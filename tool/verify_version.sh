#!/bin/sh
# Проверка бампа версии в PR — см. docs/operations.md#версия.
#
#   tool/verify_version.sh [BASE_REF]      (по умолчанию origin/main)
#
# Версия app/pubspec.yaml в рабочем дереве сравнивается с версией в BASE_REF.
# Падает, если: формат не MAJOR.MINOR.PATCH+BUILD; версия не изменилась;
# build не вырос строго. name при этом может не меняться — допустим бамп
# одного build. core/pubspec.yaml версию с build не несёт и не проверяется.
# Только POSIX sh + sed/grep/git: одинаково работает на macOS (BSD) и в CI.
set -eu

BASE_REF=${1:-origin/main}
PUBSPEC=app/pubspec.yaml
FORMAT='^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$'

cd "$(dirname "$0")/.."

# Достаёт значение `version:` из pubspec на stdin: без кавычек, комментария
# и пробелов по краям.
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
