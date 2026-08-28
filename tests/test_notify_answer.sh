#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# --- notify: happy path -----------------------------------------------------
qid="$("$ORCHID_BIN" notify "which db do you want?")"
assert_match "^q-[0-9]+-[0-9a-f]{4}$" "$qid" "qid shape"

[ -f ".orchid/runtime/answers/$qid.question" ] || fail "question file written"
assert_match "which db do you want" "$(cat ".orchid/runtime/answers/$qid.question")" "question file content"

assert_match "^## $qid\$" "$(cat .orchid/BLOCKERS.md)" "BLOCKERS.md has qid heading"
assert_match "which db do you want" "$(cat .orchid/BLOCKERS.md)" "BLOCKERS.md has the text"

assert_match "blocker" "$(cat .orchid/journal.md)" "journal has blocker kind"
assert_match "$qid: which db do you want" "$(cat .orchid/journal.md)" "journal blocker entry carries qid+text"

# --- notify: --task scoping --------------------------------------------------
"$ORCHID_BIN" task create T001 "demo"
_qid_t="$("$ORCHID_BIN" notify --task T001 "ok to deploy on Friday?")"
assert_match "T001" "$(cat .orchid/journal.md)" "task-scoped blocker journaled with task id"
assert_match "T001" "$(cat .orchid/BLOCKERS.md)" "task-scoped blocker noted in BLOCKERS.md"
[ -f ".orchid/runtime/journal-index/T001" ] || fail "task journal index written (via journal add --task)"

# --- notify: stale epoch dies (epoch-fenced, INV-02) ------------------------
rc=0
ORCHID_EPOCH=999999 "$ORCHID_BIN" notify "should never be minted" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "notify with stale epoch must die"
[ -z "$(grep -F 'should never be minted' .orchid/BLOCKERS.md 2>/dev/null)" ] || fail "stale-epoch notify must not touch BLOCKERS.md"

rc=0
unset ORCHID_EPOCH
"$ORCHID_BIN" notify "should never be minted either" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "notify with absent epoch must die"
ORCHID_EPOCH="$("$ORCHID_BIN" run resume | sed 's/epoch: //')"
export ORCHID_EPOCH

# --- answer: unknown qid dies ------------------------------------------------
rc=0
"$ORCHID_BIN" answer q-nonexistent-dead0 yes 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "answer to unknown qid must die"

# --- answer: happy path ------------------------------------------------------
out="$("$ORCHID_BIN" answer "$qid" postgres)"
assert_match "postgres" "$out" "answer echoes choice"
[ -f ".orchid/runtime/answers/$qid.answer" ] || fail "answer file written"
assert_eq "postgres" "$(cat ".orchid/runtime/answers/$qid.answer")" "answer file content"
assert_match "blocker_resolved" "$(cat .orchid/journal.md)" "journal has blocker_resolved kind"
assert_match "$qid: postgres" "$(cat .orchid/journal.md)" "journal blocker_resolved entry carries qid+choice"

# --- answer: idempotent same-choice -----------------------------------------
before="$(wc -l < .orchid/journal.md)"
out2="$("$ORCHID_BIN" answer "$qid" postgres)"
assert_eq "already answered" "$out2" "same-choice re-answer is idempotent"
after="$(wc -l < .orchid/journal.md)"
assert_eq "$before" "$after" "idempotent re-answer must not journal again"

# --- answer: conflicting choice dies -----------------------------------------
rc=0
"$ORCHID_BIN" answer "$qid" mysql 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "answering the same qid differently must die"
assert_eq "postgres" "$(cat ".orchid/runtime/answers/$qid.answer")" "conflicting answer must not overwrite the recorded choice"

# --- answer: works with stale/absent epoch (NOT epoch-fenced, INV-02 exception) --
qid2="$("$ORCHID_BIN" notify "second question?")"

out3="$(ORCHID_EPOCH=999999 "$ORCHID_BIN" answer "$qid2" yes)"
assert_match "yes" "$out3" "answer works even with a stale ORCHID_EPOCH"
assert_eq "yes" "$(cat ".orchid/runtime/answers/$qid2.answer")" "stale-epoch answer file written"

qid3="$("$ORCHID_BIN" notify "third question?")"
( unset ORCHID_EPOCH; "$ORCHID_BIN" answer "$qid3" no ) || fail "answer works with ORCHID_EPOCH entirely absent"
assert_eq "no" "$(cat ".orchid/runtime/answers/$qid3.answer")" "absent-epoch answer file written"

# --- answer: task-scoped resolution must reach the task's journal view ------
# (regression: `orchid answer` used to append blocker_resolved straight to
# journal.md, bypassing runtime/journal-index/<task>, so a task-scoped
# `journal show --task <id>` only ever showed the original blocker, never
# its resolution)
qid_t2="$("$ORCHID_BIN" notify --task T001 "second task blocker?")"
out_t="$("$ORCHID_BIN" answer "$qid_t2" ship-it)"
assert_match "ship-it" "$out_t" "task-scoped answer echoes choice"
task_show="$("$ORCHID_BIN" journal show --task T001)"
assert_match "blocker" "$task_show" "task journal show has the original blocker entry"
assert_match "blocker_resolved" "$task_show" "task journal show has the blocker_resolved entry too"
assert_match "$qid_t2: ship-it" "$task_show" "task journal show carries qid+choice"
assert_match "e-\)" "$task_show" "blocker_resolved entry is stamped the epoch-unknown marker e-"

# --- answer: unfenced journal write still works with stale/absent epoch ----
# and always stamps e- (epoch-unknown), regardless of ORCHID_EPOCH's value.
qid4="$("$ORCHID_BIN" notify "fourth question?")"
out4="$(ORCHID_EPOCH=999999 "$ORCHID_BIN" answer "$qid4" maybe)"
assert_match "maybe" "$out4" "unfenced answer works with a stale epoch"
assert_match "$qid4: maybe" "$(cat .orchid/journal.md)" "unfenced answer journaled with qid+choice"
assert_match "e-\)" "$(cat .orchid/journal.md)" "unfenced answer entry stamped e- even with a stale ORCHID_EPOCH"

qid5="$("$ORCHID_BIN" notify "fifth question?")"
( unset ORCHID_EPOCH; "$ORCHID_BIN" answer "$qid5" sure ) || fail "unfenced answer works with ORCHID_EPOCH entirely absent"
assert_match "$qid5: sure" "$(cat .orchid/journal.md)" "absent-epoch answer journaled with qid+choice"

# --- answer: expiry check fails CLOSED when both `stat` variants fail -------
# (review Minor #10: the age-unknown case used to silently SKIP the expiry
# check entirely -- fail open -- letting an unbounded-age question through
# regardless of answer_expiry_s). A PATH prefix shadowing `stat` with an
# always-failing stub reproduces "both stat variants fail" deterministically,
# without touching the real coreutils this suite otherwise needs.
qid6="$("$ORCHID_BIN" notify "sixth question?")"
STUBBIN_STAT="$WORK/stubbin-stat"; mkdir -p "$STUBBIN_STAT"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN_STAT/stat"; chmod +x "$STUBBIN_STAT/stat"
rc=0
err6="$(PATH="$STUBBIN_STAT:$PATH" "$ORCHID_BIN" answer "$qid6" nope 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "answer must refuse (not silently proceed) when both stat variants fail on the .question file"
assert_match "cannot determine .* age" "$err6" "answer names the age-unknown refusal plainly, rather than skipping the expiry check"
[ ! -f ".orchid/runtime/answers/$qid6.answer" ] || fail "an answer refused for unknown age must never be recorded as answered"

# --- declared choice sets (T009): both edges pinned per L034 -----------------
# A question minted with --choice values records the set with itself, and
# `orchid answer` REFUSES a value outside it, naming the valid ones (L028:
# a refusal names the action that clears it). A question with NO declared
# set keeps today's free-text contract in full.

# A --choice value must survive as one argv word of `orchid answer`, so a
# value with whitespace or a comma (the set's own join character) is
# refused at mint time, never recorded in a shape the reader can't split.
rc=0
"$ORCHID_BIN" notify --choice "two words" "bad choice shape" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a --choice value containing whitespace must be refused at mint time"
rc=0
"$ORCHID_BIN" notify --choice "a,b" "comma in a choice" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a --choice value containing a comma must be refused at mint time"

# ...and a typoed flag dies as usage rather than silently becoming message
# text (the same silent-acceptance shape the choice gate exists to close).
rc=0
"$ORCHID_BIN" notify --choise approve "typoed flag" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown --flag must die as a usage error, not be swallowed into the message text"

qidC="$("$ORCHID_BIN" notify --task T001 --choice approve --choice request-changes --choice defer "promote r-001 to beta?")"
assert_match "^choices: approve,request-changes,defer\$" "$(cat ".orchid/runtime/answers/$qidC.question")" \
  "the .question file records the declared set on its own choices: line"
assert_match "^choices: approve \| request-changes \| defer\$" "$(cat .orchid/BLOCKERS.md)" \
  "BLOCKERS.md names the permitted answers beside the reply command"

# RED: a value outside the declared set is refused, the refusal NAMES the
# valid choices, and nothing is recorded — not the answer file, not a
# blocker_resolved journal entry.
rc=0
errC="$("$ORCHID_BIN" answer "$qidC" ship-it 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "an answer outside the declared choice set must be refused"
assert_match "'ship-it' is not among $qidC's declared choices" "$errC" "the refusal names the rejected value and the qid"
assert_match "approve \| request-changes \| defer" "$errC" "the refusal names the valid choices (L028)"
[ ! -f ".orchid/runtime/answers/$qidC.answer" ] || fail "a refused out-of-set answer must never be recorded as answered"
if grep -q "$qidC: ship-it" .orchid/journal.md; then
  fail "a refused out-of-set answer must never journal a blocker_resolved entry"
fi

# GREEN: a value inside the declared set is accepted and recorded verbatim.
outC="$("$ORCHID_BIN" answer "$qidC" defer)"
assert_match "$qidC: defer" "$outC" "an in-set answer is accepted"
assert_eq "defer" "$(cat ".orchid/runtime/answers/$qidC.answer")" "the in-set choice is recorded verbatim"

# GREEN (the other edge): a question that declares NO set records no
# choices: line and still accepts free text, exactly as before.
qidF="$("$ORCHID_BIN" notify "no declared set here")"
if grep -q '^choices: ' ".orchid/runtime/answers/$qidF.question"; then
  fail "a question minted without --choice must not record a choices: line"
fi
outF="$("$ORCHID_BIN" answer "$qidF" any-free-text-at-all)"
assert_match "any-free-text-at-all" "$outF" "free text stays accepted when the question declares no choice set"
[ ! -f ".orchid/runtime/answers/$qidF.choices" ] \
  || fail "a question minted without --choice must record no declared set at all"

# ...and the set that DOES gate is read from the question's own record, never
# scraped back out of its prose. The `choices:` line in the .question file is
# a display line: it sits at exactly the position the free-text body would
# otherwise start at, so a blocker whose own text opens "choices: ..." is
# indistinguishable from a declaration by any line-matching rule. Reading it
# as one would refuse the operator's legitimate free-text answer and name
# choices nobody ever declared — the silent-mis-gate twin of the typo this
# feature exists to catch. Both directions, so neither half can rot:
qidX="$("$ORCHID_BIN" notify "choices: rollback,retry")"
[ ! -f ".orchid/runtime/answers/$qidX.choices" ] \
  || fail "a blocker whose TEXT starts with 'choices: ' declared nothing — no set may be recorded for it"
outX="$("$ORCHID_BIN" answer "$qidX" "let us discuss it first")"
assert_match "let us discuss it first" "$outX" \
  "a question whose prose merely looks like a declaration must still accept free text"
[ -f ".orchid/runtime/answers/$qidC.choices" ] \
  || fail "a question minted WITH --choice must record the declared set in its own file"
assert_eq "approve,request-changes,defer" "$(cat ".orchid/runtime/answers/$qidC.choices")" \
  "the recorded set is the CSV the refusal above names, verbatim"

# --- a DECLARATION THAT CANNOT BE READ is refused, never waved through -------
# The sidecar's EXISTENCE is the declaration, so the gate has to key on that
# same fact. A sidecar that exists but yields no choice — a truncated runtime,
# a restored backup, or a producer that died and still landed its zero bytes
# through `atomic_write` — is "a set was declared and the record of it is
# gone", NOT "no set was declared". Reading those two as one answer resolves
# it the wrong way: every value sails through for a question whose page told
# the operator their answer would be checked, and the refusal that names the
# valid choices never fires. Both edges, since the whole point is that the two
# cases are distinguishable.
#
# RED. `approve` is deliberately a value that WAS declared: the refusal has to
# be about the unreadable record, not about the value being out of set.
qidE="$("$ORCHID_BIN" notify --choice approve --choice defer "answer me after the sidecar is lost")"
: > ".orchid/runtime/answers/$qidE.choices"
rc=0
errE="$("$ORCHID_BIN" answer "$qidE" approve 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "a question whose declared set cannot be read must refuse the answer, not accept it because the file happened to be empty"
assert_match "declared a choice set" "$errE" \
  "the refusal says a set WAS declared — the operator is owed the difference between a lost record and no record"
assert_match "$qidE.choices" "$errE" \
  "and names the file, because restoring or re-raising it is an operator's move and nothing here can reconstruct it"
if grep -q "is not among" <<<"$errE"; then
  fail "an unreadable declaration must not be reported as an out-of-set value — that would name a set nobody can read as though it had been checked"
fi
[ ! -f ".orchid/runtime/answers/$qidE.answer" ] \
  || fail "an answer refused for an unreadable declaration must never be recorded as answered"

# GREEN, the edge this must not swallow: no sidecar AT ALL still declares
# nothing and still takes free text. Same shape as qidE above, one difference
# — the file is absent rather than empty — so the two conditions are pinned
# apart rather than by one of them alone.
qidN="$("$ORCHID_BIN" notify "no sidecar was ever minted for this one")"
[ ! -f ".orchid/runtime/answers/$qidN.choices" ] \
  || fail "test fixture: a notify with no --choice must mint no sidecar, or the contrast below tests nothing"
outN="$("$ORCHID_BIN" answer "$qidN" "whatever the operator wants to say")"
assert_match "whatever the operator wants to say" "$outN" \
  "an ABSENT sidecar is not a lost one: free text stays accepted exactly as it was before choice sets existed"
