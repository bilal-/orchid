#!/usr/bin/env bash
# Explicit, user-scoped frontend registration. No repository state is touched.
frontend_root() {
  local root="$ORCHID_ROOT" opt
  case "$root" in
    */Cellar/orchid/*/libexec)
      opt="${root%/Cellar/orchid/*}/opt/orchid/libexec"
      if [ -d "$opt" ] && [ "$(orchid_physical_dir "$opt")" = "$(orchid_physical_dir "$root")" ]; then root="$opt"; fi
      ;;
  esac
  printf '%s\n' "$root"
}

frontend_link_one() {
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" != "$src" ]; then
      printf 'orchid: skip (foreign symlink, left alone): %s -> %s\n' "$dest" "$(readlink "$dest")" >&2
      return 0
    fi
    return 0
  elif [ -e "$dest" ]; then
    printf 'orchid: skip (not symlink, left alone): %s\n' "$dest" >&2
    return 0
  fi
  mkdir -p "$(dirname "$dest")" || return 1
  ln -s "$src" "$dest" || return 1
  printf 'linked: %s -> %s\n' "$dest" "$src"
}

frontend_unlink_one() {
  local src="$1" dest="$2"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    rm -f "$dest" || return 1
    printf 'removed: %s\n' "$dest"
  fi
}

frontend_paths() {
  FRONTEND_HOST="$1"
  FRONTEND_RECORD="$HOME/.orchid/frontends/$1.json"
  FRONTEND_ARTIFACT="$HOME/.orchid/frontends/$1-hook"
  FRONTEND_EVENT=SessionStart
  case "$1" in
    claude) FRONTEND_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ;;
    codex) FRONTEND_CONFIG="${CODEX_HOME:-$HOME/.codex}/hooks.json" ;;
    hermes) FRONTEND_CONFIG="${HERMES_HOME:-$HOME/.hermes}/config.yaml"; FRONTEND_EVENT=pre_llm_call ;;
    opencode) FRONTEND_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/orchid.js"; FRONTEND_ARTIFACT="$FRONTEND_CONFIG" ;;
    *) orchid_die "unknown frontend '$1' (expected claude, codex, hermes, opencode or all)" ;;
  esac
}

frontend_python() {
  local candidate
  if [ -n "${ORCHID_FRONTEND_PYTHON:-}" ]; then
    candidate="$ORCHID_FRONTEND_PYTHON"
    [ -x "$candidate" ] && "$candidate" -c 'import yaml' >/dev/null 2>&1 || orchid_die 'ORCHID_FRONTEND_PYTHON must be an executable Python with PyYAML'
    printf '%s\n' "$candidate"; return
  fi
  for candidate in "${HERMES_HOME:-$HOME/.hermes}/hermes-agent/venv/bin/python" "${HERMES_HOME:-$HOME/.hermes}/hermes-agent/.venv/bin/python" "$(command -v python3 || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -c 'import yaml' >/dev/null 2>&1; then printf '%s\n' "$candidate"; return; fi
  done
  orchid_die 'Hermes setup requires its Python runtime with PyYAML; set ORCHID_FRONTEND_PYTHON to that interpreter'
}

frontend_entry() {
  local command
  command="$(jq -rn --arg path "$FRONTEND_ARTIFACT" '$path | @sh')"
  if [ "$FRONTEND_HOST" = hermes ]; then
    jq -cn --arg command "$command" '{command:$command,timeout:5}'
  else
    jq -cn --arg command "$command" '{matcher:"",hooks:[{type:"command",command:$command,timeout:5}]}'
  fi
}

frontend_artifact() {
  local root="$1" quoted
  if [ "$FRONTEND_HOST" = opencode ]; then
    quoted="$(jq -Rn --arg path "$root/bin/orchid" '$path')"
    cat <<EOF
// Orchid managed frontend: read-only context; no model or runtime launches.
import { execFileSync } from "node:child_process";
export const OrchidPlugin = async ({ directory }) => ({
  "experimental.chat.system.transform": async (_input, output) => {
    try {
      const context = execFileSync($quoted, ["context", "--ambient"], {
        cwd: directory, timeout: 3000, maxBuffer: 8192,
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]
      }).trim();
      if (context && !output.system.includes(context)) output.system.push(context);
    } catch { /* Optional context must never prevent a host turn. */ }
  }
});
EOF
  else
    quoted="$(jq -rn --arg path "$root/runners/orchid-setup" '$path | @sh')"
    printf '#!/bin/bash -p\nexec /bin/bash -p %s --hook %s\n' "$quoted" "$FRONTEND_HOST"
  fi
}

frontend_record_read() {
  FRONTEND_OLD='null'
  [ ! -L "$HOME/.orchid/frontends" ] || orchid_die "refusing foreign registration directory symlink: $HOME/.orchid/frontends"
  [ ! -L "$FRONTEND_RECORD" ] || orchid_die "refusing symlink registration record: $FRONTEND_RECORD"
  if [ -e "$FRONTEND_RECORD" ]; then
    [ -f "$FRONTEND_RECORD" ] || orchid_die "invalid registration record: $FRONTEND_RECORD"
    FRONTEND_OLD="$(frontend_record_json "$FRONTEND_RECORD" "$FRONTEND_HOST")" || orchid_die "malformed registration record: $FRONTEND_RECORD"
    [ "$(jq -r .artifact <<< "$FRONTEND_OLD")" = "$FRONTEND_ARTIFACT" ] && [ "$(jq -r .config <<< "$FRONTEND_OLD")" = "$FRONTEND_CONFIG" ] || orchid_die "frontend profile moved; uninstall from its previous profile before registering: $FRONTEND_HOST"
  fi
}

frontend_record_json() {
  jq -ce --arg host "$2" '
    select(.contract == 1 and .host == $host and (.artifact|type)=="string" and (.content|type)=="string" and (.config|type)=="string" and
      (.pending == null or (.pending|type)=="boolean") and
      (.previous_content == null or (.previous_content|type)=="string"))' "$1"
}

frontend_parent_check() {
  local parent
  parent="$(dirname "$1")"
  while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do parent="$(dirname "$parent")"; done
  [ -d "$parent" ] && [ -w "$parent" ] || orchid_die "frontend destination parent is not a writable directory: $parent"
}

frontend_artifact_check() {
  local expected actual
  FRONTEND_ARTIFACT_OWNED_CONTENT='null'
  [ ! -L "$FRONTEND_ARTIFACT" ] || orchid_die "refusing foreign symlink: $FRONTEND_ARTIFACT"
  if [ -e "$FRONTEND_ARTIFACT" ]; then
    [ -f "$FRONTEND_ARTIFACT" ] && [ "$FRONTEND_OLD" != null ] || orchid_die "refusing foreign frontend file: $FRONTEND_ARTIFACT"
    expected="$(jq -r .content <<< "$FRONTEND_OLD" | _orchid_stream_sha256)" || return 1
    actual="$(_orchid_stream_sha256 < "$FRONTEND_ARTIFACT")" || return 1
    if [ "$actual" = "$expected" ]; then
      FRONTEND_ARTIFACT_OWNED_CONTENT="$(jq -c .content <<< "$FRONTEND_OLD")"
    elif [ "$(jq -r '.pending // false' <<< "$FRONTEND_OLD")" = true ] && [ "$(jq -r '.previous_content|type' <<< "$FRONTEND_OLD")" = string ]; then
      expected="$(jq -r .previous_content <<< "$FRONTEND_OLD" | _orchid_stream_sha256)" || return 1
      [ "$actual" = "$expected" ] || orchid_die "frontend file changed outside Orchid; left untouched: $FRONTEND_ARTIFACT"
      FRONTEND_ARTIFACT_OWNED_CONTENT="$(jq -c .previous_content <<< "$FRONTEND_OLD")"
    else
      orchid_die "frontend file changed outside Orchid; left untouched: $FRONTEND_ARTIFACT"
    fi
  fi
}

frontend_json_render() {
  local action="$1" entry="$2" input='{}' oldentry='null'
  [ ! -L "$FRONTEND_CONFIG" ] || orchid_die "refusing symlink frontend config: $FRONTEND_CONFIG"
  if [ -e "$FRONTEND_CONFIG" ]; then
    [ -f "$FRONTEND_CONFIG" ] || orchid_die "invalid frontend config: $FRONTEND_CONFIG"
    input="$(cat "$FRONTEND_CONFIG")"
  fi
  if [ "$FRONTEND_OLD" != null ]; then oldentry="$(jq -c .entry <<< "$FRONTEND_OLD")"; fi
  jq -e --arg event "$FRONTEND_EVENT" --arg action "$action" --argjson entry "$entry" --argjson old "$oldentry" '
    if type != "object" or (.hooks? != null and (.hooks|type)!="object") or (.hooks[$event]? != null and (.hooks[$event]|type)!="array") then error("invalid hooks configuration") else . end |
    (.hooks[$event] // []) as $items |
    ($entry.hooks[0].command) as $command |
    if $old != null and ([$items[]|select(.==$old)]|length)>1 then error("duplicate managed hook is ambiguous") else . end |
    if any($items[]; . != $old and any(.hooks[]?; .command? == $command)) then error("existing Orchid command changed or is foreign-owned") else . end |
    if $action == "uninstall" and $old == null then .
    elif $action == "uninstall" then .hooks[$event] = [$items[] | select(. != $old)]
    else .hooks[$event] = ([$items[] | select(. != $old)] + [$entry]) end
  ' <<< "$input" || orchid_die "malformed or foreign-owned hooks in $FRONTEND_CONFIG; no settings changed"
}

# PyYAML is Hermes' native configuration parser. Edit only the selected sequence
# using its marked nodes, keeping all unrelated config bytes and comments intact.
frontend_yaml_render() {
  local action="$1" entry="$2" python oldentry='null'
  [ ! -L "$FRONTEND_CONFIG" ] || orchid_die "refusing symlink frontend config: $FRONTEND_CONFIG"
  [ ! -e "$FRONTEND_CONFIG" ] || [ -f "$FRONTEND_CONFIG" ] || orchid_die "invalid frontend config: $FRONTEND_CONFIG"
  python="$(frontend_python)" || return 1
  if [ "$FRONTEND_OLD" != null ]; then oldentry="$(jq -c .entry <<< "$FRONTEND_OLD")"; fi
  "$python" - "$FRONTEND_CONFIG" "$action" "$entry" "$oldentry" <<'PY'
import json, os, sys, yaml
path, action, entry_json, old_json = sys.argv[1:]
entry, old = json.loads(entry_json), json.loads(old_json)
try:
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    data = yaml.safe_load(text) if text.strip() else {}
    if not isinstance(data, dict): raise ValueError("config must be a mapping")
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict): raise ValueError("hooks must be a mapping")
    items = hooks.get("pre_llm_call", [])
    if not isinstance(items, list): raise ValueError("pre_llm_call must be a list")
    if any(not isinstance(item, dict) for item in items): raise ValueError("pre_llm_call entries must be mappings")
    if old is not None and items.count(old)>1: raise ValueError("duplicate managed hook is ambiguous")
    for item in items:
        if isinstance(item, dict) and item.get("command") == entry["command"] and item != old:
            raise ValueError("existing Orchid command changed or is foreign-owned")
    if action == "uninstall" and (old is None or old not in items):
        sys.stdout.write(text); sys.exit(0)
    new = [x for x in items if x != old]
    if action != "uninstall": new.append(entry)
    if items == new: sys.stdout.write(text); sys.exit(0)
    node = yaml.compose(text) if text.strip() else None
    def child(mapping, key):
        if not isinstance(mapping, yaml.MappingNode): return None
        found = [(k,v) for k,v in mapping.value if k.value == key]
        if len(found)>1: raise ValueError("duplicate " + key + " key")
        if found and found[0][1].start_mark.index < found[0][0].end_mark.index:
            raise ValueError("aliased " + key + " requires an explicit mapping/list before setup")
        return found[0][1] if found else None
    hooknode = child(node, "hooks")
    seq = child(hooknode, "pre_llm_call")
    if seq is not None and not seq.flow_style:
        # Existing block sequence: retain foreign entries verbatim, remove only
        # the previously recorded value's source span, then append our entry.
        lines = text.splitlines(keepends=True)
        edits = []
        for index, item in enumerate(items):
            if old is not None and item == old:
                start = seq.value[index].start_mark.line
                end = seq.value[index+1].start_mark.line if index+1 < len(items) else seq.end_mark.line
                edits.append((start, end))
        insertion = seq.end_mark.line
        indent = seq.start_mark.column
        appended = ""
        if action != "uninstall":
            appended = "".join(" " * indent + line + "\n" for line in yaml.safe_dump([entry], sort_keys=False).splitlines())
        for start, end in reversed(edits): del lines[start:end]; insertion -= end-start
        if appended: lines.insert(insertion, appended)
        # YAML requires a valid empty sequence after removing its only item.
        if not new:
            keynode = next(k for k,v in hooknode.value if k.value=="pre_llm_call")
            lines.insert(keynode.start_mark.line+1, " " * max(indent,keynode.start_mark.column+2) + "[]\n")
        sys.stdout.write("".join(lines))
    elif seq is not None:
        replacement = yaml.safe_dump(new, default_flow_style=True, width=100000, sort_keys=False).strip()
        sys.stdout.write(text[:seq.start_mark.index] + replacement + text[seq.end_mark.index:])
    elif hooknode is not None and not hooknode.flow_style:
        indent = hooknode.start_mark.column
        fragment = yaml.safe_dump({"pre_llm_call":new}, sort_keys=False)
        addition = "".join(" " * indent + line + "\n" for line in fragment.splitlines())
        at = hooknode.end_mark.index
        sys.stdout.write(text[:at] + addition + text[at:])
    elif hooknode is not None:
        hooks["pre_llm_call"] = new
        replacement = yaml.safe_dump(hooks, default_flow_style=True, width=100000, sort_keys=False).strip()
        sys.stdout.write(text[:hooknode.start_mark.index] + replacement + text[hooknode.end_mark.index:])
    elif node is None or (isinstance(node, yaml.MappingNode) and not node.flow_style):
        fragment = yaml.safe_dump({"hooks":{"pre_llm_call":new}}, sort_keys=False)
        sys.stdout.write(text + ("\n" if text and not text.endswith("\n") else "") + fragment)
    else: raise ValueError("top-level flow YAML is unsupported; use a block mapping before setup")
except (ValueError, OSError, yaml.YAMLError) as exc:
    print("orchid: malformed or unsupported Hermes config; no settings changed: " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
}

frontend_prepare() {
  local host="$1" action="$2" scratch="$3" root="$4" entry content
  frontend_paths "$host"
  frontend_record_read
  if [ "$action" = uninstall ] && [ "$FRONTEND_OLD" = null ]; then return 0; fi
  frontend_artifact_check
  frontend_parent_check "$FRONTEND_RECORD"
  frontend_parent_check "$FRONTEND_ARTIFACT"
  frontend_parent_check "$FRONTEND_CONFIG"
  content="$(frontend_artifact "$root")" || return 1
  entry='null'
  if [ "$host" != opencode ]; then
    entry="$(frontend_entry)" || return 1
    if [ "$host" = hermes ]; then frontend_yaml_render "$action" "$entry" > "$scratch/$host.config" || return 1
    else frontend_json_render "$action" "$entry" > "$scratch/$host.config" || return 1; fi
  fi
  jq -cn --arg host "$host" --arg artifact "$FRONTEND_ARTIFACT" --arg content "$content" --arg config "$FRONTEND_CONFIG" --arg root "$root" --argjson entry "$entry" --argjson previous_content "$FRONTEND_ARTIFACT_OWNED_CONTENT" '{contract:1,host:$host,artifact:$artifact,content:$content,config:$config,root:$root,entry:$entry,previous_content:$previous_content}' > "$scratch/$host.record"
}

frontend_apply() {
  local host="$1" action="$2" scratch="$3"
  frontend_paths "$host"
  if [ "$action" = uninstall ]; then
    [ -f "$FRONTEND_RECORD" ] || return 0
    if [ "$host" != opencode ] && [ -f "$FRONTEND_CONFIG" ]; then atomic_write "$FRONTEND_CONFIG" < "$scratch/$host.config" || return 1; fi
    # Keep the ownership record until the artifact removal succeeds. A single
    # multi-operand rm can delete the record despite failing its first operand.
    rm -f "$FRONTEND_ARTIFACT" || return 1
    rm -f "$FRONTEND_RECORD" || return 1
  else
    mkdir -p "$(dirname "$FRONTEND_RECORD")" "$(dirname "$FRONTEND_ARTIFACT")" "$(dirname "$FRONTEND_CONFIG")" || return 1
    # Reserve exact ownership before publishing a callback or host entry. The
    # pending record also binds the previously verified bytes during relocation.
    # Any failed phase can then be retried or safely uninstalled.
    jq '. + {pending:true}' "$scratch/$host.record" | atomic_write "$FRONTEND_RECORD" || return 1
    jq -r .content "$scratch/$host.record" | atomic_write "$FRONTEND_ARTIFACT" || return 1
    if [ "$host" != opencode ]; then chmod 700 "$FRONTEND_ARTIFACT" || return 1; atomic_write "$FRONTEND_CONFIG" < "$scratch/$host.config" || return 1; fi
    jq 'del(.pending,.previous_content)' "$scratch/$host.record" | atomic_write "$FRONTEND_RECORD" || return 1
  fi
}

frontend_overview() {
  local host record config state root rows='[]' old python entry pending
  root="$(frontend_root)" || return 1
  for host in claude codex hermes opencode; do
    frontend_paths "$host"; record="$FRONTEND_RECORD"; config="$FRONTEND_CONFIG"; state=unregistered
    if [ -f "$record" ] && [ ! -L "$record" ]; then
      old="$(frontend_record_json "$record" "$host" 2>/dev/null)" || old='null'
      if [ "$old" = null ]; then state=invalid_record
      elif [ "$(jq -r .artifact <<< "$old")" != "$FRONTEND_ARTIFACT" ] || [ "$(jq -r .config <<< "$old")" != "$config" ]; then state=profile_changed
      elif [ ! -f "$FRONTEND_ARTIFACT" ] || [ -L "$FRONTEND_ARTIFACT" ]; then state=missing_or_foreign_artifact
      else
        state=registered
        if ! ( FRONTEND_OLD="$old"; frontend_artifact_check ) 2>/dev/null; then state=changed_artifact
        elif [ "$host" != opencode ]; then
          entry="$(jq -c .entry <<< "$old")"
          if [ ! -f "$config" ] || [ -L "$config" ]; then state=missing_or_foreign_config
          elif [ "$host" = hermes ]; then
            python="$(frontend_python 2>/dev/null)" || python=''
            if [ -z "$python" ]; then state=recorded_yaml_not_verified
            elif ! "$python" - "$config" "$entry" <<'PY' >/dev/null 2>&1
import json,sys,yaml
try:
    data=yaml.safe_load(open(sys.argv[1]))
    entry=json.loads(sys.argv[2])
    assert data['hooks']['pre_llm_call'].count(entry)==1
except (AssertionError, KeyError, TypeError, ValueError, OSError, yaml.YAMLError):
    sys.exit(1)
PY
            then state=missing_or_changed_hook; fi
          elif ! jq -e --argjson entry "$entry" '([.hooks.SessionStart[]?|select(.==$entry)]|length)==1' "$config" >/dev/null 2>&1; then state=missing_or_changed_hook; fi
        fi
        if [ "$state" = registered ] && [ "$(jq -r '.pending // false' <<< "$old")" = true ]; then state=pending_registration; fi
        if [ "$state" = registered ] && [ "$(jq -r .root <<< "$old")" != "$root" ]; then state=needs_repair; fi
      fi
    elif [ -e "$record" ] || [ -L "$record" ]; then state=invalid_record
    fi
    pending=false
    if [ -f "$record" ] && [ ! -L "$record" ]; then pending="$(jq -r '.pending == true' "$record" 2>/dev/null)" || pending=false; fi
    rows="$(jq -c --arg host "$host" --arg state "$state" --arg config "$config" --arg record "$record" --argjson pending "$pending" '. + [{frontend:$host,state:$state,config:$config,record:$record,pending:$pending,trust:"host_owned_not_verified"}]' <<< "$rows")" || return 1
  done
  jq -cn --arg root "$root" --argjson frontends "$rows" '{operation:"setup",mode:"overview",root:$root,frontends:$frontends,next:"orchid setup --frontend claude|codex|hermes|opencode|all; host-native trust remains required"}'
}

frontend_hook() {
  local host="$1" payload cwd event expected_event context='' LC_ALL=C
  payload="$(cat)" || payload='{}'
  case "$host" in claude|codex) expected_event=SessionStart ;; hermes) expected_event=pre_llm_call ;; *) return 0 ;; esac
  event="$(jq -er '.hook_event_name | select(type=="string")' <<< "$payload" 2>/dev/null)" || event=''
  if [ "$event" != "$expected_event" ]; then printf '{}\n'; return 0; fi
  cwd="$(jq -er '.cwd | select(type=="string" and length>0)' <<< "$payload" 2>/dev/null)" || cwd=''
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    context="$(cd "$cwd" && with_timeout 3 "$ORCHID_ROOT/bin/orchid" context --ambient 2>/dev/null)" || context=''
  fi
  [ "${#context}" -le 8192 ] || context=''
  if [ -z "$context" ]; then printf '{}\n'; return 0; fi
  case "$host" in
    claude|codex) jq -cn --arg context "$context" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$context}}' ;;
    hermes) jq -cn --arg context "$context" '{context:$context}' ;;
    *) return 0 ;;
  esac
}
