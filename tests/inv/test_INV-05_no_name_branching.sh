#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# Kernel never branches on plugin names: engine literals may appear only in
# defaults inside config lookups, never in conditionals.
#
# RED: a synthetic `if [ "$e" = codex ]` line, fed to the same pattern this
#      gate scans with, must be FOUND. This scan passes when it matches
#      nothing, which is also exactly what it does when the pattern is broken
#      or the source roots move -- so without the probe below, INV-05 would
#      go on passing forever over a kernel that branches on every engine name
#      in the tree.
# GREEN: a `config_get role.implementer codex` line -- an engine name as a
#      config DEFAULT, which is data, not a branch -- must NOT survive the
#      same pipeline, or the gate would be unusable and the RED case above
#      would only prove that the pattern matches everything.
NAME_BRANCH_RE='if .*(codex|agy|claude)|case .*(codex|agy|claude)'
probe="$WORK/inv05-probe.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$engine" = codex ]; then echo branch; fi\n'
} > "$probe"
# Captured, never `... | grep -q ...`: under helpers.sh's `set -o pipefail` a
# `grep -q` exits at its first match and SIGPIPEs the upstream grep, whose 141
# is then promoted to the pipeline's status -- so the probe would report "no
# match" for a pattern it did find. The scan below has never been exposed to
# that because it uses no -q either.
probe_hit="$(grep -nE "$NAME_BRANCH_RE" "$probe" | grep -v 'config_get.*role\.' || true)"
[ -n "$probe_hit" ] \
  || fail "INV-05 self-check: the scan does not match a real 'if ... = codex' branch, so a kernel full of them would pass this gate"
probe_default="$WORK/inv05-probe-default.sh"
printf 'if [ -n "$(config_get role.implementer codex)" ]; then echo ok; fi\n' > "$probe_default"
probe_default_hit="$(grep -nE "$NAME_BRANCH_RE" "$probe_default" | grep -v 'config_get.*role\.' || true)"
[ -z "$probe_default_hit" ] \
  || fail "INV-05 self-check: a config_get default naming an engine must stay legal -- the exemption is what makes this gate usable"
red_case "INV-05's scan matched a real 'if ... = codex' engine-name branch"
# SINGLE-quoted, and it has to stay that way. Inside DOUBLE quotes the backticks
# below are command substitution, not prose: bash ran `config_get
# role.implementer codex`, wrote `config_get: command not found` to this file's
# stderr on every single run, and passed the label on with the name it exists to
# quote spliced out of it -- so the GREEN half of INV-05's proof pair printed a
# sentence describing an input it no longer named. Inside single quotes they are
# literal, and the label is the text written here.
green_case 'the same scan let a `config_get role.implementer codex` default through, so the match above is detection rather than a pattern that hits every line naming an engine'

if grep -nE "$NAME_BRANCH_RE" "$REPO_ROOT"/libexec/* "$REPO_ROOT"/lib/*.sh \
   | grep -v 'config_get.*role\.'; then
  fail "INV-05: kernel branches on an engine name"
fi
