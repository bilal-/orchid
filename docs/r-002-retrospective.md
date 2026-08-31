# r-002 retrospective — the 40-task result and what beta still lacks

**Orchid's characteristic defect is the unescapable state.** A guard refuses
something unsafe, but the state on the refused side has no supported way back.
The guard is locally correct — do not merge a conflicted tree, do not count
independence that was not proved, do not retry forever, do not launch twice —
and the system around it is incomplete. A recoverable incident becomes durable
state that only a human can hand-edit or route around. In an unattended run,
that silently changes “unattended” to “attended.”

**The design rule is therefore:** a guard that can refuse must name, at the
point of refusal, the supported action that clears it. If no verb provides that
action, the guard is not finished.

This is the final retrospective for r-002's 40-task hardening result. The first
draft was frozen on 2026-08-25 after 15 tasks had merged; it correctly recorded
why the run had stalled, but it could not describe the repairs and further
failures found by the remaining tasks. This version was written from the
assembled integration tree at `1686c5dc9513f139b4b3b2ff77f58e0cb89bed44`,
which contains 39 task merges; T038, this document, is the fortieth task.

The shipped version remains **`1.0.0-beta.1`**, within the
`1.0.0-beta.x` series. This retrospective is not run-acceptance evidence and is
not a release announcement. The still-open acceptance observations are kept in
[r-002-acceptance-evidence.md](./r-002-acceptance-evidence.md).

## The pattern, four times

The four independent mechanisms that established the pattern were:

1. **L022 / T030 — per-candidate formula pinning.** Every candidate changed the
   same content-derived checksum line. After the first merge, every later
   candidate rebased into a conflict and the configured implementer could not
   run the command needed to regenerate the pin. A safety check against a stale
   release artifact became a permanent merge deadlock.
2. **L027 / T039 — the reviewing dead end.** Review routing was recomputed from
   live engine health after evidence had been filed. The new table could orphan
   valid reviews, the forward edge required those reviews, and no backward edge
   could either adopt the evidence or rebind the unfilled slots.
3. **T026 — attempt exhaustion.** `attempts` was kernel-owned, the cap was
   fixed, and `unblock` or `retry` restored a status without restoring a round.
   A task whose budget was consumed by environmental or operator failures had
   no verb that could make another attempt legal.
4. **T027 — the proposed launch refusal.** The first design used exit 17 (the
   shipped registry ultimately assigns this condition exit 18) to refuse a
   second launch over a pid-0 manifest. In `PLANNING`, the reaper that could
   clear that manifest did not run. The fix for unbounded duplicate launches
   would therefore have created another permanent state.

The fourth appeared **inside a fix for the same class of failure represented by
the third**. That is the strongest evidence from this run that unescapable state
is a design habit, not four unrelated oversights.

### Supported-exit audit of the shipped fixes

The audit is deliberately closed over those four pattern-defining refusal
points. For each one, inspect the refusing guard, the action printed at that
point, and the regression case that recreates the old wedge. On the assembled
tree the result is **4 of 4**:

| Refusal point | Supported exit now shipped | Executable regression evidence |
|---|---|---|
| Formula pin | Candidate verification no longer owns the pin. The release gate in `scripts/release.sh` refuses a stale tag and names `bash scripts/pin-formula.sh`, the integration-branch formula-only commit, re-tag, and retry. | T030 sections in `tests/test_ci_release.sh` and `tests/test_merge.sh` reproduce the two-candidate conflict, prove candidates no longer touch the pin, and keep a stale release refused. |
| Review plan | The attempt's slot table is pinned. A boundary names `orchid jobs review-plan <id> --adopt-evidence` for reviews filed under the former routing, `--repin` for unfilled unavailable slots, or the universal blocked edge. | T039 sections in `tests/test_review_routing.sh` and `tests/test_drive.sh` reproduce the live-table orphan and the two legal exits. |
| Attempt cap | The blocked page names `orchid task retry <id> --attempts N` to grant rounds and `orchid task reverify <id>` when the existing tree is already green. Neither rewinds the audit counter. | T026 sections in `tests/test_task.sh` and `tests/test_drive.sh` construct an exhausted task, grant budget, and reverify without spending an attempt. |
| Unlaunched manifest | The refusal and reaper share `job_unlaunched_reapable`; the message names `orchid jobs gc`, and the drive runs the matching reap in every phase, including `PLANNING`. | T027 sections in `tests/test_jobs.sh` and `tests/test_drive.sh` construct the pid-0 orphan and prove the planning path can leave it. |

The exact proof commands are:

```sh
/bin/bash tests/test_ci_release.sh
/bin/bash tests/test_merge.sh
/bin/bash tests/test_review_routing.sh
/bin/bash tests/test_task.sh
/bin/bash tests/test_jobs.sh
/bin/bash tests/test_drive.sh
```

They were **not run by the T038 implementer**; this task's hand-off explicitly
forbids verification. “Executable regression evidence” here means the RED cases
exist in the shipped tree, not that this candidate observed them pass.

Nor is 4 of 4 a claim about every non-zero exit in the CLI. r-002 did not ship
an exhaustive, machine-checked inventory that rejects a new guard lacking a
recovery verb. Outside this closed set, the design rule is still review policy.
Turning it into a derived whole-tree invariant is a 1.0 prerequisite.

## What the run found about the system

The useful grouping is by what the failures say about Orchid, not when they
were discovered.

### Evidence can exist and still prove the wrong thing

- **L023:** entry to `rework` deleted the verify log while journaling a pointer
  to that same log. The next implementer was told to read evidence the recovery
  step had destroyed, so three byte-identical failures looked like three new
  attempts. The shipped path captures round-scoped rework evidence before
  invalidating the live gate file and feeds it into the next brief.
- **L024:** the suite was not isolated from another Orchid running on the same
  machine. Shared state below `HOME` made roughly twelve notification assertions
  fail for a concurrent drive loop rather than for the candidate. The hermetic
  suite now gives its nested run a disposable home and proves it against a
  concurrent writer. A second Orchid mutating the **same checkout** remains an
  explicit operator-owned, not-tested scheduling constraint.
- **L025:** an implementer could file an envelope and keep working. Orchid read
  one commit, then verification exercised a later one while the evidence named
  the first. Hand-off work could create the same lie by committing after
  `candidate_sha` was captured. Reconcile now waits for the job to resolve;
  hand-off advances the candidate; and `orchid verify` refuses with exit 20 if
  the worktree is not the recorded candidate or moves during the suite.
- **Dogfood F32 / T033:** a `request-changes` verdict could carry an empty
  `findings[]`. Every severity gate then weighed nothing, while the objection
  lived only in prose. Reconcile now synthesizes a blocking finding from a
  prose-only non-approve verdict, and deterministic approval discloses when the
  severity gate received zero structured findings. An approving verdict-only
  adapter may still legitimately file an empty array; the record now says that
  approval rests on `verdict + scope_complete`, rather than pretending the
  severity gate supplied a second opinion.
- **Dogfood F33 / T032:** an arbiter requested changes twice, naming the same
  concurrency defect and exact location. A later pair of reviewers, shown no
  memory of that objection, unanimously approved the unchanged defect, and the
  deterministic rule silently overrode the arbiter. A request-changes
  arbitration is now durable as a standing objection. Fresh reviews cannot
  erase it; only an arbitration with at least the authority that raised it can
  clear it.

The general lesson is broader than evidence binding by SHA. A check can pass
for the wrong reason; evidence can be present but describe a different run; and
a structured field can exist while carrying no substance for the gate that
reads it. “The file exists” and “the command exited zero” are not proof
statuses.

### Work was charged to budgets it never consumed

- Candidate attempts absorbed formula-pin conflicts, missing executable modes,
  ambient-state flakes, operator prerequisites, and launch failures. Those are
  different owners and need different counters. The shipped driver now
  distinguishes candidate failures, waived environment/handoff failures, and
  infrastructure failures, and preserves the evidence used for attribution.
- A clean no-op delivery was once charged as failure. That rule blocked 27 of
  40 tasks in four hours and held its own repair seven times. The correct
  question is whether the actor delivered a candidate, not whether a diff is
  non-empty in every legitimate rework situation.
- A designed capability refusal was counted as an engine fault. Three such
  refusals could exclude an engine permanently, change a live review plan, and
  strand evidence. Capability refusal now has its own ledger status and count;
  it is visible without poisoning availability.
- L026 showed the same accounting error at run scope: exit 16 meant “a decision
  is outstanding somewhere,” but the supervisor treated it as “stop the whole
  pass.” The driver now walks every task, records the highest-priority boundary
  at the end, pages each distinct operator stop, and keeps unrelated work
  moving.

### Durable state crossed boundaries it did not own

- In the webBooks run, a newline in a `task set` value made `awk` fail after
  opening the destination and truncated the task record to **zero bytes**.
  `task show` then returned success over the empty file. Task values are now
  single-line validated before mutation, writes are atomic, and malformed or
  empty records refuse loudly.
- A launch that failed before stamping a pid left a manifest that neither the
  old liveness ladder nor garbage collection owned. One external run produced
  73 pid-0 manifests in 73 passes. The shipped manifest states and reaper now
  cover never-started and unstamped jobs without treating every pid 0 as dead.
- The scheduled pump outlived the webBooks run it served and could outlive the
  worktree it targeted. Service records are now bound to the checkout and
  scheduler identity, finished runs are visible, wake budgets are bounded, and
  teardown has an enforced order. Installation is still machine-local and its
  real scheduler behavior is not proved by a portable unit fixture alone.
- Orchid's durable run state reached webBooks' product `main`, which ended up
  tracking 14 orchestration files. The shipped pre-push hook refuses newly
  reachable run state on product refs, while merge-time containment detection
  is intentionally **advisory** because Orchid does not own the product merge.
  Already-published history and a machine without the installed hook remain
  operator problems; the warning is not containment by itself.
- Eighty-nine judgment pages accumulated during r-002 while no notification
  pump was scheduled, then expired into an answer state no verb could clear.
  Question choice sets, answer validation, de-duplication and scheduling
  diagnostics are stronger now, but a live outbound-and-return round trip is
  still a per-machine operator qualification step.

### The product model assumed the author's repository and machine

The webBooks and wasiyyat runs were valuable external-repository dogfoods, but
they were still operated by Orchid's author and are not third-party beta runs.
They exposed assumptions the self-host could not:

- gitignored dependencies and multi-gigabyte data were absent from task and
  merge worktrees;
- a task that authored a database migration could not apply its own operator
  prerequisite, so a missing schema looked like defective code;
- generated artifacts overflowed reviewer packs, and launch failure was once
  silent;
- a comma-joined dependency list rendered like a valid wait but could never
  match a task id;
- a plugin's declared `shell` capability did not prove that the vendor session
  was actually allowed to execute a command; and
- a schedule, trust record, installed hook, vendor quota and live notification
  channel are properties of one machine, not properties of a Git commit.

The shipped tree has preparation hooks, operator prerequisites, capability
routing, pack controls, dependency validation and better diagnostics for these
classes. Their existence is not evidence that an unfamiliar operator can
configure them correctly from the docs or that every vendor profile grants the
capability its manifest declares.

## What the operator broke, and initially blamed on Orchid

A substantial share of r-002's lost work was operator-caused. Omitting that
would turn a retrospective into advocacy.

The largest single attempt destroyer was the operator's workaround for the
implementer hand-off gap: the formula re-pinning loop. **Three task-attempts
were lost, split 1:2 — one third on T021 and two thirds on T006.** T021 spent
its entire available budget on one stale-pin failure with nothing else wrong.
Two T006 rounds verified a pin that was four hours stale because the
supervisor's liveness guard suppressed every re-pin in between. Three attempts
lost to the workaround is more than any one product defect consumed. The right
repair was T030's: remove the whole-tree formula pin from every task's
verification chain and pin once at release, not automate the hand-off more
cleverly.

The operator's conflict tooling also stripped executable mode bits from three
executables, stranding **T019, T025 and T027**. When T019 stranded first, the
operator classified it as an implementer hand-off, unblocked the task on that
basis, and journaled the irony that the task which classified failure ownership
had been killed by the class it existed to classify. The reasoning was
coherent end to end and wrong at its root: the operator's own merge tooling had
removed the bits. Some of the run was not merely operator-caused; it was first
misattributed to the product.

The operator also ran drive or merge beside a live supervisor, launched
duplicate supervisors, relied on zsh word splitting that executed zero loop
iterations, and fixed one boundary halt by reporting it 337 times rather than
making progress past it. These were procedural failures, not evidence that the
review judgments themselves were noisy.

Operator hand-off commits, including legitimate formula or mode repairs made
under the run's then-current protocol and trailered `Orchid-Handoff: operator`,
are not implementation violations. The failure was the gap and the scaffolding
built around it. A workaround that generates more defects than the condition
it works around is not a papercut.

## What is proved, and what is not

| Proof status | Honest claim |
|---|---|
| **Enforced in code and represented by a RED case** | The four supported exits above; round-scoped rework evidence; candidate/verify binding; synthesis of a prose-only non-approve finding; durable arbiter objections; task-value newline refusal; pid-0 convergence; attempt grants; boundary walks that continue across tasks; release-only formula freshness. This task observed the code and cases but did not execute them. |
| **Advisory** | The merge-time product-state containment warning; beta and acceptance checklists whose rows `orchid run accept` does not parse; the requirement not to verify while another Orchid mutates the same checkout; a manifest's positive capability declaration; the 1.0 criteria in this document. Advisory means a human must still act. |
| **Proved only on this machine or in a local fixture** | r-002's own history; the operator's recorded focused checks; the 13m19s local release rehearsal; isolated scheduler, trust, hook and no-network fixtures; any live vendor or Telegram observation made during dogfood. These do not establish behavior on another operator's machine. |
| **Operator-owned and unproved** | Final T038 docs verification; the canonical final-candidate CI run; the post-merge suite from the integration-branch checkout; hosted CI after a push; a live command-execution probe for every implementer profile; a complete notification return-leg qualification; a genuine third-party beta; and publication. Open means open, never pass. |

Most importantly, **no genuine third-party beta run has occurred**. webBooks
and wasiyyat were real product repositories, but the author operated them and
supplied the recovery knowledge. No public release has occurred either. Nothing
was pushed, tagged, uploaded, deployed, published or announced by this run, and
the release step remains the operator's.

## What beta still lacks

Orchid is fit for continued private, operator-attended beta work. It is not yet
proved safe for an unfamiliar person to run unattended. The gap is no longer
“does the kernel have review and merge guards?” It is whether the whole system
can encounter a refusal, explain it, recover through a supported verb, preserve
the evidence and charge the right owner without its author supervising the
loop.

Specifically, beta still lacks:

- a genuine third-party run from setup through acceptance on a repository and
  machine the author does not control;
- runtime proof that each selected implementer can execute the commands its
  work requires, rather than a manifest declaration being treated as a grant;
- a full live notification round trip, including detection of a missing inbound
  answering agent;
- enforced containment that keeps run state out of product history without
  relying on an installed local hook or an operator noticing an advisory;
- an exhaustive supported-exit invariant for new refusal points;
- proof that the final assembled integration tree and hosted workflow are
  green; and
- evidence that an unattended run survives the same-checkout, long-suite,
  scheduler and generated-artifact pressures that required the author's
  supervisor in r-002.

## The requirements for 1.0

The version stays in `1.0.0-beta.x` until all of the following are true:

1. **Close the final proof rows on the exact released tree.** Run and record the
   canonical candidate check, the assembled integration-branch check and hosted
   CI against the SHAs they actually exercised. No candidate-local pass may be
   relabeled as post-merge or remote evidence.
2. **Complete at least one genuine third-party beta.** The tester must own the
   repository and machine, follow the published setup, run through acceptance,
   and report every intervention. Fix blocking findings and repeat until the
   run completes without hand-editing durable state or using an undocumented
   supervisor.
3. **Make supported exit an invariant, not a lesson.** Derive the inventory of
   user-facing refusal points from the shipped tree. Each refusal must have a
   tested clearing verb or a deliberately terminal classification, and its
   message must name that action at the refusal site.
4. **Prove capabilities at runtime.** A selected profile must demonstrate the
   command execution, file-mode change and repository operations its tasks
   require, or Orchid must refuse before dispatch and route an explicit
   operator hand-off. A positive manifest atom alone must never qualify 1.0.
5. **Exercise the evidence chain end to end.** On the final tree, prove that a
   moving candidate cannot be verified, a non-approve verdict cannot weigh an
   empty severity record, and a standing objection cannot be erased by a later
   unanimous round. Keep the RED cases and observe them in canonical CI.
6. **Close lifecycle and containment on a product repository.** A finished or
   removed run must not leave a useful-looking scheduled pump behind, and run
   state must not reach product history silently. The supported cleanup and
   export path must work without author knowledge.
7. **Qualify the human boundary.** A blocker must travel out and its answer must
   travel back on the documented channel; expired, duplicate and unanswerable
   questions must all have supported exits and visible ownership.
8. **Demonstrate unattended operation under real pressure.** Use a long suite,
   concurrent machine-local activity, gitignored dependencies, generated
   artifacts, rework and at least one deliberate refusal. The run must keep
   unrelated tasks moving, preserve evidence, and charge no candidate attempt
   for work the candidate did not consume.
9. **Only then perform the public release.** The operator re-pins the formula
   once on integration, runs the local release gate, creates and pushes the
   immutable tag, observes hosted CI, publishes the prepared distribution
   surfaces and changes the version from beta. Those outward actions are not
   delegated to a task candidate.

## Verdict

r-002 succeeded as a hardening run because it falsified the claim Orchid most
needed tested: that a correct deterministic kernel was enough for unattended
operation. It was not. The run found and repaired serious state, evidence,
accounting, lifecycle and containment defects, and its review machinery caught
real problems. It also needed extensive operator scaffolding, and that
scaffolding caused and misattributed a substantial fraction of the lost work.

The honest release posture is therefore **beta, private, and operator-led**.
The kernel is much harder to fool than it was at task 1. The product has still
not shown that someone other than its author can get out of every state it can
enter. That is what the remaining beta and the 1.0 bar must prove.
