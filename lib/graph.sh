#!/usr/bin/env bash
# Pure delivery graph model. Source after common.sh, frontmatter.sh,
# manifest.sh, archetype.sh, json.sh and the existing schedule_split_deps helper.
# Contract-bearing models additionally require output_contract_validate from
# output-contract.sh; graph never imports the contract or execution layers.
# No process, worktree or durable-state effects belong here. Snapshot scratch
# files are invocation-local and removed before the subshell exits.
_ORCHID_GRAPH_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

_ORCHID_GRAPH_JQ='
  def graph_error($message): error("graph: " + $message);
  def ensure($condition; $message): if $condition then . else graph_error($message) end;
  def id_ok: type == "string" and test("^[A-Za-z0-9_-]+$") and . != "plan";
  def text($r; $key; $default):
    if ($r|has($key)) then
      $r[$key] | if . == null then "" elif type == "string" then .
        elif type == "boolean" or type == "number" then tostring
        else graph_error($key + " must be scalar") end
    else $default end;
  def number_field($r; $key; $default; $zero; $maximum; $empty_default):
    if (($r|has($key))|not) or ($empty_default and $r[$key] == "") then $default
    else text($r; $key; "") as $value
      | if ($value|test(if $zero then "^(0|[1-9][0-9]*)$" else "^[1-9][0-9]*$" end))
        then ($value|tonumber) as $number
          | if $number <= $maximum then $number else graph_error($key + " exceeds its bound") end
        else graph_error("invalid " + $key + " decimal") end
    end;
  def object_field($r; $key):
    if (($r|has($key))|not) or $r[$key] == "" or $r[$key] == null then null
    else ($r[$key] | if type == "string" then
      try fromjson catch graph_error($key + " is not valid JSON") else . end) as $value
      | if ($value|type) == "object" then $value else graph_error($key + " must be an object") end
    end;
  def input_ids($node): ($node.depends_on + (if $node.verifies == null then [] else [$node.verifies] end)) | unique;
  def closure($roots; $adjacency):
    {queue:($roots|unique),seen:{}}
    | until((.queue|length) == 0;
        .queue[0] as $id | .queue = .queue[1:]
        | if .seen[$id] then . else .seen[$id] = true | .queue += ($adjacency[$id] // []) end)
    | .seen | keys;
  def effective_terms($node; $nodes):
    {acceptance_criteria:$node.acceptance_criteria,verification_commands:$node.verification_commands}
    + (if $node.output_contract == null then {} else {output_contract:$node.output_contract} end)
    + (if $node.verifies == null then {} else {verifies:$node.verifies} end)
    + (if $node.repair_target == null then {} else {repair_target:$node.repair_target} end)
    + (if $node.repair_declared or $node.verifies != null then {repair_budget:$node.repair_budget} else {} end)
    + ([$nodes[] | select(.verifies == $node.id) | {id,contract_revision}] | sort_by(.id)
       | if length == 0 then {} else {verification_obligations:.} end);
  def normalized_node($r; $outcome):
    text($r; "id"; "") as $id
    | {
      id:$id,title:text($r;"title";$id),status:text($r;"status";"pending"),
      archetype:(text($r;"archetype";"feature") | if . == "" then "feature" else . end),outcome:$outcome,
      depends_on:($r._graph_deps // []),
      verifies:(text($r;"verifies";"") | if . == "" then null else . end),
      contract_revision:number_field($r;"contract_revision";1;false;999999;false),
      execution_generation:number_field($r;"execution_generation";1;false;999999;false),
      attempts:number_field($r;"attempts";0;true;999999;true),
      branch:text($r;"branch";("task/"+$id)),worktree:text($r;"worktree";""),
      base_sha:text($r;"base_sha";""),candidate_sha:text($r;"candidate_sha";""),
      acceptance_criteria:text($r;"acceptance_criteria";""),verification_commands:text($r;"verification_commands";""),
      output_contract:object_field($r;"output_contract"),
      repair_target:(text($r;"repair_target";"") | if . == "" then null else . end),
      repair_budget:number_field($r;"repair_budget";3;false;999999;true),
      repair_rounds:number_field($r;"repair_rounds";0;true;999999;true),
      repair_declared:($r|has("repair_budget") or has("repair_target")),
      attempt_budget:(if text($r;"attempt_budget";"") == "" then null
        else number_field($r;"attempt_budget";null;false;999999;false) end),
      resources_raw:text($r;"resources";""),
      exclusive:(text($r;"exclusive";"false") | if . == "true" then true
        elif . == "false" or . == "" then false else graph_error("exclusive must be true or false") end),
      risk_tier:text($r;"risk_tier";"low"),
      implementer_engine_id:text($r;"implementer_engine_id";""),
      unresolved_objection:text($r;"unresolved_objection";""),
      unresolved_objection_by:text($r;"unresolved_objection_by";""),
      verification_target:object_field($r;"verification_target"),
      candidate_reuse_from:object_field($r;"candidate_reuse_from"),
      repair_obligation:object_field($r;"repair_obligation"),
      graph_wait:object_field($r;"graph_wait"),
      graph_declared:($r|has("verifies") or has("output_contract") or has("repair_target") or has("repair_budget"))
    } | .attempt = (.attempts + 1);
  def topo_order($vertices; $edges):
    {indegree:(reduce $vertices[] as $id ({}; .[$id]=0)),adjacency:{},queue:[],order:[]}
    | reduce $edges[] as $edge (.; .indegree[$edge[1]] += 1
        | .adjacency[$edge[0]] = ((.adjacency[$edge[0]] // []) + [$edge[1]]))
    | .queue = [.indegree|to_entries[]|select(.value == 0)|.key]
    | until((.queue|length) == 0;
        .queue[0] as $id | .queue = .queue[1:] | .order += [$id]
        | reduce (.adjacency[$id] // [])[] as $next (.; .indegree[$next] -= 1
            | if .indegree[$next] == 0 then .queue += [$next] else . end))
    | if (.order|length) == ($vertices|length) then .order else graph_error("milestone dependency cycle") end;
  def milestone_graph($nodes):
    {vertices:[$nodes[] | .id+":candidate",.id+":done"],
      edges:([$nodes[] as $node
        | [$node.id+":candidate",$node.id+":done"],
          ($node.depends_on[] | [.+":done",$node.id+":candidate"]),
          (if $node.verifies == null then empty else
            [$node.verifies+":candidate",$node.id+":candidate"],
            [$node.id+":done",$node.verifies+":done"] end)] | unique)};
  def safe_counter: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
  def wait_ok:
    type == "object" and (.started_at|safe_counter) and (.seconds|safe_counter)
    and (.candidate_sha|type) == "string"
    and (.generation|type) == "number" and .generation >= 1 and .generation <= 999999 and (.generation|floor) == .generation
    and (.attempt|type) == "number" and .attempt >= 1 and .attempt <= 1000000 and (.attempt|floor) == .attempt;
  def validate_graph:
    . as $snapshot
    | ensure(.contract == 1 and (.nodes|type) == "object"; "invalid snapshot contract")
    | ensure((.nodes|length) <= 256; "node limit exceeded (256)")
    | ensure((.run|type) == "object" and (.run.id|type) == "string" and (.run.digest|type) == "string"; "invalid run identity")
    | ensure((.run.requirements_revision|type) == "number" and .run.requirements_revision >= 1 and .run.requirements_revision <= 999999 and (.run.requirements_revision|floor) == .run.requirements_revision; "invalid requirements_revision")
    | ensure(all(.nodes|to_entries[]; (.key|id_ok) and .value.id == .key); "task ID and file identity differ")
    | ensure(all(.nodes[]; (.status as $status | ["pending","implementing","testing","reviewing","arbitrating","merging","rework","blocked","done"]|index($status)) != null); "invalid status")
    | ensure(all(.nodes[]; (.outcome == "code" or .outcome == "report") and (.depends_on|type) == "array"); "invalid node outcome or dependencies")
    | ensure(all(.nodes[]; . as $node | all(["id","title","status","archetype","branch","worktree","base_sha","candidate_sha","acceptance_criteria","verification_commands","resources_raw","risk_tier","implementer_engine_id","unresolved_objection","unresolved_objection_by"][]; . as $key | ($node[$key]|type) == "string")); "node text fields must be strings")
    | ensure(all(.nodes[]; .depends_on == (.depends_on|unique) and (.verifies == null or (.verifies|id_ok))); "invalid normalized input declarations")
    | ensure(([.nodes[]|input_ids(.)[]]|length) <= 4096; "edge limit exceeded (4096)")
    | ensure(all(.nodes[]; all(input_ids(.)[]; . as $id | ($id|id_ok) and ($snapshot.nodes|has($id)))); "unknown or invalid input task")
    | ensure(all(.nodes[]; .verifies == null or (.verifies != .id and .outcome == "report")); "self verification or non-report verifier")
    | ensure(all(.nodes[]; .graph_wait == null or (.graph_wait|wait_ok)); "invalid graph_wait accounting")
    | ensure((.graph_enabled|type) == "boolean"; "invalid graph_enabled flag")
    | ensure(.graph_enabled or (all(.nodes[]; .verifies == null and .output_contract == null and (.repair_declared|not))); "graph features require graph_enabled")
    | ensure(all(.nodes[]; (.contract_revision|type) == "number" and .contract_revision >= 1 and .contract_revision <= 999999 and (.contract_revision|floor) == .contract_revision
        and (.execution_generation|type) == "number" and .execution_generation >= 1 and .execution_generation <= 999999 and (.execution_generation|floor) == .execution_generation); "invalid node version")
    | ensure(all(.nodes[]; (.attempts|safe_counter) and .attempts <= 999999 and .attempt == (.attempts+1)
        and (.repair_rounds|safe_counter) and .repair_rounds <= 999999
        and (.repair_budget|safe_counter) and .repair_budget >= 1 and .repair_budget <= 999999
        and (.attempt_budget == null or ((.attempt_budget|safe_counter) and .attempt_budget >= 1 and .attempt_budget <= 999999))); "invalid execution or repair counters")
    | ensure(all(.nodes[]; (.exclusive|type) == "boolean" and (.repair_declared|type) == "boolean" and (.graph_declared|type) == "boolean"
        and (.output_contract == null or (.output_contract|type) == "object")
        and (.verification_target == null or (.verification_target|type) == "object")
        and (.candidate_reuse_from == null or (.candidate_reuse_from|type) == "object")
        and (.repair_obligation == null or (.repair_obligation|type) == "object")); "invalid typed contract or kernel metadata")
    | ensure(all(.nodes[]; .terms == effective_terms(.;$snapshot.nodes)); "effective terms differ from declarations")
    | ensure(all(.nodes[]; .id as $id | .required_verifiers == ([$snapshot.nodes[]|select(.verifies == $id)|.id]|sort)); "required verifier membership differs")
    | milestone_graph(.nodes) as $milestones
    | topo_order($milestones.vertices;$milestones.edges) as $order
    | ensure(($order|length) == (2*(.nodes|length)); "invalid milestone graph")
    | ensure(all(.nodes[]; .verifies as $next
        | {next:$next,depth:0}
        | until(.next == null or .depth > 32; .next as $id | .next=$snapshot.nodes[$id].verifies | .depth+=1)
        | .depth <= 32); "verification depth limit exceeded (32)")
    | ensure(all(.nodes[]; .repair_target == null or
        (.verifies != null and .repair_target == .verifies)); "repair_target must be the immediate verifies target")
    | .;
  def require_node($id): if (.nodes|has($id)) then .nodes[$id] else graph_error("unknown task " + $id) end;
  def target_binding($snapshot; $id):
    ($snapshot|require_node($id)) as $node
    | if $node.verifies == null then null else
      ($snapshot|require_node($node.verifies))
      | {task:.id,contract_revision,execution_generation,base_sha,candidate_sha,attempt,contract_terms:.terms}
    end;
'

_graph_jq() {
  local program="$1" input="$2"; shift 2
  jq "$@" "$_ORCHID_GRAPH_JQ"$'\n'"$program" "$input"
}

_graph_json_input() {
  declare -F orchid_json_file_valid >/dev/null || { printf 'orchid: graph requires orchid_json_file_valid prerequisite\n' >&2; return 1; }
  if ! orchid_json_file_valid "$1"; then
    printf 'orchid: graph requires valid UTF-8 and one JSON document: %s\n' "$2" >&2
    return 1
  fi
}

# graph_snapshot <repo> [semantic-overlay-file]
# Overlays are objects keyed by task ID: an object declares semantic field
# changes/additions, null removes an existing node. Runtime fields are refused.
graph_snapshot() (
  graph_repo="$(orchid_physical_dir "$1")" || exit 1
  graph_overlay="${2:-}"
  ORCHID_ROOT="${ORCHID_ROOT:-$_ORCHID_GRAPH_SOURCE_ROOT}"
  graph_state="$graph_repo/.orchid"
  for graph_helper in fm_json schedule_split_deps archetype_validate _orchid_agent_context_input_owned _orchid_stream_sha256 orchid_json_file_valid; do
    declare -F "$graph_helper" >/dev/null || { printf 'orchid: graph requires primitive helper %s\n' "$graph_helper" >&2; exit 1; }
  done
  for graph_relative in .orchid .orchid/tasks; do
    _orchid_agent_context_input_owned "$graph_repo" "$graph_repo" "$graph_relative" directory || exit 1
  done
  for graph_relative in .orchid/roadmap.md .orchid/requirements.md; do
    _orchid_agent_context_input_owned "$graph_repo" "$graph_repo" "$graph_relative" file || exit 1
  done
  graph_tmp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-graph.XXXXXX")" || exit 1
  trap 'rm -rf "$graph_tmp"' EXIT
  printf '[\n' > "$graph_tmp/rows.json" || exit 1
  graph_count=0
  for graph_file in "$graph_state/tasks"/*.md; do
    [ -e "$graph_file" ] || [ -L "$graph_file" ] || continue
    graph_id="${graph_file##*/}"; graph_id="${graph_id%.md}"
    [ "$graph_id" != plan ] || continue
    case "$graph_id" in ''|*[!A-Za-z0-9_-]*) printf 'orchid: graph task filename is invalid: %s\n' "$graph_file" >&2; exit 1 ;; esac
    graph_count=$((graph_count+1))
    [ "$graph_count" -le 256 ] || { printf 'orchid: graph node limit exceeded (256)\n' >&2; exit 1; }
    _orchid_agent_context_input_owned "$graph_repo" "$graph_repo" ".orchid/tasks/$graph_id.md" file || exit 1
    # Write bytes before shell capture: command substitution can discard NUL.
    # The encoder adds one formatting newline outside the metadata byte bound.
    if ! fm_json "$graph_file" > "$graph_tmp/node.json"; then
      printf 'orchid: graph cannot read UTF-8 JSON task metadata: %s\n' "$graph_id" >&2
      exit 1
    fi
    graph_bytes="$(wc -c < "$graph_tmp/node.json")"
    [ "$graph_bytes" -le 262145 ] || { printf 'orchid: graph node data exceeds byte bound\n' >&2; exit 1; }
    if ! graph_why="$(fm_check "$graph_file" id)"; then printf 'orchid: graph damaged task %s: %s\n' "$graph_id" "$graph_why" >&2; exit 1; fi
    if [ "$graph_count" -gt 1 ]; then printf ',\n' >> "$graph_tmp/rows.json" || exit 1; fi
    # IDs already passed the ASCII whitelist. Raw JSON bytes remain owned by
    # fm_json; concatenate them unchanged and validate the bounded batch once.
    printf '{"file":"%s","raw":' "$graph_id" >> "$graph_tmp/rows.json" || exit 1
    cat "$graph_tmp/node.json" >> "$graph_tmp/rows.json" || exit 1
    printf '}' >> "$graph_tmp/rows.json" || exit 1
  done
  printf '\n]\n' >> "$graph_tmp/rows.json" || exit 1
  _graph_json_input "$graph_tmp/rows.json" 'task metadata batch' || exit 1
  if [ -z "$graph_overlay" ]; then
    printf '{}\n' > "$graph_tmp/overlay.json"
    graph_overlay="$graph_tmp/overlay.json"
  else
    [ -f "$graph_overlay" ] && [ ! -L "$graph_overlay" ] || { printf 'orchid: graph overlay must be a regular file\n' >&2; exit 1; }
    graph_bytes="$(wc -c < "$graph_overlay")"
    [ "$graph_bytes" -le 2097152 ] || { printf 'orchid: graph overlay byte limit exceeded\n' >&2; exit 1; }
    head -c 2097153 < "$graph_overlay" > "$graph_tmp/overlay.json" || exit 1
    graph_overlay="$graph_tmp/overlay.json"
    graph_bytes="$(wc -c < "$graph_overlay")"
    [ "$graph_bytes" -le 2097152 ] || { printf 'orchid: graph overlay byte limit exceeded\n' >&2; exit 1; }
  fi
  _graph_json_input "$graph_overlay" overlay || exit 1
  _graph_jq '
    if ($overlay|length) != 1 or ($overlay[0]|type) != "object" then graph_error("overlay must be one object") else . end
    | reduce .[] as $row ({}; if $row.raw.id != $row.file then graph_error("task ID and filename differ") else .[$row.file]=$row.raw end)
    | reduce ($overlay[0]|to_entries[]) as $entry (.;
      if ($entry.key|id_ok|not) then graph_error("invalid overlay task ID")
      elif $entry.value == null then
        if has($entry.key) then del(.[$entry.key]) else graph_error("overlay deletes unknown task") end
      elif ($entry.value|type) != "object" then graph_error("overlay task must be an object or null")
      elif ([$entry.value|keys[]] - ["id","title","archetype","acceptance_criteria","verification_commands","depends_on","verifies","output_contract","repair_target","repair_budget","resources","exclusive","risk_tier","stop_condition","operator_prerequisite"]|length) > 0 then graph_error("overlay contains runtime or unknown fields")
      elif any($entry.value|to_entries[]|select(.key != "output_contract")|.value|..|strings; contains("\n") or contains("\u0000")) then graph_error("overlay FM scalar fields must be single-line and NUL-free; use literal escapes")
      elif ($entry.value|has("id")) and $entry.value.id != $entry.key then graph_error("overlay ID differs from its key")
      else .[$entry.key] = ((.[$entry.key] // {id:$entry.key}) + $entry.value) end)
    | ensure(length <= 256; "node limit exceeded (256)")
  ' "$graph_tmp/rows.json" --slurpfile overlay "$graph_overlay" > "$graph_tmp/raw.json" || exit 1
  : > "$graph_tmp/deps.jsonl"
  jq -r 'keys[]' "$graph_tmp/raw.json" > "$graph_tmp/node-ids" || exit 1
  while IFS= read -r graph_id; do
    graph_deps="$(jq -r --arg id "$graph_id" '.[$id].depends_on // "" | if type == "array" and all(.[];type == "string") then join(",") elif type == "string" then . else error("depends_on must be a string or ID array") end' "$graph_tmp/raw.json")" || exit 1
    graph_dep_json="$(schedule_split_deps "$graph_deps" | jq -Rsc 'split("\n")|map(select(length>0))|unique')" || exit 1
    printf '{"id":"%s","deps":%s}\n' "$graph_id" "$graph_dep_json" >> "$graph_tmp/deps.jsonl"
  done < "$graph_tmp/node-ids"
  : > "$graph_tmp/archetypes.jsonl"
  jq -r '[.[]|.archetype // "feature"|if . == "" then "feature" else . end]|unique[]' "$graph_tmp/raw.json" > "$graph_tmp/archetype-names" || exit 1
  while IFS= read -r graph_arch; do
    case "$graph_arch" in ''|*[!A-Za-z0-9_-]*) printf 'orchid: graph invalid archetype name\n' >&2; exit 1 ;; esac
    archetype_validate "$graph_arch" >/dev/null || exit 1
    graph_outcome="$(archetype_outcome "$graph_arch")" || exit 1
    printf '{"name":"%s","outcome":"%s"}\n' "$graph_arch" "$graph_outcome" >> "$graph_tmp/archetypes.jsonl"
  done < "$graph_tmp/archetype-names"
  if [ -f "$graph_state/roadmap.md" ]; then
    if ! fm_json "$graph_state/roadmap.md" > "$graph_tmp/roadmap.json"; then
      printf 'orchid: graph cannot read UTF-8 JSON roadmap metadata\n' >&2
      exit 1
    fi
    graph_bytes="$(wc -c < "$graph_tmp/roadmap.json")"
    [ "$graph_bytes" -le 262145 ] || { printf 'orchid: graph roadmap metadata exceeds byte bound\n' >&2; exit 1; }
    _graph_json_input "$graph_tmp/roadmap.json" 'roadmap metadata' || exit 1
    if ! graph_why="$(fm_check "$graph_state/roadmap.md")"; then printf 'orchid: graph damaged roadmap: %s\n' "$graph_why" >&2; exit 1; fi
  else printf '{}\n' > "$graph_tmp/roadmap.json"; fi
  graph_digest=""
  if [ -f "$graph_state/requirements.md" ]; then graph_digest="$(_orchid_stream_sha256 < "$graph_state/requirements.md")" || exit 1; fi
  _graph_jq '
    ensure(($deps|length) == length and ([$deps[].id]|unique|length) == length
      and ([$deps[].id]|sort) == keys; "dependency normalization coverage differs from graph nodes")
    | (reduce $archetypes[] as $entry ({}; .[$entry.name]=$entry.outcome)) as $outcomes
    | ensure(all(.[]; (text(.;"archetype";"feature")|if . == "" then "feature" else . end) as $name | $outcomes|has($name)); "archetype normalization coverage differs")
    |
    (reduce $deps[] as $entry (.; .[$entry.id]._graph_deps=$entry.deps)) as $raw
    | ($raw|with_entries(.value as $r | .value=normalized_node($r;$outcomes[(text($r;"archetype";"feature")|if . == "" then "feature" else . end)]))) as $nodes
    | ($nodes|with_entries(.key as $id | .value.required_verifiers=([$nodes[]|select(.verifies == $id)|.id]|sort)
        | .value.terms=effective_terms(.value;$nodes))) as $complete
    | $roadmap[0] as $run
    | {contract:1,graph_enabled:(number_field($run;"graph_contract";0;false;1;false) == 1 or any($complete[];.graph_declared)),
        run:{id:text($run;"run_id";""),requirements_revision:number_field($run;"requirements_revision";1;false;999999;false),digest:$digest},
        limits:{nodes:256,edges:4096,verification_depth:32,node_metadata_bytes:262144,roadmap_metadata_bytes:262144,overlay_bytes:2097152},nodes:$complete}
  ' "$graph_tmp/raw.json" --slurpfile deps "$graph_tmp/deps.jsonl" --slurpfile archetypes "$graph_tmp/archetypes.jsonl" --slurpfile roadmap "$graph_tmp/roadmap.json" --arg digest "$graph_digest" > "$graph_tmp/snapshot.json" || exit 1
  graph_validate "$graph_tmp/snapshot.json" || exit 1
  cat "$graph_tmp/snapshot.json"
)

graph_validate() {
  local definitions row id definition diagnostic
  _graph_json_input "$1" snapshot || return 1
  definitions="$(_graph_jq 'validate_graph | .nodes | to_entries[] | select(.value.output_contract != null) | {id:.key,definition:.value.output_contract}' "$1" -c)" || return 1
  [ -n "$definitions" ] || return 0
  declare -F output_contract_validate >/dev/null || { printf 'orchid: graph requires output_contract_validate prerequisite for output contracts\n' >&2; return 1; }
  while IFS= read -r row; do
    id="$(printf '%s\n' "$row" | jq -r .id)" || return 1
    definition="$(printf '%s\n' "$row" | jq -c .definition)" || return 1
    if ! diagnostic="$(output_contract_validate "$definition")"; then
      printf 'orchid: graph output contract for %s refused: %s\n' "$id" "$diagnostic" >&2
      return 1
    fi
  done <<< "$definitions"
}
graph_terms() { _graph_jq 'require_node($id) | .terms' "$1" -c --arg id "$2"; }
graph_inputs() {
  _graph_jq '
    . as $snapshot | require_node($id) as $node
    | reduce input_ids($node)[] as $input ({};
      ($snapshot|require_node($input)) as $source
      | .[$input]={contract_revision:$source.contract_revision,execution_generation:$source.execution_generation,
          candidate_sha:$source.candidate_sha,contract_terms:$source.terms}
        + (if $input == $node.verifies then {base_sha:$source.base_sha,attempt:$source.attempt} else {} end))
  ' "$1" -c --arg id "$2"
}
# graph_affected <snapshot> <id>... OR <snapshot> <JSON-array-file>.
graph_affected() {
  local snapshot="$1" roots; shift
  [ "$#" -gt 0 ] || { printf 'orchid: graph_affected requires roots\n' >&2; return 1; }
  if [ "$#" -eq 1 ] && { case "$1" in *[!A-Za-z0-9_-]*) true ;; *) false ;; esac; }; then
    roots="$(jq -c 'if type == "array" and all(.[];type == "string") then . else error("roots must be an ID array") end' "$1")" || return 1
  else roots="$(printf '%s\n' "$@" | jq -Rsc 'split("\n")|map(select(length>0))')" || return 1; fi
  _graph_jq '
    . as $snapshot | ensure(all($roots[]; . as $id | $snapshot.nodes|has($id)); "unknown affected root")
    | (reduce .nodes[] as $node ({}; reduce input_ids($node)[] as $input (.; .[$input]=((.[$input] // [])+[$node.id])))) as $adjacency
    | closure($roots;$adjacency)[]
  ' "$snapshot" -r --argjson roots "$roots"
}
graph_required() {
  _graph_jq '
    . as $snapshot | require_node($id) as $node
    | (reduce .nodes[] as $entry ({}; .[$entry.id]=$entry.required_verifiers)) as $adjacency
    | closure($node.required_verifiers;$adjacency)[]
  ' "$1" -r --arg id "$2"
}
graph_target_binding() { _graph_jq 'target_binding(.;$id)' "$1" -c --arg id "$2"; }
