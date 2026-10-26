#!/usr/bin/env bash
# RED: Invalid or unauthorized rewrites preserve every durable preimage.
# GREEN: Replanning versions the old/new graph impact and revalidates retained commits.
source "$(dirname "$0")/helpers.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/graph-replan.sh"
_graph_revision_load
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf 'baseline\n' > app.txt
git add app.txt
git commit -q -m baseline
"$ORCHID_BIN" init >/dev/null || { fail 'initialize replan fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'replan control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
for id in A B; do "$ORCHID_BIN" task create "$id" "$id source" >/dev/null || { fail 'create source'; exit 1; }; done
for id in V W U; do "$ORCHID_BIN" task create "$id" "$id verifier" --archetype review >/dev/null || { fail 'create report'; exit 1; }; done
"$ORCHID_BIN" task set B depends_on A >/dev/null
"$ORCHID_BIN" task set V verifies A >/dev/null
"$ORCHID_BIN" task set W verifies V >/dev/null
"$ORCHID_BIN" task set A output_contract '{"contract":1}' >/dev/null
# Fixture declarations precede graph adoption, matching an existing legacy run.
"$ORCHID_BIN" run advance running --reason fixture >/dev/null || { fail 'start fixture'; exit 1; }
candidate="$(git rev-parse orchid/integration)"
for id in A V W; do
  fm_set ".orchid/tasks/$id.md" base_sha "$candidate"
  fm_set ".orchid/tasks/$id.md" candidate_sha "$candidate"
done
cp .orchid/tasks/U.md "$WORK/unrelated.md"
snapshot_state() { git rev-parse orchid/integration; git hash-object .orchid/tasks/*.md .orchid/roadmap.md .orchid/requirements.md .orchid/journal.md; }
refuse_replan() {
  local label="$1" before rc=0
  shift
  before="$(snapshot_state)"
  graph_replan_command "$ORCHID_REPO" "$@" > "$WORK/refusal.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label refuses"
  assert_eq "$before" "$(snapshot_state)" "$label preserves durable state"
}
printf '{"A":{"depends_on":"W"},"V":{"verifies":"A"},"W":{"verifies":"V"}}\n' > "$WORK/cycle.json"
refuse_replan 'milestone cycle' --patch "$WORK/cycle.json" --reason fixture
printf '{"A":{"execution_generation":2}}\n' > "$WORK/runtime.json"
refuse_replan 'kernel metadata patch' --patch "$WORK/runtime.json" --reason fixture
printf '{"NEW":{"archetype":"missing"}}\n' > "$WORK/new.json"
refuse_replan 'unknown new-node archetype' --patch "$WORK/new.json" --reason fixture
printf '{"NEW":{"verifies":"A"}}\n' > "$WORK/default-verifier.json"
refuse_replan 'default code outcome cannot be a verifier' --patch "$WORK/default-verifier.json" --reason fixture
fm_set .orchid/tasks/A.md risk_tier high
printf '{"A":{"risk_tier":"low"}}\n' > "$WORK/downgrade.json"
refuse_replan 'risk downgrade' --patch "$WORK/downgrade.json" --reason fixture
fm_set .orchid/tasks/A.md risk_tier low
printf '{"V":{"verifies":"A"},"W":{"verifies":"V","acceptance_criteria":"nested acceptance"}}\n' > "$WORK/change.json"
ORCHID_ACTOR=orchestrator refuse_replan 'actor authority' --patch "$WORK/change.json" --reason fixture
red_case 'cycles runtime metadata unknown IDs risk downgrades and non-operator rewrites refuse before publication'

# An editor can change a contract after planning but before common publication
# captures its preimages. The graph plan must bind the earlier input snapshot.
saved_publish="$(declare -f _graph_revision_publish)"
eval "$(declare -f _graph_revision_publish | sed '1s/_graph_revision_publish/_graph_revision_publish_original/')"
_graph_revision_publish() {
  fm_set "$1/.orchid/tasks/W.md" acceptance_criteria 'foreign editor change'
  _graph_revision_publish_original "$@"
}
old_criteria="$(fm_get .orchid/tasks/W.md acceptance_criteria)"
before_head="$(git rev-parse orchid/integration)"
rc=0; graph_replan_command "$ORCHID_REPO" --patch "$WORK/change.json" --reason 'planning input race' > "$WORK/editor-race.log" 2>&1 || rc=$?
eval "$saved_publish"
[ "$rc" -ne 0 ] || fail 'foreign edit invalidates the prepared graph plan'
assert_eq "$before_head" "$(git rev-parse orchid/integration)" 'stale plan never publishes a commit'
assert_eq 'foreign editor change' "$(fm_get .orchid/tasks/W.md acceptance_criteria)" 'foreign edit is preserved'
fm_set .orchid/tasks/W.md acceptance_criteria "$old_criteria"
red_case 'a graph plan cannot silently incorporate contracts edited after its input snapshot'

export ORCHID_ENGINES_DIR="$WORK/engines"
mkdir -p "$ORCHID_ENGINES_DIR/fake"
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' > "$ORCHID_ENGINES_DIR/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$ORCHID_ENGINES_DIR/fake/run"
chmod 755 "$ORCHID_ENGINES_DIR/fake/run"
legacy_manifest="$("$ORCHID_BIN" jobs prepare U reviewer review --engine fake)" || { fail 'prepare legacy adoption job'; exit 1; }
cp "$legacy_manifest" "$WORK/legacy-manifest.json"
printf '{}\n' > "$WORK/unchanged.json"
refuse_replan 'legacy prepared job prevents adoption' --patch "$WORK/unchanged.json" --reason adoption
assert_match 'outstanding jobs' "$(cat "$WORK/refusal.log")" 'adoption checks every legacy execution'
touch -t 202001010000 "$legacy_manifest"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 --prepared-older-than-s 0 >/dev/null || { fail 'retire prepared legacy job'; exit 1; }
red_case 'declared but disabled graphs cannot adopt while an unrelated legacy job is prepared'
graph_replan_command "$ORCHID_REPO" --patch "$WORK/unchanged.json" --reason adoption > "$WORK/adopt.log" 2>&1 || { fail 'adopt valid graph'; cat "$WORK/adopt.log"; exit 1; }
assert_eq 1 "$(fm_get .orchid/roadmap.md graph_contract)" 'explicit replan adopts graph mode'
for id in A B V W U; do
  assert_eq 2 "$(fm_version ".orchid/tasks/$id.md" execution_generation)" 'legacy adoption invalidates every execution'
done
assert_eq testing "$(fm_get .orchid/tasks/A.md status)" 'code checkpoint reopens mechanical verification'
assert_eq reviewing "$(fm_get .orchid/tasks/W.md status)" 'report checkpoint reopens fresh review'
assert_eq "$candidate" "$(fm_get .orchid/tasks/A.md candidate_sha)" 'same commit is retained as lineage'
assert_eq '' "$(fm_get .orchid/tasks/A.md worktree)" 'new generation never adopts old writable checkout'
test -f .orchid/revisions/graph-p1/old.json || { fail 'old snapshot archived'; cat "$WORK/adopt.log"; rg --files .orchid/revisions; git ls-tree -r --name-only orchid/integration -- .orchid/revisions; }
test -f .orchid/revisions/graph-p1/requirements.md || fail 'old requirements archived'
green_case 'valid legacy adoption checkpoints candidates and starts fresh context for all nodes'
rc=0; graph_manifest_current "$ORCHID_REPO" "$WORK/legacy-manifest.json" > "$WORK/stale-legacy.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'pre-adoption legacy manifest cannot be reused in graph mode'

# A later leaf change versions ancestors and input consumers, preserving U.
cp .orchid/tasks/U.md "$WORK/unrelated.md"
printf '{"W":{"acceptance_criteria":"second nested acceptance"}}\n' > "$WORK/change2.json"
before="$(snapshot_state)"
ORCHID_EPOCH=stale graph_replan_command "$ORCHID_REPO" --patch "$WORK/change2.json" --reason preview --dry-run > "$WORK/preview.json" || fail 'read-only preview ignores stale epoch'
assert_eq "$before" "$(snapshot_state)" 'preview has no durable effects'
jq -e '.nodes | keys == ["A","B","V","W"]' "$WORK/preview.json" >/dev/null || fail 'nested ancestor/input closure'
ORCHID_EPOCH=stale refuse_replan 'stale epoch' --patch "$WORK/change2.json" --reason fixture
red_case 'mutation needs the current epoch even when its pure preview is readable'
graph_replan_command "$ORCHID_REPO" --patch "$WORK/change2.json" --reason nested > "$WORK/nested.log" 2>&1 || { fail 'nested rewrite'; cat "$WORK/nested.log"; exit 1; }
for id in A V W; do assert_eq 3 "$(fm_version ".orchid/tasks/$id.md" contract_revision)" 'nested contract revision reaches every required ancestor once'; done
assert_eq 2 "$(fm_version .orchid/tasks/B.md contract_revision)" 'ordinary consumer contract unchanged'
assert_eq 3 "$(fm_version .orchid/tasks/B.md execution_generation)" 'ordinary consumer execution invalidated'
cmp -s .orchid/tasks/U.md "$WORK/unrelated.md" || fail 'unrelated node byte preservation'
green_case 'nested change versions ancestors once and invalidates their consumers only'

# Removing an input must not spare the execution that previously consumed it.
printf '{"B":{"depends_on":""}}\n' > "$WORK/remove.json"
graph_replan_command "$ORCHID_REPO" --patch "$WORK/remove.json" --reason removal > "$WORK/remove.log" 2>&1 || { fail 'edge removal rewrite'; cat "$WORK/remove.log"; exit 1; }
assert_eq '' "$(fm_get .orchid/tasks/B.md depends_on)" 'removed input is persisted'
assert_eq 4 "$(fm_version .orchid/tasks/B.md execution_generation)" 'removed-edge consumer still invalidated'
green_case 'edge removal follows the union of old and new graph inputs'

fm_set .orchid/tasks/A.md repair_obligation '{"contract":1,"source":{"task":"A"}}'
fm_set .orchid/tasks/A.md repair_rounds 2
fm_set .orchid/tasks/U.md unresolved_objection 'operator keeps this boundary'
fm_set .orchid/tasks/U.md unresolved_objection_by operator
printf 'Revised requirements\n' > "$WORK/requirements.md"
refuse_replan 'outstanding machine obligation' --requirements "$WORK/requirements.md" --reason fixture
red_case 'requirements changes cannot silently retire a machine repair obligation'
graph_replan_command "$ORCHID_REPO" --requirements "$WORK/requirements.md" --resolve-repairs A --reason 'operator retires old scope' > "$WORK/requirements.log" 2>&1 || { fail 'requirements rewrite'; cat "$WORK/requirements.log"; exit 1; }
assert_eq 2 "$(fm_version .orchid/roadmap.md requirements_revision)" 'requirements revision advances'
assert_eq '' "$(fm_get .orchid/tasks/A.md repair_obligation)" 'explicit named retirement removes machine obligation'
assert_eq 2 "$(fm_get .orchid/tasks/A.md repair_rounds)" 'contract replanning never refunds consumed repair rounds'
assert_eq 'operator keeps this boundary' "$(fm_get .orchid/tasks/U.md unresolved_objection)" 'operator objection survives requirements replanning'
cmp -s .orchid/requirements.md "$WORK/requirements.md" || fail 'requirements content published'
jq -e '.retired_repairs == ["A"]' .orchid/revisions/graph-p4/decision.json >/dev/null || fail 'repair retirement archived with reason'
green_case 'requirements revise all contracts and journal explicit obligation retirement'

printf '{"A":{"risk_tier":"medium"}}\n' > "$WORK/increase.json"
graph_replan_command "$ORCHID_REPO" --patch "$WORK/increase.json" --reason 'increase review scrutiny' > "$WORK/increase.log" 2>&1 || { fail 'monotonic risk increase'; cat "$WORK/increase.log"; exit 1; }
assert_eq medium "$(fm_get .orchid/tasks/A.md risk_tier)" 'risk increase is permitted'
assert_eq medium "$(fm_get .orchid/tasks/A.md blocking_severity)" 'risk increase derives its matching blocking threshold'
green_case 'the same monotonicity gate accepts stronger review scrutiny and derives its threshold'

# Interrupt source synchronization after CAS. Recovery must install exactly the
# committed graph plan, including its nested archive, without running it twice.
printf '{"W":{"acceptance_criteria":"recovered nested acceptance"}}\n' > "$WORK/recover.json"
cp .orchid/tasks/A.md "$WORK/pre-interruption-A.md"
before_head="$(git rev-parse orchid/integration)"
before_index="$(git ls-files --stage -z | _orchid_stream_sha256)"
saved_sync="$(declare -f _ocd_sync_dir_atomic)"
_ocd_sync_dir_atomic() { return 77; }
rc=0; graph_replan_command "$ORCHID_REPO" --patch "$WORK/recover.json" --reason 'recoverable publication fixture' > "$WORK/interrupted.log" 2>&1 || rc=$?
eval "$saved_sync"
[ "$rc" -ne 0 ] || fail 'interrupted source sync must report failure'
[ "$before_head" != "$(git rev-parse orchid/integration)" ] || fail 'fixture interrupted after commit publication'
cmp -s .orchid/tasks/A.md "$WORK/pre-interruption-A.md" || fail 'preimage retained until recovery'
test -f .orchid/runtime/publication.json || fail 'published plan has a recovery receipt'
red_case 'post-CAS graph publication failure leaves an explicit receipt and unchanged source preimage'
ORCHID_EPOCH="$("$ORCHID_BIN" run resume | sed 's/epoch: //')"; export ORCHID_EPOCH
assert_eq 'recovered nested acceptance' "$(fm_get .orchid/tasks/W.md acceptance_criteria)" 'resume publishes committed semantic change'
test -f .orchid/revisions/graph-p6/new.json || fail 'resume restores exact graph archive'
test ! -f .orchid/runtime/publication.json || fail 'successful recovery retires receipt'
assert_eq "$before_index" "$(git ls-files --stage -z | _orchid_stream_sha256)" 'recovery leaves source Git index unchanged'
before="$(snapshot_state)"
graph_replan_command "$ORCHID_REPO" --patch "$WORK/recover.json" --reason replay > "$WORK/recovered-replay.log" 2>&1 || fail 'recovered replan replay'
assert_eq "$before" "$(snapshot_state)" 'same recovered plan never increments generations twice'
green_case 'resume completes the committed graph plan and replay preserves its single generation change'

# Unchanged-contract operator restart uses graph input edges as well, without
# changing any parent's effective contract or adopting checkpoint approvals.
for id in A V W; do fm_set ".orchid/tasks/$id.md" status blocked; done
source_revision="$(fm_version .orchid/tasks/A.md contract_revision)"
verifier_generation="$(fm_version .orchid/tasks/V.md execution_generation)"
cp .orchid/tasks/U.md "$WORK/restart-unrelated.md"
"$ORCHID_BIN" task restart A --reason 'rerun the existing graph contract' > "$WORK/graph-restart.log" 2>&1 || { fail 'graph-aware operator restart'; cat "$WORK/graph-restart.log"; exit 1; }
assert_eq "$source_revision" "$(fm_version .orchid/tasks/A.md contract_revision)" 'restart preserves effective contract revision'
assert_eq "$((verifier_generation + 1))" "$(fm_version .orchid/tasks/V.md execution_generation)" 'restart invalidates required verifier input generation'
assert_eq pending "$(fm_get .orchid/tasks/W.md status)" 'nested verifier must rerun'
cmp -s .orchid/tasks/U.md "$WORK/restart-unrelated.md" || fail 'graph restart preserves unrelated objection and node'
green_case 'operator restart traverses verifies inputs while preserving contract terms and unrelated nodes'

printf '{"U":null}\n' > "$WORK/delete.json"
refuse_replan 'deletion cannot erase an objection' --patch "$WORK/delete.json" --reason 'remove obsolete task'
red_case 'removing a graph node cannot erase its unresolved operator objection'
fm_set .orchid/tasks/U.md unresolved_objection ''
graph_replan_command "$ORCHID_REPO" --patch "$WORK/delete.json" --reason 'remove obsolete resolved task' > "$WORK/deleted.log" 2>&1 || { fail 'delete resolved obsolete node'; cat "$WORK/deleted.log"; exit 1; }
test ! -f .orchid/tasks/U.md || fail 'removed node leaves the current graph'
test -f .orchid/revisions/graph-p7/tasks/U.md || fail 'removed node remains in immutable history'
green_case 'an obsolete node can be removed after its existing objection is resolved'

source_revision="$(fm_version .orchid/tasks/A.md contract_revision)"
parent_revision="$(fm_version .orchid/tasks/W.md contract_revision)"
printf '{"N":{"title":"independent nested verifier","archetype":"review","verifies":"W","acceptance_criteria":"check exact report"}}\n' > "$WORK/add.json"
graph_replan_command "$ORCHID_REPO" --patch "$WORK/add.json" --reason 'add independent verification' > "$WORK/added.log" 2>&1 || { fail 'add a new nested verifier'; cat "$WORK/added.log"; exit 1; }
assert_eq 1 "$(fm_version .orchid/tasks/N.md contract_revision)" 'new contract starts at one'
assert_eq 1 "$(fm_version .orchid/tasks/N.md execution_generation)" 'new execution starts at one'
assert_eq pending "$(fm_get .orchid/tasks/N.md status)" 'new verifier starts pending'
assert_eq task/N "$(fm_get .orchid/tasks/N.md branch)" 'new verifier has canonical initial branch'
assert_eq "$((source_revision + 1))" "$(fm_version .orchid/tasks/A.md contract_revision)" 'new nested verifier versions target ancestors once'
assert_eq "$((parent_revision + 1))" "$(fm_version .orchid/tasks/W.md contract_revision)" 'new verifier versions its immediate parent'
test ! -f .orchid/revisions/graph-p8/tasks/N.md || fail 'new node has no invented previous record'
green_case 'new nested verification uses canonical task templates and versions every required ancestor'
printf '{"N":{"depends_on":"A"}}\n' > "$WORK/new-cycle.json"
refuse_replan 'new verifier completion cycle' --patch "$WORK/new-cycle.json" --reason fixture
printf '{"U":{"title":"reuse retired identity"}}\n' > "$WORK/reuse.json"
refuse_replan 'retired identity cannot reset its history' --patch "$WORK/reuse.json" --reason fixture
red_case 'new verification cannot introduce completion cycles or reuse retired execution identities'
[ "$(fm_version .orchid/tasks/N.md execution_generation)" = 1 ] || fail 'refused rewrite preserves fresh generation'
green_case 'the accepted new verifier survives subsequent refused rewrites unchanged'
[ "$FAILS" -eq 0 ]
