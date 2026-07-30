#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
[ -x "$REPO_ROOT/libexec/orchid-task" ] || { echo "  SKIP: orchid-task not yet implemented (activates in Task 6)"; exit 0; }
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
cur="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$cur"
"$ORCHID_BIN" task create T001 demo || fail "current epoch mutates"
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
cd "$rn_wt"
export ORCHID_REPO="$rn_wt" HOME="$WORK/home"
stale_epoch="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$stale_epoch"
"$ORCHID_BIN" run advance blocked --reason "inv02 fixture" >/dev/null
"$ORCHID_BIN" run resume >/dev/null   # epoch moves on; ORCHID_EPOCH is now stale
rc=0; "$ORCHID_BIN" run new --reason "should be refused" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-02: stale epoch must not allow run new"
[ -d .orchid/runs ] && fail "INV-02: run new must not have archived anything under a stale epoch"
grep -q "run_id: r-001" .orchid/roadmap.md || fail "INV-02: roadmap.md run_id must be untouched by a refused run new"
