#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# INV-16: a step that requires a capability the resolved actor does not declare
# is never dispatched to it -- it becomes an operator hand-off instead.
#
# THE DEFECT THIS GATES. Plugin manifests have always declared `capabilities=`,
# and nothing consulted them when deciding whether a STEP could be assigned to
# an actor. So the tick routinely asked an implementer to run a verifier,
# re-pin a checksum or set a mode bit -- all of which a profile that denies on
# the command STRING refuses (lesson L017). In this repository's own runs that
# cost T005 two attempt cycles being told twice to fix findings it could not
# see, and T014 three to a pin it could not refresh. Every one of those rounds
# was a full engine session spent on work that could not have succeeded, and
# the task's attempt budget paid for it.
#
# THE TWO DIRECTIONS, and they are not symmetric. A capability atom is a CLAIM
# BY THE PLUGIN, NOT A GRANT (docs/beta-qualification.md): the shipped claude
# adapter declares `shell` and still launches its implement path with a
# file-edit permission mode and no command allowlist. So a MISSING atom is
# decisive and a PRESENT one settles nothing -- which is why the last part of
# this file proves the rule can only ever ROUTE MORE WORK TO A HUMAN. An actor
# must not be able to declare its way past a gate an operator set.
#
# RED: a step whose work needs `shell` is routed to an actor whose manifest
#      declares everything around it (structured_text, workspace_write, git)
#      and not that -- both directly at the routing gate and end to end through
#      `orchid jobs prepare`, where the actor reaches the step through a custom
#      role whose descriptor asks for nothing at all, so the existing role gate
#      admits it. Both must be REFUSED, naming `shell`, with no job manifest
#      minted. The same hole is then driven through the TABLE rather than the
#      code: an actor declaring NO capabilities whatsoever, bound to that same
#      custom role, is routed a `review` step -- priced at nothing, that gate
#      returns 0 before it so much as resolves the actor, and an unpriced row
#      admits every routing there is. It must be refused too, naming
#      `structured_text`. A third input is the direction that must never work:
#      an actor DECLARING `shell`, fed to a repository whose operator asked
#      for the hand-off, must not clear it -- a claim by a plugin is not a
#      grant, and
#      an actor that could vote itself past a human's gate would make the whole
#      rule decorative. A fourth is the actor that is genuinely NOT INSTALLED --
#      a qualified id (`zzz/ghost`) no engine directory answers to and no
#      installed manifest claims: the hand-off must be REQUIRED and the message
#      must name it, because a gate that answers "no objection" about a manifest
#      it never read is a fail-open hole exactly where third-party plugins live.
#      It must reach that verdict without retrying the basename, so a directory
#      called `ghost` published by somebody else settles nothing about
#      `zzz/ghost`. A fifth is the ADVICE a hand-off hands over: a refused hook
#      step must name the point and a config key orchid actually reads, never
#      the `role.hook` key that pouring a hook job's placeholder role positional
#      into `role.<role>` invents -- an operator sent to a key the kernel never
#      reads edits a file it ignores while the boundary survives. And a sixth
#      runs the real driver: a refusal on the ESCALATION LADDER's relaunch must
#      raise the named hand-off and be journaled, rather than be swallowed and
#      left to burn the task's infra_failures down to `blocked` for a reason
#      nothing recorded. A seventh is the rest of that same advice: a refused
#      REVIEWER SLOT must name `orchid jobs review-plan <task> --repin` as well
#      as the config key, because the attempt's slot table is PINNED -- an
#      operator who binds a capable engine and stops there moves live routing
#      while the walk keeps dispatching the pinned row, which is the "edit a
#      key, nothing happens" dead end the key half exists to prevent, reached
#      one step later. An eighth is the arm where NO ACTOR IS NAMED AT ALL --
#      the ordinary dispatch, which resolves a role's failover chain. When that
#      walk yields nobody it exits 14, and 14 is a wait; where every entry in
#      the chain is short an atom the step needs, no window reopens and the
#      wait is forever, so it must come back 19 instead -- at `jobs prepare`,
#      and through the real driver on the DISPATCH walk (the other launch path
#      from the sixth case's relaunch), where it must journal the refusal, raise
#      the named boundary and leave the task where it stood. That arm is where
#      most shortfalls actually arrive: a built-in role's `requires=` and its
#      step's price are the same atoms, so the role gate refuses before any
#      actor exists to ask about.
# GREEN: the SAME step, the SAME call, the SAME role and the SAME task, with
#      one atom added to the actor's manifest, must be admitted -- silently at
#      the gate and with a real job manifest through `jobs prepare`; likewise
#      the review step, for an actor declaring exactly `structured_text` and
#      nothing else, so the refusal above is about that one atom rather than
#      about a sparse manifest. A mistyped operation, meanwhile, must NOT come
#      back as either: it is the caller's error, and reporting it as a
#      capability refusal hands an operator a hand-off boundary about a plugin
#      that is behaving perfectly. And a repository with neither arm objecting
#      must leave the pause off. A third-party engine that IS installed must
#      RESOLVE BY ITS QUALIFIED ID (`acme/foo`) and proceed, addressed either
#      that way or by the directory it is installed under: refusing the
#      qualified form would hold every candidate that engine builds at a
#      hand-off no operator act can ever clear, since nothing a human does makes
#      an unresolvable name resolve. That lookup must still refuse an installed
#      third-party actor whose manifest is genuinely short, or it is a waiver
#      wearing a resolver's clothes. The ROLE arm of that same advice must still
#      name `role.<role>`, so naming the hook point is a correction to the one
#      step whose role positional means nothing rather than a retreat from
#      naming a key at all. And the same escalation relaunch must mint
#      its job once the bound actor declares what the step needs. The repin
#      advice is held to the same standard twice over: no OTHER role's advice
#      may name a review-plan verb (nothing else has a pinned row for one to
#      move), and the verb itself is RUN against a repository whose pinned slot
#      holds an engine `review` refuses -- it must rebind that slot to the
#      engine the operator bound, durably and journaled, leaving the step
#      routable. Advice that names a remedy proves nothing until the remedy is
#      run. And the chain arm must keep every OTHER reason a chain comes up
#      empty exactly as it was: one entry the table does not refuse, an entry
#      no manifest can be read for, and a mistyped operation must all leave the
#      answer 14 (or the caller's own error), because each has a different
#      remedy and re-reporting one as a capability hand-off sends an operator
#      to audit a manifest that is fine or absent -- while the identical call
#      against a chain naming a capable actor must resolve and mint, at the
#      verb and through the driver alike. Without those
#      the refusals above would be evidence only that something rejects things,
#      which is exactly the shape this repository keeps producing.
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"; source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"; source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
source "$REPO_ROOT/lib/review.sh"; source "$REPO_ROOT/lib/capability.sh"
source "$REPO_ROOT/lib/handoff.sh"; source "$REPO_ROOT/lib/drive.sh"
export ORCHID_ROOT="$REPO_ROOT"
export HOME="$MACHINE_HOME"; mkdir -p "$HOME/.orchid"
export ORCHID_ENGINES_DIR="$WORK/eng"; mkdir -p "$WORK/eng"
export ORCHID_ROLES_DIR="$WORK/roles"; mkdir -p "$WORK/roles"

# mk_engine <name> <capabilities> -- the same stub shape tests/test_failover.sh
# uses. Only the manifest matters here: every assertion below reads a
# DECLARATION, and nothing in this file ever runs an adapter.
mk_engine() {
  local name="$1" caps="$2" dir
  dir="$WORK/eng/$name"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nentrypoint=run\n' \
    "$name" "$caps" > "$dir/plugin.conf"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/run"
  chmod +x "$dir/run"
}

# ===========================================================================
# 1 -- the table is kernel data, and it is the table this file then tests
# against. Asserted explicitly so a row silently losing its atoms cannot make
# every refusal below stop firing while the file still reads as a pass.
# ===========================================================================
assert_eq "shell" "$(capability_step_requires mechanical)" \
  "INV-16: the mechanical step (a lint fix, a checksum re-pin, a mode bit) needs shell"
assert_eq "$(printf 'shell\ngit')" "$(capability_step_requires orchestrate)" \
  "INV-16: orchestrate needs shell and git, mirroring lib/conform.sh's capability-implication table"
assert_eq "$(printf 'workspace_write\nshell\ngit')" "$(capability_step_requires implement)" \
  "INV-16: implement needs workspace_write to edit the tree, git to DELIVER it and shell to run the repository's own gates first — a round that commits nothing produces no candidate (entry to testing is refused without one), so pricing it at workspace_write alone would admit an actor that can edit files and never deliver them"
assert_eq "structured_text" "$(capability_step_requires review)" \
  "INV-16: review needs structured_text — with this row empty, a capability-free actor reaching review through a custom role met no gate at all"
assert_eq "structured_text" "$(capability_step_requires critique)" \
  "INV-16: critique needs structured_text for the same reason review does — it returns the same kind of structured envelope"
assert_eq "$(printf 'structured_text\ncitations')" "$(capability_step_requires research)" \
  "INV-16: research needs structured_text and citations — docs/specs/plugins.md's envelope union for it is citations[] + summary, the same sentence that gives critique its findings[]"
# The one row priced at nothing, asserted so it stays a DECISION. A row that
# quietly emptied would make this gate stop firing while every refusal above
# still passed; a row that quietly gained an atom would refuse hook handlers
# that ship today declaring none.
assert_eq "" "$(capability_step_requires hook)" \
  "INV-16: hook is the one step priced at nothing — a handler is bound by name from config and no hook contract has ever asked one for a capability"
capability_step_valid mechanical || fail "INV-16: mechanical must be a kernel-owned step"
if capability_step_valid not_a_real_step; then
  fail "INV-16: an unknown step name must not validate — a typo that priced itself at nothing would route anything anywhere"
fi

# EXHAUSTIVE OVER THE STEP SET, which is the assertion the individual rows
# above cannot make. A step the table forgets to price is a step this gate
# cannot refuse, so an omission reads exactly like a deliberate "needs
# nothing" and admits every actor — the fail-open arriving through the DATA.
# `hook` is the single step allowed to be free, and it is named here so that
# adding a step to `_CAPABILITY_STEPS` without pricing it fails this gate
# instead of silently opening it.
while IFS= read -r _step; do
  [ -n "$_step" ] || continue
  if [ "$_step" != hook ] && [ -z "$(capability_step_requires "$_step")" ]; then
    fail "INV-16: step '$_step' is priced at nothing — every step but 'hook' must state what its work needs, or an actor declaring nothing is routed it"
  fi
done <<< "$(printf '%s' "$_CAPABILITY_STEPS" | tr ' ' '\n')"

# AND EXHAUSTIVE OVER WHERE EACH ROW IS ENFORCED, which is the half the gate
# above cannot see. `lib/capability.sh` prices the work in one place and names
# the GATE that acts on each price in another — an enumeration that opens "WHERE
# EACH ROW IS ENFORCED" and closes at an explicit "END OF WHERE EACH ROW IS
# ENFORCED" marker. Pricing a step without adding it there leaves a row whose
# gate nobody has chosen, and the file reads as though somebody did: that is
# exactly what happened when `research` was added to `_CAPABILITY_STEPS` and the
# enumeration was not, so the one row with no role gate behind it was the one
# row the paragraph never placed.
#
# The block ends at that CLOSING MARKER rather than at the first bare comment
# line after the heading, because the enumeration is several paragraphs long.
# Inferred from the layout, its end moved the moment the prose was reorganised:
# an `orchestrate` subsection introduced a separator above the `mechanical` and
# `hook` sentences, which put two of the seven rows outside a paragraph that
# still said it accounted for all seven. That direction is only noisy — the
# expensive one is a row ADDED below the separator, named in the enumeration,
# and never seen by this gate. The marker's presence is asserted below for the
# same reason: absent it, `sed` runs to end of file and this would search the
# whole module for a name instead of the paragraph.
#
# Matched on the BACKTICKED name, the form the paragraph uses for every row,
# because a bare substring passes on a word that merely contains it (`review`
# inside `reviewer`, `implement` inside `implementer`) — a false pass in an
# assertion whose entire job is to catch an omission. The backtick lives in a
# variable: written inline inside the double quotes this comparison needs, it
# would be command substitution rather than a character.
_bt='`'
_enforced="$(sed -n '/WHERE EACH ROW IS ENFORCED/,/END OF WHERE EACH ROW IS ENFORCED/p' "$REPO_ROOT/lib/capability.sh")"
[ -n "$_enforced" ] \
  || fail "INV-16: lib/capability.sh has no 'WHERE EACH ROW IS ENFORCED' paragraph — without it this gate passes vacuously and the enumeration it guards is unguarded"
case "$(printf '%s\n' "$_enforced" | tail -n 1)" in
  *"END OF WHERE EACH ROW IS ENFORCED"*) ;;
  *) fail "INV-16: lib/capability.sh's 'WHERE EACH ROW IS ENFORCED' enumeration has no closing 'END OF WHERE EACH ROW IS ENFORCED' marker — the extraction ran to end of file, so the check below would accept a step named anywhere in the module rather than inside the enumeration" ;;
esac
while IFS= read -r _step; do
  [ -n "$_step" ] || continue
  case "$_enforced" in
    *"$_bt$_step$_bt"*) ;;
    *) fail "INV-16: step '$_step' is priced but named nowhere in lib/capability.sh's 'WHERE EACH ROW IS ENFORCED' paragraph — every row is enforced somewhere (or, like 'hook', priced at nothing and said to be), and a row with no stated gate is one nobody chose" ;;
  esac
done <<< "$(printf '%s' "$_CAPABILITY_STEPS" | tr ' ' '\n')"

# ===========================================================================
# 2 -- RED: a shell-requiring step routed to an actor declaring NO shell.
#
# `noshell` declares every atom around the one that matters (structured_text,
# workspace_write, git) precisely so the refusal below cannot be an actor that
# declares nothing being rejected by anything.
# ===========================================================================
mk_engine noshell "structured_text,workspace_write,git"
rc=0; why="$(capability_routing_refusal mechanical noshell)" || rc=$?
assert_eq 1 "$rc" \
  "INV-16: routing a shell-requiring step to an actor that declares no shell must be REFUSED (exit 1), not permitted"
assert_match "does not declare" "$why" "INV-16: the refusal says what the actor failed to declare"
assert_match "missing: shell" "$why" "INV-16: and names the exact atom, so an operator is not left guessing"
red_case 'a mechanical step (needs shell) routed to an actor declaring structured_text, workspace_write and git was refused, naming shell as the missing atom'

# ===========================================================================
# 3 -- GREEN twin: the SAME step, the SAME call, one atom added to the actor's
# manifest. Without this the refusal above would be evidence only that
# something rejects things.
# ===========================================================================
mk_engine withshell "structured_text,workspace_write,git,shell"
rc=0; why="$(capability_routing_refusal mechanical withshell)" || rc=$?
assert_eq 0 "$rc" \
  "INV-16: the same step must be routable to an actor that DOES declare shell — otherwise the refusal above is not about capabilities at all"
assert_eq "" "$why" "INV-16: an admitted routing says nothing (it is not a grant, so it makes no claim)"
green_case 'the same mechanical step routed to the same actor plus a shell declaration was admitted silently, so the refusal above is a capability decision'

# An unpriced step is admitted for the very same actor the priced one was
# refused for: the rule gates the WORK, not the actor.
rc=0; capability_routing_refusal hook noshell >/dev/null || rc=$?
assert_eq 0 "$rc" "INV-16: a step priced at nothing is routable to any actor — this table adds requirements, it never invents them"

# The third outcome, kept apart from the other two on purpose: an actor that
# cannot be resolved at all is UNDETERMINED (2), never quietly "covered".
rc=0; why="$(capability_routing_refusal mechanical no_such_engine)" || rc=$?
assert_eq 2 "$rc" "INV-16: an unresolvable actor is undetermined (2), so a caller can tell it from a declared shortfall (1)"
assert_match "is not installed" "$why" "INV-16: and says so rather than reporting a missing capability it never read"
assert_match "no_such_engine" "$why" "INV-16: and names the actor it could not find, which is the only thing an operator can act on"

# A step name outside the closed set is refused rather than priced at nothing:
# a typo that silently required no capability would admit every routing it was
# asked about, which is the one direction this whole file exists to close.
#
# It is its OWN outcome (3), kept apart from the actor's shortfall (1), because
# the two blame opposite parties. An unknown step is a malformed request; the
# plugin named beside it may be flawless, and answering "the actor does not
# declare what that work needs" sends an operator to audit a manifest that is
# not the problem while the actual typo appears nowhere in the message.
rc=0; why="$(capability_routing_refusal not_a_real_step withshell)" || rc=$?
assert_eq 3 "$rc" "INV-16: an unknown step is a CALLER error (3), never treated as one that asks for nothing and never as the actor's shortfall (1)"
assert_match "no step named" "$why" "INV-16: and the refusal says the step is unknown rather than blaming the actor"
assert_match "not a capability any plugin lacks" "$why" \
  "INV-16: and says so explicitly — an operator reading this must not go looking for a capability nothing ever read"
case "$why" in
  *withshell*) fail "INV-16: a caller error must not name the actor at all — it is the one party here that is certainly not at fault" ;;
esac

# THE SAME CLOSED SET GATES THE HELPER THE REFUSAL IS BUILT OUT OF, and this is
# the assertion the one above cannot make. capability_step_uncovered is
# reachable on its own, and for an unknown step capability_step_requires prints
# nothing — so a version that only looped would report "no atoms uncovered" and
# hand every caller that read its OUTPUT the very fail-open the gate refuses,
# arriving through the API instead of through the data. Same exit 3 the gate
# answers with, because the two must not disagree about who is at fault; and
# nothing on stdout, because a clean-looking answer to a question that was never
# priced is exactly what a caller must not be able to read.
rc=0; uncovered="$(capability_step_uncovered not_a_real_step "$WORK/eng/withshell")" || rc=$?
assert_eq 3 "$rc" \
  "INV-16: capability_step_uncovered must refuse an unknown step as a caller error (3), not report it as covered"
assert_eq "" "$uncovered" \
  "INV-16: and print nothing with it, so no caller reading stdout alone mistakes an unpriced step for a covered one"
# The GREEN twin, against the same actor and the same helper: a step the kernel
# does price still answers about the manifest, so the refusal above is the step
# name being unknown and not the helper having stopped working.
rc=0; uncovered="$(capability_step_uncovered mechanical "$WORK/eng/noshell")" || rc=$?
assert_eq 0 "$rc" \
  "INV-16: a kernel-owned step still answers from the manifest, so the caller-error refusal above is about the step name"
assert_eq "shell" "$uncovered" \
  "INV-16: and names the atom the actor did not claim"

# ===========================================================================
# 4 -- END TO END, and the hole a role gate cannot close. `orchid jobs prepare`
# is where a (task, role, operation) triple is BOUND to an engine.
#
# The role gate (lib/roles.sh) reads `requires=` from the ROLE'S DESCRIPTOR,
# and a `kind=role` plugin ships its own descriptor -- so a publisher can
# declare a role that asks for nothing and bind its own engine to it. That is
# an actor declaring its way past the only capability gate there used to be.
# The step table is kernel-owned and refuses anyway.
# ===========================================================================
printf 'id=runner\ndescription=a custom role whose descriptor asks for nothing at all\n' \
  > "$WORK/roles/runner.role"
crepo="$WORK/crepo"; mkdir -p "$crepo/.orchid/tasks" "$crepo/.orchid/reviews"
(cd "$crepo" && git init -q . && git commit -q --allow-empty -m root)
printf 'verify=true\nrole.runner=noshell\n' > "$crepo/orchid.config"
export ORCHID_REPO="$crepo"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create TC demo >/dev/null

# Sanity, and it is the whole point of this part: the ROLE gate admits this
# pairing. If it refused, the exit 19 below would prove nothing new.
role_eligible runner "$WORK/eng/noshell" \
  || fail "INV-16 sanity: the custom role's own descriptor must ADMIT this actor, or part 4 is testing the role gate instead"

rc=0; err="$("$ORCHID_BIN" jobs prepare TC runner orchestrate 2>&1 1>/dev/null)" || rc=$?
assert_eq 19 "$rc" \
  "INV-16: jobs prepare refuses to bind an orchestrate step (needs shell, git) to an actor declaring no shell, even through a role that asks for nothing"
assert_match "refusing to route" "$err" "INV-16: the refusal names itself as a routing decision"
assert_match "missing: shell" "$err" "INV-16: and names the atom the actor never claimed"
[ -z "$(list_dir_files "$crepo/.orchid/runtime/jobs")" ] \
  || fail "INV-16: a refused routing must mint NO job manifest — a prepared job is a step already assigned"
red_case 'orchid jobs prepare exited 19 and minted nothing when a shell-requiring step was routed, through a role declaring no requirements, to an actor declaring no shell'

# GREEN twin, end to end: only the bound engine changes.
printf 'verify=true\nrole.runner=withshell\n' > "$crepo/orchid.config"
rc=0; mf="$("$ORCHID_BIN" jobs prepare TC runner orchestrate)" || rc=$?
assert_eq 0 "$rc" "INV-16: the identical step, role and task must be routable to an actor that declares shell and git"
[ -f "$mf" ] || fail "INV-16: an admitted routing mints the job manifest it always did"
green_case 'the identical prepare, with only the bound engine changed to one declaring shell, minted its job manifest — so the exit 19 above is a capability refusal and not a broken verb'

# ===========================================================================
# 4b -- THE SAME HOLE, ARRIVING THROUGH THE TABLE INSTEAD OF THROUGH THE CODE.
#
# Part 4 proves the gate fires for a step the table PRICES. A step priced at
# nothing never reaches it: `capability_routing_refusal` returns 0 before it
# resolves an actor at all, so an unpriced row admits every routing, and the
# admission is indistinguishable from a plugin that genuinely covers the work.
#
# `review` and `critique` were exactly that. Their floor lives in the BUILT-IN
# judging roles' descriptors (roles/reviewer.role, arbiter, plan_critic), which
# made pricing them here look redundant -- and it is redundant for those five.
# It is not redundant for the case this whole file exists for: a `kind=role`
# plugin ships its own `descriptor.role`, so a publisher declares a role asking
# for nothing, binds its own engine, and reaches a review step. With the row
# empty, the kernel-owned gate had nothing to say and an actor declaring NO
# CAPABILITIES AT ALL was routed work whose whole output is a structured
# envelope.
#
# So the actor here declares nothing whatsoever -- the weakest claim a valid
# manifest can make -- and the role it arrives through asks for nothing either.
# Every gate in the kernel except this table's row is open.
# ===========================================================================
mk_engine nocaps ""
assert_eq "" "$(manifest_capabilities "$WORK/eng/nocaps")" \
  "INV-16 fixture: the actor for this part must declare NOTHING, or it is not the case the empty row admitted"
role_eligible runner "$WORK/eng/nocaps" \
  || fail "INV-16 sanity: the custom role's descriptor must ADMIT an actor declaring nothing, or this part tests the role gate instead of the table"

rc=0; why="$(capability_routing_refusal review nocaps)" || rc=$?
assert_eq 1 "$rc" \
  "INV-16: routing a review step to an actor that declares no capabilities at all must be REFUSED — a review's whole product is a structured envelope"
assert_match "missing: structured_text" "$why" "INV-16: naming the atom the actor never claimed"
rc=0; why="$(capability_routing_refusal critique nocaps)" || rc=$?
assert_eq 1 "$rc" "INV-16: and the same for critique, which returns the same kind of envelope"

printf 'verify=true\nrole.runner=nocaps\n' > "$crepo/orchid.config"
jobs_before="$(list_dir_files "$crepo/.orchid/runtime/jobs" | wc -l | tr -d ' ')"
rc=0; err="$("$ORCHID_BIN" jobs prepare TC runner review 2>&1 1>/dev/null)" || rc=$?
assert_eq 19 "$rc" \
  "INV-16: jobs prepare refuses to bind a review step to an actor declaring no capabilities, reached through a custom role that requires none"
assert_match "refusing to route" "$err" "INV-16: the refusal names itself as a routing decision"
assert_match "missing: structured_text" "$err" "INV-16: and names the atom, so the operator is not left to guess which claim was absent"
assert_eq "$jobs_before" "$(list_dir_files "$crepo/.orchid/runtime/jobs" | wc -l | tr -d ' ')" \
  "INV-16: and mints NO job manifest — a prepared job is a step already assigned"
red_case 'an actor declaring no capabilities at all, bound to a custom role whose descriptor requires nothing, was refused a review step at orchid jobs prepare (exit 19, naming structured_text) with no job minted'

# GREEN twin: the same step, role, task and repository, with an actor declaring
# EXACTLY the one atom the row prices. Without it the refusal above would be
# evidence only that a manifest declaring nothing upsets something.
mk_engine textonly "structured_text"
printf 'verify=true\nrole.runner=textonly\n' > "$crepo/orchid.config"
rc=0; mf2="$("$ORCHID_BIN" jobs prepare TC runner review)" || rc=$?
assert_eq 0 "$rc" "INV-16: the identical review step must be routable to an actor declaring structured_text and nothing else"
[ -f "$mf2" ] || fail "INV-16: an admitted review routing mints the job manifest it always did"
green_case 'the identical prepare, with only the bound engine changed to one declaring exactly structured_text, minted its job manifest — so the refusal above is about that one atom and not about a sparse manifest'

# AND THE FAULT IS ATTRIBUTED TO THE RIGHT PARTY. A step name this kernel does
# not know is the CALLER's error: the actor bound here is the very one admitted
# a line ago. Answered as an INV-16 refusal it would exit 19, which the driver
# turns into a journaled operator-handoff boundary that persists until a human
# acts -- sending that human to audit a plugin behaving perfectly while the
# typo, the one thing they could fix, appears nowhere in the message.
rc=0; err="$("$ORCHID_BIN" jobs prepare TC runner reviewww 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-16: an unknown operation must not mint a job"
[ "$rc" -ne 19 ] \
  || fail "INV-16: an unknown operation must NOT be reported as a capability refusal — 19 is an operator hand-off about the actor, and the actor here is the one just admitted"
assert_match "unknown operation" "$err" "INV-16: the caller error says the operation is unknown"
case "$err" in
  *"refusing to route"*) fail "INV-16: a mistyped operation must not be phrased as a routing refusal about the resolved actor" ;;
  *textonly*) fail "INV-16: and must not name the actor at all — it is not implicated in a step name that does not exist" ;;
esac

# ===========================================================================
# 4c -- THE GATE THAT REFUSED FIRST AND SAID THE WRONG THING. Both gates can
# refuse one call, and only one answer reaches the driver.
#
# `orchid jobs prepare --engine <name>` is how a REVIEWER SLOT is dispatched,
# and review_routing's session-independent fallback hands slot 1 the engine that
# BUILT the candidate -- an arm that skips the reviewer-eligibility check every
# chain entry passes. So the slot can be pinned to an implementer-grade engine
# (`workspace_write,shell,git`) that declares no `structured_text`: refused by
# roles/reviewer.role AND by the `review` row here.
#
# Asked in the order this file used to be asked in, role eligibility answered
# first and the driver was handed exit 14. 14 is a WAIT (drive_launch's header
# says so: the usual cause is a ledger window that reopens by itself), so the
# pass journaled nothing, raised no boundary, and came back next pass to wait
# again. The routing refusal INV-16 exists to name never fired and the hand-off
# it exists to produce was never recorded -- the task simply stopped moving,
# which is the silent dead end this whole invariant is about. 19 is the answer
# no later pass can change, and it is the one runners/orchid-drive turns into a
# journaled `operator-handoff` (proved end to end through the real runner in
# part 7, and handed the reviewer slot's own binding key in part 8a).
#
# THE ORDERING IS A REPORT, NEVER A WAIVER, which is what the GREEN twin below
# is for: an actor that covers the STEP and is still ineligible for the ROLE is
# refused by the role gate, at 14, in its own words.
# ===========================================================================
mk_engine builderonly "workspace_read,workspace_write,shell,git"
rc=0; capability_routing_refusal review builderonly >/dev/null || rc=$?
assert_eq 1 "$rc" \
  "INV-16 fixture: the actor for this part must be short exactly for the review step, or the exit below says nothing about the ordering"
if role_eligible reviewer "$WORK/eng/builderonly"; then
  fail "INV-16 fixture: this actor must ALSO be refused by roles/reviewer.role — a part about which of two refusals is reported needs both of them to fire"
fi

jobs_before="$(list_dir_files "$crepo/.orchid/runtime/jobs" | wc -l | tr -d ' ')"
rc=0; err="$("$ORCHID_BIN" jobs prepare TC reviewer review --engine builderonly 2>&1 1>/dev/null)" || rc=$?
assert_eq 19 "$rc" \
  "INV-16: when the role gate and the step table both refuse a named actor, the answer is the capability refusal (19) — reported as 14 the driver reads it as a wait, journals nothing and raises no hand-off"
assert_match "missing: structured_text" "$err" \
  "INV-16: and names the atom the step needs, not merely that some engine was ineligible for some role"
assert_eq "$jobs_before" "$(list_dir_files "$crepo/.orchid/runtime/jobs" | wc -l | tr -d ' ')" \
  "INV-16: and mints no job manifest, exactly as the later gate did"
red_case 'a reviewer slot pinned to an implementer-grade engine declaring no structured_text was refused with the capability answer (19, naming structured_text) that the driver turns into a journaled operator hand-off, instead of the exit 14 it reads as a wait'

# GREEN twin: the role gate still refuses on its own terms. `textonly` declares
# exactly what the `review` step needs, so the table has no objection at all --
# and the custom role it is asked for here requires `network` on top, which is
# a ROLE's requirement and no step's. That must still be 14, and must still say
# which capability the ROLE asked for.
printf 'id=netrunner\nrequires=structured_text,network\ndescription=a custom role asking for more than the step does\n' \
  > "$WORK/roles/netrunner.role"
rc=0; capability_routing_refusal review textonly >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" \
  "INV-16 fixture: the step table must have NO objection to this actor, or the 14 below is not evidence that the role gate still runs"
rc=0; err="$("$ORCHID_BIN" jobs prepare TC netrunner review --engine textonly 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" \
  "INV-16: an actor that covers the STEP and not the ROLE is still refused by the role gate at 14 — asking the step table first orders two reports, it does not waive one of them"
assert_match "network" "$err" \
  "INV-16: and the role gate's own refusal names the capability the ROLE asked for, which no step prices"
case "$err" in
  *"refusing to route"*) fail "INV-16: a role-eligibility refusal must not be phrased as a routing refusal — the step table admitted this actor, and an operator sent to look for a missing step capability finds none" ;;
esac
green_case 'the same prepare with an actor covering the step but not the role was still refused at 14 by the role gate, naming the ROLE capability — so asking the step table first is an ordering of reports rather than a way past the role gate'

# ===========================================================================
# 5 -- THE DIRECTION THE RULE MAY NEVER RUN IN. A declaration is a claim, not
# a grant, so the capability arm may only ever turn the operator pause ON.
#
# Both halves matter. If a declared `shell` could clear a pause an operator
# configured, an actor would be voting itself past a human's gate -- and the
# shipped claude adapter, which declares `shell` and cannot run one command on
# its implement path, is exactly the profile that would do it.
# ===========================================================================
hrepo="$WORK/hrepo"; mkdir -p "$hrepo/.orchid/tasks"
printf 'role.implementer=withshell\nhandoff_before_verify=required\n' > "$hrepo/orchid.config"
assert_eq off "$(handoff_capability_gate "$hrepo" TH | cut -f1)" \
  "INV-16 sanity: the capability arm alone has no objection to an implementer declaring shell"
assert_eq required "$(handoff_gate_mode "$hrepo")" \
  "INV-16 sanity: the operator's own gate is on for this repository"
[ "$(handoff_state "$hrepo" TH | cut -f1)" != off ] \
  || fail "INV-16: an actor DECLARING shell must not clear a hand-off the operator asked for — a capability is a claim by the plugin, never a grant it can vote itself"
red_case 'an actor declaring shell was fed to a repository whose operator had set handoff_before_verify=required, and the pause held — the declaration bought nothing'

# ...and the arm does fire on its own, with no operator config at all. Note what
# this fixture is and is not evidence of: it plants the BINDING directly, which
# is the one path to this arm that no role gate has walked. A real dispatch
# cannot reach it -- roles/implementer.role requires shell, so an engine short
# of it is refused the role at exit 14 and never builds a candidate. Part 8
# below pins that relationship in both directions; the assertion here is that
# the arm decides correctly on the input, not that a running repository hands it
# this one.
printf 'role.implementer=noshell\n' > "$hrepo/orchid.config"
assert_eq off "$(handoff_gate_mode "$hrepo")" \
  "INV-16 sanity: nothing in this repository's config asks for the pause"
assert_eq required "$(handoff_capability_gate "$hrepo" TH | cut -f1)" \
  "INV-16: an implementer that declares no shell makes the mechanical step an operator hand-off with no config key set"
[ "$(handoff_state "$hrepo" TH | cut -f1)" != off ] \
  || fail "INV-16: the pause must be on when the actor that would perform the mechanical step cannot"

printf 'role.implementer=withshell\n' > "$hrepo/orchid.config"
assert_eq off "$(handoff_state "$hrepo" TH | cut -f1)" \
  "INV-16: with neither arm objecting the pause is off — otherwise the two assertions above say only that this gate always stops"
green_case 'with no config gate and an implementer declaring shell the pause stayed off, so the two required verdicts above are decisions rather than a gate that never opens'

# ===========================================================================
# 6 -- THE ACTOR NAMED BY A QUALIFIED ID. Both ways this gate can be wrong
# about one, and they are opposite failures.
#
# Third-party engines are the case. A publisher's manifest id is QUALIFIED
# (`acme/foo`), `implementer_engine_id` records the implement envelope's id
# verbatim apart from the `orchid/` vendor prefix libexec/orchid-task strips,
# and the name lookup searches the plugin roots by DIRECTORY name -- so the id
# a task records for a third-party actor is not the string that resolver
# searches by.
#
# ANSWERED "NO OBJECTION", that is not a gate at all: the pause is silently
# waived for exactly the plugins INV-14 promises the kernel treats like its own,
# and their candidates go to verification with the mechanical step unperformed.
#
# ANSWERED "CANNOT IDENTIFY", it is a trap with no door. That id is in the task
# record BECAUSE orchid minted, launched and reconciled a job for that plugin --
# it is not a stranger -- so refusing it holds every candidate that engine builds
# at an operator hand-off FOREVER: no act a human can perform makes an
# unresolvable name resolve. Same INV-14 violation, opposite side, and it costs
# every attempt instead of one.
#
# So the id is RESOLVED, through the same registry that installed the plugin and
# by either name it answers to. What the id is NOT is guessed at: the basename is
# never retried, because `acme/foo` and `zzz/foo` both fall to a directory called
# `foo` and answering out of another publisher's manifest is the shadowing INV-10
# refuses elsewhere. Refusal is kept for the actor that is genuinely not
# installed, and it names what it looked for.
# ===========================================================================
# THE SHIPPED LAYOUT, not an invented one. `orchid plugins install` puts a
# plugin at `$HOME/.orchid/plugins/<kind>s/<basename of its id>` (libexec/
# orchid-plugins' install arm), so a publisher's `acme/foo` is installed in a
# directory called `foo`. That IS the split this part is about: the id a task
# records and the name a binding uses are two different strings for one plugin,
# and both have to reach its manifest.
mk_engine foo "structured_text,workspace_read,workspace_write,git,shell"
# A QUALIFIED id, over mk_engine's own `test/<name>`. The capabilities are
# COMPLETE -- this engine can perform the mechanical step, and the gate has to
# be able to find that out.
printf 'manifest_version=1\nid=acme/foo\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,git,shell\nentrypoint=run\n' \
  > "$WORK/eng/foo/plugin.conf"

rc=0; why="$(capability_routing_refusal mechanical acme/foo)" || rc=$?
assert_eq 0 "$rc" \
  "INV-16: a qualified third-party id that IS installed must RESOLVE and proceed — refused, every candidate that engine builds waits forever on a hand-off no operator act can clear (said: $why)"
assert_eq "" "$why" "INV-16: and an admitted routing says nothing, exactly as it does for a first-party name"
green_case 'a qualified third-party id (acme/foo) whose plugin is installed under the directory orchid plugins install would give it resolved through the registry and was admitted the mechanical step, instead of being held at an unclearable hand-off'

# ...and resolving it is a LOOKUP, not a waiver. The same qualified form, for an
# installed publisher whose manifest is genuinely short, is still refused by the
# atom it never claimed.
mk_engine bar "structured_text,workspace_read,workspace_write,git"
printf 'manifest_version=1\nid=acme/bar\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,workspace_write,git\nentrypoint=run\n' \
  > "$WORK/eng/bar/plugin.conf"
rc=0; why="$(capability_routing_refusal mechanical acme/bar)" || rc=$?
assert_eq 1 "$rc" \
  "INV-16: an installed third-party actor that declares no shell is REFUSED by its qualified id too — resolving a name must not become a way past the gate"
assert_match "missing: shell" "$why" "INV-16: naming the atom, exactly as it does for a directory-named actor"
red_case 'the qualified id of an INSTALLED third-party engine declaring no shell was refused the mechanical step, naming shell — so resolving qualified ids reads the manifest rather than waiving the gate'

# RED: genuinely absent. No directory answers to it and no installed manifest
# claims it, so nothing was ever read and the gate says so — naming the id, which
# is the one thing an operator can act on.
rc=0; why="$(capability_routing_refusal mechanical zzz/ghost)" || rc=$?
assert_eq 2 "$rc" \
  "INV-16: an actor that is installed under NEITHER name is undetermined (2) — a gate must never report 'no objection' about a manifest it never read"
assert_match "zzz/ghost" "$why" "INV-16: and the refusal NAMES the id it could not find"
assert_match "is not installed" "$why" "INV-16: and says the plugin is absent rather than reporting a capability nothing read"
assert_match "no installed plugin manifest declares id=" "$why" \
  "INV-16: and says which forms it looked for, so 'install it' and 'bind the name it is installed under' are both visible as the fix"

# AND THE BASENAME IS NEVER RETRIED, which the install layout above makes a live
# hazard rather than a hypothetical: every plugin sits in a directory named after
# its id's basename, so `zzz/ghost` and `test/ghost` compete for the directory
# `ghost` and only one of them can be the plugin installed there. A directory
# called `ghost` published by somebody ELSE, declaring everything, is installed
# before the same lookup is repeated: `zzz/ghost` must STILL be undetermined. A
# resolver that fell back to the basename would answer out of that manifest — the
# shadowing INV-10 refuses elsewhere, arrived at by being helpful, and here it
# would silently clear a hand-off using a plugin that never built the candidate.
mk_engine ghost "structured_text,workspace_read,workspace_write,git,shell"
rc=0; why="$(capability_routing_refusal mechanical zzz/ghost)" || rc=$?
assert_eq 2 "$rc" \
  "INV-16: an unrelated plugin installed at the id's BASENAME settles nothing — a qualified id resolves because a manifest claims it, or it does not resolve"
red_case 'a qualified id no directory answers to and no manifest claims (zzz/ghost) was refused and named, and stayed refused when an unrelated plugin was installed at its basename'

# TWO PLUGINS CLAIMING ONE ID is refused rather than chosen between, which is
# the same INV-10 rule the duplicate-NAME refusal already enforces. Reported as
# undetermined, because picking one is precedence-by-shadow.
mk_engine dup-a "shell"
mk_engine dup-b "shell"
for _d in dup-a dup-b; do
  printf 'manifest_version=1\nid=dup/one\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell\nentrypoint=run\n' \
    > "$WORK/eng/$_d/plugin.conf"
done
rc=0; why="$(capability_routing_refusal mechanical dup/one 2>/dev/null)" || rc=$?
assert_eq 2 "$rc" \
  "INV-16: an id claimed by two installed plugins is undetermined — both declare shell, so a gate that picked one would be admitting on a manifest it chose by shadow (INV-10)"
assert_match "claimed by two installed plugins" "$why" \
  "INV-16: and says which of the two unresolvable cases this is, since 'install it' and 'uninstall one of them' are opposite actions"

# ---------------------------------------------------------------------------
# The same three verdicts through the hand-off arm, which is the caller that
# actually holds a candidate.
# ---------------------------------------------------------------------------
qrepo="$WORK/qrepo"; mkdir -p "$qrepo/.orchid/tasks"
printf 'role.implementer=zzz/ghost\n' > "$qrepo/orchid.config"
assert_eq off "$(handoff_gate_mode "$qrepo")" \
  "INV-16 sanity: nothing in this repository's config asks for the pause, so the capability arm is the only thing that can"

qline="$(handoff_capability_gate "$qrepo" TQ)"
assert_eq required "$(printf '%s' "$qline" | cut -f1)" \
  "INV-16: an actor installed under no name at all is REFUSED, never permitted — a mechanical step waived for an actor nothing could read is the fail-open this rule exists to close"
assert_match "zzz/ghost" "$(printf '%s' "$qline" | cut -f2-)" \
  "INV-16: and the operator is told WHICH plugin is missing (installable), not that a capability was absent (unactionable, and untrue)"
red_case 'an implementer id no installed plugin answers to made the mechanical hand-off REQUIRED and named the id — the arm did not report "no objection" about a manifest it never read'

# GREEN twin, and the case the rework turns on: the recorded id of a plugin that
# IS installed, addressed by the qualified form a real third-party envelope
# reports. The pause must be off, because the manifest was read and it declares
# shell.
printf -- '---\nschema: 1\nid: TQ2\nstatus: testing\nimplementer_engine_id: acme/foo\ncandidate_sha: 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n---\n\nfixture task record\n' \
  > "$qrepo/.orchid/tasks/TQ2.md"
printf 'role.implementer=noshell\n' > "$qrepo/orchid.config"
assert_eq off "$(handoff_capability_gate "$qrepo" TQ2 | cut -f1)" \
  "INV-16: a RECORDED qualified id whose plugin is installed and declares shell leaves the pause off — held instead, that candidate could never reach verification by any operator act"
green_case 'a task recording a third-party implementer by its qualified id (acme/foo) left the mechanical pause off once the id was resolved through the registry, so a third-party engine can finish a candidate'

# ...and the RECORDED implementer is still what is priced. A resolvable, fully
# capable binding sitting beside a recorded id that is short must not clear it:
# the gate asks about the actor that built THIS candidate.
printf -- '---\nschema: 1\nid: TQ3\nstatus: testing\nimplementer_engine_id: acme/bar\ncandidate_sha: 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n---\n\nfixture task record\n' \
  > "$qrepo/.orchid/tasks/TQ3.md"
printf 'role.implementer=withshell\n' > "$qrepo/orchid.config"
qline="$(handoff_capability_gate "$qrepo" TQ3)"
assert_eq required "$(printf '%s' "$qline" | cut -f1)" \
  "INV-16: the RECORDED implementer is what the gate prices, so a resolvable binding beside it clears nothing"
assert_match "missing: shell" "$(printf '%s' "$qline" | cut -f2-)" \
  "INV-16: and the refusal is the atom that actor never claimed, read from the manifest its qualified id resolved to"
assert_eq outstanding "$(handoff_state "$qrepo" TQ3 | cut -f1)" \
  "INV-16: and the candidate is held for an operator rather than sent to verification"

# The very same plugin, addressed by the directory it is installed under: still
# off. Both forms name one actor, and the gate must not answer differently
# depending on which one a record happens to carry.
printf 'role.implementer=foo\n' > "$qrepo/orchid.config"
assert_eq off "$(handoff_capability_gate "$qrepo" TQ | cut -f1)" \
  "INV-16: the identical manifest, addressed by the name it is installed under, resolves and declares shell — so the pause stays off"
green_case 'the same third-party manifest bound by its directory name left the pause off too, so the gate answers about the plugin rather than about which of its two names a record carries'

# ===========================================================================
# 6b -- THE OTHER HALF OF A HAND-OFF: the advice an operator is handed.
#
# A refusal ends at an `operator-handoff` boundary, and the only thing that
# tells the human how to STOP meeting it is the config key the reason names. So
# the key has to be one orchid reads.
#
# The hook step is where that broke. A hook job's `role` positional is the
# literal word `hook` -- handlers are bound by NAME from `hook.<point>` config
# and reach no role chain at all -- so pouring it into `role.<role>` produced
# `role.hook`, a key this kernel has never had and `orchid config` does not know.
# An operator following it edits a file orchid ignores while the boundary
# survives. The same string dropped the POINT, so which of the five bindings was
# refused went unsaid.
# ===========================================================================
hooktext="$(drive_capability_handoff_text hook hook before_merge)"
hookreason="$(printf '%s' "$hooktext" | cut -f1)"
assert_match "before_merge" "$hookreason" \
  "INV-16: a refused hook step NAMES the point — it is the only thing identifying which of the five bindings was refused, since the role positional is a placeholder"
assert_match "hook.before_merge" "$hookreason" \
  "INV-16: and points at hook.<point>, the key that actually binds a handler"
case "$hookreason" in
  *role.hook*) fail "INV-16: the hook arm must not name 'role.hook' — orchid has never read that key, so an operator following it edits a file the kernel ignores while the boundary survives" ;;
esac
assert_match "before_merge" "$(printf '%s' "$hooktext" | cut -f2-)" \
  "INV-16: and the journal line names the point too, so the durable record says which binding stopped"
# The key it names is one `orchid config` actually knows, asserted against the
# kernel's own key list rather than against this test's opinion of it.
grep -qxF "hook.before_merge" "$REPO_ROOT/lib/config-keys.txt" \
  || fail "INV-16: hook.before_merge must be a real config key — the hand-off advice sends an operator to it"
red_case 'the hand-off advice for a refused hook step named the point and the hook.before_merge key that binds a handler, instead of the role.hook key orchid has never read'

# GREEN twin: the ROLE arm still names role.<role>, which for every non-hook
# step is exactly the key that bound the actor that was refused.
roletext="$(drive_capability_handoff_text implementer implement)"
assert_match "role.implementer" "$(printf '%s' "$roletext" | cut -f1)" \
  "INV-16: a non-hook refusal still points at role.<role>, the key that bound the actor — the hook arm is a distinction, not a retreat from naming a key"
green_case 'the role arm of the same advice still named role.implementer, so naming the hook point is a correction to the one step whose role positional is a placeholder rather than a loss of the advice'

# AND THE DRIVER PASSES THE POINT, at both call sites that can launch a hook job
# (the hook walk, and the escalation ladder's relaunch). Text that can name the
# point is worth nothing if the caller never hands it over.
hookcalls="$(grep -c 'drive_capability_refusal "\$id" hook hook "\$point"' "$REPO_ROOT/runners/orchid-drive" || true)"
assert_eq 1 "$hookcalls" \
  "INV-16: the hook walk's refusal passes the point through to the advice"
grep -q 'drive_capability_refusal "\$id" "\$role" "\$op" "\$point"' "$REPO_ROOT/runners/orchid-drive" \
  || fail "INV-16: the escalation ladder's relaunch carries a hook point too, so its refusal must pass it as well — otherwise a relaunched hook job is refused with the point dropped"

# ===========================================================================
# 7 -- THROUGH THE DRIVER, on the one launch path that is not a dispatch: the
# ESCALATION LADDER's relaunch.
#
# The ladder counts JOB FAILURES against a task's `infra_failures` and blocks it
# at the cap. That counter measures broken infrastructure, and a capability
# refusal is not that: no later pass makes the same actor able to do the same
# work. A refusal swallowed on the relaunch is therefore the worst of the four
# call sites -- the rung for the job that DIED is already spent, nothing is
# journaled, no boundary is raised, and the walk meets the same task again next
# pass and spends the next rung. Three passes on, the task is `blocked` for a
# reason nothing recorded: the exact mis-attribution T008 removed.
#
# The fixture drives the real runner. Two tasks are refused on the SAME pass so
# the second one's refusal is HELD (equal boundary priority, first wins) and
# never reaches the boundary record -- which is what the once-per-record journal
# dedup has to survive: keyed on the recorded boundary it would miss every pass
# for exactly that task and append the same line forever.
# ===========================================================================
erepo="$WORK/erepo"
mkdir -p "$erepo"
cd "$erepo" || exit 1
git init -q .
# role.runner is the custom role from part 4 -- its descriptor asks for nothing,
# so the ROLE gate admits `noshell` and the step table is what refuses.
# The tasks are advanced to `implementing` below so the ordinary dispatch walk
# is inert: this part exercises the escalation ladder's relaunch, not a fresh
# pending-task dispatch. That distinction became load-bearing when T027 made
# pending/rework recovery belong to the dispatch walk (which owns worktree
# preparation) instead of relaunching it early from the ladder. infra_max sits
# well above the rungs this fixture spends so the ladder's auto-block cannot
# end it early.
printf 'role.implementer=noshell\nrole.runner=noshell\ninfra_max=9\nconcurrency=10\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$erepo" "$ORCHID_BIN" init >/dev/null \
  || fail "INV-16 fixture: orchid init (escalation-relaunch repo)"
git checkout -q orchid/integration
export ORCHID_REPO="$erepo"
EEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$EEPOCH"
cat > "$WORK/requirements-erepo.md" <<'EOF'
# Requirements
- REQ-1: a relaunch nobody in the loop can perform is handed over, not charged.
EOF
"$ORCHID_BIN" requirements import "$WORK/requirements-erepo.md" >/dev/null

"$ORCHID_BIN" task create EONE "its refusal wins the pass's boundary" >/dev/null
"$ORCHID_BIN" task create ETWO "its refusal is held behind EONE's" >/dev/null
"$ORCHID_BIN" task create ETHREE "the green twin: the same relaunch, admitted" >/dev/null
"$ORCHID_BIN" plan apply --reason "initial plan" >/dev/null
printf '%s\n' EONE ETWO ETHREE | while IFS= read -r _e; do
  "$ORCHID_BIN" task advance "$_e" implementing --reason "fixture: active job already dispatched" >/dev/null
done

# eplant <task> <hex-suffix> -- the manifest of a job that has already died,
# exactly the shape `orchid jobs prepare` mints (the job_id and log path are
# both validated by `jobs gc`, which is about to reap this). The pid is a real
# one that has certainly exited, because the driver's escalation sweep decides
# "died" with `kill -0` and nothing else.
eplant() {
  local task="$1" sfx="$2" pid jid
  pid="$(bash -c 'echo $$')"
  jid="j-e$EEPOCH-$task-a1-$sfx"
  mkdir -p "$erepo/.orchid/runtime/jobs" "$erepo/.orchid/runtime/logs"
  jq -n --arg jid "$jid" --arg task "$task" \
    --arg log "$erepo/.orchid/runtime/logs/$jid.log" \
    --arg out "$erepo/.orchid/runtime/spool/$jid.json" \
    --argjson pid "$pid" --argjson started "$(( $(date +%s) - 600 ))" \
    '{job_id:$jid, task:$task, attempt:1, role:"runner", operation:"orchestrate",
      engine:"noshell", pid:$pid, pgid:$pid, started_at:$started, log:$log,
      output:$out, base_sha:"", candidate_sha:"", hook_point:""}' \
    > "$erepo/.orchid/runtime/jobs/$jid.json"
}
EDRIVE_RC=0; EDRIVE_OUT=""
run_edrive() {
  EDRIVE_RC=0
  EDRIVE_OUT="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || EDRIVE_RC=$?
}
eboundary() { "$ORCHID_BIN" run boundary show 2>/dev/null || true; }
efield() { "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }
# How many times THIS task's own journal carries the routing refusal. The
# subject of the dedup is the journal, so the journal is what is counted.
erefusals() {
  "$ORCHID_BIN" journal show --task "$1" 2>/dev/null \
    | grep -c "was not routed to role 'runner'" || true
}

eplant EONE 00a1
eplant ETWO 00b2
run_edrive
assert_eq 16 "$EDRIVE_RC" \
  "INV-16: a pass that ends at a judgment boundary exits 16 — a swallowed refusal would have exited 0 with nothing recorded (out: $EDRIVE_OUT)"
assert_eq operator-handoff "$(eboundary | jq -r .kind)" \
  "INV-16: a relaunch the resolved actor cannot be given raises the operator hand-off boundary (out: $EDRIVE_OUT)"
assert_eq EONE "$(eboundary | jq -r .task)" \
  "INV-16: and names the task whose step was refused"
assert_eq 1 "$(erefusals EONE)" \
  "INV-16: with the refusal journaled, so the task's history says the step was REFUSED rather than merely never attempted"
assert_eq 1 "$(erefusals ETWO)" \
  "INV-16: including the refusal that lost the pass's boundary — the durable record is the journal's job, not the boundary's"
assert_eq 1 "$(efield EONE infra_failures)" \
  "INV-16: the ladder spent exactly the one rung the DEAD JOB earned; the refusal itself charges nothing, because no rung can clear it"
assert_eq 1 "$(efield ETWO infra_failures)" \
  "INV-16: same for the task whose refusal was held — being held changes what is recorded, never what is charged"
assert_eq implementing "$(efield EONE status)" \
  "INV-16: and the task stays in its pre-existing active status rather than advancing behind a step that was never routed"
red_case "a capability refusal on the escalation ladder's relaunch raised the named operator hand-off and journaled it, instead of being swallowed by the ladder and left to burn infra_failures to blocked"

# THE PASS THE DEDUP IS ABOUT. The same two refusals recur (a real run re-reaches
# them every pump cycle until an operator acts); EONE wins the boundary again, so
# ETWO's is held again and the boundary record has never once named it.
eplant EONE 00c3
eplant ETWO 00d4
run_edrive
assert_eq EONE "$(eboundary | jq -r .task)" \
  "INV-16 fixture: EONE wins this pass too, so ETWO's refusal was held again and the recorded boundary has still never named it (out: $EDRIVE_OUT)"
assert_eq 2 "$(efield ETWO infra_failures)" \
  "INV-16 fixture: the second pass really did re-reach ETWO's refusal — without this the unchanged journal below would prove only that nothing happened"
assert_eq 1 "$(erefusals ETWO)" \
  "INV-16: the once-per-record dedup keys on the JOURNAL, which is always written — keyed on the recorded boundary it would miss on every pass for a task whose refusal never wins one, and bury the run's history under one unchanging fact"
assert_eq 1 "$(erefusals EONE)" \
  "INV-16: and the winning task's line is not repeated either"

# GREEN twin, through the same runner: only the bound engine changes.
printf 'role.implementer=noshell\nrole.runner=withshell\ninfra_max=9\nconcurrency=10\n' > "$erepo/orchid.config"
eplant ETHREE 00e5
run_edrive
assert_eq 0 "$(erefusals ETHREE)" \
  "INV-16: the identical relaunch is not refused when the bound actor declares what orchestrate needs (out: $EDRIVE_OUT)"
assert_eq 1 "$(list_dir_files "$erepo/.orchid/runtime/jobs" | grep -c ETHREE || true)" \
  "INV-16: and it mints the job it always did — so the refusals above are capability decisions, not a ladder that had stopped relaunching"
ethree_boundary="$(eboundary | jq -r '(.kind // "") + " " + (.task // "")' 2>/dev/null || true)"
[ "$ethree_boundary" != "operator-handoff ETHREE" ] \
  || fail "INV-16: an admitted relaunch must raise no hand-off boundary at all (it recorded: $ethree_boundary)"
green_case 'the same escalation relaunch, with only the bound engine changed to one declaring shell and git, was admitted and minted its job — no refusal, no hand-off boundary, and the ladder still relaunches'

# ===========================================================================
# 8 -- WORDS THAT MATCH BEHAVIOUR. Two claims a hand-off makes to the human
# reading it, and both were wrong in ways only a human would ever notice.
#
# 8a. THE KEY A REFUSED REVIEWER SLOT NAMES. A refusal's whole second half is
# the advice: perform the step, or bind an actor that covers it AT THIS KEY.
# For a step bound straight off a role chain, `role.<role>` is that key. A
# REVIEWER SLOT is not bound that way. review_routing walks resolve_role_chain
# (reviewer) and then the `review.<tier>` chain, and falls back to the engine
# that built the candidate when neither yields an eligible, available one -- so
# `role.reviewer` describes one of three origins and misdescribes the other
# two. An operator told to edit a key the refused engine never came through
# edits it, watches the boundary survive unchanged, and concludes orchid is
# broken.
#
# The fallback is the origin most likely to be refused here, which is why the
# wrong advice lands where it hurts most: _review_candidate_ok already requires
# reviewer-role eligibility (hence `structured_text`) of every CHAIN entry,
# while the fallback arm skips that check entirely and hands the slot an engine
# gated only on `workspace_write,shell,git`.
# ===========================================================================
rrepo="$WORK/rrepo"; mkdir -p "$rrepo/.orchid/tasks"
printf -- '---\nschema: 1\nid: TR\nstatus: reviewing\nrisk_tier: high\n---\n\nfixture task record\n' \
  > "$rrepo/.orchid/tasks/TR.md"
printf 'role.reviewer=revrole\nreview.high=revtier,revrole\n' > "$rrepo/orchid.config"

assert_eq role.reviewer "$(review_slot_engine_source "$rrepo" TR 1 revrole)" \
  "INV-16: slot 1 walks the reviewer chain first, so an engine that chain names is attributed to role.reviewer"
assert_eq review.high "$(review_slot_engine_source "$rrepo" TR 1 revtier)" \
  "INV-16: an engine only the tier chain names is attributed to review.<tier> — advising role.reviewer would name a key it never came through"
assert_eq review.high "$(review_slot_engine_source "$rrepo" TR 2 revrole)" \
  "INV-16: slot 2 is drawn purely from review.<tier>, so an engine in BOTH chains is attributed to the chain slot 2 actually walks"

# The tier is read from the TASK, not assumed: review.high and review.low are
# different bindings, and advice naming the wrong one is advice about somebody
# else's chain.
printf -- '---\nschema: 1\nid: TRL\nstatus: reviewing\nrisk_tier: low\n---\n\nfixture task record\n' \
  > "$rrepo/.orchid/tasks/TRL.md"
printf 'role.reviewer=revrole\nreview.high=revtier,revrole\nreview.low=revlow\n' > "$rrepo/orchid.config"
assert_eq review.low "$(review_slot_engine_source "$rrepo" TRL 1 revlow)" \
  "INV-16: the tier key comes from this task's own risk_tier, the same way review_routing derives it"

printf 'role.reviewer=revrole\nreview.high=revtier,revrole\n' > "$rrepo/orchid.config"
src_rc=0
rsrc="$(review_slot_engine_source "$rrepo" TR 1 buildereng)" || src_rc=$?
assert_eq 1 "$src_rc" \
  "INV-16: an engine neither chain names is reported as such — the status is how a caller tells a bare key from the fallback"
case "$rsrc" in
  role.reviewer) fail "INV-16: the session-independent fallback must NOT be advertised as role.reviewer — that key did not select this engine, and an operator who edits it watches the boundary survive" ;;
esac
assert_match "role.reviewer" "$rsrc" \
  "INV-16: the fallback still names both keys, because adding an eligible engine to either is what ends it"
assert_match "review.high" "$rsrc" \
  "INV-16: including the tier chain, which is the other place an eligible reviewer can be bound"
assert_match "fell back" "$rsrc" \
  "INV-16: and says the slot fell back, so an operator knows why no reviewer binding names the engine they were shown"
red_case 'a refused reviewer slot named the key its engine actually resolved from — review.<tier>, or the fallback in words — instead of advising role.reviewer for an engine that key never selected'

# The advice string is what carries it, and the driver is what hands it over.
rtext="$(drive_capability_handoff_text reviewer review "" review.high)"
rreason="$(printf '%s' "$rtext" | cut -f1)"
assert_match "review.high" "$rreason" \
  "INV-16: the boundary reason names the key it was given"
case "$rreason" in
  *role.reviewer*) fail "INV-16: and does not also name role.reviewer, the key that did not bind this slot's engine" ;;
esac
grep -q 'drive_capability_refusal "\$id" reviewer review "" "\$src"' "$REPO_ROOT/runners/orchid-drive" \
  || fail "INV-16: the reviewing walk must pass the resolved source through — advice that CAN name the right key is worth nothing if the caller never hands it over"

# GREEN twin: with no source given the default is still role.<role>, so this is
# a correction to the one caller whose binding is not a role chain rather than a
# retreat from naming a key at all.
assert_match "role.arbiter" "$(drive_capability_handoff_text arbiter arbitrate | cut -f1)" \
  "INV-16: a caller that names no key still gets role.<role>, the key that binds an actor resolved straight off a role chain"
green_case 'a refusal with no explicit binding still advised role.<role>, so naming the reviewer slot key is a correction to the one caller bound another way rather than a loss of the advice'

# ===========================================================================
# 8b. THE PAUSE THE DOCS MAY NOT ADVERTISE. lib/handoff.sh's capability arm has
# two outcomes, and only one of them can happen to a running repository.
#
# `roles/implementer.role` declares `requires=workspace_write,shell,git`, and
# the role gate enforces it before anything is dispatched -- so an engine
# declaring no `shell` is refused the implementer role (exit 14) before any
# candidate of its exists for the hand-off to hold. Documenting "the pause is
# also asked for when your implementer declares no shell" therefore promises a
# protection that CANNOT FIRE, in a capability feature, where an operator
# reading it concludes they need not set `handoff_before_verify` -- the exact
# key that covers the case no manifest shows, a profile that DECLARES `shell`
# and is still not granted it.
#
# BOTH DIRECTIONS ARE PINNED, because either half moving alone is a defect. If
# the role stops requiring `shell` the arm becomes reachable and the docs have
# to say so again; if the docs go back to advertising it, the role gate makes
# them false. Prose is FOLDED before matching -- a pinned sentence straddles a
# hard wrap, and an unfolded grep for one never matches whatever the file says.
# ===========================================================================
grep -Eq '^requires=(.*,)?shell(,.*)?$' "$REPO_ROOT/roles/implementer.role" \
  || fail "INV-16: roles/implementer.role must require shell — it is what makes the capability arm's shell outcome unreachable for a dispatched implementer, so if this is being removed deliberately, the docs pinned below have to describe a pause that CAN now fire"

fold_doc() { tr '\n' ' ' < "$1" | tr -s ' '; }
case "$(fold_doc "$REPO_ROOT/docs/configuration.md")" in
  *"refused the implementer role (exit 14) before it can build a candidate at all"*) ;;
  *) fail "INV-16: docs/configuration.md must say the shell half of the capability arm cannot fire for a dispatched implementer — an operator who reads it as automatic protection skips handoff_before_verify, the only key covering a profile that declares shell without being granted it" ;;
esac
case "$(fold_doc "$REPO_ROOT/PROTOCOL.md")" in
  *"cannot arise for a candidate this kernel dispatched"*) ;;
  *) fail "INV-16: PROTOCOL.md must say the same in the bullet that introduces the second arm — the boundary an operator meets is described there" ;;
esac
case "$(fold_doc "$REPO_ROOT/docs/configuration.md")" in
  *"You do not have to set it for the case it was written for"*)
    fail "INV-16: docs/configuration.md must not tell an operator this config key is unnecessary — the arm that would make it so is gated out by roles/implementer.role, so the key is still the only cover for a profile that declares shell without being granted it" ;;
esac
red_case 'the docs stopped advertising an automatic hand-off pause that roles/implementer.role makes unreachable, and the role requirement they now rest on is pinned beside them so neither half can move alone'

# ===========================================================================
# 9 -- EVERY OPERATION THE KERNEL NAMES IS PRICED, and the one that was not.
#
# The closed step set is only safe while it is closed over the operations that
# can actually reach `orchid jobs prepare`. docs/specs/plugins.md's request
# union is `implement | review | critique | research | hook | orchestrate`, and
# `research` was absent from `_CAPABILITY_STEPS` -- so a well-formed call on a
# documented operation met the CALLER-ERROR arm (exit 3, "no step named
# research exists") instead of being priced. That is not a harmless gap in a
# gate that only ever refuses:
#
#   * it reports a documented operation as a malformed request, and sends an
#     operator looking for a typo that is not there;
#   * the arm reaches the caller as `orchid_die`'s exit 1, NOT as this
#     feature's 19 -- so runners/orchid-drive reads it as an ordinary launch
#     failure and spends a rung of the task's infra_failures ladder on
#     infrastructure that is not broken. That is the exact mis-attribution
#     INV-16 exists to end, arriving through the gate built to end it.
#
# TWO-WAY, because either half moving alone is a defect. If the spec drops
# `research` from the union this row should go with it; if the row is dropped
# while the spec still names it, the gate silently starts refusing a documented
# operation as unknown again. Prose is FOLDED before matching, as in 8b.
# ===========================================================================
capability_step_valid research \
  || fail "INV-16: research must be a kernel-owned step — docs/specs/plugins.md names it in the request union, so an unpriced research reaches the caller-error arm and is charged to the infra ladder as a malformed request"
case "$(fold_doc "$REPO_ROOT/docs/specs/plugins.md")" in
  *"implement | review | critique | research | hook | orchestrate"*) ;;
  *) fail "INV-16: docs/specs/plugins.md must still name research in the request union — if it was removed deliberately, drop the research row from _CAPABILITY_STEPS in the same change, because the two together are what keep prepare from refusing a documented operation as unknown" ;;
esac

# RED: an actor declaring the structured half and NOT the citations half. As in
# 2, it declares everything around the one atom that matters, so the refusal
# cannot be a sparse manifest being rejected by anything.
mk_engine nociter "structured_text,workspace_read,workspace_write,shell,git"
rc=0; why="$(capability_routing_refusal research nociter)" || rc=$?
assert_eq 1 "$rc" \
  "INV-16: a research step must be REFUSED (exit 1) against an actor that declares no citations — and exit 1 is the point: 3 would blame the caller for a step the kernel does name"
assert_match "missing: citations" "$why" \
  "INV-16: naming the exact atom, so this is a capability decision rather than the step name being unrecognised"
case "$why" in
  *"no step named"*) fail "INV-16: research must not be answered as an unknown step — that is the caller-error arm, and it exits 1 through orchid_die rather than 19, so the driver charges the infra ladder for it" ;;
esac
red_case 'a research step routed to an actor declaring every atom but citations was refused as a capability shortfall naming citations, instead of being answered as a step the kernel has never heard of'

# GREEN twin: the same step, the same call, the one atom added.
mk_engine withciter "structured_text,workspace_read,workspace_write,shell,git,citations"
rc=0; why="$(capability_routing_refusal research withciter)" || rc=$?
assert_eq 0 "$rc" \
  "INV-16: the same research step must be routable to an actor that DOES declare citations — otherwise the refusal above is not about capabilities at all"
assert_eq "" "$why" "INV-16: an admitted routing says nothing (it is not a grant, so it makes no claim)"
green_case 'the same research step routed to the same actor plus a citations declaration was admitted silently, so the refusal above is a capability decision and research is genuinely priced rather than merely accepted'

# ===========================================================================
# 10 -- THE REVIEWER SLOT'S ADVICE HAS TO REACH A PINNED ROW. Part 8a fixed
# WHICH KEY a refused reviewer slot names. Naming the right key is still a dead
# end on its own, because a reviewer slot is not routed live: once an attempt
# has a candidate the table is written down (`review_plan_pin_rows`) and every
# later reader gets THAT table back for the life of the attempt. So an operator
# who does exactly what the advice says -- bind a capable engine at the key
# this slot's engine resolved from -- moves LIVE routing and watches the
# boundary survive, because the walk dispatches the PINNED row. That is the
# same "edit a key, nothing happens, conclude orchid is broken" failure 8a
# exists to prevent, reached one step later.
#
# The supported way to move a pinned row is `orchid jobs review-plan <task>
# --repin`, which is already the remedy the neighbouring exit-14 refusal on the
# same slot prints. So the advice is asserted in two halves, and the second is
# the one that matters: the words, and then the verb actually run against a
# real repository to prove it clears the slot.
# ===========================================================================
ptext="$(drive_capability_handoff_text reviewer review "" review.low TR1)"
preason="$(printf '%s' "$ptext" | cut -f1)"
assert_match "review-plan TR1 --repin" "$preason" \
  "INV-16: a refused reviewer slot's advice must name the verb that moves a PINNED row, with this task's own id — the config key it also names cannot reach the row on its own"
assert_match "review.low" "$preason" \
  "INV-16: and still names the key the slot's engine resolved from, because the repin recomputes from live routing and there is nothing new to bind to until that key changes"
assert_match "PINNED" "$preason" \
  "INV-16: and says WHY the key alone is not enough, so an operator who stops after the config edit knows the boundary surviving is expected rather than a bug"
# The slot most likely to be refused here is the FALLBACK one (8a), whose
# "binding" review_slot_engine_source hands over is a whole phrase rather than
# a key. The repin step has to survive being appended to that too, or the one
# advice that matters most is the one that loses it.
pfall="$(drive_capability_handoff_text reviewer review "" \
  "$(review_slot_engine_source "$rrepo" TR 1 buildereng || true)" TR1 | cut -f1)"
assert_match "review-plan TR1 --repin" "$pfall" \
  "INV-16: the repin step is named even where the binding is the fallback PHRASE — that is the slot the fallback arm makes most likely to be refused, so losing it there loses it where it counts"
assert_match "fell back" "$pfall" \
  "INV-16: without displacing the phrase itself, which is the only thing that explains why no reviewer binding names the engine the operator was shown"
# The caller hands the id over. Advice that CAN name the task is worth nothing
# if the one function that writes it never passes one, and a command printed
# with a blank argument is worse advice than none.
grep -q 'drive_capability_handoff_text "\$role" "\$op" "\$point" "\$binding" "\$id"' "$REPO_ROOT/runners/orchid-drive" \
  || fail "INV-16: drive_capability_refusal must pass the task id through to the advice, or the reviewer arm prints a review-plan command with no task in it"
red_case 'a refused reviewer slot advised the recorded verb that moves a pinned row (orchid jobs review-plan <task> --repin) alongside the config key, instead of naming only a key that a pinned plan ignores'

# GREEN twin: the arms that have no pinned plan must NOT name a review-plan
# verb. `--repin` moves reviewer slots and nothing else, so advertising it for
# an implementer or a hook handler would send an operator to run a command that
# cannot touch what refused them.
for _plain in implementer:implement arbiter:arbitrate; do
  _prole="${_plain%%:*}"; _pop="${_plain##*:}"
  case "$(drive_capability_handoff_text "$_prole" "$_pop" | cut -f1)" in
    *review-plan*) fail "INV-16: role '$_prole' has no pinned plan, so its advice must not name a review-plan verb that cannot move anything it was refused over" ;;
  esac
done
case "$(drive_capability_handoff_text hook hook before_merge | cut -f1)" in
  *review-plan*) fail "INV-16: a hook handler has no reviewer slot either — its advice names hook.<point>, and adding a review-plan verb to it would be a command that cannot reach the binding" ;;
esac
green_case 'the same advice for an implementer, an arbiter and a hook handler named no review-plan verb, so the repin step is a correction to the one caller whose row is pinned rather than a command pasted onto every refusal'

# ---------------------------------------------------------------------------
# AND THE VERB CLEARS THE SLOT. Words that name a remedy prove nothing until
# the remedy is run: this drives the real `orchid jobs review-plan` against a
# repository whose pinned slot 1 holds an engine `review` refuses.
#
# The slot gets there the way a running repository does. `review_routing`'s
# session-independent fallback hands slot 1 the engine that BUILT the candidate
# when no chain entry is eligible and available -- and that arm skips the
# reviewer eligibility check every chain entry passes, so the pinned engine can
# be an implementer that declares no `structured_text`. That is the slot most
# likely to be refused here, and it is the one the pin then freezes.
# ---------------------------------------------------------------------------
mk_engine revshort "workspace_read,workspace_write,shell,git"
mk_engine revfull "structured_text,workspace_read,workspace_write,shell,git"
prepo="$WORK/prepo"; mkdir -p "$prepo/.orchid/tasks" "$prepo/.orchid/reviews"
cd "$prepo" || exit 1
git init -q .
git commit -q --allow-empty -m root
export ORCHID_REPO="$prepo"
PEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$PEPOCH"
phead="$(git -C "$prepo" rev-parse HEAD)"
# Both reviewer chains name only the engine that built the candidate, so
# neither yields an entry DIFFERENT from the implementer and slot 1 falls back.
printf 'role.implementer=revshort\nrole.reviewer=revshort\nreview.low=revshort\n' > "$prepo/orchid.config"
"$ORCHID_BIN" task create TRP "a pinned slot holding an engine review refuses" >/dev/null
"$ORCHID_BIN" task set TRP risk_tier low --reason "one reviewer slot" >/dev/null
"$ORCHID_BIN" task set TRP candidate_sha "$phead" >/dev/null

pinned="$("$ORCHID_BIN" jobs review-plan TRP --pin)"
assert_eq "$(printf '1\trevshort\tsession-independent')" "$pinned" \
  "INV-16 fixture: slot 1 must fall back to the engine that built the candidate — that is the arm that skips the reviewer eligibility check, and without it nothing below is the refused case"
prc=0; capability_routing_refusal review revshort >/dev/null || prc=$?
assert_eq 1 "$prc" \
  "INV-16 fixture: and that pinned engine must be one the review step REFUSES, or the repin below clears a slot that was never stuck"

# The operator does exactly what the key half of the advice says, and ONLY that.
printf 'role.implementer=revshort\nrole.reviewer=revshort\nreview.low=revfull\n' > "$prepo/orchid.config"
assert_eq "$(printf '1\trevfull\tengine-independent')" "$(review_routing "$prepo" TRP)" \
  "INV-16 fixture: binding a capable engine at the named key really does move LIVE routing, so what follows is the pin outliving the edit rather than the edit failing"
assert_eq "$pinned" "$("$ORCHID_BIN" jobs review-plan TRP)" \
  "INV-16: the config edit ALONE leaves the pinned row exactly as it was — this is the dead end, and advice that stopped at the key would end here with the boundary surviving unexplained"

# ...and then the verb the advice names.
repinned="$("$ORCHID_BIN" jobs review-plan TRP --repin)"
assert_eq "$(printf '1\trevfull\tengine-independent')" "$repinned" \
  "INV-16: 'orchid jobs review-plan <task> --repin' rebinds the unfilled slot to the engine the operator bound — the advice names a step that actually reaches the pinned row"
assert_eq "$repinned" "$("$ORCHID_BIN" jobs review-plan TRP)" \
  "INV-16: and the change is DURABLE — the next reader of the plan gets the rebound row, so the walk dispatches it"
prc=0; capability_routing_refusal review revfull >/dev/null || prc=$?
assert_eq 0 "$prc" \
  "INV-16: the slot is CLEARED: the step that refused this slot is routable to the engine now pinned to it, so following the advice ends the hand-off rather than merely rewriting a table"
assert_match "review plan pinned for attempt 1 \(repin\)" \
  "$("$ORCHID_BIN" journal show --task TRP 2>/dev/null || true)" \
  "INV-16: and it is a RECORDED verb, journaled with the table it landed — the remedy for a routing refusal must not be an operator editing durable state by hand"
green_case 'running the advised orchid jobs review-plan --repin against a pinned slot whose engine review refuses rebound it to the capable engine the operator had bound, journaled the new table, and left the step routable — while the config edit alone had left the pinned row untouched'

# ===========================================================================
# 11 -- THE ARM WITH NO ACTOR TO ASK ABOUT: the NORMAL ROLE CHAIN.
#
# Parts 4c and 7 cover the dispatch where the CALLER named the engine. Every
# other dispatch names none: `orchid jobs prepare <task> <role> <op>` hands the
# role to resolve_role_available, which walks the chain and prints the first
# entry that is discovered, role-eligible, ledger-available and (past the
# primary) capsuite-passed. Until that walk succeeds there is no manifest for
# the step table to be asked about, so the gate parts 4 and 4b exercise sits
# BEHIND a resolution that has already failed.
#
# AND WHEN IT FAILS IT EXITS 14, WHICH IS A WAIT. That reading is right for the
# reasons the walk usually fails: a ledger window that reopens by itself, a
# fallback one `orchid plugins test` away, a plugin not installed yet. It is
# exactly wrong when every entry in the chain is short an atom the STEP's work
# needs. Nothing reopens, so runners/orchid-drive waits, journals nothing,
# raises no boundary, and the walk meets the same task again every pass
# forever — the silent dead end this whole invariant exists to end, arriving
# one gate EARLIER than the gate built to end it.
#
# THE OVERLAP IS NOT A CORNER CASE, which is why this arm had to be closed
# rather than argued away. A built-in role's `requires=` and its step's price
# are drawn from the same facts about the same work: roles/reviewer.role wants
# `structured_text` and the `review` step prices exactly that, and
# roles/implementer.role wants `workspace_write,shell,git` — the implement
# row, atom for atom. So for the two roles the driver actually dispatches,
# EVERY capability shortfall in the shipped tree is refused by the role gate
# first and reaches the caller as this 14, never as the post-resolution 19.
# ===========================================================================
nrepo="$WORK/nrepo"; mkdir -p "$nrepo/.orchid/tasks" "$nrepo/.orchid/reviews"
cd "$nrepo" || exit 1
git init -q .
git commit -q --allow-empty -m root
export ORCHID_REPO="$nrepo"
NEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$NEPOCH"
"$ORCHID_BIN" task create TN "a chain with nobody in it who can do the work" >/dev/null

# `builderonly` (part 4c) declares workspace_read, workspace_write, shell and
# git — everything except the one atom `review` prices.
printf 'verify=true\nrole.reviewer=builderonly\n' > "$nrepo/orchid.config"

# THE PREMISE, asserted rather than assumed: resolution really does come up
# empty, and it comes up empty at 14. Without this the exit 19 below could be
# the post-resolution gate firing on an actor that resolved fine, which is
# parts 4 and 4b and proves nothing about this arm.
nrc=0; nerr="$(resolve_role_available "$nrepo" reviewer 2>&1 1>/dev/null)" || nrc=$?
assert_eq 14 "$nrc" \
  "INV-16 fixture: the chain must yield NO actor at all — this part is about the refusal that has to arrive before one exists"
assert_match "no eligible engine available for role reviewer" "$nerr" \
  "INV-16 fixture: and it must be the generic chain-walk failure, the exit 14 runners/orchid-drive reads as a ledger wait"

jobs_before="$(list_dir_files "$nrepo/.orchid/runtime/jobs" | wc -l | tr -d ' ')"
rc=0; err="$("$ORCHID_BIN" jobs prepare TN reviewer review 2>&1 1>/dev/null)" || rc=$?
assert_eq 19 "$rc" \
  "INV-16: a chain EVERY entry of which is short an atom the step needs is a permanent refusal (19), not the wait (14) the driver journals nothing for"
assert_match "refusing to route" "$err" "INV-16: the refusal names itself as a routing decision"
assert_match "missing: structured_text" "$err" \
  "INV-16: and names the atom, so an operator is not sent to watch a ledger window over a fact no window reopens"
assert_eq "$jobs_before" "$(list_dir_files "$nrepo/.orchid/runtime/jobs" | wc -l | tr -d ' ')" \
  "INV-16: and mints NO job manifest, exactly as the named-actor arm does"
red_case 'a role chain whose only entry declares no structured_text was refused a review step at orchid jobs prepare with the permanent answer (19, naming the atom) instead of the exit 14 the driver reads as a ledger wait, with no job minted'

# GREEN TWIN 1 — EVERY ENTRY, NEVER ANY. `textonly` declares exactly what
# `review` prices, so one entry in this chain is one the step table has no
# objection to and a later pass can route the step there. Resolution still
# fails, because a fallback is used only once `orchid plugins test` has proved
# it for this role — and that is a wait an operator clears by running one
# command, not a capability fact. Refusing here would hand them a hand-off
# about a manifest that is perfectly adequate.
printf 'verify=true\nrole.reviewer=builderonly,textonly\n' > "$nrepo/orchid.config"
if capsuite_passed textonly reviewer; then
  fail "INV-16 fixture: textonly must have NO capsuite record for reviewer, or the chain below resolves and this twin tests nothing"
fi
nrc=0; resolve_role_available "$nrepo" reviewer >/dev/null 2>&1 || nrc=$?
assert_eq 14 "$nrc" \
  "INV-16 fixture: the chain must STILL yield no actor, or the 14 below is a successful dispatch rather than a preserved wait"
rc=0; err="$("$ORCHID_BIN" jobs prepare TN reviewer review 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" \
  "INV-16: one entry the step table does not refuse leaves the chain a WAIT — this gate re-reports a refusal only when it holds for the whole chain"
case "$err" in
  *"refusing to route"*) fail "INV-16: an unproven fallback is not a capability shortfall, and phrasing it as a routing refusal sends an operator to audit a manifest that covers the step" ;;
esac
green_case 'the same chain with one capable entry appended stayed the exit-14 wait it always was, so the refusal above is about the whole chain being short rather than about resolution having failed'

# GREEN TWIN 2 — AN ENTRY THIS GATE CANNOT ANSWER FOR IS NOT A REFUSAL, and it
# is the DELIBERATE opposite of what part 6 requires of the single-actor gate.
# There, an unresolvable actor (2) must never be read as permission, because a
# routing was about to happen and a gate that shrugged would waive itself.
# Here nothing is about to happen — resolution has already refused — and the
# only question is whether to RE-REPORT that as permanent. An uninstalled
# plugin is an install, and reported as a capability hand-off it sends an
# operator to read a manifest that is not on the disk.
printf 'verify=true\nrole.reviewer=zzz/ghost\n' > "$nrepo/orchid.config"
nrc=0; capability_routing_refusal review zzz/ghost >/dev/null 2>&1 || nrc=$?
assert_eq 2 "$nrc" \
  "INV-16 fixture: the single-actor gate must call this entry UNDETERMINED, or the two answers below are not the contrast this twin is about"
rc=0; err="$("$ORCHID_BIN" jobs prepare TN reviewer review 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" \
  "INV-16: a chain entry no manifest can be read for stays the wait it was — the chain gate re-reports only the one fact no later pass changes"
case "$err" in
  *"refusing to route"*) fail "INV-16: an uninstalled plugin must not be reported as a capability the plugin lacks — the remedy is an install, and no hand-off about a capability names it" ;;
esac
green_case 'a chain naming only an uninstalled qualified id stayed at exit 14, so the chain gate re-reports a missing atom and not every reason a chain comes up empty'

# AND THE CALLER-ERROR ARM IS STILL THE CALLER'S, on this arm too. Reported as
# 19 a mistyped operation becomes a journaled hand-off about a plugin behaving
# perfectly, with the typo — the one thing an operator could fix — nowhere in
# the message.
printf 'verify=true\nrole.reviewer=builderonly\n' > "$nrepo/orchid.config"
rc=0; err="$("$ORCHID_BIN" jobs prepare TN reviewer revieww 2>&1 1>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "INV-16: an unknown operation must not mint a job on the chain arm either"
[ "$rc" -ne 19 ] \
  || fail "INV-16: an unknown operation must NOT be reported as a capability refusal — the fault is the request's, and the chain gate must blame it exactly as the named-actor gate does"
assert_match "unknown operation" "$err" \
  "INV-16: the chain gate says the operation is unknown, in the same words the named-actor gate uses"
case "$err" in
  *"refusing to route"*) fail "INV-16: a mistyped operation must not be phrased as a routing refusal about a chain that was never asked for a capability" ;;
esac

# GREEN TWIN 3 — the verb still works on this arm. Only the binding changes.
printf 'verify=true\nrole.reviewer=textonly\n' > "$nrepo/orchid.config"
rc=0; nmf="$("$ORCHID_BIN" jobs prepare TN reviewer review)" || rc=$?
assert_eq 0 "$rc" "INV-16: the identical call must resolve and mint when the chain names an actor that declares what review needs"
[ -f "$nmf" ] || fail "INV-16: an admitted chain routing mints the job manifest it always did"
green_case 'the identical prepare, with only the chain rebound to an actor declaring structured_text, resolved and minted its job — so the exit 19 above is a capability decision and not a verb that had stopped working'

# ===========================================================================
# 11b -- AND THROUGH THE REAL DRIVER, on the ORDINARY DISPATCH WALK. Part 7
# proved the hand-off end to end on the escalation ladder's relaunch, which is
# the path that reaches `--engine`-shaped launches. This is the other one, and
# it is the one every pending task takes: drive_role_for_status hands
# `implementing` to the implementer role, drive_launch runs the launcher with
# NO --engine at all, and the chain is what picks the actor.
#
# Reported as the wait it used to be, this pass printed "no eligible engine —
# waiting for the ledger window to reopen", took no transition, recorded
# nothing, and did the identical thing on every pass after it. What has to
# come out instead is the pair that makes a hand-off actionable: the JOURNAL
# line, which is the durable record that the step was refused rather than
# merely never attempted, and the `operator-handoff` BOUNDARY, which names no
# settling verb so a human is notified and no model is woken to make a
# decision it has no verb to make.
# ===========================================================================
ndrepo="$WORK/nchain"
mkdir -p "$ndrepo"
cd "$ndrepo" || exit 1
git init -q .
# `textonly` declares structured_text and nothing else, so it is short every
# atom the implement row prices. roles/implementer.role refuses it first, which
# is the whole point: that refusal is a 14, and a 14 is a wait.
printf 'role.implementer=textonly\nrole.reviewer=textonly\ninfra_max=9\nconcurrency=10\n' > orchid.config
git add -A
git commit -q -m "fixture: config"
ORCHID_REPO="$ndrepo" "$ORCHID_BIN" init >/dev/null \
  || fail "INV-16 fixture: orchid init (chain-dispatch repo)"
git checkout -q orchid/integration
export ORCHID_REPO="$ndrepo"
NDEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$NDEPOCH"
cat > "$WORK/requirements-nchain.md" <<'EOF'
# Requirements
- REQ-1: a chain nobody in it can do the work is handed over, not waited on.
EOF
"$ORCHID_BIN" requirements import "$WORK/requirements-nchain.md" >/dev/null
"$ORCHID_BIN" task create NCH1 "its dispatch resolves to nobody who can implement" >/dev/null
"$ORCHID_BIN" task set NCH1 verification_commands "true" >/dev/null
"$ORCHID_BIN" plan apply --reason "initial plan" >/dev/null

NDRIVE_RC=0; NDRIVE_OUT=""
run_ndrive() {
  NDRIVE_RC=0
  NDRIVE_OUT="$("$REPO_ROOT/runners/orchid-drive" 2>&1)" || NDRIVE_RC=$?
}
ndboundary() { "$ORCHID_BIN" run boundary show 2>/dev/null || true; }
ndstatus() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }
ndrefusals() {
  "$ORCHID_BIN" journal show --task "$1" 2>/dev/null \
    | grep -c "was not routed to role 'implementer'" || true
}

run_ndrive
assert_eq 16 "$NDRIVE_RC" \
  "INV-16: a pass that ends at a judgment boundary exits 16 — reported as the wait it used to be it would have exited 0 with nothing recorded (out: $NDRIVE_OUT)"
assert_eq operator-handoff "$(ndboundary | jq -r .kind)" \
  "INV-16: a dispatch whose whole role chain is short what the step needs raises the operator hand-off boundary (out: $NDRIVE_OUT)"
assert_eq NCH1 "$(ndboundary | jq -r .task)" \
  "INV-16: and names the task whose step was refused"
assert_eq 1 "$(ndrefusals NCH1)" \
  "INV-16: with the refusal JOURNALED, so the task's history says the step was refused rather than showing a status that simply stopped moving"
assert_match "role.implementer" "$(ndboundary | jq -r .reason)" \
  "INV-16: and the advice names the key that binds this chain, which is the one thing an operator can act on"
assert_eq pending "$(ndstatus NCH1)" \
  "INV-16: the task stays in its prior status — nothing was spawned, so no envelope is awaited and no attempt is spent"
[ -z "$(list_dir_files "$ndrepo/.orchid/runtime/jobs")" ] \
  || fail "INV-16: a refused dispatch must leave no job manifest behind"
case "$NDRIVE_OUT" in
  *"waiting for the ledger window to reopen"*)
    fail "INV-16: a chain that is short a capability must not be reported as a ledger wait — no window reopens, and the pass that says so comes back and says it again forever" ;;
esac
red_case 'the real driver, dispatching a pending task through an ordinary role chain whose only entry declares none of what implement needs, journaled the refusal and raised the named operator-handoff boundary instead of printing a ledger wait and coming back next pass'

# GREEN twin, through the same runner and against the same task: only the
# binding changes. `withshell` declares workspace_write, shell and git, so the
# chain resolves, the step is routable and the dispatch happens as it always
# did.
#
# THE ADVANCE IS WHAT PROVES IT, not the journal count, and the difference
# matters. This task's journal already carries the refusal the pass above
# wrote, and it stays there -- a hand-off that has been recorded is not
# un-recorded by the operator acting on it. So the count below is asserted
# UNCHANGED (no SECOND refusal), and the evidence that the routing was
# actually admitted is the pair a refusal makes impossible: the task advancing
# out of `pending`, and a manifest for the job that carried it there.
printf 'role.implementer=withshell\nrole.reviewer=textonly\ninfra_max=9\nconcurrency=10\n' > "$ndrepo/orchid.config"
run_ndrive
assert_eq implementing "$(ndstatus NCH1)" \
  "INV-16: the identical dispatch advances once the chain names an actor declaring what implement needs — a refusal returns before the advance, so this is unreachable while the step is being refused (out: $NDRIVE_OUT)"
[ -n "$(list_dir_files "$ndrepo/.orchid/runtime/jobs")" ] \
  || fail "INV-16: the advance into implementing must be backed by a job that really spawned"
assert_eq 1 "$(ndrefusals NCH1)" \
  "INV-16: and no SECOND refusal was journaled — the one line above is the record of a hand-off that has since been acted on, not a refusal still firing"
green_case 'the same driver pass, with only role.implementer rebound to an engine declaring workspace_write, shell and git, dispatched the task and journaled no refusal — so the hand-off above is about the chain and not about the walk'

# ===========================================================================
# 11c -- AN INCAPABLE PRIMARY MUST NOT SHADOW A CAPABLE PROVEN FALLBACK.
#
# Parts 4 and 11 both refuse a chain in which NOBODY can do the work. This is
# the case in between, and until now it was refused too -- wrongly.
# `resolve_role_available` answered "who may hold this ROLE": it walked the
# chain, stopped at the first entry that was discovered, role-eligible,
# ledger-available and (past the primary) capsuite-passed, and handed that
# entry to the step gate. Where a role descriptor asks for LESS than the step's
# work costs -- which is the custom role this whole file exists for, the one
# whose descriptor its own publisher writes -- the walk stops at an entry that
# cannot perform the work while an entry that CAN stands right behind it in the
# same chain. The step gate then refuses permanently, and the fallback is never
# reached by anything.
#
# That is a failover chain declining to fail over. A capability shortfall is as
# permanent a reason to move to the next entry as a rate limit is a temporary
# one, so selection is told which STEP it is picking for (lib/resolver.sh's
# resolve_role_available takes the step; `orchid jobs prepare` passes the
# operation) and an entry the table refuses is SKIPPED with its shortfall named
# among the disqualifiers, exactly like every other one.
#
# The GREEN twin comes FIRST here, and it is the guard that keeps the skip from
# meaning "pick anybody": the fallback is capable but has no capsuite record
# yet, so the chain must still come up empty and still be the WAIT it always
# was -- not a refusal, because one entry the table does not refuse means a
# later pass can route the step, and not a dispatch, because a fallback
# activates only once `orchid plugins test` has proved it for this role.
# ===========================================================================
mk_engine chainprimary "workspace_read,workspace_write,shell,git"
mk_engine chainfallback "structured_text"
ochain="$WORK/ochain"; mkdir -p "$ochain/.orchid/tasks" "$ochain/.orchid/reviews"
cd "$ochain" || exit 1
git init -q .
git commit -q --allow-empty -m root
export ORCHID_REPO="$ochain"
OEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$OEPOCH"
"$ORCHID_BIN" task create TO "a chain whose primary cannot do the work" >/dev/null
printf 'verify=true\nrole.runner=chainprimary,chainfallback\n' > "$ochain/orchid.config"

# The premise, asserted rather than assumed, in both directions: the ROLE gate
# admits the primary (so nothing but the step table can move past it), and the
# step table REFUSES it (so there is something to fail over from).
role_eligible runner "$WORK/eng/chainprimary" \
  || fail "INV-16 fixture: the custom role must ADMIT the primary, or the skip below is the role gate doing its old job"
orc=0; capability_routing_refusal review chainprimary >/dev/null 2>&1 || orc=$?
assert_eq 1 "$orc" \
  "INV-16 fixture: the step table must REFUSE the primary a review step, or there is nothing for selection to fail over from"

if capsuite_passed chainfallback runner; then
  fail "INV-16 fixture: the fallback must have NO capsuite record yet, or the wait this twin is about never happens"
fi
jobs_before="$(list_dir_files "$ochain/.orchid/runtime/jobs" | wc -l | tr -d ' ')"
rc=0; err="$("$ORCHID_BIN" jobs prepare TO runner review 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" \
  "INV-16: skipping an incapable primary does not promote an unproven fallback — the chain is still the wait one orchid plugins test clears"
case "$err" in
  *"refusing to route"*) fail "INV-16: one entry the table does not refuse must not be reported as a permanent capability refusal — the remedy here is a capsuite run, not a manifest audit" ;;
esac
assert_match "capsuite not passed" "$err" \
  "INV-16: and the wait says which entry is unproven, so the operator is sent to the command that clears it"
assert_eq "$jobs_before" "$(list_dir_files "$ochain/.orchid/runtime/jobs" | wc -l | tr -d ' ')" \
  "INV-16: and mints nothing while it waits"
green_case 'an incapable primary skipped in favour of a capable but UNPROVEN fallback left the chain at exit 14 with the capsuite remedy named, so operation-aware selection does not promote an entry the failover rules have not cleared'

# ...and now the fallback is proved for this role, which is the only thing that
# changes between the two halves.
capsuite_run chainfallback runner >/dev/null \
  || fail "INV-16 fixture: capsuite_run must pass the fallback for the custom role (static checks only — no dryrun operation maps to it)"
rc=0; omf="$("$ORCHID_BIN" jobs prepare TO runner review)" || rc=$?
assert_eq 0 "$rc" \
  "INV-16: a chain holding a capable, capsuite-proven fallback must DISPATCH — the primary being unable to do the work is a reason to fail over, not a reason to refuse the chain"
[ -f "$omf" ] || fail "INV-16: an admitted chain routing mints the job manifest it always did"
assert_eq chainfallback "$(jq -r .engine "$omf")" \
  "INV-16: and the job is bound to the FALLBACK — settling on the primary is what made the step gate refuse a chain that had somebody in it who could do the work"
red_case 'a role chain whose primary is role-eligible but cannot perform the step failed over to the capable capsuite-proven entry behind it and minted the job there, instead of settling on the primary and refusing the whole chain at 19'

# ===========================================================================
# 11d -- ONE ANSWER, NOT TWO. The chain gate used to run only AFTER
# `resolve_role_available` had already failed -- which meant that by the time
# it could speak, resolution's own "no eligible engine available for role X"
# was already on stderr. An operator then met a WAIT and a PERMANENT REFUSAL
# about a single call and had to work out which of the two described their
# repository. Only one ever does, and reading the wrong one costs exactly the
# staleness windows this invariant exists to stop spending.
#
# It refuses only when EVERY entry is short, so a chain resolution could still
# pick somebody out of is one it says nothing about -- which is why asking it
# FIRST cannot refuse a dispatch that would have happened, and why the wait
# line can be left to print exactly when the wait is real. The GREEN twin below
# is that second half: the transient chain still gets its wait line, in full.
# ===========================================================================
printf 'verify=true\nrole.runner=chainprimary\n' > "$ochain/orchid.config"
rc=0; err="$("$ORCHID_BIN" jobs prepare TO runner review 2>&1 1>/dev/null)" || rc=$?
assert_eq 19 "$rc" \
  "INV-16 fixture: a chain whose only entry is short the atom must still be the permanent refusal, or this part has nothing to count the messages of"
assert_match "refusing to route" "$err" "INV-16: the permanent refusal is emitted"
case "$err" in
  *"no eligible engine available for role"*)
    fail "INV-16: a converted 14 must not ALSO carry the wait line it was converted from — an operator handed both has to guess which of two contradictory reports describes their repository" ;;
esac
red_case 'converting a permanent chain shortfall from the exit-14 wait to the exit-19 refusal emitted the refusal ALONE, instead of printing the wait line the caller must not act on beside it'

# GREEN twin: the wait line is not suppressed generally -- it is printed
# whenever the wait is what actually happened. Same verb, same repository, same
# role, and an entry the table has no objection to.
printf 'verify=true\nrole.runner=chainfallback\n' > "$ochain/orchid.config"
ledger_mark "$ochain" chainfallback rate_limited 999999
rc=0; err="$("$ORCHID_BIN" jobs prepare TO runner review 2>&1 1>/dev/null)" || rc=$?
assert_eq 14 "$rc" "INV-16: a rate-limited but capable chain is still the wait it always was"
assert_match "no eligible engine available for role runner" "$err" \
  "INV-16: and the wait line is still printed in full — suppressing it generally would trade one silent dead end for another"
case "$err" in
  *"refusing to route"*) fail "INV-16: a ledger window must never be phrased as a capability refusal" ;;
esac
green_case 'the identical verb against a capable but rate-limited chain still printed the wait line from resolve_role_available and no refusal, so emitting only the refusal is a choice about which report is true rather than the wait line being suppressed'

# ===========================================================================
# 12 -- THE WAKE, END TO END, THROUGH THE SCHEDULED PUMP.
#
# Every part above reaches this invariant through `orchid jobs prepare`. The
# ORCHESTRATE step does not: runners/orchid-tick builds its own request
# document and never mints a job, and runners/orchid-pump decides whether to
# exec it from a dry `resolve_role_available` probe. So for as long as the
# table was consulted only at prepare, an orchestrator chain that could never
# be woken produced precisely the failure INV-16 exists to end -- one line of
# terminal output per staleness window ("no capable orchestrator available"),
# forever, with nothing journaled, no human told, and the judgment boundary the
# driver raised on that very pass left for an orchestrator that is never
# coming.
#
# The fixture is a real pass of the real pump over a real repository: a task
# parked at `arbitrating` over a request-changes review raises `review-conflict`,
# which IS a boundary a woken orchestrator settles (`orchid task arbitrate`,
# which the broker admits), so the pump genuinely reaches its pre-wake probe.
# ===========================================================================
# A runnable orchestrate stub, unlike mk_engine's `exit 1` -- the GREEN twin
# below has to actually be woken, and "the pump got past its probe" is only
# credible if an adapter really ran.
mk_wake_engine() {
  local name="$1" caps="$2" dir
  dir="$WORK/eng/$name"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nrequires_binaries=jq\nentrypoint=run\n' \
    "$name" "$caps" > "$dir/plugin.conf"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -eu'
    echo "MARKER=$(printf '%q' "$WORK/wake-marker-$name")"
  } > "$dir/run"
  cat >> "$dir/run" <<'WAKEEOF'
touch "$MARKER"
req="$1"; out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"orchestrate","status":"ok","actions":[],"summary":"inv16 wake stub"}' \
  "$jid" "$task" > "$out"
WAKEEOF
  chmod +x "$dir/run"
}
mk_wake_engine wakeshort "structured_text"
mk_wake_engine wakeshort2 "structured_text,workspace_write"
mk_wake_engine wakefull "shell,git"

prepo="$WORK/pumpwake"; mkdir -p "$prepo/.orchid/tasks" "$prepo/.orchid/reviews"
cd "$prepo" || exit 1
git init -q .
git commit -q --allow-empty -m root
printf -- '---\nrun_status: running\nrun_id: r-inv16-wake\n---\n# Roadmap\n' > "$prepo/.orchid/roadmap.md"
printf 'role.implementer=withshell\nrole.reviewer=textonly\nrole.orchestrator=wakeshort,wakeshort2\n' \
  > "$prepo/orchid.config"
export ORCHID_REPO="$prepo"
PEPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH="$PEPOCH"
"$ORCHID_BIN" task create TPW "a contested review nobody can be woken for" >/dev/null
PWCAND=7777777777777777777777777777777777777777
fm_set "$prepo/.orchid/tasks/TPW.md" status arbitrating
fm_set "$prepo/.orchid/tasks/TPW.md" candidate_sha "$PWCAND"
jq -n --arg cand "$PWCAND" \
  '{contract:1, job_id:"j-inv16-TPW", task:"TPW", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:"fixture review",
    candidate_sha:$cand, findings:[]}' > "$prepo/.orchid/reviews/TPW-a1-reviewer.json"
unset ORCHID_EPOCH
"$ORCHID_BIN" trust unattended "$prepo" --reason "INV-16 pump fixture" >/dev/null \
  || fail "INV-16 fixture: the pump refuses an unacknowledged repository, so the wake probe would never be reached"

# stale_lease -- the pump reads lease age BEFORE it hands the pass to the
# driver, and the driver refreshes the lease while it runs, so every pump pass
# below has to be re-staled first.
stale_lease() {
  mkdir -p "$prepo/.orchid/runtime"
  jq -n '{epoch:1, refreshed_at:"2000-01-01T00:00:00Z"}' > "$prepo/.orchid/runtime/lease.json"
}
pw_handoffs() {
  grep -c "routed the 'orchestrate' step for role 'orchestrator'" \
    "$prepo/.orchid/BLOCKERS.md" 2>/dev/null || true
}

stale_lease
PRC=0; POUT="$("$REPO_ROOT/runners/orchid-pump" 2>&1)" || PRC=$?

# The premise: the pump really did reach its pre-wake probe. Without a boundary
# a woken orchestrator could settle, it exits earlier and this part would be
# asserting about a code path it never entered.
assert_eq review-conflict "$("$ORCHID_BIN" run boundary show 2>/dev/null | jq -r .kind)" \
  "INV-16 fixture: the pass must end at a boundary an orchestrator WOULD be woken for, or the probe below is never reached (out: $POUT)"
assert_eq 0 "$PRC" \
  "INV-16: a hand-off recorded for a human is a normal poll outcome — the scheduled pump must not start failing over it (out: $POUT)"
assert_match "INV-16" "$POUT" \
  "INV-16: the pump names the routing refusal rather than reporting a chain nobody can be woken from as an ordinary poll result"
assert_match "role.orchestrator" "$POUT" \
  "INV-16: and names the key that binds that chain, which is the one thing an operator can act on"
case "$POUT" in
  *"no capable orchestrator available"*)
    fail "INV-16: a chain short an atom the orchestrate step needs must not be reported as the come-back-later poll result — nothing reopens, so the next pass says the same thing and the boundary is never settled" ;;
esac
assert_eq 1 "$(pw_handoffs)" \
  "INV-16: the refusal is recorded once, durably, where an operator reads it — a wake nobody can perform that leaves no record is the silent dead end this invariant is about"
assert_match "routed the 'orchestrate' step for role 'orchestrator'" \
  "$(cat "$prepo/.orchid/journal.md")" \
  "INV-16: and journaled, so the run's own history says the wake was refused rather than showing a boundary that simply stopped being acted on"
assert_eq review-conflict "$("$ORCHID_BIN" run boundary show 2>/dev/null | jq -r .kind)" \
  "INV-16: and the driver's own boundary record is left exactly as it was — the pump raises the blocker without overwriting a record another writer owns"
[ -e "$WORK/wake-marker-wakeshort" ] \
  && fail "INV-16: no adapter may be spawned for a step its manifest does not cover"
[ -e "$WORK/wake-marker-wakeshort2" ] \
  && fail "INV-16: nor may the fallback be, for the same reason"
red_case 'the real scheduled pump, meeting an orchestrator chain in which every entry is short an atom the orchestrate step needs, recorded one journaled operator hand-off naming role.orchestrator instead of printing its come-back-later poll line once per staleness window forever'

# GREEN twin 1 -- ONCE PER DISTINCT FACT, NOT ONCE PER PASS. The condition
# persists until a human acts and the walk re-reaches it every cycle, so a
# blocker per pass would bury the run's history under one unchanging fact.
stale_lease
PRC=0; POUT="$("$REPO_ROOT/runners/orchid-pump" 2>&1)" || PRC=$?
assert_eq 0 "$PRC" "INV-16: a repeated pass over the same refusal is still a no-op (out: $POUT)"
assert_eq 1 "$(pw_handoffs)" \
  "INV-16: and raises no SECOND blocker for a fact that has not changed"
green_case 'a second pump pass over the same permanently-refused chain raised no second blocker, so the hand-off is recorded once per distinct fact rather than once per staleness window'

# ...AND THE OTHER ENTRY POINT SAYS THE SAME THING. runners/orchid-tick is an
# unattended entry in its own right (its own trust gate says so), so a
# scheduler pointed straight at it must not get the wait either. It reports
# through its EXIT CODE and its message and journals nothing: a direct tick is
# one shot with a caller watching it, and the durable record for the scheduled
# loop is the pump's, raised exactly once above. Two writers of one fact is how
# a run's history ends up with the same line on every pass.
handoffs_before_tick="$(pw_handoffs)"
TRC=0; TOUT="$("$REPO_ROOT/runners/orchid-tick" 2>&1)" || TRC=$?
assert_eq 19 "$TRC" \
  "INV-16: the headless tick reports a chain nobody in it can orchestrate as the permanent refusal, not as the exit-14 wait a scheduler retries forever (out: $TOUT)"
assert_match "routed the 'orchestrate' step for role 'orchestrator'" "$TOUT" \
  "INV-16: and says so in the same words the pump records, so the two entry points cannot describe one fact differently"
assert_eq "$handoffs_before_tick" "$(pw_handoffs)" \
  "INV-16: and files no blocker of its own — the pump already recorded this fact, and a second writer would re-raise it on every pass"
[ -e "$WORK/wake-marker-wakeshort" ] \
  && fail "INV-16: the tick must refuse before it spawns, not after"
green_case 'the headless tick, run directly against the same refused chain, exited 19 with the same sentence and filed no second record, so the classification belongs to both pre-wake entry points rather than to the pump alone'

# GREEN twin 2 -- AND THE TRANSIENT CASE IS STILL TRANSIENT, which is the whole
# distinction this part turns on. `wakefull` declares exactly what the
# orchestrate step needs and is merely rate-limited; nothing about that is
# permanent, the poll line is the correct report, and a hand-off here would
# send an operator to audit a manifest that covers the work.
printf 'role.implementer=withshell\nrole.reviewer=textonly\nrole.orchestrator=wakefull\n' \
  > "$prepo/orchid.config"
ledger_mark "$prepo" wakefull rate_limited 999999
stale_lease
PRC=0; POUT="$("$REPO_ROOT/runners/orchid-pump" 2>&1)" || PRC=$?
assert_eq 0 "$PRC" "INV-16: an unavailable-but-capable orchestrator is still an ordinary poll outcome (out: $POUT)"
assert_match "no capable orchestrator available" "$POUT" \
  "INV-16: and it still gets the come-back-later line, because coming back later is exactly what clears a ledger window"
case "$POUT" in
  *"INV-16"*) fail "INV-16: a rate-limited engine that declares everything the step needs must never be handed to an operator as a capability refusal" ;;
esac
assert_eq 1 "$(pw_handoffs)" \
  "INV-16: and raises no hand-off blocker at all — the count is the one the permanent case left behind"
[ -e "$WORK/wake-marker-wakefull" ] \
  && fail "INV-16: a rate-limited engine must not be spawned either"
green_case 'the same pump against a chain whose only entry declares everything orchestrate needs and is merely rate-limited printed the ordinary poll line and raised no hand-off, so the refusal above is a capability decision rather than the pump reporting every unavailability as permanent'

# GREEN twin 3 -- and the wake itself still happens. Only the ledger mark is
# cleared: same repository, same boundary, same chain, an engine declaring
# `shell` and `git`. If the probe above were refusing on anything but the
# capability fact, this is the pass that would show it.
ledger_mark "$prepo" wakefull ok
ledger_available "$prepo" wakefull \
  || fail "INV-16 fixture: the ledger window must be open again, or this twin proves only that a rate limit still holds"
stale_lease
PRC=0; POUT="$("$REPO_ROOT/runners/orchid-pump" 2>&1)" || PRC=$?
[ -f "$WORK/wake-marker-wakefull" ] \
  || fail "INV-16: the pump must exec the tick and wake a capable orchestrator — the probe gates the wake, it does not replace it (rc $PRC, out: $POUT)"
assert_eq 1 "$(pw_handoffs)" \
  "INV-16: and a successful wake raises no hand-off of its own"
green_case 'the identical pump pass, with only the ledger mark cleared, woke the orchestrator adapter that declares shell and git — so the two refusals above are decisions about the chain rather than a pump that had stopped waking anything'

# ===========================================================================
# 13 -- THE PREDICTION MUST NAME THE ENTRY THE WAKE WILL ACTUALLY USE.
#
# Part 11c made selection operation-aware, so an incapable primary is failed
# over rather than settled on. lib/drive.sh's drive_orchestrator_surface asks
# the SAME chain a second question -- "what command_surface will the adapter
# the pump wakes declare?" -- and its answer feeds
# drive_boundary_wakes_orchestrator, which is what decides whether a judgment
# boundary is offered to a model at all or routed to a human. Two readings of
# one chain that disagree about WHICH ENTRY wins is a decision made from the
# manifest of an adapter nobody is going to spawn: the pump fails over to the
# capable entry and reports on the incapable one's label.
#
# On the shipped tree the two questions coincide, because
# roles/orchestrator.role requires `shell,git` and the orchestrate row prices
# exactly those -- so the role gate stops the incapable primary before either
# question is asked. They come apart in the one place this whole file is about:
# a descriptor asking for LESS than the work costs. That descriptor is
# kernel-shipped for this role, so the fixture must supply its own; it is
# written LAST, after every part above has run against the real one.
# ===========================================================================
printf 'id=orchestrator\ndescription=INV-16: an operator descriptor asking for less than the orchestrate step costs\n' \
  > "$WORK/roles/orchestrator.role"

# <name> <capabilities> <command_surface> -- mk_engine plus the one manifest
# key this part reads. Nothing is spawned here either: drive_orchestrator_surface
# resolves and reads a declaration.
mk_surface_engine() {
  local name="$1" caps="$2" surface="$3" dir
  dir="$WORK/eng/$name"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=%s\nentrypoint=run\ncommand_surface=%s\n' \
    "$name" "$caps" "$surface" > "$dir/plugin.conf"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/run"
  chmod +x "$dir/run"
}
mk_surface_engine surfshort "structured_text" soft
mk_surface_engine surfcapable "shell,git" brokered

srepo="$WORK/surfchain"; mkdir -p "$srepo"
printf 'role.orchestrator=surfshort,surfcapable\n' > "$srepo/orchid.config"

# The premises, asserted rather than assumed. The labels differ (so the two
# readings are distinguishable at all), the role gate ADMITS the primary under
# the descriptor just written (so only the step table can move past it), the
# step table REFUSES it, and the fallback is capsuite-proven (so the wake really
# does reach it rather than stopping at an unproven entry).
assert_eq soft "$(manifest_get "$WORK/eng/surfshort" command_surface soft)" \
  "INV-16 fixture: the incapable primary declares the unrestricted label"
assert_eq brokered "$(manifest_get "$WORK/eng/surfcapable" command_surface soft)" \
  "INV-16 fixture: and the capable fallback the restricted one, or the two readings cannot be told apart"
role_eligible orchestrator "$WORK/eng/surfshort" \
  || fail "INV-16 fixture: the supplied descriptor must ADMIT the primary, or this part is the role gate doing its old job"
src=0; capability_routing_refusal orchestrate surfshort >/dev/null 2>&1 || src=$?
assert_eq 1 "$src" \
  "INV-16 fixture: the step table must REFUSE the primary the orchestrate step, or there is nothing to fail over from"
capsuite_run surfcapable orchestrator >/dev/null \
  || fail "INV-16 fixture: capsuite_run must pass the fallback for the orchestrator role, or the wake stops at an unproven entry instead"

assert_eq brokered "$(drive_orchestrator_surface "$srepo")" \
  "INV-16: the surface is read off the entry the wake will actually use — reporting the incapable primary's label decides a judgment boundary from the manifest of an adapter nobody will spawn"
red_case 'the surface prediction the driver and the pump both consult followed the same operation-aware walk the wake does and reported the capable fallback command_surface, instead of the label of the role-eligible primary that cannot perform the orchestrate step'

# GREEN twin -- and it is still the WINNER's label, not a constant. Same
# function, same repository, one entry, capable, declaring the other label.
mk_surface_engine surfsoft "shell,git" soft
printf 'role.orchestrator=surfsoft\n' > "$srepo/orchid.config"
assert_eq soft "$(drive_orchestrator_surface "$srepo")" \
  "INV-16: a capable orchestrator's own label is still what is reported — the skip above is a failover decision, not the prediction collapsing to the narrowest answer"
green_case 'the same prediction against a single capable entry declaring the unrestricted surface reported that label, so skipping an incapable entry narrows nothing on its own'
