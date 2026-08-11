#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: a candidate branch carrying a commit that writes `.orchid/tasks/EVIL.md`
#      is built for real below, and the advance into `testing` over that range
#      must be REFUSED. A run whose candidate can edit its own durable state
#      is a run that can approve itself, so this is the one input the guard
#      exists to reject.
# GREEN: T003 at the bottom -- a candidate range built the same way but
#      touching no `.orchid/` path, with both SHAs set -- must be ALLOWED into
#      `testing` by the same verb. It runs HERE rather than being delegated:
#      every other case in this file is a refusal, and a guard that refused
#      every entry would satisfy all of them while gating nothing.
#      The second refusal covers the other direction the guard must cover: an
#      entry with unset base_sha/candidate_sha, where an empty-range
#      comparison would otherwise find nothing and pass vacuously.
cd_scratch "$WORK" || exit 1; git init -q .; echo a > a.txt; git add a.txt; git commit -q -m base
# .orchid/runtime/ is machine-local, volatile state (per kernel.md) and must
# never be committed; without this, `git add .orchid` below would sweep the
# live epoch/lease files onto task/T001, and checking back out to main would
# delete them from the working tree — an unrelated defect that would corrupt
# the epoch fence, not what this test is exercising.
echo ".orchid/runtime/" > .gitignore; git add .gitignore; git commit -q -m gitignore
mkdir -p .orchid/tasks; git add .orchid 2>/dev/null || true
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
# This fixture holds three tasks in an active status at once (T001 and T002 for
# the two refusals, T003 for the GREEN twin at the bottom), which is over the
# v1 default `concurrency` cap of 2 -- and the dispatch gate would then refuse
# T003's advance for a scheduling reason that has nothing to do with INV-04.
printf 'concurrency=10\n' > orchid.config
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

# THE GREEN TWIN, exercised in this file rather than delegated to another one.
# Both cases above are REFUSALS, and a guard that refused every entry to
# `testing` would satisfy both while gating nothing -- the state machine would
# simply be stuck, and this file would still pass. So the same verb is given
# the input it must ACCEPT: a candidate range that touches no `.orchid/` path,
# with both SHAs set, over exactly the same walk.
git checkout -q -b task/T003
echo clean > clean.txt; git add clean.txt; git commit -q -m "candidate that touches no durable state"
t3_cand="$(git rev-parse HEAD)"; git checkout -q -
"$ORCHID_BIN" task create T003 "clean range"
"$ORCHID_BIN" task set T003 base_sha "$base"
"$ORCHID_BIN" task set T003 candidate_sha "$t3_cand"
"$ORCHID_BIN" task advance T003 implementing >/dev/null
"$ORCHID_BIN" task advance T003 testing >/dev/null \
  || fail "INV-04: a candidate range touching no .orchid/ path, with both SHAs set, must be ALLOWED into testing -- otherwise the two refusals above are equally consistent with a guard that refuses everything"
green_case "a candidate range touching no .orchid/ path, with both SHAs set, was allowed into testing by the same verb that refused the two inputs above"
