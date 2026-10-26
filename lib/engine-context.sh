#!/usr/bin/env bash
# Native adapters keep their reply format while receiving the same mandatory
# graph instructions as custom adapters. Legacy packs add no prompt text.
orchid_engine_context_prompt() (
  local pack="$1" prompt="$2" physical
  if [ -z "$pack" ] || { [ ! -e "$pack/delivery-context.json" ] && [ ! -L "$pack/delivery-context.json" ]; }; then
    printf '%s' "$prompt"
    return 0
  fi
  physical="$(orchid_physical_dir "$pack")" || return 1
  _orchid_agent_context_input_owned "$pack" "$physical" delivery-context.json file || return 1
  source "$ORCHID_ROOT/lib/json.sh"
  orchid_json_file_valid "$pack/delivery-context.json" || {
    echo 'orchid: malformed engine delivery context' >&2; return 1;
  }
  jq -e 'type == "object" and .graph_contract == 1' "$pack/delivery-context.json" >/dev/null || return 1
  printf '%s\n\n' "$prompt"
  printf '%s\n' 'Kernel-bound delivery context for this execution:'
  cat "$pack/delivery-context.json" || return 1
  printf '\n%s\n' 'Keep the adapter reply format. Satisfy the output contract for this operation and commit required artifacts when implementing. Address each structured repair finding; when reviewing, check those findings against this exact candidate. Do not edit Orchid state.'
)
