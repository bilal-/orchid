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
sleep 1
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "stub engine envelope reconciled end-to-end"
# request document sanity: recorded in runtime/requests
req="$(ls "$WORK/.orchid/runtime/requests/"*.json | head -n1)"
assert_eq "implement" "$(jq -r .operation "$req")" "request operation"
assert_eq "workspace-write" "$(jq -r .policy "$req")" "implement policy"
