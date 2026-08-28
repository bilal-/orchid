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
# T027 (dogfood F29): a pid-0 manifest with NO LOG never reached the launcher's
# spawn line, so no engine ran and none ever will. `jobs check` used to call
# that `prepared` — indistinguishable from "queued and fine", which is how 73
# of them stayed invisible for a whole run. It is `never-started`; `prepared`
# now means only the genuine post-spawn/pre-stamp window, which a log proves.
assert_match "T001	never-started" "$("$ORCHID_BIN" jobs check)" \
  "a pid-0 manifest with no log is reported never-started, not prepared"
m_log="$(jq -r .log "$m")"
mkdir -p "$(dirname "$m_log")"; : > "$m_log"
assert_match "T001	prepared" "$("$ORCHID_BIN" jobs check)" \
  "the same manifest WITH a log is the real prepared window (spawned, pid not yet stamped)"
rm -f "$m_log"

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
# DISOWNED, so the shell stops REPORTING this job. `jobs check` is about to
# kill it -- that is the whole point of the case -- and bash then announces the
# reap on stderr as `tests/test_jobs.sh: line N: <pid> Terminated: 15 sleep
# 100`. That line has the exact `file: line N:` shape lib/findings.sh carries
# into a rework brief, so a suite that is passing hands the next implementer
# three fabricated locations to "fix" and displaces the real ones (it did
# exactly that to T018). Disowning changes nothing this fixture asserts: the
# pid stays in `$spid`, and `kill`/`kill -0` address a pid, never a job spec.
#
# Guarded, and the guard is the portable part rather than a shrug. `disown`
# takes a JOBSPEC on bash 3.2 (the floor this suite runs on), not a pid, so the
# bare form is the only spelling available -- and a bare `disown` that finds no
# current job both exits non-zero and prints `disown: current: no such job`,
# which would be a NEW stderr line of exactly the shape this is removing.
# Nothing is made fail-open by it: the entire effect of this line is what
# stderr says.
disown 2>/dev/null || true
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
disown 2>/dev/null || true  # as at the pgid guard above: a reaped job's notice is not a finding
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
# The pid-0 ghost incident, in two rounds.
#
# v1-m4 Task 2 added `jobs gc --reap-prepared [--older-than-s N]` (default
# 3600) as a SEPARATE mode targeting EXACTLY the pid==0 "prepared, never
# launched" manifests -- e.g. `orchid-launch` dying between `jobs prepare` and
# the actual spawn. T027 (dogfood F29) makes ORDINARY `gc` reap them too: a
# whole run's worth of them survived `orchid jobs gc --older-than-s 0` -- the
# call the driver itself makes and the first one an operator reaches for -- and
# 74 files were deleted by hand.
#
# SCOPE, STATED ONCE FOR EVERY CASE BELOW: the class being reaped here is the
# pid-0 one, and that is the class the parent skipped outright
# (`[ "$pid" != 0 ] || continue`). The dead-pid class was never skipped there
# and is not fixed by any of this -- see the block much further down that says
# so, and `bash tests/probes/probe-t027-parent-red.sh <base_sha>`, which runs
# both classes through the parent's own binary and this one's.
#
# Age is measured off the manifest FILE's own mtime for both modes, since
# `started_at` is always 0 for a never-launched manifest. EVERY BOUND IS TAKEN
# LITERALLY -- there is no floor hidden inside the verb (T027 rework; the F41
# report is that same operator typing `--older-than-s 0` at a manifest they had
# already identified by hand and being quietly given something else). The
# margin an unattended sweep needs, for a launcher that may be mid-flight
# between its own `prepare` and its spawn line, is a SEPARATE bound its caller
# passes: `--prepared-older-than-s`, pinned in both directions below.
# ---------------------------------------------------------------------------
mkdir -p "$rt/jobs"
printf 'stall_minutes=1\n' >> orchid.config   # a 60s bound the fixtures straddle

# A genuinely old, never-launched manifest: must be reaped as gc-prepared.
jq -n '{job_id:"j-e1-TPREP-a1-aaaa0001", task:"TPREP", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-old.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-old.json"
touch -t 202001010000 "$rt/jobs/j-prep-old.json"   # ancient mtime

# A young, never-launched manifest: 30 seconds old, i.e. strictly INSIDE the
# 60s `stall_minutes` window this fixture sets. That window is the whole point
# of the pair below -- one bound must spare it and another must reap it -- so
# the age has to be neither 0 nor ancient, which no `touch -t` literal can be.
# BSD/macOS `date -v` first, GNU `date -d` as the fallback, exactly the split
# lib/common.sh's own timestamp parsing already carries; LOCAL time in both,
# because that is what `touch -t` reads.
#
# The two assertions that use it are each other's guard: if this ageing
# silently did nothing the manifest is 0s old and the `--older-than-s 0` call
# spares it, and if it aged too far the `--prepared-older-than-s 60` call reaps
# it. Either way a `fail` fires -- the window cannot quietly collapse and leave
# the pair vacuous.
back30="$(date -v-30S +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 seconds ago' +%Y%m%d%H%M.%S)"
jq -n '{job_id:"j-e1-TPREPYOUNG-a1-bbbb0001", task:"TPREPYOUNG", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-young.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-young.json"
touch -t "$back30" "$rt/jobs/j-prep-young.json"

# A LARGER bound holds both back: an operator asking for more retention gets
# it, on this class too.
long_gc_out="$("$ORCHID_BIN" jobs gc --older-than-s 999999999)"
# Herestring, never `echo | grep -q`: same SIGPIPE/pipefail trap helpers.sh
# documents for assert_match — a matching grep exiting early would poison the
# pipeline status and silently skip the `fail`. Same for every negative
# assertion below.
grep -q "TPREP" <<<"$long_gc_out" && fail "a large --older-than-s must still hold the prepared manifest back"
[ -f "$rt/jobs/j-prep-old.json" ] || fail "a large --older-than-s must not reap the old prepared manifest"

# THE SEPARATE BOUND, which is where the unattended sweep's margin lives. The
# driver passes its own `stall_minutes` here precisely because it cannot know
# whether a launcher is mid-flight; the aged manifest is past it and goes, the
# young one is not and stays.
split_gc_out="$("$ORCHID_BIN" jobs gc --older-than-s 0 --prepared-older-than-s 60)"
assert_match "^gc-prepared j-e1-TPREP-a1-aaaa0001$" "$split_gc_out" \
  "plain gc reaps an aged never-launched manifest (T027: it used to skip every pid==0 manifest outright)"
grep -q "TPREPYOUNG" <<<"$split_gc_out" && fail "--prepared-older-than-s must hold back a manifest younger than the bound the caller passed"
[ ! -f "$rt/jobs/j-prep-old.json" ] || fail "plain gc: the aged prepared manifest must leave the jobs dir"
[ -f "$rt/quarantine/j-prep-old.json.reason-gc-prepared" ] || fail "plain gc: quarantined as .reason-gc-prepared"
[ -f "$rt/jobs/j-prep-young.json" ] || fail "plain gc: the young prepared manifest must survive its caller's bound"

# ...AND THE ZERO THE OPERATOR TYPED IS THE ZERO THEY GET (dogfood F41). No
# --prepared-older-than-s, so the one bound given applies to everything: the
# SAME young manifest the call above deliberately spared is reaped by this one,
# with no age of any kind standing between the operator and a manifest they
# have already identified as an orphan.
#
# RED twice over, for two different reasons, which is worth keeping straight:
# at the PARENT this call printed nothing because ordinary gc skipped every
# pid-0 manifest outright; at an earlier T027 attempt it printed nothing
# because the verb silently raised the 0 the caller typed to `stall_minutes`.
# The parent half is the dogfood defect -- what sent that operator to `rm` for
# the second run running -- and is the one the probe's `gc-zero-never-started`
# row proves; the second is a self-inflicted regression this rework removed,
# and only this file ever saw it.
zero_gc_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
assert_match "^gc-prepared j-e1-TPREPYOUNG-a1-bbbb0001$" "$zero_gc_out" \
  "an explicit --older-than-s 0 honours zero on a known pid-0/no-log orphan"
[ ! -f "$rt/jobs/j-prep-young.json" ] || fail "gc --older-than-s 0: the orphan the operator asked to clear must be gone"

# The explicit mode, on its own aged fixture -- plus a fresh young one, since
# the zero-bound call above cleared the first (that is what it is there to
# prove) and this block needs an un-aged manifest of its own to spare.
jq -n '{job_id:"j-e1-TPREPX-a1-aaaa0002", task:"TPREPX", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-x.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-x.json"
touch -t 202001010000 "$rt/jobs/j-prep-x.json"
jq -n '{job_id:"j-e1-TPREPYOUNG-a1-bbbb0001", task:"TPREPYOUNG", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-young.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-young.json"

reap_out="$("$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 60)"
assert_match "^gc-prepared j-e1-TPREPX-a1-aaaa0002$" "$reap_out" "gc --reap-prepared reaps the old never-launched manifest"
grep -q "TPREPYOUNG" <<<"$reap_out" && fail "gc --reap-prepared must not touch the young prepared manifest"
[ ! -f "$rt/jobs/j-prep-x.json" ] || fail "gc --reap-prepared: old prepared manifest removed from jobs dir"
[ -f "$rt/quarantine/j-prep-x.json.reason-gc-prepared" ] || fail "gc --reap-prepared: quarantined as .reason-gc-prepared"
[ -f "$rt/jobs/j-prep-young.json" ] || fail "gc --reap-prepared: young prepared manifest must survive"

# ...AND `--prepared-older-than-s` MEANS SOMETHING IN THIS MODE TOO. It was
# parsed here and then dropped on the floor: a caller naming the bound for the
# only class this mode touches was silently given `--older-than-s`, or the 3600
# default. That is the F41 defect one level up -- a bound typed and ignored --
# so it is honoured, and being the more specific name for this class it wins.
#
# Both directions, because a flag that only ever reaps proves nothing: it must
# be able to hold a manifest back as well as let it go.
mk_prepared() {  # <file> <job-id> <task> -- an ancient never-launched manifest
  jq -n --arg jid "$2" --arg task "$3" --arg log "$rt/logs/$1.log" \
    '{job_id:$jid, task:$task, attempt:1, role:"implementer", operation:"implement",
      engine:"fake", pid:0, pgid:0, started_at:0, log:$log, output:"/dev/null",
      base_sha:"", candidate_sha:""}' > "$rt/jobs/$1.json"
  touch -t 202001010000 "$rt/jobs/$1.json"
}

mk_prepared j-prep-bound-a j-e1-TPREPBOUNDA-a1-cccc0001 TPREPBOUNDA
bound_reap_out="$("$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 999999999 --prepared-older-than-s 60)"
assert_match "^gc-prepared j-e1-TPREPBOUNDA-a1-cccc0001$" "$bound_reap_out" \
  "gc --reap-prepared honours --prepared-older-than-s, and the class-specific bound wins over --older-than-s"
[ ! -f "$rt/jobs/j-prep-bound-a.json" ] || fail "gc --reap-prepared: the manifest past --prepared-older-than-s must leave the jobs dir"

mk_prepared j-prep-bound-b j-e1-TPREPBOUNDB-a1-cccc0002 TPREPBOUNDB
bound_hold_out="$("$ORCHID_BIN" jobs gc --reap-prepared --prepared-older-than-s 999999999)"
grep -q "TPREPBOUNDB" <<<"$bound_hold_out" && fail "gc --reap-prepared: --prepared-older-than-s must be able to HOLD a manifest back, not only reap one — an ignored flag would fall through to the 3600 default and reap this ancient manifest"
[ -f "$rt/jobs/j-prep-bound-b.json" ] || fail "gc --reap-prepared: the manifest inside --prepared-older-than-s must survive"
# ...and it is a bound, not a permanent exemption. Cleared here so the jobs dir
# is left as this block found it -- at 3600, which the ancient manifest is past
# and the young one from the block above is not, so the cleanup takes exactly
# what it put there.
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 3600 >/dev/null
[ ! -f "$rt/jobs/j-prep-bound-b.json" ] || fail "gc --reap-prepared: a bound held back is not an exemption — the next call with a bound it passes takes it"
[ -f "$rt/jobs/j-prep-young.json" ] || fail "and the cleanup must not have taken the young manifest with it"

# ---------------------------------------------------------------------------
# ...and the manifest no bound may reap WHILE ITS LOG IS STILL BEING WRITTEN:
# pid 0 with a log.
#
# `pid == 0` alone cannot mean "safe to reap". The launcher creates the log by
# redirecting the engine into it and stamps the pid only on the line after, so
# a pid-0 manifest that HAS a log was spawned -- an engine may be running
# behind it right now with its pid recorded nowhere on disk. The manifest is
# the only handle on that process. Reaping it loses the handle AND clears the
# way for a second implementer in the same worktree, which is the exact
# duplicate-implementer defect the kernel already guards against.
#
# So: ancient manifest, ancient-looking everything, log written a moment ago --
# and both gc modes, at their most aggressive bound, must leave it alone.
#
# But NOT FOREVER (T027 rework). Retention on its own was never the answer to
# "an engine might be running": the driver read the same manifest as "no job"
# and relaunched over it anyway, so the duplicate happened and the manifest
# just accumulated. What ends it is the log going quiet for `stall_minutes` --
# the same silence `check` kills a stamped job for -- and the second half of
# this block is that convergence.
# ---------------------------------------------------------------------------
jq -n '{job_id:"j-e1-TLIVE-a1-cccc0001", task:"TLIVE", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-live.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-live.json"
mkdir -p "$rt/logs"; printf 'engine is running\n' > "$rt/logs/j-prep-live.log"
touch -t 202001010000 "$rt/jobs/j-prep-live.json"   # as old as a manifest gets

live_plain_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
grep -q "TLIVE\|j-prep-live" <<<"$live_plain_out" && fail "plain gc must never reap a pid-0 manifest that HAS a log — an engine may be running behind it"
[ -f "$rt/jobs/j-prep-live.json" ] || fail "plain gc: the log-backed manifest is the only handle on that process and must survive"
live_reap_out="$("$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0)"
grep -q "TLIVE\|j-prep-live" <<<"$live_reap_out" && fail "gc --reap-prepared must not reap a log-backed manifest either — it is the explicit mode, not a wider hammer"
[ -f "$rt/jobs/j-prep-live.json" ] || fail "gc --reap-prepared: the log-backed manifest must survive"
assert_match "TLIVE	prepared" "$("$ORCHID_BIN" jobs check)" \
  "and it keeps being REPORTED, so an operator can see what is being waited on"

# ...AND IT CONVERGES. Age the LOG past `stall_minutes` (60s here) and nothing
# has written a line for as long as `check` would kill a stamped job over. The
# report changes, and the manifest becomes reapable — the manifest itself is
# untouched, so the log's own mtime is doing all of the work.
#
# RED at the parent, precisely: `prepared` forever from `jobs check`, skipped
# by ordinary `gc` at every bound, while runners/orchid-drive read the same
# manifest as "no job" and launched a second engine over it on the very next
# pass. Not "reaped by nothing" -- the parent's `--reap-prepared` mode did
# reap it, on pid 0 alone and with no regard for whether its log was still
# growing, which is the opposite error and is why the two halves of the pid-0
# class are separated by the log here rather than merged.
touch -t 202001010000 "$rt/logs/j-prep-live.log"
assert_match "TLIVE	unstamped" "$("$ORCHID_BIN" jobs check)" \
  "a spawn that never stamped a pid and then went silent is reported unstamped, not prepared forever"
live_stale_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
assert_match "^gc-unstamped j-e1-TLIVE-a1-cccc0001$" "$live_stale_out" \
  "and gc retires it under its own reason, distinct from a job that never started at all"
[ ! -f "$rt/jobs/j-prep-live.json" ] || fail "the stale unstamped manifest must leave the jobs dir"
[ -f "$rt/quarantine/j-prep-live.json.reason-gc-unstamped" ] || fail "quarantined as .reason-gc-unstamped, not silently deleted"
# THE LOG SURVIVES, unlike the dead-job reap's. No pid was ever recorded, so
# nothing could be signalled: if an engine really is alive behind this manifest
# its output is the only evidence left, and the reap must not destroy it at the
# exact moment the handle goes away.
[ -f "$rt/logs/j-prep-live.log" ] \
  || fail "gc must keep an unstamped job's log — it is the only surviving record of whatever was spawned"

# The same shape with NO log at all is the other class, reported and reasoned
# about separately -- the log is the whole difference, in both verbs.
jq -n '{job_id:"j-e1-TLIVE-a1-cccc0002", task:"TLIVE", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-prep-nolog.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-prep-nolog.json"
touch -t 202001010000 "$rt/jobs/j-prep-nolog.json"   # past any bound; the log's absence is the subject here
assert_match "TLIVE	never-started" "$("$ORCHID_BIN" jobs check)" \
  "without the log it is a job that never started"
live_gone_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
assert_match "^gc-prepared j-e1-TLIVE-a1-cccc0002$" "$live_gone_out" \
  "and it is retired under the never-started reason"

# ---------------------------------------------------------------------------
# ...and the OTHER half of the operator's predicate: NOT A FIX. A REGRESSION
# TRIPWIRE, AND LABELLED AS ONE.
#
# The operator who deleted these by hand -- twice, on two separate runs --
# found them with one predicate: `pid == 0 || ! kill -0 <pid>`. Everything
# above is the first half of that `||`, and it is what T027 actually fixed.
# This is the second half: a job that DID launch and then died without ever
# filing an envelope.
#
# T027's acceptance criteria calls that "the same defect as F29" and asks for
# a RED case per shape. THERE IS NO RED CASE HERE TO WRITE. The parent commit
# already reaps this manifest on this exact call: ordinary `gc`'s dead-job arm
# takes `--older-than-s` literally there too, and the age it measures is
# `now - started_at`, which for a real launched job is seconds. Only the pid-0
# half was ever skipped (`[ "$pid" != 0 ] || continue`, right at the top of
# that loop). Whatever sent the operator back to `rm` a second time, it was
# not ordinary gc refusing to reap a dead pid.
#
# So this block asserts a behaviour the candidate INHERITED, which makes it a
# regression tripwire and nothing more -- kept, because `--older-than-s 0` is
# the one bound the incident is about and the one the driver hardcodes for the
# unlaunched class, so a future change putting a margin back under either class
# fails here first. Calling it a fix would have been the worse error: an
# invented defect, "proved" by an assertion that passes on the parent too and
# can therefore never fail.
#
# Checkable, not merely asserted: `bash tests/probes/probe-t027-parent-red.sh
# <base_sha>` runs this shape and the two pid-0 shapes through the parent's own
# binary and this checkout's, and its `gc-zero-dead-pid` row FAILS if this half
# is ever re-labelled as newly fixed (its `gc-zero-never-started` and
# `gc-zero-unstamped` rows are the RED proof for the half that is).
# ---------------------------------------------------------------------------
mkdir -p "$rt/packs/j-e1-TGONE-a1-dead0002"
echo '{}' > "$rt/requests/j-e1-TGONE-a1-dead0002.json"
echo gone-log > "$rt/logs/j-gone.log"
( exit 0 ) & gone_pid=$!
wait "$gone_pid" 2>/dev/null || true
jq -n --argjson pid "$gone_pid" --argjson started "$(( $(date +%s) - 5 ))" \
  --arg log "$rt/logs/j-gone.log" \
  '{job_id:"j-e1-TGONE-a1-dead0002", task:"TGONE", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-gone.json"

assert_match "TGONE	dead" "$("$ORCHID_BIN" jobs check)" \
  "a launched job whose pid is gone is reported dead — never-started is the other shape, not this one"
gone_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
assert_match "^gc j-e1-TGONE-a1-dead0002$" "$gone_out" \
  "gc --older-than-s 0 reaps a job that died without an envelope — INHERITED from the parent, not fixed here; this pins it against a future margin"
[ ! -f "$rt/jobs/j-gone.json" ] || fail "the dead manifest must leave the jobs dir"
[ -f "$rt/quarantine/j-gone.json.reason-gc-dead" ] || fail "and be quarantined as .reason-gc-dead, not silently deleted"
[ ! -d "$rt/packs/j-e1-TGONE-a1-dead0002" ] || fail "the dead job's pack dir goes with it"
[ ! -f "$rt/requests/j-e1-TGONE-a1-dead0002.json" ] || fail "the dead job's request file goes with it"
[ ! -f "$rt/logs/j-gone.log" ] || fail "the dead job's log goes with it"

# ---------------------------------------------------------------------------
# ...AND THE OPERATOR'S OWN PREDICATE, RUN AS THEY RAN IT, MUST COME BACK EMPTY.
#
# Every case above pins one shape against one call. This pins the thing the
# operator actually did: they swept `.orchid/runtime/jobs` with
# `pid == 0 || ! kill -0 <pid>`, found manifests, and deleted them by hand --
# on two separate runs, having first tried `orchid jobs gc --older-than-s 0`.
#
# So: seed one manifest of EVERY shape that predicate matches, make exactly
# that one call, and re-run their sweep. Anything it still finds is a file they
# would still be deleting by hand, whatever the per-shape assertions above say.
# A future shape nobody thought to write a case for fails here first.
#
# MIXED BY CONSTRUCTION, and that is the point of it: shapes (1) and (2) are
# what T027 fixed, shape (3) the parent already reaped (see the block above).
# This case is about the operator's END STATE -- an empty sweep -- which is a
# property of all three together and was not true before, because (1) and (2)
# survived. It is deliberately NOT evidence that any individual shape here was
# broken; the per-shape blocks above say which were, and
# tests/probes/probe-t027-parent-red.sh settles it against the parent's own
# binary rather than against a comment.
# ---------------------------------------------------------------------------
rm -f "$rt/jobs"/*.json          # clean slate: the sweep below must be exhaustive

# (1) never started -- pid 0, no log ever opened.
jq -n '{job_id:"j-e1-TF41A-a1-f41a0001", task:"TF41A", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-f41-a.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-f41-a.json"
touch -t 202001010000 "$rt/jobs/j-f41-a.json"

# (2) spawned, never stamped a pid, then silent -- pid 0 WITH a stale log.
jq -n '{job_id:"j-e1-TF41B-a1-f41b0001", task:"TF41B", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"'"$rt"'/logs/j-f41-b.log", output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-f41-b.json"
echo f41-b-log > "$rt/logs/j-f41-b.log"
touch -t 202001010000 "$rt/jobs/j-f41-b.json" "$rt/logs/j-f41-b.log"

# (3) launched and died without an envelope -- a pid that is gone. The
# INHERITED shape: present so the sweep is exhaustive over the operator's
# predicate, not because this half was ever broken.
echo f41-c-log > "$rt/logs/j-f41-c.log"
( exit 0 ) & f41_pid=$!
wait "$f41_pid" 2>/dev/null || true
jq -n --argjson pid "$f41_pid" --argjson started "$(( $(date +%s) - 5 ))" \
  --arg log "$rt/logs/j-f41-c.log" \
  '{job_id:"j-e1-TF41C-a1-f41c0001", task:"TF41C", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:""}' > "$rt/jobs/j-f41-c.json"

f41_before=0
for f41_m in "$rt/jobs"/*.json; do
  [ -e "$f41_m" ] || continue
  f41_before=$((f41_before + 1))
done
assert_eq 3 "$f41_before" "the sweep below really has all three shapes to clear"

"$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null

# THE OPERATOR'S SWEEP, verbatim in spirit: pid 0, or a pid nothing answers to.
f41_left=""
for f41_m in "$rt/jobs"/*.json; do
  [ -e "$f41_m" ] || continue
  f41_p="$(jq -r '.pid // 0' "$f41_m")"
  if [ "$f41_p" = 0 ] || ! kill -0 "$f41_p" 2>/dev/null; then
    f41_left="$f41_left $(basename "$f41_m")"
  fi
done
assert_eq "" "$f41_left" \
  "after ONE 'orchid jobs gc --older-than-s 0', the operator's own 'pid == 0 || ! kill -0' sweep finds nothing left to delete by hand (dogfood F29/F41)"

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
disown 2>/dev/null || true  # as at the pgid guard above: a reaped job's notice is not a finding
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
# Orphan by construction: nothing launches this one, and since T027 a second
# manifest for a slot that already holds a never-started one is refused
# outright (exit 18). Later blocks in this file prepare plan/plan_critic/
# critique again for this same attempt, so the fixture clears its own litter
# here rather than leaving them to trip over it.
rm -f "$mp2"

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
# Orphan by construction, cleared for the same reason $mp2 is above it.
rm -f "$mph2"

# ===========================================================================
# T035: `orchid jobs ls` -- the operator's process table for the run.
#
# What `status` could show while two jobs existed for one task was a task id
# and a state word (`T004 dead` / `T004 running`): not which job was which,
# nor its role, engine, attempt, start time, elapsed, or whether the dead one
# was a corpse already handled or a fresh failure needing escalation. Every
# field was already in the manifest, so this is a rendering gap. The two
# properties below are the ones that make it worth having.
# ===========================================================================

# ---------------------------------------------------------------------------
# (1) LIVENESS IS COMPUTED, NEVER READ (dogfood F29). A manifest records the
# pid its launcher stamped and nothing ever unstamps it, so a table that
# believes the file describes 73 never-launched jobs as 73 identical
# `prepared` lines -- which is exactly what happened, and the only way to find
# they were corpses was cat-ing manifests and noticing `pid: 0, started_at 0`.
# A stamped-live job, a stamped-dead job, and all three pid-0 shapes pin the
# operator table to the same liveness vocabulary as `jobs check`.
# ---------------------------------------------------------------------------
ls_now="$(date +%s)"
sleep 100 &
ls_live_pid=$!
echo running-log > "$rt/logs/j-ls-live.log"
jq -n --argjson pid "$ls_live_pid" --argjson st "$ls_now" --arg log "$rt/logs/j-ls-live.log" \
  '{job_id:"j-e1-TLS-a3-1111aaaa", task:"TLS", attempt:3, role:"reviewer", operation:"review",
    engine:"fake", pid:$pid, pgid:$pid, started_at:$st, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:"", launched_by:"drive"}' > "$rt/jobs/j-ls-live.json"

( exit 0 ) & ls_dead_pid=$!
wait "$ls_dead_pid" 2>/dev/null || true
echo dead-log > "$rt/logs/j-ls-dead.log"
touch -t 202001010000 "$rt/logs/j-ls-dead.log"   # last wrote long ago
jq -n --argjson pid "$ls_dead_pid" --argjson st "$(( ls_now - 45000 ))" \
  --arg log "$rt/logs/j-ls-dead.log" \
  '{job_id:"j-e1-TLS-a4-2222bbbb", task:"TLS", attempt:4, role:"plan_critic", operation:"critique",
    engine:"fake", pid:$pid, pgid:0, started_at:$st, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:"", launched_by:"pump"}' > "$rt/jobs/j-ls-dead.json"

jq -n '{job_id:"j-e1-TLS-a5-3333cccc", task:"TLS", attempt:5, role:"implementer", operation:"implement",
    engine:"fake", pid:0, pgid:0, started_at:0, log:"", output:"/dev/null",
    base_sha:"", candidate_sha:"", launched_by:"operator"}' > "$rt/jobs/j-ls-prep.json"
touch -t 202001010000 "$rt/jobs/j-ls-prep.json"   # prepared long ago, never launched

echo fresh-log > "$rt/logs/j-ls-prepared.log"
jq -n --arg log "$rt/logs/j-ls-prepared.log" \
  '{job_id:"j-e1-TLS-a6-4444dddd", task:"TLS", attempt:6, role:"reviewer", operation:"review",
    engine:"fake", pid:0, pgid:0, started_at:0, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:"", launched_by:"drive"}' > "$rt/jobs/j-ls-prepared.json"

echo stale-log > "$rt/logs/j-ls-unstamped.log"
touch -t 202001010000 "$rt/logs/j-ls-unstamped.log"
jq -n --arg log "$rt/logs/j-ls-unstamped.log" \
  '{job_id:"j-e1-TLS-a7-7777aaaa", task:"TLS", attempt:7, role:"reviewer", operation:"review",
    engine:"fake", pid:0, pgid:0, started_at:0, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:"", launched_by:"pump"}' > "$rt/jobs/j-ls-unstamped.json"

ls_out="$("$ORCHID_BIN" jobs ls 2>/dev/null)"
assert_match "^JOB[[:space:]]+TASK[[:space:]]+ROLE[[:space:]]+OP[[:space:]]+ATT[[:space:]]+ENGINE[[:space:]]+PID[[:space:]]+STATE[[:space:]]+AGE[[:space:]]+ELAPSED[[:space:]]+BUDGET[[:space:]]+LAUNCHER[[:space:]]+LOG$" \
  "$ls_out" "jobs ls renders one header row with every column the operator asked for"
assert_match "j-e1-TLS-a3-1111aaaa[[:space:]]+TLS[[:space:]]+reviewer[[:space:]]+review[[:space:]]+3[[:space:]]+fake[[:space:]]+${ls_live_pid}[[:space:]]+running[[:space:]]" \
  "$ls_out" "a job whose pid is alive renders running, with its role, op, attempt and engine on the row"
assert_match "j-e1-TLS-a4-2222bbbb[[:space:]]+TLS[[:space:]]+plan_critic[[:space:]]+critique[[:space:]]+4[[:space:]]+fake[[:space:]]+${ls_dead_pid}[[:space:]]+dead[[:space:]]" \
  "$ls_out" "a job whose pid is gone renders dead — the manifest still says it launched"
assert_match "j-e1-TLS-a5-3333cccc[[:space:]]+TLS[[:space:]]+implementer[[:space:]]+implement[[:space:]]+5[[:space:]]+fake[[:space:]]+0[[:space:]]+never-started[[:space:]]" \
  "$ls_out" "a pid-0 manifest with no log renders never-started"
assert_match "j-e1-TLS-a6-4444dddd[[:space:]]+TLS[[:space:]]+reviewer[[:space:]]+review[[:space:]]+6[[:space:]]+fake[[:space:]]+0[[:space:]]+prepared[[:space:]]" \
  "$ls_out" "a pid-0 manifest with a fresh log renders prepared — the engine may still be running"
assert_match "j-e1-TLS-a7-7777aaaa[[:space:]]+TLS[[:space:]]+reviewer[[:space:]]+review[[:space:]]+7[[:space:]]+fake[[:space:]]+0[[:space:]]+unstamped[[:space:]]" \
  "$ls_out" "a pid-0 manifest with a stale log renders unstamped, not prepared forever"
# Herestrings, not `echo ... | grep -q`, for every negative below: this file
# runs under `set -o pipefail`, and grep -q exits at its first match, which
# SIGPIPEs the upstream echo mid-write -- pipefail then promotes that 141 to
# the pipeline's status and the check silently reports the opposite of what it
# saw (helpers.sh documents the same hazard for assert_match).
grep -E "j-e1-TLS-a5-3333cccc.*[[:space:]]prepared[[:space:]]" <<< "$ls_out" \
  && fail "F29: a pid-0 manifest with no log must never render prepared — that word made 73 corpses read as healthy jobs"

# The machine surface is deliberately untouched: `jobs check` is what THE TICK
# is specified against, it kills what it calls stalled, and it still answers in
# its own vocabulary. The point is that the OPERATOR view no longer inherits it.
ls_check_out="$(ORCHID_TIMEOUT_MINUTES=60 "$ORCHID_BIN" jobs check)"
assert_match "TLS[[:space:]]+never-started" "$ls_check_out" \
  "jobs check and the table agree that pid 0 with no log is never-started"
assert_match "TLS	prepared" "$ls_check_out" \
  "jobs check and the table agree that pid 0 with a fresh log is prepared"
assert_match "TLS[[:space:]]+unstamped" "$ls_check_out" \
  "jobs check and the table agree that pid 0 with a stale log is unstamped"

# The three columns nothing else in the kernel could answer: who launched it.
assert_match "j-e1-TLS-a3-1111aaaa.*[[:space:]]drive[[:space:]]" "$ls_out" \
  "a job a drive pass started says so"
assert_match "j-e1-TLS-a4-2222bbbb.*[[:space:]]pump[[:space:]]" "$ls_out" \
  "a job the scheduled pump started says so — it wants a different response from a hand-run one"
assert_match "j-e1-TLS-a3-1111aaaa.*runtime/logs/j-ls-live\.log" "$ls_out" \
  "the log path is on the row, so the next command is copy-paste rather than a find under runtime/logs/"

# ---------------------------------------------------------------------------
# (2) AGE BESIDE LIVENESS, AND A WARNING THAT CANNOT BE SKIMMED PAST (F36).
# The failure this closes is not "the operator lacked data": a session read
# real, recent-looking findings out of a log and told its operator the critique
# was actively working, while the job had been DEAD FOR TWELVE AND A HALF
# HOURS. Both the operator and the assistant concluded the run was healthy from
# CONTENT while the TIMESTAMP said otherwise. So age is a column, and the two
# conditions that mean "nothing is happening" also say so in words, on stderr.
# ---------------------------------------------------------------------------
ls_warn="$("$ORCHID_BIN" jobs ls 2>&1 >/dev/null)"
assert_match "WARNING: job j-e1-TLS-a4-2222bbbb .* is dead and left no envelope" "$ls_warn" \
  "a job whose pid is gone and whose envelope never landed is called out as a failure, not left as a row to notice"
assert_match "j-e1-TLS-a4-2222bbbb .* last wrote [0-9]+d[0-9]+h ago" "$ls_warn" \
  "the age of the last thing it wrote is in the warning itself (F36: the timestamp was the signal nobody read)"
assert_match "WARNING: job j-e1-TLS-a5-3333cccc .* never started \(pid 0\)" "$ls_warn" \
  "a manifest that has sat prepared past the stall threshold is called out too — nothing is running for it"
assert_match "WARNING: job j-e1-TLS-a7-7777aaaa .* spawned but never stamped a pid" "$ls_warn" \
  "a log-backed pid-0 job silent past the stall threshold is called out as unstamped"
grep -q "j-e1-TLS-a6-4444dddd" <<< "$ls_warn" \
  && fail "a fresh log-backed pid-0 job may still be running and must not be warned about"
grep -q "j-e1-TLS-a3-1111aaaa" <<< "$ls_warn" \
  && fail "a live job that wrote to its log a moment ago must not be warned about"

# Age is rendered per row, not only inside a warning: the dead job last wrote
# in 2000, the live one just now.
ls_tsv="$("$ORCHID_BIN" jobs ls --tsv 2>/dev/null)"
ls_dead_age="$(awk -F'\t' '$1 == "j-e1-TLS-a4-2222bbbb" { print $9; exit }' <<< "$ls_tsv")"
assert_match "^[0-9]+d[0-9]{2}h$" "$ls_dead_age" "AGE is a duration a human reads at a glance"
ls_live_age="$(awk -F'\t' '$1 == "j-e1-TLS-a3-1111aaaa" { print $9; exit }' <<< "$ls_tsv")"
assert_match "^[0-9]+(s|m[0-9]{2}s)$" "$ls_live_age" \
  "a job writing right now shows seconds, not a stale-looking figure"

# ---------------------------------------------------------------------------
# ELAPSED AGAINST wallclock_budget_s. Distinguishing slow from hung meant
# reading started_at out of a manifest and doing the arithmetic by hand. The
# column and `jobs check`'s escalation now come from ONE predicate
# (schedule_budget_pct), so the table can never tell an operator a task is at
# 40% while check reports it budget-exceeded. TBUDGET (anchored in 2000,
# budget 1s) and TOKBUDGET (budget 28800s, just dispatched) are the fixtures
# built for `check` far above; here they are read through the new column.
# ---------------------------------------------------------------------------
ls_tb_pct="$(awk -F'\t' '$2 == "TBUDGET" { print $11; exit }' <<< "$ls_tsv")"
ls_ok_pct="$(awk -F'\t' '$2 == "TOKBUDGET" { print $11; exit }' <<< "$ls_tsv")"
assert_match "^[0-9]+%$" "$ls_tb_pct" "BUDGET renders as a percentage of the attempt's wall-clock budget"
assert_match "^[0-9]+%$" "$ls_ok_pct" "a task within budget shows its percentage too — continuously, not only once exceeded"
[ "${ls_tb_pct%\%}" -ge 100 ] || fail "the over-budget task must read >=100% in the table"
[ "${ls_ok_pct%\%}" -lt 100 ] || fail "the within-budget task must read <100% in the table"
assert_match "TBUDGET	budget-exceeded" "$ls_check_out" \
  "and jobs check agrees about the SAME task: >=100% in the column is exactly what it escalates"
grep -q "TOKBUDGET	budget-exceeded" <<< "$ls_check_out" \
  && fail "nor may the two disagree in the other direction"
# A task with no attempt in flight has no budget to render (the same
# active-status gate that keeps `check` from re-blocking a retried task).
ls_tls_pct="$(awk -F'\t' '$2 == "TLS" { print $11; exit }' <<< "$ls_tsv")"
assert_eq "-" "$ls_tls_pct" "a job whose task has no attempt in flight shows no budget, rather than an invented one"

# ---------------------------------------------------------------------------
# A DEAD PID WITH ITS ENVELOPE STILL IN THE SPOOL HAS DELIVERED. `jobs gc`
# already holds that manifest back for exactly one pass; rendering it `dead`
# would send an operator escalating a delivery that arrived (and relaunching a
# second engine over it).
# ---------------------------------------------------------------------------
( exit 0 ) & ls_del_pid=$!
wait "$ls_del_pid" 2>/dev/null || true
jq -n --argjson pid "$ls_del_pid" --argjson st "$(( ls_now - 30 ))" \
  --arg out "$rt/spool/j-e1-TDEL-a1-5555eeee.json" \
  '{job_id:"j-e1-TDEL-a1-5555eeee", task:"TDEL", attempt:1, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$st, log:"/nonexistent.log", output:$out,
    base_sha:"", candidate_sha:"", launched_by:"drive"}' > "$rt/jobs/j-ls-del.json"
echo '{"contract":1,"job_id":"j-e1-TDEL-a1-5555eeee","task":"TDEL","operation":"implement","status":"ok","summary":"delivered fixture"}' \
  > "$rt/spool/j-e1-TDEL-a1-5555eeee.json"
ls_del_out="$("$ORCHID_BIN" jobs ls 2>/dev/null)"
assert_match "j-e1-TDEL-a1-5555eeee[[:space:]].*[[:space:]]delivered[[:space:]]" "$ls_del_out" \
  "a dead pid whose envelope is waiting to be reconciled renders delivered, never dead"
ls_del_warn="$("$ORCHID_BIN" jobs ls 2>&1 >/dev/null)"
grep -q "j-e1-TDEL-a1-5555eeee" <<< "$ls_del_warn" \
  && fail "nor may it be warned about — it delivered, and the next reconcile files it"
rm -f "$rt/jobs/j-ls-del.json" "$rt/spool/j-e1-TDEL-a1-5555eeee.json"

# ---------------------------------------------------------------------------
# WHO LAUNCHED IT. `jobs prepare` records the automation that minted the job,
# so even a manifest whose launcher died before spawning still names it -- the
# pid-0 ghost is precisely the one an operator needs attributed. The value is
# ambient environment landing in a manifest a tab-separated table later
# renders, so it is sanitized rather than trusted verbatim.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TLAUNCHP "launcher-attribution-pump" >/dev/null
"$ORCHID_BIN" task create TLAUNCHD "launcher-attribution-default" >/dev/null
"$ORCHID_BIN" task create TLAUNCHH "launcher-attribution-hostile" >/dev/null
"$ORCHID_BIN" task create TLAUNCHE "launcher-attribution-empty" >/dev/null
ls_m_pump="$(ORCHID_LAUNCHED_BY=pump "$ORCHID_BIN" jobs prepare TLAUNCHP implementer implement)"
assert_eq "pump" "$(jq -r .launched_by "$ls_m_pump")" \
  "jobs prepare records the automation that owns the launch"
ls_m_default="$("$ORCHID_BIN" jobs prepare TLAUNCHD implementer implement)"
assert_eq "operator" "$(jq -r .launched_by "$ls_m_default")" \
  "a hand-run launch, inheriting nothing, records operator"
ls_m_hostile="$(ORCHID_LAUNCHED_BY="$(printf 'ev\til\nx')" "$ORCHID_BIN" jobs prepare TLAUNCHH implementer implement)"
assert_eq "evilx" "$(jq -r .launched_by "$ls_m_hostile")" \
  "a launcher value carrying a tab or a newline is stripped before it can splice a table row apart"
ls_m_empty="$(ORCHID_LAUNCHED_BY='!!!' "$ORCHID_BIN" jobs prepare TLAUNCHE implementer implement)"
assert_eq "operator" "$(jq -r .launched_by "$ls_m_empty")" \
  "a launcher value with nothing legible left in it falls back to operator, never to empty"

# ---------------------------------------------------------------------------
# `--all`: history, so "what did this task run, in what order, and how long did
# each take" is answerable AFTER the fact instead of reconstructed from
# journal.md by hand. Both paths that remove a manifest -- reconcile and gc --
# record it first, because the manifest is the only place a job's engine,
# launcher and start time ever lived; the durable envelope carries no timing.
# ---------------------------------------------------------------------------
( exit 0 ) & ls_hist_pid=$!
wait "$ls_hist_pid" 2>/dev/null || true
jq -n --argjson pid "$ls_hist_pid" --argjson st "$(( ls_now - 3661 ))" \
  --arg out "$rt/spool/j-e1-T001-a9-4444dddd.json" \
  '{job_id:"j-e1-T001-a9-4444dddd", task:"T001", attempt:9, role:"implementer", operation:"implement",
    engine:"fake", pid:$pid, pgid:0, started_at:$st, log:"/nonexistent.log", output:$out,
    base_sha:"", candidate_sha:"", launched_by:"drive"}' > "$rt/jobs/j-ls-hist.json"
echo '{"contract":1,"job_id":"j-e1-T001-a9-4444dddd","task":"T001","operation":"implement","status":"ok","summary":"history fixture"}' \
  > "$rt/spool/j-e1-T001-a9-4444dddd.json"
"$ORCHID_BIN" jobs reconcile >/dev/null

ls_all_out="$("$ORCHID_BIN" jobs ls --all 2>/dev/null)"
assert_match "j-e1-T001-a9-4444dddd[[:space:]]+T001[[:space:]]+implementer[[:space:]]+implement[[:space:]]+9[[:space:]]+fake[[:space:]]+${ls_hist_pid}[[:space:]]+ok[[:space:]]" \
  "$ls_all_out" "a reconciled job stays answerable after its manifest is gone, with the envelope's own outcome"
ls_all_tsv="$("$ORCHID_BIN" jobs ls --all --tsv 2>/dev/null)"
ls_hist_elapsed="$(awk -F'\t' '$1 == "j-e1-T001-a9-4444dddd" { print $10; exit }' <<< "$ls_all_tsv")"
assert_match "^[0-9]+h[0-9]{2}m$" "$ls_hist_elapsed" \
  "and how long it actually ran — measured at the moment it left the jobs dir, since nothing durable records it"

# A MANIFEST MINTED BEFORE THIS TASK HAS NO `launched_by` KEY AT ALL, and one
# is still sitting in the jobs dir of every run that upgrades mid-flight. Its
# row must land in the same columns as everyone else's. It is the empty-cell
# case, and the reason no producer here may emit one: the readers split on a
# tab, tab is IFS whitespace, and a run of IFS whitespace delimits ONE field,
# so an empty cell shifts every column after it left by one AND STILL PARSES.
# Untreated, this job's STATE would read as its log path, its LAUNCHER as a
# raw epoch, and its ELAPSED as `-`. (jq's `//` does not catch it: it takes
# its right side only for `null` or `false`, and "" is neither -- so a
# `{"role": ""}` manifest lands here too.)
( exit 0 ) & ls_old_pid=$!
wait "$ls_old_pid" 2>/dev/null || true
jq -n --argjson pid "$ls_old_pid" --argjson st "$(( ls_now - 3661 ))" \
  --arg out "$rt/spool/j-e1-T001-a10-6666ffff.json" \
  '{job_id:"j-e1-T001-a10-6666ffff", task:"T001", attempt:10, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$st,
    log:"/nonexistent.log", output:$out, base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-ls-old.json"
echo '{"contract":1,"job_id":"j-e1-T001-a10-6666ffff","task":"T001","operation":"implement","status":"ok","summary":"pre-upgrade fixture"}' \
  > "$rt/spool/j-e1-T001-a10-6666ffff.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
ls_old_tsv="$("$ORCHID_BIN" jobs ls --all --tsv 2>/dev/null)"
ls_old_row="$(awk -F'\t' '$1 == "j-e1-T001-a10-6666ffff" { print; exit }' <<< "$ls_old_tsv")"
assert_eq "ok" "$(awk -F'\t' '{ print $8 }' <<< "$ls_old_row")" \
  "STATE stays in the STATE column for a manifest that predates the launched_by field"
assert_eq "-" "$(awk -F'\t' '{ print $12 }' <<< "$ls_old_row")" \
  "an unrecorded launcher renders as '-', never as an empty cell that shifts the row"
assert_eq "/nonexistent.log" "$(awk -F'\t' '{ print $13 }' <<< "$ls_old_row")" \
  "and the log path is still the last column, not one cell to the left"
assert_match "^[0-9]+h[0-9]{2}m$" "$(awk -F'\t' '{ print $10 }' <<< "$ls_old_row")" \
  "ELAPSED is still a duration — the column an operator uses to tell slow from hung"

assert_match "j-e1-TPREP-a1-aaaa0001.*gc-prepared" "$ls_all_out" \
  "a manifest gc reaped is in the history too, named by the reason it was reaped"
grep -q "gc-prepared" <<< "$ls_out" \
  && fail "the DEFAULT table is outstanding jobs only — history is what --all is for"
grep -q "j-e1-TLS-a3-1111aaaa" <<< "$ls_all_out" \
  || fail "--all must still include the jobs that are outstanding right now"

# ---------------------------------------------------------------------------
# `--warnings` (what `orchid status` calls in every mode) prints nothing on
# stdout: it exists so the liveness warnings reach an operator who never asked
# for a table.
# ---------------------------------------------------------------------------
ls_warn_stdout="$("$ORCHID_BIN" jobs ls --warnings 2>/dev/null)"
assert_eq "" "$ls_warn_stdout" "jobs ls --warnings writes no table to stdout"
ls_warn_stderr="$("$ORCHID_BIN" jobs ls --warnings 2>&1 >/dev/null)"
assert_match "is dead and left no envelope" "$ls_warn_stderr" "jobs ls --warnings still warns"

# ---------------------------------------------------------------------------
# `--watch`, since the natural use of a process table is polling -- both
# operators who hit this were already doing it by hand around `orchid drive`.
# Polled to a condition rather than slept-and-asserted: a fixed sleep here
# would be a timing coin flip on a loaded machine.
# ---------------------------------------------------------------------------
ls_watch_log="$WORK/ls-watch.out"
: > "$ls_watch_log"
"$ORCHID_BIN" jobs ls --watch --interval 1 > "$ls_watch_log" 2>/dev/null &
ls_watch_pid=$!
ls_watch_ok=0
ls_watch_n=0
ls_watch_tries=0
while [ "$ls_watch_tries" -lt 15 ]; do
  ls_watch_tries=$(( ls_watch_tries + 1 ))
  ls_watch_n="$(grep -c '^# orchid jobs' "$ls_watch_log" 2>/dev/null)" || true
  case "${ls_watch_n:-0}" in
    ''|*[!0-9]*) ls_watch_n=0 ;;
  esac
  if [ "$ls_watch_n" -ge 2 ]; then ls_watch_ok=1; break; fi
  sleep 1
done
kill "$ls_watch_pid" 2>/dev/null || true
wait "$ls_watch_pid" 2>/dev/null || true
[ "$ls_watch_ok" -eq 1 ] \
  || fail "jobs ls --watch must re-render on its interval (saw $ls_watch_n renders in 15s at --interval 1)"
assert_match "j-e1-TLS-a3-1111aaaa" "$(cat "$ls_watch_log")" "each --watch render is the same table"

# An interval must be a positive whole number of seconds: a mistyped one that
# fell through to `sleep` would spin the loop as fast as the machine allows.
ls_bad_rc=0
"$ORCHID_BIN" jobs ls --watch --interval 0 >/dev/null 2>&1 || ls_bad_rc=$?
[ "$ls_bad_rc" -ne 0 ] || fail "jobs ls --interval 0 must be refused, not spun"
ls_bad_rc=0
"$ORCHID_BIN" jobs ls --nonsense >/dev/null 2>&1 || ls_bad_rc=$?
[ "$ls_bad_rc" -ne 0 ] || fail "jobs ls must refuse an unknown flag rather than ignore it"

kill "$ls_live_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-ls-live.json" "$rt/jobs/j-ls-dead.json" "$rt/jobs/j-ls-prep.json"

# ===========================================================================
# T040 / dogfood finding F35 -- NEVER DISCARD WORK A JOB ALREADY COMPLETED.
#
# The reported incident, verbatim in shape: critique attempt a4 ran to
# completion, produced EIGHT complete findings, wrote every one of them to its
# job log, and then exited WITHOUT writing an envelope. `orchid jobs
# reconcile` had nothing to land, so from the outside the attempt simply never
# happened -- the findings sat in
# `.orchid/runtime/logs/j-e0-plan-a4-b068.log` until an operator recovered
# them with grep and applied them by hand. Without that grep they were lost
# and an expensive critique would have been re-run to regenerate findings
# orchid already had on disk.
#
# The fixture below is that job: a manifest whose pid is dead, no envelope
# anywhere, and a log holding results in the SAME `FINDING:`/`VERDICT:`
# grammar the review adapters themselves emit and parse.
#
# The job_id's trailing field is HEX, exactly as `jobs prepare` mints it --
# the salvage pass validates it with the same regex as gc's dead-manifest
# reap (see the TEVIL case below), so a mnemonic non-hex id here would be
# skipped as suspect and every assertion in this Part would see empty.
# ===========================================================================
salv_log="$rt/logs/j-e1-TSALV-a1-5a1f0001.log"
mkdir -p "$rt/logs" "$rt/exits"
cat > "$salv_log" <<'SALVLOG'
Reading the pack...
FINDING: high: the reaper never runs in PLANNING
FINDING: medium: a refusal and its gc disagree about the same predicate
FINDING: bogus: this severity token is not one of the three
FINDING: low:
VERDICT: request-changes
SALVLOG
printf '7\n' > "$rt/exits/j-e1-TSALV-a1-5a1f0001"

( exit 0 ) & salv_pid=$!
wait "$salv_pid" 2>/dev/null || true
jq -n --argjson pid "$salv_pid" --arg log "$salv_log" \
  '{job_id:"j-e1-TSALV-a1-5a1f0001", task:"TSALV", attempt:4, role:"plan_critic",
    operation:"critique", engine:"critic", pid:$pid, pgid:0, started_at:1,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:"cand0", hook_point:""}' \
  > "$rt/jobs/j-salv.json"

salv_out="$("$ORCHID_BIN" jobs reconcile)"
assert_match "TSALV	no_envelope" "$salv_out" \
  "reconcile REPORTS the exited-without-an-envelope job -- printing nothing is what made this look like a job that never ran"
salv_env=".orchid/reviews/TSALV-a4-plan_critic.json"
[ -f "$salv_env" ] \
  || fail "the findings the engine already produced must be landed as a degraded envelope, not left for an operator to grep out of runtime/logs"
assert_eq no_envelope "$(jq -r .status "$salv_env")" "the degraded envelope carries the first-class no_envelope status"
assert_eq true "$(jq -r .degraded "$salv_env")" "and is marked degraded"
assert_eq 7 "$(jq -r .exit_code "$salv_env")" "and carries the exit code the launcher recorded"
assert_eq "$salv_log" "$(jq -r .salvaged_from "$salv_env")" "and names the log it was reconstructed from"
assert_eq request-changes "$(jq -r .verdict "$salv_env")" "the verdict line in the log is salvaged too"
assert_eq 2 "$(jq -r '.findings | length' "$salv_env")" \
  "exactly the two well-formed findings are salvaged -- an unknown severity token and an empty title are dropped, never guessed at (same best-effort parse the adapters themselves use)"
assert_eq "the reaper never runs in PLANNING" "$(jq -r '.findings[0].title' "$salv_env")" "the first finding survives verbatim"
assert_eq high "$(jq -r '.findings[0].severity' "$salv_env")" "with its severity"
assert_eq cand0 "$(jq -r .candidate_sha "$salv_env")" "and stays bound to the candidate its manifest pinned"
red_case "a job that logged results and exited with no envelope: the work is recovered as a degraded envelope, not discarded"

# The failure is VISIBLE without knowing to grep runtime/logs: the exit code
# and the tail of the log are journaled.
salv_journal="$("$ORCHID_BIN" journal show --task TSALV)"
assert_match "exited without writing an envelope" "$salv_journal" "the death itself is journaled"
assert_match "Exit code: 7" "$salv_journal" "with the exit code an operator otherwise has no way to see"
assert_match "the reaper never runs in PLANNING" "$salv_journal" "and the tail of the log, so the evidence is in the audit trail too"

# The manifest SURVIVES, stamped. The driver's escalation sweep reads dead
# manifests, not reconcile's stdout, and runs after reconcile in the same
# pass: deleting it here would retire the infra_failures ladder for exactly
# this failure class, trading one silent loss for another.
[ -f "$rt/jobs/j-salv.json" ] \
  || fail "the manifest must survive reconcile -- the escalation sweep reads it, and gc reaps it a step later in the same pass"
assert_eq true "$(jq -r .no_envelope_reported "$rt/jobs/j-salv.json")" "and is stamped as reported"

# Reported ONCE. A second reconcile before gc gets to the manifest must not
# file a second envelope nor re-journal the same death.
salv_out2="$("$ORCHID_BIN" jobs reconcile)"
# A HERESTRING, never `echo "$out" | grep -q`: under pipefail, grep -q exits
# at its first match and SIGPIPEs the echo, so the pipeline reports 141 and
# this assertion would be SKIPPED exactly when the duplicate it guards against
# is present (helpers.sh's assert_match carries the same note).
grep -q "TSALV" <<<"$salv_out2" && fail "a second reconcile must not re-report the same envelope-less job"
[ ! -e ".orchid/reviews/TSALV-a4-plan_critic.2.json" ] \
  || fail "nor file a duplicate degraded envelope beside the first"
green_case "the same job re-reconciled: reported and salvaged exactly once"

# ---------------------------------------------------------------------------
# ...and NOTHING IS INVENTED. A job that exits leaving no parseable results
# files NO envelope at all. This is the half that keeps the salvage honest:
# several gates read a same-shaped file at that path as evidence that the
# question has been answered (drive_hook_envelope_count counts hook envelopes;
# `jobs prepare` counts plan-critique rounds), so manufacturing one for every
# muted exit would answer questions nobody asked. The death is still reported
# and still journaled -- that is not conditional on there being loot.
# ---------------------------------------------------------------------------
mute_log="$rt/logs/j-e1-TMUTE-a1-3ee00001.log"
printf 'starting up\nsomething went wrong, exiting\n' > "$mute_log"
( exit 0 ) & mute_pid=$!
wait "$mute_pid" 2>/dev/null || true
jq -n --argjson pid "$mute_pid" --arg log "$mute_log" \
  '{job_id:"j-e1-TMUTE-a1-3ee00001", task:"TMUTE", attempt:1, role:"plan_critic",
    operation:"critique", engine:"critic", pid:$pid, pgid:0, started_at:1,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:"", hook_point:""}' \
  > "$rt/jobs/j-mute.json"

mute_out="$("$ORCHID_BIN" jobs reconcile)"
assert_match "TMUTE	no_envelope	nothing-to-salvage" "$mute_out" \
  "a job that produced nothing is still reported as a failure, and says so plainly"
[ ! -e ".orchid/reviews/TMUTE-a1-plan_critic.json" ] \
  || fail "an envelope must NEVER be manufactured for a job whose log held no results -- gates read that file as evidence the point was answered"
assert_match "Exit code: unrecorded" "$("$ORCHID_BIN" journal show --task TMUTE)" \
  "an unrecorded exit code is reported as unrecorded, never as 0"

# ---------------------------------------------------------------------------
# `no_envelope` is the KERNEL's word. An adapter that files one in the spool
# is not reporting its own status, it is impersonating the kernel's account of
# one -- and every reader that skips a degraded envelope as non-evidence would
# skip that engine's real failure the same way, silently.
# ---------------------------------------------------------------------------
mforge="$("$ORCHID_BIN" jobs prepare plan plan_critic critique)"
forge_jid="$(jq -r .job_id "$mforge")"; forge_out="$(jq -r .output "$mforge")"
printf '{"contract":1,"job_id":"%s","task":"plan","operation":"critique","status":"no_envelope","findings":[{"severity":"high","title":"forged"}]}' \
  "$forge_jid" > "$forge_out"
forge_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "quarantined: $forge_jid.json \(kernel-status\)" "$forge_line" \
  "a spool envelope claiming the kernel-only no_envelope status is quarantined, never accepted"
[ -f "$rt/quarantine/$forge_jid.json.reason-kernel-status" ] || fail "and lands in quarantine under that reason"

# ---------------------------------------------------------------------------
# T040 rework (carried finding): the salvage pass validates manifest-derived
# fields exactly as gc's dead-manifest reap does, BEFORE tailing the log or
# building the reviews/ write path from them -- task/attempt/role/hook_point
# become the write path, job_id keys the exits/ read, and the log is tailed
# straight into the journal. A corrupted or hand-edited manifest must not
# steer a read or a write anywhere on disk: skipped, salvaging nothing, and
# left standing for gc's own sweep to quarantine as gc-suspect.
# ---------------------------------------------------------------------------
evil_decoy="$WORK/evil-decoy.log"
printf 'FINDING: high: decoy outside runtime\n' > "$evil_decoy"
( exit 0 ) & evil_pid=$!
wait "$evil_pid" 2>/dev/null || true
jq -n --argjson pid "$evil_pid" --arg log "$evil_decoy" \
  '{job_id:"j-e1-TEVIL-a1-ee110001", task:"../../tasks/TEVIL", attempt:1, role:"plan_critic",
    operation:"critique", engine:"critic", pid:$pid, pgid:0, started_at:1,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:"", hook_point:""}' \
  > "$rt/jobs/j-evilsalv.json"
evil_out="$("$ORCHID_BIN" jobs reconcile)"
assert_match "salvage-skip: j-evilsalv.json \(suspect fields\)" "$evil_out" \
  "a dead manifest whose fields fail validation is skipped by the salvage pass, and says so"
grep -q "no_envelope" <<<"$evil_out" \
  && fail "nothing may be salvaged from a suspect manifest -- its fields would steer the write path and the log read"
[ -f "$rt/jobs/j-evilsalv.json" ] \
  || fail "the suspect manifest is left standing for gc's own sweep to quarantine"
assert_eq false "$(jq -r '.no_envelope_reported // false' "$rt/jobs/j-evilsalv.json")" \
  "and is not stamped as reported -- the salvage pass never touched it"
rm -f "$rt/jobs/j-evilsalv.json" "$evil_decoy"

# ===========================================================================
# T040 / F35, second half -- LIVENESS IS CHECKED, PROGRESS IS NOT.
#
# The other attempt that produced nothing kept sending heartbeats while its
# CPU time stayed flat: 0.85s at 05:18:12Z and 1.07s at 05:23:42Z, roughly two
# tenths of a second of CPU across five minutes of wallclock. Then it exited
# with no envelope. `jobs check` has a `stalled` status and it never fired,
# because the process was ALIVE -- and the heartbeats kept its log mtime fresh
# the whole time, so the log-mtime stall arm could not fire either.
#
# The CPU numbers were already on disk: lib/heartbeat.sh has carried a `cpu`
# field on every heartbeat line since it was written, explicitly so a future
# CPU-delta guard would have the raw signal to consume. These cases are that
# consumer. Note every fixture log below is written FRESH (mtime = now), so
# the log-mtime arm is provably not what is firing.
#
# THE ARM IS OPT-IN (cpu_stall_min_s, default 0: off): F35's own follow-up
# retracted CPU as a sole progress signal after a healthy API-bound job
# proved indistinguishable from the dead one on CPU alone (~9 CPU-seconds
# across 40 minutes, 24 modified files in its worktree). The cases below
# therefore opt in explicitly with ORCHID_CPU_STALL_MIN_S=1; the default's
# own edge -- no floor configured, no kill -- is pinned further down.
# ===========================================================================
cpu_stall_log="$rt/logs/j-cpuflat.log"
cat > "$cpu_stall_log" <<'FLATLOG'
[hb 2026-08-11T05:18:12Z] engine pid 4242 cpu 0:00.85
[hb 2026-08-11T05:21:12Z] engine pid 4242 cpu 0:00.97
[hb 2026-08-11T05:23:42Z] engine pid 4242 cpu 0:01.07
FLATLOG
# pgid 0 in every fixture below, exactly as the pgid-guard case far above
# does: a `sleep &` in a non-interactive script inherits this script's own
# process group rather than leading one, so a group kill keyed on its pid
# would signal no group at all and the kill assertion would pass vacuously.
# kill_stuck falls back to signalling the pid directly when pgid is 0.
sleep 100 &
cpu_stall_pid=$!
# DISOWNED, as at the pgid guard far above and at every `sleep 100 &` in this
# CPU block. Each of these six fixtures ends with its job reaped -- by `jobs
# check` where the arm is meant to fire, by an explicit `kill` where it is
# meant not to -- and bash announces every one of those reaps on stderr as
# `tests/test_jobs.sh: line N: <pid> Terminated: 15 sleep 100`. That is the
# `file: line N:` shape lib/findings.sh carries into a rework brief, so six
# PASSING fixtures hand the next implementer six fabricated locations and
# displace the real ones. They did exactly that to T018, whose own brief
# arrived carrying these six lines and nothing else.
disown 2>/dev/null || true
jq -n --argjson pid "$cpu_stall_pid" --arg log "$cpu_stall_log" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TCPUFLAT-a1-c0f00001", task:"TCPUFLAT", attempt:1, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$started,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-cpuflat.json"

# stall_minutes=5 makes the window exactly the 5m30s the fixture spans;
# timeout_minutes is 0 in this file's config (set far above for the pgid
# guard), so it is overridden here or the timeout arm would answer first and
# the case would prove nothing about CPU. CPU_STALL_MIN_S=1 opts the arm in
# (default 0: off), the shape an operator who enabled it would run.
cpu_out="$(ORCHID_STALL_MINUTES=5 ORCHID_TIMEOUT_MINUTES=60 ORCHID_CPU_STALL_MIN_S=1 \
  "$ORCHID_BIN" jobs check 2>/dev/null)"
assert_match "TCPUFLAT	stalled" "$cpu_out" \
  "a heartbeating process burning 0.2s of CPU across five minutes is NOT working -- its heartbeats are lying, and check must call it stalled"
sleep 0.3
if kill -0 "$cpu_stall_pid" 2>/dev/null; then
  fail "a CPU-stalled job must be killed, exactly as a log-mtime-stalled one is"
  kill "$cpu_stall_pid" 2>/dev/null || true
fi
rm -f "$rt/jobs/j-cpuflat.json"
red_case "a live, heartbeating job with no CPU progress is marked stalled"

# The twin: the SAME heartbeat cadence, the same fresh log, a job that is
# genuinely working. It must be left alone -- an engine doing real work must
# never be killed by the guard that catches one doing none.
cpu_busy_log="$rt/logs/j-cpubusy.log"
cat > "$cpu_busy_log" <<'BUSYLOG'
[hb 2026-08-11T05:18:12Z] engine pid 4243 cpu 0:00.85
[hb 2026-08-11T05:21:12Z] engine pid 4243 cpu 0:18.40
[hb 2026-08-11T05:23:42Z] engine pid 4243 cpu 0:41.12
BUSYLOG
sleep 100 &
cpu_busy_pid=$!
disown 2>/dev/null || true  # as at the flat-CPU fixture above: a reaped job's notice is not a finding
jq -n --argjson pid "$cpu_busy_pid" --arg log "$cpu_busy_log" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TCPUBUSY-a1-c0b00001", task:"TCPUBUSY", attempt:1, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$started,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-cpubusy.json"
# Opted in (CPU_STALL_MIN_S=1), or the `running` below would be vacuous --
# an unconfigured arm never consults the log at all.
busy_out="$(ORCHID_STALL_MINUTES=5 ORCHID_TIMEOUT_MINUTES=60 ORCHID_CPU_STALL_MIN_S=1 \
  "$ORCHID_BIN" jobs check 2>/dev/null)"
assert_match "TCPUBUSY	running" "$busy_out" "a job accumulating real CPU over the same window is running, not stalled"
kill -0 "$cpu_busy_pid" 2>/dev/null || fail "and it must still be alive -- the guard must never kill an engine that is working"
green_case "a live job burning real CPU over the same window is left running"
kill "$cpu_busy_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-cpubusy.json"

# Not enough heartbeat history to span the window is NOT evidence of a stall.
# A job in its first minutes has no anchor to measure a delta against, and
# judging it anyway would kill every engine during its own startup.
cpu_young_log="$rt/logs/j-cpuyoung.log"
cat > "$cpu_young_log" <<'YOUNGLOG'
[hb 2026-08-11T05:18:12Z] engine pid 4244 cpu 0:00.85
[hb 2026-08-11T05:18:42Z] engine pid 4244 cpu 0:00.86
YOUNGLOG
sleep 100 &
cpu_young_pid=$!
disown 2>/dev/null || true  # as at the flat-CPU fixture above: a reaped job's notice is not a finding
jq -n --argjson pid "$cpu_young_pid" --arg log "$cpu_young_log" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TCPUYOUNG-a1-c0900001", task:"TCPUYOUNG", attempt:1, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$started,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-cpuyoung.json"
# Opted in for the same non-vacuity reason as the busy twin above.
young_out="$(ORCHID_STALL_MINUTES=5 ORCHID_TIMEOUT_MINUTES=60 ORCHID_CPU_STALL_MIN_S=1 \
  "$ORCHID_BIN" jobs check 2>/dev/null)"
assert_match "TCPUYOUNG	running" "$young_out" \
  "thirty seconds of heartbeats cannot answer a five-minute question -- a job with no anchor in the window is never judged by it"
kill "$cpu_young_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-cpuyoung.json"

# An EXPLICIT cpu_stall_min_s=0 (not just the unset default) disables the
# check outright -- the check arm skips the log entirely when it reads 0.
# Proved on the very fixture that DID fire when opted in above.
cat > "$cpu_stall_log" <<'FLATLOG2'
[hb 2026-08-11T05:18:12Z] engine pid 4245 cpu 0:00.85
[hb 2026-08-11T05:21:12Z] engine pid 4245 cpu 0:00.97
[hb 2026-08-11T05:23:42Z] engine pid 4245 cpu 0:01.07
FLATLOG2
sleep 100 &
cpu_off_pid=$!
disown 2>/dev/null || true  # as at the flat-CPU fixture above: a reaped job's notice is not a finding
jq -n --argjson pid "$cpu_off_pid" --arg log "$cpu_stall_log" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TCPUOFF-a1-c0000001", task:"TCPUOFF", attempt:1, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$started,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-cpuoff.json"
off_out="$(ORCHID_STALL_MINUTES=5 ORCHID_TIMEOUT_MINUTES=60 ORCHID_CPU_STALL_MIN_S=0 \
  "$ORCHID_BIN" jobs check 2>/dev/null)"
assert_match "TCPUOFF	running" "$off_out" "cpu_stall_min_s=0 disables the CPU-delta check outright"
kill "$cpu_off_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-cpuoff.json"

# ---------------------------------------------------------------------------
# T040 rework: THE DEFAULT IS OFF -- the opt-in edge, pinned. F35's follow-up
# retracted CPU as a sole progress signal: a legitimate implement job sat at
# ~9s of CPU across 40 minutes -- on CPU alone identical to the flat fixture
# above -- and was working the whole time, with 24 modified files in its
# worktree to prove it. Worktree corroboration cannot rescue the signal for
# review/critique/hook jobs either: they run under a read-only policy and
# legitimately never touch the worktree for their whole run. A kill here
# discards work the engine was already paid for -- the loss this whole task
# exists to prevent -- so with NO floor configured the arm must not fire, on
# the very fixture that fires when opted in.
# ---------------------------------------------------------------------------
cat > "$cpu_stall_log" <<'FLATLOG3'
[hb 2026-08-11T05:18:12Z] engine pid 4246 cpu 0:00.85
[hb 2026-08-11T05:21:12Z] engine pid 4246 cpu 0:00.97
[hb 2026-08-11T05:23:42Z] engine pid 4246 cpu 0:01.07
FLATLOG3
sleep 100 &
cpu_dflt_pid=$!
disown 2>/dev/null || true  # as at the flat-CPU fixture above: a reaped job's notice is not a finding
jq -n --argjson pid "$cpu_dflt_pid" --arg log "$cpu_stall_log" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TCPUDFLT-a1-c0d00001", task:"TCPUDFLT", attempt:1, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$started,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-cpudflt.json"
dflt_out="$(ORCHID_STALL_MINUTES=5 ORCHID_TIMEOUT_MINUTES=60 "$ORCHID_BIN" jobs check 2>/dev/null)"
assert_match "TCPUDFLT	running" "$dflt_out" \
  "with no floor configured the CPU arm must not fire -- CPU alone cannot tell a dead engine from a healthy one blocked on a vendor API"
kill -0 "$cpu_dflt_pid" 2>/dev/null \
  || fail "and the job must still be alive -- an unconfigured arm must never kill"
red_case "the CPU-delta arm is opt-in: with no floor configured, the flat-CPU job is left running"
kill "$cpu_dflt_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-cpudflt.json"

# ---------------------------------------------------------------------------
# T040 rework: A CPU COUNTER THAT GOES BACKWARDS IS UNKNOWN, NEVER A STALL.
# `ps -o time=` is cumulative per-PID, and pid reuse hands a heartbeat a
# stranger's clock -- ordinary, not exotic. The old comparison asked only
# "is the delta >= the floor", so a NEGATIVE delta failed that test, fell
# through, and killed a healthy job. Unknown must not kill: even with the
# arm opted in, this job stays running and alive.
# ---------------------------------------------------------------------------
cpu_back_log="$rt/logs/j-cpuback.log"
cat > "$cpu_back_log" <<'BACKLOG'
[hb 2026-08-11T05:18:12Z] engine pid 4247 cpu 0:41.12
[hb 2026-08-11T05:21:12Z] engine pid 4247 cpu 0:00.30
[hb 2026-08-11T05:23:42Z] engine pid 4247 cpu 0:00.95
BACKLOG
sleep 100 &
cpu_back_pid=$!
disown 2>/dev/null || true  # as at the flat-CPU fixture above: a reaped job's notice is not a finding
jq -n --argjson pid "$cpu_back_pid" --arg log "$cpu_back_log" --argjson started "$(date +%s)" \
  '{job_id:"j-e1-TCPUBACK-a1-c0e00001", task:"TCPUBACK", attempt:1, role:"implementer",
    operation:"implement", engine:"fake", pid:$pid, pgid:0, started_at:$started,
    log:$log, output:"/dev/null", base_sha:"", candidate_sha:""}' \
  > "$rt/jobs/j-cpuback.json"
back_out="$(ORCHID_STALL_MINUTES=5 ORCHID_TIMEOUT_MINUTES=60 ORCHID_CPU_STALL_MIN_S=1 \
  "$ORCHID_BIN" jobs check 2>/dev/null)"
assert_match "TCPUBACK	running" "$back_out" \
  "a negative CPU delta is unknown, never no-progress -- even with the arm opted in it must not fire"
kill -0 "$cpu_back_pid" 2>/dev/null \
  || fail "and the job must still be alive -- unknown must not kill"
red_case "a CPU counter that went backwards (pid reuse) is unknown: the job is left running, not killed"
kill "$cpu_back_pid" 2>/dev/null || true
rm -f "$rt/jobs/j-cpuback.json"

# ---------------------------------------------------------------------------
# T027 (dogfood F29): prepare refuses a SECOND manifest for a job that already
# has an UNLAUNCHED one -- same task, attempt, role, operation and (for
# hooks) the same point. A launcher that dies before its spawn line leaves one
# behind; minting another cannot make the first one run, and a run that did it
# once per pass ended with 73 identical pid-0 manifests, no logs and nothing to
# reconcile. Exit 18 is a WAIT for the caller (like exit 14's closed ledger
# window), and it clears itself: gc reaps the orphan and the identical call
# then succeeds.
#
# The refusal is keyed on the SAME predicate gc's reap is
# (job_unlaunched_reapable: pid 0, and either no log at all or one nothing has
# written to in `stall_minutes`). That is what makes it a state that can always
# be left, and the two assertions at the end of this block are the ones that
# hold it there: a pid-0 manifest whose log is still being written is not
# reapable, so it must not be refusable either -- refusing over something
# nothing retires is a permanent refusal.
# ---------------------------------------------------------------------------
count_manifests() {  # task
  local mf n=0
  for mf in "$rt/jobs"/*.json; do
    [ -e "$mf" ] || continue
    [ "$(jq -r '.task // ""' "$mf" 2>/dev/null || echo)" = "$1" ] || continue
    n=$((n + 1))
  done
  echo "$n"
}

"$ORCHID_BIN" task create TDUP "one orphan per slot is enough" >/dev/null
dup1="$("$ORCHID_BIN" jobs prepare TDUP implementer implement)"
assert_eq "0" "$(jq -r .pid "$dup1")" "the first prepare mints the usual unlaunched manifest"

rc=0; dup_err="$("$ORCHID_BIN" jobs prepare TDUP implementer implement 2>&1 1>/dev/null)" || rc=$?
assert_eq 18 "$rc" "a second prepare for the same never-started slot exits 18"
assert_match "already has an unlaunched manifest" "$dup_err" \
  "and says exactly what it found, naming the manifest an operator has to look at"
assert_match "orchid jobs gc --reap-prepared --older-than-s 0" "$dup_err" \
  "and names the immediate way out, so the refusal is never a dead end"
assert_eq 1 "$(count_manifests TDUP)" "no second manifest was minted"

# A DIFFERENT slot on the same task and attempt is a different job, and is
# minted normally -- the refusal is keyed on the job's identity, not the task's.
dup_rev="$("$ORCHID_BIN" jobs prepare TDUP plan_critic critique)"
[ -f "$dup_rev" ] || fail "a different role/operation on the same attempt must still be prepared"
assert_eq 2 "$(count_manifests TDUP)" "the second slot really got its own manifest"

# Two hook points bind through the SAME role positional (the literal "hook"),
# so the point is part of the key: an unlaunched before_merge handler must not
# refuse an unrelated on_blocker one.
printf 'hook.on_blocker=planhook\n' >> orchid.config
dup_h1="$("$ORCHID_BIN" jobs prepare TDUP hook hook --hook after_plan_draft)"
[ -f "$dup_h1" ] || fail "the first hook job for this attempt must be prepared"
dup_h2="$("$ORCHID_BIN" jobs prepare TDUP hook hook --hook on_blocker)"
[ -f "$dup_h2" ] || fail "a hook job for a DIFFERENT point is a different job, not a duplicate"
rc=0; "$ORCHID_BIN" jobs prepare TDUP hook hook --hook after_plan_draft >/dev/null 2>&1 || rc=$?
assert_eq 18 "$rc" "...but the same point twice, still unlaunched, is refused"

# Once the manifest carries a real pid it is a LAUNCHED job, and this refusal
# has nothing to say about it: whether a second engine may run for a slot is a
# dispatch decision (runners/orchid-drive's drive_job_outstanding), never this
# verb's.
jq '.pid=424242 | .pgid=424242' "$dup1" > "$dup1.tmp" && mv "$dup1.tmp" "$dup1"
dup_after_launch="$("$ORCHID_BIN" jobs prepare TDUP implementer implement)"
[ -f "$dup_after_launch" ] || fail "prepare must not refuse over a manifest that really was launched"
rm -f "$dup_after_launch"

# And a pid-0 manifest whose log is STILL BEING WRITTEN must not be refused
# over. Nothing reaps that one -- an engine may be running behind it -- so a
# refusal keyed on it would be permanent, which is the one way this guard could
# turn "retrying forever" into "never running again". The refusal and the reap
# must cover EXACTLY the same manifests, and this is that assertion from the
# refusal side.
"$ORCHID_BIN" task create TDUPLOG "a manifest with a log is not an orphan" >/dev/null
dup_c="$("$ORCHID_BIN" jobs prepare TDUPLOG implementer implement)"
dup_c_log="$(jq -r .log "$dup_c")"
mkdir -p "$(dirname "$dup_c_log")"; printf 'engine is running\n' > "$dup_c_log"
dup_c2="$("$ORCHID_BIN" jobs prepare TDUPLOG implementer implement)" \
  || fail "prepare must not refuse over a pid-0 manifest whose log is still being written — nothing reaps that one, so the refusal would never clear"
[ -f "$dup_c2" ] || fail "the second manifest must really have been minted"

# ...and the OTHER side of that same rule (T027 rework): once that log has been
# silent past `stall_minutes` the manifest IS reapable, so it MUST be refusable
# too. The refusal and the reap are one predicate; a manifest gc will retire
# that prepare still mints over is the 73-orphans defect coming back for the
# log-backed half of the class.
rm -f "$dup_c2"
touch -t 202001010000 "$dup_c_log"
rc=0; dup_c_err="$("$ORCHID_BIN" jobs prepare TDUPLOG implementer implement 2>&1 1>/dev/null)" || rc=$?
assert_eq 18 "$rc" \
  "a pid-0 manifest whose log went silent past stall_minutes is unlaunched, and prepare refuses over it"
assert_match "already has an unlaunched manifest" "$dup_c_err" \
  "and says so in the same words, naming the manifest gc is about to retire"
rm -f "$dup_c_log" "$dup_c"

# And the refusal clears itself: gc reaps the orphan, the identical call works.
touch -t 202001010000 "$dup_h1"
"$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null
[ ! -f "$dup_h1" ] || fail "gc must reap the aged never-launched hook manifest"
dup_h1b="$("$ORCHID_BIN" jobs prepare TDUP hook hook --hook after_plan_draft)"
[ -f "$dup_h1b" ] || fail "once the orphan is reaped, the identical prepare succeeds with no operator action"
# T031 (r-002, lesson L025): AN ENVELOPE IS A COMPLETION REPORT, and a job
# that has not exited has not completed. Reconciling one early is what let
# T013 certify the wrong commit: reconcile filed the implement envelope and
# DELETED the manifest, `runners/orchid-drive` read that as "the implementer
# is done" and captured candidate_sha from the worktree's HEAD -- while the
# job was still alive and went on to commit again 19 minutes later. Once the
# manifest is gone there is nothing left on disk that says a job is running,
# so this is the only place the truth still exists.
#
# A live pid must therefore DEFER: envelope stays in the spool, manifest
# stays in jobs/, nothing is filed and nothing is quarantined.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TDEFER "envelope filed by a job that is still running" >/dev/null
mlive="$("$ORCHID_BIN" jobs prepare TDEFER implementer implement)"
live_jid="$(jq -r .job_id "$mlive")"
live_out="$(jq -r .output "$mlive")"
sleep 30 &
live_engine_pid=$!
# started_at deliberately in the past, so the gc assertion below turns on the
# spool guard rather than on gc's own age bound.
jq --argjson pid "$live_engine_pid" '.pid=$pid | .pgid=$pid | .started_at=((now|floor) - 600)' \
  "$mlive" > "$mlive.tmp" && mv "$mlive.tmp" "$mlive"
printf '{"contract":1,"job_id":"%s","task":"TDEFER","operation":"implement","status":"ok","summary":"filed early"}' \
  "$live_jid" > "$live_out"

live_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "^deferred: " "$live_line" "T031: reconcile defers an envelope whose job is still running"
[ -f "$live_out" ] || fail "T031: a deferred envelope must stay in the spool"
[ -f "$mlive" ] || fail "T031: a deferred envelope's manifest must survive — it is the only record that the job is alive"
[ ! -f ".orchid/reviews/TDEFER-a1-implementer.json" ] || fail "T031: a live job's envelope must not be filed to reviews/"
for _q in "$rt/quarantine/$live_jid.json".*; do
  [ -e "$_q" ] || continue
  fail "T031: deferring is not quarantining — the envelope is good, just early (found $_q)"
done
red_case "reconcile defers a still-running job's envelope instead of filing it as a completion report"

kill "$live_engine_pid" 2>/dev/null || true
wait "$live_engine_pid" 2>/dev/null || true
kill -0 "$live_engine_pid" 2>/dev/null && fail "sanity: the fixture engine pid should be gone"

# Deferral makes a dead job's manifest reachable by gc with its envelope still
# unreconciled (`jobs check` kills a job that stalls AFTER filing its report).
# gc must spare it, exactly as the orphan sweep already spares pack/request
# litter with a pending spool file: reaping it here would strand real
# evidence, and the next reconcile would quarantine it as `unknown-job`.
"$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null
[ -f "$mlive" ] || fail "T031: gc must spare a dead job's manifest while its envelope is still waiting in the spool"
[ -f "$live_out" ] || fail "T031: gc must not touch the pending spool envelope either"

# ...and now the envelope reconciles normally.
live_line2="$("$ORCHID_BIN" jobs reconcile)"
assert_match "TDEFER	ok" "$live_line2" "T031: the deferred envelope reconciles on the pass after the job exits"
[ -f ".orchid/reviews/TDEFER-a1-implementer.json" ] || fail "T031: the envelope is filed once its job has exited"
[ ! -f "$mlive" ] || fail "T031: the manifest is deleted once its envelope is genuinely reconciled"
green_case "the same envelope reconciles normally on the pass after its job exits — deferral delays, never discards"

# ---------------------------------------------------------------------------
# T031 (attempt-4 rework): THE LAUNCH/RECONCILE RACE. The deferral above asks
# whether the job has exited. A pid of 0 is not an answer to that question:
# `jobs prepare` mints every manifest with pid 0 and runners/orchid-launch
# stamps the real pid only AFTER the spawn, so pid 0 means "nobody has
# recorded whether this began" -- an UNRESOLVED STARTUP STATE. Reading it as
# an exit re-opens T013's race one launcher-window narrower: an engine running
# with its pid recorded nowhere still commits, and its envelope would still be
# filed as final.
#
# Deterministic, and no live process is involved: the whole class is pid 0, so
# what decides it is the LOG -- exactly the handle `prepare`, `gc`, `check`
# and the driver's drive_job_outstanding already use for this manifest shape,
# and exactly the one TDUPLOG above turns on. Fresh log = the post-spawn/
# pre-stamp window, something is writing right now.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TSTART "envelope filed inside the launcher window" >/dev/null
mstart="$("$ORCHID_BIN" jobs prepare TSTART implementer implement)"
start_jid="$(jq -r .job_id "$mstart")"
start_out="$(jq -r .output "$mstart")"
start_log="$(jq -r .log "$mstart")"
assert_eq 0 "$(jq -r '.pid // 0' "$mstart")" \
  "sanity: prepare mints a manifest with no pid — the launcher stamps it later"
mkdir -p "$(dirname "$start_log")"; printf 'engine is running\n' > "$start_log"
printf '{"contract":1,"job_id":"%s","task":"TSTART","operation":"implement","status":"ok","summary":"filed early"}' \
  "$start_jid" > "$start_out"

start_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "^deferred: " "$start_line" \
  "T031: pid 0 with a fresh log is a job that has not resolved, so its envelope is deferred, not filed"
assert_match "still starting" "$start_line" \
  "T031: and the line names the startup window rather than claiming a live pid it does not have"
[ -f "$start_out" ] || fail "T031: the deferred envelope must stay in the spool"
[ -f "$mstart" ] \
  || fail "T031: the manifest must survive — inside the launcher window it is the ONLY handle on an engine whose pid is recorded nowhere"
[ ! -f ".orchid/reviews/TSTART-a1-implementer.json" ] \
  || fail "T031: an envelope from the launcher window must not be filed as a completion report"
for _q in "$rt/quarantine/$start_jid.json".*; do
  [ -e "$_q" ] || continue
  fail "T031: deferring is not quarantining — the envelope is good, just early (found $_q)"
done
red_case "reconcile defers an envelope whose manifest is still inside the launcher's post-spawn/pre-stamp window"

# ---------------------------------------------------------------------------
# THE TWIN (T031 attempt-5 rework): THE LIVE, SILENT, UNTRACKED PROCESS. Same
# manifest, one thing changed -- the log has gone quiet past `stall_minutes`.
#
# That silence used to end the hold: the envelope reconciled and the manifest
# was deleted. But NOTHING HERE MEASURED AN EXIT. No pid was ever stamped, so
# there is nothing to `kill -0` and nothing to signal, and an engine that is
# alive and merely quiet -- a long model call writes nothing for many minutes
# -- leaves exactly these bytes on disk. Reading them as "it finished" files a
# mid-flight report as a completion signal over a process that is still
# committing, which is T013's defect with a stale log in place of a live pid.
#
# The state below is therefore deliberately AMBIGUOUS, and that is the whole
# assertion: reconcile is not being asked to notice a dead job, it is being
# asked NOT TO GUESS about one it cannot see. (Spawning a real silent process
# would add nothing — with its pid recorded nowhere, no reader could tell the
# difference, which is precisely why the guess is unsafe.)
#
# gc runs first, over a manifest that is now genuinely reapable (pid 0, log
# silent past stall_minutes, and the file itself backdated past the threshold),
# and must SPARE it anyway because its envelope is still spooled. A hold that
# could only be ended by a reap, and a reap that waits for the hold, would keep
# the envelope for each other forever.
touch -t 202001010000 "$start_log" "$mstart"
start_gc="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
assert_match "gc-pending $start_jid" "$start_gc" \
  "T031: gc names the hold-back rather than reaping a manifest whose envelope has not been filed"
[ -f "$mstart" ] || fail "T031: gc must spare the manifest while its envelope is still spooled"
start_line2="$("$ORCHID_BIN" jobs reconcile)"
assert_match "^unresolved: " "$start_line2" \
  "T031: a pid-0 job whose log went quiet has not been shown to EXIT, so its envelope is not a completion signal"
assert_match "silence is not an exit" "$start_line2" \
  "T031: and the line says why it is refusing rather than reporting a job it watched finish"
[ ! -f ".orchid/reviews/TSTART-a1-implementer.json" ] \
  || fail "T031: an envelope from a process nobody can show has stopped must not be filed"
[ -f "$start_out" ] || fail "T031: HELD, not discarded — the envelope stays spooled for the pass that can admit it"
[ -f "$mstart" ] \
  || fail "T031: and the manifest stays standing — it is the only handle on that job, and what the driver escalates over"
red_case "log staleness is not an exit: a pid-0 job that has gone silent has its envelope held, never filed"

# ...AND THE HOLD ENDS ON THE POSITIVE RECORD, which is what keeps it from
# being the new forever. runners/orchid-launch wraps the engine in a subshell
# that outlives it by exactly one write, so `runtime/exits/<job-id>` exists
# BECAUSE the process ended (T040) -- the one fact about this job that says so.
# Its arrival needs no operator: if that engine really was alive and quiet, the
# very next pass after it exits files the report it already wrote.
mkdir -p "$rt/exits"; printf '0\n' > "$rt/exits/$start_jid"
start_line3="$("$ORCHID_BIN" jobs reconcile)"
assert_match "TSTART	ok" "$start_line3" \
  "T031: with the engine's own exit recorded, the job HAS exited and its envelope reconciles"
[ -f ".orchid/reviews/TSTART-a1-implementer.json" ] || fail "T031: the held envelope is filed, not lost"
[ ! -f "$mstart" ] || fail "T031: the manifest is deleted once its envelope is genuinely reconciled"
green_case "a positive exit record ends the hold — the refusal is about evidence, not about waiting forever"

# The other pid-0 shape: NO log at all. The spawn line was provably never
# reached, so nothing is starting and nothing ever will. It must reconcile on
# the FIRST pass — this is the arm that proves the new "pid 0 is unresolved"
# reading did not turn every unstamped manifest into a permanent hold.
"$ORCHID_BIN" task create TNOLOG "envelope whose manifest never reached the spawn line" >/dev/null
mnolog="$("$ORCHID_BIN" jobs prepare TNOLOG implementer implement)"
nolog_jid="$(jq -r .job_id "$mnolog")"
[ ! -e "$(jq -r .log "$mnolog")" ] || fail "sanity: prepare must not create the job log — the launcher does, by redirecting the spawn into it"
printf '{"contract":1,"job_id":"%s","task":"TNOLOG","operation":"implement","status":"ok","summary":"no log ever appeared"}' \
  "$nolog_jid" > "$(jq -r .output "$mnolog")"
nolog_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "TNOLOG	ok" "$nolog_line" \
  "T031: pid 0 with no log is resolved — no engine ran and none will — so its envelope reconciles immediately"
[ ! -f "$mnolog" ] || fail "T031: and its manifest is deleted, exactly as before"
green_case "pid 0 with no log still reconciles on the first pass — the startup hold covers the launcher window only"

# ---------------------------------------------------------------------------
# T031 attempt-6 rework -- `jobs record-exit`: THE OPERATOR'S HALF OF THE HOLD,
# AS A VERB.
#
# The hold above ends by itself if that engine exits, because the launcher's
# wrapper records the status. For the class the driver escalates as `untracked`
# it never will: nothing ever waited on that process, so no wrapper is going to
# write anything about it, and the only remaining witness is a human who looks
# at the process table. Before this verb existed the boundary asked them to
# `printf` a number straight into `.orchid/runtime/exits/<job-id>` -- a
# hand-edit of the single fact this whole task protects, with nothing between a
# mistyped job id and a filed report.
#
# So the write moves behind a verb, and the verb is the checks: the id is held
# to the shape `jobs prepare` mints BEFORE it becomes a path, the job must still
# be outstanding, its liveness must actually be the unresolved state the
# boundary is about, and a record the process itself wrote is never replaced.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TRECX "an engine nobody can see, and the operator who looked" >/dev/null
mrecx="$("$ORCHID_BIN" jobs prepare TRECX implementer implement)"
recx_jid="$(jq -r .job_id "$mrecx")"
recx_out="$(jq -r .output "$mrecx")"
recx_log="$(jq -r .log "$mrecx")"
mkdir -p "$(dirname "$recx_log")"; printf 'engine is talking\n' > "$recx_log"
printf '{"contract":1,"job_id":"%s","task":"TRECX","operation":"implement","status":"ok","summary":"filed by a job nobody can see"}' \
  "$recx_jid" > "$recx_out"

# A FRESH LOG IS NOT THIS CLASS. Something is writing right now, so the one
# thing this verb states -- that the process has stopped -- is the one thing
# nobody can say. Refused, and refused by naming what does answer it.
rc=0; recx_err="$("$ORCHID_BIN" jobs record-exit "$recx_jid" 0 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: record-exit must refuse a job whose log is still moving (out: $recx_err)"
assert_match "stall_minutes" "$recx_err" \
  "T031: and the refusal names the window it is inside rather than a bare no (got: $recx_err)"
[ ! -e "$rt/exits/$recx_jid" ] || fail "T031: a refused record-exit must write nothing"

# Now the state the boundary is actually about: silent past `stall_minutes`,
# envelope spooled, no exit recorded anywhere.
touch -t 202001010000 "$recx_log" "$mrecx"
assert_match "^unresolved: " "$("$ORCHID_BIN" jobs reconcile)" \
  "sanity: this is the held class -- reconcile refuses to read the silence as an exit"

# THE ID BECOMES A PATH, so it is validated as an id first. `..` in a job id is
# the shape that would put this write anywhere on disk.
rc=0; recx_err="$("$ORCHID_BIN" jobs record-exit "../../escaped" 0 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: record-exit must refuse a job id that is not one (out: $recx_err)"
# Where `$rt/exits/../../escaped` would have landed, had the id been allowed to
# build a path before it was checked.
[ ! -e "$rt/../escaped" ] || fail "T031: a traversing job id must not reach a write path at all"
rc=0; recx_err="$("$ORCHID_BIN" jobs record-exit "j-e1-TGHOST-a1-deadbeef" 0 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: record-exit must refuse a job with no manifest (out: $recx_err)"
assert_match "no outstanding job" "$recx_err" \
  "T031: and says the job is not outstanding, rather than minting a record nothing will read (got: $recx_err)"
rc=0; recx_err="$("$ORCHID_BIN" jobs record-exit "$recx_jid" 300 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: record-exit must refuse an exit code outside 0-255 (out: $recx_err)"
rc=0; recx_err="$("$ORCHID_BIN" jobs record-exit "$recx_jid" "killed" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: record-exit must refuse an exit code that is not a number (out: $recx_err)"
[ ! -e "$rt/exits/$recx_jid" ] || fail "T031: none of those refusals may have written a record"
[ -f "$recx_out" ] || fail "T031: and none of them may have disturbed the held envelope"
red_case "record-exit refuses a live-looking job, an id that is not one, a job that is not outstanding, and a code that is not an exit status — writing nothing in every case"

# THE HAPPY PATH: an operator who has looked and found no such process.
# 2>&1, so the advisory is asserted rather than left to leak into the suite's
# own stderr — a passing fixture that prints to stderr is what a rework brief
# later scrapes and hands an implementer as a failure to fix.
recx_ok="$("$ORCHID_BIN" jobs record-exit "$recx_jid" 137 2>&1)"
assert_match "recorded-exit $recx_jid 137" "$recx_ok" \
  "T031: the verb reports the record it wrote (got: $recx_ok)"
assert_match "next .orchid jobs reconcile" "$recx_ok" \
  "T031: and tells the operator what admits the held report now (got: $recx_ok)"
[ -f "$rt/exits/$recx_jid" ] || fail "T031: and the record is where every reader of it looks"
assert_eq 137 "$(head -n1 "$rt/exits/$recx_jid")" \
  "T031: line 1 is the exit code and nothing else — job_exit_code reads exactly that and rejects any non-digit"
assert_match "recorded-by: operator" "$(cat "$rt/exits/$recx_jid")" \
  "T031: and the record says a human wrote it — a launcher-written one is a process reporting its own status, and after the write nothing else on disk tells the two apart"

# NEVER REPLACED. Overwriting a record with a second opinion is the same
# substitution this task exists to close, one file further down.
rc=0; recx_err="$("$ORCHID_BIN" jobs record-exit "$recx_jid" 0 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: a second record-exit over an existing record must be refused (out: $recx_err)"
assert_eq 137 "$(head -n1 "$rt/exits/$recx_jid")" "T031: and the record on file is untouched"

# ...and the hold ends, through exactly the path the launcher's own write uses.
recx_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "TRECX	ok" "$recx_line" \
  "T031: with the operator's finding on record the job has resolved, and its held envelope files (got: $recx_line)"
[ -f ".orchid/reviews/TRECX-a1-implementer.json" ] || fail "T031: the held envelope is filed, not lost"
[ ! -f "$mrecx" ] || fail "T031: and its manifest is deleted, exactly as any reconciled job's is"
green_case "record-exit ends the hold through the same record the launcher writes — the envelope files on the next reconcile, with nothing hand-edited"

# The `exited` arm, which is a refusal for the opposite reason: a pid-0 manifest
# with no log at all never reached the spawn line, so it is already resolved and
# reconciles on its own. There is nothing for an operator to find, and saying so
# is better than accepting a record that changes nothing.
"$ORCHID_BIN" task create TRECY "a job that never reached the spawn line" >/dev/null
mrecy="$("$ORCHID_BIN" jobs prepare TRECY implementer implement)"
recy_jid="$(jq -r .job_id "$mrecy")"
[ ! -e "$(jq -r .log "$mrecy")" ] || fail "sanity: prepare must not create the job log"
rc=0; recy_err="$("$ORCHID_BIN" jobs record-exit "$recy_jid" 1 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: record-exit must refuse a job that is already resolved (out: $recy_err)"
assert_match "already resolved" "$recy_err" \
  "T031: and names that, rather than accepting a finding about a job nothing was ever running for (got: $recy_err)"
[ ! -e "$rt/exits/$recy_jid" ] || fail "T031: and writes nothing for it"
red_case "record-exit is admitted only for the unresolved class — an already-resolved job is refused, not overwritten with a finding it does not need"
# T033 (dogfood F32, reproduced independently in r-002): A NON-APPROVE VERDICT
# MUST CARRY A FINDING THE SEVERITY GATE CAN SEE.
#
# The shape: `verdict: request-changes`, `findings: []`, and the entire
# substance of the objection in the free-text `summary`. Filed that way, the
# envelope contributes NOTHING to any severity-based gate -- lib/drive.sh's
# approve arm reports "no finding at or above <severity>" by reading
# findings[], and it read an empty array. The danger is not the disagreement
# (a request-changes verdict blocks on its own); it is the AGREEMENT, where a
# reviewer approves while keeping the same prose caveat and the field the gate
# consults is empty.
#
# `orchid jobs reconcile` is where that closes, because it is the one place
# every envelope passes through on its way to becoming durable evidence. The
# pair below is fed to the GATE ITSELF (drive_envelope_has_blocking_finding,
# lib/drive.sh), not to a proxy for it, before and after filing.
# ---------------------------------------------------------------------------
# Sourced for the gate function alone; lib/drive.sh defines functions and
# three constants at source time and reads nothing. Last block in this file,
# so nothing downstream inherits the sourced definitions.
source "$REPO_ROOT/lib/drive.sh"
# `critic` (declared above, capabilities=structured_text) satisfies the
# reviewer role's own `requires=structured_text`, so prepare resolves it
# rather than refusing at the door with exit 14. This is the only
# `role.reviewer=` line in this fixture's config, so last-wins settles nothing
# here.
printf 'role.reviewer=critic\n' >> orchid.config

objection="prepareBackupAttempt() can return run_id 0 after a best-effort startRun() failure, yet the handler still flushes started, so a committed running row is not guaranteed before the early response"

mrev="$("$ORCHID_BIN" jobs prepare T001 reviewer review)"
[ -f "$mrev" ] || fail "reviewer manifest written: role.reviewer=critic must resolve, or every assertion below is vacuous"
mrev_jid="$(jq -r .job_id "$mrev")"; mrev_out="$(jq -r .output "$mrev")"
jq -n --arg jid "$mrev_jid" --arg s "$objection" \
  '{contract:1, job_id:$jid, task:"T001", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:$s, findings:[]}' \
  > "$mrev_out"

# The defect itself, demonstrated on the envelope exactly as the reviewer
# wrote it: the gate has nothing to weigh. Kept aside because reconcile is
# about to consume the spool copy.
cp "$mrev_out" "$WORK/asfiled-request-changes.json"
if drive_envelope_has_blocking_finding "$WORK/asfiled-request-changes.json" medium; then
  fail "fixture is not the defect: the as-written prose-only objection already carries a blocking finding"
fi

rev_line="$("$ORCHID_BIN" jobs reconcile)"
filed=".orchid/reviews/T001-a1-reviewer.json"
# FILED, never quarantined: the shipped verdict-only review adapters write
# `findings: []` verbatim on every review, so rejecting this envelope would
# throw a legitimate objection away and leave the task short of its review
# count with nothing for the operator to read.
[ -f "$filed" ] || fail "a request-changes review with an empty findings[] must still be filed -- quarantining it would destroy the objection it carries"
assert_match "synthesized-finding: T001-a1-reviewer[.]json" "$rev_line" \
  "reconcile says out loud that it composed a finding: a prose-only objection is accepted, never silently"
assert_eq "1" "$(jq '.findings | length' "$filed")" \
  "the filed envelope carries one finding synthesized from its summary"
assert_eq "high" "$(jq -r '.findings[0].severity' "$filed")" \
  "synthesized at high severity -- the one value no task's blocking_severity can filter out"
assert_match "prepareBackupAttempt" "$(jq -r '.findings[0].title' "$filed")" \
  "the synthesized finding carries the reviewer's own words, not a paraphrase"
assert_match "synthesized from summary" "$(jq -r '.findings[0].title' "$filed")" \
  "and says on its face that the kernel composed it, so it is never read as the reviewer's own severity call"
assert_eq "true" "$(jq -r '.findings[0].synthesized' "$filed")" "the entry is marked synthesized"
assert_eq "$objection" "$(jq -r '.findings[0].detail' "$filed")" \
  "the summary survives WHOLE in detail, so the truncated title costs nothing"
assert_eq "$objection" "$(jq -r '.summary' "$filed")" \
  "and the reviewer's own summary is left exactly as it was written"
drive_envelope_has_blocking_finding "$filed" high \
  || fail "the synthesized finding must reach the severity gate even at the strictest threshold"
red_case "a request-changes envelope with findings: [] reaches the severity gate: reconcile lifts its summary into a high-severity finding instead of filing an empty array the gate weighs as nothing"

# The twin, and the reason the check above is detection rather than a rule
# that rewrites every envelope it sees: an APPROVING review with an empty
# findings[] is the ordinary output of every verdict-only adapter and must
# pass through untouched. The trigger is WITHHELD APPROVAL, not an empty
# array.
mrev2="$("$ORCHID_BIN" jobs prepare T001 reviewer review)"
mrev2_jid="$(jq -r .job_id "$mrev2")"; mrev2_out="$(jq -r .output "$mrev2")"
jq -n --arg jid "$mrev2_jid" \
  '{contract:1, job_id:$jid, task:"T001", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"scope covered, nothing to report", findings:[]}' \
  > "$mrev2_out"
rev2_line="$("$ORCHID_BIN" jobs reconcile)"
filed2=".orchid/reviews/T001-a1-reviewer.2.json"
[ -f "$filed2" ] || fail "the approving review is filed under the collision suffix, same attempt"
assert_eq "0" "$(jq '.findings | length' "$filed2")" \
  "an approving review that found nothing keeps its empty findings[] -- reporting no findings is a valid review"
case "$rev2_line" in
  *"synthesized-finding: T001-a1-reviewer.2.json"*)
    fail "reconcile synthesized a finding into an APPROVING review: the trigger must be a withheld verdict, not an empty array" ;;
esac
drive_envelope_has_blocking_finding "$filed2" medium \
  && fail "an approving review with no findings must not block: nothing may be invented into it"
green_case "an approving review with findings: [] is filed byte-for-byte as written, and still blocks nothing"
