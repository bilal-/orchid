#!/usr/bin/env bash
# v1-m2 Task 8: runners/orchid-pump -- the LLM-free front gate that decides
# whether an abandoned run is worth waking. It never builds a prompt or reads
# an envelope; it only checks init state, run_status, lease staleness, and
# (dry-check only) whether an orchestrator engine is currently resolvable,
# then `exec`s runners/orchid-tick (Task 7) to do the real work.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
export ORCHID_ROOT="$REPO_ROOT"

cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"; mkdir -p "$HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"; mkdir -p "$WORK/eng"
PUMP="$REPO_ROOT/runners/orchid-pump"

# mk_stub_engine <name> -- a stub orchestrator engine (capabilities=shell,git
# matches roles/orchestrator.role's requires=shell,git). requires_binaries=jq
# is just a representative populated value here, not a required workaround --
# the bash-3.2 empty-CSV/array quirk this used to sidestep is fixed directly
# in lib/manifest.sh's _manifest_split_csv now (see its own header comment;
# tests/test_failover.sh's mk_engine demonstrates the fix by dropping this
# key entirely). Its `run` touches a
# per-engine marker file (so a scenario can assert exactly which engine, if
# any, was actually spawned) and writes a valid `ok` orchestrate envelope.
mk_stub_engine() {
  local name="$1"
  local dir="$WORK/eng/$name"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
    "$name" > "$dir/plugin.conf"
  {
    echo '#!/usr/bin/env bash'
    echo "set -eu"
    echo "MARKER=$(printf '%q' "$WORK/marker-$name")"
  } > "$dir/run"
  cat >> "$dir/run" <<'EOF'
touch "$MARKER"
req="$1"; out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"orchestrate","status":"ok","actions":[],"summary":"pump stub ok"}' \
  "$jid" "$task" > "$out"
EOF
  chmod +x "$dir/run"
}

# write_lease <age_seconds> -- plants .orchid/runtime/lease.json with
# refreshed_at set to now-<age_seconds> (portable GNU/BSD date, same idiom as
# lib/ledger.sh's _ledger_epoch_to_iso).
write_lease() {
  local age="$1" now target iso
  now="$(date -u +%s)"; target=$((now - age))
  iso="$(date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p .orchid/runtime
  jq -n --arg t "$iso" '{epoch:1, refreshed_at:$t}' > .orchid/runtime/lease.json
}

cur_epoch() { cat .orchid/runtime/epoch 2>/dev/null || echo 0; }

# write_released_lease <age_seconds> -- like write_lease, but additionally
# sets `released: true` (v1-m4: orchid run release-lease, PROTOCOL.md
# COMPLETION's clean-session-exit affordance). refreshed_at is still stamped
# at now-<age_seconds> exactly like write_lease -- the point of every test
# using this helper is that the pump must treat it as stale regardless of
# how FRESH that timestamp is, not because it happens to also be old.
write_released_lease() {
  local age="$1" now target iso
  now="$(date -u +%s)"; target=$((now - age))
  iso="$(date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p .orchid/runtime
  jq -n --arg t "$iso" '{epoch:1, refreshed_at:$t, released:true}' > .orchid/runtime/lease.json
}

# ===========================================================================
# A -- uninitialized dir (no .orchid/tasks, no journal.md, no roadmap.md):
# exit 0, and the pump must say so plainly rather than let the tick's "not
# initialized" die (exit 1) leak through.
# ===========================================================================
out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 on an uninitialized repo"
assert_eq "pump: not an orchid repo" "$out" "pump names an uninitialized repo plainly"

# ===========================================================================
# A1 -- split-brain checkout, journal-only variant (v1-m3 Task 2 review
# fix): ONLY .orchid/journal.md exists (no tasks dir, no roadmap.md) -- a
# task verb wrote a journal entry against the wrong checkout without ever
# creating a task. Arm 1's uninitialized condition must be the exact
# complement of orchid_split_brain (tasks OR journal, roadmap absent), so
# this must reach the split-brain arm below, not be swallowed as "not an
# orchid repo".
# ===========================================================================
mk_stub_engine stubjournal
printf 'role.orchestrator=stubjournal\n' > orchid.config
mkdir -p .orchid
echo "# Journal" > .orchid/journal.md
rm -f "$WORK/marker-stubjournal"

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 on a journal-only split-brain checkout"
assert_eq "pump: no roadmap in this checkout (split-brain — run from the integration branch)" "$out" \
  "pump treats a journal-only checkout as split-brain, not as uninitialized"
[ -f "$WORK/marker-stubjournal" ] && fail "pump must not spawn anything on a journal-only split-brain checkout"
rm -f .orchid/journal.md

# ===========================================================================
# A1b -- a genuinely empty .orchid/ dir (the directory itself exists on
# disk, but none of tasks/, journal.md, or roadmap.md exist inside it) is
# still "not an orchid repo" -- confirms the arm-1 fix widened the check to
# journal.md without broadening it any further than that.
# ===========================================================================
mkdir -p .orchid
out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 on a truly empty .orchid dir"
assert_eq "pump: not an orchid repo" "$out" "an empty .orchid dir (no tasks/journal/roadmap) is still not an orchid repo"

mkdir -p .orchid/tasks

# ===========================================================================
# A2 -- split-brain checkout (v1-m3 Task 2, F7): .orchid/tasks/ exists (a
# task verb built untracked state against this checkout) but roadmap.md is
# absent (durable state lives only on the integration branch). Distinct
# from BOTH "not an orchid repo" (arm 1, above -- that requires tasks AND
# roadmap both absent) and "run complete" (arm 3, below -- that requires a
# roadmap to even read run_status from). Never spawns.
# ===========================================================================
mk_stub_engine stubsplit
printf 'role.orchestrator=stubsplit\n' > orchid.config
rm -f .orchid/roadmap.md "$WORK/marker-stubsplit"

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 on a split-brain checkout"
assert_eq "pump: no roadmap in this checkout (split-brain — run from the integration branch)" "$out" \
  "pump names the split-brain condition distinctly from run complete"
[ -f "$WORK/marker-stubsplit" ] && fail "pump must not spawn anything on a split-brain checkout"

# ===========================================================================
# B -- run_status complete: nothing spawned, regardless of lease/engine
# state (refuses to spend quota / spawn anything on a finished run).
# ===========================================================================
mk_stub_engine stubcomplete
printf -- '---\nrun_status: complete\nrun_id: r-pump\n---\n# Roadmap\n' > .orchid/roadmap.md
printf 'role.orchestrator=stubcomplete\n' > orchid.config
rm -f "$WORK/marker-stubcomplete"
write_lease 999999   # deliberately stale -- must not matter when run_status is complete

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 when run_status is complete"
assert_eq "pump: run complete" "$out" "pump reports run complete verbatim"
[ -f "$WORK/marker-stubcomplete" ] && fail "pump must not spawn anything when run_status is complete"

# ===========================================================================
# B2 -- run_status planning + NO lease.json at all (exactly the state right
# after a fresh `orchid init`, before any run has ever started) + a healthy
# orchestrator: the pump must NOT treat a missing lease as stale here.
# PLANNING is reserved for interactive drafting (PROTOCOL.md) -- a bare "no
# lease yet" must read as "no run has started," never as "abandoned run,
# wake it up." No spawn, exit 0, a clear message naming the run_status.
# ===========================================================================
mk_stub_engine stubplanning
printf -- '---\nrun_status: planning\nrun_id: r-pump\n---\n# Roadmap\n' > .orchid/roadmap.md
printf 'role.orchestrator=stubplanning\n' > orchid.config
rm -f .orchid/runtime/lease.json "$WORK/marker-stubplanning"

rc=0
out="$("$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "pump must refuse a runnable repo without unattended trust"
assert_match 'unattended pump refused: unattended trust is denied' "$out" \
  "pump refusal names the unattended trust gate"
[ -f "$WORK/marker-stubplanning" ] && fail "untrusted pump must never spawn an engine"

rm -f .orchid/runtime/pump.log
rc=0
out="$("$PUMP" --service-log 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "service-mode pump must refuse a runnable repo without unattended trust"
assert_match 'unattended pump refused: unattended trust is denied' "$out" \
  "service-mode refusal is still available before its internal log is opened"
[ ! -e .orchid/runtime/pump.log ] \
  || fail "untrusted service-mode pump must not create or open pump.log"

# A real scheduler discards this stderr (`>> /dev/null 2>&1` in the cron line,
# /dev/null StandardOutPath+StandardErrorPath in the launchd agent) and the
# repo-local pump.log above is deliberately not opened before the gate. Without
# a machine-local copy the operator would see a service that runs on schedule
# and silently does nothing. Assert the copy exists, is outside the repository,
# and names the surface and the reason.
refusal_log="$MACHINE_HOME/.orchid/unattended-trust/refusals.log"
[ -f "$refusal_log" ] \
  || fail "a scheduled refusal must be recorded in the machine-local trust store"
refusal_entry="$(tail -n 1 "$refusal_log")"
assert_match 'unattended pump' "$refusal_entry" \
  "the machine-local refusal names the refused surface"
assert_match 'unattended trust' "$refusal_entry" \
  "the machine-local refusal carries the gate's own reason"
[ ! -e "$WORK/.orchid/runtime/refusals.log" ] \
  || fail "refusal diagnostics must never be written inside the untrusted target"

# The interactive pump prints to the caller's terminal and must NOT append to
# the machine-local log: an operator who can see the refusal does not need it
# duplicated into shared machine state.
refusal_lines_before="$(wc -l < "$refusal_log")"
rc=0
"$PUMP" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "interactive pump must still refuse an untrusted repo"
assert_eq "$refusal_lines_before" "$(wc -l < "$refusal_log")" \
  "an interactive refusal does not append to the machine-local diagnostic log"

HOME="$HOME" "$ORCHID_BIN" trust unattended "$WORK" --reason "pump test fixture" >/dev/null \
  || fail "pump fixture acknowledgement must succeed"

out="$("$PUMP" --service-log 2>&1)"; rc=$?
assert_eq 0 "$rc" "trusted service-mode pump exits 0 when planning has no lease"
assert_eq "" "$out" "trusted service-mode diagnostics move from scheduler output into pump.log"
assert_match '^pump: run not running \(planning\), no lease yet$' \
  "$(cat .orchid/runtime/pump.log)" \
  "service-mode pump begins repo-local logging after trust succeeds"

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 when run_status is planning and no lease exists"
assert_eq "pump: run not running (planning), no lease yet" "$out" \
  "pump names the non-running run_status rather than treating a missing lease as stale"
[ -f "$WORK/marker-stubplanning" ] && fail "pump must NEVER autonomously tick during planning, even with a healthy engine configured"

# ===========================================================================
# B3 -- v1.1 Track 2, the headline change: the pump runs the DETERMINISTIC
# DRIVER first and wakes an LLM only for a named judgment boundary. With a
# stale lease, a healthy orchestrator engine configured, and nothing for
# deterministic policy to stop on, the driver completes the pass and NO
# engine is spawned at all -- the quota is simply not spent.
# ===========================================================================
printf -- '---\nrun_status: running\nrun_id: r-pump\n---\n# Roadmap\n' > .orchid/roadmap.md
mk_stub_engine stubnodrive
printf 'role.orchestrator=stubnodrive\n' > orchid.config
write_lease 1000
rm -f "$WORK/marker-stubnodrive"

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 when the deterministic driver completed the pass"
assert_match "pump: deterministic drive completed the pass, no judgment boundary" "$out" \
  "the pump says the driver handled it, in so many words"
[ -f "$WORK/marker-stubnodrive" ] \
  && fail "an LLM orchestrator must NOT be woken when deterministic policy resolved the pass"

# ===========================================================================
# B4 -- a boundary an ORCHESTRATOR cannot move must not wake one. A `blocked`
# task raises the same record on every pass until a human runs `task
# unblock`/`task retry` — verbs the broker refuses — so waking a model for it
# spends a wakeup per pump cycle re-reading a record and changing nothing. The
# driver still records the boundary AND raises the blocker that actually
# reaches a human; the pump simply declines the hand-off.
# ===========================================================================
mk_stub_engine stubparked
printf 'role.orchestrator=stubparked\n' > orchid.config
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T000 "needs a human" >/dev/null
"$ORCHID_BIN" task advance T000 blocked --reason "fixture: parked for a human" >/dev/null
unset ORCHID_EPOCH
write_lease 1000
rm -f "$WORK/marker-stubparked"

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 on an operator-only boundary (a wait state, not an error)"
assert_match "pump: judgment boundary \[blocked-task\] is operator-only — not waking an orchestrator" "$out" \
  "the pump says which boundary it declined to wake a model for"
[ -f "$WORK/marker-stubparked" ] \
  && fail "no LLM may be woken for a decision no admitted verb can make"
rc=0; "$ORCHID_BIN" run boundary show >/dev/null 2>&1 || rc=$?
assert_eq 16 "$rc" "the boundary stays recorded — declining to wake a model is not resolving it"
assert_match "judgment boundary \[blocked-task\]" "$(cat .orchid/BLOCKERS.md)" \
  "the driver raised the blocker that does reach a human, exactly once for this record"
blockers_after_first="$(wc -l < .orchid/BLOCKERS.md)"
write_lease 1000   # the driver refreshed it; re-stale so the pass really re-runs
out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "a repeated pump pass over the same operator-only boundary is still a no-op"
assert_eq "$blockers_after_first" "$(wc -l < .orchid/BLOCKERS.md)" \
  "and raises no second blocker for a record that has not changed"

# From here on the fixture ALSO carries a task parked at `arbitrating` over a
# request-changes review: a `review-conflict` boundary, the kind one `orchid
# task arbitrate` settles and the broker admits. It outranks the blocked task
# above (which is never hidden, just deprioritized), and it is what lets the
# arms below go on exercising the LLM hand-off itself.
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 "contested review" >/dev/null
unset ORCHID_EPOCH
PUMP_CAND=6666666666666666666666666666666666666666
fm_set "$WORK/.orchid/tasks/T001.md" status arbitrating
fm_set "$WORK/.orchid/tasks/T001.md" candidate_sha "$PUMP_CAND"
mkdir -p "$WORK/.orchid/reviews"
jq -n --arg cand "$PUMP_CAND" \
  '{contract:1, job_id:"j-fixture-T001", task:"T001", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:"fixture review",
    candidate_sha:$cand, findings:[]}' > "$WORK/.orchid/reviews/T001-a1-reviewer.json"

# From here to the end of this file, EVERY arm re-drives that same unchanged
# review-conflict boundary, because each one is about something else entirely
# (lease freshness, a released lease, failover, engine eligibility) and reuses
# one fixture to get there. That is more consecutive passes over one unmoved
# boundary than the wake budget allows: `pump_wake_max` (config, default 3)
# exists precisely so a boundary nothing is moving stops waking a model, and
# under the default these arms would stop asserting what they were written to
# assert -- a declined wake would look like a failover bug.
#
# So every `orchid.config` written below raises it out of the way. The budget's
# own RED/GREEN pair lives in tests/test_run.sh, against a fixture built for
# it; suppressing it here keeps these arms testing the one thing each is for.
PUMP_NO_BUDGET='pump_wake_max=99'

# Sanity: the driver really does stop on it, with the dedicated exit code.
rc=0; drive_out="$(ORCHID_REPO="$WORK" "$REPO_ROOT/runners/orchid-drive" 2>&1)" || rc=$?
assert_eq 16 "$rc" "a contested review parks the deterministic driver at a judgment boundary"
assert_match "boundary \[review-conflict\] T001" "$drive_out" "the boundary names the contested task"
assert_match "boundary \[blocked-task\] T000" "$drive_out" \
  "the blocked task is still noted on the pass — deprioritized, never hidden"

# ===========================================================================
# C -- fresh lease: run_status running, lease refreshed moments ago -- a live
# orchestrator owns this run; the pump must not spawn the tick.
# ===========================================================================
printf -- '---\nrun_status: running\nrun_id: r-pump\n---\n# Roadmap\n' > .orchid/roadmap.md
mk_stub_engine stubfresh
printf 'role.orchestrator=stubfresh\n%s\n' "$PUMP_NO_BUDGET" > orchid.config
write_lease 5
rm -f "$WORK/marker-stubfresh"

out="$("$PUMP" 2>&1)"; rc=$?
assert_eq 0 "$rc" "pump exits 0 when the lease is fresh"
assert_match '^pump: lease fresh \([0-9]+s\)$' "$out" "pump prints the lease-fresh message with the observed age"
[ -f "$WORK/marker-stubfresh" ] && fail "pump must not spawn the tick while the lease is fresh"

# ===========================================================================
# C2 -- v1-m4 Task 2 (the "no clean-exit affordance" incident): a RELEASED
# lease (orchid run release-lease) whose refreshed_at is only moments old
# must still be treated as immediately stale -- the session that wrote it
# is genuinely gone, not merely between refreshes. Before this fix, an
# operator had to wait out pump_stale_s (or hand-backdate lease.json) even
# though the session itself had already cleanly signaled it was done.
# ===========================================================================
mk_stub_engine stubreleased
printf 'role.orchestrator=stubreleased\n%s\n' "$PUMP_NO_BUDGET" > orchid.config
write_released_lease 5   # fresh by age alone -- released must override that
rm -f "$WORK/marker-stubreleased"
epoch_before="$(cur_epoch)"

out="$("$PUMP" 2>&1)"; rc=$?
epoch_after="$(cur_epoch)"

assert_eq 0 "$rc" "pump exits 0 on a healthy ok tick when the lease is released"
[ -f "$WORK/marker-stubreleased" ] || fail "a released lease must be treated as immediately stale, even with a fresh refreshed_at"
[ "$epoch_after" -gt "$epoch_before" ] || fail "pump's tick fences a fresh epoch ($epoch_before -> $epoch_after)"

# ===========================================================================
# D -- stale lease + a healthy primary orchestrator engine: the tick runs
# (marker present, epoch bumped, tick's own exit code propagates as pump's).
# ===========================================================================
mk_stub_engine stubhealthy
printf 'role.orchestrator=stubhealthy\n%s\n' "$PUMP_NO_BUDGET" > orchid.config
write_lease 1000   # > default pump_stale_s (900)
epoch_before="$(cur_epoch)"

out="$("$PUMP" 2>&1)"; rc=$?
epoch_after="$(cur_epoch)"

assert_eq 0 "$rc" "pump exits 0 (the tick's own exit code) on a healthy ok tick"
[ -f "$WORK/marker-stubhealthy" ] || fail "pump execs the tick, which must spawn the healthy primary orchestrator"
[ "$epoch_after" -gt "$epoch_before" ] || fail "pump's tick fences a fresh epoch ($epoch_before -> $epoch_after)"
assert_match "tick: stubhealthy ok" "$out" "pump's output is the tick's own output (exec, not a wrapper)"

# ===========================================================================
# D2 -- run_status running + NO lease.json at all (crashed before its first
# refresh, unlike B2's planning case): explicitly pinning that a missing
# lease is stale-by-policy ONLY under `running` -- the tick fires.
# ===========================================================================
mk_stub_engine stubcrashed
printf 'role.orchestrator=stubcrashed\n%s\n' "$PUMP_NO_BUDGET" > orchid.config
rm -f .orchid/runtime/lease.json "$WORK/marker-stubcrashed"
epoch_before="$(cur_epoch)"

out="$("$PUMP" 2>&1)"; rc=$?
epoch_after="$(cur_epoch)"

assert_eq 0 "$rc" "pump exits 0 on a healthy ok tick when run_status running had no lease at all"
[ -f "$WORK/marker-stubcrashed" ] || fail "a missing lease under run_status running must be treated as stale (crashed before first refresh)"
[ "$epoch_after" -gt "$epoch_before" ] || fail "pump's tick fences a fresh epoch ($epoch_before -> $epoch_after)"

# ===========================================================================
# E -- stale lease + primary rate-limited + a capsuite-PASSED fallback: the
# tick runs on the FALLBACK (marker names the fallback engine specifically).
# Note: running the healthy-primary tick above (D) refreshed the lease via
# `orchid run resume` -- it must be staled again here.
# ===========================================================================
mk_stub_engine stubprime
mk_stub_engine stubfallback
printf 'role.orchestrator=stubprime,stubfallback\n%s\n' "$PUMP_NO_BUDGET" > orchid.config
ledger_mark "$WORK" stubprime rate_limited 999999
capsuite_run stubfallback orchestrator >/dev/null \
  || fail "sanity: capsuite_run should pass stubfallback for the orchestrator role (no dryrun op; static checks only)"
write_lease 1000
rm -f "$WORK/marker-stubprime" "$WORK/marker-stubfallback"

out="$("$PUMP" 2>&1)"; rc=$?

assert_eq 0 "$rc" "pump exits 0 on the fallback's ok tick"
[ -f "$WORK/marker-stubfallback" ] || fail "pump's tick must fail over to the capsuite-passed fallback"
[ -f "$WORK/marker-stubprime" ] && fail "the rate-limited primary must never be spawned"
assert_match "tick: stubfallback ok" "$out" "tick output names the fallback engine, not the primary"

# ===========================================================================
# F -- stale lease + primary rate-limited + fallback WITHOUT any capsuite
# record: no eligible engine at all -- exit 0 (cron-friendly wait state),
# nothing spawned, reason from resolve_role_available's stderr surfaced.
# ===========================================================================
mk_stub_engine stubprime2
mk_stub_engine stubfallback2
printf 'role.orchestrator=stubprime2,stubfallback2\n%s\n' "$PUMP_NO_BUDGET" > orchid.config
ledger_mark "$WORK" stubprime2 rate_limited 999999
write_lease 1000
rm -f "$WORK/marker-stubprime2" "$WORK/marker-stubfallback2"
epoch_before="$(cur_epoch)"

out="$("$PUMP" 2>&1)"; rc=$?
epoch_after="$(cur_epoch)"

assert_eq 0 "$rc" "pump exits 0 when no orchestrator engine is eligible (normal wait state, not an error)"
assert_match '^pump: no capable orchestrator available \(.+\)$' "$out" "pump surfaces resolve_role_available's disqualifier reason"
assert_match 'stubprime2' "$out" "the no-capable-orchestrator message names the disqualified primary"
assert_match 'stubfallback2' "$out" "the no-capable-orchestrator message names the unverified fallback"
[ -f "$WORK/marker-stubprime2" ] && fail "no engine must be spawned when none is eligible"
[ -f "$WORK/marker-stubfallback2" ] && fail "the unverified fallback must never be spawned"
# The deterministic driver needs no orchestrator engine at all, so it still
# ran (and fenced its own epoch) before the pump discovered there was nobody
# to wake for the boundary it found. That is the v1.1 ordering working as
# intended: mechanical progress never waits on model availability.
[ "$epoch_after" -gt "$epoch_before" ] \
  || fail "the deterministic driver runs regardless of orchestrator availability, so it fences an epoch ($epoch_before -> $epoch_after)"

# ===========================================================================
# G -- ONE TASK'S DECISION MUST NOT PARK THE OTHER TWENTY-NINE (lesson L026).
#
# `orchid drive` exits 16 as soon as ANY task needs an operator. That code
# means "a decision is outstanding somewhere", never "no further progress is
# possible" — and a pump that reads it the second way halts a whole roadmap
# over a decision affecting one task. It is not hypothetical: a run stopped at
# one review conflict at 07:32Z, the operator arbitrated within minutes but did
# not restart the pump, and twenty-eight unrelated tasks sat idle until 14:42Z.
# A pump that stops at the first arbitrable disagreement is attended operation
# wearing an unattended label.
#
# So ONE pump pass over a run holding a boundaried task AND a dispatchable one
# must do both halves:
#
#   1. REPORT the boundary — through the configured notify channel, in the same
#      invocation that found it. This is the RED half: `orchid notify` (tier-1)
#      only queues runtime/outbox/<qid>, and the pump used to drain that outbox
#      ONLY BEFORE the drive pass. The blocker the pass itself raised therefore
#      waited for whichever LATER invocation happened to drain next — and if the
#      operator stopped the pump at the boundary (exactly what "16 means stop"
#      invites), it was never sent at all. Before the fix the channel below is
#      never called and the message is still sitting in the outbox here.
#   2. CONTINUE — the unrelated task is dispatched by that very same pass, and
#      the invocation ends 0, a wait state rather than a failure. The driver
#      already walked every task; this pins that the pump neither swallows that
#      progress nor turns 16 into a halt, so the two cannot regress apart.
# ===========================================================================
KEEP="$WORK/keepgoing"
mkdir -p "$KEEP"
cd "$KEEP" || exit 1
git init -q .

# A stub `openclaw` on PATH, same shape as tests/test_notify_channel.sh's:
# captures argv, sends nothing real. It is the proof that the SEND happened —
# BLOCKERS.md alone would only prove `orchid notify` ran.
KEEPBIN="$WORK/keepbin"; mkdir -p "$KEEPBIN"
KEEP_OC_LOG="$WORK/keep-openclaw-calls.log"; : > "$KEEP_OC_LOG"
cat > "$KEEPBIN/openclaw" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$KEEP_OC_LOG"
exit 0
EOF
chmod +x "$KEEPBIN/openclaw"
export PATH="$KEEPBIN:$PATH"

# An implementer stub, so "kept advancing" means a real dispatch (worktree,
# launch, advance) and not a status hand-edited by the fixture.
mkdir -p "$WORK/eng/stubkeepimpl"
printf 'manifest_version=1\nid=test/stubkeepimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubkeepimpl/plugin.conf"
cat > "$WORK/eng/stubkeepimpl/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
worktree="$(jq -r .worktree "$req")"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
[ "$(jq -r .operation "$req")" = implement ] || exit 1
cd "$worktree" || exit 1
echo "stub implementation for $task" > stub_feature.txt
git add stub_feature.txt
git -c user.email=stub@example.invalid -c user.name="stub" commit -q -m "stub: implement $task"
sha="$(git rev-parse HEAD)"
jq -n --arg jid "$jid" --arg task "$task" --arg sha "$sha" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"stub implemented", commits:[$sha]}' > "$out"
EOF
chmod +x "$WORK/eng/stubkeepimpl/run"

# An orchestrator IS configured and resolvable here, deliberately: the point is
# that the pump declines to wake one for a decision it cannot make, not that
# there was nobody to wake.
{
  echo "role.orchestrator=stubparked"
  echo "role.implementer=stubkeepimpl"
  echo "notify.channel=slack"
  echo "notify.to=#ops"
  echo "send_retry_max=2"
} > orchid.config
git add -A
git commit -q -m "fixture: config"

export ORCHID_REPO="$KEEP"
"$ORCHID_BIN" init >/dev/null || fail "orchid init (keep-going fixture)"
git checkout -q orchid/integration
KEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$KEPOCH"
cat > "$WORK/requirements-keep.md" <<'EOF'
# Requirements
- REQ-1: one task waits for a human; every other task keeps moving.
EOF
"$ORCHID_BIN" requirements import "$WORK/requirements-keep.md" >/dev/null
"$ORCHID_BIN" task create K900 "parked on a human" >/dev/null
"$ORCHID_BIN" task create K901 "unrelated, and perfectly dispatchable" >/dev/null
"$ORCHID_BIN" task set K901 verification_commands true >/dev/null
"$ORCHID_BIN" plan apply --reason "initial plan" >/dev/null
"$ORCHID_BIN" task advance K900 blocked --reason "fixture: parked for a human" >/dev/null
unset ORCHID_EPOCH

HOME="$HOME" "$ORCHID_BIN" trust unattended "$KEEP" --reason "keep-going pump fixture" >/dev/null \
  || fail "keep-going fixture acknowledgement must succeed"
write_lease 1000
rm -f "$WORK/marker-stubparked"

kstatus_of() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }
assert_eq blocked "$(kstatus_of K900)" "fixture: one task really is parked on a human"
assert_eq pending "$(kstatus_of K901)" "fixture: the other really is dispatchable"

# ...and the surface this all runs against is the SOFT one, stated rather than
# left to chance. `blocked-task` names no settling verb at all, so it is
# operator-only on every surface — which means this whole section would keep
# passing if the pinned orchestrator's label quietly became `brokered`, and the
# end-to-end proof that a soft surface no longer suppresses the blocker would
# be gone with nothing failing. mk_stub_engine writes no `command_surface` key,
# and an absent label reads as `soft` (INV-14: the field may weaken its own
# claim by omission, never strengthen it), so this asserts the default that
# actually applies here rather than a key nobody wrote.
assert_eq soft "$(manifest_get "$WORK/eng/stubparked" command_surface soft)" \
  "the orchestrator this run would wake declares the UNRESTRICTED surface — the path that used to swallow the blocker"

krc=0
kout="$("$PUMP" 2>&1)" || krc=$?

assert_eq 0 "$krc" \
  "a boundaried task is a wait state for the RUN, not a pump failure (out: $kout)"
assert_match "pump: judgment boundary \[blocked-task\] is operator-only — not waking an orchestrator" "$kout" \
  "the pump names the boundary it declined to wake a model for"
assert_match "the pass still advanced every other task" "$kout" \
  "and says plainly that ending this invocation is not stopping the run"
[ -f "$WORK/marker-stubparked" ] \
  && fail "no orchestrator may be woken for a decision no admitted verb can make, however available one is"

# Half 2: the unrelated task really moved, in the SAME pass that met the
# boundary, by a real dispatch.
assert_eq implementing "$(kstatus_of K901)" \
  "the dispatchable task advanced in the very pass that met another task's boundary (out: $kout)"
assert_eq blocked "$(kstatus_of K900)" \
  "and the boundaried task was left exactly where only a human can move it"
[ -n "$(list_dir_files "$KEEP/.orchid/runtime/jobs")" ] \
  || fail "that advance must be backed by a job that really spawned, not a bare status write"

# Half 1: the blocker reached the channel in THIS invocation.
assert_match "judgment boundary \[blocked-task\]" "$(cat "$KEEP_OC_LOG")" \
  "the boundary was reported through the notify channel by the same pass that raised it"
assert_match "channel slack" "$(cat "$KEEP_OC_LOG")" \
  "and through the configured channel, not some default"
kqueued="$(list_dir_files "$KEEP/.orchid/runtime/outbox" 2>/dev/null | grep -v '\.tries$' | grep -v '\.reason-send-failed$' || true)"
assert_eq "" "$kqueued" \
  "nothing is left queued for a later invocation that may never come (still queued: $kqueued)"
assert_match "judgment boundary \[blocked-task\]" "$(cat "$KEEP/.orchid/BLOCKERS.md")" \
  "and the local terminal surface carries it too"

# Idempotent, which is what makes "keep driving" cost nothing: a second pass
# re-reports the same record, raises no second blocker, and sends nothing more.
koc_lines_before="$(wc -l < "$KEEP_OC_LOG")"
kblockers_before="$(wc -l < "$KEEP/.orchid/BLOCKERS.md")"
write_lease 1000   # the pass refreshed it; re-stale so the next one really runs
krc=0
kout="$("$PUMP" 2>&1)" || krc=$?
assert_eq 0 "$krc" "a repeated pass over the same outstanding decision is still a wait state"
assert_eq "$kblockers_before" "$(wc -l < "$KEEP/.orchid/BLOCKERS.md")" \
  "an unchanged record raises no second blocker"
assert_eq "$koc_lines_before" "$(wc -l < "$KEEP_OC_LOG")" \
  "and sends no second message — re-reporting a boundary costs nothing"
