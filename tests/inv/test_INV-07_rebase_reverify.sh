#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# INV-07: a candidate whose SHA changed cannot merge without re-verify +
# re-review. Exercised via the stale-base rebase path of `orchid merge`:
# a parallel commit lands on integration first, forcing rebase-reverify.
#
# RED: a candidate whose SHA has moved under it -- a real parallel commit is
#      landed on integration below, so the recorded verify evidence belongs to
#      a commit that no longer exists. The merge must exit 5, the integration
#      ref must be untouched, the stale evidence must be DELETED rather than
#      reused, and the advance back to `reviewing` on the rebased candidate
#      must then be refused. Evidence that outlives the thing it attests to is
#      exactly a check that passes without having tested the candidate in hand.
# GREEN: after a real re-verify on the rebased candidate, the same merge
#      succeeds and the task reaches `done` -- so the refusal above is the
#      gate discriminating, not `merge` being broken.
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"

integ=orchid/integration
git branch "$integ"
echo "integration_branch=$integ" > orchid.config

ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create T001 "rebase-reverify demo"
git checkout -q -b task/T001 "$integ"
echo feature > feature.txt && git add feature.txt && git commit -q -m "feature work"
cand_old="$(git rev-parse HEAD)"
git checkout -q "$integ"
base_old="$(git rev-parse "$integ")"

"$ORCHID_BIN" task set T001 base_sha "$base_old"
"$ORCHID_BIN" task set T001 candidate_sha "$cand_old"
"$ORCHID_BIN" task set T001 verification_commands "test -f feature.txt"
"$ORCHID_BIN" task advance T001 implementing
"$ORCHID_BIN" task advance T001 testing

git checkout -q task/T001
"$ORCHID_BIN" verify T001 >/dev/null
git checkout -q "$integ"

"$ORCHID_BIN" task advance T001 reviewing
plant_reviewer_envelope T001
"$ORCHID_BIN" task advance T001 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task advance T001 merging --reason "approved for merge"

old_verify_log=".orchid/reviews/T001-verify.log"
old_verify_sha="$(grep '^sha: ' "$old_verify_log" | cut -d' ' -f2)"
assert_eq "$cand_old" "$old_verify_sha" "sanity: old verify evidence is against the old candidate"

# Parallel commit advances integration BEFORE this task merges.
git checkout -q "$integ"
echo other > parallel.txt && git add parallel.txt && git commit -q -m "parallel task landed first"
integ_after_parallel="$(git rev-parse "$integ")"

pre_integ="$(git rev-parse "$integ")"
rc=0; out="$WORK/merge.out"
"$ORCHID_BIN" merge T001 >"$out" 2>&1 || rc=$?
assert_eq 5 "$rc" "stale base -> merge exits 5 (rebase_rereview_required)"

post_integ="$(git rev-parse "$integ")"
assert_eq "$pre_integ" "$post_integ" "integration ref untouched by rebase-reverify"

new_status="$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)"
assert_eq testing "$new_status" "task lands back in testing after rebase"

grep -q "rebase_review" .orchid/journal.md || fail "merge exit-5 must journal a rebase_review entry (kernel.md's normative table)"
grep -q "evidence invalidated" .orchid/journal.md || fail "rebase_review entry must record that evidence was invalidated"

new_base="$("$ORCHID_BIN" task show T001 | grep '^base_sha: ' | cut -d' ' -f2)"
new_cand="$("$ORCHID_BIN" task show T001 | grep '^candidate_sha: ' | cut -d' ' -f2)"
assert_eq "$integ_after_parallel" "$new_base" "base_sha updated to the new integration HEAD"
[ "$new_cand" != "$cand_old" ] || fail "candidate_sha must change after rebase"
[ -n "$new_cand" ] || fail "candidate_sha must be set after rebase"

# Staleness must be detectable: the old verify evidence's sha no longer
# matches the task's (new) candidate_sha.
[ "$old_verify_sha" != "$new_cand" ] || fail "old review evidence must not match the new candidate (staleness undetectable)"

n_wt="$(git worktree list | wc -l | tr -d ' ')"
assert_eq 1 "$n_wt" "temp worktree removed after rebase-reverify"

# The task's branch ref itself was rebased in place onto the new integ HEAD.
branch_tip="$(git rev-parse task/T001)"
assert_eq "$new_cand" "$branch_tip" "task branch ref reflects the rebased tip"
merge_base="$(git merge-base task/T001 "$integ")"
assert_eq "$integ_after_parallel" "$merge_base" "rebased branch now sits directly on the new integration HEAD"

# INV-07 kernel enforcement: the PRE-rebase verify evidence must not survive
# the rebase-reset — otherwise its stale "exit: 0" would satisfy the INV-11
# gate and let the task reach `reviewing` without ever re-verifying the new
# candidate. Attempting the advance now, before any re-verify, must DIE.
[ ! -f "$old_verify_log" ] || fail "INV-07: stale verify evidence must not survive the rebase-reset"
[ ! -f ".orchid/reviews/T001-merge.log" ] || fail "INV-07: stale merge evidence must not survive the rebase-reset"
rc=0; err="$("$ORCHID_BIN" task advance T001 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-07: reviewing must be refused before re-verify (stale evidence gone -> INV-11 gate)"
echo "$err" | grep -qi "verify" || fail "INV-07: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "INV-07: refused advance leaves status at testing"

# --- Walk the rebased candidate through verify + review again; merge must
# now succeed on the new base (that's the point of INV-07: re-verify is
# mandatory, not optional, before the second merge attempt can proceed).
git checkout -q task/T001
rc=0; "$ORCHID_BIN" verify T001 >/dev/null || rc=$?
assert_eq 0 "$rc" "re-verify passes on the rebased candidate"
git checkout -q "$integ"

"$ORCHID_BIN" task advance T001 reviewing
plant_reviewer_envelope T001
"$ORCHID_BIN" task advance T001 arbitrating --reason "re-reviewed after rebase, approved"
"$ORCHID_BIN" task advance T001 merging --reason "approved for merge"

rc=0; out2="$WORK/merge2.out"
"$ORCHID_BIN" merge T001 >"$out2" 2>&1 || rc=$?
assert_eq 0 "$rc" "merge succeeds on the new base"
assert_match "^merged T001: $integ -> " "$(cat "$out2")" "prints merged message on second attempt"
assert_eq "done" "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "task reaches done"
red_case "a moved candidate SHA made merge exit 5, destroyed the stale verify evidence and blocked re-entry to reviewing until a real re-verify ran"
green_case "after a real re-verify on the rebased candidate the SAME merge succeeded and the task reached done, so the refusal above is a re-verify requirement rather than a merge that refuses every rebased candidate"

final_integ="$(git rev-parse "$integ")"
git show "$final_integ:feature.txt" >/dev/null 2>&1 || fail "final integ contains the (rebased) feature commit"
git show "$final_integ:parallel.txt" >/dev/null 2>&1 || fail "final integ still contains the parallel commit"
