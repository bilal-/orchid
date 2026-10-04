#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
export ORCHID_OUTPUT=raw
ORCHID_BIN="${ORCHID_AXI_TEST_ROOT:-$REPO_ROOT}/bin/orchid"
AXI_ROOT="${ORCHID_AXI_TEST_ROOT:-$REPO_ROOT}"

# RED: a typo, surplus argument or help request must be rejected/answered
# before a command changes an ownership epoch, requirement or decision record.
# GREEN: the same commands still perform legal transitions with explicit values;
# a literal --help consumed by --reason remains decision data.
cd_scratch "$WORK"
export HOME="$MACHINE_HOME" ORCHID_REPO="$WORK"
git init -q .
git commit -q --allow-empty -m 'AXI mutation admission fixture'
"$ORCHID_BIN" init > "$MACHINE_HOME/axi-init.log" 2>&1 || fail 'AXI fixture: init'
git checkout -q orchid/integration || exit 1
epoch_out="$("$ORCHID_BIN" run start)" || exit 1
ORCHID_EPOCH="$(printf '%s\n' "$epoch_out" | sed -n 's/^epoch: //p')"
export ORCHID_EPOCH
printf 'REQ-1: isolated argument admission\n' > "$WORK/requirements.txt"

axi_digest() {
  local f
  find "$WORK/.orchid" -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done
}

"$ORCHID_BIN" run boundary set --kind operator-decision --reason 'standing help fixture' >/dev/null
before_help="$(axi_digest)"
rc=0
help_out="$("$ORCHID_BIN" run boundary clear --help --reason 'help must preserve this boundary' 2>&1)" || rc=$?
assert_eq 0 "$rc" 'AXI: nested clear help succeeds'
assert_match '^usage: orchid run boundary clear' "$help_out" 'AXI: nested clear answers its own help'
assert_eq "$before_help" "$(axi_digest)" 'AXI: help followed by valid mutation flags preserves standing boundary and journal'
red_case 'nested clear help with otherwise valid mutation flags was answered before clearing the standing operator decision'

axi_bad() {
  local token="$1" out rc=0 before; shift
  before="$(axi_digest)"
  out="$(ORCHID_EPOCH=999999 "$ORCHID_BIN" "$@" 2>&1)" || rc=$?
  assert_eq 2 "$rc" "AXI: $* is a usage refusal before the stale epoch"
  assert_match "(^|[^[:alnum:]])$token" "$out" "AXI: $* names the offending token"
  assert_match 'usage:|--help' "$out" "AXI: $* includes focused recovery help"
  assert_eq "$before" "$(axi_digest)" "AXI: $* writes no runtime or durable state"
}

axi_bad --bogus run start --bogus
axi_bad --bogus run refresh-lease --bogus
axi_bad --bogus run boundary set --kind operator-decision --reason fixture --bogus
axi_bad --bogus run boundary clear --reason fixture --bogus
axi_bad --bogus start --bogus
axi_bad --bogus plan rounds --bogus
axi_bad --bogus init --bogus
axi_bad --bogus requirements import "$WORK/requirements.txt" --bogus
axi_bad --bogus merge T999 --bogus
axi_bad --bogus verify T999 --bogus
axi_bad --bogus drive --bogus
axi_bad --bogus service status --dry-run --bogus
axi_bad --bogus answer q-e1-T999-abc yes --bogus
axi_bad --bogus notify --bogus 'isolated question'
axi_bad extra version extra
red_case 'unknown flags and surplus arguments across effectful verbs were rejected with the token and focused help before state ownership or effects'

for leaf in show set clear; do
  rc=0
  before_help="$(axi_digest)"
  help_out="$(ORCHID_EPOCH=999999 "$ORCHID_BIN" run boundary "$leaf" --help 2>&1)" || rc=$?
  assert_eq 0 "$rc" "AXI: boundary $leaf help is available under stale ownership"
  assert_match "^usage: orchid run boundary $leaf" "$help_out" "AXI: boundary $leaf help is focused"
  assert_eq "$before_help" "$(axi_digest)" "AXI: boundary $leaf help preserves state"
done
green_case 'show set and clear each expose their focused nested reference under a stale epoch without changing state'

# Direct kernel callers use the same admission and normalized argv as the
# dispatcher. A help-shaped, multiline option value must retain its bytes.
before_direct="$(axi_digest)"
direct_out="$(ORCHID_ROOT="$AXI_ROOT" /bin/bash "$AXI_ROOT/libexec/orchid-run")"
assert_eq "$("$ORCHID_BIN" run boundary show)" "$direct_out" 'AXI: direct run uses its documented read default'
rc=0
direct_out="$(ORCHID_ROOT="$AXI_ROOT" /bin/bash "$AXI_ROOT/libexec/orchid-run" boundary clear --help --reason 'direct help' 2>&1)" || rc=$?
assert_eq 0 "$rc" 'AXI: direct nested help succeeds before mutation'
assert_match '^usage: orchid run boundary clear' "$direct_out" 'AXI: direct nested help stays focused'
assert_eq "$before_direct" "$(axi_digest)" 'AXI: direct read and help preserve standing boundary'
green_case 'direct kernel invocation shares implicit read defaults and focused nested help without state writes'

# Refresh the fixture's returned ownership in the baseline RED experiment too:
# its ignored run-start flag can have minted a new epoch.
ORCHID_EPOCH="$(cat "$WORK/.orchid/runtime/epoch")"
export ORCHID_EPOCH
"$ORCHID_BIN" requirements import "$WORK/requirements.txt" >/dev/null
before_replay="$(axi_digest)"
"$ORCHID_BIN" requirements import "$WORK/requirements.txt" >/dev/null
assert_eq "$before_replay" "$(axi_digest)" 'AXI: exact requirements reimport is a no-op'
cp "$WORK/requirements.txt" "$WORK/--help"
rc=0
direct_out="$(ORCHID_ROOT="$AXI_ROOT" /bin/bash "$AXI_ROOT/libexec/orchid-requirements" import -- --help 2>&1)" || rc=$?
assert_eq 0 "$rc" 'AXI: direct escaped help-shaped filename is data'
assert_match 'already imported' "$direct_out" 'AXI: escaped filename reaches import instead of help'
assert_eq "$before_replay" "$(axi_digest)" 'AXI: escaped exact requirements retry preserves state'
green_case 'an exact-byte requirements retry succeeds without adding a duplicate import decision'

rc=0
advance_out="$("$ORCHID_BIN" run advance blocked --reason '--help' 2>&1)" || rc=$?
assert_eq 0 "$rc" 'AXI: --help as the reason value is accepted as data'
assert_match 'run_status: planning -> blocked' "$advance_out" 'AXI: the transition reports the resulting state'
assert_eq blocked "$(sed -n 's/^run_status: //p' "$WORK/.orchid/roadmap.md")" 'AXI: the legal transition still occurs with a help-shaped value'
assert_match '(^|[[:space:]])--help' "$("$ORCHID_BIN" journal tail -n 20)" 'AXI: the literal help-shaped reason is journaled'
before_replay="$(axi_digest)"
rc=0
"$ORCHID_BIN" requirements import "$WORK/requirements.txt" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'AXI: an exact requirements retry succeeds after planning'
assert_eq "$before_replay" "$(axi_digest)" 'AXI: exact requirements retry preserves the in-flight snapshot and journal'
printf 'REQ-1: Changed scope\n' > "$WORK/changed-requirements.txt"
rc=0
changed_out="$("$ORCHID_BIN" requirements import "$WORK/changed-requirements.txt" 2>&1)" || rc=$?
assert_eq 1 "$rc" 'AXI: changed requirements still refuse after planning'
assert_match 'requirements are immutable' "$changed_out" 'AXI: changed requirements retain the domain refusal'
assert_eq "$before_replay" "$(axi_digest)" 'AXI: changed requirements refusal preserves all state'
red_case 'changed requirements still refuse after planning while an exact-byte replay preserves the in-flight snapshot'
before_replay="$(axi_digest)"
rc=0
"$ORCHID_BIN" run advance blocked --reason 'retry the desired state' >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'AXI: requesting the current non-complete run state is a no-op'
assert_eq "$before_replay" "$(axi_digest)" 'AXI: desired-state repeat changes no evidence or journal'
inline_reason="$(printf 'direct inline reason\n--help')"
rc=0
direct_out="$(unset ORCHID_OUTPUT; ORCHID_ROOT="$AXI_ROOT" /bin/bash "$AXI_ROOT/libexec/orchid-run" advance running "--reason=$inline_reason" 2>&1)" || rc=$?
assert_eq 0 "$rc" 'AXI: direct inline option retains its multiline value'
assert_match 'run_status: blocked -> running' "$direct_out" 'AXI: direct inline option still performs the legal transition'
assert_match 'direct inline reason' "$("$ORCHID_BIN" journal tail -n 20)" 'AXI: direct inline reason is journaled'
rc=0
"$ORCHID_BIN" run advance complete --reason 'cannot waive acceptance evidence' >/dev/null 2>&1 || rc=$?
assert_eq 3 "$rc" 'AXI: advance complete still requires the dedicated acceptance gate'
qid="$("$ORCHID_BIN" notify -- --help)"
assert_match '^--help$' "$(cat "$WORK/.orchid/runtime/answers/$qid.question")" 'AXI: escaped help-shaped question is data'
rc=0
direct_out="$(unset ORCHID_OUTPUT; ORCHID_ROOT="$AXI_ROOT" /bin/bash "$AXI_ROOT/libexec/orchid-answer" -- "$qid" --help 2>&1)" || rc=$?
assert_eq 0 "$rc" 'AXI: escaped help-shaped free-text answer is data'
assert_eq "$qid: --help" "$direct_out" 'AXI: direct escaped answer retains the literal answer in its receipt'
green_case 'literal help values and legal desired-state retries preserve domain transitions while complete remains evidence-gated'
