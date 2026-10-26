#!/usr/bin/env bash
# RED: An independent candidate review blocks a structurally valid wrong result,
# including direct approval while its exact detached review is still running.
# GREEN: The real driver repairs once, resumes across an epoch fence, and accepts
# only fresh verifier approval before merging the corrected candidate.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/graph-runtime.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
export ORCHID_ENGINES_DIR="$WORK/engines"
export ORCHID_GRAPH_DRIVE_CAPTURE="$WORK/captured"
export ORCHID_GRAPH_DRIVE_RELEASE="$WORK/release-check"
mkdir -p "$WORK/origin" "$ORCHID_ENGINES_DIR/graphimpl" "$ORCHID_ENGINES_DIR/graphreview" "$ORCHID_GRAPH_DRIVE_CAPTURE"
cd_scratch "$WORK/origin" || exit 1
git init -q
printf '{"ok":true,"sum":-1}\n' > result.json
printf 'role.implementer=graphimpl\nrole.reviewer=graphreview\nconcurrency=1\nverify=true\n' > orchid.config
git add result.json orchid.config
git commit -q -m 'graph driver fixture baseline'
"$ORCHID_BIN" init >/dev/null || { fail 'initialize graph driver fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'integration control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
printf 'REQ-1: result.json must structurally succeed and compute sum 3.\n' > "$WORK/requirements.md"
"$ORCHID_BIN" requirements import "$WORK/requirements.md" >/dev/null || { fail 'requirements fixture'; exit 1; }
for engine in graphimpl graphreview; do
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq,git\nentrypoint=run\n' "$engine" > "$ORCHID_ENGINES_DIR/$engine/plugin.conf"
done
cat > "$ORCHID_ENGINES_DIR/graphimpl/run" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
request="$1"
job="$(jq -r .job_id "$request")"
task="$(jq -r .task "$request")"
operation="$(jq -r .operation "$request")"
worktree="$(jq -r .worktree "$request")"
output="$(jq -r .output "$request")"
pack="$(jq -r .input_pack "$request")"
context="$pack/delivery-context.json"
[ "$operation" = implement ] && [ "$task" = BUILD ] || exit 91
repaired="$(jq -r '.repair_obligation != null' "$context")"
sum=0; [ "$repaired" != true ] || sum=3
printf '{"ok":true,"sum":%s}\n' "$sum" > "$worktree/result.json"
git -C "$worktree" add result.json
git -C "$worktree" -c user.name='Graph fixture' -c user.email=graph@example.invalid commit -qm "produce $sum"
candidate="$(git -C "$worktree" rev-parse HEAD)"
jq -n --arg task "$task" --arg job "$job" --arg candidate "$candidate" --arg worktree "$worktree" --argjson repaired "$repaired" --slurpfile context "$context" \
  '{task:$task,job_id:$job,candidate_sha:$candidate,worktree:$worktree,repaired:$repaired,context:$context[0]}' > "$ORCHID_GRAPH_DRIVE_CAPTURE/$job.implement.json"
jq -n --arg job "$job" --arg task "$task" --arg operation "$operation" --arg candidate "$candidate" \
  '{contract:1,job_id:$job,task:$task,operation:$operation,status:"ok",candidate_sha:$candidate,summary:"produced committed fixture result"}' > "$output"
WORKER
cat > "$ORCHID_ENGINES_DIR/graphreview/run" <<'WORKER'
#!/usr/bin/env bash
set -euo pipefail
request="$1"
job="$(jq -r .job_id "$request")"
task="$(jq -r .task "$request")"
operation="$(jq -r .operation "$request")"
worktree="$(jq -r .worktree "$request")"
output="$(jq -r .output "$request")"
pack="$(jq -r .input_pack "$request")"
context="$pack/delivery-context.json"
[ "$operation" = review ] || exit 91
candidate="$(git -C "$worktree" rev-parse HEAD)"
sum="$(jq -r .sum "$worktree/result.json")"
if [ "$task" = CHECK ] && [ "$sum" != 3 ] && [ ! -e "$ORCHID_GRAPH_DRIVE_RELEASE" ]; then
  jq -n --arg task "$task" --arg job "$job" --arg candidate "$candidate" --arg worktree "$worktree" \
    '{task:$task,job_id:$job,candidate_sha:$candidate,worktree:$worktree}' > "$ORCHID_GRAPH_DRIVE_CAPTURE/$job.held.json"
WORKER
stub_hold_until "$ORCHID_GRAPH_DRIVE_RELEASE" >> "$ORCHID_ENGINES_DIR/graphreview/run"
printf '\n' >> "$ORCHID_ENGINES_DIR/graphreview/run"
cat >> "$ORCHID_ENGINES_DIR/graphreview/run" <<'WORKER'
  [ -e "$ORCHID_GRAPH_DRIVE_RELEASE" ] || exit 92
fi
verdict=approve; findings='[]'
if [ "$task" = CHECK ] && [ "$sum" != 3 ]; then
  verdict=request-changes
  findings='[{"severity":"high","title":"computed sum differs from required 3","source":"independent-check"}]'
fi
jq -n --arg task "$task" --arg job "$job" --arg candidate "$candidate" --arg worktree "$worktree" --arg verdict "$verdict" --argjson sum "$sum" --slurpfile context "$context" \
  '{task:$task,job_id:$job,candidate_sha:$candidate,worktree:$worktree,verdict:$verdict,sum:$sum,context:$context[0]}' > "$ORCHID_GRAPH_DRIVE_CAPTURE/$job.review.json"
jq -n --arg job "$job" --arg task "$task" --arg operation "$operation" --arg candidate "$candidate" --arg verdict "$verdict" --argjson findings "$findings" \
  '{contract:1,job_id:$job,task:$task,operation:$operation,status:"ok",candidate_sha:$candidate,verdict:$verdict,scope_complete:true,findings:$findings,summary:"read the owned committed candidate"}' > "$output"
WORKER
/bin/bash -n "$ORCHID_ENGINES_DIR/graphimpl/run" "$ORCHID_ENGINES_DIR/graphreview/run" || { fail 'fixture engine syntax'; exit 1; }
chmod 755 "$ORCHID_ENGINES_DIR/graphimpl/run" "$ORCHID_ENGINES_DIR/graphreview/run"
"$ORCHID_BIN" task create BUILD 'compute the requested sum' >/dev/null || { fail 'create code source'; exit 1; }
"$ORCHID_BIN" task create CHECK 'independent semantic verification' --archetype review >/dev/null || { fail 'create report verifier'; exit 1; }
"$ORCHID_BIN" task set BUILD acceptance_criteria 'result.json computes sum 3' >/dev/null
"$ORCHID_BIN" task set BUILD verification_commands "jq -e '.ok == true' result.json >/dev/null" >/dev/null
"$ORCHID_BIN" task set BUILD output_contract '{"contract":1,"artifacts":[{"path":"result.json","schema":{"type":"object","required":["ok","sum"],"properties":{"ok":{"const":true},"sum":{"type":"integer"}}}}]}' >/dev/null
"$ORCHID_BIN" task set BUILD repair_budget 1 >/dev/null
"$ORCHID_BIN" task set CHECK verifies BUILD >/dev/null
"$ORCHID_BIN" task set CHECK repair_target BUILD >/dev/null
"$ORCHID_BIN" task set CHECK output_contract '{"contract":1}' >/dev/null
"$ORCHID_BIN" graph enable --reason 'candidate-bound autonomous delivery fixture' >/dev/null || { fail 'enable candidate graph'; exit 1; }
"$ORCHID_BIN" plan apply --reason 'initial graph plan' >/dev/null || { fail 'apply candidate graph plan'; exit 1; }

drive_die() {
  release_stub "$ORCHID_GRAPH_DRIVE_RELEASE"
  fail "$1"
  [ ! -f "$WORK/drive-all.log" ] || tail -n 80 "$WORK/drive-all.log"
  exit 1
}
drive_once() {
  DRIVE_RC=0
  "$ORCHID_BIN" drive > "$WORK/drive-$passes.log" 2>&1 || DRIVE_RC=$?
  cat "$WORK/drive-$passes.log" >> "$WORK/drive-all.log"
  case "$DRIVE_RC" in 0|16) ;; *) drive_die "driver pass $passes refused (rc=$DRIVE_RC; log $WORK/drive-all.log)" ;; esac
  if [ "$DRIVE_RC" -eq 16 ] && ! rg -q 'run-complete' "$WORK/drive-$passes.log"; then
    drive_die "graph delivery stopped at a human boundary in pass $passes"
  fi
  if rg -q 'worktree-conflict|unresolved.objection|budget.exhausted|repair budget exhausted' "$WORK/drive-$passes.log"; then
    drive_die "graph delivery raised an unexpected human boundary: $(cat "$WORK/drive-$passes.log")"
  fi
}
capture_review() {
  local verdict="$1" candidate="${2:-}" item
  for item in "$ORCHID_GRAPH_DRIVE_CAPTURE/"*.review.json; do
    [ -f "$item" ] || continue
    if jq -e --arg verdict "$verdict" --arg candidate "$candidate" '.task == "CHECK" and .verdict == $verdict and ($candidate == "" or .candidate_sha == $candidate)' "$item" >/dev/null; then printf '%s\n' "$item"; return 0; fi
  done
  return 1
}
passes=0; held_checked=0; bad_checked=0; resumed=0; repair_seen=0; app_injected=0; rebase_seen=0
while [ "$passes" -lt 48 ]; do
  drive_once
  graph_snapshot_file "$ORCHID_REPO" "$WORK/current.json" || drive_die 'snapshot after real driver pass'
  jq -e '.nodes.BUILD.unresolved_objection == "" and .nodes.CHECK.unresolved_objection == ""' "$WORK/current.json" >/dev/null || drive_die 'automatic repair must precede a standing objection'
  if [ "$held_checked" -eq 0 ]; then
    held=""
    for held_item in "$ORCHID_GRAPH_DRIVE_CAPTURE/"*.held.json; do [ ! -f "$held_item" ] || held="$held_item"; done
    if [ -n "$held" ]; then
      rc=0; "$ORCHID_BIN" task arbitrate BUILD --result approve --reason 'probe required verifier gate' > "$WORK/early-approval.log" 2>&1 || rc=$?
      [ "$rc" -ne 0 ] || drive_die 'operator approval bypassed live required verifier'
      red_case 'structural success and own approval cannot bypass required live candidate review'
      passes=$((passes+1))
      drive_once
      held_path="$(jq -r .worktree "$held")"
      source_path="$(fm_get .orchid/tasks/BUILD.md worktree)"
      [ "$held_path" != "$source_path" ] && [ "$held_path" != "$ORCHID_REPO" ] || drive_die 'live verifier borrowed a writable checkout'
      release_stub "$ORCHID_GRAPH_DRIVE_RELEASE"
      held_checked=1
      green_case 'a current live detached review survives another driver pass without worktree conflict'
    fi
  fi
  if [ "$bad_checked" -eq 0 ] && bad_review="$(capture_review request-changes)"; then
    bad_candidate="$(jq -r .candidate_sha "$bad_review")"
    if git merge-base --is-ancestor "$bad_candidate" orchid/integration; then drive_die 'known wrong candidate reached integration'; fi
    assert_eq 0 "$(git show "$bad_candidate:result.json" | jq -r .sum)" 'independent reviewer rejected a committed wrong result'
    bad_checked=1
    red_case 'independent semantic finding blocks the exact structurally valid wrong candidate'
  fi
  if jq -e '.nodes.BUILD.repair_rounds == 1' "$WORK/current.json" >/dev/null; then
    repair_seen=1
    [ -d .orchid/revisions/repair-BUILD-r1 ] || drive_die 'repair did not archive its failed evidence'
    if [ "$resumed" -eq 0 ] && jq -e '.nodes.BUILD.status == "pending" and .nodes.BUILD.repair_obligation != null' "$WORK/current.json" >/dev/null; then
      jobs="$("$ORCHID_BIN" jobs ls --tsv --strict)" || drive_die 'inspect quiescent resume point'
      if [ -z "$jobs" ]; then
        before_epoch="$ORCHID_EPOCH"
        ORCHID_EPOCH="$("$ORCHID_BIN" run resume | sed 's/epoch: //')"; export ORCHID_EPOCH
        [ "$ORCHID_EPOCH" != "$before_epoch" ] || drive_die 'resume did not fence the previous epoch'
        resumed=1
      fi
    fi
  fi
  if [ "$repair_seen" -eq 1 ] && [ "$app_injected" -eq 0 ] && app_review="$(capture_review approve)"; then
    jq -e '.nodes.BUILD.status != "done"' "$WORK/current.json" >/dev/null || drive_die 'upstream change must occur before delivery completes'
    jq -e '.sum == 3' "$app_review" >/dev/null || drive_die 'application change must follow a real corrected semantic approval'
    pre_rebase_candidate="$(jq -r .nodes.BUILD.candidate_sha "$WORK/current.json")"
    pre_rebase_check_generation="$(jq -r .nodes.CHECK.execution_generation "$WORK/current.json")"
    upstream_head="$(git rev-parse orchid/integration)"
    upstream_blob="$(printf 'an independent upstream application change\n' | git hash-object -w --stdin)" || drive_die 'create upstream application blob'
    GIT_INDEX_FILE="$WORK/upstream.index" git read-tree "$upstream_head" || drive_die 'initialize injected commit index'
    GIT_INDEX_FILE="$WORK/upstream.index" git update-index --add --cacheinfo 100644 "$upstream_blob" upstream.txt || drive_die 'stage injected application path'
    upstream_tree="$(GIT_INDEX_FILE="$WORK/upstream.index" git write-tree)" || drive_die 'build injected application tree'
    upstream_commit="$(printf 'independent upstream application change\n' | git commit-tree "$upstream_tree" -p "$upstream_head")" || drive_die 'commit upstream application path'
    git update-ref refs/heads/orchid/integration "$upstream_commit" "$upstream_head" || drive_die 'publish controlled upstream application change'
    # Simulate the normal integration publisher updating this one application
    # path. Keep every other index entry and all live .orchid state untouched.
    printf 'an independent upstream application change\n' > upstream.txt
    git update-index --add --cacheinfo 100644 "$upstream_blob" upstream.txt || drive_die 'sync only injected path in control index'
    app_injected=1
  fi
  if [ "$app_injected" -eq 1 ] && [ "$rebase_seen" -eq 0 ] && jq -e --arg prior "$pre_rebase_candidate" --argjson generation "$pre_rebase_check_generation" '.nodes.BUILD.candidate_sha != $prior and .nodes.CHECK.execution_generation > $generation' "$WORK/current.json" >/dev/null; then
    jq -e '.nodes.CHECK.status != "done"' "$WORK/current.json" >/dev/null || drive_die 'old verifier approval survived a real application rebase'
    rebase_seen=1
    red_case 'actual upstream application change invalidates the previously approved exact candidate'
  fi
  if jq -e '.nodes.BUILD.status == "done" and .nodes.CHECK.status == "done"' "$WORK/current.json" >/dev/null; then break; fi
  passes=$((passes+1))
  sleep 0.1
done
release_stub "$ORCHID_GRAPH_DRIVE_RELEASE"
jq -e '.nodes.BUILD.status == "done" and .nodes.CHECK.status == "done"' "$WORK/current.json" >/dev/null || drive_die "graph did not finish within 48 passes (log $WORK/drive-all.log)"
assert_eq 1 "$held_checked" 'live detached verifier was exercised'
assert_eq 1 "$bad_checked" 'wrong candidate was independently rejected'
assert_eq 1 "$repair_seen" 'bounded automatic repair ran'
assert_eq 1 "$resumed" 'delivery resumed at a quiescent epoch fence'
assert_eq 1 "$app_injected" 'real upstream application change was exercised'
assert_eq 1 "$rebase_seen" 'real application rebase invalidated old verifier approval'
jq -e '.nodes.BUILD.repair_rounds == 1 and .nodes.BUILD.execution_generation >= 2 and .nodes.CHECK.execution_generation >= 2 and .nodes.BUILD.repair_obligation == null' "$WORK/current.json" >/dev/null || fail 'fresh verifier approval discharged exactly one persisted repair obligation'
assert_eq 3 "$(git show orchid/integration:result.json | jq -r .sum)" 'integration contains the independently verified corrected result'
final_candidate="$(jq -r .nodes.BUILD.candidate_sha "$WORK/current.json")"
fresh_review="$(capture_review approve "$final_candidate")" || drive_die 'replacement verifier did not approve'
jq -e '.sum == 3 and .context.verification_target.task == "BUILD" and .context.verification_target.candidate_sha == .candidate_sha' "$fresh_review" >/dev/null || fail 'fresh semantic approval binds exact corrected target'
repaired_implementations=0
for item in "$ORCHID_GRAPH_DRIVE_CAPTURE/"*.implement.json; do
  [ -f "$item" ] || continue
  if jq -e '.repaired == true and .context.repair_obligation.source.task == "BUILD"' "$item" >/dev/null; then repaired_implementations=$((repaired_implementations+1))
    jq -e --arg failed "$bad_candidate" '.context.repair_obligation.round == 1 and .context.repair_obligation.source.candidate_sha == $failed and (.context.repair_obligation.failed_evidence | length) > 0' "$item" >/dev/null || fail 'repair instruction binds the exact independently rejected candidate'
    jq -r '.context.repair_obligation.failed_evidence[] | [.path,.sha256] | @tsv' "$item" > "$WORK/archived-evidence.tsv" || fail 'read archived evidence metadata'
    while IFS=$'\t' read -r archived_path archived_hash; do
      case "$archived_path" in .orchid/revisions/repair-BUILD-r1/reviews/*) ;; *) drive_die 'unexpected repair evidence archive ownership' ;; esac
      [ -f "$archived_path" ] || drive_die 'failed independent evidence was not archived'
      assert_eq "$archived_hash" "$(_orchid_stream_sha256 < "$archived_path")" 'archived failed verifier proof retains its exact digest'
    done < "$WORK/archived-evidence.tsv"
  fi
done
assert_eq 1 "$repaired_implementations" 'exactly one implementer consumed the persisted repair instructions'
graph_completion_ready "$ORCHID_REPO" BUILD "$WORK/current.json" || fail 'final completion requires current exact verifier binding'
assert_eq 'an independent upstream application change' "$(git show orchid/integration:upstream.txt)" 'real upstream application change survived delivery'
green_case 'one bounded repair and fresh verification survive epoch resume and a real application rebase without metadata loops'
[ "$FAILS" -eq 0 ]
