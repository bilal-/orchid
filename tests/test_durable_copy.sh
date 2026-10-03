#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"

# RED: copy and publication failures cannot discard the previous directory.
# GREEN: a complete directory replaces durable files and preserves live runtime.
copy_src="$WORK/source"; mkdir -p "$copy_src/runtime"
printf 'new first\n' > "$copy_src/a"
printf 'new last\n' > "$copy_src/b"
printf 'source runtime\n' > "$copy_src/runtime/epoch"

copy_rc=0
copy_error="$(
  (
    cp() {
      if [ "${2##*/}" = a ]; then printf 'simulated copy failure\n' >&2; return 7; fi
      command cp "$@"
    }
    _ocd_copy_path "$copy_src" "$WORK/stage"
  ) 2>&1
)" || copy_rc=$?
[ "$copy_rc" -ne 0 ] || fail 'durable staging must reject an early copy failure'
assert_match 'simulated copy failure' "$copy_error" 'staging preserves copy stderr'
red_case 'durable staging rejects failed first copy even when later files are readable'

_ocd_copy_path "$copy_src" "$WORK/stage" || fail 'complete durable staging succeeds'
assert_eq 'new first' "$(cat "$WORK/stage/a")" 'staging carries first file'
assert_eq 'new last' "$(cat "$WORK/stage/b")" 'staging carries last file'
[ ! -e "$WORK/stage/runtime" ] || fail 'staging must exclude volatile runtime'
green_case 'complete staging copies durable files while excluding runtime'

for copy_failure in copy copy_runtime rename_old rename_new; do
  copy_dst="$WORK/destination-$copy_failure"
  mkdir -p "$copy_dst/runtime"
  printf 'old first\n' > "$copy_dst/a"
  printf 'live runtime\n' > "$copy_dst/runtime/epoch"
  copy_rc=0
  copy_error="$(
    (
      cp() {
        if [ "$copy_failure" = copy ] && [ "${2##*/}" = a ]; then
          printf 'simulated sync copy failure\n' >&2; return 7
        fi
        if [ "$copy_failure" = copy_runtime ] && [ "${2##*/}" = runtime ]; then
          printf 'simulated runtime copy failure\n' >&2; return 7
        fi
        command cp "$@"
      }
      mv() {
        if [ "$copy_failure" = rename_old ] && [ "$1" = "$copy_dst" ]; then
          printf 'simulated old rename failure\n' >&2; return 7
        fi
        if [ "$copy_failure" = rename_new ] && [ "$2" = "$copy_dst" ] && [ "$1" = "$copy_dst.new.$$" ]; then
          printf 'simulated new rename failure\n' >&2; return 7
        fi
        command mv "$@"
      }
      _ocd_sync_dir_atomic "$copy_dst" "$copy_src"
    ) 2>&1
  )" || copy_rc=$?
  [ "$copy_rc" -ne 0 ] || fail "directory sync must reject $copy_failure failure"
  assert_match 'simulated' "$copy_error" "directory sync retains $copy_failure error"
  assert_eq 'old first' "$(cat "$copy_dst/a" 2>/dev/null)" "directory sync preserves old files after $copy_failure failure"
  assert_eq 'live runtime' "$(cat "$copy_dst/runtime/epoch" 2>/dev/null)" "directory sync preserves runtime after $copy_failure failure"
  [ ! -e "$copy_dst/b" ] || fail "directory sync must not publish a partial copy after $copy_failure failure"
  red_case "directory sync refuses $copy_failure failure and retains its previous directory"

  _ocd_sync_dir_atomic "$copy_dst" "$copy_src" || fail "directory sync succeeds after $copy_failure refusal"
  assert_eq 'new first' "$(cat "$copy_dst/a")" 'successful sync replaces old durable file'
  assert_eq 'new last' "$(cat "$copy_dst/b")" 'successful sync carries all durable files'
  assert_eq 'live runtime' "$(cat "$copy_dst/runtime/epoch")" 'successful sync retains destination runtime'
  [ ! -e "$copy_dst.old.$$" ] && [ ! -e "$copy_dst.new.$$" ] || fail 'successful sync removes staging directories'
  green_case "directory sync accepts a complete retry after $copy_failure refusal"
done

copy_dst="$WORK/double-failure"
mkdir -p "$copy_dst/runtime"
printf 'recoverable first\n' > "$copy_dst/a"
printf 'recoverable runtime\n' > "$copy_dst/runtime/epoch"
copy_rc=0
copy_error="$(
  (
    mv() {
      if [ "$2" = "$copy_dst" ]; then printf 'simulated publication and rollback failure\n' >&2; return 7; fi
      command mv "$@"
    }
    _ocd_sync_dir_atomic "$copy_dst" "$copy_src"
  ) 2>&1
)" || copy_rc=$?
[ "$copy_rc" -ne 0 ] || fail 'failed publication and rollback must remain a failure'
assert_eq 'recoverable first' "$(cat "$copy_dst.old.$$/a" 2>/dev/null)" 'failed rollback preserves durable backup'
assert_eq 'recoverable runtime' "$(cat "$copy_dst.old.$$/runtime/epoch" 2>/dev/null)" 'failed rollback preserves runtime backup'
assert_match 'rollback failed' "$copy_error" 'failed rollback identifies recovery requirement'
red_case 'failed publication and rollback retain the previous directory rather than deleting its backup'
mv "$copy_dst.old.$$" "$copy_dst" || fail 'fixture recovers its retained backup'
_ocd_sync_dir_atomic "$copy_dst" "$copy_src" || fail 'sync accepts a recovered directory'
assert_eq 'new first' "$(cat "$copy_dst/a")" 'recovered sync publishes the complete new state'
green_case 'successful publication after backup recovery replaces the recovered directory'
