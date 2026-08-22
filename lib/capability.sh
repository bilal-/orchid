#!/usr/bin/env bash
# lib/capability.sh -- CAPABILITY-AWARE STEP ROUTING (INV-16).
#
# WHAT A STEP IS. One unit of work the tick routes to an actor: the `implement`
# operation a dispatch launches, the `orchestrate` operation a wake spawns, the
# `mechanical` work a candidate needs between an implementer's envelope
# reconciling and `orchid verify` running. Each step's work needs certain
# CAPABILITIES; this file holds the kernel's table of which, so that a step may
# be refused to an actor whose own manifest does not claim them -- before
# anything is spawned, and before an attempt is spent on a round that could
# never have succeeded.
#
# THE COST THIS EXISTS TO STOP. Nothing consulted `capabilities=` when deciding
# whether a STEP could be assigned, so the tick routinely asked an implementer
# to run a verifier, re-pin a checksum or set a mode bit -- all of which a
# profile that denies on the command STRING refuses (lesson L017). In this
# repository's own runs that cost T005 two attempt cycles being told twice to
# fix findings it could not see, and T014 three to a pin it could not refresh.
# A step nobody in the loop can perform is an operator hand-off; naming it as
# one is the whole of the rule.
#
# WHY A SECOND TABLE, WHEN lib/roles.sh ALREADY GATES ON CAPABILITIES. The role
# gate answers a different question -- "may this plugin HOLD this role" -- from
# `requires=`/`forbids=` in the ROLE'S DESCRIPTOR. That descriptor is not
# always kernel data: a `kind=role` plugin ships its own `descriptor.role`
# (lib/roles.sh's _role_file discovers it, and libexec/orchid-doctor lists it),
# so a custom role's requirements are declared by the same publisher whose
# engine is about to fill them. An actor can therefore reach a step through a
# role that asks for nothing at all. The table below is kernel-owned and cannot
# be shipped past: it is asked about the WORK, not about the role, so it holds
# however the actor got there.
#
# IT ONLY EVER REFUSES. A capability atom is A CLAIM BY THE PLUGIN, NOT A GRANT
# -- docs/beta-qualification.md draws exactly that distinction, and the shipped
# tree is its own counter-example: plugins/engines/claude declares `shell`
# while its implement path launches the vendor CLI with a file-edit permission
# mode and no command allowlist, so it cannot run one command. A MISSING atom
# is therefore decisive (the profile certainly cannot do the work) and a
# PRESENT one settles nothing. Nothing in this file returns "permitted", and no
# caller may read a clean answer as permission: every gate built on this
# composes as ONE MORE REASON TO STOP, never as a reason to proceed past
# another gate that already said stop. lib/handoff.sh's capability arm is the
# worked example -- it can only ever turn the operator pause ON.
#
# Pure policy, like lib/drive.sh and lib/handoff.sh: every function below READS
# (a plugin manifest, the search path) and prints. Nothing here mutates, spawns
# or reaches for a verb.
#
# Source AFTER lib/common.sh, lib/manifest.sh and lib/resolver.sh -- it calls
# manifest_capabilities and resolve_engine_dir_any and nothing else.

# The closed set of STEP names. Kernel-owned, exactly like lib/hooks.sh's
# `_HOOK_POINTS` and lib/drive.sh's `_DRIVE_BOUNDARY_KINDS`: a step outside
# this set is a programming error or a typo, not a new kind of work, so
# capability_routing_refusal stops on it rather than pricing it at nothing --
# and reports it as the CALLER's error (its exit 3), never as something the
# resolved actor failed to declare.
# Space-padded for the substring membership idiom this codebase already uses.
_CAPABILITY_STEPS=" implement review critique hook orchestrate mechanical "

capability_step_valid() {  # step -> 0 iff kernel-owned
  case "$_CAPABILITY_STEPS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# capability_step_requires <step> -- the capability atoms this step's work
# needs, one per line; nothing at all for a step the kernel prices no
# requirement for.
#
# EVERY ROW IS A STATEMENT, INCLUDING THE EMPTY ONE. A step this table forgets
# to price is a step this file cannot refuse, so an omission here reads exactly
# like a deliberate "needs nothing" and opens the gate for every actor -- the
# same fail-open the file exists to close, arriving through the DATA instead of
# through the code. The rows below are therefore exhaustive over
# `_CAPABILITY_STEPS`, and the one priced at nothing says why.
#
# The implement/orchestrate rows are lib/conform.sh's `_conform_ops_for_dir`
# table read in the other direction. That file already decides which OPERATIONS
# a plugin's declared capabilities imply it can be probed for --
# `workspace_write` means it may be asked to implement, `shell` AND `git`
# together mean it may be asked to orchestrate -- so the same shipped fact is
# used here to refuse a routing rather than to choose a probe. Two files
# reading one implication in opposite directions is deliberate; two files
# inventing two implications would not be.
#
# `mechanical` is the row with no counterpart there, because no adapter is ever
# ASKED to do it: it is the candidate's execution-requiring mechanical work --
# applying a linter's own fix, re-pinning a release checksum, setting the mode
# bit on a newly added executable -- and every one of those is a COMMAND, so
# `shell` is its floor (lesson L017; lib/handoff.sh's header).
#
# WHERE EACH ROW IS ENFORCED, because the answer is not uniform. `implement`,
# `review`, `critique` and `orchestrate` are enforced at `orchid jobs prepare`,
# the one place a (task, role, operation) triple is bound to an engine. For the
# five BUILT-IN roles those rows restate a floor the role gate already holds
# (and cannot be shadowed past -- lib/roles.sh refuses a custom role whose id
# equals a core one, INV-10), so there they are defense in depth; they become
# load bearing
# the moment a CUSTOM role is bound, which is the case whose descriptor its own
# publisher writes. Note that `orchestrate` reaches prepare only that way --
# runners/orchid-tick builds its own request document and never mints a job --
# so the tick's own orchestrator is gated by roles/orchestrator.role, not here.
# `mechanical` is enforced at lib/handoff.sh, because it is a step no adapter
# is dispatched for at all.
#
# `review` and `critique` need `structured_text`, and pricing them at nothing
# was this table's own fail-open. What both steps produce is a STRUCTURED reply
# -- an envelope the kernel parses a `verdict`, a `scope_complete` and a
# `findings[]` out of -- so an actor that does not claim structured text cannot
# perform either, exactly as an actor claiming no `shell` cannot run a command.
# The three built-in judging roles do declare it (roles/reviewer.role,
# roles/arbiter.role, roles/plan_critic.role), which is precisely why leaving
# the rows empty LOOKED safe: the role gate covers those five. It does not
# cover the case this whole file exists for -- a CUSTOM role, whose descriptor
# is written by the same publisher whose engine is about to fill it. A role
# asking for nothing carried a capability-free actor to a review step and this
# table had nothing to say about it, so the kernel-owned gate never fired and
# the claim-is-not-a-grant rule was decorative for exactly the routing it was
# built to stop. Both rows are load bearing there and defense in depth for the
# built-in five, which is the same division of labour the header describes.
#
# `hook` is the one step priced at NOTHING, and it is a statement rather than
# an omission. A hook handler is bound by NAME from `hook.<point>` config and
# reaches no role gate at all (libexec/orchid-jobs' hook arm), and this kernel
# has never asked a handler for any capability: the point's contract is an
# envelope with an `outcome`, and handlers that ship today declare anything
# from a full set down to nothing. Pricing it would invent a requirement and
# refuse working handlers -- a step's price must be what the WORK needs, and
# nobody has established that this work needs an atom. Should a hook contract
# ever require one, it is added HERE, as a row -- never as a caller's own
# inline test.
capability_step_requires() {
  case "$1" in
    implement) printf 'workspace_write\n' ;;
    review|critique) printf 'structured_text\n' ;;
    orchestrate) printf 'shell\ngit\n' ;;
    mechanical) printf 'shell\n' ;;
    hook) ;;
  esac
  return 0
}

# _capability_oneline -- reads lines on stdin, prints them comma-joined on one.
# Every message this file produces goes into a boundary detail, a journal line
# or a `die`, and a multi-line value in any of those is read the way no value
# at all is.
_capability_oneline() {
  local out=""
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -z "$out" ]; then out="$line"; else out="$out, $line"; fi
  done
  printf '%s' "$out"
}

# _capability_have <plugin-dir> -- the atoms this plugin's manifest CLAIMS, as
# a space-bounded " a b c " string for substring membership.
#
# A `while read` loop over a process substitution, never `read -ra <<< "..."`:
# a plugin declaring no capabilities at all is ordinary (a hook handler, a
# manifest with a bare `capabilities=`), and in bash 3.2 `read -ra` on an empty
# string leaves the array genuinely UNSET rather than empty, which every caller
# of this file aborts on under `set -u`. Same idiom lib/roles.sh's
# role_eligibility_reason and lib/capsuite.sh already use for the same reason.
_capability_have() {
  local have=" "
  local atom
  while IFS= read -r atom; do
    [ -n "$atom" ] && have="$have$atom "
  done < <(manifest_capabilities "$1" 2>/dev/null)
  printf '%s' "$have"
}

# capability_step_uncovered <step> <plugin-dir> -- the atoms <step> needs that
# this plugin's manifest does not claim, one per line. No output means covered
# (including for a step priced at nothing).
capability_step_uncovered() {
  local step="$1"
  local dir="$2"
  local have
  local atom
  have="$(_capability_have "$dir")"
  while IFS= read -r atom; do
    [ -n "$atom" ] || continue
    case "$have" in
      *" $atom "*) ;;
      *) printf '%s\n' "$atom" ;;
    esac
  done < <(capability_step_requires "$step")
  return 0
}

# capability_routing_refusal <step> <engine-name> -- THE routing gate. Four
# outcomes, and a caller must read the STATUS as well as the output:
#
#   0, no output   this step may be routed to this actor: either the actor's
#                  manifest claims every atom the step needs, or the step is
#                  priced at none. NOT a grant -- see this file's header.
#   1, one line    REFUSED. The actor's manifest does not claim an atom the
#                  step's work needs, so routing it there produces a round that
#                  could not have succeeded.
#   2, one line    UNDETERMINED. No actor was named, or the named one is not
#                  installed under EITHER name it could answer to -- neither an
#                  engine directory of that name nor a manifest claiming that
#                  id -- so there is no manifest to read and nothing says
#                  either way.
#   3, one line    THE CALLER IS WRONG, and the actor is not implicated at all:
#                  the step name is outside `_CAPABILITY_STEPS`, so no work was
#                  ever priced and no manifest was read.
#
# WHY 3 IS NOT FOLDED INTO 1, though both stop the routing. A refusal is a
# report about WHO IS AT FAULT as much as a decision, and these two blame
# opposite parties: 1 says the resolved plugin does not declare what the work
# needs, 3 says the kernel was asked to route work that does not exist -- a
# mistyped operation, a caller passing a step name this table has never had.
# Reported as 1, an `orchid jobs prepare TC runner reviewww` sends an operator
# to audit the manifest of a plugin that is behaving perfectly, and the actual
# typo -- the one thing they could fix -- is nowhere in the message. Every
# caller below therefore says which occurred, and the caller-error arm is not
# an INV-16 hand-off at all: nothing about it is an operator's work.
#
# THE NONZERO OUTCOMES ARE KEPT APART SO A CALLER CAN SAY WHICH HAPPENED,
# NOT SO ONE OF THEM CAN MEAN "PROCEED". No caller may proceed on any of them.
# Both shipped callers refuse on 1 and 2 alike:
# `orchid jobs prepare` is about to MINT A JOB for this exact actor, and
# lib/handoff.sh's capability arm is deciding whether a candidate goes to
# verification with its mechanical step unperformed -- and an actor neither can
# inspect is no safer than one inspected and found short. The distinction is
# kept because the two call for opposite OPERATOR actions (install or rebind
# the plugin, versus perform the step or bind a different engine), and a
# refusal that names the wrong one sends a human looking for a capability
# nothing ever read.
#
# THERE IS NO "COULD NOT TELL, SO ALLOW" ANSWER HERE, and there must never be.
# A caller that read 2 as permission would waive the gate for every actor it
# happened not to find, which is the fail-open this file exists to close.
#
# BUT 2 IS ALSO NOT A PLACE TO PUT ACTORS THAT MERELY LOOK UNFAMILIAR, and that
# error is just as bad in the other direction. Third-party engines ship
# QUALIFIED ids (`acme/foo`), and a field like `implementer_engine_id` holds
# one because ORCHID DISPATCHED TO THAT PLUGIN -- the id is evidence of a job
# this kernel minted, not of a stranger. Answering 2 for it would hold every
# candidate a third-party engine builds at an operator hand-off FOREVER: no
# hand-off a human can perform makes an unresolvable name resolve, so the state
# has no exit. That is the same INV-14 violation as waiving the gate, reached
# from the opposite side. So the actor is RESOLVED first, through the registry
# that installed it and by either name it answers to (resolve_engine_dir_any),
# and 2 is reserved for resolution that genuinely fails -- which the refusal
# then says, naming the forms it tried.
capability_routing_refusal() {
  local step="$1"
  local engine="${2:-}"
  local dir
  local need
  local missing
  local rrc

  if ! capability_step_valid "$step"; then
    # Deliberately says nothing about the actor, and does not resolve it: the
    # fault is the request's, the plugin named alongside it may be flawless,
    # and a message that mentioned its manifest would send an operator to
    # inspect the one thing here that is certainly not wrong.
    printf 'no step named %s exists, so nothing prices its work and no actor was asked for it -- this is a malformed request, not a capability any plugin lacks (steps: %s)\n' \
      "$step" "$(printf '%s' "$_CAPABILITY_STEPS" | tr -s ' ' ',' | sed -e 's/^,//' -e 's/,$//')"
    return 3
  fi

  need="$(capability_step_requires "$step" | _capability_oneline)"
  # A step priced at nothing asks nothing of the actor, so there is nothing to
  # refuse -- and resolving the actor anyway would let a momentary discovery
  # failure refuse steps this table has never gated.
  [ -n "$need" ] || return 0

  if [ -z "$engine" ]; then
    printf 'step %s needs %s, and no actor was named for it\n' "$step" "$need"
    return 2
  fi
  # BOTH FORMS AN ACTOR IS NAMED BY, through the one registry that installed
  # it: the directory a binding uses, and the qualified id a manifest claims
  # (resolve_engine_dir_any). A third-party actor recorded as `acme/foo` is not
  # an unknown -- orchid dispatched to it, which is why the field holds that id
  # at all -- so it is looked up, not given up on. See that function's header
  # for why the basename is never retried.
  rrc=0
  dir="$(resolve_engine_dir_any "$engine" 2>/dev/null)" || rrc=$?
  if [ "$rrc" -eq 2 ]; then
    printf 'step %s needs %s, and the actor %s is claimed by two installed plugins, so no single manifest says whether it claims them (INV-10)\n' \
      "$step" "$need" "$engine"
    return 2
  fi
  if [ "$rrc" -ne 0 ]; then
    # NAMES BOTH FORMS THAT WERE TRIED. "Does not resolve" alone sends an
    # operator to look for a capability nothing read; this says the plugin is
    # not installed under either name it could answer to, which is a thing
    # they can act on -- install it, or bind the role to the name it is
    # installed under.
    printf 'step %s needs %s, and the actor %s is not installed: no engine directory is named %s, and no installed plugin manifest declares id=%s, so no manifest says whether it claims them\n' \
      "$step" "$need" "$engine" "$engine" "$engine"
    return 2
  fi

  missing="$(capability_step_uncovered "$step" "$dir" | _capability_oneline)"
  [ -n "$missing" ] || return 0
  printf 'step %s needs %s, which the actor %s does not declare (missing: %s)\n' \
    "$step" "$need" "$engine" "$missing"
  return 1
}
