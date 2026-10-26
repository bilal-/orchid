#!/usr/bin/env bash
# RED: Required nested checks and obsolete same-SHA results block completion.
# GREEN: Public graph preparation and fresh evidence complete each obligation.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/graph-runtime.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf 'verify=true\nconcurrency=1\n' > orchid.config
git add orchid.config
git commit -q -m baseline
baseline="$(git rev-parse HEAD)"
"$ORCHID_BIN" init >/dev/null || { fail 'initialize delivery fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
printf 'Deliver a verified JSON result.\n' > "$WORK/requirements.md"
"$ORCHID_BIN" requirements import "$WORK/requirements.md" >/dev/null || { fail 'requirements'; exit 1; }
"$ORCHID_BIN" task create BUILD 'Build result' >/dev/null || { fail 'build node'; exit 1; }
for id in CHECK DEEP BROKEN GOOD; do
  "$ORCHID_BIN" task create "$id" 'Independent check' --archetype review >/dev/null || { fail 'check node'; exit 1; }
done
"$ORCHID_BIN" task set CHECK verifies BUILD >/dev/null || { fail 'target edge'; exit 1; }
"$ORCHID_BIN" task set DEEP verifies CHECK >/dev/null || { fail 'nested edge'; exit 1; }
"$ORCHID_BIN" task set BUILD output_contract '{"contract":1,"artifacts":[{"path":"result.json","schema":{"properties":{"ok":{"const":true}},"required":["ok"]}}]}' >/dev/null || { fail 'artifact definition'; exit 1; }
"$ORCHID_BIN" task set BROKEN output_contract '{"contract":1,"artifacts":[{"path":"missing-result.json"}]}' >/dev/null || { fail 'negative report contract'; exit 1; }
"$ORCHID_BIN" task set GOOD output_contract '{"contract":1,"artifacts":[{"path":"orchid.config","contains":["verify=true"]}]}' >/dev/null || { fail 'positive report contract'; exit 1; }
"$ORCHID_BIN" graph enable --reason 'nested delivery fixture' >/dev/null || { fail 'enable graph'; exit 1; }
"$ORCHID_BIN" run advance running --reason 'begin graph fixture' >/dev/null || { fail 'start graph'; exit 1; }

refuse() {
  local label="$1" rc=0; shift
  "$@" > "$WORK/refusal.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label"
}
fresh_review() {
  local id="$1" candidate contract
  candidate="$(fm_get ".orchid/tasks/$id.md" candidate_sha)" || return 1
  plant_reviewer_envelope "$id" || return 1
  graph_job_binding "$ORCHID_REPO" "$id" "$WORK/binding.json" || return 1
  contract="$(jq -c .output_contract "$WORK/binding.json")" || return 1
  if [ "$contract" != null ] && printf '%s' "$contract" | jq -e '.operations | index("review") != null' >/dev/null; then
    if output_contract_evaluate "$ORCHID_REPO" "$candidate" "$contract" ".orchid/reviews/$id-a1-reviewer.json" > "$WORK/contract.json"; then
      jq --slurpfile evidence "$WORK/contract.json" '.output_contract_evidence=$evidence[0]' ".orchid/reviews/$id-a1-reviewer.json" > "$WORK/contract-review.json" || return 1
    else
      jq --slurpfile failure "$WORK/contract.json" '.contract_failure=($failure[0]+{reported_status:"ok",reported_verdict:"approve"}) | .verdict="request-changes" | .findings=[{severity:"high",summary:"committed artifact failed"}]' ".orchid/reviews/$id-a1-reviewer.json" > "$WORK/contract-review.json" || return 1
    fi
    mv "$WORK/contract-review.json" ".orchid/reviews/$id-a1-reviewer.json" || return 1
  fi
  jq --slurpfile binding "$WORK/binding.json" '. + $binding[0]' \
    ".orchid/reviews/$id-a1-reviewer.json" > "$WORK/current-review.json" || return 1
  mv "$WORK/current-review.json" ".orchid/reviews/$id-a1-reviewer.json"
}
prepare_review() {
  local id="$1"
  "$REPO_ROOT/runners/orchid-graph-prepare" "$id" --operation review || return 1
  "$ORCHID_BIN" task advance "$id" reviewing --reason 'frozen review input' >/dev/null || return 1
  fresh_review "$id" || return 1
  "$ORCHID_BIN" task advance "$id" arbitrating --reason 'fresh check filed' >/dev/null
}

source "$REPO_ROOT/lib/drive.sh"
for invalid_generation in 0 01 -1 bad 1000000; do
  if drive_worktree_path "$ORCHID_REPO" FUTURE "$invalid_generation" > "$WORK/bad-generation.out"; then
    fail 'explicit worktree generation must be canonical and bounded'
  fi
done
red_case 'future-node worktree planning refuses invalid explicit generations'
assert_eq "$(orchid_physical_dir "$WORK/control")-FUTURE" "$(drive_worktree_path "$ORCHID_REPO" FUTURE 1)" 'new node shares canonical generation-one path owner'
green_case 'a valid explicit generation plans a future node without a task record'
refuse 'graph execution rejects ad hoc node creation' "$ORCHID_BIN" task create LATE 'unversioned membership change'
[ ! -e .orchid/tasks/LATE.md ] || fail 'refused node creation leaves no partial record'
refuse 'executing contract must use semantic replan' "$ORCHID_BIN" task set CHECK acceptance_criteria 'unversioned contract change'
refuse 'repair budget counter is kernel owned' "$ORCHID_BIN" task set BUILD repair_rounds 0
refuse 'graph branch must match generation one too' "$ORCHID_BIN" task set BUILD branch arbitrary
red_case 'graph execution definitions counters and branch identity require their owning verbs'
green_case 'the same graph nodes were created and configured during planning'

prepare_review BROKEN || { fail 'finished negative report reaches arbitration'; exit 1; }
refuse 'direct approval cannot override a failed artifact contract' "$ORCHID_BIN" task arbitrate BROKEN --result approve --reason fixture
assert_eq arbitrating "$(fm_get .orchid/tasks/BROKEN.md status)" 'artifact contract remains a completion gate'
red_case 'negative artifact review remains reviewable but cannot be approved past its contract'
"$ORCHID_BIN" task arbitrate BROKEN --result request-changes --reason 'contract requires a different candidate or replan' >/dev/null || { fail 'negative report can enter ordinary rework'; exit 1; }
prepare_review GOOD || { fail 'prepare passing artifact report'; exit 1; }
"$ORCHID_BIN" task arbitrate GOOD --result approve --reason fixture >/dev/null || { fail 'passing report contract permits completion'; exit 1; }
green_case 'the same report approval path accepts passing committed artifact evidence'
good_candidate="$(fm_get .orchid/tasks/GOOD.md candidate_sha)"
good_worktree="$(fm_get .orchid/tasks/GOOD.md worktree)"
refuse 'completed graph candidate cannot be retargeted without a generation' "$ORCHID_BIN" task set GOOD candidate_sha "$baseline"
refuse 'completed graph base cannot silently change review scope' "$ORCHID_BIN" task set GOOD base_sha "$baseline"
refuse 'completed graph checkout cannot be replaced' "$ORCHID_BIN" task set GOOD worktree "$(fm_get .orchid/tasks/BROKEN.md worktree)"
refuse 'completed graph clock cannot be forged' "$ORCHID_BIN" task set GOOD started_at '2026-01-01T00:00:00Z'
refuse 'a registered completed checkout cannot be silently forgotten' "$ORCHID_BIN" task set GOOD worktree ''
assert_eq "$good_candidate" "$(fm_get .orchid/tasks/GOOD.md candidate_sha)" 'rejected identity changes preserve completed evidence'
red_case 'completed graph evidence cannot be retargeted by generic setters'
git worktree remove "$good_worktree" || { fail 'remove completed fixture checkout'; exit 1; }
"$ORCHID_BIN" task set GOOD worktree '' >/dev/null || { fail 'record completed checkout cleanup'; exit 1; }
graph_completion_ready "$ORCHID_REPO" GOOD || fail 'completed report proof survives legitimate checkout cleanup'
assert_eq "$good_candidate" "$(fm_get .orchid/tasks/GOOD.md candidate_sha)" 'cleanup preserves the approved candidate'
green_case 'named execution preparation and completed checkout cleanup preserve exact identity'


"$REPO_ROOT/runners/orchid-graph-prepare" BUILD --operation implement || { fail 'prepare build'; exit 1; }
wt="$(fm_get .orchid/tasks/BUILD.md worktree)"
"$ORCHID_BIN" task advance BUILD implementing >/dev/null || { fail 'implement entry'; exit 1; }
printf '{"ok":true}\n' > "$wt/result.json"
git -C "$wt" add result.json
git -C "$wt" commit -q -m 'deliver artifact'
candidate="$(git -C "$wt" rev-parse HEAD)"
"$ORCHID_BIN" task set BUILD candidate_sha "$candidate" >/dev/null || { fail 'record delivered candidate'; exit 1; }
"$ORCHID_BIN" task advance BUILD testing >/dev/null || { fail 'test entry'; exit 1; }
"$ORCHID_BIN" verify BUILD >/dev/null || { fail 'bound mechanical proof'; exit 1; }
grep -F 'graph_binding:' .orchid/reviews/BUILD-verify.log >/dev/null || fail 'mechanical evidence binds graph context'
"$ORCHID_BIN" task advance BUILD reviewing >/dev/null || { fail 'build reviewing'; exit 1; }
fresh_review BUILD || { fail 'fresh build review'; exit 1; }
"$ORCHID_BIN" task advance BUILD arbitrating >/dev/null || { fail 'build arbitration'; exit 1; }
refuse 'parent approval cannot bypass missing verifier' "$ORCHID_BIN" task arbitrate BUILD --result approve --reason fixture
assert_eq arbitrating "$(fm_get .orchid/tasks/BUILD.md status)" 'parent remains unfinished'
red_case 'direct parent approval refuses an unfinished required verifier'
"$ORCHID_BIN" graph wait BUILD >/dev/null || { fail 'record build wait'; exit 1; }

prepare_review CHECK || { fail 'prepare first verifier at concurrency one'; exit 1; }
refuse 'verifier cannot bypass its nested check' "$ORCHID_BIN" task arbitrate CHECK --result approve --reason fixture
red_case 'required verification nests without bypassing inner completion'
"$ORCHID_BIN" graph wait CHECK >/dev/null || { fail 'record nested wait'; exit 1; }
prepare_review DEEP || { fail 'prepare nested verifier'; exit 1; }
"$ORCHID_BIN" task arbitrate DEEP --result approve --reason fixture >/dev/null || { fail 'complete nested check'; exit 1; }
"$ORCHID_BIN" task arbitrate CHECK --result approve --reason fixture >/dev/null || { fail 'complete verifier'; exit 1; }
"$ORCHID_BIN" task arbitrate BUILD --result approve --reason fixture >/dev/null || { fail 'complete parent checks'; exit 1; }
assert_eq merging "$(fm_get .orchid/tasks/BUILD.md status)" 'code awaits merge only after nested approval'
green_case 'fresh nested evidence releases each parent through public arbitration'

# Restarting the report branch retains the target candidate and its contract.
cp .orchid/reviews/CHECK-a1-reviewer.json "$WORK/old-review.json"
"$ORCHID_BIN" task restart CHECK --reason 'repeat independent branch' >/dev/null || { fail 'restart verifier closure'; exit 1; }
assert_eq 2 "$(fm_version .orchid/tasks/CHECK.md execution_generation)" 'selected verifier generation advances'
assert_eq 2 "$(fm_version .orchid/tasks/DEEP.md execution_generation)" 'nested verifier generation advances'
assert_eq 1 "$(fm_version .orchid/tasks/BUILD.md execution_generation)" 'upstream generation stays intact'
"$REPO_ROOT/runners/orchid-graph-prepare" CHECK --operation review || { fail 'prepare repeated candidate'; exit 1; }
assert_eq "$candidate" "$(fm_get .orchid/tasks/CHECK.md candidate_sha)" 'same SHA is retained as input'
"$ORCHID_BIN" task advance CHECK reviewing >/dev/null || { fail 'repeat report entry'; exit 1; }
cp "$WORK/old-review.json" .orchid/reviews/CHECK-a1-reviewer.json
refuse 'same SHA does not admit old-generation review' "$ORCHID_BIN" task advance CHECK arbitrating
red_case 'same-SHA old-generation evidence cannot satisfy a restarted verifier'
fresh_review CHECK || { fail 'fresh repeated review'; exit 1; }
"$ORCHID_BIN" task advance CHECK arbitrating >/dev/null || { fail 'fresh repeated evidence counts'; exit 1; }
refuse 'direct merge still requires restarted subtree' "$ORCHID_BIN" merge BUILD
red_case 'direct merge rechecks current required verification after branch restart'
green_case 'fresh generation evidence counts without restarting the unchanged source'
[ "$FAILS" -eq 0 ]
