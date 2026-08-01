#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

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
qid_t="$("$ORCHID_BIN" notify --task T001 "ok to deploy on Friday?")"
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
export ORCHID_EPOCH="$("$ORCHID_BIN" run resume | sed 's/epoch: //')"

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
