#!/bin/sh
# Builds a GitHub Release body — see docs/operations.md#release.
#
#   tool/release_notes.sh VERSION      (e.g. 0.10.0, no leading "v")
#
# Output: "What's new in VERSION" — that version's section of
# CHANGELOG.md — followed by .github/release-notes.md (install
# instructions). Fails if CHANGELOG.md has no `## VERSION` section: a
# release without a "what's new" isn't published.
#
# Both sources are hard-wrapped at ~72 columns, like all Markdown in the
# repo, but GitHub renders every line break in a release body as a real
# one — the text came out as a narrow column on the left. So paragraphs
# and list items are joined into single lines here, and relative links
# (fine inside the repo, dead on a release page) are made absolute.
# POSIX sh + awk/sed only: works the same on macOS (BSD) and in CI.
set -eu

VERSION=${1:?usage: tool/release_notes.sh VERSION}
REPO_URL="https://github.com/${GITHUB_REPOSITORY:-tiltozavr2545/mark_it_down_UI}"

cd "$(dirname "$0")/.."

# One version's section: from its `## ` heading up to the next one.
section=$(awk -v v="$VERSION" '
  /^## / {
    if (found) exit
    if (index($0, "## " v " ") == 1 || $0 == "## " v) found = 1
  }
  found
' CHANGELOG.md)
[ -n "$section" ] || {
  echo "release-notes: CHANGELOG.md has no \"## $VERSION\" section" >&2
  exit 1
}

# Joins wrapped lines: a blank line, a heading, a list item, a table row,
# or a code fence starts a new line; anything else continues the current
# one. Code blocks pass through untouched.
unwrap() {
  awk '
    function flush() { if (line != "") print line; line = "" }
    /^```/ { flush(); print; code = !code; next }
    code { print; next }
    /^[[:space:]]*$/ { flush(); print ""; next }
    /^#/ || /^\|/ { flush(); print; next }
    /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/ { flush(); line = $0; next }
    {
      text = $0
      sub(/^[[:space:]]+/, "", text)
      line = (line == "") ? text : line " " text
    }
    END { flush() }
  '
}

# `](path)` → `](https://github.com/…/blob/main/path)`; absolute links and
# anchors stay as they are.
absolute_links() {
  sed -E 's#\]\(([^)h#][^)]*|h[^t][^)]*)\)#](REPO/blob/main/\1)#g' \
    | sed "s#](REPO/#](${REPO_URL}/#g"
}

# The section's own heading becomes "What's new in …", one level below
# the page title, like the template's headings.
printf '%s\n' "$section" \
  | sed -E "1s/^## [^ ]+ *(— *)?/### What's new in $VERSION: /; 1s/: \$//" \
  | unwrap | absolute_links
printf '\n'
unwrap < .github/release-notes.md | absolute_links
