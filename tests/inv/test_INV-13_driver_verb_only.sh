#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# INV-13: the deterministic driver mutates durable/cross-process state only
# through named verbs, and decides only on structured fields.
#
# Both halves are statically checkable, and both are load bearing. If the
# driver ever wrote `.orchid/` directly, its writes would escape epoch
# fencing, the verb lock, and the journal -- the three things that make the
# state machine safe to resume. If it ever decided on PROSE (an engine's
# summary line, a log's text), a target repository could steer the run by
# writing convincing sentences.

DRIVER="$REPO_ROOT/runners/orchid-drive"
POLICY="$REPO_ROOT/lib/drive.sh"
# T010: the driver reads verdicts from a SECOND policy library now
# (lib/handoff.sh, the operator hand-off gate -- and, since T024, the operator
# prerequisite gate beside it). Check 1 below applies to every such library,
# not just the first one written -- a read-only rule that covers only the file
# it was written for stops being an invariant the moment the driver grows
# another input, and hiding a mutation behind one of them is exactly what
# check 1 exists to prevent.
#
# T007: a THIRD, on the same rule and for the same reason. The merging arm of
# the driver now decides between "merge validation failed" and a repo-wide
# `gate_failed` -- and, at the budget cap, between an ordinary rework round and
# an operator boundary -- by calling findings_log_gate_failed. That is a
# verdict read from lib/findings.sh, so lib/findings.sh is a policy library the
# driver reads verdicts from, whatever else that file is also used for. Left
# out, the one library in the set whose whole job is reading LOGS would be the
# one nothing checks for a mutation.
#
# An ARRAY, not a space-separated string: `$REPO_ROOT` is wherever the checkout
# happens to live, and a path containing a space would split one library into
# two nonexistent ones -- turning check 1 into a `fail` on a correct tree, or
# (had the existence guard below not been there) into a loop that scans nothing
# and passes vacuously.
#
# T018 adds a fourth (lib/capability.sh, the step-routing table the hand-off
# gate's capability arm reads). Enrolling it is not optional bookkeeping: it is
# consulted on the path to a boundary the driver records, so a mutation hidden
# there would escape check 1 for exactly the reason the note above gives.
#
# T025 adds a fifth: lib/rework.sh decides whether captured failure evidence is
# current and whether its signature has crossed the non-convergence threshold.
# Those verdicts can reroute an engine and raise a boundary, so the same
# read-only audit applies to that library too.
POLICIES=("$POLICY" "$REPO_ROOT/lib/handoff.sh" "$REPO_ROOT/lib/findings.sh" "$REPO_ROOT/lib/capability.sh" "$REPO_ROOT/lib/rework.sh")
[ -f "$DRIVER" ] || fail "INV-13: runners/orchid-drive is missing"
for p in "${POLICIES[@]}"; do
  [ -f "$p" ] || fail "INV-13: $p is missing"
done

# ...and the list has to stay TIED to the driver, in the one direction a file
# can check itself. Membership here is a claim that the driver reads this
# library; the driver's own `source` lines are where that claim is settled, so
# an entry the driver no longer sources is a stale audit target and says so,
# rather than quietly padding the set. The other direction -- a new driver
# input that nobody adds here -- is the omission this comment block exists to
# stop and cannot be automated: only a reader knows whether a newly sourced
# library is consulted for a VERDICT or merely for a formatter.
#
# The existence loop above already catches a typo'd path, so this is not that:
# it catches a path that exists and is no longer an input.
for p in "${POLICIES[@]}"; do
  grep -qF "lib/${p##*/}\"" "$DRIVER" \
    || fail "INV-13: $p is audited here as a driver policy library, but runners/orchid-drive no longer sources it — either the driver stopped reading it (drop the entry) or the source line moved (this scan is now blind)"
done

# Comment lines are excluded everywhere below: this file's whole subject is
# what the driver EXECUTES, and both files document the very verbs and
# hazards they are forbidden from open-coding.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# THE PURITY SCAN ITSELF, named once so the shipped libraries and this file's
# own RED/GREEN probes are judged by the SAME pattern. An earlier round aimed
# the two cases at `code_of` instead -- so the RED case demonstrated a helper
# working, not this gate detecting the failure it exists for, and its label
# said the check had "KEPT" a line, which is the ACCEPTING direction wearing
# the rejecting name. A proof aimed at the wrong function, or labelled the
# wrong way round, is indistinguishable in the record from a real one.
POLICY_IMPURE='fm_set|atomic_write|update-ref|ORCHID_BIN|bin/orchid|worktree[[:space:]]+(add|remove)|^[[:space:]]*(rm|mv|cp)[[:space:]]'

# policy_impurity <file> -- the lines of <file> that make it something other
# than read-only policy: a mutation, or a reach for a verb. Silent for a pure
# library. `grep -n` reads its input to EOF, so this pipeline has never been
# exposed to the SIGPIPE race the capture below section 1 exists for.
policy_impurity() { code_of "$1" | grep -nE "$POLICY_IMPURE" || true; }

# RED: a synthetic policy library containing a real `fm_set` line must be
#      FLAGGED by policy_impurity -- the gate's own scan, fed the exact input
#      it exists to reject. Every negative scan in this file passes when it
#      matches nothing, so an unexercised one is indistinguishable from a
#      clean tree: a driver that wrote frontmatter, removed files, evaluated
#      strings and read prose summaries would pass all six at once, silently.
# GREEN: the same line COMMENTED OUT must be ACCEPTED by the same scan,
#      because the comment exclusion is what lets both files document the
#      hazards they are forbidden from open-coding -- without it the gate
#      would flag its own prose, and its RED case above would be a matcher
#      that rejects everything.
policy_probe="$WORK/inv13-policy-probe.sh"
printf '%s\n' 'fm_set "$f" status done' > "$policy_probe"
assert_match 'fm_set' "$(policy_impurity "$policy_probe")" \
  "INV-13 self-check: the purity scan must FLAG a policy library that writes frontmatter -- if it does not, the six scans below are passing over whatever the driver and its policy libraries actually do"
red_case "INV-13's purity scan flagged a synthetic policy library carrying a real fm_set line, so the negative scans below are capable of finding a mutation rather than merely matching nothing"

policy_probe_ok="$WORK/inv13-policy-probe-commented.sh"
printf '%s\n' '# fm_set in a comment is documentation' 'echo "pure policy"' \
  > "$policy_probe_ok"
policy_probe_ok_out="$(policy_impurity "$policy_probe_ok")"
[ -z "$policy_probe_ok_out" ] \
  || fail "INV-13 self-check: the purity scan flagged a COMMENTED fm_set ($policy_probe_ok_out) -- the exclusion that lets both files document the hazards they are forbidden from open-coding is gone, so the gate would flag its own prose and the RED case above would be a matcher that rejects everything"
green_case "the same purity scan ACCEPTED a library whose only fm_set is in a comment, so the flag above is mutation detection rather than a pattern that hits every mention"

# Every POSITIVE assertion below matches against this capture, never against a
# live `code_of ... | grep -q` pipeline. Under helpers.sh's `set -uo pipefail`,
# `grep -q` exits at its FIRST match and SIGPIPEs the upstream `grep -vE`; with
# the driver's earliest hit hundreds of lines from the end, that upstream death
# is a race, pipefail promotes its 141 to the pipeline's status, and the
# assertion fails (or, in an `if` form, silently reports "no match") on a file
# that is in fact correct. Capturing once removes the pipe, so the exit status
# is the matcher's alone. The NEGATIVE checks use `grep -n`, which reads its
# input to EOF and so has never been exposed to this.
drv_code="$(code_of "$DRIVER")"

# ===========================================================================
# 1 -- every policy library the driver reads verdicts from is PURE: it reads
# and prints. None may ever mutate anything, and none may invoke a verb (which
# would hide a mutation behind a function call the driver's own audit cannot
# see).
# ===========================================================================
for p in "${POLICIES[@]}"; do
  p_impure="$(policy_impurity "$p")"
  if [ -n "$p_impure" ]; then
    printf '%s\n' "$p_impure"
    fail "INV-13: $p must be read-only policy — it mutates, or reaches for a verb"
  fi
done

# ===========================================================================
# 2 -- runners/orchid-drive never writes `.orchid/` itself. It holds `$state`
# and `$rt` only to READ task files, envelopes and manifests; any redirection,
# removal, rename or frontmatter write against those roots would be a
# durable/cross-process mutation outside a verb.
# ===========================================================================
if code_of "$DRIVER" | grep -nE '>[[:space:]]*"?\$(state|rt)|>>[[:space:]]*"?\$(state|rt)'; then
  fail "INV-13: the driver redirects output into .orchid state or runtime"
fi
if code_of "$DRIVER" | grep -nE '^[[:space:]]*(rm|mv|cp|mkdir|touch|ln)[[:space:]]'; then
  fail "INV-13: the driver creates, moves or removes files directly"
fi
if code_of "$DRIVER" | grep -nE 'fm_set|atomic_write|update-ref'; then
  fail "INV-13: the driver writes frontmatter, files or refs directly instead of through a verb"
fi
if code_of "$DRIVER" | grep -nE 'boundary\.json'; then
  fail "INV-13: the driver touches the boundary record directly instead of through orchid run boundary"
fi
if code_of "$DRIVER" | grep -nE '(^|[^_[:alnum:]])eval([^_[:alnum:]]|$)'; then
  fail "INV-13: the driver evaluates a constructed string"
fi

# The boundary record has exactly ONE writer in the whole kernel.
boundary_writers="$(grep -rlE 'boundary\.json' "$REPO_ROOT"/bin "$REPO_ROOT"/lib "$REPO_ROOT"/libexec "$REPO_ROOT"/runners 2>/dev/null | LC_ALL=C sort || true)"
assert_eq "$REPO_ROOT/libexec/orchid-run" "$boundary_writers" \
  "INV-13: orchid run boundary is the single writer of the boundary record"

# ===========================================================================
# 3 -- every verb the driver invokes is one it is allowed to invoke. The
# driver is a mechanical executor: it may walk the state machine, but it may
# never reconfigure the machine, grant trust, install a schedule, execute a
# plugin lifecycle, or accept a run.
# ===========================================================================
admitted=" run jobs task verify merge notify journal status "
used=""
while IFS= read -r verb; do
  [ -n "$verb" ] || continue
  case "$admitted" in
    *" $verb "*) ;;
    *) fail "INV-13: the driver invokes verb '$verb', which is not in its admitted set" ;;
  esac
  used="$used $verb"
done < <(code_of "$DRIVER" | grep -oE '\$ORCHID_BIN"?[[:space:]]+[a-z-]+' | sed -E 's/.*[[:space:]]//' | sort -u)
[ -n "$used" ] || fail "INV-13: no verb invocations found in the driver — the extraction regex broke"

for forbidden in trust service config plugins init start plan requirements answer doctor lessons; do
  if grep -qE "\\\$ORCHID_BIN\"?[[:space:]]+$forbidden([[:space:]]|\$)" <<<"$drv_code"; then
    fail "INV-13: the driver invokes the forbidden verb '$forbidden'"
  fi
done

# The one judgment result it may record, it records through the one verb for
# recording judgments -- never a bare `task advance` out of arbitrating.
case "$drv_code" in
  *'task arbitrate'*) ;;
  *) fail "INV-13: the driver must record approvals through orchid task arbitrate" ;;
esac
if code_of "$DRIVER" | grep -nE 'task advance[^\n]*(merging|"done")'; then
  fail "INV-13: the driver must not hand-pick an arbitration destination — that is task arbitrate's job"
fi

# ===========================================================================
# 4 -- decisions read structured fields, never prose. An engine's `.summary`,
# a verify log's text, and a review's free text must never reach a branch.
#
# T033/F32 DREW THE LINE MORE EXACTLY, and it is worth being precise about
# which half moved. A `review-conflict` boundary now CARRIES an excerpt of the
# rejecting review's summary in its reason, because a record that named only
# `verdict=request-changes` sent two dogfood operators off to `jq` the raw
# envelope to find out what was wrong. The same record now also names the
# `title` of the finding that tripped the severity gate, for the same reason
# and in the arm where it is the only thing the arbiter is told. Carrying prose
# to a human is not deciding on it: both strings are folded by
# lib/envelope.sh's envelope_fold_line (a reader, not a policy file, which is
# why it is not in POLICIES and why the scan below keeps its teeth on the files
# that DECIDE), and the decision itself is still taken from `.verdict`,
# `.scope_complete` and `.findings` alone.
#
# So the scan stays exactly as it was -- neither the driver nor a policy file
# may read `.summary` itself -- and the positive pin below is what stops that
# from becoming a rule satisfied by indirection: every arm's DECISION WORD is
# a literal in its own printf format, so no arm can compute one from anything
# an envelope said in prose.
# ===========================================================================
if code_of "$DRIVER" | grep -nE '\.summary|\.actions'; then
  fail "INV-13: the driver reads an engine's prose summary"
fi
for p in "${POLICIES[@]}"; do
  if code_of "$p" | grep -nE '\.summary|\.actions'; then
    fail "INV-13: $p reads an engine's prose summary"
  fi
done
case "$drv_code" in
  *drive_review_decision*) ;;
  *) fail "INV-13: the driver must route arbitration through the structured policy function" ;;
esac

# Each arm names its decision LITERALLY. A `printf '%s\t...'` fed from a
# variable would let a computed word -- one an envelope's own text could reach
# -- stand where `approve` stands today. Matched against the comment-stripped
# capture, per this file's own rule: a decision word quoted in a doc-comment
# must not be able to satisfy the pin for a code path that no longer prints it.
#
# `objection` (T032) is in this loop for a reason the other three do not carry
# on their own: it is the arm whose word decides WHICH BOUNDARY KIND the driver
# raises, and the two kinds differ by whether a woken model may settle the stop.
# A computed word there does not merely mislabel a decision, it re-routes an
# operator-only one to an orchestrator.
pol_code="$(code_of "$POLICY")"
for arm in approve evidence conflict objection; do
  grep -qE "printf '$arm"'\\t' <<<"$pol_code" \
    || fail "INV-13: the arbitration policy's '$arm' decision is no longer a literal in its own printf format — a computed decision word can be reached by prose"
done

# And every carried string stays a DISPLAY string: nothing in the policy may
# branch on what it says. All three, not just the first one added -- the
# rejecting review's summary excerpt, the title of the finding that tripped the
# severity gate, and (T032) the arbiter's own standing objection are free text
# that reaches the record, and a rule policing only one of them is a rule the
# others walk past. The objection is HUMAN-written rather than engine-written,
# which changes nothing about the rule: the policy's whole contract is that it
# decides on structured fields, and prose it merely quotes is prose from
# whoever wrote it.
for carried in excerpt ftitle objection; do
  # Braced expansions throughout: a bare `$carried[` reads as an array index to
  # ShellCheck (SC1087) and this suite is linted at warning severity.
  if code_of "$POLICY" | grep -nE "case[[:space:]]+\"?\\\$${carried}|\\\$${carried}[[:space:]]*=~|grep[^|]*\\\$${carried}"; then
    fail "INV-13: the arbitration policy branches on engine-written text carried in \$${carried} — it may quote prose into a record, never decide on it"
  fi
done

# The policy function's own inputs are all validated envelope fields.
for field in '.status' '.verdict' '.scope_complete' '.candidate_sha' '.findings'; do
  grep -qF "$field" "$POLICY" || fail "INV-13: the arbitration policy ignores the structured field $field"
done

# ===========================================================================
# 5 -- the driver spawns only through the tier-2 spawner (INV-06's rule,
# restated for this file): no engine binary, no plugin path, is ever named
# here.
# ===========================================================================
if code_of "$DRIVER" | grep -nE 'plugins/engines'; then
  fail "INV-13: the driver references a plugin path directly instead of the tier-2 spawner"
fi
case "$drv_code" in
  *runners/orchid-launch*) ;;
  *) fail "INV-13: the driver must spawn role jobs through the tier-2 spawner" ;;
esac
