# Dogfood run — wasiyyat-schedule-c, General forms (2026-08-11)

> Historical field report. Status and command output below remain as observed
> at the time. See [the r-002 retrospective](./r-002-retrospective.md) and
> [r-003 requirements](./plans/r-003-requirements.md) for the current
> closed/open split.

Second run in the same repo. Findings continue the numbering (F35–F49; previous
highest was F34 in `dogfood-2026-08-09-wasiyyat-schedule-c.md`).

**Repo:** same PHP 7.4 / MySQL production app — ~2,200 PHPUnit tests, 416
Playwright specs, gitignored multi-GB data directories.
**Run:** `r-002`, 16 tasks, reached via `orchid run new` after `r-001` completed.
**Status at time of writing:** in THE TICK, 13 of 16 tasks merged. F35–F43 were
written during PLANNING, which the run eventually cleared; F44–F49 come from the
tick and are about **recovery and diagnosis**, not planning.

Two headlines, one per phase. Planning's problems were about **the loop being
unobservable**: work completed and then silently discarded, and no way to tell
convergence from looping. The tick's problems are about **failure being
undiagnosable and unrecoverable**: when a job dies without an envelope, when an
operator records a wrong decision, or when a gate fails for a reason outside the
diff, there is no sanctioned path back to a runnable state and often no way to
learn what went wrong (F44, F46, F47, F48). Both phases share a root cause —
orchid models the happy path precisely and the failure path barely at all.

F49 is the counterpart on the success side, and arguably the most consequential
finding here: a gate that passes is reported identically whether it ran 25 tests
or 2,305. Thirteen tasks merged on green gates that were, on average, running
about 1% of the suite.

The sharpest example is the F47/F48 pair. A gate failed; the message pointed at
a verify log that was not there when it pointed at it; the actual cause was a
migration this very run had authored and nobody had applied. orchid attributed
it to the task's diff and sent a *correct* implementation back to rework twice.
Unattended, that is an infinite loop — the implementer cannot apply migrations,
and it is not even shown the error it is being asked to fix. (F47 as originally
filed overstated this and has been corrected in place; the log does get written,
just not usefully.)

Worth saying plainly: **the review layer is earning its keep.** Across this run
the reviewers caught three real defects that the full test suite passed clean —
a status-transition identity gap, a non-atomic CAS-plus-audit-log write, and a
PDF font that silently rendered Urdu member names as `???`. The findings below
are about the machinery around that layer, not the layer itself.

---

## F35 (job lifecycle, CRITICAL) — a job can do its whole task, log the results, then die without an envelope

The worst finding of this run, because orchid **threw away work it had already
completed**.

Critique attempt `a4` ran, produced eight complete findings, wrote every one of
them to its job log, and then exited without writing an envelope. `orchid jobs
reconcile` had nothing to land. From the outside the attempt simply never
happened.

The findings were sitting in the log the whole time:

```
$ grep '^FINDING:' .orchid/runtime/logs/j-e0-plan-a4-b068.log
high: T007 adds a seventh rate-limit table but still registers, counts, backs up, and readiness-tests only six
high: T008 and T016 give contradictory supersede rules ...
high: T010 simultaneously requires prefilled_rate to be re-derived and forbids re-derivation ...
... (8 total)
```

I recovered them with `grep` and applied them by hand. Without that they were
lost, and the operator would have re-run an expensive critique to regenerate
findings orchid already had on disk.

Attempt `a3` failed differently and just as silently: heartbeats kept arriving
while **CPU stayed flat**, ~1 second of CPU across five minutes of wallclock —

```
[hb 2026-08-11T05:18:12Z] engine pid 65301 cpu 0:00.85
[hb 2026-08-11T05:23:42Z] engine pid 65301 cpu 0:01.07
```

— then it exited, also with no envelope. `jobs check` has a `stalled` status but
it never fired: the process was alive, so liveness looked fine, and nothing
watches whether the process is doing any *work*.

**Two attempts out of four produced nothing recoverable through the verbs.**

**Suggestions:**
- **Salvage partial output.** If a job exits without an envelope but its log
  contains parseable results, reconcile should land them as a degraded envelope
  rather than discarding them. The engine already paid for that work.
- Treat "exited, no envelope" as a first-class failure with its own status, not
  as a job that silently never happened.
- Make `jobs check` use **filesystem progress in the task worktree** — not CPU
  delta — for `stalled`. **Correction, added later in the run:** I originally
  suggested CPU delta here, and then hit a false positive with it. A legitimate
  T010 implement job sat at ~9s of CPU across 40 minutes and looked identical to
  the dead `a3` attempt above; it was in fact working the whole time, and had 24
  modified files in its worktree to prove it. CPU is a bad progress signal for an
  agent whose wallclock is dominated by waiting on API responses. `git status`
  in the worktree separates the two cases cleanly; CPU is corroboration at best.
- Journal the exit code and the last N log lines when an envelope is missing, so
  the operator sees *something* without knowing to go grep runtime logs.

---

## F36 (observability, high) — nothing distinguishes "running" from "died twelve hours ago"

Directly downstream of F35, and the reason it cost so much time.

I reported to the operator that the critique was "actively working" and quoted
its recent findings. It had been dead for **twelve and a half hours**. The
findings I quoted were real — they were just stale, and the log gave no
indication of that. The operator had to tell me twice that nothing was
happening.

Everything needed to notice was available, but only if you already suspected:
the job pid was gone, `.orchid/reviews/` had no `a4` envelope, and the log's
mtime was 12 hours old. None of it surfaced through `orchid status`, which
happily showed a run in `planning` with no indication that its only in-flight
job had died.

**Suggestions:**
- `orchid status` should show outstanding jobs with **age and liveness**, not
  just presence — this is the process-table feature request from the r-001
  report, and this run is the second time its absence cost hours.
- A job whose pid is gone and whose envelope never landed should be visible in
  `status` as failed, immediately.
- Consider a staleness warning: "job X last wrote 12h ago".

---

## F37 (run rollover, high) — `orchid run new` inherits the previous run's branch state silently

`orchid run new` rolled `r-001 → r-002` cleanly and archived the old run. But the
integration branch kept **r-001's tip**, which meant the new run's base was:

- 18 commits behind `origin/main`
- carrying r-001's completed work, which was still an **unmerged open PR**
- missing the new run's requirements document and its fixture files entirely

Every task in r-002 would have branched from that — building an unrelated
feature on top of an open PR, against stale main, with the spec's authoritative
source documents absent from the tree the implementer can see.

Nothing warned. It surfaced only because the plan critic reported that a task's
declared fixture paths did not exist; the files existed, but on another branch.

I fixed it by resetting the integration branch onto the correct base and
restoring `.orchid/` verbatim — which is exactly the kind of hand-surgery on run
state the protocol otherwise forbids, and I had no verb for it.

**Suggestions:**
- `run new` should either take a `--base <ref>` (defaulting to the configured
  integration base, not the previous run's tip) or refuse when the integration
  branch is behind its remote, naming the gap.
- At minimum, print the base and its distance from `origin/main` so the operator
  sees what the new run will build on.
- A `run rebase --onto <ref>` verb would remove the need for hand-surgery.

---

## F38 (epoch, medium) — after `run new` there is no epoch file, and the error says otherwise

Immediately after `orchid run new`:

```
$ cat .orchid/runtime/epoch
cat: .orchid/runtime/epoch: No such file or directory

$ orchid run new --help
orchid: stale epoch 'unset' (current 0) — refused (INV-02)
```

The refusal says the current epoch is `0`, but no file holds it, so the
documented way to read it fails. `ORCHID_EPOCH=0` worked, but by inference
rather than instruction. This compounds F31 from the r-001 report (the handoff
prints an epoch that goes stale); here the problem is the opposite — the epoch
exists conceptually but has no readable home.

**Suggestion:** create `runtime/epoch` at `run new`, or have the refusal say
where to read it. Better, support `ORCHID_EPOCH=auto`.

---

## F39 (verbs, medium) — there is no way to read a single task field

To amend one field of a task I had to do:

```sh
orchid task set T007 acceptance_criteria \
  "$(orchid task show T007 | sed -n 's/^acceptance_criteria: //p') ...extra..."
```

`task show` prints the whole file, so reading one field means parsing prose.
That pattern is fragile — it silently truncates at the first newline, and it
encourages exactly the read-modify-write appending that caused F40 below.

**Suggestion:** `orchid task get <id> <key>` printing the raw value, and
possibly `task append <id> <key> <text>` so amendment is explicit rather than
reconstructed by the caller.

---

## F40 (plan critique, high) — the loop gives no convergence signal, and rewards appending

Four critique rounds produced **8, 8, 8, 8** findings. An operator cannot tell
from that whether the plan is converging slowly, oscillating, or whether the
same defects are being re-reported in new words. r-001's loop went
8→8→8→4→4→3→0 and was legible; this one was not, and I only understood it by
reading every finding by hand across four rounds.

The deeper problem is that the loop **structurally encourages the failure mode
it then reports**. Because amending a task means read-modify-write (F39), the
natural fix for a finding is to append a clarifying sentence. After four rounds
my tasks contained contradictory layers — one clause requiring a value be
re-derived on submit and a later clause forbidding exactly that — and the critic
correctly reported them as contradictions. Several rounds' findings were
therefore *artifacts of how the previous round's findings had been applied*.

**Suggestions:**
- Report per-round deltas: new findings, repeats, resolved. "8 findings, 6
  repeats" is a completely different signal from "8 new".
- Track finding identity across attempts so a genuinely unresolved item is
  visibly unresolved rather than re-stated.
- Consider a convergence guard: N rounds with no reduction should raise a
  boundary asking the operator whether to continue, rather than looping.
- The critique reads the drafted tasks; it could cheaply flag *internal*
  contradiction within a single task's criteria as its own finding class, which
  is what most of my late-round findings actually were.

---

## F41 (gc, medium) — `jobs gc` still cannot reap what it creates

Recurrence of the r-001 finding, unchanged: manifests for jobs that never
launched, or that died without an envelope, are not reaped by
`orchid jobs gc --older-than-s 0`. I removed them by hand again, this run, with
the same `pid == 0 || !kill -0` check.

Reported as F29 in the r-001 notes; repeating it here only to record that it is
reproducible and still costing manual cleanup.

---

## What worked well

- **`run new` rollover and archival** were clean — `r-001` moved to `runs/r-001/`
  with its journal and reviews intact, and the new run started in `planning`
  correctly. The state model is sound; it is the *base branch* that needs
  attention (F37).
- **The plan critique's findings were consistently high quality when they
  arrived.** It caught real contradictions in my drafting, a genuinely stale
  requirements fixture path, and — across both runs — a migration numbering
  collision that would have shipped. The problem is the delivery mechanism, not
  the critic.
- **Config carried over correctly** between runs, including the verify command
  and `pack_budget_bytes`, so r-001's hard-won environment lessons applied
  automatically to r-002. That is the system working as intended.

---

## Operator note (not an orchid issue)

Two of my own errors are worth recording because they interacted badly with F35
and F36:

1. I read a job log's **contents** and reported the run as healthy without
   checking the log's **mtime**. The job had been dead half a day.
2. I applied critique findings by **appending** to task criteria rather than
   rewriting them, producing the contradictions described in F40.

Both would have been caught earlier by a status view that showed job age and
liveness.

---

## F42 (run rollover, high) — `run new` does not namespace task branches, so a second run collides on its first dispatch

`orchid run new` rolled `r-001 → r-002` and archived the old run's record
correctly — but r-001's ten `task/T001`…`task/T010` branches still existed. r-002
numbers its tasks from T001 too, so the very first dispatch failed:

```
{
  "kind": "worktree-conflict",
  "task": "T001",
  "reason": "git worktree add failed for branch task/T001 at .../wasiyyat-schedule-c-orchid-T001"
}
```

Any repo that runs orchid twice hits this, and hits it immediately.

**Credit where due: orchid handled it exactly right.** It raised a
`worktree-conflict` boundary naming both the branch and the path, and stopped
rather than guessing. That is the opposite of F35, and it is what made the fix
obvious. The finding is only that the collision should not arise.

I renamed the old branches to `r001/task/*` (content also preserved in the
squashed PR branch).

**Suggestions:** namespace task branches by run (`r002/task/T001`), or have
`run new` detect surviving `task/*` branches from the archived run and offer to
rename or delete them as part of the rollover.

---

## F43 (reviewer envelopes, high) — agy returned three envelopes with `verdict: null` and no findings

Task T004 drew five review envelopes. Three came from `agy` and were empty:

```
T004-a1-reviewer.2.json   engine=orchid/agy           verdict=null   findings=0
T004-a1-reviewer.3.json   engine=orchid/agy           verdict=null   findings=0
T004-a1-reviewer.4.json   engine=orchid/agy           verdict=null   findings=0
T004-a1-reviewer.json     engine=orchid/codex-review  verdict=approve
T004-a1-reviewer.5.json   engine=orchid/codex-review  verdict=request-changes
```

A `verdict: null` envelope is neither an approval, a rejection, nor a recorded
failure — it is a review slot that consumed an engine invocation and contributed
nothing. This is almost certainly the same headless tool-permission denial
recorded as F6 and hit again earlier in this run (agy needs `read_file` and
cannot prompt for it), but here it produced *reconciled envelopes* rather than an
error, so nothing flagged it.

The consequence is quiet and bad: **the arbitration appeared to rest on five
reviews and actually rested on two.** An operator reading "2/2 reviews
reconciled" or a five-envelope directory would reasonably assume more scrutiny
than existed.

**Suggestions:**
- Reject a reconciled envelope whose `verdict` is null or absent — quarantine it
  as `malformed` (the adapter already has that path) rather than storing it.
- Surface effective reviewer count in the boundary record and in `task show`:
  "2 usable of 5" is decision-relevant information.
- Given F6, F43 and the earlier round-two failure in this same run, consider
  whether `agy` should be bound to reviewer slots at all in headless mode
  without a pre-granted read permission, since its documented design is
  inline/diff-only and it cannot read a worktree.

---

## F44 (recovery, CRITICAL) — a task whose job dies without an envelope cannot be recovered through any verb

The operational cost of F35, and worse than it. F35 says work gets discarded;
F44 says the **task itself becomes unrunnable**, with no sanctioned way out.

I killed a running implement job deliberately (I had given it a wrong
instruction and wanted to redispatch with a corrected one). That left T010 in
`implementing` with no job — the same state any crashed or OOM-killed job
produces. Every documented escape refused:

```
$ orchid task retry T010 --reason "..."
orchid: illegal retry from implementing

$ orchid task infra-fail T010 --reason "..."
T010: infra_failures 1/3          # counter moved; status stayed 'implementing'

$ orchid drive
# ...did not redispatch T010; walked straight past it to report T016 waiting-deps

$ orchid task set T010 status rework
orchid: 'status' is kernel-owned — use task advance/unblock/retry
```

So: `retry` is illegal from the state the failure leaves you in, `infra-fail`
increments a counter without changing state, `drive` ignores it, and the direct
edit is refused and points back at the three verbs that don't work. That is a
closed loop.

The only way out was `orchid jobs prepare T010 implementer implement`, which
mints a fresh manifest that `drive` then spawns. I found it by reading a
job-pile-up error message that mentioned `runners/orchid-launch`, discovering
that path doesn't exist in the repo, and then reading `libexec/orchid-jobs`
source for the signature. Nothing in the refusal messages points there.

**Suggestions:**
- Make `retry` legal from `implementing` when the task has no live job — that is
  exactly the situation retry exists for.
- `infra-fail` should return the task to a dispatchable state, not just count.
  A counter that doesn't unblock anything is telemetry, not recovery.
- `drive` should detect `implementing` with no live job and either redispatch or
  raise a boundary naming the dead job — silently walking past it is the worst
  option.
- The `status` refusal should name the actual escape hatch (`jobs prepare`)
  rather than three verbs that all refuse.

---

## F45 (CLI, low) — `--help` is gated on run state, and `jobs prepare` crashes instead of printing usage

Two small papercuts that cost real minutes because they hit while recovering
from F44.

```
$ orchid task arbitrate --help
orchid: stale epoch 'unset' (current 1) — refused (INV-02)

$ ORCHID_EPOCH=1 orchid jobs prepare
/Users/bilal/workspace/personal/orchid/libexec/orchid-jobs: line 60: $1: unbound variable
```

Help text should never depend on run state — `--help` is how you find out what
to do when the run state is already wrong. And `jobs prepare` with no arguments
hits `set -u` on `$1` before reaching its own usage string, which the code
clearly has (it prints correctly for a *bad* flag, just not for *no* args).

Related: `ORCHID_EPOCH=1 orchid task arbitrate --help` answers `orchid: no task
--help`, so even past the epoch gate there is no per-verb help. I got the
signature by invoking with no args and reading the usage line in the error.

**Suggestions:** handle `--help`/`-h` before the epoch guard and before argument
binding; give each subverb a real help output.

---

## F46 (arbitration, medium) — the arbitration reason is write-once, so a wrong operator decision cannot be corrected

I arbitrated T010 `request-changes` and wrote a fix direction into `--reason`.
The direction was wrong: I told the implementer to change a unique index to be
submission-scoped, when the codebase's own established pattern (three Hissa
Jaidad handlers, in production) solves it by blanking the uuid at prefill and
letting the repository regenerate it.

I caught it about a minute after dispatch — and there was no way to fix it.
`arbitrate` had already consumed the transition, the reason is not an editable
field, and the running job had already been handed the old text. My only route
was to kill the job (into F44), write the correction into `acceptance_criteria`
instead, and redispatch — so the task record now carries a clause whose job is
to say "the arbitration note on this task is void."

That is a bad shape. The authoritative instruction and its retraction live in
two different fields, and a reader has to know which one wins.

**Suggestions:**
- Allow amending an arbitration reason while the task is in `rework` or
  `implementing`, appending an audit entry rather than mutating history.
- Or separate "the reviewer's finding" (immutable) from "the operator's
  direction" (amendable) in the rework prompt, so correcting the latter doesn't
  require laundering it through acceptance criteria.
- Generally: any field that gets packed into a dispatched prompt should have a
  correction path that doesn't require killing the job.

---

## F43 confirmed by the engine table

`orchid status` now reports it directly, which is the right surfacing:

```
== engines
codex           ok        -
codex-review    ok        -
agy             failing   failures 3
```

Three failures, and `agy` has contributed nothing usable across the entire run.
This is good observability — it just arrives after the reviews it poisoned have
already been reconciled and counted. See F43's suggestion to reject null-verdict
envelopes at reconcile time rather than storing them.

---

## F47 (verify, medium) — CORRECTED: the verify log survives success and not failure, and is keyed per task rather than per attempt

**I filed this wrongly and am correcting it in place rather than deleting it,
because the corrected version still matters.**

What I originally claimed: a failed verify names `.orchid/reviews/<task>-verify.log`
and that file is never written. That is false. Every task in this run has one:

```
$ ls .orchid/reviews/*verify.log | wc -l
14
```

What actually happened. T010's verify failed at 06:05:32 and the journal said
`verify failed: see .orchid/reviews/T010-verify.log`. I looked ~40 seconds later
and the file was absent. It appeared at 06:13:54 — written by the *passing* re-run
of the very same candidate SHA (`4924b1b6`), after I had fixed the environment
(F48). So on the evidence I have, the failing run left no log and the succeeding
run wrote one. I did not reproduce a second failure to confirm the mechanism, so
treat "not written on failure" as strongly suggested rather than proven; what is
certain is that the artifact the failure message pointed to did not exist when
the failure message was emitted.

The second half is certain and is the more useful finding: **the log is keyed by
task, not by attempt.** `T010-verify.log` now contains a3's passing output. a2's
failing output — the thing anyone would want to read — is gone, overwritten by
its own successful retry. There is no per-attempt forensic trail.

**Suggestions:**
- Write the log on failure first and foremost; that is the only case anyone reads it.
- Key it per attempt (`<task>-a<N>-verify.log`) so a retry cannot erase the
  evidence of the failure that caused it.
- Include the tail of it in the journal entry, so the common case needs no file.
- Pass it into the rework pack — the implementer is asked to fix a failure it is
  not shown.

**Operator note:** I reported this to my human as "the log is never written"
before checking whether it appeared later. The correct check — `ls` the whole
directory rather than one path — would have cost one command.

---

## F48 (environment, high) — the run authored a migration and then failed its own tests for never having applied it

T007 of this very run created `db/migrations/043_create_general_forms.sql` —
seven tables plus three columns on `moosi_members`. T010 then added the run's
first **integration** test, which naturally tried to write to those tables:

```
RuntimeException: Failed to prepare submission insert:
Table 'amcusa_db.general_form_submissions' doesn't exist
```

Nothing in the pipeline applies migrations. `verify` runs `phpunit`; the
bootstrap I wrote creates directories and symlinks data dirs, but no step in
orchid or in my config takes a schema from "authored in this run" to "present in
the database the tests connect to."

The result was a **false attribution**: orchid recorded this as T010 failing its
gate and sent T010 back to rework, twice. The task was correct. Its code was
correct — I verified the actual fix by hand and mutation-tested it (revert the
one line, the test goes red). Only the environment was wrong, and the
implementer has no ability to fix that.

I applied 043 to the dev database myself, after checking the migration's own
precondition guard (it aborts if legacy `reaffirmation` rows exist — there were
none), dumping the two tables its `ALTER`s touch, and confirming the enum
narrowing was safe. The test then passed, 21 assertions.

**Suggestions:**
- Support a per-run **setup/readiness command** distinct from `verify` — run
  once before the tick, allowed to mutate the environment (apply migrations,
  seed fixtures). `verify` should stay pure.
- Failing that, let a task declare an environment precondition, and raise a
  boundary naming it rather than blaming the task's diff.
- Distinguish "gate failed" from "gate could not run." Sending a task to rework
  for a missing database table is a category error, and it is the kind that
  burns a whole unattended night.

---

## F49 (verify, high) — "verify PASS" is reported as a gate without ever showing how narrow the gate is

Partly my own doing, which is why it is worth reporting: an operator can create
this situation without noticing, and orchid does nothing to make it visible.

The repo-level verify command I configured runs the whole suite:

```
... && php vendor/bin/phpunit
```

But each task carries its own `verification_commands`, and those were authored
with filters. The command actually executed for T010 was:

```
... && php vendor/bin/phpunit --filter 'GeneralFormPublic|GeneralFormValidation'
```

Across the run, per-task verification covered between 4 and 86 tests:

```
T003  OK (4 tests)      T011  OK (8 tests)     T010  OK (25 tests)
T007  OK (7 tests)      T013  OK (12 tests)    T008  OK (27 tests)
T006  OK (8 tests)      T016  OK (14 tests)    T005  OK (86 tests)
```

The suite has **2,305 tests**. So thirteen tasks merged, each reporting a green
gate, and nothing had run the full suite against the integrated result. I ran it
by hand once I noticed: `OK (2305 tests, 14279 assertions)` — no regression, as
it happens. But that was luck confirmed after the fact, not a gate.

The problem is presentation. `orchid status` and the journal both say
`verify passed`, and a task moves `testing -> reviewing` on the strength of it.
Nothing anywhere says "passed 25 of 2305 tests." A filter that made sense while
drafting a task silently became the definition of correctness for merging it.

**Suggestions:**
- Record and display the **effective scope** of a verify: test count, or at
  minimum whether the executed command differs from the repo-level default.
  `verify passed (25 tests)` and `verify passed (2305 tests)` are different
  claims and should not read identically.
- Warn when a task's `verification_commands` narrows the repo default — a
  `--filter` added to a command that otherwise matches the configured one is
  almost always a drafting artifact that nobody revisits.
- Consider a run-level gate before the final task: run the repo-level verify
  unfiltered against the integration branch, so narrow per-task gates cannot add
  up to an unverified whole.

**Operator note:** the honest lesson is mine — I wrote those filters during
planning to keep early tasks fast and never revisited them. But the reason it
survived thirteen merges is that orchid reports a filtered pass and a full pass
in exactly the same words.
