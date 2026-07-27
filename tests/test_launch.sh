#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; echo a > f.txt; git add f.txt; git commit -q -m base
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
mkdir -p "$WORK/eng/fake"
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
