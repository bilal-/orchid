#!/usr/bin/env bash
# plugin.conf schema (v1) — see docs/specs/plugins.md (Manifest section).
# Parsed as key=value, NEVER sourced (reuses _cfg_file_get's escaping from
# lib/common.sh, which callers must source before this file).

# Keys understood at manifest_version=1; anything else is an unknown key
# (warn, still valid) rather than a hard failure.
_MANIFEST_KNOWN_KEYS=" manifest_version id version kind api_version requires_orchid capabilities permissions requires_binaries platforms entrypoint "

# This file's own directory, regardless of who sources it or their cwd —
# BASH_SOURCE[0] inside a function is the file the function is DEFINED in,
# not the caller's file, so this stays correct even when ORCHID_ROOT is
# unset (e.g. tests sourcing lib/manifest.sh directly).
_manifest_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

manifest_get() {  # plugin-dir key [default]
  local dir="$1" key="$2" def="${3:-}" v
  v="$(_cfg_file_get "$dir/plugin.conf" "$key")"
  [ -n "$v" ] && { echo "$v"; return; }
  echo "$def"
}

manifest_capabilities() {  # plugin-dir -> capability atoms, one per line
  local caps; caps="$(manifest_get "$1" capabilities)"
  [ -n "$caps" ] || return 0
  echo "$caps" | tr ',' '\n'
}

_manifest_known_capability() {  # atom
  grep -qxF "$1" "$(_manifest_lib_dir)/capabilities.txt"
}

manifest_validate() {  # plugin-dir
  local dir="$1" conf="$1/plugin.conf" ok=1

  if [ ! -f "$conf" ]; then
    echo "FAIL: $dir: no plugin.conf"
    return 1
  fi

  local mv; mv="$(manifest_get "$dir" manifest_version)"
  if [ -z "$mv" ]; then
    echo "FAIL: $dir: manifest_version missing"
    ok=0
  elif [ "$mv" != 1 ]; then
    echo "FAIL: $dir: unknown manifest_version '$mv' (rejected, fail closed)"
    return 13
  fi

  local id; id="$(manifest_get "$dir" id)"
  if [ -z "$id" ]; then
    echo "FAIL: $dir: id missing"; ok=0
  else
    case "$id" in
      *..*) echo "FAIL: $dir: id '$id' contains '..'"; ok=0 ;;
    esac
    if ! printf '%s' "$id" | grep -Eq '^[a-z0-9_-]+/[a-z0-9_-]+$'; then
      echo "FAIL: $dir: id '$id' is not qualified as publisher/name"; ok=0
    fi
  fi

  local kind; kind="$(manifest_get "$dir" kind)"
  case "$kind" in
    engine|archetype|notify|hook|role) ;;
    *) echo "FAIL: $dir: kind '$kind' is not one of engine|archetype|notify|hook|role"; ok=0 ;;
  esac

  local av; av="$(manifest_get "$dir" api_version)"
  if [ -z "$av" ]; then
    echo "FAIL: $dir: api_version missing"; ok=0
  elif ! printf '%s' "$av" | grep -Eq '^[0-9]+$'; then
    echo "FAIL: $dir: api_version '$av' is not an integer"; ok=0
  elif [ "$av" != 1 ]; then
    echo "FAIL: $dir: unknown api_version '$av' (rejected, fail closed)"
    return 13
  fi

  local ver; ver="$(manifest_get "$dir" version)"
  if [ -z "$ver" ]; then
    echo "FAIL: $dir: version missing"; ok=0
  elif ! printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+'; then
    echo "FAIL: $dir: version '$ver' is not semver-ish (expected N.N...)"; ok=0
  fi

  case "$kind" in
    engine|notify)
      local ep; ep="$(manifest_get "$dir" entrypoint)"
      if [ -z "$ep" ]; then
        echo "FAIL: $dir: entrypoint missing (required for kind=$kind)"; ok=0
      elif [ ! -f "$dir/$ep" ] || [ ! -x "$dir/$ep" ]; then
        echo "FAIL: $dir: entrypoint '$ep' is not an executable file in $dir"; ok=0
      fi
      ;;
  esac

  if [ "$kind" = engine ]; then
    local caps atom atoms
    caps="$(manifest_get "$dir" capabilities)"
    if [ -n "$caps" ]; then
      IFS=',' read -ra atoms <<< "$caps"
      for atom in "${atoms[@]}"; do
        if ! _manifest_known_capability "$atom"; then
          echo "FAIL: $dir: unknown capability atom '$atom'"; ok=0
        fi
      done
    fi
  fi

  # Unknown KEYS (in a known manifest_version) warn but never invalidate.
  local key
  while IFS='=' read -r key _; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$_MANIFEST_KNOWN_KEYS" in
      *" $key "*) ;;
      *) echo "warn: $dir: unknown key '$key' in plugin.conf" >&2 ;;
    esac
  done < "$conf"

  if [ "$ok" -eq 1 ]; then
    echo "ok: $dir"
    return 0
  fi
  return 1
}
