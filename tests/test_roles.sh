#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"
export ORCHID_ROOT="$REPO_ROOT"

# -- role_requires / role_forbids parse each core role's .role file ---------
assert_eq "$(printf 'shell\ngit')" "$(role_requires orchestrator)" "orchestrator requires shell,git"
assert_eq "$(printf 'workspace_write\nshell\ngit')" "$(role_requires implementer)" "implementer requires workspace_write,shell,git"
assert_eq structured_text "$(role_requires reviewer)" "reviewer requires structured_text"
assert_eq structured_text "$(role_requires arbiter)" "arbiter requires structured_text"
assert_eq structured_text "$(role_requires plan_critic)" "plan_critic requires structured_text"
assert_eq "" "$(role_forbids reviewer)" "reviewer has no forbids by default"
assert_eq "" "$(role_forbids implementer)" "implementer has no forbids by default"

# -- role_eligible is purely capability-driven -------------------------------
agy_dir="$REPO_ROOT/plugins/engines/agy"       # structured_text only
codex_dir="$REPO_ROOT/plugins/engines/codex"   # full capability set
claude_dir="$REPO_ROOT/plugins/engines/claude" # full capability set

role_eligible reviewer "$agy_dir" || fail "agy (structured_text only) should be eligible for reviewer"
role_eligible arbiter "$agy_dir" || fail "agy should be eligible for arbiter"
role_eligible plan_critic "$agy_dir" || fail "agy should be eligible for plan_critic"
role_eligible implementer "$agy_dir" && fail "agy lacks workspace_write/shell/git: must NOT be eligible for implementer"
role_eligible orchestrator "$agy_dir" && fail "agy lacks shell/git: must NOT be eligible for orchestrator"

for role in orchestrator implementer reviewer arbiter plan_critic; do
  role_eligible "$role" "$codex_dir" || fail "codex (full capability set) should be eligible for $role"
  role_eligible "$role" "$claude_dir" || fail "claude (full capability set) should be eligible for $role"
done

# -- resolve_role_checked gates resolve_role on eligibility ------------------
cd_scratch "$WORK" || exit 1; git init -q .
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME/.orchid"

out="$(resolve_role_checked "$WORK" implementer)"; rc=$?
assert_eq 0 "$rc" "resolve_role_checked succeeds for implementer (codex default)"
assert_eq codex "$out" "resolve_role_checked returns codex for implementer"

printf 'role.implementer=agy\n' > orchid.config
err="$(resolve_role_checked "$WORK" implementer 2>&1 1>/dev/null)"; rc=$?
assert_eq 1 "$rc" "resolve_role_checked rejects agy for implementer (lacks workspace_write)"
assert_match "engine agy missing required capability workspace_write for role implementer" "$err" "clear missing-required-capability message"
rm -f orchid.config

# -- resolve_role_checked reports the correct (non-backwards) message for a
# forbids violation: the engine HAS the forbidden capability, not "lacks" it.
mkdir -p "$WORK/roles" "$WORK/plugins/engines/netty"
cat > "$WORK/roles/nettest.role" <<'EOF'
id=nettest
forbids=network
description=test role forbidding network
EOF
cat > "$WORK/plugins/engines/netty/plugin.conf" <<'EOF'
manifest_version=1
id=orchid/netty
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text,network
entrypoint=run
EOF
: > "$WORK/plugins/engines/netty/run"; chmod +x "$WORK/plugins/engines/netty/run"

ORCHID_ROOT="$WORK" role_eligible nettest "$WORK/plugins/engines/netty" \
  && fail "netty (has network) should NOT be eligible for nettest (forbids network)"

printf 'role.nettest=netty\n' > orchid.config
err="$(ORCHID_ROOT="$WORK" resolve_role_checked "$WORK" nettest 2>&1 1>/dev/null)"; rc=$?
assert_eq 1 "$rc" "resolve_role_checked rejects netty for nettest (has forbidden network)"
assert_match "engine netty has forbidden capability network for role nettest" "$err" "clear forbidden-capability message"
rm -f orchid.config

# existing resolve_role/resolve_engine_exe stay unchanged (back-compat)
assert_eq codex "$(resolve_role "$WORK" implementer)" "resolve_role unaffected by resolve_role_checked"

# -----------------------------------------------------------------------
# v1-m3 Task 7: _role_file grows a search path (mirroring resolve_engine_
# exe/archetype_dir), so a custom role can ship as a plugin. Precedence:
# ORCHID_ROLES_DIR (test hook) > $ORCHID_PLUGIN_PATH/roles/<n>/descriptor.
# role > ~/.orchid/plugins/roles/<n>/descriptor.role > $ORCHID_ROOT/roles/
# <n>.role (built-ins, always last).
# -----------------------------------------------------------------------
homeRP="$WORK/homeRP"; mkdir -p "$homeRP/.orchid/plugins/roles/scribe"
printf 'id=scribe\nrequires=structured_text\ndescription=user-root scribe\n' \
  > "$homeRP/.orchid/plugins/roles/scribe/descriptor.role"
out="$(HOME="$homeRP" ORCHID_ROOT="$WORK" role_requires scribe)"
assert_eq structured_text "$out" "_role_file finds a role descriptor under ~/.orchid/plugins/roles/<name>/"

pathrootR="$WORK/pathrootR"; mkdir -p "$pathrootR/roles/scribe"
printf 'id=scribe\nrequires=git\ndescription=path-root scribe\n' \
  > "$pathrootR/roles/scribe/descriptor.role"
out="$(HOME="$WORK/homeRP-empty" ORCHID_ROOT="$WORK" ORCHID_PLUGIN_PATH="$pathrootR" role_requires scribe)"
assert_eq git "$out" "\$ORCHID_PLUGIN_PATH/roles/<name>/descriptor.role outranks ~/.orchid (unused here) when it's the only hit"

# ORCHID_ROLES_DIR is checked in isolation (a distinct role name from
# 'scribe' above): mirroring resolve_engine_exe/archetype_dir, the test hook
# is just the first entry walked in the SAME collision-checked search --
# were it to also collide with a real root's same-named role, that would
# (correctly) be INV-10 too, not a silent "test hook wins".
rolesdirR="$WORK/rolesdirR"; mkdir -p "$rolesdirR"
printf 'id=annotator\nrequires=shell\ndescription=test-hook role\n' > "$rolesdirR/annotator.role"
out="$(ORCHID_ROLES_DIR="$rolesdirR" ORCHID_ROOT="$WORK" role_requires annotator)"
assert_eq shell "$out" "ORCHID_ROLES_DIR test hook is discoverable and highest-precedence when nothing else names the role"

# a duplicate role id across TWO real roots (an ORCHID_PLUGIN_PATH root and
# ~/.orchid/plugins/roles, neither of them the built-in) is an INV-10 error
# same as any other collision -- no silent shadow, not even between two
# custom roots.
err="$(HOME="$homeRP" ORCHID_ROOT="$WORK" ORCHID_PLUGIN_PATH="$pathrootR" _role_file scribe 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "_role_file must error when two custom roots both declare role 'scribe' (INV-10)"
assert_match "duplicate role 'scribe'" "$err" "INV-10 error names the duplicate role"
assert_match "INV-10" "$err" "INV-10 error names the invariant"

# an entirely unknown role (nowhere on the search path) is NOT an error --
# _role_file resolves to the built-in (nonexistent) path and role_get's
# existing missing-file-is-empty handling takes it from there.
assert_eq "" "$(HOME="$WORK/homeRP-empty" ORCHID_ROOT="$WORK" role_requires totallyunknown)" \
  "an unknown role's requires is empty, not an error"

# -- role_binding_blocking: default true, config-overridable ---------------
assert_eq true "$(role_binding_blocking "$WORK" implementer)" "role_binding_blocking defaults to true with no config"
printf 'role.implementer.blocking=false\n' > "$WORK/orchid.config"
assert_eq false "$(role_binding_blocking "$WORK" implementer)" "role_binding_blocking honors role.<id>.blocking=false"
rm -f "$WORK/orchid.config"
