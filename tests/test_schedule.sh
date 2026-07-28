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
mk_task T006 done false "" ""
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
mk_task G000 done false "" ""
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
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

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
