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

# ===========================================================================
# T034 (dogfood F34) -- REWRITE-OR-REFUSE, at the library level.
#
# fm_set used to be `awk ... | atomic_write "$f"`, a pipeline that could not
# tell a successful rewrite from a failed one: atomic_write renames whatever
# awk emitted, INCLUDING NOTHING. Two reachable inputs made awk emit nothing --
# a value carrying a newline (awk refuses the -v assignment and dies before
# reading a line of the file) and an already-empty target -- and both left the
# task file at zero bytes while the verb exited 0.
# ===========================================================================
printf -- '---\nid: T004\ntitle: intact\nstatus: pending\nhook_guidance:\n---\nBody4.\n' > "$WORK/T004.md"
cp "$WORK/T004.md" "$WORK/T004.before"

rc=0; nl_err="$(fm_set "$WORK/T004.md" hook_guidance "$(printf 'para one\n\npara two')" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_set must REFUSE a value containing a newline (it used to destroy the file and return 0)"
assert_match "newline" "$nl_err" "the refusal names the single-line constraint it is enforcing"
[ -s "$WORK/T004.md" ] || fail "THE FILE IS EMPTY: a refused fm_set destroyed it, which is the whole defect"
cmp -s "$WORK/T004.before" "$WORK/T004.md" || fail "a refused fm_set must leave the file byte-identical"

# The GREEN twin: the same key, the same call, one line -- accepted.
fm_set "$WORK/T004.md" hook_guidance "shrink the diff and retry" \
  || fail "fm_set must still accept a single-line value"
assert_eq "shrink the diff and retry" "$(fm_get "$WORK/T004.md" hook_guidance)" "an accepted value round-trips"
assert_match "Body4." "$(cat "$WORK/T004.md")" "and the body survives the accepted write"

# An ALREADY-empty target: awk has nothing to print, so the old pipeline
# "succeeded" over and over against a file with nothing in it. That is why the
# destruction stayed silent -- every later write reported success too.
: > "$WORK/T005.md"
rc=0; empty_err="$(fm_set "$WORK/T005.md" status implementing 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_set against an empty file must not report success"
assert_match "empty" "$empty_err" "the refusal says the rewrite would have produced an empty document"

# fm_check -- the shared predicate 'task show' and 'orchid doctor' both read.
fm_check "$WORK/T004.md" id >/dev/null || fail "fm_check must accept an intact frontmatter document"
fm_check "$REPO_ROOT/templates/task.md" >/dev/null \
  || fail "fm_check must accept the shipped task template (comment lines and bare empty keys included)"
rc=0; why="$(fm_check "$WORK/T005.md" id)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_check must reject a zero-byte file"
assert_match "EMPTY" "$why" "fm_check says a zero-byte file is empty"
printf 'no delimiters here\n' > "$WORK/T006.md"
rc=0; why="$(fm_check "$WORK/T006.md" id)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_check must reject a file with no frontmatter"
assert_match "no frontmatter" "$why" "fm_check says the opening delimiter is missing"
printf -- '---\nid: T007\nstatus: pending\n' > "$WORK/T007.md"
rc=0; why="$(fm_check "$WORK/T007.md" id)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_check must reject unterminated frontmatter"
assert_match "no closing" "$why" "fm_check says the closing delimiter is missing"
printf -- '---\nstatus: pending\n---\nbody\n' > "$WORK/T008.md"
rc=0; why="$(fm_check "$WORK/T008.md" id)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_check must reject a task document with no id"
assert_match "no 'id:' value" "$why" "fm_check names the required key that is missing"

# fm_write_task -- the same rewrite-or-refuse rule for the OTHER writer: the
# rework arms replace a task's whole document by piping an aged body (plus a
# fresh brief) into it. atomic_write would rename whatever its stdin gave it,
# so a producer that emitted nothing truncates the task exactly as fm_set's
# old pipeline did -- and `pipefail` reports the producer's failure only after
# that rename, too late for any caller to act on.
printf -- '---\nid: T009\nstatus: rework\n---\nbody\n' > "$WORK/T009.md"
cp "$WORK/T009.md" "$WORK/T009.before"
rc=0; wt_err="$(printf '' | fm_write_task "$WORK/T009.md" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_write_task must refuse an empty replacement document"
assert_match "unusable" "$wt_err" "the refusal says the replacement document is unusable"
cmp -s "$WORK/T009.before" "$WORK/T009.md" \
  || fail "a refused whole-document rewrite must leave the task byte-identical"
printf -- '---\nid: T009\nstatus: rework\n---\nbody\n\nrework brief appended\n' \
  | fm_write_task "$WORK/T009.md" || fail "fm_write_task must accept a complete replacement document"
assert_match "rework brief appended" "$(cat "$WORK/T009.md")" "an accepted whole-document rewrite lands"
