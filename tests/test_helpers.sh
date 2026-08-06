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

# ---------------------------------------------------------------------------
# v1-m4 T006: the SECOND way $WORK reaches a fixture empty, which the guard
# above cannot cover -- helpers.sh never loaded at all. An INSTRUMENTED COPY
# of a test file, run from a directory where `$(dirname "$0")/helpers.sh`
# does not resolve, gets a `source` that prints "No such file" and KEEPS
# GOING with WORK simply unset; `cd ""` is a silent no-op, and the git init
# and two commits that follow land in the caller's cwd. That is how T006's
# incident rewrote a real task worktree's orchid.config to a fixture's
# `verify=true` -- which would have made every later `orchid verify` pass
# without running a test. `cd_scratch` (an undefined command when helpers.sh
# is missing: bash exits 127) plus the fixtures' existing `|| exit 1` is what
# makes that case fail closed, so prove it does.
unsourced="$(mktemp -d)/unsourced_test.sh"
cwd2="$(mktemp -d)"
cat > "$unsourced" <<'EOF'
#!/usr/bin/env bash
source "/nonexistent/path/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
echo "reached-git-commit"
EOF
out2="$(cd "$cwd2" && bash "$unsourced" 2>&1)"
rc2=$?
[ "$rc2" -ne 0 ] || fail "a test file whose helpers.sh never loaded must die, not run git against the caller's cwd"
echo "$out2" | grep -q 'reached-git-commit' && fail "execution must never reach the git lines when helpers.sh failed to load"
[ ! -d "$cwd2/.git" ] || fail "an unsourced test file git-initialized the caller's cwd ($cwd2) -- the T006 stray-commit incident, again"

# ---------------------------------------------------------------------------
# And the registry half: cd_scratch accepts ONLY directories this run created
# (its own $WORK/$MACHINE_HOME and anything made through make_scratch, plus
# paths beneath them). A real, existing directory that simply is not one of
# them -- a repo checkout being the case that matters -- is refused, so a
# fixture pointed at the wrong tree by an edit or a stray env var cannot
# git-write it.
outsider="$(mktemp -d)"
cwd3="$(mktemp -d)"
foreign="$(mktemp -d)/foreign_test.sh"
cat > "$foreign" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
cd_scratch "$outsider" || exit 1; git init -q .; git commit -q --allow-empty -m root
echo "reached-git-commit"
EOF
# Run from a disposable cwd, never this file's own (which is the real
# checkout): if the guard under test were broken, the `git init` above would
# land wherever this ran.
out3="$(cd "$cwd3" && bash "$foreign" 2>&1)"
rc3=$?
[ "$rc3" -ne 0 ] || fail "cd_scratch must refuse a directory this run did not create"
echo "$out3" | grep -q 'reached-git-commit' && fail "execution must never reach the git lines after a refused cd_scratch"
[ ! -d "$outsider/.git" ] || fail "cd_scratch cd'd into an unregistered directory and git-initialized it"
[ ! -d "$cwd3/.git" ] || fail "a refused cd_scratch let git run against the caller's cwd ($cwd3)"
rm -rf "$outsider" "$cwd3" "$(dirname "$foreign")" "$(dirname "$unsourced")" "$cwd2"

# ---------------------------------------------------------------------------
# Suite-wide lint, so the shape cannot come back one file at a time: no test
# file may start a command with a plain `cd` into a BARE scratch root -- a
# variable whose whole value is one `mktemp -d` result, and therefore the only
# kind that can arrive EMPTY and turn `cd` into a silent no-op. Paths built as
# "$WORK/sub" are exempt by construction: with WORK empty they degrade to
# "/sub", which `cd` rejects, so the fixtures' `|| exit 1` already fails closed
# there (and "$WORK/.." is deliberately outside the registry, so it must stay
# a plain `cd`).
#
# The root list is DERIVED per file, not hardcoded: helpers.sh's own two, plus
# every `VAR="$(mktemp -d)"` and every `make_scratch VAR` the file itself
# declares. A fixture that mints a new scratch root tomorrow is covered
# without anyone remembering to extend a list here.
lint_hits=""
for f in "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/tests/inv/*.sh; do
  [ -f "$f" ] || continue
  [ "${f##*/}" = test_helpers.sh ] && continue
  roots=(WORK MACHINE_HOME)
  # Anchored at the END on purpose: `X="$(mktemp -d)/sub"` is NOT a bare root
  # (it cannot come out empty), and matching it here would flag a `cd` that is
  # already safe.
  while IFS= read -r v; do
    [ -n "$v" ] && roots+=("$v")
  done < <(
    grep -oE '[A-Za-z_][A-Za-z0-9_]*="\$\(mktemp -d\)"$' "$f" | cut -d= -f1
    grep -oE 'make_scratch [A-Za-z_][A-Za-z0-9_]*' "$f" | cut -d' ' -f2
  )
  for v in "${roots[@]}"; do
    hit="$(grep -nE '(^|[;&|(])[[:space:]]*cd "\$'"$v"'"' "$f" || true)"
    [ -z "$hit" ] || lint_hits="$lint_hits
${f#"$REPO_ROOT"/}:$hit"
  done
done
[ -z "$lint_hits" ] || fail "these fixtures cd into a bare scratch root with plain \`cd\` -- use cd_scratch, which refuses an empty or foreign path:$lint_hits"

[ "$FAILS" -eq 0 ] && echo "helpers.sh WORK guard: OK"
exit $((FAILS > 0))
