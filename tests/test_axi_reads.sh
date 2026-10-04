#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# The override executes the same assertions against the frozen pre-AXI tree.
ORCHID_BIN="${ORCHID_AXI_BIN_OVERRIDE:-$ORCHID_BIN}"
export ORCHID_OUTPUT=raw HOME="$MACHINE_HOME" ORCHID_REPO="$WORK"
cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# Generic validation must happen before epoch or state access. Each accepting
# help twin exercises the same entry, with deliberately stale fencing.
for verb in status task jobs config journal lessons plugins trust; do
  rc=0
  out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" "$verb" --typo 2>&1)" || rc=$?
  assert_eq 2 "$rc" "$verb unknown flag is a usage error"
  assert_match 'typo' "$out" "$verb identifies offending flag"
  assert_match 'help|usage' "$out" "$verb provides recovery help"
  red_case "$verb rejects unknown flag before stale epoch"
  rc=0
  out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" "$verb" --help 2>&1)" || rc=$?
  assert_eq 0 "$rc" "$verb focused help before stale epoch"
  green_case "$verb accepts help through same validator before stale epoch"
done
rc=0
out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" trust help --help 2>&1)" || rc=$?
assert_eq 0 "$rc" 'trust existing help alias remains available'
for args in 'plugins validate --all orchid/claude' 'plugins audit --all claude' 'plugins test claude'; do
  read -r -a probe <<<"$args"
  rc=0
  out="$("$ORCHID_BIN" "${probe[@]}" 2>&1)" || rc=$?
  assert_eq 2 "$rc" "exclusive/required plugin form: $args"
  assert_match 'usage|help' "$out" "plugin invalid form includes recovery: $args"
done
red_case 'plugin compound forms refuse ambiguous target and missing role'
"$ORCHID_BIN" plugins validate --all >/dev/null || fail 'plugins validate --all accepts exact valid form'
green_case 'plugin all target accepts through same form validator'

# Preserve raw contracts; typed adapters are a separate read-only view.
"$ORCHID_BIN" task create T001 'typed task' >/dev/null || fail 'create typed fixture'
raw_list="$("$ORCHID_BIN" task list)"
assert_eq $'T001\tpending\ttyped task' "$raw_list" 'raw task list stays three-column TSV'
"$ORCHID_BIN" task show T001 > "$WORK/task.raw" || fail 'raw task show'
cmp "$WORK/task.raw" .orchid/tasks/T001.md || fail 'raw task detail remains byte identical'
rc=0
"$ORCHID_BIN" task get T001 title unexpected > "$WORK/get.out" 2> "$WORK/get.err" || rc=$?
assert_eq 2 "$rc" 'task get rejects extra positional argument'
red_case 'task get rejects extra positional argument instead of discarding it'
assert_eq 'typed task' "$("$ORCHID_BIN" task get T001 title)" 'task get literal field accepting twin'
green_case 'task get exact arguments retain raw field value'

# This historically escaped the managed plugin namespace and deleted a sibling.
mkdir -p "$HOME/.orchid/plugins/hooks" "$HOME/.orchid/plugins/outside"
printf 'kind=hook\n' > "$HOME/.orchid/plugins/outside/plugin.conf"
printf 'preserve\n' > "$HOME/.orchid/plugins/outside/sentinel"
rc=0
out="$("$ORCHID_BIN" plugins remove ../outside 2>&1)" || rc=$?
assert_eq 2 "$rc" 'plugin remove rejects traversal name'
[ -f "$HOME/.orchid/plugins/outside/sentinel" ] || fail 'plugin traversal preserves outside target'
red_case 'plugin lifecycle rejects traversal before removal'
make_scratch EXTERNAL_PLUGINS
mkdir -p "$EXTERNAL_PLUGINS/escaped"
printf 'kind=hook\n' > "$EXTERNAL_PLUGINS/escaped/plugin.conf"
printf 'preserve\n' > "$EXTERNAL_PLUGINS/escaped/sentinel"
ln -s "$EXTERNAL_PLUGINS" "$HOME/.orchid/plugins/roles"
rc=0
out="$("$ORCHID_BIN" plugins remove escaped 2>&1)" || rc=$?
assert_eq 2 "$rc" 'plugin remove rejects external symlink parent'
[ -f "$EXTERNAL_PLUGINS/escaped/sentinel" ] || fail 'plugin symlink escape preserves external target'
red_case 'plugin lifecycle refuses physically external candidate'
rm "$HOME/.orchid/plugins/roles"
mkdir -p "$HOME/.orchid/plugins/hooks/owned"
printf 'kind=hook\n' > "$HOME/.orchid/plugins/hooks/owned/plugin.conf"
"$ORCHID_BIN" plugins remove owned >/dev/null || fail 'remove owned plugin'
[ ! -e "$HOME/.orchid/plugins/hooks/owned" ] || fail 'owned plugin was removed'
"$ORCHID_BIN" plugins remove owned >/dev/null || fail 'repeat owned removal is successful desired state'
green_case 'owned regular plugin removal accepts and repeat is a no-op'

# Idempotence acknowledges existing desired state only after original guards.
"$ORCHID_BIN" lessons add --scope repo --invalidate-when fixed 'repeat retirement' >/dev/null || fail 'add lesson'
"$ORCHID_BIN" lessons retire L001 --reason fixed >/dev/null || fail 'retire lesson'
cp .orchid/lessons.md "$WORK/lessons.before"
cp .orchid/journal.md "$WORK/journal.before"
rc=0
out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" lessons retire L001 --reason fixed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'repeat retirement retains epoch refusal'
rc=0
out="$("$ORCHID_BIN" lessons retire L001 2>&1)" || rc=$?
assert_eq 2 "$rc" 'repeat retirement retains required reason'
rc=0
"$ORCHID_BIN" lessons retire NOPE --reason fixed >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'retirement does not invent missing lesson success'
red_case 'retirement desired state never bypasses epoch/reason/missing guards'
"$ORCHID_BIN" lessons retire L001 --reason fixed >/dev/null || fail 'repeat retirement accepts desired state'
cmp "$WORK/lessons.before" .orchid/lessons.md || fail 'repeat retirement preserves lesson bytes'
cmp "$WORK/journal.before" .orchid/journal.md || fail 'repeat retirement preserves journal bytes'
green_case 'guarded repeated retirement accepts without another journal entry'

# The adapters operate only on successful output and existing domain readers.
export ORCHID_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/agent-read.sh"
printf '%s\n' "$raw_list" > "$WORK/list.raw"
orchid_agent_read_json task list "$WORK/list.raw" > "$WORK/list.json" || fail 'typed task list'
jq -e '.count == 1 and .total == 1 and .items[0] == {id:"T001",status:"pending",title:"typed task"}' "$WORK/list.json" >/dev/null || fail 'typed task list semantic rows/counts'
: > "$WORK/empty.raw"
orchid_agent_read_json task list "$WORK/empty.raw" > "$WORK/empty.json" || fail 'typed empty list'
jq -e '.items == [] and .count == 0 and .total == 0' "$WORK/empty.json" >/dev/null || fail 'explicit empty list data'
printf 'j-e1-T001-a1-deadbeef\tT001\timplementer\timplement\t1\torchid/claude\t0\tprepared\t-\t-\t60s\tpid:0\tfixture.log\n' > "$WORK/jobs.raw"
orchid_agent_read_json jobs ls "$WORK/jobs.raw" > "$WORK/jobs.json" || fail 'typed jobs list'
jq -e '.items[0].attempt == 1 and .items[0].pid == 0 and .default_fields == ["id","task","role","state"]' "$WORK/jobs.json" >/dev/null || fail 'typed job numbers and compact default fields'
python3 -c 'print("long guidance " + "x" * 20000)' > "$WORK/long.raw"
orchid_agent_read_json journal tail "$WORK/long.raw" -n 1 > "$WORK/long.json" || fail 'typed full journal stream'
jq -e '.bytes > 20000 and (.text|length) > 20000' "$WORK/long.json" >/dev/null || fail 'adapter keeps full text for central truncation/full retrieval'

# A context read must never initialize runtime or enforce job outcomes.
make_scratch EMPTY_REPO
mkdir -p "$EMPTY_REPO/.orchid/tasks"
orchid_agent_context_json "$EMPTY_REPO" > "$WORK/context-empty.json" || fail 'empty context'
[ ! -e "$EMPTY_REPO/.orchid/runtime" ] || fail 'context must not create missing runtime'
jq -e '.initialized == false and .epoch == null and .tasks.count == 0 and .jobs.count == 0 and .boundary == null' "$WORK/context-empty.json" >/dev/null || fail 'context explicit uninitialized/empty state'
cp -R .orchid/runtime "$WORK/runtime.before"
orchid_agent_context_json "$WORK" > "$WORK/context.json" || fail 'live context'
diff -r "$WORK/runtime.before" .orchid/runtime >/dev/null || fail 'context leaves runtime byte identical'
jq -e '.tasks.count == 1 and .tasks.by_status.pending == 1 and .jobs.count == 0' "$WORK/context.json" >/dev/null || fail 'context shares typed tasks/jobs counts'
# Numeric read/retention options are literal decimal values, not arithmetic.
for form in 'journal tail -n nope' 'jobs ls --interval nope' 'jobs gc --older-than-s nope' 'jobs gc --prepared-older-than-s nope'; do
  read -r -a probe <<<"$form"
  rc=0
  out="$("$ORCHID_BIN" "${probe[@]}" 2>&1)" || rc=$?
  assert_eq 2 "$rc" "invalid numeric option: $form"
  assert_match 'nope' "$out" "numeric error identifies value: $form"
done
printf -v arithmetic_payload 'BASH_VERSINFO[$(touch %q)]' "$WORK/arithmetic-sentinel"
rc=0
out="$("$ORCHID_BIN" journal tail -n "$arithmetic_payload" 2>&1)" || rc=$?
assert_eq 2 "$rc" 'journal count never executes caller arithmetic'
[ ! -e "$WORK/arithmetic-sentinel" ] || fail 'journal arithmetic payload must not execute'
red_case 'numeric options reject malformed literal values'
"$ORCHID_BIN" journal tail -n 008 >/dev/null || fail 'decimal journal count accepts leading zero'
"$ORCHID_BIN" jobs ls --interval 1 --tsv >/dev/null || fail 'positive job interval accepting twin'
"$ORCHID_BIN" jobs gc --older-than-s 0 --prepared-older-than-s 0 >/dev/null || fail 'zero retention accepting twin'
green_case 'numeric options accept their zero/positive/decimal valid twins'
# Read-only verbs must not initialize absent runtime just to locate its files.
make_scratch READ_REPO
mkdir -p "$READ_REPO/.orchid/tasks"
ORCHID_REPO="$READ_REPO" "$ORCHID_BIN" journal tail >/dev/null || fail 'empty journal tail read'
ORCHID_REPO="$READ_REPO" "$ORCHID_BIN" journal show --task NONE >/dev/null || fail 'empty journal show read'
ORCHID_REPO="$READ_REPO" "$ORCHID_BIN" jobs ls --tsv >/dev/null || fail 'empty jobs list read'
[ ! -e "$READ_REPO/.orchid/runtime" ] || fail 'raw jobs/journal reads preserve missing runtime'

# Combination rules are part of usage, not a mutation or policy refusal.
for form in 'lessons update L001' 'task handoff T001 --reason fixture' 'task handoff T001 --ack --clear --reason fixture' 'task advance T001 rework --waive-attempt --charge-attempt --reason fixture' 'jobs review-plan T001 --pin --repin'; do
  read -r -a probe <<<"$form"
  rc=0
  out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" "${probe[@]}" 2>&1)" || rc=$?
  assert_eq 2 "$rc" "option combination rejects before epoch: $form"
  assert_match 'usage|help' "$out" "option combination includes recovery: $form"
done
red_case 'missing alternatives and conflicting options reject before any mutation'
for form in 'lessons update L001 --confirm' 'task handoff T001 --ack --reason fixture' 'task advance T001 rework --waive-attempt --reason fixture' 'jobs review-plan T001 --pin'; do
  read -r -a probe <<<"$form"
  (orchid_cli_validate "${probe[@]}") || fail "accepting option combination: $form"
done
green_case 'same metadata combination checks accept one option with required reason'

# Standing boundaries retain kernel-owned operator routing; read inspection
# does not acknowledge, clear or charge the boundary.
"$ORCHID_BIN" run boundary set --kind operator-decision --task T001 --reason fixture >/dev/null || fail 'record operator boundary'
cp .orchid/runtime/boundary.json "$WORK/boundary.before"
orchid_agent_context_json "$WORK" > "$WORK/context-boundary.json" || fail 'boundary context'
jq -e '.boundary.kind == "operator-decision" and .operator_owned == true' "$WORK/context-boundary.json" >/dev/null || fail 'operator boundary ownership uses drive policy'
cmp "$WORK/boundary.before" .orchid/runtime/boundary.json || fail 'context does not charge or acknowledge boundary'
"$ORCHID_BIN" run boundary set --kind planning --reason fixture >/dev/null || fail 'record planning boundary'
orchid_agent_context_json "$WORK" > "$WORK/context-planning.json" || fail 'planning context'
surface="$(drive_orchestrator_surface "$WORK")"
expected_owned=true
drive_boundary_wakes_orchestrator planning '' "$surface" && expected_owned=false
jq -e --argjson expected "$expected_owned" '.operator_owned == $expected' "$WORK/context-planning.json" >/dev/null || fail 'context resolvability matches configured command surface'
echo 'AXI read validation, raw contracts, typed views, pure context, lifecycle ownership and guarded idempotence'
