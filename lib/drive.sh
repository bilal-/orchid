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
# OUTSTANDING (`orchid drive` when a pass met one -- the pass still walked
# every task and took every edge it could, so this reports a decision waiting
# somewhere, never a run that cannot proceed; `orchid run boundary show` when
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
#                        this task/repo/branch, or its state cannot be READ at
#                        all: an inspection that answers "clean" when it could
#                        not look is fail-open, so it is refused in the same
#                        direction as a tree that is genuinely in the way
#   operator-handoff  -- the candidate's execution-requiring mechanical steps
#                        (a lint fix, a checksum re-pin, a mode bit on a new
#                        executable) are not acknowledged for THIS candidate.
#                        Deliberately settled by no verb below: none performs
#                        the work, and a model able to acknowledge its own
#                        hand-off would defeat the point of naming one at all
#                        (lesson L017; lib/handoff.sh)
#   run-complete      -- every task is `done`; PROTOCOL.md's COMPLETION
#                        procedure (acceptance checks, then `orchid run
#                        accept --evidence`) is still to be run
#   operator-decision -- everything else this policy deliberately refuses to
#                        decide (attempts exhausted, wallclock budget, a
#                        status/archetype combination with no declared edge, an
#                        implement dispatch that committed nothing but left
#                        real work uncommitted in the task worktree -- whether
#                        that is committed or thrown away is a decision about
#                        somebody's output, not a rung of a ladder)
_DRIVE_BOUNDARY_KINDS=" planning blocked-task review-evidence review-conflict hook-failure worktree-conflict operator-handoff run-complete operator-decision "

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
#   2. Whether the RESOLVED ADAPTER's command surface admits that verb --
#      which is a question about the WAKEUP CONTRACT, not only about a
#      sandbox. A `command_surface=brokered` adapter can run nothing but
#      runners/orchid-orchestrator-command, whose table admits exactly one
#      state-changing judgment verb -- `orchid task arbitrate` -- and refuses
#      `plan apply`, `run accept`, `task unblock` and every other write
#      outright. A `soft` adapter is not STOPPED from running those, but
#      nothing asks it to: the orchestrate request an adapter is woken with
#      is the judgment-boundary contract (read the record, read the task and
#      its reviews, record ONE decision), and that contract names the same
#      write verbs the broker admits. So `soft` reads "the same set,
#      unenforced" -- never "every verb".
#
#      It used to read "every verb", and that was this file's own founding
#      defect reintroduced on the other path. With a soft orchestrator
#      resolved, EVERY kind classified as orchestrator-resolvable; the
#      `orchid notify` blocker is suppressed for exactly those; so a finished
#      run's `orchid run accept` and a `planning` run's `orchid plan apply`
#      woke a model once per staleness window forever, for a decision no
#      prompt had asked it to make -- with the human never told, which is the
#      one outcome the brokered path exists to prevent.
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

# ...and the ones a `soft` adapter can be relied on to run: the SAME set,
# reached by a different route. The broker ENFORCES the list above; a soft
# adapter is bounded only by the orchestrate prompt it is handed, and that
# prompt asks a woken orchestrator for exactly these decisions and no others.
# Derived here rather than retyped so the two can never silently disagree: a
# surface that is one day asked to settle more (an adapter whose prompt really
# does direct it through `orchid plan apply`) widens HERE, in data, in the
# same commit that changes the prompt -- which is what tests/test_drive.sh's
# Part R pins, so the classification and the prompt cannot drift apart.
_DRIVE_SOFT_WRITE_VERBS="$_DRIVE_BROKERED_WRITE_VERBS"

# drive_surface_admits <command_surface> <verb-phrase> -- 0 iff an adapter
# declaring <command_surface>, woken for a boundary, can be relied on to run
# that verb. Anything unrecognized is treated as `brokered` -- the surface
# whose set is enforced rather than merely asked for -- so an unknown label
# can only ever route more boundaries to a human, never fewer.
drive_surface_admits() {
  local surface="$1" verb="$2" admitted
  case "$surface" in
    soft) admitted="$_DRIVE_SOFT_WRITE_VERBS" ;;
    *) admitted="$_DRIVE_BROKERED_WRITE_VERBS" ;;
  esac
  case "$admitted" in
    *" $verb "*) return 0 ;;
    *) return 1 ;;
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
# Naming a verb is NOT the same as an adapter being able to run it: no surface
# admits `plan apply` or `run accept` today (neither the broker's table nor
# the judgment-boundary prompt any adapter is woken with mentions either), so
# `planning` and `run-complete` are operator-only on every surface. They stay
# in this table because it answers one question -- which verb would record the
# result -- and admission is deliberately the separate axis above; the day an
# adapter is asked to run one, it is one atom of data that changes.
#
# `blocked-task` (`task unblock`/`task retry`), `hook-failure` (its handler or
# its binding is broken), `worktree-conflict` (a checkout that cannot be proven
# to belong to this task), `operator-handoff` and the `operator-decision`
# catch-all deliberately name none: no procedure an orchestrator can run
# resolves them.
#
# `operator-handoff` is the one whose omission is a POLICY choice rather than
# a gap. `orchid task handoff --ack` is a real verb, and the broker could be
# taught to admit it -- which is exactly why it must not be. The verb asserts
# that execution-requiring work was performed by an actor able to perform it;
# a model that can run no linter and no chmod, acknowledging its own hand-off,
# would turn the record into the same unsatisfiable routing the hand-off
# exists to prevent, with a durable field now claiming otherwise.
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
# fills it. The shipped review adapters are split on that (v1-m4 T006):
# plugins/engines/claude/run now asks a `review` reply for `FINDING:
# <low|medium|high>: <title>` lines as well as the VERDICT line and parses
# them, so the gate is LIVE for a claude reviewer. plugins/engines/codex/run
# (and the other shipped review adapters) still ask for a VERDICT line only
# and write `findings: []` verbatim (`FINDING:` lines are requested by their
# CRITIQUE prompt alone) -- for those reviewers the severity gate is INERT
# and deterministic approval rests on `verdict` + `scope_complete` alone.
# Either way an EMPTY findings[] blocks nothing: an engine that reports no
# findings is a valid review, and this gate has always read `[]` that way.
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
    # A DEGRADED envelope is not an answer to this point. `jobs reconcile`
    # files one (status `no_envelope`) when a job exits without writing an
    # envelope but left salvageable results in its log -- the work is
    # recovered, but nothing about it says the hook ran to completion. This
    # is the ONE counter that does not already filter on `ok`, deliberately
    # (an adapter that omits candidate_sha must still be able to satisfy a
    # binding), so it is the one place a degraded envelope would silently
    # convert an auto-relaunch into a hook-failure boundary: counted here,
    # the point reads as answered, drive_hook_unsatisfied then refuses it for
    # want of an `ok` engine match, and a human is fetched for a job the
    # ladder would have retried by itself.
    [ "$(envelope_field "$ef" '.status // empty' 2>/dev/null || true)" != no_envelope ] || continue
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
# implement envelope for this task's CURRENT attempt that has not already been
# REFUSED as a no-op delivery (drive_delivery_refused), preferring the highest
# collision-counter sibling (the most recently reconciled one). Prints
# nothing when the attempt has no such envelope at all -- which is "still
# running" (no envelope yet), "the engine reported failure" (only non-ok
# envelopes), or "the only ok one was already refused"; drive_implement_failed
# below distinguishes the first two.
drive_implement_envelope() {
  local repo="$1" id="$2" state attempt f best best_n base rest n
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  best=""; best_n=0
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    base="$(basename "$f")"
    # An envelope already refused as a no-op delivery is not an envelope any
    # more, on this pass or any later one -- see drive_delivery_refused.
    if drive_delivery_refused "$repo" "$id" "$base"; then continue; fi
    rest="${base#"$id"-a"$attempt"-implementer}"
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
#
# A REFUSED envelope is not read here either, and by exactly the same rule the
# selector above applies: it is no longer an envelope. Skipping it in only one
# of the two would strand the task rather than route it -- a refused `ok`
# sibling left visible HERE answers "did the engine report failure?" with `no`
# for the whole rest of the attempt, so a genuine non-ok envelope filed
# afterwards would be selected by nobody and escalated by nobody, and the walk
# would sit on "awaiting the implementer envelope" with no job outstanding and
# no envelope it will ever accept. One rule, both readers.
drive_implement_failed() {
  local repo="$1" id="$2" state attempt f any
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  any=0
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    if drive_delivery_refused "$repo" "$id" "$(basename "$f")"; then continue; fi
    any=1
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    return 1
  done
  [ "$any" -eq 1 ]
}

# drive_delivery_floor <repo> <task> -- the sha an implement dispatch has to
# move the task worktree PAST before its envelope counts as delivery.
#
# On a rework round that is the task's existing `candidate_sha`: the round was
# dispatched precisely to change that candidate, so a HEAD still sitting on it
# delivered nothing. On a first dispatch there is no candidate yet, so it is
# `base_sha` -- where an unmoved HEAD means the attempt produced no commit at
# all, the same failure one step earlier.
#
# Prints nothing when the task carries neither sha. `drive_dispatch` stamps
# `base_sha` on the FIRST dispatch and never re-stamps it (a rework round keeps
# the base its candidate was built on), so every task that has ever been
# dispatched carries one and that state can only come from a hand-edited task
# file. The caller below deliberately reads "nothing to compare against" as
# "cannot prove a no-op" rather than as a refusal it cannot justify.
drive_delivery_floor() {
  local repo="$1" id="$2" tf floor
  tf="$(orchid_state "$repo")/tasks/$id.md"
  floor="$(fm_get "$tf" candidate_sha)"
  [ -n "$floor" ] || floor="$(fm_get "$tf" base_sha)"
  [ -z "$floor" ] || printf '%s\n' "$floor"
}

# drive_delivery_is_noop <repo> <task> <worktree-head> -- 0 iff the dispatch
# added no commit: HEAD is exactly the floor above.
#
# AN OK ENVELOPE IS NOT EVIDENCE THAT WORK HAPPENED. An implement dispatch can
# return `ok` with a summary that is pure commentary -- findings restated,
# sources listed -- over a worktree whose HEAD never moved and whose tree is
# clean. The envelope is the engine's own account of itself; the worktree is
# the only thing that can contradict it, so delivery is judged there.
#
# THIS PREDICATE IS NOT A REFUSAL, and no caller may read it as one. It answers
# "did this round add a commit?", which is a strictly narrower question than
# "did this round fail to deliver?" -- the floor is a candidate_sha wherever the
# task has one, so a `0` here covers both a task that has produced nothing at
# all and one whose candidate is already on disk and merely gained nothing this
# round. `drive_delivery_verdict` below is what separates them, and routing on
# this predicate alone is the defect lesson L039 records.
drive_delivery_is_noop() {
  local repo="$1" id="$2" head="$3" floor
  [ -n "$head" ] || return 1
  floor="$(drive_delivery_floor "$repo" "$id")"
  [ -n "$floor" ] || return 1
  [ "$head" = "$floor" ]
}

# drive_delivery_verdict <repo> <task> <worktree-head> <dirty-summary>
# <inspect-rc> -- ONE word for what the dispatch actually left behind:
#
#   delivered    HEAD moved off the floor. There is a candidate; the envelope
#                is accepted and nothing here looks at the tree (a dirty tree
#                over a MOVED head is the operator hand-off's question, asked
#                one state later against a candidate that exists -- lib/handoff.sh).
#   nothing      HEAD unchanged, the tree clean, and NO candidate exists: the
#                floor the round failed to move off is the task's `base_sha`.
#                The commentary-only round -- no commit, no edit, nothing on
#                disk to show for the dispatch, and nothing on disk from any
#                earlier one either.
#   unchanged    HEAD unchanged and the tree clean, but the floor is a
#                CANDIDATE that is not the base: a candidate demonstrably
#                exists and this round added no commit on top of it.
#   uncommitted  HEAD unchanged but the tree is NOT clean. The dispatch wrote
#                real work and failed to commit it.
#   uninspected  HEAD unchanged and the tree could not be read at all.
#
# WHY `unchanged` IS NOT `nothing` (lesson L039). Both are an unmoved HEAD over
# a clean tree, and folding them together is a comparison that never asks the
# one question separating them: does a candidate EXIST? `nothing` answers no --
# the floor is the base, so the task has produced not one commit and there is
# nothing anywhere to advance. `unchanged` answers yes: the floor is a
# candidate_sha the driver itself stamped from a HEAD it read in this worktree,
# and it differs from the base, so commits exist and a round that added none on
# top of them did not FAIL to deliver -- it delivered nothing NEW over work
# already delivered. That is a routing question, and charging it to the
# job-delivery ladder blocks a task whose candidate is sitting right there.
#
# It is reachable in ordinary operation rather than only from a lazy engine: a
# rebase rewrites a task's commits, the driver re-stamps the new HEAD as
# `candidate_sha`, the next round dispatches, and the implementer finds its own
# already-delivered work in place and truthfully reports that there is nothing
# to change. Every run with concurrency above one rebases in-flight tasks onto
# a moved integration branch, so every such run walks into this.
#
# BOTH SHAS MUST BE ON RECORD for `unchanged`. "A candidate exists" is a claim
# about work that was produced, and the only proof available here is a recorded
# base the recorded candidate differs from; with the base missing (a state no
# dispatch can produce -- `drive_dispatch` stamps it on the first one) nothing
# is proven and the stricter word stands. Note that ANCESTRY is deliberately
# not required: a rebase onto a moved integration branch is exactly the trigger
# above, and it can leave the recorded base off the candidate's line of descent
# -- demanding descent here would re-block the very case this word exists to
# route. The worktree agreeing (HEAD is the candidate) is the other half of the
# evidence, and it is checked by the caller's own `git rev-parse`.
#
# WHY `uncommitted` IS NOT `nothing`. Both fail the delivery test the same way
# -- this round produced no commit, so nothing NEW may advance -- but they call
# for opposite handling, and a sha comparison cannot tell them apart because a
# sha describes a COMMIT and says nothing about the tree sitting on top of it.
# (It is checked FIRST, ahead of the candidate question above, for the same
# reason: real uncommitted output is the operator's call whether or not a
# candidate already exists, and advancing past it would carry it nowhere.)
# `nothing` has a deterministic recovery: charge the job-delivery rung and
# relaunch the implementer into the same worktree, which is exactly where it
# left off -- empty.
# Relaunching over `uncommitted` hands the new dispatch a tree it did
# not create, holding edits it cannot account for: it will commit them as its
# own, or revert them, or build on top of them, and whichever it does the
# journal will read as the work of a round that never wrote them. And the work
# is REAL -- discarding it is a decision about somebody's uncommitted output,
# which is precisely the class of question this policy refuses to make (the
# `operator-decision` boundary), not a rung of a ladder.
#
# `uninspected` is refused in the same direction as `uncommitted`, never folded
# into `nothing`: an inspection that answers "clean" when it could not look is
# the fail-open shape lib/handoff.sh's own header rejects, and folding it here
# would relaunch over a tree nobody has seen. The rc is therefore checked
# BEFORE the summary, since a failed inspection prints its diagnosis on the
# same channel a dirty tree prints paths on.
#
# The tree is passed IN, already read, rather than looked at here: this file is
# deterministic policy over structured state (INV-13) and the caller is the one
# holding both libraries. `handoff_worktree_dirty` is what produces the two
# arguments -- its stdout and its exit status -- and it already excludes
# `.orchid/`, which is no part of any candidate.
drive_delivery_verdict() {
  local repo="$1" id="$2" head="$3" dirty="$4" irc="${5:-0}"
  local tf cand base
  if ! drive_delivery_is_noop "$repo" "$id" "$head"; then
    printf 'delivered\n'; return 0
  fi
  if [ "$irc" -ne 0 ]; then printf 'uninspected\n'; return 0; fi
  if [ -n "$dirty" ]; then printf 'uncommitted\n'; return 0; fi
  tf="$(orchid_state "$repo")/tasks/$id.md"
  cand="$(fm_get "$tf" candidate_sha)"
  base="$(fm_get "$tf" base_sha)"
  if [ -n "$cand" ] && [ -n "$base" ] && [ "$cand" != "$base" ] && [ "$head" = "$cand" ]; then
    printf 'unchanged\n'; return 0
  fi
  printf 'nothing\n'
}

# drive_delivery_refused <repo> <task> <envelope-basename> -- 0 iff this exact
# envelope has ALREADY been refused as a no-op delivery on this task.
#
# A REFUSAL THAT DOES NOT STICK IS NOT A REFUSAL. `jobs reconcile` files every
# implement envelope of an attempt as a sibling and removes none of them, so a
# refused one sits there for the rest of the attempt, still `ok`, still the
# newest `ok` -- and the no-op test above is a comparison against a MOVING
# worktree, not a property of the envelope. The refused work then walks back in
# by two other doors, both of which end with it advanced to testing:
#
#   * HEAD MOVES. The relaunch the refusal itself started commits to that same
#     worktree. The instant it does, the already-refused envelope stops looking
#     like a no-op -- HEAD is off the floor -- and reads as delivery of a commit
#     it never made. (The driver also refuses to read ANY envelope while an
#     implement job is outstanding, which closes this door for the window the
#     relaunch is alive; this mark closes it for good, including after that job
#     dies without filing an envelope of its own.)
#   * A NEWER NON-OK SIBLING ARRIVES. The relaunch reports failure. "The newest
#     ok envelope" is still the refused one, so the failure is stepped over and
#     the refused envelope selected again.
#
# Both are answered in one place, by never selecting it again. The mark is the
# task's own `refused_envelopes` frontmatter list, written through `orchid task
# set` -- INV-13: the driver mutates durable state only through named verbs and
# decides only on structured fields, so no sidecar file and no mutation of the
# engine's own artifact. BASENAMES, not counters: the basename carries the
# attempt in it (`<id>-a<n>-implementer[.k].json`), so a mark left by an earlier
# attempt can never mask a later attempt's envelope.
drive_delivery_refused() {
  local repo="$1" id="$2" base="$3" list
  [ -n "$base" ] || return 1
  list="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" refused_envelopes)"
  [ -n "$list" ] || return 1
  # Space-delimited membership, matched WITH the delimiters, so a basename can
  # only match a whole entry and never a fragment of a longer one (a task id
  # that is a prefix of another's, say). No word splitting, so nothing globs.
  case " $list " in
    *" $base "*) return 0 ;;
  esac
  return 1
}

# drive_delivery_refused_any <repo> <task> -- 0 iff a no-op delivery has been
# refused on this task's CURRENT attempt.
#
# The mark makes the refused envelope invisible, and that costs the ladder the
# durable signal it runs on: a non-ok envelope stays readable for the rest of
# the attempt, so an escalation whose relaunch never happened (no eligible
# engine, a launch that failed) is simply escalated again next pass until the
# cap fetches a human -- but a REFUSED envelope answers "did the engine report
# failure?" with nothing at all, and the walk would sit on "awaiting the
# implementer envelope" forever with no job, no envelope it will ever accept
# and no boundary. So the refusal itself is the signal: a task with one on
# record, nothing outstanding and nothing acceptable is a failure state the
# ladder must answer, not a wait.
#
# Scoped to the current attempt by the basename's own `-a<n>-` segment (the
# whole reason the mark is a basename), so a refusal from an earlier round
# cannot make a fresh round look like a failure. The trailing `-implementer`
# keeps `a1` from matching `a11`.
drive_delivery_refused_any() {
  local repo="$1" id="$2" tf attempt list
  tf="$(orchid_state "$repo")/tasks/$id.md"
  attempt=$(( $(fm_get "$tf" attempts) + 1 ))
  list="$(fm_get "$tf" refused_envelopes)"
  [ -n "$list" ] || return 1
  case " $list " in
    *" $id-a$attempt-implementer"*) return 0 ;;
  esac
  return 1
}

# drive_delivery_refusal_list <repo> <task> <envelope-basename> -- the value the
# driver writes back to `refused_envelopes` when it refuses that envelope: the
# existing list with this basename appended. IDEMPOTENT -- an envelope already
# on the list is not appended twice, so a refusal that somehow reaches the same
# envelope a second time (it should not: the selector above already excludes it)
# rewrites the same value rather than growing the field.
drive_delivery_refusal_list() {
  local repo="$1" id="$2" base="$3" list
  list="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" refused_envelopes)"
  if [ -z "$base" ] || drive_delivery_refused "$repo" "$id" "$base"; then
    printf '%s\n' "$list"
    return 0
  fi
  if [ -n "$list" ]; then
    printf '%s %s\n' "$list" "$base"
  else
    printf '%s\n' "$base"
  fi
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
