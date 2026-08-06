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
"$ORCHID_BIN" plan apply --reason "second plan" || fail "plan apply works on the fresh run"
assert_eq "running" "$(grep '^run_status: ' .orchid/roadmap.md | cut -d' ' -f2)" "plan apply advances the fresh run to running"
git -C "$bare" log --format=%s -1 "orchid/integration" | grep -q "plan apply" \
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
git -C "$bare" show "orchid/integration:.orchid/roadmap.md" | grep -q "run_status: complete" \
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
