#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# ---------------------------------------------------------------------------
# add: mints L001, journals kind lesson, writes the block format verbatim.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" lessons add --scope repo --invalidate-when "test suite fixed" "flaky test in suite X" \
  || fail "lessons add (repo scope)"
[ -f .orchid/lessons.md ] || fail "lessons add creates lessons.md"
grep -q '^## L001 \[active\] repo$' .orchid/lessons.md || fail "lessons add writes the header line verbatim"
grep -q '^statement: flaky test in suite X$' .orchid/lessons.md || fail "lessons add writes statement"
grep -q '^invalidate_when: test suite fixed$' .orchid/lessons.md || fail "lessons add writes invalidate_when"
grep -q '^first: ' .orchid/lessons.md || fail "lessons add writes first"
grep -q '^last_confirmed: ' .orchid/lessons.md || fail "lessons add writes last_confirmed"
assert_match "L001 added \(repo\): flaky test in suite X" "$(cat .orchid/journal.md)" "add journals kind lesson"
assert_match "^## .* run lesson \(" "$(cat .orchid/journal.md)" "add journals as kind=lesson"

# engine-scoped lesson, second id minted sequentially
"$ORCHID_BIN" lessons add --scope "engine:codex" --invalidate-when "codex fixes it" "codex ignores barrel rule" \
  || fail "lessons add (engine scope)"
grep -q '^## L002 \[active\] engine:codex$' .orchid/lessons.md || fail "second lesson mints L002"

# --scope validation
rc=0; bad_scope_out="$("$ORCHID_BIN" lessons add --scope bogus --invalidate-when x "y" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add rejects an invalid --scope"
assert_match "invalid --scope" "$bad_scope_out" "invalid scope names itself"

# missing required flags
rc=0; "$ORCHID_BIN" lessons add --invalidate-when x "y" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add requires --scope"
rc=0; "$ORCHID_BIN" lessons add --scope repo "y" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add requires --invalidate-when"
rc=0; "$ORCHID_BIN" lessons add --scope repo --invalidate-when x >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add requires a statement"

# ---------------------------------------------------------------------------
# list / list --active
# ---------------------------------------------------------------------------
list_out="$("$ORCHID_BIN" lessons list)"
assert_match "^L001	active	repo	flaky test in suite X$" "$list_out" "list shows L001 tab-separated"
assert_match "^L002	active	engine:codex	codex ignores barrel rule$" "$list_out" "list shows L002"
active_out="$("$ORCHID_BIN" lessons list --active)"
[ "$(echo "$active_out" | wc -l | tr -d ' ')" = 2 ] || fail "list --active shows both (both currently active)"

# ---------------------------------------------------------------------------
# update: bumps last_confirmed; --statement rewrites the field; requires at
# least one flag; refuses on a retired lesson.
# ---------------------------------------------------------------------------
before_confirm="$(grep '^## L001' -A4 .orchid/lessons.md | grep '^last_confirmed: ')"
sleep 1
"$ORCHID_BIN" lessons update L001 --statement "flaky test in suite X (confirmed still flaky)" \
  || fail "lessons update --statement"
grep -q '^statement: flaky test in suite X (confirmed still flaky)$' .orchid/lessons.md \
  || fail "update rewrites statement"
after_confirm="$(grep '^## L001' -A4 .orchid/lessons.md | grep '^last_confirmed: ')"
[ "$before_confirm" != "$after_confirm" ] || fail "update bumps last_confirmed"
assert_match "L001 updated" "$(cat .orchid/journal.md)" "update journals kind lesson"

rc=0; "$ORCHID_BIN" lessons update L001 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "update with no flags at all must be refused"

"$ORCHID_BIN" lessons update L002 --confirm || fail "lessons update --confirm alone"

# ---------------------------------------------------------------------------
# retire: requires --reason (INV-08-style), journal-first, flips state.
# ---------------------------------------------------------------------------
rc=0; retire_noreason="$("$ORCHID_BIN" lessons retire L002 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons retire without --reason must be refused"
assert_match "requires --reason" "$retire_noreason" "retire-without-reason names INV-08"

before_journal_lines="$(wc -l < .orchid/journal.md | tr -d ' ')"
"$ORCHID_BIN" lessons retire L002 --reason "engine upgraded past this quirk" || fail "lessons retire with --reason"
grep -q '^## L002 \[retired\] engine:codex$' .orchid/lessons.md || fail "retire flips state to retired"
after_journal_lines="$(wc -l < .orchid/journal.md | tr -d ' ')"
[ "$after_journal_lines" -gt "$before_journal_lines" ] || fail "retire journals a new entry"
assert_match "L002 retire \(active -> retired\): engine upgraded past this quirk" "$(cat .orchid/journal.md)" \
  "retire journals the old->new state and the reason"

rc=0; "$ORCHID_BIN" lessons retire L002 --reason "already gone" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "retiring an already-retired lesson must be refused"

rc=0; "$ORCHID_BIN" lessons update L002 --statement "no" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "update on a retired lesson must be refused"

rc=0; "$ORCHID_BIN" lessons retire NOPE --reason "x" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "retire on a nonexistent id must be refused"

list_out2="$("$ORCHID_BIN" lessons list)"
assert_match "^L002	retired	engine:codex" "$list_out2" "list reflects retired state"
active_out2="$("$ORCHID_BIN" lessons list --active)"
echo "$active_out2" | grep -q "^L002" && fail "list --active must not show a retired lesson"
[ "$(echo "$active_out2" | wc -l | tr -d ' ')" = 1 ] || fail "list --active now shows only L001"

# ---------------------------------------------------------------------------
# consolidate: within-run retired block is NOT age-dropped (nothing in this
# run predates this run's own journal start); cap enforcement refuses over-
# cap without ever touching an active lesson; a hand-crafted retired block
# actually OLDER than the journal's oldest entry IS dropped.
# ---------------------------------------------------------------------------
consolidate_out="$("$ORCHID_BIN" lessons consolidate)" || fail "lessons consolidate (within cap)"
assert_match "nothing to do" "$consolidate_out" "consolidate is a no-op when nothing is stale and under cap"
grep -q '^## L002 \[retired\]' .orchid/lessons.md || fail "consolidate must not drop a retired lesson from the SAME run"
grep -q '^## L001 \[active\]' .orchid/lessons.md || fail "consolidate never touches an active lesson"

# Over-cap: refuses, names candidates, never deletes the active lesson.
printf 'lessons_max_bytes=10\n' > orchid.config
rc=0; overcap_out="$("$ORCHID_BIN" lessons consolidate 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "consolidate over cap must be refused"
assert_match "over cap" "$overcap_out" "over-cap refusal names the cap"
assert_match "L002" "$overcap_out" "over-cap refusal lists the retired lesson as a candidate"
assert_match "never auto-deleted" "$overcap_out" "over-cap refusal states the active-lesson guarantee"
grep -q '^## L001 \[active\]' .orchid/lessons.md || fail "over-cap refusal left L001 (active) untouched"
grep -q '^## L002 \[retired\]' .orchid/lessons.md || fail "over-cap refusal left L002 untouched (no partial write)"
rm -f orchid.config

# Fully-active over-cap: no candidates at all -- still refuses, still names
# that active lessons are never auto-deleted, even with nothing to trim.
lines_before="$(cat .orchid/lessons.md)"
printf '%s\n' "$lines_before" | sed 's/\[retired\]/[active]/' > .orchid/lessons.md
printf 'lessons_max_bytes=10\n' > orchid.config
rc=0; allactive_out="$("$ORCHID_BIN" lessons consolidate 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "all-active over-cap must still be refused"
assert_match "never auto-deleted" "$allactive_out" "all-active over-cap names the guarantee with no candidates"
rm -f orchid.config
printf '%s\n' "$lines_before" > .orchid/lessons.md

# Age-based drop: hand-craft a retired lesson dated BEFORE journal.md's
# oldest entry (simulating a block that predates "the current run" per
# lib/lessons.sh's _lessons_journal_start_date convention) -- consolidate
# must drop it, and must journal that it did.
cat >> .orchid/lessons.md <<EOF
## L009 [retired] repo
statement: stale pre-run lesson
evidence:
first: 2000-01-01T00:00:00Z
last_confirmed: 2000-01-01T00:00:00Z
invalidate_when: n/a
EOF
grep -q '^## L009' .orchid/lessons.md || fail "fixture: L009 planted"
consolidate_out2="$("$ORCHID_BIN" lessons consolidate)" || fail "lessons consolidate (age-drop)"
assert_match "dropped" "$consolidate_out2" "consolidate reports a drop happened"
assert_match "L009" "$consolidate_out2" "consolidate names what it dropped"
grep -q '^## L009' .orchid/lessons.md && fail "consolidate dropped the pre-run retired lesson"
grep -q '^## L001 \[active\]' .orchid/lessons.md || fail "consolidate (age-drop pass) left L001 untouched"
grep -q '^## L002 \[retired\]' .orchid/lessons.md || fail "consolidate (age-drop pass) left the CURRENT-run retired L002 untouched"
assert_match "consolidate: dropped" "$(cat .orchid/journal.md)" "consolidate journals its own hygiene action"

# consolidate against a repo with no lessons.md at all is a clean no-op.
scratch="$WORK/scratch-nolessons"; mkdir -p "$scratch/.orchid/tasks"
( cd "$scratch" && git init -q . && git commit -q --allow-empty -m root )
noless_out="$(ORCHID_REPO="$scratch" ORCHID_EPOCH="$(ORCHID_REPO="$scratch" "$ORCHID_BIN" run start | sed 's/epoch: //')" "$ORCHID_BIN" lessons consolidate)"
assert_match "nothing to consolidate" "$noless_out" "consolidate with no lessons.md is a clean no-op"

# ---------------------------------------------------------------------------
# post-review IMPORTANT 3: embedded newlines in --statement/--evidence/
# --invalidate-when (and --scope) are rejected with a clean orchid_die, at
# both add and update -- a value starting "## L" (or containing a blank
# line) would otherwise corrupt every awk-based block reader in
# lib/lessons.sh (phantom block header / silent pack truncation).
# ---------------------------------------------------------------------------
nl="$(printf 'line one\nline two')"

rc=0; nl_scope_out="$("$ORCHID_BIN" lessons add --scope "$nl" --invalidate-when x "y" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add rejects an embedded newline in --scope"
assert_match "embedded newlines" "$nl_scope_out" "newline rejection names itself (--scope)"

rc=0; nl_inval_out="$("$ORCHID_BIN" lessons add --scope repo --invalidate-when "$nl" "y" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add rejects an embedded newline in --invalidate-when"
assert_match "embedded newlines" "$nl_inval_out" "newline rejection names itself (--invalidate-when)"

rc=0; nl_evid_out="$("$ORCHID_BIN" lessons add --scope repo --invalidate-when x --evidence "$nl" "y" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add rejects an embedded newline in --evidence"
assert_match "embedded newlines" "$nl_evid_out" "newline rejection names itself (--evidence)"

rc=0; nl_stmt_out="$("$ORCHID_BIN" lessons add --scope repo --invalidate-when x "$nl" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons add rejects an embedded newline in the statement"
assert_match "embedded newlines" "$nl_stmt_out" "newline rejection names itself (statement)"

# none of the above left a phantom block behind
grep -q "line one" .orchid/lessons.md && fail "a rejected newline-bearing add must never reach lessons.md"

rc=0; nl_upd_stmt_out="$("$ORCHID_BIN" lessons update L001 --statement "$nl" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons update rejects an embedded newline in --statement"
assert_match "embedded newlines" "$nl_upd_stmt_out" "update newline rejection names itself (--statement)"

rc=0; nl_upd_evid_out="$("$ORCHID_BIN" lessons update L001 --evidence "$nl" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons update rejects an embedded newline in --evidence"
assert_match "embedded newlines" "$nl_upd_evid_out" "update newline rejection names itself (--evidence)"

rc=0; nl_upd_inval_out="$("$ORCHID_BIN" lessons update L001 --invalidate-when "$nl" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "lessons update rejects an embedded newline in --invalidate-when"
assert_match "embedded newlines" "$nl_upd_inval_out" "update newline rejection names itself (--invalidate-when)"

grep -q "line one" .orchid/lessons.md && fail "a rejected newline-bearing update must never reach lessons.md"

# ---------------------------------------------------------------------------
# post-review IMPORTANT 4: add/update/consolidate must journal BEFORE
# writing lessons.md (retire already did). A directory-permission fault
# (chmod -w .orchid) does NOT discriminate ordering here -- atomic_write's
# mktemp scratch file for EITHER journal.md or lessons.md lives in the same
# directory, so both writes fail identically regardless of which one the
# code attempts first (confirmed by hand: reverting add's ordering back to
# write-then-journal left this style of test still green). The
# discriminating fault instead stubs out `libexec/orchid-journal` itself
# (the ONE thing `journal()` below calls) so ONLY the journal write fails,
# while lessons.md's own atomic_write path remains fully capable -- if
# lessons.md changes anyway, the write happened before (or regardless of)
# the journal call.
# ---------------------------------------------------------------------------
journal_bin="$REPO_ROOT/libexec/orchid-journal"
journal_backup="$(mktemp)"
cp "$journal_bin" "$journal_backup"
stub_journal_fail() { printf '#!/usr/bin/env bash\nexit 1\n' > "$journal_bin"; chmod +x "$journal_bin"; }
restore_journal() { cp "$journal_backup" "$journal_bin"; chmod +x "$journal_bin"; }

lf_before_add="$(cat .orchid/lessons.md)"
stub_journal_fail
rc=0; "$ORCHID_BIN" lessons add --scope repo --invalidate-when x "should never land" 2>/dev/null || rc=$?
restore_journal
[ "$rc" -ne 0 ] || fail "lessons add must fail when the journal verb itself fails"
assert_eq "$lf_before_add" "$(cat .orchid/lessons.md)" "journal-first: lessons.md must never change when journal add fails (add)"
grep -q "should never land" .orchid/lessons.md && fail "lessons add wrote lessons.md despite the journal call failing"

lf_before_upd="$(cat .orchid/lessons.md)"
stub_journal_fail
rc=0; "$ORCHID_BIN" lessons update L001 --statement "should never land either" 2>/dev/null || rc=$?
restore_journal
[ "$rc" -ne 0 ] || fail "lessons update must fail when the journal verb itself fails"
assert_eq "$lf_before_upd" "$(cat .orchid/lessons.md)" "journal-first: lessons.md must never change when journal update fails (update)"
grep -q "should never land either" .orchid/lessons.md && fail "lessons update wrote lessons.md despite the journal call failing"

# consolidate: needs a scenario that actually WOULD write (a stale retired
# block to age-drop), not the "nothing to do" no-op path, to prove anything.
cat >> .orchid/lessons.md <<EOF
## L010 [retired] repo
statement: another stale pre-run lesson
evidence:
first: 2000-01-01T00:00:00Z
last_confirmed: 2000-01-01T00:00:00Z
invalidate_when: n/a
EOF
lf_before_con="$(cat .orchid/lessons.md)"
stub_journal_fail
rc=0; "$ORCHID_BIN" lessons consolidate 2>/dev/null || rc=$?
restore_journal
[ "$rc" -ne 0 ] || fail "lessons consolidate must fail when the journal verb itself fails"
assert_eq "$lf_before_con" "$(cat .orchid/lessons.md)" "journal-first: lessons.md must never change when journal consolidate fails"
grep -q '^## L010' .orchid/lessons.md || fail "journal-first: consolidate must not have partially dropped L010"

# the real orchid-journal is genuinely restored (content AND executable),
# not just left in whatever state the last stub_journal_fail/restore_journal
# pairing happened to leave it.
[ -x "$journal_bin" ] || fail "orchid-journal must be restored executable after the stub tests"
diff -q "$journal_bin" "$journal_backup" >/dev/null 2>&1 || fail "orchid-journal content must be byte-identical to its pre-stub original"
rm -f "$journal_backup"
"$ORCHID_BIN" journal add --kind note "post-stub sanity check" >/dev/null || fail "orchid journal add must work normally again after restoration"
