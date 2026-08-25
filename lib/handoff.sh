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
# WHICH CANDIDATE, THOUGH. The hand-off's whole purpose is to COMMIT work
# after candidate_sha was captured, so the acknowledging verb advances the
# candidate to the commit the hand-off produced before binding to it. That is
# what makes `satisfied` below mean "the record names the tree verification
# will run" rather than merely "someone said they were done" -- an ack against
# the pre-hand-off sha would bind every downstream judgment to a commit that
# was never verified (lesson L025), inside the procedure meant to end exactly
# that. The commit it advances to must DESCEND from the candidate it replaces
# and sit on the branch the task record names -- advancing to whatever HEAD
# happens to be would trade the drift for a worse mis-binding, a record naming
# a tree that shares no history with the work under judgment. This file only
# READS the result of that; see libexec/orchid-task.
#
# Pure policy, like lib/drive.sh: every function below READS (task
# frontmatter, config) and prints. The acknowledgement is only ever CREATED by
# the `orchid task handoff` verb (libexec/orchid-task); every other writer of
# the field WITHDRAWS it -- entry to `rework`, `unblock`, `retry`, `--clear`,
# and `task reverify` when it re-stamps the candidate onto the operator's own
# HEAD. Reverify is worth naming because it is the one that looks like an
# exception and is not: the candidate it stamps provably DESCENDS from the
# acknowledged commit, but descent only proves the acknowledged work is still
# present, never that the commits stacked on top need no mechanical steps of
# their own -- which is the only thing the ack asserts. So the ack is dropped
# and the pause below reopens against the new candidate, exactly as it does
# for any other HEAD that has moved past it.
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

# handoff_worktree_dirty <cwd> -- a ONE-LINE summary of everything uncommitted
# in <cwd>, or nothing at all when the tree is clean. Three outcomes, and the
# caller must read the STATUS as well as the output:
#
#   0, no output    inspected, and clean.
#   0, one line     inspected, and this is what is uncommitted.
#   2, one line     NOT INSPECTED, and this is why.
#
# THE FAILURE DIRECTION IS DIRTY, NOT CLEAN. `git status` can fail for reasons
# that have nothing to do with the tree being tidy -- the path is not a
# checkout, it is a bare repository, its index is unreadable, `git` is not
# there. Discarding that status would fold every one of them into the same
# empty string a genuinely clean tree produces, and both callers below read
# empty as "clean": the ack would be given and the resume would proceed, on the
# strength of a look that never happened. An inspection that answers `clean`
# when it could not look is not a safety check, it is the fail-open shape this
# whole file exists to close -- so the status is kept, and a tree that could
# not be read is refused in the same direction as a dirty one and SAID to be
# uninspected rather than reported clean.
#
# WHY THE STATE AND NOT JUST `HEAD`. Every other comparison in this file is
# between shas, and a sha describes a COMMIT -- it says nothing about the tree
# sitting on top of it. An operator who applies the linter's fix and
# acknowledges without committing leaves `handoff_ack`, `candidate_sha` and
# `HEAD` all in perfect agreement about a commit that does not contain the work,
# while `orchid verify` runs the working tree that does. Every downstream
# judgment is then recorded against a commit nobody ran: lesson L025 exactly,
# reached by the one road three matching shas cannot see. So the tree's STATE is
# read too, at both ends -- the ack refuses to be given (libexec/orchid-task) and
# a resume reads the boundary as still outstanding.
#
# Untracked files count. `orchid verify` runs the suite in this tree with no
# regard for the index, so an uncommitted new file is as capable of turning a
# FAIL into a PASS as an uncommitted edit is -- and a mode bit set on a newly
# added executable, one of the three canonical hand-off steps, IS a tracked
# modification that shows up here. `.orchid/` does NOT count: kernel state is
# no part of the candidate, and the checkout it lives in is stale by design
# (see the note in the awk below).
#
# Truncated at five paths with the remainder counted: this text goes into a
# one-line boundary detail and a `die`, and a hundred-path dump in either is
# read the way no list at all is.
handoff_worktree_dirty() {
  local cwd="$1" porcelain rc=0
  # Captured, never piped straight into a consumer that can exit early: under
  # `pipefail` a short-circuiting reader SIGPIPEs `git` and the 141 would be
  # reported for the whole pipeline (the same trap libexec/orchid-task's INV-04
  # re-scan documents). And captured WITH its exit status -- a `|| true` here
  # is exactly the fail-open the header above rejects.
  porcelain="$(git -C "$cwd" status --porcelain 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'git status exited %s in %s\n' "$rc" "$cwd"
    return 2
  fi
  [ -n "$porcelain" ] || return 0
  printf '%s\n' "$porcelain" | awk '
    # Porcelain v1 is two status columns, a space, then the path.
    { p = substr($0, 4) }
    # `.orchid/` IS NOT PART OF THE CANDIDATE and is skipped. Kernel state is
    # committed through a throwaway worktree and moved with `update-ref`, which
    # never touches this checkout index -- so on a task with no worktree of its
    # own, where this tree IS the integration checkout, every state write since
    # the last plain checkout reads as an uncommitted change here. Counting
    # those would refuse the ack forever on exactly the tasks PROTOCOL.md
    # already calls the awkward case, for state the candidate is forbidden to
    # contain anyway (INV-04). What this function asks about is the tree the
    # candidate itself is made of.
    p ~ /^\.orchid\// { next }
    { n++; if (n <= 5) { printf "%s%s", sep, p; sep = ", " } }
    END {
      if (n > 5) printf ", and %d more", n - 5
      if (n > 0) printf "\n"
    }'
}

# handoff_state <repo> <task-id> -- exactly one line, "<state><TAB><detail>":
#
#   off          this repository does not ask for the pause at all; nothing
#                gates, and no boundary is ever raised for it.
#   satisfied    `handoff_ack` equals the task's CURRENT candidate_sha, that is
#                what `HEAD` of the tree verification will run in actually is,
#                AND that tree is CLEAN: an operator performed this candidate's
#                mechanical steps, committed them, recorded it, and nothing has
#                landed or been left uncommitted since. A resumed session or a
#                second driver pass proceeds -- this is what stops the pause
#                looping forever.
#   outstanding  no acknowledgement at all, one bound to a DIFFERENT
#                candidate (a rebase or a fresh rework round moved it), no
#                candidate_sha to bind one to, a tree whose HEAD has moved
#                past the acknowledgement, a tree with uncommitted changes
#                sitting on top of it, or a tree whose state could not be
#                inspected at all. The pass stops.
#
# WHY THE HEAD COMPARE IS PART OF THE RESUME RULE, not a detail of the ack.
# Two frontmatter fields agreeing prove only that they were written together.
# The thing the pause is actually about is a COMMITTED TREE -- and an operator
# who acknowledges, then commits once more (a second lint fix, a formula they
# re-pinned after re-reading the diff) leaves the record naming a tree that no
# longer exists anywhere. On a resume that reads `already performed` and
# verifies the later tree, every downstream judgment is bound to a commit
# nothing ever verified, which is lesson L025 reached by a different road --
# and reached silently, because the two fields still match each other. So the
# tree is read, not inferred, and a HEAD that has moved past the ack reopens
# the pause: `orchid task handoff <id> --ack` re-run advances and re-binds,
# which is precisely the one-command cost the fail-closed direction costs
# everywhere else here.
#
# Fail-closed on every axis: a missing task file, a missing candidate, a stale
# acknowledgement, a dirty tree and an unreadable tree all read `outstanding`.
# The cost of stopping when the work was in fact done is one operator command;
# the cost of proceeding when it was not is a burnt attempt on a candidate
# nobody finished.
handoff_state() {
  local repo="$1" id="$2" tf ack cand wt cwd head dirty drc
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
  # The tree resolved exactly as `orchid verify` and `orchid task handoff`
  # resolve theirs -- the task's `worktree` when set, else the repo -- so all
  # three are always talking about the same checkout.
  wt="$(fm_get "$tf" worktree)"; cwd="$repo"; [ -z "$wt" ] || cwd="$wt"
  head="$(git -C "$cwd" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$head" ]; then
    printf 'outstanding\tHEAD of %s cannot be read, so nothing confirms the acknowledged candidate %s is still the tree verification would run\n' "$cwd" "$cand"
    return 0
  fi
  if [ "$head" != "$ack" ]; then
    printf 'outstanding\tthe hand-off was acknowledged for candidate %s, but HEAD of %s is now %s — a commit landed after the acknowledgement, so re-run the ack to advance and re-bind\n' "$ack" "$cwd" "$head"
    return 0
  fi
  # ...and the tree ON that commit, which the three shas above cannot see. An
  # uncommitted mechanical fix is the same L025 failure as a post-ack commit --
  # verification runs work no commit contains -- except that here every sha
  # still agrees, so nothing above would ever notice it.
  drc=0
  dirty="$(handoff_worktree_dirty "$cwd")" || drc=$?
  if [ "$drc" -ne 0 ]; then
    # A LOOK THAT NEVER HAPPENED IS NOT A CLEAN TREE. Every axis above this one
    # compares shas, which can all agree about a commit while the tree carries
    # work no commit contains; this is the axis that reads the tree itself, so
    # a failed read here leaves that gap wide open rather than closed. Reported
    # as what it is -- uninspected -- because "clean" and "we could not look"
    # call for opposite actions from the operator who reads it.
    printf 'outstanding\tthe hand-off is acknowledged for candidate %s, but the working tree of %s could not be inspected (%s), so nothing says whether verification would run that commit or uncommitted work sitting on top of it\n' "$ack" "$cwd" "$dirty"
    return 0
  fi
  if [ -n "$dirty" ]; then
    printf 'outstanding\tthe hand-off is acknowledged for candidate %s, but %s has uncommitted changes (%s) — verification would run a tree no commit contains, so commit them and re-run the ack\n' "$ack" "$cwd" "$dirty"
    return 0
  fi
  printf 'satisfied\toperator hand-off acknowledged for candidate %s\n' "$cand"
}
