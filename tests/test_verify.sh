#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

"$ORCHID_BIN" task create T001 "verify demo"
"$ORCHID_BIN" task set T001 verification_commands "exit 1"

out="$WORK/verify.out"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "failing command -> FAIL exits 1"
assert_match "^FAIL$" "$(cat "$out")" "prints FAIL"

log=".orchid/reviews/T001-verify.log"
[ -f "$log" ] || fail "evidence log written"
assert_match "^command: exit 1$" "$(cat "$log")" "evidence records the exact command"
assert_match "^exit: 1$" "$(cat "$log")" "evidence records the exit code"
assert_match "^date: " "$(cat "$log")" "evidence has date header"
assert_match "^sha: " "$(cat "$log")" "evidence has sha header"
assert_match "^cwd: " "$(cat "$log")" "evidence has cwd header"
assert_match "^---$" "$(cat "$log")" "evidence has separator"

# Now make it pass.
"$ORCHID_BIN" task set T001 verification_commands "exit 0"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "passing command -> PASS exits 0"
assert_match "^PASS$" "$(cat "$out")" "prints PASS"
assert_match "^exit: 0$" "$(cat "$log")" "evidence records exit 0 after fix"
