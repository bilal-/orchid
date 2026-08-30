#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: every reason-bearing verb is invoked below with the reason MISSING --
#      `task arbitrate ... --result approve` (the arbitration outcome verb, and
#      since T032 the only public route onto `arbitrating:merging`) with no
#      `--reason` at all, and `--reason`
#      as a trailing flag with no value on advance/unblock/retry/set -- and
#      each must be refused with a message naming the missing value rather
#      than crashing on an unbound variable. Kernel-owned keys (`status`,
#      `attempts`, `updated`, `schema`) are then set directly and must be
#      refused too, with the value read back to prove nothing moved. A
#      decision recorded without a reason is one a future resumer cannot
#      audit, which is the whole of INV-08.
# GREEN: two twins, both run in this file. The same advance WITH a reason
#      succeeds and the journal then carries the arbitration entry and a
#      kernel-derived actor; and a key the kernel does NOT own is still
#      accepted by `task set` and its value actually lands. Without them the
#      refusals above are equally consistent with a verb that is simply dead
#      and a `set` that refuses everything.
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
# Asked of `orchid task arbitrate`, which since T032 is the only public verb
# that reaches an arbitration OUTCOME edge out of `arbitrating` — `task advance T001
# merging` is now refused for being an arbitration result taken by a verb that
# records none, which would make the reason-less probe below pass for a reason
# that has nothing to do with INV-08. The requirement itself is unchanged and
# the edge taken is the same one.
rc=0; "$ORCHID_BIN" task arbitrate T001 --result approve 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-08: merging without --reason"
"$ORCHID_BIN" task arbitrate T001 --result approve --reason "both reviewers approve"
grep -q "arbitration" .orchid/journal.md || fail "INV-08: arbitration kind journaled"
grep -q '"by": *"operator' .orchid/journal.md 2>/dev/null || grep -q "(operator" .orchid/journal.md || fail "INV-08: actor kernel-derived"
green_case "the SAME advance WITH a reason succeeded and journalled an arbitration entry with a kernel-derived actor, so the refusal above is the reason guard discriminating rather than the verb being dead"

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

# ...and the GREEN twin for the deny-list specifically: a key that is NOT
# kernel-owned must still be settable, and must actually move. A `task set`
# that refused every key would satisfy all four refusals above while making the
# verb useless, and this file would still pass.
"$ORCHID_BIN" task set T001 blocking_severity high \
  || fail "INV-08: task set must still accept a key the kernel does not own, or the four refusals above prove only that set refuses everything"
assert_eq "high" "$("$ORCHID_BIN" task show T001 | grep '^blocking_severity: ' | cut -d' ' -f2)" \
  "INV-08: an accepted set must actually land its value"
green_case "a non-kernel-owned key was accepted by the same task set that refused status, attempts, updated and schema, and its value landed"

# Plan-A backlog step 3(b): `--reason` as the last arg with no value must die
# cleanly, not crash with an unbound-variable error (set -u).
out="$("$ORCHID_BIN" task set T001 risk_tier high --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "risk_tier --reason with no value must fail"
# HERESTRINGS throughout the four verbs below, never `echo "$out" | grep -q`
# (T016/INV-15 section 5). `grep -q` exits at its first match and SIGPIPEs
# `echo`, and under helpers.sh's `set -o pipefail` that kill-by-signal status
# becomes the pipeline's. Both directions are wrong here and the first is the
# expensive one: the `&& fail` line is SKIPPED exactly when the crash it looks
# for really is in the output, so the assertion that must catch an unbound-
# variable regression is the one the race switches off.
grep -q "unbound variable" <<<"$out" && fail "--reason with no value must not crash with an unbound-variable error"
grep -q "reason requires a value" <<<"$out" || fail "--reason with no value must die with a clear message (got: $out)"

# v0b1 fix: the same valueless-`--reason` guard must apply on every
# reason-bearing verb (advance/unblock/retry), not just `set risk_tier`.
# Fresh, minimal fixtures per verb so each is exercised in isolation.

# advance: `*:blocked` is always a legal transition, so a freshly created
# (pending) task can advance straight to blocked.
"$ORCHID_BIN" task create T010 reason-guard-advance >/dev/null
out="$("$ORCHID_BIN" task advance T010 blocked --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "advance --reason with no value must fail"
grep -q "unbound variable" <<<"$out" && fail "advance --reason with no value must not crash with an unbound-variable error"
grep -q "requires a value" <<<"$out" || fail "advance --reason with no value must die with a clear message (got: $out)"

# unblock: needs a task actually in `blocked` status first.
"$ORCHID_BIN" task create T011 reason-guard-unblock >/dev/null
"$ORCHID_BIN" task advance T011 blocked --reason "fixture blocker" >/dev/null
out="$("$ORCHID_BIN" task unblock T011 --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "unblock --reason with no value must fail"
grep -q "unbound variable" <<<"$out" && fail "unblock --reason with no value must not crash with an unbound-variable error"
grep -q "requires a value" <<<"$out" || fail "unblock --reason with no value must die with a clear message (got: $out)"

# retry: legal from blocked or rework; use a blocked fixture.
"$ORCHID_BIN" task create T012 reason-guard-retry >/dev/null
"$ORCHID_BIN" task advance T012 blocked --reason "fixture blocker" >/dev/null
out="$("$ORCHID_BIN" task retry T012 --reason 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "retry --reason with no value must fail"
grep -q "unbound variable" <<<"$out" && fail "retry --reason with no value must not crash with an unbound-variable error"
grep -q "requires a value" <<<"$out" || fail "retry --reason with no value must die with a clear message (got: $out)"
red_case "every reason-bearing verb refused a missing or valueless --reason, and every kernel-owned key refused a direct set with its value unchanged"
