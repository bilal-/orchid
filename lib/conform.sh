#!/usr/bin/env bash
# Plugin CONTRACT gate (v1-m3 Task 10). `conform_run <plugin-dir>` runs a
# fixed, seven-check battery against a THIRD-PARTY plugin dir -- the
# author's own pre-flight, runnable on any machine, with NO repo state at
# all (no `.orchid`, no config, no resolver/role lookups): unlike `lib/
# capsuite.sh`'s `capsuite_run` (the ROLE-pairing gate: "is THIS installed
# engine eligible for THIS role, on THIS operator's machine, right now"),
# conform never touches a repo, never resolves a role, and never writes a
# durable result file -- it just prints `ok: <name>` / `FAIL: <name>:
# <reason>` for each of the seven checks plus a final "N/7 checks passed"
# summary, and its own exit status is nonzero iff any check failed. See
# docs/extending/conformance.md for the battery reference and docs/
# extending/first-engine.md for the "first adapter in under an hour" walk
# that ends with a green `orchid plugins conform`.
#
# Every probe below invokes the plugin's OWN entrypoint under
# ORCHID_DRYRUN=1 -- conform NEVER spends real quota, same guarantee lib/
# capsuite.sh's dryrun_envelope_valid check gives (see that file's header).
#
# Callers must source, in this order, before this file: lib/common.sh
# (orchid_die, with_timeout), lib/manifest.sh (manifest_get,
# manifest_validate, _manifest_split_csv, manifest_permissions -- the last
# via lib/spawn.sh), lib/spawn.sh (spawn_child_env), lib/envelope.sh
# (envelope_validate) -- exactly the same sourcing discipline lib/
# capsuite.sh already documents for itself.
#
# INV-01 carve-out (tier-1 verbs must not spawn/detach a process, checked
# by tests/inv/test_INV-01_no_spawn_in_tier1.sh via a grep over libexec/*
# only): every check below that invokes the plugin's entrypoint DOES spawn
# a real subprocess (with ORCHID_DRYRUN=1, so it never reaches a real
# vendor CLI) -- but that spawn lives here, in a lib/*.sh helper, not in
# libexec/orchid-plugins itself, which only ever calls `conform_run`.
# INV-01's grep never sees a spawn/background pattern in libexec/*, so it
# stays green -- identical reasoning to lib/capsuite.sh's own carve-out
# note. `orchid plugins conform` is operator- (or CI-) invoked diagnostics,
# never part of the tick's own dispatch path, so the split is the right
# shape semantically too, not just a grep dodge.
#
# INV-06 note (launcher-only engine spawning, tests/inv/
# test_INV-06_launcher_only.sh): that test's grep looks for literal
# `plugins/engines`/`orchid-launch` text outside runners/ -- this file
# never names either (it takes an arbitrary caller-supplied plugin dir, the
# same way lib/capsuite.sh's `$dir/run` does), so it never matches and
# needs no explicit carve-out comment there. Every spawn below closes stdin
# (`</dev/null`, or `0<&-` for the stdin_closed_safe check's second mode)
# so a plugin that tries to read an interactive prompt can never hang this
# diagnostic waiting on input that will never arrive.

# ORCHID_CONFORM_TIMEOUT_S: the stdin_closed_safe check's with_timeout
# budget. Spec'd value is 30s; overridable ONLY so tests/test_conform.sh
# can plant a deliberately-hanging fixture without a real test run
# spending 30+ real seconds per RED scenario -- production callers (`orchid
# plugins conform`) never set this, so they always get the documented 30s.
: "${ORCHID_CONFORM_TIMEOUT_S:=30}"

# _conform_reason: set by each `_conform_check_*` helper on failure, read
# by `conform_run` immediately after that helper returns false. Simple
# single-slot global (like `_plugins_had_collision` in libexec/
# orchid-plugins) rather than threading a reason back through stdout --
# these helpers already use their own stdout/stderr redirects freely
# without worrying about polluting a captured value.
_conform_reason=""

# _conform_reqdoc <job_id> <task> <operation> <output> -- prints a minimal
# request document (same field set lib/capsuite.sh's dryrun_envelope_valid
# check builds) to stdout. `worktree`/`input_pack`/`base_sha`/
# `candidate_sha` are always empty: every check here runs a DRYRUN probe,
# and a conforming adapter's dryrun branch (per docs/extending/
# first-engine.md) never reads any of those fields.
_conform_reqdoc() {
  local job_id="$1" task="$2" operation="$3" output="$4"
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg output "$output" \
    '{job_id:$job_id, task:$task, operation:$operation, worktree:"",
      input_pack:"", output:$output, base_sha:"", candidate_sha:""}'
}

# _conform_ops_for_dir <plugin-dir> -- the operations declared_ops_dryrun
# must probe, one per line, per the brief's capability-implication table:
#   kind=hook           -> hook ONLY (a hook handler's whole contract is
#                          operation=hook; it is never invoked any other
#                          way, so probing review/implement/orchestrate
#                          against it would just be testing a shape the
#                          adapter is never asked to support)
#   everything else     -> review ALWAYS (every non-hook adapter this
#                          kernel launches is asked to review at least once
#                          across some role, whether or not that engine is
#                          ever actually BOUND to a reviewing role -- the
#                          contract gate checks capability, not binding),
#                          PLUS implement iff capabilities declare
#                          workspace_write, PLUS orchestrate iff
#                          capabilities declare BOTH shell AND git.
# `review` is always printed FIRST for the non-hook branch -- callers that
# want a single representative op (stdin_closed_safe, no_output_pollution,
# env_survives_hygiene, exit_discipline; see _conform_primary_op) get a
# stable, always-present choice regardless of which of the optional two a
# given plugin also declares.
_conform_ops_for_dir() {
  local dir="$1" kind caps have=" " atom has_shell=0 has_git=0
  kind="$(manifest_get "$dir" kind)"
  if [ "$kind" = hook ]; then
    echo hook
    return 0
  fi
  echo review
  caps="$(manifest_get "$dir" capabilities)"
  while IFS= read -r atom; do
    [ -n "$atom" ] && have="$have$atom "
  done < <(_manifest_split_csv "$caps")
  case "$have" in *" workspace_write "*) echo implement ;; esac
  case "$have" in *" shell "*) has_shell=1 ;; esac
  case "$have" in *" git "*) has_git=1 ;; esac
  if [ "$has_shell" -eq 1 ] && [ "$has_git" -eq 1 ]; then
    echo orchestrate
  fi
  return 0
}

# _conform_primary_op <plugin-dir> -- the one op used by the four checks
# that don't need to walk the whole declared-ops list themselves (they're
# probing an INVOCATION property -- stdin handling, filesystem discipline,
# env hygiene, exit discipline -- not the per-operation envelope contract
# declared_ops_dryrun already covers exhaustively). Always the first line
# of _conform_ops_for_dir: `review` for a non-hook plugin, `hook` for a
# kind=hook plugin.
_conform_primary_op() {
  _conform_ops_for_dir "$1" | head -n1
}

# _conform_check_manifest_valid <plugin-dir> -- thin wrapper around lib/
# manifest.sh's own validator so its detailed FAIL text (which names the
# exact offending key/value) becomes this check's reason on failure.
_conform_check_manifest_valid() {
  local dir="$1" out
  if out="$(manifest_validate "$dir" 2>&1)"; then
    return 0
  fi
  _conform_reason="$out"
  return 1
}

# _conform_check_entrypoint <plugin-dir> -- `entrypoint=` (default `run`,
# same fallback lib/manifest.sh's validator and the trust arm both use)
# must name a regular, executable file inside the plugin dir.
_conform_check_entrypoint() {
  local dir="$1" ep
  ep="$(manifest_get "$dir" entrypoint run)"
  if [ -n "$ep" ] && [ -f "$dir/$ep" ] && [ -x "$dir/$ep" ]; then
    return 0
  fi
  _conform_reason="entrypoint '$ep' is not an executable file in $dir"
  return 1
}

# _conform_check_declared_ops_dryrun <plugin-dir> <entrypoint-path> -- for
# EVERY operation _conform_ops_for_dir implies, invokes the adapter under
# ORCHID_DRYRUN=1 with a minimal request naming that operation, then
# envelope_validate's the result -- envelope_validate itself enforces the
# right union (implement -> summary; review/critique -> verdict +
# scope_complete; orchestrate -> actions[] + summary; hook -> artifact +
# summary), so a single call covers per-operation shape AND the common
# envelope fields. Fails (naming every offending op) iff ANY implied
# operation's round trip fails.
#
# Crucially, envelope_validate ALONE is not enough: it checks that the
# envelope's `.operation` field satisfies WHATEVER union that field itself
# names -- it never cross-checks that field against the operation the
# REQUEST actually asked for. An adapter that hardcodes one easy shape
# (e.g. always answers `{"operation":"review", "verdict":"approve", ...}`
# regardless of what it was asked to do) would validate cleanly on every
# single probe and pass this check 7/7 while never actually implementing
# `implement`/`orchestrate` at all -- caught in review against a fixture
# built to exercise exactly that gap. So after envelope_validate succeeds,
# this also asserts the envelope's own `.operation` echoes back the SAME
# operation this iteration requested; a mismatch fails naming both.

# _conform_scratch_cwd -- a fresh throwaway directory. EVERY check below
# that spawns the adapter runs it with CWD pointed here, never the caller's
# own cwd (typically the operator's real repo checkout): a conforming
# adapter is only ever supposed to write to the request's `output` path
# (docs/specs/plugins.md), so its cwd should never matter. This is what
# keeps a plugin that DOESN'T honor that (the exact thing
# no_output_pollution below is built to catch) from leaving debris in the
# operator's actual working directory as a side effect of some OTHER
# check's invocation, one that isn't itself inspecting the filesystem.
_conform_scratch_cwd() { mktemp -d; }

_conform_check_declared_ops_dryrun() {
  local dir="$1" ep="$2" op reqfile outfile ok=1 failed="" scratch rc got_op
  scratch="$(_conform_scratch_cwd)"
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    reqfile="$(mktemp)"; outfile="$(mktemp)"; rm -f "$outfile"
    _conform_reqdoc "conform-declared_ops_dryrun-$op" conform "$op" "$outfile" > "$reqfile"
    rc=0
    ( cd "$scratch" && ORCHID_DRYRUN=1 "$dir/$ep" "$reqfile" </dev/null >/dev/null 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$outfile" ] && envelope_validate "$outfile"; then
      got_op="$(envelope_field "$outfile" '.operation')"
      if [ "$got_op" = "$op" ]; then
        :
      else
        ok=0; failed="$failed $op(envelope claims operation '$got_op' for a '$op' probe)"
      fi
    else
      ok=0; failed="$failed $op"
    fi
    rm -f "$reqfile" "$outfile"
  done < <(_conform_ops_for_dir "$dir")
  rm -rf "$scratch"
  if [ "$ok" -eq 1 ]; then
    return 0
  fi
  _conform_reason="operation(s) failed the dryrun/envelope round trip:$failed"
  return 1
}

# _conform_check_stdin_closed_safe <plugin-dir> <entrypoint-path> -- the
# adapter must not hang under EITHER of the two stdin shapes production
# invocation can present: `</dev/null` (the kernel launcher's own shape,
# runners/orchid-launch) and a fully CLOSED fd 0 (`0<&-`, the more hostile
# of the two -- a `read` against it errors immediately rather than EOFing,
# but a misbehaved adapter waiting on ANY input at all can still hang
# regardless of which shape it inherits). Each is bounded by with_timeout
# ORCHID_CONFORM_TIMEOUT_S (30s in production); a real timeout (124) OR a
# missing/invalid envelope on either shape fails this check.
_conform_check_stdin_closed_safe() {
  local dir="$1" ep="$2" op reqfile outfile rc secs="$ORCHID_CONFORM_TIMEOUT_S" scratch
  op="$(_conform_primary_op "$dir")"
  scratch="$(_conform_scratch_cwd)"

  reqfile="$(mktemp)"; outfile="$(mktemp)"; rm -f "$outfile"
  _conform_reqdoc "conform-stdin_closed_safe" conform "$op" "$outfile" > "$reqfile"
  rc=0
  ( cd "$scratch" && ORCHID_DRYRUN=1 with_timeout "$secs" "$dir/$ep" "$reqfile" </dev/null >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" -eq 124 ]; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter did not return within ${secs}s under stdin </dev/null (timed out)"
    return 1
  fi
  if [ ! -f "$outfile" ] || ! envelope_validate "$outfile"; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter produced no valid envelope under stdin </dev/null"
    return 1
  fi
  rm -f "$reqfile" "$outfile"

  reqfile="$(mktemp)"; outfile="$(mktemp)"; rm -f "$outfile"
  _conform_reqdoc "conform-stdin_closed_safe" conform "$op" "$outfile" > "$reqfile"
  rc=0
  ( cd "$scratch" && ORCHID_DRYRUN=1 with_timeout "$secs" "$dir/$ep" "$reqfile" 0<&- >/dev/null 2>&1 ) || rc=$?
  if [ "$rc" -eq 124 ]; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter did not return within ${secs}s with stdin closed (0<&-, timed out)"
    return 1
  fi
  if [ ! -f "$outfile" ] || ! envelope_validate "$outfile"; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter produced no valid envelope with stdin closed (0<&-)"
    return 1
  fi
  rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
  return 0
}

# _conform_check_no_output_pollution <plugin-dir> <entrypoint-path> -- runs
# the adapter with its CWD set to a fresh scratch dir and a kernel-chosen
# output path inside that same scratch dir, snapshotting the scratch tree
# before and after: the only new path allowed to survive is the output
# file itself. A tempfile the adapter creates and cleans up before exit
# never shows up in the "after" snapshot at all, so that's implicitly
# allowed too -- only a path that's STILL there after exit and isn't the
# output file fails this check.
_conform_check_no_output_pollution() {
  local dir="$1" ep="$2" op scratch outfile reqfile before after new_paths rc
  op="$(_conform_primary_op "$dir")"
  scratch="$(_conform_scratch_cwd)"
  outfile="$scratch/envelope.json"
  reqfile="$(mktemp)"
  _conform_reqdoc "conform-no_output_pollution" conform "$op" "$outfile" > "$reqfile"

  before="$(find "$scratch" -mindepth 1 | sort)"
  rc=0
  ( cd "$scratch" && ORCHID_DRYRUN=1 "$dir/$ep" "$reqfile" </dev/null >/dev/null 2>&1 ) || rc=$?
  after="$(find "$scratch" -mindepth 1 | sort)"
  rm -f "$reqfile"

  # -vxF (exact whole-line match), NOT -vF (substring): a plain -vF would
  # also filter out a genuinely polluting path that merely CONTAINS outfile
  # as a substring (e.g. an adapter dropping "envelope.json.bak" alongside
  # the real "envelope.json" output) -- silently passing this check on
  # exactly the leftover file it exists to catch.
  new_paths="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null \
    | grep -vxF "$outfile" || true)"

  if [ -n "$new_paths" ]; then
    rm -rf "$scratch"
    _conform_reason="unexpected new path(s) outside the output location: $(printf '%s' "$new_paths" | tr '\n' ' ')"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ ! -f "$outfile" ] || ! envelope_validate "$outfile"; then
    rm -rf "$scratch"
    _conform_reason="adapter failed or produced no valid envelope at the requested output path"
    return 1
  fi
  rm -rf "$scratch"
  return 0
}

# _conform_check_env_survives_hygiene <plugin-dir> <entrypoint-path> -- the
# fixed BASE allowlist the real launcher's env -i + spawn_child_env applies
# (runners/orchid-launch: PATH, HOME, USER, LANG, TERM, TMPDIR, any LC_*,
# any ORCHID_*), with NO permissions opt-ins granted -- deliberately
# filtered out of spawn_child_env's own output below (via lib/spawn.sh's
# `_launch_base_allowed`) rather than just calling spawn_child_env plain,
# so this check's verdict never depends on whether THIS conform invocation
# happens to have a declared `permissions=` var set in its own ambient
# environment (a plain call would forward it if so, silently weakening the
# check on some machines/shells and not others). A dryrun round trip must
# still produce a valid envelope under that stripped-to-base environment:
# dryrun must never depend on a real credential, full stop.
_conform_check_env_survives_hygiene() {
  local dir="$1" ep="$2" op reqfile outfile line name rc=0 scratch
  local child_env; child_env=()
  op="$(_conform_primary_op "$dir")"
  scratch="$(_conform_scratch_cwd)"
  reqfile="$(mktemp)"; outfile="$(mktemp)"; rm -f "$outfile"
  _conform_reqdoc "conform-env_survives_hygiene" conform "$op" "$outfile" > "$reqfile"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"
    _launch_base_allowed "$name" || continue
    child_env+=("$line")
  done < <(spawn_child_env "$dir")

  if [ "${#child_env[@]}" -gt 0 ]; then
    ( cd "$scratch" && env -i "${child_env[@]}" ORCHID_DRYRUN=1 "$dir/$ep" "$reqfile" </dev/null >/dev/null 2>&1 ) || rc=$?
  else
    ( cd "$scratch" && env -i ORCHID_DRYRUN=1 "$dir/$ep" "$reqfile" </dev/null >/dev/null 2>&1 ) || rc=$?
  fi

  if [ "$rc" -ne 0 ] || [ ! -f "$outfile" ] || ! envelope_validate "$outfile"; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter failed or produced no valid envelope under env -i + spawn_child_env's base allowlist (rc=$rc)"
    return 1
  fi
  rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
  return 0
}

# _conform_check_exit_discipline <plugin-dir> <entrypoint-path> -- a
# request naming an operation no contract recognizes ("bogus") must exit
# NONZERO and still write a well-formed envelope whose status is NOT "ok"
# (envelope_validate only enforces the per-operation payload union when
# status=="ok", so this additionally requires status!=ok itself -- an
# adapter can't satisfy this check by fabricating an "ok" envelope for an
# operation it doesn't understand).
_conform_check_exit_discipline() {
  local dir="$1" ep="$2" reqfile outfile rc=0 status scratch
  scratch="$(_conform_scratch_cwd)"
  reqfile="$(mktemp)"; outfile="$(mktemp)"; rm -f "$outfile"
  _conform_reqdoc "conform-exit_discipline" conform bogus "$outfile" > "$reqfile"
  ( cd "$scratch" && ORCHID_DRYRUN=1 "$dir/$ep" "$reqfile" </dev/null >/dev/null 2>&1 ) || rc=$?

  if [ "$rc" -eq 0 ]; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter exited 0 for an unsupported operation ('bogus') -- must exit nonzero"
    return 1
  fi
  if [ ! -f "$outfile" ]; then
    rm -f "$reqfile"; rm -rf "$scratch"
    _conform_reason="adapter exited nonzero for an unsupported operation but wrote no envelope"
    return 1
  fi
  if ! envelope_validate "$outfile"; then
    rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
    _conform_reason="adapter wrote a malformed envelope for an unsupported operation"
    return 1
  fi
  status="$(jq -r '.status' "$outfile")"
  rm -f "$reqfile" "$outfile"; rm -rf "$scratch"
  if [ "$status" = ok ]; then
    _conform_reason="adapter wrote status=ok for an unsupported operation -- must be a failed status"
    return 1
  fi
  return 0
}

# conform_run <plugin-dir> -- the full seven-check battery. Prints one
# `ok: <name>` / `FAIL: <name>: <reason>` line per check plus a final
# "N/7 checks passed" summary; returns 0 iff all seven passed. If the
# entrypoint isn't executable, the five checks that need to SPAWN it are
# reported as failed-and-skipped (a clear reason) rather than attempted --
# manifest_valid and entrypoint_executable are the only two checks
# unaffected by that.
conform_run() {
  local dir="$1" ep total=7 passed=0

  dir="$(cd "$dir" 2>/dev/null && pwd)" || {
    echo "orchid: conform: no such directory: $1" >&2
    return 1
  }

  if _conform_check_manifest_valid "$dir"; then
    echo "ok: manifest_valid"; passed=$((passed + 1))
  else
    echo "FAIL: manifest_valid: $_conform_reason"
  fi

  ep="$(manifest_get "$dir" entrypoint run)"
  if _conform_check_entrypoint "$dir"; then
    echo "ok: entrypoint_executable"; passed=$((passed + 1))
  else
    echo "FAIL: entrypoint_executable: $_conform_reason"
  fi

  if [ -f "$dir/$ep" ] && [ -x "$dir/$ep" ]; then
    if _conform_check_declared_ops_dryrun "$dir" "$ep"; then
      echo "ok: declared_ops_dryrun"; passed=$((passed + 1))
    else
      echo "FAIL: declared_ops_dryrun: $_conform_reason"
    fi

    if _conform_check_stdin_closed_safe "$dir" "$ep"; then
      echo "ok: stdin_closed_safe"; passed=$((passed + 1))
    else
      echo "FAIL: stdin_closed_safe: $_conform_reason"
    fi

    if _conform_check_no_output_pollution "$dir" "$ep"; then
      echo "ok: no_output_pollution"; passed=$((passed + 1))
    else
      echo "FAIL: no_output_pollution: $_conform_reason"
    fi

    if _conform_check_env_survives_hygiene "$dir" "$ep"; then
      echo "ok: env_survives_hygiene"; passed=$((passed + 1))
    else
      echo "FAIL: env_survives_hygiene: $_conform_reason"
    fi

    if _conform_check_exit_discipline "$dir" "$ep"; then
      echo "ok: exit_discipline"; passed=$((passed + 1))
    else
      echo "FAIL: exit_discipline: $_conform_reason"
    fi
  else
    echo "FAIL: declared_ops_dryrun: entrypoint not executable, skipped"
    echo "FAIL: stdin_closed_safe: entrypoint not executable, skipped"
    echo "FAIL: no_output_pollution: entrypoint not executable, skipped"
    echo "FAIL: env_survives_hygiene: entrypoint not executable, skipped"
    echo "FAIL: exit_discipline: entrypoint not executable, skipped"
  fi

  echo "$passed/$total checks passed"
  [ "$passed" -eq "$total" ]
}

# conform_run_notify <plugin-dir> -- kind=notify's OWN, much narrower conform
# path (v1-m4 Task 7). A notify channel plugin has no request/envelope
# contract at all (docs/specs/plugins.md: its whole contract is `send
# <question-id> <text>`, an exit code, nothing else) -- there is no dryrun
# operation to probe, no envelope to validate, no stdin/output-pollution/
# env-hygiene/exit-discipline story shaped like an engine's. Running the
# full seven-check battery against one would either force a fake
# envelope-shaped contract onto a plugin kind that doesn't have one, or
# (worse) actually invoke `send`, which could attempt a REAL outbound
# message even under ORCHID_DRYRUN -- something no notify plugin's contract
# promises to honor the way an engine's dryrun branch does. So this is a
# minimal LINT instead: manifest_valid (reused from the engine battery
# above -- generic, not engine-specific) + entrypoint_executable (same
# reuse) -- send is never invoked. `orchid plugins conform` (libexec/
# orchid-plugins) dispatches here for kind=notify instead of conform_run,
# based on the plugin dir's own manifest kind=.
conform_run_notify() {
  local dir="$1" total=2 passed=0

  dir="$(cd "$dir" 2>/dev/null && pwd)" || {
    echo "orchid: conform: no such directory: $1" >&2
    return 1
  }

  echo "notify plugins: send-contract lint only (manifest + entrypoint; no dryrun battery -- kind=notify has no request/envelope contract to probe, and this never invokes send)"

  if _conform_check_manifest_valid "$dir"; then
    echo "ok: manifest_valid"; passed=$((passed + 1))
  else
    echo "FAIL: manifest_valid: $_conform_reason"
  fi

  if _conform_check_entrypoint "$dir"; then
    echo "ok: entrypoint_executable"; passed=$((passed + 1))
  else
    echo "FAIL: entrypoint_executable: $_conform_reason"
  fi

  echo "$passed/$total checks passed"
  [ "$passed" -eq "$total" ]
}
