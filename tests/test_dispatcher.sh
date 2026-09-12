#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
out="$("$ORCHID_BIN" help)"
assert_match "usage: orchid" "$out" "help prints usage"
rc=0; "$ORCHID_BIN" no-such-verb 2>/dev/null || rc=$?
assert_eq "2" "$rc" "unknown verb exits 2"

# `orchid version` (libexec/orchid-version), run through the dispatcher --
# exits 0 and prints a line naming the running kernel's ORCHID_VERSION
# (lib/common.sh), currently the prerelease 1.0.0-beta.1. Matched with the
# suffix attached: a bare `1\.0\.0` pattern would also match `1.0.0` itself,
# so it could not tell the shipped prerelease from an unearned 1.0.0.
rc=0; out="$("$ORCHID_BIN" version)" || rc=$?
assert_eq "0" "$rc" "version exits 0"
assert_match "1\.0\.0-beta\.1" "$out" "version prints a line containing ORCHID_VERSION"

# ============================================================================
# A VERB THAT IS NOT EXECUTABLE IS NOT AN UNKNOWN VERB.
#
# The dispatcher gates on `[ -x "$exe" ]` and reports everything that fails it
# as `unknown command '<verb>'`. Those are two different facts with two
# different fixes, and conflating them sends the reader to the wrong conclusion
# with confidence: the file IS there, the verb HAS been added, and the whole
# problem is one mode bit.
#
# This is not hypothetical. An implementer profile may not run `chmod` (lesson
# L017), and several engines recreate every file they touch at 0644 -- so a new
# `libexec/orchid-<verb>` arriving mode 644 is a routine outcome of adding a
# verb, and `unknown command` is exactly the message that makes an operator or
# an agent conclude the file was never written and go looking for the wrong
# thing. lib/drive.sh already CLASSIFIES this state correctly and declines to
# charge the attempt for it; what it could not do is stop the dispatcher
# describing it as something else.
#
# Both halves are pinned here because the conflation is only visible as the
# DIFFERENCE between them: a genuinely absent verb must still be `unknown`.
# ============================================================================
disp_probe="$REPO_ROOT/libexec/orchid-execbitprobe"
printf '#!/usr/bin/env bash\necho reached\n' > "$disp_probe"
chmod 644 "$disp_probe"
rc=0; disp_out="$("$ORCHID_BIN" execbitprobe 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a non-executable verb must not be dispatched"
grep -q "unknown command" <<<"$disp_out" \
  && fail "a verb file that EXISTS must not be reported as unknown — the file is there and only its mode is wrong: $disp_out"
assert_match "not executable" "$disp_out" \
  "the dispatcher says what is actually wrong"
assert_match "chmod \+x" "$disp_out" \
  "...and names the one command that fixes it, since the implementer profile that shipped it cannot run chmod itself"
assert_match "libexec/orchid-execbitprobe" "$disp_out" \
  "...naming the exact path, so the fix can be run as printed"
red_case 'a verb present at mode 644 is reported as a mode problem naming chmod +x, not as an unknown command that sends the reader looking for a file that is already there'

# GREEN twin, in both directions. A verb that is genuinely absent is STILL
# `unknown command` -- without this the change would have replaced one wrong
# answer with another -- and the same file, once executable, dispatches.
rc=0; disp_absent="$("$ORCHID_BIN" no-such-verb-at-all 2>&1)" || rc=$?
assert_eq 2 "$rc" "a genuinely absent verb still exits 2"
assert_match "unknown command" "$disp_absent" \
  "...and is still reported as unknown, because that is what it is"
grep -q "chmod" <<<"$disp_absent" \
  && fail "an absent verb must not be advised to chmod a file that does not exist: $disp_absent"
chmod 755 "$disp_probe"
assert_eq reached "$("$ORCHID_BIN" execbitprobe 2>&1)" \
  "and the identical file dispatches once the mode bit is set — so the refusal above was about the bit and nothing else"
rm -f "$disp_probe"
green_case 'an absent verb is still unknown and is never advised to chmod, and the mode-644 verb dispatches normally once chmod +x has been run'
