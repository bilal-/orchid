#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/pack.sh"
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"
printf 'y%.0s' $(seq 1 9000) > f.txt; git add f.txt; git commit -q -m big
cand="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks
printf -- '---\nid: T001\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' "$base" "$cand" > .orchid/tasks/T001.md
printf 'pack_budget_bytes=100\n' > orchid.config
rc=0; pack_build "$WORK" T001 review "$WORK/p" 2>/dev/null || rc=$?
assert_eq "12" "$rc" "INV-12: non-truncatable overflow exits 12, never silently truncates"
[ ! -d "$WORK/p" ] || fail "INV-12: dest removed on overflow"
