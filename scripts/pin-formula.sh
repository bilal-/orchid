#!/usr/bin/env bash
# Compute the deterministic release-archive checksum for the repository's
# CURRENT content and pin it into Formula/orchid.rb, or verify it with
# --check. This is the maintenance half of the fixed point scripts/release.sh
# verifies at tag time: Formula/ (and .orchid/) are export-ignored, so
# writing the archive's checksum into the formula never changes the archive
# itself. This script rewrites only Formula/orchid.rb, and never pushes,
# publishes, tags, or touches the real Git index.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=pin
TMP_ROOT=""
GIT_BIN=""
CLEAN_TMPDIR=""

die() { echo "pin-formula: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: scripts/pin-formula.sh [--check]

Computes the SHA-256 of the release archive scripts/release.sh would build
from the repository's current content (tracked plus untracked, non-ignored
files, snapshotted through a disposable isolated Git repository) and pins it
into Formula/orchid.rb.

--check verifies the pinned value instead of rewriting it, exiting nonzero
and printing both checksums when the formula is stale.
EOF
}
cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "${TMP_ROOT:?}"
  fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

GIT_BIN="$(command -v git)" || die "git is required"
CLEAN_TMPDIR="${TMPDIR:-/tmp}"
[ -x "$GIT_BIN" ] || die "git is not executable: $GIT_BIN"

# Discovery may read the source repository's own config, but never ambient
# system/global/environment config. Snapshotting and archiving below use a
# separate repository and are isolated from local config as well.
source_git() {
  env -i \
    PATH="$PATH" \
    TMPDIR="$CLEAN_TMPDIR" \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    "$GIT_BIN" -C "$ROOT" "$@"
}

source_git rev-parse --git-dir >/dev/null 2>&1 || die "not a Git checkout: $ROOT"
[ -f "$ROOT/Formula/orchid.rb" ] \
  || die "Formula/orchid.rb not found (run from a source checkout, not an extracted archive)"
[ -f "$ROOT/release/metadata.conf" ] || die "release/metadata.conf not found"

metadata_value() {
  local key="$1" values count
  values="$(sed -n "s/^${key}=//p" "$ROOT/release/metadata.conf")"
  count="$(awk -v prefix="${key}=" '
    index($0, prefix) == 1 { n++ }
    END { print n + 0 }
  ' "$ROOT/release/metadata.conf")"
  [ "$count" -eq 1 ] || die "release/metadata.conf must contain exactly one $key value"
  printf '%s\n' "$values"
}

version="$(metadata_value version)"
metadata_tag="$(metadata_value tag)"
archive_name="$(metadata_value archive)"
prefix="$(metadata_value prefix)"
[ "$metadata_tag" = "v$version" ] || die "release metadata tag/version mismatch: $metadata_tag vs $version"
[ "$archive_name" = "orchid-$version.tar.gz" ] || die "release archive name mismatch: $archive_name"
[ "$prefix" = "orchid-$version/" ] || die "release archive prefix mismatch: $prefix"

formula_version="$(sed -n 's/^[[:space:]]*version "\([^"]*\)"$/\1/p' "$ROOT/Formula/orchid.rb")"
formula_url="$(sed -n 's/^[[:space:]]*url "\([^"]*\)"$/\1/p' "$ROOT/Formula/orchid.rb")"
formula_sha="$(sed -n 's/^[[:space:]]*sha256 "\([^"]*\)"$/\1/p' "$ROOT/Formula/orchid.rb")"
expected_url="https://github.com/bilal-/orchid/releases/download/$metadata_tag/$archive_name"
[ "$formula_version" = "$version" ] || die "formula version mismatch: $formula_version vs $version"
[ "$formula_url" = "$expected_url" ] || die "formula URL mismatch: $formula_url vs $expected_url"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

TMP_ROOT="$(mktemp -d "$CLEAN_TMPDIR/orchid-pin-formula.XXXXXX")"

# Snapshot the current content through a TEMPORARY repository so the checksum
# describes exactly what a commit made right now would release, without
# touching the real index or requiring a clean tree. .orchid/ is excluded
# from the snapshot outright (it is export-ignored anyway, so it can never
# affect the archive, and live run state may hold files Git cannot index).
# The source repo's config and info/attributes are intentionally not visible;
# only .gitignore/.gitattributes content captured from the worktree can affect
# the snapshot and archive. Formula/ thus stays export-ignored -- the fixed-
# point property this whole script relies on.
repository_common_dir="$(source_git rev-parse --git-common-dir)"
case "$repository_common_dir" in
  /*) ;;
  *) repository_common_dir="$ROOT/$repository_common_dir" ;;
esac
repository_objects="$repository_common_dir/objects"
[ -d "$repository_objects" ] || die "Git object directory not found: $repository_objects"
snapshot_git_dir="$TMP_ROOT/snapshot.git"
empty_template="$TMP_ROOT/empty-template"
mkdir -p "$empty_template"
env -i \
  PATH="$PATH" \
  TMPDIR="$CLEAN_TMPDIR" \
  LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_ATTR_NOSYSTEM=1 \
  "$GIT_BIN" init -q --bare --template="$empty_template" "$snapshot_git_dir"

# Keep the index, new objects, config, and info directory under the disposable
# temp root, exposing existing objects only as a read-only alternate. env -i
# also removes GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS and other injected Git
# controls. This works with read-only source metadata and leaves it untouched.
snapshot_git() {
  env -i \
    PATH="$PATH" \
    TMPDIR="$CLEAN_TMPDIR" \
    LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_DIR="$snapshot_git_dir" \
    GIT_WORK_TREE="$ROOT" \
    GIT_INDEX_FILE="$snapshot_git_dir/index" \
    GIT_OBJECT_DIRECTORY="$snapshot_git_dir/objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$repository_objects" \
    "$GIT_BIN" -C "$ROOT" "$@"
}
snapshot_git read-tree --empty
snapshot_git add -A -- . ':(exclude).git' ':(exclude).orchid'
tree="$(snapshot_git write-tree)"

archive="$TMP_ROOT/$archive_name"
# This disposable repository cannot see ambient or source-repository archive
# configuration, so tar.gz selects Git's default magic `git archive gzip`
# command and its internal gzip implementation. The formula checksum therefore
# cannot depend on a host gzip found on PATH, and no tar.<format>.command
# override can replace the built-in compressor.
snapshot_git archive --format=tar.gz \
  --mtime=1970-01-01T00:00:00Z --prefix="$prefix" \
  --output="$archive" "$tree"
archive_sha="$(sha256_file "$archive")"

if [ "$MODE" = check ]; then
  if [ "$archive_sha" = "$formula_sha" ]; then
    echo "pin-formula: Formula/orchid.rb checksum is fresh ($archive_sha)"
    exit 0
  fi
  echo "pin-formula: Formula/orchid.rb checksum is STALE for the current content" >&2
  echo "pin-formula:   pinned:   ${formula_sha:-<none>}" >&2
  echo "pin-formula:   expected: $archive_sha" >&2
  echo "pin-formula: run scripts/pin-formula.sh and commit the formula change (Formula/ is export-ignored, so the archive bytes stay identical)" >&2
  exit 1
fi

if [ "$archive_sha" = "$formula_sha" ]; then
  echo "pin-formula: Formula/orchid.rb is already fresh ($archive_sha)"
  exit 0
fi

rewritten="$TMP_ROOT/orchid.rb"
awk -v sha="$archive_sha" '
  /^[[:space:]]*sha256 ".*"$/ { sub(/".*"/, "\"" sha "\""); n++ }
  { print }
  END { exit n == 1 ? 0 : 1 }
' "$ROOT/Formula/orchid.rb" > "$rewritten" \
  || die "Formula/orchid.rb must contain exactly one sha256 line"
mv "$rewritten" "$ROOT/Formula/orchid.rb"
echo "pin-formula: pinned $archive_sha into Formula/orchid.rb"
echo "pin-formula: commit this formula-only change; Formula/ is export-ignored, so the release archive bytes are unchanged"
