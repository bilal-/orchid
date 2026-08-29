#!/usr/bin/env bash
# lib/handoff.sh -- the OPERATOR-OWNED STOPS: read-only policy over the pause
# PROTOCOL.md's THE TICK names between an implementer's envelope reconciling
# and `orchid verify` running.
#
# There are TWO of them, and they share this file because they share that one
# point in the procedure. The first half of this file is the OPERATOR HAND-OFF
# (T010): mechanical work INSIDE the candidate that requires execution. The
# second half is the OPERATOR PREREQUISITE (T024, dogfood F26): a step OUTSIDE
# the repository that the candidate's verification depends on. Their headers
# below say plainly how they differ; the short version is that a hand-off
# produces a commit and moves `candidate_sha` onto it, while a prerequisite
# changes the world outside this tree and leaves the candidate exactly as it
# was.
#
# WHAT THE PAUSE IS FOR. Some steps in a candidate are mechanical and require
# EXECUTION: setting the mode bit on a newly added executable, applying a
# linter's own fix, running a generator whose output is checked in. An engine
# profile that denies on the command STRING can perform none of them -- it
# cannot run the linter, the generator, or `chmod` (lesson L017) -- so routing them
# to it produces a rework round that could never have succeeded and spends one
# of the task's three attempts on it. Until this file, those steps were
# performed by an operator BY HABIT, at a point in the procedure that nothing
# named; and a point nothing names is a point a deterministic driver walks
# straight past, running `orchid verify` against a candidate that was never
# going to pass.
#
# WHAT MUST NEVER BE ON THAT LIST. An artifact derived from the WHOLE TREE --
# the release-archive checksum pinned into Formula/orchid.rb is the case that
# bit (lesson L022) -- must not be regenerated per candidate, by this pause or
# by anything else. Every candidate would rewrite the same line to a different
# value, so the second one to reach `orchid merge`'s stale-base rebase
# conflicts on it, lands in `rework`, and is handed to an implementer that
# cannot regenerate it either; nothing in that loop terminates. Such artifacts
# belong to the integration branch, regenerated there once after merges land
# or at release time, and gated at the release gate.
#
# WHAT PERFORMING IT BY HABIT RISKS. A hand-off can also be LOST after being
# performed: done outside this pause, late in a candidate's life, on a branch
# tip that is not what eventually merged, the work is silently dropped from
# the shipped tree and nothing fails at the time -- an exec-bit hand-off once
# shipped exactly that way, identical blob, wrong mode. Same failure family
# as lessons L017 and L021: mechanical work done out-of-band leaves no
# machine-checkable trace tying it to the candidate under judgment. The sha
# binding below is the countermeasure -- the ack names the commit the work
# produced, so work the shipped candidate lacks surfaces as a mismatch
# instead of a habit nobody re-checks.
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
# WHO ASKS FOR THE PAUSE. Two independent arms, and it is asked for when EITHER
# says so:
#
#   the config arm       `handoff_before_verify` -- an operator states that this
#                        repository's candidates need the pause.
#   the capability arm   the `mechanical` step cannot be routed to the actor
#                        that built THIS candidate: it could not be resolved to
#                        a manifest at all, so nothing says it can -- or (see
#                        the next paragraph for why this half does not fire for
#                        a dispatched implementer) its manifest does not declare
#                        `shell` (INV-16, lib/capability.sh's `mechanical` step;
#                        both refuse, see the arm itself).
#
# WHAT THE CAPABILITY ARM ACTUALLY CATCHES, AND WHAT IT DOES NOT. It does NOT
# generalize the config arm, and nothing that reads this file may say it does.
# `roles/implementer.role` declares `requires=workspace_write,shell,git`, and
# that is enforced before anything is dispatched -- by resolve_role_available
# walking the chain, and by `orchid jobs prepare`'s own eligibility check when
# an engine is named explicitly. An engine declaring no `shell` is therefore
# refused the implementer role at exit 14, BEFORE any candidate of its exists
# for this arm to hold, so the "declares no `shell`" outcome cannot arise for a
# candidate orchid's own dispatch produced. Writing this arm as though it were
# the routine protection would be advertising a pause that cannot fire -- an
# operator would read it and believe orchid guards a case it never reaches.
#
# It is kept, as what it actually is: defense in depth against that role
# descriptor changing, plus the answer for the two situations the role gate
# never saw -- a task with no `implementer_engine_id` recorded, where
# review_implementer_engine falls back to the raw `role.implementer` binding
# that nothing has eligibility-checked, and a manifest edited underneath a
# candidate after its job was minted.
#
# WHAT IT DOES CLOSE ON ITS OWN is the actor this gate CANNOT IDENTIFY. An
# implementer that resolves to no installed manifest is held rather than waved
# through, and no role gate covers that: the role gate ran while the plugin was
# still installed.
#
# AND THE CONFIG ARM IS NOT MADE REDUNDANT BY EITHER. It is the only cover for
# the case no declaration shows: a profile that DECLARES `shell` and is still
# not granted it -- the shipped claude adapter, on its implement path, which is
# the exact loss this pause was introduced for. An operator who needs that
# still sets `handoff_before_verify`; nothing below sets it for them.
#
# THE TWO ARMS COMPOSE, THEY DO NOT OVERRIDE. Either can turn the pause ON;
# neither can turn the other OFF. In particular an actor that declares `shell`
# does NOT clear a pause the operator asked for: a manifest capability is a
# CLAIM BY THE PLUGIN, NOT A GRANT (docs/beta-qualification.md; the shipped
# claude adapter declares `shell` and still cannot run one command on its
# implement path), so reading a declaration as permission to skip an operator's
# own gate is precisely how an actor would self-declare its way past it. The
# composition below makes that structurally impossible rather than merely
# unintended.
#
# Pure policy, like lib/drive.sh: every function below READS (task
# frontmatter, config, plugin manifests) and prints. The acknowledgement itself
# has exactly one writer, the `orchid task handoff` verb (libexec/orchid-task).
#
# Source AFTER lib/common.sh, lib/frontmatter.sh, lib/manifest.sh,
# lib/resolver.sh, lib/review.sh and lib/capability.sh -- the capability arm
# asks review_implementer_engine which actor built this candidate, and
# lib/capability.sh whether the `mechanical` step may be routed to it.

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

# handoff_capability_gate <repo> <task-id> -- the OTHER arm: exactly one line,
# "<required|off><TAB><why>", derived from what the actor that built this
# candidate declares rather than from what an operator remembered to configure.
#
# WHICH ACTOR. review_implementer_engine: the task's recorded
# `implementer_engine_id` when it has one (kernel-derived, written only by
# `task advance implementing->testing` from the accepted implement envelope, so
# it names the engine that ACTUALLY produced this candidate even when a
# failover moved off the chain's first entry), else the role's binding. Asking
# the binding alone would answer for the wrong engine on precisely the runs
# where failover happened.
#
# AN ACTOR THIS GATE CANNOT IDENTIFY IS REFUSED, NEVER PERMITTED. The step table
# separates "declared short" (its exit 1) from "no manifest could be read at
# all" (its exit 2) so that each caller may answer them differently; this arm
# turns the pause ON for both -- and for any other nonzero answer it does not
# recognise, since only a clean 0 is evidence of anything. A gate that reports
# no objection about an engine it could not even name is not a gate, it is a
# hole.
#
# BUT "CANNOT IDENTIFY" IS A LAST RESORT, NOT A CATEGORY FOR THIRD-PARTY
# PLUGINS. Their manifests carry QUALIFIED ids (`acme/foo`), and the field this
# arm reads records the implement envelope's id verbatim apart from the
# `orchid/` vendor prefix libexec/orchid-task strips -- so `acme/foo` is what a
# healthy third-party implementer looks like here. It is not an unknown: the
# field holds that id BECAUSE orchid minted, launched and reconciled a job for
# that plugin. Refusing on the qualified form would hold every candidate a
# third-party engine builds at a hand-off with no exit -- no act an operator can
# perform makes an unresolvable name resolve -- which is the same INV-14
# violation as waiving the pause for them, reached from the other side and
# costing every attempt instead of one. So the actor is RESOLVED by either name
# it answers to (lib/resolver.sh's resolve_engine_dir_any: the install directory
# a binding uses, or the qualified id an installed manifest claims), and the
# refusal is kept for the actor that is genuinely not installed under either.
#
# AND THE NAME IS NEVER GUESSED AT. Resolution by id matches a manifest's `id=`
# WHOLE; no arm here strips a vendor prefix and retries the basename, because
# `acme/foo` and `zzz/foo` both fall to a directory called `foo` and a lookup
# that succeeded there would be reporting on some other publisher's manifest --
# the same shadowing INV-10 refuses elsewhere, arrived at by being helpful. When
# resolution does fail the refusal SAYS the plugin is not installed under either
# name, which is a thing an operator can act on (install it, or bind the role to
# the name it is installed under) rather than a verdict about capabilities
# nothing ever read.
#
# The cost of being wrong in this direction is one operator command (`orchid
# task handoff <id> --ack`, which every hand-off already needs); the cost of the
# other is a candidate verified after a mechanical step nobody could perform --
# the whole class of loss this file exists to end. A repository whose engines
# are merely not installed yet dispatched nothing in the first place, so it has
# no candidate here to hold.
handoff_capability_gate() {
  local repo="$1" id="$2" engine why rc
  engine="$(review_implementer_engine "$repo" "$id" 2>/dev/null || true)"
  rc=0
  why="$(capability_routing_refusal mechanical "$engine")" || rc=$?
  # ONLY 0 TURNS THE PAUSE OFF. `mechanical` is a literal here, so the table's
  # caller-error answer (3) cannot happen today -- and a catch-all `*)` that
  # printed `off` would mean the day it could, this arm would report no
  # objection about a step it never managed to price. That is the fail-open
  # shape three paragraphs above refuse in every other direction; an outcome
  # this arm does not understand is one more reason to stop, never a reason to
  # proceed.
  case "$rc" in
    0) printf 'off\tthe actor that built this candidate (%s) declares what the mechanical step needs\n' "${engine:-none}" ;;
    1) printf 'required\t%s\n' "$why" ;;
    2) printf 'required\t%s — a capability gate that cannot identify the actor refuses rather than permits, so an operator performs the mechanical steps for this candidate (or installs that plugin, or binds the role to the name it is installed under)\n' "$why" ;;
    *) printf 'required\tthe mechanical step could not be priced at all (%s) — an unpriced step is held for an operator rather than waived\n' "$why" ;;
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
# who acknowledges, then commits once more (a second lint fix, a mode bit they
# restored after re-reading the diff) leaves the record naming a tree that no
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
  local capline capmode capwhy asked
  # Both arms are consulted before anything else, and the pause is off only
  # when BOTH are (see this file's header: they compose, they do not override).
  capline="$(handoff_capability_gate "$repo" "$id")"
  capmode="$(printf '%s' "$capline" | cut -f1)"
  capwhy="$(printf '%s' "$capline" | cut -f2-)"
  if [ "$(handoff_gate_mode "$repo")" = off ] && [ "$capmode" = off ]; then
    printf 'off\tthe handoff_before_verify gate is off for this repository, and %s\n' "$capwhy"
    return 0
  fi
  # WHICH ARM ASKED, carried into the first line an operator actually meets. A
  # pause nobody configured, arriving with no explanation, reads as a bug in
  # the driver rather than as the routing refusal it is -- and the fix
  # (perform the step, or bind an implementer whose manifest covers it) is not
  # guessable from the stop alone.
  asked="the handoff_before_verify gate asks for it"
  [ "$capmode" != required ] || asked="$capwhy"
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
    printf 'outstanding\tno operator hand-off is recorded for candidate %s (%s)\n' "$cand" "$asked"
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

# ---------------------------------------------------------------------------
# THE OPERATOR PREREQUISITE (T024, dogfood F26)
# ---------------------------------------------------------------------------
# The second operator-owned stop at the same point in the procedure, and a
# DIFFERENT thing from the hand-off above. The distinction is worth stating
# once, because the two are easy to conflate and their remedies do not
# substitute for one another:
#
#   the hand-off       mechanical work INSIDE the candidate that requires
#                      execution -- a lint fix, a checksum re-pin, a mode bit.
#                      It produces a COMMIT, so acknowledging it ADVANCES
#                      `candidate_sha` onto that commit. It is asked for by
#                      repository CONFIG (`handoff_before_verify`) and so
#                      applies to every task in the repository alike.
#   the prerequisite   a step OUTSIDE this repository that the candidate's
#                      verification depends on -- canonically applying, to the
#                      database the suite runs against, the migration this very
#                      task authored. It produces NO commit and the candidate
#                      does not move; what changes is the world the suite runs
#                      in. It is DECLARED PER TASK, at planning time, because
#                      only some tasks have one.
#
# So a task can be held by both, or by either, and clearing one says nothing
# about the other. What they share is the shape of the record -- an
# acknowledgement bound to a candidate_sha, satisfied only while it still
# names the current one -- which is why the policy for both lives here.
#
# Two plain frontmatter fields, no new storage:
#
#   operator_prerequisite -- the declaration. Written when the task is
#                            PLANNED (`orchid task set <id>
#                            operator_prerequisite "..."`), because the
#                            implementer never can: its commits may not touch
#                            `.orchid/` at all (INV-04 refuses entry to
#                            `testing` over it), so a task cannot declare its
#                            own prerequisite from inside the sandbox.
#   prerequisite_ack      -- the candidate_sha the operator acknowledged it
#                            for. Single-writer (`orchid task prereq-ack`),
#                            and cleared wherever prior verify evidence is
#                            invalidated -- entry to rework, unblock,
#                            retry -- so a reworked candidate, whose
#                            migration may be a different migration, always
#                            re-asks.

# handoff_prereq_unmet <task-file> -- 0 iff this task declares an OPERATOR
# PREREQUISITE and nobody has acknowledged that step for the current
# candidate.
#
# The ack SATISFIES the gate only while it still names the current
# `candidate_sha`, and that comparison -- not the clears listed above -- is
# what makes the binding real. The clears cannot carry it alone: they fire on
# the three paths that route through `rework`, and the sharpest way a
# candidate is superseded routes through none of them. libexec/orchid-merge's
# rebase-reset takes a task straight from `merging` back to `testing`, sets a
# NEW `candidate_sha` and deletes the verify evidence, without any advance to
# `rework` -- so a bare non-empty test would let an ack for the pre-rebase
# candidate wave through a suite run against a rebased one, which is exactly
# the reading ("someone applied the migration this candidate needs") the field
# exists to make impossible. Superseded means unmet, at the moment the SHA
# moves, whatever moved it. The two mechanisms are complements: the clears
# cover the window where the candidate is about to be replaced but the SHA has
# not moved yet (rework is entered before the next attempt commits anything),
# the comparison covers every way the SHA moves without passing through it.
# `handoff_state` above binds its own acknowledgement by the same rule, for
# the same reason.
#
# An empty ack is unmet by the same rule and is checked first only to keep the
# diagnostic honest: `candidate_sha` is itself empty before `testing`, and
# comparing empty to empty would read "acknowledged" for a task nobody has
# acknowledged anything about.
#
# UNLIKE `handoff_state`, this reads ONE task file and nothing else -- no
# config, no git, no repo. That is not an oversight: the declaration IS the
# gate (there is no config key to turn it on, because a task that needs a
# migration applied needs it applied in every repository), and the candidate
# does not move across the pause, so there is no HEAD to compare and no tree
# whose cleanliness could mean anything here. It is also why four verbs can
# call it cheaply: libexec/orchid-verify and libexec/orchid-merge (the two
# verbs that run the suite against the store — both refuse rather than run it,
# on this one predicate, so the two stages cannot disagree about the same
# condition), runners/orchid-drive (raises the boundary instead of spending a
# round) and libexec/orchid-status (says why the task is parked, at either
# stage).
#
# `orchid task prereq-ack` is deliberately NOT among them, and the omission is
# a decision rather than a gap: it is the verb that SETTLES this predicate, so
# gating it on the predicate would refuse exactly the operator whose ack is
# already current — someone who re-applied the migration after a store reset
# and wants the journal to say so, or who simply ran the command twice. Its own
# preconditions (a declaration to acknowledge, a `candidate_sha` to bind to, a
# status where something reads the field) are the ones that mean anything for a
# write; "is it already satisfied" means nothing for one. Every caller above
# READS the gate to decide whether to proceed; the ack verb is the only one
# that answers it, and an answer does not need permission from the question.
# tests/test_task.sh pins the re-acknowledgement as accepted and idempotent.
handoff_prereq_unmet() {
  local f="$1" ack
  [ -f "$f" ] || return 1
  [ -n "$(fm_get "$f" operator_prerequisite)" ] || return 1
  ack="$(fm_get "$f" prerequisite_ack)"
  [ -n "$ack" ] || return 0
  [ "$ack" != "$(fm_get "$f" candidate_sha)" ]
}

# handoff_prereq_stale <task-file> -- 0 iff the gate is unmet SPECIFICALLY
# because the acknowledgement on file names a candidate this task has since
# superseded (as opposed to there being no acknowledgement at all). Callers
# use it for one thing only: a refusal that says "the ack you are looking at
# is for the previous candidate" instead of "unacknowledged" while a
# non-empty `prerequisite_ack` sits in the frontmatter contradicting it.
# Never a second gate -- handoff_prereq_unmet above is the only predicate
# anything decides on.
handoff_prereq_stale() {
  local f="$1" ack
  handoff_prereq_unmet "$f" || return 1
  ack="$(fm_get "$f" prerequisite_ack)"
  [ -n "$ack" ]
}
