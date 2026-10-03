# Orchid r-003 — from governance kernel to full agent framework

> Draft. r-002 is now 40/40 and waiting at its operator acceptance boundary.
> r-003 starts only after that judgment; one run owns `.orchid/` at a time.

## Goal

r-001 and r-002 made Orchid's governance kernel materially more trustworthy: a
task state machine with evidence that must bind to the candidate it certifies,
review independence, arbitration, merge revalidation, and an honest account of
what is enforced versus advised. r-002 also proved the surrounding unattended
operability layer is not ready for an unfamiliar operator yet.

That is a governance kernel. It is not yet a framework someone adopts on a
Tuesday afternoon. r-003 closes the gap between "orchid decides whether work may
merge" and "orchid is where the work lives" — the operator-facing runtime layer
the last two runs deliberately deferred.

The competitive frame is explicit: adjacent tools own the terminal-session and
liveness layer and stop there — no task state, no review orchestration, no merge
gating. Orchid owns the half that is hard to build and easy to get wrong. If it
also becomes pleasant to live in, there is no reason to run both.

## Decision 0 — the daemon question, which gates every track below

Orchid's standing constraint is: Bash 3.2+, Git and jq; **no daemon, database,
hosted service, Node/Python runtime, or API-key proxy.**

Persistent sessions that survive a closed lid require a resident process owning
PTYs. These cannot both be true. Decide, in writing, before any track begins,
and record the rejected alternative:

- **(a) Hold the line.** No resident process. Push liveness onto the host's own
  supervisor (launchd/systemd/cron already used by `orchid service`) and accept
  that agent sessions do not survive a disconnect — only *work* does, because
  state is durable in files and jobs are resumable. Cheapest, keeps the audit
  story, keeps single-file installability.
- **(b) A narrow, optional daemon.** A supervisor that owns job processes and
  nothing else, shipped as an opt-in component, with the kernel still fully
  functional without it. Costs the "no daemon" claim; must not become required.
- **(c) Adopt a multiplexer.** Run jobs inside an existing session multiplexer
  (tmux, or a third-party runtime) via the existing plugin seam, so orchid gains
  persistence without owning a process model. Cheapest capability, adds a
  dependency orchid does not control.

Nothing in Track A may be implemented before this is decided. The decision must
name what it gives up.

## Constraints that do not change

- Engine neutrality: the kernel never branches on an engine name.
- All durable run state mutated through orchid verbs.
- Every change passes the full suite on Bash 3.2, plus ShellCheck.
- Honest labels: enforced / advisory / locally proven / operator-owned.
- **No code is copied from any other project.** Concepts and feature ideas are
  fair to reimplement; source is not. Where another project's licence would
  attach obligations, we take the idea and write our own implementation from
  orchid's own model.

## Track A — liveness and attachment

*Gated on Decision 0.*

- Work survives disconnect: a run in flight resumes cleanly after a reboot,
  a lost network, or a closed laptop, with no lost or double-counted attempts.
- A job whose host process dies is detected as dead, not left `prepared`
  forever (r-002 lesson: liveness must be computed, never read).
- Reattach from a second machine or a phone without corrupting run state —
  the epoch fence already exists for exactly this; prove it under real
  disconnection rather than in a fixture.

## Track B — the operator's window

r-002's process table (`orchid jobs ls`) lands the first half. Finish it:

- **Event-driven waiting, not polling.** A waiter should block until something
  actually changes — a task reaching a judgment boundary, a job dying, an
  implementer awaiting input — instead of sleeping and re-asking. Every
  supervising loop written against orchid so far has been a poll loop, and the
  polling is what made diagnosis slow.
- `--watch` for the process table, and a status vocabulary that distinguishes
  *working* from *blocked-on-a-human* from *idle*.
- One command that answers "what is this run doing right now, and what is it
  waiting for" without reading a journal.

## Track C — agent-to-agent primitives

- A job may ask for another job and wait for its result, within the state
  machine rather than around it.
- Blocking is first class: a job that needs a human says so, and that state is
  visible and waitable rather than inferred from silence.
- These must not become a way to bypass the kernel — anything that changes
  durable state still goes through a verb, and INV-13 still holds.

## Track D — adoption

- Detect installed agent CLIs and offer a working default configuration, rather
  than requiring the operator to know the plugin contract first.
- `orchid start` on an existing repository should reach a running plan with no
  hand-editing of config.
- Quickstart that a new operator completes without reading PROTOCOL.md.
- The lifecycle gap r-002 found stays fixed: nothing schedules work that
  outlives the run it serves.

## Run-level acceptance

- Decision 0 recorded with its rejected alternatives before Track A begins.
- `bash tests/run.sh`, the invariant suite, ShellCheck and the docs gate green
  on Bash 3.2.
- Every new gate ships a RED case proving it detects its own failure.
- A local end-to-end rehearsal: a run survives a simulated disconnect, an
  operator watches it without polling, and a task blocked on a human is visible
  as blocked.
- Version stays `1.0.0-beta.x`. Third-party beta and public release remain
  operator-owned and unclaimed.

## Track E — run lifecycle and planning legibility

From the wasiyyat general-forms dogfood run (2026-08-11), whose findings are a
different class from earlier reports: not environmental, but **the planning loop
being unobservable**. The run never reached the tick at all.

- **`run new` must not silently inherit the previous run's branch tip** (F37).
  Rolling `r-001 → r-002` archived cleanly but left the integration branch on
  r-001's tip: 18 commits behind `origin/main`, carrying r-001's still-unmerged
  PR, and missing the new run's own requirements and fixtures. Every task would
  have branched from that, building unrelated work on top of an open PR against
  stale main with the spec's source documents absent from the tree the
  implementer can see. Nothing warned; it surfaced only because the critic
  reported fixture paths that "did not exist" — they existed, on another branch.
  Take `--base <ref>` defaulting to the configured integration base rather than
  the previous tip, or refuse when the branch is behind its remote and name the
  gap. At minimum print the base and its distance from the remote. A
  `run rebase --onto <ref>` verb would remove the hand-surgery on run state the
  protocol otherwise forbids and for which no verb exists.

- **The critique loop needs a convergence signal, and must stop rewarding
  appending** (F40). Four rounds produced 8, 8, 8, 8 findings — from which an
  operator cannot tell converging from oscillating from re-reporting the same
  defects in new words. r-001's loop ran 8→8→8→4→4→3→0 and was legible; this one
  was understood only by reading every finding by hand. Report per-round deltas
  (new / repeat / resolved), track finding identity across attempts, and raise a
  boundary after N rounds with no reduction instead of looping. The loop also
  structurally causes the defect it reports: because amending a task means
  read-modify-write, the natural fix is to append a clarifying sentence, so
  tasks accumulate contradictory layers that the critic then correctly flags —
  several late findings were artifacts of how earlier ones had been applied.
  Flagging *internal* contradiction within one task's criteria is a cheap and
  high-value finding class.

  **The convergence signal landed 2026-09-13; the rest of F40 has not.**
  `orchid plan rounds` reports each critique round as
  `total / new / repeat / resolved` against the rounds before it, and verdicts
  the series — exit 3 and a named round when one did not reduce the count, exit
  0 when every round did. Read-only and answered ahead of the epoch fence, for
  INV-17's reason: the loop consults it while the draft is still cheap to
  change, and a report gated on run state is the one thing you cannot read when
  the run state is what went wrong. Run against r-002's own filed critique it
  names `a4` — the round that went 5 findings back up to 8.

  **What it cannot see, stated in its own output rather than left to be
  discovered.** Identity is the finding TITLE, case-folded and
  whitespace-collapsed, so it detects a VERBATIM repeat. It does not detect the
  same objection re-worded — one of the three things this finding says an
  operator cannot distinguish — and a re-worded repeat reads as one resolved
  plus one new. On r-002's real series every round scores zero repeats for
  exactly that reason. `repeat` is therefore a floor on repetition and never a
  ceiling, and the TOTALS column is the term that survives rewording. Fuzzy
  matching was considered and rejected: an arbitrary similarity threshold would
  make the number look stronger than the evidence behind it, which is the defect
  class this run exists to close.

  **The stop landed the same day.** `orchid plan apply` now refuses a plan whose
  critique has run `critique_nonconvergence_max` CONSECUTIVE rounds without
  reducing its finding count (default 3, `0` disables). A report nothing forces
  you to read is lesson L016's shape, so the loop is stopped by a gate instead.

  It is the rework loop's stop one loop earlier, deliberately rather than a
  second invention: `rework_nonconvergence_max` already refuses to spend a round
  re-asking an identically-answered question. The predicate is SHARED with the
  report (`findings_rounds_stalled`) so the two cannot disagree about what
  stalled means, and it is narrower than what the report prints — only
  consecutive non-reducing rounds at the END of the series, so 8, 9, 6, 3 is not
  stopped for a blip it has since recovered from. And it pairs with its own
  remedy in the state it fires in, as the carry-forward cross-check pairs with
  `plan defer`: make the next round reduce the count, or raise the bound.

  Still open: tracking identity across rewording, and flagging internal
  contradiction within one task's criteria.

- **Give the verbs a way to read and amend one field** (F39). `task show` prints
  the whole file, so reading one value means parsing prose — fragile, silently
  truncating at the first newline, and the direct cause of the append-instead-of-
  rewrite pattern above. Add `task get <id> <key>` printing the raw value, and
  consider `task append <id> <key> <text>` so amendment is explicit rather than
  reconstructed by the caller.

  **The read half is closed, 2026-09-12; the amend half is not.**
  `orchid task get <id> <key>` prints the raw value through the one frontmatter
  parser and is read-only — no verb lock, no epoch fence, so it answers when the
  run state is already wrong (the INV-17 argument). It is also admitted through
  the brokered orchestrator surface, on the ground that `task show` is already
  admitted and returns the whole document, so one field out of it discloses
  strictly less; arity, the id and the key shape are all bounded there.

  The design decision worth carrying forward is the ABSENT/EMPTY split.
  `fm_get` prints nothing for a key that is absent and nothing for one set to
  the empty string, and those are different facts with different responses
  behind them. So presence is the EXIT STATUS and the value is stdout, and
  `fm_has` was added beside `fm_get` in lib/frontmatter.sh as the same awk scan
  with `print` replaced by a status — never a second matcher, which would answer
  `yes` for a key name appearing in the task BODY. It matches both spellings of
  an empty field (`key:` as the template writes an unset one, `key: ` as a write
  leaves it), because the trailing-space form alone would report every unset
  field in a fresh task as absent.

  `task append` remains open, and is the half that actually closes the
  append-instead-of-rewrite hazard.

- **Readable epoch after setup and rollover (F38) — closed in r-002.** The
  dogfood observed `.orchid/runtime/epoch` missing immediately after `run new`
  while the refusal named current epoch 0. T029 made `orchid start` materialize
  epoch 0 and changed its hand-off to read the current value from that file;
  rollover preserves the live runtime directory. Keep the regression evidence,
  but do not schedule this as r-003 work. An `ORCHID_EPOCH=auto` convenience is
  a separate design choice, not required to close the missing-file defect.

## Track F — the rest of the 2026-08-11 report, and what r-002 already covers

Track E carried F37–F40. The report holds **fifteen** findings, F35–F49, and the
eleven not carried are triaged here. Two are CRITICAL. Several were reproduced
independently in r-002's own operation, which is noted where it happened —
a finding that recurs in a different repository under a different operator is
a property of orchid, not of one dogfood run.

### Closed by r-002 tasks — retain these as regression evidence

- **F35 (CRITICAL) — a job can do its whole task, log the results, then die
  without an envelope.** A critique attempt produced eight complete findings,
  wrote every one to its job log, and exited with no envelope; `jobs reconcile`
  had nothing to land and from the outside the attempt never happened. Recovered
  by `grep`. **T040 merged:** reconciliation salvages parseable log output as a
  degraded `no_envelope` record, preserves exit/tail diagnostics, and makes the
  failure visible. The report's own correction also survived review: **CPU
  delta is a bad default progress signal** — a legitimate job sat at ~9s CPU
  across 40 minutes while genuinely working. The CPU-stall check is therefore
  off by default and treats a backwards counter as unknown rather than killing.
- **F36 — nothing distinguishes "running" from "died twelve hours ago."** An
  operator reported a critique as actively working; it had been dead 12.5 hours.
  **T035 merged:** `orchid jobs ls` and `orchid status --jobs` show age and
  computed liveness rather than trusting a persisted process state.
- **F38 — no epoch file after `run new`.** **Closed by T029 plus rollover's
  runtime preservation:** setup now materializes epoch 0 and prints a hand-off
  that reads the current file rather than exporting an immediately stale
  literal. The operator must still refresh that value after a verb fences a new
  epoch; that is INV-02, not the missing-file defect.
- **F41 — `jobs gc` cannot reap what it creates.** Manifests for jobs that never
  launched, or died without an envelope, survive `gc --older-than-s 0`. Already
  reported as r-001's F29 and reproduced again here. **T027 merged:** launch
  refusal, status, accounting, planning-phase handling, and garbage collection
  share the same pid-0/unlaunched classification and leave a durable receipt.
- **F48 — the run authored a migration and then failed its own tests for never
  having applied it.** Two rework rounds charged to a task whose code was
  correct; only the environment was wrong, and the implementer could not fix it.
  **T024 merged** candidate-bound operator prerequisites, and **T019 merged**
  fail-closed environment/operator classification so a proved non-candidate
  failure does not charge the attempt budget. The shipped distinction is now
  **"gate failed" versus "gate could not run"**; uncertain failures still
  charge the candidate rather than being silently forgiven.

### Not owned by anything — r-003 scope

- **F44 (CRITICAL) — a task whose job dies without an envelope cannot be
  recovered through any verb.** Worse than F35: F35 discards work, F44 makes the
  task unrunnable. Every documented escape refuses — `retry` is illegal from
  `implementing`, `infra-fail` moves a counter without changing state, `drive`
  walks straight past, and `task set status` is refused with a pointer back to
  the three verbs that don't work. A closed loop. The only exit was
  `jobs prepare <id> implementer implement`, found by reading source. Make
  `retry` legal from `implementing` when no live job exists, have `infra-fail`
  return the task to a dispatchable state, have `drive` redispatch or raise a
  boundary naming the dead job, and make the refusal name the actual escape.

  **Re-measured against the shipped tree, 2026-09-12 — the loop was not closed,
  and the third bullet was already done.** Two of the four claims above no
  longer hold, and saying so is the point of re-measuring rather than
  re-reporting:

  - *An escape existed.* `to=blocked` is legal from EVERY status by
    construction (`legal()` returns 0 for it before consulting any archetype),
    and both recovery verbs are legal from `blocked`, so
    `orchid task advance <id> blocked --reason "..."` followed by
    `orchid task retry <id> --reason "..."` was always a supported, verb-only
    route back to `rework`. Nothing at the point of refusal said so, which is
    why it read as a dead end and was never found. The refusals now print it,
    from one composer shared by `retry`, `reverify` and `infra-fail`, and
    tests/test_task.sh Part AK EXECUTES the route it names so the sentence
    stays evidence rather than advice.
  - *`drive` does not walk past a dead job.* The dead-manifest escalation sweep
    that T027/T035/T040 built collects a manifest whose pid is gone with no
    spooled envelope, names the job, and charges exactly one rung of the
    `infra_failures` ladder. This was never pinned either way; it is now, in
    tests/test_drive.sh Part AK, with a live-job twin proving the ladder counts
    deaths rather than passes. The report predates that machinery.

  What is left of F44 is the part the two fixes above do not reach: `retry`
  still requires the intermediate `blocked` hop, and `infra-fail` below its cap
  still changes no status by design. Both are now NAMED at the point of
  refusal, so the remaining question is whether to collapse the hop — which
  means teaching a tier-1 verb a liveness rule that currently has exactly one
  implementation, in tier-2. That is a design decision, not an outage.
- **F42 — `run new` does not namespace task branches.** r-001's `task/T001…T010`
  survived the rollover, r-002 numbers from T001 too, and the first dispatch
  collided. Any repo that runs orchid twice hits this immediately. Orchid handled
  it correctly — a `worktree-conflict` boundary naming branch and path, stopping
  rather than guessing — so the finding is only that the collision should not
  arise. Namespace by run, or have `run new` detect surviving `task/*` branches.

  **Closed 2026-09-12 by the detect-and-refuse half, and this repository is the
  reproduction.** `orchid run new` refuses the rollover while `task/*` refs
  survive, before anything is archived — so deleting them and re-running the
  identical command is the whole remedy. The refusal names the worktrees FIRST:
  41 branches survive r-002 here, 40 held by a linked worktree each, and
  `git branch -D` refuses a branch a worktree holds, so a message naming only
  the delete would have failed on its first line. Contained branches get
  `branch -D`; anything not contained (here, `task/T024-preserve`) gets a rename,
  because deleting it destroys work that never merged. Namespacing by run is
  still the other option and is not done.
- **F43 — reviewer envelopes with `verdict: null` are stored and counted.**
  Three agy envelopes contributed nothing, so an arbitration that appeared to
  rest on five reviews rested on two. **Reproduced in r-002**: five null-verdict
  envelopes exist here — four from agy on `T010-a2`, one from claude on
  `T013-a4`. Neither merge was corrupted (T010-a2 was rejected on its own
  merits; T013-a4 had six usable envelopes), but the shape is present in a second
  repository. Quarantine a null-verdict envelope as malformed at reconcile rather
  than storing it, and surface *effective* reviewer count ("2 usable of 5") in
  the boundary record and `task show`.

  **Re-measured 2026-09-12 — the kernel was never fooled; the report was.**
  `envelope_validate` already requires `verdict IN("approve","request-changes")`
  for any `status: ok` review or critique envelope, and reconcile quarantines a
  failing one as `malformed` rather than storing it, so the first half of this
  finding is closed. The five envelopes named here are `status: failed` (four
  agy, one claude), where a null verdict is correct and expected, and the
  arbitration gate has always counted only `ok` envelopes bound to the current
  candidate. No arbitration ever rested on them.

  What was real is the reporting: six files in `reviews/`, a refusal that says
  `have 1`, and nothing connecting the two numbers. That refusal now states the
  split and why each envelope was skipped — a non-ok status (the engine failed;
  re-run the slot) and a superseded `candidate_sha` (the review was fine and the
  candidate moved under it; re-running is the one thing that does not help)
  counted apart, because they are different problems with different fixes.
  Appended after the existing sentence, so the three assertions pinned on
  `(have N)` still mean what they meant. Still open: the same split in
  `task show` and in the boundary record.
- **F45 — `--help` is gated on run state, and argument-less subverbs crash.**
  `orchid task arbitrate --help` refuses on a stale epoch; `jobs prepare` with no
  args dies on `$1: unbound variable` before reaching its own usage string.
  **Reproduced in r-002**: `orchid task unblock` with no argument fails the same
  way at `libexec/orchid-task:788`. Help must never depend on run state — it is
  how you find out what to do when the state is already wrong.

  **Closed 2026-09-12, and the sweep found a third shape worse than both.**
  Six subverbs died on `$1` under `set -u`, printing a source file and a line
  number at an operator; every one now prints its own usage, read out of a
  single per-file table that the dispatch fallback shares. Every verb and
  subverb answers `--help` itself, ahead of the epoch fence. The third shape:
  several verbs read their first argument as data, so `orchid plugins lock
  --help` WROTE `.orchid/plugins.lock`, `orchid plugins untrust --help`
  reported untrusting a plugin named `--help`, and `orchid init --help` ran the
  initialisation. Asking a question performed an action.

  It is an invariant rather than a sweep: **INV-17**
  (`tests/inv/test_INV-17_help_is_not_run_state.sh`) DERIVES its subject list
  from `libexec/` and each file's own `case "$sub" in` blocks — 78 probes on
  the current tree — runs every one under a deliberately stale epoch, and
  compares a content digest of `.orchid/` across the whole sweep, so a verb
  added tomorrow is covered without anyone extending the test.
- **F46 — the arbitration reason is write-once.** An operator who writes a wrong
  fix direction into `--reason` cannot correct it: the transition is consumed,
  the field is not editable, and the running job already has the old text. The
  only route was killing the job (into F44) and laundering the correction through
  `acceptance_criteria`, leaving the authoritative instruction and its retraction
  in two fields. Allow amending while the task is in `rework`/`implementing` with
  an audit entry, or separate the reviewer's immutable finding from the
  operator's amendable direction.
- **F47 — the verify log is keyed per task, not per attempt.** `<task>-verify.log`
  is overwritten by the next attempt, so a retry erases the evidence of the
  failure that caused it, and the failing run may not write one at all. **Live in
  r-002**: this operator read `.orchid/reviews/<id>-verify.log` for every
  diagnosis all run, always seeing only the most recent attempt. Key per attempt,
  write on failure first, include the tail in the journal entry, and pass it into
  the rework pack — the implementer is currently asked to fix a failure it is not
  shown.

  **Re-measured 2026-09-12 — the headline is stale.** T025's
  `capture_rework_evidence` already files a failing round at
  `<id>-r<n>-rework.log` on all three doors into `rework` and feeds it into the
  next brief, so "a retry erases the evidence of the failure that caused it" is
  no longer true of the shipped tree. What nothing retained was everything that
  takes no rework door: a PASS (so "which tree passed on attempt N, and what did
  it print" was unanswerable an attempt later), a refusal (exit 20), and a second
  failing run inside one attempt after `task reverify`. Every run of the verifier
  now also files `<id>-a<n>-verify.log`, keyed by the same `a<n>` as that
  attempt's implementer envelope. The live `<id>-verify.log` is untouched,
  because four readers depend on it.
- **F49 — "verify PASS" never shows how narrow the gate was.** Per-task
  `verification_commands` carried `--filter`s authored during planning; thirteen
  tasks merged reporting a green gate having run between 4 and 86 of the suite's
  2,305 tests, and nothing had run the full suite against the integrated result.
  A filter that made sense while drafting silently became the definition of
  correctness. **Independently converged on in r-002** as lesson L036, from the
  opposite direction: there, the full suite ran but was blind on the integration
  branch, and the conclusion was identical — *run the repo-level verify
  unfiltered against the integration branch, so narrow or blind per-task gates
  cannot add up to an unverified whole.* Record and display the effective scope
  of a verify; `verify passed (25 tests)` and `verify passed (2305 tests)` are
  different claims and must not read identically.

  **Partly closed 2026-09-12.** Orchid cannot count a stranger's tests — the
  verification command is arbitrary shell, and inventing a number would be the
  fabricated-evidence class this whole run is about. What it can state from
  facts it already holds is WHICH question was asked, so the evidence log now
  carries `scope: task` or `scope: repo` beside `command:`. A reader of a green
  log learns, without leaving the log, that the green describes a narrower
  question than the repository asks. The count itself stays open, and would need
  the verification command to report it.

## Track G — what the operator had to build, and what remains

The 2026-08-11 report is a *user's* account of adopting orchid. This track is the
matching evidence from the other side: r-002 initially could not be run
unattended without a 386-line hand-written supervision loop wrapped around
`runners/orchid-drive`. The resumed run retired several of its workarounds, but
the remaining ones are still gaps a real adopter meets on day one.

An operator who knows the internals writes this loop in an afternoon. An adopter
does not know it is needed, discovers each gap as a stalled run, and concludes
the tool does not work unattended. That is the whole competitive question:
orchid's governance kernel is the hard part and it is strong, but the layer a
user actually touches is the layer where it loses them.

**The loop's responsibilities, reconciled after r-002:**

- **Closed by T030 — re-pin `Formula/orchid.rb` after every implementer
  envelope.** Candidate verification no longer owns the release checksum;
  release/integration does, once, so the per-task conflict workaround is gone.
- **Still open — set the exec bit on any new `libexec/`, `scripts/`, `runners/` or `tests/`
  file staged at mode 644**, for the same reason — the implementer cannot
  `chmod`. r-002 handled this through explicit operator hand-offs; 1.0 still
  needs runtime capability proof or a supported automatic hand-off.

  **Re-measured 2026-09-12 — detection and non-charging already exist; only the
  automation is open.** `lib/drive.sh`'s hand-off classifier STATs the files a
  candidate ADDED *and* the files it MODIFIED whose base recorded mode 755,
  treats a regular file carrying a `#!` line with no execute permission as the
  hand-off state, and requires CAUSAL attribution — a failing line that names
  the file and reports a refusal to execute it — before waiving the attempt. So
  a 644 executable does not silently cost a round. What no verb can do is fix
  it, and that is the part needing capability proof.

  One reporting gap beside it was closed: `bin/orchid` gated on `[ -x ]` and
  reported a verb file present at mode 644 as `unknown command '<verb>'`. The
  file is there and only its mode is wrong, so that message sent the reader
  looking for something that was never missing — and since an implementer may
  not `chmod` and several engines recreate every file they touch at 0644, a new
  verb arriving 644 is the ORDINARY outcome of adding one. The dispatcher now
  names the mode, the path, `chmod +x`, and the `git update-index --chmod=+x`
  that records it; a genuinely absent verb is still `unknown command` and is
  never advised to chmod a file that does not exist.
- **Still open — rebase in-flight tasks onto a moved integration branch, but only in `rework`
  or `implementing`.** INV-07 invalidates verify and review evidence on a moved
  base, so rebasing eagerly where no evidence exists yet avoids an invalidation
  later; rebasing a task in `reviewing`/`arbitrating`/`merging` destroys exactly
  what INV-07 protects. Orchid does neither, so every merge either strands the
  siblings or costs them a round.

  **The supported action landed 2026-09-13; the automatic step did not.**
  `orchid task rebase <id>` rebases a task's own checkout onto the current
  integration head and re-stamps `base_sha`, so `orchid merge` no longer rebases
  that candidate and no round is spent on it. Legal only from `rework` and
  `implementing` — the two statuses where nothing has been verified or reviewed
  for this round, so there is no evidence for the new candidate sha to
  invalidate. From `testing` onward it REFUSES, naming INV-07 and the evidence a
  rebase there would destroy.

  It refuses rather than improvises on every other edge too: no recorded
  worktree, a checkout on the wrong branch, or any uncommitted change (git
  would refuse partway, and an uncommitted edit is the one thing in that tree
  that exists nowhere else). A conflicting rebase is ABORTED, journaled, and the
  checkout left exactly as it was, with both ways forward named.

  **Deliberately a verb and not a new step in the dispatch loop.** That loop is
  the most safety-critical path in the kernel, and a second process writing to a
  task worktree mid-rebase is the r-002/T013 defect reached from a new
  direction. What was missing was a supported ACTION — the retrospective's own
  rule — and a driver can call this one once someone has decided the automatic
  policy is safe. Wiring it into dispatch remains open.
- **Retired by T030 — skip conflicting pin commits and refuse to re-pin a dirty
  worktree.** Both were compensating controls for candidate-local pinning.
- **Closed in r-002 — continue the task walk past a judgment boundary.** A pass
  now visits every task before returning the highest-priority boundary, so one
  unanswered conflict no longer freezes unrelated work.
- **Partly closed by T027/T035/T040 — reap dead jobs and re-dispatch.** Launch
  failures, pid-0 manifests, missing envelopes, age, and liveness are now
  visible and recoverable. Engine-ledger recovery after genuine failures and
  the exhaustive F44 supported-exit audit remain open.
- **Partly closed by T029 — supply `ORCHID_EPOCH` on every verb invocation.**
  The setup hand-off now reads the current file instead of printing a stale
  literal, but callers still have to refresh after a newly fenced epoch.
- **Still open — read one task field without parsing `task show`** (F39).
  `task get <id> <key>` (and a deliberately audited append/amend verb) remains
  r-003 scope.

**The requirement this implies:** a supported unattended mode — `orchid run
--unattended` or equivalent — that performs the operator hand-offs it can
mechanically prove are safe, continues past boundaries while recording them, and
stops only for decisions that genuinely need a human. Anything the kernel refuses
to do automatically should say what would make it safe, rather than leaving the
operator to discover the gap as a stall. Track A's decision gates how far this
can go; the remaining hand-offs and progress reporting do not themselves require
a daemon.

## Track 0 — completed during the resumed r-002 run

r-002 was frozen on 2026-08-25 at 15 of 40 merged, then resumed on
2026-08-30. The six bootstrap repairs below ran in the required order before
the remaining carry-over work. All forty tasks are now merged at integration
`d9b1cd15174c0e75b424ebf9b64a8f953aca91b0`; the run is `accepting`, not
accepted. The final account is
[`docs/r-002-retrospective.md`](../r-002-retrospective.md).

**This track exists because of L041.** Orchid dispatches in `task list |
LC_ALL=C sort` — plain task-id order — and has no way to express priority. Every
task that repairs the run is numbered above T025, so id order scheduled them
*after* the twenty-five tasks that need the run to work. r-002 then hit each
defect while its own fix sat pending. That ordering error cost more than any
other single decision in the run.

These six are no longer r-003 work. Their ordering remains here as the record
of the bootstrap gate that allowed r-002 to finish.

| Order | Task | Fixes | r-002 result |
|---|---|---|---|
| 1 | **T026** | Real retry grants and supported reverify | Merged |
| 2 | **T027** | Visible launch failure accounting and pid-0 recovery | Merged |
| 3 | **T019** | Environment/operator failure classification | Merged |
| 4 | **T030** | Release-only formula pinning | Merged |
| 5 | **T039** | Attempt-pinned review plans with supported exits | Merged |
| 6 | **T035** | Process table with age and computed liveness | Merged |

The resumed run also closed four adjacent gaps: drive now walks every task
before reporting one boundary; non-planning passes reconcile jobs before
liveness checks; standing objections survive later reviews; and a clean pass
withdraws a stale boundary. Three follow-ons remain r-003/1.0 work:

- **The engine ledger still needs a recovery path after genuine failures.**
  `consecutive_failures` resets only on a success from an engine the resolver
  will no longer select. Add decay, retry-after, an operator verb, or a
  half-open probe.
- **Task worktrees still need lifecycle cleanup.** Successful tasks leave
  sibling worktrees behind; removal exists for merge temporaries but is not
  wired to task completion.

  **Closed 2026-09-12.** A completed merge now releases the task's own
  checkout, under conditions that make it provably safe: the merge succeeded
  (so the branch is contained in the integration branch), the checkout is clean
  with `git status --porcelain` empty — untracked counts as dirty, because an
  untracked file is the one case where those bytes exist nowhere else — and it
  is not the directory the command is running in. Every other case KEEPS the
  checkout and says so, naming the `git worktree remove` to run;
  `git worktree remove` is called without `--force`, so git's own refusals
  stand. The BRANCH is deliberately untouched: merge cleans up the checkout,
  `run new`'s rollover guard cleans up the ref, and that division is what lets
  the guard's remedy be a plain `git branch -D`. `worktree_remove_on_merge=off`
  keeps the old behaviour. This does nothing for checkouts stranded by merges
  that already happened — r-002's forty are still an operator cleanup.
- **Supported exit is not yet a whole-tree invariant.** r-002 audited the four
  pattern-defining refusal points as 4/4 repaired, but did not derive an
  exhaustive inventory. A guard that refuses must name the supported action
  that clears it; if no verb provides one, the guard is unfinished.

  **Sized on 2026-09-12, and deliberately not built, because the obvious
  version of it would be a check that cannot fail.** The shipped tree has 418
  `orchid_die` sites; 276 name no command. A gate asserting "every refusal names
  an `orchid` or `git` command" would therefore demand one at 276 sites, and it
  would be wrong at most of them:

  - Most are CALLER errors — `--task requires a value`. There is no state on
    the refused side. The supported action is to retype the command, and
    pasting a verb onto that message manufactures the appearance of recovery
    where nothing needs recovering.
  - It is satisfiable by boilerplate. Once contributors learn to paste a
    command, the gate passes for a reason unrelated to the property, which is
    precisely the class docs/specs/kernel.md's proof-discipline section exists
    to reject.
  - Several sites die with `"$usage"` — a variable. Any text-matching rule is
    blind to those and would pass them vacuously while failing honest
    neighbours, so its RED case would be measuring the spelling of the call
    rather than the quality of the message.

  The rule that is actually load-bearing is narrower: a refusal must name a
  clearing action **when the refused side leaves durable state the caller
  cannot change by retyping**. That is a classification per refusal — can the
  operator get back unaided? — not a property of the message text, so it cannot
  be derived the way INV-17 derives its subject list. Whoever takes this should
  budget for reading the refusals, not for writing a matcher. The four
  pattern-defining points, and the `retry`/`reverify`/`infra-fail` messages
  closed under F44, are the worked examples of what the answer looks like.
