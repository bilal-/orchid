# Where things stand — resume point

Written 2026-09-13. This file is the hand-off between working sessions and is
deliberately agent-agnostic: read it before doing anything else, whatever tool
you are. It records state that the code and git history do not make obvious,
and it goes stale — **verify every claim below against the tree before relying
on it.** Anything here that contradicts the code is wrong and the code wins.

## Public beta preparation — 2026-10-03

The operator requested a public beta available to anyone, explicitly authorized
publishing a beta tag and release after checks pass, and chose the existing Sous
tap: `brew install bilal-/tap/orchid`. Stable `1.0.0` remains unqualified.
GitHub's homepage is set to `https://orchid.bilal.sh`; the operator is building
that website separately. The operator requested PR #19's brand kit in this
beta and merged it at `77a2e1b`; that history is incorporated here. All 64
generated brand assets rebuilt byte-identically in an independent scratch
check. Its logo assets remain in the tagged Git
tree, while the kernel archive excludes `brand/` as that PR specifies. The
README uses pinned hosted logos so its archive and Homebrew copies work too.

The distribution candidate includes the eight-pass review below and expands
the Homebrew payload to include its source installer, skills, documentation,
configuration example, and qualification harness. Per-user setup uses the stable
Homebrew `opt` path. The installer and exact Formula payload passed offline tests, including real
local-tag clone/fetch and upgrade retargeting. Native Homebrew verification
then exposed automatic README/LICENSE relocation: the corrected formula
installs those files at its prefix and tests that layout. The original layout
failed both offline and native checks; the corrected layout passed both.
Native opt-path setup, repeated config preservation, and per-user uninstall
also passed against a provisional local archive. The preexisting global Orchid
symlink was preserved. These observations do not prove published downloads.
At snapshot preparation, final release-tree full CI, archive verification,
hosted CI, publication, and genuine published installs are pending. The GitHub
release and tap commit record publication after it occurs.
Release pinning belongs to the assembled release checkout on its
own `orchid/integration`, preserving the active integration worktree and journal.

## Whole-codebase review — 2026-10-03

The local review branch is `codex/full-codebase-review`, in the linked checkout
`../orchid-review`, based on `main` at `03e78aac`. The original `main` checkout
is preserved. PRs #15 and #17 were merged earlier in this session; the older
pending-merge instructions below are historical and superseded. Remote status
was not refreshed during the initial code-only passes; beta preparation later
verified the repository, homepage, existing tap, and operator's #19 merge.

Eight review passes were completed: five initial implementation passes, an
independent parallel review, a parallel cross-check, and aggregate verification.
The review reproduced
and repaired 21 issues. The changes concentrate on failed writes and hashes,
literal configuration and permissions, durable publication and recovery,
merge/worktree ownership, checked adapter environments, process identity,
collision-safe runtime IDs, adapter qualification, plugin entrypoint ownership,
installer diagnostics, and bounded timeout cleanup. Shared helpers replace
repeated parsing, environment loading, and ownership checks. Every new
admission fence has an exercised refusing case and accepting twin.

The tracked review inventory covers the baseline's 188 code/data files plus
13 new regression files. Coverage means whole-tree static checks, the aggregate
regression suite, and targeted source/fixture review of the critical contracts;
it does not mean every test or prose line was manually inspected.

Focused tests and independent cross-checks passed on macOS `/bin/bash` 3.2.
The full run on `413421a` completed with exit 1: the proof-annotation gate found
two missing standalone case comments, and INV-16's accepting twin counted only
live manifests after its short-lived job could already be GC'd. Both are fixed
in this candidate. The routing assertion uses `jobs ls --all --tsv` and proves
an actual spawned job with its provider, operation, positive PID, and launcher;
a suppressed-launch RED and forced-GC GREEN passed, as did focused INV-16 and
the annotation gate. This was a fixture race, not a product routing regression.
The final release-tree and extracted-archive full gates remain pending.
Earlier interrupted runs are not full-suite passes. Review records and logs are
under `/tmp/orchid-review.RpZ5fo/`; that directory is machine-local evidence,
not a durable release artifact.

The version remains `1.0.0-beta.1`. The code-only review did not re-pin the
formula; release preparation pins the assembled tree in its release checkout.
No hosted CI, actual vendor qualification, third-party beta, publication, or
release is claimed by this review. Process/path checks and subsequent OS
operations retain their documented race; durable Git/filesystem publication
retains its crash window. Global engine discovery keeps its existing run-only
compatibility behavior; manifest validation and repo-local trust/resolution
have the stronger entrypoint contract. New job-ID claims survive normal GC;
legacy IDs whose entire runtime record was already erased cannot be recovered.

r-002 remains accepted, r-003 has not started, and Decision 0 remains the
operator's choice. The unrelated integration-checkout journal edit and preserved
`r-002/T024-preserve` branch are outside this review.

## PR integration follow-through — 2026-10-03

PR #15 is merged into `main` at `e4819e52`. The accepted r-002 roadmap and
acceptance record are now on `main`; the older snapshot below saying otherwise
is superseded.

PR #17's branch CI was green, but its assembled PR tree failed on both
platforms. GitHub's latest `main` run at `1ed27d54` also failed:
[34777104362](https://github.com/bilal-/orchid/actions/runs/34777104362).
The earlier green-main claim below was stale. The failures came from two
producer-to-`grep -q` pipelines in `findings_round_series`, introduced by the
convergence change. INV-15 reproduced the failure locally; this candidate
feeds both matchers with here-strings instead.

A second fixture also reproduced a foreign clone with the same task branch
being rebased successfully. The candidate now reuses dispatch's
`drive_worktree_plan` ownership check; the regression rejects that clone and
accepts the same stale task once its record names the registered worktree.

The `r003-sibling-rebase` candidate now contains the acceptance merge, the
rebase job guard and its exercised refusal/acceptance cases, and the INV-15
repair. Merge #17 only after canonical local CI and the current-head Linux
and macOS PR checks pass. Once this candidate is on `main`, both pending PRs
from the previous session are resolved.

r-003 has not started. Decision 0 and automatic dispatch rebasing remain open.
The dated local and remote snapshots below are historical observations;
verify current branch and PR state before treating them as today's state.

## Local resumption — 2026-10-03

The `orchid` checkout is now on local branch
`codex/r003-sibling-rebase-safety`, based on `main` at `1ed27d54` with the
prepared task-rebase candidate `df9552e3` cherry-picked. The dated snapshot
below still describes the previous session; remote PR and CI status has not
been refreshed.

A disposable fixture reproduced a live implementer being rebased: `jobs ls`
reported `running`, while the task candidate changed and the verb returned
success. The candidate now refuses every outstanding job for that task,
including prepared launches without a PID. An unrelated task's live job
still permits the rebase. The regression test failed on the original
candidate and passed with the guard; the operator and kernel docs now
include the explicit verb and its job precondition.

Verified locally on macOS `/bin/bash` 3.2.57, all exit 0:

- `/bin/bash tests/test_task_rebase.sh`
- `/bin/bash tests/test_task.sh`
- `/bin/bash tests/test_docs.sh`
- `/bin/bash scripts/ci-local.sh --bash /bin/bash --no-tests`

The canonical full CI run was not run for this correction. These observations
do not establish Linux or hosted CI results for the candidate.

r-002 remains accepted on `orchid/integration`; its existing journal edit was
preserved. r-003 has not started. Decision 0 in `r-003-requirements.md` remains
pending the operator's choice. Automatic rebasing in dispatch remains open.

## 1. The run

**r-002 is ACCEPTED.** `run_status: complete`, 40/40 tasks done, evidence at
`.orchid/reviews/acceptance.log`, boundary cleared. It was accepted on the
operator's explicit instruction on 2026-09-13.

What the acceptance rests on, and what it deliberately does not claim, is in
[`../r-002-acceptance-evidence.md`](../r-002-acceptance-evidence.md) — read the
"Operator acceptance" section before quoting anything about r-002's status. In
particular: **the 40-task tree `d9b1cd15` was never green on hosted CI and is
not claimed to be.** The accepted tree contains it plus the two commits its own
hosted failures required.

The run state lives on `orchid/integration`. **It is not on `main` yet** — see
PR #15 below. Until that merges, `main`'s `.orchid/roadmap.md` still reads
`run_status: running`, which is a fossil, not the truth.

**r-003 has not started.** Its requirements are drafted in
[`r-003-requirements.md`](./r-003-requirements.md) and its rollover is now
unblocked (no `task/*` branches survive). Starting it is gated on **Decision 0**
— the daemon question, at the top of that document. That decision is the
operator's and nobody should pick it by default.

## 2. Open pull requests

| PR | Branch | What it is |
|---|---|---|
| [#15](https://github.com/bilal-/orchid/pull/15) | `r002-acceptance-to-main` | Brings the r-002 acceptance record and run state onto `main`. Docs + `.orchid/` only; no product code. |
| [#17](https://github.com/bilal-/orchid/pull/17) | `r003-sibling-rebase` | `orchid task rebase <id>` — the supported action for a task whose base moved under it. |

Merged this session: #12, #13, #14, #16. `main` is green on hosted CI on both
platforms.

## 3. What landed, and what is still open behind it

Each item below is recorded in full in `r-003-requirements.md` next to the
finding it came from. This is the index, not the record.

**Closed:** F42 (rollover refuses surviving task branches), F43 (arbitration
refusal discloses filed-vs-usable evidence), F44 (recovery verbs name the route
out), F45 (`--help` answered by the verb — now **INV-17**, which derives its
subject list from `libexec/` and covers a new verb with no edit), F47
(per-attempt verify evidence), F49 (`scope: task|repo` in the verify log), the
engine half-open probe, worktree lifecycle on merge, `task get`, and F40 (the
critique loop's convergence report *and* the `plan apply` stall gate).

**Open, with the reasoning for why they are still open:**

- **F46 — the arbitration reason is write-once.** Correcting a direction while
  a job is already running with the old text needs a way to stop that job.
  That is a design question, not a message fix.
- **`task append`** — F39's other half. Deliberately NOT built: F40 says
  appending is structurally what creates the contradictory task layers the
  critic then flags, so it would fix the corruption hazard by making the
  coherence hazard easier to hit.
- **Supported exit as a whole-tree invariant** (a 1.0 prerequisite). Sized and
  deliberately not built. The tree has 418 `orchid_die` sites and 276 name no
  command, but a gate asserting "every refusal names a command" would be wrong
  at most of them — they are caller errors with no state to clear — satisfiable
  by boilerplate, and blind to the sites that die with `"$usage"`. The
  load-bearing rule needs a judgment per refusal, not a matcher.
- **Wiring `orchid task rebase` into the dispatch loop.** The verb exists; the
  automatic step does not, because that loop is the most safety-critical path
  in the kernel.
- **The exec-bit hand-off's automation.** Detection and non-charging already
  exist in `lib/drive.sh`; only the fix needs runtime capability proof.
- Everything in `r-003-requirements.md` Tracks A–G that is not marked closed.

## 4. Working rules this repository actually taught

These cost real time to learn. They are not style preferences.

**Re-measure a finding before fixing it.** Five plan items turned out to be
partly repaired already by machinery that landed later in r-002. Build the
fixture, watch the defect, THEN write the test. When the reproduction fails, say
so in the plan doc rather than quietly narrowing scope — and assert the other
mechanism's artifact in your own test, so the claim that it covers the case
fails loudly if it stops being true.

**Match the gate to the blast radius.** `scripts/ci-local.sh` takes roughly two
hours, most of it `test_hermetic_suite.sh` re-running the whole suite nested.
Running it on a docs-only change wastes an hour and proves nothing. Use
`--no-tests` (whole-tree static + ShellCheck) plus the suites the change
touches; reserve the full run for changes in the dispatch, merge or verify
paths. Hosted CI on push is the broader check.

**A green local suite is not evidence about a slower machine.** Three fixtures
failed on hosted macOS while passing locally and on ubuntu, all because they
sequenced against concurrency with a bare `sleep`. Two were fixed by waiting on
a causal signal instead (`tests/test_merge.sh`'s CAS case waits for a marker the
validation writes; `tests/test_verb_lock.sh` counts entries against the calls
that SUCCEEDED). One — INV-16's `ETHREE` mint assertion — was seen once, never
reproduced, and deliberately NOT added to `tests/QUARANTINE.md`: that register
makes the driver classify a matching failure as `flaky` instead of `candidate`,
and buying silence for a real invariant on one sighting is the forgiveness-arm
mistake. If it is seen again, that is the point to diagnose or quarantine it.

**Traps that bit repeatedly, all caught by the gates rather than by care:**

- `assert_eq done "$(...)"` — a bare shell keyword as an argument is SC1010, a
  parse error to ShellCheck. Quote keyword literals.
- `producer | grep -q pat && fail` — `grep -q` exits at first match and
  SIGPIPEs the producer; under `pipefail` that becomes the pipeline's status,
  so the `&&` is not taken and the assertion is **skipped exactly when the
  pattern is present**. Capture into a variable and use a herestring. INV-15
  enforces this.
- `assert_match` is `grep -Eq`: alternation is a bare `|`. `\|` matches a
  literal pipe and will never alternate. (21 existing uses of `\|` are correct —
  they match the literal pipes in `choices: unblock | retry | defer`.)
- A `case` arm's `)` inside `$( ... )` is read by bash as closing the
  substitution. Move the walk into a helper.
- Tests have no `set -e`. A refused verb is silent, so a fixture whose
  `ORCHID_REPO` is not a checkout parked on the integration branch fails every
  call and the first symptom is an unrelated assertion.
- A new config key needs three registrations: `lib/config-keys.txt`,
  `orchid.config.example`, and a row in `docs/configuration.md`. The docs gate
  checks the third.
- A new `tests/inv/` file needs `# RED:` and `# GREEN:` annotations of at least
  24 characters; `tests/test_red_case_rule.sh` enforces it.

**Capture exit codes and assert them.** ShellCheck's SC2034 caught the same
mistake three times: an exit status captured and never checked, leaving an
assertion that a refusal for some *other* reason would satisfy.

## 5. Machine-local state

- `~/workspace/personal/` holds exactly two checkouts: `orchid` (on `main`) and
  `orchid-orchid` (the `orchid/integration` worktree, which is where r-002's
  run state lives). Forty stale task worktrees and thirty stray temp files were
  removed on 2026-09-13.
- `task/*` branches: **none.** Forty were deleted after verifying each was
  contained in `orchid/integration`. One was not contained and was renamed
  rather than deleted: **`r-002/T024-preserve`** — it holds work that never
  merged. Do not delete it without reading it.
