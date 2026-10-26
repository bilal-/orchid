#!/usr/bin/env bash
# RED: Concurrent retained checkpoints cannot both claim a cap1 slot; malformed
# lineage or an unanchored verification attempt cannot bypass admission.
# GREEN: The single winner retains its exact admission clock across a resumed
# prepare and owns the canonical immutable checkout for that generation.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/graph-runtime.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf 'concurrency=1\nverify=true\nverb_lock_wait_s=60\n' > orchid.config
git add orchid.config
git commit -q -m 'atomic checkpoint admission fixture'
"$ORCHID_BIN" init >/dev/null || { fail 'initialize admission fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'admission control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
for id in P Q; do
  "$ORCHID_BIN" task create "$id" "$id retained checkpoint" >/dev/null || { fail 'create checkpoint'; exit 1; }
  "$ORCHID_BIN" task set "$id" verification_commands true >/dev/null || { fail 'configure checkpoint'; exit 1; }
done
"$ORCHID_BIN" graph enable --reason 'admission race fixture' >/dev/null || { fail 'enable admission fixture'; exit 1; }
"$ORCHID_BIN" plan apply --reason 'admission fixture plan' >/dev/null || { fail 'apply admission fixture'; exit 1; }
candidate="$(git rev-parse orchid/integration)"
# Internal fixture construction models two independently retained frontiers.
# Admission/setup/binding themselves use the public tier2 runner and its lock.
for id in P Q; do
  fm_set ".orchid/tasks/$id.md" status testing
  fm_set ".orchid/tasks/$id.md" contract_revision 2
  fm_set ".orchid/tasks/$id.md" execution_generation 2
  fm_set ".orchid/tasks/$id.md" branch "task/$id-g2"
  fm_set ".orchid/tasks/$id.md" base_sha "$candidate"
  fm_set ".orchid/tasks/$id.md" candidate_sha "$candidate"
  fm_set ".orchid/tasks/$id.md" candidate_reuse_from "{\"base_sha\":\"$candidate\",\"candidate_sha\":\"$candidate\",\"source_generation\":1,\"source_contract_revision\":1,\"implementer_engine_id\":\"\",\"source_archive\":\".orchid/revisions/$id-g1\"}"
done
graph_snapshot_file "$ORCHID_REPO" "$WORK/before.json" || { fail 'snapshot two pending checkpoints'; exit 1; }
graph_checkpoint_pending "$ORCHID_REPO" P "$WORK/before.json" || fail 'P starts unadmitted'
graph_checkpoint_pending "$ORCHID_REPO" Q "$WORK/before.json" || fail 'Q starts unadmitted'
rc=0; graph_job_prepare_gate "$ORCHID_REPO" P "$WORK/before.json" verify > "$WORK/not-admitted.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'verification cannot start before admission'
assert_match 'not admitted' "$(cat "$WORK/not-admitted.log")" 'admission is checked before workspace use'
"$ORCHID_BIN" graph prepare P --operation verify > "$WORK/P.log" 2>&1 & p_pid=$!
"$ORCHID_BIN" graph prepare Q --operation verify > "$WORK/Q.log" 2>&1 & q_pid=$!
p_rc=0; wait "$p_pid" || p_rc=$?
q_rc=0; wait "$q_pid" || q_rc=$?
if [ "$p_rc" -eq 0 ] && [ "$q_rc" -ne 0 ]; then
  winner=P; loser=Q
elif [ "$q_rc" -eq 0 ] && [ "$p_rc" -ne 0 ]; then
  winner=Q; loser=P
else
  fail "exactly one concurrent checkpoint must acquire cap1 (P=$p_rc, Q=$q_rc)"
  cat "$WORK/P.log" "$WORK/Q.log"
  exit 1
fi
if ! rg -q 'concurrency-cap' "$WORK/$loser.log"; then fail 'loser is refused by canonical capacity owner'; cat "$WORK/$loser.log"; fi
assert_eq '' "$(fm_get ".orchid/tasks/$loser.md" started_at)" 'loser never receives an active budget'
assert_eq '' "$(fm_get ".orchid/tasks/$loser.md" worktree)" 'loser performs no checkout setup or binding'
anchor="$(fm_get ".orchid/tasks/$winner.md" started_at)"
[ -n "$anchor" ] || fail 'winner records its admission clock'
graph_snapshot_file "$ORCHID_REPO" "$WORK/admitted.json" || fail 'snapshot admitted winner'
if graph_checkpoint_pending "$ORCHID_REPO" "$winner" "$WORK/admitted.json"; then fail 'winner is no longer unreserved'; fi
graph_checkpoint_pending "$ORCHID_REPO" "$loser" "$WORK/admitted.json" || fail 'loser remains pending admission'
sleep 1
"$ORCHID_BIN" graph prepare "$winner" --operation verify > "$WORK/resume.log" 2>&1 || { fail 'resume same admitted checkpoint'; cat "$WORK/resume.log"; exit 1; }
assert_eq "$anchor" "$(fm_get ".orchid/tasks/$winner.md" started_at)" 'resume never refreshes the active budget clock'
graph_job_prepare_gate "$ORCHID_REPO" "$winner" "" verify || fail 'admitted idle checkpoint can verify'
red_case 'unadmitted work and the losing concurrent checkpoint cannot acquire a reserved slot'
green_case 'one admission owns cap1 and resumes the same canonical candidate with the original clock'
lineage="$(fm_get ".orchid/tasks/$loser.md" candidate_reuse_from)"
bad_lineage="$(printf '%s' "$lineage" | jq -c '.source_generation=2')"
fm_set ".orchid/tasks/$loser.md" candidate_reuse_from "$bad_lineage"
rc=0; graph_dispatch_ready "$ORCHID_REPO" "$loser" > "$WORK/bad-lineage.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'invalid retained lineage cannot become dispatchable'
assert_eq '' "$(fm_get ".orchid/tasks/$loser.md" started_at)" 'invalid lineage cannot manufacture admission'
fm_set ".orchid/tasks/$loser.md" candidate_reuse_from "$lineage"
graph_checkpoint_pending "$ORCHID_REPO" "$loser" || fail 'restored valid lineage is still an unadmitted checkpoint'
red_case 'same-generation historical lineage fails before admission'
green_case 'valid historical lineage preserves a pending checkpoint without inventing a clock'
[ "$FAILS" -eq 0 ]
