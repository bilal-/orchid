#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/rework.sh"
# T025 -- feeding the previous attempt's failure back into rework.
#
# RED before this task: lib/rework.sh does not exist, `orchid task advance
# <id> rework` deletes reviews/<id>-verify.log without capturing it first,
# and `orchid task set <id> rework_signature` is an ordinary settable key.
#
# The defect (dogfood finding F27, lesson L023): the rework advance journals
# "verify failed: see .orchid/reviews/<id>-verify.log" and, in the same call,
# deletes that log. The pointer dangles the instant it is written, so three
# attempts in a row got the same brief, made the same change, and produced a
# BYTE-IDENTICAL failure.
#
# Part A unit-tests the signature/capture primitives directly. Part B proves
# the kernel verb captures before it invalidates, and that INV-11's gate is
# still armed by the delete it kept. Part C is the convergence record itself.
# Part D is the pack: the next attempt's brief carries the failing output
# verbatim.

# ===========================================================================
# Part A -- the signature. Two runs of the same failure differ in their
# volatile header and nowhere else; that must not read as a different failure.
# ===========================================================================
A="$WORK/sig"
mkdir -p "$A"

# mk_log <file> <date> <sha> <cwd> <body> <exit> [integration-head]
#
# The REAL header shape `orchid verify` writes, prestate block included --
# not the five lines this feature's first draft assumed. libexec/orchid-verify
# splices drive_verify_prestate_headers (lib/drive.sh) in between `command:`
# and the bare `---`, and the witness below proves it still does. A fixture
# that omits those lines cannot see the defect they cause, which is exactly
# how the enumerated drop-list survived its own unit tests.
mk_log() {
  { printf 'date: %s\n' "$2"
    printf 'sha: %s\n' "$3"
    printf 'candidate: %s\n' "$3"
    printf 'cwd: %s\n' "$4"
    printf 'command: /bin/bash tests/run.sh\n'
    printf 'prestate: 1\n'
    printf 'pre_base_sha: "%s"\n' "$3"
    printf 'pre_exec_missing: ""\n'
    printf 'pre_env_missing: ""\n'
    printf 'pre_env_inventory: ""\n'
    printf 'pre_pin_stale: ""\n'
    printf 'pre_integration_head: "%s"\n' "${7:-integhead0000}"
    printf -- '---\n'
    printf '%s\n' "$5"
    printf 'exit: %s\n' "$6"
  } > "$1"
}

mk_log "$A/r1.log" 2026-08-01T00:00:00Z aaaa1111 /tmp/wt-a "FAIL: assertSame order differs" 1
mk_log "$A/r2.log" 2026-08-02T09:15:00Z bbbb2222 /tmp/wt-b "FAIL: assertSame order differs" 1
mk_log "$A/r3.log" 2026-08-03T09:15:00Z cccc3333 /tmp/wt-c "FAIL: expected 3 got 4" 1
mk_log "$A/r4.log" 2026-08-03T09:15:00Z cccc3333 /tmp/wt-c "FAIL: assertSame order differs" 2

s1="$(rework_signature "$A/r1.log")"
s2="$(rework_signature "$A/r2.log")"
s3="$(rework_signature "$A/r3.log")"
s4="$(rework_signature "$A/r4.log")"
[ -n "$s1" ] || fail "rework_signature produces a digest"
assert_eq "$s1" "$s2" "a re-run of the SAME failure has the same signature (date/sha/cwd are volatile, not evidence)"
[ "$s1" != "$s3" ] || fail "a different failure output must produce a different signature"
[ "$s1" != "$s4" ] || fail "the same output with a different exit code is a different failure"

# THE ONE THAT MAKES THIS FEATURE WORK OUTSIDE A ONE-TASK FIXTURE. `orchid
# verify` writes T019's prestate block into the same header, and
# `pre_integration_head` is the integration checkout's HEAD -- it moves every
# time ANY OTHER TASK MERGES, which on a real run is constantly and has
# nothing whatever to do with what this task failed on. A signature that
# enumerates the volatile keys it knows about (date/sha/candidate/cwd) rather
# than keeping only the one it wants (`command:`) hands two byte-identical
# failures two different digests, so `rework_signature_repeats` never reaches
# 2: the brief tells the next attempt its failure is brand new when it is the
# third copy of the same one, the failover never reroutes, and the
# non-convergence stop never fires. The whole feature goes silently inert in
# precisely the multi-task run F27 was recorded on -- and a single-task
# fixture, where integration HEAD never moves, passes anyway.
mk_log "$A/r7.log" 2026-08-04T00:00:00Z aaaa1111 /tmp/wt-a "FAIL: assertSame order differs" 1 integhead1111
mk_log "$A/r8.log" 2026-08-05T10:00:00Z bbbb2222 /tmp/wt-b "FAIL: assertSame order differs" 1 integhead2222
assert_eq "$(rework_signature "$A/r7.log")" "$(rework_signature "$A/r8.log")" \
  "an unrelated task merging (pre_integration_head moves) must NOT make the same failure look like a different one"
assert_eq "$s1" "$(rework_signature "$A/r7.log")" \
  "and the whole header block is volatile alike -- prestate lines never reach the digest either"

# Non-vacuity: the fixture header above must be the shape the verifier really
# writes. If libexec/orchid-verify ever stops splicing the prestate block, the
# assertions above would still pass while testing a header nobody produces.
grep -q 'prestate_headers' "$REPO_ROOT/libexec/orchid-verify" \
  || fail "witness: orchid-verify no longer writes a prestate header block — mk_log above is pinning a shape that does not exist"
grep -q 'pre_integration_head' "$REPO_ROOT/lib/drive.sh" \
  || fail "witness: drive_verify_prestate_headers no longer emits pre_integration_head — re-derive which header keys are volatile"

# The keep-list is what keeps that true for header keys nobody has invented
# yet: an UNRECOGNISED header line must be treated as volatile, not folded
# into the digest on the strength of not being on a drop-list. Spliced into
# the HEADER (before the bare `---`), which is where a new header key lands.
{ printf 'date: 2026-08-06T00:00:00Z\n'
  printf 'sha: dddd4444\n'
  printf 'candidate: dddd4444\n'
  printf 'cwd: /tmp/wt-d\n'
  printf 'command: /bin/bash tests/run.sh\n'
  printf 'pre_some_future_key: "moves every run"\n'
  printf -- '---\n'
  printf 'FAIL: assertSame order differs\n'
  printf 'exit: 1\n'; } > "$A/r9.log"
assert_eq "$(rework_signature "$A/r7.log")" "$(rework_signature "$A/r9.log")" \
  "a header key added by some LATER task is volatile by default — the digest keeps 'command:' and nothing else"

# `command:` itself is kept, and it is the one header line that must be: the
# same output from a DIFFERENT command is a different failure.
{ printf 'date: 2026-08-06T00:00:00Z\n'
  printf 'sha: dddd4444\n'
  printf 'candidate: dddd4444\n'
  printf 'cwd: /tmp/wt-d\n'
  printf 'command: /bin/bash tests/other_suite.sh\n'
  printf -- '---\n'
  printf 'FAIL: assertSame order differs\n'
  printf 'exit: 1\n'; } > "$A/r10.log"
[ "$(rework_signature "$A/r9.log")" != "$(rework_signature "$A/r10.log")" ] \
  || fail "the 'command:' header is evidence and must reach the digest — a different command producing the same text is a different failure"

# Header-scoped, not file-wide: output that happens to start a line with
# "sha: " is real evidence and must still count.
mk_log "$A/r5.log" 2026-08-01T00:00:00Z aaaa1111 /tmp/wt-a "sha: deadbeef mismatch" 1
mk_log "$A/r6.log" 2026-08-01T00:00:00Z aaaa1111 /tmp/wt-a "sha: cafebabe mismatch" 1
[ "$(rework_signature "$A/r5.log")" != "$(rework_signature "$A/r6.log")" ] \
  || fail "a 'sha: ' line in the OUTPUT body is evidence, not a stripped header line"

rc=0; rework_signature "$A/nonexistent.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "rework_signature on a missing file fails rather than digesting nothing"

# --- round indexing: newest-first, numeric, and honest about running out ---
B="$WORK/rounds/.orchid"
mkdir -p "$B/reviews"
for n in 1 2 9 10; do echo "round $n" > "$B/reviews/T001-r$n-rework.log"; done
echo "not a round" > "$B/reviews/T001-rX-rework.log"
assert_eq "1 2 9 10" "$(rework_rounds_present "$B" T001 | tr '\n' ' ' | sed 's/ $//')" \
  "captured rounds are listed ascending and NUMERICALLY (10 after 9), ignoring non-numeric strays"
assert_eq "$B/reviews/T001-r10-rework.log" "$(rework_latest_log "$B" T001 0)" "back=0 is the newest round"
assert_eq "$B/reviews/T001-r9-rework.log" "$(rework_latest_log "$B" T001 1)" "back=1 is the round before it"
rc=0; rework_latest_log "$B" T001 4 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "asking further back than any captured round fails rather than returning the oldest"
rc=0; rework_latest_log "$B" T999 0 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a task with no captured rounds has no latest log"

# --- which log documents which rework ---------------------------------------
C="$WORK/src/.orchid"
mkdir -p "$C/reviews"
mk_log "$C/reviews/T001-verify.log" 2026-08-01T00:00:00Z aaaa /tmp/w "FAIL" 1
assert_eq "$C/reviews/T001-verify.log" "$(rework_evidence_source "$C" T001 testing)" \
  "testing -> rework is documented by the verify log"
mk_log "$C/reviews/T001-merge.log" 2026-08-01T00:00:00Z aaaa /tmp/w "validation FAIL" 1
assert_eq "$C/reviews/T001-merge.log" "$(rework_evidence_source "$C" T001 merging)" \
  "merging -> rework (validation failure) is documented by the merge log, not the pre-merge verify PASS"
# A PASSING log is never captured as a failure: the rebase-conflict path
# reaches merging -> rework with no merge log and a green verify log behind
# it, and handing the next attempt a green suite is worse than nothing.
rm -f "$C/reviews/T001-merge.log"
mk_log "$C/reviews/T001-verify.log" 2026-08-01T00:00:00Z aaaa /tmp/w "all good" 0
rc=0; rework_evidence_source "$C" T001 merging >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a PASSING verify log is never captured as the failure that caused a rework"

# Neither is a ZERO-BYTE log, and this is the arm that keeps the convergence
# counters honest rather than the brief readable. An empty file digests to a
# perfectly stable signature, so two torn writes in a row would read as one
# identical failure repeating -- and the driver would reroute the role and
# block the task as "not converging" on the strength of no output at all.
# Asserted at the SIGNATURE level too, because "the digests match" is exactly
# the fact the streak is built from: without the guard, these two are equal
# and the second capture increments the streak.
: > "$C/reviews/T001-verify.log"
rc=0; rework_evidence_source "$C" T001 testing >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a zero-byte verify log is a torn write, not a failure that printed nothing"
: > "$C/reviews/T001-empty2.log"
empty_sig="$(rework_signature "$C/reviews/T001-verify.log")"
[ -n "$empty_sig" ] \
  || fail "witness: an empty log still digests to SOMETHING -- if it did not, the comparison below would pass vacuously"
assert_eq "$empty_sig" "$(rework_signature "$C/reviews/T001-empty2.log")" \
  "two empty logs DO share one signature -- which is why the guard above has to sit at the capture, not at the compare"
rm -f "$C/reviews/T001-empty2.log"

# Non-empty is not sufficient. A verifier can die after writing part of its
# header but before the bare `---` that proves the header is complete and the
# output begins. rework_signature intentionally discards every pre-delimiter
# line, so accepting this shape would give every such torn write the same
# empty-body digest and manufacture a non-convergence streak from no result.
{
  printf 'date: 2026-08-03T00:00:00Z\n'
  printf 'candidate: aaaa\n'
  printf 'command: /bin/bash tests/run.sh\n'
  printf 'exit: 1\n'
} > "$C/reviews/T001-verify.log"
rc=0; rework_evidence_source "$C" T001 testing aaaa >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a non-empty log without the bare header terminator is a torn write, not failure evidence"

# --- evidence is bound to the candidate that produced it --------------------
# Both logs the kernel writes carry a `candidate:` header, and a capture that
# ignores it files some OTHER candidate's output as this round's failure --
# then digests it, counts it toward the convergence streak, reroutes the role
# on it and blocks the task for not converging.
#
# The `merging` arm is why this is not hypothetical: `orchid merge`'s rebase
# path mints a NEW candidate_sha while the previous candidate's <id>-merge.log
# is still on disk and deliberately exempt from the invalidating delete, so a
# superseded log sits in exactly the place rework_evidence_source looks and
# reads exactly like a current one.
mk_log "$C/reviews/T001-verify.log" 2026-08-04T00:00:00Z candaaaa /tmp/w "FAIL: still red" 1
assert_eq "$C/reviews/T001-verify.log" "$(rework_evidence_source "$C" T001 testing candaaaa)" \
  "a log whose header names the candidate being reworked IS this round's evidence"
rc=0; rework_evidence_source "$C" T001 testing candbbbb >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a log naming a DIFFERENT candidate documents a superseded candidate's failure, never this round's"
assert_eq "$C/reviews/T001-verify.log" "$(rework_evidence_source "$C" T001 testing)" \
  "a caller with no candidate to bind to skips the check rather than failing it — refusing every capture on that basis makes the feature inert, not careful"

# The same rule at the READ end, over the newest CAPTURED round. It closes a
# window the capture cannot see: the candidate moves after the round is filed
# (the reworking implementer commits, a rebase mints a new sha, an operator
# re-derives the branch), and feeding that round forward would tell the next
# attempt that the code IT is holding produced that output.
D="$WORK/bound/.orchid"
mkdir -p "$D/reviews"
mk_log "$D/reviews/T001-r1-rework.log" 2026-08-05T00:00:00Z candaaaa /tmp/w "FAIL: still red" 1
rework_evidence_current "$D" T001 candaaaa \
  || fail "the newest captured round is current for the candidate its own header names"
rc=0; rework_evidence_current "$D" T001 candbbbb >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a captured round is NOT current for a candidate it never described"
rc=0; rework_evidence_current "$D" T001 "" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a task with no candidate has nothing to bind to — two empty sentinels agreeing is not a match"
rc=0; rework_evidence_current "$D" T001 none >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "'none' is the no-candidate sentinel and must not match a log either"
rc=0; rework_evidence_current "$D" T999 candaaaa >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a task with no captured round has nothing current"

# --- bound is not the same as FRESH -----------------------------------------
# The binding above refuses a log naming a candidate the task has MOVED OFF. It
# cannot refuse one naming the candidate still under work -- which is every
# stale log on the one path where the candidate does not move. `orchid merge`
# exempts <id>-merge.log from the invalidating delete and can die before its own
# opening `rm -f` (a run lock it did not get), leaving the previous round's log
# in exactly the place the merging arm looks, bound to exactly the right
# candidate. Read a second time it has, BY CONSTRUCTION, the digest of the round
# already filed: repeat 2 reroutes the role, repeat 3 blocks the task for not
# converging, both from a single run counted twice.
#
# Byte-identity is the discriminator precisely BECAUSE the signature is not:
# rework_signature drops the volatile header, so a re-run and a re-read digest
# the same. The header is the only place they differ.
rework_evidence_recaptured "$D" T001 "$D/reviews/T001-r1-rework.log" >/dev/null \
  || fail "a source byte-identical to the newest captured round is that round read again"
assert_eq "$D/reviews/T001-r1-rework.log" \
  "$(rework_evidence_recaptured "$D" T001 "$D/reviews/T001-r1-rework.log")" \
  "and it names the round it duplicates, so the journal entry can be checked by hand"
# A genuine RE-RUN of the same failure: same output, same exit, same candidate,
# only the volatile header moved. It must NOT be swallowed -- this is the exact
# case the whole convergence record exists to count.
mk_log "$D/reviews/rerun.log" 2026-08-06T00:00:00Z candaaaa /tmp/w "FAIL: still red" 1
assert_eq "$(rework_signature "$D/reviews/T001-r1-rework.log")" \
  "$(rework_signature "$D/reviews/rerun.log")" \
  "witness: the re-run and the captured round DO share a signature — without that this pair proves nothing"
rc=0; rework_evidence_recaptured "$D" T001 "$D/reviews/rerun.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a fresh run of the same failure is a second round, not the first one read twice"
rm -f "$D/reviews/rerun.log"
rc=0; rework_evidence_recaptured "$D" T999 "$D/reviews/T001-r1-rework.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a task with no captured round has nothing to duplicate"

# --- a repeated signature is not always an ENGINE's to answer ---------------
# The streak's one consumer that names a culprit is the driver's failover: two
# identical rounds mean "this engine is not converging on this task". A red
# repo-wide `merge_gate` breaks that inference at the root -- it is a check the
# REPOSITORY applies to everything, which the task was never asked about, and
# libexec/orchid-task calls it the one merge failure that repeats identically
# until somebody OUTSIDE this task acts. It clears the identical-signature test
# by construction, so rerouting on it spends a second engine's round on a wall
# it cannot move and durably blames the engine that ran.
E="$WORK/gatesig/.orchid"
mkdir -p "$E/reviews"
mk_log "$E/reviews/T001-r1-rework.log" 2026-08-01T00:00:00Z candaaaa /tmp/w "FAIL: the candidate's own suite" 1
rework_streak_attributable "$E" T001 \
  || fail "a candidate's own failing suite IS attributable to whoever implemented it"
rework_streak_attributable "$E" T999 \
  || fail "no captured round is not evidence of a gate failure — an absence of evidence answers yes"
# The header shape `orchid merge` really writes for a red gate. Read, never
# inferred: the trailing `exit:` line is the MERGE's status and is equally
# non-zero when the candidate's own suite is what went red.
{ printf 'date: 2026-08-02T00:00:00Z\n'
  printf 'sha: candaaaa\n'
  printf 'candidate: candaaaa\n'
  printf 'cwd: /tmp/w\n'
  printf 'command: true\n'
  printf 'gate: shellcheck lib\n'
  printf 'gate_status: ran\n'
  printf 'gate_exit: 3\n'
  printf -- '---\n'
  printf 'lib/example.sh:12: SC2086: Double quote to prevent globbing\n'
  printf 'exit: 1\n'; } > "$E/reviews/T001-r2-rework.log"
rework_streak_attributable "$E" T001 \
  && fail "a red repo-wide merge_gate repeats identically by construction — it must never indict the engine that ran"
grep -q 'gate_status' "$REPO_ROOT/libexec/orchid-merge" \
  || fail "witness: orchid-merge no longer records gate_status in the log header — the fixture above pins a shape nobody produces"

# ===========================================================================
# Part B -- the kernel verb. The capture happens BEFORE the invalidating
# delete, and the delete still happens.
# ===========================================================================
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q .
git commit -q --allow-empty -m root
# Hand-built state, exactly like tests/test_task.sh: this file exercises verb
# behaviour on the rework edge, not `orchid init`'s preflight.
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$REPO" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
STATE="$REPO/.orchid"

fm() { "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }

"$ORCHID_BIN" task create T001 "rework capture" >/dev/null
# base_sha AND candidate_sha: entry to `testing` requires both (and the
# INV-04 guard walks base..candidate, which is empty when they are equal).
"$ORCHID_BIN" task set T001 base_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task set T001 candidate_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task advance T001 implementing --reason "fixture" >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason "fixture" >/dev/null

mk_log "$STATE/reviews/T001-verify.log" 2026-08-01T00:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: assertSame array order differs after the json round-trip" 1
sig_before="$(rework_signature "$STATE/reviews/T001-verify.log")"

"$ORCHID_BIN" task advance T001 rework --reason "verify failed: see .orchid/reviews/T001-verify.log" >/dev/null

# THE defect, stated as an assertion: the reason journalled by that very call
# points at a file the same call deletes.
[ ! -f "$STATE/reviews/T001-verify.log" ] \
  || fail "entry to rework must still delete the verify log (INV-11 stays armed)"
[ -f "$STATE/reviews/T001-r1-rework.log" ] \
  || fail "the failing output must be CAPTURED before that delete, into a round-scoped log"
grep -q "assertSame array order differs" "$STATE/reviews/T001-r1-rework.log" \
  || fail "the captured log carries the actual failing output, verbatim"
assert_eq "$sig_before" "$(fm T001 rework_signature)" "the round's failure signature is recorded on the task"
assert_eq "1" "$(fm T001 rework_rounds)" "the first captured round is round 1"
assert_eq "1" "$(fm T001 rework_signature_repeats)" "a first sighting of a signature is repeat 1, not 0"
assert_match "rework evidence captured" "$(cat "$STATE/journal.md")" \
  "the capture is journalled, so 'what did that attempt actually fail on' is greppable"

# The captured log must not be mistakable for verify evidence: INV-11's gate
# still refuses the advance it exists to gate.
"$ORCHID_BIN" task advance T001 implementing --reason "next attempt" >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason "next attempt" >/dev/null
rc=0; "$ORCHID_BIN" task advance T001 reviewing --reason "should be refused" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a captured rework log must never satisfy INV-11's verify-evidence gate"

# ===========================================================================
# Part C -- the convergence record. An IDENTICAL failure is counted as a
# repeat; a changed one resets the streak.
# ===========================================================================
mk_log "$STATE/reviews/T001-verify.log" 2026-08-02T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: assertSame array order differs after the json round-trip" 1
"$ORCHID_BIN" task advance T001 rework --reason "verify failed again, identically" >/dev/null
assert_eq "2" "$(fm T001 rework_rounds)" "the second captured round is round 2"
assert_eq "2" "$(fm T001 rework_signature_repeats)" \
  "a byte-identical failure is the SAME failure repeating, not a fresh one"
assert_eq "$sig_before" "$(fm T001 rework_signature)" "the signature is unchanged across an identical round"
[ -f "$STATE/reviews/T001-r2-rework.log" ] || fail "round 2 lands in its own file, never overwriting round 1"
[ -f "$STATE/reviews/T001-r1-rework.log" ] || fail "round 1's capture survives round 2 (both halves of a comparison)"

"$ORCHID_BIN" task advance T001 implementing --reason "third attempt" >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason "third attempt" >/dev/null
mk_log "$STATE/reviews/T001-verify.log" 2026-08-03T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: expected 3 elements, got 4" 1
"$ORCHID_BIN" task advance T001 rework --reason "different failure now" >/dev/null
assert_eq "1" "$(fm T001 rework_signature_repeats)" \
  "a CHANGED failure signature resets the streak — that is real forward progress"
[ "$(fm T001 rework_signature)" != "$sig_before" ] || fail "the recorded signature follows the newest round"

# A rework with nothing failing to capture (the rebase-conflict shape) mints
# no file and leaves the streak alone rather than resetting it: an absence of
# evidence about convergence is not evidence of convergence.
"$ORCHID_BIN" task advance T001 implementing --reason "fourth attempt" >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason "fourth attempt" >/dev/null
rm -f "$STATE/reviews/T001-verify.log"
sig_kept="$(fm T001 rework_signature)"
"$ORCHID_BIN" task advance T001 rework --reason "no evidence to capture" >/dev/null
assert_eq "3" "$(fm T001 rework_rounds)" "rework_rounds counts CAPTURED rounds, so it never outruns the files on disk"
assert_eq "$sig_kept" "$(fm T001 rework_signature)" "an uncapturable round leaves the signature record untouched"

# And neither is a failing log that documents SOME OTHER CANDIDATE. It reads
# exactly like a current one, so without the binding it would be filed as this
# round's failure, digested into this round's signature and counted toward the
# streak that reroutes the role and blocks the task for not converging -- a
# fully-journalled non-convergence judgment about a tree nobody is working on.
# `orchid merge`'s rebase arm is where this really happens (it mints a new
# candidate_sha while the previous candidate's merge log is still on disk and
# exempt from the delete); the binding lives on the one path both arms share,
# so the verify log proves it here.
"$ORCHID_BIN" task advance T001 implementing --reason "fifth attempt" >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason "fifth attempt" >/dev/null
mk_log "$STATE/reviews/T001-verify.log" 2026-08-04T11:00:00Z 0000000000000000000000000000000000000000 "$REPO" \
  "FAIL tests/OrderTest: a failure of a candidate nobody is reworking" 1
"$ORCHID_BIN" task advance T001 rework --reason "evidence from a superseded candidate" >/dev/null
assert_eq "3" "$(fm T001 rework_rounds)" \
  "a log bound to another candidate is not this round's evidence and mints no round"
[ ! -f "$STATE/reviews/T001-r4-rework.log" ] \
  || fail "nothing was captured, so there is no round-4 file to feed forward"
assert_eq "$sig_kept" "$(fm T001 rework_signature)" \
  "and the convergence record is untouched — a superseded candidate's failure can neither repeat nor reset this task's streak"
assert_match "rework evidence NOT captured" "$(cat "$STATE/journal.md")" \
  "the one case where the kernel deliberately captures nothing says so — 'rework arrived with nothing to act on' is the complaint this task exists to answer"

# A log with a complete header but NO candidate claim is unbindable, not
# superseded. Those diagnoses drive different operator actions: regenerate a
# malformed/torn producer output versus inspect why the task moved candidates.
# The durable journal must not turn the former into the latter by rendering an
# absent claim as the sentinel word "none".
"$ORCHID_BIN" task advance T001 implementing --reason "sixth attempt" >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason "sixth attempt" >/dev/null
{
  printf 'date: 2026-08-05T11:00:00Z\n'
  printf 'sha: %s\n' "$(git rev-parse HEAD)"
  printf 'cwd: %s\n' "$REPO"
  printf 'command: /bin/bash tests/run.sh\n'
  printf -- '---\n'
  printf 'FAIL tests/OrderTest: producer omitted its candidate binding\n'
  printf 'exit: 1\n'
} > "$STATE/reviews/T001-verify.log"
"$ORCHID_BIN" task advance T001 rework --reason "evidence with no candidate header" >/dev/null
assert_eq "3" "$(fm T001 rework_rounds)" \
  "an unbindable log mints no captured round and cannot move the convergence counters"
assert_match "carries no candidate header" "$(tail -n 8 "$STATE/journal.md")" \
  "the journal distinguishes absent candidate metadata from a superseded candidate claim"
[ ! -f "$STATE/reviews/T001-r4-rework.log" ] \
  || fail "an unbindable log must never become the next attempt's rework evidence"

# The record is kernel-owned: no verb but the rework advance may write it.
for k in rework_rounds rework_signature rework_signature_repeats; do
  rc=0; "$ORCHID_BIN" task set T001 "$k" 99 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "task set must refuse the kernel-owned '$k'"
done

# A green candidate breaks the CONSECUTIVE streak. Without this reset, two
# failures, a successful verification/review round, and one later recurrence
# read as three identical failures in a row and trigger the non-convergence
# stop even though the loop demonstrably moved forward between them.
"$ORCHID_BIN" task create T004 "successful verification resets convergence" >/dev/null
"$ORCHID_BIN" task set T004 base_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task set T004 candidate_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task advance T004 implementing --reason "first red round" >/dev/null
"$ORCHID_BIN" task advance T004 testing --reason "first red round" >/dev/null
mk_log "$STATE/reviews/T004-verify.log" 2026-08-06T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: the recurring failure" 1
"$ORCHID_BIN" task advance T004 rework --reason "first red round" >/dev/null
"$ORCHID_BIN" task advance T004 implementing --reason "second red round" >/dev/null
"$ORCHID_BIN" task advance T004 testing --reason "second red round" >/dev/null
mk_log "$STATE/reviews/T004-verify.log" 2026-08-07T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: the recurring failure" 1
"$ORCHID_BIN" task advance T004 rework --reason "second red round" >/dev/null
assert_eq "2" "$(fm T004 rework_signature_repeats)" \
  "fixture: two consecutive identical failures build a two-round streak"

"$ORCHID_BIN" task advance T004 implementing --reason "green round" >/dev/null
"$ORCHID_BIN" task advance T004 testing --reason "green round" >/dev/null
mk_log "$STATE/reviews/T004-verify.log" 2026-08-08T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "all good" 0
"$ORCHID_BIN" task advance T004 reviewing --reason "green evidence" >/dev/null
assert_eq "0" "$(fm T004 rework_signature_repeats)" \
  "successful verification resets the consecutive-failure streak"
assert_match "convergence streak reset after successful verification" "$(tail -n 8 "$STATE/journal.md")" \
  "the reset is journalled before its kernel-owned counter moves"

# Walk the successful candidate through a request-changes round, then make the
# old failure recur. It is repeat ONE after the green break, never repeat 3.
printf '{"status":"ok","candidate_sha":"%s"}\n' "$(git rev-parse HEAD)" \
  > "$STATE/reviews/T004-a3-reviewer.json"
"$ORCHID_BIN" task advance T004 arbitrating --reason "review fixture" >/dev/null
"$ORCHID_BIN" task advance T004 rework --reason "review requested changes" >/dev/null
"$ORCHID_BIN" task advance T004 implementing --reason "post-green red round" >/dev/null
"$ORCHID_BIN" task advance T004 testing --reason "post-green red round" >/dev/null
mk_log "$STATE/reviews/T004-verify.log" 2026-08-09T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: the recurring failure" 1
"$ORCHID_BIN" task advance T004 rework --reason "old failure returned after green" >/dev/null
assert_eq "1" "$(fm T004 rework_signature_repeats)" \
  "an old signature returning after a successful verification starts a fresh streak at one"

# THE UNCHANGED-CANDIDATE CASE, at the verb. Every refusal above is about a log
# that describes the wrong thing (a pass, a torn write, another candidate). This
# one is about a log that describes exactly the right thing and has simply
# already been counted -- and it is only reachable while the candidate does NOT
# move, which is precisely when the candidate binding cannot see it. Two rework
# entries, one run: without the guard the second is filed as its own round with a
# digest identical to the first BY CONSTRUCTION, so the streak reaches two, the
# role is rerouted to another engine and the task is blocked for not converging,
# every one of those judgments derived from a single verification.
#
# A separate task, deliberately: T001's captured rounds are what Part D builds a
# pack from, and adding rounds to it would move the evidence that part asserts on.
"$ORCHID_BIN" task create T005 "the same log read twice" >/dev/null
"$ORCHID_BIN" task set T005 base_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task set T005 candidate_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task advance T005 implementing --reason "first round" >/dev/null
"$ORCHID_BIN" task advance T005 testing --reason "first round" >/dev/null
mk_log "$STATE/reviews/T005-verify.log" 2026-08-10T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: the failure this round actually had" 1
"$ORCHID_BIN" task advance T005 rework --reason "first round" >/dev/null
assert_eq "1" "$(fm T005 rework_rounds)" "fixture: the first round is captured"
assert_eq "1" "$(fm T005 rework_signature_repeats)" "fixture: a first sighting is repeat 1"
sig_t005="$(fm T005 rework_signature)"

# The previous round's log, still on disk -- byte for byte, volatile header
# included, which is what a log that outlived its run IS and what a genuine
# re-run can never be. (`orchid merge` leaves exactly this behind when it dies
# before its own opening `rm -f`; the copy the verb already filed is the same
# bytes, so it stands in for that survivor without needing a merge to fail.)
"$ORCHID_BIN" task advance T005 implementing --reason "second round" >/dev/null
"$ORCHID_BIN" task advance T005 testing --reason "second round" >/dev/null
cp "$STATE/reviews/T005-r1-rework.log" "$STATE/reviews/T005-verify.log"
"$ORCHID_BIN" task advance T005 rework --reason "the previous round's log, still on disk" >/dev/null
assert_eq "1" "$(fm T005 rework_rounds)" \
  "a source byte-identical to the round already captured is one run read twice, so it mints no second round"
[ ! -f "$STATE/reviews/T005-r2-rework.log" ] \
  || fail "the duplicate must not be filed as its own round — both halves of a did-anything-change comparison would then be the same run"
assert_eq "1" "$(fm T005 rework_signature_repeats)" \
  "and it must not advance the streak that reroutes the role and blocks the task for not converging"
assert_eq "$sig_t005" "$(fm T005 rework_signature)" "the recorded signature is untouched"
assert_match "read a second time" "$(tail -n 20 "$STATE/journal.md")" \
  "the refusal is journalled and names both files — 'why did the streak not move' must be answerable without a diff"

# ...and the pair that makes this a discrimination rather than a blanket
# suppression: a real second run of the SAME failure still counts. Identical
# output, identical exit, identical candidate; only the volatile header moved,
# which is exactly the case the convergence record exists to catch.
"$ORCHID_BIN" task advance T005 implementing --reason "third round" >/dev/null
"$ORCHID_BIN" task advance T005 testing --reason "third round" >/dev/null
mk_log "$STATE/reviews/T005-verify.log" 2026-08-11T11:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL tests/OrderTest: the failure this round actually had" 1
"$ORCHID_BIN" task advance T005 rework --reason "a real second run, same failure" >/dev/null
assert_eq "2" "$(fm T005 rework_rounds)" "a fresh run of the same failure IS a second round"
assert_eq "2" "$(fm T005 rework_signature_repeats)" \
  "and it is the repeat the convergence record exists to count"
assert_eq "$sig_t005" "$(fm T005 rework_signature)" \
  "the signature is the same one — the guard above suppressed a duplicate READ, never a duplicate FAILURE"

# ===========================================================================
# Part D -- the pack. This is the whole point: the NEXT attempt's brief has
# to contain the failing output, not a pointer to a deleted file.
# ===========================================================================
source "$REPO_ROOT/lib/pack.sh"

pack_build "$REPO" T001 implement "$WORK/pack-impl" || fail "implementer pack build"
[ -f "$WORK/pack-impl/rework.md" ] || fail "a rework attempt's implementer pack carries rework.md"
grep -q "expected 3 elements, got 4" "$WORK/pack-impl/rework.md" \
  || fail "rework.md contains the previous round's failing output VERBATIM"
grep -q "first time this particular failure" "$WORK/pack-impl/rework.md" \
  || fail "rework.md says whether this failure is new"
assert_eq "true" "$(jq -r '.total_bytes == ([.items[].bytes] | add)' "$WORK/pack-impl/pack.json")" \
  "pack.json still sums its items with rework.md present"
assert_match '"rework.md"' "$(jq -c '[.items[].name]' "$WORK/pack-impl/pack.json")" \
  "rework.md is a declared pack item, not a smuggled file"

# A reviewer must NOT be handed the previous attempt's failure: it judges the
# candidate in front of it.
pack_build "$REPO" T001 review "$WORK/pack-rev" || fail "reviewer pack build"
[ ! -f "$WORK/pack-rev/rework.md" ] || fail "a review pack must not carry rework.md"

# A task with no captured rework has no brief and no error.
"$ORCHID_BIN" task create T002 "first attempt" >/dev/null
"$ORCHID_BIN" task set T002 base_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task set T002 candidate_sha "$(git rev-parse HEAD)" >/dev/null
pack_build "$REPO" T002 implement "$WORK/pack-first" || fail "first-attempt pack build"
[ ! -f "$WORK/pack-first/rework.md" ] || fail "a first attempt has no previous failure to feed back"

# --- the repeated-signature brief, which is the F27 case itself ------------
# T003 fails twice, identically. The second attempt's brief must not merely
# repeat the output: it must SAY that the last round changed nothing.
"$ORCHID_BIN" task create T003 "identical twice" >/dev/null
"$ORCHID_BIN" task set T003 base_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task set T003 candidate_sha "$(git rev-parse HEAD)" >/dev/null
"$ORCHID_BIN" task advance T003 implementing --reason "fixture" >/dev/null
"$ORCHID_BIN" task advance T003 testing --reason "fixture" >/dev/null
mk_log "$STATE/reviews/T003-verify.log" 2026-08-01T00:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL OrderTest::testRoundTrip assertSame" 1
"$ORCHID_BIN" task advance T003 rework --reason "first failure" >/dev/null
"$ORCHID_BIN" task advance T003 implementing --reason "second attempt" >/dev/null
"$ORCHID_BIN" task advance T003 testing --reason "second attempt" >/dev/null
mk_log "$STATE/reviews/T003-verify.log" 2026-08-02T00:00:00Z "$(git rev-parse HEAD)" "$REPO" \
  "FAIL OrderTest::testRoundTrip assertSame" 1
"$ORCHID_BIN" task advance T003 rework --reason "identical failure" >/dev/null

pack_build "$REPO" T003 implement "$WORK/pack-repeat" || fail "repeat pack build"
brief="$(cat "$WORK/pack-repeat/rework.md")"
assert_match "repeated 2 times in a row" "$brief" \
  "the brief states the failure repeated unchanged — 'you already tried this and got exactly this'"
assert_match "OrderTest::testRoundTrip" "$brief" "the brief still carries the output itself"
assert_match "no diff to show" "$brief" \
  "an identical round shows no diff rather than an empty one that reads like a change"

# (rework.md's budgeting — priority ahead of lessons.md/context.md, and its
# tail-kept trim — is tests/test_pack.sh's subject, exercised there against
# pack_build directly rather than duplicated through the verbs here.)
