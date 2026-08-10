#!/usr/bin/env bash
# INV-10: duplicate plugin IDs are an error, never a shadow (docs/specs/
# kernel.md's Conformance invariants). Task 3 (libexec/orchid-plugins'
# _plugins_collisions) already implements COLLISION detection in `orchid
# plugins list`, and `orchid doctor` already shells to `plugins list` for its
# plugins: section (see libexec/orchid-doctor) -- this test formalizes that
# behavior under the INV-10 name and proves it end-to-end across a real
# discovery search path: a duplicate id in TWO DIFFERENT roots (an
# $ORCHID_PLUGIN_PATH entry and ~/.orchid/plugins, not just two dirs under
# one root) must be a nonzero `plugins list` exit AND a doctor FAIL -- and
# neither colliding entry may vanish from the printed report (a silent
# precedence win would mean one just disappears; INV-10 requires both stay
# visible until an operator resolves the collision).
#
# RED: two plugins claiming the id `acme/shadow`, planted in two different
#      discovery roots below. `plugins list` must exit nonzero, `doctor` must
#      FAIL, and BOTH colliding rows must still be printed -- a silent
#      precedence win, where one binding quietly disappears and the run uses
#      whichever won, is the failure this gate exists for.
# GREEN: the same two kinds of discovery root, holding DISTINCT ids, must list
#      cleanly -- exit 0, no COLLISION line, both plugins still shown. It runs
#      in this file rather than being inferred from the fixture around it,
#      because everything else here is a rejection and a `plugins list` that
#      failed on any input at all would satisfy every one of them while
#      detecting no collision.
source "$(dirname "$0")/../helpers.sh"

mk_plugin() {  # dir id kind version
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=%s\nkind=%s\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
    "$2" "$4" "$3" > "$1/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

home="$WORK/home"; mkdir -p "$home/.orchid"
pathroot="$WORK/pathroot"
mk_plugin "$home/.orchid/plugins/engines/dupA" acme/shadow engine 0.1.0
mk_plugin "$pathroot/engines/dupB" acme/shadow engine 0.2.0
repo="$WORK/repo"; mkdir -p "$repo"

# 1) `orchid plugins list` -- nonzero exit, COLLISION line names the id and
# BOTH paths.
rc=0
out="$(HOME="$home" ORCHID_REPO="$repo" ORCHID_PLUGIN_PATH="$pathroot" "$ORCHID_BIN" plugins list)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-10: plugins list must exit nonzero on a duplicate id across the discovery search path"
assert_match "COLLISION: acme/shadow at" "$out" "INV-10: COLLISION line names the id"
assert_match "dupA" "$out" "INV-10: COLLISION line includes the first colliding path"
assert_match "dupB" "$out" "INV-10: COLLISION line includes the second colliding path"

# Never a silent shadow: BOTH colliding rows are still printed below the
# COLLISION line -- neither is dropped in favor of the other.
assert_match "acme/shadow	engine	0.1.0" "$out" "INV-10: the first colliding entry is still listed, not shadowed away"
assert_match "acme/shadow	engine	0.2.0" "$out" "INV-10: the second colliding entry is still listed, not shadowed away"

# THE GREEN TWIN, exercised in this file rather than assumed of the fixture
# around it. Everything above is a rejection, and a `plugins list` that failed
# on any input at all -- a broken discovery root, a manifest parser that always
# errors -- would satisfy every one of them while detecting no collision. So
# the same discovery is run over the same two kinds of root holding DISTINCT
# ids: it must exit 0, print no COLLISION line, and still list both plugins.
cleanhome="$WORK/clean-home"; mkdir -p "$cleanhome/.orchid"
cleanpath="$WORK/clean-pathroot"
mk_plugin "$cleanhome/.orchid/plugins/engines/soloA" acme/solo-a engine 0.1.0
mk_plugin "$cleanpath/engines/soloB" acme/solo-b engine 0.2.0
rc=0
clean_out="$(HOME="$cleanhome" ORCHID_REPO="$repo" ORCHID_PLUGIN_PATH="$cleanpath" "$ORCHID_BIN" plugins list)" || rc=$?
assert_eq 0 "$rc" "INV-10: two DISTINCT plugin ids across the same two discovery roots must list cleanly (got rc=$rc: $clean_out)"
grep -q 'COLLISION' <<<"$clean_out" \
  && fail "INV-10: a listing with no duplicate id printed a COLLISION line -- the detector is firing on discovery itself rather than on a collision"
assert_match "acme/solo-a	engine	0.1.0" "$clean_out" "INV-10: the home-root plugin is listed in the collision-free case"
assert_match "acme/solo-b	engine	0.2.0" "$clean_out" "INV-10: the path-root plugin is listed in the collision-free case"
green_case "two DISTINCT plugin ids across the same two discovery roots listed cleanly and exited 0, so the failures above are collision detection rather than discovery being broken outright"

# 2) `orchid doctor` -- FAILs, never silently passes with one binding
# arbitrarily winning.
(cd "$repo" && git init -q . && git commit -q --allow-empty -m root)
mkdir -p "$repo/eng/fake"
printf '#!/usr/bin/env bash\n' > "$repo/eng/fake/run"; chmod +x "$repo/eng/fake/run"
{
  echo 'verify=true'
  echo 'role.orchestrator=fake'
  echo 'role.implementer=fake'
  echo 'role.reviewer=fake'
  echo 'role.arbiter=fake'
  echo 'role.plan_critic=fake'
} > "$repo/orchid.config"

rc=0
out="$(HOME="$home" ORCHID_REPO="$repo" ORCHID_PLUGIN_PATH="$pathroot" ORCHID_ENGINES_DIR="$repo/eng" "$ORCHID_BIN" doctor)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-10: doctor must FAIL on a duplicate plugin id, never silently pass"
assert_match "FAIL.*collision" "$out" "INV-10: doctor reports the collision as a FAIL"
assert_match "COLLISION: acme/shadow" "$out" "INV-10: doctor's plugins: section shows the COLLISION line"
red_case "a duplicate plugin id across two discovery roots failed both plugins list and doctor, with neither colliding entry silently shadowed away"
