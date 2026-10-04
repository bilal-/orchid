#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"

# RED: a reused PID, missing birth, foreign host, or wrong process group must
# never authorize a signal.
# GREEN: repairing that same process identity permits the expected timeout.
cd_scratch "$WORK" || exit 1
git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng"
printf 'verify=true\nrole.implementer=fake\ntimeout_minutes=0\nstall_minutes=60\n' > orchid.config
mkdir -p .orchid/tasks .orchid/reviews "$WORK/eng/fake"
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nentrypoint=run\n' > "$WORK/eng/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create I001 'process identity' >/dev/null
identity_jid="j-e${ORCHID_EPOCH}-I001-a1-abcd"
identity_file="$WORK/.orchid/runtime/jobs/$identity_jid.json"
identity_output="$WORK/.orchid/runtime/spool/$identity_jid.json"
mkdir -p "$(dirname "$identity_file")" "$(dirname "$identity_output")"
identity_manifest() {
  local kind="$1" birth host group=0
  birth="$(_pid_start "$identity_pid")"; host="$(hostname)"
  case "$kind" in
    reused) birth=previous-process-incarnation ;;
    legacy) birth='' ;;
    foreign) host=another-host ;;
    group) group=2147483647 ;;
  esac
  jq -n --arg jid "$identity_jid" --argjson pid "$identity_pid" --arg start "$birth" --arg host "$host" \
    --argjson group "$group" --arg out "$identity_output" \
    '{job_id:$jid,task:"I001",attempt:1,role:"implementer",operation:"implement",engine:"fake",
      pid:$pid,pgid:$group,started_at:0,pid_start:$start,hostname:$host,log:"/nonexistent",output:$out,base_sha:"",candidate_sha:""}' > "$identity_file"
}
for identity_case in reused legacy foreign group; do
  sleep 100 & identity_pid=$!
  disown 2>/dev/null || true
  identity_manifest "$identity_case"
  identity_check="$("$ORCHID_BIN" jobs check 2>&1)"
  sleep 0.2
  kill -0 "$identity_pid" 2>/dev/null || fail "$identity_case identity must not signal an unrelated process"
  "$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null
  if [ "$identity_case" = reused ]; then
    assert_match 'I001[[:space:]]dead' "$identity_check" 'a different birth proves the original job ended'
    [ ! -e "$identity_file" ] || fail 'reused PID does not prevent retiring the original job'
  else
    assert_match 'I001[[:space:]]unverified' "$identity_check" 'missing ownership proof refuses signals'
    [ -e "$identity_file" ] || fail 'unverified process keeps its outstanding manifest'
    assert_match '[[:space:]]unverified[[:space:]]' "$("$ORCHID_BIN" jobs ls --tsv 2>/dev/null)" 'display uses the same ownership classification'
  fi
  red_case "$identity_case process identity refuses timeout signal before touching that process"
  identity_manifest owned
  assert_eq running "$(orchid_job_process_state "$identity_file")" 'repaired process identity is owned'
  "$ORCHID_BIN" jobs check >/dev/null
  sleep 0.2
  if kill -0 "$identity_pid" 2>/dev/null; then
    fail 'matching owned process still receives the configured timeout'
    kill "$identity_pid" 2>/dev/null || true
  fi
  rm -f "$identity_file"
  green_case 'the same timeout signals the process after its identity is repaired'
done

# Legacy live records require an operator to resolve the unknown identity.
# Filing a report or garbage collecting it must not infer an exit from age.
sleep 100 & identity_pid=$!
disown 2>/dev/null || true
identity_manifest legacy
jq -n --arg jid "$identity_jid" '{contract:1,job_id:$jid,task:"I001",operation:"implement",status:"ok",summary:"original job ended"}' > "$identity_output"
identity_reconcile="$("$ORCHID_BIN" jobs reconcile)"
assert_match '^unresolved:' "$identity_reconcile" 'unverified PID keeps its report held'
[ -e "$identity_output" ] && [ -e "$identity_file" ] || fail 'held report and manifest remain intact'
red_case 'unverified legacy identity holds completion evidence instead of inferring an exit'
"$ORCHID_BIN" jobs record-exit "$identity_jid" 0 >/dev/null
identity_reconcile="$("$ORCHID_BIN" jobs reconcile)"
assert_match 'I001[[:space:]]ok' "$identity_reconcile" 'operator confirmation resolves the held report'
kill -0 "$identity_pid" 2>/dev/null || fail 'operator acknowledgement never signals the unrelated process'
kill "$identity_pid" 2>/dev/null || true
green_case 'explicit operator exit confirmation admits the same held report without signalling its PID'
