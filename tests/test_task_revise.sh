#!/usr/bin/env bash
# RED: Unsafe or obsolete revisions refuse before changing durable state.
# GREEN: A changed contract restarts only its dependent executions and archives
# evidence while preserving merged code and unrelated work.
source "$(dirname "$0")/helpers.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
git commit -q --allow-empty -m root
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
git add orchid.config
git commit -q -m config
"$ORCHID_BIN" init >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'required revision fixture step failed'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/handoff.sh"
source "$REPO_ROOT/lib/drive.sh"
source "$REPO_ROOT/lib/schedule.sh"
source "$REPO_ROOT/lib/revision.sh"
export ORCHID_ENGINES_DIR="$WORK/engines"
mkdir -p "$ORCHID_ENGINES_DIR/fake"
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' > "$ORCHID_ENGINES_DIR/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$ORCHID_ENGINES_DIR/fake/run"
chmod 755 "$ORCHID_ENGINES_DIR/fake/run"
for id in A B C A-other; do
  "$ORCHID_BIN" task create "$id" "$id contract" >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
  "$ORCHID_BIN" task set "$id" verification_commands true >/dev/null
done
"$ORCHID_BIN" task set B depends_on A >/dev/null
"$ORCHID_BIN" task set C depends_on B >/dev/null
out="$("$ORCHID_BIN" task revise A --acceptance-criteria revised --reason fixture 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'revision cannot bypass the planning phase'
assert_match 'running or accepting run' "$out" 'planning-phase revision diagnosis'
red_case 'contract revision cannot bypass the initial planning gate'
"$ORCHID_BIN" run advance running --reason fixture >/dev/null || { fail 'required revision fixture step failed'; exit 1; }

# A real candidate, verification, review gate, arbitration, and merge for every
# task. All calls target this disposable repository, never Orchid's live run.
revision_complete() {
  local id="$1" text="$2" branch base candidate path
  branch="$("$ORCHID_BIN" task get "$id" branch)"
  base="$(git rev-parse orchid/integration)"
  path="$(drive_worktree_path "$ORCHID_REPO" "$id")"
  git worktree add -q -b "$branch" "$path" "$base" || return 1
  "$ORCHID_BIN" task set "$id" worktree "$path" >/dev/null || return 1
  "$ORCHID_BIN" task set "$id" base_sha "$base" >/dev/null || return 1
  "$ORCHID_BIN" task advance "$id" implementing >/dev/null || return 1
  printf '%s\n' "$text" > "$path/$id.txt"
  git -C "$path" add "$id.txt"
  git -C "$path" commit -q -m "$id implementation"
  candidate="$(git -C "$path" rev-parse HEAD)"
  "$ORCHID_BIN" task set "$id" candidate_sha "$candidate" >/dev/null || return 1
  "$ORCHID_BIN" task advance "$id" testing >/dev/null || return 1
  "$ORCHID_BIN" verify "$id" >/dev/null || return 1
  "$ORCHID_BIN" task advance "$id" reviewing >/dev/null || return 1
  plant_reviewer_envelope "$id"
  "$ORCHID_BIN" task advance "$id" arbitrating --reason fixture >/dev/null || return 1
  "$ORCHID_BIN" task arbitrate "$id" --result approve --reason fixture >/dev/null || return 1
  "$ORCHID_BIN" merge "$id" >/dev/null || return 1
}
for id in A B C A-other; do
  revision_complete "$id" "original $id" || { fail "initial completion $id"; exit 1; }
done
"$ORCHID_BIN" run advance accepting --reason fixture >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
cp .orchid/tasks/A-other.md "$WORK/unrelated.md"
cp .orchid/reviews/A-other-verify.log "$WORK/unrelated-verify.log"
cp .orchid/tasks/A.md "$WORK/original-A.md"
cp .orchid/reviews/A-verify.log "$WORK/original-verify.log"
original_branch="$(git rev-parse task/A)"

revision_snapshot() {
  git rev-parse orchid/integration
  git hash-object .orchid/tasks/*.md .orchid/reviews/* .orchid/roadmap.md .orchid/journal.md
}
revision_refuses() {
  local label="$1" pattern="$2" before out rc=0
  before="$(revision_snapshot)"
  out="$("$ORCHID_BIN" task revise A --acceptance-criteria revised --reason fixture 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label refuses"
  assert_match "$pattern" "$out" "$label diagnostic"
  assert_eq "$before" "$(revision_snapshot)" "$label preserves durable state and integration ref"
}

before="$(revision_snapshot)"
impact="$(ORCHID_EPOCH=stale "$ORCHID_BIN" task revise A --acceptance-criteria revised --reason fixture --dry-run)" || fail 'read-only impact without ownership'
assert_eq $'revision impact for A:\nA\nB\nC' "$impact" 'transitive impact excludes unrelated prefix task'
assert_eq "$before" "$(revision_snapshot)" 'dry-run changes no durable bytes'
out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" task revise A --acceptance-criteria revised --reason fixture 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'stale epoch refuses'
assert_match 'stale epoch' "$out" 'stale epoch diagnosis'
assert_eq "$before" "$(revision_snapshot)" 'stale epoch changes no durable bytes'
red_case 'stale ownership cannot revise while the impact preview remains observational'
green_case 'impact preview computes the transitive closure without taking ownership'

old_manifest="$("$ORCHID_BIN" jobs prepare C reviewer review --engine fake)" || { fail 'required revision fixture step failed'; exit 1; }
old_jid="$(jq -r .job_id "$old_manifest")"
cp "$old_manifest" "$WORK/old-manifest.json"
if ! revision_manifest_current "$ORCHID_REPO" "$old_manifest"; then
  jq '{task,contract_revision,execution_generation,contract_terms,input_revisions}' "$old_manifest"
  revision_terms .orchid/tasks/C.md
  revision_inputs "$ORCHID_REPO" C
  fail 'fresh prepared binding is current'
fi
"$ORCHID_BIN" task set B acceptance_criteria 'changed legacy input' >/dev/null
if revision_manifest_current "$ORCHID_REPO" "$old_manifest"; then fail 'input contract terms cannot drift under a prepared job'; fi
"$ORCHID_BIN" task set B acceptance_criteria '' >/dev/null
"$ORCHID_BIN" task set C verification_commands false >/dev/null
if revision_manifest_current "$ORCHID_REPO" "$old_manifest"; then fail 'own verification contract cannot drift under a prepared job'; fi
"$ORCHID_BIN" task set C verification_commands true >/dev/null
revision_manifest_current "$ORCHID_REPO" "$old_manifest" || fail 'unchanged restored terms match the prepared binding'
red_case 'prepared jobs reject changed own or input contract terms even in legacy generation one'
green_case 'the same prepared binding accepts matching current contract terms'
revision_refuses 'prepared dependent job' 'outstanding jobs'
touch -t 202001010000 "$old_manifest"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 --prepared-older-than-s 0 >/dev/null
[ ! -e "$old_manifest" ] || { fail 'prepared manifest retired before accepting-twin cases'; exit 1; }
red_case 'even an unlaunched dependent job prevents revision of its upstream contract'

git branch task/A-g2 orchid/integration
revision_refuses 'replacement branch collision' 'already exists'
git branch -D task/A-g2 >/dev/null
fm_set .orchid/tasks/B.md unresolved_objection 'a1: unresolved fixture objection'
revision_refuses 'standing objection' 'unresolved objection'
fm_set .orchid/tasks/B.md unresolved_objection ''
fm_set .orchid/tasks/B.md execution_generation '1+1'
revision_refuses 'malformed generation' 'invalid execution_generation'
fm_set .orchid/tasks/B.md execution_generation 1
red_case 'branch collisions, unresolved objection authority, and malformed versions refuse before publication'
fm_set .orchid/tasks/B.md execution_generation 999999
revision_refuses 'exhausted execution generation' 'execution generation exhausted'
fm_set .orchid/tasks/B.md execution_generation 1
fm_set .orchid/tasks/A.md contract_revision 999999
revision_refuses 'exhausted contract revision' 'contract revision exhausted'
fm_set .orchid/tasks/A.md contract_revision 1
mkdir -p .orchid/revisions/A-g2
printf 'historical marker\n' > .orchid/revisions/A-g2/marker
revision_refuses 'existing revision archive' 'revision archive.*already exists'
assert_eq 'historical marker' "$(cat .orchid/revisions/A-g2/marker)" 'archive collision preserves previous content'
rm .orchid/revisions/A-g2/marker
rmdir .orchid/revisions/A-g2 .orchid/revisions
red_case 'exhausted counters and existing archives cannot be overwritten by another revision'
"$ORCHID_BIN" task advance B blocked --reason 'fixture idle recovery' >/dev/null
"$ORCHID_BIN" task retry B --reason 'fixture resumed execution' >/dev/null
"$ORCHID_BIN" task advance B implementing >/dev/null
revision_refuses 'active affected execution' 'B is implementing'
"$ORCHID_BIN" task advance B blocked --reason 'fixture stopped before revision' >/dev/null
red_case 'an active affected task must return to an idle state before its upstream contract changes'


dirty_path="$WORK/dirty-root"
git worktree add -q "$dirty_path" task/A
"$ORCHID_BIN" task set A worktree "$dirty_path" >/dev/null
printf 'uncommitted fixture bytes\n' > "$dirty_path/uncommitted.txt"
revision_refuses 'uncommitted original worktree' 'uncommitted work'
rm "$dirty_path/uncommitted.txt"
git worktree remove "$dirty_path"
"$ORCHID_BIN" task set A worktree '' >/dev/null
git clone -q "$WORK/origin" "$WORK/foreign"
git -C "$WORK/foreign" checkout -q -b task/A "$original_branch"
"$ORCHID_BIN" task set A worktree "$WORK/foreign" >/dev/null
revision_refuses 'foreign original worktree' 'not.*registered|different repository'
"$ORCHID_BIN" task set A worktree '' >/dev/null
mkdir -p "$WORK/outside-revisions"
printf 'preserve\n' > "$WORK/outside-revisions/marker"
ln -s "$WORK/outside-revisions" .orchid/revisions
revision_refuses 'linked revision namespace' 'unsafe context input'
assert_eq preserve "$(cat "$WORK/outside-revisions/marker")" 'linked archive target untouched'
rm .orchid/revisions
red_case 'uncommitted or foreign worktrees and redirected archive namespaces cannot be consumed by revision'

before="$(revision_snapshot)"
out="$(ORCHID_ACTOR=tick-e1 "$ORCHID_BIN" task revise A --acceptance-criteria revised --reason fixture 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'orchestrator actor cannot revise its contract'
assert_match 'operator-owned' "$out" 'revision actor authority'
out="$("$ORCHID_BIN" task revise A --verification-commands true --reason fixture 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'unchanged contract cannot spend a generation'
assert_match 'changed acceptance criterion or verification command' "$out" 'unchanged contract diagnosis'
assert_eq "$before" "$(revision_snapshot)" 'actor and unchanged-contract refusals preserve state'
red_case 'orchestrator actors cannot redefine acceptance and no-op changes cannot reset execution budgets'

# A failed staging commit must not publish any restarted tasks or archives.
mkdir -p "$WORK/hooks"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/hooks/pre-commit"
chmod 755 "$WORK/hooks/pre-commit"
git config core.hooksPath "$WORK/hooks"
revision_refuses 'failed publication' '.*'
git config --unset core.hooksPath
[ ! -e .orchid/revisions/A-g2 ] || fail 'failed commit publishes no archive'
red_case 'failed durable commit leaves all task generations and evidence unchanged'

cp .orchid/tasks/A.md "$WORK/original-A.md"
live_manifest="$("$ORCHID_BIN" jobs prepare A-other reviewer review --engine fake)" || { fail 'required revision fixture step failed'; exit 1; }
live_jid="$(jq -r .job_id "$live_manifest")"
live_log="$(jq -r .log "$live_manifest")"
mkdir -p "$(dirname "$live_log")"
(
  exec 3>>"$live_log"
  printf 'before revision\n' >&3
  printf 'ready\n' > "$WORK/live-ready"
  for ((live_wait=0; live_wait<800; live_wait++)); do
    [ ! -e "$WORK/live-go" ] || break
    sleep 0.05
  done
  [ -e "$WORK/live-go" ] || exit 1
  printf 'after revision\n' >&3
) &
live_pid=$!
for ((live_wait=0; live_wait<100; live_wait++)); do
  [ ! -e "$WORK/live-ready" ] || break
  sleep 0.05
 done
[ -e "$WORK/live-ready" ] || { fail 'unrelated worker opened its log'; exit 1; }
jq --argjson pid "$live_pid" '.pid=$pid | .started_at=1' "$live_manifest" > "$WORK/live-manifest.json"
mv "$WORK/live-manifest.json" "$live_manifest"
plant_job_process_identity "$live_manifest"
assert_match "$live_jid.*running" "$("$ORCHID_BIN" jobs ls --tsv)" 'unrelated worker is running before revision'
"$ORCHID_BIN" task revise A --acceptance-criteria revised --reason 'integration exposed missing behavior' >/dev/null || { fail 'revision accepts idle graph'; exit 1; }

touch "$WORK/live-go"
wait "$live_pid" || fail 'unrelated worker finishes normally'
assert_eq $'before revision\nafter revision' "$(cat "$live_log")" 'unrelated worker keeps writing its original visible log across publication'
mkdir -p .orchid/runtime/exits
printf '0\n' > ".orchid/runtime/exits/$live_jid"
touch -t 202001010000 "$live_manifest" "$live_log" ".orchid/runtime/exits/$live_jid"
"$ORCHID_BIN" jobs gc --older-than-s 0 --prepared-older-than-s 0 >/dev/null
[ ! -e "$live_manifest" ] || fail 'completed unrelated fixture job is retired'
green_case 'an unrelated live worker retains its runtime file identity and log output during contract revision'

for id in A B C; do
  assert_eq pending "$("$ORCHID_BIN" task get "$id" status)" "$id restarted"
  assert_eq 2 "$("$ORCHID_BIN" task get "$id" execution_generation)" "$id new execution generation"
  assert_eq "task/$id-g2" "$("$ORCHID_BIN" task get "$id" branch)" "$id fresh branch"
  [ ! -e ".orchid/reviews/$id-verify.log" ] || fail "$id old verification withdrawn"
done
assert_eq 2 "$("$ORCHID_BIN" task get A contract_revision)" 'root contract revised'
assert_eq 1 "$("$ORCHID_BIN" task get B contract_revision)" 'dependent contract unchanged'
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" 'acceptance reopened for execution'
cmp "$WORK/original-A.md" .orchid/revisions/A-g2/tasks/A.md || fail 'old task archived byte-identical'
cmp "$WORK/original-verify.log" .orchid/revisions/A-g2/reviews/A-verify.log || fail 'old proof archived byte-identical'
cmp "$WORK/unrelated.md" .orchid/tasks/A-other.md || fail 'unrelated completed task preserved'
cmp "$WORK/unrelated-verify.log" .orchid/reviews/A-other-verify.log || fail 'unrelated prefix evidence preserved'
assert_eq "$original_branch" "$(git rev-parse task/A)" 'original branch preserved'
assert_eq 'original A' "$(git show orchid/integration:A.txt)" 'merged code preserved'
owned_branches="$(_orchid_in_run_branches "$ORCHID_REPO" orchid/integration)"
assert_match '^task/A$' "$owned_branches" 'archived execution branch remains run-owned'
green_case 'idle upstream revision restarts transitive dependents, preserves unrelated work and merged history, and archives superseded evidence'

# Replay a historical manifest as fault injection, then deliver its late result.
# Version binding must reject it even though it still names the same task ID.
cp "$WORK/old-manifest.json" "$old_manifest"
jq -n --arg id "$old_jid" '{contract:1,job_id:$id,task:"C",operation:"review",status:"ok",verdict:"approve",scope_complete:true,summary:"late old result"}' > ".orchid/runtime/spool/$old_jid.json"
out="$("$ORCHID_BIN" jobs reconcile)" || fail 'obsolete result quarantine'
assert_match 'obsolete-revision' "$out" 'old generation result refused'
[ ! -e .orchid/reviews/C-a1-reviewer.json ] || fail 'obsolete result becomes no current evidence'
touch -t 202001010000 "$old_manifest"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 --prepared-older-than-s 0 >/dev/null
red_case 'late results from the superseded generation cannot become current evidence'

for id in A B C; do
  revision_complete "$id" "revised $id" || { fail "replacement completion $id"; exit 1; }
done
manifest="$("$ORCHID_BIN" jobs prepare C reviewer review --engine fake)" || { fail 'required revision fixture step failed'; exit 1; }
jq -e '.contract_revision == 1 and .execution_generation == 2 and .input_revisions.B.execution_generation == 2' "$manifest" >/dev/null || fail 'job pins its task and upstream input versions'
green_case 'replacement generations pass the normal verification and merge lifecycle with pinned input revisions'

jid="$(jq -r .job_id "$manifest")"
candidate="$(jq -r .candidate_sha "$manifest")"
mkdir -p .orchid/runtime/exits
printf '0\n' > ".orchid/runtime/exits/$jid"
jq -n --arg id "$jid" --arg candidate "$candidate" '{contract:1,job_id:$id,task:"C",operation:"review",status:"ok",verdict:"approve",scope_complete:true,summary:"review",candidate_sha:$candidate,execution_generation:1}' > ".orchid/runtime/spool/$jid.json"
out="$("$ORCHID_BIN" jobs reconcile)" || fail 'mismatched adapter revision quarantine'
assert_match 'revision-mismatch' "$out" 'adapter cannot contradict its prepared generation'
red_case 'an adapter cannot relabel a current job result with an obsolete execution generation'
jq -n --arg id "$jid" --arg candidate "$candidate" '{contract:1,job_id:$id,task:"C",operation:"review",status:"ok",verdict:"approve",scope_complete:true,summary:"review",candidate_sha:$candidate}' > ".orchid/runtime/spool/$jid.json"
"$ORCHID_BIN" jobs reconcile >/dev/null || fail 'legacy adapter reply remains accepted'
bound_envelope=""
for evidence in .orchid/reviews/C-a1-reviewer*.json; do
  [ "$(jq -r .job_id "$evidence")" != "$jid" ] || bound_envelope="$evidence"
done
[ -n "$bound_envelope" ] || fail 'corrected reply is filed'
jq -e '.execution_generation == 2 and .contract_revision == 1 and .input_revisions.B.execution_generation == 2' "$bound_envelope" >/dev/null || fail 'kernel supplies trusted result binding'
green_case 'legacy adapters may omit additive fields and receive trusted task and input bindings from the kernel'

out="$("$ORCHID_BIN" task set A branch main 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'versioned branch cannot alias an operator branch'
"$ORCHID_BIN" task set A branch task/A-g2 >/dev/null || fail 'canonical branch repair remains available'
red_case 'versioned branch records cannot be redirected to another execution or operator branch'
green_case 'the canonical branch for the current execution generation remains admissible'
out="$("$ORCHID_BIN" task set A contract_revision 1 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'version fields cannot be forged with task set'
out="$("$ORCHID_BIN" task set A acceptance_criteria bypass 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'executed versioned contract cannot be edited in place'
red_case 'task set cannot forge versions or mutate an executed versioned contract in place'
green_case 'the earlier revision transaction is the accepting path for contract changes'

old_run="$(fm_get .orchid/roadmap.md run_id)"
# Existing run-new policy requires obsolete task branch names to be released.
# Delete only this fixture's branches after proving every commit is integrated.
for branch in task/A task/B task/C task/A-other task/A-g2 task/B-g2 task/C-g2; do
  git merge-base --is-ancestor "$branch" orchid/integration || fail "$branch fully integrated before fixture cleanup"
  git branch -D "$branch" >/dev/null
done
"$ORCHID_BIN" run advance blocked --reason 'fixture next run' >/dev/null || fail 'block fixture run'
"$ORCHID_BIN" run release-lease >/dev/null || fail 'release fixture ownership before rollover'
"$ORCHID_BIN" run new --reason 'retain revision history' >/dev/null || fail 'archive revised run'
[ -f ".orchid/runs/$old_run/revisions/A-g2/tasks/A.md" ] || fail 'new run retains original execution history'
[ ! -e .orchid/revisions ] || fail 'new run starts with a fresh revision namespace'
owned_branches="$(_orchid_in_run_branches "$ORCHID_REPO" orchid/integration)"
assert_match '^task/A$' "$owned_branches" 'past-run revision branches remain run-owned'
green_case 'run rollover archives revision history and retains ownership of historical execution branches'

# A pending task may have a clean recorded checkout before any review exists.
# RED: Dirty work refuses revision before the first review.
# GREEN: A clean recorded checkout survives revision without prior evidence.
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create T 'first execution' >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
"$ORCHID_BIN" task set T verification_commands true >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
"$ORCHID_BIN" run advance running --reason fixture >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
retained_path="$WORK/retained-T"
git worktree add -q -b task/T "$retained_path" orchid/integration || { fail 'required revision fixture step failed'; exit 1; }
printf 'retained work\n' > "$retained_path/T.txt"
git -C "$retained_path" add T.txt
git -C "$retained_path" commit -q -m 'retained work'
retained_head="$(git -C "$retained_path" rev-parse HEAD)"
"$ORCHID_BIN" task set T worktree "$retained_path" >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
[ ! -d .orchid/reviews ] || rmdir .orchid/reviews || { fail 'required revision fixture step failed'; exit 1; }
[ ! -e .orchid/reviews ] || fail 'first execution has no review namespace'
printf 'dirty\n' > "$retained_path/dirty.txt"
out="$("$ORCHID_BIN" task revise T --acceptance-criteria clarified --reason fixture 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail 'dirty first execution refuses revision'
assert_match 'uncommitted work' "$out" 'dirty first execution diagnostic'
rm "$retained_path/dirty.txt"
red_case 'uncommitted work prevents revision before the first review'
"$ORCHID_BIN" task revise T --acceptance-criteria clarified --reason fixture >/dev/null || { fail 'required revision fixture step failed'; exit 1; }
assert_eq "$retained_head" "$(git -C "$retained_path" rev-parse HEAD)" 'clean prior checkout retains its commit'
assert_eq 'task/T' "$(git -C "$retained_path" symbolic-ref --short HEAD)" 'clean prior checkout retains its branch'
assert_eq 'retained work' "$(cat "$retained_path/T.txt")" 'clean prior checkout retains its payload'
assert_eq '2' "$(fm_get .orchid/tasks/T.md execution_generation)" 'first execution can be revised without prior review evidence'
assert_eq 'task/T-g2' "$(fm_get .orchid/tasks/T.md branch)" 'first revision queues a fresh branch'
assert_eq '' "$(fm_get .orchid/tasks/T.md worktree)" 'replacement execution has no inherited checkout'
green_case 'clean recorded work survives revision before any review evidence exists'
[ "$FAILS" -eq 0 ]
