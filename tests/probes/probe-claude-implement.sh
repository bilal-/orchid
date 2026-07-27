#!/usr/bin/env bash
set -euo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
# SPENDS REAL QUOTA: this runs one full `claude -p` implement round trip.
#
# Open question: can `claude -p --permission-mode acceptEdits` (the exact
# invocation plugins/engines/claude/run uses for `implement`) actually
# create a file and commit it to git, unattended? Builds a scratch repo,
# asks claude to create a marker file and commit it, then inspects
# `git log` for the result.

if ! command -v claude >/dev/null 2>&1; then
  echo "PROBE-RESULT: SKIP (claude not installed)"
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

scratch="$(mktemp -d)"
err_file="$(mktemp)"
cleanup() { rm -rf "$scratch"; rm -f "$err_file"; }
trap cleanup EXIT

git -C "$scratch" init -q .
git -C "$scratch" -c user.email=probe@orchid.local -c user.name="Orchid Probe" \
  commit -q --allow-empty -m root

PROMPT='Create a file named probe-marker.txt containing exactly one line: probe. Then commit it to git in this repository with the commit message "probe commit". Do this now; do not ask questions.'

_run_claude() {
  cd "$scratch" && claude -p "$PROMPT" --permission-mode acceptEdits
}

set +e
stdout="$(with_timeout 120 _run_claude 2>"$err_file")"
rc=$?
set -e
stderr="$(cat "$err_file")"
combined="$stdout"$'\n'"$stderr"

commit_count="$(git -C "$scratch" rev-list --count HEAD 2>/dev/null || echo 1)"
dirty="$(git -C "$scratch" status --porcelain 2>/dev/null || true)"

if [ "$commit_count" -gt 1 ]; then
  new_log="$(git -C "$scratch" log --oneline -n "$((commit_count - 1))")"
  echo "PROBE-RESULT: YES (git log after run: $(printf '%s' "$new_log" | tr '\n' ' | ')) [claude rc=$rc]"
  exit 0
fi

if [ -n "$dirty" ]; then
  echo "PROBE-RESULT: PARTIAL (no new commit, but the worktree has uncommitted changes: $(printf '%s' "$dirty" | tr '\n' ' | ')) [claude rc=$rc]"
  exit 0
fi

if [ "$rc" -ne 124 ] && is_auth_failure "$combined"; then
  echo "PROBE-RESULT: AUTH-UNAVAILABLE ($(printf '%s' "$combined" | head -n1))"
  exit 0
fi

evidence="rc=$rc"; [ "$rc" -eq 124 ] && evidence="$evidence (timed out after 120s)"
echo "PROBE-RESULT: NO (no commit, no working-tree changes; $evidence; output: $(printf '%s' "$combined" | tr '\n' ' ' | head -c 200))"
