#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/resolver.sh"
cd "$WORK"; git init -q .; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME/.orchid"
printf 'role.implementer=fake\n' > orchid.config
assert_eq fake "$(resolve_role "$WORK" implementer)" "role from repo config"
mkdir -p "$WORK/eng/fake"; printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
ORCHID_ENGINES_DIR="$WORK/eng" out="$(ORCHID_ENGINES_DIR="$WORK/eng" resolve_engine_exe fake)" || fail "resolve exe"
assert_match "fake/run" "$out" "exe path"
assert_match "role.implementer	fake	repo" "$("$ORCHID_BIN" config list)" "config list provenance"
