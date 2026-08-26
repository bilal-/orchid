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
# `blocked-task` (`task unblock`/`task retry`/`task reverify`), `hook-failure`
# (its handler or
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
#
# One active status is NEVER a dispatch target: `<idle> -> testing`, the
# operator's reverify edge (T026). That edge means "a human has vouched for
# this tree, re-run verification against it" -- it is reached through `orchid
# task reverify`, or through the `task advance` that enforces the identical
# conditions, and both demand a recorded reason, a clean task worktree and a
# candidate_sha that IS that worktree's HEAD. The driver deciding a queued
# task needs no implementer is not that, and it is skipped explicitly here
# rather than left to fall out of declaration order: the scan below is
# first-active-wins over the archetype's `transitions=` list, so an archetype
# that merely listed `rework:testing` ahead of `rework:implementing` would
# send every reworked task straight back into verification of the candidate
# that just failed -- spawning no engine, consuming the pass, and re-running
# a suite nobody had fixed anything for. What a dispatch MEANS must not
# depend on the order a config line happens to be written in.
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
    if [ "$to" = testing ] && ! schedule_is_active_status "$from"; then
      continue
    fi
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

# drive_failure_charged <repo> <key> -- 0 iff this run's journal already
# records an infrastructure-failure charge carrying <key>.
#
# THE IDEMPOTENCY KEY FOR ONE JOB FAILURE, and the whole reason the escalation
# ladder can count one physical event exactly once across a crash. Two arms
# charge the same stranded launch: the driver's `drive_launch`, synchronously,
# with the launcher's non-zero exit still in hand, and its ageing sweep, some
# passes later, reading the manifest that launch left behind. Only one of them
# has an event; the other is looking at a corpse.
#
# A MARK ON THE MANIFEST CANNOT ARBITRATE BETWEEN THEM. Whichever order it is
# written in, one crash window is left open and it is never the same one: mark
# first and a process that dies before `task infra-fail` loses the charge
# outright (the failure is then invisible forever, which is the exact silence
# this ladder exists to end); charge first and a process that dies before the
# mark pays for the same event twice, blocking a task on arithmetic. Two
# non-atomic writes cannot be made exactly-once by ordering them.
#
# So the dedup asks for the receipt THE CHARGE ITSELF WROTE. `orchid task
# infra-fail` is journal-first by construction (libexec/orchid-task: the reason
# lands in journal.md before the counter it justifies is written), so a charge
# whose reason carries the receipt token below has already recorded, durably,
# that this job was counted. Charging is then at-least-once against a durable
# key, which is exactly once. The only window left is inside infra-fail's own
# journal-then-write pair -- not this file's to close, and orders of magnitude
# tighter than a whole drive pass.
#
# `[ladder job <id>]`, not a bare `[job <id>]`, and the word carries weight: a
# false positive here SILENCES A FAILURE, so the token must be one that only the
# ladder ever writes. Any other journal line that happened to mention a job id
# in brackets -- a note, an operator's own entry, some future diagnostic -- would
# otherwise read as a charge that never happened, and the incident it was
# standing in front of would go uncounted. runners/orchid-drive is the sole
# writer of this token; nothing else in the kernel emits it. It writes it from
# exactly three places, all of them accounting one job failure once:
# drive_escalate (the charge), drive_launch's optional-hook arm and the
# escalation sweep's optional-hook arm (the two halves of a failure that is
# journaled but deliberately spends no rung -- the receipt is how they avoid
# recording the same handler's collapse twice).
#
# Straight at the FILE, never `cat ... | grep -q`: under `set -o pipefail` a
# grep that exits early on its first match SIGPIPEs its writer and poisons the
# pipeline status, which is the trap tests/helpers.sh documents for assert_match
# and the same one that would make this answer "no" precisely when it is "yes".
# -F for the same reason the callers' own tests use it: the token is bracketed,
# and a regex reader would take `[ladder job ...]` for a character class.
drive_failure_charged() {
  local repo="$1" key="$2" journal
  [ -n "$key" ] || return 1
  journal="$(orchid_state "$repo")/journal.md"
  [ -f "$journal" ] || return 1
  grep -qF -e "$(drive_failure_receipt "$key")" "$journal"
}

# drive_failure_receipt <key> -- the receipt token for a job failure, written
# into the charge's own reason and looked for by drive_failure_charged above.
# ONE function so the writer and the reader can never drift; empty for a caller
# with no job to name, which is what makes the receipt optional at the call site
# without any caller having to spell the format.
drive_failure_receipt() {
  [ -n "${1:-}" ] || return 0
  printf ' [ladder job %s]' "$1"
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

# -- which implement envelope belongs to THIS round -------------------------
#
# An implement envelope is filed as `reviews/<id>-a<attempt>-implementer.json`,
# with `.2.json`, `.3.json` siblings for later ones at the same attempt. On an
# ordinary rework round `attempts` moves, so the previous round's envelopes are
# unreachable by name and none of this is needed.
#
# A WAIVED round is the exception, and it was a live defect. `--waive-attempt`
# leaves `attempts` unchanged on purpose -- it is a waiver, not a fresh attempt
# -- so the re-dispatched round recomputes the SAME attempt number, and the
# first `drive_implementing` pass after it resolved the PREVIOUS round's ok
# envelope, stamped the worktree HEAD that had not moved as the candidate, and
# advanced straight back to testing. The verify then re-ran an unchanged
# candidate and failed again for the same reason, with the newly launched
# implementer still writing to that worktree.
#
# So a waived round records a FLOOR when it is entered: `implement_floor:
# a<attempt>:<n>`, where `n` is the highest sibling counter already on disk.
# Only an envelope ABOVE that floor counts for the round that follows, which is
# exactly "a waived round must have a fresh envelope of its own". The attempt
# is written into the mark so it cannot outlive the attempt it was taken for --
# once `attempts` moves, the floor is inert rather than wrong.

# _drive_implement_index <file> <id> <attempt> -- the sibling counter of an
# implement envelope filename (`...-implementer.json` is 1, `....2.json` is 2),
# or nothing when the name is not one.
_drive_implement_index() {
  local rest
  rest="$(basename "$1")"
  rest="${rest#"$2"-a"$3"-implementer}"
  case "$rest" in
    .json) printf '1\n' ;;
    .[0-9]*.json) rest="${rest#.}"; printf '%s\n' "${rest%.json}" ;;
  esac
}

# drive_implement_floor <repo> <task> -- the sibling counter an implement
# envelope must EXCEED to count for this task's current attempt. 0 when no
# floor was recorded, or when the recorded one was taken for another attempt.
drive_implement_floor() {
  local repo="$1" id="$2" state attempt mark
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  mark="$(fm_get "$state/tasks/$id.md" implement_floor)"
  case "$mark" in
    "a$attempt:"*) mark="${mark#*:}" ;;
    *) printf '0\n'; return 0 ;;
  esac
  case "$mark" in ''|*[!0-9]*) mark=0 ;; esac
  printf '%s\n' "$mark"
}

# drive_implement_floor_mark <repo> <task> -- the `implement_floor` value to
# record right now: every implement envelope this task's current attempt has
# already produced is below it.
drive_implement_floor_mark() {
  local repo="$1" id="$2" state attempt f n best=0
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    n="$(_drive_implement_index "$f" "$id" "$attempt")"
    [ -n "$n" ] || continue
    [ "$n" -gt "$best" ] || continue
    best="$n"
  done
  printf 'a%s:%s\n' "$attempt" "$best"
}

# drive_implement_envelope <repo> <task> -- the path of a reconciled `ok`
# implement envelope for this task's CURRENT attempt AND above its floor,
# preferring the highest collision-counter sibling (the most recently
# reconciled one). Prints nothing when the attempt has no such envelope at all
# -- which is either "still running" (no envelope yet) or "the engine reported
# failure" (only non-ok envelopes); drive_implement_failed below distinguishes
# them.
drive_implement_envelope() {
  local repo="$1" id="$2" state attempt f best best_n base floor n
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  floor="$(drive_implement_floor "$repo" "$id")"
  best=""; best_n=0
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    base="$(basename "$f")"
    # An envelope already refused as a no-op delivery is not an envelope any
    # more, on this pass or any later one -- see drive_delivery_refused.
    if drive_delivery_refused "$repo" "$id" "$base"; then continue; fi
    n="$(_drive_implement_index "$f" "$id" "$attempt")"
    [ -n "$n" ] || continue
    [ "$n" -gt "$floor" ] || continue
    if [ "$n" -gt "$best_n" ]; then
      best_n="$n"; best="$f"
    fi
  done
  [ -z "$best" ] || printf '%s\n' "$best"
}

# drive_implement_failed <repo> <task> -- 0 iff at least one implement
# envelope has been reconciled for this attempt ABOVE ITS FLOOR and none of
# those is ok. That is the deterministic "the engine reported failure" signal;
# a task with no implement envelope of its own is simply still awaiting one.
#
# The floor applies here for the same reason it applies above, in the other
# direction: a waived round whose fresh implementer reports non-ok must still
# escalate, and it would not if the previous round's `ok` envelope were allowed
# to answer the question.
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
  local repo="$1" id="$2" state attempt f any floor n
  state="$(orchid_state "$repo")"
  attempt=$(( $(fm_get "$state/tasks/$id.md" attempts) + 1 ))
  floor="$(drive_implement_floor "$repo" "$id")"
  any=0
  for f in "$state/reviews/$id-a$attempt-implementer"*.json; do
    [ -e "$f" ] || continue
    if drive_delivery_refused "$repo" "$id" "$(basename "$f")"; then continue; fi
    n="$(_drive_implement_index "$f" "$id" "$attempt")"
    [ -n "$n" ] || continue
    [ "$n" -gt "$floor" ] || continue
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

# -- verification-failure classification ------------------------------------
# The attempt budget is supposed to measure the CANDIDATE's quality. Left
# unclassified it measures the harness's bad days instead: in r-002's
# bootstrap wave, a stale Formula pin the implementer profile cannot re-pin and
# an executable that shipped without its mode bit each consumed rework attempts
# and drove tasks to `blocked` without a single defect in the code under test.
# Two more classes of the same injustice ran through that wave: a task worktree
# that never received the gitignored dependency tree the integration checkout
# carries (lesson L003), and an assertion the repository already knew sampled a
# race (lesson L020, which stranded eight tasks and outspent every real defect
# in the run).
#
# So a failure is CLASSIFIED before anything charges it. The bias is
# one-directional and deliberate: forgiving a real defect hides it, while
# charging a spurious failure only costs an attempt, so every case the
# classifier cannot decide charges, and says why. No arm here forgives on the
# ABSENCE of evidence -- only on positive evidence.
#
# FOUR WAIVERS, AND NO FRAMEWORK. Earlier rounds of this classifier grew
# surface -- a per-repository signature list of failure SENTENCES, a
# dependency-directory NAME list, a whole-round exemption -- and each addition
# forgave something it never meant to: a generic name list let an unrelated
# `.cache` directory plus any `command not found` line waive every failure in a
# round. What is left forgives only what can be PROVED, and each proof is a
# closed question answered by the world rather than a reading of the failure:
#
#   1. A STALE PACKAGE PIN, proved by RUNNING the repository's own freshness
#      check and reading a positive staleness report out of what it printed.
#   2. AN EXECUTABLE LEFT MODE 644, proved by STATTING the file.
#   3. GITIGNORED BUILD STATE THE WORKTREE NEVER RECEIVED, proved by comparing
#      the two checkouts -- and attributed only when the thing the round could
#      not resolve is one that LIVES INSIDE the missing tree.
#   4. AN ASSERTION THE REPOSITORY ALREADY RECORDED AS FLAKY, in a register
#      this candidate did not touch, matched literally.
#
# A FIFTH WAS WITHDRAWN, AND IT IS WORTH KNOWING WHY: a run whose recorded exit
# status is 124, 137 or 143 was taken to have been KILLED before it reached a
# verdict, so there was nothing about the candidate to forgive. That premise
# was assumed rather than proved -- the identical trailer is what a candidate
# that HUNG leaves, and what a suite that exited with the status deliberately
# leaves. It is now reported on a charged round instead
# (`_DRIVE_CUT_SHORT_STATUSES`).
#
# 1 and 2 are hand-offs the protocol itself names -- an implementer profile may
# not `chmod` and may not re-pin a checksum (L017). 3 is a dispatch step. 4 is
# a test somebody has already written down as broken. None of them is a thing
# the implementer can fix by trying again, which is what makes charging an
# attempt for them meaningless.
#
# A ROUND IS NEVER WAIVED AS A ROUND, AND THAT IS THE WHOLE SAFETY PROPERTY.
# Each waiver is attributed to ONE artifact, and claims only the failing lines
# that artifact accounts for. Whatever no artifact claims is what decides: a
# single unexplained failing line charges the round, and the reason quotes it.
# NO ARM IS EXEMPT FROM THAT ACCOUNTING -- the build-state arm that used to be
# (an absent ignored directory taken to invalidate the whole run) is exactly
# how an unrelated ignored directory came to waive failures it had no part in,
# and it is back above WITH the accounting rather than around it.

# _drive_verify_body <verify-log> -- just the verification command's OWN
# output: everything after the log's `---` separator, minus the single
# trailing `exit: N` line the verb appends.
#
# Matching the body and not the whole file is load-bearing. The header carries
# `command:` -- the verification command verbatim -- so a path named there
# would be found in the header of EVERY failure that repository ever produces,
# and attribution would hold for all of them.
#
# Only the LAST line is dropped, and only if it is the verb's own trailer. A
# test suite is entitled to print `exit: 1` as part of its own diagnostics --
# this repository's own drive tests do -- and deleting those lines everywhere
# would quietly rewrite the evidence attribution is decided against.
_drive_verify_body() {
  local log="$1"
  [ -f "$log" ] || return 0
  awk '
    started {
      if (have) print prev
      prev = $0; have = 1
    }
    /^---$/ { started = 1 }
    END { if (have && prev !~ /^exit: [0-9]+$/) print prev }
  ' "$log"
}

# drive_verify_class <repo> <task-file> <verify-log> -- classify a FAILED
# verification. Prints one tab-separated line, "<class><TAB><reason>":
#
#   candidate    the candidate is what failed -- charge the attempt. Also the
#                answer whenever classification is not possible, so the strict
#                reading is the default rather than a special case.
#   handoff      one of the two operator hand-offs above is outstanding AND
#                every failing line in this round is attributable to it, so the
#                round is waiting on the operator rather than on the
#                implementer.
#   environment  the worktree this candidate was verified in is missing
#                gitignored build state the integration checkout carries, and
#                what this round could not resolve lives inside it (L003).
#   flaky        this repository recorded the failing assertion as known-flaky
#                BEFORE this candidate, in a register the candidate did not
#                touch (L020).
#
# A RUN THAT WAS KILLED IS NOT A FOURTH CLASS, and it used to be. `orchid
# verify` recording exit 124, 137 or 143 was read as "the harness reaped this
# pass, so it never spoke about the candidate" and waived the round. That is
# one reading of the status and not the only one: 143 is what a candidate's own
# `exit 143` leaves behind, and a candidate that HANGS until a timeout reaps it
# leaves the identical trailer. Nothing in the log distinguishes the three, so
# the provenance was never proved -- it was assumed, on exactly the evidence
# this classifier refuses everywhere else. The state is still REPORTED, because
# an operator reading a charged round needs to know the run stopped rather than
# finished, and the round CHARGES, because that is what an uncertain reading
# does here.
#
# THE ONE CONFIGURABLE SURFACE IS THE FLAKY REGISTER'S PATH, and the thing that
# makes it safe is not the path: it is that a register THIS CANDIDATE CHANGED
# is not an authority on this candidate. An implementer cannot quarantine the
# assertion it is failing, because touching the file removes the route -- and
# cannot reach around that by leaving the entry UNCOMMITTED either, because
# what is read normally has to be what `candidate_sha` records
# (`_drive_authority_intact`, which the pin check takes too). The only bootstrap
# is a task whose base AND candidate answerably predate the path: it can use a
# clean tracked integration copy, which the candidate cannot write. Every other
# proof here has no configuration at all.
#
# ATTRIBUTION IS PER FAILURE, AND THE UNIT IS THE FAILING LINE. Each
# outstanding hand-off claims the individual failures it explains; what is
# left unclaimed decides the round. Two consequences, and they pull in
# opposite directions on purpose:
#
#   A ROUND MAY HOLD A MIX. Two hand-offs outstanding at once, each to blame
#   for part of the output, together account for all of it and the round is
#   waived. The same round with one further unexplained failing line in it is
#   CHARGED, and the reason quotes that line: a candidate whose defect happens
#   to land alongside an outstanding hand-off is exactly the case that must not
#   be laundered.
#
#   ONE FAULT IS NOT ONE FAILING LINE. A single missing mode bit produces a
#   CASCADE -- this task's own stranding was 116 assertions from one stripped
#   bit on `runners/orchid-drive`. An accounting that could only ever claim the
#   handful of lines carrying a refusal shape would leave the other hundred
#   unexplained and charge every real hand-off it was built to recognize. So a
#   hand-off claims the whole cascade its artifact is named in, once the
#   artifact is proved to be what blocked the run (see CAUSAL/CASCADE below).
#
# NOTHING IS EXEMPT FROM THAT ACCOUNTING, and that includes the three classes
# added after the hand-offs. The build-state arm as it FIRST stood -- an absent
# ignored directory taken to invalidate the whole run -- is how an unrelated
# ignored directory came to waive failures it had no part in. The exemption was
# the mechanism, not the class, so the class is back and the exemption is not:
# a missing dependency tree claims the lines whose subject lives inside it and
# no others, exactly as a mode bit claims the lines that name the file.

# -- the two hand-offs, recognized without configuration --------------------
#
# They are named by the protocol rather than by any one project (an
# implementer profile may not set an exec bit and may not re-pin a package
# checksum, L017), so a repository that has configured nothing must still be
# protected from them -- otherwise it learns to configure them by first losing
# the attempt this feature exists to save.
#
# RECOGNITION IS NOT A CLASSIFIER OF FAILURE TEXT, AND IT IS NOT A PROOF OF
# STATE EITHER. It is both, and each half is a veto over the other.
#
# The first rounds of this feature were text classifiers. One matched
# `: Permission denied`, `is not executable` and `checksum is stale` outright.
# The next tokenized a path out of those same sentences and corroborated it
# against the tree. Both forgave defects they should have charged, because
# every one of those sentences is something an ordinary bug prints -- a test
# that writes where it may not, a validator reporting on a file's mode, a bug
# in the repository's own pinning script.
#
# The round after them stopped reading the failure altogether and asked the
# world two closed questions instead. That was the right KIND of evidence and
# it was not enough on its own, because in this repository the answer is
# AMBIENT: nearly every `lib/*.sh`, and `scripts/pin-formula.sh`, is tracked
# mode 644 WITH a `#!` line, on purpose, because they are sourced or invoked as
# `bash <file>`. So "this candidate added a file that carries a `#!` line and
# is not executable" is simply true of any task that adds a library -- T010
# added `lib/handoff.sh` -- and the round it then waived had nothing to do with
# a mode bit. A proof that is genuinely evaluated but proves an ambient fact is
# WORSE than an over-broad sentence match, because it looks rigorous.
#
# The state question cannot be narrowed out of this either: a mode-644 `#!`
# file is exactly what a new `libexec/` verb awaiting `chmod +x` looks like
# too, and nothing on disk distinguishes the two. Only the failure can.
#
# So both halves must hold, and neither can stand in for the other:
#
#   STATE -- the hand-off's own state, proved against the world, and each
#     answer is A FILE (there is nothing to attribute a failure to otherwise):
#     exec bit  -- STAT the files this candidate ADDED, and the files it
#                  MODIFIED whose base recorded mode 755. A regular file that
#                  carries a `#!` line and has no execute permission is either
#                  a new executable shipped mode 644 or an existing one whose
#                  bit this candidate dropped -- the second is how this very
#                  task was stranded, and an added-only rule proves nothing
#                  about it. `chmod +x` is the whole fix in both, and the
#                  implementer profile may not run it (L017). Once the operator
#                  has, `-x` is true and the state is gone.
#     stale pin -- RUN the repository's package-pin freshness check
#                  (`handoff.pin_check`, defaulting to orchid's own
#                  `scripts/pin-formula.sh --check`) and require it to REPORT
#                  A FILE STALE. A nonzero exit is not that report: a check
#                  that cannot find the formula, cannot find a git checkout,
#                  or trips over packaging metadata this candidate itself
#                  corrupted exits nonzero too, and re-pinning fixes none of
#                  those. Only a staleness line naming a file the repository
#                  actually tracks establishes the hand-off, and that file is
#                  what the waiver is then attributed to. The check is only
#                  RUN AS AN AUTHORITY under `_drive_authority_intact`: what
#                  `candidate_sha` records, in the tree that was verified, or
#                  no pin route at all.
#
#   ATTRIBUTION -- that THIS failure was caused by THAT file. Being
#     outstanding is not being to blame: in this repository a mode-644 `#!`
#     file is outstanding on any candidate that adds a library, and a stale pin
#     is outstanding on the whole tree for as long as it is stale. So the
#     failure has to name the artifact, in TWO steps, because one fault does
#     not produce one failing line:
#       CAUSAL  -- at least one failing line must NAME the file and report the
#                  fault that file's hand-off IS: for the exec bit a refusal to
#                  execute it (the shell's own `<path>: Permission denied`, or
#                  a gate's `<path> is not executable`), for the pin that it is
#                  stale. This is the proof the outstanding state is what
#                  blocked THIS round, and it is what keeps the ambient case
#                  out -- a sourced mode-644 library is named by every
#                  assertion that fails inside it, and nothing ever refuses to
#                  execute it, so it is never causal and claims nothing.
#       CASCADE -- once causal, every failing line that NAMES that file is
#                  attributed to it. `runners/orchid-drive must exist and be
#                  executable` carries no refusal shape at all and is
#                  unmistakably that mode bit's failure; requiring the causal
#                  shape on every line is what made this arm inert for the
#                  116-assertion cascade it exists for.
#     The path is matched AT A BOUNDARY on both sides, never as a substring
#     (`_drive_path_named_lines`): a genuine permission failure on
#     `bin/tool-helper` is the candidate's, and an outstanding `bin/tool` must
#     not collect it.
#
# Reading the failure to ATTRIBUTE is not classifying by it: no sentence can
# make a failure a hand-off (the state must be proved against the world first),
# and no state can make an unrelated failure one (the attribution must be
# established second). Every text rule this replaces had only the second half.
#
# TWO RESIDUALS, STATED RATHER THAN HIDDEN. (1) A cascade
# line that names NEITHER the artifact nor a causal shape -- a suite that
# reports only `FAIL: case 7` -- is unclaimed and charges the round. That is
# the strict direction, and the price of not letting a proximity rule ("it
# failed near something explained") forgive whatever else broke. (2) A
# candidate whose ONLY failing lines are the hand-off's own -- a defect that
# produces no diagnostic of its own -- is still forgiven for that round. It is
# bounded: the state is one an operator clears in seconds, the round is charged
# to `infra_failures`, and a second waived round on the same task stops for a
# human instead of re-dispatching.

# _DRIVE_PIN_CHECK_DEFAULT -- the freshness check orchid ships for its own
# package pin, used when a repository declares no `handoff.pin_check` of its
# own. `none` opts out. The named script is only ever run when it is a regular
# file inside the tree that was verified AND that file states how to run it
# (see `_drive_check_interp`); anything else is simply "no pin route", which
# charges.
_DRIVE_PIN_CHECK_DEFAULT='scripts/pin-formula.sh --check'

# _drive_changed_paths <root> <base> <cand> [diff-filter] -- paths <cand>
# changed relative to <base>, one per line, optionally restricted to a
# `--diff-filter` (`A` for added). Prints nothing when either sha is missing or
# unresolvable, which charges: "I could not ask git" is not evidence of a
# hand-off.
#
# `-z` then `tr`: a path containing a newline splits into two tokens, neither
# of which will stat as a mode-644 `#!` file. That loses recognition in the
# direction that CHARGES, which is the only direction this may be wrong in.
_drive_changed_paths() {
  local root="$1" base="$2" cand="$3" filter="${4:-}"
  _drive_changed_paths_answerable "$root" "$base" "$cand" || return 0
  if [ -n "$filter" ]; then
    git -C "$root" diff -z --name-only "--diff-filter=$filter" "$base" "$cand" 2>/dev/null | tr '\0' '\n'
  else
    git -C "$root" diff -z --name-only "$base" "$cand" 2>/dev/null | tr '\0' '\n'
  fi
}

# _drive_changed_paths_answerable <root> <base> <cand> -- 0 when git can be
# asked what this candidate changed at all: both shas recorded, both resolving
# to commits in a tree that is there.
#
# SPLIT OUT OF `_drive_changed_paths` BECAUSE THE EMPTY ANSWER IS AMBIGUOUS,
# and the two readings of it point opposite ways. "git says this candidate
# changed nothing" and "I could not ask git" are the same empty list, and a
# caller that treats the list as the whole answer silently picks one of them.
# Which one is safe depends entirely on what the caller does next -- see
# `_drive_candidate_changed`.
_drive_changed_paths_answerable() {
  local root="$1" base="$2" cand="$3"
  [ -n "$base" ] && [ -n "$cand" ] || return 1
  [ -d "$root" ] || return 1
  git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse -q --verify "$cand^{commit}" >/dev/null 2>&1 || return 1
  return 0
}

# _drive_candidate_changed <root> <base> <cand> <path> -- 0 when this candidate
# changed <path>, AND ALSO when that question cannot be answered.
#
# THIS IS THE AUTHORITY GUARD, AND IT IS THE ONE PLACE IN THIS FILE WHERE AN
# UNANSWERABLE QUESTION MUST READ AS *YES*. Every other proof here charges when
# git cannot be asked, because it is asking git to establish a hand-off and an
# unanswered question is no evidence. These two callers ask the inverse: they
# have already found an authority in the tree -- a freshness check, a
# known-flaky register -- and they are asking whether the candidate is allowed
# to be judged by it. "I could not ask git" is not permission.
#
# The direction matters because both routes are the ones an implementer could
# otherwise buy an amnesty from. A task file with no `base_sha`, a `base_sha`
# that names a commit this tree does not carry, a `worktree` that has been
# taken away -- each of them made `_drive_changed_paths` print an empty list,
# which the callers read as "the candidate did not touch it", which reopened
# the route over a register or a pin check the candidate may well have written.
# The failure was silent in exactly the case a guard exists for.
_drive_candidate_changed() {
  local root="$1" base="$2" cand="$3" want="$4" p
  # Unanswerable: fail closed. The route is lost and the round charges.
  _drive_changed_paths_answerable "$root" "$base" "$cand" || return 0
  while IFS= read -r p; do
    [ "$p" = "$want" ] || continue
    return 0
  done < <(_drive_changed_paths "$root" "$base" "$cand")
  return 1
}

# _drive_blob_mode <root> <rev> <rel> -- the mode <rev> records for <rel>, when
# <rev> resolves and carries <rel> as an ordinary file. Nonzero for anything
# else: a rev this tree does not have, a path it does not carry, and a symlink
# or a gitlink, none of which is a file orchid may run or read as an authority.
#
# Plain `ls-tree`, not `--format=%(objectmode)`, which needs git 2.36: the mode
# is the first field of the default `<mode> <type> <sha>\t<path>` line in every
# git that has ever shipped the verb.
_drive_blob_mode() {
  local root="$1" rev="$2" rel="$3" line mode
  [ -n "$rev" ] || return 1
  git -C "$root" rev-parse -q --verify "$rev^{commit}" >/dev/null 2>&1 || return 1
  line="$(git -C "$root" ls-tree "$rev" -- "$rel" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  mode="${line%% *}"
  case "$mode" in 100644|100755) ;; *) return 1 ;; esac
  printf '%s' "$mode"
}

# _drive_authority_intact <root> <base> <cand> <rel> -- 0 only when <rel> may be
# read as an AUTHORITY ON THIS CANDIDATE: a freshness check orchid will run, or
# a known-flaky register orchid will believe.
#
# UNTOUCHED ACROSS `base..candidate` IS NOT ENOUGH, and that is what this
# function exists to say. A diff of two commits answers a question about two
# COMMITS, and what the driver actually runs and reads is the FILE IN THE
# WORKTREE THE VERIFICATION RAN IN. Those come apart in every direction that
# matters, and each of them was open:
#
#   NOT IN THE CANDIDATE AT ALL -- an untracked `scripts/pin-formula.sh`
#     dropped into the worktree is in no diff, so it was "untouched", and it
#     was also entirely the implementer's to write.
#   TRACKED BUT DIRTY -- an edit left unstaged, or staged and not committed, is
#     in no `base..candidate` diff either. The check that RUNS is the edited
#     one; the register that is READ is the edited one.
#   MISSING, OR NOT A FILE -- deleted from the worktree after the commit, or
#     replaced by a symlink pointing somewhere else entirely.
#
# So the authority must be the same bytes and the same mode the candidate
# RECORDED, in the tree that was verified. Everything is proved against
# `candidate_sha` itself rather than against `HEAD`: the recorded candidate is
# what the round is about, and a worktree whose HEAD has moved on is not
# evidence about it either way.
#
# Unanswerable anywhere -- no shas, a sha this tree does not carry, a git that
# will not answer -- closes the route, which charges. That is the same
# direction every other proof here leans in, and on this route it is the one
# that matters most: these are the two files an implementer could otherwise
# write its own amnesty into.
_drive_authority_intact() {
  local root="$1" base="$2" cand="$3" rel="$4" abs mode
  [ -n "$rel" ] || return 1
  # Inside the verified tree only, so `candidate_sha` can be asked about it.
  case "$rel" in /*|*..*) return 1 ;; esac
  [ -d "$root" ] || return 1
  # A check or a register THIS CANDIDATE CHANGED is no authority on it -- and
  # nor is one where that could not be established at all.
  if _drive_candidate_changed "$root" "$base" "$cand" "$rel"; then return 1; fi
  # Carried by the recorded candidate itself, as an ordinary file. Assigned on
  # its own line, never as `local mode="$(...)"`, which would swallow the
  mode="$(_drive_blob_mode "$root" "$cand" "$rel")" || return 1
  abs="$root/$rel"
  [ -f "$abs" ] || return 1
  [ ! -L "$abs" ] || return 1
  # The mode, read off the filesystem rather than off git's record, because the
  # exec bit is what decides HOW the pin check is invoked. A repository with
  # `core.fileMode` off reports no mode change here, so this is asked directly.
  if [ "$mode" = 100755 ]; then
    [ -x "$abs" ] || return 1
  else
    [ ! -x "$abs" ] || return 1
  fi
  # And the bytes, both ends: the worktree against the candidate commit, and
  # the index against it too. Porcelain `git diff` rather than `diff-index`
  # plumbing, because it refreshes the index first -- plumbing reports a
  # stat-dirty entry as a modification and would close the route on a file
  # nobody had touched. The `--cached` half is not redundant: a change staged
  # and then reverted in the worktree leaves the first half quiet.
  git -C "$root" diff --quiet "$cand" -- "$rel" 2>/dev/null || return 1
  git -C "$root" diff --cached --quiet "$cand" -- "$rel" 2>/dev/null || return 1
  return 0
}

# _drive_exec_bit_missing <path> -- 0 when <path> is in exactly the state the
# exec-bit hand-off leaves behind: a regular file that is NOT executable and
# that carries a `#!` line, so it is unambiguously meant to be run and
# `chmod +x` is the whole fix. That conjunction cannot be produced by a defect
# in the candidate's CONTENT, and the implementer profile may not clear it
# (L017). Once the operator has, `-x` is true and the identical failure charges
# again.
_drive_exec_bit_missing() {
  local p="$1" first
  [ -f "$p" ] || return 1
  [ ! -x "$p" ] || return 1
  # `head -n 1` over a REDIRECT, rather than `read` and rather than passing the
  # path as an argument: `read` reports failure on a final line with no
  # terminating newline while still having ASSIGNED it -- a one-line stub is
  # exactly that shape -- and a path argument beginning with `-` would be taken
  # for an option.
  first="$(head -n 1 < "$p" 2>/dev/null || true)"
  case "$first" in '#!'*) return 0 ;; esac
  return 1
}

# _drive_exec_bit_dropped <root> <base> <path> -- 0 when <base> recorded <path>
# as mode 100755, so a candidate that now leaves it mode 644 has DROPPED an
# exec bit rather than never having set one.
#
# git's record, never the worktree: the question is what changed ACROSS this
# candidate, and only the base tree can answer it. A path <base> does not carry
# at all, or carries as anything but 100755, answers no -- which charges.
_drive_exec_bit_dropped() {
  local root="$1" base="$2" p="$3" line
  [ -n "$base" ] || return 1
  # Plain `ls-tree`, not `--format=%(objectmode)`, which needs git 2.36: the
  # mode is the first field of the default `<mode> <type> <sha>\t<path>` line
  # in every git that has ever shipped this verb.
  line="$(git -C "$root" ls-tree "$base" -- "$p" 2>/dev/null || true)"
  [ -n "$line" ] || return 1
  [ "${line%% *}" = 100755 ] || return 1
  return 0
}

# drive_handoff_exec_bit <root> <task-file> -- every relative path that carries
# a `#!` line, is not executable, and is one THIS CANDIDATE is answerable for
# being that way, one per line. Nothing when there is none.
#
# A mode bit goes missing two ways, and both are the same hand-off:
#
#   ADDED   -- a file this candidate introduced, at mode 644. It is new, so no
#              standing convention of the repository's put it at that mode.
#   DROPPED -- a file this candidate MODIFIED that `base_sha` recorded mode
#              755. The bit was there, this candidate's rewrite lost it, and
#              `chmod +x` is again the whole fix and again the operator's (an
#              implementer profile may not run it, L017).
#
# THE SECOND SHAPE IS NOT HYPOTHETICAL: it is how this very task was stranded.
# `runners/orchid-drive` was tracked 100755, an implementer round rewrote it,
# the mode came back 100644, and every drive invocation in its own suite
# returned 126 with 116 assertions cascading from that one cause. The file was
# MODIFIED, never added, so an added-only rule proves no state for it and the
# round classifies as `candidate` -- orchid charging an attempt for precisely
# the hand-off this function exists to recognize. It is a shape rather than an
# incident: any engine whose file writes recreate a file at 0644 does this to
# every executable it touches.
#
# Both shapes still require `_drive_exec_bit_missing`, and neither is merely
# PRESENT: a mode-644 `#!` file that has sat in the tree for a year is nobody's
# outstanding hand-off, and treating it as one would forgive every failure that
# repository ever produces. The set comes from git rather than from the failure
# output, so no wording is involved on either side -- and being outstanding is
# still not being to blame, which is attribution's question, below.
#
# ALL of them, not the first: a candidate that adds both a sourced library (at
# this repository's usual mode 644) and a new verb genuinely awaiting
# `chmod +x` has two, git orders them alphabetically, and stopping at the first
# would hand attribution a path the failure says nothing about while the one it
# DOES name went unexamined. Which of them a failure blames is attribution's
# question, and it cannot answer it about a path it was never given.
drive_handoff_exec_bit() {
  local root="$1" tf="$2" p base cand
  base="$(fm_get "$tf" base_sha)"
  cand="$(fm_get "$tf" candidate_sha)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _drive_exec_bit_missing "$root/$p" || continue
    printf '%s\n' "$p"
  done < <(_drive_changed_paths "$root" "$base" "$cand" A)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _drive_exec_bit_missing "$root/$p" || continue
    _drive_exec_bit_dropped "$root" "$base" "$p" || continue
    printf '%s\n' "$p"
  done < <(_drive_changed_paths "$root" "$base" "$cand" M)
  return 0
}

# _drive_check_interp <path> -- how to invoke the freshness check at <path>,
# printed as the interpreter prefix its own `#!` line names, empty when <path>
# is executable and needs none. Returns nonzero when there is no way to run it
# that the FILE ITSELF states -- which is no pin route, which charges.
#
# The exec bit is the repository's convention to set, not orchid's to require.
# Requiring it made the built-in route dead in the repository that ships the
# default: orchid's own `scripts/pin-formula.sh` is tracked mode 644 and is
# invoked as `bash scripts/pin-formula.sh --check` everywhere it runs, so a
# stale pin -- T014's case, the whole reason this route exists -- classified as
# `candidate` here with no configuration able to fix it, because the shipped
# default could not be run at all. Reading the `#!` line runs it exactly as its
# own repository does.
#
# Still narrow, and narrow in the charging direction: the interpreter comes
# from the file rather than from a guess (no defaulting to `sh` for a file that
# names nothing), and it must exist and be executable, so an unrunnable check
# stays "no pin route" rather than becoming a nonzero exit read as staleness.
# This is not a new trust boundary either -- the driver already runs this
# repository's entire verification command line, and the path is config-named
# with a default that must exist in the verified tree before anything is run.
_drive_check_interp() {
  local abs="$1" first
  local -a words=()
  [ -f "$abs" ] || return 1
  # Executable as it stands: run it directly, no prefix. This is the branch a
  # repository whose checks carry the exec bit takes.
  [ ! -x "$abs" ] || return 0
  # `head -n 1` over a redirect for the same reason `_drive_exec_bit_missing`
  # uses one: a path beginning with `-` would otherwise be taken for an option.
  first="$(head -n 1 < "$abs" 2>/dev/null || true)"
  case "$first" in '#!'*) ;; *) return 1 ;; esac
  read -r -a words <<< "${first#\#!}"
  # `${words[0]:-}` rather than `${#words[@]}`: bash 3.2 -- the /bin/bash this
  # project's own verification runs under -- is unforgiving about empty-array
  # references under `set -u`, and a `#!` line with nothing after it is exactly
  # that case.
  [ -n "${words[0]:-}" ] || return 1
  [ -x "${words[0]}" ] || return 1
  printf '%s' "${words[*]}"
}

# _DRIVE_PIN_STALE_RE -- a line saying something IS STALE. A whole word,
# bounded on both sides, so `stalemate` and `installed` are not staleness
# reports.
#
# This is the one sentence orchid asks a freshness check to write, and it is
# asked in the CHARGING direction: a check that reports staleness in words
# orchid cannot read forgives nothing, exactly as a check that cannot be run
# forgives nothing. It is not a rule for spotting hand-offs in a verification's
# output -- the state has to be proved by RUNNING the check first, and the same
# word in a verify log establishes nothing on its own.
_DRIVE_PIN_STALE_RE='(^|[^[:alnum:]_])[Ss][Tt][Aa][Ll][Ee]([^[:alnum:]_]|$)'

# _drive_strip_punct <token> -- <token> with the punctuation a sentence wraps
# around a path taken off both ends, ONE CHARACTER AT A TIME.
#
# A bracket-class strip (`${tok%[...]}`) removes at most one member, so a
# quoted path followed by a colon keeps that colon and never opens; and
# spelling `\`, `[` and `]` inside a case bracket-class is a puzzle whose wrong
# answers are silent. A trailing `.` comes off too -- a sentence may end on the
# path -- which is safe because every caller still has to find what is left in
# the tree before it means anything.
#
# Shared by the pin route (which then requires a file git tracks) and the
# missing-build-state route (which then requires an entry point inside the
# absent directory), so a path a diagnostic quotes, backticks or wraps in
# angle brackets opens the same way for both.
#
# THE ANSWER IS LEFT IN A GLOBAL, and `_drive_strip_punct` is the printing
# wrapper. That is not a style choice: the missing-build-state route tokenizes
# every resolution-shaped line of a verification log, and `$(...)` per token is
# a FORK per token. On a suite that printed thousands of lines the wrapper
# alone is the difference between classifying a failure and appearing to hang
# at the one moment the run is already going badly.
_DRIVE_TOK=''
_drive_strip_punct_into() {
  local tok="$1"
  while [ -n "$tok" ]; do
    case "$tok" in
      \'*|\"*|\`*|\(*|\[*|\<*|,*|:*|\;*) tok="${tok#?}"; continue ;;
    esac
    case "$tok" in
      *\'|*\"|*\`|*\)|*\]|*\>|*,|*:|*\;|*.) tok="${tok%?}"; continue ;;
    esac
    break
  done
  _DRIVE_TOK="$tok"
}
_drive_strip_punct() {
  _drive_strip_punct_into "$1"
  printf '%s' "$_DRIVE_TOK"
}

# _drive_pin_stale_path <root> <check-output> -- the file the check REPORTS
# STALE: a token on one of its staleness lines that is a regular file git
# tracks in <root>. Nothing when the check said no such thing, which charges.
#
# THIS IS THE DIFFERENCE BETWEEN "THE PIN IS STALE" AND "THE CHECK FAILED",
# and an exit status cannot draw it. `scripts/pin-formula.sh` exits 1 when the
# recorded checksum is stale AND when it cannot find the formula, cannot find a
# git checkout, or trips over packaging metadata this candidate itself
# corrupted -- and re-pinning fixes only the first. Reading a nonzero exit as
# staleness therefore handed an operator hand-off's amnesty to a whole class of
# candidate defect.
#
# The FILE is required as well as the word, for two reasons that are really
# one: a waiver must be attributable to something, and a token that names a
# file the repository tracks is a fact rather than a reading. A check that says
# "the pin is stale" and names nothing proves nothing this can act on.
_drive_pin_stale_path() {
  local root="$1" out="$2" line tok i
  local -a words=()
  [ -n "$out" ] || return 0
  [ -d "$root" ] || return 0
  while IFS= read -r line; do
    grep -Eq -- "$_DRIVE_PIN_STALE_RE" <<< "$line" || continue
    # `read -r -a` rather than an unquoted `for tok in $line`: word splitting
    # there also GLOBS, so a check that printed a `*` would expand it against
    # the driver's working directory and hand this loop filenames the check
    # never mentioned.
    words=()
    read -r -a words <<< "$line"
    i=0
    while [ -n "${words[i]:-}" ]; do
      tok="$(_drive_strip_punct "${words[i]}")"
      i=$((i + 1))
      [ -n "$tok" ] || continue
      # Never a token git could read as an option, and never an absolute path:
      # the answer has to be a path INSIDE the tree that was verified, because
      # that is the only thing `ls-files` can confirm and the only thing an
      # operator's re-pin acts on.
      case "$tok" in -*|/*) continue ;; esac
      [ -f "$root/$tok" ] || continue
      git -C "$root" ls-files --error-unmatch -- "$tok" >/dev/null 2>&1 || continue
      printf '%s' "$tok"
      return 0
    done
  done <<< "$out"
  return 0
}

# drive_handoff_stale_pin <repo> <root> <task-file> -- when running the
# repository's freshness check in <root> proves a recorded package checksum
# stale right now: the check's command line on the FIRST line, and the file it
# reported stale on the second. Nothing otherwise.
#
# Two values because the caller needs both: the command line is what an
# operator re-runs, and the file is what the waiver is attributed to.
#
# Running a repository's own script is not a new trust boundary: the driver
# already executes that repository's entire verification command line, and this
# one is named by config with a default that must exist in the verified tree,
# and must state how it is run, before it is invoked at all
# (`_drive_check_interp`).
#
# One narrowing matters, and it is the hole the text-matching rounds left open:
# a check the CANDIDATE CHANGED is not an authority on the candidate. A bug the
# implementer just introduced into the pinning script fails exactly like a
# stale pin, and forgiving that would hand straight back the amnesty this
# rewrite withdrew. So a touched check yields no pin route, and charges.
#
# ONE RESIDUAL, STATED RATHER THAN HIDDEN: this runs on every FAILED verify in
# a repository that has such a check, and the shipped default builds a release
# archive -- a few seconds, paid only on a failure, after a verification run
# that cost far more.
drive_handoff_stale_pin() {
  local repo="$1" root="$2" tf="$3" cmd script abs rc interp out path
  local -a parts=() pre=()
  cmd="$(config_get "$repo" handoff.pin_check "$_DRIVE_PIN_CHECK_DEFAULT")"
  [ -n "$cmd" ] || return 0
  [ "$cmd" != none ] || return 0
  read -r -a parts <<< "$cmd"
  script="${parts[0]:-}"
  [ -n "$script" ] || return 0
  # Inside the verified tree, always. A check somewhere else on the machine is
  # a file `candidate_sha` records nothing about, so nothing can establish that
  # it is an authority on this candidate -- and the authority guard below would
  # close the route on it anyway. Refused here so the reason is the path rather
  # than a failed comparison.
  case "$script" in /*|*..*) return 0 ;; esac
  abs="$root/$script"
  # Assigned on its own line, never as `local interp="$(...)"`, which would
  # swallow the status this branch turns on.
  interp="$(_drive_check_interp "$abs")" || return 0
  # A check this candidate changed is no authority on this candidate -- nor is
  # one the candidate never recorded, nor one the verified worktree carries in
  # any state but the one the candidate recorded, nor one where any of that
  # could not be established at all. `_drive_authority_intact` is the whole of
  # that question, and every unanswerable form of it closes the route.
  _drive_authority_intact "$root" \
    "$(fm_get "$tf" base_sha)" "$(fm_get "$tf" candidate_sha)" "$script" \
    || return 0
  # `set --` then `shift`, rather than the array slice `"${parts[@]:1}"`: on a
  # one-word command line that slice is an EMPTY array reference, which bash
  # 3.2 -- the /bin/bash this project's own verification runs under -- treats
  # as an unbound variable under `set -u`. `"$@"` is safe empty in every bash.
  set -- "${parts[@]}"
  shift
  rc=0
  out=""
  if [ -n "$interp" ]; then
    read -r -a pre <<< "$interp"
    out="$( cd "$root" && "${pre[@]}" "$abs" "$@" 2>&1 )" || rc=$?
  else
    out="$( cd "$root" && "$abs" "$@" 2>&1 )" || rc=$?
  fi
  # BOTH are required, and they answer different questions. The exit status
  # says the check is unhappy; only its words say a pin is STALE, which is the
  # one unhappiness an operator's re-pin fixes.
  [ "$rc" -ne 0 ] || return 0
  path="$(_drive_pin_stale_path "$root" "$out")"
  [ -n "$path" ] || return 0
  printf '%s\n%s' "$cmd" "$path"
}

# -- attribution: from "outstanding" to "to blame" --------------------------

# _DRIVE_EXEC_REFUSAL_RE -- a line saying something could not be EXECUTED.
# Only ever matched together with the artifact's own path, because on its own
# each of these is a sentence an ordinary defect prints.
_DRIVE_EXEC_REFUSAL_RE='[Pp]ermission denied|[Nn]ot executable|[Cc]annot execute|[Cc]ould not execute|[Nn]ot marked executable|[Ee]xec format error'

# _DRIVE_RESOLUTION_RE -- a line saying something could not be RESOLVED. The
# environment arm later requires the named subject to live inside a directory
# proved missing; here the same diagnostic shapes belong to the round's
# FAILURE universe whether or not that attribution succeeds. Otherwise an
# attributable hand-off beside `missing-helper: command not found` can make the
# second, unexplained failure invisible and waive the candidate's round.
_DRIVE_RESOLUTION_RE='[Nn]ot found|[Nn]o such file or directory|[Cc]annot find (module|package)|ModuleNotFoundError|ImportError|ENOENT|[Cc]ould not resolve|[Uu]nable to resolve|[Cc]annot open'

# _DRIVE_FATAL_RE -- fatal diagnostics that do not need a harness's `FAIL:` or
# `error:` prefix to be verdicts. Keep word boundaries around the prose forms:
# this repository legitimately runs files such as `test_panic_recovery.sh` and
# prints counters such as `fatal_errors: 0`, neither of which is a panic or a
# fatal exit. Language exception names end in `Error:` or `Exception:` and are
# admitted only as one token, which covers `RuntimeError:` and
# `java.lang.IllegalStateException:` without matching ordinary "error
# handling" prose.
_DRIVE_FATAL_RE='(^|[^[:alnum:]_])([Pp][Aa][Nn][Ii][Cc]([Kk][Ee][Dd])?|[Ff][Aa][Tt][Aa][Ll]|[Ss]egmentation fault|[Aa]bort trap|[Bb]us error|[Ii]llegal instruction|[Ss]yntax error|[Uu]ndefined reference|[Uu]nhandled exception|[Uu]nhandled rejection|[Ss]tack overflow|[Oo]ut of memory)([^[:alnum:]_]|$)|(^|[[:space:]])[[:alnum:]_.]*(Error|Exception):|UnhandledPromiseRejection'

# _DRIVE_FAILURE_LINE_RE -- what a line REPORTING a failure looks like, across
# the harnesses a repository is likely to run. Used for one question only: does
# this round contain failures the hand-off does not account for?
#
# The two directions are not symmetric, and this leans the way the rest of the
# classifier does. TOO NARROW is the dangerous one: a defect whose diagnostic
# goes unseen beside an attributed hand-off is laundered, which is the whole
# failure mode this rewrite exists to close -- so the exec refusals are in here
# too (an unexplained `Permission denied` about some OTHER path is a failure
# this round must be charged for), and so are the lower-case `failed`/`failure`
# a python or node harness prints. TOO BROAD only costs waivers, but it costs
# ALL of them: a shape that matches a line of ordinary progress output leaves
# every round with an unexplained failure and nothing is ever waived again.
# That is why whole words bounded on both sides, never a bare `fail` -- this
# repository's own runner prints `== tests/test_failover.sh` for every file it
# runs, and `orchid status` prints `infra_failures:`, and the leading bound
# excludes `_` precisely so that second one stays a counter rather than a
# failure -- and why `error` counts only with its colon, since "error handling"
# is prose and `error:` is a compiler. Resolution refusals are different:
# `command not found`, `ENOENT`, `Cannot find module`, `panic:`, and language
# exceptions are verdicts even without a harness prefix, and must be visible
# before any waiver is considered.
_DRIVE_FAILURE_LINE_RE="(^|[^[:alnum:]_])(FAIL|FAILED|FAILURE|FAILURES|ERROR|[Ff]ailed|[Ff]ailure|[Ff]ailures)([^[:alnum:]_]|\$)|(^|[^[:alnum:]_])[Ee]rror:|^not ok |[Aa]ssertion(Error| failed)|Traceback \\(most recent call last\\)|$_DRIVE_EXEC_REFUSAL_RE|$_DRIVE_RESOLUTION_RE|$_DRIVE_FATAL_RE"

# _DRIVE_PROGRESS_LINE_RE -- lines that affirm progress, success, or an
# explicitly neutral not-tested claim rather than diagnose a failed command.
# This is intentionally a CLOSED vocabulary. Once verify exits non-zero, a
# non-empty line that is neither a reported failure above nor one of these
# explicit non-failure records is uncertain evidence and therefore charges the
# attempt. That is the only fail-closed answer possible for an unfamiliar
# harness: extending a failure regex whenever a new spelling is discovered
# always leaves the next spelling able to disappear beside an attributable
# hand-off.
#
# A progress line has to say something structurally positive: a suite heading,
# TAP success/plan/comment, a PASS or terminal standalone `OK` marker, Orchid's
# state-transition/attempt trace, a RED/GREEN demonstration record, a zero
# failure/error counter, an ordinary named coverage counter, or a sentence
# ending in one of the two success forms the shipped tests use. Orchid's two
# NOT-TESTED records are neutral by contract: they explicitly say a claim was
# not made, rather than reporting either a pass or a failure. The shipped suite
# runner's ORCHID-VERIFY-SEGMENT records are structural evidence, not claims
# about a diagnostic; drive_failure_lines separately trusts a segment's body
# only after the matching END 0 record proves that exact test returned zero.
# A bare diagnostic such as `widget went sideways` is not progress merely
# because no known failure word appears in it.
_DRIVE_PROGRESS_LINE_RE='^[[:space:]]*$|^[[:space:]]*==([[:space:]]|$)|^[[:space:]]*---[[:space:]]*$|^[[:space:]]*(CI )?PASS([:[:space:]].*)?$|^[[:space:]]*[^[:space:]].*[[:space:]]OK[[:space:]]*$|^[[:space:]]*NOT-TESTED:[[:space:]]+.+ -- .+$|^[[:space:]]*not-tested:[[:space:]]+[0-9]+ claim[(]s[)] in this file were recorded as not-tested, never as passes[[:space:]]*$|^[[:space:]]*ok([[:space:]][0-9]+)?([[:space:]]+-.*)?$|^[[:space:]]*[0-9]+\.\.[0-9]+([[:space:]]*#.*)?$|^[[:space:]]*#[[:space:]]*(Subtest:|tests[[:space:]][0-9]+|suites[[:space:]][0-9]+|pass[[:space:]][0-9]+|fail[[:space:]]0|cancelled[[:space:]]0|skipped[[:space:]][0-9]+|todo[[:space:]][0-9]+|duration_ms[[:space:]][0-9.]+|SKIP([[:space:]]|$)|TODO([[:space:]]|$)).*$|^[[:space:]]*(RED-CASE|GREEN-CASE|red-cases):.*$|^[[:space:]]*[[:alnum:]_.-]+_(cases|count):[[:space:]]*[0-9]+[[:space:]]*$|^[[:space:]]*[[:alnum:]_.-]+_(failures|errors):[[:space:]]*0([[:space:]].*)?$|^[[:space:]]*[A-Z][[:alnum:]_-]*[0-9][[:alnum:]_-]*:[[:space:]]+[[:alnum:]_-]+[[:space:]]+->[[:space:]]+[[:alnum:]_-]+[[:space:]]*$|^[[:space:]]*[A-Z][[:alnum:]_-]*[0-9][[:alnum:]_-]*:[[:space:]]+(guidance delivered to the task body|attempt budget unchanged at [0-9]+|infra_failures [0-9]+/[0-9]+).*$|^[[:space:]]*ORCHID-VERIFY-SEGMENT[[:space:]]+[[:alnum:]_.:-]+[[:space:]]+(BEGIN([[:space:]].*)?|END[[:space:]]+[0-9]+)[[:space:]]*$|^[[:space:]]*.*(coverage complete|cases passed)[[:space:]]*$'

# _DRIVE_QUOTE_MAX -- how much of an evidence line a journal reason quotes.
_DRIVE_QUOTE_MAX=120

# _drive_quote_line <text> -- the first line of <text>, trimmed and clipped, for
# quoting as evidence inside a one-line `--reason`.
#
# Parameter expansion rather than `head -n 1`: under `pipefail` a `head` that
# closes the pipe early makes the assignment exit non-zero, and this library is
# sourced into a `set -e` driver, where that is a pass that dies mid-round
# instead of a reason that is a little long.
_drive_quote_line() {
  local s="${1%%$'\n'*}" edge
  # Two steps per trim, with the whitespace run captured into its own variable
  # first: the same spelling libexec/orchid-start uses, and the one this
  # project's lint gate is known to accept.
  edge="${s%%[![:space:]]*}"; s="${s#"$edge"}"
  edge="${s##*[![:space:]]}"; s="${s%"$edge"}"
  [ "${#s}" -le "$_DRIVE_QUOTE_MAX" ] || s="${s:0:$_DRIVE_QUOTE_MAX}..."
  printf '%s' "$s"
}

# drive_reported_failure_lines <body> -- lines whose own syntax reports a
# failure. Only these may join a causal artifact's same-file cascade: an
# UNKNOWN line always remains unattributed, even if it happens to name the
# artifact, because naming cannot turn uncertainty into proof of causation.
drive_reported_failure_lines() {
  [ -n "$1" ] || return 0
  grep -E -- "$_DRIVE_FAILURE_LINE_RE" <<< "$1" || true
}

# drive_failure_lines <body> -- every line that must be accounted for before a
# failed verification may be waived. Reported failures are included directly;
# explicit progress/success/neutral records are excluded; everything else is
# uncertain and included in the strict, charging direction. Preserve input
# order so a charged journal reason quotes the first unexplained diagnostic the
# operator actually saw.
drive_failure_lines() {
  local out
  [ -n "$1" ] || return 0
  # Pass the patterns through the environment rather than awk -v: backslashes
  # in -v string values are interpreted a second time by awk, which silently
  # changes EREs such as the literal opening parenthesis in `Traceback (`.
  out="$(ORCHID_DRIVE_FAILURE_RE="$_DRIVE_FAILURE_LINE_RE" \
    ORCHID_DRIVE_PROGRESS_RE="$_DRIVE_PROGRESS_LINE_RE" \
    awk '
      {
        line[NR] = $0
        marker = $0
        sub(/^[[:space:]]*/, "", marker)
        fields_n = split(marker, fields, /[[:space:]]+/)
        if (fields_n >= 3 && fields[1] == "ORCHID-VERIFY-SEGMENT" &&
            fields[2] ~ /^[[:alnum:]_.:-]+$/) {
          token = fields[2]
          if (fields[3] == "BEGIN") {
            segment_begin[token] = NR
          } else if (fields_n == 4 && fields[3] == "END" &&
                     fields[4] == "0" && (token in segment_begin)) {
            # A zero result proves every line in this exact invocation was
            # fixture/progress output, even when the test deliberately printed
            # scary diagnostics while exercising a negative case. Keep failed
            # and incomplete segments untouched. Difference counters make
            # nested suite runs work without an O(lines * segments) scan.
            hidden_delta[segment_begin[token]]++
            hidden_delta[NR + 1]--
            delete segment_begin[token]
          }
        }
      }
      END {
        hidden = 0
        for (i = 1; i <= NR; i++) {
          hidden += hidden_delta[i]
          if (hidden > 0) continue
          if (line[i] ~ ENVIRON["ORCHID_DRIVE_FAILURE_RE"]) {
            print line[i]
            continue
          }
          if (line[i] ~ ENVIRON["ORCHID_DRIVE_PROGRESS_RE"]) continue
          print line[i]
        }
      }
    ' <<< "$1")"
  [ -z "$out" ] || printf '%s\n' "$out"
}

# _drive_ere_escape <text> -- <text> with every ERE metacharacter backslashed.
# A path is spliced into a pattern below and must match only itself:
# `lib-two-a.sh`'s dot would otherwise match any character at all, and the one
# thing this whole section turns on is a path matching exactly.
#
# The membership test is a prefix strip, not a `case`: spelling a literal `\`,
# `[` and `]` inside a case bracket-class is a puzzle whose wrong answers are
# silent, and the inverse -- the metacharacter set as the case WORD -- is a
# constant word that the lint gate reads as a forgotten `$` (SC2194). Stripping
# instead keeps the character quoted, so it matches only itself, and the whole
# question is `did anything come off?`.
_DRIVE_ERE_META='\.^()[]{}*+?|$'
_drive_ere_escape() {
  local s="$1" out="" i=0 c
  while [ "$i" -lt "${#s}" ]; do
    c="${s:i:1}"
    if [ "${_DRIVE_ERE_META%%"$c"*}" != "$_DRIVE_ERE_META" ]; then
      out="$out\\$c"
    else
      out="$out$c"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# _DRIVE_PATH_EXACT_LEAD / _DRIVE_PATH_TAIL -- what must sit on either side of
# a path for a line to have NAMED it rather than merely contained it.
#
# THE SUBSTRING VERSION OF THIS WAS A REAL HOLE: with `bin/tool` awaiting
# `chmod +x`, a genuine `bin/tool-helper: Permission denied` -- the candidate's
# own defect, on a different file -- was attributed to the hand-off and the
# round waived. A later boundary-only version still admitted any `/` before
# the relative path, so `fixtures/bin/tool` could claim the same hand-off by
# suffix. Identity is therefore explicit: the repository-relative spelling,
# its `./` spelling, or the exact verification-root absolute spelling. A `/`
# cannot lead the first two; it is part of the third spelling itself.
#
# `.` is excluded on the trailing side too, which costs a match on a diagnostic
# that ends its sentence with `bin/tool.` -- deliberately, since including it
# would let `bin/tool` claim `bin/tool.bak`. That loss is in the direction that
# CHARGES, the only direction an error here may fall in.
_DRIVE_PATH_EXACT_LEAD='(^|[^[:alnum:]._/-])'
_DRIVE_PATH_TAIL='([^[:alnum:]._/-]|$)'

# _drive_path_identity_ere <path> <root> -- an ERE matching only the three
# spellings that identify <path>. Empty <root> deliberately loses the absolute
# spelling in the fail-strict direction; production callers always know the
# verification root, while focused callers that use only relative diagnostics
# need not invent one.
_drive_path_identity_ere() {
  local p="$1" root="$2" esc forms abs
  [ -n "$p" ] || return 0
  esc="$(_drive_ere_escape "$p")"
  forms="$esc|\\./$esc"
  if [ -n "$root" ]; then
    case "$root" in
      /) abs="/$p" ;;
      *) abs="${root%/}/$p" ;;
    esac
    forms="$forms|$(_drive_ere_escape "$abs")"
  fi
  printf '%s(%s)' "$_DRIVE_PATH_EXACT_LEAD" "$forms"
}

# _drive_path_named_lines <path> <root> <body> -- the lines of <body> that name
# <path> by exact relative, ./-relative, or verification-root absolute
# identity, one per line.
_drive_path_named_lines() {
  local p="$1" root="$2" body="$3" identity
  [ -n "$p" ] && [ -n "$body" ] || return 0
  identity="$(_drive_path_identity_ere "$p" "$root")"
  [ -n "$identity" ] || return 0
  grep -E -- "$identity$_DRIVE_PATH_TAIL" <<< "$body" || true
}

# _drive_artifact_causal <path> <causal-ere> <body> [root] -- the lines of
# <body> that identify <path> AND report the fault its hand-off is. Non-empty
# is the proof that this outstanding state is what blocked THIS run.
#
# Both halves on the SAME line, always: naming alone is what every assertion
# inside a newly added file does, and a causal shape alone is what a candidate
# writing where it may not prints about some other path entirely.
_drive_artifact_causal() {
  local p="$1" re="$2" body="$3" root="${4:-}"
  [ -n "$p" ] && [ -n "$body" ] || return 0
  _drive_path_named_lines "$p" "$root" "$body" | grep -E -- "$re" || true
}

# _drive_artifact_attribution <path> <causal-ere> <body> [root] -- the lines of
# <body> this artifact is answerable for, one per line. Empty means this
# failure is not attributable to it.
#
# Causal first, then the cascade it caused. One fault does not fail one check:
# the shell refuses a file once and every check that needed it reports in its
# own words, so `runners/orchid-drive must exist and be executable` -- no
# refusal shape anywhere in it -- is as much that mode bit's failure as the
# `Permission denied` two lines above. Claiming only the causal lines left the
# other hundred lines of the cascade unexplained, and an arm that only fires
# when the round contains nothing else can never fire when it matters.
#
# The causal proof is what stops that from being a naming rule: without a line
# that both names the artifact and reports its fault, nothing is claimed at all.
_drive_artifact_attribution() {
  local p="$1" re="$2" body="$3" root="${4:-}"
  [ -n "$p" ] && [ -n "$body" ] || return 0
  [ -n "$(_drive_artifact_causal "$p" "$re" "$body" "$root")" ] || return 0
  _drive_path_named_lines "$p" "$root" "$(drive_reported_failure_lines "$body")"
}

# The two artifacts, each with the fault its own hand-off IS. Named functions
# rather than a regex argument at the call site, so a test can assert the layer
# that broke and neither pattern can be handed to the other's file.
drive_exec_bit_causal() {
  _drive_artifact_causal "$1" "$_DRIVE_EXEC_REFUSAL_RE" "$2" "${3:-}"
}
drive_exec_bit_attribution() {
  _drive_artifact_attribution "$1" "$_DRIVE_EXEC_REFUSAL_RE" "$2" "${3:-}"
}
drive_pin_causal() {
  _drive_artifact_causal "$1" "$_DRIVE_PIN_STALE_RE" "$2" "${3:-}"
}
drive_pin_attribution() {
  _drive_artifact_attribution "$1" "$_DRIVE_PIN_STALE_RE" "$2" "${3:-}"
}

# drive_unattributed_failures <body> <attributed> -- the failing lines of
# <body> that <attributed> does not account for, one per line.
drive_unattributed_failures() {
  local body="$1" attr="$2" line out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -n "$attr" ] && grep -Fxq -- "$line" <<< "$attr"; then continue; fi
    out="$out$line
"
  done <<< "$(drive_failure_lines "$body")"
  printf '%s' "$out"
}

# _drive_attribution_check <attributed> <body> -- exit 0, printing nothing,
# when <attributed> is non-empty AND accounts for every failing line in <body>,
# so a waiver is admissible. Otherwise print the clause saying what blocked it,
# and exit 1.
#
# The two refusals are worded apart on purpose: "nothing attributes this
# failure to it" and "it explains part of this round and not the rest" are
# different facts about the candidate, and an operator reads them differently.
_drive_attribution_check() {
  local attr="$1" body="$2" un
  if [ -z "$attr" ]; then
    # The line is QUOTED here too, not just in the partial case below. An
    # operator reading "nothing here is attributable to it" cannot tell what
    # they are being charged for; the first thing that failed is the answer,
    # and it costs one more read of the same body.
    un="$(drive_unattributed_failures "$body" "")"
    if [ -n "$un" ]; then
      printf 'no failing line in this round is attributable to it, beginning "%s"' \
        "$(_drive_quote_line "$un")"
    else
      printf 'no failing line in this round is attributable to it'
    fi
    return 1
  fi
  un="$(drive_unattributed_failures "$body" "$attr")"
  [ -n "$un" ] || return 0
  printf 'it accounts for "%s", but %s further failing line(s) in the same round are not attributable to it, beginning "%s"' \
    "$(_drive_quote_line "$attr")" \
    "$(printf '%s' "$un" | grep -c .)" \
    "$(_drive_quote_line "$un")"
  return 1
}

# _drive_exec_state_clause <root> <base> <path> -- the outstanding exec-bit
# hand-off, in the operator's own terms. WHICH of the two shapes it is is said
# out loud: "you rewrote a runner and lost its mode bit" and "you shipped a new
# verb at 644" are the same `chmod +x`, and a different thing to know about the
# round that produced them.
_drive_exec_state_clause() {
  local root="$1" base="$2" p="$3" origin
  if _drive_exec_bit_dropped "$root" "$base" "$p"; then
    origin="which this candidate MODIFIED, dropping the mode 755 its base recorded"
  else
    origin="which this candidate added as a mode-644 file with a #! line"
  fi
  printf "the exec bit is not set on %s, %s — chmod +x %s is the operator's outstanding step" \
    "$p" "$origin" "$p"
}

# _drive_exec_unblamed_clause <root> <base> <path> -- the same outstanding
# state, worded for a round in which NOTHING is attributed to it.
#
# THE CLAUSE ABOVE ASSERTS AN OPERATOR ACTION, AND ON AN UNBLAMED ROUND THAT
# ASSERTION IS OFTEN FALSE. The exec-bit set is deliberately wider than "files
# awaiting chmod +x", because nothing on disk tells a new verb shipped mode 644
# apart from a library that is mode 644 on purpose because it is SOURCED -- and
# in this repository nearly every `lib/*.sh`, `scripts/pin-formula.sh` and some
# thirty files under `tests/` are the second kind. That is not one repository's
# quirk either: a file meant to be `source`d or run as `bash <file>` has no use
# for an exec bit, and plenty of projects never set one.
#
# ATTRIBUTION IS WHAT RESOLVES THE AMBIGUITY, and on a
# charged round there is by definition no attribution to resolve it with. So a
# task that added one sourced library was told, on every unrelated failure for
# the rest of its life, that `chmod +x lib/whatever.sh` was an outstanding
# operator step. It was not, nobody was waiting on it, and an operator who ran
# it would have committed a mode change no reviewer asked for.
#
# THE DROPPED SHAPE IS NOT AMBIGUOUS AND KEEPS THE IMPERATIVE. There the base
# tree recorded mode 755: something WAS executable and is not any more, and
# restoring it is owed whether or not this round's failures noticed. Only the
# ADDED shape -- the ambient one -- is reported rather than prescribed, and it
# is still NAMED, because the point of a fallback is that the operator sees
# what is open.
_drive_exec_unblamed_clause() {
  local root="$1" base="$2" p="$3"
  if _drive_exec_bit_dropped "$root" "$base" "$p"; then
    _drive_exec_state_clause "$root" "$base" "$p"
    return 0
  fi
  # The word `chmod` does NOT appear in this clause, and that is the assertion
  # a test can make about it: an operator who greps a charged round's reason
  # for a command to run must find nothing, because there is nothing to run.
  printf "this candidate added %s as a mode-644 file with a #! line, which is equally how a sourced library ships on purpose — nothing in this round was refused execution, so it is reported here rather than presented as a mode change anybody is waiting on" \
    "$p"
}

# ===========================================================================
# THE OTHER TWO CLASSES: environment, flaky.
#
# The two hand-offs above are not the only failures in which the code under
# test is blameless, and this task exists because each of the others cost a
# rework attempt in r-002 that measured nothing about a candidate. What follows
# adds them WITHOUT the mechanism that made every earlier version of this
# feature dangerous.
#
# THE MECHANISM, NAMED, BECAUSE IT MUST NOT COME BACK. An earlier round carried
# a build-state arm that was EXEMPT from the per-failure accounting: an absent
# ignored directory was taken to invalidate the whole run, so an unrelated
# `.cache` plus any `command not found` line waived every failure in the round.
# The defect was never the CLASS. It was the exemption. A round waived as a
# ROUND forgives whatever else happened to be in it, and that is the one thing
# this classifier may never do.
#
# So all four arms are the same shape, and the two below earn their waivers on
# the identical two halves the hand-offs do:
#
#   STATE       proved against the WORLD, never read out of the failure's
#               wording, and each answer is a THING -- a directory that is
#               present in the integration checkout and absent from the
#               dispatch worktree, a signature the repository recorded as
#               flaky BEFORE this candidate.
#   ATTRIBUTION per failing LINE, pooled with every other arm's, and then
#               `_drive_attribution_check` requires the pool to account for the
#               WHOLE round. One unexplained failing line still charges, and
#               the reason still quotes it.
#
# Nothing here is exempt from that accounting, and nothing here can waive a
# round on a coincidence.
# ===========================================================================

# -- environment: gitignored build state a dispatch worktree cannot carry ---
#
# LESSON L003, and it is the named case this task was written around. In the
# webBooks run, `mobile/node_modules` existed in the integration checkout only
# as a gitignored symlink into a sibling checkout. `git worktree add`
# reproduces what git TRACKS and nothing else, so every freshly created task
# worktree came up without it, the first `orchid verify` in each one failed on
# missing dependencies, and the attempt budget was charged for a gap in
# provisioning rather than a defect in the candidate. Every project that uses
# worktrees rediscovers this by losing an attempt to it.
#
# THE STATE IS A DIRECTORY, and it is proved by comparing the two checkouts:
# ignored by this repository's own rules, PRESENT where the run was dispatched
# from, ABSENT where the verification actually ran. Absent-and-ignored is not
# enough on its own -- the whole point is that the integration checkout has it
# and this worktree does not.
#
# THE ATTRIBUTION IS WHAT MAKES IT SAFE, and it is a fact about the world
# rather than a sentence: the round could not RESOLVE something, and the thing
# it could not resolve LIVES INSIDE the directory that is missing. `error
# Command "jest" not found` attributes to `mobile/node_modules` because
# `mobile/node_modules/.bin/jest` exists in the checkout that has the tree --
# and attributes to nothing at all when the missing directory is a `.cache`
# with no `jest` in it, which is precisely the coincidence that broke the old
# arm. NAMING the tree counts too, and so does naming a path INSIDE it --
# `ENOENT: no such file or directory, open '.../node_modules/x'` is a sentence
# about the tree that is not there, whichever half of the arm reads it
# (`_DRIVE_ENV_CHILD_TAIL` says why that is the environment arm's rule alone).

# `_DRIVE_RESOLUTION_RE` is declared with the failure-line oracle above. Here
# it is narrowed by filesystem attribution: on its own every one of those
# diagnostics is a sentence an ordinary defect prints -- a typo'd import is
# `Cannot find module` too.

# _DRIVE_ENV_CHILD_TAIL -- what may follow an absent DIRECTORY's name for the
# line to have named something INSIDE it: a `/` and then a path character.
#
# THIS IS THE ONE PLACE THE ARTIFACT BOUNDARY OPENS, AND ONLY HERE. The general
# rule (`_DRIVE_PATH_TAIL`) refuses a trailing `/` on purpose, because the
# artifacts the other arms hold are FILES: `bin/tool` must not collect
# `bin/tool-helper`, and it must not collect `bin/tool/child` either, which is a
# different file that merely lives under a path spelled like it. Neither
# exclusion is relaxed by anything here -- this pattern is used by the
# environment arm alone, and the exact-boundary rule is what the arm's own
# `_drive_env_named_lines` still carries as its first alternative.
#
# For an absent DIRECTORY the relationship is the opposite one: a path under it
# is not a different artifact, it IS that artifact, because the directory is
# what is missing and everything beneath it is missing with it. Without this the
# arm could not claim the cascade its own header documents -- `ENOENT: no such
# file or directory, open '.../node_modules/react-native/package.json'` names
# `node_modules` only through a child path, is the commonest sentence L003
# produces after the first missing command, and was charged.
#
# The `/` is required, so the exactness of the name itself is untouched:
# `node_modules-old/x` and `node_modules.bak/x` still match nothing.
_DRIVE_ENV_CHILD_TAIL='/[[:alnum:]._-]'

# _drive_env_named_lines <missing> <root> <body> -- the lines of <body> that
# name the absent directory <missing>, either by one of its three exact
# identities or by a path inside one of them.
_drive_env_named_lines() {
  local m="$1" root="$2" body="$3" identity
  [ -n "$m" ] && [ -n "$body" ] || return 0
  identity="$(_drive_path_identity_ere "$m" "$root")"
  [ -n "$identity" ] || return 0
  grep -E -- "$identity($_DRIVE_PATH_TAIL|$_DRIVE_ENV_CHILD_TAIL)" \
    <<< "$body" || true
}

# drive_env_missing_state <repo> <root> -- every path that is ignored by
# <repo>'s own rules, is a directory THERE, and does not exist in <root>, one
# per line. Nothing when <root> is <repo> itself, because then there is no
# dispatch worktree and nothing was left behind by creating one.
#
# `git status --porcelain --ignored` in its traditional mode collapses an
# ignored tree to the directory, so `node_modules/` comes back as one record
# rather than forty thousand. `-z` because a path may contain a newline; a
# record whose path does not stat as a directory is dropped, which loses
# recognition in the direction that CHARGES.
#
# `-d` rather than a trailing-slash test on git's own output: L003's case is a
# SYMLINK into a sibling checkout, which git reports without the slash it gives
# a real directory, and a rule that read the slash would have missed the exact
# case this arm exists for. `-d` follows the link and answers the question that
# matters -- is there a dependency tree here.
#
# `.git` and `.orchid` are excluded outright: run state is not build state, and
# a worktree legitimately has neither of them in the form the repo root does.
drive_env_missing_state() {
  local repo="$1" root="$2" rec p
  [ -d "$repo" ] && [ -d "$root" ] || return 0
  [ "$(cd "$repo" 2>/dev/null && pwd -P)" != "$(cd "$root" 2>/dev/null && pwd -P)" ] || return 0
  while IFS= read -r -d '' rec; do
    case "$rec" in '!! '*) p="${rec#'!! '}" ;; *) continue ;; esac
    p="${p%/}"
    [ -n "$p" ] || continue
    case "$p" in .git|.git/*|.orchid|.orchid/*) continue ;; esac
    [ -d "$repo/$p" ] || continue
    [ ! -e "$root/$p" ] || continue
    printf '%s\n' "$p"
  done < <(git -C "$repo" status --porcelain --ignored -z 2>/dev/null || true)
  return 0
}

# _drive_env_resolves <repo> <missing> <token> -- 0 when <token> names
# something that exists INSIDE <missing> in the checkout that still has it.
#
# Three shapes, and only three, because a "find anything called <token>
# anywhere under this tree" rule would resolve half the words in the English
# language against a `node_modules`: the package itself (`node_modules/lodash`),
# and the two conventional executable directories a dependency tree publishes
# its commands in (`node_modules/.bin/jest`, `.venv/bin/pytest`,
# `vendor/bin/phpunit`).
_drive_env_resolves() {
  local repo="$1" m="$2" t="$3"
  [ -n "$t" ] || return 1
  # Never an option, never an absolute path, never a traversal: the answer has
  # to be a name INSIDE the tree that is missing.
  case "$t" in -*|/*) return 1 ;; esac
  case "$t" in *..*) return 1 ;; esac
  [ -e "$repo/$m/$t" ] || [ -e "$repo/$m/.bin/$t" ] || [ -e "$repo/$m/bin/$t" ] || return 1
  return 0
}

# _drive_env_line_resolves <repo> <missing> <line> -- 0 when the SUBJECT of
# <line>'s resolution failure resolves inside <missing>.
#
# Every token is not a subject. `ENOENT: ... open 'src/config.json'` contains
# the word `open`, and a dependency tree commonly contains a package with that
# name; treating every word as a candidate lets that coincidence waive a real
# missing source file. The subject is instead taken only next to the diagnostic
# words that introduce it (`Command "jest"`, `find module lodash`, `resolve
# foo`, `open 'path'`). The shell's inverse spelling, `jest: command not found`,
# is the one form whose subject precedes the marker.
#
# This parser deliberately recognises a small grammar. Missing an unfamiliar
# diagnostic charges, while accepting an unrelated word forgives a candidate
# defect; strict classification requires the first direction.
_drive_env_line_resolves() {
  local repo="$1" m="$2" line="$3" i=0 expect=0 prev="" tok
  local -a words=()
  [ -n "$line" ] || return 1
  # `read -r -a` rather than an unquoted `for tok in $line`: word splitting
  # there also GLOBS, so a diagnostic containing a `*` would expand it against
  # the driver's working directory and hand this loop filenames nothing said.
  read -r -a words <<< "$line"
  while [ -n "${words[i]:-}" ]; do
    _drive_strip_punct_into "${words[i]}"
    tok="$_DRIVE_TOK"
    i=$((i + 1))
    [ -n "$tok" ] || continue

    if [ "$expect" -eq 1 ]; then
      # These are grammar between an introducer and its subject, as in
      # `Unable to resolve module foo` and `No module named 'foo'`.
      case "$tok" in
        command|Command|COMMAND|module|Module|MODULE|package|Package|PACKAGE|named|Named|NAMED|file|File|FILE|directory|Directory|DIRECTORY)
          prev="$tok"
          continue
          ;;
      esac
      _drive_env_resolves "$repo" "$m" "$tok" && return 0
      expect=0
    fi

    case "$tok" in
      command|Command|COMMAND)
        # POSIX shells put the missing command immediately before this word;
        # Yarn-style diagnostics put it immediately after.
        _drive_env_resolves "$repo" "$m" "$prev" && return 0
        expect=1
        ;;
      module|Module|MODULE|package|Package|PACKAGE|resolve|Resolve|RESOLVE|open|Open|OPEN)
        expect=1
        ;;
    esac
    prev="$tok"
  done
  return 1
}

# drive_env_causal <repo> <missing> <body> [root] -- the lines of <body> that
# report a RESOLUTION failure whose subject lives inside <missing>. Non-empty
# is the proof that this absent tree is what blocked THIS run.
#
# Both halves on the SAME line, exactly as the hand-off arms require: a
# resolution failure alone is what a typo'd import prints, and a token that
# happens to match something under an ignored directory is what half of an
# ordinary sentence does.
#
# The resolution shape is grepped out of the WHOLE body in one pass, and only
# those lines are then tokenized. A `grep` per line and a fork per token is how
# a classifier that runs on every failed verify becomes the slowest thing in
# the pass.
drive_env_causal() {
  local repo="$1" m="$2" body="$3" root="${4:-}" line res named out=""
  [ -n "$m" ] && [ -n "$body" ] || return 0
  res="$(grep -E -- "$_DRIVE_RESOLUTION_RE" <<< "$body" || true)"
  [ -n "$res" ] || return 0
  # TWO WAYS A RESOLUTION FAILURE'S SUBJECT IS SHOWN TO LIVE IN THE ABSENT TREE,
  # and both are facts rather than readings. The line names a path inside it --
  # an ENOENT quoting `.../node_modules/react-native/package.json` is about the
  # tree that is not there, and nothing else can be true of it -- or the line
  # holds a bare token the tree PUBLISHES, which is what a shell prints when a
  # command it cannot find would have come from `.bin`.
  named="$(_drive_env_named_lines "$m" "$root" "$res")"
  [ -z "$named" ] || out="$named
"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _drive_env_line_resolves "$repo" "$m" "$line" || continue
    out="$out$line
"
  done <<< "$res"
  printf '%s' "$out"
}

# drive_env_attribution <repo> <missing> <body> [root] -- the lines of <body>
# this absent tree is answerable for. Causal first, then its cascade: every
# FAILING line that NAMES the directory by identity. Empty means this failure
# is not attributable to it.
#
# EXACTLY THE TWO SOURCES THE HAND-OFF ARMS HAVE, and the third one this used
# to carry is gone. That third source claimed every failing line holding a
# token that RESOLVED inside the absent tree, with no resolution shape required
# of the line at all -- and a dependency tree's direct children are ordinary
# words. `node_modules/lodash` exists, so `FAIL: lodash helper returned 3,
# expected 4` resolved, and a plain candidate defect was waived as the missing
# tree's cascade because the thing it was about happened to share a name with a
# package. That is the same coincidence -- absent directory plus a sentence
# that mentions something inside it -- that the exempt round-wide arm was
# withdrawn for, reintroduced one line at a time.
#
# What is left is the rule the protocol states: a line must either report a
# RESOLUTION failure whose subject lives inside the tree (causal), or NAME the
# tree -- exactly, or by a path under it, which is the same tree and not a
# neighbouring one (cascade). The narrowing costs a cascade line that does
# neither -- `FAIL: suite could not start` -- which is unclaimed and charges,
# and that is the strict direction this classifier is required to lean in.
#
# The cascade is drawn from the failing lines rather than from the whole body
# for the same reason the hand-off arms' cascade is drawn from a path match:
# what the accounting has to answer for is the failures, and a line of ordinary
# progress output that happens to mention the directory claims nothing because
# there is nothing there to claim.
#
# Duplicates between the two sources are left in. `drive_unattributed_failures`
# tests MEMBERSHIP, so a line claimed twice is claimed once; deduping here would
# cost a fork per line to change nothing.
drive_env_attribution() {
  local repo="$1" m="$2" body="$3" root="${4:-}" fails causal named out=""
  [ -n "$m" ] && [ -n "$body" ] || return 0
  causal="$(drive_env_causal "$repo" "$m" "$body" "$root")"
  [ -n "$causal" ] || return 0
  # Keep each attributed diagnostic as its own record. Without this newline,
  # the first cascade line was glued to the causal line and the exact-line
  # accounting below rejected evidence this function had just established.
  out="$causal
"
  # Unknown diagnostics are deliberately in the whole-round denominator but
  # never in a naming cascade: only a line whose own syntax reports failure may
  # be claimed after the resolution-causal line opens this route.
  fails="$(drive_reported_failure_lines "$body")"
  [ -n "$fails" ] || { printf '%s' "$out"; return 0; }
  named="$(_drive_env_named_lines "$m" "$root" "$fails")"
  [ -z "$named" ] || out="$out$named
"
  printf '%s' "$out"
}

# -- flaky: a signature the repository ALREADY records as known-flaky --------
#
# Orchid never INFERS flakiness -- it cannot, from one run -- and this arm does
# not ask it to. It reads a register the repository keeps, and the whole of its
# safety is in WHEN that register has to have been written.
#
# A REGISTER THE CANDIDATE TOUCHED IS NOT AN AUTHORITY ON THE CANDIDATE. That
# is the same narrowing `handoff.pin_check` takes, and here it is what stops
# the obvious abuse: an implementer cannot quarantine the assertion it is
# failing, because the moment its candidate changes that file the route is
# gone and the round charges. Only a signature the repository recorded BEFORE
# this candidate -- which is what "already records as flaky" means -- forgives
# anything.
#
# THREE MORE THINGS KEEP IT NARROW. The signature is matched LITERALLY, never
# as a pattern, so no entry can be written that matches everything. It must be
# at least `_DRIVE_QUARANTINE_MIN_LEN` characters, so no entry can match
# everything by being short. And it claims ONLY the lines it literally matches
# -- there is no cascade here, because a quarantined assertion IS one line --
# so a suite that also prints an aggregate `3 tests failed` leaves that line
# unexplained and charges the round. That last one is a real limit and it is
# the strict direction: a register may excuse the assertion it names and
# nothing else.
_DRIVE_QUARANTINE_DEFAULT='tests/QUARANTINE.md'
_DRIVE_QUARANTINE_MIN_LEN=16

# _drive_quarantine_integration_intact <repo> <root> <base> <cand> <rel> -- 0
# when an old task branch may read <rel> from the integration checkout even
# though neither of its own commits carries that path.
#
# This is the narrow bootstrap edge for a register introduced while older task
# worktrees remain in flight. Requiring BOTH task commits to resolve and to
# lack the path distinguishes that case from every candidate-controlled shape:
# a candidate that adds the register has it in <cand>; one that deletes it had
# it in <base>. Neither can fall through to the integration copy. The two
# checkouts must also be distinct, and the integration copy must pass the same
# byte/mode/index authority guard against its own HEAD. Anything unanswerable
# charges.
_drive_quarantine_integration_intact() {
  local repo="$1" root="$2" base="$3" cand="$4" rel="$5" head line
  [ -d "$repo" ] && [ -d "$root" ] || return 1
  [ "$(cd "$repo" 2>/dev/null && pwd -P)" != "$(cd "$root" 2>/dev/null && pwd -P)" ] || return 1
  _drive_changed_paths_answerable "$root" "$base" "$cand" || return 1
  line="$(git -C "$root" ls-tree "$base" -- "$rel" 2>/dev/null)" || return 1
  [ -z "$line" ] || return 1
  line="$(git -C "$root" ls-tree "$cand" -- "$rel" 2>/dev/null)" || return 1
  [ -z "$line" ] || return 1
  head="$(git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  _drive_authority_intact "$repo" "$head" "$head" "$rel"
}

# drive_quarantine_signatures <repo> <root> <task-file> -- the known-flaky
# signatures this repository recorded, one per line. Nothing when there is no
# register or when it is not an authority on this candidate. Normally that is
# `_drive_authority_intact`: the candidate carries it unchanged and its live
# bytes, mode, and index match the commit. A carried-over branch whose base and
# candidate both answerably predate the path may instead use the clean tracked
# integration copy above. A candidate addition, deletion, or edit never can,
# and anything unanswerable charges.
#
# The format is one entry per line: `FLAKE: <literal substring>` and,
# optionally, ` -- <why>`. Prose around them is ignored, so the register can be
# the markdown document a human actually reads.
#
# `FLAKE:` must sit at COLUMN 0. An indented one is prose, which is how a
# register can carry a worked example of its own format without that example
# becoming a live signature -- the first thing anyone writing one of these
# files does.
drive_quarantine_signatures() {
  local repo="$1" root="$2" tf="$3" rel abs line sig edge base cand sep=' -- '
  rel="$(config_get "$repo" flaky.quarantine "$_DRIVE_QUARANTINE_DEFAULT")"
  [ -n "$rel" ] || return 0
  [ "$rel" != none ] || return 0
  # Inside the verified tree only: an absolute path is not something the
  # repository's own history can prove was recorded before this candidate.
  case "$rel" in /*|*..*) return 0 ;; esac
  base="$(fm_get "$tf" base_sha)"
  cand="$(fm_get "$tf" candidate_sha)"
  if _drive_authority_intact "$root" "$base" "$cand" "$rel"; then
    abs="$root/$rel"
  elif _drive_quarantine_integration_intact "$repo" "$root" "$base" "$cand" "$rel"; then
    abs="$repo/$rel"
  else
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'FLAKE:'*) sig="${line#FLAKE:}" ;;
      *) continue ;;
    esac
    sig="${sig%%"$sep"*}"
    edge="${sig%%[![:space:]]*}"; sig="${sig#"$edge"}"
    edge="${sig##*[![:space:]]}"; sig="${sig%"$edge"}"
    [ "${#sig}" -ge "$_DRIVE_QUARANTINE_MIN_LEN" ] || continue
    printf '%s\n' "$sig"
  done < "$abs"
  return 0
}

# drive_quarantine_attribution <signature> <body> -- the lines of <body> that
# literally contain <signature>. `grep -F`, never `grep -E`: a register is
# repository-controlled text, and a `.*` in it would waive every round.
drive_quarantine_attribution() {
  local sig="$1" body="$2"
  [ -n "$sig" ] && [ -n "$body" ] || return 0
  grep -F -- "$sig" <<< "$body" || true
}

# -- a run that stopped short: REPORTED, and never waived --------------------
#
# THIS WAS A WAIVABLE CLASS AND IT IS NOT ONE ANY MORE, and the withdrawal is
# the point rather than a simplification. The argument for it was that a suite
# killed by its own timeout, by the OOM killer, or by whatever reaped the pass
# never reported that the candidate is bad, so there is nothing to charge for.
#
# THE PREMISE WAS NEVER PROVED. `orchid verify` records the exit status of the
# command line the repository configured, and 124, 137 and 143 are what THAT
# process left behind -- not a fact about who ended it. Three different rounds
# produce the identical trailer:
#
#   the harness reaped a pass that was still working -- nobody's defect;
#   the CANDIDATE hung until a timeout reaped it -- squarely a defect, and the
#     one a `timeout` in a verification command line exists to catch;
#   the suite EXITED with that status on purpose, or propagated a child's --
#     `exit 143` is a legal thing for a script to do, and a test runner that
#     forwards a killed child's status does it without meaning anything by it.
#
# Nothing in the log tells them apart. The old arm read the first, waived the
# round, and forgave a hang once per task -- a residual it stated out loud,
# which is not the same as one it had earned. This classifier's own rule is
# that where classification is uncertain the attempt is CHARGED and the reason
# says why, and that rule was being applied to every other arm while this one
# assumed its way past it.
#
# So the status is still READ, and what it produces is a REPORT on a charged
# round: an operator seeing `attempt charged` needs to know the run also
# stopped short, or they will read a truncated log as a mysterious silence. It
# no longer produces a waiver, and no class is labelled `harness` any more.
_DRIVE_CUT_SHORT_STATUSES=' 124 137 143 '

# drive_verify_exit <verify-log> -- the `exit: N` trailer `orchid verify`
# appends, or nothing when the log does not end in one.
drive_verify_exit() {
  local log="$1" last
  [ -f "$log" ] || return 0
  last="$(tail -n 1 "$log" 2>/dev/null || true)"
  case "$last" in 'exit: '*) last="${last#'exit: '}" ;; *) return 0 ;; esac
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$last"
}

# drive_cut_short_clause <verify-log> -- the clause reporting that the recorded
# exit status is one a killed run leaves behind. Nothing otherwise.
#
# It is worded as what orchid KNOWS and does not know, because that is the
# whole of it: the status is a fact, and its provenance is not. The clause ends
# by saying the round is charged, so the sentence an operator reads is complete
# on its own wherever it is spliced in.
drive_cut_short_clause() {
  local log="$1" rc what
  rc="$(drive_verify_exit "$log")"
  [ -n "$rc" ] || return 0
  case "$_DRIVE_CUT_SHORT_STATUSES" in *" $rc "*) ;; *) return 0 ;; esac
  case "$rc" in
    124) what="the status its own timeout(1) leaves" ;;
    137) what="128+9, an out-of-memory kill or a hard reap" ;;
    *)   what="128+15, a timeout or a reap" ;;
  esac
  printf 'the verification run stopped short of a verdict: orchid verify recorded exit %s (%s) — but that status is equally what a candidate that HUNG until something reaped it leaves, and what a suite that exited with it deliberately leaves, and nothing in this log tells the three apart, so the uncertain reading charges the attempt' \
    "$rc" "$what"
}

# _drive_waived <class> <states> <attributed> [fallback] -- the waiver line,
# once the accumulated attribution has been found to account for the whole
# round. A fallback contributes no attribution and never earns the waiver; it
# is reported because it can still be an independent operator action the next
# pass owes, especially a candidate-dropped exec bit the base recorded at 755.
_drive_waived() {
  local cls="$1" states="$2" attributed="$3" fallback="${4:-}" note
  note="$states"
  [ -z "$fallback" ] \
    || note="$note (also outstanding, and not attributable to the printed failures: $fallback)"
  if [ -z "$attributed" ]; then
    printf '%s\t%s, and this round left no failing line for anything else to explain\n' "$cls" "$note"
    return 0
  fi
  printf '%s\t%s, and this failure is attributable to exactly that: "%s"\n' \
    "$cls" "$note" "$(_drive_quote_line "$attributed")"
}

# drive_waivable_outstanding <repo> <task-file> <verify-body> <verify-log> --
# what every waivable class has to say about THIS failure, as
# "<class><TAB><reason>":
#
#   handoff / environment / flaky
#              some class has state outstanding, failures are attributable to
#              it, and TOGETHER the pool accounts for every failing line in the
#              round. The class named is the one an operator would have to act
#              on first (see the precedence below).
#   candidate  some class has state outstanding and that did not hold. The
#              reason says which, because "the state is there but nothing ties
#              this failure to it" is a fact an operator needs stated rather
#              than a silent charge.
#   (nothing)  no class has any state outstanding, so none of them has anything
#              to say about this round either way.
#
# EVERY OUTSTANDING ARTIFACT IS ASKED, AND THEIR ANSWERS ARE POOLED, ACROSS
# CLASSES. An earlier round stopped at the first attributable path and then
# required that ONE artifact to account for the whole round -- so a round in
# which a stale pin explained six lines and a dropped mode bit explained four
# was charged, with every failure in it an operator's and none of them the
# candidate's. Attribution is per FAILURE, so what a waiver needs is that
# nothing is left over, not that one artifact did all the work; and a round
# whose failures are half a missing dependency tree and half an unset mode bit
# is no more the candidate's than either half alone.
#
# THE CLASS NAMED IS THE ONE SOMEBODY MUST ACT ON FIRST, which is why the
# precedence is handoff, then environment, then flaky rather than alphabetical
# or first-to-fire: a hand-off is a step an operator performs, a missing
# dependency tree is provisioning somebody must add, and a quarantined
# assertion is already on somebody's list. Every contributing class is still
# NAMED in the reason regardless, so the label chooses the headline and never
# hides the rest.
#
# The reason NAMES THE ARTIFACTS, never just the class. "waiting on an operator
# hand-off" tells an operator nothing they can act on; "the exec bit is not set
# on libexec/orchid-frob" is a command they can run. Where several are to
# blame, all of them are named -- an operator who clears one, re-dispatches,
# and walks into the other has learned nothing from the first journal line.
#
# THE ORDER OF EVALUATION IS COST, NOT PRIORITY. The exec-bit question is a
# stat, the missing-state question is a `git status`, and the pin check builds
# a release archive; the expensive ones are SKIPPED entirely once the pool
# already accounts for the round, because all of them are equally admissible
# and there is no verdict left to reach.
drive_waivable_outstanding() {
  local repo="$1" tf="$2" body="$3" log="${4:-}" root base
  local paths p first="" firstdrop="" fbpath causal attr="" states="" sep=""
  local fallback="" fsep=""
  local why="" note pin cmd="" pinpath="" pinattr pinstate
  local kinds="" m envattr envstate sig qattr cut
  base="$(fm_get "$tf" base_sha)"
  root="$(fm_get "$tf" worktree)"
  # The verification ran in the task's worktree when it has one; that is the
  # tree whose state these questions are about.
  [ -n "$root" ] && [ -d "$root" ] || root="$repo"
  # A stopped-short status has uncertain provenance and therefore vetoes every
  # waiver, including one whose printed failure lines are otherwise fully
  # attributable. Compute it before the three cost-saving early returns below;
  # leaving it until the reporting block meant those returns never examined
  # the status at all and could still forgive a candidate hang.
  cut="$(drive_cut_short_clause "$log")"

  paths="$(drive_handoff_exec_bit "$root" "$tf")"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # One outstanding path is remembered even if nothing blames it, so a
    # charged round still tells the operator which state is open. A DROPPED bit
    # is preferred over an added one however git ordered them: it is the only
    # one of the two shapes that is an operator action on its own evidence, so
    # when a round holds both, the actionable one is what gets reported.
    [ -n "$first" ] || first="$p"
    if [ -z "$firstdrop" ] && _drive_exec_bit_dropped "$root" "$base" "$p"; then
      firstdrop="$p"
    fi
    causal="$(drive_exec_bit_attribution "$p" "$body" "$root")"
    [ -n "$causal" ] || continue
    attr="$attr$causal
"
    states="$states$sep$(_drive_exec_state_clause "$root" "$base" "$p")"
    sep='; and '
    kinds="$kinds handoff"
  done <<< "$paths"
  if [ -z "$states" ]; then
    fbpath="${firstdrop:-$first}"
    if [ -n "$fbpath" ]; then
      fallback="$(_drive_exec_unblamed_clause "$root" "$base" "$fbpath")"
      fsep='; and '
    fi
  fi

  # Waived on the exec bit alone, but only when the run reached an ordinary
  # verdict: uncertain stopped-short provenance charges regardless of what its
  # printed lines happened to name.
  if [ -z "$cut" ] && [ -n "$attr" ] \
     && why="$(_drive_attribution_check "$attr" "$body")"; then
    _drive_waived "$(_drive_waived_class "$kinds")" "$states" "$attr" "$fallback"
    return 0
  fi

  # -- environment: gitignored build state this worktree never received.
  #
  # An absent directory that attributes nothing is NOT added to `fallback`, and
  # that asymmetry with the two hand-offs is deliberate. An outstanding
  # hand-off is a named step somebody owes; an ignored directory the worktree
  # lacks is ordinary -- a `.cache`, a `dist`, a stale `target` -- and listing
  # every one of them on every charged round would bury the sentence that
  # matters under a directory census.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    envattr="$(drive_env_attribution "$repo" "$m" "$body" "$root")"
    if [ -n "$envattr" ]; then
      envstate="$m is present in the integration checkout and absent from the worktree this candidate was verified in — it is gitignored, so creating the worktree from Git-tracked state could not reproduce it (lesson L003), and provisioning it there is a dispatch step rather than anything the implementer wrote"
      attr="$attr$envattr
"
      states="$states$sep$envstate"
      sep='; and '
      kinds="$kinds environment"
    fi
  done <<< "$(drive_env_missing_state "$repo" "$root")"

  # -- flaky: signatures this repository recorded before this candidate.
  while IFS= read -r sig; do
    [ -n "$sig" ] || continue
    qattr="$(drive_quarantine_attribution "$sig" "$body")"
    [ -n "$qattr" ] || continue
    attr="$attr$qattr
"
    states="$states${sep}this repository already records \"$(_drive_quote_line "$sig")\" as a known-flaky assertion, in a register this candidate did not touch — the test is the thing to fix, and until it is, its failure says nothing about this candidate"
    sep='; and '
    kinds="$kinds flaky"
  done <<< "$(drive_quarantine_signatures "$repo" "$root" "$tf")"

  # Waived without ever running the pin check: it builds a release archive, and
  # there is no verdict left for it to reach.
  if [ -z "$cut" ] && [ -n "$attr" ] \
     && why="$(_drive_attribution_check "$attr" "$body")"; then
    _drive_waived "$(_drive_waived_class "$kinds")" "$states" "$attr" "$fallback"
    return 0
  fi

  pin="$(drive_handoff_stale_pin "$repo" "$root" "$tf")"
  # Split on the FIRST newline, and require BOTH halves: command substitution
  # strips trailing newlines, so anything without one is not the two-line
  # answer this route promises and is treated as no answer at all.
  case "$pin" in
    *$'\n'*) cmd="${pin%%$'\n'*}"; pinpath="${pin#*$'\n'}" ;;
  esac
  if [ -n "$pinpath" ]; then
    pinstate="the package pin recorded for $pinpath is stale — the repository's own freshness check ($cmd) reports it stale in this tree, and re-pinning it is the operator's outstanding step"
    pinattr="$(drive_pin_attribution "$pinpath" "$body" "$root")"
    if [ -n "$pinattr" ]; then
      attr="$attr$pinattr
"
      states="$states$sep$pinstate"
      sep='; and '
      kinds="$kinds handoff"
    else
      fallback="$fallback$fsep$pinstate"
      fsep='; and '
    fi
  fi

  why=""
  if [ -z "$cut" ] && [ -n "$attr" ] \
     && why="$(_drive_attribution_check "$attr" "$body")"; then
    _drive_waived "$(_drive_waived_class "$kinds")" "$states" "$attr" "$fallback"
    return 0
  fi

  # -- a run that stopped short. This waives NOTHING (see the section header
  # above `_DRIVE_CUT_SHORT_STATUSES`): the recorded status cannot tell a reap
  # from a candidate that hung from a deliberate exit, and an unproved
  # provenance charges here like every other uncertainty. It is REPORTED
  # instead, because an operator reading a charged round needs to know the run
  # also stopped where it did rather than wonder why the log ends there.
  if [ -n "$cut" ]; then
    # When every printed failure IS attributable, say that honestly. The
    # attempt still charges because the stopped-short status is an additional,
    # unproved fact about the round; falling through to the generic tail would
    # instead print "attribution was not established" with an empty reason,
    # contradicting the evidence this function just accumulated.
    if [ -z "$(drive_unattributed_failures "$body" "$attr")" ]; then
      if [ -z "$states$fallback" ]; then
        printf 'candidate\t%s\n' "$cut"
        return 0
      fi
      if [ -n "$states" ]; then
        note="$states"
        [ -z "$fallback" ] \
          || note="$note (also outstanding, and not attributable to the printed failures: $fallback)"
      else
        note="$fallback"
      fi
      printf 'candidate\t%s; every printed failing line is otherwise attributable, but %s\n' \
        "$note" "$cut"
      return 0
    fi
    fallback="$fallback$fsep$cut"
    fsep='; and '
  fi

  # Nothing was outstanding at all: this round is none of these classes'
  # business, and they say nothing about it in either direction.
  [ -n "$states" ] || [ -n "$fallback" ] || return 0
  # A blamed-but-insufficient artifact is what the operator needs named first;
  # only when nothing was blamed does the merely-outstanding state stand in for
  # it. Either way the merely-outstanding rest is still SAID, because an
  # operator who clears one, re-dispatches, and walks into the other has
  # learned nothing from the first journal line.
  if [ -n "$states" ]; then
    note="$states"
    [ -z "$fallback" ] \
      || note="$note (also outstanding, and not attributable to this failure either: $fallback)"
  else
    note="$fallback"
  fi
  [ -n "$why" ] || why="$(_drive_attribution_check "$attr" "$body" || true)"
  printf 'candidate\t%s — %s; attribution was not established, so the attempt is charged\n' \
    "$note" "$why"
}

# _drive_waived_class <kinds> -- the one class name a waiver is LABELLED with,
# out of the space-separated kinds that contributed to it. Precedence is by
# whose action clears it, most actionable first: an operator performs a
# hand-off, somebody provisions a worktree, and a quarantined assertion is
# already on a list.
#
# Only ever called with a non-empty <kinds>, since a waiver requires attributed
# evidence and every arm that contributes evidence records its kind. `flaky` is
# the last arm rather than a separate default arm, so there is no branch here
# that can only be reached by a caller that stopped keeping its side of that
# bargain.
_drive_waived_class() {
  case " $1 " in
    *' handoff '*)     printf 'handoff' ;;
    *' environment '*) printf 'environment' ;;
    *)                 printf 'flaky' ;;
  esac
}

# _DRIVE_WAIVER_MARK -- the phrase every waived rework round carries in its
# `--reason`, and therefore in its `attempt_waiver` journal entry. Written and
# read from this one constant so the recurrence guard below cannot drift out of
# step with the reason it counts.
_DRIVE_WAIVER_MARK='attempt not charged'

# drive_waiver_mark -- `_DRIVE_WAIVER_MARK` as a value callers outside this
# file can take. A function rather than a bare variable reference on purpose:
# the driver and the tests do not source this library in a way ShellCheck can
# resolve, so reading the variable across files invites an SC2154 the lint gate
# treats as fatal, and every workaround for that is worse than one accessor.
drive_waiver_mark() { printf '%s' "$_DRIVE_WAIVER_MARK"; }

# drive_waiver_reason <class> <why> -- the `--reason` a waived rework round
# carries. Written here rather than at the call site because
# `drive_waived_rounds` READS it back out of the journal: the marker has to be
# findable in that line, and a format the writer and the reader spell
# separately drifts apart silently, leaving a guard that counts nothing.
drive_waiver_reason() {
  printf 'verify failed (%s, %s): %s' "$1" "$_DRIVE_WAIVER_MARK" "$2"
}

# drive_waived_rounds <journal-file> <task-id> -- how many verify failures this
# task has ALREADY had waived by the driver.
#
# NO WAIVABLE CLASS IS ONE THE IMPLEMENTER CAN CLEAR: a checksum is re-pinned
# by an operator, an exec bit is set by one, a missing dependency tree is
# provisioned by whoever dispatches, and a quarantined assertion is fixed in
# the test. Re-dispatching the
# implementer against any of them produces the identical failure and nothing
# else, so this count is what stops the second such round rather than grinding
# out the rest of `infra_max` on retries that cannot work.
#
# The count is deliberately ACROSS classes rather than per class: a task that
# waived a hand-off and then waived a missing dependency tree has had two
# rounds that told nobody anything about the candidate, and a human should look
# at the run rather than watch a third go by.
#
# This is the task's OWN history, and only the driver's own waivers. The guard
# used to read `infra_failures`, which is a shared counter: an unrelated
# earlier infra failure -- a dead job manifest, a launch that could not spawn
# -- made it non-zero and suppressed the FIRST waived round, which is the one
# round that is supposed to retry. `attempt_waiver` is also the kind an
# operator's `task arbitrate --waive-attempt` writes, which is a different
# decision entirely, so the driver's own marker is required as well.
#
# SELECTING THE ENTRIES AND COUNTING THEM ARE KEPT APART, and that split is
# load bearing rather than tidiness. awk does the one job it is good at here --
# walk the journal's `## <ts> <task> <kind>` headings and print the reason line
# under each matching one -- and nothing else: this library is sourced into a
# `set -e` driver and read through a command substitution, so an awk that dies
# takes the entire pass down with it instead of returning a number, and one arm
# of the classifier can then never be reached at all.
_drive_waiver_reason_lines() {
  awk -v id="$2" -v mark="$_DRIVE_WAIVER_MARK" '
    /^## / { want = ($3 == id && $4 == "attempt_waiver"); next }
    want && $0 != "" { if (index($0, mark)) print; want = 0 }
  ' "$1"
}

drive_waived_rounds() {
  local journal="$1" id="$2" line lines n=0
  if [ ! -f "$journal" ]; then printf '0\n'; return 0; fi
  # Assigned on its own line, and never allowed to fail the caller: this is
  # read through a command substitution inside a `set -e` driver, where a
  # non-zero status here is not a count of zero but a dead pass.
  lines="$(_drive_waiver_reason_lines "$journal" "$id" || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
  done <<< "$lines"
  printf '%s\n' "$n"
}

drive_verify_class() {
  local repo="$1" tf="$2" log="$3" body hand hcls hnote suffix

  if [ ! -f "$log" ]; then
    printf 'candidate\tno verify evidence on disk, so the failure cannot be classified — charging per the strict default\n'
    return 0
  fi

  body="$(_drive_verify_body "$log")"
  hand="$(drive_waivable_outstanding "$repo" "$tf" "$body" "$log")"
  if [ -z "$hand" ]; then
    # Each clause says what was ESTABLISHED, not what is true of the world. The
    # pin and register clauses in particular are worded around the authority
    # guard: a check or a register this candidate wrote -- or one where that
    # could not be determined, because the shas do not resolve -- proves
    # nothing here, and saying "no pin is stale" would be a claim orchid never
    # made.
    printf 'candidate\tno failure-attributable waivable state was established in this tree — no package pin is reported stale by a freshness check this candidate recorded and left intact, this candidate left no executable mode 644, no missing gitignored build state was attributable to this failure, no trusted known-flaky register covers this failure, and the recorded exit status is not one a killed run leaves — so nothing but the candidate is left to explain this round\n'
    return 0
  fi
  hcls="${hand%%$'\t'*}"
  hnote="${hand#*$'\t'}"
  if [ "$hcls" != candidate ]; then
    case "$hcls" in
      handoff)     suffix="so this failure is waiting on an operator hand-off the implementer profile may not perform (L017)" ;;
      environment) suffix="so this failure is the dispatch environment's rather than the candidate's" ;;
      *)           suffix="so this failure is one the repository had already declared unreliable before this candidate existed" ;;
    esac
    printf '%s\t%s, %s\n' "$hcls" "$hnote" "$suffix"
    return 0
  fi
  # Everything else takes the strict default, with whatever WAS true and did
  # not forgive it said out loud: a failure that merely coincides with a known
  # fault is evidence of neither, and a coincidence must not launder it.
  printf 'candidate\t%s\n' "$hnote"
}
