#!/usr/bin/env bash
set -uo pipefail
# `pwd -P`, never logical `pwd`: the runners resolve their own ORCHID_ROOT
# physically (runners/orchid-service, runners/orchid-pump), so a checkout
# reached through a symlinked path -- a macOS `mktemp -d` merge-validation
# worktree under /var/folders/... -> /private/var/folders/... is the case
# that caught this -- would otherwise give tests a LOGICAL repo root that
# never matches the physical path a runner bakes into a rendered artifact
# (the launchd plist's ProgramArguments). Canonicalize once, here.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORCHID_BIN="$REPO_ROOT/bin/orchid"
FAILS=0

# A self-hosted test run can inherit the OUTER Orchid session's identity.
# Fixtures create and export their own repo/epoch as needed; an inherited
# actor would otherwise misattribute every fixture journal entry (and an
# inherited repo/epoch can bind early setup commands to the outer run).
# Keep dry-run available because adapter tests intentionally exercise that
# public seam, but never inherit durable-run identity into a disposable repo.
unset ORCHID_ACTOR ORCHID_REPO ORCHID_EPOCH

# Fixtures deliberately replace HOME to isolate machine-local Orchid state.
# Disposable fixture commits must not depend on an operator's global Git
# identity, which may be absent in hosted CI and extracted archives.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Orchid Tests}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-orchid-tests@example.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

fail()        { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
assert_eq()   { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
# A HERESTRING, never `echo "$2" | grep -Eq`: this file runs under `set -o
# pipefail` (line 2), and `grep -Eq` exits at its FIRST match, which SIGPIPEs
# the upstream `echo` mid-write (`write error: Broken pipe`, exit 141).
# pipefail then promotes that 141 to the pipeline's status, so the assertion
# reports "no match" for a pattern it DID find. It only fires when `$2` is
# long enough that `echo` is still writing when `grep` exits, which made it a
# silent, size-dependent coin flip across all 892 call sites rather than an
# obvious break. `<<<` feeds grep from a temp file, so there is no pipe, no
# SIGPIPE, and the exit status is the matcher's alone.
assert_match(){ grep -Eq "$1" <<<"$2" || fail "$3 (no match '$1')"; }

# not_tested <id> <why> -- record a claim this suite deliberately does NOT
# examine, in the same closed vocabulary scripts/beta-qualify.sh already uses
# for its own probes (pass|fail|blocked|not-tested). It is NOT a failure: an
# absence of evidence is not a defect. What it must never be is SILENT.
#
# The hazard is the one that kept hosted CI red from its very first run while
# `scripts/ci-local.sh` was green on the author's machine: a check whose real
# subject is a MACHINE FACT (a vendor CLI installed, a network reachable, a
# credential present) passes wherever that fact happens to hold and fails
# everywhere else, while reading, in both places, exactly like a check of this
# repository's code. Skipping such a check quietly is worse than either
# outcome, because a suite that prints nothing about it is indistinguishable
# from one that verified it. So the skip gets a line of its own, naming what
# was not tested and how to qualify it out of band.
NOT_TESTED=0
not_tested() {
  NOT_TESTED=$((NOT_TESTED + 1))
  echo "  NOT-TESTED: $1 -- $2"
}

# --------------------------------------------------------------------------
# THE RED-CASE RULE (T017). A check that GATES anything must ship a case that
# demonstrates it DETECTS the failure it exists for, plus the GREEN twin it
# must ACCEPT, and both must be exercised by the suite IN THE GATE'S OWN FILE
# -- not asserted in a comment, and not delegated to some other test that
# happens to cover the accepting direction.
#
# Across r-001 and r-002 the repeated defect was the same shape: a check that
# reported success without having tested anything. A review envelope with an
# empty `findings[]`. A probe that grepped a reply for the string it had just
# fed into the prompt. A rehearsal snapshot comparing a tree that was never at
# risk. `doctor` reporting outbound ok without reading the config its plugin
# requires. An inbound line whose output was identical whether or not a
# gateway existed. Every one was written in good faith, every one read in a
# log exactly like a check that had passed, and not one of them could fail.
#
# red_case <label> -- record that this file has just fed its OWN check an
# input the check must reject, and watched it fire. green_case <label> is the
# twin: an input the same check must ACCEPT, watched to pass. Both labels are
# printed, so a reader of the log sees WHICH failure was demonstrated and
# against what, rather than inferring that something was.
#
# BOTH are mandatory for an enrolled gate file: the EXIT trap below fails a
# file that records either at zero. A RED case alone proves only that
# something rejects the input -- possibly everything -- so the pair is what
# distinguishes detection from noise (docs/specs/kernel.md, "Proof
# discipline"). And because the trap counts what actually RAN, neither can be
# satisfied by a comment, by prose about the rule, or by a call sitting in a
# branch nothing reaches.
#
# `ORCHID_REQUIRE_RED_CASE` extends the same requirement to a file anywhere
# else; tests/test_red_case_rule.sh passes it to the fixtures it uses to prove
# this enforcement actually fires.
#
# Note the direction of that marker, because it is the opposite of
# tests/test_hermetic_suite.sh's ORCHID_HERMETIC_PROOF and is why this one is
# not an exact token: a stray value here can only ADD a requirement, so the
# worst it can cost is a loud, legible failure. There is no value of it that
# turns a check off.
RED_CASES=0
GREEN_CASES=0
red_case() {
  RED_CASES=$((RED_CASES + 1))
  echo "  RED-CASE: $1"
}
green_case() {
  GREEN_CASES=$((GREEN_CASES + 1))
  echo "  GREEN-CASE: $1"
}

# WHICH FILE IS RUNNING -- resolved, never taken from `$0`.
#
# `$0` is whatever the caller typed, and the very same file arrives under three
# different spellings depending on how it was invoked:
#
#     /abs/path/to/tests/inv/test_INV-12_pack_overflow.sh   (tests/run.sh)
#     tests/inv/test_INV-12_pack_overflow.sh                (from the repo root)
#     test_INV-12_pack_overflow.sh                          (from inside tests/inv)
#
# Only the FIRST of those matches a `*/tests/inv/test_*.sh` pattern. The second
# has no path component before `/tests/inv/` for the leading `*` to bind to;
# the third has no directory at all. So deciding enrolment from `$0` failed
# OPEN for two of the three ways a person actually runs a test file: the
# requirement silently did not apply, the summary line was simply absent, and
# the file passed. A gate that switches itself off depending on how it was
# typed, and says nothing when it does, is precisely the "reported success
# without having tested anything" shape this whole rule exists to remove -- so
# it must not be inferred from the command line at all.
#
# The path below is invocation-independent. The OUTERMOST `BASH_SOURCE` entry
# is the file bash is executing (this file is sourced by it, so it sits at the
# top of that stack), resolved against the cwd it was invoked from and
# canonicalized with `pwd -P` -- the same reason REPO_ROOT above is physical,
# since a scratch checkout under macOS's /var/folders -> /private/var/folders
# must compare equal to the path a caller derived. Captured HERE, at source
# time, rather than inside the trap: by the time the trap runs, the file may
# have `cd`'d somewhere else entirely, and BASH_SOURCE inside a trap describes
# the trap's own call stack rather than the script's.
_PROOF_SELF_RAW="${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]}"
_PROOF_SELF_DIR="$(cd "$(dirname "$_PROOF_SELF_RAW")" 2>/dev/null && pwd -P)"
if [ -n "$_PROOF_SELF_DIR" ]; then
  PROOF_SELF="$_PROOF_SELF_DIR/${_PROOF_SELF_RAW##*/}"
else
  PROOF_SELF="$_PROOF_SELF_RAW"
fi

# Gate files enrolled BY NAME rather than by living under tests/inv/: whole-
# file proofs that gate something on their own account.
#
# They are listed HERE, in the runtime enforcement, and not only in
# tests/test_red_case_rule.sh's linter, because a linter reads TEXT. A
# `red_case` call inside a comment, inside a heredoc, or in a branch nothing
# reaches satisfies a grep while nothing ever fires -- the enrolled file would
# then be held to the rule by an assertion that is itself unfalsifiable, which
# is the same defect one level up. Enrolling them by path here means the trap
# below asks the only question that matters: did a case actually RUN.
PROOF_ENROLLED_FILES=(
  tests/test_hermetic_suite.sh
  tests/test_red_case_rule.sh
)

# _proof_enrolled <path> -- true when the RED/GREEN-case rule applies to that
# path. A pure function of the path, so tests/test_red_case_rule.sh can ask it
# about paths that are not the file asking.
_proof_enrolled() {
  case "$1" in */tests/inv/test_*.sh) return 0 ;; esac
  local enrolled
  for enrolled in "${PROOF_ENROLLED_FILES[@]}"; do
    if [ "$1" = "$REPO_ROOT/$enrolled" ]; then return 0; fi
  done
  return 1
}

_red_case_required() {
  if [ -n "${ORCHID_REQUIRE_RED_CASE:-}" ]; then return 0; fi
  if _proof_enrolled "$PROOF_SELF"; then return 0; fi
  # `$0` as well, and never INSTEAD: should the resolution above ever come back
  # with something unexpected -- a `dirname` that cannot be entered, an exotic
  # invocation -- the old spelling can still only ADD a requirement. There is
  # no path through this function that turns one off.
  if _proof_enrolled "$0"; then return 0; fi
  return 1
}
# Printed from the EXIT trap, ahead of its `exit $((FAILS>0))`, so counting a
# FAILS here really does fail the file.
_proof_case_summary() {
  _red_case_required || return 0
  local short=0
  if [ "${RED_CASES:-0}" -eq 0 ]; then
    echo "  FAIL: $PROOF_SELF gates an invariant but recorded no RED case -- call red_case <label> after feeding this file's own check an input it must reject, so the check is known to be able to fail (docs/specs/kernel.md, 'Proof discipline')"
    FAILS=$((FAILS+1)); short=1
  fi
  if [ "${GREEN_CASES:-0}" -eq 0 ]; then
    echo "  FAIL: $PROOF_SELF gates an invariant but recorded no GREEN case -- call green_case <label> after feeding the SAME check an input it must accept, so its RED case is evidence of detection rather than of a matcher that rejects everything. The twin has to run inside THIS file; delegating it to another test file leaves this gate's own acceptance side unexercised (docs/specs/kernel.md, 'Proof discipline')"
    FAILS=$((FAILS+1)); short=1
  fi
  [ "$short" -eq 0 ] || return 0
  echo "  red-cases: $RED_CASES demonstrated in this file (green-cases: $GREEN_CASES)"
}
# Printed from the EXIT trap below, so a file's not-tested count survives even
# an early exit. Silent when there is nothing to report.
_not_tested_summary() {
  [ "${NOT_TESTED:-0}" -eq 0 ] \
    || echo "  not-tested: $NOT_TESTED claim(s) in this file were recorded as not-tested, never as passes"
}

# list_dir_entries <dir> / list_dir_files <dir> -- depth-1 entry names
# (dotfiles included, `.`/`..` never; _files keeps regular files only), one
# per line. Plain bash globbing, not find(1) depth primaries -- limiting a
# find walk to one level needs primaries that are not in POSIX find (T004
# rework; scripts/ci-local.sh's portability policy rejects them repo-wide).
# Subshell function bodies, so the shopt changes never leak into a test.
list_dir_entries() (
  shopt -s nullglob dotglob
  local entry
  for entry in "$1"/*; do
    printf '%s\n' "${entry##*/}"
  done
)
list_dir_files() (
  shopt -s nullglob dotglob
  local entry
  for entry in "$1"/*; do
    if [ -f "$entry" ]; then printf '%s\n' "${entry##*/}"; fi
  done
)
# --------------------------------------------------------------------------
# Scratch-directory registry. THE hazard this exists for (m2's stray-commit
# mishap, and v1-m4 T006's repeat of it): a test file opens with
#
#     cd "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
#
# and `cd ""` is a silent bash no-op -- exit 0, cwd unchanged -- so the
# instant $WORK is EMPTY (or unset, in a shell where `set -u` is not in
# force), that git init and those commits land in whatever the CALLER's cwd
# happens to be. On a task worktree that means git-writing the real checkout
# under test; T006's incident rewrote its orchid.config to a fixture's
# `verify=true`, which would have made every later `orchid verify` pass
# WITHOUT running a test.
#
# $WORK can reach a test file empty two ways, and both are covered here:
#   (a) `mktemp -d` failed (disk full, TMPDIR misconfigured, sandboxing) --
#       plain `WORK="$(mktemp -d)"` then leaves WORK="", not unset, so `set
#       -u` never fires. register_scratch below dies loudly instead.
#   (b) this file never loaded at all -- an INSTRUMENTED COPY of a test file
#       run from a directory where `$(dirname "$0")/helpers.sh` does not
#       resolve. `source` prints "No such file" and keeps going, WORK is
#       simply unset, and (a)'s guard never even ran. That is why the
#       fixtures call `cd_scratch "$WORK" || exit 1` rather than plain `cd`:
#       with helpers.sh missing, cd_scratch is an undefined command, bash
#       exits 127, and `|| exit 1` stops the file BEFORE the first git write.
#
# Only BARE scratch roots (the whole value is one `mktemp -d` result) need
# cd_scratch. A path built as "$WORK/repo" cannot come out empty even when
# WORK is -- it degrades to "/repo", which `cd` rejects, so the existing
# `|| exit 1` already fails closed there.
_SCRATCH_ROOTS=""

# _scratch_die <message> -- print and stop the test file. It ALSO counts a
# FAILS, because the EXIT trap installed below ends with `exit $((FAILS>0))`:
# a bare `exit 1` from here would be laundered back to 0 by that trap and the
# runner would score a file that refused to run as a PASS -- precisely the
# silent outcome this guard exists to prevent. (In a subshell the count is
# lost with the subshell, but so is the git write it stopped, and the
# fixture's own assertions then fail.)
_scratch_die() {
  echo "FATAL: $*" >&2
  FAILS=$((FAILS+1))
  exit 1
}

# register_scratch <dir> -- validate a directory this run just created and
# record it as a legal cd_scratch target. Physical path (`pwd -P`), because
# macOS hands out /var/folders/... symlinks for /private/var/folders/... and
# the prefix test below has to compare like with like.
register_scratch() {
  local d="${1:-}" p
  [ -n "$d" ] && [ -d "$d" ] \
    || _scratch_die "helpers.sh: mktemp -d failed to produce a usable scratch dir (got '$d') -- refusing to run any cd/git"
  p="$(cd "$d" && pwd -P)" \
    || _scratch_die "helpers.sh: cannot resolve scratch dir '$d' -- refusing to run any cd/git"
  _SCRATCH_ROOTS="${_SCRATCH_ROOTS}${p}"$'\n'
}

# make_scratch <varname> -- assign a fresh, registered scratch root to a
# caller-named variable. NOT `X="$(make_scratch)"`: command substitution runs
# in a subshell, so the registration would be thrown away with it.
make_scratch() {
  local __ms_var="${1:?make_scratch <varname>}" __ms_dir
  __ms_dir="$(mktemp -d)"
  register_scratch "$__ms_dir"
  printf -v "$__ms_var" '%s' "$__ms_dir"
}

# cd_scratch <dir> -- `cd` into a scratch directory THIS run created, or die
# without changing directory. Refuses empty, refuses non-directories, and
# refuses any path outside a registered root, so a fixture can never reach
# its `git init` line with the caller's checkout as cwd.
cd_scratch() {
  local d="${1:-}" p root
  [ -n "$d" ] \
    || _scratch_die "cd_scratch: empty scratch path -- refusing to cd (cd '' is a silent no-op, and the git writes that follow would hit the caller's checkout)"
  [ -d "$d" ] || _scratch_die "cd_scratch: '$d' is not a directory -- refusing to cd"
  p="$(cd "$d" && pwd -P)" || _scratch_die "cd_scratch: cannot resolve '$d' -- refusing to cd"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in
      "$root"|"$root"/*)
        cd "$d" || _scratch_die "cd_scratch: cd '$d' failed"
        return 0 ;;
    esac
  done <<<"$_SCRATCH_ROOTS"
  _scratch_die "cd_scratch: '$d' is not inside a scratch directory this run created -- refusing to cd/git there"
}

_scratch_cleanup() {
  local root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    rm -rf "$root"
  done <<<"$_SCRATCH_ROOTS"
}

make_scratch WORK

# Trust/config/plugin state models machine-local HOME state and must not live
# beneath a target repository. Trust-boundary fixtures use this independent
# disposable directory instead of the historical "$WORK/home" shortcut.
make_scratch MACHINE_HOME
trap '_scratch_cleanup; _proof_case_summary; _not_tested_summary; exit $((FAILS>0))' EXIT

# plant_reviewer_envelope <task-id> [attempt] -- v1-m2's kernel envelope-
# count gate (reviewing->arbitrating) requires review_required_count(risk_
# tier) reconciled `reviews/<id>-a<attempt>-reviewer*.json` files on disk,
# EACH bound (`.candidate_sha`) to the task's CURRENT candidate_sha (the
# gate is sha-bound, mirroring INV-11's verify-evidence gate, so a stale
# envelope from before a waived rework can never satisfy it). Fixtures that
# hand-walk a task straight to arbitrating (no real reviewer dispatch+
# reconcile) must plant one themselves, same shape `orchid jobs reconcile`
# itself would have written. attempt defaults to the task's CURRENT
# attempts+1 (the same formula `jobs prepare`/the gate itself use); callers
# relying on the default must run this AFTER any rework bump that already
# happened, so it lands on the right attempt. Assumes the caller has already
# `cd`'d to the repo root (every test file that reaches arbitrating does)
# and that ORCHID_BIN is set.
plant_reviewer_envelope() {
  local id="$1" attempt="${2:-}" cand
  mkdir -p .orchid/reviews
  if [ -z "$attempt" ]; then
    attempt=$(( $("$ORCHID_BIN" task show "$id" | grep '^attempts: ' | cut -d' ' -f2) + 1 ))
  fi
  cand="$("$ORCHID_BIN" task show "$id" | grep '^candidate_sha: ' | cut -d' ' -f2-)"
  jq -n --arg jid "j-fixture-$id-a$attempt" --arg task "$id" --arg cand "$cand" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:"approve", scope_complete:true, summary:"fixture reviewer", candidate_sha:$cand}' \
    > ".orchid/reviews/$id-a$attempt-reviewer.json"
}
