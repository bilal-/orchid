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
#      nothing recorded.
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
#      its job once the bound actor declares what the step needs. Without those
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
assert_eq "workspace_write" "$(capability_step_requires implement)" \
  "INV-16: implement needs workspace_write"
assert_eq "structured_text" "$(capability_step_requires review)" \
  "INV-16: review needs structured_text — with this row empty, a capability-free actor reaching review through a custom role met no gate at all"
assert_eq "structured_text" "$(capability_step_requires critique)" \
  "INV-16: critique needs structured_text for the same reason review does — it returns the same kind of structured envelope"
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
