#!/usr/bin/env bash
set -euo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
#
# Open question: does `agy -p` accept the prompt via stdin? `agy --help`
# shows `-p`/`--print`/`--prompt` taking a value inline; whether a bare `-`
# value (or plain stdin redirection) makes it read the prompt from stdin is
# untested — this probe spends a small amount of real quota (one short
# round trip per attempt) to find out.

if ! command -v agy >/dev/null 2>&1; then
  echo "PROBE-RESULT: SKIP (agy not installed)"
  exit 0
fi

# Inline with_timeout (same pattern as lib/common.sh, copied so this probe
# has no dependency on repo-internal libs): run "$@" in the background,
# race a killer against it, return the real command's exit code, or 124 on
# timeout.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local w=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$w" 2>/dev/null; then kill "$w" 2>/dev/null; wait "$w" 2>/dev/null; return "$rc"; fi
  return 124
}

is_auth_failure() {  # combined stdout+stderr text
  printf '%s' "$1" | grep -qiE 'login|auth|unauthorized|not authenticated|api.?key'
}

PROMPT='Reply with exactly OK'
err_file="$(mktemp)"; trap 'rm -f "$err_file"' EXIT

# --- Attempt A: `-` convention, prompt piped on stdin -----------------------
set +e
stdout_a="$(printf '%s' "$PROMPT" | with_timeout 60 agy -p - 2>"$err_file")"
rc_a=$?
set -e
stderr_a="$(cat "$err_file")"
combined_a="$stdout_a"$'\n'"$stderr_a"

if [ "$rc_a" -eq 0 ] && printf '%s' "$stdout_a" | grep -qiE '\bOK\b'; then
  echo "PROBE-RESULT: WORKED (form: \`agy -p -\` with prompt on stdin; reply: $(printf '%s' "$stdout_a" | tr '\n' ' ' | head -c 200))"
  exit 0
fi

if [ "$rc_a" -ne 124 ] && is_auth_failure "$combined_a"; then
  echo "PROBE-RESULT: AUTH-UNAVAILABLE (agy -p - : $(printf '%s' "$combined_a" | head -n1))"
  exit 0
fi

# --- Attempt B: plain stdin redirection into `-p`, no explicit `-` value ---
prompt_file="$(mktemp)"; printf '%s' "$PROMPT" > "$prompt_file"
: > "$err_file"

set +e
stdout_b="$(with_timeout 60 agy -p < "$prompt_file" 2>"$err_file")"
rc_b=$?
set -e
stderr_b="$(cat "$err_file")"
combined_b="$stdout_b"$'\n'"$stderr_b"
rm -f "$prompt_file"

if [ "$rc_b" -eq 0 ] && printf '%s' "$stdout_b" | grep -qiE '\bOK\b'; then
  echo "PROBE-RESULT: WORKED (form: \`agy -p < file\` stdin redirection; reply: $(printf '%s' "$stdout_b" | tr '\n' ' ' | head -c 200))"
  exit 0
fi

if [ "$rc_b" -ne 124 ] && is_auth_failure "$combined_b"; then
  echo "PROBE-RESULT: AUTH-UNAVAILABLE (agy -p < file : $(printf '%s' "$combined_b" | head -n1))"
  exit 0
fi

evidence_a="rc=$rc_a"; [ "$rc_a" -eq 124 ] && evidence_a="$evidence_a (timed out after 60s)"
evidence_b="rc=$rc_b"; [ "$rc_b" -eq 124 ] && evidence_b="$evidence_b (timed out after 60s)"
echo "PROBE-RESULT: NONE (neither form produced an OK reply — attempt A [$evidence_a]: $(printf '%s' "$combined_a" | tr '\n' ' ' | head -c 150); attempt B [$evidence_b]: $(printf '%s' "$combined_b" | tr '\n' ' ' | head -c 150))"
