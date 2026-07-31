# Troubleshooting

Every entry below is a **real incident** hit while dogfooding orchid on
itself (`docs/dogfood-notes.md`'s F-numbered findings), with the exact
remedy verb that fixed it — not a hypothetical.

## Rate limits

**Symptom:** an engine's calls start failing with a `rate_limited` envelope
status, or `orchid status` shows an engine as unavailable.

Orchid never treats a rate limit as a run failure: `orchid jobs reconcile`
marks the engine `rate_limited` in `runtime/engines.json` for a window sized
by `rate_limit_backoff_s` (config, default `3600`) or the envelope's own
`retry_after`. Dispatch falls back to the role's next chain entry once it
has passed the capability suite (`orchid plugins test <engine> <role>`); if
no fallback is eligible, the affected task's jobs simply wait — a rate
limit pauses one engine, never the run. No operator action is required;
`orchid status` (`== engines` section) explains what's rate-limited and
until when. To force a retry sooner (e.g. you know the vendor's quota reset
early), there is no override verb — the ledger window is time-based by
design, so waiting it out or configuring a fallback chain
(`role.<role>=<primary>,<fallback>`) is the supported path.

## Resume (crash / restart)

**Symptom:** the interactive session died mid-run (crash, closed terminal,
laptop sleep) and you're picking a run back up.

```sh
orchid run resume
orchid jobs check
orchid jobs reconcile
orchid status --explain
```

`orchid run resume` fences a fresh epoch and, if the previous run's lock is
held by a dead or foreign owner past `lock_break_s` (config, default `900`),
breaks it — journaled. `jobs check` kills anything genuinely
stalled/timed-out from before the crash; `jobs reconcile` lands any
already-finished envelopes. Never re-adopt an ambiguous process by hand —
job identity is `job_id` + pgid + start-time; an unidentifiable one is
confirmed dead and relaunched cleanly. See PROTOCOL.md's `RESUME` section
for the full capsule-loading walk a resuming session performs before
touching any task.

**Headless equivalent:** you don't need to do any of this by hand at all —
`runners/orchid-pump` (installed as a service, see
[quickstart.md](./quickstart.md)) detects an abandoned run itself (a lease
older than `pump_stale_s`, default `900`) and runs the exact same resume
sequence via `runners/orchid-tick` on its own.

## Stale locks / lease

**Symptom:** a verb refuses with a lock-held error, or `orchid status`
shows a lease that looks old.

- A **verb lock** (per-verb transactional locking) that a dead process still
  appears to hold is broken automatically by the next verb invocation once
  its owner fails the liveness check (dead pid, pid-start-time mismatch, or
  foreign hostname) **and** it's older than `lock_break_s` — nothing to do
  by hand; `orchid run resume` breaks the coarser run-lock the same way.
- A **stale lease** (`runtime/lease.json`, the orchestrator's own heartbeat)
  is not a lock file — it's the pump's mutual-exclusion signal
  (`pump_stale_s`). If you're ending a session cleanly and want the pump (or
  `orchid run new`) to treat this run as done-with immediately, rather than
  waiting out `pump_stale_s`:

  ```sh
  orchid run release-lease
  ```

  This writes `released: true` into the lease so both the pump and `run
  new`'s freshness guard treat it as immediately stale, regardless of how
  recently it was refreshed. PROTOCOL.md's `COMPLETION` procedure ends every
  run with it.

## Blocked tasks

**Symptom:** a task sits in `blocked` (rework attempts exhausted, a genuine
question raised via `orchid notify`, or an operator-invoked stop).

```sh
orchid task show <id>              # read the blocking reason + BLOCKERS.md
orchid journal show --task <id>    # the task's decision capsule
orchid answer <qid> <choice>        # answer an open question (if one exists)
orchid task unblock <id> --reason "<qid>: <answer text>"
# -- or, when nothing needs to change and it should just try again:
orchid task retry <id> --reason "..."
```

`orchid task unblock`/`orchid task retry` are validated transitions:
guidance is recorded into the task body and the intervention is logged in
the journal — never hand-edit a task file to un-stick it. If the block came
from a raised question (`orchid notify`), answer it first
(`orchid answer <qid> <choice>`, `--nonce <n>` required once
`answer_allowlist` is configured — see
[docs/engines/openclaw.md](./engines/openclaw.md#inbox-hardening-orchid-answer))
so the guidance text exists before `unblock` folds it in.

## Stale checkout

**Symptom:** `orchid doctor`/`orchid status` warns `integration checkout is
stale`, or a commit you just watched land on the integration branch (from
another worktree, or a pump-driven `run accept`/`plan apply`) seems to have
silently reverted files that a passing task had just added.

This is the real incident behind it: a long-lived checkout of the
integration branch whose ref gets advanced from **outside** that checkout
(another worktree's commit, a headless tick) falls behind its own branch
pointer without its index/working tree ever refreshing. A naive `git add -A
&& git commit` from that stale checkout re-commits whatever stray staged
deletions the stale index still carries — a silent revert of real history.

**Never hand-commit `orchid.config` (or anything else) from a checkout of
the integration branch directly.** For a config change, use the safe path
instead:

```sh
orchid config commit --reason "..."
```

This stages exactly `orchid.config`'s current on-disk content into a
separate temp worktree of the integration branch and commits it there —
never touching your checkout's own git index. For any other reason you need
to refresh a stale checkout by hand:

```sh
git checkout HEAD -- . ':(exclude).orchid'
```

**Not** a bare `git checkout HEAD -- .` — that would also clobber any
uncommitted `.orchid/` run state sitting in that checkout.
`orchid doctor`/`orchid status` detect and name this condition
automatically (staged-deletion signature against the checkout's own
branch), before you ever act on stale state by accident.

## Split-brain checkout

**Symptom:** `orchid doctor`/`orchid status` warns `split-brain checkout`,
or the pump reports "run complete" on a checkout where you know work is in
progress.

`orchid init` restores your own branch when it finishes — durable `.orchid/`
state (`roadmap.md` and everything gated on it) lives only on the
integration branch. Running task verbs from your own branch happily builds
untracked `.orchid/` state there anyway (nothing else on disk distinguishes
it from a healthy repo, except that `roadmap.md` never landed) — and a pump
reading that checkout sees no roadmap and assumes there's nothing to do.

**The fix is to always work from the integration branch or a worktree of
it** — exactly what `orchid init`'s own final output tells you to run:

```sh
git worktree add ../<repo>-orchid <integration-branch>
cd ../<repo>-orchid
```

`orchid doctor` and `orchid status` both detect this condition (`tasks/` or
`journal.md` present, `roadmap.md` absent) and name it by exactly this
name, rather than leaving you to debug a missing roadmap.

## Pack overflow

**Symptom:** an engine launch fails with `input_overflow` on a review,
critique, or implement job.

`input_overflow` is a **task-shaping signal first**, not a config problem:
the correctness-critical parts of a job's input (task body, acceptance
criteria, the diff for reviews) are non-truncatable, and when they alone
exceed the job's byte budget, the launch fails rather than silently
truncating. The prescribed response is to **split the task**:

```sh
orchid task set <id> ...   # narrow scope, or split into <id>-a/<id>-b
```

journaled as a `plan_revision`. Two things reduce how often this happens
without touching a budget at all:

- A review/critique diff larger than `pack_diff_inline_max_bytes` (config,
  default `262144`) is automatically relieved when the resolved
  reviewer/critic declares `workspace_read` — the pack ships `diff.stat` +
  `symbols.txt` instead of the full patch (the engine reads the worktree
  itself). An inline-only engine (agy, hermes) gets no such relief; a
  diff that large still overflows for those engines specifically — route
  the task's `review.<tier>` chain to a worktree-capable reviewer
  (`codex-review`, `claude`) instead.
- `agy_max_bytes` / `hermes_max_bytes` are separate, smaller ceilings that
  make those two inline-only adapters fail closed **before** even invoking
  the vendor CLI on an oversized diff — same idea, engine-specific.

Raising `pack_budget_bytes` in `orchid.config` is a legitimate **operator**
decision (e.g. a repo whose tasks are genuinely large-diff by nature), but
it is deliberately not the first thing to reach for — task-splitting keeps
every engine's job bounded and reviewable regardless of which one is
bound to a role.

## See also

- [docs/configuration.md](./configuration.md) — every config key named
  above, with its default and which layer it belongs in.
- [docs/quickstart.md](./quickstart.md) / [docs/quickstart-greenfield.md](./quickstart-greenfield.md)
- `docs/specs/kernel.md`'s Guardrails & failure handling and Stuck-agent
  detection sections (the normative behavior this page explains in
  operator terms).
- `docs/dogfood-notes.md` — the full incident log these remedies are drawn
  from.
