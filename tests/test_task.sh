#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

"$ORCHID_BIN" task create T001 "demo"
assert_eq pending "$(fm() { "$ORCHID_BIN" task show T001 | grep "^status: " | cut -d' ' -f2; }; fm)" "created pending"
"$ORCHID_BIN" task advance T001 implementing
rc=0; "$ORCHID_BIN" task advance T001 done 2>/dev/null || rc=$?
assert_eq 3 "$rc" "illegal transition exits 3"

# journal + reasons
rc=0; "$ORCHID_BIN" task advance T001 blocked 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "blocked without --reason must fail"
"$ORCHID_BIN" task advance T001 blocked --reason "demo blocker"
assert_match "demo blocker" "$(cat .orchid/journal.md)" "reason journaled atomically"
"$ORCHID_BIN" task unblock T001 --reason "guidance given"
assert_eq rework "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "unblock -> rework"

# risk monotonicity
"$ORCHID_BIN" task set T001 risk_tier high --reason "touches auth"
rc=0; "$ORCHID_BIN" task set T001 risk_tier low --reason x 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "risk downgrade must be refused"

# Fix 3: retry is only legal from blocked or rework
"$ORCHID_BIN" task create T002 "retry-guard"
rc=0; "$ORCHID_BIN" task retry T002 --reason "not allowed" 2>/dev/null || rc=$?
assert_eq 3 "$rc" "retry from pending must exit 3"

"$ORCHID_BIN" task create T003 "retry-ok"
"$ORCHID_BIN" task advance T003 implementing
"$ORCHID_BIN" task advance T003 blocked --reason "demo blocker"
"$ORCHID_BIN" task retry T003 --reason "guidance given"
assert_eq rework "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "retry from blocked -> rework"
