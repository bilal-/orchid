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
# existing-repository path is the door that re-renders this file. Once the run
# has left `planning` that door is shut too -- start is a setup command and
# refuses -- so the explicit route is `orchid start --refresh-push-guard`,
# which re-renders this file and does nothing else, at any run_status.
#
# The SECOND LINE of this file is LOAD-BEARING, not decoration:
# lib/common.sh's orchid_install_push_guard recognizes its own installed hook
# by line 2 STARTING with `# orchid pre-push guard`, and that is how a hook
# written by an OLDER orchid gets upgraded to this one instead of being
# mistaken for something the operator wrote. Any hook whose second line does
# not start that way is a user's own and is left untouched -- never
# overwritten, whatever it does, and however often it happens to mention
# orchid elsewhere in its body. So do not move that header off line 2 or
# reword its opening words without changing the marker with it; the rest of
# line 2, after the header, is ordinary prose and free to change.
#
# SECOND leg (T037): refuse any OTHER branch-bound ref that would publish
# orchid's own run state (`.orchid/`) where the remote does not already have
# it -- carried on the tip, or carried by any commit the push makes newly
# reachable. The two legs guard different things and neither covers the other.
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
#
# BRANCH-BOUND REFS ONLY, and that bound is part of the design rather than an
# omission. The leak this leg exists for is a leak along the merge chain: run
# state rides a branch into a product's `main` and becomes part of its history.
# A tag is a different object with a different job -- it names a commit that
# is, by the time anyone tags it, already reachable from a branch that this leg
# either passed or refused on its own merits -- so refusing `git push origin
# v1.2.3` blocks nothing that is not decided elsewhere and breaks a release the
# moment run state is anywhere in the tagged history. The same goes for
# `refs/notes/*`. Every ref that is not branch-bound pushes exactly as plain
# git would, run state or no run state. The NAME-BASED leg above is unaffected
# and runs first: it already keys on `refs/heads/...` destinations of its own.
#
# GERRIT'S `refs/for/*` IS BRANCH-BOUND, and it is the one review ref this leg
# must read as a branch rather than as "some other ref". On a Gerrit-hosted
# project nobody pushes `refs/heads/main` at all -- the upload IS the push
# (`git push origin HEAD:refs/for/main`), and the forge submits that change
# onto `main` afterwards, where no local hook runs. Treating the magic ref as
# a non-branch would mean the entire leak this leg exists for walks straight
# past it on every Gerrit repository, which is the same false protection as an
# inert hook. Both spellings git can be handed are matched -- `refs/for/<branch>`
# and the fully-qualified `refs/for/refs/heads/<branch>` -- and so is a
# push-option suffix (`%topic=x,r=someone,wip`), which Gerrit reads off the
# refname and git carries into this hook verbatim.
#
# A REVIEW UPLOAD FAILS CLOSED: `refs/for/...` is Gerrit magic and is never a
# ref the remote advertises, so the remote sha git hands this hook for it is
# all zeros by construction and there is no remote copy that could exempt it.
# The exemption below is therefore not merely absent here, it can never
# arrive -- which is why the refusal says so instead of offering the
# push-once-with-the-override recovery that the branch leg offers and that
# would leave a Gerrit operator refused again on their very next upload.
#
# THE TIP IS NOT THE PUSH. A push publishes every commit it makes newly
# reachable, not the one tree at the end of them, and `git rm -r .orchid &&
# git commit` removes nothing from a history -- it appends a commit that
# happens to have a smaller tree. So the shape a tip test reads as clean, and
# the shape this leg would otherwise wave through, is the ordinary one: merge
# the integration branch into a feature branch, notice the `.orchid/` paths in
# the diff, delete them, push. Every file is still in the commits being sent,
# still in the clone anybody makes of that branch afterwards, and still on its
# way into whatever the branch is merged into -- which is the entire leak.
# Both questions are therefore asked: the TIP TREE (the shape above), and
# whether any commit this push makes NEWLY REACHABLE touched `.orchid` at all.
#
# "Newly reachable" is measured against what the remote already has, which is
# what keeps the second question from being a standing refusal on a repository
# that tracks run state deliberately: the remote's own copy of the ref being
# pushed (the sha git hands this hook, authoritative and exactly the right
# baseline), plus the remote-tracking refs for that remote, which is the only
# baseline a Gerrit upload or a brand-new branch has. Commits the remote is
# already holding are not published by this push and cannot be its leak. With
# no baseline available at all the whole history is walked, which fails closed.
[ "${ORCHID_ALLOW_PUSH:-0}" = 1 ] && exit 0

integ="__INTEGRATION_BRANCH__"
# githooks(5): the hook is called with the remote's NAME and URL. The name is
# what turns `refs/remotes/<name>/*` into a baseline below; when the push names
# a URL instead of a configured remote there are no tracking refs under it, the
# existence test fails, and the walk simply has one baseline fewer.
remote_name="${1:-}"

# Non-empty output when <commit-ish>'s tree carries durable run state.
# `.orchid/runtime/` is gitignored and never enters a tree, so any `.orchid`
# entry a commit carries is run state by construction.
carries_run_state() {
  [ -n "$(git ls-tree "$1" -- .orchid 2>/dev/null)" ]
}

# history_carries_run_state <tip> [<baseline>...] -- true when any commit
# reachable from <tip> and NOT from any <baseline> ever touched `.orchid`.
# A commit that ADDED those paths and a later commit that DELETED them both
# touch the path, so the add-then-delete branch answers true, which is the
# whole point of asking.
#
# `--full-history` is load-bearing: the default walk simplifies merges away, so
# a feature branch that took run state in through one side of a merge and whose
# tip matches its first parent can have the very commit that carries it pruned
# out of the answer. `--max-count=1` because one is proof and the walk stops.
#
# `--not` is emitted only when there is something to exclude -- a bare `--not`
# with an empty list is a nonsense command line, and this must never be the
# reason a push dies.
history_carries_run_state() {
  local tip="$1"
  shift
  if [ "$#" -gt 0 ]; then
    [ -n "$(git rev-list --full-history --max-count=1 "$tip" --not "$@" -- .orchid 2>/dev/null)" ]
  else
    [ -n "$(git rev-list --full-history --max-count=1 "$tip" -- .orchid 2>/dev/null)" ]
  fi
}

blocked=0
blocked_ref=""
leaked=0
leaked_ref=""
leaked_review=0
leaked_target=""
leaked_where=""
while read -r _local_ref local_sha remote_ref remote_sha; do
  case "$remote_ref" in
    refs/heads/task/*) blocked=1; blocked_ref="$remote_ref"; continue ;;
    "refs/heads/$integ") blocked=1; blocked_ref="$remote_ref"; continue ;;
  esac
  # The run-state leg is scoped to branch-bound refs, and only AFTER the
  # name-based checks above have had their say -- see the header. A tag, a
  # note: normal git behaviour, whatever its commit carries.
  review=0
  target=""
  case "$remote_ref" in
    # A branch is bound to itself.
    refs/heads/*) target="${remote_ref#refs/heads/}" ;;
    refs/for/*)
      # Gerrit, unwrapped in the order git hands it over: the push options
      # first (everything from the first `%`; `[%]` rather than a bare `%`, so
      # the pattern cannot be misread as another trim operator), then the magic
      # prefix, then the optional fully-qualified spelling -- leaving the
      # branch the change is uploaded FOR, which is where submitting it lands
      # the tree.
      review=1
      target="${remote_ref%%[%]*}"
      target="${target#refs/for/}"
      target="${target#refs/heads/}"
      ;;
    *) continue ;;
  esac
  # A deletion (all-zero local sha) pushes no tree and can leak nothing.
  case "$local_sha" in *[!0]*) ;; *) continue ;; esac

  # What the remote already holds, and therefore what this push does NOT
  # publish. Built once here and used by the history walk below.
  #
  #   * the remote's own copy of the ref being pushed -- git hands it over, so
  #     it is both authoritative and free. Skipped for a review upload, where
  #     it is all zeros by construction, and skipped when the object is not
  #     present locally, where it cannot be walked.
  #   * every remote-tracking ref of this remote. For a Gerrit upload and for a
  #     brand-new branch this is the only baseline there is, and it is the
  #     right one: a commit already on the remote somewhere is not introduced
  #     by this push. Added only once a tracking ref actually exists, so the
  #     `--remotes=` glob can never be the thing that makes rev-list fail.
  base=()
  if [ "$review" -eq 0 ]; then
    case "$remote_sha" in
      *[!0]*) git cat-file -e "$remote_sha" 2>/dev/null && base+=("$remote_sha") ;;
    esac
  fi
  if [ -n "$remote_name" ] && \
     [ -n "$(git for-each-ref --count=1 --format='%(refname)' "refs/remotes/$remote_name/" 2>/dev/null)" ]; then
    base+=("--remotes=$remote_name")
  fi

  if carries_run_state "$local_sha"; then
    # A review upload has no remote copy to be exempt by: the remote never
    # advertises `refs/for/...`, so this fails closed rather than reading the
    # all-zero sha git supplies as "nothing to compare, carry on".
    if [ "$review" -eq 0 ]; then
      case "$remote_sha" in
        *[!0]*)
          if git cat-file -e "$remote_sha" 2>/dev/null && carries_run_state "$remote_sha"; then
            continue
          fi ;;
      esac
    fi
    leaked=1; leaked_where="tip"
  elif history_carries_run_state "$local_sha" "${base[@]}"; then
    # The tip is clean and the history is not: somebody deleted the files and
    # pushed the commits that carry them anyway. Reported separately because
    # the remedy is a different one -- another deletion does not help.
    leaked=1; leaked_where="history"
  else
    continue
  fi
  leaked_ref="$remote_ref"; leaked_review="$review"; leaked_target="$target"
done

if [ "$blocked" -eq 1 ]; then
  echo "orchid: push blocked -- '$blocked_ref' is orchid-managed (task branches and the integration branch, '$integ', are never pushed by the kernel itself; PROTOCOL.md: the operator alone moves anything to origin). Set ORCHID_ALLOW_PUSH=1 to override." >&2
  exit 1
fi

if [ "$leaked" -eq 1 ]; then
  # One composer, and the two things it has to vary independently.
  #
  # WHERE the state is decides the remedy: on the tip, deleting the paths is
  # the fix; in the history, deleting them is what somebody already did and it
  # is not a removal. Telling an operator whose tip is clean to "strip .orchid/
  # before pushing" would send them to do again the thing that did not work.
  #
  # WHICH LEG decides the exemption. The branch leg's way out -- push it once
  # with the override and never be asked again -- simply does not exist for a
  # review upload, and offering it there would send an operator through the
  # override only to be refused identically on their next upload.
  if [ "$leaked_where" = history ]; then
    where="in the HISTORY this push publishes -- its tip does not carry those paths any more, but a commit that adds them is among the commits being sent, and deleting a file is a further commit rather than a removal"
    fix="Deleting the paths again changes nothing: rebuild the branch without the commits that carry them (an interactive rebase dropping them, a fresh branch cherry-picking only your own commits, or 'git filter-repo --path .orchid --invert-paths') before pushing."
  else
    where="on its tip"
    fix="If it got there by merging the integration branch ('$integ') into this branch, strip .orchid/ from it before pushing."
  fi
  if [ "$leaked_review" -eq 1 ]; then
    why="and it is a Gerrit review upload for branch '$leaked_target', so submitting it puts that state on '$leaked_target'"
    tail_msg="A 'refs/for/...' ref is never advertised by the remote, so there is no copy of it to compare against and every upload carrying run state is refused."
  else
    why="and the remote does not already hold those commits"
    tail_msg="If this repository tracks run state deliberately (orchid's own does), push it once with ORCHID_ALLOW_PUSH=1 and every later push of this ref is exempt automatically."
  fi
  echo "orchid: push blocked -- '$leaked_ref' carries orchid's own run state (.orchid/ -- roadmap, journal, BLOCKERS, plugins.lock, review envelopes) $where, $why. That state belongs to the run, not to your product: pushed here it becomes part of your project's history and, in a large diff, reads as tooling and is approved as tooling. $fix $tail_msg Set ORCHID_ALLOW_PUSH=1 to override." >&2
  exit 1
fi
exit 0
