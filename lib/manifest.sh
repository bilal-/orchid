#!/usr/bin/env bash
# plugin.conf schema (v1) — see docs/specs/plugins.md (Manifest section).
# Parsed as key=value, NEVER sourced (reuses _cfg_file_get's escaping from
# lib/common.sh, which callers must source before this file).

# Keys understood at manifest_version=1; anything else is an unknown key
# (warn, still valid) rather than a hard failure. `outcome`/`transitions`
# are kind=archetype-only keys (lib/archetype.sh's meta-contract validator);
# `command_surface` is a kind=engine-only key (see below); all are listed
# here rather than in a kind-scoped allowlist since this file has no such
# per-kind mechanism today and unknown-key warnings are advisory only.
#
# `command_surface` (v1.1, Track 1) is an HONEST LABEL, not a capability:
#   brokered -- this adapter runs its orchestrator against the
#               argument-validating broker (runners/orchid-orchestrator-
#               command) and nothing else, because its vendor CLI supports an
#               enforceable per-command allowlist. COMMANDS only: it makes no
#               claim about file writes, which the shipped brokered adapter
#               leaves open (acceptEdits) over every reachable path.
#   soft     -- this adapter's vendor CLI offers no enforceable command
#               restriction Orchid can rely on, so its orchestrator's reach is
#               bounded only by the process environment and by the operator's
#               machine-local unattended acknowledgement.
# Absent reads as `soft`: the label may only ever make a weaker claim by
# omission, never a stronger one.
_MANIFEST_KNOWN_KEYS=" manifest_version id version kind api_version requires_orchid capabilities permissions requires_binaries platforms entrypoint outcome transitions command_surface "

# This file's own directory, regardless of who sources it or their cwd —
# BASH_SOURCE[0] inside a function is the file the function is DEFINED in,
# not the caller's file, so this stays correct even when ORCHID_ROOT is
# unset (e.g. tests sourcing lib/manifest.sh directly).
_manifest_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

manifest_get() {  # plugin-dir key [default]
  local dir="$1" key="$2" def="${3:-}" v
  v="$(_cfg_file_get "$dir/plugin.conf" "$key")"
  [ -n "$v" ] && { echo "$v"; return; }
  echo "$def"
}

# _manifest_split_csv <string> -- splits a comma list and prints each token
# TRIMMED of leading/trailing whitespace, one per line, skipping empty
# tokens. Shared by manifest_capabilities, manifest_permissions,
# manifest_validate's capability-atom check, lib/schedule.sh's resources
# splitting, and lib/capsuite.sh's binaries_present check, so `permissions=A,
# B` or `capabilities=structured_text, git` (a space after the comma -- easy
# to type, common in hand-edited plugin.conf files) never leaks a
# leading-space token. An untrimmed " B" previously defeated the launcher's
# `${!perm}` indirect expansion (always-unset, since no variable is
# literally named " B") and produced a misleading "permission  B requested,
# not set" warning (two spaces, unreadable) -- same house-style bug in both
# call sites, one helper fixes both.
#
# NOT `IFS=',' read -ra tokens <<< "$s"` (the previous implementation): in
# bash 3.2, that leaves `tokens` genuinely UNSET (not an empty array) when
# $s is empty, and `"${tokens[@]}"` on that under `set -u` (every test file,
# via helpers.sh; bin/orchid and most libexec/* entrypoints too) aborts with
# "tokens[@]: unbound variable" -- e.g. lib/capsuite.sh's binaries_present
# check calling this directly on a manifest's absent `requires_binaries`
# crashed `orchid plugins test` outright (m2 Task 2 finding). A `tr ','
# '\n'` + `while read` pipeline never constructs an array at all -- an empty
# $s just yields zero loop iterations -- same idiom lib/roles.sh's role_
# eligibility_reason and lib/capsuite.sh's workspace_write_probe check
# already use to sidestep this exact pitfall.
_manifest_split_csv() {  # string -> trimmed non-empty tokens, one per line
  local s="$1" tok
  while IFS= read -r tok; do
    tok="${tok#"${tok%%[![:space:]]*}"}"   # trim leading whitespace
    tok="${tok%"${tok##*[![:space:]]}"}"   # trim trailing whitespace
    [ -n "$tok" ] && echo "$tok"
  done < <(printf '%s\n' "$s" | tr ',' '\n')
  # `while read` returns the exit status of its FINAL (EOF-failing) read,
  # not "did this run cleanly" -- always 1 once the input is exhausted, even
  # for a totally empty $s with zero real tokens. Normalize to 0 so a caller
  # that checks this function's own exit status (unlike every current
  # caller, which only consumes its stdout) never mistakes "no tokens" for
  # a failure.
  return 0
}

# _manifest_version_mm <version-string> -> "<major> <minor>" -- strips any
# trailing `-suffix` (e.g. a pre-release build tagged `1.1.0-rc1`) and keeps
# only the first two dot-separated components. requires_orchid is documented
# (docs/specs/plugins.md, Manifest section) as semver-ish `>=` compared on
# major.minor ONLY -- not full semver ordering (patch/prerelease never gate
# compatibility).
_manifest_version_mm() {
  local v="${1%%-*}" major minor
  major="${v%%.*}"
  minor="${v#*.}"; minor="${minor%%.*}"
  printf '%s %s\n' "${major:-0}" "${minor:-0}"
}

# _manifest_orchid_satisfies <requires_orchid-value, e.g. ">=1.0"> -- exit 0
# iff the running kernel's $ORCHID_VERSION (lib/common.sh; caller must have
# sourced it) is >= the required major.minor. Caller strips/validates the
# `>=` operator prefix before calling -- this only compares the two
# major.minor pairs.
_manifest_orchid_satisfies() {
  local reqver="${1#>=}" reqmm curmm reqmaj reqmin curmaj curmin
  reqmm="$(_manifest_version_mm "$reqver")"
  curmm="$(_manifest_version_mm "$ORCHID_VERSION")"
  reqmaj="${reqmm%% *}"; reqmin="${reqmm#* }"
  curmaj="${curmm%% *}"; curmin="${curmm#* }"
  [ "$curmaj" -gt "$reqmaj" ] && return 0
  [ "$curmaj" -eq "$reqmaj" ] && [ "$curmin" -ge "$reqmin" ] && return 0
  return 1
}

manifest_capabilities() {  # plugin-dir -> capability atoms, one per line
  local caps; caps="$(manifest_get "$1" capabilities)"
  [ -n "$caps" ] || return 0
  _manifest_split_csv "$caps"
}

# manifest_permissions <plugin-dir> -- prints the env var NAMES this
# plugin's plugin.conf `permissions=` (comma list) opts into, one per line.
# These are the ONLY non-base-allowlisted env vars the kernel launcher
# (runners/orchid-launch) will forward into the child's stripped environment
# (Task 5, env hygiene). The launcher consumes this function's output
# directly rather than re-splitting `permissions=` itself, so it always sees
# already-trimmed names.
manifest_permissions() {  # plugin-dir -> permission env var names, one per line
  local perms; perms="$(manifest_get "$1" permissions)"
  [ -n "$perms" ] || return 0
  _manifest_split_csv "$perms"
}

_manifest_known_capability() {  # atom
  grep -qxF "$1" "$(_manifest_lib_dir)/capabilities.txt"
}

# Unknown KEYS (in a known manifest_version) warn but never invalidate. Split
# out so a fail-closed reject path (e.g. unknown api_version) can still run
# this diagnostic before returning -- collect warnings, then fail, so an
# operator sees ALL of a manifest's problems in one pass instead of only the
# first one found.
_manifest_warn_unknown_keys() {  # plugin-dir conf-file
  local dir="$1" conf="$2" key
  while IFS='=' read -r key _; do
    case "$key" in ''|'#'*) continue ;; esac
    case "$_MANIFEST_KNOWN_KEYS" in
      *" $key "*) ;;
      *) echo "warn: $dir: unknown key '$key' in plugin.conf" >&2 ;;
    esac
  done < "$conf"
}

manifest_validate() {  # plugin-dir
  local dir="$1" conf="$1/plugin.conf" ok=1

  if [ ! -f "$conf" ]; then
    echo "FAIL: $dir: no plugin.conf"
    return 1
  fi

  local mv; mv="$(manifest_get "$dir" manifest_version)"
  if [ -z "$mv" ]; then
    echo "FAIL: $dir: manifest_version missing"
    ok=0
  elif [ "$mv" != 1 ]; then
    echo "FAIL: $dir: unknown manifest_version '$mv' (rejected, fail closed)"
    return 13
  fi

  local id; id="$(manifest_get "$dir" id)"
  if [ -z "$id" ]; then
    echo "FAIL: $dir: id missing"; ok=0
  else
    case "$id" in
      *..*) echo "FAIL: $dir: id '$id' contains '..'"; ok=0 ;;
    esac
    if ! printf '%s' "$id" | grep -Eq '^[a-z0-9_-]+/[a-z0-9_-]+$'; then
      echo "FAIL: $dir: id '$id' is not qualified as publisher/name"; ok=0
    fi
  fi

  local kind; kind="$(manifest_get "$dir" kind)"
  case "$kind" in
    engine|archetype|notify|hook|role) ;;
    *) echo "FAIL: $dir: kind '$kind' is not one of engine|archetype|notify|hook|role"; ok=0 ;;
  esac

  local av; av="$(manifest_get "$dir" api_version)"
  if [ -z "$av" ]; then
    echo "FAIL: $dir: api_version missing"; ok=0
  elif ! printf '%s' "$av" | grep -Eq '^[0-9]+$'; then
    echo "FAIL: $dir: api_version '$av' is not an integer"; ok=0
  elif [ "$av" != 1 ]; then
    _manifest_warn_unknown_keys "$dir" "$conf"
    echo "FAIL: $dir: unknown api_version '$av' (rejected, fail closed)"
    return 13
  fi

  local ver; ver="$(manifest_get "$dir" version)"
  if [ -z "$ver" ]; then
    echo "FAIL: $dir: version missing"; ok=0
  elif ! printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+'; then
    echo "FAIL: $dir: version '$ver' is not semver-ish (expected N.N...)"; ok=0
  fi

  # requires_orchid=>=X.Y (optional): the plugin's declared minimum kernel
  # version, checked against $ORCHID_VERSION (lib/common.sh) major.minor.
  # Unsatisfied -> reject fail-closed, same exit code (13) as an unknown
  # manifest_version/api_version -- same reasoning: an incompatible-version
  # plugin must never be treated as merely "invalid" (ok=0, still runnable
  # elsewhere) since running it against a kernel it declares itself
  # incompatible with is the exact failure mode fail-closed exists to
  # prevent. Only `>=` is understood (the only operator docs/specs/
  # plugins.md's Manifest section documents); any other operator warns
  # (unrecognized) but never fails the manifest on its own.
  local reqorc; reqorc="$(manifest_get "$dir" requires_orchid)"
  if [ -n "$reqorc" ]; then
    case "$reqorc" in
      '>='*)
        if ! _manifest_orchid_satisfies "$reqorc"; then
          _manifest_warn_unknown_keys "$dir" "$conf"
          echo "FAIL: $dir: requires_orchid '$reqorc' not satisfied by orchid $ORCHID_VERSION (rejected, fail closed)"
          return 13
        fi
        ;;
      *)
        echo "warn: $dir: requires_orchid '$reqorc' has an unrecognized operator (only >= is supported)" >&2
        ;;
    esac
  fi

  case "$kind" in
    engine|notify|hook)
      local ep; ep="$(manifest_get "$dir" entrypoint)"
      if [ -z "$ep" ]; then
        echo "FAIL: $dir: entrypoint missing (required for kind=$kind)"; ok=0
      elif [ ! -f "$dir/$ep" ] || [ ! -x "$dir/$ep" ]; then
        echo "FAIL: $dir: entrypoint '$ep' is not an executable file in $dir"; ok=0
      fi
      ;;
  esac

  # kind=role (v1-m3 Task 7): a custom role plugin has no entrypoint/
  # capabilities of its own (it is data describing a ROLE, not something
  # invoked) -- the manifest_validate case above deliberately excludes it
  # from the entrypoint requirement. Instead it must ship a sibling
  # `descriptor.role` (same key=value schema as a built-in .role file:
  # id/requires/forbids/description, plus an optional hook_bindings=
  # recorded for doctor display only in m3) whose own `id` names exactly
  # the manifest id's NAME part (the text after the qualifying `/`) -- e.g.
  # manifest id=acme/researcher requires descriptor.role's id=researcher.
  # This is what lets lib/roles.sh's _role_file discovery trust a
  # discovered role plugin dir's descriptor without re-deriving the role
  # name from the directory name (which `orchid plugins list`'s discovery
  # never assumes either -- manifest-derived, not guessed).
  if [ "$kind" = role ]; then
    local rf="$dir/descriptor.role" rid
    if [ ! -f "$rf" ]; then
      echo "FAIL: $dir: descriptor.role missing (required for kind=role)"; ok=0
    else
      rid="$(_cfg_file_get "$rf" id)"
      if [ -z "$rid" ]; then
        echo "FAIL: $dir: descriptor.role missing 'id' key"; ok=0
      elif [ "$rid" != "${id#*/}" ]; then
        echo "FAIL: $dir: descriptor.role id '$rid' does not match manifest id's name part '${id#*/}'"; ok=0
      fi
    fi
  fi

  # kind=hook (v1-m3): validated with the SAME fields as kind=engine (entry-
  # point above, capabilities here) -- hook handlers are engine-kind plugins
  # invoked with operation=hook (docs/specs/plugins.md, Hooks section), not a
  # distinct executable contract.
  if [ "$kind" = engine ] || [ "$kind" = hook ]; then
    local caps atom
    caps="$(manifest_get "$dir" capabilities)"
    if [ -n "$caps" ]; then
      while IFS= read -r atom; do
        [ -n "$atom" ] || continue
        if ! _manifest_known_capability "$atom"; then
          echo "FAIL: $dir: unknown capability atom '$atom'"; ok=0
        fi
      done < <(_manifest_split_csv "$caps")
    fi
  fi

  # permissions=: opting into an env var name that isn't actually set
  # anywhere the launcher will run from is never a hard failure (the plugin
  # is still runnable -- the adapter itself reports the auth failure at
  # runtime, per Task 5's launcher env-hygiene design) -- just a warn so an
  # operator notices a likely-missing credential before dispatch.
  local perm
  while IFS= read -r perm; do
    [ -n "$perm" ] || continue
    [ -n "${!perm:-}" ] || echo "warn: $dir: permission $perm requested, not set" >&2
  done < <(manifest_permissions "$dir")

  _manifest_warn_unknown_keys "$dir" "$conf"

  if [ "$ok" -eq 1 ]; then
    echo "ok: $dir"
    return 0
  fi
  return 1
}
