/// Our own minimal FFI bindings onto PDFium — only what's needed for text
/// extraction (not the full API). The decision to use PDFium via FFI
/// instead of `syncfusion_flutter_pdf` is recorded in
/// `docs/format-coverage.md#решения-этапа-3`: `core/` isn't allowed to
/// import `flutter/`, and FFI, unlike a platform plugin, also works
/// inside `Isolate.run` — see
/// `docs/client-architecture.md#конвертация-в-изоляте`.
///
/// The native library isn't committed to this tree — `pdfium/fetch.sh`
/// downloads it (like `python-build-standalone` for the sidecar, see
/// `docs/python-sidecar.md`).
///
/// The type names below repeat `fpdfview.h`/`fpdf_text.h`/`fpdf_edit.h`
/// verbatim — this makes checking them against PDFium's signatures
/// easier, it isn't a style mistake.
// ignore_for_file: camel_case_types
library;

import 'dart:ffi';
import 'dart:io';

/// Finds and opens `libpdfium`. Order of sources:
///
/// 1. `MARKITDOWN_PDFIUM_PATH` — an explicit path, needed for `dart test`
///    and for any machine where the library isn't in the platform's
///    standard location.
/// 2. The bare library name — the working case for Android: the `.so`
///    lives in `jniLibs/<abi>/` and lands on the process's search path on
///    its own, with no action needed from us. And for Windows:
///    `pdfium.dll` is placed next to the `.exe` by the `install(...)`
///    rule in `app/windows/CMakeLists.txt`, and `LoadLibrary` checks the
///    executable's own directory first.
///
/// A macOS app (the bundle from `flutter build macos`) isn't covered here
/// yet — see "Environment limitations" in `../../../../../AGENTS.md`:
/// there's no Xcode yet, so there's nowhere to run and test this branch.
/// Once there is, a path like `Frameworks/libpdfium.dylib` relative to
/// `Platform.resolvedExecutable` will be added here.
DynamicLibrary loadPdfiumLibrary() {
  final override = Platform.environment['MARKITDOWN_PDFIUM_PATH'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libpdfium.so');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libpdfium.dylib');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('pdfium.dll');
  }
  throw UnsupportedError(
    'PDFium не подключён на платформе ${Platform.operatingSystem}',
  );
}

typedef _FPDF_InitLibraryNative = Void Function();
typedef _FPDF_GetLastErrorNative = Uint64 Function();
typedef _FPDF_GetLastErrorDart = int Function();

typedef _FPDF_LoadMemDocumentNative =
    Pointer<Void> Function(
      Pointer<Void> dataBuf,
      Int32 size,
      Pointer<Void> password,
    );
typedef _FPDF_LoadMemDocumentDart =
    Pointer<Void> Function(
      Pointer<Void> dataBuf,
      int size,
      Pointer<Void> password,
    );

typedef _FPDF_CloseDocumentNative = Void Function(Pointer<Void> document);
typedef _FPDF_CloseDocumentDart = void Function(Pointer<Void> document);

typedef _FPDF_GetPageCountNative = Int32 Function(Pointer<Void> document);
typedef _FPDF_GetPageCountDart = int Function(Pointer<Void> document);

typedef _FPDF_LoadPageNative =
    Pointer<Void> Function(Pointer<Void> document, Int32 index);
typedef _FPDF_LoadPageDart =
    Pointer<Void> Function(Pointer<Void> document, int index);

typedef _FPDF_ClosePageNative = Void Function(Pointer<Void> page);
typedef _FPDF_ClosePageDart = void Function(Pointer<Void> page);

typedef _FPDFText_LoadPageNative = Pointer<Void> Function(Pointer<Void> page);
typedef _FPDFText_LoadPageDart = Pointer<Void> Function(Pointer<Void> page);

typedef _FPDFText_ClosePageNative = Void Function(Pointer<Void> textPage);
typedef _FPDFText_ClosePageDart = void Function(Pointer<Void> textPage);

typedef _FPDFText_CountCharsNative = Int32 Function(Pointer<Void> textPage);
typedef _FPDFText_CountCharsDart = int Function(Pointer<Void> textPage);

typedef _FPDFText_GetFontSizeNative =
    Double Function(Pointer<Void> textPage, Int32 index);
typedef _FPDFText_GetFontSizeDart =
    double Function(Pointer<Void> textPage, int index);

typedef _FPDFText_GetTextNative =
    Int32 Function(
      Pointer<Void> textPage,
      Int32 startIndex,
      Int32 count,
      Pointer<Uint16> result,
    );
typedef _FPDFText_GetTextDart =
    int Function(
      Pointer<Void> textPage,
      int startIndex,
      int count,
      Pointer<Uint16> result,
    );

typedef _FPDFText_GetCharBoxNative =
    Int32 Function(
      Pointer<Void> textPage,
      Int32 index,
      Pointer<Double> left,
      Pointer<Double> right,
      Pointer<Double> bottom,
      Pointer<Double> top,
    );
typedef _FPDFText_GetCharBoxDart =
    int Function(
      Pointer<Void> textPage,
      int index,
      Pointer<Double> left,
      Pointer<Double> right,
      Pointer<Double> bottom,
      Pointer<Double> top,
    );

typedef _FPDFPage_CountObjectsNative = Int32 Function(Pointer<Void> page);
typedef _FPDFPage_CountObjectsDart = int Function(Pointer<Void> page);

typedef _FPDFPage_GetObjectNative =
    Pointer<Void> Function(Pointer<Void> page, Int32 index);
typedef _FPDFPage_GetObjectDart =
    Pointer<Void> Function(Pointer<Void> page, int index);

typedef _FPDFPageObj_GetTypeNative = Int32 Function(Pointer<Void> pageObject);
typedef _FPDFPageObj_GetTypeDart = int Function(Pointer<Void> pageObject);

typedef _FPDF_GetPageSizeNative = Float Function(Pointer<Void> page);
typedef _FPDF_GetPageSizeDart = double Function(Pointer<Void> page);

typedef _FPDFBitmap_CreateExNative =
    Pointer<Void> Function(
      Int32 width,
      Int32 height,
      Int32 format,
      Pointer<Void> firstScan,
      Int32 stride,
    );
typedef _FPDFBitmap_CreateExDart =
    Pointer<Void> Function(
      int width,
      int height,
      int format,
      Pointer<Void> firstScan,
      int stride,
    );

typedef _FPDFBitmap_FillRectNative =
    Int32 Function(
      Pointer<Void> bitmap,
      Int32 left,
      Int32 top,
      Int32 width,
      Int32 height,
      Uint32 color,
    );
typedef _FPDFBitmap_FillRectDart =
    int Function(
      Pointer<Void> bitmap,
      int left,
      int top,
      int width,
      int height,
      int color,
    );

typedef _FPDF_RenderPageBitmapNative =
    Void Function(
      Pointer<Void> bitmap,
      Pointer<Void> page,
      Int32 startX,
      Int32 startY,
      Int32 sizeX,
      Int32 sizeY,
      Int32 rotate,
      Int32 flags,
    );
typedef _FPDF_RenderPageBitmapDart =
    void Function(
      Pointer<Void> bitmap,
      Pointer<Void> page,
      int startX,
      int startY,
      int sizeX,
      int sizeY,
      int rotate,
      int flags,
    );

typedef _FPDFBitmap_GetBufferNative =
    Pointer<Uint8> Function(Pointer<Void> bitmap);
typedef _FPDFBitmap_GetStrideNative = Int32 Function(Pointer<Void> bitmap);
typedef _FPDFBitmap_GetStrideDart = int Function(Pointer<Void> bitmap);
typedef _FPDFBitmap_DestroyNative = Void Function(Pointer<Void> bitmap);
typedef _FPDFBitmap_DestroyDart = void Function(Pointer<Void> bitmap);

/// `FPDFBitmap_BGRx` from `fpdfview.h`: 4 bytes per pixel, no alpha. Not
/// to be confused with `FPDFBitmap_BGR` = 2 (3 bytes): Tesseract, told
/// "4 bytes per pixel", would read such a bitmap past its end.
const fpdfBitmapBgrx = 3;

/// `FPDF_ANNOT`: also render annotations — stamps and signatures on a
/// scan are often exactly that.
const fpdfRenderAnnot = 0x01;

/// `FPDF_PAGEOBJ_IMAGE` from `fpdf_edit.h` — a value that's part of the
/// public ABI, doesn't change between PDFium releases.
const fpdfPageObjImage = 3;

/// A thin wrapper over the needed subset of `fpdfview.h`/`fpdf_text.h`/
/// `fpdf_edit.h`. One process — one library initialization: PDFium
/// doesn't support calling `FPDF_InitLibrary`/`FPDF_DestroyLibrary`
/// repeatedly on the fly without risking a race between isolates, so we
/// initialize once and never deinitialize at all — the conversion
/// process is short-lived anyway (`Isolate.run`).
class PdfiumBindings {
  PdfiumBindings._(DynamicLibrary lib)
    : _getLastError = lib
          .lookupFunction<_FPDF_GetLastErrorNative, _FPDF_GetLastErrorDart>(
            'FPDF_GetLastError',
          ),
      _loadMemDocument = lib
          .lookupFunction<
            _FPDF_LoadMemDocumentNative,
            _FPDF_LoadMemDocumentDart
          >('FPDF_LoadMemDocument'),
      _closeDocument = lib
          .lookupFunction<_FPDF_CloseDocumentNative, _FPDF_CloseDocumentDart>(
            'FPDF_CloseDocument',
          ),
      _getPageCount = lib
          .lookupFunction<_FPDF_GetPageCountNative, _FPDF_GetPageCountDart>(
            'FPDF_GetPageCount',
          ),
      _loadPage = lib.lookupFunction<_FPDF_LoadPageNative, _FPDF_LoadPageDart>(
        'FPDF_LoadPage',
      ),
      _closePage = lib
          .lookupFunction<_FPDF_ClosePageNative, _FPDF_ClosePageDart>(
            'FPDF_ClosePage',
          ),
      _textLoadPage = lib
          .lookupFunction<_FPDFText_LoadPageNative, _FPDFText_LoadPageDart>(
            'FPDFText_LoadPage',
          ),
      _textClosePage = lib
          .lookupFunction<_FPDFText_ClosePageNative, _FPDFText_ClosePageDart>(
            'FPDFText_ClosePage',
          ),
      _textCountChars = lib
          .lookupFunction<_FPDFText_CountCharsNative, _FPDFText_CountCharsDart>(
            'FPDFText_CountChars',
          ),
      _textGetFontSize = lib
          .lookupFunction<
            _FPDFText_GetFontSizeNative,
            _FPDFText_GetFontSizeDart
          >('FPDFText_GetFontSize'),
      _textGetText = lib
          .lookupFunction<_FPDFText_GetTextNative, _FPDFText_GetTextDart>(
            'FPDFText_GetText',
          ),
      _textGetCharBox = lib
          .lookupFunction<_FPDFText_GetCharBoxNative, _FPDFText_GetCharBoxDart>(
            'FPDFText_GetCharBox',
          ),
      _pageCountObjects = lib
          .lookupFunction<
            _FPDFPage_CountObjectsNative,
            _FPDFPage_CountObjectsDart
          >('FPDFPage_CountObjects'),
      _pageGetObject = lib
          .lookupFunction<_FPDFPage_GetObjectNative, _FPDFPage_GetObjectDart>(
            'FPDFPage_GetObject',
          ),
      _pageObjGetType = lib
          .lookupFunction<_FPDFPageObj_GetTypeNative, _FPDFPageObj_GetTypeDart>(
            'FPDFPageObj_GetType',
          ),
      _getPageWidth = lib
          .lookupFunction<_FPDF_GetPageSizeNative, _FPDF_GetPageSizeDart>(
            'FPDF_GetPageWidthF',
          ),
      _getPageHeight = lib
          .lookupFunction<_FPDF_GetPageSizeNative, _FPDF_GetPageSizeDart>(
            'FPDF_GetPageHeightF',
          ),
      _bitmapCreateEx = lib
          .lookupFunction<_FPDFBitmap_CreateExNative, _FPDFBitmap_CreateExDart>(
            'FPDFBitmap_CreateEx',
          ),
      _bitmapFillRect = lib
          .lookupFunction<_FPDFBitmap_FillRectNative, _FPDFBitmap_FillRectDart>(
            'FPDFBitmap_FillRect',
          ),
      _renderPageBitmap = lib
          .lookupFunction<
            _FPDF_RenderPageBitmapNative,
            _FPDF_RenderPageBitmapDart
          >('FPDF_RenderPageBitmap'),
      _bitmapGetBuffer = lib
          .lookupFunction<
            _FPDFBitmap_GetBufferNative,
            _FPDFBitmap_GetBufferNative
          >('FPDFBitmap_GetBuffer'),
      _bitmapGetStride = lib
          .lookupFunction<
            _FPDFBitmap_GetStrideNative,
            _FPDFBitmap_GetStrideDart
          >('FPDFBitmap_GetStride'),
      _bitmapDestroy = lib
          .lookupFunction<_FPDFBitmap_DestroyNative, _FPDFBitmap_DestroyDart>(
            'FPDFBitmap_Destroy',
          ) {
    lib.lookupFunction<_FPDF_InitLibraryNative, void Function()>(
      'FPDF_InitLibrary',
    )();
  }

  static PdfiumBindings? _instance;

  /// One instance per process/isolate — see the comment on the class.
  factory PdfiumBindings.instance() =>
      _instance ??= PdfiumBindings._(loadPdfiumLibrary());

  final _FPDF_GetLastErrorDart _getLastError;
  final _FPDF_LoadMemDocumentDart _loadMemDocument;
  final _FPDF_CloseDocumentDart _closeDocument;
  final _FPDF_GetPageCountDart _getPageCount;
  final _FPDF_LoadPageDart _loadPage;
  final _FPDF_ClosePageDart _closePage;
  final _FPDFText_LoadPageDart _textLoadPage;
  final _FPDFText_ClosePageDart _textClosePage;
  final _FPDFText_CountCharsDart _textCountChars;
  final _FPDFText_GetFontSizeDart _textGetFontSize;
  final _FPDFText_GetTextDart _textGetText;
  final _FPDFText_GetCharBoxDart _textGetCharBox;
  final _FPDFPage_CountObjectsDart _pageCountObjects;
  final _FPDFPage_GetObjectDart _pageGetObject;
  final _FPDFPageObj_GetTypeDart _pageObjGetType;
  final _FPDF_GetPageSizeDart _getPageWidth;
  final _FPDF_GetPageSizeDart _getPageHeight;
  final _FPDFBitmap_CreateExDart _bitmapCreateEx;
  final _FPDFBitmap_FillRectDart _bitmapFillRect;
  final _FPDF_RenderPageBitmapDart _renderPageBitmap;
  final _FPDFBitmap_GetBufferNative _bitmapGetBuffer;
  final _FPDFBitmap_GetStrideDart _bitmapGetStride;
  final _FPDFBitmap_DestroyDart _bitmapDestroy;

  int getLastError() => _getLastError();

  Pointer<Void> loadMemDocument(Pointer<Void> dataBuf, int size) =>
      _loadMemDocument(dataBuf, size, Pointer.fromAddress(0));

  void closeDocument(Pointer<Void> document) => _closeDocument(document);

  int getPageCount(Pointer<Void> document) => _getPageCount(document);

  Pointer<Void> loadPage(Pointer<Void> document, int index) =>
      _loadPage(document, index);

  void closePage(Pointer<Void> page) => _closePage(page);

  Pointer<Void> textLoadPage(Pointer<Void> page) => _textLoadPage(page);

  void textClosePage(Pointer<Void> textPage) => _textClosePage(textPage);

  int textCountChars(Pointer<Void> textPage) => _textCountChars(textPage);

  double textGetFontSize(Pointer<Void> textPage, int index) =>
      _textGetFontSize(textPage, index);

  int textGetText(
    Pointer<Void> textPage,
    int startIndex,
    int count,
    Pointer<Uint16> result,
  ) => _textGetText(textPage, startIndex, count, result);

  bool textGetCharBox(
    Pointer<Void> textPage,
    int index,
    Pointer<Double> left,
    Pointer<Double> right,
    Pointer<Double> bottom,
    Pointer<Double> top,
  ) => _textGetCharBox(textPage, index, left, right, bottom, top) != 0;

  int pageCountObjects(Pointer<Void> page) => _pageCountObjects(page);

  Pointer<Void> pageGetObject(Pointer<Void> page, int index) =>
      _pageGetObject(page, index);

  int pageObjGetType(Pointer<Void> pageObject) => _pageObjGetType(pageObject);

  /// Page size in points (1/72 inch).
  double getPageWidth(Pointer<Void> page) => _getPageWidth(page);

  double getPageHeight(Pointer<Void> page) => _getPageHeight(page);

  /// A new BGRx bitmap owned by PDFium (`firstScan` = NULL).
  Pointer<Void> bitmapCreate(int width, int height) =>
      _bitmapCreateEx(width, height, fpdfBitmapBgrx, nullptr, 0);

  void bitmapFill(Pointer<Void> bitmap, int width, int height, int color) =>
      _bitmapFillRect(bitmap, 0, 0, width, height, color);

  void renderPageBitmap(
    Pointer<Void> bitmap,
    Pointer<Void> page,
    int width,
    int height,
  ) => _renderPageBitmap(bitmap, page, 0, 0, width, height, 0, fpdfRenderAnnot);

  Pointer<Uint8> bitmapBuffer(Pointer<Void> bitmap) => _bitmapGetBuffer(bitmap);

  int bitmapStride(Pointer<Void> bitmap) => _bitmapGetStride(bitmap);

  void bitmapDestroy(Pointer<Void> bitmap) => _bitmapDestroy(bitmap);
}
