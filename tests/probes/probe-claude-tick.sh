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
# marker lines AND independent evidence each verb actually ran: `version`'s
# own output string (e.g. "orchid 1.0.0-beta.1") appearing in the reply. A
# marker with no matching output is treated as a hallucinated no-op, not a
# pass. That expected string is READ FROM THIS CHECKOUT at probe start rather
# than hard-coded -- a hard-coded one silently rotted to the long-dead
# `1.0.0-m2` across two version bumps, which made this probe unable to report
# YES at all.
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
  printf '%s' "$1" | grep -qiE 'login|auth|unauthorized|not authenticated|api.?key'
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

PROMPT="Run the shell command \`$ORCHID_BIN version\` in this directory (its output looks like \"$expected_version_output\") and paste its output. Then, on its own line, print exactly: ORCHID-ACTION: orchid version
Then run the shell command \`$ORCHID_BIN config list\` in this directory and paste its output. Then, on its own line, print exactly: ORCHID-ACTION: orchid config list
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

marker_version=false
printf '%s\n' "$stdout" | grep -qE '^ORCHID-ACTION: orchid version$' && marker_version=true
marker_config=false
printf '%s\n' "$stdout" | grep -qE '^ORCHID-ACTION: orchid config list$' && marker_config=true

# Real command OUTPUT, not just a marker line: the version verb's own
# distinctive output string. A marker with no matching output means claude
# printed the marker without the command behind it actually running
# (hallucinated no-op) — that is NO, not YES, per this probe's whole point.
output_version=false
printf '%s\n' "$stdout" | grep -qF "$expected_version_output" && output_version=true
output_config=false
printf '%s\n' "$stdout" | grep -qiE 'integration_branch' && output_config=true

if [ "$marker_version" = true ] && [ "$output_version" = true ] \
   && [ "$marker_config" = true ] && [ "$output_config" = true ]; then
  echo "PROBE-RESULT: YES (flags: --permission-mode acceptEdits --allowedTools Bash; both markers present AND real command output ($expected_version_output / integration_branch) seen in reply — verbs actually ran headless via Bash) [claude rc=$rc]"
  exit 0
fi

if [ "$marker_version" = true ] || [ "$marker_config" = true ]; then
  echo "PROBE-RESULT: PARTIAL (flags: --permission-mode acceptEdits --allowedTools Bash; marker(s) printed [version=$marker_version config=$marker_config] but real output missing for at least one verb [version=$output_version config=$output_config] — a marker without matching output is a hallucinated no-op, not a real invocation — reply: $(printf '%s' "$stdout" | tr '\n' ' ' | head -c 200)) [claude rc=$rc]"
  exit 0
fi

if [ "$output_version" = true ] || [ "$output_config" = true ]; then
  echo "PROBE-RESULT: PARTIAL (flags: --permission-mode acceptEdits --allowedTools Bash; verb output seen but no ORCHID-ACTION marker line for it — reply: $(printf '%s' "$stdout" | tr '\n' ' ' | head -c 200)) [claude rc=$rc]"
  exit 0
fi

if [ "$rc" -ne 124 ] && is_auth_failure "$combined"; then
  echo "PROBE-RESULT: AUTH-UNAVAILABLE ($(printf '%s' "$combined" | head -n1))"
  exit 0
fi

evidence="rc=$rc"; [ "$rc" -eq 124 ] && evidence="$evidence (timed out after 120s)"
echo "PROBE-RESULT: NO (flags: --permission-mode acceptEdits --allowedTools Bash; no marker, no verb evidence; $evidence; output: $(printf '%s' "$combined" | tr '\n' ' ' | head -c 200))"
