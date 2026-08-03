#!/usr/bin/env bash
# Machine-local unattended trust: identity semantics, provenance, revocation,
# and the explicit exemption for manual/read-only operation.
source "$(dirname "$0")/helpers.sh"
export ORCHID_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/common.sh"

home="$WORK/home"
mkdir -p "$home"
home_physical="$(cd "$home" && pwd -P)"
export HOME="$home"
export GIT_AUTHOR_NAME="Orchid Test"
export GIT_AUTHOR_EMAIL="orchid-test@example.invalid"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

mk_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" commit -q --allow-empty -m root
}

trust_repo() {
  HOME="$home" "$ORCHID_BIN" trust unattended "$1" --reason "${2:-test fixture acknowledgement}" >/dev/null
}

# ---------------------------------------------------------------------------
# Default denial and provenance. Neither tracked content, an origin, Git
# config, nor orchid.config can opt a repository in.
# ---------------------------------------------------------------------------
repo="$WORK/repo"
mk_repo "$repo"
root="$(git -C "$repo" rev-list --max-parents=0 HEAD)"

printf 'unattended_trust=true\n' > "$repo/orchid.config"
git -C "$repo" config orchid.unattendedTrust true
git -C "$repo" remote add origin https://example.invalid/repo.git
mkdir -p "$repo/.orchid"
printf 'trusted=true\n' > "$repo/.orchid/unattended-trust"

out="$(HOME="$home" "$ORCHID_BIN" trust show "$repo")"; rc=$?
assert_eq 0 "$rc" "trust show is read-only and exits 0 for an untrusted repo"
assert_match '^unattended trust: untrusted$' "$out" "a fresh repo is untrusted"
assert_match '^gate: denied$' "$out" "show reports the unattended gate as denied"
assert_match "root_commit: $root" "$out" "show surfaces the current root commit"
assert_match '^policy_version: 1$' "$out" "show surfaces the current trust-policy version"

rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$repo" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement without --reason must be refused"
[ ! -d "$home/.orchid/unattended-trust" ] \
  || fail "a refused acknowledgement must not create the machine-local store"
rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$repo" --reason '   ' >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement with a whitespace-only reason must be refused"
[ ! -d "$home/.orchid/unattended-trust" ] \
  || fail "a whitespace-only reason must not create the machine-local store"

reason="reviewed target and accept prompt-injection risk"
out="$(HOME="$home" "$ORCHID_BIN" trust unattended "$repo" --reason "$reason")"; rc=$?
assert_eq 0 "$rc" "trust unattended succeeds with an operator reason"
assert_match '^unattended trust acknowledged:$' "$out" "acknowledgement prints confirmation"
assert_match "reason: $reason" "$out" "acknowledgement surfaces its operator-authored reason"

out="$(HOME="$home" "$ORCHID_BIN" trust show "$repo")"
assert_match '^unattended trust: trusted$' "$out" "acknowledged repo is trusted"
assert_match '^gate: allowed$' "$out" "show reports the gate as allowed"
assert_match '^git_common_device: [0-9]+$' "$out" "show surfaces Git common-directory device"
assert_match '^git_common_inode: [0-9]+$' "$out" "show surfaces Git common-directory inode"
assert_match '^acknowledged_at: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$out" "show surfaces acknowledgement time"
assert_match "acknowledged_repo: " "$out" "show surfaces the path used when acknowledged"
assert_match "recorded_root_commit: $root" "$out" "record binds the repository root commit"
assert_match '^recorded_schema: 2$' "$out" "record uses the incarnation-anchor schema"
assert_match '^recorded_identity_anchor_device: [0-9]+$' "$out" \
  "record binds the machine-local incarnation anchor device"
assert_match '^recorded_identity_anchor_inode: [0-9]+$' "$out" \
  "record binds the machine-local incarnation anchor inode"
record="$(printf '%s\n' "$out" | sed -n 's/^record: //p')"
anchor="$(printf '%s\n' "$out" | sed -n 's/^identity_anchor: //p')"
witness="$(printf '%s\n' "$out" | sed -n 's/^identity_witness: //p')"
case "$record" in
  "$home_physical"/.orchid/unattended-trust/*.json) ;;
  *) fail "record must live under the operator HOME, outside the repo (got '$record')" ;;
esac
[ -f "$record" ] || fail "show's machine-local record path must exist"
case "$anchor" in
  "$home_physical"/.orchid/unattended-trust/*.anchor) ;;
  *) fail "identity anchor must live under the operator HOME (got '$anchor')" ;;
esac
[ -f "$anchor" ] || fail "show's machine-local identity anchor must exist"
[ "$witness" = "$(cd "$repo/.git" && pwd -P)/description" ] \
  || fail "identity witness must be Git's stable common-directory description file"
if anchor_ident="$(stat -f '%d %i' "$anchor" 2>/dev/null)"; then
  witness_ident="$(stat -f '%d %i' "$witness")"
  anchor_links="$(stat -f '%l' "$anchor")"
else
  anchor_ident="$(stat -c '%d %i' "$anchor")"
  witness_ident="$(stat -c '%d %i' "$witness")"
  anchor_links="$(stat -c '%h' "$anchor")"
fi
assert_eq "$anchor_ident" "$witness_ident" \
  "outside anchor and common-directory witness are the same inode"
assert_eq 2 "$anchor_links" \
  "incarnation witness has exactly its Git and machine-local hard links"
[ ! -e "$repo/.orchid/unattended-trust.json" ] \
  || fail "unattended trust must never write a record inside the repo"

# A record path is itself part of the boundary. It must not be a symlink or
# hard-link alias of tracked content, and another local account must not be
# able to rewrite it through group/other permissions. Re-acknowledging a
# repairable regular-file record replaces it atomically; a symlink must be
# explicitly revoked first so a symlink-to-directory can never make `mv`
# place a temp record in the target or make `chmod` change that directory.
alias_repo="$WORK/record-alias-repo"
mk_repo "$alias_repo"
trust_repo "$alias_repo" "record alias fixture"
alias_out="$(HOME="$home" "$ORCHID_BIN" trust show "$alias_repo")"
alias_record="$(printf '%s\n' "$alias_out" | sed -n 's/^record: //p')"
tracked_record="$alias_repo/tracked-trust-record.json"
cp "$alias_record" "$tracked_record"
git -C "$alias_repo" add tracked-trust-record.json
git -C "$alias_repo" commit -q -m "tracked trust-shaped data"
tracked_before="$(cat "$tracked_record")"

rm -f "$alias_record"
ln -s "$tracked_record" "$alias_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$alias_repo")"
assert_match '^binding_state: invalid$' "$out" \
  "a symlinked record never derives trust from tracked content"
assert_match 'must not be a symbolic link' "$out" \
  "a symlinked record refusal names the non-canonical path"
rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$alias_repo" \
  --reason "must not follow a record symlink" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement must refuse an existing record symlink"
assert_eq "$tracked_before" "$(cat "$tracked_record")" \
  "refusing a record symlink leaves its tracked target byte-identical"
HOME="$home" "$ORCHID_BIN" trust revoke "$alias_repo" >/dev/null \
  || fail "revoke must remove a non-canonical record symlink without following it"
[ ! -L "$alias_record" ] || fail "revoke must remove the record symlink itself"

record_target_dir="$alias_repo/tracked-record-directory"
mkdir -p "$record_target_dir"
printf 'sentinel\n' > "$record_target_dir/sentinel"
if record_dir_mode="$(stat -f '%Lp' "$record_target_dir" 2>/dev/null)"; then
  :
else
  record_dir_mode="$(stat -c '%a' "$record_target_dir")"
fi
ln -s "$record_target_dir" "$alias_record"
rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$alias_repo" \
  --reason "must not follow a directory symlink" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement must refuse a record symlink to a directory"
assert_eq sentinel "$(cat "$record_target_dir/sentinel")" \
  "directory-symlink refusal preserves existing target content"
target_entries="$(find "$record_target_dir" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
assert_eq 1 "$target_entries" \
  "directory-symlink refusal must not move an atomic-write temp file into the target"
if record_dir_mode_after="$(stat -f '%Lp' "$record_target_dir" 2>/dev/null)"; then
  :
else
  record_dir_mode_after="$(stat -c '%a' "$record_target_dir")"
fi
assert_eq "$record_dir_mode" "$record_dir_mode_after" \
  "directory-symlink refusal must not chmod the symlink target"
HOME="$home" "$ORCHID_BIN" trust revoke "$alias_repo" >/dev/null \
  || fail "revoke must remove a directory-valued record symlink safely"

ln "$tracked_record" "$alias_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$alias_repo")"
assert_match '^binding_state: invalid$' "$out" \
  "a hard-linked record never derives trust from tracked content"
assert_match 'must not be hard-linked' "$out" \
  "a hard-linked record refusal names the alias"
trust_repo "$alias_repo" "replace hard-linked record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$alias_repo")"
assert_match '^unattended trust: trusted$' "$out" \
  "re-acknowledgement atomically replaces a hard-linked regular record"

chmod 666 "$alias_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$alias_repo")"
assert_match '^binding_state: invalid$' "$out" \
  "a group/other-writable record fails closed"
assert_match 'writable by group or other' "$out" \
  "unsafe record permissions are actionable"
trust_repo "$alias_repo" "replace writable record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$alias_repo")"
assert_match '^unattended trust: trusted$' "$out" \
  "re-acknowledgement restores a canonical private record"

# HOME (or a symlink beneath it) must not place the supposedly machine-local
# record inside the repository being authorized. When no outside store is
# available, acknowledgement fails closed without creating one in-tree.
inside_store_repo="$WORK/inside-store-repo"
mk_repo "$inside_store_repo"
inside_home="$inside_store_repo/operator-home"
mkdir -p "$inside_home"
rc=0
HOME="$inside_home" "$ORCHID_BIN" trust unattended "$inside_store_repo" \
  --reason "must not be tracked" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement must refuse a trust store inside the target repo"
[ ! -e "$inside_home/.orchid/unattended-trust" ] \
  || fail "refused in-repo trust must not create a record directory"

symlink_store_repo="$WORK/symlink-store-repo"
mk_repo "$symlink_store_repo"
mkdir -p "$symlink_store_repo/local-state" "$WORK/symlink-home"
ln -s "$symlink_store_repo/local-state" "$WORK/symlink-home/.orchid"
rc=0
HOME="$WORK/symlink-home" "$ORCHID_BIN" trust unattended "$symlink_store_repo" \
  --reason "symlink must not bypass placement" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement must resolve a symlinked trust-store parent"
[ ! -e "$symlink_store_repo/local-state/unattended-trust" ] \
  || fail "refused symlinked in-repo trust must not create a record directory"

# A caller may name a subdirectory, and repository-local core.worktree may
# change Git's reported top level. Placement checks must use the physical
# checkout marker so config cannot hide an in-repository HOME alongside that
# subdirectory.
configured_store_repo="$WORK/configured-store-repo"
mk_repo "$configured_store_repo"
mkdir -p "$configured_store_repo/subdir" "$configured_store_repo/operator-home"
git -C "$configured_store_repo" config core.worktree "$configured_store_repo/subdir"
assert_eq true \
  "$(git -C "$configured_store_repo/subdir" rev-parse --is-inside-work-tree)" \
  "core.worktree fixture must remain a Git worktree"
rc=0
HOME="$configured_store_repo/operator-home" "$ORCHID_BIN" trust unattended \
  "$configured_store_repo/subdir" --reason "config must not hide placement" \
  >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "repository config must not hide an in-checkout trust store"
[ ! -e "$configured_store_repo/operator-home/.orchid/unattended-trust" ] \
  || fail "config-hidden in-repo trust must not create a record directory"

# Descendant commits do not change the repository root identity.
git -C "$repo" commit -q --allow-empty -m descendant
out="$(HOME="$home" "$ORCHID_BIN" trust show "$repo")"
assert_match '^unattended trust: trusted$' "$out" "ordinary descendant commits preserve trust"

# Linked worktrees resolve to the same Git common directory and share trust.
linked="$WORK/linked"
git -C "$repo" worktree add -q --detach "$linked" HEAD
out="$(HOME="$home" "$ORCHID_BIN" trust show "$linked")"
assert_match '^unattended trust: trusted$' "$out" "linked worktree shares common-directory trust"
assert_match "record: $record" "$out" "linked worktree resolves the exact same record"

# Copying a linked checkout also copies its .git pointer, but the common
# directory still registers the ORIGINAL worktree path. The caller-selected
# path must be bound to that reciprocal registration before its Git identity
# can inherit the original's acknowledgement.
copied_linked="$WORK/copied-linked"
cp -R "$linked" "$copied_linked"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$copied_linked")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a copied linked worktree cannot inherit the registered original's trust"
assert_match '^binding_state: unavailable$' "$out" \
  "a copied linked worktree has no valid caller-path binding"
assert_match '^gate: denied$' "$out" \
  "a copied linked worktree defaults to a denied unattended gate"
assert_match 'caller-selected worktree path does not match the linked-worktree registration' "$out" \
  "copied linked-worktree refusal names the reciprocal path mismatch"
rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$copied_linked" \
  --reason "copy must get its own identity" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a copied linked worktree must not be acknowledgeable through the original registration"

# A trailing newline is a valid and distinct sibling name. Lossy `pwd`
# command substitution used to collapse this copied path onto the registered,
# trusted sibling before the reciprocal comparison even ran.
newline_copied_linked="${linked}"$'\n'
cp -R "$linked" "$newline_copied_linked"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$newline_copied_linked")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a newline-suffixed copied worktree cannot collapse onto its trusted sibling"
assert_match '^binding_state: unavailable$' "$out" \
  "the newline-suffixed copy fails the reciprocal caller-path binding"
assert_match 'caller-selected worktree path does not match the linked-worktree registration' "$out" \
  "newline-suffixed copied-worktree refusal names the exact path mismatch"

# Machine-local state outside the selected checkout can still be inside a
# sibling checkout sharing the same common directory. Such state is trackable
# by the repository and must be rejected before it can authorize any sibling.
sibling_main="$WORK/sibling-store-main"
sibling_target="$WORK/sibling-store-target"
sibling_host="$WORK/sibling-store-host"
mk_repo "$sibling_main"
git -C "$sibling_main" worktree add -q --detach "$sibling_target" HEAD
git -C "$sibling_main" worktree add -q --detach "$sibling_host" HEAD
sibling_home="$sibling_host/operator-home"
mkdir -p "$sibling_home/.orchid/unattended-trust"
trust_repo "$sibling_target" "external sibling fixture acknowledgement"
sibling_source_record="$(
  HOME="$home" "$ORCHID_BIN" trust show "$sibling_target" | sed -n 's/^record: //p'
)"
sibling_record="$sibling_home/.orchid/unattended-trust/$(basename "$sibling_source_record")"
cp "$sibling_source_record" "$sibling_record"
sibling_record_before="$(cat "$sibling_record")"
out="$(HOME="$sibling_home" "$ORCHID_BIN" trust show "$sibling_target")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a valid trust-shaped record inside a sibling linked worktree cannot grant trust"
assert_match '^binding_state: unavailable$' "$out" \
  "a sibling-hosted trust store has invalid machine-local placement"
assert_match '^gate: denied$' "$out" \
  "a sibling-hosted trust store defaults to a denied unattended gate"
assert_match 'inside registered worktree' "$out" \
  "sibling trust-store refusal names the registered-worktree boundary"
rc=0
HOME="$sibling_home" "$ORCHID_BIN" trust unattended "$sibling_target" \
  --reason "must remain outside every sibling" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement must refuse a trust store inside a sibling worktree"
assert_eq "$sibling_record_before" "$(cat "$sibling_record")" \
  "sibling-store refusal must not rewrite repository-controlled trust state"

# A local clone has the same root history but a different common-directory
# filesystem identity, so origin/history similarity grants nothing.
clone="$WORK/clone"
git clone -q "$repo" "$clone"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$clone")"
assert_match '^unattended trust: untrusted$' "$out" "fresh clone is untrusted"
assert_match '^gate: denied$' "$out" "fresh clone remains gated"

# Ambient Git repository-selection variables cannot substitute an already
# trusted common directory for the target being inspected. This is especially
# important for self-hosted/nested runs, where Git variables can legitimately
# be present in the outer process environment.
spoof_target="$WORK/spoof-target"
mk_repo "$spoof_target"
out="$(HOME="$home" GIT_DIR="$repo/.git" GIT_WORK_TREE="$spoof_target" \
  "$ORCHID_BIN" trust show "$spoof_target")"
assert_match '^unattended trust: untrusted$' "$out" \
  "ambient GIT_DIR/GIT_WORK_TREE cannot lend another repo's acknowledgement"
spoof_common="$(git -C "$spoof_target" rev-parse --git-common-dir)"
spoof_common="$(cd "$spoof_target/$spoof_common" && pwd -P)"
assert_match "^git_common_dir: $spoof_common$" "$out" \
  "identity inspection resolves the target's own Git common directory"

# A filesystem copy likewise gets a distinct common-directory inode.
copy="$WORK/copy"
cp -R "$repo" "$copy"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$copy")"
assert_match '^unattended trust: untrusted$' "$out" "filesystem copy is untrusted"

# Canonical-path capture must retain trailing newlines. Without lossless
# framing around `pwd`, the untrusted path below collapses onto its trusted
# sibling and the sibling's common-directory acknowledgement is reused.
newline_trusted="$WORK/newline-sibling"
newline_untrusted="${newline_trusted}"$'\n'
mk_repo "$newline_trusted"
mk_repo "$newline_untrusted"
trust_repo "$newline_trusted" "trusted sibling only"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$newline_untrusted")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a newline-suffixed untrusted repo cannot collapse onto a trusted sibling"
assert_match '^gate: denied$' "$out" \
  "the losslessly distinct newline-suffixed repository remains gated"

# Git itself permits newlines inside both sides of a linked-worktree
# registration. Whole-file pointer parsing and lossless canonicalization must
# retain them while still enforcing the reciprocal caller-path binding.
newline_main="$WORK/newline-main"$'\n'
newline_linked="$WORK/newline-linked"$'\n'
mk_repo "$newline_main"
trust_repo "$newline_main" "newline-linked fixture"
git -C "$newline_main" worktree add -q --detach "$newline_linked" HEAD
out="$(HOME="$home" "$ORCHID_BIN" trust show "$newline_linked")"
assert_match '^unattended trust: trusted$' "$out" \
  "linked-worktree trust preserves newlines in common and registered paths"

# ---------------------------------------------------------------------------
# Path independence: moving the same common directory on one filesystem keeps
# its device/inode and therefore its acknowledgement.
# ---------------------------------------------------------------------------
move_repo="$WORK/move-repo"
mk_repo "$move_repo"
# An absolute core.worktree becomes stale after the rename. It must not
# override the physical marker/common-directory identity used by trust.
git -C "$move_repo" config core.worktree "$move_repo"
trust_repo "$move_repo" "safe to move"
move_record="$(HOME="$home" "$ORCHID_BIN" trust show "$move_repo" | sed -n 's/^record: //p')"
moved_repo="$WORK/moved-repo"
mv "$move_repo" "$moved_repo"
assert_eq false \
  "$(git -C "$moved_repo" rev-parse --is-inside-work-tree)" \
  "move fixture must leave Git's configured worktree path stale"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$moved_repo")"
assert_match '^unattended trust: trusted$' "$out" "same-filesystem move preserving inode remains trusted"
assert_match "record: $move_record" "$out" "move still resolves the identity-keyed record"

# Replacing .git changes the common-directory filesystem identity even when
# the working-tree path stays unchanged.
replace_repo="$WORK/replace-repo"
mk_repo "$replace_repo"
trust_repo "$replace_repo" "before gitdir replacement"
mv "$replace_repo/.git" "$WORK/replaced-old-git"
git -C "$replace_repo" init -q
git -C "$replace_repo" commit -q --allow-empty -m replacement-root
out="$(HOME="$home" "$ORCHID_BIN" trust show "$replace_repo")"
assert_match '^unattended trust: untrusted$' "$out" "replacement/recreated .git is untrusted"

# Device/inode numbers can eventually be reused after a directory is removed.
# Recreate a clone at the exact acknowledged root, then interpose only the
# common-directory stat result to emulate that reuse deterministically. The
# old machine-local JSON key, common-directory identity, root history, and
# policy all match; the non-reusable hard-link anchor must still distinguish
# the new clone from the moved-away repository incarnation.
reuse_repo="$WORK/reused-identity-repo"
reuse_seed="$WORK/reused-identity-seed"
reuse_old="$WORK/reused-identity-old"
mk_repo "$reuse_repo"
trust_repo "$reuse_repo" "original repository incarnation"
reuse_out="$(HOME="$home" "$ORCHID_BIN" trust show "$reuse_repo")"
reuse_device="$(printf '%s\n' "$reuse_out" | sed -n 's/^git_common_device: //p')"
reuse_inode="$(printf '%s\n' "$reuse_out" | sed -n 's/^git_common_inode: //p')"
reuse_common="$(printf '%s\n' "$reuse_out" | sed -n 's/^git_common_dir: //p')"
reuse_root="$(git -C "$reuse_repo" rev-parse HEAD)"
git clone -q "$reuse_repo" "$reuse_seed"
mv "$reuse_repo" "$reuse_old"
git clone -q "$reuse_seed" "$reuse_repo"
assert_eq "$reuse_root" "$(git -C "$reuse_repo" rev-parse HEAD)" \
  "recreated-clone fixture must preserve the acknowledged root history"

fake_stat_bin="$WORK/reused-identity-bin"
mkdir -p "$fake_stat_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$#" -eq 3 ] && [ "$1" = -f ] && [ "$2" = "%d %i" ] && [ "$3" = "$ORCHID_TEST_REUSED_COMMON" ]; then' \
  '  printf "%s\\n" "$ORCHID_TEST_REUSED_IDENT"' \
  '  exit 0' \
  'fi' \
  'exec "$ORCHID_TEST_REAL_STAT" "$@"' \
  >"$fake_stat_bin/stat"
chmod +x "$fake_stat_bin/stat"
real_stat="$(command -v stat)"
out="$(
  HOME="$home" \
  PATH="$fake_stat_bin:$PATH" \
  ORCHID_TEST_REAL_STAT="$real_stat" \
  ORCHID_TEST_REUSED_COMMON="$reuse_common" \
  ORCHID_TEST_REUSED_IDENT="$reuse_device $reuse_inode" \
  "$ORCHID_BIN" trust show "$reuse_repo"
)"
assert_match '^unattended trust: untrusted$' "$out" \
  "a recreated clone stays untrusted when common-directory device/inode are reused"
assert_match '^binding_state: mismatch$' "$out" \
  "reused numeric filesystem identity is rejected as another repository incarnation"
assert_match 'repository incarnation anchor is missing or does not match' "$out" \
  "recreated-clone refusal identifies the non-reusable incarnation binding"

# Replacing root history in the SAME common directory produces a named
# mismatch rather than silently inheriting the old acknowledgement.
history_repo="$WORK/history-repo"
mk_repo "$history_repo"
old_root="$(git -C "$history_repo" rev-parse HEAD)"
trust_repo "$history_repo" "original root history"
git -C "$history_repo" checkout -q --orphan replacement-history
git -C "$history_repo" commit -q --allow-empty -m replacement-history
new_root="$(git -C "$history_repo" rev-parse HEAD)"
[ "$old_root" != "$new_root" ] || fail "history fixture must produce a different root commit"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$history_repo")"
assert_match '^unattended trust: untrusted$' "$out" "root-history replacement invalidates trust"
assert_match '^binding_state: mismatch$' "$out" "root replacement is classified as a binding mismatch"
assert_match 'repository root commit changed' "$out" "root mismatch is actionable"

# Git replacement refs and legacy grafts are repository-local object views.
# Neither may disguise a replacement history as descending from the root that
# the operator acknowledged.
view_repo="$WORK/object-view-repo"
mk_repo "$view_repo"
view_old_root="$(git -C "$view_repo" rev-parse HEAD)"
git -C "$view_repo" commit -q --allow-empty -m descendant
view_descendant="$(git -C "$view_repo" rev-parse HEAD)"
trust_repo "$view_repo" "underlying history only"
git -C "$view_repo" checkout -q --orphan replacement-history
git -C "$view_repo" commit -q --allow-empty -m replacement-history
view_new_root="$(git -C "$view_repo" rev-parse HEAD)"

git -C "$view_repo" replace "$view_new_root" "$view_descendant"
assert_eq "$view_old_root" \
  "$(git -C "$view_repo" rev-list --max-parents=0 HEAD 2>/dev/null)" \
  "replacement-ref fixture must disguise the new root from an ordinary Git query"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$view_repo")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a replacement ref cannot preserve unattended trust across root replacement"
assert_match "^root_commit: $view_new_root$" "$out" \
  "trust inspection ignores replacement refs when binding root history"
git -C "$view_repo" replace -d "$view_new_root" >/dev/null

printf '%s %s\n' "$view_new_root" "$view_old_root" > "$view_repo/.git/info/grafts"
assert_eq "$view_old_root" \
  "$(git -C "$view_repo" rev-list --max-parents=0 HEAD 2>/dev/null)" \
  "graft fixture must disguise the new root from an ordinary Git query"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$view_repo")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a legacy graft cannot preserve unattended trust across root replacement"
assert_match "^root_commit: $view_new_root$" "$out" \
  "trust inspection ignores legacy grafts when binding root history"

# A shallow boundary is not the repository's underlying root. Trust
# inspection must not bind to that movable boundary or fetch the omitted
# ancestry as a side effect; acknowledgement remains unavailable until the
# history is locally complete.
shallow_source="$WORK/shallow-source"
mk_repo "$shallow_source"
git -C "$shallow_source" commit -q --allow-empty -m descendant
shallow_repo="$WORK/shallow-repo"
git -c protocol.file.allow=always clone -q --depth 1 \
  "file://$shallow_source" "$shallow_repo"
shallow_tip="$(git -C "$shallow_repo" rev-parse HEAD)"
assert_eq "$shallow_tip" \
  "$(git -C "$shallow_repo" rev-list --max-parents=0 HEAD)" \
  "ordinary Git must treat the shallow tip as the fixture's traversal root"
rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$shallow_repo" \
  --reason "incomplete ancestry must fail closed" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a shallow history must not be acknowledged as complete"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$shallow_repo")"
assert_match '^binding_state: unavailable$' "$out" \
  "a shallow repository has no locally establishable underlying root"
assert_match '^root_commit: unavailable$' "$out" \
  "the shallow traversal boundary is never surfaced as the trust root"
[ -f "$shallow_repo/.git/shallow" ] \
  || fail "trust inspection must not deepen or rewrite a shallow repository"

# Git before 2.45 ignores GIT_NO_LAZY_FETCH during client-side object access.
# Model that supported-range edge with a wrapper that advertises 2.44 and
# would explicitly drop the variable at any object walk. The repository is
# marked partial/promisor, its root object is absent, and its remote is an
# executable contact trap. Inspection must reject the Git version before any
# target-repository Git command, so neither the walk nor the remote can run.
promisor_repo="$WORK/promisor-old-git"
mk_repo "$promisor_repo"
promisor_root="$(git -C "$promisor_repo" rev-parse HEAD)"
git -C "$promisor_repo" commit -q --allow-empty -m descendant
git -C "$promisor_repo" config core.repositoryformatversion 1
git -C "$promisor_repo" config extensions.partialClone origin
git -C "$promisor_repo" config remote.origin.promisor true
git -C "$promisor_repo" config remote.origin.partialCloneFilter blob:none

promisor_contact="$WORK/promisor-contacted"
promisor_walk="$WORK/promisor-object-walk"
promisor_target_git="$WORK/promisor-target-git-query"
promisor_helper="$WORK/promisor-contact-helper"
cat > "$promisor_helper" <<'EOF'
#!/usr/bin/env bash
printf 'contacted\n' > "$ORCHID_TEST_PROMISOR_CONTACT"
exit 1
EOF
chmod +x "$promisor_helper"
git -C "$promisor_repo" config remote.origin.url "ext::$promisor_helper"
git -C "$promisor_repo" config protocol.ext.allow always

promisor_root_object="$promisor_repo/.git/objects/${promisor_root:0:2}/${promisor_root:2}"
[ -f "$promisor_root_object" ] \
  || fail "promisor fixture root commit must begin as a loose local object"
rm -f "$promisor_root_object"
[ ! -e "$promisor_root_object" ] \
  || fail "promisor fixture root commit must be absent before inspection"

old_git_bin="$WORK/old-git-bin"
mkdir -p "$old_git_bin"
cat > "$old_git_bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
  printf 'git version 2.44.0\n'
  exit 0
fi
printf 'target query\n' > "$ORCHID_TEST_TARGET_GIT"
for arg in "$@"; do
  if [ "$arg" = rev-list ]; then
    printf 'object walk\n' > "$ORCHID_TEST_OBJECT_WALK"
    unset GIT_NO_LAZY_FETCH
  fi
done
exec "$ORCHID_TEST_REAL_GIT" "$@"
EOF
chmod +x "$old_git_bin/git"

real_git="$(command -v git)"
out="$(
  HOME="$home" PATH="$old_git_bin:$PATH" \
  ORCHID_TEST_REAL_GIT="$real_git" \
  ORCHID_TEST_PROMISOR_CONTACT="$promisor_contact" \
  ORCHID_TEST_OBJECT_WALK="$promisor_walk" \
  ORCHID_TEST_TARGET_GIT="$promisor_target_git" \
  "$ORCHID_BIN" trust show "$promisor_repo"
)"
assert_match '^binding_state: unavailable$' "$out" \
  "Git without reliable no-lazy-fetch support makes trust unavailable"
assert_match 'requires Git 2\.45 or newer \(found 2\.44\.0\)' "$out" \
  "old-Git refusal names the explicit safe minimum"
assert_match '^root_commit: unavailable$' "$out" \
  "old Git is refused before the missing root is inspected"
[ ! -e "$promisor_target_git" ] \
  || fail "old-Git refusal must precede every target-repository Git query"
[ ! -e "$promisor_walk" ] \
  || fail "old-Git refusal must occur before any history object walk"
[ ! -e "$promisor_contact" ] \
  || fail "trust inspection must never contact a promisor remote on old Git"
[ ! -e "$promisor_root_object" ] \
  || fail "trust inspection must not hydrate a missing promisor object"

# A policy-version mismatch is also fail-closed. Simulate a record written
# under an older policy; the executable's current policy constant remains 1.
policy_repo="$WORK/policy-repo"
mk_repo "$policy_repo"
trust_repo "$policy_repo" "policy fixture"
policy_record="$(HOME="$home" "$ORCHID_BIN" trust show "$policy_repo" | sed -n 's/^record: //p')"
jq '.policy_version = 0' "$policy_record" | atomic_write "$policy_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$policy_repo")"
assert_match '^unattended trust: untrusted$' "$out" "policy-version change invalidates trust"
assert_match '^binding_state: mismatch$' "$out" "policy change is classified as a binding mismatch"
assert_match 'trust-policy version changed' "$out" "policy mismatch is actionable"

jq '.policy_version = 1 | .kind = "plugin"' "$policy_record" | atomic_write "$policy_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$policy_repo")"
assert_match '^binding_state: invalid$' "$out" "a record for another trust kind fails closed"
assert_match 'record kind is invalid' "$out" "invalid record kind is named"

jq '.kind = "unattended" | .reason = "   "' "$policy_record" | atomic_write "$policy_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$policy_repo")"
assert_match '^binding_state: invalid$' "$out" "whitespace-only recorded provenance fails closed"
assert_match 'missing operator provenance' "$out" "invalid recorded provenance is named"

jq '.reason = "valid" | .policy_version = "1"' "$policy_record" | atomic_write "$policy_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$policy_repo")"
assert_match '^binding_state: invalid$' "$out" "wrongly typed record fields fail closed"
assert_match 'record is malformed' "$out" "a record schema type error is named"

# Revocation from either the main checkout or a linked worktree removes the
# shared record and is idempotent.
out="$(HOME="$home" "$ORCHID_BIN" trust revoke "$linked")"; rc=$?
assert_eq 0 "$rc" "trust revoke succeeds from a linked worktree"
assert_match '^unattended trust revoked:' "$out" "revoke prints confirmation"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$repo")"
assert_match '^unattended trust: untrusted$' "$out" "revoke disables the main checkout too"
[ ! -e "$anchor" ] || fail "revoke removes the outside incarnation anchor"
[ -f "$witness" ] || fail "revoke leaves Git's existing identity witness untouched"
out="$(HOME="$home" "$ORCHID_BIN" trust revoke "$repo")"; rc=$?
assert_eq 0 "$rc" "revoke is idempotent"
assert_match 'already absent' "$out" "idempotent revoke names the absent record"

# ---------------------------------------------------------------------------
# Exemptions: manual/interactive and read-only commands still work without
# silently creating an unattended acknowledgement.
# ---------------------------------------------------------------------------
manual="$WORK/manual"
mk_repo "$manual"
mkdir -p "$manual/.orchid/tasks"
printf -- '---\nrun_status: planning\nrun_id: r-manual\n---\n# Roadmap\n' > "$manual/.orchid/roadmap.md"
printf '# Journal\n' > "$manual/.orchid/journal.md"

out="$(HOME="$home" ORCHID_REPO="$manual" "$ORCHID_BIN" status --explain)"; rc=$?
assert_eq 0 "$rc" "read-only status --explain remains available while untrusted"
assert_match '^unattended: denied' "$out" "status --explain names the headless gate"

out="$(HOME="$home" ORCHID_REPO="$manual" "$ORCHID_BIN" run start)"; rc=$?
assert_eq 0 "$rc" "explicit manual run start remains available while unattended trust is denied"
assert_match '^epoch: [0-9]+$' "$out" "manual run start still fences an epoch"

out="$(HOME="$home" "$ORCHID_BIN" trust show "$manual")"
assert_match '^unattended trust: untrusted$' "$out" "manual operation never silently opts into unattended trust"
