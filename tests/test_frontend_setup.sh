#!/usr/bin/env bash
# Native fixtures use host parsers, never vendor/model launches or real profiles.
fixture_python="${ORCHID_FRONTEND_PYTHON:-}"
if [ -n "$fixture_python" ] && { [ ! -x "$fixture_python" ] || ! "$fixture_python" -c 'import yaml' >/dev/null 2>&1; }; then fixture_python=''; fi
if [ -z "$fixture_python" ]; then
  for candidate in "${HERMES_HOME:-$HOME/.hermes}/hermes-agent/venv/bin/python" "$(command -v python3 || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -c 'import yaml' >/dev/null 2>&1; then fixture_python="$candidate"; break; fi
  done
fi
fixture_node="$(command -v node || true)"
source "$(dirname "$0")/helpers.sh"
unset CLAUDE_CONFIG_DIR CODEX_HOME HERMES_HOME XDG_CONFIG_HOME
export HOME="$WORK/home space' quote"
mkdir -p "$HOME" "$WORK/nogit"
export ORCHID_FRONTEND_PYTHON="$fixture_python"
strict_native="${ORCHID_REQUIRE_NATIVE_FRONTENDS:-0}"
if [ -z "$fixture_python" ]; then
  [ "$strict_native" != 1 ] || fail 'native frontend qualification requires Python with PyYAML'
  not_tested 'Hermes-native-frontend' 'PyYAML unavailable; rerun with ORCHID_REQUIRE_NATIVE_FRONTENDS=1 and ORCHID_FRONTEND_PYTHON pointing to Hermes Python'
fi
if [ -z "$fixture_node" ]; then
  [ "$strict_native" != 1 ] || fail 'native frontend qualification requires Node for OpenCode plugin execution'
  not_tested 'OpenCode-native-plugin' 'Node unavailable; rerun with Node and ORCHID_REQUIRE_NATIVE_FRONTENDS=1'
fi

fixture_root="$WORK/payload"
mkdir -p "$fixture_root"
for dir in lib libexec runners; do cp -R "$REPO_ROOT/$dir" "$fixture_root/"; done
mkdir -p "$fixture_root/bin"
cat > "$fixture_root/bin/orchid" <<'EOF'
#!/bin/bash
printf '%s\n' "$PWD|$*" >> "$ORCHID_FIXTURE_CALLS"
printf '%s\n' "${ORCHID_OUTPUT:-unset}" >> "$ORCHID_FIXTURE_FORMATS"
if [ "${ORCHID_FIXTURE_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "${ORCHID_FIXTURE_SLOW:-0}" = 1 ]; then sleep 15; fi
if [ "${ORCHID_FIXTURE_LARGE:-0}" = 1 ]; then printf '%09000d' 0; exit 0; fi
if [ "${ORCHID_OUTPUT:-}" = raw ]; then printf 'legacy raw context\n'; exit 0; fi
printf 'repo: fixture\nnext: orchid status --explain\n'
EOF
chmod 755 "$fixture_root/bin/orchid"
export ORCHID_FIXTURE_CALLS="$WORK/context.calls"
export ORCHID_FIXTURE_FORMATS="$WORK/context.formats"
setup="$fixture_root/runners/orchid-setup"
run_setup() { (cd "$WORK/nogit" && /bin/bash "$setup" "$@"); }

# GREEN: overview is read-only even in a fresh HOME, and generic invocation
# exposes every host without silently registering native callbacks.
overview="$(run_setup)" || fail 'frontend overview failed'
assert_eq 4 "$(jq '.frontends|length' <<< "$overview")" 'overview declares all four hosts'
[ ! -e "$HOME/.orchid" ] || fail 'read-only setup overview created user state'
green_case 'frontend setup overview has no user-configuration writes'

jq -e '.next == ["orchid setup --frontend claude","orchid setup --frontend codex","orchid setup --frontend hermes","orchid setup --frontend opencode"] and (.notes|type)=="array" and any(.notes[];contains("all four profiles") and contains("PyYAML"))' <<< "$overview" >/dev/null || fail 'fresh overview lacks equal runnable host choices or all-host prerequisites'

# RED/GREEN: an unavailable Hermes parser makes all refuse before writes; a
# selected Codex profile still registers without that optional host dependency.
casehome="$WORK/fresh-codex-no-parser"
mkdir -p "$casehome/.codex"
printf '{"foreign":true}\n' > "$casehome/.codex/hooks.json"
cp "$casehome/.codex/hooks.json" "$WORK/fresh-codex.before"
rc=0; HOME="$casehome" ORCHID_FRONTEND_PYTHON="$WORK/missing-python" /bin/bash "$setup" --frontend all > "$WORK/fresh-all.out" 2> "$WORK/fresh-all.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'all registered without the required Hermes parser'
cmp -s "$WORK/fresh-codex.before" "$casehome/.codex/hooks.json" || fail 'missing parser refusal changed existing Codex profile'
for untouched in .claude .hermes .config/opencode .orchid/frontends; do [ ! -e "$casehome/$untouched" ] || fail "missing parser refusal created $untouched"; done
red_case 'all-host parser prerequisite refuses before any selected profile changes'
HOME="$casehome" ORCHID_FRONTEND_PYTHON="$WORK/missing-python" /bin/bash "$setup" --frontend codex > "$WORK/fresh-codex.out" || fail 'selected Codex unnecessarily required Hermes parser'
jq -e '.next==["orchid setup"] and (.notes|type)=="array" and any(.notes[];contains("/hooks"))' "$WORK/fresh-codex.out" >/dev/null || fail 'selected setup lacks runnable verification or native trust notes'
HOME="$casehome" ORCHID_FRONTEND_PYTHON="$WORK/missing-python" /bin/bash "$setup" --frontend codex --uninstall > "$WORK/fresh-codex-uninstall.out" || fail 'selected Codex uninstall required absent Hermes parser'
jq -e '.next==["orchid setup"] and any(.notes[];contains("Restart") and contains("host-owned"))' "$WORK/fresh-codex-uninstall.out" >/dev/null || fail 'uninstall lacks runnable verification or retained trust notes'
assert_eq true "$(jq -r .foreign "$casehome/.codex/hooks.json")" 'selected Codex preserves fresh foreign preference'
green_case 'selected Codex registers and uninstalls without Hermes while returning runnable next commands'

mkdir -p "$HOME/.claude" "$HOME/.codex"
printf '{"theme":"keep","hooks":{"Stop":[{"hooks":[{"command":"foreign-stop","type":"command"}]}]}}\n' > "$HOME/.claude/settings.json"
printf '{"hooks":{"SessionStart":[{"matcher":"resume","hooks":[{"type":"command","command":"foreign-start"}]}]},"foreign":true}\n' > "$HOME/.codex/hooks.json"
mkdir -p "$HOME/.config/opencode"
printf 'foreign plugin-directory occupant\n' > "$HOME/.config/opencode/plugins"
rc=0; run_setup --frontend opencode > /dev/null 2> "$WORK/parent.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'non-directory frontend destination parent accepted'
assert_eq 'foreign plugin-directory occupant' "$(cat "$HOME/.config/opencode/plugins")" 'foreign parent file preserved'
red_case 'native destination parent must be a writable directory'
rm "$HOME/.config/opencode/plugins"
cp "$HOME/.claude/settings.json" "$WORK/claude.before"
# RED/GREEN: native config symlinks remain foreign, including dangling links.
mv "$HOME/.claude/settings.json" "$WORK/claude.config"
ln -s "$WORK/claude.config" "$HOME/.claude/settings.json"
rc=0; run_setup --frontend claude > /dev/null 2> "$WORK/config-symlink.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'foreign native config symlink accepted'
assert_eq "$WORK/claude.config" "$(readlink "$HOME/.claude/settings.json")" 'foreign native config symlink preserved'
red_case 'native config symlinks are refused before configuration writes'
rm "$HOME/.claude/settings.json"; mv "$WORK/claude.config" "$HOME/.claude/settings.json"

# RED: malformed profile prevents the entire selected batch from writing.
printf '{malformed\n' > "$HOME/.codex/hooks.json"
rc=0; run_setup --frontend all > "$WORK/malformed.out" 2> "$WORK/malformed.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'malformed Codex hooks accepted'
cmp -s "$WORK/claude.before" "$HOME/.claude/settings.json" || fail 'failed batch changed Claude settings'
[ ! -e "$HOME/.orchid/frontends" ] || fail 'failed batch created registration artifacts'
red_case 'malformed native configuration rejects before batch writes'
printf '{"hooks":{"SessionStart":[{"matcher":"resume","hooks":[{"type":"command","command":"foreign-start"}]}]},"foreign":true}\n' > "$HOME/.codex/hooks.json"
hosts='claude codex opencode'
if [ -n "$fixture_python" ]; then
  hosts='claude codex hermes opencode'
  mkdir -p "$HOME/.hermes"
  printf '# untouched header\nmodel: foreign-model\nhooks:\n  other_event:\n    - command: foreign-event\n  pre_llm_call:\n    - command: foreign-turn\n      timeout: 9\n# untouched footer\nforeign: keep\n' > "$HOME/.hermes/config.yaml"
fi
for host in $hosts; do run_setup --frontend "$host" > "$WORK/$host.install" || fail "$host registration failed"; done
run_setup --frontend=codex > /dev/null || fail 'inline frontend option did not normalize'
assert_eq keep "$(jq -r .theme "$HOME/.claude/settings.json")" 'Claude foreign settings survive'
assert_eq foreign-stop "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOME/.claude/settings.json")" 'Claude other event survives'
assert_eq foreign-start "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOME/.codex/hooks.json")" 'Codex foreign hook survives'
[ ! -e "$HOME/.codex/config.toml" ] || fail 'setup changed Codex TOML/feature flags'
[ ! -e "$HOME/.codex/hook-trust.json" ] || fail 'setup fabricated Codex trust'
[ ! -e "$HOME/.hermes/shell-hooks-allowlist.json" ] || fail 'setup fabricated Hermes trust'
if [ -n "$fixture_python" ]; then
  "$fixture_python" - "$HOME/.hermes/config.yaml" <<'PY' || fail 'Hermes foreign values lost'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]));assert d['model']=='foreign-model';assert d['foreign']=='keep'
assert d['hooks']['other_event'][0]['command']=='foreign-event'
assert d['hooks']['pre_llm_call'][0]=={'command':'foreign-turn','timeout':9}
assert len(d['hooks']['pre_llm_call'])==2
PY
  grep -q '^# untouched header$' "$HOME/.hermes/config.yaml" || fail 'Hermes unrelated header lost'
  grep -q '^# untouched footer$' "$HOME/.hermes/config.yaml" || fail 'Hermes unrelated footer lost'
fi
green_case 'valid native profiles register all available hosts preserving foreign settings'
overview="$(run_setup)"
for host in $hosts; do assert_eq registered "$(jq -r --arg host "$host" '.frontends[]|select(.frontend==$host)|.state' <<< "$overview")" "$host registration overview checks actual files"; done

# RED/GREEN: native definitions must still match their recorded entry, and
# malformed/symlinked ownership records cannot authorize edits.
cp "$HOME/.codex/hooks.json" "$WORK/codex.managed.config"
jq '(.hooks.SessionStart[]|select(.matcher=="")|.hooks[0].timeout)=99' "$HOME/.codex/hooks.json" > "$WORK/changed.config"
mv "$WORK/changed.config" "$HOME/.codex/hooks.json"
rc=0; run_setup --frontend codex --uninstall >/dev/null 2> "$WORK/changed-config.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'modified native hook config was claimed'
assert_eq 99 "$(jq '.hooks.SessionStart[]|select(.matcher=="")|.hooks[0].timeout' "$HOME/.codex/hooks.json")" 'modified native config preserved'
assert_eq missing_or_changed_hook "$(run_setup | jq -r '.frontends[]|select(.frontend=="codex")|.state')" 'overview detects changed native hook'
red_case 'changed native entry cannot be removed using an old ownership record'
cp "$WORK/codex.managed.config" "$HOME/.codex/hooks.json"
jq '.hooks.SessionStart += [.hooks.SessionStart[]|select(.matcher=="")]' "$HOME/.codex/hooks.json" > "$WORK/duplicate.config"
mv "$WORK/duplicate.config" "$HOME/.codex/hooks.json"
rc=0; run_setup --frontend codex --uninstall >/dev/null 2> "$WORK/duplicate-config.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'ambiguous duplicate native hook entries were removed'
assert_eq 3 "$(jq '.hooks.SessionStart|length' "$HOME/.codex/hooks.json")" 'ambiguous duplicate native config preserved'
red_case 'duplicate identical native hooks cannot authorize ambiguous removal'
cp "$WORK/codex.managed.config" "$HOME/.codex/hooks.json"
rc=0; CODEX_HOME="$WORK/moved-profile" run_setup --frontend codex >/dev/null 2> "$WORK/moved-profile.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'moved native profile accepted without previous uninstall'
[ ! -e "$WORK/moved-profile" ] || fail 'moved profile refusal created destination'
red_case 'moved native profile requires previous ownership-safe uninstall'
cp "$HOME/.orchid/frontends/codex.json" "$WORK/codex.record"
printf '{}\n' > "$HOME/.orchid/frontends/codex.json"
rc=0; run_setup --frontend codex >/dev/null 2> "$WORK/malformed-record.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'malformed ownership record accepted'
assert_eq invalid_record "$(run_setup | jq -r '.frontends[]|select(.frontend=="codex")|.state')" 'overview detects malformed ownership record'
red_case 'malformed ownership record cannot authorize frontend rewrites'
rm "$HOME/.orchid/frontends/codex.json"
ln -s "$WORK/codex.record" "$HOME/.orchid/frontends/codex.json"
rc=0; run_setup --frontend codex >/dev/null 2> "$WORK/symlink-record.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'symlink ownership record accepted'
red_case 'foreign ownership record symlink cannot authorize frontend rewrites'
rm "$HOME/.orchid/frontends/codex.json"; cp "$WORK/codex.record" "$HOME/.orchid/frontends/codex.json"
run_setup --frontend codex >/dev/null || fail 'restored exact native entry/record failed'
green_case 'exact native entry and record recover after foreign-edit refusal'
if [ -n "$fixture_python" ]; then
  cp "$HOME/.hermes/config.yaml" "$WORK/hermes.managed.config"
  "$fixture_python" - "$HOME/.hermes/config.yaml" <<'PY'
import sys,yaml
path=sys.argv[1]; d=yaml.safe_load(open(path));d['hooks']['pre_llm_call'].append(dict(d['hooks']['pre_llm_call'][-1]))
with open(path,'w') as f: yaml.safe_dump(d,f,sort_keys=False)
PY
  rc=0; run_setup --frontend hermes --uninstall >/dev/null 2> "$WORK/hermes-duplicate.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'ambiguous Hermes duplicate managed hook removed'
  red_case 'native Hermes duplicate managed hook entries refuse ambiguous removal'
  cp "$WORK/hermes.managed.config" "$HOME/.hermes/config.yaml"
  run_setup --frontend hermes >/dev/null || fail 'restored exact Hermes native entries failed'
  green_case 'exact Hermes native entry permits ownership-safe recovery'
fi

# GREEN: exact registration is idempotent, and ambient callbacks use the host
# cwd and only the explicit read-only context operation.
for host in $hosts; do
  config="$(jq -r .config "$HOME/.orchid/frontends/$host.json")"
  cp "$config" "$WORK/$host.before"
  run_setup --frontend "$host" > /dev/null || fail "$host repeat registration failed"
  cmp -s "$config" "$WORK/$host.before" || fail "$host repeat changed config bytes"
done
mkdir -p "$WORK/repo space"
callback_repo="$(cd "$WORK/repo space" && pwd -P)"
assert_eq 'legacy raw context' "$(ORCHID_OUTPUT=raw "$fixture_root/bin/orchid" context --ambient)" 'raw fixture exposes inherited compatibility format'
red_case 'inherited raw output would expose legacy context without callback override'
: > "$ORCHID_FIXTURE_CALLS"; : > "$ORCHID_FIXTURE_FORMATS"
for host in claude codex hermes; do
  [ "$host" != hermes ] || [ -n "$fixture_python" ] || continue
  hook_event=SessionStart; [ "$host" != hermes ] || hook_event=pre_llm_call
  payload="$(jq -cn --arg cwd "$callback_repo" --arg event "$hook_event" '{cwd:$cwd,hook_event_name:$event}')"
  callback="$(printf '%s\n' "$payload" | ORCHID_OUTPUT=raw "$HOME/.orchid/frontends/$host-hook")" || fail "$host callback failed"
  if [ "$host" = hermes ]; then context="$(jq -r .context <<< "$callback")"
  else context="$(jq -r .hookSpecificOutput.additionalContext <<< "$callback")"; fi
  assert_match 'repo: fixture' "$context" "$host context injection"
done
payload="$(jq -cn --arg cwd "$callback_repo" '{cwd:$cwd,hook_event_name:"SessionStart"}')"
if [ -n "$fixture_node" ]; then
  cp "$HOME/.config/opencode/plugins/orchid.js" "$WORK/orchid.mjs"
  ORCHID_OUTPUT=raw "$fixture_node" --input-type=module - "$WORK/orchid.mjs" "$callback_repo" <<'JS' || fail 'OpenCode plugin callback failed'
import { pathToFileURL } from 'node:url';
const { OrchidPlugin } = await import(pathToFileURL(process.argv[2]));
const plugin = await OrchidPlugin({directory:process.argv[3]});
const output = {system:['foreign context']};
await plugin['experimental.chat.system.transform']({},output);
if (output.system.length!==2 || !output.system[1].includes('repo: fixture')) throw Error('context absent');
await plugin['experimental.chat.system.transform']({},output);
if (output.system.length!==2) throw Error('duplicate ambient context');
JS
fi
while IFS= read -r call; do assert_eq "$callback_repo|context --ambient" "$call" 'callback exact read-only cwd/operation'; done < "$ORCHID_FIXTURE_CALLS"
while IFS= read -r format; do assert_eq toon "$format" 'native callback explicitly forces compact agent format'; done < "$ORCHID_FIXTURE_FORMATS"
green_case 'native callbacks use compact TOON context despite inherited raw output'
[ ! -e "$WORK/repo space/.orchid" ] || fail 'callback created target state'

# RED/GREEN: host callbacks fail open for missing cwd, failed/oversized/slow
# context; valid context resumes afterwards. No actual host session is started.
assert_eq '{}' "$(printf '{}\n' | "$HOME/.orchid/frontends/claude-hook")" 'missing cwd is a no-op'
wrong_event="$(jq -cn --arg cwd "$callback_repo" '{cwd:$cwd,hook_event_name:"PreToolUse"}')"
assert_eq '{}' "$(printf '%s\n' "$wrong_event" | "$HOME/.orchid/frontends/claude-hook")" 'different host event is a no-op'
export ORCHID_FIXTURE_FAIL=1
assert_eq '{}' "$(printf '%s\n' "$payload" | "$HOME/.orchid/frontends/claude-hook")" 'context failure fails open'
unset ORCHID_FIXTURE_FAIL
export ORCHID_FIXTURE_LARGE=1
assert_eq '{}' "$(printf '%s\n' "$payload" | "$HOME/.orchid/frontends/claude-hook")" 'oversized context fails open'
unset ORCHID_FIXTURE_LARGE
export ORCHID_FIXTURE_SLOW=1
start=$SECONDS
assert_eq '{}' "$(printf '%s\n' "$payload" | "$HOME/.orchid/frontends/claude-hook")" 'slow context fails open'
[ "$((SECONDS-start))" -le 8 ] || fail 'native callback exceeded bounded timeout'
unset ORCHID_FIXTURE_SLOW
if [ -n "$fixture_node" ]; then
  for rejected in FAIL LARGE SLOW; do
    export "ORCHID_FIXTURE_$rejected=1"
    "$fixture_node" --input-type=module - "$WORK/orchid.mjs" "$callback_repo" <<'JS' || fail 'OpenCode rejected context did not fail open'
import {pathToFileURL} from 'node:url';
const {OrchidPlugin}=await import(pathToFileURL(process.argv[2]));
const plugin=await OrchidPlugin({directory:process.argv[3]});
const output={system:['foreign context']}; const start=Date.now();
await plugin['experimental.chat.system.transform']({},output);
if(output.system.length!==1 || Date.now()-start>8000) throw Error('callback did not fail open boundedly');
JS
    unset "ORCHID_FIXTURE_$rejected"
  done
fi
red_case 'invalid failed oversized and timed-out callback context is refused fail-open'
assert_match 'fixture' "$(printf '%s\n' "$payload" | "$HOME/.orchid/frontends/claude-hook")" 'valid context recovers'
green_case 'valid callback context resumes without target runtime state'

# RED/GREEN: foreign/edited files and configs are never claimed or deleted;
# removing the foreign occupant permits registration again.
cp "$HOME/.orchid/frontends/claude-hook" "$WORK/managed-hook"
printf '# foreign change\n' >> "$HOME/.orchid/frontends/claude-hook"
rc=0; run_setup --frontend claude --uninstall > /dev/null 2> "$WORK/foreign.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'uninstall deleted modified hook'
grep -q 'foreign change' "$HOME/.orchid/frontends/claude-hook" || fail 'modified hook clobbered'
red_case 'uninstall refuses a modified managed artifact'
cp "$WORK/managed-hook" "$HOME/.orchid/frontends/claude-hook"
run_setup --frontend claude > /dev/null || fail 'restored owned artifact did not recover'
green_case 'restoring exact owned artifact permits repair'

# GREEN: source relocation repairs artifact content using recorded ownership.
moved_root="$WORK/relocated ' payload"
cp -R "$fixture_root" "$moved_root"
setup="$moved_root/runners/orchid-setup"
assert_eq needs_repair "$(run_setup | jq -r '.frontends[]|select(.frontend=="codex")|.state')" 'overview detects relocated installation needing repair'
run_setup --frontend codex > /dev/null || fail 'relocation repair failed'
assert_match fixture "$(printf '%s\n' "$payload" | "$HOME/.orchid/frontends/codex-hook")" 'relocated root with quotes executes safely'
assert_eq "$(cd "$moved_root" && pwd -P)" "$(jq -r .root "$HOME/.orchid/frontends/codex.json")" 'repair records relocated source root'

# GREEN: Cellar installations register the stable opt path, never version path.
prefix="$WORK/brew"
mkdir -p "$prefix/Cellar/orchid/beta" "$prefix/opt"
cp -R "$fixture_root" "$prefix/Cellar/orchid/beta/libexec"
ln -s "$prefix/Cellar/orchid/beta" "$prefix/opt/orchid"
setup="$prefix/opt/orchid/libexec/runners/orchid-setup"
run_setup --frontend opencode > /dev/null || fail 'stable opt registration failed'
grep -Fq "$prefix/opt/orchid/libexec/bin/orchid" "$HOME/.config/opencode/plugins/orchid.js" || fail 'plugin pinned to Cellar path'

# GREEN: ownership-safe uninstall preserves unrelated host state and approvals.
for host in $hosts; do run_setup --frontend "$host" --uninstall > /dev/null || fail "$host uninstall failed"; done
assert_eq foreign-start "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOME/.codex/hooks.json")" 'foreign hook remains after uninstall'
assert_eq 1 "$(jq '.hooks.SessionStart|length' "$HOME/.codex/hooks.json")" 'only managed Codex hook removed'
assert_eq 0 "$(jq '.hooks.SessionStart|length' "$HOME/.claude/settings.json")" 'managed Claude hook removed'
[ ! -e "$HOME/.config/opencode/plugins/orchid.js" ] || fail 'owned OpenCode plugin not removed'
if [ -n "$fixture_python" ]; then
  "$fixture_python" - "$HOME/.hermes/config.yaml" <<'PY' || fail 'Hermes uninstall malformed config or removed foreign hooks'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]));assert len(d['hooks']['pre_llm_call'])==1
assert d['hooks']['pre_llm_call'][0]['command']=='foreign-turn';assert d['foreign']=='keep'
PY
fi
run_setup --frontend all --uninstall > /dev/null || fail 'repeat uninstall failed'
green_case 'native uninstall removes only recorded artifacts and hook entries'
run_setup --frontend codex >/dev/null || fail 'register before general installer uninstall failed'
(cd "$WORK/nogit" && /bin/bash "$REPO_ROOT/install.sh" --uninstall > /dev/null) || fail 'general installer native uninstall failed'
[ ! -e "$HOME/.orchid/frontends/codex-hook" ] || fail 'general installer left owned Codex native callback'
assert_eq 1 "$(jq '.hooks.SessionStart|length' "$HOME/.codex/hooks.json")" 'general uninstall preserves foreign Codex hook'

# RED: a dangling plugin symlink cannot be adopted; GREEN empty path can.
ln -s "$WORK/missing-foreign" "$HOME/.config/opencode/plugins/orchid.js"
rc=0; run_setup --frontend opencode > /dev/null 2> "$WORK/symlink.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'foreign dangling plugin symlink accepted'
assert_eq "$WORK/missing-foreign" "$(readlink "$HOME/.config/opencode/plugins/orchid.js")" 'foreign dangling plugin preserved'
run_setup --frontend opencode --uninstall > /dev/null || fail 'unregistered foreign artifact uninstall should be a no-op'
[ -L "$HOME/.config/opencode/plugins/orchid.js" ] || fail 'uninstall removed unregistered foreign symlink'
red_case 'dangling native plugin symlink is foreign-owned'
rm "$HOME/.config/opencode/plugins/orchid.js"
run_setup --frontend opencode > /dev/null || fail 'empty plugin path registration failed'
green_case 'empty plugin path accepts owned registration'

if [ -n "$fixture_python" ]; then
  # GREEN: native PyYAML covers ordinary block, flow subtree, empty and
  # indentless list layouts, including uninstall of the only managed item.
  hermes_layout() {
    local name="$1" text="$2" casehome="$WORK/yaml-$1"
    mkdir -p "$casehome/.hermes"
    printf '%s\n' "$text" > "$casehome/.hermes/config.yaml"
    HOME="$casehome" /bin/bash "$setup" --frontend hermes >/dev/null || fail "Hermes $name setup failed"
    "$fixture_python" - "$casehome/.hermes/config.yaml" <<'PY' || fail 'Hermes layout rendered invalid YAML'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1])); assert d['model']=='keep'
assert any('hermes-hook' in item['command'] for item in d['hooks']['pre_llm_call'])
PY
    HOME="$casehome" /bin/bash "$setup" --frontend hermes --uninstall >/dev/null || fail "Hermes $name uninstall failed"
    "$fixture_python" - "$casehome/.hermes/config.yaml" <<'PY' || fail 'Hermes layout uninstall rendered invalid YAML'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1])); assert d['model']=='keep'
assert isinstance(d['hooks']['pre_llm_call'],list)
assert all('hermes-hook' not in item['command'] for item in d['hooks']['pre_llm_call'])
PY
  }
  hermes_layout absent $'# foreign comment\nmodel: keep'
  hermes_layout empty_hooks $'model: keep\nhooks: {}'
  hermes_layout empty_list $'model: keep\nhooks:\n  pre_llm_call: []'
  hermes_layout other_hook $'model: keep\nhooks:\n  other_event: []'
  hermes_layout indentless $'model: keep\nhooks:\n  pre_llm_call:\n  - command: foreign-turn'
  green_case 'Hermes native YAML subtree layouts preserve foreign data and uninstall validly'
  # RED/GREEN: malformed/ambiguous YAML and unavailable native parser refuse
  # before artifacts, while the ordinary equivalent above is accepted.
  for bad in malformed duplicate alias topflow; do
    casehome="$WORK/yaml-bad-$bad"; mkdir -p "$casehome/.hermes"
    case "$bad" in
      malformed) printf 'model: keep\nhooks: [\n' > "$casehome/.hermes/config.yaml" ;;
      duplicate) printf 'model: keep\nhooks: {}\nhooks: {}\n' > "$casehome/.hermes/config.yaml" ;;
      alias) printf 'model: keep\nshared: &shared\n  pre_llm_call: []\nhooks: *shared\n' > "$casehome/.hermes/config.yaml" ;;
      topflow) printf '{model: keep}\n' > "$casehome/.hermes/config.yaml" ;;
    esac
    cp "$casehome/.hermes/config.yaml" "$WORK/yaml-bad.before"
    rc=0; HOME="$casehome" /bin/bash "$setup" --frontend hermes >/dev/null 2> "$WORK/yaml-$bad.err" || rc=$?
    [ "$rc" -ne 0 ] || fail "Hermes $bad YAML accepted"
    cmp -s "$casehome/.hermes/config.yaml" "$WORK/yaml-bad.before" || fail "Hermes $bad config changed"
    [ ! -e "$casehome/.orchid" ] || fail "Hermes $bad refusal wrote registration state"
  done
  casehome="$WORK/yaml-no-parser"; mkdir -p "$casehome"
  rc=0; HOME="$casehome" ORCHID_FRONTEND_PYTHON="$WORK/missing-python" /bin/bash "$setup" --frontend hermes >/dev/null 2> "$WORK/no-parser.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'Hermes unavailable PyYAML interpreter accepted'
  [ ! -e "$casehome/.orchid" ] || fail 'missing Hermes parser wrote registration state'
  red_case 'Hermes malformed ambiguous aliased flow-root config and missing parser refuse before writes'
fi

# RED/GREEN: Orchid's private registration directory cannot be a foreign link.
casehome="$WORK/foreign-registration-home"
mkdir -p "$casehome/.orchid" "$WORK/foreign-registration-target"
ln -s "$WORK/foreign-registration-target" "$casehome/.orchid/frontends"
rc=0; HOME="$casehome" /bin/bash "$setup" --frontend claude >/dev/null 2> "$WORK/foreign-registration.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'foreign registration directory symlink accepted'
[ ! -e "$WORK/foreign-registration-target/claude.json" ] || fail 'foreign registration directory was mutated'
red_case 'foreign private registration directory link is never followed for writes'
rm "$casehome/.orchid/frontends"
HOME="$casehome" /bin/bash "$setup" --frontend claude >/dev/null || fail 'owned registration directory creation failed'
green_case 'empty private registration path accepts explicitly selected host'

# Causal RED/GREEN: each publication boundary can fail independently. The
# pending record must permit a retry, never confer ownership over changed bytes.
cat > "$WORK/recovery-worker" <<'EOF'
#!/bin/bash
set -euo pipefail
export ORCHID_ROOT="$1"
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontend.sh"
scratch="$2"; root="$3"; phase="$4"; action="${5:-install}"
frontend_prepare claude "$action" "$scratch" "$root"
# Clone the actual shared writer; failures affect only the selected boundary.
eval "$(declare -f atomic_write | sed '1s/atomic_write/fixture_atomic_write/')"
atomic_write() {
  local destination="$1" count=0
  if [ "$destination" = "$HOME/.orchid/frontends/claude.json" ]; then
    [ ! -f "$scratch/record-count" ] || count="$(cat "$scratch/record-count")"
    count=$((count + 1)); printf '%s\n' "$count" > "$scratch/record-count"
    if { [ "$phase" = first-record ] && [ "$count" = 1 ]; } || { [ "$phase" = final-record ] && [ "$count" = 2 ]; }; then printf '%s\n' "$phase" > "$scratch/failed-phase"; return 73; fi
  fi
  if [ "$phase" = artifact ] && [ "$destination" = "$HOME/.orchid/frontends/claude-hook" ]; then printf '%s\n' "$phase" > "$scratch/failed-phase"; return 73; fi
  if { [ "$phase" = config ] || [ "$phase" = uninstall-config ]; } && [ "$destination" = "$HOME/.claude/settings.json" ]; then printf '%s\n' "$phase" > "$scratch/failed-phase"; return 73; fi
  fixture_atomic_write "$@"
}
chmod() {
  if [ "$phase" = chmod ] && [ "$2" = "$HOME/.orchid/frontends/claude-hook" ]; then printf '%s\n' "$phase" > "$scratch/failed-phase"; return 73; fi
  command chmod "$@"
}
rm() {
  if [ "$phase" = remove-artifact ] && [ "$2" = "$HOME/.orchid/frontends/claude-hook" ]; then
    # Real rm continues to its next operand after one removal fails. Preserve
    # that behavior so a multi-operand removal loses its record in the RED twin.
    [ "$#" -le 2 ] || command rm -f "$3"
    printf '%s\n' "$phase" > "$scratch/failed-phase"; return 73
  fi
  if [ "$phase" = remove-record ] && [ "$2" = "$HOME/.orchid/frontends/claude.json" ]; then printf '%s\n' "$phase" > "$scratch/failed-phase"; return 73; fi
  command rm "$@"
}
frontend_apply claude "$action" "$scratch"
EOF
for phase in first-record artifact chmod config final-record; do
  casehome="$WORK/recovery-$phase"; scratch="$WORK/recovery-scratch-$phase"
  mkdir -p "$casehome/.claude" "$scratch"
  printf '{"theme":"keep"}\n' > "$casehome/.claude/settings.json"
  cp "$casehome/.claude/settings.json" "$scratch/config-before"
  rc=0; HOME="$casehome" /bin/bash "$WORK/recovery-worker" "$fixture_root" "$scratch" "$fixture_root" "$phase" > "$scratch/out" 2> "$scratch/err" || rc=$?
  assert_eq 1 "$rc" "$phase publication failure rejects"
  assert_eq "$phase" "$(cat "$scratch/failed-phase")" "$phase exact publication failure exercised"
  if [ "$phase" = first-record ]; then
    [ ! -e "$casehome/.orchid/frontends/claude.json" ] || fail 'failed first record published ownership'
    [ ! -e "$casehome/.orchid/frontends/claude-hook" ] || fail 'failed first record enabled artifact'
  else
    assert_eq true "$(jq -r .pending "$casehome/.orchid/frontends/claude.json")" "$phase leaves explicit pending ownership"
    assert_eq true "$(HOME="$casehome" /bin/bash "$setup" | jq -r '.frontends[]|select(.frontend=="claude")|.pending')" "$phase overview exposes pending work"
  fi
  if [ "$phase" = artifact ]; then [ ! -e "$casehome/.orchid/frontends/claude-hook" ] || fail 'failed artifact writer published hook'; fi
  if [ "$phase" != final-record ]; then cmp -s "$scratch/config-before" "$casehome/.claude/settings.json" || fail "$phase failure altered native configuration"; fi
  red_case "frontend publication failure at $phase is recorded before dependent effects"
  HOME="$casehome" /bin/bash "$setup" --frontend claude >/dev/null || fail "$phase normal retry refused owned partial registration"
  assert_eq registered "$(HOME="$casehome" /bin/bash "$setup" | jq -r '.frontends[]|select(.frontend=="claude")|.state')" "$phase retry finishes registration"
  jq -e 'has("pending")|not' "$casehome/.orchid/frontends/claude.json" >/dev/null || fail "$phase retry retained pending marker"
  jq -e 'has("previous_content")|not' "$casehome/.orchid/frontends/claude.json" >/dev/null || fail "$phase retry retained obsolete artifact ownership"
  assert_eq keep "$(jq -r .theme "$casehome/.claude/settings.json")" "$phase retry preserves foreign settings"
  [ -x "$casehome/.orchid/frontends/claude-hook" ] || fail "$phase retry did not repair executable mode"
  green_case "frontend normal retry completes $phase interruption"
done

# Interrupted relocation may retain the exact old owned wrapper, but no other
# bytes. A pending registration also remains ownership-safe to uninstall.
casehome="$WORK/recovery-relocation"; scratch="$WORK/recovery-relocation-scratch"
mkdir -p "$casehome/.claude" "$scratch"
printf '{"theme":"keep"}\n' > "$casehome/.claude/settings.json"
HOME="$casehome" /bin/bash "$setup" --frontend claude >/dev/null || fail 'recovery relocation baseline'
cp "$casehome/.orchid/frontends/claude-hook" "$scratch/owned-before"
rc=0; HOME="$casehome" /bin/bash "$WORK/recovery-worker" "$fixture_root" "$scratch" "$WORK/relocated recovery root" artifact >/dev/null 2> "$scratch/err" || rc=$?
assert_eq 1 "$rc" 'relocation artifact publication interrupted'
assert_eq artifact "$(cat "$scratch/failed-phase")" 'relocation failure reaches exact artifact boundary'
assert_eq true "$(jq -r .pending "$casehome/.orchid/frontends/claude.json")" 'relocation retains pending record'
cmp -s "$scratch/owned-before" "$casehome/.orchid/frontends/claude-hook" || fail 'failed relocation changed old wrapper'
printf 'foreign changed wrapper\n' > "$casehome/.orchid/frontends/claude-hook"
cp "$casehome/.orchid/frontends/claude.json" "$scratch/pending-before"
for action in install uninstall; do
  rc=0
  if [ "$action" = uninstall ]; then HOME="$casehome" /bin/bash "$setup" --frontend claude --uninstall >/dev/null 2> "$scratch/foreign-$action.err" || rc=$?
  else HOME="$casehome" /bin/bash "$setup" --frontend claude >/dev/null 2> "$scratch/foreign-$action.err" || rc=$?; fi
  [ "$rc" -ne 0 ] || fail "pending ownership claimed foreign bytes during $action"
  assert_eq 'foreign changed wrapper' "$(cat "$casehome/.orchid/frontends/claude-hook")" "pending $action preserved foreign artifact"
  cmp -s "$scratch/pending-before" "$casehome/.orchid/frontends/claude.json" || fail "pending $action changed ownership on refusal"
done
red_case 'pending relocation refuses foreign bytes during retry and uninstall'
cp "$scratch/owned-before" "$casehome/.orchid/frontends/claude-hook"
rm "$scratch/record-count"
HOME="$casehome" /bin/bash "$WORK/recovery-worker" "$fixture_root" "$scratch" "$WORK/relocated recovery root" none >/dev/null || fail 'exact old owned wrapper could not repair relocation'
assert_eq "$WORK/relocated recovery root" "$(jq -r .root "$casehome/.orchid/frontends/claude.json")" 'relocation retry installs desired root'
green_case 'pending relocation repairs only exact previously owned artifact'
rm "$scratch/record-count"
rc=0; HOME="$casehome" /bin/bash "$WORK/recovery-worker" "$fixture_root" "$scratch" "$fixture_root" final-record >/dev/null 2> "$scratch/final.err" || rc=$?
assert_eq 1 "$rc" 'pending uninstall baseline finalization interrupted'
assert_eq final-record "$(cat "$scratch/failed-phase")" 'pending uninstall reaches exact final-record boundary'
HOME="$casehome" /bin/bash "$setup" --frontend claude --uninstall >/dev/null || fail 'pending owned registration could not uninstall'
[ ! -e "$casehome/.orchid/frontends/claude-hook" ] && [ ! -e "$casehome/.orchid/frontends/claude.json" ] || fail 'pending uninstall left owned artifact or record'
assert_eq keep "$(jq -r .theme "$casehome/.claude/settings.json")" 'pending uninstall preserves foreign settings'
assert_eq 0 "$(jq '.hooks.SessionStart|length' "$casehome/.claude/settings.json")" 'pending uninstall removes only owned native entry'
green_case 'pending working registration can be safely uninstalled'

for phase in uninstall-config remove-artifact remove-record; do
  casehome="$WORK/recovery-$phase"; scratch="$WORK/recovery-scratch-$phase"
  mkdir -p "$casehome/.claude" "$scratch"
  printf '{"theme":"keep"}\n' > "$casehome/.claude/settings.json"
  HOME="$casehome" /bin/bash "$setup" --frontend claude >/dev/null || fail "$phase baseline registration"
  rc=0; HOME="$casehome" /bin/bash "$WORK/recovery-worker" "$fixture_root" "$scratch" "$fixture_root" "$phase" uninstall >/dev/null 2> "$scratch/err" || rc=$?
  assert_eq 1 "$rc" "$phase interrupted uninstall refuses"
  assert_eq "$phase" "$(cat "$scratch/failed-phase")" "$phase exact uninstall boundary exercised"
  [ -f "$casehome/.orchid/frontends/claude.json" ] || fail "$phase interrupted uninstall lost ownership record"
  if [ "$phase" = remove-record ]; then [ ! -e "$casehome/.orchid/frontends/claude-hook" ] || fail 'record removal failure did not follow successful artifact removal'
  else [ -f "$casehome/.orchid/frontends/claude-hook" ] || fail "$phase failure prematurely removed artifact"; fi
  red_case "interrupted uninstall at $phase retains ownership until removal completes"
  HOME="$casehome" /bin/bash "$setup" --frontend claude --uninstall >/dev/null || fail "$phase uninstall retry refused owned partial state"
  [ ! -e "$casehome/.orchid/frontends/claude-hook" ] && [ ! -e "$casehome/.orchid/frontends/claude.json" ] || fail "$phase uninstall retry left owned files"
  assert_eq keep "$(jq -r .theme "$casehome/.claude/settings.json")" "$phase uninstall retry preserved foreign settings"
  assert_eq 0 "$(jq '.hooks.SessionStart|length' "$casehome/.claude/settings.json")" "$phase uninstall retry removed owned entry"
  green_case "normal uninstall retry completes $phase interruption"
done

# Couple generated native callbacks to the real public context command. A
# project-provided helper must never run in an ambient session integration.
# Context also fails open when a project input aliases an external file.
native_root="$WORK/native-runtime"
native_home="$WORK/native-runtime-home"
native_repo="$WORK/native-runtime-repo"
native_neutral="$WORK/native-stale-repo"
mkdir -p "$native_root" "$native_home" "$native_repo/.orchid/tasks" "$native_repo/.orchid/runtime" "$native_repo/tools" "$native_neutral"
for dir in bin lib libexec runners release; do cp -R "$REPO_ROOT/$dir" "$native_root/"; done
printf '%s\n' '---' 'run_id: native-owned-fixture' 'run_status: active' '---' > "$native_repo/.orchid/roadmap.md"
printf '1\n' > "$native_repo/.orchid/runtime/epoch"
assert_eq '' "$(cd "$native_repo" && ORCHID_REPO="$native_neutral" ORCHID_OUTPUT=toon "$native_root/bin/orchid" context --ambient)" \
  'ordinary ambient CLI retains explicit repository override semantics'
red_case 'stale inherited ORCHID_REPO suppresses owned project context without callback scoping'
native_hosts='claude codex opencode'
[ -z "$fixture_python" ] || native_hosts="$native_hosts hermes"
for host in $native_hosts; do
  HOME="$native_home" ORCHID_FRONTEND_PYTHON="$fixture_python" /bin/bash "$native_root/runners/orchid-setup" --frontend "$host" > "$WORK/native-$host-setup.json" \
    || fail "real native context fixture setup failed: $host"
done
native_operator_path="$PATH"
export ORCHID_FRONTEND_HELPER_MARKER="$WORK/native-helper.executed"
for tool in jq git; do
  native_real_tool="$(command -v "$tool")"
  printf '#!/bin/bash\nprintf "%%s\\n" %q >> "$ORCHID_FRONTEND_HELPER_MARKER"\nexec %q "$@"\n' "$tool" "$native_real_tool" > "$native_repo/tools/$tool"
  chmod 755 "$native_repo/tools/$tool"
done
"$native_repo/tools/jq" -n null >/dev/null
"$native_repo/tools/git" --version >/dev/null
assert_eq $'jq\ngit' "$(cat "$ORCHID_FRONTEND_HELPER_MARKER")" 'project-helper control actually reaches both marker proxies'
rm "$ORCHID_FRONTEND_HELPER_MARKER"

native_callback_shell() {
  local host="$1" phase="$2" event=SessionStart payload
  [ "$host" != hermes ] || event=pre_llm_call
  payload="$(jq -cn --arg cwd "$native_repo" --arg event "$event" '{cwd:$cwd,hook_event_name:$event}')"
  printf '%s\n' "$payload" | HOME="$native_home" ORCHID_REPO="$native_neutral" ORCHID_OUTPUT=raw PATH="$native_repo/tools:$native_operator_path" \
    "$native_home/.orchid/frontends/$host-hook" > "$WORK/native-$phase-$host.json" 2> "$WORK/native-$phase-$host.err" \
    || fail "native callback failed its optional host protocol: $phase $host"
}
native_callback_opencode() {
  local phase="$1"
  [ -n "$fixture_node" ] || return 0
  cp "$native_home/.config/opencode/plugins/orchid.js" "$WORK/native-orchid.mjs"
  HOME="$native_home" ORCHID_REPO="$native_neutral" ORCHID_OUTPUT=raw PATH="$native_repo/tools:$native_operator_path" \
    "$fixture_node" --input-type=module - "$WORK/native-orchid.mjs" "$native_repo" <<'JS' > "$WORK/native-$phase-opencode.json" 2> "$WORK/native-$phase-opencode.err" || fail "real OpenCode context callback failed: $phase"
import {pathToFileURL} from 'node:url';
const {OrchidPlugin}=await import(pathToFileURL(process.argv[2]));
const plugin=await OrchidPlugin({directory:process.argv[3]});
const output={system:['foreign context']};
await plugin['experimental.chat.system.transform']({},output);
console.log(JSON.stringify(output));
JS
}
cp -R "$native_repo/.orchid" "$WORK/native-owned-state.before"
for host in claude codex hermes; do
  [ "$host" != hermes ] || [ -n "$fixture_python" ] || continue
  native_callback_shell "$host" owned
  if [ "$host" = hermes ]; then native_context="$(jq -r '.context // ""' "$WORK/native-owned-$host.json")"
  else native_context="$(jq -r '.hookSpecificOutput.additionalContext // ""' "$WORK/native-owned-$host.json")"; fi
  assert_match 'native-owned-fixture' "$native_context" "owned real context reaches $host native transport"
  assert_match 'tasks:' "$native_context" "owned real context remains compact agent format for $host"
done
native_callback_opencode owned
if [ -n "$fixture_node" ]; then
  jq -e '.system|length==2' "$WORK/native-owned-opencode.json" >/dev/null || fail 'owned real context did not reach OpenCode'
  assert_match 'native-owned-fixture' "$(jq -r '.system[1] // ""' "$WORK/native-owned-opencode.json")" 'OpenCode owned context is the real compact dashboard'
fi
[ ! -e "$ORCHID_FRONTEND_HELPER_MARKER" ] || fail 'ambient native callback ran a project-owned jq or Git helper'
diff -r "$WORK/native-owned-state.before" "$native_repo/.orchid" >/dev/null || fail 'owned native callbacks mutated project state'
green_case 'generated native callbacks scope owned real context to host directory despite stale repository override, use trusted helpers, and preserve state'

printf '%s\n' '---' 'run_id: ORCHID_FAKE_NATIVE_EXTERNAL_SECRET' 'run_status: active' '---' > "$WORK/native-external-roadmap"
mv "$native_repo/.orchid/roadmap.md" "$WORK/native-owned-roadmap"
ln -s "$WORK/native-external-roadmap" "$native_repo/.orchid/roadmap.md"
cp -R "$native_repo/.orchid" "$WORK/native-unsafe-state.before"
for host in claude codex hermes; do
  [ "$host" != hermes ] || [ -n "$fixture_python" ] || continue
  native_callback_shell "$host" unsafe
  assert_eq '{}' "$(cat "$WORK/native-unsafe-$host.json")" "unsafe real context fails open for $host"
done
native_callback_opencode unsafe
if [ -n "$fixture_node" ]; then
  jq -e '.system==["foreign context"]' "$WORK/native-unsafe-opencode.json" >/dev/null || fail 'unsafe real context reached OpenCode prompt'
fi
if grep -F 'ORCHID_FAKE_NATIVE_EXTERNAL_SECRET' "$WORK"/native-unsafe-*.json "$WORK"/native-unsafe-*.err; then fail 'native callback disclosed external input content'; fi
[ ! -e "$ORCHID_FRONTEND_HELPER_MARKER" ] || fail 'unsafe native callback ran a project-owned helper'
diff -r "$WORK/native-unsafe-state.before" "$native_repo/.orchid" >/dev/null || fail 'unsafe native callbacks mutated project state'
[ ! -e "$native_home/.orchid/requests" ] || fail 'ambient callbacks created retry cache'
red_case 'generated native callbacks reject linked external input without disclosure helper execution or state writes'
