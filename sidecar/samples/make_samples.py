"""Генератор фикстур, которые нельзя написать руками: .xls, .msg, валидный
.pptx и .xlsx с типами данных и пропусками, .pdf с таблицей.

Зачем: Dart-ядро не читает .xls и .msg, поэтому исходник пары «исходник +
ожидаемый Markdown» (core/test/fixtures/{xls,msg}/) берётся отсюда; .pptx,
написанный руками под Dart-парсер, настоящим python-pptx не открывается (нет
<p:spPr> в фигуре) и живёт как злая фикстура pptx/no_sppr.pptx, а валидный
pptx/simple.pptx порождается здесь. Образцы собираются скриптом, а не берутся
«откуда-то», чтобы их происхождение было воспроизводимо и объяснимо.
Ожидаемый Markdown для .xls/.msg — вывод сайдкара (других конвертеров нет),
для остальных — вывод Dart-ядра после сверки (make compare-sidecar).

Запуск (интерпретатором из собранного сайдкара; xlwt нужен только здесь, в
сайдкар не ставится — кладётся в отдельный каталог):

    python3 -m pip install --target /tmp/xlwt_lib xlwt    # любой Python, только скачать xlwt
    sidecar/dist/<host>/python/bin/python3 -I sidecar/samples/make_samples.py \
        --lib sidecar/dist/<host>/lib --extra-path /tmp/xlwt_lib

Без xlwt можно собрать остальное: `--only pptx xlsx msg pdf` (тогда --extra-path
не нужен). Результат — файлы в core/test/fixtures/. Это синтетика: .msg собран ниже простым
писателем CFB, а не Outlook'ом, так что он проверяет путь olefile ->
OutlookMsgConverter, но не разнообразие настоящих писем.
"""

import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.normpath(os.path.join(HERE, "..", "..", "core", "test", "fixtures"))

ENDOFCHAIN = 0xFFFFFFFE
FATSECT = 0xFFFFFFFD
FREESECT = 0xFFFFFFFF
NOSTREAM = 0xFFFFFFFF


# --- минимальный писатель Compound File Binary (v3, сектор 512, мини 64) -----


def _dir_entry(name, kind, left, right, child, start, size):
    raw = name.encode("utf-16-le")
    assert len(raw) + 2 <= 64
    entry = raw + b"\x00" * (64 - len(raw))
    entry += struct.pack("<H", len(raw) + 2)
    entry += struct.pack("<BB", kind, 1)  # тип, цвет «чёрный» (олефайл не проверяет)
    entry += struct.pack("<III", left, right, child)
    entry += b"\x00" * 16 + b"\x00" * 4 + b"\x00" * 16  # CLSID, state, времена
    entry += struct.pack("<IQ", start, size)
    assert len(entry) == 128
    return entry


def build_cfb(streams, storages):
    """streams: {имя: bytes}; storages: [имя] (пустые). Всё — прямые дети корня."""
    SECTOR, MINI, CUTOFF = 512, 64, 4096

    # Порядок записей в каталоге: по длине имени, затем по имени (требование
    # спецификации к дереву); дерево делаем вырожденным — цепочка правых братьев.
    names = sorted(list(streams) + list(storages), key=lambda n: (len(n), n.upper()))
    index = {n: i + 1 for i, n in enumerate(names)}  # 0 — корень

    # Мини-поток: маленькие потоки склеиваются по 64 байта, цепочки — в miniFAT.
    mini_data = bytearray()
    mini_fat = []
    mini_start = {}
    for n in names:
        if n in streams and len(streams[n]) < CUTOFF:
            data = streams[n]
            count = max(1, -(-len(data) // MINI))
            first = len(mini_fat)
            mini_start[n] = first
            for i in range(count):
                mini_fat.append(first + i + 1 if i < count - 1 else ENDOFCHAIN)
            mini_data += data + b"\x00" * (count * MINI - len(data))

    def sectors_for(size):
        return -(-size // SECTOR)

    n_dir = sectors_for(128 * (len(names) + 1))
    mini_fat_bytes = b"".join(struct.pack("<I", x) for x in mini_fat)
    n_minifat = sectors_for(len(mini_fat_bytes)) if mini_fat else 0
    n_mini = sectors_for(len(mini_data)) if mini_data else 0
    large = {n: streams[n] for n in names if n in streams and len(streams[n]) >= CUTOFF}
    n_large = {n: sectors_for(len(d)) for n, d in large.items()}

    # Раскладка секторов: [FAT][каталог][miniFAT][мини-поток][большие потоки].
    total = 1 + n_dir + n_minifat + n_mini + sum(n_large.values())
    assert total <= 128, "образец должен помещаться в один сектор FAT"
    pos = 1
    dir_start = pos
    pos += n_dir
    minifat_start = pos if n_minifat else ENDOFCHAIN
    pos += n_minifat
    ministream_start = pos if n_mini else ENDOFCHAIN
    pos += n_mini
    large_start = {}
    for n in large:
        large_start[n] = pos
        pos += n_large[n]

    fat = [FREESECT] * 128
    fat[0] = FATSECT

    def chain(first, count):
        for i in range(count):
            fat[first + i] = first + i + 1 if i < count - 1 else ENDOFCHAIN

    chain(dir_start, n_dir)
    if n_minifat:
        chain(minifat_start, n_minifat)
    if n_mini:
        chain(ministream_start, n_mini)
    for n, first in large_start.items():
        chain(first, n_large[n])

    entries = [
        _dir_entry(
            "Root Entry", 5, NOSTREAM, NOSTREAM, index[names[0]],
            ministream_start, len(mini_data),
        )
    ]
    for i, n in enumerate(names):
        right = index[names[i + 1]] if i + 1 < len(names) else NOSTREAM
        if n in storages:
            entries.append(_dir_entry(n, 1, NOSTREAM, right, NOSTREAM, 0, 0))
        elif n in large:
            entries.append(_dir_entry(n, 2, NOSTREAM, right, NOSTREAM, large_start[n], len(large[n])))
        else:
            entries.append(_dir_entry(n, 2, NOSTREAM, right, NOSTREAM, mini_start[n], len(streams[n])))
    dir_bytes = b"".join(entries)
    # Свободные слоты каталога: нули, но sid-ы левого/правого/дочернего — NOSTREAM.
    empty = b"\x00" * 68 + struct.pack("<III", NOSTREAM, NOSTREAM, NOSTREAM) + b"\x00" * 48
    while len(dir_bytes) < n_dir * SECTOR:
        dir_bytes += empty

    def pad(b):
        return b + b"\x00" * (-len(b) % SECTOR)

    header = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 16
    header += struct.pack("<HHHHH", 0x3E, 3, 0xFFFE, 9, 6) + b"\x00" * 6
    header += struct.pack("<I", 0)  # число секторов каталога (для v3 — 0)
    header += struct.pack("<I", 1)  # число секторов FAT
    header += struct.pack("<I", dir_start)
    header += struct.pack("<I", 0)  # transaction signature
    header += struct.pack("<I", CUTOFF)
    header += struct.pack("<II", minifat_start, n_minifat)
    header += struct.pack("<II", ENDOFCHAIN, 0)  # DIFAT: нет
    difat = [0] + [FREESECT] * 108
    header += b"".join(struct.pack("<I", x) for x in difat)
    assert len(header) == SECTOR

    body = pad(b"".join(struct.pack("<I", x) for x in fat))
    body += dir_bytes
    if n_minifat:
        body += pad(mini_fat_bytes)
    if n_mini:
        body += pad(bytes(mini_data))
    for n in large:
        body += pad(large[n])
    return header + body


def make_msg(path):
    def u(text):
        return text.encode("utf-16-le")

    # Заголовок свойств верхнего уровня — 32 байта; затем записи по 16 байт.
    # Одна запись: PR_MESSAGE_CODEPAGE (0x3FFD, PT_LONG) = 1252.
    props = b"\x00" * 32 + struct.pack("<IIII", 0x3FFD0003, 0x6, 1252, 0)
    streams = {
        "__properties_version1.0": props,
        "__substg1.0_0037001F": u("Квартальный отчёт: черновик"),  # PR_SUBJECT
        "__substg1.0_0C1F001F": u("ivan@example.com"),  # PR_SENDER_EMAIL_ADDRESS
        "__substg1.0_0E04001F": u("Мария Петрова"),  # PR_DISPLAY_TO
        "__substg1.0_1000001F": u(  # PR_BODY
            "Добрый день!\r\n\r\nВо вложении черновик отчёта. Hello, world.\r\n"
        ),
    }
    storages = ["__recip_version1.0_#00000000"]
    with open(path, "wb") as fh:
        fh.write(build_cfb(streams, storages))


def make_xls(path):
    import xlwt  # только для генерации; в сайдкар не ставится

    wb = xlwt.Workbook(encoding="utf-8")
    ws = wb.add_sheet("Данные")
    for col, head in enumerate(["Город", "Население", "Доля"]):
        ws.write(0, col, head)
    rows = [("Berlin", 1000000, 0.25), ("Paris", 2000000, 0.5), ("Москва", 3000000, 0.75)]
    for r, (city, pop, share) in enumerate(rows, start=1):
        ws.write(r, 0, city)
        ws.write(r, 1, pop)
        ws.write(r, 2, share)
    ws2 = wb.add_sheet("Второй")
    ws2.write(0, 0, "a")
    ws2.write(0, 1, "b")
    ws2.write(1, 0, 1)
    wb.save(path)


def make_pptx(path):
    from pptx import Presentation

    prs = Presentation()
    s1 = prs.slides.add_slide(prs.slide_layouts[0])
    s1.shapes.title.text = "Заголовок презентации"
    s1.placeholders[1].text = "Подзаголовок"
    s2 = prs.slides.add_slide(prs.slide_layouts[1])
    s2.shapes.title.text = "Второй слайд"
    s2.placeholders[1].text = "Первый пункт\nВторой пункт"
    s2.notes_slide.notes_text_frame.text = "Заметка докладчика"
    prs.save(path)


def make_xlsx_types(path):
    """Типы данных и пропуски: то, на чём расходятся pandas и наш разбор."""
    import datetime

    from openpyxl import Workbook

    wb = Workbook()
    ws = wb.active
    ws.title = "Типы"
    ws.append(["Название", "Цена", "Дата", "Флаг", "Заметка"])
    ws.append(["Яблоко", 0.5, datetime.date(2024, 3, 1), True, "свежее"])
    ws.append(["Груша", 2.0, datetime.date(2024, 3, 2), False, None])
    ws.append([None, 3, None, True, "пустое название | с вертикальной чертой"])
    ws.append(["Слива", 1234567.891, datetime.date(2024, 3, 4), None, "две\nстроки"])
    ws.append(["Вишня", 7, datetime.datetime(2024, 3, 5, 13, 30), True, "дата со временем"])
    ws2 = wb.create_sheet("Пустой")
    ws3 = wb.create_sheet("Второй")
    ws3.append(["x", "y"])
    ws3.append([1, 2])
    wb.save(path)


def make_pdf_table(path):
    """PDF с таблицей: линии сетки и текст по колонкам (Helvetica, без шрифтов
    в файле). Нужен, чтобы отставание Dart-ядра на таблицах PDF было
    зафиксировано фикстурой, а не словами."""
    rows = [
        ["City", "Population", "Country"],
        ["Berlin", "3700000", "Germany"],
        ["Paris", "2100000", "France"],
        ["Madrid", "3300000", "Spain"],
    ]
    left, top, col_w, row_h = 72, 700, [120, 120, 120], 24
    ops = ["BT /F1 14 Tf 72 740 Td (Cities) Tj ET"]
    width, height = sum(col_w), row_h * len(rows)
    for r in range(len(rows) + 1):
        y = top - r * row_h
        ops.append(f"{left} {y} m {left + width} {y} l S")
    x = left
    for w in [0] + col_w:
        x += w
        ops.append(f"{x} {top} m {x} {top - height} l S")
    for r, row in enumerate(rows):
        x = left
        for c, text in enumerate(row):
            ops.append(f"BT /F1 12 Tf {x + 6} {top - r * row_h - 16} Td ({text}) Tj ET")
            x += col_w[c]
    stream = "\n".join(ops).encode("latin-1")
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    with open(path, "wb") as fh:
        fh.write(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True, help="site-packages сайдкара (python-pptx, openpyxl)")
    ap.add_argument("--extra-path", help="каталог с xlwt (нужен только для xls)")
    ap.add_argument(
        "--only", nargs="+", choices=["xls", "msg", "pptx", "xlsx", "pdf"],
        default=["xls", "msg", "pptx", "xlsx", "pdf"],
    )
    args = ap.parse_args()
    sys.path[:0] = [args.lib] + ([args.extra_path] if args.extra_path else [])

    jobs = {
        "xls": (make_xls, "xls/simple.xls"),
        "msg": (make_msg, "msg/simple.msg"),
        "pptx": (make_pptx, "pptx/simple.pptx"),
        "xlsx": (make_xlsx_types, "xlsx/types_and_gaps.xlsx"),
        "pdf": (make_pdf_table, "pdf/table.pdf"),
    }
    for key in args.only:
        make, rel = jobs[key]
        path = os.path.join(FIXTURES, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        make(path)
        print(rel, os.path.getsize(path), "байт")


if __name__ == "__main__":
    main()
