#!/usr/bin/env bash
# v1-m2 Task 6: per-verb transactional locking (runtime/verb-lock).
#
# kernel.md: "Per-verb transactional locking ... is a Plan B deliverable,
# arriving alongside the tick loop." With a pump-launched tick and an
# interactive session both alive, epoch fencing alone leaves a torn-write
# window between a verb's fence check and its write. This file proves:
#   1. that window is REAL (30 parallel `journal add` calls lose entries
#      without the lock -- demonstrated by bypassing it) and CLOSED (exactly
#      30 land with the lock doing its job);
#   1b. direct mutual exclusion under that same 30-way contention: no two
#      acquirers ever simultaneously believe they hold the lock (this is
#      the specific double-owner compound race a review round found and
#      fixed in verb_lock_acquire's claim-side self-verification);
#   2. the lock is reentrant (a verb that shells out to another verb, e.g.
#      `task advance` -> `journal add`, never self-deadlocks);
#   3. a dead owner's lock is broken immediately (no age floor);
#   4. a live owner's lock makes a second acquirer WAIT, then succeed;
#   5. a live owner's lock also eventually times out (verb_lock_wait_s);
#   6. read-only verbs never take the lock at all, even while it's held.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"

cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

# ---------------------------------------------------------------------------
# 1. 30 parallel `orchid journal add` invocations.
#
# `journal add`'s durable write is read-whole-file + append + atomic_write
# the WHOLE file back (libexec/orchid-journal) -- a classic lost-update race
# under real concurrency. RED demonstrates the race is real by BYPASSING the
# lock: `ORCHID_VERB_LOCK_HELD=1` is the same reentrancy guard nested verb
# calls rely on (lib/common.sh's verb_lock_acquire treats it as "already
# held, no-op"), so exporting it here legitimately simulates "no lock" for
# exactly this measurement. GREEN re-runs the identical 30-way race with the
# lock doing its job and requires exactly 30 -- proving the LOCK, not
# something else, is what closes the race.
# ---------------------------------------------------------------------------
red_dir="$WORK/red"; mkdir -p "$red_dir/.orchid"
(
  export ORCHID_REPO="$red_dir" ORCHID_EPOCH=0 ORCHID_VERB_LOCK_HELD=1
  for i in $(seq 1 30); do
    "$ORCHID_BIN" journal add --kind note "entry $i" >/dev/null 2>&1 &
  done
  wait
)
red_count="$(grep -c '^## ' "$red_dir/.orchid/journal.md" 2>/dev/null || echo 0)"
[ "$red_count" -lt 30 ] || fail "RED: 30 parallel journal adds WITHOUT the lock should lose entries (got all $red_count -- race not demonstrated here)"

green_dir="$WORK/green"; mkdir -p "$green_dir/.orchid"
(
  export ORCHID_REPO="$green_dir" ORCHID_EPOCH=0
  for i in $(seq 1 30); do
    "$ORCHID_BIN" journal add --kind note "entry $i" >/dev/null 2>&1 &
  done
  wait
)
green_count="$(grep -c '^## ' "$green_dir/.orchid/journal.md" 2>/dev/null || echo 0)"
assert_eq 30 "$green_count" "GREEN: 30 parallel journal adds WITH the verb lock land exactly 30 entries"

# ---------------------------------------------------------------------------
# 1b. Direct mutual-exclusion stress, same 30-way contention: each acquirer
# writes a "holder" marker naming itself while inside the critical section
# and confirms no OTHER holder marker was present when it arrived, and that
# its own marker is still intact just before it clears it. Two acquirers
# ever seeing/overwriting each other's marker is direct evidence of the
# double-owner compound race (a breaker's non-atomic `rm -rf` landing after
# a fresh claimant's own mkdir, then a third process's claim-write blindly
# overwriting the survivor) that a review round found and closed via
# verb_lock_acquire's claim-side self-verification (lib/common.sh: the exit
# condition is "owner.json exists AND names me", never "I wrote it").
# ---------------------------------------------------------------------------
mutex_dir="$WORK/mutex"; mkdir -p "$mutex_dir/.orchid"
holder_marker="$mutex_dir/.orchid/holder"
violations="$mutex_dir/.orchid/violations"
rm -f "$violations"
for i in $(seq 1 30); do
  (
    unset ORCHID_VERB_LOCK_HELD
    verb_lock_acquire "$mutex_dir" || exit 1
    if [ -e "$holder_marker" ]; then
      echo "pid $$ found an existing holder marker on arrival: $(cat "$holder_marker" 2>/dev/null)" >> "$violations"
    fi
    echo "$$" > "$holder_marker"
    sleep 0.02
    [ "$(cat "$holder_marker" 2>/dev/null)" = "$$" ] \
      || echo "pid $$'s holder marker was overwritten by someone else before it cleared it" >> "$violations"
    rm -f "$holder_marker"
    verb_lock_release "$mutex_dir"
  ) &
done
wait
[ -f "$violations" ] && fail "double-owner detected under 30-way verb_lock_acquire contention: $(cat "$violations")"

# ---------------------------------------------------------------------------
# 2. Reentrancy: `task advance ... --reason` shells out to `journal add`
# (orchid-task's `journal()` wrapper) while the OUTER verb already holds the
# lock. A non-reentrant lock would have this nested call block forever on
# its own parent's lock -- a guaranteed deadlock.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create NEST001 "reentrancy demo" >/dev/null
t0=$SECONDS
rc=0
"$ORCHID_BIN" task advance NEST001 blocked --reason "reentrancy check" >/dev/null 2>&1 || rc=$?
t1=$SECONDS
assert_eq 0 "$rc" "task advance (outer lock) -> journal add (nested, reentrant) must not deadlock"
[ $(( t1 - t0 )) -lt 5 ] || fail "nested advance->journal took $(( t1 - t0 ))s -- looks blocked, not reentrant"
assert_match "reentrancy check" "$(cat .orchid/journal.md)" "the nested journal add actually ran (reason landed in journal.md)"

# ---------------------------------------------------------------------------
# 3. Dead-owner break: a held verb-lock whose owner is verifiably dead (pid
# gone) is broken IMMEDIATELY -- no age floor (unlike the RUN lock's
# lock_break_s), since verb transactions are sub-second.
# ---------------------------------------------------------------------------
dead_dir="$WORK/deadowner"; mkdir -p "$dead_dir/.orchid"
rt_dead="$(orchid_runtime "$dead_dir")"
mkdir -p "$rt_dead/verb-lock"
jq -n --arg h "$(hostname)" '{pid: 999999, pid_start: "x", hostname: $h}' > "$rt_dead/verb-lock/owner.json"
t0=$SECONDS
( unset ORCHID_VERB_LOCK_HELD; verb_lock_acquire "$dead_dir" ) || fail "verb_lock_acquire must break a dead owner's lock"
t1=$SECONDS
[ $(( t1 - t0 )) -lt 2 ] || fail "dead-owner break took $(( t1 - t0 ))s -- should be immediate (no age floor)"
[ -f "$rt_dead/verb-lock/owner.json" ] || fail "acquiring after the break must leave a fresh owner.json in place"

# ---------------------------------------------------------------------------
# 4. Live-owner contention: a verb-lock held by a genuinely LIVE owner makes
# a second acquirer WAIT (polling every 0.2s), not break it -- and it
# succeeds once the holder actually releases.
# ---------------------------------------------------------------------------
live_dir="$WORK/liveowner"; mkdir -p "$live_dir/.orchid"
hold_s=3
(
  unset ORCHID_VERB_LOCK_HELD
  verb_lock_acquire "$live_dir"
  sleep "$hold_s"
  verb_lock_release "$live_dir"
) &
holder_pid=$!
sleep 0.5   # let the holder actually win the mkdir race before timing the waiter

t0=$SECONDS
( unset ORCHID_VERB_LOCK_HELD; verb_lock_acquire "$live_dir" && verb_lock_release "$live_dir" ) \
  || fail "waiter must eventually succeed once the live holder releases"
t1=$SECONDS
waited=$(( t1 - t0 ))
[ "$waited" -ge $(( hold_s - 1 )) ] || fail "waiter should have waited roughly ${hold_s}s for the live holder to release (only waited ${waited}s)"
wait "$holder_pid" 2>/dev/null

# ---------------------------------------------------------------------------
# 5. Timeout: a verb-lock held by a live owner for longer than the
# configured `verb_lock_wait_s` makes the waiter give up with the documented
# die message, rather than waiting forever.
# ---------------------------------------------------------------------------
timeout_dir="$WORK/timeout"; mkdir -p "$timeout_dir/.orchid"
printf 'verb_lock_wait_s=1\n' > "$timeout_dir/orchid.config"
(
  unset ORCHID_VERB_LOCK_HELD
  verb_lock_acquire "$timeout_dir"
  sleep 3
  verb_lock_release "$timeout_dir"
) &
timeout_holder_pid=$!
sleep 0.5

rc=0
timeout_err="$( ( unset ORCHID_VERB_LOCK_HELD; verb_lock_acquire "$timeout_dir" ) 2>&1 1>/dev/null )" || rc=$?
[ "$rc" -ne 0 ] || fail "verb_lock_acquire must exit nonzero when it times out waiting on a live holder"
assert_match "verb lock held by pid" "$timeout_err" "timeout die message names the holder"
assert_match "another verb is mid-transaction" "$timeout_err" "timeout die message matches the documented contract"
assert_match "waited 1s" "$timeout_err" "timeout die message reports the configured verb_lock_wait_s"
wait "$timeout_holder_pid" 2>/dev/null

# ---------------------------------------------------------------------------
# 6. Read-only verbs (show/list/check/gc/review-plan/status/config/doctor)
# never take the verb lock at all -- they must run instantly even while a
# live owner holds it, never waiting behind it.
# ---------------------------------------------------------------------------
hold_s2=3
(
  unset ORCHID_VERB_LOCK_HELD
  verb_lock_acquire "$WORK"
  sleep "$hold_s2"
  verb_lock_release "$WORK"
) &
ro_holder_pid=$!
sleep 0.5

t0=$SECONDS
rc=0
ro_out="$("$ORCHID_BIN" task list 2>&1)" || rc=$?
t1=$SECONDS
assert_eq 0 "$rc" "read-only 'task list' must succeed even while the verb lock is held"
assert_match "NEST001" "$ro_out" "'task list' actually read task state"
[ $(( t1 - t0 )) -lt 2 ] || fail "'task list' took $(( t1 - t0 ))s while the lock was held -- read-only verbs must never wait on the verb lock"
wait "$ro_holder_pid" 2>/dev/null

echo "verb lock: OK"
