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
assert_match '^root_commit: pending$' "$out" \
  "show honestly defers root verification until an acknowledgement candidate exists"
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

# Deterministically fence the fast-deny boundary. Directly source the trust
# library with git/mktemp wrappers so this checks implementation work rather
# than wall-clock time. A no-record inspection must derive the identity-keyed
# path without invoking Git or creating any scratch file.
fast_guard_bin="$WORK/unattended-fast-guard-bin"
fast_guard_log="$WORK/unattended-fast-guard.log"
fast_guard_real_git="$(command -v git)"
fast_guard_real_mktemp="$(command -v mktemp)"
mkdir -p "$fast_guard_bin"
cat > "$fast_guard_bin/git" <<'EOF'
#!/bin/bash
printf 'git\t%s\n' "$*" >> "$ORCHID_TEST_FAST_GUARD_LOG"
exec "$ORCHID_TEST_FAST_GUARD_REAL_GIT" "$@"
EOF
cat > "$fast_guard_bin/mktemp" <<'EOF'
#!/bin/bash
printf 'mktemp\t%s\n' "$*" >> "$ORCHID_TEST_FAST_GUARD_LOG"
exec "$ORCHID_TEST_FAST_GUARD_REAL_MKTEMP" "$@"
EOF
chmod +x "$fast_guard_bin/git" "$fast_guard_bin/mktemp"

FAST_GUARD_OUT=""
assert_fast_denial_has_zero_repository_work() {
  local label="$1" target_repo="$2"
  : > "$fast_guard_log"
  FAST_GUARD_OUT="$(
    HOME="$home" PATH="$fast_guard_bin:$PATH" \
    ORCHID_ROOT="$REPO_ROOT" \
    ORCHID_TEST_FAST_GUARD_LOG="$fast_guard_log" \
    ORCHID_TEST_FAST_GUARD_REAL_GIT="$fast_guard_real_git" \
    ORCHID_TEST_FAST_GUARD_REAL_MKTEMP="$fast_guard_real_mktemp" \
    ORCHID_TEST_FAST_GUARD_REPO="$target_repo" \
    /bin/bash -c '
      set -euo pipefail
      source "$ORCHID_ROOT/lib/common.sh"
      source "$ORCHID_ROOT/lib/trust.sh"
      unattended_trust_show "$ORCHID_TEST_FAST_GUARD_REPO"
    '
  )"
  assert_match '^binding_state: untrusted$' "$FAST_GUARD_OUT" \
    "$label is default-denied"
  assert_match '^root_commit: pending$' "$FAST_GUARD_OUT" \
    "$label leaves unneeded root verification pending"
  [ ! -s "$fast_guard_log" ] \
    || fail "$label invoked Git or mktemp before finding an acknowledgement ($(tr '\n' ' ' < "$fast_guard_log"))"
}

assert_fast_denial_has_zero_repository_work \
  "a fresh unacknowledged repository" "$repo"

# The explicit acknowledgement-only path is allowed to cross that boundary,
# but it must finish a complete walk and exact-payload rehash before staging
# the JSON record. Its ordinary post-write inspection also verifies that the
# new candidate can independently reach the trusted state.
fast_ack_repo="$WORK/unattended-fast-guard-ack"
mk_repo "$fast_ack_repo"
: > "$fast_guard_log"
fast_ack_out="$(
  HOME="$home" PATH="$fast_guard_bin:$PATH" \
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_FAST_GUARD_LOG="$fast_guard_log" \
  ORCHID_TEST_FAST_GUARD_REAL_GIT="$fast_guard_real_git" \
  ORCHID_TEST_FAST_GUARD_REAL_MKTEMP="$fast_guard_real_mktemp" \
  ORCHID_TEST_FAST_GUARD_REPO="$fast_ack_repo" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_acknowledge \
      "$ORCHID_TEST_FAST_GUARD_REPO" "instrumented acknowledgement"
    printf "state: %s\nrecord: %s\n" \
      "$ORCHID_UNATTENDED_STATE" "$ORCHID_UNATTENDED_RECORD"
  '
)"
assert_match '^state: trusted$' "$fast_ack_out" \
  "the acknowledgement-only verifier persists a usable record"
grep -q $'^git\t.*rev-list --parents ' "$fast_guard_log" \
  || fail "acknowledgement must completely walk reachable commit history"
grep -q $'^git\t.*cat-file --batch=' "$fast_guard_log" \
  || fail "acknowledgement must batch-read exact commit payloads"
grep -q $'^git\t.*hash-object --no-filters -t commit --stdin-paths' "$fast_guard_log" \
  || fail "acknowledgement must batch-rehash exact commit payloads"
grep -q $'^mktemp\t-d .*/orchid-unattended-commit-verify\\.XXXXXX$' "$fast_guard_log" \
  || fail "acknowledgement must use bounded private history-verification scratch space"
fast_ack_hash_line="$(
  grep -n $'^git\t.*hash-object --no-filters -t commit --stdin-paths' \
    "$fast_guard_log" | head -n 1 | cut -d: -f1
)"
fast_ack_record_line="$(
  grep -n $'^mktemp\t.*\\.json\\.tmp\\.XXXXXX$' \
    "$fast_guard_log" | head -n 1 | cut -d: -f1
)"
[ -n "$fast_ack_hash_line" ] && [ -n "$fast_ack_record_line" ] \
  && [ "$fast_ack_hash_line" -lt "$fast_ack_record_line" ] \
  || fail "complete exact-payload verification must precede JSON record staging"

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
target_entries="$(list_dir_entries "$record_target_dir" | wc -l | tr -d ' ')"
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
assert_fast_denial_has_zero_repository_work \
  "a repository with a replaced Git common directory" "$replace_repo"

# Every unattended process must reach the identity gate without consulting the
# captured operator PATH. This includes the kernel-selected Bash interpreter,
# self-resolution helpers, and the awk/git/stat/jq toolchain used by trust
# inspection. Build shims capable of presenting the old identity/root/record
# after a .git replacement, put them first on PATH, and also provide a BASH_ENV
# prelude. A fresh target and the replaced target must both be denied by each
# real entry surface without executing any of that target-influenced code.
entry_fresh="$WORK/unattended-entry-fresh"
entry_replaced="$WORK/unattended-entry-replaced"
entry_replaced_old_git="$WORK/unattended-entry-replaced-old-git"
mk_repo "$entry_fresh"
mk_repo "$entry_replaced"
for entry_repo in "$entry_fresh" "$entry_replaced"; do
  mkdir -p "$entry_repo/.orchid/tasks"
  printf -- '---\nrun_status: running\nrun_id: r-path-boundary\n---\n# Roadmap\n' \
    > "$entry_repo/.orchid/roadmap.md"
done

trust_repo "$entry_replaced" "PATH boundary replacement fixture"
entry_old_out="$(HOME="$home" "$ORCHID_BIN" trust show "$entry_replaced")"
entry_old_device="$(printf '%s\n' "$entry_old_out" | sed -n 's/^git_common_device: //p')"
entry_old_inode="$(printf '%s\n' "$entry_old_out" | sed -n 's/^git_common_inode: //p')"
entry_old_anchor_device="$(printf '%s\n' "$entry_old_out" | sed -n 's/^recorded_identity_anchor_device: //p')"
entry_old_anchor_inode="$(printf '%s\n' "$entry_old_out" | sed -n 's/^recorded_identity_anchor_inode: //p')"
entry_old_root="$(printf '%s\n' "$entry_old_out" | sed -n 's/^root_commit: //p')"
entry_old_record="$(printf '%s\n' "$entry_old_out" | sed -n 's/^record: //p')"
entry_old_anchor="$(printf '%s\n' "$entry_old_out" | sed -n 's/^identity_anchor: //p')"

mv "$entry_replaced/.git" "$entry_replaced_old_git"
git -C "$entry_replaced" init -q
git -C "$entry_replaced" commit -q --allow-empty -m replacement-root
entry_new_common="$(cd "$entry_replaced/.git" && pwd -P)"
entry_new_witness="$entry_new_common/description"
entry_new_head="$(git -C "$entry_replaced" rev-parse HEAD)"
[ "$entry_new_head" != "$entry_old_root" ] \
  || fail "PATH boundary replacement fixture must have a new root commit"

entry_shim_bin="$WORK/unattended-entry-shims"
entry_shim_log="$WORK/unattended-entry-shim.log"
entry_bash_env="$WORK/unattended-entry-bash-env"
mkdir -p "$entry_shim_bin"
cat > "$entry_shim_bin/attack-tool" <<'EOF'
#!/bin/sh
tool=${0##*/}
printf '%s\n' "$tool" >> "$ORCHID_TEST_ENTRY_SHIM_LOG"

case "$tool" in
  bash)
    exec /bin/bash "$@"
    ;;
  readlink|dirname|pwd|awk|sort|grep|cat|tr|sed)
    eval "real=\${ORCHID_TEST_REAL_${tool}}"
    exec "$real" "$@"
    ;;
  git)
    for arg in "$@"; do
      case "$arg" in
        --version)
          printf 'git version 2.50.1\n'
          exit 0
          ;;
        --git-common-dir)
          printf '%s\n' "$ORCHID_TEST_ENTRY_COMMON"
          exit 0
          ;;
        rev-list)
          printf '%s\n' "$ORCHID_TEST_ENTRY_OLD_ROOT"
          exit 0
          ;;
        worktree)
          printf 'worktree %s\0HEAD %s\0branch refs/heads/main\0\0' \
            "$ORCHID_TEST_ENTRY_REPO" "$ORCHID_TEST_ENTRY_NEW_HEAD"
          exit 0
          ;;
      esac
    done
    exit 1
    ;;
  stat)
    last=
    for last do :; done
    case "${2:-}" in
      '%d %i')
        case "$last" in
          "$ORCHID_TEST_ENTRY_COMMON")
            printf '%s %s\n' \
              "$ORCHID_TEST_ENTRY_OLD_DEVICE" "$ORCHID_TEST_ENTRY_OLD_INODE"
            ;;
          "$ORCHID_TEST_ENTRY_OLD_ANCHOR"|"$ORCHID_TEST_ENTRY_NEW_WITNESS")
            printf '%s %s\n' \
              "$ORCHID_TEST_ENTRY_OLD_ANCHOR_DEVICE" \
              "$ORCHID_TEST_ENTRY_OLD_ANCHOR_INODE"
            ;;
          "$ORCHID_TEST_ENTRY_OLD_RECORD")
            printf '900001 900002\n'
            ;;
          *)
            printf '900003 900004\n'
            ;;
        esac
        ;;
      '%l %Lp')
        case "$last" in
          "$ORCHID_TEST_ENTRY_OLD_RECORD") printf '1 600\n' ;;
          *) printf '2 644\n' ;;
        esac
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  jq)
    exec "$ORCHID_TEST_REAL_jq" "$@"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$entry_shim_bin/attack-tool"
for entry_tool in bash readlink dirname pwd awk sort grep cat tr sed git stat jq; do
  ln -s attack-tool "$entry_shim_bin/$entry_tool"
done
cat > "$entry_bash_env" <<'EOF'
printf '%s\n' BASH_ENV >> "$ORCHID_TEST_ENTRY_SHIM_LOG"
EOF

export ORCHID_TEST_ENTRY_SHIM_LOG="$entry_shim_log"
export ORCHID_TEST_ENTRY_OLD_DEVICE="$entry_old_device"
export ORCHID_TEST_ENTRY_OLD_INODE="$entry_old_inode"
export ORCHID_TEST_ENTRY_OLD_ANCHOR_DEVICE="$entry_old_anchor_device"
export ORCHID_TEST_ENTRY_OLD_ANCHOR_INODE="$entry_old_anchor_inode"
export ORCHID_TEST_ENTRY_OLD_ROOT="$entry_old_root"
export ORCHID_TEST_ENTRY_OLD_RECORD="$entry_old_record"
export ORCHID_TEST_ENTRY_OLD_ANCHOR="$entry_old_anchor"
export ORCHID_TEST_ENTRY_COMMON="$entry_new_common"
export ORCHID_TEST_ENTRY_NEW_WITNESS="$entry_new_witness"
export ORCHID_TEST_ENTRY_REPO="$entry_replaced"
export ORCHID_TEST_ENTRY_NEW_HEAD="$entry_new_head"
for entry_tool in readlink dirname pwd awk sort grep cat tr sed jq; do
  eval "ORCHID_TEST_REAL_${entry_tool}=\$(command -v \"$entry_tool\")"
  eval "export ORCHID_TEST_REAL_${entry_tool}"
done

assert_entry_path_denied() {
  local label="$1" refusal="$2" target_repo="$3"
  local rc=0 out
  shift 3
  rm -f "$entry_shim_log"
  out="$(
    HOME="$home" PATH="$entry_shim_bin:$PATH" BASH_ENV="$entry_bash_env" \
      ORCHID_REPO="$target_repo" \
      "$@" 2>&1
  )" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label must be denied"
  assert_match "$refusal" "$out" "$label reaches the unattended refusal"
  [ ! -e "$entry_shim_log" ] \
    || fail "$label executed a pre-authorization PATH/BASH_ENV shim ($(tr '\n' ' ' < "$entry_shim_log"))"
}

# Read-only trust/status entry points and trust mutations must retain the fixed
# interpreter/helper path for their complete authorization work. Exercise both
# normal dispatch and direct libexec execution; also inject a bogus
# ORCHID_ROOT, which direct entry must replace from its own physical path.
ENTRY_PATH_OUT=""
assert_entry_path_clean() {
  local label="$1" expected_rc="$2" expected="$3" target_repo="$4"
  local rc=0
  shift 4
  rm -f "$entry_shim_log"
  ENTRY_PATH_OUT="$(
    HOME="$home" PATH="$entry_shim_bin:$PATH" BASH_ENV="$entry_bash_env" \
      ORCHID_ROOT="$entry_fresh" ORCHID_REPO="$target_repo" \
      "$@" 2>&1
  )" || rc=$?
  assert_eq "$expected_rc" "$rc" "$label exit status"
  assert_match "$expected" "$ENTRY_PATH_OUT" "$label reports the real gate/provenance"
  [ ! -e "$entry_shim_log" ] \
    || fail "$label executed a trust-reporting PATH/BASH_ENV shim ($(tr '\n' ' ' < "$entry_shim_log"))"
}

assert_entry_path_clean \
  "dispatched trust show" 0 \
  '^root_commit: pending$' "$entry_replaced" \
  "$ORCHID_BIN" trust show "$entry_replaced"
assert_match '^unattended trust: untrusted$' "$ENTRY_PATH_OUT" \
  "dispatched trust show cannot inherit the replaced repository's old acknowledgement"
assert_entry_path_clean \
  "direct trust show" 0 \
  '^root_commit: pending$' "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-trust" show "$entry_replaced"
assert_match '^unattended trust: untrusted$' "$ENTRY_PATH_OUT" \
  "direct trust show cannot inherit the replaced repository's old acknowledgement"

entry_dispatch_reason="dispatched PATH-boundary acknowledgement"
assert_entry_path_clean \
  "dispatched trust acknowledgement" 0 \
  "reason: $entry_dispatch_reason$" "$entry_replaced" \
  "$ORCHID_BIN" trust unattended "$entry_replaced" \
    --reason "$entry_dispatch_reason"
assert_match "root_commit: $entry_new_head$" "$ENTRY_PATH_OUT" \
  "dispatched acknowledgement binds the real replacement root"
entry_new_record="$(
  printf '%s\n' "$ENTRY_PATH_OUT" | sed -n 's/^  record: //p'
)"
[ -f "$entry_new_record" ] \
  || fail "dispatched acknowledgement must create the real replacement identity record"

assert_entry_path_clean \
  "direct trusted show" 0 '^unattended trust: trusted$' "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-trust" show "$entry_replaced"
assert_match "^record: $entry_new_record$" "$ENTRY_PATH_OUT" \
  "direct trust show resolves the record authored by dispatched trust"
assert_entry_path_clean \
  "direct trust revoke" 0 '^unattended trust revoked:' "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-trust" revoke "$entry_replaced"
[ ! -e "$entry_new_record" ] \
  || fail "direct revoke must remove the replacement identity record"
[ -f "$entry_old_record" ] \
  || fail "direct revoke must not let PATH shims redirect it to the old identity record"

entry_direct_reason="direct PATH-boundary acknowledgement"
assert_entry_path_clean \
  "direct trust acknowledgement" 0 \
  "reason: $entry_direct_reason$" "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-trust" unattended "$entry_replaced" \
    --reason "$entry_direct_reason"
entry_new_record="$(
  printf '%s\n' "$ENTRY_PATH_OUT" | sed -n 's/^  record: //p'
)"
assert_entry_path_clean \
  "dispatched trusted show" 0 '^unattended trust: trusted$' "$entry_replaced" \
  "$ORCHID_BIN" trust show "$entry_replaced"
assert_match "^root_commit: $entry_new_head$" "$ENTRY_PATH_OUT" \
  "dispatched trust show agrees with direct acknowledgement provenance"
assert_entry_path_clean \
  "dispatched trust revoke" 0 '^unattended trust revoked:' "$entry_replaced" \
  "$ORCHID_BIN" trust revoke "$entry_replaced"
[ ! -e "$entry_new_record" ] \
  || fail "dispatched revoke must remove the direct-entry identity record"

# Explain status keeps the fixed helper path for the entire report. Text and
# HTML modes must expose the same denied gate and honest pending-root
# provenance through both dispatch surfaces, exactly as the runners below
# enforce it.
assert_entry_path_clean \
  "dispatched status --explain" 0 \
  '^unattended: denied.*root pending' "$entry_replaced" \
  "$ORCHID_BIN" status --explain
assert_entry_path_clean \
  "direct status --explain" 0 \
  '^unattended: denied.*root pending' "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-status" --explain
assert_entry_path_clean \
  "dispatched status --html --explain" 0 \
  '\.orchid/runtime/status\.html$' "$entry_replaced" \
  "$ORCHID_BIN" status --html --explain
entry_status_page="$ENTRY_PATH_OUT"
entry_status_content="$(/bin/cat "$entry_status_page")"
assert_match '<strong>gate:</strong> denied' "$entry_status_content" \
  "dispatched HTML status reports the denied runner gate"
assert_match 'root pending' "$entry_status_content" \
  "dispatched HTML status reports that replacement-root verification is pending"
assert_entry_path_clean \
  "direct status --html --explain" 0 \
  '\.orchid/runtime/status\.html$' "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-status" --html --explain
entry_status_content="$(/bin/cat "$ENTRY_PATH_OUT")"
assert_match '<strong>gate:</strong> denied' "$entry_status_content" \
  "direct HTML status reports the denied runner gate"
assert_match 'root pending' "$entry_status_content" \
  "direct HTML status reports that replacement-root verification is pending"

# Doctor prints its trust verdict before restoring the operator PATH needed by
# later readiness/binary checks. Those later shims may run, but cannot change
# the first, already-emitted gate line.
assert_doctor_entry_gate() {
  local label="$1" target_repo="$2"
  local out first
  shift 2
  rm -f "$entry_shim_log"
  out="$(
    HOME="$home" PATH="$entry_shim_bin:$PATH" BASH_ENV="$entry_bash_env" \
      ORCHID_ROOT="$entry_fresh" ORCHID_REPO="$target_repo" \
      "$@" 2>&1
  )" || true
  first="${out%%$'\n'*}"
  assert_match \
    '^WARN: unattended trust \(headless execution gated\): denied.*root pending' \
    "$first" "$label prints the fast denied runner gate before operator-PATH checks"
  case "$(printf '%s\n' "$out" | grep -Ec '^(ok|WARN): unattended trust')" in
    1) ;;
    *) fail "$label must print exactly one unattended trust verdict" ;;
  esac
}
assert_doctor_entry_gate \
  "dispatched doctor" "$entry_replaced" "$ORCHID_BIN" doctor
assert_doctor_entry_gate \
  "direct doctor" "$entry_replaced" "$REPO_ROOT/libexec/orchid-doctor"

assert_entry_path_denied \
  "fresh-target pump" \
  'unattended pump refused: unattended trust is denied' \
  "$entry_fresh" \
  "$REPO_ROOT/runners/orchid-pump"
assert_entry_path_denied \
  "fresh-target tick" \
  'headless tick refused: unattended trust is denied' \
  "$entry_fresh" \
  "$REPO_ROOT/runners/orchid-tick"
assert_entry_path_denied \
  "fresh-target service install" \
  'service installation refused: unattended trust is denied' \
  "$entry_fresh" \
  "$ORCHID_BIN" service install --dry-run
assert_entry_path_denied \
  "fresh-target direct libexec service install" \
  'service installation refused: unattended trust is denied' \
  "$entry_fresh" \
  "$REPO_ROOT/libexec/orchid-service" install --dry-run

assert_entry_path_denied \
  "replaced-target pump" \
  'unattended pump refused: unattended trust is denied' \
  "$entry_replaced" \
  "$REPO_ROOT/runners/orchid-pump"
assert_entry_path_denied \
  "replaced-target tick" \
  'headless tick refused: unattended trust is denied' \
  "$entry_replaced" \
  "$REPO_ROOT/runners/orchid-tick"
assert_entry_path_denied \
  "replaced-target service install" \
  'service installation refused: unattended trust is denied' \
  "$entry_replaced" \
  "$ORCHID_BIN" service install --dry-run
assert_entry_path_denied \
  "replaced-target direct libexec service install" \
  'service installation refused: unattended trust is denied' \
  "$entry_replaced" \
  "$REPO_ROOT/libexec/orchid-service" install --dry-run

unset ORCHID_TEST_ENTRY_SHIM_LOG
unset ORCHID_TEST_ENTRY_OLD_DEVICE ORCHID_TEST_ENTRY_OLD_INODE
unset ORCHID_TEST_ENTRY_OLD_ANCHOR_DEVICE ORCHID_TEST_ENTRY_OLD_ANCHOR_INODE
unset ORCHID_TEST_ENTRY_OLD_ROOT ORCHID_TEST_ENTRY_OLD_RECORD
unset ORCHID_TEST_ENTRY_OLD_ANCHOR ORCHID_TEST_ENTRY_COMMON
unset ORCHID_TEST_ENTRY_NEW_WITNESS ORCHID_TEST_ENTRY_REPO
unset ORCHID_TEST_ENTRY_NEW_HEAD
for entry_tool in readlink dirname pwd awk sort grep cat tr sed jq; do
  eval "unset ORCHID_TEST_REAL_${entry_tool}"
done

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
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_REPO="$reuse_repo" \
  ORCHID_TEST_REAL_STAT="$real_stat" \
  ORCHID_TEST_REUSED_COMMON="$reuse_common" \
  ORCHID_TEST_REUSED_IDENT="$reuse_device $reuse_inode" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_show "$ORCHID_TEST_REPO"
  '
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

# Git ordinarily trusts that the bytes found under a loose object's advertised
# OID path actually hash to that OID. Replace an acknowledged reachable commit
# with the compressed bytes of a different valid commit while leaving HEAD and
# every ref untouched: rev-list still reports the acknowledged root filename.
# Trust inspection must independently hash the exact locally-read commit
# payload, refuse the mismatch, avoid the configured promisor remote, and
# leave both repository and machine-local acknowledgement state unchanged.
loose_repo="$WORK/loose-commit-substitution-repo"
mk_repo "$loose_repo"
loose_advertised_oid="$(git -C "$loose_repo" rev-parse HEAD)"
trust_repo "$loose_repo" "before loose commit substitution"
loose_trusted_out="$(HOME="$home" "$ORCHID_BIN" trust show "$loose_repo")"
loose_record="$(printf '%s\n' "$loose_trusted_out" | sed -n 's/^record: //p')"
loose_anchor="$(printf '%s\n' "$loose_trusted_out" | sed -n 's/^identity_anchor: //p')"

loose_tree="$(git -C "$loose_repo" rev-parse "$loose_advertised_oid^{tree}")"
loose_actual_oid="$(
  printf 'different valid root commit payload\n' \
    | git -c commit.gpgSign=false -C "$loose_repo" commit-tree "$loose_tree"
)"
[ "$loose_actual_oid" != "$loose_advertised_oid" ] \
  || fail "loose-object substitution fixture must create different valid commit bytes"
loose_advertised_path="$loose_repo/.git/objects/${loose_advertised_oid:0:2}/${loose_advertised_oid:2}"
loose_actual_path="$loose_repo/.git/objects/${loose_actual_oid:0:2}/${loose_actual_oid:2}"
[ -f "$loose_advertised_path" ] && [ -f "$loose_actual_path" ] \
  || fail "loose-object substitution fixture requires both commits to be loose"
chmod u+w "$loose_advertised_path"
cp "$loose_actual_path" "$loose_advertised_path"

loose_recomputed_oid="$(
  set -o pipefail
  git -C "$loose_repo" cat-file commit "$loose_advertised_oid" \
    | git -C "$loose_repo" hash-object --no-filters -t commit --stdin
)"
assert_eq "$loose_actual_oid" "$loose_recomputed_oid" \
  "the acknowledged OID path now contains the different valid commit payload"
assert_eq "$loose_advertised_oid" \
  "$(git -c core.commitGraph=false -C "$loose_repo" \
      rev-list --max-parents=0 HEAD 2>/dev/null)" \
  "ordinary rev-list preserves the advertised acknowledged root after loose-object substitution"

loose_remote_contact="$WORK/loose-commit-remote-contact"
loose_remote_helper="$WORK/loose-commit-remote-helper"
cat > "$loose_remote_helper" <<EOF
#!/usr/bin/env bash
printf 'contacted\n' > "$loose_remote_contact"
exit 1
EOF
chmod +x "$loose_remote_helper"
git -C "$loose_repo" config core.repositoryformatversion 1
git -C "$loose_repo" config extensions.partialClone origin
git -C "$loose_repo" config remote.origin.promisor true
git -C "$loose_repo" config remote.origin.partialCloneFilter blob:none
git -C "$loose_repo" config remote.origin.url "ext::$loose_remote_helper"
git -C "$loose_repo" config protocol.ext.allow always

loose_object_before="$(cksum "$loose_advertised_path")"
loose_record_before="$(cksum "$loose_record")"
loose_anchor_before="$(cksum "$loose_anchor")"
loose_refs_before="$(
  git -C "$loose_repo" for-each-ref --format='%(refname) %(objectname)' \
    | LC_ALL=C sort
)"
loose_git_files_before="$(
  find "$loose_repo/.git" -type f -print | LC_ALL=C sort
)"

out="$(HOME="$home" "$ORCHID_BIN" trust show "$loose_repo")"; rc=$?
assert_eq 0 "$rc" \
  "trust show reports loose commit substitution without turning inspection into an effectful failure"
assert_match '^unattended trust: untrusted$' "$out" \
  "different bytes stored under an acknowledged commit OID never preserve trust"
assert_match '^binding_state: unavailable$' "$out" \
  "a commit object integrity failure makes the trust binding unavailable"
assert_match '^root_commit: unavailable$' "$out" \
  "an unverified advertised OID is never surfaced or recorded as the trust root"
assert_match "commit object integrity mismatch: advertised OID $loose_advertised_oid hashes to $loose_actual_oid" "$out" \
  "loose commit substitution has an actionable advertised-versus-actual diagnostic"

loose_ack_error="$WORK/loose-commit-reacknowledge-error"
rc=0
HOME="$home" "$ORCHID_BIN" trust unattended "$loose_repo" \
  --reason "must not record an unverified root" \
  >"$loose_ack_error" 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "acknowledgement must refuse a commit whose bytes do not match its advertised OID"
assert_match 'commit object integrity mismatch' "$(cat "$loose_ack_error")" \
  "refused acknowledgement repeats the commit-integrity repair diagnostic"

[ ! -e "$loose_remote_contact" ] \
  || fail "commit integrity inspection must never contact a configured promisor remote"
assert_eq "$loose_object_before" "$(cksum "$loose_advertised_path")" \
  "commit integrity inspection leaves the substituted object byte-identical"
assert_eq "$loose_record_before" "$(cksum "$loose_record")" \
  "commit integrity inspection leaves the existing acknowledgement byte-identical"
assert_eq "$loose_anchor_before" "$(cksum "$loose_anchor")" \
  "commit integrity inspection leaves the incarnation anchor byte-identical"
assert_eq "$loose_refs_before" \
  "$(git -C "$loose_repo" for-each-ref --format='%(refname) %(objectname)' \
      | LC_ALL=C sort)" \
  "commit integrity inspection leaves every repository ref unchanged"
assert_eq "$loose_git_files_before" \
  "$(find "$loose_repo/.git" -type f -print | LC_ALL=C sort)" \
  "commit integrity inspection creates no persistent target-repository file"

# The same exact-payload verification must use the repository's storage hash,
# not assume forty-character SHA-1 object IDs.
sha256_repo="$WORK/sha256-trust-repo"
git init -q --object-format=sha256 "$sha256_repo"
git -C "$sha256_repo" commit -q --allow-empty -m root
sha256_root="$(git -C "$sha256_repo" rev-parse HEAD)"
assert_eq 64 "${#sha256_root}" \
  "SHA-256 trust fixture uses the repository's sixty-four-character OIDs"
trust_repo "$sha256_repo" "SHA-256 repository fixture"
git -C "$sha256_repo" commit -q --allow-empty -m descendant
out="$(HOME="$home" "$ORCHID_BIN" trust show "$sha256_repo")"
assert_match '^unattended trust: trusted$' "$out" \
  "verified SHA-256 commit history remains eligible for unattended trust"
assert_match "^root_commit: $sha256_root$" "$out" \
  "SHA-256 root derivation preserves the verified repository root"

# A trusted inspection must not amplify Git process count with history length
# or repeat the full parent walk during its final identity recheck. Count
# commands deterministically around a history large enough to distinguish one
# batch from the former per-commit cat-file/hash-object pipelines; do not use a
# wall-clock assertion, which would be host-load dependent.
batch_repo="$WORK/batched-commit-verification-repo"
mk_repo "$batch_repo"
batch_n=0
while [ "$batch_n" -lt 32 ]; do
  batch_n=$((batch_n + 1))
  git -C "$batch_repo" commit -q --allow-empty -m "batch fixture $batch_n"
done
trust_repo "$batch_repo" "batched commit verification fixture"

batch_git_bin="$WORK/batched-commit-verification-bin"
batch_git_log="$WORK/batched-commit-verification.log"
batch_real_git="$(command -v git)"
mkdir -p "$batch_git_bin"
cat > "$batch_git_bin/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    rev-list|cat-file|hash-object)
      printf '%s\n' "$arg" >> "$ORCHID_TEST_BATCH_GIT_LOG"
      break
      ;;
  esac
done
exec "$ORCHID_TEST_BATCH_REAL_GIT" "$@"
EOF
chmod +x "$batch_git_bin/git"
: > "$batch_git_log"
out="$(
  HOME="$home" PATH="$batch_git_bin:$PATH" \
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_BATCH_REPO="$batch_repo" \
  ORCHID_TEST_BATCH_GIT_LOG="$batch_git_log" \
  ORCHID_TEST_BATCH_REAL_GIT="$batch_real_git" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_show "$ORCHID_TEST_BATCH_REPO"
  '
)"
assert_match '^unattended trust: trusted$' "$out" \
  "batched exact-payload verification preserves a trusted history"
batch_walks="$(grep -c '^rev-list$' "$batch_git_log" || true)"
batch_reads="$(grep -c '^cat-file$' "$batch_git_log" || true)"
batch_hashes="$(grep -c '^hash-object$' "$batch_git_log" || true)"
assert_eq 1 "$batch_walks" \
  "one trusted inspection performs exactly one complete parent walk"
assert_eq 1 "$batch_reads" \
  "one sub-limit history uses one batched cat-file process"
assert_eq 1 "$batch_hashes" \
  "one sub-limit history uses one batched hash-object process"

# The same counters are the evidence that a repeat gate re-reads and re-hashes
# rather than reusing anything: a second inspection of an unchanged repository
# doubles every count instead of leaving it where the first one stopped.
out="$(
  HOME="$home" PATH="$batch_git_bin:$PATH" \
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_BATCH_REPO="$batch_repo" \
  ORCHID_TEST_BATCH_GIT_LOG="$batch_git_log" \
  ORCHID_TEST_BATCH_REAL_GIT="$batch_real_git" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_show "$ORCHID_TEST_BATCH_REPO"
  '
)"
assert_match '^unattended trust: trusted$' "$out" \
  "the repeated inspection of the unchanged repository stays trusted"
assert_match '^root_verification: walked$' "$out" \
  "the repeated inspection reports its own walk"
assert_eq 2 "$(grep -c '^rev-list$' "$batch_git_log" || true)" \
  "a second gate performs its own complete parent walk"
assert_eq 2 "$(grep -c '^cat-file$' "$batch_git_log" || true)" \
  "a second gate re-reads every reachable commit payload"
assert_eq 2 "$(grep -c '^hash-object$' "$batch_git_log" || true)" \
  "a second gate re-hashes every reachable commit payload"

# Commit-graph parent edges are repository-controlled acceleration metadata,
# not the underlying commit history. Forge a graph in which a real replacement
# root falsely names the acknowledged root as its parent. Ordinary Git accepts
# that edge without comparing it with the commit object and therefore reports
# the old root; trust inspection must disable the graph at command-line config
# scope even when repository config explicitly enables it.
graph_repo="$WORK/commit-graph-repo"
mk_repo "$graph_repo"
graph_old_root="$(git -C "$graph_repo" rev-parse HEAD)"
trust_repo "$graph_repo" "history before commit-graph forgery"
git -C "$graph_repo" checkout -q --orphan replacement-history
git -C "$graph_repo" commit -q --allow-empty -m replacement-history
graph_new_root="$(git -C "$graph_repo" rev-parse HEAD)"
[ "$graph_old_root" != "$graph_new_root" ] \
  || fail "commit-graph fixture must produce a different root commit"

printf '%s\n%s\n' "$graph_old_root" "$graph_new_root" \
  | git -c core.commitGraph=true -C "$graph_repo" \
      commit-graph write --stdin-commits --no-progress
graph_file="$graph_repo/.git/objects/info/commit-graph"
[ -f "$graph_file" ] || fail "commit-graph fixture must write an acceleration file"
chmod u+w "$graph_file"

graph_hash_version="$(od -An -t u1 -j 5 -N 1 "$graph_file" | tr -d ' ')"
case "$graph_hash_version" in
  1) graph_hash_len=20; graph_hash_bits=1 ;;
  2) graph_hash_len=32; graph_hash_bits=256 ;;
  *) fail "commit-graph fixture found an unsupported hash version"; graph_hash_len=20; graph_hash_bits=1 ;;
esac
graph_chunk_count="$(od -An -t u1 -j 6 -N 1 "$graph_file" | tr -d ' ')"
graph_chunk_index=0
graph_cdat_offset=
while [ "$graph_chunk_index" -lt "$graph_chunk_count" ]; do
  graph_lookup_offset=$((8 + graph_chunk_index * 12))
  graph_chunk_id="$(
    od -An -t x1 -j "$graph_lookup_offset" -N 4 "$graph_file" \
      | tr -d ' \n'
  )"
  if [ "$graph_chunk_id" = 43444154 ]; then
    set -- $(od -An -t u1 -j $((graph_lookup_offset + 4)) -N 8 "$graph_file")
    graph_cdat_offset=$(( $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 ))
    break
  fi
  graph_chunk_index=$((graph_chunk_index + 1))
done
[ -n "$graph_cdat_offset" ] \
  || fail "commit-graph fixture must locate the commit-data chunk"

graph_first_oid="$(
  printf '%s\n%s\n' "$graph_old_root" "$graph_new_root" \
    | LC_ALL=C sort | sed -n '1p'
)"
if [ "$graph_first_oid" = "$graph_new_root" ]; then
  graph_new_position=0
  graph_old_position=1
else
  graph_new_position=1
  graph_old_position=0
fi
graph_parent_offset=$((
  graph_cdat_offset
  + graph_new_position * (graph_hash_len + 16)
  + graph_hash_len
))
if [ "$graph_old_position" -eq 0 ]; then
  graph_parent_bytes='\000\000\000\000'
else
  graph_parent_bytes='\000\000\000\001'
fi
printf '%b' "$graph_parent_bytes" \
  | dd of="$graph_file" bs=1 seek="$graph_parent_offset" conv=notrunc 2>/dev/null

# Recompute the format checksum so this is a deliberately forged graph, not
# merely a file with a stale trailer. The project already supports shasum with
# an openssl fallback for its machine-local content digests.
graph_size="$(wc -c < "$graph_file" | tr -d ' ')"
graph_body_size=$((graph_size - graph_hash_len))
graph_body="$WORK/forged-commit-graph.body"
graph_checksum="$WORK/forged-commit-graph.checksum"
dd if="$graph_file" of="$graph_body" bs=1 count="$graph_body_size" 2>/dev/null
if command -v shasum >/dev/null 2>&1; then
  graph_digest="$(shasum -a "$graph_hash_bits" "$graph_body" | awk '{print $1}')"
else
  graph_digest="$(
    openssl dgst "-sha$graph_hash_bits" "$graph_body" | awk '{print $NF}'
  )"
fi
: > "$graph_checksum"
graph_digest_index=0
while [ "$graph_digest_index" -lt "${#graph_digest}" ]; do
  printf '%b' "\\x${graph_digest:$graph_digest_index:2}" >> "$graph_checksum"
  graph_digest_index=$((graph_digest_index + 2))
done
cp "$graph_body" "$graph_file"
cat "$graph_checksum" >> "$graph_file"
assert_eq "$graph_size" "$(wc -c < "$graph_file" | tr -d ' ')" \
  "forged commit-graph retains a complete checksum trailer"

git -C "$graph_repo" config core.commitGraph true
assert_eq "$graph_old_root" \
  "$(git -C "$graph_repo" rev-list --max-parents=0 HEAD 2>/dev/null)" \
  "forged commit-graph fixture must disguise the real replacement root"
assert_eq "$graph_new_root" \
  "$(git -c core.commitGraph=false -C "$graph_repo" \
      rev-list --max-parents=0 HEAD 2>/dev/null)" \
  "disabling commit-graph metadata must recover the underlying root"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$graph_repo")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a forged commit-graph cannot preserve trust across root replacement"
assert_match "^root_commit: $graph_new_root$" "$out" \
  "trust root derivation ignores forged commit-graph parent edges"
assert_match 'repository root commit changed' "$out" \
  "commit-graph forgery leaves an actionable root-history mismatch"

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
assert_match '^binding_state: untrusted$' "$out" \
  "a failed shallow acknowledgement leaves no eligible trust record"
assert_match '^root_commit: pending$' "$out" \
  "ordinary no-record inspection never re-walks the shallow history"
[ -f "$shallow_repo/.git/shallow" ] \
  || fail "trust inspection must not deepen or rewrite a shallow repository"

# Git before 2.45 ignores GIT_NO_LAZY_FETCH during client-side object access.
# Model that supported-range edge with a wrapper that advertises 2.44 and
# would explicitly drop the variable at any object walk. The repository is
# acknowledged while complete, then marked partial/promisor; its root object
# is removed and its remote becomes an executable contact trap. Candidate
# verification must reject the Git version before any target-repository Git
# command, so neither the walk nor the remote can run.
promisor_repo="$WORK/promisor-old-git"
mk_repo "$promisor_repo"
promisor_root="$(git -C "$promisor_repo" rev-parse HEAD)"
git -C "$promisor_repo" commit -q --allow-empty -m descendant
trust_repo "$promisor_repo" "old-Git local-only boundary fixture"
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
if [ "$#" -eq 3 ] && [ "$1" = -c ] \
   && [ "$2" = core.commitGraph=false ] && [ "$3" = --version ]; then
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
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_REPO="$promisor_repo" \
  ORCHID_TEST_REAL_GIT="$real_git" \
  ORCHID_TEST_PROMISOR_CONTACT="$promisor_contact" \
  ORCHID_TEST_OBJECT_WALK="$promisor_walk" \
  ORCHID_TEST_TARGET_GIT="$promisor_target_git" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_show "$ORCHID_TEST_REPO"
  '
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
promisor_record="$(printf '%s\n' "$out" | sed -n 's/^record: //p')"
promisor_anchor="$(printf '%s\n' "$out" | sed -n 's/^identity_anchor: //p')"
[ -f "$promisor_record" ] \
  || fail "old-Git refusal must leave the identity-keyed record on disk to revoke"
[ -f "$promisor_anchor" ] \
  || fail "old-Git refusal must leave the machine-local anchor on disk to revoke"

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

# ---------------------------------------------------------------------------
# Revocation may never inherit inspection's preconditions. Inspection fails
# closed on an unsupported Git, a mismatched binding, a shallow boundary, a
# missing object, or a corrupt history — and in every one of those states an
# operator must still be able to take the acknowledgement away. Otherwise the
# identity-keyed record survives on disk and authorizes unattended execution
# again the moment the repository becomes inspectable.
# ---------------------------------------------------------------------------

# Ordinary revocation is bounded: it derives the identity-keyed record from
# on-disk markers alone. No Git command and no scratch file, so its cost
# cannot scale with repository history.
revoke_guard_repo="$WORK/revoke-bounded-repo"
mk_repo "$revoke_guard_repo"
git -C "$revoke_guard_repo" commit -q --allow-empty -m descendant
trust_repo "$revoke_guard_repo" "bounded revocation fixture"
revoke_guard_out="$(HOME="$home" "$ORCHID_BIN" trust show "$revoke_guard_repo")"
revoke_guard_record="$(printf '%s\n' "$revoke_guard_out" | sed -n 's/^record: //p')"
revoke_guard_anchor="$(
  printf '%s\n' "$revoke_guard_out" | sed -n 's/^identity_anchor: //p'
)"
revoke_guard_witness="$(
  printf '%s\n' "$revoke_guard_out" | sed -n 's/^identity_witness: //p'
)"
# An unrelated acknowledgement must survive; revocation acts on one identity.
bystander_repo="$WORK/revoke-bystander-repo"
mk_repo "$bystander_repo"
trust_repo "$bystander_repo" "unrelated acknowledgement"
bystander_record="$(
  HOME="$home" "$ORCHID_BIN" trust show "$bystander_repo" | sed -n 's/^record: //p'
)"
: > "$fast_guard_log"
revoke_guard_result="$(
  HOME="$home" PATH="$fast_guard_bin:$PATH" \
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_FAST_GUARD_LOG="$fast_guard_log" \
  ORCHID_TEST_FAST_GUARD_REAL_GIT="$fast_guard_real_git" \
  ORCHID_TEST_FAST_GUARD_REAL_MKTEMP="$fast_guard_real_mktemp" \
  ORCHID_TEST_FAST_GUARD_REPO="$revoke_guard_repo" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_revoke "$ORCHID_TEST_FAST_GUARD_REPO"
    printf "revoked: %s\n" "$ORCHID_UNATTENDED_REPO"
  '
)"
assert_match "^revoked: " "$revoke_guard_result" \
  "revocation resolves the repository identity it acted on"
[ ! -s "$fast_guard_log" ] \
  || fail "ordinary revocation invoked Git or mktemp ($(tr '\n' ' ' < "$fast_guard_log"))"
[ ! -e "$revoke_guard_record" ] \
  || fail "bounded revocation must remove the identity-keyed record"
[ ! -e "$revoke_guard_anchor" ] \
  || fail "bounded revocation must remove the machine-local identity anchor"
[ -f "$revoke_guard_witness" ] \
  || fail "bounded revocation must leave Git's own common-directory witness"
[ -f "$bystander_record" ] \
  || fail "revocation must not remove another repository's acknowledgement"

# Unsupported Git. The old-Git fixture above still holds a record; removal
# must not require the version check that inspection fails, and must not run
# any target-repository Git command to get there.
revoke_out="$(
  HOME="$home" PATH="$old_git_bin:$PATH" \
  ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_REPO="$promisor_repo" \
  ORCHID_TEST_REAL_GIT="$real_git" \
  ORCHID_TEST_PROMISOR_CONTACT="$promisor_contact" \
  ORCHID_TEST_OBJECT_WALK="$promisor_walk" \
  ORCHID_TEST_TARGET_GIT="$promisor_target_git" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_revoke "$ORCHID_TEST_REPO"
    printf "revoked: %s\n" "$ORCHID_UNATTENDED_REPO"
  '
)"; rc=$?
assert_eq 0 "$rc" "revocation succeeds on a Git too old to inspect the target"
assert_match '^revoked: ' "$revoke_out" "old-Git revocation names the target"
[ ! -e "$promisor_record" ] \
  || fail "an unsupported Git must not strand the acknowledgement record on disk"
[ ! -e "$promisor_anchor" ] \
  || fail "an unsupported Git must not strand the machine-local anchor on disk"
[ ! -e "$promisor_target_git" ] \
  || fail "revocation must not issue a target-repository Git query"
[ ! -e "$promisor_walk" ] \
  || fail "revocation must not walk history objects"
[ ! -e "$promisor_contact" ] \
  || fail "revocation must never contact a promisor remote"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$promisor_repo")"
assert_match '^binding_state: untrusted$' "$out" \
  "a revoked record cannot become active again once Git can inspect the repo"
assert_match '^root_commit: pending$' "$out" \
  "the revoked repository falls back to the constant-size no-record denial"

# A binding mismatch is inspectable but denied; revocation still applies.
jq '.policy_version = 0 | .reason = "revocable policy mismatch"' \
  "$policy_record" | atomic_write "$policy_record"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$policy_repo")"
assert_match '^binding_state: mismatch$' "$out" \
  "policy-version mismatch fixture is a denied but readable binding"
policy_anchor="$(printf '%s\n' "$out" | sed -n 's/^identity_anchor: //p')"
out="$(HOME="$home" "$ORCHID_BIN" trust revoke "$policy_repo")"; rc=$?
assert_eq 0 "$rc" "revocation succeeds for a mismatched binding"
assert_match '^unattended trust revoked:' "$out" "mismatch revocation confirms removal"
[ ! -e "$policy_record" ] || fail "mismatch revocation must remove the record"
[ ! -e "$policy_anchor" ] || fail "mismatch revocation must remove the anchor"

# Repositories whose history Orchid cannot verify: a shallow boundary hiding
# absent ancestry, an outright missing root object, and a corrupt commit
# object. Each denies inspection; each must still be revocable by the
# operator, using the same identity derivation.
assert_revocable_while_uninspectable() {
  local label="$1" target="$2" record anchor witness show_out revoke_out rc=0
  show_out="$(HOME="$home" "$ORCHID_BIN" trust show "$target")"
  assert_match '^unattended trust: untrusted$' "$show_out" \
    "$label is denied while its history cannot be verified"
  record="$(printf '%s\n' "$show_out" | sed -n 's/^record: //p')"
  anchor="$(printf '%s\n' "$show_out" | sed -n 's/^identity_anchor: //p')"
  witness="$(printf '%s\n' "$show_out" | sed -n 's/^identity_witness: //p')"
  [ -f "$record" ] || fail "$label must still hold an identity-keyed record"
  [ -f "$anchor" ] || fail "$label must still hold a machine-local anchor"
  revoke_out="$(HOME="$home" "$ORCHID_BIN" trust revoke "$target")" || rc=$?
  assert_eq 0 "$rc" "$label remains revocable"
  assert_match '^unattended trust revoked:' "$revoke_out" \
    "$label revocation confirms removal"
  [ ! -e "$record" ] || fail "$label revocation must remove the record"
  [ ! -e "$anchor" ] || fail "$label revocation must remove the anchor"
  [ -f "$witness" ] || fail "$label revocation must leave Git's witness intact"
}

shallow_revoke_repo="$WORK/shallow-revoke-repo"
mk_repo "$shallow_revoke_repo"
shallow_revoke_root="$(git -C "$shallow_revoke_repo" rev-parse HEAD)"
git -C "$shallow_revoke_repo" commit -q --allow-empty -m descendant
shallow_revoke_tip="$(git -C "$shallow_revoke_repo" rev-parse HEAD)"
trust_repo "$shallow_revoke_repo" "acknowledged while history was complete"
printf '%s\n' "$shallow_revoke_tip" > "$shallow_revoke_repo/.git/shallow"
rm -f "$shallow_revoke_repo/.git/objects/${shallow_revoke_root:0:2}/${shallow_revoke_root:2}"
assert_eq "$shallow_revoke_tip" \
  "$(git -C "$shallow_revoke_repo" rev-list --max-parents=0 HEAD 2>/dev/null)" \
  "shallow fixture must hide its absent ancestry from an ordinary Git query"
assert_revocable_while_uninspectable "a shallow repository" "$shallow_revoke_repo"

missing_object_repo="$WORK/missing-object-revoke-repo"
mk_repo "$missing_object_repo"
missing_object_root="$(git -C "$missing_object_repo" rev-parse HEAD)"
git -C "$missing_object_repo" commit -q --allow-empty -m descendant
trust_repo "$missing_object_repo" "acknowledged before the object went missing"
rm -f "$missing_object_repo/.git/objects/${missing_object_root:0:2}/${missing_object_root:2}"
assert_revocable_while_uninspectable \
  "a repository missing a reachable object" "$missing_object_repo"

corrupt_history_repo="$WORK/corrupt-history-revoke-repo"
mk_repo "$corrupt_history_repo"
git -C "$corrupt_history_repo" commit -q --allow-empty -m descendant
corrupt_history_tip="$(git -C "$corrupt_history_repo" rev-parse HEAD)"
trust_repo "$corrupt_history_repo" "acknowledged before the corruption"
corrupt_history_object="$corrupt_history_repo/.git/objects/${corrupt_history_tip:0:2}/${corrupt_history_tip:2}"
[ -f "$corrupt_history_object" ] \
  || fail "corrupt-history fixture must start from a loose commit object"
# Git writes loose objects read-only (0444), so the replacement bytes cannot be
# redirected over the existing file -- that is a Permission denied, not a
# corruption. Unlink the directory entry first, then create a fresh file at the
# same path: the object is still present, but its payload is no longer a valid
# Git object. This is deliberately distinct from the missing-object fixture
# above, which removes the entry and leaves nothing behind.
rm -f "$corrupt_history_object"
printf 'not a git object payload\n' > "$corrupt_history_object"
[ -s "$corrupt_history_object" ] \
  || fail "corrupt-history fixture must leave a non-empty object file in place"
if git -C "$corrupt_history_repo" cat-file -p "$corrupt_history_tip" >/dev/null 2>&1; then
  fail "corrupt-history fixture must leave the tip commit unreadable"
fi
assert_revocable_while_uninspectable \
  "a repository with a corrupt commit object" "$corrupt_history_repo"

# Removal still refuses when no identity can be derived safely: without a
# validated worktree marker there is no applicable record to name.
not_a_repo="$WORK/revoke-not-a-repo"
mkdir -p "$not_a_repo"
rc=0
revoke_out="$(HOME="$home" "$ORCHID_BIN" trust revoke "$not_a_repo" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "revocation must refuse a target with no derivable identity"
assert_match 'cannot revoke unattended trust' "$revoke_out" \
  "an underivable revocation target is named"
[ -f "$bystander_record" ] \
  || fail "a refused revocation must not remove any other record"

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

# ---------------------------------------------------------------------------
# Every gate re-verifies from scratch. Nothing records that a repository was
# already verified, so no later gate can inherit an earlier gate's answer.
# ---------------------------------------------------------------------------
reverify_repo="$WORK/repeat-gate-repo"
mk_repo "$reverify_repo"
reverify_root="$(git -C "$reverify_repo" rev-list --max-parents=0 HEAD)"
trust_repo "$reverify_repo" "repeat gate re-verification fixture"

out="$(HOME="$home" "$ORCHID_BIN" trust show "$reverify_repo")"
assert_match '^unattended trust: trusted$' "$out" "the repeat-gate fixture starts trusted"
assert_match '^root_verification: walked$' "$out" \
  "the first gate after acknowledgement derives the root from its own walk"
assert_match "^root_commit: $reverify_root\$" "$out" \
  "the walked derivation reports the acknowledged root"
reverify_record="$(printf '%s\n' "$out" | sed -n 's/^record: //p')"
reverify_anchor="$(printf '%s\n' "$out" | sed -n 's/^identity_anchor: //p')"

out="$(HOME="$home" "$ORCHID_BIN" trust show "$reverify_repo")"
assert_match '^unattended trust: trusted$' "$out" "a repeat gate stays trusted"
assert_match '^root_verification: walked$' "$out" \
  "a repeat gate walks again instead of reusing the previous verification"

# The machine-local store holds exactly the record and its anchor for this
# identity. Any additional per-identity file would be state a later gate could
# consult in place of walking.
# Depth-1 listing by shell globbing, not a find(1) depth primary: those are
# non-POSIX and ci-local.sh rejects them repo-wide. Anchoring the glob on the
# record's own path prefix is the filter, so no `case` is needed inside the
# substitution -- Bash 3.2 mis-scans one there, letting a quoted pattern's
# `)` close the substitution early. `*` never crosses a `/`, nullglob turns
# "no such entry" into an empty list rather than the literal pattern, and the
# loop keeps that empty case from printing the blank line a bare
# `printf '%s\n' glob` would.
reverify_key="${reverify_record%.json}"
reverify_state="$(
  shopt -s nullglob
  for reverify_entry in "$reverify_key".*; do
    printf '%s\n' "$reverify_entry"
  done | LC_ALL=C sort
)"
assert_eq "$(printf '%s\n%s\n' "$reverify_anchor" "$reverify_record" | LC_ALL=C sort)" \
  "$reverify_state" \
  "an identity's machine-local state is exactly its record and its anchor"
[ -z "$(git -C "$reverify_repo" status --porcelain)" ] \
  || fail "repeated gates must not write anything into the target repository"

# The substitution a derivation cache keyed on identity plus HEAD would mask:
# different bytes stored under an acknowledged reachable commit's advertised
# OID, applied AFTER a successful gate, leaving HEAD, every ref, the common
# directory, and the incarnation anchor untouched. Exact-payload verification
# must refuse on the next gate and on every gate after it.
warm_repo="$WORK/warm-substitution-repo"
mk_repo "$warm_repo"
warm_advertised="$(git -C "$warm_repo" rev-parse HEAD)"
trust_repo "$warm_repo" "before warm same-OID substitution"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$warm_repo")"
assert_match '^unattended trust: trusted$' "$out" \
  "the same-OID substitution fixture is verified and trusted before its objects are edited"
warm_head_before="$(git -C "$warm_repo" rev-parse HEAD)"
warm_refs_before="$(
  git -C "$warm_repo" for-each-ref --format='%(refname) %(objectname)' \
    | LC_ALL=C sort
)"

warm_tree="$(git -C "$warm_repo" rev-parse "$warm_advertised^{tree}")"
warm_actual="$(
  printf 'payload substituted after a successful gate\n' \
    | git -c commit.gpgSign=false -C "$warm_repo" commit-tree "$warm_tree"
)"
[ "$warm_actual" != "$warm_advertised" ] \
  || fail "the warm substitution fixture must create different valid commit bytes"
warm_advertised_path="$warm_repo/.git/objects/${warm_advertised:0:2}/${warm_advertised:2}"
warm_actual_path="$warm_repo/.git/objects/${warm_actual:0:2}/${warm_actual:2}"
[ -f "$warm_advertised_path" ] && [ -f "$warm_actual_path" ] \
  || fail "the warm substitution fixture requires both commits to be loose"
chmod u+w "$warm_advertised_path"
cp "$warm_actual_path" "$warm_advertised_path"

assert_eq "$warm_head_before" "$(git -C "$warm_repo" rev-parse HEAD)" \
  "the substitution leaves HEAD at the same object ID"
assert_eq "$warm_refs_before" \
  "$(git -C "$warm_repo" for-each-ref --format='%(refname) %(objectname)' \
      | LC_ALL=C sort)" \
  "the substitution leaves every ref unchanged"

warm_gate=0
while [ "$warm_gate" -lt 2 ]; do
  warm_gate=$((warm_gate + 1))
  out="$(HOME="$home" "$ORCHID_BIN" trust show "$warm_repo")"
  assert_match '^unattended trust: untrusted$' "$out" \
    "gate $warm_gate after a same-OID substitution refuses despite an unchanged HEAD"
  assert_match "commit object integrity mismatch: advertised OID $warm_advertised hashes to $warm_actual" \
    "$out" \
    "gate $warm_gate names the advertised-versus-actual object mismatch"
  assert_match '^root_verification: none$' "$out" \
    "gate $warm_gate reports no verified root derivation"
done

# A replaced root history is the identity substitution the binding exists to
# catch, and it must be caught on an already-acknowledged repository too.
orphan_repo="$WORK/root-replacement-repo"
mk_repo "$orphan_repo"
trust_repo "$orphan_repo" "root replacement fixture"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$orphan_repo")"
assert_match '^unattended trust: trusted$' "$out" \
  "the replacement fixture starts trusted"
git -C "$orphan_repo" checkout -q --orphan replacement
git -C "$orphan_repo" commit -q --allow-empty -m "replacement root"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$orphan_repo")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a replaced root history is untrusted on the next gate"
assert_match '^binding_state: mismatch$' "$out" \
  "the replacement root is reported as a binding mismatch"
assert_match '^root_verification: walked$' "$out" \
  "the replacement was detected by this gate's own walk"

# Revocation removes this identity's machine-local state.
orphan_record="$(printf '%s\n' "$out" | sed -n 's/^record: //p')"
orphan_anchor="$(printf '%s\n' "$out" | sed -n 's/^identity_anchor: //p')"
HOME="$home" "$ORCHID_BIN" trust revoke "$orphan_repo" >/dev/null \
  || fail "revoking the replacement fixture must succeed"
[ ! -e "$orphan_record" ] && [ ! -e "$orphan_anchor" ] \
  || fail "revocation must remove the machine-local record and anchor"

# ---------------------------------------------------------------------------
# jq is one of the kernel's three binaries and the only reader of the record.
# Without it every parse fails, which must read as a missing tool rather than
# as a malformed operator-authored file. Build a PATH that is the current one
# with jq removed -- a symlink farm, so by construction nothing ELSE can go
# missing and confuse the result -- and drive the library directly, the same
# way the fast-denial guard above does.
# ---------------------------------------------------------------------------
nojq_bin="$WORK/no-jq-bin"
mkdir -p "$nojq_bin"
(
  IFS=:
  for nojq_dir in $PATH; do
    [ -n "$nojq_dir" ] && [ -d "$nojq_dir" ] || continue
    for nojq_exe in "$nojq_dir"/*; do
      [ -f "$nojq_exe" ] && [ -x "$nojq_exe" ] || continue
      nojq_name="${nojq_exe##*/}"
      if [ "$nojq_name" != jq ] && [ ! -e "$nojq_bin/$nojq_name" ]; then
        ln -s "$nojq_exe" "$nojq_bin/$nojq_name"
      fi
    done
  done
)
[ -x "$nojq_bin/git" ] || fail "jq-absence fixture must still provide git"
[ -x "$nojq_bin/stat" ] || fail "jq-absence fixture must still provide stat"
# Check in a subshell with the lookup hash dropped: a temporary PATH
# assignment alone can still be answered from this shell's command hash.
if ( PATH="$nojq_bin"; hash -r 2>/dev/null; command -v jq >/dev/null 2>&1 ); then
  fail "jq-absence fixture must not leave jq resolvable"
fi

nojq_repo="$WORK/no-jq-repo"
mk_repo "$nojq_repo"
trust_repo "$nojq_repo" "jq availability fixture"
nojq_out="$(
  HOME="$home" PATH="$nojq_bin" ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_NOJQ_REPO="$nojq_repo" \
  /bin/bash -c '
    set -euo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_show "$ORCHID_TEST_NOJQ_REPO"
  '
)"
assert_match '^unattended trust: untrusted$' "$nojq_out" \
  "a missing jq fails the unattended gate closed"
assert_match '^gate: denied$' "$nojq_out" "a missing jq denies the gate"
assert_match '^binding_state: unavailable$' "$nojq_out" \
  "a missing jq is an unavailable boundary, not an invalid record"
assert_match '^why: jq is required' "$nojq_out" \
  "a missing jq is reported as a missing tool, not as a malformed record"
assert_match 'install jq' "$nojq_out" \
  "the missing-jq diagnostic tells the operator what to do about it"
[ -f "$nojq_repo/.git/description" ] \
  || fail "the jq-absence path must leave the repository untouched"

# The same applies when authoring a record: refuse with a diagnostic naming
# the tool instead of writing something unreadable.
nojq_ack_repo="$WORK/no-jq-ack-repo"
mk_repo "$nojq_ack_repo"
rc=0
nojq_ack_out="$(
  HOME="$home" PATH="$nojq_bin" ORCHID_ROOT="$REPO_ROOT" \
  ORCHID_TEST_NOJQ_REPO="$nojq_ack_repo" \
  /bin/bash -c '
    set -uo pipefail
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_trust_acknowledge "$ORCHID_TEST_NOJQ_REPO" "jq must be present"
  ' 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail "acknowledgement must refuse when jq is unavailable"
assert_match 'requires jq' "$nojq_ack_out" \
  "a jq-less acknowledgement names the missing tool"
out="$(HOME="$home" "$ORCHID_BIN" trust show "$nojq_ack_repo")"
assert_match '^unattended trust: untrusted$' "$out" \
  "a refused jq-less acknowledgement leaves the repository untrusted"

# ---------------------------------------------------------------------------
# The gate resolves kernel tools on the fixed PATH every entry point pins, not
# on the operator's PATH. A reporting surface that asks the other question
# contradicts the gate: doctor probed jq after restoring the operator PATH, so
# a jq in ~/.local/bin (or nix/asdf/cargo) made it print `ok jq` about a jq no
# scheduled run can reach. Probe both directions through the library, then
# check the surface. The remedy must not be "re-run orchid service install" --
# the runners overwrite PATH unconditionally, so the scheduler's PATH is never
# consulted and reinstalling the service cannot change the answer.
# ---------------------------------------------------------------------------
probe_tool_state() {
  # $1: the PATH the library is loaded under (what an unattended run pins).
  # $2: the operator PATH lib/common.sh holds inert until a verb restores it.
  PATH="$1" ORCHID_ROOT="$REPO_ROOT" ORCHID_TEST_OPERATOR_PATH="$2" \
  /bin/bash -c '
    set -uo pipefail
    __orchid_entry_context=1
    __orchid_entry_path_was_set=x
    __orchid_entry_operator_path="$ORCHID_TEST_OPERATOR_PATH"
    __orchid_entry_defer_restore=1
    export __orchid_entry_context __orchid_entry_path_was_set
    export __orchid_entry_operator_path
    source "$ORCHID_ROOT/lib/common.sh"
    source "$ORCHID_ROOT/lib/trust.sh"
    unattended_tool_probe jq || true
    printf "%s\n%s\n" "$ORCHID_UNATTENDED_TOOL_STATE" \
      "$ORCHID_UNATTENDED_TOOL_DETAIL"
  '
}

probe_both="$(probe_tool_state "$PATH" "$PATH")"
assert_match '^both$' "$probe_both" \
  "a jq on both PATHs is reported as ready on both"

probe_interactive="$(probe_tool_state "$nojq_bin" "$PATH")"
assert_match '^interactive-only$' "$probe_interactive" \
  "a jq the operator PATH can reach but an unattended run cannot is not simply 'ok'"
assert_match 'not on the fixed PATH unattended runs pin' "$probe_interactive" \
  "the discrepancy is reported explicitly, naming the PATH that is short"
assert_match 'install jq into one of the directories on that fixed PATH' \
  "$probe_interactive" "the remedy is the one that actually works"
assert_match 'orchid service install. cannot help' "$probe_interactive" \
  "the remedy corrects the reinstall-the-service guess that cannot help"

probe_unattended="$(probe_tool_state "$PATH" "$nojq_bin")"
assert_match '^unattended-only$' "$probe_unattended" \
  "a jq only an unattended run can reach is reported as missing interactively"

probe_neither="$(probe_tool_state "$nojq_bin" "$nojq_bin")"
assert_match '^neither$' "$probe_neither" \
  "a jq on no PATH at all is still reported as missing"
assert_match 'install jq into one of the directories on that fixed PATH' \
  "$probe_neither" "an entirely missing jq names the same remedy"

# The gate itself must answer from the same PATH, so its refusal and the
# surfaces above cannot disagree about the same machine.
nojq_gate_detail="$(printf '%s\n' "$nojq_out" | sed -n 's/^why: //p')"
assert_match 'fixed PATH unattended runs pin' "$nojq_gate_detail" \
  "the gate's own refusal names the PATH it searched"
assert_match 'orchid service install. cannot help' "$nojq_gate_detail" \
  "the gate no longer sends the operator to re-run 'orchid service install'"

# `status --explain` keeps the fixed unattended PATH for its whole run, so it
# can see an operator PATH that would leave interactive verbs short. It says
# so rather than leaving the operator to meet it as an unexplained failure.
tools_repo="$WORK/tool-probe-repo"
mk_repo "$tools_repo"
trust_repo "$tools_repo" "tool probe fixture"
tools_status="$(
  HOME="$home" PATH="$nojq_bin" ORCHID_REPO="$tools_repo" \
    "$ORCHID_BIN" status --explain 2>&1
)"
assert_match '^unattended: allowed' "$tools_status" \
  "the tool-probe fixture is acknowledged, so the gate itself is open"
assert_match '^unattended_tools: WARNING: jq is reachable on the fixed PATH' \
  "$tools_status" "status --explain reports a kernel tool the operator PATH cannot reach"

tools_status_ok="$(
  HOME="$home" ORCHID_REPO="$tools_repo" "$ORCHID_BIN" status --explain 2>&1
)"
echo "$tools_status_ok" | grep -q '^unattended_tools:' \
  && fail "status --explain must stay silent about tools when both PATHs agree"

# ---------------------------------------------------------------------------
# Machine-wide deduplication (jdupes -L, rdfind, hardlink(1), some backup
# tools) replaces byte-identical files with hard links to one copy. Git's
# stock .git/description -- Orchid's identity witness -- is byte-identical in
# every repository on the machine, so such a pass links them all together and
# breaks the two-link anchor pair. That must stay fail-closed at BOTH the gate
# and re-acknowledgement, but it must not deadlock: the witness is untracked
# and its contents are never read, so recreating it clears foreign aliases,
# and both refusals must say so.
# ---------------------------------------------------------------------------
dedup_repo="$WORK/dedup-witness-repo"
mk_repo "$dedup_repo"
trust_repo "$dedup_repo" "deduplication fixture"
dedup_out="$(HOME="$home" "$ORCHID_BIN" trust show "$dedup_repo")"
assert_match '^unattended trust: trusted$' "$dedup_out" \
  "the deduplication fixture starts out trusted"
dedup_witness="$(printf '%s\n' "$dedup_out" | sed -n 's/^identity_witness: //p')"
dedup_before="$(cat "$dedup_witness")"
ln "$dedup_witness" "$WORK/dedup-twin" \
  || fail "the deduplication fixture must be able to hard-link the witness"

dedup_denied="$(HOME="$home" "$ORCHID_BIN" trust show "$dedup_repo")"
assert_match '^unattended trust: untrusted$' "$dedup_denied" \
  "a foreign hard link on the identity witness denies the gate, fail-closed"
assert_match '^binding_state: mismatch$' "$dedup_denied" \
  "the aliased witness is reported as an incarnation mismatch"
assert_match 'carries 3 hard links' "$dedup_denied" \
  "the refusal names the actual finding, not just a bare anchor mismatch"
assert_match 'recreating it' "$dedup_denied" \
  "the gate's refusal names the remedy for a deduplicated witness"
assert_match 'orchid trust unattended' "$dedup_denied" \
  "the gate's refusal names the command that completes the repair"

rc=0
dedup_ack="$(HOME="$home" "$ORCHID_BIN" trust unattended "$dedup_repo" \
  --reason "re-acknowledge after deduplication" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "re-acknowledgement must stay closed while the alias exists"
assert_match 'hard-link alias' "$dedup_ack" \
  "the acknowledgement refusal still names the unexpected alias"
assert_match 'recreating it' "$dedup_ack" \
  "the acknowledgement refusal names the remedy instead of dead-ending"

# The documented repair, exactly as docs/troubleshooting.md prints it.
cp "$dedup_witness" "$dedup_witness.orchid-new"
mv "$dedup_witness.orchid-new" "$dedup_witness"
assert_eq "$dedup_before" "$(cat "$dedup_witness")" \
  "the documented repair preserves the witness contents"
HOME="$home" "$ORCHID_BIN" trust unattended "$dedup_repo" \
  --reason "re-acknowledge after deduplication" >/dev/null \
  || fail "recreating the witness must make the repository acknowledgeable again"
dedup_repaired="$(HOME="$home" "$ORCHID_BIN" trust show "$dedup_repo")"
assert_match '^unattended trust: trusted$' "$dedup_repaired" \
  "the repaired witness restores unattended trust"
[ -f "$WORK/dedup-twin" ] \
  || fail "the repair must leave the other party's own copy alone"
