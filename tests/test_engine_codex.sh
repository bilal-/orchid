#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
ADAPTER="$REPO_ROOT/plugins/engines/codex/run"

# --- shared fixture builder -------------------------------------------------
# build_request <name> <operation> [stub-body] -> prints path to request.json
build_request() {
  local name="$1" op="$2" stub="$3"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf -- '---\nschema: 1\nid: T001\nacceptance_criteria: does the thing\nstop_condition: one pass only\n---\nDo the thing.\n' \
    > "$d/pack/task.md"
  echo "some repo context" > "$d/pack/context.md"
  printf 'diff --git a/f b/f\n+changed\n' > "$d/pack/diff.patch"
  printf '{"budget":65536,"total_bytes":10,"items":[{"name":"task.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
    > "$d/pack/pack.json"

  if [ -n "$stub" ]; then
    printf '%s\n' "$stub" > "$d/bin/codex"
    chmod +x "$d/bin/codex"
  fi

  jq -n --arg job_id "j-$name" --arg task T001 --arg op "$op" \
    --arg worktree "$d/worktree" --arg input_pack "$d/pack" --arg output "$d/out/envelope.json" \
    --arg base_sha aaa --arg candidate_sha bbb \
    '{request:1, job_id:$job_id, task:$task, attempt:1, role:"x", operation:$op,
      base_sha:$base_sha, candidate_sha:$candidate_sha, worktree:$worktree,
      input_pack:$input_pack, output:$output, deadline_s:3600,
      policy:"workspace-write", model:"", effort:"medium"}' > "$d/request.json"
  echo "$d"
}

run_adapter() {  # dir
  PATH="$1/bin:$PATH" "$ADAPTER" "$1/request.json"
}

# --- 1. review stub that approves ------------------------------------------
d="$(build_request approve review '#!/usr/bin/env bash
echo "looks fine"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "approve stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "approve stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "approve stub: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "approve stub: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "approve stub: scope_complete true (no truncation in pack.json)"

# --- 2. failing stub: rate limit on stderr ----------------------------------
d="$(build_request ratelimit review '#!/usr/bin/env bash
echo "429 usage limit exceeded" >&2
exit 1')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "ratelimit stub: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "ratelimit stub: envelope invalid"
assert_eq "rate_limited" "$(jq -r .status "$d/out/envelope.json")" "ratelimit stub: status rate_limited"

# --- 3. failing stub: auth error --------------------------------------------
d="$(build_request authfail review '#!/usr/bin/env bash
echo "Unauthorized: please login" >&2
exit 1')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "authfail stub: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "authfail stub: envelope invalid"
assert_eq "auth" "$(jq -r .status "$d/out/envelope.json")" "authfail stub: status auth"

# --- 4. malformed: stub prints no VERDICT line ------------------------------
d="$(build_request noverdict review '#!/usr/bin/env bash
echo "some rambling output with no reply contract"')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "noverdict stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "noverdict stub: status malformed"

# --- 5. implement success: summary from last non-empty stdout line ---------
d="$(build_request implsuccess implement '#!/usr/bin/env bash
echo "working..."
echo ""
echo "Implemented the feature end to end."')"
run_adapter "$d" || fail "implement stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "implement stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "implement stub: status ok"
assert_eq "Implemented the feature end to end." "$(jq -r .summary "$d/out/envelope.json")" "implement stub: summary from last non-empty line"

# --- 6. DRYRUN: implement, no spawn (no codex on PATH at all) ---------------
d="$(build_request dryimpl implement "")"
rm -rf "$d/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun implement: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun implement: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun implement: status ok"
assert_eq "dryrun" "$(jq -r .summary "$d/out/envelope.json")" "dryrun implement: summary dryrun"

# --- 7. DRYRUN: review, no spawn --------------------------------------------
d="$(build_request dryreview review "")"
rm -rf "$d/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun review: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun review: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun review: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "dryrun review: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "dryrun review: scope_complete true"

# --- 8. unsupported operation ------------------------------------------------
d="$(build_request badop research "")"
rm -rf "$d/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"
