#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# row_re <id> <kind> <version> <origin> <trust> -- same shape as
# tests/test_plugins_list.sh's helper (built independently here since each
# test file owns its fixtures).
row_re() { printf '^%s\t%s\t%s\t%s\t%s$' "$1" "$2" "$3" "$4" "$5"; }

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
[ -f "$home/.orchid/trust" ] || fail "trust record must be written to \$HOME/.orchid/trust"
grep -q "^$canon_dir " "$home/.orchid/trust" || fail "trust record names the plugin's absolute path"
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
lines="$(grep -c "^$canon_dir " "$home/.orchid/trust")"
assert_eq 1 "$lines" "no duplicate record after re-trusting at the same digest"

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
lines="$(grep -c "^$canon_dir " "$home/.orchid/trust")"
assert_eq 1 "$lines" "trust --update rewrites the record in place (no duplicate)"

out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins list)"; rc=$?
assert_match "$(row_re acme/repoeng engine 0.1.0 repo trusted)" "$out" "re-pinned repo-local plugin shows trusted again"
exe="$(resolve "$home" "$repo" repoeng)"; rc=$?
assert_eq 0 "$rc" "resolve_engine_exe resolves again after trust --update"
assert_match "repoeng/run$" "$exe" "resolved path after re-pin"

# -- untrust removes the record -------------------------------------------
out="$(HOME="$home" ORCHID_REPO="$repo" "$ORCHID_BIN" plugins untrust "$plugin_dir")"; rc=$?
assert_eq 0 "$rc" "plugins untrust succeeds"
grep -q "^$canon_dir " "$home/.orchid/trust" && fail "untrust must remove the record"

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
