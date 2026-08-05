#!/usr/bin/env bash
# lib/drive.sh -- the deterministic drive POLICY layer (Track 2).
#
# Pure library: every function here only READS (task frontmatter, reconciled
# envelopes, archetype manifests, config, git worktree registrations) and
# prints a structured verdict. Nothing in this file mutates `.orchid/`, spawns
# anything, or shells out to an engine -- the driver (runners/orchid-drive)
# turns these verdicts into verb calls, and verbs are the only writers.
#
# Source AFTER lib/common.sh, lib/frontmatter.sh, lib/manifest.sh,
# lib/archetype.sh, lib/schedule.sh, lib/envelope.sh, lib/resolver.sh,
# lib/review.sh and lib/hooks.sh -- this file calls into all of them.
#
# INV-05/INV-14 discipline: no decision below reads a plugin's NAME. Task
# routing is driven by the archetype's declared `transitions=`/`outcome=`
# data plus the kernel's own status vocabulary; review policy is driven by
# `risk_tier`/`blocking_severity` frontmatter and envelope FIELDS.

# drive_finding_rank <severity> -- ordinal for a FINDING's severity. An
# unrecognized value ranks 99, i.e. above every threshold: an envelope that
# reports a severity the kernel does not understand is treated as blocking
# (fail closed), never silently ignored.
drive_finding_rank() {
  case "$1" in
    low) echo 0 ;;
    medium) echo 1 ;;
    high) echo 2 ;;
    *) echo 99 ;;
  esac
}

# Exit-code registry, for reference from the two files that use the new
# codes literally (the same way 3/5/13/14/15 are already written literally at
# their own sites): 2 unknown verb, 3 illegal transition, 5
# rebase_rereview_required, 12 input_overflow, 13 plugin validation failure,
# 14 no eligible engine, 15 hook handler failure, 16 JUDGMENT BOUNDARY
# (`orchid drive` when a pass stopped at one; `orchid run boundary show` when
# one is recorded), 17 BROKERED COMMAND REFUSED
# (runners/orchid-orchestrator-command).

# drive_threshold_rank <blocking_severity> -- ordinal for the TASK's
# configured blocking threshold. Deliberately the mirror image of
# drive_finding_rank's fail-closed default: an unrecognized/absent threshold
# falls back to `medium` (the kernel's own derived default, see `orchid task
# set risk_tier`) rather than to 99, which would silently make NOTHING
# blocking -- fail open, the one direction this must never take.
drive_threshold_rank() {
  case "$1" in
    low) echo 0 ;;
    medium) echo 1 ;;
    high) echo 2 ;;
    *) echo 1 ;;
  esac
}

# The closed set of judgment-boundary kinds. Kernel-owned, exactly like
# lib/hooks.sh's `_HOOK_POINTS`: a boundary record naming anything outside
# this set is a programming error, not a new kind. Space-padded for the
# substring membership idiom this codebase already uses.
#
#   planning          -- run_status is `planning`; drafting is operator work
#   blocked-task      -- a task sits in `blocked`; only an operator resolves it
#   review-evidence   -- fewer valid, ok, current-candidate reviews on hand
#                        than the risk_tier requires; or the tier's count is
#                        met while a routed reviewer slot has none of its own
#   review-conflict   -- request-changes, blocking finding, mixed verdicts,
#                        or a review that did not cover the whole scope
#   hook-failure      -- a `:required` hook binding has no ok, current envelope
#   worktree-conflict -- a dispatch worktree cannot be proven to belong to
#                        this task/repo/branch
#   run-complete      -- every task is `done`; PROTOCOL.md's COMPLETION
#                        procedure (acceptance checks, then `orchid run
#                        accept --evidence`) is still to be run
#   operator-decision -- everything else this policy deliberately refuses to
#                        decide (attempts exhausted, wallclock budget, a
#                        status/archetype combination with no declared edge)
_DRIVE_BOUNDARY_KINDS=" planning blocked-task review-evidence review-conflict hook-failure worktree-conflict run-complete operator-decision "

drive_boundary_kind_valid() {  # kind -> 0 iff kernel-owned
  case "$_DRIVE_BOUNDARY_KINDS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# -- boundary resolvability -------------------------------------------------
# Whether a woken orchestrator can actually SETTLE a boundary is NEVER a
# property of the boundary kind alone. It is the conjunction of three facts,
# and getting any one of them wrong burns an LLM wakeup per pump cycle on a
# decision the model has no verb to make -- or, worse, suppresses the
# `orchid notify` blocker that is the only way a human ever hears about it:
#
#   1. WHICH VERB settles this kind at all (drive_boundary_settling_verb).
#   2. Whether the RESOLVED ADAPTER's command surface admits that verb. A
#      `command_surface=brokered` adapter (plugins/engines/claude) can run
#      nothing but runners/orchid-orchestrator-command, whose table admits
#      exactly one state-changing judgment verb -- `orchid task arbitrate` --
#      and refuses `plan apply`, `run accept`, `task unblock` and every other
#      write outright. A `soft` adapter has no enforceable restriction, so
#      every verb is reachable from it.
#   3. Whether the TASK'S CURRENT STATUS lets that verb run. `orchid task
#      arbitrate` refuses anything but `arbitrating` (libexec/orchid-task,
#      exit 3), so a review boundary raised while the task is still
#      `reviewing` is NOT arbitrable, however arbitrable the same kind
#      becomes one transition later.
#
# Two live defects made this explicit rather than implicit. A `run-complete`
# boundary was classified as orchestrator-resolvable even though the broker
# refuses `orchid run accept`, so a FINISHED run woke a model every staleness
# window forever and -- because the notify path is suppressed for anything
# orchestrator-resolvable -- never told the human to run `orchid run accept
# --evidence`. And the reviewing walk's own review-evidence boundaries ranked
# as arbitrable while the task was still `reviewing`, outranking genuine
# operator-only boundaries with a verb that would have exited 3.

# The write verbs runners/orchid-orchestrator-command admits, as verb-phrase
# atoms. Kept as data beside the broker's own table, not inferred from it.
_DRIVE_BROKERED_WRITE_VERBS=" task-arbitrate journal-add lessons-add notify run-boundary-clear "

# drive_surface_admits <command_surface> <verb-phrase> -- 0 iff an adapter
# declaring <command_surface> can actually run that verb. `soft` is the
# absence of an enforceable restriction, so it admits everything; anything
# unrecognized is treated as `brokered`, the NARROWER surface, so an unknown
# label can only ever route more boundaries to a human, never fewer.
drive_surface_admits() {
  local surface="$1" verb="$2"
  case "$surface" in
    soft) return 0 ;;
    *)
      case "$_DRIVE_BROKERED_WRITE_VERBS" in
        *" $verb "*) return 0 ;;
        *) return 1 ;;
      esac ;;
  esac
}

# drive_boundary_settling_verb <kind> -- the ONE verb that records the result
# behind this boundary kind, or nothing when no verb does and only a human at
# a terminal can act:
#
#   review-evidence  -- `orchid task arbitrate` (the arbitration truth table)
#   review-conflict
#   planning         -- `orchid plan apply` (PROTOCOL.md PLANNING)
#   run-complete     -- `orchid run accept --evidence` (PROTOCOL.md COMPLETION)
#
# `blocked-task` (`task unblock`/`task retry`), `hook-failure` (its handler or
# its binding is broken), `worktree-conflict` (a checkout that cannot be proven
# to belong to this task) and the `operator-decision` catch-all deliberately
# name none: no procedure an orchestrator can run resolves them.
drive_boundary_settling_verb() {
  case "$1" in
    review-evidence|review-conflict) printf 'task-arbitrate\n' ;;
    planning) printf 'plan-apply\n' ;;
    run-complete) printf 'run-accept\n' ;;
    *) return 0 ;;
  esac
}

# drive_boundary_resolvable <kind> <task-status> <command_surface> -- 0 iff a
# woken orchestrator could settle this exact boundary, right now, with a verb
# its adapter admits and the task's current status allows. Fail-closed on
# every axis: no settling verb, a surface that refuses it, or a status that
# would make it exit 3, all mean "a human has to be told".
drive_boundary_resolvable() {
  local kind="$1" status="${2:-}" surface="${3:-brokered}" verb
  verb="$(drive_boundary_settling_verb "$kind")"
  [ -n "$verb" ] || return 1
  drive_surface_admits "$surface" "$verb" || return 1
  case "$verb" in
    task-arbitrate) [ "$status" = arbitrating ] || return 1 ;;
  esac
  return 0
}

# drive_boundary_priority <kind> <task-status> <command_surface> -- 1 for a
# boundary a woken orchestrator can settle now, 0 for one only an operator can.
#
# This is the RANKING key runners/orchid-drive uses when a pass meets several
# boundaries and may record only one. Without it a `blocked` task -- which
# raises the same operator-only boundary on EVERY pass until a human runs
# `task unblock`/`task retry` -- would permanently mask a later task's
# arbitrable one, spending one LLM wakeup per pump cycle on a decision the
# woken model has no verb to make. Ranking, not suppression: PROTOCOL.md
# requires a blocked task to be a boundary (it is how an operator learns the
# run is parked), so it is still recorded whenever nothing outranks it.
drive_boundary_priority() {
  if drive_boundary_resolvable "$@"; then echo 1; else echo 0; fi
}

# drive_boundary_wakes_orchestrator <kind> <task-status> <command_surface> --
# 0 iff waking an orchestrator can move this boundary at all. Exactly the same
# question drive_boundary_priority ranks by, and deliberately so: the two used
# to disagree (planning and run-complete woke a model without being settleable
# by any verb the broker admits), and that gap is precisely what left a
# finished run polling a model forever with the human never notified.
# runners/orchid-pump is the caller for the wake decision; runners/orchid-drive
# is the caller for the mirror-image one -- a boundary this returns 1 for is
# routed to `orchid notify` instead, so it reaches a human.
drive_boundary_wakes_orchestrator() {
  drive_boundary_resolvable "$@"
}

# drive_orchestrator_surface <repo> -- the `command_surface` label of the
# adapter the pump would actually wake for a boundary in THIS repository, or
# `brokered` when no orchestrator engine resolves at all (nobody will be woken,
# so the narrowest surface is the honest answer and every boundary falls to the
# notify path). An engine that declares no label reads as `soft`, matching
# runners/orchid-tick and INV-14: the field may weaken its own claim by
# omission, never strengthen it.
#
# Read-only, like everything else in this file: resolve_role_available walks
# the chain, the ledger and the capsuite and mutates none of them.
drive_orchestrator_surface() {
  local repo="$1" engine dir surface
  engine="$(resolve_role_available "$repo" orchestrator 2>/dev/null)" || {
    printf 'brokered\n'; return 0
  }
  [ -n "$engine" ] || { printf 'brokered\n'; return 0; }
  dir="$(resolve_engine_dir "$engine" 2>/dev/null || true)"
  [ -n "$dir" ] || { printf 'brokered\n'; return 0; }
  surface="$(manifest_get "$dir" command_surface soft)"
  case "$surface" in
    brokered|soft) ;;
    *) surface=soft ;;
  esac
  printf '%s\n' "$surface"
}

# drive_has_transition <archetype> <from> <to> -- 0 iff the archetype
# literally declares that edge. `blocked` is deliberately NOT special-cased
# here the way libexec/orchid-task's `legal()` does: the driver never routes
# work through the universal escape hatch by accident, it only ever takes
# edges an archetype actually declares.
drive_has_transition() {
  local arch="$1" from="$2" to="$3" transitions
  transitions="$(archetype_transitions "$arch" 2>/dev/null)" || return 1
  [ -n "$transitions" ] || return 1
  grep -qxF "$from:$to" <<< "$transitions"
}

# drive_dispatch_target <archetype> <from> -- the status a queued task
# (`pending`/`rework`) is dispatched INTO, read straight off the archetype's
# declared transitions: the first declared `from:<to>` whose `<to>` is an
# active status (lib/schedule.sh's set). Prints nothing when the archetype
# declares no such edge -- the caller turns that into a boundary rather than
# guessing. This is what makes the walk archetype-driven: `feature` yields
# `implementing`, the shipped `review` archetype yields `reviewing`, and a
# custom archetype yields whatever IT declares, with no name anywhere.
drive_dispatch_target() {
  local arch="$1" from="$2" line to transitions
  transitions="$(archetype_transitions "$arch" 2>/dev/null)" || return 0
  [ -n "$transitions" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$from":*) ;;
      *) continue ;;
    esac
    to="${line#*:}"
    if schedule_is_active_status "$to"; then
      printf '%s\n' "$to"
      return 0
    fi
  done <<< "$transitions"
  return 0
}

# drive_role_for_status <status> -- which role's work a task in <status> is
# waiting on, and which operation that role performs. Prints
# "<role><TAB><operation>", nothing when the status is not one a launch
# serves (testing runs `orchid verify` in the tick's own foreground;
# arbitrating is inline judgment; merging is a verb). Kernel status
# vocabulary only -- never an archetype or engine name.
drive_role_for_status() {
  case "$1" in
    implementing) printf 'implementer\timplement\n' ;;
    reviewing) printf 'reviewer\treview\n' ;;
    *) return 0 ;;
  esac
}

# drive_envelope_has_blocking_finding <envelope> <blocking_severity> -- 0 iff
# the envelope reports at least one finding at or above the task's blocking
# threshold. Unknown finding severities rank 99 (see drive_finding_rank), so
# they always block.
drive_envelope_has_blocking_finding() {
  local f="$1" rank
  rank="$(drive_threshold_rank "$2")"
  jq -e --argjson t "$rank" '
    def frank: if . == "low" then 0
               elif . == "medium" then 1
               elif . == "high" then 2
               else 99 end;
    [ (.findings // [])[] | ((.severity // "") | ascii_downcase | frank) ]
    | any(. >= $t)
  ' "$f" >/dev/null 2>&1
}

# drive_review_decision <repo> <task> -- THE non-overlapping arbitration
# truth table, evaluated over the reconciled reviewer envelopes bound to the
# task's CURRENT attempt. Prints exactly one line:
#
#   approve<TAB><detail>    every required review is valid and current, every
#                           verdict is `approve`, every review covered the
#                           whole scope, and no finding reaches the task's
#                           blocking_severity -- the ONLY deterministic
#                           approval this policy will ever make.
#   evidence<TAB><detail>   fewer valid, `ok`, current-candidate reviews on
#                           hand than the task's risk_tier requires.
#   conflict<TAB><detail>   a request-changes verdict, a finding at or above
#                           blocking_severity, mixed verdicts, or a review
#                           that reports scope_complete false.
#
# The three arms are mutually exclusive and evaluated in that order, so an
# incomplete review set is never also reported as a conflict (and vice
# versa). No prose is parsed anywhere: every input is a structured envelope
# field the kernel already validates.
#
# THE EVIDENCE SET IS EXACTLY THE ONE THE KERNEL GATE COUNTS, and this
# function's job is to mirror libexec/orchid-task's reviewing->arbitrating
# gate rather than to second-guess it. That gate counts an envelope only when
# its candidate_sha equals the task's current one AND its status is `ok`, and
# it SILENTLY SKIPS everything else -- its own comment says so: "Only
# status==ok envelopes count; anything else is silently skipped, same as an
# sha mismatch." So here too, an envelope is skipped, never boundaried, when
# it is bound to some other candidate (a superseded sibling left behind by a
# relaunched reviewer slot, or by the merging->testing rebase edge), when its
# candidate_sha cannot be read at all (it cannot be proven to be in the
# current set), when it fails envelope_validate, or when its status is not
# `ok`. Sufficiency is then purely the COUNT of surviving envelopes against
# review_required_count, and the evidence arm fires on that count alone.
#
# WHY IT MUST BE SKIP AND NOT FAIL-CLOSED (lesson L007). The ordinary
# recovery path is: a reviewer slot errors, `orchid jobs reconcile` files the
# adapter's own non-ok envelope (`failed`, `timeout`, `rate_limited` -- all
# valid envelopes) BOUND TO THE CURRENT CANDIDATE, and the relaunched slot
# then files a good one. The kernel gate ignores the dead envelope,
# counts the live one, and admits the task to `arbitrating` with a complete
# unanimous set. If this function instead boundaried on the dead envelope,
# that task would be permanently refused deterministic approval over a file
# no verb can remove -- parked in `arbitrating` forever. A boundary must
# never be reachable only through a state the kernel itself calls fine.
#
# Not a weakening of fail-closed: this function can only ever count FEWER
# envelopes than the kernel gate (it adds envelope_validate on top of the
# gate's own two tests), so a shortfall still stops at an evidence boundary
# -- and one raised while the task is `arbitrating`, where `orchid task
# arbitrate` is exactly the verb that settles it.
#
# HONEST LABELING (lesson L006): the blocking_severity gate below reads
# `findings[]`, and findings[] is only ever populated by an adapter that
# fills it. The shipped review adapters do NOT: plugins/engines/claude/run
# and plugins/engines/codex/run ask a `review` reply for a VERDICT line only
# and write `findings: []` verbatim (`FINDING:` lines are requested by the
# CRITIQUE prompt alone). For those reviewers the severity gate is INERT and
# deterministic approval rests on `verdict` + `scope_complete` alone; it
# bites only for an adapter that genuinely reports findings.
drive_review_decision() {
  local repo="$1" id="$2" state tf attempt tier need cand blocking
  local f n approve_n conflicts base verdict scope status ecand
  state="$(orchid_state "$repo")"
  tf="$state/tasks/$id.md"
  if [ ! -f "$tf" ]; then
    printf 'evidence\tno task %s\n' "$id"
    return 0
  fi
  attempt=$(( $(fm_get "$tf" attempts) + 1 ))
  tier="$(fm_get "$tf" risk_tier)"; [ -n "$tier" ] || tier=low
  need="$(review_required_count "$tier")"
  cand="$(fm_get "$tf" candidate_sha)"
  blocking="$(fm_get "$tf" blocking_severity)"; [ -n "$blocking" ] || blocking=medium

  if [ -z "$cand" ]; then
    printf 'evidence\tno candidate_sha recorded, so no review can be bound to it\n'
    return 0
  fi

  n=0; approve_n=0; conflicts=""
  for f in "$state/reviews/$id-a$attempt-reviewer"*.json; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    # Step 1 -- scope, exactly as the kernel gate scopes: only envelopes
    # bound to the CURRENT candidate are evidence at all. An unreadable
    # candidate_sha cannot be proven to be in that set, so it is skipped for
    # the same reason a mismatched one is.
    ecand="$(envelope_field "$f" '.candidate_sha // empty' 2>/dev/null || true)"
    [ -n "$ecand" ] || continue
    [ "$ecand" = "$cand" ] || continue
    # Step 2 -- within that set, only a VALID, `ok` envelope carries a
    # verdict. A malformed or non-ok one is skipped, never boundaried: it is
    # the residue of a slot that errored, and the relaunch that replaces it
    # is what the count below is waiting for.
    envelope_validate "$f" 2>/dev/null || continue
    status="$(envelope_field "$f" '.status // empty' 2>/dev/null || true)"
    [ "$status" = ok ] || continue
    n=$(( n + 1 ))
    verdict="$(envelope_field "$f" '.verdict // empty' 2>/dev/null || true)"
    scope="$(envelope_field "$f" '.scope_complete // false' 2>/dev/null || true)"
    if [ "$verdict" = approve ]; then
      approve_n=$(( approve_n + 1 ))
    else
      conflicts="$conflicts $base:verdict=${verdict:-none}"
    fi
    if [ "$scope" != true ]; then
      conflicts="$conflicts $base:scope_complete=false"
    fi
    if drive_envelope_has_blocking_finding "$f" "$blocking"; then
      conflicts="$conflicts $base:finding>=$blocking"
    fi
  done

  if [ "$n" -lt "$need" ]; then
    printf 'evidence\tincomplete review evidence: %s of %s required for risk_tier %s bound to candidate %s\n' \
      "$n" "$need" "$tier" "$cand"
    return 0
  fi

  if [ -n "$conflicts" ]; then
    printf 'conflict\t%s\n' "${conflicts# }"
    return 0
  fi

  printf 'approve\tunanimous scope-complete approval from %s review(s), no finding at or above %s\n' \
    "$approve_n" "$blocking"
}

# drive_hook_has_required <repo> <point> -- 0 iff the point's binding carries
# at least one `:required` entry. A point bound only `optional` never gates
# anything, on any point (see drive_hook_unsatisfied below), so the driver
# must not park a task on one either: this is what tells it apart.
drive_hook_has_required() {
  local repo="$1" point="$2" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | cut -f2)" = required ] || continue
    return 0
  done <<< "$(hooks_for "$repo" "$point")"
  return 1
}

# drive_hook_envelope_count <repo> <task> <point> <attempt> <candidate_sha> --
# how many hook envelopes filed for this point/attempt are still IN SCOPE for
# the current candidate. An envelope is counted unless it can be PROVEN
# superseded: it reports a candidate_sha, that sha is readable, and it is not
# the task's current one.
#
# This is what makes a hook re-runnable when candidate_sha moves WITHIN one
# attempt (the merging->testing rebase edge, or an implementer re-dispatch
# after a waived rework). drive_hook_unsatisfied below binds a `:required`
# entry's satisfaction to the CURRENT candidate, so counting the superseded
# envelope as evidence-on-hand would leave the point permanently unsatisfiable
# -- launched never again, gated forever, with no verb able to release it. Not
# counting it makes the point look unstarted for the new candidate, which is
# exactly what it is, so the driver dispatches it again.
#
# Fail-closed in the other direction, deliberately: an envelope carrying no
# readable candidate_sha cannot be proven superseded, so it still counts. A
# hook adapter that omits the field can therefore leave a required binding
# unsatisfiable -- but that surfaces as a NAMED hook-failure boundary an
# operator sees, never as a silent relaunch loop.
drive_hook_envelope_count() {
  local repo="$1" id="$2" point="$3" attempt="$4" cand="$5" state ef ecand n
  state="$(orchid_state "$repo")"
  n=0
  for ef in "$state/reviews/$id-a$attempt-hook-$point"*.json; do
    [ -e "$ef" ] || continue
    if [ -n "$cand" ]; then
      ecand="$(envelope_field "$ef" '.candidate_sha // empty' 2>/dev/null || true)"
      if [ -n "$ecand" ] && [ "$ecand" != "$cand" ]; then
        continue
      fi
    fi
    n=$(( n + 1 ))
  done
  printf '%s\n' "$n"
}

# drive_hook_unsatisfied <repo> <task> <point> <attempt> <candidate_sha> --
# one line per `:required` binding entry on <point> that has NO reconciled
# `ok` envelope for this attempt (and, when <candidate_sha> is non-empty,
# bound to that exact candidate). Empty output means every required entry is
# satisfied, or the point is unbound / carries only `optional` entries --
# which never gate anything, on any point.
#
# Binding resolution mirrors libexec/orchid-merge's own before_merge gate: a
# filed hook envelope carries no field naming which binding produced it, so a
# required entry is satisfied only by an envelope whose `.engine` equals that
# entry's QUALIFIED manifest id (resolve_engine_qualified_id) -- never an
# assumed "orchid/<id>" string.
drive_hook_unsatisfied() {
  local repo="$1" id="$2" point="$3" attempt="$4" cand="$5"
  local state bindings line hid hreq qid ef ok
  state="$(orchid_state "$repo")"
  bindings="$(hooks_for "$repo" "$point")"
  [ -n "$bindings" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hid="$(printf '%s' "$line" | cut -f1)"
    hreq="$(printf '%s' "$line" | cut -f2)"
    [ "$hreq" = required ] || continue
    qid="$(resolve_engine_qualified_id "$hid")"
    ok=0
    for ef in "$state/reviews/$id-a$attempt-hook-$point"*.json; do
      [ -e "$ef" ] || continue
      [ "$(envelope_field "$ef" '.status // empty' 2>/dev/null || true)" = ok ] || continue
      [ "$(envelope_field "$ef" '.engine // empty' 2>/dev/null || true)" = "$qid" ] || continue
      if [ -n "$cand" ]; then
        [ "$(envelope_field "$ef" '.candidate_sha // empty' 2>/dev/null || true)" = "$cand" ] || continue
      fi
      ok=1
      break
    done
    [ "$ok" -eq 1 ] || printf '%s\n' "$hid"
  done <<< "$bindings"
}

# drive_hook_guidance <repo> <task> <point> <attempt> -- the `.artifact
# .guidance` string carried by the first ok hook envelope filed for this
# point/attempt, or nothing. Advisory input only: the driver attaches it to
# the task through `orchid task set <id> hook_guidance`, it never changes a
# routing decision.
drive_hook_guidance() {
  local repo="$1" id="$2" point="$3" attempt="$4" state ef g
  state="$(orchid_state "$repo")"
  for ef in "$state/reviews/$id-a$attempt-hook-$point"*.json; do
    [ -e "$ef" ] || continue
    [ "$(envelope_field "$ef" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    g="$(envelope_field "$ef" '.artifact.guidance // empty' 2>/dev/null || true)"
    if [ -n "$g" ]; then
      printf '%s\n' "$g"
      return 0
    fi
  done
  return 0
}

# drive_implement_envelope <repo> <task> -- the path of a reconciled `ok`
# implement envelope for this task's CURRENT attempt, preferring the highest
# collision-counter sibling (the most recently reconciled one). Prints
# nothing when the attempt has no ok implement envelope at all -- which is
# either "still running" (no envelope yet) or "the engine reported failure"
# (only non-ok envelopes); drive_implement_failed below distinguishes them.
drive_implement_envelope() {
  local repo="$1" id="$2" state attempt f best best_n rest n
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  best=""; best_n=0
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    rest="$(basename "$f")"
    rest="${rest#"$id"-a"$attempt"-implementer}"
    case "$rest" in
      .json) n=1 ;;
      .[0-9]*.json) n="${rest#.}"; n="${n%.json}" ;;
      *) continue ;;
    esac
    if [ "$n" -gt "$best_n" ]; then
      best_n="$n"; best="$f"
    fi
  done
  [ -z "$best" ] || printf '%s\n' "$best"
}

# drive_implement_failed <repo> <task> -- 0 iff at least one implement
# envelope has been reconciled for this attempt AND none of them is ok. That
# is the deterministic "the engine reported failure" signal; a task with no
# implement envelope at all is simply still awaiting one.
drive_implement_failed() {
  local repo="$1" id="$2" state attempt f any
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  any=0
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    any=1
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    return 1
  done
  [ "$any" -eq 1 ]
}

# drive_reviewer_envelope_count <repo> <task> -- how many reviewer envelopes
# for the CURRENT attempt are `ok` AND bound to the current candidate_sha:
# exactly the number libexec/orchid-task's reviewing->arbitrating gate will
# count, recomputed here so the driver never dispatches a slot the kernel
# would consider already satisfied (nor advances into a refusal).
drive_reviewer_envelope_count() {
  local repo="$1" id="$2" state tf attempt cand f n
  state="$(orchid_state "$repo")"; tf="$state/tasks/$id.md"
  attempt=$(( $(fm_get "$tf" attempts) + 1 ))
  cand="$(fm_get "$tf" candidate_sha)"
  n=0
  if [ -n "$cand" ]; then
    for f in "$state/reviews/$id-a$attempt-reviewer"*.json; do
      [ -e "$f" ] || continue
      [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
      [ "$(envelope_field "$f" '.candidate_sha // empty' 2>/dev/null || true)" = "$cand" ] || continue
      n=$(( n + 1 ))
    done
  fi
  printf '%s\n' "$n"
}

# drive_reviewer_envelope_engines <repo> <task> -- one line per reviewer
# envelope counted by drive_reviewer_envelope_count above (current attempt,
# `ok`, bound to the current candidate_sha): the QUALIFIED engine id that
# envelope reports, or a bare `-` when it reports none.
#
# `.engine` is the only durable record of WHICH engine produced a filed
# review: `orchid jobs reconcile` cross-checks it against the job manifest's
# own engine (so it cannot be forged past reconcile) and then deletes the
# manifest, leaving the envelope as the sole survivor. Adapters that omit the
# field -- it is optional, and today's fixtures exercise that -- yield `-`,
# which drive_review_slots_unsatisfied treats as attributable to any slot.
drive_reviewer_envelope_engines() {
  local repo="$1" id="$2" state tf attempt cand f e
  state="$(orchid_state "$repo")"; tf="$state/tasks/$id.md"
  attempt=$(( $(fm_get "$tf" attempts) + 1 ))
  cand="$(fm_get "$tf" candidate_sha)"
  [ -n "$cand" ] || return 0
  for f in "$state/reviews/$id-a$attempt-reviewer"*.json; do
    [ -e "$f" ] || continue
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    [ "$(envelope_field "$f" '.candidate_sha // empty' 2>/dev/null || true)" = "$cand" ] || continue
    e="$(envelope_field "$f" '.engine // empty' 2>/dev/null || true)"
    printf '%s\n' "${e:--}"
  done
}

# _drive_pool_take <pool> <want> -- prints <pool> minus the FIRST line equal
# to <want>; exit 1 (pool printed unchanged) when there is none. Consuming
# rather than merely testing is what gives the matching below multiplicity:
# one envelope can satisfy exactly one slot.
_drive_pool_take() {
  local want="$2" line found=0 out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$found" -eq 0 ] && [ "$line" = "$want" ]; then found=1; continue; fi
    out="$out$line
"
  done <<< "$1"
  printf '%s' "$out"
  [ "$found" -eq 1 ]
}

# drive_review_slots_unsatisfied <repo> <task> <routing> -- the rows of
# <routing> (`orchid jobs review-plan`'s "<slot><TAB><engine><TAB><label>"
# table) that have NO review of their own yet. Empty output means every routed
# slot is covered.
#
# Keyed on SLOT IDENTITY, never on a count. A count is the wrong key the
# moment a slot is relaunched: with slot 1 routed to engine A and slot 2 to
# engine B, a relaunch that lands a SECOND A review takes the count to the
# tier's required number, and a count-keyed driver would then both stop
# dispatching slot 2 and hand `drive_review_decision` two reviews from one
# engine to approve unanimously -- defeating the engine independence the whole
# risk-tiered review policy exists to enforce (docs/specs/kernel.md,
# "Independence"). Here A's second review can only ever satisfy a slot the
# routing table itself routed to A, which is exactly the degraded case
# `review_routing` already labels `session-independent` and journals.
#
# Envelopes that name no engine (`-`) are matched LAST, after every exact
# attribution has been made, and can stand in for any remaining slot: an
# adapter that omits `.engine` leaves nothing to attribute by, and refusing to
# credit its review would relaunch a slot forever.
drive_review_slots_unsatisfied() {
  local repo="$1" id="$2" routing="$3" pool line eng qid unmatched out
  pool="$(drive_reviewer_envelope_engines "$repo" "$id")"

  unmatched=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    eng="$(printf '%s' "$line" | cut -f2)"
    qid="$(resolve_engine_qualified_id "$eng" 2>/dev/null || true)"
    [ -n "$qid" ] || qid="$eng"
    if pool="$(_drive_pool_take "$pool" "$qid")"; then
      continue
    fi
    unmatched="$unmatched$line
"
  done <<< "$routing"

  out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if pool="$(_drive_pool_take "$pool" -)"; then
      continue
    fi
    out="$out$line
"
  done <<< "$unmatched"
  printf '%s' "$out"
}

# -- worktree identity ------------------------------------------------------
# Dispatch must be idempotent and crash-safe: a pass that dies between `git
# worktree add` and `orchid task set <id> worktree <path>` must be resumable
# without ever creating a SECOND worktree for the same task, and a path that
# cannot be proven to belong to this task, this branch and this repository
# must be refused rather than reused.

# _drive_physical <path> -- canonical absolute path, or nothing.
_drive_physical() {
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

# _drive_common_dir <path> -- the canonical Git COMMON directory backing the
# checkout at <path> (the shared `.git` of the main worktree, identical for
# every linked worktree of the same repository), or nothing. This is the fact
# that distinguishes "a worktree of MY repository" from "some other clone
# that happens to sit at the expected path".
_drive_common_dir() {
  local d="$1" g
  g="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  case "$g" in
    /*) ;;
    *) g="$d/$g" ;;
  esac
  _drive_physical "$g"
}

# drive_worktree_path <repo> <task> -- the conventional dispatch path for a
# task's worktree: a SIBLING of the repository directory named
# `<repo-basename>-<task-id>`. Deterministic (so a crashed pass can find the
# orphan it already created) and outside the repository (so a task checkout
# is never nested inside the integration checkout).
drive_worktree_path() {
  local repo="$1" id="$2" phys parent base
  phys="$(_drive_physical "$repo")" || return 1
  parent="$(dirname "$phys")"
  base="$(basename "$phys")"
  printf '%s/%s-%s\n' "$parent" "$base" "$id"
}

# _drive_worktree_registered <repo> <path> -- 0 iff <path> is a currently
# registered worktree of <repo> (compared physically, so a symlinked TMPDIR
# never causes a false mismatch).
_drive_worktree_registered() {
  local repo="$1" want="$2" line p
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) ;;
      *) continue ;;
    esac
    p="${line#worktree }"
    p="$(_drive_physical "$p" 2>/dev/null || printf '%s' "$p")"
    [ "$p" = "$want" ] || continue
    return 0
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  return 1
}

# _drive_branch_checkout <repo> <branch> -- the physical path of the
# registered worktree that currently has <branch> checked out, or nothing.
_drive_branch_checkout() {
  local repo="$1" branch="$2" line p cur=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur="${line#worktree }" ;;
      "branch refs/heads/$branch")
        [ -n "$cur" ] || continue
        p="$(_drive_physical "$cur" 2>/dev/null || printf '%s' "$cur")"
        printf '%s\n' "$p"
        return 0 ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)
  return 0
}

# _drive_other_task_claims <repo> <task> <path> -- 0 iff some OTHER task's
# frontmatter already records <path> as its worktree. A shared dispatch
# worktree would let two tasks commit onto each other's branch, so this is
# always a refusal, never a reuse.
_drive_other_task_claims() {
  local repo="$1" id="$2" want="$3" state f other p
  state="$(orchid_state "$repo")"
  for f in "$state/tasks"/*.md; do
    [ -e "$f" ] || continue
    other="$(fm_get "$f" id)"
    [ "$other" = "$id" ] && continue
    p="$(fm_get "$f" worktree)"
    [ -n "$p" ] || continue
    p="$(_drive_physical "$p" 2>/dev/null || printf '%s' "$p")"
    [ "$p" = "$want" ] || continue
    return 0
  done
  return 1
}

# drive_worktree_plan <repo> <task> -- decides, WITHOUT touching anything,
# what dispatch should do about this task's worktree. Prints exactly one
# line, "<action><TAB><path-or-reason>":
#
#   reuse  <path>   the recorded worktree is registered to THIS repository's
#                   git-common-dir, sits at the recorded path, has the task's
#                   own branch checked out, and no other task claims it.
#   adopt  <path>   frontmatter records no worktree yet, but the conventional
#                   path already holds an EXACT match on all of those facts:
#                   the orphan a crashed pass created between `git worktree
#                   add` and `task set worktree`. Recorded, never recreated.
#   create <path>   nothing exists at the conventional path and the task's
#                   branch is not checked out anywhere.
#   refuse <reason> anything else -- a recorded path that has vanished, a
#                   foreign checkout, a branch mismatch, a directory that is
#                   not a worktree of this repository, or a path another task
#                   already claims. A duplicate worktree is never created to
#                   work around any of these.
drive_worktree_plan() {
  local repo="$1" id="$2" state tf branch recorded want phys repo_common cand_common cur_branch other
  state="$(orchid_state "$repo")"; tf="$state/tasks/$id.md"
  branch="$(fm_get "$tf" branch)"
  if [ -z "$branch" ]; then
    printf 'refuse\ttask %s records no branch\n' "$id"
    return 0
  fi
  repo_common="$(_drive_common_dir "$repo")" || {
    printf 'refuse\tcannot resolve the git common directory of %s\n' "$repo"
    return 0
  }
  want="$(drive_worktree_path "$repo" "$id")" || {
    printf 'refuse\tcannot resolve a dispatch worktree path for %s\n' "$id"
    return 0
  }
  recorded="$(fm_get "$tf" worktree)"

  if [ -n "$recorded" ]; then
    phys="$(_drive_physical "$recorded")" || {
      printf 'refuse\trecorded worktree %s does not exist (operator must repair or clear it)\n' "$recorded"
      return 0
    }
    if _drive_other_task_claims "$repo" "$id" "$phys"; then
      printf 'refuse\trecorded worktree %s is already claimed by another task\n' "$phys"
      return 0
    fi
    if ! _drive_worktree_registered "$repo" "$phys"; then
      printf 'refuse\trecorded worktree %s is not a registered worktree of this repository\n' "$phys"
      return 0
    fi
    cand_common="$(_drive_common_dir "$phys")" || {
      printf 'refuse\trecorded worktree %s is not a git checkout\n' "$phys"
      return 0
    }
    if [ "$cand_common" != "$repo_common" ]; then
      printf 'refuse\trecorded worktree %s belongs to a different repository\n' "$phys"
      return 0
    fi
    cur_branch="$(git -C "$phys" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ "$cur_branch" != "$branch" ]; then
      printf 'refuse\trecorded worktree %s has branch %s checked out, not %s\n' \
        "$phys" "${cur_branch:-<detached>}" "$branch"
      return 0
    fi
    printf 'reuse\t%s\n' "$phys"
    return 0
  fi

  # No recorded worktree. Either an exact orphan is sitting at the
  # conventional path (adopt it), or nothing is (create it) -- but never
  # create when the branch is already checked out somewhere else.
  if [ -e "$want" ]; then
    phys="$(_drive_physical "$want")" || {
      printf 'refuse\t%s exists but is not a directory\n' "$want"
      return 0
    }
    if _drive_other_task_claims "$repo" "$id" "$phys"; then
      printf 'refuse\t%s is already claimed by another task\n' "$phys"
      return 0
    fi
    if ! _drive_worktree_registered "$repo" "$phys"; then
      printf 'refuse\t%s exists but is not a registered worktree of this repository\n' "$phys"
      return 0
    fi
    cand_common="$(_drive_common_dir "$phys")" || {
      printf 'refuse\t%s exists but is not a git checkout\n' "$phys"
      return 0
    }
    if [ "$cand_common" != "$repo_common" ]; then
      printf 'refuse\t%s belongs to a different repository\n' "$phys"
      return 0
    fi
    cur_branch="$(git -C "$phys" symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ "$cur_branch" != "$branch" ]; then
      printf 'refuse\t%s has branch %s checked out, not %s\n' \
        "$phys" "${cur_branch:-<detached>}" "$branch"
      return 0
    fi
    printf 'adopt\t%s\n' "$phys"
    return 0
  fi

  other="$(_drive_branch_checkout "$repo" "$branch")"
  if [ -n "$other" ]; then
    printf 'refuse\tbranch %s is already checked out at %s, not at the dispatch path %s\n' \
      "$branch" "$other" "$want"
    return 0
  fi
  printf 'create\t%s\n' "$want"
}
