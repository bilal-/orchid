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
# read for location-bearing diagnostics -- provided that log's own header
# binds it to the candidate the task is reworking, since evidence carried into
# an attempt must belong to the candidate that failed -- and those exact lines
# are appended to the task body. lib/pack.sh copies that body verbatim into the implementer's
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

# FINDINGS_BRIEF_MARK -- the marker every brief block is fenced with, so a
# brief is a STRUCTURED region of the task body rather than a heading someone
# has to recognize by its prose:
#
#   <!-- orchid:rework-brief candidate=<sha> -->
#   ... the heading, the prose, the quoted locations ...
#   <!-- orchid:rework-brief-end -->
#
# EVERY BRIEF NAMES THE CANDIDATE IT DESCRIBES, and that is not decoration.
# Briefs are APPENDED, once per rework round, to a body that survives every
# round -- so without a candidate on each block and something that acts on it,
# round three hands the implementer round one's line numbers alongside round
# three's, with nothing in the text to tell them apart. That is the same defect
# `findings_brief`'s sha binding refuses at the log end (evidence belongs to the
# candidate that produced it), reappearing one layer up inside its own remedy:
# locations that were exact when written, re-served against a tree they were
# never reported against. `findings_age_briefs` is what closes it.
FINDINGS_BRIEF_MARK="orchid:rework-brief"

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
#
# SHAPE 3'S HEADER EXPIRES AT THE END OF ITS OWN BLOCK. ShellCheck separates
# findings with a blank line, and a caret line reached after one belongs to no
# header -- so `sc_file` is cleared there, and by any shape-1/2 diagnostic
# (another tool's output has plainly ended the block). Without that, ONE
# `In <file> line <N>:` header seen anywhere earlier in the log would be
# attributed to every later caret+SC line in it, however far away and however
# unrelated: a brief whose whole job is to carry exact locations would be
# printing confidently wrong ones. The reset is deliberately NOT done on emit,
# because shellcheck reports several findings on one source line as several
# caret lines under a SINGLE header, and dropping the header after the first
# would silently lose the rest.
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
    # The blank line that ends a shellcheck block ends its header with it.
    /^[[:space:]]*$/ { sc_file = ""; next }
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
    /^[^[:space:]:]+:[0-9]+:([0-9]+:)?[[:space:]]/ { sc_file = ""; emit($0); next }
    /^[^[:space:]:]+:[[:space:]]line[[:space:]][0-9]+:[[:space:]]/ { sc_file = ""; emit($0); next }
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

# findings_log_candidate <log> -- the candidate_sha this log's own header
# claims it was produced against, or the empty string if it makes no claim.
#
# Read from the HEADER only: parsing stops at the `---` separator both
# `orchid verify` and `orchid merge` write before the captured output, so a
# test that happens to echo a `candidate: <something>` line can never
# impersonate the header field the binding below trusts.
findings_log_candidate() {
  local log="$1"
  [ -f "$log" ] || return 0
  awk '/^---$/ { exit } /^candidate: / { sub(/^candidate: /, ""); print; exit }' "$log"
}

# findings_brief <state> <task-id> <candidate-sha> -- the markdown block to
# append to a task body on entry to `rework`, or NOTHING at all when no
# failing log carries a location. Reads only the two evidence logs the kernel
# itself writes, in the order a reader wants them: `orchid verify`'s first
# (the candidate's own suite), then `orchid merge`'s (the same suite re-run on
# the merged tree).
#
# EVIDENCE IS BOUND TO THE CANDIDATE IT CAME FROM, and a log that does not
# match <candidate-sha> is DROPPED rather than quoted. This is the whole point
# of the mechanism restated as a precondition: the brief exists to carry the
# CURRENT failure into the next attempt, so re-injecting locations from a
# candidate that no longer exists is not a lesser version of that -- it is the
# defect, wearing the fix's heading. A stale log outlives its candidate
# easily: `orchid merge`'s rebase arm mints a new candidate_sha under a tree
# whose `<id>-merge.log` is still on disk, and the `merging` arm of
# `task advance rework` deliberately exempts that log from its rm so the
# failure it is about to journal keeps its evidence. So the sha compare, not
# the file's existence, is what decides.
#
# Three ways a log fails to bind, all treated identically -- silently skipped:
#   * its header names a DIFFERENT candidate (superseded, the case above);
#   * it carries no `candidate:` header at all (written by an older kernel:
#     unbindable, therefore untrusted -- absence of a claim is not a claim);
#   * <candidate-sha> is empty or `none` (the task has no candidate to bind
#     TO, so nothing can match it -- two vacuous sentinels agreeing is not
#     proof, the same trap `task advance testing->reviewing` avoids by
#     excluding `none` from its own compare).
#
# Emitting nothing rather than an empty block is deliberate: a rework that
# had no location-bearing failure -- a merge conflict, an arbitration
# request-changes, or only unbindable evidence -- must not gain a heading
# promising locations it does not have.
findings_brief() {
  local state="$1" id="$2" cand="${3:-}" log rel lines out=""
  [ -n "$cand" ] && [ "$cand" != none ] || return 0
  for log in "$state/reviews/$id-verify.log" "$state/reviews/$id-merge.log"; do
    findings_log_failed "$log" || continue
    [ "$(findings_log_candidate "$log")" = "$cand" ] || continue
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
  printf '<!-- %s candidate=%s -->\n' "$FINDINGS_BRIEF_MARK" "$cand"
  printf '**Rework brief — exact locations reported by the failing gate (candidate `%.12s`):**\n' "$cand"
  cat <<'HEADER'

These are the gate's own `file:line: RULE: message` lines, copied verbatim.
They are carried here because the actor asked to fix them may not be able to
run the gate that produced them (lesson L017), and an instruction whose
subject the recipient cannot see is not satisfiable. Fix these lines.
Running the linter, or committing its own fix, is operator work — see
PROTOCOL.md, "The operator hand-off".
HEADER
  printf '%s\n' "$out"
  printf '<!-- %s-end -->\n' "$FINDINGS_BRIEF_MARK"
}

# findings_age_briefs <task-file> <current-candidate> -- the task body with
# every brief block that describes some OTHER candidate collapsed to a short
# superseded notice, and every block describing <current-candidate> passed
# through untouched. Prints the whole file; writes nothing.
#
# WHY THE OLD ONES CANNOT SIMPLY STAY. `lib/pack.sh` copies the task body
# verbatim into the implementer's pack as `task.md`, so every live brief in it
# is an instruction that actor reads as current. A brief from a candidate two
# rounds dead names lines that a later tree may have moved, renamed or already
# fixed -- and the implementer has no way to tell which of the three briefs in
# front of it describes the tree it was just handed. In r-001 that shape cost
# T005 two rework rounds against locations it could not see; re-serving expired
# ones costs the same rounds against locations that are no longer true, which is
# strictly worse: they LOOK actionable.
#
# WHY COLLAPSED RATHER THAN DELETED. The task body is the durable record of what
# each round was told, and silently rewriting it to look as though a brief was
# never issued would hide exactly the history a reviewer reads it for. So the
# block keeps its marker, keeps the candidate it was bound to, and says how many
# diagnostic lines it carried -- the record survives, the instruction does not.
#
# IDEMPOTENT: a block already marked `superseded` is passed through unchanged
# rather than re-collapsed, so the repeated calls this gets (one per entry to
# `rework`, and rework is the loop) neither re-count nor re-word it.
#
# A candidate of `none`, or none at all, ages EVERY live brief: nothing binds to
# a task with no committed candidate, which is the same rule `findings_brief`
# applies when it refuses to quote a log for one.
findings_age_briefs() {
  local f="$1" cur="${2:-}"
  [ -f "$f" ] || return 0
  [ "$cur" != none ] || cur=""
  awk -v mark="$FINDINGS_BRIEF_MARK" -v cur="$cur" '
    function collapse() {
      printf "<!-- %s candidate=%s superseded -->\n", mark, blkcand
      printf "**Superseded rework brief (candidate `%.12s`) — %d line(s) withdrawn.**\n", blkcand, dropped
      print "They were reported against a candidate that is no longer the one under"
      print "work, so their line numbers describe a tree that no longer exists. Do not"
      print "act on them: the locations for the candidate now under work, if the gate"
      print "reported any, are in the brief marked with that sha."
      printf "<!-- %s-end -->\n", mark
    }
    $0 ~ ("^<!-- " mark " candidate=") && inblk == 0 {
      blkcand = $0
      sub("^<!-- " mark " candidate=", "", blkcand)
      sub(/ .*$/, "", blkcand)
      keep = (index($0, " superseded ") > 0) || (cur != "" && blkcand == cur)
      dropped = 0
      inblk = 1
      if (keep) print
      next
    }
    inblk && $0 == ("<!-- " mark "-end -->") {
      if (keep) print; else collapse()
      inblk = 0
      next
    }
    inblk { if (keep) print; else dropped++; next }
    { print }
    # A block whose end marker never arrived (a body truncated by hand) is
    # closed here rather than dropped: losing the tail of a task file silently
    # is a worse outcome than an unmatched marker an operator can see.
    END { if (inblk && !keep) collapse() }
  ' "$f"
}

# findings_brief_present <body> <brief> -- 0 iff <brief> is ALREADY in <body>,
# byte for byte. The guard that makes appending a brief IDEMPOTENT.
#
# WHY THE CANDIDATE MARKER IS NOT ENOUGH ON ITS OWN. `findings_age_briefs`
# withdraws the briefs describing some OTHER candidate; it deliberately leaves
# the ones describing the CURRENT one alone, because those are still true. So a
# body can reach a second entry to `rework` on the same candidate, with the same
# evidence log still on disk, and `findings_brief` regenerates a block identical
# to the one already there. Every route into that shape ends the same way -- the
# implementer is handed the same locations twice, in two blocks it must read as
# two separate reports, and the duplication grows by one on every further round.
#
# The known route is `merging` -> `rework` followed by `orchid task retry`: the
# `merging` arm EXEMPTS `<id>-merge.log` from its rm precisely so the failure it
# is journalling keeps its evidence, and `retry` then re-reads that surviving log
# against the same unchanged candidate. But the fix is deliberately at the APPEND
# rather than on that route: any other path that reaches `rework` twice without
# minting a new candidate -- a hand-walked `task advance`, an `unblock` after a
# `retry`, an arbitration -- produces it too, and a per-route guard would have to
# be rediscovered at each of them.
#
# By CONTENT, not by candidate: a brief that differs from the live one is a
# different report (the gate that failed this time was not the one that failed
# last time) and is appended. Only the byte-identical re-issue is dropped.
findings_brief_present() {
  local body="$1" brief="$2"
  [ -n "$brief" ] || return 1
  # Quoted, so the brief's own `*`, `?` and `[` are matched literally rather
  # than read as pattern syntax.
  case "$body" in
    *"$brief"*) return 0 ;;
  esac
  return 1
}
