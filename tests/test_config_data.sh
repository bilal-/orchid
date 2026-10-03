#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/spawn.sh"

# RED: config keys and permission names containing shell syntax stay inert.
# GREEN: literal keys and valid environment overrides retain their precedence.
export HOME="$WORK/home"
mkdir -p "$HOME/.orchid"
export ORCHID_CONFIG_PROBE="$WORK/config-executed"
config_syntax_key='value[$(: > "$ORCHID_CONFIG_PROBE")]'
printf '%s=literal-value\n' "$config_syntax_key" > "$WORK/orchid.config"
config_value="$(config_get "$WORK" "$config_syntax_key" fallback)" || fail 'config_get accepts keys as data'
config_source="$(config_provenance "$WORK" "$config_syntax_key")" || fail 'config_provenance accepts keys as data'
[ ! -e "$ORCHID_CONFIG_PROBE" ] || fail 'config key must not execute shell syntax'
assert_eq literal-value "$config_value" 'shell syntax in a config key is matched literally'
assert_eq repo "$config_source" 'literal key has repository provenance'
red_case 'config lookup and provenance never evaluate shell syntax in their key'

printf 'value=wrong\nvalue+=first\nvalue+=last=with-equals\n' > "$WORK/orchid.config"
assert_eq last=with-equals "$(config_get "$WORK" 'value+' fallback)" 'literal metacharacter key uses last exact record'
assert_eq fallback "$(config_get "$WORK" 'value?' fallback)" 'regex-shaped key cannot match a sibling record'
red_case 'configuration keys are exact strings rather than regular expressions'

printf 'review.valid=repo-value\n' > "$WORK/orchid.config"
printf 'review.valid=user-value\n' > "$HOME/.orchid/config"
export ORCHID_REVIEW_VALID=env-value
assert_eq env-value "$(config_get "$WORK" review.valid default-value)" 'environment wins over repository and user'
assert_eq env "$(config_provenance "$WORK" review.valid)" 'environment provenance agrees'
config_value="$(ORCHID_REVIEW_VALID=-n config_get "$WORK" review.valid)"
assert_eq -n "$config_value" 'option-shaped environment value is preserved'
unset ORCHID_REVIEW_VALID
assert_eq repo-value "$(config_get "$WORK" review.valid default-value)" 'repository wins over user'
assert_eq repo "$(config_provenance "$WORK" review.valid)" 'repository provenance agrees'
rm "$WORK/orchid.config"
assert_eq user-value "$(config_get "$WORK" review.valid default-value)" 'user value wins over default'
assert_eq user "$(config_provenance "$WORK" review.valid)" 'user provenance agrees'
assert_eq default-value "$(config_get "$WORK" missing default-value)" 'absent key uses default'
assert_eq default "$(config_provenance "$WORK" missing)" 'default provenance agrees'
green_case 'valid environment names and all four configuration layers still resolve'

config_plugin="$WORK/plugin"; mkdir -p "$config_plugin"
cat > "$config_plugin/plugin.conf" <<'CONF'
manifest_version=1
id=orchid/config-data
version=1.0.0
kind=engine
api_version=1
entrypoint=run
capabilities=structured_text
CONF
printf '#!/usr/bin/env bash\ntrue\n' > "$config_plugin/run"
chmod +x "$config_plugin/run"
export ORCHID_PERMISSION_PROBE="$WORK/permission-executed"
P=(permitted)
printf '%s\n' 'permissions=P[$(: > "$ORCHID_PERMISSION_PROBE")]' >> "$config_plugin/plugin.conf"
config_rc=0
config_error="$(manifest_validate "$config_plugin" 2>&1)" || config_rc=$?
[ "$config_rc" -ne 0 ] || fail 'manifest must reject a permission that is not an environment name'
[ ! -e "$ORCHID_PERMISSION_PROBE" ] || fail 'manifest permission must not execute array subscript syntax'
assert_match 'invalid permission' "$config_error" 'manifest diagnoses an invalid permission name'
config_rc=0
config_error="$(spawn_child_env "$config_plugin" 2>&1)" || config_rc=$?
[ "$config_rc" -ne 0 ] || fail 'spawn must reject invalid permission even without manifest validation'
[ ! -e "$ORCHID_PERMISSION_PROBE" ] || fail 'spawn permission must not execute array subscript syntax'
assert_match 'invalid permission' "$config_error" 'spawn diagnoses an invalid permission name'
red_case 'manifest validation and environment construction refuse executable permission expressions'

printf '%s\n' 'permissions=CONFIG_ALLOWED, CONFIG_EMPTY' >> "$config_plugin/plugin.conf"
export CONFIG_ALLOWED="${P[0]}" CONFIG_EMPTY=''
config_output="$(manifest_validate "$config_plugin" 2>&1)" || fail 'valid permission names remain accepted'
assert_match '^ok:' "$config_output" 'manifest with valid permission names passes'
config_output="$(spawn_child_env "$config_plugin")" || fail 'valid permissions build the child environment'
assert_match '^CONFIG_ALLOWED=permitted$' "$config_output" 'explicitly permitted value is forwarded'
assert_match '^CONFIG_EMPTY=$' "$config_output" 'explicitly permitted empty value is forwarded'
green_case 'valid permission names preserve populated and empty opted-in environment values'
