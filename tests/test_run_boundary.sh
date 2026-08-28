#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# `orchid run boundary set|clear|show` -- the single-writer record of "policy
# deliberately refused to decide this", plus the dedicated judgment-boundary
# exit code 16.
#
# RED before this task: `orchid run boundary` does not exist, so every arm
# below dies with orchid-run's usage message.

cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create T001 "boundary subject" >/dev/null

# ===========================================================================
# 1 -- no boundary recorded: `show` says so plainly and exits 0. The exit
# code is the whole point; the pump reads it, never the text.
# ===========================================================================
rc=0; out="$("$ORCHID_BIN" run boundary show 2>&1)" || rc=$?
assert_eq 0 "$rc" "run boundary show exits 0 when nothing is recorded"
assert_eq "boundary: none" "$out" "run boundary show names the empty case plainly"

# ===========================================================================
# 2 -- set: schema, fields, exit code, journal entry.
# ===========================================================================
rc=0; out="$("$ORCHID_BIN" run boundary set --kind review-conflict --task T001 \
  --reason "reviewer requested changes" 2>&1)" || rc=$?
assert_eq 0 "$rc" "run boundary set exits 0"
assert_match "boundary: review-conflict \(T001\)" "$out" "set echoes the kind and task"

rc=0; shown="$("$ORCHID_BIN" run boundary show 2>&1)" || rc=$?
assert_eq 16 "$rc" "run boundary show exits 16 (the dedicated judgment-boundary code) when one is recorded"
assert_eq 1 "$(printf '%s' "$shown" | jq -r '.schema')" "the record declares schema 1"
assert_eq "review-conflict" "$(printf '%s' "$shown" | jq -r '.kind')" "the record carries the kind"
assert_eq "T001" "$(printf '%s' "$shown" | jq -r '.task')" "the record carries the task"
assert_eq "reviewer requested changes" "$(printf '%s' "$shown" | jq -r '.reason')" "the record carries the operator-readable reason"
assert_eq "$ORCHID_EPOCH" "$(printf '%s' "$shown" | jq -r '.epoch')" "the record is stamped with the fencing epoch"
assert_match "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" \
  "$(printf '%s' "$shown" | jq -r '.at')" "the record is timestamped"

# grep -c prints "0" AND exits 1 when nothing matches, so the count must be
# captured with `|| true` rather than falling back to a second `echo`.
journal_hits() {
  local n
  n="$(grep -c "judgment boundary" .orchid/journal.md 2>/dev/null || true)"
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}
assert_eq 1 "$(journal_hits)" "setting a boundary journals it exactly once"
assert_match "judgment boundary \[review-conflict\]: reviewer requested changes" \
  "$(cat .orchid/journal.md)" "the journal entry names the kind and the reason"

# ===========================================================================
# 3 -- idempotent by CONTENT. The driver re-derives the same boundary every
# pass for as long as the condition holds; that must not journal once per
# pass. A CHANGED reason is a new fact and is journaled.
# ===========================================================================
rc=0; out="$("$ORCHID_BIN" run boundary set --kind review-conflict --task T001 \
  --reason "reviewer requested changes" 2>&1)" || rc=$?
assert_eq 0 "$rc" "re-setting an identical boundary exits 0"
assert_match "boundary unchanged" "$out" "an identical re-set reports itself as unchanged"
assert_eq 1 "$(journal_hits)" "an identical re-set does NOT journal a second time"

"$ORCHID_BIN" run boundary set --kind review-conflict --task T001 \
  --reason "reviewer requested changes, and a high finding landed" >/dev/null
assert_eq 2 "$(journal_hits)" "a changed reason is a new fact and IS journaled"

# ===========================================================================
# 4 -- refusals. An unknown kind, a missing reason, and an unknown task are
# all fail-closed: a boundary can never be minted for a condition this kernel
# has no defined meaning for, nor for a task that does not exist.
# ===========================================================================
rc=0; err="$("$ORCHID_BIN" run boundary set --kind whatever --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown boundary kind must be refused"
assert_match "unknown boundary kind 'whatever'" "$err" "the refusal names the offending kind"
assert_match "review-evidence" "$err" "the refusal enumerates the kernel-owned kinds"

rc=0; err="$("$ORCHID_BIN" run boundary set --kind planning 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "run boundary set without --reason must be refused (INV-08)"
assert_match "requires --reason" "$err" "the refusal names the missing --reason"

rc=0; err="$("$ORCHID_BIN" run boundary set --kind blocked-task --task NOPE --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a boundary naming a nonexistent task must be refused"
assert_match "no task NOPE" "$err" "the refusal names the missing task"

rc=0; err="$("$ORCHID_BIN" run boundary frobnicate 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown boundary subverb must be refused"
assert_match "usage: orchid run boundary" "$err" "an unknown subverb prints the boundary usage line"

# The record survived every refusal above untouched.
rc=0; "$ORCHID_BIN" run boundary show >/dev/null 2>&1 || rc=$?
assert_eq 16 "$rc" "a refused set never disturbs the recorded boundary"

# ===========================================================================
# 5 -- INV-02: the boundary record is cross-process state, so a stale epoch
# may not write it.
# ===========================================================================
rc=0; err="$(ORCHID_EPOCH=99999 "$ORCHID_BIN" run boundary set --kind planning --reason "stale" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a stale epoch must not be able to set a boundary"
assert_match "stale epoch" "$err" "the refusal names the epoch fence (INV-02)"
rc=0; err="$(ORCHID_EPOCH=99999 "$ORCHID_BIN" run boundary clear --reason "stale" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a stale epoch must not be able to clear a boundary"
assert_match "stale epoch" "$err" "clearing is fenced the same way as setting"

# ===========================================================================
# 6 -- clear.
# ===========================================================================
rc=0; err="$("$ORCHID_BIN" run boundary clear 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "run boundary clear without --reason must be refused (INV-08)"

rc=0; out="$("$ORCHID_BIN" run boundary clear --reason "operator arbitrated it by hand" 2>&1)" || rc=$?
assert_eq 0 "$rc" "run boundary clear exits 0"
assert_match "boundary cleared: review-conflict" "$out" "clear names the kind it released"
assert_match "judgment boundary cleared \[review-conflict\]" "$(cat .orchid/journal.md)" \
  "clearing is journaled with the kind it released"

rc=0; out="$("$ORCHID_BIN" run boundary show 2>&1)" || rc=$?
assert_eq 0 "$rc" "after clear, show is back to exit 0"
assert_eq "boundary: none" "$out" "after clear, nothing is recorded"

# Clearing when nothing is recorded is a silent no-op, not an error and not a
# journal entry -- the driver calls it on EVERY clean pass.
before="$(wc -l < .orchid/journal.md)"
rc=0; out="$("$ORCHID_BIN" run boundary clear --reason "clean pass" 2>&1)" || rc=$?
assert_eq 0 "$rc" "clearing an already-clear boundary exits 0"
assert_eq "boundary: none" "$out" "clearing an already-clear boundary says so"
assert_eq "$before" "$(wc -l < .orchid/journal.md)" \
  "a no-op clear must not journal (the driver runs it every clean pass)"

# ===========================================================================
# 7 -- every kernel-owned kind is accepted, and only those.
# ===========================================================================
for kind in planning blocked-task review-evidence review-conflict hook-failure worktree-conflict operator-handoff task-prerequisite operator-decision; do
  rc=0; "$ORCHID_BIN" run boundary set --kind "$kind" --reason "kind coverage" >/dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "kernel-owned boundary kind '$kind' is accepted"
done
"$ORCHID_BIN" run boundary clear --reason "coverage done" >/dev/null
