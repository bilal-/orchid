#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# THE EVIDENCE RULE OF tests/probes/probe-claude-tick.sh, EXERCISED OFFLINE.
#
# That probe answers one question with real quota: does headless `claude -p`
# actually EXECUTE `orchid` verbs, or does it just print the ORCHID-ACTION
# marker lines it was asked for with nothing behind them? Its whole value rests
# on the evidence it accepts as proof a verb really ran -- and that evidence is
# only worth anything if the values it greps for are values the engine could
# not have produced without running the command.
#
# The probe used to fail that on one half: it interpolated this checkout's
# exact `orchid version` line INTO the prompt and then grepped the reply for
# that same string, so an engine echoing the prompt back scored the version
# half for free. Only the config half discriminated -- and its needle was the
# literal key name `integration_branch`, which an engine can simply guess.
#
# A rule like that cannot be left to a live, billed run to notice. This file
# feeds the probe three STUB engines on a PATH where the stub is the only
# `claude` there is, so all three cases are deterministic, offline, and cost
# nothing:
#
#   1. echo-back            -- replies with the prompt verbatim plus the two
#                              marker lines it was told to print. Must NOT be
#                              scored YES, and specifically must score neither
#                              half of the output evidence.
#   2. plausible hallucination -- replies with an invented but entirely
#                              plausible version line and config table, plus
#                              both markers. Must NOT be scored YES.
#   3. honest execution     -- actually runs both verbs and pastes their real
#                              output. MUST be scored YES.
#
# Case 3 is not decoration. Without it, cases 1 and 2 would pass just as
# happily against a probe that had become unsatisfiable (a renamed verb, a
# needle nothing can print, an ENV-UNAVAILABLE bail-out) -- a check that
# rejects everything is not evidence of detection. Cases 1 and 2 likewise
# assert that the probe got as far as READING the stub's reply, so neither can
# pass by never running.
#
# No vendor CLI is contacted: every case supplies its own `claude` on PATH, so
# this file behaves identically on a developer machine and on a runner (and
# inside tests/test_hermetic_suite.sh's vendor-CLI-free nested run).

PROBE="$REPO_ROOT/tests/probes/probe-claude-tick.sh"
TEST_BASH="${ORCHID_TEST_BASH:-${BASH:-bash}}"

# `grep -Eq -e`, with the explicit `-e`: a pattern that happens to start with a
# dash is otherwise read by grep as an option and the assertion becomes an
# error rather than a comparison.
refute_match() {
  if grep -Eq -e "$1" <<<"$2"; then fail "$3 (unexpected match '$1')"; fi
}

[ -f "$PROBE" ] || { fail "$PROBE does not exist -- this file's whole subject is missing"; exit 1; }

# The version half's needle, as the probe itself derives it. Read here too so
# the fixtures below can be checked against it rather than against a
# hard-coded version string that would rot the next time the kernel bumps.
real_version_line="$("$ORCHID_BIN" version 2>/dev/null || true)"
[ -n "$real_version_line" ] \
  || { fail "orchid version printed nothing in this checkout, so the probe's version needle cannot be reasoned about here"; exit 1; }

# What case 2 pretends `orchid version` printed. It has to be plausible AND
# genuinely wrong: if this checkout ever ships a version this string contains,
# the fixture would score the version half for real and case 2 would be
# testing nothing. Fall back, then assert -- never silently.
fake_version_line="orchid 1.0.0"
case "$fake_version_line" in
  *"$real_version_line"*) fake_version_line="orchid 0.9.0" ;;
esac
case "$fake_version_line" in
  *"$real_version_line"*)
    fail "the hallucination fixture's invented version line still contains this checkout's real one ('$real_version_line'), so case 2 would score the version half for the wrong reason -- change the fixture" ;;
esac

# run_probe <stub-name> -- run the probe with $WORK/<stub-name>/bin first on
# PATH, so `command -v claude` and the `claude -p ...` call both land on that
# stub. Prints the probe's stdout; its stderr is kept for failure messages, and
# a stub may drop the prompt it was handed in <stub-name>.prompt.
run_probe() {
  PATH="$WORK/$1/bin:$PATH" \
  PROBE_STUB_ORCHID_BIN="$ORCHID_BIN" \
  PROBE_STUB_FAKE_VERSION="$fake_version_line" \
  PROBE_STUB_PROMPT_FILE="$WORK/$1.prompt" \
    "$TEST_BASH" "$PROBE" 2>"$WORK/$1.err"
}

# check_ran <stub-name> <rc> <output> -- every outcome of this probe is a
# single PROBE-RESULT line and exit 0; anything else means the case below is
# asserting against wreckage.
check_ran() {
  local err
  err="$(tr '\n' ' ' < "$WORK/$1.err" 2>/dev/null | head -c 300)"
  assert_eq "0" "$2" "$1 stub: the probe must exit 0 whatever it finds (stderr: $err)"
  assert_match "^PROBE-RESULT: " "$3" \
    "$1 stub: the probe must print a PROBE-RESULT line (stderr: $err)"
}

# --- 1. echo-back: the reply IS the prompt ---------------------------------
mkdir -p "$WORK/echo-back/bin"
cat > "$WORK/echo-back/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Merely echoes the prompt back, then prints the two marker lines it was
# literally instructed to print. It runs no command at all. This is the exact
# shape that used to score the probe's version half for free.
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) prompt="${2-}"; shift 2 2>/dev/null || shift ;;
    *)  shift ;;
  esac
done
if [ -n "${PROBE_STUB_PROMPT_FILE-}" ]; then
  printf '%s\n' "$prompt" > "$PROBE_STUB_PROMPT_FILE"
fi
printf '%s\n' "$prompt"
printf 'ORCHID-ACTION: orchid version\n'
printf 'ORCHID-ACTION: orchid config list\n'
STUB
chmod +x "$WORK/echo-back/bin/claude"

echo_rc=0
echo_out="$(run_probe echo-back)" || echo_rc=$?
check_ran echo-back "$echo_rc" "$echo_out"

assert_match "marker-version=true" "$echo_out" \
  "echo-back stub: the probe read this stub's reply (its ORCHID-ACTION lines are present), so the verdict below is about the evidence rule and not about a probe that bailed out early"
assert_match "marker-config=true" "$echo_out" \
  "echo-back stub: both marker lines reached the probe"
refute_match "PROBE-RESULT: YES" "$echo_out" \
  "echo-back stub: an engine that only hands the prompt back must never be scored as having executed the verbs"
assert_match "output-version=false" "$echo_out" \
  "echo-back stub: the version half must not be satisfiable by echoing the prompt -- the prompt now carries a generic hint, and the needle is this checkout's real version line"
assert_match "output-config=false" "$echo_out" \
  "echo-back stub: the config half must not be satisfiable by echoing the prompt"
assert_match "keyname-echoed=false" "$echo_out" \
  "echo-back stub: the prompt must not name integration_branch either -- if it did, an echo would hand back the old needle"

# The same claim stated directly against the PROMPT, in full. The assertions
# above read the probe's own verdict on a reply; this reads the bytes the probe
# actually handed the engine, so it holds even if the verdict logic is later
# rewritten. Literal substring tests, not patterns, so a version string full of
# dots cannot match something it does not equal.
echo_prompt="$(cat "$WORK/echo-back.prompt" 2>/dev/null || true)"
if [ -z "$echo_prompt" ]; then
  fail "the echo-back stub captured no prompt -- the probe either never called it or passed no -p argument, and the two prompt assertions below would then be vacuous"
else
  case "$echo_prompt" in
    *"$real_version_line"*)
      fail "the probe's prompt still carries this checkout's exact 'orchid version' output ('$real_version_line'), so grepping the reply for that string proves nothing about whether the engine ran anything -- the defect this file exists to hold closed" ;;
  esac
  case "$echo_prompt" in
    *integration_branch*)
      fail "the probe's prompt names the integration_branch key, so an engine that echoes it back is handed the config half's old needle -- the prompt must describe the shape of the config table, never a key or a value" ;;
  esac
  # The config half's VALUE, by shape rather than by substring: the per-run
  # token is minted inside the probe and never leaves it, so this file cannot
  # hold the literal to test for. Its documented shape
  # (orchid-probe-<pid>-<epoch>) is stable, and nothing else in the prompt --
  # an absolute binary path, a marker line -- can produce that spelling, so a
  # match here can only mean the probe started handing its own config needle
  # to the engine.
  refute_match 'orchid-probe-[0-9]+-[0-9]+' "$echo_prompt" \
    "the probe's prompt carries something shaped like its own per-run config token, so an engine that echoes the prompt back would be handed the config half's needle -- the token must never appear in the prompt"
  assert_match "one short line naming the tool and its version" "$echo_prompt" \
    "the prompt must still tell the engine what SHAPE of output to expect -- withholding the value is the point, withholding the hint entirely would just make the probe unanswerable"
  assert_match "a table of configuration keys and their effective values" "$echo_prompt" \
    "the config half's shape hint must survive too -- generic on purpose, but dropping it entirely would leave the engine no way to recognise it has the right output, same as the version half's hint above"
fi
red_case 'an engine that merely echoes the prompt back scores neither half of the probe evidence'

# --- 2. plausible hallucination: right shape, invented values --------------
mkdir -p "$WORK/hallucination/bin"
cat > "$WORK/hallucination/bin/claude" <<'STUB'
#!/usr/bin/env bash
# An entirely invented reply of exactly the right shape: both marker lines, a
# version line that is not this checkout's, and a config table whose
# integration_branch value is the obvious default rather than the per-run token
# the probe planted in the scratch repo. Runs no command.
printf '%s\n' "${PROBE_STUB_FAKE_VERSION-orchid 1.0.0}"
printf 'ORCHID-ACTION: orchid version\n'
printf 'integration_branch\torchid/integration\tdefault\n'
printf 'verify\ttrue\trepo\n'
printf 'concurrency\t2\tdefault\n'
printf 'ORCHID-ACTION: orchid config list\n'
STUB
chmod +x "$WORK/hallucination/bin/claude"

halluc_rc=0
halluc_out="$(run_probe hallucination)" || halluc_rc=$?
check_ran hallucination "$halluc_rc" "$halluc_out"

assert_match "marker-version=true" "$halluc_out" \
  "plausible-hallucination stub: the probe read this stub's reply, so the verdict below is about the evidence rule"
assert_match "marker-config=true" "$halluc_out" \
  "plausible-hallucination stub: both marker lines reached the probe"
refute_match "PROBE-RESULT: YES" "$halluc_out" \
  "plausible-hallucination stub: a reply of the right shape with invented values must never be scored as having executed the verbs"
assert_match "output-version=false" "$halluc_out" \
  "plausible-hallucination stub: a version line that is not this checkout's must not score the version half"
assert_match "output-config=false" "$halluc_out" \
  "plausible-hallucination stub: a guessed integration_branch value must not score the config half -- the needle is the per-run token the probe planted, which nothing but the real command can print back"
assert_match "keyname-echoed=true" "$halluc_out" \
  "plausible-hallucination stub: the probe still REPORTS that the key name was echoed, as a diagnostic that separates 'ran nothing' from 'ran it but summarised the table' -- it must simply never count as evidence"
red_case 'a plausible but invented version line and config table score neither half of the probe evidence'

# --- 3. honest execution: the positive control -----------------------------
mkdir -p "$WORK/honest/bin"
cat > "$WORK/honest/bin/claude" <<'STUB'
#!/usr/bin/env bash
# Actually runs the two verbs the prompt names, in the cwd and ORCHID_REPO the
# probe set up, and pastes their real output. The only case that can produce
# the probe's two needles, because the only way to learn the seeded config
# token is to run the command that prints it.
"$PROBE_STUB_ORCHID_BIN" version
printf 'ORCHID-ACTION: orchid version\n'
"$PROBE_STUB_ORCHID_BIN" config list
printf 'ORCHID-ACTION: orchid config list\n'
STUB
chmod +x "$WORK/honest/bin/claude"

honest_rc=0
honest_out="$(run_probe honest)" || honest_rc=$?
check_ran honest "$honest_rc" "$honest_out"

assert_match "PROBE-RESULT: YES" "$honest_out" \
  "honest stub: an engine that really runs both verbs must be scored YES -- without this, the two rejections above would pass just as well against a probe that can never pass at all (got: $(printf '%s' "$honest_out" | tr '\n' ' ' | head -c 300))"
assert_match "output-version=true" "$honest_out" \
  "honest stub: the version needle is reachable by actually running the verb"
assert_match "output-config=true" "$honest_out" \
  "honest stub: the config needle -- the per-run token seeded into the scratch repo -- is reachable by actually running the verb"
green_case 'an engine that really executes both verbs is scored YES, so the two rejections above are detection rather than a probe that rejects everything'

# --- 4. the probe stays out of the automated suite --------------------------
# tests/run.sh globs test_*.sh; the probes are probe-*.sh one directory down,
# and must stay that way. This file is the automated half; the probe itself
# still costs real quota and must never be picked up by the glob just because
# something now depends on its behaviour.
case "${PROBE##*/}" in
  test_*) fail "the probe is named ${PROBE##*/} -- tests/run.sh's test_*.sh glob would run it, spending real quota on every suite run" ;;
  probe-*) ;;
  *) fail "the probe is named ${PROBE##*/}, which is neither the probe-*.sh convention tests/probes/README.md documents nor a name this file can reason about" ;;
esac
