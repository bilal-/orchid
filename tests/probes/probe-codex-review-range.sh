#!/usr/bin/env bash
set -euo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
#
# Open question: does `codex exec review` accept an explicit base..head
# range/args, or only a single-ended selector? This reads `--help` only —
# no paid review is ever run — because the usage text alone answers the
# API-shape question.

if ! command -v codex >/dev/null 2>&1; then
  echo "PROBE-RESULT: SKIP (codex not installed)"
  exit 0
fi

set +e
help_out="$(codex exec review --help 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  if printf '%s' "$help_out" | grep -qiE 'login|auth|unauthorized|not authenticated|api.?key'; then
    echo "PROBE-RESULT: AUTH-UNAVAILABLE (codex exec review --help exited $rc: $(printf '%s' "$help_out" | head -n1))"
    exit 0
  fi
  echo "PROBE-RESULT: AMBIGUOUS (codex exec review --help exited $rc with no usage text)"
  exit 0
fi

usage_line="$(printf '%s\n' "$help_out" | grep -m1 -E '^Usage:' || true)"

has_base=false; has_head=false; has_range=false; has_commit=false
printf '%s\n' "$help_out" | grep -qiE -- '--base\b'   && has_base=true
printf '%s\n' "$help_out" | grep -qiE -- '--head\b'   && has_head=true
printf '%s\n' "$help_out" | grep -qiE -- '(--range\b|\brange\b)' && has_range=true
printf '%s\n' "$help_out" | grep -qiE -- '--commit\b' && has_commit=true

if [ "$has_base" = true ] && [ "$has_head" = true ]; then
  finding="YES: explicit --base and --head flags both present ($usage_line)"
elif [ "$has_range" = true ]; then
  finding="YES: explicit range arg/flag present ($usage_line)"
elif [ "$has_base" = true ] && [ "$has_commit" = true ]; then
  base_line="$(printf '%s\n' "$help_out" | grep -m1 -E '^\s*--base\b')"
  commit_line="$(printf '%s\n' "$help_out" | grep -m1 -E '^\s*--commit\b')"
  finding="PARTIAL: no two-endpoint base..head range flag. --base <BRANCH> compares against the implicit current HEAD/worktree state ($base_line); --commit <SHA> reviews a single commit ($commit_line). $usage_line"
elif [ "$has_base" = true ]; then
  finding="PARTIAL: --base flag present (implicit HEAD end, not an explicit range) but no --head/--commit seen. $usage_line"
else
  finding="AMBIGUOUS: no --base/--head/--range/--commit flags recognized in help output. $usage_line"
fi

echo "PROBE-RESULT: $finding"
