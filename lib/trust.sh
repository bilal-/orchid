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
# common directory and root history. Object-location overrides are cleared
# for the same reason. Replacement refs, legacy grafts, and shallow traversal
# boundaries are disabled outright: repository-local metadata must not be
# able to present a replaced or incomplete history while retaining the
# previously acknowledged root.
#
# GIT_NO_LAZY_FETCH also keeps inspection side-effect-free for partial clones:
# if a root cannot be established from local objects, fail closed instead of
# consulting a promisor remote before the unattended gate has passed.
_unattended_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_IMPLICIT_WORK_TREE GIT_PREFIX
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
  unset GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE GIT_QUARANTINE_PATH
  unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  unset GIT_CEILING_DIRECTORIES
  unset GIT_DISCOVERY_ACROSS_FILESYSTEM
  GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 \
    GIT_GRAFT_FILE=/dev/null GIT_SHALLOW_FILE=/dev/null command git "$@"
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

# Find the checkout root from the nearest on-disk .git marker rather than
# `git rev-parse --show-toplevel`. The latter honors repository-local
# core.worktree configuration, which could narrow the reported top level and
# hide that HOME's trust store is elsewhere inside the real checkout.
_unattended_worktree_root() {
  local path
  path="$(_unattended_repo_canon "$1")" || return 1
  while :; do
    if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
      printf '%s\n' "$path"
      return 0
    fi
    [ "$path" != / ] || break
    path="${path%/*}"
    [ -n "$path" ] || path=/
  done
  return 1
}

# Read one metadata line without silently accepting a second line. Git's
# .git/gitdir pointer formats are line based, so a newline in a purported path
# is malformed rather than another spelling of the same registration.
_unattended_read_single_line() {
  local path="$1" line="" extra=""
  {
    IFS= read -r line || [ -n "$line" ] || return 1
    if IFS= read -r extra || [ -n "$extra" ]; then
      return 1
    fi
  } <"$path"
  case "$line" in *$'\r') line="${line%$'\r'}" ;; esac
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

_unattended_resolve_directory() {
  local base="$1" raw="$2" candidate
  case "$raw" in
    /*) candidate="$raw" ;;
    *)  candidate="$base/$raw" ;;
  esac
  ( cd "$candidate" 2>/dev/null && pwd -P )
}

# Resolve a registered worktree's .git marker while preserving the final
# filename. Requiring that literal marker name and a regular, non-symlink file
# keeps path normalization from turning some other object into a registration.
_unattended_resolve_git_marker() {
  local base="$1" raw="$2" candidate parent
  case "$raw" in
    /*) candidate="$raw" ;;
    *)  candidate="$base/$raw" ;;
  esac
  [ "${candidate##*/}" = .git ] || return 1
  parent="${candidate%/*}"
  [ -n "$parent" ] || parent=/
  parent="$(cd "$parent" 2>/dev/null && pwd -P)" || return 1
  candidate="${parent%/}/.git"
  [ ! -L "$candidate" ] && [ -f "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

# Bind the physical checkout selected by the caller before asking Git to
# canonicalize its common directory. A linked worktree has two reciprocal
# pointers: <worktree>/.git names its administrative gitdir, whose `gitdir`
# file names that exact worktree marker. A copied linked checkout retains the
# first pointer but its administrative gitdir still points back to the
# registered original; comparing physical marker paths therefore fails closed
# instead of lending the copy the original worktree's common-directory trust.
_unattended_worktree_marker_validate() {
  local root="$1" marker="$1/.git" line raw gitdir registered_line registered
  ORCHID_UNATTENDED_WORKTREE_MARKER_KIND=""
  ORCHID_UNATTENDED_WORKTREE_GITDIR=""
  ORCHID_UNATTENDED_BOUNDARY_DETAIL=""

  if [ -L "$marker" ]; then
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree .git marker is a symbolic link"
    return 1
  fi
  if [ -d "$marker" ]; then
    ORCHID_UNATTENDED_WORKTREE_MARKER_KIND=directory
    ORCHID_UNATTENDED_WORKTREE_GITDIR="$(cd "$marker" 2>/dev/null && pwd -P)" \
      || return 1
    return 0
  fi
  if [ ! -f "$marker" ]; then
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree has no regular on-disk .git marker"
    return 1
  fi

  line="$(_unattended_read_single_line "$marker")" || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree .git pointer is malformed"
    return 1
  }
  case "$line" in
    "gitdir: "*) raw="${line#gitdir: }" ;;
    *)
      ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree .git pointer is malformed"
      return 1
      ;;
  esac
  [ -n "$raw" ] || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree .git pointer is empty"
    return 1
  }
  gitdir="$(_unattended_resolve_directory "$root" "$raw")" || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree .git pointer is inaccessible"
    return 1
  }
  [ ! -L "$gitdir/gitdir" ] && [ -f "$gitdir/gitdir" ] || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree is not backed by a linked-worktree registration"
    return 1
  }
  registered_line="$(_unattended_read_single_line "$gitdir/gitdir")" || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the linked-worktree registration is malformed"
    return 1
  }
  registered="$(_unattended_resolve_git_marker "$gitdir" "$registered_line")" || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the linked-worktree registration does not name an accessible .git marker"
    return 1
  }
  if [ "$registered" != "$marker" ]; then
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree path does not match the linked-worktree registration"
    return 1
  fi

  ORCHID_UNATTENDED_WORKTREE_MARKER_KIND=linked
  ORCHID_UNATTENDED_WORKTREE_GITDIR="$gitdir"
  return 0
}

# Once Git's common directory is known, make sure the marker validated above
# is one of that directory's own administrative entries. A normal checkout's
# .git directory is the common directory; a linked checkout's gitdir is a
# direct child of <common>/worktrees/.
_unattended_worktree_marker_matches_common() {
  local common="$1" worktrees gitdir_parent
  case "$ORCHID_UNATTENDED_WORKTREE_MARKER_KIND" in
    directory)
      [ "$ORCHID_UNATTENDED_WORKTREE_GITDIR" = "$common" ] || {
        ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected .git directory is not Git's resolved common directory"
        return 1
      }
      ;;
    linked)
      worktrees="$(cd "$common/worktrees" 2>/dev/null && pwd -P)" || {
        ORCHID_UNATTENDED_BOUNDARY_DETAIL="Git's common directory has no linked-worktree registry"
        return 1
      }
      gitdir_parent="$(cd "$ORCHID_UNATTENDED_WORKTREE_GITDIR/.." 2>/dev/null && pwd -P)" \
        || return 1
      [ "$gitdir_parent" = "$worktrees" ] || {
        ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree is not registered under Git's common directory"
        return 1
      }
      ;;
    *)
      ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree marker was not validated"
      return 1
      ;;
  esac
}

# The trust store must be outside every worktree registered under the shared
# common directory, not merely outside the worktree used for this invocation.
# Otherwise a sibling could commit the machine-local acknowledgement and lend
# repository-controlled state to every linked checkout. `-z` preserves unusual
# path bytes. The success sentinel distinguishes an empty/partial failed Git
# query from a complete list without creating a temporary file during this
# read-only inspection.
_unattended_trust_store_outside_registered_worktrees() {
  local common="$1" trust_dir="$2" field raw registered
  local complete=0 sentinel="orchid-unattended-worktree-list-complete-v1"
  while IFS= read -r -d '' field; do
    if [ "$field" = "$sentinel" ]; then
      complete=1
      continue
    fi
    case "$field" in
      "worktree "*)
        raw="${field#worktree }"
        registered="$(_unattended_repo_canon "$raw")" || continue
        if _unattended_path_within "$registered" "$trust_dir"; then
          ORCHID_UNATTENDED_BOUNDARY_DETAIL="machine-local unattended-trust directory resolves inside registered worktree $registered; use an operator HOME outside every worktree sharing this Git common directory"
          return 1
        fi
        ;;
    esac
  done < <(
    if _unattended_git --git-dir="$common" worktree list --porcelain -z 2>/dev/null; then
      printf '%s\0' "$sentinel"
    fi
  )
  [ "$complete" -eq 1 ] || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="cannot enumerate worktrees registered under Git's common directory"
    return 1
  }
}

_unattended_trust_store_validate() {
  local repo="$1" worktree_root="$2" common="$3" trust_dir="$4"
  if _unattended_path_within "$repo" "$trust_dir" \
     || _unattended_path_within "$worktree_root" "$trust_dir" \
     || _unattended_path_within "$common" "$trust_dir"; then
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="machine-local unattended-trust directory resolves inside the target repository; use an operator HOME outside the target"
    return 1
  fi
  _unattended_trust_store_outside_registered_worktrees "$common" "$trust_dir"
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

# Return "<hard-link-count> <octal-mode>" for an existing file. Trust records
# are required to be single-link, operator-owned regular files without
# group/other write permission: otherwise a record under the machine-local
# store could merely be an alias of tracked content, or another local account
# could rewrite the decision after the operator acknowledged it.
_unattended_file_security_metadata() {
  local path="$1" out links mode
  if out="$(stat -f '%l %Lp' "$path" 2>/dev/null)"; then
    :
  elif out="$(stat -c '%h %a' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  links="${out%% *}"
  mode="${out#* }"
  case "$links" in ''|*[!0-9]*) return 1 ;; esac
  case "$mode" in ''|*[!0-7]*) return 1 ;; esac
  printf '%s %s\n' "$links" "$mode"
}

# Record-only atomic writer. BSD `mv -h` and GNU/BusyBox `mv -T` are the
# respective no-dereference/no-target-directory forms: unlike a plain `mv`,
# they replace a destination symlink to a directory instead of moving the
# temp file through that symlink into the directory. The caller rejects an
# existing non-file first; the repeated directory check here narrows the
# remaining check/write race and also keeps a real directory from becoming a
# plain `mv` target on BSD.
_unattended_record_atomic_write() {
  local d="$1" t
  t="$(mktemp "${d}.tmp.XXXXXX")" || return 1
  if ! cat >"$t"; then
    rm -f "$t"
    return 1
  fi
  if [ -d "$d" ] && [ ! -L "$d" ]; then
    rm -f "$t"
    return 1
  fi
  if mv -h "$t" "$d" 2>/dev/null; then
    return 0
  fi
  if mv -T "$t" "$d" 2>/dev/null; then
    return 0
  fi
  rm -f "$t"
  return 1
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

# Re-check the repository facts after parsing a matching record. This cannot
# make a shell script immune to a hostile concurrent rename after the gate
# returns, but it prevents one inspection from silently combining a common
# directory/device observation from one repository state with root history
# read from a replacement state.
_unattended_identity_still_matches() {
  local common ident root worktree expected_kind expected_gitdir
  expected_kind="$ORCHID_UNATTENDED_WORKTREE_MARKER_KIND"
  expected_gitdir="$ORCHID_UNATTENDED_WORKTREE_GITDIR"
  worktree="$(_unattended_worktree_root "$ORCHID_UNATTENDED_REPO")" || return 1
  [ "$worktree" = "$ORCHID_UNATTENDED_WORKTREE_ROOT" ] || return 1
  _unattended_worktree_marker_validate "$worktree" || return 1
  [ "$ORCHID_UNATTENDED_WORKTREE_MARKER_KIND" = "$expected_kind" ] || return 1
  [ "$ORCHID_UNATTENDED_WORKTREE_GITDIR" = "$expected_gitdir" ] || return 1
  common="$(_unattended_git_common_dir "$ORCHID_UNATTENDED_REPO")" || return 1
  [ "$common" = "$ORCHID_UNATTENDED_COMMON_DIR" ] || return 1
  _unattended_worktree_marker_matches_common "$common" || return 1
  _unattended_trust_store_validate \
    "$ORCHID_UNATTENDED_REPO" "$worktree" "$common" \
    "$ORCHID_UNATTENDED_TRUST_DIR" || return 1
  ident="$(_unattended_fs_identity "$common")" || return 1
  [ "$ident" = "$ORCHID_UNATTENDED_DEVICE $ORCHID_UNATTENDED_INODE" ] || return 1
  root="$(_unattended_root_commit "$ORCHID_UNATTENDED_REPO")" || return 1
  [ "$root" = "$ORCHID_UNATTENDED_ROOT_COMMIT" ]
}

# Confirm that the exact regular file parsed below is still present and
# byte-equivalent immediately before allowing the gate. The JSON is passed as
# an in-shell string (not re-derived field by field), so concurrent replacement
# cannot produce a trusted decision assembled from multiple record versions.
_unattended_record_still_matches() {
  local path="$1" expected_ident="$2" expected_meta="$3" expected_json="$4"
  local ident meta json
  [ ! -L "$path" ] && [ -f "$path" ] && [ -O "$path" ] || return 1
  ident="$(_unattended_fs_identity "$path")" || return 1
  [ "$ident" = "$expected_ident" ] || return 1
  meta="$(_unattended_file_security_metadata "$path")" || return 1
  [ "$meta" = "$expected_meta" ] || return 1
  json="$(cat "$path" 2>/dev/null)" || return 1
  [ "$json" = "$expected_json" ]
}

# unattended_trust_inspect <repo>
#
# Always returns zero and populates the ORCHID_UNATTENDED_* globals below.
# Callers can therefore report an unavailable/untrusted state without
# tripping their own `set -e`; only unattended_trust_require turns it into a
# refusal. This function is read-only.
unattended_trust_inspect() {
  local repo_in="$1" ident rec_schema rec_kind rec_device rec_inode rec_policy rec_root
  local trust_dir trust_dir_physical rec_meta rec_links rec_mode record_ident record_json
  local provenance_valid=0

  ORCHID_UNATTENDED_STATE=unavailable
  ORCHID_UNATTENDED_DETAIL="repository identity is unavailable"
  ORCHID_UNATTENDED_REPO=""
  ORCHID_UNATTENDED_WORKTREE_ROOT=""
  ORCHID_UNATTENDED_WORKTREE_MARKER_KIND=""
  ORCHID_UNATTENDED_WORKTREE_GITDIR=""
  ORCHID_UNATTENDED_COMMON_DIR=""
  ORCHID_UNATTENDED_DEVICE=""
  ORCHID_UNATTENDED_INODE=""
  ORCHID_UNATTENDED_ROOT_COMMIT=""
  ORCHID_UNATTENDED_TRUST_DIR=""
  ORCHID_UNATTENDED_RECORD=""
  ORCHID_UNATTENDED_RECORD_EXISTS=0
  ORCHID_UNATTENDED_RECORD_LOADED=0
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
  if ! ORCHID_UNATTENDED_WORKTREE_ROOT="$(_unattended_worktree_root "$ORCHID_UNATTENDED_REPO")"; then
    ORCHID_UNATTENDED_DETAIL="target is not inside a Git worktree with an on-disk .git marker"
    return 0
  fi
  if ! _unattended_worktree_marker_validate "$ORCHID_UNATTENDED_WORKTREE_ROOT"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-caller-selected worktree marker is invalid}"
    return 0
  fi
  if ! ORCHID_UNATTENDED_COMMON_DIR="$(_unattended_git_common_dir "$ORCHID_UNATTENDED_REPO")"; then
    ORCHID_UNATTENDED_DETAIL="target is not a Git worktree with an accessible common directory"
    return 0
  fi
  if _unattended_path_within "$ORCHID_UNATTENDED_COMMON_DIR" "$ORCHID_UNATTENDED_REPO"; then
    ORCHID_UNATTENDED_DETAIL="target worktree resolves inside its Git common directory"
    return 0
  fi
  if ! _unattended_worktree_marker_matches_common "$ORCHID_UNATTENDED_COMMON_DIR"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-caller-selected worktree is not registered under its Git common directory}"
    return 0
  fi
  if ! trust_dir="$(_unattended_trust_dir)" \
     || ! trust_dir_physical="$(_unattended_trust_dir_physical)"; then
    ORCHID_UNATTENDED_DETAIL="machine-local unattended-trust directory is unavailable"
    return 0
  fi
  # Use the resolved absolute directory for every record access. The logical
  # HOME spelling is useful for locating the store, but continuing through a
  # symlinked component after validating its physical target would reopen a
  # needless redirection window.
  ORCHID_UNATTENDED_TRUST_DIR="$trust_dir_physical"

  # The record must not be trackable by any checkout sharing this trust
  # identity. Physical paths catch symlinked HOME/.orchid layouts as well as
  # simple lexical containment, including containment in a sibling worktree.
  if ! _unattended_trust_store_validate \
      "$ORCHID_UNATTENDED_REPO" "$ORCHID_UNATTENDED_WORKTREE_ROOT" \
      "$ORCHID_UNATTENDED_COMMON_DIR" "$trust_dir_physical"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-machine-local unattended-trust directory placement is unsafe}"
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
  if [ ! -e "$ORCHID_UNATTENDED_RECORD" ] && [ ! -L "$ORCHID_UNATTENDED_RECORD" ]; then
    ORCHID_UNATTENDED_STATE=untrusted
    ORCHID_UNATTENDED_DETAIL="no machine-local acknowledgement for this Git common-directory identity"
    return 0
  fi
  ORCHID_UNATTENDED_RECORD_EXISTS=1
  if [ -L "$ORCHID_UNATTENDED_RECORD" ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record must not be a symbolic link"
    return 0
  fi
  if [ ! -f "$ORCHID_UNATTENDED_RECORD" ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record is not a regular file"
    return 0
  fi
  if [ ! -O "$ORCHID_UNATTENDED_RECORD" ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record is not owned by the current operator"
    return 0
  fi
  if ! rec_meta="$(_unattended_file_security_metadata "$ORCHID_UNATTENDED_RECORD")"; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="cannot inspect machine-local acknowledgement record permissions"
    return 0
  fi
  rec_links="${rec_meta%% *}"
  rec_mode="${rec_meta#* }"
  if [ "$rec_links" != 1 ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record must not be hard-linked to another path"
    return 0
  fi
  if [ $((8#$rec_mode & 022)) -ne 0 ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record is writable by group or other"
    return 0
  fi
  if ! record_ident="$(_unattended_fs_identity "$ORCHID_UNATTENDED_RECORD")" \
     || ! record_json="$(cat "$ORCHID_UNATTENDED_RECORD" 2>/dev/null)"; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="cannot read machine-local acknowledgement record"
    return 0
  fi
  if ! printf '%s' "$record_json" | jq -e '
    type == "object"
    and (.schema | type == "number")
    and (.kind | type == "string")
    and (.policy_version | type == "number")
    and (.acknowledged_at | type == "string")
    and (.reason | type == "string")
    and (.acknowledged_repo | type == "string")
    and (.git_common_dir | type == "string")
    and (.git_common_device | type == "string")
    and (.git_common_inode | type == "string")
    and (.root_commit | type == "string")
  ' >/dev/null 2>&1; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record is malformed"
    return 0
  fi

  rec_schema="$(printf '%s' "$record_json" | jq -r '.schema // ""' 2>/dev/null || true)"
  rec_kind="$(printf '%s' "$record_json" | jq -r '.kind // ""' 2>/dev/null || true)"
  rec_device="$(printf '%s' "$record_json" | jq -r '.git_common_device // ""' 2>/dev/null || true)"
  rec_inode="$(printf '%s' "$record_json" | jq -r '.git_common_inode // ""' 2>/dev/null || true)"
  rec_policy="$(printf '%s' "$record_json" | jq -r '.policy_version // ""' 2>/dev/null || true)"
  rec_root="$(printf '%s' "$record_json" | jq -r '.root_commit // ""' 2>/dev/null || true)"

  ORCHID_UNATTENDED_RECORDED_REPO="$(printf '%s' "$record_json" | jq -r '.acknowledged_repo // ""' 2>/dev/null || true)"
  ORCHID_UNATTENDED_RECORDED_COMMON_DIR="$(printf '%s' "$record_json" | jq -r '.git_common_dir // ""' 2>/dev/null || true)"
  ORCHID_UNATTENDED_RECORDED_SCHEMA="$rec_schema"
  ORCHID_UNATTENDED_RECORDED_KIND="$rec_kind"
  ORCHID_UNATTENDED_RECORDED_DEVICE="$rec_device"
  ORCHID_UNATTENDED_RECORDED_INODE="$rec_inode"
  ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT="$rec_root"
  ORCHID_UNATTENDED_RECORDED_POLICY_VERSION="$rec_policy"
  ORCHID_UNATTENDED_ACKNOWLEDGED_AT="$(printf '%s' "$record_json" | jq -r '.acknowledged_at // ""' 2>/dev/null || true)"
  ORCHID_UNATTENDED_REASON="$(printf '%s' "$record_json" | jq -r '.reason // ""' 2>/dev/null || true)"
  ORCHID_UNATTENDED_RECORD_LOADED=1

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
  elif ! _unattended_record_still_matches "$ORCHID_UNATTENDED_RECORD" \
      "$record_ident" "$rec_meta" "$record_json"; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record changed during inspection; retry"
  elif ! _unattended_identity_still_matches; then
    ORCHID_UNATTENDED_STATE=unavailable
    ORCHID_UNATTENDED_DETAIL="repository identity changed during trust inspection; retry"
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
    if [ "${ORCHID_UNATTENDED_RECORD_EXISTS:-0}" -eq 1 ]; then
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
  printf 'worktree_root: %s\n' "${ORCHID_UNATTENDED_WORKTREE_ROOT:-unavailable}"
  printf 'git_common_dir: %s\n' "${ORCHID_UNATTENDED_COMMON_DIR:-unavailable}"
  printf 'git_common_device: %s\n' "${ORCHID_UNATTENDED_DEVICE:-unavailable}"
  printf 'git_common_inode: %s\n' "${ORCHID_UNATTENDED_INODE:-unavailable}"
  printf 'root_commit: %s\n' "${ORCHID_UNATTENDED_ROOT_COMMIT:-unavailable}"
  printf 'policy_version: %s\n' "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION"
  printf 'record: %s\n' "${ORCHID_UNATTENDED_RECORD:-none}"
  if [ "${ORCHID_UNATTENDED_RECORD_LOADED:-0}" -eq 1 ]; then
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
  dir="$ORCHID_UNATTENDED_TRUST_DIR"
  (
    umask 077
    mkdir -p "$dir"
    # Re-inspect after creating the directory so a pre-existing/symlinked
    # component and the repository identity are validated immediately before
    # the record is selected and written, not only before mkdir.
    unattended_trust_inspect "$repo"
    [ "$ORCHID_UNATTENDED_STATE" != unavailable ] \
      || orchid_die "cannot acknowledge unattended execution: $ORCHID_UNATTENDED_DETAIL"
    [ ! -L "$ORCHID_UNATTENDED_RECORD" ] \
      || orchid_die "cannot acknowledge unattended execution: acknowledgement record path is a symbolic link; revoke it first"
    if [ -e "$ORCHID_UNATTENDED_RECORD" ] && [ ! -f "$ORCHID_UNATTENDED_RECORD" ]; then
      orchid_die "cannot acknowledge unattended execution: acknowledgement record path is not a regular file"
    fi
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
      | _unattended_record_atomic_write "$ORCHID_UNATTENDED_RECORD"
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
  if [ -L "$ORCHID_UNATTENDED_RECORD" ] || [ -f "$ORCHID_UNATTENDED_RECORD" ]; then
    rm -f "$ORCHID_UNATTENDED_RECORD"
    return 0
  fi
  if [ -e "$ORCHID_UNATTENDED_RECORD" ]; then
    orchid_die "cannot revoke unattended trust: acknowledgement record path is not a file"
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
