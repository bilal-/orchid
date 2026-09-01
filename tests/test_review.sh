#!/usr/bin/env bash
# v1.1 Task T012 -- REVIEW DEPTH: does `review.<tier>` require a
# worktree-capable reviewer slot?
#
# The decision and both rejected alternatives are recorded in
# docs/specs/kernel.md, "Review depth". This file proves the three things
# that decision actually changed, and -- just as importantly -- the two it
# deliberately did NOT:
#
#   CHANGED   `review_depth_required` (medium/high, fail-safe on unknown);
#             the routing table's fourth DEPTH column; the depth pass that
#             fills slot 2 searching past `review.<tier>` into
#             `role.reviewer`'s chain and the implementer's own engine WHILE
#             THE ROUND STILL NEEDS DEPTH, and no further once slot 1 has
#             already brought it (Part D); and
#             `drive_review_decision` refusing a DETERMINISTIC approval at
#             medium/high when no counted review is credited to a `worktree`
#             slot -- credited off the attempt's PINNED plan and the same
#             slot matching that decides which slot a review fills, never off
#             a manifest read taken at judging time (Part K), and never off
#             live routing when that plan cannot be read at all (Part N).
#
#   UNCHANGED an inline-only install still gets its full complement of
#             slots -- no slot is ever refused, dropped or left unfilled for
#             being inline (Part E's tripwire; lesson L010's "do NOT read
#             this as a reason to drop agy"). And `low` is untouched.
#
# RED/GREEN, on the gate this file exists for -- the depth arm of
# `drive_review_decision`: Part F feeds it a complete, unanimous, scope-
# complete, finding-free medium-tier evidence set whose ONLY defect is that
# every reviewer was inline, and watches the approval be withheld; the GREEN
# twin is the same set with one review re-attributed to a worktree-capable
# engine, which must approve. Without the twin, "withholds approval" would
# be indistinguishable from a policy that approves nothing.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"; source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"; source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
source "$REPO_ROOT/lib/review.sh"; source "$REPO_ROOT/lib/drive.sh"
export ORCHID_ROOT="$REPO_ROOT"
export HOME="$WORK/home"; mkdir -p "$HOME"

# ===========================================================================
# A -- review_depth_required: the tier predicate.
#
# It keys on `risk_tier` and nothing else. That is the whole of the "which
# tasks need depth" question: `risk_tier` medium/high is ALREADY the
# operator's monotonic, --reason-carrying assertion that a task touches
# shared/kernel surface, so the kernel never has to read a task's prose to
# decide (docs/specs/kernel.md, "Review depth", rejected alternative 2).
# ===========================================================================
review_depth_required low && fail "risk_tier low must NOT require depth evidence"
review_depth_required medium || fail "risk_tier medium requires depth evidence"
review_depth_required high || fail "risk_tier high requires depth evidence"
# Fail-safe in the same direction review_required_count and _review_tier_key
# already take: an unrecognized or absent tier asks for MORE review, never
# less. A garbled frontmatter field can only ever route a task to a human.
review_depth_required bogus-tier || fail "an unrecognized risk_tier must require depth (fail-safe)"
review_depth_required "" || fail "an empty risk_tier must require depth (fail-safe)"

# ===========================================================================
# B -- what a routing row CLAIMS, and what a filed review is CREDITED. Both
# against the REAL shipped manifests, because the claim being tested is about
# what a named engine could see: "worktree-capable" means the engine declares
# `workspace_read`, so it can open a file the diff never showed it.
# ===========================================================================
assert_eq inline "$(review_engine_depth agy)" \
  "agy declares structured_text only -- it judges the diff text alone"
assert_eq worktree "$(review_engine_depth codex-review)" \
  "codex-review declares workspace_read -- it can open the checkout"
assert_eq worktree "$(review_engine_depth claude)" "claude declares workspace_read"
assert_eq inline "$(review_engine_depth hermes)" "hermes is the other shipped inline-only reviewer"
assert_eq inline "$(review_engine_depth zqxwv-no-such-engine)" \
  "a name that resolves to nothing reads inline -- depth is a positive claim, never a default"

# That predicate answers what a routing ROW claims. What a filed REVIEW is
# credited is a different question with a different key, and
# `review_plan_depth_count` is the only function that answers it: a plan,
# plus the qualified ids the envelopes carry. Depth comes off the plan's
# fourth column -- never off the engine's manifest as it reads at judging
# time -- so the cases below are the whole of the gate's attribution rule.
depth_row() {  # <engine> <depth> -- a one-slot plan routing <engine>
  printf '1\t%s\tengine-independent\t%s\n' "$1" "$2"
}
assert_eq 1 "$(review_plan_depth_count "$(depth_row codex-review worktree)" orchid/codex-review)" \
  "a review filed by orchid/codex-review against the worktree slot it was routed to IS depth evidence"
assert_eq 0 "$(review_plan_depth_count "$(depth_row agy inline)" orchid/agy)" \
  "a review filed against an inline slot is not"
assert_eq 0 "$(review_plan_depth_count "$(depth_row codex-review worktree)" -)" \
  "an envelope naming NO engine is credited the slot but never its depth -- depth is a positive claim"
assert_eq 0 "$(review_plan_depth_count "$(depth_row codex-review worktree)" orchid/agy)" \
  "and a review from an engine this slot was never routed to is credited neither the slot nor its depth"

# The depth column is read from the PLAN, so a slot pinned `worktree` keeps
# its credit even when the engine that filled it can no longer be resolved
# here at all -- an uninstall between filing and judging is not evidence
# about the review that was already filed. This is the pinned-round rule in
# its smallest form; Part K walks it end to end through the gate.
assert_eq 1 "$(review_plan_depth_count "$(depth_row zqxwv-no-such-engine worktree)" orchid/zqxwv-no-such-engine)" \
  "an engine that has since vanished does not retroactively make its review shallow"
assert_eq 0 "$(review_plan_depth_count "$(depth_row codex-review inline)" orchid/codex-review)" \
  "...and the converse: a slot pinned inline is not upgraded by what its engine's manifest says today"

# ===========================================================================
# C -- the third-party publisher cases. A publisher's manifest id need not
# agree with its plugin DIRECTORY name, and a plan row carries the NAME while
# an envelope carries the ID, so crediting a review means crossing that
# boundary. It is crossed in the safe direction only: the ROW's name -- a
# name this install resolved -- is qualified through its own manifest and
# compared whole. An envelope's `orchid/<anything>` is never stripped back to
# a bare name, so no publisher can name its way onto another's slot.
# ===========================================================================
export ORCHID_ENGINES_DIR="$WORK/engC"; mkdir -p "$ORCHID_ENGINES_DIR"
mk_engine() {  # <dir-name> <manifest-id> <capabilities>
  local d="$ORCHID_ENGINES_DIR/$1"
  mkdir -p "$d"
  printf 'manifest_version=1\nid=%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nrequires_binaries=jq\nentrypoint=run\n' \
    "$2" "$3" > "$d/plugin.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/run"
  chmod +x "$d/run"
}
# A publisher whose directory name and id agree: the ordinary third-party
# case, and it must work exactly like a first-party one.
mk_engine twin acme/twin structured_text,workspace_read
assert_eq 1 "$(review_plan_depth_count "$(depth_row twin worktree)" acme/twin)" \
  "a third-party worktree slot is credited by the manifest id its envelope reports"
# ...and one where dir name and id do NOT agree. The row says `oddname`; the
# envelope says `acme/other`; only the manifest ties them together, and a
# reader that expected `orchid/<row-name>` would credit nothing.
mk_engine oddname acme/other structured_text,workspace_read
assert_eq 1 "$(review_plan_depth_count "$(depth_row oddname worktree)" acme/other)" \
  "a slot whose plugin DIRECTORY name differs from its publisher's id is credited through that manifest, not through the name's shape"
# The inverse trap, and the reason the crossing is one-directional: a dir
# called `other` belonging to someone else must not be able to answer for
# `acme/other`.
mk_engine other someone-else/other structured_text,workspace_read
assert_eq 0 "$(review_plan_depth_count "$(depth_row other worktree)" acme/other)" \
  "an unrelated engine sharing the bare name answers for nobody: the row qualifies to someone-else/other, which acme/other is not"

# ===========================================================================
# D -- routing: the DEPTH PASS SEARCHES PAST review.<tier>.
#
# The r-001 shape (lesson L010). `review.medium`'s chain here is inline-only,
# so a pass that stopped at the tier chain would fill slot 2 with a second
# diff-only reviewer and the tier's whole purpose -- pair an inline reviewer
# with one that can open the file -- would be lost to the order of names in
# one config key. The implementer's own engine can review here, and IS
# worktree-capable, so it takes the slot, labeled session-independent. On
# r-001 that was the slot that caught the defect the inline slot approved.
# ===========================================================================
mk_routing_repo() {  # <dir> <config-lines> <task-id> <risk_tier>
  local repo="$1"
  mkdir -p "$repo/.orchid/tasks"
  printf '%s' "$2" > "$repo/orchid.config"
  printf -- '---\nschema: 1\nid: %s\nstatus: reviewing\nrisk_tier: %s\n---\nbody\n' \
    "$3" "$4" > "$repo/.orchid/tasks/$3.md"
}

mk_engine inlinerev1 test/inlinerev1 structured_text
mk_engine inlinerev2 test/inlinerev2 structured_text
# Shaped like the real claude/codex adapters: it can implement AND review,
# and it can read the workspace.
mk_engine deepimpl test/deepimpl structured_text,workspace_read,workspace_write,shell,git

repoD="$WORK/repoD"
mk_routing_repo "$repoD" \
  'role.implementer=deepimpl
role.reviewer=inlinerev1
review.medium=inlinerev1,inlinerev2
' TD medium
outD="$(review_routing "$repoD" TD)"
assert_eq 2 "$(printf '%s\n' "$outD" | wc -l | tr -d ' ')" "medium tier still routes exactly two slots"
assert_match $'^1\tinlinerev1\tengine-independent\tinline$' "$outD" \
  "slot 1 is unchanged: the engine-independent reviewer, inline"
assert_match $'^2\tdeepimpl\tsession-independent\tworktree$' "$outD" \
  "slot 2 reaches PAST the inline-only tier chain to the worktree-capable implementer engine"
review_routing_has_depth "$outD" || fail "and the table reports that it has depth"

# The same fixture with the tier chain ALREADY holding a worktree-capable
# engine: the tier chain still wins the slot, so widening the search changed
# preference order nowhere it mattered.
mk_engine deeprev test/deeprev structured_text,workspace_read
repoD2="$WORK/repoD2"
mk_routing_repo "$repoD2" \
  'role.implementer=deepimpl
role.reviewer=inlinerev1
review.medium=inlinerev1,deeprev
' TD2 medium
assert_match $'^2\tdeeprev\tengine-independent\tworktree$' "$(review_routing "$repoD2" TD2)" \
  "a worktree-capable engine IN the tier chain still fills slot 2 -- the operator's ordering is not overridden"

# --- ...AND THE WIDENING STOPS WHERE ITS REASON STOPS. Slot 1 here is the
# --- worktree-capable one, so the round ALREADY has depth before slot 2 is
# --- chosen. A widened pass would still reach past the tier chain to the
# --- implementer's own engine and take it -- buying a second copy of a
# --- property the table already carries, and paying for it with the OTHER
# --- axis, since that slot can only be labeled session-independent while an
# --- engine-independent reviewer sat available in `review.<tier>` all along.
# --- Independence and depth are different axes (lesson L010) and medium/high
# --- wants both, so with depth in hand slot 2 is filled the ordinary way.
repoD3="$WORK/repoD3"
mk_routing_repo "$repoD3" \
  'role.implementer=deepimpl
role.reviewer=deeprev
review.medium=deeprev,inlinerev1
' TD3 medium
outD3="$(review_routing "$repoD3" TD3)"
assert_match $'^1\tdeeprev\tengine-independent\tworktree$' "$outD3" \
  "slot 1 brings the depth this time: engine-independent AND worktree-capable"
assert_match $'^2\tinlinerev1\tengine-independent\tinline$' "$outD3" \
  "a round that already has depth keeps its second slot ENGINE-INDEPENDENT rather than spending it on a second worktree-capable reviewer"
grep -q deepimpl <<< "$outD3" \
  && fail "the depth pass must not reach the implementer's own engine once slot 1 is already worktree-capable (got: $outD3)"
review_routing_has_depth "$outD3" \
  || fail "...and the round still HAS depth -- that is the whole reason slot 2 no longer has to buy it"

# --- The widened list is DEMOTED, not deleted. Same shape, except the tier
# --- chain has nobody left to offer: reaching past it then costs no
# --- independence at all, because the alternative is slot 1 reviewing its own
# --- candidate twice.
repoD4="$WORK/repoD4"
mk_routing_repo "$repoD4" \
  'role.implementer=deepimpl
role.reviewer=deeprev
review.medium=deeprev
' TD4 medium
outD4="$(review_routing "$repoD4" TD4)"
assert_match $'^1\tdeeprev\tengine-independent\tworktree$' "$outD4" "slot 1 is the same deep, independent reviewer"
assert_match $'^2\tdeepimpl\tsession-independent\tworktree$' "$outD4" \
  "with the tier chain exhausted the widened list is still walked -- a DISTINCT engine, honestly labeled, beats repeating slot 1"

# ===========================================================================
# E -- THE TRIPWIRE. An install with no worktree-capable reviewer anywhere
# must still be routed its full complement of slots.
#
# This is the rejected alternative, asserted as behaviour rather than as
# prose: requiring depth at the ROUTING end would leave an inline-only
# install unable to review a medium task at all, which converts a depth
# shortfall into an availability failure and gives the operator no way
# forward but to downgrade a monotonic risk_tier. Depth is judged over the
# EVIDENCE (Part F), never by withholding a slot.
# ===========================================================================
repoE="$WORK/repoE"
mk_routing_repo "$repoE" \
  'role.implementer=inlineimpl
role.reviewer=inlinerev1
review.medium=inlinerev1,inlinerev2
' TE medium
# An implementer shaped like the real stub implementers: it can write a
# workspace but cannot produce structured review output, so it is not
# reviewer-eligible and cannot be pressed into the depth slot.
mk_engine inlineimpl test/inlineimpl workspace_write,shell,git
outE="$(review_routing "$repoE" TE)"
assert_eq 2 "$(printf '%s\n' "$outE" | wc -l | tr -d ' ')" \
  "an inline-only install is still routed BOTH slots -- routing never refuses over depth"
assert_match $'^1\tinlinerev1\tengine-independent\tinline$' "$outE" "slot 1 is filled"
assert_match $'^2\tinlinerev2\tengine-independent\tinline$' "$outE" \
  "slot 2 is filled from the tier chain, and both slots are honestly labeled inline"
review_routing_has_depth "$outE" \
  && fail "...and the table says so: this install has no depth to offer"

# review_routing_has_depth reads the fourth field and only the fourth.
review_routing_has_depth "$(printf '1\tagy\tengine-independent\tinline\n2\tclaude\tsession-independent\tworktree\n')" \
  || fail "a table with one worktree slot has depth"
review_routing_has_depth "$(printf '1\tworktree\tengine-independent\tinline\n')" \
  && fail "an ENGINE named worktree in column 2 is not a depth claim"

# runners/orchid-drive journals an all-inline table before dispatching, by the
# same rule the session-independent label follows. Both predicates it combines
# to decide that are proven directly above, on the same table shape the driver
# reads; the one-line `journal add` call that follows them is not exercised
# here, because reaching that arm needs a full stub-engine drive fixture with
# a medium-tier task in `reviewing` and no outstanding reviewer job.
not_tested "the driver's journal line for an all-inline routing table" \
  "predicates covered above; the journal call itself needs an end-to-end drive fixture (tests/test_drive.sh's SLOTS repo never reaches the dispatch arm)"
unset ORCHID_ENGINES_DIR

# ===========================================================================
# F -- the gate itself: drive_review_decision's depth arm.
#
# Everything below uses the REAL shipped manifests for attribution, because
# the whole claim being tested is about what a named engine could see.
# ===========================================================================
POLICY="$WORK/policy"; mkdir -p "$POLICY/.orchid/tasks" "$POLICY/.orchid/reviews"
PCAND=4444444444444444444444444444444444444444

mk_task() {  # <id> <risk_tier> <blocking_severity>
  printf -- '---\nschema: 1\nid: %s\nstatus: arbitrating\narchetype: feature\nattempts: 0\nrisk_tier: %s\nblocking_severity: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$1" "$2" "$3" "$PCAND" > "$POLICY/.orchid/tasks/$1.md"
}
mk_review_by() {  # <id> <suffix> <verdict> <engine-qualified-id>
  jq -n --arg jid "j-depth-$1$2" --arg task "$1" --arg cand "$PCAND" \
        --arg v "$3" --arg e "$4" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:$v, scope_complete:true, summary:"depth fixture",
      candidate_sha:$cand, findings:[], engine:$e}' \
    > "$POLICY/.orchid/reviews/$1-a1-reviewer$2.json"
}
decision_of() { drive_review_decision "$POLICY" "$1" | cut -f1; }
detail_of()   { drive_review_decision "$POLICY" "$1" | cut -f2- ; }

# mk_pin <id> <slot1-engine> <slot1-depth> <slot2-engine> <slot2-depth> -- the
# plan this attempt was dispatched under, written straight to the file rather
# than through `review_plan_store`, deliberately in the LEGACY shape: slots
# with a depth but no frozen attribution key, so every case that uses it
# exercises the live-resolution fallback a plan pinned before that column
# reads through. Part L is the current shape, and the difference between them
# is the whole of its RED case.
#
# Defined HERE, in the first Part that needs one, because depth is credited
# from the pinned round: a medium/high case with no pin is judged on the
# missing plan (Part N) rather than on the reviews it filed, so a fixture that
# means to test the depth arm has to say which round it was dispatched under.
mk_pin() {
  jq -n --arg cand "$PCAND" --arg e1 "$2" --arg d1 "$3" --arg e2 "$4" --arg d2 "$5" \
    '{contract:1, attempt:1, candidate_sha:$cand, pinned_at:"2026-02-01T00:00:00Z",
      slots:[{slot:1, engine:$e1, label:"engine-independent", depth:$d1},
             {slot:2, engine:$e2, label:"engine-independent", depth:$d2}]}' \
    > "$POLICY/.orchid/reviews/$1-a1.review-plan.json"
}

# --- RED: a complete, unanimous, finding-free medium-tier set, dispatched
# --- under a plan whose every slot is inline, and filled by exactly those
# --- engines. This is r-001's T003 exactly.
mk_task D01 medium high
mk_pin D01 agy inline hermes inline
mk_review_by D01 "" approve orchid/agy
mk_review_by D01 ".2" approve orchid/hermes
assert_eq evidence "$(decision_of D01)" \
  "two inline approvals do not deterministically approve a medium-tier task"
assert_match "unproven review depth: 2 of 2" "$(detail_of D01)" \
  "the detail concedes the COUNT was met and names the axis that was not"
assert_match "cannot open the files" "$(detail_of D01)" \
  "...and says what an inline reviewer could not do, so the operator knows what to check"
red_case 'a complete unanimous medium-tier review set with no worktree-capable reviewer is refused deterministic approval'

# --- GREEN: the same round with its second slot dispatched to a
# --- worktree-capable engine, and that slot's review filed by it. The
# --- evidence set is otherwise identical -- same count, same verdicts, same
# --- complete scope, same empty findings -- and the plan says so, because
# --- depth is a claim about the round, not about the envelope.
mk_pin D01 agy inline codex-review worktree
mk_review_by D01 ".2" approve orchid/codex-review
assert_eq approve "$(decision_of D01)" \
  "one worktree-capable approval alongside the inline one satisfies the depth axis"
assert_match "1 of them worktree-capable" "$(detail_of D01)" \
  "and the approval detail records the depth it rested on, not just the count"
green_case 'the same set approves once one review comes from a worktree-capable engine'

# The pairing is what the tier asks for, so the pair is enough: the inline
# review is never discarded, it is just no longer sufficient alone.
assert_match "unanimous scope-complete approval from 2 review" "$(detail_of D01)" \
  "both reviews still count toward the approval -- an inline review is a real review"

# --- low tier is untouched, pin or no pin. It asks for no depth, so there is
# --- no claim for a plan to support and nothing for a missing one to withdraw
# --- -- and the detail says plainly that the approval rested on none.
mk_task D02 low high
mk_review_by D02 "" approve orchid/agy
assert_eq approve "$(decision_of D02)" \
  "risk_tier low requires no depth: one inline approval still approves, exactly as before"
assert_match "0 of them worktree-capable" "$(detail_of D02)" \
  "...and with no pinned round to credit, the approval claims no depth rather than inventing one from live routing"

# --- an envelope naming NO engine cannot support a depth claim, and the
# --- shortfall is reported the same way (tests/test_drive.sh's P11 covers
# --- the two-unattributable-reviews case end to end).
mk_task D03 medium high
mk_pin D03 codex-review worktree agy inline
mk_review_by D03 "" approve orchid/codex-review
jq -n --arg cand "$PCAND" \
  '{contract:1, job_id:"j-depth-D03-anon", task:"D03", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"no engine field",
    candidate_sha:$cand, findings:[]}' \
  > "$POLICY/.orchid/reviews/D03-a1-reviewer.2.json"
assert_eq approve "$(decision_of D03)" \
  "an unattributable review alongside a worktree-capable one is still a complete, depth-proven set"
assert_match "1 of them worktree-capable" "$(detail_of D03)" \
  "only the attributable worktree-capable review is counted as depth"

# --- ORDERING: a conflict outranks a depth shortfall. When a review already
# --- says something is wrong, THAT is what the operator is handed; renaming
# --- it a depth problem would bury the finding.
mk_task D04 medium high
mk_review_by D04 "" approve orchid/agy
mk_review_by D04 ".2" request-changes orchid/hermes
assert_eq conflict "$(decision_of D04)" \
  "a request-changes verdict is reported as a conflict even though the set also lacks depth"
assert_match "verdict=request-changes" "$(detail_of D04)" "and the detail names the verdict, not the depth"

# --- ORDERING, the other side: an INCOMPLETE set is a count shortfall, not a
# --- depth one. Reporting depth first would tell an operator to find a
# --- deeper reviewer when what is missing is a review.
mk_task D05 medium high
mk_review_by D05 "" approve orchid/agy
assert_eq evidence "$(decision_of D05)" "one review where the tier wants two is still incomplete"
assert_match "incomplete review evidence: 1 of 2" "$(detail_of D05)" \
  "the count shortfall is reported ahead of the depth one"

# ===========================================================================
# G -- the depth boundary must be SETTLEABLE, or the policy above would park
# a task nothing can release.
#
# `drive_review_decision` returns `evidence`, and runners/orchid-drive raises
# that as a `review-evidence` boundary while the task is `arbitrating` --
# which is precisely where `orchid task arbitrate` runs. So an inline-only
# install is never stuck: the decision is handed to an arbiter who reads the
# diff, which is the r-001 path that caught the defect in the first place.
# ===========================================================================
assert_eq 1 "$(drive_boundary_priority review-evidence arbitrating brokered)" \
  "a depth shortfall lands on a boundary a woken orchestrator can actually settle"
drive_boundary_wakes_orchestrator review-evidence arbitrating brokered \
  || fail "...and it really does wake one, rather than waiting on a human forever"

# ===========================================================================
# H -- the ROW GRAMMAR, and the widening tripwire.
#
# runners/orchid-drive dispatches off `orchid jobs review-plan --pin`'s
# stdout and validates every line before it will treat one as a slot: stderr
# is merged into that read, so a jq diagnostic must never become a reviewer.
# That validator used to be a private copy inside `drive_reviewing` which
# pinned the row at THREE fields and rejected any fourth -- so the moment this
# task appended the depth column, every row of a perfectly good pin read as a
# diagnostic, the routing table came back empty, and the driver raised
# "review-plan pin failed" instead of dispatching, at EVERY tier. Nothing
# caught it: the routing tests read the verb's stdout directly and never go
# through the driver's parse.
#
# So the rule now lives in lib/review.sh next to the printf that decides the
# shape, and the first assertions below are anchored on `review_routing`'s
# ACTUAL output rather than on a literal row. An unknown column fails here, on
# the emitter's own bytes, instead of silently in production.
#
# The grammar admits TWO widths, and both are asserted: four columns for a live
# routing table, five for a PINNED row, whose last column is the qualified
# engine id frozen at the write (Part L). That is the whole of the widening --
# a sixth column is still refused.
# ===========================================================================
while IFS= read -r row; do
  [ -n "$row" ] || continue
  review_plan_row_valid "$row" \
    || fail "the driver's row validator rejects a row review_routing itself emitted: '$row'"
done <<< "$outD"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  review_plan_row_valid "$row" \
    || fail "the driver's row validator rejects an inline-only routing row: '$row'"
done <<< "$outE"

review_plan_row_valid "$(printf '1\tagy\tengine-independent\tinline')" \
  || fail "the canonical four-column row -- a LIVE routing table, which has no key to freeze -- is a dispatchable slot"
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tinline\torchid/agy')" \
  || fail "and so is a PINNED five-column row: the driver dispatches off exactly what --pin prints"
review_plan_row_valid "$(printf '1\tagy\tengine-independent')" \
  && fail "a three-column row is NOT dispatchable -- depth is never defaulted in at the reading end"
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tinline\torchid/agy\tseventh')" \
  && fail "a sixth column is refused rather than ignored: a reader must not dispatch a grammar it does not know"
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tdeep')" \
  && fail "an unrecognized depth label is refused"
review_plan_row_valid "$(printf 'slot-one\tagy\tengine-independent\tinline')" \
  && fail "a non-numeric slot is refused"
review_plan_row_valid "$(printf '1\t\tengine-independent\tinline')" \
  && fail "a row naming no engine is refused"
# ...and it is the EMPTY-ENGINE GUARD that refuses it, which for a long time
# nothing reached. The validator used to split with `IFS=$'\t' read`, and tab
# is IFS WHITESPACE: a run of tabs collapses into ONE delimiter, so the empty
# column above vanished and every field shifted one place left --
# `engine-independent` landed in the engine column, `inline` in the label
# column, and the DEPTH check fired. The assertion above was therefore true
# about its INPUT and no assertion at all about the guard it names, which is
# exactly the shape this suite exists to keep out of itself. Splitting on
# every tab is what makes the field count exact.
#
# The same collapse hid a worse one, in the direction that ADMITS a row: an
# empty fifth column followed by a sixth read as a five-column pinned row
# whose attribution key was the SIXTH field. A dispatcher that fails closed on
# an unknown grammar cannot be handed one wearing a known grammar's clothes.
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tinline\t\tsixth')" \
  && fail "an EMPTY fifth column must not let a sixth field masquerade as the frozen attribution key"
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tinline\t')" \
  && fail "...and an empty key on its own is refused too: no envelope reports an empty engine id, so such a row could only ever match through the live resolution the pin exists to stop"
review_plan_row_valid '1' \
  && fail "a row that is nothing but a slot number carries no column past it -- no engine, no label, no depth -- and is refused"
review_plan_row_valid "$(printf '1\tagy')" \
  && fail "...and a row truncated after its engine claims no independence label, so it is refused too"
review_plan_row_valid "$(printf '1\tagy\tprobably-independent\tinline')" \
  && fail "an unrecognized independence label is refused"
review_plan_row_valid 'jq: error: null (null) has no keys' \
  && fail "a diagnostic merged in from stderr is never read as a reviewer slot"

# ===========================================================================
# I -- ROUTING NEVER QUEUES, AND `high` IS NOT A THIRD POLICY.
#
# Part E proved an inline-only install is still routed both slots at
# `medium`. `high` has to behave identically, and that is worth its own
# assertion rather than being left implied: "refuse to route, or refuse to
# dispatch, without a worktree-capable engine" is precisely the alternative
# docs/specs/kernel.md records as REJECTED, and it is also the behaviour
# README.md and docs/architecture.md used to attribute to `high` in the very
# paragraphs this decision governs ("`high` instead queues, waiting for a
# genuinely engine-independent reviewer to become available"). No such
# branch has ever existed: review_routing, review_required_count and
# libexec/orchid-task's reviewing -> arbitrating gate all read `medium` and
# `high` through the same arm. Part J holds the docs to that, and this Part
# is what makes Part J falsifiable rather than prose agreeing with prose.
# ===========================================================================
export ORCHID_ENGINES_DIR="$WORK/engC"   # Parts C/D/E's fixture engines
repoI="$WORK/repoI"
mk_routing_repo "$repoI" \
  'role.implementer=inlineimpl
role.reviewer=inlinerev1
review.high=inlinerev1,inlinerev2
' TI high
outI="$(review_routing "$repoI" TI)"
assert_eq 2 "$(printf '%s\n' "$outI" | wc -l | tr -d ' ')" \
  "high tier routes BOTH slots on an inline-only install -- it never queues for a reviewer nobody installed"
assert_match $'^1\tinlinerev1\tengine-independent\tinline$' "$outI" \
  "high: slot 1 is filled, and honestly labeled inline"
assert_match $'^2\tinlinerev2\tengine-independent\tinline$' "$outI" \
  "high: slot 2 is filled too, from the tier chain, exactly as medium fills it"
assert_eq "$(review_required_count medium)" "$(review_required_count high)" \
  "high and medium ask for the same NUMBER of reviews"
review_depth_required high \
  || fail "...and for the same depth -- high is medium's policy, not a stricter routing rule"
unset ORCHID_ENGINES_DIR

# ===========================================================================
# J -- and the operator-facing docs must not re-assert the guarantee Part I
# just refuted.
#
# Folded to one line before either check: both claims straddled a hard wrap
# in their source files, so a scan of the raw lines would have missed them
# and this tripwire would have passed with the claim still sitting there --
# the same reason tests/test_docs.sh folds PROTOCOL.md before asserting on
# it.
#
# TWO-WAY on purpose. A bare "must not say X" is satisfied by deleting the
# whole paragraph, which would take the labeled-fallback guarantee (which is
# real, and load-bearing) down with the queueing claim (which never was). So
# each file is also held to stating what the kernel actually does.
#
# docs/specs/kernel.md is held to the SAME rule, and it is the one that
# matters most: it is the NORMATIVE file, and it is where this task records
# the routing-end refusal as a rejected alternative. A spec asserting the
# queueing branch in its Independence paragraph and rejecting it sixteen
# lines later in "Review depth" contradicts itself, and a reader has no way
# to tell which half is current. Scanning only the two narrative files would
# have left exactly that.
# ===========================================================================
readme_folded="$(tr '\n' ' ' < "$REPO_ROOT/README.md" | tr -s '[:space:]' ' ')"
arch_folded="$(tr '\n' ' ' < "$REPO_ROOT/docs/architecture.md" | tr -s '[:space:]' ' ')"
kernel_folded="$(tr '\n' ' ' < "$REPO_ROOT/docs/specs/kernel.md" | tr -s '[:space:]' ' ')"
queue_claim='`?high`?( risk)? (instead )?queues'

grep -Eq "$queue_claim" <<< "$readme_folded" \
  && fail "README.md says high-risk review QUEUES for a better reviewer; no such branch exists (Part I), and refusing at the routing end is the alternative docs/specs/kernel.md records as rejected"
grep -Eq "$queue_claim" <<< "$arch_folded" \
  && fail "docs/architecture.md says high-risk review QUEUES for a better reviewer; no such branch exists (Part I), and refusing at the routing end is the alternative docs/specs/kernel.md records as rejected"
grep -Eq "$queue_claim" <<< "$kernel_folded" \
  && fail "docs/specs/kernel.md's Independence paragraph still says high queues for engine independence -- the normative spec cannot assert the branch its own 'Review depth' section records as REJECTED"

grep -Fq 'both accept a labeled session-independent fallback' <<< "$readme_folded" \
  || fail "README.md must still describe the labeled session-independent fallback both tiers really take -- the queueing claim is to be CORRECTED, not deleted along with the guarantee that replaces it"
grep -Fq 'Routing never withholds a slot' <<< "$arch_folded" \
  || fail "docs/architecture.md must state that routing fills and labels a slot rather than withholding it, or the diagram's degraded-independence branch has nothing behind it"
grep -Fq 'accept labeled session independence rather than withhold a slot' <<< "$kernel_folded" \
  || fail "docs/specs/kernel.md must state what BOTH tiers really do with degraded independence -- deleting the sentence would drop the labeled-fallback guarantee along with the queueing claim"

# ===========================================================================
# K -- DEPTH IS ATTRIBUTED FROM THE PINNED ROUND, not from a manifest read
# taken at judging time.
#
# This is the same defect T039 fixed for routing, in the other column. That
# task pinned the plan because live routing MOVED UNDER FILED EVIDENCE: an
# engine went `failing` on unrelated work, its slot re-routed, and the review
# it had already filed became attributable to no slot at all -- leaving a task
# whose evidence was complete with no legal exit. Reading the DEPTH claim off
# the installed manifests at arbitration time left exactly that hole open one
# column to the right: uninstall a plugin, rebind a name, or edit one
# `capabilities=` line between filing and judging, and a filed review's depth
# is silently withdrawn. Nothing about the review changed.
#
# So the credit follows the pin, through the same slot matching that decides
# which slot a review COVERS. Both directions are asserted below, because only
# the pair distinguishes "reads the pin" from "reads nothing".
# ===========================================================================
# `mk_pin` (Part F) writes the LEGACY pin shape -- a depth column but no frozen
# attribution key -- so every case in this Part exercises the live-resolution
# fallback a plan pinned before that column reads through. Part L is the
# current shape, and the difference between them is the whole of its RED case.

# --- RED: the round was dispatched to a worktree-capable engine, and that
# --- engine is GONE by the time the reviews are judged. Nothing here can
# --- resolve it, so no manifest read can support its depth.
mk_task K01 medium high
mk_review_by K01 "" approve orchid/ghostrev
mk_review_by K01 ".2" approve orchid/agy
assert_eq inline "$(review_engine_depth ghostrev)" \
  "premise: ghostrev resolves to no installed engine, so a live capability read can prove nothing about it"
assert_eq evidence "$(decision_of K01)" \
  "with no pin, the depth claim has nowhere to come from and the set is unproven"
assert_match 'no usable pinned review plan \(missing\)' "$(detail_of K01)" \
  "...and the detail says the round itself is unrecorded, rather than blaming reviews that did exactly what they were asked (Part N)"
red_case 'a review filed by a worktree-capable engine that has since been uninstalled is credited no depth while the round it was dispatched under is unrecorded'

# --- GREEN: the plan that dispatched it, pinned to this attempt and this
# --- candidate, says slot 1 was `worktree`. Nothing else changes -- same
# --- envelopes, same engines installed, same manifests.
mk_pin K01 ghostrev worktree agy inline
assert_eq approve "$(decision_of K01)" \
  "the pinned round credits its own slot: an uninstall after the fact is not evidence about the review that was already filed"
assert_match "1 of them worktree-capable" "$(detail_of K01)" \
  "and the approval says which axis it rested on"
green_case 'the pinned plan credits that review its depth, so a plugin uninstalled after filing cannot withdraw a deterministic approval'

# --- The converse, and the fail-closed half: a slot pinned `inline` is NOT
# --- upgraded by what its engine's manifest happens to say today. Depth is
# --- what the reviewer we dispatched could see, and only the round knows it.
mk_task K02 medium high
mk_review_by K02 "" approve orchid/codex-review
mk_review_by K02 ".2" approve orchid/agy
mk_pin K02 codex-review inline agy inline
assert_eq worktree "$(review_engine_depth codex-review)" \
  "premise: codex-review is worktree-capable TODAY, so a live read would credit this set"
assert_eq evidence "$(decision_of K02)" \
  "but the round it was dispatched under pinned that slot inline, and the pin is what counts"
assert_match "unproven review depth: 2 of 2" "$(detail_of K02)" \
  "and the shortfall is reported as evidence, settleable by an arbiter, never as a refusal"

# --- A review from an engine the plan never routed to is credited NO depth --
# --- for exactly the same reason it satisfies no slot. The two answers come
# --- out of one matching, so they cannot drift apart; `--adopt-evidence` is
# --- the recorded verb that re-pins a plan onto the engines that reviewed.
mk_task K03 medium high
mk_review_by K03 "" approve orchid/agy
mk_review_by K03 ".2" approve orchid/codex-review
mk_pin K03 agy inline hermes inline
assert_eq evidence "$(decision_of K03)" \
  "a worktree-capable review nobody asked for does not silently satisfy a slot's depth"
assert_eq 2 "$(review_plan_unsatisfied "$POLICY" K03 "$(review_plan "$POLICY" K03)" | cut -f1)" \
  "...and the SAME matching still reports slot 2 unfilled: depth credit and slot credit never disagree about one envelope"

# --- Malformed pin rows are refused, not parsed loosely. `review_plan_pinned`
# --- can only emit five-column rows, so this is the library's own contract
# --- rather than a shape a pin file can reach -- and it is the contract that
# --- keeps a sixth column, or a diagnostic, from ever reading as depth.
assert_eq 0 "$(review_plan_depth_count "$(printf '1\tagy\tengine-independent\tworktree\torchid/agy\tseventh\n')" orchid/agy)" \
  "a row carrying an unknown sixth column is not a slot, so it is not a worktree slot either"
assert_eq 0 "$(review_plan_depth_count "$(printf '1\tagy\tengine-independent\n')" orchid/agy)" \
  "a three-column row claims no depth, and none is defaulted in at the reading end"
assert_eq 0 "$(review_plan_depth_count 'jq: error: null (null) has no keys' orchid/agy)" \
  "a diagnostic merged in from stderr credits nothing"

# ===========================================================================
# L -- AND SO IS THE KEY THE EVIDENCE IS MATCHED BY.
#
# Part K froze the DEPTH claim. A plan that froze only that, beside a bare
# route NAME, still had to ask the live plugin registry what the name meant
# before it could recognize its own envelope -- because a routing row names an
# engine the way config does (`oddname`) while an envelope names it the way its
# manifest does (`acme/other`), and only the registry ties the two together.
# So uninstalling that plugin, or rebinding the name to another publisher's
# engine, made a filed review stop matching the slot it was dispatched to: it
# lost its COVERAGE and, with it, its depth. Same defect as T039's and Part
# K's, one join to the left.
#
# The pin therefore records the name and the qualified id together, at the
# write, and the matching compares against what the row carries. Every
# assertion below is the same round of evidence, unchanged, judged across a
# registry that moves underneath it.
# ===========================================================================
export ORCHID_ENGINES_DIR="$WORK/engL"; mkdir -p "$ORCHID_ENGINES_DIR"
# A publisher whose plugin DIRECTORY name and manifest id disagree -- the case
# no name-shape convention can paper over (Part C).
mk_engine oddname acme/other structured_text,workspace_read
LPIN="$POLICY/.orchid/reviews/L01-a1.review-plan.json"
mk_task L01 medium high
mk_review_by L01 "" approve acme/other
mk_review_by L01 ".2" approve orchid/agy

# The WRITE is where the key is frozen, because the write is when the round is
# dispatched. `review_plan_store` is the only writer, so a pin can never be
# landed without one.
review_plan_store "$POLICY" L01 \
  "$(printf '1\toddname\tengine-independent\tworktree\n2\tagy\tengine-independent\tinline\n')" \
  || fail "review_plan_store must land a plan for a task with a candidate"
assert_eq acme/other "$(jq -r '.slots[0].qid' "$LPIN")" \
  "the pin records the qualified id the slot's engine resolved to, not just the name it was routed by"
assert_eq orchid/agy "$(jq -r '.slots[1].qid' "$LPIN")" \
  "...for every slot, first-party ones included"
assert_eq approve "$(decision_of L01)" \
  "premise: with both engines installed this round is a complete, depth-proven set"

# A pin written before the key existed is still readable, is reported as not
# current, and one writing pass migrates it -- the same bounded, one-time
# derivation the depth column gets. It can only derive from what is installed
# NOW, which is why it is a migration and not a repair: an engine already gone
# by the time this runs is what `--repin`/`--adopt-evidence` are for.
cp "$LPIN" "$WORK/L01-keyed.json"
jq 'del(.slots[].qid)' "$WORK/L01-keyed.json" > "$LPIN"
review_plan_columns_persisted "$POLICY" L01 \
  && fail "a pin carrying no attribution key must not read as current, or the migrating write never happens"
assert_match $'^1\toddname\tengine-independent\tworktree\tacme/other$' "$(review_plan_pinned "$POLICY" L01)" \
  "a legacy pin still reads, with the key derived once from the engine it named"
review_plan_store "$POLICY" L01 "$(review_plan_pinned "$POLICY" L01)" \
  || fail "the migrating write must land"
review_plan_columns_persisted "$POLICY" L01 \
  || fail "...and after it the pin is current"
assert_eq acme/other "$(jq -r '.slots[0].qid' "$LPIN")" \
  "the migration persists the derived key rather than re-deriving it on every later read"

# --- RED: the plugin is UNINSTALLED between filing and judging, and the plan
# --- froze only its name. Nothing about the review changed.
unset ORCHID_ENGINES_DIR
assert_eq orchid/oddname "$(review_engine_qid oddname)" \
  "premise: with the plugin gone the row's name resolves to the fallback id, which is not the acme/other its own envelope reports"
jq 'del(.slots[].qid)' "$WORK/L01-keyed.json" > "$LPIN"
assert_eq evidence "$(decision_of L01)" \
  "a name-only plan cannot recognize its own filed review once the name stops resolving"
assert_eq 1 "$(review_plan_unsatisfied "$POLICY" L01 "$(review_plan "$POLICY" L01)" | cut -f1)" \
  "...and it is the whole slot that is lost, not just its depth: the driver would re-dispatch a slot that was already reviewed"
red_case 'a review plan freezing only the bare route name withdraws a completed review when its plugin is uninstalled'

# --- GREEN: the same round, the same envelopes, the same uninstalled plugin --
# --- with the key the pin froze at the write.
cp "$WORK/L01-keyed.json" "$LPIN"
assert_eq approve "$(decision_of L01)" \
  "the frozen key recognizes the envelope the slot was dispatched to, so an uninstall withdraws nothing"
assert_match "1 of them worktree-capable" "$(detail_of L01)" \
  "and the approval still rests on the depth that round really had"
assert_eq "" "$(review_plan_unsatisfied "$POLICY" L01 "$(review_plan "$POLICY" L01)")" \
  "...off the same matching, so coverage and depth agree about the envelope as they must"
green_case 'the pinned qualified id keeps crediting that review after the engine is uninstalled'

# --- A REBIND is the sharper half, and it cuts both ways. The name resolves
# --- again, to someone else entirely.
export ORCHID_ENGINES_DIR="$WORK/engL2"; mkdir -p "$ORCHID_ENGINES_DIR"
mk_engine oddname someone-else/other structured_text,workspace_read
assert_eq someone-else/other "$(review_engine_qid oddname)" \
  "premise: the row's name now resolves to a different publisher's engine"
assert_eq approve "$(decision_of L01)" \
  "the review that was actually dispatched and filed keeps its slot: a later rebind is not evidence about it"
assert_eq 0 "$(review_plan_depth_count "$(printf '1\toddname\tengine-independent\tworktree\tacme/other')" someone-else/other)" \
  "and the fail-closed converse: whoever holds the name today cannot inherit the slot -- the key names the engine that was asked"
unset ORCHID_ENGINES_DIR

# ===========================================================================
# M -- `--adopt-evidence` PINS WHAT IT ADOPTED, AND LEAVES ALONE WHAT IT DID
# NOT.
#
# Parts K and L froze both columns at the `--pin` write. This Part is the
# OTHER writer. `--adopt-evidence` is the recorded exit for a plan that no
# longer fits its evidence, so a live read taken here lands at the one moment
# an operator is trying to leave that dead end -- and writes its answer down
# durably rather than merely computing it. Two rules, one per direction:
#
#   THE SLOTS IT MOVES take the qualified id the ADOPTED ENVELOPE reported.
#   Deciding that by comparing the adopted engine's short NAME against the row
#   it replaces cannot see a REBIND, because the name is identical on both
#   sides: the row keeps the id of the publisher who used to hold that name,
#   matches no envelope at all, and the task stays wedged in exactly the state
#   the verb was run to clear -- now with a fresh journal entry saying it was
#   repaired.
#
#   THE SLOTS IT DOES NOT MOVE keep their frozen columns. A slot covered by an
#   anonymous envelope has nothing of its own to adopt and is retained as it
#   stands, so re-deriving its depth from the installed manifests here would
#   let an edit to one `capabilities=` line, made long after that round was
#   dispatched, be written into the pin by the very verb repairing it.
# ===========================================================================
export ORCHID_ENGINES_DIR="$WORK/engM"; mkdir -p "$ORCHID_ENGINES_DIR"
repoM="$WORK/repoM"; mkdir -p "$repoM/.orchid/tasks" "$repoM/.orchid/reviews"
MCAND=5555555555555555555555555555555555555555
# `review.medium` names oddname explicitly: a qualified id whose publisher
# prefix cannot be stripped and round-tripped back to a bound name is mapped
# by walking the chains this task could have been routed to, and that walk is
# the path the rebind case below exercises.
printf 'role.implementer=deepimpl2
role.reviewer=plainrev
review.medium=oddname,plainrev,deeprev
' > "$repoM/orchid.config"

mk_m_task() {  # <id> -- a medium-tier task on attempt 1 with a candidate
  printf -- '---\nschema: 1\nid: %s\nstatus: arbitrating\narchetype: feature\nattempts: 0\nrisk_tier: medium\nblocking_severity: high\ncandidate_sha: %s\n---\nbody\n' \
    "$1" "$MCAND" > "$repoM/.orchid/tasks/$1.md"
}
mk_m_review() {  # <id> <suffix> <qualified-engine-id|->
  jq -n --arg jid "j-adopt-$1$2" --arg task "$1" --arg cand "$MCAND" --arg e "$3" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:"approve", scope_complete:true, summary:"adoption fixture",
      candidate_sha:$cand, findings:[]}
     + (if $e == "-" then {} else {engine:$e} end)' \
    > "$repoM/.orchid/reviews/$1-a1-reviewer$2.json"
}
mk_engine deepimpl2 test/deepimpl2 structured_text,workspace_read,workspace_write,shell,git
mk_engine plainrev  test/plainrev  structured_text

# --- M1, THE REBIND. The plan was pinned while `oddname` was acme/other's.
# --- By the time the operator reaches for the remedy the name belongs to a
# --- different publisher, and the review on disk was filed by the new holder.
mk_engine oddname acme/other structured_text,workspace_read
mk_m_task M01
review_plan_store "$repoM" M01 \
  "$(printf '1\toddname\tengine-independent\tworktree\n2\tplainrev\tengine-independent\tinline\n')" \
  || fail "fixture: M01's plan must pin"
assert_eq acme/other "$(jq -r '.slots[0].qid' "$repoM/.orchid/reviews/M01-a1.review-plan.json")" \
  "fixture: the round was pinned while oddname resolved to acme/other"

mk_engine oddname someone-else/other structured_text,workspace_read
assert_eq someone-else/other "$(review_engine_qid oddname)" \
  "premise: the SHORT NAME did not move -- only the publisher behind it did, which is precisely what a name comparison cannot see"
mk_m_review M01 "" someone-else/other
mk_m_review M01 ".2" test/plainrev
assert_eq 1 "$(review_plan_unsatisfied "$repoM" M01 "$(review_plan "$repoM" M01)" | cut -f1)" \
  "premise: slot 1's pinned key matches no filed envelope, so the task is wedged and --adopt-evidence is its recorded exit"
red_case 'a rebind of the engine name a slot was pinned to leaves the review that slot dispatched matching no slot at all'

adoptM="$(review_plan_adopt_evidence_rows "$repoM" M01)" \
  || fail "--adopt-evidence must accept a round whose envelopes name as many distinct installed engines as the plan routes"
assert_eq "$(printf '1\toddname\tengine-independent\tworktree\tsomeone-else/other\n2\tplainrev\tengine-independent\tinline\ttest/plainrev')" \
  "$adoptM" \
  "the adopted slot is pinned to the id its OWN envelope reported, never to the id the row carried before the rebind"
review_plan_store "$repoM" M01 "$adoptM" || fail "the adopted table must land"
assert_eq "" "$(review_plan_unsatisfied "$repoM" M01 "$(review_plan "$repoM" M01)")" \
  "and the wedge is gone: both slots are now credited by evidence already on disk"
green_case 'adopting that evidence re-pins the slot onto the qualified id the filed envelope reported, which clears the wedge'

# --- M2, THE SLOT IT DOES NOT MOVE. A degraded plan -- one engine, two slots,
# --- which is what an install with too few engines is routed -- covered by one
# --- attributable review and one envelope that names no engine. The anonymous
# --- one is creditable to any slot, so slot 2 has nothing of its own to adopt.
mk_engine deeprev test/deeprev structured_text,workspace_read
assert_eq worktree "$(review_engine_depth deeprev)" \
  "fixture: deeprev really is worktree-capable at the moment its round is pinned, so the pinned claim is honest"
mk_m_task M02
review_plan_store "$repoM" M02 \
  "$(printf '1\tdeeprev\tengine-independent\tworktree\n2\tdeeprev\tsession-independent\tworktree\n')" \
  || fail "fixture: M02's degraded two-slot plan must pin"
mk_m_review M02 "" test/plainrev
mk_m_review M02 ".2" "-"

# The manifest is edited AFTER that round was dispatched and its reviews were
# filed. Nothing about either review changed.
mk_engine deeprev test/deeprev structured_text
assert_eq inline "$(review_engine_depth deeprev)" \
  "premise: a live capability read now answers inline, so a verb that re-derived depth here would write that answer into the pin"

adoptM2="$(review_plan_adopt_evidence_rows "$repoM" M02)" \
  || fail "--adopt-evidence must accept a degraded plan covered by one named and one anonymous review"
assert_eq "$(printf '1\tplainrev\tengine-independent\tinline\ttest/plainrev\n2\tdeeprev\tengine-independent\tworktree\ttest/deeprev')" \
  "$adoptM2" \
  "the RETAINED slot keeps the depth AND the key it was pinned with; only the slot that actually adopted an envelope is derived afresh"
review_plan_store "$repoM" M02 "$adoptM2" || fail "the adopted table must land"
assert_eq 1 "$(review_plan_depth_count "$(review_plan "$repoM" M02)" test/deeprev)" \
  "...so a review filed by the engine that slot was dispatched to is still credited its depth: repairing the slots that moved must not shallow the ones that did not"
unset ORCHID_ENGINES_DIR

# ===========================================================================
# N -- THE PIN IS THE ONLY PLACE DEPTH MAY COME FROM, AND ITS ABSENCE IS A
# BOUNDARY, NOT A FALLBACK.
#
# Parts K, L and M froze the two columns a round is judged by. All three rest
# on there BEING a pinned round to read them from, and `review_plan` -- the
# table every other caller uses -- answers a missing pin with LIVE ROUTING.
# That fallback is correct for the callers it was written for: `--pin`'s own
# computation, `--repin`, `--adopt-evidence`, and the driver's dispatch walk
# are all choosing where to SEND a review or about to write a plan down.
#
# It is not correct for the one caller judging reviews already filed. A table
# computed at arbitration time says where a review would be sent today; the
# question is what the reviewer who filed THIS one could see, and those are
# the same string only by coincidence. So a plan deleted, truncated, emptied
# or re-pointed at another candidate between filing and judging would have
# been silently replaced by a fresh table -- and a deterministic approval
# handed out on a depth claim nothing recorded, which is the whole of what
# Parts K and L exist to prevent, arrived at through the back door.
#
# Every case below is the SAME round of evidence, unchanged and complete,
# judged with its plan interfered with in one of the four ways a pin can stop
# being usable. The fixture is built so LIVE ROUTING WOULD ANSWER YES to each
# of them, because only that makes "reads the pin" distinguishable from "reads
# nothing".
# ===========================================================================
export ORCHID_ENGINES_DIR="$WORK/engN"; mkdir -p "$ORCHID_ENGINES_DIR"
mk_engine nimpl test/nimpl workspace_write,shell,git
mk_engine ndeep test/ndeep structured_text,workspace_read
mk_engine nflat test/nflat structured_text
repoN="$WORK/repoN"; mkdir -p "$repoN/.orchid/tasks" "$repoN/.orchid/reviews"
NCAND=8888888888888888888888888888888888888888
printf 'role.implementer=nimpl
role.reviewer=ndeep
review.medium=ndeep,nflat
' > "$repoN/orchid.config"

mk_n_task() {  # <id> [candidate] -- a medium-tier task on attempt 1
  local cand="${2-$NCAND}"
  printf -- '---\nschema: 1\nid: %s\nstatus: arbitrating\narchetype: feature\nattempts: 0\nrisk_tier: medium\nblocking_severity: high\ncandidate_sha: %s\n---\nbody\n' \
    "$1" "$cand" > "$repoN/.orchid/tasks/$1.md"
}
mk_n_review() {  # <id> <suffix> <qualified-engine-id>
  jq -n --arg jid "j-pin-$1$2" --arg task "$1" --arg cand "$NCAND" --arg e "$3" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:"approve", scope_complete:true, summary:"pin fixture",
      candidate_sha:$cand, findings:[], engine:$e}' \
    > "$repoN/.orchid/reviews/$1-a1-reviewer$2.json"
}
ndecision() { drive_review_decision "$repoN" "$1" | cut -f1; }
ndetail()   { drive_review_decision "$repoN" "$1" | cut -f2- ; }

mk_n_task N01
mk_n_review N01 ""   test/ndeep
mk_n_review N01 ".2" test/nflat
review_plan_store "$repoN" N01 \
  "$(printf '1\tndeep\tengine-independent\tworktree\n2\tnflat\tengine-independent\tinline\n')" \
  || fail "fixture: N01's plan must pin"
NPIN="$(review_plan_file "$repoN" N01)"
cp "$NPIN" "$WORK/N01-pin.json"
assert_eq approve "$(ndecision N01)" \
  "premise: a complete unanimous set, dispatched under a plan whose slot 1 was worktree-capable and filled by that very engine"

# THE PREMISE THAT MAKES THIS PART FALSIFIABLE. Live routing here produces the
# same two rows the pin holds, so no case below can be passed by a policy that
# simply recomputed the table -- each one is decided by WHICH table was
# consulted, not by which engines happen to be installed.
assert_eq "$(printf '1\tndeep\tengine-independent\tworktree\n2\tnflat\tengine-independent\tinline')" \
  "$(review_routing "$repoN" N01)" \
  "premise: live routing would credit this same round the same depth, so falling back to it would look exactly like reading the pin"

# --- N1, RED: the plan is DELETED after the reviews are filed. A wiped
# --- `reviews/` restored from a partial backup, an operator tidying a
# --- directory, a runtime tree rebuilt without it.
rm -f "$NPIN"
assert_eq evidence "$(ndecision N01)" \
  "with the pinned round gone, the depth claim has nothing behind it and no deterministic approval is made"
assert_match 'no usable pinned review plan \(missing\)' "$(ndetail N01)" \
  "the detail names WHICH way the pin stopped being usable, or the boundary cannot say what to repair"
assert_match 'orchid task arbitrate' "$(ndetail N01)" \
  "...and names the verb that settles it where it is raised: this boundary is arbitrable, never a park"
assert_match 'adopt-evidence' "$(ndetail N01)" \
  "...and the recorded verb that re-pins the slots onto the engines that actually reviewed"
grep -Eq -- '--pin' <<< "$(ndetail N01)" \
  && fail "the remedy must NOT be '--pin': run here, after the evidence is on disk, it would freeze whatever live routing says today and hand the round a depth claim computed after the fact -- the defect wearing the remedy's clothes"
red_case 'a review plan deleted between filing and judging is answered from live routing, so a deterministic approval rests on a depth claim nothing recorded'

# ...and the FALLBACK ITSELF IS KEPT, which is the other half of this change.
# The callers that dispatch a slot, and the three verbs that write a plan
# down, must still get a table out of a task whose pin was lost -- otherwise a
# lost plan would leave a task that could never be reviewed again, which is a
# worse dead end than the one being closed. What moved is only who may use
# that table to JUDGE.
assert_eq "$(review_routing "$repoN" N01)" "$(review_plan "$repoN" N01)" \
  "review_plan still falls back to live routing for the pre-dispatch callers, even while the gate above refuses to judge from it"

# --- N1, GREEN: the same envelopes, the same installed engines, the same
# --- everything -- with the plan the round was dispatched under back on disk.
cp "$WORK/N01-pin.json" "$NPIN"
assert_eq approve "$(ndecision N01)" \
  "the pinned round is what credits the depth, and it credits it again the moment it is readable"
assert_match "1 of them worktree-capable" "$(ndetail N01)" \
  "and the approval says which axis it rested on"
green_case 'depth is credited only from the pinned round, so a plan that is not there is a boundary rather than a recomputation'

# --- N2: the pin is RE-POINTED at another candidate. The reviews on disk are
# --- still bound to the task's own, so the count and the verdicts are
# --- untouched -- it is only the plan that no longer describes this round.
jq --arg c 9999999999999999999999999999999999999999 '.candidate_sha = $c' \
  "$WORK/N01-pin.json" > "$NPIN"
assert_eq evidence "$(ndecision N01)" \
  "a plan bound to a candidate this task has moved off is not this round's plan"
assert_match 'no usable pinned review plan \(candidate-stale\)' "$(ndetail N01)" \
  "and it is reported as the stale binding it is, not as a missing file"

# --- N3: the pin is UNREADABLE -- a write torn off mid-flight, the shape
# --- `atomic_write` exists to prevent and a restored backup can still produce.
printf '{"contract":1, "slots":[\n' > "$NPIN"
assert_eq evidence "$(ndecision N01)" \
  "an unparseable plan proves nothing, and fails closed rather than reading as absent"
assert_match 'no usable pinned review plan \(unreadable\)' "$(ndetail N01)" \
  "...and says so specifically: 'missing' would send an operator looking for a file that is right there"

# --- N4: the pin PARSES and BINDS but carries no slot at all.
jq '.slots = []' "$WORK/N01-pin.json" > "$NPIN"
assert_eq evidence "$(ndecision N01)" \
  "a plan with no slots credits no slot, so it can support no depth claim"
assert_match 'no usable pinned review plan \(empty\)' "$(ndetail N01)" \
  "...reported as empty rather than as unreadable, because the file itself is fine"

cp "$WORK/N01-pin.json" "$NPIN"
assert_eq approve "$(ndecision N01)" \
  "and each of the three repairs above is undone by putting the round's own plan back -- nothing else about the evidence ever changed"

# --- N5: the classifier itself, every state it can report. The gate prints
# --- one of these words into a boundary an operator acts on, so a state that
# --- answered the wrong one would misdirect the repair.
assert_eq ok "$(review_plan_pin_state "$repoN" N01)" \
  "a plan that parses, binds to this candidate and holds slots is usable"
mk_n_task N02 ""
assert_eq no-candidate "$(review_plan_pin_state "$repoN" N02)" \
  "a task with no candidate_sha could never have had a plan bound to one"
assert_eq evidence "$(ndecision N02)" \
  "...and the gate answers that one on the candidate itself, before it ever asks about a plan"
assert_match "no candidate_sha" "$(ndetail N02)" \
  "so the operator is told the round has no candidate, not that its plan is missing"
mk_n_task N03
assert_eq missing "$(review_plan_pin_state "$repoN" N03)" \
  "a task whose attempt was never pinned reports the file, not the binding"

# --- N6: and the two shortfalls stay TOLD APART. A plan REPLACED after the
# --- fact -- one that parses, binds to this candidate, and holds slots, but
# --- routes engines that filed nothing -- is a usable pin crediting no depth,
# --- which is a different problem with a different repair from having no plan
# --- at all. Collapsing the two would send an operator looking for a file that
# --- is sitting right there, or hand them --adopt-evidence for a round whose
# --- own plan already says what it was.
jq '.slots = [{slot:1, engine:"nflat", label:"engine-independent", depth:"inline", qid:"test/nflat"},
              {slot:2, engine:"nother", label:"engine-independent", depth:"inline", qid:"test/nother"}]' \
  "$WORK/N01-pin.json" > "$NPIN"
assert_eq evidence "$(ndecision N01)" \
  "a pinned round whose slots are all inline credits no depth, exactly as Part F's D01 does"
assert_match "unproven review depth: 2 of 2" "$(ndetail N01)" \
  "and it is the DEPTH shortfall that is reported: the plan is right there, and it is what says the round was shallow"
grep -Fq 'no usable pinned review plan' <<< "$(ndetail N01)" \
  && fail "a readable, candidate-bound plan must never be reported as a missing one -- the two shortfalls have different repairs"
unset ORCHID_ENGINES_DIR
