#!/usr/bin/env bash

orchid_die() { echo "orchid: $*" >&2; exit 1; }
atomic_write() { local d="$1" t; t="$(mktemp "${d}.tmp.XXXXXX")"; cat >"$t"; mv "$t" "$d"; }
orchid_state()   { echo "$1/.orchid"; }
orchid_runtime() { local r="$1/.orchid/runtime"; mkdir -p "$r"; echo "$r"; }

with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local w=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$w" 2>/dev/null; then kill "$w" 2>/dev/null; wait "$w" 2>/dev/null; return "$rc"; fi
  return 124
}

_cfg_env_name() { echo "ORCHID_$(echo "$1" | tr 'a-z.' 'A-Z_')"; }
# Last matching `key=value` line in the file wins (append-to-override, as in
# a typical shell/config file); this was a `head -n1` (first-wins) bug that
# silently made appended config overrides no-ops. Found while writing Task 8's
# doctor test, which appends a second `role.implementer=` line expecting it
# to take effect.
_cfg_file_get() {
  local k_esc
  k_esc=$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')
  [ -f "$1" ] && grep -E "^$k_esc=" "$1" | tail -n1 | cut -d= -f2- || true
}
config_get() {
  local repo="$1" key="$2" def="${3:-}" v env
  env="$(_cfg_env_name "$key")"
  eval "v=\${$env:-}"; [ -n "$v" ] && { echo "$v"; return; }
  v="$(_cfg_file_get "$repo/orchid.config" "$key")"; [ -n "$v" ] && { echo "$v"; return; }
  v="$(_cfg_file_get "$HOME/.orchid/config" "$key")"; [ -n "$v" ] && { echo "$v"; return; }
  echo "$def"
}
config_provenance() {
  local repo="$1" key="$2" env v
  env="$(_cfg_env_name "$key")"; eval "v=\${$env:-}"
  [ -n "$v" ] && { echo env; return; }
  [ -n "$(_cfg_file_get "$repo/orchid.config" "$key")" ] && { echo repo; return; }
  [ -n "$(_cfg_file_get "$HOME/.orchid/config" "$key")" ] && { echo user; return; }
  echo default
}

_pid_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -d ' ' || true; }
lock_acquire() {
  local repo="$1" rt lock brk
  rt="$(orchid_runtime "$repo")"; lock="$rt/lock"
  brk="${ORCHID_LOCK_BREAK_S:-$(config_get "$repo" lock_break_s 900)}"
  if ! mkdir "$lock" 2>/dev/null; then
    local pid host pstart age now mt
    pid="$(jq -r .pid "$lock/owner.json" 2>/dev/null || echo 0)"
    host="$(jq -r .hostname "$lock/owner.json" 2>/dev/null || echo '?')"
    pstart="$(jq -r .pid_start "$lock/owner.json" 2>/dev/null || echo '?')"
    now="$(date +%s)"; mt="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock")"
    age=$(( now - mt ))
    local alive=1
    if [ "$host" != "$(hostname)" ]; then alive=0
    elif ! kill -0 "$pid" 2>/dev/null; then alive=0
    elif [ "$(_pid_start "$pid")" != "$pstart" ]; then alive=0; fi
    if [ "$alive" -eq 0 ] && [ "$age" -gt "$brk" ]; then
      rm -rf "$lock"; mkdir "$lock" || return 1
      echo "lock-broken (owner pid $pid dead/foreign, age ${age}s)"
    else
      echo "orchid: lock held by pid $pid on $host" >&2; return 1
    fi
  fi
  if ! jq -n --arg p "$$" --arg s "$(_pid_start "$$")" --arg h "$(hostname)" \
    --arg e "$(epoch_current "$repo")" \
    '{pid:($p|tonumber), pid_start:$s, hostname:$h, epoch:($e|tonumber? // 0)}' \
    > "$lock/owner.json" 2>/dev/null; then
    rm -rf "$lock"
    return 1
  fi
}
lock_release() { rm -rf "$(orchid_runtime "$1")/lock"; }

epoch_current() { cat "$(orchid_runtime "$1")/epoch" 2>/dev/null || echo 0; }
epoch_require() {
  local cur; cur="$(epoch_current "$1")"
  [ "${ORCHID_EPOCH:-}" = "$cur" ] || orchid_die "stale epoch '${ORCHID_EPOCH:-unset}' (current $cur) — refused (INV-02)"
}
