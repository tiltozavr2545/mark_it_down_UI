import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'tesseract_bindings.dart';

/// OCR settings that the app passes into the conversion isolate: only
/// strings and numbers — the libraries themselves are opened inside the isolate.
class OcrSettings {
  /// Directory with `<language>.traineddata`. On Windows — assets next to
  /// `.exe`; on Android — a copy of the assets in the app's directory
  /// (Tesseract reads models from disk, not from the APK), see
  /// `app/lib/src/conversion/ocr_data.dart`.
  final String tessdataDir;

  /// Tesseract languages joined by `+`. Russian first: it's the author's
  /// primary language, and on mixed text the order affects which dictionary
  /// gets consulted first.
  final String languages;

  /// How many scanned PDF pages to run OCR on. OCR per page takes seconds (on
  /// a phone — more), and the conversion can't be cancelled (`Isolate.run`),
  /// hence the limit, with the remaining pages reported in `warnings`.
  final int maxPdfPages;

  const OcrSettings({
    required this.tessdataDir,
    this.languages = 'rus+eng',
    this.maxPdfPages = 20,
  });
}

/// Whether OCR works with these settings: the libraries load and the models
/// initialize. For tests and diagnostics — converters don't need to check
/// ahead of time, they write their own warning instead.
bool ocrAvailable(OcrSettings settings) {
  final engine = TesseractOcr.open(settings);
  engine?.dispose();
  return engine != null;
}

/// Path to the models in the form `fopen` inside Tesseract will understand.
/// On macOS, Linux and Android — UTF-8. On Windows, MSVC's `fopen` reads the
/// path in the system's ANSI codepage, not UTF-8 — so an app unpacked into
/// `C:\Users\Тимофей\Downloads\…` would silently end up without OCR. Hence,
/// on Windows: ASCII as-is → short 8.3 name (`GetShortPathNameW`, which is
/// ASCII) → re-encode into the ANSI codepage (`WideCharToMultiByte`; cp1251
/// on a Russian-locale Windows); if that still loses characters — `null`,
/// OCR is unavailable. The caller frees the result's memory (`calloc.free`).
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

    const cpAcp = 0; // system ANSI codepage
    const wcNoBestFitChars = 0x400; // don't substitute "similar" characters
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

/// Recognized text and Tesseract's mean confidence (0–100).
class OcrText {
  final String text;
  final int confidence;

  const OcrText(this.text, this.confidence);
}

/// Below this, Tesseract's mean confidence is a reason to tell the user
/// "check the text": clean print scores 85–95, an angled photo — 40–60.
const lowOcrConfidence = 60;

/// Long side above which an image is downscaled before OCR. A phone photo of
/// a document is around 4000 px, which is plenty; a 15,000 px panorama would
/// take minutes to recognize with no quality gain.
const _maxSide = 5000;

/// Assumed resolution for images that don't carry their own: Tesseract
/// defaults to 70 for "0 dpi" and filters noise worse at that value. 300 is
/// reasonable for a document photo.
const _assumedDpi = 300;

/// One engine instance per conversion: models load in [open] (half a
/// second to a second for `rus+eng`), [dispose] frees the memory. Inside the
/// isolate it runs synchronously, same as PDFium.
class TesseractOcr {
  final TesseractBindings _api;
  final Pointer<Void> _handle;
  final String languages;

  TesseractOcr._(this._api, this._handle, this.languages);

  static TesseractBindings? _bindings;
  static bool _loadFailed = false;

  /// `null` if the libraries are missing, or the models for the requested
  /// languages aren't in [OcrSettings.tessdataDir] — OCR is optional, the
  /// caller writes a warning and returns what it has without it.
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
    // Tesseract's diagnostics ("Estimating resolution as …") go to the
    // app process's stderr — silence it to the null device.
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
      // The library is missing the required symbol — wrong build.
      _loadFailed = true;
      return null;
    }
  }

  /// `Tesseract 5.5.1 (rus+eng)` — written into `warnings`: the result
  /// differs across platforms and versions, and that shouldn't be hidden.
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

  /// The image in its original format (JPEG, PNG, BMP — whatever this
  /// build's Leptonica supports). [quarterTurns] — clockwise rotation from
  /// the EXIF `Orientation`: a document photo shot "sideways" Tesseract
  /// won't read without rotating it first. `null` — Leptonica failed to
  /// decode the image.
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

  /// A ready-made bitmap already in memory — this is how PDFium hands back
  /// a rendered scanned page (BGRx, 4 bytes per pixel). Tesseract treats the
  /// channel order as RGBA; swapped R and B don't matter for black text on
  /// white, and this avoids an extra tens-of-megabytes page copy. [dpi] —
  /// the render resolution.
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

/// Tesseract's text → Markdown paragraphs. Tesseract outputs lines as they
/// appear on the image; paragraphs are separated by a blank line. Lines
/// within a paragraph are joined — the same "text doesn't wrap at a fixed
/// width" rule as for PDF. A syllable hyphenation (`pere-` + `nos` starting
/// with a lowercase letter) is joined without the hyphen. The cost: a
/// hyphenated word that happens to break exactly at a line boundary
/// (`who-` / `ever`) becomes `whoever`; syllable hyphenation in scans is
/// incomparably more common.
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
