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
