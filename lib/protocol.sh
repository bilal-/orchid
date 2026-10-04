#!/usr/bin/env bash
# One canonical section selector; skills and CLI do not duplicate procedures.
orchid_protocol_heading() {
  case "$1" in
    preamble) printf '%s\n' '## Preamble' ;;
    boundaries) printf '%s\n' '## Judgment boundaries (`orchid drive`, `orchid run boundary`, `orchid task arbitrate`)' ;;
    planning) printf '%s\n' '## PLANNING (pre-run, before THE TICK ever runs)' ;;
    tick) printf '%s\n' '## THE TICK' ;;
    resume) printf '%s\n' '## RESUME' ;;
    headless) printf '%s\n' '## HEADLESS OPERATION' ;;
    completion) printf '%s\n' '## COMPLETION' ;;
    discrepancies) printf '%s\n' '## Known documentation discrepancies surfaced while writing this file' ;;
    *) return 2 ;;
  esac
}
orchid_protocol_section() {
  local heading
  heading="$(orchid_protocol_heading "$1")" || return 2
  ORCHID_PROTOCOL_HEADING="$heading" awk '
    /^```/ { fence = !fence }
    !fence && /^## / {
      if (active) exit
      if ($0 == ENVIRON["ORCHID_PROTOCOL_HEADING"]) active = 1
    }
    active { print }
  ' "$ORCHID_ROOT/PROTOCOL.md"
}
