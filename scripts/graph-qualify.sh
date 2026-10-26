#!/usr/bin/env bash
# Explicit, bounded live qualification against disposable synthetic repositories.
# Receipts contain identities/digests/proof booleans, never model text or inputs.
set -uo pipefail
# Git routing must be neutral before the source-checkout gate, too.
while IFS= read -r q_exported; do
  case "$q_exported" in GIT_*) unset "$q_exported" ;; esac
done < <(compgen -e)
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
Q_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORCHID_ROOT="$Q_ROOT"; export ORCHID_ROOT
source "$Q_ROOT/lib/common.sh"
source "$Q_ROOT/lib/frontmatter.sh"
source "$Q_ROOT/lib/manifest.sh"
source "$Q_ROOT/lib/roles.sh"
source "$Q_ROOT/lib/resolver.sh"
source "$Q_ROOT/lib/graph-runtime.sh"
orchid_root_stale_gate

usage() {
  cat <<'HELP'
usage: scripts/graph-qualify.sh --live --engine NAME --output FILE
       [--role implementer|reviewer|all] [--review-engine NAME]
       [--budget-seconds N] [--job-seconds N]

The default role is all, which requires a different review engine and CLI.
The whole invocation is capped at 900 seconds (default); each model job has
a 120-second maximum outer deadline and is never retried. Real CLI authentication must
already work. No credentials, global configuration, or remote Git are changed.
The kernel uses a private HOME; an ephemeral adapter wrapper restores the
existing HOME only before executing the exact selected adapter entrypoint.
Receipts qualify this wrapper profile and its synthetic scenarios, not every
harness integration, model, or production delivery workflow.
HELP
}
Q_LIVE=0; Q_ENGINE=""; Q_REVIEW_ENGINE=""; Q_ROLE=all; Q_OUTPUT=""; Q_BUDGET=900; Q_JOB_SECONDS=120
while [ "$#" -gt 0 ]; do
  case "$1" in
    --live) Q_LIVE=1; shift ;;
    --engine|--review-engine|--role|--output|--budget-seconds|--job-seconds)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --engine) Q_ENGINE="$2" ;; --review-engine) Q_REVIEW_ENGINE="$2" ;;
        --role) Q_ROLE="$2" ;; --output) Q_OUTPUT="$2" ;; --budget-seconds) Q_BUDGET="$2" ;; --job-seconds) Q_JOB_SECONDS="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ "$Q_LIVE" -eq 1 ] && [ -n "$Q_ENGINE" ] && [ -n "$Q_OUTPUT" ] || { usage >&2; exit 2; }
case "$Q_ROLE" in implementer|reviewer|all) ;; *) usage >&2; exit 2 ;; esac
case "$Q_BUDGET" in ''|*[!0-9]*|0*) usage >&2; exit 2 ;; esac
[ "${#Q_BUDGET}" -le 3 ] && [ "$Q_BUDGET" -le 900 ] || { usage >&2; exit 2; }
case "$Q_JOB_SECONDS" in ''|*[!0-9]*|0*) usage >&2; exit 2 ;; esac
[ "${#Q_JOB_SECONDS}" -le 3 ] && [ "$Q_JOB_SECONDS" -le 120 ] || { usage >&2; exit 2; }
if [ "$Q_ROLE" = all ]; then [ -n "$Q_REVIEW_ENGINE" ] || { usage >&2; exit 2; }
elif [ -n "$Q_REVIEW_ENGINE" ]; then usage >&2; exit 2; fi
case "$Q_OUTPUT" in /*) ;; *) Q_OUTPUT="$PWD/$Q_OUTPUT" ;; esac
Q_STARTED="$(date +%s)"; Q_DEADLINE=$(( Q_STARTED + Q_BUDGET ))
Q_REAL_HOME="$HOME"
Q_WORK="$(mktemp -d "${TMPDIR:-/tmp}/orchid-graph-qualify.XXXXXX")" || exit 1
Q_RECORDS="$Q_WORK/records.jsonl"; : > "$Q_RECORDS"
Q_ACTIVE_REPO=""; Q_ACTIVE_JOB=""; Q_KEEP=0; Q_FINISHED=0
Q_SOURCE_BEFORE=""; Q_PRIMARY="$Q_WORK/primary.json"; Q_SECONDARY="$Q_WORK/secondary.json"
Q_REPO=""; Q_EPOCH=""; Q_JOB=""; Q_REPLY=""; Q_IMPL_CANDIDATE=""
Q_FAILURE_DESCRIPTOR=""; Q_FAILURE_ROLE=""
Q_IMPL_PROOF=0; Q_REVIEW_PROOF=0; Q_RESUMED=0; Q_REPLAY=0; Q_DELIVERED=0
Q_FAILURE_REASON=kernel_scenario_refusal; Q_FAILURE_OUTCOME=blocked; Q_ADAPTER_JOBS=0

q_left() { local now; now="$(date +%s)"; printf '%s\n' "$(( Q_DEADLINE - now ))"; }
q_run() (
  trap - EXIT
  local cap="$1" left; shift
  left="$(q_left)"; [ "$left" -gt 0 ] || return 124
  [ "$cap" -le "$left" ] || cap="$left"
  with_timeout "$cap" "$@"
)
q_orchid() { q_run 25 "$Q_ROOT/bin/orchid" "$@"; }
q_git() { q_run 20 git "$@"; }
q_nonce() { head -c 32 /dev/urandom | _orchid_stream_sha256; }
q_source_digest() (
  trap - EXIT
  local path digest
  for path in "${ORCHID_KERNEL_PATHS[@]}" scripts/graph-qualify.sh; do
    if [ -d "$Q_ROOT/$path" ]; then digest="$(plugin_digest_content "$Q_ROOT/$path")" || exit 1
    else digest="$(_orchid_stream_sha256 < "$Q_ROOT/$path")" || exit 1; fi
    printf '%s %s\n' "$path" "$digest"
  done
) # The caller hashes this bounded inventory; paths themselves never enter receipts.
q_record() {
  local scenario="$1" role="$2" descriptor="$3" outcome="$4" reason="$5" proof="${6:-false}" evidence="${7:-}"
  local inputs="" terms="" contract="" envelope=""
  printf 'null\n' > "$Q_WORK/record-context.json"
  if [ -n "$evidence" ] && [ -f "$evidence" ]; then
    inputs="$(jq -cS '.input_revisions' "$evidence" | _orchid_stream_sha256)" || return 1
    terms="$(jq -cS '.contract_terms' "$evidence" | _orchid_stream_sha256)" || return 1
    contract="$(jq -cS '.output_contract' "$evidence" | _orchid_stream_sha256)" || return 1
    envelope="$(_orchid_stream_sha256 < "$evidence")" || return 1
    jq --arg inputs "$inputs" --arg terms "$terms" --arg contract "$contract" --arg envelope "$envelope" \
      '{job_id,task,operation,status,verdict,scope_complete,summary_bytes:(.summary // "" | utf8bytelength),candidate_sha,graph_contract,run_context:{id:.run_context.id,requirements_revision:.run_context.requirements_revision,digest:.run_context.digest},contract_revision,execution_generation,attempt,
        verification_target:(if .verification_target == null then null else .verification_target | {task,base_sha,candidate_sha,contract_revision,execution_generation,attempt,run_context:{id:.run_context.id,requirements_revision:.run_context.requirements_revision,digest:.run_context.digest}} end),
        input_revisions_sha256:$inputs,contract_terms_sha256:$terms,envelope_sha256:$envelope,
        output_contract_sha256:(if .output_contract == null then null else $contract end),
        output_contract_applicable:(.output_contract_evidence.applicable // false),
        artifacts:[(.output_contract_evidence.artifacts // [])[] | {path,git_blob,sha256,bytes}]}' "$evidence" > "$Q_WORK/record-context.json" || return 1
  fi
  jq -cn --arg scenario "$scenario" --arg role "$role" --slurpfile adapter "$descriptor" \
    --slurpfile context "$Q_WORK/record-context.json" --arg outcome "$outcome" --arg reason "$reason" --argjson proof "$proof" \
    '{scenario:$scenario,role:$role,adapter:($adapter[0]|{id,cli,cli_version,adapter_sha256,profile_sha256}),outcome:$outcome,reason:$reason,proof:$proof,evidence:$context[0]}' >> "$Q_RECORDS"
}
q_finish() {
  local rc="${1:-$?}" after="" source_stable=false profiles_stable=true covered=false overall=blocked descriptor
  [ "$Q_FINISHED" -eq 0 ] || return "$rc"
  Q_FINISHED=1
  if [ -n "$Q_ACTIVE_JOB" ] && [ ! -f "$Q_ACTIVE_REPO/.orchid/runtime/exits/$Q_ACTIVE_JOB" ]; then Q_KEEP=1; fi
  if [ -n "$Q_SOURCE_BEFORE" ] && [ "$(q_left)" -gt 0 ]; then
    after="$(q_run 20 q_source_digest 2>> "$Q_WORK/private.log" | _orchid_stream_sha256)" || after=""
    [ "$after" != "$Q_SOURCE_BEFORE" ] || source_stable=true
  fi
  for descriptor in "$Q_PRIMARY" "$Q_SECONDARY"; do
    if [ -f "$descriptor" ] && jq -e '.profile_sha256 != null' "$descriptor" >/dev/null; then
      if ! q_profile_stable "$descriptor"; then profiles_stable=false; fi
    fi
  done
  case "$Q_ROLE" in
    implementer) if [ "$Q_IMPL_PROOF" -eq 1 ] && [ "$Q_ADAPTER_JOBS" -eq 1 ] && jq -es 'any(.[]; .scenario=="implementation" and .outcome=="pass")' "$Q_RECORDS" >/dev/null; then covered=true; fi ;;
    reviewer) if [ "$Q_REVIEW_PROOF" -eq 1 ] && [ "$Q_ADAPTER_JOBS" -eq 1 ] && jq -es 'any(.[]; .scenario=="seeded-defect-review" and .outcome=="pass")' "$Q_RECORDS" >/dev/null; then covered=true; fi ;;
    all)
      if [ "$Q_IMPL_PROOF" -eq 1 ] && [ "$Q_REVIEW_PROOF" -eq 1 ] && [ "$Q_RESUMED" -eq 1 ] && [ "$Q_REPLAY" -eq 1 ] && [ "$Q_DELIVERED" -eq 1 ] && [ "$Q_ADAPTER_JOBS" -eq 4 ] &&
         jq -es '. as $checks | all(["implementation","independent-verifier","source-review","graph-completion","seeded-defect-review"][]; . as $name | any($checks[]; .scenario==$name and .outcome=="pass"))' "$Q_RECORDS" >/dev/null; then covered=true; fi ;;
  esac
  if [ -s "$Q_RECORDS" ] && jq -es 'any(.[]; .outcome=="fail")' "$Q_RECORDS" >/dev/null; then overall=fail; fi
  if [ "$rc" -eq 0 ] && [ "$covered" = true ] && [ -s "$Q_RECORDS" ] && jq -es 'all(.[]; .outcome=="pass")' "$Q_RECORDS" >/dev/null && [ "$source_stable" = true ] && [ "$profiles_stable" = true ] && [ "$Q_KEEP" -eq 0 ]; then overall=pass; fi
  mkdir -p "$(dirname "$Q_OUTPUT")" || return 1
  jq -s --arg outcome "$overall" --arg role "$Q_ROLE" --argjson stable "$source_stable" --argjson profiles "$profiles_stable" \
    --arg source "$Q_SOURCE_BEFORE" --arg version "$ORCHID_VERSION" --argjson budget "$Q_BUDGET" \
    --argjson seconds "$(( $(date +%s) - Q_STARTED ))" --argjson retained "$Q_KEEP" \
    --argjson jobs "$Q_ADAPTER_JOBS" --argjson job_seconds "$Q_JOB_SECONDS" --argjson covered "$covered" \
    --argjson implemented "$Q_IMPL_PROOF" --argjson reviewed "$Q_REVIEW_PROOF" \
    --argjson resumed "$Q_RESUMED" --argjson replay "$Q_REPLAY" --argjson delivered "$Q_DELIVERED" '
    {contract:1,harness:"scripts/graph-qualify.sh",scope:"synthetic graph roles with HOME-restoration adapter wrapper",
     outcome:$outcome,requested_role:$role,orchid_version:$version,source_sha256:$source,source_stable:$stable,profiles_stable:$profiles,
     budget_seconds:$budget,job_deadline_seconds:$job_seconds,elapsed_seconds:$seconds,retries:0,requested_coverage_complete:$covered,adapter_jobs_started:$jobs,retained_unresolved_worker:($retained==1),
     coverage:{fresh_postcommit_program_inputs:($implemented==1),hidden_review_read:($reviewed==1),
       ownership_resume:($resumed==1),replayed_result_refused:($replay==1),accepted_graph_delivery:($delivered==1)},checks:.}
  ' "$Q_RECORDS" > "$Q_WORK/receipt.json" && atomic_write "$Q_OUTPUT" < "$Q_WORK/receipt.json" || return 1
  printf 'graph qualification: %s\n' "$overall"
  if [ "$Q_KEEP" -eq 0 ]; then rm -rf "$Q_WORK"; fi
  [ "$overall" = pass ] || rc=1
  return "$rc"
}
q_exit() {
  local rc=$? finished_rc
  q_finish "$rc"; finished_rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  exit "$finished_rc"
}
trap q_exit EXIT
trap 'exit 130' INT TERM HUP

q_cli_version() {
  local raw version
  raw="$(q_run 3 "$1" --version 2>&1 | head -c 4096)" || return 1
  version="$(printf '%s\n' "$raw" | grep -Eo '[0-9]+([.][0-9]+){1,3}' | head -n1)"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}
q_descriptor() {
  local name="$1" destination="$2" dir id cli="" binary count=0 version digest
  dir="$(resolve_engine_dir "$name" 2>> "$Q_WORK/private.log")" || return 1
  q_run 10 manifest_validate "$dir" >> "$Q_WORK/private.log" 2>&1 || return 1
  id="$(manifest_get "$dir" id)"; digest="$(q_run 10 plugin_digest_content "$dir")" || return 1
  while IFS= read -r binary; do
    case "$binary" in ''|jq|git|bash|sh) continue ;; esac
    cli="$binary"; count=$(( count + 1 ))
  done < <(manifest_get "$dir" requires_binaries | tr ',' '\n')
  [ "$count" -eq 1 ] && command -v "$cli" >/dev/null 2>&1 || return 1
  version="$(q_cli_version "$cli")" || return 1
  jq -cn --arg id "$id" --arg dir "$dir" --arg cli "$cli" --arg version "$version" --arg digest "$digest" \
    '{id:$id,source_dir:$dir,cli:$cli,cli_version:$version,adapter_sha256:$digest,profile_sha256:null}' > "$destination"
}
q_profile_stable() {
  local descriptor="$1" digest version
  digest="$(q_run 10 plugin_digest_content "$(jq -r .source_dir "$descriptor")")" || return 1
  [ "$digest" = "$(jq -r .adapter_sha256 "$descriptor")" ] || return 1
  digest="$(q_run 10 plugin_digest_content "$ORCHID_ENGINES_DIR/$(jq -r .alias "$descriptor")")" || return 1
  [ "$digest" = "$(jq -r .profile_sha256 "$descriptor")" ] || return 1
  version="$(HOME="$Q_REAL_HOME" q_cli_version "$(jq -r .cli "$descriptor")")" || return 1
  [ "$version" = "$(jq -r .cli_version "$descriptor")" ]
}
q_wrap() {
  local descriptor="$1" alias="$2" dir entry quoted_home quoted_entry quoted_common digest
  dir="$(jq -r .source_dir "$descriptor")"; entry="$dir/$(manifest_get "$dir" entrypoint)"
  mkdir -p "$ORCHID_ENGINES_DIR/$alias" || return 1
  cp "$dir/plugin.conf" "$ORCHID_ENGINES_DIR/$alias/plugin.conf" || return 1
  printf -v quoted_home '%q' "$Q_REAL_HOME"; printf -v quoted_entry '%q' "$entry"
  printf -v quoted_common '%q' "$Q_ROOT/lib/common.sh"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nsource %s\n' "$quoted_common"
    cat <<'WRAPPER'
deadline="$(jq -er '.deadline_s | select(type=="number" and floor==. and .>=1 and .<=120)' "$1")"
# The expected hidden read token must never be inline in the actual request/pack.
if [ "$(jq -r .operation "$1")" = review ]; then
  wt="$(jq -er .worktree "$1")"; pack="$(jq -er .input_pack "$1")"
  token="$(cat "$wt/.review-token")"
  [ -n "$token" ] || exit 76
  if grep -Fq -- "$token" "$1"; then exit 76; fi
  for packed in "$pack"/*; do
    [ -f "$packed" ] || continue
    if grep -Fq -- "$token" "$packed"; then exit 76; fi
  done
fi
WRAPPER
    printf '[ "$deadline" -le %s ] || deadline=%s\nif [ "$deadline" -gt 5 ]; then deadline=$((deadline-5)); fi\nexport HOME=%s\nwith_timeout "$deadline" %s "$@"\n' \
      "$Q_JOB_SECONDS" "$Q_JOB_SECONDS" "$quoted_home" "$quoted_entry"
  } > "$ORCHID_ENGINES_DIR/$alias/run"
  chmod 755 "$ORCHID_ENGINES_DIR/$alias/run" || return 1
  digest="$(plugin_digest_content "$ORCHID_ENGINES_DIR/$alias")" || return 1
  jq --arg alias "$alias" --arg digest "$digest" '.alias=$alias | .profile_sha256=$digest' "$descriptor" > "$descriptor.next" || return 1
  mv -f "$descriptor.next" "$descriptor"
}
q_capability() { local have; have="$(manifest_get "$(jq -r .source_dir "$1")" capabilities)"; case ",$have," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }
q_new_repo() {
  local name="$1" review_alias="$2" origin
  origin="$Q_WORK/$name-origin"
  Q_REPO="$Q_WORK/$name-control"
  mkdir -p "$origin" || return 1
  q_git -C "$origin" init -q || return 1
  q_git -C "$origin" config user.name 'Orchid qualification' || return 1
  q_git -C "$origin" config user.email qualification@example.invalid || return 1
  q_git -C "$origin" config core.hooksPath "$Q_WORK/empty-hooks" || return 1
  q_git -C "$origin" config core.attributesfile "$Q_WORK/empty-attributes" || return 1
  q_git -C "$origin" config core.fsmonitor false || return 1
  q_git -C "$origin" config commit.gpgsign false || return 1
  printf 'integration_branch=orchid/integration\nverify=/bin/bash probe-verify.sh\nmerge_gate=/bin/bash probe-verify.sh\nstall_minutes=3\nengine_fail_threshold=99\nworktree_prepare=\n' > "$origin/orchid.config"
  printf 'timeout_minutes=%s\n' "$(( (Q_JOB_SECONDS + 59) / 60 ))" >> "$origin/orchid.config"
  printf 'role.implementer=%s\nrole.reviewer=%s\nreview.low=%s\n' "$(jq -r .alias "$Q_PRIMARY")" "$review_alias" "$review_alias" >> "$origin/orchid.config"
  q_nonce > "$origin/.probe-token"; q_nonce > "$origin/.review-token"
  cat > "$origin/probe-verify.sh" <<'VERIFY'
#!/usr/bin/env bash
set -euo pipefail
work="$(mktemp -d "${TMPDIR:-/tmp}/orchid-fresh-input.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cmp -s .probe-token read-token.txt
for turn in 1 2; do
  nonce="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  a=$(( 16#${nonce:0:4} - 32768 )); b=$(( 16#${nonce:4:4} + 1 ))
  if [ "$turn" = 2 ]; then b=$(( -b )); fi
  jq -cn --arg nonce "$nonce" --argjson a "$a" --argjson b "$b" '{nonce:$nonce,a:$a,b:$b}' > "$work/input.json"
  /bin/bash ./solve.sh "$work/input.json" > "$work/output.json"
  jq -es --slurpfile input "$work/input.json" 'length==1 and .[0].nonce==$input[0].nonce and .[0].sum==($input[0].a+$input[0].b)' "$work/output.json" >/dev/null
done
printf 'fresh postcommit inputs passed\n'
VERIFY
  q_git -C "$origin" add orchid.config .probe-token .review-token probe-verify.sh || return 1
  q_git -C "$origin" -c user.name='Orchid qualification' -c user.email=qualification@example.invalid commit -qm 'synthetic qualification baseline' || return 1
  ORCHID_REPO="$origin" q_orchid init >> "$Q_WORK/private.log" 2>&1 || return 1
  q_git -C "$origin" worktree add -q "$Q_REPO" orchid/integration || return 1
  export ORCHID_REPO="$Q_REPO"
  q_orchid run start > "$Q_WORK/epoch.txt" 2>> "$Q_WORK/private.log" || return 1
  Q_EPOCH="$(awk '$1=="epoch:"{print $2}' "$Q_WORK/epoch.txt")"; ORCHID_EPOCH="$Q_EPOCH"; export ORCHID_EPOCH
  printf 'Synthetic addition and fresh-input qualification only.\n' > "$Q_WORK/requirements.md"
  q_orchid requirements import "$Q_WORK/requirements.md" >> "$Q_WORK/private.log" 2>&1
}
q_reply_file() {
  local file
  for file in "$Q_REPO/.orchid/reviews/"*.json; do
    [ -f "$file" ] || continue
    if jq -e --arg job "$Q_JOB" '.job_id==$job' "$file" >/dev/null; then printf '%s\n' "$file"; return 0; fi
  done
  return 1
}
q_launch() {
  local node="$1" role="$2" operation="$3" alias="$4" deadline now reconcile_rc=0
  Q_REPLY=""; Q_JOB=""; Q_FAILURE_ROLE="$role"; Q_FAILURE_DESCRIPTOR="$Q_PRIMARY"
  if [ "$(jq -r .alias "$Q_SECONDARY")" = "$alias" ]; then Q_FAILURE_DESCRIPTOR="$Q_SECONDARY"; fi
  Q_FAILURE_REASON=insufficient_remaining_job_budget; Q_FAILURE_OUTCOME=not-tested
  [ "$(q_left)" -ge 180 ] || return 124
  Q_FAILURE_REASON=kernel_launch_refused; Q_FAILURE_OUTCOME=blocked
  Q_ACTIVE_REPO="$Q_REPO"; Q_ACTIVE_JOB=unconfirmed-launch
  if ! q_run 25 "$Q_ROOT/runners/orchid-launch" "$node" "$role" "$operation" --engine "$alias" > "$Q_WORK/launch.txt" 2>> "$Q_WORK/private.log"; then
    if q_run 10 orchid_task_jobs_idle "$Q_REPO" "$node" >> "$Q_WORK/private.log" 2>&1; then Q_ACTIVE_JOB=""; Q_ACTIVE_REPO=""; fi
    return 1
  fi
  Q_JOB="$(awk '$1=="launched"{print $2}' "$Q_WORK/launch.txt")"; [ -n "$Q_JOB" ] || return 1
  Q_ADAPTER_JOBS=$(( Q_ADAPTER_JOBS + 1 ))
  Q_ACTIVE_REPO="$Q_REPO"; Q_ACTIVE_JOB="$Q_JOB"; deadline=$(( $(date +%s) + Q_JOB_SECONDS + 15 ))
  Q_FAILURE_REASON=kernel_job_observation_refused
  while [ ! -f "$Q_REPO/.orchid/runtime/exits/$Q_JOB" ]; do
    now="$(date +%s)"
    if [ "$now" -gt "$deadline" ] || [ "$(q_left)" -le 20 ]; then Q_FAILURE_REASON=job_timeout_or_unresolved_exit; return 124; fi
    q_orchid jobs check >> "$Q_WORK/private.log" 2>&1 || return 1
    sleep 1
  done
  Q_ACTIVE_JOB=""; Q_ACTIVE_REPO=""
  Q_FAILURE_REASON=kernel_result_reconciliation_refused
  q_orchid jobs reconcile >> "$Q_WORK/private.log" 2>&1 || reconcile_rc=$?
  Q_REPLY="$(q_reply_file)" || {
    if [ "$reconcile_rc" -eq 0 ]; then Q_FAILURE_REASON=worker_produced_no_current_reply; fi
    return 1
  }
  if ! jq -e '.status=="ok" and .graph_contract==1 and .run_context.id!=""' "$Q_REPLY" >/dev/null; then
    case "$(jq -r .status "$Q_REPLY")" in
      auth) Q_FAILURE_REASON=existing_authentication_unavailable ;;
      rate_limited) Q_FAILURE_REASON=provider_rate_limited ;;
      timeout) Q_FAILURE_REASON=provider_timeout ;;
      *) Q_FAILURE_REASON=worker_output_failed; Q_FAILURE_OUTCOME=fail ;;
    esac
    return 1
  fi
  [ "$reconcile_rc" -eq 0 ]
}

q_review_read() {
  local token="$1"
  if jq -e --arg token "$token" '(.summary // "" | contains($token)) or any(.findings[]?; .title|contains($token))' "$Q_REPLY" >/dev/null; then return 0; fi
  Q_FAILURE_REASON=hidden_review_read_unproved; Q_FAILURE_OUTCOME=fail
  return 1
}

q_review_leak_free() {
  local token="$1" base="$2" candidate="$3" wt="$4" file
  q_git -C "$wt" diff "$base".."$candidate" > "$Q_WORK/review-diff.txt" || return 1
  if LC_ALL=C grep -Fq -- "$token" "$Q_WORK/review-diff.txt"; then return 1; fi
  for file in "$Q_REPO/.orchid/tasks/"*.md "$Q_REPO/.orchid/requirements.md"; do
    [ -f "$file" ] || continue
    if LC_ALL=C grep -Fq -- "$token" "$file"; then return 1; fi
  done
}
q_accept_review() {
  local node="$1"
  if ! jq -e '.verdict=="approve" and .scope_complete==true' "$Q_REPLY" >/dev/null; then
    Q_FAILURE_REASON=current_review_approval_unproved; Q_FAILURE_OUTCOME=fail; return 1
  fi
  Q_FAILURE_REASON=kernel_review_transition_refused; Q_FAILURE_OUTCOME=blocked
  q_orchid task advance "$node" arbitrating --reason 'synthetic current approval' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task arbitrate "$node" --result approve --reason 'synthetic current approval accepted' >> "$Q_WORK/private.log" 2>&1
}

q_implementation_scenario() {
  local reviewer="$1" primary_alias reviewer_alias base wt token verify_before verify_after rc=0
  primary_alias="$(jq -r .alias "$Q_PRIMARY")"; reviewer_alias="$(jq -r .alias "$reviewer")"
  Q_FAILURE_REASON=kernel_scenario_refusal; Q_FAILURE_OUTCOME=blocked
  q_new_repo implementation "$reviewer_alias" || return 1
  q_orchid task create C 'Produce fresh-input addition program' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set C acceptance_criteria 'For review operations, read .review-token and begin REASON with read:<its exact value>, before your explanation, so the proof survives the 200-byte summary limit. Create only solve.sh and read-token.txt. Copy exact .probe-token bytes into read-token.txt using workspace tools. solve.sh receives one JSON filename, reads nonce,a,b and emits exactly one JSON object {nonce:the input nonce,sum:a+b}; use Bash and jq. Do not change probe-verify.sh, hidden tokens, configuration, or .orchid. Reviewers: read hidden .review-token and include REASON: read:<its exact value> in the short reason after reviewing.' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set C verification_commands '/bin/bash probe-verify.sh' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set C output_contract '{"contract":1,"artifacts":[{"path":"solve.sh","min_bytes":1,"max_bytes":16384},{"path":"read-token.txt","min_bytes":64,"max_bytes":65}]}' >> "$Q_WORK/private.log" 2>&1 || return 1
  if [ "$Q_ROLE" = all ]; then
    q_orchid task create V 'Independent fresh-input verification' --archetype review >> "$Q_WORK/private.log" 2>&1 || return 1
    q_orchid task set V verifies C >> "$Q_WORK/private.log" 2>&1 || return 1
    q_orchid task set V acceptance_criteria 'For review operations, read .review-token and begin REASON with read:<its exact value>, before your explanation, so the proof survives the 200-byte summary limit. Independently verify solve.sh echoes arbitrary input nonce and adds a+b, and read-token.txt equals .probe-token. Read hidden .review-token through workspace tools and include REASON: read:<its exact value> in your short reason. Approve only correct code; never edit files.' >> "$Q_WORK/private.log" 2>&1 || return 1
    q_orchid task set V output_contract '{"contract":1,"envelope_schema":{"required":["summary"],"properties":{"summary":{"type":"string","minLength":1}}}}' >> "$Q_WORK/private.log" 2>&1 || return 1
  fi
  q_orchid graph enable --reason 'synthetic qualification' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid plan apply --reason 'synthetic qualification plan' >> "$Q_WORK/private.log" 2>&1 || return 1
  base="$(q_git -C "$Q_REPO" rev-parse orchid/integration)" || return 1
  wt="$Q_WORK/implementation-candidate"
  q_git -C "$Q_REPO" worktree add -q -b task/C "$wt" "$base" || return 1
  q_orchid task set C worktree "$wt" >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set C base_sha "$base" >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task advance C implementing >> "$Q_WORK/private.log" 2>&1 || return 1
  q_launch C implementer implement "$primary_alias" || return 1
  Q_FAILURE_REASON=fresh_postcommit_program_proof_failed; Q_FAILURE_OUTCOME=fail
  Q_IMPL_CANDIDATE="$(q_git -C "$wt" rev-parse HEAD)" || return 1
  verify_before="$(q_git -C "$wt" rev-parse "$base:probe-verify.sh")" || return 1
  verify_after="$(q_git -C "$wt" rev-parse "$Q_IMPL_CANDIDATE:probe-verify.sh")" || return 1
  [ "$verify_before" = "$verify_after" ] || return 1
  q_git -C "$wt" diff --name-only "$base".."$Q_IMPL_CANDIDATE" > "$Q_WORK/changed-files.txt" || return 1
  if grep -Ev '^(solve[.]sh|read-token[.]txt)$' "$Q_WORK/changed-files.txt" >/dev/null; then return 1; fi
  (cd "$wt" && q_run 12 env -i PATH="$PATH" HOME="$HOME" /bin/bash probe-verify.sh) >> "$Q_WORK/private.log" 2>&1 || return 1
  Q_IMPL_PROOF=1
  q_record implementation implementer "$Q_PRIMARY" pass fresh_postcommit_program_inputs true "$Q_REPLY" || return 1
  Q_FAILURE_REASON=kernel_graph_transition_refused; Q_FAILURE_OUTCOME=blocked
  q_orchid task set C candidate_sha "$Q_IMPL_CANDIDATE" >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task advance C testing >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid verify C >> "$Q_WORK/private.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$Q_ROLE" = all ] && [ "$rc" -eq 16 ] || return 1
  fi
  [ "$Q_ROLE" = all ] || return 0
  q_orchid run resume > "$Q_WORK/resume.txt" 2>> "$Q_WORK/private.log" || return 1
  ORCHID_EPOCH="$(awk '$1=="epoch:"{print $2}' "$Q_WORK/resume.txt")"; export ORCHID_EPOCH
  case "$ORCHID_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ORCHID_EPOCH" -gt "$Q_EPOCH" ] || return 1
  Q_RESUMED=1
  token="$(cat "$wt/.review-token")"
  q_review_leak_free "$token" "$base" "$Q_IMPL_CANDIDATE" "$wt" || return 1
  Q_REPLY=""; Q_FAILURE_DESCRIPTOR="$reviewer"; Q_FAILURE_ROLE=reviewer
  Q_FAILURE_REASON=kernel_verifier_preparation_refused; Q_FAILURE_OUTCOME=blocked
  q_run 25 "$Q_ROOT/runners/orchid-graph-prepare" V >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task advance V reviewing >> "$Q_WORK/private.log" 2>&1 || return 1
  q_launch V reviewer review "$reviewer_alias" || return 1
  q_review_read "$token" || return 1
  q_accept_review V || return 1
  Q_REVIEW_PROOF=1
  q_record independent-verifier reviewer "$reviewer" pass bound_candidate_and_hidden_read true "$Q_REPLY" || return 1
  Q_FAILURE_REASON=kernel_replay_fence_refused; Q_FAILURE_OUTCOME=blocked
  cp "$Q_REPLY" "$Q_REPO/.orchid/runtime/spool/qualification-replay.json" || return 1
  q_orchid jobs reconcile > "$Q_WORK/replay.txt" 2>> "$Q_WORK/private.log" || return 1
  grep -Fq 'unknown-job' "$Q_WORK/replay.txt" || return 1
  Q_REPLAY=1
  q_orchid task advance C reviewing >> "$Q_WORK/private.log" 2>&1 || return 1
  q_launch C reviewer review "$reviewer_alias" || return 1
  q_review_read "$token" || return 1
  q_accept_review C || return 1
  q_record source-review reviewer "$reviewer" pass independent_current_source_approval true "$Q_REPLY" || return 1
  Q_FAILURE_REASON=kernel_graph_delivery_refused; Q_FAILURE_OUTCOME=blocked
  q_orchid merge C >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid run advance accepting --reason 'synthetic graph complete' >> "$Q_WORK/private.log" 2>&1 || return 1
  printf 'Synthetic graph qualification: source and independent verifier approved; fresh postcommit program inputs passed.\n' > "$Q_WORK/acceptance.txt"
  q_orchid run accept --reason 'synthetic qualification acceptance' --evidence "$Q_WORK/acceptance.txt" >> "$Q_WORK/private.log" 2>&1 || return 1
  Q_DELIVERED=1
  q_record graph-completion kernel "$reviewer" pass accepted_after_resume_and_replay_fence true || return 1
}

q_negative_review_scenario() {
  local descriptor="$1" alias base candidate wt token
  Q_REPLY=""
  alias="$(jq -r .alias "$descriptor")"
  Q_FAILURE_REASON=kernel_review_scenario_refusal; Q_FAILURE_OUTCOME=blocked
  q_new_repo negative-review "$alias" || return 1
  printf '#!/bin/bash\njq -c ".a + .b" "$1"\n' > "$Q_REPO/add.sh"
  q_git -C "$Q_REPO" add add.sh || return 1
  q_git -C "$Q_REPO" -c user.name='Orchid qualification' -c user.email=qualification@example.invalid commit -qm 'correct fixture arithmetic' || return 1
  base="$(q_git -C "$Q_REPO" rev-parse HEAD)" || return 1
  printf '#!/bin/bash\njq -c ".a - .b" "$1"\n' > "$Q_REPO/add.sh"
  q_git -C "$Q_REPO" add add.sh || return 1
  q_git -C "$Q_REPO" -c user.name='Orchid qualification' -c user.email=qualification@example.invalid commit -qm 'seeded fixture subtraction defect' || return 1
  candidate="$(q_git -C "$Q_REPO" rev-parse HEAD)" || return 1
  q_orchid task create R 'Review seeded arithmetic defect' --archetype review >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set R acceptance_criteria 'For review operations, read .review-token and begin REASON with read:<its exact value>, before your explanation, so the proof survives the 200-byte summary limit. Review add.sh against the requirement to output a+b. Identify any arithmetic defect with a concrete high-severity finding and request changes if wrong. Read hidden .review-token using workspace tools; include REASON: read:<its exact value> in your short reason. Never edit files.' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set R output_contract '{"contract":1,"envelope_schema":{"required":["summary","findings"],"properties":{"summary":{"type":"string","minLength":1},"findings":{"type":"array","minItems":1}}}}' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid graph enable --reason 'synthetic qualification' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set R base_sha "$base" >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task set R candidate_sha "$candidate" >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid plan apply --reason 'synthetic seeded review plan' >> "$Q_WORK/private.log" 2>&1 || return 1
  q_run 25 "$Q_ROOT/runners/orchid-graph-prepare" R >> "$Q_WORK/private.log" 2>&1 || return 1
  q_orchid task advance R reviewing >> "$Q_WORK/private.log" 2>&1 || return 1
  wt="$(fm_get "$Q_REPO/.orchid/tasks/R.md" worktree)"; token="$(cat "$wt/.review-token")"
  q_review_leak_free "$token" "$base" "$candidate" "$wt" || return 1
  q_launch R reviewer review "$alias" || return 1
  q_review_read "$token" || return 1
  Q_FAILURE_REASON=seeded_defect_unproved; Q_FAILURE_OUTCOME=fail
  jq -e '.verdict=="request-changes" and .scope_complete==true and any(.findings[]?; .title|test("subtract|addition|arithmetic|operator|sum|minus|\\.a[[:space:]]*-[[:space:]]*\\.b";"i"))' "$Q_REPLY" >/dev/null || return 1
  Q_REVIEW_PROOF=1
  q_record seeded-defect-review reviewer "$descriptor" pass hidden_read_and_fixture_defect true "$Q_REPLY" || return 1
}

# Resolve installed adapters while existing HOME is still available, then isolate
# all Orchid configuration/roles/templates without copying credentials.
Q_SOURCE_BEFORE="$(q_run 20 q_source_digest 2>> "$Q_WORK/private.log" | _orchid_stream_sha256)" || exit 1
if ! q_descriptor "$Q_ENGINE" "$Q_PRIMARY"; then
  printf '{"id":"unresolved","cli":"unresolved","cli_version":null,"adapter_sha256":null,"profile_sha256":null}\n' > "$Q_PRIMARY"
  q_record preflight "$Q_ROLE" "$Q_PRIMARY" blocked adapter_or_cli_version_unavailable false
  exit 1
fi
if [ "$Q_ROLE" = all ]; then
  if ! q_descriptor "$Q_REVIEW_ENGINE" "$Q_SECONDARY"; then
    q_record preflight reviewer "$Q_PRIMARY" blocked review_adapter_or_cli_version_unavailable false; exit 1
  fi
  if [ "$(jq -r .id "$Q_PRIMARY")" = "$(jq -r .id "$Q_SECONDARY")" ] || [ "$(jq -r .cli "$Q_PRIMARY")" = "$(jq -r .cli "$Q_SECONDARY")" ]; then
    q_record preflight reviewer "$Q_SECONDARY" blocked implementation_cannot_review_itself false; exit 1
  fi
else cp "$Q_PRIMARY" "$Q_SECONDARY"; fi
# Only names are inspected; ambient credential values are neither copied nor
# printed. Kernel configuration and Git routing cannot override the fixture.
Q_KERNEL_VERSION="$ORCHID_VERSION"
Q_EXPORTED_NAMES="$(compgen -e)" || exit 1
while IFS= read -r q_name; do
  case "$q_name" in ORCHID_*|GIT_*) unset "$q_name" ;; esac
done <<< "$Q_EXPORTED_NAMES"
mkdir -p "$Q_WORK/home" "$Q_WORK/engines" "$Q_WORK/git-template" "$Q_WORK/empty-hooks" "$Q_WORK/xdg-config" "$Q_WORK/xdg-cache" "$Q_WORK/xdg-data"
: > "$Q_WORK/empty-attributes"
HOME="$Q_WORK/home"; ORCHID_ENGINES_DIR="$Q_WORK/engines"; ORCHID_ROOT="$Q_ROOT"; ORCHID_VERSION="$Q_KERNEL_VERSION"
ORCHID_OUTPUT=raw; ORCHID_DRYRUN=0
GIT_CONFIG_NOSYSTEM=1; GIT_CONFIG_GLOBAL=/dev/null; GIT_CONFIG_SYSTEM=/dev/null; GIT_TEMPLATE_DIR="$Q_WORK/git-template"
XDG_CONFIG_HOME="$Q_WORK/xdg-config"; XDG_CACHE_HOME="$Q_WORK/xdg-cache"; XDG_DATA_HOME="$Q_WORK/xdg-data"
export HOME ORCHID_ENGINES_DIR ORCHID_ROOT ORCHID_VERSION ORCHID_OUTPUT ORCHID_DRYRUN GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME
unset BASH_ENV ENV
case "$Q_ROLE" in implementer|all)
  if ! role_eligibility_reason implementer "$(jq -r .source_dir "$Q_PRIMARY")" >> "$Q_WORK/private.log" 2>&1 || ! q_capability "$Q_PRIMARY" workspace_read; then
    q_record preflight implementer "$Q_PRIMARY" not-tested declared_implementation_profile_ineligible false; exit 1
  fi ;;
esac
if [ "$Q_ROLE" != implementer ] && ! q_capability "$Q_SECONDARY" workspace_read; then
  q_record preflight reviewer "$Q_SECONDARY" not-tested declared_review_profile_cannot_prove_workspace_read false; exit 1
fi
q_wrap "$Q_PRIMARY" qualification-primary || exit 1
if [ "$Q_ROLE" = all ]; then q_wrap "$Q_SECONDARY" qualification-reviewer || exit 1; else cp "$Q_PRIMARY" "$Q_SECONDARY"; fi
if [ "$Q_ROLE" != reviewer ]; then
  if ! q_implementation_scenario "$Q_SECONDARY"; then
    q_record implementation-graph "${Q_FAILURE_ROLE:-$Q_ROLE}" "${Q_FAILURE_DESCRIPTOR:-$Q_PRIMARY}" "$Q_FAILURE_OUTCOME" "$Q_FAILURE_REASON" false "$Q_REPLY"
  fi
  [ -z "$Q_ACTIVE_JOB" ] || exit 1
fi
if [ "$Q_ROLE" != implementer ]; then
  if ! q_negative_review_scenario "$Q_SECONDARY"; then
    q_record seeded-defect-review reviewer "$Q_SECONDARY" "$Q_FAILURE_OUTCOME" "$Q_FAILURE_REASON" false "$Q_REPLY"
  fi
fi
exit 0
