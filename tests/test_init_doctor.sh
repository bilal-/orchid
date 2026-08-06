#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"; mkdir -p "$HOME/.orchid"
printf 'verify=true\n' > orchid.config
mkdir -p "$WORK/eng/fake"; printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
printf 'role.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' >> orchid.config

out0="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" || fail "doctor passes with resolvable fake engines"
assert_match "integration branch exists or creatable" "$out0" "doctor pre-init: integration branch creatable from HEAD"
assert_match "WARN: unattended trust \\(headless execution gated\\): denied" "$out0" \
  "doctor reports the default-denied unattended gate without blocking interactive readiness"

trust_out="$("$ORCHID_BIN" trust unattended "$WORK" --reason "doctor test fixture")" \
  || fail "doctor fixture acknowledgement must succeed"
assert_match "reason: doctor test fixture" "$trust_out" \
  "trust acknowledgement records operator provenance"
trusted_doctor="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" \
  || fail "doctor remains healthy after unattended acknowledgement"
assert_match "^ok: unattended trust: allowed" "$trusted_doctor" \
  "doctor reports the allowed gate with machine-local provenance"
echo "$trusted_doctor" | grep -q "scheduled/service invocation" \
  && fail "doctor must not report scheduled refusals when none were recorded"

# A scheduled pump/tick has nowhere to print: the cron line and the launchd
# agent both discard its output, and the repo-local service log is not opened
# until after the gate. Those refusals are recorded machine-locally instead,
# and doctor is where an operator finds them.
doctor_refusal_log="$HOME/.orchid/unattended-trust/refusals.log"
[ -d "$(dirname "$doctor_refusal_log")" ] \
  || fail "the acknowledgement above must have created the machine-local store"
printf '2026-01-01T00:00:00Z\tunattended pump\t%s\tuntrusted\tno machine-local acknowledgement\n' \
  "$WORK" > "$doctor_refusal_log"
refusal_doctor="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" \
  || fail "recorded refusals are a warning, not a doctor failure"
assert_match "WARN: unattended trust denied a scheduled/service invocation" \
  "$refusal_doctor" "doctor surfaces refusals the scheduler discarded"
assert_match "unattended pump" "$refusal_doctor" \
  "doctor shows which surface was refused"
rm -f "$doctor_refusal_log"

# doctor probes jq after restoring the operator PATH, while the unattended
# gate it printed above resolves tools on the fixed PATH the runners pin. The
# two must never disagree silently -- a bare `command -v` here reported `ok
# jq` about a jq no scheduled run could reach. Build the current PATH minus jq
# (a symlink farm, so by construction nothing ELSE goes missing) and check
# that doctor names the surface that is short.
assert_match '^ok: jq$' "$out0" \
  "doctor reports jq ready when the operator and unattended PATHs agree"
nojq_bin="$WORK/doctor-no-jq-bin"
mkdir -p "$nojq_bin"
(
  IFS=:
  for nojq_dir in $PATH; do
    [ -n "$nojq_dir" ] && [ -d "$nojq_dir" ] || continue
    for nojq_exe in "$nojq_dir"/*; do
      [ -f "$nojq_exe" ] && [ -x "$nojq_exe" ] || continue
      nojq_name="${nojq_exe##*/}"
      if [ "$nojq_name" != jq ] && [ ! -e "$nojq_bin/$nojq_name" ]; then
        ln -s "$nojq_exe" "$nojq_bin/$nojq_name"
      fi
    done
  done
)
nojq_doctor="$(ORCHID_ENGINES_DIR="$WORK/eng" PATH="$nojq_bin" "$ORCHID_BIN" doctor 2>&1)" || true
assert_match 'jq missing: jq is reachable on the fixed PATH' "$nojq_doctor" \
  "doctor names the PATH that is short rather than a bare 'jq missing'"
assert_match 'not on the operator PATH' "$nojq_doctor" \
  "doctor says which of the two PATHs cannot reach jq"

mkdir -p .orchid/plugins/engines/evil
out="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" || true
assert_match "repo-local plugins.*trust" "$out" "repo-local plugin note"

# init now refuses a dirty tree, so commit the fixture's config/engine
# scaffolding first (a real user would already have these committed).
git add -A && git commit -q -m "fixture: engines + config"
init_out="$("$ORCHID_BIN" init)"
git rev-parse --verify -q orchid/integration >/dev/null || fail "integration branch"
git show orchid/integration:.orchid/roadmap.md | grep -q "run_status: planning" || fail "roadmap committed with run_status"
assert_match "integration branch: orchid/integration" "$init_out" "init prints the integration branch name"
assert_match "git worktree add \.\./$(basename "$WORK")-orchid orchid/integration && cd \.\./$(basename "$WORK")-orchid" "$init_out" "init prints the exact worktree hint command"
out1="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" || fail "doctor passes post-init"
assert_match "integration branch exists or creatable" "$out1" "doctor post-init: integration branch exists"
rc=0; printf 'role.implementer=missing-engine\n' >> orchid.config
ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "doctor fails on unresolvable role"

# init refuses a dirty tree (regression: silent .gitignore loss).
# Fresh, self-contained scratch repo — $WORK already has orchid/integration
# from the init above, so a dirty-tree run there would fail for the wrong
# reason ("branch exists") rather than the dirty-tree guard.
scratch1="$WORK/scratch1"; mkdir -p "$scratch1"
git init -q "$scratch1"
(cd "$scratch1" && git commit -q --allow-empty -m root)
echo "wip" >> "$scratch1/.gitignore"
rc=0; ORCHID_REPO="$scratch1" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "init must refuse dirty tree"
git -C "$scratch1" rev-parse --verify -q orchid/integration >/dev/null 2>&1 && fail "dirty-tree refusal must not create integration branch"

# commit failure must propagate and restore prior branch (regression: || true false success)
# (simulate by breaking git identity in a scratch clone)
scratch2="$WORK/scratch2"; git init -q "$scratch2"
(cd "$scratch2" && git commit -q --allow-empty -m root && printf 'verify=true\n' > orchid.config && git add -A && git commit -q -m cfg && git config user.email "" && git config user.name "")
rc=0
(
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  cd "$scratch2" && ORCHID_REPO="$scratch2" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init
) >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "init must fail when commit fails"
[ "$(git -C "$scratch2" rev-parse --abbrev-ref HEAD)" != "orchid/integration" ] || fail "prior branch must be restored on failure"
[ -z "$(git -C "$scratch2" status --porcelain)" ] || fail "failed init must leave tree and index clean"
git -C "$scratch2" rev-parse --verify -q orchid/integration >/dev/null && fail "failed init must not leave stray integration branch" || true

# init must not destroy an existing-but-unreadable .gitignore (regression:
# `cat "$repo/.gitignore" 2>/dev/null || true` silently swallowed a
# permission-denied read and replaced the file with just the orchid line).
if [ "$(id -u)" = 0 ]; then
  echo "SKIP: running as root — file permissions are not enforced, unreadable-.gitignore test skipped"
else
  scratch3="$WORK/scratch3"; mkdir -p "$scratch3"
  git init -q "$scratch3"
  echo "precious/" > "$scratch3/.gitignore"
  (cd "$scratch3" && git add .gitignore && git commit -q -m "fixture: gitignore"
   # `git status` treats a chmod-only change (ctime differs from the index's
   # cached stat info) as a real modification even though the content is
   # untouched, which would trip the *unrelated* dirty-tree guard before this
   # test ever reaches the unreadable-.gitignore rewrite path it targets.
   # `--assume-unchanged` tells git to skip that stat comparison entirely.
   git update-index --assume-unchanged .gitignore)
  chmod 000 "$scratch3/.gitignore"
  rc=0; ORCHID_REPO="$scratch3" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init 2>/dev/null || rc=$?
  chmod 644 "$scratch3/.gitignore"
  [ "$rc" -ne 0 ] || fail "init must refuse to touch an unreadable .gitignore"
  grep -q '^precious/$' "$scratch3/.gitignore" || fail "unreadable .gitignore content must survive a failed init"
fi

# ---------------------------------------------------------------------------
# v1-m2 Task 9: doctor --greenfield / init --greenfield (focused unit
# coverage; the full pending->done walk lives in tests/test_greenfield.sh).
# ---------------------------------------------------------------------------

# doctor --greenfield is a modifier, applicable regardless of whether the
# root commit is already landed: on the already-initialized $WORK repo, it
# still skips the verify check with the greenfield note. role.implementer is
# overridden back to the resolvable "fake" engine via env var (highest
# config_get precedence) -- an earlier test above deliberately left
# role.implementer=missing-engine in orchid.config to prove the unresolvable-
# role FAIL case, which is unrelated to what this block is checking.
out_gf="$(ORCHID_ENGINES_DIR="$WORK/eng" ORCHID_ROLE_IMPLEMENTER=fake "$ORCHID_BIN" doctor --greenfield)" || fail "doctor --greenfield passes on an already-initialized repo"
assert_match "greenfield: verify command deferred to scaffold task" "$out_gf" \
  "doctor --greenfield: verify check skipped with the greenfield note"
echo "$out_gf" | grep -q "FAIL: verify command" && fail "doctor --greenfield must never FAIL the verify command check"

# doctor --greenfield rejects an unknown flag.
rc=0; ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "doctor must reject an unknown flag"

# doctor --greenfield on an unborn-HEAD repo: the integration-branch check
# accepts it (creatable once init lands the root commit), and plain doctor
# (no --greenfield) still fails that same check -- the skip is opt-in only.
scratch4="$WORK/scratch4"; mkdir -p "$scratch4"
git init -q "$scratch4"
out_unborn="$(ORCHID_REPO="$scratch4" ORCHID_ENGINES_DIR="$WORK/eng" \
  ORCHID_ROLE_ORCHESTRATOR=fake ORCHID_ROLE_IMPLEMENTER=fake ORCHID_ROLE_REVIEWER=fake \
  ORCHID_ROLE_ARBITER=fake ORCHID_ROLE_PLAN_CRITIC=fake \
  "$ORCHID_BIN" doctor --greenfield)" || fail "doctor --greenfield passes on an unborn-HEAD repo"
assert_match "greenfield: root commit pending" "$out_unborn" \
  "doctor --greenfield: integration-branch check accepts unborn HEAD"

rc=0
ORCHID_REPO="$scratch4" ORCHID_ENGINES_DIR="$WORK/eng" \
  ORCHID_ROLE_ORCHESTRATOR=fake ORCHID_ROLE_IMPLEMENTER=fake ORCHID_ROLE_REVIEWER=fake \
  ORCHID_ROLE_ARBITER=fake ORCHID_ROLE_PLAN_CRITIC=fake \
  "$ORCHID_BIN" doctor >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "plain doctor (no --greenfield) still fails on unborn HEAD's integration-branch check"

# init --greenfield: refused on a dir with stray uncommitted files (never
# adopts a pre-existing pile silently), and never mints a root commit when
# refused.
scratch5="$WORK/scratch5"; mkdir -p "$scratch5"
git init -q "$scratch5"
echo "stray" > "$scratch5/stray.txt"
rc=0; ORCHID_REPO="$scratch5" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init --greenfield 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "init --greenfield must refuse a dir with stray uncommitted files"
git -C "$scratch5" rev-parse -q --verify HEAD >/dev/null 2>&1 && fail "refused init --greenfield must not create a root commit"

# plain init on an unborn-HEAD repo dies with a hint to use --greenfield
# (regression: used to surface a raw `git branch ... HEAD` failure instead).
scratch6="$WORK/scratch6"; mkdir -p "$scratch6"
git init -q "$scratch6"
rc=0; err6="$(ORCHID_REPO="$scratch6" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "plain init on an unborn-HEAD repo must die"
assert_match "greenfield" "$err6" "plain init on unborn HEAD hints at --greenfield"
git -C "$scratch6" rev-parse -q --verify HEAD >/dev/null 2>&1 && fail "plain init must not create a root commit on an unborn-HEAD repo"

# init --greenfield on a genuinely empty dir: mints the root commit, then
# proceeds through the normal init flow.
scratch7="$WORK/scratch7"; mkdir -p "$scratch7"
git init -q "$scratch7"
ORCHID_REPO="$scratch7" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init --greenfield >/dev/null \
  || fail "init --greenfield must succeed on a genuinely empty dir"
git -C "$scratch7" rev-parse -q --verify HEAD >/dev/null 2>&1 || fail "init --greenfield must leave a root commit behind"
assert_eq "orchid: root" "$(git -C "$scratch7" log -1 --format=%s HEAD)" "init --greenfield root commit subject"
git -C "$scratch7" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  || fail "init --greenfield must still create the integration branch"

# On a repo WITH commits already, --greenfield is a no-op modifier: behaves
# exactly like plain init.
scratch8="$WORK/scratch8"; mkdir -p "$scratch8"
git init -q "$scratch8"; (cd "$scratch8" && git commit -q --allow-empty -m root)
ORCHID_REPO="$scratch8" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init --greenfield >/dev/null \
  || fail "init --greenfield on a repo with commits must succeed (no-op modifier)"
git -C "$scratch8" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  || fail "init --greenfield (no-op modifier) still creates the integration branch"
[ "$(git -C "$scratch8" log --oneline HEAD | wc -l | tr -d ' ')" = 1 ] \
  || fail "init --greenfield on a repo with commits must NOT mint an extra root commit"

# ---------------------------------------------------------------------------
# v1-m3 Task 2: split-brain checkout detection (F7) -- `orchid init` restores
# the user's own branch; durable .orchid state lives only on the integration
# branch. A checkout with task-verb-built state (.orchid/tasks/) but no
# roadmap.md is neither "uninitialized" nor a healthy run -- doctor must FAIL
# it by name, distinct from every other check.
# ---------------------------------------------------------------------------
scratch9="$WORK/scratch9"; mkdir -p "$scratch9"
git init -q "$scratch9"
(cd "$scratch9" && git commit -q --allow-empty -m root)
mkdir -p "$scratch9/.orchid/tasks"
rc=0
sb_out="$(ORCHID_REPO="$scratch9" ORCHID_ENGINES_DIR="$WORK/eng" \
  ORCHID_ROLE_ORCHESTRATOR=fake ORCHID_ROLE_IMPLEMENTER=fake ORCHID_ROLE_REVIEWER=fake \
  ORCHID_ROLE_ARBITER=fake ORCHID_ROLE_PLAN_CRITIC=fake \
  "$ORCHID_BIN" doctor 2>&1)" || rc=$?
assert_eq 1 "$rc" "doctor fails on a split-brain checkout (.orchid/tasks without roadmap.md)"
assert_match "FAIL: split-brain checkout: work from the integration branch or a worktree of it — see 'orchid init' output" "$sb_out" \
  "doctor names the split-brain fix"

# healthy fixture (the main $WORK repo, already initialized with a roadmap on
# orchid/integration) must be unaffected by the new check.
echo "$out1" | grep -q "FAIL: split-brain" && fail "doctor must not flag split-brain on a healthy post-init repo"
assert_match "ok: no split-brain checkout state" "$out1" "doctor's split-brain check passes on a healthy post-init repo"

# ---------------------------------------------------------------------------
# v1-m3 final review (CRITICAL 2): stale-integration-checkout detection --
# the live run's 6638-line silent revert. A worktree parked ON the
# integration branch whose ref gets advanced from OUTSIDE it (a raw `git
# update-ref`, never a `checkout`/`commit` made IN this worktree) falls
# behind its own branch pointer -- `git diff --cached --name-status` then
# shows a "D" row per path the new HEAD carries that the (stale) index does
# not. Both `orchid doctor` (FAIL) and `orchid status` (first-line WARNING,
# after any split-brain warning) must catch this; read-only, no mutation.
# ---------------------------------------------------------------------------
stale_bare="$WORK/stale-bare"; mkdir -p "$stale_bare"
(cd "$stale_bare" && git init -q . && git commit -q --allow-empty -m root)
ORCHID_REPO="$stale_bare" "$ORCHID_BIN" init >/dev/null
stale_wt="$WORK/stale-wt"
git -C "$stale_bare" worktree add -q "$stale_wt" orchid/integration

# Healthy checkout, unchanged: a freshly-added worktree of the integration
# branch, before anything advances the ref out from under it.
healthy_doctor_out="$(ORCHID_REPO="$stale_wt" "$ORCHID_BIN" doctor 2>&1)" || true
assert_match "ok: no stale integration checkout state" "$healthy_doctor_out" \
  "doctor: a healthy integration-branch worktree is unaffected"
healthy_status_out="$(ORCHID_REPO="$stale_wt" "$ORCHID_BIN" status)"
echo "$healthy_status_out" | grep -q "integration checkout is stale" \
  && fail "status must not warn stale on a healthy integration-branch worktree"

# Advance the ref from OUTSIDE $stale_wt: a second, DETACHED worktree of the
# same commit (git refuses a second worktree with the branch itself checked
# out) commits normally, then the branch ref is force-moved to that new
# commit via a raw update-ref -- $stale_wt's own index/working tree are never
# touched, reproducing the update-ref-under-a-checkout signature exactly.
stale_wt2="$WORK/stale-wt2"
git -C "$stale_bare" worktree add -q --detach "$stale_wt2" orchid/integration
echo "new file from elsewhere" > "$stale_wt2/elsewhere.txt"
git -C "$stale_wt2" add elsewhere.txt
git -C "$stale_wt2" commit -q -m "advance integration from elsewhere"
stale_new_sha="$(git -C "$stale_wt2" rev-parse HEAD)"
git -C "$stale_bare" update-ref refs/heads/orchid/integration "$stale_new_sha"

rc=0
stale_doctor_out="$(ORCHID_REPO="$stale_wt" "$ORCHID_BIN" doctor 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "doctor must FAIL on a stale integration checkout"
# v1-m4 Task 1: the remedy text is now SCOPED to exclude .orchid/ (a bare
# `git checkout HEAD -- .` would clobber uncommitted run state -- the r-001
# incident's other half); ':(exclude)' contains ERE metacharacters, escaped
# here since assert_match's first arg is an extended regex.
assert_match "FAIL: integration checkout is stale — refresh with \"git checkout HEAD -- \. ':\(exclude\)\.orchid'\" before committing anything here" \
  "$stale_doctor_out" "doctor names the scoped stale-checkout fix"

# v1-m4 Task 5 review: `status`'s split-brain/stale-checkout warnings now go
# to STDERR only (never stdout, in any mode -- see libexec/orchid-status),
# so this capture needs `2>&1` to still see it; unchanged otherwise.
stale_status_out="$(ORCHID_REPO="$stale_wt" "$ORCHID_BIN" status 2>&1)"
assert_match "WARNING: integration checkout is stale — refresh with \"git checkout HEAD -- \. ':\(exclude\)\.orchid'\" before committing anything here" \
  "$stale_status_out" "status warns about the scoped stale-checkout fix"

# ---------------------------------------------------------------------------
# v1-m4 Task 1 (the r-001 journal-loss incident, closed): `orchid config
# commit` -- the safe operator path for repo-config changes. Same stale-
# checkout fixture shape as above (a worktree of the integration branch
# whose ref gets advanced from OUTSIDE it, leaving a "D" row in its index
# relative to the new HEAD), but this time the operator ALSO edits
# orchid.config directly in that stale checkout. The pre-fix hazard: a
# naive `git add -A && git commit` there would both land the config edit
# AND silently re-delete `elsewhere.txt` (the stray staged "D"), reverting
# real history. `config commit` must land ONLY orchid.config, and must
# never touch this checkout's own git index/working tree at all.
# ---------------------------------------------------------------------------
cfg_bare="$WORK/cfg-bare"; mkdir -p "$cfg_bare"
(cd "$cfg_bare" && git init -q . && printf 'verify=true\n' > orchid.config \
  && git add orchid.config && git commit -q -m "fixture: base orchid.config")
ORCHID_REPO="$cfg_bare" "$ORCHID_BIN" init >/dev/null
cfg_wt="$WORK/cfg-wt"
git -C "$cfg_bare" worktree add -q "$cfg_wt" orchid/integration
cfg_epoch="$(ORCHID_REPO="$cfg_wt" HOME="$MACHINE_HOME" "$ORCHID_BIN" run start | sed 's/epoch: //')"

# Advance the ref from OUTSIDE $cfg_wt (same technique as the stale-checkout
# fixture above): $cfg_wt's own index/working tree are never touched by this.
cfg_wt2="$WORK/cfg-wt2"
git -C "$cfg_bare" worktree add -q --detach "$cfg_wt2" orchid/integration
echo "new file from elsewhere" > "$cfg_wt2/elsewhere.txt"
git -C "$cfg_wt2" add elsewhere.txt
git -C "$cfg_wt2" commit -q -m "advance integration from elsewhere"
cfg_new_sha="$(git -C "$cfg_wt2" rev-parse HEAD)"
git -C "$cfg_bare" update-ref refs/heads/orchid/integration "$cfg_new_sha"

# $cfg_wt is now a genuinely STALE, DIRTY checkout: its index still shows the
# "D elsewhere.txt" signature relative to the new HEAD, AND the operator now
# edits orchid.config directly on top of that (uncommitted).
[ -n "$(git -C "$cfg_wt" diff --cached --name-status | grep '^D')" ] \
  || fail "config-commit fixture setup: $cfg_wt must show the stale-checkout D-row signature"
printf 'role.implementer=fake\n' >> "$cfg_wt/orchid.config"
# The RAW index content (`ls-files --stage`, independent of whatever HEAD
# happens to be) is the right thing to snapshot here -- `git status`/`diff
# --cached` are relative to HEAD, and HEAD itself is about to move forward
# (config commit's own CAS-advance of the SAME branch $cfg_wt sits on) --
# that alone would make new diffs appear against the now-newer HEAD even if
# $cfg_wt's own index/working tree are never touched, which is the actual
# property under test.
pre_cfg_wt_index="$(git -C "$cfg_wt" ls-files --stage)"
pre_cfg_wt_config="$(cat "$cfg_wt/orchid.config")"
pre_cfg_journal="$(cat "$cfg_wt/.orchid/journal.md")"

cfg_commit_out="$(ORCHID_REPO="$cfg_wt" ORCHID_EPOCH="$cfg_epoch" HOME="$MACHINE_HOME" "$ORCHID_BIN" config commit --reason "add implementer role binding")"
assert_match "^committed: " "$cfg_commit_out" "config commit prints the new commit sha"

# The edited config landed on the integration branch...
git -C "$cfg_bare" show orchid/integration:orchid.config | grep -q "^role.implementer=fake$" \
  || fail "config commit lands the edited orchid.config on the integration branch"
# ...and EXACTLY orchid.config -- the stray staged deletion never rode along:
# elsewhere.txt must still exist at the new HEAD, untouched.
git -C "$cfg_bare" show orchid/integration:elsewhere.txt >/dev/null 2>&1 \
  || fail "config commit must not resurrect the stale-checkout D-row deletion (elsewhere.txt missing)"
assert_eq "orchid: config commit (add implementer role binding)" \
  "$(git -C "$cfg_bare" log -1 --format=%s orchid/integration)" \
  "config commit's own commit message"

# $cfg_wt's own git INDEX is completely untouched (raw stage content,
# independent of HEAD, which config commit's own CAS-advance legitimately
# moves forward out from under it -- see the comment above the "before"
# snapshot).
assert_eq "$pre_cfg_wt_index" "$(git -C "$cfg_wt" ls-files --stage)" \
  "config commit must not touch the operator's own git index"
# ...and its own working tree: the operator's own uncommitted orchid.config
# edit is exactly as it was (byte-identical, even though the file itself
# was rewritten via sync-back -- same content that was read from it).
assert_eq "$pre_cfg_wt_config" "$(cat "$cfg_wt/orchid.config")" \
  "config commit must leave the operator's own working-tree orchid.config untouched"

# Journaled as `intervention`, locally (not part of THIS commit -- rides
# into the integration branch on the next .orchid-committing verb).
grep -q "intervention" "$cfg_wt/.orchid/journal.md" || fail "config commit journals kind intervention"
grep -q "add implementer role binding" "$cfg_wt/.orchid/journal.md" || fail "config commit journal entry carries the reason"
[ "$(cat "$cfg_wt/.orchid/journal.md")" != "$pre_cfg_journal" ] || fail "config commit must journal locally"

# --reason is required (INV-08); refused before anything is touched.
rc=0
ORCHID_REPO="$cfg_wt" ORCHID_EPOCH="$cfg_epoch" HOME="$MACHINE_HOME" "$ORCHID_BIN" config commit >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "config commit without --reason must be refused"

# `config list` remains read-only/unaffected by the new subverb.
ORCHID_REPO="$cfg_wt" "$ORCHID_BIN" config list >/dev/null || fail "config list still works"

# ---------------------------------------------------------------------------
# v1-m4 T006: doctor's NOTIFY RETURN LEG check. Doctor used to validate the
# notify plugin and its binary -- outbound send capability -- and stop there,
# so an operator could wire a channel, watch blockers arrive on their phone,
# answer them, and have every answer go nowhere (which is exactly what
# happened: a gateway was down all day and a phone answer was lost with no
# local trace). The check below reports outbound and inbound as SEPARATE
# facts, never claims inbound liveness it cannot prove, and stays advisory.
# ---------------------------------------------------------------------------
nfy="$WORK/notify-repo"; mkdir -p "$nfy"
(cd "$nfy" && git init -q . && git commit -q --allow-empty -m root)
printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' \
  > "$nfy/orchid.config"
# A fixture notify plugin whose required binary (git) is certainly present,
# so the outbound branch is deterministic on any machine. Created up front so
# every run below sees the same ORCHID_PLUGIN_PATH surface.
mkdir -p "$WORK/notify-plugins/notify/fixchan"
printf 'manifest_version=1\nid=orchid-test/fixchan\nversion=0.1.0\nkind=notify\napi_version=1\nrequires_orchid=>=1.0\nentrypoint=send\nrequires_binaries=git\n' \
  > "$WORK/notify-plugins/notify/fixchan/plugin.conf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/notify-plugins/notify/fixchan/send"
chmod +x "$WORK/notify-plugins/notify/fixchan/send"

nfy_doctor() {  # -> combined output in $nfy_out, exit code in $nfy_rc
  nfy_rc=0
  nfy_out="$(ORCHID_REPO="$nfy" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng" \
    ORCHID_PLUGIN_PATH="$WORK/notify-plugins" "$ORCHID_BIN" doctor 2>&1)" || nfy_rc=$?
}

# 1. No channel configured at all -- a completely legitimate setup. Green,
#    and explicit that nothing is expected to answer.
nfy_doctor
assert_eq "0" "$nfy_rc" "no notify channel configured must keep doctor green"
assert_match "^ok: notify return leg: no notify channel configured" "$nfy_out" \
  "doctor states plainly when there is no channel and nothing to receive a reply"

# 2. Channel configured and sendable. Outbound is `ok` -- inbound is NOT, and
#    the two must never be conflated.
printf 'notify.plugin=fixchan\nnotify.channel=telegram\n' >> "$nfy/orchid.config"
nfy_doctor
assert_eq "0" "$nfy_rc" "the notify return-leg check is advisory: it must never fail doctor"
assert_match "^ok: notify outbound: 'fixchan' resolves and its required binaries are present" "$nfy_out" \
  "doctor confirms send capability when the plugin and its binaries resolve"
assert_match "SEND capability only" "$nfy_out" \
  "doctor labels the outbound fact as send capability alone"
assert_match "^WARN: notify inbound \\(the return leg\\): NOT VERIFIED" "$nfy_out" \
  "doctor reports the inbound leg as unverified rather than implying it from outbound"
assert_match "orchid runs no inbound listener" "$nfy_out" \
  "doctor says WHY inbound cannot be proven, instead of reporting ok"
# Herestring, never `echo | grep -q`: same SIGPIPE/pipefail trap helpers.sh
# documents for assert_match — a matching grep exiting early would poison the
# pipeline status and silently skip this `fail`.
grep -q "^ok: notify inbound" <<<"$nfy_out" \
  && fail "doctor must never report the inbound return leg as ok -- it cannot prove a listener exists"
assert_match "no blocker has been raised in this repo yet" "$nfy_out" \
  "with no questions on record doctor says there is no local evidence either way"
assert_match "answer_allowlist is unset" "$nfy_out" \
  "a configured channel with no declared answering identity is called out"

# 3. Local evidence: a raised blocker with no answer beside it is the exact
#    signature of a broken return leg, and doctor must surface it.
mkdir -p "$nfy/.orchid/runtime/answers"
printf 'task: T001\nnonce: deadbeefdeadbeef\nwhich way?\n' > "$nfy/.orchid/runtime/answers/q-1-aaaa.question"
nfy_doctor
assert_eq "0" "$nfy_rc" "an unanswered blocker is a warning, never a doctor failure"
assert_match "WARN: notify inbound: 1 blocker\\(s\\)" "$nfy_out" \
  "doctor counts blockers that were raised and never answered"
assert_match "nothing delivered that answer back here" "$nfy_out" \
  "doctor names the lost-answer failure mode the operator actually hit"

# 4. Once answered, the count clears -- and the note stays honest about what
#    an .answer file does and does not prove.
printf 'yes\n' > "$nfy/.orchid/runtime/answers/q-1-aaaa.answer"
nfy_doctor
assert_eq "0" "$nfy_rc" "answered blockers keep doctor green"
assert_match "note: notify inbound: all 1 blocker\\(s\\) on record have an answer" "$nfy_out" \
  "doctor clears the unanswered warning once an answer is recorded"
assert_match "does not distinguish a channel delivery from an operator typing" "$nfy_out" \
  "doctor does not read a local answer as proof the channel delivered it"

# 5. A configured channel whose plugin does not resolve: outbound is broken
#    and said so, still advisory.
sed 's/^notify.plugin=fixchan$/notify.plugin=nosuchchan/' "$nfy/orchid.config" > "$nfy/orchid.config.tmp"
mv "$nfy/orchid.config.tmp" "$nfy/orchid.config"
nfy_doctor
assert_eq "0" "$nfy_rc" "an unresolvable notify plugin is a warning, never a doctor failure"
assert_match "WARN: notify outbound: notify.plugin 'nosuchchan' does not resolve" "$nfy_out" \
  "doctor names an unresolvable notify plugin"
