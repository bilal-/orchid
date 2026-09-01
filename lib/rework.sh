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
#
# THE DELETE IS AT THREE DOORS, SO THE COPY IS TOO. `advance <id> rework` is
# the driver's route; `task unblock` and `task retry` are the operator's, and
# both end in `rework` with the same `rm -f` at the end of them. `retry` is the
# sharpest of the three, because the `attempts exhausted` stop parks the task
# at `blocked` -- an edge that neither captures nor deletes -- so the log of
# the run that spent the last attempt is intact right up until the operator
# grants another round, and granting it was what destroyed the evidence. The
# functions here are called by one composer in libexec/orchid-task
# (capture_rework_evidence) that all three verbs share; the rule for what
# counts as this round's failure must not vary by who sent the task round
# again. It does not: `rework_evidence_usable` is one predicate applied to
# BOTH evidence logs, and the door's `from` status decides only which of them
# is asked first. All three doors delete both logs, so all three read both --
# the `merging -> blocked` stop a red repo-wide `merge_gate` ends at leaves a
# PASSING verify log beside the failing merge log, and it is `retry`/`unblock`
# that arrive there.

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

# rework_retired_log_path <state> <id> <round> -- where a captured round goes
# once a PASSING verification has disproved it.
#
# WHAT A PASS DOES TO THE EVIDENCE, and it is the other half of the streak
# reset in the `testing -> reviewing` arm of `task advance`. That arm already
# ends the CONSECUTIVE-failure count on a verification that passed; the
# captured logs behind the count stayed on disk, and on the one path where the
# candidate does not move they stayed BOUND to it. So the next entry to
# `rework` fed the next attempt a failure of the very tree that had since
# verified green, under the brief's own sentence "the verbatim output of the
# run that FAILED is reproduced below" -- F27's claim inverted into a false
# one, which is the failure mode this whole feature exists to end rather than
# to reproduce one layer along.
#
# The route is the ordinary one, not a corner: `orchid verify` fails for a
# reason outside the candidate (a supervisor's environment override, a flake, a
# gate somebody else cleared), the round is captured, and the operator re-runs
# verification with NO implementer cycle -- `rework -> testing -> reviewing` on
# an unchanged `candidate_sha`. `task reverify` exists for precisely that move
# and consumes no attempt, so it is the cheap answer an operator reaches for
# first. The captured round names the candidate that is still under work, so
# every binding check above says yes, and only the PASS knows better.
#
# RENAMED, NOT DELETED. The bytes are the only surviving copy of that failure
# -- the kernel deleted the producer's own log on the rework edge that captured
# them -- and an operator asking "what was it failing on before it went green"
# has nowhere else to look. So the retirement is the same trick the capture
# itself plays on the evidence gates, one turn further on: keep the evidence,
# move it where no automatic reader accepts it. Deliberately NOT a name that
# still ends in `-rework.log` -- `rework_rounds_present` globs exactly that
# ending, and every reader above is indexed off it, so a retired round has to
# fall OUTSIDE the glob rather than merely decorate it.
#
# THIS FILE ONLY NAMES THE PATH; the kernel verb does the renaming. lib/rework.sh
# is one of the policy libraries INV-13 audits as read-only (it decides whether
# evidence is current and whether a streak has crossed the non-convergence
# threshold, verdicts that reroute an engine and raise a boundary), so a
# mutation living here would be a state write hidden behind a function call the
# driver's own audit cannot see. The rule for what a retired round is CALLED
# still belongs in one place, which is this one.
rework_retired_log_path() { printf '%s/reviews/%s-r%s-rework.retired.log\n' "$1" "$2" "$3"; }

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

# rework_evidence_recaptured <state> <id> <src> -- prints the captured round
# <src> duplicates, and exits 0, when <src> is byte-for-byte the log already
# filed as the newest round. Exit 1 (silently) otherwise.
#
# THE ONE STALENESS THE CANDIDATE BINDING CANNOT SEE, and it exists only while
# the candidate does NOT move. rework_evidence_bound refuses a log naming a
# SUPERSEDED candidate; a log naming the candidate still under work satisfies
# it every time, however old that log is. So on an unchanged candidate the same
# physical file can be read into two consecutive rounds. The route is not
# hypothetical: the `merging` arm of `task advance rework` deliberately exempts
# <id>-merge.log from its invalidating delete, and `orchid merge` can die
# BEFORE its own opening `rm -f` of a previous attempt's copy -- a run lock it
# did not get, which is the exact window runners/orchid-drive fingerprints the
# file across -- leaving that log on disk for the next `merging -> rework`.
#
# What it would cost is the whole convergence record. A re-read has, by
# construction, the digest of the round already filed: it would be counted as a
# repeat, reroute the role at two and block the task for not converging at
# three. An engine indicted and a loop declared stuck on the strength of ONE
# run counted twice -- the same false confidence the zero-byte guard above
# refuses, arriving by the one door a non-empty, well-formed, correctly-bound
# log walks straight through.
#
# RAW BYTES, NOT THE SIGNATURE, and that difference is the entire test.
# rework_signature deliberately drops the header, so "the same failure from a
# fresh run" and "the same file read twice" have the same digest -- which is
# right for the streak and useless here. The header is precisely what tells
# them apart: both producers stamp a per-run `date:` (and `sha:`/`cwd:`), so a
# genuine re-run differs there while a re-read cannot. Same discriminator, and
# the same content-not-mtime reasoning, as the merge-log fingerprint in
# runners/orchid-drive.
#
# Two real runs colliding on every one of those fields (identical output, same
# candidate, same working directory, inside one clock second) would be read as
# a re-read and skipped. That is the safe direction and the same one every
# other refusal here takes: the round is not filed and the streak is untouched,
# which is the pre-T025 behaviour, rather than a counter advanced on evidence
# that may not be a second run at all.
rework_evidence_recaptured() {
  local state="$1" id="$2" src="$3" latest
  [ -f "$src" ] || return 1
  latest="$(rework_latest_log "$state" "$id" 0)" || return 1
  cmp -s "$src" "$latest" || return 1
  printf '%s\n' "$latest"
}

# rework_streak_attributable <state> <id> -- 0 unless the newest CAPTURED round
# records a red repo-wide `merge_gate`.
#
# WHAT A REPEATED SIGNATURE IS EVIDENCE *ABOUT*. The streak's consumer that
# names a culprit is the driver's failover: two identical rounds mean "THIS
# ENGINE is not converging on THIS task", so the next attempt goes to another
# entry in the role's chain. A red `merge_gate` breaks that inference at the
# root. It is a check the REPOSITORY applies to everything, which this task was
# never asked about and no engine can turn green -- libexec/orchid-task says so
# in as many words beside the merging exemption ("the one merge failure that
# repeats identically until somebody outside this task acts"). It therefore
# satisfies the identical-signature test BY CONSTRUCTION, on the first repeat,
# for reasons that have nothing to do with whoever implemented the candidate.
#
# Rerouting on it spends a second engine's round on a condition it cannot fix
# and writes a durable journal line indicting the engine that ran, for an
# answer that was never its to give.
#
# THE CONVERGENCE STOP IS NOT SUPPRESSED BY THIS, and the asymmetry is the
# point: the loop really is stuck, and stopping it for a human is right whoever
# is at fault. Only the attribution to an engine is wrong, so only the
# attribution is withheld -- and the boundary the stop raises says which of the
# two it found. `orchid merge` keeps its own backstop for the gate either way
# (it charges the round and blocks the task once the budget is spent, with a
# repository-worded reason).
#
# Answers YES for a task with no captured round at all: an absence of evidence
# is not evidence of a gate failure, and a caller that has no streak to act on
# is not reading this anyway.
rework_streak_attributable() {
  local state="$1" id="$2" latest
  latest="$(rework_latest_log "$state" "$id" 0)" || return 0
  ! findings_log_gate_failed "$latest"
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

# rework_evidence_usable <log> [candidate] -- 0 iff <log> is a COMPLETE record
# of a FAILURE that binds to <candidate>. The whole of what disqualifies a log
# from being captured, asked in one place so that the two logs a rework can be
# documented by are judged by identical rules.
rework_evidence_usable() {
  local log="$1" cand="${2:-}"
  [ -f "$log" ] || return 1
  # A ZERO-BYTE log is not evidence, and its absence is the more dangerous of
  # the two: an empty file has a perfectly stable digest, so two torn writes in
  # a row read as ONE IDENTICAL FAILURE REPEATING. The driver would then
  # reroute the role to another engine and block the task as "not converging"
  # on the strength of no output at all -- a confident, fully-journalled
  # judgment derived from nothing. `orchid verify` always writes at least a
  # header and an `exit:` line, so this is a torn or truncated file rather than
  # an ordinary one, and refusing to capture it degrades to the pre-T025
  # behaviour (no captured round, streak untouched) rather than to a wrong one.
  # lib/pack.sh guards the same shape at the READ end; this is the write end,
  # and it is the one that keeps the counters honest.
  [ -s "$log" ] || return 1
  # A non-empty partial write is no more trustworthy than a zero-byte one.
  # The producer's bare `---` terminates the volatile header; without it,
  # rework_signature discards the entire file as header and returns the same
  # digest for every such truncation. Two torn writes would therefore look
  # like one byte-identical candidate failure repeating and could reroute or
  # block the task on evidence that contains no completed header or output.
  grep -qx -- '---' "$log" || return 1
  # A PASSING log is not evidence of a failure and is never captured:
  # `merging -> rework` can be reached by a rebase CONFLICT, which writes no
  # merge log at all and leaves a passing verify log behind. Capturing that
  # would hand the next attempt a green suite as its "previous failure" --
  # worse than handing it nothing.
  [ "$(tail -n1 "$log")" != "exit: 0" ] || return 1
  [ -z "$cand" ] || rework_evidence_bound "$log" "$cand"
}

# rework_evidence_source <state> <id> <from-status> [candidate] -- which log
# documents the failure that is causing THIS rework, or nothing when no failing
# evidence exists.
#
# TWO LOGS, ONE PREFERENCE, AND A FALLBACK TO THE OTHER. `merging -> rework` is
# the validation-failure path: `orchid merge` re-ran the suite in its own temp
# worktree and wrote <id>-merge.log, and the task's own <id>-verify.log is a
# PASS from before the merge (which is exactly why that arm exempts merge.log
# from the invalidating delete). Every other entry to rework is ordinarily
# documented by <id>-verify.log. The `from` status therefore only picks which
# of the two is asked FIRST; whichever is not preferred is still asked, because
# on the operator's doors the preferred one is frequently the wrong question.
#
# THE ROUTE THAT MADE THE FALLBACK NECESSARY is `merge_gate` exhaustion. A red
# repo-wide gate charges the round, and on the round that spends the budget
# `orchid merge` takes `merging -> blocked` rather than `merging -> rework` --
# an edge that captures nothing and deletes nothing, so BOTH logs survive it:
# a PASSING <id>-verify.log from before the merge and the failing
# <id>-merge.log that is the entire reason the task stopped. The operator then
# types `orchid task unblock` or `orchid task retry`, neither of which arrives
# `from = merging`, and both of which delete <id>-merge.log on their way to
# `rework`. Preferring verify.log and stopping there answers "no failing
# evidence" over a passing log while the failure sits in the file the same verb
# is about to remove -- the gate's own output destroyed by the recovery from
# it, which is lesson L023's defect one door along and the shape this whole
# feature exists to end.
#
# THE `candidate` ARGUMENT IS WHAT KEEPS BOTH ARMS HONEST, and it is not
# hypothetical: `orchid merge`'s rebase arm mints a NEW candidate_sha under a
# tree whose <id>-merge.log is still on disk, and the `merging` arm of `task
# advance rework` deliberately exempts that log from its invalidating delete
# (so the failure it is about to journal keeps its evidence). A superseded
# merge log therefore sits in exactly the place this function looks, reads
# exactly like a current one, and would be captured as this round's failure,
# digested into this round's signature, and counted toward the streak that
# reroutes the role and blocks the task for not converging. So the log must
# CLAIM the candidate the caller is reworking -- and that check is what makes
# the fallback safe rather than merely wider: a merge log left standing by an
# earlier candidate's merge is refused here, not captured because verify.log
# happened to be missing. Absent (the caller has no candidate to bind to, e.g.
# a direct unit call), the check is skipped rather than failed -- there is
# nothing to compare against, and refusing every capture on that basis would
# make the feature inert instead of careful.
#
# The other half of the fallback's safety is at the caller: a merge log the
# `merging -> rework` advance ALREADY captured is byte-identical to the newest
# captured round, so rework_evidence_recaptured refuses it and no round is
# filed twice (see capture_rework_evidence in libexec/orchid-task).
rework_evidence_source() {
  local state="$1" id="$2" from="$3" cand="${4:-}" first second
  if [ "$from" = merging ]; then
    first="$state/reviews/$id-merge.log"; second="$state/reviews/$id-verify.log"
  else
    first="$state/reviews/$id-verify.log"; second="$state/reviews/$id-merge.log"
  fi
  if rework_evidence_usable "$first" "$cand"; then
    printf '%s\n' "$first"; return 0
  fi
  if rework_evidence_usable "$second" "$cand"; then
    printf '%s\n' "$second"; return 0
  fi
  return 1
}
