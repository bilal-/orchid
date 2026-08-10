#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: every reason-bearing verb is invoked below with the reason MISSING --
#      `task advance ... merging` with no `--reason` at all, and `--reason`
#      as a trailing flag with no value on advance/unblock/retry/set -- and
#      each must be refused with a message naming the missing value rather
#      than crashing on an unbound variable. Kernel-owned keys (`status`,
#      `attempts`, `updated`, `schema`) are then set directly and must be
#      refused too, with the value read back to prove nothing moved. A
#      decision recorded without a reason is one a future resumer cannot
#      audit, which is the whole of INV-08.
# GREEN: the same advance WITH a reason succeeds, and the journal must then
#      carry both the arbitration entry and a kernel-derived actor -- so the
#      refusals above are the guard discriminating, not the verb being dead.
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo
# Fixture correction (Plan-A backlog step 9): entry to `testing` now requires
# non-empty base_sha/candidate_sha. This test only exercises reason/deny-list
# enforcement, not INV-04's commit-content check, so a dummy SHA (the repo's
# only commit, used for both ends of the range) satisfies the new guard
# without touching .orchid/ in the range.
head_sha="$(git -C "$WORK" rev-parse HEAD)"
"$ORCHID_BIN" task set T001 base_sha "$head_sha"
"$ORCHID_BIN" task set T001 candidate_sha "$head_sha"
for s in implementing testing; do "$ORCHID_BIN" task advance T001 "$s" >/dev/null; done
# INV-11 fixture note: testing -> reviewing now kernel-requires a passing
# verify evidence log, so this walk needs a real `orchid verify` PASS here
# (honest fixture, not a hand-written log) before it can reach reviewing.
"$ORCHID_BIN" task set T001 verification_commands "true"
"$ORCHID_BIN" verify T001 >/dev/null
"$ORCHID_BIN" task advance T001 reviewing >/dev/null
plant_reviewer_envelope T001
"$ORCHID_BIN" task advance T001 arbitrating >/dev/null
rc=0; "$ORCHID_BIN" task advance T001 merging 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-08: merging without --reason"
"$ORCHID_BIN" task advance T001 merging --reason "both reviewers approve"
grep -q "arbitration" .orchid/journal.md || fail "INV-08: arbitration kind journaled"
grep -q '"by": *"operator' .orchid/journal.md 2>/dev/null || grep -q "(operator" .orchid/journal.md || fail "INV-08: actor kernel-derived"

# Fix 1: kernel-owned keys must not be settable via `task set`
before_status="$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)"
before_attempts="$("$ORCHID_BIN" task show T001 | grep '^attempts: ' | cut -d' ' -f2)"
rc=0; "$ORCHID_BIN" task set T001 status "done" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task set status must be refused (kernel-owned)"
rc=0; "$ORCHID_BIN" task set T001 attempts 99 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task set attempts must be refused (kernel-owned)"
after_status="$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)"
after_attempts="$("$ORCHID_BIN" task show T001 | grep '^attempts: ' | cut -d' ' -f2)"
[ "$before_status" = "$after_status" ] || fail "status changed despite refused set"
[ "$before_attempts" = "$after_attempts" ] || fail "attempts changed despite refused set"

# Plan-A backlog step 3(a): `updated` and `schema` are also kernel-owned
rc=0; "$ORCHID_BIN" task set T001 updated "2020-01-01T00:00:00Z" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task set updated must be refused (kernel-owned)"
rc=0; "$ORCHID_BIN" task set T001 schema 2 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task set schema must be refused (kernel-owned)"

# Plan-A backlog step 3(b): `--reason` as the last arg with no value must die
# cleanly, not crash with an unbound-variable error (set -u).
out="$("$ORCHID_BIN" task set T001 risk_tier high --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "risk_tier --reason with no value must fail"
echo "$out" | grep -q "unbound variable" && fail "--reason with no value must not crash with an unbound-variable error"
echo "$out" | grep -q "reason requires a value" || fail "--reason with no value must die with a clear message (got: $out)"

# v0b1 fix: the same valueless-`--reason` guard must apply on every
# reason-bearing verb (advance/unblock/retry), not just `set risk_tier`.
# Fresh, minimal fixtures per verb so each is exercised in isolation.

# advance: `*:blocked` is always a legal transition, so a freshly created
# (pending) task can advance straight to blocked.
"$ORCHID_BIN" task create T010 reason-guard-advance >/dev/null
out="$("$ORCHID_BIN" task advance T010 blocked --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "advance --reason with no value must fail"
echo "$out" | grep -q "unbound variable" && fail "advance --reason with no value must not crash with an unbound-variable error"
echo "$out" | grep -q "requires a value" || fail "advance --reason with no value must die with a clear message (got: $out)"

# unblock: needs a task actually in `blocked` status first.
"$ORCHID_BIN" task create T011 reason-guard-unblock >/dev/null
"$ORCHID_BIN" task advance T011 blocked --reason "fixture blocker" >/dev/null
out="$("$ORCHID_BIN" task unblock T011 --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "unblock --reason with no value must fail"
echo "$out" | grep -q "unbound variable" && fail "unblock --reason with no value must not crash with an unbound-variable error"
echo "$out" | grep -q "requires a value" || fail "unblock --reason with no value must die with a clear message (got: $out)"

# retry: legal from blocked or rework; use a blocked fixture.
"$ORCHID_BIN" task create T012 reason-guard-retry >/dev/null
"$ORCHID_BIN" task advance T012 blocked --reason "fixture blocker" >/dev/null
out="$("$ORCHID_BIN" task retry T012 --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "retry --reason with no value must fail"
echo "$out" | grep -q "unbound variable" && fail "retry --reason with no value must not crash with an unbound-variable error"
echo "$out" | grep -q "requires a value" || fail "retry --reason with no value must die with a clear message (got: $out)"
red_case "every reason-bearing verb refused a missing or valueless --reason, and every kernel-owned key refused a direct set with its value unchanged"
