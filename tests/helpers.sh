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
trap '_scratch_cleanup; exit $((FAILS>0))' EXIT

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
