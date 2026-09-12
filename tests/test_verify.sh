#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create T001 "verify demo"
"$ORCHID_BIN" task set T001 verification_commands "exit 1"

out="$WORK/verify.out"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "failing command -> FAIL exits 1"
assert_match "^FAIL$" "$(cat "$out")" "prints FAIL"

log=".orchid/reviews/T001-verify.log"
[ -f "$log" ] || fail "evidence log written"
assert_match "^command: exit 1$" "$(cat "$log")" "evidence records the exact command"
assert_match "^exit: 1$" "$(cat "$log")" "evidence records the exit code"
assert_match "^date: " "$(cat "$log")" "evidence has date header"
assert_match "^sha: " "$(cat "$log")" "evidence has sha header"
assert_match "^cwd: " "$(cat "$log")" "evidence has cwd header"
assert_match "^---$" "$(cat "$log")" "evidence has separator"

# Now make it pass.
"$ORCHID_BIN" task set T001 verification_commands "exit 0"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "passing command -> PASS exits 0"
assert_match "^PASS$" "$(cat "$out")" "prints PASS"
assert_match "^exit: 0$" "$(cat "$log")" "evidence records exit 0 after fix"

# The verification command's stdin is /dev/null, never the caller's. This verb
# runs from inside runners/orchid-drive's task walk, whose own stdin is the
# worklist it is iterating, so a suite that reads stdin would consume the
# tasks the driver has not reached yet — the pass would end early, silently,
# with work skipped and no error raised anywhere.
stdin_probe="$WORK/verify-stdin.txt"
"$ORCHID_BIN" task set T001 verification_commands "cat > '$stdin_probe'"
rc=0; printf 'SWALLOWED\n' | "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "a command that reads stdin still passes"
[ -f "$stdin_probe" ] || fail "the verification command ran"
assert_eq "" "$(cat "$stdin_probe")" "the verification command reads EOF, never the caller's stdin"

# ---------------------------------------------------------------------------
# ORCHID_REPO_ROOT reaches the VERIFICATION command, not just the
# `worktree_prepare` command.
#
# A task's suite runs in a checkout Orchid made, which holds only what is
# committed; anything gitignored the suite needs lives in the dispatching
# repository, and this variable is the only portable handle on it -- a
# dispatch worktree is a sibling of the repository and a merge validation
# worktree is an unrelated $TMPDIR directory, so no fixed relative path
# reaches it from both. Without it in this environment the alternative is an
# absolute path hardcoded into committed config, which is exactly what the
# variable exists to make unnecessary.
#
# RED before this change: the command sees `unset` -- ORCHID_REPO_ROOT was
# exported to the prepare child only (lib/common.sh) and to nothing else.
# ---------------------------------------------------------------------------
root_probe="$WORK/verify-root.txt"
cat > "$WORK/verify-root.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s' "${ORCHID_REPO_ROOT-unset}" > "$1"
EOF
chmod +x "$WORK/verify-root.sh"
"$ORCHID_BIN" task set T001 verification_commands "$WORK/verify-root.sh $root_probe"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "the probe command passes"
# The expected value is the repository's PHYSICAL path, because that is what
# the verb resolves before exporting it: macOS hands out /var/folders symlinks
# for /private/var/folders, so a logical path would never compare equal.
# cd_scratch, not a plain `cd` (lesson L014): an empty $WORK would make `cd ""`
# a silent no-op and `pwd -P` would then report the CALLER's directory, so the
# EXPECTED side of this assertion would quietly become the real checkout --
# and a wrong expectation that happens to match is an assertion that no longer
# tests anything. tests/test_helpers.sh lints for this shape suite-wide.
WORKP="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root"; exit 1; }
assert_eq "$WORKP" "$(cat "$root_probe" 2>/dev/null || echo missing)" \
  "the verification command is handed the repository's own canonical path in ORCHID_REPO_ROOT"

# ============================================================================
# F47 -- the verify log is keyed per TASK, so only the most recent run of it
# is ever readable under its own name.
#
# MEASURED BEFORE IT WAS FIXED, and the report's headline is stale: T025
# already captures a FAILING round at `<id>-r<n>-rework.log` on every one of
# the three doors into `rework`, so "a retry erases the evidence of the failure
# that caused it" is no longer true of the shipped tree. Saying otherwise here
# would make this file a monument to a defect somebody else repaired.
#
# What is still true, and what this pins, is narrower and real: that capture
# fires only when a rework door is TAKEN. Nothing retains
#
#   * a PASSING run -- the next attempt overwrites it, so "which tree passed on
#     attempt 2, and what did it print" is unanswerable an attempt later; or
#   * a REFUSED run (exit 20, the tree is not the candidate), which takes no
#     rework door at all; or
#   * a second failing run inside one attempt, after `task reverify`.
#
# So every run of the verifier now files a copy keyed by ATTEMPT --
# `<id>-a<n>-verify.log`, the same `a<n>` the attempt's implementer envelope
# uses -- beside the round-keyed rework capture, which is a different axis and
# stays exactly as it is. The live `<id>-verify.log` is untouched: INV-11's
# gate, the rework capture and the driver all read it, and none of them should
# learn a second name.
# ============================================================================
"$ORCHID_BIN" task create T090 "f47-per-attempt-verify-evidence"
"$ORCHID_BIN" task set T090 verification_commands "echo round-one-output; exit 1"
# `testing` refuses without both shas, and a refused advance is SILENT in a
# test file with no `set -e` -- the fixture would then charge no attempt and
# the twin below would compare one round against itself.
f47_head="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T090 base_sha "$f47_head"
"$ORCHID_BIN" task set T090 candidate_sha "$f47_head"
rc=0; "$ORCHID_BIN" verify T090 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "fixture: the first round fails"

f47_live=".orchid/reviews/T090-verify.log"
f47_a1=".orchid/reviews/T090-a1-verify.log"
[ -f "$f47_live" ] || fail "fixture: the live verify log must exist after a failing round"
[ -f "$f47_a1" ] \
  || fail "F47: a failing verify must leave a per-attempt copy at $f47_a1"
assert_match "round-one-output" "$(cat "$f47_a1" 2>/dev/null || echo)" \
  "F47: the per-attempt copy carries the failing round's own output"

# Now the recovery that used to destroy it. `advance <id> rework` is the edge a
# failing round takes -- it charges the attempt AND deletes the live log -- and
# `retry` deletes it again on the way back from `blocked`. Both doors are taken
# here, because F47 is about the evidence surviving whichever one is used.
"$ORCHID_BIN" task advance T090 implementing >/dev/null \
  || fail "fixture: pending -> implementing"
"$ORCHID_BIN" task advance T090 testing --reason "round one ran" >/dev/null \
  || fail "fixture: implementing -> testing (needs base_sha and candidate_sha)"
"$ORCHID_BIN" task advance T090 rework --reason "round one failed (fixture)" >/dev/null \
  || fail "fixture: testing -> rework, the edge that charges the attempt"
"$ORCHID_BIN" task advance T090 blocked --reason "attempts exhausted (fixture)" >/dev/null
"$ORCHID_BIN" task retry T090 --reason "diagnosed; try again" >/dev/null
[ ! -f "$f47_live" ] \
  || fail "fixture: retry is supposed to invalidate the live verify log — if it no longer does, this case is not testing F47"
[ -f "$f47_a1" ] \
  || fail "F47: the attempt-keyed copy did not survive the recovery verbs"
assert_match "round-one-output" "$(cat "$f47_a1" 2>/dev/null || echo)" \
  "F47: ...and it still holds the output the next implementer needs to read"
# T025's round-keyed capture, asserted HERE so this file states what it did not
# fix. If this ever stops existing, the claim in the header above is wrong and
# the person reading it should find that out from a failing test.
[ -f ".orchid/reviews/T090-r1-rework.log" ] \
  || fail "F47: T025's round-scoped rework capture is missing — the header of this block claims it already covers the failing-round case, and that claim is now false"
red_case 'a failing verify round is readable after the recovery verbs under BOTH keys: T025 round capture, and the attempt-keyed copy added here'

# GREEN twin: a SECOND round files its own copy under its own attempt, rather
# than overwriting the first. Without this the check above would pass just as
# well against a single archive path that every round clobbers -- which is the
# defect wearing a different name.
f47_attempts="$("$ORCHID_BIN" task show T090 | grep '^attempts: ' | cut -d' ' -f2)"
[ "$f47_attempts" -ge 1 ] \
  || fail "fixture: the rework edge must have charged an attempt, or the twin below compares one round against itself (attempts=$f47_attempts)"
"$ORCHID_BIN" task set T090 verification_commands "echo round-two-output; exit 1"
"$ORCHID_BIN" task advance T090 implementing >/dev/null \
  || fail "fixture: rework -> implementing for the second round"
"$ORCHID_BIN" task advance T090 testing --reason "second round" >/dev/null \
  || fail "fixture: implementing -> testing for the second round"
rc=0; "$ORCHID_BIN" verify T090 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "fixture: the second round fails too"
f47_a2=".orchid/reviews/T090-a$(( f47_attempts + 1 ))-verify.log"
[ "$f47_a2" != "$f47_a1" ] \
  || fail "fixture: the second round must be a different attempt, or this twin proves nothing (attempts=$f47_attempts)"
[ -f "$f47_a2" ] || fail "F47: the second round filed no copy of its own at $f47_a2"
assert_match "round-two-output" "$(cat "$f47_a2" 2>/dev/null || echo)" \
  "F47: the second round's copy carries the second round's output"
assert_match "round-one-output" "$(cat "$f47_a1" 2>/dev/null || echo)" \
  "F47: ...and the first round's copy is untouched by it"
green_case 'two failing rounds leave two readable logs, one per attempt, instead of one path each overwriting the last'

# ============================================================================
# F49 -- "verify PASS" never showed how narrow the gate was.
#
# Thirteen r-001 tasks merged reporting a green gate having run between 4 and
# 86 of the suite's 2,305 tests. Each task's `verification_commands` carried a
# `--filter` authored during planning, when narrowing was a reasonable drafting
# convenience; by merge time that filter had silently become the definition of
# correctness for the task. `verify passed (25 tests)` and `verify passed
# (2305 tests)` are different claims and read identically.
#
# Orchid cannot count a stranger's tests -- the verification command is
# arbitrary shell, and inventing a number would be exactly the fabricated-
# evidence class the whole run is about. What it CAN state, from facts it
# holds, is whether the gate that ran was the repository's own or a per-task
# substitute for it. That is the decision-relevant half: a reviewer reading a
# green log learns, without leaving the log, that the green describes a
# narrower question than the repository asks.
#
# `scope: repo` when the task ran the configured repository gate, `scope: task`
# when it ran something else, and the command itself is already on the line
# above so the reader can see WHAT else.
# ============================================================================
"$ORCHID_BIN" task create T091 "f49-scope-disclosure"
"$ORCHID_BIN" task set T091 verification_commands "true"
rc=0; "$ORCHID_BIN" verify T091 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: the narrow task gate passes"
f49_narrow="$(cat .orchid/reviews/T091-verify.log 2>/dev/null || echo)"
assert_match "^scope: task" "$f49_narrow" \
  "F49: a task that substitutes its own verification_commands records that its gate was task-scoped"
assert_match "^command: true" "$f49_narrow" \
  "F49: ...beside the command itself, so the reader can see what was substituted"
red_case 'a green verify log filed against a per-task verification command declares its gate task-scoped, so a narrow pass cannot read like the repository gate'

# GREEN twin: a task with NO substitute runs the repository's configured gate,
# and must say so. Without this the marker could be a constant that says
# "task" about everything, which discloses nothing.
# The repository gate this fixture has not needed until now: a task with no
# verification_commands of its own falls back to it, and that fallback is the
# whole distinction being pinned.
printf 'verify=true\n' > orchid.config
"$ORCHID_BIN" task create T092 "f49-repo-scope"
rc=0; "$ORCHID_BIN" verify T092 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: the repository gate passes for a task that declares none of its own"
f49_repo="$(cat .orchid/reviews/T092-verify.log 2>/dev/null || echo)"
assert_match "^scope: repo" "$f49_repo" \
  "F49: a task with no verification_commands of its own records that it ran the repository gate"
green_case 'the same field reads repo for a task that ran the configured repository gate: the disclosure distinguishes the two rather than labelling everything'

# The case T025's capture cannot reach: a PASS. No rework door is taken, so
# nothing is captured, and the next attempt overwrites the live log -- which
# makes "what did the tree that passed on attempt N actually print" a question
# the run cannot answer one attempt later. This is the part of F47 that was
# genuinely open.
"$ORCHID_BIN" task create T093 "f47-a-pass-is-evidence-too"
"$ORCHID_BIN" task set T093 verification_commands "echo THE-PASSING-ROUND; exit 0"
rc=0; "$ORCHID_BIN" verify T093 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: the round passes"
[ -f ".orchid/reviews/T093-a1-verify.log" ] \
  || fail "F47: a PASSING verify left no attempt-keyed copy — a pass is evidence about a tree and nothing else retains it"
assert_match "THE-PASSING-ROUND" "$(cat .orchid/reviews/T093-a1-verify.log 2>/dev/null || echo)" \
  "F47: ...and the copy carries what the passing round printed"
[ ! -f ".orchid/reviews/T093-r1-rework.log" ] \
  || fail "F47: a passing round must not have taken a rework door — if it did, this case is measuring T025's capture rather than the gap beside it"
green_case 'a passing round is retained under its attempt as well, which is the case the round-scoped rework capture cannot reach because it fires only on entry to rework'
