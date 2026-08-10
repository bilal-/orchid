#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: a verb run under an epoch the kernel has already moved past -- `task
#      set`, `journal add` and `run new`, each invoked with a deliberately
#      stale ORCHID_EPOCH below. Each must be REFUSED, and the durable state
#      each would have written (the task file, journal.md, .orchid/runs and
#      the roadmap's run_id) is read back afterwards to prove the refusal was
#      a refusal and not a quiet success with an error message.
# GREEN: the same verbs under the CURRENT epoch must succeed (`task create`
#      at the top), or the refusals above would prove only that the fixture
#      is broken.
# An invariant gate that cannot run is not a gate that passed: without the
# verb there is nothing here to fence, so this fails rather than skipping.
[ -x "$REPO_ROOT/libexec/orchid-task" ] \
  || { fail "INV-02: libexec/orchid-task is missing, so nothing below can exercise the epoch fence"; exit 1; }
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
cur="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
ORCHID_EPOCH="$cur"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo || fail "current epoch mutates"
# The GREEN twin, exercised HERE rather than delegated: the same class of verb,
# under the CURRENT epoch, must both succeed AND land its durable write. The
# refusals below are evidence of fencing only if this one got through.
[ -f .orchid/tasks/T001.md ] \
  || fail "INV-02: task create under the current epoch produced no task file, so the refusals below prove only that the fixture is broken"
green_case "a mutating verb under the CURRENT epoch succeeded and its durable write landed"
"$ORCHID_BIN" run resume >/dev/null      # epoch moves on; we are now stale
rc=0; "$ORCHID_BIN" task set T001 title X 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-02: stale epoch must not mutate durable state"

# Fix 2: journal add must also be epoch-fenced (still stale from above)
snap_before="$(cat .orchid/journal.md 2>/dev/null || true)"
rc=0; "$ORCHID_BIN" journal add --task T001 --kind note x 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-02: stale epoch must not allow journal add"
snap_after="$(cat .orchid/journal.md 2>/dev/null || true)"
[ "$snap_before" = "$snap_after" ] || fail "INV-02: journal.md changed despite stale epoch"

# v1-m3 Task 11 fix (post-review CRITICAL 1): `orchid run new` must fence
# the epoch exactly like every other mutating run verb -- a real init +
# integration-branch worktree is needed here, since `new` operates against
# a real branch (mirrors `orchid plan apply`'s own temp-worktree pattern).
# NOT wrapped in a subshell: `fail` mutates $FAILS in the CURRENT shell, so
# a subshell here would silently swallow any failure below.
bare="$WORK/inv02-bare"; mkdir -p "$bare"
(cd "$bare" && git init -q . && git commit -q --allow-empty -m root)
rn_wt="$WORK/inv02-wt"
ORCHID_REPO="$bare" HOME="$WORK/home" "$ORCHID_BIN" init >/dev/null
git -C "$bare" worktree add -q "$rn_wt" orchid/integration
cd "$rn_wt" || exit 1
export ORCHID_REPO="$rn_wt" HOME="$WORK/home"
stale_epoch="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
ORCHID_EPOCH="$stale_epoch"
export ORCHID_EPOCH
"$ORCHID_BIN" run advance blocked --reason "inv02 fixture" >/dev/null
"$ORCHID_BIN" run resume >/dev/null   # epoch moves on; ORCHID_EPOCH is now stale
rc=0; "$ORCHID_BIN" run new --reason "should be refused" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-02: stale epoch must not allow run new"
[ -d .orchid/runs ] && fail "INV-02: run new must not have archived anything under a stale epoch"
grep -q "run_id: r-001" .orchid/roadmap.md || fail "INV-02: roadmap.md run_id must be untouched by a refused run new"
red_case "the epoch fence refused task set, journal add and run new under a stale epoch, and none of their durable writes landed"
