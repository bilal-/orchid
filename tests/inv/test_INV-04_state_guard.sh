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
rc=0; t1_out="$("$ORCHID_BIN" task advance T001 testing 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-04: commit touching .orchid/ must block testing"
# EXIT 3, the code every refusal of an EDGE uses -- an illegal transition, a
# dispatch the schedule declines, the reverify-edge gates. This refusal used to
# be a plain die (exit 1) here while `task reverify` exited 3 asking the very
# same question a moment earlier, so ONE condition answered with two codes
# depending on which door was used and no caller could branch on the status.
# The reverify door is held to this same number at the bottom of this file.
assert_eq 3 "$rc" "INV-04: entry refused with the transition-refusal code (out: $t1_out)"

# Plan-A backlog step 9: entry to `testing` now REQUIRES non-empty
# base_sha/candidate_sha, making the INV-04 guard non-vacuous.
"$ORCHID_BIN" task create T002 "no-shas"
"$ORCHID_BIN" task advance T002 implementing >/dev/null
rc=0; t2_out="$("$ORCHID_BIN" task advance T002 testing 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-04: entry to testing with unset base_sha/candidate_sha must be refused"
assert_eq 3 "$rc" "INV-04: the vacuous-range refusal carries the same code as every other refused edge (out: $t2_out)"
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

# THE SAME CONDITION THROUGH THE OTHER DOOR, WITH THE SAME CODE. `orchid task
# reverify` reaches `testing` from an idle status and asks this guard about the
# sha it is ABOUT to stamp, so the identical candidate has to be refused there
# -- and refused with the identical exit code. One condition answering with two
# codes depending on the verb typed is a distinction no caller can act on and
# every caller has to know about.
#
# T004 is given the EVIL candidate through a worktree of its own, checked out on
# the branch that carries it: the reverify edge stamps the worktree's HEAD, so
# this is what "the operator says that tree is green" looks like for a candidate
# that rewrites the run's own state.
git worktree add -q "$WORK/wt-t001" task/T001 \
  || fail "fixture: could not check out the candidate branch in a worktree of its own"
"$ORCHID_BIN" task create T004 "the same candidate, through the reverify door"
"$ORCHID_BIN" task set T004 base_sha "$base"
"$ORCHID_BIN" task set T004 candidate_sha "$cand"
"$ORCHID_BIN" task set T004 branch task/T001
"$ORCHID_BIN" task set T004 worktree "$WORK/wt-t001"
"$ORCHID_BIN" task advance T004 blocked --reason "fixture: parked where an operator would reach for reverify"
rc=0; t4_out="$("$ORCHID_BIN" task reverify T004 --reason "the tree over there is green, honest" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-04: reverify must refuse a candidate whose range commits .orchid/ — the guard belongs to the edge, not to one verb"
assert_eq 3 "$rc" "INV-04: and refuses it with the same code the raw advance uses (out: $t4_out)"
assert_match "touch .orchid/" "$t4_out" "naming the same reason, in the same words (out: $t4_out)"
assert_eq blocked "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" \
  "and the refused reverify left the task where it was"
red_case "the same .orchid/-touching candidate was refused entry to testing through the reverify verb as through task advance, with the same exit code"
