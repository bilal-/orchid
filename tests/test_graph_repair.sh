#!/usr/bin/env bash
# RED: Stale/incomplete evidence, objections, and spent repair budgets refuse.
# GREEN: Current structured findings publish one bounded generation reset and obligation.
source "$(dirname "$0")/helpers.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/graph-repair.sh"
_graph_repair_load
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf 'baseline\n' > app.txt
git add app.txt
git commit -q -m baseline
"$ORCHID_BIN" init >/dev/null || { fail 'initialize repair fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'repair control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create A source >/dev/null || { fail 'create source'; exit 1; }
"$ORCHID_BIN" task create V verifier --archetype review >/dev/null || { fail 'create verifier'; exit 1; }
"$ORCHID_BIN" task create U unrelated --archetype review >/dev/null || { fail 'create unrelated'; exit 1; }
"$ORCHID_BIN" run advance running --reason fixture >/dev/null || { fail 'start fixture'; exit 1; }
# Fixture state represents kernel-filed review evidence without invoking a vendor.
fm_set .orchid/roadmap.md graph_contract 1
fm_set .orchid/roadmap.md requirements_revision 1
fm_set .orchid/tasks/V.md verifies A
fm_set .orchid/tasks/V.md repair_target A
fm_set .orchid/tasks/A.md repair_budget 2
candidate="$(git rev-parse orchid/integration)"
bind_review_fixture() {
  local verdict="$1" scope="$2" findings="$3"
  fm_set .orchid/tasks/A.md status reviewing
  fm_set .orchid/tasks/V.md status arbitrating
  for id in A V; do
    fm_set ".orchid/tasks/$id.md" base_sha "$candidate"
    fm_set ".orchid/tasks/$id.md" candidate_sha "$candidate"
  done
  graph_snapshot_file "$ORCHID_REPO" "$WORK/snapshot.json" || return 1
  fm_set .orchid/tasks/V.md verification_target "$(graph_expected_target "$WORK/snapshot.json" V)" || return 1
  graph_snapshot_file "$ORCHID_REPO" "$WORK/snapshot.json" || return 1
  graph_job_binding "$ORCHID_REPO" V "$WORK/binding.json" "$WORK/snapshot.json" || return 1
  mkdir -p .orchid/reviews
  jq -n --slurpfile binding "$WORK/binding.json" --arg candidate "$candidate" --arg verdict "$verdict" \
    --argjson scope "$scope" --argjson findings "$findings" '
    {contract:1,task:"V",role:"reviewer",operation:"review",status:"ok",candidate_sha:$candidate,
     verdict:$verdict,scope_complete:$scope,summary:"fixture review",findings:$findings,engine:"test/fake"} + $binding[0]
  ' > .orchid/reviews/V-a1-reviewer.json
}
blocking='[{"severity":"high","title":"committed artifact is invalid","detail":"fixture structured evidence"}]'
bind_review_fixture request-changes true "$blocking" || { fail 'bind initial evidence'; exit 1; }
cp .orchid/tasks/U.md "$WORK/unrelated.md"
state_hash() {
  local file
  git rev-parse orchid/integration
  git hash-object .orchid/tasks/*.md .orchid/roadmap.md .orchid/journal.md
  for file in .orchid/reviews/*.json; do [ ! -f "$file" ] || git hash-object "$file"; done
}
refuse_repair() {
  local label="$1" before rc=0
  before="$(state_hash)"
  graph_repair_command "$ORCHID_REPO" V > "$WORK/refusal.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label refuses"
  assert_eq "$before" "$(state_hash)" "$label preserves durable state"
}
fm_set .orchid/tasks/A.md unresolved_objection 'operator owns this objection'
fm_set .orchid/tasks/A.md unresolved_objection_by operator
refuse_repair 'standing operator objection'
assert_eq 'operator owns this objection' "$(fm_get .orchid/tasks/A.md unresolved_objection)" 'machine never clears operator objection'
fm_set .orchid/tasks/A.md unresolved_objection ''
bind_review_fixture request-changes false "$blocking" || fail 'incomplete scope fixture'
refuse_repair 'incomplete reviewer scope'
bind_review_fixture request-changes true '[]' || fail 'unstructured rejection fixture'
refuse_repair 'rejection without structured finding'
bind_review_fixture request-changes true "$blocking" || fail 'restore evidence'
fm_set .orchid/tasks/A.md execution_generation 2
refuse_repair 'same SHA obsolete target generation'
fm_set .orchid/tasks/A.md execution_generation 1
red_case 'operator objections incomplete scope unstructured rejection and stale target versions refuse automatic repair'

# The obligation's content hash must agree with the exact file moved into the
# immutable revision archive, even if a producer claims different evidence.
saved_evidence="$(declare -f _graph_repair_evidence)"
eval "$(declare -f _graph_repair_evidence | sed '1s/_graph_repair_evidence/_graph_repair_evidence_original/')"
_graph_repair_evidence() {
  _graph_repair_evidence_original "$@" || return 1
  jq '.evidence[0].sha256=("0"*64)' "$4" > "$WORK/forged-evidence.json" || return 1
  mv "$WORK/forged-evidence.json" "$4"
}
refuse_repair 'mismatched archived evidence digest'
eval "$saved_evidence"
red_case 'a machine obligation cannot claim evidence bytes different from its archive'

graph_repair_command "$ORCHID_REPO" V > "$WORK/repaired.log" 2>&1 || { fail 'current blocking repair'; cat "$WORK/repaired.log"; exit 1; }
assert_eq 1 "$(fm_get .orchid/tasks/A.md repair_rounds)" 'one repair round consumed'
assert_eq 2 "$(fm_version .orchid/tasks/A.md execution_generation)" 'source generation advances'
assert_eq 2 "$(fm_version .orchid/tasks/V.md execution_generation)" 'verifier generation advances'
assert_eq 1 "$(fm_version .orchid/tasks/A.md contract_revision)" 'repair keeps original contract'
assert_eq pending "$(fm_get .orchid/tasks/A.md status)" 'source returns to implementation'
assert_eq "$candidate" "$(fm_get .orchid/tasks/A.md candidate_sha)" 'failed immutable commit is implementation baseline'
assert_eq '' "$(fm_get .orchid/tasks/V.md verification_target)" 'old verifier target authority removed'
test -f .orchid/revisions/repair-A-r1/reviews/V-a1-reviewer.json || { fail 'failed evidence archived'; rg --files .orchid/revisions/repair-A-r1; }
test ! -f .orchid/reviews/V-a1-reviewer.json || fail 'old evidence cannot satisfy fresh round'
cmp -s .orchid/tasks/U.md "$WORK/unrelated.md" || fail 'unrelated node survives exact'
obligation="$(fm_get .orchid/tasks/A.md repair_obligation)"
printf '%s' "$obligation" | jq -e '.source.execution_generation == 1 and .verifier.execution_generation == 1 and .round == 1 and (.failed_evidence|length) == 1' >/dev/null || fail 'obligation binds exact failed lineage'
green_case 'one current structured failure resets the input closure and retains the failed candidate as baseline'

rc=0; graph_repair_approval_gate "$ORCHID_REPO" A > "$WORK/approval-refused.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'historical failure cannot count as fresh repair approval'
red_case 'obligation cannot be discharged by archived evidence from the rejected generation'
bind_review_fixture approve true '[]' || { fail 'fresh approval fixture'; exit 1; }
fm_set .orchid/tasks/V.md status "done"
graph_repair_approval_gate "$ORCHID_REPO" A || fail 'fresh bound approval discharges obligation'
graph_repair_approval_complete "$ORCHID_REPO" A || fail 'record fresh obligation resolution'
assert_eq '' "$(fm_get .orchid/tasks/A.md repair_obligation)" 'only machine obligation removed'
assert_eq 1 "$(fm_get .orchid/tasks/A.md repair_rounds)" 'resolution never refunds repair budget'
graph_repair_approval_complete "$ORCHID_REPO" A || fail 'resolution is idempotent'
green_case 'fresh later-generation verifier approval resolves only its machine obligation exactly once'

bind_review_fixture request-changes true "$blocking" || fail 'second blocking fixture'
graph_repair_command "$ORCHID_REPO" V > "$WORK/repair2.log" 2>&1 || { fail 'second bounded repair'; cat "$WORK/repair2.log"; exit 1; }
assert_eq 2 "$(fm_get .orchid/tasks/A.md repair_rounds)" 'cross-generation counter reaches configured budget'
bind_review_fixture request-changes true "$blocking" || fail 'third blocking fixture'
refuse_repair 'exhausted cross-generation budget'
red_case 'new generations and fresh failed reviews cannot reset the configured repair ceiling'
assert_eq 2 "$(fm_get .orchid/tasks/A.md repair_rounds)" 'refusal preserves the consumed budget'
green_case 'the configured number of repairs succeeds before the same gate refuses the next round'

# A merge/rebase candidate change invalidates bound verifier descendants while
# preserving the already-updated parent and its consumed repair budget.
fm_set .orchid/tasks/U.md depends_on V
new_candidate="$(printf 'changed candidate\n' | git commit-tree 'HEAD^{tree}' -p HEAD)"
fm_set .orchid/tasks/A.md candidate_sha "$new_candidate"
cp .orchid/tasks/A.md "$WORK/parent-before-invalidate.md"
fm_set .orchid/tasks/V.md unresolved_objection 'standing verifier objection'
rc=0; graph_invalidate_command "$ORCHID_REPO" A --reason rebase > "$WORK/invalidate-refused.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'invalidation preserves unresolved objection authority'
assert_eq 'standing verifier objection' "$(fm_get .orchid/tasks/V.md unresolved_objection)" 'invalidation never clears objection'
red_case 'candidate-change invalidation waits for the existing objection boundary'
fm_set .orchid/tasks/V.md unresolved_objection ''
graph_invalidate_command "$ORCHID_REPO" A --reason rebase > "$WORK/invalidated.log" 2>&1 || { fail 'invalidate stale verifier'; cat "$WORK/invalidated.log"; exit 1; }
assert_eq 4 "$(fm_version .orchid/tasks/V.md execution_generation)" 'obsolete verifier generation advances'
assert_eq 2 "$(fm_version .orchid/tasks/U.md execution_generation)" 'ordinary verifier consumer invalidated too'
assert_eq pending "$(fm_get .orchid/tasks/V.md status)" 'old verifier result reopens'
cmp -s .orchid/tasks/A.md "$WORK/parent-before-invalidate.md" || fail 'updated target stays byte-identical'
before="$(state_hash)"
graph_invalidate_command "$ORCHID_REPO" A --reason replay > "$WORK/invalidate-replay.log" 2>&1 || fail 'invalidation replay'
assert_eq "$before" "$(state_hash)" 'already-unbound verifier invalidation is idempotent'
green_case 'candidate invalidation resets stale verifier consumers exactly once while preserving the target'
[ "$FAILS" -eq 0 ]
