#!/usr/bin/env bash
# lib/handoff.sh -- the OPERATOR HAND-OFF: read-only policy over the pause
# PROTOCOL.md's THE TICK names between an implementer's envelope reconciling
# and `orchid verify` running.
#
# WHAT THE PAUSE IS FOR. Some steps in a candidate are mechanical and require
# EXECUTION: re-pinning a release checksum in a formula, setting the mode bit
# on a newly added executable, applying a linter's own fix. An engine profile
# that denies on the command STRING can perform none of them -- it cannot run
# the linter, the checksum tool, or `chmod` (lesson L017) -- so routing them
# to it produces a rework round that could never have succeeded and spends one
# of the task's three attempts on it. Until this file, those steps were
# performed by an operator BY HABIT, at a point in the procedure that nothing
# named; and a point nothing names is a point a deterministic driver walks
# straight past, running `orchid verify` against a candidate that was never
# going to pass.
#
# WHAT IT IS NOT. It is not a claim about who may SEE a lint finding. The
# exact `file:line: RULE: message` locations travel into the brief regardless
# of who acts on them (lib/findings.sh), so the record shows what was wrong
# and whoever acts has it in hand. This file governs only the ACT.
#
# THE ACKNOWLEDGEMENT IS BOUND TO A COMMITTED CANDIDATE, NEVER TO A TASK OR A
# MOMENT. `handoff_ack` holds a candidate_sha, and it is satisfied only while
# it equals the task's CURRENT one. That is what makes the pause survive a
# resume: a second driver pass, or a session restarted an hour later, reads
# the same two fields and can tell "already performed" from "still
# outstanding" without a boundary record, a lock, or anyone's memory. It is
# also what makes it fail SAFE across `orchid merge`'s rebase arm -- a
# rebased tree is a different candidate, so an acknowledgement made against
# the old one can never be silently inherited by it, exactly as INV-07
# invalidates the verify evidence there.
#
# Pure policy, like lib/drive.sh: every function below READS (task
# frontmatter, config) and prints. The acknowledgement itself has exactly one
# writer, the `orchid task handoff` verb (libexec/orchid-task).
#
# Source AFTER lib/common.sh and lib/frontmatter.sh; it needs nothing else.

# handoff_gate_mode <repo> -- `required` when this repository asks the driver
# to stop at the hand-off, `off` when it does not.
#
# `handoff_before_verify` (config, default `off`) -- off is the compatibility
# default, and the right one for the ordinary case where an implementer can
# run the repository's own gates itself. Absent or empty reads as `off`;
# anything OTHER than the literal `off` reads as `required`. That direction is
# deliberate and matches lib/drive.sh's drive_surface_admits: a typo in this
# key can then only ever route more work to a human, never less.
handoff_gate_mode() {
  local v
  v="$(config_get "$1" handoff_before_verify off)"
  case "$v" in
    ''|off) printf 'off\n' ;;
    *) printf 'required\n' ;;
  esac
}

# handoff_state <repo> <task-id> -- exactly one line, "<state><TAB><detail>":
#
#   off          this repository does not ask for the pause at all; nothing
#                gates, and no boundary is ever raised for it.
#   satisfied    `handoff_ack` equals the task's CURRENT candidate_sha: an
#                operator performed this candidate's mechanical steps and
#                recorded it. A resumed session or a second driver pass
#                proceeds -- this is what stops the pause looping forever.
#   outstanding  no acknowledgement at all, one bound to a DIFFERENT
#                candidate (a rebase or a fresh rework round moved it), or no
#                candidate_sha to bind one to. The pass stops.
#
# Fail-closed on every axis: a missing task file, a missing candidate and a
# stale acknowledgement all read `outstanding`. The cost of stopping when the
# work was in fact done is one operator command; the cost of proceeding when
# it was not is a burnt attempt on a candidate nobody finished.
handoff_state() {
  local repo="$1" id="$2" tf ack cand
  if [ "$(handoff_gate_mode "$repo")" = off ]; then
    printf 'off\tthe handoff_before_verify gate is off for this repository\n'
    return 0
  fi
  tf="$(orchid_state "$repo")/tasks/$id.md"
  if [ ! -f "$tf" ]; then
    printf 'outstanding\tno task %s\n' "$id"
    return 0
  fi
  cand="$(fm_get "$tf" candidate_sha)"
  if [ -z "$cand" ]; then
    printf 'outstanding\tno candidate_sha is recorded, so no hand-off can be bound to one\n'
    return 0
  fi
  ack="$(fm_get "$tf" handoff_ack)"
  if [ -z "$ack" ]; then
    printf 'outstanding\tno operator hand-off is recorded for candidate %s\n' "$cand"
    return 0
  fi
  if [ "$ack" != "$cand" ]; then
    printf 'outstanding\tthe recorded hand-off is bound to candidate %s, not the current %s\n' "$ack" "$cand"
    return 0
  fi
  printf 'satisfied\toperator hand-off acknowledged for candidate %s\n' "$cand"
}
