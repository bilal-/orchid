#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME/.orchid"
printf 'verify=true\n' > orchid.config
mkdir -p "$WORK/eng/fake"; printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
printf 'role.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' >> orchid.config

out0="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" || fail "doctor passes with resolvable fake engines"
assert_match "integration branch exists or creatable" "$out0" "doctor pre-init: integration branch creatable from HEAD"
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
rc=0; (cd "$scratch2" && ORCHID_REPO="$scratch2" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" init) >/dev/null 2>&1 || rc=$?
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
