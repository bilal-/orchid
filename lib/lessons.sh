#!/usr/bin/env bash
# lib/lessons.sh -- cross-run lessons.md parsing/mutation helpers (v1-m3
# Task 11, docs/specs/kernel.md's "Cross-run lessons" section).
#
# Deliberately self-contained (no `source`s of its own, unlike libexec/*
# verbs which assume the caller already sourced lib/common.sh etc in a
# fixed order): lib/pack.sh -- one of this file's callers -- is sourced
# DIRECTLY by several test files with no ORCHID_ROOT set at all
# (tests/test_pack.sh, tests/test_hooks.sh, tests/inv/test_INV-12_pack_
# overflow.sh, tests/test_review_routing.sh), so lib/pack.sh resolves this
# file relative to its OWN directory rather than via "$ORCHID_ROOT/lib/...".
# Every function below is pure awk/bash text processing; none of it needs
# atomic_write/config_get, so no dependency on lib/common.sh is needed here
# either -- callers that DO mutate lessons.md (libexec/orchid-lessons,
# libexec/orchid-run) pipe this file's output through their own
# already-sourced atomic_write.
#
# lessons.md format (one block per lesson, kernel.md-normative):
#   ## L001 [active] repo
#   statement: <text>
#   evidence: <text>
#   first: <ISO8601>
#   last_confirmed: <ISO8601>
#   invalidate_when: <text>
# Blocks are delimited purely by "^## L" header lines -- a blank line
# between two blocks is just body content, never a parsed delimiter (same
# convention journal.md's own "## " entry headers use).

# lessons_active_only <lessons.md> -- every ACTIVE block verbatim (header
# line + its field lines, file order), or nothing when the file is absent
# or has no active blocks. Used by lib/pack.sh's lessons injection and by
# `orchid run new`'s carry-forward step.
lessons_active_only() {
  local src="$1"
  [ -f "$src" ] || return 0
  awk '
    /^## L/ {
      if (keep && buf != "") printf "%s", buf
      buf = $0 "\n"
      st = $0
      sub(/^## [^ ]+ \[/, "", st); sub(/\].*$/, "", st)
      keep = (st == "active")
      next
    }
    { buf = buf $0 "\n" }
    END { if (keep && buf != "") printf "%s", buf }
  ' "$src"
}

# lessons_list_blocks <lessons.md> -- tab-separated "id\tstate\tscope\tstatement",
# one line per block, file order.
lessons_list_blocks() {
  local src="$1"
  [ -f "$src" ] || return 0
  awk '
    /^## L/ {
      if (id != "") print id "\t" state "\t" scope "\t" stmt
      line = $0; sub(/^## /, "", line)
      n = split(line, a, " ")
      id = a[1]; state = a[2]; gsub(/[][]/, "", state); scope = a[3]
      stmt = ""
      next
    }
    index($0, "statement: ") == 1 { stmt = substr($0, 12) }
    END { if (id != "") print id "\t" state "\t" scope "\t" stmt }
  ' "$src"
}

# lessons_next_id <lessons.md> -- L00N, one past the highest existing
# numeric suffix regardless of state; L001 when the file is absent/empty.
lessons_next_id() {
  local src="$1" max=0 n
  if [ -f "$src" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      n=$((10#$n))
      [ "$n" -gt "$max" ] && max="$n"
    done < <(awk '/^## L[0-9]/{ id=$2; sub(/^L/,"",id); print id }' "$src")
  fi
  printf 'L%03d' $((max + 1))
}

# lessons_state <lessons.md> <id> -- just the [state] token for block <id>
# (empty if the block doesn't exist).
lessons_state() {
  local src="$1" id="$2"
  [ -f "$src" ] || return 0
  awk -v id="$id" '
    /^## L/ {
      line = $0; sub(/^## /, "", line); n = split(line, a, " ")
      if (a[1] == id) { st = a[2]; gsub(/[][]/, "", st); print st; exit }
    }
  ' "$src"
}

# lessons_set_state <lessons.md> <id> <new-state> -- stdout is the WHOLE new
# file content with block <id>'s header state token rewritten in place;
# every other line, and every other block, passes through byte-identical.
# Caller pipes to atomic_write.
lessons_set_state() {
  local src="$1" id="$2" new="$3"
  awk -v id="$id" -v new="$new" '
    /^## L/ {
      line = $0; sub(/^## /, "", line); n = split(line, a, " ")
      if (a[1] == id) sub(/\[[^]]*\]/, "[" new "]")
      print; next
    }
    { print }
  ' "$src"
}

# lessons_set_field <lessons.md> <id> <field> <value> -- stdout is the whole
# new file content with one field line inside block <id> rewritten (field
# must already exist in that block -- guaranteed, every block is written
# with the full fixed field set). Caller pipes to atomic_write.
lessons_set_field() {
  local src="$1" id="$2" field="$3" val="$4"
  awk -v id="$id" -v field="$field" -v val="$val" '
    /^## L/ {
      line = $0; sub(/^## /, "", line); n = split(line, a, " ")
      insec = (a[1] == id)
      print; next
    }
    insec && index($0, field ": ") == 1 { print field ": " val; next }
    { print }
  ' "$src"
}

# _lessons_journal_start_date <journal.md> -- the ISO8601 date token of the
# FIRST entry in journal.md (its header line is "## <ISO8601> <task|run>
# <kind> (<actor>)"), or empty when the file is absent or has no entries
# yet. Used by `lessons consolidate` as the "current run" boundary: a run
# rollover (`orchid run new`) always starts a FRESH journal.md whose first
# entry is the rollover's own `intervention` record, so the oldest entry in
# the CURRENT journal.md is exactly this run's start; on a run that has
# never rolled over there is no such boundary (returns empty), so
# consolidate's age-based drop is a deliberate no-op rather than a guess.
_lessons_journal_start_date() {
  local jf="$1"
  [ -f "$jf" ] || return 0
  awk '/^## [0-9][0-9][0-9][0-9]-/{print $2; exit}' "$jf"
}
