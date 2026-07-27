#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"

integ=orchid/integration
git branch "$integ"
echo "integration_branch=$integ" > orchid.config

printf -- '---\nrun_status: planning\nrun_id: r-001\n---\n# Roadmap\n' > .orchid/roadmap.md
echo "# Requirements (author by hand, then: orchid requirements import <file>)" > .orchid/requirements.md
echo "# Journal" > .orchid/journal.md
echo "# Blockers" > .orchid/BLOCKERS.md
echo "# Baseline" > .orchid/baseline.md

export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

user_branch_before="$(git rev-parse --abbrev-ref HEAD)"
user_head_before="$(git rev-parse HEAD)"

# ---------------------------------------------------------------------------
# requirements import: happy path
# ---------------------------------------------------------------------------
echo "# Real requirements" > "$WORK/reqs-v1.md"
echo "- REQ-1: do the thing" >> "$WORK/reqs-v1.md"
out="$("$ORCHID_BIN" requirements import "$WORK/reqs-v1.md")"
assert_match "imported: reqs-v1.md -> requirements.md" "$out" "import happy path prints result"
assert_eq "$(cat "$WORK/reqs-v1.md")" "$(cat .orchid/requirements.md)" "requirements.md now matches imported file"
grep -q "plan_revision" .orchid/journal.md || fail "import journals plan_revision"
grep -q "reqs-v1.md" .orchid/journal.md || fail "import journal entry names the source file"

# ---------------------------------------------------------------------------
# plan apply: commits ALL current .orchid/ durable changes on the
# INTEGRATION branch, from a temp worktree, WITHOUT touching the user's
# checkout; journals the reason (journal-first); transitions run_status
# planning->running in the same commit.
# ---------------------------------------------------------------------------
pre_integ="$(git rev-parse "$integ")"
pre_status_porcelain="$(git status --porcelain)"
pre_wt_count="$(git worktree list | wc -l | tr -d ' ')"

out_apply="$("$ORCHID_BIN" plan apply --reason "initial plan")"
assert_match "^applied: $integ -> " "$out_apply" "plan apply prints result"

# User's checkout is untouched: same branch, same HEAD, same working-tree
# status, no leaked temp worktree.
assert_eq "$user_branch_before" "$(git rev-parse --abbrev-ref HEAD)" "plan apply must not switch the user's branch"
assert_eq "$user_head_before" "$(git rev-parse HEAD)" "plan apply must not move the user's HEAD"
assert_eq "$pre_status_porcelain" "$(git status --porcelain)" "plan apply must not change the user's working-tree status"
post_wt_count="$(git worktree list | wc -l | tr -d ' ')"
assert_eq "$pre_wt_count" "$post_wt_count" "plan apply leaves no dangling temp worktree"

# Integration branch advanced by exactly one commit, with the durable
# .orchid/ content (including the just-imported requirements.md and the
# journal entry) riding along in it.
post_integ="$(git rev-parse "$integ")"
[ "$post_integ" != "$pre_integ" ] || fail "plan apply must advance the integration branch"
assert_eq "orchid: plan apply" "$(git log -1 --format=%s "$integ")" "plan apply commit message"
git show "$integ:.orchid/roadmap.md" | grep -q "run_status: running" \
  || fail "plan apply transitions run_status planning->running in the same commit"
git show "$integ:.orchid/requirements.md" | grep -q "REQ-1" \
  || fail "plan apply commits the currently-imported requirements.md"
git show "$integ:.orchid/journal.md" | grep -q "initial plan" \
  || fail "plan apply's journal entry (with reason) rides in the commit"

# Fix 3 (CAS discipline): both mutations are built into the temp
# worktree's commit FIRST; the local working copy only receives them via
# sync-back AFTER the CAS (update-ref) above has already succeeded. Assert
# that structurally: local journal.md/roadmap.md are byte-identical to
# what's committed on $integ, i.e. copied from the commit rather than
# composed locally and independently written (which is what the pre-fix
# code did, and which is exactly what let a CAS failure leave local
# claiming a transition the integration branch never received).
grep -q "initial plan" .orchid/journal.md || fail "plan apply journals the reason in the working copy"
fm_get .orchid/roadmap.md run_status | grep -q '^running$' \
  || fail "plan apply transitions the WORKING copy's run_status too"
assert_eq "$(git show "$integ:.orchid/journal.md")" "$(cat .orchid/journal.md)" \
  "plan apply's local journal.md is byte-identical to the committed one (synced back post-CAS)"
assert_eq "$(git show "$integ:.orchid/roadmap.md")" "$(cat .orchid/roadmap.md)" \
  "plan apply's local roadmap.md is byte-identical to the committed one (synced back post-CAS)"
# Fix 3(c), CAS-failure path: deliberately not exercised here via a live
# race (would need a test-only hook inside orchid-plan to pause it between
# reading integ_head and update-ref — judged too intrusive for this fix;
# see the commit message / report for that choice). Covered by inspection:
# the CAS-failure branch in orchid-plan only ever runs `journal add --kind
# intervention` against $repo (never touches $wt_roadmap or $state's
# roadmap.md), so it cannot mutate local run_status by construction.

# ---------------------------------------------------------------------------
# requirements import: refused once run_status has left `planning`
# (immutable after plan).
# ---------------------------------------------------------------------------
echo "# Should be refused" > "$WORK/reqs-v2.md"
rc=0
"$ORCHID_BIN" requirements import "$WORK/reqs-v2.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "import must refuse once run_status is not planning"
assert_match "REQ-1" "$(cat .orchid/requirements.md)" "requirements.md untouched by refused import"

# ---------------------------------------------------------------------------
# run advance: legality table.
# ---------------------------------------------------------------------------
# running->complete is refused: must go through accepting first.
rc=0
"$ORCHID_BIN" run advance complete --reason "skip ahead" >/dev/null 2>&1 || rc=$?
assert_eq 3 "$rc" "running->complete is illegal (exit 3)"
fm_get .orchid/roadmap.md run_status | grep -q '^running$' || fail "illegal transition leaves run_status unchanged"

# running->accepting is legal.
"$ORCHID_BIN" run advance accepting --reason "moving to acceptance" >/dev/null \
  || fail "running->accepting must be legal"
fm_get .orchid/roadmap.md run_status | grep -q '^accepting$' || fail "run_status now accepting"
grep -q "run_status running -> accepting" .orchid/journal.md || fail "run advance journals the transition"

# accepting->planning is illegal (not in the table, and not ->blocked).
rc=0
"$ORCHID_BIN" run advance planning --reason "go back" >/dev/null 2>&1 || rc=$?
assert_eq 3 "$rc" "accepting->planning is illegal (exit 3)"

# accepting->running is the legal rollback edge.
"$ORCHID_BIN" run advance running --reason "not ready yet" >/dev/null \
  || fail "accepting->running (rollback) must be legal"
fm_get .orchid/roadmap.md run_status | grep -q '^running$' || fail "run_status rolled back to running"

# --reason is required (INV-08).
rc=0
"$ORCHID_BIN" run advance accepting >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run advance without --reason must be refused"

# any->blocked is legal from any state, including `running`.
"$ORCHID_BIN" run advance blocked --reason "operator halted the run" >/dev/null \
  || fail "running->blocked must be legal (any->blocked)"
fm_get .orchid/roadmap.md run_status | grep -q '^blocked$' || fail "run_status now blocked"
grep -q "run_status running -> blocked" .orchid/journal.md || fail "blocked transition journaled"

# ---------------------------------------------------------------------------
# run accept: shorthand for accepting->complete; requires accepting status
# AND an evidence file, copied atomically to reviews/acceptance.log.
# ---------------------------------------------------------------------------
# Get back to `running`, then `accepting`, to exercise accept legitimately.
fm_set .orchid/roadmap.md run_status running
"$ORCHID_BIN" run advance accepting --reason "re-entering acceptance" >/dev/null

# accept refuses without --evidence.
rc=0
"$ORCHID_BIN" run accept --reason "no evidence supplied" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run accept without --evidence must be refused"
fm_get .orchid/roadmap.md run_status | grep -q '^accepting$' || fail "run_status unchanged by refused accept"

# accept refuses when run_status is not `accepting`.
"$ORCHID_BIN" run advance running --reason "leave accepting for the guard check" >/dev/null
echo "acceptance evidence: all checks passed" > "$WORK/evidence.log"
rc=0
"$ORCHID_BIN" run accept --reason "wrong state" --evidence "$WORK/evidence.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run accept must refuse when run_status is not accepting"

# Happy path: accepting -> complete.
"$ORCHID_BIN" run advance accepting --reason "ready for acceptance" >/dev/null

# ---------------------------------------------------------------------------
# Fix 1 regression: the evidence-gate bypass. `accepting:complete` used to
# be a legal `run advance` edge, so `run advance complete --reason x` could
# reach `complete` without ever supplying --evidence or writing
# reviews/acceptance.log. `run advance` must refuse ->complete
# unconditionally now, from ANY state — `orchid run accept --evidence` is
# the only path to complete.
# ---------------------------------------------------------------------------
rc=0
out_bypass="$("$ORCHID_BIN" run advance complete --reason "skip via advance" 2>&1)" || rc=$?
assert_eq 3 "$rc" "advance ->complete is refused even from accepting (exit 3)"
assert_match "use: orchid run accept --evidence" "$out_bypass" "advance ->complete points the operator at run accept"
fm_get .orchid/roadmap.md run_status | grep -q '^accepting$' \
  || fail "refused advance->complete must leave run_status at accepting"

# The legitimate path — run accept — still works from this same state.
out_accept="$("$ORCHID_BIN" run accept --reason "all requirements covered" --evidence "$WORK/evidence.log")"
assert_match "accepting -> complete" "$out_accept" "run accept prints the transition"
fm_get .orchid/roadmap.md run_status | grep -q '^complete$' || fail "run_status now complete"
assert_eq "$(cat "$WORK/evidence.log")" "$(cat .orchid/reviews/acceptance.log)" \
  "evidence copied atomically to reviews/acceptance.log"
grep -q "acceptance" .orchid/journal.md || fail "run accept journals kind acceptance"
grep -q "all requirements covered" .orchid/journal.md || fail "run accept journal entry carries the reason"

# ---------------------------------------------------------------------------
# Epoch fencing: a stale ORCHID_EPOCH must refuse all three ownership verbs,
# without mutating any state.
# ---------------------------------------------------------------------------
stale=$(( ORCHID_EPOCH - 1 ))
pre_reqs="$(cat .orchid/requirements.md)"
pre_integ_stale="$(git rev-parse "$integ")"
pre_status="$(fm_get .orchid/roadmap.md run_status)"

rc=0
ORCHID_EPOCH="$stale" "$ORCHID_BIN" requirements import "$WORK/reqs-v2.md" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "requirements import must die on a stale epoch"
assert_eq "$pre_reqs" "$(cat .orchid/requirements.md)" "stale-epoch import must not mutate requirements.md"

rc=0
ORCHID_EPOCH="$stale" "$ORCHID_BIN" plan apply --reason "stale attempt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "plan apply must die on a stale epoch"
assert_eq "$pre_integ_stale" "$(git rev-parse "$integ")" "stale-epoch plan apply must not move the integration branch"

rc=0
ORCHID_EPOCH="$stale" "$ORCHID_BIN" run advance running --reason "stale attempt" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run advance must die on a stale epoch"
assert_eq "$pre_status" "$(fm_get .orchid/roadmap.md run_status)" "stale-epoch run advance must not mutate run_status"

rc=0
ORCHID_EPOCH="$stale" "$ORCHID_BIN" run accept --reason "stale" --evidence "$WORK/evidence.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run accept must die on a stale epoch"
