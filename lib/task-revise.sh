#!/usr/bin/env bash
# Called by the task revise/restart arms after shared CLI admission.
task_revision() {
  local repo state revision_root revision_reason revision_criteria revision_verify
  local revision_criteria_set revision_verify_set revision_dry_run revision_file
  local revision_changed revision_ids revision_rev revision_gen revision_archive
  local ORCHID_COMMIT_DURABLE_HOOK ORCHID_COMMIT_DURABLE_RECOVERABLE revision_path revision_action revision_kind revision_label
  repo="$(orchid_physical_dir "$1")" || return 1
  revision_action="$2"; shift 2
  case "$revision_action" in
    revise) revision_kind=plan_revision; revision_label=revision ;;
    restart) revision_kind=task_restart; revision_label=restart ;;
    *) orchid_die 'unknown task revision operation' ;;
  esac
  state="$(orchid_state "$repo")"
  [ $# -ge 1 ] || orchid_die "$(task_usage "$revision_action")"
  revision_root="$1"; shift
  case "$revision_root" in ''|plan|*[!A-Za-z0-9_-]*) orchid_die 'revision requires a flat task id' ;; esac
  revision_reason=""; revision_criteria=""; revision_verify=""
  revision_criteria_set=0; revision_verify_set=0; revision_dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --acceptance-criteria) revision_criteria="$2"; revision_criteria_set=1; shift 2 ;;
      --verification-commands) revision_verify="$2"; revision_verify_set=1; shift 2 ;;
      --reason) revision_reason="$2"; shift 2 ;;
      --dry-run) revision_dry_run=1; shift ;;
      *) orchid_die "$(task_usage "$revision_action")" ;;
    esac
  done
  [ -n "$revision_reason" ] || orchid_die 'revision requires --reason'
  _no_newline 'revision reason' "$revision_reason"
  if [ "$revision_criteria_set" -eq 1 ]; then
    [ -n "$revision_criteria" ] || orchid_die 'acceptance criteria must be nonempty'
    _no_newline 'acceptance criteria' "$revision_criteria"
  fi
  if [ "$revision_verify_set" -eq 1 ]; then
    [ -n "$revision_verify" ] || orchid_die 'verification commands must be nonempty'
    _no_newline 'verification commands' "$revision_verify"
  fi
  if [ "$revision_action" = revise ] && [ "$(fm_get "$state/roadmap.md" graph_contract)" = 1 ]; then
    local graph_patch graph_rc=0
    source "$ORCHID_ROOT/lib/graph-replan.sh"
    graph_patch="$(mktemp "${TMPDIR:-/tmp}/orchid-task-replan.XXXXXX")" || return 1
    jq -n --arg id "$revision_root" --arg criteria "$revision_criteria" --arg verify "$revision_verify" \
      --argjson criteria_set "$revision_criteria_set" --argjson verify_set "$revision_verify_set" '
      {($id):((if $criteria_set == 1 then {acceptance_criteria:$criteria} else {} end) +
        (if $verify_set == 1 then {verification_commands:$verify} else {} end))}
    ' > "$graph_patch" || { rm -f "$graph_patch"; return 1; }
    if [ "$revision_dry_run" -eq 1 ]; then
      graph_replan_command "$repo" --patch "$graph_patch" --reason "$revision_reason" --dry-run || graph_rc=$?
    else
      graph_replan_command "$repo" --patch "$graph_patch" --reason "$revision_reason" || graph_rc=$?
    fi
    rm -f "$graph_patch"
    return "$graph_rc"
  fi
  if [ "$revision_dry_run" -eq 0 ]; then
    verb_lock_guard "$repo"
    epoch_require "$repo"
    case "${ORCHID_ACTOR:-operator}" in operator) ;; *) orchid_die 'contract revision is operator-owned' ;; esac
  fi
  _orchid_agent_context_input_owned "$repo" "$repo" .orchid directory || return 1
  for revision_path in tasks reviews revisions; do
    revision_namespace_owned "$repo" ".orchid/$revision_path" || return 1
  done
  for revision_path in roadmap.md journal.md; do
    _orchid_agent_context_input_owned "$repo" "$repo" ".orchid/$revision_path" file || return 1
  done
  revision_file="$state/tasks/$revision_root.md"
  [ -f "$revision_file" ] || orchid_die "no task $revision_root"
  revision_changed=0
  if [ "$revision_criteria_set" -eq 1 ] && [ "$revision_criteria" != "$(fm_get "$revision_file" acceptance_criteria)" ]; then revision_changed=1; fi
  if [ "$revision_verify_set" -eq 1 ] && [ "$revision_verify" != "$(fm_get "$revision_file" verification_commands)" ]; then revision_changed=1; fi
  if [ "$revision_action" = revise ]; then
    [ "$revision_changed" -eq 1 ] || orchid_die 'revision requires a changed acceptance criterion or verification command'
  else
    [ "$revision_criteria_set" -eq 0 ] && [ "$revision_verify_set" -eq 0 ] || orchid_die 'restart preserves the contract; use task revise to change it'
  fi
  revision_ids="$(revision_affected "$repo" "$revision_root")" || orchid_die 'cannot establish revision impact; inspect task records'
  if [ "$revision_dry_run" -eq 1 ]; then
    printf '%s impact for %s:\n%s\n' "$revision_label" "$revision_root" "$revision_ids"
  else
    case "$(fm_get "$state/roadmap.md" run_status)" in running|accepting) ;; *) orchid_die 'revision requires a running or accepting run; use a new run after acceptance' ;; esac
    source "$ORCHID_ROOT/lib/drive.sh"
    revision_preflight "$repo" "$revision_ids" || exit 1
    revision_rev="$(fm_version "$revision_file" contract_revision)"
    if [ "$revision_action" = revise ]; then
      [ "$revision_rev" -lt 999999 ] || orchid_die 'contract revision exhausted'
    fi
    revision_gen="$(fm_version "$revision_file" execution_generation)"
    revision_archive="$revision_root-g$((revision_gen + 1))"
    { [ ! -e "$state/revisions/$revision_archive" ] && [ ! -L "$state/revisions/$revision_archive" ]; } || orchid_die "revision archive $revision_archive already exists"
    task_revision_hook() {
      local wt="$1"
        # A first execution may have no tracked review evidence yet. Keep the
        # selected durable path present so Git can stage it even when empty.
        mkdir -p "$wt/.orchid/reviews" || return 1
      mkdir -p "$wt/.orchid/runtime" || return 1
      printf '%s\n' "$ORCHID_EPOCH" > "$wt/.orchid/runtime/epoch" || return 1
      ORCHID_REPO="$wt" "$ORCHID_ROOT/bin/orchid" journal add --kind "$revision_kind" \
        "task $revision_label $revision_archive; affected: $(printf '%s' "$revision_ids" | tr '\n' ' '); reason: $revision_reason" || return 1
      rm -rf "$wt/.orchid/runtime" || return 1
      revision_apply "$wt" "$revision_root" "$revision_ids" "$revision_archive" \
      "$revision_criteria_set" "$revision_criteria" "$revision_verify_set" "$revision_verify" "$revision_action" || return 1
    if [ "$(fm_get "$wt/.orchid/roadmap.md" graph_contract)" = 1 ]; then
      source "$ORCHID_ROOT/lib/graph-runtime.sh"
      graph_snapshot "$wt" >/dev/null || return 1
    fi
    }
    # ShellCheck rationale: orchid_commit_durable invokes this hook in lib/common.sh.
    # shellcheck disable=SC2034
    ORCHID_COMMIT_DURABLE_HOOK=task_revision_hook
  if [ "$(fm_get "$state/roadmap.md" graph_contract)" = 1 ]; then
    # ShellCheck rationale: common.sh consumes the graph publication mode.
    # shellcheck disable=SC2034
    ORCHID_COMMIT_DURABLE_RECOVERABLE=1
    orchid_commit_durable "$repo" "orchid: task $revision_label $revision_archive" \
      .orchid/tasks .orchid/reviews ".orchid/revisions/$revision_archive" .orchid/roadmap.md .orchid/journal.md
  else
    orchid_commit_durable "$repo" "orchid: task $revision_label $revision_archive" \
      .orchid/tasks .orchid/reviews .orchid/revisions .orchid/roadmap.md .orchid/journal.md
  fi
    unset ORCHID_COMMIT_DURABLE_HOOK
    if [ "$revision_action" = revise ]; then
    printf 'revised %s: contract %s -> %s; archive .orchid/revisions/%s\nrestarted:\n%s\n' \
      "$revision_root" "$revision_rev" "$((revision_rev + 1))" "$revision_archive" "$revision_ids"
    else
      printf 'restarted %s: contract %s unchanged; archive .orchid/revisions/%s\nrestarted:\n%s\n' \
        "$revision_root" "$revision_rev" "$revision_archive" "$revision_ids"
    fi
  fi
}
