#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: a verification command that genuinely fails (`test -f marker.txt` with
#      no marker) must produce FAIL, an evidence log recording that exact
#      command and a nonzero exit, and a REFUSED advance to `reviewing`. The
#      marker is then removed again after a passing run, and the evidence
#      must flip back -- evidence that only ever says PASS is the exact defect
#      this invariant names, and a `verify` whose log could not record a
#      failure would gate nothing.
# GREEN: with the marker present the same command must PASS, log `exit: 0`,
#      and let the advance through, so the refusals above are the evidence
#      gate reading the real outcome rather than a verb that always refuses.
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
# v1-m2 Task 5: this fixture runs T001..T006 through several overlapping
# lifecycle walks in the SAME repo (several sit in an active status —
# reviewing/testing/arbitrating — at once by design, unrelated to
# concurrency itself); raise the cap well above the v1 default (2) so the
# new dispatch gate never interferes with this file's INV-11 evidence
# assertions. Kept comfortably ABOVE the task count rather than level with it
# (T031): a fixture sitting exactly on its own cap starves the next case added
# after it, and reports that as a status assertion failing somewhere else.
printf 'concurrency=16\n' > orchid.config
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# verify_at <candidate-sha> <task-id> -- run `orchid verify` with that
# candidate actually CHECKED OUT, then put the checkout back where it was.
#
# T031: `orchid verify` now refuses a tree that is not the task's recorded
# candidate_sha, so a fixture that bumps candidate_sha to a commit it never
# checked out is no longer verifying anything -- it is exercising the refusal.
# Every candidate minted below shares head_sha's tree, so the reset is a pure
# HEAD move with no working-file churn, and restoring afterwards keeps the
# later fixtures that key off head_sha honest without rewriting them.
verify_at() {
  local at="$1" id="$2" restore rc=0
  restore="$(git -C "$WORK" rev-parse HEAD)"
  git -C "$WORK" reset -q --hard "$at"
  "$ORCHID_BIN" verify "$id" >/dev/null 2>&1 || rc=$?
  git -C "$WORK" reset -q --hard "$restore"
  return "$rc"
}

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
assert_match "^prestate: 1$" "$(cat "$log")" "evidence marks the trusted pre-verification snapshot contract"
assert_match '^pre_base_sha: "(none|[0-9a-f]{40})"$' "$(cat "$log")" \
  "evidence binds classifier authority comparisons to base_sha before candidate-controlled verification"
assert_match '^pre_exec_missing: "' "$(cat "$log")" "evidence records the pre-run exec-bit set as one JSON string"
assert_match '^pre_env_missing: "' "$(cat "$log")" "evidence records the pre-run missing-build-state set as one JSON string"
assert_match '^pre_env_inventory: "' "$(cat "$log")" "evidence records the pre-run environment resolution inventory as one JSON string"
assert_match '^pre_pin_stale: "' "$(cat "$log")" "evidence records the pre-run stale-pin proof as one JSON string"
assert_match '^pre_integration_head: "[0-9a-f]{40}"$' "$(cat "$log")" \
  "evidence binds old-branch control-plane authority to integration HEAD before candidate-controlled verification"
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
red_case "verify evidence recorded a real FAIL, flipped to PASS only when the underlying condition changed, and flipped back when it changed again"

# No verification_commands on the task and no config 'verify' -> dies
# nonzero with a clear message; no engine spawn is required to detect this.
"$ORCHID_BIN" task create T002 "no-command"
rc=0; err="$("$ORCHID_BIN" verify T002 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "verify with no command source must exit nonzero"
# HERESTRINGS throughout this file, never `echo "$err" | grep -qi` and never
# `tail -n1 <log> | grep -q` (T016/INV-15 section 5): `grep -q` exits at its
# first match and SIGPIPEs the producer, and under helpers.sh's `set -o
# pipefail` that kill-by-signal status becomes the pipeline's -- so a die
# message that DOES name verify reads as one that does not, and the `&& fail`
# sanity line below is skipped exactly when the evidence really does record
# the wrong exit.
grep -qi "verification_commands\|verify" <<<"$err" || fail "die message must reference the missing verification source (got: $err)"
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
grep -qi "verify" <<<"$err" || fail "INV-11: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "INV-11: refused advance leaves status at testing"

# (b) evidence exists but the last line records a FAIL -> still refused.
# Honest fixture: a real `orchid verify` run with a failing command, not a
# hand-written log.
"$ORCHID_BIN" task set T003 verification_commands "false"
rc=0; "$ORCHID_BIN" verify T003 >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "fixture: real verify FAIL for T003"
grep -q "^exit: 0$" <<<"$(tail -n1 .orchid/reviews/T003-verify.log)" && fail "sanity: fixture evidence should record a nonzero exit"
rc=0; err="$("$ORCHID_BIN" task advance T003 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-11: reviewing after a FAIL verify run must be refused"
grep -qi "verify" <<<"$err" || fail "INV-11: die message must mention verify (got: $err)"

# (c) evidence exists and the last line is a real passing verify -> advance
# succeeds. Same honest-fixture approach: a real `orchid verify` PASS run.
"$ORCHID_BIN" task set T003 verification_commands "true"
rc=0; "$ORCHID_BIN" verify T003 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "fixture: real verify PASS for T003"
grep -q "^exit: 0$" <<<"$(tail -n1 .orchid/reviews/T003-verify.log)" || fail "sanity: fixture evidence should record exit 0"
"$ORCHID_BIN" task advance T003 reviewing >/dev/null || fail "INV-11: reviewing after a passing verify run must be permitted"
assert_eq reviewing "$("$ORCHID_BIN" task show T003 | grep '^status: ' | cut -d' ' -f2)" "INV-11: T003 advanced to reviewing"
green_case "with the condition satisfied, the same command PASSed, the evidence logged 'exit: 0', and the same gate let the advance to reviewing THROUGH -- so the refusals above are the gate reading a real outcome rather than a verb that always refuses"

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
plant_reviewer_envelope T004
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
grep -qi "verify" <<<"$err" || fail "rework: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "rework: refused advance leaves status at testing"

rc=0; verify_at "$new_cand" T004 || rc=$?
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

plant_reviewer_envelope T004
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
grep -qi "verify" <<<"$err" || fail "merging->rework: die message must mention verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T004 | grep '^status: ' | cut -d' ' -f2)" "merging->rework: refused advance leaves status at testing"

rc=0; verify_at "$new_cand2" T004 || rc=$?
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
grep -q "^exit: 0$" <<<"$(tail -n1 .orchid/reviews/T005-verify.log)" || fail "sanity: T005 evidence records exit 0"
assert_match "^candidate: $head_sha$" "$(cat .orchid/reviews/T005-verify.log)" "sanity: T005 evidence bound to the pre-bump candidate"

new_cand5="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "out-of-band bump")"
[ -n "$new_cand5" ] || fail "sanity: could not mint a new candidate commit for T005"
"$ORCHID_BIN" task set T005 candidate_sha "$new_cand5"

[ -f .orchid/reviews/T005-verify.log ] || fail "sanity: stale evidence log still present (rm-based invalidation does not fire on a bare task set)"
rc=0; err="$("$ORCHID_BIN" task advance T005 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "sha-binding: reviewing must be refused when evidence's candidate != task's current candidate_sha, despite a passing exit code"
grep -qi "candidate\|verify" <<<"$err" || fail "sha-binding: die message must mention candidate/verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T005 | grep '^status: ' | cut -d' ' -f2)" "sha-binding: refused advance leaves status at testing"

rc=0; verify_at "$new_cand5" T005 || rc=$?
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
grep -qi "candidate\|verify" <<<"$err" || fail "vacuous-none: die message must mention candidate/verify (got: $err)"
assert_eq testing "$("$ORCHID_BIN" task show T006 | grep '^status: ' | cut -d' ' -f2)" "vacuous-none: refused advance leaves status at testing"

# ===========================================================================
# T031 (r-002, lesson L025): INV-11 defeated FROM THE INSIDE. Every gate
# above compares the evidence's own claim against the task's candidate_sha
# and never asks the one question that matters -- was the tree the suite
# actually executed the tree the evidence names?
#
# It was not, on T013. `runners/orchid-drive` captured candidate_sha by
# reading the task worktree's HEAD when it reconciled the implementer
# envelope (05:04:31Z, 4bb8d03); the implementer job was still alive and
# committed 680cfc0 at 05:23:10Z; the verification that finished at 05:50:15Z
# ran against 680cfc0 while writing `sha: 4bb8d03` into its header. Every
# gate above sees 4bb8d03 == 4bb8d03 and admits it. A PASS would have
# certified one commit on the strength of executing another; it failed only
# by luck, because the extra commit happened to make Formula/orchid.rb stale.
#
# So verification must FAIL CLOSED on a drifted tree rather than produce
# admissible evidence -- both when the tree is wrong before it starts, and
# when the tree moves underneath a suite that is already running.
# ===========================================================================
"$ORCHID_BIN" task create T007 "verify refuses a tree that is not the candidate"
"$ORCHID_BIN" task set T007 verification_commands "true"
"$ORCHID_BIN" task set T007 base_sha "$head_sha"
cand7="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "T007 candidate")"
[ -n "$cand7" ] || fail "sanity: could not mint T007's candidate commit"
"$ORCHID_BIN" task set T007 candidate_sha "$cand7"
"$ORCHID_BIN" task advance T007 implementing >/dev/null
"$ORCHID_BIN" task advance T007 testing >/dev/null

# The checkout is still at head_sha -- exactly T013's shape, where the tree on
# disk was NOT the recorded candidate. Nothing may run.
drift_head="$(git -C "$WORK" rev-parse HEAD)"
[ "$drift_head" != "$cand7" ] || fail "sanity: T007's checkout must not already be at the candidate"
rc=0; drift_err="$("$ORCHID_BIN" verify T007 2>&1 1>/dev/null)" || rc=$?
assert_eq 20 "$rc" "T031: verify against a drifted worktree exits 20 (refused), never 0 or 1"
# Here-strings, not `echo | grep -q`: this file runs under `pipefail`, and
# `grep -q` exits at its first match, so a long-enough left-hand side takes
# SIGPIPE and the pipeline reports 141 for a pattern that DID match. An
# assertion that inverts on success is worse than no assertion.
grep -q "$drift_head" <<<"$drift_err" || fail "T031: the refusal must name the worktree's actual HEAD (got: $drift_err)"
grep -q "$cand7" <<<"$drift_err" || fail "T031: the refusal must name the recorded candidate_sha (got: $drift_err)"

drift_log=".orchid/reviews/T007-verify.log"
[ -f "$drift_log" ] || fail "T031: the refusal is itself evidence and must be recorded"
assert_match "^sha: $drift_head$" "$(cat "$drift_log")" "T031: refusal evidence names the tree that was actually there"
assert_match "^candidate: $cand7$" "$(cat "$drift_log")" "T031: refusal evidence names the candidate it was asked for"
# `head_after:` is what makes an evidence header describe a TREE rather than a
# moment, so it belongs in every header this verb writes -- including this one.
# A run that was refused before it began left HEAD exactly where it found it,
# and saying so explicitly is the difference between "nothing ran" and "the
# header is silent about the other end". A reader that has to branch on
# whether the field is present cannot compare the two ends at all.
assert_match "^head_after: $drift_head$" "$(cat "$drift_log")" \
  "T031: refusal evidence carries head_after: too — a refused run left HEAD where it found it, and the header says so"
assert_match "^refused: " "$(tail -n1 "$drift_log")" "T031: the refusal is the log's LAST line, so the INV-11 gate's tail check can never read 'exit: 0'"

rc=0; err="$("$ORCHID_BIN" task advance T007 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: a refused verify must never produce admissible evidence — reviewing must be refused"
assert_eq testing "$("$ORCHID_BIN" task show T007 | grep '^status: ' | cut -d' ' -f2)" "T031: refused advance leaves T007 at testing"
red_case "a verification aimed at a worktree that is not the recorded candidate exits 20, names both shas, and produces evidence the INV-11 gate cannot admit"

# ...and the same task passes the moment the tree really is the candidate.
rc=0; verify_at "$cand7" T007 || rc=$?
assert_eq 0 "$rc" "T031: verify PASSes once the worktree really is the recorded candidate"
"$ORCHID_BIN" task advance T007 reviewing >/dev/null || fail "T031: reviewing permitted after an honest verify of the candidate"
assert_eq reviewing "$("$ORCHID_BIN" task show T007 | grep '^status: ' | cut -d' ' -f2)" "T031: T007 advanced to reviewing"
green_case "the identical task, verified with its recorded candidate actually checked out, PASSes and advances -- so the refusal above is a drift check reading a real disagreement, not a verb that always refuses"

# ---------------------------------------------------------------------------
# The other half of the same race: the tree was right when the suite STARTED
# and moved while it ran (T013's implementer committed 19 minutes into a
# verification that had already begun). A single `sha:` header cannot honestly
# describe that run, so it must not be admissible either -- whatever the
# suite's own exit code said.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T008 "the tree moved while the suite ran"
"$ORCHID_BIN" task set T008 base_sha "$head_sha"
cand8="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "T008 candidate")"
[ -n "$cand8" ] || fail "sanity: could not mint T008's candidate commit"
"$ORCHID_BIN" task set T008 candidate_sha "$cand8"
# A suite that PASSES (exit 0) and commits while it runs -- a live implementer
# landing one more commit into the worktree it still owns, in one line.
"$ORCHID_BIN" task set T008 verification_commands "git commit -q --allow-empty -m 'landed while the suite ran'"
"$ORCHID_BIN" task advance T008 implementing >/dev/null
"$ORCHID_BIN" task advance T008 testing >/dev/null

t008_restore="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" reset -q --hard "$cand8"
rc=0; moved_err="$("$ORCHID_BIN" verify T008 2>&1 1>/dev/null)" || rc=$?
moved_head="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" reset -q --hard "$t008_restore"

assert_eq 20 "$rc" "T031: a suite whose tree moved underneath it is refused (20), never reported as a PASS"
# Exit 20 alone tells an operator that something was refused, not WHAT drifted.
# The diagnostic has to name both ends of the move -- the tree the suite was
# asked to certify and the tree it finished on -- or the refusal is unactionable.
assert_match "$cand8" "$moved_err" "T031: the drift diagnostic names the recorded candidate the suite started against"
assert_match "$moved_head" "$moved_err" "T031: the drift diagnostic names the HEAD the worktree moved to"
[ "$moved_head" != "$cand8" ] || fail "sanity: the T008 suite really did move the worktree's HEAD"
moved_log=".orchid/reviews/T008-verify.log"
[ -f "$moved_log" ] || fail "T031: the moved-tree run must still leave evidence"
assert_match "^sha: $cand8$" "$(cat "$moved_log")" "T031: evidence records the tree the suite started against"
assert_match "^head_after: $moved_head$" "$(cat "$moved_log")" "T031: evidence records the tree it ended against — the run describes no single tree"
assert_match "^exit: 0$" "$(cat "$moved_log")" "sanity: the suite itself exited 0, so nothing but the drift check stands between this and admission"
assert_match "^refused: " "$(tail -n1 "$moved_log")" "T031: the drift refusal is the last line, so the INV-11 gate refuses despite the passing exit"

rc=0; err="$("$ORCHID_BIN" task advance T008 reviewing 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "T031: a PASSING suite that ran against a moving tree must not satisfy the testing -> reviewing gate"
assert_eq testing "$("$ORCHID_BIN" task show T008 | grep '^status: ' | cut -d' ' -f2)" "T031: refused advance leaves T008 at testing"
red_case "a suite that PASSed while the worktree moved under it is refused too, and its own exit 0 is not enough to get it past the testing to reviewing gate"

# ---------------------------------------------------------------------------
# T031 attempt-6 rework -- WHERE THE BINDING IS TAKEN.
#
# The two Parts above are about DISAGREEMENT: `sha:` against the recorded
# candidate before the run, and against `head_after:` after it. Both of them
# read `sha` from one place, and that place is what this Part is about.
#
# An earlier shape of this verb read HEAD near the top of the file and quoted
# the result at the bottom, with the frontmatter parse, a repository-wide
# prestate walk and a temp-file mint in between. Every one of those takes real
# time in a worktree an implementer may still own, so what the header called
# the tree that ran was in fact the tree as it stood some seconds BEFORE the
# gate asked its question -- and `sha:` is not a diagnostic here, it is the
# claim an INV-11 reader compares and the left-hand end of the `head_after:`
# comparison. A claim about a different instant than the one it names is the
# exact substitution this whole task exists to close, arrived at from inside
# the fix for it.
#
# So the read is REBOUND immediately before the exec, with nothing between it
# and the command but the comparison it exists for. That is an ordering
# property of the source: no fixture can stage a commit landing inside a
# window measured in milliseconds, and a test that tried would be a coin flip
# rather than a guard. It is asserted as a shape, in the same spirit as
# tests/test_drive.sh's verify-refusal-arm tripwire, because the alternative is
# no guard at all on a regression that consists entirely of moving one line.
# ---------------------------------------------------------------------------
vsrc="$REPO_ROOT/libexec/orchid-verify"
[ -f "$vsrc" ] || fail "T031: cannot read $vsrc -- this tripwire has lost its subject and must be revisited"

# -F, and substrings chosen to be unique: `sha_after="$(git ...` does not
# contain `sha="$(git`, and the only other mention of `bash -c` in this file is
# prose that carries no `"$cmd"`.
bind_hits="$(grep -cF 'sha="$(git -C "$cwd" rev-parse HEAD' "$vsrc" || true)"
exec_hits="$(grep -cF 'bash -c "$cmd"' "$vsrc" || true)"
assert_eq 1 "$bind_hits" "T031: libexec/orchid-verify must bind the evidence sha in exactly one place (found $bind_hits)"
assert_eq 1 "$exec_hits" "T031: libexec/orchid-verify must run the verification command in exactly one place (found $exec_hits)"

bind_ln="$(grep -nF 'sha="$(git -C "$cwd" rev-parse HEAD' "$vsrc" | cut -d: -f1)"
exec_ln="$(grep -nF 'bash -c "$cmd"' "$vsrc" | cut -d: -f1)"
[ "$bind_ln" -lt "$exec_ln" ] \
  || fail "T031: the sha binding (line $bind_ln) must be read BEFORE the verification command runs (line $exec_ln)"

# Everything executable between the two, comments and blank lines removed. One
# awk program rather than a pipeline of greps: a `grep -v` that filters away
# every line exits 1, and under this file's `pipefail` that would turn "the gap
# is empty" into a failed substitution instead of an assertion.
bind_gap="$(awk -v a="$bind_ln" -v b="$exec_ln" '
  NR <= a || NR >= b { next }
  { line = $0; sub(/^[ \t]+/, "", line) }
  line ~ /^#/ { next }
  line == "" { next }
  { print line }
' "$vsrc")"
bind_gap_n=0
[ -z "$bind_gap" ] || bind_gap_n="$(printf '%s\n' "$bind_gap" | wc -l | tr -d ' ')"
assert_eq 3 "$bind_gap_n" \
  "T031: nothing but the drift comparison may stand between the sha binding and the command it describes (found $bind_gap_n statement(s): $bind_gap)"
bind_l1="$(printf '%s\n' "$bind_gap" | awk 'NR==1')"
bind_l2="$(printf '%s\n' "$bind_gap" | awk 'NR==2')"
bind_l3="$(printf '%s\n' "$bind_gap" | awk 'NR==3')"
# `case`, not `assert_match`: these are literal shell fragments full of `$`,
# `[` and `!`, and pinning them as extended regular expressions would be three
# layers of escaping over an assertion whose whole point is to be readable.
# The patterns are single-quoted, which is what makes the `[ ... ]` in them a
# literal bracket pair rather than a glob character class -- a quoted character
# in a case pattern matches itself. Only the trailing `*` below is left outside
# the quotes, because that one IS meant as a glob.
case "$bind_l1" in
  'if [ "$cand" != none ] && [ "$sha" != "$cand" ]; then') ;;
  *) fail "T031: the statement after the sha binding must be the drift comparison (got: $bind_l1)" ;;
esac
case "$bind_l2" in
  'verify_refuse '*) ;;
  *) fail "T031: the drift comparison must refuse, and refuse nothing else (got: $bind_l2)" ;;
esac
assert_eq "fi" "$bind_l3" "T031: the drift comparison must close immediately before the exec (got: $bind_l3)"
red_case "the evidence sha is bound immediately before the verification command, with nothing between the read and the run but the drift comparison itself"

# ...and the binding it takes really is the tree the command executes in. The
# suite is one line that reports the HEAD it sees; the header must name that
# same commit at BOTH ends. This is what stops the tripwire above from being a
# statement about line numbers: it proves the field those lines position is the
# field the gate reads, and that it describes the tree the command stood in.
"$ORCHID_BIN" task create T009 "the recorded sha is the one the command saw"
"$ORCHID_BIN" task set T009 base_sha "$head_sha"
cand9="$(git -C "$WORK" commit-tree "$head_sha^{tree}" -p "$head_sha" -m "T009 candidate")"
[ -n "$cand9" ] || fail "sanity: could not mint T009's candidate commit"
"$ORCHID_BIN" task set T009 candidate_sha "$cand9"
"$ORCHID_BIN" task set T009 verification_commands "git rev-parse HEAD > $WORK/t009-seen-head"
"$ORCHID_BIN" task advance T009 implementing >/dev/null
"$ORCHID_BIN" task advance T009 testing >/dev/null

rc=0; verify_at "$cand9" T009 || rc=$?
assert_eq 0 "$rc" "T031: the reporting suite PASSes with its candidate checked out"
[ -f "$WORK/t009-seen-head" ] || fail "T031: the verification command did not run, so it reported no HEAD"
seen_head="$(tr -d '[:space:]' < "$WORK/t009-seen-head")"
assert_eq "$cand9" "$seen_head" "sanity: the command ran in the checkout holding the recorded candidate"
bind_log=".orchid/reviews/T009-verify.log"
[ -f "$bind_log" ] || fail "T031: the passing run must leave evidence"
assert_match "^sha: $seen_head$" "$(cat "$bind_log")" \
  "T031: the sha the evidence records is the HEAD the command itself observed"
assert_match "^head_after: $seen_head$" "$(cat "$bind_log")" \
  "T031: and the far end of the bracket names it too, so the run describes one tree"
"$ORCHID_BIN" task advance T009 reviewing >/dev/null || fail "T031: a run bound to the tree it executed advances"
green_case "the recorded sha is the commit the verification command itself reported standing on, at both ends of the run -- so the ordering pinned above positions the field the gate actually reads"
