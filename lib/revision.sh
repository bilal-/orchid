#!/usr/bin/env bash
# Task contract and execution versions. Source after frontmatter/schedule;
# mutation callers additionally source drive.sh for worktree ownership checks.

# Reuse the existing repository-path ownership checker for the namespaces this
# transaction reads and archives. Recursion adds traversal, not another checker.
# Compatibility name for the shared owned-tree admission primitive.
revision_namespace_owned() { orchid_state_tree_owned "$@"; }

# Existing dependency parser is the sole owner of depends_on syntax.
revision_execution_branch() {
  local generation
  generation="$(fm_version "$1" execution_generation)" || return 1
  if [ "$generation" -eq 1 ]; then
    printf 'task/%s\n' "$2"
  else
    printf 'task/%s-g%s\n' "$2" "$generation"
  fi
}

revision_terms() {
  jq -cn --arg acceptance "$(fm_get "$1" acceptance_criteria)" \
    --arg verification "$(fm_get "$1" verification_commands)" \
    '{acceptance_criteria:$acceptance,verification_commands:$verification}'
}

revision_inputs() {
  local repo="$1" id="$2" state dep f rows="" rev gen cand terms
  state="$(orchid_state "$repo")"
  f="$state/tasks/$id.md"
  [ -f "$f" ] || return 1
  while IFS= read -r dep; do
    case "$dep" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ -f "$state/tasks/$dep.md" ] || return 1
    rev="$(fm_version "$state/tasks/$dep.md" contract_revision)" || return 1
    gen="$(fm_version "$state/tasks/$dep.md" execution_generation)" || return 1
    cand="$(fm_get "$state/tasks/$dep.md" candidate_sha)"
    terms="$(revision_terms "$state/tasks/$dep.md")" || return 1
    rows="$rows$(jq -cn --arg id "$dep" --argjson revision "$rev" --argjson generation "$gen" --arg candidate "$cand" \
      --argjson terms "$terms" '{key:$id,value:{contract_revision:$revision,execution_generation:$generation,candidate_sha:$candidate,contract_terms:$terms}}')"$'\n'
  done < <(schedule_split_deps "$(fm_get "$f" depends_on)")
  printf '%s' "$rows" | jq -s 'from_entries'
}

# Dependency closure, in stable filename order. Validate the complete task list
# before reasoning about it; a damaged record cannot hide a dependent task.
revision_affected() {
  local repo="$1" root="$2" state f id dep changed=1 ids
  state="$(orchid_state "$repo")"
  if [ "$(fm_get "$state/roadmap.md" graph_contract)" = 1 ]; then
    _revision_graph_affected "$repo" "$root"
    return
  fi
  [ "$root" != plan ] && [ -f "$state/tasks/$root.md" ] || return 1
  for f in "$state/tasks"/*.md; do
    [ -e "$f" ] || continue
    fm_check "$f" id >/dev/null || return 1
    id="$(fm_get "$f" id)"
    case "$id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "$f" = "$state/tasks/$id.md" ] || return 1
  done
  ids="$root"
  while [ "$changed" -eq 1 ]; do
    changed=0
    for f in "$state/tasks"/*.md; do
      [ -e "$f" ] || continue
      id="$(fm_get "$f" id)"
      case " $ids " in *" $id "*) continue ;; esac
      while IFS= read -r dep; do
        case " $ids " in *" $dep "*) ids="$ids $id"; changed=1; break ;; esac
      done < <(schedule_split_deps "$(fm_get "$f" depends_on)")
    done
  done
  for f in "$state/tasks"/*.md; do
    [ -e "$f" ] || continue
    id="$(fm_get "$f" id)"
    case " $ids " in *" $id "*) printf '%s\n' "$id" ;; esac
  done
}

_revision_graph_affected() (
  local repo="$1" root="$2" snapshot
  source "$ORCHID_ROOT/lib/graph-runtime.sh"
  snapshot="$(mktemp "${TMPDIR:-/tmp}/orchid-restart-graph.XXXXXX")" || return 1
  trap 'rm -f "$snapshot"' EXIT
  graph_snapshot_file "$repo" "$snapshot" || return 1
  graph_affected "$snapshot" "$root"
)

# Pins come from the kernel manifest, not an engine's claims. A missing binding
# is legacy generation 1, never permission to file into a revised generation.
revision_manifest_current() {
  local repo="$1" manifest="$2" id f rev gen inputs terms
  id="$(jq -r .task "$manifest")" || return 1
  case "$id" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "$id" != plan ] || return 0
  f="$(orchid_state "$repo")/tasks/$id.md"
  if [ ! -f "$f" ]; then
    # Legacy orphan manifests still produce their historical diagnostics.
    # Versioned jobs require a matching current task record.
    jq -e '(has("execution_generation") or has("contract_revision")) | not' "$manifest" >/dev/null
    return
  fi
  rev="$(fm_version "$f" contract_revision)" || return 1
  gen="$(fm_version "$f" execution_generation)" || return 1
  inputs="$(revision_inputs "$repo" "$id")" || return 1
  terms="$(revision_terms "$f")" || return 1
  jq -e --argjson rev "$rev" --argjson gen "$gen" --argjson inputs "$inputs" --argjson terms "$terms" '
    (.contract_revision // 1) == $rev and (.execution_generation // 1) == $gen and
    (if has("contract_terms") then .contract_terms == $terms else $gen == 1 end) and
    (if has("input_revisions") then .input_revisions == $inputs else $gen == 1 end)
  ' "$manifest" >/dev/null
}

revision_preflight() {
  local repo="$1" ids="$2" policy="${3:-idle}" state id f status gen branch plan action path dirty idle
  state="$(orchid_state "$repo")"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    f="$state/tasks/$id.md"
    status="$(fm_get "$f" status)"
    case "$policy:$status" in
      graph:pending|graph:implementing|graph:testing|graph:reviewing|graph:arbitrating|graph:merging|graph:rework|graph:blocked|graph:done|\
      repair:pending|repair:implementing|repair:testing|repair:reviewing|repair:arbitrating|repair:merging|repair:rework|repair:blocked|repair:done|\
      idle:pending|idle:rework|idle:blocked|idle:done) ;; *)
      printf 'orchid: revision refused: %s is %s; stop and reconcile its execution first\n' "$id" "$status" >&2
      return 1 ;;
    esac
    if [ "$policy" != graph ] && [ -n "$(fm_get "$f" unresolved_objection)" ]; then
      printf 'orchid: revision refused: %s has an unresolved objection; resolve it through arbitration first\n' "$id" >&2
      return 1
    fi
    idle="$(orchid_task_jobs_idle "$repo" "$id")" || { printf 'orchid: revision refused: %s\n' "$idle" >&2; return 1; }
    gen="$(fm_version "$f" execution_generation)" || return 1
    [ "$gen" -lt 999999 ] || { printf 'orchid: execution generation exhausted for %s\n' "$id" >&2; return 1; }
    branch="task/$id-g$((gen + 1))"
    if git -C "$repo" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
      printf 'orchid: revision refused: replacement branch %s already exists\n' "$branch" >&2
      return 1
    fi
    plan="$(drive_worktree_plan "$repo" "$id")" || return 1
    IFS=$'\t' read -r action path <<< "$plan"
    case "$action" in
      create) ;;
      reuse|adopt)
        dirty="$(handoff_worktree_dirty "$path")" || { printf 'orchid: cannot inspect worktree for %s\n' "$id" >&2; return 1; }
        [ -z "$dirty" ] || { printf 'orchid: revision refused: %s has uncommitted work in %s\n' "$id" "$path" >&2; return 1; } ;;
      *) printf 'orchid: revision refused for %s: %s\n' "$id" "$path" >&2; return 1 ;;
    esac
    # Validate inputs and both counters before any durable publication.
    revision_inputs "$repo" "$id" >/dev/null || return 1
    fm_version "$f" contract_revision >/dev/null || return 1
  done <<< "$ids"
}

# Runs only inside orchid_commit_durable's detached staging checkout. The
# caller has already journalled the reason there. No source checkout is reset.
revision_archive_task() {
  local repo="$1" id="$2" archive="$3" state f evidence owner name attempt suffix
  state="$(orchid_state "$repo")"; f="$state/tasks/$id.md"
  mkdir -p "$state/revisions/$archive/tasks" "$state/revisions/$archive/reviews" || return 1
  cp "$f" "$state/revisions/$archive/tasks/$id.md" || return 1
    for evidence in "$state/reviews/$id-"*; do
      [ -e "$evidence" ] || continue
      [ -f "$evidence" ] && [ ! -L "$evidence" ] || return 1
      name="${evidence##*/}"
      # Prefixes are not identities: T1 must not consume T1-other's evidence.
      case "$name" in
        "$id-verify.log"|"$id-merge.log") ;;
        *.json)
          owner="$(jq -r '.task // ""' "$evidence")" || return 1
          if [ "$owner" != "$id" ]; then
            [ -z "$owner" ] || continue
            attempt="$(jq -r '.attempt // ""' "$evidence")" || return 1
            [ "$name" = "$id-a$attempt.review-plan.json" ] || continue
          fi ;;
        "$id-r"*"-rework.log"|"$id-r"*"-rework.retired.log")
          suffix="${name#"$id-r"}"; suffix="${suffix%-rework.log}"; suffix="${suffix%-rework.retired.log}"
          case "$suffix" in ''|*[!0-9]*) continue ;; esac ;;
        *) continue ;;
      esac
      mv "$evidence" "$state/revisions/$archive/reviews/" || return 1
    done
}

# The one owner of execution reset. Both manual and graph transactions use it.
revision_reset_task() {
  local repo="$1" id="$2" archive="$3" state f gen rev field at
  state="$(orchid_state "$repo")"; f="$state/tasks/$id.md"
  gen="$(fm_version "$f" execution_generation)" || return 1
  rev="$(fm_version "$f" contract_revision)" || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  fm_set "$f" contract_revision "$rev" || return 1
  fm_set "$f" execution_generation "$((gen + 1))" || return 1
  fm_set "$f" revision_id "$archive" || return 1
  fm_set "$f" branch "task/$id-g$((gen + 1))" || return 1
  fm_set "$f" status pending || return 1
  # Policy and dependency declarations survive; execution authority does not.
  for field in worktree base_sha candidate_sha started_at handoff_ack prerequisite_ack \
    verify_fail_pending refused_envelopes implement_floor implementer_engine_id \
    verification_target candidate_reuse_from graph_wait; do
    if fm_has "$f" "$field"; then fm_set "$f" "$field" "" || return 1; fi
  done
  for field in attempts infra_failures rework_rounds rework_signature_repeats; do
    if fm_has "$f" "$field"; then fm_set "$f" "$field" 0 || return 1; fi
  done
  if fm_has "$f" rework_signature; then fm_set "$f" rework_signature "" || return 1; fi
  fm_set "$f" updated "$at"
}

revision_apply() {
  local repo="$1" root="$2" ids="$3" archive="$4" criteria_set="$5" criteria="$6" verify_set="$7" verify="$8" action="$9"
  local state id f rev
  state="$(orchid_state "$repo")"
  while IFS= read -r id; do
    revision_archive_task "$repo" "$id" "$archive" || return 1
    f="$state/tasks/$id.md"
    if [ "$id" = "$root" ] && [ "$action" = revise ]; then
      rev="$(fm_version "$f" contract_revision)" || return 1
      [ "$criteria_set" -eq 0 ] || fm_set "$f" acceptance_criteria "$criteria" || return 1
      [ "$verify_set" -eq 0 ] || fm_set "$f" verification_commands "$verify" || return 1
      fm_set "$f" contract_revision "$((rev + 1))" || return 1
    fi
    revision_reset_task "$repo" "$id" "$archive" || return 1
  done <<< "$ids"
  if [ "$(fm_get "$state/roadmap.md" run_status)" = accepting ]; then
    fm_set "$state/roadmap.md" run_status running || return 1
  fi
}

# A validated graph plan may change semantics, delete nodes, or retain an
# immutable candidate for new-contract revalidation. Only this reset owner
# moves execution generations; no caller relabels historical model evidence.
revision_apply_plan() {
  local repo="$1" plan="$2" archive="$3" new_tasks="${4:-}" state id f key value checkpoint evidence path expected digest
  repo="$(orchid_physical_dir "$repo")" || return 1
  state="$(orchid_state "$repo")"
  while IFS= read -r id; do
    f="$state/tasks/$id.md"
    if jq -e --arg id "$id" '.nodes[$id].new_task == true' "$plan" >/dev/null; then
      [ -n "$new_tasks" ] && [ -f "$new_tasks/$id.md" ] && [ ! -L "$new_tasks/$id.md" ] && [ ! -e "$f" ] || return 1
      fm_check "$new_tasks/$id.md" id >/dev/null || return 1
      [ "$(fm_get "$new_tasks/$id.md" id)" = "$id" ] || return 1
      mkdir -p "$state/tasks" || return 1
      cp "$new_tasks/$id.md" "$f" || return 1
      fm_set "$f" contract_revision 1 || return 1
      fm_set "$f" execution_generation 1 || return 1
    else
      revision_archive_task "$repo" "$id" "$archive" || return 1
      if jq -e --arg id "$id" '.nodes[$id].delete == true' "$plan" >/dev/null; then
        rm "$f" || return 1
        continue
      fi
      revision_reset_task "$repo" "$id" "$archive" || return 1
    fi
    while IFS= read -r key; do
      value="$(jq -r --arg id "$id" --arg key "$key" '.nodes[$id].fields[$key] | if type == "object" or type == "array" then tojson elif . == null then "" else tostring end' "$plan")" || return 1
      fm_set "$f" "$key" "$value" || return 1
    done < <(jq -r --arg id "$id" '.nodes[$id].fields | keys[]' "$plan")
    if jq -e --arg id "$id" '.nodes[$id].resolve_repair == true' "$plan" >/dev/null; then
      fm_set "$f" repair_obligation '' || return 1
    fi
    checkpoint="$(jq -c --arg id "$id" '.nodes[$id].checkpoint // null' "$plan")" || return 1
    if [ "$checkpoint" != null ]; then
      fm_set "$f" candidate_reuse_from "$checkpoint" || return 1
      for key in base_sha candidate_sha implementer_engine_id; do
        value="$(jq -r --arg key "$key" '.[$key] // ""' <<< "$checkpoint")" || return 1
        fm_set "$f" "$key" "$value" || return 1
      done
      value="$(jq -r --arg id "$id" '.nodes[$id].outcome | if . == "code" then "testing" else "reviewing" end' "$plan")" || return 1
      fm_set "$f" status "$value" || return 1
    fi
  done < <(jq -r '.nodes | keys[]' "$plan")
  # The obligation describes the archived bytes, not a racing live review.
  while IFS= read -r evidence; do
    path="$(jq -r .path <<< "$evidence")" || return 1
    expected="$(jq -r .sha256 <<< "$evidence")" || return 1
    case "$path" in ".orchid/revisions/$archive/reviews/"*) ;; *) echo 'orchid: repair evidence is outside its archive' >&2; return 1 ;; esac
    _orchid_agent_context_input_owned "$repo" "$repo" "$path" file || return 1
    [ -f "$repo/$path" ] || { echo 'orchid: repair evidence was not archived' >&2; return 1; }
    digest="$(_orchid_stream_sha256 < "$repo/$path")" || return 1
    [ "$digest" = "$expected" ] || { echo 'orchid: archived repair evidence differs from the obligation' >&2; return 1; }
  done < <(jq -c '.nodes[].fields.repair_obligation.failed_evidence[]?' "$plan")
  if [ "$(fm_get "$state/roadmap.md" run_status)" = accepting ]; then
    fm_set "$state/roadmap.md" run_status running || return 1
  fi
}

revision_bind_envelope() {
  jq --slurpfile manifest "$2" '
    . as $envelope |
    ($manifest[0] | {contract_revision:(.contract_revision // 1),
      execution_generation:(.execution_generation // 1)} +
      (if has("input_revisions") then {input_revisions} else {} end) +
      (if has("contract_terms") then {contract_terms} else {} end)) as $binding |
    if any($binding | to_entries[]; . as $entry |
      ($envelope | has($entry.key)) and ($envelope[$entry.key] != $entry.value))
    then error("envelope revision differs from prepared job")
    else $envelope + $binding end
  ' "$1"
}
