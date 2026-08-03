#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
export HOME="$WORK/home"; mkdir -p "$HOME/.orchid"

echo hi | atomic_write "$WORK/f"; assert_eq hi "$(cat "$WORK/f")" "atomic write"

# v1-m3 Task 12: the running kernel's version constant, checked directly
# against lib/common.sh (tests/test_dispatcher.sh covers the same fact
# through the CLI's `orchid version` verb; this is the library-level source
# of truth both that verb and every manifest's `requires_orchid` check read).
# v1-m4: bumped to the release version 1.0.0 (no more `-mN` suffix).
assert_eq "1.0.0" "$ORCHID_VERSION" "ORCHID_VERSION is 1.0.0"

# layered config
mkdir -p "$WORK/repo"; cd "$WORK/repo" || exit 1; git init -q .
printf 'role.implementer=codex\n' > "$HOME/.orchid/config"
assert_eq codex "$(config_get "$WORK/repo" role.implementer)" "user layer"
printf 'role.implementer=claude\n' > "$WORK/repo/orchid.config"
assert_eq claude "$(config_get "$WORK/repo" role.implementer)" "repo overrides user"
ORCHID_ROLE_IMPLEMENTER=agy \
  assert_eq agy "$(ORCHID_ROLE_IMPLEMENTER=agy config_get "$WORK/repo" role.implementer)" "env overrides repo"
assert_eq repo "$(config_provenance "$WORK/repo" role.implementer)" "provenance"

# v1-m4: hyphenated keys (a custom role id, e.g. role.code-reviewer) must get
# a working env override too -- `_cfg_env_name` used to only map `.` to `_`,
# never `-`, so a hyphenated key's "env name" carried a raw hyphen through
# (an invalid bash identifier -- config_get's own `eval "v=\${$env:-}"` would
# throw a bad-substitution error if that value were ever actually consulted).
assert_eq "ORCHID_ROLE_CODE_REVIEWER" "$(_cfg_env_name role.code-reviewer)" \
  "_cfg_env_name maps both '.' and '-' to '_'"
printf 'role.code-reviewer=agy\n' > "$WORK/repo/orchid.config"
assert_eq agy "$(config_get "$WORK/repo" role.code-reviewer)" "hyphenated key resolves from repo config"
assert_eq codex "$(ORCHID_ROLE_CODE_REVIEWER=codex config_get "$WORK/repo" role.code-reviewer)" \
  "hyphenated key's env override wins over repo config"
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

# -- plugin_digest covers symlinks (Fix 1: a symlinked entrypoint must not be
# swappable without changing the digest) -----------------------------------
mkdir -p "$WORK/plugin" "$WORK/link-target-a" "$WORK/link-target-b"
echo body > "$WORK/plugin/file"
ln -s "$WORK/link-target-a" "$WORK/plugin/link"
d1="$(plugin_digest "$WORK/plugin")"
# repointing the symlink -- no regular file touched at all -- must still
# change the digest; a `find -type f` digest would miss this entirely.
rm "$WORK/plugin/link"; ln -s "$WORK/link-target-b" "$WORK/plugin/link"
d2="$(plugin_digest "$WORK/plugin")"
[ -n "$d1" ] && [ -n "$d2" ] || fail "plugin_digest must produce a nonempty digest"
[ "$d1" != "$d2" ] || fail "plugin_digest must change when a symlink inside the dir is repointed"

# -- trust store record format: `<digest> <path>`, so paths with spaces
# resolve correctly (Fix 2) --------------------------------------------------
spaced="$WORK/plugin dir with spaces"
mkdir -p "$spaced"
trust_store_set "$spaced" "deadbeef"
assert_eq "deadbeef $spaced" "$(cat "$HOME/.orchid/trust")" "trust record is '<digest> <path>' (digest first field)"
assert_eq deadbeef "$(trust_lookup "$spaced")" "trust_lookup resolves a path containing spaces"
trust_store_set "$spaced" "deadbeef"
trust_line_count="$(wc -l < "$HOME/.orchid/trust" | tr -d ' ')"
assert_eq 1 "$trust_line_count" "re-setting the same spaced path does not duplicate the record"
trust_store_remove "$spaced"
[ -z "$(trust_lookup "$spaced")" ] || fail "trust_store_remove clears a spaced-path record"
[ ! -s "$HOME/.orchid/trust" ] || fail "trust file is empty after removing its only (spaced-path) record"

# -- with_timeout (v1-m2 Task 7 regression): a fast command's own exit
# status/output must survive capture through $(...), and the run must
# return promptly even with a LONG deadline -- not just eventually succeed,
# but return well under the deadline. This is the regression net for a real
# bug found wiring up runners/orchid-tick: the watcher's own `sleep "$secs"`
# had already forked as a real child of the watcher subshell by the time
# with_timeout went to cancel it, and a bare `kill "$w"` (no process-group
# targeting) killed only the subshell, orphaning that `sleep` under init for
# the rest of its deadline -- which kept the orphan's inherited stdout pipe
# open and hung any `$(...)`-capturing caller (exactly runners/orchid-tick's
# own usage) for the full deadline on every otherwise-successful run.
start="$(date +%s)"
out="$(with_timeout 3600 bash -c 'echo fast; exit 7')"; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq fast "$out" "with_timeout captures the timed command's stdout"
assert_eq 7 "$rc" "with_timeout returns the timed command's own exit status"
[ "$elapsed" -lt 10 ] || fail "with_timeout must return promptly on early finish, not linger near the deadline (took ${elapsed}s)"

# timeout path: a command that outlives the deadline is killed and 124 is
# returned.
start="$(date +%s)"
out="$(with_timeout 1 bash -c 'sleep 30; echo should-not-print')"; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq 124 "$rc" "with_timeout returns 124 on timeout"
assert_eq "" "$out" "with_timeout's killed command produces no output"
[ "$elapsed" -lt 10 ] || fail "with_timeout must return promptly after killing on timeout (took ${elapsed}s)"
