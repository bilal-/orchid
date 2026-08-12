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

# D -- a discovered but role-ineligible override (agy, structured_text only,
# for the implementer role which requires workspace_write/shell/git) is
# refused with exit 14 via the same role_eligibility_reason walk resolve_
# role_checked/resolve_role_available already use.
rc=0; err="$("$ORCHID_BIN" jobs prepare TB implementer implement --engine agy 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" "prepare --engine refuses an ineligible engine with exit 14"
assert_match "missing required capability workspace_write" "$err" "prepare --engine names the missing capability"

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
assert_match $'^1\tagy\tengine-independent$' "$outF" "low tier: slot 1 is agy, engine-independent (differs from codex implementer)"

# G -- medium-tier task -> two distinct slots; slot 2 prefers the worktree-
# capable engine (codex-review declares workspace_read; agy does not).
"$ORCHID_BIN" task create TR2 demo >/dev/null
"$ORCHID_BIN" task set TR2 risk_tier medium --reason "touches shared code" >/dev/null
outG="$("$ORCHID_BIN" jobs review-plan TR2)"
assert_eq 2 "$(echo "$outG" | wc -l | tr -d ' ')" "medium tier: review-plan prints exactly two slots"
assert_match $'^1\tagy\tengine-independent$' "$outG" "medium tier: slot 1 is agy, engine-independent"
assert_match $'^2\tcodex-review\tengine-independent$' "$outG" "medium tier: slot 2 is codex-review (worktree-capable, distinct from slot 1), engine-independent"

# H -- when every candidate OTHER than the implementer's own engine is
# unavailable, the slot falls back to the implementer's engine, labeled
# session-independent -- NEVER silently, and never zero slots.
ledger_mark "$repoR" agy rate_limited 999999
ledger_mark "$repoR" codex-review rate_limited 999999
"$ORCHID_BIN" task create TR3 demo >/dev/null
outH="$("$ORCHID_BIN" jobs review-plan TR3)"
assert_match $'^1\tcodex\tsession-independent$' "$outH" "only the implementer's engine available -> session-independent fallback (never silent)"

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
"$ORCHID_BIN" verify TW1 >/dev/null
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

TWO_ENGINE_PLAN="$(printf '1\tagy\tengine-independent\n2\tcodex-review\tengine-independent')"

# ---------------------------------------------------------------------------
# P -- `--pin` writes the table down, once, bound to the attempt AND the
# candidate; a second `--pin` is a no-op an idempotent driver can make every
# pass.
# ---------------------------------------------------------------------------
mk_p_task TP1
planP="$("$ORCHID_BIN" jobs review-plan TP1 --pin)"
assert_eq "$TWO_ENGINE_PLAN" "$planP" "--pin returns the table it pinned"
pinP="$repoP/.orchid/reviews/TP1-a1-review-plan.json"
[ -f "$pinP" ] || fail "--pin writes the plan down for the attempt"
assert_eq "$head_p" "$(jq -r .candidate_sha "$pinP")" "the pin records the candidate it was taken for"
assert_eq 1 "$(jq -r .attempt "$pinP")" "...and the attempt"
assert_eq 1 "$(p_pin_lines TP1)" "pinning a plan is journaled"
assert_eq "$planP" "$("$ORCHID_BIN" jobs review-plan TP1 --pin)" "a second --pin returns the same table"
assert_eq 1 "$(p_pin_lines TP1)" \
  "...and journals nothing the second time: an idempotent pin lets the driver call it every pass without narrating a change that did not happen"

# The bare form is still read-only and unfenced -- an operator can ask what
# the plan is from anywhere, exactly as before.
assert_eq "$planP" "$(ORCHID_EPOCH='' "$ORCHID_BIN" jobs review-plan TP1)" \
  "the bare read needs no epoch and returns the pinned table"

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
adoptS="$("$ORCHID_BIN" jobs review-plan TP3 --adopt-evidence)"
assert_eq "$(printf '1\tcodex-review\tengine-independent\n2\tclaude\tengine-independent')" "$adoptS" \
  "--adopt-evidence re-pins the slots onto the engines that actually filed the reviews, in the order they were filed"
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
assert_match $'^1\tagy\tengine-independent$' "$repinT" \
  "--repin FREEZES the slot that already has a review of its own, whatever live routing now prefers"
assert_match $'^2\tagy\tsession-independent$' "$repinT" \
  "and rebinds only the unfilled slot — labeled session-independent, because one engine covering two slots is degraded independence however it was arrived at"
ledger_mark "$repoP" codex-review ok
