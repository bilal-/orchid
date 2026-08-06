#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/hooks.sh"; source "$REPO_ROOT/lib/envelope.sh"

cd_scratch "$WORK" || exit 1; mkdir -p .orchid
export ORCHID_REPO="$WORK"

# ---------------------------------------------------------------------------
# hooks_for: ordered `hook.<point>=` binding parsing, one "id<TAB>required|
# optional" line per entry, order preserved. An unbound point prints nothing.
# ---------------------------------------------------------------------------
printf 'hook.before_merge=alpha:required,beta,gamma:required\n' > orchid.config
out="$(hooks_for "$WORK" before_merge)"
expected="$(printf 'alpha\trequired\nbeta\toptional\ngamma\trequired')"
assert_eq "$expected" "$out" "hooks_for parses an ordered binding with required flags, order preserved"

empty_out="$(hooks_for "$WORK" on_blocker)"
assert_eq "" "$empty_out" "hooks_for on an unbound point prints nothing"

# single, unflagged entry -> optional
printf 'hook.on_verify_fail=solo\n' >> orchid.config
solo_out="$(hooks_for "$WORK" on_verify_fail)"
assert_eq "$(printf 'solo\toptional')" "$solo_out" "hooks_for single unflagged entry is optional"

# ---------------------------------------------------------------------------
# hook_point_valid: the closed, kernel-owned set.
# ---------------------------------------------------------------------------
for p in after_plan_draft before_arbitration on_verify_fail before_merge on_blocker; do
  hook_point_valid "$p" || fail "hook_point_valid must accept kernel point '$p'"
done
if hook_point_valid bogus_point; then fail "hook_point_valid must reject an unknown point"; fi
if hook_point_valid ""; then fail "hook_point_valid must reject the empty string"; fi

# ---------------------------------------------------------------------------
# hook_timeout_s: default 600, config-overridable.
# ---------------------------------------------------------------------------
rm -f orchid.config
assert_eq "600" "$(hook_timeout_s "$WORK")" "hook_timeout_s default is 600"
printf 'hook_timeout_s=120\n' > orchid.config
assert_eq "120" "$(hook_timeout_s "$WORK")" "hook_timeout_s honors config override"
rm -f orchid.config

# ---------------------------------------------------------------------------
# manifest_validate: kind=hook is validated with the SAME fields as
# kind=engine (entrypoint required, capabilities checked against the atom
# list) -- not a distinct schema.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/hookplug"
printf 'manifest_version=1\nid=test/hookplug\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$WORK/hookplug/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/hookplug/run"; chmod +x "$WORK/hookplug/run"
manifest_validate "$WORK/hookplug" >/dev/null || fail "kind=hook manifest with entrypoint+capabilities validates"

mkdir -p "$WORK/hookplug_noent"
printf 'manifest_version=1\nid=test/hookplug2\nversion=0.1.0\nkind=hook\napi_version=1\n' \
  > "$WORK/hookplug_noent/plugin.conf"
manifest_validate "$WORK/hookplug_noent" >/dev/null 2>&1 && fail "kind=hook manifest missing entrypoint must fail (same rule as kind=engine)"

mkdir -p "$WORK/hookplug_badcap"
printf 'manifest_version=1\nid=test/hookplug3\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=not_a_real_atom\nentrypoint=run\n' \
  > "$WORK/hookplug_badcap/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/hookplug_badcap/run"; chmod +x "$WORK/hookplug_badcap/run"
manifest_validate "$WORK/hookplug_badcap" >/dev/null 2>&1 && fail "kind=hook manifest with an unknown capability atom must fail (same rule as kind=engine)"

# ---------------------------------------------------------------------------
# envelope union: operation=="hook" ok requires .artifact (object) + .summary
# (non-empty string).
# ---------------------------------------------------------------------------
echo '{"contract":1,"job_id":"j-1","task":"T001","operation":"hook","status":"ok","artifact":{"guidance":"x"},"summary":"did hook"}' > "$WORK/e-good.json"
envelope_validate "$WORK/e-good.json" || fail "hook ok envelope with artifact(object)+summary accepted"

echo '{"contract":1,"job_id":"j-2","task":"T001","operation":"hook","status":"ok","summary":"did hook"}' > "$WORK/e-noartifact.json"
envelope_validate "$WORK/e-noartifact.json" 2>/dev/null && fail "hook ok envelope missing artifact rejected"

echo '{"contract":1,"job_id":"j-3","task":"T001","operation":"hook","status":"ok","artifact":{"guidance":"x"}}' > "$WORK/e-nosummary.json"
envelope_validate "$WORK/e-nosummary.json" 2>/dev/null && fail "hook ok envelope missing summary rejected"

echo '{"contract":1,"job_id":"j-4","task":"T001","operation":"hook","status":"ok","artifact":"nope","summary":"x"}' > "$WORK/e-badartifact.json"
envelope_validate "$WORK/e-badartifact.json" 2>/dev/null && fail "hook ok envelope with non-object artifact rejected"

echo '{"contract":1,"job_id":"j-5","task":"T001","operation":"hook","status":"failed"}' > "$WORK/e-failed.json"
envelope_validate "$WORK/e-failed.json" || fail "hook failed status needs no payload"

# ===========================================================================
# CLI-level fixture: jobs prepare/reconcile + orchid-launch round trip.
# ===========================================================================
cd_scratch "$WORK" || exit 1; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base_sha="$(git rev-parse HEAD)"
echo change >> f.txt; git add f.txt; git commit -q -m change
cand_sha="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks .orchid/reviews
export HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"
printf 'verify=true\n' > orchid.config
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create T001 demo >/dev/null
"$ORCHID_BIN" task set T001 base_sha "$base_sha" >/dev/null
"$ORCHID_BIN" task set T001 candidate_sha "$cand_sha" >/dev/null

# a bound plugin declared kind=hook -- the primary handler for before_merge.
mkdir -p "$WORK/eng/stubhook"
printf 'manifest_version=1\nid=test/stubhook\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$WORK/eng/stubhook/plugin.conf"
cat > "$WORK/eng/stubhook/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
pack="$(jq -r .input_pack "$req")"
[ -f "$pack/task.md" ] || exit 1
[ -f "$pack/diff.patch" ] || exit 1
grep -q "change" "$pack/diff.patch" || exit 1
[ "$(jq -r .operation "$req")" = hook ] || exit 1
[ "$(jq -r .hook_point "$req")" = before_merge ] || exit 1
[ "$(jq -r .policy "$req")" = read-only ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"hook","status":"ok","artifact":{"guidance":"looks fine"},"summary":"stub hook ran"}' \
  "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/stubhook/run"
printf 'hook.before_merge=stubhook\n' >> orchid.config

# --- prepare --hook (no --engine): records the point + resolves the sole
# bound plugin, with no round of the role-chain resolver ever consulted. ---
mp="$("$ORCHID_BIN" jobs prepare T001 hook hook --hook before_merge)"
[ -f "$mp" ] || fail "hook manifest written at printed path"
assert_eq "before_merge" "$(jq -r .hook_point "$mp")" "hook manifest records hook_point"
assert_eq "stubhook" "$(jq -r .engine "$mp")" "hook manifest resolves the sole bound plugin by name"
assert_eq "hook" "$(jq -r .operation "$mp")" "hook manifest operation is 'hook'"
rm -f "$mp"

# --- unknown hook point -> die (nonzero, before any manifest is minted). ---
rc=0; err="$("$ORCHID_BIN" jobs prepare T001 hook hook --hook not_a_real_point 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "unknown hook point must die"
assert_match "unknown hook point" "$err" "unknown hook point die message names the point"

# --- --hook without operation=hook, and operation=hook without --hook. ---
rc=0; "$ORCHID_BIN" jobs prepare T001 hook implement --hook before_merge >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "--hook on a non-hook operation must die"
rc=0; "$ORCHID_BIN" jobs prepare T001 hook hook >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "operation=hook without --hook must die"

# --- an unbound point -> exit 14 ("no eligible engine"-shaped diagnostic). ---
rc=0; "$ORCHID_BIN" jobs prepare T001 hook hook --hook after_plan_draft >/dev/null 2>&1 || rc=$?
assert_eq "14" "$rc" "an unbound hook point exits 14"

# --- --engine naming a plugin NOT in the point's binding -> exit 14
# (config-is-policy: the name space for a hook point is exactly what config
# names, not "any discovered kind=engine|hook plugin"). ---
mkdir -p "$WORK/eng/notbound"
printf 'manifest_version=1\nid=test/notbound\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$WORK/eng/notbound/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/notbound/run"; chmod +x "$WORK/eng/notbound/run"
rc=0; err2="$("$ORCHID_BIN" jobs prepare T001 hook hook --hook before_merge --engine notbound 2>&1 1>/dev/null)" || rc=$?
assert_eq "14" "$rc" "--engine not bound to the point exits 14"
assert_match "not bound to hook point" "$err2" "not-bound die message names the point"

# --- a kind=engine plugin is ALSO accepted for a hook point (manifest_get
# kind = engine or hook), and --engine selecting it (when it IS bound)
# resolves cleanly. ---
mkdir -p "$WORK/eng/fakeengine"
printf 'manifest_version=1\nid=test/fakeengine\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nentrypoint=run\n' \
  > "$WORK/eng/fakeengine/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/fakeengine/run"; chmod +x "$WORK/eng/fakeengine/run"
printf 'hook.on_blocker=fakeengine\n' >> orchid.config
mp3="$("$ORCHID_BIN" jobs prepare T001 hook hook --hook on_blocker)"
assert_eq "fakeengine" "$(jq -r .engine "$mp3")" "a kind=engine plugin is accepted for a hook point"
rm -f "$mp3"

# --- a plugin whose kind is neither engine nor hook (e.g. kind=role), even
# though it IS named in the binding, is rejected. ---
mkdir -p "$WORK/eng/wrongkind"
printf 'manifest_version=1\nid=test/wrongkind\nversion=0.1.0\nkind=role\napi_version=1\n' \
  > "$WORK/eng/wrongkind/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/wrongkind/run"; chmod +x "$WORK/eng/wrongkind/run"
printf 'hook.before_arbitration=wrongkind\n' >> orchid.config
rc=0; err3="$("$ORCHID_BIN" jobs prepare T001 hook hook --hook before_arbitration 2>&1 1>/dev/null)" || rc=$?
assert_eq "14" "$rc" "a bound plugin of the wrong kind exits 14"
assert_match "kind=role" "$err3" "wrong-kind die message names the offending kind"

# ---------------------------------------------------------------------------
# Full round trip: runners/orchid-launch T001 <role> hook --hook before_merge
# -> jobs reconcile -> reviews/T001-a1-hook-before_merge.json (the role
# positional carries no meaning for a hook job -- the destination name is
# built from hook_point, never role).
# ---------------------------------------------------------------------------
launch_out="$("$REPO_ROOT/runners/orchid-launch" T001 hook hook --hook before_merge)"
assert_match "launched j-" "$launch_out" "hook launch reports a job id"
sleep 1
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "hook job reconciled ok"
dest="$WORK/.orchid/reviews/T001-a1-hook-before_merge.json"
[ -f "$dest" ] || fail "hook envelope filed at reviews/T001-a1-hook-before_merge.json"
assert_eq "looks fine" "$(jq -r '.artifact.guidance' "$dest")" "filed hook envelope keeps its artifact"
assert_eq "stub hook ran" "$(jq -r .summary "$dest")" "filed hook envelope keeps its summary"

req=""
for rf in "$WORK/.orchid/runtime/requests/"*.json; do
  [ "$(jq -r '.hook_point // empty' "$rf" 2>/dev/null)" = "before_merge" ] && req="$rf" && break
done
[ -n "$req" ] || fail "hook request document found under runtime/requests"
assert_eq "hook" "$(jq -r .operation "$req")" "hook request document operation=hook"
assert_eq "before_merge" "$(jq -r .hook_point "$req")" "hook request document carries hook_point"

# ---------------------------------------------------------------------------
# Malformed hook envelope (missing .artifact) dropped straight into spool ->
# quarantined as malformed, never filed to reviews/.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/.orchid/runtime/spool" "$WORK/.orchid/runtime/quarantine"
printf '{"contract":1,"job_id":"j-bad-hook","task":"T001","operation":"hook","status":"ok","summary":"no artifact here"}' \
  > "$WORK/.orchid/runtime/spool/j-bad-hook.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
list_dir_files "$WORK/.orchid/runtime/quarantine" \
  | grep -q "j-bad-hook.json.reason-malformed" \
  || fail "malformed hook envelope (missing artifact) quarantined"

# ---------------------------------------------------------------------------
# Third-party publisher: `jobs reconcile`'s engine cross-check must compare
# against the BOUND plugin's own manifest id, never an assumed
# "orchid/<name>" shape -- a third-party engine (dir name "foo", manifest
# `id=acme/foo`) whose adapter echoes its OWN qualified id back must
# reconcile cleanly, not be quarantined as a mismatch (critical fix,
# post-review: the pre-existing cross-check hardcoded "orchid/$m_engine").
# ---------------------------------------------------------------------------
mkdir -p "$WORK/eng/foo"
printf 'manifest_version=1\nid=acme/foo\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$WORK/eng/foo/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/foo/run"; chmod +x "$WORK/eng/foo/run"

mkdir -p "$WORK/.orchid/runtime/jobs" "$WORK/.orchid/runtime/spool" "$WORK/.orchid/runtime/quarantine"
jq -n --arg base "$base_sha" --arg cand "$cand_sha" \
  '{job_id:"j-thirdparty", task:"T001", attempt:9, role:"reviewer", operation:"review",
    engine:"foo", pid:0, pgid:0, started_at:0, log:"/dev/null", output:"/dev/null",
    base_sha:$base, candidate_sha:$cand, hook_point:""}' \
  > "$WORK/.orchid/runtime/jobs/j-thirdparty.json"
jq -n --arg base "$base_sha" --arg cand "$cand_sha" \
  '{contract:1, job_id:"j-thirdparty", task:"T001", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, engine:"acme/foo",
    base_sha:$base, candidate_sha:$cand}' \
  > "$WORK/.orchid/runtime/spool/j-thirdparty.json"

"$ORCHID_BIN" jobs reconcile >/dev/null
[ -f "$WORK/.orchid/reviews/T001-a9-reviewer.json" ] \
  || fail "a third-party publisher envelope (.engine=acme/foo, dir=foo) reconciles cleanly, not quarantined"
list_dir_files "$WORK/.orchid/runtime/quarantine" \
  | grep -q "j-thirdparty.json.reason-mismatch" \
  && fail "a third-party publisher envelope (.engine=acme/foo) must NOT be quarantined as a mismatch"

# Existing first-party fixtures stay green: a plain-name engine (no manifest
# dir discoverable under this name at all) still cross-checks against the
# "orchid/<name>" fallback shape, unchanged from before this fix.
jq -n --arg base "$base_sha" --arg cand "$cand_sha" \
  '{job_id:"j-firstparty", task:"T001", attempt:9, role:"reviewer", operation:"review",
    engine:"nosuchengine", pid:0, pgid:0, started_at:0, log:"/dev/null", output:"/dev/null",
    base_sha:$base, candidate_sha:$cand, hook_point:""}' \
  > "$WORK/.orchid/runtime/jobs/j-firstparty.json"
jq -n --arg base "$base_sha" --arg cand "$cand_sha" \
  '{contract:1, job_id:"j-firstparty", task:"T001", operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, engine:"orchid/nosuchengine",
    base_sha:$base, candidate_sha:$cand}' \
  > "$WORK/.orchid/runtime/spool/j-firstparty.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
[ -f "$WORK/.orchid/reviews/T001-a9-reviewer.2.json" ] \
  || fail "an unresolvable engine name still falls back to the orchid/<name> cross-check shape"

# ---------------------------------------------------------------------------
# Config-keys coverage: every hook.<point> key + hook_timeout_s registered.
# ---------------------------------------------------------------------------
for k in hook.after_plan_draft hook.before_arbitration hook.on_verify_fail \
         hook.before_merge hook.on_blocker hook_timeout_s; do
  grep -qxF "$k" "$REPO_ROOT/lib/config-keys.txt" || fail "config key '$k' missing from lib/config-keys.txt"
  grep -qF "$k" "$REPO_ROOT/orchid.config.example" || fail "config key '$k' missing from orchid.config.example"
done

# ===========================================================================
# lib/pack.sh: pack_build's hook branch, direct (not through the launcher),
# covering the per-point content rules -- non-truncatable artifacts
# (verify.log, diff.patch, BLOCKERS.md) vs truncatable ones (reviews.json,
# roadmap.md).
# ===========================================================================
source "$REPO_ROOT/lib/pack.sh"

pack_build "$WORK" T001 hook "$WORK/phook_bm" before_merge || fail "hook pack build (before_merge)"
[ -f "$WORK/phook_bm/task.md" ] || fail "hook pack (before_merge) has task.md"
[ -f "$WORK/phook_bm/diff.patch" ] || fail "hook pack (before_merge) has diff.patch"
grep -q "change" "$WORK/phook_bm/diff.patch" || fail "hook pack (before_merge) diff.patch captures the real diff"
assert_eq "false" "$(jq -r '.items[] | select(.name=="diff.patch") | .truncated' "$WORK/phook_bm/pack.json")" "before_merge diff.patch never truncated"

echo "verify log contents" > "$WORK/.orchid/reviews/T001-verify.log"
pack_build "$WORK" T001 hook "$WORK/phook_vf" on_verify_fail || fail "hook pack build (on_verify_fail)"
[ -f "$WORK/phook_vf/verify.log" ] || fail "hook pack (on_verify_fail) has verify.log"
grep -q "verify log contents" "$WORK/phook_vf/verify.log" || fail "hook pack (on_verify_fail) verify.log content matches"
assert_eq "false" "$(jq -r '.items[] | select(.name=="verify.log") | .truncated' "$WORK/phook_vf/pack.json")" "on_verify_fail verify.log never truncated"

echo "# Blockers" > "$WORK/.orchid/BLOCKERS.md"
echo "## q-1" >> "$WORK/.orchid/BLOCKERS.md"
pack_build "$WORK" T001 hook "$WORK/phook_ob" on_blocker || fail "hook pack build (on_blocker)"
[ -f "$WORK/phook_ob/BLOCKERS.md" ] || fail "hook pack (on_blocker) has BLOCKERS.md"

printf '{"contract":1,"job_id":"j-r1","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true}' \
  > "$WORK/.orchid/reviews/T001-a1-reviewer.json"
pack_build "$WORK" T001 hook "$WORK/phook_ba" before_arbitration || fail "hook pack build (before_arbitration)"
[ -f "$WORK/phook_ba/reviews.json" ] || fail "hook pack (before_arbitration) has reviews.json"
assert_eq "1" "$(jq 'length' "$WORK/phook_ba/reviews.json")" "before_arbitration reviews.json concatenates the current attempt's envelopes"

printf -- '---\nrun_status: planning\n---\n# Roadmap\nDraft body.\n' > "$WORK/.orchid/roadmap.md"
pack_build "$WORK" T001 hook "$WORK/phook_ap" after_plan_draft || fail "hook pack build (after_plan_draft)"
[ -f "$WORK/phook_ap/roadmap.md" ] || fail "hook pack (after_plan_draft) has roadmap.md"
grep -q "Draft body" "$WORK/phook_ap/roadmap.md" || fail "hook pack (after_plan_draft) roadmap.md content matches"

# tight budget: reviews.json/roadmap.md are the truncatable ones for their
# respective points; task.md is not (it is added before the budget check).
tight=$(( $(wc -c < "$WORK/.orchid/tasks/T001.md") + 20 ))
printf 'pack_budget_bytes=%s\n' "$tight" >> orchid.config
pack_build "$WORK" T001 hook "$WORK/phook_ap2" after_plan_draft || fail "hook pack build (after_plan_draft, tight budget)"
assert_eq "true" "$(jq -r '.items[] | select(.name=="roadmap.md") | .truncated' "$WORK/phook_ap2/pack.json")" "after_plan_draft roadmap.md trims under a tight budget"

# unknown point -> die (defense in depth; jobs prepare already refuses this
# earlier in the real launch path).
rc=0; pack_build "$WORK" T001 hook "$WORK/phook_bad" not_a_real_point 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "pack_build hook branch must refuse an unknown point"

# ===========================================================================
# hook_guidance: template default (empty, settable) + orchid-task actually
# allows setting it (it is deliberately absent from the `set` deny-list --
# tested directly here, not trusted by omission).
# ===========================================================================
grep -q '^hook_guidance:$' "$REPO_ROOT/templates/task.md" \
  || fail "templates/task.md missing an empty 'hook_guidance:' frontmatter line"
grep -q '^hook_guidance:$' "$WORK/.orchid/tasks/T001.md" \
  || fail "a freshly created task carries an empty hook_guidance: line"
"$ORCHID_BIN" task set T001 hook_guidance "retry with a smaller diff" >/dev/null \
  || fail "hook_guidance must be settable via 'orchid task set'"
assert_eq "retry with a smaller diff" \
  "$("$ORCHID_BIN" task show T001 | grep '^hook_guidance: ' | cut -d' ' -f2-)" \
  "hook_guidance round-trips through task set/show"

# ===========================================================================
# before_merge kernel gate (v1-m3 Task 6): the ONE hook point orchid-merge
# itself enforces. A `:required` binding with no sha-bound ok envelope for
# the task's CURRENT candidate_sha refuses the merge outright (exit 15); a
# matching ok envelope lets it proceed; an `optional` binding never gates,
# envelope or not; a stale-sha envelope is treated exactly like a missing
# one; multiple required bindings each need their OWN matching envelope,
# disambiguated by the filed envelope's own `.engine` field against that
# binding's OWN manifest id (resolve_engine_qualified_id) -- "orchid/<id>"
# for a first-party plugin (or any unresolvable name, as a fallback), but a
# third-party publisher's real "acme/<id>"-shaped id works exactly the same
# way (HG6 below).
# A fresh repo (separate from $WORK above) -- this needs a real integration
# branch + a full pending->merging walk, which nothing earlier in this file
# set up.
# ===========================================================================
make_scratch MWORK
cd_scratch "$MWORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$MWORK" HOME="$MWORK/home"; mkdir -p "$HOME"
# unset: ORCHID_ENGINES_DIR is a resolver-only test hook (lib/resolver.sh)
# left exported ("$WORK/eng") from the CLI-level fixture above -- it is
# checked FIRST regardless of ORCHID_REPO/HOME, so left set here it would
# collide with HG6's own $HOME-rooted third-party plugin dir below (same
# engine name resolvable from two roots -> resolve_engine_dir's own
# duplicate-engine guard, INV-10, would refuse it). This section resolves
# engines purely via $HOME, same as a real installed plugin would.
unset ORCHID_ENGINES_DIR

hg_integ=orchid/integration
git branch "$hg_integ"
printf 'integration_branch=%s\nverify=true\nconcurrency=10\n' "$hg_integ" > orchid.config
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# Local walk-to-merging helper -- same shape as tests/test_merge.sh's own
# (not importable across test files; duplicated under a distinct name).
_hg_walk_to_merging() {
  local id="$1" branch="$2" base="$3" cand="$4"
  "$ORCHID_BIN" task set "$id" base_sha "$base" >/dev/null
  "$ORCHID_BIN" task set "$id" candidate_sha "$cand" >/dev/null
  "$ORCHID_BIN" task set "$id" verification_commands "true" >/dev/null
  "$ORCHID_BIN" task advance "$id" implementing >/dev/null
  "$ORCHID_BIN" task advance "$id" testing >/dev/null
  git checkout -q "$branch"
  "$ORCHID_BIN" verify "$id" >/dev/null
  git checkout -q "$hg_integ"
  "$ORCHID_BIN" task advance "$id" reviewing >/dev/null
  plant_reviewer_envelope "$id"
  "$ORCHID_BIN" task advance "$id" arbitrating --reason "single reviewer approved" >/dev/null
  "$ORCHID_BIN" task advance "$id" merging --reason "approved for merge" >/dev/null
}

# _hg_new_candidate <id> -- creates the task + a one-commit branch off
# hg_integ, prints "<base-sha> <candidate-sha>", leaves cwd on hg_integ.
_hg_new_candidate() {
  local id="$1"
  "$ORCHID_BIN" task create "$id" "hook gate $id" >/dev/null
  git checkout -q -b "task/$id" "$hg_integ"
  echo "$id" > "$id.txt" && git add "$id.txt" && git commit -q -m "$id"
  local cand; cand="$(git rev-parse HEAD)"
  git checkout -q "$hg_integ"
  local base; base="$(git rev-parse "$hg_integ")"
  printf '%s %s\n' "$base" "$cand"
}

# plant_hook_envelope <id> <attempt> <status> <engine> <candidate_sha> [suffix]
# -- writes a hook-op envelope straight to reviews/, the same shape `jobs
# reconcile` would have filed, bypassing an actual job/engine launch (this
# gate is tested directly, not through the full launch/reconcile pipeline --
# that round trip is already covered above).
_hg_plant_hook_envelope() {
  local id="$1" attempt="$2" status="$3" engine="$4" cand="$5" suffix="${6:-}"
  local dest=".orchid/reviews/$id-a$attempt-hook-before_merge${suffix}.json"
  jq -n --arg jid "j-fixture-$id-hook-bm$suffix" --arg task "$id" \
        --arg status "$status" --arg engine "$engine" --arg cand "$cand" \
    '{contract:1, job_id:$jid, task:$task, operation:"hook", status:$status,
      engine:$engine, candidate_sha:$cand,
      artifact:{guidance:"fixture"}, summary:"fixture hook"}' \
    > "$dest"
}

# --- HG1: a required binding, no envelope at all -> exit 15. ---
read -r hg1_base hg1_cand <<< "$(_hg_new_candidate HG1)"
_hg_walk_to_merging HG1 task/HG1 "$hg1_base" "$hg1_cand"
printf 'integration_branch=%s\nverify=true\nconcurrency=10\nhook.before_merge=stubmerge:required\n' "$hg_integ" > orchid.config
rc=0; hg1_out="$("$ORCHID_BIN" merge HG1 2>&1)" || rc=$?
assert_eq 15 "$rc" "before_merge required binding with no envelope -> merge exits 15"
assert_match "merge blocked: required before_merge hook 'stubmerge' has no ok envelope for this candidate" \
  "$hg1_out" "exit-15 message names the required hook id verbatim"
assert_eq merging "$("$ORCHID_BIN" task show HG1 | grep '^status: ' | cut -d' ' -f2)" \
  "task remains in merging after the before_merge gate refuses (never attempted the merge)"

# --- HG2: same required binding, a sha-matched ok envelope -> proceeds. ---
read -r hg2_base hg2_cand <<< "$(_hg_new_candidate HG2)"
_hg_walk_to_merging HG2 task/HG2 "$hg2_base" "$hg2_cand"
_hg_plant_hook_envelope HG2 1 ok "orchid/stubmerge" "$hg2_cand"
rc=0; "$ORCHID_BIN" merge HG2 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "before_merge required binding with a matching ok envelope -> merge proceeds"
assert_eq "done" "$("$ORCHID_BIN" task show HG2 | grep '^status: ' | cut -d' ' -f2)" "HG2 reaches done"

# --- HG3: an optional binding (no :required), no envelope at all -> proceeds. ---
read -r hg3_base hg3_cand <<< "$(_hg_new_candidate HG3)"
_hg_walk_to_merging HG3 task/HG3 "$hg3_base" "$hg3_cand"
printf 'integration_branch=%s\nverify=true\nconcurrency=10\nhook.before_merge=stubmerge\n' "$hg_integ" > orchid.config
rc=0; "$ORCHID_BIN" merge HG3 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "an optional before_merge binding never gates merge, envelope or not"
assert_eq "done" "$("$ORCHID_BIN" task show HG3 | grep '^status: ' | cut -d' ' -f2)" "HG3 reaches done"

# --- HG4: required binding, an envelope bound to the WRONG candidate (a
# stale envelope) -> treated the same as missing, exit 15. ---
read -r hg4_base hg4_cand <<< "$(_hg_new_candidate HG4)"
_hg_walk_to_merging HG4 task/HG4 "$hg4_base" "$hg4_cand"
printf 'integration_branch=%s\nverify=true\nconcurrency=10\nhook.before_merge=stubmerge:required\n' "$hg_integ" > orchid.config
_hg_plant_hook_envelope HG4 1 ok "orchid/stubmerge" "0000000000000000000000000000000000dead"
rc=0; hg4_out="$("$ORCHID_BIN" merge HG4 2>&1)" || rc=$?
assert_eq 15 "$rc" "a stale-sha before_merge envelope is treated as missing -> exit 15"
assert_match "merge blocked: required before_merge hook 'stubmerge'" "$hg4_out" "stale-sha exit-15 names the hook id"
assert_eq merging "$("$ORCHID_BIN" task show HG4 | grep '^status: ' | cut -d' ' -f2)" \
  "HG4 remains in merging (stale envelope never satisfies the gate)"

# --- HG5: TWO required bindings -- ALL must pass; one entry's ok envelope
# never satisfies a DIFFERENT required entry (disambiguated by .engine). ---
read -r hg5_base hg5_cand <<< "$(_hg_new_candidate HG5)"
_hg_walk_to_merging HG5 task/HG5 "$hg5_base" "$hg5_cand"
printf 'integration_branch=%s\nverify=true\nconcurrency=10\nhook.before_merge=alpha:required,beta:required\n' "$hg_integ" > orchid.config
_hg_plant_hook_envelope HG5 1 ok "orchid/alpha" "$hg5_cand"
rc=0; hg5_out="$("$ORCHID_BIN" merge HG5 2>&1)" || rc=$?
assert_eq 15 "$rc" "only one of two required bindings satisfied -> merge still exits 15"
assert_match "merge blocked: required before_merge hook 'beta'" "$hg5_out" \
  "the UNSATISFIED binding id ('beta') is the one named, not the already-satisfied 'alpha'"
assert_eq merging "$("$ORCHID_BIN" task show HG5 | grep '^status: ' | cut -d' ' -f2)" "HG5 remains in merging"

_hg_plant_hook_envelope HG5 1 ok "orchid/beta" "$hg5_cand" ".2"
rc=0; "$ORCHID_BIN" merge HG5 >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "once BOTH required bindings have their own matching ok envelope, merge proceeds"
assert_eq "done" "$("$ORCHID_BIN" task show HG5 | grep '^status: ' | cut -d' ' -f2)" "HG5 reaches done"

# --- HG6: a THIRD-PARTY publisher's engine bound `:required` -- dir name
# "foo", manifest `id=acme/foo`, adapter echoes its OWN qualified id back
# ("acme/foo", never "orchid/foo"). The gate must derive the expected engine
# string from foo's own manifest (resolve_engine_qualified_id), not assume
# every bound name is a first-party "orchid/<name>" plugin -- hardcoding
# that shape would make this binding permanently unsatisfiable (critical
# fix, post-review). ---
mkdir -p "$HOME/.orchid/plugins/engines/foo"
printf 'manifest_version=1\nid=acme/foo\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$HOME/.orchid/plugins/engines/foo/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$HOME/.orchid/plugins/engines/foo/run"
chmod +x "$HOME/.orchid/plugins/engines/foo/run"

read -r hg6_base hg6_cand <<< "$(_hg_new_candidate HG6)"
_hg_walk_to_merging HG6 task/HG6 "$hg6_base" "$hg6_cand"
printf 'integration_branch=%s\nverify=true\nconcurrency=10\nhook.before_merge=foo:required\n' "$hg_integ" > orchid.config
_hg_plant_hook_envelope HG6 1 ok "acme/foo" "$hg6_cand"
rc=0; _hg6_out="$("$ORCHID_BIN" merge HG6 2>&1)" || rc=$?
assert_eq 0 "$rc" "a required binding to a third-party engine (manifest id=acme/foo) is satisfied by its OWN qualified id"
assert_eq "done" "$("$ORCHID_BIN" task show HG6 | grep '^status: ' | cut -d' ' -f2)" "HG6 reaches done"

cd_scratch "$WORK" || exit 1; rm -rf "$MWORK"

# ===========================================================================
# Stub-driven tick-walk: on_verify_fail guidance attach. Simulates the
# orchestrator driving THE TICK's own verbs exactly as PROTOCOL.md prescribes
# for a FAIL verify -- launch+reconcile the hook (here: an envelope planted
# directly, standing in for a real job round trip already covered above),
# read its artifact's `guidance`, `task set hook_guidance` BEFORE the rework
# advance, then the rework advance itself -- and confirms hook_guidance
# survives (is "carried") across that advance rather than being reset by it.
# ===========================================================================
make_scratch TWORK
cd_scratch "$TWORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
base_tw="$(git rev-parse HEAD)"
echo x > x.txt && git add x.txt && git commit -q -m "candidate"
cand_tw="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$TWORK" HOME="$TWORK/home"; mkdir -p "$HOME"
printf 'hook.on_verify_fail=stubguide:required\n' > orchid.config
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

"$ORCHID_BIN" task create TW1 "on_verify_fail tick-walk" >/dev/null
"$ORCHID_BIN" task set TW1 base_sha "$base_tw" >/dev/null
"$ORCHID_BIN" task set TW1 candidate_sha "$cand_tw" >/dev/null
"$ORCHID_BIN" task set TW1 verification_commands "false" >/dev/null
"$ORCHID_BIN" task advance TW1 implementing >/dev/null
"$ORCHID_BIN" task advance TW1 testing >/dev/null

# testing (awaiting-verify): `orchid verify <id>` -- FAIL.
rc=0; verify_out="$("$ORCHID_BIN" verify TW1)" || rc=$?
assert_eq 1 "$rc" "orchid verify exits 1 on a failing verification_commands"
assert_match "FAIL" "$verify_out" "orchid verify prints FAIL"

# FAIL branch, hook.on_verify_fail bound: launch+reconcile the hook (stub:
# the envelope reconcile would have filed at this exact path -- attempt
# mirrors attempts+1, same as jobs prepare's own formula; attempts is still
# 0 here, so attempt 1), then read its artifact and attach hook_guidance
# BEFORE the rework advance, per PROTOCOL.md's testing/FAIL step.
attempt_tw=$(( $("$ORCHID_BIN" task show TW1 | grep '^attempts: ' | cut -d' ' -f2) + 1 ))
hook_env=".orchid/reviews/TW1-a$attempt_tw-hook-on_verify_fail.json"
jq -n --arg jid "j-fixture-tw1-hook-ovf" \
  '{contract:1, job_id:$jid, task:"TW1", operation:"hook", status:"ok",
    artifact:{guidance:"shrink the diff and retry"}, summary:"fixture hook ran"}' \
  > "$hook_env"
guidance_tw="$(jq -r '.artifact.guidance' "$hook_env")"
"$ORCHID_BIN" task set TW1 hook_guidance "$guidance_tw" >/dev/null

assert_eq "shrink the diff and retry" \
  "$("$ORCHID_BIN" task show TW1 | grep '^hook_guidance: ' | cut -d' ' -f2-)" \
  "hook_guidance attached BEFORE the rework advance"

"$ORCHID_BIN" task advance TW1 rework --reason "verify failed: see .orchid/reviews/TW1-verify.log" >/dev/null

assert_eq rework "$("$ORCHID_BIN" task show TW1 | grep '^status: ' | cut -d' ' -f2)" \
  "TW1 lands in rework after the FAIL branch's advance"
assert_eq "shrink the diff and retry" \
  "$("$ORCHID_BIN" task show TW1 | grep '^hook_guidance: ' | cut -d' ' -f2-)" \
  "the rework advance CARRIES hook_guidance -- it is not reset by the transition"
assert_eq 1 "$("$ORCHID_BIN" task show TW1 | grep '^attempts: ' | cut -d' ' -f2)" \
  "the (non-waived) rework advance consumed an attempt, same as any other rework entry"

cd_scratch "$WORK" || exit 1; rm -rf "$TWORK"
