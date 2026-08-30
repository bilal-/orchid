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
#   * section 2 RUNS every file the red-case rule enrols -- the tests/inv/
#     gates by location and the whole-file proofs helpers.sh names by array,
#     each at the depth it ships at -- against a stub helpers.sh, and requires
#     each to be observed reaching its source line, because "the file contains
#     a source line" is text and a line's presence is not its execution: a
#     source guarded by a variable nothing sets, or written below an `exit`,
#     satisfies a grep and is never reached.
#   * section 6 runs the pump out of a root that really is stale and requires
#     the refusal to land BEFORE the pump's first write, with the write itself
#     as the witness -- a gate an entry point reaches only after it has
#     already written is reached too late. It then asks the same question of
#     the routes through both scheduled runners that write NOTHING and answer
#     anyway -- `pump: not an orchid repo`, the split-brain line, `pump: run
#     complete`, the tick's
#     finished-run line -- each of which exits above the trust gate and had the
#     stale-root gate below it, so a gate present in the file was skipped on
#     the route that only produces a verdict. A verdict about this repository,
#     read out of the tree whose staleness is the finding, is what an operator
#     acts on next.
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
#     has been validated and not in front of a typo. It then puts both halves
#     to the OTHER verb that fires this gate itself, runners/orchid-service:
#     its usage arm out of that same stale root must be answered, and its
#     status arm out of it must refuse with the report absent. The one route on
#     which this gate does not fire has to be the same route in both files, or
#     it is an omission in one of them wearing the other's justification.
#   * section 9 runs the shipped `orchid doctor` AND the shipped `orchid trust
#     show` in the one environment where the order of their two pre-report
#     gates can be wrong: the target and ORCHID_ROOT the SAME stale integration
#     checkout, with no acknowledgement for it anywhere. Refused, each must
#     have printed nothing at all and the first Git of the whole run must be
#     the gate's own index comparison; with the gate stood down by its
#     documented override and nothing else changed, each must reach and render
#     its denial having spent no Git whatsoever. Git reports its own
#     subprocesses onto the same stream as the run's output, so "before the
#     denial" is read off one ordering. Everywhere else those two paths are
#     different directories and the ordering costs nothing to get wrong, which
#     is lesson L036's shape exactly.
#     For the lookup arm the ordering is also read off directly rather than
#     inferred, which the empty-store runs cannot do: with an acknowledgement
#     on record the machine-local lookup walks the target's history, so it has
#     a POSITION, and it must hold it ahead of the gate's index comparison. The
#     previous ordering, as a fixture in the identical environment, must be
#     reported.
#     It then runs the third arm, `orchid trust revoke`, on that same
#     self-hosted target: refused, it must remove nothing, report nothing, and
#     spend the gate's comparison as its first Git; stood down, it must remove
#     the record and spend NO Git at all, which is what makes that single
#     comparison the gate's own. Its ordering cannot be read off a trace --
#     revocation walks no history by design, so its machine-local half spends
#     nothing in any environment -- so it is pinned on the one thing this arm
#     can still print out of a stale root, the diagnosis of a target whose
#     identity it cannot derive, with the twin that must produce it.
#     And last it runs BOTH ARMS of `orchid status`, because only one of them
#     makes the decision at all: `--explain` inspects unattended trust and
#     fires at the restore below it, while PLAIN status reaches the identical
#     restore having looked nothing up. A file read as one straight line reads
#     as "decision first" either way, so the arms are told apart by running
#     them -- the plain arm refusing with the gate's comparison as the run's
#     first Git and not one line of its report printed, the explain arm on an
#     ACKNOWLEDGED self-hosted target spending the lookup's own Git ahead of
#     that comparison, each beside the twin that must not fire.
#   * section 4 no longer trusts even its own path arithmetic. lib/common.sh
#     fires the gate at source time only for bin/orchid, libexec/orchid-* and
#     runners/orchid-*, so a file outside those three arms the guard and is
#     left to fire it; the section answers "is this path covered" by RUNNING a
#     stub at that very path out of a root that really is stale, rather than
#     by keeping a copy of the case pattern that decides it.
#     It no longer trusts its own SUBJECT LIST either, which is the same
#     defect one level out. That list was six directory globs, and section 5's
#     was nine; both are now one WALK of the shipped tree -- Git's
#     tracked-plus-untracked set in a checkout, a filesystem walk in an
#     extracted archive, with tests/ and Markdown the two declared exclusions
#     -- so a loader under a directory nobody has thought of, or a top-level
#     harness with no `.sh` suffix, is inside the set that looks on the day it
#     lands rather than on the day somebody widens a glob. Both discoveries
#     are driven against a fixture that carries exactly those two shapes.
#   * section 2 also refuses a gate file whose recorded LABEL the shell
#     executes. A backtick inside a double-quoted label is a command
#     substitution, so the case is counted with the words that said what it
#     proved deleted from the record -- and the fixture that demonstrates it
#     is RUN, so the deletion is observed rather than asserted about a shell.
#
# RED: thirty-one, each fed to the SAME derivation or the same shipped verb the
#      section runs over the real tree. A ci-local-shaped file whose static
#      section sits BELOW the `--no-tests` cut (so it is outside the merge
#      floor and only reaches tasks that opted into the full suite), and a
#      second one that differs from it only by NAMING a test script in its
#      comments. An inv-shaped gate file that never loads tests/helpers.sh, so
#      its `red_case`/`green_case` calls satisfy a text linter and are
#      enforced by nothing at run time -- and two more whose source line a
#      text scan accepts and a shell never executes. A trust-boundary entry
#      point that arms the stale-root gate and reaches no site that fires it;
#      a harness OUTSIDE the three executable roots that loads the library and
#      fires nothing, which is what scripts/beta-qualify.sh and every bundled
#      engine adapter were; and one whose only firing site is a call that
#      fires nothing where that file lives. A stub under libexec/, refused the
#      moment it loaded the library out of a stale root, which is the
#      source-time fire that whole partition depends on being real.
#      A doctor-shaped trust boundary that fires the Git-spending stale-root
#      gate before it performs its machine-local trust decision -- with two
#      more beside it, one firing at the operator-PATH restore above its
#      decision (the second firing spelling, and the one libexec/orchid-status
#      is judged by) and one that never deferred at all, so its gate was spent
#      at source time ahead of every line it contains -- and a second
#      doctor-shaped fixture that is RUN and really does query its target
#      repository before rendering its denial. The shipped `orchid doctor`
#      itself, run where ORCHID_REPO and ORCHID_ROOT are one stale
#      unacknowledged checkout, which must refuse with nothing printed and
#      with the gate's own index comparison as the first Git of the run.
#      The shipped `orchid trust show` in that same self-hosted environment,
#      held to the same three things; a lookup-shaped fixture that is RUN and
#      really does query its target before rendering its verdict; and the
#      lookup with its stale-root gate moved back ABOVE the machine-local
#      trust decision, run against an ACKNOWLEDGED self-hosted target, which
#      must be seen to spend the gate's index comparison first.
#      The shipped `orchid trust revoke` on that same self-hosted target with
#      an acknowledgement on file, which must refuse having removed nothing,
#      reported nothing, and spent the gate's comparison first; and the same
#      revocation pointed at a target whose identity it cannot derive, whose
#      diagnosis of that target must not be produced out of a stale root.
#      The shipped PLAIN `orchid status` on that same self-hosted target --
#      the arm that looks no acknowledgement up at all, so its gate has
#      nothing to be ordered behind -- which must refuse with not one line of
#      its report printed and the gate's own comparison as the run's first
#      Git; and the explain arm's ordering with the gate moved back ABOVE the
#      lookup, run against an ACKNOWLEDGED self-hosted target, which must be
#      seen to spend that comparison first.
#      A loader under `tools/` and a top-level loader with no `.sh` suffix --
#      two paths no glob in this file names -- which the shipped-file walk
#      must reach and the gate derivation must then report.
#      An $ORCHID_ROOT genuinely parked on its configured integration branch
#      with a staged kernel edit, which must still be REFUSED -- the case that
#      must be caught. A gate written as a producer piped into `grep -q`. A
#      pump invoked out of that same stale root, which must refuse with no
#      runtime directory created, and the two scheduled runners' write-nothing
#      routes asked out of it, which must refuse with none of their four no-op
#      verdicts produced. A merge whose repo-wide gate exits non-zero,
#      which must leave the integration ref exactly where it was. An
#      `orchid trust unattended` out of that stale root, which must refuse
#      with its machine-local store still empty, and an `orchid trust show`
#      out of the same root, which must refuse with not one line of its
#      report produced, and an `orchid service status` out of that same root,
#      which must refuse with not one line of ITS report produced -- the other
#      verb that fires this gate itself, and the one whose call had to be moved
#      off its arms and above its dispatch. A file shaped like one of the
#      whole-file proofs tests/helpers.sh enrols BY NAME, probed at the depth
#      those ship at, whose helpers.sh source line a text scan accepts and a
#      shell never reaches. The shipped install.sh, RUN out of that same stale
#      root, which must refuse having wired nothing -- no orchid symlink at the
#      prefix, no per-user plugin directory -- since the only kernel check that
#      file ever carried is its closing doctor run, and that one is skipped in
#      exactly the self-hosted shape where its source checkout can be stale.
#      And a gate file whose recorded label carries
#      backticked prose the shell executes, which must be refused -- with the
#      fixture run first, so the words really are seen to go missing.
# GREEN: the twins, in this file: the shipped scripts/ci-local.sh, whose
#      static sections are all above the cut, and two late sections that
#      really do run a test script and must be left alone; the shipped
#      tests/inv/ gates AND the whole-file proofs helpers.sh enrols by name,
#      every one of them RUN at the depth it ships at and observed to reach
#      helpers.sh, beside two fixtures -- one at each depth -- whose only
#      difference from the refused ones is that the source line is reachable; every shipped file that
#      loads lib/common.sh -- picked out of a WALK of the shipped tree rather
#      than a list of directory families, with the top-level, scripts/ and
#      plugins/ families each additionally proved non-empty -- reaching a site
#      that really fires the gate at the path it ships at; the Markdown
#      document and the tests/ file carrying the identical source line, which
#      that walk must leave outside the inventory, by both of its discoveries,
#      each returning the identical set for the identical tree; the same stub libexec/
#      refuses, left to RUN under scripts/ and under plugins/, which is the
#      shadow the narrow universe could not see into; a deferring entry point
#      that does reach its restore where restoring fires, an ordinary verb that
#      defers nothing, an off-path harness that calls the gate itself, and a
#      file that names lib/common.sh without ever loading it, all four left
#      alone; the two gate-order fixtures with their pair of lines swapped --
#      one firing by the explicit call, one by the operator-PATH restore --
#      both judged clean, and an ordinary verb that crosses no trust boundary
#      passed over rather than judged; the shipped install.sh out of a root
#      that is NOT stale, which must wire the symlink and the per-user
#      directory whose absence the refusal above is measured by;
#      the case that must NOT fire -- an
#      ordinary checkout on a development branch, where the same construction
#      spends no `git` and refuses nothing, so section 3 is detection rather
#      than a check that fails on every checkout; the shipped kernel's many
#      pipes into a grep that reads to EOF, which must all be left alone; the
#      shipped doctor, whose trust decision precedes its stale-root gate in
#      the file and which, run out of that same stale self-hosted checkout
#      with the gate stood down and nothing else changed, renders its denial
#      having spent no Git at all -- beside a fixture that spends the
#      IDENTICAL query one line later and must be left alone; the shipped
#      lookup held to both of those in the same self-hosted environment, and
#      the same lookup against an ACKNOWLEDGED self-hosted target, where the
#      machine-local decision's own Git must be seen to precede the gate's
#      index comparison while the refusal and the suppressed report stay
#      exactly as they were; the same revocation with the gate stood down,
#      which must remove the record its refusal left standing and must be seen
#      to spend no Git at all, beside the underivable target whose diagnosis
#      the stood-down run must produce; the same PLAIN status with the gate
#      stood down, which must print the run_status line and the report body
#      whose absence its refusal is measured by, and `status --explain`
#      against an ACKNOWLEDGED self-hosted target, where the machine-local
#      decision's own Git must be seen to precede the gate's comparison while
#      the refusal and the suppressed report stay exactly as they were;
#      same pump against the same repo out of a root that is NOT stale, which
#      must run and must create the very directory the refusal above proved
#      absent; both scheduled runners' write-nothing routes out of that same
#      root, which must produce the four no-op verdicts whose absence the
#      refusals are measured by; the same task, the same tree and the same absent opt-in with a
#      GREEN gate, which must merge and advance the ref; the same
#      acknowledgement out of a root that is not stale, which must write the
#      record the refusal above proved absent; the same lookup out of that
#      same root, which must resolve that record and print the report whose
#      absence the refusal is measured by; the same `orchid service status`
#      out of that same root, which must print the report ITS refusal is
#      measured by; both verbs' usage arms out of the stale root, which must
#      be answered with their own usage text rather than a refusal, since the
#      one route this gate does not sit on has to be the same route in both
#      files; and the identical sentence
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
#
# AND THE ENROLLED SET IS WIDER THAN THE GLOB. tests/helpers.sh's
# `_proof_enrolled` says yes two ways: by LOCATION, for everything under
# tests/inv/, and by NAME, for the whole-file proofs it lists in
# PROOF_ENROLLED_FILES. Both halves carry this section's hazard unchanged -- a
# file enrolled either way whose recorders no EXIT trap watches is enrolled on
# paper and enforced nowhere -- and the by-name half carries it with less to
# fall back on: a gate under tests/inv/ at least has its own path saying what it
# is, while a top-level proof is enrolled by a list in a different file, and
# nothing about the file itself would notice the trap being sprung. So the list
# is READ from helpers.sh rather than restated here, and every entry is probed
# at the depth it really ships at.
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

# The RUN-TIME half. `enrolment_unproven <file> <relative-dest>` copies <file>
# into a probe tree whose `tests/helpers.sh` is a STUB, runs it, and reports
# unless the stub announced itself -- which happens only if the file's own
# source line was actually executed.
#
# Three things make it evidence rather than another text scan:
#
#   * The witness is the STUB's, not the file's. A gate under tests/inv/ loads
#     helpers as `source "$(dirname "$0")/../helpers.sh"` and a top-level proof
#     as `source "$(dirname "$0")/helpers.sh"`, so the copy has to be placed at
#     the depth the original ships at -- <relative-dest>, which the caller
#     derives from the file's own path rather than assuming a family. Placed
#     there, either spelling resolves to <probe>/tests/helpers.sh and to nothing
#     in the real tree. The stub is the first thing the gate executes that could
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

# ORCHID_HERMETIC_PROOF is unset for the run alongside ORCHID_REQUIRE_RED_CASE,
# and for a reason worth stating rather than leaving as a flag: this file is
# itself re-run inside the nested suite tests/test_hermetic_suite.sh launches,
# and in THAT environment the variable holds that file's own recursion-guard
# token -- so a copy of it that inherited the token would exit above its source
# line and be reported here for the environment it was probed in rather than for
# anything about the file. The question this probe asks is whether the ordinary
# path through a file reaches its enrolment, so it is asked with the ambient
# recursion guard cleared. Clearing it costs nothing: the stub exits before the
# copy's body can run, so nothing is re-launched either way, and the guard's own
# behaviour is tests/test_hermetic_suite.sh's RED case, not this one's.
enrolment_unproven() {
  local f="$1" dest="$2" probe out rc=0
  if [ ! -f "$f" ]; then
    printf 'no-such-file: %s\n' "$f"
    return 0
  fi
  # The stub is the only witness this probe has; a target whose own basename
  # would land on top of it would erase the evidence and then pass for lack of
  # it, which is this file's subject in miniature.
  case "${dest##*/}" in
    helpers.sh)
      printf 'probe-collision: %s would be copied over the probe stub itself, so its run could prove nothing\n' "$f"
      return 0 ;;
  esac
  probe="$ENROL_PROBE/$dest"
  mkdir -p "${probe%/*}"
  cp "$f" "$probe"
  out="$(env -u ORCHID_REQUIRE_RED_CASE -u ORCHID_HERMETIC_PROOF "$BASH" "$probe" 2>&1)" || rc=$?
  rm -f "$probe"
  case "$out" in
    *"$ENROL_MARK"*) return 0 ;;
  esac
  printf 'helpers-not-reached: %s (run with a stub tests/helpers.sh in its place, this file never got to its source line — rc=%s. Whatever the reason, its red_case/green_case calls are watched by no EXIT trap, so it is enrolled in the red-case rule on paper and enforced nowhere)\n' \
    "$f" "$rc"
}

ENROLLED_FILES=()
for inv_file in "$INV_GLOB_DIR"/test_*.sh; do
  [ -e "$inv_file" ] || continue
  ENROLLED_FILES+=("$inv_file")
done
inv_seen="${#ENROLLED_FILES[@]}"
# The by-name half, taken from helpers.sh's own array. A second copy of that
# list here would be one more thing to remember to extend, which is the shape
# this whole file exists to remove. Expanded under a count guard, because this
# file runs under `set -u`: an empty array expanded bare would kill the shell
# outright, and an emptied PROOF_ENROLLED_FILES is a finding this section has a
# message for below rather than a reason to exit with no summary at all.
if [ "${#PROOF_ENROLLED_FILES[@]}" -gt 0 ]; then
  for enrol_named in "${PROOF_ENROLLED_FILES[@]}"; do
    ENROLLED_FILES+=("$REPO_ROOT/$enrol_named")
  done
fi
top_seen=$(( ${#ENROLLED_FILES[@]} - inv_seen ))

# Both halves are proved non-empty BEFORE the set is walked, not after: an
# empty derivation is the vacuous pass this file exists to make impossible, and
# under `set -u` an empty array expanded bare would take the shell down before
# the report could be printed at all.
[ "$inv_seen" -ge 2 ] \
  || fail "INV-15: only $inv_seen file(s) matched tests/inv/test_*.sh — the invariant gates moved, and this scan is checking an empty set"
[ "$top_seen" -ge 1 ] \
  || fail "INV-15: tests/helpers.sh's PROOF_ENROLLED_FILES named nothing, so the by-name half of the enrolled set was probed vacuously — either the whole-file proofs stopped being enrolled that way, or this scan is reading an array that no longer holds them"

if [ "${#ENROLLED_FILES[@]}" -gt 0 ]; then
  for enrol_target in "${ENROLLED_FILES[@]}"; do
    enrol_rel="${enrol_target#"$REPO_ROOT/"}"
    case "$enrol_rel" in
      /*)
        fail "INV-15: the enrolled file $enrol_target is not under $REPO_ROOT, so the probe cannot place it at the depth its own helpers.sh source line resolves from — and a copy at the wrong depth would report every file it ran"
        continue ;;
    esac
    inv_out="$(helpers_missing "$enrol_target")"
    [ -z "$inv_out" ] || fail "INV-15: $inv_out"
    inv_out="$(enrolment_unproven "$enrol_target" "$enrol_rel")"
    [ -z "$inv_out" ] || fail "INV-15: $inv_out"
  done
fi
green_case "every one of the $inv_seen shipped tests/inv/ gates and all $top_seen whole-file proofs tests/helpers.sh enrols BY NAME were RUN, each at the depth it ships at, and observed to reach tests/helpers.sh — so the run-time RED/GREEN enforcement really is installed in all of them rather than merely written into them"

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
  assert_match 'helpers-not-reached' "$(enrolment_unproven "$enrol_file" "tests/inv/$enrol_unreached.sh")" \
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
enrol_ok_out="$(enrolment_unproven "$ENROL/tests/inv/test_INV-95_properly_enrolled.sh" "tests/inv/test_INV-95_properly_enrolled.sh")"
[ -z "$enrol_ok_out" ] \
  || fail "INV-15: a gate file that sources helpers.sh on its straight-line path was reported anyway ($enrol_ok_out) — a probe that refuses everything would flag the whole shipped set and prove nothing about the two above"
green_case "the same probe accepted a gate file whose source line differs from the refused one only in being reachable, so the refusals above are unreachability being detected rather than a probe that reports every file it runs"

# ---------------------------------------------------------------------------
# THE SAME PAIR AT THE TOP LEVEL, where the by-name half of the enrolled set
# lives.
#
# A whole-file proof ships one directory higher than a gate and resolves its
# enrolment by a different relative path, so the probe's placement arithmetic is
# a second thing that has to be right and a second thing nothing above would
# catch being wrong. Both directions of wrong are live. Place the copy too deep
# and its `$(dirname "$0")/helpers.sh` resolves to nothing: every top-level
# proof reports `helpers-not-reached` and the scan above fails the shipped tree
# for the probe's own arithmetic. Get the placement right but leave the probe
# unable to detect an unreachable source at that depth, and the by-name half is
# enrolled in this scan on paper and enforced nowhere -- which is, exactly, the
# trap this section is named for, sprung on the section itself.
#
# So both edges are pinned here (lesson L034): a top-level-shaped file whose
# source line a text scan accepts and a shell never reaches, which must be
# refused, and its twin differing only in reachability, which must not be.
ENROL_TOP_UNREACHED="$ENROL/tests/test_INV-94_top_level_unreachably_enrolled.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a top-level proof whose enrolment sits below an exit that always runs\n'
  printf '# GREEN: ...and whose accepting twin sits below it too\n'
  printf 'red_case() { :; }\n'
  printf 'green_case() { :; }\n'
  printf 'red_case "a case recorded above the source line, one directory up"\n'
  printf 'green_case "a twin recorded above the source line, one directory up"\n'
  printf 'exit 0\n'
  printf 'source "$(dirname "$0")/helpers.sh"\n'
} > "$ENROL_TOP_UNREACHED"
enrol_top_text_out="$(helpers_missing "$ENROL_TOP_UNREACHED")"
[ -z "$enrol_top_text_out" ] \
  || fail "INV-15: the text scan reported the top-level fixture ($enrol_top_text_out), so it no longer demonstrates a source line a grep accepts — the run-time probe below would then be proving a gap that has moved"
assert_match 'helpers-not-reached' \
  "$(enrolment_unproven "$ENROL_TOP_UNREACHED" "tests/test_INV-94_top_level_unreachably_enrolled.sh")" \
  "INV-15: a file shaped like one of the whole-file proofs helpers.sh enrols BY NAME, carrying a helpers.sh source line that is never executed, must be refused at ITS depth too — enrolment by a list in another file is the half with nothing about the file's own path to fall back on"
red_case "a top-level-shaped proof whose helpers.sh source line the text scan ACCEPTED, placed at the depth the by-name enrolled files really ship at, was refused once it was run — so the enrolment this scan derives from PROOF_ENROLLED_FILES is observed at that depth and not only at the gates' one"

{
  printf '#!/usr/bin/env bash\n'
  printf '# RED: a compliant top-level proof, for the probe to accept\n'
  printf '# GREEN: ...and its twin\n'
  printf 'source "$(dirname "$0")/helpers.sh"\n'
  printf 'red_case "a case a trap really is watching, one directory up"\n'
  printf 'green_case "a twin a trap really is watching, one directory up"\n'
} > "$ENROL/tests/test_INV-93_top_level_properly_enrolled.sh"
enrol_top_ok_out="$(enrolment_unproven "$ENROL/tests/test_INV-93_top_level_properly_enrolled.sh" "tests/test_INV-93_top_level_properly_enrolled.sh")"
[ -z "$enrol_top_ok_out" ] \
  || fail "INV-15: a top-level-shaped proof that sources helpers.sh on its straight-line path was reported anyway ($enrol_top_ok_out) — so the refusal above is the probe's placement arithmetic failing at this depth rather than unreachability being detected, and the shipped by-name files are being failed for the same reason"
green_case "the same probe accepted a top-level-shaped proof whose source line differs from the refused one only in being reachable, so the by-name half of the enrolled set is being probed by something that can tell the two apart at that depth"

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
# 4 -- EVERY FILE THAT LOADS THE LIBRARY REACHES THE GATE THAT LOAD ARMS.
#
# Section 3's guard is armed when lib/common.sh is sourced and fired at one of
# three places: immediately at source time, for a file with no authorization
# boundary to cross; at `_orchid_entry_restore_operator_path`, for a
# trust-boundary entry point, which is the line where such an entry point
# states its authorization decision is made; and at `orchid_root_stale_gate`,
# the explicit call. A file that reaches NONE of them arms the gate and never
# fires it -- a gate skipped by omission, in the guard this file exists to
# protect.
#
# AND THE FIRST TWO OF THOSE THREE ARE CONDITIONAL ON WHERE THE FILE LIVES,
# which is where the earlier version of this section shared the blind spot it
# was written to find. lib/common.sh fires at source time only when
# `_orchid_kernel_entry_point` says the program bash is executing is one of
# orchid's three executable roots -- bin/orchid, libexec/orchid-*,
# runners/orchid-* -- and `_orchid_entry_restore_operator_path` asks that same
# predicate before firing anything. So for a file OUTSIDE those three roots,
# neither is a firing site at all: the library arms the guard and leaves it
# armed. This section used to walk exactly bin/, libexec/ and runners/, which
# is to say it looked only where the gate cannot be missed. Two shipped files
# were in that shadow -- scripts/beta-qualify.sh, which produces the
# qualification evidence an operator decides a beta on and runs the target
# repository's own verify= command in place, and every bundled engine adapter,
# which executes $ORCHID_ROOT's own libraries and role profiles and is the
# literal stale-adapter shape lesson L018 records.
#
# So the universe below is every SHIPPED file that loads lib/common.sh
# wherever it lives -- install.sh, bin/, libexec/, runners/, scripts/ and the
# bundled plugins -- and the question "does the source-time fire cover this
# path" is answered by RUNNING lib/common.sh out of a root that really is
# stale, with a stub at that very path, rather than by restating
# _orchid_kernel_entry_point's case pattern here. A restatement drifts the
# moment somebody edits the original, and drifts SILENTLY in the forgiving
# direction: it would go on believing a path is covered after the coverage
# moved. The probe cannot: it asks this candidate's own library.
#
# WHAT THIS SECTION CANNOT SEE, said here rather than only in the not-tested
# claim at the end: "the file calls a firing site" is not "the file calls it
# before it does anything". runners/orchid-pump satisfied every line below
# while reaching its firing site only after `orchid_runtime` had created
# `.orchid/runtime` in the target repository. That ordering is not derivable
# from text -- a `orchid_runtime` line inside a function body precedes a call
# site that runs long after it, and no line-number comparison can tell the two
# apart -- so it is proven by execution instead, for the entry points it was
# wrong in: the pump in section 6, `orchid trust` in section 8, and the
# self-hosted `orchid doctor` in section 9.
# ===========================================================================

# EMPTY, and it did not start that way. `libexec/orchid-trust` was declared
# here with a reason -- that its entire body is the authorization decision, so
# there is no "after the decision, before the work" moment for the gate to
# occupy -- and the reason was wrong: the moment is between the operator's
# command and the durable write to the machine-local trust store, which is
# where that file now fires it. Section 8 executes exactly that ordering.
#
# It stayed empty through the widening below, and that is a claim rather than a
# convenience: scripts/beta-qualify.sh and the four bundled engine adapters
# were in the shadow the moment the universe grew to include them, and each now
# calls `orchid_root_stale_gate` itself rather than being written down here.
# The exemption that would have been easiest to declare -- "an adapter is
# launcher-only by INV-06, and its launcher already fired" -- is exactly the
# read-only-so-harmless reasoning `orchid trust show` carried and lost.
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

# entry_loads_common <code> -- does this comment-stripped body actually SOURCE
# lib/common.sh?
#
# The predicate is anchored on a `source`/`.` line and not on the mere
# appearance of the path, and the widened universe is why. install.sh names
# "$ROOT/lib/common.sh" in the two-anchor test that decides whether a directory
# IS an orchid tree, and did so for a long time without ever loading it -- so
# judged by "the file mentions the path" the installer was scannable as an entry
# point, findable to fire nothing, and reportable: a violation invented out of a
# file that armed nothing at all. It loads the library for real now, and fires
# the gate that load arms, so it is judged on that line rather than on those; a
# file whose only relationship to the library is a `-f` test on its path is
# still passed over, which is what the mentions-only fixture below pins.
entry_loads_common() {
  grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+[^#]*lib/common\.sh"' <<<"$1"
}

# ---------------------------------------------------------------------------
# THE INVENTORY BOTH FAMILY-SHAPED SCANS IN THIS FILE DRAW FROM, AND IT IS A
# WALK OF THE TREE RATHER THAN A LIST OF FAMILIES.
#
# It did not start as one. This section's universe was six globs -- `*.sh`,
# `bin/*`, `libexec/*`, `runners/*`, `scripts/*`, `plugins/*/*/*` -- and
# section 5's was nine. Each of those lists was written by looking at the
# directories that exist today, which is a hardcoded list wearing a
# derivation's clothes: the exact shape this file exists to refuse, one level
# up from the gates it judges. A loader that lands anywhere else -- a
# directory nobody thought of, a top-level harness with no `.sh` suffix, a
# plugin helper one level deeper than `plugins/*/*/*` reaches -- sources the
# library, arms the guard, fires nothing, and is outside the set that looks.
# The installer was that shape once already: the top level was the single
# literal path `$REPO_ROOT/install.sh` before it was a glob, and the glob is
# still blind to a sibling named without a suffix.
#
# scripts/ci-local.sh discovered the same thing about its own subject and says
# why in one line -- "names and shebangs, rather than directory allowlists" --
# so this is that discipline, applied to the one question a directory list can
# still get wrong here: not "is this file shell?" but "is this file SHIPPED?".
#
# TWO DISCOVERIES, for the reason ci-local.sh has two. In a checkout, Git's own
# tracked-plus-untracked set IS the shipped tree, and it has the property this
# scan needs most: a new entry point that has been written but not yet
# committed is already inside it, which is exactly the moment somebody wants to
# be told the gate is armed and never fired. An extracted release archive has
# no `.git` at all, and there the same question is answered by walking the
# filesystem. Which branch answered is published rather than assumed --
# `shipped_inventory_mode` -- and the fixture below drives BOTH, because a
# fallback nobody has watched work is a second implementation, not a safety
# net.
#
# TWO EXCLUSIONS AND TWO PRUNES, all four declared, because an exclusion
# nobody wrote down is indistinguishable from an omission:
#
#   tests/    the suite is not shipped kernel. Its files load lib/common.sh
#             for the helper functions and are run out of a developer's
#             checkout, so judging them by "orchid is running out of a stale
#             installation" would refuse the suite itself. The gate files
#             under tests/inv/ are enrolled on their own terms -- by section
#             2's glob, and by section 5's second loop below.
#   *.md      a document is not executed. docs/plans/ quotes
#             `source "$ORCHID_ROOT/lib/common.sh"` inside fenced examples a
#             dozen times, and a walk that judged those would report a
#             violation invented out of prose -- the mirror image of the
#             mentions-only defect entry_loads_common was narrowed for.
#   .git/     not shipped, and enormous.
#   .orchid/  run state, not code, and this suite may not read it at all.
#
# Everything else in the tree is in, whatever family it lands in and whether
# or not that family existed when this was written.

# shipped_inventory_mode <root> -- which discovery answers for <root>: `git`
# when <root> is itself the top level of a checkout, `find` anywhere else,
# `unreadable` when <root> cannot even be entered. The physical path is taken
# on both sides of the comparison: macOS hands out /var/folders symlinks for
# /private/var/folders, and Git answers with the resolved path, so comparing
# the two as given would send every scratch fixture down the `find` branch
# while looking like it had chosen it.
shipped_inventory_mode() {
  local root top
  root="$(cd "$1" 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { printf 'unreadable'; return 0; }
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
  # Resolved on BOTH sides rather than compared as printed: which spelling Git
  # answers with is Git's business, and a comparison that a symlinked TMPDIR
  # could decide would send every scratch fixture down the other branch while
  # looking like it had chosen one.
  [ -z "$top" ] || top="$(cd "$top" 2>/dev/null && pwd -P)" || top=""
  if [ -n "$top" ] && [ "$top" = "$root" ]; then printf 'git'; else printf 'find'; fi
}

# shipped_inventory_admits <root> <relpath> -- the exclusions and prunes
# above, in ONE place, so the two discoveries cannot come to disagree about
# what "shipped" means.
shipped_inventory_admits() {
  case "$2" in
    .git|.git/*|.orchid|.orchid/*|tests|tests/*) return 1 ;;
    *.md) return 1 ;;
  esac
  [ -f "$1/$2" ] || return 1
  return 0
}

# shipped_inventory <root> -- every shipped file under <root>, repo-relative,
# one per line, in LC_ALL=C order. Takes its root as an argument rather than
# reading $REPO_ROOT, so the fixture below is judged by the same function the
# shipped tree is.
shipped_inventory() {
  local root rel
  root="$(cd "$1" 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || return 0
  {
    if [ "$(shipped_inventory_mode "$root")" = git ]; then
      while IFS= read -r rel; do
        if shipped_inventory_admits "$root" "$rel"; then printf '%s\n' "$rel"; fi
      done < <(git -C "$root" ls-files --cached --others --exclude-standard)
    else
      while IFS= read -r rel; do
        rel="${rel#./}"
        if shipped_inventory_admits "$root" "$rel"; then printf '%s\n' "$rel"; fi
      done < <(cd "$root" && find . \( -path './.git' -o -path './.orchid' \) -prune -o -type f -print)
    fi
  } | LC_ALL=C sort
}

# shipped_inventory_line <root> -- the same inventory as one space-separated
# line, for an assertion that compares a whole set in both directions rather
# than testing two memberships and calling the rest unexamined.
shipped_inventory_line() {
  local rel out=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    out="$out $rel"
  done < <(shipped_inventory "$1")
  printf '%s' "${out# }"
}

# THE ROOT THE SOURCE-TIME PROBE ASKS ITS QUESTION IN.
#
# Its own, not section 3's: section 3 mutates INTEG_ROOT to make its point, and
# this probe writes a stub at every path in the shipped universe, so sharing
# one root would leave each section's fixture standing in the other's evidence.
# Same builder, same constructed condition -- parked on its configured
# integration branch with a kernel path staged -- because that is the only
# condition in which the source-time fire is observable at all.
ENTRY_PROBE_ROOT="$WORK/entry-universe-root"
make_probe_root "$ENTRY_PROBE_ROOT" "$PROBE_INTEG"
printf '\n# staged kernel edit\n' >> "$ENTRY_PROBE_ROOT/libexec/orchid-version"
git -C "$ENTRY_PROBE_ROOT" add libexec/orchid-version
[ -n "$(git -C "$ENTRY_PROBE_ROOT" diff --cached --name-only HEAD -- libexec)" ] \
  || fail "INV-15: the entry-universe probe root carries no staged kernel edit, so it is not stale — every probe below would answer 'this path is not covered' for the wrong reason, and the whole partition would be built on it"

# entry_source_time_answer <relpath> -- one of three words:
#
#   fires        lib/common.sh's SOURCE-TIME fire covers a file at <relpath>
#   armed        it does not: the guard is armed and left for the file to fire
#   unanswerable neither outcome was observed, so this probe has no answer
#
# Answered by RUNNING a stub at that exact path out of the stale root above,
# so the answer comes from this candidate's own lib/common.sh rather than from
# a copy of its case pattern kept in a test file. The third word exists
# because folding an unrecognised outcome into either of the other two would
# let a broken probe decide a violation silently -- the shape this whole file
# is about. Its caller reports it rather than guessing.
entry_source_time_answer() {
  local rel="$1" stub="$ENTRY_PROBE_ROOT/$1" out
  mkdir -p "${stub%/*}"
  cat > "$stub" <<'ENTRYSTUB'
#!/usr/bin/env bash
set -uo pipefail
source "$ORCHID_ROOT/lib/common.sh"
echo "INV15-ENTRY-STUB-REACHED"
ENTRYSTUB
  # The status is deliberately not read: what distinguishes the two outcomes is
  # WHICH of them was printed, and a stub that died some third way must reach
  # the unanswerable arm rather than be sorted by an exit code that both a
  # refusal and an unrelated failure can produce.
  out="$(HOME="$MACHINE_HOME" ORCHID_ALLOW_STALE_ROOT='' ORCHID_ROOT="$ENTRY_PROBE_ROOT" \
    /bin/bash "$stub" 2>&1)"
  case "$out" in
    *INV15-ENTRY-STUB-REACHED*) printf 'armed'; return 0 ;;
    *'refusing to run: the checkout orchid itself runs from'*) printf 'fires'; return 0 ;;
  esac
  printf 'unanswerable'
}

# entry_gate_violations <file> <relpath> -- non-empty when <file> loads
# lib/common.sh and nothing on its own text fires the gate that load arms, at
# the path <relpath> puts it. Pure apart from the probe, so the fixtures below
# are judged by the same function the shipped tree is.
#
# <relpath> is a separate argument rather than derived from <file> so a fixture
# living in a scratch directory can be asked "and if you shipped HERE?" -- the
# same body is a violation under scripts/ and no violation at all under
# libexec/, and a check that could not put the same file in both places could
# not demonstrate that the location is what decides it.
entry_gate_violations() {
  local f="$1" rel="$2" code defers=0 covered
  [ -f "$f" ] || { printf 'no-such-file: %s\n' "$rel"; return 0; }
  code="$(entry_code "$f")"
  entry_loads_common "$code" || return 0
  grep -q '__orchid_entry_defer_restore=1' <<<"$code" && defers=1
  # The explicit call fires whatever is armed from wherever it sits, so it
  # settles the question for every path and is asked first.
  grep -q 'orchid_root_stale_gate' <<<"$code" && return 0
  covered="$(entry_source_time_answer "$rel")"
  case "$covered" in
    unanswerable)
      printf 'entry-probe-unanswerable: %s (a stub at this path, run out of a root that really is stale, neither refused nor reported itself reached — this probe cannot say whether the source-time fire covers this path, and an unanswerable probe must not be read as either answer)\n' "$rel"
      return 0 ;;
  esac
  if [ "$defers" = 0 ]; then
    [ "$covered" = fires ] && return 0
    printf 'gate-armed-never-fired-off-path: %s (it loads lib/common.sh without deferring the operator-PATH restore, but it does not live under one of the three executable roots lib/common.sh fires the gate at source time for — a stub at this very path was run out of a genuinely stale root and was NOT refused — and it never calls orchid_root_stale_gate, so the gate is armed and never fires)\n' "$rel"
    return 0
  fi
  if grep -q '_orchid_entry_restore_operator_path' <<<"$code"; then
    [ "$covered" = fires ] && return 0
    # _orchid_entry_restore_operator_path asks _orchid_kernel_entry_point
    # before it fires anything, so off that path it restores the PATH and
    # fires nothing. Saying so is the difference between a scan that reads a
    # call and one that knows what the call does.
    printf 'gate-fires-only-through-the-path-restore-off-path: %s (it defers the operator-PATH restore and reaches the gate only through _orchid_entry_restore_operator_path, which fires nothing for a file outside the three executable roots — a stub at this very path was run out of a genuinely stale root and was NOT refused — so this file must call orchid_root_stale_gate)\n' "$rel"
    return 0
  fi
  printf 'gate-armed-never-fired: %s (it defers the operator-PATH restore, so lib/common.sh arms the stale-root gate and leaves the firing to this file — and this file CALLS neither _orchid_entry_restore_operator_path nor orchid_root_stale_gate, so the gate is armed and never fires)\n' "$rel"
}

# THE UNIVERSE: every file in the shipped inventory above that actually loads
# the library, wherever it lives. The FAMILIES are whatever the walk finds --
# they are counted and named below rather than written down, so a loader under
# a directory invented tomorrow is inside the set that looks on the day it
# lands rather than on the day somebody remembers to widen a glob.
#
# The three families named on their own account further down are not a list
# this loop reads; they are three MINIMA asserted against what it discovered,
# each because a family going quiet is the failure that looks exactly like a
# clean scan.
entry_scanned=0
entry_deferring=0
entry_toplevel=0
entry_scripts=0
entry_plugins=0
entry_inventory_seen=0
entry_family_lines=""
entry_unfired=""
# The same universe, kept as repo-relative names so the gate-ORDER derivation
# below reads exactly the set this loop discovered rather than re-deriving one
# that could drift from it.
ENTRY_UNIVERSE=()
while IFS= read -r entry_rel; do
  [ -n "$entry_rel" ] || continue
  entry_file="$REPO_ROOT/$entry_rel"
  entry_inventory_seen=$((entry_inventory_seen + 1))
  # The family, DERIVED from the path rather than matched against a list: the
  # first component, or the top level for a file that has none. Accumulated
  # one per line and de-duplicated with sort -u below, never with a padded
  # membership test -- `*" $x "*` answers yes for two ADJACENT members, and a
  # count that quietly merged two families would be a smaller number reported
  # as coverage.
  case "$entry_rel" in
    */*) entry_family_lines="$entry_family_lines${entry_rel%%/*}"$'\n' ;;
    *)   entry_family_lines="${entry_family_lines}(top level)"$'\n' ;;
  esac
  entry_file_code="$(entry_code "$entry_file")"
  entry_loads_common "$entry_file_code" || continue
  entry_scanned=$((entry_scanned + 1))
  ENTRY_UNIVERSE+=("$entry_rel")
  if grep -q '__orchid_entry_defer_restore=1' <<<"$entry_file_code"; then
    entry_deferring=$((entry_deferring + 1))
  fi
  case "$entry_rel" in
    scripts/*) entry_scripts=$((entry_scripts + 1)) ;;
    plugins/*) entry_plugins=$((entry_plugins + 1)) ;;
    */*) ;;
    *) entry_toplevel=$((entry_toplevel + 1)) ;;
  esac
  entry_out="$(entry_gate_violations "$entry_file" "$entry_rel")"
  [ -n "$entry_out" ] || continue
  entry_unfired="$entry_unfired $entry_rel"
done < <(shipped_inventory "$REPO_ROOT")

entry_family_count=0
entry_family_names=""
while IFS= read -r entry_family; do
  [ -n "$entry_family" ] || continue
  entry_family_count=$((entry_family_count + 1))
  entry_family_names="$entry_family_names $entry_family"
done < <(printf '%s' "$entry_family_lines" | LC_ALL=C sort -u)
entry_family_names="${entry_family_names# }"
entry_inventory_mode="$(shipped_inventory_mode "$REPO_ROOT")"

# THE DENOMINATOR OF THE WALK ITSELF, asserted before anything is concluded
# from it. A discovery that had stopped reaching the tree would report an
# empty universe, no violations, and a green case -- which is this file's
# subject with this file as the subject.
[ "$entry_inventory_mode" != unreadable ] \
  || fail "INV-15: neither shipped-file discovery could answer for this checkout, so the universe below was drawn from nothing"
[ "$entry_inventory_seen" -ge 40 ] \
  || fail "INV-15: the shipped-file walk reached only $entry_inventory_seen file(s) (by the $entry_inventory_mode discovery). This repository ships many more, so the universe below is being drawn from a walk that has stopped reaching the tree"
# The families are a COUNT rather than a list for the reason the walk replaced
# the globs: naming the ones that exist today is how the next directory gets
# missed. What is asserted is that the walk still spans a tree-shaped number of
# them -- a discovery collapsed onto one directory reads, in a log, exactly
# like the six globs it replaced.
[ "$entry_family_count" -ge 8 ] \
  || fail "INV-15: the shipped-file walk spans only $entry_family_count top-level family/families ($entry_family_names). This repository has many more, so the walk is looking at a slice of the tree while reporting on all of it"
[ "$entry_scanned" -ge 10 ] \
  || fail "INV-15: only $entry_scanned file(s) that load lib/common.sh were discovered — the executable roots moved, and this scan is judging an almost empty set"
[ "$entry_deferring" -ge 3 ] \
  || fail "INV-15: only $entry_deferring trust-boundary entry point(s) discovered; the shipped set is larger, so the partition below is not reading what it claims to"
# The two families the narrow universe used to miss, each required to be
# non-empty on its own account. Without these the widening is a glob nobody
# would notice going quiet: a scripts/ or plugins/ directory that stopped
# matching would leave the derivation passing over the exact shadow it was
# widened to light up.
[ "$entry_scripts" -ge 1 ] \
  || fail "INV-15: the entry universe reached no file under scripts/ that loads lib/common.sh. That is the shadow this section was widened for — a harness outside the three executable roots arms the gate and is left to fire it — so a scan that no longer sees scripts/ has quietly gone back to looking only where the gate cannot be missed"
[ "$entry_plugins" -ge 1 ] \
  || fail "INV-15: the entry universe reached no file under plugins/ that loads lib/common.sh. A bundled engine adapter executes \$ORCHID_ROOT's own libraries and role profiles out of the installation root, which is the stale-adapter shape lesson L018 records, so this family may not fall out of the derivation silently"
# The top level, on its own account for the same reason the other two are. This
# family holds exactly one member today, install.sh, and it is the member whose
# absence would be hardest to see: the installer wires the operator's own
# `orchid` into whatever checkout it was run from, and the only kernel check it
# ever performed -- the post-install doctor run -- is skipped precisely when cwd
# IS that checkout, which is the one case its root can be the stale integration
# tree at all. A derivation that stopped reaching the top level would report
# nothing and mean nothing.
[ "$entry_toplevel" -ge 1 ] \
  || fail "INV-15: the entry universe reached no top-level file that loads lib/common.sh. install.sh is that file: it symlinks the operator's orchid, the front-end skill bundles and ~/.orchid out of \$ROOT, so out of a stale checkout it wires the pre-merge tree in as the installed orchid. A top-level family that has gone quiet means this scan is judging the installer by nothing"

entry_unfired="${entry_unfired# }"
assert_eq "$GATE_EXEMPT" "$entry_unfired" \
  "INV-15: the set of shipped files that arm the stale-root gate and never fire it must be exactly the declared one — a new member means code that runs pre-merge kernel with nothing left to say so, and a departed member means this exemption is stale"

green_case "all $entry_scanned shipped files that load lib/common.sh reach a site that really does fire the gate they arm, at the path each ships at, with no exemption left standing — and they were picked out of an inventory of $entry_inventory_seen shipped files spanning $entry_family_count top-level families ($entry_family_names), DISCOVERED by walking this tree with the $entry_inventory_mode discovery rather than by naming the directories that exist today, with the top-level, scripts/ and plugins/ families each additionally proved non-empty"

# THE WALK'S OWN BOTH EDGES (lesson L034: pin the case that must be caught and
# the case that must not fire). Everything above rests on two properties of the
# inventory that the shipped tree cannot demonstrate, because the shipped tree
# is exactly the set that passes: that the walk reaches where no glob in this
# file points, and that it stops at the two declared exclusions rather than
# stopping nowhere. Both are asked of a fixture, through the same functions.
ENTRY_INV_FIX="$WORK/inventory-fixture"
mkdir -p "$ENTRY_INV_FIX/tools" "$ENTRY_INV_FIX/docs" "$ENTRY_INV_FIX/tests"
# The two shapes the six globs could not see, each a real loader: a family
# nobody named, and a top-level harness with no .sh suffix.
for entry_inv_stub in tools/orchid-helper bootstrap; do
  { printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
    printf 'echo INV15-INVENTORY-STUB\n'
  } > "$ENTRY_INV_FIX/$entry_inv_stub"
done
# The two exclusions, carrying the IDENTICAL source line, so a walk that
# admitted everything fails here instead of passing as thoroughness.
printf 'A fenced example:\n\n    source "$ORCHID_ROOT/lib/common.sh"\n' \
  > "$ENTRY_INV_FIX/docs/note.md"
printf 'source "$REPO_ROOT/lib/common.sh"\n' > "$ENTRY_INV_FIX/tests/test_probe.sh"
ENTRY_INV_EXPECT="bootstrap tools/orchid-helper"

# The CHECKOUT discovery first, since that is the one this repository is judged
# by. Asserted to have been the branch that answered, because a fixture that
# silently fell through to the other one would be proving the same code twice.
git init -q "$ENTRY_INV_FIX"
assert_eq git "$(shipped_inventory_mode "$ENTRY_INV_FIX")" \
  "INV-15: the fixture is a checkout whose top level it IS, so the tracked-plus-untracked discovery must be the one that answers for it — otherwise the branch this repository is actually judged by is not the branch exercised here"
assert_eq "$ENTRY_INV_EXPECT" "$(shipped_inventory_line "$ENTRY_INV_FIX")" \
  "INV-15: the shipped-file walk must reach a loader under tools/ — a family no glob in this file names — and a top-level harness with no .sh suffix, and must reach NEITHER the Markdown document nor the tests/ file that carry the identical source line. Both halves are the claim: the first is the omission this section exists to end, the second is the pair of declared exclusions doing the work they are declared for"

# The two paths the old universe could not see, put through the JUDGEMENT and
# not merely through the inventory: being discovered is worth nothing if the
# derivation then has nothing to say about them.
for entry_inv_stub in tools/orchid-helper bootstrap; do
  assert_match "gate-armed-never-fired-off-path: $entry_inv_stub" \
    "$(entry_gate_violations "$ENTRY_INV_FIX/$entry_inv_stub" "$entry_inv_stub")" \
    "INV-15: a file at $entry_inv_stub that loads lib/common.sh and fires nothing must be REPORTED, with a stub at that very path run out of a genuinely stale root to establish that the source-time fire does not cover it"
done
red_case "a loader under tools/ and a top-level loader with no .sh suffix — two paths no glob in this file names, both outside the six the universe used to be written as — were discovered by the shipped-file walk and then reported by the same derivation the shipped tree is judged by, each with the source-time probe run at its own path"

# The ARCHIVE discovery, on the identical tree with its .git removed: the
# release rehearsal runs the suite out of an extracted tarball, where there is
# no Git to ask, and a fallback that answers differently from the branch it
# stands in for is a second scan nobody has read.
rm -rf "$ENTRY_INV_FIX/.git"
assert_eq find "$(shipped_inventory_mode "$ENTRY_INV_FIX")" \
  "INV-15: with no .git present the filesystem walk must be the discovery that answers, or the archive case is being judged by a branch that cannot run there"
assert_eq "$ENTRY_INV_EXPECT" "$(shipped_inventory_line "$ENTRY_INV_FIX")" \
  "INV-15: the filesystem walk must return exactly what the checkout discovery returned for the identical tree — the same two loaders, and the same two exclusions honoured — or 'shipped' means one thing in a checkout and another in a release archive"
green_case "the Markdown document and the tests/ file carrying the identical source line were left outside the inventory by both discoveries, and both discoveries returned the identical set for the identical tree — so the walk is bounded by the two exclusions this file declares rather than by nothing, and the archive fallback is not a second answer nobody has watched"

# The blind spot itself, made observable, because everything above depends on
# it being real: the SAME library, the SAME stale root, three paths, and the
# answer changes with the directory. Without this pair the widening is an
# assertion about lib/common.sh rather than an observation of it.
assert_eq fires "$(entry_source_time_answer libexec/orchid-inv15-probe)" \
  "INV-15: a stub under libexec/ must be refused at source time out of a stale root — that is the coverage the three executable roots have, and if it is absent the partition above is judging every file by a fire that never happens"
red_case "a stub under libexec/ was refused the moment it loaded lib/common.sh out of a genuinely stale root, so the source-time fire this section partitions on is real and observed rather than assumed"

for entry_shadow in scripts/inv15-probe.sh plugins/engines/inv15-probe/run; do
  assert_eq armed "$(entry_source_time_answer "$entry_shadow")" \
    "INV-15: a stub at $entry_shadow, loading the identical library out of the identical stale root, must NOT be refused — if it were, there would be no shadow here, and the explicit orchid_root_stale_gate calls this section requires of scripts/ and plugins/ would be guarding nothing"
done
green_case "the identical stub, loading the identical lib/common.sh out of the identical stale root, was left to run under scripts/ and under plugins/ while being refused under libexec/ — so the source-time fire really is conditional on the directory, and a derivation that walked only the three executable roots really would share the implementation blind spot it exists to find"

# THE ORDER OF THE TWO PRE-REPORT GATES, DERIVED RATHER THAN LISTED.
#
# Doctor was the first deferring entry point found to have TWO of them, and it
# was never the only one. When Orchid operates on itself -- ORCHID_ROOT and the
# target one directory, which is how orchid is developed and how it drives its
# own repository -- the stale-root gate's Git query lands on the very repository
# whose machine-local acknowledgement has not been looked up yet, and that is
# the query the unattended-trust contract forbids before an acknowledgement is
# found. Point an installed orchid at some other checkout and the two are
# different directories, the ordering costs nothing to get wrong, and every
# ordinary invocation is in that case: lesson L036's shape exactly.
#
# WHAT CHANGED HERE IS THIS FILE'S OWN SUBJECT, ONE LEVEL UP. The set used to be
# three names written into an array -- doctor and the two scheduled runners --
# and a hardcoded list is the thing this invariant exists to refuse. Two shipped
# entry points were already outside it (libexec/orchid-status, which makes the
# decision for its --explain arm, and runners/orchid-service, which crosses the
# unattended boundary for its install arm), and an entry point growing its first
# trust decision tomorrow would have been held to nothing while the list went on
# passing. The candidates are derived from the entry universe above instead: a
# file is judged the moment it carries both a machine-local trust DECISION and a
# site that fires the stale-root gate.
#
# TWO FIRING SPELLINGS, because there are two firing sites, and reading only one
# is how a file gets judged by a call it does not make. An entry point that
# holds the fixed entry PATH for its whole run calls orchid_root_stale_gate; a
# deferring entry point under the three executable roots fires at
# _orchid_entry_restore_operator_path, which is where lib/common.sh puts the
# gate for it. libexec/orchid-status fires by the second spelling alone, and a
# matcher that knew only the first would have called it unprovable and moved on.
#
# AND A DECISION WITH NO FIRING SITE AT ALL IS THE WORST CASE, not a file to
# pass over: a file that does not defer has already spent the gate's Git at
# source time, while the library was still loading, which is ahead of every line
# it contains and so ahead of any lookup it makes.
#
# AND WHAT THIS SCAN CANNOT SAY, which is why section 9 now runs `orchid
# status` as well as doctor and the three `trust` arms. It reads a file as one
# straight line, so it answers for the ARM whose two calls it happens to find
# first and reports that answer for the file. libexec/orchid-status is the case
# where those are not the same thing: its lookup runs only under `--explain`,
# while PLAIN status reaches the identical firing site having decided nothing,
# so "the decision is above the fire" is true of the file and true of one arm
# only. This scan is kept because it is cheap, it covers the files those
# sections do not re-run, and it fails the moment somebody moves a line -- but
# for status and for the trust arms the claim that carries weight is the one
# read off a run.
gate_order_violations() {
  local f="$1" rel="$2" code decide_line fire_line
  code="$(entry_code "$f")"
  decide_line="$(awk '/^[[:space:]]*unattended_trust_(inspect|require|revoke_resolve)[[:space:]]/ { print NR; exit }' <<<"$code")"
  # Not a candidate: no machine-local trust decision, so there is no
  # acknowledgement lookup for a gate to land in front of.
  if [ -z "$decide_line" ]; then printf 'skip\n'; return 0; fi
  fire_line="$(awk '/^[[:space:]]*(orchid_root_stale_gate|_orchid_entry_restore_operator_path)[[:space:]]*$/ { print NR; exit }' <<<"$code")"
  if [ -z "$fire_line" ]; then
    if grep -q '__orchid_entry_defer_restore=1' <<<"$code"; then
      printf 'gate-order-unprovable: %s (it makes a machine-local trust decision and defers the source-time fire, but names neither firing site, so nothing here can say where its gate lands — section 4 above reports the arming half of the same file)\n' "$rel"
    else
      printf 'gate-order-source-time-before-decision: %s (it makes a machine-local trust decision and does NOT defer the source-time fire, so lib/common.sh spends the gate against ORCHID_ROOT while the library is still loading — ahead of every line of this file, and so ahead of the acknowledgement lookup on line %s)\n' "$rel" "$decide_line"
    fi
    return 0
  fi
  case "$decide_line:$fire_line" in
    *[!0-9:]*) printf 'gate-order-unprovable: %s (line numbers did not come back numeric)\n' "$rel"; return 0 ;;
  esac
  if [ "$fire_line" -le "$decide_line" ]; then
    printf 'gate-order-stale-before-trust: %s (stale line %s, trust line %s)\n' \
      "$rel" "$fire_line" "$decide_line"
    return 0
  fi
  printf 'ok\n'
}

# THE ONE DECLARED EXEMPTION, and it is declared rather than special-cased for
# the reason GATE_EXEMPT above is: an exemption that is written down is one the
# next reader can argue with, and the comparison below is exact in BOTH
# directions, so a file joining this set fails and a member that stops needing
# it fails too.
#
# libexec/orchid-trust dispatches per subcommand, and this derivation reads a
# file as one straight line. Its FIRST fire belongs to the `unattended` arm --
# the operator authoring an acknowledgement, which is the one path licensed to
# spend verification on the target, because there is no lookup being pre-empted
# when this run is what puts a record on file. The two arms that do look one up
# order themselves correctly and neither is visible to a first-match scan:
# `show` inspects before it fires, `revoke` resolves the record it would unlink
# before it fires. Both are proved by RUNNING them, against the self-hosted
# target, in section 9 -- which is the evidence this exemption rests on and the
# reason it costs nothing.
GATE_ORDER_EXEMPT="libexec/orchid-trust"
gate_order_candidates=0
gate_order_reported=""
gate_order_detail=""
# The `+` guard is not decoration: this suite runs under `set -u`, and expanding
# an EMPTY array with "${a[@]}" aborts the whole file on the Bash 3.2 that ships
# as /bin/bash on macOS. An empty universe is already reported by the counters
# above; it must not also silence every section below it.
for gate_order_rel in ${ENTRY_UNIVERSE[@]+"${ENTRY_UNIVERSE[@]}"}; do
  gate_order_out="$(gate_order_violations "$REPO_ROOT/$gate_order_rel" "$gate_order_rel")"
  [ "$gate_order_out" != skip ] || continue
  gate_order_candidates=$((gate_order_candidates + 1))
  [ "$gate_order_out" != ok ] || continue
  gate_order_reported="$gate_order_reported $gate_order_rel"
  gate_order_detail="$gate_order_detail$gate_order_out"
done
gate_order_reported="${gate_order_reported# }"
[ "$gate_order_candidates" -ge 5 ] \
  || fail "INV-15: only $gate_order_candidates shipped entry point(s) were found to carry both a machine-local trust decision and a stale-root firing site. The shipped set is larger than that, so this derivation has stopped reading what it claims to and the ordering below is being proved about almost nothing"
assert_eq "$GATE_ORDER_EXEMPT" "$gate_order_reported" \
  "INV-15: the set of shipped entry points whose stale-root fire is not provably behind their machine-local trust decision must be exactly the declared one — a new member spends the gate's Git on an unacknowledged target in the self-hosted case, and a departed member means this exemption is stale ($gate_order_detail)"
green_case "all $gate_order_candidates shipped entry points that carry both a machine-local unattended-trust decision and a stale-root firing site were DERIVED from the entry universe rather than listed — doctor, status, trust and all three runners, by either firing spelling — and in every one but the single declared exemption the decision is written above the fire, with both still above the file's first report; what that ordering means arm by arm, where a file's lookup runs on one arm only, is answered by running it in section 9 rather than here"

GATE_ORDER_BAD="$WORK/orchid-doctor-stale-first"
{
  printf '#!/bin/bash -p\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="$PWD"\n'
  printf 'orchid_root_stale_gate\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'unattended_trust_summary_loaded\n'
} > "$GATE_ORDER_BAD"
assert_match 'gate-order-stale-before-trust' \
  "$(gate_order_violations "$GATE_ORDER_BAD" libexec/orchid-inv15-order-bad)" \
  "INV-15: a doctor-shaped entry point that queries stale-root Git before its trust decision must be reported"
red_case 'the gate-order derivation rejected a fixture whose stale-root Git query precedes its machine-local trust decision, so the shipped ordering is proved rather than merely described'

# The SECOND firing spelling, both edges. Without these the widening above is a
# regex nobody has watched work: a matcher that ignored the PATH restore would
# call libexec/orchid-status unprovable, and one that reported every file it
# recognised would report it too.
GATE_ORDER_RESTORE_BAD="$WORK/orchid-status-restore-first"
{
  printf '#!/bin/bash -p\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'repo="$PWD"\n'
  printf '_orchid_entry_restore_operator_path\n'
  printf 'unattended_trust_inspect "$repo"\n'
} > "$GATE_ORDER_RESTORE_BAD"
assert_match 'gate-order-stale-before-trust' \
  "$(gate_order_violations "$GATE_ORDER_RESTORE_BAD" libexec/orchid-inv15-restore-bad)" \
  "INV-15: a deferring entry point that fires the gate at its operator-PATH restore ABOVE its trust decision must be reported — that is the second firing spelling, and it is the one libexec/orchid-status is judged by"

# The source-time shape: a decision, and no firing site at all because the file
# never deferred. Its gate is already spent before line one.
GATE_ORDER_SOURCE_TIME="$WORK/orchid-inv15-source-time"
{
  printf '#!/bin/bash -p\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'repo="$PWD"\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'unattended_trust_summary_loaded\n'
} > "$GATE_ORDER_SOURCE_TIME"
assert_match 'gate-order-source-time-before-decision' \
  "$(gate_order_violations "$GATE_ORDER_SOURCE_TIME" libexec/orchid-inv15-source-time)" \
  "INV-15: an entry point that makes a trust decision without deferring the source-time fire must be reported — lib/common.sh spent the gate while it was loading, which is ahead of every line the file contains"
red_case "the same derivation reported a fixture firing at the operator-PATH restore above its trust decision, and a second fixture whose gate was spent at source time because it never deferred — so both of the ways this ordering can be wrong are detected, not just the explicit call"

# The three that must come back clean, and they are the same bodies as the two
# refused fixtures above with the pair of lines swapped -- plus the ordinary
# verb, which must be passed over rather than judged, since a file with no trust
# decision has no acknowledgement lookup for a gate to precede.
{
  printf '#!/bin/bash -p\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="$PWD"\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'orchid_root_stale_gate\n'
  printf 'unattended_trust_summary_loaded\n'
} > "$WORK/orchid-inv15-order-good"
{
  printf '#!/bin/bash -p\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'repo="$PWD"\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf '_orchid_entry_restore_operator_path\n'
} > "$WORK/orchid-inv15-restore-good"
{
  printf '#!/bin/bash -p\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'echo "an ordinary verb: it crosses no trust boundary"\n'
} > "$WORK/orchid-inv15-no-decision"

while IFS=: read -r gate_ok_file gate_ok_want; do
  [ -n "$gate_ok_file" ] || continue
  gate_ok_out="$(gate_order_violations "$WORK/$gate_ok_file" "libexec/$gate_ok_file")"
  assert_eq "$gate_ok_want" "$gate_ok_out" \
    "INV-15: the $gate_ok_file fixture must be judged '$gate_ok_want' — a derivation that reports every file carrying these two calls, or that passes over a file it should judge, proves nothing about the shipped set"
done <<'GATEORDEROK'
orchid-inv15-order-good:ok
orchid-inv15-restore-good:ok
orchid-inv15-no-decision:skip
GATEORDEROK
green_case 'the identical fixtures with the two calls in the other order -- one by the explicit gate call, one by the operator-PATH restore -- were both judged clean, and an ordinary verb that makes no trust decision at all was passed over rather than judged, so the three reports above are ordering being detected rather than a scan that flags every file naming both calls'

# The RED twins, on the same function. Six fixtures, and every one of them is
# judged at a REPO-RELATIVE PATH as well as by its text, because the path is
# half of what decides the verdict: one of them -- the deferring entry point
# that reaches only the PATH restore -- is a violation under plugins/ and no
# violation at all under libexec/, and it is fed to the same function at both.
# Between them the fixtures cover the three reported shapes and four judgements
# that must come back clean, so a scan that says yes to everything cannot pass
# this, and neither can one that has quietly gone back to reading only the
# three executable roots.
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
# The harness shape: outside the three executable roots, deferring nothing,
# firing nothing. This is what scripts/beta-qualify.sh was before this task,
# and what every bundled engine adapter was.
{ printf '#!/usr/bin/env bash\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'echo "a harness outside the executable roots that fires no gate"\n'
} > "$ENTRY_FIXTURES/offpath-unfired.sh"
# The same harness with the one line that fixes it.
{ printf '#!/usr/bin/env bash\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'orchid_root_stale_gate\n'
  printf 'echo "a harness that fires the gate it armed"\n'
} > "$ENTRY_FIXTURES/offpath-fired.sh"
# The file that names lib/common.sh without ever loading it -- the shape of
# install.sh's two-anchor test, which is still in the installer beside the load
# it now also performs. It must be passed over entirely rather than reported for
# firing nothing, since a file that only tests for the path arms nothing.
{ printf '#!/usr/bin/env bash\n'
  printf 'if [ ! -f "$ROOT/lib/common.sh" ]; then exit 1; fi\n'
  printf 'echo "this checks for the library, it does not load it"\n'
} > "$ENTRY_FIXTURES/mentions-only.sh"

assert_match 'gate-armed-never-fired:' \
  "$(entry_gate_violations "$ENTRY_FIXTURES/orchid-unfired" libexec/orchid-inv15-unfired)" \
  "INV-15: a trust-boundary entry point that arms the gate and reaches no firing site must be reported"
red_case "INV-15's entry-point derivation reported a synthetic trust-boundary entry point that arms the stale-root gate and never fires it, so a gate skipped by omission is detected rather than assumed impossible"

assert_match 'gate-armed-never-fired-off-path:' \
  "$(entry_gate_violations "$ENTRY_FIXTURES/offpath-unfired.sh" scripts/inv15-unfired.sh)" \
  "INV-15: a file that loads lib/common.sh from outside the three executable roots, and fires nothing, must be reported — the source-time fire does not reach it, so the guard it armed is left armed"
red_case "INV-15's derivation reported a synthetic harness under scripts/ that loads lib/common.sh and fires nothing: the shape scripts/beta-qualify.sh and every bundled engine adapter had, in the shadow the narrow universe could not see into"

assert_match 'gate-fires-only-through-the-path-restore-off-path:' \
  "$(entry_gate_violations "$ENTRY_FIXTURES/orchid-restores" plugins/engines/inv15-restores/run)" \
  "INV-15: a deferring file outside the executable roots whose only firing site is _orchid_entry_restore_operator_path must be reported — that helper asks _orchid_kernel_entry_point before it fires anything, so off that path it restores the PATH and fires nothing"
red_case "INV-15's derivation reported a file whose one firing site is a call that fires nothing where that file lives, so 'the text contains a call to a firing site' is not being mistaken for 'the gate fires'"

# A heredoc rather than a space-separated string walked with an unquoted
# expansion: this file is inside scripts/ci-local.sh's own ShellCheck pass, and
# the loop that checks the gates may not be the one thing that trips it.
while IFS=: read -r entry_ok_file entry_ok_rel; do
  [ -n "$entry_ok_file" ] || continue
  entry_ok_out="$(entry_gate_violations "$ENTRY_FIXTURES/$entry_ok_file" "$entry_ok_rel")"
  [ -z "$entry_ok_out" ] \
    || fail "INV-15: the $entry_ok_file fixture was reported at $entry_ok_rel ($entry_ok_out) — a scan that flags a deferring entry point which DOES restore where restoring fires, an ordinary verb that defers nothing, a harness that calls the gate explicitly, or a file that only MENTIONS the library would flag the whole tree and prove nothing"
done <<'ENTRYOK'
orchid-restores:libexec/orchid-inv15-restores
orchid-ordinary:libexec/orchid-inv15-ordinary
offpath-fired.sh:scripts/inv15-fired.sh
mentions-only.sh:scripts/inv15-mentions-only.sh
ENTRYOK
green_case 'a deferring entry point that reaches its restore at a path where restoring really fires, an ordinary verb that defers nothing at all, an off-path harness that calls orchid_root_stale_gate itself, and a file that names lib/common.sh without loading it were all left alone — so the four reports above are detection rather than a scan that flags every file it reads'

# ---------------------------------------------------------------------------
# THE INSTALLER, RUN, because the derivation above can only say it is WIRED.
#
# install.sh is the top-level family, and it is the one entry point whose
# product is not a verb but a machine-scoped WIRING: the operator's own `orchid`
# becomes a symlink into whatever checkout it was run from, and ~/.orchid is
# created from that checkout's key list. Out of a stale integration checkout
# that is the pre-merge tree installing itself as the operator's orchid, at the
# one step nobody re-runs afterwards.
#
# AND ITS ONLY PRIOR KERNEL CHECK COULD NOT SEE THAT, which is why a scan of the
# file was never going to be enough. The installer finishes by running `orchid
# doctor`, but only when cwd is a git repo whose toplevel is NOT the source
# checkout -- so the check is skipped in exactly the self-hosted shape, running
# the installer from inside the orchid checkout itself, which is the only shape
# in which that checkout can be the stale integration tree at all. A gate whose
# single blind spot is the only environment that reaches the condition is
# lesson L036 again, in the installer.
#
# BOTH EDGES, and the witness is a side effect rather than an exit code: the
# refused run must leave no symlink at the prefix and no ~/.orchid tree, and the
# permitted run out of a root that is NOT stale must create both -- otherwise
# this pair is satisfied by an installer that wires nothing.
INSTALL_STALE_ROOT="$WORK/installer-stale-root"
make_probe_root "$INSTALL_STALE_ROOT" "$PROBE_INTEG"
cp "$REPO_ROOT/install.sh" "$INSTALL_STALE_ROOT/install.sh"
printf '\n# staged kernel edit\n' >> "$INSTALL_STALE_ROOT/libexec/orchid-version"
git -C "$INSTALL_STALE_ROOT" add libexec/orchid-version
[ -n "$(git -C "$INSTALL_STALE_ROOT" diff --cached --name-only HEAD -- libexec)" ] \
  || fail "INV-15: the installer probe root carries no staged kernel edit, so it is not stale and the refusal below would prove nothing"

INSTALL_OK_ROOT="$WORK/installer-fresh-root"
make_probe_root "$INSTALL_OK_ROOT" probe/development
cp "$REPO_ROOT/install.sh" "$INSTALL_OK_ROOT/install.sh"
printf '\n# staged kernel edit\n' >> "$INSTALL_OK_ROOT/libexec/orchid-version"
git -C "$INSTALL_OK_ROOT" add libexec/orchid-version

# run_installer <root> <tag> -- the SHIPPED install.sh, out of <root>, into a
# scratch HOME and prefix of its own. ~/.orchid/config is pre-created so the run
# never reaches lib/config-keys.txt, which these minimal probe roots do not
# carry: what is under test is where the gate lands, not the installer's config
# authoring. The prefix directory is deliberately NOT pre-created, so its
# absence afterwards is evidence the installer stopped before its first write.
install_home=""
install_prefix=""
install_out=""
install_rc=0
run_installer() {
  local root="$1" tag="$2"
  install_home="$WORK/installer-home-$tag"
  install_prefix="$WORK/installer-prefix-$tag"
  mkdir -p "$install_home/.orchid"
  printf '# scratch user config\n' > "$install_home/.orchid/config"
  install_rc=0
  install_out="$(HOME="$install_home" ORCHID_ALLOW_STALE_ROOT='' \
    /bin/bash "$root/install.sh" --prefix "$install_prefix" 2>&1)" || install_rc=$?
}

run_installer "$INSTALL_OK_ROOT" fresh
assert_eq 0 "$install_rc" \
  "INV-15: the shipped installer must complete out of a root that is not stale — otherwise the refusal below is an installer that refuses everything (got: $install_out)"
[ -L "$install_prefix/bin/orchid" ] \
  || fail "INV-15: the permitted installer run created no orchid symlink at $install_prefix/bin — the side effect the refusal below has to prevent does not happen, so preventing it proves nothing ($install_out)"
[ -d "$install_home/.orchid/plugins/engines" ] \
  || fail "INV-15: the permitted installer run created no ~/.orchid/plugins/engines — the second side effect the refusal below has to prevent does not happen either ($install_out)"
green_case "the shipped install.sh, run out of a checkout that is NOT stale with the identical staged kernel edit, wired the operator orchid symlink and the per-user plugin directory — so those writes really do happen, and their absence below is caused rather than inherited"

run_installer "$INSTALL_STALE_ROOT" stale
assert_eq 1 "$install_rc" \
  "INV-15: the shipped installer, run out of a checkout genuinely parked on its configured integration branch with a kernel path staged, must refuse (got rc=$install_rc: $install_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$install_out" \
  "INV-15: and it must be the stale-root refusal, not some other installer failure"
assert_match 'libexec/orchid-version' "$install_out" \
  "INV-15: the refusal must name the staged kernel path, which only the index comparison can have produced — the installer's gate is not merely present, it SAW something"
[ ! -e "$install_prefix" ] \
  || fail "INV-15: the refused installer run created $install_prefix anyway — the gate is reached after the wiring it exists to prevent, which is a gate reached too late"
[ ! -e "$install_home/.orchid/plugins" ] \
  || fail "INV-15: the refused installer run created ~/.orchid/plugins in the scratch HOME anyway — the gate sits below at least one of this installer's writes"
red_case "the shipped install.sh, run out of a genuinely stale installation root, refused with the staged kernel path named and wired NOTHING — no orchid symlink at the prefix and no per-user plugin directory — so the top-level entry point that the source-time fire cannot reach, and whose own post-install doctor is skipped in exactly this self-hosted shape, fires the gate it arms ahead of its side effects"

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
pq_files_seen=0

# pq_scan_file <abspath> <relpath> -- count this file's pipes into grep and
# collect the early-exiting ones. One body, called from both loops below, so
# the shipped tree and the gate files cannot come to be scanned differently.
pq_scan_file() {
  local abs="$1" rel="$2" line
  pq_files_seen=$((pq_files_seen + 1))
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pq_examined=$((pq_examined + 1))
  done < <(piped_grep_lines "$abs")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pq_violations="$pq_violations
  $rel:$line"
  done < <(piped_early_exit_grep "$abs")
}

# THE WHOLE SHIPPED INVENTORY, by section 4's walk rather than by a family
# list. This scan's subject list was nine globs -- and nine is not better than
# six: an engine adapter's `classify` is fed the whole of a vendor CLI's
# combined output, which is the largest producer any matcher in this tree
# gets, and all four adapters carried this shape until this section was
# written, while install.sh carried it at the TOP LEVEL in its stable-channel
# ref check, where no scan in the tree looked because every family here was a
# directory. Both of those were found by widening a list; the walk is what
# stops the next one needing to be. A file that is not shell simply matches
# nothing, so admitting the whole inventory costs a grep per file and buys
# every directory nobody has thought of yet.
while IFS= read -r pq_rel; do
  [ -n "$pq_rel" ] || continue
  pq_scan_file "$REPO_ROOT/$pq_rel" "$pq_rel"
done < <(shipped_inventory "$REPO_ROOT")

# ...and `tests/inv/test_*.sh`, by the SAME glob section 2 enrols, so a gate
# file written tomorrow is covered by both at once: section 2 requires it to
# be enforced at run time, this requires the assertions it enforces with to
# mean what they say. It is a second loop rather than an inventory member
# because the inventory excludes tests/ wholesale and declares why; the rest
# of tests/ is deliberately still outside -- see the not-tested claim at the
# end of this file for what that leaves open and why the invariant gates were
# taken first.
for pq_file in "$INV_GLOB_DIR"/test_*.sh; do
  [ -f "$pq_file" ] || continue
  pq_scan_file "$pq_file" "${pq_file#"$REPO_ROOT"/}"
done
[ "$pq_files_seen" -ge 40 ] \
  || fail "INV-15: the early-exit scan opened only $pq_files_seen file(s). It reads the whole shipped inventory plus every tests/inv/ gate, so a number this small means the walk feeding it has stopped reaching the tree and the verdict below is about almost nothing"

# The denominator, asserted before the verdict: a scan that had stopped
# matching pipes at all would report a clean kernel, and that is the reading
# this whole file exists to make impossible.
[ "$pq_examined" -ge 10 ] \
  || fail "INV-15: only $pq_examined piped-grep line(s) discovered across the $pq_files_seen files scanned — the whole shipped inventory plus every tests/inv/ gate — and the shipped tree has many more, so the early-exit scan below is judging an almost empty set and its silence means nothing"

[ -z "$pq_violations" ] \
  || fail "INV-15: a gate pipes a producer into an early-exiting grep. Under set -o pipefail the SIGPIPE that grep's first match sends the producer becomes the pipeline's status, so a MATCH can be read as no-match — the gate is not skipped, it is decided by process scheduling (the class T010's arbitration named). In an invariant file the usual shape is a NEGATIVE assertion — a producer piped into an early-exiting grep, then '&& fail' — and it is skipped exactly when the pattern IS present. Feed the matcher a herestring instead:$pq_violations"

green_case "every one of the $pq_examined pipes into grep found across the $pq_files_seen files scanned — the entire shipped inventory this file WALKS rather than a list of families, plus the tests/inv/ gate files — reads its input to EOF, and none carries a -q whose early exit could SIGPIPE the producer and hand pipefail a kill-by-signal status where a verdict belongs"

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
chmod +x "$PUMP_ROOT/bin/orchid" "$PUMP_ROOT/runners/orchid-pump" \
  "$PUMP_ROOT/runners/orchid-tick"
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

# ACKNOWLEDGED, and this is load-bearing rather than setup -- for the GREEN run
# rather than for the RED one, which is worth being exact about now that the
# stale-root gate has moved. It used to sit BELOW the pump's unattended-trust
# gate, and the note here used to say so; it now fires above it, so out of the
# stale root the refusal below would arrive with or without this record. What
# still needs it is the run that must be ALLOWED: without an acknowledgement
# this checkout's own pump refuses at its trust gate, never reaches its lease
# step, and creates no runtime directory either -- and then the absence the RED
# run is measured by is inherited from a pump that never writes there at all
# rather than caused by the gate.
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

# ---------------------------------------------------------------------------
# THE ROUTES THAT WRITE NOTHING AND ANSWER ANYWAY.
#
# The runs above take the pump's long route, the one that reaches
# `orchid_runtime`. Both scheduled runners also have SHORT routes that produce
# a verdict about the repository and leave: `pump: not an orchid repo`, the
# split-brain line, `pump: run complete`, and the tick's `run_status complete,
# nothing to do`. Every one of those exits above the trust gate on purpose --
# they are the diagnostics that must stay available on an unacknowledged
# target -- and the stale-root gate used to sit below them, so out of a stale
# installation each was answered by the pre-merge kernel and the gate was never
# reached at all.
#
# That is this file's own subject in its second costume. The first was a gate
# nothing invoked; this is a gate invoked on one route through a file and
# omitted on another, which no scan of that file can see, because the call IS
# in the text. It is also the argument `orchid trust show` lost: writing
# nothing durable is not having nothing to protect. `pump: run complete`,
# repeated into a cron log by a kernel nobody has looked at, is an operator
# acting on a stale answer -- and it is the exact shape of the incident lesson
# L018 was written for, a run driven by pre-merge code while everything
# reported success.
#
# Two targets, neither acknowledged and neither needing to be: both routes end
# above the trust gate, so what is measured here is only the stale-root gate's
# reach. The GREEN runs come first, out of this checkout's own kernel, because
# a verdict the refusal is supposed to suppress has to be one that really is
# produced otherwise.
PUMP_BARE="$PUMP_PROOF/repo-uninitialised"
mkdir -p "$PUMP_BARE"
PUMP_DONE="$PUMP_PROOF/repo-complete"
mkdir -p "$PUMP_DONE/.orchid"
printf -- '---\nrun_status: complete\nrun_id: inv15-pump-done\n---\n# Roadmap\n' \
  > "$PUMP_DONE/.orchid/roadmap.md"
# The pump's remaining verdict, and it is BUILT rather than argued from the
# other two, because the predicate behind it is a different one:
# orchid_split_brain is true when .orchid/tasks or .orchid/journal.md exists
# WITHOUT .orchid/roadmap.md -- the "wrong checkout" shape -- and it is answered
# by its own echo and its own exit on its own route. Verdicts that share a shape
# do not share a line, and whether a route reaches the gate is a fact about that
# route; the only way to have it is to take it.
PUMP_SPLIT="$PUMP_PROOF/repo-split-brain"
mkdir -p "$PUMP_SPLIT/.orchid"
printf '# Journal\n' > "$PUMP_SPLIT/.orchid/journal.md"
[ ! -f "$PUMP_SPLIT/.orchid/roadmap.md" ] \
  || fail "INV-15: the split-brain fixture has a roadmap, so it is not split-brain and the pump would answer it on some other route"

# early_probe <root> <runner> <repo> -- one scheduled-runner invocation out of
# <root> against <repo>. Same shape as pump_probe above, with the target and
# the runner as parameters because the same short-route question is put to two
# entry points.
early_rc=0
early_out=""
early_probe() {
  early_rc=0
  early_out="$(HOME="$MACHINE_HOME" ORCHID_REPO="$3" ORCHID_ALLOW_STALE_ROOT='' \
    "$1/runners/$2" 2>&1)" || early_rc=$?
}

early_probe "$REPO_ROOT" orchid-pump "$PUMP_BARE"
assert_eq 0 "$early_rc" \
  "INV-15: this checkout's own pump must answer an uninitialised directory with its no-op verdict (got rc=$early_rc: $early_out)"
assert_eq "pump: not an orchid repo" "$early_out" \
  "INV-15: ...and answer it verbatim, so the absence of this line below is the gate suppressing it rather than a pump that never says it"
early_probe "$REPO_ROOT" orchid-pump "$PUMP_SPLIT"
assert_eq 0 "$early_rc" \
  "INV-15: this checkout's own pump must answer a split-brain checkout with its no-op verdict (got rc=$early_rc: $early_out)"
assert_match '^pump: no roadmap in this checkout ' "$early_out" \
  "INV-15: ...and it must be the split-brain line, which is its own echo on its own route rather than a second spelling of the uninitialised one"
early_probe "$REPO_ROOT" orchid-pump "$PUMP_DONE"
assert_eq 0 "$early_rc" \
  "INV-15: this checkout's own pump must answer a finished run with its no-op verdict (got rc=$early_rc: $early_out)"
assert_eq "pump: run complete" "$early_out" \
  "INV-15: ...and answer it verbatim"
early_probe "$REPO_ROOT" orchid-tick "$PUMP_DONE"
assert_eq 0 "$early_rc" \
  "INV-15: this checkout's own tick must answer a finished run with its no-op verdict (got rc=$early_rc: $early_out)"
assert_match 'run_status complete, nothing to do' "$early_out" \
  "INV-15: ...and it must be the finished-run line, not some other exit"
green_case "both scheduled runners, out of a root that is NOT stale, produced every short-route verdict they exist to produce on an unacknowledged target -- the pump's uninitialised, split-brain and finished-run lines and the tick's finished-run line -- so each verdict is an answer that really is given, and its absence below is caused rather than inherited"

# The RED half: the same four questions, out of the genuinely stale root.
early_probe "$PUMP_ROOT" orchid-pump "$PUMP_BARE"
assert_eq 1 "$early_rc" \
  "INV-15: a pump answering 'not an orchid repo' out of a stale installation root must refuse instead (got rc=$early_rc: $early_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$early_out" \
  "INV-15: ...and it must be the stale-root refusal, not some other failure of the fixture"
assert_match 'templates/\.keep' "$early_out" \
  "INV-15: ...naming the staged kernel path, which only the index comparison can have produced"
if grep -qF 'pump: not an orchid repo' <<<"$early_out"; then
  fail "INV-15: the refused pump printed its uninitialised verdict anyway. That verdict is an answer about this repository read out of the tree whose staleness is the finding, and it is on a route that exits above the trust gate — so the gate is reached on the route that writes and skipped on the route that only answers"
fi

early_probe "$PUMP_ROOT" orchid-pump "$PUMP_SPLIT"
assert_eq 1 "$early_rc" \
  "INV-15: a pump answering its split-brain line out of a stale installation root must refuse instead (got rc=$early_rc: $early_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$early_out" \
  "INV-15: ...and it must be the stale-root refusal"
if grep -qF 'no roadmap in this checkout' <<<"$early_out"; then
  fail "INV-15: the refused pump printed its split-brain verdict anyway. This route is reached through a different predicate from the pump's other two verdicts, which is exactly why it is taken here rather than argued from them: a gate is reached or skipped per ROUTE, and routes that clear it say nothing about the one beside them"
fi

early_probe "$PUMP_ROOT" orchid-pump "$PUMP_DONE"
assert_eq 1 "$early_rc" \
  "INV-15: a pump answering 'run complete' out of a stale installation root must refuse instead (got rc=$early_rc: $early_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$early_out" \
  "INV-15: ...and it must be the stale-root refusal"
if grep -qF 'pump: run complete' <<<"$early_out"; then
  fail "INV-15: the refused pump printed 'run complete' anyway — the one verdict a scheduler collects most often, produced by pre-merge code, on the route where the gate was never reached"
fi

early_probe "$PUMP_ROOT" orchid-tick "$PUMP_DONE"
assert_eq 1 "$early_rc" \
  "INV-15: a direct tick answering a finished run out of a stale installation root must refuse instead (got rc=$early_rc: $early_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$early_out" \
  "INV-15: ...and it must be the stale-root refusal. The tick fires this gate through its operator-PATH restore, which sits BELOW its finished-run exit, so this route reached no gate at all until the runner called it itself"
if grep -qF 'nothing to do' <<<"$early_out"; then
  fail "INV-15: the refused tick printed its finished-run verdict anyway. The direct tick is an unattended entry point in its own right — a crontab can point straight at it — so this is the same omission the pump had, one file over"
fi
red_case "the same four short-route questions asked out of a genuinely stale installation root were all refused with the staged kernel path named and not one of the four verdicts produced, so the gate these runners arm is reached on every route that only ANSWERS and not merely on the routes that write"

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
# are what `orchid trust` loads and dispatches through, and runners/ is copied
# with them because the usage-arm comparison at the end of this section runs the
# OTHER verb that fires this gate itself -- `orchid service`, whose libexec file
# is a bare handoff into runners/orchid-service. `templates/.keep` is what gets
# staged, so the refusal names a path nothing else in this fixture could have
# produced.
TRUST_ROOT="$TRUST_PROOF/stale-root"
mkdir -p "$TRUST_ROOT"
for trust_dir in bin lib libexec runners; do
  cp -R "$REPO_ROOT/$trust_dir" "$TRUST_ROOT/$trust_dir"
done
for trust_dir in plugins roles skills templates; do
  mkdir -p "$TRUST_ROOT/$trust_dir"
  printf 'probe\n' > "$TRUST_ROOT/$trust_dir/.keep"
done
printf 'PROTOCOL probe\n' > "$TRUST_ROOT/PROTOCOL.md"
printf 'integration_branch=%s\n' "$PROBE_INTEG" > "$TRUST_ROOT/orchid.config"
chmod +x "$TRUST_ROOT/bin/orchid" "$TRUST_ROOT/libexec/orchid-trust" \
  "$TRUST_ROOT/libexec/orchid-service" "$TRUST_ROOT/runners/orchid-service"
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

# ---------------------------------------------------------------------------
# THE USAGE ARM, IN BOTH VERBS THAT FIRE THIS GATE THEMSELVES.
#
# `libexec/orchid-trust` and `runners/orchid-service` are the two shipped entry
# points that hold the fixed bootstrap PATH for their whole run, never reach
# _orchid_entry_restore_operator_path, and therefore fire the stale-root gate by
# an explicit call or not at all. Both dispatch on a subcommand first, and both
# answer -h, --help, help and a bare invocation with their usage text ABOVE that
# call. That is a route through a trust-boundary entry point on which the gate
# does not fire, which is precisely this file's subject -- so it may not be an
# accident in one file and a documented decision in the other. It is one rule,
# and it is asked of both verbs here.
#
# The rule is the floor the too-many-arguments case above establishes: the gate
# belongs AFTER the operator's command has been validated, so a mistyped
# invocation is answered with its own diagnosis rather than a refusal about the
# checkout. A usage text is that same kind of answer -- it is about the command
# line, it names no repository, resolves no record, and reports nothing an
# operator could act on about a target, because at that point no target has been
# resolved. What the gate must precede is the first thing the verb does on its
# target, and both files place the call exactly there.
#
# Which is why the acting arm is run too, out of the SAME root. On its own,
# "the usage arm was answered" is equally true of a root that is not stale at
# all; the pair is what makes it an exemption being measured rather than a
# fixture that refuses nothing. `orchid trust`'s acting arms are covered above,
# so the one added here is `orchid service status` -- the arm of the other verb
# that reaches a target without crossing the unattended-trust boundary first,
# and the file whose gate placement had to be corrected from per-arm to
# straight-line during this task.
svc_rc=0
svc_out=""
svc_probe() {
  local root="$1"; shift
  svc_rc=0
  svc_out="$(env -u ORCHID_REPO -u ORCHID_EPOCH \
    HOME="$TRUST_HOME" ORCHID_ALLOW_STALE_ROOT='' \
    "$root/bin/orchid" "$@" 2>&1)" || svc_rc=$?
}

# <verb>:<a line only that verb's usage text carries>. The marker is spelled per
# verb rather than derived from the verb name because the two lay their usage
# out differently -- `orchid service` puts the whole synopsis on the `usage:`
# line and `orchid trust` lists its three arms under it -- and a pattern loose
# enough to match both would also be matched by half the refusals in this file.
for svc_usage_arm in 'trust:orchid trust unattended' 'service:usage: orchid service'; do
  svc_verb="${svc_usage_arm%%:*}"
  svc_want="${svc_usage_arm#*:}"
  svc_probe "$TRUST_ROOT" "$svc_verb" --help
  assert_eq 0 "$svc_rc" \
    "INV-15: 'orchid $svc_verb --help' out of a stale installation root must still print its usage and exit 0 (got rc=$svc_rc: $svc_out). The gate sits after the operator's command has been validated in both of these verbs, and a help text that answers in one and refuses in the other is the same rule being applied twice with two different answers"
  assert_match "$svc_want" "$svc_out" \
    "INV-15: ...and what it printed must be that verb's own usage text"
  case "$svc_out" in
    *'refusing to run'*)
      fail "INV-15: 'orchid $svc_verb --help' was answered with the stale-root refusal. The other verb answers the same arm with its usage text, so one of the two is now firing the gate in front of an answer that names no target — and whichever one it is, the two no longer agree about where this gate belongs" ;;
  esac
done
green_case "both entry points that fire the stale-root gate themselves — 'orchid trust' and 'orchid service' — answered their usage arm out of the very installation root that refuses the acting arms below, so the one route on which this gate does not fire is the same route in both files rather than an exemption one of them grew alone"

# The acting arm of the second verb, and the GREEN half runs first for the
# reason the lookup's did: the RED below is an ABSENCE, and an absence proves
# nothing until the thing absent is known to happen.
svc_probe "$REPO_ROOT" service status --repo "$TRUST_REPO"
assert_eq 0 "$svc_rc" \
  "INV-15: 'orchid service status' out of this checkout's own kernel must report on the fixture repository (got rc=$svc_rc: $svc_out)"
assert_match 'orchid service status:' "$svc_out" \
  "INV-15: ...and it must actually print the status report, which is what the refusal below is measured by the absence of"
green_case "the status arm of 'orchid service', run out of a root that is NOT stale, printed the report it exists to print — so that report is a side effect which really does happen, and its absence below is caused rather than inherited"

svc_probe "$TRUST_ROOT" service status --repo "$TRUST_REPO"
assert_eq 1 "$svc_rc" \
  "INV-15: 'orchid service status' invoked out of a stale installation root must refuse (got rc=$svc_rc: $svc_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$svc_out" \
  "INV-15: ...and it must be the stale-root refusal, not a usage error or some other failure of the fixture"
assert_match 'templates/\.keep' "$svc_out" \
  "INV-15: the refusal must name the staged kernel path — the gate is not merely called in this runner, it ran and it SAW something"
case "$svc_out" in
  *'orchid service status:'*)
    fail "INV-15: the refused 'orchid service status' printed its report anyway, so the gate in runners/orchid-service is reached after the answer it was supposed to precede. This is the file whose gate was written once per arm and had to be moved above the dispatch; a report produced below it is that correction not having taken" ;;
esac
red_case "the acting arm of 'orchid service', out of the same stale installation root whose usage arm was answered above, refused before its report — so the usage exemption the two verbs share is bounded to the arm that resolves no target, and the gate really does fire on the arm that does"

# ===========================================================================
# 9 -- THE SELF-HOSTED ENTRY POINTS, RUN: THE DENIAL COSTS NO TARGET-REPOSITORY
# GIT, AND A REFUSED RUN REPORTS NOTHING AT ALL.
#
# Four entry points, in the order they were found to need it: `orchid doctor`
# first; then `orchid trust show` -- the arm whose target the operator NAMES,
# and most often names as Orchid's own checkout; then `orchid trust revoke`,
# whose ordering is pinned on its report edge because it walks no history; and
# last `orchid status`, both of its arms, because only one of them makes the
# decision at all. Each half is below the doctor half, after the plumbing they
# all share.
#
# `orchid doctor` is the one deferring diagnostic with TWO pre-report gates,
# and the order of the two only matters in one environment: the one where
# ORCHID_REPO and ORCHID_ROOT are the SAME checkout. Then the stale-root
# gate's `git -C $root diff --cached` is a query against the very repository
# whose machine-local acknowledgement has not been looked up yet, and firing
# it first would spend target-repository Git in front of the unattended-trust
# decision. Everywhere else the two are different directories and the ordering
# costs nothing to get wrong -- which is precisely the shape of lesson L036:
# the dimension the code branches on is false in every environment that
# revalidates it. Orchid is self-hosted, so that environment is not
# hypothetical; it is this repository.
#
# The only answer this file used to have was a comparison of the line numbers
# of two calls in libexec/orchid-doctor, up in section 4. That scan is kept,
# because it is cheap and it does say something. It is not what this section
# rests on: a line-order scan cannot see that the earlier call spends nothing,
# cannot see what the file has already printed by the time it reaches either,
# and reads exactly the same whether the file runs or not. So the claims are
# made by RUNNING the shipped doctor out of a checkout that really is the
# self-hosted case, with Git itself reporting every subprocess it spawns.
#
# TWO RUNS FOR DOCTOR, because the refusal hides the ordering it is part of
# (the lookup half below takes a third, for a reason the doctor half does not
# have):
#
#   * With the gate ARMED, doctor must refuse and must have printed NOTHING --
#     no plugin listing, no readiness verdict, not even its own trust line.
#     A diagnosis produced out of a stale checkout is produced BY the code
#     whose staleness is the finding, and an operator then acts on it. The
#     first Git subprocess of that whole run must be the gate's own index
#     comparison, so nothing reached the target repository ahead of the
#     machine-local denial.
#   * With the gate stood down by the documented override, and NOTHING else
#     changed -- same stale checkout, same empty machine-local store, same
#     target -- doctor must reach and render its denial having spent no Git at
#     all. That is "no target-repository Git before denial" observed rather
#     than deduced, and it is only observable once the refusal is out of the
#     way.
#
# GIT_TRACE is what makes both observable. A shim on PATH cannot be: doctor
# overwrites PATH with the fixed machine-local prefixes as its first act, and
# holds it across exactly the window under test here, which is the property
# that entry point exists for. Git reporting its own subprocesses is not
# subject to that.
#
# BUT THE TRACE MUST GO TO A FILE, NOT TO GIT'S STDERR, and this is the whole
# of what an earlier version of this section got wrong -- in the direction
# this file exists to refuse. GIT_TRACE=1 means "write the trace to Git's own
# standard error", and EVERY Git the kernel spends inside this window discards
# exactly that stream on purpose: the gate's index comparison is written
# `git -C "$root" diff --cached --name-only HEAD ... 2>/dev/null` in
# lib/common.sh, and lib/trust.sh's probes are written the same way, so a root
# that cannot answer stays silent instead of printing Git's complaint into an
# operator's report. Reading the trace off Git's stderr therefore observes
# NOTHING of precisely the calls this section is about. "No Git ran" and "the
# Git that ran was silenced by the production redirection" arrive as the same
# empty measurement -- a proof blind in exactly the dimension it is measuring,
# which is section 3's lesson turned on this file's own instrumentation. The
# production silence is correct and is left alone; what changes is where the
# trace is sent. GIT_TRACE set to an absolute PATH is written by Git to that
# file directly, and no redirection of Git's stderr can suppress it.
#
# Ordering survives the move, and is not traded for visibility: the run's own
# stdout and stderr are APPENDED TO THAT SAME FILE. Bash's `>>` opens with
# O_APPEND and Git opens its trace target with O_APPEND, so every write from
# either lands at the current end of the file and the result is still ONE
# stream in the order things actually happened. "Before" and "after" are read
# off a single pass, rather than correlated across two files by timestamp.
#
# And the instrumentation itself is witnessed before anything is measured with
# it, because a proof whose observer is broken reports the same empty result
# as a run that spent nothing: see DOCTOR_TRACE_PROBE below, which spends one
# Git under the production redirection and requires the trace file to have
# caught it -- next to its own twin showing that the stderr spelling catches
# nothing there.
# ===========================================================================
DOCTOR_PROOF="$WORK/doctor-selfhost"
mkdir -p "$DOCTOR_PROOF"
DOCTOR_ROOT="$DOCTOR_PROOF/stale-root"
mkdir -p "$DOCTOR_ROOT"

# A real installation root, not section 3's minimal probe: the shipped doctor
# loads eight libraries and shells out to its own dispatcher, so a fixture that
# only satisfied the guard would fail for reasons that have nothing to do with
# this section. The directories are this candidate's own, and they mirror
# ORCHID_KERNEL_PATHS (lib/common.sh) -- the set the stale-root comparison is
# scoped to. That list is not DERIVED here, since this file does not load
# lib/common.sh, and it does not need to be exact: a path missing from the copy
# would show up as the staged edit below producing no diff, which the assertion
# after the commit refuses outright rather than passing over.
for doctor_dir in bin lib libexec runners plugins roles skills templates; do
  cp -R "$REPO_ROOT/$doctor_dir" "$DOCTOR_ROOT/$doctor_dir"
done
cp "$REPO_ROOT/PROTOCOL.md" "$DOCTOR_ROOT/PROTOCOL.md"
chmod +x "$DOCTOR_ROOT/bin/orchid" "$DOCTOR_ROOT/libexec/orchid-doctor" \
  "$DOCTOR_ROOT/libexec/orchid-trust"

# The config is AUTHORED, not copied, and it declares exactly one key.
#
# The value is this repository's own integration branch, so the fixture is
# parked on a branch a real installation really uses -- but nothing else comes
# with it. Copying orchid.config verbatim would hand the fixture this
# repository's notify channel and role table, and run two below executes the
# WHOLE of doctor: it would go resolve a notify plugin and probe a return leg
# that has nothing to do with the ordering under test. Authoring the file also
# settles a question this fixture must not depend on the answer to: with one
# occurrence of the key there is no last-wins-versus-first-wins reading of a
# stacked config for the fixture's staleness to hinge on.
doctor_integ=""
while IFS= read -r doctor_line; do
  case "$doctor_line" in integration_branch=*) doctor_integ="${doctor_line#integration_branch=}" ;; esac
done < "$REPO_ROOT/orchid.config"
[ -n "$doctor_integ" ] \
  || fail "INV-15: this repository's orchid.config declares no integration_branch, so the fixture below cannot be parked on the branch a real installation is parked on and the refusal would prove nothing"
printf 'integration_branch=%s\n' "$doctor_integ" > "$DOCTOR_ROOT/orchid.config"

git init -q "$DOCTOR_ROOT"
git -C "$DOCTOR_ROOT" symbolic-ref HEAD "refs/heads/$doctor_integ"
git -C "$DOCTOR_ROOT" add -A
git -C "$DOCTOR_ROOT" commit -q -m "doctor self-host probe root"
printf '\n# staged kernel edit\n' >> "$DOCTOR_ROOT/libexec/orchid-version"
git -C "$DOCTOR_ROOT" add libexec/orchid-version
[ -n "$(git -C "$DOCTOR_ROOT" diff --cached --name-only HEAD -- libexec)" ] \
  || fail "INV-15: the self-hosted doctor fixture has no staged kernel edit, so its root is not stale and neither run below would be measuring what it claims to"

# A machine-local store of its own, genuinely empty: the whole point of this
# section is the no-acknowledgement case, and section 8's TRUST_HOME now holds
# a record.
make_scratch DOCTOR_HOME

# -- THE OBSERVER IS WITNESSED FIRST, before anything is measured with it.
#
# Both runs below conclude things from Git the trace did NOT report, so an
# observer that reports nothing whatever it is pointed at would pass them in
# silence. The command here is the gate's own comparison, against the fixture
# root, redirected EXACTLY the way lib/common.sh redirects it -- stdout to
# /dev/null and stderr to /dev/null -- so what is witnessed is the production
# shape and not a friendlier one. (That this holds for the Git doctor itself
# resolves, on the fixed entry PATH rather than this file's, is witnessed
# separately by run two, which must trace the Git its readiness report spends.)
DOCTOR_TRACE_PROBE="$DOCTOR_PROOF/trace-witness"
: > "$DOCTOR_TRACE_PROBE"
GIT_TRACE="$DOCTOR_TRACE_PROBE" git -C "$DOCTOR_ROOT" \
  diff --cached --name-only HEAD -- libexec >/dev/null 2>/dev/null || true
assert_match 'trace: built-in: git' "$(cat "$DOCTOR_TRACE_PROBE")" \
  "INV-15: this Git does not honour GIT_TRACE pointed at a file, so every 'the run spent no Git here' conclusion in this section would be a statement about an unobserved run rather than about the run. Both measurements below rest on this line"
# The twin, and the reason the plumbing is what it is: the stderr spelling of
# the very same trace, on the very same command, sees nothing at all -- because
# the production redirection this section must not weaken discards the stream
# it writes to. Asserted rather than left as a comment, so the day somebody
# 'simplifies' this back to GIT_TRACE=1 the file says why not, in the failure
# output rather than in prose nobody reads.
doctor_stderr_trace="$(GIT_TRACE=1 git -C "$DOCTOR_ROOT" \
  diff --cached --name-only HEAD -- libexec 2>/dev/null || true)"
if grep -qF 'trace: built-in: git' <<<"$doctor_stderr_trace"; then
  fail "INV-15: GIT_TRACE=1 was expected to be invisible under the production 2>/dev/null redirection, and something reported it anyway — the two measurements below are plumbed for the opposite assumption and would have to be re-argued"
fi
# Deliberately NOT recorded as a red_case/green_case pair. Neither line feeds
# this section's check an input it must reject or accept; they establish that
# the observer works before the check uses it. The pairs this section records
# are the ones further down, where the shipped doctor and the two fixtures are
# actually judged -- calling these a detection would be the mislabelling this
# file was reworked to remove.

# first_traced_git <combined-output> -- the argv of the FIRST Git subprocess
# the run spent, or empty when it spent none. Older Git quotes each argument
# in its trace and newer Git does not, so the quotes are stripped by the
# caller rather than matched here.
first_traced_git() {
  awk '
    /trace: built-in: git / {
      line = $0
      sub(/^.*trace: built-in: git /, "", line)
      print line
      exit
    }
  ' <<<"$1"
}

# git_before_verdict <combined-output> <verdict-ere> -- violation lines when a
# Git subprocess ran before the run rendered its unattended-trust verdict.
#
# One pass over one stream, stopping at whichever comes first, so the answer is
# an ORDERING and not two independent presence tests. A run that rendered no
# verdict at all is reported too: "no Git ran before the denial" is vacuously
# true of a run that never denied anything, and reading that as a pass is the
# same defect this file is about.
#
# The verdict pattern is a parameter because the two shipped entry points this
# section runs spell their verdict differently -- doctor prefixes its readiness
# marker, `orchid trust show` leads with the report's own first line -- and one
# matcher judged against both is one fewer place for the two measurements to
# disagree about what "before" means.
git_before_verdict() {
  awk -v verdict="$2" '
    settled { next }
    $0 ~ verdict { settled = 1; next }
    /trace: built-in: git / {
      line = $0
      sub(/^.*trace: built-in: git /, "", line)
      print "git-before-denial: " line
      settled = 1
      next
    }
    END { if (!settled) print "denial-unreached: the run rendered no unattended-trust verdict at all, so there is no moment in it to measure a Git query against" }
  ' <<<"$1"
}

DOCTOR_VERDICT_ERE='^(ok|WARN): unattended trust'
TRUST_SHOW_VERDICT_ERE='^unattended trust: '

doctor_git_before_denial() { git_before_verdict "$1" "$DOCTOR_VERDICT_ERE"; }

# doctor_traced_run <stream-file> <env-assignment>... <command>... -- run a
# command with Git tracing into <stream-file>, and with the command's OWN
# stdout and stderr appended to that same file.
#
# The single file is the whole point, and it is what replaces the `2>&1`
# capture this section used to do. Git writes its trace to the file itself, so
# the production `2>/dev/null` on the kernel's own probes no longer erases the
# observation; and because both `>>` and Git's trace target are opened
# O_APPEND, the run's printed lines and Git's dispatch lines still interleave
# in the order they happened, which is what the ordering matcher above reads.
#
# The exit status is published in DOCTOR_RUN_RC rather than returned, and the
# stream is left in the file rather than printed, because a caller that read
# it through `$(...)` would lose the status to the subshell -- and a run whose
# refusal went unnoticed is the one thing this section may not do.
DOCTOR_RUN_RC=0
doctor_traced_run() {
  local stream="$1"; shift
  DOCTOR_RUN_RC=0
  : > "$stream"
  env -u ORCHID_EPOCH GIT_TRACE="$stream" "$@" \
    >>"$stream" 2>>"$stream" || DOCTOR_RUN_RC=$?
}

# -- RUN ONE: the gate armed. ORCHID_ALLOW_STALE_ROOT is spelled empty rather
# than inherited, for the reason sections 6 and 8 spell it: an operator with it
# exported would switch off the gate this section measures.
DOCTOR_STREAM1="$DOCTOR_PROOF/run1.stream"
doctor_traced_run "$DOCTOR_STREAM1" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT='' \
  "$DOCTOR_ROOT/libexec/orchid-doctor"
doctor_rc="$DOCTOR_RUN_RC"
doctor_out="$(cat "$DOCTOR_STREAM1")"
assert_eq 1 "$doctor_rc" \
  "INV-15: 'orchid doctor' run out of a stale self-hosted checkout, with that same checkout as its target, must refuse (got rc=$doctor_rc: $doctor_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$doctor_out" \
  "INV-15: ...and it must be the stale-root refusal, not some other failure of the fixture"
assert_match 'libexec/orchid-version' "$doctor_out" \
  "INV-15: the refusal must name the staged kernel path — the gate is not merely reached in the self-hosted case, it ran and it SAW something"
assert_match "sits on the integration branch '$doctor_integ'" "$doctor_out" \
  "INV-15: the refusal must name the branch this fixture's own orchid.config declares, so the guard is reading the fixture's configuration rather than falling back to a default that happens to match"
if grep -Eq '^(ok|FAIL|WARN): ' <<<"$doctor_out"; then
  fail "INV-15: the refused self-hosted doctor printed a diagnosis line anyway. Every verdict doctor prints is read out of the very checkout whose staleness is the finding, its own unattended-trust line included, and an operator acts on what they read — so the gate is reached after the report it was supposed to precede"
fi
if grep -Eq '^plugins:' <<<"$doctor_out"; then
  fail "INV-15: the refused self-hosted doctor printed its plugin discovery section anyway, which means it shelled out to its own dispatcher out of a stale checkout before the gate stopped it"
fi
doctor_first_git="$(first_traced_git "$doctor_out")"
doctor_first_git="${doctor_first_git//\'/}"
[ -n "$doctor_first_git" ] \
  || fail "INV-15: the refused self-hosted doctor spent no observable Git at all. It cannot have refused without comparing this root's index against HEAD, and the witness above already established that this Git records a traced-to-file command even under the production 2>/dev/null — so this is a run that spent nothing where it must have spent something, and every claim below about WHICH Git ran would be a claim about an unobserved run"
# Matched on a substring rather than an anchor: Git strips its own `-C <dir>`
# before it traces the dispatch, but that is Git's business and not something
# this file should depend on, so a spelling that carried the -C through would
# still be recognised as the gate's comparison rather than reported as a
# stranger.
case "$doctor_first_git" in
  *"diff --cached"*) ;;
  *) fail "INV-15: the FIRST Git subprocess the self-hosted doctor spent was 'git $doctor_first_git', not the stale-root gate's own index comparison. ORCHID_REPO and ORCHID_ROOT are the same unacknowledged checkout here, so anything ahead of the gate is a query against the target repository made before the machine-local trust decision had denied this run — the query the unattended-trust contract forbids before an acknowledgement is found" ;;
esac
# The other end of the same ordering, stated as an absence rather than left to
# "the first Git was the gate's". Doctor's own repository inspection is two
# named probes further down that file -- `rev-parse --git-dir` and `worktree
# list`, both against $repo -- and BOTH are written with their stderr
# discarded, so until the trace was moved to a file neither could be seen to
# have run or not run. Neither may appear anywhere in this stream: the refusal
# is supposed to have ended the run before doctor inspected the repository at
# all, and that is now an observation instead of an inference from the line
# numbers in section 4.
#
# Matched on the subcommand and its flag, not on a leading `git`: Git decides
# for itself whether its own `-C <dir>` survives into the traced argv, and an
# absence assertion that a spelling change could quietly satisfy is worse than
# none. The other edge -- that these strings are ones this matcher CAN find --
# is pinned on run two below, which reaches both probes and must show them.
DOCTOR_REPO_PROBES=('rev-parse --git-dir' 'worktree list')
doctor_stream1_bare="${doctor_out//\'/}"
for doctor_probe in "${DOCTOR_REPO_PROBES[@]}"; do
  if grep -Eq -- "$doctor_probe" <<<"$doctor_stream1_bare"; then
    fail "INV-15: the refused self-hosted doctor reached its own '$doctor_probe' inspection of the target anyway. The stale-root refusal is supposed to end the run before doctor inspects the repository at all, and this is inside the window where ORCHID_REPO is an unacknowledged checkout"
  fi
done
red_case "the shipped 'orchid doctor', run where ORCHID_REPO and ORCHID_ROOT are one stale integration checkout with no acknowledgement, refused with its staged kernel path named, not one line of diagnosis produced, neither of its own repository-inspection probes traced, and the stale-root gate's own index comparison as the first Git subprocess of the entire run"

# -- RUN TWO: the same checkout, the same empty store, the same target, with
# the gate stood down by the one documented override. The refusal is what
# hides the ordering, so standing it down is what makes the ordering visible;
# nothing else about the environment changes, which is what keeps this a twin
# of the run above rather than a different experiment.
DOCTOR_STREAM2="$DOCTOR_PROOF/run2.stream"
doctor_traced_run "$DOCTOR_STREAM2" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT=1 \
  "$DOCTOR_ROOT/libexec/orchid-doctor"
doctor_rc2="$DOCTOR_RUN_RC"
doctor_out2="$(cat "$DOCTOR_STREAM2")"
# This run does NOT stop at the denial -- it goes on to the whole readiness
# report -- so it is the one that proves the observer is pointed at a run that
# really does spend Git. If nothing at all were traced here, the emptiness the
# assertion below reads as "no Git before the denial" would be the emptiness of
# a blind measurement instead.
assert_match 'trace: built-in: git' "$doctor_out2" \
  "INV-15: the stood-down doctor run traced no Git whatsoever, though it ran its full readiness report past the denial — so this stream is not showing what this run spent and the ordering read off it below would mean nothing"
assert_match '^WARN: unattended trust \(headless execution gated\): denied' "$doctor_out2" \
  "INV-15: with the stale-root gate stood down, the self-hosted doctor must reach and render its unattended-trust denial (rc=$doctor_rc2) — without that line there is no denial for the ordering below to be measured against"
# The other edge of run one's absence assertion (lesson L034: pin the case that
# must be caught AND the case that must not fire). Run one concluded something
# from two strings NOT being in its stream; that conclusion is worth nothing
# unless those strings are ones this matcher finds when the probes really do
# run. Here they do -- same doctor, same fixture, the gate simply stood down --
# so the absence above is doctor stopping, not the matcher missing.
doctor_stream2_bare="${doctor_out2//\'/}"
for doctor_probe in "${DOCTOR_REPO_PROBES[@]}"; do
  assert_match "$doctor_probe" "$doctor_stream2_bare" \
    "INV-15: the stood-down doctor ran its whole readiness report and this stream shows no '$doctor_probe' — so run one's finding that the refusal preceded that inspection is a string this instrumentation cannot see either way, and proves nothing"
done
doctor_before_out="$(doctor_git_before_denial "$doctor_out2")"
[ -z "$doctor_before_out" ] \
  || fail "INV-15: the self-hosted doctor spent Git before its unattended-trust denial was rendered ($doctor_before_out). ORCHID_REPO and ORCHID_ROOT are the same checkout here, so that is a target-repository query made before any acknowledgement for it had been looked for — and it is invisible in every other environment, because everywhere else those two are different directories"
green_case "the same shipped doctor, out of the same stale self-hosted checkout with the same empty machine-local store and the gate stood down by its documented override, rendered its denial having spent no Git subprocess whatsoever — so the denial really is reached with no target-repository Git, observed on the stream that carries both"

# The RED and GREEN twins for that matcher, run rather than scanned. Two
# doctor-shaped fixtures differing in ONE line's position: a target-repository
# query before the verdict, and the identical query after it.
#
# Both fixtures discard their query's stderr, `2>/dev/null`, the way the kernel
# discards its own. That is not decoration: a query written that way is exactly
# the one an observer reading Git's stderr cannot see, so the RED case below is
# a demonstration that the shape which used to be invisible is now detected,
# rather than a demonstration against a friendlier spelling nobody ships.
DOCTOR_FIXTURES="$DOCTOR_ROOT/libexec"
{ printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="${ORCHID_REPO:-$PWD}"\n'
  printf 'git -C "$repo" rev-list --max-count=1 HEAD >/dev/null 2>/dev/null\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'echo "WARN: unattended trust (headless execution gated): $ORCHID_UNATTENDED_STATE"\n'
} > "$DOCTOR_FIXTURES/orchid-inv15-early-git"
{ printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="${ORCHID_REPO:-$PWD}"\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'echo "WARN: unattended trust (headless execution gated): $ORCHID_UNATTENDED_STATE"\n'
  printf 'git -C "$repo" rev-list --max-count=1 HEAD >/dev/null 2>/dev/null\n'
} > "$DOCTOR_FIXTURES/orchid-inv15-late-git"

# Through the SAME plumbing as the two shipped runs, deliberately: a matcher
# demonstrated on one instrumentation and applied on another has been
# demonstrated on nothing. It publishes the stream's path rather than printing
# the stream, for the reason doctor_traced_run publishes its status rather than
# returning it: a `$(...)` around either would put the run in a subshell.
doctor_fixture_run() {
  DOCTOR_FIXTURE_STREAM="$DOCTOR_PROOF/$1.stream"
  doctor_traced_run "$DOCTOR_FIXTURE_STREAM" \
    HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ROOT="$DOCTOR_ROOT" \
    ORCHID_ALLOW_STALE_ROOT=1 \
    /bin/bash "$DOCTOR_FIXTURES/$1"
}

doctor_fixture_run orchid-inv15-early-git
doctor_early_out="$(cat "$DOCTOR_FIXTURE_STREAM")"
assert_match '^WARN: unattended trust' "$doctor_early_out" \
  "INV-15: the early-Git fixture must still reach its verdict line (got: $doctor_early_out) — a fixture that died before rendering anything would be reported for the wrong reason"
assert_match 'git-before-denial: .*rev-list' "$(doctor_git_before_denial "$doctor_early_out")" \
  "INV-15: a doctor-shaped entry point that queries its target repository before rendering its unattended-trust denial must be reported, and reported with the query it made"
red_case "a doctor-shaped fixture that really did run 'git rev-list' against its target before rendering its denial was RUN, and the same matcher the shipped doctor is judged by named that query — so the shipped run's silence is detection rather than a matcher that finds nothing"

doctor_fixture_run orchid-inv15-late-git
doctor_late_out="$(cat "$DOCTOR_FIXTURE_STREAM")"
assert_match '^WARN: unattended trust' "$doctor_late_out" \
  "INV-15: the late-Git fixture must reach its verdict line too, or the two fixtures differ in more than the one line whose position is the point"
assert_match 'trace: built-in: git' "$doctor_late_out" \
  "INV-15: the late-Git fixture must actually spend its Git — if GIT_TRACE observed nothing here, the RED case above and the shipped run's clean result are both measurements of an unobserved run"
doctor_late_violations="$(doctor_git_before_denial "$doctor_late_out")"
[ -z "$doctor_late_violations" ] \
  || fail "INV-15: the late-Git fixture was reported ($doctor_late_violations) — it spends the IDENTICAL query one line later, so a matcher that flags it is flagging the presence of Git rather than its position, and would flag the shipped doctor for the gate's own comparison"
green_case "the identical query, moved to the line after the verdict, was left alone by the same matcher — and it really did run, observed in the same trace — so what is being detected is a target-repository query that PRECEDES the denial, not a run that touches Git at all"

# Section 4's line-order scan over libexec/orchid-doctor is deliberately kept
# alongside all of this. It says less, and it says it about the file rather
# than about a run -- but it is the one check that still speaks if somebody
# adds a THIRD pre-report call to doctor tomorrow whose Git the two runs above
# happen not to see because that call spends none in this fixture.

# ---------------------------------------------------------------------------
# THE SECOND SELF-HOSTED ENTRY POINT: `orchid trust show`.
#
# Doctor is not the only verb whose target can be Orchid's own checkout, and it
# is not the one most often pointed at it. `orchid trust show <repo>` takes its
# target from the operator's own argument, and the repository an operator most
# often asks that question about is the Orchid installation a scheduled run
# would execute out of. There ORCHID_ROOT and the target are ONE directory, so
# the stale-root gate's `git diff --cached` against the root is a query against
# the target -- and the unattended-trust contract forbids a target query before
# an acknowledgement for the target has been looked for.
#
# That is why the arm now calls unattended_trust_inspect first, fires the gate
# second, and renders third. Section 8 already runs both edges of the gate on
# this arm, but it runs them with the root and the target as DIFFERENT
# directories, which is the environment in which firing first is harmless and
# therefore the environment in which this defect is invisible -- the same shape
# as the blind spot lesson L036 was paid for, one verb over.
#
# Three runs, on the same self-hosted fixture the doctor runs above use.

# RUN THREE: the contract's own case -- the target is unacknowledged, and the
# gate is armed. The machine-local lookup must be over before the gate's query,
# and the report must not be produced at all.
TRUST_SELFHOST_STREAM="$DOCTOR_PROOF/trust-show-armed.stream"
doctor_traced_run "$TRUST_SELFHOST_STREAM" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT='' \
  "$DOCTOR_ROOT/libexec/orchid-trust" show "$DOCTOR_ROOT"
trust_selfhost_rc="$DOCTOR_RUN_RC"
trust_selfhost_out="$(cat "$TRUST_SELFHOST_STREAM")"
assert_eq 1 "$trust_selfhost_rc" \
  "INV-15: 'orchid trust show' asked about the very checkout it is running from, that checkout being stale, must refuse (got rc=$trust_selfhost_rc: $trust_selfhost_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_selfhost_out" \
  "INV-15: ...and it must be the stale-root refusal, not some other failure of the fixture"
assert_match 'libexec/orchid-version' "$trust_selfhost_out" \
  "INV-15: the refusal must name the staged kernel path — the gate is not merely reached on this arm in the self-hosted case, it ran and it SAW something"
case "$trust_selfhost_out" in
  *'binding_state:'*)
    fail "INV-15: the refused self-hosted lookup printed its report anyway. That report is the account of whether an unattended run may execute here, produced BY the pre-merge code whose staleness is the finding, and an operator acts on it — so on this arm the gate is reached after the answer it was supposed to precede" ;;
esac
trust_selfhost_first_git="$(first_traced_git "$trust_selfhost_out")"
trust_selfhost_first_git="${trust_selfhost_first_git//\'/}"
[ -n "$trust_selfhost_first_git" ] \
  || fail "INV-15: the refused self-hosted lookup spent no observable Git at all, though it cannot have refused without comparing this root's index against HEAD — so this is a run that spent nothing where it must have spent something, and the claim below about WHICH Git ran first would be a claim about an unobserved run"
case "$trust_selfhost_first_git" in
  *"diff --cached"*) ;;
  *) fail "INV-15: the FIRST Git the self-hosted lookup spent was 'git $trust_selfhost_first_git', not the stale-root gate's own index comparison. With an empty machine-local store the trust lookup is supposed to reach its denial without invoking Git at all, so anything ahead of the gate here is a target-repository query made before any acknowledgement had been looked for" ;;
esac
red_case "the shipped 'orchid trust show', asked about the one stale integration checkout it is itself running from with no acknowledgement on record, refused with its staged kernel path named, not one line of the report produced, and the stale-root gate's own index comparison as the first Git subprocess of the entire run"

# RUN FOUR: the same target and the same empty store, with the gate stood down
# by its one documented override. The refusal is what hides the ordering, so
# standing it down is what makes the denial itself observable -- and what it
# must show is a denial reached having spent no Git whatsoever.
TRUST_SELFHOST_OPEN="$DOCTOR_PROOF/trust-show-open.stream"
doctor_traced_run "$TRUST_SELFHOST_OPEN" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT=1 \
  "$DOCTOR_ROOT/libexec/orchid-trust" show "$DOCTOR_ROOT"
trust_open_rc="$DOCTOR_RUN_RC"
trust_open_out="$(cat "$TRUST_SELFHOST_OPEN")"
assert_eq 0 "$trust_open_rc" \
  "INV-15: with the stale-root gate stood down, the self-hosted lookup must run to its report (got rc=$trust_open_rc: $trust_open_out)"
assert_match '^unattended trust: untrusted' "$trust_open_out" \
  "INV-15: ...and it must be the denial, so there is a denial for the ordering below to be measured against. Anything else means this store is not empty and this run is answering a different question"
trust_open_violations="$(git_before_verdict "$trust_open_out" "$TRUST_SHOW_VERDICT_ERE")"
[ -z "$trust_open_violations" ] \
  || fail "INV-15: the self-hosted lookup spent Git before its unattended-trust denial was rendered ($trust_open_violations). The root and the target are the same checkout here, so that is a target-repository query made before any acknowledgement for it had been looked for — and it is invisible in every other environment, because everywhere else those two are different directories"
# Stronger than the absence above, and worth stating separately: this run does
# not merely reach its denial before Git, it reaches it having spent NO Git.
# The observer that would have seen one was witnessed at the top of this
# section, and the matcher that would have reported one is demonstrated on the
# two fixtures below, so this emptiness is a measured absence rather than an
# unobserved run.
if grep -qF 'trace: built-in: git' <<<"$trust_open_out"; then
  fail "INV-15: the self-hosted lookup spent a Git subprocess somewhere in a run whose whole job was to say 'no acknowledgement on record'. With no identity-keyed candidate the inspection is documented to invoke no Git, and here the repository it would be invoking it against is the unacknowledged target itself"
fi
green_case "the same shipped lookup, on the same self-hosted target with the same empty machine-local store and the gate stood down by its documented override, rendered its denial having spent no Git subprocess whatsoever — so the denial really is reached with no target-repository Git, and the refusal above is that ordering being enforced rather than inherited"

# RUN FIVE: the ordering itself, made observable.
#
# Runs three and four cannot tell the two orderings apart on their own, and
# saying so is the point of this run. With an EMPTY store the machine-local
# lookup spends nothing, so "the gate's query came first" and "the lookup came
# first and cost nothing" leave an identical trace. The lookup only acquires a
# position an observer can read when it has a record to resolve -- because THEN
# it walks the target's history, and that walk is Git.
#
# So this run acknowledges the fixture first, out of a root that is not stale,
# into a store of its own. The shipped lookup must then spend the walk's Git
# BEFORE the gate's index comparison, and must still refuse, and must still
# print nothing. Its RED twin is the previous ordering, run in the identical
# environment.
make_scratch TRUST_SELFHOST_HOME
trust_selfhost_ack_rc=0
trust_selfhost_ack_out="$(env -u ORCHID_REPO -u ORCHID_EPOCH \
  HOME="$TRUST_SELFHOST_HOME" ORCHID_ALLOW_STALE_ROOT='' \
  "$REPO_ROOT/bin/orchid" trust unattended "$DOCTOR_ROOT" \
  --reason "INV-15 self-hosted lookup ordering fixture" 2>&1)" \
  || trust_selfhost_ack_rc=$?
assert_eq 0 "$trust_selfhost_ack_rc" \
  "INV-15: this checkout's own kernel must be able to acknowledge the self-hosted fixture (got rc=$trust_selfhost_ack_rc: $trust_selfhost_ack_out). Without a record on file the lookup below spends no Git, and the ordering this run exists to observe has nothing to be read off"

# And the record must be one this lookup really resolves, established with the
# gate stood down before the gate is armed against it. Both halves matter: a
# record the lookup rejected early would leave the walk unspent, and then the
# "the lookup's Git came first" reading below would be a reading of a run in
# which the lookup had no Git to come first with. The Git this run traces is
# permitted -- an acknowledgement WAS found, which is exactly the condition
# that licenses target work -- so the pre-verdict matcher is deliberately not
# pointed at this stream.
TRUST_ORDER_OPEN="$DOCTOR_PROOF/trust-show-acked-open.stream"
doctor_traced_run "$TRUST_ORDER_OPEN" \
  HOME="$TRUST_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ALLOW_STALE_ROOT=1 \
  "$DOCTOR_ROOT/libexec/orchid-trust" show "$DOCTOR_ROOT"
trust_order_open_rc="$DOCTOR_RUN_RC"
trust_order_open_out="$(cat "$TRUST_ORDER_OPEN")"
assert_eq 0 "$trust_order_open_rc" \
  "INV-15: with the gate stood down, the self-hosted lookup must report on the acknowledgement just written (got rc=$trust_order_open_rc: $trust_order_open_out)"
assert_match '^unattended trust: trusted' "$trust_order_open_out" \
  "INV-15: ...and it must RESOLVE that record. If this lookup denies, the walk that gives the machine-local decision an observable position never happens, and the ordering measured below would be measured on a lookup that spent nothing"
assert_match 'trace: built-in: git' "$trust_order_open_out" \
  "INV-15: ...and resolving it must be observed to cost Git. Root verification is never cached or reused, so a trusted verdict here that traced nothing means this instrumentation cannot see the lookup's own subprocesses, and the ordering below would be read off half a stream"

TRUST_ORDER_GREEN="$DOCTOR_PROOF/trust-show-acked.stream"
doctor_traced_run "$TRUST_ORDER_GREEN" \
  HOME="$TRUST_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ALLOW_STALE_ROOT='' \
  "$DOCTOR_ROOT/libexec/orchid-trust" show "$DOCTOR_ROOT"
trust_order_green_rc="$DOCTOR_RUN_RC"
trust_order_green_out="$(cat "$TRUST_ORDER_GREEN")"
assert_eq 1 "$trust_order_green_rc" \
  "INV-15: an acknowledgement does not stand the stale-root gate down — the self-hosted lookup must still refuse (got rc=$trust_order_green_rc: $trust_order_green_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_order_green_out" \
  "INV-15: ...and it must still be the stale-root refusal"
case "$trust_order_green_out" in
  *'binding_state:'*)
    fail "INV-15: the refused self-hosted lookup printed its report anyway once a record existed for it, so what run three showed was an empty store having nothing to say rather than the gate suppressing the report" ;;
esac
# Quote-stripped before matching, for the reason run one's absence check
# strips: older Git quotes each argument in its trace and newer Git does not,
# so a raw match on the two words would silently find nothing on the older
# spelling and this assertion would pass by failing to look.
trust_order_green_bare="${trust_order_green_out//\'/}"
assert_match 'diff --cached' "$trust_order_green_bare" \
  "INV-15: this run must contain the gate's own index comparison — it refused, so the gate fired, and if that query is not in the trace then the ordering read off this stream below is being read off an incomplete observation"
trust_order_green_first="$(first_traced_git "$trust_order_green_out")"
trust_order_green_first="${trust_order_green_first//\'/}"
case "$trust_order_green_first" in
  *"diff --cached"*)
    fail "INV-15: the FIRST Git the self-hosted lookup spent was the stale-root gate's own index comparison ('git $trust_order_green_first'), even though a machine-local record for this target existed and resolving it costs Git. The gate is therefore querying the target repository ahead of the lookup that decides whether this target has been acknowledged at all — which is the whole of the contract, and it is observable in no environment but this one" ;;
  '')
    fail "INV-15: the self-hosted lookup spent no observable Git at all, though it both resolved a record and refused at the gate — so this stream is not showing what this run spent" ;;
esac
green_case "the shipped 'orchid trust show', asked about the self-hosted checkout with an acknowledgement on record, spent the machine-local lookup's own Git first and the stale-root gate's index comparison only after it — so the trust decision really does precede the gate's target query, observed on a run rather than read off the file — and it still refused and still printed nothing"

# The RED twin: the previous ordering, in the identical environment, as a
# fixture at the shipped verb's own kind of path. `__orchid_entry_defer_restore`
# is set for the reason libexec/orchid-trust sets it -- so lib/common.sh ARMS
# the guard and leaves the firing to the file, which is what makes the position
# of the explicit call the thing under test rather than a source-time fire.
{ printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="${ORCHID_REPO:-$PWD}"\n'
  printf 'orchid_root_stale_gate\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'unattended_trust_show_loaded\n'
} > "$DOCTOR_FIXTURES/orchid-inv15-trust-gate-first"
TRUST_ORDER_RED="$DOCTOR_PROOF/trust-show-gate-first.stream"
doctor_traced_run "$TRUST_ORDER_RED" \
  HOME="$TRUST_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ROOT="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT='' \
  /bin/bash "$DOCTOR_FIXTURES/orchid-inv15-trust-gate-first"
trust_order_red_out="$(cat "$TRUST_ORDER_RED")"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_order_red_out" \
  "INV-15: the gate-first fixture must reach the same refusal the shipped verb reaches, or it differs from it in more than the one line whose position is the point"
trust_order_red_first="$(first_traced_git "$trust_order_red_out")"
trust_order_red_first="${trust_order_red_first//\'/}"
case "$trust_order_red_first" in
  *"diff --cached"*) ;;
  *) fail "INV-15: a trust-shaped entry point that fires the stale-root gate ABOVE its machine-local lookup was expected to spend the gate's index comparison first, and spent 'git $trust_order_red_first' instead — so the GREEN result above is not this measurement discriminating between the two orderings, and would have passed for either of them" ;;
esac
red_case "the same lookup with the gate moved above it, run in the identical environment against the identical acknowledged self-hosted target, spent the gate's index comparison as its first Git — so the previous ordering is detected here, and the shipped verb's result is a position being measured rather than a trace that looks the same whatever the file says"

# The RED and GREEN twins for the VERDICT matcher on this arm, exactly as the
# doctor pair above does it for doctor's: the same two fixtures, differing in
# the position of one target query, with their stderr discarded the way the
# kernel discards its own.
{ printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="${ORCHID_REPO:-$PWD}"\n'
  printf 'git -C "$repo" rev-list --max-count=1 HEAD >/dev/null 2>/dev/null\n'
  printf 'unattended_trust_show "$repo"\n'
} > "$DOCTOR_FIXTURES/orchid-inv15-trust-early-git"
{ printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="${ORCHID_REPO:-$PWD}"\n'
  printf 'unattended_trust_show "$repo"\n'
  printf 'git -C "$repo" rev-list --max-count=1 HEAD >/dev/null 2>/dev/null\n'
} > "$DOCTOR_FIXTURES/orchid-inv15-trust-late-git"

doctor_fixture_run orchid-inv15-trust-early-git
trust_early_out="$(cat "$DOCTOR_FIXTURE_STREAM")"
assert_match '^unattended trust: ' "$trust_early_out" \
  "INV-15: the early-Git lookup fixture must still reach its verdict line (got: $trust_early_out) — a fixture that died before rendering anything would be reported for the wrong reason"
assert_match 'git-before-denial: .*rev-list' \
  "$(git_before_verdict "$trust_early_out" "$TRUST_SHOW_VERDICT_ERE")" \
  "INV-15: a lookup-shaped entry point that queries its target repository before rendering its unattended-trust verdict must be reported, and reported with the query it made"
red_case "a lookup-shaped fixture that really did run 'git rev-list' against its target before rendering its verdict was RUN, and the same matcher run four is judged by named that query — so run four's silence is detection rather than a matcher pointed at a verdict line it cannot find"

doctor_fixture_run orchid-inv15-trust-late-git
trust_late_out="$(cat "$DOCTOR_FIXTURE_STREAM")"
assert_match '^unattended trust: ' "$trust_late_out" \
  "INV-15: the late-Git lookup fixture must reach its verdict line too, or the two fixtures differ in more than the one line whose position is the point"
assert_match 'trace: built-in: git' "$trust_late_out" \
  "INV-15: the late-Git lookup fixture must actually spend its Git — if GIT_TRACE observed nothing here, the RED case above and run four's clean result are both measurements of an unobserved run"
trust_late_violations="$(git_before_verdict "$trust_late_out" "$TRUST_SHOW_VERDICT_ERE")"
[ -z "$trust_late_violations" ] \
  || fail "INV-15: the late-Git lookup fixture was reported ($trust_late_violations) — it spends the IDENTICAL query one line later, so a matcher that flags it is flagging the presence of Git rather than its position"
green_case "the identical query, moved to the line after the lookup's verdict, was left alone by the same matcher — and it really did run, observed in the same trace — so what run four measures is a target query that PRECEDES the denial, not a run that touches Git at all"

# ---------------------------------------------------------------------------
# THE THIRD SELF-HOSTED ARM: `orchid trust revoke`.
#
# The arm no run in this file used to reach, and the arm that used to fire the
# gate above everything on the argument that it had no machine-local decision
# to put first. It has one. Revocation is built WITHOUT inspection -- so that
# removal stays available on a target inspection cannot complete on -- but the
# identity derivation underneath it still decides which record this run would
# unlink, and that derivation is the bounded, no-Git, no-scratch-file half the
# availability argument is about. So it now runs ahead of the gate, exactly as
# the lookup arm's does.
#
# WHAT CAN BE READ OFF A TRACE HERE, AND WHAT CANNOT. Run five could measure
# the lookup arm's ordering directly, because with a record on file the lookup
# WALKS the target's history and that walk is Git. Revocation never walks
# anything -- that is the whole of its availability guarantee -- so its
# machine-local half spends no Git in any environment, and no trace can place
# it relative to the gate. Saying so is better than pretending otherwise, and
# what IS measurable is stated instead, in two halves:
#
#   * The arm spends no target query of its own, at all (run seven). So in the
#     armed run the gate's own index comparison is the only Git there is, and
#     nothing precedes it (run six) -- which is the substance the contract asks
#     of this arm, since there is no other query for an acknowledgement lookup
#     to have to precede.
#   * The ORDER is pinned on the report edge instead of the Git edge (runs
#     eight and nine): an underivable identity is a diagnosis ABOUT THE TARGET,
#     and out of a stale root it must not be produced. If the derivation's
#     failure were still allowed to speak, the arm would be answering out of
#     the pre-merge tree at precisely the point the gate was supposed to stop
#     it -- the same defect `show` had, in the one place this arm can still
#     print something.
#
# Runs six and seven consume the acknowledgement run five wrote, so they come
# after it: run seven removes it.
trust_revoke_record=""
while IFS= read -r trust_revoke_line; do
  case "$trust_revoke_line" in
    'record: '*)
      [ -n "$trust_revoke_record" ] \
        || trust_revoke_record="${trust_revoke_line#record: }" ;;
  esac
done <<<"$trust_order_open_out"
if [ -z "$trust_revoke_record" ] || [ ! -f "$trust_revoke_record" ]; then
  fail "INV-15: the self-hosted acknowledgement run five wrote is not on disk at a path this section could read back (got '$trust_revoke_record'), so the revocation runs below would be removing nothing and their evidence would be an absence that was already there"
fi

# RUN SIX: the armed gate, the self-hosted target, an acknowledgement on file.
TRUST_REVOKE_ARMED="$DOCTOR_PROOF/trust-revoke-armed.stream"
doctor_traced_run "$TRUST_REVOKE_ARMED" \
  HOME="$TRUST_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ALLOW_STALE_ROOT='' \
  "$DOCTOR_ROOT/libexec/orchid-trust" revoke "$DOCTOR_ROOT"
trust_revoke_armed_rc="$DOCTOR_RUN_RC"
trust_revoke_armed_out="$(cat "$TRUST_REVOKE_ARMED")"
assert_eq 1 "$trust_revoke_armed_rc" \
  "INV-15: 'orchid trust revoke' asked about the very checkout it is running from, that checkout being stale, must refuse (got rc=$trust_revoke_armed_rc: $trust_revoke_armed_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_revoke_armed_out" \
  "INV-15: ...and it must be the stale-root refusal, not some other failure of the fixture"
assert_match 'libexec/orchid-version' "$trust_revoke_armed_out" \
  "INV-15: the refusal must name the staged kernel path — the gate is not merely reached on this arm, it ran and it SAW something"
if grep -qF 'unattended trust revoked' <<<"$trust_revoke_armed_out"; then
  fail "INV-15: the refused revocation reported a removal anyway, so the gate on this arm sits below the durable mutation it is supposed to precede"
fi
[ -f "$trust_revoke_record" ] \
  || fail "INV-15: the refused revocation removed the machine-local acknowledgement anyway. Removal is a durable mutation of the machine-local store, and which record it resolves is decided by the identity derivation the stale tree carries — a gate reached after it guards nothing"
trust_revoke_armed_first="$(first_traced_git "$trust_revoke_armed_out")"
trust_revoke_armed_first="${trust_revoke_armed_first//\'/}"
[ -n "$trust_revoke_armed_first" ] \
  || fail "INV-15: the refused revocation spent no observable Git at all, though it cannot have refused without comparing this root's index against HEAD — so the claim below about WHICH Git ran first would be a claim about an unobserved run"
case "$trust_revoke_armed_first" in
  *"diff --cached"*) ;;
  *) fail "INV-15: the FIRST Git the self-hosted revocation spent was 'git $trust_revoke_armed_first', not the stale-root gate's own index comparison. ORCHID_ROOT and the target are one unacknowledged-until-looked-up checkout here, so anything ahead of the gate is a target-repository query this arm has no reason to make at all" ;;
esac
red_case "the shipped 'orchid trust revoke', asked about the stale integration checkout it is itself running from with an acknowledgement on file, refused with its staged kernel path named, removed nothing, reported nothing, and spent the stale-root gate's own index comparison as the first Git subprocess of the entire run"

# RUN SEVEN: the same target and the same record, with the gate stood down.
# The removal really does happen -- so the record's survival above is caused --
# and the whole arm is observed to spend NO Git, which is what makes the single
# query in run six the gate's own rather than one among several.
TRUST_REVOKE_OPEN="$DOCTOR_PROOF/trust-revoke-open.stream"
doctor_traced_run "$TRUST_REVOKE_OPEN" \
  HOME="$TRUST_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ALLOW_STALE_ROOT=1 \
  "$DOCTOR_ROOT/libexec/orchid-trust" revoke "$DOCTOR_ROOT"
trust_revoke_open_rc="$DOCTOR_RUN_RC"
trust_revoke_open_out="$(cat "$TRUST_REVOKE_OPEN")"
assert_eq 0 "$trust_revoke_open_rc" \
  "INV-15: with the stale-root gate stood down, the self-hosted revocation must run (got rc=$trust_revoke_open_rc: $trust_revoke_open_out)"
assert_match '^unattended trust revoked: ' "$trust_revoke_open_out" \
  "INV-15: ...and it must report the removal, or the record's survival in run six is a removal that never happens anyway"
[ ! -e "$trust_revoke_record" ] \
  || fail "INV-15: the stood-down revocation left the acknowledgement record on disk, so run six's finding that the refusal preserved it is not evidence of anything the gate did"
if grep -qF 'trace: built-in: git' <<<"$trust_revoke_open_out"; then
  fail "INV-15: the self-hosted revocation spent a Git subprocess. This arm is documented to remove an acknowledgement on the bounded identity derivation alone — no version, ref, history, object or scratch check — and here the repository it would be querying is the target itself. It also means run six's single traced query is not necessarily the gate's own"
fi
green_case "the same revocation, on the same self-hosted target with the gate stood down by its documented override, removed the acknowledgement it left standing above and spent no Git subprocess whatsoever — so the removal really does happen, and the arm's own machine-local half makes no target query for the gate's comparison to have to follow"

# RUNS EIGHT AND NINE: the ordering, pinned on the one thing this arm can still
# print out of a stale root. A target whose identity cannot be derived is the
# only route on which revocation says anything before the gate could have
# stopped it, and what it says is a verdict about that target.
TRUST_REVOKE_NOID="$DOCTOR_PROOF/revoke-not-a-worktree"
mkdir -p "$TRUST_REVOKE_NOID"
TRUST_REVOKE_NOID_ARMED="$DOCTOR_PROOF/trust-revoke-noid-armed.stream"
doctor_traced_run "$TRUST_REVOKE_NOID_ARMED" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT='' \
  "$DOCTOR_ROOT/libexec/orchid-trust" revoke "$TRUST_REVOKE_NOID"
trust_revoke_noid_rc="$DOCTOR_RUN_RC"
trust_revoke_noid_out="$(cat "$TRUST_REVOKE_NOID_ARMED")"
assert_eq 1 "$trust_revoke_noid_rc" \
  "INV-15: revocation of an underivable target out of a stale root must refuse (got rc=$trust_revoke_noid_rc: $trust_revoke_noid_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$trust_revoke_noid_out" \
  "INV-15: ...and it must be the stale-root refusal"
if grep -qF 'cannot revoke unattended trust' <<<"$trust_revoke_noid_out"; then
  fail "INV-15: the refused revocation printed its own diagnosis of the target anyway. That sentence is an answer about this repository produced by the pre-merge tree, on the one route this arm can answer at all — so the gate is reached after the report rather than before it"
fi
red_case "the shipped revocation, pointed out of a stale self-hosted root at a target whose identity it cannot derive, refused at the gate and did not produce the diagnosis of that target it would otherwise have produced"

TRUST_REVOKE_NOID_OPEN="$DOCTOR_PROOF/trust-revoke-noid-open.stream"
doctor_traced_run "$TRUST_REVOKE_NOID_OPEN" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT=1 \
  "$DOCTOR_ROOT/libexec/orchid-trust" revoke "$TRUST_REVOKE_NOID"
trust_revoke_noid_open_rc="$DOCTOR_RUN_RC"
trust_revoke_noid_open_out="$(cat "$TRUST_REVOKE_NOID_OPEN")"
assert_eq 1 "$trust_revoke_noid_open_rc" \
  "INV-15: with the gate stood down, revocation of an underivable target must still fail on its own account (got rc=$trust_revoke_noid_open_rc: $trust_revoke_noid_open_out)"
assert_match 'cannot revoke unattended trust' "$trust_revoke_noid_open_out" \
  "INV-15: ...and it must produce the diagnosis the run above did not — otherwise that absence is a sentence this fixture never reaches, and the RED case above proves nothing about where the gate sits"
green_case "the identical revocation of the identical underivable target, differing only in the gate being stood down, produced that diagnosis — so the absence above is the gate suppressing an answer that really is given, not a route this arm never takes"

# Section 4's line-order scan is deliberately NOT extended to
# libexec/orchid-trust, and the reason is worth writing down rather than
# leaving as an omission somebody re-derives. That scan compares the FIRST
# occurrence of each of the two calls in a file, which is the right question
# for doctor because doctor makes each call exactly once on a straight line.
# `orchid trust` fires the gate PER SUBCOMMAND -- what the gate must sit
# between is per subcommand -- so its first orchid_root_stale_gate is the
# acknowledgement arm's, above the lookup arm's code entirely, and a
# first-occurrence comparison would report the shipped file for an ordering
# that is correct in every arm. The lookup arm's ordering is answered by run
# five instead, which is a stronger answer anyway: it is read off a run.

# ---------------------------------------------------------------------------
# THE FOURTH SELF-HOSTED ENTRY POINT, AND THE ONE WHOSE ORDERING IS
# ARM-CONDITIONAL: `orchid status`.
#
# Section 4's line-order derivation counts libexec/orchid-status among the
# entry points carrying BOTH a machine-local trust decision and a stale-root
# firing site, and reads its two lines in the right order. What a line-order
# scan cannot see is that only ONE ARM of that file executes the decision.
# `status --explain` inspects unattended trust and then fires the gate at its
# operator-PATH restore. PLAIN `status` -- the invocation an operator types a
# hundred times more often, and the one a `--explain` reader has usually
# already run -- inspects nothing at all, and reaches the identical restore
# with no acknowledgement lookup anywhere above it. So the FILE reads as
# "decision first" while its common arm makes no decision to put first, and a
# derivation that stopped there would be describing an arm rather than a run.
# The two are told apart here by running both, in the environment where the
# difference is observable at all: ORCHID_REPO and ORCHID_ROOT one checkout.
#
# WHAT IS PROVED OF EACH ARM, AND WHY THEY ARE NOT THE SAME CLAIM.
#
#   * PLAIN status (runs ten and eleven). There is no lookup here for a gate
#     to pre-empt, so "the decision precedes the gate" is not a claim that can
#     be made about this arm and is not made -- stating it would be the
#     overclaim this section exists to replace. What must hold instead is
#     twofold: the gate's own index comparison is the FIRST Git subprocess of
#     the whole run, so nothing reached the target ahead of a refusal that
#     looked nothing up; and the refusal lands ahead of the report, because
#     every line of that report is read out of the checkout whose staleness is
#     the finding, and status is the surface an operator reads most.
#   * `status --explain` (runs twelve and thirteen), with an acknowledgement on
#     file so the lookup walks the target's history and therefore has a
#     position a trace can read: the lookup's Git must precede the gate's
#     comparison, exactly as run five requires of `orchid trust show`. With an
#     empty store the two orderings leave the identical trace, which is why
#     this arm is acknowledged first and the plain arm is not.
STATUS_ARM="$DOCTOR_ROOT/libexec/orchid-status"
[ -f "$STATUS_ARM" ] \
  || fail "INV-15: the self-hosted fixture carries no libexec/orchid-status, so the two arms below would be measured on a file that is not there"
chmod +x "$STATUS_ARM"

# RUN TEN: plain status, gate armed, the machine-local store empty -- which is
# not a condition this arm reads, and saying so is the point of run twelve.
STATUS_PLAIN_ARMED="$DOCTOR_PROOF/status-plain-armed.stream"
doctor_traced_run "$STATUS_PLAIN_ARMED" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT='' \
  "$STATUS_ARM"
status_plain_rc="$DOCTOR_RUN_RC"
status_plain_out="$(cat "$STATUS_PLAIN_ARMED")"
assert_eq 1 "$status_plain_rc" \
  "INV-15: plain 'orchid status', run out of a stale self-hosted checkout with that same checkout as its target, must refuse (got rc=$status_plain_rc: $status_plain_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$status_plain_out" \
  "INV-15: ...and it must be the stale-root refusal, not some other failure of the fixture"
assert_match 'libexec/orchid-version' "$status_plain_out" \
  "INV-15: the refusal must name the staged kernel path — the gate is not merely reached on the plain arm, it ran and it SAW something"
if grep -Eq '^(run_status:|== tasks)' <<<"$status_plain_out"; then
  fail "INV-15: the refused plain status printed its report anyway. Every line of that report is read out of the very checkout whose staleness is the finding, and status is the surface an operator reads most often — so the gate on this arm would be sitting after the report it is supposed to precede"
fi
status_plain_first="$(first_traced_git "$status_plain_out")"
status_plain_first="${status_plain_first//\'/}"
[ -n "$status_plain_first" ] \
  || fail "INV-15: the refused plain status spent no observable Git at all, though it cannot have refused without comparing this root's index against HEAD — so the claim below about WHICH Git ran first would be a claim about an unobserved run"
case "$status_plain_first" in
  *"diff --cached"*) ;;
  *) fail "INV-15: the FIRST Git subprocess plain status spent was 'git $status_plain_first', not the stale-root gate's own index comparison. This arm looks up no acknowledgement at all, so anything ahead of the gate is a target-repository query made by a run that has decided nothing whatever about this target — and here the target and ORCHID_ROOT are one unacknowledged checkout" ;;
esac
red_case "the shipped plain 'orchid status' — the arm that makes no unattended-trust decision at all, so its gate has nothing to be ordered behind — asked about the stale integration checkout it is itself running from refused with the staged kernel path named, printed not one line of its report, and spent the stale-root gate's own index comparison as the first Git subprocess of the entire run"

# RUN ELEVEN: the same arm, the same checkout, the same store, with the gate
# stood down by the one documented override. The report really is produced --
# so its absence above is caused rather than inherited from a fixture status
# has nothing to say about.
STATUS_PLAIN_OPEN="$DOCTOR_PROOF/status-plain-open.stream"
doctor_traced_run "$STATUS_PLAIN_OPEN" \
  HOME="$DOCTOR_HOME" ORCHID_REPO="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT=1 \
  "$STATUS_ARM"
status_plain_open_rc="$DOCTOR_RUN_RC"
status_plain_open_out="$(cat "$STATUS_PLAIN_OPEN")"
assert_match '^run_status: ' "$status_plain_open_out" \
  "INV-15: with the stale-root gate stood down, plain status must print its run_status line (rc=$status_plain_open_rc) — without it, run ten's silence is a report this fixture never reaches rather than one the gate suppressed"
assert_match '^== tasks' "$status_plain_open_out" \
  "INV-15: ...and it must get past that line into the report body, or the absence run ten measured is bounded to a single line rather than to the report"
green_case "the identical plain status, on the identical self-hosted checkout, differing only in the gate being stood down, printed the run_status line and the report body beneath it — so the refusal above is the gate suppressing a report that really is produced, not an arm that prints nothing here anyway"

# RUNS TWELVE AND THIRTEEN: the --explain arm, which does make the decision,
# with an acknowledgement on file so that decision costs Git and therefore has
# a position. Its own store, written out of a root that is not stale.
make_scratch STATUS_SELFHOST_HOME
status_ack_rc=0
status_ack_out="$(env -u ORCHID_REPO -u ORCHID_EPOCH \
  HOME="$STATUS_SELFHOST_HOME" ORCHID_ALLOW_STALE_ROOT='' \
  "$REPO_ROOT/bin/orchid" trust unattended "$DOCTOR_ROOT" \
  --reason "INV-15 self-hosted status ordering fixture" 2>&1)" \
  || status_ack_rc=$?
assert_eq 0 "$status_ack_rc" \
  "INV-15: this checkout's own kernel must be able to acknowledge the self-hosted fixture for the explain arm (got rc=$status_ack_rc: $status_ack_out). Without a record on file the lookup below spends no Git, and the ordering this run exists to observe has nothing to be read off"

# The record must be one this arm really resolves, established with the gate
# stood down before the gate is armed against it: a record the lookup rejected
# early would leave the walk unspent, and the ordering read below would be read
# off a lookup that had no Git to come first with.
STATUS_EXPLAIN_OPEN="$DOCTOR_PROOF/status-explain-open.stream"
doctor_traced_run "$STATUS_EXPLAIN_OPEN" \
  HOME="$STATUS_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ALLOW_STALE_ROOT=1 \
  "$STATUS_ARM" --explain
status_explain_open_rc="$DOCTOR_RUN_RC"
status_explain_open_out="$(cat "$STATUS_EXPLAIN_OPEN")"
assert_match '^unattended: allowed' "$status_explain_open_out" \
  "INV-15: with the gate stood down, 'status --explain' must RESOLVE the acknowledgement just written (rc=$status_explain_open_rc: $status_explain_open_out). If this arm denies, the history walk that gives the machine-local decision an observable position never happens"
assert_match 'trace: built-in: git' "$status_explain_open_out" \
  "INV-15: ...and resolving it must be observed to cost Git. Root verification is never cached or reused, so an allowed verdict here that traced nothing means this instrumentation cannot see the lookup's own subprocesses, and the ordering below would be read off half a stream"

STATUS_EXPLAIN_ARMED="$DOCTOR_PROOF/status-explain-armed.stream"
doctor_traced_run "$STATUS_EXPLAIN_ARMED" \
  HOME="$STATUS_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ALLOW_STALE_ROOT='' \
  "$STATUS_ARM" --explain
status_explain_rc="$DOCTOR_RUN_RC"
status_explain_out="$(cat "$STATUS_EXPLAIN_ARMED")"
assert_eq 1 "$status_explain_rc" \
  "INV-15: an acknowledgement does not stand the stale-root gate down — 'status --explain' on the self-hosted checkout must still refuse (got rc=$status_explain_rc: $status_explain_out)"
assert_match 'refusing to run: the checkout orchid itself runs from' "$status_explain_out" \
  "INV-15: ...and it must still be the stale-root refusal"
if grep -Eq '^(run_status:|== tasks|unattended: )' <<<"$status_explain_out"; then
  fail "INV-15: the refused 'status --explain' printed its report anyway — the run_status line, the task table, or the provenance line an operator reads the gate's own verdict off. All three are rendered out of the checkout whose staleness is the finding, and the provenance line is the worst of them: it is this run's account of its own trustworthiness"
fi
status_explain_bare="${status_explain_out//\'/}"
assert_match 'diff --cached' "$status_explain_bare" \
  "INV-15: this run must contain the gate's own index comparison — it refused, so the gate fired, and if that query is not in the trace the ordering read off this stream is being read off an incomplete observation"
status_explain_first="$(first_traced_git "$status_explain_out")"
status_explain_first="${status_explain_first//\'/}"
case "$status_explain_first" in
  *"diff --cached"*)
    fail "INV-15: the FIRST Git 'status --explain' spent was the stale-root gate's own index comparison ('git $status_explain_first'), even though a machine-local record for this target existed and resolving it costs Git. The gate is therefore querying the target repository ahead of the lookup that decides whether this target has been acknowledged at all" ;;
  '')
    fail "INV-15: 'status --explain' spent no observable Git at all, though it both resolved a record and refused at the gate — so this stream is not showing what this run spent" ;;
esac
green_case "the shipped 'orchid status --explain', asked about the self-hosted checkout with an acknowledgement on record, spent the machine-local lookup's own Git first and the stale-root gate's index comparison only after it — so on the ONE arm of this file that makes a trust decision, the decision really does precede the gate's target query, observed on a run rather than read off two line numbers — and it still refused and still printed nothing"

# The RED twin for that measurement, in the identical environment: the same two
# calls in the other order, at the shipped arm's own kind of path.
# `__orchid_entry_defer_restore` is set for the reason libexec/orchid-status
# sets it, so what is under test is the position of the firing call rather than
# a source-time fire.
{ printf '#!/usr/bin/env bash\n'
  printf 'set -uo pipefail\n'
  printf '__orchid_entry_defer_restore=1\n'
  printf 'source "$ORCHID_ROOT/lib/common.sh"\n'
  printf 'source "$ORCHID_ROOT/lib/trust.sh"\n'
  printf 'repo="${ORCHID_REPO:-$PWD}"\n'
  printf 'orchid_root_stale_gate\n'
  printf 'unattended_trust_inspect "$repo"\n'
  printf 'echo "run_status: (uninitialized)"\n'
} > "$DOCTOR_FIXTURES/orchid-inv15-status-gate-first"
STATUS_ORDER_RED="$DOCTOR_PROOF/status-gate-first.stream"
doctor_traced_run "$STATUS_ORDER_RED" \
  HOME="$STATUS_SELFHOST_HOME" ORCHID_REPO="$DOCTOR_ROOT" \
  ORCHID_ROOT="$DOCTOR_ROOT" ORCHID_ALLOW_STALE_ROOT='' \
  /bin/bash "$DOCTOR_FIXTURES/orchid-inv15-status-gate-first"
status_order_red_out="$(cat "$STATUS_ORDER_RED")"
assert_match 'refusing to run: the checkout orchid itself runs from' "$status_order_red_out" \
  "INV-15: the gate-first status fixture must reach the same refusal the shipped arm reaches, or it differs from it in more than the one line whose position is the point"
status_order_red_first="$(first_traced_git "$status_order_red_out")"
status_order_red_first="${status_order_red_first//\'/}"
case "$status_order_red_first" in
  *"diff --cached"*) ;;
  *) fail "INV-15: a status-shaped entry point that fires the stale-root gate ABOVE its machine-local lookup was expected to spend the gate's index comparison first, and spent 'git $status_order_red_first' instead — so the GREEN result above is not this measurement discriminating between the two orderings, and would have passed for either of them" ;;
esac
red_case "the same explain-arm ordering with the gate moved above the lookup, run in the identical environment against the identical acknowledged self-hosted target, spent the gate's index comparison as its first Git — so the shipped arm's result is a position being measured rather than a trace that looks the same whatever the file says"

# ===========================================================================
# 10 -- the boundaries of what any of this proves.
# ===========================================================================
not_tested "gate-omission-beyond-the-four-families" \
  "enforcement gates outside the four this file derives — the static sections of scripts/ci-local.sh, the files tests/helpers.sh enrols in the red-case rule (by location under tests/inv/ and by name in PROOF_ENROLLED_FILES), the stale-root guard's reach across every shipped file that loads lib/common.sh, and the early-exit matcher shape across the shipped kernel, the bundled plugins and those same gate files. A gate that is none of those (a check living only inside one verb, a hook a plugin installs) is held to the same rule by review. What makes the four checkable is that each has a DISCOVERABLE membership: a banner, a glob plus the array beside it, a source line, a syntactic shape. Two of the four are now derived over an inventory that is WALKED rather than listed, so 'which directories does this look in' has stopped being a question anybody has to keep answering; the other two are bounded by tests/inv/ and by scripts/ci-local.sh, which are the files those gates live in. A new gate family belongs here the moment its membership becomes derivable"
not_tested "gate-reach-into-code-that-arms-nothing" \
  "shipped code that executes out of \$ORCHID_ROOT without loading lib/common.sh at all. Section 4's universe is every file in the shipped inventory that SOURCES the library — and that inventory is now a WALK of the tree (Git's tracked-plus-untracked set in a checkout, a filesystem walk in an extracted archive) rather than a list of directory families, with tests/ and Markdown the two declared exclusions, so a loader under a directory nobody has thought of is inside it — because sourcing the library is what arms the guard and the question this file asks is whether what was armed is fired. A helper that runs kernel code some other way — a plugin's notify sender that shells to the orchid dispatcher rather than sourcing it, a hook script, anything reached through a subprocess — arms nothing here, so it is neither reported nor cleared. The subprocess case is the benign half: whatever it invokes is itself in the universe and fires the gate on its own account. The case that is not covered is a file that reads and acts on \$ORCHID_ROOT's contents directly without loading the library, which no shipped file does today and which this derivation would not notice arriving"
not_tested "firing-site-reachability-within-an-entry-point" \
  "whether a firing site an entry point CONTAINS is actually REACHED on every route through that file, for every entry point but the six sections 4, 6, 8 and 9 execute. Section 4 is textual in that one respect by construction: it asks whether the file calls _orchid_entry_restore_operator_path or orchid_root_stale_gate, which a scan can answer, and not whether every path to that file's own work runs past the call -- or runs past it BEFORE that work -- which it cannot. (What section 4 no longer takes on trust is the OTHER half of that question, whether a call it found fires anything where the file lives: that is answered by running a stub at the file's own path out of a genuinely stale root, so a firing site that is inert at that location is reported rather than counted.) Section 6 answers both questions for runners/orchid-pump and runners/orchid-tick, section 8 for libexec/orchid-trust and for runners/orchid-service, and section 9 for libexec/orchid-doctor and for libexec/orchid-status — the latter on BOTH its arms, because its lookup runs only under --explain and plain status reaches the identical firing site having decided nothing, which is the one place a line-order reading of a file and a reading of its runs come apart — each by running the entry point and weighing its refusal against a side effect — a write, a report, or a verdict — that really does happen otherwise; that is six entry points out of the deferring set, and section 4 executes a sixth from OUTSIDE that set — install.sh, the top-level installer, run out of a genuinely stale root with the prefix symlink and the per-user plugin directory as the witnesses, because the only kernel check that file ever carried is its closing doctor run and that one is skipped in exactly the self-hosted shape this refusal is for. Section 6 is also where the ROUTE half of the question is put rather than only the file half: both scheduled runners answer an uninitialised, split-brain or finished repository above their trust gate and leave, and those routes had no fire on them at all, which no scan of either file could have said, because the call is in the text. All four of those verdicts are RUN, each on its own target: an uninitialised directory, a split-brain checkout built to trip a different predicate from the other two, and a finished run put to both runners. Three routes clearing a gate says nothing about a fourth, so none of them is argued from the others. For the rest it is answered structurally: every shipped deferring entry point calls its firing site unconditionally on the route to its own work, and runners/orchid-service -- the one that fires the gate itself rather than through the PATH restore, and the one that shipped this per-arm and had to be corrected -- now calls it on the straight-line path above its dispatch, so it has no ACTING arm that could forget; section 8 runs its status arm out of a stale root and requires the refusal to land ahead of the report, which is the half a scan of that file cannot answer. libexec/orchid-trust is the one that fires PER SUBCOMMAND, because what the gate must precede is per subcommand, and no ACTING arm of it is exempt any longer: the lookup arm carried an exemption for writing nothing durable, that exemption is gone, and section 8 executes both the acknowledgement, whose side effect is the record it writes, and the lookup, whose side effect is the report an operator acts on. What both files DO have above the call is the usage arm -- -h, --help, help, a bare invocation -- and that is the one route through either of them on which this gate does not fire. It is not left as an omission in one and a decision in the other: section 8 runs both verbs' usage arms out of the same stale root that refuses their acting arms, so the exemption is measured, bounded to the arm that resolves no target and reads no record, and identical in the two files. What is not tested is the claim UNDER it -- that a usage text can never carry anything an operator acts on about a repository -- which is an argument about the content of two here-documents rather than about an ordering, and belongs to review. Section 8 does not run the third arm, revocation; section 9 does, on the self-hosted target, and what is left untested there is narrower than the arm. Its ordering cannot be read off a trace: revocation walks no history by design, so its machine-local half — the bounded identity derivation that decides which record would be unlinked — spends no Git in any environment, and there is no position for an observer to measure. Section 9 measures the two halves that can be: the arm spends no target query of its own at all, so the gate's comparison is the only Git in a refused run and nothing precedes it; and the ORDER is pinned on the report edge instead, since an underivable identity is a diagnosis about the target and out of a stale root it must not be produced. What that leaves untested is the ordering between the derivation and the gate on the route where the derivation SUCCEEDS, which no instrumentation in this file can see. So a trust subcommand added tomorrow that acts and forgets the call is caught by nothing: section 4 sees the file's other call sites and is satisfied, and sections 8 and 9 only ever asked about the arms they run. An entry point that guards its call, or that acts before it, belongs to review, and the two questions to put to it are the ones sections 4, 6, 8 and 9 put to those five: on which route is your gate not reached, and what have you already done by the time it is"
not_tested "early-exit-matchers-outside-the-kernel-and-the-invariant-gates" \
  "the rest of tests/. Section 5's glob is the repository top level, the shipped kernel, the bundled plugins and tests/inv/test_*.sh, and the last of those was added because an invariant gate deciding its verdict by a race is the same defect the section scans the kernel for. The other test files carry the shape too, in the hundreds, and they are not covered here: converting them is a mechanical sweep of a different size, and the argument for taking the gates first is that a wrong answer there is a wrong answer about the kernel, whereas a wrong answer in a feature test is a flaky test somebody re-runs. The tell is unchanged wherever it appears, and the direction that costs is the negative assertion: a producer piped into an early-exiting grep, then '&& fail', is skipped exactly when the pattern is present. Spelled in words rather than in code, here and in the failure message above, because these two lines are not comments: this file is inside the glob it runs, so a literal instance of the shape on a line of its own prose is a violation of this invariant reported against this file — which is the right answer, and the reason the wording works around it"
not_tested "early-exit-matchers-other-than-grep-q" \
  "producers killed by an early-exiting consumer that is not grep -q. A head -n1, a sed -n 1q, and a bare read in a pipeline all stop reading before their input ends and all SIGPIPE upstream the same way; section 5 derives exactly one consumer because that is the one the shipped tree used, and the sites that pipe into head today discard the status with an explicit fallback rather than branching on it. The tell is the same wherever it appears: a pipeline under set -o pipefail whose right-hand side can stop reading first, so its exit status may be the producer's death rather than the matcher's verdict"
not_tested "recorded-label-integrity-outside-the-invariant-gates" \
  "labels recorded anywhere but tests/inv/test_*.sh, and executing punctuation that is not a backtick. Section 2's label scan reads the gate files, because a gate whose own record says something its author did not write is this file's subject at the smallest scale; the rest of tests/ records labels through the same helpers and is not covered. That includes the whole-file proofs PROOF_ENROLLED_FILES names, and the asymmetry with the ENROLMENT half of the same section — which does now probe them — is deliberate rather than an oversight: enrolment is what decides whether a file's cases are watched by any trap at all, so an unenrolled proof records nothing anywhere, while a mangled label in one still leaves a case that ran and failed honestly. The narrower loss is left to the same review the rest of tests/ gets. Two shapes inside the scanned files are outside it as well. A recorder call written inside a heredoc body is read as ordinary code, since the scanner tracks quoting and not here-documents — no shipped gate has one, and a fixture that grows one would be reported rather than missed, which is the safe direction. And '\$( )' is deliberately accepted: labels interpolate the counts that make them non-vacuous, and unlike a backtick in a sentence that spelling is visible as code to whoever types it. What is derived here is the punctuation that has actually shipped three times, not every way a shell can be made to run a word"
not_tested "gate-vacuity-beyond-the-constructed-dimensions" \
  "environment dimensions other than the three this file constructs: '\$ORCHID_ROOT is parked on the configured integration branch' (section 3, the one lesson L036 was paid for), 'the target and ORCHID_ROOT are the SAME checkout' and 'the machine-local store holds no acknowledgement for it' (section 9, the self-hosted doctor, the self-hosted lookup, the self-hosted revocation and both arms of self-hosted status — and, for the lookup, the revocation and the explain arm, that same checkout WITH an acknowledgement, which for the two arms that look one up is the dimension that gives the machine-local decision an observable position at all and for the revocation is what gives it a record to leave standing). Other dimensions in which a revalidation environment differs from a deployed one — a machine with no vendor CLI (tests/test_hermetic_suite.sh constructs that one), a repository with no remote, a HOME that is unset rather than empty — are each somebody's own proof to construct, and none of them is covered here. The question to ask of any new gate is the one this file's header asks: in which environment is the condition you branch on false, and is that the environment you test in"
not_tested "trace-and-output-interleaving-at-sub-line-granularity" \
  "whether a traced Git dispatch could land INSIDE a partial line the run had already begun. Section 9 reads its ordering off one file that both the run and Git append to, which is sound at write granularity — both open it O_APPEND, so no write is ever placed behind an earlier one — and doctor renders its verdict as a prefix printf followed by the summary, two writes with a gap between them. Nothing in that gap spends Git today (unattended_trust_summary_loaded runs no subprocess at all), so the verdict line arrives whole; if something there ever did, the trace would appear on the verdict's own line and the ordering matcher, which settles at the verdict, would step over it. What is not tested is that property of the gap — only that it holds for the code as it stands. The lookup arm has no such gap at all: unattended_trust_show_loaded writes its verdict as one complete printf, so nothing can land inside it"
not_tested "git-spent-other-than-by-the-git-binary" \
  "repository work section 9 cannot see because it did not go through a git subprocess. GIT_TRACE is Git reporting its own dispatch, which is what makes the observation survive the fixed bootstrap PATH that a shim on PATH cannot reach — and its blind spot is the mirror of that strength: code that reads .git/ files directly, or that shells to some other tool, spends no Git and is reported by nothing here. lib/common.sh's own branch half is deliberately written that way (_orchid_head_branch_ondisk reads Git's on-disk files rather than spawning a symbolic-ref subprocess), so the shape is not hypothetical in this tree. What the unattended-trust contract forbids before an acknowledgement is a Git command targeting the repository, which is what is measured; a direct on-disk read of the target's admin directory would be a different argument, and it is not made here"
