#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\n' > orchid.config
# init now refuses a dirty tree (Task 8 safety fix): commit the fixture's
# config before init, mirroring tests/test_init_doctor.sh.
git add -A && git commit -q -m "fixture: config"
"$ORCHID_BIN" init >/dev/null
# init leaves the operator back on the pre-init branch (cleanup restores
# $cur); the run state (.orchid/roadmap.md etc.) only lives on the
# integration branch it just committed to, so check that out before
# touching task/status state — mirrors the real operator workflow
# (docs/specs/operations.md: "Integration branch holds the product").
git checkout -q orchid/integration
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo
"$ORCHID_BIN" task create T002 dep
"$ORCHID_BIN" task set T002 depends_on T001
assert_match "run_status: planning" "$("$ORCHID_BIN" status)" "run status shown"
assert_match "T001	pending" "$("$ORCHID_BIN" status)" "task table"
assert_match "T002.*waiting-deps T001" "$("$ORCHID_BIN" status --explain)" "explain names predicate"
assert_match "T001.*ready-to-dispatch" "$("$ORCHID_BIN" status --explain)" "explain ready"
