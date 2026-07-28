#!/usr/bin/env bash
# End-to-end proof: drives PROTOCOL.md's walk EXACTLY via `orchid` verbs
# against a REAL fixture repo — init, run start, requirements import,
# plan-phase task authoring, plan apply, the frontmatter-worktree dispatch,
# a real stub implementer that commits a file in its OWN worktree, reconcile
# + gc, testing/verify, a real stub reviewer that approves, arbitrating,
# merging, done, then the run-level accepting/accept close. No verb here is
# mocked — only the two engines (implementer, reviewer) are stubs, exactly
# as PROTOCOL.md's own preamble describes a front-end doing.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

# Runs "$@", fails the suite (via helpers.sh's fail()) with the captured
# output if it exits nonzero — a composition failure anywhere in the walk
# must be visible, not silently swallowed by the lack of `set -e` here.
run_ok() {
  local desc="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "$desc (exit $rc): $out"
  printf '%s\n' "$out"
}

# Polls `orchid jobs reconcile` until it reports the given task `ok` (the
# stub engines finish almost instantly, but never assume — this is a real
# background process, reconciled asynchronously, same as a live engine
# would be). Also satisfies THE TICK's reconcile-first-then-gc ordering.
reconcile_until_ok() {
  local task="$1" tries=0 out=""
  while [ "$tries" -lt 50 ]; do
    out="$("$ORCHID_BIN" jobs reconcile)"
    if printf '%s\n' "$out" | grep -Eq "^${task}[[:space:]]ok"; then
      "$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null   # THE TICK step 2, reconcile-first ordering
      printf '%s\n' "$out"
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  fail "timed out waiting for $task to reconcile ok (last reconcile output: $out)"
}

cd "$WORK"; git init -q .

# ---------------------------------------------------------------------------
# init: fixture config committed first (init refuses a dirty tree).
# ---------------------------------------------------------------------------
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\n' > orchid.config
git add -A && git commit -q -m "fixture: config"

run_ok "orchid init" "$ORCHID_BIN" init >/dev/null

# init leaves the operator back on the pre-init branch; the run state only
# lives on the integration branch it just committed to (mirrors
# tests/test_task.sh) — check that out once, then never move HEAD again
# (worktrees only, from here on).
integ=orchid/integration
git checkout -q "$integ"

# ---------------------------------------------------------------------------
# Real stub engines under ORCHID_ENGINES_DIR — implementer does REAL work
# (commits a file in the request's worktree), reviewer approves.
# ---------------------------------------------------------------------------
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/stubimpl" "$WORK/eng/stubreview"

# v1-m2: `orchid-launch` -> `jobs prepare` now resolves via
# resolve_role_available, gated on role_eligibility_reason -- each stub must
# declare the capabilities its role requires (roles/implementer.role,
# roles/reviewer.role) or the launches below would now (correctly) refuse.
printf 'manifest_version=1\nid=test/stubimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubimpl/plugin.conf"
printf 'manifest_version=1\nid=test/stubreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubreview/plugin.conf"

cat > "$WORK/eng/stubimpl/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
worktree="$(jq -r .worktree "$req")"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
[ "$op" = implement ] || exit 1
cd "$worktree"
echo "stub implementation" > stub_feature.txt
git add stub_feature.txt
git -c user.email=stub-implementer@example.com -c user.name="stub implementer" \
  commit -q -m "stub: implement $task"
sha="$(git rev-parse HEAD)"
jq -n --arg jid "$jid" --arg task "$task" --arg sha "$sha" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"stub implemented", commits:[$sha]}' > "$out"
EOF
chmod +x "$WORK/eng/stubimpl/run"

cat > "$WORK/eng/stubreview/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
[ "$op" = review ] || exit 1
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"stub review: approved"}' > "$out"
EOF
chmod +x "$WORK/eng/stubreview/run"

# ---------------------------------------------------------------------------
# run start: mints the epoch this whole walk operates under.
# ---------------------------------------------------------------------------
export ORCHID_EPOCH="$(run_ok "orchid run start" "$ORCHID_BIN" run start | sed 's/epoch: //')"
[ -n "$ORCHID_EPOCH" ] || fail "epoch minted by run start"

# ---------------------------------------------------------------------------
# PLANNING: requirements import, task authoring, plan apply.
# ---------------------------------------------------------------------------
cat > "$WORK/requirements-v1.md" <<'EOF'
# Requirements
- REQ-1: stub_feature.txt lands on the integration branch after the task merges.
EOF
run_ok "requirements import" "$ORCHID_BIN" requirements import "$WORK/requirements-v1.md" >/dev/null

run_ok "task create T001" "$ORCHID_BIN" task create T001 "stub feature" >/dev/null
run_ok "task set acceptance_criteria" "$ORCHID_BIN" task set T001 acceptance_criteria \
  "stub_feature.txt exists on the integration branch once T001 is done" >/dev/null
run_ok "task set verification_commands" "$ORCHID_BIN" task set T001 verification_commands \
  "test -f stub_feature.txt" >/dev/null

run_ok "plan apply" "$ORCHID_BIN" plan apply --reason "initial plan for T001" >/dev/null

assert_match "running" "$(fm_get "$WORK/.orchid/roadmap.md" run_status)" "plan apply moved run_status to running"

# ---------------------------------------------------------------------------
# pending -> implementing: the frontmatter worktree, created via the exact
# `git worktree add <path> -b <branch> <integ HEAD>` PROTOCOL.md names —
# never a plain checkout, never touching the shared checkout's HEAD.
# ---------------------------------------------------------------------------
integ_head="$(git rev-parse "$integ")"
branch="$(fm_get "$WORK/.orchid/tasks/T001.md" branch)"
assert_eq "task/T001" "$branch" "template's default branch field"
wt="$WORK/wt-T001"
git worktree add -q "$wt" -b "$branch" "$integ_head" || fail "git worktree add for T001"

run_ok "task set worktree" "$ORCHID_BIN" task set T001 worktree "$wt" >/dev/null
run_ok "task set base_sha" "$ORCHID_BIN" task set T001 base_sha "$integ_head" >/dev/null
run_ok "advance implementing" "$ORCHID_BIN" task advance T001 implementing \
  --reason "dispatching: deps satisfied" >/dev/null

started_at="$(fm_get "$WORK/.orchid/tasks/T001.md" started_at)"
assert_match "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$started_at" \
  "advance ... implementing stamps started_at"

launch_out="$(run_ok "orchid-launch implementer" "$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$launch_out" "implementer job launched"

# ---------------------------------------------------------------------------
# implementing -> testing: reconcile-first, gc, then read the candidate off
# the WORKTREE's HEAD (never off the manifest/envelope) — exactly the verb
# PROTOCOL.md names for this step.
# ---------------------------------------------------------------------------
reconcile_out="$(reconcile_until_ok T001)"
assert_match "^T001[[:space:]]ok" "$reconcile_out" "implementer envelope reconciled ok"

cand1="$(git -C "$wt" rev-parse HEAD)"
[ "$cand1" != "$integ_head" ] || fail "worktree HEAD must have moved past the base after the stub committed"
run_ok "task set candidate_sha" "$ORCHID_BIN" task set T001 candidate_sha "$cand1" >/dev/null
run_ok "advance testing" "$ORCHID_BIN" task advance T001 testing \
  --reason "implementer envelope ok" >/dev/null

# ---------------------------------------------------------------------------
# testing -> reviewing: orchid verify runs synchronously in the worktree.
# ---------------------------------------------------------------------------
rc=0; verify_out="$("$ORCHID_BIN" verify T001)" || rc=$?
assert_eq 0 "$rc" "orchid verify PASSes against the stub's real commit"
assert_match "PASS" "$verify_out" "verify reports PASS"

run_ok "advance reviewing" "$ORCHID_BIN" task advance T001 reviewing \
  --reason "verify passed" >/dev/null

# ---------------------------------------------------------------------------
# reviewing -> arbitrating: single-reviewer policy (role.reviewer resolves
# to a DIFFERENT engine than role.implementer — an independent reviewer,
# no degraded-independence journal note needed), then reconcile.
# ---------------------------------------------------------------------------
review_launch_out="$(run_ok "orchid-launch reviewer" "$REPO_ROOT/runners/orchid-launch" T001 reviewer review)"
assert_match "launched j-" "$review_launch_out" "reviewer job launched"

review_reconcile_out="$(reconcile_until_ok T001)"
assert_match "^T001[[:space:]]ok[[:space:]]approve" "$review_reconcile_out" "reviewer envelope reconciled: verdict approve"

run_ok "advance arbitrating" "$ORCHID_BIN" task advance T001 arbitrating \
  --reason "review reconciled: verdict approve" >/dev/null

# ---------------------------------------------------------------------------
# arbitrating -> merging: inline judgment (approve), journaled with kind
# `arbitration` by the kernel itself (from=arbitrating).
# ---------------------------------------------------------------------------
run_ok "advance merging" "$ORCHID_BIN" task advance T001 merging \
  --reason "approved for merge" >/dev/null
assert_match "T001 arbitration" "$(cat .orchid/journal.md)" "journal records the arbitration entry"

# ---------------------------------------------------------------------------
# merging: orchid merge, real transactional merge onto the integration
# branch, exit 0, task -> done.
# ---------------------------------------------------------------------------
pre_integ="$(git rev-parse "$integ")"
rc=0; merge_out="$("$ORCHID_BIN" merge T001 2>&1)" || rc=$?
assert_eq 0 "$rc" "merge exits 0"
assert_match "^merged T001: $integ -> " "$merge_out" "merge prints the merged message"

post_integ="$(git rev-parse "$integ")"
[ "$post_integ" != "$pre_integ" ] || fail "integration ref must have advanced"
assert_eq done "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "task T001 reaches done"

git merge-base --is-ancestor "$cand1" "$integ" \
  || fail "integration branch must contain the stub's own commit ($cand1)"
git show "$integ:stub_feature.txt" >/dev/null 2>&1 \
  || fail "integration branch tree contains the stub's committed file"

# ---------------------------------------------------------------------------
# COMPLETION: run advance accepting -> acceptance evidence -> run accept.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" run refresh-lease >/dev/null   # THE TICK's "before sleeping" step, once at the close

explain_out="$("$ORCHID_BIN" status --explain)"
assert_match "T001[[:space:]]done[[:space:]].*-$" "$explain_out" "status --explain: T001 done, no outstanding reason"
echo "$explain_out" | grep -qi "blocked\|FAIL" && fail "status --explain must be clean (no blocked/FAIL) once T001 is done"

run_ok "run advance accepting" "$ORCHID_BIN" run advance accepting \
  --reason "all tasks done" >/dev/null

echo "acceptance: T001 done; REQ-1 satisfied (stub_feature.txt present on $integ)" > "$WORK/acceptance.log"
accept_out="$(run_ok "run accept" "$ORCHID_BIN" run accept --reason "all requirements covered" \
  --evidence "$WORK/acceptance.log")"
assert_match "accepting -> complete" "$accept_out" "run accept transitions to complete"

assert_eq complete "$(fm_get "$WORK/.orchid/roadmap.md" run_status)" "run_status: complete"
assert_eq "$(cat "$WORK/acceptance.log")" "$(cat .orchid/reviews/acceptance.log)" \
  "acceptance evidence copied verbatim"

journal="$(cat .orchid/journal.md)"
assert_match "T001 arbitration" "$journal" "journal contains the arbitration entry"
assert_match "run acceptance" "$journal" "journal contains the acceptance entry"

final_explain="$("$ORCHID_BIN" status --explain)"
assert_match "run_status: complete" "$final_explain" "final status --explain: run_status complete"
echo "$final_explain" | grep -qi "blocked\|FAIL" && fail "final status --explain must be clean"
