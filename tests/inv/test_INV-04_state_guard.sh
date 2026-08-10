#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: a candidate branch carrying a commit that writes `.orchid/tasks/EVIL.md`
#      is built for real below, and the advance into `testing` over that range
#      must be REFUSED. A run whose candidate can edit its own durable state
#      is a run that can approve itself, so this is the one input the guard
#      exists to reject.
# GREEN: the same walk without such a commit reaches `testing` (the fixture
#      advances T001 into `implementing` first, which the same verb allows),
#      and the second case checks the other direction: the guard must also
#      refuse an entry with unset base_sha/candidate_sha, where an
#      empty-range comparison would otherwise find nothing and pass vacuously.
cd_scratch "$WORK" || exit 1; git init -q .; echo a > a.txt; git add a.txt; git commit -q -m base
# .orchid/runtime/ is machine-local, volatile state (per kernel.md) and must
# never be committed; without this, `git add .orchid` below would sweep the
# live epoch/lease files onto task/T001, and checking back out to main would
# delete them from the working tree — an unrelated defect that would corrupt
# the epoch fence, not what this test is exercising.
echo ".orchid/runtime/" > .gitignore; git add .gitignore; git commit -q -m gitignore
mkdir -p .orchid/tasks; git add .orchid 2>/dev/null || true
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo
# Commit the task file to main before branching: otherwise it's untracked on
# main, gets swept into the task/T001 commit below, and checking back out to
# main deletes it from the working tree (tracked-on-one-branch-only files are
# removed by checkout) — corrupting the fixture, not exercising INV-04.
git add .orchid && git commit -q -m "add task T001"
base="$(git rev-parse HEAD)"
git checkout -q -b task/T001
mkdir -p .orchid/tasks && echo hacked > .orchid/tasks/EVIL.md
git add .orchid && git commit -q -m "touch state"
cand="$(git rev-parse HEAD)"; git checkout -q -
"$ORCHID_BIN" task set T001 base_sha "$base"
"$ORCHID_BIN" task set T001 candidate_sha "$cand"
"$ORCHID_BIN" task advance T001 implementing >/dev/null
rc=0; "$ORCHID_BIN" task advance T001 testing 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-04: commit touching .orchid/ must block testing"

# Plan-A backlog step 9: entry to `testing` now REQUIRES non-empty
# base_sha/candidate_sha, making the INV-04 guard non-vacuous.
"$ORCHID_BIN" task create T002 "no-shas"
"$ORCHID_BIN" task advance T002 implementing >/dev/null
rc=0; "$ORCHID_BIN" task advance T002 testing 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "INV-04: entry to testing with unset base_sha/candidate_sha must be refused"
red_case "the state guard refused entry to testing for a candidate that commits .orchid/, and for a task with no range to judge at all"
