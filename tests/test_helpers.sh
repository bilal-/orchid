#!/usr/bin/env bash
# v1-m3 (m2 ledger finding): tests/helpers.sh's own WORK guard.
#
# Every test file's `cd "$WORK" || exit 1; git init -q .; git commit ...` pattern
# trusts that $WORK is a real, freshly-made scratch directory. If `mktemp -d`
# ever fails (disk full, TMPDIR misconfigured, sandboxing quirk...), plain
# `WORK="$(mktemp -d)"` leaves WORK="" -- NOT unset, so `set -u` never catches
# it. `cd ""` is a silent bash no-op (exit 0, cwd unchanged), so every
# subsequent `git init -q .`/`git commit` in the test file then runs against
# whatever the CALLER's cwd happened to be -- typically the real repo
# checkout under test. That is the exact "m2 stray-commit mishap": a test
# run left a stray empty commit in the real repo because WORK silently came
# back empty. helpers.sh must die loudly the instant WORK looks unusable,
# before any cd/git ever runs.
#
# This file does NOT source helpers.sh itself (it deliberately breaks the
# very thing helpers.sh depends on) and deliberately does NOT drive a full
# CLI-backed test file -- ORCHID_REPO/HOME derived from an empty WORK cascade
# into unrelated orchid-internals hangs (verb_lock_acquire spinning against
# an unwritable "/.orchid/runtime") that would obscure the one thing under
# test here. Instead it builds the SAME minimal cd/git pattern every real
# test file opens with, sources the real helpers.sh, and runs it as a
# subprocess with `mktemp` shadowed to always fail, from a disposable
# scratch cwd (never the real repo). Proves two things: (a) the subprocess
# dies loudly instead of limping on, and (b) no cd/git ever ran against that
# cwd (no stray .git appears in it).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
fail() { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }

fakebin="$(mktemp -d)"
scratch="$(mktemp -d)"
mini="$(mktemp -d)/mini_test.sh"
trap 'rm -rf "$fakebin" "$scratch" "$(dirname "$mini")"' EXIT

cat > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
# always fails, simulating mktemp -d being unable to produce a scratch dir
exit 1
EOF
chmod +x "$fakebin/mktemp"

cat > "$mini" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
cd "\$WORK"; git init -q .; git commit -q --allow-empty -m root
echo "reached-git-commit"
EOF

out="$(cd "$scratch" && PATH="$fakebin:$PATH" bash "$mini" 2>&1)"
rc=$?

[ "$rc" -ne 0 ] || fail "a test file must die (nonzero exit) when mktemp -d fails, not silently continue with an empty WORK"
echo "$out" | grep -qi 'mktemp\|WORK' || fail "the die message should name mktemp/WORK as the failure (got: $out)"
echo "$out" | grep -q 'reached-git-commit' && fail "execution must never reach the cd/git lines once mktemp -d has failed"
[ ! -d "$scratch/.git" ] || fail "guard failed to stop cd/git from running against the caller's cwd -- a .git dir was created in $scratch (the exact m2 stray-commit mishap)"

[ "$FAILS" -eq 0 ] && echo "helpers.sh WORK guard: OK"
exit $((FAILS > 0))
