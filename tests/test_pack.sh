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
