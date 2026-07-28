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

# -- resolve_engine_exe searches ORCHID_PLUGIN_PATH roots too (Must-fix 2) --
# `plugins list` already discovers ORCHID_PLUGIN_PATH-root plugins as
# origin=path (tests/test_plugins_list.sh) -- resolve_engine_exe must be able
# to actually execute one of those, matching the `list` row, or a path-root
# plugin lists healthy but can never run.
pathroot="$WORK/pathroot"
mkdir -p "$pathroot/engines/pathy"
printf '#!/usr/bin/env bash\ntrue\n' > "$pathroot/engines/pathy/run"; chmod +x "$pathroot/engines/pathy/run"
out="$(ORCHID_PLUGIN_PATH="$pathroot" resolve_engine_exe pathy)" || fail "resolve_engine_exe must resolve an ORCHID_PLUGIN_PATH-root plugin"
assert_match "pathroot/engines/pathy/run$" "$out" "resolved path points at the ORCHID_PLUGIN_PATH root's plugin"

# a duplicate id across an ORCHID_PLUGIN_PATH root and a built-in must still
# error (INV-10: no silent shadow, not even a search-path precedence win).
mkdir -p "$pathroot/engines/claude"
printf '#!/usr/bin/env bash\ntrue\n' > "$pathroot/engines/claude/run"; chmod +x "$pathroot/engines/claude/run"
rc=0
err="$(ORCHID_ROOT="$REPO_ROOT" ORCHID_PLUGIN_PATH="$pathroot" resolve_engine_exe claude 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "resolve_engine_exe must error on a duplicate id across an ORCHID_PLUGIN_PATH root and a built-in (INV-10)"
assert_match "duplicate engine 'claude'" "$err" "INV-10 error names the duplicate engine"
assert_match "INV-10" "$err" "INV-10 error names the invariant"
