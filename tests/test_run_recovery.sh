#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# RED: rollover never deletes the previous directory left by an interrupted swap.
# GREEN: rollover still succeeds after the operator preserves that backup elsewhere.
cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
"$ORCHID_BIN" init >/dev/null
git checkout -q orchid/integration
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" run advance blocked --reason 'recovery fixture' >/dev/null
"$ORCHID_BIN" run release-lease >/dev/null
cp -R .orchid .orchid.old.424242
printf 'only recoverable copy\n' > .orchid.old.424242/operator-note
recovery_head="$(git rev-parse HEAD)"
recovery_roadmap="$(cat .orchid/roadmap.md)"
recovery_rc=0
recovery_error="$(ORCHID_EPOCH=0 "$ORCHID_BIN" run new --reason 'stale recovery attempt' 2>&1)" || recovery_rc=$?
[ "$recovery_rc" -ne 0 ] || fail 'stale rollover must be refused'
assert_eq 'only recoverable copy' "$(cat .orchid.old.424242/operator-note 2>/dev/null)" 'epoch refusal preserves recovery backup'
red_case 'a stale epoch cannot erase a prior interrupted-swap backup before its fence fires'

recovery_rc=0
recovery_error="$("$ORCHID_BIN" run new --reason 'recovery attempt' 2>&1)" || recovery_rc=$?
[ "$recovery_rc" -ne 0 ] || fail 'rollover must refuse an unresolved recovery backup'
assert_match 'durable sync backup' "$recovery_error" 'rollover identifies the recovery backup'
assert_eq 'only recoverable copy' "$(cat .orchid.old.424242/operator-note 2>/dev/null)" 'rollover refuses without deleting backup'
assert_eq "$recovery_head" "$(git rev-parse HEAD)" 'backup refusal does not advance integration'
assert_eq "$recovery_roadmap" "$(cat .orchid/roadmap.md)" 'backup refusal preserves live roadmap'
red_case 'current-epoch rollover preserves unresolved recovery data and integration state'

mv .orchid.old.424242 saved-recovery
recovery_output="$("$ORCHID_BIN" run new --reason 'backup preserved outside swap namespace')" || fail 'rollover succeeds after backup recovery'
assert_match 'run rolled over: r-001 -> r-002' "$recovery_output" 'accepting rollover names the new run'
assert_eq 'only recoverable copy' "$(cat saved-recovery/operator-note)" 'operator-preserved recovery data survives rollover'
assert_eq "$ORCHID_EPOCH" "$(cat .orchid/runtime/epoch)" 'accepting rollover preserves current runtime epoch'
green_case 'rollover accepts an ordinary blocked run once its recovery backup is preserved elsewhere'
