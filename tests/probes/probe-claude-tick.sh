#!/usr/bin/env bash
set -euo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
# SPENDS REAL QUOTA: this runs one real `claude -p` round trip.
#
# Open question (v1-m2 Task 7): can `claude -p --permission-mode
# acceptEdits` — the exact flag plugins/engines/claude/run's `orchestrate`
# branch guesses, unverified — actually EXECUTE a Bash verb headless (not
# just edit files, which probe-claude-implement.sh already answered), and
# does it reliably print the `ORCHID-ACTION: <command>` marker line the
# adapter greps out of its transcript? Builds a scratch repo, asks claude to
# run `orchid status` in it and print the marker, then inspects the
# transcript for both the marker line and independent evidence the verb
# actually ran (`orchid status`'s own "run_status:" banner appearing in the
# reply).
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

PROMPT="Run the shell command \`$ORCHID_BIN status\` in this directory (its output starts with a line like \"run_status: ...\") and paste its output. Then, on its own line, print exactly: ORCHID-ACTION: orchid status
Do this now; do not ask questions."

cd "$scratch"
export ORCHID_REPO="$scratch"
set +e
stdout="$(with_timeout 120 claude -p "$PROMPT" --permission-mode acceptEdits 2>"$err_file")"
rc=$?
set -e
cd - >/dev/null
stderr="$(cat "$err_file")"
combined="$stdout"$'\n'"$stderr"

has_marker=false
printf '%s\n' "$stdout" | grep -qE '^ORCHID-ACTION: ' && has_marker=true
has_verb_evidence=false
printf '%s\n' "$stdout" | grep -qiE 'run_status:' && has_verb_evidence=true

if [ "$has_marker" = true ] && [ "$has_verb_evidence" = true ]; then
  echo "PROBE-RESULT: YES (flags: --permission-mode acceptEdits; marker present AND run_status: seen in reply — verb actually ran headless) [claude rc=$rc]"
  exit 0
fi

if [ "$has_marker" = true ]; then
  echo "PROBE-RESULT: PARTIAL (flags: --permission-mode acceptEdits; marker line printed, but no run_status: evidence the verb actually executed — reply: $(printf '%s' "$stdout" | tr '\n' ' ' | head -c 200)) [claude rc=$rc]"
  exit 0
fi

if [ "$has_verb_evidence" = true ]; then
  echo "PROBE-RESULT: PARTIAL (flags: --permission-mode acceptEdits; verb output seen, but no ORCHID-ACTION marker line — reply: $(printf '%s' "$stdout" | tr '\n' ' ' | head -c 200)) [claude rc=$rc]"
  exit 0
fi

if [ "$rc" -ne 124 ] && is_auth_failure "$combined"; then
  echo "PROBE-RESULT: AUTH-UNAVAILABLE ($(printf '%s' "$combined" | head -n1))"
  exit 0
fi

evidence="rc=$rc"; [ "$rc" -eq 124 ] && evidence="$evidence (timed out after 120s)"
echo "PROBE-RESULT: NO (flags: --permission-mode acceptEdits; no marker, no verb evidence; $evidence; output: $(printf '%s' "$combined" | tr '\n' ' ' | head -c 200))"
