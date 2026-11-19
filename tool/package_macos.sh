#!/usr/bin/env bash
set -euo pipefail

# Package a release built on the current Mac for its own architecture.
source_app="${1:?usage: bash tool/package_macos.sh path/to/app.app output.dmg}"
output="${2:?output DMG path required}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/whisper/versions.sh"
arch="$(uname -m)"
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

app="${stage}/MarkItDown UI.app"
ditto "${source_app}" "${app}"
frameworks="${app}/Contents/Frameworks"
resources="${app}/Contents/Resources"
assets="${frameworks}/App.framework/Resources/flutter_assets/assets"
sidecar="${resources}/sidecar"

ditto "${root}/sidecar/dist/macos-${arch}" "${sidecar}"
test -f "${sidecar}/manifest.json"
# Current upstream PDFium binaries require macOS 13. The locked pypdfium2
# wheel includes a Monterey-compatible build of the same native library.
cp "${sidecar}/lib/pypdfium2_raw/libpdfium.dylib" "${frameworks}/"
cp -P "${root}"/tesseract/native/host/*.dylib "${frameworks}/"
cp -P "${root}"/whisper/native/host/*.dylib "${root}"/whisper/native/host/libggml-cpu-*.so "${frameworks}/"

for file in tessdata/{rus,eng}.traineddata whisper/{models.json,"${MODEL_NAME}","${VAD_NAME}"}; do
  test -s "${assets}/${file}" || { echo "Missing model in app: ${file}" >&2; exit 1; }
done

executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app}/Contents/Info.plist")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${app}/Contents/Info.plist")"
test "${minimum}" = 12.0
test "$(lipo -archs "${app}/Contents/MacOS/${executable}")" = "${arch}"

# Check each shipped Mach-O slice, including wheels and plugin frameworks.
while IFS= read -r -d '' file; do
  [[ "$(file -b "${file}")" == Mach-O* ]] || continue
  lipo "${file}" -verify_arch "${arch}"
  otool -arch "${arch}" -l "${file}" | awk -v path="${file}" '
    /cmd LC_VERSION_MIN_MACOSX/ { legacy = 1 }
    $1 == "minos" || (legacy && $1 == "version") {
      legacy = 0
      split($2, v, ".")
      if (v[1] > 12 || (v[1] == 12 && (v[2] > 0 || v[3] > 0))) {
        print path " requires macOS " $2 > "/dev/stderr"
        exit 1
      }
    }
  '
done < <(find "${app}" -type f \( -perm -100 -o -name '*.dylib' -o -name '*.so' \) -print0)

"${root}/sidecar/sign.sh" "${sidecar}" -

# Xcode has signed the Flutter frameworks. Sign the added libraries, then
# re-sign the app to seal the bundle and preserve the Release sandbox.
while IFS= read -r -d '' file; do
  codesign --force --sign - --timestamp=none "${file}"
done < <(find "${frameworks}" -maxdepth 1 -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
codesign --force --sign - --timestamp=none \
  --entitlements "${root}/app/macos/Runner/Release.entitlements" "${app}"
codesign --verify --deep --strict "${app}"

ln -s /Applications "${stage}/Applications"
mkdir -p "$(dirname "${output}")"
# Use a volume format that can be mounted by Monterey on either CPU.
hdiutil create -volname 'MarkItDown UI' -srcfolder "${stage}" -fs HFS+ -format UDZO -ov "${output}"
hdiutil verify "${output}"
