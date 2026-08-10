#!/usr/bin/env bash
# Direct unit coverage for lib/capsuite.sh (T013).
#
# tests/test_plugins_test.sh drives the same library through the `orchid
# plugins test` verb, against the REAL built-in codex/agy/claude engines.
# That is the right shape for a verb test and the wrong shape for pinning
# down what the check battery MEANS, because every question about
# binaries_present there has to be asked through manifests that name vendor
# CLIs -- which is how the suite ended up asserting a machine-installation
# fact and keeping hosted CI red on both platforms from its first run.
#
# So this file asks those questions with no vendor name anywhere in it. Every
# engine is planted here, every required binary is either `jq` (a declared
# dependency of the whole harness) or a scratch executable this file creates
# and then removes from PATH itself. It is hermetic by construction: nothing
# in it can pass or fail because of what happens to be installed.
#
# The load-bearing assertion is that binaries_present is a REAL check in both
# directions -- true when the declared binary resolves, false when the SAME
# manifest is scored on a PATH where it does not, and a false there is enough
# on its own to make the pair not-passed. A hermeticity fix that quietly
# turned binaries_present into a tautology would make the suite green and the
# failover gate (lib/resolver.sh's resolve_role_available, which consumes
# capsuite_passed) blind. This file exists to make that trade impossible to
# make by accident.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/envelope.sh"; source "$REPO_ROOT/lib/capsuite.sh"
export ORCHID_ROOT="$REPO_ROOT"

# capsuite writes to $HOME/.orchid/capsuite. That is machine-local state, so it
# goes in the independent disposable home helpers.sh mints for exactly this,
# never under a fixture repository.
export HOME="$MACHINE_HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$ORCHID_ENGINES_DIR"

# mk_engine <name> <capabilities> [requires_binaries] -- a planted engine whose
# adapter answers ORCHID_DRYRUN=1 implement/review requests with a valid
# envelope, same fixture shape as tests/test_failover.sh's. An omitted third
# argument writes no `requires_binaries` key at all, which is the common
# real-world manifest and the vacuously-true case for binaries_present.
mk_engine() {
  local name="$1" caps="$2" bins="${3:-}" dir
  dir="$ORCHID_ENGINES_DIR/$name"
  mkdir -p "$dir"
  {
    printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\n' "$name"
    printf 'capabilities=%s\n' "$caps"
    if [ -n "$bins" ]; then printf 'requires_binaries=%s\n' "$bins"; fi
    printf 'entrypoint=run\n'
  } > "$dir/plugin.conf"
  cat > "$dir/run" <<'ADAPTER'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"; output="$(jq -r .output "$req")"
if [ "${ORCHID_DRYRUN:-0}" = "1" ]; then
  case "$operation" in
    implement) jq -n '{contract:1, job_id:"x", task:"x", operation:"implement", status:"ok", summary:"dryrun"}' | atomic_write "$output" ;;
    review|critique) jq -n '{contract:1, job_id:"x", task:"x", operation:"review", status:"ok", verdict:"approve", scope_complete:true}' | atomic_write "$output" ;;
  esac
  exit 0
fi
exit 1
ADAPTER
  chmod +x "$dir/run"
}

IMPL_CAPS="structured_text,workspace_read,workspace_write,shell,git"

resfile_of() {  # <engine> <role>
  printf '%s/.orchid/capsuite/%s--%s.json\n' "$HOME" "$1" "$2"
}
check_ok() {  # <result-file> <check-name> -> true|false|"" (never recorded)
  jq -r --arg n "$2" '.checks[] | select(.name==$n) | .ok' "$1"
}

# ===========================================================================
# 1 -- the whole battery passes for a well-formed engine whose declared
# binary really does resolve, and the pass is durable and readable.
# ===========================================================================
mk_engine good "$IMPL_CAPS" jq
rc=0; capsuite_run good implementer || rc=$?
assert_eq 0 "$rc" "capsuite_run exits 0 when every check passes"

good_res="$(resfile_of good implementer)"
[ -f "$good_res" ] || fail "capsuite_run must write a durable result file to $good_res"
assert_eq true "$(jq -r .passed "$good_res")" "good/implementer: passed=true"
assert_eq good "$(jq -r .engine "$good_res")" "good/implementer: engine field"
assert_eq implementer "$(jq -r .role "$good_res")" "good/implementer: role field"
assert_eq 5 "$(jq '.checks | length' "$good_res")" \
  "good/implementer: five checks recorded (manifest_valid, capabilities_cover_role, binaries_present, dryrun_envelope_valid, workspace_write_probe)"
for cname in manifest_valid capabilities_cover_role binaries_present \
             dryrun_envelope_valid workspace_write_probe; do
  assert_eq true "$(check_ok "$good_res" "$cname")" "good/implementer: check '$cname' is ok"
done
[ -n "$(jq -r .tested_at_marker "$good_res")" ] \
  || fail "a passing result must carry the engine's content digest as its freshness marker"
capsuite_passed good implementer \
  || fail "capsuite_passed must reflect a freshly recorded pass"

# ===========================================================================
# 2 -- binaries_present is a REAL check, and one failing check is enough to
# make the pair not-passed. Everything else about this engine is identical to
# the one above; only the declared binary is one that cannot exist.
#
# This is the anti-tautology assertion. If a future change to make the suite
# hermetic ever "fixes" binaries_present by making it always true, THIS is
# what fails, and it fails without needing any particular machine: no PATH
# anywhere resolves a name this repository invented.
# ===========================================================================
mk_engine ghostbin "$IMPL_CAPS" "jq,orchid-no-such-binary-t013"
rc=0; capsuite_run ghostbin implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_run must exit nonzero when a declared binary does not resolve"

ghost_res="$(resfile_of ghostbin implementer)"
[ -f "$ghost_res" ] || fail "capsuite_run must write its result file on failure too, not only on success"
assert_eq false "$(jq -r .passed "$ghost_res")" "ghostbin/implementer: passed=false"
assert_eq false "$(check_ok "$ghost_res" binaries_present)" \
  "ghostbin/implementer: binaries_present is false for an unresolvable declared binary"
# The failure is ISOLATED: every other check still passes, so this proves the
# battery scores binaries_present on its own rather than collapsing.
for cname in manifest_valid capabilities_cover_role dryrun_envelope_valid \
             workspace_write_probe; do
  assert_eq true "$(check_ok "$ghost_res" "$cname")" \
    "ghostbin/implementer: '$cname' still passes -- the binaries_present failure must be isolated"
done
rc=0; capsuite_passed ghostbin implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must be false for a pair whose recorded result did not pass"

# ===========================================================================
# 3 -- binaries_present answers a question about PATH, and it answers it BOTH
# ways for one unchanged manifest. The declared binary is created by this file
# in a scratch directory, so the difference between the two runs below is
# purely the PATH they are scored on.
# ===========================================================================
probe_bin="$WORK/probebin"; mkdir -p "$probe_bin"
printf '#!/bin/bash\nexit 0\n' > "$probe_bin/orchid-t013-pathprobe"
chmod +x "$probe_bin/orchid-t013-pathprobe"
mk_engine pathprobe "$IMPL_CAPS" "jq,orchid-t013-pathprobe"

# The extended PATH lives in a SUBSHELL, so this file never has to restore it:
# capsuite_run's whole output is the durable result file, which outlives the
# subshell, and every assertion below reads that file rather than the process
# it was produced in. (`hash -r` because bash reuses a cached command path
# without rechecking it -- checkhash is off by default.)
rc=0
( PATH="$probe_bin:$PATH"; export PATH; hash -r; capsuite_run pathprobe implementer ) \
  || rc=$?
assert_eq 0 "$rc" "capsuite_run passes when the declared binary is on PATH"
probe_res="$(resfile_of pathprobe implementer)"
assert_eq true "$(check_ok "$probe_res" binaries_present)" \
  "pathprobe/implementer: binaries_present is true while the declared binary resolves"
capsuite_passed pathprobe implementer \
  || fail "capsuite_passed must be true while the declared binary resolves"

[ -z "$(command -v orchid-t013-pathprobe 2>/dev/null)" ] \
  || fail "the probe binary resolves on this file's own PATH -- the second half of this scenario would prove nothing"
rc=0; capsuite_run pathprobe implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_run must fail the SAME manifest once its declared binary is off PATH"
assert_eq false "$(check_ok "$probe_res" binaries_present)" \
  "pathprobe/implementer: binaries_present is false once the declared binary is off PATH"
rc=0; capsuite_passed pathprobe implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must follow the re-scored result down"

# ===========================================================================
# 4 -- a manifest that declares no binaries at all is vacuously present. This
# is the common real-world shape and must not crash on the empty-CSV path.
# ===========================================================================
mk_engine nobins "$IMPL_CAPS"
rc=0; capsuite_run nobins implementer || rc=$?
assert_eq 0 "$rc" "capsuite_run passes an engine that declares no required binaries"
assert_eq true "$(check_ok "$(resfile_of nobins implementer)" binaries_present)" \
  "nobins/implementer: binaries_present is vacuously true with no requires_binaries key"

# ===========================================================================
# 5 -- a role with no adapter operation is scored on the static checks only.
# ===========================================================================
rc=0; capsuite_run good orchestrator || rc=$?
assert_eq 0 "$rc" "capsuite_run passes an orchestrator pair (shell,git; no operation mapping)"
assert_eq 3 "$(jq '.checks | length' "$(resfile_of good orchestrator)")" \
  "good/orchestrator: only the three role-agnostic checks run"

# ===========================================================================
# 6 -- never-tested and stale both read as not-passed, and neither errors.
# ===========================================================================
rc=0; capsuite_passed good reviewer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must be false for a pair that was never tested at all"

mk_engine drifting "$IMPL_CAPS" jq
capsuite_run drifting implementer >/dev/null \
  || fail "sanity: the drifting engine must pass before it drifts"
capsuite_passed drifting implementer \
  || fail "sanity: capsuite_passed must be true immediately after a passing run"
# Same id, same capabilities, different bytes -- and no re-run of capsuite.
printf '\n# mutated after the recorded test\n' >> "$ORCHID_ENGINES_DIR/drifting/run"
rc=0; capsuite_passed drifting implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must go stale once the engine's content changes after the recorded test"

# ===========================================================================
# 7 -- an engine that does not resolve at all. Every check the battery could
# not perform is still recorded (a silently absent result would read as
# "nothing to see"), the pair is not passed, and the read side agrees.
# ===========================================================================
rc=0; capsuite_run orchid-t013-absent implementer 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_run must exit nonzero for an engine that is not on the search path"
absent_res="$(resfile_of orchid-t013-absent implementer)"
[ -f "$absent_res" ] || fail "capsuite_run must record a result even for an unresolvable engine"
assert_eq false "$(jq -r .passed "$absent_res")" "absent engine: passed=false"
assert_eq 4 "$(jq '.checks | length' "$absent_res")" \
  "absent engine: the four checks that do not need a spawned adapter are still recorded"
assert_eq "" "$(jq -r .tested_at_marker "$absent_res")" \
  "absent engine: no content digest can be recorded for a directory that does not exist"
rc=0; capsuite_passed orchid-t013-absent implementer || rc=$?
[ "$rc" -ne 0 ] || fail "capsuite_passed must be false for an engine that no longer resolves"

# ===========================================================================
# 8 -- result-file naming. A manifest-id-shaped engine name carries a `/`,
# which would otherwise land the result in a directory that does not exist.
# ===========================================================================
assert_eq "$HOME/.orchid/capsuite/acme_widget--implementer.json" \
  "$(_capsuite_result_file acme/widget implementer)" \
  "a '/' in the engine name is flattened for the result filename only"

exit 0
