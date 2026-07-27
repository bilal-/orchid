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

# The reason is journaled locally too (journal-first, before the commit).
grep -q "initial plan" .orchid/journal.md || fail "plan apply journals the reason in the working copy"
fm_get .orchid/roadmap.md run_status | grep -q '^running$' \
  || fail "plan apply transitions the WORKING copy's run_status too"

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
