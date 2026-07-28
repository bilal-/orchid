#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
ADAPTER="$REPO_ROOT/plugins/engines/claude/run"

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
    printf '%s\n' "$stub" > "$d/bin/claude"
    chmod +x "$d/bin/claude"
  fi

  # worktree is a real git repo (as it always is in production — either the
  # main repo or a task worktree) so the implement path's `git rev-list
  # base_sha..HEAD` commit capture has something real to walk.
  (cd "$d/worktree" && git init -q . \
    && git -c user.email=test@orchid.local -c user.name="Orchid Test" \
         commit -q --allow-empty -m root) >/dev/null 2>&1
  local base_sha; base_sha="$(git -C "$d/worktree" rev-parse HEAD)"

  jq -n --arg job_id "j-$name" --arg task T001 --arg op "$op" \
    --arg worktree "$d/worktree" --arg input_pack "$d/pack" --arg output "$d/out/envelope.json" \
    --arg base_sha "$base_sha" --arg candidate_sha bbb \
    '{request:1, job_id:$job_id, task:$task, attempt:1, role:"x", operation:$op,
      base_sha:$base_sha, candidate_sha:$candidate_sha, worktree:$worktree,
      input_pack:$input_pack, output:$output, deadline_s:3600,
      policy:"workspace-write", model:"", effort:"medium"}' > "$d/request.json"
  echo "$d"
}

run_adapter() {  # dir
  PATH="$1/bin:$PATH" "$ADAPTER" "$1/request.json"
}

# --- 1. review stub that approves; argv shape asserted (read-only prompting,
# no --permission-mode flag: exactly one argv, -p; the prompt itself now
# arrives on STDIN -- v0b2 F2, same stdin fix as the codex adapter) --------
d="$(build_request approve review '#!/usr/bin/env bash
printf "%s" "$#" > "'"$WORK"'/approve.argc"
i=0
for a in "$@"; do i=$((i+1)); printf "%s" "$a" > "'"$WORK"'/approve.argv.$i"; done
cat > "'"$WORK"'/approve.stdin"
echo "looks fine"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "approve stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "approve stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "approve stub: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "approve stub: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "approve stub: scope_complete true (no truncation in pack.json)"
argc="$(cat "$WORK/approve.argc")"
assert_eq "1" "$argc" "approve stub: review is read-only prompting, exactly one argv (-p only)"
assert_eq "-p" "$(cat "$WORK/approve.argv.1")" "approve stub: -p is the only argv"
stdin_content="$(cat "$WORK/approve.stdin")"
assert_match "VERDICT: approve" "$stdin_content" "approve stub: prompt (carrying the reply contract) arrives on stdin"
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "approve stub: findings placeholder empty array"

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

# --- 5. implement success: summary from last non-empty stdout line; argv
# shape asserted (acceptEdits: three argv, -p --permission-mode acceptEdits;
# the prompt itself now arrives on STDIN -- v0b2 F2, same stdin fix as the
# codex adapter, removing the leading-dash argv risk since task.md
# frontmatter starts with "---") --------------------------------------------
d="$(build_request implsuccess implement '#!/usr/bin/env bash
printf "%s" "$#" > "'"$WORK"'/implsuccess.argc"
i=0
for a in "$@"; do i=$((i+1)); printf "%s" "$a" > "'"$WORK"'/implsuccess.argv.$i"; done
cat > "'"$WORK"'/implsuccess.stdin"
echo "working..."
echo ""
echo "Implemented the feature end to end."')"
run_adapter "$d" || fail "implement stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "implement stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "implement stub: status ok"
assert_eq "Implemented the feature end to end. (no commits produced)" "$(jq -r .summary "$d/out/envelope.json")" "implement stub: summary from last non-empty line, no-commits noted"
assert_eq "[]" "$(jq -c .commits "$d/out/envelope.json")" "implement stub: empty commits array when no commits made"
argc="$(cat "$WORK/implsuccess.argc")"
assert_eq "3" "$argc" "implement stub: acceptEdits permission mode, exactly three argv (no prompt argv)"
assert_eq "-p" "$(cat "$WORK/implsuccess.argv.1")" "implement stub: -p is first argv"
assert_eq "--permission-mode" "$(cat "$WORK/implsuccess.argv.2")" "implement stub: --permission-mode is second argv"
assert_eq "acceptEdits" "$(cat "$WORK/implsuccess.argv.3")" "implement stub: acceptEdits is third argv"
stdin_content="$(cat "$WORK/implsuccess.stdin")"
assert_match "Do the thing." "$stdin_content" "implement stub: full task body arrives on stdin, not argv"

# --- 5b. implement success: stub actually commits in the worktree -> the
# envelope's commits[] contains that real sha, and the summary is untouched
# (no "no commits produced" note) -------------------------------------------
d="$(build_request implcommit implement '#!/usr/bin/env bash
echo "did the work" > done.txt
git add done.txt
git -c user.email=test@orchid.local -c user.name="Orchid Test" commit -q -m "stub commit"
echo "Implemented and committed."')"
run_adapter "$d" || fail "implement+commit stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "implement+commit stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "implement+commit stub: status ok"
new_sha="$(git -C "$d/worktree" rev-parse HEAD)"
assert_eq "[\"$new_sha\"]" "$(jq -c .commits "$d/out/envelope.json")" "implement+commit stub: commits array contains the new sha"
assert_eq "Implemented and committed." "$(jq -r .summary "$d/out/envelope.json")" "implement+commit stub: summary unchanged when commits present"

# --- 6. DRYRUN: implement, no spawn (no claude on PATH at all) -------------
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
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "dryrun review: findings placeholder empty array"

# --- 8b. exact-match guard: last VERDICT line is the ECHOED instruction ----
# ("VERDICT: approve OR request-changes") — never actually chose a verdict.
# Must be MALFORMED, never approve.
d="$(build_request echoedinstruction review '#!/usr/bin/env bash
echo "thinking it over..."
echo "VERDICT: approve OR request-changes"')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "echoed-instruction stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "echoed-instruction stub: status malformed (not approve)"

# --- 9. unsupported operation ------------------------------------------------
d="$(build_request badop research "")"
rm -rf "$d/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"

# --- 9. DRYRUN + unsupported operation: operation gate precedes DRYRUN, so
# this still fails (no dryrun short-circuit for unknown operations) --------
d="$(build_request dryimplbadop research "")"
rm -rf "$d/bin"
rc=0; ORCHID_DRYRUN=1 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "dryrun badop: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "dryrun badop: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "dryrun badop: status failed (operation gate precedes dryrun)"
