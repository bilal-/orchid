# PROTOCOL.md — the v0 tick procedure

*Kernel-owned, engine-neutral. Written entirely in existing `orchid` CLI verbs
plus the one job spawner, `runners/orchid-launch`. Any front-end — a Claude
Code skill, a codex-driven tick runner, a human typing commands — executes
this procedure by running the commands named here, in the order given.
Front-ends are a convention (anything that executes this file via verbs), not
part of the architecture; this file never changes to suit one.*

## Preamble

- **No external mutation.** Never `git push`, never fetch/pull, never
  contact any remote — every mutation this file authorizes is repo-local;
  the operator alone moves anything to origin. `orchid init` also installs
  a `.git/hooks/pre-push` guard (`push_guard`, config, default true) as
  defense-in-depth: it refuses any push of a `task/*` branch or the
  integration branch unless `ORCHID_ALLOW_PUSH=1`. This bullet is prompt
  policy and the hook is a bypassable backstop (it may also be absent when
  an operator hook already exists); neither is OS/network containment for a
  shell-capable orchestrator.
- **You are the orchestrator.** Your only interface to run state is `orchid
  <verb>` and, for spawning engine work, `runners/orchid-launch`. Never
  hand-edit anything under `.orchid/` — no frontmatter, no journal, no
  roadmap — even when you can see exactly what line would need to change.
  Every mutation goes through a verb so it is fenced, journaled, and legal by
  construction.
- **Most of this file is now executable.** `orchid drive` (v1.1) runs ONE
  deterministic pass of THE TICK below — steps 1, 2, 3 and 5 — in shell, with
  no model involved: lease refresh, reconcile/check/gc ordering, safe
  dispatch, implementer reconciliation, verification, reviewer routing and
  reconciliation, deterministic approval where policy is unambiguous, one
  serialized merge, status regeneration, final lease refresh. It never makes
  a free-form judgment: every decision it takes reads a structured field (a
  frontmatter key, a validated envelope field, an archetype's declared
  transitions, a schedule predicate, an exit code), never prose. Where policy
  is ambiguous it stops at a named JUDGMENT BOUNDARY (see "Judgment
  boundaries" below) and exits 16 rather than guessing. A human or an LLM
  front-end executing this file by hand is still fully supported and is what
  the prose below describes; `orchid drive` is the same procedure, mechanized,
  and the two are interchangeable pass by pass.
- **Every judgment carries `--reason`.** The kernel only hard-requires
  `--reason` on a subset of edges (`orchid run advance`/`run accept` always;
  `orchid task advance` on `*→merging`, `*→blocked`, and `arbitrating→rework`
  specifically). This protocol requires it everywhere a human or a future
  resumer would otherwise have to guess *why*: every `task advance`, `task
  unblock`, `task retry`, `task reverify`, and `notify` call in the walk
  below carries one, whether or not the verb itself would accept the
  omission.
- **Concurrency, not "one active task."** Up to `concurrency` (config,
  default 2) tasks may hold a non-idle status — `implementing`, `testing`,
  `reviewing`, `arbitrating`, or `merging` — at the same time. Dispatch
  itself is gated fail-closed: `orchid task advance <id> implementing` (the
  only edge that actually dispatches a `pending`/`rework` task) refuses
  whenever `lib/schedule.sh`'s predicates say no — `concurrency-cap (<n>/
  <cap>)`, `exclusive-overlap (<id>)`, `resource-conflict (<res>: <id>)`,
  `waiting-deps (<ids>)` — the exact predicate set `orchid status --explain`
  already names on every `pending`/`rework` row, so "why didn't it dispatch"
  is never a guess before you even try. Two steps stay serial within a
  single tick regardless of the cap: `testing` (`orchid verify` runs
  synchronously, in the tick's own foreground — there is no job to overlap)
  and `merging` (`orchid merge` is transactional and CAS-guarded against the
  integration ref; walk at most one task through it per tick, even if
  several sit in `merging` at once — see that bullet below). Everything else
  is queued (`pending`/`rework`), waiting on a human (`blocked`), or
  finished (`done`).
- **Risk-tiered review policy.** There is no fixed reviewer count — the
  task's `risk_tier` (`orchid task show <id>`) decides how many reviewer
  slots this attempt needs and which engines fill them. Consult `orchid jobs
  review-plan <id> --pin` FIRST, every attempt: it prints the routing table
  for the task's CURRENT `risk_tier`, one line per required slot — `<slot>
  <engine>	<engine-independent|session-independent>	<worktree|inline>`
  — computed from `role.reviewer`'s chain, the `review.<tier>` chain,
  engine discovery, role eligibility, and the ledger, all at once, plus
  each slot's manifest capabilities for that last column. A PINNED table
  carries one further field per row — the qualified engine id (`orchid/agy`)
  that slot's name resolved to when the round was dispatched, which is how a
  filed review is matched back to its slot. You never need it to dispatch
  one; read the engine from column 2 as before. Never re-derive this by
  hand. Launch each printed slot with `runners/orchid-launch <id>
  reviewer review --engine <slot-engine>` — `--engine` is exactly how a
  second (or third) slot's engine differs from whatever `role.reviewer`
  would resolve to on its own.
  **The table is PINNED for the life of an attempt, by WHOEVER dispatches
  it.** `orchid jobs review-plan <id> --pin` writes it down, bound to the
  task's `attempts`+1 and its current `candidate_sha`; every later read —
  including the bare, unfenced `orchid jobs review-plan <id>` — returns that
  table until one of those two changes. The deterministic driver pins on its
  first `reviewing` pass, and the pin is idempotent, so an orchestrator that
  dispatches slots itself pins with the same command and gets back whatever
  was already written. Pin BEFORE launching the first slot, not after: a
  table that is still being recomputed between one slot's dispatch and the
  next is exactly the table that moves. (A task with no `candidate_sha` yet
  has no round of evidence to bind a plan to; `--pin` refuses, and the bare
  read is all there is to have.) This is not tidiness: engine health is one
  of the inputs, so a table recomputed on every read MOVES — and on r-002 it
  moved after an engine had already filed a valid review, re-routing the slot
  that review had been dispatched for and leaving a task that could not
  advance, could not rework and could not be arbitrated (lesson L027).
  Evidence is judged against the plan the attempt was dispatched under, never
  against a plan computed after the fact. Before dispatching ANY slot the
  table labels `session-independent`, journal it — the same rule as before,
  now applied per-slot: `orchid journal add --task <id> "reviewer slot <n> is
  session-independent only: <engine>, same as the implementer's"`. Never let
  a degraded independence pass silently, on any slot.
- **Review depth is a SECOND axis, not the same one.** Column 3 says who the
  reviewer is not; column 4 says what it can see. An `inline` reviewer
  judges the diff text alone and cannot open a file the diff never showed
  it; a `worktree` one can (manifest capability `workspace_read`). At
  `risk_tier` `medium`/`high` a deterministic approval needs at least one
  review credited to a `worktree` slot of the PINNED plan — the same table,
  and the same slot matching, that says which slot a review fills, so
  re-binding or uninstalling an engine after its review is filed changes
  neither answer. Without one, `orchid drive` reports unproven review depth
  and stops at an arbitrable `review-evidence` boundary instead of
  approving, and you settle it by reading the diff and running `orchid task
  arbitrate`. That credit comes from the PIN or from nowhere: at those tiers
  a plan that is missing, unreadable, empty, or bound to a candidate the task
  has moved off is itself reported as unprovable review depth, naming which
  of the four it was, rather than answered out of a table computed after the
  reviews were filed. Settle it with `orchid task arbitrate`, or — when the
  engines that actually reviewed are the ones to record — with `orchid jobs
  review-plan <id> --adopt-evidence` and another `orchid drive`. Not with
  `--pin`: run after the evidence is on disk it freezes whatever routing says
  at that moment, which is the very thing pinning exists to prevent. If the
  whole table comes back `inline`,
  journal that before dispatching — same discipline as a
  `session-independent` label — and dispatch every slot anyway: no slot is
  ever dropped for being inline. See docs/specs/kernel.md, "Review depth",
  for why this keys on `risk_tier` rather than on a task's prose.
- **Inline-review blind-spot guard.** The reviewer's input pack includes
  `symbols.txt` — every changed file and hunk header
  (`+++`/`@@` lines) from `base_sha..candidate_sha`'s diff. When the diff
  clearly reaches into (calls, extends, imports) a symbol whose OWN
  definition lives in a file `symbols.txt` never lists — the reviewer would
  otherwise have to judge code it cannot see — upgrade that slot to a
  worktree-capable engine (manifest capability `workspace_read`; `orchid
  jobs review-plan`'s own depth slot already prefers one, but this guard can
  promote any slot) and journal the upgrade, same discipline as a
  session-independent label above.
- **Launch by role only.** Every spawn is `runners/orchid-launch <task-id>
  <role> <operation>`, where `<role>` is one of the roles bound in config
  (`role.implementer`, `role.reviewer`, ...). Never invoke an engine binary
  directly, and never invent a role that isn't a config key.
- **Every check ships a RED case.**
  **A check that cannot fail is not a check** — and it is the failure mode
  this loop produces most often, because it costs nothing and reads like a
  pass. Runs r-001 and r-002 shipped, in good faith, a review envelope with an
  empty `findings[]`, a probe that grepped the reply for the string it had fed
  into the prompt, a rehearsal snapshot comparing a tree never at risk, a
  `doctor` reporting outbound ok without reading the config its plugin
  requires, and an inbound line whose output was identical whether or not a
  gateway existed. So: anything this protocol treats as a gate — a task's
  `verification_commands`, a reviewer's `findings[]`, a hook's artifact, a
  probe an envelope's summary leans on — must ship a RED case demonstrating
  that it DETECTS the failure it exists for, exercised by the suite rather
  than described in a comment, plus the GREEN twin that keeps it from being a
  matcher that rejects everything — and the twin has to be exercised inside the
  gate itself, not delegated to some other check that happens to cover the
  accepting direction. What cannot be demonstrated is recorded as
  `not-tested` (`orchid notify`, the journal, or `tests/helpers.sh`'s
  `not_tested`), never as a pass. The normative statement, and what is
  mechanically enforced, is docs/specs/kernel.md's "Proof discipline"; new
  gates live under `tests/inv/`, where `red_case` and `green_case` are both
  required by location — resolved from the file's real path, so the
  requirement cannot be shed by invoking the file a different way.
- **Hook points.** Five kernel-owned edges — `after_plan_draft`,
  `before_arbitration`, `on_verify_fail`, `before_merge`, `on_blocker` — may
  each carry zero or more plugin NAMEs (the short discovery name; a
  qualified id like `acme/foo` is not accepted in a binding in v1) bound via
  `hook.<point>` config (`orchid config list` shows the current binding; an
  empty value means
  unbound — skip the point, there is nothing to launch). Invoking a bound
  point is always the same shape: launch its first bound entry with
  `runners/orchid-launch <task-id> hook hook --hook <point>` (the role
  positional carries no meaning for a hook job — pass the literal `hook`; a
  hook job's real identity for engine-resolution purposes comes entirely
  from the point's config binding, never the role chain), launch every
  additional bound entry the same way but with `--engine <name>` naming
  it explicitly (mirrors a second reviewer slot), then `orchid jobs
  reconcile` before reading any of their envelopes. A binding entry marked
  `:required` whose reconciled envelope is missing, stale, or not `status:
  ok` is a real failure of that dependency — for `before_merge` specifically
  the kernel itself refuses the merge over it (see that step below); for the
  other four points, this protocol's own read of the artifact is the only
  enforcement, so treat a required failure like any other unmet dependency
  (`orchid notify` and let a human decide) rather than silently proceeding
  as if it had passed. An `optional` entry's failure is never blocking, on
  any of the five points — read it if it reconciled, move on if it didn't.

## Judgment boundaries (`orchid drive`, `orchid run boundary`, `orchid task arbitrate`)

A **judgment boundary** is the one thing deterministic policy is allowed to
do instead of deciding: stop, name why, and hand the decision to someone who
may make it. `orchid drive` records at most one per pass through its own
verb — `orchid run boundary set --kind <kind> [--task <id>] --reason "..."` —
and exits 16, the dedicated judgment-boundary exit code. `orchid run boundary
show` prints the record (schema 1: `kind`, `task`, `reason`, `epoch`, `at`)
and itself exits 16 when one is recorded, 0 when none is. `orchid run boundary
clear --reason "..."` releases it. That verb is the record's single writer;
nothing else may create, edit or delete it.

**Exit 16 says a decision is outstanding SOMEWHERE — never that the run is
stuck.** A pass that meets a boundary still walks every other task and takes
every edge policy allows; the record is written and 16 returned at the END of
that pass, not the moment the boundary was met. What it asks of a caller is
that the decision reach a human, which the pass has already done by raising
one `orchid notify` blocker per distinct record whenever no admitted verb can
settle it — and then that the caller KEEP DRIVING. `orchid drive` is
idempotent, so a boundaried task re-reports the identical record on the next
pass at no cost while every unrelated task keeps advancing. Reading 16 as
"stop and fetch a human" is how one task's arbitration parks a whole roadmap:
it is attended operation wearing an unattended label. Exit 1, not 16, is the
code that means a pass could not be made at all.

When one pass meets several boundaries, the one RECORDED is the one a woken
orchestrator could actually SETTLE, ahead of the ones only an operator can;
among equals, the first in task-id order. The walk still notes every boundary
it meets. Without that precedence a `blocked` task, which raises the same
operator-only boundary on every pass until a human runs `task
unblock`/`task retry`, would permanently mask a later task's arbitrable one
and spend an LLM wakeup per pump cycle on a decision the woken model has no
verb to make.

**"Could settle" is never a property of the kind alone.** It is the
conjunction of three facts, and each of them is read from structured data:

1. **Which verb records the result.** `review-evidence`/`review-conflict` →
   `orchid task arbitrate`. `planning` → `orchid plan apply`. `run-complete`
   → `orchid run accept --evidence`. `blocked-task`, `hook-failure`,
   `worktree-conflict`, `operator-handoff`, `task-prerequisite` and
   `operator-decision` name none — no procedure an orchestrator can run
   resolves them.
   The two operator-owned stops before verify are the deliberate cases rather
   than gaps, and for the same reason: each HAS a verb, and naming it here
   would route the boundary to a model whose only available move is to claim
   work it did not do.
   `operator-handoff` — `orchid task handoff --ack` is a real verb and the
   broker could be taught to admit it, which is exactly why it must not be.
   That verb asserts that execution-requiring work was performed by an actor
   able to perform it, and a model that can run neither the linter nor
   `chmod`, acknowledging its own hand-off, would recreate the unsatisfiable
   routing the hand-off exists to prevent — now with a durable field claiming
   otherwise.
   `task-prerequisite` is the same case one step further out: `orchid task
   prereq-ack` is a real verb and it does settle that boundary, but what it
   records is that a HUMAN did something outside the repository — applied a
   migration to a database, provisioned a credential. No model can do that
   thing, so none may assert it was done, and the boundary is left unnamed
   here so it reaches an operator through `orchid notify` instead.
2. **Whether the resolved adapter's `command_surface` admits that verb.** A
   `brokered` adapter can run only the broker
   (`runners/orchid-orchestrator-command`), whose single state-changing
   judgment verb is `orchid task arbitrate`; it refuses `plan apply`, `run
   accept`, `task unblock` and every other write. A `soft` adapter is not
   *stopped* from running those, but nothing asks it to: what a woken
   orchestrator is handed is the judgment-boundary contract — read the
   record, read the task and its reviews, record ONE decision — and that
   contract names the same write verbs the broker admits. So `soft` means
   "the same set, unenforced", never "every verb". Reading it as "every verb"
   was a live defect: with a soft orchestrator resolved, every kind
   classified as settleable, which suppressed the `orchid notify` blocker for
   all of them and woke a model per staleness window to run `orchid run
   accept` or `orchid plan apply` — verbs no prompt had asked it for — with
   the human never told. An unrecognized label reads as `brokered` — the
   surface whose set is enforced rather than merely asked for, so an unknown
   label can only ever route more boundaries to a human.
3. **Whether the task's CURRENT status lets that verb run.** `orchid task
   arbitrate` refuses any status but `arbitrating` (exit 3), so a review
   boundary raised while the task is still `reviewing` — which is exactly
   what the reviewing walk's own slot-independence boundary is — is not
   arbitrable, however arbitrable the same kind becomes one transition later.

Both consequences are load bearing. A `run-complete` boundary is a HUMAN's
job on every surface shipped today: no adapter is asked to run — and the
brokered one cannot run — the verb that closes the run, so `planning` and
`run-complete` route to a blocker rather than a wakeup whatever the label
says. And a review boundary raised from `reviewing` must not outrank a
genuine operator-only one with a verb that would have exited 3.

The kernel-owned boundary kinds:

| kind | raised when |
| --- | --- |
| `planning` | `run_status` is `planning` — drafting and critiquing a roadmap is judgment work (PLANNING below) |
| `blocked-task` | a task sits in `blocked`; only `orchid task unblock`/`orchid task retry`/`orchid task reverify` resolves it |
| `review-evidence` | fewer valid, `ok`, current-`candidate_sha` reviews are on hand than the task's `risk_tier` requires — or the tier's count is met while a routed reviewer slot still has no review of its own |
| `review-conflict` | at least one `request-changes` verdict, a finding at or above the task's `blocking_severity`, mixed verdicts, or a review reporting `scope_complete: false` |
| `hook-failure` | a `:required` hook binding has no `ok` envelope for the current candidate |
| `worktree-conflict` | a dispatch worktree cannot be proven to belong to this task, this branch and this repository — or its state cannot be read at all, which is refused in the same direction rather than taken for a clean tree |
| `operator-handoff` | work no actor in the loop declares the capability for: a step whose requirements the resolved actor's manifest does not cover, so it was never dispatched (INV-16, `orchid jobs prepare` exit 19) — or this candidate's execution-requiring mechanical steps are not acknowledged for it, because `handoff_before_verify` is on, or because its implementer is installed under neither name it is looked up by — the directory a binding names, or the qualified `id=` a manifest claims. See "The operator hand-off" below |
| `task-prerequisite` | the task declares an `operator_prerequisite` — a step outside the sandbox its verification depends on — that nobody has acknowledged for this candidate; raised by either stage that runs the suite (see THE TICK's `testing` and `merging` steps) |
| `run-complete` | every task is `done`; the acceptance checks and `orchid run accept --evidence` behind COMPLETION below are judgment work no verb decides |
| `operator-decision` | everything else policy deliberately refuses to decide: attempts exhausted, wallclock budget exceeded, a status/archetype combination with no declared edge, a merge left stuck by a CAS/config problem, an implement dispatch that left real work uncommitted in the task worktree |

**Waking a model for one asks the SAME question.** The precedence above
decides which of several boundaries goes into the record;
`runners/orchid-pump` then asks whether to wake an orchestrator for the one
that did — and it is the identical three-fact test, re-derived from the
recorded `kind`, the named task's current status, and the resolved adapter's
`command_surface`. A boundary no admitted verb can settle wakes nobody: it
would recur identically until a HUMAN acts, so the pump refuses to spend a
wakeup per cycle re-reading it, and the driver instead raises one `orchid
notify` blocker per distinct record — the surface that condition actually
needs. The pump prints `pump: judgment boundary [<kind>] is operator-only —
not waking an orchestrator` and exits 0.

These two questions used to differ, and the gap was a defect rather than a
nuance: `run-complete` was classed as orchestrator-resolvable even though the
broker refuses `orchid run accept`, so a finished run woke a model every
staleness window forever — and because the notify path is suppressed for
anything an orchestrator can settle, the operator was never told to run the
acceptance step at all. They are now one function.

**The arbitration truth table.** At `arbitrating`, exactly one of three arms
applies — they are mutually exclusive and evaluated in this order, so an
incomplete review set is never also reported as a conflict, and vice versa:

1. **Evidence** — the evidence set is EXACTLY the one the kernel's own
   `reviewing`→`arbitrating` gate counts, and this arm mirrors that gate
   rather than second-guessing it. An envelope for the current attempt counts
   only when it is bound to the task's CURRENT `candidate_sha`, validates,
   and reports status `ok`. Everything else is **skipped, never a boundary**:
   an envelope bound to a different candidate (a sibling left by a relaunched
   reviewer slot, or by the `merging`→`testing` rebase edge), one whose
   `candidate_sha` cannot be read at all, one that fails to validate, and one
   whose status is not `ok`. The kernel gate says so in its own words — "Only
   status==ok envelopes count; anything else is silently skipped, same as an
   sha mismatch". This arm then fires on the COUNT alone: fewer than
   `review_required_count(risk_tier)` surviving envelopes, or no
   `candidate_sha` on the task at all. → boundary `review-evidence`, **no
   transition**.

   **Why skipping, not failing closed.** The ordinary recovery path is a
   reviewer slot that errors, `orchid jobs reconcile` filing the adapter's own
   non-`ok` envelope bound to the current candidate, and the relaunch filing a
   good one. The kernel gate ignores the dead envelope and admits the task to
   `arbitrating` with a complete unanimous set. A driver that boundaried on
   that dead envelope would then refuse deterministic approval forever, over a
   file no verb can remove. A boundary must never be reachable only through a
   state the kernel itself calls fine. This is not a weakening: the driver
   adds `envelope_validate` on top of the gate's own two tests, so it can only
   ever count FEWER envelopes than the gate — a shortfall still stops the
   pass, and it stops it at `arbitrating`, where `orchid task arbitrate` is
   exactly the verb that settles it.
2. **Deterministic approval** — every required review is valid and current,
   every verdict is `approve`, every review reports `scope_complete: true`,
   and no finding reaches the task's `blocking_severity` (a finding whose
   severity the kernel does not recognize counts as blocking, fail closed).
   → `orchid task arbitrate <id> --result approve --reason "..."`.
   **What the severity gate actually gates:** it reads `findings[]`, which
   only an adapter that populates it can trigger — and the shipped adapters
   are split on that. `plugins/engines/claude/run` asks a `review` reply for
   `FINDING: <low|medium|high>: <title>` lines alongside the `VERDICT:` line
   and parses them into `findings[]`, so for a claude reviewer the gate is
   live (a review that reports nothing still writes `findings: []`, which
   blocks nothing — an engine reporting no findings is a valid review, not
   evidence of a broken gate). `plugins/engines/codex/run` and the other
   shipped `review` adapters still ask for a `VERDICT:` line only and write
   `findings: []` verbatim (`FINDING:` lines are requested by the `critique`
   prompt alone). For those reviewers the `blocking_severity` gate is
   **inert**, and a deterministic approval rests on `verdict` and
   `scope_complete` alone. Check which adapter reviewed before reading a
   clean gate as a second opinion you are already getting.
   **And read the live case the other way round, because it is the one that
   will surprise you:** where `findings[]` IS populated, a **non-empty** one
   blocks an otherwise-approving review. Read the TASK's own
   `blocking_severity` (`orchid task show <id>`) rather than assuming one:
   `medium` is only the fallback the gate applies when the field is absent,
   and the shipped archetypes disagree — `templates/task.md` and
   `templates/task-test.md` ship `high`, `task-migrate`/`task-refactor` ship
   `medium`. On a `medium`-threshold task a single `medium` finding on a
   review whose verdict is `approve` is not "approved with a
   note" — it is arm 3, a `review-conflict` boundary that halts the run for
   arbitration. That is the intended behavior, not a bug to route around:
   the arbiter decides, and `orchid task arbitrate --result approve` settles
   it in one verb. Reviewers habitually approve-with-nits, so the reviewer
   prompt defines the three severities by CONSEQUENCE (`low` = worth saying,
   not worth stopping for) rather than by emphasis — a nit filed as `medium`
   stops a run nobody meant to stop.
3. **Conflict** — anything else: a `request-changes` verdict, a blocking
   finding, mixed verdicts, or a non-scope-complete review. → boundary
   `review-conflict`, **no transition**. Deciding what to do about a real
   disagreement is judgment, and a driver that auto-reworked on it would be
   making exactly the call it is not entitled to make.

**`orchid task arbitrate` is the sole explicit judgment-result verb.**
`orchid task arbitrate <id> --result approve|request-changes --reason "..."
[--waive-attempt]` records an arbitration outcome in one structured shape and
DERIVES the destination from the archetype's declared transitions: an
approval takes `arbitrating:merging` when the archetype declares it, else
`arbitrating:done`; a request-changes takes `arbitrating:rework`. It performs
the move through `task advance`, so every existing gate (reason requirement,
attempt accounting, evidence invalidation, the `arbitration` journal kind)
applies unchanged. `orchid task advance` from `arbitrating` remains legal for
an operator and for the hand-executed walk below — but the driver and the
brokered orchestrator surface only ever use `task arbitrate`, which is what
makes "who decided this, and what did they decide" one greppable fact.

**A finding you approve past is a finding you must record.** Arbitration is
where a run decides that a real defect is out of THIS task's scope — the
right call, often — and the entry that says so is what the NEXT run's
planning cross-check reads back out of the archived journal. Record it as
its own entry, `orchid journal add --task <id> --kind ledger "<what, and
where it actually lives>"`, in the same breath as the approval, and name the
thing precisely: the cross-check associates an item with a task through
distinctive anchor terms (a snake_case identifier, a repo-relative source
path, an `INV-nn`, a lesson id), so `started_at` and `libexec/orchid-task`
earn it a hearing next run where "the budget bug" does not. `ledger` is
admitted on the brokered orchestrator surface for exactly this; the
`plan_deferral` kind that SATISFIES the cross-check is not, and is writable
only by `orchid plan defer` (PLANNING below). A finding that never reaches
the journal is one no future plan can be held to — and that, not the missing
fix, is what cost r-002 a blocked task hours into the run.

## PLANNING (pre-run, before THE TICK ever runs)

Before `run_status` leaves `planning`, there is no active task to walk — this
phase only drafts what the walk will later execute against:

**Greenfield.** For a target repo with no commits yet, PLANNING is preceded
by `orchid init --greenfield` — operator-run, exactly like plain `orchid
init`, outside this loop, before `run_status` exists at all — which mints an
empty root commit so the integration branch has a HEAD to branch from, then
falls through into ordinary `init` unchanged; `orchid doctor --greenfield`
skips the two preflight checks that cannot hold pre-scaffold (a configured
`verify` command; the integration branch already existing). By convention,
the FIRST task drafted in step 2 below is the scaffold task (typically
`T001`): `archetype: feature`, `scaffold: true` (`orchid task set T001
scaffold true`), whose `verification_commands` are structural assertions
(files exist, the manifest parses, the build command exits 0) rather than
product tests that cannot exist until this task creates them — resolving
the bootstrap paradox of testing a test-runner that doesn't exist yet. Every
task after it drafts normally.

**One-command setup (existing repo).** Everything mechanical that precedes
step 1 below — preflight, repo-config validation, `orchid init`, the
integration worktree, the epoch, and the import in step 1 itself — is also
available as a single operator-run command, outside this loop:
`orchid start <requirements-file> [--verify <command>] [--worktree <path>]
[--ack-unattended --reason "..."]`. It is a sequencer over exactly those
verbs and refuses whatever it cannot do safely, printing the exact recovery
command: it never guesses a verification command, never overwrites an
operator file or a directory that is not exactly this repository's
integration checkout, and never resumes or takes over a run — against
existing state it requires `run_status: planning`, no fresh unreleased
lease, no live run/verb lock, and `ORCHID_EPOCH` proving ownership of the
CURRENT epoch (it mints an epoch only where none exists yet, at `0`).
`planning` must hold on every copy that exists, not just the nearest one:
the integration checkout's `.orchid/roadmap.md`, the roadmap COMMITTED on
the integration branch (those two lag each other in opposite directions —
durable state only reaches the branch at `plan apply`/`run accept`, and a
`plan apply` killed between its `update-ref` and its sync-back leaves the
branch ahead of the checkout), and that branch carrying no committed
`.orchid/tasks/`, which only `orchid plan apply` ever puts there. It holds
the per-verb transactional lock across everything it mutates and re-checks
all three underneath it, so the commit below cannot land on a branch whose
run is already in flight and move a candidate's `base_sha`.
A `--verify` command (a single line — `orchid.config` is a line-oriented
`key=value` file, so a value carrying a newline or any other control
character is refused rather than recorded truncated) is appended to the
integration checkout's `orchid.config` and COMMITTED onto the integration
branch by that same command — only when that file (as committed on the
branch, not merely as resolved through the machine-local env/user layers)
configures none yet, and never as a replacement — so setup needs no follow-up
`orchid config commit` and leaves the integration checkout clean. That commit
is whole-file, so append-only holds against the BRANCH and not merely against
the file on disk: a checkout whose `verify=` line differs from the branch's,
or which is missing any other line the branch carries, is refused above the
mutation boundary (naming both ways to reconcile it) rather than committed
over, and an `orchid.config` that `.gitignore` excludes and no commit tracks
is refused there too, since `git add` cannot stage it and setup will not
force it past a rule the operator wrote. Unattended trust stays off unless
both `--ack-unattended` and a non-empty `--reason` are given, which invokes
the machine-local `orchid trust` acknowledgement. Nothing below depends on
it: every verb it calls remains individually callable, and the manual
sequence in
[docs/quickstart.md](./docs/quickstart.md) is unchanged.

1. `orchid requirements import <file>` — snapshot the operator-authored
   requirements into `.orchid/requirements.md` (refused once `run_status`
   has left `planning`: requirements are immutable after a plan exists).
2. Draft the roadmap: create each task with `orchid task create <id>
   <title>`, then fill in its spec via `orchid task set <id> <key> <value>`
   (acceptance criteria, `verification_commands`, `depends_on`, `risk_tier`
   with `--reason`, ...). A task whose deliverable IS a check — a new gate, a
   probe, a lint, a verification command — states its RED case in the
   acceptance criteria, in the Preamble's terms: which failure the check
   detects, and how the suite watches it fire. A task that cannot state one
   has not yet described a check. Include `operator_prerequisite` for any
   task whose verification depends on a step taken OUTSIDE the sandbox —
   canonically a schema task, whose migration must reach the database its
   suite runs against — because PLANNING is the only time it can be set: the
   implementer cannot, its commits may not touch `.orchid/` at all. Left
   empty (the default, and the right answer wherever the suite can migrate
   its own store) it changes nothing; set, it stops the tick at a
   `task-prerequisite` boundary instead of verifying against an environment
   the candidate cannot reach. THE TICK's `testing` step is normative, and
   this applies to every archetype, not only the `migrate` one whose
   template mentions it.

   `.orchid/roadmap.md` itself is the one piece of durable state this
   protocol permits editing directly while still in `planning` — it is only
   *committed* by step 3 below, so drafting it (unlike every mutation THE
   TICK makes) is not yet a fenced, journaled transition.

   If `hook.after_plan_draft` is bound, invoke it now — before the critique
   loop below ever runs — using the shape from the Preamble:
   `runners/orchid-launch plan hook hook --hook after_plan_draft`, then
   `orchid jobs reconcile`. Its artifact is a supplementary signal only; it
   never substitutes for `role.plan_critic`'s own judgment in the loop that
   follows.

   Then actually run the critique loop — the resolved `role.plan_critic`
   engine (never the drafting engine) judges the draft, it is never rubber-
   stamped: `runners/orchid-launch plan plan_critic critique` (the literal
   task id `plan` is reserved for exactly this job — no task file to read,
   no diff to bind, `orchid task create` refuses it as a real id), then
   `orchid jobs reconcile` to land its envelope at
   `.orchid/reviews/plan-a<n>-plan_critic.json`. Read that envelope's
   `findings[]` and fold each one back into the draft (add/adjust tasks,
   specs, sequencing, requirements coverage), then relaunch the same
   critique — a fresh attempt lands at `plan-a<n+1>-plan_critic.json`, the
   same counter-suffix convention any other review uses. Repeat until an
   attempt comes back with nothing left in `findings[]` at or above
   `medium` severity before moving on to step 3.

   If a critique launch exits non-zero *without* printing a `launched` line,
   no engine started and no envelope is coming — do not just re-run it. The
   manifest it stranded makes `jobs prepare` refuse the identical relaunch
   (exit 18) until it is reaped, and a PLANNING pass runs no reconcile and no
   check, so `orchid jobs gc --reap-prepared` is the reap that applies here.
   `runners/orchid-drive` makes that call itself on every planning pass, so
   the refusal clears without intervention; `orchid jobs gc --reap-prepared
   --older-than-s 0` clears it immediately. Fix the launch failure first — the
   launcher's stderr names it.

   *Exit 19 is the one that no reap and no re-run clears.* It means the engine
   bound to `role.plan_critic` does not declare what a `critique` step needs
   (INV-16), and nothing about a later attempt changes that: relaunching it
   loops this step forever. The launcher journals it against the reserved `plan`
   id as it goes, so `orchid journal show --task plan` carries the record, but
   the remedy is an operator's — bind an engine whose manifest covers the step
   at `role.plan_critic`, or perform the critique by hand. Do not fold it into
   the relaunch ladder above.

   *That reap is preceded by an account, and the ordering is the point.* You
   are the one running these launchers — there is no `orchid drive` wrapping
   them in this phase — so nothing reports a launch failure synchronously, and
   a reap that ran first would delete the only trace it left. A planning pass
   therefore sweeps the unlaunched manifests it is about to retire, journals
   each one (with the escalation ladder's own receipt, so a failure is written
   down exactly once however many passes meet it), spends a rung against the
   task where there is one, and only then reaps. The reserved `plan` id has no
   task file and so no `infra_failures` counter to spend; its failures are
   journaled and readable with `orchid journal show --task plan`. The pass
   never *relaunches* in this phase — deciding what to run next is yours.

   **The carry-forward cross-check.** A run does not start from nothing:
   `orchid run new` archived the previous run's journal under
   `.orchid/runs/<prev>/` and carried its ACTIVE lessons into
   `.orchid/lessons.md`. `orchid plan crosscheck` reports which of those
   carried-forward items no task in the current draft appears to consider,
   and exits 3 while any remains unconsidered. Two kinds count: **ledger
   items** — entries in that archived journal recorded with the `ledger`
   kind, or naming themselves a carried finding in prose, which is how every
   pre-`ledger`-kind run wrote them — and **active lessons** carried across
   the rollover. A lesson written during THIS run's own planning is neither:
   nothing is carried forward out of the run you are still scoping, so it is
   skipped. One dated at the rollover boundary itself is included, because
   both timestamps are second-resolution and a tie resolves toward asking
   the question. Run it here, inside the critique loop, where the plan is
   still cheap to change; step 3 runs it again and REFUSES on the same
   condition, so it is not a report anyone can skip.

   *Which prose spellings count, and why it is a list rather than the word.*
   The pre-`ledger`-kind spellings recognized are the noun compounds
   `ledger item` and `ledger candidate`, the phrase `deferred ledger`, and
   `the ledger` after a preposition — `for the ledger`, `worth the ledger`,
   `to the ledger`, `in`/`into`/`on`/`onto the ledger`. The bare word is
   deliberately NOT one of them, because a journal uses "ledger" for the
   ENGINE HEALTH ledger too ("remains ledger-disqualified after three
   exhausted-credit failures", "the one-hour ledger backoff has elapsed"),
   and those entries record no finding at all: matching the word would open
   every `plan apply` with a dozen items nobody can cover or act on, and a
   refusal cleared by rote is a refusal that has stopped being read. If you
   are recording a finding you knowingly are not closing, the reliable thing
   to write is `orchid journal add --kind ledger` — the prose list exists for
   journals written before that kind did, not as the supported way to say it.

   **The unit is the FINDING, not the journal entry.** A single arbitration
   entry routinely records several unrelated defects — "carried as ledger
   items: (1) … (2) … (3) … (4) …" — and tracking those per entry would let
   one task naming one of them close the entry and carry the rest out of
   planning under a green `covered` line. So an entry written as an
   ascending `(1) `/`(2) `/… enumeration is split on those markers into
   findings that are covered and deferred one at a time, with ids
   `<run>#<n>.<k>`; each is matched only against its own segment, never
   against the shared preamble, whose terms would otherwise cover all of
   them at once. The enumeration has to be a WHOLE one: every ordinal it
   uses appearing exactly once, and no higher ordinal appearing at all, so
   that a scrambled (`1, 3, 2`), gapped (`1, 2, 4`) or repeated list is not
   split on the tidy prefix an ascending scan happens to reach — the
   findings past the break would sit inside a segment attributed to a
   neighbour, closeable by anything that matched it and never named on a
   line of their own. An entry that announces SEVERAL findings — the plural
   "ledger items"/"ledger candidates", or a count like "the four outstanding
   findings" — but does not enumerate them, or enumerates fewer than it
   states, cannot be split without guessing either. Any of these is reported
   as one UNDECOMPOSED item that no task text can ever close: schedule its
   findings and then `orchid plan defer` the entry, saying what you
   scheduled. The operator states that these were considered; the check
   never infers it from a keyword that happened to land in the same
   paragraph.

   Coverage is deliberately approximate and deliberately pessimistic: an
   item is associated with a task only through a distinctive anchor term (a
   snake_case identifier, a repo-relative source path, an `INV-nn`, a lesson
   id) appearing in that task's **body**, or in the frontmatter fields that
   carry an author's intent — `title`, `acceptance_criteria`,
   `stop_condition`, `hook_guidance`, `resources`. Never through ordinary
   prose; never through a frontmatter KEY, since every task file carries
   `started_at:` and its siblings; and never through the MECHANICAL
   frontmatter values, `verification_commands` above all — those are
   boilerplate every task repeats, so a path inside one is a universal
   anchor, and a task that merely runs the suite has not thereby considered
   a finding about the suite. The question being asked is "did anyone look
   at this?", not "is this scheduled correctly": no text match can answer
   the second, and a spurious *covered* costs far more than a spurious
   *uncovered*. Because it is approximate, every `covered` line names the
   anchor that earned it — `covered [ledger] r-001#57 — … (task T010 via
   started_at)` — so an incidental association can be spotted and turned
   into a real task or a deferral instead of being taken on trust.

   Where the honest answer is "not this run", record it:
   `orchid plan defer <item-id> --reason "..."` journals the decision (kind
   `plan_deferral`) and satisfies the check for that one item. It refuses an
   id that is not on the carried-forward list and refuses to re-defer, but it
   carries no `run_status` precondition: a plan can be revised after
   `planning` (step 3), so an item can be uncovered after `planning`, so the
   decision that answers for one has to be recordable then too. Once the run
   is moving, a task is still the better answer than a deferral — that is
   advice, not a refusal. There is no bulk override: a deferral names
   one item and says why. What satisfies the check is an entry of that
   KIND, not a line of that shape: `plan_deferral` is writable only by this
   verb and is refused on the brokered orchestrator surface, so a `note`
   (which is admitted there) reading `deferred <id>: …` counts for nothing
   and the item stays uncovered. And it is a decision about ONE plan, not a
   permanent silencing: `plan_deferral` is itself a ledger kind, so an item
   deferred last run reappears in the next run's cross-check and needs
   either a task or a fresh reason. An indefinitely postponed defect is
   allowed to be indefinitely postponed; it is not allowed to disappear.

   Both empty outcomes are STATED rather than passed over: a repository
   whose first run has never rolled over, and a previous run that left
   nothing. An unrun check and an empty one look identical otherwise, and
   that is the failure this exists to prevent — r-002's requirements omitted
   a defect r-001 had already found, recorded and journaled (the once-only
   `started_at` anchor), with eighteen active lessons and the entire
   previous journal available while scoping. The information existed and
   nothing forced its use.

   And a third outcome is neither of those: **the question could not be
   answered at all**, which exits 4 and refuses. Which run this plan carries
   from is read from the roadmap's own `run_id` — the previous run is
   `r-NNN` minus one — and that run's archive must be present under
   `.orchid/runs/` with its `journal.md` inside it. When it is not, or when
   `run_id` names no run, or when an archive at or above the current run id
   contradicts it, the two item generators return the empty list — which is
   byte-for-byte the list a run that left nothing produces. Reported as
   "nothing to cross-check" it committed a plan over every finding in an
   unread record, so it is refused instead, naming what could not be read.
   The repair is to restore that record (it is durable state on the
   integration branch: `git log --oneline -- .orchid/runs`), not to cover or
   defer anything — neither remedy applies to an item the check was never
   able to list.

   A fourth outcome is the same distinction drawn about the check's own
   workspace: it builds its lists in a scratch directory under `TMPDIR`, and
   when it cannot create one it exits **5** and refuses. Nothing is wrong
   with `.orchid/` in that state — the archive is intact and the items are
   all still in it — which is exactly why an empty report there was the
   worst version of this: an unusable `TMPDIR` (one that does not exist, a
   full or read-only `/tmp`, a sandbox exporting a directory it never
   created) produced no list, and a report with no list said the plan had
   been considered. The repair is a writable temporary directory, so it gets
   a code of its own too: restoring an archive that was never missing would
   teach an operator nothing.
3. `orchid plan apply --reason "..."` — commits every current `.orchid/`
   change (roadmap, tasks, requirements) onto the integration branch in one
   transaction, from whatever checkout you're in, without ever switching the
   operator's branch; journals `plan_revision`; advances `run_status:
   planning → running` once a plan actually exists. It re-runs the
   carry-forward cross-check above first and refuses (exit 3, nothing
   committed, nothing journaled, the integration branch unmoved, the verb
   lock released) as long as any carried item is neither covered by a task
   nor explicitly deferred.

   That refusal is on the VERB, in every `run_status` — not only while the
   run is still `planning`. `plan apply` revises a committed plan too, so
   scoping the refusal to `planning` meant the one edit that can UNCOVER an
   item mid-run — a revision deleting the task that named it — committed
   with a printed warning and exit 0. The remedy is what makes that
   enforceable rather than a trap: `orchid plan defer` carries no
   `run_status` precondition, so at every refusal both ways out are open —
   cover the item with a task in the plan being applied, or record the
   decision not to.

   **The gate is on leaving `planning` as well as on this verb.** `orchid
   run advance` can take a run out of `planning` too, so it applies the same
   cross-check on every edge out of that status (`→ running` and `→ blocked`
   alike, since `blocked → running` is legal after it) and refuses on the
   same condition, before journaling or writing anything. Otherwise `run
   advance running` followed by `plan apply` would commit exactly the plan
   the refusal above exists to stop, with every carried item leaving
   planning unrecorded — a gate that can be stepped around by reordering two
   verbs is not enforcing anything. Both remedies are open at that refusal
   (the run is still in `planning`), so it strands nothing; mid-run edges
   are untouched.

Once `run_status: running`, PLANNING is over — THE TICK below is the only
procedure that touches task state from here on.

**Repo-config changes (`orchid.config`) and stale-checkout hygiene.** Never
hand-commit `orchid.config` from a checkout of the integration branch (or a
worktree of it) directly — use `orchid config commit --reason "..."`
instead. It stages exactly `orchid.config`'s current on-disk content into a
separate temp worktree of the integration branch and commits it there
(journaling `intervention`), never touching this checkout's own git index —
closing a real incident: a long-lived integration-branch checkout whose ref
gets advanced from OUTSIDE it (another worktree's commit, a pump-driven
`plan apply`/`run accept`) falls behind its own branch pointer without its
index/working tree ever refreshing (`orchid doctor`/`orchid status` detect
this and call it out by name). A naive `git add -A && git commit` in that
state silently re-commits whatever stray staged deletions the stale index
still carries, reverting real history. If you do need to refresh such a
checkout by hand for some other reason, it takes **both** commands, in this
order: `git checkout HEAD -- . ':(exclude).orchid'` and then a bare `git
reset`. The checkout refreshes the working tree without touching run state;
the reset brings the INDEX to `HEAD` for the `.orchid/` paths that pathspec
excludes, and that is what actually clears the warning — the checkout alone
leaves their staged deletions behind, so `doctor`/`status` go on reporting
stale (dogfood finding F31). The reset writes no file, so nothing on disk is
lost to it. Never a bare `git checkout HEAD -- .`, which clobbers
uncommitted `.orchid/` run state — and note that the exclude protects run
state *only*: the checkout still overwrites any uncommitted edit of your own
outside `.orchid/` (a `requirements.md` at the repository root is the one
that has actually been lost this way), so commit or stash those first.
One thing to check before running that verb, when orchid runs from the
checkout you are editing in: a merge that landed a change to `orchid.config`
will have brought this copy to it — but only if you had no pending edit here,
and it warns on stderr when you did and it therefore left yours alone. In that
second case your file does not yet carry what the branch just landed, and
`orchid config commit` commits the bytes on disk, so committing before you
reconcile the two drops the merge's change. `docs/troubleshooting.md`,
"`orchid.config` after a merge", has the comparison to run.

## THE TICK

**1. Refresh the lease.**
`orchid run refresh-lease` — first thing, every pass, so nothing watching
this run ever mistakes an in-progress tick for a stalled one.

**2. Reconcile, check, then gc (reconcile-first, check-before-reap ordering).**
`orchid jobs reconcile` drains everything already finished or quarantinable
into `.orchid/reviews/` *before* anything gets judged as stuck — a job that
completed since the last pass must never be mistaken for a dead one. Then
`orchid jobs check` reports
`never-started|prepared|unstamped|running|dead|stalled|timeout|budget-exceeded`
for whatever reconcile left outstanding (`stalled`/`timeout` jobs are killed
by `jobs check` itself as it reports them; `budget-exceeded` is report-only,
see below) — running `check` here, before anything reaps a manifest, is what
lets a job that died envelope-less between ticks (SIGKILL/OOM/adapter crash
before it ever wrote a spool envelope) still get reported `dead` and walk the
escalation ladder below, instead of being reaped silently before `check` ever
sees it. Only THEN `orchid jobs gc --older-than-s 0 --prepared-older-than-s
<stall_minutes>` — reaps manifests whose pid is *already* dead (never kills
anything live; the `0` just drops gc's normal age bound), plus the *unlaunched*
ones: `pid: 0` **and no log file** (never started), or `pid: 0` with a log
nothing has written to in `stall_minutes` (spawned, never stamped a pid, then
silent). Both bounds are the CALLER's and both are taken literally — an
operator's `orchid jobs gc --older-than-s 0` honours zero on every class. The
driver passes the second bound because *it* cannot know whether a manifest
seconds old belongs to a launcher sitting between its own `jobs prepare` and
its spawn line right now. This clears out whatever `check` just finished handling
(including the envelope-less case above), so a *later* pass never re-reports
the *same* already-dead job as `dead` and triggers a second, false escalation
for a failure this run already handled. gc runs strictly AFTER check has had
its pass over the same manifests, precisely so a dead job is reported and
escalated before it is ever reaped — reversing this order (gc before check)
lets gc silently vanish a job before `check` can ever call it `dead`, so the
escalation ladder's "first occurrence → relaunch" never fires and the
wallclock backstop (which only runs inside the manifest loop) goes silent
too — the task simply waits forever.

For the same reason the reap runs after `check`, it also runs **after the
escalation ladder below has spent its rungs**, not before: a manifest is the
only durable trace a failed job leaves, so a pass felled between the reap and
the charge would have destroyed the evidence of a failure it never counted, with
nothing left for any later pass to find. *Nothing is retired before it has been
accounted for.* The one visible consequence is that the ladder's relaunch of a
`never-started` job is refused (exit 18) while its orphan is still on disk and
lands on the following pass instead; the dispatch walk, which runs after the
reap, is unaffected.

**`stalled` is decided on PROGRESS, not just on liveness.** A job earns it two
ways, and both kill it: its log has not been written to for `stall_minutes`
(the original test), OR — when an operator has opted in by setting
`cpu_stall_min_s` (config, default `0`: off) above zero — its own heartbeat
lines show it burning less than that many CPU-seconds across the last
`stall_minutes` of heartbeats. The second exists because the first cannot see
a job that keeps heartbeating and stops working — a real attempt sent
heartbeats for five minutes while accumulating two tenths of a second of CPU
and then exited with nothing, and `jobs check` called it `running` the whole
time, because *the process was alive*. The CPU numbers were already in the
log: every heartbeat line carries a `cpu` field for exactly this consumer.
The arm is opt-in because the same incident report later retracted CPU as a
sole progress signal: an engine blocked on a vendor API legitimately burns
almost none — a healthy job was observed at ~9 CPU-seconds across 40 minutes,
indistinguishable on CPU alone from the dead one — and killing a working
engine discards work already paid for. A job without enough heartbeat history
to span the window is never judged by it, and a heartbeat CPU counter that
goes backwards (pid reuse hands `ps` a stranger's clock) is unknown, never a
stall.

**A job that exits without an envelope is a first-class failure, never a job
that never happened.** `orchid jobs reconcile` makes a second pass, after the
spool drain, over every manifest whose pid is gone with no envelope of its own
anywhere, and for each one:

- **Salvages what the engine already produced.** If the job's log holds
  results in the shape its adapter would have parsed — `FINDING:
  <low|medium|high>: <title>` lines, a whole-line `VERDICT:
  approve|request-changes` — they are filed as a DEGRADED envelope at the
  ordinary `reviews/<task>-a<n>-<role>.json` path with `status: no_envelope`,
  `degraded: true`, the exit code, and the log it came from. The engine has
  already been paid for that work; a degraded envelope an operator can read
  beats re-running an expensive critique to regenerate findings orchid
  already has on disk. **No gate counts one as evidence** — `no_envelope` is
  not `ok`, so review sufficiency, the arbitration gate, hook satisfaction and
  hook envelope counting all skip it exactly as they skip a `failed` one. A
  job whose log holds nothing parseable files NOTHING: an envelope is never
  manufactured for a handler that exited quietly having produced nothing.
- **Journals the exit code and the tail of the log**, always, whether or not
  anything was salvaged, so the failure is visible to an operator who does not
  know to go grepping `runtime/logs`.
- **Prints a `<task>	no_envelope	<detail>` line**, always. reconcile
  printing nothing at all is precisely what made this class of failure
  indistinguishable from a job that was never dispatched.

The manifest is left in place (stamped, so a second `reconcile` in the same
pass repeats none of the above) rather than deleted, so the escalation sweep
below still sees the death and still spends its rung; `jobs gc` reaps it a
step later in the same pass as always. `status: no_envelope` is the one
envelope status the kernel alone writes — an adapter that files one in the
spool has its envelope quarantined (`kernel-status`), never accepted.

The one job this ordering cannot resolve in the pass that observes it is the
one that exits *between* reconcile and the reap: dead here, with its envelope
written and not yet drained. It has DELIVERED, and neither half of this step
may treat it as a death. `jobs gc` therefore holds back (`gc-pending`) any
manifest whose `<runtime>/spool/<job_id>.json` still exists — reaping it would
destroy the delivery outright, since reconcile matches an envelope to its job
*through* the manifest and the next pass would quarantine that envelope as
`unknown-job` — and the driver's escalation sweep skips the same manifest for
the same reason: a rung spent there is a rung spent on work that arrived, and
it relaunches a second engine into the worktree over it. The job reads as
outstanding for one more pass and resolves on the next.

**The operator's view of the same state: `orchid jobs ls`.** `jobs check` is
the machine surface this step is specified against, and its `<task-id>
<state>` pairs are exactly enough to walk the ladder below and nothing like
enough to answer "which of these two jobs is which, and do I intervene". `jobs
ls` (also `orchid status --jobs`, and a Jobs section on the static page)
renders one row per outstanding job — job id, task, role, operation, attempt,
engine, pid, state, age, elapsed, percentage of `wallclock_budget_s` consumed,
who launched it, and its log path. It computes liveness with the same
predicates as `check` rather than believing the manifest: `pid: 0` with no log
reads `never-started`, with a fresh log reads `prepared`, and with a log silent
past `stall_minutes` reads `unstamped`; a stamped job whose process is gone
reads `dead`, and the hold-back case above reads `delivered`. It is read-only and kills nothing (the
stall/timeout kill stays `check`'s alone), so it is safe to run from a second
terminal mid-pass; `--watch` polls it, `--all` adds jobs that have already
finished. The two conditions that mean nothing is happening — a job dead with
no envelope, and a job silent past `stall_minutes` — additionally print a
`WARNING:` line on stderr, which `orchid status` shows in every mode with no
flag asked for: a run whose only in-flight job died is precisely the run where
nobody thinks to go looking at a table.

Escalation ladder for a job `jobs check` reports `dead`, `stalled`, `timeout`,
`never-started` or `unstamped` that reconcile above did **not** just resolve:

- *First occurrence for this attempt:* relaunch — re-run `runners/orchid-launch
  <task-id> <role> <operation>` for the same task/role/operation. This is the
  kernel's "one auto-retry"; it mints a fresh job identity and does not touch
  the task's `attempts` counter, nor `infra_failures`, at all.
- *Second consecutive occurrence:* `orchid task infra-fail <task-id>
  --reason "job <job_id> <status> after one retry"` — the dedicated
  kernel-owned path that increments `infra_failures` (the general `task set`
  deny-list blocks writing it any other way) and journals its own
  `intervention` entry, so no separate `notify`/`journal add` call is needed
  for this step. When the resulting count reaches `infra_max` (config,
  default 3), the verb auto-advances the task to `blocked` itself (reason
  "infra_failures cap reached", printed) — `blocked` is legal from any
  status, which matters here since neither `implementing` nor `reviewing`
  has a legal `rework` edge. An operator resolves it with `orchid task retry
  <task-id> --reason "..."` once the underlying infra issue is fixed —
  `retry` moves `blocked→rework` without consuming an attempt, writes the
  reason into the task body (where the implementer's own capsule carries it,
  not the journal alone), grants the task a round when its budget is spent,
  and takes `--attempts N` when it needs more than one. When the infra issue
  was the ONLY
  thing wrong and the candidate itself is fine, prefer `orchid task reverify
  <task-id> --reason "..."`: it returns the task straight to `testing` for a
  fresh verification run, with no implementation pass and no attempt spent.
- *Recurring across attempts, and it looks like REPO behavior, not vendor
  noise:* the same dead/stalled/timeout signature repeating for a task
  across attempts — a flaky test, a flaky build step, anything the repo
  itself does inconsistently — is a lesson-birth moment (docs/specs/
  kernel.md, Cross-run lessons; never a vendor-availability blip, which
  belongs in the ledger's `rate_limited`/`failing` tracking above, not
  here): `orchid lessons add --scope repo --invalidate-when "..." "..."`
  before continuing the ladder.
- *`budget-exceeded`* (independent of the ladder above — it can fire
  alongside `running`, not just `dead`/`stalled`/`timeout`): the task's
  `wallclock_budget_s`, anchored at `started_at`, has been exceeded.
  **`started_at` is re-stamped on every dispatch** — `task advance
  <task-id> implementing` (or whatever active status the archetype
  dispatches into) out of `pending` or `rework` — so the budget bounds the
  CURRENT attempt, not calendar time since the task was first ever
  dispatched. Time a task spends waiting between attempts is therefore not
  charged to it: operator downtime, debugging and overnight idling do not
  spend a budget meant to catch a runaway attempt. The intra-attempt edges
  (`implementing -> testing -> reviewing -> ...`) do NOT re-anchor it — one
  attempt, one clock.
  Reported once per task per pass, and only while the task is in an active
  status. A task sitting in `rework` or `blocked` has no attempt running and
  is never reported, so `orchid task unblock`/`orchid task retry` need no
  separate re-anchoring step: the dispatch that follows re-stamps the anchor
  before the attempt it bounds begins. It IS still reported for a task whose
  job is alive, deliberately — with a per-attempt anchor, an active task
  past its budget is precisely the runaway attempt this backstop exists to
  catch, and a version that fired only for already-dead jobs would be no
  backstop at all. `jobs check` only reports this, it never kills on its
  own. `orchid notify --task <task-id> "task wallclock budget exceeded"`
  then `orchid task advance <task-id> blocked --reason "wallclock budget
  exceeded"`.
- *A launch that FAILS is a job failure too.* `runners/orchid-launch` does
  real work before it spawns: it prepares the job, then builds the input
  pack. A non-zero exit from it — anything but `14` (`no eligible engine`,
  the WAIT above), `18` (`this slot already has an unlaunched manifest`,
  below), and `19` (`step not routable`, handed to an operator below) — means
  no engine started, so there is nothing for `jobs check` to
  call `dead`, no envelope for `reconcile` to mark the engine with, and no
  reason to expect one later. Treat it exactly like a dead job: journal it and
  walk this ladder (`orchid task infra-fail <task-id> --reason "the launcher
  exited <rc> without spawning a job"`), leaving the task in the status it
  already held. The failure mode this closes is a real one — an
  `input_overflow` pack made every launch fail, and the same dispatch was
  re-attempted once per pass for 73 passes with no journal entry, no
  escalation and no engine ever marked.

  **Count it once — and never zero.** Two arms can charge one stranded launch:
  the driver's synchronous one, with the launcher's exit status in hand, and its
  ageing sweep, some passes later, reading the manifest that launch left behind.
  They deduplicate on the **job\_id of that manifest**, and the receipt is the
  journal entry the charge itself wrote: `orchid task infra-fail` is
  journal-first, so a reason carrying `[ladder job <job_id>]` is durable proof that this
  job was already counted, and a charge whose receipt is already on record is
  refused. Charged synchronously → the sweep finds the receipt and skips.
  Crashed before the charge → no receipt, and the sweep is the one that counts
  it. A mark on the manifest cannot do this job: the launcher writes
  `launch_exit` *before* the driver has journaled anything, so a pass felled in
  that window would leave a manifest claiming a failure was reported that never
  was, and a sweep keyed on the mark would skip it forever. `launch_exit` is
  therefore kept for what it actually proves — *why* the manifest was stranded,
  which is what the sweep puts in the journal when it is the one to charge — and
  never for whether the failure was counted. The reap is what finally retires the
  manifest, and it runs **after** the ladder in the same pass, so nothing is ever
  thrown away before it has been accounted for.
- *`never-started`* — a `pid: 0` manifest with no log at all, i.e. a job that
  was minted and whose launcher died before its spawn line. Nothing about it
  is `dead`/`stalled`/`timeout`, so it needs naming separately: no envelope is
  coming, and the same ladder applies once the manifest is older than
  `stall_minutes` (younger than that, a launcher may still be mid-flight over
  it — leave it alone). An unattended `orchid jobs gc` reaps it under that
  same bound, after which the identical dispatch simply succeeds.
- *`unstamped`* — a `pid: 0` manifest **with** a log that nothing has written
  to in `stall_minutes`. The launcher creates the log by redirecting the spawn
  into it and stamps the pid only on the line after, so this is a spawn whose
  pid was recorded nowhere: an engine may be running and no signal can reach
  it. While that log is still being written the driver **waits** on the
  manifest — it is a live job, and launching a second engine over it puts two
  into one worktree. Once the log goes silent for as long as `jobs check`
  would kill a stamped job over, it walks this ladder once and `orchid jobs gc`
  retires the manifest — **keeping the log**, which is the only surviving
  record of whatever was spawned.
- A `gc <job_id>` reap line printed this pass for a job whose task is still
  mid-flight (not `done`/`blocked`) is itself a signal to re-examine that
  task, not something to scroll past: with gc now running strictly after
  `check`, every legitimately-handled dead job was already reported and
  escalated above in this same pass — a reap line next to a task that is
  still mid-flight and was *not* just escalated means something reaped a
  manifest `check` didn't account for, which is worth a manual look before
  the next tick.

**Failover: the ledger, not the task, absorbs a bad engine.** Every envelope
`jobs reconcile` above just accepted or quarantined feeds `ledger_mark`,
which updates that ONE engine's record in `runtime/engines.json`
(`orchid status`'s `== engines` section reads it back): `rate_limited` opens
a `rate_limited_until` window (`rate_limit_backoff_s`, config, default
3600s, or the envelope's own `retry_after` when it names one); any other
non-`ok` status (`failed`, `timeout`, `auth`, `malformed`) increments that
engine's `consecutive_failures`, which flips it to `failing` once it reaches
`engine_fail_threshold` (config, default 3) — automatically, on every
reconcile pass, no separate verb call needed. ONE EXCEPTION, and it is not a
loophole: an envelope carrying `failure_kind: "capability"` is a REFUSAL, not
a fault — the adapter declining an operation it never claimed or a diff over
its own inline byte cap (`agy_max_bytes`) — and it increments nothing. Such an
engine keeps its `status`, keeps its place in every role chain, and shows up
in `orchid status` as `refusals <n>`, with one `refusal: <task> <engine>
declined by design` line printed by the reconcile pass that accepted it. Read
those lines as ROUTING information, never as engine health: they say this
engine cannot do this particular job, so if they keep appearing for the same
role, the fix is a worktree-capable engine on that chain (or a bigger cap),
not a healthier engine. Measured on r-002, before the distinction existed:
three refusals of diffs ~1% over the cap marked a well-behaved reviewer
`failing`, halved the run's independent reviewer pool, and stranded a task
whose review had already been filed. This is the OTHER half of
`docs/specs/kernel.md`'s "repeated infra failures → engine marked
unavailable" guardrail (`orchid task infra-fail` above is the task-scoped
counter half); it is no longer aspirational. Every launch attempt —
`jobs prepare` for the implementer, for each reviewer slot, and the headless
tick's own orchestrator pick — resolves its role through
`resolve_role_available`, which walks that role's failover chain and skips
any engine the ledger currently disqualifies (rate-limited, or failing) in
favor of the next entry (a non-primary entry also needs its capability
suite passed — `orchid plugins test <engine> <role>` — before it may
activate at all). No survivor in the chain → the call exits 14 (`no eligible
engine`), printing exactly which entries were skipped and why. This
protocol's response to exit 14 is uniform regardless of which launch hit it:
the task simply WAITS — leave it in whatever status it already held
(`pending`/`rework` for a dispatch that never got to `implementing`; the
current status for a mid-attempt reviewer-slot launch) rather than treating
the exit as a tick failure — and consult `orchid status`'s `== engines`
section on the next pass to see when the window reopens. A rate limit
pauses an engine, never work: once the window closes (or the failing streak
is broken by an unrelated `ok`), the identical dispatch call simply succeeds
on a later tick, with no operator action required.

**3. State-machine walk.**
Operate on every active task (up to `concurrency` of them, per the Preamble)
and every task that is ready to dispatch — never just one. `orchid status
--explain` names *why* each task is or isn't moving (`waiting-deps`,
`ready-to-dispatch`, `awaiting-implementer-envelope`,
`awaiting-operator-handoff`, `awaiting-verify`,
`awaiting-review-envelopes`, `awaiting-arbitration`, `awaiting-merge`,
`awaiting-rework-dispatch`, `awaiting-operator-prerequisite (orchid task
prereq-ack <id>)` — reported from `testing` and from `merging` alike, since
both stages refuse on it — `blocked (see: ...)`) — use it to pick up where
the run left off rather than re-deriving state by hand. A task in `testing`
held by both operator-owned stops reports the hand-off, which is the one to
take first: acknowledging it advances `candidate_sha`, and that expires a
prerequisite acknowledgement made before it.

```
pending → implementing → testing → reviewing → arbitrating → merging → done
                ↑            │         │            │
                └── rework (≤N) ───────┴────────────┤
                                                    └→ blocked
        rework ──┐                    blocked ──┐
                 └→ testing (reverify)          └→ testing (reverify)
```

N is `rework_max` (config, default 3), unless an operator has granted this
one task a larger `attempt_budget` with `orchid task retry --attempts N`.
The two `reverify` edges consume no attempt — they re-run verification
against a candidate the operator has already fixed, instead of buying a
fresh implementation pass to reach the same tree. Both are gated identically
wherever they are taken from (the verb, or a bare `task advance <id>
testing`, which reaches the same declared edge): a reason is required, the
task worktree must be clean, and `candidate_sha` must already be that
worktree's HEAD. Step **4. Blockers** below has the operator's side of it.

This is the `feature` archetype's walk — the only shape this file spells
out in prose. Every archetype declares its own transition subset
(`plugins/archetypes/<name>/plugin.conf`'s `transitions=`, validated at
`task create`/`task advance` time against kernel invariants), so the walk
below is `feature`'s superset, not a kernel-fixed shape. The shipped
`review` archetype (`outcome=report`), for example, walks `pending →
reviewing → arbitrating → done`, with `arbitrating → rework → reviewing` on
rejection — no `implementing`, `testing`, or `merging` at all, and `orchid
merge` refuses it outright (exit 3) rather than ever being reached. Apply
the bullets below that this task's actual transitions call for; skip the
ones its archetype never declares.

- **pending** (`ready-to-dispatch`: every `depends_on` entry is `done` AND
  none of `schedule_dispatch_blockers`' predicates hold — `orchid status
  --explain` already reflects this same gate; step 3 below enforces it
  again, fail-closed, in case something changed between reading status and
  dispatching, e.g. a second task racing the same `concurrency` cap):
  1. Create the task's worktree — `git worktree add <path> -b <branch>
     <integration-branch HEAD>`, using the task's recorded `branch` — then
     record it: `orchid task set <id> worktree <path>`. `worktree add`
     reproduces only what git TRACKS, so any gitignored build state the
     integration checkout carries (`node_modules`, `vendor`, `.venv`, a
     symlink into a sibling checkout) is simply absent from the new
     checkout, and the task's first `orchid verify` there fails on missing
     dependencies rather than on anything the implementer wrote (lesson
     L003). **Provision such state in the new worktree before dispatching** —
     that is the fix, and the classifier is only the backstop: a failure that
     round is classified `environment` and does NOT consume an attempt, but it
     still costs `infra_failures` and still costs the round.
  2. Record the base: `orchid task set <id> base_sha <integration-branch
     HEAD sha>`.
  3. `orchid task advance <id> implementing --reason "dispatching: deps
     satisfied"`.
  4. `runners/orchid-launch <id> implementer implement` — this is the ONLY
     call made here. The launcher performs `orchid jobs prepare <id>
     implementer implement` itself, as its own first (tier-1) step, before
     it ever spawns anything. Calling `orchid jobs prepare` a second time
     beforehand would mint an orphaned manifest with `pid: 0` that never
     gets used — and the launcher's own prepare then REFUSES (exit 18,
     `already has an unlaunched manifest`), because a second manifest for a
     slot that already has an unlaunched one cannot make the first one run.
     `orchid jobs prepare` is named in this protocol only to say: it happens,
     inside the launcher, and needs no separate invocation.

- **implementing** (`awaiting-implementer-envelope`): once step 2's reconcile
  reports this task's job `ok` (operation `implement`):
  1. **Read no envelope at all while an implement job for this task is still
     outstanding.** Reconcile deletes a job's manifest in the same step that
     files its envelope, so a live job has filed nothing: any envelope on disk
     is one an earlier dispatch left, and that dispatch's replacement is being
     written right now. Defer the whole arm — it neither counts as a fresh
     failure (the ladder would spend a rung per tick on one event, and spawn a
     second implementer into the worktree the first is still committing to) nor
     as an acceptance (the live job is MOVING that worktree, so the stale
     envelope can pass the HEAD check below on the strength of a commit it
     never made).
  2. `git -C <worktree> rev-parse HEAD` to read the new candidate.
  3. **An `ok` envelope is not evidence that work happened — check the
     worktree before advancing.** A dispatch can return `ok` with a summary
     that is pure commentary (the findings it was handed, restated; its
     sources, listed) over a worktree whose HEAD never moved and whose tree is
     clean. Compare the sha just read against the task's existing
     `candidate_sha` — or, on a first dispatch, which has none yet, against its
     `base_sha`, where an unmoved HEAD means the attempt produced no commit at
     all. If it has not moved, read the tree's state before charging anything
     (`git status --porcelain`, `.orchid/` excluded, being no part of any
     candidate — the same read the hand-off below makes), and ask of the task's
     own two shas whether a candidate EXISTS at all: an unmoved HEAD is three
     different situations, and only two of them are delivery failures.

     **The tree is CLEAN and the floor was the `base_sha`.** The dispatch left
     no commit and no edit, and no earlier one did either: this task has
     produced nothing anywhere. The envelope is NOT an acceptable envelope —
     take no transition. Hand it to step 2's escalation ladder exactly as a
     quarantined or non-ok envelope is handed to it — same ladder, same rung,
     no second count. The reason names both shas, and the journal entry is the
     whole record of the refusal: `orchid task infra-fail <id> --reason
     "implement envelope reported ok but delivered nothing: worktree HEAD <sha>
     is unchanged from the task's recorded <sha>"`, relaunch the implementer,
     and leave the task in `implementing`. This is deliberately the
     `infra_failures` counter and not `attempts`: the attempt budget bounds
     defects in work that was actually delivered, and charging it here would
     spend a rework round on a candidate nobody touched — while advancing would
     spend a full verify and a full review round re-proving a defect this run
     already arbitrated.

     **The tree is CLEAN and the floor was a `candidate_sha` ahead of the
     `base_sha`.** A candidate demonstrably exists — the driver stamped that sha
     itself, from a HEAD it read in this worktree, and the worktree still agrees
     — and this round added no commit on top of it. That is a routing question,
     not a delivery failure, and it must not spend the job-delivery ladder,
     whose recovery is a relaunch: there is nothing here to relaunch FOR.
     ADVANCE on the existing candidate, mark no envelope refused, charge
     nothing, and journal which of the two clean cases this was and why. It is
     produced by ordinary operation rather than only by a lazy engine: a rebase
     rewrites a task's commits, the driver re-stamps the new HEAD as
     `candidate_sha`, the next round dispatches, and the implementer truthfully
     reports that the work asked of it is already in place. Every run with
     concurrency above one rebases in-flight tasks onto a moved integration
     branch, so every such run reaches this, and refusing it blocks a task whose
     candidate is sitting right there (lesson L039). Advancing is bounded by the
     ordinary route: an engine that keeps adding nothing to a candidate that
     keeps failing verification spends the ATTEMPT budget, the budget for
     defects in work that WAS delivered, and reaches a human at its cap. Both
     shas must be on record for this case — with the base missing, nothing
     proves a candidate exists and the refusal above stands. Ancestry is
     deliberately NOT required: the rebase that triggers this can leave the
     recorded base off the candidate's line of descent, and demanding descent
     would re-block the case this exists to route.

     **The tree is DIRTY.** The dispatch did the work and failed to commit it,
     which is not the same failure and must not take the same rung: the
     ladder's recovery is a relaunch, and a relaunch into that worktree hands
     the next dispatch a tree it did not create and cannot account for — it
     will commit those edits as its own, revert them, or build on top of them,
     and the journal will read whichever it does as the work of a round that
     never wrote them. Throwing real output away is not a decision to
     automate. So charge nothing, relaunch nothing, mark nothing refused (step
     4's mark would make the envelope unselectable after the work is committed,
     which is precisely the resolution being asked for), and stop at an
     `operator-decision` boundary that names the observed HEAD, the recorded
     sha and the uncommitted paths. Both answers leave this arm correct on the
     next pass: committed onto the task branch, HEAD is off the floor and the
     envelope is ordinary delivery; discarded, the tree is clean and whichever
     of the two clean cases above applies to that task's shas applies here. A
     tree that cannot be READ at all takes a
     `worktree-conflict` boundary — the same direction, never folded into the
     clean case, since an inspection that answers "clean" when it could not
     look would relaunch over a tree nobody has seen.
  4. **Make that refusal stick**, by appending the refused envelope's basename
     to the task's `refused_envelopes` (`orchid task set`), and never selecting
     a listed envelope again — as an acceptance or as a failure. Reconcile
     removes no envelope, so a refused one sits beside every later sibling, and
     an unmarked refusal is undone twice over: once the relaunch it started
     moves HEAD, the refused envelope passes step 3 (it is no longer a no-op);
     and once a newer NON-ok sibling is filed, the refused one is still the
     newest `ok` envelope and is picked ahead of the failure. Either way the
     work just refused advances to testing by a second door. Escalate first and
     record second: a lost mark costs at most a duplicate rung on a ladder that
     ends at a human, while a lost escalation would leave the task parked in
     `implementing` with no live job and no boundary. The mark is also the
     ladder's only memory of that failure — a non-ok envelope stays readable and
     re-escalates every tick until the cap, a refused one answers nothing at
     all. So a later tick that finds a refusal recorded for the CURRENT attempt
     with no implement job outstanding and no acceptable envelope has a relaunch
     that never landed, not something to wait for: spend a rung and relaunch.
  5. `orchid task set <id> candidate_sha <sha>`.
  6. `orchid task advance <id> testing --reason "implementer envelope ok"` —
     one advance for both roads into it, with the reason naming which road when
     it was the round that added nothing to an existing candidate. A pass
     message dies with the pass; the journalled reason is all an operator
     reading the run back afterwards has to tell a round that committed
     everything from one that committed nothing.
  7. **The operator hand-off** — the named pause below. It sits exactly here,
     after the envelope has reconciled and before anything verifies the
     candidate.

  A quarantined envelope, or a `dead`/`stalled`/`timeout` job, follow the
  escalation ladder in step 2 (there is no legal `implementing→rework`, so a
  repeat failure goes to `blocked`, never `rework`) — as does the clean-tree
  no-op delivery over a task that never produced a candidate, which reaches
  `blocked` by the same `infra_max` cap. The dirty-tree one takes no rung at
  all and so reaches no cap: it is a boundary from the first pass that sees it,
  and stays one until a human answers it. The clean-tree round over a candidate
  that already exists takes no rung either, and needs none — it advances, and
  is bounded downstream by the attempt budget like any other delivered round.

  **The operator hand-off (`orchid task handoff`).** Some steps in a
  candidate are mechanical and require EXECUTION: applying a linter's own
  fix, setting the mode bit on a newly added executable, running a generator
  whose output is checked in. An engine profile that denies on the
  command **string** can perform none of them — it cannot run the linter, the
  generator, or `chmod` — so a rework round routed to it for that work is
  an instruction it could never satisfy, and it spends one of the task's three
  attempts finding that out. These steps therefore belong to the OPERATOR, and
  this is the point in the procedure where they happen. Before this they were
  performed here anyway, by habit, at a point nothing named — and a point
  nothing names is a point a driver walks straight past, running `orchid
  verify` against a candidate that was never going to pass.

  One kind of mechanical step must NEVER be on this list, however routinely a
  repository's own conventions ask for it: regenerating an artifact whose
  value is derived from the WHOLE TREE, such as a release-archive checksum
  pinned into a packaging file. Every candidate would rewrite the same line to
  a different value, so the first one merges and the second one conflicts on
  it in the stale-base rebase below — which aborts, sends the task to
  `rework`, and dispatches an implementer that cannot regenerate the artifact
  either. Nothing in that loop terminates and no attempt of it is free. A
  tree-wide derived artifact belongs to the INTEGRATION BRANCH: regenerate it
  there once, after merges have landed or at release time, and gate it at the
  release gate rather than in any task's `verification_commands`.

  A step that DOES belong on the list can still be lost after being
  performed. Done by habit rather than through this pause — late in a
  candidate's life, on a branch tip that is not what eventually merged — an
  operator hand-off is silently DROPPED from the shipped tree, and nothing
  fails at the time. It has happened: an exec-bit hand-off performed on a
  task branch whose tip never merged shipped the identical blob with the
  wrong mode, harmless only because every caller spelled `bash <path>`. That
  is the failure family lessons L017 and L021 record — mechanical work done
  out-of-band leaves no machine-checkable trace tying it to the candidate
  under judgment — and the acknowledgement in step 2 below is the
  countermeasure: it advances `candidate_sha` to the commit the hand-off
  itself produced, so work the shipped tree lacks is a sha mismatch a gate
  refuses rather than a habit nobody re-checks.

  So, with the task now in `testing` and before step 3's `testing` bullet
  runs anything:

  1. Perform the mechanical steps this candidate needs, in its worktree, and
     commit them onto its branch. Give each such commit the trailer
     `Orchid-Handoff: operator` in its message, so a later reviewer can tell
     an operator's mechanical commit from the implementer's own work rather
     than reading it as a violation of whatever hand-off clause the task
     spec carries.

     Commit ONLY the paths the mechanical step touched, and commit them in the
     tree the task record NAMES — its `worktree`, or the repository when it has
     none — on top of the current `candidate_sha` and on the branch the record
     names (`branch:` in its frontmatter). Step 2 reads `HEAD` from exactly that
     tree, so a hand-off committed anywhere else is not a hand-off at all: the
     verb sees a `HEAD` that never moved, finds nothing to advance, and the pass
     stops at the same boundary forever. A `HEAD` that moved somewhere ELSE —
     an unrelated history, a detached commit, another task's branch — is
     refused outright rather than adopted; see step 2.

     A task with no separate `worktree` is the awkward case, because then that
     tree is the one carrying `.orchid/` and the hand-off lands on the
     integration branch itself. Step 2 re-scans `base_sha..HEAD` and refuses on
     any `.orchid/` commit in that range, and this is the branch where those
     commits land: `orchid plan apply`, `run accept`, `config commit` and
     `start` each write state through a throwaway worktree and move the branch
     with `update-ref`, so any of them running while the task was in flight
     puts one there. Prefer giving the task a worktree (`git worktree add`,
     then `orchid task set <id> worktree <path>`, which is what dispatch does
     for itself) and committing the mechanical step in it. That same
     `update-ref` is why a commit made in a stale checkout of the integration
     branch is refused for a second reason: it never touches your index, so
     `git add <path>` followed by a plain `git commit` can build its tree from
     an index many commits behind `HEAD` and quietly revert every `.orchid/`
     path written since — bring the index back first (`git reset`, then stage
     your path). Either way the refusal stops the hand-off rather than
     corrupting the run — but it stops it, and the fix is here.
  2. Record it, AFTER those commits exist: `orchid task handoff <id> --ack
     --reason "<what you did>"`. The verb journals the reason, **advances
     `candidate_sha` to the commit the hand-off itself produced**, and writes
     `handoff_ack` equal to it. Both values are DERIVED — the candidate from
     `HEAD` of the tree `orchid verify` will run in (the task's `worktree`
     when set, else the repo), the acknowledgement from that candidate —
     never supplied by the caller, and `orchid task set handoff_ack` is
     refused outright.

     That advance is the point of doing this by verb rather than by hand.
     `candidate_sha` was captured back at step 3's `implementing` bullet, when
     the implementer's envelope reconciled; the hand-off's whole purpose is to
     COMMIT work after that. Left alone, the record would name the
     pre-hand-off commit while verification ran the post-hand-off tree, and
     every downstream judgment — the verify log, the review envelopes bound to
     it, the merge — would be evidence about a commit that was never the one
     verified. That is the failure lesson L025 records, and a hand-off that
     institutionalised it would be worse than the habit it replaces, because
     it would happen on every task instead of occasionally. Advancing leaves
     `candidate_sha` equal to the tree that runs, so `orchid verify`'s two
     header lines — `sha:`, read from the tree it ran in, and `candidate:`,
     read from frontmatter — name the same commit, and the INV-11 gate on
     `testing → reviewing` accepts the evidence. (As this ships, `orchid
     verify` itself does not compare the two before running; a task proposing
     that it refuse outright, T031, is unmerged at the time of writing. If it
     lands, this equality is the state it would require — the hand-off does
     not depend on it either way.)

     **What it will advance TO is itself a gate.** Adopting whatever `HEAD`
     happens to be would trade this drift for a worse mis-binding: a record
     naming a tree that shares no history with the work under judgment, while
     the verify evidence, the review envelopes bound to it and the merge all
     carry on as though it did. So the new commit must DESCEND from the
     candidate it replaces — a hand-off only ever adds commits on top of the
     implementer's work — and must be contained in the branch the task record
     names; a `HEAD` on an unrelated history, on another branch, or detached is
     refused, in a message naming both shas, and nothing is written. A record
     whose `branch:` does not exist in that tree is refused for the same
     reason: nothing can confirm membership of a branch that is not there
     (`orchid task set <id> branch <name>` if the record is what is wrong). The
     advance additionally re-scans `base_sha..HEAD` for `.orchid/` commits and
     refuses on a hit: this is the only other path that moves `candidate_sha`
     past entry to `testing`, so an operator's mechanical commit gets the same
     INV-04 scan the implementer's work got, not a way around it.

     **COMMIT FIRST — an ack over a dirty tree is refused.** Every check above
     compares SHAS, and a sha describes a commit; none of them can see the
     working tree sitting on top of it. Applying the linter's own fix and
     acknowledging without committing would leave `handoff_ack`,
     `candidate_sha` and `HEAD` in perfect three-way agreement about a commit
     that does not contain the work, while `orchid verify` runs the tree that
     does — lesson L025 again, by the one road matching shas cannot see, and the
     likeliest mistake here, because applying the fix FEELS like performing the
     hand-off. So the verb reads the tree's STATE too and refuses while anything
     is uncommitted, naming the paths — and refuses in the SAME direction when
     that read fails: a `git status` that cannot run (the path is not a
     checkout, it is bare, its index is unreadable) is reported as a tree that
     could not be inspected, never as a clean one, because an inspection that
     answers "clean" when it could not look is no check at all.
     (`.orchid/` is not counted: kernel state
     is no part of the candidate — INV-04 forbids the candidate containing it —
     and on a task with no worktree of its own that checkout is stale by design,
     since state is moved with `update-ref` and never through this index.)

     **And it is acknowledged from `testing` only.** That is the one status this
     pause exists in. From `reviewing`, `arbitrating` or `merging` the advance
     would move `candidate_sha` out from under people already judging that exact
     commit — their envelopes name the sha they were dispatched against, so the
     record would name a candidate nobody looked at while their verdicts are
     read as judgments of it. From anywhere else there is no finished candidate
     to bind to. `--clear` carries no such restriction: it only ever withdraws,
     it is what `orchid merge`'s rebase arm calls from `merging`, and a
     withdrawal some status could refuse would be a stale acknowledgement
     nothing could remove.

     Acknowledge last, then. If you commit again after acknowledging, the pause
     REOPENS — the resume rule below compares the acknowledgement against the
     tree's `HEAD`, not only against the other frontmatter field — so run the
     verb again: it advances and re-binds. Running it with nothing new to
     commit is a no-op that journals nothing, so re-running it is always safe
     and never the wrong call.

  **The acknowledgement is bound to a committed candidate, never to a task or
  a moment.** It counts only while `handoff_ack` equals the task's CURRENT
  `candidate_sha`, that is still what the tree's `HEAD` is, AND that tree is
  clean. That single rule answers all three questions a pause has to answer:

  - *What clears it.* Entry to `rework` (from any edge), `orchid task
    unblock`, `orchid task retry`, `orchid task reverify`'s re-stamp, and
    `orchid merge`'s rebase arm — the same places that invalidate verify
    evidence, for the same reason. A
    rebased tree is a DIFFERENT candidate: work performed on the old one is
    not evidence about it, so an acknowledgement is never silently inherited
    across the `merging`→`testing` rebase edge, exactly as INV-07 requires of
    the verify log beside it. The sha binding alone already refuses a stale
    acknowledgement; `orchid merge` additionally clears it explicitly, so the
    invalidation is a journalled event an operator can see rather than a
    silent mismatch.
  - *What a resume finds.* `orchid task show <id>`, `git -C <its tree>
    rev-parse HEAD` and `git -C <its tree> status` — `handoff_ack` equal to
    `candidate_sha`, equal to `HEAD` of the tree verification will run in, and
    that tree clean, means SATISFIED, and a resumed session or a second driver
    pass simply proceeds to verification. Anything else — absent, empty, bound
    to some other sha, a tree whose `HEAD` has moved past it, a tree with
    uncommitted changes on top of it, or a tree whose state could not be read
    at all — means OUTSTANDING, and it stops again.
    A tree merely brought back into line (the edits discarded) is satisfied
    again with no second ack: nothing was committed, so the acknowledgement
    standing still names the tree that will run. There is no
    in-memory state, no lock and no boundary record involved in that decision,
    which is what makes it survive a crash, a restart, or a second operator
    picking the run up cold. `orchid status --explain` reports the outstanding
    case as `awaiting-operator-handoff` rather than `awaiting-verify`: the wait
    is on a person, and saying otherwise is the silence this pause exists to
    end.

    **The tree is read, never inferred, and that third comparison is not
    belt-and-braces.** Two frontmatter fields agreeing prove only that they
    were written together. An operator who acknowledges and then commits once
    more — a second lint fix, a mode bit spotted on re-reading the diff —
    leaves both fields naming a tree that exists nowhere, still perfectly
    equal to each other. A resume reading that as "already performed" verifies
    the later tree and binds every downstream judgment to a commit nothing ever
    verified: lesson L025 again, reached silently. So a `HEAD` past the
    acknowledgement reopens the pause, and re-running `orchid task handoff <id>
    --ack` is the whole remedy — it advances and re-binds, which is why
    acknowledging LAST costs nothing but acknowledging early costs one command.

    The tree's STATE is read for the same reason, and it closes the same gap
    one step further down. An operator who edits after acknowledging — or who
    acknowledged before committing at all — leaves all THREE shas in agreement
    about a commit that does not contain the work, so nothing a sha comparison
    can do would notice. An uncommitted change therefore reads OUTSTANDING as
    surely as a moved `HEAD` does.
  - *What a deterministic driver does here.* `handoff_before_verify` (config,
    default `off`) is what asks for the pause; set it to `required` when the
    implementer is such a profile. Then `orchid drive` STOPS at an
    `operator-handoff` boundary INSTEAD of running `orchid verify`, and exits
    16. It never verifies-and-fails, so no attempt is spent. The boundary is
    operator-only by design (see the settling-verb list above), so the pump
    wakes no model for it and the driver raises one `orchid notify` blocker per
    distinct record — the surface a human actually reads. Left `off` — the
    default, and the right setting wherever the implementer can run the
    repository's own gates itself — nothing gates and no boundary is ever
    raised. Any value other than `off` reads as `required`, so a typo can only
    route more work to a human, never less.
  - *And the arm that asks for the same pause without being configured* (v1.1,
    INV-16). Where the `mechanical` step cannot be ROUTED to the engine that
    built this candidate, the pause is asked for whatever the config key says —
    the same rule that makes `orchid jobs prepare` refuse any step whose
    declared requirements the resolved actor does not cover (exit 19, nothing
    minted, no attempt spent; `lib/capability.sh`). The two arms compose and
    never override — either turns the pause on, neither turns the other off —
    because a capability atom is a claim by the plugin, not a grant, so an
    engine's own declaration must never clear a gate an operator set.
    **What this arm closes on its own** is the actor that cannot be RESOLVED to
    a manifest at all: it asks for the pause and the boundary NAMES it, because
    a capability gate that cannot identify an engine refuses rather than
    permits. A third-party plugin is not that case — the actor is looked up
    both by the directory a binding names and by the qualified `id=` an
    installed manifest claims (`acme/foo`), so it is priced from its own
    manifest like any other. Refusing the qualified form instead would exempt
    no one but hold every candidate a third-party engine builds at a hand-off
    no operator act can clear, since nothing a human does makes an unresolvable
    name resolve.
    **What it does NOT do is spare an operator the config key.** Its other
    outcome — the engine that built the candidate declares no `shell` — cannot
    arise for a candidate this kernel dispatched: `roles/implementer.role`
    declares `requires=workspace_write,shell,git`, and the role gate refuses an
    engine that declares no `shell` at exit 14 long before it could build a
    candidate for this pause to hold. That half is defense in depth against the
    role descriptor changing, and the answer for a task where no dispatch ever
    recorded which engine built the candidate — never a pause a healthy running
    repository meets.
    The config key remains the ONLY cover for the case the kernel cannot see: a
    profile that DECLARES `shell` and is still not granted it, which the
    shipped `claude` adapter is on its implement path.

  **This is not the operator prerequisite, and a task can be held by both.**
  The hand-off is repository CONFIG about mechanical work INSIDE the
  candidate, and acknowledging it produces a commit and MOVES `candidate_sha`
  onto it. The operator prerequisite (the `testing` bullet below) is a
  PER-TASK declaration about a step OUTSIDE the repository, and acknowledging
  it moves nothing, because nothing was committed. Clearing one says nothing
  about the other.

  **Take the hand-off FIRST when both are outstanding.** `prerequisite_ack` is
  bound to `candidate_sha` by the same rule `handoff_ack` is, so the hand-off's
  advance expires a prerequisite acknowledgement made before it — correctly,
  since nothing in a sha comparison can tell a re-pinned checksum from a
  rewritten migration. `orchid status --explain` names the hand-off first and
  the driver raises it first, which routes you through them in the order that
  costs one command each. Nothing enforces it: the wrong order costs one
  re-run of `orchid task prereq-ack`, and the boundary raised afterwards names
  the superseded candidate so you can see exactly why.

  **Why this does not contradict the rework brief below.** The `testing`
  bullet's FAIL arm carries a failing gate's exact `file:line: RULE: message`
  lines into the task body, where the next implementer reads them. That is
  deliberate, and it is not in tension with declaring the same fixes
  operator-owned: the two govern different things. The LOCATIONS travel with
  the guidance so that whoever acts has them and the record shows what was
  actually wrong — a brief that says "fix the two ShellCheck findings" without
  saying which lines is unsatisfiable for any reader who cannot re-run
  ShellCheck, and in r-001 that produced two consecutive rework rounds in
  which neither attempt touched either offending line. The ACT of running a
  linter, or committing its fix, stays with the operator under the paragraph
  above, because that is the part an engine profile cannot do at all. Carrying
  the locations is what makes a routed fix satisfiable; the hand-off is what
  stops it being routed to an actor that cannot perform it. Both are needed,
  and neither substitutes for the other.

- **testing** (`awaiting-verify`): the operator hand-off above comes FIRST —
  where `handoff_before_verify` is on, nothing below runs until this
  candidate's mechanical steps are acknowledged for it. Then `orchid verify
  <id>` — synchronous, run in the foreground of the tick itself; there is no
  job here, so nothing for `jobs check`/`jobs reconcile` to see.
  - **First, the operator prerequisite, if the task declares one.** Some
    tasks cannot be verified by their candidate alone. The canonical case is
    a schema task: it authors a migration and the tests that prove behavior
    against the altered table, and the database its suite runs against is
    still unmigrated when the tick arrives here. Nothing in the tick applies
    it — deliberately, because the sandbox that authors a migration is not
    where write access to a shared store belongs. Run anyway, the suite fails
    on the environment, the log reads like a defect in the candidate, and an
    attempt is spent on it.
    So a task whose verification depends on such a step declares it, at
    PLANNING time, in one frontmatter field: `orchid task set <id>
    operator_prerequisite "apply db/migrate/00NN_*.sql to the test database"`.
    It is set THEN and not later because the implementer cannot set it at
    all — its commits may not touch `.orchid/`, which INV-04 enforces at the
    door of this very status (PLANNING step 2 names the field for exactly
    this reason). If `operator_prerequisite` is non-empty and
    `prerequisite_ack` does not equal the task's current `candidate_sha` —
    empty, or naming a candidate this task has since superseded — **do not
    verify**: raise a `task-prerequisite` boundary naming the step. `orchid
    verify` refuses on the same condition on its own — exit **16**, the
    judgment-boundary code rather than its FAIL code 1 — so no evidence is
    written and no caller can mistake it for a failing candidate.
    The operator does the step and records it: `orchid task prereq-ack <id>
    --reason "..."`. That verb accepts `testing` and `merging` and no other
    status — the two in which a verb actually reads the ack (before `testing`
    the migration being acknowledged does not exist yet; `merging` is there
    because `orchid merge` gates on the same condition, see that bullet) —
    requires a `candidate_sha`, journals the reason, and stamps
    `prerequisite_ack` with that candidate_sha. It counts for that candidate
    and no other: an acknowledgement is a claim about ONE migration having
    been applied, and the next candidate may need a different one. Every
    path into `rework` —
    the advance, `task unblock`, `task retry` — clears the ack along with the
    verify evidence; and where a candidate is superseded WITHOUT passing
    through `rework`, the comparison above is what expires it. `orchid
    merge`'s rebase-reset is the sharpest such case and not a corner: it
    takes the task from `merging` back to `testing` on a freshly rebased
    `candidate_sha`, and the ack for the pre-rebase candidate must not
    satisfy the gate for the rebased one. It is not the only such move, which is
    why the rule is the comparison and not a list of verbs to keep in step:
    `orchid task reverify` re-stamps `candidate_sha` onto the task
    worktree's HEAD and lands in `testing` from `blocked` without entering
    `rework` either, and `orchid task handoff --ack` advances it onto the
    commit the mechanical steps produced. Each expires an earlier ack by the
    same comparison, with no clear of its own. Either way the declaration
    survives, so the boundary re-raises for the new candidate. Redeclaring
    the prerequisite (`task set operator_prerequisite`) clears the ack too —
    the operator acknowledged the step as it was worded — and journals that
    clearing as an `intervention`, like every other write of the field.
    `prerequisite_ack` is kernel-owned — `task set` refuses it, `task
    prereq-ack` is its single writer.
    Leave the field empty whenever the suite can migrate its own store (a
    fixture database, a temp file, an in-memory DB the tests build). That is
    the better design; this convention is for the case where it is not
    available.
    Where the operator hand-off above is ALSO outstanding, take it first: its
    ack advances `candidate_sha`, which expires a prerequisite ack made
    before it. See "Take the hand-off FIRST" there.
  - PASS: `orchid task advance <id> reviewing --reason "verify passed"` (the
    kernel's own INV-11 gate independently re-checks that the evidence's
    `candidate:` line matches the task's current `candidate_sha` before
    allowing the transition).
  - FAIL: if `hook.on_verify_fail` is bound, invoke it first (Preamble
    shape: `runners/orchid-launch <id> hook hook --hook on_verify_fail`,
    then `orchid jobs reconcile`) — an ok envelope's `.artifact.guidance`
    string gets attached to the task BEFORE the rework advance below:
    `orchid task set <id> hook_guidance "<the guidance text>"`. Because that
    hook resolves on a later pass, record the failed round first as
    `verify_fail_pending: a<attempt>:<candidate_sha>:<verify-log-sha256>`.
    While that exact receipt is current the later pass resumes the FAIL arm
    without running `orchid verify` again: the verifier's one mutable log must
    not be overwritten by a transient PASS before the failed round is charged
    and journalled. Missing or changed pinned evidence charges under the strict
    default; rework/reverify invalidation clears the receipt. Then,
    whether or not a hook fired, **classify the failure before charging it**
    — the attempt budget measures the CANDIDATE's quality, and a failure the
    candidate did not cause must not spend it. There is no signature list and
    no way to declare a failure forgiven; every waiver is earned on the same
    two halves, and neither half is worth anything alone:
    - *Not the candidate.* Something is outstanding that the implementer
      cannot fix by trying again, and every failing line in the round is
      attributable to it. THREE such things are recognized, each proved
      against the WORLD rather than read from the failure's wording:
      - `handoff` — a stale package checksum, or an executable this candidate
        left mode 644. The driver stats the files the candidate ADDED and the
        files it MODIFIED whose base recorded mode 755 (a `#!` file left mode
        644 is the exec-bit hand-off's own state, whether the candidate
        shipped it that way or dropped the bit while rewriting it), and it
        RUNS the repository's explicitly configured candidate-local package-pin
        freshness check (`handoff.pin_check`, config, default `none`; only ever
        an AUTHORITY under the rule below)
        and requires it to REPORT A FILE STALE — a nonzero exit is not that
        report, since a check that cannot find the formula or trips over
        metadata this candidate corrupted exits nonzero too and re-pinning
        fixes neither. Orchid's supported check contract admits a four-line report:
        its causal stale line plus exact pinned-checksum, expected-checksum,
        and one-command-remedy continuations. All four are attributed together;
        an unfamiliar continuation remains unknown and charges. Neither hand-off
        is a step an implementer profile may perform (L017).
      - `environment` — gitignored build state the integration checkout
        carries and the task's worktree never received, proved by comparing
        the two checkouts (lesson L003). Provisioning it is a DISPATCH step,
        above; this classification is the backstop, not the fix.
      - `flaky` — an assertion this repository ALREADY recorded as
        known-flaky, in a register (`flaky.quarantine`, config, default
        `tests/QUARANTINE.md`) that is an AUTHORITY under the rule below.
        That rule is the whole safety of it: an implementer cannot quarantine
        the assertion it is failing, because writing the entry removes the
        route. Signatures are matched literally and ordinarily claim only the
        lines they match. A register may also list exact normalized
        `FLAKE-CONTEXT:` companion lines for deterministic successful-fixture
        output an old runner exposes when a later quarantined assertion fails.
        Context is inert until a trusted signature matches this body; it is a
        closed line list, never a failed-child cascade, so any novel or genuine
        failure still charges.

      The exec-bit set, missing-build-state set **and the package/command
      subjects those missing trees publish**, and stale-pin check result are
      captured by `orchid verify` **before** it runs the candidate-controlled
      verification command, then written into the evidence header after that
      command exits. The classifier accepts them only when the log's `sha`,
      `candidate`, and `cwd` still bind the snapshot to this task's current
      candidate and worktree. It never falls back to inspecting live state
      after the run: otherwise a candidate could strip a committed executable
      bit, delete an ignored dependency tree, add a fake `.bin` subject under
      an integration dependency tree, or dirty release inputs until the pin
      check turns stale during its own test, print the matching diagnostic,
      and manufacture the post-run state that waives it. A legacy, malformed,
      or mismatched snapshot closes all three routes and charges.

      A REPOSITORY FILE IS NORMALLY AN AUTHORITY ON A CANDIDATE ONLY WHILE IT
      IS THE CANDIDATE'S OWN RECORD OF IT, and both routes above turn on that:
      the pin check and the register are read only when the file is UNTOUCHED
      across `base_sha..candidate_sha`, TRACKED IN `candidate_sha` as an
      ordinary file, and present in the verified worktree with the same bytes
      and the same mode that commit records. A diff of two commits is not that
      question — an edit left unstaged, an edit staged and uncommitted, a file
      dropped in untracked, one deleted, and one whose mode has moved are all
      invisible to it, and each of them is a way to hand the driver a file the
      implementer controls. Any of them, and any form of the question that
      cannot be ANSWERED at all, closes the route and charges.

      The flaky register has one bootstrap edge that the executable pin check
      does not: when BOTH task commits resolve and BOTH predate the register
      path, the driver may read the integration checkout's tracked copy while
      that copy is byte-, mode-, and index-clean at integration `HEAD`, and
      that HEAD is still the exact commit captured before candidate-controlled
      verification began. This is
      how an already-running branch can benefit from a historical flake learned
      after it was cut. A candidate addition fails the "candidate lacks it"
      half; a candidate deletion fails the "base lacks it" half. Neither can
      substitute integration's authority for its own change, and an
      unanswerable commit closes the route.

      A run whose recorded exit status says it STOPPED SHORT (`orchid verify`
      recorded exit 124, 137 or 143) is REPORTED on the charged round and
      forgives nothing. It was a fourth class once, on the reading that the
      harness had reaped a pass which therefore never spoke about the
      candidate; that reading was never proved. The identical trailer is what
      a candidate that HANGS until a timeout reaps it leaves — the very defect
      a `timeout` in a verification command line exists to catch — and what a
      suite that exits with the status deliberately leaves. Nothing in the log
      tells them apart, so it takes the uncertain reading below.

      The ATTRIBUTION is then required from the failure to that ARTIFACT: a
      failing line that names the file and reports its fault — refusing to
      execute that path, or calling it stale — or, for the absent build state,
      a line reporting that something COULD NOT BE RESOLVED which LIVES INSIDE
      the missing directory (`error Command "jest" not found` attributes to
      `mobile/node_modules` because `mobile/node_modules/.bin/jest` is in the
      checkout that has it, and attributes to nothing when the absent
      directory is an unrelated `.cache`). Yarn v1's exact version and help
      records are neutral. Its `$ <command> ...` echo and exact `error Command
      failed with exit code 127.` record stay in the failure denominator until
      trusted pre-run inventory proves `<command>` was published by that
      missing directory and a causal resolution line opens the environment
      route. Thus the named webBooks `$ tsx scripts/parseBooks.ts` case is
      attributed without making arbitrary package-manager chatter neutral;
      any unfamiliar wrapper line still charges. The filesystem lookup is
      applied only to that diagnosed subject, not every word on the line: in `ENOENT:
      ... open 'src/config.json'`, `src/config.json` is the subject and an
      unrelated package named `open` proves nothing. `Permission denied`, `is not
      executable`, `checksum is stale` and `Cannot find module` are all
      sentences an ordinary defect prints, so no wording decides this on its
      own; and being outstanding is not being to blame, since a repository
      whose sourced libraries carry `#!` lines at mode 644 has the exec-bit
      state outstanding on any candidate that adds one. Where the state holds
      and the failure is not attributable to it, the attempt is CHARGED and
      the reason says attribution was not established. Attribution is per
      FAILING LINE and takes two steps, because one fault does not produce one
      failure: one line must both name the artifact and report its fault
      (CAUSAL — the proof it blocked this run), after which every failing line
      naming it is its CASCADE, causal wording or not. The path must use its
      exact repository-relative, `./`-relative, or worktree-root absolute
      spelling, with a BOUNDARY after it: an outstanding `bin/tool` must not
      collect a genuine `bin/tool-helper: Permission denied` or a distinct
      `fixtures/bin/tool: Permission denied` by suffix. For the absent
      build state the CASCADE is that same naming rule and nothing wider: a
      failing line that merely mentions something living INSIDE the tree is not
      claimed — a dependency tree's direct children are ordinary words, and
      `FAIL: lodash helper returned 3` is a defect about something that shares
      a name with a package. NAMING a path UNDER the absent directory does
      count, and only for it: `ENOENT: ... open '.../node_modules/x'` cannot be
      about anything but the tree that is not there, whereas for an artifact
      that is a FILE `bin/tool/child` is a different file and `bin/tool` must
      not collect it. EVERY ROUTE THAT READS AN AUTHORITY OUT OF THE
      REPOSITORY asks git what this candidate changed — the pin check, the
      known-flaky register, and the added/dropped file lists — and each of them
      CHARGES when git cannot be asked at all: an absent, malformed or
      unresolvable `base_sha`/`candidate_sha` produces the same empty diff an
      untouched file does, and reading that as "untouched" hands the route back
      to a candidate that may have written the authority itself. A charged
      round REPORTS the outstanding state rather than prescribing a step for
      it, with one exception: a DROPPED exec bit still names `chmod +x <path>`
      as the operator's step, because the base tree recorded mode 755 and
      restoring it is owed regardless. A file merely ADDED at mode 644 is named
      and no more — that is equally how a sourced library ships.
      NO ROUND IS EVER
      WAIVED AS A ROUND: it is waived only when every failing line in it is
      individually claimed, so one round may hold a mix ACROSS CLASSES — a
      stale pin explaining six lines and an absent dependency tree explaining
      four are waived together, while one further unexplained line charges it
      and the reason quotes that line. The class NAMED is the one somebody
      must act on first (`handoff`, then `environment`, then `flaky`), and
      every contributing class is named in the reason. Resolution refusals
      such as `missing-helper: command not found`, `ENOENT`, and `Cannot find
      module`, and fatal runtime diagnostics such as `panic:`,
      `RuntimeError:`, and `Segmentation fault`, remain failing lines without a
      harness prefix. Progress identifiers such as `test_panic_recovery.sh`
      are excluded at word boundaries. That vocabulary is not an exemption:
      a non-empty line that is neither a recognized failure nor an explicit
      progress, success, or neutral NOT-TESTED record is uncertain and
      therefore remains an unattributed failing line. Orchid's terminal
      standalone `OK` and both NOT-TESTED forms are in that closed non-failure
      vocabulary. The shipped whole-suite/CI harness captures each test's
      output until the parent observes its exit status. For a zero exit it
      exposes only durable NOT-TESTED/RED/GREEN qualification records and one
      terminal `<path>: OK`; for a nonzero exit it exposes the child's output
      verbatim. Outcome therefore cannot be forged by printing an in-band
      success marker from the child being judged. The anchored qualification
      records remain neutral when their labels say `failure` or `failed` —
      those words name the negative fixture they demonstrated — but a generic
      line merely ending in `OK` gets no such precedence over a failure.
      Unknown lines cannot join a
      same-artifact cascade merely by naming the artifact. Separately
      outstanding state grants no
      attribution, but a waived reason still reports an operator action it
      proves is owed, such as restoring a candidate-dropped 755 bit.
      Such a round is charged to
      `orchid task infra-fail <id> --reason "..."` — the environment budget,
      capped by `infra_max` (config, default 3) — and then enters rework
      WAIVED: `orchid task advance <id> rework --waive-attempt --reason
      "verify failed (<class>, attempt not charged): <why>"`. The
      canonical reason is written into the `infra failure #N` intervention
      entry first, so an infra cap, recurrence boundary, implement-floor
      failure, or refused rework edge still leaves “attempt not charged”
      durable even though it never reaches the waiver advance. An archetype
      with no testing-to-rework edge is not infra-charged, so the driver writes
      the same reason as a task-scoped journal note before stopping. A
      successful advance adds its `attempt_waiver` entry; that kind alone arms
      the recurrence counter.
      Together those records make “this failure was not charged, and here is
      why” a durable fact rather than an inference from a counter that did not
      move. A waived round must produce
      a FRESH implement envelope of its own: `--waive-attempt` leaves
      `attempts` where it is, so the re-dispatched round would otherwise
      resolve the previous round's envelope and re-verify a candidate that
      never moved. And it is waived ONCE: if a waived fault recurs on a task
      that has ALREADY HAD ONE WAIVED — of ANY class — stop at an operator
      boundary instead of re-dispatching, because none of these is a fault the
      implementer can clear and an identical retry cannot fix any of them.
      That guard counts the task's own waived rounds, not `infra_failures`,
      which also counts unrelated harness faults.
    - *The candidate, or anything uncertain.* `orchid task advance <id>
      rework --reason "verify failed (candidate, attempt charged — <why>):
      see .orchid/reviews/<id>-verify.log"`, which consumes an attempt.
      Uncertainty always lands here: forgiving a real defect hides it, while
      charging a spurious failure costs one attempt, so the classification
      fails toward the strict reading and states why it charged. That includes
      a failure that merely COINCIDES with an outstanding fault; a resolution
      failure whose subject is NOT inside the absent directory; a flaky-
      looking failure the repository never wrote down; a run whose recorded
      exit status says it stopped short, since that status cannot tell a reap
      from a candidate that hung; and every failure none of the three covers.
      Orchid forgives only what it can prove.
      When the archetype declares no `testing -> rework` edge, or that advance
      is refused before it charges, the driver takes the universal blocked edge
      through `orchid task advance <id> blocked --charge-attempt --reason
      "..."`. That flag is admitted on a closed set of three edges and no
      others: `testing -> blocked` here, plus `merging -> rework` and `merging
      -> blocked`, which exist for `orchid merge`'s `gate_failed` arm alone
      (see the merging bullet). It cannot be combined with `--waive-attempt`,
      and journals and consumes exactly the candidate attempt it charges. The
      boundary names `task retry` and `task reverify`; an absent or refused
      rework edge is never a free candidate failure.

    **Either advance carries the failing gate's exact locations into the brief,
    automatically.** Before it deletes the verify log, `orchid task advance
    <id> rework` reads it for location-bearing diagnostics — `file:line:
    RULE: message` and `file:line:col: message` (the gcc-style shape almost
    every linter emits, including this repository's own
    `scripts/ci-local.sh` policy gates), `file: line N: message` (what
    `bash -n` prints), and ShellCheck's default three-line tty report, which
    is recomposed into `file:line: SC####: message` from its own fields —
    and appends those lines VERBATIM to the task body under a "Rework brief"
    heading. `lib/pack.sh` copies that body into the next implementer's pack
    as `task.md`, so the locations arrive WITH the instruction instead of
    behind a pointer to a log the recipient may be unable to open, re-run or
    reproduce. This is not the driver's doing and needs no orchestrator step:
    it happens on every `rework` edge — the driver's, a hand-walked `task
    advance`, `orchid merge`'s validation-failure arm, `task arbitrate
    --result request-changes`, `task unblock` and `task retry` — which is
    what makes it automatic rather than a convention someone has to
    remember. It is capped (and says so when it truncates, rather than
    silently presenting a partial list as complete), because `task.md` is a
    non-truncatable pack input, and it emits nothing at all when no failing
    log carried a location, so a merge conflict never gains a heading
    promising locations it does not have. Who may run the linter is a
    separate question, answered by the operator hand-off above.

    **The evidence it quotes is bound to the candidate that failed.** Both
    `orchid verify` and `orchid merge` stamp `candidate: <sha>` into their
    evidence log's header, and the brief quotes a log only when that header
    equals the task's CURRENT `candidate_sha`; a log naming a superseded
    candidate, a log carrying no `candidate:` header at all, and a task with
    no candidate to bind to are all dropped in silence. This is the same
    INV-07 rule that invalidates review and verify evidence when the
    candidate moves, applied to the brief — and it is not a refinement of the
    mechanism but a precondition of it. The brief exists to carry the CURRENT
    failure into the next attempt, so re-injecting locations from a candidate
    that no longer exists is worse than emitting nothing: it hands the next
    actor line numbers that are confidently wrong, which is the defect this
    section exists to remove, wearing its heading. `<id>-merge.log` is the
    log that outlives its candidate most easily — `orchid merge`'s rebase arm
    mints a new `candidate_sha` under a tree whose merge log is still on
    disk, and the `merging` arm of the `rework` advance deliberately exempts
    that log from its deletion so the failure it is journaling keeps its
    evidence — so the sha compare, not the file's presence, is what decides.

    **And each brief in the body names its own candidate; the ones describing
    a candidate this task has since replaced are aged out.** A brief is
    APPENDED, once per rework round, to a body that outlives every candidate
    in it — so binding the QUOTE to the failing candidate only solves half of
    it. Left alone, round three hands the implementer round one's line numbers
    beside round three's, in the same voice, with nothing in the text saying
    which describes the tree it was just given: the same defect one layer up,
    inside its own remedy, and worse than the log case because locations that
    were exact when written go on looking actionable forever. So every brief is
    fenced with the candidate it describes, and every entry to `rework`
    collapses the blocks describing some other candidate to a short superseded
    notice — the block keeps its marker, its candidate and the count of what it
    carried, so the record of what each round was told survives; the
    instruction does not. Exactly one live brief reaches the pack: the one for
    the candidate now under work.

    When the rework was caused by something `context.md` failed to state —
    not an actual defect in the candidate — this is a lesson-birth moment
    (docs/specs/kernel.md, Cross-run lessons): `orchid lessons add --scope
    repo --invalidate-when "..." "..."` before continuing. A failure you can
    see is non-deterministic is the same moment, and the first answer is to
    make the test WAIT FOR WHAT IT SAMPLES rather than sample one instant.
    Orchid never infers flakiness and will not guess at it, so an
    unrecorded flake is CHARGED; what it does honour is a flake the repository
    has already WRITTEN DOWN, in `flaky.quarantine`, before the candidate
    existed. Quarantining is the second-best answer and it is a visible one:
    an unreliable gate must announce that it is unreliable rather than fall
    silent.
    Once the task's non-waived `attempts` count (`orchid task show <id>`)
    reaches its budget, stop retrying automatically: `orchid notify --task
    <id> "attempts exhausted (<attempts>/<budget>): see
    .orchid/reviews/<id>-verify.log"` then `orchid task advance <id> blocked
    --reason "attempts exhausted (<attempts>/<budget>)"`. The budget is
    `rework_max` (config, default 3), or the task's own `attempt_budget` when
    an operator has granted it one (`orchid task retry <id> --reason "..."
    --attempts N`). It is orchestrator-enforced HERE, not a kernel-verb gate; a
    classified non-candidate failure uses a waived rework edge and never
    reaches this budget check, which is the point of classifying first. One
    exception, and only one: `orchid merge` applies the same budget itself on
    a `gate_failed` merge (T007), because it owns both the charge and the edge
    that follows it and cannot hand the decision back mid-transaction. It
    reads the number from the same place — the task's `attempt_budget`, else
    `rework_max` — so there is still one cap, not two.

- **reviewing** (`awaiting-review-envelopes`): apply the risk-tiered review
  policy from the Preamble — `orchid jobs review-plan <id> --pin`, then
  `runners/orchid-launch <id> reviewer review --engine <slot-engine>` for
  every printed slot. Once step 2's reconcile has produced a verdict for
  every dispatched slot: `orchid task advance <id> arbitrating --reason
  "review reconciled: verdict <verdict>[, <verdict>]"`. The kernel now
  enforces the count itself: this advance refuses outright — "arbitrating
  requires N reconciled review envelope(s) for risk_tier <tier> (have
  <have>)" — until at least `review_required_count(risk_tier)` reviewer
  envelopes bound to the task's CURRENT `candidate_sha` have actually
  reconciled; a slot whose job is still
  `running`/`prepared`/`never-started`/`unstamped`, or whose envelope was
  quarantined, never silently counts toward that number.
  The escalation ladder for a dead/stalled/timeout/never-started/unstamped
  reviewer job is identical to implementing's, applied per slot — `reviewing`
  has no legal `rework` edge either, so a repeat failure on any one slot also
  goes to `blocked`.

- **arbitrating** (`awaiting-arbitration`): inline judgment, not a launched
  job — kernel.md is explicit that "the orchestrator implements nothing
  beyond ≤~10-line arbitration trivia" here. For a `high` risk_tier task,
  see HEADLESS OPERATION's arbitration-wait note below before judging: the
  preferred `role.arbiter` engine gets first refusal, bounded by
  `arbiter_wait_s`. If `hook.before_arbitration` is bound, invoke it first
  (same Preamble shape: `runners/orchid-launch <id> hook hook --hook
  before_arbitration`, then `orchid jobs reconcile`) — read its artifact
  alongside the review envelopes below, as one more input to the same
  weighing, never a separate verb call of its own. Read the task's review
  envelope(s) under `.orchid/reviews/<id>-a<attempt>-reviewer*.json` (and
  `orchid task show <id>` for `blocking_severity`), weigh the findings.
  When the judgment call itself turns on repo knowledge no file
  (`context.md`, `lessons.md`, the task body) actually contained — a third
  lesson-birth moment (docs/specs/kernel.md, Cross-run lessons) — record it
  now, before deciding: `orchid lessons add --scope repo --invalidate-when
  "..." "..."`. Then:
  - approve: `orchid task advance <id> merging --reason "..."`.
  - reject: `orchid task advance <id> rework --reason "..."` (add
    `--waive-attempt` when the rejection reflects an infra/tooling gap
    rather than an actual defect in the candidate). When this rejection was
    itself driven by something `context.md` failed to state, that is the
    same lesson-birth moment `testing`'s FAIL arm names above — record it
    the same way before moving on.

- **merging** (`awaiting-merge`): more than one task may sit in `merging` at
  once (it counts against `concurrency` like any other active status); per
  the Preamble, run `orchid merge` for only ONE of them this tick — any
  deterministic order (e.g. lowest task id) — and leave the rest for the
  next pass. This is a throughput choice, not a safety one: the verb's own
  compare-and-swap against the integration ref (below) would simply refuse
  a second concurrent merge anyway. Before that one call, if
  `hook.before_merge` is bound (`orchid config list`), invoke every bound
  entry first — the Preamble's shape, `runners/orchid-launch <id> hook hook
  --hook before_merge` for the first bound entry, `--engine <name>`
  naming each additional one — then `orchid jobs reconcile`. This is the ONE
  hook point the kernel itself also enforces: a `:required` entry with no
  fresh ok envelope for the task's CURRENT `candidate_sha` makes the verb
  below refuse outright (exit 15, `merge blocked: required before_merge hook
  '<id>' has no ok envelope for this candidate`) rather than running the
  merge at all; an `optional` entry never gates it either way, invoked or
  not. Separately, and needing nothing from the orchestrator at all, the verb
  runs the repository's own `merge_gate` (config, default *unset*) on the
  merged tree alongside the task's `verification_commands` — a floor set once
  for the repository that every task inherits, precisely because a check each
  task has to opt into reaches only the tasks whose author remembered it. It
  blocks: a red gate returns the task to `rework` with the integration ref
  untouched, exactly as a red task suite does. It also *terminates*, which a
  red task suite at merge does not: unlike every other merge failure it
  charges the round, so a gate that stays red reaches `blocked` instead of
  cycling — both outcomes are itemised below. Nothing here needs invoking or
  reconciling; see docs/configuration.md for its cost and its recursion guard.
  `orchid merge <id>`, then branch on the task's **post-merge status**
  (`orchid task show <id>`) — never on the exit code alone: exit `1` is
  ambiguous between two different outcomes below, so the status is the only
  reliable signal. The verb already performs the resulting `task advance`
  internally in every case that actually changes status, so there is no
  separate advance call to make here:
  - status `done` (exit was `0`): merged.
  - status `rework` (exit was `1`, `validation_failed` / `gate_failed` /
    merge or rebase conflict; verb already journaled and advanced it):
    continue the walk's rework handling on the next pass. `gate_failed` means
    the repo-wide `merge_gate` failed rather than the candidate's own suite —
    same routing, but a failure the task was never asked about and frequently
    not its author's doing, so say which one when you brief the rework.
    `gate_failed` is also the ONE merge failure that consumes an attempt:
    `merging → rework` is otherwise exempt (the candidate was independently
    verified once already), but a red repo-wide gate is red again next round,
    so leaving it uncharged makes the loop unbounded. Merge conflicts, rebase
    conflicts and `validation_failed` stay exempt — read the reason, not the
    edge.
  - status `blocked` (exit was `1`, `gate_failed` with the attempt budget
    spent; verb already charged the round, journaled and advanced it): the
    repo-wide `merge_gate` was red for every rework round the task had, and
    another round would re-run the same gate against the same repository. Do
    not dispatch one — raise it for a human, naming the gate rather than the
    candidate. The recoveries are `orchid task reverify <id> --reason "..."`
    (re-runs verification, consumes no attempt) once the repository is green,
    or `orchid task retry <id> --reason "..." --attempts N` for more rounds.
  - status `blocked` (exit was `1`) with NO `.orchid/reviews/<id>-merge.log`
    recording a red gate: the other route to this status, and it needs the
    opposite report. A `worktree_prepare` step that keeps failing for the
    validation worktree charges the infra ladder each pass, and the kernel's
    own counter blocks the task at `infra_max` — before the suite or the gate
    ever run, and after the verb deleted any earlier attempt's validation
    log. So there is no gate to name and no merge log to read: raise it as
    the blocked task it is (`orchid task unblock|retry|reverify` are the
    remedies, as for any blocked task), point at the prepare log the verb's
    own final line names, and fix the environment. Reporting this one as a
    gate failure sends a human to a file that is not there, for a repository
    condition that did not happen; distinguish the two by whether a merge log
    this run wrote records `gate_status: ran` with a nonzero `gate_exit:`,
    never by the status or the exit code, which are identical for both.
  - status `testing`, with a fresh `base_sha`/`candidate_sha` and invalidated
    evidence (exit was `5`, `rebase_rereview_required`; verb already
    journaled this with kind `rebase_review`): classifying the coming
    re-review as delta vs. full is the orchestrator's call (kernel.md);
    record it if it isn't obvious from the diff size — `orchid journal add
    --task <id> "re-review scope: delta|full — <why>"` — then resume the
    `testing` branch of this walk on the next pass over the task.
  - status still `merging` despite a nonzero exit (e.g. the update-ref
    compare-and-swap lost to a concurrent merge, or the `worktree_prepare`
    step for the validation worktree failed): a persistent config/CAS
    problem, not a candidate defect — the verb journaled it but could not
    advance the task out of `merging` on its own. Notify with evidence that
    exists: `.orchid/reviews/<id>-merge.log` is written only once the verb
    actually ran the suite, and the verb deletes any earlier attempt's copy
    before it begins, so when that file is absent the run died BEFORE
    validation and the verb's own final line (which names the prepare log
    when there is one) is the record to carry instead — `orchid notify
    --task <id> "merge left task in merging: see
    .orchid/reviews/<id>-merge.log"`, or the same message with that final
    line in place of the `see ...` clause. Leave the task in `merging` for a
    retry either way; never assume `rework` just because the exit code was
    nonzero.
  - status still `merging` with exit `15` (`merge blocked: required
    before_merge hook '<id>' has no ok envelope for this candidate`): the
    verb never even attempted the merge, so there is nothing to invalidate —
    fix the missing/failing required hook (rerun it, or fix its handler)
    and retry `orchid merge <id>`; this is a hook-handler gap, never a
    candidate defect the way exit `1`'s `rework` is.
  - status still `merging` with exit `16` (`merge refused: <id> declares an
    operator prerequisite not acknowledged for this candidate`): the same
    condition, the same boundary and the same remedy as the `testing` bullet
    above — raise a `task-prerequisite` boundary naming the step. This verb
    re-runs the task's whole verification suite against the same external
    store, so it gates on the prerequisite exactly as `orchid verify` does;
    gating one stage and not the other would forgive an unapplied migration
    at verify and charge it here, where the failure arm sends the task to
    `rework` and the log reads like a candidate defect. Nothing was merged,
    no evidence was written and the integration ref did not move. The
    operator takes the step, records it (`orchid task prereq-ack <id>
    --reason "..."` — which accepts `merging` for this case), and `orchid
    merge <id>` is simply re-run. If the message instead reports an
    acknowledgement for a SUPERSEDED candidate, the step must be re-taken for
    the current one: an ack is a claim about one migration, not about the
    task.

**4. Blockers.**
If a notify channel is configured (`notify.channel`), the outbound message
to it is best-effort only (queued in `runtime/outbox/`, drained by the pump,
retried up to `send_retry_max` times before quarantine) — `BLOCKERS.md` plus
the terminal is always a complete interaction surface on its own, with or
without a channel ever delivering anything (docs/specs/operations.md).
Raise one with `orchid notify [--task <id>] "<text>"` (prints a `qid`). If
`hook.on_blocker` is bound, invoke it now (Preamble shape:
`runners/orchid-launch <id> hook hook --hook on_blocker`, then `orchid jobs
reconcile`) — its artifact is read the same way `on_verify_fail`'s is,
folded into whatever `unblock`/`retry` call eventually resolves the
blocker, at your discretion. Consume an answer by reading
`.orchid/runtime/answers/<qid>.answer` directly
once it exists — there is no verb that reads an answer back; `orchid answer`
only ever writes one, for the human/channel side. Then resolve the task:
`orchid task unblock <id> --reason "<qid>: <answer text>"` when the answer
changes something about the plan, or `orchid task retry <id> --reason "..."`
when nothing needs to change and the task should simply run again. **Both
record the text into the task body**, which is the file `pack_build` copies
into the implementer's capsule — so a reason really is delivered to the next
attempt, and each verb prints a line saying where it went (the journal alone
never reached an engine, which made "the guidance was ignored" and "the
guidance was never delivered" indistinguishable from outside). Two more
choices at this same moment:

- The task has no rounds left (`attempts` is at its budget): `retry` grants
  it one, journal-first, as an `attempt_budget` on that task — pass `orchid
  task retry <id> --reason "..." --attempts N` when one plainly is not
  enough. Either way the grant only ever raises the budget, so a retry of a
  task still inside its budget grants nothing — and an explicit `--attempts N`
  that would grant nothing is **refused** rather than swallowed, naming the
  budget, what is spent, and the smallest number that would buy a round (a
  flag that quietly does nothing is trusted, and then blamed for a round it
  never bought). `unblock` deliberately grants nothing at all and warns on
  stderr when it hands back a task with an empty budget.
- **The tree is already green** — the failure was environmental, or you have
  fixed it yourself in the task worktree and committed on the task branch:
  `orchid task reverify <id> --reason "..."`. It moves `blocked|rework →
  testing`, re-stamps `candidate_sha` from that worktree's HEAD, drops the
  stale verify evidence, and spends no attempt — the supported form of what
  operators used to do by hand and then describe in a `retry` reason. Commit
  the fix first: a worktree with uncommitted changes is refused (exit 3,
  listing them), because verification runs there while the evidence binds to
  a sha — an uncommitted edit would be exercised by a run that certified a
  tree which never contained it. **A clean tree is not the right tree**, so
  the commit it would stamp must also descend from the candidate it replaces
  and be contained in the branch the task record names; anything else is
  refused naming both shas, because adopting whatever HEAD happens to be is a
  worse mis-binding than the drift — every field agrees afterwards. That is
  the same rule `task handoff --ack`'s advance is held to, in the same code.
  An acknowledged hand-off is WITHDRAWN by the re-stamp, never carried: the
  commit adopted is one committed after the ack, so no operator has said its
  own mechanical steps are done, and descent proves only that the acknowledged
  work is still present. The boundary that reopens costs one command rather
  than a wedge — `reverify` leaves the task in `testing`, the one status
  `handoff --ack` is legal from. Every refusal it can raise is checked before
  it writes anything, so a refused `reverify` leaves the task untouched.
  `blocked|rework → testing` is ordinary transition data, so `orchid task
  advance <id> testing --reason "..."` reaches the same edge — and is held to
  the same conditions, by the same code: a reason, a clean worktree, and a
  `candidate_sha` that is already that worktree's HEAD. What that raw route
  will not do is re-stamp the candidate for you; it refuses and names
  `reverify`, which is the verb that does. Neither route can certify a tree
  the other refuses.

**5. Before sleeping.**
`orchid status --explain` (so anything watching the terminal — or the next
resumer — sees exactly where the run stands), then `orchid status --html`
to regenerate the static status page (`status_page` (config, default
`runtime/status.html`)) — the "check from another room" surface: a
self-contained snapshot (inline CSS, no external assets, no JS) of the run
header, task table with explain predicates, engines ledger, open blockers,
and the last 10 journal entries. Best-effort: this call never blocks the
tick — an unwritable status_page path or any other failure here is simply
left for the next pass to retry, exactly like a transient engine hiccup
elsewhere in the loop. Then `orchid run refresh-lease` once more (so a
concurrent resumer never mistakes this pass for a stalled one).

**How `orchid drive` renders the five steps above.** The mechanized pass is
the same procedure; the points below are worth stating because it must be
decidable without a model — and because every one of them is a place a
one-pass driver could otherwise stop progressing in silence:

- **Archetype-driven, never archetype-named.** The walk routes on the task's
  CURRENT status plus its archetype's DECLARED `transitions=`/`outcome=`. A
  queued task dispatches into the first active status its archetype declares
  an edge to — `implementing` for `feature`, `reviewing` for the shipped
  `review` archetype, whatever a custom archetype declares for itself — and
  `outcome=report` means no worktree and no candidate is built (both shas
  pin to the integration head so review envelopes still bind to something
  concrete). No branch anywhere reads an archetype's, or an engine's, name.
- **Worktree dispatch is idempotent and crash-safe.** The dispatch worktree
  has one deterministic path, a sibling of the repository named
  `<repo>-<task-id>`. It is REUSED only when the recorded path, the task's
  own `branch`, the Git common directory and the owning task all agree and
  no other task claims it; an exact orphan at that path with no recorded
  field yet — the signature of a pass that died between `git worktree add`
  and `orchid task set <id> worktree <path>` — is ADOPTED rather than
  recreated. Anything else (a vanished recorded path, a foreign checkout, a
  branch mismatch, a path another task claims, a branch already checked out
  elsewhere) is REFUSED as a `worktree-conflict` boundary. A duplicate
  worktree is never created to work around any of these.
- **Every checkout this protocol RUNS VERIFICATION IN gets a preparation
  step.** There are exactly two: the dispatch worktree above, and the temp
  worktree `orchid merge` validates in. Both hold only what is committed, so
  a project whose verification needs untracked setup fails there while
  passing in the operator's own checkout, and the failure is scored against
  the candidate rather than the environment. (The integration checkout
  `orchid start` creates is deliberately NOT in that set: no verb of this
  protocol ever runs a verification suite there, it is the operator's own
  working checkout to set up as they please, and it is created before this
  run has committed the config the step would be read from. If a suite is
  run there it is run by hand, by someone who can prepare it by hand.)
  `worktree_prepare` (config, default unset) is
  the command that closes that gap; it runs inside the fresh checkout, with
  that checkout as its working directory, its **stdin closed**, and the
  repository's own canonical path in `ORCHID_REPO_ROOT` (nothing relative
  reaches the repository from both a sibling worktree and a `$TMPDIR` one).
  Stdin is closed for the prepare step and for every verification command
  this protocol runs, and it is a correctness rule rather than a courtesy:
  the driver walks its work through loops whose own stdin is the worklist,
  so a child that reads stdin would consume the entries not yet walked and
  end the pass early with no error anywhere. The budget is
  `worktree_prepare_timeout_s` (config, default 900), so a hung setup step
  cannot hang the pass. It runs once per checkout per command text — the
  stamp lives in the worktree's private git dir, so it dies with the worktree
  and is re-run when the configured command changes. A failure is never
  stamped and never advances the task: dispatch parks on a
  `worktree-conflict` boundary, and `orchid merge` refuses outright.
  **A failure is charged to `infra_failures`, never to `attempts`** — through
  `orchid task infra-fail`, from both checkouts. That is the whole reason the
  step is its own command rather than a bootstrap folded into the
  verification one: an environment that cannot be prepared is not an attempt
  the candidate got wrong, and the counter's own cap (`infra_max`) is what
  turns a setup command nobody repairs into a blocked task instead of a
  boundary re-raised on every pass forever.
  `ORCHID_REPO_ROOT` is exported to **every verification command this
  protocol runs, not only to the preparation step**: reaching back to the
  repository for gitignored state is not always one-time setup, and the
  suite's own checkout is a sibling worktree or a `$TMPDIR` one either way.
- **A dispatch launches BEFORE it advances.** The queued task's status is the
  only record that it still needs dispatching, so it is not given up until a
  job has actually been spawned. `no eligible engine` (exit 14) is the case
  this exists for: it is a WAIT, the ledger window reopens on its own, and
  Failover above requires the task to stay in its PRIOR status
  (`pending`/`rework`) so the identical dispatch simply succeeds on a later
  pass. Advancing first and discarding the launch's result would strand the
  task in an active status with no job, no envelope and no boundary — a run
  that polls forever on work nobody is doing. A job already outstanding for
  that task and operation (a pass that died between the spawn and the
  advance) is adopted, never spawned a second time.

  **A `pid: 0` manifest with no log is not an outstanding job — and it is not
  a second chance either.** `orchid jobs prepare` mints every manifest with
  `pid: 0` and the launcher stamps the real pid only after the spawn, so
  `pid: 0` with no log means the spawn line was never reached and nothing is
  running. Adopting one would defeat the whole rule above — the task advances
  behind a job that will never file an envelope. So the driver treats it as no
  job. But it does not simply relaunch over it either: `jobs prepare` REFUSES
  to mint a second manifest for a slot (task, attempt, role, operation, and for
  hooks the point) that already has an UNLAUNCHED one, exiting 18. That refusal
  is a WAIT, ranked with exit 14 — nothing was spawned, no rung of the ladder is
  spent, and it clears itself, because the same pass's `orchid jobs gc` reaps
  the orphan once it is older than the bound that pass hands the verb
  (`stall_minutes`), after which the identical dispatch succeeds. That bound is
  the unattended DRIVER's, passed as `--prepared-older-than-s`, and it is there
  because a manifest younger than it may belong to a launcher that is between
  `jobs prepare` and its own spawn line right now — reaping that one would
  delete the pack and request document out from under a live launch. An
  operator who has looked at a particular manifest gets the number they type:
  `orchid jobs gc --older-than-s 0` honours zero.

  **A `pid: 0` manifest WITH a fresh log IS an outstanding job.** The launcher
  creates the log by redirecting the spawn into it, so that manifest is a spawn
  whose pid was never recorded: an engine may be running with no signal able to
  reach it. The driver waits on it rather than launching a second engine into
  the same worktree, `check` reports it `prepared`, and nothing reaps it. That
  wait is bounded, not permanent: once the log has been silent for
  `stall_minutes`, `check` reports `unstamped`, the ladder spends one rung, and
  `gc` retires the manifest while keeping the log.

  **The refusal and the reap are the same predicate, so exit 18 always
  clears.** Both mean *unlaunched*: `pid: 0` and either no log at all or a log
  silent past `stall_minutes`. And because a phase that cannot clear the orphan
  would be a phase that can never leave the refusal, that reap runs in EVERY
  phase — including `PLANNING`, whose pass runs no reconcile and no check but
  does still launch `plan critique` and plan-hook jobs.
- **Hooks are deferred, never skipped — and never gated past their job.** A
  hook is a job: it is launched, reconciles on a later pass, and only then
  can its artifact be read. So the driver dispatches a bound point's entries
  (the first with no `--engine`, each additional one named explicitly) and
  DEFERS the step that point guards to the next pass, rather than blocking a
  pass on an engine. Three rules keep that deferral bounded:
  - Once envelopes exist, an `optional` entry never gates anything, and a
    `:required` entry with no `ok` envelope for the current candidate raises
    a `hook-failure` boundary and takes no transition.
  - Envelopes are counted IN SCOPE for the task's current `candidate_sha`:
    one left behind by a candidate that has since moved *within the same
    attempt* (the `merging`→`testing` rebase edge) is not evidence for the
    candidate on the task now, so the point is dispatched again for the new
    one instead of being treated as answered-but-unsatisfiable forever.
  - An `optional` point whose handler dies leaving NO envelope is noted and
    stepped over — it gates nothing, so it also never spends the task's
    `infra_failures` budget nor gets relaunched into the same wall pass after
    pass. **A handler that could not even be launched is the same non-event**:
    an optional binding whose launcher exits non-zero (an `input_overflow` pack,
    a binary that will not resolve) is journaled, exempted from the ladder, and
    stepped over in that same pass. Deferring it instead would hand the next
    pass the identical broken launch to make the identical decision, and the
    step it guards would be parked for as long as the launcher stayed broken —
    an `optional` entry gating a transition, which is exactly what these rules
    forbid.
  `on_verify_fail`'s guidance is attached via `orchid task set <id>
  hook_guidance` before the rework advance, exactly as above.
- **A reviewer relaunch is keyed on the SLOT, never on a count.** `orchid
  jobs review-plan`'s table is the slot ledger: which slots exist and which
  engine each was routed to. A filed review is credited to a slot only when
  its own `.engine` is that slot's engine — compared against the qualified id
  the pin recorded for that slot, so uninstalling or rebinding an engine
  afterwards cannot orphan a review it already filed (an envelope naming no
  engine is credited last, to whatever slot is still open), and each review is
  credited exactly once. Counting instead would let a relaunch that landed a SECOND
  review from slot 1's engine both satisfy the tier's count and stop slot 2
  from ever being dispatched — handing the truth table two reviews from one
  engine to approve unanimously, which is precisely the independence the
  risk-tiered policy exists to enforce. When the count is met but a routed
  slot still has no review of its own, the pass stops at a `review-evidence`
  boundary rather than adding a third review to a set the kernel already
  counts as complete. The one relaunch the escalation ladder below does NOT
  make is a reviewer's, for the same reason: it would go back through the
  role's default chain rather than the slot's engine.
  **That ledger is pinned, and its boundaries name their remedy.** A slot
  identity that can be recomputed is not a ledger at all (see the Preamble's
  risk-tiered review policy, and lesson L027), so the table is bound to the
  attempt by `orchid jobs review-plan <id> --pin`. Two verbs, and only these,
  move a pinned plan afterwards — each records the table it landed in the
  journal, and a `review-evidence` boundary raised while the task is still
  `reviewing` names the one it expects, because no arbitration verb is legal
  from that status and an operator told only what is wrong has nothing left
  but a hand-edit:
  - `orchid jobs review-plan <id> --adopt-evidence` — re-pin the slots onto
    the engines that ACTUALLY filed valid, candidate-bound reviews. The exit
    for a plan that has re-routed under evidence already on disk. It refuses
    when there are fewer reviews than slots (a slot with no review is
    dispatched, not adopted) and when the filed reviews name fewer distinct
    engines than the plan they replace (adoption may record independence,
    never lower it), so it can settle the dead end without ever settling the
    independence requirement. Each slot it MOVES is pinned to the qualified
    engine id that slot's own envelope reported — so a name rebound to another
    publisher since the round was dispatched cannot leave the re-pinned slot
    matching nothing — and each slot it does NOT move (one covered by an
    envelope naming no engine) keeps its pinned key and depth untouched: this
    verb repairs the slots whose evidence moved, and re-derives nothing about
    the ones that did not.
  - `orchid jobs review-plan <id> --repin` — rebind the attempt to the live
    routing table, for a pinned slot whose engine can no longer be dispatched
    at all. Slots that already have a review of their own are frozen exactly
    as they are; only the unfilled ones move, and never onto an engine a
    frozen row already holds without the `session-independent` label that
    admits it.
  Either way the task keeps a legal, recorded exit; `orchid task advance <id>
  blocked --reason "..."` remains the universal one when neither fits.
- **A step no actor can be shown to cover is never dispatched.** Before a pass
  spawns anything, `orchid jobs prepare` refuses (exit 19) to bind a step to an
  engine whose manifest does not declare what that step's work needs — nothing
  minted, nothing spawned, no attempt spent. The driver journals the refusal
  against the task and records an `operator-handoff` boundary. Unlike exit 14
  this is never retried: no later pass makes the same actor able to do the same
  work. The requirements are kernel data, never a role descriptor a plugin
  ships (INV-16, `lib/capability.sh`), so an actor cannot declare a role that
  asks for nothing and route itself past the gate that way. Where the caller
  named the actor — `prepare --engine`, which is how a reviewer slot is
  dispatched — that question is asked *before* the role-eligibility walk, so a
  slot pinned to an engine both gates refuse is handed over rather than waited
  on. It orders two reports and waives neither: an engine that covers the step
  and is still ineligible for the role is refused there, at 14, in that gate's
  own words. That boundary names its remedy the same way every other
  reviewer-slot boundary above does: the config key the slot's engine actually
  resolved from (`role.reviewer`, `review.<tier>`, or neither — the fallback
  says so in words), **and** `orchid jobs review-plan <id> --repin`, because
  the attempt's plan is pinned and binding a capable engine does not by itself
  move a pinned row.
  Where NO actor was named — the ordinary dispatch, which resolves the role's
  failover chain — the same question is asked of every entry in that chain,
  *before* resolution runs. A chain that yields nobody
  normally exits 14, and waiting is right when it emptied over a rate limit,
  an unproven fallback or a plugin not installed yet; it is wrong when every
  entry is short an atom the step needs, because no window reopens and the
  walk would meet that task every pass forever. So that case answers 19 too,
  and only that case: one entry the table does not refuse leaves the chain the
  wait it was — which is also why asking first can refuse no dispatch that
  would have happened, and why the exit-19 refusal is emitted *alone* rather
  than beside the exit-14 wait line the caller must not act on. This is the arm
  most shortfalls actually take — a built-in
  role's `requires=` and its step's price are the same atoms, so the role gate
  refuses before any actor resolves.
  Resolution itself is told which step it is picking for, so an entry that
  cannot perform the work is failed over rather than settled on: a role-eligible
  but incapable primary must not shadow a capable, capsuite-proven fallback
  standing behind it in the same chain. A fallback still activates only once
  `orchid plugins test` has proved it for the role — skipping an entry is not
  promoting the next one past the failover rules.
- **A wake nobody can perform is handed over, not polled.** The `orchestrate`
  step reaches no `jobs prepare` at all: the tick builds its own request
  document, and the pump decides whether to run it from a dry availability
  probe that prints `no capable orchestrator available` and exits 0. That is
  the right report for a rate limit or an unproven fallback and the wrong one
  when every engine in `role.orchestrator`'s chain is short `shell` or `git` —
  then it is one line per staleness window forever, with the judgment boundary
  the driver just raised left for an orchestrator that is never coming. Both
  runners classify the chain before the wake: the tick exits 19 instead of 14,
  and both record ONE operator hand-off (`orchid notify` — journalled,
  then `BLOCKERS.md`, deduped against that blocker so a hundred passes raise
  one) and print the refusal without the poll line. The tick records it too
  because a scheduler may be pointed straight at it, and a 19 into a crontab is
  a silence; the two share the sentence and the receipt, so whichever runs
  first records the fact and the other finds it rather than restating it.
  Neither overwrites the boundary record; `orchid drive` owns that, and the
  record names the task actually waiting.
- **A refused launch is journaled by the launcher, wrapped or not.**
  `runners/orchid-launch` writes the hand-off sentence against the task the
  moment `orchid jobs prepare` answers 19, because not every launch has a
  driver behind it: `PLANNING` runs `runners/orchid-launch plan plan_critic
  critique` and its hook points from the orchestrator itself, and you may drive
  THE TICK's launcher calls by hand. `orchid drive` still records the
  `operator-handoff` boundary on the passes it ran the launcher, and finds that
  same line already journaled rather than writing a second one. The reserved
  `plan` id has no task file and so no counter and no boundary — its record is
  the journal, read with `orchid journal show --task plan`.
- **The operator hand-off is a named stop, not a habit — and it resumes.**
  Where `handoff_before_verify` is `required`, or where the engine that built
  the candidate cannot be routed its mechanical steps at all — in a running
  repository that means an implementer that resolves to no installed manifest,
  since the role gate already refuses one declaring no `shell` — a pass
  reaching a `testing`
  task compares `handoff_ack` against the task's current `candidate_sha` and
  against `HEAD` of the tree it would verify, before it runs anything. All
  three equal: it verifies, exactly as it always did.
  Anything else: it stops at an `operator-handoff` boundary and exits 16,
  WITHOUT running `orchid verify` — a driver that verified first would fail a
  candidate whose remaining work nobody in that round was able to do, spend
  one of its rework attempts on it, and send the implementer back a failure
  it cannot act on. Both halves of the resume rule fall out of that one
  comparison, with no state of the driver's own: a second pass after an
  acknowledgement proceeds (so the stop is not a loop), and a second pass
  without one stops again (so it is not a walk-past). The boundary is
  operator-only, so the pump wakes no model and one `orchid notify` blocker
  per distinct record reaches a human instead. The operator prerequisite is
  checked immediately after it, on the same pass and by the same rule; the
  hand-off is raised first because its ack moves `candidate_sha` and would
  otherwise expire a prerequisite ack taken before it.
- **A finished run is handed off, not left polling.** When every task is
  `done`, the driver takes COMPLETION's step 1 itself (`orchid run advance
  accepting --reason "all tasks done"` — a transition whose whole
  precondition is that fact) and stops at a `run-complete` boundary for the
  rest: requirement coverage, the operator's acceptance commands, and the
  evidence file `orchid run accept` demands are judgment work. Without it a
  finished headless run would poll forever — every pass clean, exit 0,
  `run_status` never leaving `running`, nobody woken to notice it is over.
  The count is taken from the statuses the walk READ, so the pass that
  finishes the last task exits 0 on its own progress and the boundary is
  raised by the next one. Against a `brokered` orchestrator that boundary is
  a blocker for a HUMAN, not a hand-off to a model: the broker refuses
  `orchid run accept`, so no woken model can close the run.
- **The lease is refreshed THROUGH the pass's long steps, not just at its
  ends.** `orchid verify` runs the task's whole suite in the pass's own
  foreground, and `orchid merge` re-runs it on the integration checkout.
  Steps 1 and 5 above refresh the lease at the two ends of a pass, which is
  enough only while everything between them is quick — on a repository whose
  suite runs longer than `pump_stale_s` (default 900) the running pass's own
  lease would read as stale, a second pump would start and fence a fresh
  epoch, and the first pass would then die on the next verb's `epoch_require`.
  No pass could ever complete there. So the driver refreshes the lease
  immediately before and after each of those two steps and keeps a background
  heartbeat refreshing it throughout, at a third of the staleness window.
  `orchid run refresh-lease` is a named verb and takes no verb lock, so this
  neither writes state outside a verb nor can deadlock against the step it
  covers.
- **One counter for the escalation ladder.** The prose ladder in step 2
  spends its first occurrence on a free relaunch that touches no counter; a
  driver has no per-attempt memory outside `.orchid/`, and a private
  retry-counter file would be exactly the un-verbed cross-process state this
  file forbids. So every dead/stalled/timed-out job goes through `orchid task
  infra-fail` — the kernel-owned counter, which journals its own reason and
  auto-blocks at `infra_max` — and relaunches for as long as that cap has not
  blocked the task. Same ladder, same bound, one counter, no hidden state.

## RESUME

1. `orchid run resume` — fences a new epoch; if the previous run's lock is
   held by a dead or foreign owner past `lock_break_s`, this call breaks it
   and journals the break itself.
2. `orchid jobs check`.
3. `orchid jobs reconcile`. (Note: this is check-*then*-reconcile, the
   reverse of THE TICK's reconcile-first ordering in step 2 there — at
   resume there is no in-progress tick a stray "dead" report could
   falsely escalate against, so `check` killing anything genuinely
   stalled/timed-out from before the crash, first, is safe here.)
4. `orchid status --explain`.
5. Capsules: for every task not `done`, load its bounded context before
   judging anything — `orchid task show <id>` (full frontmatter and body),
   `orchid journal show --task <id>` (that task's decision capsule, backed
   by `.orchid/runtime/journal-index/<id>`), `orchid journal tail -n 20`
   (recent run-wide context), `.orchid/context.md`, and the ACTIVE lessons
   (`orchid lessons list --active`) — the same run-wide memory every
   request pack already carries, under the same explicit byte budgets
   (docs/specs/kernel.md, Memory & resumption). Never re-scan the whole
   journal file by hand.
6. For every task in `testing`, re-read the operator hand-off from the task
   and its tree rather than from memory: `handoff_ack` equal to
   `candidate_sha` and equal to `HEAD` of the tree that would be verified
   means this candidate's execution-requiring mechanical steps were already
   performed, and the walk proceeds to verification; anything else means they
   were not (or were performed against a candidate that has since moved, or a
   commit has landed since the acknowledgement), and the walk stops there
   again. Read the operator PREREQUISITE the same way and in the same place —
   `prerequisite_ack` equal to `candidate_sha` on a task that declares an
   `operator_prerequisite` — for the same reason: nothing but those fields
   records either stop. Nothing else records this, which is the point —
   a resumed session, a second driver pass and a second operator all read the
   same two fields and the same `HEAD` and reach the same answer. `orchid status
   --explain` prints `awaiting-operator-handoff` or
   `awaiting-operator-prerequisite` for the outstanding cases, and
   `orchid run boundary show` names any boundary the last pass left recorded.
7. Resume THE TICK above, starting at step 3 (the state-machine walk), now
   that jobs/state have been reconciled and the capsules are loaded.

## HEADLESS OPERATION

**Machine-local acknowledgement is mandatory.** Before either headless entry
point may act, the operator must run:

```sh
orchid trust unattended <repo> --reason "<why this target is trusted for unattended execution>"
```

The JSON record and identity anchor are outside the repository. Validation
binds Git's shared common-directory device/inode, the inode of Git's stable
untracked `description` witness, the root commit(s) reachable from `HEAD`, and
the trust-policy version compiled into Orchid. The anchor is an outside hard
link to that witness; it keeps the witness inode allocated after repository
replacement, so reuse of the common-directory device/inode cannot resurrect
an acknowledgement. This requires the trust store and common directory to be
on one filesystem. Linked worktrees share an acknowledgement and a
same-filesystem move preserves it; a clone, copy, recreated/replaced `.git`,
root-history replacement, or policy-version change does not. Repository
content, origin URLs, Git config, and `orchid.config` cannot grant it.
With no identity-keyed acknowledgement candidate, inspection stops after
side-effect-free common-directory identity discovery, reports root
verification as pending, and performs no Git query, worktree enumeration,
history walk, or scratch-file creation. Explicit acknowledgement and an
existing structurally eligible candidate take the bounded local-only history
verification path.
Identity queries ignore ambient Git repository-selection or object-view
variables, disable replacement refs, legacy grafts, and shallow boundaries,
and do not lazy-fetch missing history. A shallow repository therefore cannot
be acknowledged until its commit ancestry is locally complete.
Trust-boundary paths are captured and compared losslessly, including literal
newlines. Store containment is checked against the physical checkout marker
rather than a configurable Git worktree path. A linked marker must point back
to the exact caller-selected path registered under the common directory;
copying a linked checkout and its `.git` pointer is denied. A `HOME` layout
that resolves the trust store inside the target or any registered sibling
worktree is refused. The JSON record must be an operator-owned, single-link
regular file without group/other write permission; record symlinks, hard-link
aliases, and non-files fail closed. `orchid trust show <repo>` displays the
decision, anchor binding, and operator-authored reason/timestamp; `orchid
trust revoke <repo>` removes the outside record and anchor (or a rejected
symlink itself, without following it). Revocation resolves that record with
the same bounded on-disk identity derivation and no Git version, ref,
history, object, root, or scratch check, so an unsupported Git or a
mismatched, shallow, object-missing, or corrupt-history repository can never
strand an acknowledgement that would apply again later.
Root verification is never cached: acknowledgement and every later gate re-walk
the reachable history and re-hash each commit's exact stored payload, so a
rewritten, removed, or corrupted object is re-detected even when refs and the
anchor are untouched. Reuse keyed on identity plus `HEAD` would miss exactly
that, and no portable filesystem witness can prove an object store unchanged
more cheaply than reading it. `show` reports `root_verification: walked`; the
cost is bounded by batching the walk, not by skipping it.
A scheduled invocation's output is discarded by the scheduler and the
repo-local service log is not opened until after the gate, so its refusals are
also appended to `~/.orchid/unattended-trust/refusals.log`, which `orchid
doctor` surfaces. A missing `jq` keeps the gate closed and names the missing
tool rather than reporting the record as malformed.
Interactive sessions, planning, manual verbs, and read-only commands do not
require or create this record.

**Qualify a repository before acknowledging it.** The acknowledgement opens the
gate; it does not make the target drivable. Three failure modes only appear on a
real codebase, and each one stalls a headless run with no actor able to move it:

- a verification suite whose single run approaches `pump_stale_s` — the driver
  holds no lease refresh across a synchronous verification and the merge
  re-verifies after its rebase, so one pass costs roughly twice that duration
  with the lease untouched, after which another pump treats the run as
  abandoned;
- an implementer that cannot execute a command, for which running a repository
  script and changing a file mode are operator hand-offs no in-loop actor can
  perform;
- a committed artifact derived from the tree's exact content, which the merge
  rebase invalidates and which then has no in-loop actor able to regenerate it.

`scripts/beta-qualify.sh` probes all three locally and records anonymized
evidence — check identities, durations, exit codes, and outcomes, never
repository content. It writes nothing of its own into the target; the one
thing it executes there is the target's own configured `verify=` command, run
once in place to time it (`--no-run-verify` skips it and records that probe as
`not-tested`). It never acknowledges trust on the operator's behalf, requires
no acknowledgement of its own, and never contacts a remote; the in-place run is
disclosed on stderr as it happens instead. Gating qualification on the record it
exists to inform would invert this order and would leave the gate open on a
repository that then failed to qualify — `docs/specs/operations.md` records that
decision and the alternatives rejected with it. What it cannot settle
locally, including the inbound half of the blocker round trip, it records as
`not-tested` with the reason rather than as a pass. See
[docs/beta-qualification.md](./docs/beta-qualification.md).

The interactive session above is one front-end for this file;
`runners/orchid-pump` (cron/launchd-invoked, or run by hand) is the other. The pump
never builds a prompt and never reads an envelope's contents — only exit
codes — and it does at most one thing per invocation. Every outcome below
other than a hand-off is a no-op, exit 0 — a cron poll finding nothing to do
is normal, never an error:

- **Trust denied:** after the side-effect-free uninitialized, split-brain,
  and already-complete checks, the pump refuses before it creates
  `runtime/`, drains the outbox, or hands off. The tick independently checks
  the same record before `run resume` or any spawn, so invoking the tick
  directly is not a bypass. Service installation is gated too; service
  status/uninstall remain available so an operator can inspect or remove a
  schedule after revocation.

- **Uninitialized, or the run is already `complete`:** the pump exits
  immediately, touching nothing (it will not even create `runtime/` on an
  uninitialized repo).
- **No lease yet, and `run_status` isn't `running`:** a run still in
  `planning` (PLANNING above) has never written `runtime/lease.json` at
  all — there is no interactive session to have been abandoned, so a
  missing lease here is not staleness, just "nothing to wake." The pump
  prints `pump: run not running (<run_status>), no lease yet` and exits 0
  without touching anything. (A missing lease under `running` is instead
  treated as maximally stale — an interactive session that crashed before
  its first lease write — and falls through to the staleness check below;
  `accepting`/`blocked` are reached only via a prior `running` phase that
  already wrote one, so a lease is never actually missing there.)
- **Lease fresh:** `runtime/lease.json`'s `refreshed_at` is younger than
  `pump_stale_s` (config, default 900) — the pump exits without acting. This
  IS the mutual-exclusion mechanism between an interactive session and the
  pump: lease STALENESS, not a lock file. An interactive session already
  refreshes the lease every pass (THE TICK step 1 and step 5 above), so the
  pump treats the run as abandoned (crashed, or a session that quit without
  a graceful stop). A live but delayed session can still cross that time
  threshold. Combined with epoch fencing — `orchid run
  resume` mints a fresh epoch on every invocation, interactive or headless —
  a tick that wakes a stale run and a session that was actually still alive
  can never both mutate state: whichever call mints the newer epoch wins,
  and the other's next verb call refuses under a stale one (INV-02).
- **No capable orchestrator:** the pump probes `resolve_role_available
  orchestrator` itself (discarding the resolved engine name, keeping only
  the go/no-go) before ever handing off; a `no eligible engine` verdict here
  means the pump exits 0 and simply tries again next invocation, rather than
  crash-looping a cron job over an outage it cannot fix.
- **Deterministic drive (the normal case, v1.1):** the pump runs
  `runners/orchid-drive` — one full deterministic pass of THE TICK, no model
  involved — and reads only its exit code. Exit 0 means the pass completed
  with nothing waiting on a human: the pump prints `pump: deterministic drive
  completed the pass, no judgment boundary` and exits 0, having spent no
  quota at all. Any exit other than 0 or 16 is a real failure and propagates
  verbatim.

- **Judgment boundary → and only then, an LLM:** exit 16 alone is not enough.
  The pump additionally re-reads the boundary through its own verb (`orchid
  run boundary show`, itself exiting 16 when a record exists). BOTH must
  agree before an orchestrator is woken — the exit code says "policy
  stopped", the record says which task and why, and a boundary the driver
  reported without recording (a state no orchestrator is entitled to resolve
  autonomously) deliberately fails this second test. A third fact is then
  derived from the record: some verb must settle this boundary, the resolved
  orchestrator adapter's `command_surface` must admit that verb, and the
  named task's current status must let it run (see "Could settle is never a
  property of the kind alone" above). A boundary failing any of those ends
  the invocation with `pump: judgment boundary [<kind>] is operator-only —
  not waking an orchestrator`, exit 0: it would recur identically on every
  pass until a human acted, and the driver has already raised the blocker
  that reaches one. Ending the INVOCATION is not ending the RUN — the pass
  it just ran advanced every other task, and the next scheduled one will do
  the same while the boundary waits. The pump drains `runtime/outbox/` both
  before and AFTER that pass, so a blocker the pass itself raised is sent
  through the configured channel in the same invocation that found it,
  rather than waiting for whichever later invocation happens to drain next.
  With all three satisfied, the
  pump probes `resolve_role_available orchestrator` and `exec`s
  `runners/orchid-tick` — the only path that reaches it, since a pass the
  deterministic policy can resolve on its own goes through
  `runners/orchid-drive` above and never wakes a model — which resolves that
  role again (exit 14 propagates verbatim, for the next
  pump pass to retry), prints the resolved engine's `command_surface` label
  (`brokered` or `soft`, from its manifest), and spawns it SYNCHRONOUSLY with
  an `orchestrate` request. The adapter reports which actions it took
  (`.actions[]`) plus a `.summary` in its envelope. The tick marks the ledger
  from that envelope's status exactly like `jobs reconcile` marks any other
  job's engine, and exits non-zero whenever the status wasn't `ok` — so a
  cron scheduler's own failure signal reflects a genuinely bad tick, not a
  benign no-op.

**The brokered command surface.** An orchestrator woken for a boundary has
one job: read the record, read the task and its reviews, record one decision.
An adapter whose vendor CLI supports an enforceable per-command allowlist
declares `command_surface=brokered` in its manifest and restricts its
orchestrator to exactly one executable —
`runners/orchid-orchestrator-command`, a default-deny, argument-validating
broker. It admits a short list of exact read forms (`task show`, `task list`,
`status [--explain]`, `jobs ls [--all]`, `jobs review-plan`, `journal tail`,
`journal show`, `lessons list --active`, `run boundary show`), the one
judgment-result verb
(`orchid task arbitrate`), `journal add`, `lessons add`, `notify`, and `run
boundary clear`; it refuses `trust`, `service`, `config`, `plugins`, `init`,
`start`, every tier-2 runner, every vendor CLI, and anything a shell would
interpret, with exit 17. It validates argv and then `exec`s the dispatcher
with the caller's own argument vector — it never builds or evaluates a shell
string, so there is no quoting seam to escape through. An adapter whose CLI
offers no equivalent restriction declares `command_surface=soft`; that is an
honest label, not a capability, and an absent label reads as `soft`. Both
kinds remain gated behind the machine-local unattended acknowledgement above:
a brokered surface narrows what a woken model may run, it is not OS
containment.

**Exactly what `brokered` does and does not enforce.** It is a restriction on
COMMAND EXECUTION only. The shipped brokered adapter runs `claude -p
--permission-mode acceptEdits --allowedTools "Bash(<broker>:*)"`, so the
vendor CLI genuinely refuses every command that is not that one executable.
It does NOT restrict FILE WRITES: `acceptEdits` auto-approves the vendor's
own file-write tools, so the woken model can create and edit files anywhere
the process can reach — including paths under `.orchid/`, and, when
`ORCHID_ROOT` sits inside the driven repository (the layout Orchid dogfoods
itself in), including the broker script and the rest of the Orchid tree. Nor
does it restrict reads. "Never hand-edit anything under `.orchid/`" is a
PROMPT instruction to the orchestrator, not an enforced boundary; the
enforced boundaries around a woken orchestrator are the command allowlist,
the launcher's environment allowlist, `/dev/null` stdin, the private output
path, and the unattended-trust acknowledgement.

**High-risk arbitration prefers a specific engine.** Arbitration itself is
never a launched job — it is inline judgment (Preamble; kernel.md's
"≤~10-line arbitration trivia") performed by whichever engine is CURRENTLY
running the tick, interactive or headless. For a `high` risk_tier task, that
judgment should come from the FIRST entry of `role.arbiter`'s resolved chain
(`orchid config list`) when at all possible — under headless operation the
engine the pump happened to wake this pass is not guaranteed to be that
preferred one. When it isn't: wait rather than let a lesser-preferred
engine arbitrate immediately — leave the task in `arbitrating`, let the run
idle on it — for up to `arbiter_wait_s` (config, default 14400 = 4h) of
wall-clock time, before a FALLBACK arbiter engine (the chain's next entry,
or simply whichever engine is actually ticking once the wait is spent) may
decide instead. Journal the outcome either way: `orchid journal add --task
<id> --kind arbitration "waited <n>s for <preferred>, arbitrating as
<actual>"` when a fallback ends up deciding, so a successor can always see
whether this attempt's judgment came from the preferred engine or a
timed-out fallback rather than having to infer it from which engine happened
to be running.

## COMPLETION

Once `orchid status --explain` shows every task `done`:

1. `orchid run advance accepting --reason "all tasks done"`. Under `orchid
   drive` this step is already taken for you: a pass that reads every task as
   `done` makes exactly this call and then stops at a `run-complete`
   boundary, which is what wakes an orchestrator for steps 2–3 (the pump
   never wakes one for a run it believes is still working). Arriving here at
   `run_status: accepting` with the boundary already recorded is therefore
   the normal headless path, not an anomaly.
2. Run acceptance checks: requirement coverage against
   `.orchid/requirements.md` plus whatever end-to-end acceptance command(s)
   the operator configured. This is an orchestrator-executed check, not a
   single verb — `orchid verify` is task-scoped, not run-scoped. Write the
   result to an evidence file.
3. `orchid run accept --reason "..." --evidence <path-to-evidence-file>` —
   requires `run_status: accepting`; copies the evidence file into
   `.orchid/reviews/acceptance.log` and sets `run_status: complete`, then
   COMMITS the run's entire durable `.orchid/` state onto the integration
   branch itself (the same temp-worktree + CAS transaction `orchid plan
   apply` uses, via `orchid_commit_durable`) — a completed run's record is
   never left uncommitted-only (v1-m4 ledger, the r-001 journal-loss
   incident). This is the *only* path to `complete`: `orchid run advance complete` is refused
   unconditionally, from any state, so `complete` is unreachable without an
   evidence file backing it.

   If that commit itself fails (a concurrent commit landed on the
   integration branch first — the CAS conflict), `run accept` dies but
   `run_status: complete`, the evidence copy, and the journal entry are
   already on disk — re-running the EXACT SAME `orchid run accept
   --reason ... --evidence ...` call is the real recovery: it recognizes
   `run_status` is already `complete`, skips the state transition and
   evidence copy (never redone), and re-attempts only the durable commit,
   journaling `intervention` ("accept commit retried after CAS failure").
   A further call once that commit has actually landed dies cleanly
   instead ("already accepted and committed") — there is nothing left to
   retry.
4. `orchid run release-lease` — the clean-session-exit affordance (v1-m4):
   writes `released: true` into `runtime/lease.json` so nothing watching
   this run mistakes your own still-fresh lease for a live session. Both
   `run new`'s freshness guard and the pump's own lease-staleness check
   (HEADLESS OPERATION above) treat a released lease as immediately stale,
   regardless of how recently it was last refreshed — closing the gap where
   an operator previously had to wait out `pump_stale_s`, or hand-backdate
   `lease.json`, before `run new` or the pump would touch this run again.

## Known documentation discrepancies surfaced while writing this file

- **`infra_failures`** — kernel-owned per `orchid task set`'s deny-list;
  `orchid task infra-fail` (see THE TICK, step 2) increments it and
  auto-blocks at `infra_max`, closing the counter half of
  `docs/specs/kernel.md`'s guardrails table. The other half of that same
  table — "repeated infra failures → engine marked unavailable" — is closed
  differently than the table's wording suggests: not by `infra-fail` itself
  (it is purely task-scoped and never touches an engine record), but by
  `orchid jobs reconcile` marking the ledger (`runtime/engines.json`) from
  every reconciled envelope's status, automatically, on every pass — save for
  a `failure_kind: "capability"` refusal, which is the engine declining work
  outside its contract and marks nothing against it; see THE TICK step 2's
  Failover paragraph. No longer aspirational.
- **`implementer_engine_id`** — present in the task schema/template
  (`templates/task.md`); as of this milestone, `orchid task advance <id>
  testing` populates it (from the reconciled implement envelope's `.engine`
  field, stripped of its `orchid/` prefix) the first time an attempt leaves
  `implementing`. This protocol's review-independence comparisons (`orchid
  jobs review-plan`, backed by `lib/review.sh`'s
  `review_implementer_engine`) read this field directly, falling back to
  `resolve_role <repo> implementer` (first-of-chain) only for a task that
  hasn't reached `testing` yet.
- **`orchid task unblock`** — `docs/specs/kernel.md:525` used to document it
  as `orchid task unblock <id> [--guidance "..."]`, drifted from its own
  state table two hundred-odd lines earlier (`docs/specs/kernel.md:239`),
  which already gave the real flag: kernel.md self-contradicted itself on
  this point. The actual verb (`libexec/orchid-task`) only accepts
  `--reason`, and dies with "unblock requires --reason" if given anything
  else in that position. This protocol uses the real flag, `--reason`,
  throughout; kernel.md:525 has since been corrected to say `--reason` too
  — kept here only as the historical record of where the drift was caught.
