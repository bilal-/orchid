#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# RED: reused IDs with changed arguments, actor or epoch cannot launch another
# operation, and interrupted claims cannot silently repeat an uncertain effect.
# GREEN: the same successful intent replays its recorded result without minting
# another ownership epoch; output format changes do not change semantic intent.
cd_scratch "$WORK" || exit 1
export HOME="$MACHINE_HOME" ORCHID_REPO="$WORK"
git init -q "$WORK"
git -C "$WORK" commit -q --allow-empty -m 'Request receipt fixture'
"$ORCHID_BIN" init >/dev/null || exit 1
git -C "$WORK" checkout -q orchid/integration || exit 1
export ORCHID_OUTPUT=json
first="$("$ORCHID_BIN" run start --request-id session-one)" || exit 1
before="$(cat "$WORK/.orchid/runtime/epoch")"
second="$("$ORCHID_BIN" run start --request-id session-one)" || exit 1
assert_eq "$before" "$(cat "$WORK/.orchid/runtime/epoch")" 'receipt replay preserves minted ownership epoch'
assert_eq true "$(jq -r '.request.replayed' <<< "$second")" 'receipt labels historical replay'
assert_eq "$(jq -c 'del(.request)' <<< "$first")" "$(jq -c 'del(.request)' <<< "$second")" 'receipt repeats exact recorded data'
green_case 'identical session acquisition replays historical result without acquiring another epoch'
projected="$("$ORCHID_BIN" run start --request-id session-one --fields epoch)" || exit 1
assert_eq "$before" "$(jq -r .epoch <<< "$projected")" 'projection returns recorded ownership epoch'
assert_eq true "$(jq -r '.request.replayed' <<< "$projected")" 'projection retains replay marker'
assert_eq true "$(jq -r '.request.result_is_historical' <<< "$projected")" 'projected epoch remains explicitly historical'
assert_eq false "$(jq -r 'has("next")' <<< "$projected")" 'projection still excludes unselected operation data'
green_case 'field projection preserves historical request evidence while selecting operation data'
rc=0
changed="$("$ORCHID_BIN" run resume --request-id session-one 2> "$MACHINE_HOME/request.err")" || rc=$?
assert_eq 2 "$rc" 'changed command cannot reuse request ID'
assert_eq "$before" "$(cat "$WORK/.orchid/runtime/epoch")" 'changed command refused before epoch mutation'
rc=0
changed="$(ORCHID_ACTOR=another "$ORCHID_BIN" run start --request-id session-one 2> "$MACHINE_HOME/request.err")" || rc=$?
assert_eq 2 "$rc" 'changed actor cannot reuse request ID'
rc=0
changed="$(ORCHID_EPOCH=999999 "$ORCHID_BIN" run start --request-id session-one 2> "$MACHINE_HOME/request.err")" || rc=$?
assert_eq 2 "$rc" 'changed epoch cannot reuse request ID'
assert_match 'Request replay refused' "$(jq -r .error <<< "$changed")" 'changed intent has structured stdout error'
red_case 'changed semantic intent actor or epoch cannot cause second effect under a recorded request ID'
record="$(find "$HOME/.orchid/requests" -name result.json | head -n 1)"
[ -n "$record" ] || exit 1
cp "$record" "$MACHINE_HOME/request-good.json" || exit 1
# RED: a user-local receipt is not trusted merely because .exit is numeric.
# In particular, Bash wraps exit 256 to success, and multiple JSON documents
# must not become multiple records claiming that a single operation completed.
for corrupt in missing-data null-data array-data status-wrap status-negative status-fraction status-other multiple-documents symlink; do
  case "$corrupt" in
    missing-data) printf '%s\n' '{"exit":0}' > "$record" ;;
    null-data) printf '%s\n' '{"exit":0,"data":null}' > "$record" ;;
    array-data) printf '%s\n' '{"exit":0,"data":[]}' > "$record" ;;
    status-wrap) printf '%s\n' '{"exit":256,"data":{}}' > "$record" ;;
    status-negative) printf '%s\n' '{"exit":-1,"data":{}}' > "$record" ;;
    status-fraction) printf '%s\n' '{"exit":0.5,"data":{}}' > "$record" ;;
    status-other) printf '%s\n' '{"exit":3,"data":{}}' > "$record" ;;
    multiple-documents) cat "$MACHINE_HOME/request-good.json" "$MACHINE_HOME/request-good.json" > "$record" ;;
    symlink)
      rm "$record"
      ln -s "$MACHINE_HOME/request-good.json" "$record" || exit 1
      ;;
  esac
  rc=0
  corrupt_result="$("$ORCHID_BIN" run start --request-id session-one 2> "$MACHINE_HOME/request.err")" || rc=$?
  assert_eq 1 "$rc" "corrupt $corrupt receipt refuses replay"
  assert_match 'Request replay refused' "$(jq -r .error <<< "$corrupt_result")" "corrupt $corrupt receipt has a structured refusal"
  assert_eq "$before" "$(cat "$WORK/.orchid/runtime/epoch")" "corrupt $corrupt receipt cannot execute an ownership operation"
  rm "$record"
  cp "$MACHINE_HOME/request-good.json" "$record" || exit 1
done
red_case 'malformed or linked cached results refuse replay and cannot execute another effect'
restored="$("$ORCHID_BIN" run start --request-id session-one)" || exit 1
assert_eq true "$(jq -r '.request.replayed' <<< "$restored")" 'valid restored receipt accepts replay'
assert_eq "$(jq -c 'del(.request)' <<< "$first")" "$(jq -c 'del(.request)' <<< "$restored")" 'valid restored receipt preserves original result'
green_case 'a single valid object receipt remains replayable after corrupt-cache refusals'
rm "$record"
rc=0
pending="$("$ORCHID_BIN" run start --request-id session-one 2> "$MACHINE_HOME/request.err")" || rc=$?
assert_eq 1 "$rc" 'interrupted receipt refuses uncertain execution'
assert_match 'Request replay refused' "$(jq -r .error <<< "$pending")" 'interrupted receipt has structured stdout error'
assert_match 'pending or interrupted' "$(cat "$MACHINE_HOME/request.err")" 'interrupted receipt names inspection recovery'
assert_eq "$before" "$(cat "$WORK/.orchid/runtime/epoch")" 'interrupted receipt cannot mint another epoch'
red_case 'missing result on a permanent claim is uncertainty and refuses execution rather than automatically retrying'
third="$("$ORCHID_BIN" run start --request-id session-two)" || exit 1
assert_eq false "$(jq -r '.request.replayed' <<< "$third")" 'fresh deliberate request is not replay'
[ "$before" != "$(cat "$WORK/.orchid/runtime/epoch")" ] || fail 'new explicit intent may acquire a new epoch'
green_case 'a new explicitly selected request ID permits the next intentional lifecycle operation'

# Exercise the writer separately: a malformed rendered result must never be
# published as completion of the permanent claim.
mkdir "$MACHINE_HOME/request-publish" || exit 1
try_finish() (
  export ORCHID_ROOT="$REPO_ROOT"
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/requests.sh"
  ORCHID_REQUEST_DIR="$MACHINE_HOME/request-publish"
  orchid_request_finish "$1" "$2"
)
for malformed in null array multiple status; do
  case "$malformed" in
    null) printf '%s\n' null > "$MACHINE_HOME/request-data.json"; finish_status=0 ;;
    array) printf '%s\n' '[]' > "$MACHINE_HOME/request-data.json"; finish_status=0 ;;
    multiple) printf '%s\n%s\n' '{}' '{}' > "$MACHINE_HOME/request-data.json"; finish_status=0 ;;
    status) printf '%s\n' '{}' > "$MACHINE_HOME/request-data.json"; finish_status=256 ;;
  esac
  rc=0
  try_finish "$MACHINE_HOME/request-data.json" "$finish_status" || rc=$?
  assert_eq 1 "$rc" "malformed $malformed result refuses publication"
  [ ! -e "$MACHINE_HOME/request-publish/result.json" ] || fail "malformed $malformed result was published"
done
red_case 'receipt publication refuses non-object or multiple rendered results and unsupported exit status'
printf '%s\n' '{"epoch":42}' > "$MACHINE_HOME/request-data.json"
for finish_status in 0 1 2; do
  rc=0
  try_finish "$MACHINE_HOME/request-data.json" "$finish_status" || rc=$?
  assert_eq 0 "$rc" "supported exit $finish_status accepts receipt publication"
  assert_eq "$finish_status" "$(jq -r .exit "$MACHINE_HOME/request-publish/result.json")" 'publication preserves public exit'
  assert_eq 42 "$(jq -r .data.epoch "$MACHINE_HOME/request-publish/result.json")" 'publication preserves recorded object'
done
green_case 'single rendered objects publish atomically for all three public exit statuses'

# Hold a claimed operation before its effect. A simultaneous public caller
# must observe pending uncertainty; once the winner completes, it must replay.
concurrent_before="$(cat "$WORK/.orchid/runtime/epoch")"
(
  export ORCHID_ROOT="$REPO_ROOT"
  source "$REPO_ROOT/lib/requests.sh"
  source "$ORCHID_ROOT/lib/cli.sh"
  orchid_cli_prepare run json start --request-id concurrent-operation || exit 1
  orchid_request_begin concurrent-operation run "$ORCHID_CLI_PARSED" || exit 1
  printf '%s\n' "$ORCHID_REQUEST_DIR" > "$MACHINE_HOME/request-ready"
  eval "$(stub_hold_until "$MACHINE_HOME/request-release")"
  [ -e "$MACHINE_HOME/request-release" ] || exit 1
  ORCHID_OUTPUT=json "$ORCHID_BIN" run start > "$MACHINE_HOME/request-concurrent-data.json" || exit 1
  orchid_request_finish "$MACHINE_HOME/request-concurrent-data.json" 0 || exit 1
) > "$MACHINE_HOME/request-concurrent.log" 2>&1 &
request_pid=$!
if ! _await_while_alive "$request_pid" "$_ORCHID_LIVENESS_TRIES" test -f "$MACHINE_HOME/request-ready"; then
  release_stub "$MACHINE_HOME/request-release"
  wait "$request_pid" || true
  fail "concurrent request never reached its held claim: $(cat "$MACHINE_HOME/request-concurrent.log")"
  exit 1
fi
rc=0
concurrent_pending="$("$ORCHID_BIN" run start --request-id concurrent-operation 2> "$MACHINE_HOME/request.err")" || rc=$?
assert_eq 1 "$rc" 'concurrent pending claim refuses duplicate operation'
assert_match 'Request replay refused' "$(jq -r .error <<< "$concurrent_pending")" 'concurrent pending claim has structured refusal'
assert_eq "$concurrent_before" "$(cat "$WORK/.orchid/runtime/epoch")" 'second concurrent caller cannot acquire ownership'
red_case 'a simultaneous caller cannot repeat an operation whose permanent claim is still pending'
release_stub "$MACHINE_HOME/request-release"
rc=0
wait "$request_pid" || rc=$?
assert_eq 0 "$rc" 'claimed operation completes after release'
[ "$concurrent_before" != "$(cat "$WORK/.orchid/runtime/epoch")" ] || fail 'winning claim did not perform its ownership operation'
concurrent_after="$(cat "$WORK/.orchid/runtime/epoch")"
concurrent_replay="$("$ORCHID_BIN" run start --request-id concurrent-operation)" || exit 1
assert_eq true "$(jq -r '.request.replayed' <<< "$concurrent_replay")" 'completed concurrent claim permits historical replay'
assert_eq "$concurrent_after" "$(cat "$WORK/.orchid/runtime/epoch")" 'completed concurrent claim cannot repeat ownership acquisition'
assert_eq "$(jq -c . "$MACHINE_HOME/request-concurrent-data.json")" "$(jq -c 'del(.request)' <<< "$concurrent_replay")" 'concurrent replay preserves winner result'
green_case 'the same concurrent intent replays its recorded completion after the winner finishes'

# RED: a stale self-hosted kernel cannot claim a new public request, replay a
# completed request, or touch an unacknowledged service target through receipt
# scope discovery. Every refusal must precede cache publication and target work.
# GREEN: refreshing that same kernel allows the historical replay unchanged;
# acknowledged service installation remains available through the same wrapper.
admission_root="$WORK/request-admission-kernel"
admission_home="$MACHINE_HOME/request-admission-home"
mkdir -p "$admission_root" "$admission_home" || exit 1
for payload in bin lib libexec runners templates plugins roles skills release PROTOCOL.md; do
  cp -R "$REPO_ROOT/$payload" "$admission_root/" || exit 1
done
git -C "$admission_root" init -q || exit 1
git -C "$admission_root" add . || exit 1
git -C "$admission_root" commit -qm 'Receipt admission kernel' || exit 1
HOME="$admission_home" ORCHID_REPO="$admission_root" "$admission_root/bin/orchid" init >/dev/null || exit 1
git -C "$admission_root" checkout -q orchid/integration || exit 1
admission_first="$(HOME="$admission_home" ORCHID_REPO="$admission_root" "$admission_root/bin/orchid" run start --request-id admitted-before-stale)" || exit 1
admission_epoch="$(cat "$admission_root/.orchid/runtime/epoch")"
admission_claims="$(find "$admission_home/.orchid/requests" -name intent.json | wc -l | tr -d ' ')"
printf '\n# receipt stale-install witness\n' >> "$admission_root/libexec/orchid-version"
git -C "$admission_root" add libexec/orchid-version || exit 1
for admission_id in admitted-before-stale refused-new-stale; do
  rc=0
  admission_result="$(HOME="$admission_home" ORCHID_REPO="$admission_root" GIT_TRACE="$admission_home/stale.trace" \
    "$admission_root/bin/orchid" run start --request-id "$admission_id" 2> "$admission_home/admission.err")" || rc=$?
  assert_eq 1 "$rc" "stale kernel refuses $admission_id before claim or replay"
  assert_match 'refusing to run' "$(cat "$admission_home/admission.err")" 'receipt admission retains stale-root diagnostic'
  assert_match 'Request replay refused' "$(jq -r .error <<< "$admission_result")" 'admission refusal uses structured public output'
  assert_eq "$admission_claims" "$(find "$admission_home/.orchid/requests" -name intent.json | wc -l | tr -d ' ')" 'stale refusal cannot publish a request claim'
  assert_eq "$admission_epoch" "$(cat "$admission_root/.orchid/runtime/epoch")" 'stale refusal cannot acquire another epoch'
done
if grep -Eq 'rev-parse --show-toplevel' "$admission_home/stale.trace"; then
  fail 'receipt scope invoked target Git before admission'
fi
red_case 'both new requests and cached successes refuse a staged self-hosted kernel before claim, replay or epoch change'

rc=0
service_denied="$(HOME="$admission_home" ORCHID_REPO="$WORK" GIT_TRACE="$admission_home/service-denied.trace" \
  "$admission_root/bin/orchid" service install --repo="$admission_root" --dry-run --request-id service-admitted 2> "$admission_home/admission.err")" || rc=$?
assert_eq 1 "$rc" 'explicit service target without acknowledgement refuses receipt admission'
assert_match 'service installation refused' "$(cat "$admission_home/admission.err")" 'service authorization precedes the stale-kernel gate'
assert_match 'root verification was not attempted' "$(cat "$admission_home/admission.err")" 'denial retains no-target-Git trust diagnosis'
assert_match 'Request replay refused' "$(jq -r .error <<< "$service_denied")" 'service denial remains structured'
[ ! -s "$admission_home/service-denied.trace" ] || fail 'unacknowledged receipt admission invoked target Git'
assert_eq "$admission_claims" "$(find "$admission_home/.orchid/requests" -name intent.json | wc -l | tr -d ' ')" 'unacknowledged service cannot publish a claim'
red_case 'explicit unacknowledged service target is refused before root Git or request cache writes'

git -C "$admission_root" checkout HEAD -- libexec/orchid-version || exit 1
admission_replay="$(HOME="$admission_home" ORCHID_REPO="$admission_root" "$admission_root/bin/orchid" run start --request-id admitted-before-stale)" || exit 1
assert_eq true "$(jq -r .request.replayed <<< "$admission_replay")" 'refreshed kernel permits the same historical intent'
assert_eq "$admission_epoch" "$(cat "$admission_root/.orchid/runtime/epoch")" 'admission never mints an epoch for replay'
assert_eq "$(jq -c 'del(.request)' <<< "$admission_first")" "$(jq -c 'del(.request)' <<< "$admission_replay")" 'refreshed replay preserves recorded result'
green_case 'refreshing the same staged kernel restores historical replay without another ownership transition'

HOME="$admission_home" ORCHID_REPO="$admission_root" ORCHID_OUTPUT=raw \
  "$admission_root/bin/orchid" trust unattended "$admission_root" --reason 'Disposable receipt admission proof' >/dev/null || exit 1
service_admitted="$(HOME="$admission_home" ORCHID_REPO="$WORK" "$admission_root/bin/orchid" service install \
  --repo "$admission_root" --dry-run --request-id service-admitted)" || exit 1
assert_eq false "$(jq -r .request.replayed <<< "$service_admitted")" 'previous denial did not reserve service request ID'
service_replay="$(HOME="$admission_home" ORCHID_REPO="$WORK" "$admission_root/bin/orchid" service install \
  --repo "$admission_root" --dry-run --request-id service-admitted)" || exit 1
assert_eq true "$(jq -r .request.replayed <<< "$service_replay")" 'authorized explicit service intent replays'
green_case 'acknowledging the exact explicit target permits first install and its historical replay'
HOME="$admission_home" ORCHID_REPO="$admission_root" ORCHID_OUTPUT=raw \
  "$admission_root/bin/orchid" trust revoke "$admission_root" >/dev/null || exit 1
rc=0
service_revoked="$(HOME="$admission_home" ORCHID_REPO="$WORK" GIT_TRACE="$admission_home/service-revoked.trace" \
  "$admission_root/bin/orchid" service install --repo "$admission_root" --dry-run --request-id service-admitted 2> "$admission_home/admission.err")" || rc=$?
assert_eq 1 "$rc" 'cached service install cannot bypass revoked authorization'
assert_match 'service installation refused' "$(cat "$admission_home/admission.err")" 'cached service replay rechecks current authorization'
assert_match 'Request replay refused' "$(jq -r .error <<< "$service_revoked")" 'revoked historical replay remains structured'
[ ! -s "$admission_home/service-revoked.trace" ] || fail 'revoked service replay invoked target Git'
assert_eq "$admission_epoch" "$(cat "$admission_root/.orchid/runtime/epoch")" 'service admission and replay do not acquire run ownership'
red_case 'revoking the same target prevents cached service success without target Git or epoch change'

[ "$FAILS" -eq 0 ]
