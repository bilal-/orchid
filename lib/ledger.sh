#!/usr/bin/env bash

# Engine availability ledger: <repo>/.orchid/runtime/engines.json, a map of
# engine name -> {status, rate_limited_until, consecutive_failures,
# last_status, updated_at}. Runtime (machine-local, gitignored, per
# docs/specs/kernel.md's runtime/ tree) -- never a durable file, so a plain
# atomic_write read-modify-write is enough; no epoch fence needed. Missing
# file means every engine is available (nothing has ever gone wrong).
# Sourced after common.sh (uses config_get/atomic_write/orchid_runtime).

_ledger_file() { echo "$(orchid_runtime "$1")/engines.json"; }

# epoch -> ISO-8601 UTC, portable across GNU (`date -d @epoch`) and BSD/macOS
# (`date -r epoch`) date -- the reverse of orchid-jobs' iso_to_epoch, kept in
# the same try-GNU-then-BSD shape so the two stay symmetric.
_ledger_epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return
  echo ""
}

# ledger_mark <repo> <engine> <envelope-status> [retry_after_s]
ledger_mark() {
  local repo="$1" engine="$2" status="$3" retry_after="${4:-}"
  local f now cur out
  f="$(_ledger_file "$repo")"
  now="$(date +%s)"
  cur="$(cat "$f" 2>/dev/null || echo '{}')"
  case "$status" in
    ok)
      out="$(echo "$cur" | jq --arg e "$engine" --argjson now "$now" '
        .[$e] = {status:"ok", rate_limited_until:0, consecutive_failures:0,
                 last_status:"ok", updated_at:$now}')"
      ;;
    rate_limited)
      local backoff until
      if echo "$retry_after" | grep -qE '^[1-9][0-9]*$'; then
        backoff="$retry_after"
      else
        backoff="$(config_get "$repo" rate_limit_backoff_s 3600)"
      fi
      until=$(( now + backoff ))
      out="$(echo "$cur" | jq --arg e "$engine" --argjson now "$now" --argjson until "$until" '
        .[$e] = ((.[$e] // {consecutive_failures:0}) + {
          status:"rate_limited", rate_limited_until:$until,
          last_status:"rate_limited", updated_at:$now})')"
      ;;
    failed|timeout|auth|malformed)
      local threshold
      threshold="$(config_get "$repo" engine_fail_threshold 3)"
      out="$(echo "$cur" | jq --arg e "$engine" --arg st "$status" --argjson now "$now" --argjson thr "$threshold" '
        ((.[$e].consecutive_failures // 0) + 1) as $fails
        | (.[$e].status // "ok") as $oldstatus
        | .[$e] = ((.[$e] // {rate_limited_until:0}) + {
            status: (if $fails >= $thr then "failing" else $oldstatus end),
            consecutive_failures:$fails, last_status:$st, updated_at:$now})')"
      ;;
    *) out="$cur" ;;  # envelope_validate restricts status to the 6 values above
  esac
  echo "$out" | atomic_write "$f"
}

# ledger_available <repo> <engine> -- exit 0 iff no record for this engine,
# or its rate-limit window has passed (even if never followed by an `ok`
# mark -- the window reopening is what matters) AND it hasn't hit the
# consecutive-failure threshold.
ledger_available() {
  local repo="$1" engine="$2" f now threshold
  f="$(_ledger_file "$repo")"
  [ -f "$f" ] || return 0
  now="$(date +%s)"
  threshold="$(config_get "$repo" engine_fail_threshold 3)"
  jq -e --arg e "$engine" --argjson now "$now" --argjson thr "$threshold" '
    (.[$e] // {rate_limited_until:0, consecutive_failures:0}) as $r
    | (($r.rate_limited_until // 0) <= $now) and (($r.consecutive_failures // 0) < $thr)
  ' "$f" >/dev/null
}

# ledger_show <repo> -- one line per engine: <engine>\t<status>\t<detail>
# (detail = "until <iso>" for rate_limited, "failures <n>" whenever
# consecutive_failures>0 -- whether status has already flipped to "failing"
# at threshold or is still sub-threshold "ok", so an operator sees an engine
# accumulating failures before it actually goes unavailable -- "-"
# otherwise). Prints nothing when the ledger is missing or empty; callers
# (e.g. `orchid status`) supply the "(no engine events yet)" placeholder.
ledger_show() {
  local repo="$1" f
  f="$(_ledger_file "$repo")"
  [ -f "$f" ] || return 0
  jq -r 'to_entries[] |
    [.key, (.value.status // "ok"), (.value.rate_limited_until // 0), (.value.consecutive_failures // 0)]
    | @tsv' "$f" |
  while IFS=$'\t' read -r engine status until fails; do
    case "$status" in
      rate_limited) printf '%s\t%s\tuntil %s\n' "$engine" "$status" "$(_ledger_epoch_to_iso "$until")" ;;
      failing)      printf '%s\t%s\tfailures %s\n' "$engine" "$status" "$fails" ;;
      *)
        if [ "${fails:-0}" -gt 0 ] 2>/dev/null; then
          printf '%s\t%s\tfailures %s\n' "$engine" "$status" "$fails"
        else
          printf '%s\t%s\t-\n' "$engine" "$status"
        fi
        ;;
    esac
  done
}
