# Repository guidance for coding agents

This file applies to the entire repository. Orchid is a Bash 3.2+, Git, and
`jq` orchestration kernel. It is still in the `1.0.0-beta.x` series: the
author has dogfooded it on Orchid and on external application repositories,
but no genuine third-party beta or public release has happened.

## Read before changing behavior

- `PROTOCOL.md` is the operational state-machine procedure.
- `docs/specs/kernel.md` owns invariants and evidence rules.
- `docs/specs/operations.md` owns operator workflows.
- `docs/contributing.md` owns portability, testing, RED/GREEN proof, and
  release-pin policy.
- `README.md` and `docs/architecture.md` are user-facing behavior surfaces;
  keep their diagrams and maturity claims consistent with shipped behavior.

When those documents disagree with code, establish what the shipped code and
tests actually do, then update every affected surface. Do not quietly choose
the most convenient version.

## Safety and repository state

- Never hand-edit durable `.orchid/` state. Use Orchid verbs, read the current
  epoch from `.orchid/runtime/epoch`, and pass `ORCHID_EPOCH` explicitly.
- Do not hide Orchid stderr. A refused verb is evidence, not noise.
- Never run drive, merge, or launch alongside a live supervisor.
- Preserve unrelated working-tree changes. The repository may be in active use
  through linked task and integration worktrees.
- Do not push, publish, deploy, create or move a release tag, contact a remote,
  or run `orchid run accept` unless the operator explicitly requests that exact
  action. Local implementation and local Git integration do not imply release.

## Implementation rules

- Keep shipped shell compatible with macOS `/bin/bash` 3.2 and GNU/Linux.
  Avoid GNU-only `find`/`stat` forms; use the repository helpers documented in
  `docs/contributing.md`.
- Tier-1 verbs are deterministic state transitions and must not spawn
  long-lived processes. Effectful launches belong in tier-2 runners.
- Reuse helpers in `lib/` and `tests/helpers.sh`; do not create a second parser,
  lock, liveness, frontmatter, or evidence-binding mechanism for convenience.
- Every new enforcement gate needs an exercised RED case and accepting GREEN
  twin. A check that only demonstrates success is not proof.
- Formula pinning is integration/release-owned. Do not re-pin
  `Formula/orchid.rb` in a task or feature candidate.
- Treat file modes as behavior. New executables need deliberate mode evidence;
  prose-only changes must not alter modes.

## Verification

Run the narrowest relevant test while iterating, then the appropriate shared
gate:

```sh
/bin/bash tests/test_docs.sh
/bin/bash scripts/ci-local.sh --bash /bin/bash --no-tests
/bin/bash scripts/ci-local.sh --bash /bin/bash
```

- The first command owns documentation consistency.
- The second is the whole-tree syntax, portability, and ShellCheck merge gate.
- The flagless command is the canonical full local CI run. Run it before a
  push or whenever the change's risk is broader than focused verification.
- A path conditioned on branch identity, install-root identity, or another
  ambient property needs a test that constructs that condition. A task or
  temporary merge worktree cannot prove behavior that only runs on the actual
  integration checkout.

## Documentation and claims

- Distinguish code-enforced guarantees from advisory policy, machine-local
  observations, and operator-owned/unproved work.
- Historical dogfood reports remain historical evidence; add resolution status
  rather than rewriting what the run observed.
- Keep the version in `1.0.0-beta.x` until the documented 1.0 prerequisites are
  actually satisfied.
- Never turn local tests, author-operated dogfood, or a prepared installer into
  a claim of hosted CI, third-party qualification, publication, or release.
