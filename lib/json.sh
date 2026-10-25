#!/usr/bin/env bash
# Encoding and JSON shape only, never path ownership. Callers must first bound
# their input size and arrange a stable snapshot when concurrent edits matter.
# No output, common.sh, ORCHID_ROOT, or source-time process is required.
orchid_utf8_file_valid() (
  local source="${1:-}" converted rc
  [ "$#" -eq 1 ] && [ -f "$source" ] || return 1
  case "$source" in -*) source="./$source" ;; esac
  converted="$(mktemp "${TMPDIR:-/tmp}/orchid-utf8.XXXXXX" 2>/dev/null)" || return 1
  trap 'rc=$?; if ! rm -f "$converted"; then rc=1; fi; exit "$rc"' EXIT
  # jq substitutes U+FFFD for malformed UTF-8. Its output must preserve the
  # original bytes, and its producer status must succeed before comparison.
  if ! jq -Rrsj . 2>/dev/null < "$source" > "$converted"; then
    return 1
  fi
  if cmp -s "$source" "$converted" >/dev/null 2>&1; then return 0; else return 1; fi
)

orchid_json_file_valid() {
  [ "$#" -eq 1 ] || return 1
  orchid_utf8_file_valid "$1" || return 1
  # jq admits numeric extensions (NaN, +1, .5). Check JSON tokens before
  # handing structural validation to jq; this is deliberately not a parser.
  LC_ALL=C awk '
    function token_ok() {
      if (token == "") return 1
      return token == "true" || token == "false" || token == "null" ||
        token ~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/
    }
    {
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        if (quoted) {
          if (ch ~ /[\001-\037]/) { bad = 1; exit }
          if (escaped) escaped = 0
          else if (ch == "\\") escaped = 1
          else if (ch == "\"") quoted = 0
        } else if (ch == "\"") {
          if (!token_ok()) { bad = 1; exit }
          token = ""; quoted = 1
        } else if (ch ~ /[{}\[\],: \t\r]/) {
          if (!token_ok()) { bad = 1; exit }
          token = ""
        } else token = token ch
      }
      if (quoted || !token_ok()) { bad = 1; exit }
      token = ""
    }
    END { if (bad || quoted || !token_ok()) exit 1 }
  ' < "$1" || return 1
  if jq -es 'length == 1' 2>/dev/null < "$1" >/dev/null; then return 0; else return 1; fi
}
