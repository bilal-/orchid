#!/usr/bin/env bash
# lib/findings.sh -- carry a failing gate's EXACT locations into the brief the
# next actor actually reads.
#
# THE DEFECT THIS EXISTS FOR (lesson L017). An engine profile that denies on
# the command STRING can run no verifier: no `bash`, no `bash -n`, no
# `shellcheck`, and nothing containing a literal dollar sign, a semicolon,
# parenthesis grouping or process substitution. So a ShellCheck finding filed
# against a file that profile WROTE is, to it, invisible -- and "fix the two
# ShellCheck findings" is an instruction whose subject it cannot see. Measured
# cost in r-001: T005 was told twice to fix two findings in its own file; one
# attempt wrote a documentation paragraph and the next edited eighteen lines,
# and neither touched either offending line. Nothing was wrong with the
# routing except that `file:line: RULE: message` never travelled with it.
#
# So on every entry to `rework`, the log the failing gate actually wrote is
# read for location-bearing diagnostics, and those exact lines are appended to
# the task body. lib/pack.sh copies that body verbatim into the implementer's
# input pack as `task.md`, which is the guidance an implementer receives --
# so the locations arrive with the instruction rather than behind a pointer to
# a log the recipient may be unable to open, re-run or reproduce.
#
# THIS CARRIES INFORMATION, NEVER PERMISSION. It is deliberately NOT the
# other half of the same problem: whoever ends up acting on these lines, the
# ACT of running a linter or committing its fix stays where PROTOCOL.md's
# operator hand-off puts it (lib/handoff.sh). The two are not alternatives and
# do not contradict -- carrying the locations is what makes a routed fix
# SATISFIABLE and leaves a record of what was wrong; the hand-off is what
# stops the fix being routed to an actor that cannot perform it. See
# PROTOCOL.md, "The operator hand-off".
#
# Read-only: every function here reads a log and prints text. The append
# itself is done by libexec/orchid-task, the task file's single writer.

# FINDINGS_MAX_LINES -- the cap on how many diagnostic lines ONE brief block
# carries. `task.md` is a NON-TRUNCATABLE pack input (lib/pack.sh: a pack
# whose non-truncatable inputs exceed `pack_budget_bytes` fails outright with
# input_overflow, exit 12), and a rework brief is appended once per rework
# round, so an uncapped list from a suite that fails in a hundred places could
# turn the next dispatch into a pack failure. Capped -- and the drop is always
# PRINTED, never silent: a truncated list that says nothing reads as "these
# were all of them", which is the same information loss this file exists to
# end.
FINDINGS_MAX_LINES=20

# findings_extract <log> [max] -- one `file:line: RULE: message` line per
# distinct diagnostic the log carries, in the order the log carries them,
# deduplicated, capped at [max] (default FINDINGS_MAX_LINES).
#
# Exactly three input shapes are recognized. A wider net is the wrong trade
# here: it would start quoting ordinary test output into a brief as though a
# gate had reported it, and a brief that mixes real locations with noise is
# read the way a brief with no locations at all is -- skipped.
#
#   1. `file:line: message` and `file:line:col: message` -- the gcc-style
#      shape almost every linter emits (`shellcheck -f gcc`, eslint, ruff,
#      and this repository's own scripts/ci-local.sh policy gates, which
#      print `<file>:<NR>: <what is wrong>` from awk). Copied VERBATIM: the
#      text after the location is the tool's own words, and paraphrasing it
#      is precisely the loss this file exists to stop.
#   2. `file: line N: message` -- the shell's own diagnostic shape, which is
#      what `bash -n` prints for a syntax error. Copied verbatim too.
#   3. ShellCheck's DEFAULT (tty) report, which splits one finding across
#      three lines: `In <file> line <N>:`, the offending source line, then a
#      caret line carrying `SC####` and the message. Neither line alone has
#      both the location and the rule, so this is the one shape COMPOSED
#      rather than copied -- `<file>:<N>: SC####: <message>`, with every
#      field taken verbatim from shellcheck's own output and nothing added.
#
# Lines with leading whitespace never match shapes 1 or 2 (the anchors forbid
# it), which is also what keeps shellcheck's own indented caret lines from
# being quoted twice.
findings_extract() {
  local log="$1" max="${2:-$FINDINGS_MAX_LINES}"
  [ -f "$log" ] || return 0
  awk -v max="$max" '
    function emit(s) {
      if (s in seen) return
      seen[s] = 1
      n++
      if (n <= max) print s
    }
    # Shape 3, first half: remember where the next caret line points.
    /^In .+ line [0-9]+:$/ {
      sc_file = $0
      sub(/^In /, "", sc_file)
      sub(/ line [0-9]+:$/, "", sc_file)
      sc_line = $0
      sub(/^.* line /, "", sc_line)
      sub(/:$/, "", sc_line)
      next
    }
    # Shape 3, second half: the caret line names the rule and the message.
    # Both a caret AND an SC code are required -- prose that merely mentions
    # a code is not a finding. `index`, not a `/\^/` match: a bare caret is
    # the ERE anchor, and whether an escaped one inside a bracketless literal
    # is honoured is exactly the kind of awk-dialect detail that would make
    # this silently match nothing on one platform and everything on another.
    sc_file != "" && index($0, "^") && match($0, /SC[0-9]+/) {
      code = substr($0, RSTART, RLENGTH)
      msg = substr($0, RSTART + RLENGTH)
      sub(/^[[:space:]]*\([^)]*\)/, "", msg)   # newer shellcheck: " (warning)"
      sub(/^:[[:space:]]*/, "", msg)
      emit(sc_file ":" sc_line ": " code ": " msg)
      next
    }
    /^[^[:space:]:]+:[0-9]+:([0-9]+:)?[[:space:]]/ { emit($0); next }
    /^[^[:space:]:]+:[[:space:]]line[[:space:]][0-9]+:[[:space:]]/ { emit($0); next }
    END {
      if (n > max)
        printf "... and %d further diagnostic line(s) in this log, not quoted here\n", n - max
    }
  ' "$log"
}

# findings_log_failed <log> -- 0 iff this log RECORDED A FAILURE.
#
# `orchid verify` and `orchid merge` both close their evidence log with a
# literal `exit: <rc>` line, so this reads a STRUCTURED field rather than
# guessing from the text. That matters in one direction specifically: a
# PASSING suite may still print something location-shaped (a test echoing a
# path and a line number), and quoting that into a rework brief as though a
# gate had reported it is exactly the noise the shape rules above avoid. A log
# with no `exit:` line at all was not written by either verb and is not read.
findings_log_failed() {
  local log="$1" last
  [ -f "$log" ] || return 1
  last="$(tail -n1 "$log")"
  case "$last" in
    "exit: 0") return 1 ;;
    "exit: "*) return 0 ;;
    *) return 1 ;;
  esac
}

# findings_brief <state> <task-id> -- the markdown block to append to a task
# body on entry to `rework`, or NOTHING at all when no failing log carries a
# location. Reads only the two evidence logs the kernel itself writes, in the
# order a reader wants them: `orchid verify`'s first (the candidate's own
# suite), then `orchid merge`'s (the same suite re-run on the merged tree).
#
# Emitting nothing rather than an empty block is deliberate: a rework that
# had no location-bearing failure -- a merge conflict, an arbitration
# request-changes -- must not gain a heading promising locations it does not
# have.
findings_brief() {
  local state="$1" id="$2" log rel lines out=""
  for log in "$state/reviews/$id-verify.log" "$state/reviews/$id-merge.log"; do
    findings_log_failed "$log" || continue
    lines="$(findings_extract "$log")"
    [ -n "$lines" ] || continue
    rel=".orchid/reviews/$(basename "$log")"
    out="$out
**From \`$rel\`:**

\`\`\`
$lines
\`\`\`
"
  done
  [ -n "$out" ] || return 0
  cat <<'HEADER'
**Rework brief — exact locations reported by the failing gate:**

These are the gate's own `file:line: RULE: message` lines, copied verbatim.
They are carried here because the actor asked to fix them may not be able to
run the gate that produced them (lesson L017), and an instruction whose
subject the recipient cannot see is not satisfiable. Fix these lines.
Running the linter, or committing its own fix, is operator work — see
PROTOCOL.md, "The operator hand-off".
HEADER
  printf '%s\n' "$out"
}
