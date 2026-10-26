#!/usr/bin/env bash
# Controlled semantic changes use the same archival/reset/publication owner as
# task restart. Candidate commits are lineage, never recycled model approval.
_graph_revision_load() {
  source "$ORCHID_ROOT/lib/frontmatter.sh"
  source "$ORCHID_ROOT/lib/manifest.sh"
  source "$ORCHID_ROOT/lib/roles.sh"
  source "$ORCHID_ROOT/lib/resolver.sh"
  source "$ORCHID_ROOT/lib/archetype.sh"
  source "$ORCHID_ROOT/lib/schedule.sh"
  source "$ORCHID_ROOT/lib/json.sh"
  source "$ORCHID_ROOT/lib/output-contract.sh"
  source "$ORCHID_ROOT/lib/graph.sh"
  source "$ORCHID_ROOT/lib/revision.sh"
  source "$ORCHID_ROOT/lib/handoff.sh"
  source "$ORCHID_ROOT/lib/drive.sh"
  source "$ORCHID_ROOT/lib/publication.sh"
  source "$ORCHID_ROOT/lib/graph-runtime.sh"
}

_graph_revision_reason() {
  local bytes
  bytes="$(printf '%s' "$1" | wc -c | tr -d ' ')" || return 1
  [ -n "$1" ] && [ "$bytes" -le 8192 ] || {
    echo 'orchid: graph revision requires a reason of 1..8192 bytes' >&2; return 1;
  }
  case "$1" in *$'\n'*|*$'\r'*) echo 'orchid: graph revision reason must be single-line' >&2; return 1 ;; esac
}

_graph_revision_owned() {
  local repo="$1" path
  _orchid_agent_context_input_owned "$repo" "$repo" .orchid directory || return 1
  for path in tasks reviews revisions; do
    revision_namespace_owned "$repo" ".orchid/$path" || return 1
  done
  for path in roadmap.md requirements.md journal.md; do
    _orchid_agent_context_input_owned "$repo" "$repo" ".orchid/$path" file || return 1
  done
}

_graph_revision_copy_input() {
  local source="$1" dest="$2" maximum="$3" bytes
  [ -f "$source" ] && [ ! -L "$source" ] || {
    echo "orchid: graph input must be a regular file: $source" >&2; return 1;
  }
  bytes="$(wc -c < "$source" | tr -d ' ')" || return 1
  [ "$bytes" -le "$maximum" ] || { echo 'orchid: graph input exceeds its byte limit' >&2; return 1; }
  head -c "$((maximum + 1))" < "$source" > "$dest" || return 1
  bytes="$(wc -c < "$dest" | tr -d ' ')" || return 1
  [ "$bytes" -le "$maximum" ] || return 1
  orchid_utf8_file_valid "$dest"
}

_graph_revision_plan_preimages() {
  orchid_publication_capture "$1" .orchid/tasks .orchid/reviews .orchid/requirements.md .orchid/roadmap.md .orchid/journal.md > "$2/planning-preimages.json"
}

# Model a proposed roadmap/requirements context without touching live state.
# graph_snapshot remains the sole parser/normalizer/validator.
_graph_replan_proposed() {
  local repo="$1" patch="$2" requirements="$3" temp="$4" revision="$5"
  local model="$temp/model" state
  state="$(orchid_state "$repo")"
  mkdir -p "$model/.orchid" || return 1
  _ocd_copy_path "$state/tasks" "$model/.orchid/tasks" exact || return 1
  _ocd_copy_path "$state/roadmap.md" "$model/.orchid/roadmap.md" exact || return 1
  _ocd_copy_path "$state/requirements.md" "$model/.orchid/requirements.md" exact || return 1
  _graph_replan_render_new "$repo" "$patch" "$model" || return 1
  fm_set "$model/.orchid/roadmap.md" graph_contract 1 || return 1
  fm_set "$model/.orchid/roadmap.md" requirements_revision "$revision" || return 1
  if [ -n "$requirements" ]; then cp "$requirements" "$model/.orchid/requirements.md" || return 1; fi
  graph_snapshot "$model" "$patch"
}

_graph_replan_render_new() {
  local repo="$1" patch="$2" model="$3" id title arch template engine at
  jq -e "$_ORCHID_GRAPH_JQ"'all(keys[]; id_ok)' "$patch" >/dev/null || return 1
  engine="$(resolve_role "$repo" implementer)" || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  mkdir -p "$model/.orchid/tasks" || return 1
  while IFS= read -r id; do
    [ ! -f "$repo/.orchid/tasks/$id.md" ] || continue
    jq -e --arg id "$id" '.[$id] != null' "$patch" >/dev/null || continue
    title="$(jq -r --arg id "$id" '.[$id].title // $id' "$patch")" || return 1
    arch="$(jq -r --arg id "$id" '.[$id].archetype // "feature"' "$patch")" || return 1
    [ -n "$arch" ] || arch=feature
    archetype_validate "$arch" >/dev/null || return 1
    template="$ORCHID_ROOT/templates/task-$arch.md"
    [ -f "$template" ] || template="$ORCHID_ROOT/templates/task.md"
    fm_write_task_from "$model/.orchid/tasks/$id.md" \
      fm_render_task_template "$template" "$id" "$title" "$arch" "$engine" "$at" || return 1
  done < <(jq -r 'keys[]' "$patch")
}

_graph_replan_roots() {
  local repo="$1" patch="$2" destination="$3" id key before after changed
  : > "$destination.lines"
  while IFS= read -r id; do
    if [ ! -f "$repo/.orchid/tasks/$id.md" ]; then
      printf '%s\n' "$id" >> "$destination.lines"
      continue
    fi
    if jq -e --arg id "$id" '.[$id] == null' "$patch" >/dev/null; then
      printf '%s\n' "$id" >> "$destination.lines"
      continue
    fi
    changed=0
    while IFS= read -r key; do
      before="$(fm_get "$repo/.orchid/tasks/$id.md" "$key")" || return 1
      after="$(jq -r --arg id "$id" --arg key "$key" '.[$id][$key] | if . == null then "" elif type == "object" or type == "array" then tojson else tostring end' "$patch")" || return 1
      if [ "$key" = output_contract ]; then
        [ -z "$before" ] || before="$(output_contract_validate "$before")" || return 1
        [ -z "$after" ] || after="$(output_contract_validate "$after")" || return 1
      fi
      [ "$before" = "$after" ] || changed=1
    done < <(jq -r --arg id "$id" '.[$id] | keys[]' "$patch")
    [ "$changed" -eq 0 ] || printf '%s\n' "$id" >> "$destination.lines"
  done < <(jq -r 'keys[]' "$patch")
  jq -Rsc 'split("\n") | map(select(length > 0)) | unique' < "$destination.lines" > "$destination"
}

_graph_replan_risk_gate() {
  local snapshot="$1" patch="$2" id old proposed
  while IFS= read -r id; do
    jq -e --arg id "$id" '.nodes | has($id)' "$snapshot" >/dev/null || continue
    old="$(jq -r --arg id "$id" '.nodes[$id].risk_tier // ""' "$snapshot")" || return 1
    proposed="$(jq -r --arg id "$id" '.[$id].risk_tier' "$patch")" || return 1
    case "$old" in low|medium|high) ;; *) echo 'orchid: current risk_tier is invalid' >&2; return 1 ;; esac
    case "$proposed" in low|medium|high) ;; *) echo 'orchid: invalid proposed risk_tier' >&2; return 1 ;; esac
    [ "$(orchid_risk_rank "$proposed")" -ge "$(orchid_risk_rank "$old")" ] || {
      echo "orchid: risk_tier is monotonic ($old -> $proposed refused)" >&2; return 1;
    }
  done < <(jq -r 'to_entries[] | select(.value != null and (.value | has("risk_tier"))) | .key' "$patch")
}

_graph_replan_new_preflight() {
  local repo="$1" plan="$2" id path previous
  while IFS= read -r id; do
    for previous in "$repo/.orchid/revisions/"*/tasks/"$id.md"; do
      [ ! -e "$previous" ] || { echo "orchid: retired task identity cannot be reused in this run: $id" >&2; return 1; }
    done
    if git -C "$repo" rev-parse --verify -q "refs/heads/task/$id" >/dev/null; then
      echo "orchid: new task branch already exists: task/$id" >&2; return 1
    fi
    path="$(drive_worktree_path "$repo" "$id" 1)" || return 1
    if [ -e "$path" ] || [ -L "$path" ] || _drive_worktree_registered "$repo" "$path"; then
      echo "orchid: new task checkout path is already occupied: $id" >&2; return 1
    fi
  done < <(jq -r '.nodes | to_entries[] | select(.value.new_task == true) | .key' "$plan")
}

_graph_revision_archive_name() {
  local repo="$1" counter
  counter="$(fm_get "$repo/.orchid/roadmap.md" graph_revision)"
  [ -n "$counter" ] || counter=0
  case "$counter" in 0|[1-9]|[1-9][0-9]*) ;; *) echo 'orchid: invalid graph revision counter' >&2; return 1 ;; esac
  case "$counter" in *[!0-9]*) return 1 ;; esac
  [ "$counter" -lt 999999 ] || { echo 'orchid: graph revision counter exhausted' >&2; return 1; }
  printf 'graph-p%s\n' "$((counter + 1))"
}

_graph_revision_check_candidates() {
  local repo="$1" plan="$2" id key sha resolved
  while IFS= read -r id; do
    for key in base_sha candidate_sha; do
      sha="$(jq -r --arg id "$id" --arg key "$key" '.nodes[$id].checkpoint[$key] // ""' "$plan")" || return 1
      [ -n "$sha" ] || continue
      case "${#sha}" in 40|64) ;; *) echo 'orchid: retained candidate must be a full commit ID' >&2; return 1 ;; esac
      case "$sha" in *[!0-9a-f]*) echo 'orchid: retained candidate must be hexadecimal' >&2; return 1 ;; esac
      resolved="$(git -C "$repo" rev-parse --verify "$sha^{commit}" 2>/dev/null)" || {
        echo "orchid: invalid retained $key on $id" >&2; return 1;
      }
      [ "$resolved" = "$sha" ] || { echo "orchid: retained candidate must be a full commit ID on $id" >&2; return 1; }
    done
    if jq -e --arg id "$id" '.nodes[$id].checkpoint != null' "$plan" >/dev/null; then
      git -C "$repo" merge-base --is-ancestor \
        "$(jq -r --arg id "$id" '.nodes[$id].checkpoint.base_sha' "$plan")" \
        "$(jq -r --arg id "$id" '.nodes[$id].checkpoint.candidate_sha' "$plan")" || {
        echo "orchid: retained base is not an ancestor of candidate on $id" >&2; return 1;
      }
    fi
  done < <(jq -r '.nodes | keys[]' "$plan")
}

# A candidate change invalidates evidence in required verifier subgraphs and
# their ordinary consumers, without changing the target's own execution.
graph_invalidate_command() (
  local repo id reason='' dry_run=0 temp ids archive expected recorded verifier
  repo="$(orchid_physical_dir "$1")" || return 1; id="${2:-}"; shift 2
  _graph_revision_load
  source "$ORCHID_ROOT/lib/graph-runtime.sh"
  case "$id" in ''|plan|*[!A-Za-z0-9_-]*) echo 'orchid: invalidate requires a target ID' >&2; return 1 ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || return 1; reason="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) return 1 ;;
    esac
  done
  _graph_revision_reason "$reason" || return 1
  temp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-invalidate.XXXXXX")" || return 1
  trap 'rm -rf "$temp"' EXIT
  if [ "$dry_run" -eq 0 ]; then
    verb_lock_acquire "$repo" || return 1
    trap 'rm -rf "$temp"; verb_lock_release "$repo"' EXIT
    epoch_require "$repo"
  fi
  _graph_revision_owned "$repo" || return 1
  graph_runtime_enabled "$repo" || return 0
  _graph_revision_plan_preimages "$repo" "$temp" || return 1
  graph_snapshot_file "$repo" "$temp/old.json" || return 1
  graph_required "$temp/old.json" "$id" > "$temp/required.lines" || return 1
  : > "$temp/stale.lines"
  while IFS= read -r verifier; do
    [ -n "$verifier" ] || continue
    recorded="$(jq -c --arg id "$verifier" '.nodes[$id].verification_target' "$temp/old.json")" || return 1
    # Never invalidate a pristine, unbound generation repeatedly.
    [ "$recorded" != null ] || continue
    expected="$(graph_expected_target "$temp/old.json" "$verifier")" || return 1
    if ! jq -en --argjson old "$recorded" --argjson current "$expected" '$old == $current' >/dev/null; then
      printf '%s\n' "$verifier" >> "$temp/stale.lines"
    fi
  done < "$temp/required.lines"
  if [ ! -s "$temp/stale.lines" ]; then echo 'current verifier bindings'; return 0; fi
  jq -Rsc 'split("\n") | map(select(length > 0))' < "$temp/stale.lines" > "$temp/stale.json" || return 1
  ids="$(graph_affected "$temp/old.json" "$temp/stale.json")" || return 1
  printf '%s\n' "$ids" | jq -Rsc 'split("\n") | map(select(length > 0))' > "$temp/affected.json" || return 1
  jq -n --slurpfile old "$temp/old.json" --slurpfile affected "$temp/affected.json" '
    {contract:1,nodes:(reduce $affected[0][] as $id ({};
      .[$id] = {delete:false,outcome:$old[0].nodes[$id].outcome,checkpoint:null,fields:{}}))}
  ' > "$temp/plan.json" || return 1
  archive="$(_graph_revision_archive_name "$repo")" || return 1
  jq -n --arg target "$id" --arg reason "$reason" '{contract:1,actor:"kernel",target:$target,reason:$reason}' > "$temp/decision.json" || return 1
  if [ "$dry_run" -eq 1 ]; then cat "$temp/plan.json"; return 0; fi
  revision_preflight "$repo" "$ids" repair || return 1
  _graph_revision_publish "$repo" "$temp" "$archive" "$reason" graph_invalidate || return 1
  printf 'invalidated: %s\narchive: .orchid/revisions/%s\n' "$(tr '\n' ' ' <<< "$ids")" "$archive"
)

# All graph mutations reach this one recoverable transaction. Its hook calls
# the shared revision plan, then validates what will actually be committed.
_graph_revision_publish() {
  local repo="$1" temp="$2" archive="$3" reason="$4" kind="$5" requirements="${6:-}"
  local state ORCHID_COMMIT_DURABLE_HOOK ORCHID_COMMIT_DURABLE_RECOVERABLE
  state="$(orchid_state "$repo")"
  { [ ! -e "$state/revisions/$archive" ] && [ ! -L "$state/revisions/$archive" ]; } || {
    echo "orchid: revision archive already exists: $archive" >&2; return 1;
  }
  _graph_revision_publish_hook() {
    local wt="$1" path
    # The plan was computed before staging. A later edit must not be silently
    # incorporated into a plan derived from an earlier contract/generation.
    orchid_publication_preimages_match "$wt" "$(cat "$temp/planning-preimages.json")" || return 1
    mkdir -p "$wt/.orchid/tasks" "$wt/.orchid/reviews" "$wt/.orchid/revisions/$archive" "$wt/.orchid/runtime" || return 1
    printf '%s\n' "$ORCHID_EPOCH" > "$wt/.orchid/runtime/epoch" || return 1
    ORCHID_REPO="$wt" "$ORCHID_ROOT/bin/orchid" journal add --kind "$kind" \
      "$kind $archive; affected: $(jq -r '.nodes | keys | join(",")' "$temp/plan.json"); reason: $reason" || return 1
    rm -rf "$wt/.orchid/runtime" || return 1
    cp "$wt/.orchid/roadmap.md" "$wt/.orchid/revisions/$archive/roadmap.md" || return 1
    cp "$wt/.orchid/requirements.md" "$wt/.orchid/revisions/$archive/requirements.md" || return 1
    for path in old.json new.json patch.json impact.json plan.json decision.json planning-preimages.json; do
      [ ! -f "$temp/$path" ] || cp "$temp/$path" "$wt/.orchid/revisions/$archive/$path" || return 1
    done
    revision_apply_plan "$wt" "$temp/plan.json" "$archive" "$temp/model/.orchid/tasks" || return 1
    if [ -n "$requirements" ]; then
      cp "$requirements" "$wt/.orchid/requirements.md" || return 1
      fm_set "$wt/.orchid/roadmap.md" requirements_revision "$(jq -r '.run.requirements_revision' "$temp/new.json")" || return 1
    fi
    fm_set "$wt/.orchid/roadmap.md" graph_contract 1 || return 1
    case "$archive" in graph-p*) fm_set "$wt/.orchid/roadmap.md" graph_revision "${archive#graph-p}" || return 1 ;; esac
    graph_snapshot "$wt" > "$temp/published-model.json" || return 1
    if [ -f "$temp/new.json" ]; then cp "$temp/new.json" "$wt/.orchid/revisions/$archive/proposed.json" || return 1; fi
    cp "$temp/published-model.json" "$wt/.orchid/revisions/$archive/new.json" || return 1
  }
  # ShellCheck rationale: orchid_commit_durable consumes this named local hook.
  # shellcheck disable=SC2034
  ORCHID_COMMIT_DURABLE_HOOK=_graph_revision_publish_hook
  # ShellCheck rationale: common.sh consumes recoverable publication mode.
  # shellcheck disable=SC2034
  ORCHID_COMMIT_DURABLE_RECOVERABLE=1
  orchid_commit_durable "$repo" "orchid: $kind $archive" \
    .orchid/tasks .orchid/reviews ".orchid/revisions/$archive" .orchid/requirements.md .orchid/roadmap.md .orchid/journal.md
}

graph_replan_command() (
  local repo patch='' reason='' requirements='' resolve='' dry_run=0 temp state archive ids
  local old_revision new_revision adoption=0 requirements_changed=0
  repo="$(orchid_physical_dir "$1")" || return 1; shift
  _graph_revision_load
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --patch|--reason|--requirements|--resolve-repairs)
        [ "$#" -ge 2 ] || { echo "orchid: $1 requires a value" >&2; return 1; }
        case "$1" in --patch) patch="$2" ;; --reason) reason="$2" ;; --requirements) requirements="$2" ;; --resolve-repairs) resolve="$2" ;; esac
        shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "orchid: unknown replan option: $1" >&2; return 1 ;;
    esac
  done
  _graph_revision_reason "$reason" || return 1
  state="$(orchid_state "$repo")"
  temp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-replan.XXXXXX")" || return 1
  trap 'rm -rf "$temp"' EXIT
  if [ "$dry_run" -eq 0 ]; then
    [ "${ORCHID_ACTOR:-operator}" = operator ] || { echo 'orchid: graph replanning is operator-owned' >&2; return 1; }
    verb_lock_acquire "$repo" || return 1
    trap 'rm -rf "$temp"; verb_lock_release "$repo"' EXIT
    epoch_require "$repo"
  fi
  _graph_revision_owned "$repo" || return 1
  case "$(fm_get "$state/roadmap.md" run_status)" in running|accepting) ;; *) echo 'orchid: replan requires a running or accepting run' >&2; return 1 ;; esac
  if [ -n "$patch" ]; then
    _graph_revision_copy_input "$patch" "$temp/patch.json" 2097152 || return 1
    orchid_json_file_valid "$temp/patch.json" || { echo 'orchid: patch must be exactly one strict JSON value' >&2; return 1; }
  else printf '{}\n' > "$temp/patch.json"; fi
  jq -e 'type == "object"' "$temp/patch.json" >/dev/null || return 1
  _graph_revision_plan_preimages "$repo" "$temp" || return 1
  graph_snapshot_file "$repo" "$temp/old.json" || return 1
  _graph_replan_risk_gate "$temp/old.json" "$temp/patch.json" || return 1
  old_revision="$(jq -r '.run.requirements_revision' "$temp/old.json")" || return 1
  new_revision="$old_revision"
  if [ -n "$requirements" ]; then
    _graph_revision_copy_input "$requirements" "$temp/requirements.md" 1048576 || return 1
    requirements="$temp/requirements.md"
    if ! cmp -s "$requirements" "$state/requirements.md"; then
      [ "$old_revision" -lt 999999 ] || { echo 'orchid: requirements revision exhausted' >&2; return 1; }
      requirements_changed=1; new_revision=$((old_revision + 1))
    else requirements=''; fi
  fi
  # A model can describe graph features before the operator enables execution.
  # Adoption follows the runtime marker, never inferred declarations.
  if graph_runtime_enabled "$repo"; then adoption=0; else adoption=1; fi
  _graph_replan_proposed "$repo" "$temp/patch.json" "$requirements" "$temp" "$new_revision" > "$temp/new.json" || return 1
  _graph_replan_roots "$repo" "$temp/patch.json" "$temp/roots.json" || return 1
  if [ "$requirements_changed" -eq 1 ] || [ "$adoption" -eq 1 ]; then
    jq -n --slurpfile old "$temp/old.json" --slurpfile proposed "$temp/new.json" \
      '($old[0].nodes | keys) + ($proposed[0].nodes | keys) | unique' > "$temp/roots.json" || return 1
  fi
  if [ "$requirements_changed" -eq 0 ] && [ "$adoption" -eq 0 ] && jq -e 'length == 0' "$temp/roots.json" >/dev/null; then echo 'unchanged graph contract'; return 0; fi
  graph_replan_impact "$temp/old.json" "$temp/new.json" "$temp/roots.json" > "$temp/impact.json" || return 1
  archive="$(_graph_revision_archive_name "$repo")" || return 1
  jq -Rn --arg values "$resolve" '$values | split(",") | map(select(length > 0)) | unique' > "$temp/resolved.json" || return 1
  jq -ne --slurpfile old "$temp/old.json" --slurpfile impact "$temp/impact.json" --slurpfile resolved "$temp/resolved.json" '
    ($old[0].nodes) as $nodes | ($impact[0].affected) as $affected |
    all($resolved[0][]; . as $id | ($affected | index($id)) != null and $nodes[$id].repair_obligation != null) and
    all($affected[]; . as $id | $nodes[$id].repair_obligation == null or ($resolved[0] | index($id)) != null)
  ' >/dev/null || { echo 'orchid: enumerate affected outstanding repair obligations with --resolve-repairs' >&2; return 1; }
  jq -n --slurpfile old "$temp/old.json" --slurpfile new "$temp/new.json" --slurpfile patch "$temp/patch.json" \
    --slurpfile impact "$temp/impact.json" --slurpfile resolved "$temp/resolved.json" --arg archive ".orchid/revisions/$archive" '
    $old[0].nodes as $old | $new[0].nodes as $new |
    {contract:1,nodes:(reduce $impact[0].affected[] as $id ({};
      $old[$id] as $node | .[$id] = {
        delete:($new | has($id) | not), new_task:($old | has($id) | not), outcome:($new[$id].outcome // $node.outcome),
        resolve_repair:(($resolved[0] | index($id)) != null),
        fields:(($patch[0][$id] // {}) +
          (if ($patch[0][$id] // {} | has("risk_tier")) then
            {blocking_severity:(if $patch[0][$id].risk_tier == "low" then "high" else "medium" end)}
           else {} end) + {contract_revision:(if $node == null then 1 else ($node.contract_revision +
          (if ($impact[0].contracts | index($id)) != null then 1 else 0 end)) end)}),
        checkpoint:(if $node != null and ($new | has($id)) and $node.candidate_sha != "" then
          {base_sha:(if $node.base_sha == "" then $node.candidate_sha else $node.base_sha end),
           candidate_sha:$node.candidate_sha,source_generation:$node.execution_generation,
           source_contract_revision:$node.contract_revision,implementer_engine_id:$node.implementer_engine_id,
           source_archive:$archive} else null end)
      }))}
  ' > "$temp/plan.json" || return 1
  jq -ne --slurpfile old "$temp/old.json" --slurpfile plan "$temp/plan.json" '
    all($plan[0].nodes | to_entries[] | select(.value.delete == true);
      .key as $id | $old[0].nodes[$id].unresolved_objection == "")
  ' >/dev/null || { echo 'orchid: cannot delete a task with an unresolved objection; arbitrate it first' >&2; return 1; }
  jq -e 'all(.nodes[]; .fields.contract_revision <= 999999)' "$temp/plan.json" >/dev/null || { echo 'orchid: contract revision exhausted' >&2; return 1; }
  _graph_revision_check_candidates "$repo" "$temp/plan.json" || return 1
  ids="$(jq -r '.nodes | keys[]' "$temp/plan.json")" || return 1
  jq -n --arg reason "$reason" --slurpfile resolved "$temp/resolved.json" --argjson adoption "$adoption" \
    '{contract:1,actor:"operator",reason:$reason,retired_repairs:$resolved[0],adopted_legacy:($adoption == 1)}' > "$temp/decision.json" || return 1
  if [ "$dry_run" -eq 1 ]; then cat "$temp/plan.json"; return 0; fi
  _graph_replan_new_preflight "$repo" "$temp/plan.json" || return 1
  revision_preflight "$repo" "$(jq -r '.nodes | to_entries[] | select(.value.new_task != true) | .key' "$temp/plan.json")" graph || return 1
  _graph_revision_publish "$repo" "$temp" "$archive" "$reason" graph_replan "$requirements" || return 1
  printf 'replanned: %s\narchive: .orchid/revisions/%s\n' "$(tr '\n' ' ' <<< "$ids")" "$archive"
)
