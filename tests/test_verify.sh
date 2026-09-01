#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create T001 "verify demo"
"$ORCHID_BIN" task set T001 verification_commands "exit 1"

out="$WORK/verify.out"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "failing command -> FAIL exits 1"
assert_match "^FAIL$" "$(cat "$out")" "prints FAIL"

log=".orchid/reviews/T001-verify.log"
[ -f "$log" ] || fail "evidence log written"
assert_match "^command: exit 1$" "$(cat "$log")" "evidence records the exact command"
assert_match "^exit: 1$" "$(cat "$log")" "evidence records the exit code"
assert_match "^date: " "$(cat "$log")" "evidence has date header"
assert_match "^sha: " "$(cat "$log")" "evidence has sha header"
assert_match "^cwd: " "$(cat "$log")" "evidence has cwd header"
assert_match "^---$" "$(cat "$log")" "evidence has separator"

# Now make it pass.
"$ORCHID_BIN" task set T001 verification_commands "exit 0"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "passing command -> PASS exits 0"
assert_match "^PASS$" "$(cat "$out")" "prints PASS"
assert_match "^exit: 0$" "$(cat "$log")" "evidence records exit 0 after fix"

# The verification command's stdin is /dev/null, never the caller's. This verb
# runs from inside runners/orchid-drive's task walk, whose own stdin is the
# worklist it is iterating, so a suite that reads stdin would consume the
# tasks the driver has not reached yet — the pass would end early, silently,
# with work skipped and no error raised anywhere.
stdin_probe="$WORK/verify-stdin.txt"
"$ORCHID_BIN" task set T001 verification_commands "cat > '$stdin_probe'"
rc=0; printf 'SWALLOWED\n' | "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "a command that reads stdin still passes"
[ -f "$stdin_probe" ] || fail "the verification command ran"
assert_eq "" "$(cat "$stdin_probe")" "the verification command reads EOF, never the caller's stdin"

# ---------------------------------------------------------------------------
# ORCHID_REPO_ROOT reaches the VERIFICATION command, not just the
# `worktree_prepare` command.
#
# A task's suite runs in a checkout Orchid made, which holds only what is
# committed; anything gitignored the suite needs lives in the dispatching
# repository, and this variable is the only portable handle on it -- a
# dispatch worktree is a sibling of the repository and a merge validation
# worktree is an unrelated $TMPDIR directory, so no fixed relative path
# reaches it from both. Without it in this environment the alternative is an
# absolute path hardcoded into committed config, which is exactly what the
# variable exists to make unnecessary.
#
# RED before this change: the command sees `unset` -- ORCHID_REPO_ROOT was
# exported to the prepare child only (lib/common.sh) and to nothing else.
# ---------------------------------------------------------------------------
root_probe="$WORK/verify-root.txt"
cat > "$WORK/verify-root.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s' "${ORCHID_REPO_ROOT-unset}" > "$1"
EOF
chmod +x "$WORK/verify-root.sh"
"$ORCHID_BIN" task set T001 verification_commands "$WORK/verify-root.sh $root_probe"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "the probe command passes"
# The expected value is the repository's PHYSICAL path, because that is what
# the verb resolves before exporting it: macOS hands out /var/folders symlinks
# for /private/var/folders, so a logical path would never compare equal.
# cd_scratch, not a plain `cd` (lesson L014): an empty $WORK would make `cd ""`
# a silent no-op and `pwd -P` would then report the CALLER's directory, so the
# EXPECTED side of this assertion would quietly become the real checkout --
# and a wrong expectation that happens to match is an assertion that no longer
# tests anything. tests/test_helpers.sh lints for this shape suite-wide.
WORKP="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root"; exit 1; }
assert_eq "$WORKP" "$(cat "$root_probe" 2>/dev/null || echo missing)" \
  "the verification command is handed the repository's own canonical path in ORCHID_REPO_ROOT"
