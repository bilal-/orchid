#!/usr/bin/env bash
set -u
rc=0
BASH_BIN="${ORCHID_TEST_BASH:-${BASH:-bash}}"
# Every test file launched from here can tell it is part of a WHOLE-SUITE run
# rather than a lone invocation. tests/test_hermetic_suite.sh is the only
# consumer today, and it needs the distinction rather than assuming it: on a
# machine with no vendor CLI installed, the run happening around that file is
# already the vendor-CLI-free run it would otherwise launch a second,
# byte-identical copy of.
export ORCHID_SUITE_RUN=1
for t in "$(dirname "$0")"/test_*.sh "$(dirname "$0")"/inv/test_*.sh; do
  [ -e "$t" ] || continue
  echo "== $t"; "$BASH_BIN" "$t" || rc=1
done
exit "$rc"
