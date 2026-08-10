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
source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/review.sh"
# capsuite + ledger: drive_orchestrator_surface resolves the orchestrator the
# same way the pump would, and resolve_role_available consults both.
source "$REPO_ROOT/lib/capsuite.sh"
source "$REPO_ROOT/lib/ledger.sh"
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

# --- boundary resolvability: kind AND task status AND command surface ------
# Never the kind alone. A boundary is settleable by a woken orchestrator only
# when some verb records its result, the resolved adapter's command surface
# admits that verb, and the task's current status lets the verb run.
assert_eq 1 "$(drive_boundary_priority review-conflict arbitrating brokered)" \
  "a review conflict on an ARBITRATING task is resolvable by the one write the broker admits"
assert_eq 1 "$(drive_boundary_priority review-evidence arbitrating brokered)" \
  "a review-evidence boundary on an arbitrating task is likewise arbitrable"

# The confirmed defect: the reviewing walk raises review-evidence boundaries
# while the task is still `reviewing`, where `orchid task arbitrate` refuses
# outright (libexec/orchid-task, exit 3). Ranking those as arbitrable let them
# outrank genuine operator-only boundaries with a verb that could not run.
assert_eq 0 "$(drive_boundary_priority review-evidence reviewing brokered)" \
  "the SAME kind on a REVIEWING task is not arbitrable — task arbitrate exits 3 there"
assert_eq 0 "$(drive_boundary_priority review-conflict reviewing soft)" \
  "and the status gate is the verb's own, so it holds on a soft surface too"
if drive_boundary_wakes_orchestrator review-evidence reviewing brokered; then
  fail "waking a model for a review boundary it cannot yet arbitrate changes nothing"
fi

# The other confirmed defect: `run-complete` is settled by `orchid run accept
# --evidence`, which runners/orchid-orchestrator-command does not admit. A
# brokered orchestrator woken for a finished run can do nothing about it.
if drive_boundary_wakes_orchestrator run-complete "" brokered; then
  fail "a brokered adapter cannot run 'orchid run accept' — a finished run is a human's job"
fi
drive_boundary_wakes_orchestrator run-complete "" soft \
  || fail "a soft adapter has no command restriction, so COMPLETION is reachable from it"
if drive_boundary_wakes_orchestrator planning "" brokered; then
  fail "a brokered adapter cannot run 'orchid plan apply' either"
fi
drive_boundary_wakes_orchestrator planning "" soft \
  || fail "a soft adapter can run PLANNING's own recording verb"

# Kinds no verb settles at all are operator-only on EVERY surface.
for kind in blocked-task hook-failure worktree-conflict operator-decision; do
  for surface in brokered soft; do
    assert_eq 0 "$(drive_boundary_priority "$kind" arbitrating "$surface")" \
      "a $kind boundary ranks below arbitrable ones on a $surface surface"
    if drive_boundary_wakes_orchestrator "$kind" arbitrating "$surface"; then
      fail "a $kind boundary needs a human — no verb records its result"
    fi
  done
done

# An unrecognized surface label reads as the NARROWER one, so it can only ever
# route more boundaries to a human, never fewer.
if drive_boundary_wakes_orchestrator run-complete "" nonsense; then
  fail "an unrecognized command_surface must fall back to brokered, never to soft"
fi

# --- evidence arm ----------------------------------------------------------
mk_policy_task P01 low high ""
assert_eq evidence "$(decision_of P01)" "no candidate_sha at all is an evidence boundary"
assert_match "no candidate_sha" "$(detail_of P01)" "the detail says which evidence is missing"

mk_policy_task P02 low high
assert_eq evidence "$(decision_of P02)" "zero reviewer envelopes is an evidence boundary"
assert_match "incomplete review evidence: 0 of 1" "$(detail_of P02)" "the detail counts what is missing against what is required"

mk_policy_task P03 low high
printf 'not json at all\n' > "$POLICY/.orchid/reviews/P03-a1-reviewer.json"
assert_eq evidence "$(decision_of P03)" "a malformed reviewer envelope carries no verdict, so the set is still empty"
assert_match "incomplete review evidence: 0 of 1" "$(detail_of P03)" \
  "it is skipped exactly as the kernel gate skips it, and the shortfall is what stops the pass"

mk_policy_task P04 low high
mk_review P04 "" approve true '[]' "$CAND" failed
assert_eq evidence "$(decision_of P04)" "a non-ok reviewer envelope likewise leaves the set empty"
assert_match "incomplete review evidence: 0 of 1" "$(detail_of P04)" \
  "the detail counts what is on hand against what the tier requires"

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

# THE ORDINARY RECOVERY PATH, and the reason the arms below count rather
# than fail closed on a dead sibling (lesson L007). A reviewer slot errors,
# `orchid jobs reconcile` files the adapter's own non-ok envelope (`failed`,
# `timeout`, `rate_limited` — all of them valid envelopes, all of them BOUND
# TO THE CURRENT CANDIDATE), and the relaunch then files a good one. The
# kernel's own
# reviewing->arbitrating gate ignores the dead envelope and counts the live
# one -- its comment says so verbatim: "Only status==ok envelopes count;
# anything else is silently skipped, same as an sha mismatch" -- so the task
# reaches `arbitrating` with a complete unanimous set. If this policy
# boundaried on the dead envelope instead, that task would be permanently
# refused deterministic approval over a file NO VERB CAN REMOVE.
mk_policy_task P08 low high
mk_review P08 "" approve true '[]' "$CAND" timeout
assert_eq evidence "$(decision_of P08)" \
  "before the relaunch lands, the dead envelope counts for nothing: the set is short"
assert_match "incomplete review evidence: 0 of 1" "$(detail_of P08)" \
  "and the shortfall is the reason, not the dead envelope"
mk_review P08 ".2" approve true '[]'
assert_eq approve "$(decision_of P08)" \
  "the relaunch's own review completes the set, and the dead sibling never blocks approval"
assert_match "unanimous scope-complete approval from 1 review" "$(detail_of P08)" \
  "only the valid ok current envelopes are counted toward the approval"

# Same for a malformed sibling: it carries no verdict to weigh, and no verb
# can delete it, so it is skipped rather than made permanent.
mk_policy_task P09 low high
mk_review P09 "" approve true '[]'
printf '{"contract":1,"status":"ok"\n' > "$POLICY/.orchid/reviews/P09-a1-reviewer.2.json"
assert_eq approve "$(decision_of P09)" \
  "an unreadable envelope is skipped exactly as the kernel gate skips it, never boundaried forever"

# The count this policy uses can only ever be LOWER than the kernel gate's --
# it adds envelope_validate on top of the gate's own two tests -- so a
# shortfall still stops the pass, and it stops it at `arbitrating`, which is
# exactly where `orchid task arbitrate` can settle it.
mk_policy_task P09b medium high
mk_review P09b "" approve true '[]'
printf '{"contract":1,"status":"ok","candidate_sha":"%s"}\n' "$CAND" \
  > "$POLICY/.orchid/reviews/P09b-a1-reviewer.2.json"
assert_eq evidence "$(decision_of P09b)" \
  "an envelope the kernel gate counts but envelope_validate rejects leaves the policy short, not silently approving"
assert_match "incomplete review evidence: 1 of 2" "$(detail_of P09b)" \
  "and the shortfall says so in counts"

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
# Part A2 -- slot attribution. Which SLOT a filed review belongs to is what
# decides whether the tier's independence requirement is met, and it is
# decided by the envelope's own `.engine` (cross-checked against the job
# manifest by `orchid jobs reconcile` before filing, then the only surviving
# record of who produced it) -- never by counting envelopes.
# ===========================================================================

# mk_review_eng <id> <suffix> <verdict> <engine-qualified-id> -- an ok,
# scope-complete, finding-free review for the current candidate that NAMES the
# engine that produced it. `""` means an adapter that omitted the field.
mk_review_eng() {
  local id="$1" suffix="$2" verdict="$3" eng="$4"
  jq -n --arg jid "j-fixture-$id-$suffix" --arg task "$id" --arg cand "$CAND" \
        --arg v "$verdict" --arg e "$eng" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:$v, scope_complete:true, summary:"policy fixture",
      candidate_sha:$cand, findings:[]}
     + (if $e == "" then {} else {engine:$e} end)' \
    > "$POLICY/.orchid/reviews/$id-a1-reviewer$suffix.json"
}

# Engine names in a routing row are plugin NAMES; an unresolvable one
# qualifies to `orchid/<name>` (resolve_engine_qualified_id's documented
# fallback), which is what these fixtures write into `.engine`.
TWO_SLOTS="$(printf '1\talpha\tengine-independent\n2\tbeta\tengine-independent\n')"

mk_policy_task P30 medium high
mk_review_eng P30 "" approve orchid/alpha
mk_review_eng P30 ".2" approve orchid/alpha
assert_eq 2 "$(drive_review_slots_unsatisfied "$POLICY" P30 "$TWO_SLOTS" | cut -f1)" \
  "two reviews from ONE engine leave the slot routed to the OTHER engine unsatisfied"
assert_eq 2 "$(drive_reviewer_envelope_count "$POLICY" P30)" \
  "...even though the raw envelope count the kernel gate uses is already met"

mk_policy_task P31 medium high
mk_review_eng P31 "" approve orchid/alpha
mk_review_eng P31 ".2" approve orchid/beta
assert_eq "" "$(drive_review_slots_unsatisfied "$POLICY" P31 "$TWO_SLOTS")" \
  "one review per routed engine satisfies both slots"

# The DEGRADED routing `review_routing` already labels session-independent:
# one engine really was asked for both slots, so two of its reviews are
# exactly what was ordered.
mk_policy_task P32 medium high
mk_review_eng P32 "" approve orchid/alpha
mk_review_eng P32 ".2" approve orchid/alpha
assert_eq "" "$(drive_review_slots_unsatisfied "$POLICY" P32 \
  "$(printf '1\talpha\tengine-independent\n2\talpha\tsession-independent\n')")" \
  "a routing table that asks ONE engine for both slots is satisfied by two of its reviews"

# An adapter that names no engine cannot be attributed, so it is credited
# last, to whatever slot is still open -- refusing it outright would relaunch
# that slot forever.
mk_policy_task P33 medium high
mk_review_eng P33 "" approve orchid/alpha
mk_review_eng P33 ".2" approve ""
assert_eq "" "$(drive_review_slots_unsatisfied "$POLICY" P33 "$TWO_SLOTS")" \
  "a review that names no engine still covers a slot nothing else claims"

mk_policy_task P34 medium high
mk_review_eng P34 "" approve orchid/beta
assert_eq 1 "$(drive_review_slots_unsatisfied "$POLICY" P34 "$TWO_SLOTS" | cut -f1)" \
  "attribution is by engine, not by slot order: beta's review covers SLOT 2"

# --- hook evidence is scoped to the current candidate, same as review ------
mk_hook_env() {  # <id> <suffix> <candidate|-> -- a filed hook envelope
  local id="$1" suffix="$2" cand="$3"
  jq -n --arg jid "j-fixture-$id$suffix" --arg task "$id" --arg cand "$cand" \
    '{contract:1, job_id:$jid, task:$task, operation:"hook", status:"ok",
      engine:"orchid/alpha", summary:"hook fixture"}
     + (if $cand == "-" then {} else {candidate_sha:$cand} end)' \
    > "$POLICY/.orchid/reviews/$id-a1-hook-before_arbitration$suffix.json"
}
mk_policy_task P40 low high
mk_hook_env P40 "" "$CAND"
assert_eq 1 "$(drive_hook_envelope_count "$POLICY" P40 before_arbitration 1 "$CAND")" \
  "an envelope bound to the current candidate is evidence on hand"
assert_eq 0 "$(drive_hook_envelope_count "$POLICY" P40 before_arbitration 1 4444444444444444444444444444444444444444)" \
  "one left behind by a candidate that has since moved is not — the point is dispatched again"
mk_policy_task P41 low high
mk_hook_env P41 "" -
assert_eq 1 "$(drive_hook_envelope_count "$POLICY" P41 before_arbitration 1 "$CAND")" \
  "an envelope with no candidate_sha cannot be PROVEN superseded, so it still counts (fail closed)"

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

drive_until T001 "done" || fail "T001 must reach done under repeated deterministic passes alone (last rc=$DRIVE_RC, output: $DRIVE_OUT)"
assert_eq "done" "$(status_of T001)" "the deterministic driver walked T001 from pending to done with no model in the loop"
assert_eq 0 "$DRIVE_RC" "the pass that completed the walk exits 0 (no judgment boundary)"

# The integration branch really moved, and really carries the stub's commit.
git show "$integ:stub_feature.txt" >/dev/null 2>&1 \
  || fail "the integration branch must carry the file the stub implementer committed"

# Worktree: the deterministic sibling path, registered to this repository.
WORKP="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root"; exit 1; }
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

# ...and because the task really is `arbitrating`, `orchid task arbitrate`
# would run: this is the one shape a woken orchestrator settles in one call,
# so no operator blocker is raised for it.
case "$DRIVE_OUT" in
  *"notified: [review-conflict]"*)
    fail "a review conflict on an ARBITRATING task is arbitrable — it must not be routed to a human" ;;
esac

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

# ===========================================================================
# Part F -- a dispatch whose LAUNCH cannot spawn must leave the task
# dispatchable. `no eligible engine` (exit 14) is a WAIT: the ledger window
# reopens on its own and the identical dispatch succeeds later with no
# operator action (PROTOCOL.md's Failover paragraph). A task advanced into an
# active status by a dispatch that never spawned would instead wait forever on
# an envelope nobody is producing -- no job for `jobs check` to see, no
# envelope for the walk to read, no boundary, exit 0, silence.
# ===========================================================================
WAITREPO="$WORK/dispatchwait"
mkdir -p "$WAITREPO"
cd "$WAITREPO" || exit 1
git init -q .
printf 'role.implementer=stubwait\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$WAITREPO" "$ORCHID_BIN" init >/dev/null || fail "orchid init (dispatch-wait fixture)"
git checkout -q orchid/integration

# The implementer engine starts INELIGIBLE for its role (it declares none of
# implementer.role's required capabilities), which is exactly what an empty
# failover chain looks like from `jobs prepare`: exit 14, no manifest minted,
# nothing spawned.
mkdir -p "$WORK/eng/stubwait"
printf 'manifest_version=1\nid=test/stubwait\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubwait/plugin.conf"
cat > "$WORK/eng/stubwait/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
worktree="$(jq -r .worktree "$req")"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
cd "$worktree" || exit 1
echo "stub implementation for $task" > stub_feature.txt
git add stub_feature.txt
git -c user.email=stub@example.invalid -c user.name="stub" commit -q -m "stub: implement $task"
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"stub implemented"}' > "$out"
EOF
chmod +x "$WORK/eng/stubwait/run"

WEPOCH="$(ORCHID_REPO="$WAITREPO" "$ORCHID_BIN" run start | sed 's/epoch: //')"
worchid() { ORCHID_REPO="$WAITREPO" ORCHID_EPOCH="$WEPOCH" "$ORCHID_BIN" "$@"; }
worchid requirements import "$WORK/requirements.md" >/dev/null
worchid task create W010 "dispatch must wait for an engine" >/dev/null
worchid task set W010 verification_commands "test -f stub_feature.txt" >/dev/null
worchid plan apply --reason "initial plan" >/dev/null

WDRIVE_RC=0; WDRIVE_OUT=""
run_wdrive() {
  WDRIVE_RC=0
  WDRIVE_OUT="$(ORCHID_REPO="$WAITREPO" ORCHID_EPOCH="$WEPOCH" "$DRIVE" 2>&1)" || WDRIVE_RC=$?
}
wstatus_of() { ORCHID_REPO="$WAITREPO" "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }

run_wdrive
assert_eq 0 "$WDRIVE_RC" "no eligible engine is a WAIT state, not a judgment boundary"
assert_eq pending "$(wstatus_of W010)" \
  "a dispatch whose launch never spawned leaves the task in its PRIOR status, still dispatchable"
assert_match "no eligible engine for role 'implementer'" "$WDRIVE_OUT" \
  "the pass names what it is waiting for"
assert_match "staying in pending" "$WDRIVE_OUT" \
  "and says it took no transition, so nothing is waiting on an envelope nobody will produce"
[ -z "$(list_dir_files "$WAITREPO/.orchid/runtime/jobs")" ] \
  || fail "an exit-14 dispatch must leave no job manifest behind"

# The window reopens (here: the engine becomes role-eligible). The IDENTICAL
# dispatch, with no operator action of any kind, now succeeds.
printf 'manifest_version=1\nid=test/stubwait\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubwait/plugin.conf"
run_wdrive
assert_eq implementing "$(wstatus_of W010)" \
  "the next pass dispatches the very same task — the wait cost nothing but a pass (rc=$WDRIVE_RC, out: $WDRIVE_OUT)"
[ -n "$(list_dir_files "$WAITREPO/.orchid/runtime/jobs")" ] \
  || fail "the advance into implementing must be backed by a job that really spawned"

# ===========================================================================
# Part G -- a run whose tasks are ALL done hands off instead of polling.
# `done` is the one status the walk decides nothing about, so without this a
# finished headless run would poll forever: every pass clean, exit 0,
# run_status never leaving `running`, and nobody woken to notice the run is
# over. COMPLETION's mechanical first step is taken here; its judgment half
# (acceptance checks, then `orchid run accept --evidence`) is the boundary.
# ===========================================================================
FINISHED="$WORK/finished"
mkdir -p "$FINISHED"
cd "$FINISHED" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$FINISHED" "$ORCHID_BIN" init >/dev/null || fail "orchid init (finished-run fixture)"
git checkout -q orchid/integration
FEPOCH="$(ORCHID_REPO="$FINISHED" "$ORCHID_BIN" run start | sed 's/epoch: //')"
forchid() { ORCHID_REPO="$FINISHED" ORCHID_EPOCH="$FEPOCH" "$ORCHID_BIN" "$@"; }
forchid requirements import "$WORK/requirements.md" >/dev/null
forchid task create F010 "the only task, and it is finished" >/dev/null
forchid plan apply --reason "initial plan" >/dev/null
fm_set "$FINISHED/.orchid/tasks/F010.md" status "done"

FDRIVE_RC=0
fboundary() { ORCHID_REPO="$FINISHED" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }
frun_status() { fm_get "$FINISHED/.orchid/roadmap.md" run_status; }

FDRIVE_OUT="$(ORCHID_REPO="$FINISHED" ORCHID_EPOCH="$FEPOCH" "$DRIVE" 2>&1)" || FDRIVE_RC=$?
assert_eq 16 "$FDRIVE_RC" "a run with nothing left to do stops at a judgment boundary (out: $FDRIVE_OUT)"
assert_eq run-complete "$(fboundary | jq -r .kind)" "the boundary names the run's completion, not a generic operator decision"
assert_eq "" "$(fboundary | jq -r .task)" "it is a RUN-level boundary: no task is named"
assert_eq accepting "$(frun_status)" \
  "COMPLETION's mechanical first step (run advance accepting) is taken deterministically"

# Stable on repetition: the run_status advance happens once, the hand-off
# keeps being offered until an orchestrator actually accepts the run.
FDRIVE_RC=0
FDRIVE_OUT="$(ORCHID_REPO="$FINISHED" ORCHID_EPOCH="$FEPOCH" "$DRIVE" 2>&1)" || FDRIVE_RC=$?
assert_eq 16 "$FDRIVE_RC" "a repeated pass over a finished run reports the same boundary"
assert_eq accepting "$(frun_status)" "and does not try to advance run_status a second time"
assert_eq run-complete "$(fboundary | jq -r .kind)" "the recorded boundary is unchanged"

# ===========================================================================
# Part H -- reviewer slots are keyed on IDENTITY, never on a count. A
# relaunch that lands a second review from the slot that already reported
# must never satisfy an engine-independent requirement: counting would both
# stop the missing slot from ever being dispatched AND hand the truth table
# two reviews from one engine to approve unanimously.
# ===========================================================================
SLOTS="$WORK/slots"
mkdir -p "$SLOTS"
cd "$SLOTS" || exit 1
git init -q .
mkdir -p "$WORK/eng/revalpha" "$WORK/eng/revbeta"
for e in revalpha revbeta; do
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
    "$e" > "$WORK/eng/$e/plugin.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/eng/$e/run"
  chmod +x "$WORK/eng/$e/run"
done
printf 'role.implementer=stubimpl\nrole.reviewer=revalpha\nreview.medium=revalpha,revbeta\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$SLOTS" "$ORCHID_BIN" init >/dev/null || fail "orchid init (slot fixture)"
git checkout -q orchid/integration
LEPOCH="$(ORCHID_REPO="$SLOTS" "$ORCHID_BIN" run start | sed 's/epoch: //')"
lorchid() { ORCHID_REPO="$SLOTS" ORCHID_EPOCH="$LEPOCH" "$ORCHID_BIN" "$@"; }
lorchid requirements import "$WORK/requirements.md" >/dev/null
lorchid task create L010 "two slots, two engines" >/dev/null
lorchid plan apply --reason "initial plan" >/dev/null
lorchid task set L010 risk_tier medium --reason "fixture: two reviewer slots" >/dev/null

LCAND=7777777777777777777777777777777777777777
fm_set "$SLOTS/.orchid/tasks/L010.md" status reviewing
fm_set "$SLOTS/.orchid/tasks/L010.md" candidate_sha "$LCAND"

# Sanity: the routing table really does ask for two DIFFERENT engines.
routing="$(ORCHID_REPO="$SLOTS" "$ORCHID_BIN" jobs review-plan L010)"
assert_eq revalpha "$(printf '%s\n' "$routing" | sed -n 1p | cut -f2)" "slot 1 routes to the first eligible reviewer engine"
assert_eq revbeta "$(printf '%s\n' "$routing" | sed -n 2p | cut -f2)" "slot 2 routes to a DIFFERENT engine (engine independence)"

# Both reviews come from slot 1's engine -- the shape a relaunch through the
# role's default chain produces. Unanimous, scope-complete, finding-free: the
# only thing wrong with them is that they are the same reviewer twice.
mk_slot_review() {  # <suffix> <engine> <verdict>
  jq -n --arg jid "j-fixture-L010-$1" --arg cand "$LCAND" --arg e "$2" --arg v "$3" \
    '{contract:1, job_id:$jid, task:"L010", operation:"review", status:"ok",
      verdict:$v, scope_complete:true, summary:"slot fixture",
      candidate_sha:$cand, engine:$e, findings:[]}' \
    > "$SLOTS/.orchid/reviews/L010-a1-reviewer$1.json"
}
mkdir -p "$SLOTS/.orchid/reviews"
mk_slot_review "" test/revalpha approve
mk_slot_review ".2" test/revalpha approve

LDRIVE_RC=0
LDRIVE_OUT="$(ORCHID_REPO="$SLOTS" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || LDRIVE_RC=$?
lboundary() { ORCHID_REPO="$SLOTS" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }
lstatus() { ORCHID_REPO="$SLOTS" "$ORCHID_BIN" task show L010 | grep '^status: ' | cut -d' ' -f2; }

assert_eq 16 "$LDRIVE_RC" "two reviews from one engine stop the pass at a boundary (out: $LDRIVE_OUT)"
assert_eq reviewing "$(lstatus)" \
  "the task does NOT advance: an engine-independent requirement is not met by the same reviewer twice"
assert_eq review-evidence "$(lboundary | jq -r .kind)" "the boundary names the evidence problem"
assert_match "independence is unproven" "$(lboundary | jq -r .reason)" \
  "the reason says which requirement the evidence fails, in structured terms"
if grep -q 'arbitrate(approve)' "$SLOTS/.orchid/journal.md"; then
  fail "two same-engine reviews must never reach a deterministic approval"
fi

# THE REVIEWING CASE. This boundary was raised while L010 is still
# `reviewing`, and `orchid task arbitrate` refuses any status but
# `arbitrating` (libexec/orchid-task, exit 3). So no verb an orchestrator can
# run settles it, whatever its command surface -- it must be ranked
# operator-only AND routed to the `orchid notify` blocker path, or the
# condition would wake a model every staleness window forever with nobody
# ever told.
assert_eq reviewing "$(lstatus)" "precondition: the boundary really is raised while the task is reviewing"
assert_eq 0 "$(drive_boundary_priority review-evidence reviewing brokered)" \
  "a review boundary on a reviewing task ranks operator-only"
assert_match "notified: \[review-evidence\] is operator-only" "$LDRIVE_OUT" \
  "so the pass says it routed this one to a human instead of to a model"
assert_match "judgment boundary \[review-evidence\] needs an operator" \
  "$(cat "$SLOTS/.orchid/BLOCKERS.md")" \
  "and the blocker really is recorded where an operator reads it"

# One review per routed engine, and the same evidence set advances. (Both are
# request-changes here so the walk stops at `arbitrating` instead of running
# on into a merge, which this fixture has no real candidate for.)
mk_slot_review "" test/revalpha request-changes
mk_slot_review ".2" test/revbeta request-changes
LDRIVE_RC=0
LDRIVE_OUT="$(ORCHID_REPO="$SLOTS" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || LDRIVE_RC=$?
assert_eq arbitrating "$(lstatus)" \
  "with each routed slot covered by its OWN engine, the gate passes (rc=$LDRIVE_RC, out: $LDRIVE_OUT)"
assert_eq review-conflict "$(lboundary | jq -r .kind)" \
  "and the pass then stops on the verdicts themselves, not on the evidence set"

# ===========================================================================
# Part I -- THE RUN-COMPLETE CASE. `orchid run accept --evidence` is the only
# verb that closes a finished run, and runners/orchid-orchestrator-command
# does not admit it. So against a `command_surface=brokered` orchestrator a
# finished run is a HUMAN's job: waking a model for it would spend one wakeup
# per staleness window on a verb the model cannot reach, and -- because the
# notify path is suppressed for anything an orchestrator can settle -- the
# operator would never be told to run the acceptance step at all.
#
# The orchestrator engine is PINNED here (role.orchestrator=), never left to
# the default chain: the whole point is that the assertion depends on the
# resolved adapter's declared surface, so the fixture must decide it.
# ===========================================================================
mk_surface_engine() {  # <name> <brokered|soft>
  local dir="$WORK/eng/$1"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell,git\nrequires_binaries=jq\nentrypoint=run\ncommand_surface=%s\n' \
    "$1" "$2" > "$dir/plugin.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/run"
  chmod +x "$dir/run"
}
mk_surface_engine stubbrokered brokered
mk_surface_engine stubsoft soft

# Sanity, straight off the manifests the fixture just wrote: the label really
# is what the classification below is reading.
assert_eq brokered "$(manifest_get "$WORK/eng/stubbrokered" command_surface soft)" \
  "the brokered fixture engine declares the restricted surface"
assert_eq soft "$(manifest_get "$WORK/eng/stubsoft" command_surface soft)" \
  "and the soft one declares the unrestricted one"

# ...and the resolution the driver and the pump both make really does read
# the PINNED orchestrator's own label, all three ways.
SURF="$WORK/surfaceprobe"
mkdir -p "$SURF"
printf 'role.orchestrator=stubsoft\n' > "$SURF/orchid.config"
assert_eq soft "$(drive_orchestrator_surface "$SURF")" \
  "the surface is read off the orchestrator this repo would actually wake"
printf 'role.orchestrator=stubbrokered\n' > "$SURF/orchid.config"
assert_eq brokered "$(drive_orchestrator_surface "$SURF")" \
  "...and follows the binding when it changes, never a hardcoded default"
printf 'role.orchestrator=zqxwv-no-such-engine\n' > "$SURF/orchid.config"
assert_eq brokered "$(drive_orchestrator_surface "$SURF")" \
  "when no orchestrator resolves at all, nobody is woken — so the narrowest surface is the honest answer"

BROK="$WORK/brokeredrun"
mkdir -p "$BROK"
cd "$BROK" || exit 1
git init -q .
printf 'role.orchestrator=stubbrokered\nrole.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$BROK" "$ORCHID_BIN" init >/dev/null || fail "orchid init (brokered-completion fixture)"
git checkout -q orchid/integration
BEPOCH="$(ORCHID_REPO="$BROK" "$ORCHID_BIN" run start | sed 's/epoch: //')"
borchid() { ORCHID_REPO="$BROK" ORCHID_EPOCH="$BEPOCH" "$ORCHID_BIN" "$@"; }
borchid requirements import "$WORK/requirements.md" >/dev/null
borchid task create B010 "the only task, and it is finished" >/dev/null
borchid plan apply --reason "initial plan" >/dev/null
fm_set "$BROK/.orchid/tasks/B010.md" status "done"

assert_eq brokered "$(drive_orchestrator_surface "$BROK")" \
  "the pinned orchestrator's own manifest decides which surface this repo would wake"

BDRIVE_RC=0
BDRIVE_OUT="$(ORCHID_REPO="$BROK" ORCHID_EPOCH="$BEPOCH" "$DRIVE" 2>&1)" || BDRIVE_RC=$?
bboundary() { ORCHID_REPO="$BROK" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }

assert_eq 16 "$BDRIVE_RC" "a finished run still stops at a judgment boundary (out: $BDRIVE_OUT)"
assert_eq run-complete "$(bboundary | jq -r .kind)" "and the boundary still names the run's completion"
assert_match "notified: \[run-complete\] is operator-only" "$BDRIVE_OUT" \
  "but against a brokered orchestrator it is routed to a human, not held for a model"
assert_match "judgment boundary \[run-complete\] needs an operator" \
  "$(cat "$BROK/.orchid/BLOCKERS.md")" \
  "and the blocker that tells the operator to run the acceptance step is really raised"
if drive_boundary_wakes_orchestrator run-complete "" "$(drive_orchestrator_surface "$BROK")"; then
  fail "no model may be woken for a boundary whose only settling verb its adapter refuses"
fi

# Repeating the pass raises no SECOND blocker: the record is unchanged, and
# the notify is sent once per distinct record, not once per pass.
b_blockers_before="$(wc -l < "$BROK/.orchid/BLOCKERS.md")"
BDRIVE_RC=0
BDRIVE_OUT="$(ORCHID_REPO="$BROK" ORCHID_EPOCH="$BEPOCH" "$DRIVE" 2>&1)" || BDRIVE_RC=$?
assert_eq 16 "$BDRIVE_RC" "a repeated pass over the finished run reports the same boundary"
assert_eq "$b_blockers_before" "$(wc -l < "$BROK/.orchid/BLOCKERS.md")" \
  "and raises no second blocker for a record that has not changed"

# The same run, driven for a SOFT orchestrator, is the other half of the
# classification: nothing restricts that adapter's commands, so COMPLETION is
# reachable from it and the boundary is left for the model rather than a
# human. Same kind, same record, opposite routing -- which is exactly why the
# decision cannot be made from the kind alone.
if ! drive_boundary_wakes_orchestrator run-complete "" soft; then
  fail "a soft adapter can run 'orchid run accept', so COMPLETION is an orchestrator procedure there"
fi

# ===========================================================================
# Part I2 -- the ordinary reviewer-slot recovery, end to end (lesson L007).
# A slot errors, `orchid jobs reconcile` files the adapter's own non-ok
# envelope BOUND TO THE CURRENT CANDIDATE, and the relaunch files a good one.
# The kernel's reviewing->arbitrating gate ignores the dead envelope and
# counts the live one, so the task arrives at `arbitrating` with a complete
# unanimous set. Deterministic approval must then happen: the dead envelope
# is a file no verb can delete, so refusing over it would park the task
# forever.
# ===========================================================================
RECOV="$WORK/recovery"
mkdir -p "$RECOV"
cd "$RECOV" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$RECOV" "$ORCHID_BIN" init >/dev/null || fail "orchid init (recovery fixture)"
git checkout -q orchid/integration
REPOCH="$(ORCHID_REPO="$RECOV" "$ORCHID_BIN" run start | sed 's/epoch: //')"
rorchid() { ORCHID_REPO="$RECOV" ORCHID_EPOCH="$REPOCH" "$ORCHID_BIN" "$@"; }
rorchid requirements import "$WORK/requirements.md" >/dev/null
rorchid task create R010 "a reviewer slot died and was relaunched" >/dev/null
rorchid plan apply --reason "initial plan" >/dev/null

RCAND=8888888888888888888888888888888888888888
fm_set "$RECOV/.orchid/tasks/R010.md" status arbitrating
fm_set "$RECOV/.orchid/tasks/R010.md" candidate_sha "$RCAND"
mkdir -p "$RECOV/.orchid/reviews"
mk_recov_review() {  # <suffix> <status> <verdict>
  jq -n --arg jid "j-fixture-R010-$1" --arg cand "$RCAND" --arg st "$2" --arg v "$3" \
    '{contract:1, job_id:$jid, task:"R010", operation:"review", status:$st,
      verdict:$v, scope_complete:true, summary:"recovery fixture",
      candidate_sha:$cand, findings:[]}' \
    > "$RECOV/.orchid/reviews/R010-a1-reviewer$1.json"
}
# The dead slot's own envelope: valid, current, and NOT ok -- exactly what
# reconcile files when an adapter reports timeout/failure.
mk_recov_review "" timeout approve
# ...and the relaunch's real review.
mk_recov_review ".2" ok approve

assert_eq 1 "$(drive_reviewer_envelope_count "$RECOV" R010)" \
  "the kernel's own gate counts only the live envelope — the dead one is skipped, not fatal"
assert_eq approve "$(drive_review_decision "$RECOV" R010 | cut -f1)" \
  "and the policy agrees with the gate: a complete unanimous set approves over a dead sibling"

RDRIVE_RC=0
RDRIVE_OUT="$(ORCHID_REPO="$RECOV" ORCHID_EPOCH="$REPOCH" "$DRIVE" 2>&1)" || RDRIVE_RC=$?
rstatus() { ORCHID_REPO="$RECOV" "$ORCHID_BIN" task show R010 | grep '^status: ' | cut -d' ' -f2; }
if [ "$(rstatus)" = arbitrating ]; then
  fail "a task whose live evidence is complete must not be parked in arbitrating over a dead envelope (rc=$RDRIVE_RC, out: $RDRIVE_OUT)"
fi
assert_match "arbitrate\(approve\): deterministic approval" "$(cat "$RECOV/.orchid/journal.md")" \
  "the approval was recorded through the judgment verb despite the dead sibling"

# ===========================================================================
# Part J -- a PREPARED-BUT-NEVER-SPAWNED job manifest is not a live job.
# `orchid jobs prepare` mints every manifest with `pid: 0` and
# runners/orchid-launch stamps the real pid only after the spawn, so a pid-0
# manifest means a launch died in between and nothing is running. Nothing
# else in the kernel reads one as live -- the escalation sweep skips pid 0,
# ordinary `jobs gc` skips pid 0 -- so adopting one would advance a task into
# `implementing` behind a job that will never produce an envelope: no
# `jobs check` finding, no infra-fail, no boundary, silence forever.
# ===========================================================================
PREP="$WORK/prepared"
mkdir -p "$PREP"
cd "$PREP" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$PREP" "$ORCHID_BIN" init >/dev/null || fail "orchid init (prepared-manifest fixture)"
git checkout -q orchid/integration
PEPOCH="$(ORCHID_REPO="$PREP" "$ORCHID_BIN" run start | sed 's/epoch: //')"
porchid() { ORCHID_REPO="$PREP" ORCHID_EPOCH="$PEPOCH" "$ORCHID_BIN" "$@"; }
porchid requirements import "$WORK/requirements.md" >/dev/null
porchid task create P010 "a crashed launch left a prepared manifest" >/dev/null
porchid task set P010 verification_commands "test -f stub_feature.txt" >/dev/null
porchid plan apply --reason "initial plan" >/dev/null

# Exactly the shape `jobs prepare` mints and `orchid-launch` never got to
# stamp: pid 0, pgid 0, started_at 0.
ORPHAN="$PREP/.orchid/runtime/jobs/j-e1-P010-a1-beef.json"
mkdir -p "$PREP/.orchid/runtime/jobs"
jq -n '{job_id:"j-e1-P010-a1-beef", task:"P010", attempt:1, role:"implementer",
        operation:"implement", engine:"stubimpl", pid:0, pgid:0, started_at:0,
        log:"/dev/null", output:"/dev/null", base_sha:"", candidate_sha:"",
        hook_point:""}' > "$ORPHAN"

PDRIVE_RC=0
PDRIVE_OUT="$(ORCHID_REPO="$PREP" ORCHID_EPOCH="$PEPOCH" "$DRIVE" 2>&1)" || PDRIVE_RC=$?
pstatus() { ORCHID_REPO="$PREP" "$ORCHID_BIN" task show P010 | grep '^status: ' | cut -d' ' -f2; }

case "$PDRIVE_OUT" in
  *"adopting the implement job"*)
    fail "a pid-0 manifest is not a spawned job — adopting one advances a task behind nothing (out: $PDRIVE_OUT)" ;;
esac
assert_eq implementing "$(pstatus)" \
  "the task still advances, but only because the pass RELAUNCHED (rc=$PDRIVE_RC, out: $PDRIVE_OUT)"
live_pids="$(for _m in "$PREP/.orchid/runtime/jobs"/*.json; do
               [ -e "$_m" ] || continue
               jq -r 'select((.pid // 0) != 0) | .job_id' "$_m"
             done)"
[ -n "$live_pids" ] \
  || fail "the advance into implementing must be backed by a manifest that carries a real pid"

# The orphan is still there: the reap is BOUNDED, so a manifest younger than
# stall_minutes is left alone in case a launcher is mid-flight over it.
[ -f "$ORPHAN" ] \
  || fail "a freshly-prepared manifest must not be reaped — a live launcher may still be between prepare and spawn"

# Age it past the bound, and the pass reaps it through the verb's own
# --reap-prepared mode. Nothing else in the kernel ever would.
touch -t 202001010000 "$ORPHAN"
PDRIVE_RC=0
PDRIVE_OUT="$(ORCHID_REPO="$PREP" ORCHID_EPOCH="$PEPOCH" "$DRIVE" 2>&1)" || PDRIVE_RC=$?
assert_match "gc-prepared j-e1-P010-a1-beef" "$PDRIVE_OUT" \
  "an aged prepared manifest is reaped through orchid jobs gc --reap-prepared"
[ ! -f "$ORPHAN" ] \
  || fail "the reaped manifest must leave the jobs dir (out: $PDRIVE_OUT)"

# ===========================================================================
# Part K -- the lease must stay fresh THROUGH a long synchronous verify.
# `orchid verify` runs the task's whole suite in the pass's own foreground.
# With the lease refreshed only at the two ends of a pass, a suite longer
# than `pump_stale_s` makes the running pass's own lease read as stale: a
# second pump starts, fences a fresh epoch, and the first pass then dies on
# the next verb's `epoch_require`. On a repository whose suite takes longer
# than the staleness window, NO pass could ever complete.
#
# The assertion is the pump's own gate arithmetic, applied at a moment when
# the pass has already been running longer than the window it is measured
# against.
# ===========================================================================
HB="$WORK/heartbeat"
mkdir -p "$HB"
cd "$HB" || exit 1
git init -q .
HB_STALE_S=3
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\npump_stale_s=%s\n' "$HB_STALE_S" > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$HB" "$ORCHID_BIN" init >/dev/null || fail "orchid init (heartbeat fixture)"
git checkout -q orchid/integration
HEPOCH="$(ORCHID_REPO="$HB" "$ORCHID_BIN" run start | sed 's/epoch: //')"
horchid() { ORCHID_REPO="$HB" ORCHID_EPOCH="$HEPOCH" "$ORCHID_BIN" "$@"; }
horchid requirements import "$WORK/requirements.md" >/dev/null
horchid task create H010 "its suite outlives the staleness window" >/dev/null
horchid task set H010 verification_commands "sleep $(( HB_STALE_S * 4 )); exit 1" >/dev/null
horchid plan apply --reason "initial plan" >/dev/null

# Parked at `testing` with a suite that runs for ~4x pump_stale_s and then
# fails, so the pass stops at `rework` without spawning anything.
HCAND="$(git -C "$HB" rev-parse HEAD)"
fm_set "$HB/.orchid/tasks/H010.md" status testing
fm_set "$HB/.orchid/tasks/H010.md" candidate_sha "$HCAND"

# The pump's own two-line GNU/BSD parse, verbatim (runners/orchid-pump's
# _pump_iso_to_epoch), so this measures exactly what the pump would.
hb_lease_age() {
  local iso ep
  iso="$(jq -r '.refreshed_at // ""' "$HB/.orchid/runtime/lease.json" 2>/dev/null || echo "")"
  [ -n "$iso" ] || { echo 999999; return 0; }
  ep="$(date -u -d "$iso" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || echo 0)"
  [ "$ep" -gt 0 ] || { echo 999999; return 0; }
  echo $(( $(date -u +%s) - ep ))
}

hb_epoch_before="$(cat "$HB/.orchid/runtime/epoch")"
( ORCHID_REPO="$HB" ORCHID_EPOCH="$HEPOCH" "$DRIVE" > "$WORK/hb-drive.out" 2>&1
  echo "$?" > "$WORK/hb-drive.rc" ) &
hb_bg=$!
# Well past pump_stale_s, and well short of the suite's own runtime: the pass
# is provably still inside `orchid verify` here.
sleep $(( HB_STALE_S * 2 ))
hb_age="$(hb_lease_age)"
[ "$hb_age" -lt "$HB_STALE_S" ] \
  || fail "the lease went stale ($hb_age s >= $HB_STALE_S s) while its own pass was still verifying — a second pump would fence over it"
wait "$hb_bg"

assert_eq "$hb_epoch_before" "$(cat "$HB/.orchid/runtime/epoch")" \
  "and the pass ran to completion under its own epoch, never fenced out from under itself"
assert_eq rework "$(ORCHID_REPO="$HB" "$ORCHID_BIN" task show H010 | grep '^status: ' | cut -d' ' -f2)" \
  "the long verify really did run to its failing exit (drive out: $(cat "$WORK/hb-drive.out"))"
hb_rc="$(cat "$WORK/hb-drive.rc")"
[ "$hb_rc" -eq 0 ] || [ "$hb_rc" -eq 16 ] \
  || fail "the heartbeat-covered pass must complete normally (rc=$hb_rc): $(cat "$WORK/hb-drive.out")"

# ===========================================================================
# Part L -- a relaunched implementer is ONE implementer.
#
# `jobs reconcile` files every implement envelope of an attempt as a SIBLING
# (-a<n>-implementer.json, .2.json, ...) and removes none of them, so the
# "the engine reported failure" predicate is true for the whole REST of the
# attempt once one implementer has reported non-ok -- including the entire
# lifetime of the relaunch the escalation itself just started. Unguarded, the
# escalation ladder then runs on the WALL CLOCK instead of on failures: one
# rung per pass, a SECOND implementer spawned into the same worktree on the
# same branch while the first is still committing to it, and an auto-block at
# 3/3 with two or three engines still writing to that checkout.
#
# So the ladder is measured here against the two facts that decide it: how
# many implementers were ever STARTED, and how many rungs were spent. Both
# halves matter -- the guard must defer escalation while a relaunch is live,
# and must still count a genuine second failure when one arrives.
# ===========================================================================
DUP="$WORK/duplicate"
DUPCTL="$WORK/dupctl"
mkdir -p "$DUP" "$DUPCTL" "$WORK/eng/stubdup"
cd "$DUP" || exit 1
git init -q .
# engine_fail_threshold well above the two failures this fixture reports: the
# subject is the DRIVER's ladder, and a relaunch the ENGINE LEDGER refused
# would leave the same "no second implementer" reading for the wrong reason.
printf 'role.implementer=stubdup\nrole.reviewer=stubreview\nengine_fail_threshold=9\n' > orchid.config
git add -A
git commit -q -m "fixture: config"

printf 'manifest_version=1\nid=test/stubdup\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubdup/plugin.conf"
{
  echo '#!/usr/bin/env bash'
  echo 'set -eu'
  printf 'CTL=%s\n' "$(printf '%q' "$DUPCTL")"
} > "$WORK/eng/stubdup/run"
cat >> "$WORK/eng/stubdup/run" <<'EOF'
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
# One line per invocation. The test counts implementers HERE, not off the job
# manifests -- a manifest is runtime litter the driver's own gc may already
# have reaped, while this file is the engine's own record that it ran.
echo "$jid" >> "$CTL/starts"
# Launch #2 -- the relaunch the first failure's escalation makes -- parks
# until the test releases it, so a whole driver pass provably runs while it is
# still alive. Bounded, so a fixture that dies early cannot strand it.
if [ "$(wc -l < "$CTL/starts" | tr -d ' ')" -eq 2 ]; then
  i=0
  while [ ! -f "$CTL/release" ] && [ "$i" -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
fi
# Written to a sibling and MOVED into place, never redirected straight at the
# spool path: `jobs reconcile` runs concurrently with this write, and it
# quarantines a half-written envelope as malformed.
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"failed",
    summary:"stub implement failure"}' > "$out.part"
mv "$out.part" "$out"
EOF
chmod +x "$WORK/eng/stubdup/run"

ORCHID_REPO="$DUP" "$ORCHID_BIN" init >/dev/null || fail "orchid init (duplicate-implementer fixture)"
git checkout -q orchid/integration
DEPOCH="$(ORCHID_REPO="$DUP" "$ORCHID_BIN" run start | sed 's/epoch: //')"
dorchid() { ORCHID_REPO="$DUP" ORCHID_EPOCH="$DEPOCH" "$ORCHID_BIN" "$@"; }
dorchid requirements import "$WORK/requirements.md" >/dev/null
dorchid task create D010 "its first implementer reports failure" >/dev/null
dorchid task set D010 verification_commands "true" >/dev/null
dorchid plan apply --reason "initial plan" >/dev/null

DDRIVE_RC=0; DDRIVE_OUT=""
run_ddrive() {
  DDRIVE_RC=0
  DDRIVE_OUT="$(ORCHID_REPO="$DUP" ORCHID_EPOCH="$DEPOCH" "$DRIVE" 2>&1)" || DDRIVE_RC=$?
}
dfield() { ORCHID_REPO="$DUP" "$ORCHID_BIN" task show D010 | grep "^$1: " | cut -d' ' -f2-; }
dstarts() {
  if [ -f "$DUPCTL/starts" ]; then wc -l < "$DUPCTL/starts" | tr -d ' '; else echo 0; fi
}
# The driver's own definition of a live implement job, applied to the same
# manifests it reads: task, operation, and a pid it really stamped.
dlive_implement() {
  local m n=0
  for m in "$DUP/.orchid/runtime/jobs"/*.json; do
    [ -e "$m" ] || continue
    [ "$(jq -r '.task' "$m")" = D010 ] || continue
    [ "$(jq -r '.operation' "$m")" = implement ] || continue
    [ "$(jq -r '.pid // 0' "$m")" != 0 ] || continue
    n=$((n + 1))
  done
  echo "$n"
}
# `orchid-launch` returns as soon as it has SPAWNED, so the child's own first
# line can land a moment after the pass that started it. Bounded.
dwait_starts() {
  local want="$1" i=0
  while [ "$(dstarts)" -lt "$want" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
}

# Passes until the ladder has counted the first implementer's failure. How
# many that takes depends only on when the stub's envelope lands -- never on
# anything the driver decides -- so it is a wait, not an assertion.
di=0
while [ "$di" -lt 40 ]; do
  run_ddrive
  [ "$(dfield infra_failures)" = 0 ] || break
  [ "$DDRIVE_RC" -eq 0 ] || break
  di=$((di + 1))
  sleep 0.3
done
assert_eq 1 "$(dfield infra_failures)" \
  "a non-ok implement envelope spends exactly one rung of the escalation ladder (rc=$DDRIVE_RC, out: $DDRIVE_OUT)"
assert_eq implementing "$(dfield status)" \
  "and the task stays in implementing behind the relaunch"
dwait_starts 2
assert_eq 2 "$(dstarts)" \
  "the escalation really did relaunch -- the ladder still retries (out: $DDRIVE_OUT)"
assert_eq 1 "$(dlive_implement)" \
  "and exactly one implement job carries a stamped pid"

# THE PASS UNDER TEST. The relaunched implementer is parked and provably
# alive, and the attempt's first, non-ok envelope is still on disk beside it.
run_ddrive
assert_eq 1 "$(dlive_implement)" \
  "a pass over a LIVE relaunch must not spawn a second implementer into the worktree the first is still writing to (rc=$DDRIVE_RC, out: $DDRIVE_OUT)"
assert_eq 1 "$(dfield infra_failures)" \
  "nor spend a second rung on the failure it already counted"
assert_eq implementing "$(dfield status)" \
  "the task simply waits"
assert_match "awaiting the implementer envelope" "$DDRIVE_OUT" \
  "and the pass says so, naming what it is waiting for"
# A second implementer that HAD been spawned would append its own line here;
# give it the same grace dwait_starts gives a legitimate one before reading.
sleep 0.5
assert_eq 2 "$(dstarts)" \
  "no third engine process was ever started (out: $DDRIVE_OUT)"

# The other half: the guard DEFERS the ladder, it never disables it. Released,
# the parked implementer files a non-ok envelope of its own -- a genuine
# second failure -- and the next rung is spent on it.
: > "$DUPCTL/release"
di=0
while [ "$di" -lt 60 ]; do
  run_ddrive
  [ "$(dfield infra_failures)" = 1 ] || break
  di=$((di + 1))
  sleep 0.3
done
assert_eq 2 "$(dfield infra_failures)" \
  "a SECOND non-ok envelope is a second failure, and the ladder counts it (rc=$DDRIVE_RC, out: $DDRIVE_OUT)"
dwait_starts 3
assert_eq 3 "$(dstarts)" \
  "and relaunches once more, exactly as the ladder says (out: $DDRIVE_OUT)"
