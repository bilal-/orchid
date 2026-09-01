# Orchid r-002 — close the gaps r-001 deferred

## Goal

Run r-001 hardened the unattended boundary, built the deterministic driver
and the release gate, and shipped `1.0.0-beta.1`. It also deliberately
deferred a set of defects and structural gaps, each recorded with an
arbitration entry. This run closes them, in three tracks:

1. fix the correctness defects that shipped knowingly;
2. make the guarantees SELF-ENFORCING — every one of r-001's worst findings
   was a mechanism that existed and that nothing made fire;
3. settle two design questions r-001 raised but could not answer at the end
   of itself.

## Constraints

- Preserve Orchid's core architecture: Bash 3.2+, Git, and jq; no daemon,
  database, hosted service, Node/Python runtime, or API-key proxy.
- Preserve engine neutrality and plugin contracts. Kernel code must not
  branch on engine names (INV-05, INV-14) and the driver must not reference
  a plugin path (INV-13).
- Never push, publish, deploy, tag, contact a remote, or mutate anything
  outside this local repository and disposable local test repositories.
- Keep existing CLI behavior backward compatible unless a documented gate
  intentionally fails closed.
- All durable Orchid run state must be mutated through Orchid verbs.
- Every change must pass `bash scripts/ci-local.sh --bash /bin/bash`, which
  includes the full suite, Bash 3.2 syntax, the docs checks, and ShellCheck
  at zero warnings.
- New behavior needs focused tests, documentation, and honest labels for what
  is enforced, advisory, locally proven, or still awaiting external proof.
- **The implementer profile cannot execute anything** (lesson L017): no
  `bash`, no `bash -n`, no `shellcheck`, no writing git, and any command
  whose text contains `$`, `;`, `( )` or `<( )` is refused. Task briefs must
  therefore never instruct an implementer to self-verify, and must carry
  exact `file:line: RULE: message` text for any lint finding. Formula
  re-pinning, `chmod`, and lint fixes are operator hand-offs.

## Bootstrap safety — operator procedure while the safeguards do not yet exist

The first tasks in this run execute BEFORE the protections this run adds. Until
T001 (duplicate concurrent implementers), T006 (a stale checkout running
pre-merge code) and T010 (unactionable rework) have landed, the run itself is
exposed to precisely the failures it exists to remove. That is unavoidable —
they cannot protect their own construction — so it is handled by procedure
instead, and the procedure is part of this run's requirements rather than
operator folklore:

- After EVERY merge, and before any further verb, refresh the integration
  checkout with `git checkout HEAD -- . ':(exclude).orchid'`. The exclude is
  mandatory: a bare refresh would clobber uncommitted durable run state, which
  is the r-001 journal-loss incident.
- Before each dispatch, confirm `orchid jobs check` reports no outstanding job
  for that task, so a relaunch cannot produce a second concurrent implementer
  into the same worktree.
- Perform the mechanical hand-offs — the `Formula/orchid.rb` re-pin, any
  `chmod` on a new executable, and any lint fix — after the implementer's
  envelope reconciles and BEFORE `orchid verify` runs, and journal each one.
- Carry the exact `file:line: RULE: message` text into any rework brief by
  hand until T010 automates it.

Once T001, T006 and T010 have merged, these steps are enforced by the code and
the procedure becomes a fallback rather than the only guard.

**This procedure must be auditable, not remembered.** A procedure with no
record is indistinguishable from one nobody followed — which is how r-001's
release gate went unenforced for eight tasks. For every task dispatched before
T001, T006 and T010 have merged, the operator journals one entry per pass
naming which of the four steps above were performed and their outcome (the
refresh, the outstanding-job check, each mechanical hand-off, and whether lint
locations had to be carried by hand). T015's acceptance includes reading those
entries back and reporting any dispatch that has none, so a skipped step is
visible in the run's own record rather than inferred later from a defect.

## Track 1 — the deferred correctness defects

### Required outcomes

- `drive_implementing` must carry the same `drive_job_outstanding` liveness
  guard its sibling arms already have (hook, dispatch and review paths).
  Today a failed implementer re-escalates on every pass, spawning duplicate
  concurrent implementers into the same worktree on the same branch and
  walking `infra_failures` to the cap while several are still writing to that
  checkout. `libexec/orchid-jobs` has no duplicate-job guard in `prepare` to
  catch it either; decide whether the guard belongs in one place or both.
- `orchid start` must be idempotent or fail safely with recovery
  instructions, as its own acceptance criteria already require. A reported
  `.orchid/tasks/` idempotence break is outstanding; reproduce it first, then
  fix it, and add the case to `tests/test_start.sh`.
- A soft-surface orchestrator must not be woken with the pre-v1.1 prompt, and
  a boundary it cannot resolve must not suppress the operator `notify`.
  `drive_surface_admits` currently treats `soft` as admitting every verb,
  which reintroduces on that path the never-told-the-human failure the
  brokered path was fixed to remove.
- The release rehearsal must not pass vacuously. `tests/run.sh` globs
  `test_*.sh`, so `tests/test_e2e_release_rehearsal.sh` is part of the suite,
  and the suite is explicitly designed to be runnable inside an extracted
  release archive (`tests/test_ci_release.sh` skips its Git-dependent checks
  there by design). In that context the rehearsal's source-checkout snapshots
  compare a tree that was never at risk, so they pass without proving
  anything — and `docs/install.md:150` prescribes running the rehearsal as a
  release-day step. Either detect the extracted-archive context and record
  the snapshot as not-tested there, or make it meaningful. Note
  `scripts/release.sh` does NOT itself run the suite; the exposure is the
  documented release-day procedure plus the archive-runnable suite, not the
  release script.
- `tests/probes/probe-claude-tick.sh` must stop feeding the expected `orchid
  version` string into the prompt and then grepping the reply for that same
  string: that half of its "real output, not a hallucinated marker" evidence
  is satisfiable by echoing the prompt back. Only the independent
  `integration_branch` check currently discriminates.

### Acceptance criteria

- A focused test proves a failed implementer does not produce a second
  concurrent implementer for the same task, and that `infra_failures` climbs
  only on genuine repeat failures.
- A focused test proves `orchid start` run twice leaves the same state and
  reports what it re-used, or refuses with actionable recovery.
- A focused test proves a soft-surface boundary that no admitted verb can
  settle raises an operator blocker.
- The rehearsal's evidence is either genuine in the archive context or
  explicitly recorded as not-tested there; a vacuous pass is not acceptable.

## Track 2 — make the guarantees self-enforcing

Every one of r-001's most expensive findings was a mechanism that existed and
that nothing caused to run. This track is about closing that class, not
individual instances.

### Required outcomes

- **A stale checkout must not silently run pre-merge code** (lesson L018).
  `bin/orchid` resolves `ORCHID_ROOT` from its own location, so every verb,
  lib, runner and engine adapter comes from the working tree. When `orchid
  merge` advances the branch with `update-ref` alone, other checkouts keep
  executing the old code indefinitely while every merge appears to succeed —
  which cost r-001 a full day of its own merged improvements. Choose and
  implement one: refuse to run from a checkout whose working tree does not
  match HEAD; resolve `ORCHID_ROOT` from HEAD; or have `orchid merge` refresh
  the other checkouts of the branch it just advanced. Whichever is chosen,
  the warning must stop being advisory-only.
- **The CI gate must run without each task remembering to ask** (lesson
  L016). `scripts/ci-local.sh` existed for the whole of r-001 and only two of
  eight tasks invoked it, so seventeen findings accumulated behind a green
  suite. Put it in the merge path, in a shared verification fragment, or in
  the plan-time task template — anywhere that does not depend on an author
  choosing to include it.
- **A capability refusal must not be recorded as an engine fault.** When
  `agy` declines a diff over `agy_max_bytes` it is doing exactly what its
  adapter is designed to do, yet `ledger_mark` counts it toward
  `engine_fail_threshold`, so an engine that reviews small diffs perfectly
  would eventually be disqualified from everything. Distinguish the two.
- **`orchid doctor` must be able to say whether a notify reply can actually
  arrive** (lesson L011). Outbound needs only a CLI; inbound needs a
  persistent agent, and an operator currently gets no signal when that agent
  is gone — r-001 lost a real phone answer to exactly this. T006 added an
  `inbound_probe` manifest key and `plugins/notify/openclaw/plugin.conf`
  declares one; `plugins/notify/hermes/plugin.conf` does NOT, even though
  `hermes gateway status` reports exactly that fact and is the channel r-001
  actually delivered on. Give hermes a probe, and make sure "cannot
  determine" is reported as such rather than as health.
- **A lint gate the implementer cannot see must not be routed to the
  implementer** (lesson L017). Make the rework path carry exact
  `file:line: RULE: message` text, or make lint fixes an explicit operator
  hand-off in the protocol rather than a convention.

### Acceptance criteria

- A focused test proves a verb refuses, or self-corrects, when the working
  tree does not match HEAD.
- A task dispatched without `scripts/ci-local.sh` in its own
  `verification_commands` is still gated by it before merge.
- A focused test proves a capability refusal leaves
  `consecutive_failures` unchanged while a genuine engine fault increments
  it.
- `orchid doctor` reports the notify return leg from a plugin's own probe
  where one exists, and says plainly that it cannot tell where none does.

## Track 3 — settle two open design questions

### Required outcomes

- **Does qualification need its own trust step?** `scripts/beta-qualify.sh`
  executes the target repository's configured `verify=` by default with no
  acknowledgement. That is repository content reaching execution, which is
  Track 1 of r-001's threat model — but requiring `orchid trust unattended`
  first would invert the documented order (qualify BEFORE acknowledging).
  Decide, implement the decision, and write down the reasoning either way.
  `--no-run-verify` already exists as the opt-out.
- **Should review policy require a worktree-capable slot?** (lesson L010.)
  Across r-001, `agy` returned four generic one-sentence approves with no
  findings, including on a task whose central acceptance criterion was unmet,
  while the session-independent slot found every real defect. Its
  independence is real and worth keeping; its depth is bounded by what a diff
  shows. Decide whether `review.<tier>` should require at least one
  worktree-capable reviewer when a task's criteria involve interaction with
  existing kernel behaviour, and implement or explicitly reject it.

### Acceptance criteria

- Each question has a written decision in `docs/specs/`, with the reasoning
  and the rejected alternative recorded, not just the outcome.
- Any behaviour change is covered by a focused test.

## Run-level acceptance

- `bash scripts/ci-local.sh --bash /bin/bash` passes on the merged tree.
- All new focused tests pass independently.
- Documentation and CLI help agree with implemented behavior.
- No lesson from r-001 is contradicted without an explicit, recorded decision
  to supersede it.
- Genuine third-party beta runs and public release remain explicitly
  operator-owned follow-up work; this repository must not claim they
  occurred, and the version must not advance past `1.0.0-beta.x` in this run.
