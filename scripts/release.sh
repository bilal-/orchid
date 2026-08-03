#!/usr/bin/env bash
# Build and verify a local release archive. This script never pushes,
# publishes, uploads, or reads payload files from the working tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""
OUTPUT=""
BASH_BIN="${BASH:-/bin/bash}"
TMP_ROOT=""

die() { echo "release: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
usage: scripts/release.sh --tag vX.Y.Z --output DIR [--bash /path/to/bash]

Builds and fully verifies local artifacts from the exact clean tagged commit.
It does not push, publish, upload, or modify the tag.
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
    --tag) [ "$#" -ge 2 ] || die "--tag requires a value"; TAG="$2"; shift 2 ;;
    --tag=*) TAG="${1#--tag=}"; shift ;;
    --output) [ "$#" -ge 2 ] || die "--output requires a directory"; OUTPUT="$2"; shift 2 ;;
    --output=*) OUTPUT="${1#--output=}"; shift ;;
    --bash) [ "$#" -ge 2 ] || die "--bash requires a path"; BASH_BIN="$2"; shift 2 ;;
    --bash=*) BASH_BIN="${1#--bash=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TAG" ] || { usage >&2; die "--tag is required"; }
[ -n "$OUTPUT" ] || { usage >&2; die "--output is required"; }
case "$TAG" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "tag must be an immutable semantic-version tag such as v1.2.3 (moving refs such as main or HEAD are refused)" ;;
esac
printf '%s\n' "$TAG" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || die "tag must be exactly vMAJOR.MINOR.PATCH"
[ -x "$BASH_BIN" ] || die "Bash interpreter is not executable: $BASH_BIN"
if ! "$BASH_BIN" -c '[ -n "${BASH_VERSION:-}" ] && (( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) ))'; then
  die "--bash must name Bash 3.2 or newer: $BASH_BIN"
fi

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "not a Git checkout: $ROOT"
[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ] \
  || die "working tree and index must be clean"

tag_ref="refs/tags/$TAG"
tag_object_before="$(git -C "$ROOT" rev-parse --verify "$tag_ref" 2>/dev/null)" \
  || die "tag does not exist: $TAG"
commit="$(git -C "$ROOT" rev-parse --verify "$tag_ref^{commit}" 2>/dev/null)" \
  || die "tag does not resolve to a commit: $TAG"
head_commit="$(git -C "$ROOT" rev-parse --verify HEAD)"
[ "$head_commit" = "$commit" ] || die "HEAD $head_commit is not tagged commit $commit ($TAG)"

git_file() {
  git -C "$ROOT" show "$commit:$1"
}
metadata_value() {
  local key="$1" values count
  values="$(git_file release/metadata.conf | sed -n "s/^${key}=//p")"
  # Count matching records in the Git object itself. Counting only non-empty
  # extracted values would incorrectly accept `key=value` plus a second,
  # empty `key=` record after command substitution trimmed its newline.
  count="$(git_file release/metadata.conf | awk -v prefix="${key}=" '
    index($0, prefix) == 1 { n++ }
    END { print n + 0 }
  ')"
  [ "$count" -eq 1 ] || die "release/metadata.conf must contain exactly one $key value"
  printf '%s\n' "$values"
}

version="$(metadata_value version)"
metadata_tag="$(metadata_value tag)"
archive_name="$(metadata_value archive)"
prefix="$(metadata_value prefix)"
installer_ref="$(metadata_value installer_ref)"
[ "$TAG" = "v$version" ] || die "tag/version mismatch: $TAG vs $version"
[ "$metadata_tag" = "$TAG" ] || die "release metadata tag mismatch: $metadata_tag vs $TAG"
[ "$archive_name" = "orchid-$version.tar.gz" ] || die "release archive name mismatch: $archive_name"
[ "$prefix" = "orchid-$version/" ] || die "release archive prefix mismatch: $prefix"
[ "$installer_ref" = "$TAG" ] || die "installer_ref mismatch: $installer_ref vs $TAG"

common_version="$(git_file lib/common.sh | sed -n 's/^ORCHID_VERSION="\([^"]*\)"$/\1/p')"
[ "$common_version" = "$version" ] || die "lib/common.sh version mismatch: $common_version vs $version"
install_version="$(git_file install.sh | sed -n 's/^ORCHID_INSTALL_VERSION="\([^"]*\)"$/\1/p')"
install_ref="$(git_file install.sh | sed -n 's/^ORCHID_INSTALL_REF="\([^"]*\)"$/\1/p')"
install_repository="$(git_file install.sh | sed -n 's/^ORCHID_INSTALL_REPOSITORY="\([^"]*\)"$/\1/p')"
[ "$install_version" = "$version" ] || die "installer version mismatch: $install_version vs $version"
[ "$install_ref" = "$TAG" ] || die "installer ref mismatch: $install_ref vs $TAG"
expected_repository="https://github.com/bilal-/orchid.git"
[ "$install_repository" = "$expected_repository" ] \
  || die "installer repository mismatch: $install_repository vs $expected_repository"

formula="$(git_file Formula/orchid.rb)"
formula_version="$(printf '%s\n' "$formula" | sed -n 's/^[[:space:]]*version "\([^"]*\)"$/\1/p')"
formula_url="$(printf '%s\n' "$formula" | sed -n 's/^[[:space:]]*url "\([^"]*\)"$/\1/p')"
formula_sha="$(printf '%s\n' "$formula" | sed -n 's/^[[:space:]]*sha256 "\([0-9a-f]*\)"$/\1/p')"
expected_url="https://github.com/bilal-/orchid/releases/download/$TAG/$archive_name"
[ "$formula_version" = "$version" ] || die "formula version mismatch: $formula_version vs $version"
[ "$formula_url" = "$expected_url" ] || die "formula URL mismatch: $formula_url"
printf '%s\n' "$formula_sha" | grep -Eq '^[0-9a-f]{64}$' || die "formula checksum is missing or a placeholder"

surface="$(for path in README.md docs/install.md docs/quickstart.md Formula/orchid.rb install.sh release/metadata.conf; do git_file "$path"; done)"
if printf '%s\n' "$surface" | grep -Eq 'VERSION-PLACEHOLDER|SHA256-PLACEHOLDER|<!--[[:space:]]*SCREENSHOT:'; then
  die "release-facing metadata still contains a placeholder"
fi

mkdir -p "$OUTPUT"
[ ! -e "$OUTPUT/$archive_name" ] || die "refusing to overwrite $OUTPUT/$archive_name"
[ ! -e "$OUTPUT/$archive_name.sha256" ] || die "refusing to overwrite $OUTPUT/$archive_name.sha256"
[ ! -e "$OUTPUT/Formula/orchid.rb" ] || die "refusing to overwrite $OUTPUT/Formula/orchid.rb"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchid-release.XXXXXX")"
archive_a="$TMP_ROOT/archive-a.tar.gz"
archive_b="$TMP_ROOT/archive-b.tar.gz"
treeish="$commit^{tree}"
archive_from_commit() {
  local destination="$1"
  git -C "$ROOT" archive --format=tar.gz \
    --mtime=1970-01-01T00:00:00Z --prefix="$prefix" \
    --output="$destination" "$treeish"
}

archive_from_commit "$archive_a"
archive_from_commit "$archive_b"
cmp -s "$archive_a" "$archive_b" || die "archive rebuild differs byte-for-byte"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}
archive_sha="$(sha256_file "$archive_a")"
rebuilt_sha="$(sha256_file "$archive_b")"
[ "$archive_sha" = "$rebuilt_sha" ] || die "archive rebuild checksum mismatch"
[ "$archive_sha" = "$formula_sha" ] || die "formula checksum mismatch: $formula_sha vs $archive_sha"

list="$TMP_ROOT/archive.list"
tar -tzf "$archive_a" > "$list"
[ -s "$list" ] || die "archive is empty"
while IFS= read -r entry; do
  case "$entry" in "$prefix"*) ;; *) die "archive entry has wrong prefix: $entry" ;; esac
  case "/$entry/" in *'/../'*|*'/./'*) die "unsafe archive entry: $entry" ;; esac
done < "$list"
for required in bin/orchid install.sh lib/common.sh release/metadata.conf scripts/ci-local.sh; do
  grep -qxF "$prefix$required" "$list" || die "archive is missing $required"
done
grep -qF "$prefix.orchid/" "$list" && die "archive must not contain .orchid run state"
grep -qF "${prefix}Formula/" "$list" && die "archive must not contain the tap formula"

extract_parent="$TMP_ROOT/extracted"
mkdir -p "$extract_parent"
tar -xzf "$archive_a" -C "$extract_parent"
extract_root="$extract_parent/${prefix%/}"
[ -d "$extract_root" ] || die "archive did not extract to $prefix"
(
  cd "$extract_root"
  ORCHID_RELEASE_ARCHIVE_TEST=1 "$BASH_BIN" scripts/ci-local.sh --bash "$BASH_BIN"
) || die "tests failed inside the release archive"

verify_tag_unchanged() {
  local tag_object_after commit_after
  tag_object_after="$(git -C "$ROOT" rev-parse --verify "$tag_ref" 2>/dev/null)" \
    || die "tag disappeared during release verification: $TAG"
  commit_after="$(git -C "$ROOT" rev-parse --verify "$tag_ref^{commit}" 2>/dev/null)" \
    || die "tag stopped resolving to a commit: $TAG"
  [ "$tag_object_after" = "$tag_object_before" ] && [ "$commit_after" = "$commit" ] \
    || die "tag moved during release verification: $TAG"
}

# Resolve the ref again after every build/check. Both the tag object and its
# peeled commit must remain identical, so a concurrently moved tag fails.
verify_tag_unchanged

cp "$archive_a" "$OUTPUT/$archive_name"
printf '%s  %s\n' "$archive_sha" "$archive_name" > "$OUTPUT/$archive_name.sha256"
mkdir -p "$OUTPUT/Formula"
printf '%s\n' "$formula" > "$OUTPUT/Formula/orchid.rb"
verify_tag_unchanged
echo "release verified: $TAG -> $commit"
echo "archive: $OUTPUT/$archive_name"
echo "sha256: $archive_sha"
