#!/usr/bin/env bash
set -euo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
# SPENDS REAL QUOTA: this runs one real `claude -p` round trip.
#
# F8 (dogfood): the real pump-driven claude tick ran and executed ZERO
# verbs — `--permission-mode acceptEdits` alone authorizes file edits only,
# not the Bash tool, so headless claude politely explained it lacked
# permission and exited 0 (envelope ok, actions=0). plugins/engines/claude/
# run's `orchestrate` branch now also passes `--allowedTools Bash`. The
# real open question this probe answers: with Bash allowlisted, does
# headless claude actually EXECUTE `orchid` verbs by their absolute binary
# path (not just print a hallucinated marker line with no real command
# behind it)? Builds a scratch repo, asks claude to run `<abs>/bin/orchid
# version` and `<abs>/bin/orchid config list` in it, printing an
# ORCHID-ACTION marker for each, then inspects the transcript for BOTH the
# marker lines AND independent evidence each verb actually ran. A marker with
# no matching output is treated as a hallucinated no-op, not a pass.
#
# EVIDENCE INDEPENDENCE. Both halves of that evidence have to be values the
# model can only produce by RUNNING the command -- never values this probe
# handed it. The earlier form failed that on one half: it interpolated this
# checkout's exact `orchid version` line into the prompt ("its output looks
# like ...") and then grepped the reply for that same string, so an engine
# that merely echoed the prompt back scored the version half for free and only
# the config half still discriminated. Now:
#
#   * version half -- the prompt carries a GENERIC hint (one short line naming
#     the tool and its version) and never the line itself. The needle is this
#     checkout's real `orchid version` output, read at probe start. Still read
#     rather than hard-coded: a hard-coded one silently rotted to the long-dead
#     `1.0.0-m2` across two version bumps, which made this probe unable to
#     report YES at all.
#   * config half -- the scratch repo's own orchid.config is seeded with a
#     per-run token as `integration_branch`, and the needle is that token. The
#     prompt names no key and no value. The old needle was the literal key name
#     `integration_branch`: independent of the prompt, but eminently guessable,
#     so a plausible hallucination of a config table scored it anyway. A token
#     minted per run cannot be guessed, only read back out of the command.
#     Bounded, and deliberately so: that token also sits in the scratch repo's
#     own orchid.config, so an engine that reads THAT file instead of running
#     `config list` would print it too. Narrowing the needle to the
#     tab-separated three-column line `config list` actually emits would close
#     the gap, at the price of a NO for every cooperative engine that reformats
#     the table on the way out -- a false negative on a billed run, bought
#     against a shortcut nothing takes when it was told to run the command. The
#     version half is not reachable that way at all: nothing in the scratch repo
#     carries this checkout's version line. A YES needs BOTH halves, so the
#     verdict still rests on a verb having really run.
#
# Both needles are checked for reachability in this checkout BEFORE any quota
# is spent, so a probe that has become unsatisfiable reports ENV-UNAVAILABLE
# rather than a confident NO about the engine.
#
# tests/test_probe_evidence.sh exercises that rule offline, against stub
# engines (echo-back, plausible hallucination, honest execution) on a PATH
# that never reaches a real CLI -- so the rule is covered by the suite rather
# than only by a live, billed run.
#
# Caveat: containing claude to $scratch is instruction-level only, same
# caveat as probe-claude-implement.sh — review the probe's aftermath before
# trusting a YES/PARTIAL result at face value.

if ! command -v claude >/dev/null 2>&1; then
  echo "PROBE-RESULT: SKIP (claude not installed)"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCHID_BIN="$REPO_ROOT/bin/orchid"

# Inline with_timeout, corrected process-group form (lib/common.sh's fixed
# version, copied so this probe has no dependency on repo-internal libs):
# BOTH the timed command and the watcher are backgrounded under `set -m` so
# each lands in its own process group — a bare `kill "$pid"`/`kill "$w"`
# (no leading dash) only ever reaches one process, which either orphans the
# real work under init on a timeout (billing quota unattended) or, on the
# ordinary early-finish path, orphans the watcher's own already-forked
# `sleep` — which then holds this probe's stdout pipe open for the full
# timeout even though claude itself is long done. Found and fixed in
# lib/common.sh while building runners/orchid-tick (v1-m2 Task 7); mirrored
# here rather than sourcing that file, per this directory's no-repo-internal-
# deps convention.
with_timeout() {
  local secs="$1"; shift
  set -m
  "$@" & local pid=$!
  set +m
  set -m
  ( sleep "$secs"; kill -- "-$pid" 2>/dev/null ) & local w=$!
  set +m
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$w" 2>/dev/null; then kill -- "-$w" 2>/dev/null; wait "$w" 2>/dev/null; return "$rc"; fi
  return 124
}

is_auth_failure() {  # combined stdout+stderr text
  # Herestring, not a pipe, for the pipefail/SIGPIPE reason spelled out at the
  # evidence checks below: `grep -q` leaving early on a long reply would take
  # the upstream `printf` down with it and turn a match into a "no".
  grep -qiE 'login|auth|unauthorized|not authenticated|api.?key' <<<"$1"
}

scratch="$(mktemp -d)"
err_file="$(mktemp)"
cleanup() { rm -rf "$scratch"; rm -f "$err_file"; }
trap cleanup EXIT

# Guarded so a git/orchid fixture failure reports a clean PROBE-RESULT
# instead of aborting under `set -e` with no PROBE-RESULT line at all.
if ! git -C "$scratch" init -q . 2>/dev/null || \
   ! git -C "$scratch" -c user.email=probe@orchid.local -c user.name="Orchid Probe" \
       commit -q --allow-empty -m root 2>/dev/null; then
  echo "PROBE-RESULT: ENV-UNAVAILABLE (git fixture failed)"
  exit 0
fi
mkdir -p "$scratch/.orchid/tasks"

if ! expected_version_output="$("$ORCHID_BIN" version 2>/dev/null)" \
   || [ -z "$expected_version_output" ]; then
  echo "PROBE-RESULT: ENV-UNAVAILABLE (orchid version did not run in this checkout)"
  exit 0
fi

# The config half's needle: a per-run token planted in the SCRATCH repo's own
# orchid.config and never mentioned in the prompt. `integration_branch` is the
# first key in lib/config-keys.txt, so the line carrying the token is the first
# line `config list` prints -- the part of a long table most likely to survive
# an engine that pastes only the head of it. Letters, digits and hyphens only --
# no regex metacharacter and no shell metacharacter -- so it is both a plain
# `grep -F` needle and a legal branch-shaped value.
config_token="orchid-probe-$$-$(date +%s)"
printf 'integration_branch=%s\n' "$config_token" > "$scratch/orchid.config"

# An inherited ORCHID_INTEGRATION_BRANCH outranks the repo file in config_get's
# precedence (env > repo > user > default), which would quietly serve the
# operator's own value in place of the token and leave the grep below looking
# for something `config list` never prints. Drop it for this probe and for
# everything it spawns.
unset ORCHID_INTEGRATION_BRANCH

# Neither needle is worth spending quota on if this checkout cannot actually
# produce it: an unreachable needle would make every run report NO about the
# ENGINE for a reason that is really about the fixture. No pipe into `grep -q`
# here -- see the herestring note at the evidence checks below.
config_list_selfcheck="$(ORCHID_REPO="$scratch" "$ORCHID_BIN" config list 2>/dev/null || true)"
case "$config_list_selfcheck" in
  *"$config_token"*) ;;
  *) echo "PROBE-RESULT: ENV-UNAVAILABLE (orchid config list did not report this probe's seeded integration_branch token in this checkout)"
     exit 0 ;;
esac

# GENERIC hints only. Naming the shape of each command's output is what lets a
# cooperative engine recognise it has the right thing; naming the VALUE would
# hand back the answer and make the greps below unfalsifiable.
PROMPT="Run the shell command \`$ORCHID_BIN version\` in this directory and paste its output. It prints one short line naming the tool and its version; do not guess that line, run the command and copy exactly what it printed. Then, on its own line, print exactly: ORCHID-ACTION: orchid version
Then run the shell command \`$ORCHID_BIN config list\` in this directory and paste its output IN FULL, every line, starting with the first. It prints a table of configuration keys and their effective values; do not summarise it and do not guess any value. Then, on its own line, print exactly: ORCHID-ACTION: orchid config list
Do this now; do not ask questions."

cd "$scratch"
export ORCHID_REPO="$scratch"
set +e
stdout="$(with_timeout 120 claude -p "$PROMPT" --permission-mode acceptEdits --allowedTools Bash 2>"$err_file")"
rc=$?
set -e
cd - >/dev/null
stderr="$(cat "$err_file")"
combined="$stdout"$'\n'"$stderr"

# HERESTRINGS, never `printf ... | grep -q`, for every check below. This file
# runs under `set -o pipefail` (line 2) and `grep -q` exits at its FIRST match,
# which SIGPIPEs the upstream writer mid-write; pipefail then promotes that 141
# to the pipeline's status, so the check reports "not found" for a needle it
# DID find. It only bites once the reply is long enough that the writer is
# still writing when grep leaves -- i.e. exactly on the real, chatty replies
# this probe exists to judge, and never on the short ones you test it with.
# tests/helpers.sh's assert_match carries the same fix for the same reason.
marker_version=false
grep -qE '^ORCHID-ACTION: orchid version$' <<<"$stdout" && marker_version=true
marker_config=false
grep -qE '^ORCHID-ACTION: orchid config list$' <<<"$stdout" && marker_config=true

# Real command OUTPUT, not just a marker line -- and, for both verbs, a value
# the prompt never carried (see EVIDENCE INDEPENDENCE at the top). A marker
# with no matching output means claude printed the marker without the command
# behind it actually running (hallucinated no-op) — that is NO, not YES, per
# this probe's whole point.
output_version=false
grep -qF "$expected_version_output" <<<"$stdout" && output_version=true
output_config=false
grep -qF "$config_token" <<<"$stdout" && output_config=true

# DIAGNOSTIC ONLY, never a pass condition. `integration_branch` is a key name
# an engine can guess without running anything, which is why it is no longer
# the config half's evidence. It is still worth reporting: it separates "the
# engine ran nothing at all" from "the engine ran `config list` but summarised
# the table instead of pasting the line the token is on".
keyname_echoed=false
grep -qiF 'integration_branch' <<<"$stdout" && keyname_echoed=true

FLAGS="--permission-mode acceptEdits --allowedTools Bash"
# One evidence clause, identical on every outcome below, so a reader (and
# tests/test_probe_evidence.sh) can tell WHICH half of the evidence held
# without having to parse a different sentence per verdict.
evidence="marker-version=$marker_version marker-config=$marker_config output-version=$output_version output-config=$output_config keyname-echoed=$keyname_echoed rc=$rc"

if [ "$marker_version" = true ] && [ "$output_version" = true ] \
   && [ "$marker_config" = true ] && [ "$output_config" = true ]; then
  echo "PROBE-RESULT: YES (flags: $FLAGS; both markers present AND real command output seen in reply — this checkout's own version line plus the scratch repo's seeded config token, neither of which the prompt carried — verbs actually ran headless via Bash) -- $evidence"
  exit 0
fi

if [ "$marker_version" = true ] || [ "$marker_config" = true ]; then
  echo "PROBE-RESULT: PARTIAL (flags: $FLAGS; marker(s) printed but real output missing for at least one verb — a marker without matching output is a hallucinated no-op, not a real invocation — reply: $(printf '%s' "$stdout" | tr '\n' ' ' | head -c 200)) -- $evidence"
  exit 0
fi

if [ "$output_version" = true ] || [ "$output_config" = true ]; then
  echo "PROBE-RESULT: PARTIAL (flags: $FLAGS; verb output seen but no ORCHID-ACTION marker line for it — reply: $(printf '%s' "$stdout" | tr '\n' ' ' | head -c 200)) -- $evidence"
  exit 0
fi

if [ "$rc" -ne 124 ] && is_auth_failure "$combined"; then
  echo "PROBE-RESULT: AUTH-UNAVAILABLE ($(printf '%s' "$combined" | head -n1)) -- $evidence"
  exit 0
fi

timing=""; [ "$rc" -eq 124 ] && timing=" (timed out after 120s)"
echo "PROBE-RESULT: NO (flags: $FLAGS; no marker, no verb evidence$timing; output: $(printf '%s' "$combined" | tr '\n' ' ' | head -c 200)) -- $evidence"
