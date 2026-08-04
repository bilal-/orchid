#!/usr/bin/env bash
# orchid_run_engine_cli <err_file> <stdout-var> <rc-var> <cwd|-> <prompt|-> <cli-argv...>
#
# v1-m3, round 2 of the live-run log-streaming finding: the first fix in
# this milestone (`stdout="$(cli ... 2>"$err_file" | tee /dev/stderr)"`)
# proved harmless but INSUFFICIENT against the real engines --
# tests/probes/probe-stream-buffering.sh's first live run reported BOTH
# codex and claude BUFFERED (see that probe's header for the exact result):
# the real CLIs hold their own stdout internally and only write it out in
# one shot at process exit, no matter how faithfully bash relays whatever
# bytes it's handed. Tee-ing a stream that never arrives until the end
# doesn't make it arrive sooner. The job log for a real long-running engine
# call was therefore STILL silent (zero bytes) for the whole run, and
# `jobs check`'s log-mtime stall detector could still falsely kill it.
#
# This function is the definitive fix: instead of proving the ENGINE is
# still producing output (unprovable — the CLI itself decides when to
# flush), it proves the ENGINE PROCESS IS STILL ALIVE, independent of
# whatever it has or hasn't written yet. A background heartbeat subshell
# appends one `[hb <UTC time>] engine pid <pid> cpu <ps time>` line to this
# script's own stderr -- which the launcher/tick's `>> "$log" 2>&1`
# redirect already captures into the job log -- every `ORCHID_HB_INTERVAL_S`
# seconds (default 30; test suites override this to 1 to keep fixtures
# fast, see tests/test_engine_{codex,claude,agy}.sh) for as long as the
# engine's real OS pid is alive, so the log's mtime advances for the WHOLE
# run even if the engine itself never flushes a single byte before exit.
#
# ACCEPTED TRADE-OFF (documented here once, at the one place all three
# adapters route through): a hung-but-still-alive engine process (e.g.
# spinning, or blocked waiting on something that will never resolve) now
# survives past what the stall detector would previously have caught --
# the heartbeat can't distinguish "alive and making progress" from "alive
# and stuck," only "alive" from "gone." The request's own `deadline_s`
# (enforced by the launcher/tick's outer `with_timeout`) remains the real
# backstop for that case, not the log-mtime stall check. The heartbeat
# line's `cpu` field (`ps -o time= -p <pid>`, cumulative CPU time) is
# carried specifically so a FUTURE spinning-check (kernel.md's CPU-delta
# guard: comparing cpu-time deltas across heartbeats to tell "burning CPU"
# from "genuinely idle/blocked") has the raw signal already in the log to
# consume, without this function needing to make that judgment call itself.
#
# WHY A REAL PID, NOT JUST "SOMETHING BACKGROUNDED": the whole point of the
# `cpu` field is to reflect the ENGINE's own CPU usage, not some wrapper's.
# Backgrounding `cmd | tee` as a single job only exposes tee's own pid via
# `$!` (bash pipeline semantics: `$!` after backgrounding a pipe is the
# LAST stage's pid) -- `ps -o time=` on that would report tee's own
# (trivially ~zero) CPU time forever, which is worse than no signal at all.
# To get the engine's own real pid from `$!`, the engine must be
# backgrounded ALONE, with no `|` operator touching it directly. That
# rules out the previous `printf '%s' "$prompt" | cli ... | tee
# /dev/stderr` idiom outright (both pipes disqualify a bare `$!`), hence
# this function's restructuring:
#   - the prompt (if any) is written to a temp FILE and fed to the engine
#     via plain `<` stdin redirection instead of a pipe from `printf`;
#   - the engine's stdout is redirected (plain `>`, not `|`) to a FIFO;
#   - a separate `tee /dev/stderr <fifo >out_tmp` process, started FIRST so
#     it's ready to read before the engine's write-open on the FIFO can
#     block, relays the engine's output live to the log (harmless best-
#     effort, catches whatever a given CLI DOES flush) while also
#     accumulating it into `out_tmp` for this function to hand back as the
#     caller's captured stdout text -- semantically identical to what
#     `stdout="$(cli 2>err | tee /dev/stderr)"` produced before, just
#     wired through a FIFO instead of a `|` so the engine itself can still
#     be backgrounded alone.
#   - the engine's real stderr is UNCHANGED: still a plain `2>"$err_file"`
#     redirect straight on the engine invocation, exactly as before this
#     function existed.
#
# Params:
#   err_file  - path the engine's own real stderr is redirected to (same
#               file every call site already `mktemp`s for classify()).
#   stdout-var/rc-var
#             - NAMES (plain strings, e.g. "stdout"/"rc") of the caller's
#               own variables to fill in with the engine's captured stdout
#               text and exit status, via `printf -v`. Every local variable
#               THIS function declares is prefixed `_hb_` specifically so
#               it can never collide with whatever name a caller passes
#               here (bash has no real namerefs in 3.2 -- a same-named
#               local would shadow the caller's target instead of writing
#               through to it; this was caught and fixed during
#               development by testing with the exact caller-side name
#               "rc", which collided with an earlier unprefixed draft).
#   cwd|-     - directory to run the engine in (a task worktree), or `-`
#               for "don't cd" (the review-only call sites already run
#               from the adapter's own cwd). Restored via a plain `cd`
#               back to the ORIGINAL directory immediately after
#               backgrounding the engine -- not a subshell -- since a
#               subshell wrapper is exactly what would cost us the real
#               pid again.
#   prompt|-  - prompt text to feed the engine via stdin (written to a
#               temp file, then `<` redirected), or `-` for "no stdin"
#               (agy's argv-carried prompt needs none).
#   cli-argv  - the engine binary + its own flags/args, executed directly
#               (never wrapped in a subshell or an explicit `|`), so `$!`
#               right after backgrounding it is genuinely its own pid.
orchid_run_engine_cli() {
  local err_file="$1" _out_var="$2" _rc_var="$3" _hb_cwd="$4" _hb_prompt="$5"; shift 5
  local _hb_fifo_dir _hb_fifo _hb_out_tmp _hb_prompt_file="" _hb_tee_pid _hb_cli_pid _hb_hb_pid \
        _hb_rc _hb_interval _hb_cpu _hb_orig_pwd

  # Allocate a private directory first, then create the FIFO at a fixed name
  # inside it. No attacker can claim the path in a gap between unallocated
  # name generation and mkfifo.
  _hb_fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/orchid-hb.XXXXXX")"
  _hb_fifo="$_hb_fifo_dir/stream"
  mkfifo "$_hb_fifo"
  _hb_out_tmp="$(mktemp)"
  # Reader started BEFORE the engine's write-open below: opening a FIFO for
  # writing blocks until a reader exists, so starting `tee` first avoids a
  # race where the engine would otherwise hang waiting on this same FIFO.
  tee "$_hb_out_tmp" <"$_hb_fifo" >&2 &
  _hb_tee_pid=$!

  if [ "$_hb_prompt" != "-" ]; then
    _hb_prompt_file="$(mktemp)"; printf '%s' "$_hb_prompt" > "$_hb_prompt_file"
  fi

  # Plain `cd`/`cd back`, not a `(cd ... && cmd) &` subshell wrapper -- see
  # the "WHY A REAL PID" note above for why a subshell here would silently
  # reintroduce the same wrong-pid problem this function exists to avoid.
  if [ "$_hb_cwd" != "-" ]; then
    _hb_orig_pwd="$PWD"
    if ! cd "$_hb_cwd"; then
      kill "$_hb_tee_pid" 2>/dev/null || true
      wait "$_hb_tee_pid" 2>/dev/null || true
      rm -f "$_hb_out_tmp" ${_hb_prompt_file:+"$_hb_prompt_file"}
      rm -rf "${_hb_fifo_dir:?}"
      return 1
    fi
  fi
  if [ -n "$_hb_prompt_file" ]; then
    "$@" <"$_hb_prompt_file" >"$_hb_fifo" 2>"$err_file" &
  else
    "$@" >"$_hb_fifo" 2>"$err_file" &
  fi
  _hb_cli_pid=$!
  if [ "$_hb_cwd" != "-" ] && ! cd "$_hb_orig_pwd"; then
    kill "$_hb_cli_pid" 2>/dev/null || true
    wait "$_hb_cli_pid" 2>/dev/null || true
    wait "$_hb_tee_pid" 2>/dev/null || true
    rm -f "$_hb_out_tmp" ${_hb_prompt_file:+"$_hb_prompt_file"}
    rm -rf "${_hb_fifo_dir:?}"
    return 1
  fi

  _hb_interval="${ORCHID_HB_INTERVAL_S:-30}"
  (
    # Self-terminating guard: once the engine pid is gone, this loop ends
    # itself on its own next wake -- it does not depend on the explicit
    # kill below actually reaching it (belt-and-braces for e.g. a crash
    # between the engine's `wait` and that kill line).
    while kill -0 "$_hb_cli_pid" 2>/dev/null; do
      sleep "$_hb_interval"
      kill -0 "$_hb_cli_pid" 2>/dev/null || break
      _hb_cpu="$(ps -o time= -p "$_hb_cli_pid" 2>/dev/null | tr -d ' ' || true)"
      printf '[hb %s] engine pid %s cpu %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_hb_cli_pid" "${_hb_cpu:-?}" >&2
    done
  ) &
  _hb_hb_pid=$!

  _hb_rc=0
  wait "$_hb_cli_pid" || _hb_rc=$?
  wait "$_hb_tee_pid" 2>/dev/null || true
  # Killed immediately after the engine returns, BEFORE any parsing of its
  # output -- the heartbeat's only job is log liveness during the run; it
  # has nothing to add once the run is over. `|| true` on both the kill
  # and the following wait: under `set -e` (every adapter's shebang line),
  # `wait` on a job this line just SIGTERM'd returns 128+15=143, which
  # would otherwise abort the whole adapter right here even though the
  # engine itself finished cleanly -- caught during development by tracing
  # an unguarded version of exactly this line.
  kill "$_hb_hb_pid" 2>/dev/null || true
  wait "$_hb_hb_pid" 2>/dev/null || true

  printf -v "$_out_var" '%s' "$(cat "$_hb_out_tmp")"
  printf -v "$_rc_var" '%s' "$_hb_rc"
  # ${_hb_prompt_file:+"$_hb_prompt_file"}, NOT a bare unquoted
  # $_hb_prompt_file: agy's "no stdin" case (`_hb_prompt` = "-") leaves
  # _hb_prompt_file empty, and an unquoted empty expansion happens to vanish
  # cleanly under word-splitting -- but a genuinely set path containing a
  # space or glob metacharacter would otherwise be re-split/re-globbed here.
  # The :+ guard also sidesteps that word-splitting on the empty case
  # entirely rather than relying on it.
  rm -f "$_hb_out_tmp" ${_hb_prompt_file:+"$_hb_prompt_file"}
  rm -rf "${_hb_fifo_dir:?}"
}
