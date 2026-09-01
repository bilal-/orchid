#!/usr/bin/env bash
# INV-09: repo-local plugins never execute without an out-of-repo trust
# record (docs/specs/kernel.md's Conformance invariants).
#
# RED: a repo-local engine is resolved below with no trust record at all,
#      with a record for a DIFFERENT directory, after its bytes changed
#      (digest mismatch), after a symlink inside it was repointed, and after
#      revocation. Every one must refuse AND print no path -- a resolver that
#      refuses while still emitting the path has handed the caller the
#      executable anyway.
# GREEN: the same engine, genuinely trusted and digest-matching, must resolve
#      to its own run script; and a ~/.orchid user plugin and a built-in must
#      resolve with no record at all, so the refusals above are the trust
#      boundary and not a resolver that refuses everything.
source "$(dirname "$0")/../helpers.sh"

mk_engine() {  # dir id version -- a minimal valid engine plugin
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=%s\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
    "$2" "$3" > "$1/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

resolve() {  # home repo name -> resolved path on stdout, rc = resolve_engine_exe's rc
  ( export HOME="$1" ORCHID_REPO="$2" ORCHID_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/resolver.sh"
    resolve_engine_exe "$3" )
}

repo="$WORK/repo"; home="$WORK/home"; mkdir -p "$home/.orchid"
plugin_dir="$repo/.orchid/plugins/engines/inveng"
mk_engine "$plugin_dir" acme/inveng 0.1.0

# 1) Fresh sandbox HOME, no trust record anywhere -> refused.
rc=0; exe="$(resolve "$home" "$repo" inveng)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-09: repo-local engine executed with NO trust record at all"
[ -z "$exe" ] || fail "INV-09: resolve_engine_exe must not print a path when refusing"

# 2) Trust records are exact-path-scoped: trusting a DIFFERENT directory
# (even one that also contains a same-named engine) must not enable this one.
other_repo="$WORK/other-repo"
other_dir="$other_repo/.orchid/plugins/engines/inveng"
mk_engine "$other_dir" acme/inveng 0.1.0
HOME="$home" "$ORCHID_BIN" plugins trust "$other_dir" >/dev/null || fail "setup: trusting the decoy dir failed"
rc=0; exe="$(resolve "$home" "$repo" inveng)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-09: trusting an unrelated directory must not enable this repo's engine"
HOME="$home" "$ORCHID_BIN" plugins untrust "$other_dir" >/dev/null

# 3) Trust records live OUTSIDE the repo, never inside it.
[ ! -e "$repo/.orchid/trust" ] || fail "INV-09: a trust record must never live under the repo"

# 4) Trusting the actual dir (out-of-repo record, sandbox HOME) enables it.
HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins trust "$plugin_dir" >/dev/null \
  || fail "setup: trust of the real plugin dir failed"
[ -f "$home/.orchid/trust" ] || fail "INV-09: trust record must be written to \$HOME/.orchid/trust"
[ ! -e "$repo/.orchid/trust" ] || fail "INV-09: trust record must never appear under the repo, even after trusting"
exe="$(resolve "$home" "$repo" inveng)"; rc=$?
[ "$rc" -eq 0 ] || fail "INV-09: a genuinely trusted, digest-matching repo-local engine must resolve"
# Herestrings here and at the user-plugin check below, never `echo "$exe" |
# grep -q` (T016/INV-15 section 5): `grep -q` exits at its first match and
# SIGPIPEs `echo`, and helpers.sh's `set -o pipefail` makes that kill the
# pipeline's status -- so the correct path can be read as the wrong one.
grep -q "inveng/run$" <<<"$exe" || fail "INV-09: resolved path must point at the trusted repo-local run script"

# 5) A digest mismatch (e.g. a repo pull mutating a tracked file) instantly
# de-trusts it -- it must go back to never executing, with no operator
# action required to re-disable it.
printf '# tampered\n' >> "$plugin_dir/run"
rc=0; exe="$(resolve "$home" "$repo" inveng)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-09: a digest-mismatched repo-local engine executed"
[ -z "$exe" ] || fail "INV-09: resolve_engine_exe must not print a path on digest mismatch"

# 6) Untrusting removes the record; still refused (no residual trust).
HOME="$home" "$ORCHID_BIN" plugins trust --update "$plugin_dir" >/dev/null 2>&1  # re-pin, then explicitly revoke
HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins untrust "$plugin_dir" >/dev/null
rc=0; exe="$(resolve "$home" "$repo" inveng)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-09: an untrusted (revoked) repo-local engine executed"

# 7) INV-09 is scoped to repo-local: built-in and user (~/.orchid) plugins
# need no trust record at all and must keep resolving throughout.
userhome="$WORK/userhome"; mkdir -p "$userhome/.orchid/plugins/engines/usereng"
mk_engine "$userhome/.orchid/plugins/engines/usereng" acme/usereng 0.1.0
exe="$(resolve "$userhome" "$repo" usereng)"; rc=$?
[ "$rc" -eq 0 ] || fail "INV-09 must not spill over: a ~/.orchid user plugin needs no trust record"
grep -q "usereng/run$" <<<"$exe" || fail "user-plugin resolution returned the wrong path"
exe="$(resolve "$userhome" "$repo" claude)"; rc=$?
[ "$rc" -eq 0 ] || fail "INV-09 must not spill over: a built-in engine needs no trust record"

# 8) Repointing a symlink inside an already-trusted repo-local plugin must
# also de-trust it (digest mismatch), exactly like mutating a regular file
# does -- plugin_digest must hash symlink targets, not just regular files,
# or a trusted plugin's executed code could be swapped by retargeting a
# symlink without the digest ever changing.
symrepo="$WORK/sym-repo"
symplugin="$symrepo/.orchid/plugins/engines/symeng"
mk_engine "$symplugin" acme/symeng 0.1.0
mkdir -p "$symplugin/targets/a" "$symplugin/targets/b"
ln -s targets/a "$symplugin/link"
HOME="$home" ORCHID_REPO="$symrepo" "$ORCHID_BIN" plugins trust "$symplugin" >/dev/null \
  || fail "setup: trust of the symlink-bearing plugin dir failed"
exe="$(resolve "$home" "$symrepo" symeng)"; rc=$?
[ "$rc" -eq 0 ] || fail "INV-09: freshly trusted symlink-bearing engine must resolve"
green_case "a genuinely trusted, digest-matching repo-local engine RESOLVED, so the refusals around it are trust decisions rather than a resolver that refuses every repo-local plugin"
rm "$symplugin/link"; ln -s targets/b "$symplugin/link"
rc=0; exe="$(resolve "$home" "$symrepo" symeng)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-09: repointing a symlink inside a trusted repo-local plugin must de-trust it (digest must cover symlinks)"
[ -z "$exe" ] || fail "INV-09: resolve_engine_exe must not print a path after a symlink repoint de-trusts the plugin"
red_case "an untrusted, wrongly-trusted, digest-mismatched, symlink-repointed and revoked repo-local engine each refused to resolve, while a genuinely trusted one resolved"
