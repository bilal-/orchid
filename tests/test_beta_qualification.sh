#!/usr/bin/env bash
# scripts/beta-qualify.sh -- the reusable local beta qualification harness.
#
# Two DISPOSABLE fixture repositories, deliberately chosen so the suite is not
# made only of fast, well-behaved fixtures:
#
#   A "fast"      -- a repository this build can actually drive: verify passes
#                    instantly, and the implementer profile declares shell.
#   B "slow"      -- a repository this build CANNOT drive unattended: the
#                    verify suite genuinely outruns the lease-staleness window
#                    it is measured against, AND the implementer profile has no
#                    shell capability, so a repository script or a chmod is an
#                    operator hand-off with no in-loop actor. Both defects are
#                    real here, not simulated: fixture B's suite really sleeps,
#                    and pump_stale_s is really scaled down to meet it, which
#                    is the honest way to make "outruns its timeout" both
#                    genuine and fast.
#
# The evidence rule is tested adversarially: fixture content, a fixture
# FILENAME, a fixture PATH component, and the verify command's own stdout and
# stderr all carry distinct canaries, and none of them may appear in either
# emitted file.
#
# This file never cds at all. Every git invocation is `git -C <absolute path>`
# and every Orchid verb gets an explicit ORCHID_REPO, so there is no bare `cd`
# for an empty scratch root to silently turn into `git init`/`git commit`
# against the real checkout under test -- `cd ""` is a no-op that leaves the
# caller's cwd in place, which is how that damage happens.
#
# RED before this task: scripts/beta-qualify.sh does not exist, so every run
# below fails to start.
source "$(dirname "$0")/helpers.sh"

QUALIFY="$REPO_ROOT/scripts/beta-qualify.sh"
[ -f "$QUALIFY" ] || fail "scripts/beta-qualify.sh missing"

W="$(cd_scratch "$WORK" && pwd -P)"
export HOME="$MACHINE_HOME"
mkdir -p "$HOME/.orchid"

# Distinct canaries, one per leak channel this harness could plausibly have.
CANARY_CONTENT="CANARY-CONTENT-9d2e-proprietary-source"
CANARY_FILENAME="CANARY-FILENAME-b3f1.txt"
CANARY_PATH="canary-path-5e8b"
CANARY_STDOUT="CANARY-VERIFY-STDOUT-7a1c"
CANARY_STDERR="CANARY-VERIFY-STDERR-4c60"

# Stub engine plugins. The capability list is the whole point of the
# implementer-shell probe, so the two differ in exactly that one field.
export ORCHID_ENGINES_DIR="$W/eng"
mkdir -p "$W/eng/shellimpl" "$W/eng/noshellimpl" "$W/eng/stubreview"
printf 'manifest_version=1\nid=test/shellimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$W/eng/shellimpl/plugin.conf"
printf 'manifest_version=1\nid=test/noshellimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_write\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$W/eng/noshellimpl/plugin.conf"
printf 'manifest_version=1\nid=test/stubreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$W/eng/stubreview/plugin.conf"
for eng in shellimpl noshellimpl stubreview; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/eng/$eng/run"
  chmod +x "$W/eng/$eng/run"
done

# mk_fixture <dir> <implementer-engine> <verify-line> <pump_stale_s>
mk_fixture() {
  local repo="$1" impl="$2" verify="$3" stale="$4"
  mkdir -p "$repo"
  git -C "$repo" init -q
  {
    printf 'role.implementer=%s\n' "$impl"
    printf 'role.reviewer=stubreview\n'
    printf 'verify=%s\n' "$verify"
    printf 'pump_stale_s=%s\n' "$stale"
  } > "$repo/orchid.config"
  printf '%s\n' "$CANARY_CONTENT" > "$repo/$CANARY_FILENAME"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "fixture: config and payload"
}

# repo_fingerprint <dir> -- tracked/untracked state plus a sorted listing, so a
# harness that wrote anything at all inside the target is caught.
repo_fingerprint() {
  git -C "$1" status --porcelain=v1 --untracked-files=all
  git -C "$1" rev-parse HEAD
  find "$1" -print | LC_ALL=C sort
}

# assert_absent <needle> <file> <label> -- greps the FILE directly. Never
# `producer | grep -q`: a pipeline whose reader exits early SIGPIPEs its
# producer, and this file runs under pipefail.
assert_absent() {
  if grep -qF -- "$1" "$2"; then fail "$3 (found '$1' in $2)"; fi
}
assert_present() {
  grep -qF -- "$1" "$2" || fail "$3 (no '$1' in $2)"
}

# jq_probe <json> <probe-id> <field>
jq_probe() {
  jq -r --arg id "$2" --arg f "$3" \
    '[.probes[] | select(.id == $id)] | if length == 0 then "MISSING" else .[0][$f] end' "$1"
}

# ===========================================================================
# Fixture A -- a repository this build can drive. Expect: qualified, exit 0.
# ===========================================================================
A_REPO="$W/$CANARY_PATH/fast"
mkdir -p "$W/$CANARY_PATH"
mk_fixture "$A_REPO" shellimpl \
  "printf '$CANARY_STDOUT\\n'; printf '$CANARY_STDERR\\n' >&2; true" 900

A_OUT="$W/out-fast"
a_before="$(repo_fingerprint "$A_REPO")"
a_rc=0
a_stdout="$("$BASH" "$QUALIFY" --repo "$A_REPO" --output "$A_OUT" \
  --label fast-fixture --bash "$BASH" --verify-timeout-s 60 2>&1)" || a_rc=$?
a_after="$(repo_fingerprint "$A_REPO")"

assert_eq 0 "$a_rc" "a repository this build can drive qualifies and exits 0: $a_stdout"
assert_eq "$a_before" "$a_after" "the harness must not write anything inside the target repository"

A_JSON="$A_OUT/qualification.json"
A_TEXT="$A_OUT/qualification.txt"
[ -f "$A_JSON" ] || fail "no JSON evidence emitted"
[ -f "$A_TEXT" ] || fail "no text evidence emitted"
jq -e . "$A_JSON" >/dev/null 2>&1 || fail "the JSON evidence does not parse"

assert_eq qualified "$(jq -r .verdict "$A_JSON")" "fixture A's verdict"
assert_eq fast-fixture "$(jq -r .repo.label "$A_JSON")" "the evidence carries the operator-supplied label"
assert_eq 1 "$(jq -r .schema "$A_JSON")" "the evidence declares its schema"

# Every probe this harness owes an operator must be present and named.
for probe in toolchain repo-config unattended-gate implementer-shell \
             implementer-command-execution verify-duration \
             merge-rebase-regeneration stale-run-lock-visibility \
             notify-return-leg; do
  outcome="$(jq_probe "$A_JSON" "$probe" outcome)"
  [ "$outcome" = MISSING ] && fail "the harness emitted no '$probe' probe at all"
done

# RECORD WHY, NOT JUST WHAT. A pass/fail with no reasoning attached is the
# exact evidence gap this harness exists to close, so no record may carry an
# empty why/result/tested.
assert_eq 0 "$(jq '[.probes[] | select((.why | length) == 0 or (.result | length) == 0 or (.tested | length) == 0)] | length' "$A_JSON")" \
  "every probe record must carry what was tested, why the check exists, and why this outcome was reached"

# PROBE, DO NOT INFER. A verdict must state its own scope and enumerate what it
# did not test, and a non-blocking gap must say what makes it expire.
assert_present "This verdict covers only the probes listed above" "$A_TEXT" \
  "the text report states the scope of its own verdict"
assert_present "NOT CERTIFIED BY THIS RUN" "$A_TEXT" \
  "the text report enumerates what it did not certify"
[ "$(jq '.not_certified | length' "$A_JSON")" -ge 2 ] \
  || fail "the harness must name every check it did not perform, not silently omit them"
assert_eq 0 "$(jq '[.known_gaps[] | select((.expires_when | length) == 0)] | length' "$A_JSON")" \
  "a non-blocking gap must state what makes it expire, so no warning outlives its cause"
assert_eq 0 "$(jq '[.probes[] | select(.outcome == "pass" and .blocking == false and (.expires_when != null))] | length' "$A_JSON")" \
  "an expiry belongs on an open gap, never on a passing probe"

# The three defect classes this build actually shipped must each be visible.
assert_present "lease" "$A_TEXT" "the slow-suite probe explains the lease-staleness window it measured against"
lock_outcome="$(jq_probe "$A_JSON" stale-run-lock-visibility outcome)"
case "$lock_outcome" in
  pass|fail) ;;
  *) fail "the stale-run-lock probe must actually run, not be assumed (got '$lock_outcome')" ;;
esac
assert_eq false "$(jq_probe "$A_JSON" stale-run-lock-visibility blocking)" \
  "a build-level gap must not block a candidate repository's own verdict"
assert_eq not-tested "$(jq_probe "$A_JSON" notify-return-leg outcome)" \
  "the inbound answer leg cannot be tested locally and must never be recorded as working"
notify_why="$(jq_probe "$A_JSON" notify-return-leg why)"
assert_match "not symmetric" "$notify_why" \
  "the notify probe states the asymmetry between the outbound and inbound legs"
assert_eq not-tested "$(jq_probe "$A_JSON" implementer-command-execution outcome)" \
  "whether an adapter really grants command execution needs a live vendor round trip and must not be assumed from the manifest"

# The unattended gate is REPORTED, never granted: a harness that acknowledged
# would be granting itself trust.
assert_eq pass "$(jq_probe "$A_JSON" unattended-gate outcome)" "the gate is readable"
assert_match "denied" "$(jq_probe "$A_JSON" unattended-gate result)" \
  "an unacknowledged fixture must be reported as gated, not silently trusted"
[ -d "$HOME/.orchid/unattended-trust" ] \
  && fail "the harness must never create a machine-local unattended-trust record"

# ANONYMIZED EVIDENCE. Content, filename, path component, and both of the
# verify command's own output streams must all be absent from both files.
for f in "$A_JSON" "$A_TEXT"; do
  assert_absent "$CANARY_CONTENT" "$f" "repository content must never reach the evidence"
  assert_absent "$CANARY_FILENAME" "$f" "a repository filename must never reach the evidence"
  assert_absent "$CANARY_PATH" "$f" "a repository path component must never reach the evidence"
  assert_absent "$CANARY_STDOUT" "$f" "the verify command's stdout must never reach the evidence"
  assert_absent "$CANARY_STDERR" "$f" "the verify command's stderr must never reach the evidence"
  assert_absent "$A_REPO" "$f" "the target repository path must never reach the evidence"
  assert_absent "$HOME" "$f" "the operator's home path must never reach the evidence"
  assert_absent "$A_OUT" "$f" "the output path must never reach the evidence"
done

# Anonymized metadata is still real metadata: bucketed, never exact. A `case`
# rather than a regex assertion -- assert_match is grep -E, and a band label
# like `10000+` carries an ERE metacharacter that would silently change what
# the pattern means.
assert_bucket() {
  case "$1" in
    0-9|10-99|100-999|1000-9999|10000+) ;;
    *) fail "$2 (got '$1')" ;;
  esac
}
assert_bucket "$(jq -r .repo.commits "$A_JSON")" \
  "commit count is recorded as an order-of-magnitude band, not an exact fingerprint"
assert_bucket "$(jq -r .repo.tracked_files "$A_JSON")" \
  "tracked-file count is recorded as an order-of-magnitude band"

# The harness never claims the operator-owned work happened.
assert_present "OPERATOR-OWNED, NOT PERFORMED HERE" "$A_TEXT" \
  "the report separates what it did from what only an operator can do"
[ "$(jq '[.operator_owned[] | select(contains("third-party beta"))] | length' "$A_JSON")" -ge 1 ] \
  || fail "a genuine third-party beta run must be listed as operator-owned and unclaimed"
[ "$(jq '[.operator_owned[] | select(contains("publication"))] | length' "$A_JSON")" -ge 1 ] \
  || fail "publication must be listed as operator-owned and unclaimed"

# ===========================================================================
# Fixture B -- a repository this build cannot drive unattended. The suite
# really outruns the window it is measured against, and the implementer really
# cannot run a command. Expect: not qualified, exit 1, both named.
# ===========================================================================
B_REPO="$W/slow"
mk_fixture "$B_REPO" noshellimpl \
  "printf '$CANARY_STDOUT\\n'; sleep 2; true" 1

B_OUT="$W/out-slow"
b_rc=0
b_stdout="$("$BASH" "$QUALIFY" --repo "$B_REPO" --output "$B_OUT" \
  --label slow-fixture --bash "$BASH" --verify-timeout-s 60 2>&1)" || b_rc=$?
assert_eq 1 "$b_rc" "a repository this build cannot drive must not qualify: $b_stdout"

B_JSON="$B_OUT/qualification.json"
B_TEXT="$B_OUT/qualification.txt"
[ -f "$B_JSON" ] || fail "no JSON evidence emitted for the slow fixture"
jq -e . "$B_JSON" >/dev/null 2>&1 || fail "the slow fixture's JSON evidence does not parse"
assert_eq not-qualified "$(jq -r .verdict "$B_JSON")" "fixture B's verdict"

# (a) the slow suite. A fast-fixture-only suite would certify this build.
assert_eq fail "$(jq_probe "$B_JSON" verify-duration outcome)" \
  "a verify suite that outruns the lease-staleness window must fail qualification"
slow_result="$(jq_probe "$B_JSON" verify-duration result)"
assert_match "pump_stale_s" "$slow_result" \
  "the slow-suite failure names the timeout it was measured against"
assert_match "unrefreshed lease" "$slow_result" \
  "the slow-suite failure explains why the duration matters, not just that it was long"

# (b) the no-shell implementer profile, and the merge-rebase deadlock it causes.
assert_eq fail "$(jq_probe "$B_JSON" implementer-shell outcome)" \
  "an implementer that cannot run a command must fail qualification"
impl_result="$(jq_probe "$B_JSON" implementer-shell result)"
assert_match "chmod" "$impl_result" \
  "the no-shell failure names changing a file mode as an operator hand-off"
assert_match "hand-off" "$impl_result" \
  "the no-shell failure says plainly that these become operator hand-offs"
assert_eq fail "$(jq_probe "$B_JSON" merge-rebase-regeneration outcome)" \
  "a no-shell profile leaves no in-loop actor to regenerate what the merge rebase invalidates"
assert_match "rebase" "$(jq_probe "$B_JSON" merge-rebase-regeneration why)" \
  "the merge deadlock names the rebase that causes it"

for f in "$B_JSON" "$B_TEXT"; do
  assert_absent "$CANARY_CONTENT" "$f" "slow fixture: repository content must never reach the evidence"
  assert_absent "$CANARY_STDOUT" "$f" "slow fixture: the verify command's stdout must never reach the evidence"
  assert_absent "$B_REPO" "$f" "slow fixture: the target repository path must never reach the evidence"
done

# ===========================================================================
# Refusals -- the harness must fail closed on anything that could corrupt the
# evidence or write where it must not.
# ===========================================================================
run_refusal() {  # <label> <needle> <args...>
  local label="$1" needle="$2"; shift 2
  local out rc=0
  out="$("$BASH" "$QUALIFY" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label: expected a precondition refusal (exit 2), got $rc: $out"
  case "$out" in
    *"$needle"*) ;;
    *) fail "$label: refusal did not explain itself ('$needle' absent): $out" ;;
  esac
}

run_refusal "existing evidence" "refusing to overwrite" \
  --repo "$A_REPO" --output "$A_OUT" --bash "$BASH"
run_refusal "path-shaped label" "--label must be" \
  --repo "$A_REPO" --output "$W/out-badlabel" --label "../escape" --bash "$BASH"
run_refusal "output inside the target" "never writes into the target repository" \
  --repo "$A_REPO" --output "$A_REPO/evidence" --bash "$BASH"
run_refusal "missing repo" "--repo is required" --output "$W/out-norepo"

# --no-run-verify must degrade to an explicit not-tested, never to a silent
# pass: the timing fact it skips is the most load-bearing one in the report.
C_OUT="$W/out-noverify"
"$BASH" "$QUALIFY" --repo "$A_REPO" --output "$C_OUT" --label skipped \
  --bash "$BASH" --no-run-verify >/dev/null 2>&1 || true
C_JSON="$C_OUT/qualification.json"
[ -f "$C_JSON" ] || fail "--no-run-verify still has to emit evidence"
assert_eq not-tested "$(jq_probe "$C_JSON" verify-duration outcome)" \
  "a skipped verify run is recorded as not-tested, never as a pass"
assert_match "not executed" "$(jq_probe "$C_JSON" verify-duration result)" \
  "the skipped verify run says plainly that nothing was executed"

exit 0
