#!/usr/bin/env bash
# Machine-local unattended trust: identity semantics, provenance, revocation,
# and the explicit exemption for manual/read-only operation.
source "$(dirname "$0")/helpers.sh"
export ORCHID_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/common.sh"

home="$WORK/home"
mkdir -p "$home"
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
record="$(printf '%s\n' "$out" | sed -n 's/^record: //p')"
case "$record" in
  "$home"/.orchid/unattended-trust/*.json) ;;
  *) fail "record must live under the operator HOME, outside the repo (got '$record')" ;;
esac
[ -f "$record" ] || fail "show's machine-local record path must exist"
[ ! -e "$repo/.orchid/unattended-trust.json" ] \
  || fail "unattended trust must never write a record inside the repo"

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
