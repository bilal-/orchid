# r-002 run-level acceptance evidence — candidate hand-off

Status: **NOT YET ACCEPTED. Operator completion is required after merge.**

This file began as the candidate's honest hand-off, not a claim that the run
was complete. A commit cannot observe the merged tree that will contain
itself, and T015's mandatory implementer hand-off forbade running the verifier.
The candidate-time matrix therefore remains unchanged as historical evidence;
the operator observations made after merge are recorded separately below.
Only an operator-completed copy is suitable for `orchid run accept`.

## Identity and scope

- Run: r-002
- Task: T015
- Integration base inspected by this task: `51f5fa3c59cfe2b18d756ab99318b0730a5629b7`
- Partial candidate preserved at task start:
  `d0690c85349a4c5f129bdcc006832b7ff908ddbd`
- Final T015 candidate: `d38e8ed8a16903b949613de8aa405b9b4cfe8447`
- T015 merged integration: `1686c5dc9513f139b4b3b2ff77f58e0cb89bed44`
- Final 40-task integration after T038:
  `d9b1cd15174c0e75b424ebf9b64a8f953aca91b0`
- Source release metadata remains `1.0.0-beta.1`, within the required
  `1.0.0-beta.x` posture. No version was promoted by this task.

## Acceptance matrix

| Observation | Status in this candidate | Command/evidence the operator must record |
|---|---|---|
| Documentation gate | **NOT RUN** — mandatory implementer hand-off | `/bin/bash tests/test_docs.sh` |
| Canonical candidate-local CI | **NOT RUN** — mandatory implementer hand-off | `/bin/bash scripts/ci-local.sh --bash /bin/bash`, from this candidate checkout; record branch, HEAD, exit status, and log path |
| PATH-restricted no-vendor-CLI proof | **NOT RUN** — part of canonical CI | Record the `tests/test_hermetic_suite.sh` result emitted by the command above. When no vendor CLI exists on the outer PATH, retain its explicit `NOT-TESTED` duplicate-run record and the surrounding suite result rather than relabeling it a nested pass. |
| Merged-tree check | **NOT POSSIBLE FROM THIS CANDIDATE** | After T015 merges, resolve the assembled integration HEAD and inspect the merged documentation/code there. Record the commit. |
| Suite on the integration branch itself | **NOT RUN; REQUIRED AFTER MERGE** | From a checkout actually parked on the configured integration branch at the assembled HEAD, run `/bin/bash scripts/ci-local.sh --bash /bin/bash`; record branch, HEAD, exit status, and log path. A task worktree or merge temp worktree does not satisfy this row. |
| Hosted GitHub Actions | **NOT OBSERVED BY THIS RUN** | After the operator pushes, identify the workflow run and use `gh run watch <run-id> --exit-status`; record the run URL/id and conclusion. The candidate contacted no remote and makes no green-CI claim. |

## Post-merge operator follow-up — 2026-08-31

- T015's exact candidate `d38e8ed8a16903b949613de8aa405b9b4cfe8447`
  passed its formal verifier with `CI PASS`, exit 0, including the
  PATH-restricted hermetic suite. The bound run evidence is
  `.orchid/reviews/T015-verify.log`.
- T015 merged at integration
  `1686c5dc9513f139b4b3b2ff77f58e0cb89bed44`. From a checkout actually parked
  on `orchid/integration` at that SHA, the operator ran
  `/bin/bash scripts/ci-local.sh --bash /bin/bash`; it exited 0 with `CI PASS`.
  The local log is
  `/private/tmp/orchid-r002-post-t015-integration-1686c5dc.log`, and the durable
  journal records the same command, branch, SHA, and result.
- T038 changed only `docs/r-002-retrospective.md`. Its declared
  `/bin/bash tests/test_docs.sh` verification passed, its whole-tree static
  merge gate passed, and it merged as the fortieth task at
  `d9b1cd15174c0e75b424ebf9b64a8f953aca91b0`.
- The driver then moved the 40/40 run to `run_status: accepting` and raised the
  operator-only `run-complete` boundary. No `orchid run accept` was run.
- Hosted CI, genuine third-party beta qualification, publication, and release
  remain unobserved and open.

The local equivalent of the workflow is not an approximation invented here:
`.github/workflows/ci.yml` invokes `/bin/bash scripts/ci-local.sh --bash
/bin/bash` on its hosted jobs. Local success still cannot prove that a remote
workflow ran, and candidate-local success cannot prove the integration-branch
ambient condition.

## Why the integration-branch row is separate

Lesson L036 was demonstrated by commit
`416fcc9a9c24a9dd6ca5ab3fc12c175ba36a9ce6`: the suite failed five checks when
that commit was checked out on `orchid/integration`, while the identical commit
passed on another branch name. The relevant kernel guard returned early in
every task worktree and merge temp worktree because neither can be parked on
the integration branch. Re-running either gate could never exercise the
condition.

The resulting rule is now in PROTOCOL.md, contributing guidance, the kernel
and operations specs, both quickstarts, troubleshooting, beta qualification,
and the lifecycle diagrams: a path conditioned on branch identity, install-root
identity, or another property a temp worktree cannot possess needs a test that
constructs the condition, and run acceptance still executes once in the
ambient integration-branch checkout.

## Documentation reconciliation

The candidate reconciles these surfaces against the assembled behavior:

| Surface | Reconciled fact |
|---|---|
| `README.md` and `docs/architecture.md` | Pump/tick runs deterministic drive first; only a settleable boundary wakes judgment; no-candidate delivery, verify refusal, persistent objection, and location-bound acceptance are visible edges rather than prose-only exceptions. |
| `PROTOCOL.md` | The complete `implementing` and testing-FAIL arms were read as one procedure; the merged arms are ordered once, with no superseded advance, duplicate close, or sentence splice. COMPLETION distinguishes candidate, integration-branch, and remote observations. |
| `docs/specs/kernel.md` | Acceptance evidence is location-bound; candidate evidence cannot pre-claim the post-merge row. |
| `docs/specs/operations.md` | The operator walkthrough requires the assembled integration-branch run and records hosted CI separately. |
| `docs/specs/roadmap.md` | The binary release checklist includes the assembled integration-branch suite and operator-observed hosted CI. |
| `docs/specs/plugins.md` | Audited; the qualification threat-model boundary and shipped adapter claims remain consistent. No change was required. |
| `docs/engines/*` | Every guide now bounds local CI correctly: the hermetic run proves no ambient vendor CLI dependency, not a live vendor session, quota spend, or phone delivery. |
| `docs/configuration.md` | `integration_branch` now owns an ambient acceptance run, not only the ref merge advances. |
| `docs/install.md` | Run acceptance precedes release-day pin/tag work; whole-tree formula pinning remains integration/release-owned. |
| `docs/troubleshooting.md` | Adds the integration-branch-only failure diagnosis and the rule to construct ambient conditions in tests. |
| `docs/beta-qualification.md` | Separates beta qualification/rehearsal from run acceptance and leaves third-party beta, post-merge CI, and publication operator-owned. |
| `docs/contributing.md` | Records all four textual-gate incidents, exact ShellCheck idioms, the ambient-condition rule, and why parallel edits to one numbered procedure need one final owner. |
| Quickstarts | `run_status: accepting` is an operator boundary; evidence is completed before acceptance and service teardown remains separate. |
| Changed command/help surfaces | Audited `answer`, `doctor`, `jobs`, `merge`, `notify`, `plan`, `run`, `start`, `task`, `trust`, `verify`, launch, drive, orchestrator-command, service, beta qualification, local CI, formula pinning, and local release. The terse usage-only verbs retain current flags/subverbs; full help now names no-candidate triage, verify refusal, persistent-objection authority, schedule persistence, hermetic CI scope, and release-only formula pinning where relevant. |

## Recorded decisions: choice and rejected alternatives

### T011 — qualification execution and trust

- **Choice:** beta qualification runs the target repository's configured
  `verify=` command once, in place, after an explicit stderr notice. The
  foreground qualification command has no unattended-trust or separate
  acknowledgement prerequisite; `--no-run-verify` remains the opt-out.
- **Rejected alternative 1:** reuse unattended trust. Rejected because trust is
  deliberately granted only after qualification; requiring it first inverts
  the safety order and leaves trust open for a repository that may fail.
- **Rejected alternative 2:** introduce a qualification-scoped trust record.
  Rejected because it creates a second machine-local trust lifecycle for one
  foreground, visible command without narrowing what that command executes.
- **Rejected alternative 3:** make `--no-run-verify` the default. Rejected
  because a skipped timing probe cannot qualify verify duration and must be
  reported as `not-tested`, not passed.
- Normative record:
  `docs/specs/operations.md`, “Qualification runs the target verify command
  and takes no acknowledgement.”

### T012 — review depth

- **Choice:** at medium/high risk, deterministic approval requires at least one
  reconciled review credited to a pinned `worktree` slot. A missing or invalid
  depth proof becomes an arbitration boundary; routing still fills every slot.
- **Rejected alternative 1:** refuse routing or dispatch when no
  worktree-capable reviewer is available. Rejected because it converts an
  evidence-quality shortfall into permanent availability failure and pressures
  operators to mislabel risk.
- **Rejected alternative 2:** add a task flag or scan acceptance prose for
  “interaction with existing behavior.” Rejected because the kernel does not
  judge prose and a second hand-set risk field would drift from `risk_tier`.
- **Rejected alternative 3:** add a global `review.require_depth` switch.
  Rejected because it would silently disable the evidence record for every
  task; the per-task arbitration boundary is already the explicit escape hatch.
- Normative record: `docs/specs/kernel.md`, “Review depth (v1.1 — decision,
  T012).”

## Gate regressions closed in the candidate

- The documentation verb extractor now treats only a code span beginning
  `orchid <verb>` or a command line inside a fenced block as an invocation. It
  checks README.md, PROTOCOL.md, and both quickstarts. Its RED probe supplies a
  fictitious code-span verb and a fictitious fenced command; its GREEN probe
  supplies the prose shape “orchid creates” and extracts nothing.
- INV-13's operation scan removes inert single-quoted and double-quoted string
  contents before checking for forbidden worktree commands. Its RED probe
  performs a real forbidden operation; its GREEN probe prints the diagnostic
  words `git worktree add` without performing that operation. Data selectors
  and redirection targets remain raw-text checks by design.
- Orchid cannot change ShellCheck parsing. Contributing guidance now warns that
  a bare shell keyword used as data (for example unquoted `done`) triggers
  SC1010, and that backticks or angle-bracket placeholders inside a
  double-quoted annotation are parsed as shell syntax.

These were not executed by the implementer. On 2026-08-30 the operator ran
the focused documentation test and INV-13 production probes against candidate
`43432aef115cf7866e87da927039a9942719ec4d`; both passed, including the quoted
boundary path, `bash -c`, `sh -c`, bundled `bash -lc`/`sh -ec`, preceding shell
options, and command-position `$BASH -c` cases. Bash syntax, warning-level
ShellCheck on every changed shell file, and the exact
`scripts/ci-local.sh --bash /bin/bash --no-tests` static gate also passed. The
canonical full candidate-local CI row remains open until Orchid's formal
verification runs against the final operator-hand-off SHA.

## Bootstrap-journal audit

Status: **OPERATOR AUDIT COMPLETE; REQUIRED RECORDS ARE MISSING.** The task
rule forbids an implementer from touching run state, so the operator read the
journal after the candidate hand-off and recorded the result through Orchid.

The three merge cutoffs visible in Git history are:

- T001: `c1d7550b970b9f4db952a7d9ce5cc62d77067ae7` (2026-08-10)
- T010: `df47066e67f5467fc32664337804016aa1acc4e3` (2026-08-11)
- T006: `416fcc9a9c24a9dd6ca5ab3fc12c175ba36a9ce6` (2026-08-12)

The latest of the three cutoffs is the T006 merge at
`416fcc9a9c24a9dd6ca5ab3fc12c175ba36a9ce6`, recorded at
2026-08-12T09:47:20Z. Before that cutoff the journal contains 117 dispatch
passes and **zero complete four-part bootstrap entries**. The only entry that
names the bootstrap procedure, at 2026-08-09T16:04:39Z, records the integration
checkout refresh and its root-file clobber hazard only. It does not record the
outstanding-job check, mechanical hand-off outcome, or whether exact lint
locations had to be carried by hand. No later task event is treated as a
substitute for the one-per-pass record the procedure required.

| Task | Unmatched dispatch passes |
|---|---:|
| T001 | 1 |
| T006 | 16 |
| T010 | 9 |
| T013 | 7 |
| T014 | 7 |
| T017 | 4 |
| T018 | 5 |
| T019 | 16 |
| T020 | 1 |
| T021 | 11 |
| T022 | 9 |
| T023 | 8 |
| T024 | 6 |
| T025 | 6 |
| T026 | 6 |
| T027 | 2 |
| T028 | 1 |
| T031 | 2 |
| **Total** | **117** |

Operator result: **117 unmatched dispatch passes.** This is an audit finding,
not inferred compliance and not a reason to rewrite history. It is recorded as
a T015 ledger item in the durable journal. The run remains unaccepted.

## Lesson reconciliation

The published guidance is reconciled in this candidate:

- the four prose/string-literal gate incidents are one systematic lesson, not
  four style workarounds;
- the two independently mangled PROTOCOL arms become one lesson about parallel
  edits to an ordered procedure;
- L036's branch-conditioned-path finding now owns a concrete run-acceptance
  row;
- T030's whole-tree formula policy supersedes any candidate-level formula-pin
  hand-off. Formula pinning is integration/release-owned; executable mode bits
  remain candidate hand-offs only when a new executable actually exists.

After the implementer hand-off, the operator reconciled durable lesson state
through Orchid's lesson verbs:

- updated L011 (the remaining answer-refusal ownership gap), L032 (general
  candidate freeze without obsolete Formula advice), L034 (T015 gate
  oscillation evidence), and L043 (the post-T030 hand-off procedure);
- retired L013, L014, L016, L017, L018, L020, L023, L025, L026, L027, L031,
  and L039 because their owning repairs have landed or their candidate-level
  Formula rule was superseded;
- added L044 for concurrent edits degrading one ordered procedure and L045 for
  treating a vendor weekly-quota exit as capacity rather than a generic engine
  failure;
- reviewed and retained L036's constructed-condition/integration-branch rule;
  and
- left L029 active at candidate hand-off until T015 itself merged, because its
  invalidation condition was the repaired documentation gate landing on
  integration.

Operator result: **COMPLETE FOR THE CURRENT CANDIDATE.** The run remains
unaccepted. After T015 merged, the operator retired L029 through
`orchid lessons retire`; the durable journal records the transition and reason.

## Mandatory task hand-offs and release posture

- Verification, ShellCheck, and Bash were **not run by this implementer**.
- `Formula/orchid.rb` was **not touched**. T030 removed per-candidate formula
  pinning; integration/release pinning remains operator-owned.
- This task adds no executable. No mode change and no chmod hand-off exists.
- No third-party beta run has occurred.
- Nothing was published, pushed, tagged, uploaded, deployed, announced, or
  sent to a remote by this run.
- Remote CI was not observed by this run.
- The shipped version remains `1.0.0-beta.1` (`1.0.0-beta.x` posture). Nothing
  in this evidence claims a public release or `1.0.0` qualification.

## Hosted CI — observed 2026-09-02, and what it does and does not cover

The hosted row above is now filled by observation rather than by inference,
and the observation includes the two runs that failed.

| Run | Head SHA | Branch | Conclusion |
|---|---|---|---|
| [33459387731](https://github.com/bilal-/orchid/actions/runs/33459387731) | `c080bf35` | `main` | **failure** |
| [33566887753](https://github.com/bilal-/orchid/actions/runs/33566887753) | `aae7e9b9` | `main` | **failure** |
| [33577759163](https://github.com/bilal-/orchid/actions/runs/33577759163) | `7dcb58bcf333627a1f50e428834d03b6b52b80fe` | `main` | **success**, 58m34s, workflow `CI` |

Read it exactly as it stands:

- **The green run is on `main`, not on the 40-task integration SHA.**
  `7dcb58bc` contains `d9b1cd15` (through merge `eb719732`) plus three later
  commits. The tree the run assembled was never itself observed on hosted CI.
- **The 40-task tree as merged did not pass hosted CI.** Two commits were
  required to make it green: `aae7e9b9` (Ubuntu ShellCheck 0.9 compatibility,
  touching `lib/common.sh` and two test files) and `7dcb58bc` (deterministic
  service platform fixtures). Both were authored directly on `main` by the
  operator, outside the run's task machinery, so neither carries a task record,
  a review, or a journal entry.
- The retrospective's "canonical full-CI run against the exact final 40-task
  integration SHA `d9b1cd15`" row is therefore **still open**, and closing it
  would require pushing that SHA and observing its own workflow run.

## Remaining operator completion block

The final T015 SHA, candidate-local CI, integration-branch CI,
bootstrap-journal audit, lesson reconciliation, L029 retirement, and now the
hosted workflow rows are recorded above. Before `orchid run accept`, the
operator still must record:

1. the operator's acceptance reason; and
2. a decision on the exact-SHA row: either push `d9b1cd15` and observe its own
   hosted run, or record the explicit judgment that the green run at
   `7dcb58bc` — that SHA plus three post-merge commits — is the tree being
   accepted. Never a fabricated green result, and never a green run on one tree
   reported as a green run on another.

Until all required rows are complete, this file is evidence of an honest
candidate hand-off, not evidence of run acceptance. Those rows are now
complete, and the decision that closed them is recorded below. This file
became acceptance evidence at that point and not before; the hand-off text
above is left exactly as the candidate wrote it.

## Operator acceptance — 2026-09-12

Recorded on the operator's explicit instruction to accept the run. Both items
the completion block above left outstanding are answered here, and each is
answered with what is true rather than with what would be convenient.

### The tree being accepted

`orchid/integration` at `08fb01b77ba358159eeed6377f789eb89fba0555`.

- It contains the 40-task result `d9b1cd15174c0e75b424ebf9b64a8f953aca91b0`
  as an ancestor, so every task's merge is in this history.
- Its PRODUCT content — everything outside `.orchid/` and `tests/` — is
  **byte-identical** to `main` at `7dcb58bcf333627a1f50e428834d03b6b52b80fe`
  (`git diff 7dcb58bc 08fb01b7 -- . ':(exclude).orchid' ':(exclude)tests'` is
  empty). That is the exact tree hosted CI run
  [33577759163](https://github.com/bilal-/orchid/actions/runs/33577759163)
  proved green on ubuntu-latest and macos-latest. No line of shipped code in
  this acceptance is unproved by that run.

**Two test files differ, and they were added deliberately after the first
acceptance gate ran RED.** That gate failed four assertions, all one cause: the
merge CAS case timed its concurrent commit with `sleep 0.3` against a real
merge, and on a loaded machine the commit lands before merge reads the
integration head — so merge correctly reports a STALE BASE (exit 5) and the
case fails while reporting a race it never ran. The same fixture had already
failed twice on hosted macOS and been diagnosed and repaired on `main`; the
integration branch simply predated the repair.

Re-running until it passed would have treated a diagnosed defect as luck. So
the two test-only fixes were cherry-picked here instead:

- `03b7f18e` — the CAS case now waits for a marker the merge's own validation
  command writes, which proves `integ_head` was already read, putting the
  concurrent commit inside the CAS window by construction rather than by
  timing.
- `dd1dbec2` — the verb-lock case now counts journal entries against the calls
  that actually SUCCEEDED, because a caller refused for lock contention never
  ran and has no entry to lose.

`git diff --name-only a6523dfe 08fb01b7` names only `tests/test_merge.sh` and
`tests/test_verb_lock.sh`. **No product file changed.** The accepted tree is
r-002's result plus two corrections to tests that were measuring the machine
rather than the property they claim to test.

### The exact-SHA row: closed by decision, not by a run

The retrospective asked for "a canonical full-CI run against the exact final
40-task integration SHA `d9b1cd15`". That run is deliberately NOT performed, and
the reason is not expedience:

**`d9b1cd15`'s product tree is known to FAIL hosted CI.** That is precisely why
`aae7e9b9` (Ubuntu ShellCheck 0.9 compatibility) and `7dcb58bc` (deterministic
service platform fixtures) exist — the first two hosted runs on the merge of
that tree failed, and those two commits are what made it green. Running CI
against `d9b1cd15` today would produce a red result on a tree that has already
been superseded twice over. It would be ceremony, and recording a known-red run
as an acceptance row would be worse than recording nothing.

So the accepted tree is the one that CONTAINS `d9b1cd15` plus the two fixes its
own hosted failures demanded, and the green evidence is bound to that tree by a
byte-identical product diff rather than by assertion. **No claim is made that
the 40-task tree as merged was ever green.** It was not.

### The ambient integration-branch gate

`/bin/bash scripts/ci-local.sh --bash /bin/bash`, run from this checkout while
it is actually parked on `orchid/integration` at
`08fb01b77ba358159eeed6377f789eb89fba0555`: **CI PASS**, 105 test files, 0
failures, including `test_hermetic_suite.sh` (the PATH-restricted no-vendor-CLI
run) and every `tests/inv/` invariant.

This is the row L036 exists for and the one no other environment can stand in
for: a path conditioned on branch identity is dead code in a task worktree and
in merge's temp worktree, because neither can be parked on the integration
branch. It is why the same commit once passed on every other branch name and
failed eleven assertions here.

The FIRST run of this gate, on `a6523dfe`, failed — four assertions, one cause,
recorded above. It is named here rather than quietly replaced by the green one:
an acceptance that reports only its last attempt is the shape r-001's
acceptance had.

### Acceptance reason

r-002 delivered what a hardening run is for: 40 tasks merged, each through the
kernel's own review, arbitration and merge gates, and the run falsified the
claim it most needed tested — that a correct deterministic kernel is sufficient
for unattended operation. The defects it found in state recovery, evidence
binding, failure accounting, lifecycle and containment are repaired in this
tree, with RED cases for the enforced ones and honest labels on the rest. The
product content of the accepted tree is proved green by hosted CI on both
platforms and by the local canonical gate from this integration checkout.

The run is accepted as a **hardening run's result**, not as a release and not as
a claim of readiness for an unfamiliar operator.

### What acceptance does NOT claim

Unchanged by this decision, and still open:

- no genuine third-party beta run has occurred;
- nothing has been published, tagged, uploaded, deployed or announced, and the
  version remains `1.0.0-beta.1`;
- runtime capability proof for implementer profiles is not done;
- a live notification return-leg qualification on a fresh machine is not done;
- the 1.0 prerequisites in the retrospective stand as written.

### Work that is NOT part of this acceptance

r-003 track work merged to `main` after r-002's tasks (PRs #12 and #13:
recovery-route messages, INV-17, the rollover guard, per-attempt verify
evidence, the engine half-open probe, worktree lifecycle, `task get`). It is
outside this run and outside this acceptance record.
