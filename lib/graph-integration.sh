#!/usr/bin/env bash
# Graph admission shared by public verbs and their deterministic runner.
# Runtime is lazy: legacy invocations retain their existing cost and behavior.
_ORCHID_GRAPH_INTEGRATION_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
orchid_graph_active() {
  source "$_ORCHID_GRAPH_INTEGRATION_LIB/graph-runtime.sh"
  graph_runtime_enabled "$1"
}

orchid_graph_dispatch_active() (
  local repo="$1" requester="$2" ancestor snapshot
  if ! orchid_graph_active "$repo"; then
    schedule_active_tasks "$repo" | grep -vxF "$requester" || true
    return 0
  fi
  snapshot="$(mktemp "${TMPDIR:-/tmp}/orchid-schedule-graph.XXXXXX")" || return 1
  trap 'rm -f "$snapshot"' EXIT
  graph_snapshot_file "$repo" "$snapshot" || return 1
  while IFS= read -r ancestor; do
    [ "$ancestor" != "$requester" ] || continue
    # Retained checkpoints have not reserved resources until admission.
    if graph_checkpoint_pending "$repo" "$ancestor" "$snapshot"; then continue; fi
    if ! graph_wait_exempts "$repo" "$ancestor" "$requester" "$snapshot"; then
      printf '%s\n' "$ancestor"
    fi
  done < <(schedule_active_tasks "$repo")
)

orchid_graph_review_current() {
  orchid_graph_active "$1" || return 0
  graph_review_evidence_current "$1" "$2" "$3"
}

orchid_graph_task_set_gate() (
  local repo="$1" id="$2" key="$3" value="$4" overlay snapshot state
  orchid_graph_active "$repo" || return 0
  graph_semantic_key "$key" || return 0
  state="$(orchid_state "$repo")"
  [ "$(fm_get "$state/roadmap.md" run_status)" = planning ] || {
    echo 'orchid: graph definitions are immutable during execution; use graph replan' >&2
    return 1
  }
  overlay="$(mktemp "${TMPDIR:-/tmp}/orchid-definition.XXXXXX")" || return 1
  snapshot="$(mktemp "${TMPDIR:-/tmp}/orchid-definition-snapshot.XXXXXX")" || { rm -f "$overlay"; return 1; }
  trap 'rm -f "$overlay" "$snapshot"' EXIT
  jq -n --arg id "$id" --arg key "$key" --arg value "$value" \
    '{($id):{($key):$value}}' > "$overlay" || return 1
  graph_snapshot "$repo" "$overlay" > "$snapshot"
)

# Execution identity is mutable while preparing/reworking a task. Once its
# candidate is exposed to verification, named owners must invalidate evidence.
orchid_graph_identity_set_gate() {
  local repo="$1" id="$2" key="$3" value="$4" file current status plan action path head dirty physical
  case "$key" in base_sha|candidate_sha|branch|worktree) ;; *) return 0 ;; esac
  orchid_graph_active "$repo" || return 0
  file="$(orchid_state "$repo")/tasks/$id.md"
  current="$(fm_get "$file" "$key")" || return 1
  [ "$value" != "$current" ] || return 0
  status="$(fm_get "$file" status)" || return 1
  case "$status" in pending|rework|implementing|blocked) return 0 ;; esac
  declare -F drive_worktree_plan >/dev/null || source "$ORCHID_ROOT/lib/drive.sh"
  # Clearing a successfully removed checkout changes no candidate evidence.
  if [ "$status" = "done" ] && [ "$key" = worktree ] && [ -z "$value" ]; then
    physical="$(_orchid_physical_path "$current")" || return 1
    if [ ! -e "$current" ] && [ ! -L "$current" ] && ! _drive_worktree_registered "$repo" "$physical"; then
      return 0
    fi
  fi
  # Same private per-task handshake as arbitration: the merge owner derives
  # these values after rebasing the task's own registered, clean branch.
  if [ "$status" = merging ] && [ "${ORCHID_GRAPH_REBASE_ID:-}" = "$id" ]; then
    case "$key" in
      base_sha|candidate_sha)
        _graph_runtime_commit "$repo" "$value" || return 1
        plan="$(drive_worktree_plan "$repo" "$id")" || return 1
        IFS=$'\t' read -r action path <<< "$plan"
        case "$action" in reuse|adopt) ;; *) return 1 ;; esac
        dirty="$(handoff_worktree_dirty "$path")" || return 1
        [ -z "$dirty" ] || return 1
        head="$(git -C "$path" rev-parse HEAD)" || return 1
        case "$key" in
          candidate_sha) [ "$value" = "$head" ] || return 1 ;;
          base_sha) git -C "$repo" merge-base --is-ancestor "$value" "$head" || return 1 ;;
        esac
        return 0
        ;;
    esac
  fi
  printf 'orchid: %s %s is frozen in %s; use restart or a named rebase, reverify, or handoff operation\n' "$id" "$key" "$status" >&2
  return 1
}

orchid_graph_completion_gate() {
  orchid_graph_active "$1" || return 0
  graph_completion_ready "$1" "$2" || {
    echo "orchid: $2 has incomplete or obsolete required verification" >&2
    return 1
  }
}

orchid_graph_verify_binding() (
  local repo="$1" id="$2" scratch
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/orchid-verify-binding.XXXXXX")" || return 1
  trap 'rm -rf "$scratch"' EXIT
  graph_snapshot_file "$repo" "$scratch/snapshot.json" || return 1
  graph_job_prepare_gate "$repo" "$id" "$scratch/snapshot.json" verify || return 1
  graph_job_binding "$repo" "$id" "$scratch/binding.json" "$scratch/snapshot.json" || return 1
  graph_wait_close "$repo" "$id" || return 1
  jq -c . "$scratch/binding.json"
)

orchid_graph_effect_admission() (
  local repo="$1" id="$2" operation="$3" snapshot
  orchid_graph_active "$repo" || return 0
  snapshot="$(mktemp "${TMPDIR:-/tmp}/orchid-effect-graph.XXXXXX")" || return 1
  trap 'rm -f "$snapshot"' EXIT
  graph_snapshot_file "$repo" "$snapshot" || return 1
  graph_job_prepare_gate "$repo" "$id" "$snapshot" "$operation" || return 1
  graph_wait_close "$repo" "$id"
)

# Compare committed project bytes and modes, including gitlinks. Reserved
# orchestration state is carried separately by the integration branch.
orchid_graph_project_equal() {
  local status=0
  git -C "$1" diff --quiet --no-ext-diff --no-textconv --ignore-submodules=none \
    "$2" "$3" -- . ':(top,exclude,literal).orchid' || status=$?
  case "$status" in 0|1) return "$status" ;; *) return 2 ;; esac
}

# State publication must not create an endless rebase/invalidation cycle.
# Only forward histories whose every change is reserved state qualify.
orchid_graph_merge_basis() (
  local repo="$1" base="$2" candidate="$3" integration="$4" scratch status=0
  _graph_runtime_commit "$repo" "$base" && _graph_runtime_commit "$repo" "$candidate" && \
    _graph_runtime_commit "$repo" "$integration" || return 2
  git -C "$repo" merge-base --is-ancestor "$base" "$candidate" || status=$?
  case "$status" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  status=0
  git -C "$repo" merge-base --is-ancestor "$base" "$integration" || status=$?
  case "$status" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  status=0
  git -C "$repo" merge-base --is-ancestor "$candidate" "$integration" || status=$?
  case "$status" in
    0)
      orchid_graph_project_equal "$repo" "$candidate" "$integration" || return $?
      printf 'already_integrated\n'
      return 0
      ;;
    1) ;;
    *) return 2 ;;
  esac
  orchid_graph_project_equal "$repo" "$base" "$integration" || return $?
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/orchid-state-progress.XXXXXX")" || return 2
  trap 'rm -rf "$scratch"' EXIT
  git -C "$repo" rev-list "$base..$integration" > "$scratch/commits" || return 2
  git -C "$repo" diff-tree --stdin -r -m --root --no-commit-id --name-only -z \
    --no-ext-diff --no-textconv --ignore-submodules=none \
    -- . ':(top,exclude,literal).orchid' < "$scratch/commits" > "$scratch/paths" || return 2
  [ ! -s "$scratch/paths" ] || return 1
  printf 'state_progress\n'
)

# Narrow predicate retained for callers that ask specifically about state-only
# history. The merge verb also understands already-integrated revalidation.
orchid_graph_state_progress() {
  local basis
  basis="$(orchid_graph_merge_basis "$@")" || return $?
  [ "$basis" = state_progress ]
}

# Detect a crash between candidate replacement and descendant invalidation.
# Unbound pending nodes have nothing to retire; only recorded bindings count.
orchid_graph_stale_targets() (
  local repo="$1" scratch id target expected
  orchid_graph_active "$repo" || return 0
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/orchid-stale-targets.XXXXXX")" || return 1
  trap 'rm -rf "$scratch"' EXIT
  graph_snapshot_file "$repo" "$scratch/graph.json" || return 1
  while IFS= read -r id; do
    graph_expected_target "$scratch/graph.json" "$id" > "$scratch/expected.json" || return 1
    expected="$(jq -r --arg id "$id" --slurpfile expected "$scratch/expected.json" \
      '.nodes[$id].verification_target == $expected[0]' "$scratch/graph.json")" || return 1
    [ "$expected" = false ] || continue
    target="$(jq -r --arg id "$id" '.nodes[$id].verifies' "$scratch/graph.json")" || return 1
    printf '%s\n' "$target"
  done < <(jq -r '.nodes[] | select(.verifies != null and .verification_target != null) | .id' "$scratch/graph.json")
)

orchid_graph_run_gate() (
  local repo="$1" state file id
  orchid_graph_active "$repo" || return 0
  state="$(orchid_state "$repo")"
  for file in "$state/tasks"/*.md; do
    [ -f "$file" ] || continue
    id="${file##*/}"; id="${id%.md}"
    [ "$id" != plan ] || continue
    [ "$(fm_get "$file" status)" = "done" ] || return 1
    graph_completion_ready "$repo" "$id" || return 1
  done
)
