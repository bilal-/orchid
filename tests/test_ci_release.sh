#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

CI="$REPO_ROOT/scripts/ci-local.sh"
RELEASE="$REPO_ROOT/scripts/release.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

[ -f "$CI" ] || fail "scripts/ci-local.sh missing"
[ -f "$RELEASE" ] || fail "scripts/release.sh missing"
[ -f "$WORKFLOW" ] || fail ".github/workflows/ci.yml missing"

# Content-based discovery must cover every layout in which this repository
# ships shell: root files, templates, extensionless executables, runners,
# adapters, tests, libraries, and the CI/release helpers themselves.
shell_list="$("$BASH" "$CI" --bash "$BASH" --list-shell)" || fail "ci-local --list-shell failed"
for expected in \
  install.sh \
  templates/pre-push.sh \
  bin/orchid \
  runners/orchid-tick \
  plugins/engines/codex/run \
  plugins/notify/openclaw/send \
  tests/helpers.sh \
  lib/common.sh \
  scripts/ci-local.sh \
  scripts/pin-formula.sh \
  scripts/release.sh; do
  printf '%s\n' "$shell_list" | grep -qxF "$expected" \
    || fail "shell discovery omitted $expected"
done
printf '%s\n' "$shell_list" | grep -q '^\.orchid/' \
  && fail "shell discovery must never inspect run state under .orchid"

# Exercise discovery against layouts and shebang forms rather than proving
# only that today's known files happen to be present. The copied gate has no
# Git metadata, so this also covers the extracted-archive find fallback.
discovery_fixture="$WORK/discovery-fixture"
mkdir -p "$discovery_fixture"/{plugins/example,scripts,skills/example/helpers,templates,tests}
cp "$CI" "$discovery_fixture/scripts/ci-local.sh"
printf '%s\n' '#!/usr/bin/env sh' 'exit 0' > "$discovery_fixture/root-helper"
printf '%s\n' '#!/usr/bin/env -S bash -e' 'exit 0' > "$discovery_fixture/skills/example/helpers/check"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$discovery_fixture/plugins/example/run"
printf '%s\n' 'exit 0' > "$discovery_fixture/templates/hook.sh"
printf '%s\n' '#!/usr/bin/env python3' 'pass' > "$discovery_fixture/tests/not-shell"
chmod +x "$discovery_fixture/root-helper" \
  "$discovery_fixture/skills/example/helpers/check" \
  "$discovery_fixture/plugins/example/run"
fixture_shell_list="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" --list-shell)" \
  || fail "archive-layout shell discovery failed"
for expected in root-helper plugins/example/run skills/example/helpers/check templates/hook.sh; do
  printf '%s\n' "$fixture_shell_list" | grep -qxF "$expected" \
    || fail "archive-layout shell discovery omitted $expected"
done
printf '%s\n' "$fixture_shell_list" | grep -qxF tests/not-shell \
  && fail "shell discovery included a non-shell executable"

lint_disable='# shellcheck '
lint_disable="${lint_disable}disable=SC2034"
printf '%s\n' '#!/usr/bin/env bash' "$lint_disable" 'unused=1' \
  > "$discovery_fixture/tests/undocumented-exception.sh"
rc=0
lint_policy_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "CI accepts an undocumented ShellCheck exception"
assert_match 'lacks an adjacent rationale' "$lint_policy_out" \
  "CI explains why an undocumented ShellCheck exception is rejected"

# Regression (T004 rework): even a fully-documented suppression is rejected
# when its directive precedes the file's first command — ShellCheck scopes
# that placement to the WHOLE file (the lib/common.sh SC2034 defect), so an
# adjacent rationale alone must not excuse it.
rm -f "$discovery_fixture/tests/undocumented-exception.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  '# ShellCheck rationale: fixture regression for file-wide suppression placement.' \
  "$lint_disable" 'unused=1' \
  > "$discovery_fixture/tests/filewide-exception.sh"
rc=0
filewide_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "CI accepts a file-wide ShellCheck suppression (directive before the first command)"
assert_match 'precedes the first command' "$filewide_out" \
  "CI explains why a file-wide ShellCheck suppression is rejected"

# Regression (T004 rework): a shipped script reintroducing a non-POSIX find
# depth primary must fail the portability policy. The offending token is
# assembled at runtime so this test file itself stays clean under the gate.
rm -f "$discovery_fixture/tests/filewide-exception.sh"
nonportable_find_use='find . -m'
nonportable_find_use="${nonportable_find_use}axdepth 1 -type f"
printf '%s\n' '#!/usr/bin/env bash' "$nonportable_find_use" \
  > "$discovery_fixture/tests/nonportable-find.sh"
rc=0
portability_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "CI accepts a non-POSIX find depth primary"
assert_match 'non-POSIX find depth primary' "$portability_out" \
  "CI explains why a non-POSIX find depth primary is rejected"
rm -f "$discovery_fixture/tests/nonportable-find.sh"

rc=0; "$BASH" "$CI" --bash /bin/false --list-shell >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "ci-local accepts a non-Bash --bash interpreter"

grep -q 'ubuntu-latest' "$WORKFLOW" || fail "CI workflow has no Linux runner"
grep -q 'macos-latest' "$WORKFLOW" || fail "CI workflow has no macOS runner"
grep -q 'scripts/ci-local.sh --bash /bin/bash' "$WORKFLOW" \
  || fail "hosted CI does not use the canonical local gate"
grep -q 'scripts/release.sh --tag' "$WORKFLOW" || fail "tag workflow has no pinned release gate"
grep -q 'contents: read' "$WORKFLOW" || fail "CI workflow does not use read-only repository permissions"
grep -Eq 'secrets\.' "$WORKFLOW" && fail "deterministic CI must not require repository secrets"

unsafe_mktemp_pattern='mktemp[[:space:]]+'
unsafe_mktemp_pattern="${unsafe_mktemp_pattern}-u"
while IFS= read -r shell_file; do
  [ "$shell_file" = tests/test_ci_release.sh ] && continue
  grep -En "$unsafe_mktemp_pattern" "$REPO_ROOT/$shell_file" >/dev/null \
    && fail "a shipped shell script still uses the racy temporary-name pattern: $shell_file"
done <<< "$shell_list"

# Regression (T004 rework): the live tree itself must stay free of find's
# non-POSIX depth primaries — the pattern is assembled at runtime, so no
# shipped file (this one included) needs an exclusion.
nonportable_find_pattern='[-]m'
nonportable_find_pattern="${nonportable_find_pattern}(in|ax)depth"
while IFS= read -r shell_file; do
  grep -En "$nonportable_find_pattern" "$REPO_ROOT/$shell_file" >/dev/null \
    && fail "a shipped shell script still uses a non-POSIX find depth primary: $shell_file"
done <<< "$shell_list"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Regression (T004 rework): Formula/orchid.rb's pinned checksum must stay
# fresh for the tree that carries it -- a repair commit that changes shipped
# bytes without re-pinning the formula previously went undetected until the
# release gate at tag time. Enforced here on the live checkout at every run;
# skipped inside an extracted release archive, which by design has neither a
# Git checkout at this root nor a Formula/ directory. On failure the message
# carries pin-formula's own output, which names the exact expected checksum
# and the one-command remedy.
if [ "$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)" = "$REPO_ROOT" ] \
   && [ -f "$REPO_ROOT/Formula/orchid.rb" ]; then
  rc=0
  freshness_out="$("$BASH" "$REPO_ROOT/scripts/pin-formula.sh" --check 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "Formula/orchid.rb checksum is stale for the current tree -- $freshness_out"
fi

write_formula() {
  local repo="$1" version="$2" sha="$3"
  cat > "$repo/Formula/orchid.rb" <<EOF
class Orchid < Formula
  url "https://github.com/bilal-/orchid/releases/download/v$version/orchid-$version.tar.gz"
  sha256 "$sha"
  version "$version"
end
EOF
}

commit_fixture() {
  local repo="$1" message="$2"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$message"
}

fixture="$WORK/release-fixture"
mkdir -p "$fixture"/{Formula,bin,docs,lib,release,scripts,.orchid}
cp "$RELEASE" "$fixture/scripts/release.sh"
cat > "$fixture/.gitattributes" <<'EOF'
/.orchid export-ignore
/Formula export-ignore
EOF
cat > "$fixture/release/metadata.conf" <<'EOF'
version=1.2.3
tag=v1.2.3
archive=orchid-1.2.3.tar.gz
prefix=orchid-1.2.3/
installer_ref=v1.2.3
EOF
cat > "$fixture/lib/common.sh" <<'EOF'
#!/usr/bin/env bash
ORCHID_VERSION="1.2.3"
EOF
cat > "$fixture/install.sh" <<'EOF'
#!/usr/bin/env bash
ORCHID_INSTALL_VERSION="1.2.3"
ORCHID_INSTALL_REF="v1.2.3"
ORCHID_INSTALL_REPOSITORY="https://github.com/bilal-/orchid.git"
exit 0
EOF
cat > "$fixture/bin/orchid" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$fixture/scripts/ci-local.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${ORCHID_RELEASE_ARCHIVE_TEST:-0}" = 1 ]
[ "$1" = --bash ]
[ -x "$2" ]
[ ! -e .git ]
[ ! -e .orchid ]
[ ! -e Formula ]
[ -f release/metadata.conf ]
if [ -n "${ORCHID_TEST_MOVE_TAG_REPO:-}" ]; then
  [ -n "${ORCHID_TEST_MOVE_TAG_TO:-}" ]
  git -C "$ORCHID_TEST_MOVE_TAG_REPO" tag -f v1.2.3 "$ORCHID_TEST_MOVE_TAG_TO" >/dev/null
fi
echo "archive fixture CI PASS"
EOF
printf '%s\n' '# Release fixture' > "$fixture/README.md"
printf '%s\n' '# Install fixture' > "$fixture/docs/install.md"
printf '%s\n' '# Quickstart fixture' > "$fixture/docs/quickstart.md"
printf '%s\n' 'private run state' > "$fixture/.orchid/private"
write_formula "$fixture" 1.2.3 "0000000000000000000000000000000000000000000000000000000000000000"

git init -q "$fixture"
git -C "$fixture" config user.email test@example.com
git -C "$fixture" config user.name "Release Test"
commit_fixture "$fixture" "fixture payload"

# Formula is export-ignored, so its final checksum can be committed without a
# checksum self-reference. Fixed archive mtimes make the tree archive stable
# across that formula-only commit.
probe="$WORK/probe.tar.gz"
git -C "$fixture" archive --format=tar.gz --mtime=1970-01-01T00:00:00Z \
  --prefix=orchid-1.2.3/ --output="$probe" 'HEAD^{tree}'
fixture_sha="$(sha256_file "$probe")"
write_formula "$fixture" 1.2.3 "$fixture_sha"
commit_fixture "$fixture" "pin formula checksum"
probe_after="$WORK/probe-after.tar.gz"
git -C "$fixture" archive --format=tar.gz --mtime=1970-01-01T00:00:00Z \
  --prefix=orchid-1.2.3/ --output="$probe_after" 'HEAD^{tree}'
assert_eq "$fixture_sha" "$(sha256_file "$probe_after")" \
  "export-ignored formula update leaves the release archive reproducible"
git -C "$fixture" tag v1.2.3

release_out="$WORK/release-out"
positive_output="$("$BASH" "$fixture/scripts/release.sh" \
  --tag v1.2.3 --output "$release_out" --bash "$BASH")" \
  || fail "release builder rejected a valid clean tagged fixture"
assert_match "release verified: v1.2.3" "$positive_output" "release success names the verified tag"
[ -f "$release_out/orchid-1.2.3.tar.gz" ] || fail "release archive not emitted"
[ -f "$release_out/orchid-1.2.3.tar.gz.sha256" ] || fail "release checksum not emitted"
[ -f "$release_out/Formula/orchid.rb" ] || fail "verified formula not emitted"
assert_eq "$fixture_sha" "$(sha256_file "$release_out/orchid-1.2.3.tar.gz")" \
  "emitted archive checksum matches the pinned formula input"
archive_list="$(tar -tzf "$release_out/orchid-1.2.3.tar.gz")"
printf '%s\n' "$archive_list" | grep -v '^orchid-1.2.3/' \
  && fail "release archive contains an entry outside its canonical prefix"
printf '%s\n' "$archive_list" | grep -q '^orchid-1.2.3/\.orchid/' \
  && fail "release archive leaked .orchid run state"
printf '%s\n' "$archive_list" | grep -q '^orchid-1.2.3/Formula/' \
  && fail "release archive included the external tap formula"

run_release_failure() {
  local repo="$1" tag="$2" pattern="$3" name="$4" out rc=0
  out="$("$BASH" "$repo/scripts/release.sh" --tag "$tag" \
    --output "$WORK/fail-$name" --bash "$BASH" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$name: release unexpectedly succeeded"
  assert_match "$pattern" "$out" "$name: failure reason"
}

# Dirty state is rejected before any Git object is archived.
printf '%s\n' dirty > "$fixture/untracked"
run_release_failure "$fixture" v1.2.3 'clean' dirty
rm "$fixture/untracked"

# Moving names and missing tags are never accepted as release inputs.
run_release_failure "$fixture" main 'moving refs|semantic-version' moving-ref
run_release_failure "$fixture" v9.9.9 'does not exist' missing-tag

clone_fixture() {
  local name="$1" destination
  destination="$WORK/$name"
  git clone -q "$fixture" "$destination"
  git -C "$destination" config user.email test@example.com
  git -C "$destination" config user.name "Release Test"
  printf '%s\n' "$destination"
}

# A valid tag elsewhere is insufficient: the clean checked-out HEAD itself
# must be the exact tagged commit.
head_mismatch="$(clone_fixture head-mismatch)"
printf '%s\n' later > "$head_mismatch/later"
commit_fixture "$head_mismatch" "commit after tag"
run_release_failure "$head_mismatch" v1.2.3 'HEAD .* is not tagged commit' head-mismatch

placeholder_repo="$(clone_fixture placeholder)"
printf '%s\n' '<!-- SCREENSHOT: missing evidence -->' >> "$placeholder_repo/README.md"
commit_fixture "$placeholder_repo" "plant placeholder"
git -C "$placeholder_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$placeholder_repo" v1.2.3 'placeholder' placeholder

installer_repo="$(clone_fixture installer-mismatch)"
sed 's/ORCHID_INSTALL_REF="v1.2.3"/ORCHID_INSTALL_REF="main"/' \
  "$installer_repo/install.sh" > "$installer_repo/install.sh.new"
mv "$installer_repo/install.sh.new" "$installer_repo/install.sh"
commit_fixture "$installer_repo" "break installer metadata"
git -C "$installer_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$installer_repo" v1.2.3 'installer ref mismatch' installer-mismatch

installer_origin_repo="$(clone_fixture installer-origin-mismatch)"
sed 's#ORCHID_INSTALL_REPOSITORY="https://github.com/bilal-/orchid.git"#ORCHID_INSTALL_REPOSITORY="https://example.invalid/orchid.git"#' \
  "$installer_origin_repo/install.sh" > "$installer_origin_repo/install.sh.new"
mv "$installer_origin_repo/install.sh.new" "$installer_origin_repo/install.sh"
commit_fixture "$installer_origin_repo" "break installer repository metadata"
git -C "$installer_origin_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$installer_origin_repo" v1.2.3 'installer repository mismatch' installer-origin-mismatch

duplicate_metadata_repo="$(clone_fixture duplicate-metadata)"
printf '%s\n' 'version=' >> "$duplicate_metadata_repo/release/metadata.conf"
commit_fixture "$duplicate_metadata_repo" "duplicate release metadata"
git -C "$duplicate_metadata_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$duplicate_metadata_repo" v1.2.3 'exactly one version value' duplicate-metadata

formula_repo="$(clone_fixture formula-mismatch)"
write_formula "$formula_repo" 1.2.4 "$fixture_sha"
commit_fixture "$formula_repo" "break formula metadata"
git -C "$formula_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$formula_repo" v1.2.3 'formula version mismatch' formula-mismatch

checksum_repo="$(clone_fixture checksum-mismatch)"
write_formula "$checksum_repo" 1.2.3 "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
commit_fixture "$checksum_repo" "break formula checksum"
git -C "$checksum_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$checksum_repo" v1.2.3 'formula checksum mismatch' checksum-mismatch

# A tag that changes after its commit has been resolved must fail even though
# every archive byte came from the originally resolved commit.
moving_tag_repo="$(clone_fixture moving-tag)"
printf '%s\n' later > "$moving_tag_repo/later"
commit_fixture "$moving_tag_repo" "commit available for a moved tag"
moving_tag_to="$(git -C "$moving_tag_repo" rev-parse HEAD)"
git -C "$moving_tag_repo" checkout -q --detach v1.2.3
rc=0
moving_tag_out="$(ORCHID_TEST_MOVE_TAG_REPO="$moving_tag_repo" \
  ORCHID_TEST_MOVE_TAG_TO="$moving_tag_to" \
  "$BASH" "$moving_tag_repo/scripts/release.sh" --tag v1.2.3 \
  --output "$WORK/fail-moving-tag" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "moving-tag: release unexpectedly succeeded"
assert_match 'tag moved during release verification' "$moving_tag_out" \
  "moving-tag: failure reason"

# Regression (T004 rework): checksum freshness is owned by one deterministic
# tool. pin-formula --check must flag a stale pinned value and print the
# exact expected checksum; pin-formula must then repair the formula to that
# fixed point (Formula/ is export-ignored, so pinning cannot change the
# archive); and the repaired formula must pass --check again.
pin_repo="$(clone_fixture pin-formula)"
cp "$REPO_ROOT/scripts/pin-formula.sh" "$pin_repo/scripts/pin-formula.sh"
commit_fixture "$pin_repo" "carry the pin-formula tool"
pin_probe="$WORK/pin-probe.tar.gz"
git -C "$pin_repo" archive --format=tar.gz --mtime=1970-01-01T00:00:00Z \
  --prefix=orchid-1.2.3/ --output="$pin_probe" 'HEAD^{tree}'
pin_expected_sha="$(sha256_file "$pin_probe")"
write_formula "$pin_repo" 1.2.3 "1111111111111111111111111111111111111111111111111111111111111111"
rc=0
pin_check_out="$("$BASH" "$pin_repo/scripts/pin-formula.sh" --check 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "pin-formula --check accepted a stale formula checksum"
assert_match 'STALE' "$pin_check_out" "pin-formula --check names the staleness"
assert_match "$pin_expected_sha" "$pin_check_out" \
  "pin-formula --check prints the exact expected fixed-point checksum"
"$BASH" "$pin_repo/scripts/pin-formula.sh" >/dev/null 2>&1 \
  || fail "pin-formula failed to repin a stale formula"
grep -q "sha256 \"$pin_expected_sha\"" "$pin_repo/Formula/orchid.rb" \
  || fail "pin-formula did not pin the exact fixed-point checksum (wanted $pin_expected_sha)"
"$BASH" "$pin_repo/scripts/pin-formula.sh" --check >/dev/null 2>&1 \
  || fail "pin-formula --check rejects the checksum it just pinned"

exit 0
