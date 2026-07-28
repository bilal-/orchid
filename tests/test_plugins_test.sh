#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/capsuite.sh"
export ORCHID_ROOT="$REPO_ROOT"

# These tests run the REAL built-in codex/agy/claude engines (plugins/
# engines/{codex,agy,claude}) rather than planted stand-ins: `orchid plugins
# test` never spends real quota on them because ORCHID_DRYRUN=1 makes every
# adapter short-circuit BEFORE it ever shells out to the real codex/agy/claude
# CLI (see each adapter's `if [ "${ORCHID_DRYRUN:-0}" = "1" ]` branch, which
# runs ahead of any `codex exec`/`agy -p`/`claude -p` call) -- so this is safe
# to run unconditionally, same guarantee the brief asks the capability suite
# itself to provide. binaries_present still wants the real `codex`/`agy`/
# `claude`/`jq` CLIs actually present on PATH for the passing-battery
# assertions below; the missing-binary assertion instead NARROWS PATH to
# `/usr/bin:/bin` (present on every dev/CI box, no engine CLI lives there) so
# it never depends on what happens to be installed.
homeA="$WORK/homeA"; mkdir -p "$homeA/.orchid"
repoA="$WORK/repoA"; mkdir -p "$repoA"

run_test() {  # engine role -> stdout, rc via $?
  HOME="$homeA" ORCHID_REPO="$repoA" "$ORCHID_BIN" plugins test "$@"
}

# -- RED scenario 1: codex/implementer passes, all checks ok, result written
out="$(run_test codex implementer)"; rc=$?
assert_eq 0 "$rc" "plugins test codex implementer should exit 0 (all checks pass)"
assert_match "^PASS: codex implementer$" "$out" "prints a PASS line naming engine and role"

resfile="$homeA/.orchid/capsuite/codex--implementer.json"
[ -f "$resfile" ] || fail "result file must be written to $resfile"
assert_eq true "$(jq -r .passed "$resfile")" "codex/implementer result: passed=true"
assert_eq codex "$(jq -r .engine "$resfile")" "codex/implementer result: engine field"
assert_eq implementer "$(jq -r .role "$resfile")" "codex/implementer result: role field"
nchecks="$(jq '.checks | length' "$resfile")"
assert_eq 5 "$nchecks" "codex/implementer: 5 checks recorded (manifest_valid, capabilities_cover_role, binaries_present, dryrun_envelope_valid, workspace_write_probe)"
for name in manifest_valid capabilities_cover_role binaries_present dryrun_envelope_valid workspace_write_probe; do
  ok="$(jq --arg n "$name" -r '.checks[] | select(.name==$n) | .ok' "$resfile")"
  assert_eq true "$ok" "codex/implementer: check '$name' is ok"
done
marker="$(jq -r .tested_at_marker "$resfile")"
[ -n "$marker" ] || fail "tested_at_marker must be non-empty for a resolvable engine"

# -- RED scenario 2: agy/implementer FAILS at capabilities_cover_role --------
out="$(run_test agy implementer)"; rc=$?
[ "$rc" -ne 0 ] || fail "plugins test agy implementer must exit nonzero (agy lacks workspace_write)"
assert_match "^FAIL: agy implementer$" "$out" "prints a FAIL line naming engine and role"

resfile2="$homeA/.orchid/capsuite/agy--implementer.json"
[ -f "$resfile2" ] || fail "result file must be written even on failure"
assert_eq false "$(jq -r .passed "$resfile2")" "agy/implementer result: passed=false"
cap_ok="$(jq -r '.checks[] | select(.name=="capabilities_cover_role") | .ok' "$resfile2")"
assert_eq false "$cap_ok" "agy/implementer: capabilities_cover_role must be the failing check (agy lacks workspace_write)"

# -- capsuite_passed reflects both -------------------------------------------
HOME="$homeA" capsuite_passed codex implementer \
  || fail "capsuite_passed codex implementer should reflect the recorded pass"
rc=0; HOME="$homeA" capsuite_passed agy implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed agy implementer should reflect the recorded failure"

# -- capsuite_passed: absent result -> not-passed ----------------------------
rc=0; HOME="$homeA" capsuite_passed codex reviewer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must be false for a pair that was never tested"

# -- missing binary -> binaries_present fails (PATH narrowed so the real
# `codex` CLI cannot be found, regardless of what's installed on this box) --
homeM="$WORK/homeM"; mkdir -p "$homeM/.orchid"
out="$(HOME="$homeM" ORCHID_REPO="$repoA" PATH="/usr/bin:/bin" "$ORCHID_BIN" plugins test codex implementer)"; rc=$?
[ "$rc" -ne 0 ] || fail "plugins test codex implementer must exit nonzero when the codex binary is not on PATH"
resfile3="$homeM/.orchid/capsuite/codex--implementer.json"
bin_ok="$(jq -r '.checks[] | select(.name=="binaries_present") | .ok' "$resfile3")"
assert_eq false "$bin_ok" "codex/implementer: binaries_present must fail when codex is not on PATH"
cap_ok3="$(jq -r '.checks[] | select(.name=="capabilities_cover_role") | .ok' "$resfile3")"
assert_eq true "$cap_ok3" "codex/implementer: capabilities_cover_role should still pass (isolates the binaries_present failure)"
dryrun_ok3="$(jq -r '.checks[] | select(.name=="dryrun_envelope_valid") | .ok' "$resfile3")"
assert_eq true "$dryrun_ok3" "codex/implementer: dryrun_envelope_valid still passes without the real CLI (ORCHID_DRYRUN short-circuits before it)"

# -- orchestrator role has no adapter operation: no dryrun/workspace checks --
out="$(run_test claude orchestrator)"; rc=$?
assert_eq 0 "$rc" "plugins test claude orchestrator should pass (shell,git only)"
resfile4="$homeA/.orchid/capsuite/claude--orchestrator.json"
nchecks4="$(jq '.checks | length' "$resfile4")"
assert_eq 3 "$nchecks4" "claude/orchestrator: only the 3 static/binary checks (no operation mapping for orchestrator)"

# -- reviewer/arbiter/plan_critic map to the review operation ----------------
out="$(run_test agy reviewer)"; rc=$?
assert_eq 0 "$rc" "plugins test agy reviewer should pass (agy is eligible + review dryrun succeeds)"
resfile5="$homeA/.orchid/capsuite/agy--reviewer.json"
op_ok="$(jq -r '.checks[] | select(.name=="dryrun_envelope_valid") | .ok' "$resfile5")"
assert_eq true "$op_ok" "agy/reviewer: dryrun_envelope_valid should pass for the review operation"

# -- --all-defaults iterates the default role->engine pairs ------------------
homeB="$WORK/homeB"; mkdir -p "$homeB/.orchid"
repoB="$WORK/repoB"; mkdir -p "$repoB"
out="$(HOME="$homeB" ORCHID_REPO="$repoB" "$ORCHID_BIN" plugins test --all-defaults)"; rc=$?
assert_eq 0 "$rc" "plugins test --all-defaults exits 0 when every default pair passes"
for pair in "claude orchestrator" "codex implementer" "agy reviewer" "claude arbiter" "codex plan_critic"; do
  assert_match "^PASS: $pair$" "$out" "--all-defaults reports PASS for $pair"
  set -- $pair
  [ -f "$homeB/.orchid/capsuite/$1--$2.json" ] || fail "--all-defaults must write a result file for $1/$2"
done

# -- --all-defaults surfaces a failing configured pair -----------------------
homeC="$WORK/homeC"; mkdir -p "$homeC/.orchid"
repoC="$WORK/repoC"; mkdir -p "$repoC"
printf 'role.implementer=agy\n' > "$repoC/orchid.config"
rc=0; out="$(HOME="$homeC" ORCHID_REPO="$repoC" "$ORCHID_BIN" plugins test --all-defaults)" || rc=$?
[ "$rc" -ne 0 ] || fail "--all-defaults must exit nonzero when a configured pair fails (agy cannot implement)"
assert_match "^FAIL: agy implementer$" "$out" "--all-defaults reports the failing pair"

# -- staleness: a changed engine invalidates a previously-passed result ------
# A private, non-colliding stub engine (ORCHID_ENGINES_DIR is an ADDITIONAL
# search location, not an override -- a name that also exists as a built-in,
# e.g. "codex", would be found on BOTH paths and rejected as a duplicate,
# INV-10) so this is the one place that plants its own throwaway engine, and
# it's given a name no built-in uses.
homeD="$WORK/homeD"; mkdir -p "$homeD/.orchid"
enginesD="$WORK/enginesD/stubengine"
mkdir -p "$enginesD"
printf 'manifest_version=1\nid=acme/stubengine\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$enginesD/plugin.conf"
cat > "$enginesD/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"; output="$(jq -r .output "$req")"
if [ "${ORCHID_DRYRUN:-0}" = 1 ]; then
  case "$operation" in
    implement) jq -n '{contract:1, job_id:"x", task:"x", operation:"implement", status:"ok", summary:"dryrun"}' | atomic_write "$output" ;;
    review|critique) jq -n '{contract:1, job_id:"x", task:"x", operation:"review", status:"ok", verdict:"approve", scope_complete:true}' | atomic_write "$output" ;;
  esac
  exit 0
fi
exit 1
EOF
chmod +x "$enginesD/run"

HOME="$homeD" ORCHID_ENGINES_DIR="$WORK/enginesD" ORCHID_REPO="$repoA" \
  "$ORCHID_BIN" plugins test stubengine implementer >/dev/null
HOME="$homeD" ORCHID_ENGINES_DIR="$WORK/enginesD" capsuite_passed stubengine implementer \
  || fail "capsuite_passed should be true immediately after a passing test"
# Mutate the engine's run script's content -- same id/capabilities, different
# bytes -- without re-running `plugins test`.
printf '\n# mutated\n' >> "$enginesD/run"
rc=0; HOME="$homeD" ORCHID_ENGINES_DIR="$WORK/enginesD" capsuite_passed stubengine implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must go stale (not-passed) once the engine's files change after the recorded test"
