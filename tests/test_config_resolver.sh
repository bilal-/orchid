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

# ---------------------------------------------------------------------------
# v1-m2 Task 2: role config values become comma-separated preference chains.
# `resolve_role_chain` splits a configured chain (or supplies the built-in
# default chain) one engine per line; `resolve_role` MUST keep returning only
# the first entry (back-compat: it already did `${v%%,*}` for a scalar, so a
# comma chain must reduce to its first element exactly the same way).
# ---------------------------------------------------------------------------
rm -f orchid.config

# -- built-in default chains (no config at all) ------------------------------
assert_eq "$(printf 'claude\ncodex')" "$(resolve_role_chain "$WORK" orchestrator)" "default chain: orchestrator"
assert_eq "$(printf 'codex\nclaude')" "$(resolve_role_chain "$WORK" implementer)" "default chain: implementer"
assert_eq "$(printf 'agy')" "$(resolve_role_chain "$WORK" reviewer)" "default chain: reviewer (single entry)"
assert_eq "$(printf 'claude\ncodex')" "$(resolve_role_chain "$WORK" arbiter)" "default chain: arbiter"
assert_eq "$(printf 'codex\nclaude')" "$(resolve_role_chain "$WORK" plan_critic)" "default chain: plan_critic"

assert_eq claude "$(resolve_role "$WORK" orchestrator)" "resolve_role still returns only the first of the default chain (orchestrator)"
assert_eq codex "$(resolve_role "$WORK" implementer)" "resolve_role still returns only the first of the default chain (implementer)"
assert_eq agy "$(resolve_role "$WORK" reviewer)" "resolve_role unaffected for a single-entry default (reviewer)"
assert_eq claude "$(resolve_role "$WORK" arbiter)" "resolve_role still returns only the first of the default chain (arbiter)"
assert_eq codex "$(resolve_role "$WORK" plan_critic)" "resolve_role still returns only the first of the default chain (plan_critic)"

# -- configured comma chain ---------------------------------------------------
printf 'role.implementer=codex,claude\n' > orchid.config
assert_eq "$(printf 'codex\nclaude')" "$(resolve_role_chain "$WORK" implementer)" "resolve_role_chain splits a configured comma chain"
assert_eq codex "$(resolve_role "$WORK" implementer)" "resolve_role returns only the first entry of a configured chain (not the raw comma value)"

# -- configured scalar (no comma) still round-trips exactly like before ------
printf 'role.implementer=fake\n' > orchid.config
assert_eq "$(printf 'fake')" "$(resolve_role_chain "$WORK" implementer)" "resolve_role_chain: a scalar config value is a one-entry chain"
assert_eq fake "$(resolve_role "$WORK" implementer)" "resolve_role: scalar config value unaffected"

rm -f orchid.config
