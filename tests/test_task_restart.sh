#!/usr/bin/env bash
# RED: Restart refuses missing authority, live jobs, and obsolete results.
# GREEN: One verification branch reruns without changing its contract or siblings.
source "$(dirname "$0")/helpers.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
git commit -q --allow-empty -m 'committed application baseline'
candidate="$(git rev-parse HEAD)"
"$ORCHID_BIN" init >/dev/null || { fail 'initialize restart fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'create control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

export ORCHID_ENGINES_DIR="$WORK/engines"
mkdir -p "$ORCHID_ENGINES_DIR/fake"
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' > "$ORCHID_ENGINES_DIR/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$ORCHID_ENGINES_DIR/fake/run"
chmod 755 "$ORCHID_ENGINES_DIR/fake/run"

# A is the completed upstream audit; B and C are independent checks. D depends
# on both checks. Restarting B must affect B,D and preserve A,C byte for byte.
for id in A B C D; do
    "$ORCHID_BIN" task create "$id" "$id verification contract" --archetype review >/dev/null || { fail 'create review node'; exit 1; }
done
"$ORCHID_BIN" task set B depends_on A >/dev/null
"$ORCHID_BIN" task set C depends_on A >/dev/null
"$ORCHID_BIN" task set D depends_on B,C >/dev/null
"$ORCHID_BIN" run advance running --reason fixture >/dev/null
complete_check() {
    local id="$1"
    "$ORCHID_BIN" task set "$id" base_sha "$candidate" >/dev/null || return 1
    "$ORCHID_BIN" task set "$id" candidate_sha "$candidate" >/dev/null || return 1
    "$ORCHID_BIN" task advance "$id" reviewing >/dev/null || return 1
    plant_reviewer_envelope "$id"
    "$ORCHID_BIN" task advance "$id" arbitrating --reason 'check completed' >/dev/null || return 1
    "$ORCHID_BIN" task arbitrate "$id" --result approve --reason 'accepted check' >/dev/null
}
for id in A B C D; do
    complete_check "$id" || { fail "complete initial check $id"; exit 1; }
done
"$ORCHID_BIN" run advance accepting --reason 'all checks passed' >/dev/null
restart_snapshot() {
    git rev-parse orchid/integration
    git hash-object .orchid/tasks/*.md .orchid/reviews/* .orchid/roadmap.md .orchid/journal.md
}
before="$(restart_snapshot)"
out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" task restart B --reason 'repeat independent check' --dry-run)" || { fail 'restart dry-run works without ownership'; exit 1; }
assert_match '^B$' "$out" 'restart impact includes selected check'
assert_match '^D$' "$out" 'restart impact includes downstream check'
if grep -Eq '^(A|C)$' <<< "$out"; then fail 'restart impact excludes upstream and sibling'; fi
assert_eq "$before" "$(restart_snapshot)" 'restart preview is pure'

rc=0; out="$(ORCHID_EPOCH=stale "$ORCHID_BIN" task restart B --reason fixture 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'stale epoch cannot restart'
rc=0; out="$(ORCHID_ACTOR=tick-e1 "$ORCHID_BIN" task restart B --reason fixture 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'headless actor cannot restart'
assert_match 'operator-owned' "$out" 'restart authority diagnostic'
rc=0; "$ORCHID_BIN" task restart B > "$WORK/missing-reason.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'restart requires reason'
rc=0; "$ORCHID_BIN" task restart B --acceptance-criteria changed --reason fixture > "$WORK/contract-flag.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'restart cannot accept contract changes'
assert_eq "$before" "$(restart_snapshot)" 'refused restart leaves state unchanged'
red_case 'restart refuses stale ownership, orchestrator authority, missing reason, and contract mutation'
green_case 'read-only restart preview computes the selected verification subgraph'

old_manifest="$("$ORCHID_BIN" jobs prepare B reviewer review --engine fake)" || { fail 'prepare original check job'; exit 1; }
old_jid="$(jq -r .job_id "$old_manifest")"
cp "$old_manifest" "$WORK/old-manifest.json"
rc=0; out="$("$ORCHID_BIN" task restart B --reason fixture 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'outstanding check job prevents restart'
assert_match 'outstanding jobs' "$out" 'outstanding check diagnostic'
assert_eq "$before" "$(restart_snapshot)" 'outstanding job refusal preserves state'
touch -t 202001010000 "$old_manifest"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 --prepared-older-than-s 0 >/dev/null
red_case 'prepared verification work prevents restart until retired'

cp .orchid/tasks/A.md "$WORK/upstream.md"
cp .orchid/tasks/C.md "$WORK/sibling.md"
cp .orchid/reviews/C-a1-reviewer.json "$WORK/sibling-evidence.json"
criteria="$(fm_get .orchid/tasks/B.md acceptance_criteria)"
"$ORCHID_BIN" task restart B --reason 'repeat independent check' >/dev/null || { fail 'restart verification subgraph'; exit 1; }
for id in B D; do
    assert_eq pending "$(fm_get ".orchid/tasks/$id.md" status)" "$id queued for re-execution"
    assert_eq 1 "$(fm_get ".orchid/tasks/$id.md" contract_revision)" "$id contract unchanged"
    assert_eq 2 "$(fm_get ".orchid/tasks/$id.md" execution_generation)" "$id execution advanced"
    [ -f ".orchid/revisions/B-g2/tasks/$id.md" ] || fail "$id prior execution archived"
    [ ! -e ".orchid/reviews/$id-a1-reviewer.json" ] || fail "$id old approval withdrawn"
done
assert_eq "$criteria" "$(fm_get .orchid/tasks/B.md acceptance_criteria)" 'restart retains acceptance criteria'
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" 'restart reopens accepting run'
cmp "$WORK/upstream.md" .orchid/tasks/A.md || fail 'completed upstream check preserved'
cmp "$WORK/sibling.md" .orchid/tasks/C.md || fail 'independent sibling check preserved'
cmp "$WORK/sibling-evidence.json" .orchid/reviews/C-a1-reviewer.json || fail 'sibling evidence preserved'
green_case 'restart changes execution generations only and preserves upstream and sibling checks'

# Re-pin the identical application candidate: old results must still be stale.
"$ORCHID_BIN" task set B base_sha "$candidate" >/dev/null
"$ORCHID_BIN" task set B candidate_sha "$candidate" >/dev/null
"$ORCHID_BIN" task advance B reviewing >/dev/null
cp "$WORK/old-manifest.json" "$old_manifest"
mkdir -p .orchid/runtime/spool
jq -n --arg jid "$old_jid" --arg cand "$candidate" '{contract:1,job_id:$jid,task:"B",operation:"review",status:"ok",verdict:"approve",scope_complete:true,summary:"obsolete check",candidate_sha:$cand}' > ".orchid/runtime/spool/$old_jid.json"
out="$("$ORCHID_BIN" jobs reconcile)" || fail 'quarantine old result'
assert_match 'obsolete-revision' "$out" 'same-candidate old generation refused'
[ ! -e .orchid/reviews/B-a1-reviewer.json ] || fail 'obsolete approval not filed'
rc=0; "$ORCHID_BIN" task advance B arbitrating --reason 'old approval' > "$WORK/obsolete-approval.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'old approval cannot complete restarted check'
red_case 'an obsolete check cannot approve the identical candidate in a new execution'
touch -t 202001010000 "$old_manifest"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 --prepared-older-than-s 0 >/dev/null
manifest="$("$ORCHID_BIN" jobs prepare B reviewer review --engine fake)" || { fail 'prepare replacement check'; exit 1; }
jid="$(jq -r .job_id "$manifest")"
jq -e '.contract_revision == 1 and .execution_generation == 2 and .input_revisions.A.execution_generation == 1' "$manifest" >/dev/null || fail 'replacement binds unchanged contract and upstream'
mkdir -p .orchid/runtime/exits
printf '0\n' > ".orchid/runtime/exits/$jid"
jq -n --arg jid "$jid" --arg cand "$candidate" '{contract:1,job_id:$jid,task:"B",operation:"review",status:"ok",verdict:"approve",scope_complete:true,summary:"fresh check",candidate_sha:$cand}' > ".orchid/runtime/spool/$jid.json"
"$ORCHID_BIN" jobs reconcile >/dev/null || fail 'file fresh check'
"$ORCHID_BIN" task advance B arbitrating --reason 'fresh approval' >/dev/null || fail 'fresh check reaches arbitration'
"$ORCHID_BIN" task arbitrate B --result approve --reason 'fresh check accepted' >/dev/null || fail 'fresh check completes'
complete_check D || fail 'downstream check reruns after replacement approval'
assert_eq 'done' "$(fm_get .orchid/tasks/D.md status)" 'downstream check completes replacement execution'
green_case 'new generation independently reviews the same candidate and unblocks downstream verification'

# A restart spends execution generations, never contract revisions.
fm_set .orchid/tasks/B.md contract_revision 999999
"$ORCHID_BIN" task restart B --reason 'repeat with unchanged capped contract' >/dev/null || fail 'contract revision cap does not prevent unchanged restart'
assert_eq 999999 "$(fm_get .orchid/tasks/B.md contract_revision)" 'repeated restart preserves capped contract revision'
assert_eq 3 "$(fm_get .orchid/tasks/B.md execution_generation)" 'repeated restart advances execution'
[ -f .orchid/revisions/B-g2/tasks/B.md ] || fail 'first restart history remains'
[ -f .orchid/revisions/B-g3/tasks/B.md ] || fail 'second restart archives replacement'
green_case 'repeated verification loops retain their contract and all previous generations'
[ "$FAILS" -eq 0 ]
