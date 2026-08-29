#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"

# INV-15: NO ENFORCEMENT GATE CAN BE SKIPPED BY OMISSION, AND NONE MAY BE
# BLIND IN THE ENVIRONMENT IT IS DEPLOYED IN.
#
# r-001's single most expensive defect was a gate that existed and that
# nothing invoked. `scripts/ci-local.sh` shipped for the whole run; two of
# eight tasks named it in their own `verification_commands`, because that
# field is authored per task; seventeen ShellCheck findings accumulated behind
# a green suite; and the run-level criterion "the ShellCheck gate passes" was
# false on the integration branch for the entire run (lesson L016). T007 put
# that gate somewhere unavoidable -- the repo-wide `merge_gate`, which
# `orchid merge` runs whatever a task asked for. This file makes the PROPERTY
# checkable so it cannot regress, and it derives what it checks rather than
# restating a list, in the spirit of INV-14's discovery scan: a gate added
# tomorrow is covered without anyone remembering to extend anything.
#
# THE SECOND INSTANCE, and why this file covers two things rather than one.
# On this run's own integration branch a gate WAS invoked, ran honestly, and
# was blind: lib/common.sh's stale-root guard (T006) branches on whether
# $ORCHID_ROOT is parked on the configured integration branch, and a task
# worktree and `orchid merge`'s temp worktree are BY CONSTRUCTION never on
# that branch. So the one dimension the guard branches on was false in every
# environment that revalidated it, the identical commit passed all 67 test
# files on any other branch name, and eleven FAILs were waiting on the branch
# the code actually deploys to (lesson L036). Neither run was skipped, stale
# or dishonest. Re-running either any number of times would never have caught
# it. A revalidation environment that differs from the deployed environment in
# the dimension under test converts a real failure into a silent pass, so
# section 3 CONSTRUCTS that dimension instead of inheriting it.
#
# The THIRD, in section 5, which needs nobody to omit or misjudge anything: a
# gate written as `producer | grep -q`, whose answer is decided by whether the
# producer finished writing before grep's first match killed it. That one had
# already shipped a fail-OPEN instance (scripts/release.sh's placeholder scan).
#
# The three are one subject: omission is a gate nothing calls, vacuity is a
# gate that runs and cannot see, a race is a gate that runs, sees, and is
# overruled by a signal -- and in a log all three are indistinguishable from
# each other and from a gate that passed.
#
# AND A DERIVATION OVER TEXT IS ITSELF THE FOURTH WAY THE SAME DEFECT GETS IN,
# which is why the claims that carry this invariant's weight are also made
# EXECUTABLY, against this candidate's own kernel. A scan that reads the
# shipped source can say a gate is WIRED and cannot say it FIRES: the whole
# subject of this file is that satisfying a check by text nothing executes
# reads, in a log, exactly like satisfying it for real. So:
#
#   * section 2 RUNS every shipped gate file against a stub helpers.sh and
#     requires it to be observed reaching its source line, because "the file
#     contains a source line" is text and a line's presence is not its
#     execution -- a source guarded by a variable nothing sets, or written
#     below an `exit`, satisfies a grep and is never reached.
#   * section 6 runs the pump out of a root that really is stale and requires
#     the refusal to land BEFORE the pump's first write, with the write itself
#     as the witness -- a gate an entry point reaches only after it has
#     already written is reached too late.
#   * section 7 walks a real task, whose `verification_commands` names nothing
#     but `true`, to `merging` and merges it against a red repo-wide gate, and
#     requires the integration ref not to move. That is L016's sentence --
#     "still gated before its ref can advance" -- executed rather than read
#     out of orchid.config.
#   * section 8 does for `orchid trust` what section 6 does for the pump: the
#     one entry point that never restores the operator PATH, and so fires the
#     stale-root gate explicitly or nowhere at all, must refuse out of a stale
#     root with its machine-local trust store still empty -- and must write
#     that same record out of a root that is not stale. It does it on the
#     LOOKUP arm too, which writes nothing durable and carried an exemption
#     for that: what a lookup produces out of a stale checkout is a report an
#     operator acts on, so the report is the side effect, and the same run
#     pins the other edge -- a usage error out of the same stale root is still
#     answered as a usage error, so the gate sits after the operator's command
#     has been validated and not in front of a typo.
#   * section 2 also refuses a gate file whose recorded LABEL the shell
#     executes. A backtick inside a double-quoted label is a command
#     substitution, so the case is counted with the words that said what it
#     proved deleted from the record -- and the fixture that demonstrates it
#     is RUN, so the deletion is observed rather than asserted about a shell.
#
# RED: thirteen, each fed to the SAME derivation or the same shipped verb the
#      section runs over the real tree. A ci-local-shaped file whose static
#      section sits BELOW the `--no-tests` cut (so it is outside the merge
#      floor and only reaches tasks that opted into the full suite), and a
#      second one that differs from it only by NAMING a test script in its
#      comments. An inv-shaped gate file that never loads tests/helpers.sh, so
#      its `red_case`/`green_case` calls satisfy a text linter and are
#      enforced by nothing at run time -- and two more whose source line a
#      text scan accepts and a shell never executes. A trust-boundary entry
#      point that arms the stale-root gate and reaches no site that fires it.
#      A doctor-shaped trust boundary that fires the Git-spending stale-root
#      gate before it performs its machine-local trust decision.
#      An $ORCHID_ROOT genuinely parked on its configured integration branch
#      with a staged kernel edit, which must still be REFUSED -- the case that
#      must be caught. A gate written as a producer piped into `grep -q`. A
#      pump invoked out of that same stale root, which must refuse with no
#      runtime directory created. A merge whose repo-wide gate exits non-zero,
#      which must leave the integration ref exactly where it was. An
#      `orchid trust unattended` out of that stale root, which must refuse
#      with its machine-local store still empty, and an `orchid trust show`
#      out of the same root, which must refuse with not one line of its
#      report produced. And a gate file whose recorded label carries
#      backticked prose the shell executes, which must be refused -- with the
#      fixture run first, so the words really are seen to go missing.
# GREEN: the twins, in this file: the shipped scripts/ci-local.sh, whose
#      static sections are all above the cut, and two late sections that
#      really do run a test script and must be left alone; the shipped
#      tests/inv/ gates, every one of them RUN and observed to reach
#      helpers.sh, beside a fixture whose only difference from the refused
#      ones is that its source line is reachable; a real deferring entry point
#      that does reach a firing site; the case that must NOT fire -- an
#      ordinary checkout on a development branch, where the same construction
#      spends no `git` and refuses nothing, so section 3 is detection rather
#      than a check that fails on every checkout; the shipped kernel's many
#      pipes into a grep that reads to EOF, which must all be left alone; the
#      shipped doctor, whose trust decision precedes its stale-root gate;
#      same pump against the same repo out of a root that is NOT stale, which
#      must run and must create the very directory the refusal above proved
#      absent; the same task, the same tree and the same absent opt-in with a
#      GREEN gate, which must merge and advance the ref; the same
#      acknowledgement out of a root that is not stale, which must write the
#      record the refusal above proved absent; the same lookup out of that
#      same root, which must resolve that record and print the report whose
#      absence the refusal is measured by; and the identical sentence
#      single-quoted, in a comment and in a trailing comment, which the label
#      scan must leave alone.

CI_LOCAL="$REPO_ROOT/scripts/ci-local.sh"
[ -f "$CI_LOCAL" ] || fail "INV-15: scripts/ci-local.sh is missing — the repository's static gate is gone, or it moved"

# ===========================================================================
# 1 -- THE STATIC GATES ARE INSIDE THE MERGE FLOOR.
#
# `scripts/ci-local.sh` is this repository's `merge_gate` (orchid.config), and
# it is invoked with `--no-tests`. That flag is a CUT, not a filter: every
# section above it is in the gate automatically, with nothing to enrol; every
# section below it runs only when something asks for the whole suite, and
# "something asks" is exactly the per-task opt-in L016 is about.
#
# So the invariant is positional AND derived: locate the cut, list the section
# banners, work out from each section's own body whether it runs a test
# script, and require every section that does NOT to be above the cut. Nothing
# here names a check, so a static check added tomorrow is covered the moment
# it prints its banner.
# ===========================================================================

# ci_local_cut_line <file> -- the 1-based line of the `--no-tests` early exit,
# or empty when it cannot be located. Empty is "cannot judge", never "no
# violations": section 1's caller treats it as a failure of its own, because a
# locator that silently found nothing would report a clean bill of health over
# a file whose whole structure had changed.
ci_local_cut_line() {
  local line
  while IFS= read -r line; do
    printf '%s' "${line%%:*}"
    return 0
  done < <(grep -n 'RUN_TESTS" -eq 0' "$1" 2>/dev/null || true)
  printf ''
}

# ci_local_late_sections <file> -- one line per STATIC section that prints
# below the cut, i.e. one line per check that is outside the merge floor.
# Silent when the file is well-formed.
#
# "Static" is derived, not listed: the sections that legitimately live below
# the cut are the ones that RUN TEST SCRIPTS, and this file's whole point is
# that a section which runs no test script has no reason to be down there --
# it is a check of the shipped source, it costs nothing to run at merge, and
# leaving it below the line makes it reachable only by a task that named the
# full suite. So a section is judged by whether its body invokes the suite
# runner or the per-test helper, and a new static check added tomorrow is
# covered without being named here.
#
# Banners are matched at column 0 (`echo "== ` with nothing before it), which
# is how every one of them is written: an indented one is inside a function or
# a conditional and is not a section of the top-level run at all.
#
# And the body is judged on its CODE, never on its text. This repository
# documents its own hazards in comments -- scripts/ci-local.sh's own header
# talks about "the `tests/run.sh` invocation at the bottom" -- so a scan that
# asked "does this section mention tests/run.sh" would answer YES for a
# section that only talks about it, and would then excuse it from the merge
# floor for the sentence rather than for the call. That is this file's own
# subject one level down: a gate satisfied by text that never executes. So
# every line is comment-stripped before it is classified, and a section is
# credited with running the suite only when something in it actually would.
ci_code_line() {
  local s="$1" tab code
  tab=$'\t'
  # Leading whitespace off first, so a comment-only line is recognizable
  # however deeply it is indented.
  s="${s#"${s%%[![:space:]]*}"}"
  case "$s" in ''|'#'*) return 0 ;; esac
  # A trailing comment off the end, at the first `#` that follows whitespace.
  # Narrow on purpose: `${var#prefix}` and a `#` inside a word keep the code
  # around them intact. The residual error runs in the direction of a comment
  # this misses being read as code, which could credit a section with a call
  # it does not make -- so the shipped file is not the only thing this is
  # asked about: the fixture pair below feeds it the exact shape, a late
  # section whose ONLY mention of a test script is in comments, and requires
  # it to be reported.
  code="${s%% #*}"
  printf '%s' "${code%%"$tab"#*}"
}

ci_local_late_sections() {
  local file="$1" cut_at line code no section_no section_runs section_label
  cut_at="$(ci_local_cut_line "$file")"
  if [ -z "$cut_at" ]; then
    printf 'cut-not-located: %s\n' "$file"
    return 0
  fi
  section_no=0
  section_runs=0
  section_label=""
  no=0
  while IFS= read -r line; do
    no=$((no + 1))
    case "$line" in
      'echo "== '*)
        if [ "$section_no" -gt "$cut_at" ] && [ "$section_runs" -eq 0 ]; then
          printf 'late-static-section: %s:%s: %s\n' "$file" "$section_no" "$section_label"
        fi
        section_no="$no"
        section_label="$line"
        section_runs=0
        continue
        ;;
    esac
    code="$(ci_code_line "$line")"
    case "$code" in
      *tests/run.sh*|*ci_run_test*) section_runs=1 ;;
    esac
  done < "$file"
  if [ "$section_no" -gt "$cut_at" ] && [ "$section_runs" -eq 0 ]; then
    printf 'late-static-section: %s:%s: %s\n' "$file" "$section_no" "$section_label"
  fi
}

ci_cut="$(ci_local_cut_line "$CI_LOCAL")"
# Unjudgeable is a FAILURE and stops this section, never a silent pass: every
# comparison below is numeric, and letting an empty answer reach one of them
# would report a shell error where a verdict belongs.
if [ -z "$ci_cut" ]; then
  fail "INV-15: cannot locate the --no-tests cut in scripts/ci-local.sh, so nothing here can say which of its checks are inside the merge floor — this scan is now blind rather than passing"
  ci_cut=0
fi

ci_banner_count=0
while IFS= read -r ci_line; do
  [ -n "$ci_line" ] || continue
  ci_banner_count=$((ci_banner_count + 1))
done < <(grep -n '^echo "== ' "$CI_LOCAL" 2>/dev/null || true)
[ "$ci_banner_count" -ge 4 ] \
  || fail "INV-15: only $ci_banner_count section banner(s) discovered in scripts/ci-local.sh; the static gate is larger than that, so the discovery below is reading the wrong thing"

ci_late="$(ci_local_late_sections "$CI_LOCAL")"
[ -z "$ci_late" ] \
  || fail "INV-15: scripts/ci-local.sh runs a static check BELOW its --no-tests cut, so that check is outside this repository's merge floor and reaches only tasks whose verification_commands happen to name the full suite (lesson L016): $ci_late"

# L016's OWN gate, named explicitly and only here, because it is the one that
# was optional for a whole run: the ShellCheck section must be above the cut.
# The derivation above would already catch it moving below, but a scan that
# quietly stopped finding any banner would also pass, and this line would not.
ci_shellcheck_line=""
while IFS= read -r ci_line; do
  ci_shellcheck_line="${ci_line%%:*}"
  break
done < <(grep -n '^echo "== ShellCheck (' "$CI_LOCAL" 2>/dev/null || true)
if [ -z "$ci_shellcheck_line" ]; then
  fail "INV-15: scripts/ci-local.sh no longer prints a ShellCheck section banner — the gate seventeen findings accumulated behind (lesson L016) cannot be located, so nothing here can say whether it is inside the merge floor"
elif [ "$ci_shellcheck_line" -ge "$ci_cut" ]; then
  fail "INV-15: the ShellCheck gate (line $ci_shellcheck_line) is below the --no-tests cut (line $ci_cut), so it is outside the merge floor — that is lesson L016 exactly, restored"
fi

# The gate has to be WIRED, too. A floor nothing invokes is r-001's defect
# with extra steps, so the repository's own configuration is read rather than
# assumed: `merge_gate` must name this script, and must pass the flag that
# makes the cut mean what section 1 just checked.
REPO_CONFIG="$REPO_ROOT/orchid.config"
[ -f "$REPO_CONFIG" ] || fail "INV-15: orchid.config is missing"
merge_gate_line="$(grep '^merge_gate=' "$REPO_CONFIG" || true)"
assert_match 'ci-local\.sh' "$merge_gate_line" \
  "INV-15: this repository's merge_gate must invoke scripts/ci-local.sh, or its static checks reach only the tasks that opted in"
assert_match '[-][-]no-tests' "$merge_gate_line" \
  "INV-15: the merge_gate must pass --no-tests, which is the cut section 1 measures every static check against"

# ...and being NAMED in orchid.config is still only text. Whether `orchid
# merge` actually reads that key, runs the command it names against a task
# that asked for nothing, and refuses the ref advance when it comes back
# non-zero is section 7, which walks a real task through a real merge to find
# out. Everything above this line would be equally green against a kernel
# that had stopped reading `merge_gate` altogether.

# RED/GREEN on the SAME derivation. The fixtures differ from each other in one
# line's position and in nothing else, so the outcomes below are attributable
# to that and to nothing else.
CI_FIXTURES="$WORK/ci-local-fixtures"
mkdir -p "$CI_FIXTURES"

# write_ci_fixture <path> <early|late|late-comment|late-test|late-test-comment>
# -- five ci-local-shaped files differing in ONE section: where it goes, and
# whether it RUNS a test script or merely mentions one. Everything else is
# identical, so each outcome below is attributable to that section and to
# nothing else.
#
# `late-comment` is the pair that makes the classification real rather than
# textual: its late section is a `grep`, exactly like `late`'s, and the only
# difference between them is a COMMENT naming tests/run.sh. A scan that reads
# text excuses it from the merge floor for that sentence; a scan that reads
# code reports it, because nothing in it runs a test.
write_ci_fixture() {
  local path="$1" placement="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "== Bash syntax"\n'
    printf 'grep -n something "$f"\n'
    if [ "$placement" = early ]; then
      printf 'echo "== A new static check"\n'
      printf 'grep -n forbidden "$f"\n'
    fi
    printf 'if [ "$RUN_TESTS" -eq 0 ]; then\n'
    printf '  echo "CI PASS (static checks only; --no-tests)"\n'
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'echo "== Full test suite"\n'
    printf '"$BASH_BIN" "$ROOT/tests/run.sh"\n'
    if [ "$placement" = late ]; then
      printf 'echo "== A new static check"\n'
      printf 'grep -n forbidden "$f"\n'
    fi
    if [ "$placement" = late-comment ]; then
      printf 'echo "== A new static check"\n'
      printf '  # this check used to live in tests/run.sh before it moved here,\n'
      printf '  # and ci_run_test is how the sections below it are invoked.\n'
      printf 'grep -n forbidden "$f"   # nothing here runs a test\n'
    fi
    if [ "$placement" = late-test ]; then
      printf 'echo "== Documentation checks"\n'
      printf 'ci_run_test "$ROOT/tests/test_docs.sh"\n'
    fi
    if [ "$placement" = late-test-comment ]; then
      printf 'echo "== Documentation checks"\n'
      printf 'ci_run_test "$ROOT/tests/test_docs.sh"  # the doc gate\n'
    fi
  } > "$path"
}
write_ci_fixture "$CI_FIXTURES/early.sh"             early
write_ci_fixture "$CI_FIXTURES/late.sh"              late
write_ci_fixture "$CI_FIXTURES/late-comment.sh"      late-comment
write_ci_fixture "$CI_FIXTURES/late-test.sh"         late-test
write_ci_fixture "$CI_FIXTURES/late-test-comment.sh" late-test-comment

assert_match 'late-static-section: .*A new static check' "$(ci_local_late_sections "$CI_FIXTURES/late.sh")" \
  "INV-15: a static check placed below the --no-tests cut must be reported — it is in the suite and outside the merge floor, which is exactly the shape of an opt-in gate"
red_case "INV-15's cut derivation reported a static check placed below the --no-tests cut, so a gate that reaches only the tasks which opted in is detected rather than assumed absent"

# The same section, below the same cut, with one difference: it now TALKS
# about tests/run.sh and ci_run_test in a comment while still running neither.
# It must be reported for exactly the same reason, or this derivation is
# excusing a gate for its prose.
assert_match 'late-static-section: .*A new static check' "$(ci_local_late_sections "$CI_FIXTURES/late-comment.sh")" \
  "INV-15: a static check below the cut whose only mention of a test script is in a COMMENT must still be reported — crediting a section for the sentence rather than for the call is a gate satisfied by text that never executes, which is this file's own subject"
red_case "a static section below the cut that merely NAMES tests/run.sh and ci_run_test in its comments was reported anyway, so this derivation classifies executable code rather than the prose beside it"

ci_early_out="$(ci_local_late_sections "$CI_FIXTURES/early.sh")"
[ -z "$ci_early_out" ] \
  || fail "INV-15: the identical check placed ABOVE the cut was reported anyway ($ci_early_out) — a locator that flags every section would make the shipped-file assertion above meaningless"
for ci_ok in late-test late-test-comment; do
  ci_late_test_out="$(ci_local_late_sections "$CI_FIXTURES/$ci_ok.sh")"
  [ -z "$ci_late_test_out" ] \
    || fail "INV-15: a section below the cut that DOES run a test script ($ci_ok) was reported anyway ($ci_late_test_out) — the test half belongs below the cut, and a scan that flags it would flag the shipped file and could never be satisfied"
done
green_case 'the identical static check placed ABOVE the cut, and two sections below the cut that do run a test script -- one of them with a trailing comment on the very line that runs it -- were all left alone, so the report above is position-and-kind detection rather than a scan that flags every section banner or one that loses a call to the comment beside it'

# The locator's own failure mode is a violation, never a pass: a ci-local that
# has lost its cut cannot be judged, and saying nothing about it is how a
# blind scan reads as a clean one.
assert_match 'cut-not-located' "$(ci_local_late_sections "$CI_FIXTURES/nonexistent.sh")" \
  "INV-15: a file whose --no-tests cut cannot be located must be reported as unjudgeable, never passed"

# ===========================================================================
# 2 -- ENROLMENT IN THE RED-CASE RULE MUST BE ENFORCED AT RUN TIME, NOT IN
# TEXT.
#
# tests/helpers.sh's EXIT trap fails an enrolled gate file that RECORDS no RED
# or GREEN case, and that trap is installed by sourcing helpers.sh. A file
# under tests/inv/ that never sources it is enrolled on paper -- it satisfies
# every one of tests/test_red_case_rule.sh's four TEXT requirements -- and
# enforced by nothing whatever: its `red_case` and `green_case` calls are
# undefined commands sitting in a file that no trap watches.
#
# That is a gate satisfied by text that never executes, which is the defect
# this whole file exists to eliminate, one level up. The check is structural
# and derived by glob, so a gate file written tomorrow is covered.
#
# AND THE STRUCTURAL HALF IS NOT ENOUGH, WHICH IS THIS SECTION'S OWN VERSION
# OF THE SAME MISTAKE. "The file contains a line that sources helpers.sh" is
# read out of TEXT, and a line's presence is not its execution: a source
# guarded by a condition nothing sets, or written below an `exit` that always
# runs, is a line a grep is satisfied by and a shell never reaches. A gate file
# in that state records nothing, prints no summary, and is indistinguishable in
# the log from one that complied -- the exact property this file exists to
# eliminate, restored inside the check meant to eliminate it.
#
# So enrolment is proven by OBSERVATION. Every shipped gate file is executed
# against a STUB helpers.sh that announces itself with an unforgeable token and
# exits before the gate's own body can run, and enrolment means that token was
# seen. A file that never reaches its source -- for any reason, including ones
# no scan of this file anticipated -- fails, and it fails without anybody
# enumerating the ways a line can go unreached.
# ===========================================================================
INV_GLOB_DIR="$REPO_ROOT/tests/inv"

# helpers_missing <file> -- non-empty when <file> is a gate file that never
# LOADS tests/helpers.sh. `source`/`.` at the head of a line, so a mention of
# helpers.sh in prose (this file's own comments are full of them) does not
# satisfy it.
#
# The TEXT half, kept because it is the cheap one and it names the commonest
# shape exactly; it is not the half that decides. `enrolment_unproven` below
# is, and the fixtures at the end of this section are two files this function
# accepts and that one refuses.
helpers_missing() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf 'no-such-file: %s\n' "$f"
    return 0
  fi
  grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+.*helpers\.sh' "$f" && return 0
  printf 'helpers-not-loaded: %s (its red_case/green_case calls satisfy a text linter and are enforced by nothing at run time — tests/helpers.sh is what installs the EXIT trap that requires a case to have actually RUN)\n' "$f"
}

# The RUN-TIME half. `enrolment_unproven <file>` copies <file> into a probe
# tree whose `tests/helpers.sh` is a STUB, runs it, and reports unless the stub
# announced itself -- which happens only if the file's own source line was
# actually executed.
#
# Three things make it evidence rather than another text scan:
#
#   * The witness is the STUB's, not the file's. Every gate here loads helpers
#     as `source "$(dirname "$0")/../helpers.sh"`, so a copy placed at
#     <probe>/tests/inv/ resolves to <probe>/tests/helpers.sh and to nothing in
#     the real tree. The stub is the first thing the gate executes that could
#     print anything at all.
#   * The token carries this process's PID, so no file in the tree can contain
#     it and no gate can print it by accident or on purpose.
#   * The stub exits immediately, so this costs one bash startup per gate and
#     never runs a gate's body. Nothing here re-runs the suite, and this file
#     probing its own copy stops at the same line.
#
# It answers "was the source reached", which is the question, rather than
# "which of the ways a line can be unreachable does this one use" -- a
# condition nothing sets, an `exit` above it, a `return` in a sourced context,
# a shape nobody has thought of yet. All of them look identical here: no token.
ENROL_PROBE="$WORK/enrolment-probe"
ENROL_MARK="INV15-HELPERS-REACHED-$$"
mkdir -p "$ENROL_PROBE/tests/inv"
{
  printf '# INV-15 probe stub: stand in for tests/helpers.sh and announce that\n'
  printf '# the gate file above actually reached its source line.\n'
  printf 'echo "%s"\n' "$ENROL_MARK"
  printf 'exit 0\n'
} > "$ENROL_PROBE/tests/helpers.sh"

enrolment_unproven() {
  local f="$1" probe out rc=0
  if [ ! -f "$f" ]; then
    printf 'no-such-file: %s\n' "$f"
    return 0
  fi
  probe="$ENROL_PROBE/tests/inv/${f##*/}"
  cp "$f" "$probe"
  out="$(env -u ORCHID_REQUIRE_RED_CASE "$BASH" "$probe" 2>&1)" || rc=$?
  rm -f "$probe"
  case "$out" in
    *"$ENROL_MARK"*) return 0 ;;
  esac
  printf 'helpers-not-reached: %s (run with a stub tests/helpers.sh in its place, this file never got to its source line — rc=%s. Whatever the reason, its red_case/green_case calls are watched by no EXIT trap, so it is enrolled in the red-case rule on paper and enforced nowhere)\n' \
    "$f" "$rc"
}

inv_seen=0
for inv_file in "$INV_GLOB_DIR"/test_*.sh; do
  [ -e "$inv_file" ] || continue
  inv_seen=$((inv_seen + 1))
  inv_out="$(helpers_missing "$inv_file")"
  [ -z "$inv_out" ] || fail "INV-15: $inv_out"
  inv_out="$(enrolment_unproven "$inv_file")"
  [ -z "$inv_out" ] || fail "INV-15: $inv_out"
done
[ "$inv_seen" -ge 2 ] \
  || fail "INV-15: only $inv_seen file(s) matched tests/inv/test_*.sh — the invariant gates moved, and this scan is checking an empty set"
green_case "every one of the $inv_seen shipped tests/inv/ gates was RUN and observed to reach tests/helpers.sh, so the run-time RED/GREEN enforcement really is installed in all of them rather than merely written into them"

# The RED twin, and it is deliberately a file that a TEXT linter accepts. Both
# halves are demonstrated rather than argued: the fixture carries all four
# things tests/test_red_case_rule.sh's linter requires, and running it exits 0
# having recorded nothing -- no summary line, no failure, nothing in the log to
# distinguish it from a gate that complied.
ENROL="$WORK/enrolment-fixtures"
mkdir -p "$ENROL/tests/inv"
UNENFORCED="$ENROL/tests/inv/test_INV-98_textually_enrolled.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a gate file that carries every textual mark of enrolment\n'
  printf '# GREEN: ...and the accepting twin, also purely textual here\n'
  printf 'red_case() { :; }\n'
  printf 'green_case() { :; }\n'
  printf 'red_case "a case that no trap is watching"\n'
  printf 'green_case "a twin that no trap is watching"\n'
} > "$UNENFORCED"

assert_match 'helpers-not-loaded' "$(helpers_missing "$UNENFORCED")" \
  "INV-15: an inv-shaped gate file that never loads tests/helpers.sh must be refused — nothing else makes its recorded cases mean anything"

# ...and it really would have passed as enrolled. The four textual
# requirements are asked here directly rather than asserted in prose, so if
# the linter's contract changes this stops claiming something it no longer
# demonstrates.
for enrol_pattern in \
  '^[[:space:]]*#[[:space:]]*RED:' \
  '^[[:space:]]*#[[:space:]]*GREEN:' \
  '(^|[^_[:alnum:]])red_case[[:space:]]+[^[:space:]]' \
  '(^|[^_[:alnum:]])green_case[[:space:]]+[^[:space:]]'
do
  grep -Eq "$enrol_pattern" "$UNENFORCED" \
    || fail "INV-15: the unenforced fixture no longer satisfies the text requirement '$enrol_pattern', so it no longer demonstrates a file that is enrolled on paper and enforced nowhere"
done

enrol_rc=0
enrol_out="$(env -u ORCHID_REQUIRE_RED_CASE "$BASH" "$UNENFORCED" 2>&1)" || enrol_rc=$?
assert_eq 0 "$enrol_rc" \
  "INV-15: the unenforced fixture must RUN cleanly — that is the hazard, not a broken fixture (got rc=$enrol_rc: $enrol_out)"
grep -q 'red-cases: ' <<<"$enrol_out" \
  && fail "INV-15: the unenforced fixture printed a red-case summary, so it did reach the run-time enforcement and is no longer the hazard this section is about"
red_case "an inv-shaped gate file carrying all four textual marks of enrolment, but never loading tests/helpers.sh, was refused by this scan — it ran to completion, recorded nothing, and printed no summary, so no other check in the tree could have told it from a compliant one"

# ---------------------------------------------------------------------------
# The two fixtures the TEXT half accepts, which is the whole reason the
# run-time half exists. Each one carries a `source .../helpers.sh` line that
# `helpers_missing` is satisfied by and that a shell never executes: one
# guarded by a variable nothing sets, one below an `exit` that always runs.
# Both are written the way a real gate is written -- same relative source
# expression, same four textual marks -- so what separates them from a
# compliant gate is reachability and nothing else.
#
# `helpers_missing` is asked about them EXPLICITLY, and must say nothing. That
# assertion is not decoration: if the text scan ever grew a way to catch these
# two, this pair would stop demonstrating the gap the run-time probe is here to
# close, and would go on passing while proving something weaker.
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a gate whose enrolment is guarded by a variable nothing sets\n'
  printf '# GREEN: ...and whose accepting twin is guarded by the same thing\n'
  printf 'if [ -n "${ORCHID_INV_LOAD_HELPERS:-}" ]; then\n'
  printf '  source "$(dirname "$0")/../helpers.sh"\n'
  printf 'fi\n'
  printf 'red_case() { :; }\n'
  printf 'green_case() { :; }\n'
  printf 'red_case "a case recorded by a trap that was never installed"\n'
  printf 'green_case "a twin recorded by a trap that was never installed"\n'
} > "$ENROL/tests/inv/test_INV-97_conditionally_enrolled.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a gate whose enrolment sits below an exit that always runs\n'
  printf '# GREEN: ...and whose accepting twin sits below it too\n'
  printf 'red_case() { :; }\n'
  printf 'green_case() { :; }\n'
  printf 'red_case "a case recorded above the source line"\n'
  printf 'green_case "a twin recorded above the source line"\n'
  printf 'exit 0\n'
  printf 'source "$(dirname "$0")/../helpers.sh"\n'
} > "$ENROL/tests/inv/test_INV-96_unreachably_enrolled.sh"

for enrol_unreached in test_INV-97_conditionally_enrolled test_INV-96_unreachably_enrolled; do
  enrol_file="$ENROL/tests/inv/$enrol_unreached.sh"
  enrol_text_out="$(helpers_missing "$enrol_file")"
  [ -z "$enrol_text_out" ] \
    || fail "INV-15: the text scan reported $enrol_unreached ($enrol_text_out), so this fixture no longer demonstrates a source line a grep accepts — the run-time probe below would then be proving a gap that has moved"
  assert_match 'helpers-not-reached' "$(enrolment_unproven "$enrol_file")" \
    "INV-15: $enrol_unreached carries a source line that is never executed, and must be refused — 'the file contains the line' is text, and a line's presence is not its execution"
done
red_case "two gate files whose helpers.sh source line the text scan ACCEPTED — one guarded by a variable nothing sets, one below an exit that always runs — were both refused once they were run, so enrolment here is observed rather than read"

# The GREEN twin on the same probe, and it is one line different from the
# conditional fixture above: the source is on the straight-line path. Without
# it, a probe that reported every file whatsoever would satisfy both RED cases.
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a compliant gate file, for the probe to accept\n'
  printf '# GREEN: ...and its twin\n'
  printf 'source "$(dirname "$0")/../helpers.sh"\n'
  printf 'red_case "a case a trap really is watching"\n'
  printf 'green_case "a twin a trap really is watching"\n'
} > "$ENROL/tests/inv/test_INV-95_properly_enrolled.sh"
enrol_ok_out="$(enrolment_unproven "$ENROL/tests/inv/test_INV-95_properly_enrolled.sh")"
[ -z "$enrol_ok_out" ] \
  || fail "INV-15: a gate file that sources helpers.sh on its straight-line path was reported anyway ($enrol_ok_out) — a probe that refuses everything would flag the whole shipped set and prove nothing about the two above"
green_case "the same probe accepted a gate file whose source line differs from the refused one only in being reachable, so the refusals above are unreachability being detected rather than a probe that reports every file it runs"

# ---------------------------------------------------------------------------
# AND THE LABEL A GATE RECORDS MUST BE THE LABEL SOMEBODY WROTE.
#
# tests/helpers.sh's recorders -- red_case, green_case, not_tested, fail --
# take their text as an ordinary shell word, so a double-quoted label is
# EXPANDED before it is recorded. Prose written the way prose is written
# everywhere else in this tree, with a backtick around an identifier, is
# therefore a command substitution: the shell runs the quoted words as a
# command, prints a command-not-found line on stderr, and splices that
# command's empty output into the label. The case is still recorded, the file
# still exits 0, the summary still counts it -- with the words that carried
# its meaning deleted, and the record left saying something its author did not
# write.
#
# That is this file's own subject at the smallest scale, and it is the shape
# every other section here is built to refuse: a proof that reads as satisfied
# and is not the proof it claims. It has now shipped three times -- in
# tests/inv/test_INV-14_engine_neutrality.sh, then in
# tests/inv/test_INV-05_no_name_branching.sh, then in this file's own
# not-tested prose -- which is what makes it a derivation rather than a third
# repair.
#
# The rule is narrow on purpose. What is refused is a backtick in a position
# the SHELL is live in: unquoted, or inside double quotes, on the logical line
# of a recorder call. A backtick inside single quotes is inert and is left
# alone -- INV-05 spells its own label that way -- and so is one in a comment.
# `$( )` is not refused either: labels legitimately interpolate the counts
# that make them non-vacuous, and that spelling is visible as code to whoever
# types it, which is exactly what a backtick inside a sentence is not.
#
# The scanner walks characters and tracks the quoting state rather than
# matching a pattern, because the question here is not "does this line contain
# a backtick" -- most of the comments in this file do -- but "would the shell
# execute it".
label_command_substitution() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf 'no-such-file: %s\n' "$f"
    return 0
  fi
  awk '
    BEGIN {
      SQ = sprintf("%c", 39)
      DQ = sprintf("%c", 34)
      BS = sprintf("%c", 92)
      BT = sprintf("%c", 96)
      HASH = sprintf("%c", 35)
      TAB = sprintf("%c", 9)
    }
    function live_backtick(s,   i, c, p, st, n) {
      st = 0
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == 0) {
          if (c == BS) { i++; continue }
          if (c == SQ) { st = 1; continue }
          if (c == DQ) { st = 2; continue }
          if (c == BT) return 1
          if (c == HASH) {
            p = (i == 1) ? " " : substr(s, i - 1, 1)
            if (p == " " || p == TAB) return 0
          }
        } else if (st == 1) {
          if (c == SQ) st = 0
        } else {
          if (c == BS) { i++; continue }
          if (c == DQ) { st = 0; continue }
          if (c == BT) return 1
        }
      }
      return 0
    }
    {
      if (pend != "") { line = pend " " $0 } else { line = $0; pend_start = NR }
      if (line ~ /\\$/) { pend = substr(line, 1, length(line) - 1); next }
      pend = ""
      if (line ~ /(^|[[:space:]&|;(])(red_case|green_case|not_tested|fail)[[:space:]]/ && live_backtick(line))
        printf "label-command-substitution: %s:%d (this recorder call carries a backtick the shell is live in, so the case is recorded with its own prose executed as a command and those words deleted from the record. Single-quote the label, or drop the punctuation)\n", FILENAME, pend_start
    }
  ' "$f"
}

lbl_seen=0
for lbl_file in "$INV_GLOB_DIR"/test_*.sh; do
  [ -e "$lbl_file" ] || continue
  lbl_seen=$((lbl_seen + 1))
  lbl_out="$(label_command_substitution "$lbl_file")"
  [ -z "$lbl_out" ] || fail "INV-15: $lbl_out"
done
[ "$lbl_seen" -ge 2 ] \
  || fail "INV-15: only $lbl_seen file(s) matched tests/inv/test_*.sh for the label scan — the invariant gates moved, and this scan is reading an empty set"
green_case "every recorded label and failure message in all $lbl_seen shipped tests/inv/ gates was scanned and none carries a backtick the shell would execute, so what those gates record is what somebody wrote rather than what a command substitution left behind"

# The RED twin, on the same function, and the offending punctuation is built
# rather than typed: this file is inside the glob it scans, so a literal
# backtick on a line of its own that begins with a recorder name would be a
# violation reported against this file. Composing the fixture through printf
# keeps the fixture honest and this file clean at the same time.
LBL="$WORK/label-fixtures"
mkdir -p "$LBL"
lbl_bt="$(printf '\140')"
LBL_LIVE="$LBL/test_INV-94_live_label.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a recorded label whose own prose the shell executes\n'
  printf '# GREEN: ...and the inert twin, in the file beside this one\n'
  printf 'red_case "the scan let a %sconfig_get role.implementer%s default through"\n' \
    "$lbl_bt" "$lbl_bt"
  printf 'green_case "and left the twin alone"\n'
} > "$LBL_LIVE"

# The fixture really is the hazard, and that is executed rather than argued:
# run it with recorders that print what they were handed, and the words
# between the backticks are gone from the label the shell built. The stub
# recorders are defined here rather than sourced from tests/helpers.sh, so
# this costs one bash startup and installs no second EXIT trap over this run.
lbl_expand_rc=0
lbl_expanded="$("$BASH" --noprofile --norc -c \
  'red_case() { printf "%s\n" "$1"; }; green_case() { :; }; . "$1"' \
  _ "$LBL_LIVE" 2>/dev/null)" || lbl_expand_rc=$?
case "$lbl_expanded" in
  *"config_get role.implementer"*)
    fail "INV-15: the fixture's label survived expansion intact (rc=$lbl_expand_rc), so it no longer demonstrates prose the shell executes and the refusal below would be a refusal of nothing" ;;
esac
case "$lbl_expanded" in
  *"the scan let a"*) ;;
  *)
    fail "INV-15: the fixture recorded no label at all (rc=$lbl_expand_rc), so the missing words above are a fixture that did not run rather than a shell that deleted them" ;;
esac

assert_match 'label-command-substitution' "$(label_command_substitution "$LBL_LIVE")" \
  "INV-15: a gate file recording a label whose backticked prose the shell executes must be refused — it is counted as a case, it prints a command-not-found line nobody reads, and the record it leaves is missing the words that said what was proven"
red_case "a gate file whose recorded label carries backticked prose was refused, and running it first showed the shell really does delete those words from the label — so a case that reads as recorded and says something other than what was written is detected rather than assumed impossible"

# The GREEN twin, carrying the identical sentence in the two places the shell
# cannot reach it: inside single quotes, and in a comment. Without it, a scan
# that flagged every backtick whatsoever would satisfy the RED case above and
# would fail every gate in the shipped set, this file included.
LBL_INERT="$LBL/test_INV-93_inert_label.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: the same sentence, quoted so the shell cannot reach it\n'
  printf '# GREEN: ...and the same punctuation in a comment: %sconfig_get%s\n' \
    "$lbl_bt" "$lbl_bt"
  printf "red_case 'the scan let a %sconfig_get role.implementer%s default through'\n" \
    "$lbl_bt" "$lbl_bt"
  printf 'green_case "a label that interpolates $(printf 3) and carries no backtick"\n'
  printf 'fail "a message that mentions no punctuation at all"  # %sinert%s\n' \
    "$lbl_bt" "$lbl_bt"
} > "$LBL_INERT"
lbl_inert_out="$(label_command_substitution "$LBL_INERT")"
[ -z "$lbl_inert_out" ] \
  || fail "INV-15: the inert fixture was reported anyway ($lbl_inert_out) — a scan that flags a backtick wherever it appears would flag the single-quoted label INV-05 records, every comment in this file, and this section's own prose, so the refusal above would be detection of nothing"
green_case 'the identical sentence single-quoted, the same punctuation in a comment and in a trailing comment, and a label interpolating a count the modern way were all left alone, so the refusal above is live command substitution being detected rather than a scan that reports every backtick it finds'

# ===========================================================================
# 3 -- A GATE MAY NOT BE BLIND IN THE ENVIRONMENT IT IS DEPLOYED IN.
#
# lib/common.sh's stale-root guard is the instance, and the construction is
# the point. Every environment that revalidates this repository -- a task
# worktree, `orchid merge`'s temp worktree, a release archive -- has
# $ORCHID_ROOT parked on something other than the configured integration
# branch, which is the one dimension that guard branches on. So this section
# builds a root that IS parked on it, rather than asking the ambient one.
#
# BOTH EDGES, because either alone is worthless (lesson L034). The case that
# must be caught: a root on its integration branch with a staged kernel edit
# must be REFUSED when a verb runs out of it. The case that must NOT fire: an
# ordinary development checkout must be left alone, so this is detection
# rather than a check that fails on every tree.
#
# And the property under test in between: loading the library must spend NO
# `git`. lib/trust.sh's unattended gate touches no repository in any way until
# an acknowledgement for it has been found, and a source-time spawn lands in
# front of that lookup however the gate itself is written.
# ===========================================================================
STALE="$WORK/blind-gate"
mkdir -p "$STALE"

# The branch the probe fixtures declare as theirs. Written into every probe
# root's orchid.config, and only ONE of the two roots is parked on it -- which
# is the entire difference between the two edges below. Spelled once, so the
# pair cannot drift into agreeing (or into both differing) by a typo.
PROBE_INTEG=orchid/probe-integration

# make_probe_root <dir> <head-branch> -- the smallest real installation root
# the guard can be asked about: the shipped dispatcher and the shipped
# lib/common.sh under test, one verb, every kernel path the guard's pathspec
# names, and an orchid.config declaring $PROBE_INTEG as the integration branch
# whatever this root's own HEAD is parked on. Deliberately NOT a copy of
# tests/test_stale_root.sh's richer fixture: what is under test here is the
# guard's REACH into an environment, not the refusal's content.
make_probe_root() {
  local dir="$1" branch="$2" kdir
  for kdir in bin lib libexec runners plugins roles skills templates; do
    mkdir -p "$dir/$kdir"
    printf 'probe\n' > "$dir/$kdir/.keep"
  done
  printf 'PROTOCOL probe\n' > "$dir/PROTOCOL.md"
  cp "$REPO_ROOT/bin/orchid" "$dir/bin/orchid"
  cp "$REPO_ROOT/lib/common.sh" "$dir/lib/common.sh"
  cat > "$dir/libexec/orchid-version" <<'VERB'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "probe verb ran"
VERB
  chmod +x "$dir/bin/orchid" "$dir/libexec/orchid-version"
  printf 'integration_branch=%s\n' "$PROBE_INTEG" > "$dir/orchid.config"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "probe root"
}

# A logging `git` ahead of the real one, so "spent a subprocess" is observed
# rather than inferred. The library is loaded the way tests/test_unattended_
# trust.sh's fast-guard fixture loads it -- bare, with no entry point above it
# -- because that is the shape whose PATH is not pinned and in which a
# source-time spawn is reachable by a target-controlled binary at all.
PROBE_BIN="$STALE/probe-bin"
PROBE_LOG="$STALE/probe-git.log"
mkdir -p "$PROBE_BIN"
PROBE_REAL_GIT="$(command -v git)"
[ -n "$PROBE_REAL_GIT" ] || fail "INV-15: no git on PATH to build the probe shim from"
cat > "$PROBE_BIN/git" <<'SHIM'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$ORCHID_TEST_INV15_LOG"
exec "$ORCHID_TEST_INV15_REAL_GIT" "$@"
SHIM
chmod +x "$PROBE_BIN/git"

# source_probed <root> -- load the library out of <root> with the logging git
# first on PATH. Leaves the status in $probe_rc and every git the load
# consumed in $PROBE_LOG.
probe_rc=0
source_probed() {
  : > "$PROBE_LOG"
  probe_rc=0
  PATH="$PROBE_BIN:$PATH" HOME="$MACHINE_HOME" \
    ORCHID_TEST_INV15_LOG="$PROBE_LOG" ORCHID_TEST_INV15_REAL_GIT="$PROBE_REAL_GIT" \
    ORCHID_ROOT="$1" \
    /bin/bash -c 'set -euo pipefail; source "$ORCHID_ROOT/lib/common.sh"' \
    >/dev/null 2>&1 || probe_rc=$?
}

# run_probed <root> -- the same root, reached the way an operator reaches it.
# bin/orchid pins the fixed machine-local PATH as its first act, so the shim
# is deliberately absent from this one: what it observes is the REFUSAL, and
# the refusal's own report of the staged path is evidence the comparison was
# made.
probe_out=""
run_probed() {
  probe_rc=0
  probe_out="$(HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT='' \
    "$1/bin/orchid" version 2>&1)" || probe_rc=$?
}

# -- the CONSTRUCTED condition: parked on its own configured integration
# branch, with a kernel path staged so the guard has something real to find.
INTEG_ROOT="$STALE/on-integration"
make_probe_root "$INTEG_ROOT" "$PROBE_INTEG"
printf '\n# staged kernel edit\n' >> "$INTEG_ROOT/libexec/orchid-version"
git -C "$INTEG_ROOT" add libexec/orchid-version
[ -n "$(git -C "$INTEG_ROOT" diff --cached --name-only HEAD -- libexec)" ] \
  || fail "INV-15: the constructed fixture has no staged kernel edit, so the refusal below would prove nothing"

source_probed "$INTEG_ROOT"
assert_eq 0 "$probe_rc" \
  "INV-15: loading the library is not running a verb, so it must not refuse even on a root parked on its integration branch"
[ ! -s "$PROBE_LOG" ] \
  || fail "INV-15: loading lib/common.sh out of a root parked on its configured integration branch spent a Git subprocess ($(tr '\n' ' ' < "$PROBE_LOG")) — that is the call the unattended-trust contract forbids before an acknowledgement is found, and it is reachable in exactly one environment: the self-hosted checkout, which no task worktree and no merge worktree ever reproduces (lesson L036)"

run_probed "$INTEG_ROOT"
assert_eq 1 "$probe_rc" \
  "INV-15: the SAME root must still refuse when a verb runs out of it — otherwise the assertion above is satisfied by a guard that was simply switched off"
assert_match 'refusing to run: the checkout orchid itself runs from' "$probe_out" \
  "INV-15: and it must be the stale-root refusal, not some other failure of the probe launcher"
assert_match 'libexec/orchid-version' "$probe_out" \
  "INV-15: the refusal reports the staged kernel path, which only the index comparison can have produced — the gate is not merely reachable, it SAW something"
red_case "a root genuinely parked on its configured integration branch with a staged kernel edit was refused when a verb ran out of it, and the refusal named the staged path, so the gate is reachable AND not blind in the one environment no revalidation worktree reproduces"

# -- the case that must NOT fire. Same construction, same probe, one
# difference: the branch. Without this, section 3 would be satisfied by a
# guard that refuses every checkout and by a scan that logs every load.
DEV_ROOT="$STALE/on-development"
make_probe_root "$DEV_ROOT" probe/development
printf '\n# staged kernel edit\n' >> "$DEV_ROOT/libexec/orchid-version"
git -C "$DEV_ROOT" add libexec/orchid-version

source_probed "$DEV_ROOT"
assert_eq 0 "$probe_rc" "INV-15: an ordinary development checkout loads the library cleanly"
[ ! -s "$PROBE_LOG" ] \
  || fail "INV-15: loading the library out of a development checkout spent a Git subprocess ($(tr '\n' ' ' < "$PROBE_LOG"))"
run_probed "$DEV_ROOT"
assert_eq 0 "$probe_rc" \
  "INV-15: a development checkout with the identical staged kernel edit must RUN — the guard fires on the integration branch, not on dirty development (got: $probe_out)"
assert_match 'probe verb ran' "$probe_out" "INV-15: ...and it must run its own verb, not merely exit 0"
green_case 'the identical staged kernel edit on a development branch neither refused nor spent a git, so the refusal above is the integration-branch condition being detected rather than a guard that fires on every checkout'

# ===========================================================================
# 4 -- EVERY KERNEL ENTRY POINT REACHES THE GATE IT ARMS.
#
# Section 3's guard is armed when lib/common.sh is sourced and fired at one of
# two places: immediately, for an entry point with no authorization boundary
# to cross, and at `_orchid_entry_restore_operator_path` for a trust-boundary
# entry point, which is the line where such an entry point states its
# authorization decision is made. A trust-boundary entry point that reaches
# NEITHER arms the gate and never fires it -- a gate skipped by omission, in
# the guard this file exists to protect.
#
# So the entry-point set is DERIVED (every file under bin/, libexec/ and
# runners/ that sources lib/common.sh) and partitioned by what each file
# declares about itself, rather than being listed here. A trust-boundary entry
# point written tomorrow is covered the moment it defers.
#
# WHAT THIS SECTION CANNOT SEE, said here rather than only in the not-tested
# claim at the end: "the file calls a firing site" is not "the file calls it
# before it does anything". runners/orchid-pump satisfied every line below
# while reaching its firing site only after `orchid_runtime` had created
# `.orchid/runtime` in the target repository. That ordering is not derivable
# from text -- a `orchid_runtime` line inside a function body precedes a call
# site that runs long after it, and no line-number comparison can tell the two
# apart -- so it is proven by execution instead, for the entry point it was
# wrong in, in section 6.
# ===========================================================================

# EMPTY, and it did not start that way. `libexec/orchid-trust` was declared
# here with a reason -- that its entire body is the authorization decision, so
# there is no "after the decision, before the work" moment for the gate to
# occupy -- and the reason was wrong: the moment is between the operator's
# command and the durable write to the machine-local trust store, which is
# where that file now fires it. Section 8 executes exactly that ordering.
#
# The declaration stays, because a declared exemption is how the next one gets
# stated instead of getting away. It is spelled as the exact string the
# derivation below must produce -- repo-relative names in glob order, separated
# by single spaces -- rather than as an array, so that "no exemption at all" is
# a value this check can hold rather than an empty expansion `set -u` aborts
# on. The comparison is EXACT in both directions: a file joining this set
# fails, and a member that stops needing the exemption fails too, so an
# exemption cannot outlive its reason.
GATE_EXEMPT=""

# entry_code <file> -- <file> with its comment lines removed.
#
# NOT a nicety. This whole repository documents its own hazards in comments,
# and runners/orchid-service's gate call carries a paragraph naming the very
# helper it is standing in for -- so a scan asked "does this file mention
# _orchid_entry_restore_operator_path" answers YES for a file that only talks
# about it. That is the same defect one level down: a gate satisfied by text
# that never executes. Captured into a variable and matched with herestrings
# below, never `entry_code ... | grep -q`: `grep -q` exits at its first match
# and SIGPIPEs the producer, and under this suite's `set -o pipefail` that
# kill-by-signal status becomes the pipeline's, so a MATCH can be read as a
# failure to match.
entry_code() { grep -vE '^[[:space:]]*#' "$1"; }

# entry_gate_violations <file> -- non-empty when <file> is a trust-boundary
# entry point that arms the stale-root gate and reaches no site that fires it.
# Pure: it reads the file and writes stdout, so the fixtures below can be fed
# to the same function the shipped tree is judged by.
entry_gate_violations() {
  local f="$1" code
  [ -f "$f" ] || { printf 'no-such-file: %s\n' "$f"; return 0; }
  code="$(entry_code "$f")"
  grep -q 'lib/common\.sh"' <<<"$code" || return 0
  grep -q '__orchid_entry_defer_restore=1' <<<"$code" || return 0
  grep -q '_orchid_entry_restore_operator_path' <<<"$code" && return 0
  grep -q 'orchid_root_stale_gate' <<<"$code" && return 0
  printf 'gate-armed-never-fired: %s (it defers the operator-PATH restore, so lib/common.sh arms the stale-root gate and leaves the firing to this file — and this file CALLS neither _orchid_entry_restore_operator_path nor orchid_root_stale_gate, so the gate is armed and never fires)\n' "$f"
}

entry_scanned=0
entry_deferring=0
entry_unfired=""
for entry_file in "$REPO_ROOT"/bin/orchid "$REPO_ROOT"/libexec/* "$REPO_ROOT"/runners/*; do
  [ -f "$entry_file" ] || continue
  entry_file_code="$(entry_code "$entry_file")"
  grep -q 'lib/common\.sh"' <<<"$entry_file_code" || continue
  entry_scanned=$((entry_scanned + 1))
  if grep -q '__orchid_entry_defer_restore=1' <<<"$entry_file_code"; then
    entry_deferring=$((entry_deferring + 1))
  fi
  entry_out="$(entry_gate_violations "$entry_file")"
  [ -n "$entry_out" ] || continue
  entry_unfired="$entry_unfired ${entry_file#"$REPO_ROOT"/}"
done
[ "$entry_scanned" -ge 10 ] \
  || fail "INV-15: only $entry_scanned kernel entry point(s) discovered — the executable roots moved, and this scan is judging an almost empty set"
[ "$entry_deferring" -ge 3 ] \
  || fail "INV-15: only $entry_deferring trust-boundary entry point(s) discovered; the shipped set is larger, so the partition below is not reading what it claims to"

entry_unfired="${entry_unfired# }"
assert_eq "$GATE_EXEMPT" "$entry_unfired" \
  "INV-15: the set of trust-boundary entry points that arm the stale-root gate and never fire it must be exactly the declared one — a new member means a verb that runs pre-merge kernel with nothing left to say so, and a departed member means this exemption is stale"

green_case "every shipped trust-boundary entry point reaches a site that fires the gate it arms, with no exemption left standing, and the declared exemption set matched the derived one exactly"

# Doctor is the one deferring diagnostic that has TWO pre-report gates. The
# unattended-trust decision must run first: when Orchid is operating on itself,
# the stale-root gate's Git query targets the very repository whose
# machine-local acknowledgement has not yet been looked up. Both calls are
# straight-line and uniquely named, so their executable-code order is derived
# here rather than left as prose beside the implementation.
doctor_gate_order_violations() {
  local f="$1" code inspect_line stale_line
  code="$(entry_code "$f")"
  inspect_line="$(awk '/^[[:space:]]*unattended_trust_inspect[[:space:]]/ { print NR; exit }' <<<"$code")"
  stale_line="$(awk '/^[[:space:]]*orchid_root_stale_gate[[:space:]]*$/ { print NR; exit }' <<<"$code")"
  case "$inspect_line:$stale_line" in
    *[!0-9:]*|:*|*:) printf 'doctor-gate-order-unprovable: %s\n' "$f"; return 0 ;;
  esac
  if [ "$stale_line" -le "$inspect_line" ]; then
    printf 'doctor-stale-before-trust: %s (stale line %s, trust line %s)\n' \
      "$f" "$stale_line" "$inspect_line"
  fi
}

doctor_order_out="$(doctor_gate_order_violations "$REPO_ROOT/libexec/orchid-doctor")"
[ -z "$doctor_order_out" ] \
  || fail "INV-15: orchid-doctor queries stale-root Git before its trust decision ($doctor_order_out)"
green_case 'orchid-doctor performs its machine-local unattended-trust decision before the stale-root gate can spend a Git query, with both still ahead of its first report'

DOCTOR_ORDER_BAD="$WORK/orchid-doctor-stale-first"
{
  printf '#!/bin/bash -p\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="$PWD"\n'
  printf 'orchid_root_stale_gate\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'unattended_trust_summary_loaded\n'
} > "$DOCTOR_ORDER_BAD"
assert_match 'doctor-stale-before-trust' "$(doctor_gate_order_violations "$DOCTOR_ORDER_BAD")" \
  "INV-15: a doctor-shaped entry point that queries stale-root Git before its trust decision must be reported"
red_case 'the doctor gate-order derivation rejected a fixture whose stale-root Git query precedes its machine-local trust decision, so the shipped ordering is proved rather than merely described'

# The RED twin, on the same function. Three fixtures: the violation, and the
# two shapes that must NOT be flagged, so a scan that says yes to everything
# cannot pass this.
ENTRY_FIXTURES="$WORK/entry-fixtures"
mkdir -p "$ENTRY_FIXTURES"
{ printf '#!/bin/bash -p\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'echo "a trust-boundary entry point that never fires the gate"\n'
} > "$ENTRY_FIXTURES/orchid-unfired"
{ printf '#!/bin/bash -p\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'echo "decision made"\n'
  printf '_orchid_entry_restore_operator_path\n'
} > "$ENTRY_FIXTURES/orchid-restores"
{ printf '#!/bin/bash -p\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'echo "an ordinary verb: it defers nothing, so the gate fires at source time"\n'
} > "$ENTRY_FIXTURES/orchid-ordinary"

assert_match 'gate-armed-never-fired' "$(entry_gate_violations "$ENTRY_FIXTURES/orchid-unfired")" \
  "INV-15: a trust-boundary entry point that arms the gate and reaches no firing site must be reported"
red_case "INV-15's entry-point derivation reported a synthetic trust-boundary entry point that arms the stale-root gate and never fires it, so a gate skipped by omission is detected rather than assumed impossible"

for entry_ok in orchid-restores orchid-ordinary; do
  entry_ok_out="$(entry_gate_violations "$ENTRY_FIXTURES/$entry_ok")"
  [ -z "$entry_ok_out" ] \
    || fail "INV-15: the $entry_ok fixture was reported ($entry_ok_out) — a scan that flags a deferring entry point which DOES restore, or an ordinary verb that defers nothing, would flag the whole tree and prove nothing"
done
green_case 'a deferring entry point that does reach its restore, and an ordinary verb that defers nothing at all, were both left alone, so the report above is omission detection rather than a scan that flags every entry point'

# ===========================================================================
# 5 -- NO GATE MAY BE SKIPPED BY AN ACCIDENT OF PROCESS SCHEDULING.
#
# A third way to skip a gate, and it needs nobody to omit anything: write it
# as `producer | grep -q pattern`. `grep -q` exits at its FIRST match, which
# SIGPIPEs the producer mid-write; every kernel entry point runs under `set -o
# pipefail`, so that kill-by-signal status becomes the pipeline's, and a MATCH
# is read as a failure to match. Which way that costs depends only on how the
# caller branches, and BOTH directions were spelled in this tree when this
# section was written -- twenty-four sites across seven files in lib/,
# scripts/ and every bundled engine adapter, all converted in the same commit
# that added this section. lib/trust.sh could refuse
# a valid --reason for being long enough to still be writing (closed, a
# spurious refusal). scripts/release.sh's placeholder scan -- six whole files
# piped in, `die` on a MATCH -- could skip its own `die` and build the archive
# with the placeholder it exists to catch (OPEN). That second one is the whole
# class in one line: a gate that ran, that nobody skipped, and that passed
# because its producer was killed.
#
# T010's arbitration named the class and asked for a sweep. A sweep is a
# one-off, and a one-off is a gate nothing invokes the second time -- this
# file's own subject. So the sweep is DERIVED here instead, by glob over the
# shipped kernel, and a source file written tomorrow is covered without
# anyone remembering to re-run anything.
#
# THE INVARIANT GATES ARE IN THAT GLOB TOO, and they were the omission this
# section shipped with. `tests/inv/` is where the checks that gate the
# invariants live -- section 2 above exists solely to make their enrolment
# real -- and twenty-five of their assertions were written as `echo "$out" |
# grep -q`. The direction that costs is the one those files use most: a
# NEGATIVE assertion, `... | grep -q pat && fail`, is skipped by pipefail
# EXACTLY when `pat` is present, because that is when grep exits first and
# kills the producer. So the arm that must catch the regression is the one the
# race switches off, and it switches off silently, in the files whose whole
# job is to notice. A gate scanning the kernel for a hazard it carries itself
# is the same defect one level up, which is why the glob below is the kernel
# AND these files.
#
# What is flagged is narrow and mechanical: a pipe into `grep`, with a `q` in
# that grep's flags. A pipe into a grep that reads its input to EOF (-v, -c,
# -o, a bare -E) has no early exit and no race, and the shipped kernel is full
# of them -- which is what makes the GREEN half below a real discrimination
# rather than a scan that flags every pipe.
# ===========================================================================

# The two halves of the shape, spelled once. The first is the DENOMINATOR --
# every pipe into grep, safe or not -- so the second can be shown to be
# selecting rather than matching nothing.
#
# `(^|[^|])` in front of the pipe, and it is not decoration: `cmd || grep -q x
# file` carries a `|` immediately followed by another, and without this the
# scan reads that `||` as a pipe and reports a `grep` that has no producer to
# kill at all (tests/inv/test_INV-08_reasons.sh line 44 is exactly that shape
# and is correct as written). A matcher that cannot tell a pipeline from a
# logical OR would make this section unsatisfiable against honest code, and an
# unsatisfiable gate gets weakened rather than obeyed.
PQ_PIPE_TO_GREP='(^|[^|])\|[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*grep[[:space:]]'
# `[^|]*` so the `q` has to belong to THIS grep rather than to something
# further down the pipeline, and `([[:space:]]|$)` so a line that ends on the
# flag -- with its pattern on a continuation -- is caught like any other.
PQ_EARLY_EXIT='grep[^|]*[[:space:]]-[A-Za-z]*q[A-Za-z]*([[:space:]]|$)'

# piped_grep_lines <file> -- every NON-COMMENT line of <file> that pipes into
# grep, carrying its real line number. The numbers are taken off the unstripped
# file and the comment lines dropped afterwards, rather than stripping first
# the way entry_code does above: a violation here is something an author has
# to go and open, so the number has to be the one in their editor.
piped_grep_lines() {
  grep -nE "$PQ_PIPE_TO_GREP" "$1" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# piped_early_exit_grep <file> -- the subset whose grep carries a `q`. Note
# that neither pipeline in this pair uses `grep -q` itself: both read their
# input to EOF, so this scan is not an instance of the thing it looks for.
piped_early_exit_grep() {
  piped_grep_lines "$1" | grep -E "$PQ_EARLY_EXIT" || true
}

pq_examined=0
pq_violations=""
# Every shipped executable root, INCLUDING the bundled plugins: an engine
# adapter's `classify` is fed the whole of a vendor CLI's combined output,
# which is the largest producer any matcher in this tree gets, and all four
# adapters carried the shape until this section was written. `plugins/*/*/*`
# rather than `plugins/*/*/run`, so a helper script placed beside `run`
# tomorrow is covered too; a plugin.conf simply matches nothing.
#
# ...and `tests/inv/test_*.sh`, by the SAME glob section 2 enrols, so a gate
# file written tomorrow is covered by both at once: section 2 requires it to
# be enforced at run time, this requires the assertions it enforces with to
# mean what they say. The rest of tests/ is deliberately not here -- see the
# not-tested claim at the end of this file for what that leaves open and why
# the invariant gates were taken first.
for pq_file in "$REPO_ROOT"/bin/* "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/libexec/* \
               "$REPO_ROOT"/runners/* "$REPO_ROOT"/scripts/*.sh \
               "$REPO_ROOT"/plugins/*/*/* "$REPO_ROOT"/templates/*.sh \
               "$INV_GLOB_DIR"/test_*.sh; do
  [ -f "$pq_file" ] || continue
  pq_rel="${pq_file#"$REPO_ROOT"/}"
  while IFS= read -r pq_line; do
    [ -n "$pq_line" ] || continue
    pq_examined=$((pq_examined + 1))
  done < <(piped_grep_lines "$pq_file")
  while IFS= read -r pq_line; do
    [ -n "$pq_line" ] || continue
    pq_violations="$pq_violations
  $pq_rel:$pq_line"
  done < <(piped_early_exit_grep "$pq_file")
done

# The denominator, asserted before the verdict: a scan that had stopped
# matching pipes at all would report a clean kernel, and that is the reading
# this whole file exists to make impossible.
[ "$pq_examined" -ge 10 ] \
  || fail "INV-15: only $pq_examined piped-grep line(s) discovered across bin/, lib/, libexec/, runners/, scripts/, plugins/, templates/ and tests/inv/ — the shipped tree has many more, so the early-exit scan below is judging an almost empty set and its silence means nothing"

[ -z "$pq_violations" ] \
  || fail "INV-15: a gate pipes a producer into an early-exiting grep. Under set -o pipefail the SIGPIPE that grep's first match sends the producer becomes the pipeline's status, so a MATCH can be read as no-match — the gate is not skipped, it is decided by process scheduling (the class T010's arbitration named). In an invariant file the usual shape is a NEGATIVE assertion — a producer piped into an early-exiting grep, then '&& fail' — and it is skipped exactly when the pattern IS present. Feed the matcher a herestring instead:$pq_violations"

green_case "every one of the $pq_examined pipes into grep across the shipped tree — kernel, bundled plugins and the tests/inv/ gate files alike — reads its input to EOF, and none carries a -q whose early exit could SIGPIPE the producer and hand pipefail a kill-by-signal status where a verdict belongs"

# The RED twin, on the same two functions. The fixture also carries the shape
# INSIDE A COMMENT, because this repository documents this exact hazard in
# comments all over the kernel -- including in the very files section 5 just
# scanned -- and a scan that counted those would be unsatisfiable.
PQ_FIXTURES="$WORK/piped-grep-fixtures"
mkdir -p "$PQ_FIXTURES"
# The matcher's own spelling, passed IN rather than written out: `tests/inv/`
# is now inside the glob above, so a literal `| grep -q` on any line of this
# file would be a violation reported against this file -- and a gate that has
# to exempt itself from its own scan is one exemption away from being useless.
# The fixture bytes are identical either way; only this file's source differs.
pq_q='grep -q'
{ printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf '  # a herestring, never printf "%%s" "$x" | %s y -- this line is prose\n' "$pq_q"
  printf 'if printf "%%s" "$reason" | LC_ALL=C %s "[^[:space:]]"; then :; fi\n' "$pq_q"
} > "$PQ_FIXTURES/gate-with-a-race"

pq_red_out="$(piped_early_exit_grep "$PQ_FIXTURES/gate-with-a-race")"
assert_match 'grep -q' "$pq_red_out" \
  "INV-15: a producer piped into an early-exiting grep must be reported — that is a gate whose answer depends on whether the producer finished writing before grep exited"
pq_red_count=0
while IFS= read -r pq_line; do
  [ -n "$pq_line" ] || continue
  pq_red_count=$((pq_red_count + 1))
done <<<"$pq_red_out"
assert_eq 1 "$pq_red_count" \
  "INV-15: exactly one line of the fixture is executable; the other spelling of the shape sits in a comment, and counting that one would make this scan unsatisfiable against a kernel that documents the hazard everywhere (got: $pq_red_out)"
red_case "INV-15's early-exit derivation reported a gate written as a producer piped into grep -q, and left the identical shape in a comment beside it alone, so a gate decided by process scheduling is detected rather than assumed absent"

# ...and the accepting twin, which is the load-bearing half here: the safe
# pipes must be EXAMINED and then left alone. Without the denominator check
# below, "no violations" would also be the answer for a scan that had stopped
# seeing pipes altogether.
{ printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf 'active="$(list_them | grep -vxF "$id" || true)"\n'
  printf 'n="$(printf "%%s\\n" "$body" | grep -c "[^[:space:]]" || true)"\n'
  printf 'warns="$(echo "$out" | grep -E "^warn:" || true)"\n'
  printf 'grep -q "[^[:space:]]" <<<"$reason" || die "empty"\n'
  # A logical OR, not a pipeline: two `|` characters in a row, and the grep to
  # their right reads a FILE. There is no producer here for a first match to
  # kill, and a matcher that could not tell this from a pipe would report a
  # shipped invariant gate that is correct as written.
  printf 'is_recorded "$id" || %s "^recorded$" "$ledger"\n' "$pq_q"
} > "$PQ_FIXTURES/gate-without-a-race"

pq_ok_out="$(piped_early_exit_grep "$PQ_FIXTURES/gate-without-a-race")"
[ -z "$pq_ok_out" ] \
  || fail "INV-15: a read-to-EOF pipe (-v, -c, a bare -E), a grep -q fed from a herestring, or a grep -q on the right of a logical OR was reported anyway ($pq_ok_out) — none of the three can SIGPIPE a producer, and a scan that flagged them would flag the shipped tree and could never be satisfied"
pq_ok_seen=0
while IFS= read -r pq_line; do
  [ -n "$pq_line" ] || continue
  pq_ok_seen=$((pq_ok_seen + 1))
done < <(piped_grep_lines "$PQ_FIXTURES/gate-without-a-race")
[ "$pq_ok_seen" -ge 3 ] \
  || fail "INV-15: only $pq_ok_seen of the accepting fixture's three piped greps were EXAMINED at all, so leaving them unflagged demonstrates nothing about the flag test — it demonstrates the pipe matcher missing them"
green_case "the accepting fixture's three read-to-EOF pipes were all examined and none was flagged, and neither the herestring-fed grep -q beside them nor the grep -q on the right of a logical OR was, so the report above discriminates by early exit rather than by the presence of a pipe or of two adjacent pipe characters"

# ===========================================================================
# 6 -- A GATE REACHED ONLY AFTER THE FIRST WRITE IS REACHED TOO LATE.
#
# Section 4 asks whether a trust-boundary entry point CONTAINS a firing site.
# That is a text question and it has a text answer, and both halves of this
# file's subject say why that is not enough: `runners/orchid-pump` contained
# one (`_orchid_entry_restore_operator_path`, five lines below its outbox
# machinery) and reached it only after `orchid_runtime` had already created
# `.orchid/runtime` in the target repository and, under `--service-log`, after
# it had created and opened `pump.log` there. Every scan in this file passed
# that, because every scan in this file reads source. A stale kernel does not
# become safe by writing only a directory before it is stopped -- the point of
# the guard is that NOTHING pre-merge runs, and a gate placed after the first
# side effect has already lost the argument for the side effects it did not
# happen to reach.
#
# So this section EXECUTES the pump, twice, against the same repository, with
# one difference between the runs: the installation root it is invoked from.
# The witness is the runtime directory -- absent after the refusal, present
# after the run that is allowed to proceed -- which is what makes the absence
# evidence of the gate rather than evidence of a pump that writes nothing
# there anyway.
#
# The fixture repository is left at `run_status: planning` deliberately: the
# pump's lease step exits 0 on it with a diagnostic, which is far enough past
# the gate to have created the runtime directory and short of anything that
# spends an engine.
# ===========================================================================
PUMP_PROOF="$WORK/pump-gate"
mkdir -p "$PUMP_PROOF"

# The stale root, built out of THIS candidate's own kernel rather than a
# stand-in: bin/, lib/ and runners/ are copied because that is what the pump
# actually loads, and the remaining kernel directories are created empty so
# the guard's pathspec (ORCHID_KERNEL_PATHS) names something real in each.
# `templates/.keep` is what gets staged, so the refusal has a path to report
# that no other part of this fixture could have produced.
PUMP_ROOT="$PUMP_PROOF/stale-root"
mkdir -p "$PUMP_ROOT"
for pump_dir in bin lib runners; do
  cp -R "$REPO_ROOT/$pump_dir" "$PUMP_ROOT/$pump_dir"
done
for pump_dir in libexec plugins roles skills templates; do
  mkdir -p "$PUMP_ROOT/$pump_dir"
  printf 'probe\n' > "$PUMP_ROOT/$pump_dir/.keep"
done
printf 'PROTOCOL probe\n' > "$PUMP_ROOT/PROTOCOL.md"
printf 'integration_branch=%s\n' "$PROBE_INTEG" > "$PUMP_ROOT/orchid.config"
chmod +x "$PUMP_ROOT/bin/orchid" "$PUMP_ROOT/runners/orchid-pump"
git init -q "$PUMP_ROOT"
git -C "$PUMP_ROOT" symbolic-ref HEAD "refs/heads/$PROBE_INTEG"
git -C "$PUMP_ROOT" add -A
git -C "$PUMP_ROOT" commit -q -m "pump probe root"
printf 'staged kernel edit\n' >> "$PUMP_ROOT/templates/.keep"
git -C "$PUMP_ROOT" add templates/.keep
[ -n "$(git -C "$PUMP_ROOT" diff --cached --name-only HEAD -- templates)" ] \
  || fail "INV-15: the pump fixture's root has no staged kernel edit, so it is not stale and the refusal below would prove nothing"

# The target repository, and it is a DIFFERENT directory from the root above:
# what is under test is a scheduled pump reaching a repo out of a stale
# installation, which is the shape a `service install` leaves behind.
PUMP_REPO="$PUMP_PROOF/repo"
mkdir -p "$PUMP_REPO"
git init -q "$PUMP_REPO"
git -C "$PUMP_REPO" commit -q --allow-empty -m root
mkdir -p "$PUMP_REPO/.orchid/tasks"
printf -- '---\nrun_status: planning\nrun_id: inv15-pump\n---\n# Roadmap\n' \
  > "$PUMP_REPO/.orchid/roadmap.md"

# ACKNOWLEDGED, and this is load-bearing rather than setup: without it the
# pump refuses at the unattended-trust gate, which sits AHEAD of the stale-root
# gate and writes nothing either -- so the runtime directory would be absent
# for the wrong reason and this section would prove nothing at all.
HOME="$MACHINE_HOME" "$ORCHID_BIN" trust unattended "$PUMP_REPO" \
  --reason "INV-15 pre-write pump gate fixture" >/dev/null \
  || fail "INV-15: could not acknowledge the pump fixture repository, so the runs below would be stopped by the unattended-trust gate rather than by the gate this section is about"

# pump_probe <root> -- one pump invocation against $PUMP_REPO out of <root>.
# ORCHID_ALLOW_STALE_ROOT is spelled empty rather than left inherited: an
# operator with it exported would otherwise switch off the very gate this
# section measures.
pump_rc=0
pump_out=""
pump_probe() {
  pump_rc=0
  pump_out="$(HOME="$MACHINE_HOME" ORCHID_REPO="$PUMP_REPO" ORCHID_ALLOW_STALE_ROOT='' \
    "$1/runners/orchid-pump" 2>&1)" || pump_rc=$?
}

[ ! -e "$PUMP_REPO/.orchid/runtime" ] \
  || fail "INV-15: the pump fixture already has a runtime directory before any pump has run, so its absence below would be inherited rather than caused"

pump_probe "$PUMP_ROOT"
assert_eq 1 "$pump_rc" \
  "INV-15: a pump invoked out of a stale installation root must refuse (got rc=$pump_rc: $pump_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$pump_out" \
  "INV-15: ...and it must be the stale-root refusal, not some other failure of the fixture"
assert_match 'templates/\.keep' "$pump_out" \
  "INV-15: the refusal must name the staged kernel path, which only the index comparison can have produced"
[ ! -e "$PUMP_REPO/.orchid/runtime" ] \
  || fail "INV-15: the refused pump created $PUMP_REPO/.orchid/runtime before the stale-root gate fired. The gate is reachable and it is reached too late: a stale kernel wrote into the target repository, and everything after that write is guarded only by where the next author happens to put the call"
red_case "a pump invoked out of a genuinely stale installation root refused before its first write -- the refusal named the staged kernel path, and the target repository has no runtime directory, so the gate this entry point arms fires ahead of its side effects rather than merely somewhere inside it"

# The case that must NOT fire, on the SAME repository: this checkout's own
# pump, which is not stale, must run and must create the very directory the
# refusal above proved absent. Without it, an entry point that refused
# everything -- or a pump that never wrote there at all -- would satisfy the
# assertions above.
pump_probe "$REPO_ROOT"
assert_eq 0 "$pump_rc" \
  "INV-15: this checkout's own pump must run against an acknowledged repository (got rc=$pump_rc: $pump_out). If this is the stale-root refusal, the checkout the suite is running from is itself parked on its integration branch with a staged kernel edit, and every verb is refusing for the same reason"
assert_match 'run not running \(planning\), no lease yet' "$pump_out" \
  "INV-15: ...and it must get as far as the lease step, which is past the gate"
[ -d "$PUMP_REPO/.orchid/runtime" ] \
  || fail "INV-15: the pump that was allowed to proceed created no runtime directory, so the absence asserted in the RED case above is not evidence of anything the gate did"
green_case 'the same pump, against the same acknowledged repository, ran to its lease step out of a root that is not stale and created the runtime directory there -- so the refusal above is the gate stopping a write that really does happen, rather than a pump that writes nothing or an entry point that refuses everything'

# ===========================================================================
# 7 -- THE MERGE FLOOR, EXECUTED.
#
# Section 1 reads `scripts/ci-local.sh` and `orchid.config` and concludes that
# this repository's static checks are inside a floor every task inherits. Both
# of those are text. The sentence L016 actually costs -- "a task whose
# verification_commands omits the gate is still gated before its ref can
# advance" -- is about a verb's behaviour, and it is asked here of the shipped
# `orchid merge`, on a real task, in a real repository.
#
# The task's `verification_commands` is `true`: it names no gate, no linter
# and no suite, exactly like the six r-001 tasks that never opted in. The
# repository's `merge_gate` exits non-zero. The integration ref must not move.
# Then the identical scenario with a green gate must merge, so the refusal is
# attributable to the gate's exit status and to nothing else about this
# fixture.
# ===========================================================================
#
# `unset`, not `export ...=`: this file runs inside `scripts/ci-local.sh` in
# CI, which sets the recursion marker so a gate that is the repository's own
# suite cannot open a second level of itself. Inherited here, the fixture's
# gate would correctly skip and BOTH arms below would assert nothing -- a
# green section proving the opposite of what it claims, which is this file's
# whole subject. The fixture's own gate is `ls`, so nothing recurses.
unset ORCHID_MERGE_GATE_ACTIVE

MERGE_PROOF="$WORK/merge-floor"
mkdir -p "$MERGE_PROOF"
cd_scratch "$MERGE_PROOF" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$MERGE_PROOF"
HOME="$WORK/merge-home"; mkdir -p "$HOME"; export HOME
mg_integ=orchid/integration
git branch "$mg_integ"

# `ls` is the gate body in both arms: it exits 0 and it writes the tree it ran
# against into the marker, so "the gate ran" and "the gate ran against the
# MERGED tree" are one assertion. The red body differs from the green one in
# its exit status and in nothing else.
MERGE_GATE_MARKER="$WORK/inv15-merge-gate-ran.txt"
mg_gate_pass="ls >> $MERGE_GATE_MARKER"
mg_gate_fail="ls >> $MERGE_GATE_MARKER; exit 7"
mg_set_gate() {
  {
    printf 'integration_branch=%s\n' "$mg_integ"
    printf 'merge_gate=%s\n' "$1"
  } > orchid.config
}
mg_set_gate "$mg_gate_fail"

ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# The only path the kernel allows into `merging`, walked verbatim: a real
# passing `orchid verify` (INV-11's gate) and a reconciled reviewer envelope.
# A hand-set status would prove nothing about a verb that reads the status it
# was handed.
mg_walk_to_merging() {  # <id> <branch> <base> <cand> <verification_commands>
  "$ORCHID_BIN" task set "$1" base_sha "$3"
  "$ORCHID_BIN" task set "$1" candidate_sha "$4"
  "$ORCHID_BIN" task set "$1" verification_commands "$5"
  "$ORCHID_BIN" task advance "$1" implementing >/dev/null
  "$ORCHID_BIN" task advance "$1" testing >/dev/null
  git checkout -q "$2"
  "$ORCHID_BIN" verify "$1" >/dev/null
  git checkout -q "$mg_integ"
  "$ORCHID_BIN" task advance "$1" reviewing >/dev/null
  plant_reviewer_envelope "$1"
  "$ORCHID_BIN" task advance "$1" arbitrating --reason "single reviewer approved" >/dev/null
  "$ORCHID_BIN" task advance "$1" merging --reason "approved for merge" >/dev/null
}

"$ORCHID_BIN" task create T101 "gated without opting in" >/dev/null
git checkout -q -b task/T101 "$mg_integ"
printf 'red\n' > inv15-red.txt
git add inv15-red.txt
git commit -q -m "INV-15 red candidate"
mg_cand="$(git rev-parse HEAD)"
git checkout -q "$mg_integ"
mg_base="$(git rev-parse "$mg_integ")"
mg_walk_to_merging T101 task/T101 "$mg_base" "$mg_cand" true

# The premise of the whole section, asserted rather than assumed: this task
# asked for nothing.
mg_vc="$("$ORCHID_BIN" task show T101 | grep '^verification_commands: ' | cut -d' ' -f2-)"
assert_eq "true" "$mg_vc" \
  "INV-15: the fixture task's own verification_commands must name nothing but 'true', or it opted in and the gating below is not the property under test"

: > "$MERGE_GATE_MARKER"
mg_pre="$(git rev-parse "$mg_integ")"
mg_rc=0
mg_out="$("$ORCHID_BIN" merge T101 2>&1)" || mg_rc=$?
[ "$mg_rc" -ne 0 ] \
  || fail "INV-15: a merge whose repo-wide gate exited non-zero reported success (out: $mg_out)"
assert_eq "$mg_pre" "$(git rev-parse "$mg_integ")" \
  "INV-15: the integration ref MOVED past a red repo-wide gate — that is lesson L016 restored: the gate ran, the task never opted into it, and its work landed anyway"
mg_log=".orchid/reviews/T101-merge.log"
assert_match 'inv15-red\.txt' "$(cat "$MERGE_GATE_MARKER")" \
  "INV-15: the gate must have RUN, and against the merged tree — its own listing carries the candidate's file"
assert_match '^gate_status: ran$' "$(cat "$mg_log")" \
  "INV-15: the merge evidence must record that the repo-wide gate ran"
assert_match '^gate_exit: 7$' "$(cat "$mg_log")" \
  "INV-15: ...and the status it came back with"
assert_match '^command_status: 0$' "$(cat "$mg_log")" \
  "INV-15: the task's OWN suite passed, so the refusal is the repo-wide gate's and nothing else about this candidate"
assert_match "^candidate: $mg_cand\$" "$(cat "$mg_log")" \
  "INV-15: the evidence must be bound to the candidate that was actually gated — a merge log that names no candidate, or names a superseded one, is a record of a gate run on something else"
# WHERE THE GATE CAME FROM, which is the other half of "no task can switch it
# off": a candidate is a TREE, and a tree can carry an orchid.config of its
# own. Resolved from the merged tree instead of from the repository, a
# candidate could ship a one-line config naming a gate that trivially passes
# and be judged by it -- the floor lowered by the very change it is there to
# judge. This fixture's orchid.config is never committed, so the merged tree
# has none at all: had the gate been resolved from there, nothing would have
# run and every assertion above would have failed.
assert_eq "gate: $mg_gate_fail" "$(grep '^gate: ' "$mg_log")" \
  "INV-15: the gate that ran must be verbatim the REPOSITORY's configured command, resolved from repo config rather than from the tree being merged"
red_case "a task whose verification_commands names nothing but 'true' was gated anyway by the repository's merge_gate, the gate ran against the merged tree, it exited 7, and the integration ref did not move — L016's sentence executed against the shipped orchid merge rather than read out of orchid.config"

# The GREEN twin: same repository, same absent opt-in, one difference -- the
# gate's exit status. Without it the RED case would be satisfied by a merge
# that refuses everything.
mg_set_gate "$mg_gate_pass"
"$ORCHID_BIN" task create T102 "green gate, still no opt-in" >/dev/null
git checkout -q -b task/T102 "$mg_integ"
printf 'green\n' > inv15-green.txt
git add inv15-green.txt
git commit -q -m "INV-15 green candidate"
mg_cand2="$(git rev-parse HEAD)"
git checkout -q "$mg_integ"
mg_base2="$(git rev-parse "$mg_integ")"
mg_walk_to_merging T102 task/T102 "$mg_base2" "$mg_cand2" true

: > "$MERGE_GATE_MARKER"
mg_rc=0
mg_out="$("$ORCHID_BIN" merge T102 2>&1)" || mg_rc=$?
assert_eq 0 "$mg_rc" "INV-15: the identical scenario with a GREEN gate must merge (out: $mg_out)"
[ "$(git rev-parse "$mg_integ")" != "$mg_base2" ] \
  || fail "INV-15: the integration ref did not advance past a green gate, so the RED case above is not evidence that the red gate is what stopped it"
assert_eq "done" "$("$ORCHID_BIN" task show T102 | grep '^status: ' | cut -d' ' -f2)" \
  "INV-15: ...and the task reaches done — the floor delays a merge, it does not derail one"
assert_match 'inv15-green\.txt' "$(cat "$MERGE_GATE_MARKER")" \
  "INV-15: the green gate ran too, against its own merged tree — the floor is not skipped for a task that would have passed anyway"
green_case 'the same repository, the same task-level opt-in (none), and a gate that exits 0 merged and advanced the integration ref, so the refusal above is the gate exit status being obeyed rather than a verb that refuses every merge'

# ===========================================================================
# 8 -- THE ENTRY POINT THAT NEVER RESTORES THE OPERATOR PATH FIRES THE GATE
# ANYWAY, BEFORE ITS DURABLE WRITE.
#
# `libexec/orchid-trust` is the one trust-boundary entry point that holds the
# fixed bootstrap PATH for its whole run: acknowledgement, inspection and
# revocation never call _orchid_entry_restore_operator_path, which is where
# lib/common.sh fires the gate for everything else that defers. So it armed the
# gate and fired it nowhere, and section 4 carried it as a declared exemption
# whose stated reason -- "its entire body IS the authorization decision, so
# there is no moment for the gate to occupy" -- was wrong. The moment is the
# one every other entry point has: after the operator's command has been
# validated, and before the durable write. `orchid trust unattended` authors a
# machine-local record that every unattended run afterwards is authorized by.
# Authored out of a stale checkout, it is authored by pre-merge code -- and the
# record outlives the process that wrote it, which is what makes it a side
# effect rather than an answer.
#
# Section 4 cannot see this, for the reason it says: it asks whether the file
# CALLS a firing site. So this section runs the verb twice against the same
# repository, differing only in the installation root, and weighs the refusal
# against the store: empty after the refusal, holding a record after the run
# that is allowed to proceed. That contrast is what makes the emptiness
# evidence of the gate rather than evidence of a verb that writes nothing.
# ===========================================================================
TRUST_PROOF="$WORK/trust-gate"
mkdir -p "$TRUST_PROOF"

# The stale root, out of this candidate's own kernel: bin/, lib/ and libexec/
# are what `orchid trust` loads and dispatches through. `templates/.keep` is
# what gets staged, so the refusal names a path nothing else in this fixture
# could have produced.
TRUST_ROOT="$TRUST_PROOF/stale-root"
mkdir -p "$TRUST_ROOT"
for trust_dir in bin lib libexec; do
  cp -R "$REPO_ROOT/$trust_dir" "$TRUST_ROOT/$trust_dir"
done
for trust_dir in runners plugins roles skills templates; do
  mkdir -p "$TRUST_ROOT/$trust_dir"
  printf 'probe\n' > "$TRUST_ROOT/$trust_dir/.keep"
done
printf 'PROTOCOL probe\n' > "$TRUST_ROOT/PROTOCOL.md"
printf 'integration_branch=%s\n' "$PROBE_INTEG" > "$TRUST_ROOT/orchid.config"
chmod +x "$TRUST_ROOT/bin/orchid" "$TRUST_ROOT/libexec/orchid-trust"
git init -q "$TRUST_ROOT"
git -C "$TRUST_ROOT" symbolic-ref HEAD "refs/heads/$PROBE_INTEG"
git -C "$TRUST_ROOT" add -A
git -C "$TRUST_ROOT" commit -q -m "trust probe root"
printf 'staged kernel edit\n' >> "$TRUST_ROOT/templates/.keep"
git -C "$TRUST_ROOT" add templates/.keep
[ -n "$(git -C "$TRUST_ROOT" diff --cached --name-only HEAD -- templates)" ] \
  || fail "INV-15: the trust fixture's root has no staged kernel edit, so it is not stale and the refusal below would prove nothing"

# A HOME of its own, so the store starts genuinely empty and the count below
# is this section's own writes rather than another section's acknowledgement.
make_scratch TRUST_HOME
TRUST_STORE="$TRUST_HOME/.orchid/unattended-trust"

TRUST_REPO="$TRUST_PROOF/repo"
mkdir -p "$TRUST_REPO"
git init -q "$TRUST_REPO"
git -C "$TRUST_REPO" commit -q --allow-empty -m root

# trust_store_files -- how many durable records the machine-local store holds.
# The witness is a COUNT of files rather than the presence of one named path:
# what may not happen out of a stale kernel is any durable write at all, and
# naming the record's own filename here would miss an anchor, a log or a
# scratch file left beside it.
trust_store_files() {
  local n=0 f
  [ -d "$TRUST_STORE" ] || { printf '0'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
  done < <(find "$TRUST_STORE" -type f 2>/dev/null || true)
  printf '%s' "$n"
}

trust_rc=0
trust_out=""
# <root> -- one acknowledgement attempt out of <root>. The environment is
# spelled rather than inherited: section 7 above exports ORCHID_REPO and
# ORCHID_EPOCH for its own merge fixture, and a run that picked either of them
# up would be answering about that repository. ORCHID_ALLOW_STALE_ROOT is
# spelled empty for the same reason section 6 does it -- an operator with it
# exported would switch off the gate this section measures.
trust_probe() {
  trust_rc=0
  trust_out="$(env -u ORCHID_REPO -u ORCHID_EPOCH \
    HOME="$TRUST_HOME" ORCHID_ALLOW_STALE_ROOT='' \
    "$1/bin/orchid" trust unattended "$TRUST_REPO" \
    --reason "INV-15 pre-write trust gate fixture" 2>&1)" || trust_rc=$?
}

assert_eq 0 "$(trust_store_files)" \
  "INV-15: the trust fixture's store is not empty before any acknowledgement has been attempted, so the emptiness asserted below would be inherited rather than caused"

trust_probe "$TRUST_ROOT"
assert_eq 1 "$trust_rc" \
  "INV-15: 'orchid trust unattended' invoked out of a stale installation root must refuse (got rc=$trust_rc: $trust_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_out" \
  "INV-15: ...and it must be the stale-root refusal, not a usage error or some other failure of the fixture"
assert_match 'templates/\.keep' "$trust_out" \
  "INV-15: the refusal must name the staged kernel path, which only the index comparison can have produced — the gate is not merely called here, it ran and it SAW something"
assert_eq 0 "$(trust_store_files)" \
  "INV-15: the refused acknowledgement wrote into the machine-local trust store anyway. The gate is reached and it is reached too late: a stale kernel authored the record every later unattended run is authorized by, and that record outlives the process that refused"
red_case "an acknowledgement attempted out of a genuinely stale installation root refused before its durable write — the refusal named the staged kernel path and the machine-local trust store is still empty, so the one entry point that never restores the operator PATH fires the gate it arms, ahead of its own side effect"

# The case that must NOT fire, on the SAME store and the SAME repository: this
# checkout's own kernel, which is not stale, must acknowledge and must leave
# behind the very record the refusal above proved absent.
trust_probe "$REPO_ROOT"
assert_eq 0 "$trust_rc" \
  "INV-15: this checkout's own 'orchid trust unattended' must acknowledge the fixture repository (got rc=$trust_rc: $trust_out). If this is the stale-root refusal, the checkout the suite runs from is itself parked on its integration branch with a staged kernel edit, and every verb is refusing for the same reason"
assert_match 'unattended trust acknowledged' "$trust_out" \
  "INV-15: ...and it must be the acknowledgement, not some other zero exit"
[ "$(trust_store_files)" -gt 0 ] \
  || fail "INV-15: the acknowledgement that was allowed to proceed wrote nothing durable, so the empty store asserted in the RED case above is not evidence of anything the gate did"
green_case 'the same acknowledgement, of the same repository, into the same machine-local store, out of a root that is NOT stale wrote its record and exited 0 -- so the refusal above is the gate stopping a write that really does happen, rather than a verb that writes nothing or an entry point that refuses everything'

# ---------------------------------------------------------------------------
# THE SAME ORDERING, ON THE ARM THAT WRITES NOTHING DURABLE.
#
# The lookup arm -- `orchid trust show` -- carried the last exemption in this
# file, on the reasoning that it authors no machine-local record and so has
# nothing to protect. That reasoning weighed the wrong side effect. What the
# lookup produces is the REPORT an operator reads before deciding whether a
# scheduled run may execute against this repository: the gate verdict, the
# record it resolved, the root verification, the provenance. Out of a stale
# checkout that report is produced BY the pre-merge code, and an answer nobody
# has looked at is not cheaper than a refusal, because the operator then acts
# on it. A verb exempted for being read-only is also exactly how the advisory
# version of this guard failed.
#
# So the arm is held to the ordering the acknowledgement is held to, with the
# report itself as the side effect the refusal must precede -- and it is
# proven on the record the acknowledgement above really did write, so the
# report has something to say and its absence is the gate suppressing it
# rather than an empty store answering nothing.
#
# AND THE OTHER EDGE OF THE ORDERING, which the acknowledgement half cannot
# show: the gate fires AFTER the operator's command has been validated, never
# in front of a usage error. Out of the same stale root, a `show` with too
# many arguments must still be answered with its usage message. Without that
# edge "fire it earlier" has no floor, and the refusal starts standing in for
# the diagnosis of a typo.
trust_show_probe() {
  local root="$1"; shift
  trust_rc=0
  trust_out="$(env -u ORCHID_REPO -u ORCHID_EPOCH \
    HOME="$TRUST_HOME" ORCHID_ALLOW_STALE_ROOT='' \
    "$root/bin/orchid" trust show "$@" 2>&1)" || trust_rc=$?
}

# The GREEN twin runs FIRST here, deliberately: the RED below asserts the
# ABSENCE of the report, and an absence is worth nothing until the report is
# known to be something this verb produces.
trust_show_probe "$REPO_ROOT" "$TRUST_REPO"
assert_eq 0 "$trust_rc" \
  "INV-15: 'orchid trust show' out of this checkout's own kernel must report on the repository the acknowledgement above bound (got rc=$trust_rc: $trust_out)"
assert_match '^binding_state: ' "$trust_out" \
  "INV-15: ...and the report an operator acts on must actually be produced"
assert_match '^unattended trust: trusted' "$trust_out" \
  "INV-15: ...and it must resolve the record written above. Anything else means this lookup is answering about some other repository or some other store, and the absence asserted below would not be the gate's doing"
green_case "the lookup arm of 'orchid trust', run out of a root that is NOT stale, resolved the acknowledgement written above and printed the report an operator reads before letting a scheduled run proceed -- so that report is a side effect which really does happen, and its absence below is caused rather than inherited"

trust_show_probe "$TRUST_ROOT" "$TRUST_REPO"
assert_eq 1 "$trust_rc" \
  "INV-15: 'orchid trust show' invoked out of a stale installation root must refuse (got rc=$trust_rc: $trust_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_out" \
  "INV-15: ...and it must be the stale-root refusal, not a usage error or some other failure of the fixture"
assert_match 'templates/\.keep' "$trust_out" \
  "INV-15: the refusal must name the staged kernel path — the gate is not merely called on this arm, it ran and it SAW something"
case "$trust_out" in
  *'binding_state:'*)
    fail "INV-15: the refused lookup printed its report anyway, so the gate on this arm is reached after the answer it was supposed to precede. An operator reading that report is reading pre-merge code's account of whether an unattended run may execute here, which is the side effect a read-only exemption overlooks" ;;
esac
red_case "the lookup arm, out of a genuinely stale installation root, refused BEFORE it reported — the refusal named the staged kernel path and not one line of the report an operator acts on was produced, so the arm that writes nothing durable is held to the same ordering as the arm that does"

# And the gate is still BELOW the authorization decision: the same stale root,
# a command that is simply wrong, which must be answered as a usage error.
trust_show_probe "$TRUST_ROOT" "$TRUST_REPO" "$TRUST_REPO"
assert_eq 1 "$trust_rc" \
  "INV-15: 'orchid trust show' with too many arguments must fail (got rc=$trust_rc: $trust_out)"
assert_match 'usage: orchid trust show' "$trust_out" \
  "INV-15: ...and out of a stale root it must still be the USAGE message. The gate belongs after the operator's command has been validated, not in front of a typo's diagnosis — otherwise every mistyped invocation is answered with a refusal about the checkout instead"

# ===========================================================================
# 9 -- the boundaries of what any of this proves.
# ===========================================================================
not_tested "gate-omission-beyond-the-four-families" \
  "enforcement gates outside the four this file derives — the static sections of scripts/ci-local.sh, the tests/inv/ gate files, the stale-root guard's entry-point reach, and the early-exit matcher shape across the shipped kernel, the bundled plugins and those same gate files. A gate that is none of those (a check living only inside one verb, a hook a plugin installs) is held to the same rule by review. What makes the four checkable is that each has a DISCOVERABLE membership: a banner, a glob, a source line, a syntactic shape. A new gate family belongs here the moment its membership becomes derivable"
not_tested "firing-site-reachability-within-an-entry-point" \
  "whether a firing site an entry point CONTAINS is actually REACHED on every route through that file, for every entry point but the two sections 6 and 8 execute. Section 4 is textual by construction: it asks whether the file calls _orchid_entry_restore_operator_path or orchid_root_stale_gate, which a scan can answer, and not whether every path to that file's own work runs past the call -- or runs past it BEFORE that work -- which it cannot. Section 6 answers both questions for runners/orchid-pump and section 8 for libexec/orchid-trust, each by running the entry point and weighing its refusal against a side effect that really does happen otherwise; that is two entry points out of the deferring set. For the rest it is answered structurally: every shipped deferring entry point calls its firing site unconditionally, and runners/orchid-service -- the one that fires the gate itself rather than through the PATH restore, and the one that shipped this per-arm and had to be corrected -- now calls it on the straight-line path above its dispatch, so it has no arm that could forget. libexec/orchid-trust is the one that fires PER SUBCOMMAND, because what the gate must precede is per subcommand, and NO arm of it is exempt any longer: the lookup arm carried an exemption for writing nothing durable, that exemption is gone, and section 8 executes both the acknowledgement, whose side effect is the record it writes, and the lookup, whose side effect is the report an operator acts on. What section 8 does not run is the third arm, revocation, which carries the same call above the same kind of durable mutation. So a trust subcommand added tomorrow that acts and forgets the call is caught by nothing: section 4 sees the file's other call sites and is satisfied, and section 8 only ever asked about the arms it runs. An entry point that guards its call, or that acts before it, belongs to review, and the two questions to put to it are the ones sections 4, 6 and 8 put to those three: on which route is your gate not reached, and what have you already done by the time it is"
not_tested "early-exit-matchers-outside-the-kernel-and-the-invariant-gates" \
  "the rest of tests/. Section 5's glob is the shipped kernel, the bundled plugins and tests/inv/test_*.sh, and the last of those was added because an invariant gate deciding its verdict by a race is the same defect the section scans the kernel for. The other test files carry the shape too, in the hundreds, and they are not covered here: converting them is a mechanical sweep of a different size, and the argument for taking the gates first is that a wrong answer there is a wrong answer about the kernel, whereas a wrong answer in a feature test is a flaky test somebody re-runs. The tell is unchanged wherever it appears, and the direction that costs is the negative assertion: a producer piped into an early-exiting grep, then '&& fail', is skipped exactly when the pattern is present. Spelled in words rather than in code, here and in the failure message above, because these two lines are not comments: this file is inside the glob it runs, so a literal instance of the shape on a line of its own prose is a violation of this invariant reported against this file — which is the right answer, and the reason the wording works around it"
not_tested "early-exit-matchers-other-than-grep-q" \
  "producers killed by an early-exiting consumer that is not grep -q. A head -n1, a sed -n 1q, and a bare read in a pipeline all stop reading before their input ends and all SIGPIPE upstream the same way; section 5 derives exactly one consumer because that is the one the shipped tree used, and the sites that pipe into head today discard the status with an explicit fallback rather than branching on it. The tell is the same wherever it appears: a pipeline under set -o pipefail whose right-hand side can stop reading first, so its exit status may be the producer's death rather than the matcher's verdict"
not_tested "recorded-label-integrity-outside-the-invariant-gates" \
  "labels recorded anywhere but tests/inv/test_*.sh, and executing punctuation that is not a backtick. Section 2's label scan reads the gate files, because a gate whose own record says something its author did not write is this file's subject at the smallest scale; the rest of tests/ records labels through the same helpers and is not covered. Two shapes inside the scanned files are outside it as well. A recorder call written inside a heredoc body is read as ordinary code, since the scanner tracks quoting and not here-documents — no shipped gate has one, and a fixture that grows one would be reported rather than missed, which is the safe direction. And '\$( )' is deliberately accepted: labels interpolate the counts that make them non-vacuous, and unlike a backtick in a sentence that spelling is visible as code to whoever types it. What is derived here is the punctuation that has actually shipped three times, not every way a shell can be made to run a word"
not_tested "gate-vacuity-beyond-the-integration-branch-dimension" \
  "environment dimensions other than 'is \$ORCHID_ROOT parked on the configured integration branch'. That is the one lesson L036 was paid for, and it is the one section 3 constructs. Other dimensions in which a revalidation environment differs from a deployed one — a machine with no vendor CLI (tests/test_hermetic_suite.sh constructs that one), a HOME with no acknowledgement, a repository with no remote — are each somebody's own proof to construct, and none of them is covered here. The question to ask of any new gate is the one this file's header asks: in which environment is the condition you branch on false, and is that the environment you test in"
