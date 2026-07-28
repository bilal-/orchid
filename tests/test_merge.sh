#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"

integ=orchid/integration
git branch "$integ"
echo "integration_branch=$integ" > orchid.config

export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

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
assert_eq done "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "task advances to done"
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
"$ORCHID_BIN" task advance T005 arbitrating --reason "re-reviewed after rebase, approved"
"$ORCHID_BIN" task advance T005 merging --reason "approved for merge"
rc=0; out5b="$WORK/merge5b.out"
"$ORCHID_BIN" merge T005 >"$out5b" 2>&1 || rc=$?
assert_eq 0 "$rc" "merge succeeds on the new base (recorded worktree)"
assert_eq done "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" "task reaches done (recorded worktree path)"
