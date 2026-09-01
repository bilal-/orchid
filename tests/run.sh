#!/usr/bin/env bash
set -u
rc=0
BASH_BIN="${ORCHID_TEST_BASH:-${BASH:-bash}}"
suite_output="$(mktemp "${TMPDIR:-/tmp}/orchid-suite-output.XXXXXX")"
# THE RECORDER'S RECEIPT (T016). tests/helpers.sh's EXIT trap fails an enrolled
# gate file that recorded no RED or GREEN case -- and that trap is a slot the
# gate can overwrite. One `trap ... EXIT` of its own after the source, which is
# how a gate that wants its own cleanup is written, takes the requirement off
# the file that carries it: nothing counts the cases, no summary is printed,
# the file exits 0, and in a log it is indistinguishable from a gate that
# complied. That the file REACHED helpers.sh, which
# tests/inv/test_INV-15_no_optional_gate.sh section 2 proves for every enrolled
# file, says the enforcement was offered; it cannot say it ran.
#
# So `red_case`/`green_case` append a line naming the file they ran in to this
# receipt as they run, and the check below -- in the PARENT, the one process a
# gate file cannot reach into -- requires that line for the file it just
# launched. A gate can disarm its own trap. It cannot disarm its parent, and it
# cannot write the line without having called the recorder.
proof_receipt="$(mktemp "${TMPDIR:-/tmp}/orchid-proof-receipt.XXXXXX")"
export ORCHID_PROOF_RECEIPT="$proof_receipt"
trap 'rm -f "$suite_output" "$proof_receipt"' EXIT
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
  # Truncated per file, so a line written by SOME OTHER test's child process --
  # every fixture in this suite inherits the variable -- cannot outlive the run
  # that produced it. Within a run, lines are told apart by the path they name.
  : > "$proof_receipt"
  "$BASH_BIN" "$t" > "$suite_output" 2>&1 || test_rc=$?

  # The file's own resolved physical path, built exactly the way
  # tests/helpers.sh builds PROOF_SELF, so the two compare equal whichever
  # spelling the glob above produced. A `cd` that fails leaves this naming a
  # path nothing can have written, and the requirement below then fails closed.
  proof_self="$(cd "$(dirname "$t")" 2>/dev/null && pwd -P)/${t##*/}"
  # Required two ways, and the union can only over-require. By LOCATION, for
  # everything this runner globbed out of tests/inv/ -- which needs the child to
  # have declared nothing, so a gate that never reaches helpers.sh at all is
  # caught here too -- and by the child's own `enrolled` line, which is how the
  # whole-file proofs named in helpers.sh's PROOF_ENROLLED_FILES declare
  # themselves without this file keeping a second copy of that list.
  proof_required=0
  case "$t" in */inv/test_*.sh) proof_required=1 ;; esac
  if grep -qxF "enrolled $proof_self" "$proof_receipt" 2>/dev/null; then
    proof_required=1
  fi
  if [ "$proof_required" -eq 1 ]; then
    for proof_kind in red green; do
      if ! grep -qxF "$proof_kind $proof_self" "$proof_receipt" 2>/dev/null; then
        printf '%s: FAIL: enrolled in the RED-case rule, and no %s_case call was observed to run in it -- the case has to be RECORDED by a call that executes, not offered by a file that loads tests/helpers.sh and then replaces the EXIT trap that would have required it (docs/specs/kernel.md, "Proof discipline")\n' \
          "$t" "$proof_kind"
        test_rc=1
      fi
    done
  fi

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
