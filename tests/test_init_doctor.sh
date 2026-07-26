#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME/.orchid"
printf 'verify=true\n' > orchid.config
mkdir -p "$WORK/eng/fake"; printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
printf 'role.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' >> orchid.config

ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor || fail "doctor passes with resolvable fake engines"
mkdir -p .orchid/plugins/engines/evil
out="$(ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor)" || true
assert_match "repo-local plugins.*disabled" "$out" "repo-local plugin warning"

# init now refuses a dirty tree, so commit the fixture's config/engine
# scaffolding first (a real user would already have these committed).
git add -A && git commit -q -m "fixture: engines + config"
"$ORCHID_BIN" init
git rev-parse --verify -q orchid/integration >/dev/null || fail "integration branch"
git show orchid/integration:.orchid/roadmap.md | grep -q "run_status: planning" || fail "roadmap committed with run_status"
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
