#!/usr/bin/env bash

# Engine availability ledger: <repo>/.orchid/runtime/engines.json, a map of
# engine name -> {status, rate_limited_until, consecutive_failures,
# capability_refusals, last_status, updated_at}. Runtime (machine-local,
# gitignored, per docs/specs/kernel.md's runtime/ tree) -- never a durable
# file, so a plain atomic_write read-modify-write is enough; no epoch fence
# needed. Missing file means every engine is available (nothing has ever gone
# wrong). Sourced after common.sh (uses config_get/atomic_write/
# orchid_runtime).
#
# A CAPABILITY REFUSAL IS NOT A FAULT (v1-m5 T008). A non-`ok` envelope means
# one of two very different things, and until this file could tell them apart
# it counted both toward disqualification:
#
#   * the engine FAILED -- crashed, timed out, lost its auth, answered
#     something unparseable. Every one of these is evidence the engine cannot
#     be relied on, so it increments `consecutive_failures` and flips the
#     engine to `failing` at `engine_fail_threshold`.
#   * the engine REFUSED BY DESIGN -- `plugins/engines/agy/run` declining a
#     diff over `agy_max_bytes`, an adapter declining an operation it never
#     claimed to support. The engine worked perfectly: it read the request,
#     recognized it as outside its declared envelope, said so naming the
#     limit and the remedy, and wrote a valid envelope. This is evidence
#     about the REQUEST, not about the engine.
#
# Counting the second kind was measured live on r-002: agy refused three
# review packs whose diffs were ~1% over its byte cap, the ledger read that
# as three faults and marked agy `failing`, the run's reviewer pool silently
# dropped to one session-independent engine, a reviewer slot was reassigned
# out from under a review agy had ALREADY filed, and T024 was left in
# `reviewing` with no legal forward edge. A correct refusal by a
# well-behaved engine stranded a task and degraded review independence for
# every medium/high task in the run.
#
# So `ledger_mark` takes the adapter's own `failure_kind` (the envelope
# field, `capability` or `engine`; absent means `engine`) and, for a
# capability refusal, records the event WITHOUT touching the engine's health:
# `consecutive_failures` is left exactly as it was, `status` is left alone,
# `last_status` becomes `refused`, and a separate `capability_refusals`
# counter is incremented so the refusal is still VISIBLE rather than silent
# (dogfood F12).
#
# `last_status` matters as much as the counter. No kernel predicate reads it
# today (ledger_available gates on `rate_limited_until` +
# `consecutive_failures`; ledger_show reports `status` and the two counts) --
# it exists so that this file's record of the most recent event is TRUE, for
# the operator reading `runtime/engines.json` and for anything later built on
# it. Writing `failed` there for a refusal files a fault against an engine
# that did not commit one, which is the same lie the counter used to tell,
# just in a field nothing has started trusting yet.
#
# That counter is deliberately never a disqualifier. An adapter CAN claim
# `capability` on every failure and so never be marked `failing` -- but an
# adapter can equally claim `ok` on work it never did, and the trust model
# answers both the same way: envelopes are adapter self-reports, "tests
# pass" is established by `orchid verify` alone, and a plugin that lies is
# removed by the operator. Making the lie loud (`refusals 37` in `orchid
# status`) is the honest fix here; inventing a second threshold that
# re-disqualifies the well-behaved engine this task exists to protect is
# not.

_ledger_file() { echo "$(orchid_runtime "$1")/engines.json"; }

# epoch -> ISO-8601 UTC, portable across GNU (`date -d @epoch`) and BSD/macOS
# (`date -r epoch`) date -- the reverse of orchid-jobs' iso_to_epoch, kept in
# the same try-GNU-then-BSD shape so the two stay symmetric.
_ledger_epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return
  echo ""
}

# ledger_mark <repo> <engine> <envelope-status> [retry_after_s] [failure_kind]
#
# `failure_kind` is the envelope's own `.failure_kind` field, passed straight
# through by the caller (empty when absent, which is the overwhelmingly
# common case). It is honored ONLY inside the fault bucket below: a
# `capability` claim on an `ok` or `rate_limited` envelope is meaningless
# (there is no fault to reclassify) and is ignored rather than obeyed, so a
# confused adapter cannot use it to suppress a rate-limit window.
ledger_mark() {
  local repo="$1" engine="$2" status="$3" retry_after="${4:-}" kind="${5:-}"
  local f now cur out
  f="$(_ledger_file "$repo")"
  now="$(date +%s)"
  cur="$(cat "$f" 2>/dev/null || echo '{}')"
  case "$status" in
    ok)
      # `(.[$e] // {}) +` rather than a bare assignment: every HEALTH field is
      # still overwritten (that is what an `ok` mark means), but the
      # cumulative `capability_refusals` count survives it. A refusal is not
      # a fault, so a later success is not a reason to forget the engine kept
      # declining work -- an operator reading `orchid status` should still see
      # "this reviewer refuses most of what it is handed" after it reviews one
      # small diff successfully.
      out="$(echo "$cur" | jq --arg e "$engine" --argjson now "$now" '
        .[$e] = ((.[$e] // {}) + {status:"ok", rate_limited_until:0,
                 consecutive_failures:0, last_status:"ok", updated_at:$now})')"
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
      if [ "$kind" = capability ]; then
        # Capability refusal (see the header): record it, count it, change
        # NOTHING about the engine's health. `status`, `rate_limited_until`
        # and `consecutive_failures` are carried through untouched -- an
        # engine mid-way through a genuine failure streak neither advances nor
        # clears it by declining one request out of contract. The defaults
        # supplied for a first-ever event are a complete healthy record, so
        # ledger_show/ledger_available never have to infer a missing field.
        out="$(echo "$cur" | jq --arg e "$engine" --argjson now "$now" '
          ((.[$e].capability_refusals // 0) + 1) as $refusals
          | .[$e] = ((.[$e] // {status:"ok", rate_limited_until:0, consecutive_failures:0}) + {
              last_status:"refused", capability_refusals:$refusals, updated_at:$now})')"
      else
        local threshold
        threshold="$(config_get "$repo" engine_fail_threshold 3)"
        out="$(echo "$cur" | jq --arg e "$engine" --arg st "$status" --argjson now "$now" --argjson thr "$threshold" '
          ((.[$e].consecutive_failures // 0) + 1) as $fails
          | (.[$e].status // "ok") as $oldstatus
          | .[$e] = ((.[$e] // {rate_limited_until:0}) + {
              status: (if $fails >= $thr then "failing" else $oldstatus end),
              consecutive_failures:$fails, last_status:$st, updated_at:$now})')"
      fi
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

# _ledger_effective <repo> <until> <fails> -- the status a record ACTUALLY
# has right now, derived from the same two numbers `ledger_available` decides
# on, in the same order: `failing` (at or past the failure threshold),
# `rate_limited` (a window that has not closed yet), else `ok`.
#
# The stored `status` string is a record of the last MARK, not of the present:
# `ledger_mark` writes "rate_limited" once and nothing ever rewrites it when
# the window passes, because nothing has to -- availability is computed from
# `rate_limited_until <= now`. Reporting that stale string is how r-002's
# operator spent ten minutes chasing an engine whose window had expired six
# days earlier, while the actual cause of the stall was elsewhere entirely.
# Every reporting path derives the status here instead, so what an operator
# reads and what dispatch does can never disagree.
#
# `rl_until`, not `until`: the reserved word is only recognized as one in
# command position, so `until=0` would in fact parse as a plain assignment --
# but a loop keyword standing where a reader expects a variable is a trap for
# the next person editing this, and costs nothing to avoid.
_ledger_effective() {
  local repo="$1" rl_until="${2:-0}" fails="${3:-0}" now threshold
  now="$(date +%s)"
  threshold="$(config_get "$repo" engine_fail_threshold 3)"
  case "$rl_until" in ''|*[!0-9]*) rl_until=0 ;; esac
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  # A garbled `engine_fail_threshold` falls back to the same default the
  # config lookup itself declares, rather than letting `[` fail with a
  # syntax error and report `ok` on the way out.
  case "$threshold" in ''|*[!0-9]*) threshold=3 ;; esac
  if [ "$fails" -ge "$threshold" ]; then echo failing
  elif [ "$rl_until" -gt "$now" ]; then echo rate_limited
  else echo ok
  fi
}

# ledger_effective_status <repo> <engine> -- that same derivation for one
# engine, for callers that have a name and need to know WHY it is unavailable:
# a `rate_limited` engine's window reopens on its own (wait), while a
# `failing` one stays unavailable until an `ok` mark it can only earn by being
# dispatched (a decision, not a wait). An engine with no record at all is
# `ok`, exactly as ledger_available treats it.
ledger_effective_status() {
  local repo="$1" engine="$2" f rec
  f="$(_ledger_file "$repo")"
  [ -f "$f" ] || { echo ok; return 0; }
  rec="$(jq -r --arg e "$engine" '
    (.[$e] // {}) | [((.rate_limited_until // 0)|tostring), ((.consecutive_failures // 0)|tostring)] | @tsv' \
    "$f" 2>/dev/null || true)"
  [ -n "$rec" ] || { echo ok; return 0; }
  _ledger_effective "$repo" "$(printf '%s' "$rec" | cut -f1)" "$(printf '%s' "$rec" | cut -f2)"
}

# ledger_show <repo> -- one line per engine: <engine>\t<status>\t<detail>,
# where <status> is the EFFECTIVE status (_ledger_effective above), never the
# last mark's stale string. detail = "until <iso>" while a rate-limit window
# is open, "rate limit expired <iso>" once it has closed (the mark is still
# the most recent thing that happened to this engine, and saying so is more
# use than a bare "-"), "failures <n>" whenever consecutive_failures>0 --
# whether the engine has already reached the threshold or is still
# accumulating below it, so an operator sees it coming -- "-" otherwise.
# Prints nothing when the ledger is missing or empty; callers (e.g. `orchid
# status`) supply the "(no engine events yet)" placeholder.
# ledger_show <repo> -- one line per engine: <engine>\t<status>\t<detail>
# (detail = "until <iso>" for rate_limited; otherwise "failures <n>" whenever
# consecutive_failures>0 -- whether status has already flipped to "failing"
# at threshold or is still sub-threshold "ok", so an operator sees an engine
# accumulating failures before it actually goes unavailable -- and/or
# "refusals <n>" whenever capability_refusals>0, appended after the failure
# count when both are nonzero; "-" when there is nothing to report). Prints
# nothing when the ledger is missing or empty; callers (e.g. `orchid status`)
# supply the "(no engine events yet)" placeholder.
#
# The refusal count is what makes a capability refusal visible instead of
# silent (dogfood F12): it never affects availability, so `orchid status` is
# the only place an operator can see that an engine keeps declining the work
# it is handed -- and see it WITHOUT the word "failures" next to a
# well-behaved engine's name.
ledger_show() {
  local repo="$1" f detail eff
  f="$(_ledger_file "$repo")"
  [ -f "$f" ] || return 0
  jq -r 'to_entries[] |
    [.key, (.value.status // "ok"), (.value.rate_limited_until // 0),
     (.value.consecutive_failures // 0), (.value.capability_refusals // 0)]
    | @tsv' "$f" |
  while IFS=$'\t' read -r engine status until fails refusals; do
    # T039: report the status the record ACTUALLY has now, not the last one
    # marked -- `ledger_mark` writes "rate_limited" once and nothing rewrites
    # it when the window closes. T008: a capability refusal is not an engine
    # fault, so it is counted and shown separately from failures. Both.
    eff="$(_ledger_effective "$repo" "$until" "$fails")"
    if [ "$eff" = rate_limited ]; then
      detail="until $(_ledger_epoch_to_iso "$until")"
    else
      detail=""
      if [ "${fails:-0}" -gt 0 ] 2>/dev/null; then
        detail="failures $fails"
      elif [ "$status" = rate_limited ]; then
        detail="rate limit expired $(_ledger_epoch_to_iso "$until")"
      fi
      if [ "${refusals:-0}" -gt 0 ] 2>/dev/null; then
        if [ -n "$detail" ]; then
          detail="$detail refusals $refusals"
        else
          detail="refusals $refusals"
        fi
      fi
      [ -n "$detail" ] || detail="-"
    fi
    printf '%s\t%s\t%s\n' "$engine" "$eff" "$detail"
  done
}
