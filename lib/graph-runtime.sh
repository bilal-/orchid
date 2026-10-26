#!/usr/bin/env bash
# Graph runtime bindings and lifecycle observations. Effect callers own the
# existing verb lock. Libraries never acquire it or replace caller EXIT traps.
if [ "${_ORCHID_GRAPH_RUNTIME_LOADED:-0}" = 1 ]; then return 0; fi
_ORCHID_GRAPH_RUNTIME_LOADED=1
_ORCHID_GRAPH_RUNTIME_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
declare -F orchid_state >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/common.sh"
declare -F fm_json >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/frontmatter.sh"
declare -F manifest_get >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/manifest.sh"
declare -F archetype_validate >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/archetype.sh"
declare -F orchid_json_file_valid >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/json.sh"
declare -F output_contract_validate >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/output-contract.sh"
declare -F graph_snapshot >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/graph.sh"
declare -F orchid_publication_admit >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/publication.sh"

_graph_runtime_fail() { printf 'orchid: graph runtime: %s\n' "$*" >&2; return 1; }
_graph_runtime_workspace_helpers() {
  if ! declare -F drive_worktree_plan >/dev/null || ! declare -F drive_worktree_base >/dev/null; then source "$_ORCHID_GRAPH_RUNTIME_LIB/drive.sh"; fi
  declare -F handoff_worktree_dirty >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/handoff.sh"
}
_graph_runtime_snapshot_helpers() {
  declare -F schedule_split_deps >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/schedule.sh"
}
graph_runtime_enabled() {
  local repo physical file value
  repo="$(orchid_physical_dir "$1")" || return 1
  physical="$repo"; file="$repo/.orchid/roadmap.md"
  _orchid_agent_context_input_owned "$repo" "$physical" .orchid/roadmap.md file || orchid_die 'cannot inspect owned graph_contract'
  [ -f "$file" ] || return 1
  value="$(fm_get "$file" graph_contract)" || orchid_die 'cannot read graph_contract'
  case "$value" in 1) return 0 ;; '') return 1 ;; *) orchid_die "unsupported graph_contract '$value'" ;; esac
}
graph_snapshot_file() (
  trap - EXIT
  gr_repo="$(orchid_physical_dir "$1")" || exit 1
  gr_dest="$2"
  if [ -e "$gr_repo/.orchid/runtime/publication.json" ] || [ -L "$gr_repo/.orchid/runtime/publication.json" ]; then
    _graph_runtime_fail 'interrupted durable publication; resume before reading a graph'; exit 1
  fi
  orchid_publication_admit "$gr_repo" "$(config_get "$gr_repo" integration_branch orchid/integration)" || exit 1
  _graph_runtime_snapshot_helpers
  gr_stage="$(mktemp "${TMPDIR:-/tmp}/orchid-graph-snapshot.XXXXXX")" || exit 1
  trap 'rm -f "$gr_stage"' EXIT
  graph_snapshot "$gr_repo" > "$gr_stage" || exit 1
  orchid_json_file_valid "$gr_stage" || exit 1
  atomic_write "$gr_dest" < "$gr_stage"
)
# Internal setup is called only inside runtime-owned subshell functions.
_graph_runtime_open() {
  gr_repo="$(orchid_physical_dir "$1")" || return 1
  gr_tmp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-graph-runtime.XXXXXX")" || return 1
  trap 'rm -rf "$gr_tmp"' EXIT
  gr_snapshot="${2:-}"
  if [ -z "$gr_snapshot" ]; then
    gr_snapshot="$gr_tmp/snapshot.json"
    graph_snapshot_file "$gr_repo" "$gr_snapshot" || return 1
  fi
  [ -f "$gr_snapshot" ] && [ ! -L "$gr_snapshot" ] || _graph_runtime_fail 'a validated current snapshot file is required'
}
graph_expected_target() {
  _graph_jq '. as $snapshot | target_binding(.;$id) | if . == null then null else . + {run_context:$snapshot.run} end' "$1" -c --arg id "$2"
}
graph_effective_output_contract() {
  _graph_jq 'if $id == "plan" then null else require_node($id) | . as $node | .output_contract |
    if . == null or has("operations") then . else . + {operations:[if $node.outcome == "code" then "implement" else "review" end]} end end' "$1" -c --arg id "$2" > "$3"
}
graph_job_binding() (
  trap - EXIT
  graph_runtime_enabled "$1" || exit 1
  _graph_runtime_open "$1" "${4:-}" || exit 1
  gr_id="$2"; gr_dest="$3"
  graph_effective_output_contract "$gr_snapshot" "$gr_id" "$gr_tmp/output.json" || exit 1
  if [ "$gr_id" = plan ]; then
    jq -n --slurpfile model "$gr_snapshot" '{graph_contract:1,run_context:$model[0].run,contract_revision:1,execution_generation:1,contract_terms:{},input_revisions:{},verification_target:null,output_contract:null}' > "$gr_tmp/binding.json" || exit 1
  else
    graph_terms "$gr_snapshot" "$gr_id" > "$gr_tmp/terms.json" || exit 1
    graph_inputs "$gr_snapshot" "$gr_id" > "$gr_tmp/inputs.json" || exit 1
    graph_expected_target "$gr_snapshot" "$gr_id" > "$gr_tmp/target.json" || exit 1
    _graph_jq '. as $model | require_node($id) | {graph_contract:1,run_context:$model.run,
      contract_revision,execution_generation,attempt,base_sha,contract_terms:$terms[0],input_revisions:$inputs[0],
      verification_target:$target[0],output_contract:$output[0]}' "$gr_snapshot" -c --arg id "$gr_id" \
      --slurpfile terms "$gr_tmp/terms.json" --slurpfile inputs "$gr_tmp/inputs.json" --slurpfile target "$gr_tmp/target.json" --slurpfile output "$gr_tmp/output.json" > "$gr_tmp/binding.json" || exit 1
  fi
  atomic_write "$gr_dest" < "$gr_tmp/binding.json"
)
# Shared comparison for manifests, verification headers and filed envelopes.
_graph_runtime_binding_equal() {
  jq -e --slurpfile expected "$1" '. as $actual | type == "object" and all($expected[0]|to_entries[]; . as $entry | $actual[$entry.key] == $entry.value)' "$2" >/dev/null
}

_graph_runtime_bound() {
  _graph_jq '. as $model | require_node($id) as $node | if $node.verifies == null then true else
    (target_binding($model;$id)+{run_context:$model.run}) as $target |
    $node.verification_target == $target and $node.base_sha == $target.base_sha and $node.candidate_sha == $target.candidate_sha end' "$1" -e --arg id "$2" >/dev/null
}
_graph_runtime_ready() {
  _graph_runtime_checkpoint_admitted "$1" "$2" || return 1
  _graph_jq '. as $model | require_node($id) as $node |
    (["testing","reviewing","arbitrating","merging","done"]|index($node.status)) != null and $node.candidate_sha != "" and $node.base_sha != ""' "$1" -e --arg id "$2" >/dev/null || return 1
  _graph_runtime_bound "$1" "$2"
}
_graph_runtime_commit() {
  case "$2" in ''|*[!0-9a-f]*) return 1 ;; esac
  { [ "${#2}" -eq 40 ] || [ "${#2}" -eq 64 ]; } || return 1
  git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null
}
# Resolve desired immutable input. This reads Git objects but creates nothing.
_graph_runtime_spec() (
  trap - EXIT
  gr_repo="$1"; gr_id="$2"; gr_snapshot="$3"
  gr_node="$(mktemp "${TMPDIR:-/tmp}/orchid-graph-node.XXXXXX")" || exit 1
  gr_target="$(mktemp "${TMPDIR:-/tmp}/orchid-graph-target.XXXXXX")" || { rm -f "$gr_node"; exit 1; }
  trap 'rm -f "$gr_node" "$gr_target"' EXIT
  _graph_jq 'require_node($id)' "$gr_snapshot" -c --arg id "$gr_id" > "$gr_node" || exit 1
  gr_generation="$(jq -r .execution_generation "$gr_node")"
  gr_branch="task/$gr_id"; [ "$gr_generation" -eq 1 ] || gr_branch="$gr_branch-g$gr_generation"
  [ "$(jq -r .branch "$gr_node")" = "$gr_branch" ] || { _graph_runtime_fail "$gr_id records a noncanonical generation branch"; exit 1; }
  graph_expected_target "$gr_snapshot" "$gr_id" > "$gr_target" || exit 1
  gr_verifies="$(jq -r '.verifies // empty' "$gr_node")"
  if jq -e '.candidate_reuse_from != null' "$gr_node" >/dev/null; then _graph_runtime_checkpoint_lineage "$gr_snapshot" "$gr_id" || { _graph_runtime_fail "$gr_id invalid retained checkpoint lineage"; exit 1; }; fi
  gr_base="$(jq -r .base_sha "$gr_node")"; gr_candidate="$(jq -r .candidate_sha "$gr_node")"
  # A crash may leave the canonical registered checkout before binding its
  # base. Recover its real fork point rather than relabeling a newer integration
  # commit as the input to an older checkout. The drive owner decides adoption.
  if [ -z "$gr_verifies" ] && [ -z "$gr_base" ] && [ -z "$gr_candidate" ] && jq -e '.candidate_reuse_from == null' "$gr_node" >/dev/null; then
    _graph_runtime_workspace_helpers
    gr_integration="$(git -C "$gr_repo" rev-parse --verify "$(config_get "$gr_repo" integration_branch orchid/integration)^{commit}")" || exit 1
    gr_plan="$(drive_worktree_plan "$gr_repo" "$gr_id")" || exit 1
    IFS=$'\t' read -r gr_action gr_path <<< "$gr_plan"
    case "$gr_action" in create|adopt|reuse) ;; *) _graph_runtime_fail "$gr_id checkout recovery refused: $gr_path"; exit 1 ;; esac
    gr_base="$(drive_worktree_base "$gr_repo" "$gr_branch" "$gr_integration" "$gr_action")" || exit 1
    if jq -e '.outcome == "report"' "$gr_node" >/dev/null; then gr_candidate="$gr_base"; fi
  fi
  if [ -n "$gr_verifies" ]; then
    _graph_runtime_ready "$gr_snapshot" "$gr_verifies" || { _graph_runtime_fail "$gr_id target $gr_verifies is not candidate-ready/current"; exit 1; }
    gr_kind=verifier
    gr_base="$(jq -r .base_sha "$gr_target")"; gr_candidate="$(jq -r .candidate_sha "$gr_target")"
    jq -e --slurpfile target "$gr_target" '.verification_target == null or .verification_target == $target[0]' "$gr_node" >/dev/null || { _graph_runtime_fail "$gr_id target changed; restart its execution before rebinding"; exit 1; }
    jq -e --arg base "$gr_base" --arg candidate "$gr_candidate" '(.base_sha == "" or .base_sha == $base) and (.candidate_sha == "" or .candidate_sha == $candidate)' "$gr_node" >/dev/null || { _graph_runtime_fail "$gr_id already names another candidate; restart before rebinding"; exit 1; }
  elif jq -e '.candidate_reuse_from != null' "$gr_node" >/dev/null; then
    gr_kind=checkpoint
    [ -n "$gr_base" ] || gr_base="$(jq -r '.candidate_reuse_from.base_sha // empty' "$gr_node")"
    [ -n "$gr_candidate" ] || gr_candidate="$(jq -r '.candidate_reuse_from.candidate_sha // empty' "$gr_node")"
  elif [ "$(jq -r .outcome "$gr_node")" = report ]; then
    gr_kind=report
    [ -n "$gr_candidate" ] || gr_candidate="$(git -C "$gr_repo" rev-parse --verify "$(config_get "$gr_repo" integration_branch orchid/integration)^{commit}")" || exit 1
    [ -n "$gr_base" ] || gr_base="$gr_candidate"
  else
    gr_kind=code
    [ -n "$gr_base" ] || gr_base="$(git -C "$gr_repo" rev-parse --verify "$(config_get "$gr_repo" integration_branch orchid/integration)^{commit}")" || exit 1
  fi
  gr_checkout="$gr_candidate"; [ -n "$gr_checkout" ] || gr_checkout="$gr_base"
  _graph_runtime_commit "$gr_repo" "$gr_checkout" && _graph_runtime_commit "$gr_repo" "$gr_base" || { _graph_runtime_fail "$gr_id has no immutable candidate/base commit"; exit 1; }
  jq -n --arg id "$gr_id" --arg kind "$gr_kind" --arg branch "$gr_branch" --arg base "$gr_base" --arg candidate "$gr_candidate" --arg checkout "$gr_checkout" \
    --slurpfile target "$gr_target" '{id:$id,kind:$kind,branch:$branch,base_sha:$base,candidate_sha:$candidate,checkout_sha:$checkout,verification_target:$target[0]}'
)
# A checkpoint retains immutable candidate lineage, but reserves no active
# slot until the existing active-entry clock owner records its admission.
_graph_runtime_checkpoint_lineage() {
  _graph_jq '
    require_node($id) as $node | $node.candidate_reuse_from as $source |
    ($source|type) == "object" and
    ($source.base_sha|type) == "string" and ($source.base_sha|test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
    ($source.candidate_sha|type) == "string" and ($source.candidate_sha|test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
    ($source.source_generation|type) == "number" and $source.source_generation >= 1 and ($source.source_generation|floor) == $source.source_generation and $source.source_generation < $node.execution_generation and
    ($source.source_contract_revision|type) == "number" and $source.source_contract_revision >= 1 and ($source.source_contract_revision|floor) == $source.source_contract_revision and $source.source_contract_revision <= $node.contract_revision and
    ($source.implementer_engine_id|type) == "string" and
    ($source.source_archive|type) == "string" and ($source.source_archive|test("^\\.orchid/revisions/[A-Za-z0-9_-]+$"))
  ' "$1" -e --arg id "$2" >/dev/null
}
# Retained lineage also accompanies ordinary pending/rework/implementing
# repairs. Only verification/completion phases represent checkpoint admission.
_graph_runtime_checkpoint_stage() {
  _graph_jq 'require_node($id) as $node | $node.candidate_reuse_from != null and (["testing","reviewing","arbitrating","merging","done"] | index($node.status)) != null' "$1" -e --arg id "$2" >/dev/null
}
_graph_runtime_checkpoint_admitted() {
  if ! _graph_runtime_checkpoint_stage "$1" "$2"; then return 0; fi
  _graph_runtime_checkpoint_lineage "$1" "$2" || return 1
  _graph_jq 'require_node($id)|.started_at != "" and (.started_at|started_ok)' "$1" -e --arg id "$2" >/dev/null
}
graph_checkpoint_pending() (
  trap - EXIT
  graph_runtime_enabled "$1" || exit 1
  _graph_runtime_open "$1" "${3:-}" || exit 1
  if _graph_jq 'require_node($id)|.candidate_reuse_from == null' "$gr_snapshot" -e --arg id "$2" >/dev/null; then exit 1; fi
  _graph_runtime_checkpoint_lineage "$gr_snapshot" "$2" || { _graph_runtime_fail "$2 invalid retained checkpoint lineage"; exit 2; }
  _graph_jq 'require_node($id)|(.status == "testing" or .status == "reviewing") and .started_at == ""' "$gr_snapshot" -e --arg id "$2" >/dev/null
)
graph_checkpoint_admit() (
  trap - EXIT
  epoch_require "$1"
  graph_runtime_enabled "$1" || exit 0
  [ "${ORCHID_VERB_LOCK_HELD:-}" = 1 ] || { _graph_runtime_fail 'checkpoint admission requires the existing verb lock'; exit 1; }
  # Reuse the kernel reentrant lock convention; never add an independent lock.
  verb_lock_acquire "$1" || { _graph_runtime_fail 'cannot enter checkpoint admission verb lock'; exit 1; }
  _graph_runtime_open "$1" '' || exit 1
  gr_id="$2"; gr_supplied="${3:-}"
  if [ -n "$gr_supplied" ]; then
    graph_validate "$gr_supplied" || exit 1
    jq -e --arg id "$gr_id" --slurpfile expected "$gr_supplied" '
      .run == $expected[0].run and
      (.nodes[$id] | del(.started_at,.graph_wait)) == ($expected[0].nodes[$id] | del(.started_at,.graph_wait))
    ' "$gr_snapshot" >/dev/null || { _graph_runtime_fail "$gr_id checkpoint admission snapshot is obsolete"; exit 1; }
    graph_inputs "$gr_snapshot" "$gr_id" > "$gr_tmp/current-inputs.json" || exit 1
    graph_inputs "$gr_supplied" "$gr_id" > "$gr_tmp/supplied-inputs.json" || exit 1
    jq -e --slurpfile expected "$gr_tmp/supplied-inputs.json" '. == $expected[0]' "$gr_tmp/current-inputs.json" >/dev/null || { _graph_runtime_fail "$gr_id checkpoint input snapshot is obsolete"; exit 1; }
  fi
  if ! _graph_runtime_checkpoint_stage "$gr_snapshot" "$gr_id"; then exit 0; fi
  _graph_runtime_checkpoint_lineage "$gr_snapshot" "$gr_id" || { _graph_runtime_fail "$gr_id invalid retained checkpoint lineage"; exit 1; }
  if _graph_runtime_checkpoint_admitted "$gr_snapshot" "$gr_id"; then exit 0; fi
  graph_checkpoint_pending "$gr_repo" "$gr_id" "$gr_snapshot" || { _graph_runtime_fail "$gr_id is not awaiting checkpoint admission"; exit 1; }
  _graph_runtime_snapshot_helpers
  gr_blockers="$(schedule_dispatch_blockers "$gr_repo" "$gr_id")" || exit 1
  [ -z "$gr_blockers" ] || { _graph_runtime_fail "$gr_id checkpoint admission waits: $gr_blockers"; exit 1; }
  ORCHID_REPO="$gr_repo" "$ORCHID_ROOT/bin/orchid" journal add --task "$gr_id" --kind graph_checkpoint_admission 'retained candidate admitted after current inputs and capacity' >/dev/null || exit 1
  orchid_task_start_clock "$gr_repo/.orchid/tasks/$gr_id.md"
)
graph_dispatch_ready() (
  trap - EXIT
  graph_runtime_enabled "$1" || exit 0
  _graph_runtime_open "$1" "${3:-}" || exit 1
  _graph_runtime_dependencies_ready "$gr_snapshot" "$2" || exit 1
  _graph_jq 'require_node($id) | .verifies == null and .candidate_reuse_from == null and .outcome == "code"' "$gr_snapshot" -e --arg id "$2" >/dev/null && exit 0
  _graph_runtime_spec "$gr_repo" "$2" "$gr_snapshot" >/dev/null
)
graph_job_workspace() (
  trap - EXIT
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"; gr_operation="${4:-review}"; gr_point="${5:-}"
  if [ "$gr_id" = plan ]; then printf '%s\n' "$gr_repo"; exit 0; fi
  _graph_runtime_workspace_helpers
  _graph_runtime_spec "$gr_repo" "$gr_id" "$gr_snapshot" > "$gr_tmp/spec.json" || exit 1
  gr_plan="$(drive_worktree_plan "$gr_repo" "$gr_id")" || exit 1
  IFS=$'\t' read -r gr_action gr_path <<< "$gr_plan"
  case "$gr_action" in reuse) ;; *) _graph_runtime_fail "$gr_id needs a bound owned generation checkout: $gr_path"; exit 1 ;; esac
  if [ "$gr_operation" = implement ] && _graph_jq 'require_node($id)|.outcome == "code" and .verifies == null' "$gr_snapshot" -e --arg id "$gr_id" >/dev/null; then
    printf '%s\n' "$gr_path"; exit 0
  fi
  gr_head="$(git -C "$gr_path" rev-parse HEAD)" || exit 1
  [ "$gr_head" = "$(jq -r .checkout_sha "$gr_tmp/spec.json")" ] || { _graph_runtime_fail "$gr_id checkout HEAD differs from its pinned candidate"; exit 1; }
  gr_dirty="$(handoff_worktree_dirty "$gr_path")" || exit 1
  [ -z "$gr_dirty" ] || { _graph_runtime_fail "$gr_id checkout contains uncommitted work: $gr_dirty"; exit 1; }
  if [ "$(jq -r .kind "$gr_tmp/spec.json")" = verifier ]; then _graph_runtime_bound "$gr_snapshot" "$gr_id" || { _graph_runtime_fail "$gr_id verification target is unbound or obsolete"; exit 1; }; fi
  printf '%s\n' "$gr_path"
)
_graph_runtime_operation_ready() {
 case "$3" in
  implement)
   [ "$2" != plan ] || return 1
   _graph_jq 'require_node($id) as $node | $node.outcome == "code" and $node.verifies == null and (["pending","rework","implementing"] | index($node.status)) != null' "$1" -e --arg id "$2" >/dev/null ;;
  review|critique|hook|verify|merge) return 0 ;;
  *) return 1 ;;
 esac
}
graph_job_prepare_gate() (
 trap - EXIT
 _graph_runtime_open "$1" "${3:-}" || exit 1
 gr_id="$2"; gr_operation="${4:-review}"; gr_point="${5:-}"; gr_ignore_job="${6:-}"
 [ "$gr_id" = plan ] || _graph_runtime_dependencies_ready "$gr_snapshot" "$gr_id" || { _graph_runtime_fail "$gr_id waits current done dependencies"; exit 1; }
 _graph_runtime_operation_ready "$gr_snapshot" "$gr_id" "$gr_operation" || { _graph_runtime_fail "$gr_id cannot start $gr_operation in its current phase"; exit 1; }
 if [ "$gr_id" != plan ]; then _graph_runtime_checkpoint_admitted "$gr_snapshot" "$gr_id" || { _graph_runtime_fail "$gr_id checkpoint is not admitted"; exit 1; }; fi
 gr_path="$(graph_job_workspace "$gr_repo" "$gr_id" "$gr_snapshot" "$gr_operation" "$gr_point")" || exit 1
 [ "$gr_id" != plan ] || exit 0
 if [ "$gr_operation" = implement ]; then
  gr_idle="$(orchid_task_jobs_idle "$gr_repo" "$gr_id" "$gr_ignore_job")" || { _graph_runtime_fail "$gr_idle"; exit 1; }
  _graph_runtime_workspace_helpers
  gr_dirty="$(handoff_worktree_dirty "$gr_path")" || exit 1
  [ -z "$gr_dirty" ] || { _graph_runtime_fail "$gr_id implementation starts uncommitted work"; exit 1; }
 fi
 case "$gr_operation" in verify|merge)
  gr_idle="$(orchid_task_jobs_idle "$gr_repo" "$gr_id")" || { _graph_runtime_fail "$gr_idle"; exit 1; } ;;
 esac
)
graph_manifest_current() (
  trap - EXIT
  graph_runtime_enabled "$1" || exit 1
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_manifest="$2"
  orchid_json_file_valid "$gr_manifest" || exit 1
  gr_id="$(jq -er '.task|select(type == "string")' "$gr_manifest")" || exit 1
  gr_operation="$(jq -er '.operation|select(type == "string")' "$gr_manifest")" || exit 1
  gr_point="$(jq -r '.hook_point // ""' "$gr_manifest")" || exit 1
  jq -e '.start_head_sha | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")' "$gr_manifest" >/dev/null || exit 1
  graph_job_binding "$gr_repo" "$gr_id" "$gr_tmp/binding.json" "$gr_snapshot" || exit 1
  _graph_runtime_binding_equal "$gr_tmp/binding.json" "$gr_manifest" || exit 1
  gr_path="$(graph_job_workspace "$gr_repo" "$gr_id" "$gr_snapshot" "$gr_operation" "$gr_point")" || exit 1
  jq -e --arg path "$gr_path" '.worktree == $path' "$gr_manifest" >/dev/null || exit 1
  if [ "$gr_id" != plan ]; then
    jq -e --slurpfile model "$gr_snapshot" --arg id "$gr_id" '.base_sha == $model[0].nodes[$id].base_sha and .candidate_sha == $model[0].nodes[$id].candidate_sha' "$gr_manifest" >/dev/null || exit 1
  fi
)
graph_bind() (
  trap - EXIT
  epoch_require "$1"
  graph_runtime_enabled "$1" || exit 1
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"; gr_file="$gr_repo/.orchid/tasks/$gr_id.md"
  _graph_runtime_workspace_helpers
  _graph_runtime_spec "$gr_repo" "$gr_id" "$gr_snapshot" > "$gr_tmp/spec.json" || exit 1
  gr_plan="$(drive_worktree_plan "$gr_repo" "$gr_id")" || exit 1
  IFS=$'\t' read -r gr_action gr_path <<< "$gr_plan"
  case "$gr_action" in reuse|adopt) ;; *) _graph_runtime_fail "$gr_id prepared checkout is absent or unsafe: $gr_path"; exit 1 ;; esac
  gr_dirty="$(handoff_worktree_dirty "$gr_path")" || exit 1
  [ -z "$gr_dirty" ] || { _graph_runtime_fail "$gr_id prepared checkout is dirty: $gr_dirty"; exit 1; }
  if _graph_runtime_checkpoint_stage "$gr_snapshot" "$gr_id"; then
    [ "$(git -C "$gr_path" rev-parse HEAD)" = "$(jq -r .checkout_sha "$gr_tmp/spec.json")" ] || { _graph_runtime_fail "$gr_id checkpoint differs from its immutable candidate"; exit 1; }
    graph_checkpoint_admit "$gr_repo" "$gr_id" "$gr_snapshot" || exit 1
  fi
  if jq -e --slurpfile model "$gr_snapshot" --arg id "$gr_id" --arg path "$gr_path" '. as $spec | $model[0].nodes[$id] | .worktree == $path and .base_sha == $spec.base_sha and .candidate_sha == $spec.candidate_sha and .verification_target == $spec.verification_target' "$gr_tmp/spec.json" >/dev/null; then
    if _graph_jq 'require_node($id)|.outcome == "code" and .verifies == null and (.status == "pending" or .status == "rework" or .status == "implementing")' "$gr_snapshot" -e --arg id "$gr_id" >/dev/null; then exit 0; fi
    [ "$(git -C "$gr_path" rev-parse HEAD)" = "$(jq -r .checkout_sha "$gr_tmp/spec.json")" ] || { _graph_runtime_fail "$gr_id bound checkout differs from its frozen candidate"; exit 1; }
    exit 0
  fi
  [ "$(git -C "$gr_path" rev-parse HEAD)" = "$(jq -r .checkout_sha "$gr_tmp/spec.json")" ] || { _graph_runtime_fail "$gr_id prepared checkout is not the expected candidate"; exit 1; }
  gr_idle="$(orchid_task_jobs_idle "$gr_repo" "$gr_id")" || { _graph_runtime_fail "$gr_idle"; exit 1; }
  ORCHID_REPO="$gr_repo" "$ORCHID_ROOT/bin/orchid" journal add --task "$gr_id" --kind graph_binding 'bound canonical generation checkout to immutable graph input' >/dev/null || exit 1
  fm_set "$gr_file" worktree "$gr_path" || exit 1
  fm_set "$gr_file" base_sha "$(jq -r .base_sha "$gr_tmp/spec.json")" || exit 1
  fm_set "$gr_file" candidate_sha "$(jq -r .candidate_sha "$gr_tmp/spec.json")" || exit 1
  if [ "$(jq -r .kind "$gr_tmp/spec.json")" = verifier ]; then fm_set "$gr_file" verification_target "$(jq -c .verification_target "$gr_tmp/spec.json")" || exit 1; fi
)

graph_required_blockers() (
  trap - EXIT
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"
  graph_required "$gr_snapshot" "$gr_id" > "$gr_tmp/required" || exit 1
  while IFS= read -r gr_child; do
    [ -n "$gr_child" ] || continue
    if ! _graph_jq 'require_node($id)|.status == "done"' "$gr_snapshot" -e --arg id "$gr_child" >/dev/null; then
      printf 'waiting-verifier (%s)\n' "$gr_child"
    elif ! _graph_runtime_bound "$gr_snapshot" "$gr_child"; then
      printf 'obsolete-verifier (%s)\n' "$gr_child"
    fi
  done < "$gr_tmp/required"
)
graph_completion_ready() (
 trap - EXIT
 graph_runtime_enabled "$1" || exit 0
 _graph_runtime_open "$1" "${3:-}" || exit 1
 gr_id="$2"
 _graph_runtime_bound "$gr_snapshot" "$gr_id" || { _graph_runtime_fail "$gr_id verification target obsolete"; exit 1; }
 gr_blockers="$(graph_required_blockers "$gr_repo" "$gr_id" "$gr_snapshot")" || exit 1
 [ -z "$gr_blockers" ] || { _graph_runtime_fail "$gr_id: $gr_blockers"; exit 1; }
 gr_idle="$(orchid_task_jobs_idle "$gr_repo" "$gr_id")" || { _graph_runtime_fail "$gr_idle"; exit 1; }
 graph_required "$gr_snapshot" "$gr_id" > "$gr_tmp/required.ids" || exit 1
 while IFS= read -r gr_child; do
  gr_idle="$(orchid_task_jobs_idle "$gr_repo" "$gr_child")" || { _graph_runtime_fail "$gr_idle"; exit 1; }
 done < "$gr_tmp/required.ids"
 graph_effective_output_contract "$gr_snapshot" "$gr_id" "$gr_tmp/output.json" || exit 1
 gr_primary="$(jq -r --arg id "$gr_id" 'if .nodes[$id].outcome == "code" then "implement" else "review" end' "$gr_snapshot")" || exit 1
 if jq -e --arg op "$gr_primary" '. != null and ((.operations | index($op)) != null or (.operations | index("review")) != null)' "$gr_tmp/output.json" >/dev/null; then
  gr_candidate="$(jq -r --arg id "$gr_id" '.nodes[$id].candidate_sha' "$gr_snapshot")" || exit 1
  gr_definition="$(cat "$gr_tmp/output.json")" || exit 1
  output_contract_artifacts "$gr_repo" "$gr_candidate" "$gr_definition" > "$gr_tmp/artifacts.json" || { _graph_runtime_fail "$gr_id committed output artifacts do not satisfy their contract"; exit 1; }
 fi
)
graph_review_evidence_current() (
 trap - EXIT
 _graph_runtime_open "$1" "${4:-}" || exit 1
 gr_id="$2"; gr_evidence="$3"
 orchid_json_file_valid "$gr_evidence" || exit 1
 graph_job_binding "$gr_repo" "$gr_id" "$gr_tmp/expected.json" "$gr_snapshot" || exit 1
 _graph_runtime_binding_equal "$gr_tmp/expected.json" "$gr_evidence" || exit 1
 gr_candidate="$(jq -r --arg id "$gr_id" '.nodes[$id].candidate_sha' "$gr_snapshot")" || exit 1
 jq -e --arg id "$gr_id" --arg candidate "$gr_candidate" '.task == $id and .operation == "review" and .status == "ok" and .candidate_sha == $candidate' "$gr_evidence" >/dev/null || exit 1
 graph_effective_output_contract "$gr_snapshot" "$gr_id" "$gr_tmp/output.json" || exit 1
 if jq -e '. != null and (.operations | index("review")) != null' "$gr_tmp/output.json" >/dev/null; then
  gr_definition="$(cat "$gr_tmp/output.json")" || exit 1
  if jq -e '.contract_failure.contract == 1 and .contract_failure.passed == false and .contract_failure.kind == "artifact" and .verdict == "request-changes"' "$gr_evidence" >/dev/null; then exit 0; fi
  output_contract_artifacts "$gr_repo" "$gr_candidate" "$gr_definition" > "$gr_tmp/artifacts.json" || exit 1
  gr_normalized="$(output_contract_validate "$gr_definition")" || exit 1
  gr_contract_hash="$(printf '%s' "$gr_normalized" | _orchid_stream_sha256)" || exit 1
  jq -e --arg candidate "$gr_candidate" --arg contract_hash "$gr_contract_hash" --slurpfile artifacts "$gr_tmp/artifacts.json" '.output_contract_evidence as $e | $e.contract == 1 and $e.passed == true and $e.applicable == true and $e.scope == "full" and $e.envelope_checked == true and ($e.envelope_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and $e.candidate_sha == $candidate and $e.contract_sha256 == $contract_hash and $e.artifacts == $artifacts[0].artifacts' "$gr_evidence" >/dev/null || exit 1
 fi
)
graph_verify_current() (
  trap - EXIT
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"; gr_log="$gr_repo/.orchid/reviews/$gr_id-verify.log"
  _graph_runtime_workspace_helpers
  [ -f "$gr_log" ] && [ ! -L "$gr_log" ] || exit 1
  [ "$(tail -n 1 "$gr_log")" = 'exit: 0' ] || exit 1
  gr_candidate="$(jq -r --arg id "$gr_id" '.nodes[$id].candidate_sha' "$gr_snapshot")" || exit 1
  [ -n "$gr_candidate" ] || exit 1
  for gr_key in sha head_after candidate; do
    [ "$(_drive_verify_header_value "$gr_log" "$gr_key")" = "$gr_candidate" ] || exit 1
  done
  gr_command="$(jq -r --arg id "$gr_id" '.nodes[$id].verification_commands' "$gr_snapshot")" || exit 1
  [ -n "$gr_command" ] || gr_command="$(config_get "$gr_repo" verify)"
  [ "$(_drive_verify_header_value "$gr_log" command)" = "$gr_command" ] || exit 1
  gr_header="$(_drive_verify_header_value "$gr_log" graph_binding)" || exit 1
  printf '%s\n' "$gr_header" > "$gr_tmp/header.json"
  orchid_json_file_valid "$gr_tmp/header.json" || exit 1
  graph_job_binding "$gr_repo" "$gr_id" "$gr_tmp/expected.json" "$gr_snapshot" || exit 1
  _graph_runtime_binding_equal "$gr_tmp/expected.json" "$gr_tmp/header.json" || exit 1
  gr_path="$(graph_job_workspace "$gr_repo" "$gr_id" "$gr_snapshot" verify)" || exit 1
  gr_logged_path="$(orchid_physical_dir "$(_drive_verify_header_value "$gr_log" cwd)")" || exit 1
  [ "$gr_logged_path" = "$gr_path" ]
)
graph_node_work_complete() (
  trap - EXIT
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"
  gr_idle="$(orchid_task_jobs_idle "$gr_repo" "$gr_id")" || exit 1
  if _graph_jq 'require_node($id)|.outcome == "code"' "$gr_snapshot" -e --arg id "$gr_id" >/dev/null; then
    graph_verify_current "$gr_repo" "$gr_id" "$gr_snapshot"; exit $?
  fi
  declare -F envelope_field >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/envelope.sh"
  declare -F review_required_count >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/review.sh"
  gr_attempt="$(jq -r --arg id "$gr_id" '.nodes[$id].attempt' "$gr_snapshot")"
  gr_candidate="$(jq -r --arg id "$gr_id" '.nodes[$id].candidate_sha' "$gr_snapshot")"
  gr_need="$(review_required_count "$(jq -r --arg id "$gr_id" '.nodes[$id].risk_tier' "$gr_snapshot")")"
  graph_job_binding "$gr_repo" "$gr_id" "$gr_tmp/expected.json" "$gr_snapshot" || exit 1
  gr_have=0
  for gr_evidence in "$gr_repo/.orchid/reviews/$gr_id-a$gr_attempt-reviewer"*.json; do
    [ -f "$gr_evidence" ] && [ ! -L "$gr_evidence" ] || continue
    graph_review_evidence_current "$gr_repo" "$gr_id" "$gr_evidence" "$gr_snapshot" || continue
    gr_have=$((gr_have+1))
  done
  [ "$gr_have" -ge "$gr_need" ] && [ -n "$gr_candidate" ]
)

# One owner interprets wait annotations. Budget observation calls no job CLI,
# graph snapshot or process-liveness classifier. Invalid/stale annotations grant
# no discount. The additional contract revision guards same-candidate edits.
_graph_runtime_wait_view() (
  trap - EXIT
  set -o pipefail
  fm_json "$(orchid_state "$1")/tasks/$2.md" | _graph_jq '
    . as $raw | object_field($raw;"graph_wait") as $wait |
    number_field($raw;"contract_revision";1;false;999999;false) as $cv |
    number_field($raw;"execution_generation";1;false;999999;false) as $generation |
    (number_field($raw;"attempts";0;true;999999;true)+1) as $attempt |
    text($raw;"candidate_sha";"") as $candidate |
    if $wait != null and ($wait|wait_ok) and $wait.contract_revision == $cv
      and $wait.generation == $generation and $wait.attempt == $attempt
    then ($wait.candidate_sha == $candidate) as $same |
      $wait + {candidate_sha:$candidate,same_candidate:$same,
        started_at:(if $same then $wait.started_at else 0 end),
        total_seconds:([$wait.seconds + (if $same and $wait.started_at > 0 then [($now-$wait.started_at),0]|max else 0 end),9007199254740991]|min)}
    else null end
  ' - -c --argjson now "$3"
)
graph_budget_pause() (
  trap - EXIT
  graph_runtime_enabled "$1" || { printf '0\n'; exit 0; }
  case "$3" in ''|*[!0-9]*) printf '0\n'; exit 0 ;; esac
  gr_wait="$(_graph_runtime_wait_view "$1" "$2" "$3")" || { printf '0\n'; exit 0; }
  printf '%s\n' "$gr_wait" | jq -r 'if . == null then 0 else .total_seconds end'
)
graph_wait_seconds() { graph_budget_pause "$1" "$2" "$3"; }
graph_wait_close() (
  trap - EXIT
  epoch_require "$1"
  graph_runtime_enabled "$1" || exit 0
  gr_file="$(orchid_state "$1")/tasks/$2.md"
  gr_raw="$(fm_get "$gr_file" graph_wait)" || exit 1
  [ -n "$gr_raw" ] || exit 0
  gr_wait="$(_graph_runtime_wait_view "$1" "$2" "$(date +%s)")" || exit 1
  if [ "$gr_wait" = null ]; then fm_set "$gr_file" graph_wait ''; exit $?; fi
  if printf '%s\n' "$gr_wait" | jq -e '.started_at == 0 and .same_candidate == true' >/dev/null; then exit 0; fi
  gr_closed="$(printf '%s\n' "$gr_wait" | jq -c '.seconds=.total_seconds | .started_at=0 | del(.total_seconds,.same_candidate)')" || exit 1
  fm_set "$gr_file" graph_wait "$gr_closed"
)
graph_wait_sync() (
  trap - EXIT
  epoch_require "$1"
  graph_runtime_enabled "$1" || exit 0
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"
  gr_blockers="$(graph_required_blockers "$gr_repo" "$gr_id" "$gr_snapshot")" || exit 1
  if [ -z "$gr_blockers" ] || ! graph_node_work_complete "$gr_repo" "$gr_id" "$gr_snapshot"; then graph_wait_close "$gr_repo" "$gr_id"; exit $?; fi
  gr_now="$(date +%s)"
  gr_current="$(_graph_runtime_wait_view "$gr_repo" "$gr_id" "$gr_now")" || exit 1
  if [ "$gr_current" != null ] && [ "$(printf '%s\n' "$gr_current" | jq -r .started_at)" -gt 0 ]; then exit 0; fi
  if [ "$gr_current" = null ]; then gr_seconds=0; else gr_seconds="$(printf '%s\n' "$gr_current" | jq -r .seconds)"; fi
  gr_note="$(_graph_jq 'require_node($id)|{started_at:$now,seconds:$seconds,candidate_sha,contract_revision,generation:.execution_generation,attempt}' "$gr_snapshot" -c --arg id "$gr_id" --argjson now "$gr_now" --argjson seconds "$gr_seconds")" || exit 1
  fm_set "$gr_repo/.orchid/tasks/$gr_id.md" graph_wait "$gr_note"
)
graph_wait_exempts() (
  trap - EXIT
  _graph_runtime_open "$1" "${4:-}" || exit 1
  gr_waiter="$2"; gr_requester="$3"
  _graph_jq 'require_node($id) as $node|(["testing","reviewing","arbitrating","merging"]|index($node.status)) != null' "$gr_snapshot" -e --arg id "$gr_waiter" >/dev/null || exit 1
  graph_required "$gr_snapshot" "$gr_waiter" > "$gr_tmp/required" || exit 1
  grep -Fx "$gr_requester" "$gr_tmp/required" >/dev/null || exit 1
  gr_wait="$(_graph_runtime_wait_view "$gr_repo" "$gr_waiter" "$(date +%s)")" || exit 1
  [ "$gr_wait" != null ] && [ "$(printf '%s\n' "$gr_wait" | jq -r .started_at)" -gt 0 ] || exit 1
  graph_node_work_complete "$gr_repo" "$gr_waiter" "$gr_snapshot" || exit 1
  gr_blockers="$(graph_required_blockers "$gr_repo" "$gr_waiter" "$gr_snapshot")" || exit 1
  [ -n "$gr_blockers" ]
)
_graph_runtime_dependencies_ready() {
  _graph_jq '. as $model | require_node($id) | all(.depends_on[]; . as $dep | $model.nodes[$dep].status == "done")' "$1" -e --arg id "$2" >/dev/null
}
graph_enable() (
  trap - EXIT
  gr_repo="$(orchid_physical_dir "$1")" || exit 1
  gr_reason="$2"
  [ "${ORCHID_ACTOR:-operator}" = operator ] || { _graph_runtime_fail 'graph enable is operator-owned'; exit 1; }
  [ -n "$gr_reason" ] || { _graph_runtime_fail 'enable requires a reason'; exit 1; }
  case "$gr_reason" in *$'\n'*) _graph_runtime_fail 'enable reason must be single-line'; exit 1 ;; esac
  epoch_require "$gr_repo"
  if graph_runtime_enabled "$gr_repo"; then printf 'graph already enabled\n'; exit 0; fi
  [ "$(fm_get "$gr_repo/.orchid/roadmap.md" run_status)" = planning ] || { _graph_runtime_fail 'enable requires planning before execution'; exit 1; }
  gr_preimage_file="$(mktemp "${TMPDIR:-/tmp}/orchid-graph-enable.XXXXXX")" || exit 1
  trap 'rm -f "$gr_preimage_file"' EXIT
  orchid_publication_capture "$gr_repo" .orchid/tasks .orchid/requirements.md .orchid/roadmap.md .orchid/journal.md > "$gr_preimage_file" || exit 1
  _graph_runtime_open "$gr_repo" '' || { rm -f "$gr_preimage_file"; exit 1; }
  mv "$gr_preimage_file" "$gr_tmp/preimages.json" || exit 1
  jq -e 'all(.nodes[]; .status == "pending" and .attempts == 0 and .candidate_sha == "" and .worktree == "")' "$gr_snapshot" >/dev/null || { _graph_runtime_fail 'enable requires pending unstarted tasks'; exit 1; }
  gr_jobs="$(ORCHID_REPO="$gr_repo" "$ORCHID_ROOT/bin/orchid" jobs ls --tsv --strict)" || exit 1
  [ -z "$gr_jobs" ] || { _graph_runtime_fail 'retire outstanding jobs before enabling graph mode'; exit 1; }
  _graph_enable_hook() {
    local wt="$1"
    orchid_publication_preimages_match "$wt" "$(cat "$gr_tmp/preimages.json")" || return 1
    mkdir -p "$wt/.orchid/runtime" || return 1
    printf '%s\n' "$ORCHID_EPOCH" > "$wt/.orchid/runtime/epoch" || return 1
    ORCHID_REPO="$wt" "$ORCHID_ROOT/bin/orchid" journal add --kind graph_enable "$gr_reason" >/dev/null || return 1
    rm -rf "$wt/.orchid/runtime"
    fm_set "$wt/.orchid/roadmap.md" graph_contract 1 || return 1
    if ! fm_has "$wt/.orchid/roadmap.md" requirements_revision; then fm_set "$wt/.orchid/roadmap.md" requirements_revision 1 || return 1; fi
    _graph_runtime_snapshot_helpers
    graph_snapshot "$wt" > "$gr_tmp/staged.json" || return 1
    graph_validate "$gr_tmp/staged.json" || return 1
  }
  # ShellCheck rationale: orchid_commit_durable invokes the hook by name.
  # shellcheck disable=SC2034
  ORCHID_COMMIT_DURABLE_HOOK=_graph_enable_hook
  ORCHID_COMMIT_DURABLE_RECOVERABLE=1 orchid_commit_durable "$gr_repo" 'orchid: enable graph contract' .orchid/tasks .orchid/requirements.md .orchid/roadmap.md .orchid/journal.md || exit 1
  printf 'graph enabled\n'
)

# Filed results carry trusted input bindings, but implement candidate_sha is an
# OUTPUT and must be checked against owned HEAD rather than old task metadata.
graph_result_current() (
  trap - EXIT
  graph_runtime_enabled "$1" || exit 1
  _graph_runtime_open "$1" "${4:-}" || exit 1
  gr_id="$2"; gr_evidence="$3"
  orchid_json_file_valid "$gr_evidence" || exit 1
  graph_job_binding "$gr_repo" "$gr_id" "$gr_tmp/expected.json" "$gr_snapshot" || exit 1
  _graph_runtime_binding_equal "$gr_tmp/expected.json" "$gr_evidence" || exit 1
  jq -e --arg id "$gr_id" '.task == $id and (.worktree|type) == "string"' "$gr_evidence" >/dev/null || exit 1
  gr_operation="$(jq -r .operation "$gr_evidence")" || exit 1
  gr_kind="$(jq -r '.contract_failure.kind // ""' "$gr_evidence")" || exit 1
  if [ "$gr_operation" = implement ] && { [ "$gr_kind" = candidate ] || [ "$gr_kind" = definition ]; }; then
    jq -e '.status == "failed" and .contract_failure.contract == 1 and .contract_failure.passed == false' "$gr_evidence" >/dev/null
    exit $?
  fi
  gr_path="$(graph_job_workspace "$gr_repo" "$gr_id" "$gr_snapshot" "$gr_operation" "$(jq -r '.hook_point // ""' "$gr_evidence")")" || exit 1
  jq -e --arg path "$gr_path" '.worktree == $path' "$gr_evidence" >/dev/null || exit 1
  if [ "$gr_operation" = implement ]; then
    gr_head="$(git -C "$gr_path" rev-parse HEAD)" || exit 1
    jq -e --arg head "$gr_head" '.candidate_sha == $head' "$gr_evidence" >/dev/null
  else
    jq -e --slurpfile model "$gr_snapshot" --arg id "$gr_id" '.candidate_sha == $model[0].nodes[$id].candidate_sha' "$gr_evidence" >/dev/null
  fi
)
graph_contract_failure_envelope() (
  trap - EXIT
  _graph_runtime_open "$1" "${3:-}" || exit 1
  gr_id="$2"
  declare -F _review_filed_order >/dev/null || source "$_ORCHID_GRAPH_RUNTIME_LIB/review.sh"
  gr_attempt="$(jq -r --arg id "$gr_id" '.nodes[$id].attempt' "$gr_snapshot")" || exit 1
  _review_filed_order "$gr_repo/.orchid/reviews/$gr_id-a$gr_attempt-implementer" > "$gr_tmp/files" || exit 1
  gr_latest=""
  while IFS= read -r gr_file; do
    [ -f "$gr_file" ] && [ ! -L "$gr_file" ] || continue
    jq -e '.operation == "implement" and .contract_failure.contract == 1 and .contract_failure.passed == false' "$gr_file" >/dev/null || continue
    gr_kind="$(jq -r .contract_failure.kind "$gr_file")" || continue
    case "$gr_kind" in artifact|envelope|candidate|definition) ;; *) continue ;; esac
    graph_result_current "$gr_repo" "$gr_id" "$gr_file" "$gr_snapshot" || continue
    gr_latest="$gr_file"
  done < "$gr_tmp/files"
  [ -z "$gr_latest" ] || printf '%s\n' "$gr_latest"
)
