#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
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

# --- 7. unsupported operation -----------------------------------------------
d="$(build_request badop implement "")"
rm -rf "$d/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"

# --- 8. DRYRUN: review, no spawn (no agy on PATH at all) --------------------
d="$(build_request dryreview review "")"
rm -rf "$d/bin"
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
