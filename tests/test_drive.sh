#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# `orchid drive` -- the deterministic one-pass driver.
#
# Part A unit-tests the arbitration truth table directly against
# lib/drive.sh's policy function, so every arm of it is covered exhaustively
# and by structured field, not by luck of fixture timing. Parts B/C then prove
# the same policy end to end against REAL stub engines: an unambiguous happy
# path runs to `done` with no model anywhere in the loop, and a
# request-changes verdict stops at a named judgment boundary with NO
# transition taken.
#
# RED before this task: runners/orchid-drive and lib/drive.sh do not exist.

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/review.sh"
source "$REPO_ROOT/lib/drive.sh"

DRIVE="$REPO_ROOT/runners/orchid-drive"
[ -x "$DRIVE" ] || fail "runners/orchid-drive must exist and be executable"
[ -x "$REPO_ROOT/libexec/orchid-drive" ] || fail "libexec/orchid-drive must exist and be executable (orchid drive)"

# ===========================================================================
# Part A -- the arbitration truth table, exhaustively, against the policy
# function itself. Three mutually exclusive arms, evaluated in this order:
# evidence, then approval, then conflict.
# ===========================================================================
POLICY="$WORK/policy"
mkdir -p "$POLICY/.orchid/tasks" "$POLICY/.orchid/reviews"

CAND=1111111111111111111111111111111111111111

# mk_policy_task <id> <risk_tier> <blocking_severity> [candidate]
mk_policy_task() {
  # `${4-...}`, not `${4:-...}`: omitting the argument still defaults to $CAND,
  # but an explicitly empty one stays empty -- that is how P01 builds a task
  # with no candidate_sha at all.
  local id="$1" tier="$2" bsev="$3" cand="${4-$CAND}"
  printf -- '---\nschema: 1\nid: %s\nstatus: arbitrating\narchetype: feature\nattempts: 0\nrisk_tier: %s\nblocking_severity: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$id" "$tier" "$bsev" "$cand" > "$POLICY/.orchid/tasks/$id.md"
}

# mk_review <id> <slot-suffix> <verdict> <scope_complete> <findings-json> [candidate] [status]
mk_review() {
  local id="$1" suffix="$2" verdict="$3" scope="$4" findings="$5"
  local cand="${6:-$CAND}" status="${7:-ok}"
  jq -n --arg jid "j-fixture-$id-$suffix" --arg task "$id" --arg cand "$cand" \
        --arg v "$verdict" --arg st "$status" --argjson sc "$scope" --argjson f "$findings" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:$st,
      verdict:$v, scope_complete:$sc, summary:"policy fixture",
      candidate_sha:$cand, findings:$f}' \
    > "$POLICY/.orchid/reviews/$id-a1-reviewer$suffix.json"
}

decision_of() { drive_review_decision "$POLICY" "$1" | cut -f1; }
detail_of()   { drive_review_decision "$POLICY" "$1" | cut -f2-; }

# --- severity ranking: the two halves fail closed in OPPOSITE directions ---
assert_eq 0 "$(drive_finding_rank low)" "a low finding ranks 0"
assert_eq 1 "$(drive_finding_rank medium)" "a medium finding ranks 1"
assert_eq 2 "$(drive_finding_rank high)" "a high finding ranks 2"
assert_eq 99 "$(drive_finding_rank catastrophic)" \
  "an unrecognized FINDING severity ranks above every threshold — it always blocks"
assert_eq 0 "$(drive_threshold_rank low)" "a low threshold ranks 0"
assert_eq 2 "$(drive_threshold_rank high)" "a high threshold ranks 2"
assert_eq 1 "$(drive_threshold_rank nonsense)" \
  "an unrecognized THRESHOLD falls back to medium — never to 'nothing blocks'"

# --- boundary priority: can an admitted verb actually resolve this kind? ---
assert_eq 1 "$(drive_boundary_priority review-conflict)" \
  "a review conflict is resolvable by the one verb the broker admits (task arbitrate)"
assert_eq 1 "$(drive_boundary_priority review-evidence)" \
  "a review-evidence boundary is likewise arbitrable"
assert_eq 0 "$(drive_boundary_priority blocked-task)" \
  "a blocked task is operator-only — unblock/retry are verbs the broker refuses"
assert_eq 0 "$(drive_boundary_priority operator-decision)" "operator decisions rank below arbitrable ones"
assert_eq 0 "$(drive_boundary_priority planning)" "planning ranks below arbitrable ones"

# --- evidence arm ----------------------------------------------------------
mk_policy_task P01 low high ""
assert_eq evidence "$(decision_of P01)" "no candidate_sha at all is an evidence boundary"
assert_match "no candidate_sha" "$(detail_of P01)" "the detail says which evidence is missing"

mk_policy_task P02 low high
assert_eq evidence "$(decision_of P02)" "zero reviewer envelopes is an evidence boundary"
assert_match "incomplete review evidence: 0 of 1" "$(detail_of P02)" "the detail counts what is missing against what is required"

mk_policy_task P03 low high
printf 'not json at all\n' > "$POLICY/.orchid/reviews/P03-a1-reviewer.json"
assert_eq evidence "$(decision_of P03)" "a malformed reviewer envelope is an evidence boundary"
assert_match "malformed" "$(detail_of P03)" "the detail names the malformed envelope"

mk_policy_task P04 low high
mk_review P04 "" approve true '[]' "$CAND" failed
assert_eq evidence "$(decision_of P04)" "a non-ok reviewer envelope is an evidence boundary"
assert_match "status failed, not ok" "$(detail_of P04)" "the detail names the offending status"

# Scoping: an envelope bound to another candidate is SUPERSEDED, not evidence
# at all. It is ignored (exactly as the kernel's own reviewing->arbitrating
# gate ignores it), so what remains is an EMPTY evidence set -- incomplete,
# not "stale". Boundarying it instead would pin the task in `arbitrating`
# with no verb able to release it.
mk_policy_task P05 low high
mk_review P05 "" approve true '[]' 2222222222222222222222222222222222222222
assert_eq evidence "$(decision_of P05)" "a review bound to a different candidate leaves NO evidence for the current one"
assert_match "incomplete review evidence: 0 of 1" "$(detail_of P05)" \
  "the superseded envelope is not counted, and the detail says the set is incomplete"
assert_match "bound to candidate $CAND" "$(detail_of P05)" \
  "the detail names the candidate the evidence has to be bound to"

mk_policy_task P06 medium high
mk_review P06 "" approve true '[]'
assert_eq evidence "$(decision_of P06)" "one review where the tier requires two is INCOMPLETE, an evidence boundary"
assert_match "incomplete review evidence: 1 of 2 required for risk_tier medium" "$(detail_of P06)" \
  "the detail names the shortfall and the tier that set the bar"

# --- evidence-set SCOPING, both shapes ------------------------------------
# A reviewer slot relaunched after a rebase (or the merging->testing rebase
# edge moving candidate_sha) leaves a sibling envelope behind under the same
# attempt. The set is scoped to the current candidate FIRST, so the sibling
# is ignored and the valid current approval still decides. Anything else
# would pin the task in `arbitrating` permanently.
mk_policy_task P07 low high
mk_review P07 "" approve true '[]' 3333333333333333333333333333333333333333
mk_review P07 ".2" approve true '[]'
assert_eq approve "$(decision_of P07)" \
  "a SUPERSEDED sibling (different candidate_sha, same attempt) is ignored when the current evidence is complete"
assert_match "unanimous scope-complete approval from 1 review" "$(detail_of P07)" \
  "only the envelopes bound to the current candidate are counted toward the approval"

# ...and scoping does NOT weaken fail-closed: a non-ok envelope bound to the
# CURRENT candidate is still a boundary, even beside a valid approval.
mk_policy_task P08 low high
mk_review P08 "" approve true '[]'
mk_review P08 ".2" approve true '[]' "$CAND" failed
assert_eq evidence "$(decision_of P08)" \
  "a non-ok envelope for the CURRENT candidate still fails closed to an evidence boundary"
assert_match "status failed, not ok" "$(detail_of P08)" "the detail names the offending status"

# A malformed envelope cannot be proven superseded, so it fails closed too.
mk_policy_task P09 low high
mk_review P09 "" approve true '[]'
printf '{"contract":1,"status":"ok"\n' > "$POLICY/.orchid/reviews/P09-a1-reviewer.2.json"
assert_eq evidence "$(decision_of P09)" \
  "an envelope with no readable candidate_sha cannot be scoped, so it fails closed"
assert_match "malformed" "$(detail_of P09)" "the detail names it malformed rather than silently dropping it"

# --- approval arm ----------------------------------------------------------
mk_policy_task P10 low high
mk_review P10 "" approve true '[]'
assert_eq approve "$(decision_of P10)" "a single unanimous scope-complete approval approves at risk_tier low"

mk_policy_task P11 medium high
mk_review P11 "" approve true '[]'
mk_review P11 ".2" approve true '[]'
assert_eq approve "$(decision_of P11)" "two unanimous scope-complete approvals approve at risk_tier medium"
assert_match "unanimous scope-complete approval from 2 review" "$(detail_of P11)" \
  "the approval detail records how many reviews backed it"

mk_policy_task P12 low high
mk_review P12 "" approve true '[{"severity":"medium","title":"a nit below the bar"}]'
assert_eq approve "$(decision_of P12)" "a finding BELOW blocking_severity does not block"

# --- conflict arm ----------------------------------------------------------
mk_policy_task P20 low high
mk_review P20 "" request-changes true '[]'
assert_eq conflict "$(decision_of P20)" "a request-changes verdict is a conflict boundary"
assert_match "verdict=request-changes" "$(detail_of P20)" "the detail names the verdict that blocked approval"

mk_policy_task P21 medium high
mk_review P21 "" approve true '[]'
mk_review P21 ".2" request-changes true '[]'
assert_eq conflict "$(decision_of P21)" "mixed verdicts are a conflict boundary, never a majority vote"

mk_policy_task P22 low high
mk_review P22 "" approve false '[]'
assert_eq conflict "$(decision_of P22)" "a review that did not cover the whole scope is a conflict boundary"
assert_match "scope_complete=false" "$(detail_of P22)" "the detail names the incomplete scope"

mk_policy_task P23 low high
mk_review P23 "" approve true '[{"severity":"high","title":"a real defect"}]'
assert_eq conflict "$(decision_of P23)" "a finding AT blocking_severity blocks even under an approve verdict"
assert_match "finding>=high" "$(detail_of P23)" "the detail names the blocking threshold that was reached"

mk_policy_task P24 low medium
mk_review P24 "" approve true '[{"severity":"medium","title":"now above the bar"}]'
assert_eq conflict "$(decision_of P24)" "blocking_severity is read from the TASK: the same finding blocks at medium"

mk_policy_task P25 low high
mk_review P25 "" approve true '[{"severity":"catastrophic","title":"unknown severity"}]'
assert_eq conflict "$(decision_of P25)" "an unrecognized finding severity is treated as blocking (fail closed)"

# A garbled blocking_severity must fail CLOSED (fall back to medium), never
# open -- the one direction this must never take.
mk_policy_task P26 low nonsense
mk_review P26 "" approve true '[{"severity":"medium","title":"still blocks"}]'
assert_eq conflict "$(decision_of P26)" "an unrecognized blocking_severity falls back to medium, never to 'nothing blocks'"

# ===========================================================================
# Part B -- end to end, real stub engines, no model anywhere: pending ->
# done, entirely under `orchid drive`.
# ===========================================================================
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q .
export ORCHID_REPO="$REPO" HOME="$MACHINE_HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/stubimpl" "$WORK/eng/stubreview" "$WORK/ctl"

printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"

printf 'manifest_version=1\nid=test/stubimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubimpl/plugin.conf"
printf 'manifest_version=1\nid=test/stubreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubreview/plugin.conf"

cat > "$WORK/eng/stubimpl/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
worktree="$(jq -r .worktree "$req")"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
[ "$op" = implement ] || exit 1
cd "$worktree" || exit 1
echo "stub implementation for $task" > stub_feature.txt
git add stub_feature.txt
git -c user.email=stub@example.invalid -c user.name="stub" commit -q -m "stub: implement $task"
sha="$(git rev-parse HEAD)"
jq -n --arg jid "$jid" --arg task "$task" --arg sha "$sha" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"stub implemented", commits:[$sha]}' > "$out"
EOF
chmod +x "$WORK/eng/stubimpl/run"

# The reviewer's verdict/scope/findings come from control FILES so the same
# stub can play both the unambiguous-approval and the request-changes role
# without the test ever editing kernel state by hand.
{
  echo '#!/usr/bin/env bash'
  echo 'set -eu'
  printf 'CTL=%s\n' "$(printf '%q' "$WORK/ctl")"
} > "$WORK/eng/stubreview/run"
cat >> "$WORK/eng/stubreview/run" <<'EOF'
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
cand="$(jq -r .candidate_sha "$req")"
[ "$op" = review ] || exit 1
verdict=approve
scope=true
findings='[]'
if [ -f "$CTL/verdict" ]; then verdict="$(cat "$CTL/verdict")"; fi
if [ -f "$CTL/scope" ]; then scope="$(cat "$CTL/scope")"; fi
if [ -f "$CTL/findings" ]; then findings="$(cat "$CTL/findings")"; fi
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" --arg v "$verdict" \
      --argjson sc "$scope" --argjson f "$findings" \
  '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
    verdict:$v, scope_complete:$sc, summary:"stub review", candidate_sha:$cand, findings:$f}' > "$out"
EOF
chmod +x "$WORK/eng/stubreview/run"

"$ORCHID_BIN" init >/dev/null || fail "orchid init"
integ=orchid/integration
git checkout -q "$integ"

ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

cat > "$WORK/requirements.md" <<'EOF'
# Requirements
- REQ-1: stub_feature.txt reaches the integration branch.
EOF
"$ORCHID_BIN" requirements import "$WORK/requirements.md" >/dev/null
"$ORCHID_BIN" task create T001 "deterministic happy path" >/dev/null
"$ORCHID_BIN" task set T001 verification_commands "test -f stub_feature.txt" >/dev/null
"$ORCHID_BIN" plan apply --reason "initial plan" >/dev/null

status_of() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }

DRIVE_RC=0
DRIVE_OUT=""
run_drive() {
  DRIVE_RC=0
  DRIVE_OUT="$("$DRIVE" 2>&1)" || DRIVE_RC=$?
}

# drive_until <task> <wanted-status> -- repeated deterministic passes. A pass
# that stops at a boundary (16) or fails ends the loop immediately: the point
# of these helpers is that NOTHING but `orchid drive` ever moves the task.
drive_until() {
  local id="$1" want="$2" i=0
  while [ "$i" -lt 40 ]; do
    run_drive
    if [ "$(status_of "$id")" = "$want" ]; then return 0; fi
    if [ "$DRIVE_RC" -ne 0 ]; then return 1; fi
    i=$((i + 1))
    sleep 0.3
  done
  return 1
}

drive_until T001 done || fail "T001 must reach done under repeated deterministic passes alone (last rc=$DRIVE_RC, output: $DRIVE_OUT)"
assert_eq done "$(status_of T001)" "the deterministic driver walked T001 from pending to done with no model in the loop"
assert_eq 0 "$DRIVE_RC" "the pass that completed the walk exits 0 (no judgment boundary)"

# The integration branch really moved, and really carries the stub's commit.
git show "$integ:stub_feature.txt" >/dev/null 2>&1 \
  || fail "the integration branch must carry the file the stub implementer committed"

# Worktree: the deterministic sibling path, registered to this repository.
WORKP="$(cd "$WORK" && pwd -P)"
recorded_wt="$("$ORCHID_BIN" task show T001 | grep '^worktree: ' | cut -d' ' -f2-)"
assert_eq "$WORKP/repo-T001" "$recorded_wt" "the dispatch worktree sits at the deterministic <repo>-<task> sibling path"
[ -d "$recorded_wt" ] || fail "the recorded dispatch worktree must exist on disk"

# Status generation went through the verb (THE TICK step 5), not a hand-rolled
# page: the configured status_page exists after a pass.
[ -f "$REPO/.orchid/runtime/status.html" ] \
  || fail "a pass must regenerate the static status page via orchid status --html"

# No boundary is recorded after a clean pass.
rc=0; "$ORCHID_BIN" run boundary show >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "a clean pass leaves no boundary recorded"

# The approval was recorded through the judgment-result verb, with its
# derivation visible in the journal.
journal="$(cat "$REPO/.orchid/journal.md")"
assert_match "arbitrate\(approve\): deterministic approval" "$journal" \
  "the approval was recorded through orchid task arbitrate, not a bare advance"
assert_match "unanimous scope-complete approval" "$journal" \
  "the journalled reason states the structured basis for the approval"
assert_match "T001 arbitration" "$journal" "the kernel journalled it with the arbitration kind"

# ===========================================================================
# Part C -- a request-changes verdict stops at a judgment boundary, and takes
# NO transition. This is the case the whole design exists for: deterministic
# policy must refuse to decide a real disagreement.
# ===========================================================================
printf 'request-changes\n' > "$WORK/ctl/verdict"

"$ORCHID_BIN" task create T002 "contested review" >/dev/null
"$ORCHID_BIN" task set T002 verification_commands "test -f stub_feature.txt" >/dev/null

drive_until_boundary() {
  local i=0
  while [ "$i" -lt 40 ]; do
    run_drive
    if [ "$DRIVE_RC" -eq 16 ]; then return 0; fi
    if [ "$DRIVE_RC" -ne 0 ]; then return 1; fi
    i=$((i + 1))
    sleep 0.3
  done
  return 1
}

drive_until_boundary || fail "a request-changes verdict must stop the driver at a judgment boundary (last rc=$DRIVE_RC, output: $DRIVE_OUT)"
assert_eq 16 "$DRIVE_RC" "a judgment boundary exits with the dedicated code 16"
assert_eq arbitrating "$(status_of T002)" "the contested task takes NO transition — it stays exactly where it was"

rc=0; boundary="$("$ORCHID_BIN" run boundary show 2>&1)" || rc=$?
assert_eq 16 "$rc" "the boundary is readable back through its own verb, also with exit 16"
assert_eq review-conflict "$(printf '%s' "$boundary" | jq -r .kind)" "the boundary kind names a review conflict, not a generic failure"
assert_eq T002 "$(printf '%s' "$boundary" | jq -r .task)" "the boundary names the task awaiting judgment"
assert_match "verdict=request-changes" "$(printf '%s' "$boundary" | jq -r .reason)" \
  "the boundary reason quotes the structured field that produced it, never prose from the review"

# Re-driving is stable: the same boundary, the same non-transition, no drift.
run_drive
assert_eq 16 "$DRIVE_RC" "a repeated pass over the same boundary reports it again"
assert_eq arbitrating "$(status_of T002)" "a repeated pass still takes no transition"

# The operator (or a woken orchestrator) resolves it through the one judgment
# verb, and the very next pass moves on.
"$ORCHID_BIN" task arbitrate T002 --result request-changes --reason "the finding is real; send it back" >/dev/null
assert_eq rework "$(status_of T002)" "the judgment verb resolves what the driver refused to decide"
printf 'approve\n' > "$WORK/ctl/verdict"
run_drive
rc=0; "$ORCHID_BIN" run boundary show >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "once the judgment is recorded, the next pass clears the boundary"

# ===========================================================================
# Part C2 -- a blocked task must not STARVE another task's arbitrable
# boundary. `blocked` raises the same boundary on EVERY pass until a human
# runs `task unblock`/`task retry` — verbs the broker refuses — so if the
# first boundary in task-id order simply won, a low-numbered blocked task
# would mask every later task's review boundary indefinitely, spending one
# LLM wakeup per pump cycle on a decision the woken model cannot make.
#
# Its own repository, and no engine is ever launched: both fixture tasks are
# parked in states the walk decides on frontmatter and envelopes alone.
# ===========================================================================
STARVE="$WORK/starve"
mkdir -p "$STARVE"
cd "$STARVE" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$STARVE" "$ORCHID_BIN" init >/dev/null || fail "orchid init (starvation fixture)"
git checkout -q orchid/integration

SEPOCH="$(ORCHID_REPO="$STARVE" "$ORCHID_BIN" run start | sed 's/epoch: //')"
sorchid() { ORCHID_REPO="$STARVE" ORCHID_EPOCH="$SEPOCH" "$ORCHID_BIN" "$@"; }

cat > "$WORK/requirements-starve.md" <<'EOF'
# Requirements
- REQ-1: a parked task never hides a decidable one.
EOF
sorchid requirements import "$WORK/requirements-starve.md" >/dev/null
sorchid task create S010 "parked by an operator" >/dev/null
sorchid task create S020 "contested, and later in id order" >/dev/null
sorchid plan apply --reason "initial plan" >/dev/null
sorchid task advance S010 blocked --reason "fixture: an operator must resolve this" >/dev/null
sorchid task advance S020 blocked --reason "fixture: parked for now" >/dev/null

SDRIVE_RC=0
SDRIVE_OUT=""
run_sdrive() {
  SDRIVE_RC=0
  SDRIVE_OUT="$(ORCHID_REPO="$STARVE" ORCHID_EPOCH="$SEPOCH" "$DRIVE" 2>&1)" || SDRIVE_RC=$?
}
sboundary() { ORCHID_REPO="$STARVE" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }

# Pass 1 -- nothing arbitrable in play. A blocked task is STILL a recorded
# boundary (PROTOCOL requires it: that record is how an operator learns the
# run is parked); among equals the first in task-id order wins.
run_sdrive
assert_eq 16 "$SDRIVE_RC" "a pass with only blocked tasks still stops at a judgment boundary"
assert_eq blocked-task "$(sboundary | jq -r .kind)" \
  "with nothing arbitrable in play, the blocked task IS the recorded boundary — this is precedence, not suppression"
assert_eq S010 "$(sboundary | jq -r .task)" "and among equal-priority boundaries the lowest task id wins"

# Pass 2 -- S020 now sits at `arbitrating` over a request-changes review: an
# arbitrable boundary, on a HIGHER task id than the blocked one. The reviewer
# envelope and the frontmatter are written directly, so the pass is decided
# purely by structured fields with no engine in the loop.
SCAND=5555555555555555555555555555555555555555
fm_set "$STARVE/.orchid/tasks/S020.md" status arbitrating
fm_set "$STARVE/.orchid/tasks/S020.md" candidate_sha "$SCAND"
mkdir -p "$STARVE/.orchid/reviews"
jq -n --arg cand "$SCAND" \
  '{contract:1, job_id:"j-fixture-S020", task:"S020", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:"fixture review",
    candidate_sha:$cand, findings:[]}' > "$STARVE/.orchid/reviews/S020-a1-reviewer.json"

run_sdrive
assert_eq 16 "$SDRIVE_RC" "the pass still stops at a boundary"
assert_eq review-conflict "$(sboundary | jq -r .kind)" \
  "the RECORDED boundary is the one an admitted verb can resolve, not the blocked task ahead of it in id order"
assert_eq S020 "$(sboundary | jq -r .task)" \
  "a blocked task never masks a later task's arbitrable boundary"
assert_match "boundary \[blocked-task\] S010" "$SDRIVE_OUT" \
  "the blocked task is still NOTED on the pass — deprioritized, never hidden"
assert_eq blocked "$(ORCHID_REPO="$STARVE" "$ORCHID_BIN" task show S010 | grep '^status: ' | cut -d' ' -f2)" \
  "the blocked task is untouched: ranking a boundary is not resolving it"
assert_eq arbitrating "$(ORCHID_REPO="$STARVE" "$ORCHID_BIN" task show S020 | grep '^status: ' | cut -d' ' -f2)" \
  "and the contested task still takes NO transition"

# Repeating the pass is stable: the same arbitrable boundary wins again.
run_sdrive
assert_eq review-conflict "$(sboundary | jq -r .kind)" "a repeated pass ranks the same way"
assert_eq S020 "$(sboundary | jq -r .task)" "and names the same task"

cd "$REPO" || exit 1
export ORCHID_REPO="$REPO"

# ===========================================================================
# Part D -- preflight. `drive` must be safe to point at anything.
# ===========================================================================
mkdir -p "$WORK/empty"
rc=0; out="$(ORCHID_REPO="$WORK/empty" "$DRIVE" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "drive must refuse a directory that is not an orchid repo"
assert_match "not initialized" "$out" "the refusal names the missing initialization"
[ ! -d "$WORK/empty/.orchid" ] || fail "drive must not seed runtime state into a non-orchid directory"

mkdir -p "$WORK/splitbrain/.orchid/tasks"
rc=0; out="$(ORCHID_REPO="$WORK/splitbrain" "$DRIVE" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "drive must refuse a split-brain checkout"
assert_match "split-brain" "$out" "the refusal names the split-brain condition"

mkdir -p "$WORK/donerun/.orchid/tasks"
printf -- '---\nrun_status: complete\nrun_id: r-001\n---\n# Roadmap\n' > "$WORK/donerun/.orchid/roadmap.md"
rc=0; out="$(ORCHID_REPO="$WORK/donerun" "$DRIVE" 2>&1)" || rc=$?
assert_eq 0 "$rc" "drive exits 0 on a completed run"
assert_match "run_status complete, nothing to do" "$out" "a completed run is a no-op, never a boundary"

# ===========================================================================
# Part E -- epoch discipline. A pass inside a live session keeps that
# session's epoch; a pass with no epoch of its own fences a fresh one
# (INV-02), exactly like the headless tick.
# ===========================================================================
cd "$REPO" || exit 1
epoch_before="$(cat "$REPO/.orchid/runtime/epoch")"
run_drive
assert_eq "$epoch_before" "$(cat "$REPO/.orchid/runtime/epoch")" \
  "a pass inside a live session (ORCHID_EPOCH current) does not re-fence"
assert_match "continuing under epoch $epoch_before" "$DRIVE_OUT" "the pass says which epoch it is continuing under"

rc=0; out="$(env -u ORCHID_EPOCH "$DRIVE" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 16 ] || fail "a pass with no epoch of its own must still run (rc=$rc): $out"
epoch_after="$(cat "$REPO/.orchid/runtime/epoch")"
[ "$epoch_after" -gt "$epoch_before" ] || fail "a pass with no epoch of its own must fence a fresh one ($epoch_before -> $epoch_after)"
assert_match "fenced epoch $epoch_after" "$out" "the pass says which epoch it fenced"
