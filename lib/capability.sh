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
# manifest_capabilities, resolve_engine_dir_any and resolve_role_chain, and
# nothing else.

# The closed set of STEP names. Kernel-owned, exactly like lib/hooks.sh's
# `_HOOK_POINTS` and lib/drive.sh's `_DRIVE_BOUNDARY_KINDS`: a step outside
# this set is a programming error or a typo, not a new kind of work, so
# capability_routing_refusal stops on it rather than pricing it at nothing --
# and reports it as the CALLER's error (its exit 3), never as something the
# resolved actor failed to declare.
# Space-padded for the substring membership idiom this codebase already uses.
_CAPABILITY_STEPS=" implement review critique research hook orchestrate mechanical "

# A SINGLE-TOKEN ARGUMENT IS WHAT MAKES THE PADDED IDIOM A MEMBERSHIP TEST, and
# this is the one place in this file where the argument comes from a CALLER.
# `case " a b c " in *" $1 "*)` asks whether the padded list CONTAINS the padded
# argument, which is the same question as membership only while the argument is
# one word: the rows are separated by single spaces, so " review " can sit
# nowhere but where the `review` row is. A COMPOUND argument breaks that
# equivalence -- `review critique` names two ADJACENT rows, so
# " review critique " is a substring of the list and the step validated as
# kernel-owned. Nothing downstream caught it afterwards, because everything
# downstream trusts this answer: capability_step_requires has no arm for it and
# prints nothing, capability_routing_refusal reads that as a step priced at
# nothing and returns 0 without resolving an actor at all, and `orchid jobs
# prepare <task> <role> 'review critique'` -- whose ONLY validation of the
# operation name is this function's exit 3 (libexec/orchid-jobs'
# prepare_capability_gate) -- minted a job for an operation no adapter has ever
# heard of, against any actor whatsoever. That is exactly the fail-open the
# comment above says this closed set exists to close, a typo pricing itself at
# nothing and thereby routing anything anywhere, reached with a space instead of
# a misspelling.
#
# So the argument must be ONE non-empty token before it is looked up at all, and
# a step name that is not is refused here rather than being read as a row this
# table happens not to price. `_capability_have`'s identical idiom needs its own
# version of this guard for the opposite side -- see its header.
capability_step_valid() {  # step -> 0 iff kernel-owned
  case "$1" in
    ''|*[[:space:]]*) return 1 ;;
  esac
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
# The orchestrate row is lib/conform.sh's `_conform_ops_for_dir` table read in
# the other direction. That file already decides which OPERATIONS a plugin's
# declared capabilities imply it can be probed for -- `shell` AND `git`
# together mean it may be asked to orchestrate -- so the same shipped fact is
# used here to refuse a routing rather than to choose a probe. Two files
# reading one implication in opposite directions is deliberate; two files
# inventing two implications would not be.
#
# `implement` IS PRICED ABOVE WHAT THAT TABLE PROBES FOR, and the difference is
# not a disagreement between the two files. conform asks "may this plugin be
# probed for an implement envelope at all", and one atom answers it:
# `workspace_write`. This table asks what the WORK needs, and an implement step
# is not done when a file changes -- IT DELIVERS A COMMIT. Entry to `testing`
# is refused unless `candidate_sha` is set, is the task worktree's HEAD, and
# has a walkable `base..candidate` range (libexec/orchid-task's
# testing_entry_blocker and its lineage gate), so an actor that edits the tree
# and commits nothing produces no candidate for anything downstream to judge:
# the round ends, the attempt is spent, and the task cannot leave
# `implementing`. So the row is `workspace_write` to edit the tree, `git` to
# deliver it, and `shell` to run the repository's own gates before doing so --
# which is what every implementer is asked for in the same breath, and which a
# profile denying on the command STRING cannot do (lesson L017).
#
# roles/implementer.role has said exactly that since it shipped
# (`requires=workspace_write,shell,git`), and that is the reason to state it
# HERE as well rather than lean on it: a kernel-owned row WEAKER than the role
# descriptor that carries the same work is this table's own fail-open. A custom
# role asking for nothing already routes `implement` past the role gate, and a
# row priced at `workspace_write` alone would then admit an actor that can edit
# files and never deliver them -- the gate asked about the WORK having nothing
# to say about the half of the work that produces the candidate.
#
# `mechanical` is the row with no counterpart there, because no adapter is ever
# ASKED to do it: it is the candidate's execution-requiring mechanical work --
# applying a linter's own fix, re-pinning a release checksum, setting the mode
# bit on a newly added executable -- and every one of those is a COMMAND, so
# `shell` is its floor (lesson L017; lib/handoff.sh's header).
#
# WHERE EACH ROW IS ENFORCED, because the answer is not uniform. `implement`,
# `review`, `critique`, `research` and `orchestrate` are enforced at `orchid
# jobs prepare`, the one place a (task, role, operation) triple is bound to an
# engine (prepare validates no operation NAME of its own -- only `hook` gets a
# special case there, for its mandatory `--hook` -- so every one of them
# reaches this table). For the
# five BUILT-IN roles those rows restate a floor the role gate already holds
# (and cannot be shadowed past -- lib/roles.sh refuses a custom role whose id
# equals a core one, INV-10), so there they are defense in depth; they become
# load bearing
# the moment a CUSTOM role is bound, which is the case whose descriptor its own
# publisher writes. `research` is only ever the second of those: no built-in
# role carries it, so its row has no role gate standing behind it at all.
# Where the caller NAMED the actor (`prepare --engine`), that row is asked
# BEFORE the role gate rather than after it -- not to let anything past the
# role gate, which still runs and still refuses on its own terms, but because
# when both refuse the same call only one answer reaches the driver, and 14
# ("no eligible engine") is the one it reads as a WAIT. See
# libexec/orchid-jobs' prepare_capability_gate for why that ordering is a
# report about which fact is permanent, never a permission. Where NO actor was
# named, those same rows are asked TWICE over, of two different populations,
# and both are needed: once of every entry in the role chain, ahead of
# resolution, so a chain in which nobody can do the work answers 19 instead of
# the 14 a driver waits on forever (capability_chain_refusal below, through
# capability_role_chain_refusal); and once DURING resolution, per entry, so an
# incapable entry is FAILED OVER rather than settled on -- see
# lib/resolver.sh's resolve_role_available, whose optional <step> argument is
# this table asked at selection time.
#
# `orchestrate` HAS A SECOND ENFORCEMENT SITE, and it is not `jobs prepare`.
# runners/orchid-tick builds its own request document and never mints a job, so
# the wake that spawns an orchestrator reaches no prepare arm at all; for as
# long as this table was consulted only there, an orchestrator chain that could
# never be woken produced exactly the silent poll this file exists to end --
# the scheduled pump printing "no capable orchestrator available" once per
# staleness window, forever, with nothing journaled and no human told. So the
# same row is asked at the PRE-WAKE probe in runners/orchid-pump and again in
# runners/orchid-tick, through capability_role_chain_refusal below, and the
# pump turns the permanent answer into one journaled operator hand-off.
# roles/orchestrator.role still gates the wake on its own terms and is not
# replaced by this: it happens to require the same two atoms, so on the shipped
# tree the two refuse together and this one is merely the one that says the
# fact is permanent.
#
# `mechanical` is enforced at lib/handoff.sh, because it is a step no adapter
# is dispatched for at all. `hook` is the one row with no enforcement site
# anywhere, because it is priced at nothing and the gate returns before it so
# much as resolves the actor -- a statement about the WORK, not a row this
# paragraph forgot. All seven rows are accounted for above, and that is the
# point of saying EACH: a step added to `_CAPABILITY_STEPS` without a home in
# this paragraph is a step whose gate nobody has chosen.
#
# END OF WHERE EACH ROW IS ENFORCED. tests/inv/test_INV-16_capability_routing.sh
# extracts from the opening line to THIS one and requires every priced step to
# be named backticked inside it, so this marker is the enumeration's boundary
# rather than the first blank comment line under its heading. It has to be,
# because the enumeration outgrew one paragraph: the `orchestrate` subsection
# above put a separator between the heading and the `mechanical` and `hook`
# sentences, and an end inferred from that separator left two of the seven rows
# outside a paragraph still claiming all seven -- with the check reporting the
# reorganisation as an unplaced row, and, the direction that actually costs
# something, ready to admit a row added below the separator without ever
# looking at it. A new subsection goes ABOVE this line.
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
# `research` IS AN OPERATION THIS KERNEL ALREADY NAMES, and leaving it out of
# the set above was the one way this table could refuse work without ever
# pricing it. docs/specs/plugins.md's request union is `implement | review |
# critique | research | hook | orchestrate`, so `orchid jobs prepare <task>
# <role> research` is a well-formed call on a documented operation -- and an
# unpriced step is not answered "needs nothing" by the gate, it is answered
# with the CALLER-ERROR arm (exit 3, "no step named research exists"). That
# reports a documented operation as a malformed request, sends an operator to
# look for a typo there is not, and -- because the arm reaches the caller as
# `orchid_die`'s exit 1 rather than as this file's 19 -- lands in
# runners/orchid-drive as an ordinary launch failure and spends a rung of the
# task's infra_failures ladder on infrastructure that is not broken. That is
# precisely the mis-attribution this whole file exists to end, arriving through
# the gate that was built to end it.
#
# It is priced at `structured_text` AND `citations` because that is what the
# kernel already says the work produces: plugins.md's envelope union is
# `research` -> `citations[]` + `summary`, the same sentence that gives
# `critique` its `findings[]`. Both atoms are kernel-known
# (lib/capabilities.txt), and the shipped custom-role example agrees --
# `acme/researcher`'s descriptor requires `structured_text,citations`, which is
# why `agy` is refused that role for lacking the second (tests/
# test_custom_roles.sh). So this row stands to the researcher role exactly as
# the `review` row stands to roles/reviewer.role: defense in depth where a
# descriptor already asks for the same atoms, load bearing the moment a custom
# role asks for nothing.
#
# Pricing it is deliberately NOT a claim that the operation is finished. No
# shipped adapter serves it (the engines answer `unsupported operation
# 'research'`) and lib/envelope.sh does not yet implement its payload union, so
# a research job still fails downstream exactly as it did before this file
# existed. The point is only that it must fail THERE, on its own merits, rather
# than be refused here as a step the kernel has never heard of.
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
    implement) printf 'workspace_write\nshell\ngit\n' ;;
    review|critique) printf 'structured_text\n' ;;
    research) printf 'structured_text\ncitations\n' ;;
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
#
# AN ENTRY THAT IS NOT ONE TOKEN IS NOT AN ATOM, and dropping it is the same
# guard capability_step_valid applies to the other side of the same idiom -- in
# the direction that matters here, because this string is the HAYSTACK and its
# contents are written by the plugin. `capabilities=` is split on COMMAS ONLY
# (lib/manifest.sh's _manifest_split_csv trims each token's outer whitespace and
# keeps its inner), so a manifest declaring `capabilities=deploy shell` yields
# one entry `deploy shell`, and appending it verbatim would make " shell " a
# substring of this string: the plugin would satisfy the `shell` requirement of
# every step priced on it while claiming no such atom. That is an actor
# declaring its way past a kernel-owned gate -- the one direction this file's
# header says a claim may never buy anything -- and it costs nothing to close,
# because no capability atom this kernel knows contains whitespace
# (lib/capabilities.txt) and manifest_validate already fails such a manifest
# outright as an unknown atom. Skipping it here simply makes the routing gate
# agree with that verdict on a manifest nothing re-validated at read time.
_capability_have() {
  local have=" "
  local atom
  while IFS= read -r atom; do
    [ -n "$atom" ] || continue
    case "$atom" in *[[:space:]]*) continue ;; esac
    have="$have$atom "
  done < <(manifest_capabilities "$1" 2>/dev/null)
  printf '%s' "$have"
}

# capability_step_uncovered <step> <plugin-dir> -- the atoms <step> needs that
# this plugin's manifest does not claim, one per line. No output means covered
# (including for a step priced at nothing) -- so a caller that reads the OUTPUT
# alone gets an answer only for a step this kernel actually prices, and exit 3
# says when it did not.
#
# WHY THE STEP IS RE-VALIDATED HERE, when capability_routing_refusal already
# validated it before ever reaching this line. This function is reachable on
# its own, and for a step name outside `_CAPABILITY_STEPS`
# capability_step_requires prints nothing at all -- which this loop would then
# report as "no atoms uncovered", admitting every actor it was asked about. A
# typo pricing itself at nothing and thereby routing anything anywhere is the
# one direction this whole file exists to close; the header refuses it in the
# DATA (every step gets a row, and the row priced at nothing says why) and
# capability_routing_refusal refuses it in the GATE (its exit 3), and leaving
# it open in the helper both are built out of would be the same fail-open
# arriving through the API. The status is the SAME 3 the gate answers with, and
# nothing is printed with it: the two functions must not disagree about who is
# at fault, and a caller reading only stdout must not be handed a clean-looking
# answer to a question that was never priced.
capability_step_uncovered() {
  local step="$1"
  local dir="$2"
  local have
  local atom
  capability_step_valid "$step" || return 3
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

# capability_chain_refusal <step> <chain> -- the same question asked of a whole
# ROLE CHAIN at once, <chain> being its engine names one per line (lib/
# resolver.sh's resolve_role_chain). Three outcomes, and the caller must again
# read the STATUS as well as the output:
#
#   0, no output   nothing here is a permanent capability fact. The chain is
#                  empty, or it holds an entry this table does not refuse --
#                  so an entry a later pass could route this step to exists.
#   1, one line    REFUSED, and permanently: EVERY entry in the chain is short
#                  an atom the step's work needs. Names each entry's shortfall,
#                  since the operator's remedy has to reach the whole chain.
#   3, one line    THE CALLER IS WRONG -- the step name is outside
#                  `_CAPABILITY_STEPS`, reported exactly as the single-actor
#                  gate reports it, once rather than once per entry.
#
# WHY A CHAIN GATE EXISTS, when capability_routing_refusal already runs at every
# dispatch. It runs on the actor RESOLUTION SETTLED ON, and resolution can fail
# first: `resolve_role_available` walks the chain and exits 14 -- "no eligible
# engine available for role X" -- when no entry is discovered, role-eligible,
# ledger-available and capsuite-passed. runners/orchid-drive reads 14 as a WAIT,
# which is right when the chain came up empty over a ledger window. It is
# exactly wrong when every entry lacks a capability the work needs: no window
# reopens, so the driver waits, journals nothing, raises no boundary and meets
# the same task again every pass. That is the silent dead end INV-16 exists to
# end, arriving one gate EARLIER than the gate built to end it -- the same
# defect libexec/orchid-jobs' prepare_capability_gate fixed for the arm where
# the caller NAMED the actor, reached through the role chain instead.
#
# AND IT IS ASKED AHEAD OF THAT RESOLUTION, not behind it. It used to sit
# behind, on the reasoning that a chain whose first capable entry is available
# resolves normally and should be gated on the engine that actually won -- true,
# and still true, because this function refuses ONLY when EVERY entry is short.
# A chain holding one entry it does not refuse is one resolution may still pick,
# so asking first can refuse nothing a dispatch would have used. What asking
# first buys is the report: behind the resolution, the caller has already let
# resolve_role_available print its own "no eligible engine available for role X"
# to stderr, and the operator then meets a WAIT and a PERMANENT REFUSAL about
# the same call, in that order, and has to work out which of the two describes
# their repository. Only one of them does. Asked first, only the refusal is
# emitted, and the wait line is printed exactly when the wait is real.
#
# ONLY A MISSING ATOM COUNTS, which is what stops this annexing every other
# reason a chain comes up empty. A rate limit reopens on its own; a missing
# capsuite record is one `orchid plugins test` away; an uninstalled plugin is an
# install. Each is a different report with a different remedy, each already has
# its own words in resolve_role_available's message, and re-reporting one of
# them here would send an operator to audit a manifest over a ledger window. A
# ROLE requirement that no step prices is left alone for the same reason:
# `requires=` may ask for more than the work does (a role wanting `network`,
# say), and that refusal belongs to the role gate, in its own words, at 14 --
# the same division the named-actor arm's GREEN twin holds to. A missing atom
# is the one fact this file owns and the one no later pass changes, so it is the
# only one that turns the wait into a hand-off.
#
# EVERY ENTRY, NEVER ANY. One entry this table does not refuse means a later
# pass can route the step somewhere, so the wait is a real wait; the loop
# therefore stops at the first such entry and says nothing at all. An entry it
# cannot answer for (2 -- not installed under either name, or an id two plugins
# claim) counts as such an entry HERE, which is the opposite of what the
# single-actor gate does with 2, and deliberately: there, 2 is a reason not to
# proceed with a routing that was about to happen, and reading it as permission
# would waive the gate. Here nothing is about to happen -- resolution has
# already refused -- and the only question is whether to RE-REPORT that refusal
# as a permanent capability fact. An unreadable manifest is not one.
capability_chain_refusal() {
  local step="$1"
  local chain="${2:-}"
  local entry
  local why
  local rc
  local detail=""
  local entries=0

  # Validated up front and BY THE SINGLE-ACTOR GATE ITSELF, so the two can
  # never disagree about who is at fault or say it in different words: for a
  # step outside the closed set that function answers 3 with its caller-error
  # line whatever actor it is handed, so it is handed none. Doing it here rather
  # than inside the loop also answers it for an EMPTY chain, which has no first
  # entry to ask -- a mistyped operation is the caller's error whether or not
  # the role happened to be bound.
  if ! capability_step_valid "$step"; then
    rc=0
    capability_routing_refusal "$step" "" || rc=$?
    return "$rc"
  fi

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entries=$((entries + 1))
    rc=0
    why="$(capability_routing_refusal "$step" "$entry")" || rc=$?
    if [ "$rc" -ne 1 ]; then
      return 0
    fi
    if [ -z "$detail" ]; then detail="$why"; else detail="$detail; $why"; fi
  done <<< "$chain"

  # An empty chain says nothing about capabilities: whatever emptied it --
  # an unbound custom role, a config key set to nothing -- is a fault
  # resolve_role_chain reports itself, in a message that names the key to set.
  [ "$entries" -gt 0 ] || return 0
  printf '%s\n' "$detail"
  return 1
}

# capability_role_chain_refusal <repo> <role> <step> -- capability_chain_refusal
# asked about a role BY NAME, resolving the chain itself. Same three outcomes,
# same words, same statuses.
#
# ONE FUNCTION BECAUSE THREE CALLERS ASK THE SAME QUESTION, and they must never
# drift into three different answers: `orchid jobs prepare`'s chain arm
# (libexec/orchid-jobs), the scheduled pump's pre-wake probe and the headless
# tick's own resolution (runners/orchid-pump, runners/orchid-tick). Each of
# them stands in front of a `resolve_role_available` call whose exit 14 the
# caller would otherwise read as a wait; each therefore needs the SAME
# classification of that 14 into "a window that reopens" and "a shortfall no
# pass changes", and a second inline copy of the resolve-then-classify pair is
# a second place for that line to be drawn differently.
#
# The chain's own stderr is dropped: this is a read of config for a question
# resolution has already reported on in its own words, and an unreadable chain
# is simply an empty one -- which capability_chain_refusal answers by declining
# to speak.
capability_role_chain_refusal() {
  local repo="$1" role="$2" step="$3"
  local chain
  local rc=0
  chain="$(resolve_role_chain "$repo" "$role" 2>/dev/null)" || chain=""
  capability_chain_refusal "$step" "$chain" || rc=$?
  return "$rc"
}

# capability_chain_handoff_line <role> <step> <binding> <detail> -- the ONE
# operator-facing sentence a RUN-LEVEL capability refusal is recorded as: what
# was refused, that no later pass changes it, and the config key that binds the
# chain it was refused against.
#
# DISTINCT FROM lib/drive.sh's drive_capability_handoff_text, and the split is
# deliberate rather than duplication. That function produces the pair the
# DRIVER writes for a refused TASK step -- a boundary reason and a task-scoped
# journal line, with a reviewer arm that names the repin verb because a
# reviewer slot's row is pinned. This one is for the refusal that belongs to no
# task at all: the wake the pump and the tick are about to perform on behalf of
# the whole run. A task-scoped hand-off recorded against no task would be
# filed where nobody looks for it, and the repin advice would name a plan that
# does not exist here.
#
# ONE LINE, because both emitters put it somewhere that reads a multi-line
# value the way it reads no value at all: BLOCKERS.md's entry body, and a
# runner's own stderr.
capability_chain_handoff_line() {
  local role="$1" step="$2" binding="$3" detail="$4"
  printf "no actor can be routed the '%s' step for role '%s': %s. Every engine in that chain is short an atom the work needs, so no ledger window, capsuite run or later pass changes it (INV-16) — an operator performs this step, or binds an engine whose manifest covers it at %s\n" \
    "$step" "$role" "$detail" "$binding"
}
