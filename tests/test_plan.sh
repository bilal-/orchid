#!/usr/bin/env bash
# T021: the PLANNING-time carry-forward cross-check.
#
# WHAT IS BEING PROVEN, and why it is worth a suite of its own. r-002's
# requirements omitted a defect r-001 had already found, recorded and
# journaled -- the once-only `started_at` anchor -- and it blocked a task
# hours into the run. Eighteen active lessons and a full previous journal
# were sitting right there while the plan was scoped. That is lesson L016's
# shape ("a mechanism nothing forces you to use is not a fix") applied to
# knowledge, so the fix cannot be a report an operator may remember to read:
# `orchid plan apply` itself has to refuse.
#
# The three cases the brief names -- a covered item, an uncovered one, and an
# explicitly deferred one -- are each proven below on a REAL rollover
# fixture (`orchid run new`), not a hand-built .orchid tree, so what is
# tested is what an operator will actually meet. Two further cases are
# proven because silence is the failure mode this whole check exists to
# remove: a repository whose first run has never rolled over, and a previous
# run that genuinely left nothing. Both must SAY so.
#
# RED (before libexec/orchid-plan grew the check): every crosscheck
# invocation exits 2 on an unknown subverb, and every `plan apply` here
# commits regardless of what the previous run left behind.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

# new_repo <name> -- an initialized repo plus a worktree of its integration
# branch, cd'd into, with ORCHID_REPO/ORCHID_EPOCH bound to the worktree.
# Same fixture shape tests/test_run.sh's rollover section uses: `run new`
# and `plan apply` both commit through a temp worktree against a real
# integration branch, so a bare .orchid/ directory would not exercise them.
new_repo() {
  local bare="$WORK/$1-bare" wt="$WORK/$1-wt"
  # Never inherit the PREVIOUS fixture's epoch into a repository that has
  # none yet: `run start` mints one, and a stale ORCHID_EPOCH in the
  # environment is exactly what INV-02's fence exists to refuse.
  unset ORCHID_EPOCH
  mkdir -p "$bare"
  (cd "$bare" && git init -q . && git commit -q --allow-empty -m root)
  ORCHID_REPO="$bare" "$ORCHID_BIN" init >/dev/null
  git -C "$bare" worktree add -q "$wt" orchid/integration
  export ORCHID_REPO="$wt"
  cd_scratch "$wt"
  ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
  export ORCHID_EPOCH
}

# roll_over <reason> -- take the current run to a status `run new` accepts
# and roll it. The lease is removed first because a fresh one reads as "a
# live orchestrator session may still be running"; absence reads as no live
# session, exactly as runners/orchid-pump treats it.
roll_over() {
  rm -f .orchid/runtime/lease.json
  "$ORCHID_BIN" run advance blocked --reason "fixture shortcut to a rollover-legal status" >/dev/null
  "$ORCHID_BIN" run new --reason "$1" >/dev/null
}

# ===========================================================================
# 1 -- a repository whose first run has never rolled over. There is no
# previous run, so there is nothing to carry forward -- and that has to be
# STATED. An empty check and an unrun one are indistinguishable otherwise,
# which is the exact ambiguity this feature exists to remove.
# ===========================================================================
new_repo a
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "first task" >/dev/null

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck exits 0 when no run has ever rolled over"
assert_match "no previous run is archived" "$out" \
  "a first run must be reported explicitly, never passed over in silence"

apply_out="$("$ORCHID_BIN" plan apply --reason "initial plan" 2>&1)"
assert_match "^applied: " "$apply_out" "plan apply still commits when nothing is carried forward"
assert_match "no previous run is archived" "$apply_out" \
  "plan apply reports its cross-check even when the answer is 'nothing'"

# ===========================================================================
# 2 -- a previous run that left nothing. Same discipline: the check has run,
# it found no ledger items and no active lessons, and it says so rather than
# printing nothing and reading like a pass nobody performed.
# ===========================================================================
roll_over "open the second run of a repository that recorded nothing"
assert_eq "r-002" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the empty fixture rolled over"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck exits 0 when the previous run left nothing"
assert_match "r-001 recorded no ledger items and carried no active lessons" "$out" \
  "an empty previous run is stated, not skipped"

rc=0; out="$("$ORCHID_BIN" plan defer L001 --reason "nothing to defer" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse when nothing at all is carried forward"
assert_match "nothing is carried forward" "$out" "...and says why, rather than journaling a decision about a phantom"

# ===========================================================================
# 3 -- the real shape. r-001 records two ledger items and two lessons, then
# rolls over; r-002 is planned against them.
#
# The two ledger items are recorded the two DIFFERENT ways the archived
# journals actually contain them: one with the deliberate `ledger` entry
# kind, and one as prose inside an ordinary entry ("recorded as a ledger
# candidate for..."), which is how r-001 -- the run that motivated all of
# this -- wrote every one of its own. If only the tidy spelling were
# recognized, this check would not have caught the miss it was built for.
# ===========================================================================
new_repo b
b_bare="$WORK/b-bare"
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "r-001 task" >/dev/null
"$ORCHID_BIN" plan apply --reason "r-001 plan" >/dev/null

"$ORCHID_BIN" journal add --kind ledger \
  "libexec/orchid-task stamps started_at only when the field is empty, so the budget stays anchored to attempt 1" >/dev/null
"$ORCHID_BIN" journal add --kind intervention \
  "drive_implementing lacks the liveness guard its sibling arms carry - recorded as a ledger candidate for the next run" >/dev/null

"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" \
  "verb_lock_acquire must never eval a jq-authored shell fragment" >/dev/null
"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" \
  "a retired lesson naming quarantine_probe must never reach the next plan" >/dev/null
"$ORCHID_BIN" lessons retire L002 --reason "superseded by the fixture's own point" >/dev/null

# The rollover reason lands in the NEW journal, so it cannot become a
# ledger item of this cross-check -- but it WOULD become one of the next
# run's, so the fixture keeps the trigger words out of it deliberately.
roll_over "open the second run"
assert_eq "r-002" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the loaded fixture rolled over"
echo "# Requirements v2" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "crosscheck exits 3 while carried-forward items are unconsidered"
assert_match "left 3 carried-forward item" "$out" \
  "both ledger spellings and the ACTIVE lesson are carried forward (three items)"
assert_match "UNCOVERED \[ledger\] r-001#[0-9]+ .*started_at" "$out" \
  "the ledger item recorded with the ledger entry kind is found"
assert_match "UNCOVERED \[ledger\] r-001#[0-9]+ .*drive_implementing" "$out" \
  "the ledger item recorded only as prose is found too"
assert_match "UNCOVERED \[lesson\] L001" "$out" "the carried-forward active lesson is found"
grep -q "L002" <<<"$out" \
  && fail "a RETIRED lesson is not carried forward by orchid run new and must not be cross-checked"
grep -q "quarantine_probe" <<<"$out" \
  && fail "the retired lesson's text must not reach the cross-check either"

# The ids are positional in the archived journal, so read them out of the
# report rather than hard-coding an ordinal that a fixture edit would shift.
started_id="$(grep -oE 'r-001#[0-9]+' <<<"$(grep started_at <<<"$out")")"
drive_id="$(grep -oE 'r-001#[0-9]+' <<<"$(grep drive_implementing <<<"$out")")"
[ -n "$started_id" ] || fail "could not read the started_at ledger item's id back out of the report"
[ -n "$drive_id" ] || fail "could not read the drive_implementing ledger item's id back out of the report"
[ "$started_id" != "$drive_id" ] || fail "the two ledger items must have distinct ids"

# ---------------------------------------------------------------------------
# 3a -- THE ANTI-ASSERTION this whole design turns on. Every task file
# carries `started_at:` as a frontmatter KEY. A whole-file grep would
# therefore report the started_at ledger item as covered by any task at all,
# including this deliberately unrelated one -- i.e. covered by a plan that
# never considered it. That is not a hypothetical false positive; it is the
# one this check would most plausibly have shipped with, and it would have
# reproduced r-002's original miss while printing "covered".
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T011 "tidy the notify plugin docs" >/dev/null
grep -q '^started_at:' .orchid/tasks/T011.md \
  || fail "fixture assumption broken: task frontmatter no longer carries a started_at key"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "an unrelated task considers nothing"
assert_match "UNCOVERED \[ledger\] $started_id" "$out" \
  "a frontmatter KEY must never count as coverage — every task file contains started_at:"

# ---------------------------------------------------------------------------
# 3b -- A COVERED ITEM. T010's acceptance criteria name the field, so the
# item is associated with a task and the question has been asked.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T010 "re-anchor the attempt clock" >/dev/null
"$ORCHID_BIN" task set T010 acceptance_criteria \
  "stamp started_at on every advance into implementing, not only the first" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "still refused while the other two items are unconsidered"
assert_match "covered   \[ledger\] $started_id .*\(task T010\)" "$out" \
  "the ledger item is covered by the task whose text names it, and the task is named back"

# ---------------------------------------------------------------------------
# 3c -- AN EXPLICITLY DEFERRED ITEM. Deferral is the release valve: the
# operator may decline to schedule a carried item, but only by name and with
# a reason, journaled before it counts. It reports as `deferred`, never as
# `covered` -- a decision to skip is not the same fact as a task existing.
# ---------------------------------------------------------------------------
defer_out="$("$ORCHID_BIN" plan defer L001 --reason "the lock fix landed in r-001; nothing left to schedule" 2>&1)"
assert_match "L001: deferred" "$defer_out" "plan defer confirms the recorded decision"
grep -q "^deferred L001: the lock fix landed in r-001" .orchid/journal.md \
  || fail "the deferral must be journaled as a durable, reasoned decision"
grep -q "plan_deferral" .orchid/journal.md \
  || fail "the deferral entry carries its own journal kind, so it is auditable as a planning decision"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "one genuinely unconsidered item still refuses the plan"
assert_match "deferred  \[lesson\] L001 .*\(deferred: the lock fix landed" "$out" \
  "a deferred item reports as decided, with its reason, not as covered"
assert_match "UNCOVERED \[ledger\] $drive_id" "$out" "the third item is still unconsidered"

# ---------------------------------------------------------------------------
# 3d -- plan defer's own refusals. Each of these, admitted, would leave a
# real item unconsidered while looking decided.
# ---------------------------------------------------------------------------
rc=0; out="$("$ORCHID_BIN" plan defer L999 --reason "typo" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse an id that is not carried forward — a typo would read as a decision"
assert_match "not a carried-forward item" "$out" "...saying so"
assert_match "L001" "$out" "...and printing the real ids so the retry is a copy-paste"

rc=0; out="$("$ORCHID_BIN" plan defer "$drive_id" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer requires --reason (INV-08)"
assert_match "requires --reason" "$out" "...naming the requirement"

rc=0; out="$("$ORCHID_BIN" plan defer L001 --reason "again" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse to re-defer an item already deferred"
assert_match "already deferred" "$out" "...saying so"

# ---------------------------------------------------------------------------
# 3e -- THE REFUSAL ITSELF. This is the whole feature: the plan cannot be
# committed while a carried-forward item is unconsidered, and the refusal is
# actionable, transactional, and leaves the run exactly where it was.
# ---------------------------------------------------------------------------
pre_integ="$(git -C "$b_bare" rev-parse orchid/integration)"
rc=0; apply_out="$("$ORCHID_BIN" plan apply --reason "r-002 plan" 2>&1)" || rc=$?
assert_eq 3 "$rc" "plan apply refuses while a carried-forward item is unconsidered"
assert_match "plan apply refused" "$apply_out" "the refusal names itself"
assert_match "orchid plan defer $drive_id" "$apply_out" "the refusal prints the exact recovery command"
assert_eq planning "$(fm_get .orchid/roadmap.md run_status)" "a refused plan apply leaves run_status untouched"
assert_eq "$pre_integ" "$(git -C "$b_bare" rev-parse orchid/integration)" \
  "a refused plan apply commits nothing to the integration branch"
grep -q "r-002 plan" .orchid/journal.md \
  && fail "a refused plan apply must not journal its reason — nothing happened"

# The verb lock is released on that refusal (the arm exits under its own EXIT
# trap), so the very next verb works. If it leaked, this defer would refuse
# with a lock-held message instead.
"$ORCHID_BIN" plan defer "$drive_id" \
  --reason "the driver guard belongs to its own follow-up task, not this run" >/dev/null \
  || fail "plan defer must work immediately after a refused plan apply (the verb lock must not leak)"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck passes once every carried item is covered or deferred"
assert_match "all 3 carried-forward item\(s\) considered" "$out" "...and says so"

apply_out="$("$ORCHID_BIN" plan apply --reason "r-002 plan" 2>&1)"
assert_match "^applied: " "$apply_out" "plan apply proceeds once nothing is left unconsidered"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" "and takes the run to running as before"
# Captured, then matched from a herestring: `git show | grep -q` closes the
# pipe at the first match and `set -o pipefail` (tests/helpers.sh) reports
# the resulting SIGPIPE as a failure of the whole match — lesson L005.
committed_journal="$(git -C "$b_bare" show "orchid/integration:.orchid/journal.md")"
grep -q "^deferred L001: " <<<"$committed_journal" \
  || fail "the deferral decisions ride onto the integration branch in the plan apply commit"

# ---------------------------------------------------------------------------
# 3f -- deferral is a PLANNING decision. Once the plan is applied, the way to
# pick a carried item up is a task, not a retroactive note.
# ---------------------------------------------------------------------------
rc=0; out="$("$ORCHID_BIN" plan defer L001 --reason "too late" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse once planning is over"
assert_match "requires run_status planning" "$out" "...naming the gate it failed"

rc=0; out="$("$ORCHID_BIN" plan bogus 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown plan subverb is refused"
assert_match "crosscheck" "$out" "usage names the cross-check subverb"
assert_match "defer" "$out" "usage names the defer subverb"

# ===========================================================================
# 4 -- a deferral postpones an item; it does not erase it. `plan_deferral`
# is itself a ledger kind, so r-002's two deferrals come back as r-003's
# carried-forward items and need either a task or a fresh reason.
#
# Without this, the check would launder a defect out of existence in exactly
# two rollovers -- one more run than the failure it was built to prevent,
# and far harder to notice, because the item would leave no trace of ever
# having been raised.
# ===========================================================================
roll_over "open the third run"
assert_eq "r-003" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the fixture rolled over a second time"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "last run's deferrals are unconsidered again in the new plan"
assert_match "UNCOVERED \[ledger\] r-002#[0-9]+ .*deferred $drive_id" "$out" \
  "the ledger item deferred in r-002 resurfaces in r-003 rather than vanishing"
assert_match "UNCOVERED \[ledger\] r-002#[0-9]+ .*deferred L001" "$out" \
  "the deferral of the lesson resurfaces too, carrying its recorded reason"
assert_match "UNCOVERED \[lesson\] L001" "$out" \
  "and the lesson itself is still active, so it is still carried forward"
