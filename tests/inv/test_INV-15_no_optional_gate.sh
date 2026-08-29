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
# The two halves are one subject: omission is a gate nothing calls, vacuity is
# a gate that runs and cannot see, and in a log they are indistinguishable
# from each other and from a gate that passed.
#
# RED: four, one per section, each fed to the SAME derivation the section runs
#      over the shipped tree. A ci-local-shaped file whose static section sits
#      BELOW the `--no-tests` cut (so it is outside the merge floor and only
#      reaches tasks that opted into the full suite). An inv-shaped gate file
#      that never loads tests/helpers.sh, so its `red_case`/`green_case` calls
#      satisfy a text linter and are enforced by nothing at run time. A
#      trust-boundary entry point that arms the stale-root gate and reaches no
#      site that fires it. And an $ORCHID_ROOT genuinely parked on its
#      configured integration branch with a staged kernel edit, which must
#      still be REFUSED -- the case that must be caught.
# GREEN: the twins, in this file: the shipped scripts/ci-local.sh, whose
#      static sections are all above the cut; the shipped tests/inv/ gates,
#      which all load helpers.sh; a real deferring entry point that does reach
#      a firing site; and the case that must NOT fire -- an ordinary checkout
#      on a development branch, where the same construction spends no `git`
#      and refuses nothing, so section 3 is detection rather than a check that
#      fails on every checkout.

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
ci_local_late_sections() {
  local file="$1" cut_at line no section_no section_runs section_label
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
    case "$line" in
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

# RED/GREEN on the SAME derivation. The fixtures differ from each other in one
# line's position and in nothing else, so the outcomes below are attributable
# to that and to nothing else.
CI_FIXTURES="$WORK/ci-local-fixtures"
mkdir -p "$CI_FIXTURES"

# write_ci_fixture <path> <early|late|late-test> -- three ci-local-shaped
# files differing in ONE line: where the new section goes, and whether it runs
# a test script. Everything else is identical, so each outcome below is
# attributable to that line and to nothing else.
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
    if [ "$placement" = late-test ]; then
      printf 'echo "== Documentation checks"\n'
      printf 'ci_run_test "$ROOT/tests/test_docs.sh"\n'
    fi
  } > "$path"
}
write_ci_fixture "$CI_FIXTURES/early.sh"     early
write_ci_fixture "$CI_FIXTURES/late.sh"      late
write_ci_fixture "$CI_FIXTURES/late-test.sh" late-test

assert_match 'late-static-section: .*A new static check' "$(ci_local_late_sections "$CI_FIXTURES/late.sh")" \
  "INV-15: a static check placed below the --no-tests cut must be reported — it is in the suite and outside the merge floor, which is exactly the shape of an opt-in gate"
red_case "INV-15's cut derivation reported a static check placed below the --no-tests cut, so a gate that reaches only the tasks which opted in is detected rather than assumed absent"

ci_early_out="$(ci_local_late_sections "$CI_FIXTURES/early.sh")"
[ -z "$ci_early_out" ] \
  || fail "INV-15: the identical check placed ABOVE the cut was reported anyway ($ci_early_out) — a locator that flags every section would make the shipped-file assertion above meaningless"
ci_late_test_out="$(ci_local_late_sections "$CI_FIXTURES/late-test.sh")"
[ -z "$ci_late_test_out" ] \
  || fail "INV-15: a section below the cut that DOES run a test script was reported anyway ($ci_late_test_out) — the test half belongs below the cut, and a scan that flags it would flag the shipped file and could never be satisfied"
green_case 'the identical static check placed ABOVE the cut, and a section below the cut that does run a test script, were both left alone -- so the report above is position-and-kind detection rather than a scan that flags every section banner'

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
# ===========================================================================
INV_GLOB_DIR="$REPO_ROOT/tests/inv"

# helpers_missing <file> -- non-empty when <file> is a gate file that never
# LOADS tests/helpers.sh. `source`/`.` at the head of a line, so a mention of
# helpers.sh in prose (this file's own comments are full of them) does not
# satisfy it.
helpers_missing() {
  local f="$1"
  if [ ! -f "$f" ]; then
    printf 'no-such-file: %s\n' "$f"
    return 0
  fi
  grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+.*helpers\.sh' "$f" && return 0
  printf 'helpers-not-loaded: %s (its red_case/green_case calls satisfy a text linter and are enforced by nothing at run time — tests/helpers.sh is what installs the EXIT trap that requires a case to have actually RUN)\n' "$f"
}

inv_seen=0
for inv_file in "$INV_GLOB_DIR"/test_*.sh; do
  [ -e "$inv_file" ] || continue
  inv_seen=$((inv_seen + 1))
  inv_out="$(helpers_missing "$inv_file")"
  [ -z "$inv_out" ] || fail "INV-15: $inv_out"
done
[ "$inv_seen" -ge 2 ] \
  || fail "INV-15: only $inv_seen file(s) matched tests/inv/test_*.sh — the invariant gates moved, and this scan is checking an empty set"
green_case "every shipped tests/inv/ gate loads tests/helpers.sh, so the run-time RED/GREEN enforcement actually reaches all of them"

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
# ===========================================================================

# The one entry point that provably cannot fire the gate before its own work,
# with the reason, because an undeclared gap is the thing this file is against.
# `orchid trust`'s entire body IS the authorization decision: it invokes no
# other verb, spawns nothing, and writes only machine-local records outside
# every repository, so there is no "after the decision, before the work"
# moment for the gate to occupy. The membership test below is exact, so a
# second file joining this set FAILS rather than inheriting the exemption.
GATE_EXEMPT=(libexec/orchid-trust)

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
entry_expected=""
for entry_name in "${GATE_EXEMPT[@]}"; do
  entry_expected="$entry_expected $entry_name"
done
entry_expected="${entry_expected# }"
assert_eq "$entry_expected" "$entry_unfired" \
  "INV-15: the set of trust-boundary entry points that arm the stale-root gate and never fire it must be exactly the declared one — a new member means a verb that runs pre-merge kernel with nothing left to say so, and a departed member means this exemption is stale"

green_case "every shipped trust-boundary entry point but the one declared, reasoned exemption reaches a site that fires the gate it arms, and the exemption set matched exactly"

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
# 5 -- the boundaries of what any of this proves.
# ===========================================================================
not_tested "gate-omission-beyond-the-three-families" \
  "enforcement gates outside the three this file derives — the static sections of scripts/ci-local.sh, the tests/inv/ gate files, and the stale-root guard's entry-point reach. A gate that is none of those (a check living only inside one verb, a hook a plugin installs) is held to the same rule by review. What makes the three checkable is that each has a DISCOVERABLE membership: a banner, a glob, a source line. A new gate family belongs here the moment its membership becomes derivable"
not_tested "gate-vacuity-beyond-the-integration-branch-dimension" \
  "environment dimensions other than 'is \$ORCHID_ROOT parked on the configured integration branch'. That is the one lesson L036 was paid for, and it is the one section 3 constructs. Other dimensions in which a revalidation environment differs from a deployed one — a machine with no vendor CLI (tests/test_hermetic_suite.sh constructs that one), a HOME with no acknowledgement, a repository with no remote — are each somebody's own proof to construct, and none of them is covered here. The question to ask of any new gate is the one this file's header asks: in which environment is the condition you branch on false, and is that the environment you test in"
