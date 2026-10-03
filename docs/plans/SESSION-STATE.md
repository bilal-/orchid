# Where things stand — resume point

Written 2026-09-13. This file is the hand-off between working sessions and is
deliberately agent-agnostic: read it before doing anything else, whatever tool
you are. It records state that the code and git history do not make obvious,
and it goes stale — **verify every claim below against the tree before relying
on it.** Anything here that contradicts the code is wrong and the code wins.

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
