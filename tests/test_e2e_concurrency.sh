#!/usr/bin/env bash
# v1-m2 Task 5 integration proof: concurrency cap 2 + deterministic
# scheduling gates, driven entirely through REAL `orchid` verbs against a
# real fixture repo (stub engines only, exactly like tests/
# test_e2e_lifecycle.sh) -- no fixture hand-fabricates the rebase scenario:
# T1 and T2 are two genuinely independent tasks dispatched concurrently,
# T1 merges first and moves the integration branch, and T2's OWN merge
# attempt is what triggers the real exit-5 rebase-rereview path (INV-07).
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

run_ok() {
  local desc="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "$desc (exit $rc): $out"
  printf '%s\n' "$out"
}

# reconcile_until_ok <task> -- polls `orchid jobs reconcile` (which
# reconciles every pending job, not just one) until the named task's line
# reports ok.
reconcile_until_ok() {
  local task="$1" tries=0 out=""
  while [ "$tries" -lt 50 ]; do
    out="$("$ORCHID_BIN" jobs reconcile)"
    if printf '%s\n' "$out" | grep -Eq "^${task}[[:space:]]ok"; then
      printf '%s\n' "$out"
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  fail "timed out waiting for $task to reconcile ok (last reconcile output: $out)"
}

# reconcile_until_both <task1> <task2> -- T1 and T2 are dispatched
# CONCURRENTLY, so their two envelopes can land in the spool in either order
# or on different reconcile ticks. Once a job is reconciled it is removed
# from the spool and never reappears in a later `jobs reconcile` call's
# output -- so, unlike reconcile_until_ok (one task, called once), this
# accumulates output ACROSS calls and looks for both tasks' `ok` lines
# anywhere in that running history, not just in the latest tick.
reconcile_until_both() {
  local t1="$1" t2="$2" tries=0 acc="" tick
  while [ "$tries" -lt 50 ]; do
    tick="$("$ORCHID_BIN" jobs reconcile)"
    acc="$acc
$tick"
    if printf '%s\n' "$acc" | grep -Eq "^${t1}[[:space:]]ok" && \
       printf '%s\n' "$acc" | grep -Eq "^${t2}[[:space:]]ok"; then
      printf '%s\n' "$acc"
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  fail "timed out waiting for both $t1 and $t2 to reconcile ok (accumulated: $acc)"
}

cd "$WORK"; git init -q .

export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'role.implementer=stubimpl\nrole.reviewer=stubreview\nconcurrency=2\n' > orchid.config
git add -A && git commit -q -m "fixture: config"

run_ok "orchid init" "$ORCHID_BIN" init >/dev/null

integ=orchid/integration
git checkout -q "$integ"

# ---------------------------------------------------------------------------
# Real stub engines: implementer commits a task-specific file in ITS OWN
# worktree (so T1 and T2 never collide/conflict on rebase); reviewer approves
# the exact candidate_sha it was asked to review (sha-bound, like the real
# review gate expects).
# ---------------------------------------------------------------------------
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/stubimpl" "$WORK/eng/stubreview"
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
echo "stub implementation for $task" > "stub_${task}.txt"
git add "stub_${task}.txt"
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
cand="$(jq -r .candidate_sha "$req")"
[ "$op" = review ] || exit 1
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"stub review: approved", candidate_sha:$cand}' > "$out"
EOF
chmod +x "$WORK/eng/stubreview/run"

export ORCHID_EPOCH="$(run_ok "orchid run start" "$ORCHID_BIN" run start | sed 's/epoch: //')"

cat > "$WORK/requirements-v1.md" <<'EOF'
# Requirements
- REQ-1: two independent stub features land on the integration branch.
EOF
run_ok "requirements import" "$ORCHID_BIN" requirements import "$WORK/requirements-v1.md" >/dev/null

run_ok "task create T1" "$ORCHID_BIN" task create T1 "stub feature one" >/dev/null
run_ok "task set T1 acceptance_criteria" "$ORCHID_BIN" task set T1 acceptance_criteria \
  "stub_T1.txt exists on the integration branch once T1 is done" >/dev/null
run_ok "task set T1 verification_commands" "$ORCHID_BIN" task set T1 verification_commands \
  "test -f stub_T1.txt" >/dev/null

run_ok "task create T2" "$ORCHID_BIN" task create T2 "stub feature two" >/dev/null
run_ok "task set T2 acceptance_criteria" "$ORCHID_BIN" task set T2 acceptance_criteria \
  "stub_T2.txt exists on the integration branch once T2 is done" >/dev/null
run_ok "task set T2 verification_commands" "$ORCHID_BIN" task set T2 verification_commands \
  "test -f stub_T2.txt" >/dev/null

run_ok "plan apply" "$ORCHID_BIN" plan apply --reason "initial plan for T1/T2" >/dev/null
assert_match "running" "$(fm_get "$WORK/.orchid/roadmap.md" run_status)" "plan apply moved run_status to running"

integ_head="$(git rev-parse "$integ")"

dispatch() {
  local id="$1" branch wt
  branch="$(fm_get "$WORK/.orchid/tasks/$id.md" branch)"
  wt="$WORK/wt-$id"
  git worktree add -q "$wt" -b "$branch" "$integ_head" || fail "git worktree add for $id"
  run_ok "task set $id worktree" "$ORCHID_BIN" task set "$id" worktree "$wt" >/dev/null
  run_ok "task set $id base_sha" "$ORCHID_BIN" task set "$id" base_sha "$integ_head" >/dev/null
}

# ---------------------------------------------------------------------------
# Cap honored: T1 dispatches (0 active), T2 dispatches (1 active, cap 2) --
# BOTH end up implementing at once.
# ---------------------------------------------------------------------------
dispatch T1
run_ok "advance T1 implementing" "$ORCHID_BIN" task advance T1 implementing \
  --reason "dispatching: deps satisfied" >/dev/null
assert_eq implementing "$(fm_get "$WORK/.orchid/tasks/T1.md" status)" "T1 dispatched"

dispatch T2
run_ok "advance T2 implementing" "$ORCHID_BIN" task advance T2 implementing \
  --reason "dispatching: deps satisfied" >/dev/null
assert_eq implementing "$(fm_get "$WORK/.orchid/tasks/T2.md" status)" "T2 dispatched (cap 2 honored: both active at once)"

# ---------------------------------------------------------------------------
# A third task is refused outright: cap 2/2 already reached.
# ---------------------------------------------------------------------------
run_ok "task create T3" "$ORCHID_BIN" task create T3 "stub feature three" >/dev/null
rc=0; err_t3="$("$ORCHID_BIN" task advance T3 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "T3 dispatch refused at cap (exit 3)"
assert_match "concurrency-cap \(2/2\)" "$err_t3" "refusal names concurrency-cap (2/2)"
assert_eq pending "$(fm_get "$WORK/.orchid/tasks/T3.md" status)" "T3 stays pending"

# ---------------------------------------------------------------------------
# exclusive: true -- refused while ANYTHING is active (both T1 and T2, here),
# named individually; only dispatches once nothing is active at all.
# ---------------------------------------------------------------------------
run_ok "task create EX1" "$ORCHID_BIN" task create EX1 "exclusive task" >/dev/null
run_ok "task set EX1 exclusive" "$ORCHID_BIN" task set EX1 exclusive true >/dev/null
rc=0; err_ex="$("$ORCHID_BIN" task advance EX1 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "EX1 dispatch refused while T1/T2 are active"
assert_match "exclusive-overlap \(T1\)" "$err_ex" "refusal names exclusive-overlap against active T1"
assert_match "exclusive-overlap \(T2\)" "$err_ex" "refusal names exclusive-overlap against active T2"
assert_eq pending "$(fm_get "$WORK/.orchid/tasks/EX1.md" status)" "EX1 stays pending while T1/T2 are active"

# ---------------------------------------------------------------------------
# T1/T2 real implementer launches (concurrent), reconcile, candidate capture.
# ---------------------------------------------------------------------------
launch_t1="$(run_ok "orchid-launch T1 implementer" "$REPO_ROOT/runners/orchid-launch" T1 implementer implement)"
assert_match "launched j-" "$launch_t1" "T1 implementer job launched"
launch_t2="$(run_ok "orchid-launch T2 implementer" "$REPO_ROOT/runners/orchid-launch" T2 implementer implement)"
assert_match "launched j-" "$launch_t2" "T2 implementer job launched"

reconcile_both="$(reconcile_until_both T1 T2)"
assert_match "^T1[[:space:]]ok" "$reconcile_both" "T1 implementer envelope reconciled ok"
assert_match "^T2[[:space:]]ok" "$reconcile_both" "T2 implementer envelope reconciled ok"
"$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null

cand_t1="$(git -C "$WORK/wt-T1" rev-parse HEAD)"
cand_t2="$(git -C "$WORK/wt-T2" rev-parse HEAD)"
[ "$cand_t1" != "$integ_head" ] || fail "T1 worktree HEAD must have moved"
[ "$cand_t2" != "$integ_head" ] || fail "T2 worktree HEAD must have moved"

run_ok "task set T1 candidate_sha" "$ORCHID_BIN" task set T1 candidate_sha "$cand_t1" >/dev/null
run_ok "task set T2 candidate_sha" "$ORCHID_BIN" task set T2 candidate_sha "$cand_t2" >/dev/null
run_ok "advance T1 testing" "$ORCHID_BIN" task advance T1 testing --reason "implementer ok" >/dev/null
run_ok "advance T2 testing" "$ORCHID_BIN" task advance T2 testing --reason "implementer ok" >/dev/null

rc=0; "$ORCHID_BIN" verify T1 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "T1 verify PASSes"
rc=0; "$ORCHID_BIN" verify T2 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "T2 verify PASSes"

run_ok "advance T1 reviewing" "$ORCHID_BIN" task advance T1 reviewing --reason "verify passed" >/dev/null
run_ok "advance T2 reviewing" "$ORCHID_BIN" task advance T2 reviewing --reason "verify passed" >/dev/null

review_launch_t1="$(run_ok "orchid-launch T1 reviewer" "$REPO_ROOT/runners/orchid-launch" T1 reviewer review)"
assert_match "launched j-" "$review_launch_t1" "T1 reviewer job launched"
review_launch_t2="$(run_ok "orchid-launch T2 reviewer" "$REPO_ROOT/runners/orchid-launch" T2 reviewer review)"
assert_match "launched j-" "$review_launch_t2" "T2 reviewer job launched"

review_reconcile_both="$(reconcile_until_both T1 T2)"
assert_match "^T1[[:space:]]ok[[:space:]]approve" "$review_reconcile_both" "T1 review reconciled: approve"
assert_match "^T2[[:space:]]ok[[:space:]]approve" "$review_reconcile_both" "T2 review reconciled: approve"

run_ok "advance T1 arbitrating" "$ORCHID_BIN" task advance T1 arbitrating --reason "review reconciled: approve" >/dev/null
run_ok "advance T2 arbitrating" "$ORCHID_BIN" task advance T2 arbitrating --reason "review reconciled: approve" >/dev/null
run_ok "advance T1 merging" "$ORCHID_BIN" task advance T1 merging --reason "approved for merge" >/dev/null
run_ok "advance T2 merging" "$ORCHID_BIN" task advance T2 merging --reason "approved for merge" >/dev/null

# ---------------------------------------------------------------------------
# T1 merges first: exit 0, integration branch advances past integ_head.
# ---------------------------------------------------------------------------
rc=0; merge_t1_out="$("$ORCHID_BIN" merge T1 2>&1)" || rc=$?
assert_eq 0 "$rc" "T1 merge exits 0"
assert_match "^merged T1: $integ -> " "$merge_t1_out" "T1 merge prints the merged message"
assert_eq done "$(fm_get "$WORK/.orchid/tasks/T1.md" status)" "T1 reaches done"

post_t1_integ="$(git rev-parse "$integ")"
[ "$post_t1_integ" != "$integ_head" ] || fail "integration ref must have advanced after T1's merge"

# ---------------------------------------------------------------------------
# T2's merge now hits a stale base (T1 moved integ) -- exit 5,
# rebase_rereview_required, base/candidate refreshed, evidence invalidated
# (INV-07), T2 back in testing. Not a fixture: T1's OWN merge is what moved
# the base T2's merge attempt now discovers stale.
# ---------------------------------------------------------------------------
rc=0; merge_t2_out="$("$ORCHID_BIN" merge T2 2>&1)" || rc=$?
assert_eq 5 "$rc" "T2 merge exits 5 (rebase-rereview required)"
assert_match "^rebase_rereview_required T2:" "$merge_t2_out" "T2 merge reports rebase_rereview_required"
assert_eq testing "$(fm_get "$WORK/.orchid/tasks/T2.md" status)" "T2 reset to testing by the rebase-reset path"

new_base_t2="$(fm_get "$WORK/.orchid/tasks/T2.md" base_sha)"
new_cand_t2="$(fm_get "$WORK/.orchid/tasks/T2.md" candidate_sha)"
assert_eq "$post_t1_integ" "$new_base_t2" "T2's base_sha refreshed to the post-T1-merge integration HEAD"
[ "$new_cand_t2" != "$cand_t2" ] || fail "T2's candidate_sha must have changed (fresh rebase SHA)"
[ ! -f "$WORK/.orchid/reviews/T2-verify.log" ] || fail "T2's prior verify evidence must be invalidated (INV-07)"
[ ! -f "$WORK/.orchid/reviews/T2-merge.log" ] || fail "T2's prior merge evidence must be invalidated (INV-07)"
assert_match "T2 rebase_review" "$(cat "$WORK/.orchid/journal.md")" "rebase-reset journaled as rebase_review"

# ---------------------------------------------------------------------------
# Re-verify + re-review + re-arbitrate T2's rebased candidate, through the
# same real verbs -- second merge attempt lands cleanly.
# ---------------------------------------------------------------------------
rc=0; "$ORCHID_BIN" verify T2 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "T2 re-verify PASSes on the rebased candidate"

run_ok "advance T2 reviewing (re-review)" "$ORCHID_BIN" task advance T2 reviewing \
  --reason "re-verified after rebase reset" >/dev/null

review_launch_t2b="$(run_ok "orchid-launch T2 reviewer (re-review)" "$REPO_ROOT/runners/orchid-launch" T2 reviewer review)"
assert_match "launched j-" "$review_launch_t2b" "T2 re-review job launched"
review_reconcile_t2b="$(reconcile_until_ok T2)"
assert_match "^T2[[:space:]]ok[[:space:]]approve" "$review_reconcile_t2b" "T2 re-review reconciled: approve, bound to the new candidate_sha"

run_ok "advance T2 arbitrating (re-review)" "$ORCHID_BIN" task advance T2 arbitrating \
  --reason "re-reviewed after rebase reset" >/dev/null
run_ok "advance T2 merging (re-review)" "$ORCHID_BIN" task advance T2 merging \
  --reason "approved after re-review" >/dev/null

rc=0; merge_t2b_out="$("$ORCHID_BIN" merge T2 2>&1)" || rc=$?
assert_eq 0 "$rc" "T2 second merge attempt exits 0 (INV-07 satisfied)"
assert_match "^merged T2: $integ -> " "$merge_t2b_out" "T2 merge prints the merged message"
assert_eq done "$(fm_get "$WORK/.orchid/tasks/T2.md" status)" "T2 reaches done"

git show "$integ:stub_T1.txt" >/dev/null 2>&1 || fail "integration branch tree contains T1's stub file"
git show "$integ:stub_T2.txt" >/dev/null 2>&1 || fail "integration branch tree contains T2's stub file"

# ---------------------------------------------------------------------------
# Both T1/T2 are now done (nothing active) -- EX1 dispatches cleanly.
# ---------------------------------------------------------------------------
run_ok "advance EX1 implementing (retry)" "$ORCHID_BIN" task advance EX1 implementing \
  --reason "T1/T2 both done, nothing active" >/dev/null
assert_eq implementing "$(fm_get "$WORK/.orchid/tasks/EX1.md" status)" "EX1 dispatches once T1/T2 are both done"
# Free EX1 again so it doesn't linger active as an exclusive task confounding
# the resource-conflict scenario below.
"$ORCHID_BIN" task advance EX1 blocked --reason "freed for the next scenario" >/dev/null

# ---------------------------------------------------------------------------
# resources: db -- two tasks sharing a resource are never active together.
# ---------------------------------------------------------------------------
run_ok "task create R1" "$ORCHID_BIN" task create R1 "resource task one" >/dev/null
run_ok "task set R1 resources" "$ORCHID_BIN" task set R1 resources db >/dev/null
run_ok "task create R2" "$ORCHID_BIN" task create R2 "resource task two" >/dev/null
run_ok "task set R2 resources" "$ORCHID_BIN" task set R2 resources db >/dev/null

run_ok "advance R1 implementing" "$ORCHID_BIN" task advance R1 implementing \
  --reason "dispatching R1" >/dev/null
assert_eq implementing "$(fm_get "$WORK/.orchid/tasks/R1.md" status)" "R1 dispatched (no conflict yet)"

rc=0; err_r2="$("$ORCHID_BIN" task advance R2 implementing 2>&1 1>/dev/null)" || rc=$?
assert_eq 3 "$rc" "R2 dispatch refused while R1 (shares 'db') is active"
assert_match "resource-conflict \(db: R1\)" "$err_r2" "refusal names resource-conflict against active R1"
assert_eq pending "$(fm_get "$WORK/.orchid/tasks/R2.md" status)" "R2 stays pending while R1 holds 'db'"

"$ORCHID_BIN" task advance R1 blocked --reason "freeing db for R2" >/dev/null
run_ok "advance R2 implementing" "$ORCHID_BIN" task advance R2 implementing \
  --reason "R1 no longer active, db free" >/dev/null
assert_eq implementing "$(fm_get "$WORK/.orchid/tasks/R2.md" status)" "R2 dispatches once R1 releases 'db' (never active together)"

echo "e2e concurrency: OK"
