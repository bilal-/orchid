#!/usr/bin/env bash
# RED: Graph jobs refuse unbound, obsolete, dirty or foreign candidate state.
# GREEN: Separate generation checkouts and atomic waits preserve exact inputs.
source "$(dirname "$0")/helpers.sh"
if [ ! -f "$REPO_ROOT/lib/graph-runtime.sh" ]; then fail 'graph runtime exists'; exit 1; fi
source "$REPO_ROOT/lib/graph-runtime.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
env -u ORCHID_ROOT /bin/bash -uc '
  source "$1/lib/common.sh"
  source "$1/lib/frontmatter.sh"
  source "$1/lib/graph-integration.sh"
  if orchid_graph_active "$2"; then exit 1; fi
  declare -F graph_runtime_enabled >/dev/null
' rootless "$REPO_ROOT" "$WORK/origin" > "$WORK/rootless-policy.log" 2>&1 || {
  fail 'legacy policy caller loads graph helpers without an installation environment'
  exit 1
}
green_case 'legacy policy libraries locate their graph dependency without ORCHID_ROOT'
env -u ORCHID_ROOT /bin/bash -uc '
  cd "$1" || exit 1
  source lib/common.sh
  source lib/frontmatter.sh
  source lib/drive.sh
  cd "$2" || exit 1
  if orchid_graph_active "$2"; then exit 1; fi
  declare -F graph_runtime_enabled >/dev/null
' rootless "$REPO_ROOT" "$WORK/origin" > "$WORK/relative-policy.log" 2>&1 || {
  fail 'relative-source policy caller keeps its dependency after changing directory'
  exit 1
}
green_case 'relative library loading remains valid after changing the working directory'
printf 'baseline\n' > app.txt
printf 'concurrency=8\n' > orchid.config
git add app.txt orchid.config
git commit -q -m baseline
"$ORCHID_BIN" init >/dev/null || { fail 'initialize runtime fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
for id in A U K O; do "$ORCHID_BIN" task create "$id" "$id code" >/dev/null || { fail 'create source'; exit 1; }; done
"$ORCHID_BIN" task create V 'candidate verification' --archetype review >/dev/null || { fail 'create verifier'; exit 1; }
"$ORCHID_BIN" task create R 'ordinary graph report' --archetype review >/dev/null || { fail 'create ordinary report'; exit 1; }
"$ORCHID_BIN" task set K verification_commands true >/dev/null
"$ORCHID_BIN" task create W 'nested verification' --archetype review >/dev/null || { fail 'create nested verifier'; exit 1; }
"$ORCHID_BIN" task set A verification_commands true >/dev/null
"$ORCHID_BIN" task set V verifies A >/dev/null
"$ORCHID_BIN" task set W verifies V >/dev/null
"$ORCHID_BIN" task set V output_contract '{"contract":1}' >/dev/null
if graph_runtime_enabled "$ORCHID_REPO"; then fail 'legacy runtime remains disabled'; fi
# Operator enable publishes the whole pending definition set in one transaction.
index_before="$(git ls-files --stage | git hash-object --stdin)"
rc=0; ORCHID_ACTOR=machine "$ORCHID_BIN" graph enable --reason fixture > "$WORK/enable-machine.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'machine cannot activate graph policy'
"$ORCHID_BIN" graph enable --reason 'bind all pending definitions' > "$WORK/enable.log" || { fail 'operator enables graph mode'; exit 1; }
assert_eq "$index_before" "$(git ls-files --stage | git hash-object --stdin)" 'enable preserves caller index'
git show orchid/integration:.orchid/tasks/V.md > "$WORK/published-V.md" || fail 'enable publishes task definitions'
assert_eq '{"contract":1}' "$(fm_get "$WORK/published-V.md" output_contract)" 'enable publishes output contract'
assert_eq 1 "$(git show orchid/integration:.orchid/roadmap.md | sed -n 's/^graph_contract: //p')" 'enable publishes graph marker'
git cat-file -e orchid/integration:.orchid/requirements.md || fail 'enable publishes requirements'
enable_head="$(git rev-parse orchid/integration)"
"$ORCHID_BIN" graph enable --reason again >/dev/null || fail 'enable idempotent'
assert_eq "$enable_head" "$(git rev-parse orchid/integration)" 'idempotent enable makes no commit'
red_case 'graph enable is operator owned'
green_case 'enable publishes complete validated planning definitions without index changes'
fm_set .orchid/roadmap.md graph_contract 99
rc=0; out="$(graph_runtime_enabled "$ORCHID_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'unknown runtime contract cannot downgrade to legacy'
assert_match 'graph_contract|contract' "$out" 'unknown runtime contract diagnostic'
fm_set .orchid/roadmap.md graph_contract 1
graph_runtime_enabled "$ORCHID_REPO" || fail 'explicit graph mode enabled'
"$ORCHID_BIN" run advance running --reason fixture >/dev/null || { fail 'run starts'; exit 1; }
base="$(git rev-parse orchid/integration)"
git worktree add -q -b task/A "$WORK/source-A" "$base"
"$ORCHID_BIN" task set A worktree "$WORK/source-A" >/dev/null
"$ORCHID_BIN" task set A base_sha "$base" >/dev/null
"$ORCHID_BIN" task advance A implementing >/dev/null || { fail 'source dispatch'; exit 1; }
printf 'candidate\n' > "$WORK/source-A/app.txt"
git -C "$WORK/source-A" add app.txt
git -C "$WORK/source-A" commit -q -m candidate
candidate="$(git -C "$WORK/source-A" rev-parse HEAD)"
"$ORCHID_BIN" task set A candidate_sha "$candidate" >/dev/null
"$ORCHID_BIN" task advance A testing >/dev/null || { fail 'candidate enters testing'; exit 1; }

fm_set .orchid/tasks/U.md started_at 'not-an-admission-clock'
rc=0; graph_snapshot_file "$ORCHID_REPO" "$WORK/bad-clock.json" > "$WORK/bad-clock.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'malformed nonempty graph clock cannot hide an unadmitted checkpoint'
fm_set .orchid/tasks/U.md started_at ''
graph_snapshot_file "$ORCHID_REPO" "$WORK/good-clock.json" || fail 'empty unadmitted clock remains representable'
red_case 'malformed nonempty graph admission clocks fail closed'
green_case 'empty graph admission clocks are normalized without inventing a start'
before="$(git hash-object .orchid/tasks/*.md .orchid/roadmap.md .orchid/runtime/epoch .orchid/runtime/lease.json)"
graph_snapshot_file "$ORCHID_REPO" "$WORK/model.json" || { fail 'runtime snapshot'; exit 1; }
assert_eq "$before" "$(git hash-object .orchid/tasks/*.md .orchid/roadmap.md .orchid/runtime/epoch .orchid/runtime/lease.json)" 'runtime snapshot is read only'
rc=0; out="$(graph_job_prepare_gate "$ORCHID_REPO" V "$WORK/model.json" review 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'unbound verifier cannot prepare a job'
red_case 'unknown graph versions and unbound verifier work refuse'
"$ORCHID_BIN" graph prepare V >/dev/null || { fail 'materialize exact verifier candidate'; exit 1; }
graph_snapshot_file "$ORCHID_REPO" "$WORK/model.json" || fail 'snapshot bound verifier'
verifier_path="$(graph_job_workspace "$ORCHID_REPO" V "$WORK/model.json" review)" || { fail 'owned verifier checkout'; exit 1; }
assert_eq "$candidate" "$(git -C "$verifier_path" rev-parse HEAD)" 'verifier reads exact unmerged candidate'
[ "$verifier_path" != "$WORK/source-A" ] && [ "$verifier_path" != "$ORCHID_REPO" ] || fail 'verifier never borrows source or control checkout'
assert_eq task/V "$(git -C "$verifier_path" symbolic-ref --short HEAD)" 'verifier canonical branch'
graph_job_prepare_gate "$ORCHID_REPO" V "$WORK/model.json" review || fail 'bound verifier is admissible'
node_before="$(git hash-object .orchid/tasks/V.md .orchid/journal.md)"
"$ORCHID_BIN" graph bind V >/dev/null || fail 'matching bind is idempotent'
assert_eq "$node_before" "$(git hash-object .orchid/tasks/V.md .orchid/journal.md)" 'matching binding does not republish metadata'
green_case 'graph prepare creates a distinct exact canonical checkout and bind is idempotent'

graph_job_binding "$ORCHID_REPO" V "$WORK/binding.json" "$WORK/model.json" || fail 'trusted binding file'
jq -e '.graph_contract == 1 and .verification_target.task == "A" and .verification_target.run_context == .run_context and .output_contract.operations == ["review"] and .attempt == 1' "$WORK/binding.json" >/dev/null || fail 'typed binding and report contract scope'
graph_job_binding "$ORCHID_REPO" A "$WORK/code-binding.json" "$WORK/model.json" || fail 'source binding'
jq -e '.verification_target == null' "$WORK/code-binding.json" >/dev/null || fail 'non-verifier target is explicitly null'
jq --arg candidate "$candidate" --arg base "$base" --arg path "$verifier_path" '. + {task:"V",operation:"review",base_sha:$base,candidate_sha:$candidate,start_head_sha:$candidate,worktree:$path}' "$WORK/binding.json" > "$WORK/manifest.json"
graph_manifest_current "$ORCHID_REPO" "$WORK/manifest.json" "$WORK/model.json" || fail 'current manifest accepted'
jq '.run_context.requirements_revision += 1' "$WORK/manifest.json" > "$WORK/obsolete.json"
rc=0; graph_manifest_current "$ORCHID_REPO" "$WORK/obsolete.json" "$WORK/model.json" > "$WORK/obsolete.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'obsolete context rejected'
printf 'dirty\n' > "$verifier_path/dirty.txt"
rc=0; graph_job_prepare_gate "$ORCHID_REPO" V "$WORK/model.json" review > "$WORK/dirty.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'dirty verifier refuses job preparation'
rm "$verifier_path/dirty.txt"
red_case 'obsolete run bindings and dirty verifier checkouts refuse'
graph_manifest_current "$ORCHID_REPO" "$WORK/manifest.json" "$WORK/model.json" || fail 'restored candidate current'
green_case 'trusted current binding accepts after the same workspace is clean'

# Writable jobs cannot start after a candidate freezes. Verify/merge wait for all jobs.
rc=0; graph_job_prepare_gate "$ORCHID_REPO" A "$WORK/model.json" implement > "$WORK/frozen.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'testing candidate rejects writable implementation'
rc=0; (orchid_task_jobs_idle() { printf 'prepared job owns checkout\n'; return 1; }; graph_job_prepare_gate "$ORCHID_REPO" A "$WORK/model.json" verify) > "$WORK/live-verify.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'verify refuses outstanding job even when HEAD unchanged'
graph_job_prepare_gate "$ORCHID_REPO" A "$WORK/model.json" verify || fail 'idle immutable candidate can verify'
red_case 'frozen implement and nonidle verify are refused'
green_case 'idle immutable candidate admits verification'
# Own prepared-job exemption never hides another job. The existing jobs verb
# remains the only process inventory producer; this fixture controls its rows.
mkdir -p "$WORK/jobs-owner/bin"
cat > "$WORK/jobs-owner/bin/orchid" <<'SH'
#!/bin/bash
printf 'own\tU\timplementer\timplement\tfake\t1\t1\tprepared\n'
[ "${OTHER_PREPARED:-0}" = 0 ] || printf 'other\tU\timplementer\timplement\tfake\t1\t1\tprepared\n'
SH
chmod +x "$WORK/jobs-owner/bin/orchid"
(ORCHID_ROOT="$WORK/jobs-owner"; orchid_task_jobs_idle "$ORCHID_REPO" U own) || fail 'own prepared manifest exemption'
rc=0; (export OTHER_PREPARED=1; ORCHID_ROOT="$WORK/jobs-owner"; orchid_task_jobs_idle "$ORCHID_REPO" U own) > "$WORK/other-job.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'another own-task prepared job still blocks'
red_case 'ignoring prepared launch never ignores another job'
green_case 'only exact own prepared manifest can be exempted'
# Budget reads consume no job inventory and never forgive stale identities.
graph_job_binding "$ORCHID_REPO" A "$WORK/verify-binding.json" "$WORK/model.json" || fail 'mechanical binding'
mkdir -p .orchid/reviews
"$ORCHID_BIN" verify A >/dev/null || { fail 'normal graph verification'; exit 1; }
graph_verify_current "$ORCHID_REPO" A "$WORK/model.json" || fail 'mechanical proof is current'
cp .orchid/reviews/A-verify.log "$WORK/same-candidate.log"
sed 's@^cwd:.*@cwd: /different-owned-checkout@' "$WORK/same-candidate.log" > .orchid/reviews/A-verify.log
rc=0; graph_verify_current "$ORCHID_REPO" A "$WORK/model.json" > "$WORK/other-cwd.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'same candidate and command proof from another cwd refused'
cp "$WORK/same-candidate.log" .orchid/reviews/A-verify.log
graph_verify_current "$ORCHID_REPO" A "$WORK/model.json" || fail 'same physical owned cwd proof current'
red_case 'mechanical proof from another workspace cannot be reused by SHA alone'
green_case 'mechanical proof matches current canonical owned cwd including platform aliases'
"$ORCHID_BIN" graph wait A >/dev/null || fail 'wait begins only after own proof'
now="$(date +%s)"
fm_set .orchid/tasks/A.md graph_wait "{\"started_at\":$((now-10)),\"seconds\":5,\"candidate_sha\":\"$candidate\",\"contract_revision\":1,\"generation\":1,\"attempt\":1}"
pause="$(orchid_task_jobs_idle() { fail 'budget observation must not query jobs'; return 1; }; graph_budget_pause "$ORCHID_REPO" A "$now")"
assert_eq 15 "$pause" 'pause accounts cumulative and ongoing waiting'
graph_wait_exempts "$ORCHID_REPO" A V || fail 'idle waiting ancestor permits its verifier'
if graph_wait_exempts "$ORCHID_REPO" A U; then fail 'waiting ancestor never exempts unrelated task'; fi
"$ORCHID_BIN" graph prepare A --operation review >/dev/null || fail 'prepare closes waiting interval before own effect'
jq -e '(.started_at == 0) and .seconds >= 15' <<< "$(fm_get .orchid/tasks/A.md graph_wait)" >/dev/null || fail 'close is atomic cumulative update'
# Evidence-bearing identities are frozen. Stop explicitly before exercising
# supported recovery changes; the binding checks below must still reject old
# evidence even though recovery keeps the version counters and candidate.
"$ORCHID_BIN" task advance A blocked --reason 'explicit recovery for candidate clock and range probes' >/dev/null || { fail 'stop before identity recovery'; exit 1; }
assert_eq blocked "$(fm_get .orchid/tasks/A.md status)" 'identity probes use explicit blocked recovery'
# Cumulative closed pause belongs to this execution attempt, while an open
# interval belongs only to its exact candidate and cannot move with a new SHA.
fm_set .orchid/tasks/A.md graph_wait "{\"started_at\":0,\"seconds\":15,\"candidate_sha\":\"$candidate\",\"contract_revision\":1,\"generation\":1,\"attempt\":1}"
alternate="$(printf 'same-attempt alternate candidate\n' | git commit-tree "$(git rev-parse "$candidate^{tree}")" -p "$candidate")" || { fail 'alternate candidate'; exit 1; }
"$ORCHID_BIN" task set A candidate_sha "$alternate" >/dev/null || fail 'same-attempt candidate update'
assert_eq 15 "$(graph_budget_pause "$ORCHID_REPO" A "$now")" 'closed pause survives same-attempt candidate change'
fm_set .orchid/tasks/A.md graph_wait "{\"started_at\":$((now-10)),\"seconds\":7,\"candidate_sha\":\"$candidate\",\"contract_revision\":1,\"generation\":1,\"attempt\":1}"
assert_eq 7 "$(graph_budget_pause "$ORCHID_REPO" A "$now")" 'different candidate never accrues stale open interval'
graph_wait_close "$ORCHID_REPO" A || fail 'close mismatched candidate without losing prior closed pause'
jq -e --arg candidate "$alternate" '.started_at == 0 and .seconds == 7 and .candidate_sha == $candidate and (has("same_candidate") | not)' <<< "$(fm_get .orchid/tasks/A.md graph_wait)" >/dev/null || fail 'mismatched open wait normalizes to closed current candidate'
"$ORCHID_BIN" task set A candidate_sha "$candidate" >/dev/null || fail 'restore candidate'
assert_eq 7 "$(graph_budget_pause "$ORCHID_REPO" A "$now")" 'closed pause survives candidate restore'
fm_set .orchid/tasks/A.md attempts 1
assert_eq 0 "$(graph_budget_pause "$ORCHID_REPO" A "$now")" 'new attempt resets cumulative pause'
fm_set .orchid/tasks/A.md attempts 0
red_case 'open pause cannot move to another candidate or execution attempt'
green_case 'closed same-attempt pause survives candidate changes and normalizes atomically'
fm_set .orchid/tasks/A.md execution_generation 2
assert_eq 0 "$(graph_budget_pause "$ORCHID_REPO" A "$now")" 'stale generation pause grants no budget discount'
red_case 'budget observation and exemptions reject unrelated tasks and stale identities'
fm_set .orchid/tasks/A.md execution_generation 1
green_case 'atomic wait accounting and exact descendant exemptions preserve own work budgets'
# Pending repairs retain history too: this is mutable work, and the normal
# task active-entry transition owns its clock rather than checkpoint admission.
fm_set .orchid/tasks/U.md execution_generation 2
fm_set .orchid/tasks/U.md contract_revision 2
fm_set .orchid/tasks/U.md branch task/U-g2
fm_set .orchid/tasks/U.md candidate_reuse_from "{\"base_sha\":\"$base\",\"candidate_sha\":\"$base\",\"source_generation\":1,\"source_contract_revision\":1,\"implementer_engine_id\":\"\",\"source_archive\":\".orchid/revisions/U-g1\"}"
if graph_checkpoint_pending "$ORCHID_REPO" U; then fail 'pending mutable repair is not a verification checkpoint'; fi
# A malformed worker reply may leave clean useful commits in the same generation.
"$ORCHID_BIN" graph prepare U --operation implement >/dev/null || { fail 'pending implementation workspace'; exit 1; }
graph_snapshot_file "$ORCHID_REPO" "$WORK/retry.json" || fail 'pending snapshot'
graph_job_prepare_gate "$ORCHID_REPO" U "$WORK/retry.json" implement || fail 'pending code implement admission'
assert_eq '' "$(fm_get .orchid/tasks/U.md started_at)" 'pending lineage preparation leaves clock to normal task entry'
"$ORCHID_BIN" task advance U implementing >/dev/null || { fail 'U implementing'; exit 1; }
u_path="$(fm_get .orchid/tasks/U.md worktree)"
u_work_anchor="$(fm_get .orchid/tasks/U.md started_at)"
[ -n "$u_work_anchor" ] || fail 'ordinary mutable work owns an active-entry clock'
printf 'retained malformed-reply work\n' > "$u_path/retry.txt"
git -C "$u_path" add retry.txt
git -C "$u_path" commit -q -m 'retained worker output'
u_head="$(git -C "$u_path" rev-parse HEAD)"
graph_snapshot_file "$ORCHID_REPO" "$WORK/retry.json" || fail 'retry snapshot'
graph_job_prepare_gate "$ORCHID_REPO" U "$WORK/retry.json" implement || fail 'same generation advanced clean HEAD can retry'
"$ORCHID_BIN" graph prepare U --operation implement >/dev/null || fail 'retry prepare preserves produced HEAD'
assert_eq "$u_head" "$(git -C "$u_path" rev-parse HEAD)" 'retry never resets committed worker output'
assert_eq 2 "$(fm_version .orchid/tasks/U.md execution_generation)" 'retry retains generation'
assert_eq "$u_work_anchor" "$(fm_get .orchid/tasks/U.md started_at)" 'mutable repair retry never refreshes its active-entry clock'
green_case 'pending and implementing admission preserve same-generation committed output'
# Completion rechecks immutable artifact contracts even for explicit review
# scope on a code node; ordinary operator approval cannot override the bytes.
"$ORCHID_BIN" task set U candidate_sha "$u_head" >/dev/null || fail 'publish retry candidate'
"$ORCHID_BIN" task advance U testing >/dev/null || { fail 'U testing'; exit 1; }
fm_set .orchid/tasks/U.md output_contract '{"contract":1,"artifacts":[{"path":"missing.txt"}]}'
graph_snapshot_file "$ORCHID_REPO" "$WORK/artifacts.json" || fail 'artifact failure snapshot'
rc=0; graph_completion_ready "$ORCHID_REPO" U "$WORK/artifacts.json" > "$WORK/artifact-refused.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'missing committed artifact blocks completion'
fm_set .orchid/tasks/U.md output_contract '{"contract":1,"operations":["review"],"artifacts":[{"path":"missing.txt"}]}'
graph_snapshot_file "$ORCHID_REPO" "$WORK/artifacts.json" || fail 'explicit review contract snapshot'
rc=0; graph_completion_ready "$ORCHID_REPO" U "$WORK/artifacts.json" > "$WORK/review-artifact-refused.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'explicit review artifact contract blocks code completion'
fm_set .orchid/tasks/U.md output_contract '{"contract":1,"artifacts":[{"path":"retry.txt"}]}'
graph_snapshot_file "$ORCHID_REPO" "$WORK/artifacts.json" || fail 'valid artifact snapshot'
graph_completion_ready "$ORCHID_REPO" U "$WORK/artifacts.json" || fail 'committed declared artifact admits completion'
red_case 'missing committed artifacts block primary and explicit review completion'
green_case 'existing immutable candidate artifacts satisfy completion contract'
# Full receipts certify the pre-enrichment worker envelope. Additive trusted
# metadata must not be revalidated against its strict raw-worker object schema.
fm_set .orchid/tasks/V.md output_contract '{"contract":1,"envelope_schema":{"type":"object","properties":{"operation":{"type":"string"},"status":{"type":"string"}},"required":["operation","status"],"additionalProperties":false}}'
graph_snapshot_file "$ORCHID_REPO" "$WORK/receipt.json" || fail 'strict receipt snapshot'
graph_job_binding "$ORCHID_REPO" V "$WORK/receipt-binding.json" "$WORK/receipt.json" || fail 'strict receipt binding'
graph_effective_output_contract "$WORK/receipt.json" V "$WORK/receipt-contract.json" || fail 'strict effective contract'
printf '{"operation":"review","status":"ok"}\n' > "$WORK/raw-review.json"
output_contract_evaluate "$ORCHID_REPO" "$candidate" "$(cat "$WORK/receipt-contract.json")" "$WORK/raw-review.json" > "$WORK/full-receipt.json" || fail 'raw worker strict schema passes before enrichment'
jq --arg candidate "$candidate" --slurpfile raw "$WORK/raw-review.json" --slurpfile receipt "$WORK/full-receipt.json" '. + $raw[0] + {task:"V",candidate_sha:$candidate,output_contract_evidence:$receipt[0]}' "$WORK/receipt-binding.json" > "$WORK/filed-review.json"
graph_review_evidence_current "$ORCHID_REPO" V "$WORK/filed-review.json" "$WORK/receipt.json" || fail 'trusted additive metadata preserves full receipt'
jq 'del(.output_contract_evidence)' "$WORK/filed-review.json" > "$WORK/no-receipt.json"
rc=0; graph_review_evidence_current "$ORCHID_REPO" V "$WORK/no-receipt.json" "$WORK/receipt.json" || rc=$?
[ "$rc" -ne 0 ] || fail 'applicable review contract requires full kernel receipt'
jq '.task="W"' "$WORK/filed-review.json" > "$WORK/wrong-task-review.json"
rc=0; graph_review_evidence_current "$ORCHID_REPO" V "$WORK/wrong-task-review.json" "$WORK/receipt.json" || rc=$?
[ "$rc" -ne 0 ] || fail 'another task cannot reuse identical semantic review context'
jq '.operation="critique"' "$WORK/filed-review.json" > "$WORK/critique.json"
rc=0; graph_review_evidence_current "$ORCHID_REPO" V "$WORK/critique.json" "$WORK/receipt.json" || rc=$?
[ "$rc" -ne 0 ] || fail 'critique cannot stand in for required review'
jq '.verdict="request-changes" | .contract_failure={contract:1,passed:false,kind:"artifact",reason:"fixture"}' "$WORK/no-receipt.json" > "$WORK/negative-review.json"
graph_review_evidence_current "$ORCHID_REPO" V "$WORK/negative-review.json" "$WORK/receipt.json" || fail 'kernel artifact failure counts as finished negative review'
red_case 'missing full contract receipts and critique evidence cannot satisfy a review'
green_case 'trusted full receipts and bound kernel artifact failures remain finished reviews'
# Every graph report owns a separate pinned checkout even without a verifies
# edge, so unrelated integration activity cannot alter its review files.
"$ORCHID_BIN" graph prepare R --operation review >/dev/null || { fail 'ordinary report checkout'; exit 1; }
graph_snapshot_file "$ORCHID_REPO" "$WORK/report.json" || fail 'ordinary report snapshot'
r_path="$(graph_job_workspace "$ORCHID_REPO" R "$WORK/report.json" review)" || fail 'ordinary report owns workspace'
[ "$r_path" != "$ORCHID_REPO" ] || fail 'ordinary report must not borrow control checkout'
assert_eq "$(git rev-parse orchid/integration)" "$(git -C "$r_path" rev-parse HEAD)" 'ordinary report pins integration HEAD when unset'
printf 'uncommitted report mutation\n' > "$r_path/dirty.txt"
rc=0; graph_job_prepare_gate "$ORCHID_REPO" R "$WORK/report.json" review > "$WORK/report-dirty.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'ordinary report dirty checkout refused'
rm "$r_path/dirty.txt"
graph_job_prepare_gate "$ORCHID_REPO" R "$WORK/report.json" review || fail 'ordinary report clean checkout admitted'
red_case 'ordinary graph reports cannot use dirty mutable checkouts'
green_case 'ordinary graph reports own a separate immutable candidate checkout'
# Model a replan-owned checkpoint: historical lineage is retained, while the
# current candidate/base take precedence after a legitimate candidate rebase.
fm_set .orchid/tasks/K.md execution_generation 2
fm_set .orchid/tasks/K.md contract_revision 2
fm_set .orchid/tasks/K.md branch task/K-g2
fm_set .orchid/tasks/K.md base_sha "$base"
fm_set .orchid/tasks/K.md candidate_sha "$candidate"
fm_set .orchid/tasks/K.md status testing
fm_set .orchid/tasks/K.md candidate_reuse_from "{\"base_sha\":\"$base\",\"candidate_sha\":\"$base\",\"source_generation\":1,\"source_contract_revision\":1,\"implementer_engine_id\":\"\",\"source_archive\":\".orchid/revisions/K-g1\"}"
graph_snapshot_file "$ORCHID_REPO" "$WORK/unadmitted.json" || fail 'unadmitted checkpoint snapshot'
graph_checkpoint_pending "$ORCHID_REPO" K "$WORK/unadmitted.json" || fail 'retained checkpoint begins pending admission'
rc=0; graph_job_prepare_gate "$ORCHID_REPO" K "$WORK/unadmitted.json" verify > "$WORK/unadmitted-job.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'unadmitted checkpoint refuses own jobs and verification'
assert_match 'not admitted' "$(cat "$WORK/unadmitted-job.log")" 'admission refusal precedes absent workspace check'
(
  verb_lock_acquire "$ORCHID_REPO"
  trap 'verb_lock_release "$ORCHID_REPO"' EXIT
  graph_checkpoint_admit "$ORCHID_REPO" K "$WORK/unadmitted.json"
) || { fail 'atomic retained checkpoint admission'; exit 1; }
k_anchor="$(fm_get .orchid/tasks/K.md started_at)"
[ -n "$k_anchor" ] || fail 'checkpoint admission records shared active-entry clock'
assert_eq '' "$(fm_get .orchid/tasks/K.md worktree)" 'crash after clock before checkout remains resumable'
if graph_checkpoint_pending "$ORCHID_REPO" K; then fail 'admitted checkpoint must reserve its active slot'; fi
(
  verb_lock_acquire "$ORCHID_REPO"
  trap 'verb_lock_release "$ORCHID_REPO"' EXIT
  graph_checkpoint_admit "$ORCHID_REPO" K "$WORK/unadmitted.json"
) || fail 'replayed admission with same lineage is idempotent'
assert_eq "$k_anchor" "$(fm_get .orchid/tasks/K.md started_at)" 'replayed admission does not refresh budget clock'
red_case 'unadmitted retained checkpoints refuse work before reserving a slot'
green_case 'atomic admission survives clock-before-checkout crash without refreshing budget'
"$ORCHID_BIN" graph prepare K --operation verify >/dev/null || { fail 'retained candidate checkpoint'; exit 1; }
assert_eq "$k_anchor" "$(fm_get .orchid/tasks/K.md started_at)" 'runner resumes admitted checkpoint with original active clock'
graph_snapshot_file "$ORCHID_REPO" "$WORK/checkpoint.json" || fail 'checkpoint snapshot'
k_path="$(graph_job_workspace "$ORCHID_REPO" K "$WORK/checkpoint.json" verify)" || fail 'owned checkpoint workspace'
assert_eq "$candidate" "$(git -C "$k_path" rev-parse HEAD)" 'checkpoint uses current candidate over historical lineage'
assert_eq task/K-g2 "$(git -C "$k_path" symbolic-ref --short HEAD)" 'checkpoint owns new generation branch'
"$ORCHID_BIN" verify K >/dev/null || fail 'checkpoint reruns mechanical proof without implementer reply'
graph_verify_current "$ORCHID_REPO" K || fail 'checkpoint proof current'
rc=0; "$ORCHID_BIN" graph prepare K --operation implement > "$WORK/checkpoint-write.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'checkpoint cannot restart implementation implicitly'
red_case 'retained checkpoint cannot enter writable implementation'
green_case 'retained checkpoint rechecks current candidate on a new owned generation branch'
# Candidate/definition diagnostics must remain visible precisely when their
# physical checkout/candidate is unusable; stale logical identities still fail.
graph_job_binding "$ORCHID_REPO" U "$WORK/failure-binding.json" || fail 'negative boundary binding'
jq '. + {task:"U",operation:"implement",status:"failed",worktree:"/missing-owned-checkout",contract_failure:{contract:1,passed:false,kind:"candidate",reason:"fixture"}}' "$WORK/failure-binding.json" > "$WORK/candidate-failure.json"
graph_result_current "$ORCHID_REPO" U "$WORK/candidate-failure.json" || fail 'current candidate diagnostic survives unusable checkout'
jq '.execution_generation += 1' "$WORK/candidate-failure.json" > "$WORK/stale-failure.json"
rc=0; graph_result_current "$ORCHID_REPO" U "$WORK/stale-failure.json" || rc=$?
[ "$rc" -ne 0 ] || fail 'stale failure cannot become current candidate boundary'
red_case 'stale trusted failure bindings cannot affect current execution'
green_case 'current candidate diagnostics stay visible without inspecting unusable checkout'
# Crash recovery adopts an exact canonical orphan at its real fork point even
# when an unrelated integration commit lands before durable bind completes.
_graph_runtime_workspace_helpers
o_path="$(drive_worktree_path "$ORCHID_REPO" O)" || { fail 'orphan conventional path'; exit 1; }
o_base="$(git rev-parse orchid/integration)"
git worktree add -q -b task/O "$o_path" "$o_base" || { fail 'simulate creation before bind crash'; exit 1; }
o_tree="$(git rev-parse 'orchid/integration^{tree}')"
o_next="$(printf 'unrelated integration advancement\n' | git commit-tree "$o_tree" -p "$o_base")" || fail 'new integration commit'
git update-ref refs/heads/orchid/integration "$o_next" "$o_base" || fail 'integration advances between creation and binding'
printf 'dirty orphan\n' > "$o_path/dirty.txt"
rc=0; "$ORCHID_BIN" graph prepare O --operation implement > "$WORK/dirty-orphan.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'dirty orphan checkout cannot be adopted'
rm "$o_path/dirty.txt"
"$ORCHID_BIN" graph prepare O --operation implement >/dev/null || { fail 'adopt orphan at real older fork point'; exit 1; }
assert_eq "$o_base" "$(git -C "$o_path" rev-parse HEAD)" 'orphan recovery never resets its checkout'
assert_eq "$o_base" "$(fm_get .orchid/tasks/O.md base_sha)" 'orphan recovery records actual fork point'
[ "$o_base" != "$o_next" ] || fail 'integration actually advanced during crash window'
red_case 'dirty canonical orphan cannot be adopted after a crash'
green_case 'clean canonical orphan retains real fork point after integration advances'
# Review scope and mechanical commands can depend on the requested base..HEAD
# range even when candidate and every version counter remain unchanged.
# A remains explicitly blocked from the earlier recovery-clock probes.
"$ORCHID_BIN" verify A >/dev/null || { fail 'initial exact-range mechanical proof'; exit 1; }
graph_snapshot_file "$ORCHID_REPO" "$WORK/range-old.json" || { fail 'old range snapshot'; exit 1; }
graph_job_binding "$ORCHID_REPO" A "$WORK/range-binding.json" "$WORK/range-old.json" || fail 'old range binding'
jq --arg candidate "$candidate" '. + {task:"A",operation:"review",status:"ok",candidate_sha:$candidate,verdict:"approve",scope_complete:true,findings:[]}' "$WORK/range-binding.json" > "$WORK/range-review.json"
graph_review_evidence_current "$ORCHID_REPO" A "$WORK/range-review.json" "$WORK/range-old.json" || fail 'old review current for its original range'
graph_verify_current "$ORCHID_REPO" A "$WORK/range-old.json" || fail 'old mechanical proof current for its original range'
old_range_base="$(fm_get .orchid/tasks/A.md base_sha)"
broader_base="$(git rev-parse "$old_range_base^")" || { fail 'broader review base'; exit 1; }
cp .orchid/reviews/A-verify.log "$WORK/range-verify.log"
"$ORCHID_BIN" task set A base_sha "$broader_base" >/dev/null || { fail 'public blocked-recovery same-version base correction'; exit 1; }
graph_snapshot_file "$ORCHID_REPO" "$WORK/range-new.json" || { fail 'new range snapshot'; exit 1; }
jq -e --arg candidate "$candidate" --arg base "$broader_base" '.nodes.A.contract_revision == 1 and .nodes.A.execution_generation == 1 and .nodes.A.attempt == 1 and .nodes.A.candidate_sha == $candidate and .nodes.A.base_sha == $base' "$WORK/range-new.json" >/dev/null || fail 'range probe changes only base identity'
# Feed the old proof back explicitly so this checks its binding rather than
# depending on whether the public setter happened to remove stale log files.
cp "$WORK/range-verify.log" .orchid/reviews/A-verify.log
rc=0; graph_review_evidence_current "$ORCHID_REPO" A "$WORK/range-review.json" "$WORK/range-new.json" || rc=$?
[ "$rc" -ne 0 ] || fail 'old narrower review cannot count for a new base range'
rc=0; graph_verify_current "$ORCHID_REPO" A "$WORK/range-new.json" || rc=$?
[ "$rc" -ne 0 ] || fail 'old mechanical graph header cannot count for a new base range'
red_case 'same-version same-candidate evidence cannot cross a changed base range'
"$ORCHID_BIN" verify A >/dev/null || { fail 'fresh broadened range mechanical proof'; exit 1; }
graph_verify_current "$ORCHID_REPO" A "$WORK/range-new.json" || fail 'fresh mechanical header binds current base'
graph_job_binding "$ORCHID_REPO" A "$WORK/range-fresh-binding.json" "$WORK/range-new.json" || fail 'fresh range binding'
jq --arg candidate "$candidate" '. + {task:"A",operation:"review",status:"ok",candidate_sha:$candidate,verdict:"approve",scope_complete:true,findings:[]}' "$WORK/range-fresh-binding.json" > "$WORK/range-fresh-review.json"
graph_review_evidence_current "$ORCHID_REPO" A "$WORK/range-fresh-review.json" "$WORK/range-new.json" || fail 'fresh review binds current broader base'
assert_eq "$broader_base" "$(jq -r .base_sha "$WORK/range-fresh-binding.json")" 'base is canonical input binding rather than worker authority'
green_case 'fresh review and mechanical evidence bind the exact current base and candidate'
[ "$FAILS" -eq 0 ]
