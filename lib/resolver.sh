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
