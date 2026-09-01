#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"; mkdir -p "$HOME/.orchid"
printf 'verify=true\n' > orchid.config
mkdir -p "$WORK/eng/fake"; printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
printf 'role.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' >> orchid.config

out0="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" || fail "doctor passes with resolvable fake engines"
assert_match "integration branch exists or creatable" "$out0" "doctor pre-init: integration branch creatable from HEAD"
assert_match "WARN: unattended trust \\(headless execution gated\\): denied" "$out0" \
  "doctor reports the default-denied unattended gate without blocking interactive readiness"

# T027 (dogfood F29): the RESOLVED pack budget, with the layer it came from.
# A pack over this budget fails the LAUNCH before any engine starts, and the
# layer is where operators go wrong: a run failed every launch on the default
# 65536 while its operator believed the 131072 they had set -- in the orchid
# installation's own orchid.config, which is not a layer for the repo being
# driven at all.
assert_match "note: pack budget: pack_budget_bytes=65536 \\(from: default\\)" "$out0" \
  "doctor prints the resolved pack budget and that it came from the built-in default"
printf 'pack_budget_bytes=131072\n' >> orchid.config
budget_doctor="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" \
  || fail "doctor still passes with a repo-set pack budget"
assert_match "note: pack budget: pack_budget_bytes=131072 \\(from: repo\\)" "$budget_doctor" \
  "and follows the value to the layer that actually won it"
assert_match "is NOT part of that chain" "$budget_doctor" \
  "naming the file that is not a layer, since that is the mistake it exists to catch"
# ...but only when it really is not a layer. Driving orchid's OWN repository
# makes $ORCHID_ROOT/orchid.config the repo layer, and doctor claiming it is
# never consulted would be false in exactly the situation orchid is in whenever
# it dogfoods itself.
self_doctor="$(ORCHID_REPO="$REPO_ROOT" ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor 2>&1 || true)"
assert_match "This target IS the orchid installation" "$self_doctor" \
  "driving orchid itself, doctor says the installation's own orchid.config IS the repo layer"
# Herestring, never `echo | grep -q`: same SIGPIPE/pipefail trap helpers.sh
# documents for assert_match — a matching grep exiting early would poison the
# pipeline status and silently skip this `fail`.
grep -q "is NOT part of that chain" <<<"$self_doctor" \
  && fail "doctor must not tell a self-driving run that its own orchid.config is not a layer — it is"

trust_out="$("$ORCHID_BIN" trust unattended "$WORK" --reason "doctor test fixture")" \
  || fail "doctor fixture acknowledgement must succeed"
assert_match "reason: doctor test fixture" "$trust_out" \
  "trust acknowledgement records operator provenance"
trusted_doctor="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" \
  || fail "doctor remains healthy after unattended acknowledgement"
assert_match "^ok: unattended trust: allowed" "$trusted_doctor" \
  "doctor reports the allowed gate with machine-local provenance"
grep -q "scheduled/service invocation" <<<"$trusted_doctor" \
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
grep -q "run_status: planning" <<<"$(git show orchid/integration:.orchid/roadmap.md)" || fail "roadmap committed with run_status"
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
grep -q "FAIL: verify command" <<<"$out_gf" && fail "doctor --greenfield must never FAIL the verify command check"

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
grep -q "FAIL: split-brain" <<<"$out1" && fail "doctor must not flag split-brain on a healthy post-init repo"
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
# T029: a HERESTRING, never `echo | grep -q` (the trap helpers.sh documents for
# assert_match, and this file already spells out at its own line 36). It is
# load-bearing HERE in a way it was not before: this is the only arm proving
# the stale warning is CONDITIONAL, and the text it looks for just grew from
# one line to four (orchid_stale_checkout_remedy). A piped `grep -q` exits at
# its first match and SIGPIPEs the `echo`, which pipefail promotes to a nonzero
# pipeline status -- so the `fail` is skipped exactly when the pattern IS
# present, i.e. exactly when a regression made `status` warn unconditionally.
grep -q "integration checkout is stale" <<<"$healthy_status_out" \
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
# incident's other half).
#
# T029 (dogfood finding F31): that scoped checkout is only HALF the remedy --
# it cannot clear this check by itself, because the index entries it clears
# are the ones its own pathspec excludes. Both verbs now print the two-command
# recovery from lib/common.sh's orchid_stale_checkout_remedy, and the Part
# below RUNS each half against a real stale checkout rather than trusting the
# text. `grep -F` here, not assert_match: the line is quotes, parentheses,
# dots and `&&` almost end to end, and an ERE that escapes all of that is a
# defect waiting to pass on a pattern nobody can read.
stale_remedy_line="integration checkout is stale — refresh with \"git checkout HEAD -- . ':(exclude).orchid' && git reset\" before committing anything here"
grep -qF "FAIL: $stale_remedy_line" <<<"$stale_doctor_out" \
  || fail "doctor names the two-command stale-checkout fix (no match '$stale_remedy_line')"
grep -qF 'the bare "git reset" is what CLEARS this warning' <<<"$stale_doctor_out" \
  || fail "doctor says which half of the remedy actually clears the warning"
grep -qF 'requirements.md being revised at the repository root' <<<"$stale_doctor_out" \
  || fail "doctor warns that the checkout half overwrites uncommitted work outside .orchid/"

# v1-m4 Task 5 review: `status`'s split-brain/stale-checkout warnings now go
# to STDERR only (never stdout, in any mode -- see libexec/orchid-status),
# so this capture needs `2>&1` to still see it; unchanged otherwise.
stale_status_out="$(ORCHID_REPO="$stale_wt" "$ORCHID_BIN" status 2>&1)"
grep -qF "WARNING: $stale_remedy_line" <<<"$stale_status_out" \
  || fail "status warns with the two-command stale-checkout fix (no match '$stale_remedy_line')"
# The two verbs print ONE text: they drifted from correct together once (F31),
# and a copy each is how that happened.
grep -qF 'requirements.md being revised at the repository root' <<<"$stale_status_out" \
  || fail "status carries the same recovery text doctor does, from the same source"

# ---------------------------------------------------------------------------
# T029 (dogfood finding F31): THE PRINTED REMEDY IS RUN, not read. An operator
# followed the old one-command recovery character for character and watched
# this warning survive it -- so the claim under test here is not "the text
# mentions the right commands" but "each half does what the text says it does,
# against a checkout that is actually stale".
#
# The fixture above is not enough for that, and the difference is the whole
# finding: its advancing commit adds `elsewhere.txt` and nothing else, so the
# scoped checkout clears it and the defect never appears. A REAL merge commit
# carries new durable run state under `.orchid/` as well as code -- that is
# what `orchid merge` commits -- and those are exactly the index entries the
# `:(exclude).orchid` pathspec is not allowed to touch. So this fixture's
# advance carries both.
# ---------------------------------------------------------------------------
rem_bare="$WORK/remedy-bare"; mkdir -p "$rem_bare"
(cd "$rem_bare" && git init -q . && git commit -q --allow-empty -m root)
ORCHID_REPO="$rem_bare" "$ORCHID_BIN" init >/dev/null
rem_wt="$WORK/remedy-wt"
git -C "$rem_bare" worktree add -q "$rem_wt" orchid/integration
# An operator document at the repository root, committed FROM this checkout,
# so nothing is stale yet. requirements.md is the specific file F31's operator
# lost: it is edited uncommitted for long stretches while a run is driven.
printf 'v1: the committed requirements\n' > "$rem_wt/requirements.md"
git -C "$rem_wt" add requirements.md
git -C "$rem_wt" commit -q -m "fixture: requirements.md at the repository root"

# Advance the branch from OUTSIDE $rem_wt (same update-ref technique as above),
# with a commit shaped like a merge: one code path, one new `.orchid/` path.
rem_wt2="$WORK/remedy-wt2"
git -C "$rem_bare" worktree add -q --detach "$rem_wt2" orchid/integration
mkdir -p "$rem_wt2/.orchid/runs/r-001"
echo "the merged code" > "$rem_wt2/kernel.sh"
echo "merged run state" > "$rem_wt2/.orchid/runs/r-001/from-elsewhere.md"
git -C "$rem_wt2" add -A
git -C "$rem_wt2" commit -q -m "advance integration from elsewhere (code + run state)"
git -C "$rem_bare" update-ref refs/heads/orchid/integration "$(git -C "$rem_wt2" rev-parse HEAD)"

# The operator's own state in the stale checkout: an uncommitted edit at the
# repository root (outside .orchid/, so NOT protected by the pathspec) and
# live uncommitted run state (inside .orchid/, so protected).
printf 'v2: the edit in progress\n' > "$rem_wt/requirements.md"
printf 'live run state\n' > "$rem_wt/.orchid/live-state.md"
[ -n "$(git -C "$rem_wt" diff --cached --name-status | grep '^D')" ] \
  || fail "remedy fixture setup: $rem_wt must show the stale-checkout D-row signature"
grep -qE '^D[[:space:]]+\.orchid/' <<<"$(git -C "$rem_wt" diff --cached --name-status)" \
  || fail "remedy fixture setup: the advance must leave a staged deletion UNDER .orchid/, or this Part tests nothing"

# RED -- the half the old text printed, alone. It restores the code, and it
# leaves the warning exactly where it was, because the staged deletions it did
# not clear are under the one prefix its pathspec excludes.
git -C "$rem_wt" checkout HEAD -- . ':(exclude).orchid'
rc=0; rem_half_out="$(ORCHID_REPO="$rem_wt" "$ORCHID_BIN" doctor 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "doctor must still FAIL after the scoped checkout alone (F31)"
assert_match "FAIL: integration checkout is stale" "$rem_half_out" \
  "the scoped checkout ALONE does not clear the stale-checkout warning — this is dogfood finding F31"
assert_eq "the merged code" "$(cat "$rem_wt/kernel.sh")" \
  "the scoped checkout does refresh the code half (that is why it is still the first command)"
# ...and it overwrote the operator's uncommitted root file. The remedy text
# warns about exactly this; the warning is true, and it is pinned here so it
# cannot be quietly dropped as scaremongering.
assert_eq "v1: the committed requirements" "$(cat "$rem_wt/requirements.md")" \
  "the scoped checkout overwrites an uncommitted edit outside .orchid/ (the second half of F31)"
assert_eq "live run state" "$(cat "$rem_wt/.orchid/live-state.md")" \
  "...while uncommitted run state under .orchid/ is protected by the pathspec, as documented"

# GREEN -- the second command the remedy now names. It clears the warning, and
# it writes nothing: the live run state on disk is byte-identical afterwards.
git -C "$rem_wt" reset -q
rem_full_out="$(ORCHID_REPO="$rem_wt" "$ORCHID_BIN" doctor 2>&1)" || true
assert_match "ok: no stale integration checkout state" "$rem_full_out" \
  "the bare 'git reset' clears the stale-checkout warning the scoped checkout could not"
assert_eq "live run state" "$(cat "$rem_wt/.orchid/live-state.md")" \
  "a mixed 'git reset' writes no file — uncommitted run state survives it untouched"
assert_eq "the merged code" "$(cat "$rem_wt/kernel.sh")" \
  "...and it does not undo the refresh the checkout just made"
rem_status_out="$(ORCHID_REPO="$rem_wt" "$ORCHID_BIN" status 2>&1)"
grep -q "integration checkout is stale" <<<"$rem_status_out" \
  && fail "status must not go on warning stale once the printed remedy has been run in full"

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
grep -q "^role.implementer=fake$" <<<"$(git -C "$cfg_bare" show orchid/integration:orchid.config)" \
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
# every run below sees the same ORCHID_PLUGIN_PATH surface. `mk_fixchan
# <requires_config> <inbound_probe> <probe-exit> [probe-stdout]` rewrites it:
# the two manifest keys T006 added are per-plugin declarations, so every
# branch below has to be reachable from a manifest, not from a doctor flag.
mk_fixchan() {
  local req_cfg="$1" probe_key="$2" probe_exit="$3" probe_out="${4:-fixture probe detail}"
  mkdir -p "$WORK/notify-plugins/notify/fixchan"
  {
    printf 'manifest_version=1\nid=orchid-test/fixchan\nversion=0.1.0\nkind=notify\napi_version=1\nrequires_orchid=>=1.0\nentrypoint=send\nrequires_binaries=git\n'
    [ -z "$req_cfg" ] || printf 'requires_config=%s\n' "$req_cfg"
    [ -z "$probe_key" ] || printf 'inbound_probe=%s\n' "$probe_key"
  } > "$WORK/notify-plugins/notify/fixchan/plugin.conf"
  # The probe branch asserts the channel actually reached it, so a doctor
  # that forgot to export ORCHID_NOTIFY_CHANNEL can't pass by accident.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "%s" ]; then\n' "${probe_key:-__none__}"
    printf '  [ -n "${ORCHID_NOTIFY_CHANNEL:-}" ] || { echo "no channel in env"; exit 3; }\n'
    printf '  echo "%s (channel=$ORCHID_NOTIFY_CHANNEL)"\n' "$probe_out"
    printf '  exit %s\n' "$probe_exit"
    printf 'fi\nexit 0\n'
  } > "$WORK/notify-plugins/notify/fixchan/send"
  chmod +x "$WORK/notify-plugins/notify/fixchan/send"
}
mk_fixchan "" "" 0

nfy_doctor() {  # -> combined output in $nfy_out, exit code in $nfy_rc
  nfy_rc=0
  nfy_out="$(ORCHID_REPO="$nfy" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng" \
    ORCHID_PLUGIN_PATH="$WORK/notify-plugins" "$ORCHID_BIN" doctor 2>&1)" || nfy_rc=$?
}
# "advisory" is the invariant these cases are really about: doctor may say
# anything it likes about notify, but never as a FAIL. `$nfy_rc` is the wrong
# way to assert that -- it is doctor's GLOBAL verdict over every check in the
# file, so it couples each case to whatever ELSE this fixture happens to trip.
# It does trip things: case 10 below creates .orchid/tasks/ with no
# roadmap.md beside it, which is the pre-existing split-brain FAIL
# (lib/common.sh's orchid_split_brain), and from there on rc is 1 for a
# reason that has nothing to do with notify. Assert the invariant directly
# instead, on the lines that carry it. Herestring, never `echo | grep -q`:
# same SIGPIPE/pipefail trap helpers.sh documents for assert_match.
assert_notify_advisory() {  # <what this case claims>
  local hits; hits="$(grep -E '^FAIL:.*(notify|return leg)' <<<"$nfy_out" || true)"
  [ -z "$hits" ] || fail "$1 (doctor failed on a notify verdict: $hits)"
}

# 1. No channel configured at all -- a completely legitimate setup. Green,
#    and explicit that nothing is expected to answer.
nfy_doctor
# The one global-rc assertion in this block, and only here: at this point
# nothing has been built up in the fixture yet, so it pins the PRECONDITION
# that this repo starts doctor-clean -- which is what makes every warning
# the cases below assert attributable to the notify config they change.
assert_eq "0" "$nfy_rc" "the notify fixture must start doctor-clean"
assert_match "^ok: notify return leg: no notify channel configured" "$nfy_out" \
  "doctor states plainly when there is no channel and nothing to receive a reply"

# 2. Channel configured and sendable, plugin declaring NO probe. Outbound is
#    `ok`; inbound is not, and the wording must blame this PLUGIN's lack of a
#    probe rather than assert that liveness is unknowable in general.
printf 'notify.plugin=fixchan\nnotify.channel=telegram\n' >> "$nfy/orchid.config"
nfy_doctor
assert_notify_advisory "the notify return-leg check is advisory: it must never fail doctor"
assert_match "^ok: notify outbound: 'fixchan' resolves, its required binaries are present" "$nfy_out" \
  "doctor confirms send capability when the plugin, its binaries and its declared config resolve"
assert_match "SEND capability only" "$nfy_out" \
  "doctor labels the outbound fact as send capability alone"
assert_match "^WARN: notify inbound \\(the return leg\\): NOT VERIFIED" "$nfy_out" \
  "doctor reports the inbound leg as unverified rather than implying it from outbound"
assert_match "'fixchan' declares no inbound probe" "$nfy_out" \
  "doctor blames the specific plugin's missing probe, not 'nothing can ever be known'"
# Herestring, never `echo | grep -q`: same SIGPIPE/pipefail trap helpers.sh
# documents for assert_match — a matching grep exiting early would poison the
# pipeline status and silently skip this `fail`.
grep -q "^ok: notify inbound" <<<"$nfy_out" \
  && fail "with no probe declared, doctor must never report the inbound return leg as ok"
assert_match "no blocker has been raised in this repo yet" "$nfy_out" \
  "with no questions on record doctor says there is no local evidence either way"
assert_match "answer_allowlist is unset" "$nfy_out" \
  "a configured channel with no declared answering identity is called out"

# 3. THE PROBE ITSELF -- the whole point of this check. A plugin that CAN
#    determine liveness declares an `inbound_probe=` mode, doctor runs it,
#    and reports what the plugin determined. Exit 1 (down) is the gateway
#    outage that motivated the task: it must read as NOT REACHABLE, on a
#    healthy-looking machine where every local file says nothing is wrong.
mk_fixchan "" "--probe" 1 "gateway is not answering"
nfy_doctor
assert_notify_advisory "a dead return leg is a warning, never a doctor failure"
assert_match "WARN: notify inbound \\(the return leg\\): 'fixchan' probed its channel and reports it NOT REACHABLE" "$nfy_out" \
  "doctor reports a probe's negative verdict instead of staying silent about it"
assert_match "gateway is not answering \\(channel=telegram\\)" "$nfy_out" \
  "doctor prints the probe's own detail, and the probe really did see notify.channel"
assert_match "Answers sent on this channel are being lost" "$nfy_out" \
  "doctor names the consequence an operator has to act on"

#    Exit 0 (up) is the ONLY path to an inbound `ok` -- and even then the line
#    must bound what it proves: transport, not a channel-side agent.
mk_fixchan "" "--probe" 0 "channel connected"
nfy_doctor
assert_notify_advisory "a reachable return leg is reported, never as a failure"
assert_match "^ok: notify inbound \\(the return leg\\): 'fixchan' probed its channel and reports it REACHABLE" "$nfy_out" \
  "a positive probe is what earns an inbound ok"
assert_match "does NOT prove a channel-side agent" "$nfy_out" \
  "even a reachable transport must not be reported as a working answer path"

#    Exit 2 (cannot tell) must never round up to ok.
mk_fixchan "" "--probe" 2 "status output not recognized"
nfy_doctor
assert_match "WARN: notify inbound \\(the return leg\\): UNDETERMINED" "$nfy_out" \
  "a probe that cannot tell is reported as unknown"
assert_match "Reported as unknown rather than ok, deliberately" "$nfy_out" \
  "doctor says it is deliberately declining to call an unknown result ok"
grep -q "^ok: notify inbound" <<<"$nfy_out" \
  && fail "an undetermined probe must never produce an inbound ok"

# 4. requires_config: the plugin declares config its entrypoint cannot run
#    without. Unset -> outbound must NOT be ok, because every queued blocker
#    would fail, retry to send_retry_max and quarantine while doctor showed
#    green (the shipped openclaw send does exactly `to=${ORCHID_NOTIFY_TO:?}`).
mk_fixchan "notify.channel,notify.to" "--probe" 0
nfy_doctor
assert_notify_advisory "missing notify config is a warning, never a doctor failure"
assert_match "WARN: notify outbound: 'fixchan' declares config it cannot send without, and it is unset: notify.to" "$nfy_out" \
  "doctor checks the config THIS plugin declares, and names the missing key"
assert_match "retry to send_retry_max and quarantine" "$nfy_out" \
  "doctor states what actually happens to queued blockers when that key is unset"
grep -q "^ok: notify outbound" <<<"$nfy_out" \
  && fail "outbound must not report ok while config the plugin requires is unset"
#    Set it and outbound goes green again -- the check is a real gate, not a
#    permanent warning.
printf 'notify.to=+15550000000\n' >> "$nfy/orchid.config"
nfy_doctor
assert_match "^ok: notify outbound: 'fixchan' resolves, its required binaries are present, and the config it declares is set" "$nfy_out" \
  "setting the declared key clears the outbound warning"

# 5. Missing required BINARY, and a non-executable entrypoint: both are
#    outbound failures with their own wording, and neither may be reported as
#    an inbound verdict.
mk_fixchan "" "--probe" 0
printf 'manifest_version=1\nid=orchid-test/fixchan\nversion=0.1.0\nkind=notify\napi_version=1\nrequires_orchid=>=1.0\nentrypoint=send\nrequires_binaries=orchid-no-such-binary-t006\ninbound_probe=--probe\n' \
  > "$WORK/notify-plugins/notify/fixchan/plugin.conf"
nfy_doctor
assert_notify_advisory "a missing notify binary is a warning, never a doctor failure"
assert_match "WARN: notify outbound: 'fixchan' resolves .* but required binaries are missing from PATH: orchid-no-such-binary-t006" "$nfy_out" \
  "doctor names the missing binary rather than reporting outbound ok"
grep -q "^ok: notify outbound" <<<"$nfy_out" \
  && fail "outbound must not report ok while a required binary is missing"

mk_fixchan "" "--probe" 0
chmod -x "$WORK/notify-plugins/notify/fixchan/send"
nfy_doctor
# Doctor DOES fail here, and NOT because of this block: a non-executable
# entrypoint is a malformed manifest, which `plugins validate --all` already
# fails doctor on (lib/manifest.sh). Assert that specific FAIL line rather
# than `$nfy_rc`, for the same reason the advisory helper above exists — the
# claim is about which check failed, not about doctor's global verdict. What
# the return-leg lines add is the actionable half — which plugin, which file,
# and what it means for sends and for the probe.
assert_match "^FAIL: plugin manifests: validate failed" "$nfy_out" \
  "a non-executable entrypoint fails doctor via manifest validation, as it always has"
assert_notify_advisory "and it fails as a manifest verdict, never as a notify one"
assert_match "WARN: notify outbound: 'fixchan' resolves .* but its entrypoint 'send' is not executable" "$nfy_out" \
  "doctor names a non-executable entrypoint"
assert_match "chmod \\+x" "$nfy_out" \
  "doctor prints the one command that fixes a non-executable entrypoint"
assert_match "WARN: notify inbound \\(the return leg\\): NOT PROBED" "$nfy_out" \
  "an unrunnable entrypoint means the probe was not run — not that it failed"
mk_fixchan "" "--probe" 0   # restore an executable, probing plugin

# 6. INV-10: the same notify plugin name under two roots. resolve_notify_dir
#    explains that on stderr; doctor used to discard it and report the plugin
#    simply "not found", sending an operator hunting for something that is in
#    fact installed twice.
mkdir -p "$WORK/notify-plugins-2/notify/fixchan"
cp "$WORK/notify-plugins/notify/fixchan/plugin.conf" "$WORK/notify-plugins-2/notify/fixchan/plugin.conf"
cp "$WORK/notify-plugins/notify/fixchan/send" "$WORK/notify-plugins-2/notify/fixchan/send"
nfy_dup_rc=0
nfy_dup_out="$(ORCHID_REPO="$nfy" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng" \
  ORCHID_PLUGIN_PATH="$WORK/notify-plugins:$WORK/notify-plugins-2" "$ORCHID_BIN" doctor 2>&1)" || nfy_dup_rc=$?
assert_match "WARN: notify outbound: notify.plugin 'fixchan' is not usable" "$nfy_dup_out" \
  "a duplicate notify plugin is reported as unusable, not as missing"
assert_match "duplicate notify plugin 'fixchan'" "$nfy_dup_out" \
  "doctor surfaces resolve_notify_dir's own INV-10 explanation instead of discarding it"
# ...and the notify WARN above is only HALF the verdict. A duplicate id is an
# INV-10 collision, which orchid-doctor's plugin-discovery check calls "a
# doctor FAIL, not a warning" in its own words -- so this is the one notify
# case where the advisory invariant does NOT apply, and asserting only the
# WARN wording would let a notify duplicate silently degrade to warn-only.
# `$nfy_dup_rc` is safe to assert here where it is not elsewhere: the fixture
# was pinned doctor-clean in case 1 and cases 2-5 each restored what they
# changed, so this run's failure is attributable to the duplicate. Both
# halves, since rc alone would not say WHICH check failed: test_plugins_list
# covers collision-FAIL for engine plugins; what is covered here is that a
# kind=notify duplicate reaches the same discovery check at all.
[ "$nfy_dup_rc" -ne 0 ] || fail "an INV-10 duplicate notify plugin must FAIL doctor, not merely warn"
assert_match "^FAIL: plugin discovery: collision" "$nfy_dup_out" \
  "a duplicate notify plugin fails doctor via the plugin-discovery collision check"
rm -rf "$WORK/notify-plugins-2"

# 7. Local evidence: a raised blocker with no answer beside it is the exact
#    signature of a broken return leg, and doctor must surface it.
mkdir -p "$nfy/.orchid/runtime/answers"
printf 'task: T001\nnonce: deadbeefdeadbeef\nwhich way?\n' > "$nfy/.orchid/runtime/answers/q-1-aaaa.question"
nfy_doctor
assert_notify_advisory "an unanswered blocker is a warning, never a doctor failure"
assert_match "WARN: notify inbound: 1 blocker\\(s\\)" "$nfy_out" \
  "doctor counts blockers that were raised and never answered"
assert_match "nothing delivered that answer back here" "$nfy_out" \
  "doctor names the lost-answer failure mode the operator actually hit"

# 8. Once answered, the count clears -- and the note stays honest about what
#    an .answer file does and does not prove.
printf 'yes\n' > "$nfy/.orchid/runtime/answers/q-1-aaaa.answer"
nfy_doctor
assert_notify_advisory "an answered blocker is reported, never as a doctor failure"
assert_match "note: notify inbound: no question is currently unanswered and still answerable; 1 of 1 on record have an .answer" "$nfy_out" \
  "doctor clears the unanswered warning once an answer is recorded"
assert_match "does not distinguish a channel delivery from an operator typing" "$nfy_out" \
  "doctor does not read a local answer as proof the channel delivered it"
# The all-clear must stay an ABSENCE. An earlier pass printed "no blocker is
# waiting for an answer", which reads as a positive verdict on the return leg
# that nothing here establishes.
assert_match "that is an absence, not a working return leg" "$nfy_out" \
  "doctor states the bound on its own all-clear instead of implying the return leg works"
grep -q "no blocker is waiting for an answer" <<<"$nfy_out" \
  && fail "doctor must not phrase the inbound all-clear as a positive verdict"

# 9. AN EXPIRED QUESTION MUST STOP WARNING. `orchid answer` refuses anything
#    past answer_expiry_s, so an expired question can never be answered and
#    the old check warned about it on EVERY run, forever -- the false alarm
#    that teaches an operator to skim past this exact line. (Two such
#    questions were sitting in this project's own runtime when it was found.)
printf 'answer_expiry_s=60\n' >> "$nfy/orchid.config"
printf 'task: none\nnonce: aaaabbbbccccdddd\nlong gone?\n' > "$nfy/.orchid/runtime/answers/q-2-bbbb.question"
# Backdated well past the 60s expiry above; `touch -t` is POSIX, unlike the
# GNU-only `-d '... ago'` form.
touch -t 200001010000 "$nfy/.orchid/runtime/answers/q-2-bbbb.question"
nfy_doctor
assert_notify_advisory "an expired question is accounted for, never as a doctor failure"
grep -q "WARN: notify inbound: 1 blocker" <<<"$nfy_out" \
  && fail "an EXPIRED question must not be reported as waiting for an answer — orchid answer would refuse it"
assert_match "1 further question\\(s\\) ignored as unanswerable" "$nfy_out" \
  "doctor accounts for the questions it excluded rather than silently dropping them"
assert_match "expired past answer_expiry_s=60s" "$nfy_out" \
  "doctor names the expiry it applied, using the repo's own configured value"

# 10. EXPIRY IS THE ONLY EXCLUSION -- task status is NOT one. `orchid answer`
#     never reads task status (libexec/orchid-answer gates on the question
#     file, expiry, nonce/allowlist and no prior answer), so a question on a
#     task in ANY status is answerable and its silence is real evidence. An
#     earlier pass excluded everything whose task was not `blocked`, which
#     discarded exactly the boundaries runners/orchid-drive notifies with the
#     task mid-flight -- hook-failure, worktree-conflict, non-arbitrable
#     review-conflict, and `merge left the task in merging`.
#
#     Statuses chosen to span the three cases that matter: locally resolved
#     (`rework`, what the old filter was aimed at), notified mid-merge
#     (`merging`, drive's operator-decision boundary), and awaiting
#     arbitration (`arbitrating`, where a review-conflict blocker lands).
#
#     The 60s expiry from case 9 is widened to an hour first, and REWRITTEN
#     rather than appended so there is only ever one `answer_expiry_s` line
#     for config_get to resolve. Four more doctor passes follow (each running
#     the plugin probe with its own 10s deadline), and a question created at
#     the top of this loop must still be inside the window when case 11
#     counts it; 60s is not a safe margin for that on a loaded machine. The
#     backdated question from case 9 stays expired under either value.
sed 's/^answer_expiry_s=60$/answer_expiry_s=3600/' "$nfy/orchid.config" > "$nfy/orchid.config.tmp"
mv "$nfy/orchid.config.tmp" "$nfy/orchid.config"
mkdir -p "$nfy/.orchid/tasks"
nfy_q=0
for nfy_case in T009:rework:cccc T011:merging:eeee T012:arbitrating:ffff; do
  nfy_id="${nfy_case%%:*}"; nfy_rest="${nfy_case#*:}"
  nfy_st="${nfy_rest%%:*}"; nfy_tag="${nfy_rest#*:}"
  printf -- '---\nschema: 1\nid: %s\nstatus: %s\n---\nbody\n' "$nfy_id" "$nfy_st" \
    > "$nfy/.orchid/tasks/$nfy_id.md"
  printf 'task: %s\nnonce: 1111222233334444\nanswerable in %s?\n' "$nfy_id" "$nfy_st" \
    > "$nfy/.orchid/runtime/answers/q-$nfy_tag.question"
  nfy_q=$(( nfy_q + 1 ))
  nfy_doctor
  assert_notify_advisory "an unanswered question on a '$nfy_st' task is a warning, never a doctor failure"
  assert_match "WARN: notify inbound: $nfy_q blocker\\(s\\) in .* are still waiting for an answer" "$nfy_out" \
    "a fresh question on a '$nfy_st' task counts as waiting — 'orchid answer' would accept it"
done
# The expired question from case 9 is still excluded, and it is now the ONLY
# thing in the ignored bucket -- the exclusion narrowed to what `orchid
# answer` actually refuses.
assert_match "1 further question\\(s\\) ignored as unanswerable" "$nfy_out" \
  "expiry remains the sole exclusion, and doctor still accounts for it"
assert_match "which is the one refusal 'orchid answer' itself enforces" "$nfy_out" \
  "doctor names expiry as the rule it is mirroring rather than inventing its own"
grep -q "no longer blocked" <<<"$nfy_out" \
  && fail "doctor must not exclude questions by task status — orchid answer never reads it"

# 11. A still-blocked task's fresh question warns too: narrowing the
#     exclusion must not have disturbed the original case.
printf -- '---\nschema: 1\nid: T010\nstatus: blocked\n---\nbody\n' > "$nfy/.orchid/tasks/T010.md"
printf 'task: T010\nnonce: 5555666677778888\nstill waiting?\n' > "$nfy/.orchid/runtime/answers/q-4-dddd.question"
nfy_doctor
assert_match "WARN: notify inbound: 4 blocker\\(s\\) in .* are still waiting for an answer" "$nfy_out" \
  "a fresh question on a still-blocked task is exactly what this warning is for"
assert_match "still within answer_expiry_s=3600s" "$nfy_out" \
  "the warning says the question is still answerable, which is why it is worth reporting"

# 12. A configured channel whose plugin does not resolve: outbound is broken
#     and said so, still advisory -- and inbound is NOT PROBED rather than
#     silently absent.
sed 's/^notify.plugin=fixchan$/notify.plugin=nosuchchan/' "$nfy/orchid.config" > "$nfy/orchid.config.tmp"
mv "$nfy/orchid.config.tmp" "$nfy/orchid.config"
nfy_doctor
assert_notify_advisory "an unresolvable notify plugin is a warning, never a doctor failure"
assert_match "WARN: notify outbound: notify.plugin 'nosuchchan' does not resolve" "$nfy_out" \
  "doctor names an unresolvable notify plugin"
assert_match "WARN: notify inbound \\(the return leg\\): NOT PROBED" "$nfy_out" \
  "with no plugin resolved there is nothing to probe, and doctor says so"

# 13. answer_allowlist set with notify.channel UNSET: nothing is ever sent, so
#     doctor must not evaluate a plugin the repo never put on the send path.
nfy_al="$WORK/notify-repo-allowlist"; mkdir -p "$nfy_al"
(cd "$nfy_al" && git init -q . && git commit -q --allow-empty -m root)
printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\nanswer_allowlist=phone\n' \
  > "$nfy_al/orchid.config"
nfy_al_rc=0
nfy_al_out="$(ORCHID_REPO="$nfy_al" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng" \
  ORCHID_PLUGIN_PATH="$WORK/notify-plugins" "$ORCHID_BIN" doctor 2>&1)" || nfy_al_rc=$?
assert_eq "0" "$nfy_al_rc" "an allowlist with no channel keeps doctor green"
assert_match "note: notify outbound: notify.channel is unset" "$nfy_al_out" \
  "an allowlist alone must not be read as a configured send path"
assert_match "note: notify inbound \\(the return leg\\): nothing to probe" "$nfy_al_out" \
  "with no channel there is no return leg to probe either"
grep -q "notify inbound (the return leg): NOT VERIFIED" <<<"$nfy_al_out" \
  && fail "with notify.channel unset there is no channel to be unverified about"

# ---------------------------------------------------------------------------
# T034 (dogfood F34): DOCTOR MUST SEE A DESTROYED TASK FILE.
#
# A task whose file was destroyed mid-flight -- zero bytes, or non-empty with
# its frontmatter gone -- presents everywhere else as a task that simply
# stopped existing: the path is still there, `task list` prints a row of empty
# fields, and nothing in a run says anything is wrong. Both dogfood operators
# found the damage only because a grep came back empty. Nobody goes looking for
# a zero-byte file, so the check has to come to them.
#
# The GREEN direction is asserted FIRST and in the same repo, so the FAIL below
# is attributable to the truncation and not to a check that flags every task
# file it sees.
#
# ATTRIBUTION IS BY FAIL LINE, NOT BY `$tskf_rc`. Same reason
# `assert_notify_advisory` above gives: doctor's exit code is its GLOBAL verdict
# over every check in the file, so asserting `rc == 0` on the green half would
# couple this case to whatever else a hand-built fixture happens to trip (the
# split-brain check, a plugin note, the unattended gate) and would go red for a
# reason that has nothing to do with task files. What this case actually claims
# is narrower and stronger: the intact run emits the `ok:` line and NO
# `FAIL: task file` line, and each damaged run adds EXACTLY ONE new FAIL --
# doctor's own count, since `bad()` is what drives its non-zero exit (asserted
# at the unresolvable-role case above).
# ---------------------------------------------------------------------------
tskf="$WORK/taskfile-repo"; mkdir -p "$tskf"
git init -q "$tskf"
(cd "$tskf" && git commit -q --allow-empty -m root)
printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' \
  > "$tskf/orchid.config"
mkdir -p "$tskf/.orchid/tasks"
# roadmap.md alongside tasks/, or doctor's split-brain check fails this repo
# for an unrelated reason and the rc assertions below prove nothing.
printf -- '---\nrun_id: r-001\nrun_status: running\n---\nroadmap body\n' > "$tskf/.orchid/roadmap.md"
printf -- '---\nschema: 1\nid: TK1\ntitle: intact\nstatus: pending\n---\nbody\n' > "$tskf/.orchid/tasks/TK1.md"
# `|| true` on the count: `grep -c` prints 0 AND exits 1 when nothing matches,
# so an unguarded count would abort the substitution on exactly the healthy run
# this baseline exists to measure.
tskf_doctor() {
  tskf_rc=0
  tskf_out="$(ORCHID_REPO="$tskf" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng" \
    "$ORCHID_BIN" doctor 2>&1)" || tskf_rc=$?
  tskf_fails="$(grep -c '^FAIL:' <<<"$tskf_out" || true)"
}

tskf_doctor
tskf_fails_clean="$tskf_fails"
grep -q '^FAIL: task file' <<<"$tskf_out" \
  && fail "doctor must not report an INTACT task file as damaged (out: $tskf_out)"
assert_match "^ok: task files: 1 present, each with parseable frontmatter and an id" "$tskf_out" \
  "doctor reports intact task files as intact"
green_case 'orchid doctor over an intact task file: ok, no task-file FAIL'

# ZERO BYTES -- exactly what the destroyed r-002/F34 task file looked like.
: > "$tskf/.orchid/tasks/TK1.md"
tskf_doctor
[ "$tskf_rc" -ne 0 ] || fail "doctor must FAIL on a zero-byte task file (a run whose task file vanished otherwise presents as a task that stopped existing)"
assert_eq "$((tskf_fails_clean + 1))" "$tskf_fails" \
  "the truncation adds EXACTLY ONE new FAIL -- nothing else about the fixture changed, so doctor's non-zero exit here is this check's (out: $tskf_out)"
assert_match "^FAIL: task file \\.orchid/tasks/TK1\\.md: the file is EMPTY \\(0 bytes\\)" "$tskf_out" \
  "doctor names the damaged path and what is wrong with it"
assert_match "DAMAGED task file" "$tskf_out" \
  "doctor calls it damage rather than an empty task"
assert_match "git checkout <sha> -- \\.orchid/tasks/TK1\\.md" "$tskf_out" \
  "doctor prints the recovery command for the file it names"
grep -q '^ok: task files:' <<<"$tskf_out" \
  && fail "doctor must not also report the task files as ok once one of them is damaged"
red_case 'orchid doctor over a zero-byte task file: FAIL, non-zero exit'

# ...and the non-empty half of the same class: a file with content but no
# frontmatter at all, which every reader here would otherwise treat as a task
# with no fields set.
printf 'the frontmatter is gone but the body survived\n' > "$tskf/.orchid/tasks/TK1.md"
tskf_doctor
[ "$tskf_rc" -ne 0 ] || fail "doctor must FAIL on a frontmatter-less task file too"
assert_eq "$((tskf_fails_clean + 1))" "$tskf_fails" \
  "the frontmatter-less file adds exactly one new FAIL too (out: $tskf_out)"
assert_match "^FAIL: task file \\.orchid/tasks/TK1\\.md: no frontmatter" "$tskf_out" \
  "doctor distinguishes a frontmatter-less file from an empty one"
red_case 'orchid doctor over a frontmatter-less task file: FAIL, non-zero exit'

# ...and the shape that is neither empty nor frontmatter-less, which is the one
# an operator can never find by looking (T034 rework). A value carrying a
# newline splits one entry in two, leaving the remainder in the frontmatter as
# a line belonging to no key. Both delimiters are present and `id` still
# resolves, so this file passed both checks above, `task show` printed it, and
# only the split field was quietly wrong -- doctor is the check that comes to
# the operator, so it is the one that has to see this.
printf -- '---\nschema: 1\nid: TK1\ntitle: first half of a value\nand the remainder of that value\nstatus: pending\n---\nbody\n' \
  > "$tskf/.orchid/tasks/TK1.md"
tskf_doctor
[ "$tskf_rc" -ne 0 ] || fail "doctor must FAIL on a task file whose frontmatter carries a key-less remainder line -- id resolves and both delimiters are there, so nothing else reports it"
assert_eq "$((tskf_fails_clean + 1))" "$tskf_fails" \
  "the split value adds exactly one new FAIL too (out: $tskf_out)"
assert_match "^FAIL: task file \\.orchid/tasks/TK1\\.md: malformed frontmatter: line 5" "$tskf_out" \
  "doctor names the line the damage is on, since the rest of the document reads normally"
red_case 'orchid doctor over frontmatter carrying a key-less remainder line: FAIL, non-zero exit'

# And the fixture is restored, so nothing downstream of this file inherits a
# repo doctor considers damaged.
printf -- '---\nschema: 1\nid: TK1\ntitle: intact\nstatus: pending\n---\nbody\n' > "$tskf/.orchid/tasks/TK1.md"
