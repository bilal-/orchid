#!/usr/bin/env bash
# THE RED-CASE RULE, MADE MECHANICAL (T017).
#
# Across r-001 and r-002 the same defect kept shipping: a check that reported
# success without having tested anything. A review envelope with an empty
# `findings[]`. A probe that grepped the reply for the string it had itself
# fed into the prompt. A rehearsal snapshot comparing a tree that was never at
# risk. `doctor` reporting outbound ok without reading the config its plugin
# requires. An inbound line whose output was identical whether or not a
# gateway existed. Each was written in good faith. None could fail. In a log
# they are indistinguishable from checks that ran and passed, which is exactly
# why they survived review after review.
#
# The rule (docs/specs/kernel.md, "Proof discipline"; PROTOCOL.md's Preamble):
# a check that GATES anything must ship a RED case demonstrating that it
# DETECTS the failure it exists for, plus the GREEN twin the same check must
# accept, and both must be exercised by the suite.
#
# This file is the enforcement, and it enforces two different things because
# a rule about proof cannot be enforced by structure alone:
#
#   * STATIC (`red_case_violations`): every enrolled gate file carries a
#     `# RED:` annotation, a `# GREEN:` annotation, a `red_case` call and a
#     `green_case` call. Cheap, and it reads only text -- which is why it is
#     NOT the load-bearing half and is not trusted on its own for any file.
#   * RUNTIME (tests/helpers.sh's EXIT trap): an ENROLLED file that RECORDS no
#     RED case, or no GREEN case, when it actually runs FAILS -- whatever its
#     comments say. A call in a comment, in a heredoc, or in a branch nothing
#     reaches satisfies the grep above and cannot satisfy this one. Sections 3,
#     4 and 5 prove that enforcement fires, against fixtures and against a real
#     repository gate, rather than trusting it.
#
# ENROLMENT IS A FACT ABOUT THE FILE, NEVER ABOUT HOW IT WAS TYPED. The runtime
# half used to decide from `$0`, which is whatever the caller wrote on the
# command line -- so the very same invariant gate was enrolled when run by
# absolute path and SILENTLY SKIPPED when run as `tests/inv/test_x.sh` from the
# repo root or as a bare `test_x.sh` from inside the directory. It failed open
# and printed nothing about it: a gate that switches itself off depending on
# how it was invoked, which is the defect this whole file exists to prevent,
# reproduced inside the enforcement of the rule against it. Section 4 is that
# regression, exercised through all three invocations, against a fixture AND
# against a real tests/inv/ file.
#
# What none of it can do is judge whether a recorded case is honest -- whether
# the input fed to the check was really one the check must reject (or accept).
# That is reviewer-owned and recorded as not-tested at the end, never as a
# pass, in the same vocabulary tests/helpers.sh's not_tested uses.
#
# RED: a gate file that carries no `# RED:` annotation, no `# GREEN:`
#      annotation, no `red_case` call or no `green_case` call; a file enrolled
#      at run time that records no RED case; one that records no GREEN case;
#      and an inv-shaped file invoked by absolute path, by relative path and by
#      bare name, each of which must be caught. One fixture per case is fed to
#      this file's own linter and to the real tests/helpers.sh below, and each
#      must be rejected -- if any were accepted, this file would be one more
#      check that cannot fail, enforcing a rule against exactly that.
# GREEN: a gate file carrying all four, an enrolled file that records both a
#      RED and a GREEN case, and a REAL tests/inv/ file run all three ways,
#      must all be ACCEPTED and print their summary -- otherwise the rejections
#      above prove only that something rejects everything.

# This file gates too, so it holds itself to its own rule at run time and not
# merely in the linter below: it is named in tests/helpers.sh's
# PROOF_ENROLLED_FILES, so if it ever stops actually exercising a RED and a
# GREEN case, helpers.sh's EXIT trap fails it.
#
# It sets NO marker on itself, deliberately. An `export
# ORCHID_REQUIRE_RED_CASE=1` here would satisfy the requirement by the marker
# branch and leave the BY-NAME enrolment -- the thing this file asserts is what
# holds the two whole-file proofs -- never actually taken for the file doing the
# asserting. Every child process launched below states its own answer
# explicitly instead: `ORCHID_REQUIRE_RED_CASE=1` where the marker is the
# subject, `env -u ORCHID_REQUIRE_RED_CASE` where its ABSENCE is, so no fixture
# outcome is ever decided by inheritance.

source "$(dirname "$0")/helpers.sh"

# ===========================================================================
# 1 -- the linter.
# ===========================================================================

# A one-word `# RED: yes` satisfies the letter of an annotation rule and tells
# a later reader nothing about which failure was demonstrated. The minimum
# length is what makes the annotation a sentence rather than a checkbox.
RED_ANNOTATION_MIN=24

# annotation_body <file> <RED|GREEN> -- the text after the FIRST `# RED:` /
# `# GREEN:` comment in <file>, leading blanks trimmed; empty when there is
# none.
annotation_body() {
  local f="$1" kind="$2" line body=""
  while IFS= read -r line; do
    body="${line#*"$kind":}"
    break
  done < <(grep -E "^[[:space:]]*#[[:space:]]*$kind:" "$f" 2>/dev/null || true)
  while [ "${body# }" != "$body" ]; do body="${body# }"; done
  printf '%s' "$body"
}

# red_case_violations <file> -- one line per violation, nothing when the file
# satisfies the rule. Pure: it reads the file and writes stdout, so section 2
# can feed it fixtures without any of them touching the repository.
red_case_violations() {
  local f="$1" body
  if [ ! -f "$f" ]; then
    printf 'no-such-file: %s\n' "$f"
    return 0
  fi
  body="$(annotation_body "$f" RED)"
  if [ "${#body}" -lt "$RED_ANNOTATION_MIN" ]; then
    printf 'red-annotation-missing-or-stub: %s (a `# RED:` comment of at least %s characters must name the failure this gate detects)\n' \
      "$f" "$RED_ANNOTATION_MIN"
  fi
  body="$(annotation_body "$f" GREEN)"
  if [ "${#body}" -lt "$RED_ANNOTATION_MIN" ]; then
    printf 'green-annotation-missing-or-stub: %s (a `# GREEN:` comment of at least %s characters must name what the same check accepts, so its RED case is evidence of detection and not of a matcher that rejects everything)\n' \
      "$f" "$RED_ANNOTATION_MIN"
  fi
  # `red_case`/`green_case` followed by whitespace: `red_case_violations` and
  # the backticked mentions of the helpers in prose both fail to match, so a
  # file cannot satisfy this by talking about the rule.
  if ! grep -Eq '(^|[^_[:alnum:]])red_case[[:space:]]+[^[:space:]]' "$f"; then
    printf 'red-case-call-missing: %s (nothing in this file records a RED case, so its check has never been shown to fire)\n' "$f"
  fi
  if ! grep -Eq '(^|[^_[:alnum:]])green_case[[:space:]]+[^[:space:]]' "$f"; then
    printf 'green-case-call-missing: %s (nothing in this file records a GREEN case, so its check has never been shown to ACCEPT anything -- a matcher that rejects everything would satisfy its RED case)\n' "$f"
  fi
}

# ===========================================================================
# 2 -- the linter, exercised. GREEN first, then one fixture per violation.
#
# Fixtures, not the real files: a linter checked only against files that
# already comply proves nothing about what it REJECTS, which is the entire
# question. Each fixture is minimal and differs from the accepted one in
# exactly the way its name says.
# ===========================================================================
FIXTURES="$WORK/lint-fixtures"
mkdir -p "$FIXTURES"

RED_LINE='# RED: a synthetic gate file missing the thing this fixture is named for'
GREEN_LINE='# GREEN: a synthetic gate file carrying everything the rule requires'
CALL_LINE='red_case "the synthetic gate fired on an input it must reject"'
GREEN_CALL_LINE='green_case "the synthetic gate accepted an input it must accept"'

{ echo "$RED_LINE"; echo "$GREEN_LINE"; echo "$CALL_LINE"; echo "$GREEN_CALL_LINE"; } > "$FIXTURES/complete.sh"
{ echo "$GREEN_LINE"; echo "$CALL_LINE"; echo "$GREEN_CALL_LINE"; }  > "$FIXTURES/no-red.sh"
{ echo "$RED_LINE"; echo "$CALL_LINE"; echo "$GREEN_CALL_LINE"; }    > "$FIXTURES/no-green.sh"
{ echo "$RED_LINE"; echo "$GREEN_LINE"; echo "$GREEN_CALL_LINE"; }   > "$FIXTURES/no-call.sh"
{ echo "$RED_LINE"; echo "$GREEN_LINE"; echo "$CALL_LINE"; }         > "$FIXTURES/no-green-call.sh"
{ echo '# RED: yes'; echo "$GREEN_LINE"; echo "$CALL_LINE"; echo "$GREEN_CALL_LINE"; } > "$FIXTURES/stub-red.sh"
# The shape a file talking ABOUT the rule has: it mentions `red_case` and
# `green_case` in prose and defines a similarly-named helper, but records
# nothing.
{ echo "$RED_LINE"; echo "$GREEN_LINE"
  echo '# this file discusses `red_case` and `green_case` at length'
  echo 'red_case_violations() { :; }'; }                             > "$FIXTURES/mentions-only.sh"

assert_eq "" "$(red_case_violations "$FIXTURES/complete.sh")" \
  "a fixture carrying a RED annotation, a GREEN annotation, a red_case call and a green_case call must pass the linter -- if this fails, every rejection below is just a linter that rejects everything"
green_case "the linter accepted a gate file carrying all four things the rule requires"

for fixture_pair in \
  "no-red:red-annotation-missing-or-stub" \
  "no-green:green-annotation-missing-or-stub" \
  "no-call:red-case-call-missing" \
  "no-green-call:green-case-call-missing" \
  "stub-red:red-annotation-missing-or-stub" \
  "mentions-only:red-case-call-missing"
do
  fixture_name="${fixture_pair%%:*}"
  fixture_want="${fixture_pair#*:}"
  fixture_out="$(red_case_violations "$FIXTURES/$fixture_name.sh")"
  assert_match "$fixture_want" "$fixture_out" \
    "the linter must reject the '$fixture_name' fixture with a '$fixture_want' violation (got: ${fixture_out:-<nothing>})"
done
red_case "the linter rejects a gate file missing its RED annotation, its GREEN annotation, its red_case call or its green_case call"

# A file that does not exist is a violation, not a clean bill of health: an
# enrolled path that gets renamed away would otherwise pass silently, which is
# the failure mode tests/test_hermetic_suite.sh's own glob check exists for.
assert_match 'no-such-file' "$(red_case_violations "$FIXTURES/never-written.sh")" \
  "a missing enrolled file must be reported, never treated as compliant"
red_case "the linter reports a missing enrolled file instead of passing it"

# ===========================================================================
# 3 -- the RUNTIME enforcement in tests/helpers.sh, exercised against the real
# helpers.sh rather than a copy of its logic.
#
# This is the half that cannot be satisfied by a comment, so it is the half
# that has to be proven. Each fixture sources the shipped tests/helpers.sh and
# differs only in which cases it records and whether it is required to.
# ===========================================================================
RUNTIME="$WORK/runtime-fixtures"
mkdir -p "$RUNTIME"

# write_fixture <path> [red|green|both|none] -- an otherwise identical file
# that records exactly the cases named. Identical bodies are the point: any
# difference in outcome below is attributable to the recording and to nothing
# else.
write_fixture() {
  local path="$1" records="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'source "%s/tests/helpers.sh"\n' "$REPO_ROOT"
    case "$records" in
      red|both)   printf 'red_case "the fixture rejected an input its own check must reject"\n' ;;
    esac
    case "$records" in
      green|both) printf 'green_case "the fixture accepted an input its own check must accept"\n' ;;
    esac
    printf 'echo "  fixture body ran"\n'
  } > "$path"
}
write_fixture "$RUNTIME/records-none.sh"  none
write_fixture "$RUNTIME/records-red.sh"   red
write_fixture "$RUNTIME/records-green.sh" green
write_fixture "$RUNTIME/records-both.sh"  both

# -- CONTROL: unmarked, and not enrolled, a file that records nothing still
# passes. Without this the assertions below would be satisfied by an
# enforcement that failed every test file in the suite. `env -u`, because a
# marker inherited from the caller's environment would make this control
# measure the opposite of what it claims.
control_rc=0
control_out="$(env -u ORCHID_REQUIRE_RED_CASE "$BASH" "$RUNTIME/records-none.sh" 2>&1)" || control_rc=$?
assert_eq 0 "$control_rc" \
  "a file that is neither enrolled by location nor carrying the marker must not be held to the rule (got rc=$control_rc: $control_out)"

# -- RED: the marker is enough on its own, and each half is named separately so
# the diagnostic tells an author which one is missing.
marked_rc=0
marked_out="$(ORCHID_REQUIRE_RED_CASE=1 "$BASH" "$RUNTIME/records-none.sh" 2>&1)" || marked_rc=$?
assert_eq 1 "$marked_rc" \
  "a required file that records neither case must FAIL, not pass quietly"
assert_match 'recorded no RED case' "$marked_out" \
  "the failure must say what is missing and how to satisfy it"
assert_match 'recorded no GREEN case' "$marked_out" \
  "...and it must name the GREEN half too, rather than letting an author fix one and rediscover the other"

# -- RED: a RED case ALONE is not enough. This is the half a textual linter can
# never reach, and the half the two whole-file proofs used to rest on: a
# `green_case` call sitting in a comment satisfies section 1's grep while
# nothing accepts anything, so the gate could be a matcher that rejects
# everything and still pass.
red_only_rc=0
red_only_out="$(ORCHID_REQUIRE_RED_CASE=1 "$BASH" "$RUNTIME/records-red.sh" 2>&1)" || red_only_rc=$?
assert_eq 1 "$red_only_rc" \
  "a required file that records a RED case but no GREEN case must FAIL -- a matcher that rejects everything satisfies a RED case and detects nothing"
assert_match 'recorded no GREEN case' "$red_only_out" \
  "the GREEN half's failure must name the GREEN half"
grep -q 'recorded no RED case' <<<"$red_only_out" \
  && fail "a file that DID record a RED case was told it recorded none -- the two counters are not independent"

# -- RED: and a GREEN case alone is not enough either, or a gate could ship
# nothing but the input it accepts.
green_only_rc=0
green_only_out="$(ORCHID_REQUIRE_RED_CASE=1 "$BASH" "$RUNTIME/records-green.sh" 2>&1)" || green_only_rc=$?
assert_eq 1 "$green_only_rc" \
  "a required file that records a GREEN case but no RED case must FAIL"
assert_match 'recorded no RED case' "$green_only_out" \
  "the RED half's failure must name the RED half"
red_case "helpers.sh fails a required file that records neither case, one that records only a RED case, and one that records only a GREEN case"

# -- GREEN: the same fixture recording both passes -- and says so in the log,
# so a reader sees which failures were demonstrated.
kept_rc=0
kept_out="$(ORCHID_REQUIRE_RED_CASE=1 "$BASH" "$RUNTIME/records-both.sh" 2>&1)" || kept_rc=$?
assert_eq 0 "$kept_rc" \
  "a required file that records BOTH cases must pass (got rc=$kept_rc: $kept_out)"
assert_match 'RED-CASE: ' "$kept_out" \
  "a recorded RED case must be printed, so the log shows which failure was demonstrated rather than that some number of them were"
assert_match 'GREEN-CASE: ' "$kept_out" "...and so must its GREEN twin"
assert_match 'red-cases: 1 demonstrated' "$kept_out" \
  "a file that satisfies the rule must SAY so, so the summary's absence is itself readable as the rule not having applied"
green_case "helpers.sh passes a required file that records both a RED and a GREEN case, and prints both labels plus the summary line"

# ===========================================================================
# 4 -- ENROLMENT MUST NOT DEPEND ON HOW THE FILE WAS INVOKED.
#
# tests/inv/ files are required by WHERE THEY LIVE, with no marker to remember
# and none to forget. That is what makes the requirement survive a new
# invariant test written by someone who never read this file.
#
# But "where they live" was read off `$0`, and `$0` is whatever the caller
# typed. The same file arrives as an absolute path from tests/run.sh, as
# `tests/inv/test_x.sh` from the repo root, and as a bare `test_x.sh` from
# inside the directory -- and only the first matched. The other two were
# silently NOT enrolled: no requirement, no summary line, no failure, nothing
# in the log to distinguish them from a file that complied. A gate that turns
# itself off depending on how it was typed is precisely the shape this file
# exists to prevent, so the fix is proven through every one of the three
# invocations rather than through the one that always worked.
# ===========================================================================

# run_invoked <cwd> <argv0> -- run a file the way a person would, from a
# particular directory and with a particular spelling of its name, and report
# the outcome. The `cd` lives inside a command substitution's own subshell, so
# it can never leak into the rest of this file.
INVOKED_RC=0
INVOKED_OUT=""
run_invoked() {
  INVOKED_RC=0
  INVOKED_OUT="$(cd "$1" && env -u ORCHID_REQUIRE_RED_CASE "$BASH" "$2" 2>&1)" || INVOKED_RC=$?
}

INV_FIXTURE_ROOT="$WORK/inv-shaped"
INV_FIXTURE_DIR="$INV_FIXTURE_ROOT/tests/inv"
mkdir -p "$INV_FIXTURE_DIR"
write_fixture "$INV_FIXTURE_DIR/test_INV-99_bare.sh"     none
write_fixture "$INV_FIXTURE_DIR/test_INV-99_complete.sh" both

# The three spellings, named once and reused for both directions so neither can
# quietly be exercised through fewer of them than the other. Each entry is
# <cwd>|<prefix>|<label>, and the file name is appended to the prefix -- the
# empty prefix on the last one is the bare-name case.
INVOCATIONS=(
  "$INV_FIXTURE_ROOT|$INV_FIXTURE_DIR/|absolute path (how tests/run.sh invokes it)"
  "$INV_FIXTURE_ROOT|tests/inv/|relative path from the tree root"
  "$INV_FIXTURE_DIR||bare filename from inside tests/inv"
)

for invocation in "${INVOCATIONS[@]}"; do
  inv_cwd="${invocation%%|*}"
  inv_rest="${invocation#*|}"
  inv_prefix="${inv_rest%%|*}"
  inv_label="${inv_rest#*|}"

  # RED: an inv-shaped file that records nothing must fail, however it is
  # spelled. Two of these three used to exit 0 in silence.
  run_invoked "$inv_cwd" "${inv_prefix}test_INV-99_bare.sh"
  assert_eq 1 "$INVOKED_RC" \
    "a tests/inv/ file that records no case must fail on its LOCATION alone when invoked by $inv_label, with no marker set -- enrolment read off \$0 skipped this one silently (got rc=$INVOKED_RC: $INVOKED_OUT)"
  assert_match 'recorded no RED case' "$INVOKED_OUT" \
    "the location-based failure must name the RED requirement when invoked by $inv_label"
  assert_match 'recorded no GREEN case' "$INVOKED_OUT" \
    "...and the GREEN requirement too, when invoked by $inv_label"

  # GREEN: the same location, a file that DOES record both, must pass and print
  # its summary -- otherwise the failures above would only show that this
  # spelling breaks the fixture rather than that the rule reached it.
  run_invoked "$inv_cwd" "${inv_prefix}test_INV-99_complete.sh"
  assert_eq 0 "$INVOKED_RC" \
    "a tests/inv/ file that records both cases must PASS when invoked by $inv_label (got rc=$INVOKED_RC: $INVOKED_OUT)"
  assert_match 'red-cases: 1 demonstrated' "$INVOKED_OUT" \
    "an enrolled file must print its summary when invoked by $inv_label -- the ABSENCE of that line was the only visible symptom of the gate silently not applying"
done
red_case "an inv-shaped file recording no case failed by location alone through all three invocations -- absolute, relative and bare -- including the two that used to be skipped in silence"
green_case "the same location with both cases recorded passed and printed its summary through all three invocations, so the failures above are enrolment reaching the file rather than the spelling breaking it"

# ...and the same three spellings against a REAL repository invariant gate,
# which is the operator's own reproduction. The fixture above shares this
# file's scratch tree; a shipped tests/inv/ file shares nothing with it, so
# this is the assertion that the fix reaches the files the rule is actually
# for. INV-01 is chosen because it is a static scan: it costs a few greps and
# writes nothing outside its own scratch.
REAL_INV_FILE=test_INV-01_no_spawn_in_tier1.sh
[ -f "$REPO_ROOT/tests/inv/$REAL_INV_FILE" ] \
  || fail "the real invariant gate this section reproduces against ($REAL_INV_FILE) is gone -- pick another tests/inv/ file rather than dropping the reproduction"
REAL_INVOCATIONS=(
  "$REPO_ROOT|$REPO_ROOT/tests/inv/$REAL_INV_FILE|absolute path"
  "$REPO_ROOT|tests/inv/$REAL_INV_FILE|relative path from the repo root"
  "$REPO_ROOT/tests/inv|$REAL_INV_FILE|bare filename from inside tests/inv"
)
for invocation in "${REAL_INVOCATIONS[@]}"; do
  inv_cwd="${invocation%%|*}"
  inv_rest="${invocation#*|}"
  inv_argv0="${inv_rest%%|*}"
  inv_label="${inv_rest#*|}"
  run_invoked "$inv_cwd" "$inv_argv0"
  assert_eq 0 "$INVOKED_RC" \
    "the real invariant gate $REAL_INV_FILE must pass when invoked by $inv_label (got rc=$INVOKED_RC: $INVOKED_OUT)"
  assert_match 'red-cases: [1-9]' "$INVOKED_OUT" \
    "the real invariant gate $REAL_INV_FILE must be ENROLLED when invoked by $inv_label -- an absent summary means the rule silently did not apply to a shipped gate, which is exactly what \$0-based enrolment did for this spelling"
done
green_case "a real shipped tests/inv/ gate was enrolled and printed its red-case summary through all three invocations, not only the absolute one"

# ===========================================================================
# 5 -- the enrolled gates, and the enrolment predicate itself.
#
# Every tests/inv/ file (by glob, so a new one is enrolled the moment it
# exists) plus the whole-file proofs tests/helpers.sh names. The list is read
# FROM helpers.sh rather than restated here: a second copy would let the two
# drift, and the runtime half is the one that matters.
# ===========================================================================
for required_enrolled in tests/test_hermetic_suite.sh tests/test_red_case_rule.sh; do
  enrolled_found=0
  for enrolled_name in "${PROOF_ENROLLED_FILES[@]}"; do
    [ "$enrolled_name" = "$required_enrolled" ] && enrolled_found=1
  done
  [ "$enrolled_found" -eq 1 ] \
    || fail "tests/helpers.sh's PROOF_ENROLLED_FILES no longer names $required_enrolled, so that whole-file proof is held to the rule by this file's text scan alone -- a red_case call in one of its comments would satisfy that while nothing ran"
done

# The predicate, asked directly. This is what decides enrolment, so it is fed
# the answers it must give rather than inferred from the end-to-end runs above.
_proof_enrolled "$REPO_ROOT/tests/inv/$REAL_INV_FILE" \
  || fail "the enrolment predicate does not recognize a real tests/inv/ file"
_proof_enrolled "$REPO_ROOT/tests/test_hermetic_suite.sh" \
  || fail "the enrolment predicate does not recognize a file named in PROOF_ENROLLED_FILES"
green_case "the enrolment predicate says yes to a real tests/inv/ path and to a by-name enrolled whole-file proof"

if _proof_enrolled "$REPO_ROOT/tests/test_docs.sh"; then
  fail "the enrolment predicate enrols an ordinary suite file that is neither under tests/inv/ nor named in PROOF_ENROLLED_FILES -- a predicate that says yes to everything would make the whole suite fail rather than hold the gates to the rule"
fi
if _proof_enrolled "$REPO_ROOT/tests/inv/helpers-not-a-test.sh"; then
  fail "the enrolment predicate enrols a tests/inv/ file that is not a test_*.sh gate"
fi
# The defect itself, kept as a live fact rather than as prose: the pattern the
# predicate matches with genuinely cannot see the repo-root-relative spelling.
# THAT is why the caller must hand it a resolved path, and if this ever starts
# passing, the resolution in helpers.sh has stopped being what carries the fix.
if _proof_enrolled "tests/inv/$REAL_INV_FILE"; then
  fail "the enrolment pattern now matches the bare relative spelling directly -- harmless in itself, but tests/helpers.sh's path RESOLUTION is no longer the thing keeping enrolment invocation-independent, and section 4's guarantee now rests on something this file is not checking"
fi
red_case "the enrolment predicate refuses an ordinary suite file, a non-test file under tests/inv/, and the unresolved relative spelling that is exactly why the path must be resolved before it is asked"

ENROLLED=()
for enrolled_file in "$REPO_ROOT"/tests/inv/test_*.sh; do
  [ -e "$enrolled_file" ] || continue
  ENROLLED+=("$enrolled_file")
done
inv_count="${#ENROLLED[@]}"
[ "$inv_count" -gt 0 ] \
  || fail "no tests/inv/ file matched the glob -- either the invariant gates moved, or this enrollment is checking an empty list and would pass however many of them stopped complying"
for enrolled_name in "${PROOF_ENROLLED_FILES[@]}"; do
  ENROLLED+=("$REPO_ROOT/$enrolled_name")
done

for enrolled_file in "${ENROLLED[@]}"; do
  enrolled_out="$(red_case_violations "$enrolled_file")"
  [ -z "$enrolled_out" ] || fail "$enrolled_out"
done
echo "  red-case rule: ${#ENROLLED[@]} enrolled gate file(s) checked ($inv_count under tests/inv/, ${#PROOF_ENROLLED_FILES[@]} by name)"

# ===========================================================================
# 6 -- the rule is written down where a check is specified, in all three
# places, so it cannot quietly become this file's private convention.
# ===========================================================================
grep -qF 'must ship a RED case demonstrating that it detects the failure it exists for' \
  "$REPO_ROOT/docs/specs/kernel.md" \
  || fail "docs/specs/kernel.md no longer states the RED-case rule -- the normative spec is where a check's contract lives"
grep -qF 'A check that cannot fail is not a check' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md's Preamble no longer states the RED-case rule for the checks this protocol specifies"
grep -qF 'red_case' "$REPO_ROOT/docs/contributing.md" \
  || fail "docs/contributing.md no longer tells a contributor how to satisfy the RED-case rule mechanically"
grep -qF 'green_case' "$REPO_ROOT/docs/contributing.md" \
  || fail "docs/contributing.md no longer tells a contributor that the GREEN twin has to RUN inside the gate file, not be delegated to another one"

# ===========================================================================
# 7 -- the boundaries of what any of this proves.
# ===========================================================================
not_tested "red-case-annotation-truthfulness" \
  "whether a recorded RED or GREEN case is HONEST -- whether the input fed to the check was really one the check must reject (or accept), and whether the \`# RED:\`/\`# GREEN:\` sentences describe them. Structure is checkable; meaning is not. This stays reviewer-owned, and it is the question to ask of any new gate: what input did you feed it, and did you watch it fail"
not_tested "red-case-rule-beyond-the-enrolled-gates" \
  "the rule over the rest of tests/test_*.sh. Enforcement covers tests/inv/ (by path, at run time) and the whole-file proofs named in tests/helpers.sh's PROOF_ENROLLED_FILES; the other suite files predate the rule and are held to it by review, not by this check. A new GATE belongs in tests/inv/ or in that list, where the enforcement reaches it"
not_tested "red-case-enrolment-beyond-the-three-invocations" \
  "spellings of a test file's path other than the three section 4 exercises. Absolute, tree-relative and bare-name are what tests/run.sh, scripts/ci-local.sh and a person at a shell actually produce, and enrolment is now decided from a RESOLVED physical path rather than from the command line, so exotic spellings (\`./x/../inv/test_y.sh\`, a symlinked checkout) resolve to the same place by construction -- but only the three are demonstrated"
