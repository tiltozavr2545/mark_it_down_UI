"""Тонкая обёртка над настоящим markitdown: argv -> один JSON-объект на stdout.

Запуск (протокол описан в docs/python-sidecar.md):

    <dir>/python/bin/python3 -I -B <dir>/run.py --in <path> --format <id>

stdout — ровно один JSON `{"markdown": str, "title": str|null, "warnings": [...]}`,
всё остальное (предупреждения библиотек, логи, трейсбеки) — только stderr.
Коды выхода: 0 успех; 2 формат не поддерживается; 3 битый файл; 1 прочее.

Обёртка намеренно не содержит логики конвертации: сайдкар ценен как эталон
«настоящего markitdown», и любая правка вывода здесь превратила бы эталон в
ещё одну реализацию.
"""

import json
import logging
import os
import sys
import warnings

# Формат (id из приложения) -> расширение-подсказка для markitdown. Временный
# файл может прийти без правильного расширения, а конвертеры markitdown выбирают
# себя прежде всего по нему. Ключи обязаны совпадать с FORMATS в build.sh.
FORMAT_EXTENSIONS = {
    "pdf": ".pdf",
    "docx": ".docx",
    "xlsx": ".xlsx",
    "xls": ".xls",
    "pptx": ".pptx",
    "msg": ".msg",
}

EXIT_OK = 0
EXIT_OTHER = 1
EXIT_UNSUPPORTED = 2
EXIT_BROKEN = 3

# Модули конвертеров markitdown и имена переменных, где они прячут ошибку
# импорта необязательной зависимости (см. _dependency_exc_info в исходниках).
_DEPENDENCY_FLAGS = {
    "pdf": ("markitdown.converters._pdf_converter", "_dependency_exc_info"),
    "docx": ("markitdown.converters._docx_converter", "_dependency_exc_info"),
    "xlsx": ("markitdown.converters._xlsx_converter", "_xlsx_dependency_exc_info"),
    "xls": ("markitdown.converters._xlsx_converter", "_xls_dependency_exc_info"),
    "pptx": ("markitdown.converters._pptx_converter", "_dependency_exc_info"),
    "msg": (
        "markitdown.converters._outlook_msg_converter",
        "_dependency_exc_info",
    ),
}


def _err(message):
    print(f"run.py: {message}", file=sys.stderr, flush=True)


def _parse_args(argv):
    # argparse по умолчанию выходит с кодом 2 — а это у нас «формат не
    # поддерживается». Неверные аргументы — код 1, поэтому разбираем руками.
    args = {"in": None, "format": None, "self_check": False}
    it = iter(argv)
    for arg in it:
        if arg in ("--in", "--format"):
            value = next(it, None)
            if value is None:
                raise ValueError(f"{arg} требует значение")
            args[arg[2:]] = value
        elif arg.startswith("--in=") or arg.startswith("--format="):
            key, _, value = arg[2:].partition("=")
            args[key] = value
        elif arg == "--self-check":
            args["self_check"] = True
        else:
            raise ValueError(f"неизвестный аргумент: {arg}")
    if not args["self_check"] and (args["in"] is None or args["format"] is None):
        raise ValueError("нужны оба аргумента: --in <path> --format <id>")
    return args


def _emit(stdout_fd, payload):
    """Пишет JSON в настоящий stdout (fd, сохранённый до подмены)."""
    text = json.dumps(payload, ensure_ascii=False)
    try:
        data = text.encode("utf-8")
    except UnicodeEncodeError:
        # Одинокие суррогаты из битых документов: ASCII-вариант с \uXXXX
        # остаётся валидным JSON при любом содержимом.
        data = json.dumps(payload, ensure_ascii=True).encode("ascii")
    view = memoryview(data)
    while view:
        view = view[os.write(stdout_fd, view) :]


def _setup_paths():
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib")
    sys.path.insert(0, lib)


def _setup_diagnostics():
    """Всё, что библиотеки захотят сказать, — в stderr, а не в stdout.

    Возвращает fd настоящего stdout. Сам fd 1 перенаправляется на stderr на
    всё время работы: нативные расширения (onnxruntime у magika) пишут в него
    напрямую, минуя sys.stdout, и никакой print-перехват это не поймает.
    """
    stdout_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    logging.captureWarnings(True)
    warnings.simplefilter("default")
    return stdout_fd


def _self_check():
    """Проверка собранного дерева: markitdown грузится, зависимости на месте.

    Не прогон конвертации (для этого фикстуры), а гарантия, что manifest не
    врёт: конвертер без своей зависимости markitdown молча пропускает.
    """
    import markitdown  # noqa: F401  (ошибка импорта = сборка негодная)
    from importlib import import_module

    problems = []
    for fmt in FORMAT_EXTENSIONS:
        module_name, flag = _DEPENDENCY_FLAGS[fmt]
        exc_info = getattr(import_module(module_name), flag)
        if exc_info is not None:
            problems.append(f"{fmt}: {exc_info[1]!r}")
    # MarkItDown() загружает модель magika через onnxruntime; identify_bytes
    # гоняет настоящий инференс. Это страховка сборки: из lib/ вычищаются
    # пакеты, которые onnxruntime формально требует, но, как считается, не
    # импортирует (sympy, mpmath) — если это перестанет быть правдой, упасть
    # должна сборка, а не пользователь на первом файле.
    guess = markitdown.MarkItDown()._magika.identify_bytes(b"# hello\n\nworld\n")
    if guess.status != "ok":
        problems.append(f"magika: статус {guess.status}")
    # Табличный путь markitdown (xlsx/xls) целиком стоит на pandas.
    import pandas

    pandas.DataFrame({"a": [1]}).to_html(index=False)

    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest.json")
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as fh:
            manifest_formats = set(json.load(fh)["formats"])
        if manifest_formats != set(FORMAT_EXTENSIONS):
            problems.append(
                f"manifest.formats {sorted(manifest_formats)} != "
                f"FORMAT_EXTENSIONS {sorted(FORMAT_EXTENSIONS)}"
            )
    if problems:
        for p in problems:
            _err(f"самопроверка: {p}")
        return EXIT_OTHER
    _err("самопроверка: ок")
    return EXIT_OK


# Форматы, чей путь кода в markitdown стоит на pandas (read_excel + to_html).
_PANDAS_FORMATS = {"xlsx", "xls"}


def _convert(path, fmt):
    """Возвращает (payload, exit_code)."""
    if fmt not in _PANDAS_FORMATS:
        # markitdown импортирует ВСЕ конвертеры разом, а xlsx/xls тянут pandas
        # (~0,4 с и ~35 МБ ОЗУ на старте). Для pdf/docx/pptx/msg он
        # не нужен вообще (проверено grep'ом по markitdown и pdfplumber).
        # `sys.modules[name] = None` — штатный способ сказать «import упадёт
        # с ImportError»: markitdown сам ловит это и просто помечает xlsx-
        # конвертеры как недоступные. Код и вывод markitdown не меняются.
        sys.modules["pandas"] = None  # type: ignore[assignment]
    from markitdown import MarkItDown, StreamInfo
    from markitdown import (
        FileConversionException,
        MissingDependencyException,
        UnsupportedFormatException,
    )

    try:
        result = MarkItDown().convert_local(
            path, stream_info=StreamInfo(extension=FORMAT_EXTENSIONS[fmt])
        )
    except UnsupportedFormatException as exc:
        _err(f"формат не поддерживается: {exc}")
        return None, EXIT_UNSUPPORTED
    except FileConversionException as exc:
        attempts = exc.attempts or []
        # Если все попытки упали на отсутствующей зависимости — это сломанная
        # сборка, а не битый файл: пользователю «файл повреждён» было бы ложью.
        if attempts and all(
            isinstance(a.exc_info[1], MissingDependencyException)
            for a in attempts
            if a.exc_info is not None
        ):
            _err(f"в сборке не хватает зависимости: {exc}")
            return None, EXIT_OTHER
        _err(f"не удалось разобрать файл: {exc}")
        return None, EXIT_BROKEN
    except MissingDependencyException as exc:
        _err(f"в сборке не хватает зависимости: {exc}")
        return None, EXIT_OTHER

    markdown = result.markdown or ""
    out_warnings = []
    if not markdown.strip():
        out_warnings.append("результат пуст")
    return {
        "markdown": markdown,
        "title": result.title,
        "warnings": out_warnings,
    }, EXIT_OK


def main(argv):
    try:
        args = _parse_args(argv)
    except ValueError as exc:
        _err(str(exc))
        return EXIT_OTHER

    if not args["self_check"] and args["format"] not in FORMAT_EXTENSIONS:
        _err(f"неизвестный формат: {args['format']}")
        return EXIT_UNSUPPORTED

    stdout_fd = _setup_diagnostics()
    _setup_paths()

    try:
        if args["self_check"]:
            return _self_check()
        if not os.path.isfile(args["in"]):
            _err(f"нет такого файла: {args['in']}")
            return EXIT_OTHER
        payload, code = _convert(args["in"], args["format"])
        if payload is not None:
            _emit(stdout_fd, payload)
        return code
    except Exception:  # noqa: BLE001 — любой сбой превращаем в код 1 + stderr
        import traceback

        traceback.print_exc(file=sys.stderr)
        return EXIT_OTHER


if __name__ == "__main__":
    code = main(sys.argv[1:])
    sys.stderr.flush()
    # os._exit не нужен: обычного выхода достаточно, потоков onnxruntime после
    # конвертации никто не ждёт.
    sys.exit(code)
