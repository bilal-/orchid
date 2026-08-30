#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/archetype.sh"
export ORCHID_ROOT="$REPO_ROOT"

# ============================================================================
# Unit level: archetype_dir / archetype_transitions / archetype_outcome /
# archetype_validate, sourced directly (mirrors tests/test_manifest.sh).
# ============================================================================

# -- archetype_dir resolves the built-in feature/review archetypes ----------
dir="$(archetype_dir feature)"; rc=$?
assert_eq 0 "$rc" "archetype_dir resolves the built-in feature archetype"
assert_eq "$REPO_ROOT/plugins/archetypes/feature" "$dir" "archetype_dir returns the built-in feature dir"

dir2="$(archetype_dir review)"; rc=$?
assert_eq 0 "$rc" "archetype_dir resolves the built-in review archetype"
assert_eq "$REPO_ROOT/plugins/archetypes/review" "$dir2" "archetype_dir returns the built-in review dir"

rc=0; archetype_dir no-such-archetype >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "archetype_dir must fail for an archetype that doesn't exist anywhere on the search path"

# -- feature reproduces today's exact transition table, as DATA --------------
# This is the literal hardcoded `legal()` case table from before this task,
# now required to live verbatim in plugins/archetypes/feature/plugin.conf.
#
# T026 grew it by exactly two rows -- `rework:testing` and `blocked:testing`,
# the two source states `orchid task reverify` runs from. They are DATA here,
# not a name branch in the verb (INV-05): an archetype with no `testing`
# state (the report-outcome `review` archetype below) simply never declares
# them, and `reverify` against such a task is refused as an illegal
# transition rather than being special-cased by archetype name.
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
actual_feature="$(archetype_transitions feature)"
assert_eq "$expected_feature" "$actual_feature" "feature archetype declares today's exact transition table, verbatim"

expected_review="$(cat <<'EOF'
pending:reviewing
reviewing:arbitrating
arbitrating:done
arbitrating:rework
rework:reviewing
EOF
)"
actual_review="$(archetype_transitions review)"
assert_eq "$expected_review" "$actual_review" "review archetype declares its documented transition table"

assert_eq code "$(archetype_outcome feature)" "feature archetype outcome=code"
assert_eq report "$(archetype_outcome review)" "review archetype outcome=report"
assert_eq code "$(archetype_outcome no-such-archetype)" "archetype_outcome defaults to code for an unresolvable archetype"

# -- both built-ins pass the meta-contract validator -------------------------
out="$(archetype_validate feature)"; rc=$?
assert_eq 0 "$rc" "feature archetype passes archetype_validate (rc=$rc): $out"
assert_match "^ok" "$out" "archetype_validate prints an ok line for feature"

out="$(archetype_validate review)"; rc=$?
assert_eq 0 "$rc" "review archetype passes archetype_validate (rc=$rc): $out"
assert_match "^ok" "$out" "archetype_validate prints an ok line for review"

# -- unknown archetype -> archetype_validate rejects with exit 13 -----------
rc=0; archetype_validate no-such-archetype >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "archetype_validate on an unknown archetype rejects with exit 13"

# ============================================================================
# ORCHID_ARCHETYPES_DIR: the resolver-only test hook (mirrors
# ORCHID_ENGINES_DIR), highest precedence, never walked by real discovery.
# ============================================================================
work_arch="$WORK/test-archetypes"
mkdir -p "$work_arch/planted"
cat > "$work_arch/planted/plugin.conf" <<'EOF'
manifest_version=1
id=acme/planted
version=0.1.0
kind=archetype
api_version=1
outcome=code
transitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done
EOF
dir3="$(ORCHID_ARCHETYPES_DIR="$work_arch" archetype_dir planted)"; rc=$?
assert_eq 0 "$rc" "ORCHID_ARCHETYPES_DIR test hook resolves a planted archetype"
assert_eq "$work_arch/planted" "$dir3" "ORCHID_ARCHETYPES_DIR is the highest-precedence root"

mk_arch() {  # dir-under-test_arch conf-body
  mkdir -p "$work_arch/$1"
  printf '%s' "$2" > "$work_arch/$1/plugin.conf"
}

# -- archetype_validate rejects: outcome=report with a merging:* transition -
mk_arch bad-report-merge 'manifest_version=1
id=acme/bad-report-merge
version=0.1.0
kind=archetype
api_version=1
outcome=report
transitions=pending:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done
'
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" archetype_validate bad-report-merge >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "outcome=report with a merging:* transition is rejected (exit 13)"

# -- archetype_validate rejects: outcome=code missing testing:reviewing -----
mk_arch bad-code-missing 'manifest_version=1
id=acme/bad-code-missing
version=0.1.0
kind=archetype
api_version=1
outcome=code
transitions=pending:implementing,implementing:testing,reviewing:arbitrating,arbitrating:merging,merging:done
'
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" archetype_validate bad-code-missing >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "outcome=code missing testing:reviewing is rejected (exit 13)"

# -- archetype_validate rejects: a transition naming an unknown state -------
mk_arch bad-unknown-state 'manifest_version=1
id=acme/bad-unknown-state
version=0.1.0
kind=archetype
api_version=1
outcome=code
transitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done,merging:launched
'
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" archetype_validate bad-unknown-state >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "a transition naming an unknown state ('launched') is rejected (exit 13)"

# -- archetype_validate rejects: no transition reaches done (unreachable) ---
mk_arch bad-no-done 'manifest_version=1
id=acme/bad-no-done
version=0.1.0
kind=archetype
api_version=1
outcome=report
transitions=pending:reviewing,reviewing:arbitrating,arbitrating:rework,rework:reviewing
'
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" archetype_validate bad-no-done >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "no transition reaching 'done' (unreachable terminal) is rejected (exit 13)"

# -- archetype_validate rejects: outcome value that is neither code|report --
mk_arch bad-outcome 'manifest_version=1
id=acme/bad-outcome
version=0.1.0
kind=archetype
api_version=1
outcome=mystery
transitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done
'
rc=0; ORCHID_ARCHETYPES_DIR="$work_arch" archetype_validate bad-outcome >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "an outcome value that is neither code nor report is rejected (exit 13)"

# -- archetype_dir: duplicate id across two DIFFERENT roots -> INV-10 -------
dup_path="$WORK/dup-pathroot"
mkdir -p "$dup_path/archetypes/dupname"
printf 'manifest_version=1\nid=acme/dup\nversion=0.1.0\nkind=archetype\napi_version=1\noutcome=code\ntransitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done\n' \
  > "$dup_path/archetypes/dupname/plugin.conf"
dup_home="$WORK/dup-home"; mkdir -p "$dup_home/.orchid/plugins/archetypes/dupname"
printf 'manifest_version=1\nid=acme/dup\nversion=0.2.0\nkind=archetype\napi_version=1\noutcome=code\ntransitions=pending:implementing,implementing:testing,testing:reviewing,reviewing:arbitrating,arbitrating:merging,merging:done\n' \
  > "$dup_home/.orchid/plugins/archetypes/dupname/plugin.conf"
rc=0
dup_err="$( (HOME="$dup_home" ORCHID_PLUGIN_PATH="$dup_path" archetype_dir dupname) 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "archetype_dir must error on a duplicate archetype id across two different roots (INV-10)"
assert_match "INV-10" "$dup_err" "duplicate archetype id error names INV-10"
assert_match "dupname" "$dup_err" "duplicate archetype id error names the archetype"

# ============================================================================
# Integration level: `orchid task create/advance/set` and `orchid merge`
# driving a real `review`-archetype task end to end.
# ============================================================================
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# -- task create --archetype review writes archetype: review ---------------
"$ORCHID_BIN" task create R001 "review demo" --archetype review
assert_eq review "$("$ORCHID_BIN" task show R001 | grep '^archetype: ' | cut -d' ' -f2)" "task create --archetype review writes archetype: review"

# Review-archetype walk (brief): base_sha/candidate_sha are set by plain
# `task set` -- the range under audit -- since a review task never traverses
# `testing` (INV-04's .orchid/ scan and INV-11's verify-evidence gate live on
# edges review-archetype tasks never reach, so they stay naturally inert).
# The reviewing->arbitrating envelope-count gate IS archetype-agnostic
# (same kernel code as feature), and it is sha-bound, so candidate_sha must
# be set before a reviewer envelope can satisfy it.
review_sha="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set R001 base_sha "$review_sha"
"$ORCHID_BIN" task set R001 candidate_sha "$review_sha"

# -- a bare task create (no --archetype) still defaults to feature ---------
"$ORCHID_BIN" task create F001 "default archetype demo"
assert_eq feature "$("$ORCHID_BIN" task show F001 | grep '^archetype: ' | cut -d' ' -f2)" "task create without --archetype still defaults to archetype: feature"

# -- an unknown archetype on create -> exit 13, no task file written --------
rc=0; "$ORCHID_BIN" task create BAD001 "bad archetype" --archetype no-such-archetype 2>/dev/null || rc=$?
assert_eq 13 "$rc" "task create --archetype <unknown> exits 13"
[ ! -f ".orchid/tasks/BAD001.md" ] || fail "task create must not write a task file when the archetype fails validation"

# -- review task: pending -> reviewing is legal ------------------------------
"$ORCHID_BIN" task advance R001 reviewing
assert_eq reviewing "$("$ORCHID_BIN" task show R001 | grep '^status: ' | cut -d' ' -f2)" "review archetype: pending -> reviewing is legal"

# -- review task: pending -> implementing is illegal (exit 3) ---------------
# (feature's very first edge -- proves review's declared table, not
# feature's, governs a review-archetype task's legality)
"$ORCHID_BIN" task create R002 "review demo 2" --archetype review
rc=0; "$ORCHID_BIN" task advance R002 implementing 2>/dev/null || rc=$?
assert_eq 3 "$rc" "review archetype: pending -> implementing is illegal (exit 3)"
assert_eq pending "$("$ORCHID_BIN" task show R002 | grep '^status: ' | cut -d' ' -f2)" "R002 stays in pending after the refused illegal edge"

# -- review task: reviewing -> arbitrating (same reviewer-count gate as
# feature -- the gate itself is archetype-agnostic, only the edge table
# differs) --------------------------------------------------------------
plant_reviewer_envelope R001
"$ORCHID_BIN" task advance R001 arbitrating --reason "single reviewer approved"
assert_eq arbitrating "$("$ORCHID_BIN" task show R001 | grep '^status: ' | cut -d' ' -f2)" "review archetype: reviewing -> arbitrating"

# -- review task: arbitrating -> done requires --reason and journals kind
# arbitration (the report-accept edge is an arbitration outcome) -----------
#
# Asked of `orchid task arbitrate`, which since T032 is the only public verb
# that reaches this edge: `task advance R001 done` is refused now for being an
# arbitration result taken by a verb that records none, which would leave the
# reason-less probe below passing for a reason that has nothing to do with
# INV-08. The verb carries the same requirement.
rc=0; "$ORCHID_BIN" task arbitrate R001 --result approve 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "review archetype: arbitrating -> done without --reason must fail (INV-08)"
assert_eq arbitrating "$("$ORCHID_BIN" task show R001 | grep '^status: ' | cut -d' ' -f2)" "R001 stays in arbitrating after the refused reason-less done"

"$ORCHID_BIN" task arbitrate R001 --result approve --reason "accepted: findings addressed upstream"
assert_eq "done" "$("$ORCHID_BIN" task show R001 | grep '^status: ' | cut -d' ' -f2)" "review archetype: arbitrating -> done with --reason succeeds"
assert_match "arbitration" "$(cat .orchid/journal.md)" "arbitrating -> done journals kind=arbitration"
assert_match "accepted: findings addressed upstream" "$(cat .orchid/journal.md)" "arbitrating -> done journals the supplied reason"

# -- orchid merge on a review-archetype task is refused, exit 3, BEFORE the
# ordinary "not in merging" status check ------------------------------------
rc=0; out="$("$ORCHID_BIN" merge R002 2>&1)" || rc=$?
assert_eq 3 "$rc" "orchid merge on a review-archetype task exits 3"
assert_match "merge refused: archetype 'review' outcome=report never advances the integration branch \(exit 3\)" "$out" "merge refusal names the archetype and the exact reason, verbatim per the brief"

# ============================================================================
# Review-archetype REWORK CYCLE (T4 review fix): drives R003 through its
# full cycle, INCLUDING one arbitrating:rework -> rework:reviewing round, and
# proves the sha-bound reviewer-envelope-count gate (reviewing->arbitrating)
# is genuinely per-attempt for a review task too -- not just for feature's --
# the SAME attempt-1 envelope must NOT satisfy the gate once the rework round
# has bumped attempts to 1 (gate wants attempts+1 = 2).
# ============================================================================
r003_status() { "$ORCHID_BIN" task show R003 | grep '^status: ' | cut -d' ' -f2; }
r003_attempts() { "$ORCHID_BIN" task show R003 | grep '^attempts: ' | cut -d' ' -f2; }

"$ORCHID_BIN" task create R003 "review rework cycle" --archetype review
review_sha3="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set R003 base_sha "$review_sha3"
"$ORCHID_BIN" task set R003 candidate_sha "$review_sha3"

# pending -> reviewing
"$ORCHID_BIN" task advance R003 reviewing
assert_eq reviewing "$(r003_status)" "R003 rework cycle: pending -> reviewing"

# reviewer envelope for attempt 1 (attempts is still 0, so gate_attempt =
# attempts+1 = 1), bound to the current candidate_sha.
plant_reviewer_envelope R003 1

# reviewing -> arbitrating (first round; attempt-1 envelope satisfies the
# gate)
"$ORCHID_BIN" task advance R003 arbitrating --reason "first review round"
assert_eq arbitrating "$(r003_status)" "R003 rework cycle: reviewing -> arbitrating (round 1)"

# arbitrating -> rework (needs --reason; bumps attempts 0 -> 1; journals
# kind=arbitration since from=arbitrating).
#
# Taken through `orchid task arbitrate`, which since T032 is the only public
# verb that reaches an arbitration OUTCOME edge out of `arbitrating`: it derives the
# destination from THIS archetype's declared transitions and still takes it
# through `task advance`, so the edge, the attempt charge and the journal kind
# asserted here are all the same ones.
"$ORCHID_BIN" task arbitrate R003 --result request-changes --reason "arbiter sent back for rework"
assert_eq rework "$(r003_status)" "R003 rework cycle: arbitrating -> rework"
assert_eq 1 "$(r003_attempts)" "R003 rework cycle: arbitrating -> rework bumped attempts to 1"

# rework -> reviewing
"$ORCHID_BIN" task advance R003 reviewing
assert_eq reviewing "$(r003_status)" "R003 rework cycle: rework -> reviewing"

# reviewing -> arbitrating must now be REFUSED: the gate wants attempts+1 = 2
# reconciled envelopes for the CURRENT attempt, and only the attempt-1
# envelope (from before the rework round) exists on disk -- it must NOT be
# miscounted as satisfying attempt 2's gate. (This is the sha-bound,
# per-attempt gate lib/review.sh/orchid-task document for feature tasks;
# this proves it holds for a review-archetype task identically, since the
# gate itself is archetype-agnostic.)
rc=0; "$ORCHID_BIN" task advance R003 arbitrating --reason "premature, only attempt-1 envelope exists" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "R003 rework cycle: reviewing -> arbitrating must be refused with only the stale attempt-1 envelope on disk"
assert_eq reviewing "$(r003_status)" "R003 rework cycle: status stays in reviewing after the refused premature arbitrating"

# Plant the attempt-2 envelope (bound to the same, unchanged candidate_sha --
# a review task never re-candidates mid-cycle the way a feature task's
# rebase/rework would) -- the gate now has what it needs.
plant_reviewer_envelope R003 2
"$ORCHID_BIN" task advance R003 arbitrating --reason "second review round, approved"
assert_eq arbitrating "$(r003_status)" "R003 rework cycle: reviewing -> arbitrating (round 2, attempt-2 envelope present)"

# arbitrating -> done (needs --reason; journals kind=arbitration). `--result
# approve` on an outcome=report archetype derives `done`, since the archetype
# declares no `arbitrating:merging`.
"$ORCHID_BIN" task arbitrate R003 --result approve --reason "accepted after rework"
assert_eq "done" "$(r003_status)" "R003 rework cycle: arbitrating -> done"

# Both arbitration OUTCOMES (the rework decision and the final done
# acceptance) journaled with kind=arbitration, each with its own reason.
r003_journal="$(cat .orchid/journal.md)"
r003_arb_count="$(grep -c 'R003 arbitration' .orchid/journal.md)"
# THREE, not two: the two edge entries, plus the clear of the objection the
# first outcome raised. `task arbitrate --result request-changes` records the
# rejection as durable state on the task (T032, dogfood F33) and `--result
# approve` clears it, journaling that clear under the same `arbitration` kind.
# Counted rather than left to `assert_match` alone because a rejection that
# stopped writing the objection, or an approval that stopped clearing it, would
# leave every pattern below matching and the property gone.
assert_eq 3 "$r003_arb_count" "R003 rework cycle: both arbitration outcomes (rework and done) journaled with kind=arbitration, plus the clear of the objection the first one raised"
assert_match 'arbitrating -> rework: arbitrate\(request-changes\): arbiter sent back for rework' "$r003_journal" "R003 rework cycle: arbitrating -> rework reason journaled"
assert_match 'arbitrating -> done: arbitrate\(approve\): accepted after rework' "$r003_journal" "R003 rework cycle: arbitrating -> done reason journaled"
assert_match 'objection cleared by an explicit arbitration approval.*arbiter sent back for rework' "$r003_journal" \
  "R003 rework cycle: the objection the rework outcome raised is cleared by the accepting one, naming what it cleared"
