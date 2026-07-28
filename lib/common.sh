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

# -- Digest-pinned trust store (docs/specs/plugins.md, Trust model; INV-09) --
# Records live in `~/.orchid/trust` — OUTSIDE any repo, so cloning a repo can
# never itself grant code execution to a repo-local plugin. One line per
# trusted path: `<sha256-digest> <canonical-abs-path>` -- digest FIRST,
# because it's a fixed-width, space-free 64-hex token, so the path (which may
# itself contain spaces) can safely be "everything after the first space"
# rather than a single awk field. The reverse order (`<path> <digest>`)
# silently truncated any spaced path at its first space and could never
# match, which fails closed (trust never resolves) but is still wrong.

_trust_canon_path() {  # dir -> canonical absolute path (no trailing slash,
  # symlinks resolved), or nonzero if it doesn't exist / isn't a directory.
  ( cd "$1" 2>/dev/null && pwd -P )
}

_orchid_file_sha256() {  # file -> a line binding this file's path to its
  # content hash (exact format doesn't matter -- only that it's deterministic
  # and changes with either the path or the content -- since it is never
  # compared across machines/tools, only fed into plugin_digest below).
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    printf '%s %s\n' "$(openssl dgst -sha256 "$1" | awk '{print $NF}')" "$1"
  fi
}
_orchid_symlink_sha256() {  # symlink -> a line binding this symlink's path to
  # its TARGET STRING (not the target's content -- retargeting a symlink is
  # itself a change worth catching, whether or not the new target's bytes
  # happen to match the old one's), fed into plugin_digest below.
  if command -v shasum >/dev/null 2>&1; then
    printf '%s -> %s\n' "$1" "$(readlink "$1")" | shasum -a 256
  else
    printf '%s %s\n' \
      "$(printf '%s -> %s\n' "$1" "$(readlink "$1")" | openssl dgst -sha256 | awk '{print $NF}')" "$1"
  fi
}
_orchid_stream_sha256() {  # stdin -> hex digest of the whole stream
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

# plugin_digest <dir> -- SHA-256 over a stable sorted listing of the plugin
# dir's file AND symlink entries: `find <dir> \( -type f -o -type l \) |
# LC_ALL=C sort`, then per entry a regular file contributes `shasum -a 256
# <path>` while a symlink contributes a hash of "<path> -> <target>" (its
# target string, not the target's content), and the whole per-entry listing
# is rolled up with one final `shasum -a 256` (openssl dgst -sha256 fallback
# when shasum is absent). Symlinks must be covered, not just regular files:
# `find -type f` alone never sees a symlink, so a trusted plugin whose
# entrypoint is a symlink could have its executed target swapped without
# ever moving the digest (see also orchid-plugins' `trust`, which refuses to
# trust a symlinked entrypoint in the first place). With that covered, any
# file OR symlink added, removed, renamed, changed, or repointed inside the
# dir changes this digest.
plugin_digest() {
  local dir; dir="$(_trust_canon_path "$1")" || return 1
  [ -d "$dir" ] || return 1
  find "$dir" \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then _orchid_symlink_sha256 "$f"; else _orchid_file_sha256 "$f"; fi
  done | _orchid_stream_sha256
}

_orchid_trust_dir()  { echo "$HOME/.orchid"; }
_orchid_trust_file() { echo "$(_orchid_trust_dir)/trust"; }

trust_lookup() {  # abs-dir -> the recorded digest for that exact path, or
  # empty if there is no record. Last matching line wins (append-to-override,
  # consistent with _cfg_file_get's convention elsewhere in this file). Path
  # comparison strips only the leading `<digest> ` token off each line (see
  # the record-format note above), so a path containing spaces still matches
  # whole.
  local dir="$1" f; f="$(_orchid_trust_file)"
  [ -f "$f" ] || return 0
  awk -v d="$dir" '{p=$0; sub(/^[^ ]+ /, "", p); if (p==d) v=$1} END{if (v!="") print v}' "$f"
}

trust_status_for() {  # abs-dir -> trusted|untrusted|mismatch
  local dir="$1" rec cur
  rec="$(trust_lookup "$dir")"
  [ -n "$rec" ] || { echo untrusted; return 0; }
  cur="$(plugin_digest "$dir" 2>/dev/null)" || { echo mismatch; return 0; }
  [ "$rec" = "$cur" ] && echo trusted || echo mismatch
}

trust_store_set() {  # abs-dir digest -- atomic upsert (one record per path)
  local dir="$1" digest="$2" f; f="$(_orchid_trust_file)"
  mkdir -p "$(_orchid_trust_dir)"
  { [ -f "$f" ] && awk -v d="$dir" '{p=$0; sub(/^[^ ]+ /, "", p)} p!=d' "$f"; printf '%s %s\n' "$digest" "$dir"; } | atomic_write "$f"
}

trust_store_remove() {  # abs-dir -- atomic delete of any record for that path
  local dir="$1" f; f="$(_orchid_trust_file)"
  [ -f "$f" ] || return 0
  mkdir -p "$(_orchid_trust_dir)"
  awk -v d="$dir" '{p=$0; sub(/^[^ ]+ /, "", p)} p!=d' "$f" | atomic_write "$f"
}
