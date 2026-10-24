/// Our own minimal FFI bindings onto Tesseract's C API (`tesseract/capi.h`)
/// and a few Leptonica functions (`allheaders.h`) — the same approach as
/// PDFium (`../pdf/pdfium_bindings.dart`): FFI runs inside the conversion
/// isolate, and `core/` can't import a Flutter plugin. For why Tesseract
/// and not ML Kit, and where the libraries come from, see
/// `docs/format-coverage.md#решения-этапа-6`.
///
/// Type names repeat the headers verbatim — this makes checking the
/// signatures against them easier.
// ignore_for_file: camel_case_types
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Environment variable with the directory holding `libtesseract`/
/// `libleptonica` (and everything they depend on). Needed for `dart test`
/// and for any machine where the libraries aren't in the platform's
/// standard location.
const tesseractLibDirEnvVar = 'MARKITDOWN_TESSERACT_DIR';

/// A pair of libraries: Tesseract and the Leptonica it uses.
class TesseractLibraries {
  final DynamicLibrary tesseract;
  final DynamicLibrary leptonica;

  const TesseractLibraries(this.tesseract, this.leptonica);
}

/// Finds and opens the libraries. `null` if they're missing: OCR is an
/// optional part of the pipeline, its absence isn't a conversion error.
///
/// 1. [tesseractLibDirEnvVar] — an explicit directory.
/// 2. Android: bare names — the `.so` files live in `jniLibs/arm64-v8a/`
///    and are found on their own (from the Tesseract4Android build, see
///    `tesseract/fetch.sh`).
/// 3. Windows: next to the `.exe` (`install(...)` in
///    `app/windows/CMakeLists.txt`). The DLL names are versioned
///    (`leptonica-1.87.0.dll`, `tesseract55.dll`) and can't be renamed —
///    `tesseract55.dll` imports Leptonica by name — so we search by prefix.
/// 4. Linux: the system ones from distro packages (that's how CI installs
///    them).
TesseractLibraries? loadTesseractLibraries() {
  try {
    final dir = Platform.environment[tesseractLibDirEnvVar];
    if (dir != null && dir.isNotEmpty) return _openFromDirectory(dir);
    if (Platform.isAndroid) {
      // Leptonica first: a Tesseract dependency, loaded by name.
      final leptonica = DynamicLibrary.open('libleptonica.so');
      return TesseractLibraries(
        DynamicLibrary.open('libtesseract.so'),
        leptonica,
      );
    }
    if (Platform.isWindows) {
      return _openFromDirectory(File(Platform.resolvedExecutable).parent.path);
    }
    if (Platform.isLinux) {
      return TesseractLibraries(
        _openFirst(['libtesseract.so.5', 'libtesseract.so']),
        _openFirst(['libleptonica.so.6', 'liblept.so.5', 'libleptonica.so']),
      );
    }
  } on ArgumentError {
    return null; // DynamicLibrary.open: file missing or fails to load
  } on StateError {
    return null;
  }
  return null;
}

DynamicLibrary _openFirst(List<String> names) {
  for (final name in names) {
    try {
      return DynamicLibrary.open(name);
    } on ArgumentError {
      continue;
    }
  }
  throw StateError('нет ни одной из библиотек: ${names.join(', ')}');
}

TesseractLibraries? _openFromDirectory(String dir) {
  final files = Directory(dir).existsSync()
      ? Directory(dir).listSync().whereType<File>().toList()
      : <File>[];
  String? find(List<String> prefixes) {
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final isLibrary =
          name.endsWith('.dll') ||
          name.endsWith('.dylib') ||
          name.contains('.so');
      if (isLibrary && prefixes.any(name.startsWith)) return file.path;
    }
    return null;
  }

  final leptonica = find(['libleptonica', 'leptonica', 'liblept']);
  final tesseract = find(['libtesseract', 'tesseract']);
  if (leptonica == null || tesseract == null) return null;
  final leptonicaLib = DynamicLibrary.open(leptonica);
  return TesseractLibraries(DynamicLibrary.open(tesseract), leptonicaLib);
}

typedef _TessVersionNative = Pointer<Utf8Char> Function();
typedef _TessBaseAPICreateNative = Pointer<Void> Function();
typedef _TessBaseAPIDeleteNative = Void Function(Pointer<Void> handle);
typedef _TessBaseAPIDeleteDart = void Function(Pointer<Void> handle);
typedef _TessBaseAPIInit3Native =
    Int32 Function(
      Pointer<Void> handle,
      Pointer<Utf8Char> datapath,
      Pointer<Utf8Char> language,
    );
typedef _TessBaseAPIInit3Dart =
    int Function(
      Pointer<Void> handle,
      Pointer<Utf8Char> datapath,
      Pointer<Utf8Char> language,
    );
typedef _TessBaseAPISetVariableNative =
    Int32 Function(
      Pointer<Void> handle,
      Pointer<Utf8Char> name,
      Pointer<Utf8Char> value,
    );
typedef _TessBaseAPISetVariableDart =
    int Function(
      Pointer<Void> handle,
      Pointer<Utf8Char> name,
      Pointer<Utf8Char> value,
    );
typedef _TessBaseAPISetPageSegModeNative =
    Void Function(Pointer<Void> handle, Int32 mode);
typedef _TessBaseAPISetPageSegModeDart =
    void Function(Pointer<Void> handle, int mode);
typedef _TessBaseAPISetImageNative =
    Void Function(
      Pointer<Void> handle,
      Pointer<Uint8> imagedata,
      Int32 width,
      Int32 height,
      Int32 bytesPerPixel,
      Int32 bytesPerLine,
    );
typedef _TessBaseAPISetImageDart =
    void Function(
      Pointer<Void> handle,
      Pointer<Uint8> imagedata,
      int width,
      int height,
      int bytesPerPixel,
      int bytesPerLine,
    );
typedef _TessBaseAPISetImage2Native =
    Void Function(Pointer<Void> handle, Pointer<Void> pix);
typedef _TessBaseAPISetImage2Dart =
    void Function(Pointer<Void> handle, Pointer<Void> pix);
typedef _TessBaseAPISetSourceResolutionNative =
    Void Function(Pointer<Void> handle, Int32 ppi);
typedef _TessBaseAPISetSourceResolutionDart =
    void Function(Pointer<Void> handle, int ppi);
typedef _TessBaseAPIGetUTF8TextNative =
    Pointer<Utf8Char> Function(Pointer<Void> handle);
typedef _TessBaseAPIMeanTextConfNative = Int32 Function(Pointer<Void> handle);
typedef _TessBaseAPIMeanTextConfDart = int Function(Pointer<Void> handle);
typedef _TessDeleteTextNative = Void Function(Pointer<Utf8Char> text);
typedef _TessDeleteTextDart = void Function(Pointer<Utf8Char> text);

typedef _pixReadMemNative =
    Pointer<Void> Function(Pointer<Uint8> data, Size size);
typedef _pixReadMemDart = Pointer<Void> Function(Pointer<Uint8> data, int size);
typedef _pixDestroyNative = Void Function(Pointer<Pointer<Void>> ppix);
typedef _pixDestroyDart = void Function(Pointer<Pointer<Void>> ppix);
typedef _pixRotateOrthNative =
    Pointer<Void> Function(Pointer<Void> pix, Int32 quads);
typedef _pixRotateOrthDart =
    Pointer<Void> Function(Pointer<Void> pix, int quads);
typedef _pixGetDimensionNative = Int32 Function(Pointer<Void> pix);
typedef _pixGetDimensionDart = int Function(Pointer<Void> pix);
typedef _pixScaleNative =
    Pointer<Void> Function(Pointer<Void> pix, Float scaleX, Float scaleY);
typedef _pixScaleDart =
    Pointer<Void> Function(Pointer<Void> pix, double scaleX, double scaleY);
typedef _setMsgSeverityNative = Int32 Function(Int32 severity);
typedef _setMsgSeverityDart = int Function(int severity);

/// C's `char` — a UTF-8 byte, read by [readCString].
typedef Utf8Char = Uint8;

/// `PSM_AUTO`: parse the page into blocks without detecting orientation —
/// Tesseract's command-line default mode (the API default is
/// `PSM_SINGLE_BLOCK`, which breaks on multi-column pages).
const tessPsmAuto = 3;

/// `L_SEVERITY_NONE`: Leptonica stays quiet on stderr — its complaints
/// about an unreadable image already get turned into a clear warning on
/// our side.
const _lSeverityNone = 6;

class TesseractBindings {
  TesseractBindings(TesseractLibraries libs)
    : _version = libs.tesseract
          .lookupFunction<_TessVersionNative, _TessVersionNative>(
            'TessVersion',
          ),
      _create = libs.tesseract
          .lookupFunction<_TessBaseAPICreateNative, _TessBaseAPICreateNative>(
            'TessBaseAPICreate',
          ),
      _delete = libs.tesseract
          .lookupFunction<_TessBaseAPIDeleteNative, _TessBaseAPIDeleteDart>(
            'TessBaseAPIDelete',
          ),
      _init3 = libs.tesseract
          .lookupFunction<_TessBaseAPIInit3Native, _TessBaseAPIInit3Dart>(
            'TessBaseAPIInit3',
          ),
      _setVariable = libs.tesseract
          .lookupFunction<
            _TessBaseAPISetVariableNative,
            _TessBaseAPISetVariableDart
          >('TessBaseAPISetVariable'),
      _setPageSegMode = libs.tesseract
          .lookupFunction<
            _TessBaseAPISetPageSegModeNative,
            _TessBaseAPISetPageSegModeDart
          >('TessBaseAPISetPageSegMode'),
      _setImage = libs.tesseract
          .lookupFunction<_TessBaseAPISetImageNative, _TessBaseAPISetImageDart>(
            'TessBaseAPISetImage',
          ),
      _setImage2 = libs.tesseract
          .lookupFunction<
            _TessBaseAPISetImage2Native,
            _TessBaseAPISetImage2Dart
          >('TessBaseAPISetImage2'),
      _setSourceResolution = libs.tesseract
          .lookupFunction<
            _TessBaseAPISetSourceResolutionNative,
            _TessBaseAPISetSourceResolutionDart
          >('TessBaseAPISetSourceResolution'),
      _getUtf8Text = libs.tesseract
          .lookupFunction<
            _TessBaseAPIGetUTF8TextNative,
            _TessBaseAPIGetUTF8TextNative
          >('TessBaseAPIGetUTF8Text'),
      _meanTextConf = libs.tesseract
          .lookupFunction<
            _TessBaseAPIMeanTextConfNative,
            _TessBaseAPIMeanTextConfDart
          >('TessBaseAPIMeanTextConf'),
      _deleteText = libs.tesseract
          .lookupFunction<_TessDeleteTextNative, _TessDeleteTextDart>(
            'TessDeleteText',
          ),
      _pixReadMem = libs.leptonica
          .lookupFunction<_pixReadMemNative, _pixReadMemDart>('pixReadMem'),
      _pixDestroy = libs.leptonica
          .lookupFunction<_pixDestroyNative, _pixDestroyDart>('pixDestroy'),
      _pixRotateOrth = libs.leptonica
          .lookupFunction<_pixRotateOrthNative, _pixRotateOrthDart>(
            'pixRotateOrth',
          ),
      _pixGetWidth = libs.leptonica
          .lookupFunction<_pixGetDimensionNative, _pixGetDimensionDart>(
            'pixGetWidth',
          ),
      _pixGetHeight = libs.leptonica
          .lookupFunction<_pixGetDimensionNative, _pixGetDimensionDart>(
            'pixGetHeight',
          ),
      _pixScale = libs.leptonica.lookupFunction<_pixScaleNative, _pixScaleDart>(
        'pixScale',
      ) {
    libs.leptonica.lookupFunction<_setMsgSeverityNative, _setMsgSeverityDart>(
      'setMsgSeverity',
    )(_lSeverityNone);
  }

  final _TessVersionNative _version;
  final _TessBaseAPICreateNative _create;
  final _TessBaseAPIDeleteDart _delete;
  final _TessBaseAPIInit3Dart _init3;
  final _TessBaseAPISetVariableDart _setVariable;
  final _TessBaseAPISetPageSegModeDart _setPageSegMode;
  final _TessBaseAPISetImageDart _setImage;
  final _TessBaseAPISetImage2Dart _setImage2;
  final _TessBaseAPISetSourceResolutionDart _setSourceResolution;
  final _TessBaseAPIGetUTF8TextNative _getUtf8Text;
  final _TessBaseAPIMeanTextConfDart _meanTextConf;
  final _TessDeleteTextDart _deleteText;
  final _pixReadMemDart _pixReadMem;
  final _pixDestroyDart _pixDestroy;
  final _pixRotateOrthDart _pixRotateOrth;
  final _pixGetDimensionDart _pixGetWidth;
  final _pixGetDimensionDart _pixGetHeight;
  final _pixScaleDart _pixScale;

  Pointer<Void> create() => _create();
  void delete(Pointer<Void> handle) => _delete(handle);
  int init3(
    Pointer<Void> handle,
    Pointer<Utf8Char> path,
    Pointer<Utf8Char> lang,
  ) => _init3(handle, path, lang);
  int setVariable(
    Pointer<Void> handle,
    Pointer<Utf8Char> name,
    Pointer<Utf8Char> value,
  ) => _setVariable(handle, name, value);
  void setPageSegMode(Pointer<Void> handle, int mode) =>
      _setPageSegMode(handle, mode);
  void setImage(
    Pointer<Void> handle,
    Pointer<Uint8> data,
    int width,
    int height,
    int bytesPerPixel,
    int bytesPerLine,
  ) => _setImage(handle, data, width, height, bytesPerPixel, bytesPerLine);
  void setImage2(Pointer<Void> handle, Pointer<Void> pix) =>
      _setImage2(handle, pix);
  void setSourceResolution(Pointer<Void> handle, int ppi) =>
      _setSourceResolution(handle, ppi);
  Pointer<Utf8Char> getUtf8Text(Pointer<Void> handle) => _getUtf8Text(handle);
  int meanTextConf(Pointer<Void> handle) => _meanTextConf(handle);
  void deleteText(Pointer<Utf8Char> text) => _deleteText(text);
  Pointer<Void> pixReadMem(Pointer<Uint8> data, int size) =>
      _pixReadMem(data, size);
  void pixDestroy(Pointer<Pointer<Void>> ppix) => _pixDestroy(ppix);
  Pointer<Void> pixRotateOrth(Pointer<Void> pix, int quads) =>
      _pixRotateOrth(pix, quads);
  int pixGetWidth(Pointer<Void> pix) => _pixGetWidth(pix);
  int pixGetHeight(Pointer<Void> pix) => _pixGetHeight(pix);
  Pointer<Void> pixScale(Pointer<Void> pix, double scaleX, double scaleY) =>
      _pixScale(pix, scaleX, scaleY);

  /// `5.5.1` and the like — written into `warnings` along with the result.
  String get version => readCString(_version());
}

/// A null-terminated UTF-8 string → a Dart string (without freeing the
/// memory). Malformed sequences don't crash the parse: OCR sometimes
/// outputs a truncated multi-byte character.
String readCString(Pointer<Utf8Char> pointer) {
  if (pointer.address == 0) return '';
  var length = 0;
  while (pointer[length] != 0) {
    length++;
  }
  return utf8.decode(pointer.asTypedList(length), allowMalformed: true);
}
