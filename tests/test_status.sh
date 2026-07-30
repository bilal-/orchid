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
assert_match "T002.*waiting-deps \(T001\)" "$("$ORCHID_BIN" status --explain)" "explain names predicate"
assert_match "T001.*ready-to-dispatch" "$("$ORCHID_BIN" status --explain)" "explain ready"

# status in an uninitialized repo (no .orchid/roadmap.md) must not leak awk's
# stderr and must print an explicit marker instead of a blank run_status.
scratch="$WORK/uninit"; mkdir -p "$scratch"
(cd "$scratch" && git init -q . && git commit -q --allow-empty -m root)
rc=0; out="$(ORCHID_REPO="$scratch" HOME="$HOME" "$ORCHID_BIN" status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status must exit 0 in an uninitialized repo"
assert_match "run_status: \(uninitialized\)" "$out" "status prints (uninitialized) marker"
echo "$out" | grep -qi "no such file\|awk:" && fail "status must not leak fm_get's stderr for a missing roadmap"

# v1-m3 Task 2: split-brain checkout (F7) -- .orchid/tasks/ exists (a task
# verb ran against this checkout) but roadmap.md does not (durable state
# lives only on the integration branch). status must WARN, and the warning
# must be the FIRST line, above run_status.
splitb="$WORK/splitbrain"; mkdir -p "$splitb/.orchid/tasks"
(cd "$splitb" && git init -q . && git commit -q --allow-empty -m root)
out_sb="$(ORCHID_REPO="$splitb" HOME="$HOME" "$ORCHID_BIN" status 2>&1)"
assert_eq "WARNING: split-brain checkout (.orchid state without roadmap.md — run from the integration branch)" \
  "$(echo "$out_sb" | head -n1)" "status warns about split-brain as the very first line"
assert_match "^run_status: \(uninitialized\)$" "$out_sb" "status still prints run_status after the split-brain warning"

# healthy fixture (the main $WORK repo on orchid/integration) is unaffected.
echo "$("$ORCHID_BIN" status)" | grep -q "split-brain" && fail "status must not warn split-brain on a healthy checkout"
