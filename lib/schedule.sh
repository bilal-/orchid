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
#                                       separated inside one predicate.
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
  for d in $deps; do
    [ "$(fm_get "$state/tasks/$d.md" status 2>/dev/null)" = done ] || unmet="$unmet $d"
  done
  [ -z "$unmet" ] || echo "waiting-deps ($(printf '%s' "${unmet# }"))"
}
