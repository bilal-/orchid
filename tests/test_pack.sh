#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/pack.sh"
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
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
tight=$(( $(wc -c < .orchid/tasks/T001.md) + $(cd "$WORK" && git diff "$base".."$cand" | wc -c) + 200 ))
printf 'pack_budget_bytes=%s\n' "$tight" > orchid.config
pack_build "$WORK" T001 review "$WORK/p2" || fail "pack build with trim"
assert_eq "true" "$(jq -r '.items[] | select(.name=="context.md") | .truncated' "$WORK/p2/pack.json")" "context trimmed"
[ "$(wc -c < "$WORK/p2/context.md")" -lt 5000 ] || fail "context actually smaller"

# manifest honesty: total_bytes must equal the sum of all packed items' bytes
assert_eq "true" "$(jq -r '.total_bytes == ([.items[].bytes] | add)' "$WORK/p1/pack.json")" "total_bytes sums all items (context present)"

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
