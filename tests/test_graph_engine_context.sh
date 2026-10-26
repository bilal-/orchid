#!/usr/bin/env bash
# RED: Missing or malformed graph context cannot become native model input.
# GREEN: Every shipped native worker receives the same contracts and repairs.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/engine-context.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
assert_eq legacy "$(orchid_engine_context_prompt "$WORK/absent" legacy)" 'legacy prompt stays byte identical'
mkdir -p "$WORK/context"
printf '{bad JSON\n' > "$WORK/context/delivery-context.json"
rc=0; out="$(orchid_engine_context_prompt "$WORK/context" legacy 2> "$WORK/context.err")" || rc=$?
[ "$rc" -ne 0 ] || fail 'malformed mandatory context refuses model invocation'
assert_eq '' "$out" 'invalid context emits no partial prompt'
rm "$WORK/context/delivery-context.json"
printf '{"graph_contract":1}\n' > "$WORK/outside.json"
ln -s "$WORK/outside.json" "$WORK/context/delivery-context.json"
rc=0; out="$(orchid_engine_context_prompt "$WORK/context" legacy 2> "$WORK/context.err")" || rc=$?
[ "$rc" -ne 0 ] || fail 'context symlink cannot inject outside instructions'
red_case 'malformed and symlinked mandatory context refuse before emitting a native prompt'
rm "$WORK/context/delivery-context.json"
cat > "$WORK/context/delivery-context.json" <<'CONTEXT'
{"graph_contract":1,"run_context":{"id":"fixture"},"output_contract":{"contract":1,"artifacts":[{"path":"delivery-result.json"}]},"repair_obligation":{"findings":[{"title":"prior arithmetic defect"}]},"target_repair_obligation":{"findings":[{"title":"independent repair confirmation"}]}}
CONTEXT
out="$(orchid_engine_context_prompt "$WORK/context" legacy)" || fail 'valid context appends'
assert_match 'prior arithmetic defect' "$out" 'own repair is visible'
assert_match 'independent repair confirmation' "$out" 'inherited repair is visible'
green_case 'the same prompt helper appends valid output and repair contracts'

for engine in claude codex agy hermes; do
  dir="$WORK/$engine"
  mkdir -p "$dir/pack" "$dir/worktree" "$dir/out" "$dir/bin"
  git -C "$dir/worktree" init -q
  git -C "$dir/worktree" commit -q --allow-empty -m baseline
  candidate="$(git -C "$dir/worktree" rev-parse HEAD)"
  printf -- '---\nschema: 1\nid: T\ntitle: Inspect result\nacceptance_criteria: Inspect arithmetic\nstop_condition: One pass\n---\n' > "$dir/pack/task.md"
  printf 'diff --git a/app b/app\n+arithmetic\n' > "$dir/pack/diff.patch"
  cp "$WORK/context/delivery-context.json" "$dir/pack/delivery-context.json"
  printf '{"budget":65536,"total_bytes":1024,"items":[{"name":"task.md","truncated":false},{"name":"diff.patch","truncated":false},{"name":"delivery-context.json","truncated":false}],"omitted":[]}\n' > "$dir/pack/pack.json"
  printf -v capture_q '%q' "$dir/captured"
  {
    printf '#!/usr/bin/env bash\ncapture=%s\n' "$capture_q"
    cat <<'CLI'
case "${0##*/}" in
  codex|claude) cat > "$capture" ;;
  *) previous=''; for argument in "$@"; do
       case "$previous" in -p|-z) printf '%s' "$argument" > "$capture" ;; esac
       previous="$argument"
     done ;;
esac
printf 'REASON: inspected context\nVERDICT: approve\n'
CLI
  } > "$dir/bin/$engine"
  chmod 755 "$dir/bin/$engine"
  jq -n --arg job "j-$engine" --arg wt "$dir/worktree" --arg pack "$dir/pack" \
    --arg output "$dir/out/result.json" --arg candidate "$candidate" \
    '{request:1,job_id:$job,task:"T",attempt:1,role:"reviewer",operation:"review",base_sha:$candidate,candidate_sha:$candidate,worktree:$wt,input_pack:$pack,output:$output,deadline_s:10,policy:"read-only",model:"",effort:"medium"}' > "$dir/request.json"
  rc=0
  PATH="$dir/bin:$PATH" ORCHID_HB_INTERVAL_S=1 "$REPO_ROOT/plugins/engines/$engine/run" "$dir/request.json" > "$dir/adapter.out" 2> "$dir/adapter.err" || rc=$?
  assert_eq 0 "$rc" "$engine fake CLI accepts the actual adapter prompt"
  [ -f "$dir/captured" ] || { fail "$engine reached its CLI"; continue; }
  prompt="$(cat "$dir/captured")"
  assert_match 'delivery-result.json' "$prompt" "$engine receives committed artifact contract"
  assert_match 'prior arithmetic defect' "$prompt" "$engine receives own repair obligation"
  assert_match 'independent repair confirmation' "$prompt" "$engine receives target repair obligation"
  assert_match 'Keep the adapter reply format' "$prompt" "$engine keeps native reply protocol"
done
green_case 'all four native worker adapters deliver graph instructions to their actual CLI input'
[ "$FAILS" -eq 0 ]
