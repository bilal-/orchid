#!/usr/bin/env bash
# End-to-end proof: crash + epoch-fence + still-live-job recovery, against
# the REAL system (no mocking of orchid itself) — a slow stub engine is
# launched, the orchestrator's own lock is simulated dead (dead-owner
# owner.json, stale mtime past lock_break_s), `orchid run resume` breaks it
# and fences a NEW epoch, the OLD epoch can no longer mutate anything, the
# still-live slow job (its own process group) is found by `jobs check` and
# killed via the timeout path, `jobs gc` reaps its litter, then a clean
# relaunch with a fast stub completes the walk to done.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

run_ok() {
  local desc="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "$desc (exit $rc): $out"
  printf '%s\n' "$out"
}

reconcile_until_ok() {
  local task="$1" tries=0 out=""
  while [ "$tries" -lt 50 ]; do
    out="$("$ORCHID_BIN" jobs reconcile)"
    if printf '%s\n' "$out" | grep -Eq "^${task}[[:space:]]ok"; then
      "$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null
      printf '%s\n' "$out"
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  fail "timed out waiting for $task to reconcile ok (last reconcile output: $out)"
}

cd "$WORK"; git init -q .
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'role.implementer=stubslow\nrole.reviewer=stubreview\n' > orchid.config
git add -A && git commit -q -m "fixture: config"

run_ok "orchid init" "$ORCHID_BIN" init >/dev/null
integ=orchid/integration
git checkout -q "$integ"

export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/stubslow" "$WORK/eng/stubfast" "$WORK/eng/stubreview"

# v1-m2: `orchid-launch` -> `jobs prepare` now resolves via
# resolve_role_available, gated on role_eligibility_reason -- each stub must
# declare the capabilities its role requires (roles/implementer.role,
# roles/reviewer.role) or the launches below would now (correctly) refuse.
printf 'manifest_version=1\nid=test/stubslow\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubslow/plugin.conf"
printf 'manifest_version=1\nid=test/stubfast\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubfast/plugin.conf"
printf 'manifest_version=1\nid=test/stubreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubreview/plugin.conf"

# The slow implementer: sleeps well past this test's patience, long enough
# to still be alive (own process group) by the time we come back around to
# inspect it after simulating the crash. It never gets far enough to write
# an envelope — it is killed first.
cat > "$WORK/eng/stubslow/run" <<'EOF'
#!/usr/bin/env bash
set -eu
sleep 300
EOF
chmod +x "$WORK/eng/stubslow/run"

cat > "$WORK/eng/stubfast/run" <<'EOF'
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
chmod +x "$WORK/eng/stubfast/run"

cat > "$WORK/eng/stubreview/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
cand="$(jq -r .candidate_sha "$req")"
[ "$op" = review ] || exit 1
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"stub review: approved", candidate_sha:$cand}' > "$out"
EOF
chmod +x "$WORK/eng/stubreview/run"

# ---------------------------------------------------------------------------
# run start (epoch1), plan a single task, dispatch it to the SLOW stub.
# ---------------------------------------------------------------------------
epoch1="$(run_ok "orchid run start" "$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$epoch1"
[ -n "$epoch1" ] || fail "epoch1 minted by run start"

cat > "$WORK/requirements-v1.md" <<'EOF'
# Requirements
- REQ-1: stub_feature.txt lands on the integration branch after the task merges.
EOF
run_ok "requirements import" "$ORCHID_BIN" requirements import "$WORK/requirements-v1.md" >/dev/null
run_ok "task create T001" "$ORCHID_BIN" task create T001 "crash-fence demo" >/dev/null
run_ok "task set verification_commands" "$ORCHID_BIN" task set T001 verification_commands \
  "test -f stub_feature.txt" >/dev/null
run_ok "plan apply" "$ORCHID_BIN" plan apply --reason "initial plan for T001" >/dev/null

integ_head="$(git rev-parse "$integ")"
branch="$(fm_get "$WORK/.orchid/tasks/T001.md" branch)"
wt="$WORK/wt-T001"
git worktree add -q "$wt" -b "$branch" "$integ_head" || fail "git worktree add for T001"
run_ok "task set worktree" "$ORCHID_BIN" task set T001 worktree "$wt" >/dev/null
run_ok "task set base_sha" "$ORCHID_BIN" task set T001 base_sha "$integ_head" >/dev/null
run_ok "advance implementing" "$ORCHID_BIN" task advance T001 implementing \
  --reason "dispatching: deps satisfied" >/dev/null

launch_out="$(run_ok "orchid-launch slow implementer" "$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$launch_out" "slow implementer job launched"
slow_pid="$(echo "$launch_out" | awk '{print $4}')"
manifest_before="$(ls "$WORK/.orchid/runtime/jobs/"*.json 2>/dev/null | head -n1)"
[ -n "$manifest_before" ] || fail "manifest exists for the slow job before the crash"
own_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
manifest_pgid="$(jq -r .pgid "$manifest_before")"
[ "$manifest_pgid" -gt 0 ] 2>/dev/null || fail "slow job manifest pgid must be > 0"
[ "$manifest_pgid" != "$own_pgid" ] || fail "slow job must run in its OWN process group, not this test's"
kill -0 "$slow_pid" 2>/dev/null || fail "sanity: slow job pid alive right after launch"

# ---------------------------------------------------------------------------
# Simulate orchestrator death: the run lock is left held by a dead/foreign
# owner, with a stale mtime well past lock_break_s (default 900s) — mirrors
# tests/test_common.sh's dead-owner break fixture exactly. The slow job
# itself is untouched by this — it is a real, still-running process,
# independent of the orchestrator that launched it.
# ---------------------------------------------------------------------------
rt="$WORK/.orchid/runtime"
mkdir -p "$rt/lock"
jq -n '{pid: 999999, pid_start: "x", epoch: 1, hostname: "'"$(hostname)"'"}' > "$rt/lock/owner.json"
touch -t 202001010000 "$rt/lock" "$rt/lock/owner.json"
touch -t 202001010000 "$rt/lease.json" 2>/dev/null || true

kill -0 "$slow_pid" 2>/dev/null || fail "sanity: slow job pid still alive during the simulated crash"

# ---------------------------------------------------------------------------
# `orchid run resume`: breaks the dead lock, journals the break, fences a
# NEW epoch (epoch2 > epoch1).
# ---------------------------------------------------------------------------
resume_out="$(run_ok "orchid run resume" "$ORCHID_BIN" run resume)"
epoch2="$(echo "$resume_out" | sed 's/epoch: //')"
[ "$epoch2" -gt "$epoch1" ] 2>/dev/null || fail "run resume must fence a strictly newer epoch ($epoch1 -> $epoch2)"
assert_match "stale lock broken" "$(cat .orchid/journal.md)" "run resume journals the broken lock"
[ ! -d "$rt/lock" ] || fail "the dead lock must not survive resume (released again after the fenced pass)"

# ---------------------------------------------------------------------------
# Fence assert: the OLD epoch, exported in a SUBSHELL, can no longer mutate
# anything — the current epoch on disk is now epoch2.
# ---------------------------------------------------------------------------
pre_title="$(fm_get "$WORK/.orchid/tasks/T001.md" title)"
(
  export ORCHID_EPOCH="$epoch1"
  rc=0
  "$ORCHID_BIN" task set T001 title "hijacked-by-stale-epoch" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || exit 9
)
[ $? -ne 9 ] || fail "task set under the OLD epoch must be refused (INV-02 fence)"
assert_eq "$pre_title" "$(fm_get "$WORK/.orchid/tasks/T001.md" title)" "task frontmatter untouched by the stale-epoch mutation attempt"

export ORCHID_EPOCH="$epoch2"

# ---------------------------------------------------------------------------
# `jobs check` finds the still-live slow job — its OWN process group, alive
# through the crash and the resume (resume never touches jobs). With the
# default timeout/stall config it is correctly reported `running`, not
# `dead`/`timeout` — proving it really is still alive, not a corpse.
# ---------------------------------------------------------------------------
check_out_live="$("$ORCHID_BIN" jobs check)"
assert_match "^T001[[:space:]]running" "$check_out_live" "jobs check reports the still-live slow job as running"
kill -0 "$slow_pid" 2>/dev/null || fail "slow job pid must still be alive at this point (jobs check must never kill a job within budget)"

# ---------------------------------------------------------------------------
# Force the timeout path: timeout_minutes=0 makes ANY running job's wall
# clock look exceeded. `jobs check` kills it itself (own-pgid group kill)
# and reports `timeout` — the exact escalation path PROTOCOL.md's THE TICK
# step 2 names for a stuck job, exercised here without waiting real minutes.
# ---------------------------------------------------------------------------
printf 'timeout_minutes=0\n' >> orchid.config
# `jobs check`'s timeout math is `now - started_at` in whole seconds (both
# via `date +%s`); guarantee at least one full second has elapsed since
# launch so a fast run doesn't land both reads in the same second (which
# would make the "over budget" comparison 0 > 0 == false).
sleep 1.2
check_out_killed="$("$ORCHID_BIN" jobs check)"
assert_match "^T001[[:space:]]timeout" "$check_out_killed" "jobs check kills the slow job via the timeout path and reports it"
sleep 0.3
kill -0 "$slow_pid" 2>/dev/null && fail "slow job pid must be dead after jobs check's timeout kill"

# `jobs gc` reaps the now-dead manifest's runtime litter.
gc_out="$("$ORCHID_BIN" jobs gc --older-than-s 0)"
assert_match "^gc j-" "$gc_out" "jobs gc reaps the dead slow-job manifest"
[ ! -f "$manifest_before" ] || fail "slow job's manifest must be gone from runtime/jobs after gc"

# Restore a sane timeout for the rest of the walk. config_get's file
# resolution is last-matching-line-wins (see lib/common.sh's
# _cfg_file_get), so an appended override cancels the forced-zero one above
# without needing to edit/delete it — portable across sed dialects.
printf 'timeout_minutes=60\n' >> orchid.config

# ---------------------------------------------------------------------------
# Relaunch cleanly with the good (fast) stub — same task, same worktree,
# still `implementing` (it never advanced past dispatch since the first
# attempt never produced an envelope). Same last-wins trick: appending a
# new role.implementer binding overrides the stubslow one above.
# ---------------------------------------------------------------------------
printf 'role.implementer=stubfast\n' >> orchid.config
assert_eq implementing "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "task T001 still implementing, ready for a clean relaunch"

relaunch_out="$(run_ok "orchid-launch fast implementer" "$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$relaunch_out" "fast implementer relaunch"

reconcile_out="$(reconcile_until_ok T001)"
assert_match "^T001[[:space:]]ok" "$reconcile_out" "fast implementer envelope reconciled ok"

cand1="$(git -C "$wt" rev-parse HEAD)"
[ "$cand1" != "$integ_head" ] || fail "worktree HEAD must have moved past base after the fast stub committed"
run_ok "task set candidate_sha" "$ORCHID_BIN" task set T001 candidate_sha "$cand1" >/dev/null
run_ok "advance testing" "$ORCHID_BIN" task advance T001 testing \
  --reason "implementer envelope ok" >/dev/null

rc=0; verify_out="$("$ORCHID_BIN" verify T001)" || rc=$?
assert_eq 0 "$rc" "orchid verify PASSes against the relaunched candidate"
assert_match "PASS" "$verify_out" "verify reports PASS"

run_ok "advance reviewing" "$ORCHID_BIN" task advance T001 reviewing --reason "verify passed" >/dev/null

review_launch_out="$(run_ok "orchid-launch reviewer" "$REPO_ROOT/runners/orchid-launch" T001 reviewer review)"
assert_match "launched j-" "$review_launch_out" "reviewer job launched"
review_reconcile_out="$(reconcile_until_ok T001)"
assert_match "^T001[[:space:]]ok[[:space:]]approve" "$review_reconcile_out" "reviewer envelope reconciled: verdict approve"

run_ok "advance arbitrating" "$ORCHID_BIN" task advance T001 arbitrating \
  --reason "review reconciled: verdict approve" >/dev/null
run_ok "advance merging" "$ORCHID_BIN" task advance T001 merging --reason "approved for merge" >/dev/null

pre_integ="$(git rev-parse "$integ")"
rc=0; merge_out="$("$ORCHID_BIN" merge T001 2>&1)" || rc=$?
assert_eq 0 "$rc" "merge exits 0 after the crash-and-recover walk"
post_integ="$(git rev-parse "$integ")"
[ "$post_integ" != "$pre_integ" ] || fail "integration ref must have advanced"
assert_eq done "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "task T001 reaches done"
git merge-base --is-ancestor "$cand1" "$integ" \
  || fail "integration branch must contain the relaunched stub's own commit ($cand1)"

final_explain="$("$ORCHID_BIN" status --explain)"
assert_match "T001[[:space:]]done[[:space:]].*-$" "$final_explain" "status --explain: T001 done, clean"
echo "$final_explain" | grep -qi "blocked\|FAIL" && fail "final status --explain must be clean"
