#!/usr/bin/env bash

# _role_default_chain <role> -- the built-in preference chain (config-shaped
# data, keyed by ROLE name, never by engine name -- INV-05) for a role with
# no `role.<role>=` config value at all. Single source of truth shared by
# resolve_role (which only ever wants the chain's first element) and
# resolve_role_chain (the full ordered chain) so the two can never disagree
# about what "the default" is.
_role_default_chain() {
  local role="$1" v=""
  case "$role" in
    orchestrator) v=claude,codex;; implementer) v=codex,claude;; reviewer) v=agy;;
    arbiter) v=claude,codex;; plan_critic) v=codex,claude;; esac
  echo "$v"
}

resolve_role() {  # repo role -> primary engine name (first entry of the chain)
  local v; v="$(config_get "$1" "role.$2")"
  [ -n "$v" ] || v="$(_role_default_chain "$2")"
  echo "${v%%,*}"
}

# resolve_role_chain <repo> <role> -- prints the role's preference chain, one
# engine name per line: the configured `role.<role>=` value split on comma,
# or (absent config, one of the five built-ins) the built-in default chain.
# A scalar (no-comma) config value is a one-entry chain, same as before
# v1-m2. A CUSTOM role (not one of the five built-ins, Task 7) has no
# default chain at all -- it resolves PURELY from config -- so an unbound
# one (no `role.<custom>=` anywhere) is a distinct, more specific failure
# than "chain resolved to nothing eligible": exit 14 naming exactly the
# config key to set, from THIS function, before resolve_role_available's own
# chain-walk (which would otherwise just report an empty chain with no
# disqualifiers, a confusing dead end for an operator).
resolve_role_chain() {
  local repo="$1" role="$2" v
  v="$(config_get "$repo" "role.$role")"
  [ -n "$v" ] || v="$(_role_default_chain "$role")"
  if [ -z "$v" ] && ! _role_is_builtin "$role"; then
    echo "orchid: no binding for custom role '$role' (set role.$role=...)" >&2
    return 14
  fi
  echo "$v" | tr ',' '\n'
}
resolve_engine_exe() {  # name -> executable path (search path; dup = error)
  local name="$1" d found="" repo_dir abs trust_stat p
  local -a search_dirs=()
  # ORCHID_ROOT is guarded with :- (brief had it bare): resolve_engine_exe is
  # unit-tested by sourcing this file directly, without going through
  # bin/orchid, so ORCHID_ROOT is unset in that context; under the tests'
  # `set -u` a bare "$ORCHID_ROOT" would abort with "unbound variable"
  # before the loop body ever runs.
  #
  # ORCHID_ENGINES_DIR is a resolver-only test hook (see lib/capsuite.sh's
  # header comment on "external" origin) that real discovery
  # (_plugins_roots/_plugins_discover, libexec/orchid-plugins) never walks --
  # kept first/highest here purely so tests can inject a private engines dir
  # without disturbing the real search roots below.
  #
  # $ORCHID_PLUGIN_PATH (colon-delimited; each entry laid out like
  # _plugins_roots' path roots, i.e. <entry>/engines/<name>/run) is highest
  # REAL precedence per docs/specs/plugins.md's search order -- ahead of
  # ~/.orchid and $ORCHID_ROOT -- and, like ~/.orchid, is a user-controlled
  # location (Trust model) so a path-root engine needs no trust record, same
  # as `plugins list` already treats it (origin=path, trust=user). Without
  # this, a path-root plugin discovers/lists healthy but could never
  # actually execute.
  search_dirs+=("${ORCHID_ENGINES_DIR:-}")
  if [ -n "${ORCHID_PLUGIN_PATH:-}" ]; then
    local IFS=':' parts=()
    read -ra parts <<< "$ORCHID_PLUGIN_PATH"
    for p in "${parts[@]}"; do
      [ -n "$p" ] && search_dirs+=("$p/engines")
    done
  fi
  search_dirs+=("$HOME/.orchid/plugins/engines" "${ORCHID_ROOT:-}/plugins/engines")
  for d in "${search_dirs[@]}"; do
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

# resolve_notify_dir <name> -- the kind=notify analogue of resolve_engine_dir:
# searches the SAME class of roots ($ORCHID_PLUGIN_PATH entries, ~/.orchid/
# plugins, $ORCHID_ROOT/plugins) but under a `notify` kind-dir instead of
# `engines`, and returns the plugin DIR rather than a hardcoded `.../run`
# path -- kind=notify's own entrypoint contract is `send` (docs/specs/
# plugins.md), read from the manifest by the caller (manifest_get "$dir"
# entrypoint), not assumed to be literally named "run" the way
# resolve_engine_exe assumes for engines.
#
# v1-m4 Task 7 scope note: repo-local (<repo>/.orchid/plugins/notify)
# discovery + digest-pinned trust (INV-09, the same treatment
# resolve_engine_exe gives engines) is NOT implemented here -- no shipped
# notify channel plugin needs it yet (the one built-in, plugins/notify/
# openclaw, is discovered via the builtin root below), and `orchid plugins
# list/validate/audit` (libexec/orchid-plugins' generic, kind-agnostic
# discovery) already covers repo-local notify plugins for those verbs
# regardless. Only the launch-time resolver (used solely by runners/
# orchid-pump's outbox drain) is narrower; extend this the same way
# resolve_engine_exe handles INV-09 if a repo-local notify channel is ever
# needed.
resolve_notify_dir() {
  local name="$1" d found="" p
  local -a search_dirs=()
  if [ -n "${ORCHID_PLUGIN_PATH:-}" ]; then
    local IFS=':' parts=()
    read -ra parts <<< "$ORCHID_PLUGIN_PATH"
    for p in "${parts[@]}"; do
      [ -n "$p" ] && search_dirs+=("$p/notify")
    done
  fi
  search_dirs+=("$HOME/.orchid/plugins/notify" "${ORCHID_ROOT:-}/plugins/notify")
  for d in "${search_dirs[@]}"; do
    [ -n "$d" ] || continue
    [ -f "$d/$name/plugin.conf" ] || continue
    [ -z "$found" ] || { echo "orchid: duplicate notify plugin '$name' ($found vs $d/$name) (INV-10)" >&2; return 1; }
    found="$d/$name"
  done
  [ -n "$found" ] || return 1
  echo "$found"
}

# resolve_engine_qualified_id <name> -- the qualified manifest id (e.g.
# "orchid/claude", or a third-party publisher's own "acme/foo") a plugin's
# OWN plugin.conf claims for itself, for comparing against an envelope's
# self-reported `.engine` field -- real adapters echo that field back in
# exactly this qualified form (docs/specs/plugins.md). Resolves the bound
# NAME to its plugin dir (resolve_engine_dir) and reads THAT dir's manifest
# `id=` directly -- this must never assume the "orchid/<name>" shape, which
# only happens to hold for first-party plugins; hardcoding it would make any
# `:required`-bound third-party engine permanently unsatisfiable at every
# call site that compares against it (INV-05: this is manifest-derived data
# being compared, not a branch on a hardcoded name). When the name cannot be
# resolved to an installed dir at all (unbound, or not currently discoverable
# at gate/reconcile time), falls back to the literal "orchid/<name>" string
# -- preserves every fixture/test that predates third-party publishers
# rather than refusing to compare at all.
# Callers must additionally source lib/manifest.sh (manifest_get).
resolve_engine_qualified_id() {
  local name="$1" dir qid
  if dir="$(resolve_engine_dir "$name" 2>/dev/null)"; then
    qid="$(manifest_get "$dir" id)"
    [ -n "$qid" ] || qid="orchid/$name"
  else
    qid="orchid/$name"
  fi
  echo "$qid"
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

# resolve_role_available <repo> <role> -- walks resolve_role_chain and prints
# the first entry that is (a) discovered (resolve_engine_dir), (b)
# role-eligible (role_eligibility_reason), (c) ledger_available, and (d) --
# for every entry AFTER the first -- capsuite_passed for this exact (engine,
# role) pair: a fallback may activate ONLY once it has actually been proven
# to work for this role (v1-m1's capability suite gate); the primary is the
# tested default and needs no capsuite record. `plan_critic` additionally
# skips any chain entry that equals `resolve_role <repo> orchestrator`'s
# engine -- the engine that drafted a plan never critiques its own draft --
# regardless of that entry's chain position.
#
# No survivor -> nothing on stdout, exit 14, and one line on stderr naming
# the role, the full chain, and EACH entry's specific disqualifier (so an
# operator never has to go spelunking in the ledger/capsuite dirs to see
# why). Callers must source, in order: lib/common.sh, lib/manifest.sh,
# lib/roles.sh, lib/resolver.sh (this file), lib/capsuite.sh, lib/ledger.sh.
resolve_role_available() {
  local repo="$1" role="$2" chain engine dir reason skip_engine="" idx=0 disq=""

  [ "$role" = plan_critic ] && skip_engine="$(resolve_role "$repo" orchestrator)"
  # An unbound custom role's exit 14 (its own specific "no binding for
  # custom role" message, already on stderr) is propagated verbatim rather
  # than falling through to the generic "no eligible engine" message below,
  # which would otherwise report an empty chain with zero disqualifiers.
  chain="$(resolve_role_chain "$repo" "$role")" || return $?

  while IFS= read -r engine; do
    [ -n "$engine" ] || continue
    idx=$((idx + 1))

    if [ -n "$skip_engine" ] && [ "$engine" = "$skip_engine" ]; then
      disq="$disq$engine: same engine as orchestrator (plan_critic cannot critique its own plan); "
      continue
    fi

    if ! dir="$(resolve_engine_dir "$engine")"; then
      disq="$disq$engine: not found on search path; "
      continue
    fi

    if ! reason="$(role_eligibility_reason "$role" "$dir")"; then
      disq="$disq$engine: $reason; "
      continue
    fi

    if ! ledger_available "$repo" "$engine"; then
      disq="$disq$engine: rate-limited or failing (ledger); "
      continue
    fi

    if [ "$idx" -gt 1 ] && ! capsuite_passed "$engine" "$role"; then
      disq="$disq$engine: capsuite not passed -- run: orchid plugins test $engine $role; "
      continue
    fi

    echo "$engine"
    return 0
  done <<< "$chain"

  echo "orchid: no eligible engine available for role $role (chain: ${disq%; })" >&2
  return 14
}
