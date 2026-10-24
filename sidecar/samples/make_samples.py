"""Generator for fixtures that can't be written by hand: .xls, .msg, a valid
.pptx and .xlsx with data types and gaps, a .pdf with a table, images with
real EXIF (Pillow) and an evil JPEG with a loop in the IFD, audio with tags
(libsndfile via soundfile + mutagen).

Why: .xls and .msg can't be written by hand, so the source of the "source +
expected Markdown" pair (core/test/fixtures/{xls,msg}/) comes from here;
a .pptx handwritten for the Dart parser doesn't open in real python-pptx
(no <p:spPr> in the shape) and lives on as the evil fixture
pptx/no_sppr.pptx, while the valid pptx/simple.pptx is generated here.
Samples are built by a script rather than sourced "from somewhere" so their
origin is reproducible and explainable. The expected Markdown for
xls/simple.xls and msg/simple.msg is the sidecar's output (the integration
test's reference), for the rest it's the Dart core's output after review
(make compare-sidecar).

Invocation (with the interpreter from the built sidecar; xlwt is only
needed here, it isn't installed into the sidecar — it's placed in a
separate directory):

    python3 -m pip install --target /tmp/xlwt_lib xlwt    # any Python, just to download xlwt
    sidecar/dist/<host>/python/bin/python3 -I sidecar/samples/make_samples.py \
        --lib sidecar/dist/<host>/lib --extra-path /tmp/xlwt_lib

Without xlwt you can still build the rest: `--only pptx xlsx msg pdf image`
(then --extra-path isn't needed). `audio` requires soundfile and mutagen —
install them, like xlwt, into a separate directory and pass via
--extra-path:

    python3 -m pip install --target /tmp/audio_lib --python-version 3.12 \
        --only-binary=:all: --no-deps soundfile mutagen

M4A is produced by the system `afconvert` (macOS only). `image` on macOS
also produces HEIC via the system `sips` (Pillow doesn't write HEIC); on
another OS photo.heic simply isn't regenerated. The result is files under
core/test/fixtures/. This is synthetic: .msg is assembled below by a plain
CFB writer, not by Outlook, so it exercises the olefile ->
OutlookMsgConverter path, but not the variety of real messages.
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


# --- minimal Compound File Binary writer (v3, 512-byte sectors, 64-byte mini) ---


def _dir_entry(name, kind, left, right, child, start, size):
    raw = name.encode("utf-16-le")
    assert len(raw) + 2 <= 64
    entry = raw + b"\x00" * (64 - len(raw))
    entry += struct.pack("<H", len(raw) + 2)
    entry += struct.pack("<BB", kind, 1)  # type, color "black" (olefile doesn't check)
    entry += struct.pack("<III", left, right, child)
    entry += b"\x00" * 16 + b"\x00" * 4 + b"\x00" * 16  # CLSID, state, timestamps
    entry += struct.pack("<IQ", start, size)
    assert len(entry) == 128
    return entry


def build_cfb(streams, storages):
    """streams: {name: bytes}; storages: [name] (empty). Everything is a
    direct child of the root."""
    SECTOR, MINI, CUTOFF = 512, 64, 4096

    # Order of directory entries: by name length, then by name (a
    # specification requirement for the tree); we make the tree degenerate —
    # a chain of right siblings.
    names = sorted(list(streams) + list(storages), key=lambda n: (len(n), n.upper()))
    index = {n: i + 1 for i, n in enumerate(names)}  # 0 is the root

    # The mini stream: small streams are glued together in 64-byte chunks,
    # their chains go into the miniFAT.
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

    # Sector layout: [FAT][directory][miniFAT][mini stream][large streams].
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
    # Free directory slots: zeros, but the left/right/child sids are NOSTREAM.
    empty = b"\x00" * 68 + struct.pack("<III", NOSTREAM, NOSTREAM, NOSTREAM) + b"\x00" * 48
    while len(dir_bytes) < n_dir * SECTOR:
        dir_bytes += empty

    def pad(b):
        return b + b"\x00" * (-len(b) % SECTOR)

    header = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 16
    header += struct.pack("<HHHHH", 0x3E, 3, 0xFFFE, 9, 6) + b"\x00" * 6
    header += struct.pack("<I", 0)  # number of directory sectors (0 for v3)
    header += struct.pack("<I", 1)  # number of FAT sectors
    header += struct.pack("<I", dir_start)
    header += struct.pack("<I", 0)  # transaction signature
    header += struct.pack("<I", CUTOFF)
    header += struct.pack("<II", minifat_start, n_minifat)
    header += struct.pack("<II", ENDOFCHAIN, 0)  # DIFAT: none
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

    # Top-level properties header — 32 bytes; followed by 16-byte entries.
    # One entry: PR_MESSAGE_CODEPAGE (0x3FFD, PT_LONG) = 1252.
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


def make_msg_ansi(path):
    """A message in the old, non-Unicode format: PT_STRING8 (001E) strings
    in the message's codepage (PR_MESSAGE_CODEPAGE = 1251), with a body
    longer than 4096 bytes — stored in regular sectors, not the mini
    stream."""
    props = b"\x00" * 32 + struct.pack("<IIII", 0x3FFD0003, 0x6, 1251, 0)
    paragraph = "Строка тела письма с кириллицей и пробелами в конце.   \r\n"
    body = "Здравствуйте!\r\n\r\n\r\n\r\n" + paragraph * 90 + "До свидания.\r\n"
    streams = {
        "__properties_version1.0": props,
        "__substg1.0_0037001E": "Счёт № 15 за октябрь".encode("cp1251") + b"\x00",
        "__substg1.0_0C1F001E": "buh@example.ru".encode("cp1251") + b"\x00",
        "__substg1.0_0E04001E": "Бухгалтерия; Иван Петров".encode("cp1251") + b"\x00",
        "__substg1.0_1000001E": body.encode("cp1251") + b"\x00",
    }
    assert len(streams["__substg1.0_1000001E"]) >= 4096
    storages = ["__recip_version1.0_#00000000", "__recip_version1.0_#00000001"]
    with open(path, "wb") as fh:
        fh.write(build_cfb(streams, storages))


def make_msg_html(path):
    """Body in HTML only (PR_HTML, PT_BINARY): markitdown returns an empty
    section, the Dart core returns the HTML converted to Markdown."""
    props = b"\x00" * 32 + struct.pack("<IIII", 0x3FDE0003, 0x6, 65001, 0)
    html = (
        "<html><body><h1>Новости</h1><p>Первый <b>абзац</b> и "
        '<a href="https://example.com">ссылка</a>.</p>'
        "<ul><li>пункт один</li><li>пункт два</li></ul></body></html>"
    )
    streams = {
        "__properties_version1.0": props,
        "__substg1.0_0037001F": "Рассылка".encode("utf-16-le"),
        "__substg1.0_0C1F001F": "news@example.com".encode("utf-16-le"),
        "__substg1.0_10130102": html.encode("utf-8"),
    }
    with open(path, "wb") as fh:
        fh.write(build_cfb(streams, ["__recip_version1.0_#00000000"]))


def make_xls(path):
    import xlwt  # generation only; not installed into the sidecar

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


def make_xls_evil(path):
    """What breaks a handwritten BIFF8 parser: an SST string table longer
    than one record (continuation in CONTINUE, a split mid-character, and a
    string that's sometimes compressed Latin-1, sometimes UTF-16),
    dates/times/booleans, RK and IEEE numbers, merged cells, an empty
    sheet, Markdown markup in the text."""
    import datetime

    import xlwt  # generation only; not installed into the sidecar

    wb = xlwt.Workbook(encoding="utf-8")

    ws = wb.add_sheet("Строки")
    for r in range(120):
        # Alternating Latin-1-only strings (xlwt writes them compressed)
        # and Cyrillic (UTF-16) ones — the compression flag flips at the
        # CONTINUE boundary.
        latin = "latin %03d " % r + "x" * (40 + r % 17)
        cyrillic = "строка %03d " % r + "я" * (30 + r % 13)
        ws.write(r, 0, latin)
        ws.write(r, 1, cyrillic)

    ws = wb.add_sheet("Типы")
    date = xlwt.easyxf(num_format_str="YYYY-MM-DD")
    stamp = xlwt.easyxf(num_format_str="YYYY-MM-DD HH:MM:SS")
    clock = xlwt.easyxf(num_format_str="HH:MM:SS")
    rows = [
        ("Дата", datetime.date(2024, 3, 1), date),
        ("Дата и время", datetime.datetime(2024, 3, 5, 13, 30), stamp),
        ("Время", datetime.time(8, 15, 30), clock),
        ("Правда", True, None),
        ("Ложь", False, None),
        ("Целое (RK)", 42, None),
        ("Отрицательное", -7, None),
        ("Дробное", 0.1, None),
        ("Большое", 12345678901234.5, None),
        ("Сотые (RK ×100)", 1.25, None),
        ("Разметка", "a | b *c* [d]", None),
        ("Две строки", "первая\nвторая", None),
    ]
    for r, (label, value, style) in enumerate(rows):
        ws.write(r, 0, label)
        if style is None:
            ws.write(r, 1, value)
        else:
            ws.write(r, 1, value, style)

    ws = wb.add_sheet("Объединения")
    ws.write_merge(0, 0, 0, 2, "Шапка на три столбца")
    ws.write(1, 0, "a")
    ws.write(1, 1, "b")
    ws.write(1, 2, "c")
    ws.write_merge(2, 3, 0, 0, "две строки")
    ws.write(2, 1, 1)
    ws.write(3, 1, 2)

    wb.add_sheet("Пустой")
    wb.save(path)


def make_xls_biff5(path):
    """Excel 95 (BIFF5, the `Book` stream): single-byte strings in the
    workbook's codepage (CODEPAGE = 1251), not UTF-16. xlwt doesn't write
    BIFF5 — the records are assembled by hand; xlrd reads them, which is
    exactly what this sample tests."""

    def rec(rid, data=b""):
        return struct.pack("<HH", rid, len(data)) + data

    def bof(kind):
        return rec(0x0809, struct.pack("<HHHH", 0x0500, kind, 0x0DBB, 0x07CC))

    def label(row, col, text):
        raw = text.encode("cp1251")
        return rec(0x0204, struct.pack("<HHHH", row, col, 0x0F, len(raw)) + raw)

    def number(row, col, value):
        return rec(0x0203, struct.pack("<HHHd", row, col, 0x0F, value))

    # 16 XF: xlrd expects at least a default style at index 15.
    xf = rec(0x00E0, struct.pack("<HHHBBBBII", 0, 0, 0xFFF5, 0x20, 0, 0, 0, 0, 0))
    font = rec(0x0031, struct.pack("<HHHHHBBBB", 200, 0, 0x7FFF, 400, 0, 0, 0, 0, 0) + b"\x05Arial")
    sheet_name = "Лист".encode("cp1251")

    globals_head = bof(0x0005) + rec(0x0042, struct.pack("<H", 1251)) + font * 5 + xf * 16
    boundsheet_len = 4 + 4 + 1 + 1 + 1 + len(sheet_name)  # record header + fields
    sheet_offset = len(globals_head) + boundsheet_len + 4  # + EOF
    globals_ = globals_head + rec(
        0x0085, struct.pack("<IBBB", sheet_offset, 0, 0, len(sheet_name)) + sheet_name
    ) + rec(0x000A)
    sheet = (
        bof(0x0010)
        + label(0, 0, "Город")
        + label(0, 1, "Население")
        + label(1, 0, "Москва")
        + number(1, 1, 13010112)
        + label(2, 0, "Санкт-Петербург")
        + number(2, 1, 5601911.5)
        + rec(0x000A)
    )
    stream = globals_ + sheet
    stream += b"\x00" * max(0, 4096 - len(stream))  # not the mini stream: this is how Excel writes it
    with open(path, "wb") as fh:
        fh.write(build_cfb({"Book": stream}, []))


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
    """Data types and gaps: where pandas and our parsing diverge."""
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
    """A PDF with a table: grid lines and text laid out in columns
    (Helvetica, no fonts embedded in the file). Needed so that the Dart
    core's gap on PDF tables is pinned down by a fixture, not just words."""
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


# --- images (Stage 6, EXIF) -------------------------------------------------


def _photo_exif():
    """EXIF "as from a camera": everything ImageConverter reads, including
    GPS, UTF-8 Cyrillic (how phones and Windows write it), and markup
    characters."""
    from PIL import Image
    from PIL.TiffImagePlugin import IFDRational

    exif = Image.Exif()
    exif[0x010F] = "Canon"  # Make
    exif[0x0110] = "Canon EOS 5D Mark IV"  # Model
    exif[0x0112] = 6  # Orientation: rotate 90° clockwise
    exif[0x0131] = "Firmware 1.2.3"  # Software
    exif[0x010E] = "Закат над *рекой* | вид с моста".encode("utf-8")  # ImageDescription
    exif[0x013B] = "Иван Петров".encode("utf-8")  # Artist
    exif[0x8298] = "(c) 2024 Иван Петров".encode("utf-8")  # Copyright
    details = exif.get_ifd(0x8769)
    details[0x9003] = "2024:07:14 18:32:05"  # DateTimeOriginal
    details[0x9011] = "+03:00"  # OffsetTimeOriginal
    details[0x829A] = IFDRational(1, 250)  # ExposureTime
    details[0x829D] = IFDRational(28, 10)  # FNumber
    details[0x8827] = 200  # ISOSpeedRatings
    details[0x920A] = IFDRational(50, 1)  # FocalLength
    details[0xA434] = "EF50mm f/1.8 STM"  # LensModel
    gps = exif.get_ifd(0x8825)
    gps[0x0001] = "N"
    gps[0x0002] = (IFDRational(55, 1), IFDRational(45, 1), IFDRational(209916, 10000))
    gps[0x0003] = "E"
    gps[0x0004] = (IFDRational(37, 1), IFDRational(37, 1), IFDRational(33, 10))
    gps[0x0005] = 0
    gps[0x0006] = IFDRational(1565, 10)
    return exif


def make_photo_jpeg(path):
    from PIL import Image

    Image.new("RGB", (64, 48), (200, 120, 60)).save(path, exif=_photo_exif(), quality=80)


def make_photo_heic(path):
    """HEIC with the same EXIF — produced from photo.jpg by the system sips (macOS only)."""
    import subprocess

    source = os.path.join(FIXTURES, "image", "photo.jpg")
    if not os.path.exists(source):
        make_photo_jpeg(source)
    subprocess.run(["sips", "-s", "format", "heic", source, "--out", path],
                   check=True, stdout=subprocess.DEVNULL)


def make_screenshot_png(path):
    """A screenshot: no EXIF at all — the most common case."""
    from PIL import Image

    Image.new("RGB", (120, 80), (255, 255, 255)).save(path)


def make_sticker_webp(path):
    """WebP with minimal EXIF (date, software) — an EXIF chunk inside RIFF and VP8X."""
    from PIL import Image

    exif = Image.Exif()
    exif[0x0131] = "Telegram"
    exif.get_ifd(0x8769)[0x9003] = "2023:01:02 03:04:05"
    Image.new("RGBA", (40, 30), (0, 128, 255, 128)).save(path, exif=exif, lossless=True)


def make_scan_tiff(path):
    """TIFF: the size comes from the main IFD; Windows captions live in the
    XP* tags (UTF-16LE) — that's how Explorer's "Properties" -> "Details"
    writes them."""
    from PIL import Image

    exif = Image.Exif()
    exif[0x9C9B] = "Договор, стр. 1".encode("utf-16-le") + b"\0\0"  # XPTitle
    exif[0x9C9E] = "договор; скан".encode("utf-16-le") + b"\0\0"  # XPKeywords
    exif[0x9C9D] = "Бухгалтерия".encode("utf-16-le") + b"\0\0"  # XPAuthor
    Image.new("L", (100, 140), 255).save(path, exif=exif)


def make_animation_gif(path):
    from PIL import Image

    Image.new("P", (32, 16)).save(path)


def make_icon_bmp(path):
    from PIL import Image

    Image.new("RGB", (16, 12), (10, 20, 30)).save(path)


def _evil_tiff():
    """A TIFF EXIF block full of traps: ExifIFD and the "next IFD" both
    point back at IFD0 itself (a loop), Model's offset is far outside the
    block, and the GPS IFD claims 65535 entries that don't exist. Make
    itself stays valid — and that's what should be returned."""
    entry_count = 4
    make_at = 8 + 2 + 12 * entry_count + 4
    gps_at = make_at + 6
    out = bytearray(b"II*\0" + struct.pack("<I", 8))
    out += struct.pack("<H", entry_count)
    out += struct.pack("<HHII", 0x010F, 2, 6, make_at)  # Make
    out += struct.pack("<HHII", 0x0110, 2, 40, 0x7FFF0000)  # Model — out of bounds
    out += struct.pack("<HHII", 0x8769, 4, 1, 8)  # ExifIFD -> IFD0
    out += struct.pack("<HHII", 0x8825, 4, 1, gps_at)  # GPS IFD -> broken
    out += struct.pack("<I", 8)  # next IFD -> back to IFD0
    out += b"Nokia\0"
    out += struct.pack("<H", 0xFFFF)
    return bytes(out)


def make_evil_jpeg(path):
    """A real JPEG (Pillow) with an APP1 containing [_evil_tiff] spliced in."""
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (24, 16), (0, 0, 0)).save(buf, format="JPEG")
    jpeg = buf.getvalue()
    payload = b"Exif\0\0" + _evil_tiff()
    app1 = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
    with open(path, "wb") as fh:
        fh.write(jpeg[:2] + app1 + jpeg[2:])


# --- audio (Stage 6, metadata) ----------------------------------------------


def _tone(seconds, rate, channels=1):
    import numpy as np

    t = np.arange(int(seconds * rate)) / rate
    wave = 0.3 * np.sin(2 * np.pi * 440 * t)
    return np.column_stack([wave] * channels) if channels > 1 else wave


def make_song_mp3(path):
    """MP3 with ID3v2.3 in UTF-16 (how Windows and most taggers write it):
    Cyrillic, a genre by number "(17)", a track "3/12", a comment, lyrics."""
    import soundfile as sf
    from mutagen.id3 import COMM, ID3, TALB, TCON, TDRC, TIT2, TPE1, TRCK, USLT

    sf.write(path, _tone(2.0, 44100, 2), 44100, format="MP3")
    tags = ID3()
    tags.add(TIT2(encoding=1, text="Звезда по имени Солнце"))
    tags.add(TPE1(encoding=1, text="Кино"))
    tags.add(TALB(encoding=1, text="Звезда по имени Солнце"))
    tags.add(TDRC(encoding=1, text="1989"))
    tags.add(TCON(encoding=1, text="(17)"))
    tags.add(TRCK(encoding=1, text="1/8"))
    tags.add(COMM(encoding=1, lang="rus", desc="", text="Ремастер *2019* | винил"))
    tags.add(COMM(encoding=1, lang="eng", desc="iTunNORM", text=" 00000000 00000000"))
    tags.add(USLT(encoding=1, lang="rus", desc="",
                  text="Белый снег, серый лёд\nНа растрескавшейся земле\n\nОдеялом лоскутным на ней"))
    tags.save(path, v2_version=3)


def make_legacy_mp3(path):
    """MP3 from an "old" collection: ID3v2.3 with encoding 0 (declared as
    ISO-8859-1), but the bytes are Windows-1251; ID3v1 is in Windows-1251
    too. Plus a title with Latin letters and diacritics — it should stay
    Latin-1."""
    import soundfile as sf
    from mutagen.id3 import ID3, TALB, TIT2, TPE1

    def cp1251(text):
        # mutagen encodes encoding=0 as latin-1 — we feed it 1251 bytes
        return text.encode("cp1251").decode("latin-1")

    sf.write(path, _tone(1.5, 22050), 22050, format="MP3")
    tags = ID3()
    tags.add(TIT2(encoding=0, text=cp1251("Группа крови")))
    tags.add(TPE1(encoding=0, text=cp1251("Кино")))
    tags.add(TALB(encoding=0, text="Motörhead Café"))
    tags.save(path, v2_version=3, v1=2)


def make_voice_opus(path):
    """A voice message: Ogg Opus, mono, 48 kHz, like messaging apps use."""
    import soundfile as sf
    from mutagen.oggopus import OggOpus

    sf.write(path, _tone(3.2, 48000), 48000, format="OGG", subtype="OPUS")
    audio = OggOpus(path)
    audio["TITLE"] = "Голосовое сообщение"
    audio["ARTIST"] = "Анна"
    audio.save()


def make_music_vorbis(path):
    import soundfile as sf
    from mutagen.oggvorbis import OggVorbis

    sf.write(path, _tone(1.0, 44100, 2), 44100, format="OGG", subtype="VORBIS")
    audio = OggVorbis(path)
    audio["TITLE"] = "Etude"
    audio["ARTIST"] = ["Ivan", "Maria"]
    audio["DATE"] = "2021-05-03"
    audio["GENRE"] = "Classical"
    audio.save()


def make_track_flac(path):
    """FLAC: STREAMINFO (exact duration) + a Vorbis comment with
    TRACKNUMBER/TRACKTOTAL and lyrics."""
    import soundfile as sf
    from mutagen.flac import FLAC

    sf.write(path, _tone(1.75, 48000, 2), 48000, format="FLAC", subtype="PCM_24")
    audio = FLAC(path)
    audio["TITLE"] = "Перемен"
    audio["ARTIST"] = "Кино"
    audio["ALBUMARTIST"] = "Кино"
    audio["ALBUM"] = "Последний герой"
    audio["TRACKNUMBER"] = "2"
    audio["TRACKTOTAL"] = "11"
    audio["LYRICS"] = "Вместо тепла — зелень стекла\nВместо огня — дым"
    audio.save()


def make_recording_wav(path):
    """A voice recorder: WAV PCM 16-bit, mono, 16 kHz, with LIST/INFO."""
    import soundfile as sf

    with sf.SoundFile(path, "w", 16000, 1, subtype="PCM_16", format="WAV") as f:
        f.title = "Planerka"
        f.artist = "Recorder"
        f.date = "2024-11-05"
        f.comment = "room 3"
        f.write(_tone(2.5, 16000))


def make_memo_m4a(path):
    """M4A (AAC) — how iPhone and Android voice-recorder apps write it; iTunes tags."""
    import subprocess
    import tempfile

    import soundfile as sf
    from mutagen.mp4 import MP4

    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "memo.wav")
        sf.write(wav, _tone(2.0, 44100), 44100, format="WAV")
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", wav, path], check=True)
    audio = MP4(path)
    audio["\xa9nam"] = "Заметка"
    audio["\xa9ART"] = "Тимофей"
    audio["\xa9day"] = "2025"
    audio["trkn"] = [(4, 9)]
    audio["\xa9gen"] = "Podcast"
    audio.save()


def make_clip_mp4(path):
    """A synthetic MP4 video: just the moov structure (mvhd, trak with tkhd
    and an hdlr of "vide"), with no frames. There's no video encoder at
    hand, and what's being tested is box parsing anyway — like .msg above,
    this is synthetic, not a real recording."""

    def box(kind, payload):
        return struct.pack(">I", 8 + len(payload)) + kind + payload

    ftyp = box(b"ftyp", b"isom" + struct.pack(">I", 512) + b"isomiso2mp41")
    mvhd = box(b"mvhd", b"\0" * 4 + struct.pack(">IIII", 0, 0, 1000, 65500) + b"\0" * 80)
    tkhd_payload = (b"\0\0\0\x03" + struct.pack(">IIIII", 0, 0, 1, 0, 65500)
                    + b"\0" * 16 + b"\0" * 36 + struct.pack(">II", 1280 << 16, 720 << 16))
    tkhd = box(b"tkhd", tkhd_payload)
    hdlr = box(b"hdlr", b"\0" * 4 + b"\0" * 4 + b"vide" + b"\0" * 12 + b"VideoHandler\0")
    trak = box(b"trak", tkhd + box(b"mdia", hdlr))
    moov = box(b"moov", mvhd + trak)
    with open(path, "wb") as fh:
        fh.write(ftyp + moov + box(b"mdat", b""))


# --- OCR (Stage 6): images and a scan with real text -----------------------

OCR_LINES = [
    "Счёт № 42 от 14 июля 2024 года",
    "Поставщик: ООО «Ромашка», ИНН 7701234567",
    "Invoice total: 12 500 RUB",
]


def _text_image(width=1400, height=420):
    """Black text on white, 40 pt — like a screenshot or a good scan. The
    font is macOS's Arial (DejaVu Sans on Linux); the fixture is generated
    once and committed, so the test doesn't depend on the machine's
    fonts."""
    from PIL import Image, ImageDraw, ImageFont

    for font_path in ("/System/Library/Fonts/Supplemental/Arial.ttf",
                      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(font_path):
            break
    font = ImageFont.truetype(font_path, 40)
    img = Image.new("L", (width, height), 255)
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(OCR_LINES):
        draw.text((60, 60 + i * 110), line, font=font, fill=0)
    return img


def make_ocr_png(path):
    _text_image().save(path)


def _transparent_text_image():
    """Text on a transparent background — like a sticker or animation: white
    became transparent, the letters stay opaque black."""
    gray = _text_image()
    rgba = gray.convert("RGBA")
    rgba.putalpha(gray.point(lambda v: 255 - v))
    return rgba


def make_ocr_gif(path):
    """A GIF with a transparent background: the Leptonica in our builds
    doesn't read GIF, Dart (package:image) decodes the frame and places it
    on a white background."""
    _transparent_text_image().save(path, transparency=0, optimize=False)


def make_ocr_webp(path):
    _transparent_text_image().save(path, lossless=True)


def make_ocr_tiff(path):
    _text_image().save(path, compression="tiff_lzw")


def make_ocr_rotated_jpeg(path):
    """The same text, but the pixels lie "sideways" (rotated 90°
    counter-clockwise), while EXIF Orientation = 6 says to display them
    rotated clockwise — this is how a phone saves a photo of a document
    shot in portrait orientation."""
    from PIL import Image

    img = _text_image().rotate(90, expand=True)
    exif = Image.Exif()
    exif[0x0112] = 6
    img.save(path, exif=exif, quality=92)


def make_ocr_scan_pdf(path):
    """A PDF made of a single image — no text layer, like a scanner's output."""
    _text_image(width=1654, height=2339).convert("RGB").save(path, resolution=200)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True, help="site-packages сайдкара (python-pptx, openpyxl)")
    ap.add_argument("--extra-path", help="каталог с xlwt (для xls) или soundfile+mutagen (для audio)")
    ap.add_argument(
        "--only", nargs="+", choices=["xls", "msg", "pptx", "xlsx", "pdf", "image", "audio", "ocr"],
        default=["xls", "msg", "pptx", "xlsx", "pdf", "image", "audio", "ocr"],
    )
    args = ap.parse_args()
    sys.path[:0] = [args.lib] + ([args.extra_path] if args.extra_path else [])

    jobs = {
        "xls": [(make_xls, "xls/simple.xls"), (make_xls_evil, "xls/evil.xls"),
                (make_xls_biff5, "xls/biff5.xls")],
        "msg": [(make_msg, "msg/simple.msg"), (make_msg_ansi, "msg/ansi.msg"),
                (make_msg_html, "msg/html_only.msg")],
        "pptx": [(make_pptx, "pptx/simple.pptx")],
        "xlsx": [(make_xlsx_types, "xlsx/types_and_gaps.xlsx")],
        "pdf": [(make_pdf_table, "pdf/table.pdf")],
        "image": [
            (make_photo_jpeg, "image/photo.jpg"),
            (make_screenshot_png, "image/screenshot.png"),
            (make_sticker_webp, "image/sticker.webp"),
            (make_scan_tiff, "image/scan.tiff"),
            (make_animation_gif, "image/animation.gif"),
            (make_icon_bmp, "image/icon.bmp"),
            (make_evil_jpeg, "image/evil_loop.jpg"),
        ] + ([(make_photo_heic, "image/photo.heic")] if sys.platform == "darwin" else []),
        "audio": [
            (make_song_mp3, "audio/song.mp3"),
            (make_legacy_mp3, "audio/legacy.mp3"),
            (make_voice_opus, "audio/voice.ogg"),
            (make_music_vorbis, "audio/music.ogg"),
            (make_track_flac, "audio/track.flac"),
            (make_recording_wav, "audio/recording.wav"),
            (make_clip_mp4, "audio/clip.mp4"),
        ] + ([(make_memo_m4a, "audio/memo.m4a")] if sys.platform == "darwin" else []),
        "ocr": [
            (make_ocr_png, "ocr/invoice.png"),
            (make_ocr_rotated_jpeg, "ocr/invoice_rotated.jpg"),
            (make_ocr_scan_pdf, "ocr/invoice_scan.pdf"),
            (make_ocr_gif, "ocr/invoice.gif"),
            (make_ocr_webp, "ocr/invoice.webp"),
            (make_ocr_tiff, "ocr/invoice.tiff"),
        ],
    }
    for key in args.only:
        for make, rel in jobs[key]:
            path = os.path.join(FIXTURES, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            make(path)
            print(rel, os.path.getsize(path), "байт")


if __name__ == "__main__":
    main()
