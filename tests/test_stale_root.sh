#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# ---------------------------------------------------------------------------
# T006 / lesson L018: orchid refuses to run FROM a checkout of the integration
# branch whose kernel files have fallen behind that branch, and `orchid merge`
# refreshes the ONE checkout it is itself running from so that refusal never
# fires on the merge's own bookkeeping.
#
# bin/orchid resolves $ORCHID_ROOT from its own location, so the verbs, libs,
# runners and engine adapters it executes come from that checkout's WORKING
# TREE. `orchid merge` advances the integration branch with `update-ref`
# alone -- by design, so it never reaches into another checkout's index or
# working tree -- which leaves a checkout parked on that branch running
# PRE-MERGE code indefinitely while every merge reports success. That is not
# hypothetical: on 2026-08-06 a merged review-adapter fix stayed inert for two
# further rounds because the launcher kept reading the pre-merge adapter off a
# stale working tree, and the existing advisory warning was read and dismissed
# on the first command of that session.
#
# The two cases most likely to be broken BY the fix get first-class coverage
# here, because a mismatch check that refused on any uncommitted edit would
# make the tool unusable, and one that refreshed or refused over `.orchid/`
# would re-run the r-001 journal-loss incident:
#
#   * ordinary DIRTY development still works -- on a development branch,
#     however far the working tree has drifted from HEAD (checks 5 and 6); on
#     the integration branch itself for everything that is not kernel code,
#     which is what keeps the `edit orchid.config` -> `orchid config commit`
#     path working (check 4); and, the case that took three rounds to get
#     right, on the integration branch for KERNEL code too (check 13), because
#     that checkout is the one orchid is itself developed in.
#   * uncommitted durable `.orchid/` state, and an uncommitted `orchid.config`
#     with it, survive the refusal, the documented remedy, the automatic
#     refresh and a branch-side advance of that same state (checks 1-4, 8, 9).
#
# Checks 8 and 9 are the ones the first attempt did not have. 8 pins the
# restore itself, including the case a bare `git checkout HEAD -- <paths>`
# cannot clear. 9 pins the regression that check made possible: a self-hosted
# `orchid merge` whose ref advance strands its own `task advance <id> done`
# behind the refusal, leaving the branch moved and the task frozen in
# `merging` with no verb left able to move it.
#
# 8b and 10 are the two ways the automatic refresh must NOT go, and both are
# the r-001 journal-loss hazard wearing kernel clothes rather than `.orchid/`
# ones: 8b is a refresh that would overwrite an untracked file of the
# operator's, 10 is a merge that correctly declines to refresh over their
# uncommitted kernel edit and then has to SAY so -- the merge is the only
# process that saw this checkout before the ref moved, and so the only one
# that can name the cause at all. The refusal downstream cannot (13b).
#
# 12 and 13 are the two the earlier rounds of this task did not have, and both
# are defects the guard SHIPPED with rather than hazards it might have had.
#
#   * 12: PROTOCOL.md is executed, not merely read. The skills carry no
#     procedure of their own -- they tell the engine to read
#     $ORCHID_ROOT/PROTOCOL.md and follow it -- so a merge that changes ONLY
#     the protocol used to be invisible to this guard: no refusal, no
#     refresh, and a run that went on executing the PRE-MERGE procedure. That
#     is this task's own failure class on the one file that defines the
#     procedure.
#   * 13 and 13b: what the refusal may CLAIM, and what it may PRINT. Two
#     successive versions of it guessed at a cause it cannot observe and
#     attached `git checkout HEAD -- <kernel paths>` to the guess -- first
#     against a hand-edited kernel, then against a staged-only edit, both read
#     as "behind", both remedies overwriting the operator's only copy. Dogfood
#     finding F31 is that same shape costing a requirements.md edit. So the
#     rule is now structural rather than per-state: report the observation,
#     name the paths, print nothing that writes. assert_no_lossy_command holds
#     it as a class so the next round cannot satisfy it by changing which
#     command it prescribes.
#
#     13 is also where the dirty-development criterion is actually tested. The
#     guard fires only in a checkout of the integration branch, and orchid is
#     developed in one, so "any uncommitted edit refuses" was not a hypothetical
#     unusability -- it was orchid refusing to run in its own development
#     checkout. Comparing the INDEX rather than the working tree is what fixes
#     it, and 13b is the price: a STAGED edit is indistinguishable from a
#     branch advance and so still refuses, reporting both possibilities.
#
#   * 14: the window between `orchid merge`'s ref advance and its refresh,
#     which is a real interval in which this checkout's index really does not
#     match HEAD. Concurrent verbs from the same root -- not children of the
#     merge, so not covered by its ORCHID_ALLOW_STALE_ROOT -- meet it. A round
#     of this task let them RUN for the duration, which is this guard's own
#     failure class inside its own fix: the tree they ran was the pre-merge
#     one. They refuse now, with a distinct message and exit status, and 14
#     pins both that and the identity that decides which message -- a bare PID
#     outlives a SIGKILLed merge and is eventually reissued.
# ---------------------------------------------------------------------------

# The one list the guard, the refresh and the documented remedy all use. Kept
# here literally, NOT sourced from lib/common.sh, so that a silent edit to
# ORCHID_KERNEL_PATHS has to be made in two places and is seen in review.
#
# Split in two because the fixture builder below has to MAKE these paths and
# they are not all of a kind: eight directories the launcher executes out of,
# and one FILE, PROTOCOL.md, which is the procedure a tick executes. The guard
# treats them identically (a pathspec is a pathspec); only `mkdir` cares.
KERNEL_DIRS=(bin lib libexec runners plugins roles skills templates)
KERNEL=("${KERNEL_DIRS[@]}" PROTOCOL.md)

# make_root <dir> <branch> -- a minimal but REAL orchid installation root: the
# shipped dispatcher and the shipped lib/common.sh under test, plus one
# `version` verb whose only job is to report WHICH copy of itself just ran,
# and one `gone` verb that a later commit deletes. Every kernel path exists --
# the eight directories and PROTOCOL.md -- so the remedy the refusal prints
# can be run against it verbatim.
# Committed on <branch> alongside one tracked `.orchid/journal.md` standing in
# for durable run state and one tracked `orchid.config`. The branch is pinned
# explicitly so the fixture never depends on the machine's
# `init.defaultBranch`.
make_root() {
  local dir="$1" branch="$2" d
  for d in "${KERNEL_DIRS[@]}"; do mkdir -p "$dir/$d"; printf 'fixture\n' > "$dir/$d/.keep"; done
  printf 'PROTOCOL v1\n' > "$dir/PROTOCOL.md"
  mkdir -p "$dir/.orchid"
  cp "$REPO_ROOT/bin/orchid" "$dir/bin/orchid"
  cp "$REPO_ROOT/lib/common.sh" "$dir/lib/common.sh"
  cat > "$dir/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "adapter: pre-merge"
VERB
  cat > "$dir/libexec/orchid-gone" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "gone: still here"
VERB
  chmod +x "$dir/bin/orchid" "$dir/libexec/orchid-version" "$dir/libexec/orchid-gone"
  printf 'committed journal line\n' > "$dir/.orchid/journal.md"
  printf 'integration_branch=orchid/integration\nverify=true\n' > "$dir/orchid.config"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture: kernel v1"
}

# run_version <root> [allow] -- the fixture's own launcher, with a disposable
# HOME so no machine-local ~/.orchid/config can reach config_get. <allow> is
# the ORCHID_ALLOW_STALE_ROOT value, empty (i.e. guard active) by default.
# Leaves the exit status in $rc and the merged output in $out.
run_version() {
  local root="$1" allow="${2:-}"
  rc=0
  out="$(HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT="$allow" \
    "$root/bin/orchid" version 2>&1)" || rc=$?
}

# assert_no_lossy_command <label> -- the rule the whole of this round is, held
# against whatever refusal or warning is in $out: orchid may print commands
# for LOOKING and must print none that writes to a working tree or an index.
#
# Written as a CLASS check, not as a search for the one string a past round
# happened to emit, because the defect has now appeared twice in two different
# states -- a hand-edited kernel and a staged-only edit -- and the text it
# prescribed was not the same text both times. What is invariant is the shape:
# `git [-C <dir>] <write-verb>`. The bare words are useless to match on ("the
# checkout orchid itself runs from" is the refusal's own first clause), so the
# two-token sequence is what gets pinned.
assert_no_lossy_command() {
  local bad
  bad="$(grep -Eo 'git( +-C +[^ ]+)? +(checkout|restore|reset|clean|stash|rm|apply|mv)' <<<"$out" || true)"
  [ -z "$bad" ] || fail "$1 -- printed a command that can discard uncommitted work: $(tr '\n' ' ' <<<"$bad")"
}

# ===========================================================================
# 1 -- a stale integration checkout REFUSES, and refusing costs no state
# ===========================================================================
# The same fixture topology tests/test_init_doctor.sh already uses for the
# durable-state half of this hazard, because it is the real deployment shape:
# a hub repository on its own branch, the integration branch checked out as a
# linked worktree ($root -- this is where orchid runs from), and a second,
# DETACHED worktree that commits the "merged fix". The branch ref is then
# force-moved onto that commit from the hub, so $root's own index and working
# tree are never touched -- exactly the update-ref-under-a-checkout signature
# `orchid merge` produces.
hub="$WORK/hub"
make_root "$hub" main
git -C "$hub" branch orchid/integration
root="$WORK/root"
git -C "$hub" worktree add -q "$root" orchid/integration
elsewhere="$WORK/root-elsewhere"
git -C "$hub" worktree add -q --detach "$elsewhere" orchid/integration
cat > "$elsewhere/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "adapter: post-merge"
VERB
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "fixture: kernel v2 (the merged fix)"
git -C "$hub" update-ref refs/heads/orchid/integration "$(git -C "$elsewhere" rev-parse HEAD)"

# Durable run state the operator has NOT committed, sitting in the stale
# checkout: tracked at HEAD and locally appended to, so a bare `git checkout
# HEAD -- .` would silently revert it. This is the r-001 incident's shape.
printf 'uncommitted durable line\n' >> "$root/.orchid/journal.md"
journal_before="$(cat "$root/.orchid/journal.md")"
# The same shape one file over: the config edit the documented `orchid config
# commit` path leaves uncommitted by design. It is tracked, so the remedy the
# refusal prints must not be broad enough to restore it either.
printf '# probe marker kept\n' >> "$root/orchid.config"
config_before="$(cat "$root/orchid.config")"

run_version "$root"
assert_eq 1 "$rc" "a stale integration checkout refuses to run, it does not merely warn"
assert_match "refusing to run: the checkout orchid itself runs from" "$out" \
  "the refusal says the ROOT is what is stale, not the managed repo"
assert_match "orchid/integration" "$out" "the refusal names the branch it is parked on"
assert_match "INDEX does not match HEAD" "$out" \
  "and reports the OBSERVATION it made rather than a cause it cannot establish"
assert_match "libexec/orchid-version" "$out" \
  "naming the kernel paths it is talking about, so the operator can look at them"
# The read-only commands are the whole of what it prescribes. `status --short`
# and `diff --cached` change nothing, which is the property being pinned --
# not their exact spelling.
assert_match "git -C .* status --short -- bin lib libexec runners plugins roles skills templates PROTOCOL.md" "$out" \
  "it offers a read-only way to LOOK, scoped to the kernel paths and PROTOCOL.md with it"
assert_match "ORCHID_ALLOW_STALE_ROOT=1" "$out" "the refusal names its own override"
assert_no_lossy_command "even where the checkout really has only fallen behind, the refusal"
assert_eq "$journal_before" "$(cat "$root/.orchid/journal.md")" \
  "refusing must not touch uncommitted durable .orchid state"

# The hazard the refusal exists for, demonstrated: with the override, this
# checkout really does execute the PRE-MERGE adapter while its branch head
# carries the merged one.
run_version "$root" 1
assert_eq 0 "$rc" "ORCHID_ALLOW_STALE_ROOT=1 runs the one command anyway"
assert_match "adapter: pre-merge" "$out" \
  "the stale root was in fact executing pre-merge code (lesson L018)"

# ===========================================================================
# 2 -- the remedy the DOCS give for this case clears it, and costs no state
# ===========================================================================
# The restore lives in docs/troubleshooting.md now and not in the refusal,
# under a heading the operator only reaches after establishing which case they
# are in -- a page can spell out what a command costs, a one-line refusal that
# guessed the case cannot. What is pinned here is unchanged either way: run
# against a checkout that really has only fallen behind, the kernel-scoped
# pathspec clears the refusal and reaches nothing else.
git -C "$root" checkout HEAD -- "${KERNEL[@]}"
assert_eq "$journal_before" "$(cat "$root/.orchid/journal.md")" \
  "the documented restore preserves uncommitted durable .orchid state"
assert_eq "$config_before" "$(cat "$root/orchid.config")" \
  "the documented restore preserves an uncommitted orchid.config edit"
run_version "$root"
assert_eq 0 "$rc" "the refusal clears after the documented restore"
assert_match "adapter: post-merge" "$out" "the refreshed root executes the merged code"

# ===========================================================================
# 3 -- a branch-side advance of .orchid/ ALONE is not a refusal
# ===========================================================================
# The kernel code on disk still matches HEAD, so nothing the launcher executes
# is stale. Refusing here would block a run over its own durable state and
# push operators toward the bare refresh that lost the r-001 journal.
printf 'branch-side journal line\n' > "$elsewhere/.orchid/journal.md"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "fixture: durable .orchid state advanced on the branch"
git -C "$hub" update-ref refs/heads/orchid/integration "$(git -C "$elsewhere" rev-parse HEAD)"
run_version "$root"
assert_eq 0 "$rc" "an .orchid-only branch advance is not a stale-kernel refusal"
assert_eq "$journal_before" "$(cat "$root/.orchid/journal.md")" \
  "and it still leaves the checkout's own uncommitted durable state alone"

# ===========================================================================
# 4 -- uncommitted non-kernel edits on the integration branch still run
# ===========================================================================
# The documented operator path for a config change is to edit orchid.config in
# the integration checkout and land it with `orchid config commit`. That edit
# is uncommitted by definition and must never be a refusal: it changes nothing
# about which code the launcher executes.
printf 'role.implementer=fake\n' >> "$root/orchid.config"
printf 'more uncommitted durable state\n' >> "$root/.orchid/journal.md"
run_version "$root"
assert_eq 0 "$rc" "an uncommitted orchid.config/.orchid edit on the integration branch still runs"
assert_match "adapter: post-merge" "$out" "and still runs the branch's own kernel code"

# ===========================================================================
# 5 -- an ordinary DIRTY development checkout runs
# ===========================================================================
# Nothing merges onto a development branch, so however dirty the tree gets --
# unstaged edit, staged edit, untracked file, all three at once -- the kernel
# must run normally. A check that refused on any uncommitted edit would make
# orchid unusable to develop with.
devroot="$WORK/devroot"
make_root "$devroot" main
printf 'echo "dev: staged edit"\n' >> "$devroot/libexec/orchid-version"
git -C "$devroot" add libexec/orchid-version
printf 'echo "dev: unstaged edit"\n' >> "$devroot/libexec/orchid-version"
printf 'scratch\n' > "$devroot/notes.txt"
run_version "$devroot"
assert_eq 0 "$rc" "a dirty development checkout still runs"
assert_match "dev: unstaged edit" "$out" "and runs the developer's working-tree edit"

# The same checkout after committing that work: still clean, still runs.
git -C "$devroot" add -A
git -C "$devroot" commit -q -m "dev: local work"
run_version "$devroot"
assert_eq 0 "$rc" "an ordinary local commit is not a stale root"

# ===========================================================================
# 6 -- the SAME stale shape on a development branch is not a refusal
# ===========================================================================
# Same drift, same technique, different branch: this pins condition 1 rather
# than letting check 5 pass merely because its tree happened to be less
# divergent. Only the branch a run merges onto can go stale behind an
# operator's back, and only it is asked about.
develsewhere="$WORK/devroot-elsewhere"
git -C "$devroot" worktree add -q --detach "$develsewhere" main
cat > "$develsewhere/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "adapter: dev branch moved on"
VERB
git -C "$develsewhere" add -A
git -C "$develsewhere" commit -q -m "dev: someone else advanced main"
git -C "$devroot" update-ref refs/heads/main "$(git -C "$develsewhere" rev-parse HEAD)"
run_version "$devroot"
assert_eq 0 "$rc" "a development branch advanced under its checkout is not a refusal"

# ===========================================================================
# 7 -- a non-git installation root is inert
# ===========================================================================
# The ordinary `brew`/`install.sh` prefix is not a checkout at all: there is
# no branch, nothing can advance under it, and the guard must never fire.
plain="$WORK/plain"
make_root "$plain" orchid/integration
rm -rf "$plain/.git"
run_version "$plain"
assert_eq 0 "$rc" "a non-git installation root runs unconditionally"
assert_match "adapter: pre-merge" "$out" "a non-git installation root runs its own code"

# ===========================================================================
# 8 -- orchid_refresh_kernel restores what a bare checkout cannot
# ===========================================================================
# The branch advances again, this time with all three shapes of kernel change
# in one commit: a MODIFIED verb, an ADDED verb (which must arrive executable
# or bin/orchid reports it as an unknown command), and a DELETED verb.
#
# `git checkout HEAD -- <paths>` handles the first two and NOT the third: it
# never removes an index entry the new HEAD has dropped, so the deleted verb
# stays tracked, `git diff HEAD` keeps reporting it, and the refusal survives
# the remedy. That is the gap orchid_refresh_kernel closes, and it is asserted
# here in both directions so the helper cannot be quietly replaced by the
# one-liner it exists to fix.
cat > "$elsewhere/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "adapter: post-merge-2"
VERB
cat > "$elsewhere/libexec/orchid-fresh" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "fresh: merged verb"
VERB
chmod +x "$elsewhere/libexec/orchid-fresh"
rm -f "$elsewhere/libexec/orchid-gone"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "fixture: kernel v3 (add, modify, delete)"
git -C "$hub" update-ref refs/heads/orchid/integration "$(git -C "$elsewhere" rev-parse HEAD)"

journal_before="$(cat "$root/.orchid/journal.md")"
config_before="$(cat "$root/orchid.config")"
run_version "$root"
assert_eq 1 "$rc" "the add/modify/delete advance is a refusal like any other"

git -C "$root" checkout HEAD -- "${KERNEL[@]}"
assert_match "fresh: merged verb" \
  "$(HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1 "$root/bin/orchid" fresh 2>&1)" \
  "a bare checkout does restore an added verb, executable bit and all"
run_version "$root"
assert_eq 1 "$rc" \
  "but the bare checkout leaves the DELETED verb tracked, so the refusal survives the one-liner"

rc=0
# `export`, not a bare assignment, and the same in the four subshells like this
# one below. The consumer is the `source` on the next line -- lib/common.sh's
# stale-root guard, which this root would otherwise refuse -- and a linter
# cannot see inside a sourced file, so a bare assignment here reads as an
# unused variable (SC2034). Exporting states the same thing in a form that is
# checkable, and reaches nothing but the `git` children these helpers spawn,
# which do not read it.
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_refresh_kernel "$root" ) || rc=$?
assert_eq 0 "$rc" "orchid_refresh_kernel reports success"
[ -e "$root/libexec/orchid-gone" ] \
  && fail "orchid_refresh_kernel leaves behind a verb the branch deleted"
run_version "$root"
assert_eq 0 "$rc" "and the refusal is cleared by it"
assert_match "adapter: post-merge-2" "$out" "the root now executes the branch's kernel"
assert_eq "$journal_before" "$(cat "$root/.orchid/journal.md")" \
  "the refresh never touches uncommitted durable .orchid state"
assert_eq "$config_before" "$(cat "$root/orchid.config")" \
  "the refresh never touches an uncommitted orchid.config edit"

# A hand-edited kernel is exactly what the refresh must NOT silently discard:
# orchid_kernel_clean is the precondition every caller checks first, and it
# has to say "dirty" here even though the edit is only in the working tree.
printf 'echo "operator hand-edit"\n' >> "$root/libexec/orchid-version"
rc=0
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_kernel_clean "$root" ) || rc=$?
assert_eq 1 "$rc" "orchid_kernel_clean refuses a checkout with an uncommitted kernel edit"
git -C "$root" checkout HEAD -- libexec/orchid-version

# ===========================================================================
# 8b -- the refresh declines rather than overwrite an UNTRACKED file
# ===========================================================================
# orchid_kernel_clean cannot cover this one, and not for want of trying: it is
# asked BEFORE the ref moves, and at that moment an untracked scratch file
# under libexec/ is not drift, does not veto anything, and could not be harmed
# by any restore. The collision only exists once the branch has added a
# TRACKED file at that same path -- after which `git diff HEAD` reports the
# path as deleted (the index has no entry for it) and a reset-then-checkout
# would silently write the branch's bytes over the operator's file.
#
# So the restore has to ask, per path, and decline. That is the r-001
# journal-loss hazard in kernel clothing: uncommitted work destroyed by a
# refresh nobody asked for.
cat > "$elsewhere/libexec/orchid-added-later" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "added-later: the branch's version"
VERB
chmod +x "$elsewhere/libexec/orchid-added-later"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "fixture: kernel v4 (adds a verb)"
git -C "$hub" update-ref refs/heads/orchid/integration "$(git -C "$elsewhere" rev-parse HEAD)"

printf 'operator draft, never committed, never anywhere else\n' \
  > "$root/libexec/orchid-added-later"
draft_before="$(cat "$root/libexec/orchid-added-later")"

rc=0
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_refresh_kernel "$root" ) || rc=$?
assert_eq 1 "$rc" \
  "orchid_refresh_kernel reports failure rather than a refresh it did not do"
assert_eq "$draft_before" "$(cat "$root/libexec/orchid-added-later")" \
  "an untracked file at a path the branch now carries is never overwritten"
run_version "$root"
assert_eq 1 "$rc" "and the refusal stands, so the operator has to look at it"

# Once the operator has dealt with their file, the same refresh completes.
rm -f "$root/libexec/orchid-added-later"
rc=0
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_refresh_kernel "$root" ) || rc=$?
assert_eq 0 "$rc" "with the file out of the way the refresh succeeds"
assert_match "added-later: the branch's version" \
  "$(HOME="$MACHINE_HOME" "$root/bin/orchid" added-later 2>&1)" \
  "and the branch's verb is now the one that runs"

# ===========================================================================
# 9 -- `orchid merge` refreshes the checkout it is itself running from
# ===========================================================================
# The regression the refusal creates if merge is left alone. In a self-hosted
# run $ORCHID_ROOT and the managed repo are the same directory, so the CAS
# `update-ref` at the end of `orchid merge` makes that directory stale in the
# same instant -- and the very next child process is merge's own `task advance
# <id> done`. Unguarded, that child refuses: the integration branch carries
# the work, the task is frozen in `merging`, and every verb that could say so
# refuses too.
#
# A REAL orchid root, copied from this checkout, so the merge runs the shipped
# verb and not a stand-in. The candidate carries all three kernel shapes again
# (add/modify/delete) plus the durable-state hazards on either side of the
# pathspec: an untracked `.orchid/` sentinel and a tracked-but-uncommitted
# `orchid.config` edit that the refresh must not so much as read.
selfroot="$WORK/selfhosted"
mkdir -p "$selfroot"
for d in "${KERNEL[@]}"; do cp -R "$REPO_ROOT/$d" "$selfroot/$d"; done
printf 'v1\n' > "$selfroot/templates/probe-mutable.txt"
printf 'doomed\n' > "$selfroot/templates/probe-doomed.txt"
printf 'integration_branch=orchid/integration\n' > "$selfroot/orchid.config"
git init -q "$selfroot"
git -C "$selfroot" symbolic-ref HEAD refs/heads/orchid/integration
git -C "$selfroot" add -A
git -C "$selfroot" commit -q -m "self-hosted fixture: kernel v1"

# The candidate branch, committed BEFORE any .orchid state exists so `add -A`
# cannot sweep durable state into it.
git -C "$selfroot" checkout -q -b task/TS1
cat > "$selfroot/libexec/orchid-probe" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "probe: merged"
VERB
chmod +x "$selfroot/libexec/orchid-probe"
printf 'v2\n' > "$selfroot/templates/probe-mutable.txt"
rm -f "$selfroot/templates/probe-doomed.txt"
git -C "$selfroot" add -A
git -C "$selfroot" commit -q -m "self-hosted fixture: kernel v2"
self_cand="$(git -C "$selfroot" rev-parse HEAD)"
git -C "$selfroot" checkout -q orchid/integration
self_base="$(git -C "$selfroot" rev-parse orchid/integration)"

mkdir -p "$selfroot/.orchid/tasks" "$selfroot/.orchid/reviews"
printf 'durable sentinel\n' > "$selfroot/.orchid/sentinel"
printf '# probe marker kept\n' >> "$selfroot/orchid.config"
self_config_before="$(cat "$selfroot/orchid.config")"

cd_scratch "$selfroot" || exit 1
ORCHID_BIN="$selfroot/bin/orchid"          # plant_reviewer_envelope reads this
export ORCHID_REPO="$selfroot"
HOME="$WORK/selfhome"; mkdir -p "$HOME"; export HOME
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create TS1 "self-hosted kernel merge" >/dev/null
"$ORCHID_BIN" task set TS1 base_sha "$self_base"
"$ORCHID_BIN" task set TS1 candidate_sha "$self_cand"
"$ORCHID_BIN" task set TS1 verification_commands "true"
"$ORCHID_BIN" task advance TS1 implementing
"$ORCHID_BIN" task advance TS1 testing
git -C "$selfroot" checkout -q task/TS1
"$ORCHID_BIN" verify TS1 >/dev/null
git -C "$selfroot" checkout -q orchid/integration
"$ORCHID_BIN" task advance TS1 reviewing
plant_reviewer_envelope TS1
"$ORCHID_BIN" task advance TS1 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task advance TS1 merging --reason "approved for merge"

rc=0
out="$("$ORCHID_BIN" merge TS1 2>&1)" || rc=$?
assert_eq 0 "$rc" "a self-hosted merge completes instead of stranding on its own ref advance"
assert_match "^merged TS1: orchid/integration -> " "$out" "it reports the merge"
assert_match "^refreshed .* to orchid/integration \(orchid runs from this checkout\)" "$out" \
  "and says plainly that it refreshed the checkout it runs from"
assert_eq 'done' "$("$ORCHID_BIN" task show TS1 | grep '^status: ' | cut -d' ' -f2)" \
  "the task reaches done -- the bookkeeping after the advance is not refused"
[ "$(git -C "$selfroot" rev-parse orchid/integration)" != "$self_base" ] \
  || fail "the integration ref advanced"

# The point of the whole task: the run now executes its own merged work.
assert_match "probe: merged" "$("$ORCHID_BIN" probe 2>&1)" \
  "the merged verb is live in the checkout orchid runs from, executable bit and all"
assert_eq v2 "$(cat "$selfroot/templates/probe-mutable.txt")" "a modified kernel file is refreshed"
[ -e "$selfroot/templates/probe-doomed.txt" ] \
  && fail "a kernel file the merge deleted is still on disk after the refresh"

# ...without the refresh reaching one byte outside the kernel pathspec.
assert_eq "durable sentinel" "$(cat "$selfroot/.orchid/sentinel")" \
  "uncommitted durable .orchid state survives the automatic refresh"
assert_eq "$self_config_before" "$(cat "$selfroot/orchid.config")" \
  "an uncommitted orchid.config edit survives the automatic refresh"

# And an ordinary verb afterwards is not refused, which is what "the run keeps
# going" actually means.
rc=0
"$ORCHID_BIN" task show TS1 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "an ordinary verb runs against the refreshed checkout"

# ===========================================================================
# 10 -- the merge that must NOT refresh says so, on the merge that caused it
# ===========================================================================
# Check 9's refresh is conditional, and this is the condition failing. The
# checkout orchid runs from carries a kernel edit of its own, so restoring it
# would throw that edit away -- which the design forbids, and which check 8's
# orchid_kernel_clean assertion already pins. What is left is the operator's
# side of it: the branch still advances, so this checkout still goes stale,
# and the only place that can be explained while it is still comprehensible
# is the merge that did it. A silent advance here means the operator meets a
# refusal with no idea their own edit is why. That matters more now than it
# did: the refusal downstream reports what it observes and no longer claims a
# cause (check 13b), so THIS warning is the only place in the whole sequence
# where the cause is actually known -- the merge is the one process that saw
# this checkout before the ref moved.
#
# The edit is UNSTAGED, which is both the ordinary developer's shape and the
# only one that can reach this code at all. The guard compares the INDEX, so
# an unstaged kernel edit does not refuse and `orchid merge` runs; the merge
# then asks orchid_kernel_clean, whose working-tree half correctly calls the
# checkout dirty, and has to decide. A STAGED edit cannot be used here: it
# refuses at source time, so `orchid merge` never starts, which is a safe
# outcome and an untestable one.
self_base2="$(git -C "$selfroot" rev-parse orchid/integration)"
git -C "$selfroot" checkout -q -b task/TS2
printf 'v3\n' > "$selfroot/templates/probe-mutable.txt"
# A targeted `add`, never `add -A`: durable `.orchid/` run state exists in this
# fixture by now and must not be swept into a candidate branch.
git -C "$selfroot" add templates/probe-mutable.txt
git -C "$selfroot" commit -q -m "self-hosted fixture: kernel v3"
self_cand2="$(git -C "$selfroot" rev-parse HEAD)"
git -C "$selfroot" checkout -q orchid/integration

"$ORCHID_BIN" task create TS2 "self-hosted merge over a dirty kernel index" >/dev/null
"$ORCHID_BIN" task set TS2 base_sha "$self_base2"
"$ORCHID_BIN" task set TS2 candidate_sha "$self_cand2"
"$ORCHID_BIN" task set TS2 verification_commands "true"
"$ORCHID_BIN" task advance TS2 implementing
"$ORCHID_BIN" task advance TS2 testing
git -C "$selfroot" checkout -q task/TS2
"$ORCHID_BIN" verify TS2 >/dev/null
git -C "$selfroot" checkout -q orchid/integration

# Unstaged, and made AFTER the branch round-trip above: `git checkout` would
# have refused to move across a change to the same file.
printf 'operator kernel edit\n' >> "$selfroot/templates/probe-mutable.txt"
dirty_before="$(git -C "$selfroot" diff --name-only HEAD -- "${KERNEL[@]}")"
assert_match "templates/probe-mutable.txt" "$dirty_before" \
  "test fixture: the kernel edit really is in the working tree"
worktree_before="$(cat "$selfroot/templates/probe-mutable.txt")"

rc=0
"$ORCHID_BIN" task show TS2 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" \
  "an unstaged kernel edit is not a refusal — this is a developer editing orchid in its own checkout"

"$ORCHID_BIN" task advance TS2 reviewing
plant_reviewer_envelope TS2
"$ORCHID_BIN" task advance TS2 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task advance TS2 merging --reason "approved for merge"

rc=0
out="$("$ORCHID_BIN" merge TS2 2>&1)" || rc=$?
assert_eq 0 "$rc" "the merge still completes when it may not refresh"
assert_match "^merged TS2: orchid/integration -> " "$out" "it reports the merge"
assert_match "kernel files were already modified before the merge" "$out" \
  "and names the operator's own edit as the reason it left this checkout stale"
assert_match "templates/probe-mutable.txt" "$out" \
  "naming the file, captured before the advance mixed the merge's own drift into every comparison"
assert_no_lossy_command "the merge's declined-refresh warning"
if grep -q "^refreshed " <<<"$out"; then
  fail "the merge claimed a refresh it must not have performed"
fi
assert_eq "$worktree_before" "$(cat "$selfroot/templates/probe-mutable.txt")" \
  "the operator's kernel edit is exactly as they left it — the merge discarded nothing"

# The checkout is stale now, on purpose, and behaves like it: ordinary verbs
# refuse, while the merge's own bookkeeping still reached done.
rc=0
"$ORCHID_BIN" task show TS2 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "an ordinary verb refuses against the checkout the merge left stale"
assert_eq 'done' "$(ORCHID_ALLOW_STALE_ROOT=1 "$ORCHID_BIN" task show TS2 | grep '^status: ' | cut -d' ' -f2)" \
  "but TS2 still reached done — the merge is never left half-finished"
assert_eq "durable sentinel" "$(cat "$selfroot/.orchid/sentinel")" \
  "and uncommitted durable .orchid state survives the declined refresh too"

# ===========================================================================
# 10b -- a merge that moves no kernel file says NOTHING, dirty tree or not
# ===========================================================================
# The other half of check 10, and what keeps that warning worth reading. The
# merge decides whether to warn from orchid_kernel_clean, which calls this
# checkout dirty for as long as the operator's edit sits in it -- whether or
# not the merge touched one byte the launcher executes. Left at that, every
# merge of a docs, config or test change announces that it left this checkout
# stale, when it left it exactly current; and an operator who has been told
# that four times skips the fifth, which is the one where their edit really is
# why every verb now refuses. That is precisely how the ADVISORY version of
# this whole guard failed, so it may not be rebuilt inside the fix.
#
# Same dirty kernel as check 10, and a candidate that changes a tracked file
# OUTSIDE ORCHID_KERNEL_PATHS. Nothing goes stale, nothing is said, and verbs
# keep running.
#
# Check 10 left this checkout stale on purpose, so clear it first. That is the
# test's own housekeeping and not a documented remedy -- the edit discarded
# here is one this file made twenty lines up.
git -C "$selfroot" checkout -q HEAD -- "${KERNEL[@]}"
rc=0
"$ORCHID_BIN" task show TS2 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "test fixture: the checkout is current again before 10b begins"

mkdir -p "$selfroot/docs"
printf 'v1 -- a tracked file the launcher never executes\n' > "$selfroot/docs/notes.md"
git -C "$selfroot" add docs/notes.md
git -C "$selfroot" commit -q -m "self-hosted fixture: a tracked file outside the kernel"
self_base3="$(git -C "$selfroot" rev-parse orchid/integration)"

git -C "$selfroot" checkout -q -b task/TS3
printf 'v2 -- still not executed\n' > "$selfroot/docs/notes.md"
git -C "$selfroot" add docs/notes.md
git -C "$selfroot" commit -q -m "self-hosted fixture: a change outside the kernel"
self_cand3="$(git -C "$selfroot" rev-parse HEAD)"
git -C "$selfroot" checkout -q orchid/integration

"$ORCHID_BIN" task create TS3 "self-hosted merge that moves no kernel file" >/dev/null
"$ORCHID_BIN" task set TS3 base_sha "$self_base3"
"$ORCHID_BIN" task set TS3 candidate_sha "$self_cand3"
"$ORCHID_BIN" task set TS3 verification_commands "true"
"$ORCHID_BIN" task advance TS3 implementing
"$ORCHID_BIN" task advance TS3 testing
git -C "$selfroot" checkout -q task/TS3
"$ORCHID_BIN" verify TS3 >/dev/null
git -C "$selfroot" checkout -q orchid/integration
"$ORCHID_BIN" task advance TS3 reviewing
plant_reviewer_envelope TS3
"$ORCHID_BIN" task advance TS3 arbitrating --reason "single reviewer approved"
"$ORCHID_BIN" task advance TS3 merging --reason "approved for merge"

# The operator's kernel edit, made after the branch round-trips for the reason
# check 10 gives: `git checkout` refuses to move across a change to the file.
printf 'operator kernel edit, and no business of this merge\n' \
  >> "$selfroot/templates/probe-mutable.txt"
worktree_before3="$(cat "$selfroot/templates/probe-mutable.txt")"

rc=0
out="$("$ORCHID_BIN" merge TS3 2>&1)" || rc=$?
assert_eq 0 "$rc" "a merge that moves no kernel file completes over a dirty kernel"
assert_match "^merged TS3: orchid/integration -> " "$out" "it reports the merge"
if grep -q "kernel files were already modified before the merge" <<<"$out"; then
  fail "the merge warned it had left this checkout stale when nothing the launcher executes had moved"
fi
if grep -q "^refreshed " <<<"$out"; then
  fail "the merge claimed a refresh of a kernel it was never allowed to write"
fi
rc=0
"$ORCHID_BIN" task show TS3 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" \
  "and the checkout is not stale — nothing needed refreshing, which is why nothing needed saying"
assert_eq "$worktree_before3" "$(cat "$selfroot/templates/probe-mutable.txt")" \
  "the operator's kernel edit is exactly as they left it"

# ===========================================================================
# 11 -- the guard runs FIRST of everything, so it may not spend a subprocess
# ===========================================================================
# This refusal is evaluated at SOURCE time in lib/common.sh, which puts it
# ahead of every verb's own code -- and therefore ahead of lib/trust.sh's
# unattended-trust gate, whose whole premise is that orchid touches NO
# repository, in NO way, until an acknowledgement for it has been found and
# the Git-version refusal has cleared. Spawning git IS touching, and a
# source-time spawn lands in front of that lookup however the gate itself is
# written; tests/test_unattended_trust.sh fences the same boundary from the
# other side (its fast-guard shim fails on ANY git or mktemp before an
# acknowledgement). So the branch half of the guard is answered from Git's
# own on-disk HEAD and spawns NO git, and the content half -- the one that
# does need git -- is reachable only for a checkout parked on the integration
# branch, which is orchid's own root and never a repository a run was pointed
# at.
#
# What is fenced here is git, exactly, and not "subprocesses" in general: a
# root that HAS a branch still pays config_get's tr/sed/grep/tail/cut to learn
# the integration branch's name, and those read config FILES rather than any
# repository. Touching a repository ahead of its acknowledgement is the thing
# the unattended gate forbids, and git is the only thing here that would.
#
# The two roots below are the two on-disk layouts Git writes, deliberately
# split across the two outcomes so both are exercised: an ordinary checkout
# with a .git DIRECTORY on the zero-subprocess path, and a linked worktree
# with a .git FILE holding a "gitdir:" pointer on the refusal path. Getting
# the pointer form wrong would be invisible to a directory-only fixture, and
# a linked worktree is how every task checkout in a real run is made.
guard_bin="$WORK/guard-bin"
guard_log="$WORK/guard-git.log"
mkdir -p "$guard_bin"
guard_real_git="$(command -v git)"
cat > "$guard_bin/git" <<'SHIM'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$ORCHID_TEST_GUARD_LOG"
exec "$ORCHID_TEST_REAL_GIT" "$@"
SHIM
chmod +x "$guard_bin/git"

# source_guarded <root> -- source the library under test the way a verb does,
# with the logging git ahead of the real one on PATH. Leaves the status in
# $rc and every git the source consumed in $guard_log.
source_guarded() {
  : > "$guard_log"
  rc=0
  PATH="$guard_bin:$PATH" HOME="$MACHINE_HOME" \
    ORCHID_TEST_GUARD_LOG="$guard_log" ORCHID_TEST_REAL_GIT="$guard_real_git" \
    ORCHID_ROOT="$1" \
    /bin/bash -c 'set -euo pipefail; source "$ORCHID_ROOT/lib/common.sh"' \
    >/dev/null 2>&1 || rc=$?
}

guardhub="$WORK/guard-hub"
make_root "$guardhub" main
git -C "$guardhub" branch orchid/integration
guardstale="$WORK/guard-staleroot"
git -C "$guardhub" worktree add -q "$guardstale" orchid/integration
guardelse="$WORK/guard-elsewhere"
git -C "$guardhub" worktree add -q --detach "$guardelse" orchid/integration
printf 'merged kernel change\n' >> "$guardelse/templates/.keep"
git -C "$guardelse" add -A
git -C "$guardelse" commit -q -m "fixture: kernel v2 (the merged fix)"
git -C "$guardhub" update-ref refs/heads/orchid/integration \
  "$(git -C "$guardelse" rev-parse HEAD)"

# The development root is DIRTY in the kernel on purpose. A guard that reached
# for its content comparison before establishing the branch would have plenty
# to find here, so an empty log means the branch test really did come first
# and really was answered without git -- not merely that there was nothing to
# compare.
printf 'operator edit\n' >> "$guardhub/templates/.keep"

source_guarded "$guardhub"
assert_eq 0 "$rc" "a dirty development root sources the library without refusing"
[ ! -s "$guard_log" ] \
  || fail "the stale-root guard spent a Git subprocess ahead of the unattended-trust gate ($(tr '\n' ' ' < "$guard_log"))"

# ...and giving that up bought nothing: the refusal still fires, off a linked
# worktree whose branch is only knowable through its gitdir pointer.
source_guarded "$guardstale"
assert_eq 1 "$rc" \
  "a stale linked-worktree root is still refused, with its branch read from the gitdir pointer"
grep -q '^git ' "$guard_log" \
  || fail "the refusal is allowed its content comparison and must actually make one"

# ===========================================================================
# 12 -- a merge that changes ONLY PROTOCOL.md is stale like any other
# ===========================================================================
# PROTOCOL.md is not code and is executed all the same: skills/orchid*/SKILL.md
# carry no procedure of their own, they tell the driving engine to read
# $ORCHID_ROOT/PROTOCOL.md and follow the section they name. So the protocol
# on disk in this checkout IS the instruction stream a tick runs, and a
# protocol-only merge left out of the kernel pathspec reproduces this whole
# task's failure class on the one file that defines the procedure: nothing
# refuses, nothing refreshes, and the run goes on executing the PRE-MERGE
# procedure while the merge reports success.
#
# $root is back at the branch head after check 8b, so this advance is the only
# thing between them.
printf 'PROTOCOL v2: the merged procedure\n' > "$elsewhere/PROTOCOL.md"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "fixture: kernel v5 (PROTOCOL.md only)"
git -C "$hub" update-ref refs/heads/orchid/integration "$(git -C "$elsewhere" rev-parse HEAD)"

assert_eq "PROTOCOL v1" "$(cat "$root/PROTOCOL.md")" \
  "test fixture: the stale checkout really is still carrying the pre-merge procedure"
run_version "$root"
assert_eq 1 "$rc" "a merge that changes ONLY PROTOCOL.md is a refusal, not a silent pre-merge run"
assert_match "PROTOCOL.md" "$out" "and the refusal names the protocol file as the path it observed"
assert_no_lossy_command "the protocol-only refusal"

rc=0
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_refresh_kernel "$root" ) || rc=$?
assert_eq 0 "$rc" "the refresh handles a plain file in the pathspec like any directory"
assert_eq "PROTOCOL v2: the merged procedure" "$(cat "$root/PROTOCOL.md")" \
  "and the checkout now carries the merged procedure"
run_version "$root"
assert_eq 0 "$rc" "the refusal clears once the protocol is current"

# ===========================================================================
# 13 -- an ordinary dirty kernel edit in the SELF-HOSTED checkout still runs
# ===========================================================================
# The acceptance criterion says a mismatch check that refused on any
# uncommitted edit would make the tool unusable. The first two rounds of this
# guard satisfied that by exempting every branch but the integration one --
# which exempts every checkout except the only one the guard ever fires in.
# orchid is developed in a checkout of its own integration branch, so "edit
# lib/common.sh, run orchid" was precisely what it refused, and the escape
# hatch it offered for the tool's own development loop was an environment
# variable on every command.
#
# The fix is to compare the INDEX rather than the working tree. `git
# update-ref` moves the branch without touching either, so the index left
# describing the commit the branch moved off IS the record of the fall behind;
# an operator editing files leaves the index alone. This check is the dirty
# development case the criterion names, run where it actually bites.
#
# $root is clean and current after check 12, so the ONLY difference below is
# the operator's own, and it is unstaged.
printf 'echo "operator hand-edit"\n' >> "$root/libexec/orchid-version"
handedit_before="$(cat "$root/libexec/orchid-version")"
run_version "$root"
assert_eq 0 "$rc" \
  "an uncommitted kernel edit in the integration checkout must RUN -- it is how orchid is developed"
assert_eq "$handedit_before" "$(cat "$root/libexec/orchid-version")" \
  "and nothing went near the edit"

# ===========================================================================
# 13b -- a STAGED kernel edit refuses, and is never prescribed away
# ===========================================================================
# `git add` is what makes an edit indistinguishable from a branch advance:
# both leave an index that does not match HEAD, and no comparison available
# inside this checkout separates them. The round before this one classified
# exactly this state as "behind" and prescribed `git checkout HEAD -- <kernel
# paths>` for it -- which would have overwritten the staged blob with HEAD's
# copy. That is the defect, and it is the second time it appeared: the round
# before THAT did the same to an unstaged edit.
#
# So the requirement is not "classify this state correctly". It is: report
# what was seen, name the paths, and print nothing that writes. Both halves
# are asserted, and the second one as a class (assert_no_lossy_command), so a
# future round cannot satisfy it by changing which command it prescribes.
git -C "$root" add -- libexec/orchid-version
run_version "$root"
assert_eq 1 "$rc" "a STAGED kernel edit on the integration branch refuses"
assert_match "INDEX does not match HEAD" "$out" \
  "and reports the observation it can actually make"
assert_match "libexec/orchid-version" "$out" \
  "naming the file whose staged copy exists nowhere else"
assert_no_lossy_command "against a staged edit, the refusal"
assert_match "not a diagnosis" "$out" \
  "saying in as many words that it is not claiming to know the cause"
assert_match "git add" "$out" \
  "and naming the staged edit as one of the two things that produce this state"
# The state where the refusal is hardest to read as anything but a broken tool:
# nothing is stale, the operator staged that edit on purpose, and orchid stops
# anyway. It has to SAY so -- that doctor and status are stopped too, and why --
# or the reasonable response to a verb that looks broken is to route around it.
assert_match "doctor' and 'status' included" "$out" \
  "and saying in the refusal itself that doctor and status are stopped too"
assert_match "protecting you rather than orchid broken" "$out" \
  "naming it as protection, which is the only thing that distinguishes it from a bug from where the operator stands"
assert_eq "$handedit_before" "$(cat "$root/libexec/orchid-version")" \
  "refusing is read-only: the edit it refused over is untouched on disk"
assert_eq "$handedit_before" "$(git -C "$root" show ":libexec/orchid-version")" \
  "and untouched in the index, which is where its only copy of that change lives"

# EVERY verb, not a list of them, and this state is where that is argued
# hardest: a staged kernel edit refuses `doctor` and `status` too, which are
# the verbs an operator in this state wants most. They are in anyway, and the
# reason is not symmetry -- a diagnosis read out of this checkout would be
# produced BY the stale code, so `doctor` here runs the checks the pre-merge
# tree carries and can pass a checkout the merged one fails. The refusal
# already reports more than `doctor` would (branch, staged paths, unstaged
# context, two read-only commands), and an exemption list is precisely how
# the advisory version of this check failed. The exemption is
# ORCHID_ALLOW_STALE_ROOT=1, taken per invocation once the operator has read
# what was observed, so the staleness of what they are about to read is
# explicit rather than silent (docs/troubleshooting.md, "Why doctor and
# status refuse too").
#
# Mechanically there is no list to get wrong: the refusal fires when
# lib/common.sh is SOURCED, and every verb sources it. A second verb stands
# in for all of them here, so an exemption added later has to break this.
rc=0
# Spelled `''` rather than left bare: an empty value before a line continuation
# is ambiguous to a reader and to a linter alike (SC1007 -- is the next line a
# value or the command?). The variable is set to empty rather than simply
# omitted because this suite must not inherit an operator's own
# ORCHID_ALLOW_STALE_ROOT=1 and quietly stop testing the refusal.
second_out="$(HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT='' \
  "$root/bin/orchid" fresh 2>&1)" || rc=$?
assert_eq 1 "$rc" "a second, unrelated verb refuses in the same state -- the refusal is not per-verb"
assert_match "refusing to run" "$second_out" "and refuses with the same report"
rc=0
second_out="$(HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1 \
  "$root/bin/orchid" fresh 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "and the per-invocation override is what reads state out of a checkout in this state"
assert_match "fresh: merged verb" "$second_out" "having actually run the verb"

# The same staged edit, now with the branch advanced under it as well -- both
# things are true at once, which is precisely what check 10's merge produces.
# The refusal carries the unstaged half as context and still prescribes
# nothing.
printf 'echo "merged line"\n' >> "$elsewhere/libexec/orchid-fresh"
git -C "$elsewhere" add -A
git -C "$elsewhere" commit -q -m "fixture: kernel v6 (advance under a staged edit)"
git -C "$hub" update-ref refs/heads/orchid/integration "$(git -C "$elsewhere" rev-parse HEAD)"
printf 'echo "and an unstaged one on top"\n' >> "$root/libexec/orchid-version"
both_before="$(cat "$root/libexec/orchid-version")"

run_version "$root"
assert_eq 1 "$rc" "a stale checkout that also carries staged and unstaged edits refuses"
assert_match "ALSO OBSERVED" "$out" \
  "and reports the unstaged modification as context rather than as a cause"
assert_match "libexec/orchid-version" "$out" "still naming the file at risk"
assert_no_lossy_command "with every state true at once, the refusal"
assert_eq "$both_before" "$(cat "$root/libexec/orchid-version")" \
  "and both layers of the operator's work survive the refusal"

# ===========================================================================
# 14 -- `orchid merge`'s advance-then-refresh window REFUSES, and says why
# ===========================================================================
# `orchid merge` moves the ref and then restores this checkout, and between
# those two steps the index legitimately does not match HEAD -- the exact
# thing the refusal reports. The merge shields its own children with
# ORCHID_ALLOW_STALE_ROOT=1, but nothing reaches the OTHER processes started
# from the same root in that window: an operator's `orchid status`, a
# heartbeat, a notify hook.
#
# An earlier round let those processes RUN for the duration, on the reasoning
# that the condition was already being repaired and the window was short. That
# was this task's own defect wearing the fix's clothes: during the window this
# working tree really does hold the pre-merge kernel, so every verb allowed
# through executed exactly the stale code L018 is about, and "short" is not a
# property the executed code has -- a tick that starts in the window runs a
# whole pass of it. Waiting instead of running is no better: by the time this
# guard is reached the process has already sourced its libraries off the
# pre-merge tree, so sleeping until the restore lands leaves it running the
# old bytes it is already holding.
#
# So the window is closed to EXECUTION, which is the only thing that had to
# close: the verb refuses either way, and the marker decides only WHICH
# refusal it gets. That distinction is worth a file because the two messages
# send an operator to opposite places -- "retry in a moment" versus a report
# about their own staged bytes -- and it earns a distinct exit status (75,
# EX_TEMPFAIL) because the callers most affected are heartbeats and hooks,
# which have to tell "retry" from "a human must look at this".
#
# The negative cases below are the whole of why a marker may be believed at
# all. It carries the identity lock_acquire uses -- pid, start time, host --
# because a bare PID cannot survive its own writer: an EXIT trap does not run
# on SIGKILL, so a killed merge leaves the file behind, and the number is
# eventually reissued to something unrelated. Under the old tolerance that
# silently disarmed the whole refusal; here it would tell an operator to keep
# retrying a merge that died hours ago. Every failure -- recycled PID, foreign
# host, dead PID, the old one-line format, a mangled file, no file -- falls
# through to the full report. $root is stale from check 13b and refuses
# without a marker.
marker="$root/.orchid/runtime/kernel-refresh"
mkdir -p "$root/.orchid/runtime"

# The identity fields are spelled out here rather than sourced from
# lib/common.sh, for the same reason ORCHID_KERNEL_PATHS is: a silent change
# to what the marker records has to be made twice and seen in review. This
# shell is the stand-in for the live merge -- its PID is alive by definition
# and its start time is whatever `ps` says right now.
live_start="$(ps -o lstart= -p "$$" 2>/dev/null | tr -d ' ')"
live_host="$(hostname)"
[ -n "$live_start" ] || fail "test fixture: cannot read this shell's process start time"
[ -n "$live_host" ] || fail "test fixture: cannot read this machine's hostname"

printf '%s\n%s\n%s\n' "$$" "$live_start" "$live_host" > "$marker"
run_version "$root"
assert_eq 75 "$rc" \
  "a verb from a root whose merge is mid-refresh refuses with the temporary-failure status, not the operator-must-look one"
assert_match "restoring this checkout's kernel files to it right now" "$out" \
  "and says a repair is in flight rather than reporting an index the operator has to judge"
assert_match "Retry in a moment" "$out" "telling the caller the state clears itself"
[ "${out#*adapter: pre-merge}" = "$out" ] \
  || fail "the mid-refresh window let a verb EXECUTE the pre-merge tree -- the failure this guard exists for"
assert_no_lossy_command "the mid-refresh refusal"

# Writer and reader, round-tripped in ONE process, because a marker whose
# format the two halves disagree about is invisible from either side alone:
# `orchid merge` would open a window nothing believes, and every verb in it
# would get the full report about a checkout that is mid-repair. The same
# process that opens it must recognise it.
rc=0
HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1 /bin/bash -c '
  set -euo pipefail
  source "$1/lib/common.sh"
  orchid_kernel_refresh_open "$2" || exit 3
  _orchid_kernel_refresh_inflight "$2" || exit 4' _ "$REPO_ROOT" "$root" || rc=$?
assert_eq 0 "$rc" \
  "the marker orchid_kernel_refresh_open writes is the marker _orchid_kernel_refresh_inflight believes"

# ...and that window shut when its process did, with no reaper anywhere: the
# file is still on disk, naming a PID that has now exited.
[ -e "$marker" ] || fail "test fixture: the round-trip left no marker to go stale"
run_version "$root"
assert_eq 1 "$rc" \
  "a real marker outlives the process that wrote it and stops being believed the moment it exits"

# PID REUSE, which is the case a bare PID cannot see: the number is alive --
# it is this very shell -- but it is not the process that wrote the marker.
printf '%s\n%s\n%s\n' "$$" "ThuJan101:00:001970" "$live_host" > "$marker"
run_version "$root"
assert_eq 1 "$rc" \
  "a live PID that is not the process that opened the window cannot impersonate it"
assert_match "INDEX does not match HEAD" "$out" \
  "and the operator gets the full report instead of being told to retry forever"

# The same, one field over: a runtime directory that turns out to be shared
# must not let another host's PID answer for this one's.
printf '%s\n%s\n%s\n' "$$" "$live_start" "not-this-host" > "$marker"
run_version "$root"
assert_eq 1 "$rc" "a marker written on another host is not this host's merge"

# The format this replaces, still naming a live PID. It must read as "cannot
# establish", or an orchid mid-upgrade would believe its predecessor's markers.
printf '%s\n' "$$" > "$marker"
run_version "$root"
assert_eq 1 "$rc" "the old bare-PID marker format is not believed"

# A PID this shell started and reaped: certainly dead, and certainly not
# recycled yet. This is the merge that was killed mid-window.
( exit 0 ) &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\n%s\n%s\n' "$dead_pid" "$live_start" "$live_host" > "$marker"
run_version "$root"
assert_eq 1 "$rc" \
  "a marker whose merge is gone claims nothing -- the full report fires, which is the safe direction"

printf 'not-a-pid\nx\ny\n' > "$marker"
run_version "$root"
assert_eq 1 "$rc" "a truncated or mangled marker fails closed too"

rm -f "$marker"
run_version "$root"
assert_eq 1 "$rc" "and with no marker at all the refusal is exactly as it was"

# The real merges from checks 9 and 10 both took this path -- one refreshing,
# one declining to -- and neither may leave the window standing open behind
# it. Nothing would be let through if they did (the refusal no longer depends
# on the marker), but until that process died every verb from the checkout
# would be told to retry a repair that had already finished or been declined,
# which in check 10's case is a wait that would never end.
[ ! -e "$selfroot/.orchid/runtime/kernel-refresh" ] \
  || fail "orchid merge left its advance-then-refresh window open after exiting"

# ===========================================================================
# 15 -- a refresh KILLED mid-flight leaves the guard REFUSING
# ===========================================================================
# The window inside check 14's window. That one covers what other processes
# are told while the restore is happening; this is what they are told when it
# never finishes -- a SIGKILL, a full disk, a lid closing. The marker cannot
# answer for that case by construction: it is believed only while its writer
# is alive, so it stops speaking at the exact instant the repair stops
# happening. What is left standing between a half-done restore and a run
# executing the pre-merge tree is the refusal itself.
#
# It stands only if the restore never makes this checkout LOOK current before
# it IS current. The guard reads the INDEX, so the index has to be the last
# thing each path gets, after its working tree already carries HEAD's bytes.
# The version this replaces reset the index first and wrote the file second:
# killed in between, it left a CURRENT INDEX over PRE-MERGE CODE, which the
# guard reads as healthy and lets every verb run -- L018 reproduced inside the
# fix for L018, and reachable by nothing more exotic than ^C.
#
# ONE kernel path moves, deliberately: with two, a checkout could refuse over
# the second while the first was already lying, and this check would pass over
# the very defect it exists for.
crashhub="$WORK/crash-hub"
make_root "$crashhub" main
git -C "$crashhub" branch orchid/integration
crashroot="$WORK/crash-root"
git -C "$crashhub" worktree add -q "$crashroot" orchid/integration
crashelse="$WORK/crash-elsewhere"
git -C "$crashhub" worktree add -q --detach "$crashelse" orchid/integration
cat > "$crashelse/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "adapter: post-merge"
VERB
git -C "$crashelse" add -A
git -C "$crashelse" commit -q -m "fixture: kernel v2 (one path, so one write to interrupt)"
git -C "$crashhub" update-ref refs/heads/orchid/integration \
  "$(git -C "$crashelse" rev-parse HEAD)"

run_version "$crashroot"
assert_eq 1 "$rc" \
  "test fixture: the advance leaves this checkout refusing before any repair starts"

# The interruption, in a process of its own so that it is a real SIGKILL of
# the process running the refresh rather than a `return` the function could
# tidy up after.
#
# The wrapper is deliberately blind to WHICH git subcommand it is wrapping: it
# compares this checkout's tracked state before and after every git the
# refresh runs and fires the moment anything has changed, so it interrupts the
# first write whatever the implementation chooses to make it with, and cannot
# be satisfied by renaming a step. `-uno` keeps a temporary file -- untracked
# by definition -- from being mistaken for that write.
cat > "$WORK/refresh-crash.sh" <<'CRASH'
#!/usr/bin/env bash
set -uo pipefail
root="$1"
source "$2/lib/common.sh"
before="$(command git -C "$root" status --porcelain -uno 2>/dev/null || true)"
git() {
  local grc=0
  command git "$@" || grc=$?
  if [ "$(command git -C "$root" status --porcelain -uno 2>/dev/null || true)" != "$before" ]; then
    # SIGKILL, not `exit`: no trap runs, nothing is cleaned up, and it reaches
    # this process even from inside a command substitution.
    kill -9 $$
  fi
  return "$grc"
}
orchid_refresh_kernel "$root"
CRASH

rc=0
HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1 \
  /bin/bash "$WORK/refresh-crash.sh" "$crashroot" "$REPO_ROOT" >/dev/null 2>&1 || rc=$?
[ "$rc" -ge 128 ] \
  || fail "test fixture: the refresh was never interrupted (exit $rc) -- nothing below is being tested"

run_version "$crashroot"
assert_eq 1 "$rc" \
  "a refresh killed before it finished leaves the guard REFUSING -- an index that says current over a tree nobody finished repairing is exactly L018"
assert_match "INDEX does not match HEAD" "$out" \
  "with the full report, since the merge that would have been repairing it is gone"
[ "${out#*adapter: pre-merge}" = "$out" ] \
  || fail "the interrupted refresh let a verb EXECUTE the pre-merge tree"
assert_no_lossy_command "after an interrupted refresh, the refusal"

# And the state it left is one a refresh can finish. It is reached only
# through the index, which is why the drift list is not the working tree's
# alone: the file this checkout executes is already correct here, so a
# working-tree comparison finds nothing to do and would leave the refusal
# standing for ever.
rc=0
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_refresh_kernel "$crashroot" ) || rc=$?
assert_eq 0 "$rc" "a second refresh finishes the job the killed one left half done"
run_version "$crashroot"
assert_eq 0 "$rc" "and the refusal clears"
assert_match "adapter: post-merge" "$out" "with the merged kernel the one that executes"

# The same interruption, one path shape over, and the one the harness above
# cannot reach (an added file is untracked, so writing it changes no tracked
# state to trigger on). A killed refresh leaves an UNTRACKED file at a path
# the branch ADDED, holding HEAD's own bytes: written, index entry not yet.
# That is byte-for-byte the shape 8b declines to overwrite -- and declining
# HERE would leave a refusal nothing could clear, since the working tree is
# already right and only the index keeps the refusal alive. Built by hand
# rather than by killing a second process, because it is a state, not a race.
cat > "$crashelse/libexec/orchid-arrived" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "arrived: the merged verb"
VERB
chmod +x "$crashelse/libexec/orchid-arrived"
git -C "$crashelse" add -A
git -C "$crashelse" commit -q -m "fixture: kernel v3 (the branch adds a verb)"
git -C "$crashhub" update-ref refs/heads/orchid/integration \
  "$(git -C "$crashelse" rev-parse HEAD)"
git -C "$crashroot" cat-file blob \
  "$(git -C "$crashroot" rev-parse "HEAD:libexec/orchid-arrived")" \
  > "$crashroot/libexec/orchid-arrived"

run_version "$crashroot"
assert_eq 1 "$rc" \
  "a path written but not yet in the index is still a refusal, which is what makes the file safe to write through"
rc=0
( export HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
  source "$REPO_ROOT/lib/common.sh"
  orchid_refresh_kernel "$crashroot" ) || rc=$?
assert_eq 0 "$rc" \
  "and the refresh finishes it instead of declining over the file it wrote itself"
run_version "$crashroot"
assert_eq 0 "$rc" "clearing that refusal too"
assert_match "arrived: the merged verb" \
  "$(HOME="$MACHINE_HOME" "$crashroot/bin/orchid" arrived 2>&1)" \
  "with the verb executable — the one thing a half-done write does not leave behind"
