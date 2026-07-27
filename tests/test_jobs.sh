#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo

m="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
[ -f "$m" ] || fail "manifest written at printed path"
jid="$(jq -r .job_id "$m")"
assert_match "^j-e[0-9]+-T001-a1-" "$jid" "job id shape"
assert_eq "fake" "$(jq -r .engine "$m")" "engine resolved from role"
assert_eq "0" "$(jq -r .pid "$m")" "prepare does not spawn"
assert_match "T001	prepared" "$("$ORCHID_BIN" jobs check)" "prepared state visible"

# reconcile a good envelope
out="$(jq -r .output "$m")"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"done"}' "$jid" > "$out"
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "reconciled"
[ -f ".orchid/reviews/T001-a1-implementer.json" ] || fail "envelope moved durable"
[ ! -f "$m" ] || fail "manifest deleted"

# pgid guard: pid alive but pgid=0 must never become `kill -- -0` (which
# signals the CALLER's own process group, not just the stuck job). check
# must fall back to killing the pid directly, and the caller must survive
# to reach the assertions below.
sleep 100 &
spid=$!
jq -n --argjson pid "$spid" \
  '{job_id:"j-guard", task:"TGUARD", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:0, log:"/nonexistent.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$WORK/.orchid/runtime/jobs/j-guard.json"
printf 'timeout_minutes=0\n' >> orchid.config
"$ORCHID_BIN" jobs check >/dev/null
echo "PGID_GUARD: caller survived jobs check"
assert_match "PGID_GUARD" "PGID_GUARD: caller survived jobs check" "pgid guard: caller reached post-check assertions"
sleep 0.3
if kill -0 "$spid" 2>/dev/null; then
  fail "pgid guard: sleep pid should have been killed via pid fallback"
  kill "$spid" 2>/dev/null || true
fi
rm -f "$WORK/.orchid/runtime/jobs/j-guard.json"

# ---------------------------------------------------------------------------
# v0b2: `jobs gc [--older-than-s N]` reaps DEAD jobs' runtime litter (the
# manifest -> quarantine as `.reason-gc-dead`, plus its pack dir/request
# file/log removed) once past the age threshold, and separately sweeps
# orphaned pack/request entries that have no manifest AND no pending spool
# envelope. It must never touch a live pid, a dead-but-young manifest, or a
# pack/request that still has a pending spool envelope waiting on it. gc
# mutates only runtime/ (manifests, packs, requests, logs, quarantine) —
# never durable task state — so it is deliberately NOT epoch-fenced (see the
# comment in libexec/orchid-jobs).
# ---------------------------------------------------------------------------
rt="$WORK/.orchid/runtime"
mkdir -p "$rt/jobs" "$rt/packs" "$rt/requests" "$rt/logs" "$rt/spool" "$rt/quarantine"

now="$(date +%s)"
old_started=$(( now - 90000 ))   # > default 86400s threshold

# Dead + old: must be fully reaped (manifest quarantined, pack/request/log gone).
( exit 0 ) & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
mkdir -p "$rt/packs/j-dead"
echo '{}' > "$rt/requests/j-dead.json"
echo dead-log > "$rt/logs/j-dead.log"
jq -n --argjson pid "$dead_pid" --argjson started "$old_started" --arg log "$rt/logs/j-dead.log" \
  '{job_id:"j-dead", task:"TDEAD", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-dead.json"

# Dead but too young: must survive (age alone, not just deadness, gates gc).
( exit 0 ) & young_dead_pid=$!
wait "$young_dead_pid" 2>/dev/null || true
jq -n --argjson pid "$young_dead_pid" --argjson started "$now" --arg log "$rt/logs/j-young-dead.log" \
  '{job_id:"j-young-dead", task:"TYOUNGDEAD", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-young-dead.json"

# Live + old: age must never override a live pid.
sleep 100 &
live_pid=$!
jq -n --argjson pid "$live_pid" --argjson started "$old_started" --arg log "$rt/logs/j-live.log" \
  '{job_id:"j-live", task:"TLIVE", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-live.json"

# Orphaned pack dir + orphaned request file: no manifest, no spool envelope.
mkdir -p "$rt/packs/j-orphan"
echo x > "$rt/packs/j-orphan/dummy"
echo '{}' > "$rt/requests/j-orphan2.json"

# Pack with a PENDING spool envelope (no manifest, but a spool file exists):
# must survive — "no manifest" alone is not sufficient to call it orphaned.
mkdir -p "$rt/packs/j-pending"
echo '{"job_id":"j-pending"}' > "$rt/spool/j-pending.json"

gc_out="$("$ORCHID_BIN" jobs gc --older-than-s 86400)"
assert_match "^gc j-dead$" "$gc_out" "gc reaps the dead+old job"
assert_match "gc-orphan .*j-orphan" "$gc_out" "gc reaps orphan pack dir"
assert_match "gc-orphan .*j-orphan2" "$gc_out" "gc reaps orphan request file"
echo "$gc_out" | grep -q "j-young-dead" && fail "gc must not touch the dead-but-young manifest"
echo "$gc_out" | grep -q "j-live" && fail "gc must not touch the live-pid manifest"
echo "$gc_out" | grep -q "j-pending" && fail "gc must not touch a pack with a pending spool envelope"

[ ! -f "$rt/jobs/j-dead.json" ] || fail "gc: dead manifest removed from jobs dir"
[ -f "$rt/quarantine/j-dead.json.reason-gc-dead" ] || fail "gc: dead manifest quarantined as .reason-gc-dead"
[ ! -d "$rt/packs/j-dead" ] || fail "gc: dead job's pack dir removed"
[ ! -f "$rt/requests/j-dead.json" ] || fail "gc: dead job's request file removed"
[ ! -f "$rt/logs/j-dead.log" ] || fail "gc: dead job's log removed"

[ -f "$rt/jobs/j-young-dead.json" ] || fail "gc: dead-but-young manifest must survive"
[ -f "$rt/jobs/j-live.json" ] || fail "gc: live-pid manifest must survive"
kill -0 "$live_pid" 2>/dev/null || fail "sanity: live pid still alive during assertions"

[ ! -d "$rt/packs/j-orphan" ] || fail "gc: orphan pack dir removed"
[ ! -f "$rt/requests/j-orphan2.json" ] || fail "gc: orphan request file removed"
[ -d "$rt/packs/j-pending" ] || fail "gc: pack with pending spool envelope must survive"

kill "$live_pid" 2>/dev/null || true
