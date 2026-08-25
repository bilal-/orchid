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

mk_log() {  # mk_log <file> <date> <sha> <cwd> <body> <exit>
  { printf 'date: %s\n' "$2"
    printf 'sha: %s\n' "$3"
    printf 'candidate: %s\n' "$3"
    printf 'cwd: %s\n' "$4"
    printf 'command: /bin/bash tests/run.sh\n'
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

# The record is kernel-owned: no verb but the rework advance may write it.
for k in rework_rounds rework_signature rework_signature_repeats; do
  rc=0; "$ORCHID_BIN" task set T001 "$k" 99 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "task set must refuse the kernel-owned '$k'"
done

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
