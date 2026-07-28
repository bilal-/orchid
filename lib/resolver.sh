#!/usr/bin/env bash
resolve_role() {  # repo role -> primary engine name
  local v; v="$(config_get "$1" "role.$2")"
  [ -n "$v" ] || case "$2" in
    orchestrator) v=claude;; implementer) v=codex;; reviewer) v=agy;;
    arbiter) v=claude;; plan_critic) v=codex;; esac
  echo "${v%%,*}"
}
resolve_engine_exe() {  # name -> executable path (search path; dup = error)
  local name="$1" d found="" repo_dir abs trust_stat
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
  # <repo>/.orchid/plugins/engines is repo-local and thus attacker-controlled
  # by anything that can land a commit; it is resolvable ONLY when
  # `~/.orchid/trust` (digest-pinned, outside the repo -- see lib/common.sh)
  # has a record for this exact directory whose digest matches the directory
  # right now (INV-09). Absent or mismatched (e.g. after a pull mutated a
  # file) -> skipped + warned to stderr, never executed.
  # TOCTOU: the digest is checked here, at resolve time, but the resolved
  # path is only exec'd later by the caller -- a single-operator v1 accepts
  # that gap rather than closing it (e.g. no re-check-then-exec atomicity).
  if [ -n "${ORCHID_REPO:-}" ]; then
    repo_dir="$ORCHID_REPO/.orchid/plugins/engines/$name"
    if [ -x "$repo_dir/run" ]; then
      abs="$(_trust_canon_path "$repo_dir" 2>/dev/null || true)"
      trust_stat="untrusted"; [ -z "$abs" ] || trust_stat="$(trust_status_for "$abs")"
      if [ "$trust_stat" = trusted ]; then
        [ -z "$found" ] || { echo "orchid: duplicate engine '$name' ($found vs $repo_dir/run) (INV-10)" >&2; return 1; }
        found="$repo_dir/run"
      else
        local trust_cmd="trust"; [ "$trust_stat" = mismatch ] && trust_cmd="trust --update"
        echo "orchid: engine '$name' found in <repo>/.orchid/plugins/engines but is $trust_stat -- run 'orchid plugins $trust_cmd $repo_dir' to enable it (skipped, INV-09)" >&2
      fi
    fi
  fi
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
  local repo="$1" role="$2" engine dir reason

  engine="$(resolve_role "$repo" "$role")"
  dir="$(resolve_engine_dir "$engine")" \
    || { echo "orchid: engine '$engine' for role '$role' not found on search path" >&2; return 1; }

  # role_eligibility_reason is the single requires/forbids walk shared with
  # role_eligible, so the gate and its human-readable reason can never drift
  # apart the way they used to (a forbids violation used to be misreported
  # as "lacks capability").
  reason="$(role_eligibility_reason "$role" "$dir")" \
    || { echo "orchid: engine $engine $reason for role $role" >&2; return 1; }

  echo "$engine"
}
