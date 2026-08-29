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

# ---------------------------------------------------------------------------
# A NON-APPROVE VERDICT MUST CARRY A FINDING THE SEVERITY GATE CAN SEE
# (dogfood F32, reproduced independently in r-002).
#
# THE DEFECT. A reviewer may return `verdict: request-changes` with
# `findings: []` and put the entire substance of its objection in the
# free-text `summary`. On wasiyyat T004 that summary held a real correctness
# defect -- a handler that flushed `started` while the run row it claimed was
# not guaranteed committed -- and the structured array was empty. On r-002
# T020 the same shape appeared again: `request-changes`, `findings: []`, the
# whole objection in one line of prose.
#
# THE DANGER IS NOT THE DISAGREEMENT, IT IS THE AGREEMENT. Every
# severity-based gate in this system reads `findings[]`: lib/drive.sh's
# deterministic approval arm reports "no finding at or above <severity>" from
# it, and PROTOCOL.md's PLANNING loop folds a critique's findings back into
# the draft until nothing at or above `medium` is left. An envelope whose only
# content is prose contributes NOTHING to either. Had the second reviewer on
# that task also said `approve` while keeping the same prose caveat, the
# defect would have sailed through deterministic approval -- not because the
# gate was wrong, but because the field it consults was empty. A gate weighing
# an empty array reports the same sentence whether the reviewers found nothing
# or wrote everything they found somewhere the gate cannot look.
#
# WHY THIS IS NOT SPELLED "MALFORMED". Refusing such an envelope at
# envelope_validate (or quarantining it at reconcile) is the tempting fix and
# it is the wrong one: the shipped verdict-only `review` adapters --
# plugins/engines/codex/run and its siblings -- write `findings: []` VERBATIM
# on every review they file, so "non-approve with an empty findings[]" is the
# ordinary shape of a legitimate objection from them, not a forgery. Rejecting
# it would throw the reviewer's prose into quarantine, leave the task short of
# its required review count, and park it at a review-evidence boundary whose
# operator then has nothing to read. That destroys the very evidence F32 is
# about. So the envelope is ACCEPTED and its objection is MADE VISIBLE:
# `envelope_synthesize_finding` lifts the summary into findings[] at reconcile
# time, and the entry says plainly that the kernel composed it. The invariant
# a validation rule would have bought -- every non-approve review carries at
# least one finding -- is delivered by CONSTRUCTION instead of by rejection,
# and it holds for the adapters that cannot be changed as well as the ones
# that can. This is the prose firewall (docs/specs/kernel.md) applied exactly
# as written: free-form text reaches a gate only after a deterministic verb
# has translated it into structured state, and that verb is `jobs reconcile`.
#
# The severity is `high` deliberately: drive_threshold_rank maps every
# recognized threshold to at most `high`, so a `high` finding is the one value
# that cannot be filtered out below any task's `blocking_severity`. The kernel
# cannot read a severity out of prose, and the only fail-closed reading of "I
# will not approve this" is the severity no threshold silently drops. Nothing
# here pretends the reviewer said `high`: the entry carries its own provenance
# (`source`/`synthesized`), and the reviewer's summary is preserved verbatim
# in `detail` alongside the truncated title.
ENVELOPE_SYNTHESIZED_FINDING_SEVERITY="high"
ENVELOPE_SYNTHESIZED_FINDING_SOURCE="orchid:synthesized-from-summary"

ENVELOPE_EXCERPT_MAX=160

# envelope_fold_line <text> [max] -- <text> folded to ONE line, with runs of
# whitespace squeezed to single spaces and the result truncated to [max]
# characters (default ENVELOPE_EXCERPT_MAX). Empty in, empty out.
#
# THE FOLD IS NOT COSMETIC. Every caller puts the result into a TAB-separated,
# one-line record: lib/drive.sh's decision line is read with `cut -f1`/`cut
# -f2-`, and runners/orchid-drive turns field 2 into a boundary reason. Text
# carrying a newline would truncate that record at the first line and a raw
# TAB would shift every field after it -- so an envelope could corrupt the
# very boundary record meant to surface it.
#
# ONE FOLD FOR EVERY FIELD THAT TRAVELS IN THAT RECORD, which is why this is a
# function and not two copies. Both an engine-written `summary` and an
# engine-written finding `title` reach the record, both are free text an
# adapter controls, and a fold that protected only the field someone happened
# to add first would leave the record corruptible through the other.
#
# THE FOLD IS DONE IN THE SHELL, NOT IN jq, and that is deliberate. Collapsing
# whitespace runs wants `gsub`, and jq's regex functions need an
# Oniguruma-enabled build -- nothing else in this kernel asks jq for one, and
# a jq built without it does not fail loudly at the call sites below: `gsub`
# would error, the `2>/dev/null || true` guarding their jq calls would swallow
# that error, and the excerpt would come back EMPTY on every envelope. That is
# the one failure this must not have, since an empty excerpt is
# indistinguishable from "the reviewer wrote nothing there" and silently drops
# the objection it exists to carry. `tr` is already a hard dependency of every
# verb in the repo.
envelope_fold_line() {
  local raw="$1"
  local max="${2:-$ENVELOPE_EXCERPT_MAX}"
  raw="$(printf '%s' "$raw" | tr '\n\r\t\v\f' '     ' | tr -s ' ')"
  # `tr -s` leaves at most a single leading/trailing space behind.
  raw="${raw# }"; raw="${raw% }"
  if [ "${#raw}" -gt "$max" ]; then
    printf '%s...\n' "${raw:0:$max}"
  else
    printf '%s\n' "$raw"
  fi
}

# envelope_summary_excerpt <envelope> [max] -- the envelope's `summary`, folded
# by envelope_fold_line. Empty when the envelope carries no summary.
envelope_summary_excerpt() {
  local f="$1"
  local raw
  raw="$(jq -r '.summary // ""' "$f" 2>/dev/null || true)"
  envelope_fold_line "$raw" "${2:-$ENVELOPE_EXCERPT_MAX}"
}

# envelope_prose_only_objection <envelope> -- 0 iff this envelope is an `ok`
# review/critique that WITHHOLDS approval while reporting no finding at all:
# the shape above. Absent and empty `findings` are the same case (a reviewer
# that omits the key reports exactly as much as one that writes `[]`).
#
# Bound to `review`/`critique` because `verdict` means nothing on the other
# operations, and to `status == ok` because a `failed`/`timeout`/`no_envelope`
# envelope is the residue of a slot that errored -- it carries no judgment to
# lift. That last one matters since T040: a salvaged envelope reconstructed
# from a dead job's log can carry a scraped `request-changes` verdict with no
# finding beside it, and inventing a `high` out of the kernel's own
# reconstruction would be putting weight on text nobody filed as a judgment.
envelope_prose_only_objection() {
  jq -e '
    (.status == "ok")
    and ((.operation // "") | IN("review","critique"))
    and ((.verdict // "") | (length > 0) and (. != "approve"))
    and (((.findings // []) | length) == 0)
  ' "$1" >/dev/null 2>&1
}

# envelope_synthesize_finding <envelope> -- prints the envelope with exactly
# one finding composed from its `summary`, for an envelope that
# envelope_prose_only_objection has just matched. Prints; writes nothing (the
# caller decides whether the result is fit to keep).
#
# The title is MARKED, so no reader mistakes a kernel-composed entry for the
# reviewer's own severity call, and `detail` keeps the summary whole where the
# title had to be cut. An objection filed with neither findings nor a summary
# still yields an entry -- there is nothing to carry, and that itself is what
# the gate must be told, rather than being handed a silent empty array again.
envelope_synthesize_finding() {
  local f="$1"
  local excerpt
  excerpt="$(envelope_summary_excerpt "$f" 200)"
  [ -n "$excerpt" ] || excerpt="a non-approve verdict filed with no findings[] and no summary"
  jq --arg sev "$ENVELOPE_SYNTHESIZED_FINDING_SEVERITY" \
     --arg title "synthesized from summary: $excerpt" \
     --arg src "$ENVELOPE_SYNTHESIZED_FINDING_SOURCE" '
    .findings = [ { severity: $sev, title: $title, source: $src,
                    synthesized: true, detail: (.summary // "") } ]
  ' "$f"
}
