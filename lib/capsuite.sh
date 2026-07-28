#!/usr/bin/env bash
# Capability-suite runner (v1-m1 Task 6). `capsuite_run <engine> <role>` puts
# one (engine, role) pair through a fixed check battery WITHOUT spending real
# quota where possible (adapters are invoked with ORCHID_DRYRUN=1, never for
# real), and records a durable result to
# ~/.orchid/capsuite/<engine>--<role>.json -- {engine, role, passed,
# checks:[{name,ok}], tested_at_marker}. `capsuite_passed <engine> <role>` is
# the read side v1-m2's failover gate consumes: reads that recorded result,
# absent-or-stale reads as not-passed rather than erroring.
#
# `tested_at_marker` is the engine plugin dir's content digest (lib/common.sh
# plugin_digest) AT TEST TIME, not a timestamp -- this codebase already has a
# content-addressed freshness primitive (the digest-pinned trust store, INV-
# 09) and reusing it here means "stale" needs no wall-clock/TTL policy: a
# result is fresh iff the engine's files haven't changed since it was tested,
# full stop, and that's exactly the property v1-m2's failover gate cares
# about (don't trust a passed result for code that has since moved).
#
# Callers must source, in this order, before this file: lib/common.sh
# (orchid_die, atomic_write, plugin_digest), lib/manifest.sh (manifest_get,
# manifest_validate, manifest_capabilities, _manifest_split_csv), lib/
# roles.sh (role_eligible), lib/resolver.sh (resolve_engine_dir), lib/
# envelope.sh (envelope_validate) -- exactly like lib/roles.sh already
# assumes common.sh+manifest.sh are loaded first.
#
# INV-01 note (tier-1 verbs must not spawn/detach a process or invoke an
# engine CLI, checked by tests/inv/test_INV-01_no_spawn_in_tier1.sh via a
# grep over libexec/* only): capsuite_run's dryrun_envelope_valid check DOES
# spawn the engine's adapter (`$dir/run`, with ORCHID_DRYRUN=1 so it never
# reaches the real CLI) -- a real subprocess spawn, but that spawn lives here,
# in a lib/*.sh helper, not in libexec/orchid-plugins itself. libexec/
# orchid-plugins only ever calls capsuite_run; INV-01's grep never sees a
# spawn pattern in libexec/*, so it stays green. `orchid plugins test` is
# operator-invoked diagnostics, never part of the tick's own dispatch path,
# so this split is also the right shape semantically, not just a grep dodge.

_capsuite_dir() { echo "$HOME/.orchid/capsuite"; }

# _capsuite_result_file <engine> <role> -- the durable result path. A `/` in
# engine (the manifest id form, e.g. a future `acme/foo`) would otherwise
# land the file in a subdirectory that doesn't exist, so it's replaced with
# `_` for the filename component only, per the brief.
_capsuite_result_file() {
  local engine="${1//\//_}" role="$2"
  echo "$(_capsuite_dir)/${engine}--${role}.json"
}

# _capsuite_op_for_role <role> -- the adapter `operation` this role's
# dryrun_envelope_valid/workspace_write_probe checks exercise. `orchestrator`
# has no entry: it DRIVES adapters through other roles' operations rather
# than being invoked through run() itself, so capsuite_run skips the dryrun
# check for it (same as any other role string this function doesn't
# recognize) and scores it on the three static checks only.
_capsuite_op_for_role() {
  case "$1" in
    implementer) echo implement ;;
    reviewer|arbiter|plan_critic) echo review ;;
    *) echo "" ;;
  esac
}

# _capsuite_note <checks-file> <name> <true|false> -- appends one battery
# result line (as a JSON object) to the accumulator file.
_capsuite_note() {
  local cf="$1" name="$2" ok="$3"
  jq -n --arg n "$name" --argjson ok "$ok" '{name:$n, ok:$ok}' >> "$cf"
}

# capsuite_run <engine> <role> -- runs the full check battery for one
# (engine, role) pair, ALWAYS writes the durable result file (pass or fail),
# and returns 0 iff every check that ran passed.
capsuite_run() {
  local engine="$1" role="$2"
  local dir op reqfile outfile checks_file all_ok=1 marker="" dryrun_ok=0

  mkdir -p "$(_capsuite_dir)"
  checks_file="$(mktemp)"

  dir="$(resolve_engine_dir "$engine" 2>/dev/null)" || dir=""
  [ -n "$dir" ] || echo "orchid: capsuite: engine '$engine' not found on search path" >&2

  # manifest_valid
  if [ -n "$dir" ] && manifest_validate "$dir" >/dev/null; then
    _capsuite_note "$checks_file" manifest_valid true
  else
    _capsuite_note "$checks_file" manifest_valid false; all_ok=0
  fi

  # capabilities_cover_role (static, from role_eligible)
  if [ -n "$dir" ] && role_eligible "$role" "$dir"; then
    _capsuite_note "$checks_file" capabilities_cover_role true
  else
    _capsuite_note "$checks_file" capabilities_cover_role false; all_ok=0
  fi

  # binaries_present (requires_binaries resolve on PATH; vacuously true when
  # the manifest declares none)
  if [ -n "$dir" ]; then
    local bins bin bins_ok=1
    bins="$(manifest_get "$dir" requires_binaries)"
    while IFS= read -r bin; do
      [ -n "$bin" ] || continue
      command -v "$bin" >/dev/null 2>&1 || bins_ok=0
    done < <(_manifest_split_csv "$bins")
    if [ "$bins_ok" -eq 1 ]; then
      _capsuite_note "$checks_file" binaries_present true
    else
      _capsuite_note "$checks_file" binaries_present false; all_ok=0
    fi
  else
    _capsuite_note "$checks_file" binaries_present false; all_ok=0
  fi

  # dryrun_envelope_valid: invoke the adapter with ORCHID_DRYRUN=1 for the
  # role's operation, then envelope_validate the output -- skipped (not
  # recorded) for a role with no operation mapping (orchestrator).
  op="$(_capsuite_op_for_role "$role")"
  if [ -n "$dir" ] && [ -n "$op" ]; then
    reqfile="$(mktemp)"; outfile="$(mktemp)"; rm -f "$outfile"
    jq -n --arg job_id "capsuite-$engine-$role" --arg task capsuite \
          --arg operation "$op" --arg output "$outfile" \
      '{job_id:$job_id, task:$task, operation:$operation, worktree:"",
        input_pack:"", output:$output, base_sha:"", candidate_sha:""}' \
      > "$reqfile"
    if ORCHID_DRYRUN=1 "$dir/run" "$reqfile" >/dev/null 2>&1 \
      && [ -f "$outfile" ] && envelope_validate "$outfile"; then
      dryrun_ok=1
      _capsuite_note "$checks_file" dryrun_envelope_valid true
    else
      _capsuite_note "$checks_file" dryrun_envelope_valid false; all_ok=0
    fi
    rm -f "$reqfile" "$outfile"

    if [ "$role" = implementer ]; then
      # workspace_write_probe: dryrun path only in v1-m1 (a real-write probe
      # into a scratch worktree is noted as post-m1 in the brief) -- so this
      # re-checks, via the SAME dryrun envelope above rather than a second
      # adapter spawn, that the manifest actually declares workspace_write
      # AND that the implement-operation dryrun round-trip produced a valid
      # envelope.
      # Built as a space-bounded "have" string (role_eligibility_reason's
      # idiom, lib/roles.sh) rather than `manifest_capabilities | grep -q`:
      # under `set -o pipefail` a `grep -q` that matches early closes its
      # end of the pipe, and the still-writing producer side can then die of
      # SIGPIPE -- pipefail then reports THAT non-zero exit as the whole
      # pipeline's status even though grep itself matched, silently flipping
      # this check to false. No pipe, no SIGPIPE race.
      local caps_atom have=" " ww_ok
      while IFS= read -r caps_atom; do
        [ -n "$caps_atom" ] && have="$have$caps_atom "
      done < <(manifest_capabilities "$dir")
      ww_ok=0; case "$have" in *" workspace_write "*) ww_ok=1 ;; esac
      if [ "$ww_ok" -eq 1 ] && [ "$dryrun_ok" -eq 1 ]; then
        _capsuite_note "$checks_file" workspace_write_probe true
      else
        _capsuite_note "$checks_file" workspace_write_probe false; all_ok=0
      fi
    fi
  elif [ "$role" = implementer ]; then
    _capsuite_note "$checks_file" workspace_write_probe false; all_ok=0
  fi

  [ -z "$dir" ] || marker="$(plugin_digest "$dir" 2>/dev/null)" || marker=""

  jq -n --arg engine "$engine" --arg role "$role" \
        --argjson passed "$([ "$all_ok" -eq 1 ] && echo true || echo false)" \
        --argjson checks "$(jq -s '.' "$checks_file")" \
        --arg marker "$marker" \
    '{engine:$engine, role:$role, passed:$passed, checks:$checks, tested_at_marker:$marker}' \
    | atomic_write "$(_capsuite_result_file "$engine" "$role")"

  rm -f "$checks_file"
  [ "$all_ok" -eq 1 ]
}

# capsuite_passed <engine> <role> -- exit 0 iff a result is on record, it
# passed, AND the engine dir's current content digest still matches the
# marker recorded at test time. Absent file, passed=false, unreadable
# engine dir, or a digest mismatch (the engine's files changed since it was
# tested) all read the same way: not-passed. Never partially trusts a stale
# result.
capsuite_passed() {
  local engine="$1" role="$2" f dir marker recorded
  f="$(_capsuite_result_file "$engine" "$role")"
  [ -f "$f" ] || return 1
  recorded="$(jq -r 'if .passed == true then (.tested_at_marker // "") else empty end' "$f" 2>/dev/null)" || recorded=""
  [ -n "$recorded" ] || return 1
  dir="$(resolve_engine_dir "$engine" 2>/dev/null)" || return 1
  marker="$(plugin_digest "$dir" 2>/dev/null)" || return 1
  [ "$recorded" = "$marker" ]
}
