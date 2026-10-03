#!/usr/bin/env bash
# Shared environment allowlist for adapters and notify plugins. The base names
# are PATH, HOME, USER, LANG, TERM, TMPDIR, LC_*, and ORCHID_*; other names must
# be explicitly requested in plugin.conf permissions and set in the parent.
# Source after lib/common.sh and lib/manifest.sh.
#
# spawn_child_env emits assignments for inspection (newline-delimited by
# default, NUL-delimited with --null). Effectful callers use the checked
# spawn_child_env_load array loader so a producer failure cannot spawn an
# adapter with partial credentials, and multiline values stay intact.

_launch_base_allowed() {  # name -> 0 if base-allowlisted
  case "$1" in
    PATH|HOME|USER|LANG|TERM|TMPDIR) return 0 ;;
    LC_*|ORCHID_*) return 0 ;;
    *) return 1 ;;
  esac
}
_spawn_env_emit() {
  if [ "$3" = --null ]; then
    printf '%s=%s\0' "$1" "$2"
  else
    printf '%s=%s\n' "$1" "$2"
  fi
}
spawn_child_env() {  # plugin-dir [--null] -> NAME=value assignments
  local plugin_dir="$1" mode="${2:-}" _name _perm perms
  while IFS= read -r _name; do
    [ -n "$_name" ] || continue
    if _launch_base_allowed "$_name"; then
      _spawn_env_emit "$_name" "${!_name}" "$mode" || return 1
    fi
  done < <(compgen -e || true)
  perms="$(manifest_permissions "$plugin_dir")" || return 1
  while IFS= read -r _perm; do
    [ -n "$_perm" ] || continue
    if ! _orchid_env_name_valid "$_perm"; then
      echo "orchid: invalid permission '$_perm' (expected an environment variable name)" >&2
      return 1
    fi
    _launch_base_allowed "$_perm" && continue   # already printed above
    [ -n "${!_perm+x}" ] || continue            # not set in parent: nothing to forward
    _spawn_env_emit "$_perm" "${!_perm}" "$mode" || return 1
  done <<< "$perms"
  return 0
}

# Populate the caller's child_env array. An empty NUL record marks successful
# completion and cannot collide with a NAME=value assignment. This checks the
# producer across process substitution without storing credentials in a file.
# Every value, including embedded newlines, remains one array element.
spawn_child_env_load() {
  local _spawn_line complete=0
  child_env=()
  while IFS= read -r -d '' _spawn_line; do
    if [ -z "$_spawn_line" ]; then complete=1; continue; fi
    child_env+=("$_spawn_line")
  done < <(spawn_child_env "$1" --null && printf '\0')
  if [ "$complete" -ne 1 ]; then
    child_env=()
    return 1
  fi
  return 0
}
