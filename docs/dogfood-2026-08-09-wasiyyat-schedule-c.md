# Dogfood run — wasiyyat-schedule-c (2026-08-09)

> Historical field report. Status and command output below remain as observed
> at the time. See [the r-002 retrospective](./r-002-retrospective.md) and
> [r-003 requirements](./plans/r-003-requirements.md) for the current
> closed/open split.

Companion to `dogfood-notes.md`; findings continue that file's numbering
(F24–F31, previous highest was F23).

**Repo:** PHP 7.4 / MySQL production app. ~2,100-test PHPUnit suite across
three suites, plus 65 Playwright specs. Hand-vendored runtime libraries, no
autoloader for app code, several gitignored multi-GB data directories.
**Run:** `r-001`, 9 tasks, `orchid start` → PLANNING → THE TICK via `orchid drive`.
**Reached:** 4/9 merged at time of writing; run continuing.
**Driver:** a Claude Code session executing PROTOCOL.md, looping `orchid drive`
and stopping at boundaries.

This was the first exposure of orchid to a repo of this size and messiness, and
most findings below are consequences of that rather than of the protocol model.
The fencing, journaling and boundary discipline all behaved as documented.

---

## F24 (worktree bootstrap, high) — task worktrees cannot obtain gitignored dependencies

`git worktree add` materializes only *tracked* files. Any repo whose test suite
needs gitignored paths fails verification for reasons unrelated to the task:

| missing | symptom |
|---|---|
| `vendor/` (composer) | `Could not open input file: vendor/bin/phpunit` |
| `statements/`, `uploads/` (1.9 GB + 1.6 GB data dirs) | 8 failures across two integration test classes |
| `tests/E2E/node_modules/` | would have broken all 65 Playwright specs |

The first task failed verify on this alone; its code was already correct
(2,136 tests green once `vendor/` existed). Without diagnosis it would have
failed all 9 tasks identically and looked like nine bad implementations.

The available workaround is to fold a bootstrap into `verify=`, which is what I
did. It works, but conflates two concerns in one field: `verify` runs every
pass, so per-worktree one-time setup is re-checked constantly, and the
bootstrap has to be idempotent, guarded and inlined into the single config line
whose failure otherwise means "the task's code is wrong."

**Suggestion:** a separate `prepare=` command, run once per worktree after
creation, before first verify, whose failure counts as `infra_failures` rather
than `attempts`. That distinction matters — see F27.

---

## F25 (merge validation, high) — the merge worktree lives somewhere else

Merge validation runs the task's `verification_commands` in a temp worktree:

```
cwd: /var/folders/78/nq9t6.../T//orchid-merge.nMBOyD
command: php vendor/bin/phpunit --filter Php74
---
Could not open input file: vendor/bin/phpunit
exit: 1
```

Task worktrees are siblings of the repo (`../<repo>-orchid-T008`), so an F24
bootstrap written with sibling-relative paths works there. The merge worktree
is under `$TMPDIR`, where the same relative path resolves to nothing. The task
was **approved unanimously twice**, then failed merge validation twice, for a
reason invisible in any review.

**Suggestion:** whatever solves F24 must also cover the merge worktree.
Separately, export the main repo path into the verify/prepare environment (e.g.
`ORCHID_REPO_ROOT`) so a bootstrap can be written portably instead of
hardcoding an absolute path into committed config, as I had to.

---

## F26 (schema tasks, high) — a task that adds a migration cannot make its own tests pass

T001 authored migration `041` and tests proving isolation against the altered
table. Its tests failed with:

```
Error: Call to a member function execute() on bool
```

`prepare()` returning `false` because the columns did not exist yet. The
implementer's own commit message says the behavioral tests "could not execute
because the sandbox" could not apply the migration.

There is a real ordering problem: the task authors the migration, nothing in
the tick applies it to the database the suite runs against, and the implementer
sandbox arguably should not hold schema-write rights. I applied `041` to the
local test DB by hand; the tests then passed (6 tests, 94 assertions).

Today this presents as a task failure and consumes `attempts`.

**Suggestion:** a documented convention (schema tasks declare an operator
prerequisite and the tick raises a boundary before verifying them), or a
`migrate=` step run against the test database as part of `prepare`.

---

## F27 (rework loop, high) — identical failure signatures still consume attempts

T002 failed verify three times with the *same two* assertions failing the same
way. The defect was in the test:

```php
$this->assertSame([$first, $second], $active['steps']);   // === on arrays
```

The values round-trip through a MySQL `json` column, which does not preserve
key order. Every key and value was correct; only order differed. `assertSame`
is `===` (order-sensitive for arrays); `assertEquals` is `==` (not). The
implementer instead kept trying to change production code to satisfy an
order-sensitive assertion, three times, then hit `attempts exhausted`.

Three attempts produced a **byte-identical** failure signature — strong
evidence the rework loop feeds back the same information and gets the same
answer.

**Suggestions, by value:**
- Include the previous attempt's verify output (or its diff) in the rework
  pack. "You already tried this and got exactly this" would likely break the
  loop by itself.
- On a second identical signature, route rework to a different engine in the
  role's failover chain.
- Consider not counting a rework as an attempt when the signature is unchanged.

---

## F28 (operator recourse, high) — `task retry` gives guidance exactly one shot

Follow-up to F27, and it sharpens it.

After the boundary I ran `orchid task retry T002 --reason "<precise diagnosis:
the two line numbers, the exact substitution, and an explicit 'do not change
production code for this'>"`. The task moved `blocked → rework → implementing`,
produced a byte-identical fourth failure, and immediately re-blocked with
`attempts exhausted` — `retry` restores *status* but no attempt budget.

Two distinct problems:

1. **You cannot tell whether `--reason` reaches the implementer.** I wrote an
   actionable diagnosis naming file, lines, substitution and anti-instruction;
   the next attempt repeated the mistake. Either the reason is journal-only or
   it was delivered and ignored — indistinguishable from outside, which is
   itself worth fixing.
2. **There is no supported "operator fixed it, just verify" path.** I ended up
   editing the test in the task worktree and committing on `task/T002` myself,
   then retrying with "the tree is already green." That worked, but it is
   outside the verbs and the protocol has no name for it.

**Suggestions:** have `retry` grant an attempt (or take `--attempts N`); make
reason-delivery visible in `task show` or the retry output; add a first-class
`task reverify` edge for "the tree is green, re-run verification without
another implementation pass." Four engine invocations went to a two-word test
change the operator had diagnosed correctly after the first failure.

---

## F29 (job launch, high) — a launch that fails before it runs is silent, and `drive` retries it forever

**This is F23 recurring, plus a much worse dimension F23 did not surface.**

Same error, same budget, different repo:

```
orchid: input_overflow — non-truncatable inputs (76086 bytes) exceed pack budget (65536)
```

F23 found this by running `orchid-launch` by hand. **Through `orchid drive` it
is completely invisible.** The pass prepares a manifest, the launch fails,
drive moves on, and re-attempts next pass. After 73 passes: 73 manifests, all
`"pid": 0, "pgid": 0, "started_at": 0`, no log files, `orchid jobs check`
reporting them `prepared` forever, `orchid status` showing `agy ok` throughout,
and not one journal entry mentioning a failure. The run degraded into an
infinite silent retry that only a wall-clock stall detector on the caller's
side caught.

The escalation ladder never engages: it triggers on `dead`/`stalled`/`timeout`,
and a job that never started is none of those. The ledger never marks the
engine, because no envelope is ever produced.

Compounding it: **`orchid jobs gc --older-than-s 0` cannot reap these.** It
reaps manifests whose pid is already dead, and `pid: 0` never satisfies that
test. I removed 74 files by hand after confirming `pid == 0 && started_at == 0`
on each. Note `dogfood-notes.md` line ~520 records treating "the pid-0 ghost
job as a known false positive" — benign at one, not benign at 73 and
uncollectable.

**Suggestions:**
- Treat a non-zero launcher exit as a job failure: journal it, run it through
  the escalation ladder (or straight to `infra-fail`).
- `jobs check` should report `pid: 0` with no log as `never-started`, not
  `prepared`.
- `jobs gc` should reap never-launched manifests.
- Refuse to prepare a second manifest for a (task, attempt, role, operation)
  that already has an unlaunched one outstanding.
- Since F23 already proposed raising the default: the effective budget here was
  **65536 even though this repo's orchid root `orchid.config` sets
  `pack_budget_bytes=131072`**. The repo-level config did not set it and the
  resolved value matched neither. Worth checking resolution order, and worth
  having `orchid doctor` print the resolved pack budget — it is now twice
  demonstrated to be able to wedge a run.

---

## F30 (scheduler, high) — comma-separated `depends_on` silently deadlocks

`lib/schedule.sh:125`:

```sh
deps="$(fm_get "$f" depends_on)"
for d in $deps; do
  [ "$(fm_get "$state/tasks/$d.md" status 2>/dev/null)" = "done" ] || unmet="$unmet $d"
done
```

`for d in $deps` splits on **whitespace**. A value of `T002,T003` is one token;
`fm_get .orchid/tasks/T002,T003.md status` finds no file, returns empty, never
equals `done`. The dependency can never be satisfied. `orchid task set T004
depends_on "T002,T003"` is accepted silently.

**What makes this dangerous is the rendered message.** The predicate joins the
unmet ids, so the bogus single token renders as:

```
T004  pending  waiting-deps (T002,T003)
```

which is **byte-identical to a correct two-dependency wait**. I read that line
repeatedly over several hours and it looked right every time. The tell was only
statistical: every task that ever dispatched had exactly ONE dependency, and
every task that never dispatched had more than one. After switching to spaces
the same tasks went `ready-to-dispatch` immediately, and the message became
`waiting-deps (T004 T005)` — correctly dropping deps already done.

**Suggestions:**
- Split on commas as well as whitespace (`${deps//,/ }` or `tr ',' ' '`).
- Or have `task set` reject a `depends_on` containing a comma, naming the
  expected separator.
- Either way, reject a `depends_on` id with no corresponding task file. That
  single check catches this at write time, hours before it can deadlock.
- Document the separator: the task template ships `depends_on:` empty with no
  format hint.

---

## F31 (papercuts, low/medium)

- **`orchid start`'s handoff prints an epoch guaranteed to expire.** It ends
  with `export ORCHID_EPOCH=0`; every `drive` pass fences a new epoch, so a
  later verb refuses with `stale epoch '0' (current 3) — refused (INV-02)`.
  The refusal message is excellent (it names the current epoch). The handoff
  could say so, or accept `ORCHID_EPOCH=auto`. I ended up prefixing every
  command with `export ORCHID_EPOCH=$(cat .orchid/runtime/epoch)`.
- **The stale-checkout recovery hint does not clear the flag.** After
  `plan apply`, `doctor` reported `FAIL: integration checkout is stale —
  refresh with "git checkout HEAD -- . ':(exclude).orchid'"`. Running exactly
  that did not clear it: the working tree was already correct, but the *index*
  carried staged deletions of `.orchid/reviews/plan-a*.json`, which that
  pathspec deliberately excludes. A bare `git reset` cleared it (7 envelopes on
  disk, 7 in HEAD, nothing lost). PROTOCOL.md already warns about this exact
  stale-index hazard, so only the printed recovery is incomplete.
- **Verb usage errors surface as raw bash errors.** `orchid task create` and
  `orchid task set` with no args print
  `libexec/orchid-task: line 47: $1: unbound variable`. `orchid task` and
  `orchid jobs` with no subcommand print proper usage, so the convention exists
  — it just is not applied to missing positionals.
- **Journal references a verify log before it exists.** `testing -> rework:
  verify failed: see .orchid/reviews/T008-verify.log` named a path that did not
  exist when read immediately after; it appeared later. Probably write-ordering
  between journaling the transition and flushing the log.

---

## What worked well (worth not regressing)

- **The plan critique loop is the standout feature.** Seven rounds
  (8→8→8→4→4→3→0 findings) against a spec already reviewed by hand. It caught a
  genuine data-loss bug: a `DELETE FROM backup_history WHERE filename = ?` in a
  file I had not inspected, which would have silently deleted rows once two
  subsystems shared that table. It also caught an inverted compression ratio
  and a method name I had invented. That loop paid for the entire run.
- **Boundary discipline.** `attempts exhausted` raised an `operator-decision`
  boundary instead of guessing, naming the failing log.
- **`orchid drive` as a deterministic pass.** Being able to loop a shell verb
  and involve a model only at boundaries made supervising this practical.
- **Refusals name their recovery.** Stale-epoch, `orchid start` preflight, and
  `doctor`'s per-check lines all tell you the next command.

---

## Operator note (not an orchid issue)

I first ran the driver loop `nohup`-detached, so the supervising harness tracked
only the launcher process and never learned when the loop stopped. It halted
correctly on a blocked task and then idled ~5 hours before anyone noticed. Run
the loop as a tracked child, not a detached one.

---

## Feature request — `orchid jobs ls` / a process table for the run

Raised by the operator mid-run, and the run had already produced the evidence
for it twice. Filed as an enhancement, not a defect.

**What `orchid status` shows today**, verbatim, while two jobs exist for the
same task:

```
== jobs
T004	dead
T004	running
```

A task id and a state word. You cannot tell which job is which, what role or
engine either was, when they started, how long they have run, which attempt
they belong to, or whether the `dead` one is the corpse of something already
handled or a fresh failure needing escalation.

**Every field needed is already persisted.** A job manifest holds:

```
attempt, base_sha, candidate_sha, engine, hook_point, job_id, log,
operation, output, pgid, pid, role, started_at, task
```

So this is a rendering gap, not a data-modelling one — which makes it cheap.

### Proposed

`orchid jobs ls` (and the same table under `orchid status --jobs`), one row per
outstanding job:

```
JOB                    TASK  ROLE       OP      ATT  ENGINE  PID    STATE      ELAPSED  BUDGET
j-e3-T004-a1-5037      T004  reviewer   review  1    agy     93307  running    04:12    28800s (0%)
j-e3-T004-a1-2ee0      T004  reviewer   review  1    agy     0      never-started  —    —
```

Two properties matter more than the columns:

1. **Liveness must be computed, not read.** A `pid: 0` manifest, or one whose
   pid fails `kill -0`, must render as `never-started` / `dead` — never as
   `prepared`. This is F29's failure mode surfacing in the UI layer: 73
   never-launched jobs rendered as 73 identical `prepared` lines, and the only
   way to discover they were corpses was `cat`-ing the manifests by hand and
   noticing `pid: 0, started_at: 0`. A process table that computed liveness
   would have made that visible in one command, on the first pass.

2. **Elapsed against `wallclock_budget_s`.** Distinguishing "slow" from "hung"
   currently means reading `started_at` out of a manifest and doing the
   arithmetic yourself. The budget is already tracked well enough for
   `jobs check` to report `budget-exceeded`; showing the percentage
   continuously is nearly free and is what tells an operator whether to wait or
   intervene.

### Worth having alongside

- **Who launched it.** `drive` pass N vs. an operator's hand-run
  `runners/orchid-launch` vs. the pump. During this run I could not distinguish
  a job drive had just started from one I had started myself, and the two want
  different responses.
- **The log path on the row**, so the next command is copy-paste rather than a
  `find` under `.orchid/runtime/logs/`.
- **`--watch`**, since the natural use is polling. The whole supervising loop I
  wrote around `orchid drive` exists partly because there was nothing to watch.
- **A history mode** (`orchid jobs ls --all`) covering reconciled jobs, so
  "what did this task actually run, in what order, and how long did each take"
  is answerable after the fact. Reconstructing that from `journal.md` works but
  is manual.

### Why it earns its place

`orchid service` already installs a real pump (launchd/cron), so semi-attended
runs are a first-class mode — but there is no operator-facing view of what that
pump is doing. In this run, two separate multi-hour stalls (F29's silent retry,
and a driver that had exited unnoticed) would both have been obvious at a
glance from a table like the above. Both instead took manual manifest
archaeology to diagnose.

---

## F32 (review envelope, medium) — `request-changes` with an empty `findings[]` puts the substance somewhere the tooling does not read

T004 drew two reviewers (high `risk_tier` → two slots). They disagreed:

```
T004-a1-reviewer.json     engine=orchid/agy           verdict=approve          findings=0
T004-a1-reviewer.2.json   engine=orchid/codex-review  verdict=request-changes  findings=0
```

The `request-changes` envelope carried **zero structured findings**. Its entire
substance was in the free-text `summary`:

> `prepareBackupAttempt()` can return `run_id` 0 after a best-effort
> `startRun()` failure, yet the handler still flushes "started," so a committed
> running row is not guaranteed before the early response

That turned out to be a **real defect**, and a good catch: the handler called
`prepareBackupAttempt()` and discarded its return value, while the comment
directly above it asserted "A racing request therefore sees either the named
lock or this row; there is no neither-visible gap" — an invariant the code did
not enforce. I arbitrated to `request-changes`.

The disagreement escalated correctly here, because the verdicts differed. The
concern is what happens when they *don't*: the deterministic approval path
reports "unanimous scope-complete approval from N review(s), **no finding at or
above high**", which reads `findings[]`. An envelope whose only content is a
prose `summary` contributes nothing to that test. Had agy also returned
`approve` — or had this reviewer returned `approve` with the same prose caveat
— a genuine correctness defect would have sailed through deterministic
approval, because the field the gate consults was empty.

**Suggestions:**
- Treat `verdict: request-changes` with an empty `findings[]` as malformed, or
  synthesize a finding from `summary` at reconcile time, so severity-based
  gates see it.
- Surface `summary` in whatever the arbiter/operator is shown. I only found
  this by `jq`-ing the raw envelope; the boundary record itself said only
  `T004-a1-reviewer.2.json:verdict=request-changes`, with no hint that a
  specific, actionable concern was sitting in the file.
- Consider requiring at least one finding for any non-`approve` verdict.

**Also worth noting positively:** the two-slot routing for a `high` risk tier
earned its keep on the first task that used it. The engine that approved
(`agy`) missed a defect the other (`codex-review`) caught. A single-reviewer
configuration would have merged it.

---

## F33 (arbitration, CRITICAL) — a later unanimous auto-approval silently overrides an arbiter's `request-changes`

**The most serious finding of this run. A defect the operator explicitly
rejected twice was merged, and nothing in the run state records that the
concern was never addressed.**

### Sequence

| round | agy | codex-review | outcome |
|---|---|---|---|
| 1 | `approve` | `request-changes` | boundary → operator arbitrated **request-changes** |
| 2 | `approve` | `request-changes` | boundary → operator arbitrated **request-changes** |
| 3 | `approve` | `approve` | **deterministic approval → merged** |

Round 3's journal entry:

```
arbitrating -> merging: arbitrate(approve): deterministic approval:
unanimous scope-complete approval from 2 review(s), no finding at or above medium
```

### The defect is still in the merged tree

Both operator arbitrations named the same missing branch, the second one
naming the exact constants (`'named_lock'` vs `'active_run_fallback'`), the
exact line range, the response shape to reuse, and the test to add. The merged
`includes/handlers/backup_api.php` logs the WARNING and then **proceeds
unconditionally**; `git grep active_run_fallback` over the merged tree finds it
only in the guard's own `decision()` and in tests asserting the mode string.
There is no refusal anywhere. The concurrency hole T004 exists to close —
fallback mode with a failed `startRun()`, so neither lock nor row protects the
run — shipped to the integration branch.

### Why it slipped

Two mechanisms compound, and the second is the dangerous one:

1. **F32 again.** Both reviewers returned `findings: []` with all substance in
   prose `summary`. The deterministic gate weighs "no finding at or above
   medium" against an array that is always empty, so it always passes.
2. **Arbitration decisions do not persist.** An operator `request-changes` moves
   the task to `rework` and is journaled, but leaves **no durable marker on the
   task** saying "this specific concern is unresolved." The next attempt is
   judged entirely on its own reviews. When the reviewer that raised the
   concern changes its mind — without the code changing in the way the arbiter
   required — the deterministic path merges it, and no verb ever asks whether
   the arbiter's objection was met.

An operator who arbitrates `request-changes` twice reasonably believes they
have blocked that merge. They have not. They have only deferred it by one
round, and nothing tells them when it lands anyway. I found this by reading the
merged source *after* `orchid status` said `T004 done` — nothing in the status,
journal, or envelopes flagged it.

### Suggestions

- **Persist the objection.** An arbiter `request-changes` should write a
  blocking marker on the task (an `unresolved_objection` field, or a synthetic
  high-severity finding injected into the next attempt's review set) that must
  be explicitly cleared — by the arbiter, or by a reviewer that names it — before
  deterministic approval can fire.
- **Never let deterministic approval fire on a task with a prior operator
  `request-changes` for the current attempt chain.** Require an explicit
  `orchid task arbitrate --result approve` from the operator instead. The
  deterministic path is right for a task that has never been rejected; it
  should not be able to overrule a human who already said no, twice.
- **Carry the arbitration reason into the next attempt's reviewer pack**, so
  the reviewer is judging "did they fix the thing the arbiter named", not
  re-forming an opinion from scratch. That a reviewer flipped `request-changes`
  → `approve` with the defect untouched suggests it never saw its own prior
  objection.
- Fix F32 as a prerequisite: while `findings[]` can be empty on a non-approve
  verdict, every severity-based gate in the system is weighing nothing.

### Operator cost

Three implementation rounds, six review dispatches, two hand-written
arbitrations naming the exact fix — and the defect shipped anyway. The
mechanism that should have caught it (two reviewer slots on a `high` risk tier)
DID catch it, twice. It was the auto-approval path that discarded that signal.

---

## F34 (task set, high) — a newline in a value silently truncates the task file to zero bytes

`orchid task set <id> <key> "<value containing a newline>"` prints:

```
awk: newline in string BACKGROUND, read thi... at source line 1
```

three times, exits **0**, and leaves `.orchid/tasks/T010.md` at **0 bytes**. The
entire task — id, title, status, archetype, branch, every field — is gone. Not
a rejected write: a destroyed file.

It then fails quietly in both directions:

- `orchid task set` reported success (exit 0) for the subsequent writes I made
  against the now-empty file, so nothing signalled that the task no longer
  existed.
- `orchid task show T010` **exits 0 and prints nothing**, rather than reporting
  a malformed or empty task. I only noticed because a `grep` for the fields I
  had just written came back empty, and `ls -la` showed the size.

Frontmatter being single-line is a reasonable constraint. Destroying the file
when it is violated is not, and neither is a reader that treats an empty task
file as success.

**Suggestions:**
- Reject a value containing a newline before writing anything, naming the
  constraint. (Or accept it and encode it — but rejecting is fine and cheap.)
- Write through a temp file + atomic rename so a failed rewrite can never leave
  a truncated task.
- `task show` should exit non-zero on an empty or unparseable task file.
- Consider a `task lint` / `doctor` check for zero-byte or frontmatter-less task
  files, since a run whose task file vanished mid-flight would otherwise
  present as a task that simply stopped existing.

**Context:** this happened while writing a long, multi-paragraph
`acceptance_criteria` — exactly the case where an operator is most likely to
paste prose containing newlines, and exactly the field where losing the content
matters most.
