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
#   review-evidence   -- missing/malformed/non-ok/stale/incomplete evidence
#   review-conflict   -- request-changes, blocking finding, mixed verdicts,
#                        or a review that did not cover the whole scope
#   hook-failure      -- a `:required` hook binding has no ok, current envelope
#   worktree-conflict -- a dispatch worktree cannot be proven to belong to
#                        this task/repo/branch
#   operator-decision -- everything else this policy deliberately refuses to
#                        decide (attempts exhausted, wallclock budget, a
#                        status/archetype combination with no declared edge)
_DRIVE_BOUNDARY_KINDS=" planning blocked-task review-evidence review-conflict hook-failure worktree-conflict operator-decision "

drive_boundary_kind_valid() {  # kind -> 0 iff kernel-owned
  case "$_DRIVE_BOUNDARY_KINDS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# drive_boundary_priority <kind> -- 1 when a woken orchestrator can actually
# RESOLVE a boundary of this kind with the verbs its brokered command surface
# admits (runners/orchid-orchestrator-command: exact reads plus `orchid task
# arbitrate`, journal/lesson, notify, `run boundary clear`), 0 when only an
# operator can.
#
# Only the two review kinds are resolvable: they are settled by reading the
# evidence and recording one `orchid task arbitrate`. `blocked-task` is the
# case this exists for -- `orchid task unblock`/`task retry` are operator
# verbs the broker refuses, so a blocked task raises the SAME boundary on
# every pass, forever, until a human intervenes. With one boundary recorded
# per pass in task-id order, an unresolvable boundary on a low-numbered task
# would otherwise mask every later task's arbitrable one indefinitely, at one
# LLM wakeup per pump cycle spent on a decision the woken model has no verb
# to make. Ranking, not suppression: PROTOCOL.md requires a blocked task to
# be a boundary (it is how an operator learns the run is parked), so it is
# still recorded whenever nothing arbitrable outranks it.
drive_boundary_priority() {
  case "$1" in
    review-evidence|review-conflict) echo 1 ;;
    *) echo 0 ;;
  esac
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
#   evidence<TAB><detail>   missing, malformed, non-ok or incomplete evidence
#                           FOR THE CURRENT candidate_sha.
#   conflict<TAB><detail>   a request-changes verdict, a finding at or above
#                           blocking_severity, mixed verdicts, or a review
#                           that reports scope_complete false.
#
# The three arms are mutually exclusive and evaluated in that order, so an
# incomplete review set is never also reported as a conflict (and vice
# versa). No prose is parsed anywhere: every input is a structured envelope
# field the kernel already validates.
#
# SCOPING FIRST, exactly like the kernel's own reviewing->arbitrating gate
# (libexec/orchid-task): the evidence set is the envelopes BOUND TO THE
# TASK'S CURRENT candidate_sha, and every malformed/non-ok/incomplete test
# below is applied WITHIN that set. An envelope carrying a different
# candidate_sha is SUPERSEDED -- a sibling left behind by a relaunched
# reviewer slot, or by the merging->testing rebase edge moving candidate_sha
# under a review that already landed -- and is ignored, never boundaried.
# Boundarying it would contradict the kernel gate (which counts the current
# ones and ignores the rest), make two truth-table arms match the same state,
# and pin the task in `arbitrating` with no verb able to release it. Anything
# that IS bound to the current candidate and is not a valid `ok` envelope
# still fails closed to a boundary.
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
    # Step 1 -- scope. An envelope whose candidate_sha cannot be read at all
    # cannot be proven superseded, so it fails closed as malformed rather
    # than being silently dropped from the set.
    ecand="$(envelope_field "$f" '.candidate_sha // empty' 2>/dev/null || true)"
    if [ -z "$ecand" ]; then
      printf 'evidence\tmalformed review envelope %s: no readable candidate_sha to scope it by\n' "$base"
      return 0
    fi
    # Superseded sibling: bound to some OTHER candidate. Ignored outright.
    [ "$ecand" = "$cand" ] || continue
    # Step 2 -- everything below judges only envelopes bound to the CURRENT
    # candidate, and every one of them must be a valid `ok` envelope.
    if ! envelope_validate "$f" 2>/dev/null; then
      printf 'evidence\tmalformed review envelope %s\n' "$base"
      return 0
    fi
    status="$(envelope_field "$f" '.status // empty' 2>/dev/null || true)"
    if [ "$status" != ok ]; then
      printf 'evidence\treview envelope %s reports status %s, not ok\n' "$base" "${status:-none}"
      return 0
    fi
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
