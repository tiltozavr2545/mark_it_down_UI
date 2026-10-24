#!/bin/sh
# Checks the version bump in a PR — see docs/operations.md#version.
#
#   tool/verify_version.sh [BASE_REF]      (defaults to origin/main)
#
# The version in the working tree's app/pubspec.yaml is compared against
# the version at BASE_REF. Fails if: the format isn't
# MAJOR.MINOR.PATCH+BUILD; the version hasn't changed; the build didn't
# strictly increase. The name may stay the same — a build-only bump is
# fine. core/pubspec.yaml carries no build number and isn't checked.
# POSIX sh + sed/grep/git only: works the same on macOS (BSD) and in CI.
set -eu

BASE_REF=${1:-origin/main}
PUBSPEC=app/pubspec.yaml
FORMAT='^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$'

cd "$(dirname "$0")/.."

# Extracts the `version:` value from a pubspec on stdin: no quotes,
# comment, or surrounding whitespace.
read_version() {
  sed -n 's/^version:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//'
}

fail() {
  echo "verify-version: $*" >&2
  exit 1
}

head_version=$(read_version < "$PUBSPEC")
[ -n "$head_version" ] || fail "в $PUBSPEC нет строки version:"

if ! base_content=$(git show "$BASE_REF:$PUBSPEC" 2>/dev/null); then
  fail "не удалось прочитать $PUBSPEC из '$BASE_REF'. Базовая ветка не подтянута? (git fetch origin <ветка>)"
fi
base_version=$(printf '%s\n' "$base_content" | read_version)

echo "verify-version: $BASE_REF = $base_version, рабочее дерево = $head_version"

echo "$head_version" | grep -Eq "$FORMAT" \
  || fail "версия '$head_version' в $PUBSPEC не в формате MAJOR.MINOR.PATCH+BUILD (например 0.4.0+4)"
echo "$base_version" | grep -Eq "$FORMAT" \
  || fail "версия '$base_version' в $BASE_REF не в формате MAJOR.MINOR.PATCH+BUILD — сравнивать не с чем"

[ "$head_version" != "$base_version" ] \
  || fail "версия не изменена относительно $BASE_REF ($head_version): бампни её в $PUBSPEC"

head_build=${head_version#*+}
base_build=${base_version#*+}
[ "$head_build" -gt "$base_build" ] \
  || fail "build должен расти строго: в $BASE_REF +$base_build, у тебя +$head_build (Google Play и App Store Connect не принимают повторный номер)"

echo "verify-version: ок ($base_version -> $head_version)"
