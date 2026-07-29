#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
printf -- '---\nid: T001\nstatus: pending\n---\nBody.\n' > "$WORK/T001.md"
assert_eq pending "$(fm_get "$WORK/T001.md" status)" "get"
fm_set "$WORK/T001.md" status implementing
assert_eq implementing "$(fm_get "$WORK/T001.md" status)" "set"
fm_set "$WORK/T001.md" branch task/T001
assert_eq task/T001 "$(fm_get "$WORK/T001.md" branch)" "add"
assert_match "Body." "$(cat "$WORK/T001.md")" "body preserved"

# -- v1-m3 (m2 ledger F9): fm_set on a key whose CURRENT frontmatter line is
# bare "key:" (no value, no trailing space) must replace that line IN PLACE,
# never append a duplicate "key: value" line just before the closing '---'.
# This is the exact shape templates/task.md seeds for base_sha, candidate_
# sha, started_at, etc. -- every one of those is a live fm_set target later.
# The already-working "key: value" (valued) and "key: " (trailing-space,
# empty-value) replacement paths must stay unchanged.
printf -- '---\nid: T002\nstatus: pending\nbase_sha:\ncandidate_sha:\n---\nBody2.\n' > "$WORK/T002.md"
fm_set "$WORK/T002.md" base_sha abc123
assert_eq abc123 "$(fm_get "$WORK/T002.md" base_sha)" "fm_set on a bare empty-valued key sets the value"
count="$(grep -c '^base_sha:' "$WORK/T002.md")"
assert_eq 1 "$count" "fm_set on a bare empty-valued key replaces in place -- exactly one base_sha line remains, never a duplicate"
assert_eq "" "$(fm_get "$WORK/T002.md" candidate_sha)" "an unrelated bare empty-valued key (candidate_sha) is left untouched"
assert_match "Body2." "$(cat "$WORK/T002.md")" "body preserved after fixing a bare empty-valued key"

# body text after the closing '---' that happens to LOOK like a "key:" line
# must never be rewritten -- fm_set's empty-value match is scoped to n==1
# (between the two '---' delimiters) only.
printf -- '---\nid: T003\nstatus: pending\nbranch:\n---\nBody mentions base_sha: nottouched\n' > "$WORK/T003.md"
fm_set "$WORK/T003.md" branch task/T003
assert_eq task/T003 "$(fm_get "$WORK/T003.md" branch)" "fm_set still sets the bare key correctly alongside a look-alike body line"
assert_match "base_sha: nottouched" "$(cat "$WORK/T003.md")" "fm_set never rewrites body text after the closing ---, even if it looks like a key: line"
