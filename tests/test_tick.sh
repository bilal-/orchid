#!/usr/bin/env bash
# v1-m2 Task 7: runners/orchid-tick (headless tick) + the `orchestrate`
# operation. Stub orchestrator engines (via ORCHID_ENGINES_DIR) stand in for
# the real claude/codex adapters -- their orchestrate branch runs a real
# `orchid` verb (proving the tick's env hygiene actually forwards ORCHID_REPO
# into the child) and writes a hand-built envelope, exactly like
# tests/test_launch.sh's stub engines do for `implement`.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"

cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"; mkdir -p "$WORK/eng"

# mk_stub_engine <name> -- a stub orchestrator engine dir. `capabilities=
# shell,git` matches roles/orchestrator.role's `requires=shell,git`, and
# `requires_binaries=jq` sidesteps the pre-existing bash-3.2 empty-CSV quirk
# in lib/manifest.sh (same fixture convention as tests/test_failover.sh's
# mk_engine).
mk_stub_engine() {
  local name="$1" dir="$WORK/eng/$1"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
    "$name" > "$dir/plugin.conf"
}

# -- stubmarker: proves NO spawn happens when run_status is already complete.
mk_stub_engine stubmarker
MARKER="$WORK/marker-spawned"
{
  echo '#!/usr/bin/env bash'
  echo "set -eu"
  echo "MARKER=$(printf '%q' "$MARKER")"
} > "$WORK/eng/stubmarker/run"
cat >> "$WORK/eng/stubmarker/run" <<'EOF'
touch "$MARKER"
req="$1"; out="$(jq -r .output "$req")"
printf '{"contract":1,"job_id":"x","task":"run","operation":"orchestrate","status":"ok","actions":[],"summary":"should never run"}' > "$out"
EOF
chmod +x "$WORK/eng/stubmarker/run"

# -- stubo: the happy path. Runs a real `orchid status` (proves ORCHID_REPO
# reached the child through the tick's env hygiene) and a real `orchid
# journal add` (proves ORCHID_ACTOR rode the same env-hygiene path into the
# child, so the entry it writes is attributed to the tick, not "operator"),
# then writes an `ok` envelope with exactly one action.
mk_stub_engine stubo
{
  echo '#!/usr/bin/env bash'
  echo "set -eu"
  echo "ORCHID_BIN=$(printf '%q' "$ORCHID_BIN")"
} > "$WORK/eng/stubo/run"
cat >> "$WORK/eng/stubo/run" <<'EOF'
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
[ "$(jq -r .operation "$req")" = orchestrate ] || exit 1
[ -n "${ORCHID_REPO:-}" ] || exit 1
"$ORCHID_BIN" status >/dev/null
"$ORCHID_BIN" journal add --kind note "tick actor probe"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"orchestrate","status":"ok","actions":["orchid status"],"summary":"tick stub ok"}' \
  "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/stubo/run"

# -- stubrl: emits `rate_limited` (no actions/summary required for a
# non-"ok" status per lib/envelope.sh's ok-union).
mk_stub_engine stubrl
cat > "$WORK/eng/stubrl/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"orchestrate","status":"rate_limited"}' \
  "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/stubrl/run"

# ===========================================================================
# A -- run_status complete: no spawn at all (stub would create a marker file
# were it invoked; assert absent). Refuses to spend quota on a finished run.
# ===========================================================================
printf -- '---\nrun_status: complete\nrun_id: r-tick\n---\n# Roadmap\n' > .orchid/roadmap.md
printf 'role.orchestrator=stubmarker\n' > orchid.config
rm -f "$MARKER"

out="$("$REPO_ROOT/runners/orchid-tick" 2>&1)"; rc=$?
assert_eq 0 "$rc" "tick exits 0 when run_status is already complete"
[ -f "$MARKER" ] && fail "tick must not spawn the orchestrator engine when run_status is complete"

# ===========================================================================
# B -- happy path: run_status running, stub runs a real verb, writes an ok
# envelope with one action.
# ===========================================================================
printf -- '---\nrun_status: running\nrun_id: r-tick\n---\n# Roadmap\n' > .orchid/roadmap.md
printf 'role.orchestrator=stubo\n' >> orchid.config

epoch_before="$(cat .orchid/runtime/epoch 2>/dev/null || echo 0)"
out="$("$REPO_ROOT/runners/orchid-tick" 2>&1)"; rc=$?
epoch_after="$(cat .orchid/runtime/epoch 2>/dev/null || echo 0)"

assert_eq 0 "$rc" "tick exits 0 on an ok envelope"
assert_match "tick: stubo ok actions=1" "$out" "tick prints engine/status/actions summary"
[ "$epoch_after" -gt "$epoch_before" ] || fail "tick's run resume increments the epoch ($epoch_before -> $epoch_after)"

env_file=".orchid/runtime/logs/tick-e${epoch_after}.envelope.json"
[ -f "$env_file" ] || fail "tick logs the envelope at runtime/logs/tick-e<epoch>.envelope.json"
envelope_validate "$env_file" || fail "the happy-path envelope must validate"

ledger_status="$(jq -r '.stubo.status' .orchid/runtime/engines.json)"
assert_eq "ok" "$ledger_status" "ledger marks stubo ok after a successful tick"

# Actor identity (v1-m3): the tick exports ORCHID_ACTOR="<engine>/orchestrator
# tick-e<epoch>" before spawning; the child's `orchid journal add` call above
# picked it up via the same env-hygiene path ORCHID_REPO/ORCHID_EPOCH already
# used, so the journal entry reads "stubo/orchestrator tick-e<epoch>" instead
# of the generic "operator e<epoch>".
journal_content="$(cat .orchid/journal.md 2>/dev/null || true)"
assert_match "tick actor probe" "$journal_content" "tick's journal add call reached journal.md"
assert_match "\\(stubo/orchestrator tick-e${epoch_after}\\)" "$journal_content" \
  "headless tick's journal entry is attributed to '<engine>/orchestrator tick-e<epoch>', not 'operator'"
[ "$(printf '%s\n' "$journal_content" | grep -c "operator e${epoch_after}")" -eq 0 ] || \
  fail "headless tick's journal entry must not fall back to the generic 'operator' actor"

# ===========================================================================
# C -- rate_limited: ledger marks the engine rate-limited and tick exits
# nonzero (the pump's next pass would then fail over).
# ===========================================================================
printf 'role.orchestrator=stubrl\n' >> orchid.config

out="$("$REPO_ROOT/runners/orchid-tick" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "tick must exit nonzero on a rate_limited envelope"
ledger_status_rl="$(jq -r '.stubrl.status' .orchid/runtime/engines.json)"
assert_eq "rate_limited" "$ledger_status_rl" "ledger marks stubrl rate_limited"

# ===========================================================================
# D -- envelope union: an `ok` orchestrate envelope without `actions` is
# malformed.
# ===========================================================================
bad="$WORK/bad-orchestrate.json"
jq -n '{contract:1, job_id:"x", task:"run", operation:"orchestrate", status:"ok", summary:"ticked"}' > "$bad"
envelope_validate "$bad" && fail "an ok orchestrate envelope without actions must be invalid"

# ...and without summary is likewise malformed.
bad2="$WORK/bad-orchestrate2.json"
jq -n '{contract:1, job_id:"x", task:"run", operation:"orchestrate", status:"ok", actions:[]}' > "$bad2"
envelope_validate "$bad2" && fail "an ok orchestrate envelope without summary must be invalid"

# ...but a well-formed one passes.
good="$WORK/good-orchestrate.json"
jq -n '{contract:1, job_id:"x", task:"run", operation:"orchestrate", status:"ok", actions:["a"], summary:"s"}' > "$good"
envelope_validate "$good" || fail "a well-formed ok orchestrate envelope must validate"
