#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
# v1-m2: `jobs prepare` resolves via resolve_role_available, which gates on
# discoverability + role eligibility (lib/roles.sh) -- "fake" must actually
# exist on the search path and declare the implementer role's required
# capabilities, or prepare now (correctly) refuses with exit 14.
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/fake"
# requires_binaries=jq below is just a representative populated value --
# the bash-3.2 empty-CSV/array quirk this key used to be needed to sidestep
# is fixed directly in lib/manifest.sh's _manifest_split_csv now (see its own
# header comment; tests/test_failover.sh's mk_engine drops this key entirely
# to demonstrate the fix).
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
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
mkdir -p "$rt/packs/j-e1-TDEAD-a1-dead0001"
echo '{}' > "$rt/requests/j-e1-TDEAD-a1-dead0001.json"
echo dead-log > "$rt/logs/j-dead.log"
jq -n --argjson pid "$dead_pid" --argjson started "$old_started" --arg log "$rt/logs/j-dead.log" \
  '{job_id:"j-e1-TDEAD-a1-dead0001", task:"TDEAD", attempt:1, role:"implementer", operation:"implement",
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
assert_match "^gc j-e1-TDEAD-a1-dead0001$" "$gc_out" "gc reaps the dead+old job"
assert_match "gc-orphan .*j-orphan" "$gc_out" "gc reaps orphan pack dir"
assert_match "gc-orphan .*j-orphan2" "$gc_out" "gc reaps orphan request file"
echo "$gc_out" | grep -q "j-young-dead" && fail "gc must not touch the dead-but-young manifest"
echo "$gc_out" | grep -q "j-live" && fail "gc must not touch the live-pid manifest"
echo "$gc_out" | grep -q "j-pending" && fail "gc must not touch a pack with a pending spool envelope"

[ ! -f "$rt/jobs/j-dead.json" ] || fail "gc: dead manifest removed from jobs dir"
[ -f "$rt/quarantine/j-dead.json.reason-gc-dead" ] || fail "gc: dead manifest quarantined as .reason-gc-dead"
[ ! -d "$rt/packs/j-e1-TDEAD-a1-dead0001" ] || fail "gc: dead job's pack dir removed"
[ ! -f "$rt/requests/j-e1-TDEAD-a1-dead0001.json" ] || fail "gc: dead job's request file removed"
[ ! -f "$rt/logs/j-dead.log" ] || fail "gc: dead job's log removed"

[ -f "$rt/jobs/j-young-dead.json" ] || fail "gc: dead-but-young manifest must survive"
[ -f "$rt/jobs/j-live.json" ] || fail "gc: live-pid manifest must survive"
kill -0 "$live_pid" 2>/dev/null || fail "sanity: live pid still alive during assertions"

[ ! -d "$rt/packs/j-orphan" ] || fail "gc: orphan pack dir removed"
[ ! -f "$rt/requests/j-orphan2.json" ] || fail "gc: orphan request file removed"
[ -d "$rt/packs/j-pending" ] || fail "gc: pack with pending spool envelope must survive"

kill "$live_pid" 2>/dev/null || true

# ---------------------------------------------------------------------------
# T022: A DEAD JOB WHOSE ENVELOPE IS STILL IN THE SPOOL HAS DELIVERED, and its
# manifest is the only thing that can prove which job that envelope belongs to.
# `reconcile` and this reap run in the same driver pass, in that order, so a
# job that exits BETWEEN them is dead here with its envelope written and not
# yet drained. Reaping the manifest then destroys the delivery: reconcile
# matches an envelope to its job THROUGH the manifest, so the next pass finds
# none and quarantines the envelope as `unknown-job` — the engine's own report
# is lost, and the driver's escalation sweep counts the job as one that died
# without an envelope, spending a rung on work that actually arrived.
#
# Age and deadness are exactly the same as the reaped fixture above; only the
# pending spool entry differs. The second half is the one that keeps this a
# DEFERRAL rather than an exemption: with the envelope drained, the very same
# manifest is reaped as before.
#
# The job_id's trailing field must be HEX, exactly as `jobs prepare` mints it:
# gc validates the whole id against `j-e<n>-<task>-a<n>-<hex>` BEFORE it looks
# at the spool, and a non-hex suffix is quarantined as `.reason-gc-suspect` on
# the way past — the hold-back below is then never reached and every assertion
# in this block fails for a reason that has nothing to do with the hold-back.
# That ordering is deliberate and must stay: the hold-back keys an existence
# probe on `<spool>/<job_id>.json`, which may not be built from an unvalidated
# id. Keep the suffix in [0-9a-f], as every other fixture here does.
# ---------------------------------------------------------------------------
( exit 0 ) & pend_pid=$!
wait "$pend_pid" 2>/dev/null || true
mkdir -p "$rt/packs/j-e1-TPEND-a1-feed0001"
echo '{}' > "$rt/requests/j-e1-TPEND-a1-feed0001.json"
echo pend-log > "$rt/logs/j-pend.log"
jq -n --argjson pid "$pend_pid" --argjson started "$old_started" --arg log "$rt/logs/j-pend.log" \
  --arg out "$rt/spool/j-e1-TPEND-a1-feed0001.json" \
  '{job_id:"j-e1-TPEND-a1-feed0001", task:"TPEND", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:$out,
    base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-pend.json"
echo '{"contract":1,"job_id":"j-e1-TPEND-a1-feed0001","task":"TPEND","operation":"implement","status":"ok"}' \
  > "$rt/spool/j-e1-TPEND-a1-feed0001.json"

pend_out="$("$ORCHID_BIN" jobs gc --older-than-s 86400)"
assert_match "gc-pending j-e1-TPEND-a1-feed0001" "$pend_out" \
  "gc names the manifest it is holding back, and why"
echo "$pend_out" | grep -q "^gc j-e1-TPEND-a1-feed0001$" \
  && fail "gc must not reap a dead job whose envelope is still pending in the spool"
[ -f "$rt/jobs/j-pend.json" ] \
  || fail "gc: the manifest a pending envelope still needs must survive — without it reconcile can only quarantine that envelope as unknown-job"
[ ! -f "$rt/quarantine/j-pend.json.reason-gc-dead" ] \
  || fail "gc: nor may it be quarantined out from under the envelope"
[ -f "$rt/spool/j-e1-TPEND-a1-feed0001.json" ] || fail "gc: the pending envelope itself must be untouched"
[ -d "$rt/packs/j-e1-TPEND-a1-feed0001" ] || fail "gc: nor may the pack the envelope's job was built from be reaped"
[ -f "$rt/requests/j-e1-TPEND-a1-feed0001.json" ] || fail "gc: nor its request document"

# Drained (what reconcile does with it): the hold is released and the ordinary
# dead-job reap applies, unchanged.
rm -f "$rt/spool/j-e1-TPEND-a1-feed0001.json"
pend_out2="$("$ORCHID_BIN" jobs gc --older-than-s 86400)"
assert_match "^gc j-e1-TPEND-a1-feed0001$" "$pend_out2" \
  "once nothing is waiting on it, the same manifest is reaped exactly as before"
[ ! -f "$rt/jobs/j-pend.json" ] || fail "gc: drained manifest removed from jobs dir"
[ -f "$rt/quarantine/j-pend.json.reason-gc-dead" ] || fail "gc: drained manifest quarantined as .reason-gc-dead"

# ---------------------------------------------------------------------------
# v0b2: gc must validate manifest-derived paths before removal. job_id and
# log come straight from manifest JSON content with no validation — a
# corrupted or hand-edited manifest could carry a job_id with `../` or a log
# path pointing outside runtime/, steering gc's rm -rf at an arbitrary file.
# A suspect manifest must be left alone (quarantined as `.reason-gc-suspect`
# so it surfaces) rather than reaped, and nothing it points at may be
# touched.
# ---------------------------------------------------------------------------
decoy="$WORK/decoy-outside-runtime.txt"
echo decoy-contents > "$decoy"

hostile_started=$(( now - 90000 ))
( exit 0 ) & hostile_pid=$!
wait "$hostile_pid" 2>/dev/null || true
jq -n --argjson pid "$hostile_pid" --argjson started "$hostile_started" --arg log "$decoy" \
  '{job_id:"../../../../etc/j-evil", task:"THOSTILE", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-hostile.json"

hostile_out="$("$ORCHID_BIN" jobs gc --older-than-s 86400)"
assert_match "^gc-skip j-hostile\.json \(suspect fields\)$" "$hostile_out" "gc skips the hostile manifest"
echo "$hostile_out" | grep -Eq "^gc (\.\.|/)" && fail "gc must never echo a reaped path-traversal job_id"

[ -f "$decoy" ] || fail "gc: decoy file outside runtime must survive"
[ "$(cat "$decoy")" = "decoy-contents" ] || fail "gc: decoy file contents must be untouched"
[ ! -f "$rt/jobs/j-hostile.json" ] || fail "gc: hostile manifest removed from jobs dir (quarantined)"
[ -f "$rt/quarantine/j-hostile.json.reason-gc-suspect" ] || fail "gc: hostile manifest quarantined as .reason-gc-suspect"

# ---------------------------------------------------------------------------
# v1-m4 Task 2 (the pid-0 ghost incident): `jobs gc --reap-prepared
# [--older-than-s N]` (default 3600) is a SEPARATE mode targeting EXACTLY
# the pid==0 "prepared, never launched" manifests -- e.g. `orchid-launch`
# dying between `jobs prepare` and the actual spawn -- that plain `gc` (no
# flag) deliberately skips outright (see the `[ "$pid" != 0 ] || continue`
# line above), and which otherwise sat forever, re-reported as `prepared` by
# every `jobs check` pass. Age is measured off the manifest FILE's own
# mtime, since `started_at` is always 0 for a never-launched manifest.
# ---------------------------------------------------------------------------
mkdir -p "$rt/jobs"

# A genuinely old, never-launched manifest: must be reaped as gc-prepared.
jq -n '{job_id:"j-e1-TPREP-a1-aaaa0001", task:"TPREP", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-old.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-old.json"
touch -t 202001010000 "$rt/jobs/j-prep-old.json"   # ancient mtime

# A young, never-launched manifest: must survive (age gates it, just like
# the dead-job reap above).
jq -n '{job_id:"j-e1-TPREPYOUNG-a1-bbbb0001", task:"TPREPYOUNG", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-young.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-young.json"

# Plain gc (no --reap-prepared) must still skip BOTH pid-0 manifests outright
# -- unchanged existing behavior.
plain_gc_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
echo "$plain_gc_out" | grep -q "j-prep-old\|TPREP" && fail "plain gc must never touch a pid==0 (prepared) manifest, old or young"
[ -f "$rt/jobs/j-prep-old.json" ] || fail "plain gc must not remove the old prepared manifest"

reap_out="$("$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 60)"
assert_match "^gc-prepared j-e1-TPREP-a1-aaaa0001$" "$reap_out" "gc --reap-prepared reaps the old never-launched manifest"
echo "$reap_out" | grep -q "TPREPYOUNG" && fail "gc --reap-prepared must not touch the young prepared manifest"
[ ! -f "$rt/jobs/j-prep-old.json" ] || fail "gc --reap-prepared: old prepared manifest removed from jobs dir"
[ -f "$rt/quarantine/j-prep-old.json.reason-gc-prepared" ] || fail "gc --reap-prepared: quarantined as .reason-gc-prepared"
[ -f "$rt/jobs/j-prep-young.json" ] || fail "gc --reap-prepared: young prepared manifest must survive"

# --reap-prepared's own suspect-fields validation (same discipline as the
# ordinary dead-job reap): a hand-edited/corrupt job_id must never be reaped
# -- quarantined as gc-suspect instead, and nothing on disk touched.
jq -n '{job_id:"../../../../etc/j-evil-prep", task:"THOSTILEPREP", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"/nonexistent.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-hostile-prep.json"
touch -t 202001010000 "$rt/jobs/j-hostile-prep.json"

hostile_prep_out="$("$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 60)"
assert_match "^gc-skip j-hostile-prep\.json \(suspect fields\)$" "$hostile_prep_out" "gc --reap-prepared skips a hostile job_id"
[ ! -f "$rt/jobs/j-hostile-prep.json" ] || fail "gc --reap-prepared: hostile prepared manifest removed from jobs dir (quarantined)"
[ -f "$rt/quarantine/j-hostile-prep.json.reason-gc-suspect" ] || fail "gc --reap-prepared: hostile manifest quarantined as .reason-gc-suspect"

# --older-than-s defaults to 3600 under --reap-prepared (distinct from plain
# gc's 86400 default): a manifest just past 3600s old is reaped with no
# --older-than-s given at all.
jq -n '{job_id:"j-e1-TPREPDEF-a1-def00001", task:"TPREPDEF", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-def.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-def.json"
touch -t 202001010000 "$rt/jobs/j-prep-def.json"

default_reap_out="$("$ORCHID_BIN" jobs gc --reap-prepared)"
assert_match "^gc-prepared j-e1-TPREPDEF-a1-def00001$" "$default_reap_out" "gc --reap-prepared's --older-than-s defaults to 3600"

# ---------------------------------------------------------------------------
# v0b2: `jobs check` ALSO reads the task's `started_at` + `wallclock_budget_s`
# from frontmatter, independent of the job/pid's own liveness, and prints
# `<task>\tbudget-exceeded` once exceeded. This is a report only — `jobs
# check` never kills for a wall-clock overrun; the orchestrator escalates it
# via protocol (`task advance ... blocked`).
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TBUDGET "budget-demo"
"$ORCHID_BIN" task advance TBUDGET implementing
"$ORCHID_BIN" task set TBUDGET started_at "2000-01-01T00:00:00Z"
"$ORCHID_BIN" task set TBUDGET wallclock_budget_s 1
"$ORCHID_BIN" jobs prepare TBUDGET implementer implement >/dev/null
budget_out="$("$ORCHID_BIN" jobs check)"
assert_match "TBUDGET	budget-exceeded" "$budget_out" "jobs check reports budget-exceeded for an over-budget task"

# A task well within budget must never be reported over.
"$ORCHID_BIN" task create TOKBUDGET "budget-ok-demo"
"$ORCHID_BIN" task advance TOKBUDGET implementing
"$ORCHID_BIN" task set TOKBUDGET wallclock_budget_s 28800
"$ORCHID_BIN" jobs prepare TOKBUDGET implementer implement >/dev/null
ok_out="$("$ORCHID_BIN" jobs check)"
echo "$ok_out" | grep -q "TOKBUDGET	budget-exceeded" && fail "jobs check must not report budget-exceeded for a task within budget"

# ---------------------------------------------------------------------------
# T020: `wallclock_budget_s` bounds the current ATTEMPT, not calendar time
# since the task's first dispatch. Three properties, in the order they bit
# real runs. (`ORCHID_CONCURRENCY` because TBUDGET and TOKBUDGET above are
# still parked in `implementing` and would otherwise trip the cap of 2 --
# scheduling is tested in tests/test_dispatcher.sh, not here.)
#
#   1. A task idle across a long wall-clock gap is NOT reported over budget:
#      the re-dispatch that ends the idle re-anchors `started_at`, so hours
#      spent parked are not charged to the attempt about to run. r-001's
#      T013 was blocked exactly that way -- an eleven-hour-old task-level
#      anchor, a three-minute-old job, a candidate that had verified clean.
#   2. Nothing is reported for a task PARKED in rework by `task retry`: the
#      operator's own recovery verb used to hand the task back to a `jobs
#      check` that re-blocked it on the very next pass, burning one
#      implementer dispatch per cycle without ever converging (the webBooks
#      run's lesson L006).
#   3. An attempt that genuinely blows its budget IS still reported, and
#      deliberately so even while its job is ALIVE -- that is the runaway
#      attempt this backstop exists to catch. Once per task, not once per
#      manifest.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TIDLE "idle-across-a-long-gap"
ORCHID_CONCURRENCY=8 "$ORCHID_BIN" task advance TIDLE implementing
"$ORCHID_BIN" task set TIDLE wallclock_budget_s 60
# Stands in for an attempt dispatched long ago and then parked: the anchor is
# ancient, the task's own work is not.
"$ORCHID_BIN" task set TIDLE started_at "2000-01-01T00:00:00Z"
"$ORCHID_BIN" jobs prepare TIDLE implementer implement >/dev/null
assert_match "TIDLE[[:space:]]budget-exceeded" "$("$ORCHID_BIN" jobs check)" \
  "an ACTIVE task past its anchor is reported (the stale anchor was the defect, not the report)"

"$ORCHID_BIN" task advance TIDLE blocked --reason "parked overnight"
"$ORCHID_BIN" task retry TIDLE --reason "operator resumed it"
assert_eq rework "$("$ORCHID_BIN" task show TIDLE | grep '^status: ' | cut -d' ' -f2)" "retry parks TIDLE in rework"
retry_out="$("$ORCHID_BIN" jobs check)"
echo "$retry_out" | grep -q "TIDLE	budget-exceeded" \
  && fail "a task parked in rework has no attempt in flight — jobs check must not report a budget for it (the unconvergent retry loop)"

ORCHID_CONCURRENCY=8 "$ORCHID_BIN" task advance TIDLE implementing
idle_started="$("$ORCHID_BIN" task show TIDLE | grep '^started_at: ' | cut -d' ' -f2-)"
[ "$idle_started" != "2000-01-01T00:00:00Z" ] \
  || fail "re-dispatch after the idle gap must RE-anchor started_at, not keep the first attempt's"
idle_out="$("$ORCHID_BIN" jobs check)"
echo "$idle_out" | grep -q "TIDLE	budget-exceeded" \
  && fail "a task re-dispatched after a long idle gap must not be over budget on its FIRST second of work"

# A genuine overrun: this attempt's own anchor (no hand-set started_at at
# all), a one-second budget, and more than a second of elapsed attempt.
"$ORCHID_BIN" task create TRUNAWAY "attempt-genuinely-over-budget"
ORCHID_CONCURRENCY=8 "$ORCHID_BIN" task advance TRUNAWAY implementing
"$ORCHID_BIN" task set TRUNAWAY wallclock_budget_s 1
sleep 100 &
runaway_pid=$!
jq -n --argjson pid "$runaway_pid" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TRUNAWAY-a1-run00001", task:"TRUNAWAY", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:"/nonexistent.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-runaway.json"
# A second, concurrent manifest for the SAME task — the shape a real task
# carries whenever more than one job is outstanding for it (implementer plus
# one manifest per reviewer slot). The budget is a task-level fact, so it
# must be reported once per pass, not once per manifest.
"$ORCHID_BIN" jobs prepare TRUNAWAY implementer implement >/dev/null
sleep 2
kill -0 "$runaway_pid" 2>/dev/null || fail "fixture: the runaway job's pid must still be alive at check time"
# timeout_minutes is 0 in this fixture's config (set far above, for the pgid
# guard); overridden here only so the live job reports `running` rather than
# being killed as a timeout — the point of this case is the LIVE arm.
runaway_out="$(ORCHID_TIMEOUT_MINUTES=60 "$ORCHID_BIN" jobs check)"
assert_match "TRUNAWAY[[:space:]]running" "$runaway_out" "the runaway attempt's job is alive at check time"
assert_match "TRUNAWAY[[:space:]]budget-exceeded" "$runaway_out" \
  "an attempt genuinely past its own budget is reported even though its job is alive"
runaway_n="$(grep -cE "TRUNAWAY[[:space:]]budget-exceeded" <<<"$runaway_out" || true)"
assert_eq 1 "$runaway_n" "budget-exceeded is reported once per task, not once per manifest"
kill "$runaway_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-runaway.json"

# ---------------------------------------------------------------------------
# v1-m3: plan-scoped critique jobs -- `orchid jobs prepare plan <role>
# critique` mints a manifest with NO task file read at all (`plan` is a
# reserved task id; `orchid task create` refuses it -- tests/test_task.sh).
# attempt is 1 + however many `reviews/plan-a*-<role>.json` already exist;
# base/candidate stay empty (a plan pack has no diff to bind to). A stub
# plan_critic engine's envelope reconciles to `reviews/plan-a1-
# plan_critic.json` via the exact same counter-suffix naming any other
# task's review uses.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/eng/critic"
printf 'manifest_version=1\nid=test/critic\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/critic/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/critic/run"; chmod +x "$WORK/eng/critic/run"
printf 'role.plan_critic=critic\n' >> orchid.config

mp="$("$ORCHID_BIN" jobs prepare plan plan_critic critique)"
[ -f "$mp" ] || fail "plan-scoped manifest written at printed path"
assert_eq "plan" "$(jq -r .task "$mp")" "plan job task is the literal reserved id"
assert_eq "1" "$(jq -r .attempt "$mp")" "plan job first attempt is 1 (no prior reviews)"
assert_eq "" "$(jq -r .base_sha "$mp")" "plan job base_sha empty"
assert_eq "" "$(jq -r .candidate_sha "$mp")" "plan job candidate_sha empty"
plan_jid="$(jq -r .job_id "$mp")"
assert_match "^j-e[0-9]+-plan-a1-" "$plan_jid" "plan job id shape"

plan_out="$(jq -r .output "$mp")"
printf '{"contract":1,"job_id":"%s","task":"plan","operation":"critique","status":"ok","verdict":"request-changes","scope_complete":true,"findings":[{"severity":"medium","title":"missing rollback plan"}]}' "$plan_jid" > "$plan_out"
plan_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "plan	ok" "$plan_line" "plan critique envelope reconciled"
[ -f ".orchid/reviews/plan-a1-plan_critic.json" ] || fail "plan critique envelope filed at plan-a1-plan_critic.json"
[ ! -f "$mp" ] || fail "plan manifest deleted after reconcile"
assert_eq "1" "$(jq '.findings | length' ".orchid/reviews/plan-a1-plan_critic.json")" "plan critique envelope keeps its findings[]"

# A second prepare call after the first attempt's envelope has landed counts
# the existing reviews/plan-a1-plan_critic.json and bumps to attempt 2.
mp2="$("$ORCHID_BIN" jobs prepare plan plan_critic critique)"
assert_eq "2" "$(jq -r .attempt "$mp2")" "plan job second attempt counts the prior reconciled envelope"

# ---------------------------------------------------------------------------
# v1-m3 final review (IMPORTANT 4): plan-scoped HOOK attempt counting. A
# plan-scoped hook job's role positional is the literal "hook" (the
# Preamble's launch shape: the role positional carries no meaning for a hook
# job), but reconcile files its envelope as reviews/plan-a<n>-hook-<point>.json
# (hook-point-aware, since role never appears in a hook filename) -- never
# reviews/plan-a<n>-hook.json. `jobs prepare`'s attempt-counting glob for
# `task=plan` used to glob on `plan-a*-$role.json` regardless of operation,
# i.e. `plan-a*-hook.json` for a hook job, which never matches anything a
# prior plan-hook attempt actually landed -- every plan hook attempt was
# silently stuck at attempt 1 forever (this test is the regression guard).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/eng/planhook"
printf 'manifest_version=1\nid=test/planhook\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$WORK/eng/planhook/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/planhook/run"; chmod +x "$WORK/eng/planhook/run"
printf 'hook.after_plan_draft=planhook\n' >> orchid.config

mph1="$("$ORCHID_BIN" jobs prepare plan hook hook --hook after_plan_draft)"
assert_eq "1" "$(jq -r .attempt "$mph1")" "plan hook job first attempt is 1 (no prior reviews)"
mph1_jid="$(jq -r .job_id "$mph1")"; mph1_out="$(jq -r .output "$mph1")"
printf '{"contract":1,"job_id":"%s","task":"plan","operation":"hook","status":"ok","artifact":{},"summary":"draft looks fine"}' \
  "$mph1_jid" > "$mph1_out"
mph1_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "plan	ok" "$mph1_line" "plan hook envelope reconciled"
[ -f ".orchid/reviews/plan-a1-hook-after_plan_draft.json" ] \
  || fail "plan hook envelope filed at plan-a1-hook-after_plan_draft.json"

mph2="$("$ORCHID_BIN" jobs prepare plan hook hook --hook after_plan_draft)"
assert_eq "2" "$(jq -r .attempt "$mph2")" \
  "second plan-hook prepare counts the prior reconciled envelope (regression: used to stay stuck at 1)"
