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

# --- the outer half of the merge-gate recursion guard (T007) ---------------
# This file can be a repository's `merge_gate` (orchid.config's `merge_gate`
# key; libexec/orchid-merge). When it is, the loop is: merge -> this script ->
# tests/run.sh -> tests/test_merge.sh -> `orchid merge` -> that merge's gate ->
# this script again. `orchid merge` sets ORCHID_MERGE_GATE_ACTIVE in the gate
# command's own environment, which closes the loop from the INSIDE and does
# not depend on this file cooperating. This assertion is about the OTHER
# direction: an operator or the hosted CI job running the suite directly, with
# no merge above it, where the first nested `orchid merge` would otherwise be
# free to open level one.
#
# THIS repository's own gate is the `--no-tests` form (asserted below), which
# cannot reach tests/run.sh at all, so the loop above is not reachable here
# today. The guard is not therefore decoration: `merge_gate` takes any command,
# the flagless form of this script is the obvious thing to reach for, and a
# recursion that only bites the repository that configures it that way is one
# nobody discovers until it is running.
#
# Behavioural, not a grep for the export line: ci-local.sh spawns `$BASH_BIN`
# for its own interpreter probe, so a `--bash` that records its inherited
# environment before exec'ing the real interpreter reports what a spawned
# child actually sees. `--list-shell` is used to stop right after that probe —
# the marker is process-wide once exported, so proving it reaches the FIRST
# child proves it reaches `tests/run.sh` too, and the static check below is
# what would catch someone unsetting it in between.
marker_probe="$WORK/ci-marker-probe.txt"
marker_wrapper="$WORK/bash-marker-wrapper"
cat > "$marker_wrapper" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\${ORCHID_MERGE_GATE_ACTIVE:-unset}" >> "$marker_probe"
exec "$BASH" "\$@"
EOF
chmod +x "$marker_wrapper"
: > "$marker_probe"
"$BASH" "$CI" --bash "$marker_wrapper" --list-shell >/dev/null \
  || fail "ci-local --list-shell failed through the marker-probe interpreter"
assert_match "^1$" "$(cat "$marker_probe")" \
  "ci-local.sh exports ORCHID_MERGE_GATE_ACTIVE into the processes it spawns (merge-gate recursion guard)"

# The probe above proves the marker is set where it is first observable; this
# proves nothing later takes it away again. One `export`, no `unset` — the
# guard is worthless if the suite is reached with it cleared, and that removal
# would be invisible to any check that only looks at the top of the file.
marker_writes="$(grep -cE '^[[:space:]]*(export[[:space:]]+)?ORCHID_MERGE_GATE_ACTIVE=|^[[:space:]]*unset[[:space:]].*ORCHID_MERGE_GATE_ACTIVE' "$CI")"
assert_eq 1 "$marker_writes" "ci-local.sh writes ORCHID_MERGE_GATE_ACTIVE exactly once, and never unsets it"
grep -q '^export ORCHID_MERGE_GATE_ACTIVE=1$' "$CI" \
  || fail "ci-local.sh's single write of ORCHID_MERGE_GATE_ACTIVE must be that export"

# Exercise discovery against layouts and shebang forms rather than proving
# only that today's known files happen to be present. The copied gate has no
# Git metadata, so this also covers the extracted-archive find fallback.
discovery_fixture="$WORK/discovery-fixture"
mkdir -p "$discovery_fixture"/{lib,plugins/example,scripts,skills/example/helpers,templates,tests}
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

# Regression (T014, lesson L019): a shipped script that reads an mtime with a
# platform-specific stat format must fail the portability policy. The correct
# BSD/GNU form existed in exactly ONE file for a whole release while five other
# sites — including the lock acquisition every durable verb runs through — kept
# the broken exit-status form and took CI down on ubuntu-latest. A good example
# nobody is forced to follow did not converge them; this gate is what does, so
# it needs its own regression net. Assembled at runtime, same as the find case,
# so this test file stays clean under the gate it is testing.
#
# All five spellings below are checked, not just the one that broke CI. A gate
# keyed to the exact text of the last outage catches only the author who
# reproduces that outage verbatim; the next one omits the space, or reaches for
# GNU's long option -- with or without the `=`, since getopt_long accepts the
# format as a separate argument too -- and walks straight past it. The BSD and
# GNU forms are both rejected in both spacings because a file may legitimately
# be developed on either platform -- what makes them wrong is naming a platform
# at all.
mtime_pct='%'
for raw_mtime_use in \
  "mt=\"\$(stat -f ${mtime_pct}m /tmp 2>/dev/null)\"" \
  "mt=\"\$(stat -f${mtime_pct}m /tmp 2>/dev/null)\"" \
  "mt=\"\$(stat -c${mtime_pct}Y /tmp 2>/dev/null)\"" \
  "mt=\"\$(stat --format='${mtime_pct}Y' /tmp 2>/dev/null)\"" \
  "mt=\"\$(stat --printf ${mtime_pct}Y /tmp 2>/dev/null)\""
do
  printf '%s\n' '#!/usr/bin/env bash' "$raw_mtime_use" \
    > "$discovery_fixture/tests/raw-mtime.sh"
  rc=0
  mtime_policy_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "CI accepts a platform-specific stat mtime format outside lib/common.sh: $raw_mtime_use"
  # Matched against the REFUSAL's own wording, not merely against `file_mtime`:
  # the gate echoes a banner naming that helper before it checks anything, so a
  # bare `file_mtime` match is satisfied by a run in which the gate never fired
  # and ci-local exited non-zero for an unrelated reason (a missing shellcheck,
  # say). That assertion would have passed against a gate that matched nothing
  # at all -- which is the exact failure mode this whole task is about.
  assert_match 'platform-specific stat format' "$mtime_policy_out" \
    "CI explains why a platform-specific stat mtime format is rejected ($raw_mtime_use)"
  assert_match 'file_mtime instead' "$mtime_policy_out" \
    "CI names the helper that a rejected stat mtime format should have used ($raw_mtime_use)"
done
rm -f "$discovery_fixture/tests/raw-mtime.sh"

# Regression (T014 rework): lib/common.sh is exempt because it HOLDS the
# correct implementation — so the exemption is `file_mtime`'s own block, not
# the six hundred lines around it. Waving the whole file through would let the
# next raw idiom land beside the helper written to prevent it, in the same
# file as the lock acquisition that went down on ubuntu-latest: L016 and L019
# a third time. All three cases below use a stand-in lib/common.sh so the
# assertions are about the GATE, not about today's contents of the real file.
mtime_helper_doc='# file_mtime <path> [fallback] -- fixture stand-in for the real helper.'
mtime_inside="  mt=\"\$(stat -f ${mtime_pct}m \"\$1\" 2>/dev/null || true)\""
mtime_outside="stale_mtime=\"\$(stat -c${mtime_pct}Y /tmp 2>/dev/null)\""

# Accepted: the helper's own block may name both spellings — that is the whole
# point of exempting it. Asserted against the refusal's wording rather than the
# run's exit status, so an unrelated ci-local failure cannot masquerade as this
# case passing (and cannot make it fail either).
printf '%s\n' '#!/usr/bin/env bash' "$mtime_helper_doc" 'file_mtime() {' \
  "$mtime_inside" '  printf %s "$mt"' '}' \
  > "$discovery_fixture/lib/common.sh"
scoped_ok_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1 || true)"
printf '%s\n' "$scoped_ok_out" | grep -q 'platform-specific stat format' \
  && fail "CI rejects a platform-specific stat format INSIDE lib/common.sh's own file_mtime helper — that block is the one place the format belongs"

# Rejected: the same format one line past the helper's closing brace.
printf '%s\n' '#!/usr/bin/env bash' "$mtime_helper_doc" 'file_mtime() {' \
  "$mtime_inside" '  printf %s "$mt"' '}' "$mtime_outside" \
  > "$discovery_fixture/lib/common.sh"
rc=0
scoped_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "CI accepts a platform-specific stat mtime format in lib/common.sh outside its own file_mtime helper"
assert_match 'outside its own file_mtime helper' "$scoped_out" \
  "CI explains that lib/common.sh's exemption is the file_mtime helper, not the whole file"

# Rejected: the helper is gone (renamed, moved, deleted) and the format is
# still there. An unlocatable block must read as "cannot judge", never as
# "exempt" — otherwise renaming file_mtime silently restores the blanket pass
# this case exists to remove.
printf '%s\n' '#!/usr/bin/env bash' "$mtime_outside" \
  > "$discovery_fixture/lib/common.sh"
rc=0
unlocatable_out="$("$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "CI accepts a platform-specific stat mtime format in a lib/common.sh with no locatable file_mtime helper — the exemption must not survive the helper it is scoped to"
assert_match 'cannot be located' "$unlocatable_out" \
  "CI explains that it refuses rather than exempts when file_mtime cannot be located"
rm -f "$discovery_fixture/lib/common.sh"

# Regression (T004 attempt 7): ShellCheck normally searches a script's parent
# directories and the invoking user's home for .shellcheckrc. Neither source
# may suppress a warning outside the repository's audited inline-directive
# policy. Requiring the actual warning code avoids passing merely because the
# intentionally minimal discovery fixture has no full test runner afterward.
ambient_home="$WORK/ambient-home"
mkdir -p "$ambient_home"
printf '%s\n' 'disable=SC2034' > "$WORK/.shellcheckrc"
printf '%s\n' 'disable=SC2034' > "$ambient_home/.shellcheckrc"
printf '%s\n' '#!/usr/bin/env bash' 'ambient_policy_must_not_hide_me=1' \
  > "$discovery_fixture/tests/ambient-policy-warning.sh"
rc=0
ambient_policy_out="$(HOME="$ambient_home" \
  "$BASH" "$discovery_fixture/scripts/ci-local.sh" --bash "$BASH" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "CI accepts a warning suppressed by ambient .shellcheckrc policy"
assert_match 'SC2034' "$ambient_policy_out" \
  "CI ignores suppressive parent/global .shellcheckrc policy and reports the warning"
rm -f "$discovery_fixture/tests/ambient-policy-warning.sh" \
  "$WORK/.shellcheckrc" "$ambient_home/.shellcheckrc"

rc=0; "$BASH" "$CI" --bash /bin/false --list-shell >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "ci-local accepts a non-Bash --bash interpreter"

grep -q 'ubuntu-latest' "$WORKFLOW" || fail "CI workflow has no Linux runner"
grep -q 'macos-latest' "$WORKFLOW" || fail "CI workflow has no macOS runner"
grep -q 'scripts/ci-local.sh --bash /bin/bash' "$WORKFLOW" \
  || fail "hosted CI does not use the canonical local gate"

# ...and so does this repository's own merge path. The mechanism landing
# without anything turning it on is precisely the r-001 failure repeated one
# level up: `scripts/ci-local.sh` existed for that entire run and was simply
# never wired to the tasks it was supposed to judge. libexec/orchid-merge
# reads `merge_gate` from repo config, so this line in orchid.config is what
# makes the gate fire for every task here rather than only for the ones whose
# author remembered to name it. Assert the wiring, not just the wire.
grep -q '^merge_gate=.*scripts/ci-local\.sh' "$REPO_ROOT/orchid.config" \
  || fail "orchid.config does not set merge_gate to the canonical local gate — merges here would not be gated by it"

# The gate is the STATIC half, and it has to stay that way. `orchid merge` runs
# the task's own `verification_commands` on the merged tree before the gate
# fires, so a gate that ran the suite again would pay for a second full run per
# merge and learn nothing from it — and this repository's suite is long enough
# that the doubling is not a rounding error. Pinned here rather than left to
# whoever next edits orchid.config, because the flag disappearing is silent:
# every merge would still pass, just twice as slowly.
grep -q '^merge_gate=.*[-]-no-tests' "$REPO_ROOT/orchid.config" \
  || fail "orchid.config's merge_gate must pass --no-tests — the merged tree already gets a full suite from verification_commands"

# And the flag has to mean what the config assumes: every static check, no
# test script. Run it rather than read it — the failure worth catching is a
# static section added BELOW the cut by a later author and silently skipped at
# every merge thereafter, and only the real command can see that.
#
# Against a fixture with no tests/ directory at all, deliberately, so the two
# halves prove each other and neither costs a second pass over this repository:
# `--no-tests` exits 0 here only if it stopped before reaching a test runner
# that does not exist, and the flagless run below fails for exactly that
# reason. Two files to lint, not seventy.
no_tests_fixture="$WORK/no-tests-fixture"
mkdir -p "$no_tests_fixture/scripts"
cp "$CI" "$no_tests_fixture/scripts/ci-local.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$no_tests_fixture/clean.sh"
no_tests_ci="$no_tests_fixture/scripts/ci-local.sh"

# ShellCheck is a MACHINE FACT here, and this is the one place in the suite
# that needs it: every check above reads a file or stops at `--list-shell`,
# which never reaches ci-local's `command -v shellcheck` requirement. Running
# the pair below on a machine without it would not merely fail — the flagless
# contrast would ALSO exit non-zero, for the missing linter rather than for
# the missing suite, and would go on "passing" while proving nothing. So the
# absence is recorded in the same vocabulary tests/helpers.sh's not_tested
# uses, never as a pass and never as a defect in this repository's code.
if ! command -v shellcheck >/dev/null 2>&1; then
  not_tested "ci-local-no-tests-cut" "shellcheck is not installed, and scripts/ci-local.sh exits 1 without it, so the --no-tests cut cannot be exercised here (both this run and its flagless contrast would be measuring the missing linter). Qualify by installing ShellCheck — see docs/contributing.md — and re-running this file; hosted CI installs it on both runners"
else
  rc=0
  no_tests_out="$("$BASH" "$no_tests_ci" --bash "$BASH" --no-tests 2>&1)" || rc=$?
  assert_eq 0 "$rc" "ci-local --no-tests passes a clean tree that has no test suite to run"
  assert_match '^== ShellCheck \(zero warnings\)$' "$no_tests_out" \
    "--no-tests still runs the ShellCheck gate — the half of L016 no task's own suite ever contained"
  assert_match '^== Portability policy' "$no_tests_out" \
    "--no-tests still runs the portability gates"
  # A here-string, not `printf | grep`: under this suite's `pipefail` the piped
  # form is the negative assertion that fails open — grep's early exit can
  # SIGPIPE the producer, turning "pattern present" into a nonzero pipeline that
  # skips the `&& fail` exactly when it should fire.
  grep -q '^== Full test suite' <<<"$no_tests_out" \
    && fail "--no-tests reached the test suite"
  assert_eq "CI PASS (static checks only; --no-tests)" \
    "$(printf '%s\n' "$no_tests_out" | tail -n1)" \
    "--no-tests says plainly that it skipped the suite, so a passing gate is never read as a full run"

  # The contrast that makes the assertion above mean something: same tree, same
  # static checks, flag dropped -> it goes looking for the suite and fails. And
  # it must fail for THAT reason: the banner is printed only once the static
  # half has finished, so requiring it in the output tells this failure apart
  # from one that never got past ShellCheck or the portability gates and would
  # otherwise satisfy a bare "exited non-zero" check while proving nothing.
  rc=0
  flagless_out="$("$BASH" "$no_tests_ci" --bash "$BASH" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "ci-local without --no-tests must still try to run the test suite"
  assert_match '^== Full test suite$' "$flagless_out" \
    "the flagless run failed AT the test suite, not before it — otherwise the contrast measures a broken static check rather than the cut"
fi

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

# T030 removed the live-checkout freshness gate that used to stand here.
#
# It was a T004 regression check: run `scripts/pin-formula.sh --check`
# against $REPO_ROOT on every suite run, so a commit that changed shipped
# bytes without re-pinning the formula failed immediately instead of at tag
# time. The intent was right and the fixpoint it defended is still defended
# -- but the placement made a DERIVED artifact a per-candidate obligation,
# and that deadlocks the orchestrator (lesson L022, found live in r-002).
#
# The chain: this suite is every task's verification_commands, so every
# candidate had to re-pin, so every candidate rewrote the SAME single
# `sha256` line in Formula/orchid.rb to a DIFFERENT value. The first task
# merges. The second one's base is now stale, libexec/orchid-merge rebases
# it onto the new integration HEAD, and the replay conflicts on exactly that
# line. The rebase aborts, merge advances the task to `rework`, and rework
# dispatches the implementer -- which under the restricted profile (L017)
# cannot run git, cannot run scripts/pin-formula.sh and cannot compute a
# SHA-256. It produces no commit, the candidate is unchanged, and the same
# conflict recurs forever, with no operator in a headless run to break it.
#
# So the obligation moved to where the pin actually lives rather than being
# deleted. No task branch touches Formula/orchid.rb at all now, which is what
# leaves nothing to conflict. The pin is regenerated ONCE on the integration
# branch at release time (`scripts/pin-formula.sh`, docs/install.md's
# release-day steps), and scripts/release.sh refuses to verify a tag whose
# formula checksum does not equal the archive it just built -- so a stale pin
# still cannot ship. The T030 section at the end of this file proves both
# halves, and pins a tripwire so this gate cannot come back here.

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

# Hostile Git state outside the tagged tree must not alter archive bytes. Git
# supports replacement compressors through tar.<format>.command, reads config
# from system/global/local/environment scopes, and normally gives
# $GIT_DIR/info/attributes precedence over the tree's own .gitattributes.
# Plant every one of those inputs. Also put a gzip first on PATH that delegates
# decompression (GNU tar may request it) but emits divergent bytes and fails for
# compression. The custom commands and hostile gzip would fail if invoked to
# build an archive, while the attributes would export-ignore the whole tree if
# consulted. The release must still reproduce the original checksum.
hostile_system_config="$WORK/hostile-system.gitconfig"
hostile_global_config="$WORK/hostile-global.gitconfig"
hostile_attributes="$WORK/hostile-attributes"
real_gzip="$(command -v gzip)" || fail "gzip is required to exercise hostile PATH coverage"
hostile_bin="$WORK/hostile-bin"
mkdir -p "$hostile_bin"
cat > "$hostile_bin/gzip" <<'EOF'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  case "$arg" in
    -d|--decompress|-*d*) exec "${ORCHID_TEST_REAL_GZIP:?}" "$@" ;;
  esac
done
printf '%s\n' 'hostile gzip output must never become release bytes'
exit 97
EOF
chmod +x "$hostile_bin/gzip"
hostile_path="$hostile_bin:$PATH"
[ "$(PATH="$hostile_path" command -v gzip)" = "$hostile_bin/gzip" ] \
  || fail "hostile gzip is not first on PATH"
printf '%s\n' '* export-ignore' > "$hostile_attributes"
git config --file "$hostile_system_config" tar.tar.gz.command false
git config --file "$hostile_system_config" core.attributesFile "$hostile_attributes"
git config --file "$hostile_global_config" tar.tar.command false
git config --file "$hostile_global_config" core.attributesFile "$hostile_attributes"
git -C "$fixture" config tar.tar.gz.command false
git -C "$fixture" config core.attributesFile "$hostile_attributes"
printf '%s\n' '* export-ignore' > "$fixture/.git/info/attributes"

hostile_release_out="$WORK/release-out-hostile"
hostile_release_output="$(
  PATH="$hostile_path" \
  ORCHID_TEST_REAL_GZIP="$real_gzip" \
  GIT_CONFIG_SYSTEM="$hostile_system_config" \
  GIT_CONFIG_GLOBAL="$hostile_global_config" \
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=tar.tar.gz.command \
  GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=core.attributesFile \
  GIT_CONFIG_VALUE_1="$hostile_attributes" \
    "$BASH" "$fixture/scripts/release.sh" \
      --tag v1.2.3 --output "$hostile_release_out" --bash "$BASH"
)" || fail "release archive depends on hostile ambient/source Git config or attributes"
assert_match "release verified: v1.2.3" "$hostile_release_output" \
  "config- and compressor-isolated release still verifies the exact tag"
assert_eq "$fixture_sha" "$(sha256_file "$hostile_release_out/orchid-1.2.3.tar.gz")" \
  "ambient gzip, Git config, and info/attributes cannot alter release bytes"

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

# T008: the tag gate admits a semver PRERELEASE (the shipped 1.0.0-beta.1)
# and nothing looser. Both directions are checked on shape alone, so the
# widened pattern cannot rot into accepting an arbitrary string:
#
#   - a well-formed prerelease that is simply not tagged in this fixture must
#     fail on tag EXISTENCE, which is only reachable once the shape gate has
#     already admitted it;
#   - moving refs, malformed suffixes, and anything carrying path syntax must
#     still be refused on shape, before any Git object is resolved.
#
# Refusal arrives from one of two gates -- the cheap glob (which names moving
# refs) or the authoritative grep (which names vMAJOR.MINOR.PATCH) -- and
# either one means the tag was rejected for its shape, so both messages count.
shape_refused='moving refs|vMAJOR\.MINOR\.PATCH'
run_release_failure "$fixture" v9.9.9-beta.1 'does not exist' shape-prerelease-simple
run_release_failure "$fixture" v9.9.9-rc.2.alpha-3 'does not exist' shape-prerelease-multi
run_release_failure "$fixture" HEAD "$shape_refused" shape-head
run_release_failure "$fixture" release-v1.2.3 "$shape_refused" shape-branch-name
run_release_failure "$fixture" v1.2.3- "$shape_refused" shape-empty-suffix
run_release_failure "$fixture" v1.2.3-beta..1 "$shape_refused" shape-empty-identifier
run_release_failure "$fixture" v1.2.3-01 "$shape_refused" shape-leading-zero
run_release_failure "$fixture" v1.2.3+build.1 "$shape_refused" shape-build-metadata
run_release_failure "$fixture" v1.2.3-beta.1/../evil "$shape_refused" shape-path-syntax

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
# Apply the same hostile archive/config/attribute state to the current-content
# snapshotter. It must compute the same bytes as the clean baseline above and
# must never execute a configured archive command or PATH-provided compressor.
git -C "$pin_repo" config tar.tar.gz.command false
git -C "$pin_repo" config core.attributesFile "$hostile_attributes"
printf '%s\n' '* export-ignore' > "$pin_repo/.git/info/attributes"
# A temporary index is insufficient isolation on its own: `git add` would
# otherwise persist the dirty formula blob and synthesized trees in the real
# object database. Both modes must keep every temporary object disposable so
# this maintenance check also works with read-only repository metadata.
pin_objects_before="$(git -C "$pin_repo" count-objects -v)"
rc=0
pin_check_out="$(
  PATH="$hostile_path" \
  ORCHID_TEST_REAL_GZIP="$real_gzip" \
  GIT_CONFIG_SYSTEM="$hostile_system_config" \
  GIT_CONFIG_GLOBAL="$hostile_global_config" \
  GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=tar.tar.gz.command \
  GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=core.attributesFile \
  GIT_CONFIG_VALUE_1="$hostile_attributes" \
    "$BASH" "$pin_repo/scripts/pin-formula.sh" --check 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail "pin-formula --check accepted a stale formula checksum"
assert_match 'STALE' "$pin_check_out" "pin-formula --check names the staleness"
assert_match "$pin_expected_sha" "$pin_check_out" \
  "pin-formula ignores ambient gzip and prints the exact fixed-point checksum"
PATH="$hostile_path" \
ORCHID_TEST_REAL_GZIP="$real_gzip" \
GIT_CONFIG_SYSTEM="$hostile_system_config" \
GIT_CONFIG_GLOBAL="$hostile_global_config" \
GIT_CONFIG_COUNT=2 \
GIT_CONFIG_KEY_0=tar.tar.gz.command \
GIT_CONFIG_VALUE_0=false \
GIT_CONFIG_KEY_1=core.attributesFile \
GIT_CONFIG_VALUE_1="$hostile_attributes" \
  "$BASH" "$pin_repo/scripts/pin-formula.sh" >/dev/null 2>&1 \
  || fail "pin-formula failed to repin a stale formula"
grep -q "sha256 \"$pin_expected_sha\"" "$pin_repo/Formula/orchid.rb" \
  || fail "pin-formula did not pin the exact fixed-point checksum (wanted $pin_expected_sha)"
PATH="$hostile_path" \
ORCHID_TEST_REAL_GZIP="$real_gzip" \
GIT_CONFIG_SYSTEM="$hostile_system_config" \
GIT_CONFIG_GLOBAL="$hostile_global_config" \
GIT_CONFIG_COUNT=2 \
GIT_CONFIG_KEY_0=tar.tar.gz.command \
GIT_CONFIG_VALUE_0=false \
GIT_CONFIG_KEY_1=core.attributesFile \
GIT_CONFIG_VALUE_1="$hostile_attributes" \
  "$BASH" "$pin_repo/scripts/pin-formula.sh" --check >/dev/null 2>&1 \
  || fail "pin-formula --check rejects the checksum it just pinned"
assert_eq "$pin_objects_before" "$(git -C "$pin_repo" count-objects -v)" \
  "pin-formula leaves the repository object database untouched"

# ===========================================================================
# T008: admitting a prerelease TAG is only half the job -- every downstream
# agreement check has to hold for a prerelease VERSION too. tag = v$version,
# archive = orchid-<version>.tar.gz, prefix = orchid-<version>/, and the
# lib/common.sh / install.sh / formula cross-checks all interpolate the
# version verbatim, so a suffix that broke any of them would surface only at
# real tag time. Build one end to end instead of trusting that. The version
# is deliberately not the shipped one: this pins the SHAPE, not 1.0.0-beta.1.
# ===========================================================================
pre_version="2.0.0-beta.1"
pre="$WORK/prerelease-fixture"
mkdir -p "$pre"/{Formula,bin,docs,lib,release,scripts,.orchid}
cp "$RELEASE" "$pre/scripts/release.sh"
cat > "$pre/.gitattributes" <<'EOF'
/.orchid export-ignore
/Formula export-ignore
EOF
cat > "$pre/release/metadata.conf" <<EOF
version=$pre_version
tag=v$pre_version
archive=orchid-$pre_version.tar.gz
prefix=orchid-$pre_version/
installer_ref=v$pre_version
EOF
cat > "$pre/lib/common.sh" <<EOF
#!/usr/bin/env bash
ORCHID_VERSION="$pre_version"
EOF
cat > "$pre/install.sh" <<EOF
#!/usr/bin/env bash
ORCHID_INSTALL_VERSION="$pre_version"
ORCHID_INSTALL_REF="v$pre_version"
ORCHID_INSTALL_REPOSITORY="https://github.com/bilal-/orchid.git"
exit 0
EOF
cat > "$pre/bin/orchid" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$pre/scripts/ci-local.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${ORCHID_RELEASE_ARCHIVE_TEST:-0}" = 1 ]
[ "$1" = --bash ]
[ -x "$2" ]
[ ! -e .git ]
[ ! -e .orchid ]
[ ! -e Formula ]
[ -f release/metadata.conf ]
echo "prerelease archive fixture CI PASS"
EOF
printf '%s\n' '# Release fixture' > "$pre/README.md"
printf '%s\n' '# Install fixture' > "$pre/docs/install.md"
printf '%s\n' '# Quickstart fixture' > "$pre/docs/quickstart.md"
printf '%s\n' 'private run state' > "$pre/.orchid/private"
write_formula "$pre" "$pre_version" "0000000000000000000000000000000000000000000000000000000000000000"

git init -q "$pre"
git -C "$pre" config user.email test@example.com
git -C "$pre" config user.name "Release Test"
commit_fixture "$pre" "prerelease fixture payload"

# Same export-ignored-formula trick as the baseline fixture: snapshot the
# payload tree, pin that checksum in a formula-only commit, then tag. The
# pinned digest stays valid for the tagged commit precisely because Formula/
# never reaches the archive.
pre_probe="$WORK/prerelease-probe.tar.gz"
git -C "$pre" archive --format=tar.gz --mtime=1970-01-01T00:00:00Z \
  --prefix="orchid-$pre_version/" --output="$pre_probe" 'HEAD^{tree}'
pre_sha="$(sha256_file "$pre_probe")"
write_formula "$pre" "$pre_version" "$pre_sha"
commit_fixture "$pre" "pin prerelease formula checksum"
git -C "$pre" tag "v$pre_version"

pre_out="$WORK/prerelease-out"
pre_output="$("$BASH" "$pre/scripts/release.sh" \
  --tag "v$pre_version" --output "$pre_out" --bash "$BASH" 2>&1)" \
  || fail "release builder rejected a valid clean prerelease tag: $pre_output"
assert_match "release verified: v$pre_version" "$pre_output" \
  "prerelease release success names the verified prerelease tag"
[ -f "$pre_out/orchid-$pre_version.tar.gz" ] \
  || fail "prerelease archive not emitted under its suffixed name"
[ -f "$pre_out/orchid-$pre_version.tar.gz.sha256" ] \
  || fail "prerelease archive checksum not emitted"
[ -f "$pre_out/Formula/orchid.rb" ] || fail "prerelease formula not emitted"
assert_eq "$pre_sha" "$(sha256_file "$pre_out/orchid-$pre_version.tar.gz")" \
  "prerelease archive checksum matches the pinned formula input"
pre_list="$(tar -tzf "$pre_out/orchid-$pre_version.tar.gz")"
printf '%s\n' "$pre_list" | grep -v "^orchid-$pre_version/" \
  && fail "prerelease archive contains an entry outside its suffixed prefix"
printf '%s\n' "$pre_list" | grep -qxF "orchid-$pre_version/release/metadata.conf" \
  || fail "prerelease archive is missing release/metadata.conf under its suffixed prefix"

# ===========================================================================
# T030: the formula pin is a DERIVED artifact of the integration branch, and
# pinning it per candidate deadlocks the orchestrator (lesson L022).
#
# The five checks below are one argument, in order:
#
#   1. RED -- two candidates off one base that each re-pin genuinely DO
#      collide. The second one's rebase conflicts, in Formula/orchid.rb, on
#      the one line both rewrote. This is the deadlock's mechanism, proven
#      rather than asserted, so the rest of the section is answering a real
#      failure and not a hypothetical one.
#   2. GREEN -- the same two candidates under the shipped design, where
#      neither touches Formula/orchid.rb: the second rebases clean, both
#      land in sequence, and no operator step happens anywhere between them.
#   3. The obligation MOVED, it did not vanish: the pin on the integration
#      tip is now stale, one pin-formula run on that branch makes it fresh
#      in a formula-only commit, and the release gate then verifies the tag.
#      That is T004's fixed point, kept, but proven where the pin lives.
#   4. A stale pin still FAILS the release gate, so nothing can ship on one.
#   5. A tripwire, so the per-candidate gate cannot come back to this file.
#
# All of this runs at the git level, on a real fixture, because that is the
# layer the conflict happens at. The same two-candidates-in-sequence property
# is proven through the `orchid merge` verb itself in tests/test_merge.sh.
# ===========================================================================

# A fixture repository carrying the REAL pin-formula tool, with its baseline
# formula pinned for its own content, plus the branch name and commit the two
# candidates below will both fork from.
t030_fixture() {
  local repo="$1"
  cp "$REPO_ROOT/scripts/pin-formula.sh" "$repo/scripts/pin-formula.sh"
  commit_fixture "$repo" "carry the pin-formula tool"
  "$BASH" "$repo/scripts/pin-formula.sh" >/dev/null 2>&1 \
    || fail "T030 setup: could not pin $repo's baseline formula"
  commit_fixture "$repo" "pin the baseline formula"
}

# One candidate: fork $base, add ONE new shipped file, commit. lib/ is not
# export-ignored, so the new file moves the archive bytes and therefore the
# checksum -- which is exactly what used to oblige every candidate to re-pin.
# It is read by none of release.sh's version/URL/placeholder cross-checks, so
# the ONLY variable between the two scenarios below is `$repin`.
t030_candidate() {
  local repo="$1" base="$2" who="$3" repin="$4"
  git -C "$repo" checkout -q -b "task/$who" "$base"
  printf '%s\n' '#!/usr/bin/env bash' "echo candidate $who" > "$repo/lib/feature-$who.sh"
  if [ "$repin" = repin ]; then
    "$BASH" "$repo/scripts/pin-formula.sh" >/dev/null 2>&1 \
      || fail "T030 setup: candidate $who could not re-pin under the old contract"
  fi
  commit_fixture "$repo" "candidate $who"
}

# --- 1. RED: the per-candidate re-pin is what collides ---------------------
deadlock_repo="$(clone_fixture t030-deadlock)"
t030_fixture "$deadlock_repo"
deadlock_integ="$(git -C "$deadlock_repo" symbolic-ref --short HEAD)"
deadlock_base="$(git -C "$deadlock_repo" rev-parse HEAD)"

# The old contract, replayed exactly: change shipped bytes, then re-pin in the
# same commit, because the suite would otherwise fail this candidate.
t030_candidate "$deadlock_repo" "$deadlock_base" a repin
t030_candidate "$deadlock_repo" "$deadlock_base" b repin

deadlock_pin_a="$(git -C "$deadlock_repo" show "task/a:Formula/orchid.rb" \
  | sed -n 's/^[[:space:]]*sha256 "\([^"]*\)"$/\1/p')"
deadlock_pin_b="$(git -C "$deadlock_repo" show "task/b:Formula/orchid.rb" \
  | sed -n 's/^[[:space:]]*sha256 "\([^"]*\)"$/\1/p')"
if [ -z "$deadlock_pin_a" ] || [ -z "$deadlock_pin_b" ]; then
  fail "T030 setup: both re-pinning candidates must carry a pinned checksum"
fi
[ "$deadlock_pin_a" != "$deadlock_pin_b" ] \
  || fail "T030 setup: the two re-pinning candidates must pin DIFFERENT checksums"

# Candidate a lands first, exactly as merge would land it.
git -C "$deadlock_repo" checkout -q "$deadlock_integ"
git -C "$deadlock_repo" merge -q --no-ff -m "merge candidate a" task/a \
  || fail "T030 setup: the first re-pinning candidate should still merge cleanly"

# Candidate b is now on a stale base. This is libexec/orchid-merge's rebase
# arm, and it is where the run used to die.
rc=0
git -C "$deadlock_repo" rebase "$deadlock_integ" task/b >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "T030 premise broken: two candidates that each re-pin no longer conflict on rebase"
deadlock_conflicts="$(git -C "$deadlock_repo" diff --name-only --diff-filter=U)"
assert_match 'Formula/orchid.rb' "$deadlock_conflicts" \
  "the per-candidate re-pin is what conflicts, in Formula/orchid.rb itself"
git -C "$deadlock_repo" rebase --abort >/dev/null 2>&1 || true

# --- 2. GREEN: the shipped design, same two candidates ---------------------
# Nothing here re-pins, because nothing in a candidate's verification chain
# asks it to any more. That single difference is the whole fix.
land_repo="$(clone_fixture t030-sequential)"
t030_fixture "$land_repo"
land_integ="$(git -C "$land_repo" symbolic-ref --short HEAD)"
land_base="$(git -C "$land_repo" rev-parse HEAD)"
land_base_formula="$(git -C "$land_repo" show "$land_base:Formula/orchid.rb")"

for who in a b; do
  t030_candidate "$land_repo" "$land_base" "$who" no-repin
  assert_eq "$land_base_formula" "$(git -C "$land_repo" show "task/$who:Formula/orchid.rb")" \
    "candidate $who leaves Formula/orchid.rb byte-identical to its base"
done

git -C "$land_repo" checkout -q "$land_integ"
git -C "$land_repo" merge -q --no-ff -m "merge candidate a" task/a \
  || fail "the first candidate must land"

# The stale-base rebase that used to abort. No conflict, so no advance to
# rework, so no implementer is dispatched for work it cannot perform.
rc=0
git -C "$land_repo" rebase "$land_integ" task/b >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "the second candidate rebases onto the new base without a conflict"
git -C "$land_repo" checkout -q "$land_integ"
git -C "$land_repo" merge -q --no-ff -m "merge candidate b" task/b \
  || fail "the second candidate must land too"

# Both landed, and no operator touched anything in between.
git -C "$land_repo" show "$land_integ:lib/feature-a.sh" >/dev/null 2>&1 \
  || fail "candidate a's change is missing from the integration branch"
git -C "$land_repo" show "$land_integ:lib/feature-b.sh" >/dev/null 2>&1 \
  || fail "candidate b's change is missing from the integration branch"
assert_eq "$land_base_formula" "$(git -C "$land_repo" show "$land_integ:Formula/orchid.rb")" \
  "no task branch wrote Formula/orchid.rb, so the integration tip still carries the base pin"

# --- 3. The obligation moved to the integration branch ---------------------
# The pin is now genuinely stale for what the branch carries -- the fixed
# point T004 established is still a real obligation, it just belongs here.
rc=0
stale_out="$("$BASH" "$land_repo/scripts/pin-formula.sh" --check 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "two landed candidates must leave the integration branch's pin stale"
assert_match 'STALE' "$stale_out" "the integration branch's stale pin is named as such"

"$BASH" "$land_repo/scripts/pin-formula.sh" >/dev/null 2>&1 \
  || fail "pin-formula could not re-pin the integration branch"
land_repin_dirty="$(git -C "$land_repo" status --porcelain=v1 --untracked-files=all | awk '{print $NF}')"
assert_eq "Formula/orchid.rb" "$land_repin_dirty" \
  "re-pinning the integration branch rewrites Formula/orchid.rb and nothing else"
commit_fixture "$land_repo" "re-pin the formula for the integration branch"
"$BASH" "$land_repo/scripts/pin-formula.sh" --check >/dev/null 2>&1 \
  || fail "pin-formula --check rejects the checksum it just pinned on the integration branch"

# ...and the release gate agrees, on the tag, which is the property that had
# to survive this whole redesign: what ships is what the formula describes.
git -C "$land_repo" tag -f v1.2.3 >/dev/null
land_release_out="$("$BASH" "$land_repo/scripts/release.sh" \
  --tag v1.2.3 --output "$WORK/t030-release" --bash "$BASH" 2>&1)" \
  || fail "release gate rejected an integration branch whose pin was just refreshed: $land_release_out"
assert_match 'release verified: v1.2.3' "$land_release_out" \
  "one re-pin on the integration branch is enough to satisfy the release gate"

# --- 4. A stale pin still fails the release gate ---------------------------
# The gate moved; it did not soften. This is the only thing standing between
# a stale pin and a shipped archive now, so it is asserted directly, and on
# the remedy text too -- an operator meeting this message is the one person
# who has to know which branch to run the tool on.
stale_release_repo="$(clone_fixture t030-stale-pin)"
printf '%s\n' '#!/usr/bin/env bash' 'echo shipped' > "$stale_release_repo/lib/feature-a.sh"
commit_fixture "$stale_release_repo" "change shipped bytes without re-pinning"
git -C "$stale_release_repo" tag -f v1.2.3 >/dev/null
run_release_failure "$stale_release_repo" v1.2.3 \
  'formula checksum mismatch' t030-stale-pin
run_release_failure "$stale_release_repo" v1.2.3 \
  'pin-formula\.sh.* on the integration branch' t030-stale-pin-remedy

# --- 5. Tripwire: the per-candidate gate must not come back ----------------
# Assembled at runtime from fragments, the same way the mktemp and find scans
# above are, so this file can carry the check without matching it itself --
# and so no file is excluded from the scan, least of all this one, which is
# where the gate lived. What is forbidden is narrow and exact: RUNNING
# pin-formula against the live checkout from inside the suite. Copying the
# tool into a fixture (which this file does, twice, above) is untouched.
live_pin_pattern='REPO_ROOT'
live_pin_pattern="${live_pin_pattern}[^\"]*pin-formula[.]sh\"?[[:space:]]+[-]-check"

# A POSITIVE CONTROL FIRST, because the scan below is expected to match
# nothing -- and a pattern that has quietly stopped matching anything at all
# is indistinguishable from a clean tree. This is the exact line T030 removed
# from this file, reassembled from fragments so that carrying it here still
# does not trip the scan (no single fragment holds both `REPO_ROOT` and the
# `--check` argument). If the pattern ever stops recognising the gate it
# exists to forbid, this fails rather than the tripwire passing vacuously.
live_pin_removed_line='  freshness_out="$("$BASH" "$'
live_pin_removed_line="${live_pin_removed_line}REPO_ROOT/scripts/pin-formula.sh\" "
live_pin_removed_line="${live_pin_removed_line}--check 2>&1)\" || rc=\$?"
printf '%s\n' "$live_pin_removed_line" | grep -Eq "$live_pin_pattern" \
  || fail "the per-candidate freshness-gate tripwire no longer matches the line it forbids -- the scan below proves nothing"

while IFS= read -r shell_file; do
  [ -n "$shell_file" ] || continue
  grep -En "$live_pin_pattern" "$REPO_ROOT/$shell_file" >/dev/null \
    && fail "a shipped file re-introduced the per-candidate formula freshness gate (lesson L022): $shell_file"
done <<< "$shell_list"

# T019 added a trusted pre-command package-pin snapshot after this task's
# preserved candidate was first written. It is part of the driven verification
# chain even though it lives outside tests/run.sh, so the live-suite scan above
# cannot see it. Keep its generic per-file route, but require explicit opt-in:
# Orchid's unconfigured whole-tree Formula pin must not be built or checked for
# every task before the release gate needs it.
drive_pin_default="$(sed -n "s/^_DRIVE_PIN_CHECK_DEFAULT='\([^']*\)'$/\1/p" \
  "$REPO_ROOT/lib/drive.sh")"
assert_eq none "$drive_pin_default" \
  "the driver package-pin prestate route defaults to none, so T019 cannot silently reintroduce the whole-tree Formula check into every task chain"

# --- 6. Guidance must not put the Formula back in a candidate hand-off ------
# Moving the executable gate is insufficient if the shipped operator guidance
# still tells somebody to perform the same write by hand. These are the exact
# stale instructions found after the behavior was already green: following any
# of them makes task branches rewrite Formula/orchid.rb and recreates the RED
# rebase above. Keep both the old phrases absent and the replacement rule
# present, so a deletion cannot satisfy this check by making the docs silent.
# Fold first, following tests/test_docs.sh's established idiom: these are prose
# claims, not source lines, and an ordinary Markdown re-wrap must not break the
# gate or let a stale phrase straddle two lines undetected.
t030_folded_file() {
  tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '
}
t030_folded_shell_comments() {
  sed 's/^[[:space:]]*#[[:space:]]*//' "$1" \
    | tr '\n' ' ' \
    | tr -s '[:space:]' ' '
}
t030_config_guidance="$(t030_folded_file "$REPO_ROOT/orchid.config.example")"
t030_troubleshooting_guidance="$(t030_folded_file "$REPO_ROOT/docs/troubleshooting.md")"
t030_kernel_guidance="$(t030_folded_file "$REPO_ROOT/docs/specs/kernel.md")"
t030_drive_guidance="$(t030_folded_shell_comments "$REPO_ROOT/lib/drive.sh")"
t030_handoff_guidance="$(t030_folded_shell_comments "$REPO_ROOT/lib/handoff.sh")"

grep -Fq 're-pinning a release checksum' <<<"$t030_config_guidance" \
  && fail "orchid.config.example still describes a whole-tree release checksum as a candidate hand-off"
grep -Fq 'a re-pinned formula checksum' <<<"$t030_troubleshooting_guidance" \
  && fail "troubleshooting still describes the Formula checksum as candidate hand-off evidence"
while IFS= read -r guidance_file; do
  [ -n "$guidance_file" ] || continue
  guidance_text="$(t030_folded_file "$REPO_ROOT/$guidance_file")"
  grep -Fq 're-pinning Formula/orchid.rb after any change to shipped bytes' \
    <<<"$guidance_text" \
    && fail "$guidance_file still labels per-change Formula re-pinning as operator-owned candidate work"
done <<'EOF'
docs/beta-qualification.md
scripts/beta-qualify.sh
EOF
grep -Fq 'recognized with no per-repo configuration at all' \
  <<<"$t030_kernel_guidance" \
  && fail "kernel.md still claims the opt-in candidate-local pin route needs no configuration"
grep -Fq 'Every other proof here has no configuration at all' \
  <<<"$t030_drive_guidance" \
  && fail "lib/drive.sh still contradicts its opt-in candidate-local pin route"
grep -Fq 'a formula they re-pinned after re-reading the diff' \
  <<<"$t030_handoff_guidance" \
  && fail "lib/handoff.sh still offers whole-tree Formula pinning as candidate hand-off work"
grep -Fq 'Perform the hand-off (re-pin, `chmod +x`)' \
  <<<"$t030_troubleshooting_guidance" \
  && fail "troubleshooting still gives an unqualified re-pin as candidate hand-off work"

grep -Fq 'Never use this pause to re-pin a whole-tree release checksum' \
  <<<"$t030_config_guidance" \
  || fail "candidate hand-off configuration no longer says whole-tree release pins belong elsewhere"
grep -Fq 'preparation, never a candidate hand-off' \
  <<<"$(t030_folded_file "$REPO_ROOT/docs/beta-qualification.md")" \
  || fail "beta qualification no longer distinguishes Formula release preparation from candidate hand-offs"
grep -Fq 'is never such a hand-off' \
  <<<"$t030_troubleshooting_guidance" \
  || fail "troubleshooting no longer distinguishes Formula release preparation from candidate hand-offs"
grep -Fq 'candidate-local pin hand-off is available only when the repository explicitly configures `handoff.pin_check` (default `none`)' \
  <<<"$t030_kernel_guidance" \
  || fail "kernel.md no longer says the candidate-local pin route is explicit opt-in with a default-none setting"
grep -Fq 'The pin route defaults to `none` and must name a candidate-local check explicitly' \
  <<<"$t030_drive_guidance" \
  || fail "lib/drive.sh no longer documents the default-none candidate-local pin route"
grep -Fq 'a mode bit they restored after re-reading the diff' \
  <<<"$t030_handoff_guidance" \
  || fail "lib/handoff.sh no longer uses a candidate-local mechanical hand-off in its post-ack example"
grep -Fq 'refresh the explicitly configured candidate-local artifact or restore its mode with `chmod +x`' \
  <<<"$t030_troubleshooting_guidance" \
  || fail "troubleshooting no longer limits the pin hand-off to an explicitly configured candidate-local artifact"

# --- 7. scripts/pin-formula.sh must be executable in the index -------------
# r-001 set this mode bit on a branch as an operator hand-off and shipped a
# different commit, so the fix was silently dropped: the blob is identical to
# main's, the mode is not. It is harmless only because every caller spells
# `bash scripts/pin-formula.sh`; its release-tooling siblings ci-local.sh and
# release.sh are both 100755. Asserted on the INDEX rather than with `[ -x ]`
# so it is the committed tree being judged and not a checkout's local umask.
# Skipped inside an extracted release archive, which has no Git checkout at
# this root -- the same guard the removed freshness gate used.
if [ "$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)" = "$REPO_ROOT" ]; then
  pin_mode="$(git -C "$REPO_ROOT" ls-files -s -- scripts/pin-formula.sh | awk '{print $1}')"
  assert_eq 100755 "$pin_mode" \
    "scripts/pin-formula.sh is executable in the index (operator hand-off: chmod +x scripts/pin-formula.sh)"
fi

exit 0
