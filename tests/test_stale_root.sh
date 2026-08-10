#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# ---------------------------------------------------------------------------
# T006 / lesson L018: orchid refuses to run FROM a checkout of the integration
# branch whose kernel files have fallen behind that branch.
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
#   * uncommitted durable `.orchid/` state survives the refusal, the
#     documented remedy, and a branch-side advance of that same state, and is
#     never itself a reason to refuse (checks 1-4).
# ---------------------------------------------------------------------------

# make_root <dir> <branch> -- a minimal but REAL orchid installation root: the
# shipped dispatcher and the shipped lib/common.sh under test, plus one
# `version` verb whose only job is to report WHICH copy of itself just ran.
# Committed on <branch> alongside one tracked `.orchid/journal.md` standing in
# for durable run state. The branch is pinned explicitly so the fixture never
# depends on the machine's `init.defaultBranch`.
make_root() {
  local dir="$1" branch="$2"
  mkdir -p "$dir/bin" "$dir/lib" "$dir/libexec" "$dir/.orchid"
  cp "$REPO_ROOT/bin/orchid" "$dir/bin/orchid"
  cp "$REPO_ROOT/lib/common.sh" "$dir/lib/common.sh"
  cat > "$dir/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "adapter: pre-merge"
VERB
  chmod +x "$dir/bin/orchid" "$dir/libexec/orchid-version"
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

run_version "$root"
assert_eq 1 "$rc" "a stale integration checkout refuses to run, it does not merely warn"
assert_match "refusing to run: the checkout orchid itself runs from" "$out" \
  "the refusal says the ROOT is what is stale, not the managed repo"
assert_match "orchid/integration" "$out" "the refusal names the branch it is parked on"
assert_match "git checkout HEAD -- \. ':\(exclude\)\.orchid'" "$out" \
  "the refusal names the .orchid-preserving refresh, never a bare one"
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
# 2 -- the documented remedy clears it, and costs no durable state
# ===========================================================================
git -C "$root" checkout HEAD -- . ':(exclude).orchid'
assert_eq "$journal_before" "$(cat "$root/.orchid/journal.md")" \
  "the documented refresh preserves uncommitted durable .orchid state"
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
