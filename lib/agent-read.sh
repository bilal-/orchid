#!/usr/bin/env bash
# Presentation adapters for successful raw reads. Durable parsers and job
# liveness remain owned by their existing libraries/verbs; this file never
# enforces a timeout, acknowledges evidence, or writes run state.
# Public functions below are sourced by the dispatcher and context runner.

source "$ORCHID_ROOT/lib/frontmatter.sh"
source "$ORCHID_ROOT/lib/manifest.sh"
source "$ORCHID_ROOT/lib/roles.sh"
source "$ORCHID_ROOT/lib/resolver.sh"
source "$ORCHID_ROOT/lib/ledger.sh"
source "$ORCHID_ROOT/lib/capsuite.sh"
source "$ORCHID_ROOT/lib/capability.sh"
source "$ORCHID_ROOT/lib/review.sh"
source "$ORCHID_ROOT/lib/drive.sh"

_orchid_agent_tsv_json() {
  local input="$1" fields="$2" defaults="${3:-$2}" next="${4:-[]}"
  jq -Rs --argjson fields "$fields" --argjson defaults "$defaults" \
    --argjson next "$next" '
    split("\n") | map(select(length > 0) | split("\t")) |
    map(. as $row | reduce range(0; $fields|length) as $i
      ({}; .[$fields[$i]] = ($row[$i] // ""))) |
    map(with_entries(if (.key == "pid" or .key == "attempt" or .key == "slot")
      and (.value|test("^[0-9]+$")) then .value |= tonumber else . end)) |
    {items:.,count:length,total:length,fields:$fields,
     default_fields:$defaults,next:$next}' "$input"
}

_orchid_agent_text_json() {
  local input="$1" next="${2:-[]}"
  jq -Rs --argjson next "$next" \
    '{text:.,bytes:utf8bytelength,empty:(length == 0),next:$next}' "$input"
}

_orchid_agent_jobs_json() {
  local input="$1"
  _orchid_agent_tsv_json "$input" \
    '["id","task","role","operation","attempt","engine","pid","state","age","elapsed","budget","launcher","log"]' \
    '["id","task","role","state"]' \
    '["orchid jobs ls --all","orchid task show <id>"]'
}

# orchid_agent_read_json <verb> <selected-path> <raw-stdout-file> [semantic args]
# Returns JSON only for recognized successful reads; return 1 asks the caller
# to use its generic success presentation. Errors belong to the caller that
# captured the original domain exit code, never to a second execution here.
orchid_agent_read_json() {
  local verb="$1" selected="$2" input="$3"; shift 3
  local repo="${ORCHID_REPO:-$PWD}" id key title status
  case "$verb:$selected" in
    task:list)
      _orchid_agent_tsv_json "$input" '["id","status","title"]' \
        '["id","status","title"]' \
        '["orchid task show <id>","orchid task create <id> \"<title>\""]' ;;
    task:show)
      id="${1:-}"
      title="$(fm_get "$input" title)"; status="$(fm_get "$input" status)"
      jq -Rs --arg id "$id" --arg title "$title" --arg status "$status" \
        '{id:$id,title:$title,status:$status,text:.,bytes:utf8bytelength,
          next:[]}' "$input" ;;
    task:get)
      id="${1:-}"; key="${2:-}"
      jq -Rs --arg task "$id" --arg key "$key" \
        '{task:$task,key:$key,value:(if endswith("\n") then .[0:-1] else . end),next:[]}' "$input" ;;
    jobs:ls)
      # The raw TSV form is the single stable producer for thirteen fields.
      # The dispatcher obtains it instead of parsing a padded display table.
      _orchid_agent_jobs_json "$input" ;;
    jobs:check)
      _orchid_agent_tsv_json "$input" '["task","state"]' \
        '["task","state"]' '["orchid jobs ls"]' ;;
    jobs:review-plan)
      _orchid_agent_tsv_json "$input" \
        '["slot","engine","level","diversity","qualification"]' \
        '["slot","engine","level","qualification"]' \
        '["orchid task show <id>"]' ;;
    config:list)
      _orchid_agent_tsv_json "$input" '["key","value","source"]' \
        '["key","value","source"]' '["orchid config list --full"]' ;;
    lessons:list)
      _orchid_agent_tsv_json "$input" '["id","state","scope","statement"]' \
        '["id","state","scope","statement"]' \
        '["orchid lessons update <id> --confirm","orchid lessons add --scope repo --invalidate-when \"<condition>\" \"<statement>\""]' ;;
    plugins:list)
      _orchid_agent_tsv_json "$input" '["id","kind","version","origin","trust"]' \
        '["id","kind","version","trust"]' \
        '["orchid plugins validate <id>","orchid plugins audit <name>"]' ;;
    plugins:audit)
      jq -Rs '
        split("=== ")[1:] | map(split("\n") | .[0] as $header |
          reduce .[1:][] as $line ({id:($header|sub(" ===$";""))};
            if ($line|test("^[a-z_]+: ")) then
              ($line|capture("^(?<key>[a-z_]+): (?<value>.*)$")) as $v |
              if $v.key == "capsuite" then
                .capsuite = ((.capsuite // "") +
                  (if (.capsuite // "") == "" then "" else "; " end) + $v.value)
              else .[$v.key] = $v.value end
            else . end)) |
        {items:.,count:length,total:length,
         fields:["id","kind","version","origin","trust","validate","provenance","digest","capsuite","lockfile"],
         default_fields:["id","kind","version","validate"],
         next:["orchid plugins validate <id>","orchid plugins test <engine-id> <role>"]}' "$input" ;;
    plugins:validate)
      jq -n --arg target "${1:---all}" \
        '{target:$target,valid:true,next:[]}' ;;
    journal:tail|journal:show)
      # Journal output is a stream, not a new parser for its Markdown store.
      # Preserve the text exactly; the shared formatter owns previews/full.
      _orchid_agent_text_json "$input" \
        '["orchid journal show --task <id>","orchid journal tail -n <count> --full"]' ;;
    trust:show)
      jq -Rs '
        split("\n") | reduce .[] as $line ({};
          if ($line|contains(": ")) then
            ($line|capture("^(?<key>[^:]+): (?<value>.*)$")) as $v |
            .[($v.key|gsub(" ";"_"))] = $v.value
          else . end) |
        . + {next:["orchid trust unattended <repo> --reason \"<reason>\"","orchid trust revoke <repo>"]}' "$input" ;;
    status:)
      case " $* " in
        *' --html '*) _orchid_agent_text_json "$input" ;;
        *) orchid_agent_context_json "$repo" ;;
      esac ;;
    *) return 1 ;;
  esac
}

# orchid_agent_context_json <repo> -- directory-scoped, observational context.
# Missing runtime is inspected as missing; do not invoke orchid_runtime (which
# creates it). With an existing runtime, jobs ls reuses the kernel's read-only
# classification and never runs jobs check, GC, or lease operations.
orchid_agent_context_json() {
  local repo="$1" state rt f id status title why task_rows="" tasks jobs
  local run_id="" run_status=uninitialized epoch="" boundary boundary_json
  local boundary_kind boundary_task boundary_status="" surface operator_owned=false
  state="$(orchid_state "$repo")"; rt="$state/runtime"
  if [ -f "$state/roadmap.md" ]; then
    run_id="$(fm_get "$state/roadmap.md" run_id)"
    run_status="$(fm_get "$state/roadmap.md" run_status)"
    [ -n "$run_status" ] || run_status=damaged
  fi
  [ ! -f "$rt/epoch" ] || epoch="$(cat "$rt/epoch")"
  for f in "$state/tasks"/*.md; do
    [ -e "$f" ] || continue
    if why="$(fm_check "$f" id)"; then
      id="$(fm_get "$f" id)"; status="$(fm_get "$f" status)"
      title="$(fm_get "$f" title)"
    else
      id="${f##*/}"; id="${id%.md}"; status=DAMAGED
      title="DAMAGED task file: $why"
    fi
    task_rows="$task_rows$(jq -cn --arg id "$id" --arg status "$status" \
      --arg title "$title" '{id:$id,status:$status,title:$title}')"$'\n'
  done
  tasks="$(printf '%s' "$task_rows" | jq -s '
    . as $items | {items:$items,count:length,total:length,
      by_status:(reduce $items[] as $t ({}; .[$t.status] = ((.[$t.status] // 0)+1))),
      fields:["id","status","title"],default_fields:["id","status","title"],
      next:["orchid task show <id>","orchid task create <id> \"<title>\""]}')" || return 1
  if [ -d "$rt" ]; then
    # Feed through stdin rather than an argv JSON value: a large run must not
    # fail at the operating system's argument-size limit.
    jobs="$(ORCHID_REPO="$repo" ORCHID_OUTPUT=raw \
      "$ORCHID_ROOT/bin/orchid" jobs ls --tsv --strict | \
      _orchid_agent_jobs_json - | jq '
      . + {by_state:(reduce .items[] as $j
        ({}; .[$j.state] = ((.[$j.state] // 0)+1)))}')" || return 1
  else
    jobs='{"items":[],"count":0,"total":0,"by_state":{},"fields":["id","task","role","state"],"default_fields":["id","task","role","state"],"next":["orchid jobs ls --all"]}'
  fi
  boundary="$rt/boundary.json"
  if [ -f "$boundary" ]; then
    if jq -e -s 'length == 1 and (.[0]|type == "object")' "$boundary" >/dev/null; then
      boundary_json="$(cat "$boundary")"
      boundary_kind="$(jq -r '.kind // ""' "$boundary")"
      boundary_task="$(jq -r '.task // ""' "$boundary")"
      # Reuse the already-read task snapshot. A damaged boundary task string
    # must not become another filesystem path during this read-only view.
    if [ -n "$boundary_task" ]; then
      boundary_status="$(printf '%s\n' "$tasks" | jq -r --arg id "$boundary_task" \
        '.items[] | select(.id == $id) | .status')"
    fi
    surface="$(drive_orchestrator_surface "$repo")"
      if ! drive_boundary_wakes_orchestrator "$boundary_kind" "$boundary_status" "$surface"; then
        operator_owned=true
      fi
    else
      boundary_json='{"malformed":true,"reason":"The standing boundary is unreadable; inspect orchid doctor."}'
      operator_owned=true
    fi
  else
    boundary_json=null
  fi
  printf '%s\n%s\n%s\n' "$tasks" "$jobs" "$boundary_json" | \
    jq -s --arg repo "$repo" --arg run_id "$run_id" \
      --arg run_status "$run_status" --arg epoch "$epoch" \
      --argjson operator_owned "$operator_owned" '
      {repo:$repo,initialized:($run_status != "uninitialized"),run:{id:$run_id,status:$run_status},
       epoch:(if ($epoch|test("^[0-9]+$")) then ($epoch|tonumber) else null end),
       boundary:.[2],operator_owned:$operator_owned,tasks:.[0],jobs:.[1],
       next:(if .[2] != null then ["orchid run boundary show","orchid protocol boundaries --full"]
         elif $run_status == "uninitialized" then ["orchid start --help","orchid protocol planning --full"]
         elif $run_status == "complete" then ["orchid protocol completion --full","orchid run new --help"]
         else ((.[0].items | map(select(.status!="done"))[0:3] | map("orchid task show " + (.id|@sh))) + ["orchid jobs ls --all"]) end)}'
}
