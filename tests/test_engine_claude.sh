#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/common.sh"   # file_mtime (portable BSD/GNU stat mtime)
ADAPTER="$REPO_ROOT/plugins/engines/claude/run"

# v1-m3 final review (CRITICAL 1): the orchestrate branch's own instructions=
# string (what this adapter actually feeds the engine, not just PROTOCOL.md's
# prose) must mirror the no-external-mutation policy -- a live tick pushing
# a branch to origin was a real finding. Static grep against the source,
# same lint-style check test_install.sh runs against PROTOCOL.md itself.
grep -q 'git push' "$ADAPTER" || fail "$ADAPTER's orchestrate instructions never mirror the no-external-mutation policy (git push)"

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
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "approve stub: a review reply with no FINDING lines still yields an empty findings[]"
# Plain-substring shape (no ERE metacharacters — assert_match is `grep -E`,
# where the literal `<low|medium|high>` token would read as alternation and
# match almost anything).
assert_match "One line per issue found, exactly: FINDING:" "$stdin_content" \
  "approve stub: the review prompt asks for the same FINDING line shape the critique prompt does"
# This fixture's task.md carries no blocking_severity, so the prompt must
# state the SAME fallback lib/drive.sh's own gate applies (medium).
assert_match "This task's blocking_severity is medium" "$stdin_content" \
  "approve stub: with the key absent the prompt states the gate's own default"
# Squeezed first: the text this guards against was WRAPPED in the prompt
# ("(medium by\ndefault)"), so a line-oriented grep for it could never have
# fired.
grep -qF "medium by default" <<<"$(tr '\n' ' ' <<<"$stdin_content" | tr -s '[:space:]' ' ')" \
  && fail "approve stub: the prompt must not hardcode a default threshold — templates/task.md and task-test.md ship blocking_severity: high"

# --- 1b. v1-m4 T006: a REVIEW reply's `FINDING:` lines must reach findings[]
# exactly as a critique's do. Before this, review asked for a VERDICT line
# only and every review envelope carried `findings: []` verbatim -- the
# reviewer's reasoning survived only in the reaped engine log (a real T003
# round lost three reported findings that way). The VERDICT contract itself
# is unchanged: this stub still request-changes through the same line shape.
d="$(build_request reviewfindings review '#!/usr/bin/env bash
echo "reviewed the diff"
echo "FINDING: high: doctor claims inbound ok from an outbound-only fact"
echo "FINDING: low: comment says v1-m3 but the change is v1-m4"
echo "FINDING: bogus: severity token is not one of the three"
echo "FINDING: <low|medium|high>: <title>"
echo "FINDING: medium: "
echo "VERDICT: request-changes"')"
run_adapter "$d" || fail "review findings stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "review findings stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "review findings stub: status ok"
assert_eq "request-changes" "$(jq -r .verdict "$d/out/envelope.json")" "review findings stub: VERDICT contract unchanged"
assert_eq "2" "$(jq '.findings | length' "$d/out/envelope.json")" \
  "review findings stub: FINDING lines parsed into findings[] (unknown severity, echoed instruction line and empty title all dropped)"
assert_eq "high" "$(jq -r '.findings[0].severity' "$d/out/envelope.json")" "review findings stub: first finding severity"
assert_eq "doctor claims inbound ok from an outbound-only fact" \
  "$(jq -r '.findings[0].title' "$d/out/envelope.json")" "review findings stub: first finding title"
assert_eq "low" "$(jq -r '.findings[1].severity' "$d/out/envelope.json")" "review findings stub: second finding severity"

# --- 1c. a review that reports NO findings is still a valid, ok review with a
# literally empty findings[] -- the driver's blocking_severity gate reads that
# as "nothing blocking", exactly as it always has.
d="$(build_request reviewnofindings review '#!/usr/bin/env bash
echo "nothing to report"
echo "VERDICT: approve"')"
run_adapter "$d" || fail "review no-findings stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "review no-findings stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "review no-findings stub: status ok"
assert_eq "approve" "$(jq -r .verdict "$d/out/envelope.json")" "review no-findings stub: verdict approve"
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "review no-findings stub: findings[] is the empty array"

# --- 1d. v1-m4 T006: the prompt must state THIS task's blocking_severity, not
# a hardcoded default. The shipped archetypes genuinely disagree
# (templates/task.md and templates/task-test.md ship `high`; task-migrate and
# task-refactor ship `medium`), so a prompt asserting "medium by default"
# tells a reviewer on a test/default task the wrong threshold for the very
# gate this milestone made live -- inviting a `medium` finding believing it
# will halt the run when lib/drive.sh will let it through.
d="$(build_request reviewbsevhigh review '#!/usr/bin/env bash
cat > "'"$WORK"'/bsevhigh.stdin"
echo "VERDICT: approve"')"
printf -- '---\nschema: 1\nid: T001\nacceptance_criteria: does the thing\nstop_condition: one pass only\nblocking_severity: high\n---\nDo the thing.\n' \
  > "$d/pack/task.md"
run_adapter "$d" || fail "blocking_severity=high stub: adapter should exit 0"
bsev_stdin="$(cat "$WORK/bsevhigh.stdin")"
assert_match "This task's blocking_severity is high" "$bsev_stdin" \
  "blocking_severity=high stub: the prompt reports the task's actual threshold"
assert_match "a finding at or above high" "$bsev_stdin" \
  "blocking_severity=high stub: the consequence sentence uses the same threshold, not a default"
grep -q "blocking_severity is medium" <<<"$bsev_stdin" \
  && fail "blocking_severity=high stub: the prompt must not state medium for a high-threshold task"
# The severity menu must stay true under either threshold: `medium` may or may
# not block depending on the task, so it must not be described as one that
# always does.
grep -q "medium: should block this candidate" <<<"$bsev_stdin" \
  && fail "blocking_severity=high stub: the severity menu must not claim medium always blocks"

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
echo "engine edit" > implsuccess_edit.txt
echo "working..."
echo ""
echo "Implemented the feature end to end."')"
run_adapter "$d" || fail "implement stub: adapter should exit 0"
envelope_validate "$d/out/envelope.json" || fail "implement stub: envelope invalid"
assert_eq "ok" "$(jq -r .status "$d/out/envelope.json")" "implement stub: status ok"
assert_eq "Implemented the feature end to end." "$(jq -r .summary "$d/out/envelope.json")" "implement stub: summary from last non-empty line"
new_sha="$(git -C "$d/worktree" rev-parse HEAD)"
assert_eq "[\"$new_sha\"]" "$(jq -c .commits "$d/out/envelope.json")" "implement stub: commits array has the adapter's own commit (v0b2 F3: engine edits, adapter commits)"
argc="$(cat "$WORK/implsuccess.argc")"
assert_eq "3" "$argc" "implement stub: acceptEdits permission mode, exactly three argv (no prompt argv)"
assert_eq "-p" "$(cat "$WORK/implsuccess.argv.1")" "implement stub: -p is first argv"
assert_eq "--permission-mode" "$(cat "$WORK/implsuccess.argv.2")" "implement stub: --permission-mode is second argv"
assert_eq "acceptEdits" "$(cat "$WORK/implsuccess.argv.3")" "implement stub: acceptEdits is third argv"
stdin_content="$(cat "$WORK/implsuccess.stdin")"
assert_match "Do the thing." "$stdin_content" "implement stub: full task body arrives on stdin, not argv"

# --- 5b. v0b2 F3: engine EDITS a file but does NOT commit -> the adapter
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

# --- 5c. implement: engine produces NO changes at all (no edit, no commit)
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

# --- 6. DRYRUN: implement, no spawn (no claude on PATH at all) -------------
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
# argv shape asserted too. F8 established that the Bash tool must be
# allowlisted at all (acceptEdits alone authorizes edits, not commands).
# v1.1 Track 1 narrows WHAT it may run: the allowlist entry is scoped to the
# brokered command surface (runners/orchid-orchestrator-command) rather than
# the whole shell, and the instruction text must name that broker by absolute
# path (bare `orchid` may not be on PATH in a dev checkout, and the broker is
# the only executable this branch is permitted to invoke).
d="$(build_request orchone orchestrate '#!/usr/bin/env bash
printf "%s" "$#" > "'"$WORK"'/orchone.argc"
i=0
for a in "$@"; do i=$((i+1)); printf "%s" "$a" > "'"$WORK"'/orchone.argv.$i"; done
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
argc="$(cat "$WORK/orchone.argc")"
assert_eq "5" "$argc" "orchestrate stub: acceptEdits + a scoped allowedTools entry, exactly five argv (no prompt argv)"
assert_eq "-p" "$(cat "$WORK/orchone.argv.1")" "orchestrate stub: -p is first argv"
assert_eq "--permission-mode" "$(cat "$WORK/orchone.argv.2")" "orchestrate stub: --permission-mode is second argv"
assert_eq "acceptEdits" "$(cat "$WORK/orchone.argv.3")" "orchestrate stub: acceptEdits is third argv"
assert_eq "--allowedTools" "$(cat "$WORK/orchone.argv.4")" "orchestrate stub: --allowedTools is fourth argv (F8: orchestrator's whole job is running commands)"
assert_match '^Bash\(/.*/runners/orchid-orchestrator-command:\*\)$' "$(cat "$WORK/orchone.argv.5")" \
  "orchestrate stub: the allowlist entry is scoped to the brokered command surface by absolute path, never a bare Bash grant"
assert_match "runners/orchid-orchestrator-command" "$stdin_content" \
  "orchestrate one-action stub: instructions name the absolute brokered-command path"

# T009: ...and the notify form they hand the model DECLARES ITS ANSWER SET.
# runners/orchid-drive already does this for every boundary kind that has one
# (lib/drive.sh's drive_boundary_choices, pinned in tests/test_drive.sh), but
# a boundary the driver routes to a woken model and the model then judges to
# be a human's after all is paged from HERE, not from the driver. Left out of
# this block, exactly the pages a model escalates keep the shape r-001 shipped
# twenty-seven of: `orchid answer <qid> <choice> --nonce <n>` with nothing
# saying what `<choice>` may be. Asserted on the prompt the engine actually
# received rather than on the adapter's source line, because a source line is
# only an instruction once it reaches the engine.
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
rm -rf "${d:?}/bin"
rc=0; run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "badop: adapter should exit nonzero"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "badop: status failed"

# --- 9. DRYRUN + unsupported operation: operation gate precedes DRYRUN, so
# this still fails (no dryrun short-circuit for unknown operations) --------
d="$(build_request dryimplbadop research "")"
rm -rf "${d:?}/bin"
rc=0; ORCHID_DRYRUN=1 run_adapter "$d" || rc=$?
[ "$rc" -ne 0 ] || fail "dryrun badop: adapter should exit nonzero"
envelope_validate "$d/out/envelope.json" || fail "dryrun badop: envelope invalid"
assert_eq "failed" "$(jq -r .status "$d/out/envelope.json")" "dryrun badop: status failed (operation gate precedes dryrun)"

# --- 10. v1-m3 log streaming: the live-run finding was that a job log stayed
# ZERO BYTES for the whole run (adapter captured CLI output purely into a
# bash variable, with nothing written to its own stdout/stderr -- which is
# what a launcher/tick redirect actually captures into the job log). The fix
# tees the CLI's stdout to the adapter's own stderr as it arrives. Simulate
# the launcher's redirect here (`>> log 2>&1`) around a stub claude, and
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
echo "engine edit" > streamed.txt
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

# --- 11. v1-m3 ORCHID-ACTION belt-and-braces fallback: the orchestrate stub
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

# --- 12. v1-m3 round 2: adapter heartbeat. probe-stream-buffering.sh's real
# run found claude BUFFERED too -- tee alone (the streaming test above)
# doesn't help a CLI that produces literally NOTHING until it exits (worse
# than that test's echo/sleep/echo stub, which at least gives tee something
# to relay). The stub below sleeps the WHOLE time and writes not one byte
# until the very end; the ONLY thing that can make the job log grow mid-run
# here is lib/heartbeat.sh's `[hb ...]` liveness line, written to the
# adapter's own stderr (never the stub's stdout) every ORCHID_HB_INTERVAL_S
# seconds. Set to 1 here as a TEST-ONLY override (real default is 30s, see
# lib/heartbeat.sh) so the fixture doesn't need to wait out a real 30s
# interval for a heartbeat line to land. Also pins that heartbeat lines
# never leak into actions[]/summary parsing (they're on stderr, structurally
# separate from the stub's real stdout -- $stdout is filled purely from the
# FIFO-relayed stdout content -- but pinned here rather than left implicit).
#
# T019 (lesson L020): the heartbeat half of the same family as case 10 above.
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
# <severity>: <title>` lines must parse into findings[] (unchanged by T006's
# extension of the same line shape to `review` -- see tests 1b/1c above).
build_plan_request() {  # name stub -> prints path to request.json's dir
  local name="$1" stub="$2"
  local d="$WORK/$name"
  mkdir -p "$d/pack" "$d/worktree" "$d/out" "$d/bin"
  printf '# Requirements\nShip the widget end to end.\n' > "$d/pack/requirements.md"
  printf -- '---\nrun_status: planning\n---\n# Roadmap\n- T001: build the widget\n' > "$d/pack/roadmap.md"
  printf -- '---\nid: T001\n---\nBuild the widget.\n' > "$d/pack/tasks.md"
  printf '{"budget":65536,"total_bytes":10,"items":[{"name":"requirements.md","bytes":5,"truncated":false}],"omitted":[]}\n' \
    > "$d/pack/pack.json"
  [ -n "$stub" ] && { printf '%s\n' "$stub" > "$d/bin/claude"; chmod +x "$d/bin/claude"; }
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

# Prompt content sanity: the plan pack's requirements/roadmap/tasks reach the
# CLI, and the diff-based review prompt shape never does.
d="$(build_plan_request planprompt '#!/usr/bin/env bash
content="$(cat)"
printf %s "$content" > ../out/stdin_capture.txt
echo "VERDICT: approve"')"
run_adapter "$d" || fail "plan prompt stub: adapter should exit 0"
captured="$(cat "$d/out/stdin_capture.txt")"
assert_match "Requirements:" "$captured" "plan prompt: requirements section present"
assert_match "Ship the widget end to end." "$captured" "plan prompt: requirements body present"
assert_match "Draft roadmap:" "$captured" "plan prompt: roadmap section present"
assert_match "Build the widget." "$captured" "plan prompt: tasks.md body present"
case "$captured" in *"Diff:"*) fail "plan prompt: must never contain the diff-based review prompt shape" ;; esac
assert_eq "[]" "$(jq -c .findings "$d/out/envelope.json")" "plan prompt stub: approve-only reply still yields empty findings[]"
