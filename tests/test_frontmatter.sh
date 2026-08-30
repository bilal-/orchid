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

# The newline the guard above CANNOT see, because it does not exist yet when
# the guard runs. awk processes escape sequences in a `-v` operand (POSIX), so
# the two characters `\` `n` -- what an operator flattening prose onto one line
# actually types -- used to reach awk as a REAL newline and split the value
# across two frontmatter lines: the key truncated at "before", the rest landing
# as a bogus `and after` line. fm_set reads both operands out of ENVIRON now,
# which has no escape processing, so the value is stored byte-for-byte.
lit_before="$(grep -c '' "$WORK/T004.md")"
fm_set "$WORK/T004.md" hook_guidance 'before\nand after\ttabbed' \
  || fail "fm_set must accept a value containing literal backslash escapes"
assert_eq 'before\nand after\ttabbed' "$(fm_get "$WORK/T004.md" hook_guidance)" \
  "a literal backslash-n is stored as the two characters it is, never expanded into a real newline"
assert_eq "$lit_before" "$(grep -c '' "$WORK/T004.md")" \
  "and the file gained no lines -- an expanded escape would have split one frontmatter line into two"
assert_eq 1 "$(grep -c '^hook_guidance: ' "$WORK/T004.md")" \
  "exactly one hook_guidance line, so the value did not leave a stray remainder behind"

# The KEY is guarded on the same terms, and only this library can guard it:
# moving off `-v` removed awk's own refusal of a newline, which was the only
# thing that ever objected to one there. `print k ": " v` would otherwise split
# a single frontmatter entry across two lines and land the remainder as a key
# of its own -- the same rule broken by the same accident, since `task set`
# takes its key off the command line too.
cp "$WORK/T004.md" "$WORK/T004.keyguard"
rc=0; key_err="$(fm_set "$WORK/T004.md" "$(printf 'hook_guidance\nsmuggled')" x 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_set must refuse a KEY containing a newline, not write it as two frontmatter lines"
assert_match "newline" "$key_err" "the key refusal names the same single-line constraint"
cmp -s "$WORK/T004.keyguard" "$WORK/T004.md" || fail "a refused newline KEY must leave the file byte-identical too"

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

# ---------------------------------------------------------------------------
# THE DAMAGE EVERY CHECK ABOVE LETS THROUGH (T034 rework) -- and the one this
# repository's own writers used to PRODUCE. A value carrying a newline does not
# empty the file: it splits one entry across two lines, so the key is truncated
# at the break and the REMAINDER sits in the frontmatter as a line belonging to
# no key. That file opens with `---`, closes with `---`, and `id` resolves --
# so it passes the file/empty/delimiter/required-key checks above, `task show`
# prints it happily, and only the split field is quietly wrong.
#
# The fixture is written as bytes rather than produced by fm_set, deliberately:
# fm_set refuses this input now, so driving the fixture through it would leave
# nothing to check. What is on disk here is what the OLD writers left behind,
# which is also what an older orchid, a bad restore or a hand-edit leaves.
# ---------------------------------------------------------------------------
printf -- '---\nid: T010\ntitle: first half of a value\nand the remainder of that value\nstatus: pending\n---\nbody\n' \
  > "$WORK/T010.md"
assert_eq T010 "$(fm_get "$WORK/T010.md" id)" \
  "fixture witness: the split file is one every OTHER check reads as healthy -- id still resolves, which is why this case is needed at all"
rc=0; why="$(fm_check "$WORK/T010.md" id)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_check must reject frontmatter carrying a line that belongs to no key -- that is the residue of a value split across two lines, and every other check in this function passes it"
assert_match "malformed frontmatter" "$why" "fm_check names the structural problem"
assert_match "line 4" "$why" \
  "...and names the LINE, since the rest of the document is readable and nothing else points at the damage"
assert_match "and the remainder of that value" "$why" \
  "...and quotes it, so the operator can recognize the value it was cut out of"

# The GREEN twin, and it is the discriminating one: everything a healthy task
# document legitimately contains -- a comment, a blank line, a bare valued-later
# key, a value with its own colons and hashes -- plus a BODY whose prose lines
# would every one of them be rejected if the scan were not scoped to the
# frontmatter.
printf -- '---\n# a comment, which templates/task.md uses for depends_on\n\nid: T017\ntitle: a value with: a colon, a #hash and an em-dash — in it\nworktree:\n---\nthis body line belongs to no key\nand neither does this one\n' \
  > "$WORK/T017.md"
fm_check "$WORK/T017.md" id >/dev/null \
  || fail "fm_check must accept comments, blank lines, bare keys and colon-bearing values -- and must not read the BODY as frontmatter"
green_case 'fm_check over a document with comments, blank lines and prose body: accepted'
red_case 'fm_check over frontmatter carrying a key-less remainder line: refused, named by line'

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

# ...and the same structural rule at the WRITE end. A rewrite that would land
# frontmatter with a key-less remainder line is refused rather than appending a
# rework brief on top of damage: the arms that call this replace a task's whole
# document, so whatever they emit is what the task becomes. Non-empty and
# fully delimited, so nothing else in this function objects to it.
cp "$WORK/T009.md" "$WORK/T009.structure"
rc=0
wt_bad="$(printf -- '---\nid: T009\ntitle: first half\nand the remainder\nstatus: rework\n---\nbody\n' \
  | fm_write_task "$WORK/T009.md" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_write_task must refuse a replacement whose frontmatter carries a key-less remainder line"
assert_match "malformed frontmatter" "$wt_bad" "the write-end refusal names the same structural problem the read end does"
cmp -s "$WORK/T009.structure" "$WORK/T009.md" \
  || fail "a refused structural rewrite must leave the task byte-identical, exactly as the empty-document refusal does"

# ===========================================================================
# T034 rework -- fm_render_task_template: LITERAL substitution, at the library
# level. This is the CREATE half of the same story the rest of this file tells
# about rewrites, and it is a separate writer with a separate accident.
#
# `orchid task create` used to render templates/task*.md with
# `sed -e "s|__TITLE__|$title|g"`, and a sed REPLACEMENT string is a small
# language rather than literal text:
#
#   `&`  stands for the WHOLE MATCH, so a title of `parser & lexer` was written
#        out as `parser __TITLE__ lexer` -- the placeholder reinstated into the
#        value that was meant to replace it.
#   `\`  introduces an escape whose meaning is IMPLEMENTATION-DEFINED. GNU sed
#        renders `\n` as a real newline (splitting the title across two lines,
#        the remainder landing as a key-less frontmatter line); BSD sed renders
#        it as the single letter `n`.
#   `|`  is the s-command delimiter, which at least failed loudly.
#
# THE CASES PIN THE ROUND TRIP -- the bytes back out equal the bytes in --
# rather than either sed family's particular wrong answer. Pinning "GNU splits
# the line" would pass vacuously on BSD and vice versa, so a case written either
# way is green on half the machines that run it while the defect is fully
# present. As a round trip it is red on both.
# ===========================================================================
printf -- '---\nid: __ID__\ntitle: __TITLE__\narchetype: __ARCHETYPE__\nbranch: task/__ID__\nengine: __ENGINE__\ncreated: __DATE__\nupdated: __DATE__\n---\nBody for __ID__.\n' \
  > "$WORK/tmpl.md"
render_title() { fm_render_task_template "$WORK/tmpl.md" TR1 "$1" feature claude 2026-01-01T00:00:00Z; }

amp="$(render_title 'parser & lexer & 100% & rising')" \
  || fail "fm_render_task_template must render a title containing '&'"
assert_eq 'title: parser & lexer & 100% & rising' "$(grep '^title: ' <<<"$amp")" \
  "'&' is stored byte-for-byte, never expanded into the placeholder text it replaced"

esc="$(render_title 'a\nb, a\ttab, and a lone \ on its own')" \
  || fail "fm_render_task_template must render a title containing backslash escapes"
assert_eq 'title: a\nb, a\ttab, and a lone \ on its own' "$(grep '^title: ' <<<"$esc")" \
  "a literal backslash-n is stored as the two characters it is (GNU sed made it a real newline, BSD sed the letter n)"
assert_eq "$(grep -c '' <<<"$amp")" "$(grep -c '' <<<"$esc")" \
  "and the escaped render has exactly as many lines as the plain one -- an expanded escape would have split the title line in two"
assert_eq 1 "$(grep -c '^title: ' <<<"$esc")" \
  "exactly one title line, so no remainder was left behind as a key-less frontmatter line"

# A substituted value is INERT once placed. The old renderer was one sed pass
# PER PLACEHOLDER, and each later pass rescanned text the earlier ones had
# already written -- so a title naming a placeholder whose pass ran later was
# itself substituted. `__DATE__` is the discriminating one; it went last.
ph="$(render_title 'why __DATE__ and __ID__ are spelled that way')" \
  || fail "fm_render_task_template must render a title that names a placeholder"
assert_eq 'title: why __DATE__ and __ID__ are spelled that way' "$(grep '^title: ' <<<"$ph")" \
  "text already substituted is never rescanned"
assert_eq 'created: 2026-01-01T00:00:00Z' "$(grep '^created: ' <<<"$ph")" \
  "...while the template's OWN __DATE__ was still substituted, so the single scan is a scan and not a skipped pass"
assert_eq 'branch: task/TR1' "$(grep '^branch: ' <<<"$ph")" \
  "...including the second occurrence of __ID__ on another line, so one scan still means every hit"

# THE TOKEN LIST IS PART OF THE CONTRACT, and it lives in the library while the
# templates live in templates/. A sixth placeholder added to a shipped template
# would be rendered into live task files verbatim -- `updated: __UPDATED_BY__`,
# forever -- and nothing above would notice, because these cases supply their
# own template. So every SHIPPED task template is rendered here and checked for
# a leftover token, and for being readable afterwards by the predicate `task
# show` and `orchid doctor` both use.
for shipped in "$REPO_ROOT"/templates/task*.md; do
  shipped_name="${shipped##*/}"
  rendered="$(fm_render_task_template "$shipped" TR2 'a & shipped \n template' feature claude 2026-01-01T00:00:00Z)" \
    || fail "fm_render_task_template must render the shipped template $shipped_name"
  leftover="$(grep -oE '__[A-Z_]+__' <<<"$rendered" | sort -u | tr '\n' ' ' || true)"
  assert_eq "" "$leftover" \
    "$shipped_name renders with no placeholder left over -- the renderer's token list must cover every __TOKEN__ a shipped template uses"
  printf '%s' "$rendered" > "$WORK/rendered.md"
  fm_check "$WORK/rendered.md" id >/dev/null \
    || fail "$shipped_name must render into a document fm_check -- and therefore task show and doctor -- can read"
  assert_eq 'title: a & shipped \n template' "$(grep '^title: ' "$WORK/rendered.md")" \
    "$shipped_name stores a metacharacter title byte-for-byte too, not just the hand-built template above"
done

# A template that cannot be read is a REFUSAL, not an empty render: paired with
# fm_write_task (which is how orchid-task's create arm spells it), an empty
# render would otherwise be a brand-new zero-byte task file.
rc=0; miss_err="$(fm_render_task_template "$WORK/no-such-template.md" TR3 t feature claude d 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "fm_render_task_template must refuse a missing template rather than render nothing and succeed"
assert_match "missing" "$miss_err" "the refusal names the template it could not read"
