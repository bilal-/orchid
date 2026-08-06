#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"; source "$REPO_ROOT/lib/schedule.sh"
export ORCHID_ROOT="$REPO_ROOT"

# ============================================================================
# Unit level: schedule_active_tasks / schedule_dispatch_blockers, sourced
# directly against hand-written task frontmatter fixtures (mirrors
# tests/test_archetype.sh's direct-sourced unit section) -- no CLI, no
# `orchid task advance` involved yet, so this exercises lib/schedule.sh in
# total isolation from the kernel gate that will later call it.
# ============================================================================
repo="$WORK/unit"; mkdir -p "$repo/.orchid/tasks"

# mk_task <id> <status> <exclusive> <resources> <depends_on> -- writes a
# minimal frontmatter fixture directly (fm_get only reads between the first
# two `---` lines, "key: value" per line -- no need for the full template).
mk_task() {
  local id="$1" status="$2" exclusive="$3" resources="$4" depends_on="$5"
  cat > "$repo/.orchid/tasks/$id.md" <<EOF
---
id: $id
status: $status
exclusive: $exclusive
resources: $resources
depends_on: $depends_on
---
(fixture)
EOF
}

# -- schedule_active_tasks: exactly the active status set, nothing else -----
mk_task T000 pending false "" ""
mk_task T001 implementing false "" ""
mk_task T002 testing false "" ""
mk_task T003 reviewing false "" ""
mk_task T004 arbitrating false "" ""
mk_task T005 merging false "" ""
mk_task T006 "done" false "" ""
mk_task T007 blocked false "" ""
mk_task T008 rework false "" ""
active="$(schedule_active_tasks "$repo" | sort)"
assert_eq "$(printf 'T001\nT002\nT003\nT004\nT005')" "$active" "schedule_active_tasks: exactly implementing/testing/reviewing/arbitrating/merging"

rm -f "$repo/.orchid/tasks"/*.md

# -- concurrency-cap: cap=1 fixture -------------------------------------------
printf 'concurrency=1\n' > "$repo/orchid.config"
mk_task A000 implementing false "" ""
mk_task A001 pending false "" ""
blockers="$(schedule_dispatch_blockers "$repo" A001)"
assert_match "^concurrency-cap \(1/1\)$" "$blockers" "cap=1, 1 active: concurrency-cap (1/1)"

rm -f "$repo/orchid.config"
# -- default cap (2): 1 active is still under cap, no concurrency-cap line --
blockers="$(schedule_dispatch_blockers "$repo" A001)"
echo "$blockers" | grep -q "concurrency-cap" && fail "default cap=2 with 1 active must not block on concurrency-cap"
assert_eq "" "$blockers" "default cap=2, 1 non-conflicting active, no deps: fully dispatchable (empty blockers)"

# -- v1-m3 (m2 ledger finding): a non-numeric `concurrency` config value must
# die cleanly rather than feed straight into `[ "$n" -lt "$cap" ]` (bash
# would print "integer expression expected" and behave unpredictably).
printf 'concurrency=abc\n' > "$repo/orchid.config"
rc=0; err="$(schedule_dispatch_blockers "$repo" A001 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "non-numeric concurrency config must die, not silently proceed"
assert_match "concurrency must be a positive integer \(got 'abc'\)" "$err" "concurrency validation names the bad value"

# a configured "0" is not a positive integer either.
printf 'concurrency=0\n' > "$repo/orchid.config"
rc=0; err="$(schedule_dispatch_blockers "$repo" A001 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "concurrency=0 must die, not be treated as a valid (impossible) cap"
assert_match "concurrency must be a positive integer \(got '0'\)" "$err" "concurrency=0 validation names the bad value"

# a leading-zero form ("00") is all-digits -- it must NOT slip past the
# non-numeric check and get silently treated as the numeric 0 by `-lt`
# (which would permanently trip concurrency-cap without ever naming why).
printf 'concurrency=00\n' > "$repo/orchid.config"
rc=0; err="$(schedule_dispatch_blockers "$repo" A001 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "concurrency=00 must die (leading-zero form), not silently evaluate as 0"
assert_match "concurrency must be a positive integer \(got '00'\)" "$err" "concurrency=00 validation names the bad value"

rm -f "$repo/orchid.config"

rm -f "$repo/.orchid/tasks"/*.md

# -- exclusive-overlap, direction 1: an ACTIVE task is exclusive -------------
mk_task B000 implementing true "" ""
mk_task B001 pending false "" ""
blockers="$(schedule_dispatch_blockers "$repo" B001)"
assert_match "exclusive-overlap \(B000\)" "$blockers" "active task exclusive=true blocks a normal pending task"

rm -f "$repo/.orchid/tasks"/*.md

# -- exclusive-overlap, direction 2: THIS task is exclusive, something active
mk_task C000 implementing false "" ""
mk_task C001 pending true "" ""
blockers="$(schedule_dispatch_blockers "$repo" C001)"
assert_match "exclusive-overlap \(C000\)" "$blockers" "an exclusive pending task is blocked by any active task"

rm -f "$repo/.orchid/tasks"/*.md

# -- exclusive: neither side exclusive -> no exclusive-overlap --------------
mk_task D000 implementing false "" ""
mk_task D001 pending false "" ""
blockers="$(schedule_dispatch_blockers "$repo" D001)"
echo "$blockers" | grep -q "exclusive-overlap" && fail "no exclusive-overlap when neither task declares exclusive:true"

rm -f "$repo/.orchid/tasks"/*.md

# -- resource-conflict: intersecting resources lists -------------------------
mk_task E000 implementing false "db,cache" ""
mk_task E001 pending false "db,queue" ""
blockers="$(schedule_dispatch_blockers "$repo" E001)"
assert_match "resource-conflict \(db: E000\)" "$blockers" "shared 'db' resource blocks with the active task's id"
echo "$blockers" | grep -q "resource-conflict (cache" && fail "non-shared resource 'cache' must not appear as a conflict"
echo "$blockers" | grep -q "resource-conflict (queue" && fail "non-shared resource 'queue' must not appear as a conflict"

rm -f "$repo/.orchid/tasks"/*.md

# -- resources: disjoint lists -> no resource-conflict -----------------------
mk_task F000 implementing false "db" ""
mk_task F001 pending false "cache" ""
blockers="$(schedule_dispatch_blockers "$repo" F001)"
echo "$blockers" | grep -q "resource-conflict" && fail "disjoint resources lists must never conflict"

rm -f "$repo/.orchid/tasks"/*.md

# -- waiting-deps: unmet dependency ------------------------------------------
mk_task G000 pending false "" ""
mk_task G001 pending false "" "G000"
blockers="$(schedule_dispatch_blockers "$repo" G001)"
assert_match "^waiting-deps \(G000\)$" "$blockers" "unmet dep G000 (not done) blocks G001"

# once the dep is done, waiting-deps must disappear
mk_task G000 "done" false "" ""
blockers="$(schedule_dispatch_blockers "$repo" G001)"
echo "$blockers" | grep -q "waiting-deps" && fail "a done dependency must no longer appear in waiting-deps"
assert_eq "" "$blockers" "no deps outstanding, no cap/exclusive/resource issues: fully dispatchable"

# multiple unmet deps: space-separated inside one predicate
mk_task G000 pending false "" ""
mk_task G002 pending false "" ""
mk_task G003 pending false "" "G000 G002"
blockers="$(schedule_dispatch_blockers "$repo" G003)"
assert_match "^waiting-deps \(G000 G002\)$" "$blockers" "two unmet deps listed space-separated in one predicate"

rm -f "$repo/.orchid/tasks"/*.md

echo "unit: schedule_dispatch_blockers predicates OK"

# ============================================================================
# Integration level: the kernel-side dispatch gate on `orchid task advance
# <id> implementing` (pending-> and rework->), and `orchid status --explain`
# surfacing the same predicates. Drives real CLI verbs against a real repo,
# mirroring tests/test_task.sh's style.
# ============================================================================
repo2="$WORK/integ"; mkdir -p "$repo2/.orchid/tasks"
(cd "$repo2" && git init -q . && git commit -q --allow-empty -m root)
export ORCHID_REPO="$repo2" HOME="$WORK/home2"; mkdir -p "$HOME"
printf 'concurrency=1\n' > "$repo2/orchid.config"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create H001 "first" >/dev/null
"$ORCHID_BIN" task create H002 "second" >/dev/null

# H001 dispatches fine (0 active, cap 1) --------------------------------------
"$ORCHID_BIN" task advance H001 implementing >/dev/null \
  || fail "H001 (0 active, cap 1) must dispatch cleanly"
assert_eq implementing "$("$ORCHID_BIN" task show H001 | grep '^status: ' | cut -d' ' -f2)" "H001 reached implementing"

# H002 is refused: cap=1 already reached by H001, exit 3, predicate on stderr
rc=0; err="$("$ORCHID_BIN" task advance H002 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "H002 dispatch refused at cap exits 3"
assert_match "concurrency-cap \(1/1\)" "$err" "refusal names the concurrency-cap predicate"
assert_eq pending "$("$ORCHID_BIN" task show H002 | grep '^status: ' | cut -d' ' -f2)" "H002 stays pending after the refused dispatch"

# status --explain shows the same predicate for the pending row --------------
explain="$("$ORCHID_BIN" status --explain)"
assert_match "H002.*concurrency-cap \(1/1\)" "$explain" "status --explain shows concurrency-cap for H002"
assert_match "H001.*implementing" "$explain" "status --explain still shows H001's own status row"

# -- rework -> implementing goes through the same gate + status treatment ---
# H001 goes to testing then rework: at that point NOTHING is active (H001 is
# rework, not yet re-dispatched; H002 is still pending) -- 0 active < cap 1
# -- so the rework->implementing edge must succeed cleanly through the same
# gate, proving it does not count the dispatching task against its own cap.
edge_sha="deadbeefcafebabe0000000000000000000000"
"$ORCHID_BIN" task set H001 base_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set H001 candidate_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task advance H001 testing >/dev/null
"$ORCHID_BIN" task advance H001 rework --reason "back to rework" >/dev/null
assert_eq rework "$("$ORCHID_BIN" task show H001 | grep '^status: ' | cut -d' ' -f2)" "H001 is rework"

"$ORCHID_BIN" task advance H001 implementing >/dev/null \
  || fail "rework -> implementing with 0 active tasks must dispatch cleanly (no self-blocking)"

explain2="$("$ORCHID_BIN" status --explain)"
assert_match "H001.*implementing" "$explain2" "H001 back in implementing after rework dispatch"

# now H001 is active again (cap 1 reached): H002's rework/pending re-attempt
# is refused the same way, proving rework rows get the same predicate
# treatment in status --explain as pending rows.
rc=0; err3="$("$ORCHID_BIN" task advance H002 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "H002 dispatch still refused at cap after H001's rework re-dispatch"
assert_match "concurrency-cap \(1/1\)" "$err3" "second refusal also names concurrency-cap"

# ============================================================================
# Integration level (final-review Finding 1): a REPORT-archetype task's
# pending/rework -> reviewing edge is a real dispatch too -- `reviewing` is
# an active status (_SCHEDULE_ACTIVE_STATUSES above) -- and must be gated by
# the exact same predicates as pending/rework -> implementing. Before this
# fix, libexec/orchid-task's gate was keyed on a literal `to = implementing`
# check, so a review-archetype task dispatching straight into `reviewing`
# skipped concurrency-cap/exclusive/resource/waiting-deps entirely, even
# though `orchid status --explain` (above) already shows those same
# predicates for its pending/rework row. No archetype-name branching here
# (INV-05) -- the gate keys on "to is an active status", read via
# lib/schedule.sh, never on the archetype's name.
# ============================================================================
repo3="$WORK/integ3"; mkdir -p "$repo3/.orchid/tasks"
(cd "$repo3" && git init -q . && git commit -q --allow-empty -m root)
export ORCHID_REPO="$repo3" HOME="$WORK/home3"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
repo3_sha="$(git -C "$repo3" rev-parse HEAD)"

"$ORCHID_BIN" task create K001 "occupies the cap" >/dev/null
"$ORCHID_BIN" task advance K001 implementing >/dev/null   # feature, active

"$ORCHID_BIN" task create K002 "review task" --archetype review >/dev/null
"$ORCHID_BIN" task set K002 base_sha "$repo3_sha" >/dev/null
"$ORCHID_BIN" task set K002 candidate_sha "$repo3_sha" >/dev/null

# (a) concurrency-cap: cap=1, K001 already active -> K002's review-archetype
# pending -> reviewing dispatch is refused, exit 3, naming concurrency-cap.
printf 'concurrency=1\n' > "$repo3/orchid.config"
rc=0; errA="$("$ORCHID_BIN" task advance K002 reviewing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "review-archetype pending -> reviewing refused at cap exits 3"
assert_match "concurrency-cap \(1/1\)" "$errA" "refusal names concurrency-cap for a review-archetype dispatch into reviewing"
assert_eq pending "$("$ORCHID_BIN" task show K002 | grep '^status: ' | cut -d' ' -f2)" "K002 stays pending after the refused reviewing dispatch"

# back to default cap (2): K001 alone (1 active) no longer trips the cap.
rm -f "$repo3/orchid.config"

# (b) waiting-deps: K002 depends on K003, which never leaves pending (not
# done) -> refused, exit 3, naming waiting-deps, cap/exclusive/resources
# all clear.
"$ORCHID_BIN" task create K003 "dep source, left pending" >/dev/null
"$ORCHID_BIN" task set K002 depends_on K003 >/dev/null
rc=0; errB="$("$ORCHID_BIN" task advance K002 reviewing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "review-archetype pending -> reviewing refused on an unmet dep exits 3"
assert_match "waiting-deps \(K003\)" "$errB" "refusal names waiting-deps for a review-archetype dispatch into reviewing"
assert_eq pending "$("$ORCHID_BIN" task show K002 | grep '^status: ' | cut -d' ' -f2)" "K002 stays pending after the refused reviewing dispatch"

# drive a fresh review-archetype task, K004, all the way to `done` (review's
# shortest path: pending -> reviewing -> arbitrating -> done) so it can
# stand in as a MET dependency for K002 below.
"$ORCHID_BIN" task create K004 "dep source, will finish" --archetype review >/dev/null
"$ORCHID_BIN" task set K004 base_sha "$repo3_sha" >/dev/null
"$ORCHID_BIN" task set K004 candidate_sha "$repo3_sha" >/dev/null
"$ORCHID_BIN" task advance K004 reviewing >/dev/null \
  || fail "K004 (0 active besides K001, cap 2, no deps) must dispatch into reviewing cleanly"
mkdir -p "$repo3/.orchid/reviews"
jq -n --arg jid "j-fixture-K004-a1" --arg cand "$repo3_sha" \
  '{contract:1, job_id:$jid, task:"K004", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"fixture reviewer", candidate_sha:$cand}' \
  > "$repo3/.orchid/reviews/K004-a1-reviewer.json"
"$ORCHID_BIN" task advance K004 arbitrating --reason "single reviewer approved" >/dev/null
"$ORCHID_BIN" task advance K004 "done" --reason "accepted" >/dev/null
assert_eq "done" "$("$ORCHID_BIN" task show K004 | grep '^status: ' | cut -d' ' -f2)" "K004 reached done"

# (c) cap free + deps met -> K002's pending -> reviewing now proceeds.
"$ORCHID_BIN" task set K002 depends_on K004 >/dev/null
"$ORCHID_BIN" task advance K002 reviewing >/dev/null \
  || fail "K002 (cap free, dep K004 done) must dispatch into reviewing cleanly"
assert_eq reviewing "$("$ORCHID_BIN" task show K002 | grep '^status: ' | cut -d' ' -f2)" "K002 reached reviewing once its dep was done and the cap was free"

# drive K002 on to `rework` (reviewing -> arbitrating -> rework) so the next
# check can exercise rework -> reviewing, review-archetype's rework
# re-entry edge.
mkdir -p "$repo3/.orchid/reviews"
jq -n --arg jid "j-fixture-K002-a1" --arg cand "$repo3_sha" \
  '{contract:1, job_id:$jid, task:"K002", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"fixture reviewer", candidate_sha:$cand}' \
  > "$repo3/.orchid/reviews/K002-a1-reviewer.json"
"$ORCHID_BIN" task advance K002 arbitrating --reason "single reviewer approved" >/dev/null
"$ORCHID_BIN" task advance K002 rework --reason "needs another pass" >/dev/null
assert_eq rework "$("$ORCHID_BIN" task show K002 | grep '^status: ' | cut -d' ' -f2)" "K002 is rework"

# (e) rework -> reviewing is gated identically: cap=1 with K001 still active
# refuses K002's rework -> reviewing re-entry the same way it refused its
# very first pending -> reviewing dispatch.
printf 'concurrency=1\n' > "$repo3/orchid.config"
rc=0; errE="$("$ORCHID_BIN" task advance K002 reviewing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "review-archetype rework -> reviewing refused at cap exits 3"
assert_match "concurrency-cap \(1/1\)" "$errE" "refusal names concurrency-cap for a review-archetype rework -> reviewing re-entry"
assert_eq rework "$("$ORCHID_BIN" task show K002 | grep '^status: ' | cut -d' ' -f2)" "K002 stays rework after the refused reviewing re-entry"

# ============================================================================
# v1-m3 Task 8: `orchid task create --archetype migrate` writes a template
# default of `exclusive: true` (frontmatter substitution, not a `task set
# exclusive` call) -- proving the m2 scheduler's exclusive-overlap predicate
# gates a migrate task's dispatch identically to any other exclusive:true
# task, purely off that create-time default, with no extra `task set
# exclusive true` step required.
# ============================================================================
repo4="$WORK/integ4"; mkdir -p "$repo4/.orchid/tasks"
(cd "$repo4" && git init -q . && git commit -q --allow-empty -m root)
export ORCHID_REPO="$repo4" HOME="$WORK/home4"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
repo4_sha="$(git -C "$repo4" rev-parse HEAD)"

"$ORCHID_BIN" task create M001 "occupies the cap, ordinary feature task" >/dev/null
"$ORCHID_BIN" task advance M001 implementing >/dev/null   # feature, active

"$ORCHID_BIN" task create M002 "a migration" --archetype migrate >/dev/null
assert_eq true "$("$ORCHID_BIN" task show M002 | grep '^exclusive: ' | cut -d' ' -f2)" "task create --archetype migrate defaults exclusive: true from the template, no task set needed"

# M001 is active (any status) -> M002's exclusive:true refuses dispatch,
# naming exclusive-overlap, even though the concurrency cap (default 2) is
# nowhere near full.
rc=0; errM="$("$ORCHID_BIN" task advance M002 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "migrate task dispatch refused while another task is active exits 3"
assert_match "exclusive-overlap \(M001\)" "$errM" "refusal names exclusive-overlap against the active feature task"
assert_eq pending "$("$ORCHID_BIN" task show M002 | grep '^status: ' | cut -d' ' -f2)" "M002 stays pending after the refused exclusive dispatch"

# once M001 is no longer active, M002's migrate dispatch proceeds cleanly.
"$ORCHID_BIN" task set M001 base_sha "$repo4_sha" >/dev/null
"$ORCHID_BIN" task set M001 candidate_sha "$repo4_sha" >/dev/null
"$ORCHID_BIN" task advance M001 testing >/dev/null
"$ORCHID_BIN" task advance M001 rework --reason "back to rework, freeing the cap" >/dev/null
"$ORCHID_BIN" task advance M002 implementing >/dev/null \
  || fail "migrate task must dispatch cleanly once nothing else is active"
assert_eq implementing "$("$ORCHID_BIN" task show M002 | grep '^status: ' | cut -d' ' -f2)" "M002 reached implementing once the exclusive-overlap cleared"

# and, symmetrically, a fresh ordinary task is now refused because the
# ACTIVE migrate task (M002) is itself exclusive:true.
"$ORCHID_BIN" task create M003 "blocked by the active migration" >/dev/null
rc=0; errN="$("$ORCHID_BIN" task advance M003 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "an ordinary task's dispatch is refused while the migrate task is active"
assert_match "exclusive-overlap \(M002\)" "$errN" "refusal names exclusive-overlap against the active migrate task"
