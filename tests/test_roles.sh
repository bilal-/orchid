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
cd "$WORK"; git init -q .
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME/.orchid"

out="$(resolve_role_checked "$WORK" implementer)"; rc=$?
assert_eq 0 "$rc" "resolve_role_checked succeeds for implementer (codex default)"
assert_eq codex "$out" "resolve_role_checked returns codex for implementer"

printf 'role.implementer=agy\n' > orchid.config
err="$(resolve_role_checked "$WORK" implementer 2>&1 1>/dev/null)"; rc=$?
assert_eq 1 "$rc" "resolve_role_checked rejects agy for implementer (lacks workspace_write)"
assert_match "engine agy lacks capability .* for role implementer" "$err" "clear capability-gap message"
rm -f orchid.config

# existing resolve_role/resolve_engine_exe stay unchanged (back-compat)
assert_eq codex "$(resolve_role "$WORK" implementer)" "resolve_role unaffected by resolve_role_checked"
