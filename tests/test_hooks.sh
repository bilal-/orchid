#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/hooks.sh"; source "$REPO_ROOT/lib/envelope.sh"

cd "$WORK"; mkdir -p .orchid
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
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base_sha="$(git rev-parse HEAD)"
echo change >> f.txt; git add f.txt; git commit -q -m change
cand_sha="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks .orchid/reviews
export HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"
printf 'verify=true\n' > orchid.config
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"

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
ls "$WORK/.orchid/runtime/quarantine/" 2>/dev/null | grep -q "j-bad-hook.json.reason-malformed" \
  || fail "malformed hook envelope (missing artifact) quarantined"

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
