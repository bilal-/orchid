#!/usr/bin/env bash
# v1-m2 Task 9: greenfield mode. Full walk in a scratch EMPTY repo (unborn
# HEAD, no files at all) with real stub engines: `orchid doctor --greenfield`
# passes pre-init, `orchid init --greenfield` mints the root commit itself
# and proceeds through the normal init flow, T001 (the scaffold task,
# `scaffold: true`, structural `verification_commands`) is walked
# pending->done through the real verbs exactly like tests/
# test_e2e_lifecycle.sh, and a second normal task builds on top of the
# scaffold it left behind. Also covers the two refusal paths: --greenfield
# refused in a dir with stray uncommitted files, and plain `init` refused
# (with a --greenfield hint) on an unborn-HEAD repo.
#
# The repo directory itself ($repo, below) must stay LITERALLY EMPTY (only
# .git) until `init --greenfield`'s own root commit -- so, unlike the other
# e2e fixtures, engine role config here is supplied entirely via
# ORCHID_ROLE_* env vars and an ORCHID_ENGINES_DIR that lives OUTSIDE the
# repo (config_get checks env vars before any repo file; resolve_engine_exe
# treats ORCHID_ENGINES_DIR as a resolver-only test hook independent of the
# repo tree) -- no orchid.config, no eng/ dir, nothing but .git sits in the
# repo before the root commit.
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
    if grep -Eq "^${task}[[:space:]]ok" <<<"$out"; then
      "$ORCHID_BIN" jobs gc --older-than-s 0 >/dev/null
      printf '%s\n' "$out"
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  fail "timed out waiting for $task to reconcile ok (last reconcile output: $out)"
}

# ---------------------------------------------------------------------------
# Fixture: engines live OUTSIDE the repo ($WORK/eng), roles wired via env
# vars (never a repo-local orchid.config) so the repo dir can start and stay
# genuinely empty right up to the greenfield root commit.
# ---------------------------------------------------------------------------
export HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"
export ORCHID_ROLE_ORCHESTRATOR=fake ORCHID_ROLE_REVIEWER=fake \
       ORCHID_ROLE_ARBITER=fake ORCHID_ROLE_PLAN_CRITIC=fake \
       ORCHID_ROLE_IMPLEMENTER=stubimpl

mkdir -p "$WORK/eng/fake"
printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"
chmod +x "$WORK/eng/fake/run"

mkdir -p "$WORK/eng/stubimpl"
printf 'manifest_version=1\nid=test/stubimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubimpl/plugin.conf"
# T001 is the scaffold task: the stub creates README.md. Any other task gets
# a task-specific stub file, same convention as test_e2e_concurrency.sh.
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
cd "$worktree" || exit 1
if [ "$task" = T001 ]; then
  echo "# Greenfield scaffold" > README.md
  git add README.md
else
  echo "stub implementation for $task" > "stub_${task}.txt"
  git add "stub_${task}.txt"
fi
git -c user.email=stub-implementer@example.com -c user.name="stub implementer" \
  commit -q -m "stub: implement $task"
sha="$(git rev-parse HEAD)"
jq -n --arg jid "$jid" --arg task "$task" --arg sha "$sha" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"stub implemented", commits:[$sha]}' > "$out"
EOF
chmod +x "$WORK/eng/stubimpl/run"

# ---------------------------------------------------------------------------
# Refusal 1: init --greenfield in a dir with stray uncommitted files must be
# refused -- greenfield never adopts a pre-existing pile silently.
# ---------------------------------------------------------------------------
stray_dir="$WORK/stray"; mkdir -p "$stray_dir"
git init -q "$stray_dir"
echo "oops" > "$stray_dir/oops.txt"
rc=0; err_stray="$(ORCHID_REPO="$stray_dir" "$ORCHID_BIN" init --greenfield 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "init --greenfield must refuse a dir with stray uncommitted files"
assert_match "oops.txt" "$err_stray" "init --greenfield refusal names the stray file"
git -C "$stray_dir" rev-parse -q --verify HEAD >/dev/null 2>&1 \
  && fail "init --greenfield must not create a root commit when refused for stray files"

# ---------------------------------------------------------------------------
# Refusal 2: plain `init` (no --greenfield) on an unborn-HEAD repo dies with
# a hint to use --greenfield, rather than the raw `git branch ... HEAD`
# failure this used to surface.
# ---------------------------------------------------------------------------
unborn_dir="$WORK/unborn-plain"; mkdir -p "$unborn_dir"
git init -q "$unborn_dir"
rc=0; err_unborn="$(ORCHID_REPO="$unborn_dir" "$ORCHID_BIN" init 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "plain init on an unborn-HEAD repo must die"
assert_match "greenfield" "$err_unborn" "plain init on unborn HEAD hints at --greenfield"
git -C "$unborn_dir" rev-parse -q --verify HEAD >/dev/null 2>&1 \
  && fail "plain init must not create a root commit on an unborn-HEAD repo"

# ---------------------------------------------------------------------------
# The real walk starts here: a genuinely empty repo (only .git).
# ---------------------------------------------------------------------------
repo="$WORK/repo"; mkdir -p "$repo"
git init -q "$repo"
export ORCHID_REPO="$repo"

only_git="$(list_dir_entries "$repo" | grep -Fxv .git || true)"
[ -z "$only_git" ] || fail "fixture bug: repo must be empty apart from .git before the greenfield walk starts"

# ---------------------------------------------------------------------------
# doctor --greenfield passes PRE-INIT, on the unborn-HEAD empty repo: verify
# check deferred with a note, integration-branch check accepts unborn HEAD.
# ---------------------------------------------------------------------------
out_doctor="$("$ORCHID_BIN" doctor --greenfield)" || fail "doctor --greenfield passes pre-init on an unborn-HEAD, empty repo"
assert_match "greenfield: verify command deferred to scaffold task" "$out_doctor" \
  "doctor --greenfield: verify check skipped with the greenfield note"
assert_match "greenfield: root commit pending" "$out_doctor" \
  "doctor --greenfield: integration-branch check accepts unborn HEAD"
grep -q "^FAIL" <<<"$out_doctor" && fail "doctor --greenfield must report no FAILs pre-init"

# ---------------------------------------------------------------------------
# init --greenfield: mints the root commit itself, then proceeds through the
# normal init flow (integration branch from the new HEAD, .orchid/ skeleton,
# lockfile, commit).
# ---------------------------------------------------------------------------
run_ok "orchid init --greenfield" "$ORCHID_BIN" init --greenfield >/dev/null

git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1 \
  || fail "init --greenfield must leave a root commit behind"
assert_eq "orchid: root" "$(git -C "$repo" log -1 --format=%s HEAD)" "root commit subject"

integ=orchid/integration
git -C "$repo" rev-parse --verify -q "$integ" >/dev/null 2>&1 \
  || fail "init --greenfield must create the integration branch"
grep -q "run_status: planning" <<<"$(git -C "$repo" show "$integ:.orchid/roadmap.md" 2>/dev/null)" \
  || fail "init --greenfield: roadmap committed with run_status"

cd "$repo" || exit 1
git checkout -q "$integ"

# ---------------------------------------------------------------------------
# PLANNING: requirements import, T001 authored as the scaffold task
# (scaffold: true, structural verification_commands), plan apply.
# ---------------------------------------------------------------------------
ORCHID_EPOCH="$(run_ok "orchid run start" "$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
[ -n "$ORCHID_EPOCH" ] || fail "epoch minted by run start"

cat > "$WORK/requirements-v1.md" <<'EOF'
# Requirements
- REQ-1: a README.md scaffold lands on the integration branch (T001).
- REQ-2: a second, normal task builds on top of the scaffold.
EOF
run_ok "requirements import" "$ORCHID_BIN" requirements import "$WORK/requirements-v1.md" >/dev/null

run_ok "task create T001" "$ORCHID_BIN" task create T001 "scaffold: README.md" >/dev/null
run_ok "task set T001 scaffold" "$ORCHID_BIN" task set T001 scaffold true >/dev/null
assert_eq true "$(fm_get "$repo/.orchid/tasks/T001.md" scaffold)" "T001: scaffold true is a plain settable key"
run_ok "task set T001 acceptance_criteria" "$ORCHID_BIN" task set T001 acceptance_criteria \
  "README.md exists on the integration branch once T001 is done" >/dev/null
run_ok "task set T001 verification_commands" "$ORCHID_BIN" task set T001 verification_commands \
  "test -f README.md" >/dev/null

run_ok "task create T002" "$ORCHID_BIN" task create T002 "second normal task" >/dev/null
assert_eq false "$(fm_get "$repo/.orchid/tasks/T002.md" scaffold)" "T002: scaffold stays false (template default)"
run_ok "task set T002 acceptance_criteria" "$ORCHID_BIN" task set T002 acceptance_criteria \
  "stub_T002.txt exists on the integration branch, built on top of the scaffold" >/dev/null
run_ok "task set T002 verification_commands" "$ORCHID_BIN" task set T002 verification_commands \
  "test -f README.md && test -f stub_T002.txt" >/dev/null

run_ok "plan apply" "$ORCHID_BIN" plan apply --reason "initial plan: T001 scaffold, T002 builds on it" >/dev/null
assert_match "running" "$(fm_get "$repo/.orchid/roadmap.md" run_status)" "plan apply moved run_status to running"

# ---------------------------------------------------------------------------
# T001 (scaffold) walked pending -> done through the real verbs.
# ---------------------------------------------------------------------------
integ_head="$(git rev-parse "$integ")"
branch="$(fm_get "$repo/.orchid/tasks/T001.md" branch)"
wt1="$WORK/wt-T001"
git worktree add -q "$wt1" -b "$branch" "$integ_head" || fail "git worktree add for T001"
run_ok "task set T001 worktree" "$ORCHID_BIN" task set T001 worktree "$wt1" >/dev/null
run_ok "task set T001 base_sha" "$ORCHID_BIN" task set T001 base_sha "$integ_head" >/dev/null
run_ok "advance T001 implementing" "$ORCHID_BIN" task advance T001 implementing \
  --reason "dispatching scaffold task" >/dev/null

launch1_out="$(run_ok "orchid-launch T001 implementer" "$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$launch1_out" "T001 implementer job launched"

reconcile1_out="$(reconcile_until_ok T001)"
assert_match "^T001[[:space:]]ok" "$reconcile1_out" "T001 implementer envelope reconciled ok"

cand1="$(git -C "$wt1" rev-parse HEAD)"
[ "$cand1" != "$integ_head" ] || fail "T001 worktree HEAD must have moved past base after the stub committed"
run_ok "task set T001 candidate_sha" "$ORCHID_BIN" task set T001 candidate_sha "$cand1" >/dev/null
run_ok "advance T001 testing" "$ORCHID_BIN" task advance T001 testing \
  --reason "implementer envelope ok" >/dev/null

rc=0; verify1_out="$("$ORCHID_BIN" verify T001)" || rc=$?
assert_eq 0 "$rc" "T001 structural verify (test -f README.md) PASSes"
assert_match "PASS" "$verify1_out" "T001 verify reports PASS"

run_ok "advance T001 reviewing" "$ORCHID_BIN" task advance T001 reviewing \
  --reason "verify passed" >/dev/null

# risk_tier low (template default) -> review_required_count 1: a single
# sha-bound reviewer envelope, planted the same way tests/test_merge.sh does
# (no reviewer engine dispatch needed for this walk).
plant_reviewer_envelope T001
run_ok "advance T001 arbitrating" "$ORCHID_BIN" task advance T001 arbitrating \
  --reason "review reconciled: approve" >/dev/null
# `task arbitrate`, not `task advance T001 merging`: since T032 the edges an
# arbitration RESULT takes out of `arbitrating` are refused by that verb, and
# only this one records a result. The destination is derived from the archetype.
run_ok "arbitrate T001 approve" "$ORCHID_BIN" task arbitrate T001 --result approve \
  --reason "approved for merge" >/dev/null

pre_integ="$(git rev-parse "$integ")"
rc=0; merge1_out="$("$ORCHID_BIN" merge T001 2>&1)" || rc=$?
assert_eq 0 "$rc" "T001 merge exits 0"
assert_match "^merged T001: $integ -> " "$merge1_out" "T001 merge prints the merged message"
assert_eq "done" "$(fm_get "$repo/.orchid/tasks/T001.md" status)" "T001 reaches done"

post_integ1="$(git rev-parse "$integ")"
[ "$post_integ1" != "$pre_integ" ] || fail "integration ref must have advanced after T001's merge"
git show "$integ:README.md" >/dev/null 2>&1 || fail "integration branch tree contains the scaffold's README.md"

# ---------------------------------------------------------------------------
# T002 (a second, normal task) builds on top of the scaffold: its worktree
# is cut from the POST-T001 integration HEAD, so README.md is already there.
# ---------------------------------------------------------------------------
integ_head2="$(git rev-parse "$integ")"
branch2="$(fm_get "$repo/.orchid/tasks/T002.md" branch)"
wt2="$WORK/wt-T002"
git worktree add -q "$wt2" -b "$branch2" "$integ_head2" || fail "git worktree add for T002"
[ -f "$wt2/README.md" ] || fail "T002's worktree must already contain the scaffold's README.md"

run_ok "task set T002 worktree" "$ORCHID_BIN" task set T002 worktree "$wt2" >/dev/null
run_ok "task set T002 base_sha" "$ORCHID_BIN" task set T002 base_sha "$integ_head2" >/dev/null
run_ok "advance T002 implementing" "$ORCHID_BIN" task advance T002 implementing \
  --reason "dispatching: builds on the scaffold" >/dev/null

launch2_out="$(run_ok "orchid-launch T002 implementer" "$REPO_ROOT/runners/orchid-launch" T002 implementer implement)"
assert_match "launched j-" "$launch2_out" "T002 implementer job launched"

reconcile2_out="$(reconcile_until_ok T002)"
assert_match "^T002[[:space:]]ok" "$reconcile2_out" "T002 implementer envelope reconciled ok"

cand2="$(git -C "$wt2" rev-parse HEAD)"
[ "$cand2" != "$integ_head2" ] || fail "T002 worktree HEAD must have moved past base after the stub committed"
run_ok "task set T002 candidate_sha" "$ORCHID_BIN" task set T002 candidate_sha "$cand2" >/dev/null
run_ok "advance T002 testing" "$ORCHID_BIN" task advance T002 testing \
  --reason "implementer envelope ok" >/dev/null

rc=0; verify2_out="$("$ORCHID_BIN" verify T002)" || rc=$?
assert_eq 0 "$rc" "T002 verify PASSes (README.md from scaffold + its own stub file)"
assert_match "PASS" "$verify2_out" "T002 verify reports PASS"

run_ok "advance T002 reviewing" "$ORCHID_BIN" task advance T002 reviewing \
  --reason "verify passed" >/dev/null
plant_reviewer_envelope T002
run_ok "advance T002 arbitrating" "$ORCHID_BIN" task advance T002 arbitrating \
  --reason "review reconciled: approve" >/dev/null
run_ok "arbitrate T002 approve" "$ORCHID_BIN" task arbitrate T002 --result approve \
  --reason "approved for merge" >/dev/null

rc=0; merge2_out="$("$ORCHID_BIN" merge T002 2>&1)" || rc=$?
assert_eq 0 "$rc" "T002 merge exits 0"
assert_match "^merged T002: $integ -> " "$merge2_out" "T002 merge prints the merged message"
assert_eq "done" "$(fm_get "$repo/.orchid/tasks/T002.md" status)" "T002 reaches done"

git show "$integ:README.md" >/dev/null 2>&1 || fail "integration branch still contains README.md after T002 merges"
git show "$integ:stub_T002.txt" >/dev/null 2>&1 || fail "integration branch contains T002's own file"

echo "greenfield: OK"
