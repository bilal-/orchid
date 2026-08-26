#!/usr/bin/env bash
set -u
rc=0
BASH_BIN="${ORCHID_TEST_BASH:-${BASH:-bash}}"
segment_index=0
# Every test file launched from here can tell it is part of a WHOLE-SUITE run
# rather than a lone invocation. tests/test_hermetic_suite.sh is the only
# consumer today, and it needs the distinction rather than assuming it: on a
# machine with no vendor CLI installed, the run happening around that file is
# already the vendor-CLI-free run it would otherwise launch a second,
# byte-identical copy of.
#
# The value is THIS RUNNER'S OWN PHYSICAL PATH, not a bare `1`. The consumer
# stands its own proof down on the strength of this marker, so the marker has
# to identify what it claims to: a bare `1` left in an operator's environment,
# or exported by some unrelated harness, would silence that proof on a
# vendor-CLI-free machine with nothing having run in its place. A path can be
# compared against the runner the consumer resolved for itself, and matches
# only when this file really is the run around it. `pwd -P` for the same
# reason tests/helpers.sh canonicalizes REPO_ROOT: a checkout reached through
# a symlinked path (macOS /var/folders -> /private/var/folders) must compare
# equal to the physical path the consumer derives.
ORCHID_SUITE_RUN="$(cd "$(dirname "$0")" && pwd -P)/run.sh"
export ORCHID_SUITE_RUN
for t in "$(dirname "$0")"/test_*.sh "$(dirname "$0")"/inv/test_*.sh; do
  [ -e "$t" ] || continue
  segment_index=$((segment_index + 1))
  segment_token="$$-$segment_index"
  echo "== $t"
  printf 'ORCHID-VERIFY-SEGMENT %s BEGIN %s\n' "$segment_token" "$t"
  test_rc=0
  "$BASH_BIN" "$t" || test_rc=$?
  printf 'ORCHID-VERIFY-SEGMENT %s END %s\n' "$segment_token" "$test_rc"
  [ "$test_rc" -eq 0 ] || rc=1
done
exit "$rc"
