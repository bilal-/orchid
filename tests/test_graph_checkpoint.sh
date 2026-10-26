#!/usr/bin/env bash
# RED: A retained checkpoint cannot reserve a slot or expose a target candidate
# before its newly required ordinary input has completed.
# GREEN: At cap1 the newly added input runs, then the checkpoint is admitted with
# an anchored active budget and its exact retained candidate can be verified.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/graph-runtime.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
export ORCHID_ENGINES_DIR="$WORK/engines"
export ORCHID_CHECKPOINT_IMPLEMENT_LOG="$WORK/implementation-jobs"
mkdir -p "$WORK/origin" "$ORCHID_ENGINES_DIR/checkpointimpl" "$ORCHID_ENGINES_DIR/checkpointreview"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf 'role.implementer=checkpointimpl\nrole.reviewer=checkpointreview\nconcurrency=1\nverify=true\n' > orchid.config
git add orchid.config
git commit -q -m 'checkpoint input fixture'
"$ORCHID_BIN" init >/dev/null || { fail 'initialize checkpoint fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'checkpoint control worktree'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
printf 'REQ-1: retain the proof artifact while checking new ordinary input.\n' > "$WORK/requirements.md"
"$ORCHID_BIN" requirements import "$WORK/requirements.md" >/dev/null || { fail 'checkpoint requirements'; exit 1; }
for engine in checkpointimpl checkpointreview; do
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq,git\nentrypoint=run\n' "$engine" > "$ORCHID_ENGINES_DIR/$engine/plugin.conf"
done
cat > "$ORCHID_ENGINES_DIR/checkpointimpl/run" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
request="$1"
job="$(jq -r .job_id "$request")"
task="$(jq -r .task "$request")"
operation="$(jq -r .operation "$request")"
worktree="$(jq -r .worktree "$request")"
output="$(jq -r .output "$request")"
if [ "$operation" = implement ]; then
  printf '%s\n' "$job" >> "$ORCHID_CHECKPOINT_IMPLEMENT_LOG"
  printf 'checkpoint artifact\n' > "$worktree/proof.txt"
  git -C "$worktree" add proof.txt
  git -C "$worktree" -c user.name='Checkpoint fixture' -c user.email=checkpoint@example.invalid commit -qm 'produce proof'
fi
candidate="$(git -C "$worktree" rev-parse HEAD)"
jq -n --arg job "$job" --arg task "$task" --arg operation "$operation" --arg candidate "$candidate" \
  '{contract:1,job_id:$job,task:$task,operation:$operation,status:"ok",candidate_sha:$candidate,summary:"checkpoint fixture"} +
   (if $operation == "implement" then {} else {verdict:"approve",scope_complete:true,findings:[]} end)' > "$output"
WORKER
cp "$ORCHID_ENGINES_DIR/checkpointimpl/run" "$ORCHID_ENGINES_DIR/checkpointreview/run"
chmod 755 "$ORCHID_ENGINES_DIR/checkpointimpl/run" "$ORCHID_ENGINES_DIR/checkpointreview/run"
/bin/bash -n "$ORCHID_ENGINES_DIR/checkpointimpl/run" "$ORCHID_ENGINES_DIR/checkpointreview/run" || { fail 'checkpoint engine syntax'; exit 1; }
"$ORCHID_BIN" task create BUILD 'retain a delivered implementation' >/dev/null || { fail 'checkpoint source'; exit 1; }
"$ORCHID_BIN" task create CHECK 'required candidate review' --archetype review >/dev/null || { fail 'checkpoint verifier'; exit 1; }
"$ORCHID_BIN" task set BUILD verification_commands 'test -f proof.txt' >/dev/null || { fail 'checkpoint mechanical command'; exit 1; }
"$ORCHID_BIN" task set BUILD output_contract '{"contract":1,"artifacts":[{"path":"proof.txt","contains":["checkpoint artifact"]}]}' >/dev/null || { fail 'checkpoint artifact contract'; exit 1; }
"$ORCHID_BIN" task set CHECK verifies BUILD >/dev/null || { fail 'checkpoint edge'; exit 1; }
"$ORCHID_BIN" graph enable --reason 'checkpoint input liveness fixture' >/dev/null || { fail 'enable checkpoint graph'; exit 1; }
"$ORCHID_BIN" plan apply --reason 'initial checkpoint plan' >/dev/null || { fail 'apply checkpoint plan'; exit 1; }
checkpoint_drive() {
  checkpoint_rc=0
  "$ORCHID_BIN" drive > "$WORK/$1.log" 2>&1 || checkpoint_rc=$?
  cat "$WORK/$1.log" >> "$WORK/driver.log"
  case "$checkpoint_rc" in
    0) ;;
    16) rg -q 'run-complete' "$WORK/$1.log" || { fail 'ordinary checkpoint dependency wait must not raise a human boundary'; cat "$WORK/$1.log"; return 1; } ;;
    *) fail "checkpoint driver refused (rc=$checkpoint_rc)"; cat "$WORK/$1.log"; return 1 ;;
  esac
}
initial_pass=0
while [ "$initial_pass" -lt 24 ]; do
  checkpoint_drive "initial-$initial_pass" || exit 1
  graph_snapshot_file "$ORCHID_REPO" "$WORK/initial.json" || { fail 'snapshot initial delivery'; exit 1; }
  if jq -e '.nodes.BUILD.status == "done" and .nodes.CHECK.status == "done"' "$WORK/initial.json" >/dev/null && [ "$(fm_get .orchid/roadmap.md run_status)" = accepting ]; then break; fi
  initial_pass=$((initial_pass+1))
  sleep 0.1
done
jq -e '.nodes.BUILD.status == "done" and .nodes.CHECK.status == "done"' "$WORK/initial.json" >/dev/null || { fail 'initial delivery must finish before replan'; tail -n 60 "$WORK/driver.log"; exit 1; }
assert_eq accepting "$(fm_get .orchid/roadmap.md run_status)" 'initial graph reached accepting without operator accept'
retained_candidate="$(jq -r .nodes.BUILD.candidate_sha "$WORK/initial.json")"
printf '{"D":{"title":"new ordinary report input","archetype":"review"},"BUILD":{"depends_on":"D"}}\n' > "$WORK/add-input.json"
"$ORCHID_BIN" graph replan --patch "$WORK/add-input.json" --reason 'require a new ordinary input before checkpoint verification' > "$WORK/replan.log" 2>&1 || { fail 'public dynamic ordinary-input replan'; cat "$WORK/replan.log"; exit 1; }
graph_snapshot_file "$ORCHID_REPO" "$WORK/reopened.json" || { fail 'snapshot retained checkpoint frontier'; exit 1; }
jq -e --arg candidate "$retained_candidate" '.nodes.D.status == "pending" and .nodes.D.candidate_sha == "" and .nodes.BUILD.status == "testing" and .nodes.CHECK.status == "reviewing" and .nodes.BUILD.candidate_sha == $candidate and .nodes.BUILD.candidate_reuse_from != null and .nodes.CHECK.candidate_reuse_from != null' "$WORK/reopened.json" >/dev/null || { fail 'replan constructs retained checkpoints and new candidate-less ordinary input'; cat "$WORK/reopened.json"; exit 1; }
assert_eq '' "$(fm_get .orchid/tasks/BUILD.md started_at)" 'retained code checkpoint begins unadmitted'
assert_eq '' "$(fm_get .orchid/tasks/CHECK.md started_at)" 'retained report checkpoint begins unadmitted'
ready_rc=0; graph_dispatch_ready "$ORCHID_REPO" CHECK "$WORK/reopened.json" > "$WORK/check-ready.log" 2>&1 || ready_rc=$?
[ "$ready_rc" -ne 0 ] || fail 'verifier must not read a retained target before its ordinary input and checkpoint admission'
red_case 'historical candidate bytes do not make an unadmitted checkpoint target ready'
premature=0; pass=0
while [ "$pass" -lt 6 ]; do
  checkpoint_drive "reopened-$pass" || exit 1
  graph_snapshot_file "$ORCHID_REPO" "$WORK/after.json" || { fail 'snapshot ordinary-input progress'; exit 1; }
  if jq -e '.nodes.D.status != "done"' "$WORK/after.json" >/dev/null; then
    for reply in .orchid/reviews/CHECK-a1-reviewer*.json; do [ ! -f "$reply" ] || premature=1; done
  fi
  pass=$((pass+1))
  sleep 0.1
done
assert_eq 0 "$premature" 'checkpoint verifier cannot file a fresh review while ordinary input is unfinished'
jq -e '.nodes.D.status == "done"' "$WORK/after.json" >/dev/null || fail 'unadmitted checkpoints must not starve the new input at cap1'
[ -n "$(fm_get .orchid/tasks/D.md started_at)" ] || fail 'new ordinary report has an anchored admission clock'
[ -n "$(fm_get .orchid/tasks/BUILD.md started_at)" ] || fail 'ready retained source receives an anchored active budget'
assert_eq "$retained_candidate" "$(jq -r .nodes.BUILD.candidate_sha "$WORK/after.json")" 'ordinary-input admission retains immutable implementation candidate'
red_case 'unadmitted checkpoint phases reserve neither capacity nor premature verifier work'
completion_pass=0
while [ "$completion_pass" -lt 18 ]; do
  checkpoint_drive "completion-$completion_pass" || exit 1
  graph_snapshot_file "$ORCHID_REPO" "$WORK/completed.json" || { fail 'snapshot completed checkpoints'; exit 1; }
  if jq -e '.nodes.BUILD.status == "done" and .nodes.CHECK.status == "done" and .nodes.D.status == "done"' "$WORK/completed.json" >/dev/null; then break; fi
  completion_pass=$((completion_pass+1))
  sleep 0.1
done
jq -e '.nodes.BUILD.status == "done" and .nodes.CHECK.status == "done" and .nodes.D.status == "done"' "$WORK/completed.json" >/dev/null || fail 'retained implementation and report checkpoints must complete after new ordinary input'
assert_eq "$retained_candidate" "$(jq -r .nodes.BUILD.candidate_sha "$WORK/completed.json")" 'already-integrated checkpoint completes without a replacement implementation candidate'
assert_eq 1 "$(wc -l < "$ORCHID_CHECKPOINT_IMPLEMENT_LOG" | tr -d ' ')" 'new ordinary input never forces a fake implementation commit'
graph_completion_ready "$ORCHID_REPO" BUILD "$WORK/completed.json" || fail 'completed retained checkpoint has current descendant verification'
if [ "$FAILS" -eq 0 ]; then
  green_case 'new ordinary input completes at cap1 before retained checkpoints receive active clocks'
else
  tail -n 100 "$WORK/driver.log"
fi
[ "$FAILS" -eq 0 ]
