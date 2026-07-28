#!/usr/bin/env bash
resolve_role() {  # repo role -> primary engine name
  local v; v="$(config_get "$1" "role.$2")"
  [ -n "$v" ] || case "$2" in
    orchestrator) v=claude;; implementer) v=codex;; reviewer) v=agy;;
    arbiter) v=claude;; plan_critic) v=codex;; esac
  echo "${v%%,*}"
}
resolve_engine_exe() {  # name -> executable path (search path; dup = error)
  local name="$1" d found=""
  # <repo>/.orchid/plugins/engines is repo-local and thus attacker-controlled
  # by anything that can land a commit; v0 has no trust mechanism yet, so it
  # is never added to the search path below (this is the "SKIPPED unless
  # trusted" rule from PROTOCOL — INV-10 seed). We still warn when something
  # is sitting there so an operator who just dropped in a plugin isn't left
  # wondering why it's silently ignored.
  if [ -x "${ORCHID_REPO:-}/.orchid/plugins/engines/$name/run" ]; then
    echo "orchid: engine '$name' found in <repo>/.orchid/plugins/engines but repo-local engines are untrusted in v0 (skipped)" >&2
  fi
  # ORCHID_ROOT is guarded with :- (brief had it bare): resolve_engine_exe is
  # unit-tested by sourcing this file directly, without going through
  # bin/orchid, so ORCHID_ROOT is unset in that context; under the tests'
  # `set -u` a bare "$ORCHID_ROOT" would abort with "unbound variable"
  # before the loop body ever runs.
  for d in "${ORCHID_ENGINES_DIR:-}" "$HOME/.orchid/plugins/engines" "${ORCHID_ROOT:-}/plugins/engines"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$name/run" ]; then
      [ -z "$found" ] || { echo "orchid: duplicate engine '$name' ($found vs $d) (INV-10)" >&2; return 1; }
      found="$d/$name/run"
    fi
  done
  [ -n "$found" ] || return 1
  echo "$found"
}
resolve_engine_dir() {  # name -> plugin dir (dirname of resolve_engine_exe)
  local exe; exe="$(resolve_engine_exe "$1")" || return 1
  dirname "$exe"
}

# resolve_role_checked <repo> <role> -- resolves the role's engine (same
# lookup as resolve_role) then gates it on capability eligibility (lib/
# roles.sh's role_eligible against the engine's manifest capabilities).
# Callers must additionally source lib/manifest.sh and lib/roles.sh.
# Existing resolve_role/resolve_engine_exe are left unchanged above for
# back-compat with v0 callers/tests.
resolve_role_checked() {  # repo role -> engine name, or exit 1 with a reason
  local repo="$1" role="$2" engine dir have atom atoms req

  engine="$(resolve_role "$repo" "$role")"
  dir="$(resolve_engine_dir "$engine")" \
    || { echo "orchid: engine '$engine' for role '$role' not found on search path" >&2; return 1; }

  if role_eligible "$role" "$dir"; then
    echo "$engine"
    return 0
  fi

  # role_eligible only says pass/fail; walk requires/forbids again here to
  # name the specific capability gap for the error message.
  have=" "
  IFS=',' read -ra atoms <<< "$(manifest_get "$dir" capabilities)"
  for atom in "${atoms[@]}"; do
    [ -n "$atom" ] && have="$have$atom "
  done

  req="$(role_get "$role" requires)"
  IFS=',' read -ra atoms <<< "$req"
  for atom in "${atoms[@]}"; do
    [ -n "$atom" ] || continue
    case "$have" in *" $atom "*) ;; *)
      echo "orchid: engine $engine lacks capability $atom for role $role" >&2
      return 1
      ;;
    esac
  done

  local forb; forb="$(role_get "$role" forbids)"
  IFS=',' read -ra atoms <<< "$forb"
  for atom in "${atoms[@]}"; do
    [ -n "$atom" ] || continue
    case "$have" in *" $atom "*)
      echo "orchid: engine $engine lacks capability $atom for role $role" >&2
      return 1
      ;;
    esac
  done

  echo "orchid: engine $engine is not eligible for role $role" >&2
  return 1
}
