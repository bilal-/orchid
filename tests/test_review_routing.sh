#!/usr/bin/env bash
# v1-m2 Task 3: dual review routing, launch engine override, kernel
# envelope-count gate.
#
# `lib/review.sh`'s review_required_count/review_implementer_engine/
# review_routing; `orchid jobs prepare --engine`/`orchid-launch --engine`
# (F5: the second dual-review engine is now launchable, not just resolved);
# `orchid jobs review-plan <task>` (read-only tier-1 routing table);
# `task advance implementing->testing` implementer_engine_id capture;
# `task advance reviewing->arbitrating`'s reconciled-envelope-count gate;
# `task set risk_tier`'s blocking_severity derivation; `lib/pack.sh`'s
# symbols.txt (blind-spot guard data).
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"; source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"; source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
source "$REPO_ROOT/lib/review.sh"; source "$REPO_ROOT/lib/pack.sh"
export ORCHID_ROOT="$REPO_ROOT"
export HOME="$WORK/home"; mkdir -p "$HOME"

# ---------------------------------------------------------------------------
# A -- review_required_count: low -> 1; medium|high -> 2; unknown -> 2
# (fail-safe, never under-review an unrecognized tier).
# ---------------------------------------------------------------------------
assert_eq 1 "$(review_required_count low)" "review_required_count low -> 1"
assert_eq 2 "$(review_required_count medium)" "review_required_count medium -> 2"
assert_eq 2 "$(review_required_count high)" "review_required_count high -> 2"
assert_eq 2 "$(review_required_count bogus-tier)" "review_required_count unknown -> 2 (fail-safe)"
assert_eq 2 "$(review_required_count "")" "review_required_count empty -> 2 (fail-safe)"

# ---------------------------------------------------------------------------
# mk_custom_engine <dir> <name> <capabilities> -- a stub engine under a
# private ORCHID_ENGINES_DIR, used only where we need a NAME distinct from
# the real production engines (plugins/engines/agy|codex|codex-review|claude,
# always discoverable once ORCHID_ROOT is the real repo root -- exactly like
# tests/test_roles.sh already relies on). Every scenario that just needs
# "codex implementer" / "agy reviewer" / "codex-review, worktree-capable"
# uses those real engines directly, no stub required.
# ---------------------------------------------------------------------------
mk_custom_engine() {
  local edir="$1" name="$2" caps="$3" d
  d="$edir/$name"; mkdir -p "$d"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nrequires_binaries=jq\nentrypoint=run\n' \
    "$name" "$caps" > "$d/plugin.conf"
  cat > "$d/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"; out="$(jq -r .output "$req")"; jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok", summary:"stub"}' > "$out"
EOF
  chmod +x "$d/run"
}

# ===========================================================================
# B/C/D -- `orchid jobs prepare <task> <role> <op> --engine <name>` (F5)
# ===========================================================================
repoB="$WORK/repoB"; mkdir -p "$repoB/.orchid/tasks"
(cd "$repoB" && git init -q . && git commit -q --allow-empty -m root)
export ORCHID_ENGINES_DIR="$WORK/engB"; mkdir -p "$ORCHID_ENGINES_DIR"
mk_custom_engine "$ORCHID_ENGINES_DIR" ovr1 "workspace_write,shell,git"
export ORCHID_REPO="$repoB"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create TB demo >/dev/null

# B -- a discovered + eligible override is recorded in the manifest exactly
# like a resolved engine (F5 closed).
m="$("$ORCHID_BIN" jobs prepare TB implementer implement --engine ovr1)"
[ -f "$m" ] || fail "prepare --engine writes a manifest"
assert_eq ovr1 "$(jq -r .engine "$m")" "prepare --engine records the override engine in the manifest"
# This manifest is an ORPHAN by construction: nothing is going to launch it
# (PROTOCOL.md is explicit that `jobs prepare` is never called separately
# before a launch, precisely because it strands one). E below launches the same
# task/role/operation for real, and since T027 a second manifest for a slot
# that already has a never-started one is refused outright (exit 18) -- so the
# fixture clears its own litter here rather than leaving the launch to trip
# over it.
rm -f "$m"

# C -- an undiscovered engine name is refused with exit 14, never silently
# accepted (the override names ANY discovered engine, not an arbitrary
# string).
rc=0; err="$("$ORCHID_BIN" jobs prepare TB implementer implement --engine totally-nonexistent-engine 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" "prepare --engine refuses an undiscovered engine with exit 14"
assert_match "not found" "$err" "prepare --engine names the undiscovered engine in its error"

# D -- a discovered but ineligible override (agy, structured_text only, for the
# implementer role which requires workspace_write/shell/git) is refused, never
# silently accepted. It comes back 19 rather than 14 because the same three
# atoms are what the `implement` STEP needs (INV-16, lib/capability.sh), and
# where the caller named the actor that kernel-owned question is asked first:
# both gates refuse this call, and 19 is the answer no later pass can change,
# while runners/orchid-drive reads 14 as a wait. The role gate still refuses on
# its own terms -- D2 is that case.
rc=0; err="$("$ORCHID_BIN" jobs prepare TB implementer implement --engine agy 2>&1 1>/dev/null)" || rc=$?
assert_eq 19 "$rc" "prepare --engine refuses an ineligible engine whose shortfall is also the step's, with exit 19"
assert_match "missing: workspace_write" "$err" "prepare --engine names the missing capability"

# D2 -- and the role gate is NOT bypassed by that ordering. `revonly` declares
# exactly what the `review` step needs, so INV-16 has no objection; the custom
# role it is bound to asks for `network` as well, and role_eligibility_reason
# refuses it there with the exit 14 it always did.
mk_custom_engine "$ORCHID_ENGINES_DIR" revonly "structured_text"
mkdir -p "$WORK/rolesB"
printf 'id=netreviewer\nrequires=structured_text,network\ndescription=fixture\n' \
  > "$WORK/rolesB/netreviewer.role"
export ORCHID_ROLES_DIR="$WORK/rolesB"
rc=0; err="$("$ORCHID_BIN" jobs prepare TB netreviewer review --engine revonly 2>&1 1>/dev/null)" || rc=$?
unset ORCHID_ROLES_DIR
assert_eq 14 "$rc" "prepare --engine still refuses a role-ineligible engine with exit 14 when the step itself is covered"
assert_match "network" "$err" "and the role gate's own refusal names the capability the ROLE asked for"

# E -- `orchid-launch <task> <role> <op> --engine <name>` forwards the flag
# to prepare verbatim.
launch_out="$("$REPO_ROOT/runners/orchid-launch" TB implementer implement --engine ovr1)"
assert_match "^launched j-" "$launch_out" "orchid-launch --engine reports a launched job"
job_id="$(echo "$launch_out" | awk '{print $2}')"
launch_manifest="$repoB/.orchid/runtime/jobs/$job_id.json"
[ -f "$launch_manifest" ] || fail "orchid-launch --engine leaves the manifest behind"
assert_eq ovr1 "$(jq -r .engine "$launch_manifest")" "orchid-launch --engine's manifest carries the overridden engine"

# ===========================================================================
# F/G/H -- `review_routing`/`orchid jobs review-plan <task>` (dual review
# routing table; real production engines, no stubs needed)
# ===========================================================================
repoR="$WORK/repoR"; mkdir -p "$repoR/.orchid/tasks"
(cd "$repoR" && git init -q . && git commit -q --allow-empty -m root)
unset ORCHID_ENGINES_DIR
export ORCHID_REPO="$repoR"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# F -- low-tier task, default (codex) implementer -> a single agy slot,
# labeled engine-independent (agy != codex). review-plan is read-only:
# no ORCHID_EPOCH needed at all.
"$ORCHID_BIN" task create TR1 demo >/dev/null
outF="$(ORCHID_EPOCH='' "$ORCHID_BIN" jobs review-plan TR1)"
assert_eq 1 "$(echo "$outF" | wc -l | tr -d ' ')" "low tier: review-plan prints exactly one slot"
assert_match $'^1\tagy\tengine-independent\tinline$' "$outF" "low tier: slot 1 is agy, engine-independent (differs from codex implementer), inline (no workspace_read)"

# G -- medium-tier task -> two distinct slots; slot 2 prefers the worktree-
# capable engine (codex-review declares workspace_read; agy does not).
"$ORCHID_BIN" task create TR2 demo >/dev/null
"$ORCHID_BIN" task set TR2 risk_tier medium --reason "touches shared code" >/dev/null
outG="$("$ORCHID_BIN" jobs review-plan TR2)"
assert_eq 2 "$(echo "$outG" | wc -l | tr -d ' ')" "medium tier: review-plan prints exactly two slots"
assert_match $'^1\tagy\tengine-independent\tinline$' "$outG" "medium tier: slot 1 is agy, engine-independent, inline"
assert_match $'^2\tcodex-review\tengine-independent\tworktree$' "$outG" "medium tier: slot 2 is codex-review (worktree-capable, distinct from slot 1), engine-independent"

# H -- when every candidate OTHER than the implementer's own engine is
# unavailable, the slot falls back to the implementer's engine, labeled
# session-independent -- NEVER silently, and never zero slots.
ledger_mark "$repoR" agy rate_limited 999999
ledger_mark "$repoR" codex-review rate_limited 999999
"$ORCHID_BIN" task create TR3 demo >/dev/null
outH="$("$ORCHID_BIN" jobs review-plan TR3)"
assert_match $'^1\tcodex\tsession-independent\tworktree$' "$outH" "only the implementer's engine available -> session-independent fallback (never silent)"

# ===========================================================================
# I/J/K -- one task's real lifecycle walk: implementer_engine_id capture,
# risk_tier -> blocking_severity derivation, reviewing->arbitrating count gate
# ===========================================================================
repoL="$WORK/repoL"; mkdir -p "$repoL/.orchid/tasks"
(cd "$repoL" && git init -q . && git commit -q --allow-empty -m root)
printf 'verify=true\n' > "$repoL/orchid.config"
export ORCHID_REPO="$repoL"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create TL1 demo >/dev/null
"$ORCHID_BIN" task advance TL1 implementing >/dev/null
head_sha="$(git -C "$repoL" rev-parse HEAD)"
"$ORCHID_BIN" task set TL1 base_sha "$head_sha" >/dev/null
"$ORCHID_BIN" task set TL1 candidate_sha "$head_sha" >/dev/null

mkdir -p "$repoL/.orchid/reviews"
jq -n '{contract:1, job_id:"j-plant-1", task:"TL1", operation:"implement", status:"ok",
        summary:"planted", engine:"orchid/codex"}' > "$repoL/.orchid/reviews/TL1-a1-implementer.json"

# I -- implementing->testing captures implementer_engine_id from the planted
# envelope's .engine, stripping the leading "orchid/".
"$ORCHID_BIN" task advance TL1 testing >/dev/null
assert_eq codex "$(fm_get "$repoL/.orchid/tasks/TL1.md" implementer_engine_id)" \
  "advance implementing->testing captures implementer_engine_id from the planted envelope"

"$ORCHID_BIN" verify TL1 >/dev/null
"$ORCHID_BIN" task advance TL1 reviewing --reason "verify passed" >/dev/null

# K -- risk_tier low->medium also derives blocking_severity (low->high;
# medium|high->medium), in the SAME risk_change journal entry.
before_bsev="$(fm_get "$repoL/.orchid/tasks/TL1.md" blocking_severity)"
assert_eq high "$before_bsev" "fresh task's blocking_severity starts high (low-tier default)"
"$ORCHID_BIN" task set TL1 risk_tier medium --reason "needs dual review" >/dev/null
assert_eq medium "$(fm_get "$repoL/.orchid/tasks/TL1.md" blocking_severity)" \
  "risk_tier low->medium flips blocking_severity to medium"
assert_match "low -> medium.*needs dual review.*medium" "$(tail -n5 "$repoL/.orchid/journal.md")" \
  "risk_change journal entry carries the blocking_severity derivation alongside the reason"

# J -- reviewing->arbitrating is refused when fewer than review_required_
# count(risk_tier) reviewer envelopes are reconciled, and passes once enough
# land (second one via the .2.json counter suffix, same as jobs reconcile's
# own collision handling).
jq -n --arg cand "$head_sha" '{contract:1, job_id:"j-plant-2", task:"TL1", operation:"review", status:"ok",
        verdict:"approve", scope_complete:true, summary:"planted review 1", candidate_sha:$cand}' \
  > "$repoL/.orchid/reviews/TL1-a1-reviewer.json"
rc=0; err="$("$ORCHID_BIN" task advance TL1 arbitrating --reason "one review only" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "reviewing->arbitrating must refuse with only 1/2 reviewer envelopes for risk_tier medium"
assert_match "arbitrating requires 2 reconciled review envelope\(s\) for risk_tier medium \(have 1\)" "$err" \
  "reviewing->arbitrating gate names required/actual counts and risk_tier"
assert_eq reviewing "$(fm_get "$repoL/.orchid/tasks/TL1.md" status)" "refused arbitrating leaves status at reviewing"

jq -n --arg cand "$head_sha" '{contract:1, job_id:"j-plant-3", task:"TL1", operation:"review", status:"ok",
        verdict:"approve", scope_complete:true, summary:"planted review 2", candidate_sha:$cand}' \
  > "$repoL/.orchid/reviews/TL1-a1-reviewer.2.json"
"$ORCHID_BIN" task advance TL1 arbitrating --reason "two reviews reconciled" >/dev/null
assert_eq arbitrating "$(fm_get "$repoL/.orchid/tasks/TL1.md" status)" \
  "reviewing->arbitrating succeeds once 2/2 reviewer envelopes are reconciled"

# ===========================================================================
# L -- lib/pack.sh: review/critique packs gain symbols.txt (changed-file
# list + every hunk header), truncatable, trimmed AFTER context.md.
# ===========================================================================
packrepo="$WORK/packrepo"; mkdir -p "$packrepo/.orchid/tasks"
(cd "$packrepo" && git init -q . && echo base > f.txt && git add f.txt && git commit -q -m base)
base_sha="$(git -C "$packrepo" rev-parse HEAD)"
echo changed > "$packrepo/f.txt"
(cd "$packrepo" && git add f.txt && git commit -q -m change)
cand_sha="$(git -C "$packrepo" rev-parse HEAD)"
printf -- '---\nid: TP\nstatus: reviewing\nbase_sha: %s\ncandidate_sha: %s\n---\nspec.\n' "$base_sha" "$cand_sha" \
  > "$packrepo/.orchid/tasks/TP.md"

pack_build "$packrepo" TP review "$packrepo/p1" || fail "pack_build (review) succeeds"
[ -f "$packrepo/p1/symbols.txt" ] || fail "review pack contains symbols.txt"
grep -q '^+++ ' "$packrepo/p1/symbols.txt" || fail "symbols.txt contains a +++ file header"
grep -q '^@@ ' "$packrepo/p1/symbols.txt" || fail "symbols.txt contains a @@ hunk header"
assert_eq "false" "$(jq -r '.items[] | select(.name=="symbols.txt") | .truncated' "$packrepo/p1/pack.json")" \
  "symbols.txt untruncated when it comfortably fits the budget"

# implement packs do NOT gain symbols.txt (only review/critique do).
pack_build "$packrepo" TP implement "$packrepo/p2" || fail "pack_build (implement) succeeds"
[ ! -f "$packrepo/p2/symbols.txt" ] || fail "implement pack must not contain symbols.txt"

# ===========================================================================
# M/N -- waived-rework stale-envelope fixes (review-approved fix, not the
# original brief): `--waive-attempt` on arbitrating->rework leaves
# `attempts` unchanged, so a waived-rework round reuses the SAME attempt
# number K as the round it followed. Neither the reviewing->arbitrating
# count gate nor the implementer_engine_id capture may be satisfiable by
# STALE round-1 envelopes left over from before the rework -- both must
# bind to the task's CURRENT candidate_sha (or, for the implementer
# capture, fall back to the most recently reconciled envelope when no
# candidate_sha match exists).
# ===========================================================================
repoW="$WORK/repoW"; mkdir -p "$repoW/.orchid/tasks"
(cd "$repoW" && git init -q . && git commit -q --allow-empty -m root)
# v1-m2 Task 5: TW1/TW2/TW3 sit active (arbitrating/testing) at once by this
# section's design (unrelated to concurrency) -- raise the cap so the new
# dispatch gate never interferes with these waived-rework assertions.
printf 'verify=true\nconcurrency=10\n' > "$repoW/orchid.config"
export ORCHID_REPO="$repoW"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
head_w="$(git -C "$repoW" rev-parse HEAD)"
mkdir -p "$repoW/.orchid/reviews"

# ---------------------------------------------------------------------------
# M -- reviewing->arbitrating count gate must not be satisfiable by a stale
# round-1 reviewer envelope after a waived rework changed candidate_sha.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TW1 demo >/dev/null
"$ORCHID_BIN" task advance TW1 implementing >/dev/null
"$ORCHID_BIN" task set TW1 base_sha "$head_w" >/dev/null
"$ORCHID_BIN" task set TW1 candidate_sha "$head_w" >/dev/null
"$ORCHID_BIN" task advance TW1 testing >/dev/null
"$ORCHID_BIN" verify TW1 >/dev/null
"$ORCHID_BIN" task advance TW1 reviewing --reason "round 1 verify passed" >/dev/null
jq -n --arg cand "$head_w" \
  '{contract:1, job_id:"j-w-round1-reviewer", task:"TW1", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"round 1 review", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW1-a1-reviewer.json"
"$ORCHID_BIN" task advance TW1 arbitrating --reason "round 1 approved" >/dev/null
assert_eq arbitrating "$(fm_get "$repoW/.orchid/tasks/TW1.md" status)" "sanity: round 1 reaches arbitrating"

before_attempts="$(fm_get "$repoW/.orchid/tasks/TW1.md" attempts)"
"$ORCHID_BIN" task advance TW1 rework --waive-attempt --reason "distinct forward progress, waived" >/dev/null
assert_eq "$before_attempts" "$(fm_get "$repoW/.orchid/tasks/TW1.md" attempts)" \
  "sanity: --waive-attempt leaves attempts (and so the attempt number) unchanged"

"$ORCHID_BIN" task advance TW1 implementing >/dev/null
cand2_w="$(git -C "$repoW" commit-tree "$head_w^{tree}" -p "$head_w" -m "TW1 round 2 fix")"
"$ORCHID_BIN" task set TW1 candidate_sha "$cand2_w" >/dev/null
"$ORCHID_BIN" task advance TW1 testing >/dev/null
# T031: `orchid verify` refuses a tree that is not the recorded candidate, so
# round 2's candidate has to actually be checked out for the run. cand2_w
# shares head_w's tree, so this is a pure HEAD move; restoring afterwards
# keeps TW2/TW3 below (which pin themselves to head_w) honest.
git -C "$repoW" reset -q --hard "$cand2_w"
"$ORCHID_BIN" verify TW1 >/dev/null
git -C "$repoW" reset -q --hard "$head_w"
"$ORCHID_BIN" task advance TW1 reviewing --reason "round 2 verify passed" >/dev/null

# The stale round-1 envelope (candidate_sha == head_w) is STILL on disk at
# reviews/TW1-a1-reviewer.json (rework only invalidates verify.log/merge.log,
# never reviews/*.json) -- and the attempt number is unchanged (K=1, waived),
# so the plain glob from the original implementation would have wrongly
# counted it as satisfying round 2's gate too.
rc=0; err="$("$ORCHID_BIN" task advance TW1 arbitrating --reason "attempt with only the stale envelope" 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "waived rework: stale round-1 reviewer envelope (old candidate_sha) must not satisfy the count gate"
assert_match "arbitrating requires 1 reconciled review envelope\(s\) for risk_tier low \(have 0\)" "$err" \
  "waived rework: gate reports 0 sha-bound envelopes despite a stale file existing on disk"
assert_eq reviewing "$(fm_get "$repoW/.orchid/tasks/TW1.md" status)" "refused arbitrating (stale envelope) leaves status at reviewing"

# A fresh round-2 envelope, bound to the CURRENT candidate_sha, lands at the
# counter-suffixed path (the base name is still occupied by the stale
# round-1 file) -- exactly what `jobs reconcile`'s own collision handling
# would have produced. The gate must now pass.
jq -n --arg cand "$cand2_w" \
  '{contract:1, job_id:"j-w-round2-reviewer", task:"TW1", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"round 2 review", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW1-a1-reviewer.2.json"
"$ORCHID_BIN" task advance TW1 arbitrating --reason "round 2 approved" >/dev/null
assert_eq arbitrating "$(fm_get "$repoW/.orchid/tasks/TW1.md" status)" \
  "waived rework: arbitrating succeeds once a reviewer envelope bound to the CURRENT candidate_sha lands"

# ---------------------------------------------------------------------------
# N -- implementer_engine_id capture after a waived rework must prefer the
# envelope bound to the CURRENT candidate_sha over a stale round-1 file, even
# when a decoy stale file has a HIGHER collision counter (proving match-
# preference beats raw "highest counter wins").
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TW2 demo >/dev/null
"$ORCHID_BIN" task advance TW2 implementing >/dev/null
"$ORCHID_BIN" task set TW2 base_sha "$head_w" >/dev/null
"$ORCHID_BIN" task set TW2 candidate_sha "$head_w" >/dev/null
jq -n --arg cand "$head_w" \
  '{contract:1, job_id:"j-w2-round1-impl", task:"TW2", operation:"implement", status:"ok",
    summary:"round 1 implement", engine:"orchid/codex", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW2-a1-implementer.json"
"$ORCHID_BIN" task advance TW2 testing >/dev/null
assert_eq codex "$(fm_get "$repoW/.orchid/tasks/TW2.md" implementer_engine_id)" \
  "sanity: round 1 implementer_engine_id capture (single envelope)"
"$ORCHID_BIN" verify TW2 >/dev/null
"$ORCHID_BIN" task advance TW2 reviewing --reason "round 1 verify passed" >/dev/null
jq -n --arg cand "$head_w" \
  '{contract:1, job_id:"j-w2-round1-reviewer", task:"TW2", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"round 1 review", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW2-a1-reviewer.json"
"$ORCHID_BIN" task advance TW2 arbitrating --reason "round 1 approved" >/dev/null

"$ORCHID_BIN" task advance TW2 rework --waive-attempt --reason "distinct forward progress, waived" >/dev/null
"$ORCHID_BIN" task advance TW2 implementing >/dev/null
cand2_w2="$(git -C "$repoW" commit-tree "$head_w^{tree}" -p "$head_w" -m "TW2 round 2 fix")"
"$ORCHID_BIN" task set TW2 candidate_sha "$cand2_w2" >/dev/null

# Same attempt number K=1 (waived): the base file is still round 1's
# (stale). Plant the REAL round-2 envelope at the counter-suffixed path
# (engine claude, bound to the new candidate) PLUS a decoy at an even HIGHER
# counter (engine decoy-engine, bound to the STALE candidate) -- the decoy
# must lose despite its higher counter, because it doesn't match the
# current candidate_sha.
jq -n --arg cand "$cand2_w2" \
  '{contract:1, job_id:"j-w2-round2-impl", task:"TW2", operation:"implement", status:"ok",
    summary:"round 2 implement", engine:"orchid/claude", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW2-a1-implementer.2.json"
jq -n --arg cand "$head_w" \
  '{contract:1, job_id:"j-w2-decoy-impl", task:"TW2", operation:"implement", status:"ok",
    summary:"decoy stale envelope, higher counter", engine:"orchid/decoy-engine", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW2-a1-implementer.3.json"

"$ORCHID_BIN" task advance TW2 testing >/dev/null
assert_eq claude "$(fm_get "$repoW/.orchid/tasks/TW2.md" implementer_engine_id)" \
  "waived rework: implementer_engine_id capture prefers the envelope matching the CURRENT candidate_sha over a higher-counter stale decoy"

# ---------------------------------------------------------------------------
# O -- when NO envelope matches the current candidate_sha at all, the
# capture must still fall back to the highest-counter (most recently
# reconciled) file, never the oldest.
# ---------------------------------------------------------------------------
"$ORCHID_BIN" task create TW3 demo >/dev/null
"$ORCHID_BIN" task advance TW3 implementing >/dev/null
cand3_w="$(git -C "$repoW" commit-tree "$head_w^{tree}" -p "$head_w" -m "TW3 candidate")"
"$ORCHID_BIN" task set TW3 base_sha "$head_w" >/dev/null
"$ORCHID_BIN" task set TW3 candidate_sha "$cand3_w" >/dev/null
jq -n --arg cand "$head_w" \
  '{contract:1, job_id:"j-w3-impl-1", task:"TW3", operation:"implement", status:"ok",
    summary:"oldest, non-matching", engine:"orchid/alpha", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW3-a1-implementer.json"
jq -n --arg cand "$head_w" \
  '{contract:1, job_id:"j-w3-impl-2", task:"TW3", operation:"implement", status:"ok",
    summary:"newest, also non-matching", engine:"orchid/beta", candidate_sha:$cand}' \
  > "$repoW/.orchid/reviews/TW3-a1-implementer.2.json"
"$ORCHID_BIN" task advance TW3 testing >/dev/null
assert_eq beta "$(fm_get "$repoW/.orchid/tasks/TW3.md" implementer_engine_id)" \
  "implementer_engine_id capture falls back to the highest counter (newest) when no envelope matches the current candidate_sha"

# ===========================================================================
# P/Q/R/S/T -- THE PINNED PLAN (T039, run r-002's lesson L027).
#
# `review_routing` is computed live, from engine health among other things.
# Read once per dispatch that is right; read again to JUDGE a review that has
# already been filed, it is a table that moves under its own evidence. On
# r-002 it did: an engine filed a valid, candidate-bound review, then hit its
# consecutive-failure threshold on unrelated work, and the slot it had been
# dispatched for was re-routed to somebody else. Its review then belonged to
# no slot at all, the reviewing->arbitrating edge stayed shut, and the task
# had no legal exit that was not a hand-edit of durable state.
#
# So `orchid jobs review-plan <task> --pin` writes the table down for the life
# of the attempt, and two verbs -- `--repin` and `--adopt-evidence` -- are the
# recorded exits for a plan that no longer fits its evidence.
# ===========================================================================
repoP="$WORK/repoP"; mkdir -p "$repoP/.orchid/tasks" "$repoP/.orchid/reviews"
(cd "$repoP" && git init -q . && git commit -q --allow-empty -m root)
export ORCHID_REPO="$repoP"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
head_p="$(git -C "$repoP" rev-parse HEAD)"

# A medium-tier task with a candidate on it: two reviewer slots, and a round
# of evidence for a plan to be bound to.
mk_p_task() {
  "$ORCHID_BIN" task create "$1" "pinned plan fixture" >/dev/null
  "$ORCHID_BIN" task set "$1" risk_tier medium --reason "two reviewer slots" >/dev/null
  "$ORCHID_BIN" task set "$1" candidate_sha "$head_p" >/dev/null
}
mk_p_unbound_task() {
  "$ORCHID_BIN" task create "$1" "unbound pinned-plan fixture" >/dev/null
  "$ORCHID_BIN" task set "$1" risk_tier medium --reason "two reviewer slots" >/dev/null
}
# mk_p_review <task> <suffix> <qualified-engine-id|-> -- an ok, scope-complete,
# candidate-bound reviewer envelope, filed exactly where `jobs reconcile` files
# one. `-` is an adapter that omitted the optional `.engine` field.
mk_p_review() {
  jq -n --arg jid "j-plan-$1$2" --arg task "$1" --arg cand "$head_p" --arg e "$3" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:"approve", scope_complete:true, summary:"plan fixture",
      candidate_sha:$cand, findings:[]}
     + (if $e == "-" then {} else {engine:$e} end)' \
    > "$repoP/.orchid/reviews/$1-a1-reviewer$2.json"
}
p_journal() { "$ORCHID_BIN" journal show --task "$1" 2>/dev/null || true; }
p_pin_lines() { grep -c 'review plan pinned' <<< "$(p_journal "$1")" || true; }

# A PINNED row carries a fifth column the live table does not: the qualified
# engine id its slot's name resolved to at the write. That is the key a filed
# review is matched by, and freezing it is what stops an uninstall or a rebind
# from making an already-filed review match no slot (lib/review.sh's
# `_review_rows_qualify`; tests/test_review.sh Part L walks it end to end).
TWO_ENGINE_PLAN="$(printf '1\tagy\tengine-independent\tinline\torchid/agy\n2\tcodex-review\tengine-independent\tworktree\torchid/codex-review')"

# A writing plan command must reject an unbound round BEFORE its journal
# entry. `review_plan_store` has always refused the eventual file write; the
# ordering matters because journaling first otherwise records a pin that can
# never exist.
mk_p_unbound_task TP0
for unbound_mode in --pin --repin; do
  unbound_rc=0
  unbound_err="$("$ORCHID_BIN" jobs review-plan TP0 "$unbound_mode" 2>&1)" || unbound_rc=$?
  [ "$unbound_rc" -ne 0 ] || fail "RED: $unbound_mode must refuse a task with no candidate_sha"
  assert_match "there is none to bind to until the task has a candidate_sha" "$unbound_err" \
    "$unbound_mode explains that an unbound evidence round cannot be pinned"
done
[ ! -e "$(review_plan_file "$repoP" TP0)" ] \
  || fail "RED: rejected unbound plan commands must leave no pin behind"
assert_eq 0 "$(p_pin_lines TP0)" \
  "RED: rejected unbound plan commands must not journal a pin they could not store"

# ---------------------------------------------------------------------------
# P -- `--pin` writes the table down, once, bound to the attempt AND the
# candidate; a second `--pin` is a no-op an idempotent driver can make every
# pass.
# ---------------------------------------------------------------------------
mk_p_task TP1
planP="$("$ORCHID_BIN" jobs review-plan TP1 --pin)"
assert_eq "$TWO_ENGINE_PLAN" "$planP" "--pin returns the table it pinned"
pinP="$repoP/.orchid/reviews/TP1-a1.review-plan.json"
[ -f "$pinP" ] || fail "--pin writes the plan down for the attempt"
assert_eq "$head_p" "$(jq -r .candidate_sha "$pinP")" "the pin records the candidate it was taken for"
assert_eq 1 "$(jq -r .attempt "$pinP")" "...and the attempt"
assert_eq inline "$(jq -r '.slots[0].depth' "$pinP")" "the pin persists slot 1's inline depth"
assert_eq worktree "$(jq -r '.slots[1].depth' "$pinP")" "the pin persists slot 2's worktree depth"
assert_eq orchid/agy "$(jq -r '.slots[0].qid' "$pinP")" \
  "...and the qualified id each slot's engine NAME resolved to, which is the key its filed review is matched by"
assert_eq orchid/codex-review "$(jq -r '.slots[1].qid' "$pinP")" "...for every slot"
assert_eq 1 "$(p_pin_lines TP1)" "pinning a plan is journaled"
assert_eq "$planP" "$("$ORCHID_BIN" jobs review-plan TP1 --pin)" "a second --pin returns the same table"
assert_eq 1 "$(p_pin_lines TP1)" \
  "...and journals nothing the second time: an idempotent pin lets the driver call it every pass without narrating a change that did not happen"

# The bare form is still read-only and unfenced -- an operator can ask what
# the plan is from anywhere, exactly as before.
assert_eq "$planP" "$(ORCHID_EPOCH='' "$ORCHID_BIN" jobs review-plan TP1)" \
  "the bare read needs no epoch and returns the pinned table"

# A plan pinned before a column existed -- by T039 before the depth column, or
# before the attribution key was frozen beside it -- has the same leading
# fields and nothing else. Its bare read remains read-only and normalizes the
# missing columns from the installed engine manifests; the next writing --pin
# migrates the durable record once, with a journal entry, so neither becomes a
# live value that can move under already-filed evidence.
jq 'del(.slots[].depth) | del(.slots[].qid)' "$pinP" > "$pinP.legacy" && mv "$pinP.legacy" "$pinP"
assert_eq "$planP" "$(ORCHID_EPOCH='' "$ORCHID_BIN" jobs review-plan TP1)" \
  "a legacy three-column pin remains readable as the same five-column table"
assert_eq 0 "$(jq '[.slots[] | has("depth"), has("qid")] | map(select(.)) | length' "$pinP")" \
  "and the bare read did not mutate that legacy durable record"
assert_eq "$planP" "$("$ORCHID_BIN" jobs review-plan TP1 --pin)" \
  "a writing --pin migrates the legacy record without changing its effective routing"
assert_eq worktree "$(jq -r '.slots[1].depth' "$pinP")" \
  "and persists the derived worktree depth instead of re-deriving it on every read"
assert_eq orchid/codex-review "$(jq -r '.slots[1].qid' "$pinP")" \
  "...and the derived attribution key with it, in the same one write"
assert_eq 2 "$(p_pin_lines TP1)" \
  "the one schema migration is journaled exactly once"

# ---------------------------------------------------------------------------
# Q -- THE RED CASE. The engine that filed slot 1's review reaches its
# consecutive-failure threshold AFTERWARDS. Live routing moves; the pin does
# not; and the review that engine already filed still counts for the slot it
# was dispatched for.
# ---------------------------------------------------------------------------
ledger_mark "$repoP" agy failed
ledger_mark "$repoP" agy failed
ledger_mark "$repoP" agy failed
ledger_available "$repoP" agy && fail "fixture: three consecutive failures must make agy ledger-unavailable"

liveP="$(review_routing "$repoP" TP1)"
[ "$liveP" != "$planP" ] \
  || fail "fixture: live routing must have MOVED off the failing engine, or nothing below proves anything"
assert_eq "$planP" "$("$ORCHID_BIN" jobs review-plan TP1)" \
  "the pinned plan outlives its engine's health: a read still returns the table this attempt was dispatched against"

mk_p_review TP1 "" orchid/agy
mk_p_review TP1 ".2" orchid/codex-review
assert_eq "" "$(review_plan_unsatisfied "$repoP" TP1 "$(review_plan "$repoP" TP1)")" \
  "every pinned slot is credited: a review filed BEFORE its engine failed still counts for the slot it was dispatched for"
[ -n "$(review_plan_unsatisfied "$repoP" TP1 "$liveP")" ] \
  || fail "RED: against the LIVE table those same two reviews leave a slot uncredited — that is the dead end the pin closes, and if it no longer reproduces this comparison proves nothing"

# ---------------------------------------------------------------------------
# R -- `--adopt-evidence` REFUSES to buy a task its exit. Two reviews from one
# engine cannot be adopted into a plan that routed two different ones: that is
# exactly the same-engine pair the independence policy exists to refuse.
# ---------------------------------------------------------------------------
ledger_mark "$repoP" agy ok   # a healthy ledger again, so TP2 really routes two engines
mk_p_task TP2
planR="$("$ORCHID_BIN" jobs review-plan TP2 --pin)"
assert_eq "$TWO_ENGINE_PLAN" "$planR" "fixture: TP2's plan routes two DIFFERENT engines"
mk_p_review TP2 "" orchid/codex-review
mk_p_review TP2 ".2" orchid/codex-review
rc=0; err="$("$ORCHID_BIN" jobs review-plan TP2 --adopt-evidence 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "--adopt-evidence must refuse two reviews from ONE engine into a two-engine plan"
assert_match "lower the tier's engine independence" "$err" "...and names which of its two conditions failed"
assert_eq "$planR" "$("$ORCHID_BIN" jobs review-plan TP2)" "a refused adoption leaves the pin exactly as it was"

# The other refusal: a slot with no review at all is DISPATCHED, not adopted.
mk_p_task TP5
"$ORCHID_BIN" jobs review-plan TP5 --pin >/dev/null
mk_p_review TP5 "" orchid/agy
rc=0; err="$("$ORCHID_BIN" jobs review-plan TP5 --adopt-evidence 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "--adopt-evidence must refuse when there are fewer reviews than slots"
assert_match "must be dispatched, not adopted" "$err" "...and says so"

# ---------------------------------------------------------------------------
# S -- and ACCEPTS the case it exists for: a plan whose slots no longer match
# the engines that actually reviewed, where adopting them costs no
# independence at all. This is the exit for a task already wedged in that
# state, and it is a verb, not an operator editing durable state by hand.
# ---------------------------------------------------------------------------
mk_p_task TP3
"$ORCHID_BIN" jobs review-plan TP3 --pin >/dev/null
mk_p_review TP3 "" orchid/codex-review
mk_p_review TP3 ".2" orchid/claude
[ -n "$(review_plan_unsatisfied "$repoP" TP3 "$(review_plan "$repoP" TP3)")" ] \
  || fail "fixture: TP3 must start WEDGED — evidence its pinned plan cannot credit"

# FILING order, not GLOB order, and the two really do differ here. `jobs
# reconcile` names a second envelope for the same attempt `<base>.2.json`
# (libexec/orchid-jobs), and `.2.json` sorts BEFORE `.json` -- '2' precedes
# 'j' -- so the shell hands back the review that was filed SECOND first.
# Adoption credits the i-th review to slot i, so reading the glob raw would
# transpose the adopted table against its own evidence. Asserted here on its
# own, ahead of the table, so a regression names the cause rather than
# surfacing as two engines in the wrong slots.
assert_eq "$(printf 'orchid/codex-review\norchid/claude')" "$(review_filed_engines "$repoP" TP3)" \
  "filed reviews are read in the order reconcile filed them (TP3-a1-reviewer.json, then TP3-a1-reviewer.2.json), never in the order the shell globs them"

adoptS="$("$ORCHID_BIN" jobs review-plan TP3 --adopt-evidence)"
assert_eq "$(printf '1\tcodex-review\tengine-independent\tworktree\torchid/codex-review\n2\tclaude\tengine-independent\tworktree\torchid/claude')" "$adoptS" \
  "--adopt-evidence re-pins the slots onto the engines that actually filed the reviews, in the order they were filed, and freezes the key each one is credited by"
assert_eq "" "$(review_plan_unsatisfied "$repoP" TP3 "$(review_plan "$repoP" TP3)")" \
  "and the wedge is gone: every slot now has a review of its own"
assert_match "review plan pinned for attempt 1 \(adopt\)" "$(p_journal TP3)" \
  "the adoption is recorded, with the table it landed"

# ---------------------------------------------------------------------------
# T -- `--repin` moves ONLY the slots nobody has reviewed. A repin that
# recomputed every row would re-route a covered slot and orphan its review a
# second time -- the defect, offered as its own remedy.
# ---------------------------------------------------------------------------
mk_p_task TP4
planT="$("$ORCHID_BIN" jobs review-plan TP4 --pin)"
assert_eq "$TWO_ENGINE_PLAN" "$planT" "fixture: TP4 pins agy (slot 1) and codex-review (slot 2)"
mk_p_review TP4 "" orchid/agy
ledger_mark "$repoP" codex-review failed
ledger_mark "$repoP" codex-review failed
ledger_mark "$repoP" codex-review failed
ledger_available "$repoP" codex-review && fail "fixture: codex-review must be ledger-unavailable for the repin to have anything to move"
repinT="$("$ORCHID_BIN" jobs review-plan TP4 --repin)"
assert_match $'^1\tagy\tengine-independent\tinline\torchid/agy$' "$repinT" \
  "--repin FREEZES the slot that already has a review of its own, key included, whatever live routing now prefers"
assert_match $'^2\tcodex\tsession-independent\tworktree\torchid/codex$' "$repinT" \
  "and rebinds only the unfilled slot onto the live worktree-capable fallback — labeled session-independent because it is the implementer's engine (got: $repinT)"
ledger_mark "$repoP" codex-review ok

# ---------------------------------------------------------------------------
# U -- adoption preserves independence even with EXTRA evidence. Checking
# distinctness across every filed envelope and then taking the first N is not
# enough: A,A,B contains two distinct engines, but its first two do not.
# ---------------------------------------------------------------------------
mk_p_task TP7
planU="$("$ORCHID_BIN" jobs review-plan TP7 --pin)"
assert_eq "$TWO_ENGINE_PLAN" "$planU" "fixture: TP7 requires two distinct engines"
mk_p_review TP7 "" orchid/codex-review
mk_p_review TP7 ".2" orchid/codex-review
mk_p_review TP7 ".3" orchid/claude
adoptU="$("$ORCHID_BIN" jobs review-plan TP7 --adopt-evidence)"
assert_eq "$(printf '1\tcodex-review\tengine-independent\tworktree\torchid/codex-review\n2\tclaude\tengine-independent\tworktree\torchid/claude')" "$adoptU" \
  "A,A,B evidence adopts the first two DISTINCT engines A,B, not the first two envelopes A,A"
assert_eq "" "$(review_plan_unsatisfied "$repoP" TP7 "$(review_plan "$repoP" TP7)")" \
  "and both independently adopted slots are credited by evidence already on disk"

# ---------------------------------------------------------------------------
# V -- JOURNAL FIRST. Failure injection stubs only the journal verb while the
# review-plan destination remains writable. A write-before-journal
# implementation leaves the pin behind and this RED case catches it; the same
# command with the real journal restored is the GREEN twin.
# ---------------------------------------------------------------------------
mk_p_task TP6
pinV="$(review_plan_file "$repoP" TP6)"
journal_bin="$REPO_ROOT/libexec/orchid-journal"
journal_backup="$WORK/orchid-journal.backup"
cp "$journal_bin" "$journal_backup"
rc_file="$WORK/orchid-journal.rc"
err_file="$WORK/orchid-journal.err"
(
  trap 'cp "$journal_backup" "$journal_bin"; chmod +x "$journal_bin"' EXIT
  printf '#!/usr/bin/env bash\nexit 71\n' > "$journal_bin"
  chmod +x "$journal_bin"
  injected_rc=0
  "$ORCHID_BIN" jobs review-plan TP6 --pin > /dev/null 2> "$err_file" || injected_rc=$?
  printf '%s\n' "$injected_rc" > "$rc_file"
)
rc="$(cat "$rc_file")"
errV="$(cat "$err_file")"

[ "$rc" -ne 0 ] || fail "RED: --pin must fail when its required journal record fails"
[ ! -e "$pinV" ] \
  || fail "RED: a failed journal write must leave no review-plan mutation behind"
assert_match "cannot journal the review-plan change" "$errV" \
  "the refusal identifies the journal-first failure and says no plan was written"

planV="$("$ORCHID_BIN" jobs review-plan TP6 --pin)"
assert_eq "$TWO_ENGINE_PLAN" "$planV" \
  "GREEN: with the journal restored, the same computed plan is accepted"
[ -f "$pinV" ] || fail "GREEN: the journaled review plan is then stored"
diff -q "$journal_bin" "$journal_backup" >/dev/null 2>&1 \
  || fail "the journal executable must be restored byte-for-byte after failure injection"
# P -- T033 (dogfood F32, reproduced independently in r-002): the review
# policy's own record must carry a non-approve verdict's SUBSTANCE.
#
# The boundary record used to read `<file>:verdict=request-changes` and
# nothing else. On both runs that hit this shape the actionable defect was
# sitting in the envelope's free-text `summary`, and the operator found it
# only by hand-jq-ing the raw file -- with the structured `findings[]` the
# severity gate consults sitting empty the whole time. This detail line is
# what `runners/orchid-drive` turns into the `review-conflict` boundary's
# reason, so it is where both facts have to appear: that the gate was handed
# an empty array, and what the reviewer actually objected to.
#
# Read STRUCTURALLY as well as by content: the decision is one TAB-separated
# line, split by `cut -f1`/`cut -f2-` at its only caller, so a summary
# carrying a newline or a tab must be folded before it goes anywhere near it.
# ===========================================================================
# drive_review_decision reads task frontmatter, lib/review.sh's required
# count and lib/envelope.sh's readers -- all of which this file already
# sources. It touches none of drive.sh's archetype/schedule/hooks callers, so
# the four sources above are the whole dependency for this Part.
source "$REPO_ROOT/lib/drive.sh"

repoP="$WORK/repoP"; mkdir -p "$repoP/.orchid/tasks" "$repoP/.orchid/reviews"
candP=3333333333333333333333333333333333333333

# mk_p_task <id> <blocking_severity> -- risk_tier low, so ONE review is the
# whole required set and the decision turns on that envelope alone.
mk_p_task() {
  printf -- '---\nschema: 1\nid: %s\nstatus: arbitrating\narchetype: feature\nattempts: 0\nrisk_tier: low\nblocking_severity: %s\ncandidate_sha: %s\n---\nbody\n' \
    "$1" "$2" "$candP" > "$repoP/.orchid/tasks/$1.md"
}

# A summary with a newline AND a tab in it, exactly the two characters that
# would corrupt the record this text is about to travel in.
objectionP="$(printf 'prepareBackupAttempt() can return run_id 0 after a best-effort startRun() failure,\nyet the handler still\tflushes started')"

mk_p_task TP1 high
jq -n --arg cand "$candP" --arg s "$objectionP" \
  '{contract:1, job_id:"j-p1", task:"TP1", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:$s,
    candidate_sha:$cand, findings:[]}' \
  > "$repoP/.orchid/reviews/TP1-a1-reviewer.json"

decisionP="$(drive_review_decision "$repoP" TP1)"
assert_eq conflict "$(printf '%s' "$decisionP" | cut -f1)" \
  "a request-changes verdict is a conflict, findings[] empty or not"
detailP="$(printf '%s' "$decisionP" | cut -f2-)"
assert_match "verdict=request-changes" "$detailP" "the record still names the verdict that blocked approval"
assert_match "findings=0" "$detailP" \
  "and says the severity gate was handed an empty array, rather than leaving that to be inferred from silence"
assert_match "prepareBackupAttempt" "$detailP" \
  "the objection itself reaches the record the arbiter is shown -- no jq of the raw envelope required"
assert_match "summary:" "$detailP" "and is labelled as the reviewer's summary, not as a finding it never filed"
assert_eq 1 "$(printf '%s\n' "$decisionP" | wc -l | tr -d ' ')" \
  "the decision stays ONE line: a summary's newline must never split the record its caller reads with cut"
assert_eq 2 "$(printf '%s\n' "$decisionP" | awk -F'\t' '{print NF}')" \
  "and exactly two TAB fields: a summary's tab must never shift the fields after it"
red_case "a request-changes envelope with an empty findings[] and a prose-only objection: the decision record names findings=0 and carries the prose, instead of reporting a bare verdict and a gate that weighed nothing"

# The twin: an approving, scope-complete review with the same empty findings[]
# is the ordinary output of every verdict-only adapter. It approves, and
# nothing is dragged out of its summary into a record it does not belong in.
mk_p_task TP2 high
jq -n --arg cand "$candP" \
  '{contract:1, job_id:"j-p2", task:"TP2", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"scope covered, nothing to report",
    candidate_sha:$cand, findings:[]}' \
  > "$repoP/.orchid/reviews/TP2-a1-reviewer.json"

decisionP2="$(drive_review_decision "$repoP" TP2)"
assert_eq approve "$(printf '%s' "$decisionP2" | cut -f1)" \
  "an approving review with no findings still approves: an empty array is not itself a signal"
detailP2="$(printf '%s' "$decisionP2" | cut -f2-)"
assert_match "unanimous scope-complete approval from 1 review" "$detailP2" \
  "and the approval verdict clause itself is unchanged"
case "$detailP2" in
  *"nothing to report"*) fail "an approving review's summary must not be spliced into the approval record" ;;
esac
green_case "an approving review with an empty findings[] approves, with its summary left where the reviewer put it"
# ...but the line must not stop at "no finding at or above high", because that
# reads identically whether the gate weighed findings that all ranked below the
# threshold or weighed an EMPTY ARRAY, as here. That is the same one-empty-list-
# two-answers defect as the prose-only objection above, in the arm that
# APPROVES -- the arm where nobody is woken to go and look.
assert_match "NO findings were filed across those 1 review" "$detailP2" \
  "a deterministic approval must say when the severity gate was handed nothing at all, not report a threshold it never weighed anything against"
assert_match "severity gate weighed an empty array" "$detailP2" \
  "and say so in those terms, so the operator is not left to infer it from a clean-looking threshold clause"
assert_match "rests on verdict [+] scope_complete alone" "$detailP2" \
  "and name what the approval actually rests on when the gate is inert -- the verdict-only adapters' ordinary case"
red_case "a deterministic approval backed by ZERO structured findings: the record says the severity gate weighed an empty array, instead of reporting 'no finding at or above high' as though it had weighed something"

# The twin of the twin, and the reason the disclosure above is a COUNT rather
# than an alarm: an approving review that did file findings, none of which
# reach this task's blocking_severity, is a gate that genuinely weighed
# something and let it through. It must read differently from the empty one.
mk_p_task TP4 high
jq -n --arg cand "$candP" \
  '{contract:1, job_id:"j-p4", task:"TP4", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"one nit, not blocking",
    candidate_sha:$cand,
    findings:[{severity:"low", title:"a nit below the threshold"}]}' \
  > "$repoP/.orchid/reviews/TP4-a1-reviewer.json"

decisionP4="$(drive_review_decision "$repoP" TP4)"
assert_eq approve "$(printf '%s' "$decisionP4" | cut -f1)" \
  "a filed finding BELOW blocking_severity does not block: the threshold is what gates, and the count is only disclosure"
detailP4="$(printf '%s' "$decisionP4" | cut -f2-)"
assert_match "no finding at or above high" "$detailP4" \
  "the threshold clause is unchanged when the gate had something to weigh"
assert_match "1 finding[(]s[)] filed across those 1 review[(]s[)] and weighed against it" "$detailP4" \
  "and the record says how much it weighed, so this approval is distinguishable from one backed by an empty array"
case "$detailP4" in
  *"weighed an empty array"*)
    fail "a review that DID file a finding must not be reported as one the gate weighed nothing for -- the disclosure would then be noise on every approval" ;;
  *"a nit below the threshold"*)
    fail "a non-blocking finding's title must not be spliced into the approval record: the conflict arm names what BLOCKED, this arm only counts" ;;
esac
assert_eq 2 "$(printf '%s\n' "$decisionP4" | awk -F'\t' '{print NF}')" \
  "and the approval stays a two-field TAB record like every other arm"
green_case "an approving review with one below-threshold finding approves, and its record reports one finding weighed rather than an empty gate"

# The OTHER half of the same complaint, and the case where the record is the
# only warning there is. Every verdict said `approve`; a filed finding at or
# above blocking_severity stopped the pass anyway. The record used to say
# `<file>:finding>=medium` -- that the gate weighed something, never what --
# so the arbiter it wakes had the same trip to `jq` ahead of it that the bare
# `verdict=request-changes` record sent two dogfood operators on.
#
# Two findings, deliberately: the WORST one is named, and it is filed SECOND,
# so a record that simply took findings[0] would name the wrong one. And the
# title carries the same newline-and-tab payload as the summary above, because
# a finding title is engine-written free text travelling in the same
# TAB-separated line -- a fold that covered only `summary` would leave the
# record corruptible through `title`.
mk_p_task TP3 medium
titleP="$(printf 'run_id 0 is flushed as\tstarted before the row\nis committed')"
jq -n --arg cand "$candP" --arg t "$titleP" \
  '{contract:1, job_id:"j-p3", task:"TP3", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"looks fine to me",
    candidate_sha:$cand,
    findings:[{severity:"medium", title:"a lesser one, filed first"},
              {severity:"high", title:$t}]}' \
  > "$repoP/.orchid/reviews/TP3-a1-reviewer.json"

decisionP3="$(drive_review_decision "$repoP" TP3)"
assert_eq conflict "$(printf '%s' "$decisionP3" | cut -f1)" \
  "a finding at or above blocking_severity is a conflict even when every verdict approved"
detailP3="$(printf '%s' "$decisionP3" | cut -f2-)"
assert_match "finding>=medium" "$detailP3" "the record still names the threshold the gate applied"
assert_match "run_id 0 is flushed as started before the row is committed" "$detailP3" \
  "and names the finding that tripped it, folded to one line -- the arbiter is not sent to the raw envelope"
case "$detailP3" in
  *"a lesser one, filed first"*)
    fail "the record must name the WORST blocking finding, not whichever one the reviewer filed first" ;;
esac
assert_eq 1 "$(printf '%s\n' "$decisionP3" | wc -l | tr -d ' ')" \
  "the decision stays ONE line: a finding title's newline must never split the record its caller reads with cut"
assert_eq 2 "$(printf '%s\n' "$decisionP3" | awk -F'\t' '{print NF}')" \
  "and exactly two TAB fields: a finding title's tab must never shift the fields after it"
red_case "an approving review whose filed finding blocks: the decision record names the worst blocking finding, instead of reporting a bare threshold the arbiter has to jq the envelope to understand"

# THE THIRD ENTRY THIS RECORD CAN EMIT, and the one the two cases above leave
# bare. `scope_complete: false` is a reviewer reporting it did not cover the
# whole change; WHICH part it could not reach is free text in the very same
# `summary` the verdict arm lifts. It fires on its own whenever the review
# APPROVED what it did read -- so, exactly as with the blocking-finding entry
# above, that entry is then the whole of what the arbiter is told, and a bare
# `scope_complete=false` sends them back to `jq` for the one sentence that says
# what is missing. Same newline-and-tab payload, because this arm shares the
# TAB-separated record with the other two.
mk_p_task TP5 high
scopeP="$(printf 'the generated migration under db/migrate was not read at all:\nit is the only caller of\tprepareBackupAttempt()')"
jq -n --arg cand "$candP" --arg s "$scopeP" \
  '{contract:1, job_id:"j-p5", task:"TP5", operation:"review", status:"ok",
    verdict:"approve", scope_complete:false, summary:$s,
    candidate_sha:$cand, findings:[]}' \
  > "$repoP/.orchid/reviews/TP5-a1-reviewer.json"

decisionP5="$(drive_review_decision "$repoP" TP5)"
assert_eq conflict "$(printf '%s' "$decisionP5" | cut -f1)" \
  "a review that reports incomplete scope is a conflict even though its verdict approved"
detailP5="$(printf '%s' "$decisionP5" | cut -f2-)"
assert_match "scope_complete=false" "$detailP5" "the record still names the structured field that produced the decision"
# Bracketed parens: assert_match is `grep -Eq`, where a bare `()` is an empty
# GROUP and would match the name with no parentheses after it at all.
assert_match "the generated migration under db/migrate was not read at all: it is the only caller of prepareBackupAttempt[(][)]" "$detailP5" \
  "and carries the reviewer's own account of what it could not reach, folded to one line -- this entry is the whole of what the arbiter is told"
assert_match "summary:" "$detailP5" "labelled as the reviewer's summary, not as a finding it never filed"
assert_eq 1 "$(printf '%s\n' "$decisionP5" | wc -l | tr -d ' ')" \
  "the decision stays ONE line: a summary's newline must never split the record its caller reads with cut"
assert_eq 2 "$(printf '%s\n' "$decisionP5" | awk -F'\t' '{print NF}')" \
  "and exactly two TAB fields: a summary's tab must never shift the fields after it"
red_case "an approving review that reports scope_complete=false: the decision record carries the summary saying WHAT was left uncovered, instead of a bare field name the arbiter has to jq the envelope to understand"

# ...and ONCE, not once per arm. A review that both withholds approval and
# reports incomplete scope emits two entries; the summary belongs to the
# envelope, not to either entry, so repeating it would pad the boundary reason
# with a duplicate rather than tell the arbiter anything new.
mk_p_task TP6 high
jq -n --arg cand "$candP" --arg s "$objectionP" \
  '{contract:1, job_id:"j-p6", task:"TP6", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:false, summary:$s,
    candidate_sha:$cand, findings:[]}' \
  > "$repoP/.orchid/reviews/TP6-a1-reviewer.json"

decisionP6="$(drive_review_decision "$repoP" TP6)"
detailP6="$(printf '%s' "$decisionP6" | cut -f2-)"
assert_match "verdict=request-changes" "$detailP6" "both entries are still emitted: the verdict one..."
assert_match "scope_complete=false" "$detailP6" "...and the scope one"
assert_eq 1 "$(grep -o -e '(summary: ' <<<"$detailP6" | wc -l | tr -d ' ')" \
  "but the envelope's one summary is carried exactly once across them, not repeated per entry"
green_case "a review that both rejects and reports incomplete scope emits both entries and quotes its summary once"
