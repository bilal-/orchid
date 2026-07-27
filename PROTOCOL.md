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
- **One active task.** v0 is single-reviewer and serial: at most one task
  holds a non-idle status — `implementing`, `testing`, `reviewing`,
  `arbitrating`, or `merging` — at a time. Everything else is queued
  (`pending`/`rework`), waiting on a human (`blocked`), or finished (`done`).
- **Single-reviewer policy.** Exactly one reviewer launch per attempt.
  Prefer an *engine-independent* reviewer: compare the task's recorded
  `implementer_engine_id` (`orchid task show <id>`) against the resolved
  `role.reviewer` binding (`orchid config list`). When they differ, dispatch
  as-is. When the resolver can only offer the same engine, the review is
  *session-independent only* (fresh session, same vendor) — label this
  explicitly and journal it (`orchid journal add --task <id> "reviewer is
  session-independent only: role.reviewer resolves to <engine>, same as
  implementer_engine_id"`) **before** dispatch. Never let a degraded
  independence pass silently.
- **Launch by role only.** Every spawn is `runners/orchid-launch <task-id>
  <role> <operation>`, where `<role>` is one of the roles bound in config
  (`role.implementer`, `role.reviewer`, ...). Never invoke an engine binary
  directly, and never invent a role that isn't a config key.

## PLANNING (pre-run, before THE TICK ever runs)

Before `run_status` leaves `planning`, there is no active task to walk — this
phase only drafts what the walk will later execute against:

1. `orchid requirements import <file>` — snapshot the operator-authored
   requirements into `.orchid/requirements.md` (refused once `run_status`
   has left `planning`: requirements are immutable after a plan exists).
2. Draft the roadmap: create each task with `orchid task create <id>
   <title>`, then fill in its spec via `orchid task set <id> <key> <value>`
   (acceptance criteria, `verification_commands`, `depends_on`, `risk_tier`
   with `--reason`, ...) — the resolved `role.plan_critic` engine (never the
   drafting engine) critiques the draft; revise and repeat until settled.
   `.orchid/roadmap.md` itself is the one piece of durable state this
   protocol permits editing directly while still in `planning` — it is only
   *committed* by the verb below, so drafting it (unlike every mutation
   THE TICK makes) is not yet a fenced, journaled transition.
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

**2. Reconcile, then check (reconcile-first ordering).**
`orchid jobs reconcile` drains everything already finished or quarantinable
into `.orchid/reviews/` *before* anything gets judged as stuck — a job that
completed since the last pass must never be mistaken for a dead one. Then
`orchid jobs check` reports `prepared|running|dead|stalled|timeout` for
whatever is left outstanding (`stalled`/`timeout` jobs are killed by `jobs
check` itself as it reports them).

Escalation ladder for a job `jobs check` reports `dead`, `stalled`, or
`timeout` that reconcile did **not** just turn into a reviews/ entry:

- *First occurrence for this attempt:* relaunch — re-run `runners/orchid-launch
  <task-id> <role> <operation>` for the same task/role/operation. This is the
  kernel's "one auto-retry"; it mints a fresh job identity and does not touch
  the task's `attempts` counter at all.
- *Second consecutive occurrence:* `orchid task set` denies writing
  `status|attempts|infra_failures|id|created|updated|schema` directly
  (kernel-owned — see `libexec/orchid-task`'s `set` case), so there is no
  verb that increments `infra_failures`; and neither `implementing` nor
  `reviewing` has a legal `rework` edge (see the state table below), so
  `task advance ... rework` is not available from either status either. The
  only kernel-legal escalation is: `orchid notify --task <task-id> "infra
  failure: job <job_id> <status> after one retry"` then `orchid task advance
  <task-id> blocked --reason "infra failure: <job_id> <status> x2"`. An
  operator resolves it with `orchid task retry <task-id> --reason "..."`
  once the underlying infra issue is fixed — `retry` moves `blocked→rework`
  without consuming an attempt.
- **Discrepancy, documented rather than papered over:** `docs/specs/kernel.md`
  ("Guardrails & failure handling") calls for `infra_failures++` as a
  separate counter from rework's `attempts`, with "repeated infra failures →
  engine marked unavailable" as a further escalation. No verb implements
  either today. The blocked+notify path above is the closest available
  approximation using only verbs that exist; it correctly avoids consuming
  an attempt (matching "infra_failures NEVER consume attempts"), but nothing
  currently counts *how many* infra failures a task or engine has
  accumulated.

**3. State-machine walk.**
Operate on the one active task, or the next one to dispatch. `orchid status
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

- **pending** (`ready-to-dispatch`: every `depends_on` entry is `done`):
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

- **reviewing** (`awaiting-review-envelopes`): apply the single-reviewer
  policy from the preamble, then `runners/orchid-launch <id> reviewer
  review`. Once step 2's reconcile produces a verdict for this task's review
  job: `orchid task advance <id> arbitrating --reason "review reconciled:
  verdict <verdict>"`. The escalation ladder for a dead/stalled/timeout
  reviewer job is identical to implementing's — `reviewing` has no legal
  `rework` edge either, so a repeat failure also goes to `blocked`.

- **arbitrating** (`awaiting-arbitration`): inline judgment, not a launched
  job — kernel.md is explicit that "the orchestrator implements nothing
  beyond ≤~10-line arbitration trivia" here. Read the task's review
  envelope(s) under `.orchid/reviews/<id>-a<attempt>-reviewer*.json` (and
  `orchid task show <id>` for `blocking_severity`), weigh the findings, then:
  - approve: `orchid task advance <id> merging --reason "..."`.
  - reject: `orchid task advance <id> rework --reason "..."` (add
    `--waive-attempt` when the rejection reflects an infra/tooling gap
    rather than an actual defect in the candidate).

- **merging** (`awaiting-merge`): `orchid merge <id>` and branch on its exit
  code — the verb already performs the resulting `task advance` internally
  in every case, so there is no separate advance call to make here:
  - `0`: merged; task is now `done`.
  - `1` (`validation_failed` / merge or rebase conflict): task is now
    `rework` (verb already journaled and advanced it). Continue the walk's
    rework handling on the next pass.
  - `5` (`rebase_rereview_required`): task is now back at `testing` with a
    fresh `base_sha`/`candidate_sha` and invalidated evidence (verb already
    journaled this with kind `rebase_review`). Classifying the coming
    re-review as delta vs. full is the orchestrator's call (kernel.md);
    record it if it isn't obvious from the diff size — `orchid journal add
    --task <id> "re-review scope: delta|full — <why>"` — then resume the
    `testing` branch of this walk on the next pass over the task.

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
3. `orchid jobs reconcile`.
4. `orchid status --explain`.
5. Capsules: for every task not `done`, load its bounded context before
   judging anything — `orchid task show <id>` (full frontmatter and body),
   `orchid journal show --task <id>` (that task's decision capsule, backed
   by `.orchid/runtime/journal-index/<id>`), and `orchid journal tail -n 20`
   (recent run-wide context). Never re-scan the whole journal file by hand.
6. Resume THE TICK above, starting at step 3 (the state-machine walk), now
   that jobs/state have been reconciled and the capsules are loaded.

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

- **`infra_failures`** — kernel-owned per `orchid task set`'s deny-list, but
  no verb anywhere increments it, and nothing marks an engine unavailable
  after repeated infra failures, despite both being called for in
  `docs/specs/kernel.md`'s guardrails table. See THE TICK, step 2.
- **`orchid task unblock`** — `docs/specs/operations.md` documents it as
  `orchid task unblock <id> [--guidance "..."]`; the actual verb
  (`libexec/orchid-task`) only accepts `--reason`, and dies with "unblock
  requires --reason" if given anything else in that position. This protocol
  uses the real flag, `--reason`, throughout.
