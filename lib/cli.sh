#!/usr/bin/env bash
# Shared command metadata, admission and focused help. State/evidence checks
# remain in the verb; this layer never acquires a lease or changes run state.
orchid_cli_prepare() {
  local verb="$1" format="$2"; shift 2
  ORCHID_CLI_ERROR=""
  local metadata="$ORCHID_ROOT/lib/cli/$verb.json" argv parsed
  [ -f "$metadata" ] || { ORCHID_CLI_ERROR="Unknown command $verb; run orchid --help for available commands"; printf "orchid: command metadata missing for '%s'\n" "$verb" >&2; return 2; }
  argv="$(jq -cn --args '$ARGS.positional' -- "$@")" || return 2
  parsed="$(jq -c --arg verb "$verb" --arg format "$format" \
    --argjson raw "$([ "$format" = raw ] && printf true || printf false)" \
    --argjson argv "$argv" -f "$ORCHID_ROOT/lib/cli-parse.jq" "$metadata")" || return 2
  if [ "$(jq -r 'has("error")' <<< "$parsed")" = true ]; then
    ORCHID_CLI_ERROR="$(jq -r '.error' <<< "$parsed")"
    printf 'orchid: %s\n' "$ORCHID_CLI_ERROR" >&2
    return 2
  fi
  ORCHID_CLI_PARSED="$parsed"
  ORCHID_CLI_ARGS=()
  ORCHID_CLI_WIRE_ARGS=()
  while IFS= read -r -d '' item; do
    ORCHID_CLI_ARGS[${#ORCHID_CLI_ARGS[@]}]="$item"
  done < <(jq -jr '.argv[] | . + "\u0000"' <<< "$parsed")
  while IFS= read -r -d '' item; do
    ORCHID_CLI_WIRE_ARGS[${#ORCHID_CLI_WIRE_ARGS[@]}]="$item"
  done < <(jq -jr '.wire_argv[] | . + "\u0000"' <<< "$parsed")
}
orchid_cli_help() {
  local verb="$1" command="$2"
  printf '%s\n' "$(jq -r '.usage' <<< "$command")"
  jq -r '.description // empty' "$ORCHID_ROOT/lib/cli/$verb.json"
  jq -r '.commands[]?.usage' <<< "$command"
  jq -r '.notes[]?' <<< "$command"
  printf '\nOptions:\n'
  jq -r '(.options // {}) | to_entries[] | "  \(.key)\(if .value == 1 then " <value>" else "" end)"' <<< "$command"
  printf '  --help, -h\n  --json         JSON instead of TOON\n  --full         Complete detail text and all rows\n  --fields <a,b> Select declared output fields\n  --limit <n>    Maximum list rows (default %s)\n  --request-id <id> Replay the same recorded intent safely\n\nExamples:\n' "$(jq -r '.default_limit // 100' <<< "$command")"
  jq -r '.examples[]? | "  " + .' <<< "$command"
}
orchid_cli_validate_impl() {
  local verb="$1"; shift
  orchid_cli_prepare "$verb" raw "$@" || return 2
  if [ "$(jq -r '.help' <<< "$ORCHID_CLI_PARSED")" = true ]; then
    orchid_cli_help "$verb" "$(jq -c '.command' <<< "$ORCHID_CLI_PARSED")"
    exit 0
  fi
}

orchid_cli_usage_error() {
  local verb="$1" message="$2"
  printf 'orchid: %s\n' "$message" >&2
  printf 'usage: run orchid %s --help for the accepted form\n' "$verb" >&2
  return 2
}
