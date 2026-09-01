#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/envelope.sh"; source "$REPO_ROOT/lib/capsuite.sh"
export ORCHID_ROOT="$REPO_ROOT"

# v1-m3 Task 7: custom role registration -- a kind=role plugin (plugin.conf
# + descriptor.role) discovers/lists/validates like any other plugin, its
# descriptor is found via the same kind of search path resolve_engine_exe
# already uses for engines, and its eligibility gate is the SAME
# role_eligibility_reason walk the five built-ins use (INV-05: purely
# capability-driven, never a branch on role or engine name).

mk_role_plugin() {  # dir manifest-id role-id requires [forbids]
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=0.1.0\nkind=role\napi_version=1\n' "$2" > "$1/plugin.conf"
  {
    echo "id=$3"
    [ -n "$4" ] && echo "requires=$4"
    [ -n "${5:-}" ] && echo "forbids=$5"
    echo "description=test role plugin"
  } > "$1/descriptor.role"
}

mk_engine() {  # dir id capabilities
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nentrypoint=run\n' \
    "$2" "$3" > "$1/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

repo="$WORK/repo"; mkdir -p "$repo"
(cd "$repo" && git init -q . && git commit -q --allow-empty -m root)
home="$WORK/home"; mkdir -p "$home/.orchid"

mk_role_plugin "$home/.orchid/plugins/roles/researcher" acme/researcher researcher structured_text,citations
mk_engine "$home/.orchid/plugins/engines/citer" acme/citer structured_text,citations

# -- discovery: `orchid plugins list` shows the role plugin as kind=role ----
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 with a planted role plugin + engine"
assert_match "^acme/researcher	role	0.1.0	user	user\$" "$out" "researcher role plugin is listed as kind=role, origin=user"
assert_match "^acme/citer	engine	0.1.0	user	user\$" "$out" "citer engine is listed"

# -- validate: kind=role needs no entrypoint, but descriptor.role must exist
# and match --------------------------------------------------------------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins validate acme/researcher)"; rc=$?
assert_eq 0 "$rc" "validate acme/researcher passes (kind=role, no entrypoint required)"
assert_match "^ok" "$out" "ok line printed for the role plugin"

# missing descriptor.role -> FAIL
mkdir -p "$WORK/broken_role"
printf 'manifest_version=1\nid=acme/brokenrole\nversion=0.1.0\nkind=role\napi_version=1\n' > "$WORK/broken_role/plugin.conf"
out="$(manifest_validate "$WORK/broken_role" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "manifest_validate must FAIL a kind=role plugin with no descriptor.role"
assert_match "descriptor.role missing" "$out" "FAIL names the missing descriptor.role"

# descriptor id mismatch -> FAIL
mkdir -p "$WORK/mismatch_role"
printf 'manifest_version=1\nid=acme/mismatch\nversion=0.1.0\nkind=role\napi_version=1\n' > "$WORK/mismatch_role/plugin.conf"
printf 'id=notmismatch\nrequires=structured_text\n' > "$WORK/mismatch_role/descriptor.role"
out="$(manifest_validate "$WORK/mismatch_role" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "manifest_validate must FAIL when descriptor.role id != manifest id's name part"
assert_match "does not match manifest id" "$out" "FAIL names the id mismatch"

# -- eligibility: agy (structured_text only) lacks citations ----------------
printf 'role.researcher=agy\n' > "$repo/orchid.config"
err="$(HOME="$home" ORCHID_ROOT="$REPO_ROOT" resolve_role_checked "$repo" researcher 2>&1 1>/dev/null)"; rc=$?
assert_eq 1 "$rc" "resolve_role_checked rejects agy for researcher (lacks citations)"
assert_match "engine agy missing required capability citations for role researcher" "$err" "clear missing-capability message, same shape as a built-in role"

# -- eligibility: a stub engine WITH citations passes -----------------------
printf 'role.researcher=citer\n' > "$repo/orchid.config"
out="$(HOME="$home" ORCHID_ROOT="$REPO_ROOT" resolve_role_checked "$repo" researcher)"; rc=$?
assert_eq 0 "$rc" "resolve_role_checked accepts citer for researcher (has structured_text,citations)"
assert_eq citer "$out" "resolve_role_checked returns citer"

rm -f "$repo/orchid.config"

# -- plugins test <engine> <custom-role>: capsuite works via the static
# checks (role_eligible resolved through the search path); the dryrun/
# workspace-write checks are skipped for any role _capsuite_op_for_role
# doesn't map (same as orchestrator today -- a pre-existing, honest gap,
# not something Task 7 introduces) -----------------------------------------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins test citer researcher)"; rc=$?
assert_eq 0 "$rc" "plugins test citer researcher passes (manifest_valid + capabilities_cover_role + binaries_present)"
assert_match "^PASS: citer researcher$" "$out" "PASS line for the custom role"
resfile="$home/.orchid/capsuite/citer--researcher.json"
[ -f "$resfile" ] || fail "capsuite result file written for a custom role pair"
nchecks="$(jq '.checks | length' "$resfile")"
assert_eq 3 "$nchecks" "custom role researcher: only the 3 role-agnostic checks run (no dryrun op mapping for it)"

out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins test agy researcher)"; rc=$?
[ "$rc" -ne 0 ] || fail "plugins test agy researcher must FAIL (agy lacks citations)"
assert_match "^FAIL: agy researcher$" "$out" "FAIL line for agy/researcher"

# -- doctor: a role.<custom> binding whose descriptor is undiscoverable is a
# FAIL; a discoverable one is an ok line naming the descriptor ------------
homeD="$WORK/homeD"; mkdir -p "$homeD/.orchid"
{
  echo 'verify=true'
  echo "role.researcher=citer"
} > "$repo/orchid.config"
mkdir -p "$repo/eng/citer" # ORCHID_ENGINES_DIR test hook root for engine exe resolution
printf '#!/usr/bin/env bash\n' > "$repo/eng/citer/run"; chmod +x "$repo/eng/citer/run"
out="$(HOME="$homeD" ORCHID_REPO="$repo" ORCHID_ENGINES_DIR="$repo/eng" "$ORCHID_BIN" doctor)"; rc=$?
[ "$rc" -ne 0 ] || fail "doctor must FAIL: role.researcher is bound but no researcher descriptor is discoverable under \$HOME=homeD"
assert_match "role researcher: custom role has a config binding but no discoverable descriptor.role" "$out" "doctor names the undiscoverable custom-role descriptor"

out="$(HOME="$home" ORCHID_REPO="$repo" ORCHID_ENGINES_DIR="$repo/eng" "$ORCHID_BIN" doctor)"; rc=$?
assert_eq 0 "$rc" "doctor passes once the researcher descriptor is discoverable (under \$HOME=home) and citer is eligible"
assert_match "^ok: role researcher -> citer \(custom, descriptor: $home/.orchid/plugins/roles/researcher/descriptor.role\)\$" "$out" "doctor's custom-role line names the resolved chain and descriptor path"
rm -f "$repo/orchid.config"

# -- v1-m3 final review (TRIVIA): _role_custom_names must capture a HYPHENATED
# custom role id whole (e.g. "code-reviewer"), not stop at the first "-" --
# regression test for a regex that used to only allow [a-zA-Z0-9_], silently
# truncating "role.code-reviewer=..." down to just "code" and never
# discovering the real custom role at all. Scoped to _role_custom_names
# itself (not a full doctor round-trip): config_get's env-var shadow lookup
# (`_cfg_env_name`, lib/common.sh) has its own separate, pre-existing
# hyphen-handling gap unrelated to this regex -- out of scope here. -----------
mk_role_plugin "$home/.orchid/plugins/roles/code-reviewer" acme/code-reviewer code-reviewer structured_text
printf 'role.code-reviewer=citer\n' > "$repo/orchid.config"
hyphen_names="$(HOME="$home" ORCHID_ROOT="$REPO_ROOT" _role_custom_names "$repo")"
assert_match "^code-reviewer$" "$hyphen_names" "_role_custom_names captures a hyphenated role id whole"
grep -qxF "code" <<<"$hyphen_names" && fail "_role_custom_names must not truncate a hyphenated id at its first hyphen"
rm -f "$repo/orchid.config"

# -- INV-10: a custom role plugin whose descriptor id shadows a BUILT-IN
# role name (reviewer) is a collision, never a silent shadow -------------
homeS="$WORK/homeS"; mkdir -p "$homeS/.orchid"
mk_role_plugin "$homeS/.orchid/plugins/roles/reviewer" acme/reviewer reviewer structured_text

err="$(HOME="$homeS" ORCHID_ROOT="$REPO_ROOT" _role_file reviewer 2>&1 1>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] || fail "_role_file must error when a custom role plugin's descriptor id shadows the built-in 'reviewer'"
assert_match "duplicate role 'reviewer'" "$err" "INV-10 error names the duplicate role"
assert_match "INV-10" "$err" "INV-10 error names the invariant"

if HOME="$homeS" ORCHID_ROOT="$REPO_ROOT" role_eligible reviewer "$REPO_ROOT/plugins/engines/agy" 2>/dev/null; then
  fail "role_eligible must also refuse a shadowed 'reviewer' (ambiguous descriptor, INV-10) rather than silently picking one"
fi

# -- unbound custom role: exit 14 with the specific message ----------------
err="$(HOME="$home" ORCHID_ROOT="$REPO_ROOT" resolve_role_chain "$repo" ghostwriter 2>&1 1>/dev/null)"; rc=$?
assert_eq 14 "$rc" "resolve_role_chain exits 14 for an unbound custom role"
assert_match "no binding for custom role 'ghostwriter' \(set role.ghostwriter=\.\.\.\)" "$err" "exit-14 message names the exact config key to set"

err="$(HOME="$home" ORCHID_ROOT="$REPO_ROOT" resolve_role_available "$repo" ghostwriter 2>&1 1>/dev/null)"; rc=$?
assert_eq 14 "$rc" "resolve_role_available also propagates the same exit 14 for an unbound custom role"
assert_match "no binding for custom role 'ghostwriter'" "$err" "resolve_role_available's message matches resolve_role_chain's (never re-wrapped into the generic 'no eligible engine' message)"

# a BOUND custom role with a real chain must NOT trip the unbound path -----
printf 'role.ghostwriter=citer\n' > "$repo/orchid.config"
out="$(HOME="$home" ORCHID_ROOT="$REPO_ROOT" resolve_role_chain "$repo" ghostwriter)"; rc=$?
assert_eq 0 "$rc" "resolve_role_chain succeeds once role.ghostwriter is bound"
assert_eq citer "$out" "resolve_role_chain returns the configured chain for a bound custom role"
rm -f "$repo/orchid.config"

# -- role_binding_blocking: default true, config-overridable ----------------
assert_eq true "$(role_binding_blocking "$repo" researcher)" "role_binding_blocking defaults to true with no config"
printf 'role.researcher.blocking=false\n' > "$repo/orchid.config"
assert_eq false "$(role_binding_blocking "$repo" researcher)" "role_binding_blocking honors role.<id>.blocking=false"
printf 'role.researcher.blocking=true\n' > "$repo/orchid.config"
assert_eq true "$(role_binding_blocking "$repo" researcher)" "role_binding_blocking honors an explicit true too"
rm -f "$repo/orchid.config"

# -- CRITICAL fix regression (code review finding): a role named ONLY via
# role.<id>.blocking (no role.<id>= binding at all) must not silently abort
# the whole `orchid doctor` run. Before the fix, resolve_role_chain's own
# exit 14 (unbound custom role) propagated straight through doctor's
# `set -euo pipefail` + an unguarded `var="$(cmd | tr ...)"` pipeline,
# killing the script mid-loop with NO diagnostic and skipping every check
# still to come (lockfile drift, integration branch, split-brain).
{ echo 'verify=true'; echo 'role.researcher.blocking=false'; } > "$repo/orchid.config"
rc=0; out="$(HOME="$home" ORCHID_REPO="$repo" ORCHID_ENGINES_DIR="$repo/eng" "$ORCHID_BIN" doctor)" || rc=$?
[ "$rc" -ne 0 ] || fail "doctor must FAIL: role.researcher.blocking is set but role.researcher itself is never bound"
assert_match "FAIL: role researcher: no binding \(set role.researcher=<engine>\[,fallback\]\)" "$out" "doctor names the missing binding instead of aborting silently"
assert_match "no split-brain checkout state" "$out" "doctor kept running past the custom-role loop -- every later check still executed"
rm -f "$repo/orchid.config"

# -- descriptor hook_bindings (doctor display only, m3, code review finding):
# a valid point appends "(hooks: ...)" to the role's ok line; an unknown
# point WARNs but never FAILs doctor ---------------------------------------
homeHB="$WORK/homeHB"; mkdir -p "$homeHB/.orchid"
mk_role_plugin "$homeHB/.orchid/plugins/roles/cataloger" acme/cataloger cataloger structured_text
printf 'hook_bindings=before_arbitration:acme/cataloger\n' >> "$homeHB/.orchid/plugins/roles/cataloger/descriptor.role"
{ echo 'verify=true'; echo 'role.cataloger=agy'; } > "$repo/orchid.config"
out="$(HOME="$homeHB" ORCHID_REPO="$repo" ORCHID_ENGINES_DIR="$repo/eng" "$ORCHID_BIN" doctor)"; rc=$?
assert_eq 0 "$rc" "doctor passes with a valid hook_bindings entry on a custom role descriptor"
assert_match "^ok: role cataloger -> agy \(custom, descriptor: .*\) \(hooks: before_arbitration:acme/cataloger\)\$" "$out" "doctor's ok line appends the descriptor's hook_bindings"
rm -f "$repo/orchid.config"

homeHB2="$WORK/homeHB2"; mkdir -p "$homeHB2/.orchid"
mk_role_plugin "$homeHB2/.orchid/plugins/roles/archivist" acme/archivist archivist structured_text
printf 'hook_bindings=not_a_real_point:acme/archivist\n' >> "$homeHB2/.orchid/plugins/roles/archivist/descriptor.role"
{ echo 'verify=true'; echo 'role.archivist=agy'; } > "$repo/orchid.config"
out="$(HOME="$homeHB2" ORCHID_REPO="$repo" ORCHID_ENGINES_DIR="$repo/eng" "$ORCHID_BIN" doctor)"; rc=$?
assert_eq 0 "$rc" "an unknown hook point in hook_bindings WARNs, it never FAILs doctor"
assert_match "warn: role archivist: hook_bindings names unknown hook point 'not_a_real_point'" "$out" "doctor warns naming the unknown hook point"
assert_match "^ok: role archivist -> agy" "$out" "the role's own ok line still prints despite the unknown-point warning"
rm -f "$repo/orchid.config"
