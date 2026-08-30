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
#
# Caveat: containing claude to $scratch (so it only touches the throwaway
# repo, not your real cwd/tree) is instruction-level only — the prompt asks
# it to, but nothing here sandboxes or enforces it. Review the probe's
# aftermath (git status/log in $scratch, and your working tree) before
# trusting a YES/PARTIAL result at face value.

if ! command -v claude >/dev/null 2>&1; then
  echo "PROBE-RESULT: SKIP (claude not installed)"
  exit 0
fi

# Inline with_timeout (same process-group trick runners/orchid-launch uses,
# copied so this probe has no dependency on repo-internal libs): runs "$@"
# directly in the background — never through a wrapper function/subshell —
# so $! is the real command's own pid, then races a killer against it.
# `set -m` around the spawn puts the backgrounded job in its OWN process
# group (pgid == its own pid, same trick as orchid-launch's launch line),
# so on timeout the watcher can `kill -- -$pid` and reach the whole group
# instead of only an immediate child.
#
# This replaces a version that backgrounded a shell function doing
# `cd "$scratch" && claude ...`: killing that function's wrapper-subshell
# pid on timeout left the real `claude` process — a distinct child of the
# now-dead subshell, never itself placed in its own group — running and
# billing quota, orphaned under init once the trap's scratch-dir deletion
# raced past it. Empirically reproduced; fixed by never interposing that
# layer (the caller now does the `cd` itself, before calling with_timeout).
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
  grep -qiE 'login|auth|unauthorized|not authenticated|api.?key' <<<"$1"
}

scratch="$(mktemp -d)"
err_file="$(mktemp)"
cleanup() { rm -rf "$scratch"; rm -f "$err_file"; }
trap cleanup EXIT

# Guarded so a git fixture failure (e.g. no git on PATH, no write access to
# TMPDIR) reports a clean PROBE-RESULT instead of aborting under `set -e`
# with no PROBE-RESULT line at all.
if ! git -C "$scratch" init -q . 2>/dev/null || \
   ! git -C "$scratch" -c user.email=probe@orchid.local -c user.name="Orchid Probe" \
       commit -q --allow-empty -m root 2>/dev/null; then
  echo "PROBE-RESULT: ENV-UNAVAILABLE (git fixture failed)"
  exit 0
fi

PROMPT='Create a file named probe-marker.txt containing exactly one line: probe. Then commit it to git in this repository with the commit message "probe commit". Do this now; do not ask questions.'

# cd here, in the parent — NOT inside with_timeout/a wrapper function — so
# the thing with_timeout backgrounds is the bare `claude ...` invocation
# itself (see the with_timeout comment above for why that matters).
cd "$scratch"
set +e
stdout="$(with_timeout 120 claude -p "$PROMPT" --permission-mode acceptEdits 2>"$err_file")"
rc=$?
set -e
cd - >/dev/null
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
