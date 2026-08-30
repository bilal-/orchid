#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
# Fixture correction (Plan-A backlog step 2): `run start` now refuses an
# uninitialized repo (neither .orchid/tasks/ nor .orchid/roadmap.md present).
# This fixture predates that guard and only created the bare .orchid/ dir —
# widen it to .orchid/tasks so the happy-path `run start` below still passes.
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
e1="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
e2="$("$ORCHID_BIN" run resume | sed 's/epoch: //')"
[ "$e2" -gt "$e1" ] || fail "resume increments epoch ($e1 -> $e2)"
[ -f .orchid/runtime/lease.json ] || fail "lease written"

# lock must not leak when a middle step fails (regression)
mkdir -p "$WORK/stub"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/stub/jq"; chmod +x "$WORK/stub/jq"
rc=0; PATH="$WORK/stub:$PATH" "$ORCHID_BIN" run start >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run start should fail with broken jq"
[ ! -d .orchid/runtime/lock ] || fail "lock leaked after failed run start"
"$ORCHID_BIN" run start >/dev/null || fail "run start works again after failed attempt"

# failed acquire must NOT remove a lock held by another process
"$ORCHID_BIN" run start >/dev/null   # we do not hold the lock now (trap released it), so take it manually:
source "$REPO_ROOT/lib/common.sh"; lock_acquire "$WORK" >/dev/null || fail "manual acquire for fixture"
rc=0; PATH="$WORK/stub:$PATH" "$ORCHID_BIN" run start >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acquire against held lock should fail"
[ -d .orchid/runtime/lock ] || fail "holder's lock must survive a failed acquire"
lock_release "$WORK"

# run start refuses an uninitialized repo (no .orchid/tasks and no roadmap.md)
scratch="$WORK/scratch-uninit"; mkdir -p "$scratch"
(cd "$scratch" && git init -q . && git commit -q --allow-empty -m root)
rc=0; ORCHID_REPO="$scratch" HOME="$WORK/home" "$ORCHID_BIN" run start >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run start must refuse an uninitialized repo"

# v0b2: `run resume` requires initialized state too (same guard as start) —
# resume recovers an existing run after a crash/restart, it does not
# bootstrap one; letting it proceed against an uninitialized repo would mint
# an epoch/lease for state that was never created.
rc=0; ORCHID_REPO="$scratch" HOME="$WORK/home" "$ORCHID_BIN" run resume >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run resume must refuse an uninitialized repo"

# ===========================================================================
# v1-m3 Task 11: `orchid run new` -- run rollover. A real `orchid init` +
# integration-branch worktree is needed here (unlike the bare-.orchid
# fixtures above), since `new` mirrors `orchid plan apply`'s temp-worktree +
# CAS commit pattern against a real integration branch.
# ===========================================================================
bare="$WORK/rn-bare"; mkdir -p "$bare"
(cd "$bare" && git init -q . && git commit -q --allow-empty -m root)
export ORCHID_REPO="$bare"
"$ORCHID_BIN" init >/dev/null
wt="$WORK/rn-wt"
git -C "$bare" worktree add -q "$wt" orchid/integration
export ORCHID_REPO="$wt"
cd "$wt" || exit 1
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "demo" >/dev/null
"$ORCHID_BIN" plan apply --reason "initial plan" >/dev/null
"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" "an active lesson that must carry forward" >/dev/null
"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" "a retired lesson that must NOT carry forward" >/dev/null
"$ORCHID_BIN" lessons retire L002 --reason "no longer relevant" >/dev/null
echo "stable repo fact" > .orchid/context.md
git add .orchid && git commit -q -m "context + lessons fixture"

# refused while running_status is still `running`. Lease staleness (IMPORTANT
# 3, below) is orthogonal to this specific gate, so the lease is removed
# first -- absence reads as "no live session", same as the pump's own
# missing-lease handling -- to isolate the run_status refusal from it.
rm -f .orchid/runtime/lease.json
rc=0; running_out="$("$ORCHID_BIN" run new --reason "too early" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "run new must refuse while run_status is running"
assert_match "requires run_status complete\|blocked" "$running_out" "refusal names the required run_status"
[ ! -d .orchid/runs ] || fail "run new must not have touched anything while refused"

# refused without --reason, even once run_status is legal for it
"$ORCHID_BIN" run advance blocked --reason "smoke shortcut to blocked" >/dev/null

# ---------------------------------------------------------------------------
# v1-m3 final review (IMPORTANT 3): lease-freshness guard. `run refresh-lease`
# here stands in for a live session's own periodic refresh (PROTOCOL.md THE
# TICK steps 1+5) -- a fresh lease means a live orchestrator session may
# still be running, so `run new` must refuse rather than race a rollover
# against it, even though run_status is otherwise legal (blocked, just
# advanced above) and --reason is supplied.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" run refresh-lease
rc=0; fresh_lease_out="$("$ORCHID_BIN" run new --reason "conflicting session" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "run new must refuse while the lease is still fresh"
assert_match "a live orchestrator session may still be running" "$fresh_lease_out" \
  "fresh-lease refusal names the reason"
[ ! -d .orchid/runs ] || fail "run new must not have touched anything while lease-refused"

# Stale/absent lease: no live session left to race -- proceeds normally.
# Absence is the simplest stand-in for staleness (a missing/unparseable
# lease reads as "no live session" too, same policy runners/orchid-pump's
# own missing-lease handling uses).
rm -f .orchid/runtime/lease.json

rc=0; "$ORCHID_BIN" run new >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run new requires --reason (INV-08)"

# archives + resets on a legal status (blocked here; complete is covered by
# the same code path -- run_status is read once, up front, and only its
# membership in {complete, blocked} is checked).
old_journal_before="$(cat .orchid/journal.md)"
"$ORCHID_BIN" run new --reason "rollover to r-002" || fail "run new on a legal (blocked) run_status"

assert_eq "r-002" "$(grep '^run_id: ' .orchid/roadmap.md | cut -d' ' -f2)" \
  "roadmap.md run_id incremented to r-002"
assert_eq "planning" "$(grep '^run_status: ' .orchid/roadmap.md | cut -d' ' -f2)" "roadmap.md reset to run_status planning"
[ -d .orchid/tasks ] && [ -z "$(ls -A .orchid/tasks)" ] || fail "tasks/ is fresh and empty on the new run"
[ -d .orchid/reviews ] && [ -z "$(ls -A .orchid/reviews)" ] || fail "reviews/ is fresh and empty on the new run"
assert_eq "# Blockers" "$(cat .orchid/BLOCKERS.md)" "BLOCKERS.md reset"

# the fresh journal's FIRST entry names the archived run (kind intervention)
first_journal_entry="$(grep -m1 '^## ' .orchid/journal.md)"
assert_match "intervention" "$first_journal_entry" "fresh journal's first entry is kind intervention"
assert_match "r-001 archived to runs/r-001/ -> r-002" "$(cat .orchid/journal.md)" "fresh journal names the archived run and the rollover reason"
assert_match "rollover to r-002" "$(cat .orchid/journal.md)" "fresh journal carries the --reason text"
[ "$(grep -c '^## ' .orchid/journal.md)" = 1 ] || fail "fresh journal.md has exactly one entry so far"

# runs/r-001/ holds the OLD journal.md, intact and byte-identical, plus the
# rest of the archived run's durable state.
[ -f .orchid/runs/r-001/journal.md ] || fail "runs/r-001/journal.md exists"
assert_eq "$old_journal_before" "$(cat .orchid/runs/r-001/journal.md)" "runs/r-001/journal.md is byte-identical to the pre-rollover journal"
[ -f .orchid/runs/r-001/roadmap.md ] || fail "runs/r-001/roadmap.md archived"
grep -q "run_id: r-001" .orchid/runs/r-001/roadmap.md || fail "archived roadmap.md still shows r-001"
[ -f .orchid/runs/r-001/tasks/T001.md ] || fail "runs/r-001/tasks/T001.md archived"
[ -f .orchid/runs/r-001/BLOCKERS.md ] || fail "runs/r-001/BLOCKERS.md archived"

# lessons.md carries forward ACTIVE blocks only
grep -q "an active lesson that must carry forward" .orchid/lessons.md \
  || fail "run new carries forward the active lesson"
grep -q "a retired lesson that must NOT carry forward" .orchid/lessons.md \
  && fail "run new must not carry forward a retired lesson"

# context.md carries forward untouched
assert_eq "stable repo fact" "$(cat .orchid/context.md)" "context.md carried forward untouched"

# a second `run new` immediately, still on run_status planning, is refused
rc=0; "$ORCHID_BIN" run new --reason "too soon again" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run new must refuse again immediately (run_status is now planning)"

# the fresh run is fully usable: requirements import (planning again),
# task create, and plan apply all work against r-002.
echo "# Requirements v2" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md || fail "requirements import works on the fresh run"
"$ORCHID_BIN" task create T010 "second-run task" || fail "task create works on the fresh run"
# T021: the rollover just above CREATED a carried-forward item -- the active
# lesson `run new` copied into r-002 -- so `plan apply` now refuses to commit
# a plan that neither covers nor defers it. Asserted here only because this
# fixture is what produces the carry-forward; the cross-check itself is
# tests/test_plan.sh's subject.
rc=0; carry_out="$("$ORCHID_BIN" plan apply --reason "second plan" 2>&1)" || rc=$?
assert_eq 3 "$rc" "plan apply is refused while the carried-forward lesson is unconsidered"
assert_match "L001" "$carry_out" "the refusal names the lesson run new carried forward"
"$ORCHID_BIN" plan defer L001 --reason "rollover fixture: out of scope for the second run" >/dev/null \
  || fail "plan defer records the decision on a carried-forward lesson"
"$ORCHID_BIN" plan apply --reason "second plan" || fail "plan apply works on the fresh run"
assert_eq "running" "$(grep '^run_status: ' .orchid/roadmap.md | cut -d' ' -f2)" "plan apply advances the fresh run to running"
grep -q "plan apply" <<<"$(git -C "$bare" log --format=%s -1 "orchid/integration")" \
  || fail "plan apply's commit landed on the integration branch"

# ===========================================================================
# post-review CRITICAL 2: shadow-dir swap crash-window recovery. A truly
# deterministic "kill the process between the swap's two mv calls" is
# impractical in a bash test harness -- that window is a handful of
# syscalls wide, with no hook to pause the real verb mid-flight without
# invasively rewriting it just to make it kill-able (noted explicitly here,
# per the review's own fallback instruction, rather than faked). What IS
# testable, and is the actual safety property that matters: reproducing the
# EXACT on-disk shape that crash window would leave (.orchid/ wholly
# absent -- never split-brain), and proving the one documented recovery
# command (the comment above the swap in libexec/orchid-run) genuinely
# restores it.
# ===========================================================================
snap_run_id="$(grep '^run_id: ' .orchid/roadmap.md)"
snap_run_status="$(grep '^run_status: ' .orchid/roadmap.md)"
snap_journal="$(cat .orchid/journal.md)"
snap_lessons="$(cat .orchid/lessons.md 2>/dev/null || true)"
snap_context="$(cat .orchid/context.md)"

# Reproduce the crash window itself: "$state" renamed away and nothing
# renamed back in -- exactly what a kill between the two mv calls leaves.
mv .orchid .orchid.simulated-crash-backup
[ ! -d .orchid ] || fail "crash-window simulation: .orchid must be wholly absent"

git checkout HEAD -- .orchid || fail "documented recovery command failed: git checkout HEAD -- .orchid"
[ -d .orchid ] || fail "recovery must restore .orchid"
assert_eq "$snap_run_id" "$(grep '^run_id: ' .orchid/roadmap.md)" "recovery restores the correct run_id"
assert_eq "$snap_run_status" "$(grep '^run_status: ' .orchid/roadmap.md)" "recovery restores the correct run_status"
assert_eq "$snap_journal" "$(cat .orchid/journal.md)" "recovery restores journal.md byte-identical"
assert_eq "$snap_lessons" "$(cat .orchid/lessons.md 2>/dev/null || true)" "recovery restores lessons.md byte-identical"
assert_eq "$snap_context" "$(cat .orchid/context.md)" "recovery restores context.md byte-identical"
[ -f .orchid/runs/r-001/journal.md ] || fail "recovery restores the archived runs/r-001/ tree too"

# runtime/ is gitignored and never part of any commit -- `git checkout`
# cannot restore what was never tracked. This is expected, not a gap: a
# fresh `orchid run start|resume` mints a new epoch/lease regardless, same
# as any other crash recovery in this codebase.
[ ! -d .orchid/runtime ] || fail "runtime/ should never be restorable by git checkout -- if this fires, something committed it by mistake"
"$ORCHID_BIN" run resume >/dev/null || fail "run resume works normally after the simulated-crash recovery"
rm -rf .orchid.simulated-crash-backup

# ===========================================================================
# v1-m4 Task 1 (the r-001 journal-loss incident, closed): `run accept`
# commits the run's ENTIRE durable .orchid/ state onto the integration
# branch -- not just the files it directly touches (reviews/acceptance.log,
# journal.md, roadmap.md). This fixture's own checkout ($wt) IS a real
# worktree of the integration branch (`$bare`'s orchid/integration), so this
# also exercises the operator's actual documented working shape, unlike
# test_ownership_verbs.sh's lighter mechanism-only fixture.
# ===========================================================================
"$ORCHID_BIN" task create T011 "third task, never committed via a plan apply" >/dev/null
"$ORCHID_BIN" run advance accepting --reason "wrap up r-002" >/dev/null
echo "acceptance evidence: r-002 done" > "$WORK/r2-evidence.log"
pre_bare_integ="$(git -C "$bare" rev-parse orchid/integration)"
accept_out="$("$ORCHID_BIN" run accept --reason "r-002 complete" --evidence "$WORK/r2-evidence.log")"
assert_match "accepting -> complete" "$accept_out" "run accept prints the transition"
post_bare_integ="$(git -C "$bare" rev-parse orchid/integration)"
[ "$post_bare_integ" != "$pre_bare_integ" ] || fail "run accept must advance the integration branch"
assert_eq "orchid: run accepted (r-002)" "$(git -C "$bare" log -1 --format=%s orchid/integration)" \
  "run accept commit message names the current run id"
grep -q "run_status: complete" <<<"$(git -C "$bare" show "orchid/integration:.orchid/roadmap.md")" \
  || fail "run accept's commit shows run_status complete"
git -C "$bare" show "orchid/integration:.orchid/tasks/T011.md" >/dev/null 2>&1 \
  || fail "run accept commits ALL durable .orchid/ state -- T011.md was never committed via plan apply"
assert_eq "$(cat "$WORK/r2-evidence.log")" "$(git -C "$bare" show "orchid/integration:.orchid/reviews/acceptance.log")" \
  "run accept's commit carries the evidence log"
# The worktree's own checkout is left exactly where it was (still a
# worktree of orchid/integration, same branch/HEAD) -- orchid_commit_durable
# never switches branches or touches the working checkout's own git state.
[ "$(git rev-parse --abbrev-ref HEAD)" = orchid/integration ] || fail "run accept must not switch the worktree's own branch"
assert_eq "$post_bare_integ" "$(git rev-parse HEAD)" "run accept's worktree HEAD now matches the advanced integration branch"

# ===========================================================================
# v1-m4 Task 2 (the "no clean-exit affordance" incident): `orchid run
# release-lease` writes `released: true` into lease.json; both `run new`'s
# own freshness guard (exercised just above, for the plain-fresh-lease case)
# and the pump (tests/test_pump.sh) must treat a RELEASED lease as
# immediately stale, regardless of how recently refreshed_at was stamped --
# no more waiting out pump_stale_s, no more hand-backdating lease.json.
# run_status is already `complete` here (the accept just above), which is
# itself a legal starting status for `run new` -- no extra advance needed.
# ===========================================================================
"$ORCHID_BIN" run refresh-lease
"$ORCHID_BIN" run release-lease || fail "release-lease works with a current epoch"
assert_eq true "$(jq -r .released .orchid/runtime/lease.json)" "release-lease writes released: true"
# refreshed_at is still a fresh timestamp (release-lease stamps its own,
# moments ago) -- proving the staleness bypass is keyed on `released`, not on
# age.
released_refreshed_at="$(jq -r .refreshed_at .orchid/runtime/lease.json)"
released_epoch="$(date -u -d "$released_refreshed_at" +%s 2>/dev/null \
  || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$released_refreshed_at" +%s)"
[ $(( $(date -u +%s) - released_epoch )) -lt 5 ] || fail "sanity: released_refreshed_at should be moments ago"

rc=0; released_new_out="$("$ORCHID_BIN" run new --reason "released lease must not block" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "run new must proceed immediately once the lease is released, even though refreshed_at is fresh (got: $released_new_out)"
assert_match "run rolled over: r-002 -> r-003" "$released_new_out" "run new actually rolled over past the released lease"

# release-lease itself must be epoch-fenced: a stale ORCHID_EPOCH is refused
# (INV-02), same as every other mutating run verb.
rc=0; ORCHID_EPOCH=$(( ORCHID_EPOCH - 1 )) "$ORCHID_BIN" run release-lease >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "release-lease with a stale epoch must be refused (INV-02)"

# ===========================================================================
# T036 -- THE WAKE BUDGET, and the boundary record's `passes` counter it is
# answered from.
#
# The live finding was a pump that woke an orchestrator pass after pass over a
# boundary no wakeup moved -- eight consecutive times, with the interval
# shrinking rather than the polling stopping. Resolvability alone cannot stop
# it: "an orchestrator could settle this" is a static property of (kind, task
# status, command_surface), so it is satisfied identically on the hundredth
# pass as on the first and cannot notice that the record has not changed by a
# character in between.
#
# The counter that CAN notice is the boundary record's own `passes`: `orchid
# run boundary set` bumps it whenever the record it is handed is unchanged by
# content, and resets it to 1 when it is not. Both the pump (which declines the
# wake) and the driver (which raises the blocker instead) read one predicate
# over it, in lib/drive.sh, so the two can never disagree about whether a
# boundary is still worth a model's time.
#
# THE BOUNDARY DRIVEN HERE IS `review-conflict` OVER AN `arbitrating` TASK, and
# that choice is load-bearing. It is the shape a woken orchestrator really can
# settle -- `orchid task arbitrate` is in the write set BOTH surfaces admit
# (lib/drive.sh's _DRIVE_BROKERED_WRITE_VERBS), and the task's status allows it
# -- so it is the only shape where an unbounded wake loop is still possible at
# all, and therefore the only one a budget can be shown to bound. A
# `run-complete` boundary is NOT that shape: no surface admits `orchid run
# accept`, so it is operator-only on every one of them and the pump declines it
# one gate earlier, at 5c. That half of the finding is asserted at the end of
# this block, on its own terms -- a run whose tasks are all done must wake
# nobody, which is a different mechanism with the same required outcome.
#
# Driven end to end through the real pump against a real stub orchestrator:
# what is being proven is that a wake STOPS HAPPENING, and only a spawn that
# does not happen can show that.
# ===========================================================================
# lib/common.sh FIRST, and not only for tidiness: drive_wake_budget_max calls
# config_get, which lives there, and lib/drive.sh sources nothing of its own
# (every other caller -- the pump, the driver, tests/test_drive.sh -- has
# already sourced the kernel by the time it reads this file). Without it the
# budget's config lookup is a `command not found` whose empty output lands in
# the malformed-value arm and falls back to the very default the assertion
# below checks for -- so the arm would pass while proving nothing, which is
# exactly what the configured-value assertion further down now rules out.
#
# The rest of the list is runners/orchid-pump's own source order, and it is
# here for the availability probe at the very end of this block:
# drive_orchestrator_available walks the role chain through lib/resolver.sh and
# prices the `orchestrate` step through lib/capability.sh, and a caller that
# passes a step without the latter sourced is REFUSED (exit 3) rather than
# answered -- which would make "an incapable engine is unavailable" pass
# without the capability table ever having been consulted.
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/capsuite.sh"
source "$REPO_ROOT/lib/ledger.sh"
source "$REPO_ROOT/lib/drive.sh"
source "$REPO_ROOT/lib/capability.sh"

make_scratch WB
WB_BARE="$WB/bare"; mkdir -p "$WB_BARE"
(cd "$WB_BARE" && git init -q . && git commit -q --allow-empty -m root)

# A `soft` orchestrator: no `command_surface` key at all, which INV-14 reads as
# soft (a manifest may weaken its own claim by omission, never strengthen it).
mkdir -p "$WB/eng/wbstub"
printf 'manifest_version=1\nid=test/wbstub\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WB/eng/wbstub/plugin.conf"
{
  echo '#!/usr/bin/env bash'
  echo 'set -eu'
  echo "MARKER=$(printf '%q' "$WB/marker-wbstub")"
} > "$WB/eng/wbstub/run"
cat >> "$WB/eng/wbstub/run" <<'WBEOF'
# One line per spawn: the assertions below are about HOW MANY times a model was
# woken, so a marker that merely exists would answer the wrong question.
printf 'woken\n' >> "$MARKER"
req="$1"; out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"orchestrate","status":"ok","actions":[],"summary":"wake-budget stub"}' \
  "$jid" "$task" > "$out"
WBEOF
chmod +x "$WB/eng/wbstub/run"
export ORCHID_ENGINES_DIR="$WB/eng"
: > "$WB/marker-wbstub"

ORCHID_REPO="$WB_BARE" "$ORCHID_BIN" init >/dev/null || fail "wake-budget fixture: orchid init"
WB_WT="$WB/wt"
git -C "$WB_BARE" worktree add -q "$WB_WT" orchid/integration \
  || fail "wake-budget fixture: integration worktree"
# Appended, never overwritten: `orchid init` may have committed an
# orchid.config of its own into the integration branch, and last-match-wins
# means this line still selects the orchestrator without discarding whatever
# else that file already established.
printf 'role.orchestrator=wbstub\n' >> "$WB_WT/orchid.config"

cd "$WB_WT" || exit 1
unset ORCHID_EPOCH
export ORCHID_REPO="$WB_WT"
WB_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$WB_EPOCH"
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create W001 "a contested review, parked for arbitration" >/dev/null
"$ORCHID_BIN" task create W002 "already finished" >/dev/null
"$ORCHID_BIN" plan apply --reason "wake-budget fixture" >/dev/null
# W001 is parked at `arbitrating` over a request-changes review: the
# `review-conflict` boundary, settled by `orchid task arbitrate`, which is the
# one write BOTH command surfaces admit. This is the exact fixture shape
# tests/test_pump.sh uses to reach the LLM hand-off at all.
#
# `done` is QUOTED. Bare, it is a shell keyword sitting in argument position,
# which is exactly the shape ShellCheck flags (SC1010) and ci-local runs at
# --severity=warning, so the linter -- not bash -- is what would reject it.
# Every other fixture in this suite that plants a finished status spells it
# the same way (tests/test_drive.sh's F010/B010 fixtures).
WB_CAND=7777777777777777777777777777777777777777
fm_set "$WB_WT/.orchid/tasks/W001.md" status arbitrating
fm_set "$WB_WT/.orchid/tasks/W001.md" candidate_sha "$WB_CAND"
fm_set "$WB_WT/.orchid/tasks/W002.md" status "done"
mkdir -p "$WB_WT/.orchid/reviews"
jq -n --arg cand "$WB_CAND" \
  '{contract:1, job_id:"j-fixture-W001", task:"W001", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:"wake-budget fixture review",
    candidate_sha:$cand, findings:[]}' > "$WB_WT/.orchid/reviews/W001-a1-reviewer.json"
unset ORCHID_EPOCH
HOME="$HOME" "$ORCHID_BIN" trust unattended "$WB_WT" --reason "wake-budget fixture" >/dev/null \
  || fail "wake-budget fixture: unattended acknowledgement"

WB_PUMP="$REPO_ROOT/runners/orchid-pump"
# Every pump pass that reaches the tick refreshes the lease, so it has to be
# re-staled before the next one or the pass exits at the freshness gate having
# driven nothing.
wb_stale_lease() {
  local now target iso
  now="$(date -u +%s)"; target=$((now - 100000))
  iso="$(date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$WB_WT/.orchid/runtime"
  jq -n --arg t "$iso" '{epoch:1, refreshed_at:$t}' > "$WB_WT/.orchid/runtime/lease.json"
}
wb_boundary() { ORCHID_REPO="$WB_WT" "$ORCHID_BIN" run boundary show 2>/dev/null || true; }
wb_field()    { printf '%s' "$(wb_boundary)" | jq -r "$1" 2>/dev/null || echo ""; }
wb_wakes()    { wc -l < "$WB/marker-wbstub" | tr -d ' '; }

# -- the predicate itself, before anything drives it ----------------------
assert_eq 3 "$(drive_wake_budget_max "$WB_WT")" \
  "pump_wake_max defaults to 3 when nothing configures it"
if drive_wake_budget_exhausted 3 3; then
  fail "the budget is NOT spent on the pass that uses its last permitted wakeup"
fi
if ! drive_wake_budget_exhausted 4 3; then
  fail "the budget IS spent once a boundary outlives it"
fi
if drive_wake_budget_exhausted "" 3 || drive_wake_budget_exhausted 4 "not-a-number"; then
  fail "a malformed counter must fail OPEN (budget remains) -- it must never be what silently stops a run being driven"
fi

# -- the counter's identity, and the ranking that reads it -----------------
# The count is filed per boundary IDENTITY, and the driver's ranking reads
# those entries back before it chooses which boundary to record. Writer and
# reader compose that identity through ONE function, so a key built two ways
# cannot make the ranking look up a boundary that is not the one the record
# filed.
# The separator as a literal character rather than as a `tr` escape: `\037` in
# a SET is read by some `tr` implementations and not others, and this suite has
# to count the same separators wherever it runs.
WB_US=$'\037'
WB_KEY="$(drive_boundary_counter_key review-conflict W001 "a contested review")"
assert_eq 2 "$(printf '%s' "$WB_KEY" | tr -cd "$WB_US" | wc -c | tr -d ' ')" \
  "the key is three fields, and a US separator keeps them three"
assert_eq 2 "$(printf '%s' "$(drive_boundary_counter_key run-complete "" "the run is finished")" \
  | tr -cd "$WB_US" | wc -c | tr -d ' ')" \
  "a run-level boundary's EMPTY task stays a field of its own -- collapsed, it would collide with a task-scoped boundary of the same kind"

assert_eq 2 "$(drive_boundary_spent "$(jq -nc --arg k "$WB_KEY" '{($k): 2}')" \
  review-conflict W001 "a contested review")" \
  "a boundary's spent wakeups are read out of the record's counters map under its own identity"
assert_eq 0 "$(drive_boundary_spent "$(jq -nc --arg k "$WB_KEY" '{($k): 2}')" \
  review-conflict W002 "a contested review")" \
  "and belong to that boundary alone: another task's entry is not this one's budget"
assert_eq 0 "$(drive_boundary_spent '{}' review-conflict W001 "a contested review")" \
  "a boundary with no entry has spent nothing"
assert_eq 0 "$(drive_boundary_spent 'not json at all' review-conflict W001 "a contested review")" \
  "and an unreadable counters map reads as budget UNTOUCHED -- fail-open, exactly as the exhaustion predicate does"

assert_eq 1 "$(drive_boundary_rank review-conflict arbitrating brokered 0 3)" \
  "a boundary an orchestrator can settle, with its budget untouched, ranks above the operator-only tier"
assert_eq 1 "$(drive_boundary_rank review-conflict arbitrating brokered 3 3)" \
  "and still ranks there on the pass that spends its last permitted wakeup"
assert_eq 0 "$(drive_boundary_rank review-conflict arbitrating brokered 4 3)" \
  "but a boundary whose budget is spent ranks with the operator-only ones -- no wakeup will be spent on it again, so it must not outrank one that still will be"
assert_eq 0 "$(drive_boundary_rank run-complete "" brokered 0 3)" \
  "and an operator-only boundary ranks there however untouched its budget is"

# ...and the budget is genuinely READ, not merely defaulted to. `3` is also
# what a budget whose config lookup does not work at all produces: an empty
# value lands in the malformed-value arm and falls back to the same number, so
# the default assertion above cannot by itself tell a working lookup from a
# missing one. A repository that configures the key explicitly can.
WB_CFG="$WB/configured"; mkdir -p "$WB_CFG"
printf 'pump_wake_max=7\n' > "$WB_CFG/orchid.config"
assert_eq 7 "$(drive_wake_budget_max "$WB_CFG")" \
  "an explicit pump_wake_max is honoured -- the budget comes from config, not from a constant"
printf 'pump_wake_max=0\n' > "$WB_CFG/orchid.config"
assert_eq 3 "$(drive_wake_budget_max "$WB_CFG")" \
  "a zero budget falls back to the default rather than to 'never wake an orchestrator at all'"

# -- an OUTAGE spends no budget --------------------------------------------
# Asked before anything else drives this boundary, because it is about the
# counter's very first pass as much as its later ones.
#
# What the budget charges must be a WAKEUP, not a wall pass. These four passes
# meet a repository whose orchestrator role resolves to nothing at all -- the
# same state a rate-limited or ledger-disabled engine leaves -- so the pump
# reaches its step 6, reports no capable orchestrator, and exits without asking
# any model anything. Counting them would let a transient engine outage exhaust
# the budget on a boundary a model was never given a chance at, and then
# permanently decline to wake one the moment the outage lifted, under a blocker
# claiming wakeups that never happened. That is a worse failure than the
# unbounded polling the budget exists to stop: it parks a run that was still
# capable of moving.
#
# Appended, never overwritten -- last-match-wins is what makes the restore
# below a one-line append too.
printf 'role.orchestrator=nosuchengine\n' >> "$WB_WT/orchid.config"
wb_pass=1
while [ "$wb_pass" -le 4 ]; do
  wb_stale_lease
  wb_outage="$(ORCHID_REPO="$WB_WT" "$WB_PUMP" 2>&1)" || true
  wb_pass=$((wb_pass + 1))
done
assert_match 'no capable orchestrator available' "$wb_outage" \
  "sanity: with no orchestrator resolvable the pump really is exiting at its availability probe"
assert_eq review-conflict "$(wb_field '.kind // ""')" \
  "a contested review parks the run on the review-conflict boundary -- the one an orchestrator can settle"
assert_eq W001 "$(wb_field '.task // ""')" "and the record names the contested task"
assert_eq 0 "$(wb_wakes)" "sanity: an unresolvable orchestrator role wakes nobody"
assert_eq 0 "$(wb_field '.passes // 0')" \
  "four passes on which nobody COULD be woken charge nothing to the wake budget"
red_case "an engine outage records the boundary but spends none of its wake budget"

# -- GREEN: within budget, the pump really does wake an orchestrator -------
# The outage is over. If those four passes had been charged, this repository
# would already be over a budget of 3 and the very first pass below would
# decline -- so the wake count here is the outage arm's proof as much as its
# own.
printf 'role.orchestrator=wbstub\n' >> "$WB_WT/orchid.config"
wb_pass=1
while [ "$wb_pass" -le 3 ]; do
  wb_stale_lease
  ORCHID_REPO="$WB_WT" "$WB_PUMP" >/dev/null 2>&1 || true
  wb_pass=$((wb_pass + 1))
done
assert_eq review-conflict "$(wb_field '.kind // ""')" \
  "the boundary is unmoved: the woken orchestrator settled nothing"
assert_eq 3 "$(wb_field '.passes // 0')" \
  "three wakeups over one unchanged boundary are counted on the record itself"
assert_eq 3 "$(wb_wakes)" \
  "and while the budget lasts the pump really does wake an orchestrator, once per pass"
green_case "an orchestrator-settleable boundary is woken for, once per pass, while its wake budget lasts"

# -- RED: the fourth pass must not wake a fourth orchestrator --------------
wb_stale_lease
rc=0
wb_red="$(ORCHID_REPO="$WB_WT" "$WB_PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "a spent wake budget is a wait state, not a failure -- a cron poll must not start erroring"
assert_eq 4 "$(wb_field '.passes // 0')" "the fourth pass is counted like any other"
assert_match "has survived 4 passes unchanged \(pump_wake_max=3\)" "$wb_red" \
  "the pump says exactly why it declined, and against which budget"
assert_eq 3 "$(wb_wakes)" \
  "and spawned nobody: a boundary no wakeup has moved stops being worth a model's time"
red_case "a boundary that three orchestrator wakeups did not move stops waking a fourth"

# The human is finally told -- on the pass the budget runs out, and only then.
# For every pass before it the boundary looked orchestrator-resolvable, which
# is precisely what kept this notify suppressed while the run polled a model.
assert_match "judgment boundary \[review-conflict\] has survived 3 orchestrator wakeup\(s\) unchanged" \
  "$(cat "$WB_WT/.orchid/BLOCKERS.md")" \
  "the blocker that reaches a human is raised when the wakeups are proven not to have worked"
wb_blocker_lines="$(wc -l < "$WB_WT/.orchid/BLOCKERS.md")"

wb_stale_lease
ORCHID_REPO="$WB_WT" "$WB_PUMP" >/dev/null 2>&1 || true
assert_eq 5 "$(wb_field '.passes // 0')" "a fifth pass still counts itself"
assert_eq 3 "$(wb_wakes)" "and still wakes nobody -- the refusal is durable, not a one-pass hiccup"
assert_eq "$wb_blocker_lines" "$(wc -l < "$WB_WT/.orchid/BLOCKERS.md")" \
  "and raises no second blocker: the budget runs out exactly once per boundary"

# -- RED: a pass nobody scheduled is not a wakeup, and is not charged -------
# The budget is denominated in orchestrator WAKEUPS, and runners/orchid-pump is
# the only caller that goes on to produce one. `orchid drive` is ALSO a verb an
# operator runs by hand and a test runs to reach one arm; neither asks a model
# anything. Charged, a handful of debugging invocations would park a live
# boundary on a human under a blocker naming wakeups nobody ever made -- and
# because an uncharged pass leaves the counter exactly where it stands, the
# once-per-boundary page above would fire again on every one of them.
#
# Deliberately the SAME pass the pump makes -- same repo, same staled lease,
# same driver binary -- with only the provenance different, so what is being
# asserted is the provenance and nothing else.
wb_stale_lease
wb_hand_passes="$(wb_field '.passes // 0')"
rc=0
ORCHID_REPO="$WB_WT" "$REPO_ROOT/runners/orchid-drive" >/dev/null 2>&1 || rc=$?
assert_eq 16 "$rc" "sanity: a hand-run drive parks on the same judgment boundary the pump's own drive does"
assert_eq "$wb_hand_passes" "$(wb_field '.passes // 0')" \
  "a drive nobody scheduled charges nothing -- only a pump pass can spend a wakeup"
assert_eq 3 "$(wb_wakes)" "and wakes nobody itself"
assert_eq "$wb_blocker_lines" "$(wc -l < "$WB_WT/.orchid/BLOCKERS.md")" \
  "and re-pages nobody: an uncharged pass cannot re-announce a budget that ran out once"
red_case "a hand-run orchid drive spends none of the pump's wake budget"

# -- RED: a spent boundary must not starve a live one ----------------------
# The budget stops one boundary being polled forever. Ranked as an orchestrator
# could-settle-this boundary all the same -- which is what it stays, statically,
# for as long as the task sits at `arbitrating` -- a SPENT boundary goes on
# winning the pass's single record slot from boundaries that are still live,
# because equal rank is broken by task-id order and W001 sorts first. The pump
# reads that spent record, declines at its step 6c, and exits 0; W002's
# arbitration, which no wakeup has yet been spent on at all, is never recorded,
# never reaches the pump, and never gets a model. One exhausted task would park
# every later task's arbitration for the rest of the run -- the same starvation
# the priority ranking was introduced to end, one tier down.
#
# W001 is left exactly as the arms above left it: parked, five passes spent
# against a budget of three. W002 is given the identical shape one task later.
WB_CAND2=6666666666666666666666666666666666666666
WB_W001_REASON="$(wb_field '.reason // ""')"
[ -n "$WB_W001_REASON" ] || fail "fixture: the spent boundary must still be the recorded one before a live one is raised beside it"
wb_starve_wakes="$(wb_wakes)"
wb_starve_spent="$(wb_field '.passes // 0')"
if ! drive_wake_budget_exhausted "$wb_starve_spent" 3; then
  fail "fixture: W001's boundary must already be OVER budget here, or this arm proves nothing about a spent one"
fi

fm_set "$WB_WT/.orchid/tasks/W002.md" status arbitrating
fm_set "$WB_WT/.orchid/tasks/W002.md" candidate_sha "$WB_CAND2"
jq -n --arg cand "$WB_CAND2" \
  '{contract:1, job_id:"j-fixture-W002", task:"W002", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:"starvation fixture review",
    candidate_sha:$cand, findings:[]}' > "$WB_WT/.orchid/reviews/W002-a1-reviewer.json"

wb_stale_lease
wb_starve_out="$(ORCHID_REPO="$WB_WT" "$WB_PUMP" 2>&1)" || true
assert_match "supersedes \[review-conflict\]: its wake budget is spent" "$wb_starve_out" \
  "the pass names the mechanism that moved the record -- a SPENT budget, not the older 'no admitted verb resolves that one', which is untrue of a boundary that stayed arbitrable throughout"
assert_eq W002 "$(wb_field '.task // ""')" \
  "the live boundary takes the record from the spent one, however far behind it in task-id order"
assert_eq review-conflict "$(wb_field '.kind // ""')" \
  "and it is the arbitrable kind: the ranking demoted a SPENT boundary, it did not stop ranking by resolvability"
assert_eq 1 "$(wb_field '.passes // 0')" \
  "the live boundary spends the first of its own wakeups -- the budget is per boundary, so W001's spent one is not charged to it"
assert_eq "$((wb_starve_wakes + 1))" "$(wb_wakes)" \
  "and a model really is woken for it: a run with one exhausted task is not a run with nothing left to ask"
assert_eq "$wb_starve_spent" \
  "$(drive_boundary_spent "$(printf '%s' "$(wb_boundary)" | jq -c '.counters // {}')" \
     review-conflict W001 "$WB_W001_REASON")" \
  "and the displaced boundary keeps its own count untouched: demoted is not reset, so it cannot be polled all over again"
assert_eq "$wb_blocker_lines" "$(wc -l < "$WB_WT/.orchid/BLOCKERS.md")" \
  "and no second page: a boundary that loses the slot to a live one was already announced on the pass its budget ran out"
red_case "an exhausted boundary must not starve a live one behind it in task-id order"

# Back to the fixture the arms below expect: W002 finished, its review gone
# with its status. What was proven here is the RANKING, and leaving a second
# arbitrating task standing would make the finished-run arm below assert about
# a run that is not finished.
rm -f "$WB_WT/.orchid/reviews/W002-a1-reviewer.json"
fm_set "$WB_WT/.orchid/tasks/W002.md" status "done"

# -- the counter resets when the boundary actually CHANGES -----------------
# Without this the budget would be a one-way latch: a run that got past the
# parked condition (an operator arbitrates, a new review lands) would never
# wake an orchestrator again, which is a worse failure than the one being
# fixed.
ORCHID_EPOCH="$(ORCHID_REPO="$WB_WT" "$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
ORCHID_REPO="$WB_WT" "$ORCHID_BIN" run boundary set --kind operator-decision \
  --reason "a different condition entirely" >/dev/null \
  || fail "recording a genuinely different boundary must succeed"
assert_eq 1 "$(wb_field '.passes // 0')" \
  "a boundary that differs by content resets the counter -- the budget is per-boundary, never a latch"
unset ORCHID_EPOCH

# -- RED: a run whose tasks are ALL done wakes nobody at all ----------------
# The other half of the live finding, and a DIFFERENT mechanism from the budget
# above: `orchid run accept --reason --evidence` is admitted by no command
# surface, so `run-complete` is operator-only on every one of them and the pump
# declines it at 5c without spending a single wakeup -- not after three, not
# ever. The budget never even gets to apply, which is why this is asserted
# separately rather than folded into the arms above.
#
# The review envelope goes with the status: a `done` task with a contested
# review still in reviews/ is not the finished run this is about.
rm -f "$WB_WT/.orchid/reviews/W001-a1-reviewer.json"
fm_set "$WB_WT/.orchid/tasks/W001.md" status "done"
wb_wakes_before_done="$(wb_wakes)"
wb_pass=1
while [ "$wb_pass" -le 3 ]; do
  wb_stale_lease
  wb_done_out="$(ORCHID_REPO="$WB_WT" "$WB_PUMP" 2>&1)" || true
  wb_pass=$((wb_pass + 1))
done
assert_eq run-complete "$(wb_field '.kind // ""')" \
  "a run whose every task is done parks on the run-complete boundary"
assert_eq accepting "$(fm_get "$WB_WT/.orchid/roadmap.md" run_status)" \
  "COMPLETION's mechanical half is taken without an operator verb -- the run does leave 'running' on its own"
assert_match 'is operator-only — not waking an orchestrator' "$wb_done_out" \
  "and the pump says so, naming the boundary it declined"
assert_eq "$wb_wakes_before_done" "$(wb_wakes)" \
  "a finished run wakes nobody -- not once, let alone every pump_interval_s forever"
assert_eq 0 "$(wb_field '.passes // 0')" \
  "and charges nothing to the wake budget: no wakeup was ever available to spend"
red_case "a run whose tasks are all done stops waking an orchestrator"

# ===========================================================================
# T036 -- THE AVAILABILITY PROBE ASKS THE PUMP'S EXACT QUESTION.
#
# `--no-count` is decided by drive_orchestrator_available, and what it is FOR
# is predicting the arm runners/orchid-pump will take at its step 6. The pump
# probes `resolve_role_available <repo> orchestrator orchestrate` -- with the
# STEP -- because an entry that cannot perform `orchestrate` must be failed
# over rather than settled on (INV-16). Asked without the step, the same walk
# answers a DIFFERENT question: "who may hold the orchestrator role", which
# says yes for exactly the chain the step gate then refuses. Drifted that way,
# the driver calls a wakeup available, charges the budget for it, and the pump
# declines one gate later having woken nobody -- a budget spent on models that
# were never asked, which is the one failure mode the `--no-count` arms exist
# to prevent.
#
# roles/orchestrator.role and the `orchestrate` row happen to require the same
# two atoms, so on the shipped tree the two questions agree and the drift is
# invisible. A role descriptor asking for LESS than the step costs is what
# separates them -- the custom-descriptor case INV-16 was written for -- so the
# fixture repoints ORCHID_ROOT at a roles directory carrying a weakened
# orchestrator descriptor. That is the only way to isolate one: INV-10 refuses
# a second `orchestrator.role` alongside the built-in rather than shadowing it.
# ===========================================================================
WB_ALT="$WB/altroot"; mkdir -p "$WB_ALT/roles"
cp "$REPO_ROOT/roles/"*.role "$WB_ALT/roles/"
printf 'id=orchestrator\nrequires=shell\ndescription=weakened descriptor: role-eligible without git\n' \
  > "$WB_ALT/roles/orchestrator.role"

# An engine this weakened descriptor admits and the `orchestrate` row does not:
# it claims `shell` and not `git`, and `orchestrate` is priced at both.
mkdir -p "$WB/eng/wbnogit"
printf 'manifest_version=1\nid=test/wbnogit\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WB/eng/wbnogit/plugin.conf"
# Deliberately NOT a copy of wbstub's entrypoint: these arms only ever RESOLVE
# this engine, never spawn it, and an entrypoint sharing wbstub's wake marker
# would quietly corrupt the wake counts asserted above if that ever changed.
printf '#!/usr/bin/env bash\nexit 1\n' > "$WB/eng/wbnogit/run"
chmod +x "$WB/eng/wbnogit/run"

# GREEN witness first. Without it a probe that refused everything -- a mistyped
# role, an unsourced capability table, an engines dir the alternate root cannot
# see -- would satisfy the RED arm below while proving nothing at all.
printf 'role.orchestrator=wbstub\n' >> "$WB_WT/orchid.config"
if ! ORCHID_ROOT="$WB_ALT" drive_orchestrator_available "$WB_WT"; then
  fail "sanity: an engine claiming both priced atoms must read as available -- the probe is not simply refusing everything"
fi

printf 'role.orchestrator=wbnogit\n' >> "$WB_WT/orchid.config"
if ! ORCHID_ROOT="$WB_ALT" resolve_role_available "$WB_WT" orchestrator >/dev/null 2>&1; then
  fail "fixture: the shell-only engine must be ROLE-eligible under the weakened descriptor, or the two questions were never different here"
fi
if ORCHID_ROOT="$WB_ALT" drive_orchestrator_available "$WB_WT"; then
  fail "an engine the 'orchestrate' step refuses is NOT an available orchestrator: the probe must ask the pump's question, step and all, or it charges the budget for a wakeup the pump then declines"
fi
red_case "the wake budget's availability probe prices the orchestrate step, exactly as the pump's own probe does"
