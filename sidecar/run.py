"""Thin wrapper over the real markitdown: argv -> a single JSON object on stdout.

Invocation (protocol described in docs/python-sidecar.md):

    <dir>/python/bin/python3 -I -B <dir>/run.py --in <path> --format <id>

stdout is exactly one JSON `{"markdown": str, "title": str|null, "warnings": [...]}`,
everything else (library warnings, logs, tracebacks) goes to stderr only.
Exit codes: 0 success; 2 unsupported format; 3 corrupted file; 1 other.

The wrapper deliberately contains no conversion logic: the sidecar's value is
being a reference for "the real markitdown", and any tweak to the output here
would turn the reference into yet another implementation.
"""

import json
import logging
import os
import sys
import warnings

# Format (id from the app) -> extension hint for markitdown. A temp file
# can arrive without the right extension, and markitdown's converters pick
# themselves mainly by it. Keys must match FORMATS in build.sh.
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

# markitdown converter modules and the variable names where they stash the
# import error of an optional dependency (see _dependency_exc_info in the
# sources).
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
    # argparse exits with code 2 by default — but that's our "format not
    # supported". Bad arguments are code 1, so we parse by hand.
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
    """Writes JSON to the real stdout (the fd saved before it was swapped)."""
    text = json.dumps(payload, ensure_ascii=False)
    try:
        data = text.encode("utf-8")
    except UnicodeEncodeError:
        # Lone surrogates from corrupted documents: the ASCII variant with
        # \uXXXX stays valid JSON no matter the content.
        data = json.dumps(payload, ensure_ascii=True).encode("ascii")
    view = memoryview(data)
    while view:
        view = view[os.write(stdout_fd, view) :]


def _setup_paths():
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib")
    sys.path.insert(0, lib)


def _setup_diagnostics():
    """Anything the libraries want to say goes to stderr, not stdout.

    Returns the fd of the real stdout. fd 1 itself is redirected to stderr
    for the whole run: native extensions (onnxruntime under magika) write
    to it directly, bypassing sys.stdout, and no print interception would
    catch that.
    """
    stdout_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    logging.captureWarnings(True)
    warnings.simplefilter("default")
    return stdout_fd


def _self_check():
    """Checks the built tree: markitdown loads, dependencies are in place.

    Not a conversion run (fixtures exist for that), but a guarantee that the
    manifest isn't lying: a converter missing its dependency is silently
    skipped by markitdown.
    """
    import markitdown  # noqa: F401  (import error = build is bad)
    from importlib import import_module

    problems = []
    for fmt in FORMAT_EXTENSIONS:
        module_name, flag = _DEPENDENCY_FLAGS[fmt]
        exc_info = getattr(import_module(module_name), flag)
        if exc_info is not None:
            problems.append(f"{fmt}: {exc_info[1]!r}")
    # MarkItDown() loads the magika model via onnxruntime; identify_bytes
    # runs real inference. This is a build safety net: packages that
    # onnxruntime formally requires but is believed not to actually import
    # (sympy, mpmath) are stripped from lib/ — if that stops being true, the
    # build should fail, not the user on their first file.
    guess = markitdown.MarkItDown()._magika.identify_bytes(b"# hello\n\nworld\n")
    if guess.status != "ok":
        problems.append(f"magika: статус {guess.status}")
    # markitdown's tabular path (xlsx/xls) rests entirely on pandas.
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


# Formats whose code path in markitdown rests on pandas (read_excel + to_html).
_PANDAS_FORMATS = {"xlsx", "xls"}


def _convert(path, fmt):
    """Returns (payload, exit_code)."""
    if fmt not in _PANDAS_FORMATS:
        # markitdown imports ALL converters at once, and xlsx/xls pull in
        # pandas (~0.4s and ~35 MB RAM at startup). For pdf/docx/pptx/msg it
        # isn't needed at all (verified by grepping markitdown and
        # pdfplumber). `sys.modules[name] = None` is the standard way to say
        # "import will fail with ImportError": markitdown itself catches
        # this and simply marks the xlsx converters as unavailable.
        # markitdown's code and output don't change.
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
        # If every attempt failed on a missing dependency, that's a broken
        # build, not a corrupted file: telling the user "file is corrupted"
        # would be a lie.
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
    except Exception:  # noqa: BLE001 — any failure becomes code 1 + stderr
        import traceback

        traceback.print_exc(file=sys.stderr)
        return EXIT_OTHER


if __name__ == "__main__":
    code = main(sys.argv[1:])
    sys.stderr.flush()
    # os._exit isn't needed: a normal exit is enough, nobody waits on
    # onnxruntime's threads after conversion.
    sys.exit(code)
