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
# guards nothing and a proof that proves nothing. So the guard is exercised
# twice. Once directly, against a synthetic re-entry. Once for real: the marked
# child run appends one line per re-entry to a log this file then reads, and
# the count must be exactly one -- 0 means this file left the glob and is no
# longer part of the suite it claims to certify, 2+ means the guard stopped
# working and the loop is back.

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
    "this machine has none of ${VENDOR_CLIS[*]} installed, so the PATH below is the ambient PATH and the mirroring code path did not run here. The guarantee the nested run then proves is still the real one -- a runner is in exactly this state -- but the mirror itself is exercised only where a vendor CLI is actually installed"
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
# 4 -- THE PROOF: the whole suite, on the vendor-CLI-free PATH.
#
# The full suite, not a hand-picked subset. A subset would have to be kept in
# step with which tests happen to touch a vendor CLI today, and the failure
# mode of forgetting is silence -- which is the failure mode this whole file
# exists to remove.
# ===========================================================================
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
# Exactly one re-entry. Not zero: zero means tests/run.sh no longer globs this
# file, so the no-vendor-CLI guarantee has quietly stopped being part of the
# suite and of CI, even though this file still passes. Not two or more: that
# means the guard stopped stopping, and the infinite loop is back.
# ===========================================================================
reentries="$(grep -c . "$reentry_log")"
if [ "$reentries" -eq 0 ]; then
  fail "the nested run never re-entered this file: tests/run.sh does not glob tests/test_hermetic_suite.sh any more, so the no-vendor-CLI guarantee is no longer executed by the suite or by CI -- put it back in tests/ under a test_*.sh name"
else
  assert_eq 1 "$reentries" \
    "the recursion guard must stop re-entry at the first nested run (got $reentries re-entries -- more than one means the guard no longer prevents the loop)"
fi
grep -qxF 1 "$reentry_log" \
  || fail "the nested run's re-entry did not carry this run's depth marker -- ORCHID_HERMETIC_PROOF is not reaching the child environment, so the guard is being satisfied by something else"

not_tested "vendor-cli-behaviour" \
  "what the real codex/claude/agy CLIs DO. This proof removes them; it does not exercise them. Whether a vendor CLI is installed, authenticated and answers correctly stays an operator-owned, out-of-band qualification (\`orchid plugins test --all-defaults\` on a machine that has them), deliberately outside the deterministic suite"

exit 0
