#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"

# RED: failed hash backends and escaped path operands must not become approvals.
# GREEN: real hash backends bind contents, and literal trust paths round-trip.
# Exercise the shipped hash implementation through a failure-injecting wrapper;
# successful files still use the real backend and the real filename binding.
digest_dir="$WORK/digest"; mkdir -p "$digest_dir"
printf 'first\n' > "$digest_dir/a"
printf 'last\n' > "$digest_dir/b"
digest_real_hash="$(declare -f _orchid_file_sha256)"
eval "${digest_real_hash/_orchid_file_sha256/_digest_test_real_file_sha256}"

for digest_function in plugin_digest plugin_digest_content; do
  digest_rc=0
  digest_error="$(
    (
      set +o pipefail
      _orchid_file_sha256() {
        if [ "${1##*/}" = a ]; then
          printf 'simulated first-file hash failure\n' >&2
          return 7
        fi
        _digest_test_real_file_sha256 "$1"
      }
      "$digest_function" "$digest_dir"
    ) 2>&1
  )" || digest_rc=$?
  [ "$digest_rc" -ne 0 ] || fail "$digest_function must reject an early file-hash failure"
  assert_match 'simulated first-file hash failure' "$digest_error" "$digest_function retains the hash error"
  red_case "$digest_function rejects a failed first file even when a later file hashes successfully"

  digest_before="$("$digest_function" "$digest_dir")" || fail "$digest_function accepts complete hashing"
  assert_match '^[0-9a-f]{64}$' "$digest_before" "$digest_function emits a full digest"
  printf 'changed first\n' > "$digest_dir/a"
  digest_after="$("$digest_function" "$digest_dir")" || fail "$digest_function accepts a changed first file"
  [ "$digest_before" != "$digest_after" ] || fail "$digest_function must bind the first file's contents"
  printf 'first\n' > "$digest_dir/a"
  green_case "$digest_function accepts successful hashing and detects a change to the first file"
done

# OpenSSL is the supported fallback when shasum is absent. A failed backend must
# not be converted into a successful line containing only the filename.
ln -s a "$digest_dir/link"
for digest_hash in _orchid_file_sha256 _orchid_symlink_sha256 _orchid_stream_sha256; do
  digest_rc=0
  digest_error="$(
    (
      set +o pipefail
      command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = shasum ]; then return 1; fi
        builtin command "$@"
      }
      openssl() { printf 'simulated OpenSSL hash failure\n' >&2; return 7; }
      if [ "$digest_hash" = _orchid_stream_sha256 ]; then
        "$digest_hash" <<< 'payload'
      elif [ "$digest_hash" = _orchid_symlink_sha256 ]; then
        "$digest_hash" "$digest_dir/link"
      else
        "$digest_hash" "$digest_dir/a"
      fi
    ) 2>&1
  )" || digest_rc=$?
  [ "$digest_rc" -ne 0 ] || fail "$digest_hash must preserve an OpenSSL backend failure"
  assert_match 'simulated OpenSSL hash failure' "$digest_error" "$digest_hash retains backend stderr"
  red_case "$digest_hash refuses a failed OpenSSL backend instead of publishing a usable hash record"
  digest_fallback="$(
    (
      command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = shasum ]; then return 1; fi
        builtin command "$@"
      }
      if [ "$digest_hash" = _orchid_stream_sha256 ]; then
        "$digest_hash" <<< 'payload'
      elif [ "$digest_hash" = _orchid_symlink_sha256 ]; then
        "$digest_hash" "$digest_dir/link"
      else
        "$digest_hash" "$digest_dir/a"
      fi
    )
  )" || fail "$digest_hash accepts a successful OpenSSL backend"
  assert_match '^[0-9a-f]{64}($| )' "$digest_fallback" "$digest_hash emits an OpenSSL digest"
  green_case "$digest_hash accepts successful OpenSSL hashing"
done

digest_rc=0
digest_error="$(
  (
    readlink() { printf 'simulated symlink read failure\n' >&2; return 7; }
    _orchid_symlink_sha256 "$digest_dir/link"
  ) 2>&1
)" || digest_rc=$?
[ "$digest_rc" -ne 0 ] || fail "symlink hashing must reject a failed target read"
assert_match 'simulated symlink read failure' "$digest_error" "symlink hash retains read error"
red_case 'symlink digest refuses a failed target read rather than hashing an empty target'

digest_link_before="$(_orchid_symlink_sha256 "$digest_dir/link")" || fail "symlink hash accepts a readable target"
rm "$digest_dir/link"; ln -s b "$digest_dir/link"
digest_link_after="$(_orchid_symlink_sha256 "$digest_dir/link")" || fail "symlink hash accepts a changed target"
[ "$digest_link_before" != "$digest_link_after" ] || fail "symlink hash must bind its target"
green_case 'symlink hashing accepts readable targets and changes the digest when the target changes'

# Path operands are bytes, not awk escape sequences. Work in a separate fake
# HOME so the round-trip checks never inspect or modify the operator's store.
digest_literal_path="$WORK/literal\nname"
digest_literal_home="$WORK/literal-home"
mkdir -p "$digest_literal_path" "$digest_literal_home"
digest_trust_record="$(
  HOME="$digest_literal_home"; export HOME
  trust_store_set "$digest_literal_path" old-digest || exit 1
  trust_store_set "$digest_literal_path" new-digest || exit 1
  trust_lookup "$digest_literal_path"
)" || fail "literal-path trust round trip succeeds"
assert_eq new-digest "$digest_trust_record" "trust lookup reads the literal backslash path"
assert_eq "new-digest $digest_literal_path" "$(cat "$digest_literal_home/.orchid/trust")" "literal-path upsert keeps exactly one record"
red_case 'trust upsert and lookup preserve a literal backslash followed by n instead of interpreting it as a newline'
HOME="$digest_literal_home" trust_store_remove "$digest_literal_path" || fail "literal-path trust removal succeeds"
assert_eq '' "$(cat "$digest_literal_home/.orchid/trust")" "trust removal deletes exactly the literal path"
green_case 'trust removal accepts the same literal path and leaves no stale approval record'
