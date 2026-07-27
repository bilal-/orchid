#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
export HOME="$WORK/home"; mkdir -p "$HOME/.orchid"

echo hi | atomic_write "$WORK/f"; assert_eq hi "$(cat "$WORK/f")" "atomic write"

# layered config
mkdir -p "$WORK/repo"; cd "$WORK/repo"; git init -q .
printf 'role.implementer=codex\n' > "$HOME/.orchid/config"
assert_eq codex "$(config_get "$WORK/repo" role.implementer)" "user layer"
printf 'role.implementer=claude\n' > "$WORK/repo/orchid.config"
assert_eq claude "$(config_get "$WORK/repo" role.implementer)" "repo overrides user"
ORCHID_ROLE_IMPLEMENTER=agy \
  assert_eq agy "$(ORCHID_ROLE_IMPLEMENTER=agy config_get "$WORK/repo" role.implementer)" "env overrides repo"
assert_eq repo "$(config_provenance "$WORK/repo" role.implementer)" "provenance"
printf 'evil=$(touch %s/pwned)\n' "$WORK" >> "$WORK/repo/orchid.config"
config_get "$WORK/repo" evil >/dev/null; [ ! -e "$WORK/pwned" ] || fail "never sourced"

# key must be ERE-escaped before grep: dotted key `a.b` must not match `axb=1`
# (unescaped `.` in an ERE matches any char)
printf 'axb=1\n' > "$WORK/repo/orchid.config.dots"
[ -z "$(_cfg_file_get "$WORK/repo/orchid.config.dots" a.b)" ] || fail "unescaped '.' in key a.b must not match axb=1"
printf 'a.b=2\n' >> "$WORK/repo/orchid.config.dots"
assert_eq 2 "$(_cfg_file_get "$WORK/repo/orchid.config.dots" a.b)" "escaped key a.b still matches literal a.b=2"

# lock: acquire, contend, identity-guarded break
mkdir -p "$WORK/repo/.orchid"
lock_acquire "$WORK/repo" || fail "first acquire"
if lock_acquire "$WORK/repo" 2>/dev/null; then fail "second acquire must fail (live owner)"; fi
lock_release "$WORK/repo"
# dead-owner break: fake owner.json with dead pid and old mtime
lock_acquire "$WORK/repo"; rt="$WORK/repo/.orchid/runtime"
jq -n '{pid: 999999, pid_start: "x", epoch: 1, hostname: "'"$(hostname)"'"}' > "$rt/lock/owner.json"
touch -t 202001010000 "$rt/lock" "$rt/lock/owner.json"
out="$(ORCHID_LOCK_BREAK_S=1 lock_acquire "$WORK/repo")" || fail "break stale dead lock"
assert_match "lock-broken" "$out" "break reported"
lock_release "$WORK/repo"
# live-owner break attempt must fail: age alone is not enough. Craft
# owner.json around a genuinely live process (real pid, real pid_start via
# the same `ps -o lstart=` recipe lib/common.sh uses, current hostname),
# backdate the lock dir AND owner.json mtime far beyond lock_break_s, then
# confirm ORCHID_LOCK_BREAK_S=1 still refuses to break it: liveness must
# win over age, or a live owner's lock could be stolen out from under it.
lock_acquire "$WORK/repo"
sleep 60 & live_pid=$!
live_pstart="$(ps -o lstart= -p "$live_pid" 2>/dev/null | tr -d ' ')"
jq -n --arg p "$live_pid" --arg s "$live_pstart" --arg h "$(hostname)" \
  '{pid: ($p|tonumber), pid_start: $s, epoch: 1, hostname: $h}' > "$rt/lock/owner.json"
touch -t 202001010000 "$rt/lock" "$rt/lock/owner.json"
if out="$(ORCHID_LOCK_BREAK_S=1 lock_acquire "$WORK/repo" 2>&1)"; then
  fail "live owner's lock must not break on stale age alone (got: $out)"
fi
[ -d "$rt/lock" ] || fail "live owner's lock dir must survive a failed break attempt"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
lock_release "$WORK/repo"

# epochs
echo 3 > "$rt/epoch"
assert_eq 3 "$(epoch_current "$WORK/repo")" "epoch read"
( export ORCHID_EPOCH=2; if ( epoch_require "$WORK/repo" ) 2>/dev/null; then exit 1; fi ) || fail "stale epoch refused"
( export ORCHID_EPOCH=3; epoch_require "$WORK/repo" ) || fail "current epoch accepted"
