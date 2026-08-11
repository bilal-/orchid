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
#     however far the working tree has drifted from HEAD (checks 5 and 6);
#     and on the integration branch itself for everything that is not kernel
#     code, which is what keeps the `edit orchid.config` -> `orchid config
#     commit` path working (check 4).
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
# uncommitted kernel edit and then has to SAY so, because the refusal they
# meet next describes a cause that is not the one in front of them.
# ---------------------------------------------------------------------------

# The one list the guard, the refresh and the documented remedy all use. Kept
# here literally, NOT sourced from lib/common.sh, so that a silent edit to
# ORCHID_KERNEL_PATHS has to be made in two places and is seen in review.
KERNEL=(bin lib libexec runners plugins roles skills templates)

# make_root <dir> <branch> -- a minimal but REAL orchid installation root: the
# shipped dispatcher and the shipped lib/common.sh under test, plus one
# `version` verb whose only job is to report WHICH copy of itself just ran,
# and one `gone` verb that a later commit deletes. Every kernel directory
# exists, so the remedy the refusal prints can be run against it verbatim.
# Committed on <branch> alongside one tracked `.orchid/journal.md` standing in
# for durable run state and one tracked `orchid.config`. The branch is pinned
# explicitly so the fixture never depends on the machine's
# `init.defaultBranch`.
make_root() {
  local dir="$1" branch="$2" d
  for d in "${KERNEL[@]}"; do mkdir -p "$dir/$d"; printf 'fixture\n' > "$dir/$d/.keep"; done
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
assert_match "checkout HEAD -- bin lib libexec runners plugins roles skills templates" "$out" \
  "the refusal names the kernel-scoped refresh"
if grep -qE "checkout HEAD -- \." <<<"$out"; then
  fail "the refusal must never print a whole-tree refresh: that restores the uncommitted orchid.config the design promises to leave alone"
fi
assert_match "ORCHID_ALLOW_STALE_ROOT=1" "$out" "the refusal names its own override"
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
# 2 -- the documented remedy clears it, and costs no uncommitted state
# ===========================================================================
git -C "$root" checkout HEAD -- "${KERNEL[@]}"
assert_eq "$journal_before" "$(cat "$root/.orchid/journal.md")" \
  "the documented refresh preserves uncommitted durable .orchid state"
assert_eq "$config_before" "$(cat "$root/orchid.config")" \
  "the documented refresh preserves an uncommitted orchid.config edit"
run_version "$root"
assert_eq 0 "$rc" "the refusal clears after the documented refresh"
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
( HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
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
( HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
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
( HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
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
( HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT=1
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
# refusal whose message names the general cause ("advanced without this
# working tree being refreshed") and not the specific one -- their own edit --
# and the obvious reading of that message is to run the refresh that discards
# it.
#
# The edit is STAGED and reverted on disk on purpose. That is the one shape
# that gets past the guard (which compares the working tree) while
# orchid_kernel_clean's `--cached` half still, correctly, calls the checkout
# dirty -- so the merge runs at all and then has to decide, which is the whole
# point of the check. It is also the shape most likely to be quietly lost.
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

# Staged only, and made AFTER the branch round-trip above: `git checkout` would
# have refused to move across a staged change to the same file.
printf 'operator staged kernel edit\n' >> "$selfroot/templates/probe-mutable.txt"
git -C "$selfroot" add templates/probe-mutable.txt
printf 'v2\n' > "$selfroot/templates/probe-mutable.txt"
staged_before="$(git -C "$selfroot" diff --cached --name-only HEAD)"
assert_match "templates/probe-mutable.txt" "$staged_before" \
  "test fixture: the kernel edit really is staged"

rc=0
"$ORCHID_BIN" task show TS2 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" \
  "a kernel edit that is staged but not on disk is not itself a refusal — the guard compares the working tree"

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
if grep -q "^refreshed " <<<"$out"; then
  fail "the merge claimed a refresh it must not have performed"
fi
assert_eq "$staged_before" "$(git -C "$selfroot" diff --cached --name-only HEAD)" \
  "the operator's staged kernel edit is still staged — the merge discarded nothing"
assert_eq v2 "$(cat "$selfroot/templates/probe-mutable.txt")" \
  "and their working tree is exactly as they left it"

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
# own on-disk HEAD and costs nothing, and the content half -- the one that
# does need git -- is reachable only for a checkout parked on the integration
# branch, which is orchid's own root and never a repository a run was pointed
# at.
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
