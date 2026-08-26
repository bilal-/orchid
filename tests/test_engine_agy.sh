#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/common.sh"   # file_mtime (portable BSD/GNU stat mtime)
ADAPTER="$REPO_ROOT/plugins/engines/agy/run"

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
    printf '%s\n' "$stub" > "$d/bin/agy"
    chmod +x "$d/bin/agy"
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
# argv elements are dumped one-per-file (NOT newline-joined: the prompt itself
# is multi-line, so a naive `printf '%s\n' "$@"` would make line-counting lie).
d="$(build_request approve review '#!/usr/bin/env bash
printf "%s" "$#" > "'"$WORK"'/approve.argc"
i=0
for a in "$@"; do i=$((i+1)); printf "%s" "$a" > "'"$WORK"'/approve.argv.$i"; done
echo "looks fine"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "approve stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "approve stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "approve stub: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "approve stub: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "approve stub: scope_complete true (no truncation)"
argc="$(cat "$WORK/approve.argc")"
assert_eq "2" "$argc" "approve stub: exactly two argv (flags before -p, then the prompt)"
assert_eq "-p" "$(cat "$WORK/approve.argv.1")" "approve stub: -p precedes the prompt"
last_argv="$(cat "$WORK/approve.argv.2")"
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

# --- 6. oversized diff: failed WITHOUT invoking agy (default 100000 cap) ---
d="$(build_request oversize review '#!/usr/bin/env bash
printf "%s\n" "$@" > "'"$WORK"'/oversize.argv"
echo "VERDICT: approve"' 200000)"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "oversize: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "oversize: status failed"
[ ! -e "$WORK/oversize.argv" ] || fail "oversize: agy must never be invoked when the byte guard trips"
# v1-m5 (T008): the byte guard is a CAPABILITY REFUSAL, and the envelope has
# to say so -- `status` alone cannot tell lib/ledger.sh apart from an engine
# that crashed, which is how three ~1%-over refusals marked agy `failing` on
# r-002 and cost that run a reviewer.
envelope_validate "$d/out/envelope.json" || fail "oversize: refusal envelope must still be valid"
assert_eq "capability" "$(jq -r '.failure_kind // "absent"' "$d/out/envelope.json")" "oversize: the byte-cap refusal is marked failure_kind capability, not an engine fault"

# --- 6b. custom agy_max_bytes via env override (config_get precedence) -----
d="$(build_request customcap review '#!/usr/bin/env bash
printf "%s\n" "$@" > "'"$WORK"'/customcap.argv"
echo "VERDICT: approve"' 500)"
rc=0; ORCHID_AGY_MAX_BYTES=100 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "customcap: adapter should exit nonzero (500 > 100 override)"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "customcap: status failed"
[ ! -e "$WORK/customcap.argv" ] || fail "customcap: agy must never be invoked when override cap trips"

# --- 6c. exact-match guard: last VERDICT line is the ECHOED instruction ----
# ("VERDICT: approve OR request-changes") — never actually chose a verdict.
# Must be MALFORMED, never approve.
d="$(build_request echoedinstruction review '#!/usr/bin/env bash
echo "thinking it over..."
echo "VERDICT: approve OR request-changes"')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "echoed-instruction stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "echoed-instruction stub: status malformed (not approve)"
# The other half of the T008 distinction: an unparseable reply IS evidence the
# engine misbehaved, so it must carry no capability marker and must go on
# counting toward engine_fail_threshold.
assert_eq "absent" "$(jq -r '.failure_kind // "absent"' "$d/out/envelope.json")" "echoed-instruction stub: a genuine fault must never be marked a capability refusal"

# --- 7. unsupported operation -----------------------------------------------
d="$(build_request badop implement "")"
rm -rf "${d:?}/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"
assert_eq "capability" "$(jq -r '.failure_kind // "absent"' "$d/out/envelope.json")" "badop: declining an operation agy never claimed is a capability refusal, not an engine fault"

# --- 8. DRYRUN: review, no spawn (no agy on PATH at all) --------------------
d="$(build_request dryreview review "")"
rm -rf "${d:?}/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun review: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun review: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun review: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "dryrun review: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "dryrun review: scope_complete true"

# --- 9. DRYRUN + unsupported operation: fails identically, no spawn --------
d="$(build_request dryimplement implement '#!/usr/bin/env bash
printf "%s\n" "$@" > "'"$WORK"'/dryimplement.argv"
echo "VERDICT: approve"')"
rc=0; ORCHID_DRYRUN=1 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "dryrun implement: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "dryrun implement: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "dryrun implement: status failed"
[ ! -e "$WORK/dryimplement.argv" ] || fail "dryrun implement: agy must never be invoked (no spawn)"

# --- 10. tool-denial emptiness: empty stdout, rc 0 -> malformed, AND the raw
# reply is diagnosed on stderr (dogfood F6: headless print-mode auto-denies
# a tool call, agy exits 0 with nothing on stdout, and previously nothing
# was ever logged anywhere to explain the empty envelope).
d="$(build_request emptyreply review '#!/usr/bin/env bash
: ')"
rc=0; stderr_out="$(run_adapter "$d" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "emptyreply stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "emptyreply stub: status malformed"
assert_match "malformed reply .no VERDICT line.; raw output follows" "$stderr_out" "emptyreply stub: raw-output diagnostic marker on stderr"

# --- 11. REASON line captured into the ok-envelope's summary ----------------
d="$(build_request withreason review '#!/usr/bin/env bash
echo "VERDICT: approve"
echo "REASON: tests pass and the diff is scoped tightly"')"
run_adapter "$d" || fail "withreason stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "withreason stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "withreason stub: status ok"
assert_match "tests pass and the diff is scoped tightly" "$(jq -r .summary "$d/out/envelope.json")" "withreason stub: summary carries REASON text"

# --- 12. v1-m3 log streaming: the live-run finding was that a job log
# stayed ZERO BYTES for the whole run (agy/run captured the CLI's output
# purely into a bash variable, with nothing written to its own stdout/
# stderr -- which is what the launcher's redirect actually captures into the
# job log). The fix tees agy's stdout to the adapter's own stderr as it
# arrives. Simulate the launcher's redirect here (`>> log 2>&1`) around a
# stub agy, and assert the log has grown partway through the run -- not just
# after the adapter exits.
#
# T019 (lesson L020): this case used to read the log at ONE fixed instant
# (0.2s after launch) and assert it was already non-empty. On a loaded
# machine the adapter can take longer than that to relay its first byte, so
# the assertion failed for a scheduling reason and stranded six otherwise-
# clean tasks in r-002. The property it checks is LIVENESS -- the log grows
# while the adapter is still running -- so the sampler waits, bounded, for
# what it samples, and the stub cannot exit until this test releases it,
# which removes the race outright instead of widening the window.
#
# The sampler and the hold are tests/helpers.sh's `await_log_growth` and
# `stub_hold_until`, SHARED with the seven sibling sites that carry the same
# shape -- the streaming and heartbeat cases of all four engine-adapter test
# files. Cases 12b, 12c and 12d below pin every edge of that shared sampler
# once, on behalf of all eight -- including the one the waiting introduced:
# `[hb ` lines do not count as growth, so the longer window cannot be filled
# by the heartbeat and read as streaming.
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
assert_eq "yes" "$midrun_grew" "streaming stub: job log must have grown WHILE the adapter was still running -- this is the stall-detector's liveness signal"
[ "$final_size" -ge "$midrun_size" ] || fail "streaming stub: job log must not shrink after the adapter exits"
assert_match "line one" "$(cat "$joblog")" "streaming stub: the CLI's early output reached the job log"
envelope_validate "$d/out/envelope.json" || fail "streaming stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "streaming stub: status ok"

# --- 12b. L020's loaded-machine edge, pinned for the WHOLE family: the first
# byte arrives LATE -- well past the 0.2s instant the old single-sample read
# -- but within the bound. Under the pre-T019 shape this exact stub failed
# the suite and charged a rework attempt; a late start is slowness, not a
# stall, and the bounded sampler must ride it out. Asserted against the
# shared helper, so it holds for every site that uses it, not just this one.
d="$(build_request slowstart review '#!/usr/bin/env bash
sleep 1.2
echo "slow first line"
'"$(stub_hold_until "$WORK/slowstart.release")"'
echo "VERDICT: approve"')"
joblog="$d/out/job.log"; : > "$joblog"
(run_adapter "$d" >>"$joblog" 2>&1) &
adapter_pid=$!
slowstart_grew=no
await_log_growth "$joblog" "$adapter_pid" && slowstart_grew=yes
release_stub "$WORK/slowstart.release"
wait "$adapter_pid" || fail "slowstart stub: adapter should exit 0"
assert_eq "yes" "$slowstart_grew" "slowstart stub (L020): a first byte that is merely late, still inside the bound, must not read as a stall -- wait for what you sample"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "slowstart stub: status ok"

# --- 12c. L020's other edge, also on behalf of the whole family: a GENUINE
# stall -- a producer that stays alive and never writes a byte -- must still
# be reported, by BOTH shared samplers. Drive each against a mute sleeper
# with a short bound: each must exhaust the bound and fail, not pass
# vacuously, whichever way the scheduler leans. This is what keeps the
# de-flaking from having quietly deleted the property: the growth sampler
# still catches an adapter that never relays a byte, and the heartbeat
# sampler still catches one whose `[hb ` line never fires. -----------------
# The mute producer outlives both bounds by a wide margin ON PURPOSE. If it
# could exit first the sampler would still return failure -- so the assertions
# below would still pass -- but for the wrong reason, and this case would stop
# demonstrating that an EXHAUSTED BOUND is what reports a stall.
stall_log="$WORK/stall.log"; : > "$stall_log"
sleep 30 &
stall_pid=$!
stall_rc=0
await_log_growth "$stall_log" "$stall_pid" 8 || stall_rc=$?
stall_hb_rc=0
printf 'not a heartbeat line\n' > "$stall_log"
await_log_heartbeat "$stall_log" "$stall_pid" 8 || stall_hb_rc=$?
kill "$stall_pid" 2>/dev/null
wait "$stall_pid" 2>/dev/null
[ "$stall_rc" -ne 0 ] || fail "stall detector: a log that never grows while its producer stays alive must still be caught -- the liveness property is real and the sampler must not wave it through"
[ "$stall_hb_rc" -ne 0 ] || fail "stall detector: a log that grows with NON-heartbeat output while its producer stays alive must still read as a missing heartbeat -- the heartbeat cases mean [hb specifically, not any byte"

# --- 12d. THE HOLE THE DE-FLAKING WOULD OTHERWISE HAVE OPENED, pinned both
# ways for the whole family. Waiting instead of sampling one instant is the
# right fix, but it lengthens the window the streaming cases sit inside -- and
# something else writes into that same job log while they wait:
# lib/heartbeat.sh's `[hb ` line, which fires PRECISELY WHEN THE CLI HAS
# WRITTEN NOTHING, because that is what it is for. The streaming fixtures do
# not override ORCHID_HB_INTERVAL_S (only the heartbeat fixtures do), so they
# run at the real 30s default and the growth sampler's own bound is 30s: the
# two coincide, and a sampler that counted BYTES would accept the very defect
# these cases exist to catch -- an adapter relaying not one byte until exit,
# whose log grows on the heartbeat alone.
#
# So the growth sampler ignores `[hb ` lines, and both edges of that are pinned
# here rather than left to the comment in tests/helpers.sh. RED: heartbeats
# alone are NOT streaming, however many of them arrive. GREEN: heartbeats
# INTERLEAVED with real relayed output are still streaming -- the fix must
# ignore heartbeats, not be confused by them, or every real run (which always
# has both) would read as a stall. Driven against the shared helper directly,
# so it holds for all four engine-adapter files at once.
hbonly_log="$WORK/hbonly.log"
sleep 30 &
hbonly_pid=$!
printf '[hb 2026-08-26T00:00:00Z] engine pid %s cpu 0:00.01\n' "$hbonly_pid" > "$hbonly_log"
printf '[hb 2026-08-26T00:00:01Z] engine pid %s cpu 0:00.02\n' "$hbonly_pid" >> "$hbonly_log"
hbonly_rc=0
await_log_growth "$hbonly_log" "$hbonly_pid" 8 || hbonly_rc=$?
printf 'line one\n' >> "$hbonly_log"
hbmixed_rc=0
await_log_growth "$hbonly_log" "$hbonly_pid" 8 || hbmixed_rc=$?
kill "$hbonly_pid" 2>/dev/null
wait "$hbonly_pid" 2>/dev/null
[ "$hbonly_rc" -ne 0 ] || fail "stall detector: a job log that has grown ONLY by heartbeat lines must NOT read as streaming -- the heartbeat fires exactly when the CLI has produced nothing, so counting its bytes as growth would wave through the buffered-until-exit defect this case exists to catch (L020's fix must not open that hole)"
[ "$hbmixed_rc" -eq 0 ] || fail "stall detector: real relayed output INTERLEAVED with heartbeat lines must still read as streaming -- every live run carries both, so a growth check that heartbeats can spoil would report a stall on every healthy adapter"

# --- 13. v1-m3 round 2: adapter heartbeat. probe-stream-buffering.sh's real
# run (codex/claude only -- agy wasn't part of that probe, but the same
# buffering risk applies to any CLI) showed tee alone doesn't help a CLI
# that produces literally NOTHING until it exits (worse than the streaming
# test above, whose stub at least gives tee something to relay while it
# runs). The stub below sleeps the WHOLE time and writes not one byte until
# the very end; the ONLY thing that can make the job log grow mid-run here
# is lib/heartbeat.sh's `[hb ...]` liveness line, written to the adapter's
# own stderr (never the stub's stdout) every ORCHID_HB_INTERVAL_S seconds.
# Set to 1 here as a TEST-ONLY override (real default is 30s, see
# lib/heartbeat.sh) so the fixture doesn't need to wait out a real 30s
# interval. Also pins that heartbeat lines never leak into summary parsing
# (they're on stderr, structurally separate from the stub's real stdout --
# $stdout is filled purely from the FIFO-relayed stdout content -- but
# pinned here rather than left implicit).
#
# T019 (lesson L020): this is the SECOND shape of the same fault as case 12
# above -- it used to sleep 1.3s and count `[hb ` lines at that one instant,
# which is a deadline for the heartbeat rather than a test that one fires.
# Same fix, same shared helpers: hold the stub open until the sampler has
# seen a heartbeat, and only then let it exit.
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
[ "$midrun_hb_count" -ge 1 ] || fail "heartbeat stub: job log must gain at least one [hb line WHILE the adapter is still running (stub produced zero output of its own until exit) -- this is the liveness signal the stall detector depends on"
[ "$midrun_mtime" -ge "$initial_mtime" ] || fail "heartbeat stub: job log mtime must have advanced mid-run (initial=$initial_mtime midrun=$midrun_mtime)"
envelope_validate "$d/out/envelope.json" || fail "heartbeat stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "heartbeat stub: status ok"
assert_match "heartbeat test reply" "$(jq -r .summary "$d/out/envelope.json")" "heartbeat stub: summary carries the real REASON text, unaffected by interleaved heartbeat lines"
summary_val="$(jq -r .summary "$d/out/envelope.json")"
case "$summary_val" in *'[hb '*) fail "heartbeat stub: a heartbeat line leaked into the envelope summary" ;; esac

# --- v1-m3: a PLAN pack (task id `plan`, role.plan_critic; no task.md/
# diff.patch at all -- see lib/pack.sh's _pack_build_plan) must fail with a
# clean `failed` envelope and a stderr note, never a silent crash (F6-class:
# no envelope at all would leave reconcile never seeing the job). Built by
# hand rather than via build_request, which always creates task.md/
# diff.patch.
d="$WORK/planpack"
mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
printf '# Requirements\nShip the widget.\n' > "$d/pack/requirements.md"
printf -- '---\nrun_status: planning\n---\n# Roadmap\n' > "$d/pack/roadmap.md"
printf -- '---\nid: T001\n---\nBuild the widget.\n' > "$d/pack/tasks.md"
printf '{"budget":65536,"total_bytes":10,"items":[{"name":"requirements.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
  > "$d/pack/pack.json"
jq -n --arg job_id "j-planpack" \
  --arg worktree "$d/worktree" --arg input_pack "$d/pack" --arg output "$d/out/envelope.json" \
  '{request:1, job_id:$job_id, task:"plan", attempt:1, role:"plan_critic", operation:"critique",
    base_sha:"", candidate_sha:"", worktree:$worktree,
    input_pack:$input_pack, output:$output, deadline_s:3600,
    policy:"read-only", model:"", effort:"medium"}' > "$d/request.json"
rc=0; stderr_out="$(run_adapter "$d" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan pack: adapter must exit nonzero, never silently succeed"
assert_match "agy has no plan-critique mode" "$stderr_out" "plan pack: stderr note explains why"
envelope_validate "$d/out/envelope.json" || fail "plan pack: a failed envelope must still be written and valid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "plan pack: status failed (never a silent crash with no envelope at all)"
assert_eq "capability" "$(jq -r '.failure_kind // "absent"' "$d/out/envelope.json")" "plan pack: having no plan-critique mode is a capability refusal, not an engine fault"
