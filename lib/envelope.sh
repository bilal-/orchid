#!/usr/bin/env bash
# Envelope status vocabulary. Six of the seven are an ADAPTER's own report of
# itself. The seventh, `no_envelope` (T040), is the one status no adapter may
# ever write: it is the KERNEL's own account of a job that exited without
# writing an envelope at all, reconstructed by `orchid jobs reconcile` from
# what the job left in its log. It is accepted here so a salvaged envelope is
# a first-class, readable envelope like any other -- and refused at the spool
# door in libexec/orchid-jobs, so an adapter can never file one itself and
# pass its own crash off as the kernel's reconstruction of one.
#
# `failure_kind` (optional, v1-m5 T008): how the adapter itself classifies a
# non-`ok` envelope -- `capability` (it declined by design: an operation it
# never claimed, a diff over its own inline byte cap) or `engine` (it
# genuinely failed). Absent means `engine`, so every pre-existing adapter and
# fixture keeps its exact meaning. Constrained here rather than merely passed
# through because `lib/ledger.sh`'s ledger_mark acts on it: a `capability`
# claim spares the engine a consecutive-failure charge, and a field with that
# much say over failover must be a known value on an envelope that actually
# reports a failure. `capability` alongside `status:"ok"` is incoherent (there
# is no failure to classify) and fails validation -> quarantine, which is the
# fail-closed direction: a quarantined envelope never reaches the ledger at
# all.
envelope_validate() {
  jq -e '
    (.contract == 1)
    and (.job_id | type == "string" and length > 0)
    and (.task   | type == "string" and length > 0)
    and (.status | IN("ok","failed","rate_limited","timeout","auth","malformed","no_envelope"))
    and (
      .status != "ok" or (
        (.operation == "implement" and (.summary | type == "string" and length > 0))
        or ((.operation | IN("review","critique"))
            and (.verdict | IN("approve","request-changes"))
            and (.scope_complete | type == "boolean"))
        or (.operation == "orchestrate"
            and (.actions | type == "array" and all(.[]; type == "string"))
            and (.summary | type == "string" and length > 0))
        or (.operation == "hook"
            and (.artifact | type == "object")
            and (.summary | type == "string" and length > 0))
      )
    )
    and (
      (has("findings") | not) or
      (.findings | type == "array" and
        all(.[];
          type == "object"
          and (.severity | type == "string" and length > 0)
          and (.title    | type == "string" and length > 0)))
    )
    and (
      (has("commits") | not) or
      (.commits | type == "array" and all(.[]; type == "string"))
    )
    and (
      (has("failure_kind") | not) or
      ((.failure_kind | IN("capability","engine")) and .status != "ok")
    )
  ' "$1" >/dev/null
}
envelope_field() { jq -r "$2" "$1"; }

# envelope_salvage_json <log-file> -- what an exited-without-an-envelope job
# left behind in its own log, as {"findings":[...], "verdict":<string|null>}.
# Always prints a valid object; an unreadable or resultless log yields
# {"findings":[],"verdict":null} rather than failing.
#
# WHY THIS EXISTS (dogfood finding F35, the worst of that run). A critique
# attempt ran to completion, produced EIGHT complete findings, wrote every
# one of them to its job log, and then exited WITHOUT writing an envelope.
# `orchid jobs reconcile` had nothing to land, so from the outside the attempt
# simply never happened: the findings sat in
# `.orchid/runtime/logs/j-e0-plan-a4-b068.log` until an operator recovered
# them with grep and applied them by hand. Without that grep they were lost
# and an expensive critique would have been re-run to regenerate findings
# orchid already had on disk. The engine had already been paid for that work.
#
# THE GRAMMAR IS THE ADAPTERS' OWN, NOT A NEW ONE. `FINDING: <low|medium|high>:
# <title>` and a whole-line `VERDICT: approve|request-changes` are exactly the
# two reply shapes plugins/engines/{claude,codex,hermes}/run already ask a
# review/critique reply for and already parse out of the engine's stdout --
# and the launcher tees that same stdout into the job log, so the lines this
# reads are the lines the adapter would have parsed had it lived long enough
# to. This is deliberately a scrape of text the kernel did not itself
# structure, so it is best-effort in exactly the way the adapters' own parse
# is: a severity token that is not one of the three, an empty title, or a
# reply that merely echoes the instruction line back (severity token
# `<low|medium|high>` and all) contributes nothing rather than failing the
# salvage.
#
# CAPPED, because a log is unbounded input. A runaway or hostile log cannot
# turn one dead job into a megabyte of durable envelope: past the cap the
# scrape simply stops, and the count that landed is reported by the caller.
ENVELOPE_SALVAGE_MAX_FINDINGS=200
envelope_salvage_json() {
  local log="$1"
  local rest sev title vline verdict ndjson findings n
  findings='[]'; verdict=""; ndjson=""; n=0
  if [ -f "$log" ]; then
    while IFS= read -r rest; do
      [ "$n" -lt "$ENVELOPE_SALVAGE_MAX_FINDINGS" ] || break
      sev="$(printf '%s' "$rest" | cut -d: -f1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      title="$(printf '%s' "$rest" | cut -d: -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      case "$sev" in low|medium|high) ;; *) continue ;; esac
      [ -n "$title" ] || continue
      ndjson="$ndjson$(jq -n --arg s "$sev" --arg t "$title" '{severity:$s,title:$t}')"$'\n'
      n=$((n + 1))
    done < <(grep '^FINDING:' "$log" 2>/dev/null | sed 's/^FINDING:[[:space:]]*//' || true)
    [ -z "$ndjson" ] || findings="$(printf '%s' "$ndjson" | jq -s -c '.')"
    # `tail -n1`, matching the adapters: the LAST whole verdict line wins, so
    # a reply that reasons its way to a verdict is read at its conclusion.
    # No early-exiting consumer here, so no SIGPIPE for pipefail to promote.
    vline="$(grep -iE '^VERDICT:[[:space:]]*(approve|request-changes)[[:space:]]*$' "$log" 2>/dev/null | tail -n1 || true)"
    case "$(printf '%s' "$vline" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
      verdict:approve) verdict=approve ;;
      verdict:request-changes) verdict=request-changes ;;
    esac
  fi
  jq -n --argjson f "$findings" --arg v "$verdict" \
    '{findings:$f, verdict:(if $v == "" then null else $v end)}'
}

# envelope_salvage_empty <salvage-json> -- 0 iff the scrape found NOTHING: no
# finding and no verdict. The caller files a degraded envelope only when this
# is false, which is the whole difference between "orchid recovered work the
# engine had already done" and "orchid invented an envelope for a job that
# produced nothing" -- the second would put a same-shaped file on disk for
# every muted handler that exits quietly, which several gates read as
# evidence that the point has been answered.
envelope_salvage_empty() {
  [ "$(printf '%s' "$1" | jq -r '((.findings | length) == 0) and (.verdict == null)')" = true ]
}
