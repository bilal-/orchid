#!/usr/bin/env bash
# v1-m3 Task 9: plugin lifecycle -- install/update/remove/audit
# (libexec/orchid-plugins). Each scenario below gets its own sandbox HOME
# (and, where a repo is needed, its own repo dir) so scenarios can never
# interact via shared discovery/collision state.
source "$(dirname "$0")/helpers.sh"

mk_engine() {  # dir id version -- a minimal valid engine plugin
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=%s\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
    "$2" "$3" > "$1/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

# -- install: local dir -> sandbox ~/.orchid/plugins/engines/<name>, with
# a .provenance whose installed_digest matches plugin_digest_content -------
homeA="$WORK/homeA"; mkdir -p "$homeA/.orchid"
repoA="$WORK/repoA"; mkdir -p "$repoA"
srcA="$WORK/srcA"; mk_engine "$srcA" acme/widget 0.1.0

out="$(HOME="$homeA" ORCHID_REPO="$repoA" "$ORCHID_BIN" plugins install "$srcA")"; rc=$?
assert_eq 0 "$rc" "install from a local dir succeeds"
assert_match "^installed: acme/widget \(engine\)" "$out" "install prints a confirmation naming id and kind"

destA="$homeA/.orchid/plugins/engines/widget"
[ -d "$destA" ] || fail "install lands at $destA"
[ -f "$destA/plugin.conf" ] || fail "installed plugin dir carries its manifest"
[ -f "$destA/.provenance" ] || fail "install writes .provenance"

canonsrcA="$(cd "$srcA" && pwd -P)"
prov="$(cat "$destA/.provenance")"
assert_match "^source=$canonsrcA$" "$prov" "provenance records the canonical local source path"
assert_match "^ref=-$" "$prov" "provenance ref is '-' for a non-git local source"
digest_line="$(echo "$prov" | grep '^installed_digest=')"
[ -n "$digest_line" ] || fail "provenance records installed_digest"

expect_digest="$(HOME="$homeA" ORCHID_ROOT="$REPO_ROOT" bash -c \
  'source "$ORCHID_ROOT/lib/common.sh"; plugin_digest_content "$1"' _ "$destA")"
assert_eq "installed_digest=$expect_digest" "$digest_line" \
  "installed_digest matches plugin_digest_content (the metadata-excluding digest) of the dest dir"

assert_match "orchid plugins test widget <role>" "$out" "install prints next-step: plugins test <name> <role>"
assert_match "orchid plugins lock" "$out" "install prints next-step: plugins lock"

# ---------------------------------------------------------------------------
# v1-m3 final review (TRIVIA): the half-installed-dir cleanup trap must be
# set BEFORE `cp -R` runs, not after -- a `cp -R` that itself fails partway
# (an unreadable file deep in the source tree, here) used to leave a
# partial destination dir behind forever, since no trap was registered yet
# at the point of failure.
# ---------------------------------------------------------------------------
homeCpFail="$WORK/homeCpFail"; mkdir -p "$homeCpFail/.orchid"
repoCpFail="$WORK/repoCpFail"; mkdir -p "$repoCpFail"
srcCpFail="$WORK/srcCpFail"; mk_engine "$srcCpFail" acme/cpfail 0.1.0
mkdir -p "$srcCpFail/sub"; echo "unreadable" > "$srcCpFail/sub/blocked"; chmod 000 "$srcCpFail/sub/blocked"
rc=0
HOME="$homeCpFail" ORCHID_REPO="$repoCpFail" "$ORCHID_BIN" plugins install "$srcCpFail" >/dev/null 2>&1 || rc=$?
chmod 644 "$srcCpFail/sub/blocked"   # restore so the scratch dir can be cleaned up on exit
[ "$rc" -ne 0 ] || fail "install with an unreadable source file must fail, not silently succeed"
[ ! -e "$homeCpFail/.orchid/plugins/engines/cpfail" ] \
  || fail "a cp -R failure mid-install must not leave a half-installed plugin dir behind"

# -- duplicate install is refused, pointed at 'update' ----------------------
rc=0; out="$(HOME="$homeA" ORCHID_REPO="$repoA" "$ORCHID_BIN" plugins install "$srcA" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "duplicate install must be refused"
assert_match "update" "$out" "duplicate-install refusal points at 'update'"

# -- collision with a built-in id is refused (INV-10) -----------------------
homeC="$WORK/homeC"; mkdir -p "$homeC/.orchid"
repoC="$WORK/repoC"; mkdir -p "$repoC"
srcC="$WORK/srcC"; mk_engine "$srcC" orchid/claude 9.9.9

rc=0; out="$(HOME="$homeC" ORCHID_REPO="$repoC" "$ORCHID_BIN" plugins install "$srcC" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "install must refuse an id colliding with a built-in (INV-10)"
assert_match "INV-10" "$out" "collision refusal names INV-10"
[ ! -e "$homeC/.orchid/plugins/engines/claude" ] || fail "a refused collision install must not land on disk"

# -- --kind is a sanity guard against the manifest's OWN declared kind -----
homeD="$WORK/homeD"; mkdir -p "$homeD/.orchid"
repoD="$WORK/repoD"; mkdir -p "$repoD"
srcD="$WORK/srcD"; mk_engine "$srcD" acme/kindcheck 0.1.0

rc=0; out="$(HOME="$homeD" ORCHID_REPO="$repoD" "$ORCHID_BIN" plugins install "$srcD" --kind archetype 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "install --kind mismatching the manifest's declared kind must be refused"
assert_match "kind" "$out" "kind-mismatch refusal mentions kind"
[ ! -e "$homeD/.orchid/plugins" ] || fail "a refused --kind mismatch must not create any plugin dir"

out="$(HOME="$homeD" ORCHID_REPO="$repoD" "$ORCHID_BIN" plugins install "$srcD" --kind engine)"; rc=$?
assert_eq 0 "$rc" "install --kind matching the manifest's declared kind succeeds"
[ -d "$homeD/.orchid/plugins/engines/kindcheck" ] || fail "install --kind engine lands under engines/"

# -- an invalid manifest is refused with exit 13, nothing lands on disk ----
homeE="$WORK/homeE"; mkdir -p "$homeE/.orchid"
repoE="$WORK/repoE"; mkdir -p "$repoE"
srcE="$WORK/srcE"; mkdir -p "$srcE"
printf 'manifest_version=1\nid=acme/badengine\nversion=0.1.0\nkind=engine\napi_version=2\nrequires_orchid=>=1.0\n' \
  > "$srcE/plugin.conf"

rc=0; HOME="$homeE" ORCHID_REPO="$repoE" "$ORCHID_BIN" plugins install "$srcE" >/dev/null 2>&1 || rc=$?
assert_eq 13 "$rc" "install refuses an invalid manifest with exit 13"
[ ! -e "$homeE/.orchid/plugins/engines/badengine" ] || fail "a failed-validation install must not land on disk"

# -- update: re-fetches from provenance, re-validates, swaps version+digest -
homeF="$WORK/homeF"; mkdir -p "$homeF/.orchid"
repoF="$WORK/repoF"; mkdir -p "$repoF"
srcF="$WORK/srcF"; mk_engine "$srcF" acme/upd 0.1.0
HOME="$homeF" ORCHID_REPO="$repoF" "$ORCHID_BIN" plugins install "$srcF" >/dev/null

destF="$homeF/.orchid/plugins/engines/upd"
olddigest="$(grep '^installed_digest=' "$destF/.provenance")"

mk_engine "$srcF" acme/upd 0.2.0
printf '# bumped\n' >> "$srcF/run"

out="$(HOME="$homeF" ORCHID_REPO="$repoF" "$ORCHID_BIN" plugins update upd)"; rc=$?
assert_eq 0 "$rc" "update succeeds from a bumped local source"
assert_match "0\.1\.0 -> 0\.2\.0" "$out" "update reports the version bump"

newver="$(grep '^version=' "$destF/plugin.conf" | cut -d= -f2)"
assert_eq 0.2.0 "$newver" "installed manifest now reflects the bumped version"
newdigest="$(grep '^installed_digest=' "$destF/.provenance")"
[ "$newdigest" != "$olddigest" ] || fail "update must produce a new installed_digest once content changed"
[ ! -d "$destF/.git" ] || fail "update must not ship any .git metadata into the installed plugin dir"

# -- regression: plugin_digest_content must be PATH-INDEPENDENT (review
# finding) -- update builds the replacement in a TEMP dir
# ("$destF.build.XXXXXX") and records installed_digest there BEFORE the mv
# swap into "$destF" itself; a digest that bakes in the absolute path would
# make audit report "modified since install" on EVERY updated plugin,
# forever, even with zero actual drift. Own sandbox (homeJ) so this
# regression check's own tamper never interferes with homeF's later
# scenarios below.
homeJ="$WORK/homeJ"; mkdir -p "$homeJ/.orchid"
repoJ="$WORK/repoJ"; mkdir -p "$repoJ"
srcJ="$WORK/srcJ"; mk_engine "$srcJ" acme/pathindep 0.1.0
HOME="$homeJ" ORCHID_REPO="$repoJ" "$ORCHID_BIN" plugins install "$srcJ" >/dev/null
destJ="$homeJ/.orchid/plugins/engines/pathindep"

mk_engine "$srcJ" acme/pathindep 0.2.0
printf '# bumped\n' >> "$srcJ/run"
HOME="$homeJ" ORCHID_REPO="$repoJ" "$ORCHID_BIN" plugins update pathindep >/dev/null

out="$(HOME="$homeJ" ORCHID_REPO="$repoJ" "$ORCHID_BIN" plugins audit pathindep)"; rc=$?
assert_eq 0 "$rc" "audit succeeds right after an update"
assert_match "digest: unchanged" "$out" \
  "audit reports digest: unchanged after update -- plugin_digest_content must not depend on the temp-build-vs-dest absolute path"

printf '# tampered post-update\n' >> "$destJ/run"
out="$(HOME="$homeJ" ORCHID_REPO="$repoJ" "$ORCHID_BIN" plugins audit pathindep)"; rc=$?
assert_eq 0 "$rc" "audit still succeeds after a real tamper"
assert_match "modified since install" "$out" "audit reports modified since install after a REAL post-update tamper"

# -- update prints a stale-capsuite note when a prior result is on record --
mkdir -p "$homeF/.orchid/capsuite"
printf '{"engine":"upd","role":"implementer","passed":true,"checks":[],"tested_at_marker":"deadbeef"}' \
  > "$homeF/.orchid/capsuite/upd--implementer.json"
mk_engine "$srcF" acme/upd 0.3.0

out="$(HOME="$homeF" ORCHID_REPO="$repoF" "$ORCHID_BIN" plugins update upd)"; rc=$?
assert_eq 0 "$rc" "update still succeeds with a prior capsuite result on record"
assert_match "stale" "$out" "update prints a stale-capsuite note when a prior capsuite result exists"
assert_match "orchid plugins test upd implementer" "$out" "stale-capsuite note names the re-run command"

# -- ... but NOT when the re-fetched content is byte-identical (Minor,
# review) -- a re-run against an unchanged source must not claim a fresh
# capsuite result went stale when nothing about the plugin's content did.
out="$(HOME="$homeF" ORCHID_REPO="$repoF" "$ORCHID_BIN" plugins update upd)"; rc=$?
assert_eq 0 "$rc" "a second, no-op update (unchanged source) still succeeds"
if echo "$out" | grep -q stale; then
  fail "update must not print a stale-capsuite note when installed_digest did not actually change"
fi

# -- update refuses when the local source dir has vanished -----------------
homeG="$WORK/homeG"; mkdir -p "$homeG/.orchid"
repoG="$WORK/repoG"; mkdir -p "$repoG"
srcG="$WORK/srcG"; mk_engine "$srcG" acme/vanish 0.1.0
HOME="$homeG" ORCHID_REPO="$repoG" "$ORCHID_BIN" plugins install "$srcG" >/dev/null
rm -rf "$srcG"

rc=0; out="$(HOME="$homeG" ORCHID_REPO="$repoG" "$ORCHID_BIN" plugins update vanish 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "update must refuse when the local source dir has vanished"
assert_match "no longer exists" "$out" "update refusal names the vanished source"

rc=0; HOME="$homeG" ORCHID_REPO="$repoG" "$ORCHID_BIN" plugins update nosuchname >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "update must refuse an unknown installed plugin name"

# -- remove deletes the installed plugin dir --------------------------------
homeH="$WORK/homeH"; mkdir -p "$homeH/.orchid"
repoH="$WORK/repoH"; mkdir -p "$repoH"
srcH="$WORK/srcH"; mk_engine "$srcH" acme/removeme 0.1.0
HOME="$homeH" ORCHID_REPO="$repoH" "$ORCHID_BIN" plugins install "$srcH" >/dev/null
destH="$homeH/.orchid/plugins/engines/removeme"
[ -d "$destH" ] || fail "setup: install must land before the remove test runs"

out="$(HOME="$homeH" ORCHID_REPO="$repoH" "$ORCHID_BIN" plugins remove removeme)"; rc=$?
assert_eq 0 "$rc" "remove succeeds"
[ ! -e "$destH" ] || fail "remove must delete the installed plugin dir"
assert_match "plugins lock" "$out" "remove prints the generic lockfile-refresh reminder"

rc=0; HOME="$homeH" ORCHID_REPO="$repoH" "$ORCHID_BIN" plugins remove removeme >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "remove must refuse an already-removed/unknown name"

# -- audit: per-plugin block, modified-since-install after a tamper --------
homeI="$WORK/homeI"; mkdir -p "$homeI/.orchid"
repoI="$WORK/repoI"; mkdir -p "$repoI"
srcI="$WORK/srcI"; mk_engine "$srcI" acme/auditme 0.1.0
HOME="$homeI" ORCHID_REPO="$repoI" "$ORCHID_BIN" plugins install "$srcI" >/dev/null
destI="$homeI/.orchid/plugins/engines/auditme"

out="$(HOME="$homeI" ORCHID_REPO="$repoI" "$ORCHID_BIN" plugins audit auditme)"; rc=$?
assert_eq 0 "$rc" "audit exits 0 for a valid, unmodified install"
assert_match "=== acme/auditme ===" "$out" "audit prints a header block for the plugin"
assert_match "digest: unchanged" "$out" "audit reports digest unchanged before any tamper"
assert_match "capsuite: none on record" "$out" "audit reports no capsuite record when none exists"
assert_match "validate: OK" "$out" "audit reports validate OK"

printf '# tampered\n' >> "$destI/run"
out="$(HOME="$homeI" ORCHID_REPO="$repoI" "$ORCHID_BIN" plugins audit auditme)"; rc=$?
assert_eq 0 "$rc" "audit still exits 0 -- a content tamper alone isn't a manifest-validation failure"
assert_match "modified since install" "$out" "audit reports 'modified since install' after a tamper"

# -- provenance sig=: hand-editing source=/ref= is invisible to the content
# digest (which deliberately excludes .provenance) -- a sig= line binds
# those two lines so tampering with either is still detectable, and update
# refuses to fetch from a provenance it no longer trusts (review finding).
homeK="$WORK/homeK"; mkdir -p "$homeK/.orchid"
repoK="$WORK/repoK"; mkdir -p "$repoK"
srcK="$WORK/srcK"; mk_engine "$srcK" acme/sigcheck 0.1.0
HOME="$homeK" ORCHID_REPO="$repoK" "$ORCHID_BIN" plugins install "$srcK" >/dev/null
destK="$homeK/.orchid/plugins/engines/sigcheck"

[ -n "$(grep '^sig=' "$destK/.provenance")" ] || fail ".provenance must record a sig= line"

out="$(HOME="$homeK" ORCHID_REPO="$repoK" "$ORCHID_BIN" plugins audit sigcheck)"; rc=$?
assert_eq 0 "$rc" "audit succeeds before any provenance tamper"
if echo "$out" | grep -q TAMPERED; then
  fail "audit must not report TAMPERED before source=/ref= have been touched"
fi

# hand-edit source= (a "poisoned" pointer) WITHOUT recomputing sig=
sed -i.bak 's#^source=.*#source=/nonexistent/poisoned/path#' "$destK/.provenance"
rm -f "$destK/.provenance.bak"

out="$(HOME="$homeK" ORCHID_REPO="$repoK" "$ORCHID_BIN" plugins audit sigcheck)"; rc=$?
assert_eq 0 "$rc" "audit still exits 0 -- a tampered provenance alone isn't a manifest-validation failure"
assert_match "provenance: TAMPERED" "$out" "audit flags a hand-edited source= as TAMPERED"

rc=0; out="$(HOME="$homeK" ORCHID_REPO="$repoK" "$ORCHID_BIN" plugins update sigcheck 2>&1)" || rc=$?
assert_eq 13 "$rc" "update refuses to fetch from a tampered provenance, exit 13"
assert_match "tampered" "$out" "update's refusal names the provenance as tampered"

# -- audit of a built-in (no .provenance recorded) reports 'local' ---------
out="$(HOME="$homeI" ORCHID_REPO="$repoI" "$ORCHID_BIN" plugins audit orchid/claude)"; rc=$?
assert_eq 0 "$rc" "audit of a built-in plugin (matched by full id) succeeds"
assert_match "provenance: local" "$out" "a plugin with no .provenance on record reports provenance: local"

# -- audit reports lockfile references when run inside a locked repo ------
homeL="$WORK/homeL"; mkdir -p "$homeL/.orchid"
repoL="$WORK/repoL"; mkdir -p "$repoL"
(cd "$repoL" && git init -q . && git commit -q --allow-empty -m root)
HOME="$homeL" ORCHID_REPO="$repoL" "$ORCHID_BIN" plugins lock >/dev/null

out="$(HOME="$homeL" ORCHID_REPO="$repoL" "$ORCHID_BIN" plugins audit orchid/claude)"; rc=$?
assert_eq 0 "$rc" "audit inside a locked repo succeeds"
assert_match "lockfile: referenced in $repoL/.orchid/plugins.lock" "$out" \
  "audit reports a lockfile reference when the current repo's plugins.lock names this plugin"

# -- audit --all: a genuinely INVALID manifest flips the exit code nonzero -
badhome="$WORK/badhome"; mkdir -p "$badhome/.orchid/plugins/engines/badaudit"
printf 'manifest_version=1\nid=acme/badaudit\nversion=0.1.0\nkind=engine\napi_version=1\n' \
  > "$badhome/.orchid/plugins/engines/badaudit/plugin.conf"   # missing entrypoint -> INVALID
badrepo="$WORK/badrepoaudit"; mkdir -p "$badrepo"

rc=0; out="$(HOME="$badhome" ORCHID_REPO="$badrepo" "$ORCHID_BIN" plugins audit --all 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "audit must exit nonzero when any audited plugin fails manifest validation"
assert_match "acme/badaudit" "$out" "audit --all's report includes the invalid plugin"
assert_match "validate: INVALID" "$out" "audit names the invalid plugin's validate status"

# -- audit refuses an unknown name ------------------------------------------
rc=0; HOME="$homeI" ORCHID_REPO="$repoI" "$ORCHID_BIN" plugins audit nosuchplugin >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "audit must refuse an unknown plugin name"

# -- install from a git URL: a file:// LOCAL bare repo fixture (no real
# network anywhere in this test) -- the ONE sanctioned network use of this
# verb, exercised here against a purely local transport. -------------------
homeGit="$WORK/homeGit"; mkdir -p "$homeGit/.orchid"
repoGit="$WORK/repoGit"; mkdir -p "$repoGit"
srcGit="$WORK/srcGit"; mk_engine "$srcGit" acme/gitinstalled 0.1.0
(cd "$srcGit" && git init -q . && git add -A && git commit -q -m init)
expect_ref="$(cd "$srcGit" && git rev-parse HEAD)"
baregit="$WORK/bare.git"
git clone -q --bare "$srcGit" "$baregit" >/dev/null 2>&1

out="$(HOME="$homeGit" ORCHID_REPO="$repoGit" "$ORCHID_BIN" plugins install "file://$baregit")"; rc=$?
assert_eq 0 "$rc" "install from a file:// git URL succeeds"
destGit="$homeGit/.orchid/plugins/engines/gitinstalled"
[ -d "$destGit" ] || fail "git-url install lands at $destGit"
[ -f "$destGit/plugin.conf" ] || fail "git-url install carries the cloned manifest"
[ ! -d "$destGit/.git" ] || fail "git-url install must not ship .git metadata into the installed plugin dir"

prov="$(cat "$destGit/.provenance")"
assert_match "^source=file://$baregit$" "$prov" "provenance records the git URL verbatim as source"
assert_match "^ref=$expect_ref$" "$prov" "provenance ref records the cloned commit's sha"

# duplicate git-url install is refused the same as a local-dir one
rc=0; out="$(HOME="$homeGit" ORCHID_REPO="$repoGit" "$ORCHID_BIN" plugins install "file://$baregit" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "duplicate git-url install must be refused"
assert_match "update" "$out" "duplicate git-url install refusal points at 'update'"

# and update works against the git-installed plugin too (re-clones from
# the SAME provenance source, refuses only if the source itself vanished)
out="$(HOME="$homeGit" ORCHID_REPO="$repoGit" "$ORCHID_BIN" plugins update gitinstalled)"; rc=$?
assert_eq 0 "$rc" "update succeeds against a git-installed plugin (re-clones its recorded source)"
