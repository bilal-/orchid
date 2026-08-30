#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"

integ=orchid/integration
git branch "$integ"
echo "integration_branch=$integ" > orchid.config

ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# helper: walk a task from pending all the way to `merging`, with a real
# passing `orchid verify` in between (INV-11 gate) — mirrors the only path
# the kernel allows into `merging`.
walk_to_merging() {
  local id="$1" branch="$2" base="$3" cand="$4" vcmd="$5"
  "$ORCHID_BIN" task set "$id" base_sha "$base"
  "$ORCHID_BIN" task set "$id" candidate_sha "$cand"
  "$ORCHID_BIN" task set "$id" verification_commands "$vcmd"
  # The ONE edge in this walk that the scheduler can refuse: `pending ->
  # implementing` is an idle -> active dispatch, and `task advance` runs
  # `schedule_dispatch_blockers` fail-closed on it. Named here with `|| fail`
  # so a refusal (`concurrency-cap (n/cap)`, an exclusive/resource hold) is
  # reported where it happens, against the task that was actually refused.
  # Left silent, the task simply stays `pending` and the FIRST symptom is this
  # case's own end-state assertion reading `expected merging, got pending` --
  # which names the feature under test rather than the scheduling slot some
  # earlier case never gave back.
  "$ORCHID_BIN" task advance "$id" implementing \
    || fail "$id: dispatch into implementing refused -- the rest of this case is meaningless"
  "$ORCHID_BIN" task advance "$id" testing
  git checkout -q "$branch"
  "$ORCHID_BIN" verify "$id" >/dev/null
  git checkout -q "$integ"
  "$ORCHID_BIN" task advance "$id" reviewing
  plant_reviewer_envelope "$id"
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "single reviewer approved"
  # `task arbitrate`, not `task advance <id> merging`: `arbitrating:merging` is
  # an arbitration RESULT, and since T032 the only
  # public verb that records one is this (libexec/orchid-task's `advance` arm
  # refuses the rest).
  "$ORCHID_BIN" task arbitrate "$id" --result approve --reason "approved for merge"
}

# ---------------------------------------------------------------------------
# Clean merge path: task -> done, integration advanced.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T001 "clean merge"
git checkout -q -b task/T001 "$integ"
echo hello > feature1.txt && git add feature1.txt && git commit -q -m "feature 1"
cand1="$(git rev-parse HEAD)"
git checkout -q "$integ"
base1="$(git rev-parse "$integ")"

walk_to_merging T001 task/T001 "$base1" "$cand1" "test -f feature1.txt"

pre_integ="$(git rev-parse "$integ")"
out="$WORK/merge1.out"; rc=0
"$ORCHID_BIN" merge T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "clean merge exits 0"
assert_match "^merged T001: $integ -> " "$(cat "$out")" "prints merged message"
assert_eq "done" "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "task advances to done"
post_integ="$(git rev-parse "$integ")"
[ "$post_integ" != "$pre_integ" ] || fail "integration ref advanced"
git show "$integ:feature1.txt" >/dev/null 2>&1 || fail "integ now contains feature1.txt"

log=".orchid/reviews/T001-merge.log"
[ -f "$log" ] || fail "merge evidence log written"
assert_match "^command: test -f feature1.txt$" "$(cat "$log")" "merge evidence records the exact command"
assert_match "^exit: 0$" "$(cat "$log")" "merge evidence records exit 0"
assert_match "^sha: $post_integ$" "$(cat "$log")" "merge evidence records the merge commit sha"

n_wt="$(git worktree list | wc -l | tr -d ' ')"
assert_eq 1 "$n_wt" "temp worktree removed after clean merge"

# ---------------------------------------------------------------------------
# Validation-fail path: task -> rework, integration untouched.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T002 "fails validation"
git checkout -q -b task/T002 "$integ"
echo world > feature2.txt && git add feature2.txt && git commit -q -m "feature 2"
cand2="$(git rev-parse HEAD)"
git checkout -q "$integ"
base2="$(git rev-parse "$integ")"

# A command that passes on a NAMED branch checkout (the task's own branch,
# used for the testing->reviewing verify gate) but fails on a DETACHED HEAD
# (merge's own temp worktree) — a deterministic way to make merge's
# independent re-run of the suite fail even though the gate's verify passed,
# without needing a semantically-differing merged tree.
vcmd2='test "$(git rev-parse --abbrev-ref HEAD)" != HEAD'
walk_to_merging T002 task/T002 "$base2" "$cand2" "$vcmd2"

pre_integ2="$(git rev-parse "$integ")"
out2="$WORK/merge2.out"; rc=0
"$ORCHID_BIN" merge T002 >"$out2" 2>&1 || rc=$?
assert_eq 1 "$rc" "failing suite -> exit 1"
assert_eq rework "$("$ORCHID_BIN" task show T002 | grep '^status: ' | cut -d' ' -f2)" "task returns to rework"
post_integ2="$(git rev-parse "$integ")"
assert_eq "$pre_integ2" "$post_integ2" "integration ref untouched on validation failure"
log2=".orchid/reviews/T002-merge.log"
[ -f "$log2" ] || fail "merge evidence log written on failure too"
assert_match "^exit: [^0]" "$(cat "$log2")" "merge evidence records non-zero exit"
assert_match "validation_failed" "$(cat .orchid/journal.md)" "rework reason journaled"

# ---------------------------------------------------------------------------
# Merge-conflict path: task -> rework, integration untouched, no dangling
# worktree left behind.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T003 "merge conflict"
git checkout -q -b task/T003 "$integ"
echo "task version" > clash.txt && git add clash.txt && git commit -q -m "clash from task"
cand3="$(git rev-parse HEAD)"
git checkout -q "$integ"
base3="$(git rev-parse "$integ")"
echo "integ version" > clash.txt && git add clash.txt && git commit -q -m "clash from integ"

walk_to_merging T003 task/T003 "$base3" "$cand3" "true"
# task's base_sha is now stale relative to the fresh integ commit above, so
# force it back to "current" to exercise the merge-conflict path directly
# rather than the rebase path (that path is covered by the INV-07 test).
"$ORCHID_BIN" task set T003 base_sha "$(git rev-parse "$integ")"

pre_integ3="$(git rev-parse "$integ")"
rc=0
"$ORCHID_BIN" merge T003 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "merge conflict -> exit 1"
assert_eq rework "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "conflicting task returns to rework"
assert_match "merge conflict" "$(cat .orchid/journal.md)" "merge conflict reason journaled"
post_integ3="$(git rev-parse "$integ")"
assert_eq "$pre_integ3" "$post_integ3" "integration ref untouched on merge conflict"
n_wt3="$(git worktree list | wc -l | tr -d ' ')"
assert_eq 1 "$n_wt3" "temp worktree removed after merge conflict"

# ---------------------------------------------------------------------------
# v0b2: CAS update-ref failure path. `merge` reads integ_head once, up front;
# its final `git update-ref refs/heads/<integ> <new> <old>` is a
# compare-and-swap that only succeeds if the ref STILL points at that old
# value. If a concurrent commit lands on integration in the window between
# that read and the write (a race the rebase-reverify path doesn't cover,
# since base_sha == integ_head here at the start), the CAS must refuse: no
# clobbering the concurrent commit, no silently reporting success, task
# stays in `merging` for retry, and the failure is journaled.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T004 "cas race"
git checkout -q -b task/T004 "$integ"
echo raced > feature4.txt && git add feature4.txt && git commit -q -m "feature 4"
cand4="$(git rev-parse HEAD)"
git checkout -q "$integ"
base4="$(git rev-parse "$integ")"

# Slow verification command opens a real window between merge's integ_head
# read (at script top) and its update-ref (after the merge + verify steps).
walk_to_merging T004 task/T004 "$base4" "$cand4" "sleep 1 && test -f feature4.txt"

"$ORCHID_BIN" merge T004 >"$WORK/merge4.out" 2>&1 &
merge_pid=$!
sleep 0.3
# Race: land a concurrent commit on integ WHILE merge's slow verification is
# still running in its own detached temp worktree.
echo concurrent > concurrent4.txt && git add concurrent4.txt && git commit -q -m "concurrent landing"
concurrent_integ="$(git rev-parse "$integ")"
rc=0; wait "$merge_pid" || rc=$?

assert_eq 1 "$rc" "CAS update-ref failure -> merge exits nonzero"
assert_eq merging "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "task remains in merging after CAS failure (safe to retry)"
post_integ4="$(git rev-parse "$integ")"
assert_eq "$concurrent_integ" "$post_integ4" "concurrent commit is NOT clobbered by the losing CAS"
grep -q "intervention" .orchid/journal.md || fail "CAS failure journals an intervention"
grep -qi "update-ref\|CAS" .orchid/journal.md || fail "CAS failure journal entry names the cause"
# v1-m3 regression: orchid-merge's `ORCHID_ACTOR="${ORCHID_ACTOR:-orchestrator}"`
# call sites pass a bare (unmarked) actor name and have always relied on
# libexec/orchid-journal to append " e<epoch>" itself -- pin the rendered
# shape so a future journal refactor can't silently drop the epoch off a
# bare-name actor the way an earlier draft of the v1-m3 actor-identity
# change did (it special-cased only the unset-ORCHID_ACTOR default).
assert_match "\\(orchestrator e${ORCHID_EPOCH}\\)" "$(cat .orchid/journal.md)" \
  "CAS failure journal entry's actor is 'orchestrator e<epoch>', not epoch-less 'orchestrator'"

# Fixture teardown, not part of the contract above -- and it is load-bearing
# for every case BELOW this one. The contract this case proves is that the
# losing CAS leaves the task in `merging`, and `merging` is an ACTIVE status
# (lib/schedule.sh's `_SCHEDULE_ACTIVE_STATUSES`). A fixture task parked there
# never retires, so it holds one of the run's two concurrency slots for the
# remainder of the file; the second such task takes the other, and then every
# later case's `pending -> implementing` dispatch is refused at
# `concurrency-cap (2/2)`. The task stays `pending` and the failures surface as
# that case's own end-state assertions, naming the feature under test instead
# of the slot it never got. Released through `*:blocked`, the one edge `legal`
# accepts from any status, AFTER the assertions that needed `merging` have run.
"$ORCHID_BIN" task advance T004 blocked \
  --reason "fixture teardown: release the scheduling slot this parked task holds" >/dev/null

# ---------------------------------------------------------------------------
# v0b2: stale-base rebase IN the recorded frontmatter worktree. When a task's
# frontmatter `worktree` already has the task branch checked out (a live
# implementer checkout — not merge's own temp worktree), the stale-base path
# must rebase directly IN that worktree instead of trying to mint a temp
# worktree for a branch that's already checked out (which would otherwise
# hit the explicit-die-with-path branch). This is the INV-07 rebase-reverify
# path exercised through that recorded-worktree layout: same "exits 5,
# candidate/base rewritten, evidence invalidated" contract, PLUS the
# recorded worktree itself must survive healthy (merge_cleanup only tears
# down ITS OWN temp worktrees, never the recorded one).
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T005 "rebase in recorded worktree"
git checkout -q -b task/T005 "$integ"
echo five > feature5.txt && git add feature5.txt && git commit -q -m "feature 5"
cand5="$(git rev-parse HEAD)"
git checkout -q "$integ"
base5="$(git rev-parse "$integ")"

# The task branch is checked out in its own registered worktree (simulating
# a live implementer checkout), recorded on the task via frontmatter.
wt5="$WORK/wt5"
git worktree add -q "$wt5" task/T005
"$ORCHID_BIN" task set T005 worktree "$wt5"

"$ORCHID_BIN" task set T005 base_sha "$base5"
"$ORCHID_BIN" task set T005 candidate_sha "$cand5"
"$ORCHID_BIN" task set T005 verification_commands "test -f feature5.txt"
"$ORCHID_BIN" task advance T005 implementing
"$ORCHID_BIN" task advance T005 testing
"$ORCHID_BIN" verify T005 >/dev/null   # runs in $wt5 (frontmatter worktree)
"$ORCHID_BIN" task advance T005 reviewing
plant_reviewer_envelope T005
"$ORCHID_BIN" task advance T005 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task arbitrate T005 --result approve --reason "approved for merge"

# Parallel commit lands on integration BEFORE T005 merges -> stale base.
echo other5 > parallel5.txt && git add parallel5.txt && git commit -q -m "parallel task landed first (T005)"
integ_after5="$(git rev-parse "$integ")"

pre_integ5="$(git rev-parse "$integ")"
rc=0; out5="$WORK/merge5.out"
"$ORCHID_BIN" merge T005 >"$out5" 2>&1 || rc=$?
assert_eq 5 "$rc" "stale base (recorded worktree) -> merge exits 5"
post_integ5="$(git rev-parse "$integ")"
assert_eq "$pre_integ5" "$post_integ5" "integration ref untouched by rebase-reverify (recorded worktree)"

new_status5="$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)"
assert_eq testing "$new_status5" "task lands back in testing after in-worktree rebase"

new_base5="$("$ORCHID_BIN" task show T005 | grep '^base_sha: ' | cut -d' ' -f2)"
new_cand5="$("$ORCHID_BIN" task show T005 | grep '^candidate_sha: ' | cut -d' ' -f2)"
assert_eq "$integ_after5" "$new_base5" "base_sha updated to new integ HEAD (recorded-worktree path)"
[ "$new_cand5" != "$cand5" ] || fail "candidate_sha must change after in-worktree rebase"
[ -n "$new_cand5" ] || fail "candidate_sha must be set after in-worktree rebase"

branch_tip5="$(git rev-parse task/T005)"
assert_eq "$new_cand5" "$branch_tip5" "task branch reflects the in-place-rebased tip"
merge_base5="$(git merge-base task/T005 "$integ")"
assert_eq "$integ_after5" "$merge_base5" "rebased branch sits directly on the new integration HEAD"

# The recorded worktree is never merge's own temp worktree: it must remain a
# healthy, usable checkout with the task branch still checked out and clean.
[ -e "$wt5/.git" ] || fail "recorded worktree still exists after in-place rebase"
wt5_status="$(git -C "$wt5" status --porcelain)"
[ -z "$wt5_status" ] || fail "recorded worktree is not clean after in-place rebase: $wt5_status"
wt5_branch="$(git -C "$wt5" rev-parse --abbrev-ref HEAD)"
assert_eq "task/T005" "$wt5_branch" "recorded worktree still has task branch checked out"
wt5_head="$(git -C "$wt5" rev-parse HEAD)"
assert_eq "$new_cand5" "$wt5_head" "recorded worktree HEAD reflects the rebased tip"

# No leaked temp worktree: only the main checkout + the recorded worktree
# remain registered.
n_wt5="$(git worktree list | wc -l | tr -d ' ')"
assert_eq 2 "$n_wt5" "only the recorded worktree remains registered (no leaked temp worktree)"

# Re-verify + re-review + merge succeeds on the rebased candidate (mirrors
# INV-07's second-attempt walk, confirming the recorded-worktree path leaves
# the task in a normal, mergeable state afterward).
rc=0; "$ORCHID_BIN" verify T005 >/dev/null || rc=$?
assert_eq 0 "$rc" "re-verify passes on the rebased candidate (recorded worktree)"
"$ORCHID_BIN" task advance T005 reviewing
plant_reviewer_envelope T005
"$ORCHID_BIN" task advance T005 arbitrating --reason "re-reviewed after rebase, approved"
"$ORCHID_BIN" task arbitrate T005 --result approve --reason "approved for merge"
rc=0; out5b="$WORK/merge5b.out"
"$ORCHID_BIN" merge T005 >"$out5b" 2>&1 || rc=$?
assert_eq 0 "$rc" "merge succeeds on the new base (recorded worktree)"
assert_eq "done" "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" "task reaches done (recorded worktree path)"

# ---------------------------------------------------------------------------
# v1-m3 (Task 6) regression: no `hook.before_merge` binding at all -> the
# new gate is a total no-op, merge behaves exactly as it always did. Every
# scenario above already exercises this implicitly (none of them ever set a
# hook.before_merge key), but this makes the "unbound point never gates"
# contract an explicit, named assertion of its own rather than an incidental
# side effect of other coverage.
# ---------------------------------------------------------------------------
! grep -q '^hook\.before_merge=' orchid.config 2>/dev/null \
  || fail "test setup: hook.before_merge must be unbound for the regression check"

"$ORCHID_BIN" task create T006 "no hook binding at all"
git checkout -q -b task/T006 "$integ"
echo six > feature6.txt && git add feature6.txt && git commit -q -m "feature 6"
cand6="$(git rev-parse HEAD)"
git checkout -q "$integ"
base6="$(git rev-parse "$integ")"

walk_to_merging T006 task/T006 "$base6" "$cand6" "test -f feature6.txt"

rc=0; "$ORCHID_BIN" merge T006 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "no hook.before_merge binding -> merge proceeds unchanged (exit 0)"
assert_eq "done" "$("$ORCHID_BIN" task show T006 | grep '^status: ' | cut -d' ' -f2)" "no hook.before_merge binding -> task still reaches done"

# ---------------------------------------------------------------------------
# T030 (lesson L022): a DERIVED artifact must not be regenerated per
# candidate. The repository-level version of this is Formula/orchid.rb, whose
# one content-derived checksum line every task's verification chain used to
# oblige it to re-pin; tests/test_ci_release.sh proves that story on a real
# release fixture. What is proven HERE is the same property at the layer that
# actually deadlocked: `orchid merge`'s stale-base rebase arm.
#
# `derived.txt` below stands in for any such artifact. The two scenarios are
# identical except for whether the candidates regenerate it, so the rebase
# outcome is attributable to that and to nothing else.
# ---------------------------------------------------------------------------
git checkout -q "$integ"
echo "derived from the base" > derived.txt
git add derived.txt && git commit -q -m "carry a content-derived artifact"
derived_base="$(git rev-parse "$integ")"

# --- RED: both candidates regenerate it -> the second one cannot land ------
"$ORCHID_BIN" task create T007 "per-candidate re-derivation conflicts on rebase"
# Candidate a, landed on integration first by an ordinary merge (its own trip
# through the state machine is not what this case is about).
git checkout -q -b task/T007a "$derived_base"
echo a > source-a.txt && echo "derived for a" > derived.txt
git add source-a.txt derived.txt && git commit -q -m "candidate a, re-derived"
git checkout -q "$integ"
git merge -q --no-ff -m "land candidate a" task/T007a \
  || fail "T030 setup: candidate a must land on integration"

# Candidate b forked the SAME base and re-derived the same line differently.
git checkout -q -b task/T007 "$derived_base"
echo b > source-b.txt && echo "derived for b" > derived.txt
git add source-b.txt derived.txt && git commit -q -m "candidate b, re-derived"
cand7="$(git rev-parse HEAD)"
git checkout -q "$integ"

# base_sha is deliberately the ORIGINAL base, not the current integ HEAD, so
# merge takes its stale-base rebase arm — the one that deadlocked the run.
walk_to_merging T007 task/T007 "$derived_base" "$cand7" "test -f source-b.txt"

pre_integ7="$(git rev-parse "$integ")"
# Compared before/against after rather than against a literal: the T005 case
# above deliberately leaves its own recorded worktree registered, so the
# absolute count here is not 1 and asserting one would pin that case's
# leftovers instead of this merge's cleanup.
pre_wt7="$(git worktree list | wc -l | tr -d ' ')"
rc=0
"$ORCHID_BIN" merge T007 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "two candidates that both re-derive a shared artifact -> rebase conflict, exit 1"
assert_eq rework "$("$ORCHID_BIN" task show T007 | grep '^status: ' | cut -d' ' -f2)" \
  "the conflicting second candidate is sent to rework — where a no-shell implementer cannot regenerate anything, and the loop never ends"
assert_eq "$pre_integ7" "$(git rev-parse "$integ")" "integration ref untouched by the conflicting rebase"
assert_eq "$pre_wt7" "$(git worktree list | wc -l | tr -d ' ')" \
  "the conflicting rebase leaks no temp worktree"

# --- GREEN: neither candidate regenerates it -> both land, unattended ------
# This is the shipped contract. Nothing else changes: same one base, same two
# candidates, same stale-base rebase arm.
"$ORCHID_BIN" task create T008 "two candidates off one base both land"
green_base="$(git rev-parse "$integ")"

git checkout -q -b task/T008a "$green_base"
echo a > green-a.txt && git add green-a.txt && git commit -q -m "candidate a"
git checkout -q "$integ"
git merge -q --no-ff -m "land green candidate a" task/T008a \
  || fail "T030 setup: green candidate a must land on integration"
green_integ="$(git rev-parse "$integ")"

git checkout -q -b task/T008 "$green_base"
echo b > green-b.txt && git add green-b.txt && git commit -q -m "candidate b"
cand8="$(git rev-parse HEAD)"
git checkout -q "$integ"

walk_to_merging T008 task/T008 "$green_base" "$cand8" "test -f green-b.txt"

rc=0
"$ORCHID_BIN" merge T008 >/dev/null 2>&1 || rc=$?
# Exit 5 is not an operator step: the rebase succeeded, and the kernel is
# re-requiring review of the candidate it just minted (INV-07). The driver
# walks this on its own — which is the whole difference from the RED case,
# where the same arm produced `rework` and an instruction nobody could follow.
assert_eq 5 "$rc" "no candidate re-derives -> the stale-base rebase is clean (exit 5, re-review required)"
assert_eq testing "$("$ORCHID_BIN" task show T008 | grep '^status: ' | cut -d' ' -f2)" \
  "a clean rebase lands the task in testing, not rework"
new_base8="$("$ORCHID_BIN" task show T008 | grep '^base_sha: ' | cut -d' ' -f2)"
assert_eq "$green_integ" "$new_base8" "the rebased candidate now sits on the tip candidate a landed"

new_cand8="$("$ORCHID_BIN" task show T008 | grep '^candidate_sha: ' | cut -d' ' -f2)"
[ "$new_cand8" != "$cand8" ] || fail "the rebase must mint a new candidate sha"
assert_eq "$new_cand8" "$(git rev-parse task/T008)" "the task branch carries the rebased tip"
# No frontmatter worktree on this task, so `orchid verify` runs in the main
# checkout and sha-binds the log to ITS head — the rebased branch has to be
# checked out for the INV-11 gate to accept the evidence. Same two lines
# walk_to_merging uses; the point being proven is that a driver gets here
# with no human in the loop, not that the checkout is free.
git checkout -q task/T008
rc=0; "$ORCHID_BIN" verify T008 >/dev/null || rc=$?
git checkout -q "$integ"
assert_eq 0 "$rc" "the rebased candidate re-verifies with no operator step in between"
"$ORCHID_BIN" task advance T008 reviewing
plant_reviewer_envelope T008
"$ORCHID_BIN" task advance T008 arbitrating --reason "re-reviewed after rebase, approved"
"$ORCHID_BIN" task arbitrate T008 --result approve --reason "approved for merge"
rc=0
"$ORCHID_BIN" merge T008 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "the second candidate merges on its new base"
assert_eq "done" "$("$ORCHID_BIN" task show T008 | grep '^status: ' | cut -d' ' -f2)" \
  "both candidates off one base reach done, with no operator intervention anywhere"
git show "$integ:green-a.txt" >/dev/null 2>&1 || fail "candidate a's change is on the integration branch"
git show "$integ:green-b.txt" >/dev/null 2>&1 || fail "candidate b's change is on the integration branch"
# T024 rework: the rebase-reset expires an operator prerequisite acknowledgement.
#
# `prerequisite_ack` records the candidate_sha an operator acknowledged the
# out-of-sandbox step for (canonically: "I applied this task's migration to
# the database the suite runs against"). Every route into `rework` clears the
# field -- but THIS path is not one of them. A stale base sends merge down the
# rebase-reverify path: the candidate is rebased, `candidate_sha` is rewritten,
# the task goes `merging` -> `testing`, and `rework` is never entered. The
# acknowledgement therefore survives in the frontmatter, still naming the
# pre-rebase candidate, and must NOT satisfy the gate for the rebased one --
# otherwise the very event that forces a re-verify would hand that re-verify a
# vouched-for environment nobody re-vouched for.
#
# Asserted against a REAL `orchid merge` rebase (exit 5), not a hand-written
# candidate_sha, because the point is that this path reaches the gate without
# going through any of the clearing verbs.
# ---------------------------------------------------------------------------
prereq7="apply db/migrate/0007_isolation.sql to the test database"
"$ORCHID_BIN" task create T040 "declares an operator prerequisite, then gets rebased"
git checkout -q -b task/T040 "$integ"
echo seven > feature7.txt && git add feature7.txt && git commit -q -m "feature 7"
cand7="$(git rev-parse HEAD)"
git checkout -q "$integ"
base7="$(git rev-parse "$integ")"

"$ORCHID_BIN" task set T040 base_sha "$base7"
"$ORCHID_BIN" task set T040 candidate_sha "$cand7"
"$ORCHID_BIN" task set T040 verification_commands "test -f feature7.txt"
"$ORCHID_BIN" task set T040 operator_prerequisite "$prereq7"
"$ORCHID_BIN" task advance T040 implementing
"$ORCHID_BIN" task advance T040 testing
"$ORCHID_BIN" task prereq-ack T040 --reason "applied 0007 to the fixture database"
assert_eq "$cand7" "$("$ORCHID_BIN" task show T040 | grep '^prerequisite_ack: ' | cut -d' ' -f2-)" \
  "the ack names the candidate it was given for"
git checkout -q task/T040
"$ORCHID_BIN" verify T040 >/dev/null
git checkout -q "$integ"
"$ORCHID_BIN" task advance T040 reviewing
plant_reviewer_envelope T040
"$ORCHID_BIN" task advance T040 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task arbitrate T040 --result approve --reason "approved for merge"

# A parallel task lands on integration first -> stale base -> rebase-reset.
echo other7 > parallel7.txt && git add parallel7.txt && git commit -q -m "parallel task landed first (T040)"
rc=0; out7="$WORK/merge7.out"
"$ORCHID_BIN" merge T040 >"$out7" 2>&1 || rc=$?
assert_eq 5 "$rc" "stale base -> merge exits 5 (rebase-rereview required)"
new_cand7="$("$ORCHID_BIN" task show T040 | grep '^candidate_sha: ' | cut -d' ' -f2-)"
[ "$new_cand7" != "$cand7" ] || fail "test setup: the rebase must actually mint a new candidate_sha"
assert_eq testing "$("$ORCHID_BIN" task show T040 | grep '^status: ' | cut -d' ' -f2)" \
  "the rebase-reset lands the task back in testing"

# The field is untouched -- no verb cleared it, and none should have. What
# changed is the candidate underneath it.
assert_eq "$cand7" "$("$ORCHID_BIN" task show T040 | grep '^prerequisite_ack: ' | cut -d' ' -f2-)" \
  "the rebase-reset routes through no clearing verb, so the ack is still on file"
assert_eq "$prereq7" "$("$ORCHID_BIN" task show T040 | grep '^operator_prerequisite: ' | cut -d' ' -f2-)" \
  "...and the declaration stands"

# THE POINT: it no longer satisfies the gate.
[ ! -f .orchid/reviews/T040-verify.log ] || fail "test setup: the rebase-reset must have invalidated the verify evidence"
git checkout -q task/T040
rc=0; stale7="$("$ORCHID_BIN" verify T040 2>&1)" || rc=$?
assert_eq 16 "$rc" \
  "an acknowledgement for the pre-rebase candidate does NOT satisfy the gate for the rebased one -- verify refuses with the judgment-boundary code"
assert_match "$cand7" "$stale7" "the refusal names the candidate the ack was for"
assert_match "$new_cand7" "$stale7" "...and the candidate that superseded it"
[ ! -f .orchid/reviews/T040-verify.log ] \
  || fail "a refused verify writes no evidence, stale ack or no ack"

# Re-acknowledged for the candidate now in hand, the run continues normally.
"$ORCHID_BIN" task prereq-ack T040 --reason "re-applied 0007 for the rebased candidate"
assert_eq "$new_cand7" "$("$ORCHID_BIN" task show T040 | grep '^prerequisite_ack: ' | cut -d' ' -f2-)" \
  "the fresh ack binds to the rebased candidate"
rc=0; "$ORCHID_BIN" verify T040 >/dev/null || rc=$?
assert_eq 0 "$rc" "re-verify passes once the prerequisite is acknowledged for THIS candidate"
git checkout -q "$integ"
"$ORCHID_BIN" task advance T040 reviewing
plant_reviewer_envelope T040
"$ORCHID_BIN" task advance T040 arbitrating --reason "re-reviewed after rebase, approved"
"$ORCHID_BIN" task arbitrate T040 --result approve --reason "approved for merge"
rc=0; "$ORCHID_BIN" merge T040 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "merge succeeds on the rebased candidate"
assert_eq "done" "$("$ORCHID_BIN" task show T040 | grep '^status: ' | cut -d' ' -f2)" \
  "and the task reaches done -- the gate delayed the run, it did not derail it"

# ---------------------------------------------------------------------------
# T024 rework: merge's revalidation gates on the prerequisite too.
#
# `orchid merge` re-runs the task's WHOLE verification suite against the same
# external store before it advances the integration ref. Gated at `testing`
# and not here, one unapplied migration would be forgiven at verify (exit 16,
# no evidence, no attempt) and charged at merge, where the nonzero-suite arm
# advances the task to `rework` with `validation_failed` and a merge log full
# of "prepare() returned false" -- a whole rework round, implementer dispatch
# and re-review included, spent on a candidate with nothing wrong with it.
# The `merging`->`rework` edge deliberately charges no attempt, which makes it
# worse rather than better here: the round happens and the counter does not
# even record that it did.
#
# The route to an unmet ack in `merging` without hand-editing frontmatter:
# redeclare the prerequisite. The operator acknowledged the step AS IT WAS
# WORDED, so rewording it clears the ack (tests/test_task.sh covers that
# clearing); here it is just the honest way to reach the state.
#
# The assertion that matters is not the exit code but that THE SUITE NEVER
# RAN: `verification_commands` is a command that leaves a sentinel file
# behind, so its absence after a refused merge is direct evidence no suite
# touched the store -- which is the entire point of refusing before running
# rather than after.
# ---------------------------------------------------------------------------
sentinel8="$WORK/t041-suite-ran"
prereq8="apply db/migrate/0008_isolation.sql to the test database"
"$ORCHID_BIN" task create T041 "declares an operator prerequisite, reaches merging"
git checkout -q -b task/T041 "$integ"
echo eight > feature8.txt && git add feature8.txt && git commit -q -m "feature 8"
cand8="$(git rev-parse HEAD)"
git checkout -q "$integ"
base8="$(git rev-parse "$integ")"

"$ORCHID_BIN" task set T041 base_sha "$base8"
"$ORCHID_BIN" task set T041 candidate_sha "$cand8"
"$ORCHID_BIN" task set T041 verification_commands "touch $sentinel8"
"$ORCHID_BIN" task set T041 operator_prerequisite "$prereq8"
"$ORCHID_BIN" task advance T041 implementing
"$ORCHID_BIN" task advance T041 testing
"$ORCHID_BIN" task prereq-ack T041 --reason "applied 0008 to the fixture database"
git checkout -q task/T041
"$ORCHID_BIN" verify T041 >/dev/null
git checkout -q "$integ"
[ -f "$sentinel8" ] || fail "test setup: an acknowledged prerequisite must let verify actually run the suite"
rm -f "$sentinel8"
"$ORCHID_BIN" task advance T041 reviewing
plant_reviewer_envelope T041
"$ORCHID_BIN" task advance T041 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task arbitrate T041 --result approve --reason "approved for merge"

# The step is reworded -- a different migration, not vouched for by anybody.
"$ORCHID_BIN" task set T041 operator_prerequisite "apply db/migrate/0009_isolation.sql to the test database"
assert_eq "" "$("$ORCHID_BIN" task show T041 | grep '^prerequisite_ack: ' | cut -d' ' -f2-)" \
  "test setup: redeclaring the prerequisite cleared the acknowledgement"

pre_integ8="$(git rev-parse "$integ")"
pre_attempts8="$("$ORCHID_BIN" task show T041 | grep '^attempts: ' | cut -d' ' -f2)"
rc=0; out8="$("$ORCHID_BIN" merge T041 2>&1)" || rc=$?
assert_eq 16 "$rc" \
  "merge refuses an unacknowledged prerequisite with the judgment-boundary code 16 -- never its FAIL code 1, which is what stops it reading as a bad candidate"
[ ! -f "$sentinel8" ] \
  || fail "a refused merge must not run the suite at all -- running it against an unmigrated store is the failure this gate exists to prevent"
assert_eq merging "$("$ORCHID_BIN" task show T041 | grep '^status: ' | cut -d' ' -f2)" \
  "the task stays in merging: nothing about the candidate is in question, so nothing is invalidated"
assert_eq "$pre_integ8" "$(git rev-parse "$integ")" "the integration ref did not move"
[ ! -f .orchid/reviews/T041-merge.log ] \
  || fail "a refused merge writes no merge evidence -- that log is the artifact a reviewer would be spent on"
assert_eq "$pre_attempts8" "$("$ORCHID_BIN" task show T041 | grep '^attempts: ' | cut -d' ' -f2)" \
  "and the attempt counter is untouched"
assert_match "0009_isolation" "$out8" "the refusal names the step a human must take"
assert_match "orchid task prereq-ack T041" "$out8" "...and the verb that records having taken it"

# The refusal has to be actionable from the state it was raised in. Were
# `merging` not an accepted status for the ack, the only route back to one
# would be a trip through `rework`: a whole round -- implementer dispatch,
# re-verify, re-review -- to re-derive a candidate that was already fine.
"$ORCHID_BIN" task prereq-ack T041 --reason "applied 0009 for this candidate"
assert_eq "$cand8" "$("$ORCHID_BIN" task show T041 | grep '^prerequisite_ack: ' | cut -d' ' -f2-)" \
  "prereq-ack accepts merging as well as testing, and binds to the candidate in hand"

rc=0; "$ORCHID_BIN" merge T041 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "re-run after the acknowledgement, merge proceeds normally"
[ -f "$sentinel8" ] || fail "...and NOW the suite actually runs"
assert_eq "done" "$("$ORCHID_BIN" task show T041 | grep '^status: ' | cut -d' ' -f2)" \
  "the task reaches done -- the gate delayed the merge, it did not derail it"
# ---------------------------------------------------------------------------
# T007: the repo-wide `merge_gate`.
#
# The defect this covers is r-001's, not a hypothetical: `scripts/ci-local.sh`
# existed for the whole run and only two of eight tasks named it in their own
# `verification_commands`, because that field is authored per task. So the
# things asserted below are, in order, the things that were missing — the gate
# reaches a task that never opted in; a RED gate stops the integration ref
# rather than merely printing; and the nesting the first two create
# terminates.
#
# Every scenario here deliberately uses a CHEAP gate command (`ls`), never the
# repository's real suite. The gate's content is not what is under test — its
# reach, its authority over the ref, and its recursion behaviour are.
#
# The fixture task ids continue from T008 above rather than restarting: T007
# and T008 are already spent on the T030 re-derivation scenarios, and reusing
# either would inherit that task's status and branch instead of walking a
# fresh one.
#
# `unset`, not `export ...=`: this file runs inside `scripts/ci-local.sh` in
# CI, which sets the recursion marker for exactly the reason section (C)
# below exercises. With it inherited, every gate here would correctly skip
# and (A) and (B) would assert nothing at all — a green suite proving the
# opposite of what it claims, which is the shape of the original defect.
# ---------------------------------------------------------------------------
unset ORCHID_MERGE_GATE_ACTIVE

gate_marker="$WORK/gate-ran.txt"
: > "$gate_marker"

# `ls` is the gate body throughout: it exits 0, and it writes the merged
# tree's own file list into the marker, so "the gate ran" and "the gate ran
# against the merged tree rather than the candidate branch or the repo root"
# are the same assertion.
gate_pass="ls >> $gate_marker"
# The red body also prints ONE gcc-shaped diagnostic, which is not decoration:
# the routing half of this feature (see "(B, continued)") is that a gate
# failure has to arrive in the next brief as a LOCATION, and a gate that
# failed silently could not tell a working carry from a broken one.
gate_diag='lib/example.sh:12: SC2086: Double quote to prevent globbing.'
gate_fail="ls >> $gate_marker; echo '$gate_diag'; exit 3"

set_gate() {  # rewrite orchid.config; an EMPTY argument means "no merge_gate key"
  {
    echo "integration_branch=$integ"
    [ -z "$1" ] || echo "merge_gate=$1"
  } > orchid.config
}

# --- (A) a task that never opted in is gated anyway, and a green gate lets
# the merge through -------------------------------------------------------
set_gate "$gate_pass"

"$ORCHID_BIN" task create T009 "gated without opting in"
git checkout -q -b task/T009 "$integ"
echo nine > feature9.txt && git add feature9.txt && git commit -q -m "feature 9"
cand9="$(git rev-parse HEAD)"
git checkout -q "$integ"
base9="$(git rev-parse "$integ")"

# The whole point of the scenario: this task's own verification_commands says
# nothing whatsoever about the gate.
walk_to_merging T009 task/T009 "$base9" "$cand9" "test -f feature9.txt"
vc9="$("$ORCHID_BIN" task show T009 | grep '^verification_commands: ' | cut -d' ' -f2-)"
assert_eq "test -f feature9.txt" "$vc9" "task's own verification_commands never names the gate"

rc=0; "$ORCHID_BIN" merge T009 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "green gate -> merge still exits 0"
assert_eq "done" "$("$ORCHID_BIN" task show T009 | grep '^status: ' | cut -d' ' -f2)" "green gate -> task reaches done"
assert_match "feature9\.txt" "$(cat "$gate_marker")" "gate RAN, and ran against the merged tree (its listing carries the candidate's file)"

log9=".orchid/reviews/T009-merge.log"
assert_match "^gate: ls >> " "$(cat "$log9")" "merge evidence records the gate command"
assert_match "^gate_status: ran$" "$(cat "$log9")" "merge evidence records that the gate ran"
assert_match "^== merge_gate: ls >> " "$(cat "$log9")" "the gate's output is captured into the log body under its own banner"
assert_match "^exit: 0$" "$(cat "$log9")" "the log still ends in the single exit: line lib/findings.sh keys on"
assert_eq "exit: 0" "$(tail -n1 "$log9")" "gate output never displaces the trailing exit: line"

# WHERE THE GATE COMMAND CAME FROM, which is the other half of "no task can
# switch it off". Task frontmatter cannot, because nothing reads it -- but a
# candidate is a TREE, and a tree carries an orchid.config of its own. If
# `orchid merge` resolved the gate against the merged tree in $wt rather than
# against the repository, a candidate could ship a one-line config naming a
# gate that trivially passes and be judged by it: the floor lowered by the
# very change it is there to judge.
#
# This scenario already settles it, and only a witness was missing. The
# fixture's orchid.config is written into the working tree at the top of this
# file and never `git add`ed, so it is in NO commit -- the merged tree
# contains no orchid.config at all. A gate resolved from that tree would have
# found nothing and run nothing, and the assertions above would all have
# failed. So assert the witness explicitly, because it is a property of the
# fixture rather than of the code and a later `git add` in an unrelated
# scenario would retire this proof silently, leaving the assertions still
# green and no longer about anything. (`orchid start` is the one verb that
# would do it -- it commits orchid.config onto the integration branch on
# purpose -- and this file never calls it. In a repository that HAS been
# started, the merged tree carries an orchid.config and the same property
# rests instead on config_get being asked for $repo: that is the claim the
# assertion below pins, and the absence above is only what makes this fixture
# able to show it.)
git show "$integ:orchid.config" >/dev/null 2>&1 \
  && fail "fixture invariant broken: orchid.config is TRACKED, so the merged tree carries one too and scenario (A) no longer shows the gate came from the repository rather than from the candidate"
assert_eq "gate: $gate_pass" "$(grep '^gate: ' "$log9")" \
  "the gate that ran is verbatim the REPOSITORY's configured command -- resolved from repo config, not from the tree being merged"

# --- (B) a RED gate blocks: the integration ref does not move -------------
# The candidate's OWN suite passes here. Anything that stops this merge is
# therefore the gate and nothing else — and (B2) below closes that argument
# by re-merging the very same candidate with the gate removed.
set_gate "$gate_fail"

"$ORCHID_BIN" task create T010 "red gate must block"
git checkout -q -b task/T010 "$integ"
echo ten > feature10.txt && git add feature10.txt && git commit -q -m "feature 10"
cand10="$(git rev-parse HEAD)"
git checkout -q "$integ"
base10="$(git rev-parse "$integ")"

walk_to_merging T010 task/T010 "$base10" "$cand10" "test -f feature10.txt"

pre_integ10="$(git rev-parse "$integ")"
rc=0; "$ORCHID_BIN" merge T010 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "red gate -> merge exits 1"
assert_eq rework "$("$ORCHID_BIN" task show T010 | grep '^status: ' | cut -d' ' -f2)" "red gate -> task returns to rework"
post_integ10="$(git rev-parse "$integ")"
assert_eq "$pre_integ10" "$post_integ10" "red gate -> integration ref is EXACTLY where it was"
git show "$integ:feature10.txt" >/dev/null 2>&1 \
  && fail "red gate -> the candidate's file must NOT be on the integration branch"
assert_match "gate_failed" "$(cat .orchid/journal.md)" "gate failure journals its own reason, distinct from validation_failed"

log10=".orchid/reviews/T010-merge.log"
assert_match "^gate_status: ran$" "$(cat "$log10")" "merge evidence records that the gate ran"
assert_match "^exit: 3$" "$(cat "$log10")" "the gate's own exit status is what the log carries"

# (B, continued) THE ROUTING HALF, asserted here rather than after (B2)
# because it is a statement about the state the FAILED merge just left behind.
# It is also the reason this task lands after T010 rather than before it. Once
# the gate fires for every task its failures become the rework
# path for every task — and a `file:line: RULE:` location is not actionable by
# an implementer that cannot run the linter that produced it (lesson L017). So
# it is not enough that the gate blocks: its own diagnostics have to reach the
# body the next implementer is handed. lib/findings.sh scrapes the SAME
# `<id>-merge.log` this verb just wrote, and the gate's output is appended to
# that log's captured body ahead of the same trailing `exit:` line findings.sh
# keys on — asserted here end to end rather than argued in a comment, because
# every part of that sentence is a thing a later edit could quietly break: the
# banner could be written after the `exit:` line, the gate could get a log of
# its own, or the sha binding could stop matching.
body10="$(cat .orchid/tasks/T010.md)"
assert_match "$gate_diag" "$body10" \
  "the RED GATE's own location reaches the next implementer's brief — not just the log it cannot open"
assert_match "orchid:rework-brief candidate=$cand10" "$body10" \
  "and it arrives bound to the candidate that failed, in a real brief block"

# (B2) same candidate, gate removed -> it merges. This is what makes (B) a
# statement about the GATE rather than about some incidental property of
# T010: with nothing else changed, dropping the gate is sufficient to let the
# identical tree through.
set_gate ""
walk_to_merging T010 task/T010 "$base10" "$cand10" "test -f feature10.txt"
rc=0; "$ORCHID_BIN" merge T010 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "same candidate merges once the gate is removed -> the gate was the only blocker"
assert_eq "done" "$("$ORCHID_BIN" task show T010 | grep '^status: ' | cut -d' ' -f2)" "ungated re-merge reaches done"
log10b=".orchid/reviews/T010-merge.log"
grep -q '^gate' "$log10b" && fail "no gate configured -> the log carries no gate lines at all"

# --- (C) the recursion guard --------------------------------------------
# The loop this closes: merge -> gate -> the repository's suite -> a test that
# runs `orchid merge` -> that merge's gate -> the suite again. The marker is
# set by `orchid merge` in the gate's own environment (and by
# scripts/ci-local.sh for a direct run), so the INNER merge declines to open a
# second level. Exercised here by standing in for that inner merge directly:
# same red gate as (B), which blocked; with the marker set it must not.
set_gate "$gate_fail"

"$ORCHID_BIN" task create T011 "recursion guard"
git checkout -q -b task/T011 "$integ"
echo eleven > feature11.txt && git add feature11.txt && git commit -q -m "feature 11"
cand11="$(git rev-parse HEAD)"
git checkout -q "$integ"
base11="$(git rev-parse "$integ")"

walk_to_merging T011 task/T011 "$base11" "$cand11" "test -f feature11.txt"

marker_before11="$(wc -l < "$gate_marker" | tr -d ' ')"
rc=0
ORCHID_MERGE_GATE_ACTIVE=1 "$ORCHID_BIN" merge T011 >"$WORK/merge11.out" 2>&1 || rc=$?
assert_eq 0 "$rc" "nested merge -> the gate is skipped, so the red gate cannot block it"
assert_eq "done" "$("$ORCHID_BIN" task show T011 | grep '^status: ' | cut -d' ' -f2)" "nested merge still reaches done"
marker_after11="$(wc -l < "$gate_marker" | tr -d ' ')"
assert_eq "$marker_before11" "$marker_after11" "nested merge did not EXECUTE the gate (marker unchanged)"

# A skip must never be silent — a marker left set in some ambient environment
# would otherwise disable the gate everywhere while every merge reported a
# pass, which is the original defect with the fix's name on it.
log11=".orchid/reviews/T011-merge.log"
assert_match "^gate: ls >> " "$(cat "$log11")" "a skipped gate is still named in the evidence"
assert_match "^gate_status: skipped-nested$" "$(cat "$log11")" "the evidence says the gate was skipped, not that it passed"
assert_match "merge_gate skipped" "$(cat "$WORK/merge11.out")" "the skip is announced, not silent"

# --- (D) no gate configured is a total no-op ------------------------------
# T001-T008 above all ran with no `merge_gate` key and behaved exactly as they
# always did; this makes that an assertion of its own rather than an
# incidental property of the other coverage, in the same spirit as the
# hook.before_merge regression further up.
set_gate ""
"$ORCHID_BIN" task create T012 "no gate configured"
git checkout -q -b task/T012 "$integ"
echo twelve > feature12.txt && git add feature12.txt && git commit -q -m "feature 12"
cand12="$(git rev-parse HEAD)"
git checkout -q "$integ"
base12="$(git rev-parse "$integ")"

walk_to_merging T012 task/T012 "$base12" "$cand12" "test -f feature12.txt"
marker_before12="$(wc -l < "$gate_marker" | tr -d ' ')"
rc=0; "$ORCHID_BIN" merge T012 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "unconfigured gate -> merge proceeds unchanged (exit 0)"
assert_eq "done" "$("$ORCHID_BIN" task show T012 | grep '^status: ' | cut -d' ' -f2)" "unconfigured gate -> task still reaches done"
assert_eq "$marker_before12" "$(wc -l < "$gate_marker" | tr -d ' ')" "unconfigured gate -> nothing was executed"

# --- (E) the one dedup made in code: a red task suite skips the gate ------
# libexec/orchid-merge makes exactly one deduplication, and it is not
# textual: when the task's own suite has ALREADY failed, the gate is not run,
# because the merge is going to `rework` either way and running it buys
# nothing the next round would not produce. The gate configured here is the
# RED one, which is what lets this scenario tell "skipped" apart from "ran,
# and the suite merely won the race for the exit code": had the gate run, the
# marker would have grown and the journal would say gate_failed. Neither may
# happen — the failure is the suite's own, and it must be reported as such,
# because a `gate_failed` here would send the next rework brief chasing a
# gate that never executed.
set_gate "$gate_fail"

suite_red="$WORK/suite-goes-red.flag"
"$ORCHID_BIN" task create T013 "red suite pre-empts the gate"
git checkout -q -b task/T013 "$integ"
echo thirteen > feature13.txt && git add feature13.txt && git commit -q -m "feature 13"
cand13="$(git rev-parse HEAD)"
git checkout -q "$integ"
base13="$(git rev-parse "$integ")"

# Green at walk time (INV-11's real `orchid verify` must pass to reach
# `merging`), red at merge time: the flag appears in between, so the merge's
# own run of the suite is the first one to fail.
walk_to_merging T013 task/T013 "$base13" "$cand13" "test ! -f $suite_red"
: > "$suite_red"

pre_integ13="$(git rev-parse "$integ")"
marker_before13="$(wc -l < "$gate_marker" | tr -d ' ')"
rc=0; "$ORCHID_BIN" merge T013 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "red suite -> merge exits 1"
assert_eq rework "$("$ORCHID_BIN" task show T013 | grep '^status: ' | cut -d' ' -f2)" "red suite -> task returns to rework"
assert_eq "$pre_integ13" "$(git rev-parse "$integ")" "red suite -> integration ref untouched"
assert_eq "$marker_before13" "$(wc -l < "$gate_marker" | tr -d ' ')" "red suite -> the gate was not EXECUTED (marker unchanged)"

log13=".orchid/reviews/T013-merge.log"
assert_match "^gate: ls >> " "$(cat "$log13")" "a suite-skipped gate is still named in the evidence"
assert_match "^gate_status: skipped-suite-failed$" "$(cat "$log13")" "the evidence says the suite's failure pre-empted the gate"
assert_eq "exit: 1" "$(tail -n1 "$log13")" "the log carries the SUITE's exit status, never the skipped gate's 3"

# The routing half, scoped to THIS task's journal entries — the run-wide
# journal already carries validation_failed from the earlier plain red-suite
# scenario, so matching the whole file would prove nothing.
journal13="$("$ORCHID_BIN" journal show --task T013)"
assert_match "validation_failed" "$journal13" "red suite journals validation_failed"
grep -q "gate_failed" <<<"$journal13" \
  && fail "red suite must NOT journal gate_failed — the gate never ran"

# --- (F) EVIDENCE ATTRIBUTION: one log, two commands, one of them guilty ---
# `orchid merge` now writes TWO commands' output into a single
# `<id>-merge.log`, and lib/findings.sh scrapes that log for the locations it
# puts in front of the next implementer. The characteristic failing shape is
# the one where the two DISAGREE — a green task suite followed by a red gate —
# and before the header carried a per-command status there was nothing in the
# file that could tell them apart: the trailing `exit:` line says the MERGE
# failed, which was a complete answer only while a log held one command.
#
# Two costs, and the second is the one that bites. The brief gets a passing
# run's chatter under a heading saying a failing gate reported it; and because
# FINDINGS_MAX_LINES caps the quoted list in LOG ORDER, with the suite's
# output first, a chatty green suite spends the whole cap and pushes the
# gate's real locations out of the brief entirely. So the suite below prints
# MORE than that cap: without the fix the brief contains twenty noise lines, a
# truncation notice, and not one word from the gate.
#
# Asserted in both directions, because a filter that simply dropped everything
# above the banner would pass the first half and silently lose a red suite's
# own evidence — which is the failing shape (E) leaves behind, and (F2) is
# that same log read back.
noisy="$WORK/noisy-suite.sh"
cat > "$noisy" <<'NOISY'
#!/usr/bin/env bash
# More than FINDINGS_MAX_LINES of perfectly well-formed, location-shaped
# output. Nothing about these lines is malformed — the shape rules in
# lib/findings.sh are meant to quote exactly this. Whether they SHOULD is a
# question about whose output it is, which only the recorded status answers.
i=1
while [ "$i" -le 25 ]; do
  echo "tests/task-suite.sh:$i: SC9999: printed by the task suite itself"
  i=$((i + 1))
done
NOISY
noise_pat="printed by the task suite itself"

# --- (F1) green suite + red gate: the brief quotes the GATE ----------------
set_gate "$gate_fail"

"$ORCHID_BIN" task create T014 "green suite, red gate"
git checkout -q -b task/T014 "$integ"
echo fourteen > feature14.txt && git add feature14.txt && git commit -q -m "feature 14"
cand14="$(git rev-parse HEAD)"
git checkout -q "$integ"
base14="$(git rev-parse "$integ")"

walk_to_merging T014 task/T014 "$base14" "$cand14" "bash $noisy && test -f feature14.txt"

pre_integ14="$(git rev-parse "$integ")"
rc=0; "$ORCHID_BIN" merge T014 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "green suite + red gate -> merge exits 1"
assert_eq "$pre_integ14" "$(git rev-parse "$integ")" "green suite + red gate -> integration ref untouched"

log14=".orchid/reviews/T014-merge.log"
log14_body="$(cat "$log14")"
assert_match "^command_status: 0$" "$log14_body" "the header records the TASK SUITE's own exit status, separately"
assert_match "^gate_status: ran$" "$log14_body" "...and that the gate ran"
assert_match "^gate_exit: 3$" "$log14_body" "...and the gate's own exit status, separately from the merge's"
assert_eq "exit: 3" "$(tail -n1 "$log14")" "the trailing exit: line still carries the MERGE's status"
# The log is the record and keeps everything. Attribution happens where the
# evidence is READ, never by throwing half of it away at the write — an
# operator opening this file must still see what the suite printed.
assert_match "$noise_pat" "$log14_body" "the log itself retains the passing suite's output in full"

body14="$(cat .orchid/tasks/T014.md)"
assert_match "orchid:rework-brief candidate=$cand14" "$body14" "a brief is written for the failed candidate"
assert_match "$gate_diag" "$body14" \
  "the brief carries the RED GATE's location — the one actionable line in the log"
grep -q "$noise_pat" <<<"$body14" \
  && fail "the brief must NOT quote the output of a command the header records as having PASSED — those locations were reported by nothing"
grep -q "further diagnostic line(s)" <<<"$body14" \
  && fail "the passing suite's 25 lines must not have spent the FINDINGS_MAX_LINES cap: the truncation notice means the gate's own locations were pushed out of the brief"

# --- (F2) red suite: its output IS the evidence ----------------------------
# Same script, same noise, gate still configured red — but now the suite
# fails, so the gate never runs and every one of those lines is the failing
# command's own. They must be carried. This is what makes (F1) an assertion
# about the recorded STATUS rather than about position in the file.
set_gate "$gate_fail"

suite_red2="$WORK/suite2-goes-red.flag"
"$ORCHID_BIN" task create T015 "red suite keeps its own evidence"
git checkout -q -b task/T015 "$integ"
echo fifteen > feature15.txt && git add feature15.txt && git commit -q -m "feature 15"
cand15="$(git rev-parse HEAD)"
git checkout -q "$integ"
base15="$(git rev-parse "$integ")"

walk_to_merging T015 task/T015 "$base15" "$cand15" "bash $noisy; test ! -f $suite_red2"
: > "$suite_red2"

rc=0; "$ORCHID_BIN" merge T015 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "red suite -> merge exits 1"

log15=".orchid/reviews/T015-merge.log"
log15_body="$(cat "$log15")"
assert_match "^command_status: 1$" "$log15_body" "the header records the suite's own non-zero status"
assert_match "^gate_status: skipped-suite-failed$" "$log15_body" "the gate did not run"
grep -q '^gate_exit: ' <<<"$log15_body" \
  && fail "a gate that never executed must publish no exit status — gate_rc is 0 by initialisation, and printing it would read as a pass"

body15="$(cat .orchid/tasks/T015.md)"
assert_match "orchid:rework-brief candidate=$cand15" "$body15" "a brief is written for the failed candidate"
assert_match "tests/task-suite\.sh:1: SC9999: $noise_pat" "$body15" \
  "the RED suite's own locations are carried — the filter keys on the recorded status, not on being above the banner"
assert_match "further diagnostic line\(s\)" "$body15" \
  "and the cap still applies to them, still announced rather than silently truncated"

# --- (F3) the classifier's OWN arms, over hand-built logs ------------------
# (F1) and (F2) drive the two shapes a real `orchid merge` can produce. They
# cannot reach the rest of what lib/findings.sh promises, because the only
# writer of these headers is the verb that also decides which command runs:
# `orchid merge` skips the gate when the suite failed, always writes the
# banner it named in `gate:`, and always writes both statuses as shell
# integers. So every arm that is about a log which does NOT hold together --
# and every arm that is about the day that skip rule changes -- is reachable
# from here and nowhere else.
#
# Worth reaching, because the cost is asymmetric and silent. This function
# decides what the next implementer is SHOWN. A wrong "keep" is noise in a
# brief; a wrong "drop" is the failing gate's only actionable locations
# deleted on the way to the one actor asked to fix them, under a heading that
# still says a gate reported something. Nothing downstream can tell that
# happened -- the log on disk is complete either way.
#
# Hand-built logs, deliberately: the arms below are precisely the ones the
# real writer cannot emit, so a fixture built by running a merge could not
# express them. The two contrast arms -- (F3a), and the first arm of (F3f) --
# are what keep the rest from being vacuous: a function that answered "keep
# everything" to every log, or a predicate that answered "not a gate failure"
# to every log, would satisfy every negative arm below.
attrib_out() { ( source "$REPO_ROOT/lib/findings.sh"; findings_failing_output "$1" ); }
attrib_gate() { ( source "$REPO_ROOT/lib/findings.sh"; findings_log_gate_failed "$1" ); }

# --- (F3a) the canonical split, asked of the function directly -------------
# The (F1) shape: green suite, red gate, banner present and matching. The
# whole output is compared rather than grepped, so the header passing through
# unchanged and the BANNER being consumed are pinned alongside the split
# itself -- a banner left in the body would reach a brief as a finding.
cat > "$WORK/log-split.txt" <<'LOG'
date: 2026-01-01T00:00:00Z
sha: 1111111111111111111111111111111111111111
candidate: 2222222222222222222222222222222222222222
cwd: /tmp/wt
command: run-the-suite
command_status: 0
gate: run-the-gate
gate_status: ran
gate_exit: 3
---
suite/one.sh:1: printed by the passing suite

== merge_gate: run-the-gate
gate/two.sh:2: printed by the failing gate
exit: 3
LOG
assert_eq "date: 2026-01-01T00:00:00Z
sha: 1111111111111111111111111111111111111111
candidate: 2222222222222222222222222222222222222222
cwd: /tmp/wt
command: run-the-suite
command_status: 0
gate: run-the-gate
gate_status: ran
gate_exit: 3
---
gate/two.sh:2: printed by the failing gate
exit: 3" "$(attrib_out "$WORK/log-split.txt")" \
  "the header passes through whole, the passing suite's half goes, the failing gate's half stays, and the banner is consumed rather than quoted as a finding"

# --- (F3b) the header promises a boundary the body does not carry ----------
# THE ARM WITH THE WORST FAILURE. The header says a gate ran and went red; the
# body holds no banner naming the command `gate:` recorded (here because the
# two disagree -- equally: a `gate:` line lost to a truncated write, or a
# writer that stopped emitting the banner). Nothing in the file says where one
# command's output ends, so NEITHER half can be attributed -- and a `keep`
# decision made from the suite's green status would then delete the gate's
# locations along with it, leaving a brief that quotes nothing at all from the
# log that most needed quoting.
cat > "$WORK/log-noboundary.txt" <<'LOG'
date: 2026-01-01T00:00:00Z
sha: 1111111111111111111111111111111111111111
candidate: 2222222222222222222222222222222222222222
cwd: /tmp/wt
command: run-the-suite
command_status: 0
gate: run-the-gate
gate_status: ran
gate_exit: 3
---
suite/one.sh:1: printed by the passing suite
== merge_gate: some-other-command
gate/two.sh:2: printed by the failing gate
exit: 3
LOG
noboundary_out="$(attrib_out "$WORK/log-noboundary.txt")"
assert_match "gate/two\.sh:2: printed by the failing gate" "$noboundary_out" \
  "an unlocatable boundary keeps the gate's output -- what cannot be attributed must not be deleted, and this is the half a green suite's status would otherwise take with it"
assert_match "suite/one\.sh:1: printed by the passing suite" "$noboundary_out" \
  "...and keeps the suite's half beside it, because 'I cannot tell which of these is which' is the answer, not 'therefore the green one'"

# --- (F3c) a status field that says nothing readable ----------------------
# `x + 0` is 0 in awk, so a bare compare-against-zero reads every unparseable
# status as a PASS and throws that command's output away. A field this shape
# is not a claim that anything passed.
cat > "$WORK/log-badstatus.txt" <<'LOG'
date: 2026-01-01T00:00:00Z
candidate: 2222222222222222222222222222222222222222
command: run-the-suite
command_status: x
---
suite/one.sh:1: printed by a suite whose status is unreadable
exit: 1
LOG
assert_match "suite/one\.sh:1: printed by a suite whose status is unreadable" \
  "$(attrib_out "$WORK/log-badstatus.txt")" \
  "an unreadable command_status keeps the output -- 'this says it passed' and 'this says nothing I can read' must not be the same answer"

# ...and the same rule on the gate's own field. `command_status: 0` IS
# readable here, so the suite's half still goes: this pins that the guard is
# per-field rather than a blanket give-up on the whole log.
cat > "$WORK/log-badgateexit.txt" <<'LOG'
date: 2026-01-01T00:00:00Z
candidate: 2222222222222222222222222222222222222222
command: run-the-suite
command_status: 0
gate: run-the-gate
gate_status: ran
gate_exit: not-a-number
---
suite/one.sh:1: printed by the passing suite
== merge_gate: run-the-gate
gate/two.sh:2: printed by a gate whose status is unreadable
exit: 1
LOG
badgate_out="$(attrib_out "$WORK/log-badgateexit.txt")"
assert_match "gate/two\.sh:2: printed by a gate whose status is unreadable" "$badgate_out" \
  "an unreadable gate_exit keeps the gate's output too"
grep -q "printed by the passing suite" <<<"$badgate_out" \
  && fail "the suite's status was perfectly readable and said 0 -- one unreadable field must not turn the whole log into 'keep everything', or the attribution stops meaning anything"

# --- (F3d) a red suite and a GREEN gate -----------------------------------
# `orchid merge` cannot produce this today: it skips the gate when the suite
# has already failed. It is pinned because it is the shape that proves the
# split is driven by the two RECORDED statuses rather than by position -- a
# filter that kept everything above the banner, or everything below it, passes
# (F3a) and fails here. The day that skip rule changes, this arm is what
# already holds.
cat > "$WORK/log-inverse.txt" <<'LOG'
date: 2026-01-01T00:00:00Z
candidate: 2222222222222222222222222222222222222222
command: run-the-suite
command_status: 1
gate: run-the-gate
gate_status: ran
gate_exit: 0
---
suite/one.sh:1: printed by the failing suite
== merge_gate: run-the-gate
gate/two.sh:2: printed by the passing gate
exit: 1
LOG
inverse_out="$(attrib_out "$WORK/log-inverse.txt")"
assert_match "suite/one\.sh:1: printed by the failing suite" "$inverse_out" \
  "the RED suite's half is kept even though it is the half above the banner"
grep -q "printed by the passing gate" <<<"$inverse_out" \
  && fail "a gate the header records as having exited 0 reported nothing, so its output must not be quoted to an implementer as though it had"

# --- (F3e) a single-command log is untouched ------------------------------
# `orchid verify`'s log, and every merge log written before these fields
# existed. It classifies nothing, so nothing may be removed from it.
cat > "$WORK/log-verify.txt" <<'LOG'
date: 2026-01-01T00:00:00Z
candidate: 2222222222222222222222222222222222222222
command: run-the-suite
---
suite/one.sh:1: printed by a verify run
exit: 1
LOG
assert_eq "date: 2026-01-01T00:00:00Z
candidate: 2222222222222222222222222222222222222222
command: run-the-suite
---
suite/one.sh:1: printed by a verify run
exit: 1" "$(attrib_out "$WORK/log-verify.txt")" \
  "a log with no per-command classification in it is passed through byte for byte -- the T007 fields are additive, and an older log must read exactly as it did"

# --- (F3f) findings_log_gate_failed: what it will and will not claim ------
# The predicate `runners/orchid-drive` calls to decide whether to tell a human
# the REPOSITORY is red -- and, at the cap, whether to raise an operator
# boundary. It is the mirror image of the function above: that one keeps what
# it cannot classify, this one claims nothing it cannot read.
attrib_gate "$WORK/log-split.txt" \
  || fail "test bug: a log that plainly records a gate that RAN and exited 3 must read as a gate failure, or every negative arm below is vacuous"

cat > "$WORK/log-gate-green.txt" <<'LOG'
gate: run-the-gate
gate_status: ran
gate_exit: 0
---
exit: 0
LOG
attrib_gate "$WORK/log-gate-green.txt" \
  && fail "a gate that ran and exited 0 is not a gate failure"

cat > "$WORK/log-gate-nan.txt" <<'LOG'
gate: run-the-gate
gate_status: ran
gate_exit: boom
---
exit: 1
LOG
attrib_gate "$WORK/log-gate-nan.txt" \
  && fail "an unreadable gate_exit must not become the claim 'this repository's gate is red' -- and a numeric compare against it is a shell ERROR, which in a set -e driver is a dead pass rather than a no"

cat > "$WORK/log-gate-skipped.txt" <<'LOG'
gate: run-the-gate
gate_status: skipped-nested
gate_exit: 3
---
exit: 3
LOG
attrib_gate "$WORK/log-gate-skipped.txt" \
  && fail "a gate recorded as SKIPPED did not fail, whatever else the header carries: the status is asked first, and a skip that read as a failure would charge an attempt for a gate that never executed"

# The impersonation arm, and the reason both statuses live in the header. This
# log's header states NO gate status at all; the only `gate_status: ran` and
# `gate_exit: 3` in the file are in captured OUTPUT -- a test echoing them, a
# suite printing a merge log of its own. Parsing stops at the `---`, so they
# are text and not a classification. Written with the header silent rather
# than merely disagreeing, because a header that disagreed would answer this
# correctly by accident: the predicate exits at the FIRST `gate_status:` it
# sees, so only an absent one makes the `---` stop the thing being tested.
cat > "$WORK/log-gate-impostor.txt" <<'LOG'
gate: run-the-gate
---
gate_status: ran
gate_exit: 3
exit: 0
LOG
attrib_gate "$WORK/log-gate-impostor.txt" \
  && fail "captured output below the --- must not be able to state this log's classification: a suite that prints a gate header would otherwise charge its own task an attempt for a repository condition that never happened"

# ---------------------------------------------------------------------------
# (G) A PERSISTENTLY RED GATE IS BOUNDED.
#
# Everything above proves the gate BLOCKS. This proves it TERMINATES, which is
# a different property and was missing: `merging -> rework` charges no
# attempt, deliberately, because the candidate was independently verified once
# already and a conflict or a revalidation failure is not a fresh round of the
# implementer's work. That reasoning holds for every merge failure except this
# one. A red repo-wide gate is a statement about the REPOSITORY, and a
# repository nobody has touched is red again next round -- so the uncharged
# edge gives dispatch -> implement -> verify -> review -> merge -> red gate ->
# rework -> dispatch, forever, with the counter that exists to stop it never
# moving. Uncharged it does not terminate; it spends engine budget until an
# operator happens to look.
#
# So the assertion is arithmetic, and it is made round by round rather than
# only at the end: the SAME red gate, on an unchanged repository, must cost
# one attempt each time and stop at the cap. `rework_max` is unset in this
# fixture's config, so the budget is the documented default of 3.
# ---------------------------------------------------------------------------
attempts_of() { "$ORCHID_BIN" task show "$1" | grep '^attempts: ' | cut -d' ' -f2; }

set_gate "$gate_fail"

"$ORCHID_BIN" task create T016 "a red gate must not loop forever"
git checkout -q -b task/T016 "$integ"
echo sixteen > feature16.txt && git add feature16.txt && git commit -q -m "feature 16"
cand16="$(git rev-parse HEAD)"
git checkout -q "$integ"
base16="$(git rev-parse "$integ")"
pre_integ16="$(git rev-parse "$integ")"

assert_eq 0 "$(attempts_of T016)" "the task starts the scenario having spent nothing"

# --- round 1 and round 2: charged, and still sent back for another go ------
for round in 1 2; do
  walk_to_merging T016 task/T016 "$base16" "$cand16" "test -f feature16.txt"
  rc=0; "$ORCHID_BIN" merge T016 >/dev/null 2>&1 || rc=$?
  assert_eq 1 "$rc" "round $round: red gate -> merge exits 1"
  assert_eq rework "$("$ORCHID_BIN" task show T016 | grep '^status: ' | cut -d' ' -f2)" \
    "round $round: with rounds still left, a red gate routes to rework exactly as before"
  assert_eq "$round" "$(attempts_of T016)" \
    "round $round: ...and it COSTS one -- an uncharged edge is what makes a red gate loop forever"
done

# --- round 3: the charge reaches the cap, so the edge changes --------------
walk_to_merging T016 task/T016 "$base16" "$cand16" "test -f feature16.txt"
rc=0; "$ORCHID_BIN" merge T016 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "round 3: merge still exits 1 -- the exit code is not what carries this"
assert_eq blocked "$("$ORCHID_BIN" task show T016 | grep '^status: ' | cut -d' ' -f2)" \
  "round 3: the charge spends the last round, so merge stops the task instead of sending it round again"
assert_eq 3 "$(attempts_of T016)" "round 3: the round that blocked is itself charged, not skipped"
assert_eq "$pre_integ16" "$(git rev-parse "$integ")" \
  "three red rounds moved the integration ref not one commit"
git show "$integ:feature16.txt" >/dev/null 2>&1 \
  && fail "and the candidate never reached the integration branch"

journal16="$("$ORCHID_BIN" journal show --task T016)"
assert_match "gate_failed" "$journal16" "every round journals the gate as the cause"
assert_match "candidate attempt #3 charged while blocking" "$journal16" \
  "the blocking round records the kernel-derived attempt number it charged"
assert_match "orchid task reverify T016" "$journal16" \
  "and names the recovery that costs no attempt -- the gate is frequently not this task's doing"
assert_match "orchid task retry T016" "$journal16" \
  "...alongside the one that grants rounds back"

# The evidence has to survive the block, because the block is not the end of
# the story: the operator's route back out of `blocked` is what lifts the
# rework brief, and the gate's locations exist in this log and nowhere the
# implementer can reach. This is the load-bearing half of the pair below —
# `merging -> blocked` runs none of the `to = rework` invalidation, so the
# question is whether the block introduced a rm of its own.
[ -f .orchid/reviews/T016-merge.log ] \
  || fail "blocking must not discard the merge evidence -- it is the only copy of the gate's own output"

"$ORCHID_BIN" task unblock T016 --reason "gate fixed in the repository" >/dev/null
[ -f .orchid/reviews/T016-merge.log ] \
  && fail "unblock must consume that log the way every other entry to rework does -- a log left behind outlives the candidate it describes"
body16="$(cat .orchid/tasks/T016.md)"
# NOT a proof on its own that the unblock carried it: the charged rounds above
# each appended their own brief for this same candidate, so the location is
# already in the body. It is here as the end-to-end guard that the route out
# of `blocked` leaves the next implementer holding the gate's locations rather
# than a pointer to a log that has just been deleted.
assert_match "$gate_diag" "$body16" \
  "the RED GATE's location is in the body the next implementer is handed, after the log carrying it is gone"

# ---------------------------------------------------------------------------
# (G2) THE EXEMPTION IS INTACT FOR EVERY OTHER MERGE FAILURE.
#
# (G) is only half the claim. The charge is scoped to `gate_failed` because
# that is the failure that repeats identically; a merge conflict is resolved
# by the next rebase and a red suite is the candidate's own defect, already
# counted where it was found. Charging those would quietly halve every task's
# rework budget, and nothing above would notice -- the counter is not read
# again until the driver blocks on it, several rounds later and somewhere
# else.
# ---------------------------------------------------------------------------
# --- (G2a) a red task suite: `validation_failed`, and no charge ------------
set_gate "$gate_fail"

suite_red3="$WORK/suite3-goes-red.flag"
"$ORCHID_BIN" task create T017 "validation_failed charges nothing"
git checkout -q -b task/T017 "$integ"
echo seventeen > feature17.txt && git add feature17.txt && git commit -q -m "feature 17"
cand17="$(git rev-parse HEAD)"
git checkout -q "$integ"
base17="$(git rev-parse "$integ")"

walk_to_merging T017 task/T017 "$base17" "$cand17" "test ! -f $suite_red3"
: > "$suite_red3"
assert_eq 0 "$(attempts_of T017)" "T017 has spent nothing going in"
rc=0; "$ORCHID_BIN" merge T017 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "red suite -> merge exits 1"
assert_eq rework "$("$ORCHID_BIN" task show T017 | grep '^status: ' | cut -d' ' -f2)" "red suite -> rework"
assert_eq 0 "$(attempts_of T017)" \
  "a red SUITE still charges nothing at merge -- the exemption survives; only gate_failed opts out of it"
journal17="$("$ORCHID_BIN" journal show --task T017)"
assert_match "validation_failed" "$journal17" "and it is journaled as the validation failure it is"
grep -q "gate_failed" <<<"$journal17" \
  && fail "the gate never ran here, so nothing may attribute this round to it"
grep -q "candidate attempt #" <<<"$journal17" \
  && fail "and no attempt-charge line may appear for an edge that charged no attempt"

# --- (G2b) a merge conflict: no charge either -----------------------------
set_gate "$gate_fail"

"$ORCHID_BIN" task create T018 "a merge conflict charges nothing"
git checkout -q -b task/T018 "$integ"
echo "task version" > clash18.txt && git add clash18.txt && git commit -q -m "clash 18 from task"
cand18="$(git rev-parse HEAD)"
git checkout -q "$integ"
base18="$(git rev-parse "$integ")"
echo "integ version" > clash18.txt && git add clash18.txt && git commit -q -m "clash 18 from integ"

walk_to_merging T018 task/T018 "$base18" "$cand18" "true"
# Same device the T003 conflict scenario uses: force base_sha current so this
# takes the conflict arm rather than the rebase-reset arm.
"$ORCHID_BIN" task set T018 base_sha "$(git rev-parse "$integ")"
assert_eq 0 "$(attempts_of T018)" "T018 has spent nothing going in"
marker_before18="$(wc -l < "$gate_marker" | tr -d ' ')"
rc=0; "$ORCHID_BIN" merge T018 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "merge conflict -> exit 1"
assert_eq rework "$("$ORCHID_BIN" task show T018 | grep '^status: ' | cut -d' ' -f2)" "merge conflict -> rework"
assert_eq 0 "$(attempts_of T018)" \
  "a merge conflict charges nothing -- it is resolved by the next rebase, not by spending the implementer's rounds"
assert_eq "$marker_before18" "$(wc -l < "$gate_marker" | tr -d ' ')" \
  "and the gate never even executed: a conflict aborts before any command runs"

# ---------------------------------------------------------------------------
# (G3) THE OPT-IN IS A WHITELIST, NOT A GENERAL COUNTER-WRITING OPTION.
#
# `--charge-attempt` is how `orchid merge` gets past the `merging -> rework`
# exemption, and the danger in widening it is that it becomes a way for any
# caller to write the kernel-owned counter from any edge. It stays validated
# against a closed set of edges, and `testing -> rework` in particular is NOT
# in it: that edge already charges through its own accounting, so admitting
# the flag there would charge the same round twice.
# ---------------------------------------------------------------------------
# T018 is idle in `rework` after the conflict above; walk it into `testing` so
# the probe is made on the edge that actually matters, rather than on some
# arbitrary illegal one.
"$ORCHID_BIN" task advance T018 implementing >/dev/null
"$ORCHID_BIN" task advance T018 testing >/dev/null

rc=0
charge_err="$("$ORCHID_BIN" task advance T018 rework --charge-attempt 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--charge-attempt must be refused on testing -> rework, which already charges through its own accounting"
assert_match "only valid for" "$charge_err" "and refused by naming the edges it IS valid for"
assert_eq testing "$("$ORCHID_BIN" task show T018 | grep '^status: ' | cut -d' ' -f2)" \
  "the refusal is made before any write -- the task did not move"
assert_eq 0 "$(attempts_of T018)" "...and the counter it was trying to write did not move either"

# The reason the flag is refused there, made concrete: this edge charges on
# its own. Admitting `--charge-attempt` would have charged the round twice,
# and nothing downstream would have shown it -- `attempts` is not read again
# until the driver blocks on it, rounds later and somewhere else. Also leaves
# the fixture idle, so a scenario appended after this one is not starved of a
# concurrency slot.
"$ORCHID_BIN" task advance T018 rework --reason "probe complete" >/dev/null
assert_eq 1 "$(attempts_of T018)" \
  "the plain testing -> rework edge charges exactly one on its own -- which is why the flag has no business there"

# ---------------------------------------------------------------------------
# (H) A MERGE THAT FAILS BEFORE IT WRITES EVIDENCE IS NOT JUDGED BY THE LAST
# MERGE'S LOG.
#
# `<id>-merge.log` outlives the merge that wrote it deliberately: the
# `merging` arm of `task advance rework` exempts it from its rm so the failure
# it is journaling keeps the evidence the next brief quotes. Every merge
# failure that happens BEFORE that log is written -- the conflict used here,
# and equally a rebase conflict, an unapplied operator prerequisite or a CAS
# lost to a concurrent merge -- then ends with a merge that produced no
# evidence at all and a file on disk that reads exactly like evidence it
# produced.
#
# That file is what `runners/orchid-drive` classifies a failed merge from
# (findings_log_gate_failed, over the `gate_status:`/`gate_exit:` header it
# reads and never infers). Left alone, the previous round's red gate is
# inherited by a conflict and announced as a repository condition -- with an
# attempt charge attributed to it that nothing ever made, and, once the count
# gets there, an operator boundary raised over a gate that did not run. The
# sha binding cannot catch it, which is why this scenario is one candidate
# twice: a conflicted candidate is re-merged UNCHANGED, so the stale header
# names the very candidate under work.
# ---------------------------------------------------------------------------
set_gate "$gate_fail"

"$ORCHID_BIN" task create T019 "a conflict must not inherit the last round's gate failure"
git checkout -q -b task/T019 "$integ"
echo "task version" > clash19.txt && git add clash19.txt && git commit -q -m "clash 19 from task"
cand19="$(git rev-parse HEAD)"
git checkout -q "$integ"
base19="$(git rev-parse "$integ")"

# --- round 1: a red gate, which writes the log the next round must not use --
walk_to_merging T019 task/T019 "$base19" "$cand19" "true"
rc=0; "$ORCHID_BIN" merge T019 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "round 1: the red gate fails the merge"
log19=".orchid/reviews/T019-merge.log"
assert_match "^gate_status: ran$" "$(cat "$log19")" "round 1 leaves a log that records a gate that RAN"
assert_match "^gate_exit: 3$" "$(cat "$log19")" "...and the non-zero status it ran to"
# Kept, so the classification below can be shown to be capable of saying yes.
# A negative assertion whose predicate answers no to everything proves nothing.
stale19="$WORK/T019-round1-merge.log"
cp "$log19" "$stale19"

# --- round 2: a conflict on the SAME candidate, which writes nothing -------
# The conflicting side lands on the integration branch, and `base_sha` is
# forced current afterwards for the reason the T003 and T018 scenarios force
# it: otherwise this takes the rebase-reset arm instead of the conflict arm.
echo "integ version" > clash19.txt && git add clash19.txt && git commit -q -m "clash 19 from integ"
walk_to_merging T019 task/T019 "$base19" "$cand19" "true"
"$ORCHID_BIN" task set T019 base_sha "$(git rev-parse "$integ")"

# The fixture's own premise, asserted rather than assumed: the round-1 log has
# to still be here when round 2 begins, or this scenario reproduces nothing.
[ -f "$log19" ] \
  || fail "fixture invariant broken: the round-1 merge log is already gone before round 2 starts, so nothing below is testing what it says it tests"

pre_integ19="$(git rev-parse "$integ")"
attempts_before19="$(attempts_of T019)"
marker_before19="$(wc -l < "$gate_marker" | tr -d ' ')"
rc=0; "$ORCHID_BIN" merge T019 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "round 2: a merge conflict exits 1, like every other merge failure"
assert_eq rework "$("$ORCHID_BIN" task show T019 | grep '^status: ' | cut -d' ' -f2)" \
  "round 2: a conflict routes to rework"
assert_eq "$pre_integ19" "$(git rev-parse "$integ")" "round 2: the integration ref did not move"
assert_eq "$attempts_before19" "$(attempts_of T019)" \
  "round 2: a conflict charges nothing -- the exemption is intact for the failure that actually happened"
assert_eq "$marker_before19" "$(wc -l < "$gate_marker" | tr -d ' ')" \
  "round 2: the gate never executed, so there is nothing for a gate_failed reading to be about"

# THE DEFECT, asked through the very predicate `runners/orchid-drive` calls
# rather than through a re-implementation of it here.
if ( source "$REPO_ROOT/lib/findings.sh"; findings_log_gate_failed "$log19" ); then
  fail "a merge that ran no gate is still classified as a gate failure -- the previous round's evidence outlived the merge that wrote it, and every reader downstream reads it as this round's"
fi
# ...and the same predicate, over the same bytes, saying yes. Without this the
# check above passes just as well against a predicate that is broken outright.
if ! ( source "$REPO_ROOT/lib/findings.sh"; findings_log_gate_failed "$stale19" ); then
  fail "test bug, not a merge failure: round 1's log does not read as a gate failure even when handed to the predicate directly, so the negative check above is vacuous"
fi
[ -f "$log19" ] \
  && fail "this merge wrote no evidence, so no evidence may be on disk under its name: a log that survives a merge which produced none is a claim about a round that never made one"

journal19="$("$ORCHID_BIN" journal show --task T019)"
assert_match "merge conflict" "$journal19" "the round is journaled as the conflict it was"

# ---------------------------------------------------------------------------
# (I) THE CONFIG PRECONDITION, BOTH ANSWERS.
#
# `merge_gate` is read from `$repo/orchid.config`, so a self-hosted merge that
# LANDS a gate and leaves its own checkout resolving the pre-merge file makes
# the floor inert in the repository that just adopted it — L016 wearing the
# clothes of its own fix. So `orchid merge` brings that file to the branch
# when it moved it. What decides whether it may is `orchid.config`'s own
# bytes, since an edit awaiting `orchid config commit` is legitimate and
# uncommitted by definition and may not be restored out from under whoever
# made it (the r-001 journal-loss hazard, one file over).
#
# tests/test_stale_root.sh drives the whole of that through a real
# self-hosted `orchid merge` (checks 10c and 10d), where the fixture is an
# entire orchid root. What is pinned HERE is the decision itself, in every
# shape that answers it — because a precondition that quietly answers "clean"
# to everything is a silent overwrite, and one that answers "dirty" to
# everything is a gate that never activates and never says why.
# ---------------------------------------------------------------------------
cfg_clean() {  # the precondition, asked exactly as `orchid merge` asks it
  ( export HOME="$WORK/home" ORCHID_ALLOW_STALE_ROOT=1
    source "$REPO_ROOT/lib/common.sh"
    orchid_config_committed_clean "$1" )
}
cfg_refresh() {
  ( export HOME="$WORK/home" ORCHID_ALLOW_STALE_ROOT=1
    source "$REPO_ROOT/lib/common.sh"
    orchid_refresh_config "$1" "$2" )
}

cfgroot="$WORK/cfg-probe"
mkdir -p "$cfgroot"
printf 'integration_branch=orchid/integration\n' > "$cfgroot/orchid.config"
git init -q "$cfgroot"
git -C "$cfgroot" symbolic-ref HEAD refs/heads/orchid/integration
git -C "$cfgroot" add orchid.config
git -C "$cfgroot" commit -q -m "cfg probe: v1"
cfg_base="$(git -C "$cfgroot" rev-parse HEAD)"

# The landing this stands in for: a commit that changes the committed config,
# made somewhere else and published by a ref advance that never touches this
# checkout's tree or index — which is exactly what merge's CAS does, and is
# why this checkout goes on resolving the old values until something acts.
cfg_side="$WORK/cfg-probe-side"
git -C "$cfgroot" worktree add -q --detach "$cfg_side" orchid/integration
printf 'integration_branch=orchid/integration\nmerge_gate=true\n' > "$cfg_side/orchid.config"
git -C "$cfg_side" add orchid.config
git -C "$cfg_side" commit -q -m "cfg probe: the repository adopts a merge_gate"
cfg_head="$(git -C "$cfg_side" rev-parse HEAD)"

# --- (I1) nothing to lose: the answer is yes, and the write lands ----------
cfg_clean "$cfgroot" \
  || fail "a checkout with no config edit at all must read as clean -- a precondition that answers no to everything is a gate that never activates and never says why"
git -C "$cfgroot" update-ref refs/heads/orchid/integration "$cfg_head" "$cfg_base"
rc=0; cfg_refresh "$cfgroot" "$cfg_base" || rc=$?
assert_eq 0 "$rc" "the refresh reports success"
grep -q '^merge_gate=true$' "$cfgroot/orchid.config" \
  || fail "the committed gate is still not the live one here, so the repository that just adopted it would go on not running it"
assert_eq "" "$(git -C "$cfgroot" diff --name-only HEAD -- orchid.config)" \
  "the working tree carries the branch's bytes"
assert_eq "" "$(git -C "$cfgroot" diff --cached --name-only HEAD -- orchid.config)" \
  "and the index does too -- written last, after the tree, the same order the kernel refresh holds to"

# --- (I2) an unstaged edit: the answer is no ------------------------------
printf '# operator edit awaiting orchid config commit\n' >> "$cfgroot/orchid.config"
if cfg_clean "$cfgroot"; then
  fail "an uncommitted config edit read as clean -- the next self-hosted merge would restore over the operator's only copy"
fi

# --- (I3) ...and no when it is STAGED, which a working-tree diff cannot see -
git -C "$cfgroot" add orchid.config
if cfg_clean "$cfgroot"; then
  fail "a STAGED config edit read as clean: staging moves the file and its index entry together, so a check that asks only one of them is blind to exactly the edit an operator has been most careful with"
fi

# --- (I4) the green twin: with the edit gone the same check says yes again -
git -C "$cfgroot" reset -q HEAD -- orchid.config
git -C "$cfgroot" checkout -q HEAD -- orchid.config
cfg_clean "$cfgroot" \
  || fail "once the edit is dealt with the same checkout must read clean again -- a check that never recovers is a permanent refusal, not a precondition"

# --- (I5) an UNTRACKED orchid.config is somebody's file too ----------------
# The one shape `git diff` says nothing about: HEAD carries no orchid.config,
# so both diffs are empty and a check built on them alone would call this
# clean and let a merge that ADDS the file write straight over it.
cfgnew="$WORK/cfg-untracked"
mkdir -p "$cfgnew"
git init -q "$cfgnew"
git -C "$cfgnew" symbolic-ref HEAD refs/heads/orchid/integration
git -C "$cfgnew" commit -q --allow-empty -m "cfg probe: a repository with no committed config"
cfg_clean "$cfgnew" \
  || fail "test fixture: a repository with no orchid.config at all, tracked or on disk, must read clean -- otherwise I5 below proves nothing about the untracked file"
printf 'integration_branch=orchid/integration\n' > "$cfgnew/orchid.config"
if cfg_clean "$cfgnew"; then
  fail "an untracked orchid.config read as clean -- git diff is silent about a path HEAD does not carry, and the merge that adds one would overwrite the only copy of it"
fi

# --- (I6) an IGNORED orchid.config, and the report that has to name it -----
# The precondition asks `ls-files --others` WITHOUT `--exclude-standard` on
# purpose, so an ignored orchid.config counts as somebody's file and is
# refused like any other. That widening binds the REPORT as well, and this is
# where the two can silently come apart: a plain `git status --porcelain` says
# nothing at all about an ignored path, so the one case the precondition was
# widened to catch would be the one `orchid merge` warns about with an empty
# `Pending:` list -- telling the operator their file was preserved and leaving
# them no name to look for it under.
#
# What is pinned here is that coupling, at the level it lives at: the refusal,
# the blindness that makes the naive report wrong, and the shorthand the merge
# actually passes. The warning's own wording is driven end to end by
# tests/test_stale_root.sh check 10d, over a tracked edit -- the shape a real
# orchid root has, since `orchid.config` is meant to be committed (`orchid
# config commit`). This arm is the ignored twin of that check's premise.
printf 'orchid.config\n' > "$cfgnew/.gitignore"
git -C "$cfgnew" add .gitignore
git -C "$cfgnew" commit -q -m "cfg probe: this repository ignores its config"

if cfg_clean "$cfgnew"; then
  fail "an IGNORED orchid.config read as clean -- ignoring a file is not consenting to have it overwritten, and this is the merge's only chance to decline"
fi
# The blindness itself, asserted rather than assumed: without this the check
# below is just two git invocations agreeing, and there would be nothing to
# show that the flag `orchid merge` passes is load-bearing.
assert_eq "" "$(git -C "$cfgnew" status --porcelain -- orchid.config)" \
  "test premise: a plain porcelain status is silent about an ignored path -- if it ever stops being, the flag below is no longer what makes the warning able to name this file"
assert_match "orchid\.config" \
  "$(git -C "$cfgnew" status --porcelain --ignored -- orchid.config)" \
  "the shorthand 'orchid merge' reports a preserved config in must name the file in exactly the case the precondition was widened to refuse -- a warning that says a file was kept and does not say which is not a warning"

# T007's final fixture intentionally leaves a red repository gate configured.
set_gate ""
# `worktree_prepare` runs in the merge validation worktree too. That worktree
# is a fresh detached `git worktree add` of the integration head, so it holds
# ONLY what is committed -- and merge re-runs the task's whole suite there.
# A project whose suite needs anything untracked therefore passes its
# testing->reviewing gate (which runs in a checkout that has it) and fails
# every merge (in one that does not), with the failure recorded against the
# candidate. The prepare step is what closes that, and the temp worktree is
# also the case that makes ORCHID_REPO_ROOT necessary rather than convenient:
# it lives under $TMPDIR, so no relative path from it reaches this repository.
#
# RED before this task: merge never prepares its worktree, dep.txt is absent
# there, validation fails and T107 lands in rework instead of done.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T107 "merge validation worktree preparation"
git checkout -q -b task/T107 "$integ"
echo seven > prepare-merge-green.txt && git add prepare-merge-green.txt && git commit -q -m "feature 7"
cand7="$(git rev-parse HEAD)"
git checkout -q "$integ"
base7="$(git rev-parse "$integ")"

# Untracked in this checkout because the operator put it there -- the shape
# every real project has (installed dependencies, a generated file, a .env).
echo dep > dep.txt
cat > "$WORK/merge-prep.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
# Reaches BACK to the repository for something the checkout cannot have.
cp "$ORCHID_REPO_ROOT/dep.txt" "$ORCHID_WORKTREE/dep.txt"
EOF
chmod +x "$WORK/merge-prep.sh"
echo "worktree_prepare=$WORK/merge-prep.sh" >> orchid.config

walk_to_merging T107 task/T107 "$base7" "$cand7" "test -f dep.txt"

rc=0; "$ORCHID_BIN" merge T107 >"$WORK/merge7.out" 2>&1 || rc=$?
assert_eq 0 "$rc" "a suite needing untracked setup merges once worktree_prepare provides it"
assert_eq "done" "$("$ORCHID_BIN" task show T107 | grep '^status: ' | cut -d' ' -f2)" \
  "the candidate is not blamed for the validation worktree's missing setup"
prep7=".orchid/runtime/worktree-prepare/T107-merge.log"
[ -f "$prep7" ] \
  || fail "the merge validation worktree's prepare step writes its own log, under its own name"
# The log is named `<id>-merge` because a task usually has TWO prepared
# checkouts and one record must not overwrite the other. ORCHID_TASK is not:
# its contract is the task id, and a prepare command that keys a cache off it
# must get back the same string the rest of the protocol uses for that task,
# in both checkouts, with nothing to strip.
assert_match "^task: T107$" "$(cat "$prep7")" \
  "ORCHID_TASK is the bare task id in the merge worktree too, never the log's slug"
n_wt7="$(git worktree list | wc -l | tr -d ' ')"
assert_eq 2 "$n_wt7" "the prepared temp worktree is still torn down after the merge"

# ---------------------------------------------------------------------------
# A prepare step that FAILS must leave the operator pointing at evidence that
# exists. merge dies before it validates anything, so it writes no
# `<id>-merge.log` — and any copy an EARLIER attempt left behind (the
# merging->rework arm keeps that file on purpose) would now describe a
# candidate and a merged tree that no longer exist. The driver decides which
# message to send by asking whether that file is there, so a stale one is not
# merely untidy, it is the dangling-evidence defect of lesson L023: it sends
# someone to read a log about the wrong thing.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T108 "merge prepare fails"
git checkout -q -b task/T108 "$integ"
echo eight > prepare-merge-fail.txt && git add prepare-merge-fail.txt && git commit -q -m "feature 8"
cand8="$(git rev-parse HEAD)"
git checkout -q "$integ"
base8="$(git rev-parse "$integ")"
walk_to_merging T108 task/T108 "$base8" "$cand8" "test -f prepare-merge-fail.txt"

# Exactly what an earlier attempt on an earlier candidate leaves behind.
printf 'stale evidence from an attempt on a candidate that no longer exists\n' \
  > ".orchid/reviews/T108-merge.log"
echo 'worktree_prepare=sh -c "echo bootstrap-broke >&2; exit 9"' >> orchid.config

rc=0; "$ORCHID_BIN" merge T108 >"$WORK/merge8.out" 2>&1 || rc=$?
assert_eq 1 "$rc" "a failing prepare step makes merge refuse rather than validate"
assert_eq "merging" "$("$ORCHID_BIN" task show T108 | grep '^status: ' | cut -d' ' -f2)" \
  "the task stays in merging — the environment failed, so the candidate is not sent back to rework"
[ ! -f ".orchid/reviews/T108-merge.log" ] \
  || fail "a run that never validated must leave no validation evidence — including a previous attempt's"
prep8=".orchid/runtime/worktree-prepare/T108-merge.log"
[ -f "$prep8" ] || fail "the prepare step's own log is written even when the command fails"
assert_match "^exit: 9$" "$(cat "$prep8")" "that log records the command's own exit status"
assert_match "worktree-prepare/T108-merge.log" "$(cat "$WORK/merge8.out")" \
  "the refusal names a log that actually exists, not the validation log it never wrote"
n_wt8="$(git worktree list | wc -l | tr -d ' ')"
assert_eq 2 "$n_wt8" "the temp worktree is torn down even when the prepare step fails"

# ...AND IT IS COUNTED. An environment that cannot be prepared is the failure
# class this whole step exists to classify, so it goes on the infra ladder --
# the kernel-owned counter that journals its own reason and auto-blocks at
# `infra_max`. Charged nowhere, a bootstrap nobody repairs leaves the task in
# `merging` and the driver re-raising the same boundary every pass, forever,
# with no bound and no record. `attempts` is deliberately untouched: this is
# not a failed attempt by the candidate.
#
# RED before this change: infra_failures is still 0 and the journal holds no
# record of the environment failure.
assert_eq 1 "$("$ORCHID_BIN" task show T108 | grep '^infra_failures: ' | cut -d' ' -f2)" \
  "a merge validation worktree that cannot be prepared charges the infra ladder"
assert_match "worktree_prepare failed for the merge validation worktree" \
  "$("$ORCHID_BIN" journal show --task T108)" \
  "the infra failure records WHY, so an operator reads the environment's problem and not the candidate's"

# Fixture teardown, for the reason spelled out at the T004 case above: this is
# the file's SECOND case whose asserted end state is `merging`, and two parked
# tasks are exactly the run's whole concurrency cap. `blocked` rather than
# `rework` on purpose -- this case asserts above that an environment failure
# does NOT send this candidate back to rework, and the teardown must not
# quietly contradict the contract the case just proved. It is also what an
# operator actually does with a task whose bootstrap nobody has repaired: the
# infra ladder this case just charged auto-blocks at `infra_max` by itself.
"$ORCHID_BIN" task advance T108 blocked \
  --reason "fixture teardown: release the scheduling slot this parked task holds" >/dev/null

# ---------------------------------------------------------------------------
# ORCHID_REPO_ROOT reaches the VERIFICATION command too, in BOTH checkouts
# that run one.
#
# The prepare step alone does not close the gap this feature exists for: a
# suite that needs gitignored state from the dispatching repository has to
# reach back for it at verification time as well, and neither checkout can
# work out where that repository is on its own -- `orchid verify` runs in a
# SIBLING worktree, and merge validation runs in an unrelated $TMPDIR
# directory. This task's whole suite is one command that reaches back, and it
# is run twice by two different verbs: once by `orchid verify` inside
# walk_to_merging (the INV-11 gate), then again by `orchid merge` in the temp
# worktree. No prepare step is configured, so nothing but the verification
# environment itself can make it pass.
#
# RED before this change: ORCHID_REPO_ROOT is exported to the prepare child
# and to nothing else, so the command tests `/dep.txt`, verify FAILs, and
# walk_to_merging never gets the task past testing.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T109 "verification reaches back to the repository"
git checkout -q -b task/T109 "$integ"
echo nine > prepare-root-export.txt && git add prepare-root-export.txt && git commit -q -m "feature 9"
cand9="$(git rev-parse HEAD)"
git checkout -q "$integ"
base9="$(git rev-parse "$integ")"
# Unset again: T108 left a deliberately broken command as the last-wins value,
# and this case must prove the VERIFICATION environment carries the variable,
# with no prepare step in the picture at all.
echo 'worktree_prepare=' >> orchid.config

# dep.txt is untracked here (written during the T107 case above), so no
# checkout of any ref holds it -- reaching back is the only way to find it.
[ -f dep.txt ] || echo dep > dep.txt
walk_to_merging T109 task/T109 "$base9" "$cand9" 'test -f "$ORCHID_REPO_ROOT/dep.txt"'
assert_eq "merging" "$("$ORCHID_BIN" task show T109 | grep '^status: ' | cut -d' ' -f2)" \
  "orchid verify hands the suite ORCHID_REPO_ROOT, so the task reaches merging at all"

rc=0; "$ORCHID_BIN" merge T109 >"$WORK/merge9.out" 2>&1 || rc=$?
assert_eq 0 "$rc" "merge validation hands the same suite ORCHID_REPO_ROOT in the temp worktree"
assert_eq "done" "$("$ORCHID_BIN" task show T109 | grep '^status: ' | cut -d' ' -f2)" \
  "a suite that reaches back to the repository is not blamed for a checkout that cannot hold what it needs"
assert_match "^exit: 0$" "$(cat ".orchid/reviews/T109-merge.log")" \
  "the validation log records the suite passing in a \$TMPDIR checkout that has no relative path home"

# ---------------------------------------------------------------------------
# A merge that dies BEFORE it validates leaves no validation evidence --
# whichever of the many ways it dies.
#
# runners/orchid-drive reads the presence of `<id>-merge.log` as "this run got
# as far as validating", and picks which failure to report an operator from
# that. The deletion used to sit just above the temp worktree, so every die
# between the top of the verb and that line -- a missing base_sha or branch, a
# refused before_merge hook, an integration branch that does not exist, a
# rebase that could not get a worktree for the task branch -- left an earlier
# attempt's log in place for the driver to point at: a log about a candidate
# and a merged tree that no longer exist. That is lesson L023's
# dangling-evidence defect, arriving by a route no reader would suspect,
# because the file is real and the message naming it is confident.
#
# The integration branch is made to vanish for one invocation (through the
# config key's own env override, so no other case sees it) as the cheapest
# stand-in for that whole family: it dies at a check well above where the
# deletion used to be, with the task still in `merging`.
#
# RED before this change: T110-merge.log still holds the stale bytes.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T110 "merge dies before it validates"
git checkout -q -b task/T110 "$integ"
echo ten > prepare-stale-log.txt && git add prepare-stale-log.txt && git commit -q -m "feature 10"
cand10="$(git rev-parse HEAD)"
git checkout -q "$integ"
base10="$(git rev-parse "$integ")"
walk_to_merging T110 task/T110 "$base10" "$cand10" "test -f prepare-stale-log.txt"

printf 'stale evidence from an attempt on a candidate that no longer exists\n' \
  > ".orchid/reviews/T110-merge.log"
rc=0
ORCHID_INTEGRATION_BRANCH=no-such-branch "$ORCHID_BIN" merge T110 >"$WORK/merge10.out" 2>&1 || rc=$?
assert_eq 1 "$rc" "a merge that cannot even find its integration branch refuses"
assert_eq "merging" "$("$ORCHID_BIN" task show T110 | grep '^status: ' | cut -d' ' -f2)" \
  "the task stays in merging — nothing about the candidate was learned"
[ ! -f ".orchid/reviews/T110-merge.log" ] \
  || fail "a run that died before validating must leave no validation evidence, however early it died"

# The GREEN twin the same rule must accept: a run that DID validate leaves its
# log behind, so the driver has something real to point at. Without this, the
# case above is satisfied by a verb that simply never writes one.
rc=0; "$ORCHID_BIN" merge T110 >"$WORK/merge10b.out" 2>&1 || rc=$?
assert_eq 0 "$rc" "with the integration branch back, the same merge goes through"
[ -f ".orchid/reviews/T110-merge.log" ] \
  || fail "a run that DID validate leaves its own validation log"
assert_match "^exit: 0$" "$(cat ".orchid/reviews/T110-merge.log")" \
  "and that log is this run's, recording the suite it actually ran"

# The one route the two cases above cannot reach: this verb dying at
# `lock_acquire`, i.e. BEFORE the delete, which no ordering inside it can fix.
# runners/orchid-drive covers that end by fingerprinting the file across the
# call and treating unchanged bytes as no evidence -- driver-side, so it is
# out of this file's reach, and reaching it would mean holding the run lock
# across a full driver pass with a task walked all the way to `merging`.
not_tested "merge-log-outlives-a-lock-refusal" \
  "the driver-side half of the same rule (fingerprint across the call) needs a driver pass, not a verb call"

# ---------------------------------------------------------------------------
# The validation suite's stdin is /dev/null here too, never the caller's.
#
# This verb runs from inside runners/orchid-drive, whose own stdin is the
# worklist it is walking, and the suite below has only its stdout redirected
# -- so an inherited stdin is that worklist. A suite that reads stdin for any
# ordinary reason (a bootstrap ending in `cat`, a tool that stops to ask)
# then consumes the entries the pass has not reached yet: the walk sees EOF,
# work is silently skipped, and nothing reports an error, because a task the
# walk never reached looks exactly like a task with nothing to do. Same rule
# `orchid verify` follows (tests/test_verify.sh) -- applied here because this
# is the OTHER verb that runs the same suite, in the checkout that has no
# relative path home.
#
# The caller's stdin is a pipe holding known bytes, so this cannot pass by
# accident on a harness whose own stdin happens to be at EOF already.
#
# RED before this change: the probe holds those bytes -- the suite read the
# merge caller's stdin.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T111 "merge validation reads no stdin"
git checkout -q -b task/T111 "$integ"
echo eleven > prepare-stdin.txt && git add prepare-stdin.txt && git commit -q -m "feature 11"
cand11="$(git rev-parse HEAD)"
git checkout -q "$integ"
base11="$(git rev-parse "$integ")"

stdin_probe="$WORK/merge-verify-stdin.txt"
walk_to_merging T111 task/T111 "$base11" "$cand11" "cat > '$stdin_probe'"
# Truncated AFTER the walk, on purpose: `orchid verify` ran this same suite on
# the way to `merging` and wrote the file too. What is under test is what the
# MERGE run leaves in it.
: > "$stdin_probe"

rc=0
printf 'the caller stdin a validation suite must never read\n' \
  | "$ORCHID_BIN" merge T111 >"$WORK/merge11.out" 2>&1 || rc=$?
assert_eq 0 "$rc" "a validation suite that reads stdin still merges"
assert_eq "done" "$("$ORCHID_BIN" task show T111 | grep '^status: ' | cut -d' ' -f2)" \
  "reading EOF is not a failure -- the task still reaches done"
assert_eq "" "$(cat "$stdin_probe")" \
  "the validation suite reads EOF in the temp worktree, never the caller's stdin"

# T037 -- run-state containment. This verb grows the integration branch, and
# the integration branch carries `.orchid/`: roadmap, journal, BLOCKERS,
# plugins.lock, every review envelope. On a real product repository 14 of
# those files reached `main`, integration branch -> feature branch -> MR,
# approved because the diff was large and the paths look like tooling.
#
# The kernel never runs that merge and never may (PROTOCOL.md's Preamble), so
# what it owes the operator is to SEE the shape and say so: run state sitting
# on a branch that is neither the integration branch nor any task's recorded
# branch means the route out of the run is already open, and every further
# merge queues more state behind it.
#
# A WARNING, not a refusal -- the condition predates this merge, this verb
# cannot undo it, and refusing would freeze the task in `merging` over work
# that has to happen on branches orchid does not own. The refusal ships where
# it is safe and reversible: templates/pre-push.sh, at the boundary where the
# state would leave the machine (tests/test_launch.sh).
#
# RED (before this fix): no warning at all -- merge is silent while run state
# is already on its way into the product's history.
# ---------------------------------------------------------------------------
# T007's preceding scenarios deliberately finish with a red repository gate
# configured. Containment is the only variable in the two cases below, so
# restore the no-gate baseline before creating either candidate.
set_gate ""

"$ORCHID_BIN" task create T042 "containment green twin"
git checkout -q -b task/T042 "$integ"
echo green > containment-green.txt && git add containment-green.txt && git commit -q -m "containment green candidate"
cand7="$(git rev-parse HEAD)"
git checkout -q "$integ"
base7="$(git rev-parse "$integ")"
walk_to_merging T042 task/T042 "$base7" "$cand7" "test -f containment-green.txt"

out7="$WORK/merge7.out"; rc=0
"$ORCHID_BIN" merge T042 >"$out7" 2>&1 || rc=$?
assert_eq 0 "$rc" "containment: an ordinary repo still merges clean (exit 0)"
grep -q "run state" "$out7" \
  && fail "no branch outside the run carries run state -> merge must say nothing about containment"
green_case 'no branch outside the run carries .orchid/ -> merge warns about nothing'

# Now the leak, built the way it actually happens: the operator takes the
# integration branch onto a branch of their own. Built in a THROWAWAY
# worktree so the fixture's own checkout is never switched onto a branch that
# tracks .orchid/ (checking back out would delete the live run state under
# the suite's feet).
leak_wt="$WORK/leak-wt"
git worktree add -q -b product/main "$leak_wt" "$integ"
mkdir -p "$leak_wt/.orchid"
printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > "$leak_wt/.orchid/roadmap.md"
printf '# Journal\n' > "$leak_wt/.orchid/journal.md"
git -C "$leak_wt" add -f .orchid
git -C "$leak_wt" commit -q -m "operator: merged the integration branch into their own branch"
git worktree remove --force "$leak_wt"
[ -n "$(git ls-tree product/main -- .orchid)" ] \
  || fail "fixture: product/main must actually carry run state for the RED case to mean anything"

"$ORCHID_BIN" task create T043 "containment red case"
git checkout -q -b task/T043 "$integ"
echo red > containment-red.txt && git add containment-red.txt && git commit -q -m "containment red candidate"
cand8="$(git rev-parse HEAD)"
git checkout -q "$integ"
base8="$(git rev-parse "$integ")"
walk_to_merging T043 task/T043 "$base8" "$cand8" "test -f containment-red.txt"

# stdout and stderr captured SEPARATELY, in the one run this task has: the
# warning belongs on stderr, so a caller parsing merge's result line never has
# to filter advisory prose out of it. (Re-running the verb to check the other
# stream would prove nothing -- T043 is `done` by then and merge dies at its
# status gate, above this warning, leaving both files empty and both
# assertions passing vacuously.)
out8="$WORK/merge8.out"; err8="$WORK/merge8.err"; rc=0
"$ORCHID_BIN" merge T043 >"$out8" 2>"$err8" || rc=$?
assert_eq 0 "$rc" "containment: the warning is advisory -- the merge still completes (exit 0)"
assert_eq "done" "$("$ORCHID_BIN" task show T043 | grep '^status: ' | cut -d' ' -f2)" \
  "containment: a warned merge still reaches done, never deadlocks the task"
assert_match "^merged T043: $integ -> " "$(cat "$out8")" "containment: stdout still carries only the result line"
assert_match "run state" "$(cat "$err8")" "containment: the warning names what is leaking"
assert_match "product/main" "$(cat "$err8")" "containment: and names the branch outside the run that carries it"
assert_match "docs/troubleshooting.md" "$(cat "$err8")" "containment: and points at what to do about it"
grep -q "run state" "$out8" \
  && fail "the containment warning must go to stderr, never stdout"
grep -q "task/T00" "$err8" \
  && fail "a task's own branch is inside the run and must never be reported as a leak"
red_case 'a branch outside the run carrying .orchid/ is named by orchid merge'

# The twin that keeps that report worth reading: an ARCHIVED run's task branch
# is still orchid's own, not a product leak.
#
# `orchid run new` moves tasks/ wholesale to runs/<old_run_id>/tasks/ and
# starts a fresh, empty tasks/ -- but nothing in the kernel ever deletes a
# branch. So a repository on its second run still has every previous run's
# task branch sitting there, each carrying .orchid/ because it was cut from
# the integration branch. Asking only the LIVE tasks/ makes every one of them
# "outside the run", and a warning that recites orchid's own history on every
# merge is a warning an operator stops reading -- which is how the real leak,
# named in the same breath, goes past.
#
# The branch is deliberately NOT named `task/*`: the exemption must come from
# the archived RECORD, exactly as it does for a live task, never from the
# shape of the name.
#
# RED (before this fix): the warning names retired/T900-work as well.
mkdir -p .orchid/runs/r-000/tasks
printf -- '---\nid: T900\nbranch: retired/T900-work\n---\n# T900\n' \
  > .orchid/runs/r-000/tasks/T900.md
#
# Cutting the branch from "$integ" is NOT enough to build it: this fixture
# repository creates `.orchid/` on disk but never commits it, so a branch cut
# from the integration branch here carries an EMPTY `.orchid/` tree and the
# containment scan skips it before the exemption is ever consulted -- the case
# would pass without testing anything. Run state is put on the branch the same
# way the leak twin above does it, and in a throwaway worktree for the same
# reason: the suite's own checkout must never be switched onto a branch that
# tracks `.orchid/`, because checking back out would delete the live run state
# under it.
arch_wt="$WORK/archived-wt"
git worktree add -q -b retired/T900-work "$arch_wt" "$integ"
mkdir -p "$arch_wt/.orchid"
printf -- '---\nrun_status: archived\nrun_id: r-000\n---\n# Roadmap\n' > "$arch_wt/.orchid/roadmap.md"
git -C "$arch_wt" add -f .orchid
git -C "$arch_wt" commit -q -m "archived run: task branch carrying the run state it was cut with"
git worktree remove --force "$arch_wt"
[ -n "$(git ls-tree retired/T900-work -- .orchid)" ] \
  || fail "fixture: the archived run's branch must carry .orchid/ for this case to mean anything"

"$ORCHID_BIN" task create T044 "archived-run containment"
git checkout -q -b task/T044 "$integ"
echo archived > containment-archived.txt && git add containment-archived.txt \
  && git commit -q -m "containment archived-run candidate"
cand9="$(git rev-parse HEAD)"
git checkout -q "$integ"
base9="$(git rev-parse "$integ")"
walk_to_merging T044 task/T044 "$base9" "$cand9" "test -f containment-archived.txt"

err9="$WORK/merge9.err"; rc=0
"$ORCHID_BIN" merge T044 >/dev/null 2>"$err9" || rc=$?
assert_eq 0 "$rc" "containment: the archived-run case still merges clean (exit 0)"
grep -q "retired/T900-work" "$err9" \
  && fail "a branch recorded by an ARCHIVED run's task is inside the run, not a product leak"
# Non-vacuous: the very same merge must still name the branch that IS a leak,
# so this case cannot pass by the containment check having silently stopped
# running at all.
assert_match "product/main" "$(cat "$err9")" \
  "containment: and the real leak is still named in the same warning"
green_case 'an archived run task branch carrying .orchid/ is not reported as a leak'

# The LIVE half of the same exemption, built the way the archived one is.
#
# It was asserted before this block, and asserted VACUOUSLY: `grep -q task/T00`
# over the warning passed because no task branch in this fixture carries
# `.orchid/` at all (this repository creates run state on disk and never
# commits it), so the scan skipped every one of them on the tree test and the
# exemption was never consulted. An exemption that is never reached is not
# tested by an assertion that it did not fire. Here the branch really does
# carry run state, so the scan reaches the record lookup and the record is what
# has to answer.
#
# The branch is deliberately not named `task/*`, and the task that OWNS it is
# not the task being merged: "inside the run" is a fact about the run's
# records, not about a name or about which task happens to be in flight.
"$ORCHID_BIN" task create T045 "live task whose branch carries run state"
"$ORCHID_BIN" task set T045 branch live/T045-work
live_wt="$WORK/live-wt"
git worktree add -q -b live/T045-work "$live_wt" "$integ"
mkdir -p "$live_wt/.orchid"
printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > "$live_wt/.orchid/roadmap.md"
git -C "$live_wt" add -f .orchid
git -C "$live_wt" commit -q -m "live task: work on a branch cut from the integration branch"
git worktree remove --force "$live_wt"
[ -n "$(git ls-tree live/T045-work -- .orchid)" ] \
  || fail "fixture: the live task's branch must carry .orchid/ for this case to mean anything"

"$ORCHID_BIN" task create T046 "live-task containment"
git checkout -q -b task/T046 "$integ"
echo live > containment-live.txt && git add containment-live.txt \
  && git commit -q -m "containment live-task candidate"
cand10="$(git rev-parse HEAD)"
git checkout -q "$integ"
base10="$(git rev-parse "$integ")"
walk_to_merging T046 task/T046 "$base10" "$cand10" "test -f containment-live.txt"

err10="$WORK/merge10.err"; rc=0
"$ORCHID_BIN" merge T046 >/dev/null 2>"$err10" || rc=$?
assert_eq 0 "$rc" "containment: the live-task case still merges clean (exit 0)"
grep -q "live/T045-work" "$err10" \
  && fail "a branch a LIVE task's record names is inside the run, not a product leak"
assert_match "product/main" "$(cat "$err10")" \
  "containment: and the real leak is still named in the same warning"
green_case 'a live task branch carrying .orchid/ is not reported as a leak'

# ---------------------------------------------------------------------------
# The INTEGRATION branch's own exemption -- the arm that decides whether this
# warning is worth reading at all, since in every real repository that branch
# is the one place run state is SUPPOSED to be, and a warning that names it on
# every merge names it forever.
#
# Asked of the predicate directly, in a repository built for the question,
# because it cannot honestly be asked of the fixture above: making THAT
# integration branch carry `.orchid/` means committing the suite's own live run
# state, and from that moment every `git checkout` between the integration
# branch and a task branch cut before it either fails on untracked files or
# deletes the state the rest of the suite is reading. The predicate is the
# whole of the decision (libexec/orchid-merge only formats what it returns),
# and the verb cases above already pin that the merge path reaches it.
#
# Every branch here carries run state, so NONE of them is skipped on the tree
# test and all four reach the exemption: the assertion is the exact, whole
# output, which is what makes each exemption non-vacuous -- a broken one shows
# up as an extra line, and a scan that stopped working shows up as a missing
# `product/main`.
scan_repo="$WORK/containment-scan"
mkdir -p "$scan_repo"
git -C "$scan_repo" init -q
git -C "$scan_repo" commit -q --allow-empty -m "the operator's own history"
git -C "$scan_repo" checkout -q -b orchid/integration
mkdir -p "$scan_repo/.orchid/tasks" "$scan_repo/.orchid/runs/r-000/tasks"
printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > "$scan_repo/.orchid/roadmap.md"
printf -- '---\nid: T801\nbranch: live/T801-work\n---\n# T801\n' \
  > "$scan_repo/.orchid/tasks/T801.md"
printf -- '---\nid: T802\nbranch: retired/T802-work\n---\n# T802\n' \
  > "$scan_repo/.orchid/runs/r-000/tasks/T802.md"
git -C "$scan_repo" add -f .orchid
git -C "$scan_repo" commit -q -m "orchid: run state on the integration branch, as every real run has it"
for scan_b in live/T801-work retired/T802-work product/main; do
  git -C "$scan_repo" branch "$scan_b" orchid/integration
  [ -n "$(git -C "$scan_repo" ls-tree "$scan_b" -- .orchid)" ] \
    || fail "fixture: $scan_b must carry .orchid/ or its exemption is never reached"
done
[ -n "$(git -C "$scan_repo" ls-tree orchid/integration -- .orchid)" ] \
  || fail "fixture: the integration branch must carry .orchid/ -- that is the whole case"

# A subshell, so the library sourced for this one call cannot alter the suite
# that runs after it.
scan_out="$( (
  ORCHID_ROOT="$REPO_ROOT"; export ORCHID_ROOT
  source "$REPO_ROOT/lib/common.sh"
  orchid_leaked_run_state_branches "$scan_repo" orchid/integration
) )"
assert_eq "product/main" "$scan_out" \
  "only the branch outside the run is named: not the integration branch, not a live task's branch, not an archived one's"
green_case 'the integration branch carrying its own run state is never a leak'
