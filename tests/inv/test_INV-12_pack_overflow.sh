#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/pack.sh"
cd_scratch "$WORK" || exit 1; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"
printf 'y%.0s' $(seq 1 9000) > f.txt; git add f.txt; git commit -q -m big
cand="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks
printf -- '---\nid: T001\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' "$base" "$cand" > .orchid/tasks/T001.md
printf 'pack_budget_bytes=100\n' > orchid.config
# RED: a 9000-byte diff against a 100-byte pack budget -- an input that
#      cannot fit and cannot legally be trimmed. `pack_build` must exit 12 and
#      leave NO destination behind. A pack that silently truncated would hand
#      a reviewer a partial diff while every downstream check went on reading
#      like a full review.
# GREEN: THE SAME inputs, in this file, under a budget large enough to hold
#      them must build a pack normally and leave the destination in place.
#      That direction used to be delegated to tests/test_pack.sh -- which meant
#      this gate's own acceptance side was never exercised HERE, so a
#      `pack_build` that had simply stopped working would produce exit 12 for
#      the wrong reason and this file would still read as a pass. The twin runs
#      below, on the same repo, the same task and the same operation, with only
#      the budget changed.
rc=0; pack_build "$WORK" T001 review "$WORK/p" 2>/dev/null || rc=$?
assert_eq "12" "$rc" "INV-12: non-truncatable overflow exits 12, never silently truncates"
[ ! -d "$WORK/p" ] || fail "INV-12: dest removed on overflow"
red_case "an over-budget, non-truncatable pack exited 12 and left no partial destination behind"

# The GREEN twin: only the budget changes. If this fails, the refusal above was
# not a budget decision at all.
printf 'pack_budget_bytes=1000000\n' > orchid.config
rc=0; pack_build "$WORK" T001 review "$WORK/p-green" || rc=$?
assert_eq "0" "$rc" "INV-12: the same inputs under a budget large enough to hold them must build normally -- otherwise the exit 12 above says only that pack_build is broken"
[ -d "$WORK/p-green" ] || fail "INV-12: an accepted build must leave its destination in place"
green_case "the same repo, task and operation under a budget large enough to hold the diff built a pack and kept its destination, so the exit 12 above is a budget refusal"
