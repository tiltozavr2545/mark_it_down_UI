/*
 * Android: декодер платформы (NDK MediaExtractor + MediaCodec, API 21+) —
 * ради AAC в M4A/MP4/3GP: так пишут диктофоны и мессенджеры, а свободного
 * декодера AAC под нашу лицензию нет. Умеет и всё остальное, что умеет
 * телефон, — на случай, если переносимый декодер файл не взял.
 */
#ifdef __ANDROID__

#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaExtractor.h>
#include <media/NdkMediaFormat.h>

#include "mdw.h"
#include "mdw_internal.h"

/* android.media.AudioFormat: ENCODING_PCM_16BIT = 2, ENCODING_PCM_FLOAT = 4.
 * Ключ строкой: AMEDIAFORMAT_KEY_PCM_ENCODING объявлен только с API 28. */
#define MDW_PCM_FLOAT 4

static void mdw_read_format(AMediaFormat *format, int32_t *rate,
                            int32_t *channels, int32_t *encoding) {
  AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, rate);
  AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, channels);
  if (!AMediaFormat_getInt32(format, "pcm-encoding", encoding)) *encoding = 2;
}

int mdw_platform_decode_file(const char *path, mdw_sink *sink) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return MDW_ERR_IO;
  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return MDW_ERR_IO;
  }

  int status = MDW_OK;
  AMediaExtractor *extractor = AMediaExtractor_new();
  AMediaCodec *codec = NULL;
  AMediaFormat *format = NULL;
  if (extractor == NULL) {
    close(fd);
    return MDW_ERR_NOMEM;
  }
  if (AMediaExtractor_setDataSourceFd(extractor, fd, 0, st.st_size) !=
      AMEDIA_OK) {
    status = MDW_ERR_UNSUPPORTED;
    goto done;
  }

  /* Первая звуковая дорожка; у видео — его звук. */
  size_t tracks = AMediaExtractor_getTrackCount(extractor);
  const char *mime = NULL;
  for (size_t i = 0; i < tracks; i++) {
    AMediaFormat *candidate = AMediaExtractor_getTrackFormat(extractor, i);
    const char *candidate_mime = NULL;
    if (AMediaFormat_getString(candidate, AMEDIAFORMAT_KEY_MIME,
                               &candidate_mime) &&
        strncmp(candidate_mime, "audio/", 6) == 0) {
      format = candidate;
      mime = candidate_mime;
      AMediaExtractor_selectTrack(extractor, i);
      break;
    }
    AMediaFormat_delete(candidate);
  }
  if (format == NULL) {
    status = MDW_ERR_NO_AUDIO;
    goto done;
  }

  codec = AMediaCodec_createDecoderByType(mime);
  if (codec == NULL) {
    status = MDW_ERR_UNSUPPORTED;
    goto done;
  }
  if (AMediaCodec_configure(codec, format, NULL, NULL, 0) != AMEDIA_OK ||
      AMediaCodec_start(codec) != AMEDIA_OK) {
    status = MDW_ERR_UNSUPPORTED;
    goto done;
  }

  int32_t rate = 0, channels = 0, encoding = 2;
  mdw_read_format(format, &rate, &channels, &encoding);
  if (rate > 0) mdw_sink_set_rate(sink, (uint32_t)rate);

  int input_done = 0;
  int idle = 0; /* циклы без ввода и вывода: кодек завис */
  while (status == MDW_OK && !mdw_sink_full(sink)) {
    int progressed = 0;
    if (!input_done) {
      ssize_t index = AMediaCodec_dequeueInputBuffer(codec, 10000);
      if (index >= 0) {
        size_t capacity = 0;
        uint8_t *buffer = AMediaCodec_getInputBuffer(codec, (size_t)index, &capacity);
        ssize_t size = buffer != NULL
                           ? AMediaExtractor_readSampleData(extractor, buffer, capacity)
                           : -1;
        if (size < 0) {
          AMediaCodec_queueInputBuffer(codec, (size_t)index, 0, 0, 0,
                                       AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
          input_done = 1;
        } else {
          int64_t time = AMediaExtractor_getSampleTime(extractor);
          AMediaCodec_queueInputBuffer(codec, (size_t)index, 0, (size_t)size,
                                       (uint64_t)(time > 0 ? time : 0), 0);
          AMediaExtractor_advance(extractor);
        }
        progressed = 1;
      }
    }

    AMediaCodecBufferInfo info;
    ssize_t index = AMediaCodec_dequeueOutputBuffer(codec, &info, 10000);
    if (index >= 0) {
      progressed = 1;
      size_t capacity = 0;
      uint8_t *buffer = AMediaCodec_getOutputBuffer(codec, (size_t)index, &capacity);
      if (buffer != NULL && info.size > 0 && channels > 0 &&
          (size_t)info.offset + (size_t)info.size <= capacity) {
        const uint8_t *pcm = buffer + info.offset;
        if (encoding == MDW_PCM_FLOAT) {
          uint64_t frames = (uint64_t)info.size / (sizeof(float) * (uint32_t)channels);
          status = mdw_sink_push(sink, (const float *)pcm, frames, (uint32_t)channels);
        } else {
          uint64_t frames = (uint64_t)info.size / (sizeof(int16_t) * (uint32_t)channels);
          status = mdw_sink_push_s16(sink, (const int16_t *)pcm, frames, (uint32_t)channels);
        }
      }
      AMediaCodec_releaseOutputBuffer(codec, (size_t)index, false);
      if (info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) break;
    } else if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
      progressed = 1;
      /* Настоящие частота и каналы — здесь: у HE-AAC, например, выход
       * вдвое чаще, чем в заголовке дорожки. */
      AMediaFormat *output = AMediaCodec_getOutputFormat(codec);
      if (output != NULL) {
        mdw_read_format(output, &rate, &channels, &encoding);
        AMediaFormat_delete(output);
        if (rate > 0) status = mdw_sink_set_rate(sink, (uint32_t)rate);
      }
    } else if (index != AMEDIACODEC_INFO_TRY_AGAIN_LATER &&
               index != AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED) {
      status = MDW_ERR_DECODE;
    }

    idle = progressed ? 0 : idle + 1;
    if (idle > 500) status = MDW_ERR_DECODE; /* ~5 с тишины от кодека */
  }

done:
  if (codec != NULL) {
    AMediaCodec_stop(codec);
    AMediaCodec_delete(codec);
  }
  if (format != NULL) AMediaFormat_delete(format);
  AMediaExtractor_delete(extractor);
  close(fd);
  return status;
}

#endif /* __ANDROID__ */
