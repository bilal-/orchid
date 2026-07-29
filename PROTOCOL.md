# PROTOCOL.md — the v0 tick procedure

*Kernel-owned, engine-neutral. Written entirely in existing `orchid` CLI verbs
plus the one job spawner, `runners/orchid-launch`. Any front-end — a Claude
Code skill, a codex-driven tick runner, a human typing commands — executes
this procedure by running the commands named here, in the order given.
Front-ends are a convention (anything that executes this file via verbs), not
part of the architecture; this file never changes to suit one.*

## Preamble

- **You are the orchestrator.** Your only interface to run state is `orchid
  <verb>` and, for spawning engine work, `runners/orchid-launch`. Never
  hand-edit anything under `.orchid/` — no frontmatter, no journal, no
  roadmap — even when you can see exactly what line would need to change.
  Every mutation goes through a verb so it is fenced, journaled, and legal by
  construction.
- **Every judgment carries `--reason`.** The kernel only hard-requires
  `--reason` on a subset of edges (`orchid run advance`/`run accept` always;
  `orchid task advance` on `*→merging`, `*→blocked`, and `arbitrating→rework`
  specifically). This protocol requires it everywhere a human or a future
  resumer would otherwise have to guess *why*: every `task advance`, `task
  unblock`, `task retry`, and `notify` call in the walk below carries one,
  whether or not the verb itself would accept the omission.
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
  review-plan <id>` FIRST, every attempt: it prints the routing table for
  the task's CURRENT `risk_tier`, one line per required slot — `<slot>
  <engine>	<engine-independent|session-independent>` — computed from
  `role.reviewer`'s chain, the `review.<tier>` chain, engine discovery,
  role eligibility, and the ledger, all at once. Never re-derive this by
  hand. Launch each printed slot with `runners/orchid-launch <id> reviewer
  review --engine <slot-engine>` — `--engine` is exactly how a second (or
  third) slot's engine differs from whatever `role.reviewer` would resolve
  to on its own. Before dispatching ANY slot the table labels
  `session-independent`, journal it — the same rule as before, now applied
  per-slot: `orchid journal add --task <id> "reviewer slot <n> is
  session-independent only: <engine>, same as the implementer's"`. Never let
  a degraded independence pass silently, on any slot.
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

1. `orchid requirements import <file>` — snapshot the operator-authored
   requirements into `.orchid/requirements.md` (refused once `run_status`
   has left `planning`: requirements are immutable after a plan exists).
2. Draft the roadmap: create each task with `orchid task create <id>
   <title>`, then fill in its spec via `orchid task set <id> <key> <value>`
   (acceptance criteria, `verification_commands`, `depends_on`, `risk_tier`
   with `--reason`, ...). `.orchid/roadmap.md` itself is the one piece of
   durable state this protocol permits editing directly while still in
   `planning` — it is only *committed* by step 3 below, so drafting it
   (unlike every mutation THE TICK makes) is not yet a fenced, journaled
   transition.

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
3. `orchid plan apply --reason "..."` — commits every current `.orchid/`
   change (roadmap, tasks, requirements) onto the integration branch in one
   transaction, from whatever checkout you're in, without ever switching the
   operator's branch; journals `plan_revision`; advances `run_status:
   planning → running` once a plan actually exists.

Once `run_status: running`, PLANNING is over — THE TICK below is the only
procedure that touches task state from here on.

## THE TICK

**1. Refresh the lease.**
`orchid run refresh-lease` — first thing, every pass, so nothing watching
this run ever mistakes an in-progress tick for a stalled one.

**2. Reconcile, check, then gc (reconcile-first, check-before-reap ordering).**
`orchid jobs reconcile` drains everything already finished or quarantinable
into `.orchid/reviews/` *before* anything gets judged as stuck — a job that
completed since the last pass must never be mistaken for a dead one. Then
`orchid jobs check` reports `prepared|running|dead|stalled|timeout|budget-exceeded`
for whatever reconcile left outstanding (`stalled`/`timeout` jobs are killed
by `jobs check` itself as it reports them; `budget-exceeded` is report-only,
see below) — running `check` here, before anything reaps a manifest, is what
lets a job that died envelope-less between ticks (SIGKILL/OOM/adapter crash
before it ever wrote a spool envelope) still get reported `dead` and walk the
escalation ladder below, instead of being reaped silently before `check` ever
sees it. Only THEN `orchid jobs gc --older-than-s 0` — reaps only manifests
whose pid is *already* dead (never kills anything live; the `0` just drops
gc's normal age floor) — clears out whatever `check` just finished handling
(including the envelope-less case above), so a *later* pass never re-reports
the *same* already-dead job as `dead` and triggers a second, false escalation
for a failure this run already handled. gc runs strictly AFTER check has had
its pass over the same manifests, precisely so a dead job is reported and
escalated before it is ever reaped — reversing this order (gc before check)
lets gc silently vanish a job before `check` can ever call it `dead`, so the
escalation ladder's "first occurrence → relaunch" never fires and the
wallclock backstop (which only runs inside the manifest loop) goes silent
too — the task simply waits forever.

Escalation ladder for a job `jobs check` reports `dead`, `stalled`, or
`timeout` that reconcile above did **not** just resolve:

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
  `retry` moves `blocked→rework` without consuming an attempt.
- *`budget-exceeded`* (independent of the ladder above — it can fire
  alongside `running`, not just `dead`/`stalled`/`timeout`): the task's
  `wallclock_budget_s`, anchored at `started_at` (stamped by `task advance
  ... implementing`), has been exceeded. `jobs check` only reports this, it
  never kills on its own. `orchid notify --task <task-id> "task wallclock
  budget exceeded"` then `orchid task advance <task-id> blocked --reason
  "wallclock budget exceeded"`.
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
reconcile pass, no separate verb call needed. This is the OTHER half of
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
`ready-to-dispatch`, `awaiting-implementer-envelope`, `awaiting-verify`,
`awaiting-review-envelopes`, `awaiting-arbitration`, `awaiting-merge`,
`awaiting-rework-dispatch`, `blocked (see: ...)`) — use it to pick up where
the run left off rather than re-deriving state by hand.

```
pending → implementing → testing → reviewing → arbitrating → merging → done
                ↑            │         │            │
                └── rework (≤3) ───────┴────────────┤
                                                    └→ blocked
```

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
     record it: `orchid task set <id> worktree <path>`.
  2. Record the base: `orchid task set <id> base_sha <integration-branch
     HEAD sha>`.
  3. `orchid task advance <id> implementing --reason "dispatching: deps
     satisfied"`.
  4. `runners/orchid-launch <id> implementer implement` — this is the ONLY
     call made here. The launcher performs `orchid jobs prepare <id>
     implementer implement` itself, as its own first (tier-1) step, before
     it ever spawns anything. Calling `orchid jobs prepare` a second time
     beforehand would mint an orphaned manifest with `pid: 0` that never
     gets used — and `orchid jobs gc` can never reap it, since gc explicitly
     skips any manifest whose `pid` is still `0` (never launched). `orchid
     jobs prepare` is named in this protocol only to say: it happens, inside
     the launcher, and needs no separate invocation.

- **implementing** (`awaiting-implementer-envelope`): once step 2's reconcile
  reports this task's job `ok` (operation `implement`):
  1. `git -C <worktree> rev-parse HEAD` to read the new candidate.
  2. `orchid task set <id> candidate_sha <sha>`.
  3. `orchid task advance <id> testing --reason "implementer envelope ok"`.

  A quarantined envelope, or a `dead`/`stalled`/`timeout` job, follow the
  escalation ladder in step 2 (there is no legal `implementing→rework`, so a
  repeat failure goes to `blocked`, never `rework`).

- **testing** (`awaiting-verify`): `orchid verify <id>` — synchronous, run in
  the foreground of the tick itself; there is no job here, so nothing for
  `jobs check`/`jobs reconcile` to see.
  - PASS: `orchid task advance <id> reviewing --reason "verify passed"` (the
    kernel's own INV-11 gate independently re-checks that the evidence's
    `candidate:` line matches the task's current `candidate_sha` before
    allowing the transition).
  - FAIL: `orchid task advance <id> rework --reason "verify failed: see
    .orchid/reviews/<id>-verify.log"` (consumes an attempt unless
    `--waive-attempt` is also given — reserve that for a failure clearly
    unrelated to the candidate itself). After 3 non-waived rework attempts
    (`orchid task show <id>`'s `attempts` field), stop retrying
    automatically: `orchid notify --task <id> "attempts exhausted: see
    .orchid/reviews/<id>-verify.log"` then `orchid task advance <id> blocked
    --reason "attempts exhausted"`. The ≤3 cap is an orchestrator-enforced
    budget (kernel.md), not a kernel-verb gate — no verb refuses a 4th
    rework advance on its own.

- **reviewing** (`awaiting-review-envelopes`): apply the risk-tiered review
  policy from the Preamble — `orchid jobs review-plan <id>`, then
  `runners/orchid-launch <id> reviewer review --engine <slot-engine>` for
  every printed slot. Once step 2's reconcile has produced a verdict for
  every dispatched slot: `orchid task advance <id> arbitrating --reason
  "review reconciled: verdict <verdict>[, <verdict>]"`. The kernel now
  enforces the count itself: this advance refuses outright — "arbitrating
  requires N reconciled review envelope(s) for risk_tier <tier> (have
  <have>)" — until at least `review_required_count(risk_tier)` reviewer
  envelopes bound to the task's CURRENT `candidate_sha` have actually
  reconciled; a slot whose job is still `running`/`prepared`, or whose
  envelope was quarantined, never silently counts toward that number. The
  escalation ladder for a dead/stalled/timeout reviewer job is identical to
  implementing's, applied per slot — `reviewing` has no legal `rework` edge
  either, so a repeat failure on any one slot also goes to `blocked`.

- **arbitrating** (`awaiting-arbitration`): inline judgment, not a launched
  job — kernel.md is explicit that "the orchestrator implements nothing
  beyond ≤~10-line arbitration trivia" here. For a `high` risk_tier task,
  see HEADLESS OPERATION's arbitration-wait note below before judging: the
  preferred `role.arbiter` engine gets first refusal, bounded by
  `arbiter_wait_s`. Read the task's review envelope(s) under
  `.orchid/reviews/<id>-a<attempt>-reviewer*.json` (and `orchid task show
  <id>` for `blocking_severity`), weigh the findings, then:
  - approve: `orchid task advance <id> merging --reason "..."`.
  - reject: `orchid task advance <id> rework --reason "..."` (add
    `--waive-attempt` when the rejection reflects an infra/tooling gap
    rather than an actual defect in the candidate).

- **merging** (`awaiting-merge`): more than one task may sit in `merging` at
  once (it counts against `concurrency` like any other active status); per
  the Preamble, run `orchid merge` for only ONE of them this tick — any
  deterministic order (e.g. lowest task id) — and leave the rest for the
  next pass. This is a throughput choice, not a safety one: the verb's own
  compare-and-swap against the integration ref (below) would simply refuse
  a second concurrent merge anyway. `orchid merge <id>`, then branch on the
  task's **post-merge status** (`orchid task show <id>`) — never on the exit
  code alone: exit `1` is ambiguous between two different outcomes below, so
  the status is the only reliable signal. The verb already performs the
  resulting `task advance` internally in every case that actually changes
  status, so there is no separate advance call to make here:
  - status `done` (exit was `0`): merged.
  - status `rework` (exit was `1`, `validation_failed` / merge or rebase
    conflict; verb already journaled and advanced it): continue the walk's
    rework handling on the next pass.
  - status `testing`, with a fresh `base_sha`/`candidate_sha` and invalidated
    evidence (exit was `5`, `rebase_rereview_required`; verb already
    journaled this with kind `rebase_review`): classifying the coming
    re-review as delta vs. full is the orchestrator's call (kernel.md);
    record it if it isn't obvious from the diff size — `orchid journal add
    --task <id> "re-review scope: delta|full — <why>"` — then resume the
    `testing` branch of this walk on the next pass over the task.
  - status still `merging` despite a nonzero exit (e.g. the update-ref
    compare-and-swap lost to a concurrent merge): a persistent config/CAS
    problem, not a candidate defect — the verb journaled it but could not
    advance the task out of `merging` on its own. `orchid notify --task <id>
    "merge left task in merging: see .orchid/reviews/<id>-merge.log"` and
    leave the task in `merging` for a retry; never assume `rework` just
    because the exit code was nonzero.

**4. Blockers.**
Raise one with `orchid notify [--task <id>] "<text>"` (prints a `qid`).
Consume an answer by reading `.orchid/runtime/answers/<qid>.answer` directly
once it exists — there is no verb that reads an answer back; `orchid answer`
only ever writes one, for the human/channel side. Then resolve the task:
`orchid task unblock <id> --reason "<qid>: <answer text>"` when the answer
changes something about the plan (this records the text into the task body),
or `orchid task retry <id> --reason "..."` when nothing needs to change and
the task should simply run again.

**5. Before sleeping.**
`orchid status --explain` (so anything watching the terminal — or the next
resumer — sees exactly where the run stands) then `orchid run refresh-lease`
once more (so a concurrent resumer never mistakes this pass for a stalled
one).

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
   by `.orchid/runtime/journal-index/<id>`), and `orchid journal tail -n 20`
   (recent run-wide context). Never re-scan the whole journal file by hand.
6. Resume THE TICK above, starting at step 3 (the state-machine walk), now
   that jobs/state have been reconciled and the capsules are loaded.

## HEADLESS OPERATION

The interactive session above is one front-end for this file;
`runners/orchid-pump` (cron/launchd-invoked, or run by hand) is the other. The pump
never builds a prompt and never reads an envelope's contents — only exit
codes — and it does at most one thing per invocation: hand off to
`runners/orchid-tick`, which executes THE TICK exactly once (fencing a fresh
epoch and refreshing the lease via its own `orchid run resume` call, same as
RESUME step 1 above) and exits. Every other outcome below is a no-op, exit
0 — a cron poll finding nothing to do is normal, never an error:

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
  pump only ever wakes an ABANDONED run (crashed, or a session that quit
  without a graceful stop). Combined with epoch fencing — `orchid run
  resume` mints a fresh epoch on every invocation, interactive or headless —
  a tick that wakes a stale run and a session that was actually still alive
  can never both mutate state: whichever call mints the newer epoch wins,
  and the other's next verb call refuses under a stale one (INV-02).
- **No capable orchestrator:** the pump probes `resolve_role_available
  orchestrator` itself (discarding the resolved engine name, keeping only
  the go/no-go) before ever handing off; a `no eligible engine` verdict here
  means the pump exits 0 and simply tries again next invocation, rather than
  crash-looping a cron job over an outage it cannot fix.
- **Otherwise:** the pump `exec`s the tick, which resolves the orchestrator
  role via `resolve_role_available` (exit 14 propagates verbatim if that
  fails, for the next pump pass to retry) and spawns that engine
  SYNCHRONOUSLY with an `orchestrate` request — the adapter is expected to
  execute THE TICK's own verb sequence itself and report which actions it
  took (`.actions[]`) plus a `.summary` in its envelope. The tick marks the
  ledger from that envelope's status exactly like `jobs reconcile` marks any
  other job's engine, and exits non-zero whenever the status wasn't `ok` —
  so a cron scheduler's own failure signal reflects a genuinely bad tick,
  not a benign no-op.

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

1. `orchid run advance accepting --reason "all tasks done"`.
2. Run acceptance checks: requirement coverage against
   `.orchid/requirements.md` plus whatever end-to-end acceptance command(s)
   the operator configured. This is an orchestrator-executed check, not a
   single verb — `orchid verify` is task-scoped, not run-scoped. Write the
   result to an evidence file.
3. `orchid run accept --reason "..." --evidence <path-to-evidence-file>` —
   requires `run_status: accepting`; copies the evidence file into
   `.orchid/reviews/acceptance.log` and sets `run_status: complete`. This is
   the *only* path to `complete`: `orchid run advance complete` is refused
   unconditionally, from any state, so `complete` is unreachable without an
   evidence file backing it.

## Known documentation discrepancies surfaced while writing this file

- **`infra_failures`** — kernel-owned per `orchid task set`'s deny-list;
  `orchid task infra-fail` (see THE TICK, step 2) increments it and
  auto-blocks at `infra_max`, closing the counter half of
  `docs/specs/kernel.md`'s guardrails table. The other half of that same
  table — "repeated infra failures → engine marked unavailable" — is closed
  differently than the table's wording suggests: not by `infra-fail` itself
  (it is purely task-scoped and never touches an engine record), but by
  `orchid jobs reconcile` marking the ledger (`runtime/engines.json`) from
  every reconciled envelope's status, automatically, on every pass — see
  THE TICK step 2's Failover paragraph. No longer aspirational.
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
