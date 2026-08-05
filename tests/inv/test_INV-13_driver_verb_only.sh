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
[ -f "$DRIVER" ] || fail "INV-13: runners/orchid-drive is missing"
[ -f "$POLICY" ] || fail "INV-13: lib/drive.sh is missing"

# Comment lines are excluded everywhere below: this file's whole subject is
# what the driver EXECUTES, and both files document the very verbs and
# hazards they are forbidden from open-coding.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

# ===========================================================================
# 1 -- lib/drive.sh is a PURE POLICY library: it reads and prints verdicts.
# It may never mutate anything, and it may never invoke a verb (which would
# hide a mutation behind a function call the driver's own audit cannot see).
# ===========================================================================
if code_of "$POLICY" | grep -nE 'fm_set|atomic_write|update-ref|ORCHID_BIN|bin/orchid|worktree[[:space:]]+(add|remove)|^[[:space:]]*(rm|mv|cp)[[:space:]]'; then
  fail "INV-13: lib/drive.sh must be read-only policy — it mutates, or reaches for a verb"
fi

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
  if code_of "$DRIVER" | grep -qE "\\\$ORCHID_BIN\"?[[:space:]]+$forbidden([[:space:]]|\$)"; then
    fail "INV-13: the driver invokes the forbidden verb '$forbidden'"
  fi
done

# The one judgment result it may record, it records through the one verb for
# recording judgments -- never a bare `task advance` out of arbitrating.
code_of "$DRIVER" | grep -q 'task arbitrate' \
  || fail "INV-13: the driver must record approvals through orchid task arbitrate"
if code_of "$DRIVER" | grep -nE 'task advance[^\n]*(merging|"done")'; then
  fail "INV-13: the driver must not hand-pick an arbitration destination — that is task arbitrate's job"
fi

# ===========================================================================
# 4 -- decisions read structured fields, never prose. An engine's `.summary`,
# a verify log's text, and a review's free text must never reach a branch.
# ===========================================================================
if code_of "$DRIVER" | grep -nE '\.summary|\.actions'; then
  fail "INV-13: the driver reads an engine's prose summary"
fi
if code_of "$POLICY" | grep -nE '\.summary|\.actions'; then
  fail "INV-13: the policy library reads an engine's prose summary"
fi
code_of "$DRIVER" | grep -q 'drive_review_decision' \
  || fail "INV-13: the driver must route arbitration through the structured policy function"

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
code_of "$DRIVER" | grep -q 'runners/orchid-launch' \
  || fail "INV-13: the driver must spawn role jobs through the tier-2 spawner"
