#!/usr/bin/env bash
set -u
rc=0
BASH_BIN="${ORCHID_TEST_BASH:-${BASH:-bash}}"
suite_output="$(mktemp "${TMPDIR:-/tmp}/orchid-suite-output.XXXXXX")"
trap 'rm -f "$suite_output"' EXIT
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
  echo "== $t"
  test_rc=0
  : > "$suite_output"
  "$BASH_BIN" "$t" > "$suite_output" 2>&1 || test_rc=$?
  if [ "$test_rc" -eq 0 ]; then
    # A passing test is allowed to exercise deliberately alarming negative
    # fixtures, but those fixture diagnostics are not this suite run's
    # failures.  Keep the durable qualification records humans need and emit
    # one unambiguous result line; a failed test is printed verbatim below.
    # This is outcome-based filtering by the parent process, not an in-band
    # BEGIN/END marker a child can forge in its own output.
    grep -E '^[[:space:]]*(NOT-TESTED:|not-tested:|RED-CASE:|GREEN-CASE:|red-cases:)' \
      "$suite_output" || true
    printf '%s: OK\n' "$t"
  else
    cat "$suite_output"
    rc=1
  fi
done
exit "$rc"
