#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# row_re <id> <kind> <version> <origin> <trust> -- same shape as
# tests/test_plugins_list.sh's helper (built independently here since each
# test file owns its fixtures).
row_re() { printf '^%s\t%s\t%s\t%s\t%s$' "$1" "$2" "$3" "$4" "$5"; }

# path_count <trust-file> <path> -- number of records naming exactly <path>.
# Records are `<digest> <path>` (digest is the first whitespace-delimited
# field; the path is everything after the first space, so paths containing
# spaces are still matched whole rather than truncated at their first space).
path_count() {
  [ -f "$1" ] || { echo 0; return; }
  awk -v d="$2" '{p=$0; sub(/^[^ ]+ /, "", p); if (p==d) c++} END{print c+0}' "$1"
}

mk_engine() {  # dir id version -- a minimal valid engine plugin
  mkdir -p "$1"
  printf 'manifest_version=1\nid=%s\nversion=%s\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
    "$2" "$3" > "$1/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/run"; chmod +x "$1/run"
}

# resolve <home> <repo> <name> -- runs resolve_engine_exe in a fresh
# subshell (so it never carries state between calls), stdout is the
# resolved path (or empty), rc is resolve_engine_exe's own rc.
resolve() {
  ( HOME="$1" ORCHID_REPO="$2" ORCHID_ROOT="$REPO_ROOT"
    export HOME ORCHID_REPO ORCHID_ROOT
    source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/resolver.sh"
    resolve_engine_exe "$3" )
}

repo="$WORK/repo"; home="$WORK/home"
mkdir -p "$home/.orchid"
plugin_dir="$repo/.orchid/plugins/engines/repoeng"
mk_engine "$plugin_dir" acme/repoeng 0.1.0
# The trust store records the CANONICAL path (symlinks resolved, e.g. macOS's
# /var -> /private/var for $TMPDIR); assertions against the stored record
# must compare against that same canonical form, not the raw $plugin_dir
# string a caller happened to type.
canon_dir="$(cd "$plugin_dir" && pwd -P)"

# -- untrusted by default: DISABLED (untrusted), never resolves ------------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 with an untrusted repo-local plugin"
assert_match "$(row_re acme/repoeng engine 0.1.0 repo 'DISABLED \(untrusted\)')" "$out" \
  "repo-local plugin starts DISABLED (untrusted)"

rc=0; exe="$(resolve "$home" "$repo" repoeng)" || rc=$?
[ "$rc" -ne 0 ] || fail "resolve_engine_exe must refuse an untrusted repo-local engine"
[ -z "$exe" ] || fail "resolve_engine_exe must print nothing on refusal (got '$exe')"

err="$(HOME="$home" ORCHID_REPO="$repo" ORCHID_ROOT="$REPO_ROOT" bash -c \
  'source "$ORCHID_ROOT/lib/common.sh"; source "$ORCHID_ROOT/lib/resolver.sh"; resolve_engine_exe repoeng' 2>&1 1>/dev/null)"
assert_match "untrusted" "$err" "warns 'untrusted' to stderr when skipping"
assert_match "INV-09" "$err" "warning names INV-09"

# trust file must never land in the repo
[ ! -e "$repo/.orchid/trust" ] || fail "trust record must never be written under the repo"

# -- orchid plugins trust <dir> pins the digest into the SANDBOX HOME -------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins trust "$plugin_dir")"; rc=$?
assert_eq 0 "$rc" "plugins trust succeeds on a valid dir"
assert_match "^trusted: " "$out" "trust prints a confirmation line"
digest1="$(echo "$out" | awk '{print $NF}')"
[ -f "$home/.orchid/trust" ] || fail "trust record must be written to \$HOME/.orchid/trust"
assert_eq "$digest1 $canon_dir" "$(cat "$home/.orchid/trust")" \
  "trust record is '<digest> <path>' (digest first field, so a path with spaces still parses)"
[ ! -e "$repo/.orchid/trust" ] || fail "trust record must never be written under the repo (post-trust)"

out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 once trusted"
assert_match "$(row_re acme/repoeng engine 0.1.0 repo trusted)" "$out" "repo-local plugin now shows trusted"

exe="$(resolve "$home" "$repo" repoeng)"; rc=$?
assert_eq 0 "$rc" "resolve_engine_exe resolves a trusted repo-local engine"
assert_match "repoeng/run$" "$exe" "resolved path points at the repo-local run script"

# re-trusting at the SAME digest is idempotent (no duplicate record, no error)
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins trust "$plugin_dir")"; rc=$?
assert_eq 0 "$rc" "re-trusting at an unchanged digest is idempotent"
trust_record_count="$(path_count "$home/.orchid/trust" "$canon_dir")"
assert_eq 1 "$trust_record_count" "no duplicate record after re-trusting at the same digest"

# -- mutating a file in the dir changes the digest -> de-trusted ------------
printf '# mutated\n' >> "$plugin_dir/run"
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_eq 0 "$rc" "plugins list exits 0 after a mutation (still just a DISABLED entry, not a crash)"
assert_match "$(row_re acme/repoeng engine 0.1.0 repo 'DISABLED \(digest mismatch\)')" "$out" \
  "mutated repo-local plugin shows DISABLED (digest mismatch)"

rc=0; exe="$(resolve "$home" "$repo" repoeng)" || rc=$?
[ "$rc" -ne 0 ] || fail "resolve_engine_exe must refuse a digest-mismatched repo-local engine"
[ -z "$exe" ] || fail "resolve_engine_exe must print nothing on a digest mismatch (got '$exe')"

err="$(HOME="$home" ORCHID_REPO="$repo" ORCHID_ROOT="$REPO_ROOT" bash -c \
  'source "$ORCHID_ROOT/lib/common.sh"; source "$ORCHID_ROOT/lib/resolver.sh"; resolve_engine_exe repoeng' 2>&1 1>/dev/null)"
assert_match "mismatch" "$err" "warns 'mismatch' to stderr after a mutation"
assert_match "trust --update" "$err" "warning suggests 'trust --update'"

# plain `trust` (no --update) on a now-different digest is refused
rc=0; out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins trust "$plugin_dir" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plain 'trust' on a changed digest must be refused"
assert_match "trust --update" "$out" "refusal message points at 'trust --update'"

# -- trust --update re-pins ---------------------------------------------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins trust --update "$plugin_dir")"; rc=$?
assert_eq 0 "$rc" "trust --update re-pins the new digest"
trust_record_count="$(path_count "$home/.orchid/trust" "$canon_dir")"
assert_eq 1 "$trust_record_count" "trust --update rewrites the record in place (no duplicate)"

out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_match "$(row_re acme/repoeng engine 0.1.0 repo trusted)" "$out" "re-pinned repo-local plugin shows trusted again"
exe="$(resolve "$home" "$repo" repoeng)"; rc=$?
assert_eq 0 "$rc" "resolve_engine_exe resolves again after trust --update"
assert_match "repoeng/run$" "$exe" "resolved path after re-pin"

# -- untrust removes the record -------------------------------------------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins untrust "$plugin_dir")"; rc=$?
assert_eq 0 "$rc" "plugins untrust succeeds"
[ "$(path_count "$home/.orchid/trust" "$canon_dir")" -eq 0 ] || fail "untrust must remove the record"

out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_match "$(row_re acme/repoeng engine 0.1.0 repo 'DISABLED \(untrusted\)')" "$out" \
  "untrusted repo-local plugin is DISABLED (untrusted) again after untrust"
rc=0; exe="$(resolve "$home" "$repo" repoeng)" || rc=$?
[ "$rc" -ne 0 ] || fail "resolve_engine_exe must refuse again after untrust"

# untrust is idempotent when there is no record to remove
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins untrust "$plugin_dir")"; rc=$?
assert_eq 0 "$rc" "untrust on an already-untrusted dir is a harmless no-op"

# -- trust refuses a non-existent directory --------------------------------
rc=0; HOME="$home" "$ORCHID_BIN" plugins trust "$WORK/no-such-dir" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "trust must refuse a non-existent directory"

# -- trust refuses a plugin whose entrypoint is a symlink (Fix 1b) ----------
# A digest that hashes symlink targets (Fix 1a) still can't help if the
# plugin was pinned while `run` was already a symlink: the pinned digest
# would cover whatever it pointed at, so trust must never accept a
# symlinked entrypoint in the first place.
symdir="$WORK/symeng"; mkdir -p "$symdir"
printf 'manifest_version=1\nid=acme/symeng\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$symdir/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$symdir/real-run"; chmod +x "$symdir/real-run"
ln -s real-run "$symdir/run"
rc=0; out="$(HOME="$home" "$ORCHID_BIN" plugins trust "$symdir" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "trust must refuse a plugin whose entrypoint is a symlink"
assert_match "entrypoint.*symlink" "$out" "refusal message names the entrypoint as a symlink"
[ "$(path_count "$home/.orchid/trust" "$(cd "$symdir" && pwd -P)")" -eq 0 ] \
  || fail "a refused symlink-entrypoint plugin must not end up recorded as trusted"

# -- trust refuses a manifest that fails validation (Must-fix 1) ------------
# A kernel-declared-incompatible plugin (unknown api_version, fail-closed
# rejected by manifest_validate) must never be pinned into the trust store --
# trusting it would let it later resolve and run despite the incompatibility.
badrepo="$WORK/badrepo"
baddir="$badrepo/.orchid/plugins/engines/badeng"
mkdir -p "$baddir"
printf 'manifest_version=1\nid=acme/badeng\nversion=0.1.0\nkind=engine\napi_version=2\nrequires_orchid=>=1.0\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$baddir/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$baddir/run"; chmod +x "$baddir/run"
rc=0; out="$(HOME="$home" ORCHID_REPO="$badrepo" "$ORCHID_BIN" plugins trust "$baddir" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "trust must refuse a plugin whose manifest fails validation (api_version=2)"
assert_match "refusing to trust: manifest invalid" "$out" "refusal message names the manifest as invalid"
assert_match "orchid plugins validate" "$out" "refusal message points at 'orchid plugins validate <id>'"
assert_match "unknown api_version" "$out" "refusal message surfaces manifest_validate's own FAIL output"
[ "$(path_count "$home/.orchid/trust" "$(cd "$baddir" && pwd -P)")" -eq 0 ] \
  || fail "a refused invalid-manifest plugin must not end up recorded as trusted"

# -- a validly-manifested plugin still trusts normally ----------------------
goodrepo="$WORK/goodrepo"
gooddir="$goodrepo/.orchid/plugins/engines/goodeng"
mk_engine "$gooddir" acme/goodeng 0.1.0
out="$(HOME="$home" ORCHID_REPO="$goodrepo" "$ORCHID_BIN" plugins trust "$gooddir")"; rc=$?
assert_eq 0 "$rc" "trust still succeeds for a plugin whose manifest validates"
assert_match "^trusted: " "$out" "trust of a valid manifest still prints a confirmation line"
