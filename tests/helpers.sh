#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHID_BIN="$REPO_ROOT/bin/orchid"
FAILS=0

# Fixtures deliberately replace HOME to isolate machine-local Orchid state.
# Disposable fixture commits must not depend on an operator's global Git
# identity, which may be absent in hosted CI and extracted archives.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Orchid Tests}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-orchid-tests@example.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

fail()        { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
assert_eq()   { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
assert_match(){ echo "$2" | grep -Eq "$1" || fail "$3 (no match '$1')"; }
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
WORK="$(mktemp -d)"
# v1-m3 (m2 ledger finding, the stray-commit mishap): if mktemp -d ever
# fails, WORK ends up "" -- NOT unset, so `set -u` above never catches it.
# `cd ""` is a silent bash no-op (exit 0, cwd unchanged), so every test
# file's `cd "$WORK" || exit 1; git init -q .; git commit ...` would then run against
# whatever the CALLER's cwd happens to be -- typically the real repo
# checkout under test. Die loudly here, before any test file gets to run a
# single cd/git command against a bogus WORK.
[ -n "$WORK" ] && [ -d "$WORK" ] || {
  echo "FATAL: helpers.sh: mktemp -d failed to produce a usable scratch dir (WORK='$WORK') -- refusing to run any cd/git" >&2
  exit 1
}
trap 'rm -rf "$WORK"; exit $((FAILS>0))' EXIT

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
