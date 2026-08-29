#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/common.sh"   # file_mtime (portable BSD/GNU stat mtime)
ADAPTER="$REPO_ROOT/plugins/engines/codex/run"

# v1-m3 final review (CRITICAL 1): the orchestrate branch's own instructions=
# string (what this adapter actually feeds the engine, not just PROTOCOL.md's
# prose) must mirror the no-external-mutation policy -- a live tick pushing
# a branch to origin was a real finding. Static grep against the source,
# same lint-style check test_install.sh runs against PROTOCOL.md itself.
grep -q 'git push' "$ADAPTER" || fail "$ADAPTER's orchestrate instructions never mirror the no-external-mutation policy (git push)"

# --- shared fixture builder -------------------------------------------------
# build_request <name> <operation> [stub-body] -> prints path to request.json
build_request() {
  local name="$1" op="$2" stub="$3" nocontext="${4:-}"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf -- '---\nschema: 1\nid: T001\ntitle: Do the thing\nacceptance_criteria: does the thing\nstop_condition: one pass only\n---\nDo the thing.\n' \
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

# --- 5a-i. v1-m4 F11 regression: reply's own LAST non-empty line is a bare
# markdown fence (the exact live-run repro: commit subject shipped as
# literal "T001: ```"). Sanitization must treat a bare fence line as an
# empty candidate and fall back to the clean line right before it, not
# ship the fence verbatim.
d="$(build_request fencelast implement '#!/usr/bin/env bash
echo "engine edit" > fencelast.txt
echo "Implemented the caching layer end to end."
echo "\`\`\`"')"
run_adapter "$d" || fail "fence-last-line stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "fence-last-line stub: envelope invalid"
assert_eq "T001: Implemented the caching layer end to end." "$(git -C "$d/worktree" log -1 --format=%s)" "fence-last-line stub: commit subject falls back to the clean line before the bare fence, not the fence itself"

# --- 5a-ii. v1-m4 F11 regression: reply's own last non-empty line is an
# unsanitized bullet with inline backticks (the exact live-run repro:
# commit subject shipped as literal "T002: - \`git diff --check\` passes.").
# Sanitization strips the leading list marker and the backticks, producing
# a sane subject instead of shipping the markup verbatim.
d="$(build_request bulletlast implement '#!/usr/bin/env bash
echo "engine edit" > bulletlast.txt
echo "- \`git diff --check\` passes."')"
run_adapter "$d" || fail "bullet-last-line stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "bullet-last-line stub: envelope invalid"
assert_eq "T001: git diff --check passes." "$(git -C "$d/worktree" log -1 --format=%s)" "bullet-last-line stub: commit subject strips the leading bullet marker and backticks"

# --- 5a-iii. v1-m4 F11 regression: the reply is fence-only start to finish
# -- nothing anywhere in it survives sanitization -- so the adapter falls
# back to the task's own title (already loaded from task.md, not a new
# input) rather than shipping an empty or garbage subject.
d="$(build_request fenceonly implement '#!/usr/bin/env bash
echo "engine edit" > fenceonly.txt
echo "\`\`\`"
echo "\`\`\`"')"
run_adapter "$d" || fail "fence-only stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "fence-only stub: envelope invalid"
assert_eq "T001: Do the thing" "$(git -C "$d/worktree" log -1 --format=%s)" "fence-only stub: commit subject falls back to the task title when nothing in the reply survives sanitization"

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
rm -rf "${d:?}/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun implement: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun implement: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun implement: status ok"
assert_eq "dryrun" "$(jq -r .summary "$d/out/envelope.json")" "dryrun implement: summary dryrun"

# --- 7. DRYRUN: review, no spawn --------------------------------------------
d="$(build_request dryreview review "")"
rm -rf "${d:?}/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun review: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun review: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun review: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "dryrun review: verdict approve"
assert_eq "true" "$(jq -r .scope_complete "$d/out/envelope.json")" "dryrun review: scope_complete true"
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "dryrun review: findings placeholder empty array"

# --- 7b. DRYRUN: orchestrate, no spawn --------------------------------------
d="$(build_request dryorch orchestrate "")"
rm -rf "${d:?}/bin"
ORCHID_DRYRUN=1 run_adapter "$d" || fail "dryrun orchestrate: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "dryrun orchestrate: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "dryrun orchestrate: status ok"
assert_eq "dryrun" "$(jq -r .summary "$d/out/envelope.json")" "dryrun orchestrate: summary dryrun"
assert_eq "[]" "$(jq -c .actions "$d/out/envelope.json")" "dryrun orchestrate: actions empty array"

# --- 7c. orchestrate stub prints one ORCHID-ACTION line -> actions=["..."] --
d="$(build_request orchone orchestrate '#!/usr/bin/env bash
cat > "'"$WORK"'/orchone.stdin"
echo "advancing the task"
echo "ORCHID-ACTION: orchid task advance T001 implementing --reason tick"
echo "tick complete"')"
run_adapter "$d" || fail "orchestrate one-action stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "orchestrate one-action stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "orchestrate one-action stub: status ok"
assert_eq '["orchid task advance T001 implementing --reason tick"]' "$(jq -c .actions "$d/out/envelope.json")" \
  "orchestrate one-action stub: actions captures the ORCHID-ACTION line"
assert_eq "tick complete" "$(jq -r .summary "$d/out/envelope.json")" "orchestrate one-action stub: summary from last non-empty line"
stdin_content="$(cat "$WORK/orchone.stdin")"
assert_match "ORCHID-ACTION: <command>" "$stdin_content" "orchestrate one-action stub: the fixed instruction block arrives on stdin"

# T009: the notify form these instructions hand the model DECLARES ITS ANSWER
# SET. runners/orchid-drive already does this for every boundary kind that has
# one (lib/drive.sh's drive_boundary_choices, pinned in tests/test_drive.sh),
# but a boundary the driver routes to a woken model and the model then judges
# to be a human's after all is paged from HERE, not from the driver. Left out
# of this block, exactly the pages a model escalates keep the shape r-001
# shipped twenty-seven of: `orchid answer <qid> <choice> --nonce <n>` with
# nothing saying what `<choice>` may be. Asserted on the prompt the engine
# actually received rather than on the adapter's source line, because a source
# line is only an instruction once it reaches the engine.
assert_match "notify --task <id> \\[--choice <value>\\]" "$stdin_content" \
  "orchestrate one-action stub: the notify form the instructions hand the model carries the declared-choice flag"
# THE OTHER EDGE, in the same block, because a set that is always demanded is
# its own defect: a boundary whose honest answer is a sentence must not be
# gated on a menu, so the instructions have to say when NOT to declare one.
assert_match "omit --choice entirely when the honest answer is prose" "$stdin_content" \
  "orchestrate one-action stub: ...and say plainly when to declare no set at all"

# --- 7d. orchestrate stub prints NO ORCHID-ACTION lines, exits 0 ->
# actions == [] and status is STILL ok (never a crash). Regression test for a
# real bug: under `set -euo pipefail`, `grep '^ORCHID-ACTION: '` on zero
# matches exits 1, and pipefail promoted that to the whole actions_json
# pipeline's status -- without the `|| true` guard, `set -e` aborted the
# adapter right there, before any envelope was ever written, and
# runners/orchid-tick misread this healthy, no-op tick as a crashed engine
# (ledger_mark failed instead of ok).
d="$(build_request orchnone orchestrate '#!/usr/bin/env bash
echo "nothing to do this tick"')"
run_adapter "$d" || fail "orchestrate no-action stub: adapter should exit 0 (regression: must not crash on zero ORCHID-ACTION lines)"
envelope_validate "$d/out/envelope.json" || fail "orchestrate no-action stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "orchestrate no-action stub: status ok"
assert_eq "[]" "$(jq -c .actions "$d/out/envelope.json")" "orchestrate no-action stub: actions is empty array"

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
rm -rf "${d:?}/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"

# --- 10. DRYRUN + unsupported operation: operation gate precedes DRYRUN, so
# this still fails (no dryrun short-circuit for unknown operations, mirroring
# agy/claude symmetry) --------------------------------------------------------
d="$(build_request dryimplbadop research "")"
rm -rf "${d:?}/bin"
rc=0; ORCHID_DRYRUN=1 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "dryrun badop: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "dryrun badop: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "dryrun badop: status failed (operation gate precedes dryrun)"

# --- 12. codex-review engine identity: `codex-review/run` stamps its own
# engine id (orchid/codex-review), not the shared codex/run's default id.
# codex-review wraps the shared codex/run via ORCHID_ENGINE_ID (v1m1: engine
# id becomes real, not just an envelope-hardcoded string). ------------------
CODEX_REVIEW_ADAPTER="$REPO_ROOT/plugins/engines/codex-review/run"
run_codex_review() { PATH="$1/bin:$PATH" "$CODEX_REVIEW_ADAPTER" "$1/request.json"; }

d="$(build_request reviewengineid review '#!/usr/bin/env bash
echo "looks fine"
echo "VERDICT: approve"')"
run_codex_review "$d" || fail "codex-review approve: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "codex-review approve: envelope invalid"
assert_eq "orchid/codex-review" "$(jq -r .engine "$d/out/envelope.json")" "codex-review run stamps its own engine id"

# --- 13. codex-review operation gating: implement is NOT in its allowed ops
# (review,critique only, matching its manifest's no-workspace_write
# capability set) -- must fail closed with status failed, and the underlying
# codex stub must never even run. -------------------------------------------
d="$(build_request reviewnoimplement implement '#!/usr/bin/env bash
echo "should never run" > should_not_exist.txt
echo "Implemented."')"
rc=0; run_codex_review "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "codex-review implement: adapter should exit nonzero (operation not permitted)"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "codex-review implement: status failed"
assert_match "not permitted" "$(jq -r .summary "$d/out/envelope.json")" "codex-review implement: summary explains operation not permitted"
[ ! -f "$d/worktree/should_not_exist.txt" ] || fail "codex-review implement: engine must never have been invoked (file should not exist)"

# --- 14. codex/run itself (no ORCHID_ENGINE_ID / ORCHID_ALLOWED_OPS override)
# stays exactly as before: still stamps orchid/codex and still permits
# implement -- the shared adapter's back-compat default is unchanged. -------
d="$(build_request plaincodeximplement implement '#!/usr/bin/env bash
echo "did the work" > done2.txt
git add done2.txt
git -c user.email=test@orchid.local -c user.name="Orchid Test" commit -q -m "stub commit"
echo "Implemented via plain codex."')"
run_adapter "$d" || fail "plain codex implement: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "plain codex implement: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "plain codex implement: status ok"
assert_eq "orchid/codex" "$(jq -r .engine "$d/out/envelope.json")" "plain codex/run still stamps orchid/codex"

# --- 15. v1-m3: codex review REASON line captured into the ok-envelope's
# summary (200-char cap), same idiom as plugins/engines/agy/run -- but a
# verdict-only reply stays valid (summary optional; lib/envelope.sh's
# review/critique union never requires it). ---------------------------------
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

d="$(build_request noreason review '#!/usr/bin/env bash
echo "VERDICT: approve"')"
run_adapter "$d" || fail "noreason stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "noreason stub: envelope invalid (verdict-only reply must still be valid)"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "noreason stub: status ok (verdict-only reply stays valid)"
assert_eq "false" "$(jq -r 'has("summary")' "$d/out/envelope.json")" "noreason stub: summary absent when no REASON line"

# --- 16. v1-m3 log streaming: the live-run finding was that a job log stayed
# ZERO BYTES for the whole run (adapter captured CLI output purely into a
# bash variable, with nothing written to its own stdout/stderr -- which is
# what a launcher/tick redirect actually captures into the job log). The fix
# tees the CLI's stdout to the adapter's own stderr as it arrives. Simulate
# the launcher's redirect here (`>> log 2>&1`) around a stub codex, and
# assert the log has grown partway through the run -- not just after the
# adapter exits. ------------------------------------------------------------
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
d="$(build_request streaming implement '#!/usr/bin/env bash
echo "line one"
'"$(stub_hold_until "$WORK/streaming.release")"'
echo "line two"
echo "did the work" > streamed.txt
git add streamed.txt
git -c user.email=test@orchid.local -c user.name="Orchid Test" commit -q -m "stub commit"
echo "Implemented with streaming."')"
joblog="$d/out/job.log"; : > "$joblog"
(run_adapter "$d" >>"$joblog" 2>&1) &
adapter_pid=$!
midrun_grew=no
await_log_growth "$joblog" "$adapter_pid" && midrun_grew=yes
midrun_size="$(wc -c <"$joblog" | tr -d ' ')"
release_stub "$WORK/streaming.release"   # only now may the stub run to completion
wait "$adapter_pid" || fail "streaming stub: adapter should exit 0"
final_size="$(wc -c <"$joblog" | tr -d ' ')"
assert_eq "yes" "$midrun_grew" "streaming stub: bounded growth wait must observe live stream bytes before adapter exit -- this is the stall-detector's liveness signal"
[ "$final_size" -ge "$midrun_size" ] || fail "streaming stub: job log must not shrink after the adapter exits"
assert_match "line one" "$(cat "$joblog")" "streaming stub: the CLI's early output reached the job log"
envelope_validate "$d/out/envelope.json" || fail "streaming stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "streaming stub: status ok"

# --- 17. v1-m3 ORCHID-ACTION belt-and-braces fallback: the orchestrate stub
# below prints its ORCHID-ACTION marker line ONLY to its own stderr (never
# stdout) -- simulating a CLI that interleaves its streams so the marker
# never lands in the adapter's primary `$stdout` capture. The adapter must
# still fall back to grepping the stderr capture (err_file) it already has
# on hand, so the marker still reaches actions[] instead of silently
# vanishing. -----------------------------------------------------------------
d="$(build_request orchstderr orchestrate '#!/usr/bin/env bash
echo "ORCHID-ACTION: orchid task advance T001 implementing --reason tick" >&2
echo "tick complete"')"
run_adapter "$d" || fail "orchestrate stderr-marker stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "orchestrate stderr-marker stub: envelope invalid"
assert_eq '["orchid task advance T001 implementing --reason tick"]' "$(jq -c .actions "$d/out/envelope.json")" \
  "orchestrate stderr-marker stub: fallback captures an ORCHID-ACTION line that only reached stderr"

# --- 18. v1-m3 round 2: adapter heartbeat. probe-stream-buffering.sh's real
# run found codex BUFFERED -- tee alone (test 16 above) doesn't help a CLI
# that produces literally NOTHING until it exits (worse than that test's
# echo/sleep/echo stub, which at least gives tee something to relay). The
# stub below sleeps the WHOLE time and writes not one byte until the very
# end; the ONLY thing that can make the job log grow mid-run here is
# lib/heartbeat.sh's `[hb ...]` liveness line, written to the adapter's own
# stderr (never the stub's stdout) every ORCHID_HB_INTERVAL_S seconds. Set
# to 1 here as a TEST-ONLY override (real default is 30s, see
# lib/heartbeat.sh) so the fixture doesn't need to wait out a real 30s
# interval for a heartbeat line to land. Also pins that heartbeat lines
# never leak into actions[]/summary parsing (they're on stderr, structurally
# separate from the stub's real stdout -- $stdout is filled purely from the
# FIFO-relayed stdout content -- but pinned here rather than left implicit).
#
# T019 (lesson L020): the heartbeat half of the same family as case 16 above.
# It used to sleep 1.3s and count `[hb ` lines at that instant, which makes a
# deadline out of a liveness property; same fix, same shared helpers.
d="$(build_request heartbeat orchestrate '#!/usr/bin/env bash
'"$(stub_hold_until "$WORK/heartbeat.release")"'
echo "ORCHID-ACTION: orchid task advance T001 implementing --reason tick"
echo "tick complete"')"
joblog="$d/out/job.log"; : > "$joblog"
initial_mtime="$(file_mtime "$joblog")"
( ORCHID_HB_INTERVAL_S=1 run_adapter "$d" >>"$joblog" 2>&1 ) &
adapter_pid=$!
midrun_hb=no
await_log_heartbeat "$joblog" "$adapter_pid" && midrun_hb=yes
midrun_hb_count="$(grep -c '^\[hb ' "$joblog" 2>/dev/null || true)"; midrun_hb_count="${midrun_hb_count:-0}"
midrun_mtime="$(file_mtime "$joblog")"
release_stub "$WORK/heartbeat.release"   # only now may the stub run to completion
wait "$adapter_pid" || fail "heartbeat stub: adapter should exit 0"
assert_eq "yes" "$midrun_hb" "heartbeat stub: a [hb line must appear WHILE the adapter is still running -- waited for, not sampled at one instant"
[ "$midrun_hb_count" -ge 1 ] || fail "heartbeat stub: bounded heartbeat wait must leave at least one persisted [hb line before adapter exit -- this is the liveness signal the stall detector depends on"
[ "$midrun_mtime" -ge "$initial_mtime" ] || fail "heartbeat stub: job log mtime must have advanced mid-run (initial=$initial_mtime midrun=$midrun_mtime)"
envelope_validate "$d/out/envelope.json" || fail "heartbeat stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "heartbeat stub: status ok"
assert_eq '["orchid task advance T001 implementing --reason tick"]' "$(jq -c .actions "$d/out/envelope.json")" \
  "heartbeat stub: actions[] captures only the real marker, unaffected by interleaved heartbeat lines"
summary_val="$(jq -r .summary "$d/out/envelope.json")"
case "$summary_val" in *'[hb '*) fail "heartbeat stub: a heartbeat line leaked into the envelope summary" ;; esac
actions_val="$(jq -c .actions "$d/out/envelope.json")"
case "$actions_val" in *'[hb '*) fail "heartbeat stub: a heartbeat line leaked into the envelope actions[]" ;; esac

# --- 19. v1-m3: plan-scoped critique pack (task id `plan`, no task.md/
# diff.patch at all -- lib/pack.sh's _pack_build_plan builds requirements.md
# + roadmap.md + tasks.md instead). The prompt must be built from those
# files, not the diff-based review prompt, and a critique reply's `FINDING:
# <severity>: <title>` lines must parse into findings[] (review's contract
# stays verdict-only, unaffected -- see test 1 above).
build_plan_request() {  # name stub -> prints path to request.json's dir
  local name="$1" stub="$2"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf '# Requirements\nShip the widget end to end.\n' > "$d/pack/requirements.md"
  printf -- '---\nrun_status: planning\n---\n# Roadmap\n- T001: build the widget\n' > "$d/pack/roadmap.md"
  printf -- '---\nid: T001\n---\nBuild the widget.\n' > "$d/pack/tasks.md"
  printf '{"budget":65536,"total_bytes":10,"items":[{"name":"requirements.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
    > "$d/pack/pack.json"
  [ -n "$stub" ] && { printf '%s\n' "$stub" > "$d/bin/codex"; chmod +x "$d/bin/codex"; }
  (cd "$d/worktree" && git init -q . \
    && git -c user.email=test@orchid.local -c user.name="Orchid Test" \
         commit -q --allow-empty -m root) >/dev/null 2>&1
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
echo "FINDING: medium: missing rollback plan for T002"
echo "FINDING: low: acceptance criteria too vague on T003"')"
run_adapter "$d" || fail "plan critique stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "plan critique stub: envelope invalid"
assert_eq "request-changes" "$(jq -r .verdict "$d/out/envelope.json")" "plan critique stub: verdict parsed"
assert_eq "2" "$(jq '.findings | length' "$d/out/envelope.json")" "plan critique stub: FINDING lines parsed into findings[]"
assert_eq "medium" "$(jq -r '.findings[0].severity' "$d/out/envelope.json")" "plan critique stub: first finding severity"
assert_eq "missing rollback plan for T002" "$(jq -r '.findings[0].title' "$d/out/envelope.json")" "plan critique stub: first finding title"
assert_eq "low" "$(jq -r '.findings[1].severity' "$d/out/envelope.json")" "plan critique stub: second finding severity"

# The prompt itself must be built from the plan pack (requirements/roadmap/
# tasks), never the diff-based review prompt -- captured via the same
# stdin-capture stub convention as test 11 above.
d="$(build_plan_request planprompt "$codex_stdin_stub"$'\necho "VERDICT: approve"')"
run_adapter "$d" || fail "plan prompt stub: adapter should exit 0"
captured="$(cat "$d/out/stdin_capture.txt")"
assert_match "Requirements:" "$captured" "plan prompt: requirements section present"
assert_match "Ship the widget end to end." "$captured" "plan prompt: requirements body present"
assert_match "Draft roadmap:" "$captured" "plan prompt: roadmap section present"
assert_match "Build the widget." "$captured" "plan prompt: tasks.md body present"
case "$captured" in *"Diff:"*) fail "plan prompt: must never contain the diff-based review prompt shape" ;; esac
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "plan prompt stub: approve-only reply still yields empty findings[]"
