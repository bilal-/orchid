#!/usr/bin/env bash
# v1-m2 Task 2: capsuite-gated failover role resolution.
#
# `resolve_role_available` walks a role's preference chain (lib/resolver.sh's
# `resolve_role_chain`) and returns the first engine that is discovered,
# role-eligible, ledger-available, and -- for every entry AFTER the first --
# capsuite-passed (the m1 capability suite gate: a fallback pair may only
# activate once it has actually been proven to work for that role). No
# survivor -> exit 14, naming each chain entry's disqualifier on stderr.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/envelope.sh"; source "$REPO_ROOT/lib/capsuite.sh"
source "$REPO_ROOT/lib/ledger.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
export ORCHID_ROOT="$REPO_ROOT"

export HOME="$WORK/home"; mkdir -p "$HOME/.orchid"
export ORCHID_ENGINES_DIR="$WORK/eng"; mkdir -p "$WORK/eng"

# mk_engine <name> <capabilities> -- a stub engine dir under $ORCHID_ENGINES_DIR
# whose adapter answers ORCHID_DRYRUN=1 implement/review requests (so
# capsuite_run can pass it), same fixture shape as tests/test_plugins_test.sh's
# stubengine.
mk_engine() {
  local name="$1" caps="$2" dir
  dir="$WORK/eng/$name"
  mkdir -p "$dir"
  # No requires_binaries key at all -- proof that lib/manifest.sh's
  # _manifest_split_csv empty-CSV bash-3.2 quirk (v1-m3, fixed alongside
  # this task) is actually fixed: this manifest used to declare
  # `requires_binaries=jq` purely to dodge that crash (an `unbound variable`
  # abort under `set -u` when the key was absent), never because the stub
  # engine's run script below needed it validated. jq is still a hard
  # dependency of the whole test harness and this run script (below) still
  # calls it directly -- only the manifest's now-unnecessary declaration is
  # gone.
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nentrypoint=run\n' \
    "$name" "$caps" > "$dir/plugin.conf"
  cat > "$dir/run" <<'EOF'
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
EOF
  chmod +x "$dir/run"
}

repo="$WORK/repo"; mkdir -p "$repo/.orchid"

# ---------------------------------------------------------------------------
# A -- a single-entry, healthy chain resolves to its only (primary) engine.
# ---------------------------------------------------------------------------
mk_engine solo "workspace_write,shell,git,structured_text"
printf 'role.implementer=solo\n' > "$repo/orchid.config"
out="$(resolve_role_available "$repo" implementer)" || fail "resolve_role_available should succeed for a healthy single-entry chain"
assert_eq solo "$out" "resolve_role_available picks the (only) primary when healthy"

# ---------------------------------------------------------------------------
# B -- primary rate-limited, fallback WITH a passed capsuite record -> the
# fallback is returned.
# ---------------------------------------------------------------------------
mk_engine primb "workspace_write,shell,git"
mk_engine failb "workspace_write,shell,git"
printf 'role.implementer=primb,failb\n' > "$repo/orchid.config"
ledger_mark "$repo" primb rate_limited 999999
capsuite_run failb implementer >/dev/null || fail "sanity: capsuite_run should pass for failb/implementer"
capsuite_passed failb implementer || fail "sanity: capsuite_passed should reflect the recorded pass for failb/implementer"
out="$(resolve_role_available "$repo" implementer)" || fail "resolve_role_available should fall over to a capsuite-passed fallback"
assert_eq failb "$out" "resolve_role_available returns the capsuite-passed fallback once the primary is rate-limited"

# ---------------------------------------------------------------------------
# C -- primary rate-limited, fallback WITHOUT any capsuite record -> exit 14,
# never silently used.
# ---------------------------------------------------------------------------
mk_engine primc "workspace_write,shell,git"
mk_engine failc "workspace_write,shell,git"
printf 'role.implementer=primc,failc\n' > "$repo/orchid.config"
ledger_mark "$repo" primc rate_limited 999999
rc=0; out="$(resolve_role_available "$repo" implementer 2>"$WORK/err_c")" || rc=$?
assert_eq 14 "$rc" "resolve_role_available exits 14 when the only fallback lacks a capsuite record"
[ -z "$out" ] || fail "resolve_role_available must print nothing to stdout on failure (got '$out')"
err="$(cat "$WORK/err_c")"
assert_match "^orchid: no eligible engine available for role implementer \(chain: " "$err" "exit-14 message names the role and opens the chain listing"
assert_match "primc" "$err" "exit-14 message names the disqualified primary"
assert_match "failc" "$err" "exit-14 message names the disqualified (unverified) fallback"

# ---------------------------------------------------------------------------
# D -- plan_critic never resolves to the orchestrator's own engine, even when
# it is the configured primary; it skips straight to a capsuite-passed
# fallback.
# ---------------------------------------------------------------------------
mk_engine crita "structured_text,shell,git"
mk_engine critb "structured_text,shell,git"
printf 'role.orchestrator=crita\nrole.plan_critic=crita,critb\n' > "$repo/orchid.config"
capsuite_run critb plan_critic >/dev/null || fail "sanity: capsuite_run should pass for critb/plan_critic"
out="$(resolve_role_available "$repo" plan_critic)" || fail "resolve_role_available should skip past the orchestrator's own engine for plan_critic"
assert_eq critb "$out" "plan_critic never resolves to the orchestrator's engine (crita skipped even though healthy)"

# D2 -- a plan_critic chain with ONLY the orchestrator's engine has no
# survivor at all -> exit 14.
mk_engine critd "structured_text"
printf 'role.orchestrator=critd\nrole.plan_critic=critd\n' > "$repo/orchid.config"
rc=0; out="$(resolve_role_available "$repo" plan_critic 2>"$WORK/err_d2")" || rc=$?
assert_eq 14 "$rc" "plan_critic chain containing only the orchestrator's engine has no survivor"
[ -z "$out" ] || fail "resolve_role_available must print nothing to stdout on failure"
assert_match "critd" "$(cat "$WORK/err_d2")" "exit-14 message names the self-critique-skipped engine"

rm -f "$repo/orchid.config"

# ---------------------------------------------------------------------------
# E -- `orchid jobs prepare` on a rate-limited-primary/no-fallback role
# propagates exit 14 (full CLI integration, tier-1 verb).
# ---------------------------------------------------------------------------
crepo="$WORK/crepo"; mkdir -p "$crepo/.orchid/tasks" "$crepo/.orchid/reviews"
(cd "$crepo" && git init -q . && git commit -q --allow-empty -m root)
mk_engine soloe "workspace_write,shell,git"
printf 'verify=true\nrole.implementer=soloe\n' > "$crepo/orchid.config"
export ORCHID_REPO="$crepo"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create TE demo >/dev/null
ledger_mark "$crepo" soloe rate_limited 999999
rc=0; err="$("$ORCHID_BIN" jobs prepare TE implementer implement 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" "jobs prepare exits 14 when the only chain entry is rate-limited"
assert_match "no eligible engine available for role implementer" "$err" "jobs prepare propagates resolve_role_available's exit-14 message"

# ---------------------------------------------------------------------------
# F -- `orchid task create` seeds the template's engine field via
# resolve_role (first-of-chain) -- a configured comma chain must never land
# verbatim in frontmatter.
# ---------------------------------------------------------------------------
printf 'verify=true\nrole.implementer=codex,claude\n' > "$crepo/orchid.config"
"$ORCHID_BIN" task create TF demo2 >/dev/null
eng_field="$(fm_get "$crepo/.orchid/tasks/TF.md" engine)"
assert_eq codex "$eng_field" "task create seeds a single resolved engine (first-of-chain), never the raw 'codex,claude' chain"

# ---------------------------------------------------------------------------
# G -- `orchid doctor` shows the full chain with per-entry state: primary
# tag, and fallback capsuite passed|UNVERIFIED.
# ---------------------------------------------------------------------------
mk_engine orchg "shell,git"
mk_engine implg "workspace_write,shell,git"
mk_engine implg2 "workspace_write,shell,git"
printf 'verify=true\nrole.orchestrator=orchg\nrole.implementer=implg,implg2\nrole.reviewer=agy\nrole.arbiter=claude\nrole.plan_critic=codex\n' \
  > "$crepo/orchid.config"

out="$(ORCHID_REPO="$crepo" "$ORCHID_BIN" doctor)" || true
assert_match "role implementer -> implg \(primary: [^)]+\), implg2 \(fallback: capsuite UNVERIFIED" "$out" \
  "doctor shows the chain with an unverified fallback note before it has been tested, primary annotated with its resolved exe path"

capsuite_run implg2 implementer >/dev/null
out2="$(ORCHID_REPO="$crepo" "$ORCHID_BIN" doctor)" || true
assert_match "role implementer -> implg \(primary: [^)]+\), implg2 \(fallback: capsuite passed\)" "$out2" \
  "doctor shows 'capsuite passed' for a fallback once it has passed the capability suite, primary still annotated with its resolved exe path"
