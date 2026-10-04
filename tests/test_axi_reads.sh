#!/usr/bin/env bash
# RED: Invalid admission, read side effects, escaping plugin paths and malformed
# numeric values are rejected or detected by the exercised fixtures.
# GREEN: Valid forms, pure reads, contained plugins and guarded idempotent
# repeats accept through the same checks without extra durable writes.
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

# Literal option-shaped text passes the semantic separator unchanged.
"$ORCHID_BIN" journal add -- --help >/dev/null || fail 'literal journal text after separator'
assert_eq --help "$(tail -n 1 .orchid/journal.md)" 'journal semantic separator is not stored as message text'
ORCHID_OUTPUT=json "$ORCHID_BIN" journal add -- --help >/dev/null || fail 'public literal journal text after separator'
assert_eq --help "$(tail -n 1 .orchid/journal.md)" 'public journal transport preserves literal help text'

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

# Journal labels bind only to their flat, owned index names. Refusal occurs
# before appending the authoritative journal or reading an escaped cache.
printf 'preserve\n' > "$WORK/outside"
cp "$WORK/outside" "$WORK/outside.before"
cp .orchid/journal.md "$WORK/index-journal.before"
rc=0
out="$("$ORCHID_BIN" journal add --task ../../../outside 'must refuse' 2>&1)" || rc=$?
assert_eq 2 "$rc" 'journal add rejects traversal label'
assert_match 'task' "$out" 'journal label error names the option'
cmp "$WORK/outside.before" "$WORK/outside" || fail 'journal traversal preserves outside file'
cmp "$WORK/index-journal.before" .orchid/journal.md || fail 'label refusal precedes journal-first append'
rc=0
"$ORCHID_BIN" journal show --task ../../../outside > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
assert_eq 2 "$rc" 'journal show rejects traversal label'
[ ! -s "$WORK/index-read.out" ] || fail 'journal traversal read reveals nothing'
red_case 'journal add/show reject escaped task labels without reads or publication'
"$ORCHID_BIN" journal add --task T001 'owned entry' >/dev/null || fail 'journal owned label accepting twin'
assert_match 'owned entry' "$("$ORCHID_BIN" journal show --task T001)" 'journal owned label reads its index'
green_case 'same journal namespace check accepts flat owned label for add and show'
make_scratch INDEX_OUTSIDE
printf 'secret sentinel\n' > "$INDEX_OUTSIDE/T001"
cp "$INDEX_OUTSIDE/T001" "$WORK/index-outside.before"
cp .orchid/journal.md "$WORK/index-journal.before"
mv .orchid/runtime/journal-index "$WORK/index-owned"
ln -s "$INDEX_OUTSIDE" .orchid/runtime/journal-index
for action in add show; do
  rc=0
  if [ "$action" = add ]; then
    "$ORCHID_BIN" journal add --task T001 'must refuse' > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
  else
    "$ORCHID_BIN" journal show --task T001 > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
  fi
  assert_eq 1 "$rc" "journal $action refuses external index parent"
  [ ! -s "$WORK/index-read.out" ] || fail "journal $action external parent reveals nothing"
done
cmp "$WORK/index-outside.before" "$INDEX_OUTSIDE/T001" || fail 'external index parent remains byte identical'
cmp "$WORK/index-journal.before" .orchid/journal.md || fail 'parent ownership refusal precedes journal-first append'
rm .orchid/runtime/journal-index
ln -s "$INDEX_OUTSIDE/missing-parent" .orchid/runtime/journal-index
rc=0
"$ORCHID_BIN" journal add --task T001 'must refuse dangling parent' > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
assert_eq 1 "$rc" 'journal refuses dangling index parent'
cmp "$WORK/index-journal.before" .orchid/journal.md || fail 'dangling parent refusal precedes journal-first append'
rm .orchid/runtime/journal-index
mv "$WORK/index-owned" .orchid/runtime/journal-index
cp .orchid/runtime/journal-index/T001 "$WORK/index-file.before"
rm .orchid/runtime/journal-index/T001
ln -s "$INDEX_OUTSIDE/T001" .orchid/runtime/journal-index/T001
for action in add show; do
  rc=0
  if [ "$action" = add ]; then
    "$ORCHID_BIN" journal add --task T001 'must refuse' > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
  else
    "$ORCHID_BIN" journal show --task T001 > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
  fi
  assert_eq 1 "$rc" "journal $action refuses symlink final index"
  [ ! -s "$WORK/index-read.out" ] || fail "journal $action final symlink reveals nothing"
done
cmp "$WORK/index-outside.before" "$INDEX_OUTSIDE/T001" || fail 'external symlink target remains byte identical'
cmp "$WORK/index-journal.before" .orchid/journal.md || fail 'final ownership refusal precedes journal-first append'
red_case 'journal add/show reject symlink index parent and final file before publication or reads'
rm .orchid/runtime/journal-index/T001
mkdir .orchid/runtime/journal-index/T001
rc=0
"$ORCHID_BIN" journal add --task T001 'must refuse directory' > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
assert_eq 1 "$rc" 'journal refuses nonregular final index'
cmp "$WORK/index-journal.before" .orchid/journal.md || fail 'nonregular final index refusal precedes journal-first append'
rmdir .orchid/runtime/journal-index/T001
cp "$WORK/index-file.before" .orchid/runtime/journal-index/T001
"$ORCHID_BIN" journal add --task T001 'regular file restored' >/dev/null || fail 'regular index restore accepting twin'
assert_match 'regular file restored' "$("$ORCHID_BIN" journal show --task T001)" 'restored owned index is readable'
green_case 'same journal namespace gate accepts restored regular owned parent and file'
# A missing-path canonicalizer must not bless dangling owned ancestors.
cp .orchid/journal.md "$WORK/ancestor-journal.before"
for ancestor in runtime state; do
  if [ "$ancestor" = runtime ]; then
    mv .orchid/runtime "$WORK/runtime-owned"
    ln -s "$INDEX_OUTSIDE/missing-runtime" .orchid/runtime
  else
    mv .orchid "$WORK/state-owned"
    ln -s "$INDEX_OUTSIDE/missing-state" .orchid
  fi
  for action in add show; do
    rc=0
    if [ "$action" = add ]; then
      "$ORCHID_BIN" journal add --task T001 'must refuse ancestor' > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
    else
      "$ORCHID_BIN" journal show --task T001 > "$WORK/index-read.out" 2> "$WORK/index-read.err" || rc=$?
    fi
    assert_eq 1 "$rc" "journal $action refuses dangling $ancestor parent"
    [ ! -s "$WORK/index-read.out" ] || fail "journal $action dangling $ancestor reveals nothing"
  done
  if [ "$ancestor" = runtime ]; then
    cmp "$WORK/ancestor-journal.before" .orchid/journal.md || fail 'dangling runtime refusal precedes journal mutation'
    rm .orchid/runtime
    mv "$WORK/runtime-owned" .orchid/runtime
  else
    cmp "$WORK/ancestor-journal.before" "$WORK/state-owned/journal.md" || fail 'dangling state refusal preserves journal'
    rm .orchid
    mv "$WORK/state-owned" .orchid
  fi
done
red_case 'journal ownership rejects dangling state and runtime ancestors before append or reads'
"$ORCHID_BIN" journal add --task T001 'owned ancestors restored' >/dev/null || fail 'restored ancestor accepting twin'
assert_match 'owned ancestors restored' "$("$ORCHID_BIN" journal show --task T001)" 'restored owned ancestors permit indexed reads'
green_case 'same ancestor gate accepts restored owned state/runtime directories'


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
# Ambient context may inspect a project without executing/trusting its code.
# Every displayed/delegated project input must be owned before any read. Use
# fake-sensitive data, never credentials, and exercise the public error channel.
context_secret='owned-context-fixture-sensitive'
if [ ! -e .orchid/roadmap.md ]; then
  printf '%s\n' '---' 'run_id: context-owned' 'run_status: active' '---' > .orchid/roadmap.md
fi
mkdir -p "$WORK/context-outside" .orchid/runtime/jobs .orchid/runtime/logs \
  .orchid/runtime/exits .orchid/runtime/spool .orchid/runtime/answers \
  .orchid/plugins/engines/claude
printf '{"kind":"operator-decision","token":"%s"}\n' "$context_secret" > "$WORK/context-outside/secret.json"
printf '%s\n' '---' 'id: T001' "title: $context_secret" 'status: pending' \
  "run_id: $context_secret" 'run_status: active' '---' > "$WORK/context-outside/secret.md"
printf 'role.orchestrator=%s\n' "$context_secret" > "$WORK/context-outside/secret.config"
cp "$WORK/context-outside/secret.md" "$WORK/context-outside/roadmap.md"
printf '{"job_id":"%s","task":"T001","pid":0}\n' "$context_secret" > "$WORK/context-outside/secret-job.json"
printf 'name=claude\nkind=engine\nversion=1.0.0\nentrypoint=run\ncommand_surface=soft\n' \
  > .orchid/plugins/engines/claude/plugin.conf
printf '#!/bin/sh\nexit 0\n' > .orchid/plugins/engines/claude/run
chmod 755 .orchid/plugins/engines/claude/run
cp -R "$WORK/context-outside" "$WORK/context-outside.before"

context_unsafe_read() {
  local label="$1" verb form rc rendered html_args
  for form in context status status-html; do
    verb="$form"; html_args=()
    if [ "$form" = status-html ]; then verb=status; html_args=(--html); fi
    rc=0
    ORCHID_OUTPUT=json "$ORCHID_BIN" "$verb" ${html_args[@]+"${html_args[@]}"} --json \
      > "$WORK/context-unsafe-$verb.out" 2> "$WORK/context-unsafe-$verb.err" || rc=$?
    assert_eq 1 "$rc" "$label public $verb ownership refusal"
    rendered="$(cat "$WORK/context-unsafe-$verb.out" "$WORK/context-unsafe-$verb.err")"
    assert_match 'unsafe context input' "$rendered" "$label public $verb diagnosis"
    if printf '%s' "$rendered" | grep -F -- "$context_secret" >/dev/null; then
      fail "$label public $verb must not expose linked contents"
    fi
    jq -e 'has("error") and .kernel_exit == 1 and (has("tasks") | not) and (has("jobs") | not)' \
      "$WORK/context-unsafe-$verb.out" >/dev/null || fail "$label unsafe state is unavailable, never an empty list"
  done
}

context_owned_read() {
  local label="$1" verb
  for verb in context status; do
    ORCHID_OUTPUT=json "$ORCHID_BIN" "$verb" --json \
      > "$WORK/context-owned-$verb.json" || fail "$label public $verb owned accepting twin"
    jq -e '.tasks.count == 1 and .tasks.items[0].id == "T001" and .run != null' \
      "$WORK/context-owned-$verb.json" >/dev/null || fail "$label public $verb typed owned state"
  done
}

for context_target in .orchid/roadmap.md .orchid/journal.md .orchid/runtime/epoch \
  .orchid/runtime/lease.json .orchid/runtime/answers/context-owned.question \
  .orchid/runtime/answers/context-owned.choices .orchid/runtime/answers/context-owned.answer \
  .orchid/runtime/boundary.json .orchid/tasks/T001.md \
  .orchid/runtime/engines.json .orchid/runtime/jobs/context-owned.json \
  orchid.config .orchid/plugins/engines/claude/plugin.conf; do
  context_had_original=0
  if [ -e "$context_target" ]; then
    mv "$context_target" "$WORK/context-owned-original"; context_had_original=1
  fi
  case "$context_target" in
    *.md) context_outside="$WORK/context-outside/secret.md" ;;
    */jobs/*) context_outside="$WORK/context-outside/secret-job.json" ;;
    orchid.config|*/plugin.conf) context_outside="$WORK/context-outside/secret.config" ;;
    *) context_outside="$WORK/context-outside/secret.json" ;;
  esac
  ln -s "$context_outside" "$context_target"
  context_unsafe_read "linked final $context_target"
  rm "$context_target"
  [ "$context_had_original" -eq 0 ] || mv "$WORK/context-owned-original" "$context_target"
  context_owned_read "restored final $context_target"
done
red_case 'public context and status refuse every linked displayed or delegated project file without leaking fake sensitive data'
green_case 'the same final-file ownership gates accept owned regular restored inputs'

for context_parent in .orchid .orchid/tasks .orchid/runtime \
  .orchid/runtime/jobs .orchid/runtime/logs .orchid/runtime/answers \
  .orchid/plugins/engines/claude; do
  mv "$context_parent" "$WORK/context-owned-parent"
  ln -s "$WORK/context-outside" "$context_parent"
  context_unsafe_read "linked parent $context_parent"
  rm "$context_parent"
  ln -s "$WORK/context-nonexistent-parent" "$context_parent"
  context_unsafe_read "dangling parent $context_parent"
  rm "$context_parent"
  mv "$WORK/context-owned-parent" "$context_parent"
  context_owned_read "restored parent $context_parent"
done
red_case 'public context and status reject linked and dangling relevant ancestors before secondary readers'
green_case 'the same ancestor ownership gates accept restored owned directories'

printf '{"job_id":"context-owned","task":"T001","role":"implementer","operation":"implement","pid":0,"log":""}\n' \
  > .orchid/runtime/jobs/context-owned.json
cp .orchid/runtime/jobs/context-owned.json "$WORK/context-job.before"
jq '.task = "../../../context-outside/secret"' "$WORK/context-job.before" > .orchid/runtime/jobs/context-owned.json
context_unsafe_read 'escaping job task reference'
jq --arg log "$WORK/context-outside/secret.md" '.log = $log' "$WORK/context-job.before" > .orchid/runtime/jobs/context-owned.json
context_unsafe_read 'outside job log reference'
cp "$WORK/context-job.before" .orchid/runtime/jobs/context-owned.json
context_owned_read 'owned job reference'
red_case 'delegated jobs reader receives only flat owned task identities and runtime log paths'
green_case 'existing jobs ls strict accepts the restored owned reference twin'

cp -R .orchid "$WORK/context-state.before"
context_owned_read 'owned observation purity'
diff -r "$WORK/context-state.before" .orchid >/dev/null || fail 'owned context/status never write runtime or durable state'
diff -r "$WORK/context-outside.before" "$WORK/context-outside" >/dev/null || fail 'rejected context/status never write externally linked fixture state'
rc=0
orchid_agent_read_json unhandled '' "$WORK/empty.raw" >/dev/null || rc=$?
assert_eq 2 "$rc" 'unhandled adapter differs from a recognized unsafe read failure'
green_case 'context/status preserve all owned state and adapter failure contract remains explicit'

# An owned configuration file is still untrusted data for arithmetic. The
# empty-job loop used to evaluate this literal as Bash and create the sentinel.
context_config_had_original=0
if [ -e orchid.config ]; then
  mv orchid.config "$WORK/context-config.original"; context_config_had_original=1
fi
mv .orchid/runtime/jobs/context-owned.json "$WORK/context-empty-jobs.original"
printf -v context_arithmetic_payload 'BASH_VERSINFO[$(touch %q)]' "$WORK/context-arithmetic-sentinel"
printf 'stall_minutes=%s\n' "$context_arithmetic_payload" > orchid.config
for context_verb in context status; do
  rc=0
  ORCHID_OUTPUT=json "$ORCHID_BIN" "$context_verb" --json \
    > "$WORK/context-numeric-$context_verb.out" 2> "$WORK/context-numeric-$context_verb.err" || rc=$?
  assert_eq 1 "$rc" "$context_verb refuses config arithmetic before an empty job loop"
  assert_match 'stall_minutes' "$(cat "$WORK/context-numeric-$context_verb.out" "$WORK/context-numeric-$context_verb.err")" 'config numeric refusal identifies key'
  [ ! -e "$WORK/context-arithmetic-sentinel" ] || fail 'context config must never execute arithmetic input'
done
red_case 'owned project config is literal data before delegated jobs arithmetic, even without live jobs'
printf 'stall_minutes=008\n' > orchid.config
context_owned_read 'literal decimal stall configuration'
rm orchid.config
[ "$context_config_had_original" -eq 0 ] || mv "$WORK/context-config.original" orchid.config
mv "$WORK/context-empty-jobs.original" .orchid/runtime/jobs/context-owned.json
green_case 'the same numeric gate accepts literal decimal configuration with leading zero'

# Native callbacks use ambient context and discard failed context. Prove the
# underlying ambient command returns no linked body even before host wrapping.
mv .orchid/runtime/boundary.json "$WORK/context-ambient-boundary.original"
ln -s "$WORK/context-outside/secret.json" .orchid/runtime/boundary.json
rc=0
ORCHID_OUTPUT=json "$ORCHID_BIN" context --ambient --json \
  > "$WORK/context-ambient.out" 2> "$WORK/context-ambient.err" || rc=$?
assert_eq 1 "$rc" 'ambient context refuses unsafe existing project state'
if cat "$WORK/context-ambient.out" "$WORK/context-ambient.err" | grep -F -- "$context_secret" >/dev/null; then
  fail 'ambient context must not emit linked fake-sensitive content'
fi
rm .orchid/runtime/boundary.json
mv "$WORK/context-ambient-boundary.original" .orchid/runtime/boundary.json
red_case 'ambient context fails closed without linked sensitive body'
ORCHID_OUTPUT=json "$ORCHID_BIN" context --ambient --json > "$WORK/context-ambient-owned.json" || fail 'owned ambient accepting twin'
jq -e '.tasks.count == 1' "$WORK/context-ambient-owned.json" >/dev/null || fail 'owned ambient typed context'
green_case 'restored owned ambient state remains available'

# All jobs numeric configuration uses the same literal decimal admission.
# Empty loops must still reject malformed values, not silently accept them.
mv .orchid/runtime/jobs/context-owned.json "$WORK/numeric-empty-jobs.original"
context_config_had_original=0
if [ -e orchid.config ]; then
  mv orchid.config "$WORK/numeric-config.original"; context_config_had_original=1
fi
for numeric_form in 'stall_minutes ls --tsv' 'timeout_minutes check' \
  'cpu_stall_min_s check' 'spool_max_bytes reconcile' 'gc_older_than_s gc'; do
  read -r -a numeric_probe <<< "$numeric_form"
  numeric_key="${numeric_probe[0]}"
  printf '%s=%s\n' "$numeric_key" "$context_arithmetic_payload" > orchid.config
  rc=0
  out="$("$ORCHID_BIN" jobs "${numeric_probe[@]:1}" 2>&1)" || rc=$?
  assert_eq 1 "$rc" "$numeric_key rejects arithmetic input before empty loop"
  assert_match "$numeric_key" "$out" 'numeric configuration refusal names its key'
  [ ! -e "$WORK/context-arithmetic-sentinel" ] || fail "$numeric_key must never execute arithmetic input"
  printf '%s=9999999999999999999\n' "$numeric_key" > orchid.config
  rc=0
  out="$("$ORCHID_BIN" jobs "${numeric_probe[@]:1}" 2>&1)" || rc=$?
  assert_eq 1 "$rc" "$numeric_key refuses decimal overflow before processing"
  for numeric_value in 0 00 008 000000000000000008; do
    printf '%s=%s\n' "$numeric_key" "$numeric_value" > orchid.config
    "$ORCHID_BIN" jobs "${numeric_probe[@]:1}" >/dev/null || fail "$numeric_key accepts literal decimal $numeric_value"
  done
done
for numeric_form in 'stall_minutes ls --tsv' 'timeout_minutes check'; do
  read -r -a numeric_probe <<< "$numeric_form"
  numeric_key="${numeric_probe[0]}"
  printf '%s=153722867280912931\n' "$numeric_key" > orchid.config
  rc=0
  "$ORCHID_BIN" jobs "${numeric_probe[@]:1}" > "$WORK/minutes-range.out" 2>&1 || rc=$?
  assert_eq 1 "$rc" "$numeric_key multiplication overflow refuses"
  printf '%s=153722867280912930\n' "$numeric_key" > orchid.config
  "$ORCHID_BIN" jobs "${numeric_probe[@]:1}" >/dev/null || fail "$numeric_key maximum safe minute accepting twin"
done
rm orchid.config
[ "$context_config_had_original" -eq 0 ] || mv "$WORK/numeric-config.original" orchid.config
mv "$WORK/numeric-empty-jobs.original" .orchid/runtime/jobs/context-owned.json
red_case 'all five numeric jobs configuration keys refuse expression and range inputs before empty processing'
green_case 'same numeric gates accept zero, leading-zero decimal and maximum-safe minute twins on Bash 3.2'

# Redundant repository suffixes are ordinary owned paths, not an unbounded
# dirname walk. The timeout makes the original // infinite loop causal.
python3 - "$REPO_ROOT" "$WORK" "$HOME" <<'PYPROBE' || fail 'owned repository slash suffixes must terminate with the same context'
import json,os,subprocess,sys
root,repo,home=sys.argv[1:]
for suffix in ('','/','//','///'):
    env=os.environ.copy();env.update(ORCHID_REPO=repo+suffix,HOME=home,ORCHID_OUTPUT='json')
    for verb in ('context','status'):
        result=subprocess.run([root+'/bin/orchid',verb,'--json'],env=env,text=True,capture_output=True,timeout=10)
        assert result.returncode==0,(suffix,verb,result.stderr)
        data=json.loads(result.stdout)
        assert data['tasks']['count']==1,(suffix,verb,data)
PYPROBE
green_case 'owned repository paths with zero or multiple trailing slashes terminate and retain typed context'

# HTML output is an owned runtime file, never durable state or an external
# write destination. Exercise the direct raw path and public pre-cache path.
context_config_had_original=0
if [ -e orchid.config ]; then
  mv orchid.config "$WORK/html-config.original"; context_config_had_original=1
fi
printf 'owned output sentinel\n' > "$WORK/context-outside/status-sentinel"
cp "$WORK/context-outside/status-sentinel" "$WORK/html-sentinel.before"
ln -s "$WORK/context-outside/status-sentinel" .orchid/runtime/linked-status.html
mkdir .orchid/runtime/status-directory
for html_target in "$WORK/context-outside/status-sentinel" '../context-outside/status-sentinel' \
  journal.md runtime/../journal.md runtime//status.html runtime/linked-status.html runtime/status-directory; do
  printf 'status_page=%s\n' "$html_target" > orchid.config
  for html_channel in raw json; do
    rc=0
    ORCHID_OUTPUT="$html_channel" "$ORCHID_BIN" status --html \
      > "$WORK/html-refused.out" 2> "$WORK/html-refused.err" || rc=$?
    assert_eq 1 "$rc" "$html_channel unsafe HTML destination refuses"
    assert_match 'unsafe status_page' "$(cat "$WORK/html-refused.out" "$WORK/html-refused.err")" 'HTML output refusal identifies setting'
    cmp "$WORK/html-sentinel.before" "$WORK/context-outside/status-sentinel" || fail 'HTML output refusal preserves external bytes'
  done
done
printf 'status_page=%s\n' "$WORK/context-outside/status-sentinel" > orchid.config
rc=0
ORCHID_OUTPUT=json "$ORCHID_BIN" status --html --request-id unsafe-html-destination \
  > "$WORK/html-cache.out" 2> "$WORK/html-cache.err" || rc=$?
assert_eq 1 "$rc" 'unsafe HTML refuses before optional receipt'
[ ! -e "$HOME/.orchid/requests" ] || fail 'unsafe HTML destination must not create request state'
rm .orchid/runtime/linked-status.html
rmdir .orchid/runtime/status-directory
for html_target in runtime/status.html "$WORK/.orchid/runtime/status-absolute.html"; do
  printf 'status_page=%s\n' "$html_target" > orchid.config
  for html_channel in raw json; do
    ORCHID_OUTPUT="$html_channel" "$ORCHID_BIN" status --html \
      > "$WORK/html-owned.out" || fail "$html_channel owned HTML output accepts"
  done
done
[ -f .orchid/runtime/status.html ] && [ -f .orchid/runtime/status-absolute.html ] || fail 'owned relative/absolute HTML files exist'
rm orchid.config
[ "$context_config_had_original" -eq 0 ] || mv "$WORK/html-config.original" orchid.config
red_case 'HTML direct and public pre-cache gates refuse external, durable, aliased and unowned targets before writes'
green_case 'same HTML output gate accepts regular relative and absolute owned runtime paths'

echo 'AXI read validation, raw contracts, typed views, pure context, lifecycle ownership and guarded idempotence'
