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
if drive_boundary_wakes_orchestrator planning "" brokered; then
  fail "a brokered adapter cannot run 'orchid plan apply' either"
fi

# ...and the SOFT surface gives the SAME answer, by a different route (T003).
# `soft` is the absence of ENFORCEMENT, not a wider set of admitted verbs: the
# orchestrate contract every woken adapter is handed asks for an arbitration,
# a notify, a journal/lessons note and a boundary clear — it never asks anyone
# to run `orchid run accept` or `orchid plan apply`. Reading `soft` as "every
# verb is admissible" made EVERY kind orchestrator-resolvable, which suppresses
# the `orchid notify` blocker for all of them (the driver only notifies for
# boundaries no admitted verb settles) and wakes a model per staleness window
# for a decision no prompt asked it to make: the never-told-the-human failure
# the brokered path exists to prevent, reintroduced on the soft path.
if drive_boundary_wakes_orchestrator run-complete "" soft; then
  fail "no adapter is asked to run 'orchid run accept', so a finished run is a human's job on a soft surface too"
fi
if drive_boundary_wakes_orchestrator planning "" soft; then
  fail "and none is asked to draft a roadmap — PLANNING is operator work on every surface"
fi

# The kind a soft surface DOES settle is the one its contract actually names,
# on a status the verb accepts. Without this the assertions above would also
# be satisfied by a policy that simply never woke anybody.
drive_boundary_wakes_orchestrator review-conflict arbitrating soft \
  || fail "a soft adapter is still woken for the arbitration its orchestrate contract asks it for"

# Kinds no verb settles at all are operator-only on EVERY surface.
for kind in blocked-task hook-failure worktree-conflict operator-handoff operator-decision; do
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

# --- what a dispatch has to MOVE for its envelope to be delivery -----------
# The sha a no-op is measured against, by task shape rather than by fixture
# timing: a rework round is dispatched to change the candidate it already has,
# while a first dispatch has none yet and must move off its base.
BASE=2222222222222222222222222222222222222222
mk_delivery_task() {  # <id> <candidate|-> <base|->
  local id="$1" cand="$2" base="$3"
  [ "$cand" != - ] || cand=""
  [ "$base" != - ] || base=""
  printf -- '---\nschema: 1\nid: %s\nstatus: implementing\narchetype: feature\nattempts: 0\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$id" "$base" "$cand" > "$POLICY/.orchid/tasks/$id.md"
}

mk_delivery_task P50 "$CAND" "$BASE"
assert_eq "$CAND" "$(drive_delivery_floor "$POLICY" P50)" \
  "a rework round measures delivery against the candidate it was dispatched to change"
drive_delivery_is_noop "$POLICY" P50 "$CAND" \
  || fail "an ok envelope over a HEAD still sitting on that candidate added no commit — which is all this predicate claims: WHICH no-op it is (and whether it is one at all) belongs to the verdict below"
if drive_delivery_is_noop "$POLICY" P50 3333333333333333333333333333333333333333; then
  fail "a HEAD that moved off the prior candidate IS delivery — the envelope is not second-guessed further"
fi

mk_delivery_task P51 - "$BASE"
assert_eq "$BASE" "$(drive_delivery_floor "$POLICY" P51)" \
  "a FIRST dispatch has no candidate yet, so the sha it must move off is its base"
drive_delivery_is_noop "$POLICY" P51 "$BASE" \
  || fail "a first dispatch whose HEAD is still the base produced no commit at all — the same no-op, one step earlier"

# Neither sha recorded: state no dispatch can produce (drive_dispatch stamps
# base_sha on every one). Nothing to compare against is NOT a refusal.
mk_delivery_task P52 - -
assert_eq "" "$(drive_delivery_floor "$POLICY" P52)" "no recorded sha, nothing to measure against"
if drive_delivery_is_noop "$POLICY" P52 "$CAND"; then
  fail "with no sha on the task, a no-op cannot be PROVEN — the driver must not refuse on a guess"
fi
if drive_delivery_is_noop "$POLICY" P50 ""; then
  fail "an unreadable HEAD is a worktree fault, handled by its own boundary — never a silent no-op verdict"
fi

# --- and WHICH no-op it is: a sha comparison cannot see the tree -----------
# An unmoved HEAD over a worktree full of uncommitted edits is a dispatch that
# did the work and failed to commit it. It fails the delivery test the same way
# a commentary-only round does -- no candidate exists either way -- but the
# ladder's recovery for the latter is to relaunch the implementer into that
# same worktree, which over the former hands the next dispatch a tree it did
# not write. So the verdict distinguishes them, from the tree state the caller
# read (`handoff_worktree_dirty`'s stdout and exit status) rather than from a
# second sha. RED before this: there was no verdict to ask at all — every
# unmoved HEAD took the one refusal arm, whatever the tree held.
assert_eq delivered "$(drive_delivery_verdict "$POLICY" P50 3333333333333333333333333333333333333333 "" 0)" \
  "a HEAD that moved off the floor is delivery — there is a candidate to test"
assert_eq delivered "$(drive_delivery_verdict "$POLICY" P50 3333333333333333333333333333333333333333 "src/half-done.sh" 0)" \
  "and a dirty tree over a MOVED head is not this arm's question — that one belongs to the operator hand-off, one state later, against a candidate that exists"
assert_eq nothing "$(drive_delivery_verdict "$POLICY" P51 "$BASE" "" 0)" \
  "an unmoved HEAD over a CLEAN tree, on a task with no candidate on record, is the commentary-only round: no commit, no edit, nothing on disk to show for the dispatch or for any before it"
assert_eq uncommitted "$(drive_delivery_verdict "$POLICY" P50 "$CAND" "src/half-done.sh, docs/notes.md" 0)" \
  "an unmoved HEAD over a DIRTY tree is a different failure: the dispatch wrote real work and never committed it"
assert_eq uninspected "$(drive_delivery_verdict "$POLICY" P50 "$CAND" "git status exited 128 in /nope" 2)" \
  "a tree that could not be READ is refused in the same direction as a dirty one, never folded into the clean case — an inspection that answers 'clean' when it could not look is fail-open"
assert_eq uninspected "$(drive_delivery_verdict "$POLICY" P50 "$CAND" "" 2)" \
  "and the exit status decides that, not the text: a failed inspection prints its diagnosis on the same channel a dirty tree prints paths on"
assert_eq delivered "$(drive_delivery_verdict "$POLICY" P52 "$CAND" "src/half-done.sh" 0)" \
  "with no sha recorded a no-op cannot be PROVEN, so nothing is refused — the tree state does not turn an unprovable case into a refusable one"

# --- and whether a candidate EXISTS: the other half of the same blindness ---
# The floor is the candidate_sha where the task has one, so "HEAD is still the
# floor" is two situations, not one, and only the first is a delivery failure
# (lesson L039):
#
#   * the floor is the BASE. Nothing was ever produced -- not by this round and
#     not by any before it. T022's refusal, and it stands exactly as it was.
#   * the floor is a CANDIDATE ahead of that base. The work is already on disk;
#     this round added no commit on top of it. Refusing that charges the
#     job-delivery ladder for a task whose candidate is sitting right there,
#     and it is reached by ordinary operation -- a rebase re-stamps
#     candidate_sha and the next implementer finds its own work in place.
#
# BOTH EDGES ARE PINNED HERE, side by side, because pinning only one is the
# defect: T022 pinned the too-permissive edge and the too-strict one, unpinned,
# blocked a whole run. RED before this task's fix: the second case answered
# `nothing` and took the refusal arm.
assert_eq unchanged "$(drive_delivery_verdict "$POLICY" P50 "$CAND" "" 0)" \
  "an unmoved HEAD over a clean tree, where the floor is a CANDIDATE ahead of the base, is a round that added nothing to work already delivered — not a round that delivered nothing"
assert_eq nothing "$(drive_delivery_verdict "$POLICY" P51 "$BASE" "" 0)" \
  "and the too-permissive edge is untouched: with the floor at the base, an ok envelope over a worktree that never moved is still the refusal T022 shipped"
# A candidate cannot be PROVEN by a sha with nothing to compare it against, so
# the stricter word stands wherever the pair is incomplete. Neither state is
# producible by a dispatch (base_sha is stamped on the first one and never
# re-stamped), which is exactly why the fail-closed direction is free.
mk_delivery_task P53 "$CAND" -
assert_eq nothing "$(drive_delivery_verdict "$POLICY" P53 "$CAND" "" 0)" \
  "a candidate with no base recorded proves nothing about work produced — the refusal stands rather than advancing on a guess"
mk_delivery_task P54 "$CAND" "$CAND"
assert_eq nothing "$(drive_delivery_verdict "$POLICY" P54 "$CAND" "" 0)" \
  "nor does a candidate_sha that IS the base: the task holds the sha it started from, and a round that returns it has produced nothing"
# The tree still decides first. Real uncommitted output over an existing
# candidate is the operator's call, exactly as it is over a bare base -- an
# advance would carry the round's work nowhere and a relaunch would inherit it.
assert_eq uncommitted "$(drive_delivery_verdict "$POLICY" P50 "$CAND" "src/half-done.sh" 0)" \
  "a DIRTY tree is answered as a dirty tree whether or not a candidate exists — the existence of one does not license advancing past somebody's uncommitted work"
assert_eq uninspected "$(drive_delivery_verdict "$POLICY" P50 "$CAND" "" 2)" \
  "and a tree nobody could read is still uninspected — the candidate question is asked only once the tree is known to be clean"

# --- a refusal that does not stick is not a refusal ------------------------
# The no-op test above compares an envelope against a MOVING worktree; it is
# not a property of the envelope, and `jobs reconcile` removes no envelope. A
# refused one therefore sits on disk for the rest of the attempt, still `ok`
# and still the newest `ok`, and is re-selected by BOTH of the doors below
# unless the refusal is recorded against the envelope itself. Each is RED
# before this task: the selector had no notion of a refused envelope at all.
mk_impl_env() {  # <id> <attempt> <suffix> <status>
  local id="$1" att="$2" suffix="$3" st="$4"
  jq -n --arg jid "j-fixture-$id-a$att$suffix" --arg task "$id" --arg st "$st" \
    '{contract:1, job_id:$jid, task:$task, operation:"implement", status:$st,
      summary:"delivery fixture"}' \
    > "$POLICY/.orchid/reviews/$id-a$att-implementer$suffix.json"
}

mk_delivery_task P53 - "$BASE"
mk_impl_env P53 1 "" ok
assert_eq "$POLICY/.orchid/reviews/P53-a1-implementer.json" \
  "$(drive_implement_envelope "$POLICY" P53)" \
  "an ok implement envelope is the attempt's envelope until something says otherwise"

# The refusal, recorded exactly as runners/orchid-drive records it.
fm_set "$POLICY/.orchid/tasks/P53.md" refused_envelopes "P53-a1-implementer.json"
drive_delivery_refused "$POLICY" P53 P53-a1-implementer.json \
  || fail "the mark is read straight back off the task's own frontmatter"
if drive_delivery_refused "$POLICY" P53 P53-a1-implementer.2.json; then
  fail "and it marks THAT envelope, not every sibling of it"
fi
assert_eq "" "$(drive_implement_envelope "$POLICY" P53)" \
  "DOOR ONE: a refused envelope is never selected again, so the relaunch it started may move HEAD without that envelope becoming delivery of a commit it never made"
if drive_implement_failed "$POLICY" P53; then
  fail "nor is it a fresh engine failure — its rung was already spent, and the relaunch's own envelope has not landed yet"
fi

mk_impl_env P53 1 .2 failed
assert_eq "" "$(drive_implement_envelope "$POLICY" P53)" \
  "DOOR TWO: a newer NON-ok sibling does not restore the refused envelope to 'the newest ok one' — the failure is never stepped over to reach it"
drive_implement_failed "$POLICY" P53 \
  || fail "that non-ok sibling is the attempt's word now: a failure the ladder counts, never an acceptance"

# The mark excludes ONE envelope, not the attempt: a relaunch that really
# delivers is still accepted, on its own envelope.
mk_impl_env P53 1 .3 ok
assert_eq "$POLICY/.orchid/reviews/P53-a1-implementer.3.json" \
  "$(drive_implement_envelope "$POLICY" P53)" \
  "a genuinely new ok envelope is the attempt's envelope — the refusal quarantines one document, not the round"
if drive_implement_failed "$POLICY" P53; then
  fail "and with an acceptable envelope on disk the attempt is not in failure"
fi

# Basenames carry their own attempt, which is why the mark is a basename and
# not a counter: a counter-keyed mark would mask the NEXT round's envelope and
# strand the task with nothing selectable.
printf -- '---\nschema: 1\nid: P54\nstatus: implementing\narchetype: feature\nattempts: 1\nbase_sha: %s\ncandidate_sha: %s\nrefused_envelopes: P54-a1-implementer.json\n---\nbody\n' \
  "$BASE" "$CAND" > "$POLICY/.orchid/tasks/P54.md"
mk_impl_env P54 2 "" ok
assert_eq "$POLICY/.orchid/reviews/P54-a2-implementer.json" \
  "$(drive_implement_envelope "$POLICY" P54)" \
  "a refusal recorded on attempt 1 says nothing at all about attempt 2's envelope"

# The mark is also the ladder's REPLACEMENT SIGNAL. A non-ok envelope stays
# readable for the rest of the attempt, so an escalation whose relaunch never
# happened is escalated again next pass until the cap fetches a human; a
# refused envelope answers that question with nothing at all. Without this
# predicate the walk would wait forever on a relaunch that is neither running
# nor coming.
drive_delivery_refused_any "$POLICY" P53 \
  || fail "a refusal on the CURRENT attempt is a failure state the ladder must answer, not a wait"
if drive_delivery_refused_any "$POLICY" P50; then
  fail "a task with no refusal on record is simply awaiting its envelope"
fi
if drive_delivery_refused_any "$POLICY" P54; then
  fail "attempt 1's refusal must not read as attempt 2's — a fresh round would escalate on an old round's evidence"
fi
# ...and the segment match stops at `-implementer`, so a1 is never a11.
printf -- '---\nschema: 1\nid: P56\nstatus: implementing\narchetype: feature\nattempts: 0\nbase_sha: %s\ncandidate_sha:\nrefused_envelopes: P56-a11-implementer.json\n---\nbody\n' \
  "$BASE" > "$POLICY/.orchid/tasks/P56.md"
if drive_delivery_refused_any "$POLICY" P56; then
  fail "attempt 11's mark is not attempt 1's — a prefix match here escalates a round that never refused anything"
fi

# The value the driver writes back when it refuses: append, and idempotent.
assert_eq "P53-a1-implementer.json P53-a1-implementer.3.json" \
  "$(drive_delivery_refusal_list "$POLICY" P53 P53-a1-implementer.3.json)" \
  "a second refusal appends to the list rather than replacing it — every one of them stays refused"
assert_eq "P53-a1-implementer.json" \
  "$(drive_delivery_refusal_list "$POLICY" P53 P53-a1-implementer.json)" \
  "and refusing one already on the list writes the same list back, so the field cannot grow on a repeated pass"

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
# T026: the recurring blocked-task boundary is the message an operator re-reads
# on EVERY pass over a parked task, so its remedy list has to be the whole list
# PROTOCOL.md's boundary table names. `reverify` was missing from it while the
# table already listed it -- a remedy nobody could discover from the one place
# they were guaranteed to look.
SBLOCKED_REASON="$(sboundary | jq -r .reason)"
assert_match "orchid task unblock" "$SBLOCKED_REASON" \
  "the blocked-task boundary names the verb that clears the block (reason: $SBLOCKED_REASON)"
assert_match "retry" "$SBLOCKED_REASON" \
  "and the one that grants another rework round (reason: $SBLOCKED_REASON)"
assert_match "reverify" "$SBLOCKED_REASON" \
  "and the one that re-runs verification alone — every remedy PROTOCOL.md's boundary table lists (reason: $SBLOCKED_REASON)"

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

# The same run driven for a SOFT orchestrator routes the SAME way, and that is
# the point of T003: `soft` says nothing enforces a command allowlist, not that
# a woken model has been asked to close a run. Nothing hands any adapter the
# `orchid run accept --evidence` step, so COMPLETION reaches a human whichever
# label the resolved orchestrator declares -- and the blocker above is raised
# on both. (Part R pins the other half: what that woken model is actually
# asked to do.)
if drive_boundary_wakes_orchestrator run-complete "" soft; then
  fail "a soft surface must not imply COMPLETION is an orchestrator procedure — no prompt asks for 'orchid run accept'"
fi

# ...and end to end, because the consequence that matters is not the
# classification but the BLOCKER. A finished run under a soft orchestrator used
# to raise none at all: the kind read as settleable, the driver notifies only
# for boundaries no admitted verb settles, and the pump then woke a model every
# staleness window to run a verb nothing had asked it for. Nobody was ever told
# the run was waiting to be accepted. Same fixture shape as the brokered one
# above, one label apart.
SOFTRUN="$WORK/softrun"
mkdir -p "$SOFTRUN"
cd "$SOFTRUN" || exit 1
git init -q .
printf 'role.orchestrator=stubsoft\nrole.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$SOFTRUN" "$ORCHID_BIN" init >/dev/null || fail "orchid init (soft-completion fixture)"
git checkout -q orchid/integration
SEPOCH="$(ORCHID_REPO="$SOFTRUN" "$ORCHID_BIN" run start | sed 's/epoch: //')"
sorchid() { ORCHID_REPO="$SOFTRUN" ORCHID_EPOCH="$SEPOCH" "$ORCHID_BIN" "$@"; }
sboundary() { ORCHID_REPO="$SOFTRUN" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }
sorchid requirements import "$WORK/requirements.md" >/dev/null
sorchid task create S010 "the only task, and it is finished" >/dev/null
sorchid plan apply --reason "initial plan" >/dev/null
fm_set "$SOFTRUN/.orchid/tasks/S010.md" status "done"

assert_eq soft "$(drive_orchestrator_surface "$SOFTRUN")" \
  "the pinned orchestrator really is the unrestricted-surface one"
SDRIVE_RC=0
SDRIVE_OUT="$(ORCHID_REPO="$SOFTRUN" ORCHID_EPOCH="$SEPOCH" "$DRIVE" 2>&1)" || SDRIVE_RC=$?
assert_eq 16 "$SDRIVE_RC" "a finished run stops at a judgment boundary here too (out: $SDRIVE_OUT)"
assert_eq run-complete "$(sboundary | jq -r .kind)" "and the boundary names the run's completion"
assert_match "notified: \[run-complete\] is operator-only" "$SDRIVE_OUT" \
  "a soft surface routes it to a human as well — nothing asks any adapter to close a run"
assert_match "judgment boundary \[run-complete\] needs an operator" \
  "$(cat "$SOFTRUN/.orchid/BLOCKERS.md")" \
  "and the blocker telling the operator to run the acceptance step is really raised"

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
# else in the kernel reads one as live -- the escalation sweep and
# drive_job_outstanding both skip pid 0 -- so adopting one would advance a task into
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
# stamp: pid 0, pgid 0, started_at 0, and no log (the launcher creates the log
# by redirecting the spawn into it, so its absence is what proves the spawn
# line was never reached).
ORPHAN="$PREP/.orchid/runtime/jobs/j-e1-P010-a1-beef.json"
mkdir -p "$PREP/.orchid/runtime/jobs"
jq -n '{job_id:"j-e1-P010-a1-beef", task:"P010", attempt:1, role:"implementer",
        operation:"implement", engine:"stubimpl", pid:0, pgid:0, started_at:0,
        log:"'"$PREP"'/.orchid/runtime/logs/j-e1-P010-a1-beef.log", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$ORPHAN"

PDRIVE_RC=0
PDRIVE_OUT="$(ORCHID_REPO="$PREP" ORCHID_EPOCH="$PEPOCH" "$DRIVE" 2>&1)" || PDRIVE_RC=$?
pstatus() { ORCHID_REPO="$PREP" "$ORCHID_BIN" task show P010 | grep '^status: ' | cut -d' ' -f2; }
pfield() { ORCHID_REPO="$PREP" "$ORCHID_BIN" task show P010 | grep "^$1: " | cut -d' ' -f2-; }

case "$PDRIVE_OUT" in
  *"adopting the implement job"*)
    fail "a pid-0 manifest is not a spawned job — adopting one advances a task behind nothing (out: $PDRIVE_OUT)" ;;
esac

# The orphan is still there, and the pass does NOT advance the task behind it:
# both the reap and the relaunch are BOUNDED by stall_minutes, because a
# manifest this young may belong to a launcher that is between `jobs prepare`
# and its own spawn line right now. Reaping it would delete that launch's pack;
# relaunching over it (T027) would mint a second manifest for the same slot,
# which is how one crashed launcher became 73 pid-0 manifests. `jobs prepare`
# refuses that outright now, and the refusal is a WAIT: nothing spawned,
# nothing escalated, the task stays exactly where it was.
[ -f "$ORPHAN" ] \
  || fail "a freshly-prepared manifest must not be reaped — a live launcher may still be between prepare and spawn"
assert_eq pending "$(pstatus)" \
  "the task stays dispatchable rather than advancing behind a job nothing spawned (rc=$PDRIVE_RC, out: $PDRIVE_OUT)"
assert_match "unlaunched implement manifest for this slot" "$PDRIVE_OUT" \
  "and the pass names what it is waiting on"
assert_eq 0 "$(pfield infra_failures)" \
  "a wait spends no rung of the escalation ladder"
p_manifests="$(list_dir_files "$PREP/.orchid/runtime/jobs" | wc -l | tr -d ' ')"
assert_eq 1 "$p_manifests" "and no second manifest was minted for the same slot"

# Age it past the bound. Now the pass reaps the orphan, spends ONE rung of the
# ladder on it -- a job that never started produces no envelope, which is
# exactly the failure the ladder exists for, and which used to reach no arm of
# it at all (`dead`/`stalled`/`timeout` are all things a job that ran can be) --
# and re-dispatches the task through the ordinary walk.
touch -t 202001010000 "$ORPHAN"
PDRIVE_RC=0
PDRIVE_OUT="$(ORCHID_REPO="$PREP" ORCHID_EPOCH="$PEPOCH" "$DRIVE" 2>&1)" || PDRIVE_RC=$?
assert_match "gc-prepared j-e1-P010-a1-beef" "$PDRIVE_OUT" \
  "an aged prepared manifest is reaped by the pass's ordinary gc"
[ ! -f "$ORPHAN" ] \
  || fail "the reaped manifest must leave the jobs dir (out: $PDRIVE_OUT)"
assert_eq 1 "$(pfield infra_failures)" \
  "a never-launched job spends exactly one rung of the escalation ladder (out: $PDRIVE_OUT)"
assert_match "prepared and never launched" "$(cat "$PREP/.orchid/journal.md")" \
  "and it is JOURNALED — the incident's worst symptom was that nothing anywhere recorded it"
assert_eq implementing "$(pstatus)" \
  "with the orphan cleared, the same dispatch simply succeeds (rc=$PDRIVE_RC, out: $PDRIVE_OUT)"
live_pids="$(for _m in "$PREP/.orchid/runtime/jobs"/*.json; do
               [ -e "$_m" ] || continue
               jq -r 'select((.pid // 0) != 0) | .job_id' "$_m"
             done)"
[ -n "$live_pids" ] \
  || fail "the advance into implementing must be backed by a manifest that carries a real pid"

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

# ===========================================================================
# Part M -- THE REWORK BRIEF (T010). A lint or verification failure's EXACT
# locations must reach the guidance the next implementer receives.
#
# The defect this covers is not hypothetical (lesson L017). An engine profile
# that denies on the command STRING can run no verifier -- no `bash -n`, no
# `shellcheck`, not the repository's own suite -- so "fix the two ShellCheck
# findings in the file you wrote" names a subject that actor cannot see. In
# r-001 that produced two consecutive rework rounds on T005 in which neither
# attempt touched either offending line: one wrote a documentation paragraph,
# the next edited eighteen unrelated ones. So the assertions here are
# deliberately about the TEXT -- the gate's own `file:line: RULE: message`,
# verbatim, in the pack the implementer is actually handed. Not a pointer to
# a log, and not a paraphrase.
# ===========================================================================
source "$REPO_ROOT/lib/findings.sh"
source "$REPO_ROOT/lib/handoff.sh"
source "$REPO_ROOT/lib/pack.sh"

# --- the extractor, against every shape it claims to know ------------------
EXLOG="$WORK/extract.log"
cat > "$EXLOG" <<'EOF'
date: 2026-08-10T00:00:00Z
sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
candidate: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
cwd: /tmp/fixture
command: bash scripts/ci-local.sh --bash /bin/bash
---
== ShellCheck exception policy
lib/example.sh:7: ShellCheck suppression lacks an adjacent rationale
== gcc-format linter
lib/other.sh:3:14: warning: unreachable code [W0101]

In lib/example.sh line 12:
foo=$bar
    ^-- SC2086: Double quote to prevent globbing and word splitting.

In lib/example.sh line 40:
echo "$undefined"
      ^--^ SC2154 (warning): undefined is referenced but not assigned.
      ^--^ SC2086: a second finding on the SAME source line, one header

runners/example: line 3: syntax error near unexpected token `fi'
ok 1 - a passing case whose name mentions 12:34:56 and lib/example.sh
    ^-- SC9999: a caret line reached after its block ended
exit: 1
EOF

extracted="$(findings_extract "$EXLOG")"
assert_match "^lib/example\.sh:7: ShellCheck suppression lacks an adjacent rationale$" "$extracted" \
  "a bare file:line: message diagnostic is carried VERBATIM (this repo's own ci-local.sh gates print exactly this shape)"
assert_match "^lib/other\.sh:3:14: warning: unreachable code \[W0101\]$" "$extracted" \
  "so is the file:line:col: shape every gcc-style linter emits"
assert_match "^lib/example\.sh:12: SC2086: Double quote to prevent globbing and word splitting\.$" "$extracted" \
  "ShellCheck's three-line tty report is recomposed into file:line: RULE: message out of its own fields"
assert_match "^lib/example\.sh:40: SC2154: undefined is referenced but not assigned\.$" "$extracted" \
  "including the newer '(warning)' severity form, whose parenthetical is not part of the message"
assert_match "^lib/example\.sh:40: SC2086: a second finding on the SAME source line, one header$" "$extracted" \
  "shellcheck reports several findings on one line as several caret lines under ONE header — dropping the header after the first would silently lose the rest"
assert_match "^runners/example: line 3: syntax error" "$extracted" \
  "and the shell's own 'file: line N:' shape, which is what bash -n prints"
case "$extracted" in
  *"a passing case whose name"*)
    fail "ordinary test output must not be quoted as a finding — a brief mixing noise with locations is read the way one with no locations is" ;;
esac
# A HEADER EXPIRES WITH ITS OWN BLOCK. The stray caret above sits after a
# blank line and after two other tools' diagnostics; attributing it to the
# last `In <file> line <N>:` seen anywhere earlier would put a real file and a
# real line number on a finding that was never reported at either — a brief
# whose entire job is exact locations, printing a confidently wrong one.
case "$extracted" in
  *SC9999*)
    fail "a caret+SC line outside any shellcheck block must not inherit the last header seen — that is a fabricated location, not a carried one" ;;
esac

# A PASSING log contributes nothing, however location-shaped its output. The
# `exit:` line is a structured field, and it is what tells a gate's report
# apart from a test that happens to print a path and a number.
PASSLOG="$WORK/pass.log"
cat > "$PASSLOG" <<'EOF'
command: true
---
lib/example.sh:99: this line was printed by a test that PASSED
exit: 0
EOF
findings_log_failed "$PASSLOG" && fail "a log ending 'exit: 0' recorded no failure"
findings_log_failed "$EXLOG" || fail "a log ending in a nonzero exit recorded a failure"

# The cap is real AND it says so. A silently truncated list reads as "these
# were all the findings", which is the same information loss the whole
# mechanism exists to end.
CAPLOG="$WORK/cap.log"
{
  echo "command: fixture"
  echo "---"
  capi=1
  while [ "$capi" -le 25 ]; do
    printf 'lib/cap%s.sh:%s: SC1000: finding number %s\n' "$capi" "$capi" "$capi"
    capi=$((capi + 1))
  done
  echo "exit: 1"
} > "$CAPLOG"
capped="$(findings_extract "$CAPLOG")"
assert_eq "$((FINDINGS_MAX_LINES + 1))" "$(printf '%s\n' "$capped" | wc -l | tr -d ' ')" \
  "the brief carries at most FINDINGS_MAX_LINES diagnostics plus its own truncation notice"
assert_match "and 5 further diagnostic line\(s\)" "$capped" \
  "and the drop is PRINTED, never silent"

# --- evidence is bound to the candidate it came from ------------------------
# The brief exists to carry the CURRENT failure into the next attempt, so
# quoting a log left behind by a candidate that no longer exists is not a
# weaker version of the mechanism -- it is the original defect wearing the
# fix's heading, and it is worse than no brief at all, because the locations
# it names are confidently wrong. `<id>-merge.log` is the log that outlives
# its candidate most easily: the rebase arm mints a new candidate_sha under a
# tree whose merge log is still on disk, and `advance rework` from `merging`
# deliberately exempts that log from its rm.
BINDSTATE="$WORK/bindstate"
mkdir -p "$BINDSTATE/reviews"
CUR_CAND=1111111111111111111111111111111111111111
OLD_CAND=2222222222222222222222222222222222222222
mk_bindlog() { # <path> <candidate-header-line-or-empty> <diagnostic>
  { echo "date: 2026-08-10T00:00:00Z"
    echo "sha: 3333333333333333333333333333333333333333"
    [ -z "$2" ] || echo "candidate: $2"
    echo "command: fixture"
    echo "---"
    printf '%s\n' "$3"
    echo "exit: 1"
  } > "$1"
}

mk_bindlog "$BINDSTATE/reviews/X010-verify.log" "$CUR_CAND" "lib/current.sh:5: SC2086: from the candidate being reworked"
mk_bindlog "$BINDSTATE/reviews/X010-merge.log" "$OLD_CAND" "lib/superseded.sh:9: SC2154: from a candidate that no longer exists"
bound="$(findings_brief "$BINDSTATE" X010 "$CUR_CAND")"
assert_match "^lib/current\.sh:5: SC2086: from the candidate being reworked$" "$bound" \
  "a log whose header binds it to the current candidate_sha is carried"
case "$bound" in
  *superseded.sh*)
    fail "a merge log left behind by a SUPERSEDED candidate must not be re-injected — evidence carried into an attempt belongs to the candidate that failed" ;;
esac

# Absence of a claim is not a claim. A log written by an older kernel carries
# no `candidate:` header, so nothing binds it to anything; it is dropped for
# the same reason the mismatched one is, rather than trusted by default.
mk_bindlog "$BINDSTATE/reviews/X020-verify.log" "" "lib/unbindable.sh:3: SC2086: no candidate header at all"
case "$(findings_brief "$BINDSTATE" X020 "$CUR_CAND")" in
  *unbindable.sh*)
    fail "a log carrying no candidate: header is unbindable and must not be quoted as though it were current" ;;
esac

# ...and a task with NO candidate to bind TO matches nothing, rather than
# letting two vacuous sentinels agree (the trap `advance testing->reviewing`
# avoids by excluding `none` from its own compare).
mk_bindlog "$BINDSTATE/reviews/X030-verify.log" none "lib/vacuous.sh:1: SC2086: ran with no candidate_sha"
for nocand in "" none; do
  case "$(findings_brief "$BINDSTATE" X030 "$nocand")" in
    *vacuous.sh*)
      fail "candidate_sha '$nocand' names no candidate — it must match no evidence, not every log that also recorded none" ;;
  esac
done

# The header field is read from the HEADER, so captured test output cannot
# impersonate it: everything after `---` is the gate's own words, quoted, and
# a suite that prints a `candidate:` line is printing text, not making a claim.
mk_bindlog "$BINDSTATE/reviews/X040-verify.log" "$OLD_CAND" "candidate: $CUR_CAND
lib/spoofed.sh:2: SC2086: reached only by trusting output as header"
case "$(findings_brief "$BINDSTATE" X040 "$CUR_CAND")" in
  *spoofed.sh*)
    fail "the candidate binding must read the log HEADER only — output printed after --- must not be able to re-bind a superseded log" ;;
esac

# --- end to end: the locations reach the implementer's pack ----------------
BRIEF="$WORK/brief"
mkdir -p "$BRIEF"
cd "$BRIEF" || exit 1
git init -q .
# Deliberately WITHOUT handoff_before_verify: the brief is a property of the
# `rework` edge itself, not of the hand-off gate, and this part proves it with
# the gate off. No drive pass runs in Part M at all — every edge below is a
# verb call, so what is under test is the kernel verb and nothing else.
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$BRIEF" "$ORCHID_BIN" init >/dev/null || fail "orchid init (rework-brief fixture)"
git checkout -q orchid/integration
BEPOCH="$(ORCHID_REPO="$BRIEF" "$ORCHID_BIN" run start | sed 's/epoch: //')"
borchid() { ORCHID_REPO="$BRIEF" ORCHID_EPOCH="$BEPOCH" "$ORCHID_BIN" "$@"; }
bfield() { ORCHID_REPO="$BRIEF" "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }

cat > "$WORK/requirements-brief.md" <<'EOF'
# Requirements
- REQ-1: a rework brief names the lines that failed.
EOF
borchid requirements import "$WORK/requirements-brief.md" >/dev/null
borchid task create B010 "carries lint locations into the brief" >/dev/null
borchid plan apply --reason "initial plan" >/dev/null

BHEAD="$(git -C "$BRIEF" rev-parse HEAD)"
# Hand-walked to `testing` on frontmatter alone -- no engine is launched
# anywhere in Parts M and N. base_sha == candidate_sha keeps the INV-04
# ".orchid/ untouched" gate trivially satisfied: there is no commit between
# them to inspect.
borchid task advance B010 implementing --reason "fixture dispatch" >/dev/null
borchid task set B010 base_sha "$BHEAD" >/dev/null
borchid task set B010 candidate_sha "$BHEAD" >/dev/null
borchid task advance B010 testing --reason "fixture: implementer envelope ok" >/dev/null

mkdir -p "$BRIEF/.orchid/reviews"
sed "s|^candidate: .*|candidate: $BHEAD|" "$EXLOG" > "$BRIEF/.orchid/reviews/B010-verify.log"

borchid task advance B010 rework --reason "verify failed: see .orchid/reviews/B010-verify.log" >/dev/null
assert_eq rework "$(bfield B010 status)" "the fixture really took the testing -> rework edge"
[ ! -f "$BRIEF/.orchid/reviews/B010-verify.log" ] \
  || fail "entry to rework still invalidates the verify log — the brief is lifted BEFORE that, not instead of it"

bbody="$(borchid task show B010)"
assert_match "Rework brief — exact locations reported by the failing gate" "$bbody" \
  "entry to rework appends the brief to the task body, which IS the guidance an implementer receives"
assert_match "^lib/example\.sh:12: SC2086: Double quote to prevent globbing and word splitting\.$" "$bbody" \
  "and the body carries the gate's own file:line: RULE: message text, not a pointer to a log the implementer cannot re-run"
assert_match "^lib/example\.sh:7: ShellCheck suppression lacks an adjacent rationale$" "$bbody" \
  "every recognized location shape survives into the body, not just ShellCheck's"

# THE ASSERTION THAT MATTERS: the pack. A task body nobody hands to the
# implementer would fix nothing -- lib/pack.sh copies task.md verbatim, so
# this is the exact text the engine's request document is built from.
PACKOUT="$WORK/packout"
rm -rf "$PACKOUT"
pack_build "$BRIEF" B010 implement "$PACKOUT" >/dev/null 2>&1 \
  || fail "pack_build must succeed for a task carrying a rework brief"
[ -f "$PACKOUT/task.md" ] || fail "the implementer's pack must contain task.md"
bpacked="$(cat "$PACKOUT/task.md")"
assert_match "^lib/example\.sh:12: SC2086: Double quote to prevent globbing and word splitting\.$" "$bpacked" \
  "the failing gate's exact locations reach the pack the implementer is actually handed (lesson L017)"
assert_match "^runners/example: line 3: syntax error" "$bpacked" \
  "including the syntax error a profile that cannot run bash -n could never have found for itself"

# A rework with no location-bearing failure gains no heading promising any.
borchid task advance B010 implementing --reason "fixture: re-dispatch" >/dev/null
borchid task set B010 candidate_sha "$BHEAD" >/dev/null
borchid task advance B010 testing --reason "fixture" >/dev/null
borchid task advance B010 rework --reason "merge conflict" >/dev/null
assert_eq 1 "$(borchid task show B010 | grep -c 'Rework brief — exact locations')" \
  "a rework with no failing log carrying a location adds no second brief heading"

# ...and the same binding holds on the real verb edge, not just in the unit
# above: a stale `<id>-merge.log` sitting beside a current `<id>-verify.log`
# contributes nothing to the brief the implementer is handed.
borchid task advance B010 implementing --reason "fixture: re-dispatch" >/dev/null
borchid task set B010 candidate_sha "$BHEAD" >/dev/null
borchid task advance B010 testing --reason "fixture" >/dev/null
# A DIFFERENT diagnostic from the one already in the body. The brief this edge
# emits has to be distinguishable from the round-one brief still standing above
# it, or the append-idempotence guard further down would (correctly) drop it as
# a re-issue and the count below would be asserting that guard rather than the
# binding this block is about.
mk_bindlog "$BRIEF/.orchid/reviews/B010-verify.log" "$BHEAD" \
  "lib/current-round.sh:3: SC2086: reported against the candidate being reworked"
mk_bindlog "$BRIEF/.orchid/reviews/B010-merge.log" "$OLD_CAND" \
  "lib/superseded.sh:9: SC2154: from a candidate that no longer exists"
borchid task advance B010 rework --reason "verify failed" >/dev/null
bstale="$(borchid task show B010)"
assert_eq 2 "$(printf '%s\n' "$bstale" | grep -c 'Rework brief — exact locations')" \
  "a second brief really was appended on this edge, so the absence check below is about binding and not about an edge that emitted nothing"
assert_match "^lib/current-round\.sh:3: SC2086: reported against the candidate being reworked$" "$bstale" \
  "and it is THIS round's log that was carried"
case "$bstale" in
  *superseded.sh*)
    fail "the rework edge re-injected a merge log from a superseded candidate into the brief" ;;
esac

# --- A BRIEF DESCRIBES ONE CANDIDATE, AND IT DIES WITH IT ------------------
# Briefs are APPENDED to a body that outlives every candidate in it, so the
# binding above -- which log may be quoted -- only solves half the problem. The
# other half is the two briefs now sitting in B010's body: on the next round
# they are handed to an implementer alongside the new one, in the same voice,
# with nothing in the text saying which describes the tree it was just given.
# That is the same defect one layer up, and it is worse than the log case,
# because locations that were exact when written LOOK actionable forever.
borchid task advance B010 implementing --reason "fixture: re-dispatch" >/dev/null
# A REAL second candidate. The aging rule keys on the sha, so a fixture that
# re-used BHEAD would assert nothing at all. `git reset` first because this
# checkout's index is stale by construction: orchid moves this branch with
# `update-ref` and never touches the index, so a plain commit here would build
# its tree from an index many commits back (PROTOCOL.md says exactly this to
# operators; the fixture is subject to it too).
git -C "$BRIEF" reset -q
printf 'the next candidate\n' > "$BRIEF/note.txt"
git -C "$BRIEF" add note.txt
git -C "$BRIEF" commit -q -m "fixture: a second candidate" \
  || fail "fixture: the second candidate's commit did not land"
BHEAD2="$(git -C "$BRIEF" rev-parse HEAD)"
borchid task set B010 candidate_sha "$BHEAD2" >/dev/null
borchid task advance B010 testing --reason "fixture" >/dev/null
mk_bindlog "$BRIEF/.orchid/reviews/B010-verify.log" "$BHEAD2" \
  "lib/later.sh:4: SC2086: reported against the candidate now under work"
borchid task advance B010 rework --reason "verify failed" >/dev/null
baged="$(borchid task show B010)"

assert_match "<!-- orchid:rework-brief candidate=$BHEAD2 -->" "$baged" \
  "every brief NAMES the candidate it describes — without that, nothing downstream can tell one round's locations from another's"
assert_match "^lib/later\.sh:4: SC2086: reported against the candidate now under work$" "$baged" \
  "the current candidate's locations are carried, exactly as before"
assert_match "Superseded rework brief \(candidate " "$baged" \
  "and the briefs describing the candidate it replaced are aged out where the reader can see it happened"
case "$baged" in
  *"lib/example.sh:12: SC2086"*)
    fail "a superseded candidate's exact locations are still being handed forward verbatim — the implementer cannot tell them from the current ones, which is the L023 defect inside its own remedy" ;;
esac
assert_eq 1 "$(printf '%s\n' "$baged" | grep -c 'Rework brief — exact locations')" \
  "exactly ONE live brief remains: the one describing the candidate now under work"
assert_match "candidate=$BHEAD superseded" "$baged" \
  "the aged-out block keeps the candidate it was bound to, so the record of what each round was told survives the withdrawal"

# THE ASSERTION THAT MATTERS, again: the pack. A body that ages briefs but a
# pack that still ships them would have changed nothing for the actor.
PACKOUT2="$WORK/packout2"
rm -rf "$PACKOUT2"
pack_build "$BRIEF" B010 implement "$PACKOUT2" >/dev/null 2>&1 \
  || fail "pack_build must succeed for a task carrying an aged brief"
bpacked2="$(cat "$PACKOUT2/task.md")"
case "$bpacked2" in
  *"lib/example.sh:12: SC2086"*)
    fail "the pack the implementer is actually handed still carries a superseded candidate's locations" ;;
esac
assert_match "^lib/later\.sh:4: SC2086: reported against the candidate now under work$" "$bpacked2" \
  "while the current candidate's locations do reach it"

# Aging is IDEMPOTENT. Rework is a loop, so this pass runs again on every round
# — re-collapsing an already-collapsed block would re-word and re-count it every
# time, and the body would drift a little further from what was actually said.
bsup_n="$(printf '%s\n' "$baged" | grep -c 'Superseded rework brief')"
borchid task advance B010 implementing --reason "fixture: re-dispatch" >/dev/null
borchid task set B010 candidate_sha "$BHEAD2" >/dev/null
borchid task advance B010 testing --reason "fixture" >/dev/null
borchid task advance B010 rework --reason "merge conflict" >/dev/null
bagain="$(borchid task show B010)"
assert_eq "$bsup_n" "$(printf '%s\n' "$bagain" | grep -c 'Superseded rework brief')" \
  "a block already marked superseded is passed through, never collapsed a second time"
assert_eq 1 "$(printf '%s\n' "$bagain" | grep -c 'Rework brief — exact locations')" \
  "and the live brief survives a round that changed no candidate"

# ===========================================================================
# Part N -- THE OPERATOR HAND-OFF (T010): a named stop, a durable
# acknowledgement, and a resume rule.
#
# The pause exists because some mechanical work in a candidate requires
# EXECUTION -- a lint fix, a release checksum re-pin, the mode bit on a newly
# added executable -- which an engine profile that denies on the command
# string cannot perform at all. Verifying before it is done is a guaranteed
# FAIL that spends one of the task's three rework rounds on work nobody was
# going to do in that round.
#
# The two failure modes pinned here are opposite and equally fatal: a stop
# with no way to record the work is an infinite loop, and a stop that clears
# itself on elapsed time or on task identity is a silent walk-past.
# ===========================================================================
# Its OWN repository, holding exactly one task. Sharing Part M's fixture would
# have made the assertions below quietly meaningless: `blocked-task` and
# `operator-handoff` are both operator-only boundaries, so they rank equal and
# task-id order decides between them — a parked B010 would have taken the
# record on every pass and `operator-handoff` would never have been the one
# asserted against. One task, one possible boundary.
HANDOFF="$WORK/handoff"
mkdir -p "$HANDOFF"
cd "$HANDOFF" || exit 1
git init -q .
printf 'handoff_before_verify=required\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$HANDOFF" "$ORCHID_BIN" init >/dev/null || fail "orchid init (operator hand-off fixture)"
git checkout -q orchid/integration
HEPOCH="$(ORCHID_REPO="$HANDOFF" "$ORCHID_BIN" run start | sed 's/epoch: //')"
horchid() { ORCHID_REPO="$HANDOFF" ORCHID_EPOCH="$HEPOCH" "$ORCHID_BIN" "$@"; }
hfield() { ORCHID_REPO="$HANDOFF" "$ORCHID_BIN" task show H010 | grep "^$1: " | cut -d' ' -f2-; }

cat > "$WORK/requirements-handoff.md" <<'EOF'
# Requirements
- REQ-1: nothing verifies a candidate whose operator steps are outstanding.
EOF
ORCHID_REPO="$HANDOFF" ORCHID_EPOCH="$HEPOCH" "$ORCHID_BIN" requirements import "$WORK/requirements-handoff.md" >/dev/null
horchid task create H010 "held at the operator hand-off" >/dev/null
horchid plan apply --reason "initial plan" >/dev/null

# THE PROOF THAT `orchid verify` DID OR DID NOT RUN is a sentinel file the
# verification command itself creates. The absence of a verify LOG would prove
# nothing here: `orchid verify` dies before writing one when no command is
# configured, so a log-based assertion would pass just as happily against a
# driver with no gate at all. The command also prints one ShellCheck-shaped
# diagnostic and fails, so the pass that finally does verify exercises the
# rework brief end to end, through the driver, on the driver's own edge.
HVERIFY_RAN="$WORK/h010-verify-ran"
horchid task set H010 verification_commands \
  "touch $HVERIFY_RAN; echo lib/gate.sh:9: SC2086: Double quote to prevent globbing; exit 1" >/dev/null

HHEAD="$(git -C "$HANDOFF" rev-parse HEAD)"

# THE TASK GETS ITS OWN WORKTREE, ON ITS OWN BRANCH, because that is where a
# real hand-off happens: dispatch gives every code task a checkout of its own
# (drive_worktree_plan), the implementer's commits land there, and the
# operator's mechanical commit lands on top of them. `orchid verify` and
# `orchid task handoff` both resolve their tree the SAME way -- the task's
# `worktree` field when set, else the repository -- so recording it here is
# what makes this fixture and the verbs agree about which tree is being
# judged. A fixture that commits the hand-off somewhere the task record does
# not name tests nothing: the verb reads a HEAD that never moved, finds
# nothing to advance, and every assertion below it reads back empty.
#
# It also keeps the hand-off's commit ANSWERABLE TO INV-04 for the same reason
# the implementer's own commits are. `handoff --ack` re-runs entry-to-testing's
# scan of `base_sha..HEAD`, and the INTEGRATION BRANCH is where orchid's own
# state commits land (orchid_commit_durable builds them in a throwaway worktree
# and moves the branch with `update-ref`) -- so a hand-off committed there is
# refused the moment any of them falls inside the range, for touching kernel
# state it never wrote. A task branch carries the candidate's commits and
# nothing else, which is the shape that scan was written for.
HWT="$WORK/handoff-wt"
git -C "$HANDOFF" worktree add -q -b task/H010 "$HWT" "$HHEAD" \
  || fail "fixture: could not create H010's task worktree"
horchid task advance H010 implementing --reason "fixture dispatch" >/dev/null
horchid task set H010 worktree "$HWT" >/dev/null
horchid task set H010 base_sha "$HHEAD" >/dev/null
horchid task set H010 candidate_sha "$HHEAD" >/dev/null
horchid task advance H010 testing --reason "fixture: implementer envelope ok" >/dev/null

HDRIVE_RC=0; HDRIVE_OUT=""
run_hdrive() {
  HDRIVE_RC=0
  HDRIVE_OUT="$(ORCHID_REPO="$HANDOFF" ORCHID_EPOCH="$HEPOCH" "$DRIVE" 2>&1)" || HDRIVE_RC=$?
}
hboundary() { ORCHID_REPO="$HANDOFF" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }

assert_eq required "$(handoff_gate_mode "$HANDOFF")" "the fixture repository asks for the pause"
assert_eq outstanding "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "with nothing acknowledged, the hand-off is outstanding"

# Pass 1 -- the stop.
run_hdrive
assert_eq 16 "$HDRIVE_RC" "an unacknowledged hand-off stops the pass at a judgment boundary"
assert_eq operator-handoff "$(hboundary | jq -r .kind)" \
  "the boundary NAMES the hand-off — an operator-decision catch-all would not tell anyone what to do"
assert_eq H010 "$(hboundary | jq -r .task)" "and names the task it is holding"
assert_eq testing "$(hfield status)" "the task takes NO transition"
[ ! -f "$HVERIFY_RAN" ] \
  || fail "the pass ran orchid verify anyway — verifying before the hand-off is the burnt attempt this stop exists to prevent"
assert_eq 0 "$(hfield attempts)" "and no attempt was spent"
assert_match "notified: \[operator-handoff\]" "$HDRIVE_OUT" \
  "no verb an orchestrator can run performs this work, so it reaches a human instead of waking a model"
assert_match "awaiting-operator-handoff" \
  "$(ORCHID_REPO="$HANDOFF" "$ORCHID_BIN" status --explain 2>/dev/null)" \
  "status --explain says the wait is on a person, not 'awaiting-verify'"

# Pass 2, nothing changed -- A SECOND PASS WITHOUT AN ACKNOWLEDGEMENT STOPS
# AGAIN. The stop never decays into consent with elapsed time or pass count.
run_hdrive
assert_eq 16 "$HDRIVE_RC" "a second pass with the hand-off still outstanding stops again"
assert_eq testing "$(hfield status)" "and still takes no transition"
[ ! -f "$HVERIFY_RAN" ] || fail "the second pass verified anyway"

# The acknowledgement is DERIVED, never supplied: `task set` refuses the field
# outright, so no caller can bind one to a candidate of its own choosing.
hrc=0; horchid task set H010 handoff_ack "$HHEAD" >/dev/null 2>&1 || hrc=$?
[ "$hrc" -ne 0 ] || fail "task set must refuse handoff_ack — a hand-picked value is the one way this record could lie"

# --- THE HAND-OFF'S OWN COMMIT LANDS AFTER THE CANDIDATE WAS CAPTURED -----
# The operator now does exactly what PROTOCOL.md's procedure says: performs
# this candidate's mechanical steps and COMMITS them onto its branch. That
# commit lands after `candidate_sha` was captured (which happened when the
# implementer's envelope reconciled, several steps ago) -- so the tree
# `orchid verify` is about to run is no longer the tree the task record names.
#
# This is the drift the feature would otherwise INSTITUTIONALISE: a hand-off
# formalised as a procedure step, whose every use silently unbinds the record
# from the tree everything downstream is about to be judged against. Lesson
# L025 is evidence bound to a commit that was never the one verified, and
# below the assertions pin the fix's outcome (candidate == the tree that runs)
# rather than the bug's symptom.
#
# IT LANDS IN THE TASK'S OWN WORKTREE (see the note above `git worktree add`),
# which is both where a real one lands and the only tree the record and the
# verbs agree about. The assertion below pins the commit's SHAPE -- exactly its
# one file, no kernel state -- so a fixture that rots into a whole-index commit
# fails as itself rather than as the hand-off it is supposed to be exercising.
printf 'sha256 "0000"\n' > "$HWT/formula-pin.txt"

# --- RED: THE ACK IS REFUSED WHILE THE TREE IS DIRTY -----------------------
# The mechanical work now EXISTS, and it is not committed. Every sha this verb
# compares — `handoff_ack`, `candidate_sha`, `HEAD` — describes a COMMIT, and
# none of them can see a working tree. So an operator who applies the linter's
# own fix and acknowledges without committing leaves all three in perfect
# agreement about a commit that does not contain the work, while `orchid verify`
# runs the dirty tree that does: every downstream judgment is then evidence
# about a commit nobody ran. That is lesson L025 reached by the one road three
# matching shas cannot see, and it is the likeliest operator mistake here,
# because applying the fix FEELS like performing the hand-off.
hdirty_rc=0
hdirty_out="$(horchid task handoff H010 --ack \
  --reason "fixture: acknowledging with the fix applied but not committed" 2>&1)" || hdirty_rc=$?
[ "$hdirty_rc" -ne 0 ] \
  || fail "the ack was given over a dirty tree — verification would then run work no commit contains (it said: $hdirty_out)"
assert_match "uncommitted changes" "$hdirty_out" \
  "and it refuses on the tree's STATE, which is the thing no sha comparison can see (it said: $hdirty_out)"
assert_match "formula-pin.txt" "$hdirty_out" \
  "NAMING what is uncommitted — 'commit your changes' over a tree an operator believes is clean is the same unsatisfiable instruction this task exists to remove (it said: $hdirty_out)"
assert_eq "$HHEAD" "$(hfield candidate_sha)" "the refused ack advanced nothing"
assert_eq "" "$(hfield handoff_ack)" "and acknowledged nothing"

git -C "$HWT" add formula-pin.txt || fail "fixture: could not stage the operator's mechanical change"
git -C "$HWT" commit -q -m "H010: re-pin the formula checksum

Orchid-Handoff: operator" || fail "fixture: the operator's mechanical commit did not land"
assert_eq formula-pin.txt \
  "$(git -C "$HWT" diff-tree --no-commit-id --name-only -r HEAD)" \
  "fixture: the operator's mechanical commit carries exactly its one file and no kernel state"
HHANDOFF_CAND="$(git -C "$HWT" rev-parse HEAD)"
[ "$HHANDOFF_CAND" != "$HHEAD" ] || fail "fixture: the hand-off commit did not move HEAD, so nothing below is being tested"
assert_eq "$HHEAD" "$(hfield candidate_sha)" \
  "before the ack the record still names the PRE-hand-off commit — that is the drift, and it is real"

# The operator records the work.
#
# ITS EXIT CODE AND ITS OWN WORDS ARE ASSERTED FIRST, and that is not
# belt-and-braces. Every way this verb declines -- an unreadable tree, a
# candidate it will not advance onto, a missing reason -- ends in a `die` whose
# message is the only statement of WHY, and a fixture that sends it to
# /dev/null (or leaves it interleaved on stderr with a suite's own output)
# turns each of those into the same six assertions reading back empty. That is
# a rework round spent rediscovering a sentence the verb already printed --
# precisely the failure lesson L017 is about, reproduced inside the test for
# the feature that exists to end it. So the refusal is captured and QUOTED.
hack_rc=0
hack_out="$(horchid task handoff H010 --ack \
  --reason "re-pinned Formula/orchid.rb and set the exec bit" 2>&1)" || hack_rc=$?
[ "$hack_rc" -eq 0 ] \
  || fail "the ack verb refused the hand-off (exit $hack_rc) — it said: $hack_out"
assert_match "candidate_sha advanced $HHEAD -> $HHANDOFF_CAND" "$hack_out" \
  "the verb SAYS which candidate it moved, so the move is never a silent one (it said: $hack_out)"
assert_match "operator hand-off acknowledged for candidate $HHANDOFF_CAND" "$hack_out" \
  "and says what it acknowledged, against which candidate (it said: $hack_out)"
assert_eq "$HHANDOFF_CAND" "$(hfield candidate_sha)" \
  "the hand-off ADVANCES the candidate to its own resulting commit — the tree verification will actually run"
assert_eq "$HHANDOFF_CAND" "$(hfield handoff_ack)" \
  "and binds the acknowledgement to THAT commit, not to the one the hand-off superseded"
assert_eq "$(hfield candidate_sha)" "$(hfield handoff_ack)" \
  "leaving the two equal, which is the state the evidence header below is judged against"
assert_match "advanced candidate_sha $HHEAD -> $HHANDOFF_CAND" "$(cat "$HANDOFF/.orchid/journal.md")" \
  "and the move is journalled on its own, so an operator reading the trail sees the candidate change"
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" "which reads as satisfied"
assert_match "operator hand-off acknowledged for candidate" "$(cat "$HANDOFF/.orchid/journal.md")" \
  "and it is journalled, so the mechanical steps are part of the durable record"

# --- A DIRTY TREE IS OUTSTANDING ON THE RESUME SIDE TOO --------------------
# The refusal above governs the moment of acknowledging. The resume rule has to
# hold the same line on its own, and NOT by inheriting that refusal: an operator
# can edit the tree after a perfectly good ack, and a second driver pass has
# nothing but the record and the tree to read. Here all THREE shas agree —
# `handoff_ack`, `candidate_sha` and `HEAD` are one commit — and the tree still
# does not match any of them. A resume that reads that as "already performed"
# verifies work no commit contains.
printf 'sha256 "3333"\n' > "$HWT/formula-pin.txt"
assert_eq "$(hfield candidate_sha)" "$(hfield handoff_ack)" \
  "the two frontmatter fields agree"
assert_eq "$HHANDOFF_CAND" "$(git -C "$HWT" rev-parse HEAD)" \
  "and HEAD has not moved — so all three agree, and only the tree's state differs"
assert_eq outstanding "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "yet the hand-off reads outstanding: three matching shas say nothing about the tree on top of them"
assert_match "uncommitted changes" "$(handoff_state "$HANDOFF" H010 | cut -f2-)" \
  "and the detail says which axis failed"
assert_match "formula-pin.txt" "$(handoff_state "$HANDOFF" H010 | cut -f2-)" \
  "naming the path, so the operator is not left to diff the tree themselves"
rm -f "$HVERIFY_RAN"
run_hdrive
assert_eq 16 "$HDRIVE_RC" \
  "a pass over an acknowledged candidate with a dirty tree stops at the boundary (out: $HDRIVE_OUT)"
assert_eq operator-handoff "$(hboundary | jq -r .kind)" \
  "and it stops at the HAND-OFF specifically — every operator boundary exits 16, so the code alone would not say which one was raised"
[ ! -f "$HVERIFY_RAN" ] \
  || fail "the pass verified a tree no commit contains — the acknowledgement was read as satisfied on shas alone"
# Restoring the tree settles it with NO second ack: nothing was committed, so
# the acknowledgement standing still names the tree that will run. (A post-ack
# COMMIT is the other case, below, and that one does need re-acknowledging —
# the two are different because one moved HEAD and the other did not.)
git -C "$HWT" checkout -- formula-pin.txt || fail "fixture: could not restore the tree"
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "and a tree brought back into line with the acknowledged commit is satisfied again"

# --- RED: A TREE THAT COULD NOT BE INSPECTED IS NOT A CLEAN TREE -----------
# The check above reads the tree's STATE, which is the one axis no sha
# comparison can see — so what it does when the read FAILS decides whether that
# axis is a safety check or a decoration. `git status` fails for reasons that
# say nothing about the tree being tidy: the path is not a checkout, it is a
# bare repository, its index is unreadable, `git` is not on PATH. Every one of
# those produces no output, and no output is what a genuinely clean tree
# produces too. Fold them together and the ack is given, and the resume
# proceeds, on the strength of a look that never happened — the fail-open shape
# with the worst possible blast radius, because it is invisible exactly when
# something is already wrong with the tree.
#
# The tree here is a BARE repository, which is the honest version of that
# fault rather than a mock: `git status` cannot run in one at all, while
# `rev-parse HEAD` answers perfectly well. So every sha this path compares
# still agrees — the checks above it all pass — and the inspection is the only
# thing that fails, which is precisely the case a fail-open swallows whole.
HBARE="$WORK/handoff-uninspectable.git"
rm -rf "$HBARE"
git clone -q --bare "$HANDOFF" "$HBARE" \
  || fail "fixture: could not build a tree that cannot be inspected"
git -C "$HBARE" symbolic-ref HEAD refs/heads/task/H010 \
  || fail "fixture: could not point the bare repository at the task's branch"
assert_eq "$HHANDOFF_CAND" "$(git -C "$HBARE" rev-parse HEAD)" \
  "fixture: its HEAD is readable and IS the acknowledged candidate, so nothing ABOVE the inspection can be what refuses below"
hins_rc=0
git -C "$HBARE" status --porcelain >/dev/null 2>&1 || hins_rc=$?
[ "$hins_rc" -ne 0 ] \
  || fail "fixture: 'git status' succeeded in $HBARE, so nothing below is exercising a failed inspection"

horchid task set H010 worktree "$HBARE" >/dev/null
assert_eq outstanding "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "a tree whose state could not be READ is outstanding: the failure direction of an inspection has to be dirty, or the check answers 'clean' about a tree it never saw"
assert_match "could not be inspected" "$(handoff_state "$HANDOFF" H010 | cut -f2-)" \
  "and it SAYS the tree could not be inspected rather than reporting it clean — the two call for opposite actions from whoever reads it"
hbare_rc=0
hbare_out="$(horchid task handoff H010 --ack \
  --reason "fixture: acknowledging over a tree whose state cannot be read" 2>&1)" || hbare_rc=$?
[ "$hbare_rc" -ne 0 ] \
  || fail "the ack was given over a tree whose state could not be read — a failed inspection was taken for a clean tree (it said: $hbare_out)"
assert_match "could not be inspected" "$hbare_out" \
  "and the refusal says which look failed, not that the tree was fine (it said: $hbare_out)"
assert_match "$HBARE" "$hbare_out" \
  "naming the tree it could not read, so the operator is not left guessing which checkout is meant (it said: $hbare_out)"

horchid task set H010 worktree "$HWT" >/dev/null
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "and the real tree — inspectable, clean, on the acknowledged commit — is satisfied again, so the refusal above was about the failed look and nothing else"

# --- RED: WHICH COMMIT IT WILL ADVANCE TO IS ITSELF A GATE -----------------
# Advancing `candidate_sha` to whatever `HEAD` happens to be is a WORSE
# mis-binding than the drift the advance exists to remove. The drift at least
# named a commit that really was this candidate's; a record pointed at an
# unrelated tree names one that shares no history with the work under judgment,
# while every downstream gate — the verify evidence, the review envelopes bound
# to it, the merge — carries on as though it did.
#
# (a) AN UNRELATED HISTORY. What a checkout left on some other line of work
# looks like from here. The orphan below shares no ancestor with the candidate
# at all, so no amount of `.orchid/`-scanning would notice: the range between
# them is not a range.
git -C "$HWT" checkout -q --orphan alien || fail "fixture: could not start an unrelated history"
git -C "$HWT" commit -q -m "an unrelated tree" || fail "fixture: the unrelated commit did not land"
HALIEN="$(git -C "$HWT" rev-parse HEAD)"
halien_rc=0
halien_out="$(horchid task handoff H010 --ack \
  --reason "fixture: acknowledging against an unrelated tree" 2>&1)" || halien_rc=$?
[ "$halien_rc" -ne 0 ] \
  || fail "the ack advanced candidate_sha to a commit that shares NO history with the candidate (it said: $halien_out)"
assert_match "does not descend from the current candidate" "$halien_out" \
  "and it refuses on the ground that actually matters — a hand-off only ever ADDS commits on top of the implementer's work (it said: $halien_out)"
assert_match "$HHANDOFF_CAND" "$halien_out" \
  "the refusal names the candidate it declined to replace (it said: $halien_out)"
assert_match "$HALIEN" "$halien_out" \
  "and the commit it declined to advance to — those two shas ARE the mistake (it said: $halien_out)"
assert_eq "$HHANDOFF_CAND" "$(hfield candidate_sha)" "the record is untouched by a refused ack"
assert_eq "$HHANDOFF_CAND" "$(hfield handoff_ack)" "as is the acknowledgement already standing"
git -C "$HWT" checkout -q -f task/H010 || fail "fixture: could not return to the task branch"
git -C "$HWT" branch -D alien >/dev/null 2>&1 || true

# (b) A DESCENDANT, BUT NOT ON THE TASK'S BRANCH. Descent alone still admits a
# commit made on a branch that merely forked from this candidate — which is
# what an operator working two tasks in two checkouts produces by accident, and
# it is the shape whose commits silently vanish from the branch that merges.
git -C "$HWT" checkout -q --detach "$HHANDOFF_CAND" || fail "fixture: could not detach HEAD"
printf 'sha256 "1111"\n' > "$HWT/formula-pin.txt"
git -C "$HWT" add formula-pin.txt
git -C "$HWT" commit -q -m "H010: a mechanical fix committed off the task branch

Orchid-Handoff: operator" || fail "fixture: the off-branch commit did not land"
HDETACHED="$(git -C "$HWT" rev-parse HEAD)"
hoff_rc=0
hoff_out="$(horchid task handoff H010 --ack \
  --reason "fixture: committed on a detached HEAD" 2>&1)" || hoff_rc=$?
[ "$hoff_rc" -ne 0 ] \
  || fail "the ack accepted a commit that is not on the task's branch (it said: $hoff_out)"
assert_match "is not contained in task H010's branch" "$hoff_out" \
  "the refusal says which membership failed (it said: $hoff_out)"
assert_match "$HDETACHED" "$hoff_out" "naming the commit it refused (it said: $hoff_out)"
assert_match "$HHANDOFF_CAND" "$hoff_out" "and the candidate it would have replaced (it said: $hoff_out)"
assert_eq "$HHANDOFF_CAND" "$(hfield candidate_sha)" "and again the record is untouched"
git -C "$HWT" checkout -q -f task/H010 || fail "fixture: could not return to the task branch"

# --- A COMMIT MADE AFTER THE ACK REOPENS THE PAUSE -------------------------
# The two frontmatter fields agreeing prove only that they were written
# together. What the pause is about is a committed TREE — and an operator who
# acknowledges, then commits once more (a second lint fix, a formula re-pinned
# after re-reading the diff), leaves the record naming a tree that exists
# nowhere. A resume that read that as "already performed" would verify the
# later tree and bind every downstream judgment to a commit nothing verified:
# lesson L025 again, reached silently, because the fields still match.
printf 'sha256 "2222"\n' > "$HWT/formula-pin.txt"
git -C "$HWT" add formula-pin.txt
git -C "$HWT" commit -q -m "H010: re-pin again, after acknowledging

Orchid-Handoff: operator" || fail "fixture: the post-ack commit did not land"
HHANDOFF_CAND2="$(git -C "$HWT" rev-parse HEAD)"
assert_eq "$HHANDOFF_CAND" "$(hfield handoff_ack)" \
  "the acknowledgement still names the commit it was made against"
assert_eq "$(hfield candidate_sha)" "$(hfield handoff_ack)" \
  "and the two frontmatter fields still AGREE — which is exactly why comparing them alone is not enough"
assert_eq outstanding "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "yet the hand-off reads outstanding again: HEAD of the tree verification would run has moved past what was acknowledged"
assert_match "HEAD of $HWT is now $HHANDOFF_CAND2" "$(handoff_state "$HANDOFF" H010 | cut -f2-)" \
  "and the detail names the tree and the commit that moved, so an operator can see what happened"
rm -f "$HVERIFY_RAN"
run_hdrive
assert_eq 16 "$HDRIVE_RC" \
  "a pass over a tree that moved past its acknowledgement stops at the boundary (out: $HDRIVE_OUT)"
[ ! -f "$HVERIFY_RAN" ] \
  || fail "the pass verified a tree nobody acknowledged — two matching fields are not evidence about a commit"

# The branch check is a check on this path too: a record naming a branch this
# tree does not have can confirm nothing about the commit in front of it.
horchid task set H010 branch task/never-created >/dev/null
hnob_rc=0
hnob_out="$(horchid task handoff H010 --ack --reason "fixture: the record names a branch that does not exist" 2>&1)" || hnob_rc=$?
[ "$hnob_rc" -ne 0 ] \
  || fail "the ack advanced against a branch the record names but the tree does not have (it said: $hnob_out)"
assert_match "which does not exist in" "$hnob_out" \
  "and says so, rather than failing somewhere less legible (it said: $hnob_out)"
horchid task set H010 branch task/H010 >/dev/null

# Re-running the ack IS the whole remedy — it advances and re-binds, which is
# the same one-command cost every other fail-closed axis here charges.
horchid task handoff H010 --ack --reason "fixture: re-acknowledged after the later commit" >/dev/null
assert_eq "$HHANDOFF_CAND2" "$(hfield candidate_sha)" \
  "re-running the ack advances the candidate to the later commit"
assert_eq "$HHANDOFF_CAND2" "$(hfield handoff_ack)" "and re-binds the acknowledgement to it"
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "which settles the pause, so this is a stop with a way out and not a loop"
HHANDOFF_CAND="$HHANDOFF_CAND2"

# THE PROOF THAT THE HAND-OFF LEFT NO DRIFT BEHIND. `orchid verify` stamps two
# independent lines into its evidence: `sha:`, read from the tree it actually
# ran in, and `candidate:`, read from frontmatter. Had the ack not advanced the
# candidate, these two would name DIFFERENT commits and every downstream
# judgment would be recorded against a tree nobody ran (lesson L025). They are
# compared here, one verb call at a time, because the driver's own pass below
# ends on a `rework` advance that DELETES this log (INV-07) — after it there is
# nothing left to compare. The sentinel is cleared afterwards so the pass below
# still proves the DRIVER verified, not this line.
horchid verify H010 >/dev/null 2>&1 || true
HVLOG="$HANDOFF/.orchid/reviews/H010-verify.log"
[ -f "$HVLOG" ] || fail "orchid verify wrote no evidence log"
assert_eq "$HHANDOFF_CAND" "$(grep '^sha: ' "$HVLOG" | cut -d' ' -f2-)" \
  "verification runs against the tree the hand-off's commit produced"
assert_eq "$HHANDOFF_CAND" "$(grep '^candidate: ' "$HVLOG" | cut -d' ' -f2-)" \
  "and its evidence names that same commit as the candidate it judged — the two agree, which is what INV-11's testing -> reviewing gate reads out of this header"
rm -f "$HVERIFY_RAN"

# Pass 3 -- A SECOND PASS AFTER AN ACKNOWLEDGED HAND-OFF PROCEEDS.
run_hdrive
[ -f "$HVERIFY_RAN" ] \
  || fail "an acknowledged hand-off must let the pass proceed to verification — otherwise the stop is an infinite loop (rc=$HDRIVE_RC, out: $HDRIVE_OUT)"
assert_eq rework "$(hfield status)" "and the pass takes the verification failure's own edge, exactly as it would have with no gate at all"
assert_eq 1 "$(hfield attempts)" "spending the attempt on a verification that really ran"

# ...and that pass carried the failing gate's exact location into the brief,
# through the driver, with no orchestrator step anywhere in it.
assert_match "^lib/gate\.sh:9: SC2086: Double quote to prevent globbing$" \
  "$(ORCHID_REPO="$HANDOFF" "$ORCHID_BIN" task show H010)" \
  "the driver's own rework edge carries the gate's exact file:line: RULE: message into the task body"

# Entry to rework withdrew the acknowledgement: the candidate it was made
# against is the one this rework round exists to replace.
assert_eq "" "$(hfield handoff_ack)" "entry to rework clears the acknowledgement (INV-07 symmetry)"

# --- A RE-STAMPED CANDIDATE IS A COMMIT NOBODY ACKNOWLEDGED ----------------
# `reverify` RE-STAMPS candidate_sha onto the operator's own newer commit, and
# `handoff_ack` asserts that the mechanical steps THAT commit needs have been
# performed. Nobody has said that about the commit reverify just adopted — it
# is, by construction, work committed since the ack — so the acknowledgement is
# withdrawn and the pause reopens. Carrying it forward would certify on the
# operator's behalf that their new commits need no chmod and no formula re-pin,
# an assertion nobody made, and would buy a verification guaranteed to fail on
# the missing step while charging a rework round for it.
#
# Lineage does not rescue it: the gate proved the new commit DESCENDS from the
# acknowledged one, which says the acknowledged work is still there and says
# nothing at all about the commits stacked on top.
#
# And the withdrawal strands nothing, which is what the tail of this block
# proves: reverify leaves the task in `testing`, `--ack` is legal from
# `testing`, so the boundary costs exactly one command and then the pass
# verifies.
horchid task advance H010 implementing --reason "fixture: re-dispatch" >/dev/null
horchid task advance H010 testing --reason "fixture: implementer envelope ok" >/dev/null
horchid task handoff H010 --ack --reason "fixture: this candidate's mechanical steps are done" >/dev/null
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" "fixture: the hand-off is acknowledged for this candidate"
horchid task advance H010 blocked --reason "fixture: the suite failed for a reason that was not the candidate" >/dev/null
HACK_BEFORE="$(hfield handoff_ack)"
# The operator's own fix, committed on the task's branch — the move `reverify`
# exists to support.
printf 'the environment, fixed by hand\n' > "$HWT/operator-fix.txt"
git -C "$HWT" add operator-fix.txt || fail "fixture: could not stage the operator's fix"
git -C "$HWT" commit -q -m "H010: fix the fixture the suite kept tripping over" \
  || fail "fixture: the operator's fix did not land"
HREVERIFIED="$(git -C "$HWT" rev-parse HEAD)"
[ "$HREVERIFIED" != "$HACK_BEFORE" ] \
  || fail "fixture: the operator's commit did not move HEAD, so nothing below is under test"
hrev_out="$(horchid task reverify H010 --reason "the failure was the sandbox; the fix is committed on the task branch")"
assert_eq "$HREVERIFIED" "$(hfield candidate_sha)" "reverify re-stamps the candidate from the worktree HEAD"
assert_eq "" "$(hfield handoff_ack)" \
  "and CLEARS the acknowledgement — $HACK_BEFORE was acknowledged, $HREVERIFIED is a commit no operator has looked at"
assert_eq outstanding "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "so the hand-off reads outstanding again, rather than certifying the operator's new commits on their behalf"
assert_match "was cleared" "$hrev_out" \
  "and the verb SAYS it withdrew the acknowledgement, because that is an operator-visible consequence of the verb they just ran (out: $hrev_out)"
assert_match "orchid task handoff H010 --ack" "$hrev_out" \
  "naming the one command that settles it again (out: $hrev_out)"
assert_match "reverify: cleared the operator hand-off" "$(cat "$HANDOFF/.orchid/journal.md")" \
  "and journals it, so the withdrawal is on the trail and not only on a terminal that has scrolled"
rm -f "$HVERIFY_RAN"
run_hdrive
assert_eq 16 "$HDRIVE_RC" \
  "the pass after a reverify stops at the reopened boundary (out: $HDRIVE_OUT)"
[ ! -f "$HVERIFY_RAN" ] \
  || fail "the pass verified a candidate whose hand-off is outstanding — a re-stamp must not inherit an ack"
assert_eq testing "$(hfield status)" "fixture: and left the task in testing, which is where the remedy is legal"

# THE ONE COMMAND, AND THEN THE PASS PROCEEDS. This is the half that makes the
# withdrawal above a stop rather than a wedge: `--ack` is legal from `testing`,
# reverify leaves the task in `testing`, so the operator is never pushed
# backwards through `implementing` to clear it.
horchid task handoff H010 --ack --reason "fixture: the re-stamped candidate needs no mechanical step" >/dev/null
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "one command settles the reopened pause, from the status reverify itself left the task in"
rm -f "$HVERIFY_RAN"
run_hdrive
[ -f "$HVERIFY_RAN" ] \
  || fail "and then the pass VERIFIES — the reverify boundary must cost one command, not a round trip through implementing (rc=$HDRIVE_RC, out: $HDRIVE_OUT)"
assert_eq rework "$(hfield status)" "and takes the verification failure's own edge from there"
HHANDOFF_CAND="$HREVERIFIED"

# --- the binding is to a COMMITTED CANDIDATE, not to a task or a moment ----
# An acknowledgement made for one candidate must never read as satisfied for
# another. This is the shape `orchid merge`'s rebase arm produces when it moves
# candidate_sha underneath an acknowledged hand-off.
# The candidate is set to the fixture's CURRENT HEAD so this round's ack has
# nothing to advance: what is under test here is the binding, and an ack that
# also moved the candidate would prove it against a sha the test never named.
horchid task advance H010 implementing --reason "fixture: re-dispatch" >/dev/null
horchid task set H010 candidate_sha "$HHANDOFF_CAND" >/dev/null
horchid task advance H010 testing --reason "fixture" >/dev/null
horchid task handoff H010 --ack --reason "fixture: acknowledged against the pre-rebase candidate" >/dev/null
assert_eq satisfied "$(handoff_state "$HANDOFF" H010 | cut -f1)" "acknowledged for this candidate"

HREBASED=7777777777777777777777777777777777777777
horchid task set H010 candidate_sha "$HREBASED" >/dev/null
assert_eq outstanding "$(handoff_state "$HANDOFF" H010 | cut -f1)" \
  "a moved candidate_sha leaves the hand-off outstanding — a rebased tree never inherits work done on the tree it replaced"
assert_match "bound to candidate $HHANDOFF_CAND, not the current $HREBASED" "$(handoff_state "$HANDOFF" H010 | cut -f2-)" \
  "and the detail names both shas, so an operator can see WHY it stopped"

rm -f "$HVERIFY_RAN"
run_hdrive
assert_eq 16 "$HDRIVE_RC" "and a pass over it stops at the boundary again"
assert_eq operator-handoff "$(hboundary | jq -r .kind)" "with the hand-off named"
assert_eq testing "$(hfield status)" "taking no transition"
[ ! -f "$HVERIFY_RAN" ] || fail "nor verifying the candidate the hand-off was never made against"

# `--clear` is the explicit withdrawal `orchid merge`'s rebase arm calls, and
# it journals nothing when there is nothing to withdraw -- which is what lets
# that arm call it unconditionally on every rebase.
horchid task handoff H010 --clear --reason "fixture: withdraw" >/dev/null
assert_eq "" "$(hfield handoff_ack)" "--clear withdraws the acknowledgement"
hjournal_n="$(wc -l < "$HANDOFF/.orchid/journal.md" | tr -d ' ')"
horchid task handoff H010 --clear --reason "fixture: withdraw again" >/dev/null
assert_eq "$hjournal_n" "$(wc -l < "$HANDOFF/.orchid/journal.md" | tr -d ' ')" \
  "clearing an already-empty hand-off journals nothing"

# --- THE ACK IS RESTRICTED TO THE STATUS IT MEANS ANYTHING IN --------------
# `--ack` MOVES `candidate_sha`. That is safe at exactly one point in the
# procedure — `testing`, between the implementer's envelope reconciling and
# `orchid verify` running — and it is destructive everywhere reviewers or a
# merge already hold that commit: their envelopes name the sha they were
# dispatched against, so advancing underneath them leaves the record naming a
# candidate nobody looked at while the verdicts are read as judgments of it.
# `reviewing` is walked here because it is the state a real one lands in; the
# refusal is a single compare against the status, so `arbitrating` and `merging`
# take the identical path.
horchid task set H010 candidate_sha "$HHANDOFF_CAND" >/dev/null
horchid task set H010 verification_commands true >/dev/null
horchid verify H010 >/dev/null 2>&1 \
  || fail "fixture: the passing verify needed to reach reviewing did not run"
horchid task advance H010 reviewing --reason "fixture: reviewers now hold this candidate" >/dev/null
assert_eq reviewing "$(hfield status)" "fixture: the task really is under review"
hrev_rc=0
hrev_out="$(horchid task handoff H010 --ack \
  --reason "fixture: acknowledging while reviewers hold this candidate" 2>&1)" || hrev_rc=$?
[ "$hrev_rc" -ne 0 ] \
  || fail "the ack advanced candidate_sha out from under reviewers judging that exact commit (it said: $hrev_out)"
assert_match "reviewing" "$hrev_out" \
  "and the refusal names the status it declined from, not just a rule (it said: $hrev_out)"
assert_eq "$HHANDOFF_CAND" "$(hfield candidate_sha)" \
  "the candidate the reviewers are judging did not move"
assert_eq "" "$(hfield handoff_ack)" "and nothing was acknowledged"

# `--clear` is NOT restricted, and that asymmetry is deliberate: it only ever
# withdraws, `orchid merge`'s rebase arm calls it from `merging`, and a
# withdrawal some status could refuse would be a stale acknowledgement nothing
# could remove.
horchid task handoff H010 --clear --reason "fixture: withdrawal is legal from any status" >/dev/null

# Parked is not a hand-off point either — there is nothing left for one to
# unblock, and this is the cheap proof that the guard is on the STATE rather
# than a special case carved out for reviewers.
horchid task advance H010 blocked --reason "fixture: parked" >/dev/null
hblk_rc=0
hblk_out="$(horchid task handoff H010 --ack --reason "fixture: acknowledging a parked task" 2>&1)" || hblk_rc=$?
[ "$hblk_rc" -ne 0 ] \
  || fail "the ack was accepted from blocked (it said: $hblk_out)"
assert_match "blocked" "$hblk_out" "naming that status too (it said: $hblk_out)"

# The gate is opt-in: a repository that never asked for the pause is not
# gated by it and never sees the boundary at all.
assert_eq off "$(handoff_gate_mode "$REPO")" "the default is off"
assert_eq off "$(handoff_state "$REPO" T001 | cut -f1)" \
  "so a repository that never configured it is untouched by everything above"
# Part O -- AN OK ENVELOPE IS NOT EVIDENCE THAT WORK HAPPENED. An implement
# dispatch can return `ok` with a summary that is pure commentary -- findings
# restated, sources listed -- over a worktree whose HEAD never moved and whose
# tree is clean. A cross-project finding, confirmed here twice on one task:
# advancing on that spends a full verify and a full review round re-proving a
# defect this run already arbitrated, and burns a rework attempt on a
# candidate nobody touched. So delivery is judged by the WORKTREE, and a
# delivery that delivered nothing is a JOB-DELIVERY failure: it belongs on the
# escalation ladder, never on the attempt budget, and never on a transition.
#
# Part L above owns the OTHER half of this same ladder: how a relaunch already
# in flight is accounted. This part must hold without moving any reading there,
# and it does so by not building a second ladder at all: a delivery that
# delivered nothing is dropped as UNACCEPTABLE, so it reaches the same single
# `drive_escalate` call every other implement failure reaches, behind the same
# single "is a relaunch still live?" question Part L pins -- one event, one
# rung, whichever shape produced it. That question is now asked of the walk as
# a whole rather than of its failure arm alone, because a live relaunch is
# MOVING the worktree the acceptance test reads: the deferral this part
# observes below is Part L's note, word for word, and not one of its own.
#
# And a refusal has to STICK. Reconcile removes no envelope, so the refused one
# sits beside every later sibling: unmarked, it is re-selected the moment the
# relaunch moves HEAD (it stops looking like a no-op) or the moment a newer
# non-ok sibling is filed (it is still the newest ok one), and the refused work
# advances to testing by a second door. Part A proves what the mark excludes;
# this part proves the driver writes one, and that the live-relaunch window
# cannot be used to walk through the first door before it does.
# ===========================================================================
NOOP="$WORK/noopdelivery"
mkdir -p "$NOOP" "$WORK/nctl"
cd "$NOOP" || exit 1
git init -q .
printf 'role.implementer=stubnoop\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$NOOP" "$ORCHID_BIN" init >/dev/null || fail "orchid init (no-op delivery fixture)"
git checkout -q orchid/integration

# Role-eligible in every way that matters -- the launch really spawns, the job
# really exits 0, the envelope really reconciles `ok` -- and yet it commits
# NOTHING. Every signal short of the worktree says the work was done.
mkdir -p "$WORK/eng/stubnoop"
printf 'manifest_version=1\nid=test/stubnoop\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubnoop/plugin.conf"
{
  echo '#!/usr/bin/env bash'
  echo 'set -eu'
  printf 'CTL=%s\n' "$(printf '%q' "$WORK/nctl")"
} > "$WORK/eng/stubnoop/run"
cat >> "$WORK/eng/stubnoop/run" <<'EOF'
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
[ "$op" = implement ] || exit 1
# Which dispatch this is, counted by the stub itself rather than by the test's
# sense of timing: the SECOND one is the relaunch the first refusal makes, and
# it stays open -- no envelope of its own -- until the test releases it. That
# is what turns "is the refused envelope still the newest one?" into a
# deterministic question instead of a race against pass duration.
n=$(( $(cat "$CTL/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CTL/n"
if [ "$n" = 2 ]; then
  i=0
  while [ ! -f "$CTL/release" ] && [ "$i" -lt 900 ]; do sleep 0.2; i=$((i + 1)); done
fi
# The whole defect in one document: status ok, a summary about the work, and
# not one commit behind it.
#
# Written to a sibling and MOVED into place, never redirected straight at the
# spool path -- the same discipline Part L's stub keeps, and for the same
# reason: `jobs reconcile` runs concurrently with this write and quarantines a
# half-written envelope as malformed, which would delete the very delivery this
# part is about and leave the ladder counting a job that "died" instead.
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"restated the findings and listed the sources; made no edits"}' > "$out.part"
mv "$out.part" "$out"
EOF
chmod +x "$WORK/eng/stubnoop/run"

NEPOCH="$(ORCHID_REPO="$NOOP" "$ORCHID_BIN" run start | sed 's/epoch: //')"
norchid() { ORCHID_REPO="$NOOP" ORCHID_EPOCH="$NEPOCH" "$ORCHID_BIN" "$@"; }
norchid requirements import "$WORK/requirements.md" >/dev/null
norchid task create N010 "its implementer only ever talks about the work" >/dev/null
norchid task set N010 verification_commands "false" >/dev/null
norchid plan apply --reason "initial plan" >/dev/null

NTF="$NOOP/.orchid/tasks/N010.md"
NDRIVE_OUT=""; NDRIVE_RC=0
run_ndrive() {
  NDRIVE_RC=0
  NDRIVE_OUT="$(ORCHID_REPO="$NOOP" ORCHID_EPOCH="$NEPOCH" "$DRIVE" 2>&1)" || NDRIVE_RC=$?
}
nstatus() { fm_get "$NTF" status; }

# Passes until the refusal lands, asserting on EVERY one of them that the
# driver never takes the transition this part exists to refuse. `testing`
# reached even once IS the defect, whatever the run does afterwards.
npass=0
while [ "$(fm_get "$NTF" infra_failures)" = 0 ] && [ "$npass" -lt 30 ]; do
  run_ndrive
  case "$(nstatus)" in
    pending|implementing) ;;
    *) fail "N010 must never leave implementing on a dispatch that delivered nothing (got '$(nstatus)', out: $NDRIVE_OUT)"
       break ;;
  esac
  npass=$(( npass + 1 ))
  sleep 0.3
done

NBASE="$(fm_get "$NTF" base_sha)"
[ -n "$NBASE" ] || fail "the dispatch must have stamped base_sha (out: $NDRIVE_OUT)"
assert_eq implementing "$(nstatus)" \
  "an ok envelope over an unmoved worktree takes NO transition — the task stays exactly where it was"
assert_eq 1 "$(fm_get "$NTF" infra_failures)" \
  "the refusal is charged to infra_failures, the job-delivery counter (out: $NDRIVE_OUT)"
assert_eq 0 "$(fm_get "$NTF" attempts)" \
  "and never to attempts: nothing was delivered for the rework budget to be judging"
assert_eq "" "$(fm_get "$NTF" candidate_sha)" \
  "no candidate_sha was recorded — there is no new candidate to record"
[ ! -f "$NOOP/.orchid/reviews/N010-verify.log" ] \
  || fail "the refusal must cost no verify round — that is precisely the price of a false advance"
assert_match "moved no commit" "$NDRIVE_OUT" "the pass says plainly what it refused and why"
# The pass's EXIT STATUS is the driver's own report of what it decided, and it
# is the half a message check cannot see. 0, not 16: a delivery that delivered
# nothing is a job-delivery failure the ladder already knows how to answer --
# count the rung, relaunch the implementer -- so the pass resolves it and keeps
# driving. Stopping at a judgment boundary here would wake an operator for a
# failure with a deterministic recovery, and any other code would mean the
# refusal path died rather than took the arm above.
assert_eq 0 "$NDRIVE_RC" \
  "the refusal is a rung of the ladder, not a judgment boundary — the pass resolves it and exits 0 (out: $NDRIVE_OUT)"

# The journal entry IS the record of the refusal, and it names BOTH shas: what
# the worktree actually holds, and what the task already had recorded.
njournal="$(cat "$NOOP/.orchid/journal.md")"
assert_match "HEAD $NBASE is unchanged from the task's recorded $NBASE" "$njournal" \
  "the journalled refusal names the observed HEAD and the recorded sha it failed to move past"
assert_match "infra failure #1" "$njournal" \
  "recorded through orchid task infra-fail, so it carries the kernel's own counter, cap and journal discipline"

# AND THE REFUSAL IS RECORDED AGAINST THE ENVELOPE, not just against the pass
# that made it. Part A proves what that mark then excludes; this is the half
# only the driver can be asked -- that it writes one at all, through the same
# named verb every other field it owns goes through.
assert_match "N010-a1-implementer.json" "$(fm_get "$NTF" refused_envelopes)" \
  "the refused envelope is named on the task — a refusal that leaves it selectable is not a refusal"

# That refusal relaunched the implementer, and this fixture holds that job
# open. The envelope the next pass reads is therefore STILL the one already
# refused -- refusing it again would charge one infra_failure per pass and race
# a second implementer against the live one.
run_ndrive
assert_eq 1 "$(fm_get "$NTF" infra_failures)" \
  "the same refused envelope is never escalated twice while its own relaunch is still outstanding"
assert_match "a relaunched implement job is still running" "$NDRIVE_OUT" \
  "and it is Part L's own deferral that says so — this refusal rides that ladder, it does not run a second one beside it"
assert_eq implementing "$(nstatus)" "still implementing, still waiting"
assert_eq 0 "$NDRIVE_RC" \
  "deferring to a live relaunch is a WAIT — it costs a pass and nothing else (out: $NDRIVE_OUT)"

# THE OTHER DOOR, and the pass that used to walk through it. The relaunch this
# refusal started is alive and free to commit to the worktree at any instant --
# so the commit is made here, by hand, in exactly that window. The moment it
# lands, the ALREADY REFUSED envelope stops looking like a no-op (HEAD is off
# the floor) and a driver that reads envelopes while a job is outstanding would
# advance that half-written tree to testing on the authority of a document
# written before any of it existed, and stamp it as the candidate while its
# author is still typing.
NWT="$(fm_get "$NTF" worktree)"
[ -n "$NWT" ] || fail "the dispatch must have recorded a worktree for N010"
git -C "$NWT" commit -q --allow-empty -m "fixture: the live relaunch's first commit"
NMOVED="$(git -C "$NWT" rev-parse HEAD)"
[ "$NMOVED" != "$NBASE" ] || fail "the fixture commit must really move the worktree HEAD"
run_ndrive
assert_eq implementing "$(nstatus)" \
  "a HEAD moved by the LIVE relaunch is not delivery by the envelope already refused (out: $NDRIVE_OUT)"
assert_eq "" "$(fm_get "$NTF" candidate_sha)" \
  "and nothing is stamped as the candidate: no envelope has been filed over that commit by anyone"
assert_eq 1 "$(fm_get "$NTF" infra_failures)" \
  "nor is a second rung spent while that relaunch is still live"
assert_match "a relaunched implement job is still running" "$NDRIVE_OUT" \
  "and the LIVE JOB is what the pass defers to: with a relaunch outstanding the walk does not read an envelope at all, whatever the worktree now says"
assert_eq 0 "$NDRIVE_RC" "the pass is still a wait (out: $NDRIVE_OUT)"
# Rolled back, so the rest of this part measures the same unmoved worktree it
# started with: what follows is about the ladder's bound, not about this commit.
git -C "$NWT" reset -q --hard "$NBASE"

# Released: the relaunch files its own envelope, equally empty. The ladder now
# runs to its own bound -- a human -- instead of either advancing or looping.
: > "$WORK/nctl/release"
npass=0
while [ "$(nstatus)" != blocked ] && [ "$npass" -lt 40 ]; do
  run_ndrive
  case "$(nstatus)" in
    implementing|blocked) ;;
    *) fail "a repeated no-op delivery must still never advance (got '$(nstatus)', out: $NDRIVE_OUT)"
       break ;;
  esac
  npass=$(( npass + 1 ))
  sleep 0.3
done
assert_eq blocked "$(nstatus)" \
  "an implementer that keeps delivering nothing reaches a human through the infra_failures cap (out: $NDRIVE_OUT)"
assert_eq 3 "$(fm_get "$NTF" infra_failures)" \
  "the bound it hit is infra_max, the job-delivery budget"
assert_eq 0 "$(fm_get "$NTF" attempts)" \
  "and after three no-op deliveries the task's rework budget is still whole — none of them was a rework"
assert_eq "" "$(fm_get "$NTF" candidate_sha)" "no candidate was ever recorded for this task"
# Three dispatches, three empty envelopes, three refusals -- and every one of
# them still refused at the end, including the one refused by the pass that hit
# the cap. A list that only ever holds the LATEST refusal would re-open the
# earlier doors the moment this task was unblocked and retried.
nrefused="$(fm_get "$NTF" refused_envelopes)"
for nenv in N010-a1-implementer.json N010-a1-implementer.2.json N010-a1-implementer.3.json; do
  case " $nrefused " in
    *" $nenv "*) ;;
    *) fail "every refused envelope stays refused — $nenv is missing from '$nrefused'" ;;
  esac
done
[ ! -f "$NOOP/.orchid/reviews/N010-verify.log" ] \
  || fail "no verify round may be spent on a candidate that was never delivered"
for nrev in "$NOOP"/.orchid/reviews/N010-a*-reviewer*.json; do
  [ -e "$nrev" ] || continue
  fail "no review round may be spent on a candidate that was never delivered ($nrev)"
done

# And the ladder's bound is a HUMAN, reported the way every other parked run is
# reported: the next pass over the blocked task stops at a judgment boundary and
# says so in its exit status. This is the assertion that the refusal path ends
# somewhere, rather than driving on forever over a task no engine can move.
run_ndrive
assert_eq 16 "$NDRIVE_RC" \
  "the pass after the cap stops at a judgment boundary, the one exit status that fetches an operator (out: $NDRIVE_OUT)"
assert_eq blocked-task "$(ORCHID_REPO="$NOOP" "$ORCHID_BIN" run boundary show 2>/dev/null | jq -r '.kind // ""')" \
  "and the boundary it records is the blocked task itself"

# ===========================================================================
# Part P -- A SHA COMPARISON CANNOT SEE THE TREE. Part O judges delivery by
# comparing the worktree HEAD against the sha the round was dispatched to move,
# and an unmoved HEAD is no candidate however the envelope reads. But a sha
# describes a COMMIT and says nothing about the tree sitting on top of it, so
# that one comparison answers "delivered nothing" for two failures that are not
# the same failure:
#
#   * the commentary-only round -- no commit AND no edit. Part O's case. Its
#     recovery is deterministic: spend the job-delivery rung and relaunch the
#     implementer into the same worktree, which is exactly where it left off.
#   * a dispatch that DID the work and never committed it. The worktree holds
#     real, uncommitted output. Relaunching over it hands the next dispatch a
#     tree it did not create and cannot account for -- it will commit those
#     edits as its own, revert them, or build on top of them, and whichever it
#     does, the journal will read as the work of a round that never wrote them.
#     Throwing the work away is a decision about somebody's real output, which
#     is not a rung of a ladder; it is the operator's call.
#
# So this part pins the SECOND one, and pins that it is handled differently:
# no rung, no relaunch, no refusal mark, and a judgment boundary naming what is
# on disk. RED before this task's fix: the fixture below took Part O's arm --
# an infra_failure and a relaunch straight into the dirty tree.
# ===========================================================================
UNCM="$WORK/uncommitted"
mkdir -p "$UNCM" "$WORK/uctl"
cd "$UNCM" || exit 1
git init -q .
printf 'role.implementer=stubdirty\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$UNCM" "$ORCHID_BIN" init >/dev/null || fail "orchid init (uncommitted-delivery fixture)"
git checkout -q orchid/integration

# The same stub as Part O's in every respect but one: it WRITES. A file lands
# in the task worktree, no commit is made, and the envelope reports ok.
mkdir -p "$WORK/eng/stubdirty"
printf 'manifest_version=1\nid=test/stubdirty\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubdirty/plugin.conf"
{
  echo '#!/usr/bin/env bash'
  echo 'set -eu'
  printf 'CTL=%s\n' "$(printf '%q' "$WORK/uctl")"
} > "$WORK/eng/stubdirty/run"
cat >> "$WORK/eng/stubdirty/run" <<'EOF'
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
wt="$(jq -r .worktree "$req")"
[ "$op" = implement ] || exit 1
# Counted by the stub itself: this is how the test asks "was a second
# implementer launched over the tree the first one dirtied?" without racing the
# pass. A relaunch here is the defect.
echo "$(( $(cat "$CTL/n" 2>/dev/null || echo 0) + 1 ))" > "$CTL/n"
printf 'the fix this round was dispatched to make\n' > "$wt/half-done.txt"
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"applied the fix"}' > "$out.part"
mv "$out.part" "$out"
EOF
chmod +x "$WORK/eng/stubdirty/run"

UEPOCH="$(ORCHID_REPO="$UNCM" "$ORCHID_BIN" run start | sed 's/epoch: //')"
uorchid() { ORCHID_REPO="$UNCM" ORCHID_EPOCH="$UEPOCH" "$ORCHID_BIN" "$@"; }
uorchid requirements import "$WORK/requirements.md" >/dev/null
uorchid task create U010 "its implementer edits the tree and never commits" >/dev/null
uorchid task set U010 verification_commands "false" >/dev/null
uorchid plan apply --reason "initial plan" >/dev/null

UTF="$UNCM/.orchid/tasks/U010.md"
UDRIVE_OUT=""; UDRIVE_RC=0
run_udrive() {
  UDRIVE_RC=0
  UDRIVE_OUT="$(ORCHID_REPO="$UNCM" ORCHID_EPOCH="$UEPOCH" "$DRIVE" 2>&1)" || UDRIVE_RC=$?
}
ustatus() { fm_get "$UTF" status; }

# Passes until the boundary lands. `testing` reached even once IS the defect --
# there is no candidate, whatever is sitting in the tree.
upass=0
while [ "$UDRIVE_RC" -ne 16 ] && [ "$upass" -lt 30 ]; do
  run_udrive
  case "$(ustatus)" in
    pending|implementing) ;;
    *) fail "U010 must never leave implementing on a dispatch that committed nothing (got '$(ustatus)', out: $UDRIVE_OUT)"
       break ;;
  esac
  upass=$(( upass + 1 ))
  sleep 0.3
done

UWT="$(fm_get "$UTF" worktree)"
[ -n "$UWT" ] || fail "the dispatch must have recorded a worktree for U010"
UBASE="$(fm_get "$UTF" base_sha)"
assert_eq 16 "$UDRIVE_RC" \
  "the pass stops at a judgment boundary — this failure has no deterministic recovery a driver may take on its own (out: $UDRIVE_OUT)"
assert_eq operator-decision "$(ORCHID_REPO="$UNCM" "$ORCHID_BIN" run boundary show 2>/dev/null | jq -r '.kind // ""')" \
  "and the boundary is an operator-decision: commit the work onto the branch or throw it away is a call about somebody's real output"
assert_eq implementing "$(ustatus)" \
  "the task itself has not moved — an unmoved HEAD is no candidate, however much is sitting in the tree"
assert_eq "" "$(fm_get "$UTF" candidate_sha)" \
  "and nothing is stamped as the candidate: the work exists nowhere a sha can name"
assert_eq "$UBASE" "$(git -C "$UWT" rev-parse HEAD)" \
  "nor did anything commit on the dispatch's behalf"

# THE DISTINCTION, in the two places it has to show. The pass SAYS which of the
# two failures this was...
assert_match "uncommitted work" "$UDRIVE_OUT" \
  "the pass names what actually happened — 'delivered nothing' would be a false report of a tree with the work in it"
assert_match "half-done.txt" "$UDRIVE_OUT" \
  "and names the paths, so the operator can see what they are being asked to decide about without going looking"

# ...and NOTHING IS CHARGED. Part O's rung belongs to a failure with a
# deterministic recovery; this one is a stop, and a stop that also spent a rung
# would walk this task toward `blocked` on passes an operator has not answered
# yet.
assert_eq 0 "$(fm_get "$UTF" infra_failures)" \
  "no job-delivery rung is spent: the ladder's recovery is a relaunch, and a relaunch is exactly what must not happen here"
assert_eq 0 "$(fm_get "$UTF" attempts)" \
  "and no attempt either — the rework budget bounds defects in delivered work, and none was delivered"
assert_eq "" "$(fm_get "$UTF" refused_envelopes)" \
  "nor is the envelope marked refused: once the operator commits that work it IS the delivery this envelope reported, and a mark would make it unselectable forever"
assert_eq 1 "$(cat "$WORK/uctl/n")" \
  "and no second implementer was launched into the tree the first one dirtied"
assert_eq "the fix this round was dispatched to make" "$(cat "$UWT/half-done.txt")" \
  "the uncommitted work is still there, untouched — the driver reports it, it does not clean up after an engine"

# A second pass changes none of that. The boundary is re-raised from the same
# facts rather than escalating: an unanswered stop is not a fresh event.
run_udrive
assert_eq 16 "$UDRIVE_RC" "the stop holds until a human answers it (out: $UDRIVE_OUT)"
assert_eq 0 "$(fm_get "$UTF" infra_failures)" "and re-reading the same tree spends nothing"
assert_eq 1 "$(cat "$WORK/uctl/n")" "still one implementer, still no relaunch"
assert_eq implementing "$(ustatus)" "still implementing, still no candidate"

# THE OPERATOR ANSWERS IT, the way the boundary asks: the work is committed onto
# the task branch. Now there IS a candidate, and the envelope that reported it
# is still on disk and still selectable -- which is the whole reason it was not
# marked refused. This is the assertion that the stop is EXITABLE.
git -C "$UWT" add -- half-done.txt
git -C "$UWT" commit -q -m "operator: commit the work the dispatch left behind"
UCOMMIT="$(git -C "$UWT" rev-parse HEAD)"
[ "$UCOMMIT" != "$UBASE" ] || fail "the operator's commit must really move the worktree HEAD"
run_udrive
assert_eq "$UCOMMIT" "$(fm_get "$UTF" candidate_sha)" \
  "the committed work is recorded as the candidate — the refusal was about a tree with no commit in it, not about this envelope (out: $UDRIVE_OUT)"
if [ "$(ustatus)" = implementing ]; then
  fail "and the task leaves implementing once a candidate exists — a boundary that cannot be answered is a deadlock, not a stop (out: $UDRIVE_OUT)"
fi
assert_eq 0 "$(fm_get "$UTF" infra_failures)" \
  "with nothing ever charged for the round the operator completed"

# ===========================================================================
# Part Q -- A ROUND THAT ADDED NOTHING TO A CANDIDATE IS NOT A ROUND THAT
# DELIVERED NOTHING (lesson L039). Part O judges delivery by comparing the
# worktree HEAD against the sha the round was dispatched to move, and that
# sha -- the FLOOR -- is the task's `candidate_sha` where it has one and its
# `base_sha` where it does not. So "HEAD is still the floor" collapses two
# situations that are not the same situation at all:
#
#   * THE FLOOR IS THE BASE. Nothing was ever produced, by this round or any
#     before it. Part O's case, and it is unchanged here: still refused, still
#     charged to the job-delivery ladder, still marked.
#   * THE FLOOR IS A CANDIDATE AHEAD OF THAT BASE. The work is already on disk.
#     The driver stamped that sha itself, from a HEAD it read in this very
#     worktree, so a candidate demonstrably EXISTS -- and this round adding no
#     commit on top of it is a routing question, not a delivery failure.
#
# Charging the second to the infra ladder is what this part exists to stop. It
# is not a hypothetical and not a lazy engine: a rebase rewrites a task's
# commits, the driver re-stamps the new HEAD as `candidate_sha`, the next round
# dispatches, and the implementer finds its own already-delivered work in place
# and truthfully says so. Every run with concurrency above one rebases in-flight
# tasks onto a moved integration branch, so every such run reaches this. In the
# run this lesson comes from it blocked twenty-six of forty tasks inside four
# hours -- ten of them without ever spending an attempt -- because the honest
# answer "the work is already delivered, and manufacturing a diff to look
# productive would be worse" was charged as an infra failure until the cap.
#
# THIS FIXTURE IS THAT REBASE, WITHOUT NEEDING ONE: an implementer that
# delivers a real commit on its first dispatch and, on every dispatch after,
# reports ok and commits nothing because there is nothing left to commit. What
# must hold is that the second round is ROUTED (advanced on the candidate that
# exists), that it costs no rung of the job-delivery ladder, that no envelope is
# marked refused, and that the journal says which of the two clean cases it was.
# RED before this task's fix: the second round took Part O's arm -- infra
# failures 1, 2, 3 and `blocked`, with the candidate sitting untouched in the
# worktree the whole time.
#
# BOTH EDGES, per lesson L034: Part O above pins the too-permissive one end to
# end and must keep passing exactly as written, and this part pins the
# too-strict one. The unit-level pair sits together in Part A.
# ===========================================================================
DONE="$WORK/alreadydone"
mkdir -p "$DONE" "$WORK/dctl"
cd "$DONE" || exit 1
git init -q .
printf 'role.implementer=stubdone\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$DONE" "$ORCHID_BIN" init >/dev/null || fail "orchid init (already-delivered fixture)"
git checkout -q orchid/integration

mkdir -p "$WORK/eng/stubdone"
printf 'manifest_version=1\nid=test/stubdone\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubdone/plugin.conf"
{
  echo '#!/usr/bin/env bash'
  echo 'set -eu'
  printf 'CTL=%s\n' "$(printf '%q' "$WORK/dctl")"
} > "$WORK/eng/stubdone/run"
cat >> "$WORK/eng/stubdone/run" <<'EOF'
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
wt="$(jq -r .worktree "$req")"
[ "$op" = implement ] || exit 1
# Which dispatch this is, counted by the stub itself: the test asks "was an
# implementer RELAUNCHED over a candidate that already exists?" and a count is
# the only answer that does not race the pass.
n=$(( $(cat "$CTL/n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CTL/n"
if [ "$n" = 1 ]; then
  # The delivering round. A real commit, exactly what an implementer with work
  # to do leaves behind -- this is what makes every later round's unmoved HEAD
  # a candidate rather than a base.
  cd "$wt" || exit 1
  echo "the feature this task was dispatched for" > feature.txt
  git add feature.txt
  git -c user.email=stub@example.invalid -c user.name="stub" commit -q -m "stub: deliver $task"
  jq -n --arg jid "$jid" --arg task "$task" --arg sha "$(git rev-parse HEAD)" \
    '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
      summary:"delivered the feature", commits:[$sha]}' > "$out.part"
  mv "$out.part" "$out"
  exit 0
fi
# Every round after it: the honest answer, and the exact one the run this
# lesson comes from punished. The work is in place, so nothing is edited and
# nothing is committed -- manufacturing a diff to look productive would be
# worse than reporting the work as delivered.
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"found nothing to change: the candidate already contains this work, and I made no edits"}' > "$out.part"
mv "$out.part" "$out"
EOF
chmod +x "$WORK/eng/stubdone/run"

DEPOCH="$(ORCHID_REPO="$DONE" "$ORCHID_BIN" run start | sed 's/epoch: //')"
dorchid() { ORCHID_REPO="$DONE" ORCHID_EPOCH="$DEPOCH" "$ORCHID_BIN" "$@"; }
dorchid requirements import "$WORK/requirements.md" >/dev/null
dorchid task create D010 "its second implementer finds the work already done" >/dev/null
# Verification that always fails, so the task is sent back to `rework` and
# dispatched a SECOND time over the candidate the first round delivered. That
# second dispatch is the whole subject of this part.
dorchid task set D010 verification_commands "false" >/dev/null
dorchid plan apply --reason "initial plan" >/dev/null

DTF="$DONE/.orchid/tasks/D010.md"
# DDRIVE_OUT holds ONE pass's output and is reassigned on every pass; the
# routing note this part pins is emitted on whichever pass routes the case,
# which the loops below overrun. DDRIVE_ALL accumulates every pass for the
# assertions that mean "some pass said this"; DDRIVE_OUT stays for the ones
# that genuinely mean the last pass.
DDRIVE_OUT=""; DDRIVE_ALL=""; DDRIVE_RC=0
run_ddrive() {
  DDRIVE_RC=0
  DDRIVE_OUT="$(ORCHID_REPO="$DONE" ORCHID_EPOCH="$DEPOCH" "$DRIVE" 2>&1)" || DDRIVE_RC=$?
  DDRIVE_ALL="$DDRIVE_ALL$DDRIVE_OUT
"
}
dstatus() { fm_get "$DTF" status; }

# Passes until the SECOND rework round has been accounted -- `attempts` at 2
# means the round that committed nothing was routed through testing like any
# other delivery. The job-delivery ladder is asserted on EVERY pass, not only
# at the end: one rung charged anywhere in here is the defect, whatever the run
# does afterwards.
dpass=0
while [ "$(fm_get "$DTF" attempts)" -lt 2 ] && [ "$dpass" -lt 60 ]; do
  run_ddrive
  if [ "$(fm_get "$DTF" infra_failures)" != 0 ]; then
    fail "a round that added nothing to an EXISTING candidate must never be charged to the job-delivery ladder — the candidate is on disk, so there is nothing to relaunch for (out: $DDRIVE_OUT)"
    break
  fi
  dpass=$(( dpass + 1 ))
  sleep 0.3
done

DWT="$(fm_get "$DTF" worktree)"
[ -n "$DWT" ] || fail "the dispatch must have recorded a worktree for D010"
DBASE="$(fm_get "$DTF" base_sha)"
DCAND="$(fm_get "$DTF" candidate_sha)"
[ -n "$DCAND" ] || fail "the first round must have delivered a candidate (out: $DDRIVE_OUT)"
[ "$DCAND" != "$DBASE" ] || fail "and that candidate must be AHEAD of the base — otherwise this fixture is Part O's case, not this one's"
assert_eq 2 "$(fm_get "$DTF" attempts)" \
  "the round that added no commit to an existing candidate is ROUTED, not refused: it reached testing, failed verification there like any other candidate, and spent the rework budget that bounds delivered work (out: $DDRIVE_OUT)"
assert_eq 0 "$(fm_get "$DTF" infra_failures)" \
  "and spent no rung of the job-delivery ladder, whose recovery is a relaunch — there is nothing here to relaunch FOR"
assert_eq "" "$(fm_get "$DTF" refused_envelopes)" \
  "nor is the envelope marked refused: it truthfully describes the candidate the task has, and a mark would make it unselectable forever"
assert_eq "$DCAND" "$(git -C "$DWT" rev-parse HEAD)" \
  "the candidate is exactly where the first round left it — the second round added nothing to it, and nothing was manufactured on its behalf"
assert_eq 2 "$(cat "$WORK/dctl/n")" \
  "and exactly two implementers ran: the one that delivered and the one that found the work in place — no relaunch was spawned over a candidate that already existed"
assert_eq "the feature this task was dispatched for" "$(cat "$DWT/feature.txt")" \
  "the delivered work is still there, untouched: work a job already completed is not discarded"

# THE PASS SAYS WHICH CASE THIS WAS, and so does the JOURNAL. A pass message is
# gone with the pass; an operator reading a run back afterwards has only the
# journal, and "implementer envelope ok" alone would leave a round that
# committed nothing looking identical to one that committed everything.
assert_match "a candidate exists and this round added nothing to it" "$DDRIVE_ALL" \
  "the pass names the case it routed rather than reporting a delivery it did not see"
djournal="$(cat "$DONE/.orchid/journal.md")"
assert_match "a candidate exists and this round added nothing to it" "$djournal" \
  "and the journal carries it too, through the same named verb the transition goes through — which of the two clean cases this was"
assert_match "not a delivery failure" "$djournal" \
  "saying WHY in the journal and not only what: the whole defect was a routing question accounted as a failure"

# AND IT IS BOUNDED. Advancing is not a licence to loop: an engine that keeps
# adding nothing to a candidate that keeps failing verification runs out of the
# ATTEMPT budget -- the budget for defects in work that WAS delivered -- and
# reaches a human there, never on the job-delivery ladder it was wrongly charged
# to before.
dpass=0
while [ "$(dstatus)" != blocked ] && [ "$dpass" -lt 60 ]; do
  run_ddrive
  dpass=$(( dpass + 1 ))
  sleep 0.3
done
assert_eq blocked "$(dstatus)" \
  "an implementer that keeps finding its work already done still reaches a human (out: $DDRIVE_OUT)"
assert_eq 3 "$(fm_get "$DTF" attempts)" \
  "and the bound it hit is the ATTEMPT cap: every one of those rounds was a rework round over a candidate that exists"
assert_eq 0 "$(fm_get "$DTF" infra_failures)" \
  "with the job-delivery ladder never touched from the first pass to the last — that ladder is for dispatches that produced nothing, and this task produced a candidate on its first one"
assert_eq "" "$(fm_get "$DTF" refused_envelopes)" \
  "and no envelope was ever refused: none of them lied about the worktree"

# ===========================================================================
# Part R -- THE TWO HALVES OF THE SOFT-SURFACE FIX, PINNED TO EACH OTHER.
#
# Classifying the surface correctly is only half the fix. A soft adapter IS
# still woken for the one kind its contract settles (an arbitration on an
# `arbitrating` task, asserted first below as this Part's premise), so the
# PROMPT that adapter hands the model is what actually decides that boundary.
# An adapter still carrying the pre-v1.1 "execute ONE tick" instruction re-runs
# a pass `orchid drive` has already run and never touches the record — while
# policy, having counted the wakeup as this boundary's resolution route,
# suppressed the `orchid notify` blocker that would have told a human. Same
# never-told-the-human failure, one layer up from the one Part I pins.
#
# So: every shipped adapter that HANDLES the orchestrate operation must feed
# the judgment-boundary contract, and must not feed a tick instruction — and
# every shipped adapter that does NOT handle it must REFUSE it, loudly, which
# the sweep proves as behaviour below rather than assuming from an absent
# dispatch line. The prompt check is static and reads the `instructions=` line
# each adapter actually builds — asserting against the real vendor CLI would
# mean spawning one.
# ===========================================================================
drive_boundary_wakes_orchestrator review-conflict arbitrating soft \
  || fail "Part R's premise: a soft adapter really is woken for an arbitrable boundary"

orch_adapters=0
for _run in "$REPO_ROOT"/plugins/engines/*/run; do
  [ -f "$_run" ] || continue
  _name="$(basename "$(dirname "$_run")")"
  # The dispatch line every orchestrate-capable adapter in this tree carries.
  # An adapter that does not carry it must be UNABLE to serve the role — "it
  # refuses the operation" is the other honest answer to "can you serve this
  # role", and it has to be proven as behaviour, not read off the absent
  # dispatch: an adapter that absorbed `orchestrate` through its case-pattern
  # list (the review adapters' dispatch shape) would carry no dispatch line
  # either, and a wakeup routed through it would be swallowed with none of
  # the prompt checks below ever applying. So hand each one a real orchestrate
  # request and require the loud no: nonzero exit, a non-ok envelope for
  # reconcile to see, and a refusal that names the operation. ORCHID_DRYRUN=1
  # is belt and braces — every shipped adapter gates the operation BEFORE its
  # dryrun short-circuit, and one that admitted the operation would answer the
  # dryrun `ok`/exit-0 and trip every assertion here, rather than spawn a
  # vendor CLI.
  if ! grep -q 'operation" = orchestrate' "$_run"; then
    _ref_env="$WORK/qrefuse-$_name.json"
    _ref_req="$WORK/qrefuse-$_name.request.json"
    rm -f "$_ref_env"
    jq -n --arg out "$_ref_env" \
      '{job_id:"j-qrefuse", task:"T000", operation:"orchestrate", worktree:".",
        input_pack:".", output:$out, base_sha:"", candidate_sha:""}' > "$_ref_req"
    _ref_rc=0
    _ref_out="$(ORCHID_DRYRUN=1 "$_run" "$_ref_req" 2>&1)" || _ref_rc=$?
    [ "$_ref_rc" -ne 0 ] \
      || fail "$_name neither carries the judgment-boundary dispatch nor refuses an orchestrate request — a wakeup routed through it would be absorbed by another door (out: $_ref_out)"
    assert_match "operation 'orchestrate'" "$_ref_out" \
      "$_name's refusal must name the operation it turned down"
    if [ -f "$_ref_env" ]; then
      case "$(jq -r .status "$_ref_env" 2>/dev/null || echo unreadable)" in
        ok) fail "$_name answered an operation it does not serve with an ok envelope" ;;
      esac
    else
      fail "$_name refused orchestrate without writing an envelope — reconcile would never see the job fail, and it would sit prepared/running forever"
    fi
    continue
  fi
  orch_adapters=$(( orch_adapters + 1 ))
  _instr="$(grep 'instructions=' "$_run" || true)"
  [ -n "$_instr" ] \
    || fail "$_name handles orchestrate but builds no instruction block this check can read"
  case "$_instr" in
    *"Execute ONE tick"*|*"execute ONE tick"*|*"Execute one tick"*)
      fail "$_name's orchestrate prompt still tells a woken model to execute a whole tick — the driver already ran it, and boundary policy counts that wakeup as this boundary's resolution" ;;
  esac
  case "$_instr" in
    *"run boundary show"*) ;;
    *) fail "$_name's orchestrate prompt must send the woken model to the boundary record first" ;;
  esac
  case "$_instr" in
    *"task arbitrate"*) ;;
    *) fail "$_name's orchestrate prompt must name the verb that records an arbitration" ;;
  esac
  case "$_instr" in
    *notify*) ;;
    *) fail "$_name's orchestrate prompt must offer notify for a boundary it cannot settle" ;;
  esac
  case "$_instr" in
    *"run boundary clear"*) ;;
    *) fail "$_name's orchestrate prompt must name the verb that releases the record" ;;
  esac
done
[ "$orch_adapters" -ge 2 ] \
  || fail "Part R swept $orch_adapters orchestrate-capable adapter(s) — it is not looking at the shipped ones"

# And the classification half, stated as data rather than through a boundary:
# what a soft surface admits is exactly what that contract asks for. A verb
# the prompt never names must not be admitted by either surface, or the
# suppression of the notify blocker starts again.
drive_surface_admits soft task-arbitrate \
  || fail "the arbitration the orchestrate contract asks for must be admitted on a soft surface"
drive_surface_admits soft notify \
  || fail "so must the notify it is told to fall back to"
# The two negatives are queried through the settling-verb table, not retyped:
# a negative admits-check passes for ANY unknown string, so a literal here
# would go silently vacuous the day the atom were respelled. Reading the atom
# from drive_boundary_settling_verb ties the query to the spelling the driver
# itself classifies with, and the assert_eq beside it is the tripwire that
# fails LOUDLY on a respelling instead of letting the negative prove nothing.
r_accept_verb="$(drive_boundary_settling_verb run-complete)"
assert_eq run-accept "$r_accept_verb" \
  "Part R's run-complete negative queries the atom the table really names"
if drive_surface_admits soft "$r_accept_verb"; then
  fail "no orchestrate prompt names 'orchid run accept', so no surface may admit it"
fi
r_plan_verb="$(drive_boundary_settling_verb planning)"
assert_eq plan-apply "$r_plan_verb" \
  "and the PLANNING negative likewise"
if drive_surface_admits soft "$r_plan_verb"; then
  fail "and none names 'orchid plan apply' either"
fi

# ===========================================================================
# Part S -- the rework budget is CONFIGURATION, and one task can be granted
# more of it (T026, dogfood F28).
#
# It used to be the literal `attempts >= 3` in this driver's testing arm.
# With `attempts` on `task set`'s kernel-owned deny-list and both operator
# recovery verbs (`unblock`, `retry`) returning a task to `rework` without
# touching the counter, a task that had spent its rounds on causes the
# protocol says must NOT be charged -- an environment failure, an
# operator-caused no-op rebase -- could not be given another round through
# ANY verb: it re-blocked on its very next verify failure, forever. The only
# move left was hand-editing frontmatter.
#
# Three claims, in order: the repo-wide cap is read from config; a grant made
# through the real verb actually buys another round from the DRIVER; and the
# granted budget is itself a cap, not an unlock.
#
# No engine is ever started here: the task is parked in `testing` before each
# pass, and the testing arm runs `orchid verify` in the pass's own foreground.
# ===========================================================================
CAPD="$WORK/attemptcap"
mkdir -p "$CAPD"
cd "$CAPD" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nrework_max=1\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CAPD" "$ORCHID_BIN" init >/dev/null || fail "orchid init (attempt-budget fixture)"
git checkout -q orchid/integration
CEPOCH="$(ORCHID_REPO="$CAPD" "$ORCHID_BIN" run start | sed 's/epoch: //')"
corchid() { ORCHID_REPO="$CAPD" ORCHID_EPOCH="$CEPOCH" "$ORCHID_BIN" "$@"; }
corchid requirements import "$WORK/requirements.md" >/dev/null
corchid task create C010 "its suite fails and its budget is one round" >/dev/null
corchid task set C010 verification_commands "exit 1" >/dev/null
corchid plan apply --reason "initial plan" >/dev/null

CTASK="$CAPD/.orchid/tasks/C010.md"
CCAND="$(git -C "$CAPD" rev-parse HEAD)"
fm_set "$CTASK" base_sha "$CCAND"
fm_set "$CTASK" candidate_sha "$CCAND"
fm_set "$CTASK" attempts 1
cfield() { fm_get "$CTASK" "$1"; }
CDRIVE_RC=0; CDRIVE_OUT=""
# Parked in `testing` before every pass: this is a driver test, not a
# lifecycle one -- what it measures is which way the testing arm turns when
# the suite fails, given the budget in force.
run_cdrive() {
  fm_set "$CTASK" status testing
  CDRIVE_RC=0
  CDRIVE_OUT="$(ORCHID_REPO="$CAPD" ORCHID_EPOCH="$CEPOCH" "$DRIVE" 2>&1)" || CDRIVE_RC=$?
}

# 1. `rework_max=1` in orchid.config, one attempt already spent: the driver
#    stops here. Under the old hardcoded 3 it would have reworked twice more.
run_cdrive
assert_eq blocked "$(cfield status)" \
  "the rework budget comes from config: rework_max=1 with 1 attempt spent blocks instead of reworking (rc=$CDRIVE_RC, out: $CDRIVE_OUT)"
assert_match "attempts exhausted \(1/1\)" "$CDRIVE_OUT" \
  "and the pass reports the budget it enforced, not a bare 'exhausted' (out: $CDRIVE_OUT)"

# 2. The operator grants two more rounds through the verb -- and the driver
#    honors the grant on its very next pass.
CGRANT_OUT="$(corchid task retry C010 --reason "both spent attempts were the environment, not the candidate" --attempts 2)"
assert_eq 3 "$(cfield attempt_budget)" \
  "task retry --attempts 2 records a per-task budget of attempts+2 (out: $CGRANT_OUT)"
assert_eq 1 "$(cfield attempts)" \
  "and never winds the attempt COUNTER back -- every reviews/<id>-a<n>-*.json stays keyed to the attempt that wrote it"
run_cdrive
assert_eq rework "$(cfield status)" \
  "the granted budget really does buy another round from the driver (rc=$CDRIVE_RC, out: $CDRIVE_OUT)"
assert_eq 2 "$(cfield attempts)" \
  "and that round consumes an attempt like any other"

# 3. The grant is a BUDGET, not an unlock: at attempts 3 of 3 the driver
#    stops again, on the per-task number this time rather than the config one.
run_cdrive
assert_eq rework "$(cfield status)" "attempts 2 of 3 still has a round left"
assert_eq 3 "$(cfield attempts)" "which it spends"
run_cdrive
assert_eq blocked "$(cfield status)" \
  "and the granted budget is exhausted in its turn (rc=$CDRIVE_RC, out: $CDRIVE_OUT)"
assert_match "attempts exhausted \(3/3\)" "$CDRIVE_OUT" \
  "reported against the per-task budget the operator granted (out: $CDRIVE_OUT)"
# The boundary the pass recorded is what an operator (or a woken orchestrator)
# actually reads back, so the recovery verbs have to be named THERE, not only
# in the pass's own console output.
CBOUNDARY="$(ORCHID_REPO="$CAPD" "$ORCHID_BIN" run boundary show 2>/dev/null || true)"
assert_match "orchid task retry" "$CBOUNDARY" \
  "the recorded boundary names the verb that grants more rounds (record: $CBOUNDARY)"
assert_match "orchid task reverify" "$CBOUNDARY" \
  "and the one that re-runs verification without spending any, so the operator is never left guessing which verbs exist (record: $CBOUNDARY)"
# Part T -- a launch that FAILS is a job failure (T027, dogfood F29).
#
# The launcher does real work before its spawn line: it prepares the job, then
# builds the input pack. A pack that overflows `pack_budget_bytes` fails the
# launch (exit 12, `input_overflow`) with no engine ever started -- so there is
# no job for `jobs check` to call dead, no envelope for `reconcile` to mark the
# engine with, and the escalation ladder (which triggers on dead/stalled/
# timeout) never engaged. A real run re-attempted the identical broken launch
# once per pass for 73 passes and produced: 73 pid-0 manifests, no logs, a
# `jobs check` reporting them all `prepared`, an `orchid status` showing the
# engine fine, and not one journal entry mentioning a failure.
#
# Three properties, in the order they failed: the failure is journaled and
# spends a rung; the manifests do not pile up; and the ladder reaches its cap
# and BLOCKS instead of retrying forever.
# ===========================================================================
OVF="$WORK/overflow"
mkdir -p "$OVF"
cd "$OVF" || exit 1
git init -q .
# pack_budget_bytes=1 makes every pack overflow on its non-truncatable task.md
# alone -- the same exit 12 the real incident hit, with no fixture engine
# needed to fake it. infra_max=2 so the cap is reached inside this test's
# passes rather than the default 3.
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\npack_budget_bytes=1\ninfra_max=2\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$OVF" "$ORCHID_BIN" init >/dev/null || fail "orchid init (launch-failure fixture)"
git checkout -q orchid/integration
OEPOCH="$(ORCHID_REPO="$OVF" "$ORCHID_BIN" run start | sed 's/epoch: //')"
oorchid() { ORCHID_REPO="$OVF" ORCHID_EPOCH="$OEPOCH" "$ORCHID_BIN" "$@"; }
oorchid requirements import "$WORK/requirements.md" >/dev/null
oorchid task create O010 "its launcher cannot build a pack" >/dev/null
oorchid task set O010 verification_commands "true" >/dev/null
oorchid plan apply --reason "initial plan" >/dev/null

ODRIVE_RC=0; ODRIVE_OUT=""
run_odrive() {
  ODRIVE_RC=0
  ODRIVE_OUT="$(ORCHID_REPO="$OVF" ORCHID_EPOCH="$OEPOCH" "$DRIVE" 2>&1)" || ODRIVE_RC=$?
}
ofield() { ORCHID_REPO="$OVF" "$ORCHID_BIN" task show O010 | grep "^$1: " | cut -d' ' -f2-; }
omanifests() { list_dir_files "$OVF/.orchid/runtime/jobs" | wc -l | tr -d ' '; }

run_odrive
assert_match "input_overflow" "$ODRIVE_OUT" "the launcher's own diagnostic reaches the pass output"
assert_eq 1 "$(ofield infra_failures)" \
  "a launcher that exits non-zero without spawning is a JOB FAILURE and spends a rung (rc=$ODRIVE_RC, out: $ODRIVE_OUT)"
assert_match "the launcher exited 12 without spawning a job" "$(cat "$OVF/.orchid/journal.md")" \
  "and it is JOURNALED, with the exit code — nothing recorded this at all before"
assert_eq pending "$(ofield status)" \
  "the task is not advanced behind a job that never spawned"
assert_eq 16 "$ODRIVE_RC" "the pass stops at a boundary rather than exiting 0 as if all were well"

# A second pass must not mint a second manifest for the same slot. This is the
# property that turned one broken launch into 74 files deleted by hand.
run_odrive
assert_eq 1 "$(omanifests)" \
  "the same failing dispatch leaves ONE unlaunched manifest, not one per pass (out: $ODRIVE_OUT)"
assert_eq 1 "$(ofield infra_failures)" \
  "and the refusal to re-prepare is a WAIT — it does not spend a second rung on the same orphan"

# The ladder still converges. Aged past the bound, the orphan is reaped, the
# dispatch is retried, IT fails the same way, and the cap blocks the task
# instead of retrying it forever.
touch -t 202001010000 "$OVF/.orchid/runtime/jobs"/*.json
run_odrive
assert_eq blocked "$(ofield status)" \
  "at infra_max the task is BLOCKED — the run stops asking for the same broken launch (rc=$ODRIVE_RC, out: $ODRIVE_OUT)"
assert_eq 16 "$ODRIVE_RC" "and the pass hands off at a boundary"

# ...AND EVERY RUNG IT SPENT BELONGS TO A LAUNCH THAT REALLY WAS ATTEMPTED.
#
# One physical launch failure must cost exactly one rung. Two arms can reach
# this slot: drive_launch, which has the launcher's non-zero exit in hand, and
# the ageing sweep, which finds the manifest that failure stranded some passes
# later. Both fire on the same event, and the second one has no event of its
# own -- it is reading a corpse.
#
# Every launch-failure rung carries a receipt naming the job it was charged
# for (`[ladder job <job_id>]`), and the sweep refuses to charge a manifest whose
# receipt is already on record -- so the ladder counts LAUNCHES here, and both
# entries in the journal name the launcher's own exit code. Part W owns the
# other half of this predicate: what happens when there is NO receipt because
# the pass that should have written one died first.
#
# TWO DIFFERENT REDs sit under this assertion, and they are not the same kind
# of claim:
#
#   * AT THE PARENT, the count is 0, not 2 -- nothing charged a rung for a
#     launch that failed before its spawn line, and nothing journaled it. That
#     is the dogfood defect (F29) and the reason this whole Part exists.
#   * AT AN EARLIER T027 ATTEMPT, the count was 2 for the WRONG reason: rung 2
#     came from the sweep, worded "prepared and never launched", charged to the
#     ageing of rung 1's corpse -- while this pass's real, second launch failure
#     went uncounted behind drive_escalate's one-rung-per-slot-per-pass guard.
#     Two rungs, one launch attempt. Self-inflicted; only this file ever saw it,
#     and the `prepared and never launched` check below is what pins it dead.
#
# The parent half is what the numeric assertion proves; the wording assertions
# are what separate the two.
assert_eq 2 "$(ofield infra_failures)" \
  "two rungs for two attempted launches (out: $ODRIVE_OUT)"
assert_eq 2 "$(grep -c "the launcher exited 12 without spawning a job" "$OVF/.orchid/journal.md")" \
  "and BOTH are journaled as what they were: a launcher that ran and exited non-zero"
# Straight at the FILE, never `cat | grep -q`: same SIGPIPE/pipefail trap
# helpers.sh documents for assert_match — a matching grep exiting early would
# poison the pipeline status and silently skip this `fail`.
grep -q "prepared and never launched" "$OVF/.orchid/journal.md" \
  && fail "the corpse of an already-reported launch failure must never be charged a second rung"

# ===========================================================================
# Part U -- the exit-18 refusal must not be a state PLANNING cannot leave.
#
# (U, not N: Part N is THE OPERATOR HAND-OFF, far above. Claiming a letter that
# is already taken is not cosmetic -- every later reference to "Part N" in this
# file and in the docs silently acquires a second referent.)
#
# PLANNING runs no reconcile and no check: the plan/critique loop is judgment
# work the orchestrator owns end to end. But it DOES launch jobs -- `plan
# critique` and the plan hook points -- so a launcher that dies before its
# spawn line strands a never-started manifest here too, and `jobs prepare`
# refuses (exit 18) to mint a second one over it.
#
# That is the shape of a trap: the phase that cannot run gc would be the phase
# that can never clear the thing gc clears, and the run would sit in PLANNING
# with the identical critique relaunch refused on every attempt, forever. This
# task exists to stop a failed launch retrying silently forever; replacing that
# with a phase that can never proceed is not a fix.
#
# So: wedge the phase, then prove it gets out on its own.
#
# AND THEN THE HARDER HALF (T027 rework). Getting out is not enough if getting
# out is how the evidence disappears. PLANNING is the one phase whose launchers
# nothing wraps — the orchestrator runs `runners/orchid-launch plan plan_critic
# critique` itself, PROTOCOL.md PLANNING step 2 — so there is no synchronous
# caller to journal a non-zero exit, and a reap that ran before the ladder
# deleted the incident outright. That is F29 verbatim, in the phase the fix had
# not reached. The rest of this Part proves the ordering that closes it:
# swept, journaled with the ladder's receipt, charged where a counter exists,
# and only then reaped — recoverable across a crash, counted exactly once, and
# never relaunched from a phase that dispatches nothing.
# ===========================================================================
PLN="$WORK/planning"
mkdir -p "$PLN"
cd "$PLN" || exit 1
git init -q .
# `role.plan_critic` must name an engine that is actually ELIGIBLE for the
# role, or every `jobs prepare plan plan_critic critique` below dies at
# exit 14 ("no eligible engine available for role plan_critic ... missing
# required capability structured_text") and the exit-18 refusal this Part
# exists to test is never reached at all. roles/plan_critic.role requires
# `structured_text`; of the two stub engines only `stubreview` declares it
# (stubimpl is `workspace_write,shell,git`), so plan_critic binds there.
# Note also that resolve_role_available skips any chain entry equal to the
# ORCHESTRATOR's engine -- an engine never critiques its own plan -- and
# this fixture leaves role.orchestrator unset, so it defaults to `claude`
# and cannot collide with the binding below.
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nrole.plan_critic=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$PLN" "$ORCHID_BIN" init >/dev/null || fail "orchid init (planning fixture)"
git checkout -q orchid/integration
LEPOCH="$(ORCHID_REPO="$PLN" "$ORCHID_BIN" run start | sed 's/epoch: //')"
lorchid() { ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$ORCHID_BIN" "$@"; }
# NO `plan apply` here: run_status stays `planning`, which is the whole point.
assert_eq "planning" "$(grep '^run_status: ' "$PLN/.orchid/roadmap.md" | cut -d' ' -f2)" \
  "the fixture really is in PLANNING (no plan apply)"

# THE WEDGE. Exactly what a critique launch that died before its spawn line
# leaves behind: pid 0, no log. Aged, so no launcher can still be mid-flight.
#
# Its `engine` is deliberately NOT the engine plan_critic now resolves to.
# The refusal is keyed on (task, attempt, role, operation, hook_point) and
# expressly not on engine -- a re-dispatch that merely picked a different
# engine for the same slot is the same job, and the orphan is still the only
# thing needing clearing -- so the mismatch here is the assertion, not an
# oversight: it must still refuse.
PLAN_ORPHAN="$PLN/.orchid/runtime/jobs/j-e1-plan-a1-cafe.json"
mkdir -p "$PLN/.orchid/runtime/jobs"
jq -n '{job_id:"j-e1-plan-a1-cafe", task:"plan", attempt:1, role:"plan_critic",
        operation:"critique", engine:"stubimpl", pid:0, pgid:0, started_at:0,
        log:"'"$PLN"'/.orchid/runtime/logs/j-e1-plan-a1-cafe.log", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$PLAN_ORPHAN"
touch -t 202001010000 "$PLAN_ORPHAN"

lrc=0; lorchid jobs prepare plan plan_critic critique >/dev/null 2>&1 || lrc=$?
assert_eq 18 "$lrc" \
  "the phase IS wedged to begin with: the identical critique relaunch is refused"

# THE ESCAPE. A planning pass runs the never-started reap -- and only that,
# never the dead-job reap, which must not run before a reconcile this phase
# deliberately skips.
LDRIVE_RC=0
LDRIVE_OUT="$(ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || LDRIVE_RC=$?
assert_match "boundary .planning." "$LDRIVE_OUT" \
  "the pass still hands PLANNING back to judgment (rc=$LDRIVE_RC, out: $LDRIVE_OUT)"
assert_match "gc-prepared j-e1-plan-a1-cafe" "$LDRIVE_OUT" \
  "and it reaps the stranded critique manifest, which nothing in PLANNING used to do"
[ ! -f "$PLAN_ORPHAN" ] || fail "the stranded manifest must leave the jobs dir (out: $LDRIVE_OUT)"

# ...AND THE REAP WAS PRECEDED BY AN ACCOUNT. This is the half F29 is actually
# about, and PLANNING kept exactly the shape the finding describes right up to
# this rework. A launcher that could not run left nothing at all behind — which
# is how 73 identical launch failures produced not one journal line.
#
# RED, and checkable by hand rather than asserted: at candidate 4493cb5
# runners/orchid-drive reaped in the PLANNING pre-pass (its `run_status =
# planning` block, above both the sweep and the ladder), collected escalations
# only under `run_status != planning`, and skipped the reserved `plan` id
# outright in the ladder loop (`[ "$_etask" != plan ] || continue`). Three
# independent reasons there is no journal entry to find, any one of them enough
# on its own. `git show 4493cb5:runners/orchid-drive` shows all three.
#
# The receipt is the durable, exactly-once one the ladder writes; the prose is
# what a human reads. Both, or the entry is either unfindable or uninformative.
#
# grep -qF STRAIGHT AT THE FILE, not assert_match: `[ladder job ...]` is a
# character class to grep -E, and a pipe would hit the SIGPIPE/pipefail trap
# helpers.sh documents.
PLAN_JOURNAL="$PLN/.orchid/journal.md"
grep -qF "[ladder job j-e1-plan-a1-cafe]" "$PLAN_JOURNAL" \
  || fail "a PLANNING launch failure must be journaled with the ladder's receipt before its manifest is reaped (out: $LDRIVE_OUT)"
grep -qF "prepared and never launched" "$PLAN_JOURNAL" \
  || fail "...and the entry must say what actually happened to the job"
# THE RESERVED PLAN ID, where no task counter exists. `orchid task create plan`
# is refused outright, so there is nothing to charge — the failure is journaled
# instead, and journaling it must not conjure a task file that would then
# shadow every plan-scoped manifest.
[ ! -f "$PLN/.orchid/tasks/plan.md" ] \
  || fail "the reserved plan id must never acquire a task file"
grep -qF "prepared and never launched" "$PLN/.orchid/runtime/journal-index/plan" \
  || fail "the plan-scoped failure must be readable via 'orchid journal show --task plan'"
# Journaled, not relaunched: PLANNING dispatches nothing, and the ladder must
# not be the one thing in the pass that spawns an engine.
ls "$PLN/.orchid/runtime/jobs"/*.json >/dev/null 2>&1 \
  && fail "the PLANNING ladder must not relaunch — the jobs dir must be empty after the reap"

lrc=0; PLAN_M="$(lorchid jobs prepare plan plan_critic critique)" || lrc=$?
assert_eq 0 "$lrc" \
  "and the phase is out: the identical relaunch now succeeds, with no operator action"
[ -f "$PLAN_M" ] || fail "the critique manifest must really have been minted"

# The bound still holds in PLANNING, for the same reason it holds everywhere
# the driver reaps: the manifest just minted is seconds old and may have a
# launcher mid-flight over it. A planning pass must not reap THAT one out from
# under the launch. (The bound is the PASS's, passed to the verb -- an operator
# typing `--older-than-s 0` gets 0; see tests/test_jobs.sh.)
LDRIVE_OUT="$(ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || true
# Herestring, never `echo | grep -q`: same SIGPIPE/pipefail trap helpers.sh
# documents for assert_match — a matching grep exiting early would poison the
# pipeline status and silently skip this `fail`.
grep -q "gc-prepared" <<<"$LDRIVE_OUT" \
  && fail "a planning pass must not reap a manifest younger than stall_minutes (out: $LDRIVE_OUT)"
[ -f "$PLAN_M" ] || fail "the fresh critique manifest must survive the pass"

# CRASH RECOVERY, between the launch failure and the accounting for it.
# `runners/orchid-launch` stamps `launch_exit` on the manifest it strands, and
# in PLANNING nobody is standing there to read it: the orchestrator runs the
# launcher itself, so the synchronous half of the accounting does not exist in
# this phase at all. Whatever happens next -- the pump's lease is fenced, the
# machine reboots, the operator Ctrl-Cs -- the exit status is on disk and
# nothing has counted it.
#
# What must survive that is BOTH facts: the failure is on the record, AND it
# says what the launcher actually did. Reporting this one as "prepared and
# never launched" would throw away the single most useful thing the incident
# left behind.
PLAN_CRASH="$PLN/.orchid/runtime/jobs/j-e1-plan-a1-beef.json"
jq -n '{job_id:"j-e1-plan-a1-beef", task:"plan", attempt:1, role:"plan_critic",
        operation:"critique", engine:"stubreview", pid:0, pgid:0, started_at:0,
        launch_exit:3,
        log:"'"$PLN"'/.orchid/runtime/logs/j-e1-plan-a1-beef.log", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$PLAN_CRASH"
touch -t 202001010000 "$PLAN_CRASH"
LDRIVE_OUT="$(ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || true
grep -qF "[ladder job j-e1-plan-a1-beef]" "$PLAN_JOURNAL" \
  || fail "a PLANNING launch failure whose synchronous charge never landed must be counted by the sweep (out: $LDRIVE_OUT)"
grep -qF "the launcher exited 3 without spawning a job" "$PLAN_JOURNAL" \
  || fail "...and the stamped exit status is what the entry must report"
[ ! -f "$PLAN_CRASH" ] || fail "...and only then is the manifest reaped (out: $LDRIVE_OUT)"

# THE OTHER SIDE OF THAT WINDOW: exactly once. A charge that DID land leaves
# the ladder's receipt in the journal, and the sweep meeting the corpse of that
# same failure some passes later must not write it down a second time -- while
# still reaping the manifest, which is what stops it being met again forever.
#
# The receipt is seeded here exactly as a charge writes it, because in this
# phase there is no drive_launch to write it for real.
PLAN_DUP="$PLN/.orchid/runtime/jobs/j-e1-plan-a1-d0d0.json"
lorchid journal add --task plan \
  "the launcher exited 3 without spawning a job (role plan_critic, operation critique) [ladder job j-e1-plan-a1-d0d0]" >/dev/null
jq -n '{job_id:"j-e1-plan-a1-d0d0", task:"plan", attempt:1, role:"plan_critic",
        operation:"critique", engine:"stubreview", pid:0, pgid:0, started_at:0,
        launch_exit:3,
        log:"'"$PLN"'/.orchid/runtime/logs/j-e1-plan-a1-d0d0.log", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$PLAN_DUP"
touch -t 202001010000 "$PLAN_DUP"
LDRIVE_OUT="$(ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || true
assert_eq 1 "$(grep -cF "[ladder job j-e1-plan-a1-d0d0]" "$PLAN_JOURNAL")" \
  "one physical launch failure is journaled exactly once, whichever arm got to it first (out: $LDRIVE_OUT)"
[ ! -f "$PLAN_DUP" ] || fail "an already-counted failure is still reaped (out: $LDRIVE_OUT)"

# THE SWEEP AND THE REAP MUST COVER THE SAME SET. PLANNING's reap is `jobs gc
# --reap-prepared`, which retires libexec/orchid-jobs' job_unlaunched_reapable
# — BOTH halves of the pid-0 class, the never-started one above and this one: a
# manifest whose engine was spawned but never stamped a pid, whose log has then
# been silent for `stall_minutes`. Sweeping only the first half would put the
# phase straight back to retiring something it had never counted.
PLAN_UNS="$PLN/.orchid/runtime/jobs/j-e1-plan-a1-0ff0.json"
PLAN_UNS_LOG="$PLN/.orchid/runtime/logs/j-e1-plan-a1-0ff0.log"
mkdir -p "$PLN/.orchid/runtime/logs"
echo "engine started, then went quiet" > "$PLAN_UNS_LOG"
touch -t 202001010000 "$PLAN_UNS_LOG"
jq -n '{job_id:"j-e1-plan-a1-0ff0", task:"plan", attempt:1, role:"plan_critic",
        operation:"critique", engine:"stubreview", pid:0, pgid:0, started_at:0,
        log:"'"$PLAN_UNS_LOG"'", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$PLAN_UNS"
touch -t 202001010000 "$PLAN_UNS"
LDRIVE_OUT="$(ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || true
grep -qF "[ladder job j-e1-plan-a1-0ff0]" "$PLAN_JOURNAL" \
  || fail "PLANNING must also account for the class its reap retires with a log attached (out: $LDRIVE_OUT)"
grep -qF "spawned but never recorded a pid" "$PLAN_JOURNAL" \
  || fail "...and name that shape rather than the never-started one"
[ ! -f "$PLAN_UNS" ] || fail "...and the reap still retires it in the same pass (out: $LDRIVE_OUT)"
[ -f "$PLAN_UNS_LOG" ] || fail "...keeping the log, which is the only evidence a never-stamped job leaves"

# A TASK-OWNED manifest stranded during PLANNING. Tasks exist in this phase --
# `orchid task create` is how the roadmap gets drafted, well before `plan
# apply` -- so a stranded manifest here can have a real infra_failures counter
# behind it, unlike the reserved `plan` id above.
#
# It is CHARGED (the counter is the point of having one) and it is NOT
# RELAUNCHED: PLANNING dispatches nothing, the walk does not run, and a
# relaunch from the ladder would be the only thing in the whole pass that
# spawned an engine. The reap is what leaves the orchestrator free to launch it
# itself when the plan loop is ready.
lorchid task create P010 "drafted during planning, before plan apply" >/dev/null
PLAN_TASK_M="$PLN/.orchid/runtime/jobs/j-e1-P010-a1-0001.json"
jq -n '{job_id:"j-e1-P010-a1-0001", task:"P010", attempt:1, role:"implementer",
        operation:"implement", engine:"stubimpl", pid:0, pgid:0, started_at:0,
        log:"'"$PLN"'/.orchid/runtime/logs/j-e1-P010-a1-0001.log", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$PLAN_TASK_M"
touch -t 202001010000 "$PLAN_TASK_M"
LDRIVE_OUT="$(ORCHID_REPO="$PLN" ORCHID_EPOCH="$LEPOCH" "$DRIVE" 2>&1)" || true
assert_eq 1 "$(fm_get "$PLN/.orchid/tasks/P010.md" infra_failures)" \
  "a task-owned launch failure in PLANNING spends its rung like any other (out: $LDRIVE_OUT)"
grep -qF "[ladder job j-e1-P010-a1-0001]" "$PLAN_JOURNAL" \
  || fail "...and carries the ladder's receipt, so it is counted exactly once"
assert_match "not relaunching during PLANNING" "$LDRIVE_OUT" \
  "...and the ladder says why it is not relaunching in this phase"
[ ! -f "$PLAN_TASK_M" ] || fail "...and the manifest is reaped after the charge, not before it"
ls "$PLN/.orchid/runtime/jobs"/j-*-P010-*.json >/dev/null 2>&1 \
  && fail "PLANNING must not relaunch a task job — the phase dispatches nothing (out: $LDRIVE_OUT)"

# ===========================================================================
# Part V -- pid 0 WITH A LOG: wait on it, then CONVERGE on it (T027 rework).
#
# Parts J and T are about the pid-0 manifest with no log: the spawn line was
# never reached, so nothing is running and relaunching over it is safe. This
# Part is the other half of that class, and it had the opposite defect --
# not "retried silently forever" but "retained silently forever, while a
# duplicate engine was launched over it anyway".
#
# The launcher creates the log by redirecting the spawn into it and stamps the
# pid only on the line after, so pid 0 WITH a log means an engine was started
# and its pid was recorded nowhere. Everything that reaps or escalates
# deliberately left that manifest alone at every age -- and drive_job_outstanding
# read the very same manifest as "no job" and let the next pass launch a second
# engine into the same worktree. The manifest was kept as the only handle on a
# process, and the keeping bought nothing.
#
# Both halves, in order: the pass must WAIT while that log is being written
# (no duplicate), and the wait must END when it stops (no forever).
# ===========================================================================
UNS="$WORK/unstamped"
mkdir -p "$UNS"
cd "$UNS" || exit 1
git init -q .
# stall_minutes=1 -- a 60s silence bound this fixture can straddle with a
# `touch`, instead of the 10 minutes the default would make it wait for.
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nstall_minutes=1\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$UNS" "$ORCHID_BIN" init >/dev/null || fail "orchid init (unstamped fixture)"
git checkout -q orchid/integration
UEPOCH="$(ORCHID_REPO="$UNS" "$ORCHID_BIN" run start | sed 's/epoch: //')"
uorchid() { ORCHID_REPO="$UNS" ORCHID_EPOCH="$UEPOCH" "$ORCHID_BIN" "$@"; }
uorchid requirements import "$WORK/requirements.md" >/dev/null
uorchid task create V010 "its launcher was killed between the spawn and the pid stamp" >/dev/null
uorchid task set V010 verification_commands "true" >/dev/null
uorchid plan apply --reason "initial plan" >/dev/null

UDRIVE_RC=0; UDRIVE_OUT=""
run_udrive() {
  UDRIVE_RC=0
  UDRIVE_OUT="$(ORCHID_REPO="$UNS" ORCHID_EPOCH="$UEPOCH" "$DRIVE" 2>&1)" || UDRIVE_RC=$?
}
ufield() { ORCHID_REPO="$UNS" "$ORCHID_BIN" task show V010 | grep "^$1: " | cut -d' ' -f2-; }
umanifests() { list_dir_files "$UNS/.orchid/runtime/jobs" | wc -l | tr -d ' '; }

# Exactly what a launcher killed inside its own sub-second post-spawn window
# leaves: pid 0, pgid 0, started_at 0 -- and a log, because the redirection
# that creates it happens before the stamp that does not.
UORPHAN="$UNS/.orchid/runtime/jobs/j-e1-V010-a1-abcd0001.json"
ULOG="$UNS/.orchid/runtime/logs/j-e1-V010-a1-abcd0001.log"
mkdir -p "$UNS/.orchid/runtime/jobs" "$UNS/.orchid/runtime/logs"
jq -n '{job_id:"j-e1-V010-a1-abcd0001", task:"V010", attempt:1, role:"implementer",
        operation:"implement", engine:"stubimpl", pid:0, pgid:0, started_at:0,
        log:"'"$ULOG"'", output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$UORPHAN"
printf 'engine is talking\n' > "$ULOG"

# ---- half one: the WAIT. The log was written a moment ago, so something is
# producing output for this job and the pass must defer to it.
run_udrive
assert_eq 1 "$(umanifests)" \
  "a pid-0 manifest whose log is still being written must not have a SECOND engine launched over it (rc=$UDRIVE_RC, out: $UDRIVE_OUT)"
[ -f "$UORPHAN" ] || fail "and the manifest — the only handle on that process — must survive the pass"
assert_match "adopting the implement job" "$UDRIVE_OUT" \
  "the pass adopts the spawn that demonstrably happened rather than racing it"
assert_eq implementing "$(ufield status)" \
  "and the task advances behind the job that IS running, not behind a second one"
assert_eq 0 "$(ufield infra_failures)" \
  "waiting on a live job spends no rung of the escalation ladder"

# ---- half two: the CONVERGENCE. Nothing has written to that log for longer
# than `stall_minutes` -- the same silence `jobs check` kills a STAMPED job
# for. There is no pid to signal here, so the weaker consequence is the whole
# consequence: report it, spend one rung, retire the manifest, keep the log.
#
# RED at the parent: `prepared` forever, escalated by nothing, and skipped by
# the ordinary `gc` the driver itself calls at every bound, so the slot stayed
# held open for the rest of the run. (An operator invoking `--reap-prepared`
# by hand could clear it there — on pid 0 alone, log growing or not — but the
# unattended pass never did, and that is the arm this Part drives.)
touch -t 202001010000 "$UORPHAN" "$ULOG"
run_udrive
assert_match "V010[[:space:]]+unstamped" "$UDRIVE_OUT" \
  "a spawn that never stamped a pid and then went silent is REPORTED (rc=$UDRIVE_RC, out: $UDRIVE_OUT)"
assert_match "gc-unstamped j-e1-V010-a1-abcd0001" "$UDRIVE_OUT" \
  "and the manifest is retired under its own reason, not left for an operator to find next run"
[ ! -f "$UORPHAN" ] || fail "the stale unstamped manifest must leave the jobs dir (out: $UDRIVE_OUT)"
[ -f "$UNS/.orchid/runtime/quarantine/j-e1-V010-a1-abcd0001.json.reason-gc-unstamped" ] \
  || fail "quarantined, never silently deleted (out: $UDRIVE_OUT)"
assert_eq 1 "$(ufield infra_failures)" \
  "it spends exactly one rung — a job that produced no envelope is what the ladder is for (out: $UDRIVE_OUT)"
assert_match "never recorded a pid" "$(cat "$UNS/.orchid/journal.md")" \
  "and it is JOURNALED, saying which of the ways-without-an-envelope this was"
# THE LOG OUTLIVES THE HANDLE. No pid was ever recorded, so nothing could be
# signalled: if an engine really is alive behind that manifest, its output is
# the only evidence anyone will ever have of it.
[ -f "$ULOG" ] \
  || fail "the reap must keep an unstamped job's log — unlike the dead-job reap, nothing here was ever killable"

# ===========================================================================
# Part W -- THE CRASH WINDOW. One physical launch failure is charged exactly
# once: never twice, and NEVER ZERO TIMES (T027 rework).
#
# Part T pins the ordinary case: drive_launch has the launcher's non-zero exit
# in hand, charges a rung for it, and the ageing sweep that meets the stranded
# manifest some passes later does not charge a second one. What decided that
# used to be a MARK the launcher writes on the manifest (`launch_exit`) -- and
# the launcher writes it BEFORE this driver has journaled or charged anything.
#
# So there is a window. A pass felled inside it -- the machine reboots, a
# second pump fences a fresh epoch, an operator hits Ctrl-C between the
# launcher's exit and `orchid task infra-fail` -- leaves a manifest asserting
# "already reported" about a failure nobody ever reported. A sweep keyed on
# that mark then skips it on every pass until gc quietly retires the only
# evidence of it: no rung, no journal entry, nothing. That is the same silence
# this whole task exists to end, one level up from where it was found.
#
# The mark cannot be made to answer this. Written before the charge it loses
# the failure; written after it, a crash in the new window pays for the same
# event twice. Two non-atomic writes are not made exactly-once by ordering
# them -- so "has this been counted" is asked of the receipt the CHARGE itself
# wrote: `orchid task infra-fail` is journal-first, and every launch-failure
# rung's reason carries `[ladder job <job_id>]`.
#
# Three passes, one fixture, and both directions of the same predicate.
# ===========================================================================
CW="$WORK/crashwindow"
mkdir -p "$CW"
cd "$CW" || exit 1
git init -q .
# stall_minutes=1 so an aged manifest is one `touch` away; infra_max=9 so the
# cap never fires and every rung this Part counts stays legible as a number.
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nstall_minutes=1\ninfra_max=9\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CW" "$ORCHID_BIN" init >/dev/null || fail "orchid init (crash-window fixture)"
git checkout -q orchid/integration
WEPOCH="$(ORCHID_REPO="$CW" "$ORCHID_BIN" run start | sed 's/epoch: //')"
worchid() { ORCHID_REPO="$CW" ORCHID_EPOCH="$WEPOCH" "$ORCHID_BIN" "$@"; }
worchid requirements import "$WORK/requirements.md" >/dev/null
worchid task create W010 "a pass died between the launcher's exit and the charge" >/dev/null
worchid task set W010 verification_commands "true" >/dev/null
worchid plan apply --reason "initial plan" >/dev/null
# BLOCKED on purpose, and that is fixture rather than subject: the walk takes
# no dispatch edge out of `blocked`, so every rung this Part counts comes from
# the escalation ladder and from nothing else.
worchid task advance W010 blocked --reason "fixture: parked so the walk launches nothing" >/dev/null

WDRIVE_RC=0; WDRIVE_OUT=""
run_wdrive() {
  WDRIVE_RC=0
  WDRIVE_OUT="$(ORCHID_REPO="$CW" ORCHID_EPOCH="$WEPOCH" "$DRIVE" 2>&1)" || WDRIVE_RC=$?
}
wfield() { ORCHID_REPO="$CW" "$ORCHID_BIN" task show W010 | grep "^$1: " | cut -d' ' -f2-; }
WJOURNAL="$CW/.orchid/journal.md"
# Straight at the FILE, and -F: the receipt is bracketed, so a regex reader
# (assert_match uses grep -E) would read `[ladder job ...]` as a character class
# and match on any single letter in it. Counted with -c, so what is asserted is
# "exactly one" rather than "at least one". The token is spelled out here rather
# than taken from drive_failure_receipt on purpose: a test that builds its
# expectation with the function under test would pass on any format the two of
# them happened to agree on, including one no reader ever matches.
wreceipts() { grep -cF -e "[ladder job $1]" "$WJOURNAL" 2>/dev/null || true; }

mkdir -p "$CW/.orchid/runtime/jobs"
mk_stranded() {  # <job-id> [launch-exit] -- the manifest a launcher stranded
  local jid="$1" lexit="${2:-}" f
  f="$CW/.orchid/runtime/jobs/$jid.json"
  if [ -n "$lexit" ]; then
    jq -n --arg jid "$jid" --arg log "$CW/.orchid/runtime/logs/$jid.log" --argjson lexit "$lexit" \
      '{job_id:$jid, task:"W010", attempt:1, role:"implementer", operation:"implement",
        engine:"stubimpl", pid:0, pgid:0, started_at:0, log:$log, output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:"", launch_exit:$lexit}' > "$f"
  else
    jq -n --arg jid "$jid" --arg log "$CW/.orchid/runtime/logs/$jid.log" \
      '{job_id:$jid, task:"W010", attempt:1, role:"implementer", operation:"implement",
        engine:"stubimpl", pid:0, pgid:0, started_at:0, log:$log, output:"/dev/null",
        base_sha:"", candidate_sha:"", hook_point:""}' > "$f"
  fi
  touch -t 202001010000 "$f"
}

# ---- pass 1: THE CRASH ITSELF. `launch_exit` is on the manifest, so a
# launcher really did run and really did fail -- and the journal holds no
# receipt for it, so the charge that mark was supposed to stand for never
# landed.
#
# RED at the parent: there is no sweep, no `launch_exit` mark and no charge of
# any kind — a launcher that failed before its spawn line was invisible end to
# end, which is the dogfood finding itself.
#
# RED at an earlier T027 attempt, and the reason this Part exists as its own
# fixture: the sweep skipped every manifest carrying the mark, so this pass
# charged nothing and journaled nothing, and the failure stayed invisible until
# gc retired the manifest it was written on. Self-inflicted; the fix is that
# the receipt, not the mark, is what deduplicates.
mk_stranded j-e1-W010-a1-c0ffee01 12
run_wdrive
assert_eq 1 "$(wfield infra_failures)" \
  "a launch failure whose synchronous charge never landed is still counted — the mark is not a receipt (rc=$WDRIVE_RC, out: $WDRIVE_OUT)"
assert_eq 1 "$(wreceipts j-e1-W010-a1-c0ffee01)" \
  "and the charge writes its own receipt, keyed on the job that failure stranded"
grep -qF -e "the launcher exited 12 without spawning a job" "$WJOURNAL" \
  || fail "the sweep journals the launcher's OWN exit status, not 'prepared and never launched' — that exit code is the only diagnostic the incident left (out: $WDRIVE_OUT)"
[ ! -f "$CW/.orchid/runtime/jobs/j-e1-W010-a1-c0ffee01.json" ] \
  || fail "the manifest is retired once it has been charged (out: $WDRIVE_OUT)"

# ---- pass 2: THE OTHER DIRECTION. The same job, the same manifest shape, and
# now a receipt on record for it. Nothing may be charged again.
#
# This is the window the reap ordering opens on purpose: the ladder spends its
# rungs BEFORE gc retires anything, so that a pass felled in between loses no
# evidence -- which means a manifest can outlive its own charge. It must then
# be recognised, and only the receipt can recognise it: `launch_exit` is
# identical on this pass and the last.
mk_stranded j-e1-W010-a1-c0ffee01 12
run_wdrive
assert_eq 1 "$(wfield infra_failures)" \
  "a failure already on the ladder's record is not charged again (rc=$WDRIVE_RC, out: $WDRIVE_OUT)"
assert_eq 1 "$(wreceipts j-e1-W010-a1-c0ffee01)" \
  "and no second receipt is written for it either — one event, one entry"
assert_match "already on the ladder's record" "$WDRIVE_OUT" \
  "the pass says why it is not counting it, rather than skipping in silence (out: $WDRIVE_OUT)"

# ---- pass 3: THE DEDUP IS KEYED ON THE JOB, never on the task or the slot. A
# DIFFERENT stranded launch is a different failure and gets its own rung --
# otherwise "never twice" would have been bought by never counting anything
# after the first, which is the defect this Part opened with.
mk_stranded j-e1-W010-a1-c0ffee02
run_wdrive
assert_eq 2 "$(wfield infra_failures)" \
  "a second, distinct stranded job is a second rung (rc=$WDRIVE_RC, out: $WDRIVE_OUT)"
assert_eq 1 "$(wreceipts j-e1-W010-a1-c0ffee02)" \
  "with a receipt of its own"
grep -qF -e "prepared and never launched" "$WJOURNAL" \
  || fail "an orphan carrying no exit status is still the never-started class, and still says so (out: $WDRIVE_OUT)"

# ---- and the predicate itself, both ways, with no fixture in the loop.
drive_failure_charged "$CW" j-e1-W010-a1-c0ffee01 \
  || fail "drive_failure_charged must find a receipt that is on record"
drive_failure_charged "$CW" j-e1-W010-a1-nosuchjob \
  && fail "and must not invent one for a job that was never charged"
drive_failure_charged "$CW" "" \
  && fail "an empty key is not a receipt — a caller with no job to name must never read as already charged"

# ===========================================================================
# Part X -- AN OPTIONAL HANDLER THAT CANNOT BE LAUNCHED GATES NOTHING EITHER
# (T027 rework).
#
# `optional never gates` has two shapes and the kernel handled one of them. A
# handler that SPAWNED and then died leaving no envelope is recorded by the
# escalation sweep in a pass-local fact, and drive_hook_gate reads that fact
# and steps over the point. A handler whose LAUNCHER failed -- the same
# `input_overflow` pack, the same unresolvable binary this task exists for --
# was journaled and correctly exempted from the ladder, and then recorded
# nowhere at all.
#
# So the gate saw a point with no envelope and no reason to step over it,
# deferred the step it guards "to the next pass", and the next pass ran the
# identical broken launch to reach the identical conclusion. For a launcher
# that is broken rather than unlucky, that is not a deferral, it is a park: an
# `optional` binding holding a transition for as long as the breakage lasts.
#
# on_verify_fail is the sharpest of the five points to prove it on, because
# drive_testing takes NO edge unless the gate returns satisfied -- a task whose
# suite failed simply never reaches `rework`.
# ===========================================================================
OPT="$WORK/opthook"
mkdir -p "$OPT"
cd "$OPT" || exit 1
git init -q .
# pack_budget_bytes=1 fails every launch at pack_build (exit 12, the incident's
# own code) with no fixture engine needed to fake it -- including the hook
# job's. `hook.on_verify_fail=stubimpl` with no `:required` suffix is the
# optional binding under test.
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\npack_budget_bytes=1\nhook.on_verify_fail=stubimpl\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$OPT" "$ORCHID_BIN" init >/dev/null || fail "orchid init (optional-hook fixture)"
git checkout -q orchid/integration
XEPOCH="$(ORCHID_REPO="$OPT" "$ORCHID_BIN" run start | sed 's/epoch: //')"
xorchid() { ORCHID_REPO="$OPT" ORCHID_EPOCH="$XEPOCH" "$ORCHID_BIN" "$@"; }
xorchid requirements import "$WORK/requirements.md" >/dev/null
xorchid task create X010 "its suite fails and its on_verify_fail handler cannot be launched" >/dev/null
xorchid task set X010 verification_commands "exit 1" >/dev/null
xorchid plan apply --reason "initial plan" >/dev/null

XTASK="$OPT/.orchid/tasks/X010.md"
XCAND="$(git -C "$OPT" rev-parse HEAD)"
fm_set "$XTASK" base_sha "$XCAND"
fm_set "$XTASK" candidate_sha "$XCAND"
fm_set "$XTASK" status testing
xfield() { fm_get "$XTASK" "$1"; }

XDRIVE_RC=0
XDRIVE_OUT="$(ORCHID_REPO="$OPT" ORCHID_EPOCH="$XEPOCH" "$DRIVE" 2>&1)" || XDRIVE_RC=$?

# RED at the parent: `testing`, on this pass and on every pass after it. The
# parent's step-over arm keys on `optional_hooks_died`, which is set only where
# a hook job was LAUNCHED and then died without an envelope — a handler whose
# launcher never reached its spawn line leaves no job to die, so it reached no
# arm at all and the point was simply re-dispatched every pass.
assert_eq rework "$(xfield status)" \
  "the step an OPTIONAL point guards is taken in the same pass its handler fails to launch — a deferral here is a park (rc=$XDRIVE_RC, out: $XDRIVE_OUT)"
assert_match "could not be launched — stepping over it" "$XDRIVE_OUT" \
  "and the pass names it as a step-over, the same wording the died-handler arm uses (out: $XDRIVE_OUT)"
grep -qF -e "optional on_verify_fail hook launch failed (exit 12)" "$OPT/.orchid/journal.md" \
  || fail "stepping over it is not forgetting it: the launch failure is still journaled (out: $XDRIVE_OUT)"
assert_eq 0 "$(xfield infra_failures)" \
  "an optional binding gates nothing, so its handler's launch failure spends none of the TASK's budget (out: $XDRIVE_OUT)"
case "$XDRIVE_OUT" in
  *"deferring the step it guards"*)
    fail "nothing was dispatched, so there is nothing to wait for — deferring is what parked the transition (out: $XDRIVE_OUT)" ;;
esac

# ...AND THAT ENTRY CARRIES THE LADDER'S RECEIPT, even though no rung is spent.
# The exempt class needs the exactly-once key more than the charged one, not
# less: nothing else about an optional handler's collapse is durable, and the
# ageing sweep will meet the very same manifest again some passes later. Without
# a shared key the two arms write the same event down twice — a journal that
# reports a failure count nobody had.
grep -qE "optional on_verify_fail hook launch failed \(exit 12\).*\[ladder job j-" \
  "$OPT/.orchid/journal.md" \
  || fail "an exempt launch failure must still be keyed by the manifest it stranded (out: $XDRIVE_OUT)"

# So: age that manifest into the sweep's reach and prove the second arm holds
# its tongue while still retiring it. This is the same crash-window the charged
# path is careful about, on the path that spends nothing — and the manifest
# really does have to go, or every later pass meets it again.
XHOOK_MF=""
for _xf in "$OPT/.orchid/runtime/jobs"/*.json; do
  [ -e "$_xf" ] || continue
  [ "$(jq -r '.role // ""' "$_xf")" = hook ] || continue
  XHOOK_MF="$_xf"
done
if [ -z "$XHOOK_MF" ]; then
  # Guarded rather than asserted-and-continued: every line below reads a job id
  # off this path, so an empty one turns one honest fixture failure into a page
  # of jq and touch errors that hide it.
  fail "fixture sanity: the failed hook launch must have stranded a manifest to age"
else
  XHOOK_ID="$(jq -r .job_id "$XHOOK_MF")"
  assert_eq 1 "$(grep -cF "[ladder job $XHOOK_ID]" "$OPT/.orchid/journal.md")" \
    "fixture sanity: the synchronous arm wrote exactly one entry for this job"
  touch -t 202001010000 "$XHOOK_MF"
  XDRIVE_OUT="$(ORCHID_REPO="$OPT" ORCHID_EPOCH="$XEPOCH" "$DRIVE" 2>&1)" || true
  assert_eq 1 "$(grep -cF "[ladder job $XHOOK_ID]" "$OPT/.orchid/journal.md")" \
    "the sweep must not write down a failure its launcher already recorded (out: $XDRIVE_OUT)"
  [ ! -f "$XHOOK_MF" ] \
    || fail "...and the manifest is still retired once it is accounted for (out: $XDRIVE_OUT)"
fi

# ===========================================================================
# Part X2 -- A DEFERRED on_verify_fail HOOK MUST NOT ERASE THE FAILED ROUND.
#
# The verifier below is deliberately intermittent: its first invocation fails
# and every later invocation passes. Before the pending-failure receipt, pass 1
# launched the asynchronous hook and returned before classification; pass 2
# ran the verifier again, overwrote FAIL with PASS, and advanced to reviewing.
# The failed round consumed neither budget nor a journal line. The correct
# path runs the verifier ONCE, waits for the hook, then charges and journals the
# original evidence before entering rework.
# ===========================================================================
mkdir -p "$WORK/eng/hookok"
printf 'manifest_version=1\nid=test/hookok\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/hookok/plugin.conf"
cat > "$WORK/eng/hookok/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
cand="$(jq -r '.candidate_sha // ""' "$req")"
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"hook", status:"ok",
    engine:"test/hookok", candidate_sha:$cand,
    artifact:{guidance:"preserve the first failed round"}, summary:"hook ok"}' > "$out"
EOF
chmod +x "$WORK/eng/hookok/run"

PF="$WORK/preserve-failed-verify"
PF_COUNT="$WORK/preserve-failed-verify.count"
PF_SCRIPT="$WORK/preserve-failed-verify.sh"
mkdir -p "$PF"
printf '0\n' > "$PF_COUNT"
cat > "$PF_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -eu
count_file="$1"
n="$(cat "$count_file")"
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
if [ "$n" -eq 1 ]; then
  echo "candidate failed on the first run"
  exit 1
fi
echo "a rerun would pass and erase the first failure"
EOF
chmod +x "$PF_SCRIPT"

cd "$PF" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nhook.on_verify_fail=hookok\n' > orchid.config
git add -A
git commit -q -m "fixture: deferred failure hook"
ORCHID_REPO="$PF" "$ORCHID_BIN" init >/dev/null || fail "orchid init (deferred-failure fixture)"
git checkout -q orchid/integration
PFEPOCH="$(ORCHID_REPO="$PF" "$ORCHID_BIN" run start | sed 's/epoch: //')"
pforchid() { ORCHID_REPO="$PF" ORCHID_EPOCH="$PFEPOCH" "$ORCHID_BIN" "$@"; }
pforchid requirements import "$WORK/requirements.md" >/dev/null
pforchid task create PF1 "its first failed verify must survive an asynchronous hook" >/dev/null
PF_CMD="/bin/bash $(printf '%q' "$PF_SCRIPT") $(printf '%q' "$PF_COUNT")"
pforchid task set PF1 verification_commands "$PF_CMD" >/dev/null
pforchid plan apply --reason "initial plan" >/dev/null
PFSHA="$(git -C "$PF" rev-parse HEAD)"
PFTASK="$PF/.orchid/tasks/PF1.md"
fm_set "$PFTASK" status testing
fm_set "$PFTASK" base_sha "$PFSHA"
fm_set "$PFTASK" candidate_sha "$PFSHA"
fm_set "$PFTASK" worktree "$PF"
pffield() { fm_get "$PFTASK" "$1"; }

PF_RC=0
PF_OUT="$(ORCHID_REPO="$PF" ORCHID_EPOCH="$PFEPOCH" "$DRIVE" 2>&1)" || PF_RC=$?
assert_eq 0 "$PF_RC" "the pass that launches on_verify_fail defers cleanly (out: $PF_OUT)"
assert_eq testing "$(pffield status)" "the hook deferral holds the task in testing"
assert_eq 0 "$(pffield attempts)" "the attempt is not charged before its hook resolves"
assert_eq 1 "$(cat "$PF_COUNT")" "the first pass ran the verifier exactly once"
assert_match "^a1:$PFSHA:[0-9a-f]{64}$" "$(pffield verify_fail_pending)" \
  "and pins that exact failed evidence before returning to the caller"

_pf_i=0
while [ "$_pf_i" -lt 30 ] && [ "$(pffield status)" = testing ]; do
  PF_RC=0
  PF_OUT="$(ORCHID_REPO="$PF" ORCHID_EPOCH="$PFEPOCH" "$DRIVE" 2>&1)" || PF_RC=$?
  [ "$PF_RC" -eq 0 ] || break
  _pf_i=$((_pf_i + 1))
  [ "$(pffield status)" != testing ] || sleep 0.2
done
assert_eq rework "$(pffield status)" \
  "once the hook resolves, the ORIGINAL failed round is classified and sent to rework (rc=$PF_RC, out: $PF_OUT)"
assert_eq 1 "$(cat "$PF_COUNT")" \
  "the resumed failure arm does not run the now-passing verifier a second time"
assert_eq 1 "$(pffield attempts)" "the original candidate failure consumes exactly one attempt"
assert_eq "" "$(pffield verify_fail_pending)" "entry to rework consumes the pending-failure receipt"
assert_eq "preserve the first failed round" "$(pffield hook_guidance)" \
  "the hook guidance still lands before the rework dispatch"
grep -qF "candidate, attempt charged" "$PF/.orchid/journal.md" \
  || fail "the preserved failed round must be journalled as charged (out: $PF_OUT)"

# Part Y -- classify a verification failure BEFORE anything charges it,
# against the policy function itself.
#
# The attempt budget is supposed to measure the CANDIDATE. Every assertion
# below is really one of two claims: a failure the candidate did not cause
# must not spend an attempt, and everything else -- including every case the
# classifier cannot decide -- must. The second half is the one that has to
# hold under pressure, and this part holds the two shapes that decide nothing
# at all: a repository with NO waivable state of any class outstanding, and a
# round with no evidence on disk to read.
# ===========================================================================
CLS="$WORK/classify"
mkdir -p "$CLS/.orchid/tasks" "$CLS/.orchid/reviews"
: > "$CLS/orchid.config"

# mk_cls_task <id> [worktree]
mk_cls_task() {
  printf -- '---\nschema: 1\nid: %s\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\n---\nbody\n' \
    "$1" "${2:-}" > "$CLS/.orchid/tasks/$1.md"
}
# mk_cls_log <id> <output-body> [command] -- a legacy verify log. These strict-
# default fixtures need no waivable prestate; the absence of trusted snapshot
# fields must close those routes rather than falling back to live state.
mk_cls_log() {
  printf 'date: 2026-08-10T00:00:00Z\nsha: deadbeef\ncandidate: deadbeef\ncwd: %s\ncommand: %s\n---\n%s\nexit: 1\n' \
    "$CLS" "${3:-bash tests/run.sh}" "$2" > "$CLS/.orchid/reviews/$1-verify.log"
}

# mk_prestate_log <repo> <task-file> <log> <body> [command] [rc] [snapshot]
# -- a failed verifier log carrying state captured before its command ran.
# Supplying [snapshot] lets a regression capture it, mutate the worktree as a
# hostile test command would, and only then write the final evidence.
mk_prestate_log() {
  local repo="$1" tf="$2" log="$3" body="$4"
  local cmd="${5:-bash tests/run.sh}" rc="${6:-1}" snapshot root cand
  root="$(fm_get "$tf" worktree)"
  [ -n "$root" ] && [ -d "$root" ] || root="$repo"
  cand="$(fm_get "$tf" candidate_sha)"; [ -n "$cand" ] || cand=none
  if [ "$#" -ge 7 ]; then
    snapshot="$7"
  else
    snapshot="$(drive_verify_prestate_headers "$repo" "$tf")"
  fi
  printf 'date: 2026-08-10T00:00:00Z\nsha: %s\ncandidate: %s\ncwd: %s\ncommand: %s\n%s\n---\n%s\nexit: %s\n' \
    "$cand" "$cand" "$root" "$cmd" "$snapshot" "$body" "$rc" > "$log"
}
# HOME is replaced for the call: config_get's third layer is $HOME/.orchid/
# config, and a signature in the operator's own machine-local config must
# never decide what this fixture asserts.
classify() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$CLS" "$CLS/.orchid/tasks/$1.md" "$CLS/.orchid/reviews/$1-verify.log" )
}
class_of()  { classify "$1" | cut -f1; }
reason_of() { classify "$1" | cut -f2-; }

# --- the default is strict: nothing outstanding, so nothing is forgiven ----
# THERE IS NO FAILURE SENTENCE TO DECLARE. Every previous shape of this feature
# offered a per-repository signature list of failure TEXT, and each one forgave
# rounds it never meant to; the fixture's `orchid.config` is empty here and
# stays that way, because a repository cannot buy an amnesty for its own
# failures at any price. (The one file a repository does own is the known-flaky
# register of Part Y5, and what makes that safe is not the file: it is that a
# candidate which TOUCHES it loses the route.)
mk_cls_task C01
mk_cls_log C01 "tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq candidate "$(class_of C01)" \
  "with no waivable state of any class outstanding, a verify failure charges the attempt — forgiveness is never the default"
assert_match "no failure-attributable waivable state was established" "$(reason_of C01)" \
  "and it says what was established before charging, rather than claiming the world contains no missing state it did not attribute"

# The two sentences the earlier text classifiers keyed on, in a tree where
# neither hand-off's state exists. Both charge: no wording is evidence.
mk_cls_task C02
mk_cls_log C02 "tests/test_writes.sh: FAIL: open('/etc/hosts', 'w'): Permission denied"
assert_eq candidate "$(class_of C02)" \
  "a candidate writing where it may not says 'Permission denied' and is still the candidate's — the exec-bit route needs a file whose mode bit is really unset"
mk_cls_task C03
mk_cls_log C03 "pin-formula: Formula/orchid.rb checksum is STALE for the current content"
assert_eq candidate "$(class_of C03)" \
  "and a staleness SENTENCE forgives nothing on its own: this fixture has no pin check to run, so there is no stale-pin state to prove"

# --- no evidence at all is uncertainty, and uncertainty charges -----------
mk_cls_task C07
rm -f "$CLS/.orchid/reviews/C07-verify.log"
assert_eq candidate "$(class_of C07)" \
  "with no verify evidence on disk the failure cannot be classified, so the strict reading applies"
assert_match "cannot be classified" "$(reason_of C07)" \
  "and the absence of evidence is stated, not glossed"

# ===========================================================================
# Part Y2 -- both arms end to end, through the real driver and the real verbs.
#
# This is the acceptance claim in one place: the same pass, two tasks, two
# failing suites, ONE candidate that ships a new verb at mode 644. C300's
# suite fails on the shell refusing that file; C400's fails on an ordinary
# defect while the same mode bit is outstanding. Exactly one of them spends an
# attempt.
# ===========================================================================
CLE="$WORK/classify-e2e"
mkdir -p "$CLE"
cd "$CLE" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CLE" "$ORCHID_BIN" init >/dev/null || fail "orchid init (classification e2e fixture)"
git checkout -q orchid/integration
CEPOCH="$(ORCHID_REPO="$CLE" "$ORCHID_BIN" run start | sed 's/epoch: //')"
ceorchid() { ORCHID_REPO="$CLE" ORCHID_EPOCH="$CEPOCH" "$ORCHID_BIN" "$@"; }
ceorchid requirements import "$WORK/requirements.md" >/dev/null
ceorchid task create C300 "its suite fails on the exec bit the operator has to set" >/dev/null
ceorchid task set C300 verification_commands \
  "echo /bin/bash: libexec/orchid-ce: Permission denied; exit 1" >/dev/null
ceorchid task create C400 "its suite fails on an ordinary defect" >/dev/null
ceorchid task set C400 verification_commands "echo widget returned 3, expected 4; exit 1" >/dev/null
ceorchid plan apply --reason "initial plan" >/dev/null

# The candidate: a new verb shipped mode 644 with a `#!` line, which is the
# exec-bit hand-off's own state on disk and the one thing L017 forbids the
# implementer to clear.
CEBASE="$(git -C "$CLE" rev-parse HEAD)"
mkdir -p "$CLE/libexec"
printf '#!/usr/bin/env bash\necho ce\n' > "$CLE/libexec/orchid-ce"
git -C "$CLE" add libexec/orchid-ce
git -C "$CLE" commit -q -m "fixture: a candidate that ships a new verb at mode 644"
CECAND="$(git -C "$CLE" rev-parse HEAD)"
if [ -x "$CLE/libexec/orchid-ce" ]; then
  fail "fixture invariant broken: libexec/orchid-ce must stay mode 644, or C300 has no hand-off to be waived for"
fi
for _t in C300 C400; do
  fm_set "$CLE/.orchid/tasks/$_t.md" status testing
  fm_set "$CLE/.orchid/tasks/$_t.md" base_sha "$CEBASE"
  fm_set "$CLE/.orchid/tasks/$_t.md" candidate_sha "$CECAND"
done

CE_RC=0
CE_OUT="$(ORCHID_REPO="$CLE" ORCHID_EPOCH="$CEPOCH" "$DRIVE" 2>&1)" || CE_RC=$?
[ "$CE_RC" -eq 0 ] || [ "$CE_RC" -eq 16 ] \
  || fail "the classification pass must complete normally (rc=$CE_RC): $CE_OUT"

cefield() { ORCHID_REPO="$CLE" "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }

assert_eq rework "$(cefield C300 status)" \
  "a hand-off failure still goes to rework — the work still needs doing (out: $CE_OUT)"
assert_eq 0 "$(cefield C300 attempts)" \
  "but it consumed NO attempt: the budget measures the candidate, and the candidate is not what failed"
assert_eq 1 "$(cefield C300 infra_failures)" \
  "it was charged to the environment budget instead, so a repeating fault still terminates at infra_max rather than looping free forever"

assert_eq rework "$(cefield C400 status)" \
  "an ordinary defect goes to rework (out: $CE_OUT)"
assert_eq 1 "$(cefield C400 attempts)" \
  "and DOES consume an attempt EVEN THOUGH the same mode bit is outstanding on its candidate too — being outstanding is not being to blame, and classification must not become a way for real defects to run free"
assert_eq 0 "$(cefield C400 infra_failures)" \
  "and never touches the environment budget"

CE_JOURNAL="$(cat "$CLE/.orchid/journal.md")"
assert_match "C300 attempt_waiver" "$CE_JOURNAL" \
  "the uncharged round is journaled as an attempt_waiver, so 'not charged' is a durable fact and not an inference from a counter that did not move"
assert_match "handoff, attempt not charged" "$CE_JOURNAL" \
  "and the journal entry names the class and says the attempt was not charged"
assert_match "orchid-ce" "$CE_JOURNAL" \
  "naming the file the operator has to chmod, because a journal line an operator cannot act on is not a reason"
assert_match "candidate, attempt charged" "$CE_JOURNAL" \
  "while the charged round says so too — both arms are on the record, not just the unusual one"

# The waived round records the implement-envelope floor it was entered at.
# `--waive-attempt` holds `attempts` still on purpose, so without this the
# re-dispatched round resolves the envelope of the round just waived and
# re-verifies a candidate that never moved (Part N6 takes that apart).
assert_eq "a1:0" "$(cefield C300 implement_floor)" \
  "the waived round records the floor a fresh implement envelope must clear — attempt 1, and no envelope of its own yet"
assert_eq "" "$(cefield C400 implement_floor)" \
  "while a CHARGED round records none and needs none: attempts moved, so the previous round's envelopes are already unreachable by name"

# A non-candidate round can terminate at infra_max BEFORE the waived rework
# edge writes its attempt_waiver entry. The `infra failure #N` intervention
# itself must therefore carry the same explicit marker; a stationary attempts
# counter is not a durable explanation of why it stayed still.
printf '\ninfra_max=1\n' >> "$CLE/orchid.config"
fm_set "$CLE/.orchid/tasks/C300.md" status testing
fm_set "$CLE/.orchid/tasks/C300.md" infra_failures 0
fm_set "$CLE/.orchid/tasks/C400.md" status "done"
CE_CAP_RC=0
CE_CAP_OUT="$(ORCHID_REPO="$CLE" ORCHID_EPOCH="$CEPOCH" "$DRIVE" 2>&1)" || CE_CAP_RC=$?
[ "$CE_CAP_RC" -eq 0 ] || [ "$CE_CAP_RC" -eq 16 ] \
  || fail "the infra-cap pass must complete normally or at its boundary (rc=$CE_CAP_RC): $CE_CAP_OUT"
assert_eq blocked "$(cefield C300 status)" \
  "the classified hand-off failure blocks at infra_max before a rework edge can journal the waiver (out: $CE_CAP_OUT)"
assert_eq 0 "$(cefield C300 attempts)" \
  "and the cap exit still preserves the attempt budget"
CE_CAP_REASON="$(awk '
  /^## .* C300 intervention / { take=1; next }
  /^## / { take=0 }
  take && /^infra failure #[0-9]+:/ { last=$0; take=0 }
  END { print last }
' "$CLE/.orchid/journal.md")"
assert_match "handoff, attempt not charged" "$CE_CAP_REASON" \
  "the infra-failure record says explicitly that the capped round did not charge an attempt — this is the only durable entry that path reaches"

# ===========================================================================
# Part Y3 -- THE SAME SENTENCES, WITH NOTHING PROVED BEHIND THEM, ARE CHARGED.
#
# Every line below is the WORDING of a failure orchid does forgive elsewhere,
# or once did: an unresolvable dependency (Part Y4 waives that one), the L020
# streaming assertion (Part Y5 waives that one), a harness fault naming itself
# (nothing waives that one -- Part Y6 charges even a run whose recorded exit
# status says it stopped short). Here none of them has any state behind it --
# there is no missing dependency tree, no known-flaky register, and the run
# reached its own verdict -- and all three charge.
#
# THAT IS THE WHOLE SAFETY PROPERTY OF THIS CLASSIFIER, so it is asserted on
# the sentences most likely to tempt a text rule. An earlier round of this
# feature carried a build-state arm that was EXEMPT from the per-failure
# accounting, on the theory that an absent dependency tree invalidates the
# whole run; that exemption let an unrelated ignored `.cache` directory plus
# any `command not found` line waive every failure in a round. The class was
# never the defect -- the exemption was. Part Y4 brings the class back WITH the
# accounting, and this part is what proves the sentence alone still buys
# nothing.
# ===========================================================================
NOWAIVE="$WORK/not-waivable"
mkdir -p "$NOWAIVE/.orchid/tasks" "$NOWAIVE/.orchid/reviews"
cd "$NOWAIVE" || exit 1
git init -q .
printf 'x\n' > file.txt
git add -A
git commit -q -m "fixture: root"
: > "$NOWAIVE/orchid.config"
printf -- '---\nschema: 1\nid: NW1\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\n---\nbody\n' \
  "$NOWAIVE" > "$NOWAIVE/.orchid/tasks/NW1.md"
nw_cls() {
  printf 'date: 2026-08-10T00:00:00Z\nsha: deadbeef\ncandidate: deadbeef\ncwd: %s\ncommand: yarn test\n---\n%s\nexit: 1\n' \
    "$NOWAIVE" "$1" > "$NOWAIVE/.orchid/reviews/NW1-verify.log"
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$NOWAIVE" "$NOWAIVE/.orchid/tasks/NW1.md" \
      "$NOWAIVE/.orchid/reviews/NW1-verify.log" ) | cut -f1
}
assert_eq candidate "$(nw_cls 'error Command "jest" not found')" \
  "a dependency that could not be resolved is CHARGED where NOTHING IS MISSING: this fixture's worktree is its own repo root, so no build state was left behind, and the sentence alone attributes to nothing (Part Y4 is the same sentence with the tree actually absent)"
NOWAIVE_L020_SIG='streaming stub: job log must have grown '
NOWAIVE_L020_SIG+='WHILE the adapter was still running'
assert_eq candidate "$(nw_cls "  FAIL: $NOWAIVE_L020_SIG")" \
  "and the L020 assertion is CHARGED where this repository never wrote it down: orchid never INFERS flakiness, and a register it does not have forgives nothing (Part Y5 is the same line with the register present)"
assert_eq candidate "$(nw_cls '  FAIL: T013 was stranded by a reaped job manifest')" \
  "and a harness fault that NAMES ITSELF is charged — the words are not the evidence, and neither, since this round, is the recorded exit status: Part Y6 charges a run that stopped short too, because that status cannot tell a reap from a candidate that hung"

# ===========================================================================
# Part N2 -- the hand-offs the protocol itself defines need no per-repository
# configuration, and they are PROVED against the world rather than read out of
# the failure text.
#
# The implementer profile may not re-pin a package checksum and may not set an
# exec bit. A feature that only protects those hand-offs once a repository has
# configured a signature protects nobody: the repository learns to configure
# it by first losing the attempt the feature exists to save. So `handoff` is
# recognized with nothing configured at all -- as is `environment` (Part Y4).
# The one class that reads a repository-owned file is
# `flaky` (Part Y5), and even there the file is not a signature list orchid
# trusts on sight: a register the CANDIDATE CHANGED is no authority on that
# candidate, which is what makes it something a repository records rather than
# something it can buy.
#
# EARLIER ROUNDS OF THIS FEATURE READ THE FAILURE TEXT, and each one forgave
# defects it should have charged: first by matching `: Permission denied` and
# `checksum is stale` outright, then by tokenizing a path out of those same
# sentences and corroborating it against the tree. Every sentence involved is
# one an ordinary bug prints -- a test that writes where it may not, a
# validator reporting on a file's mode, a bug in the repository's own pinning
# script -- so each round's answer was a narrower heuristic rather than a
# different KIND of evidence.
#
# What is asserted below is the replacement: the hand-off arm's two closed
# questions, each answered by the world, and nothing else forgiven by IT.
#
#   - STAT the files the candidate ADDED, and the ones it MODIFIED whose base
#     recorded mode 755: a `#!` file with no execute permission is the
#     exec-bit hand-off's own state on disk, whether the candidate shipped it
#     that way or lost the bit while rewriting it.
#   - RUN the repository's package-pin freshness check (Part N2b).
#
# State and attribution are independent, and both directions are asserted
# here. An exec-bit sentence with no such file charges; an ordinary assertion
# failure with a mode-644 new script sitting in the tree charges too. The state
# says a hand-off is outstanding, but only a causal line plus its named cascade
# says that hand-off blocked this round.
# ===========================================================================
HOF="$WORK/handoff"
mkdir -p "$HOF/.orchid/tasks" "$HOF/.orchid/reviews" "$HOF/libexec" "$HOF/bin"
cd "$HOF" || exit 1
git init -q .
printf 'fixture\n' > "$HOF/README"
# A mode-644 file with a `#!` line that has been in the tree since BEFORE this
# candidate. Present throughout everything below, and never recognized: an old
# data-ish script nobody is waiting on is not an outstanding hand-off, and
# treating it as one would forgive every failure this repository ever produces.
printf '#!/usr/bin/env bash\necho old\n' > "$HOF/libexec/pre-existing"
git add README libexec/pre-existing
git commit -q -m "fixture: base"
HOF_BASE="$(git -C "$HOF" rev-parse HEAD)"

# What the candidate ADDED. Three files, and only one of them is the hand-off.
printf '#!/usr/bin/env bash\necho frob\n' > "$HOF/libexec/orchid-frob"      # shipped 644
printf '#!/usr/bin/env bash\necho ok\n'   > "$HOF/bin/already-chmodded"
chmod +x "$HOF/bin/already-chmodded"                                        # hand-off done
printf 'name: fixture\n'                  > "$HOF/libexec/fixture.yml"      # never executable
git add libexec/orchid-frob bin/already-chmodded libexec/fixture.yml
git commit -q -m "fixture: candidate"
HOF_CAND="$(git -C "$HOF" rev-parse HEAD)"

# mk_hof_task <base-sha> <candidate-sha>
mk_hof_task() {
  printf -- '---\nschema: 1\nid: H01\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$HOF" "$1" "$2" > "$HOF/.orchid/tasks/H01.md"
}
# hof_log <body>
hof_log() {
  mk_prestate_log "$REPO_ROOT" "$HOF/.orchid/tasks/H01.md" \
    "$HOF/.orchid/reviews/H01-verify.log" "$1"
}
# Config from THIS repository, tree from the fixture: the claim is about orchid
# as it actually ships (no handoff.pin_check declared), decided against a
# candidate whose files this test controls.
hof_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$REPO_ROOT" "$HOF/.orchid/tasks/H01.md" "$HOF/.orchid/reviews/H01-verify.log" )
}
mk_hof_task "$HOF_BASE" "$HOF_CAND"

# The layer the hand-off is recognized THROUGH, asserted directly. It fails
# silently when it fails -- a probe that says "no" is indistinguishable from
# "no hand-off here", the class lands on `candidate`, and an implementer
# forbidden to run `chmod` (L017) is charged for the operator's step. Asserted
# here so a break says WHICH layer broke.
assert_eq "libexec/orchid-frob" \
  "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H01.md")" \
  "of everything this candidate added, the exec-bit route names the one file that is meant to be run and cannot be: git says which files are new, stat says which of them is mode 644"
if ! _drive_exec_bit_missing "$HOF/libexec/orchid-frob"; then
  fail "a mode-644 file with a #! line IS the exec-bit hand-off's own state on disk — this probe is what separates it from a defect"
fi
if _drive_exec_bit_missing "$HOF/bin/already-chmodded"; then
  fail "and a file whose exec bit is already set is NOT: the hand-off has been performed, so the same failure charges"
fi
if _drive_exec_bit_missing "$HOF/libexec/fixture.yml"; then
  fail "nor is a plain data file that was never meant to be executed: the #! line is what makes chmod +x the whole fix"
fi

hof_log "bash: $HOF/libexec/orchid-frob: Permission denied"
assert_eq handoff "$(hof_cls | cut -f1)" \
  "the raw shape a repository with no gate of its own sees — the shell refusing a mode-644 executable — is a hand-off"
assert_match "orchid-frob" "$(hof_cls | cut -f2-)" \
  "and the reason names the file the operator has to chmod, not just the class"
assert_match "L017" "$(hof_cls | cut -f2-)" \
  "and says whose step is outstanding, citing the rule that forbids the implementer to take it"

hof_log "FAIL: PROTOCOL.md names 'orchid frob' but libexec/orchid-frob is not executable"
assert_eq handoff "$(hof_cls | cut -f1)" \
  "the gated shape is the same hand-off and the same answer — the wording changed, the world did not"

# --- BEING OUTSTANDING IS NOT BEING TO BLAME -------------------------------
# The half that was missing until now, and the reason it matters HERE more
# than anywhere: every lib/*.sh this repository ships is tracked mode 644 WITH
# a `#!` line, because those are sourced rather than executed, so "this
# candidate added a file that carries a #! line and is not executable" is
# simply true of any task that adds a library -- T010 added lib/handoff.sh.
# Nothing on disk tells that file apart from a new libexec/ verb genuinely
# awaiting chmod +x, which is why the state cannot be narrowed out of the
# problem and the FAILURE has to be attributable to the artifact as well.
# Waiving on the state alone forgave whole rounds that had nothing to do with
# a mode bit, and looked rigorous while doing it. The shapes below are the
# ones that are not attributable.
hof_log "tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "an ordinary assertion failure is CHARGED while a mode-644 new executable sits in the tree: the state is outstanding, and nothing about this failure says the mode bit is why it failed"
assert_match "attribution was not established" "$(hof_cls | cut -f2-)" \
  "and it says exactly that, rather than charging silently or claiming the hand-off is absent"
assert_match "orchid-frob" "$(hof_cls | cut -f2-)" \
  "while STILL naming the outstanding state — an operator reading this journal entry can clear the hand-off and see that it was not what failed"

hof_log "== libexec/orchid-frob
  FAIL: libexec/orchid-frob printed 'frob' where the spec says 'frobbed'"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "NAMING the file is not attributing the failure to its mode bit — every assertion inside a newly added file names that file, which is exactly how an ambient proof launders a real defect"

hof_log "tests/test_writes.sh: FAIL: open('/etc/hosts', 'w'): Permission denied"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "and a refusal about SOME OTHER path attributes nothing either: a candidate writing where it may not is the candidate's"

# --- A HAND-OFF WAIVES ITS OWN FAILURE, NEVER THE ROUND AROUND IT ----------
hof_log "bash: $HOF/libexec/orchid-frob: Permission denied
tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "the hand-off's own refusal is attributed and the round is STILL charged, because a second failing line in it is not — a defect landing in the same round as a hand-off is precisely what must not be laundered"
assert_match "further failing line" "$(hof_cls | cut -f2-)" \
  "and the reason says how much it did not explain"
assert_match "widget returned 3" "$(hof_cls | cut -f2-)" \
  "quoting the first line it could not attribute, so the operator can see what is being charged for"

# --- the operator performs the hand-off, and the state is gone -------------
chmod +x "$HOF/libexec/orchid-frob"
assert_eq "" "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H01.md")" \
  "once the operator has run chmod +x there is no exec-bit state left to prove, even though the candidate still ADDED the file"
hof_log "bash: $HOF/libexec/orchid-frob: Permission denied"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "so the identical sentence now charges: whatever this failure is, chmod is not the fix"
assert_match "no failure-attributable waivable state was established" "$(hof_cls | cut -f2-)" \
  "and it says why it charged rather than charging silently or overstating what inspection established"
hof_log "tests/test_writes.sh: FAIL: open('/etc/hosts', 'w'): Permission denied"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "and an ORDINARY test failure that merely says 'Permission denied' — a candidate writing where it may not — is charged, which every text rule got backwards"
hof_log "pin-formula: Formula/orchid.rb checksum is STALE for the current content"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "a staleness SENTENCE forgives nothing on its own either: this fixture has no pin check to run, so there is no stale-pin state to prove"

# The mode-644 `#!` file that was in the tree before this candidate is still
# there, and has decided nothing anywhere above.
if [ -x "$HOF/libexec/pre-existing" ]; then
  fail "fixture invariant broken: libexec/pre-existing must stay mode 644, or the next assertion proves nothing"
fi
assert_eq "" "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H01.md")" \
  "a mode-644 #! file the candidate did NOT add is nobody's outstanding hand-off — ADDED is what makes it one, and without that every failure in a repository with one old 644 script would be forgiven forever"

# --- no shas is no proof, and no proof charges -----------------------------
mk_hof_task "" ""
hof_log "bash: $HOF/libexec/orchid-frob: Permission denied"
assert_eq candidate "$(hof_cls | cut -f1)" \
  "a task with no base/candidate sha cannot be asked what it added, and 'I could not ask git' is not evidence of a hand-off"
mk_hof_task "$HOF_BASE" 0000000000000000000000000000000000000000
assert_eq candidate "$(hof_cls | cut -f1)" \
  "nor is a sha that does not resolve in this tree"

# --- EVERY added 644 `#!` file is offered to attribution, not just the first -
# The realistic shape of this in orchid itself: one commit adds a sourced
# library (mode 644 by convention, and nobody's hand-off) and a verb that
# really is waiting for chmod +x. git orders the library first, so stopping at
# the first would hand attribution the one file the failure says nothing about
# and charge a round the operator owns.
printf '#!/usr/bin/env bash\n# sourced, never executed — mode 644 on purpose\n' \
  > "$HOF/lib-two-a.sh"
printf '#!/usr/bin/env bash\necho two-b\n' > "$HOF/libexec/orchid-two-b"
git -C "$HOF" add lib-two-a.sh libexec/orchid-two-b
git -C "$HOF" commit -q -m "fixture: a sourced library and a verb, both mode 644"
HOF_MULTI="$(git -C "$HOF" rev-parse HEAD)"
printf -- '---\nschema: 1\nid: H02\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$HOF" "$HOF_CAND" "$HOF_MULTI" > "$HOF/.orchid/tasks/H02.md"
mk_prestate_log "$REPO_ROOT" "$HOF/.orchid/tasks/H02.md" \
  "$HOF/.orchid/reviews/H02-verify.log" \
  "bash: $HOF/libexec/orchid-two-b: Permission denied"
h02_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$REPO_ROOT" "$HOF/.orchid/tasks/H02.md" \
      "$HOF/.orchid/reviews/H02-verify.log" )
}
assert_eq 2 "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H02.md" | grep -c .)" \
  "both added mode-644 #! files are reported — which of them a failure blames is attribution's question, and it cannot answer it about a path it was never given"
assert_eq handoff "$(h02_cls | cut -f1)" \
  "and the round is waived on the one the shell actually refused"
H02_REASON="$(h02_cls | cut -f2-)"
assert_match "orchid-two-b" "$H02_REASON" \
  "named in the reason, so the operator chmods the file that failed"
case "$H02_REASON" in
  *lib-two-a*) fail "the library that merely sorted first was named as the hand-off: $H02_REASON" ;;
esac

# --- AN UNBLAMED 644 IS REPORTED, NOT PRESCRIBED ---------------------------
# The same two files, and a round that failed on neither of them. With no
# attribution to tell a new verb from a sourced library, the fallback used to
# assert an operator ACTION about whichever path git listed first -- so a task
# that added one library was told, on every unrelated failure for the rest of
# its life, that `chmod +x lib-two-a.sh` was an outstanding operator step.
# It was not: that file is mode 644 on purpose, nobody was waiting on it, and
# an operator who followed the instruction would have committed a mode change
# no reviewer asked for. In this repository that is not a corner case: nearly
# every lib/*.sh, scripts/pin-formula.sh and some thirty files under tests/ are
# exactly this shape, because a file that is sourced or run as `bash <file>`
# has no use for an exec bit.
#
# The state is still SAID, because a charged round has to show what is open.
# What is withdrawn is the imperative.
mk_prestate_log "$REPO_ROOT" "$HOF/.orchid/tasks/H02.md" \
  "$HOF/.orchid/reviews/H02-verify.log" \
  "tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq candidate "$(h02_cls | cut -f1)" \
  "an ordinary assertion failure is charged with two mode-644 #! files outstanding, exactly as before — this is about what the reason SAYS, not about what it decides"
H02_UNBLAMED="$(h02_cls | cut -f2-)"
assert_match "lib-two-a" "$H02_UNBLAMED" \
  "and the outstanding state is still named, because the point of reporting it on a charged round is that the operator can see what is open and rule it out"
if grep -Fq 'chmod' <<<"$H02_UNBLAMED"; then
  fail "but a round that blames it for nothing must not prescribe chmod +x on it: nothing on disk tells a new verb shipped 644 from a library that is 644 because it is SOURCED, attribution is what resolves that, and a charged round has none of it by definition (got: $H02_UNBLAMED)"
fi
assert_match "rather than presented as a mode change" "$H02_UNBLAMED" \
  "the reason says so out loud instead of going quiet — an operator who reads that a file is 644 and that nothing here was refused execution has learned the true thing, and is not sent to run a command nobody needs"

# --- THE MODE BIT A CANDIDATE DROPPED, NOT ONE IT NEVER SET ----------------
# The shape that stranded THIS task, and the one an ADDED-only rule cannot see.
# runners/orchid-drive was tracked 100755; an implementer round rewrote it and
# the mode came back 100644; every drive invocation in its own suite then
# returned 126 and 116 assertions cascaded from that one cause. The file was
# MODIFIED, so `git diff --diff-filter=A` names it nowhere, no state is proved,
# and the round charges -- orchid billing an attempt for exactly the hand-off
# this whole feature exists to recognize. It is a shape and not an incident:
# any engine whose file writes recreate a file at 0644 does this to every
# executable it touches, and the implementer cannot chmod it back (L017).
#
# The fixture forces the INDEX mode with `git update-index --chmod`, never
# relying on core.fileMode: what the base RECORDED is the whole question here,
# and a checkout where git ignores the filesystem's mode bit would otherwise
# make these assertions silently vacuous rather than failing.
mkdir -p "$HOF/runners"
printf '#!/usr/bin/env bash\necho drive\n' > "$HOF/runners/hof-drive"
chmod +x "$HOF/runners/hof-drive"
# Modified in the SAME candidate, and mode 644 in the base too: the ambient
# shape, which must decide nothing. Without this file beside it the assertion
# below would pass just as well for a rule that reported every modified 644
# `#!` file -- which is the over-broad proof this task was sent back for.
printf '#!/usr/bin/env bash\n# sourced, never executed\n' > "$HOF/lib-sourced.sh"
git -C "$HOF" add runners/hof-drive lib-sourced.sh
git -C "$HOF" update-index --chmod=+x runners/hof-drive
git -C "$HOF" commit -q -m "fixture: an executable runner and a sourced library"
HOF_DROP_BASE="$(git -C "$HOF" rev-parse HEAD)"

printf '#!/usr/bin/env bash\necho drive v2\n' > "$HOF/runners/hof-drive"
chmod -x "$HOF/runners/hof-drive"
printf '#!/usr/bin/env bash\n# sourced, never executed, v2\n' > "$HOF/lib-sourced.sh"
git -C "$HOF" add runners/hof-drive lib-sourced.sh
git -C "$HOF" update-index --chmod=-x runners/hof-drive
git -C "$HOF" commit -q -m "fixture: the rewrite that lost the runner's mode bit"
HOF_DROP_CAND="$(git -C "$HOF" rev-parse HEAD)"

printf -- '---\nschema: 1\nid: H03\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$HOF" "$HOF_DROP_BASE" "$HOF_DROP_CAND" > "$HOF/.orchid/tasks/H03.md"
h03_log() {
  mk_prestate_log "$REPO_ROOT" "$HOF/.orchid/tasks/H03.md" \
    "$HOF/.orchid/reviews/H03-verify.log" "$1"
}
h03_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$REPO_ROOT" "$HOF/.orchid/tasks/H03.md" \
      "$HOF/.orchid/reviews/H03-verify.log" )
}

if ! _drive_exec_bit_dropped "$HOF" "$HOF_DROP_BASE" runners/hof-drive; then
  fail "the base recorded runners/hof-drive as mode 100755 — that record is the only thing that can tell a dropped exec bit from a file that never had one, and reading it is the layer everything below stands on"
fi
if _drive_exec_bit_dropped "$HOF" "$HOF_DROP_BASE" lib-sourced.sh; then
  fail "a file the base recorded at mode 644 has dropped nothing, however often this candidate rewrote it — otherwise every modified sourced library in this repository would prove a hand-off, which is the ambient proof this task was sent back for"
fi
if _drive_exec_bit_dropped "$HOF" "$HOF_DROP_BASE" runners/never-existed; then
  fail "and a path the base does not carry at all answers no rather than yes: 'I could not ask git' must charge"
fi

assert_eq "runners/hof-drive" \
  "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H03.md")" \
  "the exec-bit route names the runner whose mode this candidate DROPPED, and not the library it merely modified — an added-only rule names neither, which is how this task was stranded by the very hand-off it exists to classify"

h03_log "bash: $HOF/runners/hof-drive: Permission denied"
assert_eq handoff "$(h03_cls | cut -f1)" \
  "so the shell's 126 on a runner that was executable until this candidate rewrote it is a hand-off, and charges no attempt"
assert_match "MODIFIED, dropping the mode 755" "$(h03_cls | cut -f2-)" \
  "with the reason saying WHICH shape it is: 'you rewrote a runner and lost its mode bit' and 'you shipped a new verb at 644' are the same chmod and a different thing to know about the round"
assert_match "hof-drive" "$(h03_cls | cut -f2-)" \
  "and naming the file, because a reason an operator cannot act on is not a reason"

h03_log "tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq candidate "$(h03_cls | cut -f1)" \
  "while an ordinary assertion failure is charged with the same dropped mode bit outstanding: this half is proof of STATE, and attribution is still required of the failure"

# --- AND ON AN UNBLAMED ROUND THE DROPPED BIT OUTRANKS THE AMBIENT ONE ----
# The two shapes are not equally actionable, and a round that holds both must
# report the one that is. A dropped bit is an operator step on its own
# evidence -- the base tree recorded mode 755, something WAS executable and is
# not any more -- while an added 644 `#!` file is the ambient shape this
# repository ships libraries in. git orders `lib-alpha.sh` before
# `runners/hof-drive`, so a fallback that took whatever sorted first would
# report the one nobody is waiting on and bury the one somebody is.
printf '#!/usr/bin/env bash\n# sourced, never executed — mode 644 on purpose\n' \
  > "$HOF/lib-alpha.sh"
git -C "$HOF" add lib-alpha.sh
git -C "$HOF" commit -q -m "fixture: the same rewrite, plus a sourced library that sorts first"
HOF_DROP_MULTI="$(git -C "$HOF" rev-parse HEAD)"
printf -- '---\nschema: 1\nid: H04\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$HOF" "$HOF_DROP_BASE" "$HOF_DROP_MULTI" > "$HOF/.orchid/tasks/H04.md"
mk_prestate_log "$REPO_ROOT" "$HOF/.orchid/tasks/H04.md" \
  "$HOF/.orchid/reviews/H04-verify.log" \
  "tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq 2 "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H04.md" | grep -c .)" \
  "fixture: this candidate leaves BOTH shapes outstanding at once — a sourced library it added at 644 and a runner whose 755 it dropped — or the preference below has nothing to choose between"
H04_REASON="$( ( HOME="$MACHINE_HOME"
  drive_verify_class "$REPO_ROOT" "$HOF/.orchid/tasks/H04.md" \
    "$HOF/.orchid/reviews/H04-verify.log" ) | cut -f2-)"
assert_match "chmod [+]x runners/hof-drive" "$H04_REASON" \
  "the DROPPED bit is what an unblamed round reports, with the imperative intact: it is owed whether or not this round's failures noticed, because the base tree is the evidence rather than the failure"
case "$H04_REASON" in
  *lib-alpha*) fail "and the ambient library that merely sorted first is not what the operator is pointed at: $H04_REASON" ;;
esac

# The operator performs the hand-off; the state is gone and the identical
# failure charges, exactly as it does for the added shape.
chmod +x "$HOF/runners/hof-drive"
assert_eq "" "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H03.md")" \
  "once chmod +x has been run there is no state left to prove, even though the candidate's commit still records mode 644"
h03_log "bash: $HOF/runners/hof-drive: Permission denied"
assert_eq candidate "$(h03_cls | cut -f1)" \
  "and the same sentence charges afterwards — whatever that refusal is now, chmod is not the fix"

# The candidate-controlled verifier command must not be able to CREATE that
# same state after the trusted snapshot. Capture an empty exec set while the
# file is executable, strip it as the command could, and then file the exact
# permission diagnostic that the old post-run classifier waived.
H03_BEFORE_MUTATION="$(drive_verify_prestate_headers \
  "$REPO_ROOT" "$HOF/.orchid/tasks/H03.md")"
chmod -x "$HOF/runners/hof-drive"
assert_eq "runners/hof-drive" \
  "$(drive_handoff_exec_bit "$HOF" "$HOF/.orchid/tasks/H03.md")" \
  "fixture: after the simulated command strips the bit, a post-run inspection really would see a waivable hand-off"
mk_prestate_log "$REPO_ROOT" "$HOF/.orchid/tasks/H03.md" \
  "$HOF/.orchid/reviews/H03-verify.log" \
  "bash: $HOF/runners/hof-drive: Permission denied" \
  "bash tests/run.sh" 1 "$H03_BEFORE_MUTATION"
assert_eq candidate "$(h03_cls | cut -f1)" \
  "but trusted pre-verification evidence says the bit was present, so a candidate cannot strip it during its test and manufacture its own hand-off waiver"
chmod +x "$HOF/runners/hof-drive"

# ===========================================================================
# Part N2d -- ONE FAULT IS NOT ONE FAILING LINE, and a path is not a substring.
#
# Two errors, pulling opposite ways, and both were real.
#
# TOO NARROW. A missing mode bit does not produce a failure; it produces a
# CASCADE. This task's own stranding was 116 assertions from ONE stripped bit
# on runners/orchid-drive: the shell refused the file once, and every check
# that needed it then failed in its own words -- `runners/orchid-drive must
# exist and be executable`, `T001 must reach done ... (last rc=126 ...
# Permission denied)`. An accounting that could only ever claim the lines
# carrying a refusal SHAPE left the other hundred unexplained, and the round
# charged. An arm that fires only when the round contains nothing else can
# never fire when it matters, and one missing mode bit is when it matters.
#
# TOO LOOSE. The path was matched as a substring, so an outstanding `bin/tool`
# collected a genuine `bin/tool-helper: Permission denied` -- a different file,
# the candidate's own defect -- and waived the round on it.
#
# The fix for both is one shape: attribute per FAILURE, and match the path at a
# BOUNDARY. What is left unclaimed decides the round, so a round may hold a mix
# and still charge for the part nobody owns.
# ===========================================================================
CSC="$WORK/handoff-cascade"
mkdir -p "$CSC/.orchid/tasks" "$CSC/.orchid/reviews" "$CSC/runners" "$CSC/bin"
cd "$CSC" || exit 1
git init -q .
printf '#!/usr/bin/env bash\necho drive\n' > "$CSC/runners/csc-drive"
chmod +x "$CSC/runners/csc-drive"
printf 'fixture\n' > "$CSC/README"
git add runners/csc-drive README
git -C "$CSC" update-index --chmod=+x runners/csc-drive
git commit -q -m "fixture: base, with an executable runner"
CSC_BASE="$(git -C "$CSC" rev-parse HEAD)"

# The candidate loses the runner's mode bit AND adds a new mode-644 `#!` helper
# whose name is a strict PREFIX of another file's. Two outstanding exec-bit
# states at once, which is what lets the assertions below separate "this one is
# to blame" from "this one is merely open".
printf '#!/usr/bin/env bash\necho drive v2\n' > "$CSC/runners/csc-drive"
chmod -x "$CSC/runners/csc-drive"
printf '#!/usr/bin/env bash\necho tool\n' > "$CSC/bin/csc-tool"
git add runners/csc-drive bin/csc-tool
git -C "$CSC" update-index --chmod=-x runners/csc-drive
git commit -q -m "fixture: the rewrite that lost the mode bit, and a new 644 helper"
CSC_CAND="$(git -C "$CSC" rev-parse HEAD)"

printf -- '---\nschema: 1\nid: K01\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$CSC" "$CSC_BASE" "$CSC_CAND" > "$CSC/.orchid/tasks/K01.md"
csc_log() {
  mk_prestate_log "$REPO_ROOT" "$CSC/.orchid/tasks/K01.md" \
    "$CSC/.orchid/reviews/K01-verify.log" "$1"
}
csc_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$REPO_ROOT" "$CSC/.orchid/tasks/K01.md" \
      "$CSC/.orchid/reviews/K01-verify.log" )
}
assert_eq 2 "$(drive_handoff_exec_bit "$CSC" "$CSC/.orchid/tasks/K01.md" | grep -c .)" \
  "fixture invariant: BOTH the dropped runner and the added helper are outstanding exec-bit states, or the mix this part is about does not exist"

# --- the cascade, in the shape the harness really prints it ----------------
# One refusal, then four downstream reports. Only two of the five carry a
# refusal shape at all; every one of them NAMES the file whose mode bit is the
# whole cause.
CSC_CASCADE="== tests/test_drive.sh
/bin/bash: runners/csc-drive: Permission denied
  FAIL: runners/csc-drive must exist and be executable
  FAIL: T001 must reach done under repeated deterministic passes alone (last rc=126, stderr=/bin/bash: runners/csc-drive: Permission denied)
  FAIL: a reaped manifest strands T013 (runners/csc-drive exited 126)
  FAIL: the boundary runners/csc-drive raised is not the one PROTOCOL.md names"
csc_log "$CSC_CASCADE"
assert_eq 5 "$(drive_failure_lines "$CSC_CASCADE" | grep -c .)" \
  "five of those six lines report a failure — if the oracle miscounts them the accounting below decides the round on the wrong denominator"
assert_eq 2 "$(drive_exec_bit_causal runners/csc-drive "$CSC_CASCADE" | grep -c .)" \
  "and only TWO of the five refuse to execute the runner: requiring that shape of every line is exactly what made this arm inert for a cascade"
assert_eq 5 "$(drive_exec_bit_attribution runners/csc-drive "$CSC_CASCADE" | grep -c .)" \
  "while the attribution claims all five, because once a line has proved the mode bit blocked this run, every failing line naming that file is that mode bit's failure"
assert_eq "" "$(drive_unattributed_failures "$CSC_CASCADE" \
    "$(drive_exec_bit_attribution runners/csc-drive "$CSC_CASCADE")")" \
  "leaving nothing unexplained, which is the only state a waiver is admissible in"
assert_eq handoff "$(csc_cls | cut -f1)" \
  "so a hundred-line cascade from one stripped mode bit is a hand-off and charges no attempt — this task was stranded by exactly this round, by the feature built to recognize it"
CSC_REASON="$(csc_cls | cut -f2-)"
assert_match "csc-drive" "$CSC_REASON" \
  "with the reason naming the file the operator has to chmod"
case "$CSC_REASON" in
  *csc-tool*) fail "the OTHER outstanding exec-bit state was named as this round's cause: being outstanding is not being to blame, and a reason an operator acts on must name the one that is ($CSC_REASON)" ;;
esac

# A shell resolution refusal is a failure even without `FAIL:` or `error:` in
# front of it. If the failure-line oracle drops it, the attributed exec-bit
# line appears to account for the whole round and launders this second defect.
CSC_RESOLUTION_MIX="/bin/bash: runners/csc-drive: Permission denied
missing-helper: command not found"
assert_eq 2 "$(drive_failure_lines "$CSC_RESOLUTION_MIX" | grep -c .)" \
  "both the attributed refusal and the unrelated resolution refusal belong to the round's failure universe"
assert_eq "missing-helper: command not found" \
  "$(drive_unattributed_failures "$CSC_RESOLUTION_MIX" \
      "$(drive_exec_bit_attribution runners/csc-drive "$CSC_RESOLUTION_MIX" "$CSC")")" \
  "the hand-off claims its own permission refusal but cannot make an unadorned command-not-found diagnostic disappear"
csc_log "$CSC_RESOLUTION_MIX"
assert_eq candidate "$(csc_cls | cut -f1)" \
  "an unexplained resolution failure beside an attributable hand-off CHARGES the round rather than being waived by omission"
assert_match "missing-helper: command not found" "$(csc_cls | cut -f2-)" \
  "and the charged reason quotes the diagnostic that prevented the waiver"

# Fatal language/runtime diagnostics carry their own verdict too. They need a
# bounded family rather than a bare `panic` substring: progress identifiers and
# counters use the same vocabulary and must not make every waiver inert.
CSC_FATAL_MIX="/bin/bash: runners/csc-drive: Permission denied
panic: candidate invariant broke
RuntimeError: widget exploded
Segmentation fault: 11
ld: undefined reference to widget
/bin/bash: syntax error near unexpected token
fatal: allocator corrupted
thread 'main' panicked at src/main.rs:9"
assert_eq 8 "$(drive_failure_lines "$CSC_FATAL_MIX" | grep -c .)" \
  "the attributed refusal and seven unmistakable panic, exception, crash, linker, syntax, and fatal diagnostics all belong to the failure universe"
assert_eq 7 "$(drive_unattributed_failures "$CSC_FATAL_MIX" \
    "$(drive_exec_bit_attribution runners/csc-drive "$CSC_FATAL_MIX" "$CSC")" | grep -c .)" \
  "the exec-bit hand-off claims only its refusal and leaves every fatal candidate diagnostic to charge"
csc_log "$CSC_FATAL_MIX"
assert_eq candidate "$(csc_cls | cut -f1)" \
  "a panic beside an attributable hand-off CHARGES the round rather than disappearing outside the harness-prefix oracle"
assert_match "panic: candidate invariant broke" "$(csc_cls | cut -f2-)" \
  "and the charged reason leads with the fatal diagnostic the hand-off did not explain"
CSC_FATAL_PROGRESS="== tests/test_panic_recovery.sh
panic_cases: 4
fatal_errors: 0
exception_count: 0
error handling coverage complete
out_of_memory cases passed"
assert_eq "" "$(drive_failure_lines "$CSC_FATAL_PROGRESS")" \
  "progress paths, counters, and prose containing fatal vocabulary are not verdicts — boundaries keep the strict oracle usable rather than making every waiver charge"

# No finite failure-word list can implement the strict default on its own. An
# unfamiliar diagnostic is uncertainty, and uncertainty charges even when it
# happens to name the same artifact as a proved hand-off. The naming cascade is
# therefore restricted to lines that report a failure in their own syntax;
# otherwise the fallback below would be added to the denominator and then
# immediately claimed by the very artifact it is meant to remain independent
# from.
CSC_UNKNOWN_MIX="/bin/bash: runners/csc-drive: Permission denied
runners/csc-drive produced an unfamiliar candidate verdict"
assert_eq 1 "$(drive_reported_failure_lines "$CSC_UNKNOWN_MIX" | grep -c .)" \
  "only the permission refusal reports a recognized failure — the second line exercises the unknown-diagnostic fallback rather than another keyword"
assert_eq 2 "$(drive_failure_lines "$CSC_UNKNOWN_MIX" | grep -c .)" \
  "the unfamiliar non-progress diagnostic still belongs to the round's fail-closed accounting universe"
assert_eq "/bin/bash: runners/csc-drive: Permission denied" \
  "$(drive_exec_bit_attribution runners/csc-drive "$CSC_UNKNOWN_MIX" "$CSC")" \
  "an unknown line is never admitted to a same-file cascade merely because it names the attributed artifact"
csc_log "$CSC_UNKNOWN_MIX"
assert_eq candidate "$(csc_cls | cut -f1)" \
  "an unknown candidate diagnostic beside an attributable hand-off CHARGES rather than being waived by omission"
assert_match "unfamiliar candidate verdict" "$(csc_cls | cut -f2-)" \
  "and the charged reason quotes the uncertain line that prevented the waiver"

# The fallback remains usable against the output of Orchid's OWN complete
# suite. tests/run.sh prints a heading for each file; several shipped tests end
# in a standalone `OK`; and helpers.sh emits both NOT-TESTED records unconditionally
# in files that make an explicit qualification gap visible. None is a pass for
# the candidate defect, but none diagnoses one either. If even one stays in the
# denominator, every full-suite stale-pin, exec-bit, environment, and L020
# round becomes candidate-charged before its actual terminal fault is weighed.
CSC_SHIPPED_NON_FAILURE="== /repo/tests/test_e2e_concurrency.sh
e2e concurrency: OK
== /repo/tests/test_schedule.sh
unit: schedule_dispatch_blockers predicates OK
  NOT-TESTED: failure-triage -- this failed fixture deliberately has no checkout
  not-tested: 1 claim(s) in this file were recorded as not-tested, never as passes
  RED-CASE: the failure diagnostic was rejected by the gate
  GREEN-CASE: the failed fixture's positive control was accepted
  red-cases: 1 demonstrated in this file (green-cases: 1)"
assert_eq "" "$(drive_failure_lines "$CSC_SHIPPED_NON_FAILURE")" \
  "the shipped whole-suite headings, terminal OK records, and explicit qualification records stay non-failures even when their human labels name the failure they demonstrated"
assert_eq "" "$(drive_reported_failure_lines "$CSC_SHIPPED_NON_FAILURE")" \
  "the same qualification records cannot enter an artifact cascade merely because their labels say failure or failed"
assert_eq "FAIL: candidate defect OK" "$(drive_failure_lines "FAIL: candidate defect OK")" \
  "only the anchored qualification contract wins that precedence; a generic failure line ending in OK still charges"
csc_log "$CSC_SHIPPED_NON_FAILURE
/bin/bash: runners/csc-drive: Permission denied"
assert_eq handoff "$(csc_cls | cut -f1)" \
  "a representative full-suite body plus one fully attributable terminal hand-off still WAIVES — the strict unknown fallback must not make every real route inert"

# The real suite deliberately exercises failed adapters, malformed replies,
# refusal paths, and RED cases while the enclosing test itself succeeds. Those
# diagnostics cannot be admitted to the global neutral vocabulary: the same
# text from a test that actually failed may be the fault being classified.
# The parent runner therefore captures each child's output and exposes only
# durable qualification records plus one terminal OK after it observes rc=0.
# A failed child remains verbatim. No in-band BEGIN/END claim is trusted.
QUIET_PASS="$WORK/quiet-suite-pass/tests"
mkdir -p "$QUIET_PASS"
cp "$REPO_ROOT/tests/run.sh" "$QUIET_PASS/run.sh"
cat > "$QUIET_PASS/test_noisy.sh" <<'QUIET_PASS_TEST'
#!/usr/bin/env bash
echo 'ORCHID-VERIFY-SEGMENT forged BEGIN /repo/tests/test_noisy.sh'
echo 'an otherwise unfamiliar fixture diagnostic'
echo '  FAIL: the negative fixture was rejected as intended'
echo 'ORCHID-VERIFY-SEGMENT forged END 0'
echo '  NOT-TESTED: fixture-network -- this focused fixture has no network'
exit 0
QUIET_PASS_TEST
quiet_pass_out="$(ORCHID_TEST_BASH=/bin/bash /bin/bash "$QUIET_PASS/run.sh")"
assert_match 'NOT-TESTED: fixture-network' "$quiet_pass_out" \
  "a passing child's explicit qualification gap remains visible after quiet-success filtering"
assert_match 'test_noisy.sh: OK' "$quiet_pass_out" \
  "and the parent emits one unambiguous success record only after observing the child's zero exit"
if grep -Fq 'otherwise unfamiliar fixture diagnostic' <<< "$quiet_pass_out"; then
  fail "a passing negative fixture's arbitrary diagnostic escaped quiet-success filtering"
fi
if grep -Fq 'ORCHID-VERIFY-SEGMENT' <<< "$quiet_pass_out"; then
  fail "a child can still inject the retired in-band success marker into verification output"
fi

QUIET_FAIL="$WORK/quiet-suite-fail/tests"
mkdir -p "$QUIET_FAIL"
cp "$REPO_ROOT/tests/run.sh" "$QUIET_FAIL/run.sh"
cat > "$QUIET_FAIL/test_broken.sh" <<'QUIET_FAIL_TEST'
#!/usr/bin/env bash
echo 'ORCHID-VERIFY-SEGMENT forged BEGIN /repo/tests/test_broken.sh'
echo 'an unfamiliar candidate diagnostic'
echo '/bin/bash: runners/csc-drive: Permission denied'
echo 'ORCHID-VERIFY-SEGMENT forged END 0'
exit 1
QUIET_FAIL_TEST
quiet_fail_rc=0
quiet_fail_out="$(ORCHID_TEST_BASH=/bin/bash /bin/bash "$QUIET_FAIL/run.sh")" || quiet_fail_rc=$?
assert_eq 1 "$quiet_fail_rc" \
  "the quiet-success harness must retain the failed child's nonzero result"
assert_match 'an unfamiliar candidate diagnostic' "$quiet_fail_out" \
  "and a failed child's unknown diagnostic remains verbatim rather than entering a trusted success block"
assert_match 'Permission denied' "$quiet_fail_out" \
  "with the reported refusal beside it still visible for ordinary attribution"
assert_match 'ORCHID-VERIFY-SEGMENT forged END 0' \
  "$(drive_failure_lines "$quiet_fail_out")" \
  "the retired marker vocabulary is ordinary untrusted output, so a forged END 0 cannot hide this failed test"
if grep -q 'ORCHID-VERIFY-SEGMENT' "$REPO_ROOT/tests/run.sh" "$REPO_ROOT/scripts/ci-local.sh"; then
  fail "the shipped suite or CI runner still emits the in-band success markers a candidate can forge"
fi

# ...and the causal half is still required. The same cascade with its refusals
# removed is the ambient shape -- a candidate's own assertions failing inside a
# file it added -- and it charges.
csc_log "  FAIL: runners/csc-drive must exist and be executable
  FAIL: the boundary runners/csc-drive raised is not the one PROTOCOL.md names"
assert_eq "" "$(drive_exec_bit_causal runners/csc-drive \
    "  FAIL: runners/csc-drive must exist and be executable")" \
  "nothing in that output refuses to execute the runner, so nothing proves its mode bit blocked anything"
assert_eq candidate "$(csc_cls | cut -f1)" \
  "and naming a file with an unset mode bit is NOT attributing a failure to it: without one line that actually refused to execute it, the cascade rule would forgive every assertion that fails inside any mode-644 file a candidate touches"

# --- identity: neither a prefix nor an arbitrary suffix is the same file ---
CSC_HELPER="/bin/bash: bin/csc-tool-helper: Permission denied
  FAIL: bin/csc-tool-helper exited 126"
assert_eq "" "$(drive_exec_bit_attribution bin/csc-tool "$CSC_HELPER")" \
  "an outstanding bin/csc-tool must not collect a permission failure on bin/csc-tool-helper — a substring match waived that round, and the file it was really about was the candidate's own"
assert_eq "" "$(drive_exec_bit_attribution bin/csc-tool \
    "/bin/bash: bin/csc-tool.bak: Permission denied")" \
  "nor one on bin/csc-tool.bak: the boundary is every character that can CONTINUE a path, extension included"
assert_eq "" "$(drive_exec_bit_attribution bin/csc-tool \
    "/bin/bash: bin/csc-tool/child: Permission denied")" \
  "and nor one on bin/csc-tool/child, which is a different file again — the environment arm alone treats a path under its artifact as that artifact, because its artifact is a DIRECTORY that is entirely absent (Part Y4), and that relaxation must not reach an arm whose artifact is a file"
CSC_SUFFIX="/bin/bash: fixtures/bin/csc-tool: Permission denied
  FAIL: fixtures/bin/csc-tool exited 126"
assert_eq "" "$(drive_exec_bit_attribution bin/csc-tool "$CSC_SUFFIX" "$CSC")" \
  "nor may the relative hand-off path suffix-match a distinct deeper file — a slash before bin/csc-tool is not identity unless the whole spelling is this verification root's absolute path"
csc_log "$CSC_HELPER"
assert_eq candidate "$(csc_cls | cut -f1)" \
  "so the round charges, with the hand-off state genuinely outstanding on a DIFFERENT file the whole time"
assert_match "attribution was not established" "$(csc_cls | cut -f2-)" \
  "and says so, rather than charging silently"

# The boundary admits every form a diagnostic really writes a path in, which is
# the direction it must not have narrowed in.
assert_eq 3 "$(drive_exec_bit_attribution bin/csc-tool \
    "/bin/bash: bin/csc-tool: Permission denied
/bin/bash: ./bin/csc-tool: Permission denied
/bin/bash: $CSC/bin/csc-tool: Permission denied
/bin/bash: bin/csc-tool-helper: Permission denied" "$CSC" | grep -c .)" \
  "the bare, the ./-prefixed and the absolute form all name the same file — punctuation around a path never has to be parsed off, and only the different file is excluded"
csc_log "$CSC_SUFFIX"
assert_eq candidate "$(csc_cls | cut -f1)" \
  "an outstanding bin/csc-tool does not waive a candidate permission failure on fixtures/bin/csc-tool — exact path identity, not a matching suffix, decides the round"

# ===========================================================================
# Part N2b -- the stale-pin hand-off, RUN rather than read.
#
# T014 burned three attempts on a stale Formula/orchid.rb it could not re-pin.
# What makes that a hand-off is not the sentence the failure printed; it is
# that the pin is stale, which is a question the repository's own freshness
# check answers. So the driver runs it.
#
# RUNNING IT IS NOT THE SAME AS TRUSTING ITS EXIT STATUS, and that distinction
# is the whole of this part's second half. `scripts/pin-formula.sh --check`
# exits 1 when the checksum is stale AND when it cannot find the formula,
# cannot find a git checkout, or trips over packaging metadata -- and the last
# of those is something a CANDIDATE can do. Reading nonzero as staleness
# therefore handed this hand-off's amnesty to a class of candidate defect. So
# the check must positively REPORT a file stale, and that file must be one the
# repository tracks; anything else is no proof, and no proof charges.
#
# Four narrowings are asserted, all in the charging direction: the check must
# exist where the verification ran AND state how it is run, it must report
# staleness rather than merely fail, the candidate must not have CHANGED the
# check (a bug an implementer just introduced into a pinning script fails
# exactly like a stale pin, and that one is theirs), and a repository may
# switch the check out or turn the route off.
#
# THE EXEC BIT IS THE REPOSITORY'S CONVENTION, NOT ORCHID'S REQUIREMENT, and
# that is not a detail: orchid's own scripts/pin-formula.sh is tracked mode 644
# and invoked as `bash scripts/pin-formula.sh --check` everywhere it runs.
# Requiring `-x` therefore made this route DEAD IN THE REPOSITORY THAT SHIPS
# THE DEFAULT -- T014's stale pin, the case the route exists for, classified as
# `candidate` in orchid itself, and no per-repo configuration could have fixed
# it. So the fixture below ships its stand-in exactly as this repository ships
# the real one, at mode 644, and the route reads the `#!` line to run it the
# way its own repository does.
# ===========================================================================
assert_eq "" "$( ( HOME="$MACHINE_HOME"; config_get "$REPO_ROOT" handoff.pin_check ) )" \
  "this repository declares no handoff.pin_check either, so what follows is about the shipped default"
# The shipped default, as it actually sits in this checkout: whatever its mode,
# the route must have a way to invoke it. This is the assertion that would have
# caught the `-x` requirement, and it keeps holding if someone later chmods it.
if ! _drive_check_interp "$REPO_ROOT/scripts/pin-formula.sh" >/dev/null; then
  fail "orchid's own scripts/pin-formula.sh must be runnable by the pin route AS THIS REPOSITORY SHIPS IT (tracked mode 644, invoked as 'bash scripts/pin-formula.sh --check') — a route that cannot run the default it ships protects nobody from T014's case"
fi

PIN="$WORK/handoff-pin"
mkdir -p "$PIN/.orchid/tasks" "$PIN/.orchid/reviews" "$PIN/scripts"
cd "$PIN" || exit 1
git init -q .
# A stand-in for scripts/pin-formula.sh --check at the SHIPPED DEFAULT PATH and
# at the shipped MODE (644, `#!` line, no exec bit), so this proves the
# no-configuration claim about orchid as it really is, not about a fixture made
# convenient. It reports STALE, on stderr and in the real one's own words --
# naming the file it is stale ABOUT, which is what the waiver is attributed to.
# The real one builds a release archive, which a fixture must not.
PIN_PINNED_SHA='1111111111111111111111111111111111111111111111111111111111111111'
PIN_EXPECTED_SHA='2222222222222222222222222222222222222222222222222222222222222222'
PIN_SAYS="pin-formula: Formula/orchid.rb checksum is STALE for the current content
pin-formula:   pinned:   $PIN_PINNED_SHA
pin-formula:   expected: $PIN_EXPECTED_SHA
pin-formula: run scripts/pin-formula.sh and commit the formula change (Formula/ is export-ignored, so the archive bytes stay identical)"
printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$PIN_SAYS" > "$PIN/scripts/pin-formula.sh"
# The other branch, kept executable on purpose: a repository whose checks do
# carry the exec bit is run directly, with no interpreter prefix at all.
printf '#!/bin/sh\nexit 0\n' > "$PIN/scripts/pin-fresh.sh"
chmod +x "$PIN/scripts/pin-fresh.sh"
# The pinned file itself, TRACKED: a check may only report a file stale that
# the repository actually carries, because "re-pin that" has to name something
# an operator can re-pin.
mkdir -p "$PIN/Formula"
printf 'class Orchid < Formula\n  sha256 "deadbeef"\nend\n' > "$PIN/Formula/orchid.rb"
printf 'a\n' > "$PIN/a.txt"
# The alternative checks a later assertion points `handoff.pin_check` at, all
# committed into the BASE. They are TRACKED and PRE-CANDIDATE on purpose: the
# route reads a check as an authority only when the candidate recorded it and
# the verified worktree still carries exactly what was recorded, so an
# untracked stand-in would be refused at the door and every assertion below it
# would pass for a reason that has nothing to do with what it is testing.
# The first two are things orchid must decline to RUN, because neither the file
# nor the world says how:
printf 'exit 1\n' > "$PIN/scripts/pin-nohashbang.sh"           # states no interpreter
printf '#!/no/such/interpreter\nexit 1\n' > "$PIN/scripts/pin-badinterp.sh"
# And one that orchid CAN run and that fails without saying anything: a check
# whose exit status is real and whose words are absent proves nothing about
# WHY it is unhappy, and re-pinning is only the answer to one of those reasons.
printf '#!/bin/sh\nexit 1\n' > "$PIN/scripts/pin-silent.sh"
# THE CASE THIS PART'S SECOND HALF EXISTS FOR: the check failing for its OWN
# reasons rather than reporting staleness. Both exit 1, exactly as the real
# `scripts/pin-formula.sh` does through its `die` path, and the second is
# something a CANDIDATE can cause by corrupting the formula it edits.
printf '#!/bin/sh\necho "pin-formula: not a Git checkout: /x" >&2\nexit 1\n' \
  > "$PIN/scripts/pin-nogit.sh"
printf '#!/bin/sh\necho "pin-formula: Formula/orchid.rb is not valid Ruby (unterminated string on line 4)" >&2\nexit 1\n' \
  > "$PIN/scripts/pin-corrupt.sh"
# And one that says the right word about a file that is not in the tree: a
# staleness report has to name something an operator can act on.
printf '#!/bin/sh\necho "pin-formula: packaging/nowhere.rb checksum is STALE" >&2\nexit 1\n' \
  > "$PIN/scripts/pin-unknownfile.sh"
# A stateful freshness check for the pre/post boundary regression below. It is
# fresh until the verification command creates an untracked trigger, then
# prints the same attributable stale report as the shipped check. Inspecting it
# after the command would therefore let the candidate manufacture a waiver.
printf '#!/bin/sh\n[ ! -f .pin-stale-trigger ] || { echo "%s" >&2; exit 1; }\nexit 0\n' \
  "$PIN_SAYS" > "$PIN/scripts/pin-dynamic.sh"
git add scripts Formula/orchid.rb a.txt
git commit -q -m "fixture: base"
PIN_BASE="$(git -C "$PIN" rev-parse HEAD)"
printf 'b\n' > "$PIN/b.txt"
git add b.txt
git commit -q -m "fixture: a candidate that left the check alone"
PIN_CAND="$(git -C "$PIN" rev-parse HEAD)"
if [ -x "$PIN/scripts/pin-formula.sh" ]; then
  fail "fixture invariant broken: the stand-in must stay mode 644 like the real scripts/pin-formula.sh, or it stops proving the claim it is here for"
fi

# The verification output a repository whose suite RUNS the pin check actually
# produces -- this repository's own tests/test_ci_release.sh interpolates the
# check's output into its failure, which is what makes the tie provable.
PIN_FAILED_ON_IT="  FAIL: Formula/orchid.rb checksum is stale for the current tree -- $PIN_SAYS"
assert_eq 4 "$(drive_failure_lines "$PIN_FAILED_ON_IT" | grep -c .)" \
  "the fixture is the shipped four-line failure body, not the one-line approximation that left three real continuation records unaccounted for"
assert_eq 4 "$(drive_pin_attribution "Formula/orchid.rb" "$PIN_FAILED_ON_IT" "$PIN" | grep -c .)" \
  "after the path+stale causal line opens the pin route, it claims the shipped pinned, expected, and one-command-remedy records from that same CI failure"
assert_eq "" "$(drive_unattributed_failures "$PIN_FAILED_ON_IT" \
    "$(drive_pin_attribution "Formula/orchid.rb" "$PIN_FAILED_ON_IT" "$PIN")")" \
  "Orchid's own complete stale-pin body leaves no unknown continuation behind to make its hand-off waiver inert"
# ... and one that failed on something else entirely while the pin happened to
# be stale.
PIN_FAILED_ON_OTHER="tests/test_widget.sh: FAIL: widget returned 3, expected 4"

# mk_pin_task <id> <base> <cand> [verify-body]
mk_pin_task() {
  printf -- '---\nschema: 1\nid: %s\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$1" "$PIN" "$2" "$3" > "$PIN/.orchid/tasks/$1.md"
  mk_prestate_log "$PIN" "$PIN/.orchid/tasks/$1.md" \
    "$PIN/.orchid/reviews/$1-verify.log" "${4:-$PIN_FAILED_ON_IT}"
}
# pin_cls <id> [handoff.pin_check override]
pin_cls() {
  ( HOME="$MACHINE_HOME"
    pin_body="$(_drive_verify_body "$PIN/.orchid/reviews/$1-verify.log")"
    if [ "$#" -ge 2 ]; then
      export ORCHID_HANDOFF_PIN_CHECK="$2"
    fi
    # Each ordinary assertion arranges the state that exists BEFORE its
    # simulated verifier command, so snapshot it here. P09 below is the one
    # deliberate post-command mutation and calls drive_verify_class directly
    # over the stored earlier snapshot instead of coming through this helper.
    mk_prestate_log "$PIN" "$PIN/.orchid/tasks/$1.md" \
      "$PIN/.orchid/reviews/$1-verify.log" "$pin_body"
    drive_verify_class "$PIN" "$PIN/.orchid/tasks/$1.md" "$PIN/.orchid/reviews/$1-verify.log" )
}
mk_pin_task P01 "$PIN_BASE" "$PIN_CAND"

assert_eq "scripts/pin-formula.sh --check
Formula/orchid.rb" "$( ( HOME="$MACHINE_HOME"
  drive_handoff_stale_pin "$PIN" "$PIN" "$PIN/.orchid/tasks/P01.md" ) )" \
  "the pin route's own answer is the command an operator re-runs and THE FILE it reported stale — a waiver with no file to attribute it to is not a waiver, and this is the layer that would fail silently if it broke"

assert_eq handoff "$(pin_cls P01 | cut -f1)" \
  "T014's case, decided by running the check: a mode-644 check at the shipped default path is run under its own #! interpreter, it reports Formula/orchid.rb stale in this tree, the failure names that file and calls it stale too, and re-pinning is the operator's"
assert_match "scripts/pin-formula.sh --check" "$(pin_cls P01 | cut -f2-)" \
  "and the reason names the check that proved it, so an operator can run the same command"
assert_match "Formula/orchid.rb" "$(pin_cls P01 | cut -f2-)" \
  "and names the file to re-pin, because a reason an operator cannot act on is not a reason"
assert_match "L017" "$(pin_cls P01 | cut -f2-)" \
  "and says whose step it is, citing the rule that forbids the implementer to take it"

mk_pin_task P01 "$PIN_BASE" "$PIN_CAND" "$PIN_FAILED_ON_IT
pin-formula: mirror upload deferred"
assert_eq candidate "$(pin_cls P01 | cut -f1)" \
  "an unfamiliar fourth-party pin continuation remains unknown and charges even beside the exact shipped four-line report"
assert_match "mirror upload deferred" "$(pin_cls P01 | cut -f2-)" \
  "with the charged reason naming the continuation the narrow shipped vocabulary did not claim"
mk_pin_task P01 "$PIN_BASE" "$PIN_CAND"

# --- THE CANDIDATE THAT WROTE THE CHECK GETS NOTHING FROM IT ---------------
# In its OWN repository, so the tree it is judged in really is the tree its
# candidate recorded. That matters more than it looks: the authority rule below
# closes the route on a check the worktree carries in any state but the
# recorded one, and reusing one checkout for two candidates would close it for
# THAT reason instead — leaving this assertion green while proving nothing
# about who wrote the check. The check here says the SAME words as P01's, so
# what separates them is only ever "did this candidate change the check?" and
# never how loudly the check complains.
PINT="$WORK/handoff-pin-touched"
mkdir -p "$PINT/.orchid/tasks" "$PINT/.orchid/reviews" "$PINT/scripts" "$PINT/Formula"
cd "$PINT" || exit 1
git init -q .
: > "$PINT/orchid.config"
printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$PIN_SAYS" > "$PINT/scripts/pin-formula.sh"
printf 'class Orchid < Formula\n  sha256 "deadbeef"\nend\n' > "$PINT/Formula/orchid.rb"
git add scripts/pin-formula.sh Formula/orchid.rb
git commit -q -m "fixture: base, with a check that reports the pin stale"
PINT_BASE="$(git -C "$PINT" rev-parse HEAD)"
printf '#!/bin/sh\n# the implementer edited the pinning script itself\necho "%s" >&2\nexit 1\n' \
  "$PIN_SAYS" > "$PINT/scripts/pin-formula.sh"
git add scripts/pin-formula.sh
git commit -q -m "fixture: a candidate that changed the check itself"
PINT_CAND="$(git -C "$PINT" rev-parse HEAD)"
printf -- '---\nschema: 1\nid: P02\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$PINT" "$PINT_BASE" "$PINT_CAND" > "$PINT/.orchid/tasks/P02.md"
mk_prestate_log "$PINT" "$PINT/.orchid/tasks/P02.md" \
  "$PINT/.orchid/reviews/P02-verify.log" "$PIN_FAILED_ON_IT"
assert_eq "" "$( ( HOME="$MACHINE_HOME"
  drive_handoff_stale_pin "$PINT" "$PINT" "$PINT/.orchid/tasks/P02.md" ) )" \
  "the route yields no answer at all over a check this candidate wrote — asserted at the layer it lives in, because the class below would read 'candidate' just as readily if the check had simply not run"
assert_eq candidate "$( ( HOME="$MACHINE_HOME"
  drive_verify_class "$PINT" "$PINT/.orchid/tasks/P02.md" \
    "$PINT/.orchid/reviews/P02-verify.log" ) | cut -f1)" \
  "so a candidate that CHANGED the pinning script gets no amnesty from it — a bug just introduced into a check fails exactly like a stale pin, and prints exactly what a stale pin prints, and that one is the implementer's"
cd "$PIN" || exit 1

# --- AND THE AUTHORITY QUESTION FAILS CLOSED WHEN IT CANNOT BE ASKED -------
# The narrowing above is only worth what it costs to SKIP, and skipping it was
# free: "git says this candidate did not touch the check" and "I could not ask
# git" are the same empty diff, and the route read both as permission. A task
# file with no `base_sha`, or one naming a commit this tree does not carry --
# the shape a re-pointed branch or a reaped worktree really produces -- handed
# the amnesty back over a check the candidate may well have written. Both edges
# are pinned per L034: every unanswerable form charges, and the answerable
# untouched one still waives.
mk_pin_task P06 "" "$PIN_CAND"
assert_eq candidate "$(pin_cls P06 | cut -f1)" \
  "with no base_sha there is no way to ask whether this candidate wrote the check that would forgive it, and an unanswerable authority question is not permission"
mk_pin_task P07 "$PIN_BASE" ""
assert_eq candidate "$(pin_cls P07 | cut -f1)" \
  "and with no candidate_sha either — the guard needs both ends of the diff, and one end is no more an answer than none"
mk_pin_task P08 "$PIN_BASE" 0000000000000000000000000000000000000000
assert_eq candidate "$(pin_cls P08 | cut -f1)" \
  "and a sha that does not RESOLVE in this tree answers nothing, which is the form the failure actually takes: the fields are present, so a guard that only checked for emptiness would walk straight past it"
assert_eq handoff "$(pin_cls P01 | cut -f1)" \
  "while the answerable, untouched case is untouched itself — the guard closes the route on ignorance, never on the route"

# --- AND THE AUTHORITY IS THE FILE THAT RAN, NOT A DIFF OF TWO COMMITS -----
# `base..candidate` answers a question about two COMMITS. What this route
# actually EXECUTES is the file in the worktree the verification ran in, and
# those come apart in every direction that matters — none of which appears in
# that diff at all:
#
#   an edit left UNSTAGED, or STAGED and not committed: the check that runs is
#     the edited one, and the diff of two commits is empty;
#   a file the candidate never recorded: an UNTRACKED `scripts/pin-formula.sh`
#     dropped into the worktree is in no diff either, and is entirely the
#     implementer's to have written;
#   a file that is MISSING, or whose MODE has moved, so what runs is not what
#     was recorded even where the bytes are.
#
# Each of them is a way to hand the driver a check the candidate controls while
# leaving `base..candidate` clean, so each closes the route and charges. The
# answerable, intact case is restored after every one of them, so this is a
# guard rather than a deletion.
# The check's committed bytes, written by the same printf that created it, so
# "restored" means byte-identical to what the candidate recorded rather than
# approximately the same.
pin_check_restore() {
  printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$PIN_SAYS" > "$PIN/scripts/pin-formula.sh"
}

printf '#!/bin/sh\n# edited in the worktree and never committed\necho "%s" >&2\nexit 1\n' \
  "$PIN_SAYS" > "$PIN/scripts/pin-formula.sh"
assert_eq candidate "$(pin_cls P01 | cut -f1)" \
  "an UNSTAGED edit to the check closes the route: the file that runs is the implementer's, the diff of two commits cannot see it, and a check the candidate is editing is no authority on the candidate"
git -C "$PIN" add scripts/pin-formula.sh
pin_check_restore
assert_eq candidate "$(pin_cls P01 | cut -f1)" \
  "and so does a STAGED one whose worktree copy has been put back — the bytes on disk match the candidate again, but the index does not, and a change one commit away from being the candidate's is not the candidate's authority"
git -C "$PIN" add scripts/pin-formula.sh
assert_eq handoff "$(pin_cls P01 | cut -f1)" \
  "while restoring both ends restores the route, which is what makes the two assertions above a guard rather than a deletion"

git -C "$PIN" rm -q --cached scripts/pin-formula.sh
assert_eq candidate "$(pin_cls P01 | cut -f1)" \
  "an UNTRACKED check is no authority either: the candidate recorded nothing about it, so nothing can establish that it was not the implementer who put it there"
git -C "$PIN" add scripts/pin-formula.sh
mv "$PIN/scripts/pin-formula.sh" "$PIN/scripts/pin-formula.sh.away"
assert_eq candidate "$(pin_cls P01 | cut -f1)" \
  "and a check MISSING from the verified worktree answers nothing at all"
mv "$PIN/scripts/pin-formula.sh.away" "$PIN/scripts/pin-formula.sh"
chmod +x "$PIN/scripts/pin-formula.sh"
assert_eq candidate "$(pin_cls P01 | cut -f1)" \
  "and a MODE that has moved closes it too — the recorded 644 is invoked under the interpreter its #! line names and an executable copy is invoked directly, so 'the same bytes' is not the same check being run"
chmod -x "$PIN/scripts/pin-formula.sh"
assert_eq handoff "$(pin_cls P01 | cut -f1)" \
  "and every one of those restores to the route it started from"

# --- A NONZERO EXIT IS NOT A STALENESS REPORT ------------------------------
# The narrowing this round exists for. `scripts/pin-formula.sh --check` exits 1
# when the checksum is stale AND when it dies for its own reasons -- no git
# checkout, no formula, a formula the CANDIDATE just made unparseable. Only the
# first is fixed by re-pinning, so only the first may waive; reading the exit
# status alone handed a candidate a way to buy an amnesty by corrupting the
# very file the check reads.
assert_eq candidate "$(pin_cls P01 'scripts/pin-nogit.sh --check' | cut -f1)" \
  "a check that fails because it could not RUN reports no staleness, and re-pinning would fix nothing — so the round charges"
assert_eq candidate "$(pin_cls P01 'scripts/pin-corrupt.sh --check' | cut -f1)" \
  "and a check that fails on a formula this candidate made unparseable is the CANDIDATE's failure: it exits exactly as a stale pin does, which is why the exit status may not be what decides"
assert_eq candidate "$(pin_cls P01 'scripts/pin-unknownfile.sh --check' | cut -f1)" \
  "and staleness reported about a file the repository does not track proves nothing an operator can act on — the file is required as well as the word"

# --- THE PIN'S ATTRIBUTION: the failure must name that file, and call it
# stale ---------------------------------------------------------------------
# A stale pin is outstanding on the WHOLE TREE for as long as it is stale, so
# it is the more ambient of the two hand-offs, not the less: every failure in
# the repository coincides with it. What separates a round that failed ON it
# from a round that merely failed BESIDE it is whether the verification said
# so about that file.
mk_pin_task P03 "$PIN_BASE" "$PIN_CAND" "$PIN_FAILED_ON_OTHER"
assert_eq candidate "$(pin_cls P03 | cut -f1)" \
  "the pin is stale and the suite failed on a widget assertion instead: this verification never ran the check, so a stale pin is not what failed here"
assert_match "attribution was not established" "$(pin_cls P03 | cut -f2-)" \
  "and the reason says so, naming the outstanding hand-off without hiding behind it"

mk_pin_task P04 "$PIN_BASE" "$PIN_CAND" "$PIN_FAILED_ON_IT
$PIN_FAILED_ON_OTHER"
assert_eq candidate "$(pin_cls P04 | cut -f1)" \
  "and a round that failed on the stale pin AND on a widget assertion is charged: the hand-off waives its own failure, never the defect that landed beside it"
assert_match "further failing line" "$(pin_cls P04 | cut -f2-)" \
  "saying how much of the round the hand-off did not account for"

# The round that names the file without ever calling it stale: a suite that
# happens to touch Formula/orchid.rb while the pin is genuinely stale. Naming
# is the cascade rule, and the cascade needs a causal line before it opens.
mk_pin_task P05 "$PIN_BASE" "$PIN_CAND" \
  "  FAIL: Formula/orchid.rb must declare a bottle block"
assert_eq candidate "$(pin_cls P05 | cut -f1)" \
  "a failure that NAMES the pinned file without saying anything is stale is the candidate's — naming alone is what every assertion about a file does, and it is exactly how an ambient hand-off launders a defect"

assert_eq candidate "$(pin_cls P01 'scripts/pin-silent.sh --check' | cut -f1)" \
  "a check that fails and says NOTHING proves nothing: an exit status alone cannot say whether re-pinning is the fix, and it names no file to attribute a waiver to"

assert_eq candidate "$(pin_cls P01 'scripts/pin-fresh.sh --check' | cut -f1)" \
  "a check that reports FRESH forgives nothing: the route fires on the world's answer, not on the route existing — and this one is executable, so it is run directly, with no interpreter prefix"
assert_eq candidate "$(pin_cls P01 none | cut -f1)" \
  "handoff.pin_check=none turns the route off even with the check failing"
assert_eq candidate "$(pin_cls P01 'scripts/not-here.sh --check' | cut -f1)" \
  "a check that is not there answers nothing, and an unanswered question charges"
assert_eq candidate "$(pin_cls P01 'scripts/pin-nohashbang.sh --check' | cut -f1)" \
  "a check that is neither executable nor states an interpreter is never run — the invocation comes from the file itself, never from a guess, so an unrunnable check stays 'no pin route' instead of becoming a nonzero exit read as staleness"
assert_eq candidate "$(pin_cls P01 'scripts/pin-badinterp.sh --check' | cut -f1)" \
  "and neither is one whose #! names an interpreter that is not there — same silence, same charge"

# --- THE CANDIDATE CANNOT CREATE STALENESS AFTER THE SNAPSHOT -------------
# Snapshot the dynamic check while it is fresh, then simulate the verification
# command creating release dirt before the verifier writes its final log. The
# live post-run check now reports the exact hand-off shape, which is what the
# old classifier trusted. The recorded pre-run empty value must win.
mk_pin_task P09 "$PIN_BASE" "$PIN_CAND" "$PIN_FAILED_ON_IT"
P09_PRE="$( ( HOME="$MACHINE_HOME"
  export ORCHID_HANDOFF_PIN_CHECK='scripts/pin-dynamic.sh --check'
  drive_verify_prestate_headers "$PIN" "$PIN/.orchid/tasks/P09.md" ) )"
: > "$PIN/.pin-stale-trigger"
P09_POST="$( ( HOME="$MACHINE_HOME"
  export ORCHID_HANDOFF_PIN_CHECK='scripts/pin-dynamic.sh --check'
  drive_handoff_stale_pin "$PIN" "$PIN" "$PIN/.orchid/tasks/P09.md" ) )"
assert_match "Formula/orchid.rb" "$P09_POST" \
  "fixture: after the simulated candidate command dirties release inputs, a post-run freshness check really would report a waivable stale pin"
mk_prestate_log "$PIN" "$PIN/.orchid/tasks/P09.md" \
  "$PIN/.orchid/reviews/P09-verify.log" "$PIN_FAILED_ON_IT" \
  "bash tests/run.sh" 1 "$P09_PRE"
assert_eq "" "$(_drive_verify_prestate_list "$PIN" \
    "$PIN/.orchid/tasks/P09.md" "$PIN/.orchid/reviews/P09-verify.log" pin)" \
  "the trusted pre-command snapshot remains fresh even though live post-run state is now stale"
assert_eq candidate "$( ( HOME="$MACHINE_HOME"
  drive_verify_class "$PIN" "$PIN/.orchid/tasks/P09.md" \
    "$PIN/.orchid/reviews/P09-verify.log" ) | cut -f1)" \
  "so a candidate cannot dirty release content during its own failing test and manufacture a stale-pin hand-off waiver"
rm -f "$PIN/.pin-stale-trigger"

# ===========================================================================
# Part N2e -- TWO hand-offs outstanding, each to blame for part of one round.
#
# The round that used to be charged with nothing in it that was the
# candidate's. Attribution stopped at the FIRST artifact it could blame and
# then required that one to account for the whole output — so a round in which
# a stale pin explained one failure and a dropped mode bit explained another
# was charged in full, and an operator who owned every line of it read that the
# implementer had failed.
#
# Per-failure attribution has no such notion of a winning artifact: each claims
# the failures it explains, and what is left unclaimed is what decides. The
# negative case is asserted immediately after, because pooling must not become
# a way for two partial explanations to cover a third failure neither owns.
# ===========================================================================
MIX="$WORK/handoff-mixed"
mkdir -p "$MIX/.orchid/tasks" "$MIX/.orchid/reviews" "$MIX/scripts" "$MIX/libexec"
cd "$MIX" || exit 1
git init -q .
MIX_SAYS='pin-formula: Formula/orchid.rb checksum is STALE for the current content'
printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$MIX_SAYS" > "$MIX/scripts/pin-formula.sh"
mkdir -p "$MIX/Formula"
printf 'class Orchid < Formula\n  sha256 "deadbeef"\nend\n' > "$MIX/Formula/orchid.rb"
printf 'fixture\n' > "$MIX/README"
git add scripts/pin-formula.sh Formula/orchid.rb README
git commit -q -m "fixture: base, with a check that reports the pin stale"
MIX_BASE="$(git -C "$MIX" rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho mix\n' > "$MIX/libexec/orchid-mix"
git add libexec/orchid-mix
git commit -q -m "fixture: a candidate that ships a new verb at mode 644"
MIX_CAND="$(git -C "$MIX" rev-parse HEAD)"

printf -- '---\nschema: 1\nid: X01\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$MIX" "$MIX_BASE" "$MIX_CAND" > "$MIX/.orchid/tasks/X01.md"
mix_log() {
  mk_prestate_log "$REPO_ROOT" "$MIX/.orchid/tasks/X01.md" \
    "$MIX/.orchid/reviews/X01-verify.log" "$1"
}
mix_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$REPO_ROOT" "$MIX/.orchid/tasks/X01.md" \
      "$MIX/.orchid/reviews/X01-verify.log" )
}
MIX_BODY="  FAIL: release checksum gate — $MIX_SAYS
/bin/bash: libexec/orchid-mix: Permission denied"

assert_eq 1 "$(drive_unattributed_failures "$MIX_BODY" \
    "$(drive_exec_bit_attribution libexec/orchid-mix "$MIX_BODY")" | grep -c .)" \
  "the mode bit explains its own refusal and leaves the pin's failure unexplained, so on its own it can never waive this round"
mix_log "$MIX_BODY"
assert_eq handoff "$(mix_cls | cut -f1)" \
  "but between them the two hand-offs account for every failing line, and a round in which nothing was the candidate's charges the candidate nothing"
MIX_REASON="$(mix_cls | cut -f2-)"
assert_match "orchid-mix" "$MIX_REASON" \
  "with BOTH outstanding steps named — an operator who clears one, re-dispatches, and walks into the other has learned nothing from the first journal line"
assert_match "scripts/pin-formula.sh --check" "$MIX_REASON" \
  "the pin check included, by the command line they can run themselves"
assert_match "Formula/orchid.rb" "$MIX_REASON" \
  "and the file it reported stale, which is the one they re-pin"

mix_log "$MIX_BODY
tests/test_widget.sh: FAIL: widget returned 3, expected 4"
assert_eq candidate "$(mix_cls | cut -f1)" \
  "and one more failing line that neither hand-off owns charges the round: pooling is not a way for two partial explanations to cover a third failure that is the candidate's"
assert_match "widget returned 3" "$(mix_cls | cut -f2-)" \
  "quoting the line nobody accounted for"

# ===========================================================================
# Part N2c -- attribution asserted at the layer it lives in.
#
# A break in any of these layers is invisible in a class assertion: everything
# simply charges, which is exactly what the strict default looks like when it
# is working. So each is asserted directly, and a break says which one broke.
# ===========================================================================
# One body carrying every shape at once: a runner progress line, a progress
# line for a file whose NAME contains "fail", an ordinary assertion failure, a
# lower-case failure of the kind another language's harness prints, a shell
# refusal, and a passing file's own summary.
ATT_BODY="== tests/test_failover.sh
== tests/test_frob.sh
  FAIL: frob returned 3, expected 4
1 failed, 42 passed in 3.10s
bash: ./libexec/orchid-frob: Permission denied
infra_failures: 0
  red-cases: 2 demonstrated in this file (green-cases: 2)"

assert_eq 3 "$(drive_failure_lines "$ATT_BODY" | grep -c .)" \
  "exactly three of those seven lines report a failure — the count is what decides whether a hand-off explains the whole round, so both over- and under-counting decide rounds wrongly"
if ! drive_failure_lines "$ATT_BODY" | grep -Fq "1 failed"; then
  fail "a lower-case 'failed' summary IS a failure line: missing it is the direction that laundered a real defect beside an attributed hand-off, which is the whole reason this check exists"
fi
if drive_failure_lines "$ATT_BODY" | grep -Fq "infra_failures"; then
  fail "and orchid's own 'infra_failures:' counter is NOT one — the word boundary excludes '_' exactly so a line orchid itself prints in status output cannot leave every round with an unexplained failure"
fi
if drive_failure_lines "$ATT_BODY" | grep -Fq "test_failover"; then
  fail "the runner's own progress line for tests/test_failover.sh must not read as a failure: a failure oracle that fires on every run leaves an unexplained line in EVERY round, and no hand-off is ever waived again"
fi
if ! drive_failure_lines "$ATT_BODY" | grep -Fq "Permission denied"; then
  fail "and a raw shell refusal IS a failure line: an unexplained refusal about some other path is something this round must be charged for"
fi

assert_eq "bash: ./libexec/orchid-frob: Permission denied" \
  "$(drive_exec_bit_attribution "libexec/orchid-frob" "$ATT_BODY")" \
  "the refusal line and only the refusal line: the path is matched inside it, so the ./ prefix and the punctuation around it never have to be parsed off"
assert_eq "" "$(drive_exec_bit_attribution "tests/test_frob.sh" "$ATT_BODY")" \
  "and a file this output NAMES but never refuses to execute attributes nothing — this is the ambient case, where a candidate adds a mode-644 file with a #! line and then fails an ordinary assertion inside it"

assert_eq "  FAIL: frob returned 3, expected 4
1 failed, 42 passed in 3.10s" \
  "$(drive_unattributed_failures "$ATT_BODY" \
      "$(drive_exec_bit_attribution "libexec/orchid-frob" "$ATT_BODY")")" \
  "with the refusal attributed, the two failure reports that remain are unexplained — their presence is what charges the round"
assert_eq "" "$(drive_unattributed_failures "$ATT_BODY" "$(drive_failure_lines "$ATT_BODY")")" \
  "and an attribution covering every failing line leaves nothing, which is the only state a waiver is admissible in"

# --- and the PIN's two layers, in the same body ----------------------------
# The pin's causal shape is "this file is stale", exactly as the exec bit's is
# "this file could not be executed". Both are asserted here against a body that
# contains neither, because the mistake that matters is a rule that claims a
# line it has no business claiming.
PIN_BODY="  FAIL: Formula/orchid.rb checksum is stale for the current tree
  FAIL: Formula/orchid.rb must declare a bottle block
  FAIL: frob returned 3, expected 4"
assert_eq "  FAIL: Formula/orchid.rb checksum is stale for the current tree" \
  "$(drive_pin_causal "Formula/orchid.rb" "$PIN_BODY")" \
  "one line both names the pinned file and calls it stale — that is the causal proof, and the only thing that opens the cascade"
assert_eq 2 "$(drive_pin_attribution "Formula/orchid.rb" "$PIN_BODY" | grep -c .)" \
  "after which the bottle-block failure, which names the same file, is part of the same cascade: one stale pin does not fail one check"
assert_eq "" "$(drive_pin_attribution "Formula/orchid.rb" \
    "  FAIL: Formula/orchid.rb must declare a bottle block")" \
  "but naming the file without ever calling it stale claims NOTHING — the cascade rule may never open on its own"
assert_eq "" "$(drive_pin_attribution "Formula/orchid.rb" "$ATT_BODY")" \
  "and a body that never mentions the pinned file at all attributes nothing, however stale the pin really is"
assert_eq "" "$(drive_pin_attribution "Formula/orchid.rb" \
    "  FAIL: fixtures/Formula/orchid.rb checksum is stale" "$MIX")" \
  "a stale pin diagnostic for a distinct deeper path is not this repository's Formula/orchid.rb merely because its relative name is a suffix"
assert_eq "  FAIL: $MIX/Formula/orchid.rb checksum is stale" \
  "$(drive_pin_causal "Formula/orchid.rb" \
      "  FAIL: $MIX/Formula/orchid.rb checksum is stale" "$MIX")" \
  "while the exact verification-root absolute spelling still identifies the pin without weakening relative-path identity"

# ===========================================================================
# Part N3 -- the evidence attribution is decided against is the verification
# command's output, trimmed of exactly ONE line.
#
# `orchid verify` appends a trailing `exit: N`. A test suite is entitled to
# print that text itself -- this file's own fixtures do -- and deleting every
# such line would rewrite the evidence, dropping real output out of the body
# attribution is decided against. The HEADER is excluded for the opposite
# reason: it carries `command:` verbatim, so a path named there would be found
# in every failure that repository ever produces.
# ===========================================================================
BODYLOG="$WORK/body-verify.log"
printf 'date: 2026-08-10T00:00:00Z\nsha: deadbeef\ncandidate: deadbeef\ncwd: /x\ncommand: bash tests/run.sh\n---\ncase A: the verb under test printed exit: 0\nassertion failed: widget count\nexit: 1\n' \
  > "$BODYLOG"
BODY_OUT="$(_drive_verify_body "$BODYLOG")"
assert_match "printed exit: 0" "$BODY_OUT" \
  "a line the SUITE printed that happens to contain 'exit: N' stays in the body — only the verb's own trailer is the verb's to remove"
assert_eq "assertion failed: widget count" "$(printf '%s\n' "$BODY_OUT" | tail -n1)" \
  "and the trailing trailer is gone, so orchid's own bookkeeping is never read as evidence"
case "$BODY_OUT" in
  *"command: bash tests/run.sh"*) fail "the log HEADER leaked into the matched body: $BODY_OUT" ;;
esac

printf 'date: 2026-08-10T00:00:00Z\nsha: deadbeef\ncandidate: deadbeef\ncwd: /x\ncommand: bash tests/run.sh\n---\nexit: 1\n' \
  > "$BODYLOG"
assert_eq "" "$(_drive_verify_body "$BODYLOG")" \
  "a verification that printed nothing at all yields an empty body, not the trailer"

# ===========================================================================
# Part N4 -- a refused advance must not spend environment budget either.
#
# `infra_failures` is a budget with its own auto-block. Charging it before the
# archetype is known to declare a testing -> rework edge means a task that
# CANNOT advance still pays, which is the same "charged for something that is
# not the candidate" mistake this feature exists to end, one budget over.
# ===========================================================================
CLN="$WORK/classify-noedge"
mkdir -p "$CLN"
cd "$CLN" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CLN" "$ORCHID_BIN" init >/dev/null || fail "orchid init (no-edge fixture)"
git checkout -q orchid/integration
CNEPOCH="$(ORCHID_REPO="$CLN" "$ORCHID_BIN" run start | sed 's/epoch: //')"
CNARCH="$WORK/arch-noedge"
mkdir -p "$CNARCH/noedge"
# A code archetype that satisfies the meta-contract and simply declares no
# testing -> rework edge.
printf 'manifest_version=1\nid=test/noedge\nversion=0.1.0\nkind=archetype\napi_version=1\noutcome=code\ntransitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done\n' \
  > "$CNARCH/noedge/plugin.conf"
cnorchid() {
  ORCHID_REPO="$CLN" ORCHID_EPOCH="$CNEPOCH" ORCHID_ARCHETYPES_DIR="$CNARCH" "$ORCHID_BIN" "$@"
}
cnorchid requirements import "$WORK/requirements.md" >/dev/null
cnorchid task create C500 "its archetype cannot go to rework at all" --archetype noedge >/dev/null
# This part is about the ORDER of the edge check and the charge, not about
# which class was decided, so it uses the cheapest hand-off there is: a new
# verb at mode 644, and a suite that reports the shell refusing it.
cnorchid task set C500 verification_commands \
  "echo /bin/bash: libexec/orchid-cn: Permission denied; exit 1" >/dev/null
cnorchid plan apply --reason "initial plan" >/dev/null

CNBASE="$(git -C "$CLN" rev-parse HEAD)"
mkdir -p "$CLN/libexec"
printf '#!/usr/bin/env bash\necho cn\n' > "$CLN/libexec/orchid-cn"
git -C "$CLN" add libexec/orchid-cn
git -C "$CLN" commit -q -m "fixture: a candidate that ships a new verb at mode 644"
CNCAND="$(git -C "$CLN" rev-parse HEAD)"
fm_set "$CLN/.orchid/tasks/C500.md" status testing
fm_set "$CLN/.orchid/tasks/C500.md" base_sha "$CNBASE"
fm_set "$CLN/.orchid/tasks/C500.md" candidate_sha "$CNCAND"

CN_RC=0
CN_OUT="$(ORCHID_REPO="$CLN" ORCHID_EPOCH="$CNEPOCH" ORCHID_ARCHETYPES_DIR="$CNARCH" "$DRIVE" 2>&1)" || CN_RC=$?
[ "$CN_RC" -eq 0 ] || [ "$CN_RC" -eq 16 ] \
  || fail "the no-edge pass must end at a boundary, not an error (rc=$CN_RC): $CN_OUT"

cnfield() { ORCHID_REPO="$CLN" ORCHID_ARCHETYPES_DIR="$CNARCH" "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }
assert_eq testing "$(cnfield C500 status)" \
  "with no testing -> rework edge declared the task does not move (out: $CN_OUT)"
assert_eq 0 "$(cnfield C500 attempts)" \
  "and spends no attempt"
assert_eq 0 "$(cnfield C500 infra_failures)" \
  "and no environment budget either: the edge is checked BEFORE anything is charged, so a refused advance costs nothing"
assert_match "declares no testing -> rework edge" "$CN_OUT" \
  "the pass stops at a named boundary saying exactly what is missing"
CN_JOURNAL="$(cat "$CLN/.orchid/journal.md")"
assert_match "C500 note" "$CN_JOURNAL" \
  "the missing-edge path writes a task-scoped durable note before stopping — it never reaches task advance's attempt_waiver journal"
assert_match "handoff, attempt not charged" "$CN_JOURNAL" \
  "and that note explicitly says the non-candidate round did not charge an attempt, rather than leaving an operator to infer it from a counter"

# The strict twin: the same missing edge cannot turn a CANDIDATE failure into
# a free round. Clear the first pass's boundary through the public verb, leave
# the same task and candidate in testing, and make its verifier fail on an
# unrelated assertion that none of the positive-evidence waiver routes owns.
cnorchid run boundary clear --reason "fixture: exercise the strict no-edge twin"
cnorchid task set C500 verification_commands \
  "echo tests/test_widget.sh: FAIL: widget mismatch; exit 1" >/dev/null
CN_STRICT_RC=0
CN_STRICT_OUT="$(ORCHID_REPO="$CLN" ORCHID_EPOCH="$CNEPOCH" ORCHID_ARCHETYPES_DIR="$CNARCH" "$DRIVE" 2>&1)" || CN_STRICT_RC=$?
[ "$CN_STRICT_RC" -eq 16 ] \
  || fail "the candidate no-edge pass must stop at its charged blocked boundary (rc=$CN_STRICT_RC): $CN_STRICT_OUT"
assert_eq blocked "$(cnfield C500 status)" \
  "a candidate failure with no rework edge takes the universal blocked fallback (out: $CN_STRICT_OUT)"
assert_eq 1 "$(cnfield C500 attempts)" \
  "and the missing archetype edge does not make that candidate round free"
assert_eq 0 "$(cnfield C500 infra_failures)" \
  "the strict candidate arm charges attempts, never the environment ladder"
CN_STRICT_JOURNAL="$(cat "$CLN/.orchid/journal.md")"
assert_match "candidate attempt #1 charged while blocking" "$CN_STRICT_JOURNAL" \
  "the no-edge fallback records the exact charge durably"
assert_match "declares no testing -> rework edge" "$CN_STRICT_JOURNAL" \
  "and records why the charged round had to stop instead of entering rework"
assert_match "attempt charged.*testing -> blocked" "$CN_STRICT_OUT" \
  "the pass reports a charged state move rather than activity with no accounting"
assert_match "task retry C500" "$CN_STRICT_OUT" \
  "the resulting boundary names the supported route back through rework"
assert_match "task reverify C500" "$CN_STRICT_OUT" \
  "and also names the supported exact-candidate verification route"

# The other half of the review finding is a DECLARED rework edge whose verb
# refuses before charging. Make that refusal deterministic with a real live
# verb-lock: the verifier waits on a sentinel, the fixture acquires the lock,
# and the first task advance exhausts the one-second wait. As soon as its
# refusal is visible, the fixture releases the lock, so the charge-and-block
# fallback can acquire it and complete. No production test seam is involved.
CLR="$WORK/classify-refused-rework"
mkdir -p "$CLR"
cd "$CLR" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nverb_lock_wait_s=1\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CLR" "$ORCHID_BIN" init >/dev/null || fail "orchid init (refused-rework fixture)"
git checkout -q orchid/integration
CLREPOCH="$(ORCHID_REPO="$CLR" "$ORCHID_BIN" run start | sed 's/epoch: //')"
clrorchid() { ORCHID_REPO="$CLR" ORCHID_EPOCH="$CLREPOCH" "$ORCHID_BIN" "$@"; }
clrorchid requirements import "$WORK/requirements.md" >/dev/null
clrorchid task create C501 "its declared rework edge refuses before charging" >/dev/null
clrorchid task set C501 verification_commands \
  "touch $CLR/verify-ready; while [ ! -f $CLR/verify-go ]; do sleep 0.05; done; echo tests/test_widget.sh: FAIL: widget mismatch; exit 1" >/dev/null
clrorchid plan apply --reason "initial plan" >/dev/null
CLRBASE="$(git -C "$CLR" rev-parse HEAD)"
printf 'candidate\n' > "$CLR/candidate.txt"
git -C "$CLR" add candidate.txt
git -C "$CLR" commit -q -m "fixture: candidate"
CLRCAND="$(git -C "$CLR" rev-parse HEAD)"
fm_set "$CLR/.orchid/tasks/C501.md" status testing
fm_set "$CLR/.orchid/tasks/C501.md" base_sha "$CLRBASE"
fm_set "$CLR/.orchid/tasks/C501.md" candidate_sha "$CLRCAND"

CLR_OUT_FILE="$WORK/classify-refused-rework.out"
CLR_RC=0
ORCHID_REPO="$CLR" ORCHID_EPOCH="$CLREPOCH" "$DRIVE" >"$CLR_OUT_FILE" 2>&1 &
CLR_DRIVE_PID=$!
CLR_WAIT=0
while [ ! -f "$CLR/verify-ready" ] && kill -0 "$CLR_DRIVE_PID" 2>/dev/null; do
  sleep 0.05
  CLR_WAIT=$((CLR_WAIT + 1))
  [ "$CLR_WAIT" -lt 200 ] || break
done
[ -f "$CLR/verify-ready" ] \
  || fail "the refused-rework verifier never reached its synchronization point: $(cat "$CLR_OUT_FILE" 2>/dev/null)"

CLR_RELEASE="$CLR/release-verb-lock"
CLR_LOCK_READY="$CLR/verb-lock-ready"
(
  unset ORCHID_VERB_LOCK_HELD
  verb_lock_acquire "$CLR"
  touch "$CLR_LOCK_READY"
  while [ ! -f "$CLR_RELEASE" ]; do sleep 0.05; done
  verb_lock_release "$CLR"
) &
CLR_LOCK_PID=$!
CLR_WAIT=0
while [ ! -f "$CLR_LOCK_READY" ] && kill -0 "$CLR_LOCK_PID" 2>/dev/null; do
  sleep 0.05
  CLR_WAIT=$((CLR_WAIT + 1))
  [ "$CLR_WAIT" -lt 200 ] || break
done
[ -f "$CLR_LOCK_READY" ] || fail "the refused-rework fixture could not acquire its live verb lock"
touch "$CLR/verify-go"

CLR_WAIT=0
while ! grep -q "another verb is mid-transaction" "$CLR_OUT_FILE" 2>/dev/null && \
      kill -0 "$CLR_DRIVE_PID" 2>/dev/null; do
  sleep 0.05
  CLR_WAIT=$((CLR_WAIT + 1))
  [ "$CLR_WAIT" -lt 200 ] || break
done
grep -q "another verb is mid-transaction" "$CLR_OUT_FILE" 2>/dev/null \
  || fail "the declared rework edge did not hit the deterministic verb-lock refusal: $(cat "$CLR_OUT_FILE" 2>/dev/null)"
touch "$CLR_RELEASE"
wait "$CLR_LOCK_PID" 2>/dev/null
wait "$CLR_DRIVE_PID" || CLR_RC=$?
CLR_OUT="$(cat "$CLR_OUT_FILE")"
[ "$CLR_RC" -eq 16 ] \
  || fail "the refused-rework pass must stop at its charged blocked boundary (rc=$CLR_RC): $CLR_OUT"
clrfield() { ORCHID_REPO="$CLR" "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }
assert_eq blocked "$(clrfield C501 status)" \
  "a pre-charge rework refusal falls back to blocked (out: $CLR_OUT)"
assert_eq 1 "$(clrfield C501 attempts)" \
  "and still consumes exactly one candidate attempt"
assert_eq 0 "$(clrfield C501 infra_failures)" \
  "a kernel transition refusal is not mischarged as an environment failure"
CLR_JOURNAL="$(cat "$CLR/.orchid/journal.md")"
assert_match "candidate attempt #1 charged while blocking" "$CLR_JOURNAL" \
  "the refused-edge fallback durably records the charge"
assert_match "after testing -> rework refused exit" "$CLR_JOURNAL" \
  "and records the refusal that forced the blocked path"
assert_match "attempt charged.*testing -> blocked after testing -> rework refused" "$CLR_OUT" \
  "the pass reports the refused edge's charged fallback"

# ===========================================================================
# Part N5 -- a waived failure that RECURS goes to a human, not to another
# identical re-dispatch.
#
# NO waivable class names a fault the IMPLEMENTER clears: a checksum is
# re-pinned by an operator, an exec bit set by one, a dependency tree
# provisioned by whoever dispatches, a quarantined assertion fixed in the test,
# and a killed run is nobody's to fix. Re-dispatching the implementer against
# any of them produces the very same failure, so grinding out the whole
# `infra_max` budget on retries that cannot work only delays the human by three
# rounds while the run looks busy. The first round still retries -- the fault
# may have been cleared between the two passes -- and the second stops.
#
# The count is ACROSS classes (drive_waived_rounds reads every `attempt_waiver`
# the driver wrote for this task, whatever it said): two rounds that told nobody
# anything about the candidate are two rounds, not one of each.
# ===========================================================================
CRE="$WORK/classify-recur"
mkdir -p "$CRE"
cd "$CRE" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CRE" "$ORCHID_BIN" init >/dev/null || fail "orchid init (recurrence fixture)"
git checkout -q orchid/integration
CREPOCH="$(ORCHID_REPO="$CRE" "$ORCHID_BIN" run start | sed 's/epoch: //')"
crorchid() { ORCHID_REPO="$CRE" ORCHID_EPOCH="$CREPOCH" "$ORCHID_BIN" "$@"; }
crorchid requirements import "$WORK/requirements.md" >/dev/null
crorchid task create C700 "its suite fails on the same unset mode bit twice" >/dev/null
crorchid task set C700 verification_commands \
  "echo /bin/bash: libexec/orchid-cr: Permission denied; exit 1" >/dev/null
crorchid plan apply --reason "initial plan" >/dev/null

CRBASE="$(git -C "$CRE" rev-parse HEAD)"
mkdir -p "$CRE/libexec"
printf '#!/usr/bin/env bash\necho cr\n' > "$CRE/libexec/orchid-cr"
git -C "$CRE" add libexec/orchid-cr
git -C "$CRE" commit -q -m "fixture: a candidate that ships a new verb at mode 644"
CRCAND="$(git -C "$CRE" rev-parse HEAD)"
crfield() { ORCHID_REPO="$CRE" "$ORCHID_BIN" task show C700 | grep "^$1: " | cut -d' ' -f2-; }
CR_RC=0; CR_OUT=""
run_crdrive() {
  # Re-armed the same way each round, so the ONLY thing that differs between
  # the two passes is what the task's own ledger already records.
  fm_set "$CRE/.orchid/tasks/C700.md" status testing
  fm_set "$CRE/.orchid/tasks/C700.md" base_sha "$CRBASE"
  fm_set "$CRE/.orchid/tasks/C700.md" candidate_sha "$CRCAND"
  CR_RC=0
  CR_OUT="$(ORCHID_REPO="$CRE" ORCHID_EPOCH="$CREPOCH" "$DRIVE" 2>&1)" || CR_RC=$?
  [ "$CR_RC" -eq 0 ] || [ "$CR_RC" -eq 16 ] \
    || fail "a recurrence pass must end normally or at a boundary (rc=$CR_RC): $CR_OUT"
}

run_crdrive
assert_eq rework "$(crfield status)" \
  "the FIRST hand-off failure still retries — one bad round is not yet a reason to stop a run for a human (out: $CR_OUT)"
assert_eq 0 "$(crfield attempts)" \
  "and consumes no attempt, as before"
assert_eq 1 "$(crfield infra_failures)" \
  "having been charged to the environment budget instead"

run_crdrive
assert_eq testing "$(crfield status)" \
  "the SECOND does not move the task at all: it stops at an operator boundary rather than re-dispatching an implementer that cannot chmod anything (out: $CR_OUT)"
assert_eq 0 "$(crfield attempts)" \
  "still no attempt — stopping for a human must not become a back door to charging the candidate either"
assert_eq 2 "$(crfield infra_failures)" \
  "while the recurrence is still counted, so the ledger says what the environment actually cost"
assert_match "an operator clears this" "$CR_OUT" \
  "and the boundary says why another identical re-dispatch is not the answer"
CR_INFRA_REASONS="$(awk '
  /^## .* C700 intervention / { take=1; next }
  /^## / { take=0 }
  take && /^infra failure #[0-9]+:/ { print; take=0 }
' "$CRE/.orchid/journal.md")"
assert_eq 2 "$(printf '%s\n' "$CR_INFRA_REASONS" | grep -cF "$(drive_waiver_mark)" || true)" \
  "both infra-failure entries explicitly say attempt not charged, including the recurring round that stops before a second attempt_waiver edge"

# ===========================================================================
# Part N6 -- a WAIVED round must have an implement envelope of its OWN.
#
# `--waive-attempt` leaves `attempts` where it is, by design: it is a waiver,
# not a fresh attempt. That makes the re-dispatched round recompute the SAME
# attempt number, so `reviews/<id>-a<K>-implementer.json` -- the envelope of
# the round just waived -- is still resolvable by name. The first
# `drive_implementing` pass after the waiver therefore consumed it, re-stamped
# a worktree HEAD that had not moved as the candidate, and advanced straight
# back to testing: a verify re-run against an unchanged candidate, failing for
# the same reason, while the newly launched implementer was still writing to
# that worktree.
#
# So a waived round records a FLOOR, and only an envelope above it counts. The
# floor carries the attempt it was taken for, so it cannot outlive it.
# ===========================================================================
FLR="$WORK/implement-floor"
mkdir -p "$FLR/.orchid/tasks" "$FLR/.orchid/reviews"
printf -- '---\nschema: 1\nid: F01\nstatus: implementing\narchetype: feature\nattempts: 0\n---\nbody\n' \
  > "$FLR/.orchid/tasks/F01.md"
# mk_flr_env <sibling-suffix> <status> -- only the field the predicates read.
mk_flr_env() {
  printf '{"status":"%s"}\n' "$2" > "$FLR/.orchid/reviews/F01-a1-implementer$1.json"
}
flr_env() { drive_implement_envelope "$FLR" F01; }

mk_flr_env "" ok
assert_eq "$FLR/.orchid/reviews/F01-a1-implementer.json" "$(flr_env)" \
  "an ordinary round resolves the attempt's ok implement envelope, as it always did"
assert_eq 0 "$(drive_implement_floor "$FLR" F01)" \
  "with no floor recorded nothing is excluded — this must stay the unwaived default, or every first round would stall"
assert_eq "a1:1" "$(drive_implement_floor_mark "$FLR" F01)" \
  "and the mark a waiver would record names the attempt and the highest envelope already on disk"

fm_set "$FLR/.orchid/tasks/F01.md" implement_floor "a1:1"
assert_eq "" "$(flr_env)" \
  "THE FIX: once the round is waived, the envelope it produced no longer answers for the round that follows — a waived round must have a fresh one"
if drive_implement_failed "$FLR" F01; then
  fail "and 'no envelope of its own yet' is AWAITING, not FAILED — escalating here would spawn a second implementer into the same worktree"
fi

mk_flr_env ".2" ok
assert_eq "$FLR/.orchid/reviews/F01-a1-implementer.2.json" "$(flr_env)" \
  "the fresh implementer's own envelope is above the floor and resolves normally, so the waived round proceeds on its own work"

mk_flr_env ".2" failed
assert_eq "" "$(flr_env)" \
  "a fresh implementer that reports non-ok produces no candidate"
if ! drive_implement_failed "$FLR" F01; then
  fail "but it IS a failure, and must escalate — the previous round's ok envelope is below the floor and must not answer this question either"
fi

fm_set "$FLR/.orchid/tasks/F01.md" attempts 1
assert_eq 0 "$(drive_implement_floor "$FLR" F01)" \
  "and a floor taken for attempt 1 is inert at attempt 2 rather than wrong: a charged round moves attempts, which already makes the old envelopes unreachable by name"

# ===========================================================================
# Part N7 -- the recurrence guard reads THIS TASK's own waived rounds, not the
# shared `infra_failures` counter.
#
# `infra_failures` counts every environment charge a task ever took: a dead job
# manifest, a launch that could not spawn, a reaped worktree. Keying the "this
# fault has recurred" guard on it meant an unrelated earlier infra failure
# suppressed the FIRST hand-off round -- the one round that is supposed to
# retry, because the dispatch pass names the fault in the journal where an
# operator may already have cleared it.
# ===========================================================================
WJ="$WORK/waived-journal.md"
WMARK="$(drive_waiver_mark)"
printf '# Journal\n\n' > "$WJ"
assert_eq 0 "$(drive_waived_rounds "$WJ" W01)" \
  "a task with no history has had nothing waived"
{
  printf '## 2026-08-10T00:00:00Z W01 intervention (operator e1)\n'
  printf 'infra failure #1: implement job manifest was reaped\n\n'
  printf '## 2026-08-10T00:01:00Z W02 attempt_waiver (operator e1)\n'
  printf 'verify failed (handoff, %s): another task entirely\n\n' "$WMARK"
} >> "$WJ"
assert_eq 0 "$(drive_waived_rounds "$WJ" W01)" \
  "an infra failure is not a waived round, and neither is another task's waiver — the guard is per-task and per-kind"
{
  printf '## 2026-08-10T00:02:00Z W01 attempt_waiver (operator e1)\n'
  printf 'the operator waived this arbitration round on judgement\n\n'
} >> "$WJ"
assert_eq 0 "$(drive_waived_rounds "$WJ" W01)" \
  "an operator's own arbitration waiver is a different decision and does not arm the guard either"
{
  printf '## 2026-08-10T00:03:00Z W01 attempt_waiver (operator e1)\n'
  printf 'verify failed (handoff, %s): the exec bit is not set on libexec/orchid-frob\n\n' "$WMARK"
} >> "$WJ"
assert_eq 1 "$(drive_waived_rounds "$WJ" W01)" \
  "while the driver's own waived verify round counts, which is exactly the history the guard means to ask about"

assert_match "[(]handoff, ${WMARK}[)]" \
  "$(drive_waiver_reason handoff "the exec bit is not set on libexec/orchid-frob")" \
  "the waived round's reason carries its class beside the mark — that line is what drive_waived_rounds reads back out of the journal, and a writer and a reader that spell it separately drift apart silently, leaving a guard that counts nothing"
{
  printf '## 2026-08-10T00:04:00Z W01 attempt_waiver (operator e1)\n'
  printf '%s\n\n' "$(drive_waiver_reason handoff "the package pin recorded for Formula/orchid.rb is stale")"
} >> "$WJ"
assert_eq 2 "$(drive_waived_rounds "$WJ" W01)" \
  "and a second waived round counts as a second — the guard fires on the first recurrence, so this number is the whole of what it reads"

# --- and it ANSWERS, rather than failing ------------------------------------
# This is read through a command substitution inside a `set -euo pipefail`
# runner, so its exit status is not advisory: a non-zero here is not "no waived
# rounds", it is the whole pass dying mid-round with an exit code the driver
# does not document and every task after this one in the walk untouched.
wrc=0
wout="$(drive_waived_rounds "$WJ" W01)" || wrc=$?
assert_eq 0 "$wrc" \
  "counting waived rounds must EXIT zero — the driver reads this through a command substitution under set -e, where a failure is a dead pass rather than a count"
case "$wout" in
  ''|*[!0-9]*)
    fail "counting waived rounds must yield a number, not '$wout' — the recurrence guard compares it with -ge, and a non-number there is a second failure on top of the first" ;;
esac
assert_eq 0 "$(drive_waived_rounds "$WORK/no-such-journal.md" W01)" \
  "a task in a run whose journal is not there yet has had nothing waived, and asking must not fail either"

# --- and end to end: an unrelated infra failure must not suppress the first
# waived round ------------------------------------------------------------
CRU="$WORK/classify-recur-unrelated"
mkdir -p "$CRU"
cd "$CRU" || exit 1
git init -q .
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$CRU" "$ORCHID_BIN" init >/dev/null || fail "orchid init (unrelated-infra fixture)"
git checkout -q orchid/integration
CRUEPOCH="$(ORCHID_REPO="$CRU" "$ORCHID_BIN" run start | sed 's/epoch: //')"
cruorchid() { ORCHID_REPO="$CRU" ORCHID_EPOCH="$CRUEPOCH" "$ORCHID_BIN" "$@"; }
cruorchid requirements import "$WORK/requirements.md" >/dev/null
cruorchid task create C800 "its FIRST waived failure follows an unrelated infra charge" >/dev/null
cruorchid task set C800 verification_commands \
  "echo /bin/bash: libexec/orchid-cru: Permission denied; exit 1" >/dev/null
cruorchid plan apply --reason "initial plan" >/dev/null

# The unrelated charge: a reaped job manifest, nothing to do with any hand-off
# or with this task's verification. This is the state that used to make the
# guard fire on the very first waived round.
cruorchid task infra-fail C800 --reason "implement job manifest was reaped" >/dev/null
CRUBASE="$(git -C "$CRU" rev-parse HEAD)"
mkdir -p "$CRU/libexec"
printf '#!/usr/bin/env bash\necho cru\n' > "$CRU/libexec/orchid-cru"
git -C "$CRU" add libexec/orchid-cru
git -C "$CRU" commit -q -m "fixture: a candidate that ships a new verb at mode 644"
fm_set "$CRU/.orchid/tasks/C800.md" status testing
fm_set "$CRU/.orchid/tasks/C800.md" base_sha "$CRUBASE"
fm_set "$CRU/.orchid/tasks/C800.md" candidate_sha "$(git -C "$CRU" rev-parse HEAD)"

CRU_RC=0
CRU_OUT="$(ORCHID_REPO="$CRU" ORCHID_EPOCH="$CRUEPOCH" "$DRIVE" 2>&1)" || CRU_RC=$?
[ "$CRU_RC" -eq 0 ] || [ "$CRU_RC" -eq 16 ] \
  || fail "the unrelated-infra pass must end normally or at a boundary (rc=$CRU_RC): $CRU_OUT"
crufield() { ORCHID_REPO="$CRU" "$ORCHID_BIN" task show C800 | grep "^$1: " | cut -d' ' -f2-; }
assert_eq rework "$(crufield status)" \
  "the FIRST waived round still retries even though infra_failures was already 1 for an unrelated reason — the guard asks this task's own waived history, not a shared counter (out: $CRU_OUT)"
assert_eq 0 "$(crufield attempts)" \
  "and it still consumes no attempt"
assert_eq 2 "$(crufield infra_failures)" \
  "while the environment budget still counts both charges, so a genuinely bad environment still terminates at infra_max"

# ===========================================================================
# Part Y4 -- LESSON L003, THE NAMED CASE: a dispatch worktree that never
# received the gitignored build state the integration checkout carries.
#
# `git worktree add` reproduces what git TRACKS. In the webBooks run
# `mobile/node_modules` existed in the integration checkout only as a
# gitignored symlink into a sibling checkout, so every freshly created task
# worktree came up without it, the first `orchid verify` there failed on
# missing dependencies, and a rework attempt was charged for a gap in
# PROVISIONING rather than a defect in the candidate. Every project that uses
# worktrees rediscovers this by losing an attempt to it.
#
# THIS ARM EXISTED ONCE AND WAS DANGEROUS, and the difference is the whole
# point of this part. It used to treat an absent ignored directory as
# invalidating the WHOLE ROUND -- exempt from the per-failure accounting -- so
# an unrelated `.cache` plus any `command not found` line waived every failure
# in it. The exemption was the defect, not the class. What is asserted below is
# the class WITH the accounting: the state is proved by comparing the two
# checkouts, and the failure must then be attributed to that directory by a
# fact about the FILESYSTEM -- the thing the round could not resolve is one
# the absent tree PUBLISHES.
#
# Both edges are pinned, per lesson L034: the named case is waived, and every
# shape of coincidence around it still charges.
# ===========================================================================
ENVR="$WORK/l003-repo"
mkdir -p "$ENVR/.orchid/tasks" "$ENVR/.orchid/reviews" "$ENVR/mobile"
cd "$ENVR" || exit 1
git init -q .
: > "$ENVR/orchid.config"
printf 'node_modules/\n.cache/\n' > "$ENVR/.gitignore"
printf 'x\n' > "$ENVR/mobile/app.js"
git add -A
git commit -q -m "fixture: an integration checkout that ignores its dependency tree"
# The build state itself, created AFTER the commit and never tracked -- which
# is exactly the state `git worktree add` cannot reproduce. `.bin/jest` is the
# entry point the tree PUBLISHES, and the fact the attribution turns on.
mkdir -p "$ENVR/mobile/node_modules/.bin"
printf '#!/usr/bin/env node\n' > "$ENVR/mobile/node_modules/.bin/jest"
printf '#!/usr/bin/env node\n' > "$ENVR/mobile/node_modules/.bin/tsx"
mkdir -p "$ENVR/mobile/node_modules/lodash"
# `open` is deliberately present too. It is syntax in the standard ENOENT
# diagnostic below, not that diagnostic's subject, and used to be accepted as
# causal merely because every whitespace token on the line was searched.
mkdir -p "$ENVR/mobile/node_modules/open"
# An unrelated ignored directory, present here and absent there, with nothing
# named `jest` anywhere inside it. This is the coincidence that broke the old
# arm, and it sits in the fixture throughout so every assertion below is made
# in its presence rather than in a tree curated to avoid it.
mkdir -p "$ENVR/.cache/webpack"
printf 'cache fixture\n' > "$ENVR/.cache/webpack/state"

# The dispatch worktree, created the way dispatch actually creates one, so the
# absence being asserted is git's own behaviour rather than something the
# fixture arranged.
ENVW="$WORK/l003-worktree"
git -C "$ENVR" worktree add -q "$ENVW" -b task/L003 2>/dev/null \
  || fail "fixture: could not create the L003 dispatch worktree"
[ ! -e "$ENVW/mobile/node_modules" ] \
  || fail "fixture invalid: git worktree add reproduced a gitignored directory — the whole premise of lesson L003 is that it cannot"

ENV_CAND="$(git -C "$ENVW" rev-parse HEAD)"
printf -- '---\nschema: 1\nid: EV1\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$ENVW" "$ENV_CAND" "$ENV_CAND" > "$ENVR/.orchid/tasks/EV1.md"
ev_log() {
  mk_prestate_log "$ENVR" "$ENVR/.orchid/tasks/EV1.md" \
    "$ENVR/.orchid/reviews/EV1-verify.log" "$1" "yarn test"
}
ev_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$ENVR" "$ENVR/.orchid/tasks/EV1.md" \
      "$ENVR/.orchid/reviews/EV1-verify.log" )
}

# --- the state itself, at the layer it lives in ---------------------------
assert_match "mobile/node_modules" "$(drive_env_missing_state "$ENVR" "$ENVW")" \
  "the missing build state is found by COMPARING the two checkouts: ignored here, present here, absent there"
assert_eq "" "$(drive_env_missing_state "$ENVR" "$ENVR")" \
  "and a task with no dispatch worktree of its own has none of this state by construction — there is no second checkout for anything to be missing from"
ENV_INVENTORY="$(drive_env_inventory_state "$ENVR" \
  "$(drive_env_missing_state "$ENVR" "$ENVW")")"
assert_match $'mobile/node_modules\tjest' "$ENV_INVENTORY" \
  "the verifier-owned environment inventory records the command the missing dependency tree published before candidate code runs"

# --- the named case: waived, and it names the directory -------------------
ev_log 'error Command "jest" not found'
assert_eq environment "$(ev_cls | cut -f1)" \
  "L003's own case: a worktree that never received mobile/node_modules could not resolve jest, and jest is what mobile/node_modules/.bin PUBLISHES — that is a fact about the filesystem, not a reading of the sentence, and it does not charge the attempt"
assert_match "mobile/node_modules" "$(ev_cls | cut -f2-)" \
  "and the reason names the directory, because 'the environment' is not something anybody can provision"
assert_match "creating the worktree from Git-tracked state" "$(ev_cls | cut -f2-)" \
  "and says why it is absent, so the reader learns the mechanism rather than the incident"

# Capture the real missing tree and its published subjects, then let the
# simulated candidate add a diagnostic-shaped command to the INTEGRATION
# checkout after capture. The missing-directory snapshot alone is not enough:
# a post-run resolver would find this new `.bin` entry and let candidate output
# manufacture its own environment waiver.
EV_BEFORE_INVENTORY_MUTATION="$(drive_verify_prestate_headers \
  "$ENVR" "$ENVR/.orchid/tasks/EV1.md")"
printf '#!/usr/bin/env node\n' > "$ENVR/mobile/node_modules/.bin/fabricated"
assert_match $'mobile/node_modules\tfabricated' \
  "$(drive_env_inventory_state "$ENVR" "mobile/node_modules")" \
  "fixture: a live post-command inventory really would accept the fabricated command"
mk_prestate_log "$ENVR" "$ENVR/.orchid/tasks/EV1.md" \
  "$ENVR/.orchid/reviews/EV1-verify.log" \
  'error Command "fabricated" not found' "yarn test" 1 \
  "$EV_BEFORE_INVENTORY_MUTATION"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "but the bound pre-command inventory has no fabricated subject, so candidate-created integration content cannot manufacture an environment waiver"
rm -f "$ENVR/mobile/node_modules/.bin/fabricated"

# Yarn v1 wraps that causal diagnostic in deterministic harness records. The
# version and help records are unconditionally neutral; the echoed command and
# exit-127 record are attributed only after the missing-tree inventory proves
# the command and a causal resolution failure opens the route. The full real
# bodies must remain live, while anything beyond that closed grammar keeps the
# strict default.
YARN_L003_BODY='yarn run v1.22.19
$ jest
error Command "jest" not found
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.'
ev_log "$YARN_L003_BODY"
assert_eq 2 "$(drive_failure_lines "$YARN_L003_BODY" | grep -c .)" \
  "the Yarn command echo is not globally neutral: before environment attribution the denominator contains it and the causal diagnostic"
assert_eq environment "$(ev_cls | cut -f1)" \
  "the jest-shaped L003 case dynamically attributes the echoed command after the missing tree and causal diagnostic are proved"

WEBBOOKS_L003_BODY='yarn run v1.22.19
$ tsx scripts/parseBooks.ts
/bin/sh: tsx: command not found
error Command failed with exit code 127.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.'
ev_log "$WEBBOOKS_L003_BODY"
assert_eq 3 "$(drive_failure_lines "$WEBBOOKS_L003_BODY" | grep -c .)" \
  "the actual webBooks shape keeps its command echo, causal diagnostic, and exit-127 record in the strict denominator before attribution"
assert_eq environment "$(ev_cls | cut -f1)" \
  "L003's named webBooks body attributes the arbitrary tsx package-script echo and canonical exit-127 record only after trusted inventory proves tsx came from the absent tree"
ev_log 'yarn run v1.22.19
$ webpack scripts/parseBooks.ts
/bin/sh: tsx: command not found
error Command failed with exit code 127.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "a Yarn echo for a command the missing tree did not publish stays unknown and keeps the exit-127 wrapper from being attributed, even beside a different causal environment failure"
ev_log 'yarn run v1.22.19
$tsx scripts/parseBooks.ts
/bin/sh: tsx: command not found
error Command failed with exit code 127.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "a noncanonical command echo without Yarn v1's dollar-space prefix remains unknown and charges rather than widening the exact wrapper grammar"
ev_log 'yarn run v1.22.19
$ tsx scripts/parseBooks.ts
/bin/sh: tsx: command not found
error Command failed with exit code 1.
info Visit https://yarnpkg.com/en/docs/cli/run for documentation about this command.'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "an unfamiliar Yarn exit record remains strict even when the echoed missing command is proved; only the canonical command-not-found status 127 is context"
ev_log "$YARN_L003_BODY
info an unfamiliar package-manager epilogue"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "the Yarn allowance is closed: an unfamiliar banner remains uncertain and charges instead of disappearing beside the environment failure"

# --- THE COINCIDENCE THAT BROKE THE OLD ARM, in the same tree -------------
# `.cache` is missing from the worktree too, and it is missing for exactly the
# same reason. It claims nothing, because nothing it publishes is what this
# round could not find.
assert_match ".cache" "$(drive_env_missing_state "$ENVR" "$ENVW")" \
  "the unrelated ignored directory is equally absent, so this is not a fixture that avoided the hazard"
ev_log 'error Command "webpack-dev-server" not found'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "and a resolution failure for something NEITHER absent tree publishes is CHARGED — .cache/webpack is a directory, not a command named webpack-dev-server, and 'something is missing and something failed' is a coincidence rather than a cause"
EV_UNATTRIBUTED_REASON="$(ev_cls | cut -f2-)"
assert_match "no missing gitignored build state was attributable to this failure" "$EV_UNATTRIBUTED_REASON" \
  "the charged-round reason reports the attribution decision instead of falsely saying this worktree carries build state the fixture proves it is missing"
case "$EV_UNATTRIBUTED_REASON" in
  *'worktree is missing no gitignored build state'*)
    fail "a charged round must not deny the missing node_modules and .cache trees merely because neither explains this diagnostic ($EV_UNATTRIBUTED_REASON)" ;;
esac

# --- a defect landing in the same round is not laundered ------------------
ev_log 'error Command "jest" not found
  FAIL: widget returned 3, expected 4'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "the absent tree explains the jest line and NOTHING explains the widget assertion, so the round is charged — a defect that happens to land beside a provisioning gap is precisely what must not be laundered"
assert_match "widget returned 3" "$(ev_cls | cut -f2-)" \
  "and the reason quotes the line it could not attribute"

# --- the cascade IS claimed, so the arm is not inert on a real failure ----
ev_log 'error Command "jest" not found
  FAIL: mobile/node_modules is missing; run yarn install
  FAIL: suite could not start'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "a cascade line that names NEITHER the directory nor anything it publishes is unclaimed and charges — the strict direction, and the price of not letting proximity forgive whatever else broke"
ev_log 'error Command "jest" not found
  FAIL: mobile/node_modules is missing; run yarn install'
assert_eq environment "$(ev_cls | cut -f1)" \
  "while a cascade line that NAMES the directory is attributed to it, exactly as a mode bit claims the lines naming its file — one fault does not produce one failing line"

# --- A PATH INSIDE THE ABSENT TREE NAMES THE ABSENT TREE ------------------
# The commonest sentence L003 produces after the first missing command, and it
# was charged: the resolution failure quotes a path UNDER the directory rather
# than the directory itself, and the general artifact boundary refuses a
# trailing `/` on purpose -- because for the other arms the artifact is a FILE,
# where `bin/tool/child` is a different file and must not be collected. For an
# absent DIRECTORY the relationship is the opposite: everything beneath it is
# missing with it, so a path under it is that tree and not a neighbour of it.
# The exactness of the NAME is untouched, which is the RED half below.
ev_log "ENOENT: no such file or directory, open '$ENVW/mobile/node_modules/react-native/package.json'"
assert_eq environment "$(ev_cls | cut -f1)" \
  "an ENOENT quoting a path INSIDE the absent tree is that tree's failure — it cannot be about anything else, since the directory the path runs through is the one that is not there"
assert_match "mobile/node_modules" "$(ev_cls | cut -f2-)" \
  "and the reason still names the directory somebody has to provision"
ev_log "ENOENT: no such file or directory, open 'mobile/node_modules-old/react-native/package.json'"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "while mobile/node_modules-old is a DIFFERENT directory that merely starts with the same characters, and it charges — opening the boundary for a child path must not open it for a longer name, which is the substring bug that waived a round over bin/tool-helper"
ev_log "ENOENT: no such file or directory, open 'fixtures/mobile/node_modules/react-native/package.json'"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "and a path under fixtures/mobile/node_modules is not under the missing mobile/node_modules merely because the latter is its suffix — only the exact relative, ./, or worktree-root absolute identity may open the child-path rule"
assert_eq "" "$(drive_env_causal "$ENV_INVENTORY" mobile/node_modules \
    "ENOENT: no such file or directory, open 'fixtures/mobile/node_modules/react-native/package.json'" "$ENVW")" \
  "the environment causal layer itself rejects the deeper suffix, so an unrelated cascade cannot reopen attribution later"
assert_eq "" "$(drive_env_causal "$ENV_INVENTORY" mobile/node_modules \
    "ENOENT: no such file or directory, open 'mobile/node_modulesX/y'")" \
  "nor for a name continuing in any other character — asserted at the layer it lives in, because both readings of the class assertion above look identical from outside"

# --- THE RESOLUTION SUBJECT, NOT AN UNRELATED WORD ON THE LINE ------------
# `open` is both diagnostic grammar and the name of a real package in the
# absent tree. The subject of this ENOENT is `src/config.json`; scanning every
# token resolves `open` and launders the candidate's missing source file as an
# environment gap. Subject binding keeps the filesystem proof attached to the
# thing the line actually says it could not resolve.
[ -e "$ENVR/mobile/node_modules/open" ] \
  || fail "fixture invalid: the missing dependency tree must contain a package named open, or the token-laundering regression below proves nothing"
ev_log "Error: ENOENT: no such file or directory, open 'src/config.json'"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "an ENOENT for src/config.json is CHARGED even though an unrelated token named open resolves inside the absent node_modules — only the diagnosed subject can establish causality"
assert_eq "" "$(drive_env_causal "$ENV_INVENTORY" mobile/node_modules \
    "Error: ENOENT: no such file or directory, open 'src/config.json'")" \
  "and the causal layer itself claims no line, proving the candidate verdict did not merely come from some later accounting accident"
ev_log 'jest: command not found'
assert_eq environment "$(ev_cls | cut -f1)" \
  "the shell spelling with its subject before the command marker still attributes jest to the absent tree's .bin entry"

# --- THE CASCADE IS NAMING, NOT RESEMBLANCE -------------------------------
# The coincidence above, one FAILING LINE at a time instead of one round at a
# time, and it is the shape this arm carried until now: the cascade also
# claimed any failing line holding a token that RESOLVED inside the absent
# tree, with no resolution shape required of the line at all. A dependency
# tree's direct children are ordinary words -- `lodash` is a package in
# mobile/node_modules -- so an assertion that merely happened to be ABOUT
# something sharing a package's name was waived as that tree's cascade. A
# candidate defect is not laundered by vocabulary.
[ -e "$ENVR/mobile/node_modules/lodash" ] \
  || fail "fixture invalid: mobile/node_modules must publish a direct child named lodash, or the two assertions below prove nothing about resemblance"
ev_log 'error Command "jest" not found
  FAIL: lodash helper returned 3, expected 4'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "a failing line whose ONLY tie to the absent tree is a word matching one of its direct children is not that tree's cascade — it is a candidate defect about something with a package's name, and the absent tree must claim it no more readily than .cache claims a webpack-dev-server line"
assert_match "lodash helper returned 3" "$(ev_cls | cut -f2-)" \
  "and the reason quotes it, so an operator sees exactly what the attempt is being charged for"

# --- ... while the GENUINE resolution cascade still waives -----------------
# The same package name, in a line that REPORTS A RESOLUTION FAILURE. This is
# what L003 actually prints once the first missing command has been hit, and
# narrowing the cascade must not cost it: what was withdrawn is resemblance,
# not the class.
ev_log 'error Command "jest" not found
  FAIL: Cannot find module lodash from mobile/src/App.js'
assert_eq environment "$(ev_cls | cut -f1)" \
  "a failing line that cannot RESOLVE something the absent tree publishes is still the absent tree's, so the arm remains live on the cascade it exists for"

# --- and once the worktree is provisioned, the identical failure charges --
mkdir -p "$ENVW/mobile/node_modules/.bin"
ev_log 'error Command "jest" not found'
ENV_LEFT="$(drive_env_missing_state "$ENVR" "$ENVW")"
if grep -Fq 'mobile/node_modules' <<<"$ENV_LEFT"; then
  fail "once the tree is there, there is no missing-state to prove for it — the same comparison that found it must stop finding it (still missing: $ENV_LEFT)"
fi
assert_match "[.]cache" "$ENV_LEFT" \
  "while the unrelated ignored directory is STILL absent, so the assertion below is charged in its presence rather than in a tidied tree"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "so the identical sentence now charges: whatever this failure is, provisioning mobile/node_modules is no longer the answer"

# Capture that healthy pre-run state, then let the simulated candidate command
# delete it before printing the usual L003 diagnostic. A post-run comparison
# sees the missing tree and would waive; the trusted empty snapshot must not.
EV_BEFORE_MUTATION="$(drive_verify_prestate_headers \
  "$ENVR" "$ENVR/.orchid/tasks/EV1.md")"
rm -rf "$ENVW/mobile/node_modules"
assert_match "mobile/node_modules" "$(drive_env_missing_state "$ENVR" "$ENVW")" \
  "fixture: after the simulated command deletes dependencies, a post-run comparison really would see the L003 state"
mk_prestate_log "$ENVR" "$ENVR/.orchid/tasks/EV1.md" \
  "$ENVR/.orchid/reviews/EV1-verify.log" 'error Command "jest" not found' \
  "yarn test" 1 "$EV_BEFORE_MUTATION"
assert_eq candidate "$(ev_cls | cut -f1)" \
  "but trusted pre-verification evidence says node_modules was present, so a candidate cannot delete ignored dependencies during its test and manufacture an environment waiver"

# --- and DISPATCH reports it, instead of leaving each project to discover it
# by losing a round. The same predicate runs right after `git worktree add`, so
# the gap is named at the moment somebody can still act on it. A source-level
# tripwire rather than another end-to-end pass: the predicate's behaviour is
# asserted directly above, and what this protects is that the driver still asks
# it at dispatch, which is the part that would go quietly missing.
grep -q 'drive_env_missing_state' "$DRIVE" \
  || fail "runners/orchid-drive must ASK what the new worktree could not carry when it creates one (L003) — classifying the resulting failure afterwards is the backstop for a note that went unread, not a substitute for making the note"
grep -q 'git worktree add cannot reproduce' "$DRIVE" \
  || fail "and it must SAY so in terms an operator can act on, naming the mechanism rather than reporting a bare list of paths"

# ===========================================================================
# Part Y5 -- LESSON L020: a failure the repository ALREADY recorded as flaky.
#
# Orchid never INFERS flakiness -- it cannot, from one run -- and this arm does
# not ask it to. It reads a register the repository keeps, and the entire
# safety of it is in WHEN that register had to be written: a register THIS
# CANDIDATE CHANGED is not an authority on this candidate. An implementer
# cannot quarantine the assertion it is failing, because the moment its
# candidate touches the file the route is gone and the round charges.
#
# The other narrowings are asserted here too, because each of them is what
# stops a repository buying a blanket amnesty: signatures are matched
# LITERALLY (never as patterns), must be long enough not to match everything by
# accident, and ordinarily claim ONLY the lines they match. Exact companion
# context is inert unless one of those signatures matched first, and any line
# outside its closed list still charges.
# ===========================================================================
QR="$WORK/quarantine"
mkdir -p "$QR/.orchid/tasks" "$QR/.orchid/reviews" "$QR/tests"
cd "$QR" || exit 1
git init -q .
: > "$QR/orchid.config"
# THE SIGNATURE IS READ OUT OF THE TREE, NEVER TYPED HERE, and the
# assertion further down proves this exact text is still what orchid's own
# engine-adapter suite prints when that liveness case genuinely fails. Writing
# the signature into the fixture by hand instead would prove only that grep
# works; tying it to the tree is what makes every assertion below a fact about
# this repository. The block at the end of this part then leaves the fixture
# behind entirely and drives the same route through THE REGISTER ORCHID SHIPS.
L020_SIG='bounded growth wait must observe live stream bytes before adapter exit'
{
  printf '%s\n' "# Known-flaky assertions. Each entry is one line beginning \`FLAKE:\`."
  printf '%s\n' 'FLAKE: short -- too short to be a signature, and must be ignored'
  printf '%s\n' 'FLAKE: FAIL: .* returned -- deliberately regex-shaped, and must NOT be read as one'
  printf '%s\n' 'FLAKE-CONTEXT: looks fine'
  # No final newline on purpose: a text file is allowed to end here, and the
  # reader must not silently discard its last (and most important) entry.
  printf 'FLAKE: %s -- L020: samples one instant; the shape that stranded eight tasks' "$L020_SIG"
} > "$QR/tests/QUARANTINE.md"
printf 'x\n' > "$QR/file.txt"
git add -A
git commit -q -m "fixture: a repository with a known-flaky register"
QRBASE="$(git -C "$QR" rev-parse HEAD)"
printf 'y\n' > "$QR/file.txt"
git add -A
git commit -q -m "fixture: a candidate that does NOT touch the register"
QRCAND="$(git -C "$QR" rev-parse HEAD)"

mk_qr_task() {  # <base-sha> <candidate-sha>
  printf -- '---\nschema: 1\nid: QA1\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$QR" "$1" "$2" > "$QR/.orchid/tasks/QA1.md"
}
mk_qr_task "$QRBASE" "$QRCAND"
qr_log() {  # <body> [exit-status]
  printf 'date: 2026-08-10T00:00:00Z\nsha: %s\ncandidate: %s\ncwd: %s\ncommand: bash tests/run.sh\n---\n%s\nexit: %s\n' \
    "$QRCAND" "$QRCAND" "$QR" "$1" "${2:-1}" > "$QR/.orchid/reviews/QA1-verify.log"
}
qr_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$QR" "$QR/.orchid/tasks/QA1.md" \
      "$QR/.orchid/reviews/QA1-verify.log" )
}

L020_LINE="  FAIL: streaming stub: $L020_SIG -- the stall-detector liveness signal"

# --- THE SIGNATURE IS THE ONE THIS REPOSITORY WOULD ACTUALLY PRINT --------
# The fixture's entry is not invented text: it is the sentence orchid's own
# liveness case really prints when that property is genuinely violated. So the
# route below is proved against the exact string an operator would paste into a
# register -- and if that sentence is ever reworded, this assertion fails and
# whoever reworded it learns that the worked example has to move with it.
#
# Note what this fixture's entry deliberately IS: the sentence the LIVE,
# de-flaked assertion prints. Quarantining that one for real would be wrong --
# it waits for what it samples, so its failure is evidence -- and orchid's own
# register does not. This is a fixture, and it is here to exercise the route's
# mechanics on text that is guaranteed to still exist.
grep -Fq -- "$L020_SIG" "$REPO_ROOT/tests/test_engine_agy.sh" \
  || fail "the L020 signature the fixture register below is built from must be the text tests/test_engine_agy.sh's liveness case really prints on failure — otherwise this part proves that grep matches a string this file made up, and the flaky route's only live subject in orchid goes untested"
[ "${#L020_SIG}" -ge 16 ] \
  || fail "and it must be long enough to be a legal signature (>= 16 characters), or the register would drop it and every assertion below would be about an entry that was never read"

# --- the register itself, at the layer it lives in ------------------------
QR_SIGS="$(
  HOME="$MACHINE_HOME"
  drive_quarantine_signatures "$QR" "$QR" "$QR/.orchid/tasks/QA1.md"
)"
assert_match "bounded growth wait" "$QR_SIGS" \
  "a FLAKE: entry long enough to be a signature is read out of the register"
if grep -Fq 'short' <<<"$QR_SIGS"; then
  fail "a signature shorter than the minimum must be DROPPED — an entry that short would match half the output of any suite, which is a blanket amnesty spelled as a typo (got: $QR_SIGS)"
fi
QR_CONTEXTS="$(
  HOME="$MACHINE_HOME"
  drive_quarantine_contexts "$QR" "$QR" "$QR/.orchid/tasks/QA1.md"
)"
assert_eq "looks fine" "$QR_CONTEXTS" \
  "FLAKE-CONTEXT records are read from the same trusted register, including a short exact line that cannot open the route by itself"
assert_eq "  looks fine  " "$(drive_quarantine_context_attribution \
    "looks fine" $'different\n  looks fine  \nlooks fine today')" \
  "context matches the whole normalized line, preserving its original bytes for exact accounting and never matching a longer line by substring"

# --- the L020 line, waived, and it says what it is ------------------------
qr_log "$L020_LINE"
assert_eq flaky "$(qr_cls | cut -f1)" \
  "the assertion that stranded eight tasks in r-002 was on this repository's register BEFORE this candidate, so its failure charges no attempt"
assert_match "known-flaky" "$(qr_cls | cut -f2-)" \
  "and the reason says the register is what forgave it, not orchid's own judgement about the test"

# Old tests/run.sh prints a failed child's whole buffer, including deterministic
# output from successful negative fixtures that ran before the historical
# liveness assertion. A trusted exact companion line may close that real body,
# but it is powerless without the registered assertion that causes the child
# to be exposed.
qr_log "looks fine
$L020_LINE"
assert_eq flaky "$(qr_cls | cut -f1)" \
  "registered exact fixture context beside the causal L020 assertion is attributed with it, so old tests/run.sh's buffered successful chatter does not burn the attempt"
qr_log 'looks fine'
assert_eq candidate "$(qr_cls | cut -f1)" \
  "the same registered context without a matching FLAKE signature is inert and charges — companion output can never open a waiver"
qr_log 'looks fine today'
assert_eq candidate "$(qr_cls | cut -f1)" \
  "a longer line sharing the context text still charges, because companion matching is exact after surrounding-whitespace normalization"
qr_log "$L020_LINE
looks fine
adapter fixture produced an unregistered sentence"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "causal L020 plus registered context plus one novel diagnostic still charges — the companion list is closed, not a failed-child cascade"
assert_match "unregistered sentence" "$(qr_cls | cut -f2-)" \
  "and the reason quotes the novel line that kept the mixed round chargeable"

# A stopped-short status is an independent uncertainty and vetoes even this
# otherwise complete attribution. This pins the ordering: if the waiver's
# cost-saving return runs before the status is examined, this reads `flaky`
# and silently forgives the candidate hang the status cannot rule out.
qr_log "$L020_LINE" 143
assert_eq candidate "$(qr_cls | cut -f1)" \
  "a registered assertion alongside quiet exit 143 still CHARGES — the printed line is known-flaky, but the termination may be a candidate hang and uncertain provenance vetoes every waiver"
assert_match "stopped short" "$(qr_cls | cut -f2-)" \
  "and the charged mixed round reports the termination uncertainty rather than returning early from the flaky arm"
assert_match "every printed failing line is otherwise attributable" "$(qr_cls | cut -f2-)" \
  "while saying attribution DID succeed — the attempt charges for the independent termination uncertainty, not for an empty or falsely reported attribution failure"
qr_log "$L020_LINE"

# --- literal, never a pattern --------------------------------------------
qr_log '  FAIL: widget returned 3, expected 4'
assert_eq candidate "$(qr_cls | cut -f1)" \
  "the regex-shaped entry 'FAIL: .* returned' does NOT match 'FAIL: widget returned 3' — signatures are matched literally, because a '.*' in a repository-controlled file would waive every round forever"

# --- claims only its signature and registered exact context --------------
qr_log "$L020_LINE
  FAIL: widget returned 3, expected 4"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "a quarantined flake alongside a real assertion charges the round — the register excuses its signature and closed companion context, never an unlisted failure"
assert_match "widget returned 3" "$(qr_cls | cut -f2-)" \
  "and the reason quotes what it could not excuse"

# --- and the route can be switched off outright ---------------------------
printf 'flaky.quarantine=none\n' > "$QR/orchid.config"
qr_log "$L020_LINE"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "flaky.quarantine=none disables the route, so a repository that wants no register has none"
: > "$QR/orchid.config"

# --- THE AUTHORITY QUESTION FAILS CLOSED WHEN IT CANNOT BE ASKED ----------
# The safety property at the end of this part is "a register the candidate
# changed is no authority on it", and it was skippable for free: `git diff`
# over a missing or unresolvable sha prints an empty list, which is
# indistinguishable from "this candidate changed nothing", and the route read
# both as permission. A task whose `base_sha` was never written -- or whose
# recorded commit this tree no longer carries, which is what a re-pointed
# branch leaves behind -- could therefore quarantine the assertion it was
# failing after all. Every unanswerable form is charged, and the answerable one
# is restored immediately afterwards so this is a guard rather than a deletion.
qr_log "$L020_LINE"
mk_qr_task "" "$QRCAND"
assert_eq "" "$( ( HOME="$MACHINE_HOME"
  drive_quarantine_signatures "$QR" "$QR" "$QR/.orchid/tasks/QA1.md" ) )" \
  "with no base_sha, nothing can be asked about who wrote this register, so it yields NO signatures — asserted at the layer it lives in, because the class below would also read 'candidate' if the register had simply gone missing"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "and the round charges: an unanswerable authority question is not permission, least of all on the one route an implementer could otherwise use to forgive its own failure"
mk_qr_task "$QRBASE" ""
assert_eq candidate "$(qr_cls | cut -f1)" \
  "and the same with no candidate_sha — one end of a diff is no more an answer than none"
mk_qr_task "$QRBASE" 0000000000000000000000000000000000000000
assert_eq candidate "$(qr_cls | cut -f1)" \
  "and a sha that does not RESOLVE in this tree charges too, which is the form this really takes: both fields are present, so a guard that only tested for emptiness would walk past it"
mk_qr_task "not-a-sha-at-all" "$QRCAND"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "and so does one that is not a sha at all — the guard turns on whether git ANSWERED, never on whether the field looked plausible"
mk_qr_task "$QRBASE" "$QRCAND"
assert_eq flaky "$(qr_cls | cut -f1)" \
  "while the answerable, untouched case is unchanged — the guard closes the route on ignorance, never on the route"

# --- AND THE REGISTER THAT IS READ IS THE FILE, NOT A DIFF OF TWO COMMITS --
# The timing rule is enforced with `git diff base..candidate`, and that diff
# says nothing about the file the driver actually READS. An implementer that
# cannot commit an entry into its own candidate can still leave one in the
# worktree the verification runs in — unstaged, or staged and uncommitted —
# and every one of those diffs is empty. It can drop in an untracked register
# where there was none. So the register is an authority only while the verified
# worktree still carries exactly the bytes and mode the candidate RECORDED, and
# each way of not doing that closes the route and charges. The intact case is
# restored after each, so this is a guard rather than a deletion.
QR_REG="$QR/tests/QUARANTINE.md"
QR_REG_BYTES="$WORK/qr-register.committed"
cp "$QR_REG" "$QR_REG_BYTES"
printf '\nFLAKE: widget returned 3, expected 4 -- left in the worktree, never committed\n' >> "$QR_REG"
qr_log '  FAIL: widget returned 3, expected 4'
assert_eq candidate "$(qr_cls | cut -f1)" \
  "an entry the implementer left UNSTAGED in the verified worktree forgives nothing: the file being read is not the file the candidate recorded, and a diff of two commits cannot see the difference"
git -C "$QR" add tests/QUARANTINE.md
cp "$QR_REG_BYTES" "$QR_REG"
# The L020 line from here on, and that is what keeps the rest of this block
# from being vacuous: the worktree register is byte-identical to the candidate's
# again, so a guard that only compared the worktree would open the route and
# waive this line. `candidate` here is therefore a fact about the INDEX.
qr_log "$L020_LINE"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "a STAGED entry whose worktree copy has been put back closes the route too — the bytes on disk match the candidate again, and the index still holds a register one commit away from being the candidate's own"
git -C "$QR" add tests/QUARANTINE.md
assert_eq flaky "$(qr_cls | cut -f1)" \
  "while a register restored at both ends is an authority again"
git -C "$QR" rm -q --cached tests/QUARANTINE.md
assert_eq candidate "$(qr_cls | cut -f1)" \
  "an UNTRACKED register is no authority at all — the candidate recorded nothing about it, so nothing establishes that it is not the implementer's own file"
git -C "$QR" add tests/QUARANTINE.md
mv "$QR_REG" "$QR_REG.away"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "and a register MISSING from the verified worktree answers nothing"
mv "$QR_REG.away" "$QR_REG"
assert_eq flaky "$(qr_cls | cut -f1)" \
  "and every one of those restores to the route it started from"

# --- ORCHID'S OWN REGISTER, LIVE, AND THE TRIPWIRE ON BOTH ITS ENDS -------
# Everything above drives the classifier through a register this fixture wrote.
# This drives it through THE FILE ORCHID SHIPS, committed as the fixture's BASE
# so it is pre-candidate state in the sense the route requires -- which is the
# only way to prove that the entry orchid actually carries would be honoured.
#
# Those entries are L020's TWO PRE-T019 diagnostic families, and the assertions
# below are what make carrying them safe. The de-flaked assertions still in the
# tree are the stall detector's own evidence and must never be forgiven; the old
# single-instant families cannot tell a stall from a loaded machine and are not
# evidence about anything. Their sentences are disjoint, so entries naming the
# old families cannot reach the live ones -- and if anyone ever rewords either
# side into the other's shape, this block fails and says so.
[ -f "$REPO_ROOT/tests/QUARANTINE.md" ] \
  || fail "orchid must ship the register flaky.quarantine defaults to (tests/QUARANTINE.md), or its own default path is a path to nothing"
ORCHID_FLAKES="$(grep -c '^FLAKE:' "$REPO_ROOT/tests/QUARANTINE.md" || true)"
assert_eq 2 "$ORCHID_FLAKES" \
  "and it carries EXACTLY TWO live entries — the pre-T019 stream-growth and heartbeat-count families, and nothing else. All eight live assertions were DE-FLAKED rather than quarantined (tests/helpers.sh's await_log_growth/await_log_heartbeat) and must stay chargeable. If this count ever moves, somebody has decided another gate may fail without failing, and this assertion is where they have to say so out loud"

QS="$WORK/shipped-register"
mkdir -p "$QS/.orchid/tasks" "$QS/.orchid/reviews" "$QS/tests"
cd "$QS" || exit 1
git init -q .
: > "$QS/orchid.config"
cp "$REPO_ROOT/tests/QUARANTINE.md" "$QS/tests/QUARANTINE.md"
printf 'x\n' > "$QS/file.txt"
git add -A
git commit -q -m "fixture: orchid's own shipped register, as pre-candidate state"
QSBASE="$(git -C "$QS" rev-parse HEAD)"
printf 'y\n' > "$QS/file.txt"
git add -A
git commit -q -m "fixture: a candidate that does not touch the shipped register"
QSCAND="$(git -C "$QS" rev-parse HEAD)"
printf -- '---\nschema: 1\nid: QS1\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
  "$QS" "$QSBASE" "$QSCAND" > "$QS/.orchid/tasks/QS1.md"
qs_log() {
  printf 'date: 2026-08-10T00:00:00Z\nsha: %s\ncandidate: %s\ncwd: %s\ncommand: bash tests/run.sh\n---\n%s\nexit: 1\n' \
    "$QSCAND" "$QSCAND" "$QS" "$1" > "$QS/.orchid/reviews/QS1-verify.log"
}
qs_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$QS" "$QS/.orchid/tasks/QS1.md" \
      "$QS/.orchid/reviews/QS1-verify.log" )
}
SHIPPED_SIGS="$(
  HOME="$MACHINE_HOME"
  drive_quarantine_signatures "$QS" "$QS" "$QS/.orchid/tasks/QS1.md"
)"
SHIPPED_CONTEXTS="$(
  HOME="$MACHINE_HOME"
  drive_quarantine_contexts "$QS" "$QS" "$QS/.orchid/tasks/QS1.md"
)"
# THE DIAGNOSTIC IS CLIPPED, AND THAT IS NOT COSMETIC. Every failing line this
# suite prints ends up in a verify log that orchid's own classifier then reads.
# Interpolating the SHIPPED signature into a FAIL line would put that signature
# in the output of the very guard that parses the register carrying it — so
# this assertion breaking would produce a failure the register itself waives,
# and the one check standing between orchid and a second live entry would fail
# without failing. A clipped rendering is diagnostic enough and cannot contain
# the whole signature, which is what `grep -F` matching needs.
#
# The clip is 15 characters because the register's own minimum signature length
# is 16, but nothing here relies on my having read that constant correctly: the
# assertion immediately below runs the clipped text through THE REAL MATCHER
# and requires it to match nothing. If the minimum ever drops, or the clip ever
# grows, that is what says so.
SHIPPED_SIGS_CLIPPED="$(cut -c1-15 <<<"$SHIPPED_SIGS" | tr '\n' '/')"
while IFS= read -r shipped_sig; do
  [ -n "$shipped_sig" ] || continue
  assert_eq "" "$(drive_quarantine_attribution "$shipped_sig" \
      "  FAIL: a guard over the shipped register broke (got, clipped: $SHIPPED_SIGS_CLIPPED)")" \
    "a clipped rendering must not be text either shipped signature matches — this suite's failing lines land in a verify log the classifier then reads, so a guard that printed a live signature into its own FAIL line would be waived by the register it exists to police"
done <<< "$SHIPPED_SIGS"
assert_eq 2 "$(grep -c . <<<"$SHIPPED_SIGS" || true)" \
  "the shipped register parses to exactly two live signatures through the real parser — the prose around them, including its own indented worked example of the format, is read as prose (got, clipped: $SHIPPED_SIGS_CLIPPED)"
assert_eq 51 "$(grep -c . <<<"$SHIPPED_CONTEXTS" || true)" \
  "and it parses to exactly 51 closed companion lines — the unique non-empty successful-fixture output of the four pre-T019 engine-adapter tests, not an open-ended child block"
assert_match "job log must have grown" "$SHIPPED_SIGS" \
  "one signature is L020's pre-T019 stream-growth family"
assert_match "job log must gain at least one" "$SHIPPED_SIGS" \
  "and the other is L020's pre-T019 heartbeat-count family"

# BOTH ENTRIES WORK, ON BOTH OLD LENGTHS. Agy/Claude/Codex carried longer
# explanations while Hermes stopped at the common prefix; the common literal
# must catch both without reaching any live bounded-wait assertion.
OLD_GROWTH_SIG="$(grep -F 'job log must have grown' <<< "$SHIPPED_SIGS" || true)"
OLD_HEARTBEAT_SIG="$(grep -F 'job log must gain at least one' <<< "$SHIPPED_SIGS" || true)"
[ -n "$OLD_GROWTH_SIG" ] && [ -n "$OLD_HEARTBEAT_SIG" ] \
  || fail "the two shipped signatures could not be selected by their clipped family names"
while IFS= read -r shipped_sig; do
  [ -n "$shipped_sig" ] || continue
  if grep -Fq -- "$shipped_sig" "$REPO_ROOT/tests/test_drive.sh"; then
    fail "tests/test_drive.sh embeds a live quarantine signature verbatim, so a failing self-check could print its own amnesty (got, clipped: $SHIPPED_SIGS_CLIPPED)"
  fi
done <<< "$SHIPPED_SIGS"
qs_log "  FAIL: $OLD_GROWTH_SIG (was 0 bytes at the midpoint) -- this is the stall-detector's liveness signal"
assert_eq flaky "$(qs_cls | cut -f1)" \
  "the long pre-T019 stream-growth diagnostic is waived by the shipped register"
qs_log "  FAIL: $OLD_GROWTH_SIG"
assert_eq flaky "$(qs_cls | cut -f1)" \
  "and Hermes's shorter pre-T019 stream-growth diagnostic is waived too"
qs_log "  FAIL: $OLD_HEARTBEAT_SIG (stub produced zero output of its own until exit) -- this is the liveness signal the stall detector depends on"
assert_eq flaky "$(qs_cls | cut -f1)" \
  "the long pre-T019 heartbeat-count diagnostic is waived by the shipped register"
qs_log "  FAIL: $OLD_HEARTBEAT_SIG"
assert_eq flaky "$(qs_cls | cut -f1)" \
  "and Hermes's shorter pre-T019 heartbeat-count diagnostic is waived too"

# THE ACTUAL OLD-RUNNER SHAPE: every registered successful-fixture line is in
# the same failed child buffer as the historical assertion. Drive the complete
# closed set through classification rather than proving only a tidy one-line
# rendering. The two strict edges immediately after it prove the list is not a
# global neutral vocabulary and is not a failed-child cascade.
qs_log "$SHIPPED_CONTEXTS
  FAIL: $OLD_GROWTH_SIG (was 0 bytes at the midpoint) -- this is the stall-detector's liveness signal"
assert_eq flaky "$(qs_cls | cut -f1)" \
  "the full pre-T019 engine-adapter companion set plus its causal liveness signature classifies flaky, matching the buffered body carried branches really emit"
qs_log "$SHIPPED_CONTEXTS"
assert_eq candidate "$(qs_cls | cut -f1)" \
  "the full companion set without either historical signature charges — registered context is never globally neutral"
qs_log "$SHIPPED_CONTEXTS
  FAIL: $OLD_GROWTH_SIG
adapter fixture emitted one novel diagnostic"
assert_eq candidate "$(qs_cls | cut -f1)" \
  "one novel line beside the full companion set and causal signature still charges, preserving fail-closed mixed attribution"
assert_match "one novel diagnostic" "$(qs_cls | cut -f2-)" \
  "and the charged reason identifies the exact line outside the closed companion set"

# AND NEITHER ENTRY CAN REACH THE ASSERTIONS THAT REPLACED IT. Taken verbatim
# from the suite rather than retyped here: if an old and live sentence ever
# converge, these are the lines that stop it.
DEFLAKED_GROWTH_SRC="$(grep -F -m1 -- "$L020_SIG" "$REPO_ROOT/tests/test_engine_agy.sh" || true)"
DEFLAKED_HEARTBEAT_SRC="$(grep -F -m1 -- 'bounded heartbeat wait must leave at least one persisted' "$REPO_ROOT/tests/test_engine_agy.sh" || true)"
[ -n "$DEFLAKED_GROWTH_SRC" ] && [ -n "$DEFLAKED_HEARTBEAT_SRC" ] \
  || fail "the two de-flaked liveness assertions have vanished from tests/test_engine_agy.sh — the RED halves below would then assert nothing"
qs_log "  FAIL: $DEFLAKED_GROWTH_SRC"
assert_eq candidate "$(qs_cls | cut -f1)" \
  "the live bounded growth assertion is NOT covered and charges — it waits for what it samples, so its failure is evidence"
qs_log "  FAIL: $DEFLAKED_HEARTBEAT_SRC"
assert_eq candidate "$(qs_cls | cut -f1)" \
  "the live bounded heartbeat assertion is NOT covered and charges for the same reason"
qs_engine_count=0
for qs_engine_f in "$REPO_ROOT"/tests/test_engine_*.sh; do
  [ -f "$qs_engine_f" ] || continue
  qs_engine_count=$((qs_engine_count + 1))
  while IFS= read -r shipped_sig; do
    [ -n "$shipped_sig" ] || continue
    if grep -Fq -- "$shipped_sig" "$qs_engine_f"; then
      fail "${qs_engine_f#"$REPO_ROOT"/} contains a sentence orchid's own register quarantines — a live engine-adapter case can now fail without failing"
    fi
  done <<< "$SHIPPED_SIGS"
done
[ "$qs_engine_count" -ge 4 ] \
  || fail "that sweep looked at $qs_engine_count engine-adapter file(s) rather than the four that carry these cases — it would report a clean tree by finding nothing to read"

# --- A CARRIED BRANCH CUT BEFORE THE REGISTER EXISTED ----------------------
# This is r-002's live topology: task worktrees were cut before T019, while the
# integration checkout receives the register only when T019 merges. Requiring
# the register to exist in the old candidate makes the entry unreachable in
# exactly the worktrees that can still print the old assertion. The narrow
# fallback reads integration's copy only when BOTH task commits answerably lack
# the path; candidate addition and deletion are pinned below as closed routes.
QO="$WORK/old-register-control"
QOW="$WORK/old-register-task"
QOD="$WORK/deleted-register-task"
QOH="$WORK/hostile-register-task"
mkdir -p "$QO"
cd "$QO" || exit 1
git init -q .
: > "$QO/orchid.config"
printf 'old\n' > "$QO/file.txt"
git add -A
git commit -q -m "fixture: base predates the quarantine register"
QOBASE="$(git -C "$QO" rev-parse HEAD)"
git -C "$QO" worktree add -q "$QOW" -b task/old-register "$QOBASE" 2>/dev/null \
  || fail "fixture: could not create the pre-register task worktree"
printf 'candidate\n' > "$QOW/file.txt"
git -C "$QOW" add file.txt
git -C "$QOW" commit -q -m "fixture: candidate also predates the register"
QOCAND="$(git -C "$QOW" rev-parse HEAD)"

# Integration learns the historical flake after that branch was cut. The task
# worktree deliberately remains on QOCAND and therefore has no tests/ directory
# at all, which is the state the fallback exists for rather than a staged copy
# of the new file.
mkdir -p "$QO/tests"
cp "$REPO_ROOT/tests/QUARANTINE.md" "$QO/tests/QUARANTINE.md"
git -C "$QO" add tests/QUARANTINE.md
git -C "$QO" commit -q -m "fixture: integration records the historical flake"
QOHEAD="$(git -C "$QO" rev-parse HEAD)"
[ ! -e "$QOW/tests/QUARANTINE.md" ] \
  || fail "fixture invalid: the carried task worktree unexpectedly received the post-cut register"

mkdir -p "$QO/.orchid/tasks" "$QO/.orchid/reviews"
qo_task() { # <id> <worktree> <base> <candidate>
  printf -- '---\nschema: 1\nid: %s\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$1" "$2" "$3" "$4" > "$QO/.orchid/tasks/$1.md"
}
qo_log() { # <id> <worktree> <candidate> [failure-body] [prestate-snapshot]
  local qo_body="${4:-}" qo_snapshot
  [ -n "$qo_body" ] \
    || qo_body="looks fine
  FAIL: $OLD_GROWTH_SIG (was 0 bytes at the midpoint) -- this is the stall-detector's liveness signal"
  if [ "$#" -ge 5 ]; then
    qo_snapshot="$5"
  else
    qo_snapshot="$(drive_verify_prestate_headers "$QO" "$QO/.orchid/tasks/$1.md")"
  fi
  printf 'date: 2026-08-10T00:00:00Z\nsha: %s\ncandidate: %s\ncwd: %s\ncommand: bash tests/run.sh\n%s\n---\n%s\nexit: 1\n' \
    "$3" "$3" "$2" "$qo_snapshot" "$qo_body" \
    > "$QO/.orchid/reviews/$1-verify.log"
}
qo_cls() { # <id>
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$QO" "$QO/.orchid/tasks/$1.md" \
      "$QO/.orchid/reviews/$1-verify.log" )
}

qo_task QO1 "$QOW" "$QOBASE" "$QOCAND"
qo_log QO1 "$QOW" "$QOCAND"
assert_eq flaky "$(qo_cls QO1 | cut -f1)" \
  "a carried task whose base and candidate both predate the register reads the clean tracked integration copy, so the exact pre-T019 failure no longer burns its attempt"
qo_log QO1 "$QOW" "$QOCAND" \
  "VERDICT: approve
  FAIL: $OLD_HEARTBEAT_SIG (stub produced zero output of its own until exit) -- this is the liveness signal the stall detector depends on"
assert_eq flaky "$(qo_cls QO1 | cut -f1)" \
  "and the same carried task classifies the sibling pre-T019 heartbeat-count failure as flaky rather than charging it"
assert_match "job log must have grown" "$(drive_quarantine_signatures \
    "$QO" "$QOW" "$QO/.orchid/tasks/QO1.md")" \
  "the fallback exposes the historical stream-growth signature at the register layer"
assert_match "job log must gain at least one" "$(drive_quarantine_signatures \
    "$QO" "$QOW" "$QO/.orchid/tasks/QO1.md")" \
  "and it exposes the historical heartbeat-count signature there too"

# Integration's copy is a control-plane authority, not ambient bytes. A dirty
# edit closes it just as a dirty candidate-owned register does.
QO_REG_BYTES="$WORK/old-register.committed"
cp "$QO/tests/QUARANTINE.md" "$QO_REG_BYTES"
printf '\nFLAKE: candidate bug that integration never committed\n' >> "$QO/tests/QUARANTINE.md"
assert_eq candidate "$(qo_cls QO1 | cut -f1)" \
  "a dirty integration register is no authority for an old branch — the fallback requires HEAD, index, bytes, and mode to agree"
cp "$QO_REG_BYTES" "$QO/tests/QUARANTINE.md"
assert_eq flaky "$(qo_cls QO1 | cut -f1)" \
  "restoring the clean integration authority restores the carried-branch waiver"

# A candidate that ADDS the path cannot borrow integration's older/trusted
# copy, even when the bytes happen to match. Its candidate commit carries the
# path, so the both-commits-lack condition is false; its own authority is false
# because it changed the register.
mkdir -p "$QOW/tests"
cp "$QO/tests/QUARANTINE.md" "$QOW/tests/QUARANTINE.md"
git -C "$QOW" add tests/QUARANTINE.md
git -C "$QOW" commit -q -m "fixture: candidate adds the register itself"
QOADD="$(git -C "$QOW" rev-parse HEAD)"
qo_task QO1 "$QOW" "$QOBASE" "$QOADD"
qo_log QO1 "$QOW" "$QOADD"
assert_eq candidate "$(qo_cls QO1 | cut -f1)" \
  "a candidate-added register forgives nothing and cannot fall back to integration, even when it copied integration's exact bytes"

# A candidate that DELETES a register is the other half: candidate lacks the
# path, but base does not, so the fallback stays closed rather than undoing the
# deletion from the control checkout behind the candidate's back.
git -C "$QO" worktree add -q "$QOD" -b task/delete-register "$QOHEAD" 2>/dev/null \
  || fail "fixture: could not create the register-deletion worktree"
git -C "$QOD" rm -q tests/QUARANTINE.md
git -C "$QOD" commit -q -m "fixture: candidate deletes the register"
QODEL="$(git -C "$QOD" rev-parse HEAD)"
qo_task QO2 "$QOD" "$QOHEAD" "$QODEL"
qo_log QO2 "$QOD" "$QODEL"
assert_eq candidate "$(qo_cls QO2 | cut -f1)" \
  "a candidate-deleted register forgives nothing and cannot be resurrected from integration, because its base already carried the path"

# The integration authority is also a PRE-RUN fact. The verification command
# executes candidate-controlled repository code and inherits enough context to
# address the integration checkout. Without the captured-HEAD binding it can
# commit a matching FLAKE entry there after verification begins; the fallback
# then compares that malicious file to its own new HEAD, finds it perfectly
# clean, and forgives the defect that wrote it.
git -C "$QO" worktree add -q "$QOH" -b task/hostile-register "$QOCAND" 2>/dev/null \
  || fail "fixture: could not create the old branch used by the hostile verifier"
qo_task QO3 "$QOH" "$QOBASE" "$QOCAND"
QO_PRE_ATTACK="$(drive_verify_prestate_headers "$QO" "$QO/.orchid/tasks/QO3.md")"
printf '\nFLAKE: widget returned 3, expected 4 -- committed by candidate-controlled verification\n' \
  >> "$QO/tests/QUARANTINE.md"
git -C "$QO" add tests/QUARANTINE.md
git -C "$QO" commit -q -m "fixture: verifier tries to mint its own integration waiver"
qo_log QO3 "$QOH" "$QOCAND" '  FAIL: widget returned 3, expected 4' "$QO_PRE_ATTACK"
assert_match "widget returned 3" "$(drive_quarantine_signatures \
    "$QO" "$QOH" "$QO/.orchid/tasks/QO3.md")" \
  "RED control: without a pre-verification HEAD binding, the old fallback trusts the verifier's newly committed integration entry"
assert_eq "" "$(drive_quarantine_signatures \
    "$QO" "$QOH" "$QO/.orchid/tasks/QO3.md" "$QOHEAD")" \
  "GREEN control: binding the fallback to pre-verification HEAD exposes no signature after the verifier moves that ref"
assert_eq candidate "$(qo_cls QO3 | cut -f1)" \
  "a register committed to integration after verification began forgives nothing — current HEAD no longer matches the pre-verification control-plane authority"
cd "$QR" || exit 1

# --- THE SAFETY PROPERTY: a register the candidate touched is no authority.
# LAST in this part, deliberately: it leaves the register with an entry that
# would forgive `widget returned 3` outright, so every assertion above is made
# against a register the candidate did not write.
printf '\nFLAKE: widget returned 3, expected 4 -- added by the candidate itself\n' >> "$QR/tests/QUARANTINE.md"
git -C "$QR" add tests/QUARANTINE.md
git -C "$QR" commit -q -m "fixture: the candidate quarantines its own failure"
fm_set "$QR/.orchid/tasks/QA1.md" candidate_sha "$(git -C "$QR" rev-parse HEAD)"
qr_log '  FAIL: widget returned 3, expected 4'
assert_eq candidate "$(qr_cls | cut -f1)" \
  "quarantining the assertion you are failing must be impossible: the candidate CHANGED the register, so there is no register — this is the whole safety of the flaky route, and without it a repository could buy an amnesty for any failure by writing one line"
qr_log "looks fine
$L020_LINE"
assert_eq candidate "$(qr_cls | cut -f1)" \
  "and the route is lost for entries the candidate did NOT write either, including the genuine L020 one and its context — a file this candidate edited is not evidence about this candidate, and a per-entry rule would just move the abuse one line down"

# ===========================================================================
# Part Y6 -- A RUN THAT STOPPED SHORT IS REPORTED, AND STILL CHARGED.
#
# THIS PART USED TO ASSERT THE OPPOSITE, AND THE INVERSION IS THE POINT. Exit
# 124, 137 or 143 was read as "the harness reaped this pass, so it never spoke
# about the candidate" and waived the round under a fifth class, `harness`.
# That premise was assumed rather than proved. The identical trailer is what a
# candidate that HANGS until a timeout reaps it leaves -- which is a defect,
# and precisely the defect a `timeout` in a verification command line is there
# to catch -- and what a suite that exits with the status deliberately, or
# forwards a killed child's, leaves. Nothing in the log tells the three apart.
#
# This classifier's own rule is that an uncertain reading CHARGES and says why,
# and that rule was being applied to every other arm while this one assumed its
# way past it. So the status is still READ and still REPORTED -- an operator
# looking at a charged round must not be left wondering why the log stops where
# it does -- and the attempt is charged. Both edges are pinned per L034: the
# report is present, and the class is `candidate`.
# ===========================================================================
HRN="$WORK/harness"
mkdir -p "$HRN/.orchid/tasks" "$HRN/.orchid/reviews"
cd "$HRN" || exit 1
git init -q .
: > "$HRN/orchid.config"
printf 'x\n' > "$HRN/file.txt"
git add -A
git commit -q -m "fixture: root"
printf -- '---\nschema: 1\nid: HR1\nstatus: testing\narchetype: feature\nattempts: 0\nworktree: %s\n---\nbody\n' \
  "$HRN" > "$HRN/.orchid/tasks/HR1.md"
hr_log() {  # <body> <rc>
  printf 'date: 2026-08-10T00:00:00Z\nsha: deadbeef\ncandidate: deadbeef\ncwd: %s\ncommand: bash tests/run.sh\n---\n%s\nexit: %s\n' \
    "$HRN" "$1" "$2" > "$HRN/.orchid/reviews/HR1-verify.log"
}
hr_cls() {
  ( HOME="$MACHINE_HOME"
    drive_verify_class "$HRN" "$HRN/.orchid/tasks/HR1.md" \
      "$HRN/.orchid/reviews/HR1-verify.log" )
}

hr_log '== tests/test_engine_agy.sh
Terminated: 15' 143
assert_eq 143 "$(drive_verify_exit "$HRN/.orchid/reviews/HR1-verify.log")" \
  "the recorded exit status is read from the verb's own trailer, which is a fact about the run rather than a sentence in it"
assert_eq candidate "$(hr_cls | cut -f1)" \
  "and a run that stopped at 143 CHARGES: that is equally the trailer a candidate which hung until something reaped it leaves, and equally the one a suite that exited 143 on purpose leaves, so the provenance an amnesty would need was never proved — only assumed"
HR_REASON="$(hr_cls | cut -f2-)"
assert_match "stopped short" "$HR_REASON" \
  "the status is still REPORTED, because an operator reading a charged round must not be left wondering why the log ends where it does"
assert_match "143" "$HR_REASON" \
  "naming the status itself, which is the fact orchid actually has"
assert_match "HUNG" "$HR_REASON" \
  "and naming the reading it CANNOT rule out, which is why it charges rather than forgives"
case "$HR_REASON" in
  *'attempt not charged'*|*'not the candidate'*)
    fail "a charged round's reason must not read as a waiver: this is the sentence an operator uses to tell 'we forgave this' from 'we could not tell' ($HR_REASON)" ;;
esac
hr_log 'timeout: sending signal TERM' 124
assert_eq candidate "$(hr_cls | cut -f1)" \
  "and so does a run its own timeout(1) killed — a timeout in a verification command line exists to catch a candidate that hangs, so waiving what it catches was forgiving the defect it was configured to find"
assert_match "124" "$(hr_cls | cut -f2-)" \
  "with that status named too"
hr_log 'zsh: killed' 137
assert_eq candidate "$(hr_cls | cut -f1)" \
  "and one SIGKILLed, which is an out-of-memory reap and is also what a runaway candidate looks like from outside"

# --- a killed run that had already reported real failures -----------------
hr_log '  FAIL: widget returned 3, expected 4
Terminated: 15' 143
assert_eq candidate "$(hr_cls | cut -f1)" \
  "a suite that printed a real assertion failure BEFORE it stopped is charged for that failure as well"
assert_match "widget returned 3" "$(hr_cls | cut -f2-)" \
  "and the reason quotes it, rather than letting the truncation speak for the round"
assert_match "stopped short" "$(hr_cls | cut -f2-)" \
  "while still reporting that the run stopped short, so both facts reach the operator"

# --- and an ordinary failing exit is not a kill ---------------------------
hr_log '== tests/test_engine_agy.sh
Terminated: 15' 1
assert_eq candidate "$(hr_cls | cut -f1)" \
  "an ordinary failing exit charges too, and for its own reasons: nothing here stopped short, so the report above must not appear"
case "$(hr_cls | cut -f2-)" in
  *'stopped short'*) fail "exit 1 is a verdict, not a truncation — reporting one here would put a sentence about a killed run on every ordinary failure in the repository" ;;
esac
assert_match "no failure-attributable waivable state was established" "$(hr_cls | cut -f2-)" \
  "it takes the ordinary strict default instead — and this is also what proves the WORDS 'Terminated: 15' decide nothing on their own, since this repository's own passing fixtures print exactly that line about processes they reaped on purpose"

# ===========================================================================
# Part Y7 -- THE POOL IS ACROSS CLASSES, NOT WITHIN ONE.
#
# An earlier round required ONE artifact to account for the whole round, so a
# round in which a stale pin explained six lines and a dropped mode bit
# explained four was charged with every failure in it an operator's. The same
# reasoning applies across classes: a round that is half a missing dependency
# tree and half an unset mode bit is no more the candidate's than either half
# alone. What a waiver needs is that nothing is left over.
# ===========================================================================
MIXW="$WORK/l003-worktree"
mkdir -p "$MIXW/libexec"
printf '#!/usr/bin/env bash\necho frob\n' > "$MIXW/libexec/orchid-frob"
chmod 644 "$MIXW/libexec/orchid-frob"
git -C "$MIXW" add libexec/orchid-frob
git -C "$MIXW" commit -q -m "fixture: a candidate that also ships a verb at mode 644"
fm_set "$ENVR/.orchid/tasks/EV1.md" base_sha "$(git -C "$MIXW" rev-parse HEAD~1)"
fm_set "$ENVR/.orchid/tasks/EV1.md" candidate_sha "$(git -C "$MIXW" rev-parse HEAD)"
# Both lines are FAILING lines here, unlike the bare yarn diagnostic Part Y4
# used. That is what makes this a pool rather than a short-circuit: the exec
# bit explains one of them and cannot explain the other, so the round is
# decided only after the missing tree has spoken too.
ev_log '  FAIL: yarn test: error Command "jest" not found
bash: libexec/orchid-frob: Permission denied'
assert_eq handoff "$(ev_cls | cut -f1)" \
  "two DIFFERENT classes, each explaining part of one round, together account for all of it and it is waived — and the class NAMED is the hand-off, the one an operator has to act on first"
assert_match "mobile/node_modules" "$(ev_cls | cut -f2-)" \
  "and the reason names the absent dependency tree"
assert_match "orchid-frob" "$(ev_cls | cut -f2-)" \
  "and the file awaiting chmod, because an operator who clears one, re-dispatches and walks into the other has learned nothing from the first journal line"
ev_log '  FAIL: yarn test: error Command "jest" not found
bash: libexec/orchid-frob: Permission denied
  FAIL: widget returned 3, expected 4'
assert_eq candidate "$(ev_cls | cut -f1)" \
  "and one further line neither of them owns still charges the whole round — pooling relaxes WHO must explain a failure, never WHETHER every failure is explained"
assert_match "widget returned 3" "$(ev_cls | cut -f2-)" \
  "quoting the line it could not attribute to either"

# A state can remain owed without explaining this round. Make the helper
# executable in a new base, then drop that recorded 755 bit in its candidate;
# the environment failure below says nothing about the helper, so the bit must
# not contribute attribution, but restoring it is still an operator action the
# waived-round journal cannot hide.
chmod +x "$MIXW/libexec/orchid-frob"
git -C "$MIXW" add libexec/orchid-frob
git -C "$MIXW" update-index --chmod=+x libexec/orchid-frob
git -C "$MIXW" commit -q -m "fixture: executable helper becomes the next base"
MIX_DROP_BASE="$(git -C "$MIXW" rev-parse HEAD)"
chmod -x "$MIXW/libexec/orchid-frob"
git -C "$MIXW" add libexec/orchid-frob
git -C "$MIXW" update-index --chmod=-x libexec/orchid-frob
git -C "$MIXW" commit -q -m "fixture: candidate drops the helper's exec bit"
fm_set "$ENVR/.orchid/tasks/EV1.md" base_sha "$MIX_DROP_BASE"
fm_set "$ENVR/.orchid/tasks/EV1.md" candidate_sha "$(git -C "$MIXW" rev-parse HEAD)"
ev_log '  FAIL: yarn test: error Command "jest" not found'
assert_eq environment "$(ev_cls | cut -f1)" \
  "the missing dependency tree alone earns this waiver; an unrelated dropped exec bit is state, not attribution"
MIX_FALLBACK_REASON="$(ev_cls | cut -f2-)"
assert_match "chmod [+]x libexec/orchid-frob" "$MIX_FALLBACK_REASON" \
  "the waived reason still reports the candidate-dropped 755 bit as an operator step owed independently of the failure that was waived"
assert_match "not attributable to the printed failures" "$MIX_FALLBACK_REASON" \
  "and labels the dropped bit as fallback state, so reporting it cannot be misread as letting it earn the waiver"
