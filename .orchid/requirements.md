# Orchid self-hosting hardening run

## Goal

Turn Orchid from a strong private-dogfood prototype into a safer, simpler,
release-ready beta by implementing the three improvement tracks identified in
the repository assessment:

1. harden the unattended orchestrator boundary and state its trust assumptions
   precisely;
2. move routine tick mechanics into deterministic code and collapse setup into
   a single onboarding command;
3. add cross-platform CI, a clean static-analysis gate, pinned-release tooling,
   and a reproducible external-beta qualification path.

## Constraints

- Preserve Orchid's core architecture: Bash 3.2+, Git, and jq; no daemon,
  database, hosted service, Node/Python runtime, or API-key proxy.
- Preserve engine neutrality and plugin contracts. Kernel code must not branch
  on engine names.
- Never push, publish, deploy, contact a remote, or mutate data outside this
  local repository and disposable local test repositories.
- Keep existing CLI behavior backward compatible unless a documented security
  gate intentionally fails closed for unattended operation.
- All durable Orchid run state must be mutated through Orchid verbs.
- Every code change must pass the full existing test suite on Bash 3.2.
- New behavior needs focused tests, documentation, and honest labels for what
  is enforced, advisory, locally proven, or still awaiting external proof.

## Track 1 — unattended trust boundary

### Required outcomes

- Treat target-repository content as potentially prompt-injecting input in the
  threat model, including the special risk of an orchestrator that can invoke
  shell commands.
- Add a deterministic, per-repository acknowledgement gate before unattended
  headless ticks or service installation may run. The acknowledgement must be
  operator-authored machine-local state outside the repository, bound to the
  repository's local Git identity so cloned content cannot arrive
  pre-acknowledged. Interactive/manual operation must remain available without
  silently opting into unattended trust.
- `orchid doctor` and `orchid status --explain` must report whether unattended
  execution is acknowledged and why a headless run is gated.
- Tighten the headless command surface where the supported vendor CLI permits
  enforceable command restrictions. Where OS/vendor containment is unavailable,
  say so explicitly rather than describing prompt instructions as structural
  enforcement.
- Reword claims such as "structurally impossible" wherever current enforcement
  proves only kernel mediation or source-level conformance.
- Add regression tests for the gate and for the documented trust semantics.

### Acceptance criteria

- A fresh repo cannot run `runners/orchid-tick` or install the background
  service until the operator explicitly acknowledges unattended trust through
  an out-of-repository, machine-local trust record for that repository.
- The refusal is actionable and does not affect ordinary read-only commands,
  planning, or an explicitly interactive Orchid session.
- Documentation clearly distinguishes environment hygiene, vendor sandboxing,
  prompt policy, and OS-level containment.

## Track 2 — deterministic drive and one-command setup

### Required outcomes

- Add a deterministic driver for routine tick work: lease refresh,
  reconcile/check/gc ordering, safe dispatch, implementer reconciliation,
  verification, reviewer routing/reconciliation, deterministic approval when
  policy is unambiguous, serialized merge, status regeneration, and final lease
  refresh.
- The driver must never make free-form judgment. It must stop or delegate only
  at explicit judgment boundaries such as conflicting review evidence,
  required plan drafting, or a genuine blocker.
- The unattended pump must prefer the deterministic driver and invoke an LLM
  orchestrator only for a named judgment boundary that deterministic policy
  cannot resolve.
- Add `orchid start <requirements-file>` (with explicit options where needed)
  to perform the mechanical existing-repo setup in one command: preflight,
  repo-local configuration validation, initialization, integration-worktree
  creation, epoch setup/import, and clear handoff into plan drafting. It must
  never guess a verification command or overwrite user files.
- Preserve the lower-level verbs and documented manual workflow.

### Acceptance criteria

- A fixture can progress through the ordinary happy path using the
  deterministic driver without feeding the full PROTOCOL.md to an LLM.
- Conflicting/blocking reviews stop at a clearly reported judgment boundary;
  no heuristic prose parsing decides the outcome.
- `orchid start` is idempotent or fails safely with recovery instructions and
  reduces the current worktree/epoch/import setup to one invocation.
- Crash fencing, evidence binding, review independence, and merge revalidation
  invariants remain green.

## Track 3 — beta release gate

### Required outcomes

- Add CI for Linux and macOS. It must exercise Bash syntax, the full test suite,
  invariant tests, documentation checks, and ShellCheck.
- Establish a clean, reviewed ShellCheck baseline. Intentional exceptions must
  be narrow and documented; fix unsafe or ambiguous findings, including the
  FIFO creation pattern that currently uses `mktemp -u`.
- Add release tooling that builds/checks a version-pinned archive and validates
  that version metadata, tag name, installer behavior, and Homebrew formula
  inputs agree. Do not publish or push anything.
- Make the installer support an immutable version/ref path while retaining an
  explicitly labeled development-channel option.
- Add a reproducible beta qualification harness/checklist that can be run
  against multiple operator-supplied repositories and records anonymized,
  local evidence without copying proprietary repository content.
- Replace release-facing screenshot placeholders with either checked-in
  terminal fixtures/assets generated from local deterministic data or explicit
  non-placeholder documentation that does not claim missing media exists.

### Acceptance criteria

- CI configuration is valid and has Linux/macOS jobs with no repository secrets
  required for the deterministic suite.
- The local CI-equivalent command passes on this machine under Bash 3.2.
- Release checks fail on placeholder versions, mismatched metadata, a dirty
  archive, or a moving unpinned release reference.
- The beta harness can qualify at least two disposable local fixture repos and
  emits a concise evidence summary.
- Genuine third-party beta runs and public release remain explicitly
  operator-owned follow-up work; the repository must not claim they occurred.

## Run-level acceptance

- `bash tests/run.sh` passes.
- All new focused tests pass independently.
- `bash -n` passes for every shipped shell script under Bash 3.2.
- The configured ShellCheck gate passes.
- Documentation and CLI help agree with implemented behavior.
- A local end-to-end rehearsal demonstrates the unattended trust refusal,
  acknowledged deterministic drive, one-command setup, and beta qualification
  path without any network or external mutation.
