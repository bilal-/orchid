#!/usr/bin/env bash
# Kernel-owned hook points (docs/specs/plugins.md, Hooks section; v1-m3).
# This file is a pure LIB: it only ever reads config and prints parsed
# results -- it never mutates durable state (INV-01-clean). Hook results are
# APPLIED only by the orchestrator, through tier-1 verbs, once PROTOCOL
# wiring lands (v1-m3 Task 6); nothing in this file writes anywhere.
#
# Callers must source lib/common.sh (config_get) and lib/manifest.sh
# (_manifest_split_csv, reused here for the same bash-3.2-safe trimmed-split
# reason lib/archetype.sh/lib/schedule.sh/lib/capsuite.sh already document)
# before this file.

# The closed set of hook points -- kernel-owned, never extended by a plugin
# or config value (a `hook.<point>=` binding for anything outside this set
# is a configuration error, not a new point). Space-padded so membership can
# be tested with a plain substring match (`*" $x "*`), the same idiom
# lib/manifest.sh's _MANIFEST_KNOWN_KEYS already uses.
_HOOK_POINTS=" after_plan_draft before_arbitration on_verify_fail before_merge on_blocker "

hook_point_valid() {  # point -> exit 0 iff it's one of the five kernel-owned points
  case "$_HOOK_POINTS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# hooks_for <repo> <point> -- prints the ordered `hook.<point>=` binding, one
# "plugin-id<TAB>required|optional" line per entry, order preserved (the
# first entry is the point's primary handler). An unbound point (no
# `hook.<point>=` config value anywhere) prints nothing and still exits 0 --
# absence is not itself an error at this layer; callers (jobs prepare, and
# eventually the merge gate in Task 6) decide what an unbound point means.
hooks_for() {
  local repo="$1" point="$2" v tok id req
  v="$(config_get "$repo" "hook.$point")"
  [ -n "$v" ] || return 0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    case "$tok" in
      *:required) id="${tok%:required}"; req=required ;;
      *) id="$tok"; req=optional ;;
    esac
    printf '%s\t%s\n' "$id" "$req"
  done < <(_manifest_split_csv "$v")
}

# hook_timeout_s <repo> -- the per-hook-job wall-clock budget in seconds;
# default 600 (10 minutes), same config_get default-arg convention every
# other *_s config key already uses.
hook_timeout_s() {
  config_get "$1" hook_timeout_s 600
}
