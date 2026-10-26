#!/usr/bin/env bash
# RED: Stale graph context, forged kernel fields, unsafe workspaces, and broken
# output contracts cannot become successful current graph evidence.
# GREEN: Real fake-worker launches bind immutable context and preserve legacy
# failure diagnostics while distinguishing source defects from worker faults.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/graph-runtime.sh"
source "$REPO_ROOT/lib/pack.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
export ORCHID_ENGINES_DIR="$WORK/engines" ORCHID_GRAPH_CAPTURE_DIR="$WORK/captured"
mkdir -p "$WORK/origin" "$ORCHID_ENGINES_DIR/fake" "$ORCHID_ENGINES_DIR/fakehook" "$ORCHID_GRAPH_CAPTURE_DIR"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf '{"ok":true}\n' > good.json
printf '{"ok":false}\n' > bad.json
printf 'verify=true\nconcurrency=8\nengine_fail_threshold=99\nrole.implementer=fake\nrole.reviewer=fake\nhook.before_merge=fakehook\n' > orchid.config
git add good.json bad.json orchid.config
git commit -q -m 'graph job baseline'
"$ORCHID_BIN" init >/dev/null || { fail 'initialize graph job fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'create graph control worktree'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
printf 'Graph job requirements\n' > "$WORK/requirements.md"
"$ORCHID_BIN" requirements import "$WORK/requirements.md" >/dev/null || { fail 'import fixture requirements'; exit 1; }

printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq,git\nentrypoint=run\n' > "$ORCHID_ENGINES_DIR/fake/plugin.conf"
printf 'manifest_version=1\nid=test/fakehook\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' > "$ORCHID_ENGINES_DIR/fakehook/plugin.conf"
cat > "$ORCHID_ENGINES_DIR/fake/run" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
req="$1"
job="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"; out="$(jq -r .output "$req")"
wt="$(jq -r .worktree "$req")"; pack="$(jq -r .input_pack "$req")"
mode="${ORCHID_GRAPH_FAKE_MODE:-good}"
[ -f "$pack/delivery-context.json" ] || exit 91
cp "$req" "$ORCHID_GRAPH_CAPTURE_DIR/$job.request.json"
cp "$pack/delivery-context.json" "$ORCHID_GRAPH_CAPTURE_DIR/$job.context.json"
cp "$pack/pack.json" "$ORCHID_GRAPH_CAPTURE_DIR/$job.pack.json"
cand="$(jq -r '.candidate_sha // ""' "$req")"
if [ "$op" = implement ]; then
  if [ "$mode" = absent ]; then printf 'other committed work\n' > "$wt/work.txt"; git -C "$wt" add work.txt
  else
    if [ "$mode" = badartifact ]; then printf '{"ok":false}\n' > "$wt/result.json"; else printf '{"ok":true}\n' > "$wt/result.json"; fi
    if [ "$mode" != uncommitted ]; then git -C "$wt" add result.json; fi
  fi
  if [ "$mode" != uncommitted ]; then
    if ! git -C "$wt" diff --cached --quiet; then
      git -C "$wt" -c user.name='Graph Worker' -c user.email=graph@example.invalid commit -qm 'worker output'
    fi
  fi
  cand="$(git -C "$wt" rev-parse HEAD)"
  if [ "$mode" = wrongcandidate ]; then cand="$(jq -r .base_sha "$req")"; fi
fi
jq -n --arg job "$job" --arg task "$task" --arg op "$op" --arg cand "$cand" --arg mode "$mode" '
  {contract:1,job_id:$job,task:$task,operation:$op,status:"ok",summary:"worker complete"} +
  (if $cand == "" then {} else {candidate_sha:$cand} end) +
  (if $op == "implement" then {commits:[$cand]}
   elif $op == "hook" then {artifact:{note:"hook guidance"}}
   else {verdict:"approve",scope_complete:($mode != "artifactreview")} end) |
  if $mode == "rightsummary" then .summary="required worker wording"
  elif $mode == "failed" then .status="failed" | .summary="original worker failure"
  elif $mode == "forgecontext" then .run_context={id:"wrong-run"}
  elif $mode == "forgekernel" then .output_contract_evidence={passed:true}
  else . end
' > "$out"
WORKER
cp "$ORCHID_ENGINES_DIR/fake/run" "$ORCHID_ENGINES_DIR/fakehook/run"
chmod 755 "$ORCHID_ENGINES_DIR/fake/run" "$ORCHID_ENGINES_DIR/fakehook/run"

for id in C D A P K I W J; do
  "$ORCHID_BIN" task create "$id" "$id code" >/dev/null || { fail 'create code fixture node'; exit 1; }
done
for id in V R E F S T U B Q Z; do
  "$ORCHID_BIN" task create "$id" "$id check" --archetype review >/dev/null || { fail 'create report fixture node'; exit 1; }
done
code_contract='{"contract":1,"artifacts":[{"path":"result.json","schema":{"type":"object","required":["ok"],"properties":{"ok":{"const":true}}}}]}'
for id in C D A P K; do
  "$ORCHID_BIN" task set "$id" output_contract "$code_contract" >/dev/null || { fail 'set initial code contract'; exit 1; }
done
"$ORCHID_BIN" task set V verifies C >/dev/null
"$ORCHID_BIN" task set V output_contract "$code_contract" >/dev/null
"$ORCHID_BIN" task set R output_contract '{"contract":1,"artifacts":[{"path":"bad.json","schema":{"properties":{"ok":{"const":true}}}}]}' >/dev/null
"$ORCHID_BIN" task set E output_contract '{"contract":1,"envelope_schema":{"properties":{"summary":{"const":"required worker wording"}}}}' >/dev/null
"$ORCHID_BIN" task set I output_contract '{"contract":1,"envelope_schema":{"properties":{"summary":{"const":"required worker wording"}}},"artifacts":[{"path":"result.json"}]}' >/dev/null
"$ORCHID_BIN" task set F output_contract '{"contract":1,"artifacts":[{"path":"missing.json"}]}' >/dev/null
# Initial graph marker is fixture construction, not a live adoption operation.
fm_set .orchid/roadmap.md graph_contract 1
"$ORCHID_BIN" run advance running --reason fixture >/dev/null || { fail 'start graph fixture'; exit 1; }

materialize_code() {
  local id="$1" base path
  base="$(git rev-parse orchid/integration)"; path="$WORK/code-$id"
  git worktree add -q -b "task/$id" "$path" "$base" || return 1
  "$ORCHID_BIN" task set "$id" worktree "$path" >/dev/null || return 1
  "$ORCHID_BIN" task set "$id" base_sha "$base" >/dev/null || return 1
  "$ORCHID_BIN" task advance "$id" implementing >/dev/null
}
materialize_report() {
  "$REPO_ROOT/runners/orchid-graph-prepare" "$1" >/dev/null || return 1
  "$ORCHID_BIN" task advance "$1" reviewing >/dev/null
}
launch_job() {
  local id="$1" role="$2" op="$3" mode="$4" text n
  shift 4
  export ORCHID_GRAPH_FAKE_MODE="$mode"
  text="$("$REPO_ROOT/runners/orchid-launch" "$id" "$role" "$op" "$@")" || { fail "launch $id/$op"; return 1; }
  graph_jid="$(printf '%s\n' "$text" | awk '$1=="launched"{print $2}')"
  [ -n "$graph_jid" ] || { fail "launch $id records identity"; return 1; }
  for ((n=0; n<200; n++)); do
    [ ! -f ".orchid/runtime/exits/$graph_jid" ] || break
    sleep 0.025
  done
  [ -f ".orchid/runtime/exits/$graph_jid" ] || { fail "$id fake worker exits"; return 1; }
  assert_eq 0 "$(cat ".orchid/runtime/exits/$graph_jid")" "$id fake worker consumed trusted request and pack"
}
reply_file() {
  local file
  for file in .orchid/reviews/*.json; do
    [ -f "$file" ] || continue
    if jq -e --arg id "$1" '.job_id==$id' "$file" >/dev/null; then printf '%s\n' "$file"; return 0; fi
  done
  return 1
}
reconcile_job() {
  "$ORCHID_BIN" jobs reconcile >/dev/null || { fail 'reconcile graph fake worker'; return 1; }
  graph_reply="$(reply_file "$graph_jid")" || { fail "reply for $graph_jid filed"; return 1; }
}
ledger_snapshot() { if [ -f .orchid/runtime/engines.json ]; then cat .orchid/runtime/engines.json; else printf absent; fi; }

materialize_code C || { fail 'prepare code producer'; exit 1; }
launch_job C implementer implement good --engine fake || exit 1
reconcile_job || exit 1
jq -e '.status=="ok" and .graph_contract==1 and .run_context.id!="" and .output_contract.operations==["implement"] and .output_contract_evidence.passed and .output_contract_evidence.applicable and .output_contract_evidence.scope=="full"' "$graph_reply" >/dev/null || fail 'producer passes bound effective contract'
produced="$(git -C "$WORK/code-C" rev-parse HEAD)"
assert_eq "$produced" "$(jq -r .candidate_sha "$graph_reply")" 'produced identity comes from owned checkout'
jq -e '.graph_contract==1 and .output_contract.operations==["implement"] and .worktree!=""' "$ORCHID_GRAPH_CAPTURE_DIR/$graph_jid.request.json" >/dev/null || fail 'request carries graph contract and own workspace'
jq -e '.run_context.id!="" and .contract_terms.output_contract!=null' "$ORCHID_GRAPH_CAPTURE_DIR/$graph_jid.context.json" >/dev/null || fail 'pack carries immutable run and contract context'
jq -e 'any(.items[]; .name=="delivery-context.json" and .truncated==false) and .total_bytes<=.budget' "$ORCHID_GRAPH_CAPTURE_DIR/$graph_jid.pack.json" >/dev/null || fail 'mandatory delivery context is budgeted without truncation'
"$ORCHID_BIN" task set C candidate_sha "$produced" >/dev/null
# This fixture isolates jobs/launch; parent lifecycle/checkpoint gates have their own suites.
fm_set .orchid/tasks/C.md status testing
materialize_report V || { fail 'prepare bound verifier'; exit 1; }
launch_job V reviewer review good --engine fake || exit 1
reconcile_job || exit 1
jq -e --arg produced "$produced" '.status=="ok" and .verification_target.task=="C" and .verification_target.candidate_sha==$produced and .output_contract.operations==["review"] and .output_contract_evidence.passed' "$graph_reply" >/dev/null || fail 'independent verifier receives and returns current target-bound evidence'
assert_eq "$produced" "$(git -C "$(fm_get .orchid/tasks/V.md worktree)" rev-parse HEAD)" 'verifier uses its own frozen candidate checkout'
fm_set .orchid/tasks/V.md status 'done'
fm_set .orchid/tasks/C.md status 'done'
green_case 'actual producer and independent verifier launches consume trusted graph request/pack and file current contract evidence'

for id in D A P K; do
  materialize_code "$id" || { fail "prepare bad output fixture $id"; exit 1; }
  before_ledger="$(ledger_snapshot)"
  case "$id" in D) mode=badartifact ;; A) mode=absent ;; P) mode=uncommitted ;; K) mode=wrongcandidate ;; esac
  launch_job "$id" implementer implement "$mode" --engine fake || exit 1
  reconcile_job || exit 1
  jq -e '.status=="failed" and .contract_failure.passed==false and .contract_failure.reported_status=="ok"' "$graph_reply" >/dev/null || fail "$id output cannot become successful source evidence"
  if [ "$id" = K ]; then
    assert_eq candidate "$(jq -r .contract_failure.kind "$graph_reply")" 'wrong worker candidate is an identity refusal'
  else
    assert_eq artifact "$(jq -r .contract_failure.kind "$graph_reply")" 'bad/missing/uncommitted output is a committed-artifact constraint failure'
  fi
  assert_eq "$before_ledger" "$(ledger_snapshot)" 'kernel source/candidate constraint does not charge engine health'
  fm_set ".orchid/tasks/$id.md" status blocked
done
red_case 'invalid, absent, uncommitted artifacts and forged produced commit claims file classified nonapproval without engine fault'

materialize_report R || { fail 'prepare source-artifact report'; exit 1; }
before_ledger="$(ledger_snapshot)"
launch_job R reviewer review artifactreview --engine fake || exit 1
reconcile_job || exit 1
jq -e '.status=="ok" and .verdict=="request-changes" and .scope_complete==false and .contract_failure.kind=="artifact" and .contract_failure.reported_verdict=="approve" and any(.findings[]; .severity=="high" and .source=="kernel")' "$graph_reply" >/dev/null || fail 'kernel artifact counterexample blocks without inventing model scope completeness'
assert_eq "$before_ledger" "$(ledger_snapshot)" 'review artifact constraint does not charge engine health'
fm_set .orchid/tasks/R.md status blocked
materialize_report E || { fail 'prepare malformed-output report'; exit 1; }
launch_job E reviewer review good --engine fake || exit 1
reconcile_job || exit 1
jq -e '.status=="failed" and .contract_failure.kind=="envelope" and .contract_failure.reported_verdict=="approve"' "$graph_reply" >/dev/null || fail 'bad worker output schema becomes retryable worker diagnostic'
jq -e '.fake.consecutive_failures>=1' .orchid/runtime/engines.json >/dev/null || fail 'worker output failure records an engine failure'
fm_set .orchid/tasks/E.md status blocked
red_case 'report source-artifact violation is a blocking finding while reply-schema violation is a worker failure'

materialize_report F || { fail 'prepare failure-diagnostic report'; exit 1; }
launch_job F reviewer review failed --engine fake || exit 1
reconcile_job || exit 1
jq -e '.status=="failed" and .summary=="original worker failure" and (has("contract_failure")|not) and .output_contract_evidence.applicable==false' "$graph_reply" >/dev/null || fail 'generic failed reply keeps original diagnostics and does not enforce source artifacts'
fm_set .orchid/tasks/F.md status blocked
fm_set .orchid/tasks/C.md status merging
launch_job C hook hook good --hook before_merge || exit 1
reconcile_job || exit 1
jq -e '.status=="ok" and .output_contract.operations==["implement"] and .output_contract_evidence.applicable==false and (has("contract_failure")|not)' "$graph_reply" >/dev/null || fail 'code primary output contract does not apply accidentally to its own hook'
green_case 'failed diagnostics remain intact and contextual default operation keeps code hooks nonapplicable'
fm_set .orchid/tasks/C.md status 'done'

materialize_code I || { fail 'prepare same-generation worker retry'; exit 1; }
launch_job I implementer implement good --engine fake || exit 1
reconcile_job || exit 1
jq -e '.status=="failed" and .contract_failure.kind=="envelope"' "$graph_reply" >/dev/null || fail 'first implementation committed before malformed reply'
retry_head="$(git -C "$WORK/code-I" rev-parse HEAD)"
assert_eq '' "$(fm_get .orchid/tasks/I.md candidate_sha)" 'malformed worker reply did not stamp task candidate'
launch_job I implementer implement rightsummary --engine fake || exit 1
reconcile_job || exit 1
jq -e --arg head "$retry_head" '.status=="ok" and .start_head_sha==$head and .candidate_sha==$head and .execution_generation==1' "$graph_reply" >/dev/null || fail 'same-generation retry starts from actual owned progress and accepts a fresh valid reply'
fm_set .orchid/tasks/I.md status blocked
green_case 'malformed implementation replies can retry the same generation from retained clean committed progress'

materialize_report Z || { fail 'prepare forged-reply report'; exit 1; }
for mode in forgecontext forgekernel; do
  launch_job Z reviewer review "$mode" --engine fake || exit 1
  out="$("$ORCHID_BIN" jobs reconcile)" || fail 'quarantine forged graph claim'
  assert_match 'graph-mismatch' "$out" 'worker cannot forge binding or kernel-only evidence'
  if reply_file "$graph_jid" >/dev/null; then fail 'forged graph reply never filed as evidence'; fi
done
fm_set .orchid/tasks/Z.md status blocked
red_case 'conflicting graph selfclaims and worker-authored kernel evidence are quarantined'

for id in S T U; do
  materialize_report "$id" || { fail "prepare stale-context report $id"; exit 1; }
  launch_job "$id" reviewer review good --engine fake || exit 1
  case "$id" in
    S) cp .orchid/requirements.md "$WORK/requirements.saved"; printf 'changed requirements\n' >> .orchid/requirements.md ;;
    T) fm_set .orchid/roadmap.md graph_contract '' ;;
    U) mf=".orchid/runtime/jobs/$graph_jid.json"; jq 'del(.graph_contract,.run_context)' "$mf" > "$WORK/missing-context.json"; mv "$WORK/missing-context.json" "$mf" ;;
  esac
  out="$("$ORCHID_BIN" jobs reconcile)" || fail 'quarantine stale context'
  assert_match 'obsolete-revision' "$out" 'same-candidate reply requires current graph/run context'
  if reply_file "$graph_jid" >/dev/null; then fail 'stale graph reply never filed'; fi
  case "$id" in S) cp "$WORK/requirements.saved" .orchid/requirements.md ;; T) fm_set .orchid/roadmap.md graph_contract 1 ;; esac
  touch -t 202001010000 ".orchid/runtime/jobs/$graph_jid.json"
  "$ORCHID_BIN" jobs gc --older-than-s 0 --prepared-older-than-s 0 >/dev/null
  fm_set ".orchid/tasks/$id.md" status blocked
done
red_case 'same-SHA requirement changes, mode-off graph jobs, and graph-mode contextless manifests cannot reconcile'

fm_set .orchid/tasks/Q.md status reviewing
rc=0; "$ORCHID_BIN" jobs prepare Q reviewer review --engine fake > "$WORK/no-checkout.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'graph report cannot use repository-root fallback'
fm_set .orchid/tasks/Q.md status blocked
materialize_report B || { fail 'prepare wrong-HEAD report'; exit 1; }
wrong_wt="$(fm_get .orchid/tasks/B.md worktree)"
printf 'wrong report checkout head\n' > "$wrong_wt/unexpected.txt"
git -C "$wrong_wt" add unexpected.txt
git -C "$wrong_wt" commit -q -m 'wrong report head'
rc=0; "$ORCHID_BIN" jobs prepare B reviewer review --engine fake > "$WORK/wrong-head.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'report checkout HEAD must remain its frozen candidate'
fm_set .orchid/tasks/B.md status blocked
fm_set .orchid/tasks/W.md status implementing
rc=0; "$ORCHID_BIN" jobs prepare W implementer implement --engine fake > "$WORK/no-code-checkout.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'graph implementer cannot write repository-root fallback'
red_case 'graph jobs refuse missing own checkouts and a report checkout moved off its bound candidate'
green_case 'earlier current owned producer/verifier workspaces pass the same runtime admission'

# Ignore exactly the current prepared implementation job at launch; another
# outstanding job must still block. The second runtime record is fault injection.
materialize_code J || { fail 'prepare own-job ignore case'; exit 1; }
prepared="$("$ORCHID_BIN" jobs prepare J implementer implement --engine fake)" || { fail 'prepare current implementation manifest'; exit 1; }
prepared_jid="$(jq -r .job_id "$prepared")"
graph_snapshot_file "$ORCHID_REPO" "$WORK/ignore-snapshot.json" || { fail 'snapshot own-job ignore case'; exit 1; }
graph_job_prepare_gate "$ORCHID_REPO" J "$WORK/ignore-snapshot.json" implement '' "$prepared_jid" || fail 'launch may ignore its own exact prepared implementation job'
other_jid="$(orchid_job_id_reserve "$ORCHID_REPO" "j-e${ORCHID_EPOCH}-J-a1")" || { fail 'reserve other prepared fixture identity'; exit 1; }
other_manifest=".orchid/runtime/jobs/$other_jid.json"
jq --arg job "$other_jid" --arg log "$ORCHID_REPO/.orchid/runtime/logs/$other_jid.log" --arg output "$ORCHID_REPO/.orchid/runtime/spool/$other_jid.json" \
  '.job_id=$job | .log=$log | .output=$output' "$prepared" | atomic_write "$other_manifest"
rc=0; out="$(graph_job_prepare_gate "$ORCHID_REPO" J "$WORK/ignore-snapshot.json" implement '' "$prepared_jid" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'ignoring current launch job cannot ignore another prepared job'
assert_match "$other_jid" "$out" 'the other outstanding identity is named'
rm "$other_manifest"
graph_job_prepare_gate "$ORCHID_REPO" J "$WORK/ignore-snapshot.json" implement '' "$prepared_jid" || fail 'same launch gate passes when other work retires'
touch -t 202001010000 "$prepared"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 --prepared-older-than-s 0 >/dev/null
fm_set .orchid/tasks/J.md status blocked
red_case 'launch ignores only its own prepared implementation identity, never another outstanding job'
green_case 'the same launch admission passes after the other prepared job is retired'

# Mutable repair instructions are conveyed without becoming semantic authority.
graph_job_binding "$ORCHID_REPO" V "$WORK/repair-binding.json" || { fail 'bind repair instruction fixture'; exit 1; }
cp "$WORK/repair-binding.json" "$WORK/repair-binding.original"
fm_set .orchid/tasks/C.md repair_obligation '{"contract":1,"source":{"task":"C"},"round":1}'
fm_set .orchid/tasks/V.md repair_obligation '{"contract":1,"source":{"task":"V"},"round":1}'
pack_build "$ORCHID_REPO" V review "$WORK/repair-pack" '' "$WORK/repair-binding.json" || fail 'pack nested repair instructions'
jq -e '.repair_obligation.source.task=="V" and .target_repair_obligation.source.task=="C"' "$WORK/repair-pack/delivery-context.json" >/dev/null || fail 'own and target repair obligations are both conveyed'
fm_set .orchid/tasks/V.md repair_obligation ''
pack_build "$ORCHID_REPO" V review "$WORK/parent-repair-pack" '' "$WORK/repair-binding.json" || fail 'pack parent repair instructions'
jq -e '.repair_obligation.source.task=="C" and .target_repair_obligation.source.task=="C"' "$WORK/parent-repair-pack/delivery-context.json" >/dev/null || fail 'replacement verifier receives parent obligation when it has none of its own'
fm_set .orchid/tasks/C.md repair_obligation ''
pack_build "$ORCHID_REPO" V review "$WORK/cleared-repair-pack" '' "$WORK/repair-binding.json" || fail 'pack cleared repair instructions'
jq -e '(has("repair_obligation")|not) and (has("target_repair_obligation")|not)' "$WORK/cleared-repair-pack/delivery-context.json" >/dev/null || fail 'answered instruction is no longer supplied'
cmp "$WORK/repair-binding.original" "$WORK/repair-binding.json" || fail 'instruction delivery does not alter the semantic binding'
green_case 'nested own/target repair instructions are trusted pack context and can clear without changing evidence bindings'

cp orchid.config "$WORK/config.saved"
printf 'pack_budget_bytes=1\n' >> orchid.config
rc=0; pack_build "$ORCHID_REPO" V review "$WORK/overflow-pack" '' "$WORK/repair-binding.json" > "$WORK/overflow.log" 2>&1 || rc=$?
assert_eq 12 "$rc" 'mandatory graph context cannot be silently truncated to fit'
cp "$WORK/config.saved" orchid.config
pack_build "$ORCHID_REPO" V review "$WORK/fitting-pack" '' "$WORK/repair-binding.json" || fail 'same complete graph context fits restored budget'
red_case 'graph context that exceeds the pack budget refuses instead of dropping contract terms'
green_case 'the complete mandatory context passes when sufficient budget is restored'

[ "$FAILS" -eq 0 ]
