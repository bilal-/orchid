#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
ADAPTER="$REPO_ROOT/plugins/engines/codex/run"

# --- shared fixture builder -------------------------------------------------
# build_request <name> <operation> [stub-body] -> prints path to request.json
build_request() {
  local name="$1" op="$2" stub="$3" nocontext="${4:-}"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf -- '---\nschema: 1\nid: T001\nacceptance_criteria: does the thing\nstop_condition: one pass only\n---\nDo the thing.\n' \
    > "$d/pack/task.md"
  [ -n "$nocontext" ] || echo "some repo context" > "$d/pack/context.md"
  printf 'diff --git a/f b/f\n+changed\n' > "$d/pack/diff.patch"
  printf '{"budget":65536,"total_bytes":10,"items":[{"name":"task.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
    > "$d/pack/pack.json"

  if [ -n "$stub" ]; then
    printf '%s\n' "$stub" > "$d/bin/codex"
    chmod +x "$d/bin/codex"
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

# --- 1. review stub that approves ------------------------------------------
d="$(build_request approve review '#!/usr/bin/env bash
echo "looks fine"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "approve stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "approve stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "approve stub: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "approve stub: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "approve stub: scope_complete true (no truncation in pack.json)"
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

# --- 5. v0b2 F3: engine EDITS a file but does NOT commit -> the adapter
# (unsandboxed) stages and commits the edit itself. commits[] must contain
# exactly one real sha == the worktree's new HEAD, candidate_sha in the
# envelope must equal that sha, and `git log` must show the adapter's own
# commit (message "<task>: <first 60 chars of summary>") on top of base_sha.
d="$(build_request editnocommit implement '#!/usr/bin/env bash
echo "engine edit, no commit" > edited.txt
echo "working..."
echo ""
echo "Implemented the feature end to end."')"
base_sha="$(git -C "$d/worktree" rev-parse HEAD)"
run_adapter "$d" || fail "edit-no-commit stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "edit-no-commit stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "edit-no-commit stub: status ok"
new_sha="$(git -C "$d/worktree" rev-parse HEAD)"
[ "$new_sha" != "$base_sha" ] || fail "edit-no-commit stub: adapter must create a new commit in the worktree"
assert_eq "[\"$new_sha\"]" "$(jq -c .commits "$d/out/envelope.json")" "edit-no-commit stub: commits array is exactly the adapter's new sha"
assert_eq "$new_sha" "$(jq -r .candidate_sha "$d/out/envelope.json")" "edit-no-commit stub: candidate_sha == adapter's new HEAD"
assert_eq "T001: Implemented the feature end to end." "$(git -C "$d/worktree" log -1 --format=%s)" "edit-no-commit stub: adapter's commit message is '<task>: <summary>'"

# --- 5b. implement: engine produces NO changes at all (no edit, no commit)
# -> the adapter must NOT emit ok with an empty commits[] -- an implement
# that changed nothing is a failure. ----------------------------------------
d="$(build_request nochanges implement '#!/usr/bin/env bash
echo "working..."
echo "Nothing to do here."')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "no-changes stub: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "no-changes stub: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "no-changes stub: status failed"
assert_eq "engine produced no changes" "$(jq -r .summary "$d/out/envelope.json")" "no-changes stub: summary explains why"

# --- 5c. codex-only idempotence: the engine itself ALSO commits (codex can,
# e.g. full-access) -> the adapter must accept the pre-existing commit
# instead of failing, and must NOT double-commit on top of it. --------------
d="$(build_request implcommit implement '#!/usr/bin/env bash
echo "did the work" > done.txt
git add done.txt
git -c user.email=test@orchid.local -c user.name="Orchid Test" commit -q -m "stub commit"
echo "Implemented and committed."')"
base_sha="$(git -C "$d/worktree" rev-parse HEAD)"
run_adapter "$d" || fail "implement+commit stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "implement+commit stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "implement+commit stub: status ok"
new_sha="$(git -C "$d/worktree" rev-parse HEAD)"
assert_eq "[\"$new_sha\"]" "$(jq -c .commits "$d/out/envelope.json")" "implement+commit stub: commits array contains the new sha"
assert_eq "$new_sha" "$(jq -r .candidate_sha "$d/out/envelope.json")" "implement+commit stub: candidate_sha == the engine's own commit"
assert_eq "Implemented and committed." "$(jq -r .summary "$d/out/envelope.json")" "implement+commit stub: summary unchanged when commits present"
ahead="$(git -C "$d/worktree" rev-list --count "${base_sha}..HEAD")"
assert_eq "1" "$ahead" "implement+commit stub: adapter did not add a second commit on top of the engine's own"

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
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "dryrun review: findings placeholder empty array"

# --- 8b. exact-match guard: last VERDICT line is the ECHOED instruction -----
# ("VERDICT: approve OR request-changes") — the reply never actually chose a
# verdict, just repeated the prompt's own reply-contract line. Must be
# MALFORMED, never approve (the substring "approve" is present but the line
# is not an exact verdict).
d="$(build_request echoedinstruction review '#!/usr/bin/env bash
echo "thinking it over..."
echo "VERDICT: approve OR request-changes"')"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "echoed-instruction stub: adapter should exit nonzero"
assert_eq "malformed" "$(jq -r .status "$d/out/envelope.json")" "echoed-instruction stub: status malformed (not approve)"

# --- 11. F2 regression: prompt delivered on STDIN (not argv), with `-` as the
# prompt arg and --skip-git-repo-check present. The real codex CLI's clap
# parser reads an argv prompt starting with "-"/"--" as a flag (dogfood F2a),
# and separately refuses an untrusted worktree without --skip-git-repo-check
# (F2b). Fixture has NO context.md, so the whole prompt is exactly the
# task.md body -- which (per templates/task.md) begins with the frontmatter
# "---" delimiter: the real repro shape, not a synthetic one. The stub
# codex reads stdin itself, writes what it received to a file so the test
# can inspect it, and asserts the required argv shape before doing so.
codex_stdin_stub='#!/usr/bin/env bash
set -euo pipefail
argv=" $* "
case "$argv" in
  *" --skip-git-repo-check "*) ;;
  *) echo "codex-stub: --skip-git-repo-check missing from argv: $*" >&2; exit 9 ;;
esac
last="${@: -1}"
[ "$last" = "-" ] || { echo "codex-stub: last arg is not the literal - (argv: $*)" >&2; exit 9; }
stdin_content="$(cat)"
[ -n "$stdin_content" ] || { echo "codex-stub: stdin was empty" >&2; exit 9; }
printf %s "$stdin_content" > ../out/stdin_capture.txt'

# Stub also edits a file (echoed via stdin capture path relative to cwd,
# i.e. inside the worktree) so the F3 adapter-commit logic has something to
# stage -- an implement stub producing no changes is a failure post-F3.
d="$(build_request stdinimpl implement "$codex_stdin_stub"$'\necho "stdin edit" > stdin_edit.txt\necho "Implemented via stdin."' nocontext)"
run_adapter "$d" || fail "stdin implement: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "stdin implement: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "stdin implement: status ok"
captured="$(cat "$d/out/stdin_capture.txt")"
assert_match "^---" "$captured" "stdin implement: prompt begins with the real --- frontmatter shape (leading-dash repro)"
assert_match "Do the thing." "$captured" "stdin implement: full task body present in stdin"

d="$(build_request stdinreview review "$codex_stdin_stub"$'\necho "VERDICT: approve"' nocontext)"
run_adapter "$d" || fail "stdin review: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "stdin review: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "stdin review: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "stdin review: verdict approve"
captured="$(cat "$d/out/stdin_capture.txt")"
[ -n "$captured" ] || fail "stdin review: prompt captured from stdin must be non-empty"

# --- 9. unsupported operation ------------------------------------------------
d="$(build_request badop research "")"
rm -rf "$d/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"

# --- 10. DRYRUN + unsupported operation: operation gate precedes DRYRUN, so
# this still fails (no dryrun short-circuit for unknown operations, mirroring
# agy/claude symmetry) --------------------------------------------------------
d="$(build_request dryimplbadop research "")"
rm -rf "$d/bin"
rc=0; ORCHID_DRYRUN=1 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "dryrun badop: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "dryrun badop: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "dryrun badop: status failed (operation gate precedes dryrun)"
