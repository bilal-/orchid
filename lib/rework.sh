#!/usr/bin/env bash
# Rework evidence: capturing the failure that CAUSED a rework, and deciding
# whether the loop is converging. See docs/specs/kernel.md (Attempt fairness)
# and PROTOCOL.md (THE TICK, the `testing` FAIL arm).
#
# The defect this closes (dogfood finding F27, lesson L023). `orchid task
# advance <id> rework` deletes reviews/<id>-verify.log unconditionally, while
# the very same call journals the reason "verify failed: see
# .orchid/reviews/<id>-verify.log". The pointer dangles the instant it is
# written, so the next attempt's implementer arrives with nothing to act on:
# not because the brief forgets to mention the failure, but because the
# failure output is destroyed before anything can read it. A run then produces
# byte-identical failures attempt after attempt -- the loop feeds back the
# same information and gets the same answer.
#
# The deletion itself is CORRECT and stays: it arms INV-11's gate so a stale
# PASS can never satisfy a later `testing -> reviewing` advance. So the
# evidence is COPIED first, into a round-scoped path
# (`reviews/<id>-r<n>-rework.log`) that no evidence gate anywhere accepts:
#
#   * INV-11's gate reads exactly `reviews/<id>-verify.log` -- a literal
#     path, not a glob, so `<id>-r1-rework.log` can never satisfy it;
#   * every envelope glob in the kernel (`<id>-a<attempt>-reviewer*.json`,
#     `-implementer*.json`, `-hook-<point>*.json`, and pack.sh's
#     `<id>-a<attempt>-*.json`) matches `-a<attempt>-` and `.json`, neither of
#     which this name carries.
#
# It is evidence for a HUMAN and for the next attempt's input pack, and for
# nothing else.

# rework_log_path <state> <id> <round> -- the round-scoped capture path.
rework_log_path() { printf '%s/reviews/%s-r%s-rework.log\n' "$1" "$2" "$3"; }

# rework_rounds_present <state> <id> -- every captured round number for this
# task, ascending, one per line. Numeric-only (a hand-dropped
# `<id>-rXX-rework.log` is skipped rather than crashing the sort), and
# numerically sorted so round 10 never sorts before round 9.
rework_rounds_present() {
  local state="$1" id="$2" f base n
  for f in "$state/reviews/$id-r"*"-rework.log"; do
    [ -e "$f" ] || continue
    base="${f##*/}"; n="${base#"$id-r"}"; n="${n%-rework.log}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$n"
  done | sort -n
}

# rework_latest_log <state> <id> [back] -- the captured evidence file for the
# most recent round (back=0, the default), the round before it (back=1), and
# so on. Exit 1 with no output when that many rounds were never captured.
#
# Indexed off the ROUNDS ACTUALLY ON DISK rather than off `attempts`: the two
# deliberately do not track each other. `--waive-attempt` leaves `attempts`
# unchanged, so two consecutive rework rounds can share one attempt number,
# and an `attempts`-keyed name would have the second round silently overwrite
# the first -- destroying exactly the older half of the pair a
# did-anything-change comparison needs.
rework_latest_log() {
  local state="$1" id="$2" back="${3:-0}" rounds count idx n path
  rounds="$(rework_rounds_present "$state" "$id")"
  [ -n "$rounds" ] || return 1
  count="$(printf '%s\n' "$rounds" | wc -l | tr -d ' ')"
  idx=$(( count - back ))
  [ "$idx" -ge 1 ] || return 1
  n="$(printf '%s\n' "$rounds" | sed -n "${idx}p")"
  path="$(rework_log_path "$state" "$id" "$n")"
  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

# rework_signature <evidence-file> -- a stable digest of WHAT FAILED, so two
# rounds can be compared for "did anything at all change".
#
# Both evidence shapes this kernel writes (`orchid verify`'s
# <id>-verify.log and `orchid merge`'s <id>-merge.log) share one header
# format: a block of `key: value` lines, a bare `---`, the combined output,
# then `exit: <code>`. The header is where the volatility lives, so the
# header is dropped wholesale and exactly one line is KEPT out of it:
# `command:`. The output body and the exit code are kept too, because a
# change in any of those is a real change in what failed.
#
# A KEEP-LIST, not a drop-list, and that is the whole point. Written as
# "drop date/sha/candidate/cwd" it silently goes stale the moment anything
# adds a header line -- and something already has: `orchid verify` also
# writes T019's prestate block (`prestate:`, `pre_base_sha:`,
# `pre_exec_missing:`, `pre_env_missing:`, `pre_env_inventory:`,
# `pre_pin_stale:`, `pre_integration_head:`; see drive_verify_prestate_headers
# in lib/drive.sh). `pre_integration_head` is the integration checkout's HEAD,
# which moves every time ANY OTHER TASK MERGES. An enumerated drop-list
# therefore gives two byte-identical failures two different signatures for no
# reason connected to the failure, on a busy run almost every time -- the
# streak never reaches 2, the brief tells the next attempt this failure is
# new when it is not, and neither the failover nor the non-convergence stop
# can ever fire. That is this whole feature silently inert in exactly the
# multi-task run it was written for (dogfood finding F27), so the safe
# default has to be "an unrecognised header line is volatile until proven
# otherwise" rather than the reverse.
#
# Header-scoped, not file-wide: the drop only applies before the first bare
# `---`, so a test whose OUTPUT happens to print a line starting `sha: ` still
# contributes to the signature.
rework_signature() {
  [ -f "$1" ] || return 1
  awk '
    h==0 && $0=="---" { h=1; print; next }
    h==0 && index($0,"command: ")==1 { print; next }
    h==0 { next }
    { print }' "$1" | _orchid_stream_sha256
}

# rework_evidence_source <state> <id> <from-status> -- which log documents the
# failure that is causing THIS rework, or nothing when no failing evidence
# exists.
#
# `merging -> rework` is the validation-failure path: `orchid merge` re-ran
# the suite in its own temp worktree and wrote <id>-merge.log, and the task's
# own <id>-verify.log is a PASS from before the merge (which is exactly why
# that arm exempts merge.log from the invalidating delete). Every other rework
# entry is documented by <id>-verify.log.
#
# In both cases a PASSING log is not evidence of a failure and is never
# captured: `merging -> rework` can also be reached by a rebase CONFLICT,
# which writes no merge log at all and leaves a passing verify log behind.
# Capturing that would hand the next attempt a green suite as its "previous
# failure" -- worse than handing it nothing.
rework_evidence_source() {
  local state="$1" id="$2" from="$3" src=""
  if [ "$from" = merging ] && [ -f "$state/reviews/$id-merge.log" ]; then
    src="$state/reviews/$id-merge.log"
  elif [ -f "$state/reviews/$id-verify.log" ]; then
    src="$state/reviews/$id-verify.log"
  fi
  [ -n "$src" ] || return 1
  # A ZERO-BYTE log is not evidence either, and its absence is the more
  # dangerous of the two: an empty file has a perfectly stable digest, so two
  # torn writes in a row read as ONE IDENTICAL FAILURE REPEATING. The driver
  # would then reroute the role to another engine and block the task as "not
  # converging" on the strength of no output at all -- a confident,
  # fully-journalled judgment derived from nothing. `orchid verify` always
  # writes at least a header and an `exit:` line, so this is a torn or
  # truncated file rather than an ordinary one, and refusing to capture it
  # degrades to the pre-T025 behaviour (no captured round, streak untouched)
  # rather than to a wrong one. lib/pack.sh guards the same shape at the READ
  # end; this is the write end, and it is the one that keeps the counters
  # honest.
  [ -s "$src" ] || return 1
  [ "$(tail -n1 "$src")" != "exit: 0" ] || return 1
  printf '%s\n' "$src"
}
