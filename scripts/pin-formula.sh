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

die() { echo "pin-formula: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: scripts/pin-formula.sh [--check]

Computes the SHA-256 of the release archive scripts/release.sh would build
from the repository's current content (tracked plus untracked, non-ignored
files, snapshotted through a temporary Git index) and pins it into
Formula/orchid.rb.

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

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "not a Git checkout: $ROOT"
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

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchid-pin-formula.XXXXXX")"

# Snapshot the current content through a TEMPORARY index so the checksum
# describes exactly what a commit made right now would release, without
# touching the real index or requiring a clean tree. .orchid/ is excluded
# from the snapshot outright (it is export-ignored anyway, so it can never
# affect the archive, and live run state may hold files Git cannot index).
# `git archive` reads .gitattributes from the archived tree itself, so
# Formula/ stays export-ignored in the snapshot -- the fixed-point property
# this whole script relies on.
snapshot_index="$TMP_ROOT/index"
GIT_INDEX_FILE="$snapshot_index" git -C "$ROOT" read-tree --empty
GIT_INDEX_FILE="$snapshot_index" git -C "$ROOT" add -A -- . ':(exclude).orchid'
tree="$(GIT_INDEX_FILE="$snapshot_index" git -C "$ROOT" write-tree)"

archive="$TMP_ROOT/$archive_name"
git -C "$ROOT" archive --format=tar.gz \
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
