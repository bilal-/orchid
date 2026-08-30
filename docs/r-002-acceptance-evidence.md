# r-002 run-level acceptance evidence — candidate hand-off

Status: **NOT YET ACCEPTED. Operator completion is required after merge.**

This file is the candidate's honest hand-off, not a claim that the run is
complete. A commit cannot observe the merged tree that will contain itself,
and this task's mandatory implementer hand-off forbids running the verifier.
Every unobserved fact below is therefore marked open rather than inferred.
Only the operator-completed copy is suitable for `orchid run accept`.

## Identity and scope

- Run: r-002
- Task: T015
- Integration base inspected by this task: `51f5fa3c59cfe2b18d756ab99318b0730a5629b7`
- Partial candidate preserved at task start:
  `d0690c85349a4c5f129bdcc006832b7ff908ddbd`
- Candidate under review: the task-branch HEAD containing this file. The
  operator must record its resolved SHA after the final task commit; a file
  cannot truthfully embed the hash of the commit that embeds the file.
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
- left L029 active until T015 itself merges, because its invalidation condition
  is the repaired documentation gate landing on integration.

Operator result: **COMPLETE FOR THE CURRENT CANDIDATE.** The run remains
unaccepted, and L029 still requires retirement after this task merges.

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

## Operator completion block

Before `orchid run accept`, append all of the following to the operator-owned
copy of this file:

1. final T015 candidate SHA and merged integration SHA;
2. candidate-local docs/CI command results and log paths;
3. the integration-branch checkout name, HEAD, command result, and log path;
4. bootstrap-journal audit result, including every unmatched dispatch or
   `none` after comparison;
5. lesson ids updated/retired/added;
6. hosted workflow id/URL and conclusion after push, or an explicit policy
   decision that hosted CI is not required — never a fabricated green result;
7. the operator's acceptance reason.

Until all required rows are complete, this file is evidence of an honest
candidate hand-off, not evidence of run acceptance.
