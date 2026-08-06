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
# init` to refresh the name baked in here (init never overwrites a
# pre-existing pre-push hook otherwise -- see below).
#
# `orchid init` never overwrites a pre-existing user pre-push hook (checked
# before this file is ever copied in) -- this file is only ever installed
# into a hooks dir that had none.
[ "${ORCHID_ALLOW_PUSH:-0}" = 1 ] && exit 0

integ="__INTEGRATION_BRANCH__"

blocked=0
while read -r _local_ref _local_sha remote_ref _remote_sha; do
  case "$remote_ref" in
    refs/heads/task/*) blocked=1; blocked_ref="$remote_ref" ;;
    "refs/heads/$integ") blocked=1; blocked_ref="$remote_ref" ;;
  esac
done

if [ "$blocked" -eq 1 ]; then
  echo "orchid: push blocked -- '$blocked_ref' is orchid-managed (task branches and the integration branch, '$integ', are never pushed by the kernel itself; PROTOCOL.md: the operator alone moves anything to origin). Set ORCHID_ALLOW_PUSH=1 to override." >&2
  exit 1
fi
exit 0
