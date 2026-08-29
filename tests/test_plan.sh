#!/usr/bin/env bash
# T021: the PLANNING-time carry-forward cross-check.
#
# WHAT IS BEING PROVEN, and why it is worth a suite of its own. r-002's
# requirements omitted a defect r-001 had already found, recorded and
# journaled -- the once-only `started_at` anchor -- and it blocked a task
# hours into the run. Eighteen active lessons and a full previous journal
# were sitting right there while the plan was scoped. That is lesson L016's
# shape ("a mechanism nothing forces you to use is not a fix") applied to
# knowledge, so the fix cannot be a report an operator may remember to read:
# `orchid plan apply` itself has to refuse.
#
# The three cases the brief names -- a covered item, an uncovered one, and an
# explicitly deferred one -- are each proven below on a REAL rollover
# fixture (`orchid run new`), not a hand-built .orchid tree, so what is
# tested is what an operator will actually meet. Two further cases are
# proven because silence is the failure mode this whole check exists to
# remove: a repository whose first run has never rolled over, and a previous
# run that genuinely left nothing. Both must SAY so.
#
# And the ANTI-assertions, which carry as much weight as the three positive
# cases, because every one of them is a way for the gate to print a pass over
# an item nobody considered -- r-002's original miss, wearing a green check.
#
#   3a, 3a2  a false `covered`: both shapes of boilerplate that every task
#            file repeats -- the frontmatter KEYS, and the mechanical VALUES
#            like `verification_commands` -- are pinned as NOT coverage, on
#            the real terms they collide with.
#   3c2      a forged `deferred`: the deferral is what SATISFIES the check,
#            so it is recognized by the operator-only `plan_deferral` entry
#            kind, never by a line of text any admitted kind could write.
#   3d2      a bypass by ordering: `run advance` out of planning is gated on
#            the same condition `plan apply` is, so the refusal cannot be
#            stepped around by taking the two verbs in the other order.
#   3f, 3g   a bypass by waiting: `plan apply` refuses in every run_status, so
#            a mid-run revision that drops the one task covering an item is
#            refused too and moves the integration branch not at all -- and
#            3g pins the remedy that makes that refusal survivable, `plan
#            defer`, open in the same statuses the refusal fires in.
#   5        a false `covered` for a whole ENTRY: r-001's journal records up
#            to six separate findings in a single entry, so section 5 proves
#            coverage is tracked per FINDING -- covering one of three leaves
#            two outstanding (5b), an entry that cannot be split into its
#            findings is closed by nothing but an explicit decision (5c, 5d),
#            and neither the shared preamble (5a2) nor the undivided entry id
#            (5e) can absolve the findings underneath.
#
# RED (before libexec/orchid-plan grew the check): every crosscheck
# invocation exits 2 on an unknown subverb, and every `plan apply` here
# commits regardless of what the previous run left behind.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

# Machine-local Orchid state (the trust store, and the USER config tier) is
# keyed off HOME, so a suite that leaves the operator's real HOME in place is
# not testing this repository -- it is testing this repository plus whatever
# happens to sit in ~/.orchid. That is not theoretical here: `orchid init`
# resolves the integration branch through config_get (libexec/orchid-init:46),
# which falls back to $HOME/.orchid/config (lib/common.sh:460), so an operator
# who has set `integration_branch` there would have every fixture below create
# a differently-named branch and every `git worktree add ... orchid/integration`
# fail -- green on the author's machine, red on theirs, for a reason nothing in
# the output would name. Bound BEFORE the first verb call, exactly as every
# other fixture that runs `orchid init` does (tests/inv/test_INV-02...:30).
export HOME="$MACHINE_HOME"

# new_repo <name> -- an initialized repo plus a worktree of its integration
# branch, cd'd into, with ORCHID_REPO/ORCHID_EPOCH bound to the worktree.
# Same fixture shape tests/test_run.sh's rollover section uses: `run new`
# and `plan apply` both commit through a temp worktree against a real
# integration branch, so a bare .orchid/ directory would not exercise them.
new_repo() {
  local bare="$WORK/$1-bare" wt="$WORK/$1-wt"
  # Never inherit the PREVIOUS fixture's epoch into a repository that has
  # none yet: `run start` mints one, and a stale ORCHID_EPOCH in the
  # environment is exactly what INV-02's fence exists to refuse.
  unset ORCHID_EPOCH
  mkdir -p "$bare"
  (cd "$bare" && git init -q . && git commit -q --allow-empty -m root)
  ORCHID_REPO="$bare" "$ORCHID_BIN" init >/dev/null
  git -C "$bare" worktree add -q "$wt" orchid/integration
  export ORCHID_REPO="$wt"
  cd_scratch "$wt"
  ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
  export ORCHID_EPOCH
}

# roll_over <reason> -- take the current run to a status `run new` accepts
# and roll it. The lease is removed first because a fresh one reads as "a
# live orchestrator session may still be running"; absence reads as no live
# session, exactly as runners/orchid-pump treats it.
roll_over() {
  rm -f .orchid/runtime/lease.json
  "$ORCHID_BIN" run advance blocked --reason "fixture shortcut to a rollover-legal status" >/dev/null
  "$ORCHID_BIN" run new --reason "$1" >/dev/null
}

# ===========================================================================
# 1 -- a repository whose first run has never rolled over. There is no
# previous run, so there is nothing to carry forward -- and that has to be
# STATED. An empty check and an unrun one are indistinguishable otherwise,
# which is the exact ambiguity this feature exists to remove.
# ===========================================================================
new_repo a
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "first task" >/dev/null

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck exits 0 when no run has ever rolled over"
assert_match "no previous run is archived" "$out" \
  "a first run must be reported explicitly, never passed over in silence"

apply_out="$("$ORCHID_BIN" plan apply --reason "initial plan" 2>&1)"
assert_match "^applied: " "$apply_out" "plan apply still commits when nothing is carried forward"
assert_match "no previous run is archived" "$apply_out" \
  "plan apply reports its cross-check even when the answer is 'nothing'"

# ===========================================================================
# 2 -- a previous run that left nothing. Same discipline: the check has run,
# it found no ledger items and no active lessons, and it says so rather than
# printing nothing and reading like a pass nobody performed.
# ===========================================================================
roll_over "open the second run of a repository that recorded nothing"
assert_eq "r-002" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the empty fixture rolled over"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck exits 0 when the previous run left nothing"
assert_match "r-001 recorded no ledger items and carried no active lessons" "$out" \
  "an empty previous run is stated, not skipped"

rc=0; out="$("$ORCHID_BIN" plan defer L001 --reason "nothing to defer" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse when nothing at all is carried forward"
assert_match "nothing is carried forward" "$out" "...and says why, rather than journaling a decision about a phantom"

# The GREEN half of the `run advance` gate proven in 3d2 below: leaving
# planning is refused only while something is UNCONSIDERED, never merely
# because the edge is being taken. Proven on the fixture whose previous run
# left nothing, so a regression that gated the edge itself -- and stranded
# every run that has ever rolled over -- fails here rather than in the field.
"$ORCHID_BIN" run advance running --reason "nothing was carried forward, so planning may close" >/dev/null \
  || fail "run advance must not be gated when the cross-check passes"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" "...and the transition really happens"

# ===========================================================================
# 3 -- the real shape. r-001 records three ledger items and two lessons,
# then rolls over; r-002 is planned against them.
#
# The first two are recorded the two DIFFERENT ways the archived journals
# actually contain them: one with the deliberate `ledger` entry kind, and
# one as prose inside an ordinary entry ("recorded as a ledger candidate
# for..."), which is how r-001 -- the run that motivated all of this --
# wrote every one of its own. If only the tidy spelling were recognized,
# this check would not have caught the miss it was built for. The third is
# there for 3a2: its only anchor is a path every task's verification chain
# names, which is how a real plan produces a false `covered`.
# ===========================================================================
new_repo b
b_bare="$WORK/b-bare"
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "r-001 task" >/dev/null
"$ORCHID_BIN" plan apply --reason "r-001 plan" >/dev/null

"$ORCHID_BIN" journal add --kind ledger \
  "libexec/orchid-task stamps started_at only when the field is empty, so the budget stays anchored to attempt 1" >/dev/null
"$ORCHID_BIN" journal add --kind intervention \
  "drive_implementing lacks the liveness guard its sibling arms carry - recorded as a ledger candidate for the next run" >/dev/null
# The third item is transcribed from r-001's real journal, because the false
# positive it pins is the one this check shipped with and would have died of.
# Its only anchor is a path that lives in every task's verification chain --
# see 3a2 for what that costs if the chain is searched.
"$ORCHID_BIN" journal add --kind ledger \
  "the durable fix - making scripts/ci-local.sh part of every task's verification chain, or of the merge path - is a ledger item for the next run" >/dev/null

"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" \
  "verb_lock_acquire must never eval a jq-authored shell fragment" >/dev/null
"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" \
  "a retired lesson naming quarantine_probe must never reach the next plan" >/dev/null
"$ORCHID_BIN" lessons retire L002 --reason "superseded by the fixture's own point" >/dev/null

# The rollover reason lands in the NEW journal, so it cannot become a
# ledger item of this cross-check -- but it WOULD become one of the next
# run's, so the fixture keeps the trigger words out of it deliberately.
roll_over "open the second run"
assert_eq "r-002" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the loaded fixture rolled over"
echo "# Requirements v2" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "crosscheck exits 3 while carried-forward items are unconsidered"
assert_match "left 4 carried-forward item" "$out" \
  "both ledger spellings and the ACTIVE lesson are carried forward (four items)"
assert_match "UNCOVERED \[ledger\] r-001#[0-9]+ .*started_at" "$out" \
  "the ledger item recorded with the ledger entry kind is found"
assert_match "UNCOVERED \[ledger\] r-001#[0-9]+ .*drive_implementing" "$out" \
  "the ledger item recorded only as prose is found too"
assert_match "UNCOVERED \[ledger\] r-001#[0-9]+ .*ci-local" "$out" \
  "and the verification-chain item is found"
assert_match "UNCOVERED \[lesson\] L001" "$out" "the carried-forward active lesson is found"
grep -q "L002" <<<"$out" \
  && fail "a RETIRED lesson is not carried forward by orchid run new and must not be cross-checked"
grep -q "quarantine_probe" <<<"$out" \
  && fail "the retired lesson's text must not reach the cross-check either"

# The ids are positional in the archived journal, so read them out of the
# report rather than hard-coding an ordinal that a fixture edit would shift.
#
# Anchored to the UNCOVERED VERDICT LINE, and to that line alone. `$out` is
# stdout and stderr merged, and the refusal block on stderr repeats every open
# item's summary verbatim -- so a bare `grep <term>` matches the verdict line
# AND its recovery line, and `grep -oE` then returns the same id TWICE. Such a
# value is still non-empty and still `sort -u`s to one id, so every check in
# this block passes while the id itself carries an embedded newline; `plan
# defer "$drive_id"` below then journals it as two lines ("deferred <id>",
# then "<id>: <reason>"), which is not the one line `plancheck_deferral`
# matches, so the decision reads as recorded and the item stays UNCOVERED.
# Exactly one line per item carries a verdict, so match that one.
item_id() { grep -oE 'r-001#[0-9]+' <<<"$(grep "  UNCOVERED .*$1" <<<"$2")"; }
started_id="$(item_id started_at "$out")"
drive_id="$(item_id drive_implementing "$out")"
cilocal_id="$(item_id ci-local "$out")"
[ -n "$started_id" ] || fail "could not read the started_at ledger item's id back out of the report"
[ -n "$drive_id" ] || fail "could not read the drive_implementing ledger item's id back out of the report"
[ -n "$cilocal_id" ] || fail "could not read the ci-local ledger item's id back out of the report"
[ "$(printf '%s\n%s\n%s\n' "$started_id" "$drive_id" "$cilocal_id" | sort -u | wc -l | tr -d ' ')" = 3 ] \
  || fail "the three ledger items must have distinct ids"

# ---------------------------------------------------------------------------
# 3a -- THE ANTI-ASSERTION this whole design turns on. Every task file
# carries `started_at:` as a frontmatter KEY. A whole-file grep would
# therefore report the started_at ledger item as covered by any task at all,
# including this deliberately unrelated one -- i.e. covered by a plan that
# never considered it. That is not a hypothetical false positive; it is the
# one this check would most plausibly have shipped with, and it would have
# reproduced r-002's original miss while printing "covered".
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T011 "tidy the notify plugin docs" >/dev/null
grep -q '^started_at:' .orchid/tasks/T011.md \
  || fail "fixture assumption broken: task frontmatter no longer carries a started_at key"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "an unrelated task considers nothing"
assert_match "UNCOVERED \[ledger\] $started_id" "$out" \
  "a frontmatter KEY must never count as coverage — every task file contains started_at:"

# ---------------------------------------------------------------------------
# 3a2 -- THE SAME ANTI-ASSERTION ONE LEVEL DEEPER, and the one this check
# actually shipped with. Stripping the frontmatter KEYS is not enough: the
# mechanical VALUES are boilerplate too, and `verification_commands` is the
# worst of them, because every task in a plan names the same suite entry
# points. In r-002's own fifteen-task plan `scripts/ci-local.sh` appears in
# all fifteen files and in nothing but their verification chains -- and it is
# the sole anchor of the r-001 ledger item recorded above, whose entire point
# is that per-task chains were NOT enough to make the gate run. Match on that
# value and the finding reports `covered` by whichever task the glob lists
# first, which is precisely the silent pass this feature exists to prevent.
#
# The task below is otherwise unrelated to every carried item; only its
# verification chain overlaps, exactly as a real plan's would.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task set T011 verification_commands \
  "/bin/bash tests/test_notify_channel.sh && /bin/bash scripts/ci-local.sh --bash /bin/bash" >/dev/null
grep -q '^verification_commands: .*scripts/ci-local.sh' .orchid/tasks/T011.md \
  || fail "fixture assumption broken: the verification chain did not land in T011's frontmatter"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "a shared verification chain considers nothing"
assert_match "UNCOVERED \[ledger\] $cilocal_id" "$out" \
  "a MECHANICAL frontmatter value must never count as coverage — every task's chain names the same suite scripts"

# ---------------------------------------------------------------------------
# 3a3 -- A LESSON THIS RUN'S OWN PLANNING WROTE IS NOT CARRIED FORWARD.
# Nothing is carried from the run you are still scoping, so
# plancheck_lesson_items skips a block whose `first:` postdates this
# journal's own first entry -- and that comparison is the one branch of the
# whole check that no assertion above reaches. Its two failure directions are
# not symmetric, which is why it is pinned in both:
#
#   DROP the cutoff and every lesson an operator writes while planning comes
#     back demanding a deferral. Noisy, wrong, and obvious on the first run.
#   INVERT it and the lessons `orchid run new` actually carried across the
#     rollover disappear from the report instead -- a silent pass over the
#     exact class of knowledge this feature exists to force someone to read,
#     and indistinguishable from a plan that considered all of them.
#
# So the just-written lesson and the carried one (L001) are asserted in the
# same breath: a comparison that has stopped discriminating between them
# fails here whichever way it broke.
#
# THE DATES ARE PINNED RATHER THAN LEFT TO THE CLOCK. `lessons add` stamps
# `first:` with the current second and the rollover entry that defines the
# cutoff was written moments earlier in the same fixture, so whether the verb
# produces a strictly LATER timestamp is a fact about machine load, not about
# behaviour -- and this suite has been stranded by scheduling-dependent
# assertions before (L020). Pinning the field makes each side of the boundary
# a property instead of a race, and makes the third case below -- the tie,
# which lib/plancheck.sh resolves deliberately toward INCLUDING the lesson --
# expressible at all.
#
# pin_lesson_first <id> <iso8601> rewrites just that block's `first:` line;
# the header match is on the id token, so no other block moves.
# ---------------------------------------------------------------------------
pin_lesson_first() {
  awk -v id="$1" -v d="$2" '
    /^## L/ { inblk = ($2 == id) }
    inblk && index($0, "first: ") == 1 { print "first: " d; next }
    { print }
  ' .orchid/lessons.md > "$WORK/lessons.pinned"
  mv "$WORK/lessons.pinned" .orchid/lessons.md
}

# The new block is L002 again: `run new` dropped the RETIRED L002 on the way
# into r-002, and lessons_next_id counts what is present. Incidental here --
# the retired block's own absence is asserted above, before this one exists.
"$ORCHID_BIN" lessons add --scope repo --invalidate-when "n/a" \
  "plancheck_cutoff_probe belongs to the plan being drafted, not to the run it carries from" >/dev/null
own_lesson="$(awk '/^## L/ { last = $2 } END { print last }' .orchid/lessons.md)"
[ -n "$own_lesson" ] || fail "fixture assumption broken: lessons add wrote no block to read back"
cutoff="$(awk '/^## [0-9]/ { print $2; exit }' .orchid/journal.md)"
[ -n "$cutoff" ] || fail "fixture assumption broken: this run's journal has no first entry to date the cutoff from"

pin_lesson_first "$own_lesson" "9999-01-01T00:00:00Z"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "the ledger items are still unconsidered either way"
assert_match "left 4 carried-forward item" "$out" \
  "a lesson written after this run's journal opened is not a carried-forward item"
grep -q "$own_lesson" <<<"$out" \
  && fail "...and it is not reported at all: nothing is carried forward out of the run being planned"
assert_match "UNCOVERED \[lesson\] L001" "$out" \
  "THE OTHER HALF: the lesson run new really did carry across the rollover is still checked, so the cutoff DISCRIMINATES rather than just excluding"

# The tie. Journal and lesson timestamps are both second-resolution, so a
# rollover and a lesson written in the same second are indistinguishable
# here; the costs of the two mistakes are not equal, so a tie includes.
pin_lesson_first "$own_lesson" "$cutoff"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "...still refused, with one more item to consider"
assert_match "left 5 carried-forward item" "$out" \
  "a lesson dated exactly AT the boundary is included — an ambiguous second resolves toward asking the question"
assert_match "UNCOVERED \[lesson\] $own_lesson" "$out" "...and is named, so the operator can answer it"

# Back out of the way: every section below counts four carried items, and
# this probe is not one of them.
pin_lesson_first "$own_lesson" "9999-01-01T00:00:00Z"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_match "left 4 carried-forward item" "$out" "the probe is out of the way again"

# ---------------------------------------------------------------------------
# 3b -- A COVERED ITEM. T010's acceptance criteria name the field, so the
# item is associated with a task and the question has been asked -- and the
# report says WHICH term earned it, because a `covered` line nobody can check
# is the same unexamined pass this whole feature exists to remove.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T010 "re-anchor the attempt clock" >/dev/null
"$ORCHID_BIN" task set T010 acceptance_criteria \
  "stamp started_at on every advance into implementing, not only the first" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "still refused while the other three items are unconsidered"
assert_match "covered   \[ledger\] $started_id .*\(task T010 via started_at\)" "$out" \
  "the ledger item is covered by the task whose text names it; the task AND the anchor are named back"

# ---------------------------------------------------------------------------
# 3b2 -- A COVERED LESSON, on both of the two anchors a lesson has. The brief
# says an association may be "a keyword or lesson-id" one, and a lesson item
# is the only carried kind that owns an id a task can name directly, so both
# halves are pinned:
#
#   the KEYWORD half -- a distinctive term out of the lesson's statement;
#   the ID half -- the bare `L001`, with the statement's terms gone.
#
# Without this, every `[lesson]` line in this suite is UNCOVERED or deferred
# and nothing proves a lesson can be covered AT ALL. plancheck_lesson_items
# builds its searchable text as `<id> <statement>`, so dropping the id from
# it -- an edit no other assertion here would notice -- would silently retire
# the lesson-id association the brief names, and every lesson would come back
# demanding a deferral no task could ever satisfy.
#
# T012 is removed again at the end, so section 3c below still meets L001 as
# an uncovered item and its deferral assertions are unchanged.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T012 "harden the lock helper against evaluated fragments" >/dev/null
"$ORCHID_BIN" task set T012 acceptance_criteria \
  "verb_lock_acquire must build its owner record without evaluating a jq-authored fragment" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "covering the lesson leaves the two open ledger items refusing the plan"
assert_match "covered   \[lesson\] L001 .*\(task T012 via verb_lock_acquire\)" "$out" \
  "a lesson is covered by a task naming a distinctive term of its statement, and that term is named back"

"$ORCHID_BIN" task set T012 acceptance_criteria \
  "the lesson recorded as L001 is what this rework has to satisfy" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "...still refused on the ledger items either way"
assert_match "covered   \[lesson\] L001 .*\(task T012 via L001\)" "$out" \
  "and the lesson id ALONE covers it — the association the brief names, with no statement term left in the task"

rm .orchid/tasks/T012.md
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "dropping the covering task refuses the plan again"
assert_match "UNCOVERED \[lesson\] L001" "$out" \
  "...and returns the lesson to UNCOVERED, so the deferral below is met by an open item (and this arm was not vacuous)"

# ---------------------------------------------------------------------------
# 3c -- AN EXPLICITLY DEFERRED ITEM. Deferral is the release valve: the
# operator may decline to schedule a carried item, but only by name and with
# a reason, journaled before it counts. It reports as `deferred`, never as
# `covered` -- a decision to skip is not the same fact as a task existing.
# ---------------------------------------------------------------------------
defer_out="$("$ORCHID_BIN" plan defer L001 --reason "the lock fix landed in r-001; nothing left to schedule" 2>&1)"
assert_match "L001: deferred" "$defer_out" "plan defer confirms the recorded decision"
grep -q "^deferred L001: the lock fix landed in r-001" .orchid/journal.md \
  || fail "the deferral must be journaled as a durable, reasoned decision"
grep -q "plan_deferral" .orchid/journal.md \
  || fail "the deferral entry carries its own journal kind, so it is auditable as a planning decision"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "one genuinely unconsidered item still refuses the plan"
assert_match "deferred  \[lesson\] L001 .*\(deferred: the lock fix landed" "$out" \
  "a deferred item reports as decided, with its reason, not as covered"
assert_match "UNCOVERED \[ledger\] $drive_id" "$out" "the remaining items are still unconsidered"
assert_match "UNCOVERED \[ledger\] $cilocal_id" "$out" "...both of them"

# ---------------------------------------------------------------------------
# 3c2 -- A FORGED DEFERRAL, which is the same item as 3c seen from the other
# side. The deferral is the ONE thing that satisfies this check, so whatever
# the check reads to recognize one is the gate itself. `orchid plan defer`
# writes its line as the body of a `plan_deferral` entry, and the brokered
# orchestrator surface refuses that kind (tests/test_orchestrator_command.sh)
# precisely because it is operator-only -- but it ADMITS `note`, and a note
# whose text is "deferred <id>: ..." produces a body line byte-identical to
# the real one. So a check that matched the line rather than the entry kind
# would let the very actor the broker was hardened against satisfy its own
# gate in one admitted command, and the broker's refusal would be decoration.
#
# The entry below is written with the admitted kind, exactly as an
# orchestrator could write it, and the item must stay UNCOVERED.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" journal add --kind note "deferred $drive_id: forged by an actor that may not write plan_deferral" >/dev/null
grep -q "^deferred $drive_id: forged" .orchid/journal.md \
  || fail "fixture assumption broken: the forged line did not land in the journal verbatim"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "a forged deferral must not satisfy the cross-check"
assert_match "UNCOVERED \[ledger\] $drive_id" "$out" \
  "...the item stays UNCOVERED: only a plan_deferral entry counts, never a matching line in any other kind"
grep -q "deferred  \[ledger\] $drive_id" <<<"$out" \
  && fail "the forged note must never be reported as a recorded decision"
# The positive half of the same matcher is asserted directly above, in 3c:
# L001's REAL `plan_deferral` entry does report as `deferred`, so what
# changed here is which entries count, not whether deferral works at all.
# The forgery also leaves `plan defer <drive_id>` open in 3e below, where it
# is exercised: had the note counted, that verb would have refused the id as
# "already deferred" and the item would have stayed unconsidered while the
# operator was told a decision already existed.

# ---------------------------------------------------------------------------
# 3d -- plan defer's own refusals. Each of these, admitted, would leave a
# real item unconsidered while looking decided.
# ---------------------------------------------------------------------------
rc=0; out="$("$ORCHID_BIN" plan defer L999 --reason "typo" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse an id that is not carried forward — a typo would read as a decision"
assert_match "not a carried-forward item" "$out" "...saying so"
assert_match "L001" "$out" "...and printing the real ids so the retry is a copy-paste"

rc=0; out="$("$ORCHID_BIN" plan defer "$drive_id" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer requires --reason (INV-08)"
assert_match "requires --reason" "$out" "...naming the requirement"

rc=0; out="$("$ORCHID_BIN" plan defer L001 --reason "again" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "plan defer must refuse to re-defer an item already deferred"
assert_match "already deferred" "$out" "...saying so"

# ---------------------------------------------------------------------------
# 3d2 -- THE ORDER-OF-OPERATIONS BYPASS, which needs no forgery and no flag.
# `plan apply`'s refusal is scoped to `run_status: planning` (3g below says
# why it has to be). So `orchid run advance running` FIRST, then `plan
# apply`, used to commit the same plan with the refusal already scoped out --
# every carried item leaving planning with no task and no recorded decision,
# which is the exact property this feature exists to make impossible. A gate
# skipped by doing the same two things in the other order enforces nothing.
#
# So the gate is on the run_status edge OUT of planning, whichever verb takes
# it. Both legal exits are proven here: `->running` directly, and `->blocked`,
# which would otherwise reach `running` in two legal hops.
#
# This strands nothing: the run is still IN planning at a refusal here, so
# both remedies -- cover it with a task, or `orchid plan defer` -- are open,
# exactly as at the refused `plan apply` in 3e (and, per 3g, exactly as they
# remain on the far side of this edge).
# ---------------------------------------------------------------------------
rc=0; adv_out="$("$ORCHID_BIN" run advance running --reason "start the run without considering the carried items" 2>&1)" || rc=$?
assert_eq 3 "$rc" "run advance must refuse to leave planning while a carried item is unconsidered"
assert_match "UNCOVERED \[ledger\] $drive_id" "$adv_out" "...naming the item that is unconsidered"
assert_match "orchid plan defer" "$adv_out" "...and the remedy, which is still open at this point"
assert_eq planning "$(fm_get .orchid/roadmap.md run_status)" "a refused run advance leaves run_status untouched"
grep -q "start the run without considering" .orchid/journal.md \
  && fail "a refused run advance must not journal its reason — nothing happened"

rc=0; adv_out="$("$ORCHID_BIN" run advance blocked --reason "park it instead of considering the items" 2>&1)" || rc=$?
assert_eq 3 "$rc" "the parking edge out of planning is gated too — blocked -> running is legal afterwards"
assert_eq planning "$(fm_get .orchid/roadmap.md run_status)" "...and it too leaves run_status untouched"

# ---------------------------------------------------------------------------
# 3e -- THE REFUSAL ITSELF. This is the whole feature: the plan cannot be
# committed while a carried-forward item is unconsidered, and the refusal is
# actionable, transactional, and leaves the run exactly where it was.
# ---------------------------------------------------------------------------
pre_integ="$(git -C "$b_bare" rev-parse orchid/integration)"
rc=0; apply_out="$("$ORCHID_BIN" plan apply --reason "r-002 plan" 2>&1)" || rc=$?
assert_eq 3 "$rc" "plan apply refuses while a carried-forward item is unconsidered"
assert_match "plan apply refused" "$apply_out" "the refusal names itself"
assert_match "orchid plan defer $drive_id" "$apply_out" "the refusal prints the exact recovery command"
assert_eq planning "$(fm_get .orchid/roadmap.md run_status)" "a refused plan apply leaves run_status untouched"
assert_eq "$pre_integ" "$(git -C "$b_bare" rev-parse orchid/integration)" \
  "a refused plan apply commits nothing to the integration branch"
grep -q "r-002 plan" .orchid/journal.md \
  && fail "a refused plan apply must not journal its reason — nothing happened"

# The verb lock is released on that refusal (the arm exits under its own EXIT
# trap), so the very next verb works. If it leaked, this defer would refuse
# with a lock-held message instead.
"$ORCHID_BIN" plan defer "$drive_id" \
  --reason "the driver guard belongs to its own follow-up task, not this run" >/dev/null \
  || fail "plan defer must work immediately after a refused plan apply (the verb lock must not leak)"
"$ORCHID_BIN" plan defer "$cilocal_id" \
  --reason "wiring the gate into the merge path is its own task, deliberately not this plan" >/dev/null \
  || fail "plan defer records the decision on the verification-chain item"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck passes once every carried item is covered or deferred"
assert_match "all 4 carried-forward item\(s\) considered" "$out" "...and says so"

apply_out="$("$ORCHID_BIN" plan apply --reason "r-002 plan" 2>&1)"
assert_match "^applied: " "$apply_out" "plan apply proceeds once nothing is left unconsidered"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" "and takes the run to running as before"
# Captured, then matched from a herestring: `git show | grep -q` closes the
# pipe at the first match and `set -o pipefail` (tests/helpers.sh) reports
# the resulting SIGPIPE as a failure of the whole match — lesson L005.
committed_journal="$(git -C "$b_bare" show "orchid/integration:.orchid/journal.md")"
grep -q "^deferred L001: " <<<"$committed_journal" \
  || fail "the deferral decisions ride onto the integration branch in the plan apply commit"

# ---------------------------------------------------------------------------
# 3f -- THE POST-PLANNING BYPASS, and the last one this gate carried.
#
# `plan apply` is a legal verb once run_status is `running` too: it commits
# whatever durable .orchid state is current and journals a `plan_revision`.
# The refusal used to be scoped to `run_status: planning`, which meant the
# very edit that UNCOVERS an item -- a mid-run revision dropping the one task
# that named it -- committed with a printed warning and exit 0, and the item
# left the plan considered by nobody. A gate that merely reports on the edit
# that breaks coverage is not enforcing anything about that edit; it is
# enforcing something about when the operator happens to make it.
#
# Removing T010 is that edit exactly: it was the one task naming started_at,
# and 3b proved that naming is what covered the item.
#
# What is demanded here is more than the exit code. AN UNCOVERED REVISION MUST
# NOT MOVE INTEGRATION: the branch tip is pinned across the refusal, and the
# deletion is still absent from it afterwards -- T010 still readable at the
# tip -- so the revision landed nothing at all rather than landing quietly and
# printing a warning about it.
# ---------------------------------------------------------------------------
rm .orchid/tasks/T010.md
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "sanity: dropping the covering task puts the item back to UNCOVERED"

pre_integ="$(git -C "$b_bare" rev-parse orchid/integration)"
rc=0; apply_out="$("$ORCHID_BIN" plan apply --reason "mid-run revision" 2>&1)" || rc=$?
assert_eq 3 "$rc" "plan apply refuses AFTER planning too — the scoping WAS the bypass"
assert_match "plan apply refused" "$apply_out" "the refusal names itself in this status as well"
assert_match "UNCOVERED \[ledger\] $started_id" "$apply_out" \
  "...naming the item this revision uncovered"
assert_match "orchid plan defer" "$apply_out" "...and the remedy, which is open here too (3g)"
assert_eq "$pre_integ" "$(git -C "$b_bare" rev-parse orchid/integration)" \
  "AN UNCOVERED REVISION MOVES NOTHING: the integration branch is exactly where it was"
git -C "$b_bare" cat-file -e "orchid/integration:.orchid/tasks/T010.md" 2>/dev/null \
  || fail "...and the deletion that uncovered the item is nowhere on the branch"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" \
  "a refused mid-run plan apply leaves run_status untouched"
grep -q "mid-run revision" .orchid/journal.md \
  && fail "a refused mid-run plan apply must not journal its reason — nothing happened"

# ---------------------------------------------------------------------------
# 3g -- WHY THAT REFUSAL IS NOT A DEAD END: the remedy is legal from the status
# the refusal fires in. `orchid plan defer` used to require `planning`, on the
# reasoning that a deferral is a decision about a plan -- and that restriction
# is precisely what forced the refusal above to be scoped away, since an
# operator meeting it could neither cover the item (the plan is committed) nor
# record the decision (the verb was closed). Only one of the two could keep
# its restriction. So the deferral opened and the gate closed, and this is the
# assertion that keeps them paired: if `plan defer` ever re-acquires a
# run_status precondition, this fails rather than 3f quietly becoming a trap.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" plan defer "$started_id" \
  --reason "the started_at anchor goes back to the next run's plan now that T010 is dropped" >/dev/null \
  || fail "plan defer must stay open after planning — it is the refused revision's only remedy"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "the recorded decision closes the item in running, exactly as it does in planning"

apply_out="$("$ORCHID_BIN" plan apply --reason "mid-run revision" 2>&1)"
assert_match "^applied: " "$apply_out" "...and the same revision commits once nothing is left unconsidered"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" \
  "a mid-run apply does not re-take the planning -> running edge"
# The contrast that makes 3f's pinned sha non-vacuous: this apply DOES move
# the branch and DOES carry the deletion, so the unchanged tip up there is the
# refusal's doing and not some way in which this fixture cannot commit at all.
[ "$pre_integ" != "$(git -C "$b_bare" rev-parse orchid/integration)" ] \
  || fail "the considered revision must move the integration branch"
if git -C "$b_bare" cat-file -e "orchid/integration:.orchid/tasks/T010.md" 2>/dev/null; then
  fail "...carrying with it the very deletion 3f refused to land"
fi

rc=0; out="$("$ORCHID_BIN" plan bogus 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown plan subverb is refused"
assert_match "crosscheck" "$out" "usage names the cross-check subverb"
assert_match "defer" "$out" "usage names the defer subverb"

# ===========================================================================
# 4 -- a deferral postpones an item; it does not erase it. `plan_deferral`
# is itself a ledger kind, so all four of r-002's deferrals -- the three
# recorded during planning and the one 3g recorded after it -- come back as
# r-003's carried-forward items and need either a task or a fresh reason.
#
# Without this, the check would launder a defect out of existence in exactly
# two rollovers -- one more run than the failure it was built to prevent,
# and far harder to notice, because the item would leave no trace of ever
# having been raised.
# ===========================================================================
roll_over "open the third run"
assert_eq "r-003" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the fixture rolled over a second time"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "last run's deferrals are unconsidered again in the new plan"
assert_match "UNCOVERED \[ledger\] r-002#[0-9]+ .*deferred $drive_id" "$out" \
  "the ledger item deferred in r-002 resurfaces in r-003 rather than vanishing"
assert_match "UNCOVERED \[ledger\] r-002#[0-9]+ .*deferred L001" "$out" \
  "the deferral of the lesson resurfaces too, carrying its recorded reason"
assert_match "UNCOVERED \[ledger\] r-002#[0-9]+ .*deferred $cilocal_id" "$out" \
  "and so does the deferral of the verification-chain item"
assert_match "UNCOVERED \[ledger\] r-002#[0-9]+ .*deferred $started_id" "$out" \
  "and so does the one recorded AFTER planning — a mid-run deferral is a full ledger entry, not a lesser one that lapses with the run"
assert_match "UNCOVERED \[lesson\] L001" "$out" \
  "and the lesson itself is still active, so it is still carried forward"

# ===========================================================================
# 5 -- AN ENTRY IS NOT A FINDING, which is the property everything above
# quietly assumed and r-001's real journal disproves. Its arbitration entries
# carry two, three, four and six separate defects apiece, in one entry each:
#
#   "CARRIED AS LEDGER ITEMS: (1) drive_implementing lacks the liveness
#    guard ... (2) drive_surface_admits treats a soft surface as ... (3) the
#    task walk's fd 0 is the `task list` pipe ... (4) drive_testing runs the
#    full suite BEFORE consulting the hook gate ..."
#
# Tracked per ENTRY, one task naming ONE of those four marks the entry
# `covered` and the other three leave planning unconsidered, silently, under
# a green verdict line. That is r-002's original miss reproduced by the very
# check built to prevent it -- and worse than the miss, because the report
# says in writing that someone looked.
#
# So coverage is tracked per FINDING. The four fixture entries below are the
# four shapes that decides:
#
#   an ENUMERATED entry, split on its `(k) ` markers into findings that are
#     covered and deferred one at a time (5b is the brief's RED case: three
#     findings, one covered, two still outstanding);
#   an UNDECOMPOSABLE entry, which announces several findings in prose that
#     cannot be split without guessing, and is therefore never matched
#     against task text at all (5c);
#   a SHORT-COUNT entry, which enumerates fewer findings than it states it
#     carries (5d);
#   a SCRAMBLED entry, whose markers run 1, 3, 2, so an ascending scan stops
#     early and the finding it never reached is buried inside a segment
#     attributed to another one (5d2);
#   a GAPPED entry, whose markers run 1, 2, 4 -- the shape an ordinal struck
#     out of a hand-edited enumeration leaves behind, and the one a check for
#     the NEXT ordinal alone walks straight past (5d3).
#
# The last three are the same lesson three times: A SHORTER TIDY LIST IS
# WORSE THAN NO LIST. Split any of them and the survivors come back closeable
# with a green line while the finding that fell off is never named at all --
# one report, several verdicts, and the thing this check exists to surface
# gone without a trace. All three are therefore treated as undecomposable.
#
# RED (per-entry tracking): 5a finds three findings where one item exists, so
# every id lookup below comes back empty and the assertions fail on the spot.
# ===========================================================================
new_repo c
c_bare="$WORK/c-bare"
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "r-001 task" >/dev/null
"$ORCHID_BIN" plan apply --reason "r-001 plan" >/dev/null

# The enumerated entry. Its PREAMBLE deliberately names drive_worktrees --
# a term belonging to none of the three findings -- because preamble text is
# text every finding shares, and shared text whose anchors counted would
# cover all three at once. 5a2 pins that it covers none.
"$ORCHID_BIN" journal add --kind ledger \
  "ARBITRATION: approve attempt 8 of drive_worktrees and carry three findings as ledger items: (1) drive_implementing lacks the liveness guard its sibling arms carry, so a failed implementer spawns duplicates into one worktree; (2) drive_surface_admits treats a soft surface as admitting every verb, so failover wakes the whole mechanical tick; (3) verify_stdin_inherit lets orchid verify consume the task walk's own pipe and truncate the pass" >/dev/null
# The undecomposable entry, transcribed in shape from r-001's own six-finding
# merge note: a plural announcement and then prose. Where one finding ends
# and the next begins is a guess, and a guess absolves whatever falls on the
# wrong side of it.
"$ORCHID_BIN" journal add --kind ledger \
  "CARRIED AS LEDGER ITEMS, not fixed here: the beta_qualify_trust question above; a symlinked --output leaving harness_created directories in a target it refuses to write to; and tests/test_manifest.sh still naming the superseded version" >/dev/null
# The short-count entry: it says four, it enumerates two.
"$ORCHID_BIN" journal add --kind ledger \
  "four outstanding findings are carried into the next run: (1) release_channel_regex now exists in four hand-synced copies and only one of them has shape tests; (2) probe_prompt_echo feeds the expected string into the prompt it then greps for" >/dev/null
# The scrambled entry: markers 1, 3, 2. It states no count and uses no plural
# marker, so nothing but the ordering itself says the split is untrustworthy.
# An ascending scan finds (1) and then (2) -- which sits LAST -- and never
# reaches (3), burying uninstall_symlink_assert inside finding one.
"$ORCHID_BIN" journal add --kind ledger \
  "ARBITRATION: carried findings, listed out of order: (1) merge_rebase_regeneration records a blocking pass inferred from the manifest rather than tested; (3) uninstall_symlink_assert uses a test that is false for a dangling link; (2) qualify_output_symlink leaves harness directories in a target it refuses to write to" >/dev/null
# The gapped entry: markers 1, 2, 4. The ascending scan takes (1) and (2),
# finds no (3) after them, and stops -- a clean-looking two-finding split
# with trust_walk_symlink buried inside the second segment. Like the
# scrambled entry it states no count and uses no plural marker, so the GAP
# itself is the only evidence the split cannot be trusted.
"$ORCHID_BIN" journal add --kind ledger \
  "ARBITRATION: carried findings, with a gap where one was struck out: (1) notify_dedupe_window drops the second alert of a pair naming different tasks; (2) status_lease_age reads the lease mtime rather than the stamp recorded inside it; (4) trust_walk_symlink follows a symlinked plugin directory out of the repository" >/dev/null

roll_over "open the second run"
assert_eq "r-002" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the multi-finding fixture rolled over"
echo "# Requirements v2" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null

# ---------------------------------------------------------------------------
# 5a -- five journal entries, SEVEN carried-forward items: the enumerated one
# is three findings, the other four are one apiece.
# ---------------------------------------------------------------------------
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "crosscheck exits 3 while the carried findings are unconsidered"
assert_match "left 7 carried-forward item" "$out" \
  "the entry carrying three findings is three items, so five entries are seven"

# Read the ids off the VERDICT lines only -- the stderr refusal block repeats
# every open item, so a looser grep returns each id twice and every check
# below would pass while holding a two-line value (the trap 3's own comment
# documents at length).
part_id() { grep -oE 'r-001#[0-9]+\.[0-9]+' <<<"$(grep "  UNCOVERED \[ledger\] .*$1" <<<"$2")"; }
whole_id() { grep -oE 'r-001#[0-9]+' <<<"$(grep "  UNCOVERED \[ledger\] .*$1" <<<"$2")"; }
f1="$(part_id drive_implementing "$out")"
f2="$(part_id drive_surface_admits "$out")"
f3="$(part_id verify_stdin_inherit "$out")"
undec_id="$(whole_id beta_qualify_trust "$out")"
short_id="$(whole_id "four outstanding findings" "$out")"
scram_id="$(whole_id "listed out of order" "$out")"
gap_id="$(whole_id "with a gap where one was struck out" "$out")"
[ -n "$f1" ] || fail "the enumerated entry's first finding must be an item of its own"
[ -n "$f2" ] || fail "...and its second"
[ -n "$f3" ] || fail "...and its third"
[ -n "$undec_id" ] || fail "the undecomposable entry must still be reported"
[ -n "$short_id" ] || fail "the short-count entry must still be reported"
[ -n "$scram_id" ] || fail "the scrambled entry must still be reported"
[ -n "$gap_id" ] || fail "the gapped entry must still be reported"
[ "$(printf '%s\n%s\n%s\n' "$f1" "$f2" "$f3" | sort -u | wc -l | tr -d ' ')" = 3 ] \
  || fail "the three findings of one entry must have three distinct ids"
assert_eq "${f1%.*}" "${f3%.*}" "...all bearing the ordinal of the single entry that recorded them"

# ---------------------------------------------------------------------------
# 5a2 -- PREAMBLE TEXT IS NOT COVERAGE. The words before `(1)` belong to
# every finding equally, so counting them would restore per-entry tracking
# under a different name: one task naming the entry's narrative would close
# all three findings at once.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T030 "rework drive_worktrees provisioning" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "a task naming only the entry's preamble considers nothing"
assert_match "UNCOVERED \[ledger\] $f1" "$out" \
  "a term from the shared preamble must not cover the findings that follow it"
assert_match "UNCOVERED \[ledger\] $f2" "$out" "...any of them"
assert_match "UNCOVERED \[ledger\] $f3" "$out" "...at all"

# ---------------------------------------------------------------------------
# 5b -- THE RED CASE THE BRIEF NAMES. One entry, three findings, ONE of them
# covered. The other two must still be outstanding. Under per-entry tracking
# the single task below closed the entry and all three findings left planning
# with nobody having read two of them.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T031 "make the orchestrate surface refuse a soft engine" >/dev/null
"$ORCHID_BIN" task set T031 acceptance_criteria \
  "drive_surface_admits must not report a soft surface as admitting every verb" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "covering one finding of an entry must not clear the plan"
assert_match "covered   \[ledger\] $f2 .*\(task T031 via drive_surface_admits\)" "$out" \
  "the finding the task names is covered, and the anchor that earned it is named back"
assert_match "UNCOVERED \[ledger\] $f1" "$out" \
  "THE POINT: its sibling finding in the same entry stays outstanding"
assert_match "UNCOVERED \[ledger\] $f3" "$out" "...and so does the third"

# ---------------------------------------------------------------------------
# 5c -- AN UNDECOMPOSABLE ENTRY IS NOT MATCHABLE AT ALL. It announces several
# findings in prose, so its text is the union of all of them and ANY anchor
# in it would close the lot. A task naming one of the three below therefore
# closes nothing: the operator has to say, in a reason, that the others were
# considered. Inferred absolution is exactly what this check exists to stop.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T032 "refresh the version strings the manifest suite pins" >/dev/null
"$ORCHID_BIN" task set T032 acceptance_criteria \
  "tests/test_manifest.sh must name the current version in its comments" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "a task matching one finding of an unsplittable entry does not clear it"
assert_match "UNCOVERED \[ledger\] $undec_id" "$out" \
  "an entry whose findings cannot be separated is never closed by a text match"
grep -q "covered   \[ledger\] $undec_id" <<<"$out" \
  && fail "matching one finding of an unsplittable entry must never report the entry covered"
assert_match "records SEVERAL findings" "$out" \
  "...and the report says WHY it cannot be covered, so the operator is not left guessing"

# ---------------------------------------------------------------------------
# 5d -- AN ENTRY THAT ENUMERATES FEWER FINDINGS THAN IT STATES. Splitting it
# on its markers would produce two tidy, coverable items and lose the two it
# only claimed -- a decomposition that is worse than none, because each of
# the two survivors can now be closed with a green line. Stated count over
# enumerated count is the check; a mismatch falls back to undecomposable.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T033 "collapse the prerelease regex to one copy" >/dev/null
"$ORCHID_BIN" task set T033 acceptance_criteria \
  "release_channel_regex must exist once, with shape tests on the single copy" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "the short-count entry is still unconsidered"
grep -q "$short_id\.[0-9]" <<<"$out" \
  && fail "an entry that enumerates fewer findings than it states must not be split at all"
assert_match "UNCOVERED \[ledger\] $short_id" "$out" \
  "...and a task matching one of the two it DID enumerate must not close it"

# ---------------------------------------------------------------------------
# 5d2 -- A SCRAMBLED ENUMERATION. Markers 1, 3, 2: scanning ascending finds
# (1), then (2) -- which sits last -- and stops, because there is no (3)
# after it. That yields two clean-looking findings, and the third is buried
# inside the first one's segment, coverable by anything that happens to match
# its neighbour and never named on its own line. The entry states no count
# and uses no plural marker, so the ORDERING is the only evidence that the
# split cannot be trusted, and it has to be enough.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T034 "fix the uninstall symlink assertion" >/dev/null
"$ORCHID_BIN" task set T034 acceptance_criteria \
  "uninstall_symlink_assert must hold for a dangling symlink" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "the scrambled entry is still unconsidered"
grep -q "$scram_id\.[0-9]" <<<"$out" \
  && fail "an out-of-order enumeration must not be split into the prefix an ascending scan happens to reach"
assert_match "UNCOVERED \[ledger\] $scram_id" "$out" \
  "...and the finding the scan never reached cannot be closed by a task naming it, because the entry is not matchable at all"

# ---------------------------------------------------------------------------
# 5d3 -- A GAPPED ENUMERATION, markers 1, 2, 4. The ascending scan takes (1)
# and (2), looks for (3), finds none, and stops with a tidy two-finding
# split -- so the third finding sits inside segment 2 and any anchor of its
# NEIGHBOUR closes it. Checking only whether the NEXT ordinal exists says
# yes-there-is-no-(3) and walks straight past the (4) that is right there:
# the malformation has to be looked for across the WHOLE enumeration, not
# one place past its end. A struck-out item in a hand-edited list leaves
# exactly this shape, which is why it is a fixture and not a curiosity.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T035 "stop the trust walk escaping through a symlink" >/dev/null
"$ORCHID_BIN" task set T035 acceptance_criteria \
  "trust_walk_symlink must not follow a plugin directory link out of the repository" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "the gapped entry is still unconsidered"
grep -q "$gap_id\.[0-9]" <<<"$out" \
  && fail "a gapped enumeration must not be split into the prefix the ascending scan happens to reach"
assert_match "UNCOVERED \[ledger\] $gap_id" "$out" \
  "THE POINT: a task naming the finding BEHIND the gap does not close the entry — its two siblings would have left planning under one green line"
grep -q "covered   \[ledger\] $gap_id" <<<"$out" \
  && fail "a gapped entry must never report covered: its segments are not its findings"

# ---------------------------------------------------------------------------
# 5e -- DEFERRAL IS PER FINDING TOO, and the undivided entry id of a
# decomposed entry is not an item. Admitting it would hand back the per-entry
# absolution in one command: one deferral, three findings gone.
# ---------------------------------------------------------------------------
rc=0; out="$("$ORCHID_BIN" plan defer "${f1%.*}" --reason "the whole entry at once" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "the entry id of a DECOMPOSED entry must not be deferrable — its findings are the items"
assert_match "not a carried-forward item" "$out" "...saying so, and printing the real ids"

"$ORCHID_BIN" plan defer "$f1" --reason "the driver guard is its own follow-up task, deliberately not this plan" >/dev/null \
  || fail "a single finding of an entry is deferrable by its own id"
"$ORCHID_BIN" plan defer "$f3" --reason "the stdin drain lands with the verify rework, not here" >/dev/null \
  || fail "...and so is its sibling, independently"
"$ORCHID_BIN" plan defer "$undec_id" --reason "T032 takes the manifest strings; the rest were read and postponed by hand" >/dev/null \
  || fail "an unsplittable entry is closed by an explicit decision, which is the only thing that closes it"
"$ORCHID_BIN" plan defer "$short_id" --reason "the regex copies are T033; the probe echo was read and postponed" >/dev/null \
  || fail "...and so is a short-count entry"
"$ORCHID_BIN" plan defer "$scram_id" --reason "T034 takes the symlink assertion; the other two were read and postponed" >/dev/null \
  || fail "...and so is a scrambled one"
"$ORCHID_BIN" plan defer "$gap_id" --reason "T035 takes the trust walk; the alert dedupe and the lease stamp were read and postponed" >/dev/null \
  || fail "...and so is a gapped one"

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "crosscheck passes once every FINDING is covered or deferred"
assert_match "all 7 carried-forward item\(s\) considered" "$out" "...counting findings, not entries"
assert_match "deferred  \[ledger\] $f1 .*\(deferred: the driver guard" "$out" \
  "a deferred finding reports its own recorded reason"
assert_match "covered   \[ledger\] $f2 " "$out" "...while its covered sibling still reports as covered"

apply_out="$("$ORCHID_BIN" plan apply --reason "r-002 plan" 2>&1)"
assert_match "^applied: " "$apply_out" "plan apply proceeds once no finding is left unconsidered"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" "...and takes the run to running"
committed_journal="$(git -C "$c_bare" show "orchid/integration:.orchid/journal.md")"
grep -q "^deferred $f3: the stdin drain" <<<"$committed_journal" \
  || fail "the per-finding deferrals ride onto the integration branch with the plan"

# ===========================================================================
# 6 -- AN UNREADABLE RECORD IS NOT AN EMPTY ONE, which is the assumption
# every section above rests on and this one attacks directly.
#
# Sections 1 and 2 pinned the two states in which the right answer is "there
# is nothing to carry forward", and both are STATED rather than passed over
# in silence. What neither of them could see is that a THIRD state produced
# the identical output: when the previous run's record could not be read at
# all -- its archive deleted, its archived journal gone, a roadmap that could
# not say which run this is -- both item generators returned the empty list,
# which is byte-for-byte the list a run that left nothing produces. The check
# printed "recorded no ledger items ... (stated, not skipped)" and exited 0,
# and `plan apply` committed the plan over every finding in that record.
#
# That is this file's own failure mode wearing its own green line: the report
# does not say "I looked and there was nothing" when it means "I could not
# look", because from the report's side those two are one string. And it is
# WORSE than the miss the whole feature exists to prevent, because r-002's
# operator at least had no line of output claiming the question had been
# asked.
#
# So each shape below is broken deliberately, one at a time, and each must
# refuse with exit 4 -- its own code, because neither remedy for an uncovered
# item repairs a missing archive -- name what could not be read, and then
# LIFT the moment the record is restored. The last case is the one that
# matters most: the same plan, genuinely green at exit 0, must not print that
# same verdict once its record is taken away.
#
# RED (before answerability was split from the answer): every `assert_eq 4`
# below sees 0 or 3 -- 0 where the empty list was read as an empty ledger,
# 3 where a stale archive was read as the previous run -- and the two
# fail-open anti-assertions fire on the "recorded no ledger items" and "no
# previous run is archived" lines the check printed over a record it never
# read.
# ===========================================================================
new_repo d
d_bare="$WORK/d-bare"
echo "# Requirements" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null
"$ORCHID_BIN" task create T001 "r-001 task" >/dev/null
"$ORCHID_BIN" plan apply --reason "r-001 plan" >/dev/null
"$ORCHID_BIN" journal add --kind ledger \
  "carried as a ledger item: prevrun_archive_probe reads the previous run's archived journal and cannot tell a missing one from an empty one" >/dev/null
roll_over "open the second run of the archive fixture"
assert_eq "r-002" "$(fm_get .orchid/roadmap.md run_id)" "sanity: the archive fixture rolled over"
echo "# Requirements v2" > .orchid/requirements.md
"$ORCHID_BIN" requirements import .orchid/requirements.md >/dev/null

# set_run_id <value> -- rewrite roadmap.md's run_id in place. Pure bash: this
# suite does not source lib/common.sh, so fm_set's atomic_write is not
# defined here and calling it would fail silently mid-pipeline (the roadmap
# would keep its old value and every assertion below would pass for the wrong
# reason).
set_run_id() {
  local v="$1" line tmp="$WORK/roadmap-rewrite"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "run_id: "*) printf 'run_id: %s\n' "$v" >> "$tmp" ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < .orchid/roadmap.md
  mv "$tmp" .orchid/roadmap.md
}

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "sanity: the carried item is unconsidered while its record is readable"
probe_id="$(grep -oE 'r-001#[0-9]+' <<<"$(grep "  UNCOVERED \[ledger\] .*prevrun_archive_probe" <<<"$out")")"
[ -n "$probe_id" ] || fail "sanity: the fixture's ledger item must be reported before anything is broken"
head_before="$(git -C "$d_bare" rev-parse orchid/integration)"

# ---------------------------------------------------------------------------
# 6a -- THE ARCHIVED JOURNAL IS GONE. The archive directory is still there,
# so nothing about the shape of the state says anything is wrong; the ledger
# this check reads simply is not in it.
# ---------------------------------------------------------------------------
mv .orchid/runs/r-001/journal.md "$WORK/d-archived-journal"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 4 "$rc" "an archived journal that cannot be read is refused, not reported as an empty ledger"
assert_match "cannot be answered" "$out" "...saying that the question could not be answered at all"
assert_match "journal.md is missing or unreadable" "$out" "...and naming exactly what it could not read"
grep -qF "recorded no ledger items" <<<"$out" \
  && fail "THE FAIL-OPEN: a deleted archive must never print that the previous run left nothing — that verdict and this state produce the same empty list, which is why the empty list may not decide it"
grep -qF "item(s) considered" <<<"$out" \
  && fail "...and must never report the plan as considered against a record it never read"

rc=0; out="$("$ORCHID_BIN" plan apply --reason "apply over an unreadable archive" 2>&1)" || rc=$?
assert_eq 4 "$rc" "plan apply refuses over a record it could not read"
assert_match "could not be answered" "$out" \
  "...naming the repair, not the two remedies that have nothing to act on when no item was listed"
grep -qF "orchid plan defer <id>" <<<"$out" \
  && fail "a refusal that listed no item must not tell the operator to defer one"
assert_eq "$head_before" "$(git -C "$d_bare" rev-parse orchid/integration)" \
  "...and the integration branch does not move: nothing is committed over an unread record"
grep -q "apply over an unreadable archive" .orchid/journal.md \
  && fail "a refused plan apply must not journal its reason — nothing happened"

rc=0; out="$("$ORCHID_BIN" run advance running --reason "leave planning over an unreadable archive" 2>&1)" || rc=$?
assert_eq 4 "$rc" "the same refusal gates the edge out of planning, so it cannot be stepped around by ordering"
assert_eq planning "$(fm_get .orchid/roadmap.md run_status)" "...and the run stays in planning"

rc=0; out="$("$ORCHID_BIN" plan defer "$probe_id" --reason "considered elsewhere" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a deferral cannot be recorded against a carried-forward list that could not be built"
grep -qF "nothing is carried forward" <<<"$out" \
  && fail "THE SAME FAIL-OPEN IN THE REMEDY: the command did not find an empty ledger, it failed to find the ledger"
assert_match "could not be built" "$out" "...and it says which of the two it is"

mv "$WORK/d-archived-journal" .orchid/runs/r-001/journal.md
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "the refusal lifts the moment the record is readable again — it gates the state, not the plan"
assert_match "UNCOVERED \[ledger\] $probe_id" "$out" "...and the item it could not read comes back"

# ---------------------------------------------------------------------------
# 6b -- NO ARCHIVE AT ALL for the run this one carries from. This is the
# shape that read as a pristine first run: the previous-run question was
# answered by listing `runs/`, so an empty (or absent) `runs/` reported "this
# is the first run of this repository" no matter what run_id said.
# ---------------------------------------------------------------------------
mv .orchid/runs/r-001 "$WORK/d-archive"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 4 "$rc" "a previous run with no archive is refused too"
assert_match "no archive for that run exists" "$out" \
  "...and is distinguished from an archive whose journal is missing: they are different repairs"
grep -qF "no previous run is archived" <<<"$out" \
  && fail "THE FAIL-OPEN AT ITS WORST: run r-002 HAS a previous run whatever .orchid/runs happens to hold, so it must never read as a first run"

rmdir .orchid/runs
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 4 "$rc" "...and so is a repository with no runs/ directory at all, which is the same missing archive one level up"
grep -qF "first run of this repository" <<<"$out" \
  && fail "a run at r-002 is not a first run however little of .orchid/runs survives"
mkdir .orchid/runs
mv "$WORK/d-archive" .orchid/runs/r-001

# ---------------------------------------------------------------------------
# 6c -- THE ROADMAP CANNOT SAY WHICH RUN THIS IS. run_id is what makes the
# previous run nameable; without it there is no question to answer, and
# answering from the archive listing instead is what let 6b pass.
# ---------------------------------------------------------------------------
set_run_id "not-a-run"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 4 "$rc" "a run_id that names no run cannot be silently replaced by whatever is archived"
assert_match "not the r-NNN shape" "$out" "...and the report names the field to repair"
set_run_id "r-002"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 3 "$rc" "...and repairing run_id restores the report"

# ---------------------------------------------------------------------------
# 6d -- THE ARCHIVE AND THE ROADMAP DISAGREE. A rollover archives the OLD run
# id and then increments, so an archive at or above the current run id cannot
# have come from one. Answered by the listing, a roadmap reset to r-001 over
# a repository with archived runs reads as a first run and every finding of
# every previous run leaves planning unconsidered under one green line.
# ---------------------------------------------------------------------------
set_run_id "r-001"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 4 "$rc" "a roadmap that claims to precede its own archive is refused"
assert_match "disagree about how many runs" "$out" "...saying which two records contradict each other"
grep -qF "first run of this repository" <<<"$out" \
  && fail "a repository with an archived run is not on its first run, whatever run_id was reset to"
set_run_id "r-002"

# ---------------------------------------------------------------------------
# 6e -- THE CONTRAST THAT MAKES ALL OF THIS MEAN ANYTHING. The plan below is
# genuinely green: the carried item is covered by a task that names its
# anchor, and the check says so at exit 0. Take the record away and the
# verdict must CHANGE. The whole defect was that these two states printed the
# same thing, so a check that refuses only when it has nothing to lose proves
# nothing at all.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create T010 "teach the crosscheck to tell a missing record from an empty one" >/dev/null
"$ORCHID_BIN" task set T010 acceptance_criteria \
  "prevrun_archive_probe must refuse rather than report an empty ledger when the archived journal is unreadable" >/dev/null
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "the carried item is covered once a task names its anchor"
assert_match "covered   \[ledger\] $probe_id .*via prevrun_archive_probe" "$out" \
  "...and the covering anchor is named back, as every covered line does"

mv .orchid/runs/r-001/journal.md "$WORK/d-archived-journal"
rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 4 "$rc" \
  "THE POINT OF SECTION 6: a green pass and an unreadable record must not print the same verdict — the same plan, one file away, cannot still be a pass"
grep -qF "item(s) considered" <<<"$out" \
  && fail "the plan was considered against a journal that is no longer there to have been read"
mv "$WORK/d-archived-journal" .orchid/runs/r-001/journal.md

rc=0; out="$("$ORCHID_BIN" plan crosscheck 2>&1)" || rc=$?
assert_eq 0 "$rc" "and the pass comes back with the record, unchanged by having been refused"
apply_out="$("$ORCHID_BIN" plan apply --reason "r-002 plan over a readable record" 2>&1)"
assert_match "^applied: " "$apply_out" "plan apply commits once the record can be read and every item is considered"
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" "...and takes the run to running"
