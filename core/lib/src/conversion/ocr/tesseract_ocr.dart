import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'tesseract_bindings.dart';

/// Настройки OCR, которые приложение передаёт в изолят конвертации: только
/// строки и числа — библиотеки открываются уже внутри изолята.
class OcrSettings {
  /// Каталог с `<язык>.traineddata`. На Windows — ассеты рядом с `.exe`, на
  /// Android — копия ассетов в каталоге приложения (Tesseract читает модели
  /// с диска, а не из APK), см. `app/lib/src/conversion/ocr_data.dart`.
  final String tessdataDir;

  /// Языки Tesseract через `+`. Русский первым: он основной у автора, а на
  /// смешанном тексте порядок влияет на то, какой словарь спрашивается раньше.
  final String languages;

  /// Сколько страниц-сканов PDF распознавать. OCR страницы — секунды (на
  /// телефоне — больше), отменить конвертацию нельзя (`Isolate.run`), поэтому
  /// предел, а остальные страницы — в `warnings`.
  final int maxPdfPages;

  const OcrSettings({
    required this.tessdataDir,
    this.languages = 'rus+eng',
    this.maxPdfPages = 20,
  });
}

/// Есть ли рабочий OCR с этими настройками: библиотеки грузятся и модели
/// инициализируются. Для тестов и диагностики — конвертерам проверять
/// заранее не нужно, они сами пишут предупреждение.
bool ocrAvailable(OcrSettings settings) {
  final engine = TesseractOcr.open(settings);
  engine?.dispose();
  return engine != null;
}

/// Путь к моделям в том виде, в каком его поймёт `fopen` внутри Tesseract.
/// На macOS, Linux и Android — UTF-8. На Windows `fopen` из MSVC читает путь
/// в ANSI-кодировке системы, а не в UTF-8, — и приложение, распакованное в
/// `C:\Users\Тимофей\Downloads\…`, молча осталось бы без OCR. Поэтому
/// там: ASCII как есть → короткое имя 8.3 (`GetShortPathNameW`, оно ASCII)
/// → перекодировка в ANSI-кодировку (`WideCharToMultiByte`, на русской
/// Windows — cp1251); если и она теряет символы — `null`, OCR недоступен.
/// Память под результат освобождает вызывающий (`calloc.free`).
Pointer<Uint8>? _pathForFopen(String path) {
  final isAscii = path.codeUnits.every((c) => c < 0x80);
  if (!Platform.isWindows || isAscii) return path.toNativeUtf8().cast();

  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getShortPathName = kernel32
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('GetShortPathNameW');
  final wideCharToMultiByte = kernel32
      .lookupFunction<
        Int32 Function(
          Uint32,
          Uint32,
          Pointer<Utf16>,
          Int32,
          Pointer<Uint8>,
          Int32,
          Pointer<Uint8>,
          Pointer<Int32>,
        ),
        int Function(
          int,
          int,
          Pointer<Utf16>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint8>,
          Pointer<Int32>,
        )
      >('WideCharToMultiByte');

  const capacity = 4096;
  final wide = path.toNativeUtf16();
  final short = calloc<Uint16>(capacity).cast<Utf16>();
  try {
    final length = getShortPathName(wide, short, capacity);
    if (length > 0 && length < capacity) {
      final shortPath = short.toDartString(length: length);
      if (shortPath.codeUnits.every((c) => c < 0x80)) {
        return shortPath.toNativeUtf8().cast();
      }
    }

    const cpAcp = 0; // ANSI-кодировка системы
    const wcNoBestFitChars = 0x400; // не подменять «похожими» символами
    final ansi = calloc<Uint8>(capacity);
    final usedDefault = calloc<Int32>();
    try {
      final written = wideCharToMultiByte(
        cpAcp,
        wcNoBestFitChars,
        wide,
        -1,
        ansi,
        capacity,
        nullptr,
        usedDefault,
      );
      if (written <= 0 || usedDefault.value != 0) {
        calloc.free(ansi);
        return null;
      }
      return ansi;
    } finally {
      calloc.free(usedDefault);
    }
  } finally {
    calloc
      ..free(wide)
      ..free(short);
  }
}

/// Распознанный текст и средняя уверенность Tesseract (0–100).
class OcrText {
  final String text;
  final int confidence;

  const OcrText(this.text, this.confidence);
}

/// Средняя уверенность Tesseract ниже этого — повод сказать человеку
/// «проверьте текст»: на чистой печати бывает 85–95, на фото под углом — 40–60.
const lowOcrConfidence = 60;

/// Длинная сторона, выше которой картинка уменьшается перед OCR. Снимок
/// документа с телефона — около 4000 px, этого хватает с запасом; панорама на
/// 15 000 px распознавалась бы минутами без прироста качества.
const _maxSide = 5000;

/// Предполагаемое разрешение для картинок без своего: Tesseract с «0 dpi»
/// подставляет 70 и хуже отсекает шум. Для снимка документа 300 — разумно.
const _assumedDpi = 300;

/// Один экземпляр движка на конвертацию: модели загружаются в [open]
/// (полсекунды–секунда на `rus+eng`), [dispose] освобождает память. Внутри
/// изолята — синхронно, как и PDFium.
class TesseractOcr {
  final TesseractBindings _api;
  final Pointer<Void> _handle;
  final String languages;

  TesseractOcr._(this._api, this._handle, this.languages);

  static TesseractBindings? _bindings;
  static bool _loadFailed = false;

  /// `null`, если библиотек нет или моделей нужных языков нет в
  /// [OcrSettings.tessdataDir] — OCR необязателен, вызывающий пишет
  /// предупреждение и отдаёт то, что есть без него.
  static TesseractOcr? open(OcrSettings settings) {
    for (final language in settings.languages.split('+')) {
      final model = File('${settings.tessdataDir}/$language.traineddata');
      if (!model.existsSync()) return null;
    }
    final api = _bindings ??= _load();
    if (api == null) return null;

    final path = _pathForFopen(settings.tessdataDir);
    if (path == null) return null;
    final handle = api.create();
    final languages = settings.languages.toNativeUtf8();
    try {
      final status = api.init3(handle, path.cast(), languages.cast());
      if (status != 0) {
        api.delete(handle);
        return null;
      }
    } finally {
      calloc
        ..free(path)
        ..free(languages);
    }
    final ocr = TesseractOcr._(api, handle, settings.languages);
    // Диагностика Tesseract («Estimating resolution as …») идёт в stderr
    // процесса приложения — гасим её в нулевое устройство.
    ocr._setVariable('debug_file', Platform.isWindows ? 'NUL' : '/dev/null');
    api.setPageSegMode(handle, tessPsmAuto);
    return ocr;
  }

  static TesseractBindings? _load() {
    if (_loadFailed) return null;
    final libs = loadTesseractLibraries();
    if (libs == null) {
      _loadFailed = true;
      return null;
    }
    try {
      return TesseractBindings(libs);
    } on ArgumentError {
      // В библиотеке нет нужного символа — не та сборка.
      _loadFailed = true;
      return null;
    }
  }

  /// `Tesseract 5.5.1 (rus+eng)` — пишется в `warnings`: на разных
  /// платформах и версиях результат разный, и это не надо скрывать.
  String get engine => 'Tesseract ${_api.version} ($languages)';

  void _setVariable(String name, String value) {
    final n = name.toNativeUtf8();
    final v = value.toNativeUtf8();
    try {
      _api.setVariable(_handle, n.cast(), v.cast());
    } finally {
      calloc
        ..free(n)
        ..free(v);
    }
  }

  /// Картинка в исходном формате (JPEG, PNG, BMP — что умеет Leptonica этой
  /// сборки). [quarterTurns] — поворот по часовой из EXIF `Orientation`:
  /// снимок документа «боком» Tesseract без поворота не прочтёт. `null` —
  /// Leptonica картинку не декодировала.
  OcrText? recognizeEncoded(Uint8List bytes, {int quarterTurns = 0}) {
    final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final pixes = <Pointer<Void>>[];
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var pix = _api.pixReadMem(buffer, bytes.length);
      if (pix.address == 0) return null;
      pixes.add(pix);

      if (quarterTurns % 4 != 0) {
        final rotated = _api.pixRotateOrth(pix, quarterTurns % 4);
        if (rotated.address != 0) pixes.add(pix = rotated);
      }
      final longest = [
        _api.pixGetWidth(pix),
        _api.pixGetHeight(pix),
      ].reduce((a, b) => a > b ? a : b);
      if (longest > _maxSide) {
        final factor = _maxSide / longest;
        final scaled = _api.pixScale(pix, factor, factor);
        if (scaled.address != 0) pixes.add(pix = scaled);
      }

      _api.setImage2(_handle, pix);
      _api.setSourceResolution(_handle, _assumedDpi);
      return _readText();
    } finally {
      final holder = calloc<Pointer<Void>>();
      for (final pix in pixes) {
        holder.value = pix;
        _api.pixDestroy(holder);
      }
      calloc
        ..free(holder)
        ..free(buffer);
    }
  }

  /// Готовый растр в памяти — так PDFium отдаёт отрендеренную страницу-скан
  /// (BGRx, 4 байта на пиксель). Порядок каналов Tesseract считает RGBA;
  /// перепутанные R и B на чёрном тексте по белому не влияют, а лишней копии
  /// страницы на десятки мегабайт не будет. [dpi] — разрешение рендера.
  OcrText recognizePixels(
    Pointer<Uint8> pixels,
    int width,
    int height,
    int bytesPerPixel,
    int stride,
    int dpi,
  ) {
    _api.setImage(_handle, pixels, width, height, bytesPerPixel, stride);
    _api.setSourceResolution(_handle, dpi);
    return _readText();
  }

  OcrText _readText() {
    final text = _api.getUtf8Text(_handle);
    try {
      return OcrText(readCString(text), _api.meanTextConf(_handle));
    } finally {
      if (text.address != 0) _api.deleteText(text);
    }
  }

  void dispose() => _api.delete(_handle);
}

/// Текст Tesseract → абзацы Markdown-текста. Tesseract отдаёт строки, как они
/// стоят на картинке; абзацы разделены пустой строкой. Строки внутри абзаца
/// склеиваются — то же правило «текст не переносится по ширине», что и у PDF.
/// Перенос по слогам (`пере-` + `нос` со строчной буквы) склеивается без
/// дефиса. Цена — слово через дефис ровно на стыке строк (`кто-` / `то`)
/// станет `ктото`; переносы по слогам в сканах встречаются несравнимо чаще.
List<String> ocrParagraphs(String text) {
  final paragraphs = <String>[];
  for (final block in text.replaceAll('\r', '').split(RegExp(r'\n\s*\n'))) {
    final buffer = StringBuffer();
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final current = buffer.toString();
      if (current.isEmpty) {
        buffer.write(line);
      } else if (current.endsWith('-') &&
          current.length > 1 &&
          _isLetter(current[current.length - 2]) &&
          _isLowercase(line[0])) {
        buffer
          ..clear()
          ..write(current.substring(0, current.length - 1))
          ..write(line);
      } else {
        buffer
          ..write(' ')
          ..write(line);
      }
    }
    if (buffer.isNotEmpty) paragraphs.add(buffer.toString());
  }
  return paragraphs;
}

bool _isLetter(String char) => char.toLowerCase() != char.toUpperCase();

bool _isLowercase(String char) => _isLetter(char) && char == char.toLowerCase();
