#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"

# RED: a symlinked parent cannot redirect kernel refresh into another directory.
# GREEN: the same committed changes refresh ordinary integration-checkout paths.
for refresh_action in restore delete; do
  refresh_root="$WORK/root-$refresh_action"
  refresh_foreign="$WORK/foreign-$refresh_action"
  mkdir -p "$refresh_root/lib/nested" "$refresh_foreign"
  git init -q "$refresh_root"
  git -C "$refresh_root" symbolic-ref HEAD refs/heads/orchid/integration
  printf 'old kernel\n' > "$refresh_root/lib/nested/module.sh"
  git -C "$refresh_root" add lib/nested/module.sh
  git -C "$refresh_root" commit -q -m original
  refresh_base="$(git -C "$refresh_root" rev-parse HEAD)"
  if [ "$refresh_action" = restore ]; then
    printf 'new kernel\n' > "$refresh_root/lib/nested/module.sh"
  else
    rm "$refresh_root/lib/nested/module.sh"
  fi
  git -C "$refresh_root" add -A
  git -C "$refresh_root" commit -q -m "$refresh_action kernel"
  refresh_new="$(git -C "$refresh_root" rev-parse HEAD)"
  git -C "$refresh_root" reset -q --hard "$refresh_base"
  # Construct the real stale integration-checkout condition: its branch moves,
  # while its index and files still describe the previous integration commit.
  git -C "$refresh_root" update-ref refs/heads/orchid/integration "$refresh_new" "$refresh_base"
  cp "$refresh_root/lib/nested/module.sh" "$refresh_foreign/module.sh"
  rm -rf "$refresh_root/lib/nested"
  ln -s "$refresh_foreign" "$refresh_root/lib/nested"
  refresh_rc=0
  refresh_error="$(orchid_refresh_kernel "$refresh_root" "$refresh_base" 2>&1)" || refresh_rc=$?
  [ "$refresh_rc" -ne 0 ] || fail 'kernel refresh must refuse a redirected parent'
  assert_eq 'old kernel' "$(cat "$refresh_foreign/module.sh" 2>/dev/null)" "$refresh_action refusal preserves foreign file"
  assert_match 'redirected kernel parent' "$refresh_error" "$refresh_action refusal names the redirected parent"
  red_case "$refresh_action cannot replace or delete a foreign file through an integration-checkout parent symlink"

  rm "$refresh_root/lib/nested"
  git -C "$refresh_root" checkout "$refresh_base" -- lib/nested/module.sh
  orchid_refresh_kernel "$refresh_root" "$refresh_base" || fail 'normal integration-checkout refresh succeeds'
  if [ "$refresh_action" = restore ]; then
    assert_eq 'new kernel' "$(cat "$refresh_root/lib/nested/module.sh")" 'ordinary refresh restores committed bytes'
  else
    [ ! -e "$refresh_root/lib/nested/module.sh" ] || fail 'ordinary refresh removes deleted kernel file'
  fi
  assert_eq 'old kernel' "$(cat "$refresh_foreign/module.sh")" 'accepting refresh still preserves foreign directory'
  git -C "$refresh_root" diff --quiet HEAD -- lib || fail 'accepting refresh matches integration HEAD'
  green_case "$refresh_action accepts the same integration change when its parent belongs to the checkout"
done
