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

"$ORCHID_BIN" init
git rev-parse --verify -q orchid/integration >/dev/null || fail "integration branch"
git show orchid/integration:.orchid/roadmap.md | grep -q "run_status: planning" || fail "roadmap committed with run_status"
rc=0; printf 'role.implementer=missing-engine\n' >> orchid.config
ORCHID_ENGINES_DIR="$WORK/eng" "$ORCHID_BIN" doctor >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "doctor fails on unresolvable role"
