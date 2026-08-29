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
#             `role.reviewer`'s chain and the implementer's own engine; and
#             `drive_review_decision` refusing a DETERMINISTIC approval at
#             medium/high when no counted review is credited to a `worktree`
#             slot -- credited off the attempt's PINNED plan and the same
#             slot matching that decides which slot a review fills, never off
#             a manifest read taken at judging time (Part K).
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

# --- RED: a complete, unanimous, finding-free medium-tier set, every review
# --- from an inline engine. This is r-001's T003 exactly.
mk_task D01 medium high
mk_review_by D01 "" approve orchid/agy
mk_review_by D01 ".2" approve orchid/hermes
assert_eq evidence "$(decision_of D01)" \
  "two inline approvals do not deterministically approve a medium-tier task"
assert_match "unproven review depth: 2 of 2" "$(detail_of D01)" \
  "the detail concedes the COUNT was met and names the axis that was not"
assert_match "cannot open the files" "$(detail_of D01)" \
  "...and says what an inline reviewer could not do, so the operator knows what to check"
red_case 'a complete unanimous medium-tier review set with no worktree-capable reviewer is refused deterministic approval'

# --- GREEN: the same set, one review re-attributed to a worktree-capable
# --- engine. Nothing else changes.
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

# --- low tier is untouched. A single inline approval still approves.
mk_task D02 low high
mk_review_by D02 "" approve orchid/agy
assert_eq approve "$(decision_of D02)" \
  "risk_tier low requires no depth: one inline approval still approves, exactly as before"

# --- an envelope naming NO engine cannot support a depth claim, and the
# --- shortfall is reported the same way (tests/test_drive.sh's P11 covers
# --- the two-unattributable-reviews case end to end).
mk_task D03 medium high
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
# ACTUAL output rather than on a literal row. A fifth column fails here, on
# the emitter's own bytes, instead of silently in production.
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
  || fail "the canonical four-column row is a dispatchable slot"
review_plan_row_valid "$(printf '1\tagy\tengine-independent')" \
  && fail "a three-column row is NOT dispatchable -- depth is never defaulted in at the reading end"
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tinline\tsixth')" \
  && fail "a fifth column is refused rather than ignored: a reader must not dispatch a grammar it does not know"
review_plan_row_valid "$(printf '1\tagy\tengine-independent\tdeep')" \
  && fail "an unrecognized depth label is refused"
review_plan_row_valid "$(printf 'slot-one\tagy\tengine-independent\tinline')" \
  && fail "a non-numeric slot is refused"
review_plan_row_valid "$(printf '1\t\tengine-independent\tinline')" \
  && fail "a row naming no engine is refused"
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
mk_pin() {  # <id> <slot1-engine> <slot1-depth> <slot2-engine> <slot2-depth>
  jq -n --arg cand "$PCAND" --arg e1 "$2" --arg d1 "$3" --arg e2 "$4" --arg d2 "$5" \
    '{contract:1, attempt:1, candidate_sha:$cand, pinned_at:"2026-02-01T00:00:00Z",
      slots:[{slot:1, engine:$e1, label:"engine-independent", depth:$d1},
             {slot:2, engine:$e2, label:"engine-independent", depth:$d2}]}' \
    > "$POLICY/.orchid/reviews/$1-a1.review-plan.json"
}

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
# --- can only emit four-column rows, so this is the library's own contract
# --- rather than a shape a pin file can reach -- and it is the contract that
# --- keeps a fifth column, or a diagnostic, from ever reading as depth.
assert_eq 0 "$(review_plan_depth_count "$(printf '1\tagy\tengine-independent\tworktree\tsixth\n')" orchid/agy)" \
  "a row carrying an unknown fifth column is not a slot, so it is not a worktree slot either"
assert_eq 0 "$(review_plan_depth_count "$(printf '1\tagy\tengine-independent\n')" orchid/agy)" \
  "a three-column row claims no depth, and none is defaulted in at the reading end"
assert_eq 0 "$(review_plan_depth_count 'jq: error: null (null) has no keys' orchid/agy)" \
  "a diagnostic merged in from stderr credits nothing"
