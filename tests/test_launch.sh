#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; echo a > f.txt; git add f.txt; git commit -q -m base
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
mkdir -p "$WORK/eng/fake"
# v1-m2: `jobs prepare` (via runners/orchid-launch) now resolves through
# resolve_role_available, gated on role_eligibility_reason -- "fake" must
# declare the implementer role's required capabilities to remain
# discoverable+eligible, or the launch below would now (correctly) refuse.
# requires_binaries=jq below is just a representative populated value -- the
# bash-3.2 empty-CSV/array quirk this key used to be needed to sidestep is
# fixed directly in lib/manifest.sh's _manifest_split_csv now (see its own
# header comment; tests/test_failover.sh's mk_engine drops this key entirely
# to demonstrate the fix).
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/fake/plugin.conf"
cat > "$WORK/eng/fake/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
[ -f "$(jq -r .input_pack "$req")/pack.json" ] || exit 1
[ "$(jq -r .operation "$req")" = implement ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"implement","status":"ok","summary":"stub done"}' "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/fake/run"
export ORCHID_ENGINES_DIR="$WORK/eng"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo

out="$("$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$out" "launch reports job id"

# Process-group isolation: a plain `&` inherits the parent's process group,
# so the manifest pgid would be the ORCHESTRATOR's group — `jobs check`'s
# stall/timeout group-kill would then kill the orchestrator itself. The
# spawned engine must land in its OWN process group (pgid == its own pid),
# distinct from this test script's group. Captured from the manifest BEFORE
# `jobs reconcile` (which deletes it).
job_id="$(echo "$out" | awk '{print $2}')"
launched_pid="$(echo "$out" | awk '{print $4}')"
manifest="$WORK/.orchid/runtime/jobs/$job_id.json"
[ -f "$manifest" ] || fail "manifest file exists for job before reconcile"
manifest_pid="$(jq -r .pid "$manifest")"
manifest_pgid="$(jq -r .pgid "$manifest")"
own_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
assert_eq "$launched_pid" "$manifest_pid" "manifest pid matches launched pid"
[ "$manifest_pgid" -gt 0 ] 2>/dev/null || fail "manifest pgid must be > 0 (got '$manifest_pgid')"
[ -z "$own_pgid" ] || [ "$manifest_pgid" != "$own_pgid" ] \
  || fail "manifest pgid must differ from the test's own process group (child must not inherit orchestrator's pgid)"
assert_eq "$manifest_pid" "$manifest_pgid" "manifest pgid equals the child pid (child is its own process group leader)"

sleep 1
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "stub engine envelope reconciled end-to-end"
# request document sanity: recorded in runtime/requests
req="$(ls "$WORK/.orchid/runtime/requests/"*.json | head -n1)"
assert_eq "implement" "$(jq -r .operation "$req")" "request operation"
assert_eq "workspace-write" "$(jq -r .policy "$req")" "implement policy"

# -- env hygiene (Task 5): the child only sees the base allowlist (PATH,
# HOME, USER, LANG, LC_*, TERM, TMPDIR, ORCHID_*) plus exactly the env var
# names a plugin's manifest opts into via `permissions=`. SECRET_LEAK is set
# in the PARENT but neither base-allowlisted nor opted into by the first
# stub's manifest (it has no plugin.conf at all) -- it must not reach the
# child. ORCHID_MARKER (ORCHID_*) and PATH must always reach the child.
export SECRET_LEAK="topsecret-value"
export ORCHID_MARKER="marker-should-pass"
mkdir -p "$WORK/eng/leaky"
cat > "$WORK/eng/leaky/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"implement","status":"ok","summary":"SECRET_LEAK=<%s> ORCHID_MARKER=<%s> PATH_SET=<%s>"}' \
  "$jid" "$task" "${SECRET_LEAK:-}" "${ORCHID_MARKER:-}" "${PATH:+yes}" > "$out"
EOF
chmod +x "$WORK/eng/leaky/run"
printf 'role.leaktest=leaky\n' >> "$WORK/orchid.config"

"$ORCHID_BIN" task create T002 demo2 >/dev/null
"$REPO_ROOT/runners/orchid-launch" T002 leaktest implement >/dev/null
sleep 1
"$ORCHID_BIN" jobs reconcile >/dev/null
summary="$(jq -r .summary "$WORK/.orchid/reviews/T002-a1-leaktest.json")"
assert_match "SECRET_LEAK=<>" "$summary" "child does NOT see SECRET_LEAK (not allowlisted, not opted into)"
assert_match "ORCHID_MARKER=<marker-should-pass>" "$summary" "child sees ORCHID_MARKER (ORCHID_* always allowed)"
assert_match "PATH_SET=<yes>" "$summary" "child sees PATH (always allowed)"

# -- opting into SECRET_LEAK via plugin.conf permissions= makes it reach the
# child (the ONLY way a non-base name may cross the boundary).
mkdir -p "$WORK/eng/leaky2"
cp "$WORK/eng/leaky/run" "$WORK/eng/leaky2/run"; chmod +x "$WORK/eng/leaky2/run"
printf 'manifest_version=1\nid=orchid/leaky2\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\npermissions=SECRET_LEAK\n' \
  > "$WORK/eng/leaky2/plugin.conf"
printf 'role.leaktest2=leaky2\n' >> "$WORK/orchid.config"

"$ORCHID_BIN" task create T003 demo3 >/dev/null
"$REPO_ROOT/runners/orchid-launch" T003 leaktest2 implement >/dev/null
sleep 1
"$ORCHID_BIN" jobs reconcile >/dev/null
summary2="$(jq -r .summary "$WORK/.orchid/reviews/T003-a1-leaktest2.json")"
assert_match "SECRET_LEAK=<topsecret-value>" "$summary2" "child DOES see SECRET_LEAK once plugin.conf opts in via permissions="

# ---------------------------------------------------------------------------
# v1-m3: `runners/orchid-launch plan plan_critic critique` -- the reserved
# task id `plan` has no `.orchid/tasks/plan.md` at all, so the launcher must
# (a) resolve a worktree WITHOUT crashing on the missing task file (defaults
# to the repo itself) and (b) hand the stub engine a plan-scoped pack
# (requirements.md + roadmap.md + tasks.md; no task.md/diff.patch) built by
# lib/pack.sh's plan branch, not the ordinary per-task pack.
# ---------------------------------------------------------------------------
echo "# Requirements" > "$WORK/.orchid/requirements.md"
printf -- '---\nrun_status: planning\n---\n# Roadmap\nDraft body.\n' > "$WORK/.orchid/roadmap.md"

mkdir -p "$WORK/eng/critic"
printf 'manifest_version=1\nid=test/critic\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/critic/plugin.conf"
cat > "$WORK/eng/critic/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
pack="$(jq -r .input_pack "$req")"
[ -f "$pack/requirements.md" ] || exit 1
[ -f "$pack/roadmap.md" ] || exit 1
[ -f "$pack/tasks.md" ] || exit 1
[ ! -f "$pack/task.md" ] || exit 1
[ ! -f "$pack/diff.patch" ] || exit 1
[ "$(jq -r .operation "$req")" = critique ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"critique","status":"ok","verdict":"request-changes","scope_complete":true,"findings":[{"severity":"medium","title":"stub finding"}]}' \
  "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/critic/run"
printf 'role.plan_critic=critic\n' >> "$WORK/orchid.config"

plan_launch_out="$("$REPO_ROOT/runners/orchid-launch" plan plan_critic critique)"
assert_match "launched j-" "$plan_launch_out" "plan critique launch reports job id"
sleep 1
plan_reconcile_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "plan	ok" "$plan_reconcile_line" "plan critique job reconciled end-to-end"
[ -f "$WORK/.orchid/reviews/plan-a1-plan_critic.json" ] || fail "plan critique envelope filed at plan-a1-plan_critic.json"
assert_eq "1" "$(jq '.findings | length' "$WORK/.orchid/reviews/plan-a1-plan_critic.json")" "plan critique envelope carries the stub finding"

plan_req=""
for rf in "$WORK/.orchid/runtime/requests/"*.json; do
  [ "$(jq -r .task "$rf" 2>/dev/null)" = "plan" ] && plan_req="$rf" && break
done
[ -n "$plan_req" ] || fail "plan critique request document not found under runtime/requests"
assert_eq "$WORK" "$(jq -r .worktree "$plan_req")" "plan critique request worktree defaults to the repo (no task file to read one from)"

# ===========================================================================
# T040 / dogfood finding F35, END TO END through the real launcher.
#
# The incident: a critique attempt ran to completion, wrote eight complete
# findings to its job log, and exited WITHOUT writing an envelope. reconcile
# had nothing to land, so from the outside the attempt simply never happened;
# the findings survived only because an operator went grepping runtime logs.
#
# `plan critique` is deliberately the shape used here -- it is the exact
# operation that failed in the real run -- and the stub engine below does
# precisely what that engine did: prints its results in the adapters' own
# reply grammar (which the launcher's `>> "$log"` redirect captures verbatim,
# the same way it captured the real one), then exits non-zero without ever
# touching its `output` path.
#
# Two properties can only be proved HERE, against the real launcher, and not
# in tests/test_jobs.sh against a hand-built manifest: that the engine's exit
# status is recorded at all (this launcher returns at spawn and nobody waits
# on the child, so without the spawn wrapper the status is simply gone), and
# that the pack/pgid/liveness contract survives that wrapper.
# ===========================================================================
mkdir -p "$WORK/eng/salvager"
printf 'manifest_version=1\nid=test/salvager\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/salvager/plugin.conf"
cat > "$WORK/eng/salvager/run" <<'EOF'
#!/usr/bin/env bash
set -eu
# Does all the work, reports it to stdout, then dies without an envelope --
# the `output` path is never written to at all.
echo "FINDING: high: the reaper never runs in PLANNING"
echo "FINDING: medium: a refusal and its gc disagree about the same predicate"
echo "VERDICT: request-changes"
exit 3
EOF
chmod +x "$WORK/eng/salvager/run"
printf 'role.salvagecritic=salvager\n' >> "$WORK/orchid.config"

salv_launch_out="$("$REPO_ROOT/runners/orchid-launch" plan salvagecritic critique)"
assert_match "^launched j-" "$salv_launch_out" "the salvage-case job launches like any other"
salv_job_id="$(echo "$salv_launch_out" | awk '{print $2}')"
sleep 1

# The exit status of a job nobody waits on: recorded by the launcher's spawn
# wrapper, or lost forever.
assert_eq "3" "$(tr -d '[:space:]' < "$WORK/.orchid/runtime/exits/$salv_job_id" 2>/dev/null)" \
  "the engine's own exit status is recorded — the launcher returns at spawn, so nothing else on this machine ever collects it"

salv_reconcile_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "^plan	no_envelope" "$salv_reconcile_line" \
  "reconcile reports the job that exited without an envelope — printing nothing is what made this look like an attempt that never ran"
salv_landed=".orchid/reviews/plan-a1-salvagecritic.json"
[ -f "$WORK/$salv_landed" ] \
  || fail "the findings the engine already produced must be landed as a degraded envelope rather than discarded (the whole of F35)"
assert_eq no_envelope "$(jq -r .status "$WORK/$salv_landed")" "filed with the first-class no_envelope status"
assert_eq 3 "$(jq -r .exit_code "$WORK/$salv_landed")" "carrying the exit code end to end, from the launcher's record"
assert_eq 2 "$(jq -r '.findings | length' "$WORK/$salv_landed")" "and both findings the engine wrote to its log"
assert_eq request-changes "$(jq -r .verdict "$WORK/$salv_landed")" "and the verdict it reached"
assert_match "Exit code: 3" "$(ORCHID_REPO="$WORK" "$ORCHID_BIN" journal show --task plan)" \
  "with the exit code and log tail journaled, so an operator sees it without knowing to grep runtime/logs"

# ===========================================================================
# v1-m4 Task 3 (worktree-read review packs): orchid-launch now resolves the
# reviewer engine's plugin dir BEFORE pack_build (previously it happened
# only at the spawn site, after the pack was already built) so pack_build
# can see whether that engine declares workspace_read. A big diff + a
# workspace_read-capable engine must reach the spawned engine as diff.stat,
# never diff.patch (the stub `run` below refuses/exits 1 otherwise, so a
# failed reconcile line would itself prove the plumbing broke); the SAME
# big diff + an inline-only engine still hits input_overflow end-to-end,
# unchanged (tests/test_pack.sh already covers lib/pack.sh directly -- this
# proves the LAUNCHER actually wires the capability fact through).
# ===========================================================================
base_wt="$(git -C "$WORK" rev-parse HEAD)"
big_wt_content="$(printf 'w%.0s' $(seq 1 300000))"
printf '%s\n' "$big_wt_content" > "$WORK/big.txt"
(cd_scratch "$WORK" && git add big.txt && git commit -q -m "big change")
cand_wt="$(git -C "$WORK" rev-parse HEAD)"

"$ORCHID_BIN" task create TWT demo >/dev/null
"$ORCHID_BIN" task set TWT base_sha "$base_wt" >/dev/null
"$ORCHID_BIN" task set TWT candidate_sha "$cand_wt" >/dev/null

mkdir -p "$WORK/eng/wtrev"
printf 'manifest_version=1\nid=test/wtrev\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/wtrev/plugin.conf"
cat > "$WORK/eng/wtrev/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"; out="$(jq -r .output "$req")"; jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
pack="$(jq -r .input_pack "$req")"
[ -f "$pack/diff.stat" ] || exit 1
[ ! -f "$pack/diff.patch" ] || exit 1
[ "$(jq -r .operation "$req")" = review ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"summary":"wt stub"}' \
  "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/wtrev/run"
printf 'role.wtcritic=wtrev\n' >> "$WORK/orchid.config"

wt_launch_out="$("$REPO_ROOT/runners/orchid-launch" TWT wtcritic review)"
assert_match "^launched j-" "$wt_launch_out" "worktree-read review launch reports a launched job"
sleep 1
wt_reconcile_line="$("$ORCHID_BIN" jobs reconcile)"
assert_match $'^TWT\tok' "$wt_reconcile_line" \
  "worktree-read review job reconciled end-to-end (stub itself refuses unless diff.stat is present and diff.patch is absent)"

# An inline-only engine (no workspace_read) reviewing the SAME big diff
# still hits input_overflow end-to-end through the real launcher -- unchanged,
# never silently truncated.
mkdir -p "$WORK/eng/inlinerev"
printf 'manifest_version=1\nid=test/inlinerev\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/inlinerev/plugin.conf"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/eng/inlinerev/run"
chmod +x "$WORK/eng/inlinerev/run"
printf 'role.inlinecritic=inlinerev\n' >> "$WORK/orchid.config"

"$ORCHID_BIN" task create TWT2 demo >/dev/null
"$ORCHID_BIN" task set TWT2 base_sha "$base_wt" >/dev/null
"$ORCHID_BIN" task set TWT2 candidate_sha "$cand_wt" >/dev/null
rc=0; wt2_err="$("$REPO_ROOT/runners/orchid-launch" TWT2 inlinecritic review 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "inline-only engine: launcher must fail (input_overflow) for the same big diff, unchanged"
assert_match "input_overflow" "$wt2_err" "inline-only engine: launcher surfaces input_overflow for the big diff"

# ===========================================================================
# v1-m4 Task 2 (push prevention): `orchid init` installs a defense-in-depth
# `.git/hooks/pre-push` guard (PROTOCOL.md already forbids external
# mutation outright -- "the operator alone moves anything to origin" -- but
# a live run pushed a task branch to origin TWICE anyway). Blocks pushes of
# `refs/heads/task/*` and the configured integration branch unless
# ORCHID_ALLOW_PUSH=1; never overwrites a pre-existing user hook; config
# `push_guard=false` skips installing it entirely.
# ===========================================================================
pg="$WORK/pushguard"; mkdir -p "$pg"
(cd "$pg" && git init -q . && git symbolic-ref HEAD refs/heads/trunk && git commit -q --allow-empty -m root)
ORCHID_REPO="$pg" HOME="$WORK/home" "$ORCHID_BIN" init >/dev/null
[ -x "$pg/.git/hooks/pre-push" ] || fail "orchid init installs an executable .git/hooks/pre-push guard by default"

remote="$WORK/push-remote.git"; git init -q --bare "$remote"
git -C "$pg" remote add origin "$remote"
git -C "$pg" branch task/T001 trunk

rc=0; task_push_out="$(git -C "$pg" push origin task/T001 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "push guard must block pushing a task/* branch"
assert_match "push blocked" "$task_push_out" "push guard names the block plainly"

rc=0; integ_push_out="$(git -C "$pg" push origin orchid/integration 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "push guard must block pushing the integration branch"
assert_match "push blocked" "$integ_push_out" "push guard names the block plainly for the integration branch"

# ORCHID_ALLOW_PUSH=1 overrides the guard for exactly the ref it names.
rc=0; ORCHID_ALLOW_PUSH=1 git -C "$pg" push origin task/T001 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "ORCHID_ALLOW_PUSH=1 must allow pushing a task/* branch"

# A branch that is neither task/* nor the integration branch pushes normally,
# guard or no guard.
git -C "$pg" branch feature/other trunk
rc=0; other_push_out="$(git -C "$pg" push origin feature/other 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "push guard must never block a non-task/non-integration branch (got: $other_push_out)"

# A pre-existing user pre-push hook must NEVER be overwritten by init.
pg2="$WORK/pushguard-userhook"; mkdir -p "$pg2"
(cd "$pg2" && git init -q . && git symbolic-ref HEAD refs/heads/trunk && git commit -q --allow-empty -m root)
mkdir -p "$pg2/.git/hooks"
printf '#!/bin/sh\necho custom-user-hook\nexit 0\n' > "$pg2/.git/hooks/pre-push"
chmod +x "$pg2/.git/hooks/pre-push"
custom_hook_before="$(cat "$pg2/.git/hooks/pre-push")"
init_out="$(ORCHID_REPO="$pg2" HOME="$WORK/home" "$ORCHID_BIN" init)"
assert_match "existing pre-push hook found" "$init_out" "orchid init reports skipping an existing user pre-push hook"
assert_eq "$custom_hook_before" "$(cat "$pg2/.git/hooks/pre-push")" "orchid init must never overwrite an existing pre-push hook"

# push_guard=false (config) skips installing the hook entirely.
pg3="$WORK/pushguard-disabled"; mkdir -p "$pg3"
(cd "$pg3" && git init -q . && git symbolic-ref HEAD refs/heads/trunk \
  && echo "push_guard=false" > orchid.config && git add orchid.config && git commit -q -m cfg)
ORCHID_REPO="$pg3" HOME="$WORK/home" "$ORCHID_BIN" init >/dev/null
[ -e "$pg3/.git/hooks/pre-push" ] && fail "push_guard=false must skip installing the pre-push hook"

# ===========================================================================
# Post-review fix (Important, reviewer-reproduced): the hook used to `grep
# orchid.config` for `integration_branch` at PUSH time -- but a real push
# originates from wherever the pusher's cwd is, which for a task branch is
# a TASK WORKTREE. `orchid.config` is untracked and repo-root-only, so it is
# simply absent there, and a customized integration_branch silently fell
# back to the hook's own hardcoded default -- bypassing that leg of the
# guard. Fixed by resolving the name ONCE at install time (`orchid init`
# substitutes `__INTEGRATION_BRANCH__` via sed, mirroring templates/task.md's
# own placeholder idiom) and baking it into the installed hook file, which
# never reads orchid.config again. Proves both halves: the baked name in the
# installed hook file, and the guard actually firing when triggered from a
# task WORKTREE checkout (not the main repo) that has no orchid.config at
# all on disk.
# ===========================================================================
pg4="$WORK/pushguard-custom"; mkdir -p "$pg4"
# orchid.config here is gitignored, NOT committed -- the realistic shape the
# reviewer's finding actually depends on: `orchid init`'s clean-working-tree
# gate passes because git ignores it (never shows up in `git status
# --porcelain`), `config_get` still reads it fine straight off disk (it
# never cared whether a file is tracked), but a worktree checked out from
# any commit genuinely never receives an ignored, uncommitted file -- unlike
# committing it, which would (wrongly, for this test) carry it into every
# worktree too and mask the exact bug being fixed.
(cd "$pg4" && git init -q . && git symbolic-ref HEAD refs/heads/trunk \
  && echo "orchid.config" > .gitignore && git add .gitignore && git commit -q -m "gitignore local config" \
  && echo "integration_branch=custom/integ" > orchid.config)
ORCHID_REPO="$pg4" HOME="$WORK/home" "$ORCHID_BIN" init >/dev/null
grep -qx 'integ="custom/integ"' "$pg4/.git/hooks/pre-push" \
  || fail "orchid init bakes the CUSTOM integration_branch name into the installed pre-push hook"
grep -q "__INTEGRATION_BRANCH__" "$pg4/.git/hooks/pre-push" \
  && fail "the installed pre-push hook must never carry the raw __INTEGRATION_BRANCH__ placeholder"

remote4="$WORK/push-remote-custom.git"; git init -q --bare "$remote4"
git -C "$pg4" remote add origin "$remote4"
# `orchid init` itself already created the `custom/integ` branch (that IS
# the integration branch it just initialized) -- no separate branch needed.

wt4="$WORK/pushguard-custom-wt"
git -C "$pg4" worktree add -q -b task/T099 "$wt4" trunk
[ ! -e "$wt4/orchid.config" ] || fail "sanity: orchid.config must be absent from the task worktree (untracked, repo-root-only)"

rc=0; wt_task_push_out="$(git -C "$wt4" push origin task/T099 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "push guard must block a task/* branch pushed from a TASK WORKTREE checkout (no orchid.config present there)"
assert_match "push blocked" "$wt_task_push_out" "push guard message fires from the worktree checkout too"

rc=0; wt_integ_push_out="$(git -C "$wt4" push origin custom/integ 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "push guard must block the CUSTOM integration branch pushed from a task worktree checkout"
assert_match "push blocked" "$wt_integ_push_out" "push guard names the custom integration branch even from a worktree"

rc=0; ORCHID_ALLOW_PUSH=1 git -C "$wt4" push origin task/T099 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "ORCHID_ALLOW_PUSH=1 still allows the push when triggered from a task worktree checkout"

# ===========================================================================
# Post-review fix (trivial, re-review): $integ is substituted into a sed
# REPLACEMENT string at install time -- `|` (the delimiter itself), `&`
# (whole-match backreference), and `\` (escape introducer) are all
# syntactically significant there, and `|`/`&` (unlike `\`) are legal
# characters in a real git branch name. An unescaped substitution would
# corrupt the baked-in name for a branch like `weird&name` (sed would
# expand the `&` to the whole match instead of keeping it literal) rather
# than erroring loudly. `integration_branch=weird&name` must bake in
# EXACTLY that literal text.
# ===========================================================================
pg5="$WORK/pushguard-weirdchars"; mkdir -p "$pg5"
(cd "$pg5" && git init -q . && git symbolic-ref HEAD refs/heads/trunk \
  && echo "orchid.config" > .gitignore && git add .gitignore && git commit -q -m "gitignore local config" \
  && echo "integration_branch=weird&name" > orchid.config)
ORCHID_REPO="$pg5" HOME="$WORK/home" "$ORCHID_BIN" init >/dev/null
grep -qx 'integ="weird&name"' "$pg5/.git/hooks/pre-push" \
  || fail "orchid init bakes an integration_branch containing '&' in literally, unescaped by sed's whole-match expansion"

# ===========================================================================
# Final review fix (Minor #9): $integ also lands INSIDE DOUBLE QUOTES in the
# rendered hook (`integ="__INTEGRATION_BRANCH__"`) -- `"`, `$`, and a
# backtick are all legal in a real git refname (unlike `\`, which git itself
# forbids), and any of them left unescaped there becomes LIVE SHELL SYNTAX in
# the installed hook (a broken quote, variable expansion, or a command
# substitution) rather than inert text. `integration_branch=weird"quote$
# dollar`tick`name` must bake in EXACTLY that literal text, escaped for the
# double-quoted shell context, and the installed hook must still be
# syntactically valid shell (proof no stray unescaped quote/backtick broke
# it).
# ===========================================================================
pg6="$WORK/pushguard-shellchars"; mkdir -p "$pg6"
(cd "$pg6" && git init -q . && git symbolic-ref HEAD refs/heads/trunk \
  && echo "orchid.config" > .gitignore && git add .gitignore && git commit -q -m "gitignore local config" \
  && printf 'integration_branch=%s\n' 'weird"quote$dollar`tick`name' > orchid.config)
ORCHID_REPO="$pg6" HOME="$WORK/home" "$ORCHID_BIN" init >/dev/null
grep -Fqx 'integ="weird\"quote\$dollar\`tick\`name"' "$pg6/.git/hooks/pre-push" \
  || fail "orchid init escapes '\"'/'\$'/backtick in the integration branch name for the double-quoted shell context"
bash -n "$pg6/.git/hooks/pre-push" \
  || fail "installed pre-push hook with '\"'/'\$'/backtick in the integration branch name must still be syntactically valid shell"
