#!/usr/bin/env bash
set -u
rc=0
BASH_BIN="${ORCHID_TEST_BASH:-${BASH:-bash}}"
for t in "$(dirname "$0")"/test_*.sh "$(dirname "$0")"/inv/test_*.sh; do
  [ -e "$t" ] || continue
  echo "== $t"; "$BASH_BIN" "$t" || rc=1
done
exit "$rc"
