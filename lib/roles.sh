#!/usr/bin/env bash
# .role file / descriptor.role schema: key=value (id, requires=<cap,cap,...>,
# forbids=<cap,...> optional, description=..., plus an optional
# hook_bindings=<point>:<plugin-id>,... on a custom role's descriptor.role --
# recorded for doctor display only in m3, never consumed for gating).
# Parsed as key=value via common.sh's _cfg_file_get exactly like plugin.conf
# -- NEVER sourced. Callers must source lib/common.sh (for _cfg_file_get)
# and lib/manifest.sh (for manifest_get, used by role_eligible) before this
# file.
#
# The five built-in core roles (v1-m1). Kept here (not just repeated inline)
# so every "is this role one of the five, or a custom plugin-shipped one"
# check in this file/lib/resolver.sh/libexec/orchid-doctor reads the exact
# same list. Space-padded for a substring-safe membership test, same idiom
# lib/hooks.sh's _HOOK_POINTS/lib/manifest.sh's _MANIFEST_KNOWN_KEYS use.
_ROLE_BUILTINS=" orchestrator implementer reviewer arbiter plan_critic "

_role_is_builtin() {  # role -> 0 iff one of the five core roles
  case "$_ROLE_BUILTINS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# _role_file <name> -- resolves a role's descriptor file. Search order
# (highest to lowest precedence), mirroring lib/resolver.sh's
# resolve_engine_exe (engines) / lib/archetype.sh's archetype_dir
# (archetypes):
#   1. $ORCHID_ROLES_DIR -- a resolver-only TEST HOOK (mirrors
#      ORCHID_ENGINES_DIR/ORCHID_ARCHETYPES_DIR), flat <name>.role layout
#      (same shape as the built-in root below) -- real discovery
#      (_plugins_roots/_plugins_discover, libexec/orchid-plugins) never
#      walks it.
#   2. $ORCHID_PLUGIN_PATH entries (colon-delimited), each laid out
#      <entry>/roles/<name>/descriptor.role -- a custom role plugin's own
#      dir (kind=role, alongside its plugin.conf).
#   3. $HOME/.orchid/plugins/roles/<name>/descriptor.role
#   4. $ORCHID_ROOT/roles/<name>.role -- the five built-in core roles,
#      always flat files (never a directory+plugin.conf), searched LAST so
#      a custom role can never win a precedence race against a core role --
#      it can only ever COLLIDE with one (below).
# A hit at two or more of the above -- including a custom role whose id
# equals a core role name -- is an INV-10 error: no silent shadow, ever
# (printed to stderr naming both paths, nonzero return, nothing on stdout).
# A role found NOWHERE is not an error at this layer -- it prints the
# built-in (possibly nonexistent) path unchanged, matching this function's
# pre-plugin behavior, so role_get/_cfg_file_get's existing
# missing-file-is-empty handling still applies untouched; callers that need
# to distinguish "resolved, but no such descriptor on disk" (doctor's
# custom-role-binding check) test `[ -f "$(_role_file "$x")" ]` themselves.
_role_file() {
  local name="$1" d found=""

  if [ -n "${ORCHID_ROLES_DIR:-}" ] && [ -f "$ORCHID_ROLES_DIR/$name.role" ]; then
    found="$ORCHID_ROLES_DIR/$name.role"
  fi

  if [ -n "${ORCHID_PLUGIN_PATH:-}" ]; then
    local IFS=':' parts=() p
    read -ra parts <<< "$ORCHID_PLUGIN_PATH"
    for p in "${parts[@]}"; do
      [ -n "$p" ] || continue
      d="$p/roles/$name/descriptor.role"
      if [ -f "$d" ]; then
        [ -z "$found" ] || { echo "orchid: duplicate role '$name' ($found vs $d) (INV-10)" >&2; return 1; }
        found="$d"
      fi
    done
  fi

  d="$HOME/.orchid/plugins/roles/$name/descriptor.role"
  if [ -f "$d" ]; then
    [ -z "$found" ] || { echo "orchid: duplicate role '$name' ($found vs $d) (INV-10)" >&2; return 1; }
    found="$d"
  fi

  d="${ORCHID_ROOT:-}/roles/$name.role"
  if [ -f "$d" ]; then
    [ -z "$found" ] || { echo "orchid: duplicate role '$name' ($found vs $d) (INV-10)" >&2; return 1; }
    found="$d"
  fi

  [ -n "$found" ] && { echo "$found"; return 0; }
  echo "$d"
}

role_get() {  # role key [default]
  local role="$1" key="$2" def="${3:-}" v file
  file="$(_role_file "$role")" || return 1
  v="$(_cfg_file_get "$file" "$key")"
  [ -n "$v" ] && { echo "$v"; return; }
  echo "$def"
}

role_requires() {  # role -> required capability atoms, one per line
  local caps; caps="$(role_get "$1" requires)" || return 1
  [ -n "$caps" ] || return 0
  echo "$caps" | tr ',' '\n'
}

role_forbids() {  # role -> forbidden capability atoms, one per line
  local caps; caps="$(role_get "$1" forbids)" || return 1
  [ -n "$caps" ] || return 0
  echo "$caps" | tr ',' '\n'
}

# _role_custom_names <repo> -- prints each DISTINCT non-built-in role id
# named by any `role.<id>` or `role.<id>.blocking` config key in either the
# repo or user config file, one per line. Read directly off the two config
# FILES (never $ORCHID_ROLE_* env overrides -- there is no way to enumerate
# "every env var that happens to be set" short of scanning the whole
# environment, and doctor's custom-role check is best-effort discovery, not
# a security boundary) since config_get only ever answers for one already-
# known key -- this is the one place that needs to discover WHICH custom
# role ids even exist in config at all.
_role_custom_names() {
  local repo="$1" f all rid
  # `[a-zA-Z0-9_-]+` (WITH the hyphen): a custom role id like
  # `role.code-reviewer=...` is a perfectly legal config key (plugin/role
  # NAMEs elsewhere in this codebase already allow hyphens -- e.g. shipped
  # engine dir names), but the previous `[a-zA-Z0-9_]+` class silently
  # stopped matching at the first `-`, so `role.code-reviewer` was captured
  # as just "code" -- never discovered as its own custom role at all (a
  # doctor/resolver miss, not a crash: the id this produced simply never
  # matched anything real).
  all="$( { [ -f "$repo/orchid.config" ] && grep -oE '^role\.[a-zA-Z0-9_-]+' "$repo/orchid.config"
            [ -f "$HOME/.orchid/config" ] && grep -oE '^role\.[a-zA-Z0-9_-]+' "$HOME/.orchid/config"
            true; } | sed -E 's/^role\.//' | sort -u)"
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    _role_is_builtin "$rid" || echo "$rid"
  done <<< "$all"
}

# role_binding_blocking <repo> <role-id> -- true|false, from `role.<id>.
# blocking=` (default true: a role binding blocks the run on failure unless
# it opts out). Any value other than a recognized falsy spelling (false, 0,
# no) reads as true -- fail-closed (still blocking) on a typo, since
# treating an unrecognized value as "silently non-blocking" is the more
# dangerous misread. docs/specs/operations.md's remote-channel design (v1-
# m4 API-billed engines) is this helper's first consumer; PROTOCOL.md's own
# prose wiring (journal + continue instead of infra-fail) lands in Task 12.
role_binding_blocking() {
  local repo="$1" role="$2" v
  v="$(config_get "$repo" "role.$role.blocking" true)"
  case "$v" in
    false|0|no) echo false ;;
    *) echo true ;;
  esac
}

# role_eligibility_reason <role> <plugin-dir> -- exit 0 with no output iff the
# plugin's manifest capabilities are a superset of role.requires AND disjoint
# from role.forbids. Otherwise prints ONE line naming the specific failure
# (first one found, requires checked before forbids) and exits 1. Purely
# capability-driven: never branches on an engine name (INV-05) -- eligibility
# only ever looks at manifest_capabilities atoms. This is the single walk of
# requires/forbids; role_eligible and resolve_role_checked both build on it
# so the pass/fail decision and the human-readable reason can never drift
# apart again.
role_eligibility_reason() {
  local role="$1" dir="$2" have=" " atom atoms req forb

  # A `while read` loop over a process substitution, not `IFS=',' read -ra
  # atoms <<< "..."` -- an engine legitimately declaring NO capabilities at
  # all (no plugin.conf, or a bare `capabilities=`) is common (e.g. a
  # custom/no-requirement role's engine) and manifest_get then returns "".
  # `read -ra atoms <<< ""` in bash 3.2 leaves `atoms` genuinely unset rather
  # than an empty array, and `"${atoms[@]}"` on that under `set -u` aborts
  # with "atoms[@]: unbound variable" -- this is exactly the idiom
  # lib/capsuite.sh's workspace_write_probe check already uses to sidestep
  # the same pitfall.
  while IFS= read -r atom; do
    [ -n "$atom" ] && have="$have$atom "
  done < <(manifest_get "$dir" capabilities | tr ',' '\n')

  req="$(role_get "$role" requires)" \
    || { echo "role '$role' descriptor is ambiguous on the search path (INV-10, see stderr)"; return 1; }
  if [ -n "$req" ]; then
    IFS=',' read -ra atoms <<< "$req"
    for atom in "${atoms[@]}"; do
      [ -n "$atom" ] || continue
      case "$have" in *" $atom "*) ;; *) echo "missing required capability $atom"; return 1 ;; esac
    done
  fi

  forb="$(role_get "$role" forbids)" \
    || { echo "role '$role' descriptor is ambiguous on the search path (INV-10, see stderr)"; return 1; }
  if [ -n "$forb" ]; then
    IFS=',' read -ra atoms <<< "$forb"
    for atom in "${atoms[@]}"; do
      [ -n "$atom" ] || continue
      case "$have" in *" $atom "*) echo "has forbidden capability $atom"; return 1 ;; esac
    done
  fi

  return 0
}

# role_eligible <role> <plugin-dir> -- exit 0 iff the plugin's manifest
# capabilities are a superset of role.requires AND disjoint from
# role.forbids. Thin wrapper around role_eligibility_reason: discards the
# reason text and keeps only the exit code.
role_eligible() {
  role_eligibility_reason "$@" >/dev/null
}
