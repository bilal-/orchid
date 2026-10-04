#!/usr/bin/env bash
source "$ORCHID_ROOT/lib/cli.sh"
orchid_agent_emit() {
  local format="$1"
  if [ "$format" = json ]; then jq .; else jq -r -f "$ORCHID_ROOT/lib/agent-output.jq"; fi
}
orchid_agent_error() {
  local code="$1" message="$2" format="$3" command="$4"
  jq -n --arg error "$message" --arg command "$command" --argjson kernel_exit "$code" \
    '{error:$error,kernel_exit:$kernel_exit,help:("Run " + $command + " --help for the accepted form")}' | orchid_agent_emit "$format"
}
orchid_agent_help() {
  local verb="$1" command="$2" format="$3" view="${4:-}"
  [ -n "$view" ] || view='{}'
  jq -n --argjson command "$command" --slurpfile meta "$ORCHID_ROOT/lib/cli/$verb.json" \
    '{usage:$command.usage,commands:($command.commands // []),description:$meta[0].description,
      options: (($command.options // {}) | to_entries | map({flag:.key,value:(.value==1)})),
      output:["--json","--full","--fields <a,b>","--limit <n>","--request-id <id>"],
      examples:$command.examples,notes:($command.notes // [])}' | jq --argjson command "$command" --argjson view "$view" -f "$ORCHID_ROOT/lib/agent-present.jq" | orchid_agent_emit "$format"
}
orchid_agent_catalog() {
  local format="$1"
  jq -n --arg bin "$ORCHID_ROOT/bin/orchid" \
    '[inputs | {command:(input_filename|split("/")|last|rtrimstr(".json")),description:.description}] as $items |
      {bin:$bin,description:"Coordinate coding agents with a deterministic Bash, Git and jq kernel.",
      usage:"usage: orchid [--raw|--json] <command> [args]",items:$items,count:($items|length),
      next:["orchid context","orchid <command> --help"]}' "$ORCHID_ROOT"/lib/cli/*.json | orchid_agent_emit "$format"
}
orchid_agent_result_json() {
  local verb="$1" path="$2" raw="$3" command="$4"; shift 4
  if [ -f "$ORCHID_ROOT/lib/agent-read.sh" ]; then
    local __orchid_entry_defer_restore=1
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/agent-read.sh"
    if orchid_agent_read_json "$verb" "$path" "$raw" "$@"; then return 0; fi
  fi
  if [ "$verb" = run ] && { [ "$path" = start ] || [ "$path" = resume ]; }; then
    jq -n --rawfile text "$raw" '{epoch:($text|capture("epoch: (?<n>[0-9]+)").n|tonumber),
      next:["orchid context","orchid protocol resume --full"]}'
    return
  fi
  case "$(jq -r '.kind' <<< "$command")" in
    json) jq -s 'if length==1 then .[0] else {items:.,count:length,total:length} end' "$raw" ;;
    tsv)
      jq -n --rawfile text "$raw" --argjson fields "$(jq -c '.fields' <<< "$command")" \
        '{items:($text|split("\n")|map(select(length>0)|split("\t")|. as $row|reduce range(0;($fields|length)) as $i ({};.[$fields[$i]]=$row[$i]))),fields:$fields} | .count=(.items|length) | .total=.count' ;;
    scalar) jq -n --rawfile value "$raw" '{value:($value|rtrimstr("\n"))}' ;;
    *) jq -n --rawfile text "$raw" '{text:$text} | if $text=="" then .completed=true else . end' ;;
  esac
}
orchid_agent_dispatch() {
  local verb="$1" format="$2"; shift 2
  local command view path exe output errors rc=0 data scratch request_id request_rc=0
  exe="$ORCHID_ROOT/libexec/orchid-$verb"
  if [ ! -x "$exe" ]; then
    if [ -e "$exe" ]; then
      orchid_agent_error 2 "Command $verb is not executable: $exe exists but its mode bit is not set; set chmod +x and record the Git executable mode" "$format" "orchid $verb"
    else
      orchid_agent_error 2 "Unknown command $verb; run orchid --help" "$format" "orchid"
    fi
    return 2
  fi
  if ! orchid_cli_prepare "$verb" "$format" "$@"; then
    orchid_agent_error 2 "${ORCHID_CLI_ERROR:-Invalid arguments; see the diagnostic on stderr}" "$format" "orchid $verb"
    return 2
  fi
  command="$(jq -c '.command' <<< "$ORCHID_CLI_PARSED")"
  view="$(jq -c --arg verb "$verb" '.view + {command:("orchid " + $verb + " " + (.argv|map(@sh)|join(" ")))}' <<< "$ORCHID_CLI_PARSED")"
  format="$(jq -r '.format' <<< "$view")"
  if [ "$(jq -r '.help' <<< "$ORCHID_CLI_PARSED")" = true ]; then
    orchid_agent_help "$verb" "$command" "$format" "$view"; return 0
  fi
  local -a args result_args=()
  while IFS= read -r -d '' item; do args[${#args[@]}]="$item"; done \
    < <(jq -jr '.wire_argv[] | . + "\u0000"' <<< "$ORCHID_CLI_PARSED")
  result_args=()
  while IFS= read -r -d '' item; do result_args[${#result_args[@]}]="$item"; done < <(jq -jr '.argv[(.command.path|length):][] | . + "\u0000"' <<< "$ORCHID_CLI_PARSED")
  path="$(jq -r '.command.path|join(" ")' <<< "$ORCHID_CLI_PARSED")"
  exe="$ORCHID_ROOT/libexec/orchid-$verb"
  if [ ! -x "$exe" ]; then
    orchid_agent_error 2 "Command $verb is missing or not executable" "$format" "orchid $verb"
    return 2
  fi
  request_id="$(jq -r '.view.request_id // empty' <<< "$ORCHID_CLI_PARSED")"
  if [ -n "$request_id" ]; then
    source "$ORCHID_ROOT/lib/requests.sh"
    orchid_request_begin "$request_id" "$verb" "$ORCHID_CLI_PARSED" || request_rc=$?
    if [ "$request_rc" -eq 3 ]; then
      rc="$(jq -r '.exit' "$ORCHID_REQUEST_DIR/result.json")"
      jq --arg id "$request_id" '.data + {request:{id:$id,replayed:true,result_is_historical:true}}' \
        "$ORCHID_REQUEST_DIR/result.json" | \
        jq --argjson command "$command" --argjson view "$view" -f "$ORCHID_ROOT/lib/agent-present.jq" | orchid_agent_emit "$format"
      return "$rc"
    elif [ "$request_rc" -ne 0 ]; then
      orchid_agent_error "$request_rc" 'Request replay refused; inspect state and the diagnostic before using a new ID' "$format" "orchid $verb $path"
      return "$request_rc"
    fi
  fi
  # Status's machine-compatible default performs job enforcement. Agent reads
  # use its existing explicitly read-only jobs view, including in fresh sessions.
  if [ "$verb" = status ]; then
    case " ${args[*]+${args[*]}} " in *' --html '*) ;; *) args[${#args[@]}]=--jobs ;; esac
  fi
  if [ "$verb" = jobs ] && [ "$path" = ls ] && [[ " ${args[*]+${args[*]}} " != *' --warnings '* ]]; then
    case " ${args[*]+${args[*]}} " in *' --tsv '*) ;; *) args[${#args[@]}]=--tsv ;; esac
  fi
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/orchid-agent-output.XXXXXX")" || return 1
  output="$scratch/stdout"; errors="$scratch/stderr"
  # A regular file preserves diagnostics without waiting for a launched
  # descendant to close a pipe inherited from the kernel command.
  ORCHID_OUTPUT=raw /bin/bash -p "$exe" ${args[@]+"${args[@]}"} > "$output" 2> "$errors" || rc=$?
  cat "$errors" >&2
  if [ "$rc" -ne 0 ]; then
    local message
    message="$(head -n 1 "$errors")"
    [ -n "$message" ] || message="$(head -n 1 "$output")"
    [ -n "$message" ] || message="Command stopped with kernel exit $rc"
    local public_rc=1
    [ "$rc" -eq 2 ] && public_rc=2
    data="$scratch/data.json"
    orchid_agent_error "$rc" "$message" json "orchid $verb $path" > "$data"
    if [ -n "$request_id" ]; then orchid_request_finish "$data" "$public_rc" || { rm -rf "$scratch"; return 1; }; fi
    orchid_agent_emit "$format" < "$data"
    rm -rf "$scratch"
    [ "$rc" -eq 2 ] && return 2
    return 1
  fi
  if [ "$verb" = context ] && [ ! -s "$output" ]; then
    rm -rf "$scratch"; return 0
  fi
  data="$scratch/data.json"
  if [ "$verb" = jobs ] && [ "$path" = ls ] && [[ " ${args[*]+${args[*]}} " == *' --warnings '* ]]; then
    jq -n --rawfile warnings "$errors" '{completed:true,warnings:$warnings,
      bytes:($warnings|utf8bytelength),next:["orchid jobs ls"]}' > "$data"
  elif ! orchid_agent_result_json "$verb" "$path" "$output" "$command" ${result_args[@]+"${result_args[@]}"} > "$data"; then
    orchid_agent_error 1 'Operation completed but its result could not be rendered; inspect state before retrying' "$format" "orchid $verb $path"
    rm -rf "$scratch"; return 1
  fi
  if [ -n "$request_id" ]; then
    orchid_request_finish "$data" 0 || { rm -rf "$scratch"; return 1; }
    jq --arg id "$request_id" '. + {request:{id:$id,replayed:false,result_is_historical:false}}' "$data" > "$scratch/present.json"
    data="$scratch/present.json"
  fi
  jq --argjson command "$command" --argjson view "$view" -f "$ORCHID_ROOT/lib/agent-present.jq" "$data" | orchid_agent_emit "$format"
  rc=$?
  rm -rf "$scratch"
  return "$rc"
}
