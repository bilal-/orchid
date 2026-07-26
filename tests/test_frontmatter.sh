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
