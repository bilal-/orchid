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

# lib/findings.sh, sourced relative to THIS file's own directory -- the same
# deliberate exception, for the same reason, that lib/pack.sh already makes to
# source this file (tests/test_rework.sh and tests/test_pack.sh source these
# libraries directly, with no ORCHID_ROOT set at all). findings.sh sources
# nothing itself, so there is no cycle, and it declares no readonly state, so
# re-sourcing it inside a verb that already has it (libexec/orchid-task,
# runners/orchid-drive) only redefines identical functions.
#
# SOURCED RATHER THAN RE-IMPLEMENTED, because exactly one function may own the
# rule for reading a log's `candidate:` claim. findings_log_candidate stops at
# the bare `---`, so a test that PRINTS a `candidate: ` line of its own can
# never impersonate the header field the binding below trusts -- and a second
# copy of that parse living here would be one edit away from disagreeing with
# the brief mechanism it has to agree with.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/findings.sh"

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

# rework_evidence_bound <log> <candidate> -- 0 iff <log>'s own header claims it
# was produced against <candidate>.
#
# THE SAME RULE lib/findings.sh already applies to the locations it quotes into
# a task body (T010), applied to the bytes this file carries into the next
# attempt's pack. Evidence handed to an attempt must belong to the candidate
# that failed: a log describing a candidate that no longer exists is not a
# weaker version of the previous attempt's failure, it is a different task's
# answer wearing this one's heading -- and the brief around it says "you
# already tried this and got exactly this", which about the wrong candidate is
# simply false.
#
# Three ways a log fails to bind, all of them a refusal:
#   * it names a DIFFERENT candidate (superseded);
#   * it carries no `candidate:` header at all (an older kernel wrote it:
#     unbindable, and an absence of a claim is not a claim);
#   * <candidate> is empty or `none` -- there is nothing to bind TO, and two
#     vacuous sentinels agreeing is not proof (the same trap the
#     `testing -> reviewing` sha compare avoids by excluding `none`).
rework_evidence_bound() {
  local log="$1" cand="${2:-}"
  [ -n "$cand" ] && [ "$cand" != none ] || return 1
  [ -f "$log" ] || return 1
  [ "$(findings_log_candidate "$log")" = "$cand" ]
}

# rework_evidence_current <state> <id> <candidate> -- 0 iff the newest CAPTURED
# round is usable as <candidate>'s previous failure: it exists, it is not a
# torn zero-byte write, and its header binds it to <candidate>.
#
# The read end of the binding, and it closes a window the write end cannot see.
# A round is captured against the candidate that failed, and the candidate then
# MOVES: the reworking implementer commits, `orchid merge`'s rebase arm mints a
# new candidate_sha, or an operator re-derives the branch. Every one of those
# leaves the last captured round describing a tree that is no longer under
# work. Feeding it forward would tell the next attempt that its CURRENT code
# produced that output, which is exactly the "you already tried this" claim
# inverted into a false one -- so a brief that cannot bind is not shipped at
# all, and the pack records the omission rather than quietly narrowing what it
# says.
rework_evidence_current() {
  local state="$1" id="$2" cand="${3:-}" latest
  latest="$(rework_latest_log "$state" "$id" 0)" || return 1
  [ -s "$latest" ] || return 1
  rework_evidence_bound "$latest" "$cand"
}

# rework_evidence_source <state> <id> <from-status> [candidate] -- which log
# documents the failure that is causing THIS rework, or nothing when no failing
# evidence exists.
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
#
# THE `candidate` ARGUMENT IS WHAT KEEPS THE MERGING ARM HONEST, and it is not
# hypothetical: `orchid merge`'s rebase arm mints a NEW candidate_sha under a
# tree whose <id>-merge.log is still on disk, and the `merging` arm of `task
# advance rework` deliberately exempts that log from its invalidating delete
# (so the failure it is about to journal keeps its evidence). A superseded
# merge log therefore sits in exactly the place this function looks, reads
# exactly like a current one, and would be captured as this round's failure,
# digested into this round's signature, and counted toward the streak that
# reroutes the role and blocks the task for not converging. So the log must
# CLAIM the candidate the caller is reworking. Absent (the caller has no
# candidate to bind to, e.g. a direct unit call), the check is skipped rather
# than failed -- there is nothing to compare against, and refusing every
# capture on that basis would make the feature inert instead of careful.
rework_evidence_source() {
  local state="$1" id="$2" from="$3" cand="${4:-}" src=""
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
  # A non-empty partial write is no more trustworthy than a zero-byte one.
  # The verifier's bare `---` terminates the volatile header; without it,
  # rework_signature discards the entire file as header and returns the same
  # digest for every such truncation. Two torn writes would therefore look
  # like one byte-identical candidate failure repeating and could reroute or
  # block the task on evidence that contains no completed header or output.
  grep -qx -- '---' "$src" || return 1
  [ "$(tail -n1 "$src")" != "exit: 0" ] || return 1
  if [ -n "$cand" ]; then
    rework_evidence_bound "$src" "$cand" || return 1
  fi
  printf '%s\n' "$src"
}
