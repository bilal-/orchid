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
# DETECTS the failure it exists for, and that RED case must itself be
# exercised by the suite.
#
# This file is the enforcement, and it enforces two different things because
# a rule about proof cannot be enforced by structure alone:
#
#   * STATIC (`red_case_violations`): every enrolled gate file carries a
#     `# RED:` annotation, a `# GREEN:` annotation, and at least one
#     `red_case` call. Cheap, and it reads only text -- which is why it is not
#     the load-bearing half.
#   * RUNTIME (tests/helpers.sh's EXIT trap): a file under tests/inv/ that
#     RECORDS no RED case when it actually runs fails, whatever its comments
#     say. A comment cannot satisfy this one. Sections 3 and 4 below prove
#     that enforcement fires, against fixtures, rather than trusting it.
#
# What neither half can do is judge whether a recorded RED case is honest --
# whether the input fed to the check was really one the check must reject.
# That is reviewer-owned and recorded as not-tested at the end, never as a
# pass, in the same vocabulary tests/helpers.sh's not_tested uses.
#
# RED: a gate file that carries no `# RED:` annotation, carries no `# GREEN:`
#      annotation, never calls `red_case`, or lives under tests/inv/ and
#      records no RED case at run time. One fixture per case is fed to this
#      file's own linter and to the real tests/helpers.sh below, and each must
#      be rejected -- if any were accepted, this file would be one more check
#      that cannot fail, enforcing a rule against exactly that.
# GREEN: a gate file carrying all three, and an inv-shaped file that does
#      record a RED case, must both be ACCEPTED -- otherwise the rejections
#      above prove only that something rejects everything.

# This file gates too, so it holds itself to its own rule at run time and not
# merely in the linter below: if it ever stops actually exercising a RED case,
# helpers.sh's EXIT trap fails it. Every child process launched below states
# its own answer explicitly -- `ORCHID_REQUIRE_RED_CASE=1` where the
# requirement is the subject, `env -u ORCHID_REQUIRE_RED_CASE` where its
# ABSENCE is -- so inheritance through the export can never decide a fixture's
# outcome for it.
export ORCHID_REQUIRE_RED_CASE=1

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
  # `red_case` followed by whitespace: `red_case_violations` and the backticked
  # mentions of the helper in prose both fail to match, so a file cannot
  # satisfy this by talking about the rule.
  if ! grep -Eq '(^|[^_[:alnum:]])red_case[[:space:]]+[^[:space:]]' "$f"; then
    printf 'red-case-call-missing: %s (nothing in this file records a RED case, so its check has never been shown to fire)\n' "$f"
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

{ echo "$RED_LINE"; echo "$GREEN_LINE"; echo "$CALL_LINE"; } > "$FIXTURES/complete.sh"
{ echo "$GREEN_LINE"; echo "$CALL_LINE"; }                   > "$FIXTURES/no-red.sh"
{ echo "$RED_LINE"; echo "$CALL_LINE"; }                     > "$FIXTURES/no-green.sh"
{ echo "$RED_LINE"; echo "$GREEN_LINE"; }                    > "$FIXTURES/no-call.sh"
{ echo '# RED: yes'; echo "$GREEN_LINE"; echo "$CALL_LINE"; } > "$FIXTURES/stub-red.sh"
# The shape a file talking ABOUT the rule has: it mentions `red_case` in prose
# and defines a similarly-named helper, but records nothing.
{ echo "$RED_LINE"; echo "$GREEN_LINE"
  echo '# this file discusses `red_case` at length'
  echo 'red_case_violations() { :; }'; }                     > "$FIXTURES/mentions-only.sh"

assert_eq "" "$(red_case_violations "$FIXTURES/complete.sh")" \
  "a fixture carrying a RED annotation, a GREEN annotation and a red_case call must pass the linter -- if this fails, every rejection below is just a linter that rejects everything"

for fixture_pair in \
  "no-red:red-annotation-missing-or-stub" \
  "no-green:green-annotation-missing-or-stub" \
  "no-call:red-case-call-missing" \
  "stub-red:red-annotation-missing-or-stub" \
  "mentions-only:red-case-call-missing"
do
  fixture_name="${fixture_pair%%:*}"
  fixture_want="${fixture_pair#*:}"
  fixture_out="$(red_case_violations "$FIXTURES/$fixture_name.sh")"
  assert_match "$fixture_want" "$fixture_out" \
    "the linter must reject the '$fixture_name' fixture with a '$fixture_want' violation (got: ${fixture_out:-<nothing>})"
done
red_case "the linter rejects a gate file missing its RED annotation, its GREEN annotation, or its red_case call"

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
# differs only in whether it records a RED case and whether it is required to.
# ===========================================================================
RUNTIME="$WORK/runtime-fixtures"
mkdir -p "$RUNTIME"

cat > "$RUNTIME/records-none.sh" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
echo "  fixture body ran"
EOF
cat > "$RUNTIME/records-one.sh" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
red_case "the fixture's own check rejected an input it must reject"
echo "  fixture body ran"
EOF

# -- CONTROL: unmarked, and outside tests/inv/, a file that records nothing
# still passes. Without this the assertions below would be satisfied by an
# enforcement that failed every test file in the suite. `env -u`, because a
# marker inherited from the caller's environment would make this control
# measure the opposite of what it claims.
control_rc=0
control_out="$(env -u ORCHID_REQUIRE_RED_CASE "$BASH" "$RUNTIME/records-none.sh" 2>&1)" || control_rc=$?
assert_eq 0 "$control_rc" \
  "a file that neither lives under tests/inv/ nor carries the marker must not be held to the rule (got rc=$control_rc: $control_out)"

# -- RED: the marker is enough on its own.
marked_rc=0
marked_out="$(ORCHID_REQUIRE_RED_CASE=1 "$BASH" "$RUNTIME/records-none.sh" 2>&1)" || marked_rc=$?
assert_eq 1 "$marked_rc" \
  "a required file that records no RED case must FAIL, not pass quietly"
assert_match 'recorded no RED case' "$marked_out" \
  "the failure must say what is missing and how to satisfy it"
red_case "helpers.sh fails a required file that records no RED case"

# -- GREEN: the same fixture, one RED case recorded, passes -- and says so in
# the log, so a reader sees which failure was demonstrated.
kept_rc=0
kept_out="$(ORCHID_REQUIRE_RED_CASE=1 "$BASH" "$RUNTIME/records-one.sh" 2>&1)" || kept_rc=$?
assert_eq 0 "$kept_rc" \
  "a required file that DOES record a RED case must pass (got rc=$kept_rc: $kept_out)"
assert_match 'RED-CASE: ' "$kept_out" \
  "a recorded RED case must be printed, so the log shows which failure was demonstrated rather than that some number of them were"

# ===========================================================================
# 4 -- and the half that actually holds the invariant gates: the PATH rule.
#
# tests/inv/ files are required by WHERE THEY LIVE, with no marker to
# remember and none to forget. That is what makes the requirement survive a
# new invariant test written by someone who never read this file, so it is
# asserted against an inv-SHAPED fixture rather than inferred from the marker
# case above.
# ===========================================================================
INV_FIXTURE="$WORK/inv-shaped/tests/inv"
mkdir -p "$INV_FIXTURE"
cat > "$INV_FIXTURE/test_INV-99_fixture.sh" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
echo "  a new invariant gate that never demonstrates its own detection"
EOF
inv_rc=0
inv_out="$(env -u ORCHID_REQUIRE_RED_CASE "$BASH" "$INV_FIXTURE/test_INV-99_fixture.sh" 2>&1)" || inv_rc=$?
assert_eq 1 "$inv_rc" \
  "a tests/inv/ file that records no RED case must fail on its path alone, with no marker set -- otherwise a new invariant test opts out of the rule by simply not knowing about it"
assert_match 'recorded no RED case' "$inv_out" "the path-based failure must name the same requirement"
red_case "helpers.sh fails a tests/inv/ file that records no RED case, without any marker set"

# ===========================================================================
# 5 -- the enrolled gates. Every tests/inv/ file (by glob, so a new one is
# enrolled the moment it exists) plus the two whole-file proofs that gate
# something on their own.
# ===========================================================================
ENROLLED=()
for enrolled_file in "$REPO_ROOT"/tests/inv/test_*.sh; do
  [ -e "$enrolled_file" ] || continue
  ENROLLED+=("$enrolled_file")
done
inv_count="${#ENROLLED[@]}"
[ "$inv_count" -gt 0 ] \
  || fail "no tests/inv/ file matched the glob -- either the invariant gates moved, or this enrollment is checking an empty list and would pass however many of them stopped complying"
ENROLLED+=("$REPO_ROOT/tests/test_hermetic_suite.sh" "$REPO_ROOT/tests/test_red_case_rule.sh")

for enrolled_file in "${ENROLLED[@]}"; do
  enrolled_out="$(red_case_violations "$enrolled_file")"
  [ -z "$enrolled_out" ] || fail "$enrolled_out"
done
echo "  red-case rule: ${#ENROLLED[@]} enrolled gate file(s) checked ($inv_count under tests/inv/)"

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

# ===========================================================================
# 7 -- the boundaries of what any of this proves.
# ===========================================================================
not_tested "red-case-annotation-truthfulness" \
  "whether a recorded RED case is HONEST -- whether the input fed to the check was really one the check must reject, and whether the \`# RED:\` sentence describes it. Structure is checkable; meaning is not. This stays reviewer-owned, and it is the question to ask of any new gate: what input did you feed it, and did you watch it fail"
not_tested "red-case-rule-beyond-the-enrolled-gates" \
  "the rule over the rest of tests/test_*.sh. Enforcement covers tests/inv/ (by path, at run time) and the enrolled whole-file proofs; the other suite files predate the rule and are held to it by review, not by this check. A new GATE belongs in tests/inv/ or in the enrolled list above, where the enforcement reaches it"
