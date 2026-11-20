#!/usr/bin/env bash
# Prints one version's release notes as HTML, from its section of CHANGELOG.md: the list items
# under "## <version>", with wrapped lines joined and `code` kept. Sparkle shows them in the
# update window. Fails when the changelog has no notes for the version.
# Usage: scripts/release-notes.sh <version> [changelog]
set -euo pipefail
VERSION=${1:?usage: release-notes.sh <version> [changelog]}
CHANGELOG=${2:-"$(dirname "$0")/../CHANGELOG.md"}

awk -v version="$VERSION" '
function html(text,    parts, count, i, out) {
  gsub(/&/, "\\&amp;", text)
  gsub(/</, "\\&lt;", text)
  gsub(/>/, "\\&gt;", text)
  # Backticks come in pairs; an odd one out is left as it is.
  count = split(text, parts, "`")
  if (count % 2 == 0) return text
  out = parts[1]
  for (i = 2; i <= count; i++) out = out (i % 2 == 0 ? "<code>" : "</code>") parts[i]
  return out
}
function finish() {
  if (text == "") return
  if (isItem && !inList) { print "<ul>"; inList = 1 }
  if (!isItem && inList) { print "</ul>"; inList = 0 }
  print (isItem ? "<li>" : "<p>") html(text) (isItem ? "</li>" : "</p>")
  text = ""
  written++
}
$0 == "## " version { found = 1; next }
!found { next }
/^## / { exit }
/^- / { finish(); isItem = 1; text = substr($0, 3); next }
/^[[:space:]]*$/ { finish(); next }
{
  line = $0
  sub(/^[[:space:]]+/, "", line)
  if (text == "") { isItem = 0; text = line } else text = text " " line
}
END {
  finish()
  if (inList) print "</ul>"
  if (!written) { print "error: CHANGELOG.md has no notes for " version > "/dev/stderr"; exit 1 }
}
' "$CHANGELOG"
