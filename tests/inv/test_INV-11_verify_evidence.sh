#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

# INV-11: evidence is the sole authority — the log must exist, must record
# the exact command and exit code, and must flip honestly (FAIL -> PASS)
# purely because the underlying condition changed, never because the log
# was fudged.
"$ORCHID_BIN" task create T001 "flip demo"
"$ORCHID_BIN" task set T001 verification_commands "test -f marker.txt"

log=".orchid/reviews/T001-verify.log"
out="$WORK/verify.out"

rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "no marker -> FAIL"
assert_match "^FAIL$" "$(cat "$out")" "prints FAIL before marker exists"
[ -f "$log" ] || fail "evidence log exists after FAIL run"
assert_match "^command: test -f marker\.txt$" "$(cat "$log")" "evidence records exact command (FAIL run)"
assert_match "^exit: [1-9][0-9]*$" "$(cat "$log")" "evidence records nonzero exit (FAIL run)"

touch "$WORK/marker.txt"

rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 0 "$rc" "marker present -> PASS"
assert_match "^PASS$" "$(cat "$out")" "prints PASS after marker created"
[ -f "$log" ] || fail "evidence log exists after PASS run"
assert_match "^command: test -f marker\.txt$" "$(cat "$log")" "evidence records exact command (PASS run)"
assert_match "^exit: 0$" "$(cat "$log")" "evidence records exit 0 (PASS run)"

# Honesty check: the same command, same task, only the filesystem state
# changed — the log's own recorded exit code decided FAIL then PASS.
rm -f "$WORK/marker.txt"
rc=0; "$ORCHID_BIN" verify T001 >"$out" 2>&1 || rc=$?
assert_eq 1 "$rc" "removing marker flips back to FAIL"
assert_match "^exit: [1-9][0-9]*$" "$(cat "$log")" "evidence flips back honestly"

# No verification_commands on the task and no config 'verify' -> dies
# nonzero with a clear message; no engine spawn is required to detect this.
"$ORCHID_BIN" task create T002 "no-command"
rc=0; err="$("$ORCHID_BIN" verify T002 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "verify with no command source must exit nonzero"
echo "$err" | grep -qi "verification_commands\|verify" || fail "die message must reference the missing verification source (got: $err)"
[ ! -f ".orchid/reviews/T002-verify.log" ] || fail "no evidence log should be written when there is nothing to run"

# INV-11 kernel enforcement: `task advance <id> reviewing` from `testing`
# must be gated on real, passing verify evidence — not merely reachable by
# calling advance directly, bypassing `orchid verify` entirely (or ignoring
# a prior FAIL). This is the kernel closing the enforcement gap, not the
# orchestrator's convention.
head_sha="$(git -C "$WORK" rev-parse HEAD)"
"$ORCHID_BIN" task create T003 "reviewing-gate"
"$ORCHID_BIN" task set T003 base_sha "$head_sha"
"$ORCHID_BIN" task set T003 candidate_sha "$head_sha"
"$ORCHID_BIN" task advance T003 implementing >/dev/null
"$ORCHID_BIN" task advance T003 testing >/dev/null

# (a) no evidence log at all -> advance to reviewing must be refused.
[ ! -f .orchid/reviews/T003-verify.log ] || fail "sanity: no evidence log should exist yet for T003"
rc=0; err="$("$ORCHID_BIN" task advance T003 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-11: reviewing with no verify evidence at all must be refused"
echo "$err" | grep -qi "verify" || fail "INV-11: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "INV-11: refused advance leaves status at testing"

# (b) evidence exists but the last line records a FAIL -> still refused.
# Honest fixture: a real `orchid verify` run with a failing command, not a
# hand-written log.
"$ORCHID_BIN" task set T003 verification_commands "false"
rc=0; "$ORCHID_BIN" verify T003 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "fixture: real verify FAIL for T003"
tail -n1 .orchid/reviews/T003-verify.log | grep -q "^exit: 0$" && fail "sanity: fixture evidence should record a nonzero exit"
rc=0; err="$("$ORCHID_BIN" task advance T003 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-11: reviewing after a FAIL verify run must be refused"
echo "$err" | grep -qi "verify" || fail "INV-11: die message must mention verify (got: $err)"

# (c) evidence exists and the last line is a real passing verify -> advance
# succeeds. Same honest-fixture approach: a real `orchid verify` PASS run.
"$ORCHID_BIN" task set T003 verification_commands "true"
rc=0; "$ORCHID_BIN" verify T003 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: real verify PASS for T003"
tail -n1 .orchid/reviews/T003-verify.log | grep -q "^exit: 0$" || fail "sanity: fixture evidence should record exit 0"
"$ORCHID_BIN" task advance T003 reviewing >/dev/null || fail "INV-11: reviewing after a passing verify run must be permitted"
assert_eq reviewing "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "INV-11: T003 advanced to reviewing"

# v0b1 fix: rework-loop stale-evidence symmetry. `orchid merge`'s rebase-reset
# invalidates verify/merge evidence on exit-5 (INV-07); the same must be true
# of every OTHER path back into rework (advance:rework, unblock, retry) — a
# reworked task gets a new candidate, so evidence about the old one must not
# survive to satisfy the INV-11 gate above. Walk:
# verify-PASS -> reviewing -> arbitrating -> rework --reason x -> implementing
# -> (new candidate_sha) -> testing -> advance reviewing must DIE until re-verify.
"$ORCHID_BIN" task create T004 "rework-symmetry"
"$ORCHID_BIN" task set T004 base_sha "$head_sha"
"$ORCHID_BIN" task set T004 candidate_sha "$head_sha"
"$ORCHID_BIN" task set T004 verification_commands "true"
"$ORCHID_BIN" task advance T004 implementing >/dev/null
"$ORCHID_BIN" task advance T004 testing >/dev/null
rc=0; "$ORCHID_BIN" verify T004 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: real verify PASS for T004"
"$ORCHID_BIN" task advance T004 reviewing >/dev/null
"$ORCHID_BIN" task advance T004 arbitrating --reason "single reviewer approved" >/dev/null

[ -f .orchid/reviews/T004-verify.log ] || fail "sanity: verify evidence exists before rework"

"$ORCHID_BIN" task advance T004 rework --reason "found an issue in review" >/dev/null

[ ! -f .orchid/reviews/T004-verify.log ] || fail "rework: stale verify evidence must be invalidated on entry to rework (INV-07 symmetry)"
[ ! -f .orchid/reviews/T004-merge.log ] || fail "rework: stale merge evidence must be invalidated on entry to rework (INV-07 symmetry)"

"$ORCHID_BIN" task advance T004 implementing >/dev/null

# New candidate: an actual new commit (child of head_sha, not on any branch),
# so the base..candidate range is real and the testing-entry .orchid/ guard
# (INV-04) is satisfied honestly rather than faked.
new_cand="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "rework fix")"
[ -n "$new_cand" ] || fail "sanity: could not mint a new candidate commit for T004"
"$ORCHID_BIN" task set T004 candidate_sha "$new_cand"
"$ORCHID_BIN" task advance T004 testing >/dev/null

rc=0; err="$("$ORCHID_BIN" task advance T004 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "rework: reviewing must be refused before re-verify of the new candidate (stale evidence invalidated -> INV-11 gate)"
echo "$err" | grep -qi "verify" || fail "rework: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "rework: refused advance leaves status at testing"

rc=0; "$ORCHID_BIN" verify T004 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "re-verify passes on the new candidate"
"$ORCHID_BIN" task advance T004 reviewing >/dev/null || fail "rework: reviewing permitted after honest re-verify"
assert_eq reviewing "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "rework: T004 advanced to reviewing after re-verify"

# v0b1 fix: merging->rework (validation-fail) symmetry. The advance:rework
# arm's `from != merging` guard was written to protect $id-merge.log (which
# documents the very validation failure `orchid-merge` is about to report),
# but it accidentally shielded $id-verify.log too — so the MOST common rework
# loop (reviewer approves, merge's own independent re-verification then fails
# in its detached temp worktree) left the old candidate's stale PASS verify
# evidence in place, ready to wrongly satisfy INV-11's gate for a candidate
# that was never actually re-verified. Continue T004 on into `merging` to
# exercise exactly that path.
integ=orchid/integration
git -C "$WORK" branch "$integ" "$head_sha"

"$ORCHID_BIN" task advance T004 arbitrating --reason "single reviewer approved" >/dev/null

# A command that passes on a NAMED branch checkout (here, $WORK's own
# checkout, used for the testing->reviewing verify gate above) but fails on a
# DETACHED HEAD (merge's own temp worktree) — forces merge's independent
# re-run of the suite to fail deterministically, without needing a
# semantically-differing merged tree.
vcmd_merge='test "$(git rev-parse --abbrev-ref HEAD)" != HEAD'
"$ORCHID_BIN" task set T004 verification_commands "$vcmd_merge"
"$ORCHID_BIN" task advance T004 merging --reason "approved for merge" >/dev/null

[ -f .orchid/reviews/T004-verify.log ] || fail "sanity: verify evidence exists before the merge attempt"

rc=0; "$ORCHID_BIN" merge T004 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "fixture: merge validation fails in its detached temp worktree"
assert_eq rework "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "sanity: T004 back in rework after merge validation-fail"

[ ! -f .orchid/reviews/T004-verify.log ] || fail "merging->rework: stale verify evidence must be invalidated too (validation-fail is the MOST common rework loop)"
[ -f .orchid/reviews/T004-merge.log ] || fail "merging->rework: merge.log must SURVIVE — it documents the failure just journaled"

"$ORCHID_BIN" task advance T004 implementing >/dev/null

# Another new candidate, same honest commit-tree mint as above.
new_cand2="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "second rework fix")"
[ -n "$new_cand2" ] || fail "sanity: could not mint a second new candidate commit for T004"
"$ORCHID_BIN" task set T004 candidate_sha "$new_cand2"
"$ORCHID_BIN" task advance T004 testing >/dev/null

rc=0; err="$("$ORCHID_BIN" task advance T004 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "merging->rework: reviewing must be refused before re-verify of the newest candidate (stale evidence invalidated -> INV-11 gate)"
echo "$err" | grep -qi "verify" || fail "merging->rework: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "merging->rework: refused advance leaves status at testing"

rc=0; "$ORCHID_BIN" verify T004 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "re-verify passes on the newest candidate"
"$ORCHID_BIN" task advance T004 reviewing >/dev/null || fail "merging->rework: reviewing permitted after honest re-verify"
assert_eq reviewing "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "merging->rework: T004 advanced to reviewing after re-verify"

# v0b2: sha-binding regression. The rm-based invalidations above only fire on
# SPECIFIC transitions (rework entry, unblock, retry, merge's rebase-reset).
# A bare `task set candidate_sha` (out-of-band bump — e.g. an operator
# correcting a mis-recorded SHA, or a future code path that doesn't yet know
# it needs to invalidate evidence) bypasses every one of them: the old
# verify log is still sitting on disk with `exit: 0`. Pre-sha-binding, that
# stale PASS would wrongly satisfy INV-11's gate for a candidate that was
# NEVER actually verified. Sha-binding closes this permanently by requiring
# the evidence's own `candidate:` line to match the task's current
# candidate_sha, not merely existing with a passing exit code.
"$ORCHID_BIN" task create T005 "sha-binding"
"$ORCHID_BIN" task set T005 base_sha "$head_sha"
"$ORCHID_BIN" task set T005 candidate_sha "$head_sha"
"$ORCHID_BIN" task set T005 verification_commands "true"
"$ORCHID_BIN" task advance T005 implementing >/dev/null
"$ORCHID_BIN" task advance T005 testing >/dev/null
rc=0; "$ORCHID_BIN" verify T005 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: real verify PASS for T005"
tail -n1 .orchid/reviews/T005-verify.log | grep -q "^exit: 0$" || fail "sanity: T005 evidence records exit 0"
assert_match "^candidate: $head_sha$" "$(cat .orchid/reviews/T005-verify.log)" "sanity: T005 evidence bound to the pre-bump candidate"

new_cand5="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "out-of-band bump")"
[ -n "$new_cand5" ] || fail "sanity: could not mint a new candidate commit for T005"
"$ORCHID_BIN" task set T005 candidate_sha "$new_cand5"

[ -f .orchid/reviews/T005-verify.log ] || fail "sanity: stale evidence log still present (rm-based invalidation does not fire on a bare task set)"
rc=0; err="$("$ORCHID_BIN" task advance T005 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "sha-binding: reviewing must be refused when evidence's candidate != task's current candidate_sha, despite a passing exit code"
echo "$err" | grep -qi "candidate\|verify" || fail "sha-binding: die message must mention candidate/verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" "sha-binding: refused advance leaves status at testing"

rc=0; "$ORCHID_BIN" verify T005 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "re-verify passes and binds evidence to the new candidate"
"$ORCHID_BIN" task advance T005 reviewing >/dev/null || fail "sha-binding: reviewing permitted after re-verify binds to the new candidate"
assert_eq reviewing "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" "sha-binding: T005 advanced to reviewing after re-verify"

# v0b2 fix: vacuous none-candidate evidence must never satisfy the gate.
# `orchid verify` writes a literal `candidate: none` header line when
# candidate_sha is empty at verify time (see orchid-verify). The sha-binding
# compare defaults an empty frontmatter candidate_sha to the same "none"
# sentinel, so a genuinely vacuous evidence log (never bound to any real
# sha) previously matched a genuinely vacuous frontmatter (candidate_sha
# cleared) — a string equality on a placeholder, not proof of anything.
# The gate must refuse whenever either side is none/empty; only a real
# sha == sha match may pass. Recipe: verify while candidate_sha is empty
# (bakes `candidate: none`, exit: 0 into the log), THEN set real
# base_sha/candidate_sha and walk the task to testing, THEN clear
# candidate_sha back to empty (frontmatter fcand becomes "none" again,
# same as vcand, same stale log) -> advance reviewing must DIE.
"$ORCHID_BIN" task create T006 "vacuous-none-candidate"
"$ORCHID_BIN" task set T006 verification_commands "true"

rc=0; "$ORCHID_BIN" verify T006 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: verify PASS for T006 with no candidate_sha set"
assert_match "^candidate: none$" "$(cat .orchid/reviews/T006-verify.log)" "sanity: T006 evidence records literal candidate: none"

"$ORCHID_BIN" task set T006 base_sha "$head_sha"
"$ORCHID_BIN" task set T006 candidate_sha "$head_sha"
"$ORCHID_BIN" task advance T006 implementing >/dev/null
"$ORCHID_BIN" task advance T006 testing >/dev/null

"$ORCHID_BIN" task set T006 candidate_sha ""

rc=0; err="$("$ORCHID_BIN" task advance T006 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "vacuous-none: reviewing must be refused when both evidence and frontmatter candidate are none — a vacuous match, never a real sha"
echo "$err" | grep -qi "candidate\|verify" || fail "vacuous-none: die message must mention candidate/verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T006 | grep '^status: ' | cut -d' ' -f2)" "vacuous-none: refused advance leaves status at testing"
