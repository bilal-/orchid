#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# RED: an invalid permission must prevent adapter launch, even after base env
# bytes were emitted. Multiline values must not split into new assignments.
# GREEN: the repaired permission launches and forwards its exact value.
cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks "$WORK/eng/probe"
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng"
export ORCHID_ENV_SPAWN_MARKER="$WORK/adapter-started"
printf 'verify=true\nrole.implementer=probe\n' > orchid.config
cat > "$WORK/eng/probe/plugin.conf" <<'EOF'
manifest_version=1
id=test/probe
version=0.1.0
kind=engine
api_version=1
capabilities=workspace_write,shell,git
requires_binaries=jq
entrypoint=run
permissions=INVALID-PERMISSION
EOF
cat > "$WORK/eng/probe/run" <<'EOF'
#!/usr/bin/env bash
set -eu
: > "$ORCHID_ENV_SPAWN_MARKER"
req="$1"; out="$(jq -r .output "$req")"
jq -n --arg job_id "$(jq -r .job_id "$req")" --arg task "$(jq -r .task "$req")" \
  --arg value "${DATA_ALLOWED:-}" --arg injected "${INJECTED_ENV:-}" \
  '{contract:1,job_id:$job_id,task:$task,operation:"implement",status:"ok",summary:$value,injected:$injected}' > "$out"
EOF
chmod +x "$WORK/eng/probe/run"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create E001 'invalid environment permission' >/dev/null
env_rc=0
env_error="$("$REPO_ROOT/runners/orchid-launch" E001 implementer implement 2>&1)" || env_rc=$?
sleep 1
[ "$env_rc" -ne 0 ] || fail 'invalid environment permission refuses launch'
assert_match 'invalid permission' "$env_error" 'refusal preserves permission diagnostic'
[ ! -e "$ORCHID_ENV_SPAWN_MARKER" ] || fail 'partial environment must never reach adapter spawn'
for env_manifest in "$WORK/.orchid/runtime/jobs/"*.json; do
  assert_eq 0 "$(jq -r .pid "$env_manifest")" 'refused launch remains unspawned'
  [ "$(jq -r '.launch_exit // 0' "$env_manifest")" -ne 0 ] || fail 'refused environment records launch failure'
done
red_case 'invalid permission refuses actual adapter launch before its process starts'

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/manifest.sh"
printf 'permissions=-n\n' >> "$WORK/eng/probe/plugin.conf"
env_rc=0
manifest_validate "$WORK/eng/probe" > "$WORK/manifest-check.log" 2>&1 || env_rc=$?
[ "$env_rc" -ne 0 ] || fail 'option-shaped permission must remain visible to validation'
red_case 'option-shaped manifest permission is data and cannot disappear through echo'

printf 'permissions=DATA_ALLOWED\n' >> "$WORK/eng/probe/plugin.conf"
export DATA_ALLOWED='first line
INJECTED_ENV=must-remain-value
last line'
rm -f "$ORCHID_ENV_SPAWN_MARKER"
"$ORCHID_BIN" task create E002 'exact environment value' >/dev/null
env_output="$("$REPO_ROOT/runners/orchid-launch" E002 implementer implement)" || fail 'valid environment launches adapter'
assert_match 'launched j-' "$env_output" 'valid environment reports a launched job'
sleep 1
"$ORCHID_BIN" jobs reconcile >/dev/null
[ -e "$ORCHID_ENV_SPAWN_MARKER" ] || fail 'repaired permission reaches adapter'
assert_eq "$DATA_ALLOWED" "$(jq -r .summary .orchid/reviews/E002-a1-implementer.json)" 'multiline opted-in value arrives byte-for-byte'
assert_eq '' "$(jq -r .injected .orchid/reviews/E002-a1-implementer.json)" 'embedded assignment remains part of the value'
green_case 'valid permission launches and preserves multiline data without adding an environment variable'

source "$REPO_ROOT/lib/spawn.sh"
printf 'permissions=INVALID-PERMISSION\n' >> "$WORK/eng/probe/plugin.conf"
child_env=('stale=value')
env_rc=0
spawn_child_env_load "$WORK/eng/probe" 2> "$WORK/env-check.log" || env_rc=$?
[ "$env_rc" -ne 0 ] || fail 'checked environment loader reports emitter failure'
assert_eq 0 "${#child_env[@]}" 'failed load clears stale and partial assignments'
red_case 'checked loader refuses partial output and clears the environment array'
printf 'permissions=DATA_ALLOWED\n' >> "$WORK/eng/probe/plugin.conf"
spawn_child_env_load "$WORK/eng/probe" || fail 'checked loader accepts repaired permissions'
env_found=0
for env_entry in "${child_env[@]}"; do
  [ "$env_entry" != "DATA_ALLOWED=$DATA_ALLOWED" ] || env_found=1
done
assert_eq 1 "$env_found" 'checked loader retains the exact assignment'
green_case 'checked loader accepts the same manifest after repair'
