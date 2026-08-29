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
# _resolve_engine_roots -- the `engines` directories a plugin is searched for
# by DIRECTORY NAME, highest precedence first, one per line.
#
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
#
# REPO-LOCAL IS DELIBERATELY ABSENT. <repo>/.orchid/plugins/engines is
# attacker-controlled by anything that can land a commit and is reachable only
# through the digest-pinned trust check resolve_engine_exe applies to it
# separately (INV-09); a caller that picked it up off this list would walk
# straight past that gate.
#
# Factored out of resolve_engine_exe so the lookup BY QUALIFIED ID
# (resolve_engine_dir_any) enumerates the SAME registry the name lookup does.
# Two lists would drift, and the drift would surface as an installed
# third-party plugin the routing gate cannot see -- the exact failure that
# lookup exists to end.
_resolve_engine_roots() {
  local p
  [ -z "${ORCHID_ENGINES_DIR:-}" ] || printf '%s\n' "$ORCHID_ENGINES_DIR"
  if [ -n "${ORCHID_PLUGIN_PATH:-}" ]; then
    local parts=()
    local IFS=':'
    read -ra parts <<< "$ORCHID_PLUGIN_PATH"
    for p in "${parts[@]}"; do
      [ -n "$p" ] && printf '%s/engines\n' "$p"
    done
  fi
  printf '%s\n' "$HOME/.orchid/plugins/engines"
  printf '%s\n' "${ORCHID_ROOT:-}/plugins/engines"
}

resolve_engine_exe() {  # name -> executable path (search path; dup = error)
  local name="$1" d found="" repo_dir abs trust_stat
  local -a search_dirs=()
  # `|| continue` rather than `&& search_dirs+=(...)`: under `set -e` a while
  # loop whose LAST body command is a failed test returns that status, and this
  # loop sits at the top of a function whose callers read its exit status as
  # "engine not found".
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    search_dirs+=("$d")
  done < <(_resolve_engine_roots)
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
  # Review finding (Important #2): `name` comes straight from `notify.plugin`
  # config -- operator-trusted today, but `orchid config commit` makes
  # orchid.config a tracked, merge-reachable file, so a value containing a
  # path separator or `..` must never be allowed to traverse out of every
  # notify root below (`$d/$name/plugin.conf` would otherwise resolve
  # anywhere on disk, and the caller then execs that directory's `send` with
  # NO INV-09 digest/trust gate at all -- contradicting docs/specs/
  # plugins.md's threat model). Refused before any root is even searched;
  # the caller (runners/orchid-pump's outbox drain) already feeds this exact
  # 1-argument stderr into its existing per-message failure/quarantine path.
  case "$name" in
    */*|*..*) echo "orchid: invalid notify plugin name '$name' (must not contain '/' or '..')" >&2; return 1 ;;
  esac
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

# _resolve_engine_names -- every engine directory NAME visible under any root,
# one per line, duplicates included. The repo-local root IS walked here, unlike
# in _resolve_engine_roots: this only produces NAMES, and each one is handed
# back to resolve_engine_exe, which is what applies precedence, the duplicate
# refusal (INV-10) and the repo-local digest/trust gate (INV-09). Nothing is
# resolved by being listed.
_resolve_engine_names() {
  local root d
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -d "$root" ] || continue
    for d in "$root"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      printf '%s\n' "${d##*/}"
    done
  done < <(
    _resolve_engine_roots
    [ -z "${ORCHID_REPO:-}" ] || printf '%s\n' "$ORCHID_REPO/.orchid/plugins/engines"
  )
}

# resolve_engine_dir_any <name-or-qualified-id> -- the plugin dir for an actor
# named EITHER way: the install-DIRECTORY name a binding uses
# (resolve_engine_dir), or the QUALIFIED manifest id a plugin claims for itself
# (`acme/foo`). The exact inverse of resolve_engine_qualified_id above, and it
# must stay that way -- one function turns a binding into the id an envelope
# reports, this one turns that id back into the plugin it came from.
#
# WHY BOTH FORMS ARE ONE QUESTION. `implementer_engine_id` records the id the
# implement envelope reported, minus the `orchid/` vendor prefix
# libexec/orchid-task strips -- so a first-party actor lands in that field as a
# bare `claude` (which IS its directory) and a third-party one as `acme/foo`
# (which is not). BOTH name an actor orchid itself dispatched to: the field
# exists because a job was minted, launched and reconciled for that plugin, so
# neither form is an unknown the kernel is entitled to give up on. A resolver
# that reached only the first would report every healthy third-party plugin as
# unidentifiable, and a gate built on it would then answer differently
# depending on whose engine it is -- the one thing INV-14 promises the kernel
# never does.
#
# THE ID IS MATCHED WHOLE, NEVER GUESSED AT. The basename is never retried:
# `acme/foo` and `zzz/foo` both fall to a directory called `foo`, so a lookup
# that "helpfully" succeeded there would be answering out of another
# publisher's manifest -- the shadowing INV-10 refuses elsewhere, arrived at by
# being accommodating. A qualified id resolves because some installed manifest
# CLAIMS it, or it does not resolve.
#
# NOR IS A VENDOR PREFIX RECONSTRUCTED in the other direction. A BARE name is
# looked up as a directory and matched against `id=` verbatim; it is not also
# tried as `orchid/<name>`, because that would assume the very shape
# resolve_engine_qualified_id's own header says must never be assumed. In the
# shipped layout the question does not arise: `orchid plugins install` places a
# plugin at `<root>/<kind>s/<basename of its id>` (libexec/orchid-plugins), so
# a first-party `orchid/claude` is installed in a directory called `claude` and
# the bare form the vendor-prefix strip leaves behind IS its directory name.
# A hand-placed directory whose name matches neither is reported as not
# installed, which is true, and names both forms so the fix is visible.
#
# Three outcomes, and a caller must read the STATUS:
#
#   0, one line  resolved; this is the plugin dir.
#   1, nothing   nothing installed is named that, and no installed manifest
#                claims that id.
#   2, nothing   AMBIGUOUS: two installed plugins claim the id, and picking one
#                is precedence-by-shadow, which INV-10 refuses. Kept apart from
#                1 because "install it" and "uninstall one of them" are
#                opposite operator actions.
#
# Callers must additionally source lib/manifest.sh (manifest_get).
resolve_engine_dir_any() {
  local name="$1"
  local dir n cand hit=""
  local seen=" "
  if dir="$(resolve_engine_dir "$name" 2>/dev/null)"; then
    printf '%s\n' "$dir"
    return 0
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    # Resolved back through resolve_engine_dir rather than read off disk:
    # precedence, the duplicate-NAME refusal and the repo-local trust gate are
    # applied by the one function that owns them, so an id lookup can never
    # reach a plugin a name lookup would have refused.
    cand="$(resolve_engine_dir "$n" 2>/dev/null)" || continue
    [ "$(manifest_get "$cand" id 2>/dev/null)" = "$name" ] || continue
    if [ -n "$hit" ] && [ "$hit" != "$cand" ]; then
      echo "orchid: engine id '$name' is claimed by two installed plugins ($hit vs $cand) (INV-10)" >&2
      return 2
    fi
    hit="$cand"
  done < <(_resolve_engine_names)
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
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

# resolve_role_available <repo> <role> [step] -- walks resolve_role_chain and
# prints the first entry that is (a) discovered (resolve_engine_dir), (b)
# role-eligible (role_eligibility_reason), (c) -- when a <step> is given --
# not refused that step by the kernel's own capability table, (d)
# ledger_available, and (e) -- for every entry AFTER the first --
# capsuite_passed for this exact (engine,
# role) pair: a fallback may activate ONLY once it has actually been proven
# to work for this role (v1-m1's capability suite gate); the primary is the
# tested default and needs no capsuite record. `plan_critic` additionally
# skips any chain entry that equals `resolve_role <repo> orchestrator`'s
# engine -- the engine that drafted a plan never critiques its own draft --
# regardless of that entry's chain position.
#
# WHY SELECTION IS OPERATION-AWARE AT ALL (T018/INV-16). Without <step> this
# walk answers "who may hold this ROLE", and the caller then discovers -- one
# gate later, at `orchid jobs prepare`'s step gate -- that the winner cannot
# perform the WORK. Those are different questions wherever a role descriptor
# asks for less than the step's price does, which is exactly the CUSTOM role
# whose descriptor its own publisher writes. An incapable primary then SHADOWS
# a capable, capsuite-proven fallback sitting right behind it in the same
# chain: the walk stops at the primary because it is role-eligible, the step
# gate refuses it permanently, and the fallback that could have done the work
# is never reached. Failing over is what a chain is for, and a capability
# shortfall is as permanent a reason to fail over as a rate limit is a
# temporary one.
#
# ONLY A REFUSAL (the table's exit 1) SKIPS AN ENTRY. An entry the table
# cannot answer for (its 2) and a step name it never priced (its 3) are not
# capability facts about this engine, and skipping on them would let a
# momentary discovery failure -- or one caller's typo -- silently fail a
# dispatch over to somebody else. Both leave the entry exactly where it was,
# for the gates that own those answers to report in their own words.
#
# THE STEP IS THE CALLER'S TO PASS, and a caller that passes one without
# lib/capability.sh sourced is refused rather than quietly answered. Skipping
# the check because its implementation is absent would turn "route only to an
# actor that declares the work" into "route to whoever loaded first", which is
# the fail-open INV-16 exists to close, arriving through a missing `source`.
#
# No survivor -> nothing on stdout, exit 14, and one line on stderr naming
# the role, the full chain, and EACH entry's specific disqualifier (so an
# operator never has to go spelunking in the ledger/capsuite dirs to see
# why). Callers must source, in order: lib/common.sh, lib/manifest.sh,
# lib/roles.sh, lib/resolver.sh (this file), lib/capsuite.sh, lib/ledger.sh --
# plus lib/capability.sh when (and only when) they pass a <step>.
resolve_role_available() {
  local repo="$1" role="$2" step="${3:-}"
  local chain engine dir reason skip_engine="" idx=0 disq=""
  local why crc

  if [ -n "$step" ] && ! declare -F capability_routing_refusal >/dev/null 2>&1; then
    echo "orchid: internal: resolve_role_available was asked about step '$step' without lib/capability.sh sourced" >&2
    return 3
  fi

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

    # Asked immediately after the role gate and before the ledger/capsuite
    # ones, because both read the same manifest and neither changes: an entry
    # disqualified here is disqualified for good, and reporting it as
    # "rate-limited" (the answer that would have come out first had the order
    # been the other way) is the mis-attribution INV-16 exists to end.
    if [ -n "$step" ]; then
      crc=0
      why="$(capability_routing_refusal "$step" "$engine")" || crc=$?
      if [ "$crc" -eq 1 ]; then
        disq="$disq$engine: $why; "
        continue
      fi
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
