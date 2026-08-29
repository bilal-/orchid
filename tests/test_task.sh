#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create T001 "demo"
assert_eq pending "$(fm() { "$ORCHID_BIN" task show T001 | grep "^status: " | cut -d' ' -f2; }; fm)" "created pending"

# v1-m3: `plan` is a reserved task id (plan-scoped critique jobs -- `orchid
# jobs prepare plan <role> critique`, PROTOCOL PLANNING step 2). `task
# create` must refuse it outright, before any file is written.
rc=0; plan_refuse_out="$("$ORCHID_BIN" task create plan "should be refused" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task create plan must be refused (reserved id)"
assert_match "reserved" "$plan_refuse_out" "task create plan names it reserved"
[ ! -f ".orchid/tasks/plan.md" ] || fail "task create plan must not write a task file"

# v1-m3 fix (Important 1, post-review): `task set`/`task unblock` on a
# NONEXISTENT id (including the reserved `plan`) must die cleanly, before
# any read/write of the task file -- previously `set` could crash via
# `fm_set`'s `awk ... | atomic_write` pipe (atomic_write writes an EMPTY
# file before awk's can't-open-file failure aborts the script), leaving a
# stray empty tasks/<id>.md behind, and `unblock` leaked a raw awk error to
# stderr before falling through to a misleading "not blocked" die. Both
# arms now check existence (and refuse `plan` by name) before touching the
# file at all.
before_count="$(ls .orchid/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')"

rc=0; set_nope_out="$("$ORCHID_BIN" task set NOPE somekey someval 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set on a nonexistent id must be refused"
assert_match "no task NOPE" "$set_nope_out" "task set on a nonexistent id names it (clean die, not a raw awk error)"
# Herestring, never `echo | grep -q` -- see the T034 block near the end of this
# file for why the pipe makes a NEGATIVE assertion fail open. These two guard
# the awk leak from the very pipeline T034 replaced, so they have to be able to
# fire.
grep -qi "awk" <<<"$set_nope_out" && fail "task set on a nonexistent id must never leak a raw awk error"

rc=0; set_plan_out="$("$ORCHID_BIN" task set plan somekey someval 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set plan must be refused (reserved id)"
assert_match "reserved" "$set_plan_out" "task set plan names it reserved"

rc=0; unblock_nope_out="$("$ORCHID_BIN" task unblock NOPE2 --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task unblock on a nonexistent id must be refused"
assert_match "no task NOPE2" "$unblock_nope_out" "task unblock on a nonexistent id names it (clean die, not a raw awk error)"
grep -qi "awk" <<<"$unblock_nope_out" && fail "task unblock on a nonexistent id must never leak a raw awk error"

rc=0; unblock_plan_out="$("$ORCHID_BIN" task unblock plan --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task unblock plan must be refused (reserved id)"
assert_match "reserved" "$unblock_plan_out" "task unblock plan names it reserved"

after_count="$(ls .orchid/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before_count" "$after_count" "no stray task file left behind by any of the four refused calls above"
[ ! -f ".orchid/tasks/NOPE.md" ] || fail "task set NOPE must not have written a stray task file"
[ ! -f ".orchid/tasks/NOPE2.md" ] || fail "task unblock NOPE2 must not have written a stray task file"
[ ! -f ".orchid/tasks/plan.md" ] || fail "task set/unblock plan must not have written a task file"

"$ORCHID_BIN" task advance T001 implementing
rc=0; "$ORCHID_BIN" task advance T001 "done" 2>/dev/null || rc=$?
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

# T028 (dogfood F30): `task set <id> depends_on <value>` refuses, at WRITE
# time, an id that names no task file. The scheduler cannot report such an id
# as an error later -- it can only say `waiting-deps (T999)`, which is what a
# task correctly waiting on an unfinished dependency says too -- so the write
# is the last moment the operator can be told the id resolves to nothing. Ids
# are split on commas as well as whitespace (lib/schedule.sh's
# schedule_split_deps, the same splitter the scheduler reads with), so a bad
# id hiding inside an otherwise-valid comma list is caught as well.
deps_before="$("$ORCHID_BIN" task show T002 | grep '^depends_on: ' | cut -d' ' -f2-)"
rc=0; dep_unknown_out="$("$ORCHID_BIN" task set T002 depends_on "T003,T999" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set depends_on with an id that has no task file must be refused"
assert_match "T999" "$dep_unknown_out" "the refusal names the unresolvable id"
assert_eq "$deps_before" "$("$ORCHID_BIN" task show T002 | grep '^depends_on: ' | cut -d' ' -f2-)" \
  "a refused depends_on write leaves the field exactly as it was"

# ...and the same call with every id resolving is accepted and stored as
# written -- otherwise the refusal above would be satisfied by a check that
# rejects every value.
"$ORCHID_BIN" task set T002 depends_on "T001,T003" \
  || fail "a comma-separated depends_on naming existing tasks must be accepted"
assert_eq "T001,T003" "$("$ORCHID_BIN" task show T002 | grep '^depends_on: ' | cut -d' ' -f2-)" \
  "an accepted depends_on is stored verbatim"
"$ORCHID_BIN" task set T002 depends_on "" \
  || fail "clearing depends_on must remain legal (no ids to resolve)"

# v0b2: `task advance <id> implementing` stamps frontmatter `started_at`
# (ISO) — the task wall-clock anchor `jobs check` reads for the
# budget-exceeded backstop.
"$ORCHID_BIN" task create T004 "started-at-demo"
assert_eq "" "$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)" "started_at empty before dispatch"
"$ORCHID_BIN" task advance T004 implementing
started1="$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)"
[ -n "$started1" ] || fail "advance ... implementing must stamp started_at"
assert_match "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$started1" "started_at looks like an ISO-8601 UTC stamp"

# T020: the anchor is PER ATTEMPT, not per task. It used to be stamped only
# once, ever ("stamp only if empty"), which made `wallclock_budget_s` measure
# calendar time since a task's first dispatch — every hour of operator
# downtime and overnight idling between attempts included. Every DISPATCH
# edge (pending/rework -> an active status) re-anchors it, so the budget
# bounds the attempt that is about to run. `sleep 1` is what makes the two
# stamps distinguishable at the ISO stamp's one-second resolution.
"$ORCHID_BIN" task advance T004 blocked --reason "demo blocker (unrelated)"
sleep 1
"$ORCHID_BIN" task unblock T004 --reason "guidance given"
"$ORCHID_BIN" task advance T004 implementing
started2="$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)"
assert_match "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$started2" "re-dispatch stamps a fresh ISO-8601 UTC started_at"
[ "$started2" != "$started1" ] || fail "rework -> implementing must RE-anchor started_at (attempt budget, not task budget)"

# ...but the intra-attempt edges are the SAME attempt and must NOT re-anchor:
# re-stamping at every phase would let one attempt run unbounded, a phase at a
# time. base_sha/candidate_sha are `testing`'s entry requirement; this
# fixture's single root commit serves as both, so the INV-04 guard walks an
# empty (and legal) commit range. The `sleep 1` is what would make an
# unwanted re-stamp visible at the ISO stamp's one-second resolution.
head_sha="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T004 base_sha "$head_sha"
"$ORCHID_BIN" task set T004 candidate_sha "$head_sha"
sleep 1
"$ORCHID_BIN" task advance T004 testing
assert_eq "$started2" "$("$ORCHID_BIN" task show T004 | grep '^started_at: ' | cut -d' ' -f2-)" \
  "implementing -> testing (same attempt) leaves started_at alone"

# T019: a strict candidate failure normally charges on testing -> rework. A
# valid custom code archetype may omit that edge, though, and the advance can
# also refuse before it writes. The driver needs one narrow kernel-owned way
# to preserve the charge while taking the universal blocked escape hatch.
# `--charge-attempt` is that way: journal-first, exactly one increment, and
# consumption of the deferred-failure receipt whose evidence it just accounted
# for.
#
# THE ADMITTED EDGES ARE A CLOSED SET, AND IT IS NO LONGER A SET OF ONE (T007).
# The flag shipped as `testing -> blocked` alone; T007 added `merging -> rework`
# and `merging -> blocked` for `orchid merge`'s `gate_failed` arm, which is the
# one merge failure that repeats identically until somebody outside the task
# acts on the repository. What the probes below are about is unchanged -- every
# edge OUTSIDE that set is still refused before any write -- but they must not
# go on describing the set as a single edge: an assertion whose message says
# "the only legal edge" is the thing a later reader trusts over the code, and
# `tests/test_merge.sh` (G3) plus `tests/test_docs.sh` would then be the only
# places the widening is written down. So each refusal below also pins that the
# message ENUMERATES the whole set and names the edge that was attempted.
"$ORCHID_BIN" task create T005 "charge a candidate failure while blocking"
"$ORCHID_BIN" task advance T005 implementing

rc=0
charge_source_out="$("$ORCHID_BIN" task advance T005 blocked --charge-attempt \
  --reason "candidate failure with no rework edge" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--charge-attempt must refuse a source the closed set does not admit"
assert_match "only valid for testing -> blocked" "$charge_source_out" \
  "the source-shape refusal names the edge this arm exists for"
assert_match "merging -> rework or merging -> blocked" "$charge_source_out" \
  "...and the REST of the admitted set beside it — a refusal that lists one of three edges reads as a narrower flag than the kernel actually has (T007)"
assert_match "got implementing -> blocked" "$charge_source_out" \
  "...and the edge that was actually attempted, so the caller is not left diffing the list against its own request"
assert_eq implementing "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" \
  "a refused charge leaves status untouched"
assert_eq 0 "$("$ORCHID_BIN" task show T005 | grep '^attempts: ' | cut -d' ' -f2)" \
  "and leaves attempts untouched"

"$ORCHID_BIN" task set T005 base_sha "$head_sha"
"$ORCHID_BIN" task set T005 candidate_sha "$head_sha"
"$ORCHID_BIN" task advance T005 testing
pending_receipt="a1:$head_sha:1111111111111111111111111111111111111111111111111111111111111111"
"$ORCHID_BIN" task set T005 verify_fail_pending "$pending_receipt"

rc=0
charge_dest_out="$("$ORCHID_BIN" task advance T005 rework --charge-attempt \
  --reason "wrong destination" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--charge-attempt must refuse testing -> rework, which already charges through its own accounting"
assert_match "only valid for testing -> blocked" "$charge_dest_out" \
  "the destination-shape refusal names the edges the flag IS admitted on"
assert_match "got testing -> rework" "$charge_dest_out" \
  "...and the edge that was refused: rework is a legal DESTINATION for the flag out of merging, so the refusal is about the whole edge and has to say which one"
assert_eq testing "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" \
  "a wrong-destination charge leaves status testing"
assert_eq 0 "$("$ORCHID_BIN" task show T005 | grep '^attempts: ' | cut -d' ' -f2)" \
  "and does not accidentally take rework's ordinary charge"
assert_eq "$pending_receipt" "$("$ORCHID_BIN" task show T005 | grep '^verify_fail_pending: ' | cut -d' ' -f2-)" \
  "a refused charge does not consume the evidence receipt"

rc=0
charge_conflict_out="$("$ORCHID_BIN" task advance T005 blocked --charge-attempt \
  --waive-attempt --reason "contradictory accounting" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--charge-attempt and --waive-attempt must be mutually exclusive"
assert_match "cannot be combined" "$charge_conflict_out" \
  "the contradictory accounting flags are refused explicitly"
assert_eq 0 "$("$ORCHID_BIN" task show T005 | grep '^attempts: ' | cut -d' ' -f2)" \
  "the contradictory request mutates no attempt budget"

charge_ok_out="$("$ORCHID_BIN" task advance T005 blocked --charge-attempt \
  --reason "candidate failure with no rework edge")"
assert_match "T005: testing -> blocked" "$charge_ok_out" \
  "the valid fallback reports the edge it took"
assert_eq blocked "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" \
  "the candidate-failure fallback lands blocked"
assert_eq 1 "$("$ORCHID_BIN" task show T005 | grep '^attempts: ' | cut -d' ' -f2)" \
  "and charges exactly one candidate attempt"
assert_eq "" "$("$ORCHID_BIN" task show T005 | grep '^verify_fail_pending: ' | cut -d' ' -f2-)" \
  "the accounted round's deferred-failure receipt is consumed"
assert_match "candidate attempt #1 charged while blocking: candidate failure with no rework edge" \
  "$(cat .orchid/journal.md)" \
  "the kernel-derived attempt number and reason are durable before the state move"

rc=0
charge_twice_out="$("$ORCHID_BIN" task advance T005 blocked --charge-attempt \
  --reason "must not charge twice" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a blocked task cannot be charged again with --charge-attempt"
assert_match "only valid for testing -> blocked" "$charge_twice_out" \
  "the repeat charge is rejected on its source state"
assert_match "got blocked -> blocked" "$charge_twice_out" \
  "...named as the edge it is, so a second charge is refused for being blocked -> blocked and never for being a second one"
assert_eq 1 "$("$ORCHID_BIN" task show T005 | grep '^attempts: ' | cut -d' ' -f2)" \
  "a repeated fallback cannot double-charge the round"

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

# ============================================================================
# v1-m2 Task 4: `legal()` is now archetype-driven -- it reads
# plugins/archetypes/feature/plugin.conf's `transitions=` instead of a
# hardcoded case table. This walk drives EVERY edge that table declares
# through one real feature task (T007), proving the archetype-driven path
# reproduces today's exact legality, edge for edge. base_sha/candidate_sha
# are both this repo's OWN HEAD throughout, so `git log <base>..<candidate>`
# is a real, EMPTY range and INV-04's `.orchid/` scan really does run and
# really does find nothing; and `verification_commands=true` makes `orchid
# verify` always PASS.
#
# They used to be a fixed placeholder sha that exists nowhere, which made
# `git log` fail rather than answer -- and the guard read that silence as a
# clean range. T026 made it fail CLOSED (an unanswerable range is refused, in
# the same direction every other unreadable-input check in this codebase
# fails), so a fixture that walked this edge on a non-existent range was
# proving the guard was vacuous, not that the edge was legal.
# are both the fixture's own HEAD throughout: the `to=testing` .orchid/-scan
# runs `git log <base>..<candidate>`, which prints nothing at all for an
# empty range, so this never trips INV-04's guard; and
# `verification_commands=true` makes `orchid verify` always PASS.
#
# T031: this used to be a fixed placeholder (non-existent) sha, which worked
# only because nothing ever asked whether the tree matched the claim.
# `orchid verify` now refuses to run against a worktree that is not the
# recorded candidate_sha, so the walk uses the sha the checkout is really at.
# ============================================================================
"$ORCHID_BIN" task create T007 "archetype edge walk"
edge_sha="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T007 base_sha "$edge_sha"
"$ORCHID_BIN" task set T007 candidate_sha "$edge_sha"
"$ORCHID_BIN" task set T007 verification_commands true
t007_status() { "$ORCHID_BIN" task show T007 | grep '^status: ' | cut -d' ' -f2; }

# edge: pending:implementing
"$ORCHID_BIN" task advance T007 implementing
assert_eq implementing "$(t007_status)" "archetype edge pending:implementing"

# edge: implementing:testing
"$ORCHID_BIN" task advance T007 testing
assert_eq testing "$(t007_status)" "archetype edge implementing:testing"

# edge: testing:rework (bumps attempts 0 -> 1; invalidates verify evidence,
# neither of which is set yet, so this is a no-op beyond the state move)
"$ORCHID_BIN" task advance T007 rework
assert_eq rework "$(t007_status)" "archetype edge testing:rework"
assert_eq 1 "$("$ORCHID_BIN" task show T007 | grep '^attempts: ' | cut -d' ' -f2)" "testing:rework bumped attempts to 1"

# edge: rework:implementing
"$ORCHID_BIN" task advance T007 implementing
assert_eq implementing "$(t007_status)" "archetype edge rework:implementing"

# edge: implementing:testing (again) -> real verify evidence -> reviewing
"$ORCHID_BIN" task advance T007 testing
"$ORCHID_BIN" verify T007 >/dev/null

# edge: testing:reviewing
"$ORCHID_BIN" task advance T007 reviewing
assert_eq reviewing "$(t007_status)" "archetype edge testing:reviewing"
plant_reviewer_envelope T007

# edge: reviewing:arbitrating
"$ORCHID_BIN" task advance T007 arbitrating --reason "single reviewer approved"
assert_eq arbitrating "$(t007_status)" "archetype edge reviewing:arbitrating"

# edge: arbitrating:rework (--waive-attempt: attempts stays at 1, so the
# reviewer envelope already planted -- bound to attempts+1 -- stays valid
# for every subsequent reviewing:arbitrating below without replanting)
"$ORCHID_BIN" task advance T007 rework --waive-attempt --reason "sent back for rework"
assert_eq rework "$(t007_status)" "archetype edge arbitrating:rework"
assert_eq 1 "$("$ORCHID_BIN" task show T007 | grep '^attempts: ' | cut -d' ' -f2)" "--waive-attempt left attempts at 1"

# rework:implementing -> implementing:testing -> re-verify (arbitrating:rework
# invalidated the prior evidence) -> testing:reviewing -> reviewing:arbitrating
"$ORCHID_BIN" task advance T007 implementing
"$ORCHID_BIN" task advance T007 testing
"$ORCHID_BIN" verify T007 >/dev/null
"$ORCHID_BIN" task advance T007 reviewing
"$ORCHID_BIN" task advance T007 arbitrating --reason "re-reviewed, approved"

# edge: arbitrating:merging
"$ORCHID_BIN" task advance T007 merging --reason "approved for merge"
assert_eq merging "$(t007_status)" "archetype edge arbitrating:merging"

# edge: merging:testing (does NOT invalidate verify evidence -- only a
# to=rework transition does -- so the existing PASS, still bound to the
# unchanged candidate_sha, survives)
"$ORCHID_BIN" task advance T007 testing
assert_eq testing "$(t007_status)" "archetype edge merging:testing"

# testing:reviewing (again, reusing the still-valid verify evidence and the
# still-bound reviewer envelope) -> reviewing:arbitrating -> arbitrating:merging
"$ORCHID_BIN" task advance T007 reviewing
"$ORCHID_BIN" task advance T007 arbitrating --reason "re-reviewed after merging:testing, approved"
"$ORCHID_BIN" task advance T007 merging --reason "approved for merge"

# edge: merging:rework
#
# A REAL merge log is planted first, so this edge exercises the rework brief on
# the one path where the evidence OUTLIVES the transition. `merging:rework`
# deliberately exempts `<id>-merge.log` from the invalidation every other entry
# to `rework` performs -- that log documents the very failure the advance is
# journalling -- and the two assertions after the edge are about what that
# survivor may then do.
mkdir -p .orchid/reviews
{ echo "date: 2026-08-11T00:00:00Z"
  echo "sha: $edge_sha"
  echo "candidate: $edge_sha"
  echo "command: fixture"
  echo "---"
  echo "lib/merged.sh:11: SC2115: the merged tree failed the same suite"
  echo "exit: 1"
} > .orchid/reviews/T007-merge.log
"$ORCHID_BIN" task advance T007 rework --reason "validation_failed: see reviews/T007-merge.log"
assert_eq rework "$(t007_status)" "archetype edge merging:rework"
assert_eq 1 "$("$ORCHID_BIN" task show T007 | grep '^attempts: ' | cut -d' ' -f2)" "merging:rework never bumps attempts (from=merging)"
[ -f .orchid/reviews/T007-merge.log ] \
  || fail "merging:rework must leave the merge log in place -- it is the evidence for the failure it just journalled"
assert_match "^lib/merged\.sh:11: SC2115: the merged tree failed the same suite$" \
  "$("$ORCHID_BIN" task show T007)" \
  "and the edge carried that log's exact locations into the task body (T010, lesson L017)"

# THE SAME BRIEF IS NEVER APPENDED TWICE.
#
# Aging withdraws the briefs describing some OTHER candidate; the ones
# describing the CURRENT candidate are still true and are left standing. That
# leaves one gap: a second entry to `rework` on an UNCHANGED candidate, with the
# same evidence log still on disk, regenerates a block identical to the one
# already in the body. The implementer is then handed the same locations twice,
# in two blocks it must read as two separate reports, and the body grows by one
# more copy on every further round -- the same defect a stale brief is, reached
# from the other side.
#
# `merging` -> `rework` then `orchid task retry` is the route that reaches it,
# and it is walked here exactly: the exempted merge log above is still on disk,
# `retry` re-reads it, and the candidate has not moved. The guard is on the
# APPEND rather than on this route (lib/findings.sh findings_brief_present),
# because every other way of reaching `rework` twice without minting a new
# candidate produces the same body.
t007_briefs() { "$ORCHID_BIN" task show T007 | grep -c 'Rework brief — exact locations'; }
t007_brief_n="$(t007_briefs)"
assert_eq 1 "$t007_brief_n" "one live brief stands after the merging:rework edge"
"$ORCHID_BIN" task retry T007 --reason "retry over the surviving merge log"
assert_eq rework "$(t007_status)" "retry leaves the task in rework"
assert_eq "$t007_brief_n" "$(t007_briefs)" \
  "and appends NO second copy of the brief it already carries"
assert_eq 1 "$("$ORCHID_BIN" task show T007 | grep -c 'lib/merged\.sh:11: SC2115')" \
  "the locations themselves appear exactly once, so nothing reads as two separate reports of one failure"

"$ORCHID_BIN" task advance T007 implementing
"$ORCHID_BIN" task advance T007 testing
"$ORCHID_BIN" verify T007 >/dev/null
"$ORCHID_BIN" task advance T007 reviewing
"$ORCHID_BIN" task advance T007 arbitrating --reason "re-reviewed, approved"
"$ORCHID_BIN" task advance T007 merging --reason "approved for merge"

# edge: merging:done
"$ORCHID_BIN" task advance T007 "done"
assert_eq "done" "$(t007_status)" "archetype edge merging:done"

# -- every edge in feature's declared transition table has now been driven
# through T007 (pending:implementing, implementing:testing, testing:reviewing,
# testing:rework, reviewing:arbitrating, arbitrating:merging,
# arbitrating:rework, merging:done, merging:rework, merging:testing,
# rework:implementing) -- plus *:blocked, already covered above via T001, and
# T026's two additions (rework:testing, blocked:testing), driven through the
# `task reverify` fixtures at the end of this file.

# -- one edge that was NEVER legal under the old hardcoded table stays
# illegal (exit 3) under the archetype-driven path too --------------------
"$ORCHID_BIN" task create T008 "still illegal"
rc=0; "$ORCHID_BIN" task advance T008 merging 2>/dev/null || rc=$?
assert_eq 3 "$rc" "pending -> merging is (and was always) illegal, exit 3"
assert_eq pending "$("$ORCHID_BIN" task show T008 | grep '^status: ' | cut -d' ' -f2)" "T008 stays in pending after the refused illegal edge"

# ============================================================================
# v1-m3 (m2 ledger finding): reviewing->arbitrating's envelope-count gate
# must count only status=="ok" reviewer envelopes, sha-binding kept
# alongside. A reviewer job that errored/quarantined before producing a real
# verdict can still land a same-shaped, sha-bound file on disk (status:
# "failed") -- that must never silently satisfy the gate just because a
# file with the right name and candidate_sha exists.
# ============================================================================
"$ORCHID_BIN" task create T009 "status-ok gate"
# The fixture's own HEAD, for the same reason edge_sha above is (T031:
# `orchid verify` refuses a tree that is not the recorded candidate_sha).
edge_sha2="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T009 base_sha "$edge_sha2"
"$ORCHID_BIN" task set T009 candidate_sha "$edge_sha2"
"$ORCHID_BIN" task set T009 verification_commands true
"$ORCHID_BIN" task advance T009 implementing
"$ORCHID_BIN" task advance T009 testing
"$ORCHID_BIN" verify T009 >/dev/null
"$ORCHID_BIN" task advance T009 reviewing
mkdir -p .orchid/reviews
jq -n --arg cand "$edge_sha2" '{contract:1, job_id:"j-fixture-T009-a1-failed", task:"T009", operation:"review",
    status:"failed", verdict:"approve", scope_complete:true, summary:"errored reviewer", candidate_sha:$cand}' \
  > .orchid/reviews/T009-a1-reviewer.json
rc=0; err="$("$ORCHID_BIN" task advance T009 arbitrating --reason "should be refused" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "reviewing->arbitrating must refuse when the only reconciled envelope has status!=ok"
assert_match "arbitrating requires 1 reconciled review envelope\(s\) for risk_tier low \(have 0\)" "$err" \
  "gate die message reports 0 -- the status:failed envelope was correctly not counted"
assert_eq reviewing "$("$ORCHID_BIN" task show T009 | grep '^status: ' | cut -d' ' -f2)" "refused arbitrating leaves T009 at reviewing"

jq -n --arg cand "$edge_sha2" '{contract:1, job_id:"j-fixture-T009-a1-ok", task:"T009", operation:"review",
    status:"ok", verdict:"approve", scope_complete:true, summary:"real reviewer", candidate_sha:$cand}' \
  > .orchid/reviews/T009-a1-reviewer.2.json
"$ORCHID_BIN" task advance T009 arbitrating --reason "now has a real ok envelope"
assert_eq arbitrating "$("$ORCHID_BIN" task show T009 | grep '^status: ' | cut -d' ' -f2)" \
  "reviewing->arbitrating succeeds once a status==ok envelope is reconciled (the status:failed one still doesn't count)"

# ============================================================================
# T026 (dogfood F28) -- the operator's two missing recovery moves.
#
# Both defects were found the same way: an operator diagnosed a failure
# correctly, said so through the only verbs that exist, and watched the run
# do the wrong thing anyway.
#
#   1. `task retry --reason` recorded the reason in the JOURNAL and nowhere
#      else. The journal is not an implementer input -- `pack_build` copies
#      the task FILE into the capsule -- so a retry carrying a precise
#      diagnosis was indistinguishable, from outside, from a retry carrying
#      nothing: the next attempt repeated the same mistake and no surface
#      said whether the reason had ever been delivered.
#   2. `retry`/`unblock` restore STATUS but granted no attempt budget, and
#      the budget itself was a literal `attempts >= 3` in the driver with
#      `attempts` on `task set`'s deny-list. A task that spent its rounds on
#      causes T019 says must not be charged could not be given another one
#      through any verb at all.
#
# Plus the edge neither verb ever offered: "the tree is green, re-run
# verification" (`task reverify`), whose absence had operators hand-editing
# task worktrees and committing on task branches with no name in the protocol.
# ============================================================================

tfield() { "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }
# One honest rework round: the same three edges a failing verify walks, so
# `attempts` below is only ever raised the way the kernel itself raises it --
# never hand-set (`task set attempts` is refused, which is half the point).
spend_one_attempt() {
  "$ORCHID_BIN" task advance "$1" implementing >/dev/null
  "$ORCHID_BIN" task advance "$1" testing >/dev/null
  "$ORCHID_BIN" task advance "$1" rework >/dev/null
}

# This file accumulates tasks parked in ACTIVE statuses as it goes (T004 in
# `testing`, T009 in `arbitrating`), which is already the default concurrency
# cap of 2 -- and every dispatch edge below (pending/rework into an active
# status, `reverify`'s rework:testing included) goes through
# schedule_dispatch_blockers. Scheduling is tested in tests/test_dispatcher.sh;
# raising the cap here keeps these fixtures about attempts and reverification,
# exactly as tests/test_jobs.sh does for its own wall-clock fixtures.
export ORCHID_CONCURRENCY=8

# -- attempt_budget is kernel-owned: `task set` must refuse it by name ------
"$ORCHID_BIN" task create T020 "budget is kernel-owned" >/dev/null
rc=0; ab_set_out="$("$ORCHID_BIN" task set T020 attempt_budget 9 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set attempt_budget must be refused (kernel-owned)"
assert_match "kernel-owned" "$ab_set_out" "the refusal says the key is kernel-owned"
assert_match "task retry" "$ab_set_out" "and names the ONE verb that writes it (got: $ab_set_out)"
assert_eq "" "$(tfield T020 attempt_budget)" "the refused set wrote nothing"

# -- retry DELIVERS the reason into the task body, and says so --------------
"$ORCHID_BIN" task create T021 "retry delivers its reason" >/dev/null
"$ORCHID_BIN" task advance T021 blocked --reason "fixture blocker"
retry_out="$("$ORCHID_BIN" task retry T021 --reason "the assertion on line 12 wants 'ok', not 'OK'")"
assert_eq rework "$(tfield T021 status)" "retry from blocked -> rework"
assert_match "Operator guidance" "$("$ORCHID_BIN" task show T021)" \
  "the reason is written into the task body -- the file pack_build copies into the implementer's capsule"
assert_match "wants 'ok', not 'OK'" "$("$ORCHID_BIN" task show T021)" \
  "verbatim, not a summary of it"
assert_match "guidance delivered to the task body" "$retry_out" \
  "and retry's own output says where it went, so delivery is visible without reading the file (got: $retry_out)"
assert_match "retry: the assertion on line 12" "$(cat .orchid/journal.md)" \
  "the journal still records the intervention (INV-08), it is simply no longer the ONLY place the reason lands"

# -- a retry that needs no extra budget must not shrink the one in force ----
assert_eq "" "$(tfield T021 attempt_budget)" \
  "a task with attempts spent BELOW the repo budget gets no frontmatter grant -- attempts+1 (=1) must never overwrite the default 3"
assert_match "attempt budget unchanged at 3" "$retry_out" \
  "and retry reports the budget it left alone, with the rounds remaining (got: $retry_out)"

# -- the exhausted-budget case: retry grants, and the grant is recorded -----
# Three real testing:rework rounds, so `attempts` reaches the default cap the
# honest way (each edge bumps it -- no hand-set counter anywhere).
"$ORCHID_BIN" task create T022 "spends its whole budget" >/dev/null
budget_sha="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T022 base_sha "$budget_sha"
"$ORCHID_BIN" task set T022 candidate_sha "$budget_sha"
spend_one_attempt T022
spend_one_attempt T022
spend_one_attempt T022
assert_eq 3 "$(tfield T022 attempts)" "three rework rounds consumed three attempts"
"$ORCHID_BIN" task advance T022 blocked --reason "attempts exhausted (3/3)"

grant_out="$("$ORCHID_BIN" task retry T022 --reason "two of those three were the formula-pin deadlock, not the candidate" --attempts 2)"
assert_eq 5 "$(tfield T022 attempt_budget)" \
  "--attempts 2 raises the cap to attempts+2 -- the operator's grant is measured from what has been SPENT"
assert_eq 3 "$(tfield T022 attempts)" \
  "and the attempts counter itself is never wound back: it is the attempt NUMBER every reviews/<id>-a<n>-*.json is keyed on"
assert_match "attempt budget 3 -> 5" "$grant_out" "retry reports the grant it made (got: $grant_out)"
assert_match "attempt budget 3 -> 5" "$(cat .orchid/journal.md)" "and journals it before writing it (INV-08)"

# A second grant is measured from the same spent count, and only ever raises:
# `--attempts 1` here wants 4, which is below the 5 already in force.
grant2_out="$("$ORCHID_BIN" task retry T022 --reason "second look, no more rounds needed")"
assert_eq 5 "$(tfield T022 attempt_budget)" "a smaller grant never shrinks a budget already in force"
assert_match "attempt budget unchanged at 5" "$grant2_out" "and says so (got: $grant2_out)"

# -- --attempts is validated, not silently coerced --------------------------
for bad_grant in 0 -1 two 1.5 ""; do
  rc=0; bad_out="$("$ORCHID_BIN" task retry T022 --reason "bad grant" --attempts "$bad_grant" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "task retry --attempts '$bad_grant' must be refused"
  assert_match "requires a value|positive integer" "$bad_out" \
    "--attempts '$bad_grant' is refused with a message that names the constraint (got: $bad_out)"
done
assert_eq 5 "$(tfield T022 attempt_budget)" "none of the refused grants wrote anything"

# -- unblock warns when it is handing back a task with no budget left -------
# It deliberately does NOT grant one (it is the "here is guidance" verb), so
# the operator has to be TOLD, or the next verify failure re-blocks instantly.
"$ORCHID_BIN" task create T023 "unblock with an empty budget" >/dev/null
unblock_sha="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T023 base_sha "$unblock_sha"
"$ORCHID_BIN" task set T023 candidate_sha "$unblock_sha"
spend_one_attempt T023
spend_one_attempt T023
spend_one_attempt T023
"$ORCHID_BIN" task advance T023 blocked --reason "attempts exhausted (3/3)"
unblock_warn="$("$ORCHID_BIN" task unblock T023 --reason "here is the fix" 2>&1 1>/dev/null)"
assert_match "attempts 3/3" "$unblock_warn" "unblock warns that the budget is spent (got: $unblock_warn)"
# `[-]-attempts N` matches the same text as `--attempts N`, but does not begin
# with a dash: `assert_match` passes its pattern as grep's FIRST argument, so a
# leading `--` is parsed as a long option and grep exits with its usage message
# instead of matching. The bracket is the smallest correct spelling here; the
# helper itself wants `grep -Eq -e "$1"`, which is a suite-wide change.
assert_match "[-]-attempts N" "$unblock_warn" "and names the verb that grants more"
assert_eq rework "$(tfield T023 status)" "the warning is a warning: unblock still did its job"
assert_eq "" "$(tfield T023 attempt_budget)" "and unblock granted nothing itself"

# -- ...and the verb that warning names does the job with no flag at all ----
# F28's headline ask is that `retry` "grant an attempt OR take --attempts N".
# The bare form is the one an operator reaches for after a diagnosis, so it
# has to buy a round on its own: a retry that restores status without a round
# is the exact trap (diagnosis -> one engine invocation -> identical failure
# -> re-blocked) this task exists to close.
bare_grant_out="$("$ORCHID_BIN" task retry T023 --reason "diagnosed: the fixture wants 'ok', not 'OK'")"
assert_eq 4 "$(tfield T023 attempt_budget)" \
  "a bare retry of a task with NO rounds left grants exactly one (out: $bare_grant_out)"
assert_eq 3 "$(tfield T023 attempts)" "and still never winds the counter back"
assert_match "attempt budget 3 -> 4" "$bare_grant_out" "and reports the round it bought (out: $bare_grant_out)"
# Repeated bare retries do not compound: the second wants the same 4 the first
# already granted, so the budget stays put rather than drifting up one round
# per keystroke.
bare_again_out="$("$ORCHID_BIN" task retry T023 --reason "same diagnosis, said twice")"
assert_eq 4 "$(tfield T023 attempt_budget)" "a second bare retry grants nothing on top (out: $bare_again_out)"
assert_match "attempt budget unchanged at 4" "$bare_again_out" "and says so (out: $bare_again_out)"

# -- an EXPLICIT `--attempts N` that would change nothing is REFUSED --------
# The grant only ever raises the cap, so on a task that still has rounds left
# the flag is satisfied before it is typed. Swallowing it prints the same
# "budget unchanged" line a bare retry prints, having silently declined the one
# thing the operator asked for -- and a flag that quietly does nothing is
# trusted for exactly as long as it takes to be blamed, because the next
# failure looks like the round was granted and spent. T023 is at 3 spent of a
# budget of 4 here, so `--attempts 1` is already covered.
rc=0
attempts_noop="$("$ORCHID_BIN" task retry T023 --attempts 1 --reason "and one more round on top of that" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an --attempts N that would grant nothing must be refused, not swallowed (out: $attempts_noop)"
assert_match "would grant task T023 nothing" "$attempts_noop" \
  "and the refusal says what it declined to do (out: $attempts_noop)"
assert_match "budget is already 4 with 3 spent" "$attempts_noop" \
  "showing the arithmetic the operator could not see (out: $attempts_noop)"
assert_match "[-]-attempts 2" "$attempts_noop" \
  "and naming the smallest number that WOULD buy a round, so the refusal is a route rather than a dead end (out: $attempts_noop)"
assert_eq 4 "$(tfield T023 attempt_budget)" "the refused retry granted nothing"
grep -q "and one more round on top of that" .orchid/journal.md \
  && fail "a refused retry journals nothing either -- the flag is checked before the first write"
# A herestring, never `show | grep -q`: under pipefail (helpers.sh line 32),
# grep -q exiting at its first match can SIGPIPE `task show` mid-write and the
# 141 skips the `&& fail` -- exactly when the guidance IS in the body.
grep -q "and one more round on top of that" <<<"$("$ORCHID_BIN" task show T023)" \
  && fail "and appends no guidance: the task body must not carry a diagnosis for a retry that never happened"

# ...and the same flag with a number that DOES buy a round works, which is what
# makes the refusal above about the no-op and nothing else.
attempts_grant="$("$ORCHID_BIN" task retry T023 --attempts 2 --reason "the next two failures will be the environment as well")"
assert_eq 5 "$(tfield T023 attempt_budget)" "--attempts 2 on a task 3 spent of 4 raises the budget to 5 (out: $attempts_grant)"
assert_match "attempt budget 4 -> 5" "$attempts_grant" "and reports the move (out: $attempts_grant)"

# ============================================================================
# `orchid task reverify <id> --reason "..."` -- blocked|rework -> testing.
# The supported "the tree is green, re-run verification without another
# implementation pass" edge: no attempt consumed, the candidate re-stamped
# from the worktree the operator actually fixed, the stale verify evidence
# dropped so the next run is a real one.
# ============================================================================
"$ORCHID_BIN" task create T024 "reverify after an operator fix" >/dev/null
# `reverify` refuses a worktree with uncommitted changes (see the RED case
# below), so from here on this scratch repo has to be honestly clean -- and it
# is not: line 4 puts the fixture's HOME at "$WORK/home", inside the repo,
# where it shows up as untracked. Ignoring it is what a real repo does with
# its own test junk. `.orchid/` needs no entry: the verb excludes kernel state
# on its own account, because every verb writes it into the working tree by
# design and INV-04 bars it from candidates anyway.
# `wt/` joins it for the same reason: the RED cases below put a second and a
# third CHECKOUT of this repository under it (a task worktree is how a real run
# is laid out, and it is the only way to point a task's HEAD somewhere other
# than this one). A nested checkout carries a `.git` file, so an untracked
# `wt/` would read as an uncommitted change in every assertion after it.
printf 'home/\nwt/\n' > .gitignore
mkdir -p "$WORK/wt"
git add .gitignore
git commit -q -m "fixture: ignore the scratch HOME this suite plants inside the repo"
rev_base="$(git rev-parse HEAD)"
# EVERY TASK FILE NAMES A BRANCH (`branch: task/<id>`, templates/task.md), and
# the reverify edge checks that the commit it is about to certify is CONTAINED
# in it -- a clean tree says nothing about whose work is standing in it. A real
# task worktree is on its own branch by construction (drive_worktree_plan cuts
# one per task); this scratch repo does all of its work in one checkout on one
# branch, so the records are pointed at the branch their commits are really on.
# That is the same move the refusal itself prescribes (`orchid task set <id>
# branch <name>`), and it keeps these fixtures honest rather than exempt: the
# RED cases further down are refused on this exact axis.
rev_branch="$(git rev-parse --abbrev-ref HEAD)"
"$ORCHID_BIN" task set T024 base_sha "$rev_base"
"$ORCHID_BIN" task set T024 candidate_sha "$rev_base"
"$ORCHID_BIN" task set T024 branch "$rev_branch"
"$ORCHID_BIN" task set T024 verification_commands true
"$ORCHID_BIN" task advance T024 implementing >/dev/null
"$ORCHID_BIN" task advance T024 testing >/dev/null
"$ORCHID_BIN" task advance T024 rework >/dev/null
assert_eq 1 "$(tfield T024 attempts)" "fixture: the rework round consumed one attempt"
# A PASSING log left on disk and still bound to the OLD candidate_sha: the
# stale evidence reverify has to drop, or INV-11's testing -> reviewing gate
# would accept it as proof for a tree it never ran against.
"$ORCHID_BIN" verify T024 >/dev/null
[ -f .orchid/reviews/T024-verify.log ] || fail "fixture: T024 should have stale verify evidence on disk before reverify"

# The operator's own fix, committed by hand on the task's tree -- the exact
# move that had no verb before this one. (`git add <path>`, never `-a`: a
# sweep would pull `.orchid/` into the commit and INV-04 would refuse entry
# to `testing` -- correctly.)
echo "the two-word test fix" > operator-fix.txt
git add operator-fix.txt
git commit -q -m "operator: fix the fixture the implementer kept getting wrong"
rev_fixed="$(git rev-parse HEAD)"

reverify_out="$("$ORCHID_BIN" task reverify T024 --reason "the tree is green: the operator fixed the fixture by hand")"
assert_eq testing "$(tfield T024 status)" "reverify: rework -> testing (archetype edge rework:testing)"
assert_eq 1 "$(tfield T024 attempts)" "reverify consumes NO attempt -- that is the whole point of it"
assert_eq "$rev_fixed" "$(tfield T024 candidate_sha)" \
  "and re-stamps candidate_sha from the task worktree's HEAD, so the evidence it is about to produce binds to the tree that will actually be tested"
[ ! -f .orchid/reviews/T024-verify.log ] \
  || fail "reverify must drop the stale verify evidence -- a prior PASS must never satisfy INV-11 on the re-verified candidate's behalf"
assert_match "no attempt consumed" "$reverify_out" "reverify says so in its own output (got: $reverify_out)"
assert_match "reverify: the tree is green" "$(cat .orchid/journal.md)" "and journals the operator's reason"
assert_match "candidate_sha $rev_base -> $rev_fixed" "$(cat .orchid/journal.md)" \
  "and journals the candidate re-stamp before writing it (INV-08)"

# The re-verified candidate walks on from `testing` exactly like any other:
# fresh evidence, then the ordinary gate.
"$ORCHID_BIN" verify T024 >/dev/null
"$ORCHID_BIN" task advance T024 reviewing >/dev/null
assert_eq reviewing "$(tfield T024 status)" \
  "a reverified candidate reaches reviewing on its own fresh, sha-bound evidence"

# -- blocked -> testing, the case the exhausted-attempts trap actually ends in
"$ORCHID_BIN" task create T025 "reverify straight out of blocked" >/dev/null
"$ORCHID_BIN" task set T025 base_sha "$rev_base"
"$ORCHID_BIN" task set T025 candidate_sha "$rev_fixed"
"$ORCHID_BIN" task set T025 branch "$rev_branch"
"$ORCHID_BIN" task advance T025 blocked --reason "attempts exhausted (3/3)"
# The anchor the PREVIOUS attempt left behind. `blocked` is an idle status, so
# nothing has been bounding it since -- and the moment reverify moves the task
# into `testing` it becomes live again for libexec/orchid-jobs' task-level
# budget backstop, which gates on exactly (active status + started_at +
# wallclock_budget_s). An anchor this old would put the task over any budget
# before its first re-verification command ran.
"$ORCHID_BIN" task set T025 started_at 2020-01-01T00:00:00Z
"$ORCHID_BIN" task set T025 wallclock_budget_s 3600
"$ORCHID_BIN" task reverify T025 --reason "the failing suite was the environment, not the candidate" >/dev/null
assert_eq testing "$(tfield T025 status)" "reverify: blocked -> testing (archetype edge blocked:testing)"
assert_eq 0 "$(tfield T025 attempts)" "still no attempt consumed"
# A dispatch into an active status re-anchors the wall-clock budget, whichever
# idle status it came FROM: `blocked -> testing` is a dispatch by every
# property that gate has (idle source, active destination, real work about to
# run), and the literal `pending|rework` source test that predated `reverify`
# silently exempted it -- leaving the re-verified task already over budget and
# escalated straight back to `blocked`, the same unconvergent recovery loop
# the anchor fix in `task advance` exists to prevent.
rev_anchor="$(tfield T025 started_at)"
[ "$rev_anchor" != 2020-01-01T00:00:00Z ] || \
  fail "reverify out of blocked must re-anchor started_at -- it is a dispatch into an active status (still: $rev_anchor)"

# ...and it is gated by the same dispatch predicates, for the same reason: a
# re-verification runs the task's whole suite in its worktree, which is the
# contention the concurrency cap bounds. Refused by `task advance` itself,
# naming the predicate verbatim, with the task left where it was.
"$ORCHID_BIN" task create T028 "reverify honors the dispatch gate" >/dev/null
"$ORCHID_BIN" task set T028 base_sha "$rev_base"
# Deliberately NOT the worktree's HEAD: a reverify that mutated before it
# validated would re-stamp this to $rev_fixed on its way to the refusal below,
# and the assertions after it are what catch that.
"$ORCHID_BIN" task set T028 candidate_sha "$rev_base"
"$ORCHID_BIN" task set T028 branch "$rev_branch"
"$ORCHID_BIN" task advance T028 blocked --reason "attempts exhausted (3/3)"
rc=0
rev_capped="$(ORCHID_CONCURRENCY=1 "$ORCHID_BIN" task reverify T028 --reason "capped: green tree, wrong moment" 2>&1)" || rc=$?
assert_eq 3 "$rc" "reverify is refused when the concurrency cap is already met (out: $rev_capped)"
assert_match "concurrency-cap" "$rev_capped" \
  "and the refusal names the schedule predicate verbatim (out: $rev_capped)"
assert_eq blocked "$(tfield T028 status)" "the refused reverify left the task where it was"
# VALIDATE BEFORE YOU MUTATE. The refusal is the whole outcome: a task that
# never moved must not be left carrying a re-stamped candidate and a pair of
# journal entries describing a move that did not happen. That record would
# outlive the refusal -- the next reader (operator, `task show`, a reconciled
# envelope binding on candidate_sha) has no way to tell it apart from a
# reverify that really did dispatch.
assert_eq "$rev_base" "$(tfield T028 candidate_sha)" \
  "a refused reverify re-stamps NOTHING -- every condition advance can refuse on is asked before the first write"
grep -q "capped: green tree, wrong moment" .orchid/journal.md \
  && fail "a refused reverify must not journal its reason either -- journal-first is for mutations that follow, and none did"

# -- a DIRTY worktree is refused, never certified ---------------------------
# The failure this closes: `orchid verify` runs the suite IN the task worktree
# but stamps its evidence with a sha. So an uncommitted change sitting there is
# exercised by the run while candidate_sha names a tree that never contained
# it, and the resulting PASS describes something that was never the candidate
# (lesson L025) -- produced by the verb that exists to be the SUPPORTED way to
# re-verify, which is exactly where an operator would never think to look for
# it. Untracked counts as much as modified: a suite reads a brand-new test file
# every bit as happily as an edited one.
"$ORCHID_BIN" task create T029 "reverify refuses a dirty worktree" >/dev/null
"$ORCHID_BIN" task set T029 base_sha "$rev_base"
"$ORCHID_BIN" task set T029 candidate_sha "$rev_base"
"$ORCHID_BIN" task set T029 branch "$rev_branch"
"$ORCHID_BIN" task advance T029 blocked --reason "attempts exhausted (3/3)"

# (a) untracked
echo "half of the fix, never committed" > operator-half-fix.txt
rc=0
rev_untracked="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T029 --reason "surely the tree is green by now" 2>&1)" || rc=$?
assert_eq 3 "$rc" "reverify refuses a worktree with uncommitted changes (out: $rev_untracked)"
assert_match "uncommitted changes" "$rev_untracked" \
  "and says what is wrong rather than certifying it (out: $rev_untracked)"
assert_match "operator-half-fix.txt" "$rev_untracked" \
  "NAMING what is uncommitted -- a refusal the operator cannot act on is a dead end (out: $rev_untracked)"
assert_match "commit them" "$rev_untracked" \
  "and naming the way out, since committing on the task branch is the procedure this verb exists to support (out: $rev_untracked)"
assert_eq blocked "$(tfield T029 status)" "the refused reverify left the task where it was"
assert_eq "$rev_base" "$(tfield T029 candidate_sha)" \
  "and never stamped HEAD as the candidate while something else would have been what actually ran"
grep -q "surely the tree is green by now" .orchid/journal.md \
  && fail "a refused reverify journals nothing either -- the refusal is the whole outcome"

# (b) tracked-but-modified, the same refusal by the same rule
git add operator-half-fix.txt
git commit -q -m "operator: commit the stray file"
echo "an edit on top, also uncommitted" >> operator-half-fix.txt
rc=0
rev_modified="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T029 --reason "and now surely it is green" 2>&1)" || rc=$?
assert_eq 3 "$rc" "a tracked file with uncommitted edits is refused too (out: $rev_modified)"
assert_match "operator-half-fix.txt" "$rev_modified" "named just the same (out: $rev_modified)"
assert_eq blocked "$(tfield T029 status)" "still untouched"

# (c) ...and once the operator commits, the same call goes straight through:
#     the refusal is a nudge into the supported procedure, not a dead end.
git add operator-half-fix.txt
git commit -q -m "operator: finish the fix"
rev_clean="$(git rev-parse HEAD)"
rev_ok="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T029 --reason "committed on the task branch — now re-verify it")"
assert_eq testing "$(tfield T029 status)" \
  "a CLEAN worktree reverifies exactly as before (out: $rev_ok)"
assert_eq "$rev_clean" "$(tfield T029 candidate_sha)" \
  "bound to the committed tree the suite will actually run against"
assert_eq 0 "$(tfield T029 attempts)" "and still no attempt consumed"
# The kernel state dir is the ONE thing that never counts as dirty here: every
# verb above wrote into `.orchid/` while this task sat blocked (this fixture
# never commits it at all), and INV-04 bars it from candidates anyway -- so it
# is never part of what the operator is asking to have verified. If the check
# ever stops excluding it, (c) fails and this is why.

# -- A CLEAN TREE IS NOT THE RIGHT TREE -------------------------------------
# The dirty-tree refusal above asks whether the worktree is certifiable AT ALL.
# Nothing in it asks WHOSE work is standing in it -- and adopting whatever a
# clean HEAD happens to be is the worse mis-binding of the two, because
# afterwards every field agrees and the evidence produced looks exactly right.
# A checkout left on another task, a HEAD detached by a bisect, a worktree path
# reused for something else: all clean, all certifiable, none of them this
# candidate. So the commit's lineage is a gate as much as the tree's state is.
"$ORCHID_BIN" task create T032 "reverify refuses a tree that is not this task's" >/dev/null
"$ORCHID_BIN" task set T032 base_sha "$rev_base"
"$ORCHID_BIN" task set T032 candidate_sha "$rev_clean"
"$ORCHID_BIN" task set T032 branch "$rev_branch"
"$ORCHID_BIN" task advance T032 blocked --reason "attempts exhausted (3/3)"

# (a) AN UNRELATED HISTORY. The orphan below shares no ancestor with the
#     candidate at all, so no amount of range-scanning would notice it: the
#     range between them is not a range. Built with plumbing and checked out in
#     a worktree of its own so this suite's own HEAD never moves.
rev_alien_tree="$(git hash-object -w -t tree /dev/null)"
rev_alien_sha="$(git commit-tree "$rev_alien_tree" -m "an unrelated line of work" < /dev/null)"
rev_alien_wt="$WORK/wt/alien"
git worktree add -q --detach "$rev_alien_wt" "$rev_alien_sha" \
  || fail "fixture: could not put a worktree on the unrelated commit"
"$ORCHID_BIN" task set T032 worktree "$rev_alien_wt"
rc=0
rev_alien_out="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T032 --reason "the tree over there is green" 2>&1)" || rc=$?
assert_eq 3 "$rc" "reverify refuses a clean worktree standing on an unrelated history (out: $rev_alien_out)"
assert_match "does not descend from the current candidate" "$rev_alien_out" \
  "and refuses on the ground that matters -- an operator's fix only ever ADDS commits on top of the candidate (out: $rev_alien_out)"
assert_match "$rev_clean" "$rev_alien_out" \
  "naming the candidate it declined to replace (out: $rev_alien_out)"
assert_match "$rev_alien_sha" "$rev_alien_out" \
  "and the commit it declined to certify -- those two shas ARE the mistake (out: $rev_alien_out)"
assert_eq blocked "$(tfield T032 status)" "the refused reverify left the task where it was"
assert_eq "$rev_clean" "$(tfield T032 candidate_sha)" \
  "and never stamped an unrelated commit as this task's candidate"
grep -q "the tree over there is green" .orchid/journal.md \
  && fail "a refused reverify journals nothing -- the refusal is the whole outcome"

# (b) A DESCENDANT, BUT NOT ON THE TASK'S BRANCH. Descent alone still admits a
#     commit made on a branch that merely forked from this candidate, which is
#     what an operator working two tasks in two checkouts produces by accident
#     -- and it is the shape whose commits silently vanish from the branch that
#     merges. Same worktree resolution, so this is the same door.
rev_off_wt="$WORK/wt/off-branch"
git worktree add -q --detach "$rev_off_wt" "$rev_clean" \
  || fail "fixture: could not detach a worktree at the candidate"
echo "the fix, committed off the task's branch" > "$rev_off_wt/operator-off-branch.txt"
git -C "$rev_off_wt" add operator-off-branch.txt
git -C "$rev_off_wt" commit -q -m "operator: the fix, on a detached HEAD"
rev_off_sha="$(git -C "$rev_off_wt" rev-parse HEAD)"
"$ORCHID_BIN" task set T032 worktree "$rev_off_wt"
rc=0
rev_off_out="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T032 --reason "it descends from the candidate, honest" 2>&1)" || rc=$?
assert_eq 3 "$rc" "a descendant that is not on the task's branch is refused too (out: $rev_off_out)"
assert_match "is not contained in task T032's branch" "$rev_off_out" \
  "and the refusal says which membership failed, not merely that something did (out: $rev_off_out)"
assert_match "$rev_off_sha" "$rev_off_out" "naming the commit it refused (out: $rev_off_out)"
assert_match "$rev_clean" "$rev_off_out" "and the candidate it would have replaced (out: $rev_off_out)"
assert_eq blocked "$(tfield T032 status)" "still where it was"
assert_eq "$rev_clean" "$(tfield T032 candidate_sha)" "and the candidate is untouched"

# (c) ...and the moment that same commit IS on a branch the record names, the
#     identical call goes through. The refusals above are about lineage and
#     nothing else -- not about worktrees, not about detachment as such.
git -C "$rev_off_wt" checkout -q -b task/T032-real
"$ORCHID_BIN" task set T032 branch task/T032-real
rev_lineage_ok="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T032 --reason "committed on the branch the record names — now re-verify it")"
assert_eq testing "$(tfield T032 status)" \
  "a commit that descends from the candidate AND sits on the task's branch reverifies (out: $rev_lineage_ok)"
assert_eq "$rev_off_sha" "$(tfield T032 candidate_sha)" "re-stamped to it"
assert_eq 0 "$(tfield T032 attempts)" "and still no attempt consumed"

# -- refusals ---------------------------------------------------------------
"$ORCHID_BIN" task create T026 "reverify guards" >/dev/null
rc=0; rev_pending="$("$ORCHID_BIN" task reverify T026 --reason "not from here" 2>&1)" || rc=$?
assert_eq 3 "$rc" "reverify from pending exits 3"
assert_match "illegal reverify from pending" "$rev_pending" "and names the status it refused (got: $rev_pending)"
assert_eq pending "$(tfield T026 status)" "the refused reverify moved nothing"

"$ORCHID_BIN" task advance T026 blocked --reason "now it is blocked"
rc=0; rev_noreason="$("$ORCHID_BIN" task reverify T026 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "reverify without --reason must fail (INV-08)"
assert_match "reverify requires --reason" "$rev_noreason" "and says which flag is missing (got: $rev_noreason)"
rc=0; rev_novalue="$("$ORCHID_BIN" task reverify T026 --reason 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "reverify --reason with no value must fail"
grep -q "unbound variable" <<<"$rev_novalue" && fail "reverify --reason with no value must not crash with an unbound-variable error"
assert_match "requires a value" "$rev_novalue" "and dies cleanly (got: $rev_novalue)"
assert_eq blocked "$(tfield T026 status)" "neither refusal moved the task"

# INV-05: an archetype with no `testing` state simply never declares
# blocked:testing/rework:testing, so reverify against one is refused as an
# illegal transition -- no branch on the archetype's NAME anywhere.
"$ORCHID_BIN" task create T027 "a report archetype cannot reverify" --archetype review >/dev/null
"$ORCHID_BIN" task advance T027 blocked --reason "fixture blocker"
rc=0; rev_report="$("$ORCHID_BIN" task reverify T027 --reason "there is nothing to verify" 2>&1)" || rc=$?
assert_eq 3 "$rc" "reverify on a report-outcome archetype exits 3 (its transition table has no blocked:testing)"
assert_match "illegal blocked -> testing" "$rev_report" "refused as an illegal transition, by declared data (got: $rev_report)"
assert_eq blocked "$(tfield T027 status)" "and the report task stays where it was"

# ============================================================================
# THE OTHER DOOR ONTO THE SAME EDGE (T026 rework).
#
# `blocked:testing`/`rework:testing` are declared transition DATA, so the
# public `task advance <id> testing` reaches the identical edge. When
# `reverify` alone carried the safeguards, that route bypassed every one of
# them -- the reason requirement, the clean-worktree refusal, the candidate
# binding, the evidence invalidation -- so verification could be made to
# certify exactly the tree those safeguards exist to refuse just by typing
# the other command. A guarded door beside an unguarded one guards nothing.
#
# So the conditions live on the EDGE, in functions both routes call. The
# fixtures below drive the raw route and demand the same answers.
# ============================================================================
"$ORCHID_BIN" task create T030 "the raw advance onto the reverify edge" >/dev/null
"$ORCHID_BIN" task set T030 base_sha "$rev_base"
# Deliberately NOT the worktree's HEAD (which is $rev_clean by now).
"$ORCHID_BIN" task set T030 candidate_sha "$rev_base"
"$ORCHID_BIN" task set T030 branch "$rev_branch"
"$ORCHID_BIN" task advance T030 blocked --reason "attempts exhausted (3/3)"

# (a) INV-08: the edge carries an operator judgment, so it needs a reason on
#     this route exactly as `reverify` demands one on its own.
rc=0
adv_noreason="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task advance T030 testing 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a bare advance onto the reverify edge must require --reason (INV-08)"
assert_match "blocked -> testing requires --reason" "$adv_noreason" \
  "and says so in the same shape as every other reason-bearing edge (got: $adv_noreason)"
assert_eq blocked "$(tfield T030 status)" "the refused advance moved nothing"

# (b) the candidate binding. This route cannot re-stamp (an operator asked for
#     a transition, not for their candidate to be rewritten underneath them),
#     so it requires what the re-stamp would have produced and names the verb
#     that does it. Refusing is strictly stronger than fixing up.
rc=0
adv_stale="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task advance T030 testing --reason "surely it is green" 2>&1)" || rc=$?
assert_eq 3 "$rc" "candidate_sha that is not the worktree HEAD is refused, exit 3 (out: $adv_stale)"
assert_match "not the HEAD of the task worktree" "$adv_stale" \
  "naming the mismatch rather than certifying it (out: $adv_stale)"
assert_match "$rev_clean" "$adv_stale" \
  "and printing the HEAD the suite would ACTUALLY have run against (out: $adv_stale)"
assert_match "orchid task reverify" "$adv_stale" \
  "and naming the verb that re-stamps, so the refusal is a route into the supported procedure (out: $adv_stale)"
assert_eq blocked "$(tfield T030 status)" "still where it was"
assert_eq "$rev_base" "$(tfield T030 candidate_sha)" "and the candidate is untouched -- this route never writes one"

# (c) the clean-worktree refusal is on the edge, not in the verb: the same
#     dirty tree `reverify` refuses above is refused here, by the same code.
"$ORCHID_BIN" task set T030 candidate_sha "$rev_clean"
echo "an uncommitted edit, taking the other door this time" > operator-raw-dirt.txt
rc=0
adv_dirty="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task advance T030 testing --reason "the tree is green, honest" 2>&1)" || rc=$?
assert_eq 3 "$rc" "a dirty worktree is refused on the raw route too (out: $adv_dirty)"
assert_match "uncommitted changes" "$adv_dirty" "with the same refusal reverify gives (out: $adv_dirty)"
assert_match "operator-raw-dirt.txt" "$adv_dirty" "naming what is in the way (out: $adv_dirty)"
assert_eq blocked "$(tfield T030 status)" "and the task did not move"
rm -f operator-raw-dirt.txt

# (d) ...and when every condition really is met, the raw route works AND
#     invalidates the stale evidence. That last part is why the invalidation
#     lives on the edge: a prior PASS surviving this transition would satisfy
#     INV-11's testing -> reviewing gate for a candidate nothing re-verified.
printf 'a PASS from a previous, unrelated candidate\n' > .orchid/reviews/T030-verify.log
adv_ok="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task advance T030 testing --reason "already committed on the task branch, candidate already stamped")"
assert_eq testing "$(tfield T030 status)" "a fully-satisfied raw advance takes the edge (out: $adv_ok)"
assert_eq 0 "$(tfield T030 attempts)" "and consumes no attempt, exactly as reverify does not"
[ ! -f .orchid/reviews/T030-verify.log ] \
  || fail "the raw route must drop the stale verify evidence too -- the invalidation belongs to the EDGE, not to one verb"

# ============================================================================
# `retry` validates before it mutates, like `unblock` and `reverify`.
# schedule_attempt_budget dies on a misconfigured budget; when that read came
# AFTER the journal entry and the guidance append, a retry that never happened
# still left the operator's reason recorded and pasted into the task body.
# ============================================================================
"$ORCHID_BIN" task create T031 "retry validates before it mutates" >/dev/null
"$ORCHID_BIN" task advance T031 blocked --reason "fixture blocker"
rc=0
retry_bad="$(ORCHID_REWORK_MAX=not-a-number "$ORCHID_BIN" task retry T031 --reason "this diagnosis must not outlive the refusal" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "retry must die on a misconfigured attempt budget rather than proceed"
assert_match "positive integer" "$retry_bad" "naming the constraint it failed (got: $retry_bad)"
assert_eq blocked "$(tfield T031 status)" "the refused retry left the task where it was"
grep -q "this diagnosis must not outlive the refusal" .orchid/journal.md \
  && fail "a refused retry must journal nothing -- the budget is read before the first write"
grep -q "Operator guidance" <<<"$("$ORCHID_BIN" task show T031)" \
  && fail "and must not append operator guidance either: the task body would carry a diagnosis for a retry that never happened"
# The same call with the budget configured sanely still does its whole job --
# the reordering moved a read, it did not weaken the verb.
retry_good="$("$ORCHID_BIN" task retry T031 --reason "and now, with a budget it can read")"
assert_eq rework "$(tfield T031 status)" "retry works normally once the budget is readable (out: $retry_good)"
assert_match "Operator guidance" "$("$ORCHID_BIN" task show T031)" "and the guidance lands in the body as before"

# ============================================================================
# A RENAME MUST NOT STEP AROUND THE CLEAN-TREE REFUSAL (T026 rework)
#
# The dirty-tree gate excludes `.orchid/` because kernel state is no part of
# the candidate. Porcelain v1 is `XY <path>` -- EXCEPT for a rename or copy,
# which is `XY <old> -> <new>`. A filter anchored at the path column therefore
# reads only the left-hand side, and `R  .orchid/... -> <candidate path>` looks
# exactly like kernel state to it while what it actually stages is a candidate
# file holding content no commit contains. The gate would pass, the suite would
# exercise that file, and candidate_sha would name the commit without it: the
# mis-binding the whole refusal exists to stop, reached by renaming instead of
# adding.
#
# Its own checkout ON ITS OWN BRANCH, because this case needs a TRACKED file
# under `.orchid/` to rename out of, and the scratch repo's own branch
# deliberately never commits one (INV-04 bars kernel state from candidates, and
# every fixture after this one would inherit the commit). A worktree keeps the
# commit off this suite's branch while leaving it in the SAME object store --
# which matters: `testing_entry_blocker` walks `base..candidate` with `git -C
# "$ORCHID_REPO"`, and since T026 it fails CLOSED when that walk cannot be
# done, so a fixture in a separate `git init` would be refused for having an
# unreadable range rather than for anything this case is about.
# ============================================================================
rn_wt="$WORK/wt/rename-hole"
git worktree add -q -b task/T033-rename "$rn_wt" \
  || fail "fixture: could not cut a worktree for the rename case"
mkdir -p "$rn_wt/.orchid"
printf 'kernel state, tracked here only so it can be renamed out of\n' > "$rn_wt/.orchid/scratch.txt"
git -C "$rn_wt" add .orchid/scratch.txt
git -C "$rn_wt" commit -q -m "fixture: a tracked file under .orchid/ to rename out of"
rn_head="$(git -C "$rn_wt" rev-parse HEAD)"
rn_branch="$(git -C "$rn_wt" rev-parse --abbrev-ref HEAD)"

"$ORCHID_BIN" task create T033 "reverify refuses a rename out of .orchid/" >/dev/null
"$ORCHID_BIN" task set T033 worktree "$rn_wt"
"$ORCHID_BIN" task set T033 base_sha "$rn_head"
"$ORCHID_BIN" task set T033 candidate_sha "$rn_head"
"$ORCHID_BIN" task set T033 branch "$rn_branch"
"$ORCHID_BIN" task advance T033 blocked --reason "attempts exhausted (3/3)"

# RED: the rename lands a candidate path, and the record's LEFT side is
# `.orchid/`. Nothing here is committed; HEAD is still rn_head.
mkdir -p "$rn_wt/libexec"
git -C "$rn_wt" mv .orchid/scratch.txt libexec/orchid-smuggled
rn_status="$(git -C "$rn_wt" status --porcelain)"
assert_match " [-]> libexec/orchid-smuggled" "$rn_status" \
  "fixture: git must record this as a RENAME record, or the hole under test is not staged (status: $rn_status)"
rc=0
rn_out="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T033 --reason "only a rename, surely that is nothing" 2>&1)" || rc=$?
assert_eq 3 "$rc" \
  "a staged rename OUT of .orchid/ is an uncommitted candidate file and is refused like any other (out: $rn_out)"
assert_match "uncommitted changes" "$rn_out" "with the same refusal as an added file (out: $rn_out)"
assert_match "libexec/orchid-smuggled" "$rn_out" \
  "NAMING the record, so the operator sees the candidate path it was about to have verified (out: $rn_out)"
assert_eq blocked "$(tfield T033 status)" "the refused reverify left the task where it was"
assert_eq "$rn_head" "$(tfield T033 candidate_sha)" \
  "and never bound the candidate to a commit that does not contain libexec/orchid-smuggled"

# GREEN: the exclusion itself is intact. A rename with BOTH sides under
# `.orchid/` is kernel state moving, no part of any candidate, and still does
# not count as dirty -- so this is a check on the record, not a blanket refusal
# of renames.
git -C "$rn_wt" reset -q --hard
mkdir -p "$rn_wt/.orchid/tasks"
git -C "$rn_wt" mv .orchid/scratch.txt .orchid/tasks/scratch.txt
rn_ok="$(ORCHID_CONCURRENCY=99 "$ORCHID_BIN" task reverify T033 --reason "kernel state moved; the candidate is untouched")"
assert_eq testing "$(tfield T033 status)" \
  "a rename entirely inside .orchid/ is still excluded -- the gate reads the whole record, it does not just refuse renames (out: $rn_ok)"
# T024 (dogfood F26) -- operator prerequisites.
#
# Some tasks cannot be verified by their candidate alone: a schema task
# authors a migration, and the database its suite runs against is still
# unmigrated when the tick reaches `testing`. Run anyway, the suite fails on
# the ENVIRONMENT ("Call to a member function execute() on bool", because
# prepare() found no such column), the log reads like a defect in the
# candidate, and an attempt is spent on it.
#
# The convention: the task declares the step in `operator_prerequisite`, and
# nothing verifies it until an operator acknowledges that step FOR THIS
# CANDIDATE. Every assertion below is about the fix's own behaviour, never
# about the shape of the failure it replaces.
# ============================================================================
#
# Earlier sections intentionally park several tasks in active statuses, and
# that population grows as independent regression cases are appended. Keep
# this prerequisite fixture isolated from their scheduling side effects: its
# subject is the acknowledgement state machine, not the repository-wide cap.
export ORCHID_CONCURRENCY=99
"$ORCHID_BIN" task create T010 "authors a migration it is not allowed to apply"
# T031 now validates every candidate relation before admitting `testing`, so
# this fixture uses real commits instead of the pre-T031 synthetic SHA.
pre_sha="$(git rev-parse HEAD)"
pre_step="apply db/migrate/0007_isolation.sql to the test database"
"$ORCHID_BIN" task set T010 base_sha "$pre_sha"
"$ORCHID_BIN" task set T010 candidate_sha "$pre_sha"
"$ORCHID_BIN" task set T010 verification_commands true
t010() { "$ORCHID_BIN" task show T010 | grep "^$1: " | cut -d' ' -f2-; }

# The templates seed both fields empty, and a task that declares nothing is
# affected in no way whatsoever -- this convention is opt-in per task.
grep -q '^operator_prerequisite:$' .orchid/tasks/T010.md \
  || fail "templates/task.md must seed an empty 'operator_prerequisite:' line"
grep -q '^prerequisite_ack:$' .orchid/tasks/T010.md \
  || fail "templates/task.md must seed an empty 'prerequisite_ack:' line"
assert_eq "" "$(t010 operator_prerequisite)" "a fresh task declares no operator prerequisite"
assert_eq "" "$(t010 prerequisite_ack)" "and has acknowledged nothing"

# `prerequisite_ack` is kernel-owned. An acknowledgement that a human did
# something OUTSIDE this repository is worth exactly the journal entry behind
# it, and a bare frontmatter write carries none.
rc=0; pre_set_out="$("$ORCHID_BIN" task set T010 prerequisite_ack "$pre_sha" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set prerequisite_ack must be refused (kernel-owned, single writer)"
assert_match "task prereq-ack" "$pre_set_out" "the refusal names the verb that does write it"
assert_eq "" "$(t010 prerequisite_ack)" "the refused set wrote nothing"

"$ORCHID_BIN" task advance T010 implementing
"$ORCHID_BIN" task advance T010 testing

# Nothing declared: verify behaves exactly as it always has, evidence and all.
"$ORCHID_BIN" verify T010 >/dev/null \
  || fail "a task with no operator_prerequisite must verify exactly as before"
[ -f .orchid/reviews/T010-verify.log ] \
  || fail "...writing its evidence log as before"

# ...and there is nothing to acknowledge, so the verb says so rather than
# stamping a meaningless ack.
rc=0; pre_none_out="$("$ORCHID_BIN" task prereq-ack T010 --reason "nothing to do" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task prereq-ack must be refused when no operator_prerequisite is declared"
assert_match "no operator_prerequisite" "$pre_none_out" "the refusal says why"

# -- declared and unacknowledged: refused BEFORE the command runs -----------
rm -f .orchid/reviews/T010-verify.log
"$ORCHID_BIN" task set T010 operator_prerequisite "$pre_step"
rc=0; pre_verify_out="$("$ORCHID_BIN" verify T010 2>&1)" || rc=$?
assert_eq 16 "$rc" \
  "verify refuses with the judgment-boundary code 16 -- never its own FAIL code 1, which is what makes this unmistakable for a failing candidate"
assert_match "$pre_step" "$pre_verify_out" "the refusal names the step a human must take"
assert_match "orchid task prereq-ack T010" "$pre_verify_out" "...and the verb that records having taken it"
[ ! -f .orchid/reviews/T010-verify.log ] \
  || fail "a refused verify must write NO evidence -- that log is precisely the artifact a reviewer and an attempt would be spent on"
assert_eq 0 "$(t010 attempts)" "and refusing costs no attempt"
assert_eq testing "$(t010 status)" "the task stays where it was"

# The ack verb accepts `testing` and `merging` and no other status. The line
# is "wherever a verb actually READS the ack", not "wherever a candidate
# exists": `orchid verify` gates on it in `testing`, `orchid merge` gates on
# it in `merging`. Anywhere else the call would stamp a field nothing
# consults from that state -- and before `testing` the migration it claims to
# have applied has not even been written.
"$ORCHID_BIN" task advance T010 rework --reason "exercise the status gate from somewhere else"
rc=0; pre_status_out="$("$ORCHID_BIN" task prereq-ack T010 --reason "far too early" 2>&1)" || rc=$?
assert_eq 3 "$rc" "task prereq-ack from a status no gate reads exits 3"
assert_match "is not testing or merging" "$pre_status_out" "...naming both states it does accept"
assert_match "status: rework" "$pre_status_out" "...and the status it actually found"

"$ORCHID_BIN" task advance T010 implementing
"$ORCHID_BIN" task advance T010 testing

rc=0; "$ORCHID_BIN" task prereq-ack T010 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task prereq-ack requires --reason (INV-08)"
assert_eq "" "$(t010 prerequisite_ack)" "the reason-less call wrote nothing"

"$ORCHID_BIN" task prereq-ack T010 --reason "applied 0007 to orchid_test by hand" >/dev/null
assert_eq "$pre_sha" "$(t010 prerequisite_ack)" \
  "the acknowledgement is bound to the candidate it was given for, not to the task"
grep -q "prerequisite acknowledged for candidate $pre_sha" .orchid/journal.md \
  || fail "task prereq-ack must journal the acknowledgement before writing it (INV-08, journal-first)"
grep -q "applied 0007 to orchid_test by hand" .orchid/journal.md \
  || fail "...carrying the operator's own reason"

# Acknowledging again, over a gate that is ALREADY satisfied, is accepted.
# The verb does not gate on the predicate the other four callers gate on
# (lib/handoff.sh says why): it is the verb that SETTLES that predicate, and
# refusing it while satisfied would refuse the operator who re-applied the
# migration after a store reset and wants the decision trail to say so -- or
# who simply ran the command twice. Pinned because "no precondition" is
# invisible in the source: a later reader finds the other callers gating and
# nothing here, and a well-meant symmetry fix would break exactly this.
pre_reack_ack="$(t010 prerequisite_ack)"
pre_reack_j="$(grep -c "prerequisite acknowledged for candidate $pre_sha" .orchid/journal.md || true)"
rc=0; "$ORCHID_BIN" task prereq-ack T010 --reason "re-applied 0007 after resetting orchid_test" >/dev/null || rc=$?
assert_eq 0 "$rc" \
  "re-acknowledging a prerequisite already acknowledged for THIS candidate is accepted -- the ack verb settles the gate, it does not read it"
assert_eq "$pre_reack_ack" "$(t010 prerequisite_ack)" \
  "...and is idempotent in the field: same candidate in, same candidate out"
assert_eq "$((pre_reack_j + 1))" \
  "$(grep -c "prerequisite acknowledged for candidate $pre_sha" .orchid/journal.md || true)" \
  "...while still journaling the second reason, which is the whole point of allowing it"

"$ORCHID_BIN" verify T010 >/dev/null \
  || fail "an acknowledged prerequisite lets verify run normally"
[ -f .orchid/reviews/T010-verify.log ] || fail "...and write its evidence as usual"

# -- the ack dies with the candidate ---------------------------------------
# Rework exists to replace the candidate, and the migration the next attempt
# authors may not be the migration the operator applied for the last one.
"$ORCHID_BIN" task advance T010 rework --reason "the next attempt may author a different migration"
assert_eq "" "$(t010 prerequisite_ack)" \
  "entry to rework clears the ack, exactly as it clears the verify evidence beside it"
assert_eq "$pre_step" "$(t010 operator_prerequisite)" \
  "the DECLARATION survives -- the task still needs the step, it just needs it again"

"$ORCHID_BIN" task advance T010 implementing
"$ORCHID_BIN" task advance T010 testing
"$ORCHID_BIN" task prereq-ack T010 --reason "re-applied for the reworked candidate" >/dev/null
"$ORCHID_BIN" task advance T010 blocked --reason "park it"
assert_eq "$pre_sha" "$(t010 prerequisite_ack)" "blocking on its own changes no candidate, so the ack stands"
"$ORCHID_BIN" task unblock T010 --reason "unpark it"
assert_eq "" "$(t010 prerequisite_ack)" "task unblock lands the task in rework, so it clears the ack too"

"$ORCHID_BIN" task advance T010 implementing
"$ORCHID_BIN" task advance T010 testing
"$ORCHID_BIN" task prereq-ack T010 --reason "re-applied once more" >/dev/null
"$ORCHID_BIN" task advance T010 blocked --reason "park it again"
"$ORCHID_BIN" task retry T010 --reason "nothing to change, just try again"
assert_eq "" "$(t010 prerequisite_ack)" "task retry lands it in rework as well, so it clears the ack too"

# -- the ack dies with the candidate it NAMED, not just with `rework` -------
# The three clears above are the paths that go through `rework`. They cannot
# be the whole binding: libexec/orchid-merge's rebase-reset rewrites
# `candidate_sha` and sends the task `merging` -> `testing` without entering
# `rework` at all, so the ack survives on file naming a candidate that no
# longer exists. Here the frontmatter is moved directly (what that reset
# writes); tests/test_merge.sh proves the same thing through a real `orchid
# merge` rebase, and tests/test_drive.sh through the driver's own arm.
git commit -q --allow-empty -m "fixture: rebased prerequisite candidate"
pre_rebased="$(git rev-parse HEAD)"
"$ORCHID_BIN" task advance T010 implementing
"$ORCHID_BIN" task advance T010 testing
"$ORCHID_BIN" task prereq-ack T010 --reason "applied 0007 for the pre-rebase candidate" >/dev/null
assert_eq "$pre_sha" "$(t010 prerequisite_ack)" "acknowledged for the candidate then in hand"
rm -f .orchid/reviews/T010-verify.log
"$ORCHID_BIN" task set T010 candidate_sha "$pre_rebased"
assert_eq "$pre_sha" "$(t010 prerequisite_ack)" \
  "no verb cleared the ack -- what changed is the candidate underneath it"
pre_att="$(t010 attempts)"
rc=0; pre_stale_out="$("$ORCHID_BIN" verify T010 2>&1)" || rc=$?
assert_eq 16 "$rc" \
  "an ack naming a superseded candidate does NOT satisfy the gate -- it is a claim about ONE candidate's migration, and this is a different candidate"
assert_match "$pre_sha" "$pre_stale_out" "the refusal names the candidate the ack was for"
assert_match "$pre_rebased" "$pre_stale_out" "...and the candidate that superseded it"
[ ! -f .orchid/reviews/T010-verify.log ] \
  || fail "a stale ack writes no evidence either -- same refusal, same silence"
assert_eq "$pre_att" "$(t010 attempts)" "and still costs no attempt"

"$ORCHID_BIN" task prereq-ack T010 --reason "re-applied for the rebased candidate" >/dev/null
assert_eq "$pre_rebased" "$(t010 prerequisite_ack)" "re-acknowledging binds to the candidate now in hand"
"$ORCHID_BIN" verify T010 >/dev/null \
  || fail "...which satisfies the gate again"

# Keep the real rebased candidate as the fixture's baseline for the sections
# below, with the task in `rework`. Waived, because nothing here was an attempt.
"$ORCHID_BIN" task advance T010 rework --waive-attempt \
  --reason "fixture bookkeeping: restoring the baseline, no attempt was spent"
pre_sha="$pre_rebased"

# -- rewording the step un-acknowledges it ---------------------------------
"$ORCHID_BIN" task advance T010 implementing
"$ORCHID_BIN" task advance T010 testing
"$ORCHID_BIN" task prereq-ack T010 --reason "applied 0007" >/dev/null
"$ORCHID_BIN" task set T010 operator_prerequisite "apply db/migrate/0008_isolation.sql to the test database"
assert_eq "" "$(t010 prerequisite_ack)" \
  "a redeclared prerequisite is an unacknowledged one -- the operator vouched for the step AS IT WAS WORDED"
# ...and says so in the journal. `prerequisite_ack` is kernel-owned exactly
# because an acknowledgement is worth the record behind it: the ack verb
# journals the stamp, and every other clear (the rework advance, unblock,
# retry) journals the intervention that clears it. An ack appearing in the
# decision trail and then silently vanishing -- with the operator's own reason
# for it still standing as the last word -- is an unexplained retraction.
grep -q "prerequisite redeclared" .orchid/journal.md \
  || fail "clearing the ack by redeclaration must be journaled, like every other write of that field"
grep -q "acknowledgement for candidate $pre_sha cleared" .orchid/journal.md \
  || fail "...naming the candidate whose acknowledgement was dropped"

pre_j_before="$(grep -c 'prerequisite redeclared' .orchid/journal.md || true)"
"$ORCHID_BIN" task prereq-ack T010 --reason "applied 0008" >/dev/null
"$ORCHID_BIN" task set T010 operator_prerequisite "apply db/migrate/0008_isolation.sql to the test database"
assert_eq "$pre_sha" "$(t010 prerequisite_ack)" \
  "an idempotent re-set of the SAME text is not a redeclaration and must leave the ack alone"
assert_eq "$pre_j_before" "$(grep -c 'prerequisite redeclared' .orchid/journal.md || true)" \
  "...and journals nothing, because it cleared nothing"

# A redeclaration over an EMPTY ack has nothing to retract, so it stays silent
# too -- the entry marks a withdrawn acknowledgement, not every edit of the
# declaration. (The first redeclaration below drops a real ack and does
# journal; the second, over the field it just emptied, must not.)
"$ORCHID_BIN" task set T010 operator_prerequisite "apply db/migrate/0009_isolation.sql to the test database"
assert_eq "" "$(t010 prerequisite_ack)" "test setup: that redeclaration cleared the ack"
pre_j_empty="$(grep -c 'prerequisite redeclared' .orchid/journal.md || true)"
"$ORCHID_BIN" task set T010 operator_prerequisite "apply db/migrate/0010_isolation.sql to the test database"
assert_eq "$pre_j_empty" "$(grep -c 'prerequisite redeclared' .orchid/journal.md || true)" \
  "redeclaring over an empty ack retracts nothing and journals nothing"

# Withdrawing the declaration removes the gate entirely, ack or no ack.
"$ORCHID_BIN" task set T010 operator_prerequisite ""
"$ORCHID_BIN" task set T010 prerequisite_ack "" 2>/dev/null && \
  fail "task set prerequisite_ack must stay refused even with an empty value"
rm -f .orchid/reviews/T010-verify.log
"$ORCHID_BIN" verify T010 >/dev/null \
  || fail "with no declaration there is no gate, whatever prerequisite_ack happens to hold"
[ -f .orchid/reviews/T010-verify.log ] || fail "...and verify writes evidence again"
# T034 (dogfood F34, and the identical accident on r-002's own
# .orchid/tasks/T002.md): A NEWLINE IN A VALUE MUST BE REFUSED, NOT WRITTEN,
# AND ABOVE ALL NOT ALLOWED TO DESTROY THE TASK FILE.
#
# What used to happen: `task set <id> <key> "<value with a newline>"` printed
# "awk: newline in string" three times, EXITED 0, and left the task file at
# ZERO BYTES -- id, title, status, archetype, branch, every field gone. Not a
# rejected write: a destroyed file. It then failed quietly in both directions,
# because every later `task set` against the empty file reported success too
# and `task show` exited 0 printing nothing, so the only signal either dogfood
# operator got was a grep coming back empty.
#
# The single-line rule itself is reasonable -- frontmatter is one `key: value`
# per line. Destroying the file when it is violated is not. So the assertions
# below are about BOTH halves: the refusal, and the file being byte-identical
# afterwards.
# ============================================================================
make_scratch T034_KEEP
# A FRESH id, and a CHECKED create. `task create` refuses an id that already
# has a file ("task <id> exists"), and this file runs under `set -uo pipefail`
# with no `-e`: an unchecked create against a taken id neither aborts nor
# reports, it just leaves the block silently reading whatever the earlier case
# left behind. T010 is exactly that trap -- the operator_prerequisite fixture
# above walks it to `testing` -- so the green twin at the end of this block
# would assert `status: pending` against a task that is not pending, and the
# byte-identical check would be measuring a file this block never created.
"$ORCHID_BIN" task create T013 "newline refusal" \
  || fail "fixture: task create T013 must succeed (a taken id would make every assertion below read another case's task)"
nl_file=".orchid/tasks/T013.md"
cp "$nl_file" "$T034_KEEP/T013.before"

# The value an operator actually types: multi-paragraph prose pasted into a
# long field. `acceptance_criteria` and `hook_guidance` are where this happens,
# and where losing the content hurts most.
nl_value="$(printf 'first paragraph of the criteria\n\nsecond paragraph of the criteria')"
rc=0; nl_out="$("$ORCHID_BIN" task set T013 acceptance_criteria "$nl_value" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set with a newline-bearing value must exit NON-ZERO (it used to exit 0 and leave the task file at zero bytes)"
red_case 'task set with a value containing a newline: refused, non-zero exit'
assert_match "newline" "$nl_out" "the refusal names the constraint it is enforcing (a newline in a single-line field), rather than reporting a tool error"
# Herestring, never `echo "$nl_out" | grep -qi`: this file runs under `set -o
# pipefail` (tests/helpers.sh line 2) and `grep -q` exits at its FIRST match,
# SIGPIPEing the upstream `echo` mid-write -- pipefail then promotes that 141
# to the pipeline's status, so `&& fail` is skipped for a pattern grep DID
# find. On a NEGATIVE assertion that is the fail-open direction: the leak this
# line exists to catch would go unreported precisely when it is present.
grep -qi "awk" <<<"$nl_out" && fail "the refusal must not leak a raw awk error -- that message was the symptom of the file already being gone"
[ -s "$nl_file" ] || fail "THE FILE IS EMPTY: a refused write destroyed the task, which is the whole defect"
cmp -s "$T034_KEEP/T013.before" "$nl_file" \
  || fail "a refused newline write must leave the task file BYTE-IDENTICAL"
assert_eq T013 "$("$ORCHID_BIN" task show T013 | grep '^id: ' | cut -d' ' -f2)" \
  "and the task is still fully readable after the refusal"

# The GREEN twin, on the same key and the same check: a single-line value is
# accepted and stored verbatim, so the refusal above is evidence of detection
# rather than of a guard that rejects every value.
"$ORCHID_BIN" task set T013 acceptance_criteria "one line of criteria is fine" \
  || fail "a single-line value must still be accepted"
assert_eq "one line of criteria is fine" \
  "$("$ORCHID_BIN" task show T013 | grep '^acceptance_criteria: ' | cut -d' ' -f2-)" \
  "an accepted single-line value is stored verbatim"
green_case 'task set with a single-line value: accepted and stored verbatim'

# `task create` renders its template through fm_render_task_template, not
# `fm_set` -- a different writer, and one that (since T034's rework) stores what
# it is handed byte-for-byte. That is why the newline has to be refused HERE, at
# the door: nothing downstream would object to it any more, so an unguarded
# newline would land a `title:` line split in two with the remainder sitting in
# the frontmatter as a key-less line.
rc=0; create_nl_out="$("$ORCHID_BIN" task create T012 "$(printf 'title\nwith a newline')" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task create with a newline in the title must be refused"
assert_match "newline" "$create_nl_out" "the create refusal names the constraint too"
[ ! -e ".orchid/tasks/T012.md" ] \
  || fail "a refused create must not leave a task file behind at all, least of all an empty one"
# The remedy has to fit the caller. `task set` can send an operator to the task
# BODY of a file that exists; a refused CREATE has no file at all, so pointing
# at one is advice they cannot act on.
grep -qE 'No task file was created' <<<"$create_nl_out" \
  || fail "the create refusal must say no task file was created, rather than reusing 'task set's remedy, which sends the operator to a path that does not exist"
red_case 'task create with a newline in the title: refused, non-zero exit, no file written'

# ---------------------------------------------------------------------------
# THE RENDER END (T034 rework -- the attempt-1 gap). `task create` used to
# render its template with `sed -e "s|__TITLE__|$title|g"`, and a sed
# REPLACEMENT string is a small language rather than literal text. Two of its
# metacharacters are ordinary characters in a title an operator types, and both
# failed SILENTLY -- sed exits 0, the task file is well-formed frontmatter,
# `task show` prints it happily, and only the title is wrong:
#
#   `&`  stands for the WHOLE MATCH, so `parser & lexer` was written out as
#        `parser __TITLE__ lexer` -- the placeholder reinstated into the value
#        that was supposed to replace it.
#   `\n` (the two characters, which is what an operator types when flattening
#        prose onto one line) is IMPLEMENTATION-DEFINED: GNU sed turns it into a
#        REAL newline, splitting `title:` across two lines and landing the
#        remainder as a key-less frontmatter line; BSD sed turns it into the
#        single letter `n`.
#
# THE ASSERTIONS PIN THE ROUND TRIP -- the bytes back out equal the bytes in --
# rather than either platform's particular wrong answer. That is deliberate:
# pinning "GNU sed splits the line" would pass vacuously on BSD sed and pinning
# "BSD sed eats the backslash" would pass vacuously on GNU, so a case written
# either way is green on half the machines that run it while the defect is fully
# present. Written as a round trip it is red on both, and stays red for whatever
# escape a future sed invents.
# ---------------------------------------------------------------------------
amp_title='parser & lexer & 100% & rising'
"$ORCHID_BIN" task create T014 "$amp_title" \
  || fail "fixture: task create T014 must succeed (a metacharacter title is a legal title)"
assert_eq "$amp_title" "$("$ORCHID_BIN" task show T014 | grep '^title: ' | cut -d' ' -f2-)" \
  "a title containing '&' is stored byte-for-byte, never expanded into the placeholder text it replaced"

# The implementation-defined half, asserted as three facts rather than one,
# because the two sed families break it in different places: the value round
# trips (both), the file gained no line (GNU's real newline), and exactly one
# title line remains (GNU's key-less remainder).
esc_title='flatten it: a\nb, and a\ttab, and a lone \ on its own'
lines_plain="$(grep -c '' ".orchid/tasks/T014.md")"
"$ORCHID_BIN" task create T015 "$esc_title" \
  || fail "fixture: task create T015 must succeed (a backslash is a legal character in a title)"
assert_eq "$esc_title" "$("$ORCHID_BIN" task show T015 | grep '^title: ' | cut -d' ' -f2-)" \
  "a literal backslash-n in a title is stored as the two characters it is (GNU sed made it a real newline; BSD sed made it the letter n)"
assert_eq "$lines_plain" "$(grep -c '' ".orchid/tasks/T015.md")" \
  "and the rendered task has exactly as many lines as one rendered from the same template without escapes -- an expanded escape would have split the title line in two"
assert_eq 1 "$(grep -c '^title: ' ".orchid/tasks/T015.md")" \
  "exactly one title line, so no remainder was left behind as a key-less frontmatter line"

# A substituted value must be INERT once placed. The old renderer was one sed
# pass PER PLACEHOLDER, and each later pass rescanned text the earlier ones had
# already written -- so a title naming a placeholder that sorts after __TITLE__
# was itself substituted. `__DATE__` is the discriminating one: its pass ran
# last.
ph_title='why __DATE__ and __ID__ are spelled that way'
"$ORCHID_BIN" task create T016 "$ph_title" \
  || fail "fixture: task create T016 must succeed"
assert_eq "$ph_title" "$("$ORCHID_BIN" task show T016 | grep '^title: ' | cut -d' ' -f2-)" \
  "a title that names a placeholder is stored literally -- text already substituted is never rescanned"
assert_eq T016 "$("$ORCHID_BIN" task show T016 | grep '^id: ' | cut -d' ' -f2)" \
  "...while the template's OWN __ID__ placeholder was still substituted, so the single scan is a scan and not a skipped pass"
assert_match '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$("$ORCHID_BIN" task show T016)" \
  "...and so was its __DATE__, which is the placeholder the title above impersonates"

# THE OTHER READER. `task show` has read every one of these already -- each
# assertion above went through it. The second reader is `orchid doctor`, whose
# task-file check (the read end of this same T034 work, exercised against
# DAMAGED files in tests/test_init_doctor.sh) parses the frontmatter of every
# task on disk. A title carrying '&', a backslash escape or a placeholder name
# has to read as an intact task there too, not as damage.
# Asserted by LINE, never by doctor's exit code: that code is its global verdict
# over a hand-built fixture repo, so coupling this case to it would go red for
# reasons that have nothing to do with task files.
create_doctor_out="$("$ORCHID_BIN" doctor 2>&1 || true)"
grep -q '^FAIL: task file' <<<"$create_doctor_out" \
  && fail "doctor must not report a task created with a metacharacter title as damaged (out: $create_doctor_out)"
assert_match '^ok: task files: [0-9]+ present, each with parseable frontmatter and an id' \
  "$create_doctor_out" \
  "doctor parses the frontmatter of every task in this fixture, metacharacter titles included"
green_case 'task create with & / backslash / placeholder-name titles: stored byte-for-byte, read back by both task show and doctor'

# ---------------------------------------------------------------------------
# ...AND THE READ END. A task file that has already been destroyed (by an
# older orchid, an interrupted write, a bad restore) must be reported as
# DAMAGED by the verb whose entire job is to show it. `cat` on a zero-byte file
# prints nothing and exits 0, which is indistinguishable from a healthy verb
# answering about a task with nothing in it.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T011 "the shape a destroyed task file leaves behind" \
  || fail "fixture: task create T011 must succeed (see the checked create above for why an unchecked one is silent here)"
cp ".orchid/tasks/T011.md" "$T034_KEEP/T011.before"
: > ".orchid/tasks/T011.md"
[ ! -s ".orchid/tasks/T011.md" ] || fail "fixture: T011.md must be zero bytes for this case to mean anything"

rc=0; show_empty_out="$("$ORCHID_BIN" task show T011 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task show on an EMPTY task file must exit non-zero (it used to exit 0 and print nothing)"
red_case 'task show against a zero-byte task file: refused, non-zero exit'
assert_match "EMPTY" "$show_empty_out" "task show says the file is empty instead of printing nothing"
assert_match "DAMAGED" "$show_empty_out" "and names it as damage, not as a task that merely has no content"

# The other half of the quiet failure: a write against the already-destroyed
# file used to report success, so nothing ever signalled that the task had
# stopped existing.
rc=0; set_empty_out="$("$ORCHID_BIN" task set T011 title "is anything still here" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set against an already-empty task file must not report success"
assert_match "empty" "$set_empty_out" "the write refusal says the document it would have produced is empty"

# Non-empty but frontmatter-less: the same class, reached from a partial
# restore rather than a truncation.
printf 'the frontmatter is gone but the body survived\n' > ".orchid/tasks/T011.md"
rc=0; show_nofm_out="$("$ORCHID_BIN" task show T011 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task show on a frontmatter-less task file must exit non-zero"
assert_match "no frontmatter" "$show_nofm_out" "task show names the missing frontmatter delimiter"

# GREEN twin for the read end, in this same file: an intact task file is still
# printed in full, exit 0.
show_ok_out="$("$ORCHID_BIN" task show T013)" || fail "task show on a healthy task must still exit 0"
assert_match "^id: T013$" "$show_ok_out" "task show on a healthy task still prints its frontmatter"
assert_match "^status: pending$" "$show_ok_out" "task show on a healthy task prints the whole document, not just a probe"
assert_match "^title: newline refusal$" "$show_ok_out" \
  '...and prints a field the fm_check probe never reads, so show still cats the whole document rather than echoing its probe'
green_case 'task show against an intact task file: printed in full, exit 0'

# T011 is restored before this file ends. A deliberately damaged task file left
# lying in the fixture is a trap for whatever case gets appended after this one:
# `task list` renders it as a row of empty fields and every scheduler read in
# this repo would see a task with no status at all -- which is exactly the
# failure this block is about, arriving as an unrelated test's mystery.
cp "$T034_KEEP/T011.before" ".orchid/tasks/T011.md"
"$ORCHID_BIN" task show T011 >/dev/null \
  || fail "the fixture teardown must leave T011 readable again"
