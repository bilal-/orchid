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
# Where no vendor CLI resolves at all, the suite run already in progress around
# this file IS that run, so there is nothing to launch and section 4c skips it
# rather than doubling every CI job to re-answer the same question. Whether one
# resolves is measured against the ambient PATH (section 2), never inferred
# from how much mirroring the PATH needed -- an empty PATH element means the
# current directory and cannot be mirrored at all, so the two answers come
# apart exactly where a skip would be unsafe. The skip is recorded, never
# silent.
#
# WHY A MIRROR AND NOT A PRUNED PATH. Removing whole directories from PATH is
# not an option: on macOS `codex` and `jq` routinely live in the same Homebrew
# bin. So each PATH entry that actually contains a vendor CLI is replaced by a
# scratch directory of symlinks to everything in it EXCEPT those names. Entries
# with no vendor CLI in them are passed through untouched -- which, on a hosted
# runner, is all of them, so the PATH the runner sees is the PATH this proof
# runs on, byte for byte.
#
# PATH IS NOT THE ONLY AMBIENT INPUT. A restricted PATH says nothing about the
# machine-local state the suite reads through HOME -- user config, the
# unattended-trust store, the capsuite freshness markers, the plugin trust
# records. That state belongs to the OPERATOR, it is shared by every Orchid
# process on the machine, and another Orchid can be writing it while this run
# reads it: this proof was itself blocked once by a verification that failed
# only because a drive loop was polling the same repository at the time, with
# ~12 notify-channel assertions going red that had nothing to do with the diff
# (lesson L024). A proof that removes vendor binaries and then runs the suite
# against whatever the operator's home happens to hold at that instant is not
# hermetic; it has just moved the machine dependency somewhere PATH cannot see.
# So section 4b gives the nested run its own disposable HOME and DEMONSTRATES
# the isolation -- reads, writes, and durable run identity, each against a
# decoy home that stands in for the operator's, each with a control that proves
# the check can actually fail -- and section 4c then runs the whole suite with
# a writer concurrently churning that decoy for the entire duration.
#
# RECURSION GUARD. tests/run.sh globs tests/test_*.sh, so the run this file
# launches re-enters this file, which would launch another run, forever. The
# guard is the ORCHID_HERMETIC_PROOF marker checked below, BEFORE anything else
# happens -- before helpers.sh is even sourced. It is an EXACT-VALUE test
# against a token literal in this file, never a truthiness test: a bare `-n`
# check is satisfied by ANY value, so a stray `ORCHID_HERMETIC_PROOF=1` left in
# an operator's shell or exported by an unrelated harness would make this whole
# file exit 0 having proved nothing -- an unproven-ok inside the very harness
# built to prevent unproven-oks, and one that is indistinguishable, in a log,
# from the flake above. It is not enough to write the guard and trust it: a
# refactor that renamed this file out of the glob, or dropped the marker from
# the child environment, would leave a guard that guards nothing and a proof
# that proves nothing. So every half is asserted. The guard is exercised three
# ways -- against a synthetic re-entry carrying the exact token (section 3),
# against a battery of stray and near-miss values that must NOT satisfy it
# (section 3, the RED case), and for real, by counting the marked child run's
# re-entries, which must be exactly one (section 5). Glob membership, the half
# that must hold even when no nested run happens, is asked of tests/run.sh's
# actual glob instead (section 4a).

# ---------------------------------------------------------------------------
# THE GUARD ITSELF. First statement in the file, deliberately: nothing above it
# may cost anything or create anything, because this branch runs once per
# nested suite run.
#
# The token is a literal here rather than a value chosen by the launcher, so
# the parent and the child cannot drift: the same line is read by both. Its
# shape is deliberately not something anything else would set -- guessing it by
# accident is the failure mode that made a bare truthiness test unsafe.
# ---------------------------------------------------------------------------
ORCHID_HERMETIC_PROOF_TOKEN='orchid/hermetic-suite-proof/nested-run/1'

if [ "${ORCHID_HERMETIC_PROOF:-}" = "$ORCHID_HERMETIC_PROOF_TOKEN" ]; then
  if [ -n "${ORCHID_HERMETIC_PROOF_LOG:-}" ]; then
    printf '%s\n' "$ORCHID_HERMETIC_PROOF" >> "$ORCHID_HERMETIC_PROOF_LOG"
  fi
  echo "  NOT-TESTED: hermetic-suite-nested -- recursion guard (depth marker '$ORCHID_HERMETIC_PROOF'): this file is re-entered by the tests/run.sh glob of the run it launched. Skipping, never re-launching."
  exit 0
fi

# --guard-probe: answer "which side of the guard did this invocation land on?"
# and stop, without building a PATH or launching anything. It exists so the RED
# case in section 3 can prove a stray ORCHID_HERMETIC_PROOF no longer stands
# this file down WITHOUT the probe having to run the entire file (and, on a
# developer machine, a whole nested suite) to find that out.
#
# It sits BELOW the guard on purpose, and section 3 asserts that ordering
# directly: an argument that could pre-empt the guard would be a second way to
# make this file exit 0 without proving anything, which is the exact defect the
# strict token above exists to remove. tests/run.sh, scripts/ci-local.sh and
# this task's verification_commands all invoke this file with no arguments at
# all, so nothing in the suite can reach the probe by accident; anything else
# is refused rather than ignored.
case "${1:-}" in
  "") ;;
  --guard-probe)
    echo "  guard-not-triggered: ORCHID_HERMETIC_PROOF='${ORCHID_HERMETIC_PROOF:-}' is not this file's exact recursion-guard token, so the guard did not fire and the proof would have run in full"
    exit 0
    ;;
  *)
    echo "FATAL: tests/test_hermetic_suite.sh: unknown argument '$1' (this file takes no arguments; --guard-probe is reserved for its own RED case)" >&2
    exit 1
    ;;
esac

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
# installed into. The rest are here because the mirror is the ONLY thing that
# can lose them, and losing one is not a clean failure: it is dozens of test
# files failing for reasons that read nothing like "the mirror dropped a
# tool". ln/readlink/chmod/mktemp/mv/rm/tr/sort are what the fixtures and
# lib/common.sh's atomic_write and plugin_digest actually shell out to;
# cat/mkdir/cp/cut/wc/date/sleep are the bedrock the fixtures themselves are
# written in, including this file's own isolation probes below.
REQUIRED_TOOLS=(jq git bash env awk sed grep find tr sort ln readlink chmod
                mktemp mv rm cat mkdir cp cut wc date sleep)

# plugin_digest (lib/common.sh) hashes with `shasum -a 256` and falls back to
# `openssl dgst -sha256` when shasum is absent, so EITHER satisfies the suite
# and neither alone is required. It is called out separately from the list
# above because it is the highest-consequence tool the mirror could drop and
# the one whose loss is least legible: capsuite's whole freshness marker and
# the digest-pinned trust store (INV-09) are built on it, so a mirror that
# lost it would fail a large fraction of the suite with digest mismatches
# rather than with anything naming PATH.
DIGEST_TOOLS=(shasum openssl)

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
    "the PATH-mirroring code path. No PATH entry on this machine holds any of ${VENDOR_CLIS[*]}, so nothing needed removing and the PATH below is the ambient PATH minus only entries that are not directories. A hosted runner is in exactly this state. The no-vendor-CLI guarantee itself still holds here and is still asserted below; only the mirror -- the part that has work to do on a machine that DOES have a vendor CLI installed -- goes unexercised"
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
digest_tool_found=0
for digest_tool in "${DIGEST_TOOLS[@]}"; do
  if resolves_under_hermetic_path "$digest_tool"; then digest_tool_found=1; fi
done
[ "$digest_tool_found" -eq 1 ] \
  || fail "the vendor-CLI-free PATH resolves neither ${DIGEST_TOOLS[*]}, so lib/common.sh's plugin_digest has no SHA-256 tool -- every capsuite freshness marker and every digest-pinned trust record in the nested run would fail for a reason that names neither PATH nor this file"

# The AMBIENT PATH -- the one the run AROUND this file is using -- gets the
# same question asked of it directly, because section 4c's skip leans on the
# answer: it stands down only when the surrounding run is ALREADY a
# vendor-CLI-free run, and that is a fact about the ambient PATH, not about
# the mirror built from it. mirrored_count is not that fact. It is close, and
# it was what the skip used to be gated on, but it is INFERRED, and it is
# inferred from a loop that discards exactly the PATH entries the mirror
# cannot represent: an EMPTY PATH element means the CURRENT DIRECTORY and is
# dropped above, so a `codex` in the cwd of a suite run whose PATH ends in `:`
# resolves for the surrounding run while HERMETIC_PATH proves it does not --
# and the skip would then hand the guarantee to a run that does not carry it.
# It is also wrong in the harmless direction: a vendor CLI present but not
# executable makes mirrored_count non-zero while nothing can actually resolve
# it. Measure the thing the skip depends on instead of a proxy for it.
AMBIENT_IS_HERMETIC=1
for vendor_cli in "${VENDOR_CLIS[@]}"; do
  if "$BASH" -c 'command -v "$1" >/dev/null 2>&1' _ "$vendor_cli"; then
    AMBIENT_IS_HERMETIC=0
  fi
done

# ===========================================================================
# 3 -- the recursion guard, exercised directly before it is relied on.
#
# GREEN first: the exact token stands the file down, cleanly, early, and in
# the not-tested vocabulary. Then the RED case the guard's strictness exists
# for: a battery of stray and near-miss values, none of which may satisfy it.
# ===========================================================================
guard_probe_log="$WORK/guard-probe.log"
: > "$guard_probe_log"
guard_rc=0
guard_out="$(ORCHID_HERMETIC_PROOF="$ORCHID_HERMETIC_PROOF_TOKEN" \
  ORCHID_HERMETIC_PROOF_LOG="$guard_probe_log" \
  "$BASH" "$SELF" 2>&1)" || guard_rc=$?
assert_eq 0 "$guard_rc" "a guarded re-entry must exit cleanly rather than failing the suite"
assert_match 'recursion guard' "$guard_out" "a guarded re-entry says why it stopped"
assert_match 'NOT-TESTED' "$guard_out" \
  "a guarded re-entry is recorded in the not-tested vocabulary, never as a silent pass"
assert_eq 1 "$(grep -c . "$guard_probe_log")" \
  "a guarded re-entry must record exactly one entry in the re-entry log"
grep -q 'vendor-CLI-free PATH' <<<"$guard_out" \
  && fail "a guarded re-entry reached the PATH-building phase -- the guard is not the first thing this file does"

# The guard is checked BEFORE the argument dispatch, so the token still wins
# over --guard-probe. If it ever stopped winning, the probe flag would become a
# second way to exit 0 without proving anything -- the same defect, relocated.
gp_rc=0
gp_out="$(ORCHID_HERMETIC_PROOF="$ORCHID_HERMETIC_PROOF_TOKEN" \
  ORCHID_HERMETIC_PROOF_LOG="$guard_probe_log" \
  "$BASH" "$SELF" --guard-probe 2>&1)" || gp_rc=$?
assert_eq 0 "$gp_rc" "the guard must still exit cleanly when --guard-probe is also passed"
assert_match 'recursion guard' "$gp_out" \
  "the recursion guard is checked ahead of the argument dispatch, so --guard-probe cannot pre-empt it"
assert_eq 2 "$(grep -c . "$guard_probe_log")" \
  "the token-carrying probe above must also have been recorded as a guarded re-entry"

# THE RED CASE. Until this was made strict the guard was `[ -n "$ORCHID_
# HERMETIC_PROOF" ]`, so ANY value in the environment -- a stray `1` from an
# operator's shell, an unrelated harness exporting the same name -- made this
# entire file print one NOT-TESTED line and exit 0. Nothing failed. Nothing
# ran. A log of that run is indistinguishable from a log of a real one that
# happened to be flaky, which is precisely how a spurious verification failure
# cost this task an attempt before anyone could tell the two apart. Every value
# below must now fall through the guard; the near-misses are there because a
# prefix/suffix comparison would be the obvious wrong way to make the check
# "strict" and would still be forgeable.
stray_log="$WORK/stray-guard.log"
: > "$stray_log"
for stray in \
  '' 1 0 true false yes on probe nested hermetic \
  "${ORCHID_HERMETIC_PROOF_TOKEN}x" \
  "x${ORCHID_HERMETIC_PROOF_TOKEN}" \
  "${ORCHID_HERMETIC_PROOF_TOKEN} " \
  "${ORCHID_HERMETIC_PROOF_TOKEN%/1}"
do
  stray_rc=0
  stray_out="$(ORCHID_HERMETIC_PROOF="$stray" ORCHID_HERMETIC_PROOF_LOG="$stray_log" \
    "$BASH" "$SELF" --guard-probe 2>&1)" || stray_rc=$?
  assert_eq 0 "$stray_rc" \
    "the --guard-probe reporter must exit cleanly for ORCHID_HERMETIC_PROOF='$stray'"
  assert_match 'guard-not-triggered' "$stray_out" \
    "a stray ORCHID_HERMETIC_PROOF='$stray' must NOT satisfy the recursion guard -- a truthy-only guard makes this whole proof exit 0 having proved nothing"
  grep -q 'recursion guard' <<<"$stray_out" \
    && fail "ORCHID_HERMETIC_PROOF='$stray' stood the proof down: the guard is matching something other than its exact token"
done
assert_eq 0 "$(grep -c . "$stray_log")" \
  "no stray ORCHID_HERMETIC_PROOF value may reach the guard's re-entry log -- a value that logs a re-entry is a value the guard accepted"

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

# ...and tests/run.sh still publishes the marker section 4c's skip is keyed
# on. If it stops, the skip stops firing and every CI job pays for a nested
# run it does not need -- a cost regression, not a silent one, but one that
# would otherwise be discovered as a doubled CI bill rather than as a failure.
# Checked here, unconditionally, alongside the other question about whether
# the surrounding harness still holds up its end.
grep -q 'ORCHID_SUITE_RUN=' "$RUNNER" \
  || fail "tests/run.sh no longer sets ORCHID_SUITE_RUN, so this file can no longer tell a whole-suite run from a lone invocation and will launch a nested duplicate run on every CI job"

# ===========================================================================
# 4b -- AMBIENT ISOLATION: the nested run gets a HOME of its own, and that is
# demonstrated rather than asserted.
#
# Everything above is about PATH. PATH is not where the machine dependency
# that actually bit this proof lived. The suite reads MACHINE-LOCAL state
# through HOME -- lib/common.sh's user config ($HOME/.orchid/config), the
# unattended-trust store (lib/trust.sh), capsuite's freshness markers
# (lib/capsuite.sh), the home-rooted plugin search paths in lib/resolver.sh,
# lib/roles.sh and lib/archetype.sh -- and that state is SHARED with every
# other Orchid on the machine, including a drive loop polling this very
# repository every twenty seconds while the suite runs.
#
# So the nested run below is launched with a HOME that did not exist a moment
# ago, that nothing else on the machine knows the path of, and that contains no
# Orchid state at all: exactly a hosted runner's home, which is the state this
# whole file exists to reproduce. The XDG_* names go with it, because git reads
# its own configuration through them and they can point back inside the
# operator's home even after HOME itself is redirected. The durable run
# identity (ORCHID_ACTOR/ORCHID_REPO/ORCHID_EPOCH) is unset for the same
# reason tests/run.sh unsets it: inherited, it binds a disposable fixture to
# the outer run.
#
# Each claim below is paired with a control that makes it falsifiable. An
# "the operator's home was untouched" assertion is worth nothing if the thing
# doing the looking cannot see a write in the first place, and a "the poisoned
# config was not read" assertion is worth nothing if the poison was never
# legible. The stand-in for the operator's home is a decoy scratch home,
# seeded with the machine-local state a real one holds; the controls prove the
# decoy is a live sink and a live source, and the probes then prove the nested
# environment reaches neither.
# ===========================================================================
[ -n "${HOME:-}" ] \
  || { fail "HOME is unset, so there is no ambient home to isolate the nested run FROM and nothing below can mean anything"; exit 1; }
AMBIENT_HOME="$HOME"

make_scratch NESTED_HOME
make_scratch DECOY_HOME
DECOY_CANARY='decoy-home-canary-that-the-nested-run-must-never-read'

# The decoy, seeded to look like an operator's machine-local Orchid state. The
# config values are deliberately poisonous: an `engine` naming an adapter that
# does not exist, and a `verify` override of the kind that turned a real
# incident (helpers.sh's cd_scratch header) into a suite that passed without
# running anything. If any of it were read by the nested run, the run would
# either misbehave or -- far worse -- pass for the wrong reason.
mkdir -p "$DECOY_HOME/.orchid/unattended-trust" \
         "$DECOY_HOME/.orchid/capsuite" \
         "$DECOY_HOME/.orchid/plugins/engines"
{
  echo "engine=decoy-engine-that-does-not-exist"
  echo "verify=true"
  echo "canary=$DECOY_CANARY"
} > "$DECOY_HOME/.orchid/config"
printf '%s\n' "$DECOY_CANARY" > "$DECOY_HOME/.orchid/unattended-trust/records.json"
printf '%s\n' "$DECOY_CANARY" > "$DECOY_HOME/.orchid/capsuite/marker"

# home_state <dir> -- structure AND content of a disposable home, as text.
# Content, not just names: a write that rewrites an existing file in place is
# exactly the shape a trust-store update takes, and a names-only fingerprint
# would call that "untouched". Never pointed at the operator's real home --
# only at scratch directories this run created.
home_state() {
  ( cd "$1" || exit 1
    find . -print | sort | while IFS= read -r entry; do
      if [ -f "$entry" ]; then
        printf 'F %s\n' "$entry"
        cat "$entry"
        printf '\n<eof>\n'
      else
        printf 'D %s\n' "$entry"
      fi
    done )
}

# nested_env_run <command...> -- run a command in EXACTLY the environment the
# nested suite run below gets. The probes in this section and the real run in
# 4c go through this one function, which is what makes the probes evidence
# about the run rather than evidence about a hand-rolled copy of it: a change
# that weakened the isolation would have to weaken it here, where every probe
# below would see it.
reentry_log="$WORK/reentry.log"
: > "$reentry_log"
nested_env_run() {
  env -u ORCHID_ACTOR -u ORCHID_REPO -u ORCHID_EPOCH \
    PATH="$HERMETIC_PATH" \
    HOME="$NESTED_HOME" \
    XDG_CONFIG_HOME="$NESTED_HOME/.config" \
    XDG_DATA_HOME="$NESTED_HOME/.local/share" \
    XDG_STATE_HOME="$NESTED_HOME/.local/state" \
    XDG_CACHE_HOME="$NESTED_HOME/.cache" \
    ORCHID_HERMETIC_PROOF="$ORCHID_HERMETIC_PROOF_TOKEN" \
    ORCHID_HERMETIC_PROOF_LOG="$reentry_log" \
    ORCHID_TEST_BASH="$BASH" \
    "$@"
}

# -- CONTROL: the decoy is a live sink, and home_state can see a write to it.
decoy_seeded="$(home_state "$DECOY_HOME")"
[ -n "$decoy_seeded" ] \
  || fail "the decoy home fingerprinted as nothing at all -- every comparison below would be trivially equal"
HOME="$DECOY_HOME" "$BASH" -c 'mkdir -p "$HOME/.orchid" && printf ambient-write > "$HOME/.orchid/write-probe"' \
  || fail "could not write into the decoy home through HOME -- the control below cannot run"
[ "$decoy_seeded" != "$(home_state "$DECOY_HOME")" ] \
  || fail "home_state cannot see a write made through HOME, so every 'the inherited home was untouched' claim in this section would be vacuous"
rm -f "$DECOY_HOME/.orchid/write-probe"
[ "$decoy_seeded" = "$(home_state "$DECOY_HOME")" ] \
  || fail "removing the control's probe file did not restore the decoy fingerprint -- the fingerprint is not stable and cannot be compared across the nested run"

# -- CONTROL: the decoy is a live SOURCE. The poison is legible through HOME,
# so "the nested run did not read it" is a statement about the isolation and
# not about the poison being invisible in the first place.
READ_PROBE='if [ -e "$HOME/.orchid" ]; then find "$HOME/.orchid" -type f -exec cat {} + ; fi; printf "END\n"'
control_read="$(HOME="$DECOY_HOME" "$BASH" -c "$READ_PROBE")"
assert_match "$DECOY_CANARY" "$control_read" \
  "the decoy's machine-local Orchid state must be readable through HOME, or the read probe below proves nothing"

# -- WRITES: a child launched exactly the way the nested run is launched
# writes into the disposable home, and leaves the home it would otherwise
# have inherited byte-identical. HOME is pointed at the decoy for the length
# of these two probes so that the home the child WOULD have inherited is the
# one being checked, rather than a directory nothing was ever going to reach.
HOME="$DECOY_HOME"
nested_env_run "$BASH" -c 'mkdir -p "$HOME/.orchid" && printf nested-write > "$HOME/.orchid/write-probe"' \
  || fail "a child launched with the nested run's environment could not write into its own HOME"
nested_read="$(nested_env_run "$BASH" -c "$READ_PROBE")"
HOME="$AMBIENT_HOME"

[ -f "$NESTED_HOME/.orchid/write-probe" ] \
  || fail "a child launched with the nested run's environment did not write into the disposable HOME -- HOME is not reaching the child, so the nested suite would write wherever this shell's HOME points"
[ "$decoy_seeded" = "$(home_state "$DECOY_HOME")" ] \
  || fail "a child launched with the nested run's environment wrote into the home it INHERITED rather than the one it was given -- the nested suite would be writing the operator's machine-local Orchid state"

# -- READS: the same child, with the same poisoned home inherited, reads
# nothing from it. It sees its own (empty of Orchid state) home instead.
grep -qF "$DECOY_CANARY" <<<"$nested_read" \
  && fail "a child launched with the nested run's environment READ the inherited home's machine-local Orchid state -- the nested suite would resolve user config, trust records and capsuite markers from the operator's home, which is both a machine dependency and a race with every other Orchid on the box"
assert_match 'END' "$nested_read" "the read probe must have run to completion"

# -- IDENTITY: durable run identity never crosses into the nested run. Set
# here deliberately, so the assertion is a RED case and not a restatement of
# whatever this shell happened to be started with.
#
# `export` inside the command substitution's own subshell, never an assignment
# prefixed to the function call: a prefix assignment ahead of a SHELL FUNCTION
# persists in the caller rather than living for the one command, and it is not
# reliably placed in the environment the function's own `env` then sees -- so
# the probe could report "unset" for a variable that was never set in the first
# place, and pass without testing anything.
ident_out="$(
  export ORCHID_REPO=leaked-repo ORCHID_EPOCH=99 ORCHID_ACTOR=leaked-actor
  nested_env_run "$BASH" -c 'printf "%s|%s|%s\n" "${ORCHID_REPO-unset}" "${ORCHID_EPOCH-unset}" "${ORCHID_ACTOR-unset}"'
)"
assert_eq "unset|unset|unset" "$ident_out" \
  "the nested run must not inherit ORCHID_REPO/ORCHID_EPOCH/ORCHID_ACTOR -- an inherited identity binds every disposable fixture in it to the OUTER run, which is a live Orchid writing the same machine at the same time"

# -- and the nested run starts from a home with no Orchid state in it at all,
# which is the state a hosted runner is in and the state the whole file is
# trying to reproduce. The write probe above is cleared first so what the
# nested suite inherits is the empty directory, not this section's leavings.
rm -rf "$NESTED_HOME/.orchid"
[ ! -e "$NESTED_HOME/.orchid" ] \
  || fail "the nested run's HOME still holds Orchid state before the run starts -- it is no longer the fresh, runner-shaped home this section claims to hand over"
[ "$NESTED_HOME" != "$AMBIENT_HOME" ] \
  || fail "the nested run's HOME is the ambient HOME -- there is no isolation here at all"
[ "$(grep -c . "$reentry_log")" = 0 ] \
  || fail "an isolation probe appended to the recursion-guard re-entry log; section 5's count would be measuring this section instead of the nested run"

# HOME is the only channel a shipped file may reach machine-local Orchid state
# through, and that is what makes overriding it sufficient. A hard-coded
# operator home would bypass the override entirely and no environment this file
# builds could see it, so it is checked statically rather than left implicit.
# Scoped to `/.orchid` so bin/orchid's fixed bootstrap PATH entry for
# /home/linuxbrew/.linuxbrew/bin is not mistaken for one.
home_literal_hits="$(grep -REn '(/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+)/\.orchid' \
  "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/libexec" "$REPO_ROOT/runners" \
  "$REPO_ROOT/scripts" "$REPO_ROOT/tests" 2>/dev/null || true)"
[ -z "$home_literal_hits" ] \
  || fail "a shipped file reaches an operator home's .orchid by absolute path, so redirecting HOME cannot isolate the nested run from it: $home_literal_hits"

# ===========================================================================
# 4c -- THE PROOF: the whole suite, on the vendor-CLI-free PATH, in the
# isolated home, with a concurrent writer churning the machine-local state an
# ambient Orchid shares.
#
# The full suite, not a hand-picked subset. A subset would have to be kept in
# step with which tests happen to touch a vendor CLI today, and the failure
# mode of forgetting is silence -- which is the failure mode this whole file
# exists to remove.
#
# WHEN THE NESTED RUN IS LAUNCHED, AND WHY NOT ALWAYS. AMBIENT_IS_HERMETIC is
# 1 exactly when none of the vendor CLIs resolves on the PATH this file was
# invoked with -- which is the state of every hosted runner. The run already
# in progress around this file is then ITSELF a vendor-CLI-free run of the
# whole suite: if any test depends on an installed vendor CLI, THAT run goes
# red. A suite launched from here would answer nothing it is not already
# answering, and it would double the wall clock of every CI job on a
# repository whose CI problem is the entire reason this file exists. So the
# nested run is launched in the two cases where it is not a duplicate:
#
#   * a vendor CLI really does resolve here (AMBIENT_IS_HERMETIC = 0) -- the
#     surrounding run is NOT the run this file is supposed to certify, and
#     this is the developer machine the divergence was hiding on in the first
#     place; or
#   * there is no surrounding suite run to lean on -- ORCHID_SUITE_RUN does
#     not name THIS repository's tests/run.sh, i.e. this file was invoked on
#     its own rather than through the runner.
#
# Note which of the two questions each half answers. "Is this run
# vendor-CLI-free" is measured, not inferred (section 2). "Is there a
# surrounding whole-suite run" is what ORCHID_SUITE_RUN carries -- and it is
# CHECKED, not merely tested for non-emptiness. tests/run.sh sets it to its
# own physical path and this file compares that against the runner it resolved
# for itself. A bare truthy value would have been forgeable by accident: an
# `ORCHID_SUITE_RUN=1` left in an operator's shell, or exported by some
# unrelated harness, would stand this proof down on a vendor-CLI-free machine
# with NOTHING having run in its place -- the one direction in which a skip is
# not merely wasteful but silent. Losing the marker still only costs a
# duplicate run. That asymmetry is the whole reason the marker is a path, and
# it is the same asymmetry that made ORCHID_HERMETIC_PROOF an exact token.
#
# Skipping is never silent: the branch below records what carried the
# guarantee instead, in the same not-tested vocabulary as everything else here.
# ===========================================================================
not_tested "vendor-cli-behaviour" \
  "what the real codex/claude/agy CLIs DO. This proof removes them; it does not exercise them. Whether a vendor CLI is installed, authenticated and answers correctly stays an operator-owned, out-of-band qualification (\`orchid plugins test --all-defaults\` on a machine that has them), deliberately outside the deterministic suite"

# The honest boundary of a PATH-based proof, named rather than left implicit.
# bin/orchid does not INHERIT PATH for its own bootstrap: it replaces it with a
# fixed machine-local list (/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/
# .linuxbrew/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin) and carries the
# caller's as inert data, which lib/common.sh restores at each verb's first
# source -- so everything that resolves a required binary today, capsuite's
# binaries_present included, runs on the PATH this file restricted. A
# trust-boundary verb DEFERS that restore, and on a developer machine those
# fixed directories are exactly where an installed codex/claude/agy lives. No
# binary lookup sits on the deferred side today. One added there would be
# machine-dependent again and this proof would not see it, because the list is
# a literal in bin/orchid rather than anything reachable from PATH.
not_tested "bootstrap-path-vendor-clis" \
  "whether a vendor CLI is reachable through bin/orchid's FIXED bootstrap PATH. This proof restricts PATH, and that list is not built from PATH, so it is outside what any PATH restriction can reach. It is empty of consequence only for as long as no binary lookup runs ahead of lib/common.sh's _orchid_entry_restore_operator_path; a lookup placed there would find a developer's installed CLI and not a runner's, which is the divergence class this file exists to close"

# The honest boundary of the isolation, for the same reason. Section 4b closes
# the channel a concurrent Orchid actually reached this suite through -- shared
# machine-local state under HOME -- and 4c below demonstrates the closure while
# a writer churns it. What no test file can defend against is a second Orchid
# mutating THIS CHECKOUT while the suite reads it: a driver that rebases the
# worktree, re-pins Formula/orchid.rb, or rewrites .orchid/ mid-run changes the
# code under test underneath a run already in progress. Reproducing that here
# would mean writing the working tree and .orchid/ of the repository being
# verified, which this file must never do. It is an operator-owned scheduling
# constraint, not a testable one, and it is named here so it is not mistaken
# for something the sections below cover.
not_tested "concurrent-orchid-mutating-this-checkout" \
  "a second Orchid mutating this checkout's working tree or .orchid/ state DURING the run. Section 4b closes the shared-HOME channel and 4c exercises it under a concurrent writer, but a driver that rebases, re-pins or rewrites the repository mid-run changes the code under test itself, and a test cannot both provoke that and stay safe to run. Operator-owned: do not verify this repository while a drive loop is dispatching against the same worktree (lesson L024)"

if [ "$AMBIENT_IS_HERMETIC" -eq 1 ] && [ "${ORCHID_SUITE_RUN:-}" = "$RUNNER" ]; then
  not_tested "nested-vendor-cli-free-run" \
    "a SECOND suite run launched from here. It would have answered exactly what the run now executing this file is already answering: none of ${VENDOR_CLIS[*]} resolves on this run's PATH (measured in section 2, not assumed), and ORCHID_SUITE_RUN names this repository's own $RUNNER, so the run around this file IS the vendor-CLI-free whole-suite run -- if the suite depends on a vendor CLI, THAT run goes red, without this file paying for a duplicate of it. The nested run still happens wherever it can differ: on a machine where a vendor CLI does resolve, and whenever this file is invoked outside that runner"
  not_tested "concurrent-ambient-home-writer" \
    "the concurrent-writer half of section 4c, which only runs alongside a nested run. The isolation it exercises is asserted in full above, on this machine, in section 4b -- the writer adds the demonstration that the isolation holds while the shared state is being rewritten throughout, and there is no nested run here to hold it across"
  exit 0
fi

# -- the concurrent writer. It stands in for the other Orchid: a process that
# rewrites the machine-local state under a home for the whole duration of the
# run, at a far higher rate than the twenty-second drive-loop poll that
# produced the flake this section exists for. It writes ONLY into the decoy
# scratch home and only ever READS this repository, because a stand-in that
# wrote the checkout under test would be the hazard rather than a test of it.
#
# A separate bash PROCESS, not a `&`-backgrounded shell function: a background
# subshell of this file would inherit its scratch-cleanup accounting, and the
# one thing a concurrency probe must never do is delete the run it is probing.
CHURN_MARK='concurrent-ambient-orchid-tick'
churn_script="$WORK/concurrent-home-writer.sh"
churn_stop="$WORK/concurrent-home-writer.stop"
churn_count="$WORK/concurrent-home-writer.count"
rm -f "$churn_stop"
printf '0\n' > "$churn_count"
cat > "$churn_script" <<'CHURN_SCRIPT'
#!/usr/bin/env bash
# <decoy-home> <repo-root> <stop-file> <count-file> <marker>
decoy="$1"; repo="$2"; stop="$3"; count="$4"; mark="$5"
ticks=0
while [ ! -f "$stop" ]; do
  ticks=$((ticks + 1))
  mkdir -p "$decoy/.orchid/unattended-trust" 2>/dev/null
  printf '%s %s\n' "$mark" "$ticks" > "$decoy/.orchid/unattended-trust/records.json" 2>/dev/null
  printf '%s %s\n' "$mark" "$ticks" > "$decoy/.orchid/capsuite/marker" 2>/dev/null
  git -C "$repo" rev-parse HEAD >/dev/null 2>&1
  printf '%s\n' "$ticks" > "$count" 2>/dev/null
  sleep 1
done
CHURN_SCRIPT
decoy_before_run="$(home_state "$DECOY_HOME")"
"$BASH" "$churn_script" "$DECOY_HOME" "$REPO_ROOT" "$churn_stop" "$churn_count" "$CHURN_MARK" &
churn_pid=$!

suite_log="$WORK/hermetic-suite.log"
echo "  running the FULL suite with ${VENDOR_CLIS[*]} unresolvable, in a disposable HOME, while a concurrent writer rewrites the ambient home's Orchid state (a second, nested tests/run.sh; its output is captured, not streamed)"
suite_rc=0
nested_env_run "$BASH" "$RUNNER" > "$suite_log" 2>&1 || suite_rc=$?

: > "$churn_stop"
wait "$churn_pid" 2>/dev/null || true

if [ "$suite_rc" -ne 0 ]; then
  fail "the deterministic suite does not pass with ${VENDOR_CLIS[*]} unresolvable, in an isolated HOME, alongside a concurrent writer of the ambient home -- it depends on something about the machine running it, which is what kept hosted CI red"
  echo "  ---- failures from the vendor-CLI-free run ($suite_log) ----"
  awk '
    /^== / { current = $0 }
    /^[[:space:]]*(FAIL|FATAL):/ { if (shown < 60) { print "  " current; print "  " $0; shown++ } }
  ' "$suite_log"
  echo "  ---- end ----"
fi

# The concurrency claim is only worth something if the writer was really
# running the whole time. Both halves are checked: it counted ticks, and the
# home it was rewriting genuinely changed across the run. A writer that died
# at once, or one whose writes went nowhere, would leave a green line above
# saying the suite survives concurrency when nothing concurrent happened.
churn_ticks="$(cat "$churn_count" 2>/dev/null || echo 0)"
case "$churn_ticks" in
  ''|*[!0-9]*) churn_ticks=0 ;;
esac
[ "$churn_ticks" -ge 3 ] \
  || fail "the concurrent writer recorded only $churn_ticks tick(s) across the whole nested run, so the suite above was not actually run against a moving ambient home and the concurrency guarantee is unproven"
[ "$decoy_before_run" != "$(home_state "$DECOY_HOME")" ] \
  || fail "the concurrent writer's $churn_ticks tick(s) left the ambient home byte-identical -- it was not writing the state it claims to have been churning"
echo "  concurrent ambient-home writer: $churn_ticks tick(s) across the nested run"

# ...and none of that churn reached the nested run's own home. If it had, the
# isolation would be one-directional: the run protected from writing the
# operator's home, but not from reading a home someone else is rewriting.
if grep -rlF "$CHURN_MARK" "$NESTED_HOME" >/dev/null 2>&1; then
  fail "the concurrent writer's state turned up inside the nested run's own HOME -- the two homes are not actually separate"
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
grep -qxF "$ORCHID_HERMETIC_PROOF_TOKEN" "$reentry_log" \
  || fail "the nested run's re-entry did not carry this run's exact depth marker -- ORCHID_HERMETIC_PROOF is not reaching the child environment with the token this file guards on, so the guard is being satisfied by something else"

exit 0
