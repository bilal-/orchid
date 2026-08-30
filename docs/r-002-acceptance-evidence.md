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

These are source-level observations only. Their RED/GREEN probes have **not
been executed by this implementer**; the first two rows of the acceptance
matrix remain open.

## Bootstrap-journal audit

Status: **NOT PERFORMED IN THIS CANDIDATE.** The task rule forbids touching any
run-state path, so this implementer did not read the journal and cannot
truthfully report that every pre-bootstrap dispatch has its required operator
entry.

The three merge cutoffs visible in Git history are:

- T001: `c1d7550b970b9f4db952a7d9ce5cc62d77067ae7` (2026-08-10)
- T010: `df47066e67f5467fc32664337804016aa1acc4e3` (2026-08-11)
- T006: `416fcc9a9c24a9dd6ca5ab3fc12c175ba36a9ce6` (2026-08-12)

Before acceptance, the operator must read the journal through Orchid's
read-only journal surface, enumerate every task dispatch preceding each cutoff,
and pair each dispatch with the bootstrap entry the run procedure required at
that time. Append the task ids of every unmatched dispatch here, or write
`none` only after the comparison. Until then the result is **unknown**, not
“none found.”

Operator result: **OPEN — do not accept the run.**

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

Durable lesson state was **not read or mutated** because this task forbids
touching run-state paths. Before acceptance, the operator must inspect active
lessons, retire/update any record that still assigns `Formula/orchid.rb` to an
implementer candidate, retain L017 only for genuine candidate-local mechanical
work, ensure L036 carries the constructed-condition/integration-branch rule,
and add or consolidate the textual-gate and concurrent-procedure lessons above.
Record the changed lesson ids here.

Operator result: **OPEN — do not accept the run.**

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
