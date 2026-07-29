#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
export ORCHID_ROOT="$REPO_ROOT"

# `orchid plugins conform <plugin-dir>` (v1-m3 Task 10) is repo-state-free:
# no ORCHID_REPO, no HOME/.orchid, nothing but the plugin dir itself. Every
# scenario below deliberately points HOME at a directory with no .orchid at
# all and never sets ORCHID_REPO, to prove that.
homeC="$WORK/homeC"; mkdir -p "$homeC"

run_conform() {  # plugin-dir -> stdout, rc via $?
  HOME="$homeC" "$ORCHID_BIN" plugins conform "$1"
}

# -- known-good stub adapter: kind=engine, capabilities imply implement
# (workspace_write), review (always), and orchestrate (shell+git) --------
mk_good_stub() {  # dir
  mkdir -p "$1"
  printf 'manifest_version=1\nid=test/stub\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git\nentrypoint=run\n' \
    > "$1/plugin.conf"
  cat > "$1/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {  # status extra-json
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then
  write failed '{}'
  exit 1
fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *)
    write failed '{}'
    exit 1 ;;
esac
exit 0
EOF
  chmod +x "$1/run"
}

# =============================================================================
# RED scenario 1: the known-good stub passes all 7 checks, exit 0.
# =============================================================================
mk_good_stub "$WORK/good"
out="$(run_conform "$WORK/good")"; rc=$?
assert_eq 0 "$rc" "conform on a known-good stub must exit 0"
for name in manifest_valid entrypoint_executable declared_ops_dryrun \
            stdin_closed_safe no_output_pollution env_survives_hygiene \
            exit_discipline; do
  assert_match "^ok: $name\$" "$out" "known-good stub: '$name' reports ok"
done
assert_match "^7/7 checks passed\$" "$out" "known-good stub: summary line"

[ ! -e "$homeC/.orchid" ] || fail "conform must never create .orchid anywhere -- repo-state-free"

# -- usage / not-found -------------------------------------------------------
rc=0; HOME="$homeC" "$ORCHID_BIN" plugins conform >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "conform with no argument must die"
rc=0; HOME="$homeC" "$ORCHID_BIN" plugins conform "$WORK/does-not-exist" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "conform against a nonexistent directory must die"

# =============================================================================
# Seven mutations, each copied fresh from the known-good stub and surgically
# broken in exactly ONE way -- each assertion checks that conform exits
# nonzero AND that the SPECIFIC named check reports FAIL. Where the mutation
# is naturally isolated to one check (2, 4, 5, 6, 7 below), the other six
# checks are also asserted to still report ok, proving conform correctly
# isolates the fault. Mutations 1 and 3 legitimately cascade (an
# unexecutable entrypoint breaks every check that has to spawn it; see
# lib/conform.sh's conform_run) -- for those two only the target check's own
# FAIL line is asserted.
# =============================================================================

# -- Mutation 1: non-executable entrypoint -> entrypoint_executable FAILs ---
mk_good_stub "$WORK/m1"; chmod -x "$WORK/m1/run"
out="$(run_conform "$WORK/m1")"; rc=$?
[ "$rc" -ne 0 ] || fail "non-executable entrypoint must exit nonzero"
assert_match "^FAIL: entrypoint_executable:" "$out" "non-executable entrypoint: entrypoint_executable FAILs"

# -- Mutation 2: envelope missing a required field (implement's `summary`) --
mk_good_stub "$WORK/m2"
cat > "$WORK/m2/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi

case "$operation" in
  # missing `summary` -- envelope_validate's implement union requires it.
  implement)       write ok '{}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *) write failed '{}'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$WORK/m2/run"
out="$(run_conform "$WORK/m2")"; rc=$?
[ "$rc" -ne 0 ] || fail "envelope missing a required field must exit nonzero"
assert_match "^FAIL: declared_ops_dryrun:" "$out" "missing envelope field: declared_ops_dryrun FAILs"
assert_match "implement" "$(printf '%s\n' "$out" | grep '^FAIL: declared_ops_dryrun:')" "missing envelope field: reason names the implement operation"
for name in manifest_valid entrypoint_executable stdin_closed_safe \
            no_output_pollution env_survives_hygiene exit_discipline; do
  assert_match "^ok: $name\$" "$out" "missing envelope field: '$name' is unaffected"
done

# -- Mutation 3: adapter blocks on read (planted, gated to the exact probe
# stdin_closed_safe issues) -- times out under with_timeout -> FAIL. Gated
# by job_id (conform's own request-shaping, see lib/conform.sh's
# _conform_reqdoc) rather than a bare, unconditional `read` from stdin: a
# plain `read` against EITHER `</dev/null` or a closed fd (0<&-) -- the two
# shapes conform actually feeds every adapter -- returns immediately (EOF /
# bad-fd error), it never blocks; only something that ignores what conform
# hands it (a fifo with no writer here) can genuinely hang, so that's what
# simulates "an adapter whose stdin-consuming logic misbehaves" here.
mk_good_stub "$WORK/m3"
cat > "$WORK/m3/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi

if [ "$job_id" = "conform-stdin_closed_safe" ]; then
  FIFO="$(mktemp -u)"; mkfifo "$FIFO"
  read -r _unused < "$FIFO"   # nobody ever writes: blocks until killed
fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *) write failed '{}'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$WORK/m3/run"
# Override the with_timeout budget so this RED scenario doesn't spend the
# real 30s production default -- see lib/conform.sh's header on
# ORCHID_CONFORM_TIMEOUT_S (production/`orchid plugins conform` never sets
# this, so it always gets the documented 30s).
out="$(HOME="$homeC" ORCHID_CONFORM_TIMEOUT_S=2 "$ORCHID_BIN" plugins conform "$WORK/m3")"; rc=$?
[ "$rc" -ne 0 ] || fail "an adapter that blocks on read must exit nonzero"
assert_match "^FAIL: stdin_closed_safe:" "$out" "blocking read: stdin_closed_safe FAILs (timeout)"
assert_match "timed out" "$(printf '%s\n' "$out" | grep '^FAIL: stdin_closed_safe:')" "blocking read: reason names the timeout"

# -- Mutation 4: stray-file dropper -> no_output_pollution FAILs ------------
mk_good_stub "$WORK/m4"
cat > "$WORK/m4/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi

touch ./stray-leftover-file.txt   # never cleaned up -- pollutes the scratch dir

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *) write failed '{}'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$WORK/m4/run"
out="$(run_conform "$WORK/m4")"; rc=$?
[ "$rc" -ne 0 ] || fail "a stray-file-dropping adapter must exit nonzero"
assert_match "^FAIL: no_output_pollution:" "$out" "stray-file dropper: no_output_pollution FAILs"
assert_match "stray-leftover-file.txt" "$(printf '%s\n' "$out" | grep '^FAIL: no_output_pollution:')" "stray-file dropper: reason names the leftover file"
for name in manifest_valid entrypoint_executable declared_ops_dryrun \
            stdin_closed_safe env_survives_hygiene exit_discipline; do
  assert_match "^ok: $name\$" "$out" "stray-file dropper: '$name' is unaffected"
done

# -- Mutation 4b: a "<output>.bak" dropper -> no_output_pollution FAILs.
# Regression test for a real bug: the check used to filter new paths with
# `grep -vF "$outfile"` -- SUBSTRING match, not exact-line -- so a leftover
# path that merely CONTAINS the output path as a substring (e.g. the real
# output "envelope.json" alongside a leftover "envelope.json.bak") was
# silently filtered out of `new_paths` and this check passed even though a
# real leftover file was sitting right there. `grep -vxF` (exact whole-line)
# is the fix; this adapter must now be caught. ------------------------------
mk_good_stub "$WORK/m4b"
cat > "$WORK/m4b/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *) write failed '{}'; exit 1 ;;
esac
touch "${output}.bak"   # leftover: same dir, name CONTAINS the real output path
exit 0
EOF
chmod +x "$WORK/m4b/run"
out="$(run_conform "$WORK/m4b")"; rc=$?
[ "$rc" -ne 0 ] || fail "an <output>.bak-dropping adapter must exit nonzero"
assert_match "^FAIL: no_output_pollution:" "$out" "<output>.bak dropper: no_output_pollution FAILs"
assert_match "envelope\.json\.bak" "$(printf '%s\n' "$out" | grep '^FAIL: no_output_pollution:')" \
  "<output>.bak dropper: reason names the leftover .bak file"
for name in manifest_valid entrypoint_executable declared_ops_dryrun \
            stdin_closed_safe env_survives_hygiene exit_discipline; do
  assert_match "^ok: $name\$" "$out" "<output>.bak dropper: '$name' is unaffected"
done

# -- Mutation 5: env-dependent adapter (requires a var absent once
# env_survives_hygiene's env -i + spawn_child_env stripping applies, even
# though it IS present in the ambient environment every other check's
# invocation inherits unstripped) -> env_survives_hygiene FAILs alone. -----
mk_good_stub "$WORK/m5"
cat > "$WORK/m5/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi

if [ -z "${CONFORM_FIXTURE_SECRET:-}" ]; then
  write failed '{}'
  exit 1
fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *) write failed '{}'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$WORK/m5/run"
# Not declared as `permissions=` in plugin.conf, and not on spawn_child_env's
# base allowlist (PATH/HOME/USER/LANG/TERM/TMPDIR/LC_*/ORCHID_*) -- present
# in THIS test process's own env (so every non-stripped invocation still
# sees it), but stripped away specifically by env -i + spawn_child_env.
out="$(HOME="$homeC" CONFORM_FIXTURE_SECRET=present "$ORCHID_BIN" plugins conform "$WORK/m5")"; rc=$?
[ "$rc" -ne 0 ] || fail "an adapter requiring a non-allowlisted env var must exit nonzero"
assert_match "^FAIL: env_survives_hygiene:" "$out" "env-dependent adapter: env_survives_hygiene FAILs"
for name in manifest_valid entrypoint_executable declared_ops_dryrun \
            stdin_closed_safe no_output_pollution exit_discipline; do
  assert_match "^ok: $name\$" "$out" "env-dependent adapter: '$name' is unaffected"
done

# -- Mutation 6: silent exit-0 on an unsupported operation -> exit_discipline
# FAILs alone (the operation named 'bogus' is never one declared_ops_dryrun/
# stdin_closed_safe/no_output_pollution/env_survives_hygiene ever probe). --
mk_good_stub "$WORK/m6"
cat > "$WORK/m6/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  hook)            write ok '{"artifact":{},"summary":"dryrun"}' ;;
  *) exit 0 ;;   # silently succeeds on an operation it does not understand
esac
exit 0
EOF
chmod +x "$WORK/m6/run"
out="$(run_conform "$WORK/m6")"; rc=$?
[ "$rc" -ne 0 ] || fail "a silent exit-0 on an unsupported operation must exit nonzero"
assert_match "^FAIL: exit_discipline:" "$out" "silent exit-0: exit_discipline FAILs"
for name in manifest_valid entrypoint_executable declared_ops_dryrun \
            stdin_closed_safe no_output_pollution env_survives_hygiene; do
  assert_match "^ok: $name\$" "$out" "silent exit-0: '$name' is unaffected"
done

# -- Mutation 7: manifest declares an unknown capability atom ->
# manifest_valid FAILs alone (manifest_get -- what _conform_ops_for_dir
# reads -- never itself validates atoms, so the ops list, and every check
# that spawns the still-fully-functional entrypoint, is unaffected). -------
mk_good_stub "$WORK/m7"
printf 'manifest_version=1\nid=test/stub\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,shell,git,not_a_real_atom\nentrypoint=run\n' \
  > "$WORK/m7/plugin.conf"
out="$(run_conform "$WORK/m7")"; rc=$?
[ "$rc" -ne 0 ] || fail "an unknown capability atom must exit nonzero"
assert_match "^FAIL: manifest_valid:" "$out" "unknown capability atom: manifest_valid FAILs"
assert_match "not_a_real_atom" "$(printf '%s\n' "$out" | grep '^FAIL: manifest_valid:')" "unknown capability atom: reason names the offending atom"
for name in entrypoint_executable declared_ops_dryrun stdin_closed_safe \
            no_output_pollution env_survives_hygiene exit_discipline; do
  assert_match "^ok: $name\$" "$out" "unknown capability atom: '$name' is unaffected"
done

# -- Mutation 8 (review-review-review finding): an adapter that declares
# all three ops (workspace_write+shell+git -> implement/review/orchestrate)
# but ALWAYS answers with operation="review" regardless of what was
# actually requested -- a false-full-pass bug envelope_validate alone can't
# catch, since it only checks that `.operation` satisfies whatever union
# THAT field names, never that it matches the operation the REQUEST asked
# for. Must isolate to declared_ops_dryrun alone: exit_discipline still
# gates on the operation gate below (bogus is refused properly), and the
# other four checks never inspect which operation came back at all. -------
mk_good_stub "$WORK/m8"
cat > "$WORK/m8/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {  # envelope-operation status extra-json
  local extra="${3:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$1" \
        --arg status "$2" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then
  write review failed '{}'
  exit 1
fi

case "$operation" in
  implement|review|critique|orchestrate)
    # Always claims "review", no matter which of the three it was asked
    # for -- passes envelope_validate every time (a valid review envelope),
    # while never actually implementing `implement`/`orchestrate` at all.
    write review ok '{"verdict":"approve","scope_complete":true}'
    exit 0
    ;;
  *)
    write "$operation" failed '{}'
    exit 1
    ;;
esac
EOF
chmod +x "$WORK/m8/run"
out="$(run_conform "$WORK/m8")"; rc=$?
[ "$rc" -ne 0 ] || fail "an adapter that always echoes operation=review must exit nonzero"
assert_match "^FAIL: declared_ops_dryrun:" "$out" "operation-echo bypass: declared_ops_dryrun FAILs"
fail_line="$(printf '%s\n' "$out" | grep '^FAIL: declared_ops_dryrun:')"
assert_match "implement.*envelope claims operation 'review'" "$fail_line" "operation-echo bypass: reason names the implement mismatch"
assert_match "orchestrate.*envelope claims operation 'review'" "$fail_line" "operation-echo bypass: reason names the orchestrate mismatch"
for name in manifest_valid entrypoint_executable stdin_closed_safe \
            no_output_pollution env_survives_hygiene exit_discipline; do
  assert_match "^ok: $name\$" "$out" "operation-echo bypass: '$name' is unaffected"
done

# =============================================================================
# Extra coverage (beyond the required 7 mutations): kind=hook plugins probe
# ONLY the `hook` operation -- never review/implement/orchestrate -- per the
# capability-implication rule in lib/conform.sh's _conform_ops_for_dir.
# =============================================================================
mkdir -p "$WORK/hookstub"
printf 'manifest_version=1\nid=test/hookstub\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nentrypoint=run\n' \
  > "$WORK/hookstub/plugin.conf"
cat > "$WORK/hookstub/run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then write failed '{}'; exit 1; fi
case "$operation" in
  hook) write ok '{"artifact":{"guidance":"dryrun"},"summary":"dryrun"}' ;;
  *)    write failed '{}'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$WORK/hookstub/run"
out="$(run_conform "$WORK/hookstub")"; rc=$?
assert_eq 0 "$rc" "a kind=hook plugin implementing only the hook operation passes conform"
assert_match "^7/7 checks passed\$" "$out" "kind=hook stub: full pass"
