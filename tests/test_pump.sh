#!/usr/bin/env bash
# v1-m2 Task 8: runners/orchid-pump -- the LLM-free front gate that decides
# whether an abandoned run is worth waking. It never builds a prompt or reads
# an envelope; it only checks init state, run_status, lease staleness, and
# (dry-check only) whether an orchestrator engine is currently resolvable,
# then `exec`s runners/orchid-tick (Task 7) to do the real work.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
export ORCHID_ROOT="$REPO_ROOT"

cd "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
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
# C -- fresh lease: run_status running, lease refreshed moments ago -- a live
# orchestrator owns this run; the pump must not spawn the tick.
# ===========================================================================
printf -- '---\nrun_status: running\nrun_id: r-pump\n---\n# Roadmap\n' > .orchid/roadmap.md
mk_stub_engine stubfresh
printf 'role.orchestrator=stubfresh\n' > orchid.config
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
printf 'role.orchestrator=stubreleased\n' > orchid.config
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
printf 'role.orchestrator=stubhealthy\n' > orchid.config
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
printf 'role.orchestrator=stubcrashed\n' > orchid.config
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
printf 'role.orchestrator=stubprime,stubfallback\n' > orchid.config
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
printf 'role.orchestrator=stubprime2,stubfallback2\n' > orchid.config
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
[ "$epoch_after" -eq "$epoch_before" ] || fail "no tick ran, so no fresh epoch should have been fenced"
