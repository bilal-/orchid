#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/pack.sh"
cd_scratch "$WORK" || exit 1; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"; echo change > f.txt; git add f.txt; git commit -q -m c
cand="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks
printf -- '---\nid: T001\nstatus: reviewing\nbase_sha: %s\ncandidate_sha: %s\n---\nSpec body.\n' "$base" "$cand" > .orchid/tasks/T001.md
echo "repo context here" > .orchid/context.md
export ORCHID_REPO="$WORK"

pack_build "$WORK" T001 review "$WORK/p1" || fail "pack build"
[ -f "$WORK/p1/task.md" ] && [ -f "$WORK/p1/diff.patch" ] && [ -f "$WORK/p1/pack.json" ] || fail "pack contents"
grep -q "change" "$WORK/p1/diff.patch" || fail "diff captured"
assert_eq "false" "$(jq -r '.items[] | select(.name=="task.md") | .truncated' "$WORK/p1/pack.json")" "task never truncated"

# context trimming under tight budget (non-truncatables still fit)
big_ctx="$(printf 'x%.0s' $(seq 1 5000))"; echo "$big_ctx" > .orchid/context.md
tight=$(( $(wc -c < .orchid/tasks/T001.md) + $(cd_scratch "$WORK" && git diff "$base".."$cand" | wc -c) + 200 ))
printf 'pack_budget_bytes=%s\n' "$tight" > orchid.config
pack_build "$WORK" T001 review "$WORK/p2" || fail "pack build with trim"
assert_eq "true" "$(jq -r '.items[] | select(.name=="context.md") | .truncated' "$WORK/p2/pack.json")" "context trimmed"
[ "$(wc -c < "$WORK/p2/context.md")" -lt 5000 ] || fail "context actually smaller"

# manifest honesty: total_bytes must equal the sum of all packed items' bytes
assert_eq "true" "$(jq -r '.total_bytes == ([.items[].bytes] | add)' "$WORK/p1/pack.json")" "total_bytes sums all items (context present)"

# ---------------------------------------------------------------------------
# v1-m3 Task 11: lessons.md injection into the per-task (implementer/
# reviewer) pack -- ACTIVE blocks only (kernel.md's per-role table), never
# superseded/retired ones, budgeted BEFORE context.md (docs/specs/
# plugins.md's trim order: journal/lessons/context -- packs never carry
# journal.md at all, so lessons vs. context is the only ordering that
# actually applies here).
# ---------------------------------------------------------------------------
rm -f orchid.config
echo "repo context here" > .orchid/context.md
cat > .orchid/lessons.md <<'EOF'
# Lessons

## L001 [active] repo
statement: an active lesson the implementer should see
evidence:
first: 2026-07-01T00:00:00Z
last_confirmed: 2026-07-01T00:00:00Z
invalidate_when: never

## L002 [retired] repo
statement: a retired lesson the implementer must NOT see
evidence:
first: 2026-07-01T00:00:00Z
last_confirmed: 2026-07-01T00:00:00Z
invalidate_when: n/a

## L003 [superseded] repo
statement: a superseded lesson the implementer must NOT see either
evidence:
first: 2026-07-01T00:00:00Z
last_confirmed: 2026-07-01T00:00:00Z
invalidate_when: n/a
EOF

pack_build "$WORK" T001 implement "$WORK/pimpl" || fail "implementer pack build (lessons)"
[ -f "$WORK/pimpl/lessons.md" ] || fail "implementer pack has lessons.md"
grep -q "an active lesson" "$WORK/pimpl/lessons.md" || fail "implementer pack lessons.md includes the active lesson"
grep -q "a retired lesson" "$WORK/pimpl/lessons.md" && fail "implementer pack lessons.md must NOT include the retired lesson"
grep -q "a superseded lesson" "$WORK/pimpl/lessons.md" && fail "implementer pack lessons.md must NOT include the superseded lesson"
assert_eq "false" "$(jq -r '.items[] | select(.name=="lessons.md") | .truncated' "$WORK/pimpl/pack.json")" "implementer pack lessons.md not truncated under a generous budget"

pack_build "$WORK" T001 review "$WORK/prevl" || fail "reviewer pack build (lessons)"
[ -f "$WORK/prevl/lessons.md" ] || fail "reviewer pack has lessons.md"
grep -q "an active lesson" "$WORK/prevl/lessons.md" || fail "reviewer pack lessons.md includes the active lesson"
grep -q "a retired lesson" "$WORK/prevl/lessons.md" && fail "reviewer pack lessons.md must NOT include the retired lesson"

# no lessons.md on disk at all -> cleanly omitted, never an error
rm -f .orchid/lessons.md
pack_build "$WORK" T001 implement "$WORK/pimpl_noless" || fail "implementer pack build (no lessons.md)"
[ ! -f "$WORK/pimpl_noless/lessons.md" ] || fail "no lessons.md on disk -> pack has none either"
assert_match '"lessons.md"' "$(jq -c '.omitted' "$WORK/pimpl_noless/pack.json")" "lessons.md listed omitted when absent"

# ...and an omission is never ERASED by a later one. context.md's absent-arm
# assigned `omitted` outright instead of appending to it, so a pack missing
# BOTH reported only context.md -- lessons.md vanished from the manifest
# entirely, and any later truncatable added ahead of it would too. An input the
# engine never received, recorded nowhere, is the one thing pack.json exists to
# make impossible. (T025's rework.md is not in this list by design: it is never
# a budget omission -- it is shipped, refused outright, or withheld as an
# items[] entry carrying the reason it did not travel.)
rm -f .orchid/context.md
pack_build "$WORK" T001 implement "$WORK/pimpl_neither" || fail "implementer pack build (no lessons.md, no context.md)"
omitted_both="$(jq -c '.omitted' "$WORK/pimpl_neither/pack.json")"
assert_match '"context.md"' "$omitted_both" "context.md listed omitted when absent"
assert_match '"lessons.md"' "$omitted_both" \
  "lessons.md's omission survives context.md's -- a later omission appends, it never overwrites the list (omitted: $omitted_both)"
echo "repo context here" > .orchid/context.md

# trim priority: a budget with room for EITHER lessons.md OR context.md, but
# not both, must keep lessons.md and drop context.md entirely (lessons is
# budgeted first).
cat > .orchid/lessons.md <<'EOF'
# Lessons

## L001 [active] repo
statement: an active lesson the implementer should see
evidence:
first: 2026-07-01T00:00:00Z
last_confirmed: 2026-07-01T00:00:00Z
invalidate_when: never
EOF
# Sized against what pack_build actually consumes for lessons.md -- the
# ACTIVE-filtered content (lessons_active_only strips the leading "# Lessons"
# heading, which is not itself a "## " block), not the raw file's byte count.
# Exactly zero bytes of room left for context.md once task/diff/lessons are
# all in: context.md (pre-existing code, unchanged here) always still
# produces a (possibly empty) file rather than omitting it outright the way
# lessons.md/tasks.md/symbols.txt do, so the honest assertion is "reduced to
# nothing", not "absent" -- the point being proven is priority: lessons.md
# keeps its full content while context.md is squeezed to zero.
big_ctx="$(printf 'x%.0s' $(seq 1 500))"; echo "$big_ctx" > .orchid/context.md
lessons_active_bytes="$(lessons_active_only .orchid/lessons.md | wc -c)"
tight_lessons=$(( $(wc -c < .orchid/tasks/T001.md) + $(cd_scratch "$WORK" && git diff "$base".."$cand" | wc -c) + lessons_active_bytes ))
printf 'pack_budget_bytes=%s\n' "$tight_lessons" > orchid.config
pack_build "$WORK" T001 review "$WORK/ptight_lessons" || fail "reviewer pack build (tight budget, lessons priority)"
[ -f "$WORK/ptight_lessons/lessons.md" ] || fail "lessons.md present under a budget sized for it"
grep -q "an active lesson" "$WORK/ptight_lessons/lessons.md" || fail "lessons.md content intact under tight budget"
assert_eq "false" "$(jq -r '.items[] | select(.name=="lessons.md") | .truncated' "$WORK/ptight_lessons/pack.json")" "lessons.md not truncated -- it got its full share before context.md"
assert_eq "0" "$(wc -c < "$WORK/ptight_lessons/context.md" | tr -d ' ')" "context.md squeezed to nothing once lessons.md already spent the budget"
rm -f orchid.config .orchid/lessons.md
echo "repo context here" > .orchid/context.md

# ---------------------------------------------------------------------------
# v1-m3: plan-scoped pack -- the reserved task id `plan` (role.plan_critic
# critiquing a draft roadmap) builds requirements.md + roadmap.md
# (non-truncatable) + every tasks/*.md concatenated into tasks.md
# (truncatable, tail-first trim) + lessons.md when present -- NOT the usual
# per-task task.md/diff.patch.
# ---------------------------------------------------------------------------
rm -f orchid.config
echo "# Requirements" > .orchid/requirements.md
printf -- '---\nrun_status: planning\n---\n# Roadmap\nDraft body.\n' > .orchid/roadmap.md
printf -- '---\nid: T002\nstatus: pending\n---\nSecond task body.\n' > .orchid/tasks/T002.md

pack_build "$WORK" plan critique "$WORK/pplan" || fail "plan pack build"
[ -f "$WORK/pplan/requirements.md" ] || fail "plan pack has requirements.md"
[ -f "$WORK/pplan/roadmap.md" ] || fail "plan pack has roadmap.md"
[ -f "$WORK/pplan/tasks.md" ] || fail "plan pack has tasks.md"
[ ! -f "$WORK/pplan/task.md" ] || fail "plan pack must not have task.md"
[ ! -f "$WORK/pplan/diff.patch" ] || fail "plan pack must not have diff.patch"
grep -q "T001" "$WORK/pplan/tasks.md" || fail "plan pack tasks.md includes T001"
grep -q "T002" "$WORK/pplan/tasks.md" || fail "plan pack tasks.md includes T002"
assert_eq "false" "$(jq -r '.items[] | select(.name=="requirements.md") | .truncated' "$WORK/pplan/pack.json")" "plan pack requirements.md never truncated"
assert_eq "false" "$(jq -r '.items[] | select(.name=="roadmap.md") | .truncated' "$WORK/pplan/pack.json")" "plan pack roadmap.md never truncated"
assert_eq "true" "$(jq -r '.total_bytes == ([.items[].bytes] | add)' "$WORK/pplan/pack.json")" "plan pack total_bytes sums all items"

# tasks.md truncation under a tight budget (non-truncatables still fit)
tight_plan=$(( $(wc -c < .orchid/requirements.md) + $(wc -c < .orchid/roadmap.md) + 50 ))
printf 'pack_budget_bytes=%s\n' "$tight_plan" > orchid.config
pack_build "$WORK" plan critique "$WORK/pplan2" || fail "plan pack build with trim"
assert_eq "true" "$(jq -r '.items[] | select(.name=="tasks.md") | .truncated' "$WORK/pplan2/pack.json")" "plan pack tasks.md trimmed under a tight budget"
[ -f "$WORK/pplan2/tasks.md" ] || fail "plan pack tasks.md still present (partially) under trim"
rm -f orchid.config

# `plan` with no requirements.md at all (neither `orchid init` nor
# `requirements import` has run yet) is a clean, named failure, not a crash.
rm -f .orchid/requirements.md
plan_err_f="$(mktemp)"
rc=0; pack_build "$WORK" plan critique "$WORK/pplan3" 2>"$plan_err_f" || rc=$?
[ "$rc" -ne 0 ] || fail "plan pack build must fail without requirements.md"
grep -qi "requirements" "$plan_err_f" || fail "plan pack failure names requirements.md"
rm -f "$plan_err_f"
echo "# Requirements" > .orchid/requirements.md

# ---------------------------------------------------------------------------
# v1-m4: worktree-read review packs (promotes the r-001 live-run prototype
# into the kernel). A review/critique pack_build call now takes an optional
# 5th arg carrying the RESOLVED engine's capability fact (the launcher's
# job, not pack.sh's -- pack.sh stays resolver-dumb): "workspace_read=1"
# when that engine declares workspace_read, empty/absent otherwise (every
# existing call site above omits it, proving the default is unchanged).
# When the diff exceeds `pack_diff_inline_max_bytes` (config, default
# 262144) AND the engine is worktree-capable, the pack swaps diff.patch for
# diff.stat (git diff --stat + --name-status: enough for a worktree-capable
# reviewer to navigate the checkout, cheap enough to never blow the budget)
# and records the omission honestly in pack.json. An inline-only engine (no
# workspace_read fact) keeps today's full-diff behavior UNCHANGED, including
# the existing overflow path for a diff that large -- and a small diff stays
# a full diff.patch even for a worktree-capable engine (the threshold, not
# the capability alone, decides).
# ---------------------------------------------------------------------------
rm -f orchid.config
echo "repo context here" > .orchid/context.md

# A diff comfortably over the DEFAULT pack_diff_inline_max_bytes (262144)
# and over the DEFAULT pack_budget_bytes (65536) too, so the inline-only
# path below still demonstrably overflows (unchanged behavior) while the
# worktree-read path (small diff.stat + symbols.txt) comfortably fits.
big_content="$(printf 'z%.0s' $(seq 1 300000))"
printf '%s\n' "$big_content" > f.txt
git add f.txt; git commit -q -m "big change"
big_cand="$(git rev-parse HEAD)"
printf -- '---\nid: T003\nstatus: reviewing\nbase_sha: %s\ncandidate_sha: %s\n---\nSpec body.\n' "$cand" "$big_cand" > .orchid/tasks/T003.md

pack_build "$WORK" T003 review "$WORK/pwt" "workspace_read=1" || fail "worktree-read pack build (big diff) must not overflow"
[ -f "$WORK/pwt/diff.stat" ] || fail "worktree-read pack contains diff.stat"
[ ! -f "$WORK/pwt/diff.patch" ] || fail "worktree-read pack must NOT contain diff.patch for an over-threshold diff"
[ -f "$WORK/pwt/symbols.txt" ] || fail "worktree-read pack still contains symbols.txt (blind-spot guard data)"
grep -q "f.txt" "$WORK/pwt/diff.stat" || fail "diff.stat names the changed file"
assert_eq "worktree-read" "$(jq -r '.items[] | select(.name=="diff.patch") | .omitted' "$WORK/pwt/pack.json")" \
  "pack.json records diff.patch omitted for worktree-read"

# The same big diff with NO workspace_read fact (inline-only engine, the
# launcher's default for anything that doesn't declare the capability) is
# UNCHANGED: a full diff.patch this large still blows the default budget --
# input_overflow (INV-12), exactly as before this feature existed.
rc=0; pack_build "$WORK" T003 review "$WORK/pinline" 2>/dev/null || rc=$?
assert_eq "12" "$rc" "inline-only engine: the same big diff still overflows (input_overflow), unchanged"
[ ! -d "$WORK/pinline" ] || fail "overflow path still removes dest"

# A SMALL diff (T001: base -> "change") with a worktree-read engine still
# gets the full diff.patch -- the threshold, not the capability alone,
# decides.
pack_build "$WORK" T001 review "$WORK/pwt_small" "workspace_read=1" || fail "worktree-read pack build (small diff)"
[ -f "$WORK/pwt_small/diff.patch" ] || fail "worktree-read pack keeps diff.patch for a small diff (threshold respected)"
[ ! -f "$WORK/pwt_small/diff.stat" ] || fail "worktree-read pack must not add diff.stat for a small diff"
grep -q "change" "$WORK/pwt_small/diff.patch" || fail "small diff content intact"

# pack_diff_inline_max_bytes is a REAL config key, not a hardcoded constant
# -- lowering it makes even T001's small diff cross the threshold.
printf 'pack_diff_inline_max_bytes=10\n' > orchid.config
pack_build "$WORK" T001 review "$WORK/pwt_cfg" "workspace_read=1" || fail "worktree-read pack build (custom low threshold)"
[ -f "$WORK/pwt_cfg/diff.stat" ] || fail "custom pack_diff_inline_max_bytes triggers diff.stat"
[ ! -f "$WORK/pwt_cfg/diff.patch" ] || fail "custom pack_diff_inline_max_bytes omits diff.patch"
rm -f orchid.config

# ---------------------------------------------------------------------------
# T025: rework.md -- the previous attempt's failure, fed back into the attempt
# that has to fix it. `implement` only, budgeted ahead of lessons.md and
# context.md, and built from the round-scoped logs `orchid task advance <id>
# rework` captures before it invalidates the verify evidence (lib/rework.sh).
#
# A pack that never carried this is the OTHER half of dogfood finding F27: the
# capture alone makes the failure survivable, but an attempt still handed the
# same brief as the last one still produces the same answer.
# ---------------------------------------------------------------------------
mk_rework_log() {  # mk_rework_log <file> <date> <body> [candidate-it-claims]
  # The `candidate:` header is not decoration: every captured round claims the
  # candidate it was produced against, and the brief is only allowed to speak
  # for a round whose claim matches the task's CURRENT candidate. Defaults to
  # this fixture's candidate; the staleness cases below pass another.
  local claim="${4:-$cand}"
  { printf 'date: %s\n' "$2"
    printf 'sha: %s\n' "$cand"
    printf 'candidate: %s\n' "$claim"
    printf 'cwd: %s\n' "$WORK"
    printf 'command: run-the-suite\n'
    printf -- '---\n'
    printf '%s\n' "$3"
    printf 'exit: 1\n'
  } > "$1"
}
mkdir -p .orchid/reviews

# No captured round at all (a first attempt): no rework.md, and no error.
pack_build "$WORK" T001 implement "$WORK/prw_none" || fail "implement pack build (no captured rework)"
[ ! -f "$WORK/prw_none/rework.md" ] || fail "a first attempt has no previous failure to feed back"

# One captured round: the brief carries the output verbatim.
mk_rework_log .orchid/reviews/T001-r1-rework.log 2026-08-01T00:00:00Z "FAIL OrderTest: assertSame order differs"
printf -- '---\nid: T001\nstatus: rework\nbase_sha: %s\ncandidate_sha: %s\nrework_rounds: 1\nrework_signature: aaaa1111\nrework_signature_repeats: 1\n---\nSpec body.\n' \
  "$base" "$cand" > .orchid/tasks/T001.md

pack_build "$WORK" T001 implement "$WORK/prw_one" || fail "implement pack build (one captured rework)"
[ -f "$WORK/prw_one/rework.md" ] || fail "a rework attempt's implement pack carries rework.md"
grep -q "assertSame order differs" "$WORK/prw_one/rework.md" || fail "rework.md carries the failing output VERBATIM"
grep -q "aaaa1111" "$WORK/prw_one/rework.md" || fail "rework.md names the failure signature"
grep -q "first time this particular failure" "$WORK/prw_one/rework.md" || fail "a single round is reported as a first sighting"
assert_eq "false" "$(jq -r '.items[] | select(.name=="rework.md") | .truncated' "$WORK/prw_one/pack.json")" \
  "rework.md is not truncated under a generous budget"
assert_eq "true" "$(jq -r '.total_bytes == ([.items[].bytes] | add)' "$WORK/prw_one/pack.json")" \
  "total_bytes still sums every item with rework.md present"

# A REVIEW pack never carries it: a reviewer judges base_sha..candidate_sha as
# it stands, and the previous attempt's failure would prejudge a candidate
# that no longer carries it.
pack_build "$WORK" T001 review "$WORK/prw_rev" || fail "review pack build (captured rework present)"
[ ! -f "$WORK/prw_rev/rework.md" ] || fail "a review pack must never carry rework.md"

# Two rounds, DIFFERENT failures: the brief shows what changed between them.
mk_rework_log .orchid/reviews/T001-r2-rework.log 2026-08-02T00:00:00Z "FAIL OrderTest: expected 3 got 4"
printf -- '---\nid: T001\nstatus: rework\nbase_sha: %s\ncandidate_sha: %s\nrework_rounds: 2\nrework_signature: bbbb2222\nrework_signature_repeats: 1\n---\nSpec body.\n' \
  "$base" "$cand" > .orchid/tasks/T001.md
pack_build "$WORK" T001 implement "$WORK/prw_two" || fail "implement pack build (two captured rounds)"
grep -q "expected 3 got 4" "$WORK/prw_two/rework.md" || fail "the brief leads with the NEWEST round's output"
grep -q "What changed since the round before it" "$WORK/prw_two/rework.md" \
  || fail "two rounds with different failures get a diff of the two"

# Two rounds, IDENTICAL failure: the brief must say so rather than showing an
# empty diff that reads like progress.
printf -- '---\nid: T001\nstatus: rework\nbase_sha: %s\ncandidate_sha: %s\nrework_rounds: 2\nrework_signature: aaaa1111\nrework_signature_repeats: 2\n---\nSpec body.\n' \
  "$base" "$cand" > .orchid/tasks/T001.md
pack_build "$WORK" T001 implement "$WORK/prw_same" || fail "implement pack build (repeated signature)"
grep -q "repeated 2 times in a row" "$WORK/prw_same/rework.md" \
  || fail "a repeated signature is stated as such — 'you already tried this and got exactly this'"
grep -q "no diff to show" "$WORK/prw_same/rework.md" || fail "an identical round shows no diff"

# Truncation keeps the TAIL: a suite's output ends with the failing
# assertions, so a head-first trim would keep the part that passed.
rm -f .orchid/reviews/T001-r2-rework.log
big_fail="$(printf 'PASSED filler %s\n' $(seq 1 400))"
mk_rework_log .orchid/reviews/T001-r1-rework.log 2026-08-03T00:00:00Z "$big_fail
FAIL OrderTest::theLineThatMatters"
printf -- '---\nid: T001\nstatus: rework\nbase_sha: %s\ncandidate_sha: %s\nrework_rounds: 1\nrework_signature: bbbb2222\nrework_signature_repeats: 1\n---\nSpec body.\n' \
  "$base" "$cand" > .orchid/tasks/T001.md
# +1200, not a hair over the preamble: the brief may only ship at all if the
# budget can carry the preamble WHOLE plus a meaningful tail of the failing run
# (lib/pack.sh's floor). A budget between those two is the refusal case below,
# which is a different assertion; this one is about which END of a long log the
# trim keeps.
tight_rw=$(( $(wc -c < .orchid/tasks/T001.md) + 1200 ))
printf 'pack_budget_bytes=%s\n' "$tight_rw" > orchid.config
pack_build "$WORK" T001 implement "$WORK/prw_trim" || fail "implement pack build (tight budget)"
assert_eq "true" "$(jq -r '.items[] | select(.name=="rework.md") | .truncated' "$WORK/prw_trim/pack.json")" \
  "rework.md reports itself truncated under a tight budget"
grep -q "theLineThatMatters" "$WORK/prw_trim/rework.md" \
  || fail "the trim keeps the TAIL — the failing assertions, not the filler that passed"
grep -q "PASSED filler 1$" "$WORK/prw_trim/rework.md" \
  && fail "the trim really dropped the head of a long log"
# ...and the trim is TAIL-KEPT over the captured LOG, never over the brief
# that frames it. The preamble -- the round number, the signature, and whether
# it has repeated unchanged -- is at the TOP, so a whole-file tail trim drops
# exactly the sentence this whole feature exists to deliver and hands the
# engine an unlabelled fragment of somebody's test output. That is not a
# degraded brief, it is the pre-T025 brief with extra noise: finding F27 again,
# reached by the budget instead of by the dangling pointer.
grep -q "^# Previous attempt (rework round 1)" "$WORK/prw_trim/rework.md" \
  || fail "the trim must keep the brief's PREAMBLE whole — it is the frame that makes the log underneath it mean anything"
grep -q "first time this particular failure" "$WORK/prw_trim/rework.md" \
  || fail "the convergence fact survives the trim: it is the one thing a re-reading implementer cannot derive for itself"
grep -q "^## The failing run, verbatim" "$WORK/prw_trim/rework.md" \
  || fail "the heading that labels the trimmed log survives with it"

# A budget with room for the preamble and not one byte more REFUSES THE PACK.
#
# It used to ship without rework.md and record the omission, and that is the
# quiet version of the very loop this feature ends: the attempt was dispatched
# precisely because a captured failure needs acting on, so an implementer sent
# without it -- or with a token fragment of it -- re-derives the same change
# and produces the same failure, while every counter reads healthy. Refusing is
# `input_overflow` (exit 12), the class the launcher already declines to spawn
# on, and it puts a fixable budget in front of an operator instead of another
# identical round in front of an engine.
tight_head=$(( $(wc -c < .orchid/tasks/T001.md) + 24 ))
printf 'pack_budget_bytes=%s\n' "$tight_head" > orchid.config
rc=0
rw_err="$(pack_build "$WORK" T001 implement "$WORK/prw_nohead" 2>&1)" || rc=$?
assert_eq "12" "$rc" \
  "a budget too small to carry the failure this rework was dispatched over fails the pack (input_overflow), it does not dispatch without it"
assert_match "input_overflow" "$rw_err" "the refusal names the class the launcher and INV-12 already know"
assert_match "rework.md" "$rw_err" \
  "and names the input it could not carry — an operator has to be able to tell this apart from a big diff"
[ ! -d "$WORK/prw_nohead" ] \
  || fail "a refused pack leaves no half-built pack directory behind for a launcher to hand to an engine"
# The other half of "does not dispatch" is already pinned where it belongs:
# tests/test_drive.sh's overflow Part drives a launcher whose pack_build exits
# 12 and asserts no engine ever started (the launcher dies before its spawn
# line, the driver charges the ladder and surfaces the diagnostic). Refusing
# HERE is what puts this case into that class; duplicating the end-to-end walk
# would test the launcher twice and this decision not at all.
rm -f orchid.config

# THE COMPARISON IS DROPPED BEFORE THE FAILING RUN IS CUT. rework.md is
# tail-kept, and the brief is "the failing run, then a diff against the round
# before it" -- so trimming the two together as one body keeps the DIFF and
# eats the RUN, handing the engine a description of a change to output it
# cannot see, under a heading promising that output verbatim. The failing run
# is the baseline the comparison is only meaningful against, so the run is kept
# whole first and the comparison goes, whole, when it does not fit.
# Deliberately different line by line, so the unified diff of the two is
# several times the size of the room left for it -- the assertion below is
# about which of the two is dropped, not about a knife-edge byte count.
rw_a="$(printf 'setup step %s ok\n' {1..40})"
rw_b="$(printf 'prepare stage %s completed\n' {1..40})"
mk_rework_log .orchid/reviews/T001-r1-rework.log 2026-08-04T00:00:00Z "$rw_a
FAIL OrderTest: the ROUND ONE failure"
mk_rework_log .orchid/reviews/T001-r2-rework.log 2026-08-05T00:00:00Z "$rw_b
FAIL OrderTest: the ROUND TWO failure"
printf -- '---\nid: T001\nstatus: rework\nbase_sha: %s\ncandidate_sha: %s\nrework_rounds: 2\nrework_signature: cccc3333\nrework_signature_repeats: 1\n---\nSpec body.\n' \
  "$base" "$cand" > .orchid/tasks/T001.md
# Room for the preamble and the whole newest log, and nothing like enough for
# a unified diff of two 40-line logs.
rw_room=$(( $(wc -c < .orchid/tasks/T001.md) + 600 + $(wc -c < .orchid/reviews/T001-r2-rework.log) ))
printf 'pack_budget_bytes=%s\n' "$rw_room" > orchid.config
pack_build "$WORK" T001 implement "$WORK/prw_nodiff" || fail "implement pack build (no room for the comparison)"
grep -q "the ROUND TWO failure" "$WORK/prw_nodiff/rework.md" \
  || fail "the FAILING RUN survives — it is what the attempt was dispatched to fix, and the comparison is worthless without it"
grep -q "^exit: 1$" "$WORK/prw_nodiff/rework.md" \
  || fail "and it survives WHOLE, exit line included, rather than as the tail the comparison left over"
grep -q "^# Previous attempt (rework round 2)" "$WORK/prw_nodiff/rework.md" \
  || fail "the preamble is still whole"
grep -q "What changed since the round before it" "$WORK/prw_nodiff/rework.md" \
  && fail "the comparison must be dropped ENTIRELY, not shipped in place of the run it compares"
assert_eq "true" "$(jq -r '.items[] | select(.name=="rework.md") | .truncated' "$WORK/prw_nodiff/pack.json")" \
  "a dropped comparison is a truncated input and says so — the engine did not receive all of it"
rm -f orchid.config .orchid/reviews/T001-r2-rework.log .orchid/reviews/T001-r1-rework.log

# EVIDENCE IS BOUND TO THE CANDIDATE THAT PRODUCED IT. The candidate moves
# under a captured round in ordinary operation -- the reworking implementer
# commits, `orchid merge`'s rebase arm mints a new sha, an operator re-derives
# the branch -- and the brief's sentences are claims about the code the
# recipient is holding: "you already tried this and got exactly this" against a
# superseded candidate is not a weaker brief, it is a confident false one.
mk_rework_log .orchid/reviews/T001-r1-rework.log 2026-08-06T00:00:00Z \
  "FAIL OrderTest: a failure of some OTHER candidate" "$base"
printf -- '---\nid: T001\nstatus: rework\nbase_sha: %s\ncandidate_sha: %s\nrework_rounds: 1\nrework_signature: dddd4444\nrework_signature_repeats: 1\n---\nSpec body.\n' \
  "$base" "$cand" > .orchid/tasks/T001.md
pack_build "$WORK" T001 implement "$WORK/prw_stale" \
  || fail "a superseded captured round must not fail the pack build — this is an ordinary state, not an error"
[ ! -f "$WORK/prw_stale/rework.md" ] \
  || fail "a round captured against a DIFFERENT candidate must not be fed forward as this candidate's previous failure"
assert_eq "superseded-candidate" \
  "$(jq -r '.items[] | select(.name=="rework.md") | .omitted' "$WORK/prw_stale/pack.json")" \
  "and the withholding is recorded WITH ITS REASON — evidence that exists and did not travel is exactly what pack.json must not hide"
assert_eq "true" "$(jq -r '.total_bytes == ([.items[].bytes] | add)' "$WORK/prw_stale/pack.json")" \
  "a reason-only item entry carries no bytes and leaves the total_bytes sum intact"

# A log written by an older kernel makes no claim at all, and an absence of a
# claim is not a claim: it is withheld too, under its own reason.
{ printf 'date: 2026-08-07T00:00:00Z\n'
  printf 'sha: %s\n' "$cand"
  printf 'cwd: %s\n' "$WORK"
  printf 'command: run-the-suite\n'
  printf -- '---\n'
  printf 'FAIL OrderTest: a failure nothing binds\n'
  printf 'exit: 1\n'; } > .orchid/reviews/T001-r1-rework.log
pack_build "$WORK" T001 implement "$WORK/prw_unbound" || fail "implement pack build (unbindable round)"
[ ! -f "$WORK/prw_unbound/rework.md" ] \
  || fail "a captured round with no candidate header binds to nothing and must not be fed forward"
assert_eq "unbindable" \
  "$(jq -r '.items[] | select(.name=="rework.md") | .omitted' "$WORK/prw_unbound/pack.json")" \
  "an unbindable round is recorded as such, distinctly from a superseded one — they need different operator answers"
rm -f .orchid/reviews/T001-r1-rework.log

# A captured round that is EMPTY -- a torn write, a copy interrupted midway --
# is not evidence. The brief's own framing is what makes that dangerous: "the
# verbatim output of the run that FAILED is reproduced below" over zero bytes
# asserts the failing run printed nothing, a claim ABOUT the failure rather
# than an absence of one. It must degrade to no brief at all (the pre-T025
# reading), and the pack must still build: rework.md is an optional input, and
# pack_build runs inside orchid-launch under `set -e`, where a non-zero here
# would take the whole dispatch down.
: > .orchid/reviews/T001-r1-rework.log
pack_build "$WORK" T001 implement "$WORK/prw_empty" \
  || fail "an unusable captured round must not fail the pack build -- rework.md is optional"
[ ! -f "$WORK/prw_empty/rework.md" ] \
  || fail "an EMPTY captured round must not produce a heading-only brief that claims the failing run printed nothing"
rm -f .orchid/reviews/T001-r1-rework.log
