/// Свои минимальные FFI-биндинги на PDFium — только то, что нужно для
/// извлечения текста (не полный API). Решение в пользу PDFium через FFI, а
/// не `syncfusion_flutter_pdf`, зафиксировано в
/// `docs/format-coverage.md#решения-этапа-3`: `core/` не имеет права
/// импортировать `flutter/`, а FFI, в отличие от плагина платформы, работает
/// и внутри `Isolate.run` — см. `docs/client-architecture.md#конвертация-в-изоляте`.
///
/// Нативную библиотеку в это дерево не коммитим — её качает `pdfium/fetch.sh`
/// (как `python-build-standalone` для сайдкара, см. `docs/python-sidecar.md`).
///
/// Имена типов ниже повторяют `fpdfview.h`/`fpdf_text.h`/`fpdf_edit.h`
/// буквально — это упрощает сверку с сигнатурами PDFium, а не ошибка стиля.
// ignore_for_file: camel_case_types
library;

import 'dart:ffi';
import 'dart:io';

/// Находит и открывает `libpdfium`. Порядок источников:
///
/// 1. `MARKITDOWN_PDFIUM_PATH` — явный путь, нужен для `dart test` и для
///    любой машины, где библиотека лежит не в стандартном месте платформы.
/// 2. Голое имя библиотеки — рабочий случай для Android: `.so` лежит в
///    `jniLibs/<abi>/` и попадает на путь поиска процесса сам, без нашего
///    участия. И для Windows: `pdfium.dll` кладётся рядом с `.exe` правилом
///    `install(...)` в `app/windows/CMakeLists.txt`, а каталог исполняемого
///    файла `LoadLibrary` смотрит первым.
///
/// macOS-приложение (бандл из `flutter build macos`) сюда пока не попадает —
/// см. «Ограничения среды» в `../../../../../AGENTS.md`: пока нет Xcode,
/// запускать и проверять эту ветку негде. Когда он появится, здесь
/// добавится путь вида `Frameworks/libpdfium.dylib` относительно
/// `Platform.resolvedExecutable`.
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

/// `FPDF_PAGEOBJ_IMAGE` из `fpdf_edit.h` — значение части публичного ABI,
/// не меняется между релизами PDFium.
const fpdfPageObjImage = 3;

/// Тонкая обёртка над нужным подмножеством `fpdfview.h`/`fpdf_text.h`/
/// `fpdf_edit.h`. Один процесс — одна инициализация библиотеки: PDFium не
/// поддерживает повторный `FPDF_InitLibrary`/`FPDF_DestroyLibrary` на лету
/// без риска гонки между изолятами, поэтому инициализируем один раз и не
/// деинициализируем вовсе — процесс конвертации всё равно короткоживущий
/// (`Isolate.run`).
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
          ) {
    lib.lookupFunction<_FPDF_InitLibraryNative, void Function()>(
      'FPDF_InitLibrary',
    )();
  }

  static PdfiumBindings? _instance;

  /// Один экземпляр на процесс/изолят — см. комментарий у класса.
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
}
