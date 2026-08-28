#!/usr/bin/env bash
# tests/test_archetype_suite.sh -- v1-m3 Task 8: the `refactor`/`test`/
# `migrate` archetypes. All three are outcome=code with the FULL feature
# transition set (data-only copies, verbatim -- INV-05: no archetype-name
# branching anywhere in the kernel reads this), so they merge code and MUST
# pass testing+reviewing per the meta-contract (docs/specs/plugins.md).
# They differ only in template lens text (body, guidance-only, no
# executable predicates) and frontmatter defaults:
#   refactor: risk_tier medium, blocking_severity medium
#   test:     risk_tier low
#   migrate:  risk_tier medium, exclusive true
# Mirrors tests/test_archetype.sh's direct-sourced unit section plus
# tests/test_task.sh's T007 archetype-edge-walk convention (reused here,
# once per new archetype) for the full-transition-set proof.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/archetype.sh"
export ORCHID_ROOT="$REPO_ROOT"

# ============================================================================
# Unit level: all three declare feature's exact transition table, verbatim,
# outcome=code, and pass archetype_validate.
# ============================================================================
expected_feature="$(cat <<'EOF'
pending:implementing
implementing:testing
testing:reviewing
testing:rework
reviewing:arbitrating
arbitrating:merging
arbitrating:rework
merging:done
merging:rework
merging:testing
rework:implementing
rework:testing
blocked:testing
EOF
)"

for a in refactor test migrate; do
  actual="$(archetype_transitions "$a")"
  assert_eq "$expected_feature" "$actual" "$a archetype declares feature's exact transition table, verbatim"
  assert_eq code "$(archetype_outcome "$a")" "$a archetype outcome=code"
  out="$(archetype_validate "$a")"; rc=$?
  assert_eq 0 "$rc" "$a archetype passes archetype_validate (rc=$rc): $out"
  assert_match "^ok" "$out" "archetype_validate prints an ok line for $a"
done

# ============================================================================
# Integration level: `orchid task create --archetype <a>` per-archetype
# template lookup (templates/task-<a>.md), frontmatter defaults, and body
# lens text.
# ============================================================================
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

fm_field() { "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }

# -- refactor: risk_tier medium, blocking_severity medium, behavior-
# preserving lens text in the body --------------------------------------
"$ORCHID_BIN" task create RF001 "rename the widget module" --archetype refactor
assert_eq refactor "$(fm_field RF001 archetype)" "task create --archetype refactor writes archetype: refactor"
assert_eq medium "$(fm_field RF001 risk_tier)" "refactor template defaults risk_tier: medium"
assert_eq medium "$(fm_field RF001 blocking_severity)" "refactor template defaults blocking_severity: medium"
rf_body="$("$ORCHID_BIN" task show RF001)"
assert_match "behavior-preserving" "$rf_body" "refactor task body carries the behavior-preserving lens"
assert_match "characterization tests" "$rf_body" "refactor task body names characterization tests as the one exception"

# -- test: risk_tier low, tests-only lens text in the body ------------------
"$ORCHID_BIN" task create TS001 "extend coverage for the parser" --archetype test
assert_eq test "$(fm_field TS001 archetype)" "task create --archetype test writes archetype: test"
assert_eq low "$(fm_field TS001 risk_tier)" "test template defaults risk_tier: low"
ts_body="$("$ORCHID_BIN" task show TS001)"
assert_match "adds/extends tests only" "$ts_body" "test task body carries the tests-only lens"
assert_match "production code edits forbidden" "$ts_body" "test task body forbids production code edits beyond seams"

# -- migrate: risk_tier medium, exclusive true, rollback+idempotence lens --
"$ORCHID_BIN" task create MG001 "migrate the widgets table" --archetype migrate
assert_eq migrate "$(fm_field MG001 archetype)" "task create --archetype migrate writes archetype: migrate"
assert_eq medium "$(fm_field MG001 risk_tier)" "migrate template defaults risk_tier: medium"
assert_eq medium "$(fm_field MG001 blocking_severity)" "migrate template defaults blocking_severity: medium (matches kernel.md's medium-tier derivation, per fix review Important 1 -- a medium-risk migration must not sit at the low-tier blocking threshold)"
assert_eq true "$(fm_field MG001 exclusive)" "migrate template defaults exclusive: true"
mg_body="$("$ORCHID_BIN" task show MG001)"
assert_match "rollback note" "$mg_body" "migrate task body requires a rollback note"
assert_match "idempotence statement" "$mg_body" "migrate task body requires an idempotence statement"
assert_match "Rollback note:" "$mg_body" "migrate task body carries a rollback-note placeholder field"
assert_match "Idempotence statement:" "$mg_body" "migrate task body carries an idempotence-statement placeholder field"

# -- a bare `task create` (no --archetype) is untouched: still archetype:
# feature, using templates/task.md (the fallback), not any new template --
"$ORCHID_BIN" task create DEF001 "default archetype demo"
assert_eq feature "$(fm_field DEF001 archetype)" "task create without --archetype still defaults to archetype: feature"
assert_eq low "$(fm_field DEF001 risk_tier)" "default (feature) task still gets templates/task.md's plain risk_tier: low"

# -- create-time template defaults are NOT monotonic-rule violations: no
# risk_change journal entry was written for any of the three creates above
# (the rule guards `task set risk_tier`, a POST-create change -- fm
# substitution at create time never touches that code path at all) --------
[ -f .orchid/journal.md ] && grep -q "risk_change" .orchid/journal.md && \
  fail "template-substituted risk_tier defaults at create time must never journal a risk_change entry"

# ============================================================================
# Full transition-set walk, once per new archetype (mirrors tests/
# test_task.sh's T007 archetype-edge walk): a real task, of that archetype,
# is driven through EVERY edge the (feature-identical) declared table
# names, proving the archetype-driven `legal()` path -- and every kernel
# gate that outcome=code exercises (INV-11 verify evidence, the sha-bound
# reviewer-envelope-count gate) -- works identically for a non-feature
# archetype, with real stubs standing in for implement/review/merge
# dispatch.
# ============================================================================
# plant_reviewer_envelope_pair <id> -- plants TWO reconciled reviewer
# envelopes (helpers.sh's plant_reviewer_envelope plus a `.2.json` twin,
# same collision-suffix convention `jobs reconcile` itself uses) so the
# reviewing->arbitrating gate is satisfied regardless of risk_tier: low
# needs 1 (lib/review.sh's review_required_count), medium/high need 2. A
# spare second envelope for a low-tier task is harmless (the gate is
# `>=`, not `==`), so one helper covers all three archetypes' walks.
plant_reviewer_envelope_pair() {
  local id="$1" attempt cand
  plant_reviewer_envelope "$id"
  attempt=$(( $("$ORCHID_BIN" task show "$id" | grep '^attempts: ' | cut -d' ' -f2) + 1 ))
  cand="$("$ORCHID_BIN" task show "$id" | grep '^candidate_sha: ' | cut -d' ' -f2-)"
  jq -n --arg jid "j-fixture-$id-a$attempt-2" --arg task "$id" --arg cand "$cand" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:"approve", scope_complete:true, summary:"fixture reviewer 2", candidate_sha:$cand}' \
    > ".orchid/reviews/$id-a$attempt-reviewer.2.json"
}

walk_full_archetype() {  # id archetype
  local id="$1" arch="$2"
  "$ORCHID_BIN" task create "$id" "full walk ($arch)" --archetype "$arch"
  # The fixture's own HEAD, not a placeholder: base == candidate makes a real,
  # empty INV-04 range and satisfies T031's worktree/candidate drift check.
  local sha
  sha="$(git rev-parse HEAD)"
  "$ORCHID_BIN" task set "$id" base_sha "$sha"
  "$ORCHID_BIN" task set "$id" candidate_sha "$sha"
  "$ORCHID_BIN" task set "$id" verification_commands true
  st() { "$ORCHID_BIN" task show "$id" | grep '^status: ' | cut -d' ' -f2; }

  # edge: pending:implementing
  "$ORCHID_BIN" task advance "$id" implementing
  assert_eq implementing "$(st)" "$arch edge pending:implementing"

  # edge: implementing:testing
  "$ORCHID_BIN" task advance "$id" testing
  assert_eq testing "$(st)" "$arch edge implementing:testing"

  # edge: testing:rework (bumps attempts 0 -> 1)
  "$ORCHID_BIN" task advance "$id" rework
  assert_eq rework "$(st)" "$arch edge testing:rework"
  assert_eq 1 "$("$ORCHID_BIN" task show "$id" | grep '^attempts: ' | cut -d' ' -f2)" "$arch testing:rework bumped attempts to 1"

  # edge: rework:implementing
  "$ORCHID_BIN" task advance "$id" implementing
  assert_eq implementing "$(st)" "$arch edge rework:implementing"

  # edge: implementing:testing (again) -> real verify evidence -> reviewing
  "$ORCHID_BIN" task advance "$id" testing
  "$ORCHID_BIN" verify "$id" >/dev/null

  # edge: testing:reviewing
  "$ORCHID_BIN" task advance "$id" reviewing
  assert_eq reviewing "$(st)" "$arch edge testing:reviewing"
  plant_reviewer_envelope_pair "$id"

  # edge: reviewing:arbitrating
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "single reviewer approved"
  assert_eq arbitrating "$(st)" "$arch edge reviewing:arbitrating"

  # edge: arbitrating:rework (--waive-attempt keeps attempts at 1, so the
  # already-planted reviewer envelope stays valid for every reviewing-
  # >arbitrating below without replanting)
  "$ORCHID_BIN" task advance "$id" rework --waive-attempt --reason "sent back for rework"
  assert_eq rework "$(st)" "$arch edge arbitrating:rework"

  "$ORCHID_BIN" task advance "$id" implementing
  "$ORCHID_BIN" task advance "$id" testing
  "$ORCHID_BIN" verify "$id" >/dev/null
  "$ORCHID_BIN" task advance "$id" reviewing
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "re-reviewed, approved"

  # edge: arbitrating:merging
  "$ORCHID_BIN" task advance "$id" merging --reason "approved for merge"
  assert_eq merging "$(st)" "$arch edge arbitrating:merging"

  # edge: merging:testing (does not invalidate verify evidence)
  "$ORCHID_BIN" task advance "$id" testing
  assert_eq testing "$(st)" "$arch edge merging:testing"

  "$ORCHID_BIN" task advance "$id" reviewing
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "re-reviewed after merging:testing, approved"
  "$ORCHID_BIN" task advance "$id" merging --reason "approved for merge"

  # edge: merging:rework
  "$ORCHID_BIN" task advance "$id" rework --reason "validation_failed: see reviews/$id-merge.log"
  assert_eq rework "$(st)" "$arch edge merging:rework"
  assert_eq 1 "$("$ORCHID_BIN" task show "$id" | grep '^attempts: ' | cut -d' ' -f2)" "$arch merging:rework never bumps attempts (from=merging)"

  "$ORCHID_BIN" task advance "$id" implementing
  "$ORCHID_BIN" task advance "$id" testing
  "$ORCHID_BIN" verify "$id" >/dev/null
  "$ORCHID_BIN" task advance "$id" reviewing
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "re-reviewed, approved"
  "$ORCHID_BIN" task advance "$id" merging --reason "approved for merge"

  # edge: merging:done
  "$ORCHID_BIN" task advance "$id" "done"
  assert_eq "done" "$(st)" "$arch edge merging:done"
}

walk_full_archetype W001 refactor
walk_full_archetype W002 test
walk_full_archetype W003 migrate

# ============================================================================
# Migrate dispatch is gated by the m2 scheduler while anything else is
# active (exclusive:true, from the template default -- see also tests/
# test_schedule.sh's dedicated migrate-task fixture for the fuller
# concurrency-cap/both-directions treatment).
# ============================================================================
"$ORCHID_BIN" task create GATE1 "occupies the active set" >/dev/null
"$ORCHID_BIN" task advance GATE1 implementing >/dev/null

"$ORCHID_BIN" task create GATE2 "gated migration" --archetype migrate >/dev/null
assert_eq true "$(fm_field GATE2 exclusive)" "gated migrate task still defaults exclusive: true"
rc=0; gate_err="$("$ORCHID_BIN" task advance GATE2 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "migrate task dispatch refused while another task is active (exclusive default) exits 3"
assert_match "exclusive-overlap \(GATE1\)" "$gate_err" "refusal names exclusive-overlap against the active task"
assert_eq pending "$(fm_field GATE2 status)" "GATE2 stays pending after the refused exclusive dispatch"

# ============================================================================
# archetype_validate still rejects a tampered variant: a copy of migrate's
# manifest with outcome flipped to `report` while STILL declaring a
# `merging:*` transition -- the exact meta-contract violation the brief
# names (report outcome + merging transition), rejected with exit 13, same
# as tests/test_archetype.sh's bad-report-merge fixture.
# ============================================================================
work_arch="$WORK/tampered-archetypes"
mkdir -p "$work_arch/migrate"
cat > "$work_arch/migrate/plugin.conf" <<'EOF'
manifest_version=1
id=orchid/migrate
version=0.1.0
kind=archetype
api_version=1
requires_orchid=>=1.0
outcome=report
transitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done
EOF
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" archetype_validate migrate >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "tampered migrate archetype (report outcome + merging transition) is rejected (exit 13)"

# same tamper, for good measure, against a raw `orchid task create` call --
# an invalid/tampered archetype must never write a task file (fail closed).
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" "$ORCHID_BIN" task create TAMP001 "should be refused" --archetype migrate 2>/dev/null || rc=$?
assert_eq 13 "$rc" "task create --archetype migrate against the tampered manifest exits 13"
[ ! -f ".orchid/tasks/TAMP001.md" ] || fail "task create must not write a task file when the (tampered) archetype fails validation"
