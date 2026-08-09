#!/usr/bin/env bash
# THE NO-VENDOR-CLI PROOF (T013).
#
# Hosted CI had never been green. The workflow existed, but nothing was pushed
# until it had already been written, so its first three runs were also its
# first exercise -- and they failed on ubuntu-latest AND macos-latest for the
# same reason: the deterministic suite was not hermetic. It asserted, through
# capsuite's binaries_present check, that `codex`, `claude` and `agy` resolve
# on PATH. They do on the author's machine. They do not on a runner. So
# `scripts/ci-local.sh` was green locally and red everywhere else, and the one
# thing that would have caught it -- running the suite without those CLIs --
# was something no committed artifact did.
#
# This file is that artifact. It builds a PATH on which every vendor CLI is
# UNRESOLVABLE (not shadowed by a shim: `command -v codex` must fail outright,
# which is the state a runner is actually in), and runs the whole suite on it.
# A test that reintroduces a dependency on an installed vendor CLI fails here,
# on the author's machine, at the same commit -- rather than on a runner, three
# pushes later.
#
# On a machine that has no vendor CLI installed, the suite run already in
# progress around this file IS that run, so there is nothing to launch and
# section 4b skips it rather than doubling every CI job to re-answer the same
# question. The skip is recorded, never silent, and it never applies where the
# two PATHs actually differ.
#
# WHY A MIRROR AND NOT A PRUNED PATH. Removing whole directories from PATH is
# not an option: on macOS `codex` and `jq` routinely live in the same Homebrew
# bin. So each PATH entry that actually contains a vendor CLI is replaced by a
# scratch directory of symlinks to everything in it EXCEPT those names. Entries
# with no vendor CLI in them are passed through untouched -- which, on a hosted
# runner, is all of them, so the PATH the runner sees is the PATH this proof
# runs on, byte for byte.
#
# RECURSION GUARD. tests/run.sh globs tests/test_*.sh, so the run this file
# launches re-enters this file, which would launch another run, forever. The
# guard is the ORCHID_HERMETIC_PROOF marker checked below, BEFORE anything else
# happens -- before helpers.sh is even sourced. It is not enough to write the
# guard and trust it: a refactor that renamed this file out of the glob, or
# dropped the marker from the child environment, would leave a guard that
# guards nothing and a proof that proves nothing. So both halves are asserted.
# The guard itself is exercised twice -- once directly, against a synthetic
# re-entry (section 3), and once for real, by counting the marked child run's
# re-entries, which must be exactly one (section 5). Glob membership, the half
# that must hold even when no nested run happens, is asked of tests/run.sh's
# actual glob instead (section 4a).

# ---------------------------------------------------------------------------
# THE GUARD ITSELF. First statement in the file, deliberately: nothing above it
# may cost anything or create anything, because this branch runs once per
# nested suite run.
# ---------------------------------------------------------------------------
if [ -n "${ORCHID_HERMETIC_PROOF:-}" ]; then
  if [ -n "${ORCHID_HERMETIC_PROOF_LOG:-}" ]; then
    printf '%s\n' "$ORCHID_HERMETIC_PROOF" >> "$ORCHID_HERMETIC_PROOF_LOG"
  fi
  echo "  NOT-TESTED: hermetic-suite-nested -- recursion guard (depth marker '$ORCHID_HERMETIC_PROOF'): this file is re-entered by the tests/run.sh glob of the run it launched. Skipping, never re-launching."
  exit 0
fi

source "$(dirname "$0")/helpers.sh"

SELF="$REPO_ROOT/tests/test_hermetic_suite.sh"
RUNNER="$REPO_ROOT/tests/run.sh"
[ -f "$SELF" ] \
  || { fail "this proof must live at tests/test_hermetic_suite.sh so tests/run.sh globs it"; exit 1; }
[ -f "$RUNNER" ] || { fail "tests/run.sh is missing"; exit 1; }

# The vendor CLIs an Orchid engine adapter can shell out to. `codex`, `claude`
# and `agy` are the three the built-in engine manifests declare and the three
# the broken assertions named; `hermes` and `openclaw` are the other two
# shipped adapters reach for, and a suite that started depending on one of them
# would be the same bug wearing a different name.
VENDOR_CLIS=(codex claude agy hermes openclaw)

# Tools the suite legitimately needs and the mirror must therefore preserve.
# jq is the one that matters: it is a declared dependency of the harness and,
# on macOS, it lives in the very directory a vendor CLI is most likely to be
# installed into.
REQUIRED_TOOLS=(jq git bash env awk sed grep find)

# ===========================================================================
# 1 -- build the vendor-CLI-free PATH.
# ===========================================================================
MIRROR_ROOT="$WORK/pathmirror"
mkdir -p "$MIRROR_ROOT"

dir_has_vendor_cli() {  # <dir>
  local d="$1" v
  for v in "${VENDOR_CLIS[@]}"; do
    if [ -e "$d/$v" ] || [ -L "$d/$v" ]; then return 0; fi
  done
  return 1
}

# mirror_without_vendor_clis <dir> <index> -- populate a scratch directory
# with symlinks to every entry of <dir> except the vendor CLIs, and leave its
# path in MIRROR_RESULT. Symlinks, not copies: the mirrored tools must be the
# real ones, byte for byte.
#
# The result comes back through a global rather than stdout on purpose. A
# `$( ... )` form would run this in a subshell, where a `fail` is counted into
# a FAILS that dies with the subshell and an aborted mirror would hand the
# caller an empty string -- which, spliced into a PATH, is the current
# directory. A mirror that silently half-worked is exactly the kind of quiet
# hole this file exists to close.
MIRROR_RESULT=""
mirror_without_vendor_clis() {
  local d="$1" mirror entry v skip
  mirror="$MIRROR_ROOT/$2"
  MIRROR_RESULT=""
  mkdir -p "$mirror" || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    skip=0
    for v in "${VENDOR_CLIS[@]}"; do
      if [ "$entry" = "$v" ]; then skip=1; fi
    done
    [ "$skip" -eq 0 ] || continue
    ln -s "$d/$entry" "$mirror/$entry" || return 1
  done < <(list_dir_entries "$d")
  MIRROR_RESULT="$mirror"
}

path_entries=()
IFS=':' read -r -a path_entries <<< "$PATH"
[ "${#path_entries[@]}" -gt 0 ] \
  || { fail "PATH is empty -- there is nothing to build a vendor-CLI-free PATH from"; exit 1; }
HERMETIC_PATH=""
mirrored_count=0
for path_entry in "${path_entries[@]}"; do
  [ -n "$path_entry" ] || continue
  [ -d "$path_entry" ] || continue
  if dir_has_vendor_cli "$path_entry"; then
    mirrored_count=$((mirrored_count + 1))
    mirror_without_vendor_clis "$path_entry" "$mirrored_count" \
      || { fail "cannot mirror the PATH entry '$path_entry' without its vendor CLIs -- refusing to run the proof on a PATH that silently lost tools"; exit 1; }
    path_entry="$MIRROR_RESULT"
  fi
  if [ -z "$HERMETIC_PATH" ]; then
    HERMETIC_PATH="$path_entry"
  else
    HERMETIC_PATH="$HERMETIC_PATH:$path_entry"
  fi
done
[ -n "$HERMETIC_PATH" ] \
  || { fail "no usable directory survived PATH filtering -- refusing to run the suite on an empty PATH"; exit 1; }
echo "  vendor-CLI-free PATH: $mirrored_count of ${#path_entries[@]} PATH entries needed mirroring"
if [ "$mirrored_count" -eq 0 ]; then
  not_tested "vendor-cli-removal" \
    "the PATH-mirroring code path. This machine has none of ${VENDOR_CLIS[*]} installed, so nothing needed removing and the PATH below is the ambient PATH unchanged. The no-vendor-CLI guarantee itself still holds here -- a hosted runner is in exactly this state, which is why section 4b can lean on the surrounding suite run instead of launching a duplicate -- but the mirror is exercised only on a machine that actually has a vendor CLI installed"
fi

# ===========================================================================
# 2 -- and prove it. Both directions: no vendor CLI resolves, every tool the
# suite needs still does. A child bash is asked, not this shell, because this
# shell has already cached command paths.
# ===========================================================================
resolves_under_hermetic_path() {  # <name>
  PATH="$HERMETIC_PATH" "$BASH" -c 'command -v "$1" >/dev/null 2>&1' _ "$1"
}
for vendor_cli in "${VENDOR_CLIS[@]}"; do
  if resolves_under_hermetic_path "$vendor_cli"; then
    fail "the vendor-CLI-free PATH still resolves '$vendor_cli' -- the nested run below would not be proving anything"
  fi
done
for required_tool in "${REQUIRED_TOOLS[@]}"; do
  resolves_under_hermetic_path "$required_tool" \
    || fail "filtering the vendor CLIs out of PATH also removed '$required_tool', which the suite legitimately needs"
done

# ===========================================================================
# 3 -- the recursion guard, exercised directly before it is relied on.
# ===========================================================================
guard_probe_log="$WORK/guard-probe.log"
: > "$guard_probe_log"
guard_rc=0
guard_out="$(ORCHID_HERMETIC_PROOF=probe ORCHID_HERMETIC_PROOF_LOG="$guard_probe_log" \
  "$BASH" "$SELF" 2>&1)" || guard_rc=$?
assert_eq 0 "$guard_rc" "a guarded re-entry must exit cleanly rather than failing the suite"
assert_match 'recursion guard' "$guard_out" "a guarded re-entry says why it stopped"
assert_match 'NOT-TESTED' "$guard_out" \
  "a guarded re-entry is recorded in the not-tested vocabulary, never as a silent pass"
assert_eq 1 "$(grep -c . "$guard_probe_log")" \
  "a guarded re-entry must record exactly one entry in the re-entry log"
grep -q 'vendor-CLI-free PATH' <<<"$guard_out" \
  && fail "a guarded re-entry reached the PATH-building phase -- the guard is not the first thing this file does"

# ===========================================================================
# 4a -- this file is still part of the suite it claims to certify.
#
# Asked of tests/run.sh's ACTUAL glob, not inferred from anything downstream:
# a rename or a move out of tests/ would leave a file that still passes on its
# own while the guarantee it carries has silently stopped being executed by
# the suite and by CI. That is the one failure this file must never report as
# a pass, so it is checked directly and unconditionally, in both of the modes
# below.
# ===========================================================================
in_suite_glob=0
for test_file in "$REPO_ROOT"/tests/test_*.sh; do
  if [ "$test_file" = "$SELF" ]; then in_suite_glob=1; fi
done
[ "$in_suite_glob" -eq 1 ] \
  || fail "tests/run.sh globs tests/test_*.sh and this file is not among the matches, so the no-vendor-CLI guarantee is no longer executed by the suite or by CI even though this file still passes -- keep it in tests/ under a test_*.sh name"

# ===========================================================================
# 4b -- THE PROOF: the whole suite, on the vendor-CLI-free PATH.
#
# The full suite, not a hand-picked subset. A subset would have to be kept in
# step with which tests happen to touch a vendor CLI today, and the failure
# mode of forgetting is silence -- which is the failure mode this whole file
# exists to remove.
#
# WHEN THE NESTED RUN IS LAUNCHED, AND WHY NOT ALWAYS. mirrored_count is 0
# exactly when this machine has no vendor CLI installed anywhere on PATH --
# which is the state of every hosted runner. HERMETIC_PATH is then the ambient
# PATH byte for byte, so a suite launched from here would be an identical copy
# of the one already in progress around this file: it answers nothing the
# outer run is not already answering, and it doubles the wall clock of every
# CI job on a repository whose CI problem is the entire reason this file
# exists. So the nested run is launched in the two cases where it is not a
# duplicate:
#
#   * a vendor CLI IS installed (mirrored_count > 0) -- HERMETIC_PATH really
#     differs from the ambient one, and this is the developer machine the
#     divergence was hiding on in the first place; or
#   * there is no surrounding suite run to lean on (ORCHID_SUITE_RUN unset,
#     i.e. this file was invoked on its own rather than through tests/run.sh).
#
# Skipping is never silent: the branch below records what carried the
# guarantee instead, in the same not-tested vocabulary as everything else here.
# ===========================================================================
not_tested "vendor-cli-behaviour" \
  "what the real codex/claude/agy CLIs DO. This proof removes them; it does not exercise them. Whether a vendor CLI is installed, authenticated and answers correctly stays an operator-owned, out-of-band qualification (\`orchid plugins test --all-defaults\` on a machine that has them), deliberately outside the deterministic suite"

if [ "$mirrored_count" -eq 0 ] && [ -n "${ORCHID_SUITE_RUN:-}" ]; then
  not_tested "nested-vendor-cli-free-run" \
    "a SECOND suite run launched from here. It would have been byte-for-byte identical to the one now executing this file: none of ${VENDOR_CLIS[*]} is installed on this machine, so the vendor-CLI-free PATH built above IS the ambient PATH, and the surrounding tests/run.sh (ORCHID_SUITE_RUN=1) is already the vendor-CLI-free run -- if the suite depends on a vendor CLI, THAT run goes red, without this file paying for a duplicate of it. The nested run still happens wherever it can differ: on a machine that has a vendor CLI installed, and whenever this file is invoked on its own outside tests/run.sh"
  exit 0
fi

reentry_log="$WORK/reentry.log"
: > "$reentry_log"
suite_log="$WORK/hermetic-suite.log"
echo "  running the FULL suite with ${VENDOR_CLIS[*]} unresolvable (a second, nested tests/run.sh; its output is captured, not streamed)"
suite_rc=0
PATH="$HERMETIC_PATH" \
ORCHID_HERMETIC_PROOF=1 \
ORCHID_HERMETIC_PROOF_LOG="$reentry_log" \
ORCHID_TEST_BASH="$BASH" \
  "$BASH" "$RUNNER" > "$suite_log" 2>&1 || suite_rc=$?

if [ "$suite_rc" -ne 0 ]; then
  fail "the deterministic suite does not pass with ${VENDOR_CLIS[*]} unresolvable -- it depends on a vendor CLI being installed on the machine running it, which is what kept hosted CI red"
  echo "  ---- failures from the vendor-CLI-free run ($suite_log) ----"
  awk '
    /^== / { current = $0 }
    /^[[:space:]]*(FAIL|FATAL):/ { if (shown < 60) { print "  " current; print "  " $0; shown++ } }
  ' "$suite_log"
  echo "  ---- end ----"
fi

# The nested run must really have been a full run, not an empty or truncated
# one that exited 0 by accident. The expected count is DERIVED from the same
# glob tests/run.sh uses, so this stays true as test files come and go. The
# pattern matches run.sh's own `== <path>` banner shape specifically -- a bare
# `^== ` would also count any line a test file happened to print.
expected_files=0
for test_file in "$REPO_ROOT"/tests/test_*.sh "$REPO_ROOT"/tests/inv/test_*.sh; do
  [ -e "$test_file" ] || continue
  expected_files=$((expected_files + 1))
done
assert_eq "$expected_files" \
  "$(grep -Ec '^== .*/tests/(inv/)?test_[A-Za-z0-9_.-]+\.sh$' "$suite_log")" \
  "the nested run must execute every test file tests/run.sh globs"

# ===========================================================================
# 5 -- and the guard held, for real rather than in the synthetic probe above.
#
# EXACTLY ONE re-entry. Not zero: the nested run globs this file the same way
# the outer one does, so a zero here means the marker never reached the child
# and the guard is being satisfied by something else -- the loop is one
# refactor away even though everything still passes. Not two or more: that
# means the guard stopped stopping, and the loop is already back. (Whether
# this file is still IN that glob at all is a separate question, asked
# directly of the glob in 4a above, because it has to hold in the skipped
# branch too.)
# ===========================================================================
reentries="$(grep -c . "$reentry_log")"
assert_eq 1 "$reentries" \
  "the recursion guard must let the nested run re-enter this file exactly once (got $reentries -- 0 means ORCHID_HERMETIC_PROOF never reached the child and nothing was actually guarded; 2 or more means the guard no longer prevents the loop)"
grep -qxF 1 "$reentry_log" \
  || fail "the nested run's re-entry did not carry this run's depth marker -- ORCHID_HERMETIC_PROOF is not reaching the child environment, so the guard is being satisfied by something else"

exit 0
