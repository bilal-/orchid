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
# The repository's own canonical path, spelled the way `pwd -P` inside a
# prepared checkout would spell it -- macOS hands out /var/folders symlinks
# for /private/var/folders, so a logical path would never compare equal.
REPO_PHYS="$WORKP/repo"
state_tasks="$REPO/.orchid/tasks"

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

# ===========================================================================
# 11 -- worktree_prepare. A checkout Orchid creates holds exactly what is
# committed and nothing else, so any project whose verify command needs
# untracked setup (installed dependencies, a generated file, a .env) fails
# there while passing in the operator's own checkout. `worktree_prepare` is
# the one chance to close that; the checkout it prepares is a SIBLING of the
# repository (dispatch) or an unrelated $TMPDIR directory (merge validation),
# so the command cannot work out where the repository is on its own and is
# handed ORCHID_REPO_ROOT.
#
# RED before this task: worktree_prepare (lib/common.sh) does not exist.
# ===========================================================================
# Unconfigured is the default, and it must be a silent no-op -- no log
# directory, no stamp, nothing run.
assert_match '^skip' "$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)" \
  "an unset worktree_prepare skips without running anything"
if [ -e "$REPO/.orchid/runtime/worktree-prepare" ]; then
  fail "an unset worktree_prepare must not create a log directory"
fi

PREP_COUNT="$WORK/prep-count"
cat > "$WORK/prep.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
# Runs INSIDE the prepared checkout: every relative path below is proof of
# its own cwd, and the environment it records is the contract under test.
{
  printf 'repo_root=%s\n' "$ORCHID_REPO_ROOT"
  printf 'worktree=%s\n' "$ORCHID_WORKTREE"
  printf 'task=%s\n' "$ORCHID_TASK"
  printf 'cwd=%s\n' "$(pwd -P)"
} > prepared.txt
printf 'ran\n' >> "$1"
EOF
chmod +x "$WORK/prep.sh"
printf 'worktree_prepare=%s %s\n' "$WORK/prep.sh" "$PREP_COUNT" >> "$REPO/orchid.config"

prep_out="$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)"
assert_match '^ok' "$prep_out" "a configured worktree_prepare that exits 0 reports ok"
assert_eq 1 "$(grep -c ran "$PREP_COUNT" 2>/dev/null || echo 0)" "the command ran exactly once"
assert_eq "$REPO_PHYS" "$(grep '^repo_root=' "$WORKP/repo-W8/prepared.txt" | cut -d= -f2-)" \
  "ORCHID_REPO_ROOT is the canonical physical path of the repository, not the worktree"
assert_eq "$WORKP/repo-W8" "$(grep '^cwd=' "$WORKP/repo-W8/prepared.txt" | cut -d= -f2-)" \
  "the command runs with the prepared checkout as its working directory"
assert_eq "$WORKP/repo-W8" "$(grep '^worktree=' "$WORKP/repo-W8/prepared.txt" | cut -d= -f2-)" \
  "ORCHID_WORKTREE names the checkout being prepared"
assert_eq W8 "$(grep '^task=' "$WORKP/repo-W8/prepared.txt" | cut -d= -f2-)" \
  "ORCHID_TASK names the task the checkout belongs to"
prep_log="$(printf '%s' "$prep_out" | cut -f2-)"
[ -f "$prep_log" ] || fail "the ok result names a log file that exists"
assert_match 'exit: 0' "$(cat "$prep_log")" "the log records the command's own exit status"

# Stamped: the SAME command is never re-run for the same checkout. Dispatch
# reaches this on every pass of a task that keeps its worktree, and a real
# prepare command (a dependency install) is far too expensive to repeat.
assert_match '^skip' "$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)" \
  "an already-prepared checkout is skipped on the next call"
assert_eq 1 "$(grep -c ran "$PREP_COUNT")" "the skipped call ran nothing"

# The stamp records the COMMAND, so editing the config re-prepares.
printf 'worktree_prepare=%s %s --again\n' "$WORK/prep.sh" "$PREP_COUNT" >> "$REPO/orchid.config"
assert_match '^ok' "$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)" \
  "changing the configured command re-prepares the checkout"
assert_eq 2 "$(grep -c ran "$PREP_COUNT")" "the changed command ran again"

# A failure is reported, is NOT stamped (so the next pass retries once the
# operator has fixed it), and names the log holding the command's output.
printf 'worktree_prepare=sh -c "echo boom >&2; exit 3"\n' >> "$REPO/orchid.config"
fail_out="$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)"
assert_match '^fail' "$fail_out" "a command that exits non-zero reports fail"
assert_match 'exit 3|status 3' "$fail_out" "the failure names the command's exit status"
assert_match '^fail' "$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)" \
  "a failed prepare is never stamped -- the next call retries it"

# A hung command must not hang the driver pass that called it.
printf 'worktree_prepare_timeout_s=1\n' >> "$REPO/orchid.config"
printf 'worktree_prepare=sleep 30\n' >> "$REPO/orchid.config"
slow_out="$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)"
assert_match '^fail' "$slow_out" "a command that outlives worktree_prepare_timeout_s fails"
assert_match 'timed out' "$slow_out" "the failure says it timed out rather than blaming the exit status"

# A budget that is not a number falls back to the default instead of reaching
# with_timeout's own `sleep` as its argument. That `sleep` fails the instant
# it starts, so its watcher kills the command's process group immediately and
# EVERY prepare becomes a zero-second timeout -- reported as the command
# having timed out, which sends an operator to debug a command that was never
# given a chance to run. A one-second command is what makes the difference
# visible: under the fallback it has 900 seconds and finishes, under the bug
# it is killed before it can.
#
# RED before the guard: `sleep abc` returns at once, the command below is
# killed with it, and this reports fail/timed out rather than ok.
printf 'worktree_prepare_timeout_s=abc\n' >> "$REPO/orchid.config"
printf 'worktree_prepare=sleep 1\n' >> "$REPO/orchid.config"
assert_match '^ok' "$(worktree_prepare "$REPO" "$WORKP/repo-W8" W8)" \
  "a non-numeric worktree_prepare_timeout_s falls back to the default instead of killing the command at once"

# ===========================================================================
# 12 -- end to end: a dispatch whose prepare step fails parks the run on a
# worktree-conflict boundary and leaves the task where it was. Advancing it
# into an active status would hand an implementer a checkout its own verify
# command cannot pass, and report the environment's problem as the
# candidate's.
# ===========================================================================
printf 'worktree_prepare_timeout_s=900\n' >> "$REPO/orchid.config"
printf 'worktree_prepare=sh -c "exit 7"\n' >> "$REPO/orchid.config"
"$ORCHID_BIN" task create W9 "prepare fails" >/dev/null
# W8 sits out these passes for the same reason W1..W7 do above: this section
# is about W9's dispatch, and a task already carrying a finished stub job
# would otherwise walk on through the pass and add unrelated noise.
"$ORCHID_BIN" task advance W8 blocked --reason "fixture: excluded from the prepare passes" >/dev/null
rc=0
out3="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || rc=$?
assert_match "boundary \[worktree-conflict\] W9" "$out3" \
  "a failing prepare step raises a worktree-conflict boundary against the task"
assert_eq pending "$(fm_get "$state_tasks/W9.md" status)" \
  "the task stays where it was -- never dispatched into an unusable checkout"

# AND IT IS COUNTED, on the infra ladder rather than against the candidate.
# This is the distinction the whole step exists to draw: folded into `verify`
# instead -- the workaround this feature replaces -- a broken bootstrap is a
# failed verification, which spends an ATTEMPT and reads as "the candidate is
# wrong", which is the misdiagnosis the dogfood findings behind this task are
# made of. The counter is kernel-owned, journals its reason, and auto-blocks
# at `infra_max`, so an environment nobody repairs ends bounded instead of
# re-raising the same boundary every pass forever.
#
# RED before this change: infra_failures is still 0 after the pass, and
# nothing anywhere records the environment failure.
assert_eq 1 "$(fm_get "$state_tasks/W9.md" infra_failures)" \
  "a dispatch worktree that cannot be prepared charges the infra ladder"
assert_eq 0 "$(fm_get "$state_tasks/W9.md" attempts)" \
  "and never the candidate's attempts -- nothing was attempted"
assert_match "worktree_prepare failed for the dispatch worktree" \
  "$("$ORCHID_BIN" journal show --task W9)" \
  "the counter's reason names the environment's failure, so it is not read as the candidate's"

# With the prepare step fixed, the same dispatch goes through, and the
# already-created worktree is reused rather than recreated.
printf 'worktree_prepare=%s %s\n' "$WORK/prep.sh" "$PREP_COUNT" >> "$REPO/orchid.config"
rc=0
out4="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || rc=$?
assert_match "prepared the dispatch worktree" "$out4" "the pass reports the prepare step it ran"
[ -f "$WORKP/repo-W9/prepared.txt" ] \
  || fail "a repaired prepare step lets the same dispatch through and prepares the checkout"
assert_eq "$REPO_PHYS" "$(grep '^repo_root=' "$WORKP/repo-W9/prepared.txt" 2>/dev/null | cut -d= -f2-)" \
  "the dispatch worktree was prepared with the repository's own canonical path"
wt_count3="$(git -C "$REPO" worktree list --porcelain | grep -c '^branch refs/heads/task/W9$' || true)"
[ -n "$wt_count3" ] || wt_count3=0
assert_eq 1 "$wt_count3" "the refused pass left exactly one worktree for the branch, reused by the next"

# ===========================================================================
# 13 -- the prepare command MUST NOT INHERIT THE DRIVER'S STDIN.
#
# The driver walks its work through loops whose own stdin IS the worklist:
# the task walk reads `< <("$ORCHID_BIN" task list | sort)`, and dispatch --
# and therefore worktree_prepare -- is called from inside it, through a
# command substitution, which redirects stdout and nothing else. So a prepare
# command that reads stdin for any ordinary reason reads the tasks this pass
# has not walked yet. The loop then sees EOF, the pass ends early having
# skipped real work, and NOTHING reports an error: a task the walk never
# reached is indistinguishable from a task with nothing to do.
#
# Two pending tasks is the smallest fixture that can see it -- the first
# one's prepare step eats the second one.
#
# RED before the fix: WS2 is still `pending` after the pass, and the capture
# file holds the task rows the driver never got to walk.
# ===========================================================================
STDIN_CAPTURE="$WORK/prep-stdin-capture"
: > "$STDIN_CAPTURE"
cat > "$WORK/prep-stdin.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
# Every version of this hazard reduces to the same act: the command reads
# stdin. An installer asking to continue, a bootstrap with a bare `read`, a
# pipeline ending in `cat` -- whatever it is for, if the driver's worklist is
# on the other end then reading it destroys work nobody will report missing.
# Capturing rather than discarding is what makes the failure legible.
cat >> "$1"
EOF
chmod +x "$WORK/prep-stdin.sh"
printf 'worktree_prepare=%s %s\n' "$WORK/prep-stdin.sh" "$STDIN_CAPTURE" >> "$REPO/orchid.config"

# W9 sits out this pass for the reason W8 sat out the last one.
"$ORCHID_BIN" task advance W9 blocked --reason "fixture: excluded from the stdin pass" >/dev/null
"$ORCHID_BIN" task create WS1 "first of two dispatches" >/dev/null
"$ORCHID_BIN" task create WS2 "second of two dispatches" >/dev/null

rc=0
out5="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || rc=$?
assert_eq implementing "$(fm_get "$state_tasks/WS1.md" status)" \
  "the first of the two pending tasks is dispatched"
assert_eq implementing "$(fm_get "$state_tasks/WS2.md" status)" \
  "the walk reaches the SECOND task too — a prepare command that reads stdin must not truncate it"
assert_match "WS2: prepared the dispatch worktree" "$out5" \
  "the second task's own prepare step ran, so the walk really did continue past the first"
assert_eq "" "$(cat "$STDIN_CAPTURE")" \
  "the prepare command's stdin is /dev/null — it read nothing, because there was nothing there to read"
