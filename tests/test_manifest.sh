#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"

# -- fixtures ---------------------------------------------------------------
mk_conf() {  # dir conf-body
  mkdir -p "$1"
  printf '%s' "$2" > "$1/plugin.conf"
}
mk_valid() {  # dir  (valid engine manifest + executable entrypoint)
  mk_conf "$1" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
requires_orchid=>=1.0
capabilities=structured_text,workspace_read
entrypoint=run
'
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

# valid manifest passes, prints an ok line
mk_valid "$WORK/p1"
out="$(manifest_validate "$WORK/p1")"; rc=$?
[ "$rc" -eq 0 ] || fail "valid manifest should pass (rc=$rc): $out"
assert_match "^ok" "$out" "ok line printed for a valid manifest"

# missing manifest_version -> FAIL (plain, not 13)
mk_conf "$WORK/p2" 'id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p2/run"; chmod +x "$WORK/p2/run"
out="$(manifest_validate "$WORK/p2" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "missing manifest_version must fail"
[ "$rc" -ne 13 ] || fail "missing manifest_version is a plain FAIL, not the unknown-version reject (13)"
assert_match "FAIL" "$out" "FAIL printed for missing manifest_version"

# manifest_version=2 -> reject, exit 13
mk_conf "$WORK/p3" 'manifest_version=2
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p3/run"; chmod +x "$WORK/p3/run"
manifest_validate "$WORK/p3" >/dev/null 2>&1
assert_eq 13 "$?" "unknown manifest_version rejects with exit 13"

# unqualified id (no publisher/name) -> FAIL
mk_conf "$WORK/p4" 'manifest_version=1
id=codex
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p4/run"; chmod +x "$WORK/p4/run"
out="$(manifest_validate "$WORK/p4" 2>&1)"
[ "$?" -ne 0 ] || fail "unqualified id must fail"
assert_match "FAIL" "$out" "FAIL printed for unqualified id"

# id containing '..' -> FAIL
mk_conf "$WORK/p5" 'manifest_version=1
id=orchid/../etc
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p5/run"; chmod +x "$WORK/p5/run"
out="$(manifest_validate "$WORK/p5" 2>&1)"
[ "$?" -ne 0 ] || fail "id with '..' must fail"
assert_match "FAIL" "$out" "FAIL printed for id containing '..'"

# unknown capability atom -> FAIL
mk_conf "$WORK/p6" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text,teleportation
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p6/run"; chmod +x "$WORK/p6/run"
out="$(manifest_validate "$WORK/p6" 2>&1)"
[ "$?" -ne 0 ] || fail "unknown capability atom must fail"
assert_match "FAIL" "$out" "FAIL printed for unknown capability atom"

# unknown extra key -> warn (to stderr) but still valid
mk_conf "$WORK/p7" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
mystery_key=1
'
printf '#!/usr/bin/env bash\n' > "$WORK/p7/run"; chmod +x "$WORK/p7/run"
out="$(manifest_validate "$WORK/p7" 2>/dev/null)"; rc=$?
err="$(manifest_validate "$WORK/p7" 2>&1 >/dev/null)"
[ "$rc" -eq 0 ] || fail "unknown extra key must still be valid (rc=$rc)"
assert_match "^ok" "$out" "ok line still printed despite unknown key"
assert_match "warn.*mystery_key" "$err" "unknown key warned on stderr"

# unknown api_version -> reject, exit 13
mk_conf "$WORK/p8" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=2
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p8/run"; chmod +x "$WORK/p8/run"
manifest_validate "$WORK/p8" >/dev/null 2>&1
assert_eq 13 "$?" "unknown api_version rejects with exit 13"

# missing entrypoint file -> FAIL (engine kind requires one)
mk_conf "$WORK/p9" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
'
out="$(manifest_validate "$WORK/p9" 2>&1)"
[ "$?" -ne 0 ] || fail "missing entrypoint executable must fail"
assert_match "FAIL" "$out" "FAIL printed for missing entrypoint"

# archetype kind: no entrypoint/capabilities required
mk_conf "$WORK/p10" 'manifest_version=1
id=orchid/sample-archetype
version=0.1.0
kind=archetype
api_version=1
'
out="$(manifest_validate "$WORK/p10" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "archetype manifest without entrypoint/capabilities should pass (rc=$rc): $out"

# manifest_capabilities lists atoms one per line
mk_conf "$WORK/p11" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text,workspace_read,git
entrypoint=run
'
caps="$(manifest_capabilities "$WORK/p11")"
assert_eq "$(printf 'structured_text\nworkspace_read\ngit')" "$caps" "manifest_capabilities lists atoms one per line"

# manifest_get returns default when key absent
assert_eq default "$(manifest_get "$WORK/p11" no_such_key default)" "manifest_get default fallback"

# unknown api_version WITH an unknown key present -> the unknown-key warn
# loop still runs (diagnostics complete) before the reject-with-13
# short-circuit fires. Before this fix, the early `return 13` on unknown
# api_version skipped the warn loop entirely, silently dropping the
# mystery_key diagnostic.
mk_conf "$WORK/p12" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=2
capabilities=structured_text
entrypoint=run
mystery_key=1
'
printf '#!/usr/bin/env bash\n' > "$WORK/p12/run"; chmod +x "$WORK/p12/run"
err="$(manifest_validate "$WORK/p12" 2>&1 >/dev/null)"; rc=$?
assert_eq 13 "$rc" "unknown api_version still rejects with exit 13 even when an unknown key is present"
assert_match "warn.*mystery_key" "$err" "unknown-key warn loop still runs before the unknown-api_version reject"

# non-integer api_version -> plain FAIL, exit 1 (not the fail-closed 13 --
# that reject is reserved for a known-but-unsupported api_version, not a
# malformed one).
mk_conf "$WORK/p13" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=abc
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\n' > "$WORK/p13/run"; chmod +x "$WORK/p13/run"
out="$(manifest_validate "$WORK/p13" 2>&1)"; rc=$?
assert_eq 1 "$rc" "non-integer api_version is a plain FAIL (exit 1), not the unknown-version reject (13)"
assert_match "FAIL" "$out" "FAIL printed for non-integer api_version"
assert_eq run "$(manifest_get "$WORK/p11" entrypoint)" "manifest_get reads a present key"

# known capability atoms constant file
assert_match "structured_text" "$(cat "$REPO_ROOT/lib/capabilities.txt")" "capabilities.txt has structured_text"
assert_match "workspace_write" "$(cat "$REPO_ROOT/lib/capabilities.txt")" "capabilities.txt has workspace_write"

# each of these built-in plugin dirs validates clean (representative sample,
# not exhaustive -- v1-m4 Task 6 adds engines/hermes to the sample)
for d in engines/codex engines/codex-review engines/agy engines/claude engines/hermes archetypes/feature; do
  full="$REPO_ROOT/plugins/$d"
  [ -d "$full" ] || fail "built-in plugin dir missing: $d"
  out="$(manifest_validate "$full" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || fail "built-in $d must validate clean (rc=$rc): $out"
  assert_match "^ok" "$out" "built-in $d prints ok"
done

# -- comma-list trimming (permissions AND capabilities) ----------------------
# A space after the comma must not leak into the emitted token (regression:
# untrimmed " B" defeats the launcher's `${!perm}` indirect expansion,
# silently failing to forward the permission and printing a misleading
# "permission  B requested, not set" -- two spaces, unreadable).
mk_conf "$WORK/p14" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
permissions=FOO_A, FOO_B
'
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/p14/run"; chmod +x "$WORK/p14/run"
perms="$(manifest_permissions "$WORK/p14")"
assert_eq "$(printf 'FOO_A\nFOO_B')" "$perms" "manifest_permissions trims a space after the comma"

mk_conf "$WORK/p15" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text, git
entrypoint=run
'
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/p15/run"; chmod +x "$WORK/p15/run"
caps="$(manifest_capabilities "$WORK/p15")"
assert_eq "$(printf 'structured_text\ngit')" "$caps" "manifest_capabilities trims a space after the comma"
out="$(manifest_validate "$WORK/p15" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "a spaced capability list must still validate clean (rc=$rc): $out"
assert_match "^ok" "$out" "spaced capability list prints ok, not a false unknown-atom FAIL"

# role_eligible must still work against a spaced capability list (own,
# independent split in lib/roles.sh -- a regression here would mean the
# trimming fix broke the accidental padding role_eligible relied on).
source "$REPO_ROOT/lib/roles.sh"
export ORCHID_ROOT="$REPO_ROOT"
mk_conf "$WORK/p16" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=workspace_write, shell, git
entrypoint=run
'
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/p16/run"; chmod +x "$WORK/p16/run"
role_eligible implementer "$WORK/p16" || fail "role_eligible must still recognize a spaced capability list (implementer requires workspace_write,shell,git)"

# -- requires_orchid (Task 8) -------------------------------------------
# `requires_orchid=>=X.Y` is checked against the running kernel's
# ORCHID_VERSION (lib/common.sh), major.minor only. p1's mk_valid already
# carries `requires_orchid=>=1.0` and passes (ORCHID_VERSION=1.0.0
# satisfies it) -- covered implicitly above. Here: an unsatisfiable
# requirement must reject fail-closed, same exit code (13) as an unknown
# manifest_version/api_version.
mk_conf "$WORK/p17" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
requires_orchid=>=2.0
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/p17/run"; chmod +x "$WORK/p17/run"
out="$(manifest_validate "$WORK/p17" 2>&1)"
assert_eq 13 "$?" "requires_orchid '>=2.0' unmet by orchid 1.0.0 rejects with exit 13"
assert_match "FAIL.*requires_orchid" "$out" "FAIL printed naming requires_orchid"

# a manifest with no requires_orchid key at all is unaffected (optional key)
mk_conf "$WORK/p18" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/p18/run"; chmod +x "$WORK/p18/run"
out="$(manifest_validate "$WORK/p18" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "no requires_orchid key at all must still validate clean (rc=$rc): $out"

# -- requires_orchid: numeric (not lexical) minor-version compare -----------
# p17 above only exercised a major-version bump (>=2.0 vs 1.0.0), which
# rejects the same way under numeric OR naive string comparison. Cover a
# two-digit minor version too: requires_orchid=>=1.10 against the running
# ORCHID_VERSION 1.0.0 (minor 0) must still reject (0 < 10 numerically).
mk_conf "$WORK/p19" 'manifest_version=1
id=orchid/sample
version=0.1.0
kind=engine
api_version=1
requires_orchid=>=1.10
capabilities=structured_text
entrypoint=run
'
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/p19/run"; chmod +x "$WORK/p19/run"
out="$(manifest_validate "$WORK/p19" 2>&1)"
assert_eq 13 "$?" "requires_orchid '>=1.10' unmet by orchid 1.0.0 rejects with exit 13"
assert_match "FAIL.*requires_orchid" "$out" "FAIL printed naming requires_orchid for '>=1.10'"

# -- _manifest_orchid_satisfies: prove the compare is NUMERIC, not lexical ---
# ORCHID_VERSION is fixed at 1.0.0 for the rest of this suite, so its
# minor (0) can't distinguish numeric from string ordering (both agree "0" <
# "10"). Call the compare helper directly in a subshell with ORCHID_VERSION
# overridden, using a minor-version pair where lexical and numeric ordering
# diverge: string-wise "9" > "10" (first char '9' > '1'), but numerically
# 9 < 10. A lexical-comparison bug would flip both of the assertions below.
if ( ORCHID_VERSION="1.9.0"; _manifest_orchid_satisfies ">=1.10" ); then
  fail "_manifest_orchid_satisfies: orchid 1.9 must NOT satisfy '>=1.10' (numeric 9 < 10; a lexical bug would wrongly pass since string '9' > '10')"
fi
if ! ( ORCHID_VERSION="1.10.0"; _manifest_orchid_satisfies ">=1.9" ); then
  fail "_manifest_orchid_satisfies: orchid 1.10 must satisfy '>=1.9' (numeric 10 >= 9; a lexical bug would wrongly reject since string '10' < '9')"
fi

# ============================================================================
# v1-m3 (m2 ledger finding, flagged in m2 Task 2): _manifest_split_csv's
# empty-input bash-3.2 quirk. `IFS=',' read -ra tokens <<< "$s"` on an empty
# $s leaves `tokens` genuinely UNSET in bash 3.2 (not an empty array), and
# `"${tokens[@]}"` on that under `set -u` (every test file, via helpers.sh;
# bin/orchid and most libexec/* entrypoints too) aborts with "tokens[@]:
# unbound variable" -- the same pitfall lib/roles.sh's role_eligibility_
# reason and lib/capsuite.sh's workspace_write_probe check already sidestep
# with a `tr ',' '\n'` + `while read` idiom instead. lib/capsuite.sh's
# binaries_present check calls _manifest_split_csv DIRECTLY on a manifest's
# (possibly absent) requires_binaries with no such guard, so a manifest with
# no requires_binaries key at all crashes `orchid plugins test` outright --
# every test fixture that exercises that path currently declares
# `requires_binaries=jq` purely to dodge this, never because the fixture
# actually needs it validated.
# ============================================================================
out="$(_manifest_split_csv "" 2>&1)"; rc=$?
assert_eq 0 "$rc" "_manifest_split_csv on an empty string must not abort under set -u (got: $out)"
assert_eq "" "$out" "_manifest_split_csv on an empty string yields zero tokens"

# a manifest with NO requires_binaries key at all (the common real-world
# shape: p1's mk_valid fixture above never set one) must still split cleanly
# via manifest_get's default-empty return, end to end.
out2="$(_manifest_split_csv "$(manifest_get "$WORK/p1" requires_binaries)" 2>&1)"; rc2=$?
assert_eq 0 "$rc2" "_manifest_split_csv(manifest_get ... requires_binaries) must not abort when the key is entirely absent"
assert_eq "" "$out2" "an absent requires_binaries key yields zero binary tokens, not an error"
