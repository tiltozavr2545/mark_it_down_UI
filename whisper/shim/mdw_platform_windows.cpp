/*
 * Windows: декодер платформы (Media Foundation, Source Reader) — ради AAC в
 * M4A/MP4: так пишут диктофоны и мессенджеры, а свободного декодера AAC под
 * нашу лицензию нет. MP3/WAV/FLAC MF тоже умеет — пригодится, если
 * переносимый декодер файл не взял. Ogg (Opus/Vorbis) без расширений из
 * Store MF не читает — его и не просим, это делает mdw_decode.c.
 *
 * Media Foundation грузится динамически (LoadLibraryEx из System32), а не
 * импортом: в редакциях Windows «N» без Media Feature Pack и в Windows
 * Server без компонента Media Foundation mfplat.dll нет, и со статическим
 * импортом не загрузилась бы вся
 * markitdown_whisper.dll — пропало бы распознавание речи целиком, а не
 * только AAC. Так M4A там получает честное «кодек не поддерживается».
 */
#ifdef _WIN32

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <string>

#include "mdw.h"
#include "mdw_internal.h"

namespace {

using MFStartupFn = HRESULT(WINAPI *)(ULONG, DWORD);
using MFShutdownFn = HRESULT(WINAPI *)();
using MFCreateMediaTypeFn = HRESULT(WINAPI *)(IMFMediaType **);
using MFCreateSourceReaderFromURLFn = HRESULT(WINAPI *)(LPCWSTR, IMFAttributes *,
                                                        IMFSourceReader **);

struct MediaFoundation {
  HMODULE mfplat = nullptr;
  HMODULE mfreadwrite = nullptr;
  MFStartupFn startup = nullptr;
  MFShutdownFn shutdown = nullptr;
  MFCreateMediaTypeFn create_media_type = nullptr;
  MFCreateSourceReaderFromURLFn create_source_reader = nullptr;

  // Только из System32: DLL с тем же именем рядом с .exe не подхватится.
  bool load() {
    mfplat = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    mfreadwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (mfplat == nullptr || mfreadwrite == nullptr) return false;
    startup = reinterpret_cast<MFStartupFn>(GetProcAddress(mfplat, "MFStartup"));
    shutdown = reinterpret_cast<MFShutdownFn>(GetProcAddress(mfplat, "MFShutdown"));
    create_media_type =
        reinterpret_cast<MFCreateMediaTypeFn>(GetProcAddress(mfplat, "MFCreateMediaType"));
    create_source_reader = reinterpret_cast<MFCreateSourceReaderFromURLFn>(
        GetProcAddress(mfreadwrite, "MFCreateSourceReaderFromURL"));
    return startup != nullptr && shutdown != nullptr && create_media_type != nullptr &&
           create_source_reader != nullptr;
  }

  ~MediaFoundation() {
    if (mfreadwrite != nullptr) FreeLibrary(mfreadwrite);
    if (mfplat != nullptr) FreeLibrary(mfplat);
  }
};

template <typename T>
void release(T *&p) {
  if (p != nullptr) {
    p->Release();
    p = nullptr;
  }
}

std::wstring widen(const char *utf8) {
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, &wide[0], length);
  wide.resize(static_cast<size_t>(length - 1));
  return wide;
}

int decode(const MediaFoundation &mf, const std::wstring &path, mdw_sink *sink) {
  IMFSourceReader *reader = nullptr;
  IMFMediaType *requested = nullptr;
  int status = MDW_OK;

  const DWORD stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  HRESULT hr = mf.create_source_reader(path.c_str(), nullptr, &reader);
  if (FAILED(hr)) return MDW_ERR_UNSUPPORTED;

  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  hr = reader->SetStreamSelection(stream, TRUE);
  if (FAILED(hr)) {
    release(reader);
    return MDW_ERR_NO_AUDIO;
  }

  // Просим float PCM, частоту и каналы — как в файле: сводим и
  // передискретизируем сами, тем же ресемплером, что и остальные декодеры.
  hr = mf.create_media_type(&requested);
  if (SUCCEEDED(hr)) hr = requested->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = requested->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
  if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(stream, nullptr, requested);
  if (FAILED(hr)) {
    release(requested);
    release(reader);
    return MDW_ERR_UNSUPPORTED;
  }

  // Что на самом деле отдаёт декодер. Читается заново и после
  // MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED: декодер AAC уточняет частоту
  // и каналы по первому кадру (HE-AAC — вдвое чаще, чем в заголовке), и
  // старые числа превратили бы звук в шум, на котором VAD не найдёт речи.
  // Float просили, но принимаем и 16-битный PCM — не читать его как float.
  UINT32 channels = 0, rate = 0, bits = 32;
  bool is_float = true;
  auto read_format = [&]() -> int {
    IMFMediaType *actual = nullptr;
    HRESULT result = reader->GetCurrentMediaType(stream, &actual);
    GUID subtype = {};
    if (SUCCEEDED(result)) result = actual->GetGUID(MF_MT_SUBTYPE, &subtype);
    if (SUCCEEDED(result)) result = actual->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels);
    if (SUCCEEDED(result)) result = actual->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    if (SUCCEEDED(result) && FAILED(actual->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits))) {
      bits = subtype == MFAudioFormat_Float ? 32 : 16;
    }
    release(actual);
    if (FAILED(result) || channels == 0 || rate == 0) return MDW_ERR_UNSUPPORTED;
    is_float = subtype == MFAudioFormat_Float && bits == 32;
    if (!is_float && !(subtype == MFAudioFormat_PCM && bits == 16)) return MDW_ERR_UNSUPPORTED;
    return mdw_sink_set_rate(sink, rate);
  };
  status = read_format();

  while (status == MDW_OK && !mdw_sink_full(sink)) {
    DWORD flags = 0;
    IMFSample *sample = nullptr;
    hr = reader->ReadSample(stream, 0, nullptr, &flags, nullptr, &sample);
    if (FAILED(hr)) {
      status = MDW_ERR_DECODE;
      break;
    }
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      status = read_format();
      if (status != MDW_OK) {
        release(sample);
        break;
      }
    }
    if (sample != nullptr) {
      IMFMediaBuffer *buffer = nullptr;
      if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
        BYTE *data = nullptr;
        DWORD length = 0;
        if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
          UINT64 frames = length / ((bits / 8) * channels);
          status = is_float
                       ? mdw_sink_push(sink, reinterpret_cast<const float *>(data), frames, channels)
                       : mdw_sink_push_s16(sink, reinterpret_cast<const int16_t *>(data), frames,
                                           channels);
          buffer->Unlock();
        }
        release(buffer);
      }
      release(sample);
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (flags & MF_SOURCE_READERF_ERROR) {
      status = MDW_ERR_DECODE;
      break;
    }
  }

  release(requested);
  release(reader);
  return status;
}

}  // namespace

extern "C" int mdw_platform_decode_file(const char *path, mdw_sink *sink) {
  std::wstring wide = widen(path);
  if (wide.empty()) return MDW_ERR_IO;

  // Поток изолята Dart COM не инициализировал. Если кто-то уже сделал это
  // в другом режиме (RPC_E_CHANGED_MODE) — работаем в его режиме, но и
  // CoUninitialize тогда не наш.
  HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  bool own_com = SUCCEEDED(com);
  if (FAILED(com) && com != RPC_E_CHANGED_MODE) return MDW_ERR_UNSUPPORTED;

  int status = MDW_ERR_UNSUPPORTED;
  MediaFoundation mf;
  if (mf.load() && SUCCEEDED(mf.startup(MF_VERSION, MFSTARTUP_LITE))) {
    status = decode(mf, wide, sink);
    mf.shutdown();
  }
  if (own_com) CoUninitialize();
  return status;
}

#endif  // _WIN32
