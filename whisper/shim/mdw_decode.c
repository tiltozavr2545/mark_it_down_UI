/*
 * Audio → float 16 kHz mono for Whisper.
 *
 * WAV, MP3, FLAC, Ogg Vorbis — miniaudio (dr_wav/dr_mp3/dr_flac and
 * stb_vorbis), portable C with no dependencies: the same result on
 * Windows, Android, and the test host. Ogg Opus (voice messages from
 * messaging apps) — our own Ogg page parsing plus libopus. AAC — the
 * platform decoder, see mdw_platform_*.
 *
 * We don't trust the data in the file, same as with a zip header: every
 * length is checked against the buffer size, and a corrupt tail yields
 * whatever was decoded so far, not a crash.
 */
#include <stdlib.h>
#include <string.h>

#include "mdw.h"
#include "mdw_internal.h"

#define MA_NO_DEVICE_IO
#define MA_NO_THREADING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_ENCODING
#define MA_NO_GENERATION
/* stb_vorbis: declarations first, so miniaudio enables Vorbis; after
 * miniaudio's implementation comes stb_vorbis's implementation (that's
 * what its README calls for). */
#define STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#undef STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"

#include <opus.h>
#include <opus_multistream.h>

/* ------------------------------------------------------------------- sink */

/* A chunk to transcribe — 10 minutes: memory for it (samples, the copy
 * after VAD, the mel-spectrogram) is ≈100 MB regardless of recording
 * length, and the number of boundaries where a phrase might get hurt is
 * six per hour. */
#define MDW_CHUNK_SAMPLES ((int64_t)MDW_SAMPLE_RATE * 60 * 10)
/* Where to look for silence for the boundary — in the last 15 seconds of
 * the chunk, in 0.1 s windows with half-window steps. */
#define MDW_CUT_LOOKBACK ((int64_t)MDW_SAMPLE_RATE * 15)
#define MDW_CUT_WINDOW ((int64_t)MDW_SAMPLE_RATE / 10)

struct mdw_sink {
  float *data;
  int64_t count;
  int64_t capacity;
  int64_t max;
  int64_t total; /* total received, including handed-off chunks */
  uint32_t rate;
  int has_resampler;
  ma_resampler resampler;
  float *mono; /* working buffer for mixing channels down */
  uint64_t mono_capacity;
  mdw_chunk_fn on_chunk;
  void *user;
  const volatile int32_t *cancel;
  int status;
};

mdw_sink *mdw_sink_new(int64_t max) {
  mdw_sink *sink = (mdw_sink *)calloc(1, sizeof(mdw_sink));
  if (sink == NULL) return NULL;
  sink->max = max > 0 ? max : 0;
  sink->rate = MDW_SAMPLE_RATE;
  return sink;
}

mdw_sink *mdw_sink_new_chunked(mdw_chunk_fn on_chunk, void *user,
                               const volatile int32_t *cancel) {
  mdw_sink *sink = mdw_sink_new(MDW_CHUNK_SAMPLES);
  if (sink == NULL) return NULL;
  sink->on_chunk = on_chunk;
  sink->user = user;
  sink->cancel = cancel;
  return sink;
}

int mdw_sink_set_rate(mdw_sink *sink, uint32_t rate) {
  if (rate == 0) return MDW_ERR_DECODE;
  if (rate == sink->rate && (sink->has_resampler || rate == MDW_SAMPLE_RATE)) {
    return MDW_OK;
  }
  if (sink->has_resampler) {
    ma_resampler_uninit(&sink->resampler, NULL);
    sink->has_resampler = 0;
  }
  sink->rate = rate;
  if (rate == MDW_SAMPLE_RATE) return MDW_OK;
  ma_resampler_config config = ma_resampler_config_init(
      ma_format_f32, 1, rate, MDW_SAMPLE_RATE, ma_resample_algorithm_linear);
  /* Linear interpolation with a maximum-order low-pass filter: without the
   * filter, 44.1 kHz → 16 kHz produces spectral aliasing that Whisper
   * hears as noise. */
  config.linear.lpfOrder = MA_MAX_FILTER_ORDER;
  if (ma_resampler_init(&config, NULL, &sink->resampler) != MA_SUCCESS) {
    return MDW_ERR_NOMEM;
  }
  sink->has_resampler = 1;
  return MDW_OK;
}

int mdw_sink_full(const mdw_sink *sink) {
  return sink->status != MDW_OK ||
         (sink->on_chunk == NULL && sink->count >= sink->max);
}

int64_t mdw_sink_count(const mdw_sink *sink) { return sink->total; }

int mdw_sink_status(const mdw_sink *sink) { return sink->status; }

static int mdw_sink_reserve(mdw_sink *sink, int64_t extra) {
  int64_t need = sink->count + extra;
  if (need <= sink->capacity) return MDW_OK;
  int64_t capacity = sink->capacity > 0 ? sink->capacity : MDW_SAMPLE_RATE * 60;
  while (capacity < need) capacity *= 2;
  if (capacity > sink->max) capacity = sink->max;
  float *data = (float *)realloc(sink->data, (size_t)capacity * sizeof(float));
  if (data == NULL) return MDW_ERR_NOMEM;
  sink->data = data;
  sink->capacity = capacity;
  return MDW_OK;
}

/* The middle of the quietest window in the last MDW_CUT_LOOKBACK samples:
 * a chunk boundary there won't cut a word in half. */
static int64_t mdw_quiet_point(const float *data, int64_t count) {
  int64_t from = count > MDW_CUT_LOOKBACK ? count - MDW_CUT_LOOKBACK : 0;
  int64_t best = count, best_at = count;
  double best_energy = -1;
  for (int64_t at = from; at + MDW_CUT_WINDOW <= count; at += MDW_CUT_WINDOW / 2) {
    double energy = 0;
    for (int64_t i = at; i < at + MDW_CUT_WINDOW; i++) {
      energy += (double)data[i] * data[i];
    }
    if (best_energy < 0 || energy < best_energy) {
      best_energy = energy;
      best_at = at;
    }
  }
  if (best_energy >= 0) best = best_at + MDW_CUT_WINDOW / 2;
  return best > 0 ? best : count;
}

/* Hand off what's accumulated up to the quiet point, shift the remainder
 * to the start. */
static int mdw_sink_cut(mdw_sink *sink) {
  int64_t cut = mdw_quiet_point(sink->data, sink->count);
  int status = sink->on_chunk(sink->user, sink->data, cut);
  memmove(sink->data, sink->data + cut,
          (size_t)(sink->count - cut) * sizeof(float));
  sink->count -= cut;
  return status;
}

int mdw_sink_flush(mdw_sink *sink) {
  if (sink->status != MDW_OK || sink->count == 0) return sink->status;
  sink->status = sink->on_chunk(sink->user, sink->data, sink->count);
  sink->count = 0;
  return sink->status;
}

/* 16 kHz mono into the buffer: up to the limit, or without one in chunked
 * mode. */
static int mdw_sink_store(mdw_sink *sink, const float *mono, int64_t n) {
  while (n > 0 && sink->status == MDW_OK) {
    if (sink->cancel != NULL && *sink->cancel != 0) {
      sink->status = MDW_ERR_CANCELLED;
      break;
    }
    int64_t room = sink->max - sink->count;
    if (room <= 0) {
      if (sink->on_chunk == NULL) break; /* limit: discard the rest */
      sink->status = mdw_sink_cut(sink);
      continue;
    }
    int64_t take = n < room ? n : room;
    if (mdw_sink_reserve(sink, take) != MDW_OK) {
      sink->status = MDW_ERR_NOMEM;
      break;
    }
    memcpy(sink->data + sink->count, mono, (size_t)take * sizeof(float));
    sink->count += take;
    sink->total += take;
    mono += take;
    n -= take;
  }
  return sink->status;
}

/* Mono frames at sink->rate → 16 kHz, appended to the end of the buffer. */
static int mdw_sink_append_mono(mdw_sink *sink, const float *mono,
                                uint64_t count) {
  if (!sink->has_resampler) {
    return mdw_sink_store(sink, mono, (int64_t)count);
  }
  while (count > 0 && !mdw_sink_full(sink)) {
    float out[4096];
    ma_uint64 in_frames = count;
    ma_uint64 out_frames = sizeof(out) / sizeof(*out);
    if (ma_resampler_process_pcm_frames(&sink->resampler, mono, &in_frames,
                                        out, &out_frames) != MA_SUCCESS) {
      return MDW_ERR_DECODE;
    }
    int status = mdw_sink_store(sink, out, (int64_t)out_frames);
    if (status != MDW_OK) return status;
    if (in_frames == 0 && out_frames == 0) break; /* resampler is stalled */
    mono += in_frames;
    count -= in_frames;
  }
  return sink->status;
}

static float *mdw_sink_mono_buffer(mdw_sink *sink, uint64_t count) {
  if (count > sink->mono_capacity) {
    float *mono = (float *)realloc(sink->mono, (size_t)count * sizeof(float));
    if (mono == NULL) return NULL;
    sink->mono = mono;
    sink->mono_capacity = count;
  }
  return sink->mono;
}

int mdw_sink_push(mdw_sink *sink, const float *frames, uint64_t count,
                  uint32_t channels) {
  if (channels == 0) return MDW_ERR_DECODE;
  if (channels == 1) return mdw_sink_append_mono(sink, frames, count);
  float *mono = mdw_sink_mono_buffer(sink, count);
  if (mono == NULL) return MDW_ERR_NOMEM;
  for (uint64_t i = 0; i < count; i++) {
    float sum = 0;
    for (uint32_t c = 0; c < channels; c++) sum += frames[i * channels + c];
    mono[i] = sum / (float)channels;
  }
  return mdw_sink_append_mono(sink, mono, count);
}

int mdw_sink_push_s16(mdw_sink *sink, const int16_t *frames, uint64_t count,
                      uint32_t channels) {
  if (channels == 0) return MDW_ERR_DECODE;
  float *mono = mdw_sink_mono_buffer(sink, count);
  if (mono == NULL) return MDW_ERR_NOMEM;
  for (uint64_t i = 0; i < count; i++) {
    float sum = 0;
    for (uint32_t c = 0; c < channels; c++) {
      sum += (float)frames[i * channels + c] / 32768.0f;
    }
    mono[i] = sum / (float)channels;
  }
  return mdw_sink_append_mono(sink, mono, count);
}

void mdw_sink_free(mdw_sink *sink) {
  if (sink == NULL) return;
  if (sink->has_resampler) ma_resampler_uninit(&sink->resampler, NULL);
  free(sink->mono);
  free(sink->data);
  free(sink);
}

void mdw_sink_finish(mdw_sink *sink, float **out, int64_t *n_out) {
  *out = sink->data;
  *n_out = sink->count;
  sink->data = NULL;
  mdw_sink_free(sink);
}

void mdw_free_samples(float *samples) { free(samples); }

/* ---------------------------------------------------------------- Ogg Opus */

static uint16_t mdw_le16(const uint8_t *p) {
  return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t mdw_le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

/* The first Ogg page, and its first packet is OpusHead. */
static int mdw_is_ogg_opus(const uint8_t *data, int64_t size) {
  if (size < 27 || memcmp(data, "OggS", 4) != 0) return 0;
  int64_t body = 27 + data[26];
  return body + 8 <= size && memcmp(data + body, "OpusHead", 8) == 0;
}

typedef struct mdw_opus {
  OpusDecoder *decoder;           /* family 0: mono/stereo */
  OpusMSDecoder *multistream;     /* the rest: up to 255 channels */
  int channels;                   /* channels on the decoder's output */
  int64_t skip;                   /* how many 16 kHz samples to drop */
  int packets;                    /* 0 — waiting for OpusHead, 1 — OpusTags */
  int decoded;                    /* how many packets decoded */
  int failed;                     /* how many failed to decode */
  float *pcm;                     /* 120 ms × channels */
} mdw_opus;

/* The maximum Opus frame is 120 ms: 1920 samples at 16 kHz. */
#define MDW_OPUS_MAX_FRAME 1920

static int mdw_opus_head(mdw_opus *opus, const uint8_t *packet, size_t size) {
  if (size < 19 || memcmp(packet, "OpusHead", 8) != 0) return MDW_ERR_DECODE;
  if ((packet[8] & 0xF0) != 0) return MDW_ERR_UNSUPPORTED; /* version 16+ */
  int channels = packet[9];
  int pre_skip = mdw_le16(packet + 10);
  int16_t gain = (int16_t)mdw_le16(packet + 16);
  int family = packet[18];
  if (channels == 0) return MDW_ERR_DECODE;
  int error = OPUS_OK;
  if (family == 0) {
    if (channels > 2) return MDW_ERR_DECODE;
    /* A decoder at 16 kHz and one channel: libopus mixes stereo down and
     * resamples on its own — no resampler needed. */
    opus->decoder = opus_decoder_create(MDW_SAMPLE_RATE, 1, &error);
    if (error != OPUS_OK) return MDW_ERR_NOMEM;
    opus->channels = 1;
    opus_decoder_ctl(opus->decoder, OPUS_SET_GAIN(gain));
  } else {
    if (size < 21 + (size_t)channels) return MDW_ERR_DECODE;
    int streams = packet[19];
    int coupled = packet[20];
    if (streams == 0 || coupled > streams) return MDW_ERR_DECODE;
    opus->multistream = opus_multistream_decoder_create(
        MDW_SAMPLE_RATE, channels, streams, coupled, packet + 21, &error);
    if (error != OPUS_OK) return MDW_ERR_DECODE;
    opus->channels = channels;
    opus_multistream_decoder_ctl(opus->multistream, OPUS_SET_GAIN(gain));
  }
  opus->pcm = (float *)malloc(sizeof(float) * MDW_OPUS_MAX_FRAME *
                              (size_t)opus->channels);
  if (opus->pcm == NULL) return MDW_ERR_NOMEM;
  /* pre-skip is given in 48 kHz samples: it's the encoder's "spin-up", not
   * audio. */
  opus->skip = pre_skip / 3;
  return MDW_OK;
}

static int mdw_opus_packet(mdw_opus *opus, mdw_sink *sink,
                           const uint8_t *packet, size_t size) {
  int index = opus->packets++;
  if (index == 0) return mdw_opus_head(opus, packet, size);
  if (index == 1) return MDW_OK; /* OpusTags — the tags were already read by Dart */
  if (size == 0) return MDW_OK;
  int frames = opus->decoder != NULL
                   ? opus_decode_float(opus->decoder, packet, (opus_int32)size,
                                       opus->pcm, MDW_OPUS_MAX_FRAME, 0)
                   : opus_multistream_decode_float(
                         opus->multistream, packet, (opus_int32)size,
                         opus->pcm, MDW_OPUS_MAX_FRAME, 0);
  if (frames < 0) {
    opus->failed++;
    return MDW_OK; /* corrupt packet — skip it, like a player would */
  }
  opus->decoded++;
  const float *pcm = opus->pcm;
  if (opus->skip > 0) {
    int drop = opus->skip < frames ? (int)opus->skip : frames;
    opus->skip -= drop;
    frames -= drop;
    pcm += (size_t)drop * (size_t)opus->channels;
  }
  if (frames <= 0) return MDW_OK;
  return mdw_sink_push(sink, pcm, (uint64_t)frames, (uint32_t)opus->channels);
}

static int mdw_decode_ogg_opus(const uint8_t *data, int64_t size,
                               mdw_sink *sink) {
  mdw_opus opus;
  memset(&opus, 0, sizeof(opus));
  uint8_t *packet = NULL;
  size_t packet_size = 0, packet_capacity = 0;
  uint32_t serial = 0;
  int have_serial = 0;
  int status = MDW_OK;

  int64_t pos = 0;
  while (pos + 27 <= size && status == MDW_OK && !mdw_sink_full(sink)) {
    if (memcmp(data + pos, "OggS", 4) != 0 || data[pos + 4] != 0) {
      pos++; /* garbage between pages — look for the next one */
      continue;
    }
    int header_type = data[pos + 5];
    uint32_t page_serial = mdw_le32(data + pos + 14);
    int segments = data[pos + 26];
    int64_t body = pos + 27 + segments;
    if (body > size) break;
    int64_t body_size = 0;
    for (int i = 0; i < segments; i++) body_size += data[pos + 27 + i];
    if (body + body_size > size) break; /* file tail got cut off */

    if (!have_serial) {
      serial = page_serial; /* the first stream is the one with OpusHead */
      have_serial = 1;
    }
    if (page_serial == serial) {
      /* The page doesn't continue a packet, yet one is unfinished — a page
       * got lost; discard the partially assembled packet. */
      if (!(header_type & 1)) packet_size = 0;
      int64_t offset = body;
      for (int i = 0; i < segments && status == MDW_OK; i++) {
        int lacing = data[pos + 27 + i];
        if (packet_size + (size_t)lacing > packet_capacity) {
          size_t capacity = packet_capacity > 0 ? packet_capacity * 2 : 4096;
          while (capacity < packet_size + (size_t)lacing) capacity *= 2;
          uint8_t *grown = (uint8_t *)realloc(packet, capacity);
          if (grown == NULL) {
            status = MDW_ERR_NOMEM;
            break;
          }
          packet = grown;
          packet_capacity = capacity;
        }
        memcpy(packet + packet_size, data + offset, (size_t)lacing);
        packet_size += (size_t)lacing;
        offset += lacing;
        if (lacing < 255) {
          status = mdw_opus_packet(&opus, sink, packet, packet_size);
          packet_size = 0;
        }
      }
    }
    pos = body + body_size;
  }

  if (status == MDW_OK && opus.decoded == 0) {
    status = opus.failed > 0 || opus.packets > 0 ? MDW_ERR_DECODE
                                                 : MDW_ERR_NO_AUDIO;
  }
  free(packet);
  free(opus.pcm);
  if (opus.decoder != NULL) opus_decoder_destroy(opus.decoder);
  if (opus.multistream != NULL) opus_multistream_decoder_destroy(opus.multistream);
  return status;
}

/* --------------------------------------------------------------- miniaudio */

static int mdw_decode_miniaudio(const uint8_t *data, int64_t size,
                                mdw_sink *sink) {
  /* Leave the rate and channel mixing to the sink — this way every decoder
   * shares the same resampler. */
  ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 0, 0);
  ma_decoder decoder;
  if (ma_decoder_init_memory(data, (size_t)size, &config, &decoder) !=
      MA_SUCCESS) {
    return MDW_ERR_UNSUPPORTED;
  }
  ma_format format;
  ma_uint32 channels = 0, rate = 0;
  ma_decoder_get_data_format(&decoder, &format, &channels, &rate, NULL, 0);
  int status = channels == 0 ? MDW_ERR_DECODE : mdw_sink_set_rate(sink, rate);

  float buffer[4096];
  ma_uint64 chunk = channels > 0 ? sizeof(buffer) / sizeof(*buffer) / channels : 0;
  int64_t decoded = 0;
  while (status == MDW_OK && !mdw_sink_full(sink)) {
    ma_uint64 read = 0;
    ma_result result = ma_decoder_read_pcm_frames(&decoder, buffer, chunk, &read);
    if (read > 0) {
      status = mdw_sink_push(sink, buffer, read, channels);
      decoded += (int64_t)read;
    }
    if (result != MA_SUCCESS || read == 0) {
      /* MA_AT_END means the end; anything else means a corrupt stream:
       * hand back whatever we have. */
      if (result != MA_AT_END && result != MA_SUCCESS && decoded == 0) {
        status = MDW_ERR_DECODE;
      }
      break;
    }
  }
  ma_decoder_uninit(&decoder);
  return status;
}

/* ------------------------------------------------------------------ entry */

int mdw_decode_memory_to(const uint8_t *data, int64_t size, mdw_sink *sink) {
  if (data == NULL || size <= 0) return MDW_ERR_DECODE;
  return mdw_is_ogg_opus(data, size) ? mdw_decode_ogg_opus(data, size, sink)
                                     : mdw_decode_miniaudio(data, size, sink);
}

int mdw_decode_memory(const uint8_t *data, int64_t size, int64_t max_samples,
                      float **out, int64_t *n_out) {
  *out = NULL;
  *n_out = 0;
  mdw_sink *sink = mdw_sink_new(max_samples);
  if (sink == NULL) return MDW_ERR_NOMEM;
  int status = mdw_decode_memory_to(data, size, sink);
  if (status != MDW_OK) {
    mdw_sink_free(sink);
    return status;
  }
  mdw_sink_finish(sink, out, n_out);
  return MDW_OK;
}

int mdw_decode_file(const char *path, int64_t max_samples, float **out,
                    int64_t *n_out) {
  *out = NULL;
  *n_out = 0;
  mdw_sink *sink = mdw_sink_new(max_samples);
  if (sink == NULL) return MDW_ERR_NOMEM;
  int status = mdw_platform_decode_file(path, sink);
  /* The platform decoder may have failed partway through — hand back
   * whatever was decoded. */
  if (status != MDW_OK && mdw_sink_count(sink) == 0) {
    mdw_sink_free(sink);
    return status;
  }
  mdw_sink_finish(sink, out, n_out);
  return MDW_OK;
}

#if !defined(_WIN32) && !defined(__ANDROID__)
/* macOS and Linux are only the test host: AAC isn't needed there. */
int mdw_platform_decode_file(const char *path, mdw_sink *sink) {
  (void)path;
  (void)sink;
  return MDW_ERR_UNSUPPORTED;
}
#endif
