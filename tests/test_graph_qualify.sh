#!/usr/bin/env bash
# RED: Dry-run ambiguity, self-review, fabricated output, or an unproved hidden
# read must not yield a live qualification receipt.
# GREEN: Real fake-adapter execution proves fresh inputs and bounded graph roles.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
qualify_test_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then FAILS=$((FAILS+1)); fi
  if [ "$FAILS" -gt 0 ]; then
    printf 'qualification test evidence retained: %s\n' "$WORK" >&2
  else _scratch_cleanup; fi
  _proof_case_summary; _not_tested_summary
  exit "$((FAILS>0))"
}
trap qualify_test_exit EXIT
export HOME="$MACHINE_HOME"
mkdir -p "$WORK/kernel/scripts" "$WORK/engines/qimpl" "$WORK/engines/qreview" "$WORK/bin"
# Freeze the executable payload: concurrent development of the checkout cannot
# make a fixture qualify mixed source versions or silently relax source hashes.
for path in "${ORCHID_KERNEL_PATHS[@]}"; do cp -R "$REPO_ROOT/$path" "$WORK/kernel/$path" || { fail 'copy qualification kernel fixture'; exit 1; }; done
cp "$REPO_ROOT/scripts/graph-qualify.sh" "$WORK/kernel/scripts/graph-qualify.sh" || { fail 'copy qualification entrypoint'; exit 1; }
QUALIFY="$WORK/kernel/scripts/graph-qualify.sh"
# Frozen test-only instrumentation keeps private failure diagnostics for review.
sed 's@if \[ "$Q_KEEP" -eq 0 \]; then rm -rf "$Q_WORK"; fi@if [ "$overall" != pass ]; then cp "$Q_WORK/private.log" "$Q_OUTPUT.private.log" 2>/dev/null || true; fi; if [ "$Q_KEEP" -eq 0 ]; then rm -rf "$Q_WORK"; fi@' "$QUALIFY" > "$QUALIFY.next" || { fail 'instrument private fixture diagnostics'; exit 1; }
mv "$QUALIFY.next" "$QUALIFY"
export ORCHID_ENGINES_DIR="$WORK/engines" ORCHID_QUALIFY_COUNTER="$WORK/calls"
PATH="$WORK/bin:$PATH"; export PATH
for name in fake-impl-cli fake-review-cli; do
  printf '#!/usr/bin/env bash\nprintf "qualification-cli 1.2.3\\n"\n' > "$WORK/bin/$name"
  chmod 755 "$WORK/bin/$name"
done
printf 'manifest_version=1\nid=test/qimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=fake-impl-cli,jq\nentrypoint=run\n' > "$WORK/engines/qimpl/plugin.conf"
printf 'manifest_version=1\nid=test/qreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,git\nrequires_binaries=fake-review-cli,jq\nentrypoint=run\n' > "$WORK/engines/qreview/plugin.conf"
cat > "$WORK/engines/qimpl/run" <<'ADAPTER'
#!/usr/bin/env bash
set -euo pipefail
req="$1"; here="$(cd "$(dirname "$0")" && pwd)"
mode="$(cat "$here/mode")"
if [ "$mode" = hang ]; then
  /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; while :; do sleep 1; done' _ "$here/hanging.pid" &
  wait
  exit 1
fi
engine="test/$(basename "$here")"
job="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"; op="$(jq -r .operation "$req")"
wt="$(jq -r .worktree "$req")"; out="$(jq -r .output "$req")"; cand="$(jq -r '.candidate_sha // ""' "$req")"
printf '%s\t%s\n' "$task" "$op" >> "$here/../../calls"
if [ "$op" = implement ]; then
  if [ "$mode" = hardcoded ]; then
    printf '#!/bin/bash\nprintf '\''{"nonce":"hardcoded","sum":42}\\n'\''\n' > "$wt/solve.sh"
  else
    printf '#!/bin/bash\njq -c '\''{nonce:.nonce,sum:(.a+.b)}'\'' "$1"\n' > "$wt/solve.sh"
  fi
  cp "$wt/.probe-token" "$wt/read-token.txt"
  git -C "$wt" add solve.sh read-token.txt
  git -C "$wt" -c user.name='Qualification fixture' -c user.email=fixture@example.invalid commit -qm 'generated fixture program'
  cand="$(git -C "$wt" rev-parse HEAD)"
  jq -n --arg engine "$engine" --arg job "$job" --arg task "$task" --arg cand "$cand" '{contract:1,engine:$engine,job_id:$job,task:$task,operation:"implement",status:"ok",summary:"fixture program generated",commits:[$cand],candidate_sha:$cand}' > "$out"
else
  token="$(cat "$wt/.review-token")"
  if [ "$mode" = no-read ]; then token=not-read; fi
  jq -n --arg engine "$engine" --arg job "$job" --arg task "$task" --arg cand "$cand" --arg token "$token" '
    {contract:1,engine:$engine,job_id:$job,task:$task,operation:"review",status:"ok",scope_complete:true,candidate_sha:$cand,summary:("read:"+$token)} +
    (if $task == "R" then {verdict:"request-changes",findings:[{severity:"high",title:"addition implemented as subtraction"}]}
     else {verdict:"approve",findings:[]} end)' > "$out"
fi
ADAPTER
cp "$WORK/engines/qimpl/run" "$WORK/engines/qreview/run"
chmod 755 "$WORK/engines/qimpl/run" "$WORK/engines/qreview/run"
printf 'good\n' > "$WORK/engines/qimpl/mode"
printf 'good\n' > "$WORK/engines/qreview/mode"

rc=0; /bin/bash "$QUALIFY" --engine qimpl --role implementer --output "$WORK/not-live.json" > "$WORK/not-live.log" 2>&1 || rc=$?
assert_eq 2 "$rc" 'live execution requires explicit --live'
[ ! -f "$ORCHID_QUALIFY_COUNTER" ] || fail 'no provider adapter invoked without explicit live flag'
rc=0; /bin/bash "$QUALIFY" --live --engine qimpl --role implementer --budget-seconds 901 --output "$WORK/excess-budget.json" > "$WORK/excess-budget.log" 2>&1 || rc=$?
assert_eq 2 "$rc" 'whole-invocation cap cannot exceed fifteen minutes'
red_case 'unapproved live execution and oversized total budgets refuse before any adapter call'

run_probe() {
  local name="$1" role="$2" engine="$3" rc=0
  shift 3
  /bin/bash "$QUALIFY" --live --engine "$engine" --role "$role" --output "$WORK/$name.json" "$@" > "$WORK/$name.log" 2>&1 || rc=$?
  probe_rc="$rc"
  [ -f "$WORK/$name.json" ] || { fail "$name writes an honest receipt"; return 1; }
  jq -e '.contract==1 and .retries==0 and .budget_seconds<=900 and (.scope|contains("wrapper"))' "$WORK/$name.json" >/dev/null || fail "$name receipt names bounded wrapper qualification scope"
}
run_probe self-review all qimpl --review-engine qimpl || exit 1
[ "$probe_rc" -ne 0 ] || fail 'same engine cannot qualify its own implementation review'
jq -e '.outcome=="blocked" and any(.checks[]; .reason=="implementation_cannot_review_itself") and .adapter_jobs_started==0' "$WORK/self-review.json" >/dev/null || fail 'self-review refusal is explicit and spends no model call'
red_case 'self-review cannot be presented as independent provider qualification'

run_probe implementation implementer qimpl || exit 1
assert_eq 0 "$probe_rc" 'fresh generated program qualifies its requested implementation role'
jq -e '.outcome=="pass" and .source_stable and .profiles_stable and .coverage.fresh_postcommit_program_inputs and (.coverage.accepted_graph_delivery|not) and .adapter_jobs_started==1 and any(.checks[]; .evidence.graph_contract==1 and .evidence.run_context.id!="" and (.evidence.contract_terms_sha256|test("^[0-9a-f]{64}$")))' "$WORK/implementation.json" >/dev/null || fail 'implementation receipt pins context and proof without claiming unexecuted review/delivery'
green_case 'actual fake-adapter generation passes two fresh random postcommit inputs and records current hashes'

printf 'hardcoded\n' > "$WORK/engines/qimpl/mode"
run_probe hardcoded implementer qimpl || exit 1
[ "$probe_rc" -ne 0 ] || fail 'hardcoded output cannot qualify as working generated code'
jq -e '.outcome!="pass" and (.coverage.fresh_postcommit_program_inputs|not)' "$WORK/hardcoded.json" >/dev/null || fail 'fabricated output never becomes a passing mechanical proof'
printf 'good\n' > "$WORK/engines/qimpl/mode"
red_case 'a hardcoded fixture program fails genuinely fresh postcommit nonce and arithmetic inputs'

run_probe review reviewer qreview || exit 1
assert_eq 0 "$probe_rc" 'fixture review qualifies hidden read and seeded defect discovery'
jq -e '.outcome=="pass" and .coverage.hidden_review_read and .adapter_jobs_started==1 and any(.checks[]; .scenario=="seeded-defect-review" and .evidence.output_contract_applicable)' "$WORK/review.json" >/dev/null || fail 'review-only receipt states exactly its executed contract-bound scope'
green_case 'independent report execution reads hidden committed token and rejects seeded subtraction defect'

printf 'no-read\n' > "$WORK/engines/qreview/mode"
run_probe no-read reviewer qreview || exit 1
[ "$probe_rc" -ne 0 ] || fail 'an unproved workspace read cannot qualify a reviewer'
jq -e '.outcome!="pass" and (.coverage.hidden_review_read|not)' "$WORK/no-read.json" >/dev/null || fail 'correct-looking verdict alone does not prove actual filesystem access'
printf 'good\n' > "$WORK/engines/qreview/mode"
red_case 'correct-looking review output cannot substitute for reading the withheld token'

run_probe delivery all qimpl --review-engine qreview || exit 1
assert_eq 0 "$probe_rc" 'independent provider pair completes synthetic graph qualification'
jq -e '.outcome=="pass" and .coverage.accepted_graph_delivery and .coverage.ownership_resume and .coverage.replayed_result_refused and .coverage.hidden_review_read and .coverage.fresh_postcommit_program_inputs and .adapter_jobs_started==4' "$WORK/delivery.json" >/dev/null || fail 'full receipt names only actually executed graph acceptance/resume/replay and independent model scenarios'
green_case 'separate producer/reviewer adapters complete current graph delivery, resume ownership, and reject replay'

for receipt in implementation review delivery; do
  jq -e 'all(.checks[]; (.adapter.adapter_sha256|test("^[0-9a-f]{64}$")) and (.adapter.profile_sha256|test("^[0-9a-f]{64}$")) and .adapter.cli_version=="1.2.3")' "$WORK/$receipt.json" >/dev/null || fail 'receipts pin both source adapter and HOME wrapper profile plus numeric CLI version'
  if grep -Fq "$WORK" "$WORK/$receipt.json"; then fail 'shareable receipt does not contain private filesystem paths'; fi
  if grep -Fq "$MACHINE_HOME" "$WORK/$receipt.json"; then fail 'receipt does not disclose restored HOME'; fi
done
green_case 'qualification receipts keep code/context identities without private paths or model payloads'
# Exercise the generated boundary wrapper without starting a model or kernel run.
sed -n '/^q_wrap() {/,/^q_capability() {/p' "$QUALIFY" | sed '$d' > "$WORK/wrap-function.sh"
mkdir -p "$WORK/wrap-source" "$WORK/wrap-profiles" "$WORK/wrap-worktree" "$WORK/wrap-pack"
printf 'entrypoint=run\n' > "$WORK/wrap-source/plugin.conf"
printf '#!/usr/bin/env bash\nprintf called > %q\n' "$WORK/wrap-called" > "$WORK/wrap-source/run"
chmod 755 "$WORK/wrap-source/run"
jq -cn --arg dir "$WORK/wrap-source" '{source_dir:$dir}' > "$WORK/wrap-descriptor.json"
cat > "$WORK/wrap-probe.sh" <<'WRAPTEST'
#!/usr/bin/env bash
set -euo pipefail
ORCHID_ROOT="$1"; export ORCHID_ROOT
source "$1/lib/common.sh"
source "$1/lib/manifest.sh"
source "$2/wrap-function.sh"
Q_ROOT="$1"; Q_REAL_HOME="$HOME"; Q_JOB_SECONDS=2
ORCHID_ENGINES_DIR="$2/wrap-profiles"
q_wrap "$2/wrap-descriptor.json" boundary
WRAPTEST
/bin/bash "$WORK/wrap-probe.sh" "$WORK/kernel" "$WORK" || { fail 'build actual boundary wrapper'; exit 1; }
printf 'unpredictable-hidden-wrapper-token\n' > "$WORK/wrap-worktree/.review-token"
jq -cn --arg wt "$WORK/wrap-worktree" --arg pack "$WORK/wrap-pack" '{deadline_s:2,operation:"review",worktree:$wt,input_pack:$pack}' > "$WORK/wrap-request.json"
cp "$WORK/wrap-worktree/.review-token" "$WORK/wrap-pack/leak.txt"
wrapper_rc=0
/bin/bash "$WORK/wrap-profiles/boundary/run" "$WORK/wrap-request.json" > "$WORK/wrap-leak.log" 2>&1 || wrapper_rc=$?
assert_eq 76 "$wrapper_rc" 'actual materialized pack leak refuses before native adapter'
[ ! -e "$WORK/wrap-called" ] || fail 'leaked hidden token spends no native call'
rm "$WORK/wrap-pack/leak.txt"
wrapper_rc=0
/bin/bash "$WORK/wrap-profiles/boundary/run" "$WORK/wrap-request.json" > "$WORK/wrap-clean.log" 2>&1 || wrapper_rc=$?
assert_eq 0 "$wrapper_rc" 'clean actual request and pack reach exact adapter'
[ -s "$WORK/wrap-called" ] || fail 'clean pack reaches exact native entrypoint'
red_case 'hidden token in materialized pack refuses before native adapter call'
green_case 'clean actual pack reaches selected adapter through bounded wrapper'

# Receipt completion is tested independently of successful lifecycle effects.
sed -n '/^q_finish() {/,/^q_exit() {/p' "$QUALIFY" | sed '$d' > "$WORK/finish-function.sh"
cat > "$WORK/finish-probe.sh" <<'FINISH'
#!/usr/bin/env bash
set -uo pipefail
source "$1/lib/common.sh"
source "$2/finish-function.sh"
q_run() { shift; "$@"; }
q_source_digest() { printf source; }
q_profile_stable() { return 0; }
q_left() { printf "900\n"; }
Q_WORK="$(mktemp -d "$2/finish.XXXXXX")"; Q_RECORDS="$Q_WORK/records.jsonl"
Q_OUTPUT="$2/finish-$3.json"; Q_FINISHED=0; Q_ACTIVE_JOB=""; Q_KEEP=0
Q_PRIMARY="$Q_WORK/primary.json"; Q_SECONDARY="$Q_WORK/secondary.json"
printf '{"profile_sha256":"digest"}\n' > "$Q_PRIMARY"
Q_SOURCE_BEFORE="$(printf source | _orchid_stream_sha256)"
Q_ROLE=all; Q_IMPL_PROOF=1; Q_REVIEW_PROOF=1; Q_RESUMED=1; Q_REPLAY=1; Q_DELIVERED=1
Q_ADAPTER_JOBS=4; Q_BUDGET=900; Q_JOB_SECONDS=120; Q_STARTED="$(date +%s)"
case "$3" in
 partial) Q_REVIEW_PROOF=0; printf '{"scenario":"implementation","outcome":"pass"}\n' > "$Q_RECORDS" ;;
 *) for name in implementation independent-verifier source-review graph-completion seeded-defect-review; do
      jq -cn --arg name "$name" '{scenario:$name,outcome:"pass"}' >> "$Q_RECORDS"
    done ;;
esac
if [ "$3" = failed ]; then printf '{"scenario":"late","outcome":"fail"}\n' >> "$Q_RECORDS"; fi
q_finish "$4"
FINISH
for variant in partial interrupted failed complete; do
  finish_rc=0; input_rc=0
  case "$variant" in partial|interrupted) input_rc=130 ;; esac
  /bin/bash "$WORK/finish-probe.sh" "$WORK/kernel" "$WORK" "$variant" "$input_rc" > "$WORK/finish-$variant.log" 2>&1 || finish_rc=$?
  if [ "$variant" = complete ]; then
    assert_eq 0 "$finish_rc" 'complete requested coverage can pass with zero exit'
    jq -e '.outcome=="pass" and .requested_coverage_complete' "$WORK/finish-$variant.json" >/dev/null || fail 'complete coverage receipt accepts'
  else
    [ "$finish_rc" -ne 0 ] || fail 'partial interrupted or failed check cannot aggregate pass'
    jq -e '.outcome!="pass"' "$WORK/finish-$variant.json" >/dev/null || fail 'nonzero/incomplete execution is never receipt pass'
  fi
done
jq -e '.outcome=="fail"' "$WORK/finish-failed.json" >/dev/null || fail 'executed failed check has fail precedence'
red_case 'partial coverage interrupted execution and explicit failed checks cannot yield aggregate pass'
green_case 'zero-exit complete requested coverage yields aggregate pass'

# Ambient hooks, dry-run, timeout and Git routing cannot escape the fixture.
probe_rc=0
env ORCHID_TIMEOUT_MINUTES=60 ORCHID_DRYRUN=1 ORCHID_WORKTREE_PREPARE="touch $WORK/ambient-ran" \
  ORCHID_HOOK_BEFORE_MERGE="touch $WORK/ambient-ran" ORCHID_ROLE_IMPLEMENTER=absent \
  ORCHID_REVIEW_LOW=absent GIT_DIR="$WORK/nonexistent.git" GIT_WORK_TREE="$WORK" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$WORK/ambient-hooks" \
  /bin/bash "$QUALIFY" --live --engine qimpl --role implementer --output "$WORK/poison.json" > "$WORK/poison.log" 2>&1 || probe_rc=$?
assert_eq 0 "$probe_rc" 'exported ambient overrides cannot change controlled live fixture'
[ ! -e "$WORK/ambient-ran" ] || fail 'ambient command did not execute'
jq -e '.outcome=="pass" and .adapter_jobs_started==1' "$WORK/poison.json" >/dev/null || fail 'poisoned environment still executes actual intended adapter'
red_case 'ambient Orchid and Git overrides are neutralized before kernel effects'
green_case 'controlled synthetic implementation executes under poisoned environment'

printf 'hang\n' > "$WORK/engines/qimpl/mode"
probe_rc=0
/bin/bash "$QUALIFY" --live --engine qimpl --role implementer --job-seconds 2 --output "$WORK/hang.json" > "$WORK/hang.log" 2>&1 || probe_rc=$?
[ "$probe_rc" -ne 0 ] || fail 'hanging adapter cannot qualify'
if [ -s "$WORK/engines/qimpl/hanging.pid" ]; then
  hanging_pid="$(cat "$WORK/engines/qimpl/hanging.pid")"
  if kill -0 "$hanging_pid" 2>/dev/null; then
    hanging_state="$(ps -p "$hanging_pid" -o stat= 2>/dev/null)"
    case "$hanging_state" in *Z*) ;; *) fail 'wrapper outer deadline kills TERM-resistant descendant'; kill -KILL "$hanging_pid" 2>/dev/null || true ;; esac
  fi
else fail 'timeout regression actually started resistant descendant'; fi
jq -e '.outcome!="pass" and (.coverage.fresh_postcommit_program_inputs|not)' "$WORK/hang.json" >/dev/null || fail 'timeout cannot be receipt pass'
printf 'good\n' > "$WORK/engines/qimpl/mode"
red_case 'wrapper-owned deadline terminates resistant adapter descendants without passing receipt'
for receipt in implementation review delivery; do
  jq -e '[..|objects|keys[]|select(.=="acceptance_criteria" or .=="verification_commands" or .=="contract_terms")]|length==0' "$WORK/$receipt.json" >/dev/null || fail 'receipt excludes raw contract inputs recursively'
done
green_case 'receipts expose target identities and contract hashes without raw terms'
[ "$FAILS" -eq 0 ]
