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

# v0b2 F1 fix: risk_tier's monotonic-upward-only rule previously combined
# with a `medium` template default meant `low` could NEVER be reached (a
# downgrade is always refused) -- the whole single-reviewer low-risk
# routing path was dead on arrival. Fix: the template now defaults to
# `low`; plan time may leave it there or upgrade to medium/high, and the
# monotonic rule still guards every upgrade from being walked back down.
assert_eq low "$("$ORCHID_BIN" task show T001 | grep '^risk_tier: ' | cut -d' ' -f2)" "fresh task defaults risk_tier to low"

# risk monotonicity: low -> medium -> high all legal upgrades; any downgrade
# attempt, at any rung, is refused.
"$ORCHID_BIN" task set T001 risk_tier medium --reason "touches shared util"
assert_eq medium "$("$ORCHID_BIN" task show T001 | grep '^risk_tier: ' | cut -d' ' -f2)" "risk_tier low -> medium upgrade allowed"
rc=0; "$ORCHID_BIN" task set T001 risk_tier low --reason x 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "risk downgrade (medium -> low) must be refused"
"$ORCHID_BIN" task set T001 risk_tier high --reason "touches auth"
assert_eq high "$("$ORCHID_BIN" task show T001 | grep '^risk_tier: ' | cut -d' ' -f2)" "risk_tier medium -> high upgrade allowed"
rc=0; "$ORCHID_BIN" task set T001 risk_tier low --reason x 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "risk downgrade (high -> low) must be refused"

# Fix 3: retry is only legal from blocked or rework
"$ORCHID_BIN" task create T002 "retry-guard"
rc=0; "$ORCHID_BIN" task retry T002 --reason "not allowed" 2>/dev/null || rc=$?
assert_eq 3 "$rc" "retry from pending must exit 3"

"$ORCHID_BIN" task create T003 "retry-ok"
"$ORCHID_BIN" task advance T003 implementing
"$ORCHID_BIN" task advance T003 blocked --reason "demo blocker"
"$ORCHID_BIN" task retry T003 --reason "guidance given"
assert_eq rework "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "retry from blocked -> rework"

# v0b2: `task advance <id> implementing` stamps frontmatter `started_at`
# (ISO) when it is still empty — the task wall-clock anchor `jobs check`
# reads for the budget-exceeded backstop.
"$ORCHID_BIN" task create T004 "started-at-demo"
assert_eq "" "$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)" "started_at empty before dispatch"
"$ORCHID_BIN" task advance T004 implementing
started1="$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)"
[ -n "$started1" ] || fail "advance ... implementing must stamp started_at"
assert_match "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$started1" "started_at looks like an ISO-8601 UTC stamp"
"$ORCHID_BIN" task advance T004 blocked --reason "demo blocker (unrelated)"
sleep 1
"$ORCHID_BIN" task unblock T004 --reason "guidance given"
"$ORCHID_BIN" task advance T004 implementing
started2="$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)"
assert_eq "$started1" "$started2" "advance ... implementing never overwrites an already-set started_at"

# v0b2: `task infra-fail <id> --reason "..."` is the dedicated kernel-owned
# path that bumps `infra_failures` (the general `task set` deny-list blocks
# writing it any other way), journals an `intervention` entry, and — once
# the count reaches `infra_max` (config, default 3) — auto-advances the task
# to `blocked` itself (legal from any status) with reason "infra_failures
# cap reached", printing that.
"$ORCHID_BIN" task create T006 "infra-fail-demo"
"$ORCHID_BIN" task advance T006 implementing
"$ORCHID_BIN" task infra-fail T006 --reason "job j-1 dead after one retry"
assert_eq "1" "$("$ORCHID_BIN" task show T006 | grep '^infra_failures: ' | cut -d' ' -f2)" "infra-fail #1 increments infra_failures"
assert_match "infra failure #1: job j-1 dead after one retry" "$(cat .orchid/journal.md)" "infra-fail #1 journals an intervention"
assert_eq "implementing" "$("$ORCHID_BIN" task show T006 | grep '^status: ' | cut -d' ' -f2)" "infra-fail #1 (below infra_max) does not touch status"

"$ORCHID_BIN" task infra-fail T006 --reason "job j-2 dead after one retry"
assert_eq "2" "$("$ORCHID_BIN" task show T006 | grep '^infra_failures: ' | cut -d' ' -f2)" "infra-fail #2 increments infra_failures"
assert_eq "implementing" "$("$ORCHID_BIN" task show T006 | grep '^status: ' | cut -d' ' -f2)" "infra-fail #2 (below infra_max) does not touch status"

out="$("$ORCHID_BIN" task infra-fail T006 --reason "job j-3 dead after one retry")"
assert_match "infra_failures cap reached" "$out" "infra-fail #3 prints the cap-reached reason"
assert_eq "3" "$("$ORCHID_BIN" task show T006 | grep '^infra_failures: ' | cut -d' ' -f2)" "infra-fail #3 increments infra_failures to the cap"
assert_eq "blocked" "$("$ORCHID_BIN" task show T006 | grep '^status: ' | cut -d' ' -f2)" "infra-fail #3 auto-advances to blocked at infra_max"
assert_match "infra_failures cap reached" "$(cat .orchid/journal.md)" "infra-fail auto-block journals the cap-reached reason"

rc=0; "$ORCHID_BIN" task infra-fail T006 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "infra-fail without --reason must fail"
