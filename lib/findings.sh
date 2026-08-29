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
# WHAT IS SCRAPED IS NOT THE WHOLE LOG. `findings_failing_output` strips the
# output of any command the log's header records as having PASSED before a
# single shape rule is applied, so a merge log holding a green task suite and
# a red `merge_gate` yields only the gate's half. The shape rules are the
# filter on WHAT a diagnostic looks like; that one is the filter on WHOSE
# output it is, and neither substitutes for the other -- a passing run can
# print a perfectly well-formed location.
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
  findings_failing_output "$log" | awk -v max="$max" '
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
  '
}

# findings_failing_output <log> -- the log with the output of any command it
# records as having PASSED removed. Prints the header unchanged and, below it,
# only the captured output a failing command produced. A log that classifies
# nothing is passed through whole.
#
# WHY THIS EXISTS, AND WHAT IT IS NOT. `findings_log_failed` above answers
# "did this log record a failure" for the WHOLE file, and that was a complete
# answer for exactly as long as a log held one command. `orchid merge` now
# runs two on the same tree -- the task's own `verification_commands`, then
# the repository's `merge_gate` (T007) -- into one captured body, and the
# characteristic failing shape is the one where they DISAGREE: a green task
# suite followed by a red gate. Handed that file whole, the scraper quotes the
# green suite's location-shaped output into the brief under a heading that
# says a failing gate reported it. That is the same mis-attribution
# `findings_log_failed` refuses at the file level, reappearing inside the file
# -- and it is not merely cosmetic, because `FINDINGS_MAX_LINES` caps the
# brief in LOG ORDER and the passing suite's output comes first: a chatty
# green suite can spend the whole cap and push out the gate locations that
# were the only actionable thing in the log.
#
# THE CLASSIFICATION IS READ, NEVER INFERRED. `command_status:` and
# `gate_exit:` are header fields written by the process that ran both
# commands. They are read from the header for the same reason
# `findings_log_candidate` reads `candidate:` there -- parsing stops at the
# `---`, so no captured output can impersonate them. What the BODY supplies is
# only the boundary: the `== merge_gate: <cmd>` banner, whose command must
# equal the header's `gate:` value, so counterfeiting it means echoing this
# repository's configured gate command verbatim. A body marker is the weaker
# of the two and carries the weaker fact deliberately -- where the split is,
# never who passed.
#
# It would be shorter to infer this ("the gate only runs after a green suite,
# so a failing gated log means the gate"), and wrong to: that is
# libexec/orchid-merge's current skip rule, and a copy of it here would keep
# quoting confidently after that file changed its mind.
#
# FAILS OPEN, EVERY WAY IT CAN. No `---`, no `command_status:`, no
# `gate_status: ran`, a `gate:` the banner never matches, a segment whose
# status line is missing or unreadable -- each keeps the output it could not
# classify.
# `orchid verify`'s log, every merge log written before this field existed,
# and every hand-built fixture therefore behave exactly as they did: dropping
# evidence on a parse this function is unsure of would cost the next
# implementer the locations, which is the failure the whole file exists to
# stop.
#
# WHICH IS WHY THE FILE IS READ TWICE. One of those arms cannot be answered
# while streaming, and it is the arm with the worst outcome: "the header says
# a gate ran, but the banner that says WHERE its output begins is not in this
# body." A single pass meets that state having already committed to the suite
# half's decision, and with a green suite recorded that decision is DROP -- so
# it discards the entire body, the unattributable gate locations with it, and
# the log that most needed quoting quotes as nothing. So pass one reads the
# header and answers that one yes/no question about the body; pass two streams
# and prints. Read twice rather than buffered: this runs on every rework edge
# over a log that can carry a whole suite's output, and holding that in memory
# to answer one boolean is the wrong trade. Nothing writes a log after a
# reader can reach it -- `orchid merge` and `orchid verify` both land theirs
# through atomic_write before the edge that scrapes them -- so the two passes
# see one file.
#
# AND WHY A STATUS IS DROPPED ON ONLY WHEN IT IS A WELL-FORMED ZERO. `s + 0`
# is 0 for `x`, for an empty field and for a line truncated mid-write, so a
# bare `!= 0` test reads every unparseable status as a pass and throws that
# command's output away -- the same fail-closed shape as the missing banner,
# one field over. The pattern match is what keeps "this says it passed" apart
# from "this says nothing I can read". findings_log_gate_failed below guards
# the same way and reaches the opposite answer, which is not an inconsistency:
# it decides whether to TELL a human the repository is red, so an unreadable
# field must not become a claim; this decides what evidence to KEEP, where an
# unreadable field must not become a deletion.
findings_failing_output() {
  local log="$1"
  [ -f "$log" ] || return 0
  awk '
    # PASS 1 -- the header fields, plus the single body fact pass 2 cannot
    # discover in time: whether the boundary the header promises is really
    # here. Nothing is printed and nothing is kept.
    FNR == NR {
      if (scan_header == 0) {
        if ($0 == "---") { scan_header = 1; next }
        if (index($0, "command_status: ") == 1) cmd_status = substr($0, 17)
        else if (index($0, "gate: ") == 1) gate_cmd = substr($0, 7)
        else if (index($0, "gate_status: ") == 1) gate_status = substr($0, 14)
        else if (index($0, "gate_exit: ") == 1) gate_exit = substr($0, 12)
        next
      }
      # Same equality the split below uses, so the two cannot disagree about
      # what counts as the boundary: a `gate:` the header never carried leaves
      # gate_cmd empty and matches nothing, which is itself an unlocatable
      # boundary and is handled as one.
      if (gate_cmd != "" && $0 == ("== merge_gate: " gate_cmd)) boundary = 1
      next
    }
    # PASS 2 -- the header, verbatim, then the body under that attribution.
    header == 0 {
      print
      if ($0 == "---") {
        header = 1
        # THE UNLOCATABLE CASE, decided here because here is where the body
        # starts. The header claims a gate ran and pass 1 found no banner, so
        # neither half of what follows can be attributed to a command -- and
        # what may not be attributed is kept, whole, rather than half of it
        # thrown away on the strength of a status that describes the other
        # half.
        if (gate_status == "ran" && boundary == 0) keepall = 1
        # The body opens with the task suite output. Kept unless the header
        # states, in so many words, that the command exited 0.
        keep = !(cmd_status ~ /^[0-9]+$/ && cmd_status + 0 == 0)
      }
      next
    }
    keepall { print; next }
    # The boundary, taken once: a gate whose own output repeats this line must
    # not re-open the segment it is already inside.
    split_done == 0 && gate_status == "ran" && gate_cmd != "" &&
      $0 == ("== merge_gate: " gate_cmd) {
      split_done = 1
      keep = !(gate_exit ~ /^[0-9]+$/ && gate_exit + 0 == 0)
      next
    }
    keep { print }
  ' "$log" "$log"
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
#
# WHOLE-FILE, AND ONLY WHOLE-FILE. This says whether the log is worth opening;
# it deliberately does not say which command inside it failed, because once
# `orchid merge` runs two (T007) the answer differs per command and a single
# status cannot carry both. `findings_failing_output` is where that is
# resolved. Keeping the two apart is what leaves this predicate correct for
# `orchid verify`'s single-command log as well.
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

# findings_log_gate_failed <log> -- 0 iff this log records that the repo-wide
# `merge_gate` RAN and exited non-zero.
#
# THE CLASSIFICATION IS READ, NEVER INFERRED, exactly as it is in
# findings_failing_output above. `orchid merge` writes `gate_status:` and
# `gate_exit:` into the log HEADER, above the `---` every reader in this file
# stops at, so what this answers is what the process that ran both commands
# recorded. It is deliberately NOT derivable from findings_log_failed: that
# reads the trailing `exit:` line, which is the MERGE's status and is equally
# non-zero when the task's own suite is what went red.
#
# WHY A CALLER WANTS IT. `runners/orchid-drive` has to tell a `gate_failed`
# merge from a `validation_failed` one, and after the verb they are hard to
# tell apart: same edge, same exit 1, same resulting status. The difference is
# the whole of what the operator needs -- one says this candidate's own suite
# is red, the other says the candidate is red against a floor the repository
# applies to everything and the task was never asked about, which is
# frequently not the author's doing and is what makes a persistently red gate
# a repository condition rather than a rework loop.
#
# FAILS CLOSED, which is the opposite of findings_failing_output and for the
# opposite reason. That function decides which evidence to KEEP, where an
# unsure parse costs an implementer the only actionable lines in the log, so
# it keeps everything it cannot classify. This one decides whether to tell a
# human "the repository's own gate is red" -- so a log that does not say so in
# the header (no `gate_status: ran`, no `gate_exit:`, a non-numeric or zero
# one, or no log at all) is not evidence that it is. Every merge log written
# before these fields existed therefore answers no, and reads as the
# validation failure it was.
findings_log_gate_failed() {
  local log="$1" ran gate_exit
  [ -f "$log" ] || return 1
  ran="$(awk '/^---$/ { exit } /^gate_status: / { sub(/^gate_status: /, ""); print; exit }' "$log")"
  [ "$ran" = ran ] || return 1
  gate_exit="$(awk '/^---$/ { exit } /^gate_exit: / { sub(/^gate_exit: /, ""); print; exit }' "$log")"
  # Guarded before the numeric compare, not after: `[ "$x" -ne 0 ]` on a
  # non-numeric value is a shell ERROR, not a false, and this predicate is
  # called from a `set -e` driver where that is a dead pass rather than a
  # "no".
  case "$gate_exit" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$gate_exit" -ne 0 ]
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
