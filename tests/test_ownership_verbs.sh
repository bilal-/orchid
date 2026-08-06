#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
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

ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

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
# blocked is not a permanent trap: kernel.md requires "no hand-editing,
# ever", so a blocked run must be recoverable through a legal verb, not by
# hand-editing roadmap.md. blocked->running is that recoverable edge.
# ---------------------------------------------------------------------------
# Illegal edges out of blocked (other than the new recoverable one) still
# exit 3 and leave run_status untouched.
rc=0
"$ORCHID_BIN" run advance complete --reason "illegal from blocked" >/dev/null 2>&1 || rc=$?
assert_eq 3 "$rc" "blocked->complete is illegal (exit 3)"
fm_get .orchid/roadmap.md run_status | grep -q '^blocked$' || fail "illegal transition leaves run_status at blocked"

# blocked->running is legal: an operator can resume a blocked run.
"$ORCHID_BIN" run advance running --reason "operator resumed the run" >/dev/null \
  || fail "blocked->running must be legal (recoverable block)"
fm_get .orchid/roadmap.md run_status | grep -q '^running$' || fail "run_status recovered from blocked to running"
grep -q "run_status blocked -> running" .orchid/journal.md || fail "blocked->running transition journaled"

# ---------------------------------------------------------------------------
# run accept: shorthand for accepting->complete; requires accepting status
# AND an evidence file, copied atomically to reviews/acceptance.log.
# ---------------------------------------------------------------------------
# Already back at `running` (via the legal blocked->running recovery above);
# advance to `accepting` to exercise accept legitimately.
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
# v1-m4 Task 1 (the r-001 journal-loss incident, closed): `run accept`
# commits ALL current durable .orchid/ state onto the integration branch --
# via the SAME temp-worktree + CAS + sync-back transaction `plan apply`
# uses (lib/common.sh's orchid_commit_durable) -- so a completed run's
# record is never left uncommitted-only. This fixture's own checkout ($WORK)
# is never switched onto $integ itself (same "operator stays on their own
# branch" shape plan apply's own test above already exercises).
# ---------------------------------------------------------------------------
post_accept_integ="$(git rev-parse "$integ")"
[ "$post_accept_integ" != "$pre_integ" ] || fail "run accept must advance the integration branch"
assert_eq "orchid: run accepted (r-001)" "$(git log -1 --format=%s "$integ")" \
  "run accept commit message names the run id"
git show "$integ:.orchid/roadmap.md" | grep -q "run_status: complete" \
  || fail "run accept's commit on the integration branch shows run_status complete"
git show "$integ:.orchid/journal.md" | grep -q "all requirements covered" \
  || fail "run accept's commit carries the acceptance journal entry"
assert_eq "$(cat "$WORK/evidence.log")" "$(git show "$integ:.orchid/reviews/acceptance.log")" \
  "run accept's commit carries the evidence log"
# The user's own checkout is untouched by the commit, same guarantee plan
# apply's own test asserts.
assert_eq "$user_branch_before" "$(git rev-parse --abbrev-ref HEAD)" "run accept must not switch the user's branch"
assert_eq "$user_head_before" "$(git rev-parse HEAD)" "run accept must not move the user's HEAD"

# ---------------------------------------------------------------------------
# v1-m4 Task 1 fix wave (review Important): `run accept`'s CAS-failure
# recovery must be REAL -- retrying the exact same `orchid run accept`
# call must actually land the missing commit, not just die again (the
# ORIGINAL comment here claimed "simply retry" was enough; it was false,
# since run_status is already `complete` locally and the old code's
# `from = accepting` guard refused any retry outright).
#
# A genuine live CAS race (the integration ref moving between
# orchid_commit_durable's own read and its own update-ref) is a handful of
# syscalls wide with no test-only hook to pause it mid-flight -- same
# judgment call plan apply's own test above makes. Reproduced deterministically
# instead, via a technique that leaves the EXACT on-disk shape a lost CAS
# race leaves (local run_status already `complete`, evidence/journal
# already written, but no commit landed): force the FIRST attempt's
# orchid_commit_durable call to fail by pointing it at an integration
# branch that does not exist (ORCHID_INTEGRATION_BRANCH, config_get's env
# override) -- accept's own local mutations run to completion first
# regardless of what orchid_commit_durable does with them afterward, so
# the resulting state is identical to a real lost CAS race even though the
# SPECIFIC failure reason differs. Uses a FRESH single-cycle fixture (real
# `orchid init` + worktree) so there is no PRIOR "complete" commit on this
# integration branch to confuse the "is the commit already there" check.
# ---------------------------------------------------------------------------
cas_bare="$WORK/accept-retry-bare"; mkdir -p "$cas_bare"
(cd "$cas_bare" && git init -q . && git commit -q --allow-empty -m root)
ORCHID_REPO="$cas_bare" "$ORCHID_BIN" init >/dev/null
cas_wt="$WORK/accept-retry-wt"
git -C "$cas_bare" worktree add -q "$cas_wt" orchid/integration
cas_epoch="$(ORCHID_REPO="$cas_wt" HOME="$WORK/home" "$ORCHID_BIN" run start | sed 's/epoch: //')"
ORCHID_REPO="$cas_wt" ORCHID_EPOCH="$cas_epoch" HOME="$WORK/home" "$ORCHID_BIN" run advance running --reason "start" >/dev/null
ORCHID_REPO="$cas_wt" ORCHID_EPOCH="$cas_epoch" HOME="$WORK/home" "$ORCHID_BIN" run advance accepting --reason "ready" >/dev/null
echo "cas-retry evidence" > "$WORK/cas-evidence.log"
pre_cas_integ="$(git -C "$cas_bare" rev-parse orchid/integration)"

rc=0
ORCHID_REPO="$cas_wt" ORCHID_EPOCH="$cas_epoch" HOME="$WORK/home" \
  ORCHID_INTEGRATION_BRANCH="orchid/integration-does-not-exist" \
  "$ORCHID_BIN" run accept --reason "cas retry fixture" --evidence "$WORK/cas-evidence.log" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the simulated first attempt must fail (commit never lands)"
fm_get "$cas_wt/.orchid/roadmap.md" run_status | grep -q '^complete$' \
  || fail "the failed first attempt must still leave run_status: complete locally (state already set)"
assert_eq "$pre_cas_integ" "$(git -C "$cas_bare" rev-parse orchid/integration)" \
  "the failed first attempt must not have advanced the real integration branch"

# Retry: the SAME verb call, no override this time -- must detect the
# missing commit and land it, without re-running the state transition or
# evidence copy a second time.
retry_out="$(ORCHID_REPO="$cas_wt" ORCHID_EPOCH="$cas_epoch" HOME="$WORK/home" \
  "$ORCHID_BIN" run accept --reason "cas retry fixture" --evidence "$WORK/cas-evidence.log")"
assert_match "accepting -> complete" "$retry_out" "retried accept still prints the transition"
post_cas_integ="$(git -C "$cas_bare" rev-parse orchid/integration)"
[ "$post_cas_integ" != "$pre_cas_integ" ] || fail "retried accept must advance the integration branch"
assert_eq "orchid: run accepted (r-001)" "$(git -C "$cas_bare" log -1 --format=%s orchid/integration)" \
  "retried accept's commit carries the correct message"
git -C "$cas_bare" show "orchid/integration:.orchid/roadmap.md" | grep -q "run_status: complete" \
  || fail "retried accept's commit shows run_status complete"
grep -q "accept commit retried after CAS failure" "$cas_wt/.orchid/journal.md" \
  || fail "retried accept journals the retry as an intervention"

# Third invocation: genuinely done both locally AND committed -- must die
# cleanly rather than attempt yet another commit.
rc=0
already_out="$(ORCHID_REPO="$cas_wt" ORCHID_EPOCH="$cas_epoch" HOME="$WORK/home" \
  "$ORCHID_BIN" run accept --reason "cas retry fixture" --evidence "$WORK/cas-evidence.log" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a third accept call, already fully committed, must be refused"
assert_match "already accepted and committed" "$already_out" "third call names the already-done state"

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
