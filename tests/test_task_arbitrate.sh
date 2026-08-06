#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# `orchid task arbitrate` -- the SOLE explicit judgment-result verb.
#
# The destination is derived from the archetype's declared transitions, never
# supplied by the caller: an approval takes arbitrating:merging when the
# archetype declares it (outcome=code) and arbitrating:done when it does not
# (outcome=report); a request-changes takes arbitrating:rework. Everything
# else -- the reason requirement, attempt accounting, evidence invalidation,
# the `arbitration` journal kind -- comes from `task advance`, unchanged.
#
# RED before this task: `orchid task arbitrate` does not exist, so every arm
# below dies with orchid-task's usage message.

cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

status_of() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }
attempts_of() { "$ORCHID_BIN" task show "$1" | grep '^attempts: ' | cut -d' ' -f2; }

# to_arbitrating <id> [--archetype <name>] -- the light-weight walk
# tests/test_task.sh already uses for archetype edge coverage: placeholder
# shas (a `git log <base>..<candidate>` over an invalid range prints nothing,
# so INV-04's .orchid/ scan never trips) plus `verification_commands=true`
# so `orchid verify` always PASSes, plus a planted reviewer envelope for the
# kernel's own reviewing->arbitrating count gate.
edge_sha="deadbeefcafebabe0000000000000000000000"
to_arbitrating() {
  local id="$1"; shift
  "$ORCHID_BIN" task create "$id" "arbitrate subject" "$@" >/dev/null
  "$ORCHID_BIN" task set "$id" base_sha "$edge_sha" >/dev/null
  "$ORCHID_BIN" task set "$id" candidate_sha "$edge_sha" >/dev/null
  "$ORCHID_BIN" task set "$id" verification_commands true >/dev/null
  if [ "$(status_of "$id")" = pending ]; then
    case " $* " in
      *" review "*)
        "$ORCHID_BIN" task advance "$id" reviewing --reason "report archetype dispatch" >/dev/null ;;
      *)
        "$ORCHID_BIN" task advance "$id" implementing --reason "dispatch" >/dev/null
        "$ORCHID_BIN" task advance "$id" testing --reason "implemented" >/dev/null
        "$ORCHID_BIN" verify "$id" >/dev/null
        "$ORCHID_BIN" task advance "$id" reviewing --reason "verify passed" >/dev/null ;;
    esac
  fi
  plant_reviewer_envelope "$id"
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "reviews reconciled" >/dev/null
}

# ===========================================================================
# 1 -- approve on an outcome=code archetype: derived destination is `merging`.
# ===========================================================================
to_arbitrating T001
rc=0; out="$("$ORCHID_BIN" task arbitrate T001 --result approve --reason "unanimous approval, no blocking findings" 2>&1)" || rc=$?
assert_eq 0 "$rc" "task arbitrate --result approve exits 0"
assert_eq "arbitrated T001: result=approve from=arbitrating to=merging" "$out" \
  "arbitrate prints one structured line naming the result and the derived destination"
assert_eq merging "$(status_of T001)" "an approval on an outcome=code archetype lands in merging"
assert_match "T001 arbitration" "$(cat .orchid/journal.md)" \
  "the transition is journaled with the kernel's own arbitration kind"
assert_match "arbitrate\(approve\): unanimous approval" "$(cat .orchid/journal.md)" \
  "the journal carries the structured result alongside the operator's reason"

# ===========================================================================
# 2 -- request-changes: derived destination is `rework`, and it consumes an
# attempt exactly like the equivalent `task advance` does.
# ===========================================================================
to_arbitrating T002
assert_eq 0 "$(attempts_of T002)" "T002 starts with no consumed attempts"
rc=0; out="$("$ORCHID_BIN" task arbitrate T002 --result request-changes --reason "the flagged race is real" 2>&1)" || rc=$?
assert_eq 0 "$rc" "task arbitrate --result request-changes exits 0"
assert_eq "arbitrated T002: result=request-changes from=arbitrating to=rework" "$out" \
  "a rejection names rework as the derived destination"
assert_eq rework "$(status_of T002)" "a rejection lands in rework"
assert_eq 1 "$(attempts_of T002)" "a rejection consumes an attempt"
[ ! -f .orchid/reviews/T002-verify.log ] || fail "entry to rework must invalidate the prior verify evidence"

# --waive-attempt is forwarded verbatim.
to_arbitrating T003
"$ORCHID_BIN" task arbitrate T003 --result request-changes --waive-attempt \
  --reason "the reviewer could not build; tooling gap, not a defect" >/dev/null
assert_eq rework "$(status_of T003)" "a waived rejection still lands in rework"
assert_eq 0 "$(attempts_of T003)" "--waive-attempt is forwarded: no attempt consumed"
assert_match "attempt_waiver" "$(cat .orchid/journal.md)" "the waiver is journaled by the kernel"

# ===========================================================================
# 3 -- approve on an outcome=report archetype: `merging` is not declared, so
# the derived destination is `done`. No archetype NAME is consulted anywhere
# in the verb; this is read straight off the manifest's transitions.
# ===========================================================================
to_arbitrating T004 --archetype review
rc=0; out="$("$ORCHID_BIN" task arbitrate T004 --result approve --reason "report accepted" 2>&1)" || rc=$?
assert_eq 0 "$rc" "task arbitrate --result approve exits 0 on an outcome=report archetype"
assert_eq "arbitrated T004: result=approve from=arbitrating to=done" "$out" \
  "an approval on an archetype that declares no merging edge lands in done"
assert_eq "done" "$(status_of T004)" "the report archetype's task is done, never merged"

# ===========================================================================
# 4 -- refusals. Every one of these must leave the task exactly where it was.
# ===========================================================================
to_arbitrating T005

rc=0; err="$("$ORCHID_BIN" task arbitrate T005 --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "arbitrate without --result must be refused"
assert_match "requires --result approve|request-changes" "$err" "the refusal names the missing --result"

rc=0; err="$("$ORCHID_BIN" task arbitrate T005 --result maybe --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unrecognized --result must be refused"

rc=0; err="$("$ORCHID_BIN" task arbitrate T005 --result approve 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "arbitrate without --reason must be refused (INV-08)"
assert_match "requires --reason" "$err" "the refusal names the missing --reason"

rc=0; err="$("$ORCHID_BIN" task arbitrate NOPE --result approve --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "arbitrate on a nonexistent task must be refused"
assert_match "no task NOPE" "$err" "the refusal names the missing task"

rc=0; err="$("$ORCHID_BIN" task arbitrate plan --result approve --reason x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "arbitrate on the reserved id 'plan' must be refused"
assert_match "reserved" "$err" "the reserved-id refusal names why"

assert_eq arbitrating "$(status_of T005)" "every refusal above left T005 exactly where it was"

# ===========================================================================
# 5 -- arbitrate is only legal FROM arbitrating. It is a judgment-result
# verb, not a general transition verb: it can never be used to skip a state.
# ===========================================================================
"$ORCHID_BIN" task create T006 "not arbitrating" >/dev/null
rc=0; err="$("$ORCHID_BIN" task arbitrate T006 --result approve --reason "should be refused" 2>&1)" || rc=$?
assert_eq 3 "$rc" "arbitrating from a non-arbitrating status exits 3 (illegal transition)"
assert_match "is not arbitrating \(status: pending\)" "$err" "the refusal names the actual status"
assert_eq pending "$(status_of T006)" "the refused task is untouched"

# ===========================================================================
# 6 -- INV-02: a stale epoch cannot record a judgment.
# ===========================================================================
rc=0; err="$(ORCHID_EPOCH=99999 "$ORCHID_BIN" task arbitrate T005 --result approve --reason "stale" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a stale epoch must not be able to arbitrate"
assert_match "stale epoch" "$err" "the refusal names the epoch fence (INV-02)"
assert_eq arbitrating "$(status_of T005)" "the stale-epoch attempt changed nothing"

# ===========================================================================
# 7 -- usage line advertises the verb.
# ===========================================================================
rc=0; err="$("$ORCHID_BIN" task frobnicate 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown task subverb must be refused"
assert_match "arbitrate" "$err" "orchid task's usage line advertises arbitrate"
