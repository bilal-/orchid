#!/usr/bin/env bash
# .role file schema: key=value (id, requires=<cap,cap,...>,
# forbids=<cap,...> optional, description=...). Parsed as key=value via
# common.sh's _cfg_file_get exactly like plugin.conf -- NEVER sourced.
# Callers must source lib/common.sh (for _cfg_file_get) and lib/manifest.sh
# (for manifest_get, used by role_eligible) before this file.
#
# Roles live at $ORCHID_ROOT/roles/<role>.role. A search path (mirroring
# resolve_engine_exe's for engines, so custom roles can ship as plugins) is
# left for a later milestone -- v1-m1 only needs the five built-in roles.

_role_file() { echo "${ORCHID_ROOT:-}/roles/$1.role"; }

role_get() {  # role key [default]
  local role="$1" key="$2" def="${3:-}" v
  v="$(_cfg_file_get "$(_role_file "$role")" "$key")"
  [ -n "$v" ] && { echo "$v"; return; }
  echo "$def"
}

role_requires() {  # role -> required capability atoms, one per line
  local caps; caps="$(role_get "$1" requires)"
  [ -n "$caps" ] || return 0
  echo "$caps" | tr ',' '\n'
}

role_forbids() {  # role -> forbidden capability atoms, one per line
  local caps; caps="$(role_get "$1" forbids)"
  [ -n "$caps" ] || return 0
  echo "$caps" | tr ',' '\n'
}

# role_eligible <role> <plugin-dir> -- exit 0 iff the plugin's manifest
# capabilities are a superset of role.requires AND disjoint from
# role.forbids. Purely capability-driven: never branches on an engine name
# (INV-05) -- eligibility only ever looks at manifest_capabilities atoms.
role_eligible() {
  local role="$1" dir="$2" have=" " atom atoms req forb

  IFS=',' read -ra atoms <<< "$(manifest_get "$dir" capabilities)"
  for atom in "${atoms[@]}"; do
    [ -n "$atom" ] && have="$have$atom "
  done

  req="$(role_get "$role" requires)"
  if [ -n "$req" ]; then
    IFS=',' read -ra atoms <<< "$req"
    for atom in "${atoms[@]}"; do
      [ -n "$atom" ] || continue
      case "$have" in *" $atom "*) ;; *) return 1 ;; esac
    done
  fi

  forb="$(role_get "$role" forbids)"
  if [ -n "$forb" ]; then
    IFS=',' read -ra atoms <<< "$forb"
    for atom in "${atoms[@]}"; do
      [ -n "$atom" ] || continue
      case "$have" in *" $atom "*) return 1 ;; esac
    done
  fi

  return 0
}
