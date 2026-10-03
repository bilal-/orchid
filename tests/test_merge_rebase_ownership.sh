#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# RED: automatic merge rebase cannot mutate a foreign clone or a pending job's checkout.
# GREEN: an idle, registered task worktree rebases and returns to testing.
for merge_case in foreign pending pending_current malformed_current; do
merge_repo="$WORK/$merge_case/repo"; merge_wt="$WORK/$merge_case/task"; merge_foreign="$WORK/$merge_case/foreign"
mkdir -p "$merge_repo/.orchid/tasks" "$merge_repo/.orchid/reviews"
git -C "$merge_repo" init -q
git -C "$merge_repo" commit -q --allow-empty -m root
git -C "$merge_repo" checkout -q -b orchid/integration
export ORCHID_REPO="$merge_repo" HOME="$MACHINE_HOME"
printf 'integration_branch=orchid/integration\nverify=true\n' > "$merge_repo/orchid.config"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create M001 'merge rebase ownership' >/dev/null
merge_base="$(git -C "$merge_repo" rev-parse HEAD)"
git -C "$merge_repo" worktree add -q -b task/M001 "$merge_wt" "$merge_base"
printf 'task work\n' > "$merge_wt/task.txt"
git -C "$merge_wt" add task.txt
git -C "$merge_wt" commit -q -m task
merge_candidate="$(git -C "$merge_wt" rev-parse HEAD)"
"$ORCHID_BIN" task set M001 worktree "$merge_wt" >/dev/null
"$ORCHID_BIN" task set M001 base_sha "$merge_base" >/dev/null
"$ORCHID_BIN" task set M001 candidate_sha "$merge_candidate" >/dev/null
"$ORCHID_BIN" task advance M001 implementing >/dev/null
"$ORCHID_BIN" task advance M001 testing >/dev/null
"$ORCHID_BIN" verify M001 >/dev/null
"$ORCHID_BIN" task advance M001 reviewing >/dev/null
cd_scratch "$merge_repo" || exit 1
plant_reviewer_envelope M001
"$ORCHID_BIN" task advance M001 arbitrating --reason 'review fixture' >/dev/null
"$ORCHID_BIN" task arbitrate M001 --result approve --reason 'approved fixture' >/dev/null
if [ "$merge_case" = foreign ] || [ "$merge_case" = pending ]; then
  git -C "$merge_repo" commit -q --allow-empty -m sibling
fi
merge_target="$(git -C "$merge_repo" rev-parse HEAD)"
git clone -q --no-hardlinks "$merge_repo" "$merge_foreign"
git -C "$merge_foreign" checkout -q -b task/M001 "$merge_base"
printf 'foreign work\n' > "$merge_foreign/foreign.txt"
git -C "$merge_foreign" add foreign.txt
git -C "$merge_foreign" commit -q -m foreign
merge_foreign_before="$(git -C "$merge_foreign" rev-parse HEAD)"
if [ "$merge_case" = foreign ]; then
  "$ORCHID_BIN" task set M001 worktree "$merge_foreign" >/dev/null
else
  merge_job="$("$ORCHID_BIN" jobs prepare M001 implementer implement)" || { fail 'fixture: prepare pending job'; exit 1; }
  merge_job_id="$(jq -r .job_id "$merge_job")"
  if [ "$merge_case" = malformed_current ]; then
    merge_manifest="$(cat "$merge_job")"
    for bad_manifest in '{}' '' "$merge_manifest
$merge_manifest"; do
      printf '%s\n' "$bad_manifest" > "$merge_job"
      strict_rc=0
      strict_error="$("$ORCHID_BIN" jobs ls --tsv --strict 2>&1)" || strict_rc=$?
      [ "$strict_rc" -ne 0 ] || fail 'strict ownership reader refuses missing, empty, or multiple identities'
      assert_match "$merge_job_id" "$strict_error" 'strict refusal identifies the damaged manifest'
      red_case 'strict ownership reader refuses an ambiguous job identity'
    done
    printf '%s\n' "$merge_manifest" > "$merge_job"
    strict_rows="$("$ORCHID_BIN" jobs ls --tsv --strict)" || fail 'strict ownership reader accepts a prepared manifest'
    assert_match "$merge_job_id" "$strict_rows" 'strict accepting read preserves the job identity'
    green_case 'strict ownership reader accepts the same valid prepared manifest'
    cp "$merge_job" "$merge_job.saved"
    rm "$merge_job"
    ln -s "$merge_job.saved" "$merge_job"
    strict_rc=0
    strict_error="$("$ORCHID_BIN" jobs ls --tsv --strict 2>&1)" || strict_rc=$?
    [ "$strict_rc" -ne 0 ] || fail 'strict ownership reader refuses an aliased manifest'
    assert_match "$merge_job_id" "$strict_error" 'strict alias refusal identifies the manifest'
    red_case 'strict ownership reader refuses a symbolic-link job manifest'
    rm "$merge_job"
    mv "$merge_job.saved" "$merge_job"
    "$ORCHID_BIN" jobs ls --tsv --strict >/dev/null || fail 'strict ownership reader accepts the restored regular manifest'
    green_case 'strict ownership reader accepts the restored regular manifest'
    printf '{broken\n' > "$merge_job"
    "$ORCHID_BIN" jobs ls --tsv >/dev/null || fail 'ordinary jobs display keeps its tolerant inspection behavior'
  fi
fi
merge_task_before="$(cat .orchid/tasks/M001.md)"
merge_rc=0
merge_error="$("$ORCHID_BIN" merge M001 2>&1)" || merge_rc=$?
[ "$merge_rc" -ne 0 ] && [ "$merge_rc" -ne 5 ] || fail 'foreign checkout must be refused before rebase'
if [ "$merge_case" = foreign ]; then
  assert_match 'registered worktree|different repository' "$merge_error" 'automatic rebase diagnoses foreign ownership'
else
  assert_match "$merge_job_id" "$merge_error" 'automatic rebase names its outstanding job'
fi
assert_eq "$merge_foreign_before" "$(git -C "$merge_foreign" rev-parse HEAD)" 'automatic rebase preserves foreign branch'
assert_eq "$merge_candidate" "$(git -C "$merge_wt" rev-parse HEAD)" 'automatic rebase preserves owned task branch on refusal'
assert_eq "$merge_task_before" "$(cat .orchid/tasks/M001.md)" 'ownership refusal preserves task evidence fields'
assert_eq "$merge_target" "$(git -C "$merge_repo" rev-parse HEAD)" 'ownership refusal preserves integration'
red_case "automatic merge rebase refuses the $merge_case ownership condition before changing any checkout or evidence"

if [ "$merge_case" = foreign ]; then
  "$ORCHID_BIN" task set M001 worktree "$merge_wt" >/dev/null
else
  rm "$merge_job"
fi

merge_rc=0
merge_output="$("$ORCHID_BIN" merge M001 2>&1)" || merge_rc=$?
if [ "$merge_case" = pending_current ] || [ "$merge_case" = malformed_current ]; then
  assert_eq 0 "$merge_rc" 'idle checkout with current base merges'
  assert_eq 'done' "$("$ORCHID_BIN" task get M001 status)" 'accepted current-base merge completes task'
  assert_eq 'task work' "$(git -C "$merge_repo" show orchid/integration:task.txt)" 'accepted merge publishes task work'
  green_case 'current-base merge accepts the same checkout after its pending job is removed'
else
assert_eq 5 "$merge_rc" 'registered idle checkout rebases and requests re-verification'
assert_match 'rebase_rereview_required' "$merge_output" 'accepted rebase reports evidence invalidation'
assert_eq testing "$("$ORCHID_BIN" task get M001 status)" 'accepted rebase returns to testing'
assert_eq "$merge_target" "$("$ORCHID_BIN" task get M001 base_sha)" 'accepted rebase records integration head'
git -C "$merge_wt" merge-base --is-ancestor "$merge_target" HEAD || fail 'accepted task candidate descends from integration'
assert_eq 'task work' "$(cat "$merge_wt/task.txt")" 'accepted rebase preserves task work'
assert_eq "$merge_foreign_before" "$(git -C "$merge_foreign" rev-parse HEAD)" 'accepted owned rebase leaves foreign clone untouched'
green_case 'automatic merge rebase accepts an idle registered task checkout and invalidates evidence for its new candidate'
fi
done
