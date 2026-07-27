#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

# INV-11: evidence is the sole authority — the log must exist, must record
# the exact command and exit code, and must flip honestly (FAIL -> PASS)
# purely because the underlying condition changed, never because the log
# was fudged.
"$ORCHID_BIN" task create T001 "flip demo"
"$ORCHID_BIN" task set T001 verification_commands "test -f marker.txt"

log=".orchid/reviews/T001-verify.log"
out="$WORK/verify.out"

rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "no marker -> FAIL"
assert_match "^FAIL$" "$(cat "$out")" "prints FAIL before marker exists"
[ -f "$log" ] || fail "evidence log exists after FAIL run"
assert_match "^command: test -f marker\.txt$" "$(cat "$log")" "evidence records exact command (FAIL run)"
assert_match "^exit: [1-9][0-9]*$" "$(cat "$log")" "evidence records nonzero exit (FAIL run)"

touch "$WORK/marker.txt"

rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "marker present -> PASS"
assert_match "^PASS$" "$(cat "$out")" "prints PASS after marker created"
[ -f "$log" ] || fail "evidence log exists after PASS run"
assert_match "^command: test -f marker\.txt$" "$(cat "$log")" "evidence records exact command (PASS run)"
assert_match "^exit: 0$" "$(cat "$log")" "evidence records exit 0 (PASS run)"

# Honesty check: the same command, same task, only the filesystem state
# changed — the log's own recorded exit code decided FAIL then PASS.
rm -f "$WORK/marker.txt"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "removing marker flips back to FAIL"
assert_match "^exit: [1-9][0-9]*$" "$(cat "$log")" "evidence flips back honestly"

# No verification_commands on the task and no config 'verify' -> dies
# nonzero with a clear message; no engine spawn is required to detect this.
"$ORCHID_BIN" task create T002 "no-command"
rc=0; err="$("$ORCHID_BIN" verify T002 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "verify with no command source must exit nonzero"
echo "$err" | grep -qi "verification_commands\|verify" || fail "die message must reference the missing verification source (got: $err)"
[ ! -f ".orchid/reviews/T002-verify.log" ] || fail "no evidence log should be written when there is nothing to run"
