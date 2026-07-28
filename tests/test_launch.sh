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
