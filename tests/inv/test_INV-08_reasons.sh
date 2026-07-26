#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo
for s in implementing testing reviewing arbitrating; do "$ORCHID_BIN" task advance T001 "$s" >/dev/null; done
rc=0; "$ORCHID_BIN" task advance T001 merging 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-08: merging without --reason"
"$ORCHID_BIN" task advance T001 merging --reason "both reviewers approve"
grep -q "arbitration" .orchid/journal.md || fail "INV-08: arbitration kind journaled"
grep -q '"by": *"operator' .orchid/journal.md 2>/dev/null || grep -q "(operator" .orchid/journal.md || fail "INV-08: actor kernel-derived"

# Fix 1: kernel-owned keys must not be settable via `task set`
before_status="$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)"
before_attempts="$("$ORCHID_BIN" task show T001 | grep '^attempts: ' | cut -d' ' -f2)"
rc=0; "$ORCHID_BIN" task set T001 status done 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task set status must be refused (kernel-owned)"
rc=0; "$ORCHID_BIN" task set T001 attempts 99 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "task set attempts must be refused (kernel-owned)"
after_status="$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)"
after_attempts="$("$ORCHID_BIN" task show T001 | grep '^attempts: ' | cut -d' ' -f2)"
[ "$before_status" = "$after_status" ] || fail "status changed despite refused set"
[ "$before_attempts" = "$after_attempts" ] || fail "attempts changed despite refused set"
