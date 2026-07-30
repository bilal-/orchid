#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# row_re <id> <kind> <version> <origin> <trust> -- builds the exact
# tab-separated row regex `orchid plugins list` must print for one plugin.
row_re() { printf '^%s\t%s\t%s\t%s\t%s$' "$1" "$2" "$3" "$4" "$5"; }

mk_plugin() {  # dir id kind version [capabilities]
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=%s\nkind=%s\napi_version=1\ncapabilities=%s\nentrypoint=run\n' \
    "$2" "$4" "$3" "${5:-structured_text}" > "$1/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

reposA="$WORK/repoA"; mkdir -p "$reposA"
homeA="$WORK/homeA"; mkdir -p "$homeA/.orchid"

# -- built-ins only, clean HOME/repo -----------------------------------------
# v1-m2 Task 4 adds a second built-in archetype (orchid/review, alongside
# orchid/feature). v1-m3 Task 8 adds three more (orchid/refactor, orchid/
# test, orchid/migrate) -- 9 built-ins. v1-m4 Task 6 adds a fifth built-in
# engine (orchid/hermes, review/critique only) -- 10 built-ins total from
# here on.
out="$(HOME="$homeA" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 with only built-ins"
lines="$(echo "$out" | wc -l | tr -d ' ')"
assert_eq 10 "$lines" "exactly the 10 built-ins are listed with a clean HOME/repo"
for row in "orchid/codex engine 0.1.0 builtin builtin" \
           "orchid/codex-review engine 0.1.0 builtin builtin" \
           "orchid/agy engine 0.1.0 builtin builtin" \
           "orchid/claude engine 0.1.0 builtin builtin" \
           "orchid/hermes engine 0.1.0 builtin builtin" \
           "orchid/feature archetype 0.1.0 builtin builtin" \
           "orchid/review archetype 0.1.0 builtin builtin" \
           "orchid/refactor archetype 0.1.0 builtin builtin" \
           "orchid/test archetype 0.1.0 builtin builtin" \
           "orchid/migrate archetype 0.1.0 builtin builtin"; do
  assert_match "$(row_re $row)" "$out" "built-in row: $row"
done

# -- a user plugin (sandbox HOME) shows origin=user, trust=user -------------
homeB="$WORK/homeB"
mk_plugin "$homeB/.orchid/plugins/engines/fake" acme/fake engine 0.2.0
out="$(HOME="$homeB" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list still exits 0 with one added user plugin"
assert_match "$(row_re acme/fake engine 0.2.0 user user)" "$out" "user plugin: origin=user trust=user"
lines="$(echo "$out" | wc -l | tr -d ' ')"
assert_eq 11 "$lines" "10 built-ins + 1 user plugin"

# -- ORCHID_PLUGIN_PATH entries show origin=path, trust=user -----------------
pathroot="$WORK/pathroot"
mk_plugin "$pathroot/engines/pathy" acme/pathy engine 0.3.0
out="$(HOME="$homeA" ORCHID_REPO="$reposA" ORCHID_PLUGIN_PATH="$pathroot" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 with an ORCHID_PLUGIN_PATH entry"
assert_match "$(row_re acme/pathy engine 0.3.0 path user)" "$out" "ORCHID_PLUGIN_PATH entry: origin=path trust=user"

# -- duplicate id across the discovered set -> COLLISION + nonzero (INV-10) -
homeD="$WORK/homeD"
mk_plugin "$homeD/.orchid/plugins/engines/dup1" acme/dup engine 0.1.0
mk_plugin "$homeD/.orchid/plugins/engines/dup2" acme/dup engine 0.1.0
rc=0; out="$(HOME="$homeD" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins list)" || rc=$?
[ "$rc" -ne 0 ] || fail "plugins list must exit nonzero on a duplicate id (INV-10)"
assert_match "COLLISION: acme/dup at" "$out" "COLLISION line names the id"
assert_match "dup1" "$out" "COLLISION line includes the first colliding path"
assert_match "dup2" "$out" "COLLISION line includes the second colliding path"

# -- repo-local is discovered but DISABLED, and never collides --------------
reposE="$WORK/repoE"
mk_plugin "$reposE/.orchid/plugins/engines/codex" orchid/codex engine 9.9.9
homeE="$WORK/homeE"; mkdir -p "$homeE/.orchid"
out="$(HOME="$homeE" ORCHID_REPO="$reposE" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "a repo-local plugin sharing a built-in's id must NOT trigger a collision (excluded, DISABLED)"
assert_match "$(row_re orchid/codex engine 9.9.9 repo 'DISABLED \(untrusted\)')" "$out" "repo-local plugin: origin=repo trust=DISABLED (untrusted), untrusted by default (INV-09, Task 4)"

# -- validate --all: clean (built-ins only) ----------------------------------
out="$(HOME="$homeA" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins validate --all)"; rc=$?
assert_eq 0 "$rc" "validate --all passes with only built-ins"
okcount="$(echo "$out" | grep -c '^ok:')"
assert_eq 10 "$okcount" "validate --all prints an ok line per built-in"

# -- validate --all: a malformed planted manifest aggregate-fails (exit 13) --
homeG="$WORK/homeG"
mkdir -p "$homeG/.orchid/plugins/engines/broken"
printf 'id=acme/broken\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$homeG/.orchid/plugins/engines/broken/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$homeG/.orchid/plugins/engines/broken/run"; chmod +x "$homeG/.orchid/plugins/engines/broken/run"
rc=0; out="$(HOME="$homeG" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins validate --all)" || rc=$?
assert_eq 13 "$rc" "validate --all aggregate-fails (exit 13) on a malformed manifest"
assert_match "FAIL.*broken" "$out" "the malformed manifest's FAIL line surfaces"

# -- validate <id>: single id, known and unknown -----------------------------
out="$(HOME="$homeA" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins validate orchid/codex)"; rc=$?
assert_eq 0 "$rc" "validate <id> passes for a valid built-in id"
assert_match "^ok" "$out" "validate <id> prints an ok line"
rc=0; HOME="$homeA" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins validate no/such-id >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "validate <id> must fail for an unknown id"

# -- doctor gains a plugins: section, printed before role checks ------------
repoI="$WORK/repoI"; mkdir -p "$repoI"
(cd "$repoI" && git init -q . && git commit -q --allow-empty -m root)
homeI="$WORK/homeI"; mkdir -p "$homeI/.orchid"
mkdir -p "$repoI/eng/fake"; printf '#!/usr/bin/env bash\n' > "$repoI/eng/fake/run"; chmod +x "$repoI/eng/fake/run"
{
  echo 'verify=true'
  echo 'role.orchestrator=fake'
  echo 'role.implementer=fake'
  echo 'role.reviewer=fake'
  echo 'role.arbiter=fake'
  echo 'role.plan_critic=fake'
} > "$repoI/orchid.config"

out="$(HOME="$homeI" ORCHID_REPO="$repoI" ORCHID_ENGINES_DIR="$repoI/eng" "$ORCHID_BIN" doctor)"; rc=$?
assert_eq 0 "$rc" "doctor passes cleanly with no plugin collisions"
assert_match "^plugins:" "$out" "doctor prints a plugins: section"
pidx="$(echo "$out" | grep -n '^plugins:' | head -1 | cut -d: -f1)"
ridx="$(echo "$out" | grep -n 'role orchestrator' | head -1 | cut -d: -f1)"
{ [ -n "$pidx" ] && [ -n "$ridx" ] && [ "$pidx" -lt "$ridx" ]; } || fail "plugins: section must print before role checks"

# -- doctor FAILs when plugin discovery reports a collision ------------------
homeJ="$WORK/homeJ"
mk_plugin "$homeJ/.orchid/plugins/engines/dupA" acme/dupdoctor engine 0.1.0
mk_plugin "$homeJ/.orchid/plugins/engines/dupB" acme/dupdoctor engine 0.1.0
rc=0; out="$(HOME="$homeJ" ORCHID_REPO="$repoI" ORCHID_ENGINES_DIR="$repoI/eng" "$ORCHID_BIN" doctor)" || rc=$?
[ "$rc" -ne 0 ] || fail "doctor must FAIL when plugin discovery reports a collision"
assert_match "FAIL.*collision" "$out" "doctor reports the collision as a FAIL"
assert_match "COLLISION: acme/dupdoctor" "$out" "doctor's plugins: section shows the COLLISION line"

# -- doctor surfaces a permission-requested-but-not-set WARNING -------------
# The brief requires BOTH `orchid plugins validate` and `orchid doctor` to
# warn "permission X requested but not set" (previously only `plugins
# validate` did, since doctor only ever shelled to `plugins list`, never
# `plugins validate`). UNSET_VAR is deliberately never exported anywhere in
# this test.
homeK="$WORK/homeK"
mk_plugin "$homeK/.orchid/plugins/engines/permcheck" acme/permcheck engine 0.1.0
printf 'permissions=UNSET_VAR\n' >> "$homeK/.orchid/plugins/engines/permcheck/plugin.conf"
out="$(HOME="$homeK" ORCHID_REPO="$repoI" ORCHID_ENGINES_DIR="$repoI/eng" "$ORCHID_BIN" doctor)"; rc=$?
assert_eq 0 "$rc" "doctor still passes cleanly (a permission-not-set is a WARNING, not a FAIL)"
assert_match "permission UNSET_VAR requested, not set" "$out" "doctor surfaces the permission-not-set warning naming UNSET_VAR"

# -- doctor FAILs (exit 1) on a malformed plugin manifest --------------------
homeL="$WORK/homeL"
mkdir -p "$homeL/.orchid/plugins/engines/malformed"
printf 'id=acme/malformed\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\nmanifest_version=2\n' \
  > "$homeL/.orchid/plugins/engines/malformed/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$homeL/.orchid/plugins/engines/malformed/run"; chmod +x "$homeL/.orchid/plugins/engines/malformed/run"
rc=0; out="$(HOME="$homeL" ORCHID_REPO="$repoI" ORCHID_ENGINES_DIR="$repoI/eng" "$ORCHID_BIN" doctor)" || rc=$?
assert_eq 1 "$rc" "doctor FAILs (exit 1) when a discovered plugin manifest is malformed"
assert_match "FAIL.*validat" "$out" "doctor reports the malformed manifest as a validate FAIL"

# -- v1-m3 Task 7: a kind=role plugin (plugin.conf + descriptor.role) lists
# and validates like any other plugin. Discovery is generic (any <root>/
# <kind-dir>/<name>/plugin.conf), so a "roles" dir needs no special-casing
# here -- this just proves that holds for kind=role specifically.
mk_role_plugin() {  # dir manifest-id role-id requires
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=0.1.0\nkind=role\napi_version=1\n' "$2" > "$1/plugin.conf"
  printf 'id=%s\nrequires=%s\ndescription=test role plugin\n' "$3" "$4" > "$1/descriptor.role"
}

homeR="$WORK/homeR"; mkdir -p "$homeR/.orchid"
mk_role_plugin "$homeR/.orchid/plugins/roles/researcher" acme/researcher researcher structured_text,citations
out="$(HOME="$homeR" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 with a planted kind=role plugin"
assert_match "$(row_re acme/researcher role 0.1.0 user user)" "$out" "kind=role plugin lists with kind=role, origin=user, trust=user"
lines="$(echo "$out" | wc -l | tr -d ' ')"
assert_eq 11 "$lines" "10 built-ins + 1 role plugin"

out="$(HOME="$homeR" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins validate acme/researcher)"; rc=$?
assert_eq 0 "$rc" "validate acme/researcher passes (kind=role needs no entrypoint)"
assert_match "^ok" "$out" "ok line printed for the role plugin"

# a kind=role plugin missing descriptor.role fails validate/--all (exit 13,
# same aggregate-fail discipline as any other malformed manifest)
homeRB="$WORK/homeRB"
mkdir -p "$homeRB/.orchid/plugins/roles/brokenrole"
printf 'manifest_version=1\nid=acme/brokenrole\nversion=0.1.0\nkind=role\napi_version=1\n' \
  > "$homeRB/.orchid/plugins/roles/brokenrole/plugin.conf"
rc=0; out="$(HOME="$homeRB" ORCHID_REPO="$reposA" "$ORCHID_BIN" plugins validate --all)" || rc=$?
[ "$rc" -ne 0 ] || fail "validate --all must fail a kind=role plugin with no descriptor.role"
assert_match "FAIL.*descriptor.role missing" "$out" "validate --all names the missing descriptor.role"
