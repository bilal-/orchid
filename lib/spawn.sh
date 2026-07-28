#!/usr/bin/env bash
# spawn_child_env <plugin-dir> -- prints NAME=value lines: the fixed base
# allowlist (PATH HOME USER LANG TERM TMPDIR, any LC_*, any ORCHID_*) plus
# exactly the env var NAMES this plugin's plugin.conf `permissions=` opts
# into (e.g. permissions=OPENAI_API_KEY) that are actually set in THIS
# process's own environment. Everything else the caller's environment might
# hold -- including a name that happens to look sensitive -- is never
# printed, and thus never reaches a child spawned from these lines.
#
# Extracted VERBATIM (v1-m2 Task 7) from runners/orchid-launch's inline env-
# hygiene block (v1-m1 Task 5) so runners/orchid-tick's synchronous adapter
# spawn can share the identical walk instead of re-implementing it -- the
# existing launch/e2e tests remain the regression net for this logic; only
# its home moved. Callers must source lib/manifest.sh first (this function
# calls manifest_permissions).
#
# Built from `compgen -e` (exported-variable NAMES only, no values) rather
# than scraping `env`'s NAME=value output -- a value containing an embedded
# newline could otherwise corrupt a naive line-based parse (bash 3.2 has no
# NUL-delimited env enumeration built in). Trade-off carried over from the
# original inline version, now with one more line-based hop added on top (the
# caller reads this function's own stdout back line-by-line to rebuild its
# `env -i` argv) -- accepted for v1: every name this function ever prints is
# either the fixed base list or an operator-declared `permissions=` name, and
# none of those are ever expected to hold embedded-newline values in practice.
_launch_base_allowed() {  # name -> 0 if base-allowlisted
  case "$1" in
    PATH|HOME|USER|LANG|TERM|TMPDIR) return 0 ;;
    LC_*|ORCHID_*) return 0 ;;
    *) return 1 ;;
  esac
}
spawn_child_env() {  # plugin-dir -> "NAME=value" lines, one per line
  local plugin_dir="$1" _name _perm
  while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    _launch_base_allowed "$_name" && printf '%s=%s\n' "$_name" "${!_name}"
  done < <(compgen -e || true)
  while IFS= read -r _perm; do
    [ -n "$_perm" ] || continue
    _launch_base_allowed "$_perm" && continue   # already printed above
    [ -n "${!_perm+x}" ] || continue            # not set in parent: nothing to forward
    printf '%s=%s\n' "$_perm" "${!_perm}"
  done < <(manifest_permissions "$plugin_dir")
}
