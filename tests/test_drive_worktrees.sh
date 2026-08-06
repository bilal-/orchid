#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# Worktree dispatch must be idempotent and crash-safe.
#
# The hazard is concrete: `git worktree add` and `orchid task set <id>
# worktree <path>` are two steps, and a pass can die between them. Resuming
# must ADOPT the orphan it already created, never create a second worktree for
# the same task -- and it must refuse anything it cannot prove belongs to this
# task, this branch and this repository, rather than reusing it hopefully.
#
# lib/drive.sh's `drive_worktree_plan` is the whole decision, so it is tested
# directly, case by case; one real `orchid drive` pass at the end proves the
# driver actually honours the plan it is given.
#
# RED before this task: lib/drive.sh does not exist.

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/drive.sh"

REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$REPO" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

WORKP="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root"; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"

plan_action() { drive_worktree_plan "$REPO" "$1" | cut -f1; }
plan_detail() { drive_worktree_plan "$REPO" "$1" | cut -f2-; }

# ===========================================================================
# 1 -- the conventional path is deterministic: a SIBLING of the repository
# named <repo-basename>-<task-id>. Deterministic is what makes a crashed
# pass able to find the orphan it already created; a sibling (rather than a
# nested directory) is what keeps a task checkout out of the integration
# checkout's own tree.
# ===========================================================================
"$ORCHID_BIN" task create W1 "worktree subject" >/dev/null
assert_eq "$WORKP/repo-W1" "$(drive_worktree_path "$REPO" W1)" \
  "the dispatch path is the deterministic <repo>-<task> sibling"

assert_eq create "$(plan_action W1)" "nothing exists yet, so the plan is to create"
assert_eq "$WORKP/repo-W1" "$(plan_detail W1)" "the create plan names the conventional path"

# ===========================================================================
# 2 -- ADOPT: a pass died between `git worktree add` and `task set worktree`.
# The orphan is an exact match on every fact that matters, so it is adopted,
# never recreated -- and no duplicate is ever registered for that branch.
# ===========================================================================
git worktree add -q "$WORKP/repo-W1" -b task/W1 "$HEAD_SHA"
assert_eq adopt "$(plan_action W1)" "an exact orphan at the conventional path is adopted"
assert_eq "$WORKP/repo-W1" "$(plan_detail W1)" "the adopt plan names the orphan it found"

# ===========================================================================
# 3 -- REUSE: once the field is recorded, the same worktree is reused as long
# as path, branch, git-common-dir and task all still agree.
# ===========================================================================
"$ORCHID_BIN" task set W1 worktree "$WORKP/repo-W1" >/dev/null
assert_eq reuse "$(plan_action W1)" "a registered, recorded, branch-matching worktree is reused"
assert_eq "$WORKP/repo-W1" "$(plan_detail W1)" "the reuse plan names the recorded path"

# ===========================================================================
# 4 -- REFUSE: a recorded path that has vanished. Silently re-creating it
# would discard whatever work was in it; that is an operator's call.
# ===========================================================================
"$ORCHID_BIN" task create W2 "vanished worktree" >/dev/null
"$ORCHID_BIN" task set W2 worktree "$WORKP/gone-W2" >/dev/null
assert_eq refuse "$(plan_action W2)" "a recorded worktree that does not exist is refused"
assert_match "does not exist" "$(plan_detail W2)" "the refusal says the recorded path is gone"

# ===========================================================================
# 5 -- REFUSE: a FOREIGN checkout sitting at the conventional path. Same
# path, different repository: the git-common-dir comparison is what catches
# it, not the path.
# ===========================================================================
"$ORCHID_BIN" task create W3 "foreign path" >/dev/null
mkdir -p "$WORKP/repo-W3"
( cd "$WORKP/repo-W3" && git init -q . && git commit -q --allow-empty -m foreign \
  && git branch -M task/W3 )
assert_eq refuse "$(plan_action W3)" "a foreign git checkout at the conventional path is refused"
assert_match "not a registered worktree of this repository" "$(plan_detail W3)" \
  "the refusal names the ownership problem, not a path problem"
rm -rf "$WORKP/repo-W3"

# A plain non-git directory at the conventional path is refused the same way.
mkdir -p "$WORKP/repo-W3"
printf 'not a checkout\n' > "$WORKP/repo-W3/stray.txt"
assert_eq refuse "$(plan_action W3)" "a plain directory at the conventional path is refused"
rm -rf "$WORKP/repo-W3"

# ===========================================================================
# 6 -- REFUSE: the task's branch is already checked out somewhere that is not
# the dispatch path. Creating a second worktree for it is impossible anyway;
# refusing with the actual location is what an operator can act on.
# ===========================================================================
"$ORCHID_BIN" task create W4 "branch elsewhere" >/dev/null
git worktree add -q "$WORKP/elsewhere-W4" -b task/W4 "$HEAD_SHA"
assert_eq refuse "$(plan_action W4)" "a branch already checked out elsewhere is refused"
assert_match "already checked out at $WORKP/elsewhere-W4" "$(plan_detail W4)" \
  "the refusal names where the branch actually is"

# ===========================================================================
# 7 -- REFUSE: a BRANCH MISMATCH at the conventional path. The directory is a
# genuine worktree of this repository, but it holds someone else's branch.
# ===========================================================================
"$ORCHID_BIN" task create W5 "branch mismatch" >/dev/null
git worktree add -q "$WORKP/repo-W5" -b other/branch "$HEAD_SHA"
assert_eq refuse "$(plan_action W5)" "a worktree of this repo holding a different branch is refused"
assert_match "has branch other/branch checked out, not task/W5" "$(plan_detail W5)" \
  "the refusal names both branches"

# ===========================================================================
# 8 -- REFUSE: a path another task already claims. A shared dispatch worktree
# would let two tasks commit onto each other's branch.
# ===========================================================================
"$ORCHID_BIN" task create W6 "claimed by another task" >/dev/null
"$ORCHID_BIN" task set W6 worktree "$WORKP/repo-W1" >/dev/null
assert_eq refuse "$(plan_action W6)" "a worktree another task already records is refused"
assert_match "already claimed by another task" "$(plan_detail W6)" "the refusal names the conflict"

# ===========================================================================
# 9 -- REFUSE: a task with no recorded branch has no identity to check
# against, so there is nothing safe to create or adopt.
# ===========================================================================
"$ORCHID_BIN" task create W7 "no branch" >/dev/null
"$ORCHID_BIN" task set W7 branch "" >/dev/null
assert_eq refuse "$(plan_action W7)" "a task with no branch is refused"
assert_match "records no branch" "$(plan_detail W7)" "the refusal names the missing branch"

# ===========================================================================
# 10 -- end to end: a real `orchid drive` pass over a task whose orphan
# already exists must ADOPT it. Exactly one worktree is registered for that
# branch afterwards, and the task records the orphan's own path.
# ===========================================================================
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/stubimpl"
printf 'manifest_version=1\nid=test/stubimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubimpl/plugin.conf"
cat > "$WORK/eng/stubimpl/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok", summary:"noop"}' > "$out"
EOF
chmod +x "$WORK/eng/stubimpl/run"
printf 'role.implementer=stubimpl\n' > "$REPO/orchid.config"

# The repo needs an integration branch for dispatch to read a base from.
git branch -f orchid/integration "$HEAD_SHA"
printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > "$REPO/.orchid/roadmap.md"

"$ORCHID_BIN" task create W8 "adopt end to end" >/dev/null
git worktree add -q "$WORKP/repo-W8" -b task/W8 "$HEAD_SHA"

# Every other fixture task above must sit out this pass, or the walk would
# also try to dispatch them (and, for the deliberately broken ones, park the
# run on a worktree-conflict boundary before ever reaching W8).
for other in W1 W2 W3 W4 W5 W6 W7; do
  "$ORCHID_BIN" task advance "$other" blocked --reason "fixture: excluded from the drive pass" >/dev/null
done

rc=0
out="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || rc=$?
# W1..W7 are blocked, so the pass legitimately ends at a blocked-task
# boundary; W8's dispatch still had to happen in the same pass.
[ "$rc" -eq 0 ] || [ "$rc" -eq 16 ] || fail "drive pass failed unexpectedly (rc=$rc): $out"

assert_match "adopted the orphan dispatch worktree" "$out" "the pass reports adopting the orphan rather than creating anything"
assert_eq "$WORKP/repo-W8" "$("$ORCHID_BIN" task show W8 | grep '^worktree: ' | cut -d' ' -f2-)" \
  "the adopted orphan's own path is what gets recorded"

wt_count="$(git -C "$REPO" worktree list --porcelain | grep -c '^branch refs/heads/task/W8$' || true)"
[ -n "$wt_count" ] || wt_count=0
assert_eq 1 "$wt_count" "exactly ONE worktree is registered for the task's branch — never a duplicate"

# And a second pass is a no-op on the same worktree: idempotent, not additive.
rc=0
out2="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 16 ] || fail "second drive pass failed unexpectedly (rc=$rc): $out2"
wt_count2="$(git -C "$REPO" worktree list --porcelain | grep -c '^branch refs/heads/task/W8$' || true)"
[ -n "$wt_count2" ] || wt_count2=0
assert_eq 1 "$wt_count2" "a repeated pass never registers a second worktree for the same task"
