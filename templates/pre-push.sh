#!/usr/bin/env bash
# orchid pre-push guard -- installed by `orchid init` (config `push_guard`,
# default true; set `push_guard=false` to skip installing it). v1-m4: a live
# run pushed a task branch to origin twice -- PROTOCOL.md already forbids
# external mutation outright ("No external mutation. Never git push ..."),
# this hook is defense-in-depth for when that rule is violated anyway.
# Refuses any ref update whose DESTINATION (the remote-side ref, third field
# of each stdin line per githooks(5)) matches `refs/heads/task/*` (every
# task branch this template's own `branch: task/__ID__` mints) or the
# integration branch BAKED IN BELOW, unless ORCHID_ALLOW_PUSH=1 is set in
# the environment -- every other ref pushes exactly as it always did.
#
# The integration branch name is resolved and substituted ONCE, at install
# time (`orchid init`, mirroring templates/task.md's own __ID__/__TITLE__/...
# substitution idiom) -- NOT read from `orchid.config` at push time. A
# pre-push hook runs with its cwd at the checkout that triggered the push,
# which for a real task branch push is a TASK WORKTREE: `orchid.config` is an
# untracked, repo-root-only file, so it is simply absent from every task
# worktree, and a runtime grep for it would silently fall back to the
# default name there -- exactly the gap this baked-in substitution closes.
# If `integration_branch` is ever changed in `orchid.config`, re-run `orchid
# start` to refresh the name baked in here: `orchid init` cannot be re-run on
# an initialized repository (it dies with `branch <integ> exists`), so start's
# existing-repository path is the door that re-renders this file.
#
# The words `orchid pre-push guard` on the second line of this file are
# LOAD-BEARING, not decoration: lib/common.sh's orchid_install_push_guard
# recognizes its own installed hook by exactly that phrase, and that is how a
# hook written by an OLDER orchid gets upgraded to this one instead of being
# mistaken for something the operator wrote. Any hook without the phrase is a
# user's own and is left untouched -- never overwritten, whatever it does --
# so do not reword line 2 without changing the marker with it.
#
# SECOND leg (T037): refuse any OTHER ref whose tip carries orchid's own run
# state (`.orchid/`) when the remote's copy of that ref does not already carry
# it. The two legs guard different things and neither covers the other.
#
# The refs blocked BY NAME above are orchid's own branches -- refusing them is
# about who moves what. This leg is about a leak with no orchid branch in it
# at all: on a real product repository 14 `.orchid/` files reached `main` by
# riding the merge chain, integration branch -> feature branch -> MR, and were
# approved because the diff was large and the paths look like tooling. By the
# time that feature branch is pushed it is an ordinary branch with an ordinary
# name; nothing above would look at it twice.
#
# Push is the right place for this leg, and a merge hook is not. Merging is
# only one of the routes -- a squash, a cherry-pick and a rebase put the same
# files on the same branch without ever creating a merge commit, and a hosted
# MR is merged on the forge where no local hook runs at all. Everything that
# reaches a forge is pushed first, so this is the last gate that sees every
# route, and it is a gate that costs nothing to be wrong about: the state is
# still local, and the override below is one variable.
#
# The exemption is what keeps this from being a nuisance: a ref whose remote
# copy ALREADY carries run state is a repository that tracks it on purpose --
# orchid's own, self-hosted, is exactly that -- and this push is not the one
# that introduced it. Only a push that would put run state somewhere it is not
# yet is refused. A remote sha of all zeros (a brand-new remote branch) has no
# copy to exempt, and one whose object is not present locally cannot be read
# to check: both fail CLOSED, since the cost is a message and a variable.
[ "${ORCHID_ALLOW_PUSH:-0}" = 1 ] && exit 0

integ="__INTEGRATION_BRANCH__"

# Non-empty output when <commit-ish>'s tree carries durable run state.
# `.orchid/runtime/` is gitignored and never enters a tree, so any `.orchid`
# entry a commit carries is run state by construction.
carries_run_state() {
  [ -n "$(git ls-tree "$1" -- .orchid 2>/dev/null)" ]
}

blocked=0
blocked_ref=""
leaked=0
leaked_ref=""
while read -r _local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/task/*) blocked=1; blocked_ref="$remote_ref"; continue ;;
    "refs/heads/$integ") blocked=1; blocked_ref="$remote_ref"; continue ;;
  esac
  # A deletion (all-zero local sha) pushes no tree and can leak nothing.
  case "$local_sha" in *[!0]*) ;; *) continue ;; esac
  carries_run_state "$local_sha" || continue
  case "$remote_sha" in
    *[!0]*)
      if git cat-file -e "$remote_sha" 2>/dev/null && carries_run_state "$remote_sha"; then
        continue
      fi ;;
  esac
  leaked=1; leaked_ref="$remote_ref"
done

if [ "$blocked" -eq 1 ]; then
  echo "orchid: push blocked -- '$blocked_ref' is orchid-managed (task branches and the integration branch, '$integ', are never pushed by the kernel itself; PROTOCOL.md: the operator alone moves anything to origin). Set ORCHID_ALLOW_PUSH=1 to override." >&2
  exit 1
fi

if [ "$leaked" -eq 1 ]; then
  echo "orchid: push blocked -- '$leaked_ref' carries orchid's own run state (.orchid/ -- roadmap, journal, BLOCKERS, plugins.lock, review envelopes) and the remote's copy of that ref does not. That state belongs to the run, not to your product: pushed here it becomes part of your project's history and, in a large diff, reads as tooling and is approved as tooling. If it got there by merging the integration branch ('$integ') into this branch, strip .orchid/ from it before pushing. If this repository tracks run state deliberately (orchid's own does), push it once with ORCHID_ALLOW_PUSH=1 and every later push of this ref is exempt automatically. Set ORCHID_ALLOW_PUSH=1 to override." >&2
  exit 1
fi
exit 0
