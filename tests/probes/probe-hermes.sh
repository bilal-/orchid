#!/usr/bin/env bash
set -euo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
# SPENDS REAL QUOTA: two short round trips against the real `hermes` CLI.
#
# Two open questions this stub-based test suite can't settle (the stubs
# *are* the answer to those questions by construction):
#
#   1. review-shaped: does `hermes --safe-mode -t clarify -z "<prompt>"` --
#      the EXACT invocation plugins/engines/hermes/run uses for review/
#      critique -- still return the plain VERDICT/REASON contract text on
#      stdout against the real, installed CLI (not just the bare-marker
#      shape the task's own probed fact already confirmed)?
#
#   2. implement-shaped: plugins/engines/hermes/run does NOT ship an
#      `implement` path (see docs/engines/hermes.md, "Why no implement
#      yet") -- flag research alone (hermes --help + reading the installed
#      CLI's source under ~/.hermes/hermes-agent/) found no flag that
#      confines a file write to a given directory; `tools/file_tools.py`
#      only WARNS on a relative path resolving outside the workspace root
#      and never blocks an absolute one at all. This probe checks the ONE
#      half of that question a real round trip can answer safely: does a
#      RELATIVE-path write from `hermes --safe-mode -t file -z ...`,
#      cwd-scoped to a scratch dir, actually land inside that scratch dir?
#      It deliberately does NOT attempt to test the absolute-path escape
#      case for real (that would mean actually letting a probe write
#      outside its own scratch dir on this machine) -- a YES here is
#      necessary but not sufficient evidence for a future `implement` path;
#      it narrows the open question, it does not close it. Treat any
#      result here as informative only, never as clearance to wire up
#      `implement` without also settling the absolute-path question by some
#      other means (code review of a newer hermes release, an upstream
#      sandbox flag, etc.).
#
# Containment caveat (same as tests/probes/probe-claude-implement.sh):
# cwd-scoping the CLI to $scratch is what this probe controls; whether
# hermes ITSELF stays inside $scratch is exactly what's being tested, not
# assumed.
#
# v1-m4 Task 9 live dogfood (F13): this probe's `mktemp -d` scratch dir
# (macOS puts that under /var/folders/...) got every file-tool write
# refused outright as "classified as a sensitive system path" (rc 0, no
# marker file) -- hermes's file tools reject macOS's own temp-dir
# convention wholesale. A manual retry from a $HOME-rooted scratch dir
# instead got a real answer: the relative-path write landed inside the
# scratch dir (PARTIAL, per this probe's own definition below --
# necessary, not sufficient; absolute-path confinement is still
# unsettled). See docs/engines/hermes.md's "Known gotchas" for the
# operator-facing version of this note.

if ! command -v hermes >/dev/null 2>&1; then
  echo "PROBE-RESULT: SKIP (hermes not installed)"
  exit 0
fi

# Inline with_timeout (process-group variant, same trick
# probe-claude-implement.sh uses and documents at length): backgrounds "$@"
# directly (never through a wrapper function/subshell, so $! is the real
# command's own pid) in its OWN process group (`set -m`), so a timeout can
# `kill -- -$pid` and reach the whole group instead of only an immediate
# child.
with_timeout() {
  local secs="$1"; shift
  set -m
  "$@" & local pid=$!
  set +m
  ( sleep "$secs"; kill -- "-$pid" 2>/dev/null ) & local w=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$w" 2>/dev/null; then kill "$w" 2>/dev/null; wait "$w" 2>/dev/null; return "$rc"; fi
  return 124
}

is_auth_failure() {  # combined stdout+stderr text
  printf '%s' "$1" | grep -qiE 'login|auth|unauthorized|not authenticated|api.?key'
}

# --- Probe 1: review-shaped ---------------------------------------------
PROMPT_REVIEW='Acceptance criteria: the function returns true
Stop condition: one pass only
pack manifest: task.md(5b,truncated:false) diff.patch(40b,truncated:false)

Diff:
+def ok(): return True

Do not use any tools. Do not run any commands. Judge from the diff text alone.
Reply with exactly two lines:
VERDICT: approve OR request-changes
REASON: one sentence'

err_file="$(mktemp)"; trap 'rm -f "$err_file"' EXIT
set +e
stdout_review="$(with_timeout 60 hermes --safe-mode -t clarify -z "$PROMPT_REVIEW" 2>"$err_file")"
rc_review=$?
set -e
stderr_review="$(cat "$err_file")"
combined_review="$stdout_review"$'\n'"$stderr_review"

if [ "$rc_review" -eq 0 ] && printf '%s\n' "$stdout_review" | grep -qiE '^VERDICT:[[:space:]]*(approve|request-changes)[[:space:]]*$'; then
  echo "PROBE-RESULT: review-shaped YES (reply: $(printf '%s' "$stdout_review" | tr '\n' ' ' | head -c 200))"
elif [ "$rc_review" -ne 124 ] && is_auth_failure "$combined_review"; then
  echo "PROBE-RESULT: review-shaped AUTH-UNAVAILABLE ($(printf '%s' "$combined_review" | head -n1))"
elif [ "$rc_review" -eq 124 ]; then
  echo "PROBE-RESULT: review-shaped NO (timed out after 60s)"
else
  echo "PROBE-RESULT: review-shaped NO (rc=$rc_review; output: $(printf '%s' "$combined_review" | tr '\n' ' ' | head -c 200))"
fi

# --- Probe 2: implement-shaped (relative-path containment only) ---------
scratch="$(mktemp -d)"
cleanup2() { rm -rf "$scratch"; }
trap cleanup2 EXIT

PROMPT_IMPL='Create a file named probe-marker.txt in the current directory containing exactly one line: probe. Do this now; do not ask questions.'

: > "$err_file"
cd "$scratch"
set +e
stdout_impl="$(with_timeout 90 hermes --safe-mode -t file -z "$PROMPT_IMPL" 2>"$err_file")"
rc_impl=$?
set -e
cd - >/dev/null
stderr_impl="$(cat "$err_file")"
combined_impl="$stdout_impl"$'\n'"$stderr_impl"

if [ -f "$scratch/probe-marker.txt" ]; then
  content="$(cat "$scratch/probe-marker.txt" 2>/dev/null | tr '\n' ' ')"
  echo "PROBE-RESULT: implement-shaped PARTIAL (relative-path write landed inside the scratch dir as expected: '$content' -- this does NOT establish absolute-path confinement; see this probe's header and docs/engines/hermes.md)"
elif [ "$rc_impl" -ne 124 ] && is_auth_failure "$combined_impl"; then
  echo "PROBE-RESULT: implement-shaped AUTH-UNAVAILABLE ($(printf '%s' "$combined_impl" | head -n1))"
elif [ "$rc_impl" -eq 124 ]; then
  echo "PROBE-RESULT: implement-shaped NO (timed out after 90s, no marker file created)"
else
  echo "PROBE-RESULT: implement-shaped NO (rc=$rc_impl, no marker file created; output: $(printf '%s' "$combined_impl" | tr '\n' ' ' | head -c 200))"
fi
