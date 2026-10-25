# Python sidecar: a genuine markitdown on desktop

How the real [microsoft/markitdown](https://github.com/microsoft/markitdown)
ends up inside a desktop application, why it's needed there given the Dart
core, and what it costs. The target desktop is **Windows** (Stage 5 of the
plan); macOS is secondary. The build verified so far is macOS x86_64
(Stage 4), and the numbers below, unless stated otherwise, come from there;
what changes on Windows is in the [«Windows»](#windows-stage-5) section.

There is no sidecar on Android or iOS, and there won't be — the reason is at
the very bottom. How it plugs into the pipeline (priority −1.0, `localPath`)
is covered in
[conversion-pipeline.md](conversion-pipeline.md#sidecar--just-another-converter).

---

## Why it exists if there's a Dart core

Not for "completeness," but for three specific things:

- **`.xls` (BIFF8) and `.msg`** — there's no ready-made parsing in Dart, and
  writing one just for two formats isn't worth it. `xlrd` and `olefile`
  already read them.
- **PDF** — `pdfminer.six` + `pdfplumber` give quality and, more importantly,
  **decisions about tables** that have already been made and battle-tested
  in markitdown.
- **A reference for comparison.** The most underrated reason: the sidecar is
  a way to get the "correct" answer for any test file right on the
  developer's machine and compare it against what the Dart core produced.
  Without it, a divergence between the two implementations is only ever
  noticed by eye.

If only the third point remained, the sidecar would still be worth building
— just as a development tool, not as part of the application.

## What exactly gets packaged

```
MarkItDown.app/Contents/Resources/sidecar/
  python/                 ← interpreter from python-build-standalone
  lib/                    ← markitdown + dependencies (site-packages)
  run.py                  ← thin wrapper: argv → JSON on stdout
  manifest.json           ← which formats the sidecar takes on
```

This is exactly the layout produced in `sidecar/dist/<host>/` after the build
(see "Build" below); when packaging the app, the directory is copied as is.
On Windows the same directory sits next to the `.exe`, and the interpreter is
`python/python.exe` (see "Windows" below).

The interpreter comes from
[python-build-standalone](https://github.com/astral-sh/python-build-standalone)
(the same builds `uv` uses): a ready-made, relocatable Python that doesn't
depend on the system one. The system Python can't be used — on macOS it
might not even be present, and on Windows it almost never is. Pinned:
release `20260929`, CPython **3.12.14** (the `install_only` variant),
markitdown **0.1.8**. Python 3.12, not a newer 3.13/3.14, is a deliberate
choice: macOS x86_64 wheels (`onnxruntime`, `pandas`, `lxml`) exist for every
dependency on 3.12 without exception, and there's no payoff here from a
newer interpreter. The release taken is not "today's" but ten days old — so
as not to be the first one to hit a bug in it.

What's installed is **not** `markitdown[all]`: the `az-doc-intel`,
`az-content-understanding`, and `youtube-transcription` groups aren't
installed at all — they're about network and cloud, which have no place in
the product (see [offline-and-privacy.md](offline-and-privacy.md)). What
gets installed: `pdf`, `docx`, `xlsx`, `xls`, `pptx`, `outlook`.
`audio-transcription` is not installed: it pulls in `SpeechRecognition`,
which by default calls Google's web API, i.e. gives you network
transcription rather than offline — details in
[format-coverage.md](format-coverage.md).

## Build

```
make sidecar                # = ./sidecar/build.sh
FORCE=1 make sidecar        # rebuild even if already built
```

The build is **not part of** `make verify` or CI: it downloads hundreds of
MB (the interpreter ~25 MB plus wheels like numpy/pandas/onnxruntime, etc.)
and is only needed by whoever is cross-checking implementations or packaging
the desktop app. On a slow connection the first run can take a quarter of an
hour; a repeat run comes from the pip cache and archive in about a minute.

What `sidecar/build.sh` does, step by step, with reasons:

1. **Pick the asset for the host**: macOS x86_64 / arm64, Linux x86_64 /
   aarch64. Only macOS x86_64 has actually been verified — the other three
   rows of the table in the script are written from the same template but
   haven't been run.
2. **Download and sha256.** The release version and Python version are
   pinned in `sidecar/common.sh`, the checksums are baked in (checked
   against the release's `SHA256SUMS`). The archive lives in
   `sidecar/cache/` (in `.gitignore`); a corrupted cache triggers a
   re-download, and a mismatched hash on a freshly downloaded file causes a
   refusal. "Latest" is never used: a reference that changes silently isn't
   a reference at all.
3. **`pip install --require-hashes --no-deps --target lib -r locks/<host>.txt`**
   using the interpreter *from the archive*, with `-I` and
   `--only-binary=:all:` — no building from source on the machine and no
   influence from the user's environment. All 42 packages, including
   transitive ones, are pinned by version and wheel sha256 (see "Lock file"
   below).
4. **Cleanup** (what's needed at runtime stays; markitdown's code and its
   dependencies' code are not touched):
   - `lib/bin/` (pip scripts with absolute paths), all `tests/`, other
     packages' `__pycache__`, `olefile/olefile2.py` (the Python 2 variant:
     doesn't compile);
   - **`sympy` and `mpmath`** (~45 MB): `onnxruntime` lists them as
     dependencies, but doesn't import them during the inference that
     `magika` performs; `onnxruntime/{transformers,tools,quantization}`
     (~7 MB) — also tooling, not runtime;
   - from the interpreter: `pip`/`ensurepip`, Tk/IDLE/stdlib tests, headers,
     and also `libpython3.12.dylib` (~18 MB) — `python3.12` from this build
     is static and doesn't link against a dynamic `libpython` (`otool -L`);
   - **macOS: `lipo -thin`** for universal2 wheels (`onnxruntime`,
     `cryptography`, `charset_normalizer`) — in a bundle targeting a single
     architecture, the other half of each `.so` is dead weight, ~38 MB.
5. **Bytecode ahead of time**: `compileall --invalidation-mode
   unchecked-hash` across `lib/` and the stdlib. The runtime runs with `-B`,
   and writing `.pyc` files into a signed bundle on macOS isn't allowed (it
   would break the signature), so everything is prepared before signing.
   `unchecked-hash`, not the default timestamp: the source mtime easily
   changes when copied into `.app`/DMG, and the interpreter would silently
   recompile everything in memory on every run. The temporary build path is
   stripped from `co_filename` so the builder's directory doesn't leak into
   the bundle.
6. **`manifest.json`** with the real versions from the built tree (not from
   constants in the script), then a **self-check** via `run.py
   --self-check`: markitdown imports, each of the six converters' dependency
   is in place, `magika` runs real inference (this is the safety net for the
   sympy cleanup), `pandas` computes `to_html`, and the list of formats in
   the manifest matches the table in `run.py`. If it doesn't pass, the build
   fails rather than shipping a manifest that lies.
7. The result is assembled into a temporary directory and atomically swaps
   in for `sidecar/dist/<host>/`; a skip on a repeat run is determined by a
   stamp in `sidecar/cache/` (versions plus hashes of `run.py` and
   `build.sh`).

Relocatability has been verified: a tree copied into a directory with a
space in the path, with `touch` run on every `.py` file, and under `env -i`,
works and creates not a single new file (file count before and after —
5167).

### Lock file: reproducibility

`sidecar/locks/<host>.txt` (currently `macos-x86_64.txt`, committed) — all 42
packages in the form `name==version --hash=sha256:…`. The build installs
strictly from it (`--require-hashes --no-deps`): anything not in the file, or
whose hash doesn't match, pip simply will not install, and "a slightly
newer lxml a month from now" is impossible. The file is per-host, not
shared: wheels for numpy/onnxruntime on macOS x86_64, arm64, and Linux are
different files with different hashes. For a host without a lock file,
`build.sh` refuses to build (`ALLOW_UNLOCKED=1` is a one-time bypass, used
exactly to create the first lock on a new host: first `ALLOW_UNLOCKED=1 make
sidecar`, then `make sidecar-lock`).

How to update it — only deliberately, when `MARKITDOWN_VERSION`,
`PY_VERSION`, or `PBS_TAG` changes in `sidecar/common.sh`, or when transitive
dependencies need bumping:

```
make sidecar-lock          # sidecar/lock.sh: pip --dry-run --report, installs nothing
git diff sidecar/locks/    # read what changed
FORCE=1 make sidecar       # rebuild from the new lock
make compare-sidecar       # re-cross-check against the Dart core
```

`lock.sh` doesn't use pip-tools/uv: dependency resolution is done by pip
itself from the downloaded interpreter, and sha256 values come from its own
report on the chosen wheels. Verified: rebuilding from the lock file
produced the same set of 40 `*.dist-info` entries (42 minus the cleaned-out
sympy/mpmath) and byte-for-byte the same `run.py` output on 10 samples
(pdf×3, docx×2, xlsx×2, xls, msg, pptx). `--self-check` passes.

### Sizes (macOS x86_64, verified)

Total for `sidecar/dist/macos-x86_64/` — **242 MB**: `python/` 40 MB,
`lib/` 203 MB (of which bytecode is ~35 MB). The path to get there: naive
355 MB → without sympy/mpmath and onnxruntime tooling 299 → `lipo -thin` 261
→ without `libpython` 242.

Largest items in `lib/` (including hidden `.dylibs/`):

| package | MB | why |
|---|---|---|
| `numpy` | 53 | `onnxruntime`, `pandas`; of which ~32 MB is OpenBLAS and the Fortran runtime |
| `pandas` | 34 | xlsx/xls (see below) |
| `onnxruntime` | 30 | `magika` — content-based type detection, imported unconditionally by markitdown |
| `PIL` | 15 | `pdfplumber` |
| `cryptography` | 13 | `pdfminer.six` (encrypted PDFs) |
| `lxml` | 11 | docx/pptx |
| `pdfminer` | 9 | PDF |
| `pypdfium2_raw` | 7 | `pdfplumber` |

Further shrinking is only possible by dropping dependencies that markitdown
imports unconditionally (`magika`/`onnxruntime` and `pandas` being the main
ones), i.e. at the cost of "authenticity": 242 MB on the desktop is the price
of the reference implementation, and that price has to be stated to the
user plainly. The `.py` sources next to the `.pyc` files (~32 MB) could be
dropped, leaving source-less bytecode, but that breaks tracebacks to save
13% — not taken.

### pandas: can the code path do without it — no

Verified against the `markitdown 0.1.8` source
(`converters/_xlsx_converter.py`): both `XlsxConverter` and `XlsConverter`
rest entirely on `pandas` — `pd.read_excel(..., sheet_name=None)` reads
sheets into a `DataFrame`, and `DataFrame.to_html(index=False)` produces
intermediate HTML, which the shared `HtmlConverter` then turns into
Markdown. `import pandas` sits at the top of the module, and without it both
converters simply get marked with `MissingDependencyException`. pandas is
not used in any other converter (pdf/docx/pptx/msg), nor in
`pdfplumber`/`pdfminer`, anywhere on markitdown's code path (checked via
`grep` across the tree).

Numbers: `pandas` + `python-dateutil` + `six` = **35 MB out of 242 (~14%)**;
`numpy` stays regardless (needed by `onnxruntime`). The payoff from dropping
it entirely is modest, and the cost is losing the whole point of the sidecar
for tables: our own xlsx/xls path via `openpyxl`/`xlrd` would give a *third*
implementation, not a reference. pandas's output format is exactly what we
want to cross-check against: the sheet's first row becomes the header, empty
headers turn into `Unnamed: 1`, empty cells become `NaN`, floats are aligned
by digit count (`0.50`), and integer-valued floats coming from xls are cast
to int. All of this would have to be reproduced by hand otherwise.
**Decision: pandas stays, the 35 MB is accepted and called out.**

What was done instead of removing it: pandas also costs about 0.25 s of cold
start on every call, because markitdown imports all converters at once. For
non-table formats (`pdf`, `docx`, `pptx`, `msg`), `run.py` sets
`sys.modules["pandas"] = None` before importing markitdown: `import pandas`
then raises `ImportError`, which markitdown itself catches, marking the xlsx
converters unavailable. markitdown's code and output don't change (the
result on six fixtures was byte-for-byte identical to a run without this
substitution), while the call speeds up from ~1.05 s to ~0.65 s.

## Protocol

One call, one subprocess. No daemon, no socket, no warm-up:

```
<dir>/python/bin/python3 -I -B <dir>/run.py --in /tmp/xxx.pdf --format pdf
(on Windows: <dir>\python\python.exe — the rest is the same)
→ stdout: {"markdown": "...", "title": null, "warnings": [...]}   (a single JSON object, UTF-8)
→ stderr: diagnostics (including warnings and library logs)
→ exit code: 0 | 2 (unsupported) | 3 (corrupt file) | 1 (other)
```

- **`-I`**: the caller's environment (`PYTHONPATH`, user site) has no effect
  on the sidecar; it requires no environment variables of its own. `run.py`
  itself adds `<dir>/lib` to `sys.path` relative to its own `__file__`.
- **`-B`**: bytecode is pre-built during the build step, the runtime writes
  nothing into the bundle (see "Signing").
- **`--format`** — a format id (`pdf`, `docx`, `xlsx`, `xls`, `pptx`, `msg`);
  `run.py` turns it into an extension hint for markitdown
  (`StreamInfo(extension=...)`), because the temporary file may arrive with
  any name at all. An unknown id results in exit code 2. **This is a hint,
  not a mandate:** markitdown still looks at the actual content (via
  `magika`), and a `.docx` declared as `pdf`, or plain text declared as
  `docx`, gets converted "as is," with exit code 0. The application passes
  the id based on its own type detection, so in practice there's no
  mismatch.
- **stdout stays clean.** For the duration of the run, `run.py` redirects
  file *descriptor* 1 to stderr (the native `onnxruntime` code inside
  `magika` writes straight to the fd, which `sys.stdout` wouldn't catch),
  and writes the JSON to a saved copy of the real stdout.
- **Exit codes**: 2 — `UnsupportedFormatException` or an unknown
  `--format`; 3 — `FileConversionException` (including an empty file or
  garbage: `PDFSyntaxError`, `BadZipFile`, `NotOleFileError`, `XLRDError`);
  1 — invalid arguments, missing file, an uncaught exception, and the case
  where every attempt failed due to a missing dependency (that's a broken
  build, not a "corrupt file"; telling the user "the file is corrupted"
  would be a lie). Its own argument parsing is used instead of `argparse`,
  because `argparse`'s own error is also exit code 2, which is already
  taken.
- **`warnings`** in the JSON — only what `run.py` itself knows about the
  result (currently: `"result is empty"`); library warnings go to stderr.
- **`manifest.json`**: `{"schema": 1, "markitdown": "0.1.8", "python":
  "3.12.14", "formats": ["pdf","docx","xlsx","xls","pptx","msg"]}` — only
  what actually works in this particular tree (checked by the build's
  self-check).

Why this, rather than a long-lived process: a cold Python start with `import
markitdown` is, on this machine (Intel, macOS 12), around 0.65 s for
pdf/docx/pptx/msg and 1.05 s for xlsx/xls, at ~96 / ~132 MB RAM (peak).
Noticeable, but tolerable against everything else. And one process per call
means a crash on one file doesn't corrupt state for the next one, and that
there's no state at all. If this ever becomes insufficient — a long-lived
variant and/or lazy converter imports; not needed right now.

What's passed is **a path, not a stream over stdin**: some markitdown
converters want to see an actual file (and the extension in its name). The
file in the temp folder is created by the application and deleted by the
application too, in a `finally` block — see
[client-architecture.md](client-architecture.md#state-and-privacy).

A timeout is mandatory. A subprocess that hasn't responded gets killed, and
that turns into an ordinary conversion error rather than an endless spinner.

## What the fixture run showed

A run of `run.py` from the built sidecar (macOS x86_64) over
`core/test/fixtures/` and synthetic samples `xls/simple.xls`,
`msg/simple.msg`, `pptx/simple.pptx` (produced by
`sidecar/samples/make_samples.py`):

| input | code | result |
|---|---|---|
| `pdf/simple.pdf`, `docx/simple.docx`, `docx/evil_nested.docx`, `xlsx/*.xlsx` | 0 | valid JSON |
| `pdf/blank.pdf` | 0 | `markdown: ""`, `warnings: ["result is empty"]` |
| `pdf/scanned.pdf` | 0 | text from pages that have it; empty pages produce `\f` (form feed) |
| `pptx/no_sppr.pptx` (a shape without `<p:spPr>`) | **3** | `InvalidXmlError: required <p:spPr> child element not present` |
| `.xls`/`.msg`/`.pptx` samples | 0 | valid JSON, see below |
| empty file / random bytes, for any of the six `--format` values | 3 | stdout empty, reason in stderr |
| unknown `--format` | 2 | — |
| no `--in`, missing file, extra argument | 1 | — |

Findings relevant for cross-checking:

- **The first version of `pptx/simple.pptx` wouldn't open in real
  python-pptx** (a shape without `<p:spPr>`, which the Dart parser doesn't
  care about). The fixture was replaced with a sample that opens in both,
  and the old variant was kept as an adversarial fixture
  `pptx/no_sppr.pptx`: Dart tolerates it, markitdown responds with code 3.
- **Divergences between Dart and markitdown on the current fixtures**
  (from `expected.md` versus the sidecar): PDF — Dart builds headings from
  font size and joins wrapped lines, markitdown 0.1.8 doesn't (lines stay as
  is, no headings); docx — list marker `-` versus `*`, footnotes `[^1]`
  versus `[[1]](#footnote-1)`, a headerless table in markitdown gets an
  empty header row `|  |  |`, a nested table gets flattened onto one line;
  xlsx — markitdown turns the sheet's first row into a header (Dart outputs
  `A | B` plus the data as is), merged cells aren't marked at all (Dart
  emits an HTML block with a warning, markitdown produces `Unnamed: 1`).
- **Where `.xls`/`.msg`/`.pptx` in `core/test/fixtures/` come from**
  (`xls/simple.xls`, `msg/simple.msg`, `pptx/simple.pptx`) — not "from
  somewhere," but produced by `sidecar/samples/make_samples.py` (it writes
  directly into `core/test/fixtures/`, with `--only` and `--extra-path`
  options). `.xls` via `xlwt` (installed into a temp directory, doesn't end
  up in the sidecar); `.pptx` via python-pptx from the sidecar; `.msg` via a
  minimal Compound File Binary writer right in the script, with UTF-16
  strings and Cyrillic text. This is synthetic data, not a real Outlook
  message: it exercises the `olefile` → `OutlookMsgConverter` path, but
  gives no picture of real `.msg` files (attachments, ANSI encodings, RTF
  bodies). The expected Markdown for `.xls`/`.msg` is the sidecar's own
  output (there's no other converter).

Cold start for a single call, macOS x86_64, Intel, with disk cache warm:
**0.65 s** (pdf/docx/pptx/msg), **1.05 s** (xlsx/xls), peak RAM ~96 and
~132 MB; the interpreter itself starts in 30 ms, the rest is importing
markitdown and `magika`. There are no measurements of a "truly cold" disk
(after a reboot, or copying the bundle to another volume): one random run
over a tree freshly installed by pip, with no precompiled bytecode, took
~40 s, but that's a different tree and a different situation. For the
application's timeout, build in a large margin, not 1 s.

## Windows (Stage 5)

The author's priority has shifted to Windows and Android, so the desktop
sidecar is now primarily about Windows. The design is the same — one
subprocess per call, the same `run.py`, the same protocol; what changes is
below. **It builds and is checked in CI** (the `windows-sidecar` job on
`windows-2022`: build, integration tests, cross-check against Dart — all
outputs matched macOS byte-for-byte, see
[format-coverage.md](format-coverage.md#reconciliation-on-windows-stage-5)); it has
not yet been checked on a live Windows machine (item 8), see
[implementation-plan.md](implementation-plan.md#stage-5--windows-05), item 4;
below is what changes and why.

- **Layout.** `sidecar/dist/windows-x86_64/{python,lib,run.py,manifest.json}`
  next to the `.exe`; the interpreter is `python/python.exe` instead of
  `python/bin/python3` (`SidecarConverter.fromDirectory` knows this).
  `discover()` looks for `sidecar\` in the `.exe`'s directory, and
  `app/windows/CMakeLists.txt` puts `sidecar/dist/windows-x86_64/` there if
  it's been built. The protocol, `-I -B`, and exit codes are unchanged.
- **Interpreter.** python-build-standalone for `x86_64-pc-windows-msvc`,
  `install_only` variant, same release and CPython 3.12.14. The system
  Python isn't used here either: on Windows it almost never exists, and
  "Python from the Microsoft Store" is a stub.
- **Dependencies.** Wheels for `numpy`, `onnxruntime`, `pandas`, `lxml`,
  `cryptography`, `pillow`, `pypdfium2` exist for `win_amd64` and cp312, so
  there's no fundamental obstacle. Their DLL dependencies (OpenBLAS for
  `numpy`, `onnxruntime`'s own `.dll` files) ship inside the wheels, but this
  has to be verified by actually running: `--self-check` on the runner is
  the only thing that counts. Whether the Visual C++ Redistributable is
  needed on the author's clean machine remains to be found out on the first
  artifact: `python.exe` from python-build-standalone links against the
  CRT, and if it's absent, the sidecar will silently fail to start.
- **Lock file.** `sidecar/locks/windows-x86_64.txt` — a separate file (the
  `win_amd64` wheel hashes are its own), generated on the runner rather than
  by hand: if the file doesn't exist, the `windows-sidecar` job calls
  `lock.sh` itself, uploads the result as the `sidecar-lock-windows-x86_64`
  artifact, and stays red until it's read and committed. 44 packages versus
  42 on macOS: plus `pyreadline3` and `tzdata` (Windows-only dependencies of
  `humanfriendly` and `pandas`); `cryptography`, `onnxruntime`, and
  `pypdfium2` are newer than on the Intel Mac — there are no fresh enough
  wheels there. This had no effect on the fixture output.
- **Cleanup in `build.sh`.** `lipo -thin` is macOS-specific and is skipped by
  host on Windows; `sympy`/`mpmath`, onnxruntime tooling, and `compileall`
  are shared. Cleaning the interpreter itself is a **separate branch**: NTFS
  is case-insensitive, so `python/lib/` there is the same as `python/Lib/`,
  and the Unix-style `rm -rf python/lib/{tcl*,tk*,thread*}` would have wiped
  out `Lib/threading.py`. On Windows, `Lib/{test,idlelib,tkinter,…}`, `tcl/`,
  `include/`, `libs/`, `Scripts/`, and the Tk libraries in `DLLs/` are
  removed instead.
- **Encoding and paths.** The embedded Python scripts `lock.sh`/`build.sh`
  run with `-X utf8`: stdout in a pipe on Windows is cp1252, `print` with
  Cyrillic text used to fail, and `PYTHONUTF8` is ignored under `-I`. Paths
  passed as arguments to `python.exe` go through `cygpath -w` (`native_path`
  in `common.sh`), otherwise `compileall -s` wouldn't have stripped the
  build path out of the `.pyc` files. `run.py` itself writes the response as
  UTF-8 bytes straight to the fd, so the console encoding doesn't interfere
  with the protocol.
- **Size — 308 MB** (macOS — 242): `lib/` 182 MB, `python/` 126 MB, of which
  `DLLs/` is ≈70 MB — noticeably more than you'd expect from standard
  `.pyd` files; what's actually in there and whether it can be trimmed
  hasn't been looked into (an open question, see
  [future-development.md](future-development.md#size-of-the-windows-sidecar)).
- **No macOS signing.** `sign.sh`, `sidecar.entitlements`, Hardened Runtime,
  and notarization don't apply to Windows, and along with them goes the
  signing-related reason for `-B` (the flag stays anyway: it still prevents
  writing into the install directory). Instead there's **Authenticode** for
  the `.exe` and possibly `python.exe`; there's no certificate yet, and the
  decision on signing and SmartScreen is an open question for Stage 5
  (item 6). The first call to the interpreter is checked noticeably longer
  than usual by Defender — keep the first call's timeout generous, just as
  on macOS.
- **Long paths.** The longest path inside the sidecar is 95 characters
  (`lib/lxml/isoschematron/…`; printed in the job log), i.e. with the 260
  limit there's about 165 left for the directory the zip is extracted into.
  If MSIX is chosen at Stage 7 (`C:\Program Files\WindowsApps\…` with a
  long prefix), re-check this.
- **Speed.** The measurements in this document and in
  [format-coverage.md](format-coverage.md#reconciliation-with-the-reference-stage-4) are
  from macOS; revisit on Windows. The order of "sidecar or Dart" has been
  decided (Stage 5, item 5; PDF taken out in 0.10.1): in the app, the
  sidecar goes first only for `xls`/`msg` — see
  [conversion-pipeline.md](conversion-pipeline.md#sidecar--just-another-converter).

## Signing and notarization on macOS

*Secondary platform: this section is maintained and stays as is, but is no
longer a priority.*

The most likely point where everything breaks down — hence a dedicated
section. The full working commands (marked with what's verified and what
isn't) are in
[operations.md](operations.md#signing-and-notarization-commands); here is
why it's done this way.

The embedded interpreter is **an executable file inside the bundle**, and
Hardened Runtime treats it with full seriousness:

- Every nested Mach-O binary is signed **separately**, with `--options
  runtime` (without it, notarization refuses), and only then is the bundle
  itself signed (inside out). There are 111 of them: 110 `.so`/`.dylib`
  files and `python3.12`. `sidecar/sign.sh` finds them by magic bytes, not
  by extension, so as not to miss a `.so` with a nonstandard name.
- **Signing happens strictly after `build.sh` has fully run** — after
  compileall, all the cleanup steps, and `lipo -thin`: signing hashes the
  file, and any edit afterward breaks the signature. `sign.sh` itself writes
  nothing into the tree except the signatures. And it runs strictly before
  signing the outer `.app`, whose resource seal covers this directory.
- `com.apple.security.network.client` in the interpreter's entitlements is
  **not needed and is not added**. Since 0.9 the application (Runner) has
  it — for the "link" mode — and the sidecar, as a subprocess, inherits it
  along with the sandbox; without network access, the sidecar relies on the
  fact that markitdown's network converters simply aren't installed in it
  (see [offline-and-privacy.md](offline-and-privacy.md)). `sign.sh` refuses
  to run if the entitlements file contains a network key, and it checks the
  final entitlements of the signed interpreter.
- Notarization checks the entire tree: a single unsigned `.so` among the
  dependencies is a refusal, and in the report it's just one line among
  many. That's why signing is done by a script that walks the tree, not by
  hand, and at the end every file is verified individually.

### Signing: verified ad hoc with Hardened Runtime

There's no Developer ID identity on this machine (`security find-identity -v
-p codesigning` — 0), so the honest verification here is **ad hoc (`-`)
with `--options runtime`**: Hardened Runtime applies to ad hoc signing too,
including library validation, so the set of entitlements is genuinely
exercised. Not verified: a real Developer ID, `--timestamp`, notarization.

What was found, by entitlement:

| entitlement | needed? | how it was verified |
|---|---|---|
| `cs.disable-library-validation` | **yes, for ad hoc; probably not with a Developer ID** | without it, `import numpy` fails: `code signature … not valid for use in process: mapped file has no Team ID and is not a platform binary`. With it, `--self-check` and all six formats pass, and the output matches the unsigned build byte-for-byte. With a real Developer ID, all 111 files would get one Team ID, and library validation, per the documentation, should let them through anyway; there's no way to verify this here, so the key is left in (it weakens Hardened Runtime and is a candidate for removal as soon as there's a build with a real certificate) |
| `cs.allow-unsigned-executable-memory` | **no** | a ctypes callback (`qsort` with `CFUNCTYPE`) under Hardened Runtime **hangs** without it (the process spins in the kernel, 12 s of system time out of 20), and completes in 0.8 s with it. `allow-jit` doesn't help — libffi doesn't use `MAP_JIT`. But callbacks only occur in `cffi.backend_ctypes`, `pypdfium2` (not on markitdown's code path), and the Windows branch of `click`; all six formats and onnxruntime/numpy/lxml work fine without it. If a dependency with callbacks ever shows up, the symptom is exactly this hang, and the fix is a single line in `sidecar.entitlements` |
| `cs.allow-jit` | no | see above; Python 3.12 doesn't use a JIT |
| `com.apple.security.network.*` | **forbidden** | the sidecar is offline |
| `app-sandbox` + `inherit` | no, for the DMG | a sandboxed app's subprocess inherits the sandbox on its own; for the Mac App Store both would be needed (a separate decision). **Not verified** — needs a live `.app`, and Xcode isn't installed |

Additionally verified: a signed tree copied into a directory with a space in
the path (`rsync -a`) works; a signed tree embedded in a test `.app` and
signed from the outside with `Release.entitlements` passes `codesign
--verify --deep --strict` (5205 files sealed), the nested interpreter stays
valid and runs. Corrupting a signed `.so` is caught by `codesign --verify`.

A performance note: the first run of freshly signed files on this machine is
noticeably slower than usual (the system checks every newly signed file),
so the application's timeout for the first call should be generous.

### About the App Store

A bundle containing an interpreter is not a violation (the app is
self-contained, no code is downloaded from anywhere), but it is a
**significantly more cumbersome path**: sandboxing, signing of nested
binaries, heightened review scrutiny. That's why distribution at Stage 4 is
a notarized DMG via GitHub Releases, and the Mac App Store is a separate
decision, if and when there's a reason for it.

## Why it's absent on mobile

Not because it's "hard," but because it runs straight into native
dependencies. `lxml`, `pdfminer.six` (via `cryptography`), `pandas`,
`pillow`, `magika` (an ONNX runtime) — these are all native wheels, and none
of them exist for `arm64-ios`/`arm64-android`; building them from source for
mobile ABIs would be a separate project, noticeably bigger than this whole
application.

Chaquopy (Android) and python-apple-support (iOS) provide the interpreter
itself but don't solve the wheel problem. So mobile platforms run **only**
on the Dart core, and this isn't a temporary state but an architectural
decision: it's exactly why the Dart core is the primary path and the sidecar
is a booster, not the other way around. If it were the other way around,
the app on a phone wouldn't be able to do anything at all.

A consequence worth keeping in mind: **results can differ between a phone
and a laptop.** Wherever the sidecar did the work, `warnings` includes
`converterId: sidecar` — so that when figuring out "why did I get a
different result," you don't have to guess.
