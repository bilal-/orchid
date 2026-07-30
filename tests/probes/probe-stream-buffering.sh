#!/usr/bin/env bash
# Deliberately no `-e` here (unlike this directory's other probes): the
# sampling loop below leans on plain `[ cond ] && stmt` and `kill -0`
# one-liners as ordinary statements, not loop/if conditions -- under `-e`
# a false `[ cond ]` on the left of `&&` aborts the whole script the first
# time the log hasn't grown yet, which is the common case early in a real
# run. `-u`/pipefail stay on; every risky command below is already guarded
# by its own `|| true`/`|| rc=$?`/loop-condition exemption.
set -uo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
# SPENDS REAL QUOTA: runs one small real round trip each for codex and claude.
#
# Open question (v1-m3 log-streaming amendment): plugins/engines/{codex,
# claude,agy}/run now stream each CLI's stdout into the job log in real
# time via `stdout="$(cli ... 2>"$err_file" | tee /dev/stderr)"` — but that
# idiom only proves bash's OWN plumbing (the pipe, tee, the launcher's `>>
# log 2>&1` redirect) doesn't buffer. Whether the underlying CLI itself
# buffers its OWN stdout internally until the whole reply is ready (in
# which case the job log would still jump from 0 bytes to full size in one
# shot, right at process exit, no matter how faithfully bash relays
# whatever the CLI hands it) is unverified against the real `codex`/
# `claude` binaries — this is a live-CLI question, not something a stub
# can answer by construction (the stub tests in tests/test_engine_{codex,
# claude,agy}.sh necessarily use stub CLIs that echo+sleep on purpose).
#
# Method: run the SAME pipeline shape the adapters use (`cli ... 2>err |
# tee /dev/stderr`, with that subshell's own stderr redirected to a scratch
# log file — the same fd chain runners/orchid-launch's `>> "$log" 2>&1`
# would set up around the real adapter), with a small prompt designed to
# produce a few lines of reply text. While the CLI is still running,
# sample the scratch log's byte size once a second. If any sample taken
# BEFORE the process exits is non-zero, the CLI is streaming its reply
# incrementally (matching STDOUT); if the log stays at 0 bytes for the
# CLI's whole run and only appears once the process has exited, all of its
# output arrived in one buffered shot at the end.
#
# PROBE-RESULT per engine, on its own line:
#   STREAMS  — log grew while the process was still alive.
#   BUFFERED — log was still 0 bytes at every pre-exit sample; content
#              appeared only once the process had already exited.
#   SKIP / AUTH-UNAVAILABLE / TIMEOUT — as usual (see README.md).
#
# Last run 2026-07-29: codex BUFFERED, claude BUFFERED — hence the adapter
# heartbeat (lib/heartbeat.sh, wired into plugins/engines/{codex,claude,
# agy}/run): tee-ing a stream that never arrives until process exit doesn't
# make it arrive sooner, so this probe's real-CLI result is what motivated
# proving the ENGINE PROCESS IS ALIVE (a background heartbeat line on a
# fixed interval) instead of continuing to rely on the CLI's own stdout
# ever flushing early enough to matter.

PROMPT='Count to 5. Print exactly one number per line (just the digit, nothing else) and nothing before or after. Do not use any tools.'
MAX_WAIT_S=60

is_auth_failure() {  # combined stdout+stderr text
  printf '%s' "$1" | grep -qiE 'login|auth|unauthorized|not authenticated|api.?key'
}

# probe_engine <engine-name> ("codex" or "claude") — guards on installation,
# builds a scratch git fixture, runs that engine's adapter-shaped pipeline
# in the background, samples the scratch log while it runs, and prints
# exactly one PROBE-RESULT line for this engine.
probe_engine() {
  local engine="$1"
  if ! command -v "$engine" >/dev/null 2>&1; then
    echo "PROBE-RESULT: $engine SKIP ($engine not installed)"
    return 0
  fi

  local scratch log err_file
  scratch="$(mktemp -d)"; log="$(mktemp)"; err_file="$(mktemp)"
  # A real git repo, same fixture shape as the other probes/adapters
  # (codex's --skip-git-repo-check still expects to be run somewhere sane).
  # Guarded (not `set -e`-reliant, per the top-of-file note): a fixture
  # failure here still needs to end in a clean PROBE-RESULT line, not a
  # codex/claude invocation against a half-built scratch dir.
  if ! git -C "$scratch" init -q . >/dev/null 2>&1 || \
     ! git -C "$scratch" -c user.email=probe@orchid.local -c user.name="Orchid Probe" \
         commit -q --allow-empty -m root >/dev/null 2>&1; then
    echo "PROBE-RESULT: $engine ENV-UNAVAILABLE (git fixture failed)"
    rm -rf "$scratch"; rm -f "$log" "$err_file"
    return 0
  fi

  # Background the exact adapter-shaped pipeline, with ITS OWN stderr (what
  # the tee writes to) redirected to the scratch log — the same fd this
  # probe is sampling. `set -m` so the pipeline lands in its own process
  # group (mirrors the other probes' with_timeout, so a stuck CLI can be
  # killed by group without orphaning anything).
  set -m
  case "$engine" in
    codex)
      ( cd "$scratch" && printf '%s' "$PROMPT" \
          | codex exec --sandbox read-only --skip-git-repo-check - 2>"$err_file" \
          | tee /dev/stderr ) >"$scratch/stdout.txt" 2>"$log" &
      ;;
    claude)
      ( cd "$scratch" && printf '%s' "$PROMPT" \
          | claude -p 2>"$err_file" \
          | tee /dev/stderr ) >"$scratch/stdout.txt" 2>"$log" &
      ;;
  esac
  local pid=$!
  set +m

  local elapsed=0 saw_growth_before_exit=false last_pre_exit_size=0
  while kill -0 "$pid" 2>/dev/null; do
    local size; size="$(wc -c <"$log" 2>/dev/null | tr -d ' ')"; size="${size:-0}"
    [ "$size" -gt 0 ] && saw_growth_before_exit=true
    last_pre_exit_size="$size"
    [ "$elapsed" -lt "$MAX_WAIT_S" ] || break
    sleep 1
    elapsed=$((elapsed + 1))
  done

  local rc=0
  if [ "$elapsed" -ge "$MAX_WAIT_S" ] && kill -0 "$pid" 2>/dev/null; then
    kill -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    echo "PROBE-RESULT: $engine TIMEOUT (no exit within ${MAX_WAIT_S}s; log was $last_pre_exit_size bytes at the last pre-timeout sample)"
    rm -rf "$scratch"; rm -f "$log" "$err_file"
    return 0
  fi
  wait "$pid" 2>/dev/null || rc=$?

  local final_size; final_size="$(wc -c <"$log" 2>/dev/null | tr -d ' ')"; final_size="${final_size:-0}"
  local stderr_content; stderr_content="$(cat "$err_file" 2>/dev/null || true)"
  local stdout_content; stdout_content="$(cat "$scratch/stdout.txt" 2>/dev/null || true)"
  local combined="$stdout_content"$'\n'"$stderr_content"

  if is_auth_failure "$combined"; then
    echo "PROBE-RESULT: $engine AUTH-UNAVAILABLE ($(printf '%s' "$combined" | grep -iE 'login|auth|unauthorized|not authenticated|api.?key' | head -n1))"
    rm -rf "$scratch"; rm -f "$log" "$err_file"
    return 0
  fi

  if [ "$saw_growth_before_exit" = true ]; then
    echo "PROBE-RESULT: $engine STREAMS (log was already $last_pre_exit_size of $final_size bytes while $engine was still running; rc=$rc)"
  else
    echo "PROBE-RESULT: $engine BUFFERED (log stayed 0 bytes for the entire run, then reached $final_size bytes only after $engine exited; rc=$rc)"
  fi
  rm -rf "$scratch"; rm -f "$log" "$err_file"
}

probe_engine codex
probe_engine claude
exit 0
