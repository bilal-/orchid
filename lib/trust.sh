#!/usr/bin/env bash

# Machine-local unattended-execution trust.
#
# This is deliberately separate from lib/common.sh's repo-local PLUGIN trust
# store. Plugin trust pins executable content at a path; unattended trust is
# an operator acknowledgement of the prompt-injection risk presented by a
# whole target repository. Its records live outside every repository under
# ~/.orchid/unattended-trust/.
#
# A record is bound to three facts that repository-controlled content cannot
# grant:
#   * the filesystem identity (device + inode) of Git's common directory;
#   * the root commit(s) reachable from the target worktree's HEAD; and
#   * this in-code policy version.
#
# The common directory, rather than a checkout path or per-worktree gitdir,
# makes linked worktrees share one acknowledgement. Device/inode, rather than
# a path, keeps a same-filesystem rename trusted. A clone, copy, replacement
# common directory, root-history replacement, or policy-version bump no longer
# matches. Origin URLs, git config, orchid.config, and tracked files are never
# consulted.

# Security constant: always overwrite an inherited environment value. An
# environment variable must not be able to select an older trust policy.
ORCHID_UNATTENDED_TRUST_POLICY_VERSION=1
ORCHID_UNATTENDED_TRUST_RECORD_SCHEMA=1

_unattended_trust_dir() {
  [ -n "${HOME:-}" ] || return 1
  printf '%s\n' "$HOME/.orchid/unattended-trust"
}

_unattended_repo_canon() {
  ( cd "$1" 2>/dev/null && pwd -P )
}

# Run identity-only Git queries against the path supplied by the caller, not
# against repository-selection state inherited from an outer Git/Orchid
# process. Without this boundary, `GIT_DIR=<trusted> GIT_WORK_TREE=<target>`
# could make an untrusted target resolve another repository's acknowledged
# common directory and root history. Object-location/replace/shallow
# overrides are cleared for the same reason: the binding must describe the
# repository on disk at <repo>, not a caller-composed object view.
#
# GIT_NO_LAZY_FETCH also keeps inspection side-effect-free for partial clones:
# if a root cannot be established from local objects, fail closed instead of
# consulting a promisor remote before the unattended gate has passed.
_unattended_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
  unset GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE GIT_QUARANTINE_PATH
  unset GIT_CEILING_DIRECTORIES
  unset GIT_DISCOVERY_ACROSS_FILESYSTEM
  GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0 command git "$@"
)

_unattended_path_within() {
  local parent="${1%/}" child="${2%/}"
  [ -n "$parent" ] || parent=/
  [ "$parent" = / ] && return 0
  case "$child/" in "$parent/"*) return 0 ;; esac
  return 1
}

# Resolve the intended store without creating it. Existing symlinked
# components are followed so a ~/.orchid symlink into the target cannot turn
# nominally machine-local state into repository-controlled state. The final
# directory may not exist yet; in that case its nearest relevant existing
# parent is resolved and the missing component is appended.
_unattended_trust_dir_physical() {
  local home orchid_dir trust_dir
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || return 1
  home="$(cd "$HOME" 2>/dev/null && pwd -P)" || return 1
  orchid_dir="$home/.orchid"
  if [ -e "$orchid_dir" ] || [ -L "$orchid_dir" ]; then
    [ -d "$orchid_dir" ] || return 1
    orchid_dir="$(cd "$orchid_dir" 2>/dev/null && pwd -P)" || return 1
  fi
  trust_dir="$orchid_dir/unattended-trust"
  if [ -e "$trust_dir" ] || [ -L "$trust_dir" ]; then
    [ -d "$trust_dir" ] || return 1
    trust_dir="$(cd "$trust_dir" 2>/dev/null && pwd -P)" || return 1
  fi
  printf '%s\n' "$trust_dir"
}

_unattended_git_common_dir() {
  local repo="$1" raw
  raw="$(_unattended_git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$raw" in
    /*) ( cd "$raw" 2>/dev/null && pwd -P ) ;;
    *)  ( cd "$repo/$raw" 2>/dev/null && pwd -P ) ;;
  esac
}

_unattended_fs_identity() {
  local path="$1" out
  if out="$(stat -f '%d %i' "$path" 2>/dev/null)"; then
    :
  elif out="$(stat -c '%d %i' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  case "$out" in
    *[!0-9\ ]*|"") return 1 ;;
  esac
  printf '%s\n' "$out"
}

_unattended_root_commit() {
  local repo="$1"
  # Most repositories have exactly one root. Joining a sorted set also
  # handles histories created with --allow-unrelated-histories without
  # silently ignoring one of their roots.
  _unattended_git -C "$repo" rev-list --max-parents=0 HEAD 2>/dev/null \
    | LC_ALL=C sort \
    | awk 'NF { if (roots != "") roots=roots ","; roots=roots $0 }
           END { if (roots != "") print roots }'
}

_unattended_one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' '
}

# unattended_trust_inspect <repo>
#
# Always returns zero and populates the ORCHID_UNATTENDED_* globals below.
# Callers can therefore report an unavailable/untrusted state without
# tripping their own `set -e`; only unattended_trust_require turns it into a
# refusal. This function is read-only.
unattended_trust_inspect() {
  local repo_in="$1" ident rec_schema rec_kind rec_device rec_inode rec_policy rec_root
  local trust_dir trust_dir_physical worktree_root
  local provenance_valid=0

  ORCHID_UNATTENDED_STATE=unavailable
  ORCHID_UNATTENDED_DETAIL="repository identity is unavailable"
  ORCHID_UNATTENDED_REPO=""
  ORCHID_UNATTENDED_COMMON_DIR=""
  ORCHID_UNATTENDED_DEVICE=""
  ORCHID_UNATTENDED_INODE=""
  ORCHID_UNATTENDED_ROOT_COMMIT=""
  ORCHID_UNATTENDED_TRUST_DIR=""
  ORCHID_UNATTENDED_RECORD=""
  ORCHID_UNATTENDED_RECORDED_REPO=""
  ORCHID_UNATTENDED_RECORDED_COMMON_DIR=""
  ORCHID_UNATTENDED_RECORDED_SCHEMA=""
  ORCHID_UNATTENDED_RECORDED_KIND=""
  ORCHID_UNATTENDED_RECORDED_DEVICE=""
  ORCHID_UNATTENDED_RECORDED_INODE=""
  ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT=""
  ORCHID_UNATTENDED_RECORDED_POLICY_VERSION=""
  ORCHID_UNATTENDED_ACKNOWLEDGED_AT=""
  ORCHID_UNATTENDED_REASON=""

  if ! ORCHID_UNATTENDED_REPO="$(_unattended_repo_canon "$repo_in")"; then
    ORCHID_UNATTENDED_DETAIL="target is not an accessible directory"
    return 0
  fi
  if ! ORCHID_UNATTENDED_COMMON_DIR="$(_unattended_git_common_dir "$ORCHID_UNATTENDED_REPO")"; then
    ORCHID_UNATTENDED_DETAIL="target is not a Git worktree with an accessible common directory"
    return 0
  fi
  if ! trust_dir="$(_unattended_trust_dir)" \
     || ! trust_dir_physical="$(_unattended_trust_dir_physical)"; then
    ORCHID_UNATTENDED_DETAIL="machine-local unattended-trust directory is unavailable"
    return 0
  fi
  ORCHID_UNATTENDED_TRUST_DIR="$trust_dir"

  # The record must not be trackable by the repository it authorizes. Check
  # both the supplied path and Git's worktree root (the caller may have named
  # a subdirectory), plus the common directory itself. Physical paths catch
  # symlinked HOME/.orchid layouts as well as simple lexical containment.
  worktree_root="$(_unattended_git -C "$ORCHID_UNATTENDED_REPO" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$worktree_root" ]; then
    worktree_root="$(_unattended_repo_canon "$worktree_root" 2>/dev/null || true)"
  fi
  [ -n "$worktree_root" ] || worktree_root="$ORCHID_UNATTENDED_REPO"
  if _unattended_path_within "$ORCHID_UNATTENDED_REPO" "$trust_dir_physical" \
     || _unattended_path_within "$worktree_root" "$trust_dir_physical" \
     || _unattended_path_within "$ORCHID_UNATTENDED_COMMON_DIR" "$trust_dir_physical"; then
    ORCHID_UNATTENDED_DETAIL="machine-local unattended-trust directory resolves inside the target repository; use an operator HOME outside the target"
    return 0
  fi
  if ! ident="$(_unattended_fs_identity "$ORCHID_UNATTENDED_COMMON_DIR")"; then
    ORCHID_UNATTENDED_DETAIL="cannot read Git common-directory filesystem identity"
    return 0
  fi
  ORCHID_UNATTENDED_DEVICE="${ident%% *}"
  ORCHID_UNATTENDED_INODE="${ident#* }"
  if [ -z "$ORCHID_UNATTENDED_DEVICE" ] || [ -z "$ORCHID_UNATTENDED_INODE" ] \
     || [ "$ORCHID_UNATTENDED_INODE" = "$ident" ]; then
    ORCHID_UNATTENDED_DETAIL="cannot parse Git common-directory filesystem identity"
    return 0
  fi
  if ! ORCHID_UNATTENDED_ROOT_COMMIT="$(_unattended_root_commit "$ORCHID_UNATTENDED_REPO")"; then
    ORCHID_UNATTENDED_ROOT_COMMIT=""
  fi
  if [ -z "$ORCHID_UNATTENDED_ROOT_COMMIT" ]; then
    ORCHID_UNATTENDED_DETAIL="repository has no reachable root commit at HEAD"
    return 0
  fi

  ORCHID_UNATTENDED_RECORD="$ORCHID_UNATTENDED_TRUST_DIR/$ORCHID_UNATTENDED_DEVICE-$ORCHID_UNATTENDED_INODE.json"
  if [ ! -f "$ORCHID_UNATTENDED_RECORD" ]; then
    ORCHID_UNATTENDED_STATE=untrusted
    ORCHID_UNATTENDED_DETAIL="no machine-local acknowledgement for this Git common-directory identity"
    return 0
  fi
  if ! jq -e 'type == "object"' "$ORCHID_UNATTENDED_RECORD" >/dev/null 2>&1; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record is malformed"
    return 0
  fi

  rec_schema="$(jq -r '.schema // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  rec_kind="$(jq -r '.kind // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  rec_device="$(jq -r '.git_common_device // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  rec_inode="$(jq -r '.git_common_inode // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  rec_policy="$(jq -r '.policy_version // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  rec_root="$(jq -r '.root_commit // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"

  ORCHID_UNATTENDED_RECORDED_REPO="$(jq -r '.acknowledged_repo // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  ORCHID_UNATTENDED_RECORDED_COMMON_DIR="$(jq -r '.git_common_dir // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  ORCHID_UNATTENDED_RECORDED_SCHEMA="$rec_schema"
  ORCHID_UNATTENDED_RECORDED_KIND="$rec_kind"
  ORCHID_UNATTENDED_RECORDED_DEVICE="$rec_device"
  ORCHID_UNATTENDED_RECORDED_INODE="$rec_inode"
  ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT="$rec_root"
  ORCHID_UNATTENDED_RECORDED_POLICY_VERSION="$rec_policy"
  ORCHID_UNATTENDED_ACKNOWLEDGED_AT="$(jq -r '.acknowledged_at // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"
  ORCHID_UNATTENDED_REASON="$(jq -r '.reason // ""' "$ORCHID_UNATTENDED_RECORD" 2>/dev/null || true)"

  if [ -n "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT" ] \
     && [ -n "$ORCHID_UNATTENDED_RECORDED_REPO" ] \
     && [ -n "$ORCHID_UNATTENDED_RECORDED_COMMON_DIR" ] \
     && printf '%s' "$ORCHID_UNATTENDED_REASON" | LC_ALL=C grep -q '[^[:space:]]'; then
    provenance_valid=1
  fi

  if [ "$rec_schema" != "$ORCHID_UNATTENDED_TRUST_RECORD_SCHEMA" ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record schema is unsupported (recorded ${rec_schema:-missing}, current $ORCHID_UNATTENDED_TRUST_RECORD_SCHEMA)"
  elif [ "$rec_kind" != unattended ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record kind is invalid (recorded ${rec_kind:-missing}, expected unattended)"
  elif [ "$rec_device" != "$ORCHID_UNATTENDED_DEVICE" ] \
       || [ "$rec_inode" != "$ORCHID_UNATTENDED_INODE" ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record identity does not match its Git common directory"
  elif [ "$rec_policy" != "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION" ]; then
    ORCHID_UNATTENDED_STATE=mismatch
    ORCHID_UNATTENDED_DETAIL="trust-policy version changed (recorded ${rec_policy:-missing}, current $ORCHID_UNATTENDED_TRUST_POLICY_VERSION)"
  elif [ "$rec_root" != "$ORCHID_UNATTENDED_ROOT_COMMIT" ]; then
    ORCHID_UNATTENDED_STATE=mismatch
    ORCHID_UNATTENDED_DETAIL="repository root commit changed (recorded ${rec_root:-missing}, current $ORCHID_UNATTENDED_ROOT_COMMIT)"
  elif [ "$provenance_valid" -ne 1 ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record is missing operator provenance"
  else
    ORCHID_UNATTENDED_STATE=trusted
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement matches"
  fi
  return 0
}

unattended_trust_summary_loaded() {
  local reason
  if [ "$ORCHID_UNATTENDED_STATE" = trusted ]; then
    reason="$(_unattended_one_line "$ORCHID_UNATTENDED_REASON")"
    printf 'allowed — acknowledged at %s; reason: %s; git-common identity %s:%s; root %s; policy %s; record %s\n' \
      "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT" "$reason" \
      "$ORCHID_UNATTENDED_DEVICE" "$ORCHID_UNATTENDED_INODE" \
      "$ORCHID_UNATTENDED_ROOT_COMMIT" "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION" \
      "$ORCHID_UNATTENDED_RECORD"
  else
    printf 'denied — %s; git-common identity %s:%s; root %s; policy %s' \
      "$ORCHID_UNATTENDED_DETAIL" \
      "${ORCHID_UNATTENDED_DEVICE:-unavailable}" "${ORCHID_UNATTENDED_INODE:-unavailable}" \
      "${ORCHID_UNATTENDED_ROOT_COMMIT:-unavailable}" "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION"
    if [ -n "$ORCHID_UNATTENDED_RECORD" ] && [ -f "$ORCHID_UNATTENDED_RECORD" ]; then
      printf '; existing record %s' "$ORCHID_UNATTENDED_RECORD"
      [ -z "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT" ] \
        || printf '; acknowledged at %s' "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT"
      if [ -n "$ORCHID_UNATTENDED_REASON" ]; then
        reason="$(_unattended_one_line "$ORCHID_UNATTENDED_REASON")"
        printf '; reason: %s' "$reason"
      fi
    fi
    printf '; acknowledge with: orchid trust unattended <repo> --reason <reason>\n'
  fi
}

unattended_trust_show() {
  local trust_label
  unattended_trust_inspect "$1"
  trust_label="$ORCHID_UNATTENDED_STATE"
  [ "$trust_label" = trusted ] || trust_label=untrusted
  printf 'unattended trust: %s\n' "$trust_label"
  printf 'binding_state: %s\n' "$ORCHID_UNATTENDED_STATE"
  if [ "$ORCHID_UNATTENDED_STATE" = trusted ]; then
    printf 'gate: allowed\n'
  else
    printf 'gate: denied\n'
  fi
  printf 'why: %s\n' "$ORCHID_UNATTENDED_DETAIL"
  printf 'repo: %s\n' "${ORCHID_UNATTENDED_REPO:-unavailable}"
  printf 'git_common_dir: %s\n' "${ORCHID_UNATTENDED_COMMON_DIR:-unavailable}"
  printf 'git_common_device: %s\n' "${ORCHID_UNATTENDED_DEVICE:-unavailable}"
  printf 'git_common_inode: %s\n' "${ORCHID_UNATTENDED_INODE:-unavailable}"
  printf 'root_commit: %s\n' "${ORCHID_UNATTENDED_ROOT_COMMIT:-unavailable}"
  printf 'policy_version: %s\n' "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION"
  printf 'record: %s\n' "${ORCHID_UNATTENDED_RECORD:-none}"
  if [ -n "$ORCHID_UNATTENDED_RECORD" ] && [ -f "$ORCHID_UNATTENDED_RECORD" ]; then
    printf 'recorded_schema: %s\n' "$ORCHID_UNATTENDED_RECORDED_SCHEMA"
    printf 'recorded_kind: %s\n' "$ORCHID_UNATTENDED_RECORDED_KIND"
    printf 'acknowledged_at: %s\n' "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT"
    printf 'acknowledged_repo: %s\n' "$ORCHID_UNATTENDED_RECORDED_REPO"
    printf 'acknowledged_git_common_dir: %s\n' "$ORCHID_UNATTENDED_RECORDED_COMMON_DIR"
    printf 'recorded_git_common_device: %s\n' "$ORCHID_UNATTENDED_RECORDED_DEVICE"
    printf 'recorded_git_common_inode: %s\n' "$ORCHID_UNATTENDED_RECORDED_INODE"
    printf 'recorded_root_commit: %s\n' "$ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT"
    printf 'recorded_policy_version: %s\n' "$ORCHID_UNATTENDED_RECORDED_POLICY_VERSION"
    printf 'reason: %s\n' "$(_unattended_one_line "$ORCHID_UNATTENDED_REASON")"
  fi
}

unattended_trust_acknowledge() {
  local repo="$1" reason="$2" acknowledged_at dir
  unattended_trust_inspect "$repo"
  [ "$ORCHID_UNATTENDED_STATE" != unavailable ] \
    || orchid_die "cannot acknowledge unattended execution: $ORCHID_UNATTENDED_DETAIL"
  printf '%s' "$reason" | LC_ALL=C grep -q '[^[:space:]]' \
    || orchid_die "unattended trust requires a non-empty --reason"

  acknowledged_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dir="$(_unattended_trust_dir)"
  (
    umask 077
    mkdir -p "$dir"
    # Re-inspect after creating the directory so a pre-existing/symlinked
    # component and the repository identity are validated immediately before
    # the record is selected and written, not only before mkdir.
    unattended_trust_inspect "$repo"
    [ "$ORCHID_UNATTENDED_STATE" != unavailable ] \
      || orchid_die "cannot acknowledge unattended execution: $ORCHID_UNATTENDED_DETAIL"
    jq -n \
      --argjson schema "$ORCHID_UNATTENDED_TRUST_RECORD_SCHEMA" \
      --argjson policy_version "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION" \
      --arg acknowledged_at "$acknowledged_at" \
      --arg reason "$reason" \
      --arg acknowledged_repo "$ORCHID_UNATTENDED_REPO" \
      --arg git_common_dir "$ORCHID_UNATTENDED_COMMON_DIR" \
      --arg git_common_device "$ORCHID_UNATTENDED_DEVICE" \
      --arg git_common_inode "$ORCHID_UNATTENDED_INODE" \
      --arg root_commit "$ORCHID_UNATTENDED_ROOT_COMMIT" \
      '{schema:$schema, kind:"unattended", policy_version:$policy_version,
        acknowledged_at:$acknowledged_at, reason:$reason,
        acknowledged_repo:$acknowledged_repo, git_common_dir:$git_common_dir,
        git_common_device:$git_common_device, git_common_inode:$git_common_inode,
        root_commit:$root_commit}' \
      | atomic_write "$ORCHID_UNATTENDED_RECORD"
    chmod 600 "$ORCHID_UNATTENDED_RECORD"
  )
  unattended_trust_inspect "$repo"
  [ "$ORCHID_UNATTENDED_STATE" = trusted ] \
    || orchid_die "failed to persist unattended trust: $ORCHID_UNATTENDED_DETAIL"
}

unattended_trust_revoke() {
  local repo="$1"
  unattended_trust_inspect "$repo"
  [ "$ORCHID_UNATTENDED_STATE" != unavailable ] \
    || orchid_die "cannot revoke unattended trust: $ORCHID_UNATTENDED_DETAIL"
  if [ -f "$ORCHID_UNATTENDED_RECORD" ]; then
    rm -f "$ORCHID_UNATTENDED_RECORD"
    return 0
  fi
  return 1
}

unattended_trust_require() {
  local repo="$1" surface="${2:-unattended execution}" repo_q
  unattended_trust_inspect "$repo"
  [ "$ORCHID_UNATTENDED_STATE" = trusted ] && return 0
  printf 'orchid: %s refused: unattended trust is denied — %s\n' \
    "$surface" "$ORCHID_UNATTENDED_DETAIL" >&2
  if [ -n "$ORCHID_UNATTENDED_REPO" ]; then
    printf -v repo_q '%q' "$ORCHID_UNATTENDED_REPO"
    printf 'orchid: acknowledge on this machine with: orchid trust unattended %s --reason %s\n' \
      "$repo_q" '"<why you trust this repository for unattended execution>"' >&2
  else
    printf 'orchid: the target must be a Git worktree with a root commit before it can be acknowledged\n' >&2
  fi
  return 1
}
