#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/common.sh"   # file_mtime (portable BSD/GNU stat mtime)
ADAPTER="$REPO_ROOT/plugins/engines/hermes/run"

# v1-m4 Task 6: hermes's oneshot mode has no real sandbox/jail, so this
# adapter's safety story rests on `-t clarify` (a real toolset restriction,
# not just the prompt's advisory "do not use tools" line) plus `--safe-mode`
# on every real invocation. Static grep, same lint-style check
# test_engine_codex.sh runs against its own orchestrate instructions.
grep -q -- '-t clarify' "$ADAPTER" || fail "$ADAPTER must invoke hermes with -t clarify (the real tool-visibility backstop)"
grep -q -- '--safe-mode' "$ADAPTER" || fail "$ADAPTER must invoke hermes with --safe-mode"

# --- shared fixture builder -------------------------------------------------
# build_request <name> <operation> [stub-body] [diff-bytes] [truncated]
build_request() {
  local name="$1" op="$2" stub="$3" diff_bytes="${4:-40}" truncated="${5:-false}"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf -- '---\nschema: 1\nid: T001\nacceptance_criteria: does the thing\nstop_condition: one pass only\n---\nDo the thing.\n' \
    > "$d/pack/task.md"
  head -c "$diff_bytes" /dev/zero | tr '\0' 'x' > "$d/pack/diff.patch"
  jq -n --argjson bytes "$diff_bytes" --argjson trunc "$truncated" \
    '{budget:65536,total_bytes:$bytes,
      items:[{name:"task.md",bytes:5,truncated:false},
             {name:"diff.patch",bytes:$bytes,truncated:$trunc}],omitted:[]}' \
    > "$d/pack/pack.json"

  if [ -n "$stub" ]; then
    printf '%s\n' "$stub" > "$d/bin/hermes"
    chmod +x "$d/bin/hermes"
  fi

  jq -n --arg job_id "j-$name" --arg task T001 --arg op "$op" \
    --arg worktree "$d/worktree" --arg input_pack "$d/pack" --arg output "$d/out/envelope.json" \
    --arg base_sha aaa --arg candidate_sha bbb \
    '{request:1, job_id:$job_id, task:$task, attempt:1, role:"x", operation:$op,
      base_sha:$base_sha, candidate_sha:$candidate_sha, worktree:$worktree,
      input_pack:$input_pack, output:$output, deadline_s:3600,
      policy:"read-only", model:"", effort:"medium"}' > "$d/request.json"
  echo "$d"
}

run_adapter() {  # dir
  PATH="$1/bin:$PATH" "$ADAPTER" "$1/request.json"
}

# --- 1. review stub that approves; argv shape asserted ----------------------
d="$(build_request approve review '#!/usr/bin/env bash
printf "%s" "$#" > "'"$WORK"'/approve.argc"
i=0
for a in "$@"; do i=$((i+1)); printf "%s" "$a" > "'"$WORK"'/approve.argv.$i"; done
echo "looks fine"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "approve stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "approve stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "approve stub: status ok"
assert_eq "orchid/hermes" "$(jq -r .engine "$d/out/envelope.json")" "approve stub: engine id stamped"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "approve stub: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "approve stub: scope_complete true (no truncation)"
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "approve stub: findings placeholder empty array for review"
argc="$(cat "$WORK/approve.argc")"
assert_eq "5" "$argc" "approve stub: exactly five argv (--safe-mode -t clarify -z <prompt>)"
assert_eq "--safe-mode" "$(cat "$WORK/approve.argv.1")" "approve stub: --safe-mode present"
assert_eq "-t" "$(cat "$WORK/approve.argv.2")" "approve stub: -t precedes the toolset name"
assert_eq "clarify" "$(cat "$WORK/approve.argv.3")" "approve stub: toolset restricted to clarify"
assert_eq "-z" "$(cat "$WORK/approve.argv.4")" "approve stub: -z precedes the prompt"
last_argv="$(cat "$WORK/approve.argv.5")"
assert_match "VERDICT: approve OR request-changes" "$last_argv" "approve stub: prompt is the final argv"
assert_match "^Acceptance criteria: does the thing" "$last_argv" "approve stub: prompt carries acceptance criteria"
assert_match "Do not use any tools" "$last_argv" "approve stub: prompt forbids tool use"
assert_eq "false" "$(jq -r 'has("summary")' "$d/out/envelope.json")" "approve stub: summary absent when no REASON line"

# --- 2. truncated pack -> scope_complete false ------------------------------
d="$(build_request truncated review '#!/usr/bin/env bash
echo "VERDICT: approve"' 40 true)"
run_adapter "$d" || fail "truncated stub: adapter should exit 0"
assert_eq "false" "$(jq -r .scope_complete "$d/out/envelope.json")" "truncated stub: scope_complete false"

# --- 3. request-changes verdict, last VERDICT line wins ---------------------
d="$(build_request reqchanges critique '#!/usr/bin/env bash
echo "VERDICT: approve (draft, ignore)"
echo "one more look..."
echo "VERDICT: request-changes"')"
run_adapter "$d" || fail "reqchanges stub: adapter should exit 0"
assert_eq "request-changes" "$(jq -r .verdict "$d/out/envelope.json")" "reqchanges stub: last VERDICT line wins"

# --- 4. malformed: no VERDICT line -------------------------------------------
d="$(build_request noverdict review '#!/usr/bin/env bash
echo "rambling, no reply contract"')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "noverdict stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "noverdict stub: status malformed"

# --- 5. failing stub: rate limit on stderr ----------------------------------
d="$(build_request ratelimit review '#!/usr/bin/env bash
echo "429 usage limit exceeded" >&2
exit 1')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "ratelimit stub: adapter should exit nonzero"
assert_eq "rate_limited" "$(jq -r .status "$d/out/envelope.json")" "ratelimit stub: status rate_limited"

# --- 5b. failing stub: auth error -------------------------------------------
d="$(build_request authfail review '#!/usr/bin/env bash
echo "Unauthorized: please login" >&2
exit 1')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "authfail stub: adapter should exit nonzero"
assert_eq "auth" "$(jq -r .status "$d/out/envelope.json")" "authfail stub: status auth"

# --- 6. oversized diff: failed WITHOUT invoking hermes (default 100000 cap) -
d="$(build_request oversize review '#!/usr/bin/env bash
printf "%s\n" "$@" > "'"$WORK"'/oversize.argv"
echo "VERDICT: approve"' 200000)"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "oversize: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "oversize: status failed"
[ ! -e "$WORK/oversize.argv" ] || fail "oversize: hermes must never be invoked when the byte guard trips"

# --- 6b. custom hermes_max_bytes via env override (config_get precedence) --
d="$(build_request customcap review '#!/usr/bin/env bash
printf "%s\n" "$@" > "'"$WORK"'/customcap.argv"
echo "VERDICT: approve"' 500)"
rc=0; ORCHID_HERMES_MAX_BYTES=100 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "customcap: adapter should exit nonzero (500 > 100 override)"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "customcap: status failed"
[ ! -e "$WORK/customcap.argv" ] || fail "customcap: hermes must never be invoked when override cap trips"

# --- 6c. exact-match guard: last VERDICT line is the ECHOED instruction -----
# ("VERDICT: approve OR request-changes") — never actually chose a verdict.
# Must be MALFORMED, never approve.
d="$(build_request echoedinstruction review '#!/usr/bin/env bash
echo "thinking it over..."
echo "VERDICT: approve OR request-changes"')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "echoed-instruction stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "echoed-instruction stub: status malformed (not approve)"

# --- 7. unsupported operations -----------------------------------------------
for badop in implement orchestrate research bogus; do
  d="$(build_request "badop_$badop" "$badop" "")"
  rm -rf "${d:?}/bin"
  rc=0; run_adapter "$d" || rc=$?
  [ "$rc" -ne 0 ] || fail "badop($badop): adapter should exit nonzero"
  assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop($badop): status failed"
done

# --- 8. DRYRUN: review, no spawn (no hermes on PATH at all) -----------------
d="$(build_request dryreview review "")"
rm -rf "${d:?}/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun review: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun review: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun review: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "dryrun review: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "dryrun review: scope_complete true"
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "dryrun review: findings placeholder empty array"

# --- 8b. DRYRUN + unsupported operation: fails identically, no spawn -------
d="$(build_request dryimplement implement '#!/usr/bin/env bash
printf "%s\n" "$@" > "'"$WORK"'/dryimplement.argv"
echo "VERDICT: approve"')"
rc=0; ORCHID_DRYRUN=1 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "dryrun implement: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "dryrun implement: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "dryrun implement: status failed"
[ ! -e "$WORK/dryimplement.argv" ] || fail "dryrun implement: hermes must never be invoked (no spawn)"

# --- 9. tool-denial emptiness: empty stdout, rc 0 -> malformed, raw reply
# diagnosed on stderr (same F6-class fix as plugins/engines/agy/run).
d="$(build_request emptyreply review '#!/usr/bin/env bash
: ')"
rc=0; stderr_out="$(run_adapter "$d" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "emptyreply stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "emptyreply stub: status malformed"
assert_match "malformed reply .no VERDICT line.; raw output follows" "$stderr_out" "emptyreply stub: raw-output diagnostic marker on stderr"

# --- 10. REASON line captured into the ok-envelope's summary ----------------
d="$(build_request withreason review '#!/usr/bin/env bash
echo "VERDICT: approve"
echo "REASON: tests pass and the diff is scoped tightly"')"
run_adapter "$d" || fail "withreason stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "withreason stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "withreason stub: status ok"
assert_match "tests pass and the diff is scoped tightly" "$(jq -r .summary "$d/out/envelope.json")" "withreason stub: summary carries REASON text"

d="$(build_request reasoncap review '#!/usr/bin/env bash
echo "VERDICT: approve"
echo "REASON: $(printf "x%.0s" $(seq 1 400))"')"
run_adapter "$d" || fail "reasoncap stub: adapter should exit 0"
summary_len="$(jq -r '.summary | length' "$d/out/envelope.json")"
[ "$summary_len" -le 200 ] || fail "reasoncap stub: summary must be capped at 200 chars (got $summary_len)"

# --- 11. critique: FINDING: lines parsed into findings[] (review stays
# verdict-only, unaffected -- see test 1 above). ----------------------------
d="$(build_request critiquefindings critique '#!/usr/bin/env bash
echo "VERDICT: request-changes"
echo "FINDING: medium: missing rollback plan for T002"
echo "FINDING: low: acceptance criteria too vague on T003"
echo "FINDING: bogus-severity: should be dropped"')"
run_adapter "$d" || fail "critique findings stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "critique findings stub: envelope invalid"
assert_eq "request-changes" "$(jq -r .verdict "$d/out/envelope.json")" "critique findings stub: verdict parsed"
assert_eq "2" "$(jq '.findings | length' "$d/out/envelope.json")" "critique findings stub: only well-formed FINDING lines parsed"
assert_eq "medium" "$(jq -r '.findings[0].severity' "$d/out/envelope.json")" "critique findings stub: first finding severity"
assert_eq "missing rollback plan for T002" "$(jq -r '.findings[0].title' "$d/out/envelope.json")" "critique findings stub: first finding title"
assert_eq "low" "$(jq -r '.findings[1].severity' "$d/out/envelope.json")" "critique findings stub: second finding severity"

# --- 12. plan-critique pack (task id `plan`, role.plan_critic; no task.md/
# diff.patch at all -- lib/pack.sh's _pack_build_plan). Unlike agy (which
# refuses this shape outright), hermes builds a prompt from requirements.md +
# roadmap.md + tasks.md, same as codex/claude's own plan-critique branch.
build_plan_request() {  # name stub -> prints path to request.json's dir
  local name="$1" stub="$2"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf '# Requirements\nShip the widget end to end.\n' > "$d/pack/requirements.md"
  printf -- '---\nrun_status: planning\n---\n# Roadmap\n- T001: build the widget\n' > "$d/pack/roadmap.md"
  printf -- '---\nid: T001\n---\nBuild the widget.\n' > "$d/pack/tasks.md"
  printf '{"budget":65536,"total_bytes":10,"items":[{"name":"requirements.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
    > "$d/pack/pack.json"
  [ -n "$stub" ] && { printf '%s\n' "$stub" > "$d/bin/hermes"; chmod +x "$d/bin/hermes"; }
  jq -n --arg job_id "j-$name" \
    --arg worktree "$d/worktree" --arg input_pack "$d/pack" --arg output "$d/out/envelope.json" \
    '{request:1, job_id:$job_id, task:"plan", attempt:1, role:"plan_critic", operation:"critique",
      base_sha:"", candidate_sha:"", worktree:$worktree,
      input_pack:$input_pack, output:$output, deadline_s:3600,
      policy:"read-only", model:"", effort:"medium"}' > "$d/request.json"
  echo "$d"
}

d="$(build_plan_request plancritique '#!/usr/bin/env bash
echo "VERDICT: request-changes"
echo "FINDING: medium: missing rollback plan for T002"')"
run_adapter "$d" || fail "plan critique stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "plan critique stub: envelope invalid"
assert_eq "request-changes" "$(jq -r .verdict "$d/out/envelope.json")" "plan critique stub: verdict parsed"
assert_eq "1" "$(jq '.findings | length' "$d/out/envelope.json")" "plan critique stub: FINDING line parsed into findings[]"

d="$(build_plan_request planprompt '#!/usr/bin/env bash
cat > "'"$WORK"'/planprompt.stdin" 2>/dev/null || true
printf "%s\n" "$@" > "'"$WORK"'/planprompt.argv"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "plan prompt stub: adapter should exit 0"
captured="$(cat "$WORK/planprompt.argv")"
assert_match "Requirements:" "$captured" "plan prompt: requirements section present"
assert_match "Ship the widget end to end." "$captured" "plan prompt: requirements body present"
assert_match "Draft roadmap:" "$captured" "plan prompt: roadmap section present"
assert_match "Build the widget." "$captured" "plan prompt: tasks.md body present"
case "$captured" in *"Diff:"*) fail "plan prompt: must never contain the diff-based review prompt shape" ;; esac
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "plan prompt stub: approve-only reply still yields empty findings[]"

# --- 13. plan pack via `review` (not critique): verdict-only contract,
# findings[] stays empty even though the reply carries a FINDING: line
# (review's contract never asks for one). --------------------------------
d="$WORK/planreview"
mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
printf '# Requirements\nShip the widget.\n' > "$d/pack/requirements.md"
printf -- '---\nrun_status: planning\n---\n# Roadmap\n' > "$d/pack/roadmap.md"
printf -- '---\nid: T001\n---\nBuild the widget.\n' > "$d/pack/tasks.md"
printf '{"budget":65536,"total_bytes":10,"items":[{"name":"requirements.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
  > "$d/pack/pack.json"
printf '#!/usr/bin/env bash\necho "VERDICT: approve"\necho "FINDING: high: ignored for review"\n' > "$d/bin/hermes"
chmod +x "$d/bin/hermes"
jq -n --arg job_id "j-planreview" \
  --arg worktree "$d/worktree" --arg input_pack "$d/pack" --arg output "$d/out/envelope.json" \
  '{request:1, job_id:$job_id, task:"plan", attempt:1, role:"plan_critic", operation:"review",
    base_sha:"", candidate_sha:"", worktree:$worktree,
    input_pack:$input_pack, output:$output, deadline_s:3600,
    policy:"read-only", model:"", effort:"medium"}' > "$d/request.json"
run_adapter "$d" || fail "plan review stub: adapter should exit 0"
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "plan review stub: findings stay empty for review (not critique)"

# --- 14. v1-m3-style log streaming: job log must grow WHILE the adapter is
# still running (stall-detector liveness signal), not just after exit. ------
#
# T019 (lesson L020): one of eight sites that used to answer that question by
# sleeping a fixed 0.2s and reading the log ONCE. That is a deadline, not a
# liveness check, and a loaded machine misses it -- eight tasks in r-002 were
# stranded and charged a rework attempt for a scheduling artifact. The
# sampler now waits, bounded, for what it samples, and the stub is held open
# until it has, so "still running" is a fact rather than a race. All the
# edges of the shared helpers are pinned in tests/test_engine_agy.sh (12b, 12c
# and 12d, which is why heartbeat lines do not count as growth here);
# tests/helpers.sh carries the full narrative.
d="$(build_request streaming review '#!/usr/bin/env bash
echo "line one"
'"$(stub_hold_until "$WORK/streaming.release")"'
echo "line two"
echo "VERDICT: approve"')"
joblog="$d/out/job.log"; : > "$joblog"
(run_adapter "$d" >>"$joblog" 2>&1) &
adapter_pid=$!
midrun_grew=no
await_log_growth "$joblog" "$adapter_pid" && midrun_grew=yes
midrun_size="$(wc -c <"$joblog" | tr -d ' ')"
release_stub "$WORK/streaming.release"   # only now may the stub reach its VERDICT
wait "$adapter_pid" || fail "streaming stub: adapter should exit 0"
final_size="$(wc -c <"$joblog" | tr -d ' ')"
assert_eq "yes" "$midrun_grew" "streaming stub: bounded growth wait must observe live stream bytes before adapter exit -- this is the stall-detector's liveness signal"
[ "$final_size" -ge "$midrun_size" ] || fail "streaming stub: job log must not shrink after the adapter exits"
assert_match "line one" "$(cat "$joblog")" "streaming stub: the CLI's early output reached the job log"
envelope_validate "$d/out/envelope.json" || fail "streaming stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "streaming stub: status ok"

# --- 15. adapter heartbeat: a CLI that writes NOTHING until the very end
# still grows the job log mid-run via lib/heartbeat.sh's `[hb ...]` line. --
#
# T019 (lesson L020): the heartbeat half of the same family as case 14 above.
# It used to sleep 1.3s and count `[hb ` lines at that instant, which makes a
# deadline out of a liveness property; same fix, same shared helpers.
d="$(build_request heartbeat review '#!/usr/bin/env bash
'"$(stub_hold_until "$WORK/heartbeat.release")"'
echo "VERDICT: approve"
echo "REASON: heartbeat test reply"')"
joblog="$d/out/job.log"; : > "$joblog"
initial_mtime="$(file_mtime "$joblog")"
( ORCHID_HB_INTERVAL_S=1 run_adapter "$d" >>"$joblog" 2>&1 ) &
adapter_pid=$!
midrun_hb=no
await_log_heartbeat "$joblog" "$adapter_pid" && midrun_hb=yes
midrun_hb_count="$(grep -c '^\[hb ' "$joblog" 2>/dev/null || true)"; midrun_hb_count="${midrun_hb_count:-0}"
midrun_mtime="$(file_mtime "$joblog")"
release_stub "$WORK/heartbeat.release"   # only now may the stub reach its VERDICT
wait "$adapter_pid" || fail "heartbeat stub: adapter should exit 0"
assert_eq "yes" "$midrun_hb" "heartbeat stub: a [hb line must appear WHILE the adapter is still running -- waited for, not sampled at one instant"
[ "$midrun_hb_count" -ge 1 ] || fail "heartbeat stub: bounded heartbeat wait must leave at least one persisted [hb line before adapter exit"
[ "$midrun_mtime" -ge "$initial_mtime" ] || fail "heartbeat stub: job log mtime must have advanced mid-run (initial=$initial_mtime midrun=$midrun_mtime)"
envelope_validate "$d/out/envelope.json" || fail "heartbeat stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "heartbeat stub: status ok"
assert_match "heartbeat test reply" "$(jq -r .summary "$d/out/envelope.json")" "heartbeat stub: summary carries the real REASON text"
summary_val="$(jq -r .summary "$d/out/envelope.json")"
case "$summary_val" in *'[hb '*) fail "heartbeat stub: a heartbeat line leaked into the envelope summary" ;; esac

# --- 16. `orchid plugins conform plugins/engines/hermes` -> 7/7 (DRYRUN
# only; never spends real quota, never shells to the real hermes CLI). ------
conform_out="$("$REPO_ROOT/bin/orchid" plugins conform "$REPO_ROOT/plugins/engines/hermes" 2>&1)"
rc=0; printf '%s\n' "$conform_out" | grep -q '^7/7 checks passed$' || rc=1
[ "$rc" -eq 0 ] || fail "plugins conform plugins/engines/hermes: expected 7/7, got:
$conform_out"
