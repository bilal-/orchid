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
# GREEN: the same inputs under a budget large enough to hold them build a
#      pack normally; that direction is covered by tests/test_pack.sh, whose
#      passes are what make this refusal a budget decision rather than
#      pack_build being broken.
rc=0; pack_build "$WORK" T001 review "$WORK/p" 2>/dev/null || rc=$?
assert_eq "12" "$rc" "INV-12: non-truncatable overflow exits 12, never silently truncates"
[ ! -d "$WORK/p" ] || fail "INV-12: dest removed on overflow"
red_case "an over-budget, non-truncatable pack exited 12 and left no partial destination behind"
