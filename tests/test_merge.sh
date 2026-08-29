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
  "$ORCHID_BIN" task advance "$id" implementing
  "$ORCHID_BIN" task advance "$id" testing
  git checkout -q "$branch"
  "$ORCHID_BIN" verify "$id" >/dev/null
  git checkout -q "$integ"
  "$ORCHID_BIN" task advance "$id" reviewing
  plant_reviewer_envelope "$id"
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "single reviewer approved"
  "$ORCHID_BIN" task advance "$id" merging --reason "approved for merge"
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
"$ORCHID_BIN" task advance T005 merging --reason "approved for merge"

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
"$ORCHID_BIN" task advance T005 merging --reason "approved for merge"
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
"$ORCHID_BIN" task advance T008 merging --reason "approved for merge"
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
"$ORCHID_BIN" task advance T040 merging --reason "approved for merge"

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
"$ORCHID_BIN" task advance T040 merging --reason "approved for merge"
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
"$ORCHID_BIN" task advance T041 merging --reason "approved for merge"

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
