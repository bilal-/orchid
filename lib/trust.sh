#!/usr/bin/env bash

# Machine-local unattended-execution trust.
#
# This is deliberately separate from lib/common.sh's repo-local PLUGIN trust
# store. Plugin trust pins executable content at a path; unattended trust is
# an operator acknowledgement of the prompt-injection risk presented by a
# whole target repository. Its records live outside every repository under
# ~/.orchid/unattended-trust/.
#
# A record is bound to four facts. None grants trust by itself; the matching
# operator-authored record and anchor remain outside the repository:
#   * the filesystem identity (device + inode) of Git's common directory;
#   * a machine-local hard-link anchor to that directory's stable witness file;
#   * the root commit(s) reachable from the target worktree's HEAD; and
#   * this in-code policy version.
#
# The common directory, rather than a checkout path or per-worktree gitdir,
# makes linked worktrees share one acknowledgement. Device/inode, rather than
# a path, keeps a same-filesystem rename trusted. The anchor keeps the
# common-directory witness inode allocated after repository replacement, so
# even reuse of the directory's device/inode cannot resurrect an old
# acknowledgement. A clone, copy, replacement common directory, root-history
# replacement, or policy-version bump no longer matches. Origin URLs, Git
# config, orchid.config, and tracked files are never consulted.

# Security constant: always overwrite an inherited environment value. An
# environment variable must not be able to select an older trust policy.
ORCHID_UNATTENDED_TRUST_POLICY_VERSION=1
ORCHID_UNATTENDED_TRUST_RECORD_SCHEMA=2
ORCHID_UNATTENDED_IDENTITY_WITNESS_NAME=description
# Keep exact-payload verification bounded without letting an inherited
# environment trade integrity for speed. Each batch uses one long-lived
# cat-file process and one long-lived hash-object process, regardless of the
# number of commits in the batch.
ORCHID_UNATTENDED_COMMIT_BATCH_SIZE=256
# Git 2.45 introduced the client-side --no-lazy-fetch control. Older clients
# ignore GIT_NO_LAZY_FETCH during ordinary object access, so they cannot safely
# walk a promisor repository before its unattended boundary has been accepted.
# This is a minimum for unattended trust inspection only; Orchid's manual and
# non-object-walking read-only surfaces remain available on older Git versions.
ORCHID_UNATTENDED_OBJECT_WALK_GIT_MIN=2.45

# Command substitution removes every trailing newline from its output. That is
# unsafe for filesystem values: a directory named "repo\n" is distinct from
# its sibling "repo". Append a non-newline framing byte inside the substitution
# so Bash preserves the payload, then remove only that byte. The line variant
# removes exactly one producer-added newline and therefore retains every
# newline that is part of the value itself. Valid filesystem names cannot
# contain NUL, but they can contain the framing byte; removing only the final
# byte preserves one supplied by the producer.
_unattended_capture_stdout() {
  local __orchid_capture_target="$1" __orchid_capture_value
  local __orchid_capture_status __orchid_capture_marker=$'\036'
  shift
  __orchid_capture_value="$(
    "$@"
    __orchid_capture_status=$?
    printf '%s' "$__orchid_capture_marker"
    exit "$__orchid_capture_status"
  )" || return 1
  case "$__orchid_capture_value" in
    *"$__orchid_capture_marker")
      __orchid_capture_value="${__orchid_capture_value%"$__orchid_capture_marker"}"
      ;;
    *) return 1 ;;
  esac
  printf -v "$__orchid_capture_target" '%s' "$__orchid_capture_value"
}

_unattended_capture_line() {
  local __orchid_line_target="$1" __orchid_line_value
  shift
  _unattended_capture_stdout __orchid_line_value "$@" || return 1
  case "$__orchid_line_value" in
    *$'\n') __orchid_line_value="${__orchid_line_value%$'\n'}" ;;
    *) return 1 ;;
  esac
  printf -v "$__orchid_line_target" '%s' "$__orchid_line_value"
}

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
# GIT_NO_LAZY_FETCH is retained as defense in depth. It is not the compatibility
# boundary: Git before 2.45 ignores it for ordinary object access. Every trust
# object walk separately checks the 2.45 minimum and supplies the supported
# --no-lazy-fetch command-line option, so a missing local object fails closed
# instead of consulting a promisor remote before the unattended gate passes.
#
# Commit-graph files are also repository-controlled object metadata. A forged
# parent entry can make a replacement root appear to descend from the root an
# operator previously acknowledged, even though the commit object itself has
# no parent. Disable that acceleration at the command-line config scope for
# every trust-boundary Git query. That scope outranks repository config, so a
# target cannot turn commit-graph use back on through its own config.
_unattended_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_IMPLICIT_WORK_TREE GIT_PREFIX
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
  unset GIT_SHALLOW_FILE GIT_REPLACE_REF_BASE GIT_QUARANTINE_PATH
  unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  unset GIT_CEILING_DIRECTORIES
  unset GIT_DISCOVERY_ACROSS_FILESYSTEM
  GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 \
    GIT_GRAFT_FILE=/dev/null GIT_SHALLOW_FILE=/dev/null \
    command git -c core.commitGraph=false "$@"
)

# Record the executable's advertised version and accept only versions with a
# reliable client-side no-lazy-fetch control. Keep parsing deliberately narrow:
# an unrecognized vendor spelling is unavailable, never optimistically safe.
_unattended_git_supports_local_object_walk() {
  local output version major rest minor
  ORCHID_UNATTENDED_GIT_VERSION=""
  _unattended_capture_line output _unattended_git --version 2>/dev/null \
    || return 1
  case "$output" in
    "git version "*) version="${output#git version }"; version="${version%% *}" ;;
    *) return 1 ;;
  esac
  ORCHID_UNATTENDED_GIT_VERSION="$version"
  major="${version%%.*}"
  rest="${version#*.}"
  [ "$rest" != "$version" ] || return 1
  minor="${rest%%.*}"
  case "$major" in ''|*[!0-9]*) return 1 ;; esac
  case "$minor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 45 ]; }
}

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
  _unattended_capture_line home _unattended_repo_canon "$HOME" || return 1
  orchid_dir="$home/.orchid"
  if [ -e "$orchid_dir" ] || [ -L "$orchid_dir" ]; then
    [ -d "$orchid_dir" ] || return 1
    _unattended_capture_line orchid_dir _unattended_repo_canon "$orchid_dir" \
      || return 1
  fi
  trust_dir="$orchid_dir/unattended-trust"
  if [ -e "$trust_dir" ] || [ -L "$trust_dir" ]; then
    [ -d "$trust_dir" ] || return 1
    _unattended_capture_line trust_dir _unattended_repo_canon "$trust_dir" \
      || return 1
  fi
  printf '%s\n' "$trust_dir"
}

_unattended_git_common_dir() {
  local repo="$1" raw
  _unattended_capture_line raw _unattended_git -C "$repo" \
    rev-parse --git-common-dir 2>/dev/null || return 1
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
  _unattended_capture_line path _unattended_repo_canon "$1" || return 1
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

# Git's .git/gitdir pointer files contain one path value plus a final framing
# newline, but the value itself may contain newlines because those are valid
# filesystem bytes. Read the whole file, remove exactly one Git-added newline,
# and add exactly one output newline for _unattended_capture_line to remove.
_unattended_read_git_path_file() {
  local path="$1" value
  _unattended_capture_stdout value cat "$path" 2>/dev/null || return 1
  case "$value" in *$'\n') value="${value%$'\n'}" ;; esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
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
  _unattended_capture_line parent _unattended_repo_canon "$parent" || return 1
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
    _unattended_capture_line ORCHID_UNATTENDED_WORKTREE_GITDIR \
      _unattended_repo_canon "$marker" || return 1
    return 0
  fi
  if [ ! -f "$marker" ]; then
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree has no regular on-disk .git marker"
    return 1
  fi

  _unattended_capture_line line _unattended_read_git_path_file "$marker" || {
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
  _unattended_capture_line gitdir _unattended_resolve_directory "$root" "$raw" || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree .git pointer is inaccessible"
    return 1
  }
  [ ! -L "$gitdir/gitdir" ] && [ -f "$gitdir/gitdir" ] || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the caller-selected worktree is not backed by a linked-worktree registration"
    return 1
  }
  _unattended_capture_line registered_line \
    _unattended_read_git_path_file "$gitdir/gitdir" || {
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="the linked-worktree registration is malformed"
    return 1
  }
  _unattended_capture_line registered \
    _unattended_resolve_git_marker "$gitdir" "$registered_line" || {
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

# Resolve Git's common directory from the already-validated on-disk marker,
# without asking Git to inspect repository objects or enumerate repository
# state. A normal checkout's .git directory is itself the common directory.
# A linked worktree's administrative gitdir contains Git's `commondir`
# pointer. This is the identity-only path used before Orchid knows whether a
# machine-local acknowledgement candidate exists.
_unattended_common_dir_from_marker() {
  local raw
  case "$ORCHID_UNATTENDED_WORKTREE_MARKER_KIND" in
    directory)
      printf '%s\n' "$ORCHID_UNATTENDED_WORKTREE_GITDIR"
      ;;
    linked)
      [ ! -L "$ORCHID_UNATTENDED_WORKTREE_GITDIR/commondir" ] \
        && [ -f "$ORCHID_UNATTENDED_WORKTREE_GITDIR/commondir" ] \
        || return 1
      _unattended_capture_line raw _unattended_read_git_path_file \
        "$ORCHID_UNATTENDED_WORKTREE_GITDIR/commondir" || return 1
      _unattended_resolve_directory \
        "$ORCHID_UNATTENDED_WORKTREE_GITDIR" "$raw"
      ;;
    *)
      return 1
      ;;
  esac
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
      _unattended_capture_line worktrees \
        _unattended_repo_canon "$common/worktrees" || {
        ORCHID_UNATTENDED_BOUNDARY_DETAIL="Git's common directory has no linked-worktree registry"
        return 1
      }
      _unattended_capture_line gitdir_parent \
        _unattended_repo_canon "$ORCHID_UNATTENDED_WORKTREE_GITDIR/.." \
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
        _unattended_capture_line registered _unattended_repo_canon "$raw" \
          || continue
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

_unattended_trust_store_basic_validate() {
  local repo="$1" worktree_root="$2" common="$3" trust_dir="$4"
  if _unattended_path_within "$repo" "$trust_dir" \
     || _unattended_path_within "$worktree_root" "$trust_dir" \
     || _unattended_path_within "$common" "$trust_dir"; then
    ORCHID_UNATTENDED_BOUNDARY_DETAIL="machine-local unattended-trust directory resolves inside the target repository; use an operator HOME outside the target"
    return 1
  fi
}

_unattended_trust_store_validate() {
  local repo="$1" worktree_root="$2" common="$3" trust_dir="$4"
  _unattended_trust_store_basic_validate \
    "$repo" "$worktree_root" "$common" "$trust_dir" || return 1
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

# Replace one already-staged regular file without following a destination
# symlink. Used to publish the outside repository-incarnation anchor link.
_unattended_file_atomic_replace() {
  local source="$1" destination="$2"
  if [ -d "$destination" ] && [ ! -L "$destination" ]; then
    return 1
  fi
  if mv -h "$source" "$destination" 2>/dev/null; then
    return 0
  fi
  mv -T "$source" "$destination" 2>/dev/null
}

# Rotate the incarnation anchor used by a newly authored acknowledgement. The
# repository-side witness is Git's normally stable, untracked common-directory
# `description` file; the command never writes its contents or adds an in-repo
# trust record. Its second link lives beside the machine-local JSON record.
# Deleting/replacing the repository cannot make the witness inode reusable
# while that outside link exists. A copied common directory and a fresh clone
# get different witness inodes. Requiring a hard link also fails closed when
# HOME and the repository are on different filesystems, where portable shell
# tools cannot provide the non-reuse guarantee.
_unattended_identity_anchor_rotate() {
  local anchor="$1" witness="$2"
  local stage ident meta links existing_anchor_ident=""
  ORCHID_UNATTENDED_ANCHOR_ERROR=""

  [ ! -L "$witness" ] && [ -f "$witness" ] && [ -O "$witness" ] || {
    ORCHID_UNATTENDED_ANCHOR_ERROR="Git's common-directory identity witness must be an operator-owned regular file"
    return 1
  }
  _unattended_capture_line ident _unattended_fs_identity "$witness" || {
    ORCHID_UNATTENDED_ANCHOR_ERROR="cannot inspect Git's common-directory identity witness"
    return 1
  }
  _unattended_capture_line meta \
    _unattended_file_security_metadata "$witness" || {
    ORCHID_UNATTENDED_ANCHOR_ERROR="cannot inspect Git's common-directory identity witness permissions"
    return 1
  }
  links="${meta%% *}"
  if [ $((8#${meta#* } & 022)) -ne 0 ]; then
    ORCHID_UNATTENDED_ANCHOR_ERROR="Git's common-directory identity witness is writable by group or other"
    return 1
  fi
  if [ ! -L "$anchor" ] && [ -f "$anchor" ]; then
    _unattended_capture_line existing_anchor_ident \
      _unattended_fs_identity "$anchor" || existing_anchor_ident=""
  fi
  if [ "$links" = 2 ] && [ "$existing_anchor_ident" = "$ident" ]; then
    ORCHID_UNATTENDED_ANCHOR_DEVICE="${ident%% *}"
    ORCHID_UNATTENDED_ANCHOR_INODE="${ident#* }"
    return 0
  fi
  if [ "$links" != 1 ]; then
    ORCHID_UNATTENDED_ANCHOR_ERROR="Git's common-directory identity witness has an unexpected hard-link alias"
    return 1
  fi

  stage="$(mktemp -d "$ORCHID_UNATTENDED_TRUST_DIR/.identity-stage.XXXXXX")" \
    || {
      ORCHID_UNATTENDED_ANCHOR_ERROR="cannot stage the machine-local repository-incarnation anchor"
      return 1
    }
  if ! ln "$witness" "$stage/anchor" 2>/dev/null; then
    rmdir "$stage" 2>/dev/null || true
    ORCHID_UNATTENDED_ANCHOR_ERROR="the trust store and Git common directory must be on the same filesystem to create a non-reusable identity anchor"
    return 1
  fi

  if ! _unattended_file_atomic_replace "$stage/anchor" "$anchor"; then
    rm -f "$stage/anchor"
    rmdir "$stage" 2>/dev/null || true
    ORCHID_UNATTENDED_ANCHOR_ERROR="cannot publish the machine-local repository-incarnation anchor"
    return 1
  fi
  rmdir "$stage" 2>/dev/null || true

  ORCHID_UNATTENDED_ANCHOR_DEVICE="${ident%% *}"
  ORCHID_UNATTENDED_ANCHOR_INODE="${ident#* }"
  return 0
}

# Validate both names of the non-reusable anchor and bind them to the identity
# recorded by the operator-authored JSON. The exact link count ensures neither
# tracked data nor an additional local alias can stand in for the pair.
_unattended_identity_anchor_matches() {
  local anchor="$ORCHID_UNATTENDED_IDENTITY_ANCHOR"
  local witness="$ORCHID_UNATTENDED_IDENTITY_WITNESS"
  local anchor_ident witness_ident anchor_meta witness_meta
  [ ! -L "$anchor" ] && [ -f "$anchor" ] && [ -O "$anchor" ] || return 1
  [ ! -L "$witness" ] && [ -f "$witness" ] && [ -O "$witness" ] || return 1
  _unattended_capture_line anchor_ident _unattended_fs_identity "$anchor" \
    || return 1
  _unattended_capture_line witness_ident _unattended_fs_identity "$witness" \
    || return 1
  [ "$anchor_ident" = "$witness_ident" ] || return 1
  [ "$anchor_ident" = "$ORCHID_UNATTENDED_RECORDED_ANCHOR_DEVICE $ORCHID_UNATTENDED_RECORDED_ANCHOR_INODE" ] \
    || return 1
  _unattended_capture_line anchor_meta \
    _unattended_file_security_metadata "$anchor" || return 1
  _unattended_capture_line witness_meta \
    _unattended_file_security_metadata "$witness" || return 1
  [ "$anchor_meta" = "$witness_meta" ] || return 1
  [ "${anchor_meta%% *}" = 2 ] || return 1
  [ $((8#${anchor_meta#* } & 022)) -eq 0 ]
}

_unattended_json_value() {
  local json="$1" expression="$2"
  printf '%s' "$json" | jq -j "$expression"
}

_unattended_oid_is_valid() {
  local oid="$1" expected_length="$2"
  [ "${#oid}" -eq "$expected_length" ] || return 1
  case "$oid" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

# A candidate record must carry a non-empty, consistently hashed set of
# lowercase object IDs before it is eligible to trigger any object walk.
# Exact object-format and root equality are established later by the batched
# verifier; this check only rejects structurally impossible machine-local
# records without consulting repository history.
_unattended_root_set_is_structurally_valid() {
  local remaining="$1" oid oid_length=0
  [ -n "$remaining" ] || return 1
  case "$remaining" in ,*|*,|*,,*) return 1 ;; esac
  while :; do
    case "$remaining" in
      *,*)
        oid="${remaining%%,*}"
        remaining="${remaining#*,}"
        ;;
      *)
        oid="$remaining"
        remaining=""
        ;;
    esac
    case "${#oid}" in
      40|64) ;;
      *) return 1 ;;
    esac
    case "$oid" in *[!0-9a-f]*) return 1 ;; esac
    if [ "$oid_length" -eq 0 ]; then
      oid_length="${#oid}"
    elif [ "${#oid}" -ne "$oid_length" ]; then
      return 1
    fi
    [ -n "$remaining" ] || break
  done
}

_unattended_join_root_set() (
  set -o pipefail
  printf '%s' "$1" \
    | LC_ALL=C sort \
    | awk 'NF { if (roots != "") roots=roots ","; roots=roots $0 }
           END { if (roots != "") print roots }'
)

# _unattended_root_commit <result-variable> <repo>
#
# Derive the root set only from one complete local parent walk whose every
# reachable commit is independently re-hashed. Git normally trusts that loose
# bytes found below objects/aa/bb... belong to the advertised aa... OID;
# rev-list consequently keeps reporting that filename OID even if the payload
# was replaced with a different valid commit. Comparing cat-file's exact
# payload with hash-object's result closes that gap before a root can be
# accepted or recorded.
#
# `--parents` makes the same complete walk provide the roots and the list of
# graph-contributing commits. Commit-graph acceleration, replacement refs,
# grafts, shallow boundaries, repository-selection overrides, and lazy fetches
# remain disabled by _unattended_git. The success sentinel prevents a partial
# rev-list result from being mistaken for a complete history when a local
# object is missing or unreadable.
# The worker runs in a subshell so its signal/EXIT cleanup cannot replace a
# caller's traps. Its single protocol line is framed by
# _unattended_root_commit below. Scratch data is always outside the target and
# is removed before the worker returns.
_unattended_root_commit_compute() (
  local repo="$1" object_format oid_length head line commit parents parent oid
  local roots="" joined="" commit_count=0 complete=0
  local stage="" manifest batch_oids batch_output batch_paths batch_hashes
  local temp_base
  local batch_count processed=0 expected advertised object_type object_size
  local object_extra payload remaining chunk_size chunk separator actual extra
  local sentinel="orchid-unattended-commit-walk-complete-v1"
  local LC_ALL=C
  ORCHID_UNATTENDED_COMMIT_STAGE=""

  _unattended_commit_compute_cleanup() {
    local cleanup_stage="${ORCHID_UNATTENDED_COMMIT_STAGE:-}"
    [ -n "$cleanup_stage" ] || return 0
    rm -f "$cleanup_stage/commits.oids" "$cleanup_stage/batch.oids" \
      "$cleanup_stage/batch.output" "$cleanup_stage/batch.paths" \
      "$cleanup_stage/batch.hashes" "$cleanup_stage"/payload.* \
      2>/dev/null || true
    rmdir "$cleanup_stage" 2>/dev/null || true
  }
  _unattended_commit_compute_fail() {
    printf 'error\t%s\n' "$1"
    exit 0
  }
  trap '_unattended_commit_compute_cleanup' EXIT
  trap 'exit 1' HUP INT TERM

  # Check again at the exact object-walk boundary. The earlier inspection gate
  # produces the usual version diagnostic; this repeated guard also covers a
  # changed PATH/executable during a concurrent inspection.
  if ! _unattended_git_supports_local_object_walk; then
    _unattended_commit_compute_fail \
      "side-effect-free commit verification requires Git $ORCHID_UNATTENDED_OBJECT_WALK_GIT_MIN or newer (found ${ORCHID_UNATTENDED_GIT_VERSION:-an unrecognized version})"
  fi
  if ! _unattended_capture_line object_format \
      _unattended_git --no-lazy-fetch -C "$repo" \
        rev-parse --show-object-format=storage 2>/dev/null; then
    _unattended_commit_compute_fail \
      "cannot determine the repository object format before verifying commit history"
  fi
  case "$object_format" in
    sha1) oid_length=40 ;;
    sha256) oid_length=64 ;;
    *)
      _unattended_commit_compute_fail \
        "unsupported repository object format '${object_format:-unknown}' while verifying commit history"
      ;;
  esac
  if ! _unattended_capture_line head \
      _unattended_git --no-lazy-fetch -C "$repo" \
        rev-parse --verify HEAD 2>/dev/null \
     || ! _unattended_oid_is_valid "$head" "$oid_length"; then
    _unattended_commit_compute_fail \
      "cannot resolve a valid local HEAD object before verifying commit history"
  fi

  # /tmp is operator-machine scratch state, not a caller-selectable repository
  # path. Refuse the unusual case where it is itself inside any worktree
  # registered under this common directory, so read-only trust inspection
  # never creates even transient repository-controlled content.
  if ! _unattended_capture_line temp_base _unattended_repo_canon /tmp \
     || ! _unattended_trust_store_outside_registered_worktrees \
       "$ORCHID_UNATTENDED_COMMON_DIR" "$temp_base"; then
    _unattended_commit_compute_fail \
      "cannot batch-verify commit payloads because /tmp is inside a registered worktree"
  fi
  stage="$(mktemp -d "$temp_base/orchid-unattended-commit-verify.XXXXXX")" \
    || _unattended_commit_compute_fail \
      "cannot create private scratch space for batched commit verification"
  ORCHID_UNATTENDED_COMMIT_STAGE="$stage"
  [ ! -L "$stage" ] && [ -d "$stage" ] && [ -O "$stage" ] \
    || _unattended_commit_compute_fail \
      "private scratch space for batched commit verification is not canonical"

  manifest="$stage/commits.oids"
  batch_oids="$stage/batch.oids"
  batch_output="$stage/batch.output"
  batch_paths="$stage/batch.paths"
  batch_hashes="$stage/batch.hashes"
  : >"$manifest" || _unattended_commit_compute_fail \
    "cannot stage the reachable commit manifest for verification"
  exec 3>"$manifest" || _unattended_commit_compute_fail \
    "cannot open the reachable commit manifest for verification"

  # Bind the walk to the exact HEAD resolved above. A later lightweight final
  # identity check compares symbolic HEAD with this OID, so one inspection
  # cannot combine a graph from one ref state with identity from another.
  while IFS= read -r line; do
    if [ "$line" = "$sentinel" ]; then
      complete=1
      continue
    fi
    if [ "$complete" -eq 1 ] || [ -z "$line" ]; then
      _unattended_commit_compute_fail \
        "Git returned a malformed reachable-commit graph while deriving the unattended trust root"
    fi

    commit="${line%% *}"
    if [ "$line" = "$commit" ]; then
      parents=""
    else
      parents="${line#* }"
    fi
    if ! _unattended_oid_is_valid "$commit" "$oid_length"; then
      _unattended_commit_compute_fail \
        "Git returned an invalid commit OID while deriving the unattended trust root"
    fi

    # Validate every advertised edge as well as every commit row. A successful
    # complete rev-list walk emits each reachable parent as its own row, whose
    # exact stored payload is re-hashed in the bounded batches below.
    parent="$parents"
    while [ -n "$parent" ]; do
      case "$parent" in
        *" "*)
          oid="${parent%% *}"
          parent="${parent#* }"
          ;;
        *)
          oid="$parent"
          parent=""
          ;;
      esac
      if ! _unattended_oid_is_valid "$oid" "$oid_length"; then
        _unattended_commit_compute_fail \
          "Git returned an invalid parent OID for commit $commit while deriving the unattended trust root"
      fi
    done

    printf '%s\n' "$commit" >&3 || _unattended_commit_compute_fail \
      "cannot stage advertised commit $commit for verification"
    if [ -z "$parents" ]; then
      roots="${roots}${commit}"$'\n'
    fi
    commit_count=$((commit_count + 1))
  done < <(
    if _unattended_git --no-lazy-fetch -C "$repo" \
        rev-list --parents "$head" 2>/dev/null; then
      printf '%s\n' "$sentinel"
    fi
  )
  exec 3>&-

  if [ "$complete" -ne 1 ]; then
    _unattended_commit_compute_fail \
      "cannot completely walk locally reachable commit history; a commit may be missing or unreadable"
  fi
  if [ "$commit_count" -eq 0 ] || [ -z "$roots" ]; then
    _unattended_commit_compute_fail \
      "repository has no reachable root commit at HEAD"
  fi
  if ! _unattended_capture_line joined _unattended_join_root_set "$roots" \
     || [ -z "$joined" ]; then
    _unattended_commit_compute_fail \
      "cannot normalize the verified repository root commit set"
  fi

  # cat-file --batch emits one size-framed raw payload per advertised OID.
  # Bash 3.2's read -n, under the byte-oriented C locale, stages those payloads
  # without one cat-file process per commit. hash-object --stdin-paths then
  # re-hashes every staged payload in the same order with the repository's
  # storage hash. Valid commit objects cannot contain NUL; encountering one
  # shortens read -d '' and therefore fails closed before hashing.
  exec 3<"$manifest" || _unattended_commit_compute_fail \
    "cannot reopen the reachable commit manifest for verification"
  while [ "$processed" -lt "$commit_count" ]; do
    : >"$batch_oids" || _unattended_commit_compute_fail \
      "cannot stage a commit-verification batch"
    exec 4>"$batch_oids" || _unattended_commit_compute_fail \
      "cannot open a commit-verification batch"
    batch_count=0
    while [ "$batch_count" -lt "$ORCHID_UNATTENDED_COMMIT_BATCH_SIZE" ] \
          && IFS= read -r expected <&3; do
      printf '%s\n' "$expected" >&4 || _unattended_commit_compute_fail \
        "cannot stage advertised commit $expected for batched verification"
      batch_count=$((batch_count + 1))
    done
    exec 4>&-
    [ "$batch_count" -gt 0 ] || _unattended_commit_compute_fail \
      "the reachable commit manifest ended before every commit was verified"

    if ! _unattended_git --no-lazy-fetch -C "$repo" \
        cat-file --batch='%(objectname) %(objecttype) %(objectsize)' \
        <"$batch_oids" >"$batch_output" 2>/dev/null; then
      _unattended_commit_compute_fail \
        "cannot locally read a batch of advertised commit objects; an object may be missing or unavailable without a fetch"
    fi

    : >"$batch_paths" || _unattended_commit_compute_fail \
      "cannot stage commit payload paths for batched hashing"
    exec 4<"$batch_oids" 5<"$batch_output" 6>"$batch_paths" \
      || _unattended_commit_compute_fail \
        "cannot parse locally read commit payloads"
    batch_count=0
    while IFS= read -r expected <&4; do
      advertised=""
      object_type=""
      object_size=""
      object_extra=""
      if ! IFS=' ' read -r advertised object_type object_size object_extra <&5 \
         || [ -n "$object_extra" ] \
         || [ "$advertised" != "$expected" ] \
         || [ "$object_type" != commit ]; then
        _unattended_commit_compute_fail \
          "cannot locally read advertised commit object $expected; the object may be missing, malformed, or unavailable without a fetch"
      fi
      case "$object_size" in
        ''|*[!0-9]*)
          _unattended_commit_compute_fail \
            "Git returned an invalid payload size for advertised commit $expected"
          ;;
      esac
      [ "${#object_size}" -le 18 ] || _unattended_commit_compute_fail \
        "Git returned an unsupported payload size for advertised commit $expected"

      batch_count=$((batch_count + 1))
      payload="$stage/payload.$batch_count"
      : >"$payload" || _unattended_commit_compute_fail \
        "cannot stage the exact payload for advertised commit $expected"
      exec 7>"$payload" || _unattended_commit_compute_fail \
        "cannot open exact-payload scratch space for advertised commit $expected"
      remaining=$((10#$object_size))
      while [ "$remaining" -gt 0 ]; do
        if [ "$remaining" -gt 65536 ]; then
          chunk_size=65536
        else
          chunk_size="$remaining"
        fi
        chunk=""
        IFS= read -r -d '' -n "$chunk_size" chunk <&5 || true
        if [ "${#chunk}" -ne "$chunk_size" ]; then
          _unattended_commit_compute_fail \
            "Git returned a truncated or malformed payload for advertised commit $expected"
        fi
        printf '%s' "$chunk" >&7 || _unattended_commit_compute_fail \
          "cannot stage the complete payload for advertised commit $expected"
        remaining=$((remaining - chunk_size))
      done
      exec 7>&-
      separator=invalid
      if ! IFS= read -r separator <&5 || [ -n "$separator" ]; then
        _unattended_commit_compute_fail \
          "Git returned invalid batch framing for advertised commit $expected"
      fi
      printf '%s\n' "$payload" >&6 || _unattended_commit_compute_fail \
        "cannot stage the hash input for advertised commit $expected"
    done
    extra=""
    if IFS= read -r extra <&5 || [ -n "$extra" ]; then
      _unattended_commit_compute_fail \
        "Git returned extra data after the requested commit payload batch"
    fi
    exec 4<&- 5<&- 6>&-
    [ "$batch_count" -gt 0 ] || _unattended_commit_compute_fail \
      "Git returned no locally readable commit payloads for a non-empty batch"

    if ! _unattended_git --no-lazy-fetch -C "$repo" \
        hash-object --no-filters -t commit --stdin-paths \
        <"$batch_paths" >"$batch_hashes" 2>/dev/null; then
      _unattended_commit_compute_fail \
        "cannot locally hash a batch of advertised commit payloads; an object may be malformed"
    fi

    exec 4<"$batch_oids" 5<"$batch_hashes" \
      || _unattended_commit_compute_fail \
        "cannot compare advertised and recomputed commit object IDs"
    while IFS= read -r expected <&4; do
      actual=""
      if ! IFS= read -r actual <&5; then
        _unattended_commit_compute_fail \
          "Git returned too few recomputed commit object IDs"
      fi
      if ! _unattended_oid_is_valid "$actual" "$oid_length"; then
        _unattended_commit_compute_fail \
          "Git returned an invalid recomputed object ID for advertised commit $expected"
      fi
      if [ "$actual" != "$expected" ]; then
        _unattended_commit_compute_fail \
          "commit object integrity mismatch: advertised OID $expected hashes to $actual; repair or replace the repository before acknowledging unattended trust"
      fi
      processed=$((processed + 1))
    done
    extra=""
    if IFS= read -r extra <&5 || [ -n "$extra" ]; then
      _unattended_commit_compute_fail \
        "Git returned too many recomputed commit object IDs"
    fi
    exec 4<&- 5<&-
  done
  extra=""
  if IFS= read -r extra <&3 || [ -n "$extra" ]; then
    _unattended_commit_compute_fail \
      "the reachable commit manifest changed during verification"
  fi
  exec 3<&-

  printf 'ok\t%s\t%s\n' "$joined" "$head"
)

_unattended_root_commit() {
  local target="$1" repo="$2" result payload root head
  ORCHID_UNATTENDED_ROOT_ERROR=""
  ORCHID_UNATTENDED_HEAD_OID=""

  if ! _unattended_capture_line result \
      _unattended_root_commit_compute "$repo"; then
    ORCHID_UNATTENDED_ROOT_ERROR="cannot complete batched local commit verification"
    return 1
  fi
  case "$result" in
    error$'\t'*)
      ORCHID_UNATTENDED_ROOT_ERROR="${result#error$'\t'}"
      return 1
      ;;
    ok$'\t'*$'\t'*)
      payload="${result#ok$'\t'}"
      root="${payload%%$'\t'*}"
      head="${payload#*$'\t'}"
      [ -n "$root" ] && [ -n "$head" ] && [ "$head" != "$payload" ] || {
        ORCHID_UNATTENDED_ROOT_ERROR="batched commit verification returned a malformed result"
        return 1
      }
      printf -v "$target" '%s' "$root"
      ORCHID_UNATTENDED_HEAD_OID="$head"
      ;;
    *)
      ORCHID_UNATTENDED_ROOT_ERROR="batched commit verification returned a malformed result"
      return 1
      ;;
  esac
}

_unattended_one_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' '
}

# Re-check the repository facts after a complete history verification. This
# cannot make a shell script immune to a hostile concurrent rename after the
# gate returns, but it prevents one operation from silently combining a common
# directory/device observation from one repository state with root history
# read from a replacement state. The acknowledgement-only path calls this
# before publishing a record; ordinary inspection additionally rechecks the
# machine-local incarnation anchor below.
_unattended_repository_identity_still_matches() {
  local common ident head worktree expected_kind expected_gitdir
  # Fail before any target-repository Git query if the executable changed to a
  # version that cannot guarantee local-only object access.
  _unattended_git_supports_local_object_walk || return 1
  expected_kind="$ORCHID_UNATTENDED_WORKTREE_MARKER_KIND"
  expected_gitdir="$ORCHID_UNATTENDED_WORKTREE_GITDIR"
  _unattended_capture_line worktree \
    _unattended_worktree_root "$ORCHID_UNATTENDED_REPO" || return 1
  [ "$worktree" = "$ORCHID_UNATTENDED_WORKTREE_ROOT" ] || return 1
  _unattended_worktree_marker_validate "$worktree" || return 1
  [ "$ORCHID_UNATTENDED_WORKTREE_MARKER_KIND" = "$expected_kind" ] || return 1
  [ "$ORCHID_UNATTENDED_WORKTREE_GITDIR" = "$expected_gitdir" ] || return 1
  _unattended_capture_line common \
    _unattended_git_common_dir "$ORCHID_UNATTENDED_REPO" || return 1
  [ "$common" = "$ORCHID_UNATTENDED_COMMON_DIR" ] || return 1
  _unattended_worktree_marker_matches_common "$common" || return 1
  _unattended_trust_store_validate \
    "$ORCHID_UNATTENDED_REPO" "$worktree" "$common" \
    "$ORCHID_UNATTENDED_TRUST_DIR" || return 1
  _unattended_capture_line ident _unattended_fs_identity "$common" || return 1
  [ "$ident" = "$ORCHID_UNATTENDED_DEVICE $ORCHID_UNATTENDED_INODE" ] || return 1
  _unattended_capture_line head \
    _unattended_git --no-lazy-fetch -C "$ORCHID_UNATTENDED_REPO" \
      rev-parse --verify HEAD 2>/dev/null || return 1
  [ "$head" = "$ORCHID_UNATTENDED_HEAD_OID" ] || return 1
}

_unattended_identity_still_matches() {
  _unattended_repository_identity_still_matches || return 1
  _unattended_identity_anchor_matches
}

# Confirm that the exact regular file parsed below is still present and
# byte-equivalent immediately before allowing the gate. The JSON is passed as
# an in-shell string (not re-derived field by field), so concurrent replacement
# cannot produce a trusted decision assembled from multiple record versions.
_unattended_record_still_matches() {
  local path="$1" expected_ident="$2" expected_meta="$3" expected_json="$4"
  local ident meta json
  [ ! -L "$path" ] && [ -f "$path" ] && [ -O "$path" ] || return 1
  _unattended_capture_line ident _unattended_fs_identity "$path" || return 1
  [ "$ident" = "$expected_ident" ] || return 1
  _unattended_capture_line meta \
    _unattended_file_security_metadata "$path" || return 1
  [ "$meta" = "$expected_meta" ] || return 1
  _unattended_capture_stdout json cat "$path" 2>/dev/null || return 1
  [ "$json" = "$expected_json" ]
}

_unattended_trust_reset() {
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
  ORCHID_UNATTENDED_ROOT_STATUS=unavailable
  ORCHID_UNATTENDED_HEAD_OID=""
  ORCHID_UNATTENDED_TRUST_DIR=""
  ORCHID_UNATTENDED_RECORD=""
  ORCHID_UNATTENDED_IDENTITY_ANCHOR=""
  ORCHID_UNATTENDED_IDENTITY_WITNESS=""
  ORCHID_UNATTENDED_ANCHOR_DEVICE=""
  ORCHID_UNATTENDED_ANCHOR_INODE=""
  ORCHID_UNATTENDED_GIT_VERSION=""
  ORCHID_UNATTENDED_ROOT_ERROR=""
  ORCHID_UNATTENDED_BOUNDARY_DETAIL=""
  ORCHID_UNATTENDED_RECORD_EXISTS=0
  ORCHID_UNATTENDED_RECORD_LOADED=0
  ORCHID_UNATTENDED_RECORDED_REPO=""
  ORCHID_UNATTENDED_RECORDED_COMMON_DIR=""
  ORCHID_UNATTENDED_RECORDED_SCHEMA=""
  ORCHID_UNATTENDED_RECORDED_KIND=""
  ORCHID_UNATTENDED_RECORDED_DEVICE=""
  ORCHID_UNATTENDED_RECORDED_INODE=""
  ORCHID_UNATTENDED_RECORDED_ANCHOR_DEVICE=""
  ORCHID_UNATTENDED_RECORDED_ANCHOR_INODE=""
  ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT=""
  ORCHID_UNATTENDED_RECORDED_POLICY_VERSION=""
  ORCHID_UNATTENDED_ACKNOWLEDGED_AT=""
  ORCHID_UNATTENDED_REASON=""
}

# Resolve only the caller-selected worktree, its physical common-directory
# identity, and the corresponding machine-local record names. This phase uses
# filesystem metadata and constant-size Git administrative pointer files; it
# does not run Git, enumerate registered worktrees, inspect refs or objects,
# walk history, create scratch space, or write anything.
_unattended_trust_identity_discover() {
  local repo_in="$1" ident trust_dir trust_dir_physical

  if ! _unattended_capture_line ORCHID_UNATTENDED_REPO \
      _unattended_repo_canon "$repo_in"; then
    ORCHID_UNATTENDED_DETAIL="target is not an accessible directory"
    return 1
  fi
  if ! _unattended_capture_line ORCHID_UNATTENDED_WORKTREE_ROOT \
      _unattended_worktree_root "$ORCHID_UNATTENDED_REPO"; then
    ORCHID_UNATTENDED_DETAIL="target is not inside a Git worktree with an on-disk .git marker"
    return 1
  fi
  if ! _unattended_worktree_marker_validate "$ORCHID_UNATTENDED_WORKTREE_ROOT"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-caller-selected worktree marker is invalid}"
    return 1
  fi
  if ! _unattended_capture_line ORCHID_UNATTENDED_COMMON_DIR \
      _unattended_common_dir_from_marker; then
    ORCHID_UNATTENDED_DETAIL="target is not a Git worktree with an accessible common directory"
    return 1
  fi
  if _unattended_path_within "$ORCHID_UNATTENDED_COMMON_DIR" "$ORCHID_UNATTENDED_REPO"; then
    ORCHID_UNATTENDED_DETAIL="target worktree resolves inside its Git common directory"
    return 1
  fi
  if ! _unattended_worktree_marker_matches_common "$ORCHID_UNATTENDED_COMMON_DIR"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-caller-selected worktree is not registered under its Git common directory}"
    return 1
  fi
  if ! _unattended_capture_line trust_dir _unattended_trust_dir \
     || ! _unattended_capture_line trust_dir_physical \
       _unattended_trust_dir_physical; then
    ORCHID_UNATTENDED_DETAIL="machine-local unattended-trust directory is unavailable"
    return 1
  fi
  ORCHID_UNATTENDED_TRUST_DIR="$trust_dir_physical"
  if ! _unattended_trust_store_basic_validate \
      "$ORCHID_UNATTENDED_REPO" "$ORCHID_UNATTENDED_WORKTREE_ROOT" \
      "$ORCHID_UNATTENDED_COMMON_DIR" "$trust_dir_physical"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-machine-local unattended-trust directory placement is unsafe}"
    return 1
  fi
  if ! _unattended_capture_line ident \
      _unattended_fs_identity "$ORCHID_UNATTENDED_COMMON_DIR"; then
    ORCHID_UNATTENDED_DETAIL="cannot read Git common-directory filesystem identity"
    return 1
  fi
  ORCHID_UNATTENDED_DEVICE="${ident%% *}"
  ORCHID_UNATTENDED_INODE="${ident#* }"
  if [ -z "$ORCHID_UNATTENDED_DEVICE" ] || [ -z "$ORCHID_UNATTENDED_INODE" ] \
     || [ "$ORCHID_UNATTENDED_INODE" = "$ident" ]; then
    ORCHID_UNATTENDED_DETAIL="cannot parse Git common-directory filesystem identity"
    return 1
  fi

  ORCHID_UNATTENDED_RECORD="$ORCHID_UNATTENDED_TRUST_DIR/$ORCHID_UNATTENDED_DEVICE-$ORCHID_UNATTENDED_INODE.json"
  ORCHID_UNATTENDED_IDENTITY_ANCHOR="$ORCHID_UNATTENDED_TRUST_DIR/$ORCHID_UNATTENDED_DEVICE-$ORCHID_UNATTENDED_INODE.anchor"
  ORCHID_UNATTENDED_IDENTITY_WITNESS="$ORCHID_UNATTENDED_COMMON_DIR/$ORCHID_UNATTENDED_IDENTITY_WITNESS_NAME"
  ORCHID_UNATTENDED_ROOT_STATUS=pending
  ORCHID_UNATTENDED_DETAIL="repository identity resolved; root verification is pending an eligible machine-local acknowledgement"
  return 0
}

# unattended_trust_inspect <repo>
#
# Always returns zero and populates the ORCHID_UNATTENDED_* globals below.
# Callers can therefore report an unavailable/untrusted state without
# tripping their own `set -e`; only unattended_trust_require turns it into a
# refusal. This function is read-only.
unattended_trust_inspect() {
  local repo_in="$1" rec_schema rec_kind rec_device rec_inode rec_policy rec_root
  local rec_anchor_device rec_anchor_inode
  local rec_meta rec_links rec_mode record_ident record_json
  local provenance_valid=0

  _unattended_trust_reset
  _unattended_trust_identity_discover "$repo_in" || return 0
  if [ ! -e "$ORCHID_UNATTENDED_RECORD" ] && [ ! -L "$ORCHID_UNATTENDED_RECORD" ]; then
    ORCHID_UNATTENDED_STATE=untrusted
    ORCHID_UNATTENDED_DETAIL="no machine-local acknowledgement for this Git common-directory identity; root verification was not attempted"
    return 0
  fi
  ORCHID_UNATTENDED_RECORD_EXISTS=1
  # Git 2.44 and older cannot reliably prohibit lazy object fetching. Check
  # the executable only after finding an identity-keyed candidate, but before
  # any Git command targets the repository.
  if ! _unattended_git_supports_local_object_walk; then
    ORCHID_UNATTENDED_ROOT_STATUS=unavailable
    ORCHID_UNATTENDED_DETAIL="side-effect-free unattended trust inspection requires Git $ORCHID_UNATTENDED_OBJECT_WALK_GIT_MIN or newer (found ${ORCHID_UNATTENDED_GIT_VERSION:-an unrecognized version}); no target-repository Git query or history object walk was attempted"
    return 0
  fi
  # Only an existing candidate justifies enumerating linked worktrees. This
  # keeps the ordinary no-record denial constant-size while preserving the
  # rule that machine-local state cannot live in any sibling checkout.
  if ! _unattended_trust_store_validate \
      "$ORCHID_UNATTENDED_REPO" "$ORCHID_UNATTENDED_WORKTREE_ROOT" \
      "$ORCHID_UNATTENDED_COMMON_DIR" "$ORCHID_UNATTENDED_TRUST_DIR"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-machine-local unattended-trust directory placement is unsafe}"
    return 0
  fi
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
  if ! _unattended_capture_line rec_meta \
      _unattended_file_security_metadata "$ORCHID_UNATTENDED_RECORD"; then
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
  if ! _unattended_capture_line record_ident \
      _unattended_fs_identity "$ORCHID_UNATTENDED_RECORD" \
     || ! _unattended_capture_stdout record_json \
       cat "$ORCHID_UNATTENDED_RECORD" 2>/dev/null; then
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
    and (.identity_anchor_device | type == "string")
    and (.identity_anchor_inode | type == "string")
    and (.root_commit | type == "string")
  ' >/dev/null 2>&1; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record is malformed"
    return 0
  fi

  if ! _unattended_capture_stdout rec_schema \
      _unattended_json_value "$record_json" '.schema // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_kind \
       _unattended_json_value "$record_json" '.kind // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_device \
       _unattended_json_value "$record_json" '.git_common_device // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_inode \
       _unattended_json_value "$record_json" '.git_common_inode // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_anchor_device \
       _unattended_json_value "$record_json" '.identity_anchor_device // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_anchor_inode \
       _unattended_json_value "$record_json" '.identity_anchor_inode // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_policy \
       _unattended_json_value "$record_json" '.policy_version // ""' 2>/dev/null \
     || ! _unattended_capture_stdout rec_root \
       _unattended_json_value "$record_json" '.root_commit // ""' 2>/dev/null \
     || ! _unattended_capture_stdout ORCHID_UNATTENDED_RECORDED_REPO \
       _unattended_json_value "$record_json" '.acknowledged_repo // ""' 2>/dev/null \
     || ! _unattended_capture_stdout ORCHID_UNATTENDED_RECORDED_COMMON_DIR \
       _unattended_json_value "$record_json" '.git_common_dir // ""' 2>/dev/null \
     || ! _unattended_capture_stdout ORCHID_UNATTENDED_ACKNOWLEDGED_AT \
       _unattended_json_value "$record_json" '.acknowledged_at // ""' 2>/dev/null \
     || ! _unattended_capture_stdout ORCHID_UNATTENDED_REASON \
       _unattended_json_value "$record_json" '.reason // ""' 2>/dev/null; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="cannot decode machine-local acknowledgement record"
    return 0
  fi
  ORCHID_UNATTENDED_RECORDED_SCHEMA="$rec_schema"
  ORCHID_UNATTENDED_RECORDED_KIND="$rec_kind"
  ORCHID_UNATTENDED_RECORDED_DEVICE="$rec_device"
  ORCHID_UNATTENDED_RECORDED_INODE="$rec_inode"
  ORCHID_UNATTENDED_RECORDED_ANCHOR_DEVICE="$rec_anchor_device"
  ORCHID_UNATTENDED_RECORDED_ANCHOR_INODE="$rec_anchor_inode"
  ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT="$rec_root"
  ORCHID_UNATTENDED_RECORDED_POLICY_VERSION="$rec_policy"
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
    return 0
  elif [ "$rec_kind" != unattended ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record kind is invalid (recorded ${rec_kind:-missing}, expected unattended)"
    return 0
  elif [ "$rec_device" != "$ORCHID_UNATTENDED_DEVICE" ] \
       || [ "$rec_inode" != "$ORCHID_UNATTENDED_INODE" ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record identity does not match its Git common directory"
    return 0
  elif [ "$rec_policy" != "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION" ]; then
    ORCHID_UNATTENDED_STATE=mismatch
    ORCHID_UNATTENDED_DETAIL="trust-policy version changed (recorded ${rec_policy:-missing}, current $ORCHID_UNATTENDED_TRUST_POLICY_VERSION)"
    return 0
  elif [ "$provenance_valid" -ne 1 ]; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record is missing operator provenance"
    return 0
  elif ! _unattended_root_set_is_structurally_valid "$rec_root"; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="acknowledgement record contains a malformed root commit set"
    return 0
  fi
  case "$rec_anchor_device:$rec_anchor_inode" in
    :*|*:|*[!0-9:]*|*:*:*)
      ORCHID_UNATTENDED_STATE=invalid
      ORCHID_UNATTENDED_DETAIL="acknowledgement record contains a malformed incarnation-anchor identity"
      return 0
      ;;
  esac
  if ! _unattended_identity_anchor_matches; then
    ORCHID_UNATTENDED_STATE=mismatch
    ORCHID_UNATTENDED_DETAIL="repository incarnation anchor is missing or does not match the machine-local acknowledgement"
    return 0
  fi
  if ! _unattended_record_still_matches "$ORCHID_UNATTENDED_RECORD" \
      "$record_ident" "$rec_meta" "$record_json"; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record changed during inspection; retry"
    return 0
  fi

  # The candidate is now safe, current-policy, identity-bound, structurally
  # complete, and backed by its non-reusable machine-local anchor. Only this
  # state may pay for exact-payload/root verification.
  ORCHID_UNATTENDED_ROOT_STATUS=unavailable
  if ! _unattended_root_commit ORCHID_UNATTENDED_ROOT_COMMIT \
      "$ORCHID_UNATTENDED_REPO"; then
    ORCHID_UNATTENDED_ROOT_COMMIT=""
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_ROOT_ERROR:-cannot verify locally reachable commit history}"
    return 0
  fi
  if [ -z "$ORCHID_UNATTENDED_ROOT_COMMIT" ]; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_ROOT_ERROR:-repository has no reachable root commit at HEAD}"
    return 0
  fi
  ORCHID_UNATTENDED_ROOT_STATUS=verified

  if [ "$rec_root" != "$ORCHID_UNATTENDED_ROOT_COMMIT" ]; then
    ORCHID_UNATTENDED_STATE=mismatch
    ORCHID_UNATTENDED_DETAIL="repository root commit changed (recorded ${rec_root:-missing}, current $ORCHID_UNATTENDED_ROOT_COMMIT)"
  elif ! _unattended_record_still_matches "$ORCHID_UNATTENDED_RECORD" \
      "$record_ident" "$rec_meta" "$record_json"; then
    ORCHID_UNATTENDED_STATE=invalid
    ORCHID_UNATTENDED_DETAIL="machine-local acknowledgement record changed during history verification; retry"
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
  local reason root_display
  root_display="${ORCHID_UNATTENDED_ROOT_COMMIT:-${ORCHID_UNATTENDED_ROOT_STATUS:-unavailable}}"
  if [ "$ORCHID_UNATTENDED_STATE" = trusted ]; then
    reason="$(_unattended_one_line "$ORCHID_UNATTENDED_REASON")"
    printf 'allowed — acknowledged at %s; reason: %s; git-common identity %s:%s; incarnation anchor %s:%s; root %s; policy %s; record %s\n' \
      "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT" "$reason" \
      "$ORCHID_UNATTENDED_DEVICE" "$ORCHID_UNATTENDED_INODE" \
      "$ORCHID_UNATTENDED_RECORDED_ANCHOR_DEVICE" \
      "$ORCHID_UNATTENDED_RECORDED_ANCHOR_INODE" \
      "$ORCHID_UNATTENDED_ROOT_COMMIT" "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION" \
      "$ORCHID_UNATTENDED_RECORD"
  else
    printf 'denied — %s; git-common identity %s:%s; root %s; policy %s' \
      "$ORCHID_UNATTENDED_DETAIL" \
      "${ORCHID_UNATTENDED_DEVICE:-unavailable}" "${ORCHID_UNATTENDED_INODE:-unavailable}" \
      "$root_display" "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION"
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
  local trust_label root_display
  unattended_trust_inspect "$1"
  root_display="${ORCHID_UNATTENDED_ROOT_COMMIT:-${ORCHID_UNATTENDED_ROOT_STATUS:-unavailable}}"
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
  printf 'root_commit: %s\n' "$root_display"
  printf 'policy_version: %s\n' "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION"
  printf 'record: %s\n' "${ORCHID_UNATTENDED_RECORD:-none}"
  printf 'identity_anchor: %s\n' "${ORCHID_UNATTENDED_IDENTITY_ANCHOR:-none}"
  printf 'identity_witness: %s\n' "${ORCHID_UNATTENDED_IDENTITY_WITNESS:-none}"
  if [ "${ORCHID_UNATTENDED_RECORD_LOADED:-0}" -eq 1 ]; then
    printf 'recorded_schema: %s\n' "$ORCHID_UNATTENDED_RECORDED_SCHEMA"
    printf 'recorded_kind: %s\n' "$ORCHID_UNATTENDED_RECORDED_KIND"
    printf 'acknowledged_at: %s\n' "$ORCHID_UNATTENDED_ACKNOWLEDGED_AT"
    printf 'acknowledged_repo: %s\n' "$ORCHID_UNATTENDED_RECORDED_REPO"
    printf 'acknowledged_git_common_dir: %s\n' "$ORCHID_UNATTENDED_RECORDED_COMMON_DIR"
    printf 'recorded_git_common_device: %s\n' "$ORCHID_UNATTENDED_RECORDED_DEVICE"
    printf 'recorded_git_common_inode: %s\n' "$ORCHID_UNATTENDED_RECORDED_INODE"
    printf 'recorded_identity_anchor_device: %s\n' "$ORCHID_UNATTENDED_RECORDED_ANCHOR_DEVICE"
    printf 'recorded_identity_anchor_inode: %s\n' "$ORCHID_UNATTENDED_RECORDED_ANCHOR_INODE"
    printf 'recorded_root_commit: %s\n' "$ORCHID_UNATTENDED_RECORDED_ROOT_COMMIT"
    printf 'recorded_policy_version: %s\n' "$ORCHID_UNATTENDED_RECORDED_POLICY_VERSION"
    printf 'reason: %s\n' "$(_unattended_one_line "$ORCHID_UNATTENDED_REASON")"
  fi
}

# The explicit operator acknowledgement is the sole no-record path allowed to
# perform complete local history verification. Keep that authority in a
# dedicated helper so ordinary inspection cannot accidentally regain an
# eager object walk. No trust-store file is created or changed here.
_unattended_trust_acknowledgement_verify() {
  local repo="$1"
  _unattended_trust_reset
  _unattended_trust_identity_discover "$repo" || return 1
  if ! _unattended_git_supports_local_object_walk; then
    ORCHID_UNATTENDED_ROOT_STATUS=unavailable
    ORCHID_UNATTENDED_DETAIL="local acknowledgement verification requires Git $ORCHID_UNATTENDED_OBJECT_WALK_GIT_MIN or newer (found ${ORCHID_UNATTENDED_GIT_VERSION:-an unrecognized version})"
    return 1
  fi
  if ! _unattended_trust_store_validate \
      "$ORCHID_UNATTENDED_REPO" "$ORCHID_UNATTENDED_WORKTREE_ROOT" \
      "$ORCHID_UNATTENDED_COMMON_DIR" "$ORCHID_UNATTENDED_TRUST_DIR"; then
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_BOUNDARY_DETAIL:-machine-local unattended-trust directory placement is unsafe}"
    return 1
  fi
  ORCHID_UNATTENDED_ROOT_STATUS=unavailable
  if ! _unattended_root_commit ORCHID_UNATTENDED_ROOT_COMMIT \
      "$ORCHID_UNATTENDED_REPO"; then
    ORCHID_UNATTENDED_ROOT_COMMIT=""
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_ROOT_ERROR:-cannot verify locally reachable commit history}"
    return 1
  fi
  [ -n "$ORCHID_UNATTENDED_ROOT_COMMIT" ] || {
    ORCHID_UNATTENDED_DETAIL="${ORCHID_UNATTENDED_ROOT_ERROR:-repository has no reachable root commit at HEAD}"
    return 1
  }
  ORCHID_UNATTENDED_ROOT_STATUS=verified
  if ! _unattended_repository_identity_still_matches; then
    ORCHID_UNATTENDED_DETAIL="repository identity changed during acknowledgement verification; retry"
    return 1
  fi
}

unattended_trust_acknowledge() {
  local repo="$1" reason="$2" acknowledged_at dir trust_dir_after
  printf '%s' "$reason" | LC_ALL=C grep -q '[^[:space:]]' \
    || orchid_die "unattended trust requires a non-empty --reason"

  _unattended_trust_acknowledgement_verify "$repo" \
    || orchid_die "cannot acknowledge unattended execution: $ORCHID_UNATTENDED_DETAIL"
  acknowledged_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dir="$ORCHID_UNATTENDED_TRUST_DIR"
  (
    umask 077
    mkdir -p "$dir"
    # Resolve the just-created store again and retain the verified repository
    # HEAD/identity globals. A symlink or repository replacement raced into
    # either path must fail before the anchor or JSON record is published.
    _unattended_capture_line trust_dir_after \
      _unattended_trust_dir_physical \
      || orchid_die "cannot acknowledge unattended execution: machine-local unattended-trust directory became unavailable"
    [ "$trust_dir_after" = "$dir" ] \
      || orchid_die "cannot acknowledge unattended execution: machine-local unattended-trust directory changed during verification"
    _unattended_repository_identity_still_matches \
      || orchid_die "cannot acknowledge unattended execution: repository identity changed after history verification; retry"

    [ ! -L "$ORCHID_UNATTENDED_RECORD" ] \
      || orchid_die "cannot acknowledge unattended execution: acknowledgement record path is a symbolic link; revoke it first"
    if [ -e "$ORCHID_UNATTENDED_RECORD" ] && [ ! -f "$ORCHID_UNATTENDED_RECORD" ]; then
      orchid_die "cannot acknowledge unattended execution: acknowledgement record path is not a regular file"
    fi
    if ! _unattended_identity_anchor_rotate \
        "$ORCHID_UNATTENDED_IDENTITY_ANCHOR" \
        "$ORCHID_UNATTENDED_IDENTITY_WITNESS"; then
      orchid_die "cannot acknowledge unattended execution: $ORCHID_UNATTENDED_ANCHOR_ERROR"
    fi
    _unattended_repository_identity_still_matches \
      || orchid_die "cannot acknowledge unattended execution: repository identity changed before the acknowledgement record was written; retry"
    if ! jq -n \
      --argjson schema "$ORCHID_UNATTENDED_TRUST_RECORD_SCHEMA" \
      --argjson policy_version "$ORCHID_UNATTENDED_TRUST_POLICY_VERSION" \
      --arg acknowledged_at "$acknowledged_at" \
      --arg reason "$reason" \
      --arg acknowledged_repo "$ORCHID_UNATTENDED_REPO" \
      --arg git_common_dir "$ORCHID_UNATTENDED_COMMON_DIR" \
      --arg git_common_device "$ORCHID_UNATTENDED_DEVICE" \
      --arg git_common_inode "$ORCHID_UNATTENDED_INODE" \
      --arg identity_anchor_device "$ORCHID_UNATTENDED_ANCHOR_DEVICE" \
      --arg identity_anchor_inode "$ORCHID_UNATTENDED_ANCHOR_INODE" \
      --arg root_commit "$ORCHID_UNATTENDED_ROOT_COMMIT" \
      '{schema:$schema, kind:"unattended", policy_version:$policy_version,
        acknowledged_at:$acknowledged_at, reason:$reason,
        acknowledged_repo:$acknowledged_repo, git_common_dir:$git_common_dir,
        git_common_device:$git_common_device, git_common_inode:$git_common_inode,
        identity_anchor_device:$identity_anchor_device,
        identity_anchor_inode:$identity_anchor_inode,
        root_commit:$root_commit}' \
      | _unattended_record_atomic_write "$ORCHID_UNATTENDED_RECORD"; then
      orchid_die "cannot write the machine-local unattended acknowledgement record"
    fi
  )
  unattended_trust_inspect "$repo"
  [ "$ORCHID_UNATTENDED_STATE" = trusted ] \
    || orchid_die "failed to persist unattended trust: $ORCHID_UNATTENDED_DETAIL"
}

unattended_trust_revoke() {
  local repo="$1" removed=0
  unattended_trust_inspect "$repo"
  [ "$ORCHID_UNATTENDED_STATE" != unavailable ] \
    || orchid_die "cannot revoke unattended trust: $ORCHID_UNATTENDED_DETAIL"

  # Only the outside link is Orchid state. Removing it leaves Git's existing
  # common-directory witness and its contents untouched.
  if [ -L "$ORCHID_UNATTENDED_IDENTITY_ANCHOR" ] \
     || [ -f "$ORCHID_UNATTENDED_IDENTITY_ANCHOR" ]; then
    rm -f "$ORCHID_UNATTENDED_IDENTITY_ANCHOR"
    removed=1
  elif [ -e "$ORCHID_UNATTENDED_IDENTITY_ANCHOR" ]; then
    orchid_die "cannot revoke unattended trust: identity anchor path is not a file"
  fi
  if [ -L "$ORCHID_UNATTENDED_RECORD" ] || [ -f "$ORCHID_UNATTENDED_RECORD" ]; then
    rm -f "$ORCHID_UNATTENDED_RECORD"
    removed=1
  fi
  if [ -e "$ORCHID_UNATTENDED_RECORD" ]; then
    orchid_die "cannot revoke unattended trust: acknowledgement record path is not a file"
  fi
  [ "$removed" -eq 1 ]
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
