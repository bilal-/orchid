#!/usr/bin/env bash
# lib/schedule.sh -- v1-m2 deterministic scheduling gates (docs/specs/
# kernel.md, "Scheduling rules (v1)": concurrency cap 2, `exclusive`/
# `resources` frontmatter gate parallelism, dependency-manifest tasks
# serialize). The predicate set has exactly ONE home: both `orchid task
# advance` (the kernel-side dispatch gate, pending/rework -> implementing)
# and `orchid status --explain` (the operator-facing "why didn't it dispatch"
# surface) call schedule_dispatch_blockers rather than each growing their own
# copy.
#
# T026 adds the OTHER runaway cap to the same file, for the same reason:
# schedule_attempt_budget (bottom) is the single home for the rework budget
# the driver stops at, shared by `runners/orchid-drive` and by the operator
# verbs that report and raise it.
#
# Source AFTER lib/common.sh (orchid_state, config_get), lib/frontmatter.sh
# (fm_get), and lib/manifest.sh (_manifest_split_csv, reused here for
# `resources` comma-list splitting -- same trimmed/empty-skipping behavior
# as every other comma-list field in this codebase).

# The kernel's "active" status set (docs/specs/kernel.md's loop section):
# a task counts against the concurrency cap, and against exclusive/resource
# overlap, for exactly as long as it sits in one of these. Space-padded for
# a substring-safe membership test (mirrors lib/archetype.sh's
# _ARCHETYPE_KERNEL_STATES convention).
_SCHEDULE_ACTIVE_STATUSES=" implementing testing reviewing arbitrating merging "

_schedule_active_status() {  # status -> 0 iff it counts as "active"
  case "$_SCHEDULE_ACTIVE_STATUSES" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# schedule_is_active_status <status> -- public wrapper over
# _schedule_active_status for callers outside this file. libexec/orchid-
# task's dispatch gate keys off this (rather than a literal `to =
# implementing` check) so a report-archetype task dispatching straight into
# an active status OTHER than implementing (e.g. the `review` archetype's
# pending:reviewing / rework:reviewing) is gated by
# schedule_dispatch_blockers exactly like a feature task's pending/rework ->
# implementing edge -- no archetype-name branching (INV-05), just "is the
# destination status one that counts as active".
schedule_is_active_status() {
  _schedule_active_status "$1"
}

# schedule_split_deps <value> -- the task ids in a `depends_on` frontmatter
# value, one per line, split on COMMAS as well as whitespace, empty tokens
# skipped. The single home for what separates two dependency ids: both the
# reader below and `orchid task set`'s write-time existence check split with
# this, so a value the writer accepted can never be re-read as a different
# set of ids.
#
# Commas are here because of dogfood finding F30, and the bug it names is
# the reason this is a function and not a bare `for d in $deps`. `depends_on:
# T002,T003` read by word splitting alone is ONE token, "T002,T003"; the
# reader then looks for `.orchid/tasks/T002,T003.md`, finds no file, reads no
# status, and the dependency can never equal `done` -- the task waits
# forever. What made it survive is the rendering: the unmet token joins back
# into `waiting-deps (T002,T003)`, which reads exactly like a correct
# two-dependency wait, so the predicate that was supposed to explain the
# stall was the thing hiding it.
#
# Two `tr` invocations rather than one with a bracket expression: `tr
# ',[:space:]' '\n'` relies on set2 being padded with its last character,
# which is not portable enough to rest a scheduling predicate on. Splitting
# is done by `tr` + `while read` rather than by unquoted word splitting so a
# hand-edited id containing a glob character is never expanded against the
# cwd.
schedule_split_deps() {
  local tok
  while IFS= read -r tok; do
    [ -n "$tok" ] && printf '%s\n' "$tok"
  done < <(printf '%s\n' "$1" | tr ',' '\n' | tr ' \t' '\n\n')
  # Same normalization lib/manifest.sh's _manifest_split_csv documents: a
  # `while read` loop exits with its final (EOF-failing) read's status, so an
  # empty `depends_on` would otherwise report failure to a caller that checks.
  return 0
}

# schedule_active_tasks <repo> -- ids whose status is currently active
# (implementing, testing, reviewing, arbitrating, merging), one per line, in
# task-file glob order. Empty output (no active tasks) is not an error.
schedule_active_tasks() {
  local repo="$1" state f st
  state="$(orchid_state "$repo")"
  for f in "$state/tasks"/*.md; do
    [ -e "$f" ] || continue
    st="$(fm_get "$f" status)"
    _schedule_active_status "$st" || continue
    fm_get "$f" id
  done
}

# schedule_dispatch_blockers <repo> <task> -- every blocking predicate for
# dispatching <task> (a pending or rework task) into `implementing` RIGHT
# NOW, one per line; empty output + exit 0 means dispatchable. Predicate
# strings are VERBATIM (docs/plans/2026-07-28-v1-m2-core-autonomy.md, Task
# 5), never reworded by a caller:
#
#   concurrency-cap (<n>/<cap>)     -- <n> tasks already active, at/over the
#                                       configured `concurrency` cap (default 2).
#   exclusive-overlap (<active-id>) -- <active-id> is exclusive, or THIS task
#                                       is exclusive and <active-id> is active
#                                       (either direction conflicts) -- one
#                                       line per conflicting active task.
#   resource-conflict (<res>: <active-id>) -- <res> appears in both this
#                                       task's and <active-id>'s comma-
#                                       separated `resources` lists -- one
#                                       line per (resource, active-id) pair.
#   waiting-deps (<id> ...)         -- this task's `depends_on` ids that have
#                                       not reached `done` yet, space-
#                                       separated inside one predicate,
#                                       however the frontmatter value itself
#                                       separated them (schedule_split_deps
#                                       accepts commas and whitespace; the
#                                       rendering is always space-separated,
#                                       one id per space).
#
# <task> is a task ID, not a path (mirrors archetype_transitions <name>).
schedule_dispatch_blockers() {
  local repo="$1" id="$2" state f
  state="$(orchid_state "$repo")"
  f="$state/tasks/$id.md"

  local cap n active a_id
  active="$(schedule_active_tasks "$repo" | grep -vxF "$id" || true)"
  n=0
  for a_id in $active; do n=$((n + 1)); done
  cap="$(config_get "$repo" concurrency 2)"
  # v1-m3 (m2 ledger finding): a hand-edited/misconfigured `concurrency`
  # config value must die cleanly here, not feed straight into the `-lt`
  # comparison below (bash's `[ "$n" -lt "$cap" ]` on a non-numeric operand
  # errors out with an unhelpful "integer expression expected" deep inside
  # an unrelated caller). Any leading-zero/zero form ("0", "00", "01", ...)
  # is rejected by `0*` too -- a cap of zero is never a legitimate
  # concurrency limit, only a misconfiguration, and "00" is all-digits so it
  # would otherwise slip past `*[!0-9]*` and get treated as the numeric 0 by
  # `-lt` below (permanently tripping concurrency-cap).
  case "$cap" in
    ''|*[!0-9]*|0*) orchid_die "concurrency must be a positive integer (got '$cap')" ;;
  esac
  [ "$n" -lt "$cap" ] || echo "concurrency-cap ($n/$cap)"

  local self_exclusive self_resources
  self_exclusive="$(fm_get "$f" exclusive)"
  self_resources="$(fm_get "$f" resources)"

  local a_exclusive a_resources sres ares
  for a_id in $active; do
    a_exclusive="$(fm_get "$state/tasks/$a_id.md" exclusive)"
    if [ "$a_exclusive" = true ] || [ "$self_exclusive" = true ]; then
      echo "exclusive-overlap ($a_id)"
    fi
    if [ -n "$self_resources" ]; then
      a_resources="$(fm_get "$state/tasks/$a_id.md" resources)"
      if [ -n "$a_resources" ]; then
        for sres in $(_manifest_split_csv "$self_resources"); do
          for ares in $(_manifest_split_csv "$a_resources"); do
            [ "$sres" = "$ares" ] && echo "resource-conflict ($sres: $a_id)"
          done
        done
      fi
    fi
  done

  local deps d unmet=""
  deps="$(fm_get "$f" depends_on)"
  # Process substitution, never a pipe: a `while read` on the right-hand side
  # of `|` runs in a subshell, and $unmet would be discarded with it.
  while IFS= read -r d; do
    [ "$(fm_get "$state/tasks/$d.md" status 2>/dev/null)" = "done" ] || unmet="$unmet $d"
  done < <(schedule_split_deps "$deps")
  [ -z "$unmet" ] || echo "waiting-deps ($(printf '%s' "${unmet# }"))"
}

# schedule_attempt_budget <repo> <task-id> -- the rework cap that applies to
# THIS task right now: the number of `attempts` at which the driver stops
# retrying and hands the task to a human. The SINGLE home for that number,
# for the same reason schedule_dispatch_blockers is the single home for the
# dispatch predicates: `runners/orchid-drive` enforces it and `orchid task
# retry`/`orchid task unblock` report against it, and two copies of a cap
# drift the moment one of them is made configurable.
#
# Two layers, most specific first:
#
#   1. the task's own `attempt_budget` frontmatter grant, written ONLY by
#      `orchid task retry --attempts N` (`task set` denies the key) -- the
#      operator's recorded "this task gets more rounds";
#   2. `rework_max` (config, default 3) -- the repo-wide budget, which used
#      to be a literal `attempts >= 3` in the driver with no way to change
#      it at all.
#
# WHY A BUDGET AND NOT A DECREMENT OF `attempts` (dogfood F28): the obvious
# reading of "grant an attempt" is "give back one of the ones spent". It is
# not available. `attempts` is the attempt NUMBER every per-attempt artifact
# is keyed on -- `reviews/<id>-a<attempts+1>-{implementer,reviewer}*.json`,
# read by `jobs prepare`, by both kernel envelope gates in `orchid task
# advance`, by `lib/drive.sh`'s review policy and by the driver's own
# implement-failure predicate. Winding it back would point the next attempt
# at a PREVIOUS attempt's envelopes: a stale non-ok implement envelope would
# read as this attempt's fresh failure, and a stale reviewer set as this
# attempt's reviews. So `attempts` stays strictly monotonic and the CAP is
# what moves.
schedule_attempt_budget() {
  local repo="$1" id="$2" state f v
  state="$(orchid_state "$repo")"
  f="$state/tasks/$id.md"
  v=""
  if [ -f "$f" ]; then
    v="$(fm_get "$f" attempt_budget)"
  fi
  [ -n "$v" ] || v="$(config_get "$repo" rework_max 3)"
  # Same fail-closed numeric guard, and the same `0*` rejection, the
  # concurrency cap above documents: a hand-edited/misconfigured value must
  # die cleanly here rather than feed a `-ge` comparison inside an unrelated
  # caller, and a zero budget is never a legitimate rework budget (it blocks
  # every task on its first verify failure) -- only a misconfiguration, with
  # "00" being all-digits and so otherwise slipping past `*[!0-9]*`.
  case "$v" in
    ''|*[!0-9]*|0*) orchid_die "attempt budget must be a positive integer (got '$v')" ;;
  esac
  echo "$v"
}
