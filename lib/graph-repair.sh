#!/usr/bin/env bash
# Opt-in repair routes structured current verifier findings to its immediate
# target. Objections remain their owner's authority throughout this operation.
_graph_repair_load() {
  source "$ORCHID_ROOT/lib/graph-replan.sh"
  _graph_revision_load
  source "$ORCHID_ROOT/lib/envelope.sh"
  source "$ORCHID_ROOT/lib/review.sh"
  source "$ORCHID_ROOT/lib/graph-runtime.sh"
}

# Collect only kernel-filed, current, scope-complete reviewer evidence. Reuse
# the runtime's binding owner and the driver's existing severity threshold.
_graph_repair_evidence() (
  local repo="$1" id="$2" snapshot="$3" dest="$4" temp f candidate attempt need count=0 threshold hash
  temp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-repair-evidence.XXXXXX")" || return 1
  trap 'rm -rf "$temp"' EXIT
  graph_job_binding "$repo" "$id" "$temp/expected.json" "$snapshot" || return 1
  candidate="$(jq -r --arg id "$id" '.nodes[$id].candidate_sha' "$snapshot")" || return 1
  attempt="$(jq -r --arg id "$id" '.nodes[$id].attempt' "$snapshot")" || return 1
  need="$(review_required_count "$(jq -r --arg id "$id" '.nodes[$id].risk_tier' "$snapshot")")" || return 1
  threshold="$(fm_get "$repo/.orchid/tasks/$id.md" blocking_severity)"
  [ -n "$threshold" ] || threshold=medium
  : > "$temp/evidence.jsonl"
  for f in "$repo/.orchid/reviews/$id-a$attempt-reviewer"*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    _graph_revision_copy_input "$f" "$temp/review.json" 1048576 || return 1
    orchid_json_file_valid "$temp/review.json" || continue
    _graph_runtime_binding_equal "$temp/expected.json" "$temp/review.json" || continue
    jq -e --arg id "$id" --arg candidate "$candidate" '
      .task == $id and .operation == "review" and .status == "ok" and .candidate_sha == $candidate
    ' "$temp/review.json" >/dev/null || continue
    jq -e '.scope_complete == true' "$temp/review.json" >/dev/null || {
      echo 'orchid: repair evidence includes an incomplete reviewer scope' >&2; return 1;
    }
    count=$((count + 1))
    [ "$count" -le 32 ] || { echo 'orchid: repair evidence exceeds 32 current reviews' >&2; return 1; }
    hash="$(_orchid_stream_sha256 < "$temp/review.json")" || return 1
    jq -c --arg path ".orchid/reviews/${f##*/}" --arg sha256 "$hash" \
      '{path:$path,sha256:$sha256,findings:(.findings // []),verdict,scope_complete}' "$temp/review.json" >> "$temp/evidence.jsonl" || return 1
    if drive_envelope_has_blocking_finding "$temp/review.json" "$threshold"; then touch "$temp/blocking"; fi
  done
  [ "$count" -ge "$need" ] || { echo 'orchid: repair requires complete current scope-complete review evidence' >&2; return 1; }
  jq -s --argjson blocking "$(if [ -f "$temp/blocking" ]; then echo true; else echo false; fi)" \
    '{complete:true,blocking:$blocking,evidence:.}' "$temp/evidence.jsonl" > "$dest"
)

graph_repair_command() (
  local repo id dry_run=0 temp state target rounds budget ids archive expected recorded source_candidate
  repo="$(orchid_physical_dir "$1")" || return 1; id="${2:-}"; shift 2
  _graph_repair_load
  case "$id" in ''|plan|*[!A-Za-z0-9_-]*) echo 'orchid: repair requires a verifier ID' >&2; return 1 ;; esac
  if [ "$#" -gt 0 ]; then [ "$#" -eq 1 ] && [ "$1" = --dry-run ] || return 1; dry_run=1; fi
  temp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-repair.XXXXXX")" || return 1
  trap 'rm -rf "$temp"' EXIT
  if [ "$dry_run" -eq 0 ]; then
    verb_lock_acquire "$repo" || return 1
    trap 'rm -rf "$temp"; verb_lock_release "$repo"' EXIT
    epoch_require "$repo"
  fi
  state="$(orchid_state "$repo")"
  _graph_revision_owned "$repo" || return 1
  graph_runtime_enabled "$repo" || { echo 'orchid: repair requires graph mode' >&2; return 1; }
  case "$(fm_get "$state/roadmap.md" run_status)" in running|accepting) ;; *) echo 'orchid: repair requires a running run' >&2; return 1 ;; esac
  _graph_revision_plan_preimages "$repo" "$temp" || return 1
  graph_snapshot_file "$repo" "$temp/old.json" || return 1
  target="$(jq -er --arg id "$id" '.nodes[$id] | select(.verifies != null and .repair_target == .verifies) | .verifies' "$temp/old.json")" || {
    echo 'orchid: repair is opt-in and may target only the immediate verifies parent' >&2; return 1;
  }
  fm_has "$state/tasks/$target.md" repair_budget || {
    echo 'orchid: repair target must explicitly declare repair_budget' >&2; return 1;
  }
  case "$(jq -r --arg id "$id" '.nodes[$id].status' "$temp/old.json")" in reviewing|arbitrating) ;; *) echo 'orchid: repair requires a reviewer-complete active verifier' >&2; return 1 ;; esac
  expected="$(graph_expected_target "$temp/old.json" "$id")" || return 1
  recorded="$(jq -c --arg id "$id" '.nodes[$id].verification_target' "$temp/old.json")" || return 1
  jq -en --argjson expected "$expected" --argjson recorded "$recorded" '$expected != null and $expected == $recorded' >/dev/null || {
    echo 'orchid: verifier target binding is obsolete' >&2; return 1;
  }
  graph_completion_ready "$repo" "$id" "$temp/old.json" || return 1
  _graph_runtime_commit "$repo" "$(jq -r --arg id "$target" '.nodes[$id].base_sha' "$temp/old.json")" || {
    echo 'orchid: repair target has no valid immutable base commit' >&2; return 1;
  }
  _graph_repair_evidence "$repo" "$id" "$temp/old.json" "$temp/failed.json" || return 1
  jq -e '.blocking == true' "$temp/failed.json" >/dev/null || { echo 'orchid: no structured blocking finding authorizes repair' >&2; return 1; }
  rounds="$(jq -r --arg id "$target" '.nodes[$id].repair_rounds' "$temp/old.json")" || return 1
  budget="$(jq -r --arg id "$target" '.nodes[$id].repair_budget' "$temp/old.json")" || return 1
  [ "$rounds" -lt "$budget" ] && [ "$rounds" -lt 999999 ] || { echo "orchid: repair budget exhausted for $target ($rounds/$budget)" >&2; return 1; }
  ids="$(graph_affected "$temp/old.json" "$target")" || return 1
  archive="repair-$target-r$((rounds + 1))"
  source_candidate="$(jq -r --arg id "$target" '.nodes[$id].candidate_sha' "$temp/old.json")" || return 1
  [ -n "$source_candidate" ] || { echo 'orchid: repair target has no immutable candidate' >&2; return 1; }
  case "${#source_candidate}" in 40|64) ;; *) echo 'orchid: repair candidate must be a full commit ID' >&2; return 1 ;; esac
  case "$source_candidate" in *[!0-9a-f]*) echo 'orchid: repair candidate must be hexadecimal' >&2; return 1 ;; esac
  jq -n --slurpfile old "$temp/old.json" --slurpfile failed "$temp/failed.json" --arg source "$target" --arg verifier "$id" \
    --arg archive ".orchid/revisions/$archive" --argjson round "$((rounds + 1))" '
    $old[0].nodes[$source] as $source_node | $old[0].nodes[$verifier] as $verifier_node |
    {contract:1,source:($source_node | {task:.id,contract_revision,execution_generation,candidate_sha}),
     verifier:($verifier_node | {task:.id,contract_revision,execution_generation,attempt,candidate_sha,verification_target}),
     failed_evidence:($failed[0].evidence | map(. + {source_path:.path,
       path:($archive + "/reviews/" + (.path | split("/") | last))})),archive:$archive,round:$round}
  ' > "$temp/obligation.json" || return 1
  [ "$(wc -c < "$temp/obligation.json" | tr -d ' ')" -le 65536 ] || { echo 'orchid: repair obligation exceeds 64KiB; operator review required' >&2; return 1; }
  printf '%s\n' "$ids" | jq -Rsc 'split("\n") | map(select(length > 0))' > "$temp/affected.json" || return 1
  jq -n --slurpfile old "$temp/old.json" --slurpfile obligation "$temp/obligation.json" --slurpfile affected "$temp/affected.json" \
    --arg source "$target" --arg archive ".orchid/revisions/$archive" --argjson rounds "$((rounds + 1))" '
    {contract:1,nodes:(reduce $affected[0][] as $id ({};
      $old[0].nodes[$id] as $node |
      .[$id] = {delete:false,outcome:$node.outcome,checkpoint:null,fields:{}} |
      if $id == $source then .[$id].fields = {
        repair_rounds:$rounds,repair_obligation:$obligation[0],
        base_sha:$node.base_sha,candidate_sha:$node.candidate_sha,implementer_engine_id:$node.implementer_engine_id,
        candidate_reuse_from:{base_sha:$node.base_sha,candidate_sha:$node.candidate_sha,
          source_generation:$node.execution_generation,source_contract_revision:$node.contract_revision,
          implementer_engine_id:$node.implementer_engine_id,source_archive:$archive}
      } else . end))}
  ' > "$temp/plan.json" || return 1
  _graph_revision_check_candidates "$repo" "$temp/plan.json" || return 1
  # Also validate the implementation baseline, which deliberately remains pending.
  git -C "$repo" cat-file -e "$source_candidate^{commit}" || return 1
  jq -n --arg actor kernel --arg source "$target" --arg verifier "$id" \
    '{contract:1,actor:$actor,source:$source,verifier:$verifier}' > "$temp/decision.json" || return 1
  if [ "$dry_run" -eq 1 ]; then cat "$temp/plan.json"; return 0; fi
  revision_preflight "$repo" "$ids" repair || return 1
  _graph_revision_publish "$repo" "$temp" "$archive" "structured blocking verifier finding from $id" graph_repair || return 1
  printf 'repair: %s -> %s; round %s/%s; archive: .orchid/revisions/%s\n' "$id" "$target" "$((rounds + 1))" "$budget" "$archive"
)

# Called under the public approval verb's lock. A fresh required verifier must
# answer the failed obligation in a later source AND verifier generation.
graph_repair_approval_gate() (
  local repo="$1" id="$2" temp obligation verifier
  _graph_repair_load
  obligation="$(fm_get "$repo/.orchid/tasks/$id.md" repair_obligation)" || return 1
  [ -n "$obligation" ] || return 0
  temp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-repair-approval.XXXXXX")" || return 1
  trap 'rm -rf "$temp"' EXIT
  printf '%s\n' "$obligation" > "$temp/obligation.json"
  orchid_json_file_valid "$temp/obligation.json" || return 1
  graph_snapshot_file "$repo" "$temp/current.json" || return 1
  verifier="$(jq -er '.verifier.task | select(type == "string")' "$temp/obligation.json")" || return 1
  jq -e --arg source "$id" --arg verifier "$verifier" --slurpfile obligation "$temp/obligation.json" '
    $obligation[0] as $failed |
    $failed.contract == 1 and $failed.source.task == $source and
    .nodes[$source].contract_revision == $failed.source.contract_revision and
    .nodes[$verifier].contract_revision == $failed.verifier.contract_revision and
    .nodes[$source].execution_generation > $failed.source.execution_generation and
    .nodes[$verifier].execution_generation > $failed.verifier.execution_generation and
    .nodes[$verifier].status == "done" and .nodes[$verifier].verifies == $source and
    .nodes[$source].repair_rounds == $failed.round
  ' "$temp/current.json" >/dev/null || { echo 'orchid: machine repair obligation lacks a fresh completed verifier' >&2; return 1; }
  graph_completion_ready "$repo" "$id" "$temp/current.json" || return 1
  _graph_repair_evidence "$repo" "$verifier" "$temp/current.json" "$temp/approved.json" || return 1
  jq -e '.blocking == false and all(.evidence[]; .verdict == "approve" and .scope_complete == true)' "$temp/approved.json" >/dev/null || {
    echo 'orchid: current verifier evidence does not approve the repair' >&2; return 1;
  }
)

graph_repair_approval_complete() {
  local repo="$1" id="$2" obligation hash
  obligation="$(fm_get "$repo/.orchid/tasks/$id.md" repair_obligation)" || return 1
  [ -n "$obligation" ] || return 0
  graph_repair_approval_gate "$repo" "$id" || return 1
  hash="$(printf '%s' "$obligation" | _orchid_stream_sha256)" || return 1
  ORCHID_REPO="$repo" "$ORCHID_ROOT/bin/orchid" journal add --task "$id" --kind graph_repair_resolved \
    "fresh bound verifier approval resolved machine obligation $hash" || return 1
  fm_set "$repo/.orchid/tasks/$id.md" repair_obligation ''
}
