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
echo "$set_nope_out" | grep -qi "awk" && fail "task set on a nonexistent id must never leak a raw awk error"

rc=0; set_plan_out="$("$ORCHID_BIN" task set plan somekey someval 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task set plan must be refused (reserved id)"
assert_match "reserved" "$set_plan_out" "task set plan names it reserved"

rc=0; unblock_nope_out="$("$ORCHID_BIN" task unblock NOPE2 --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "task unblock on a nonexistent id must be refused"
assert_match "no task NOPE2" "$unblock_nope_out" "task unblock on a nonexistent id names it (clean die, not a raw awk error)"
echo "$unblock_nope_out" | grep -qi "awk" && fail "task unblock on a nonexistent id must never leak a raw awk error"

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
# are fixed placeholder (non-existent) shas throughout: the `to=testing`
# .orchid/-scan runs `git log <base>..<candidate>`, which prints nothing at
# all for an invalid range, so a placeholder never trips INV-04's guard; and
# `verification_commands=true` makes `orchid verify` always PASS.
# ============================================================================
"$ORCHID_BIN" task create T007 "archetype edge walk"
edge_sha="deadbeefcafebabe0000000000000000000000"
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
"$ORCHID_BIN" task advance T007 rework --reason "validation_failed: see reviews/T007-merge.log"
assert_eq rework "$(t007_status)" "archetype edge merging:rework"
assert_eq 1 "$("$ORCHID_BIN" task show T007 | grep '^attempts: ' | cut -d' ' -f2)" "merging:rework never bumps attempts (from=merging)"

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
# rework:implementing) -- plus *:blocked, already covered above via T001.

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
edge_sha2="cafebabedeadbeef0000000000000000000000"
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
