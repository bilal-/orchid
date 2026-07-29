#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; echo a > f.txt; git add f.txt; git commit -q -m base
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
mkdir -p "$WORK/eng/fake"
# v1-m2: `jobs prepare` (via runners/orchid-launch) now resolves through
# resolve_role_available, gated on role_eligibility_reason -- "fake" must
# declare the implementer role's required capabilities to remain
# discoverable+eligible, or the launch below would now (correctly) refuse.
# requires_binaries=jq below is just a representative populated value -- the
# bash-3.2 empty-CSV/array quirk this key used to be needed to sidestep is
# fixed directly in lib/manifest.sh's _manifest_split_csv now (see its own
# header comment; tests/test_failover.sh's mk_engine drops this key entirely
# to demonstrate the fix).
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/fake/plugin.conf"
cat > "$WORK/eng/fake/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
[ -f "$(jq -r .input_pack "$req")/pack.json" ] || exit 1
[ "$(jq -r .operation "$req")" = implement ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"implement","status":"ok","summary":"stub done"}' "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/fake/run"
export ORCHID_ENGINES_DIR="$WORK/eng"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo

out="$("$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$out" "launch reports job id"

# Process-group isolation: a plain `&` inherits the parent's process group,
# so the manifest pgid would be the ORCHESTRATOR's group — `jobs check`'s
# stall/timeout group-kill would then kill the orchestrator itself. The
# spawned engine must land in its OWN process group (pgid == its own pid),
# distinct from this test script's group. Captured from the manifest BEFORE
# `jobs reconcile` (which deletes it).
job_id="$(echo "$out" | awk '{print $2}')"
launched_pid="$(echo "$out" | awk '{print $4}')"
manifest="$WORK/.orchid/runtime/jobs/$job_id.json"
[ -f "$manifest" ] || fail "manifest file exists for job before reconcile"
manifest_pid="$(jq -r .pid "$manifest")"
manifest_pgid="$(jq -r .pgid "$manifest")"
own_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
assert_eq "$launched_pid" "$manifest_pid" "manifest pid matches launched pid"
[ "$manifest_pgid" -gt 0 ] 2>/dev/null || fail "manifest pgid must be > 0 (got '$manifest_pgid')"
[ "$manifest_pgid" != "$own_pgid" ] || fail "manifest pgid must differ from the test's own process group (child must not inherit orchestrator's pgid)"
assert_eq "$manifest_pid" "$manifest_pgid" "manifest pgid equals the child pid (child is its own process group leader)"

sleep 1
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "stub engine envelope reconciled end-to-end"
# request document sanity: recorded in runtime/requests
req="$(ls "$WORK/.orchid/runtime/requests/"*.json | head -n1)"
assert_eq "implement" "$(jq -r .operation "$req")" "request operation"
assert_eq "workspace-write" "$(jq -r .policy "$req")" "implement policy"

# -- env hygiene (Task 5): the child only sees the base allowlist (PATH,
# HOME, USER, LANG, LC_*, TERM, TMPDIR, ORCHID_*) plus exactly the env var
# names a plugin's manifest opts into via `permissions=`. SECRET_LEAK is set
# in the PARENT but neither base-allowlisted nor opted into by the first
# stub's manifest (it has no plugin.conf at all) -- it must not reach the
# child. ORCHID_MARKER (ORCHID_*) and PATH must always reach the child.
export SECRET_LEAK="topsecret-value"
export ORCHID_MARKER="marker-should-pass"
mkdir -p "$WORK/eng/leaky"
cat > "$WORK/eng/leaky/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"implement","status":"ok","summary":"SECRET_LEAK=<%s> ORCHID_MARKER=<%s> PATH_SET=<%s>"}' \
  "$jid" "$task" "${SECRET_LEAK:-}" "${ORCHID_MARKER:-}" "${PATH:+yes}" > "$out"
EOF
chmod +x "$WORK/eng/leaky/run"
printf 'role.leaktest=leaky\n' >> "$WORK/orchid.config"

"$ORCHID_BIN" task create T002 demo2 >/dev/null
"$REPO_ROOT/runners/orchid-launch" T002 leaktest implement >/dev/null
sleep 1
"$ORCHID_BIN" jobs reconcile >/dev/null
summary="$(jq -r .summary "$WORK/.orchid/reviews/T002-a1-leaktest.json")"
assert_match "SECRET_LEAK=<>" "$summary" "child does NOT see SECRET_LEAK (not allowlisted, not opted into)"
assert_match "ORCHID_MARKER=<marker-should-pass>" "$summary" "child sees ORCHID_MARKER (ORCHID_* always allowed)"
assert_match "PATH_SET=<yes>" "$summary" "child sees PATH (always allowed)"

# -- opting into SECRET_LEAK via plugin.conf permissions= makes it reach the
# child (the ONLY way a non-base name may cross the boundary).
mkdir -p "$WORK/eng/leaky2"
cp "$WORK/eng/leaky/run" "$WORK/eng/leaky2/run"; chmod +x "$WORK/eng/leaky2/run"
printf 'manifest_version=1\nid=orchid/leaky2\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\npermissions=SECRET_LEAK\n' \
  > "$WORK/eng/leaky2/plugin.conf"
printf 'role.leaktest2=leaky2\n' >> "$WORK/orchid.config"

"$ORCHID_BIN" task create T003 demo3 >/dev/null
"$REPO_ROOT/runners/orchid-launch" T003 leaktest2 implement >/dev/null
sleep 1
"$ORCHID_BIN" jobs reconcile >/dev/null
summary2="$(jq -r .summary "$WORK/.orchid/reviews/T003-a1-leaktest2.json")"
assert_match "SECRET_LEAK=<topsecret-value>" "$summary2" "child DOES see SECRET_LEAK once plugin.conf opts in via permissions="

# ---------------------------------------------------------------------------
# v1-m3: `runners/orchid-launch plan plan_critic critique` -- the reserved
# task id `plan` has no `.orchid/tasks/plan.md` at all, so the launcher must
# (a) resolve a worktree WITHOUT crashing on the missing task file (defaults
# to the repo itself) and (b) hand the stub engine a plan-scoped pack
# (requirements.md + roadmap.md + tasks.md; no task.md/diff.patch) built by
# lib/pack.sh's plan branch, not the ordinary per-task pack.
# ---------------------------------------------------------------------------
echo "# Requirements" > "$WORK/.orchid/requirements.md"
printf -- '---\nrun_status: planning\n---\n# Roadmap\nDraft body.\n' > "$WORK/.orchid/roadmap.md"

mkdir -p "$WORK/eng/critic"
printf 'manifest_version=1\nid=test/critic\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/critic/plugin.conf"
cat > "$WORK/eng/critic/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
pack="$(jq -r .input_pack "$req")"
[ -f "$pack/requirements.md" ] || exit 1
[ -f "$pack/roadmap.md" ] || exit 1
[ -f "$pack/tasks.md" ] || exit 1
[ ! -f "$pack/task.md" ] || exit 1
[ ! -f "$pack/diff.patch" ] || exit 1
[ "$(jq -r .operation "$req")" = critique ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"critique","status":"ok","verdict":"request-changes","scope_complete":true,"findings":[{"severity":"medium","title":"stub finding"}]}' \
  "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/critic/run"
printf 'role.plan_critic=critic\n' >> "$WORK/orchid.config"

plan_launch_out="$("$REPO_ROOT/runners/orchid-launch" plan plan_critic critique)"
assert_match "launched j-" "$plan_launch_out" "plan critique launch reports job id"
sleep 1
plan_reconcile_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "plan	ok" "$plan_reconcile_line" "plan critique job reconciled end-to-end"
[ -f "$WORK/.orchid/reviews/plan-a1-plan_critic.json" ] || fail "plan critique envelope filed at plan-a1-plan_critic.json"
assert_eq "1" "$(jq '.findings | length' "$WORK/.orchid/reviews/plan-a1-plan_critic.json")" "plan critique envelope carries the stub finding"

plan_req=""
for rf in "$WORK/.orchid/runtime/requests/"*.json; do
  [ "$(jq -r .task "$rf" 2>/dev/null)" = "plan" ] && plan_req="$rf" && break
done
[ -n "$plan_req" ] || fail "plan critique request document not found under runtime/requests"
assert_eq "$WORK" "$(jq -r .worktree "$plan_req")" "plan critique request worktree defaults to the repo (no task file to read one from)"
