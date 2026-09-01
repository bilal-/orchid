# Journal

## 2026-08-07T02:39:05Z run intervention (operator e33)
run rollover: r-001 archived to runs/r-001/ -> r-002: r-001 hardening run complete and merged as PR #11; opening r-002 to close the defects and structural gaps r-001 deliberately deferred

## 2026-08-07T02:39:29Z run lesson (operator e33)
L017 updated (invalidate_when)

## 2026-08-07T02:40:23Z run plan_revision (operator e33)
requirements imported from requirements.md

## 2026-08-07T02:43:58Z run plan_revision (operator e33)
requirements imported from requirements.md

## 2026-08-08T23:20:38Z T001 risk_change (operator e33)
low -> high: concurrency correctness in the driver: the failure mode is several implementers writing one worktree (blocking_severity -> medium)

## 2026-08-08T23:20:39Z T002 risk_change (operator e33)
low -> medium: operator-facing setup verb whose own acceptance criteria require idempotence (blocking_severity -> medium)

## 2026-08-08T23:20:55Z T003 risk_change (operator e33)
low -> medium: reintroduces on the soft path the never-told-the-human failure the brokered path was fixed to remove (blocking_severity -> medium)

## 2026-08-08T23:20:55Z T004 risk_change (operator e33)
low -> medium: the rehearsal is the release gate's own evidence; a vacuous pass is worse than no check (blocking_severity -> medium)

## 2026-08-08T23:21:11Z T005 risk_change (operator e33)
low -> low: self-contained probe script; no kernel surface (blocking_severity -> high)

## 2026-08-08T23:21:11Z T006 risk_change (operator e33)
low -> high: changes when every verb will refuse to run; a wrong gate bricks the tool (blocking_severity -> medium)

## 2026-08-08T23:22:53Z T007 risk_change (operator e33)
low -> high: changes the merge path every task depends on (blocking_severity -> medium)

## 2026-08-08T23:22:54Z T008 risk_change (operator e33)
low -> medium: ledger data drives role resolution; wrong data disqualifies a working engine (blocking_severity -> medium)

## 2026-08-08T23:25:26Z T013 risk_change (operator e33)
low -> high: CI on main is red on both platforms; this is the first signal any external beta tester sees (blocking_severity -> medium)

## 2026-08-08T23:25:26Z T014 risk_change (operator e33)
low -> high: lib/common.sh's lock_acquire runs on every durable verb; it dies under set -u on Linux (blocking_severity -> medium)

## 2026-08-08T23:25:42Z run lesson (operator e33)
L019 added (repo): A CI WORKFLOW THAT HAS NEVER RUN IS NOT A GATE, AND 'the local gate passed' IS NOT 'CI passed'. r-001's T004 added .github/workflows/ci.yml and its acceptance criterion was that the CONFIGURATION is valid with Linux/macOS jobs — not that it ever executed. Nothing was pushed for the whole run, so the workflow first ran on 2026-08-06 when the branch was finally pushed for PR #11, and it FAILED on ubuntu-latest and macos-latest, on all three runs that exist. Meanwhile the operator's run-level acceptance was recorded as PASS on the strength of a local 'scripts/ci-local.sh' run. Both statements were true and they were about different things. TWO ROOT CAUSES, both worth generalizing. (1) THE SUITE IS NOT HERMETIC: tests/test_plugins_test.sh asserts binaries_present for codex, claude and agy, which are installed on the author's machine and absent on a runner — so the local gate passes for an environmental reason the CI cannot reproduce. Any suite that can pass because of what happens to be installed is measuring the machine, not the code; PATH-restrict a run and see what actually survives. (2) A CORRECT FIX THAT WAS NEVER GENERALIZED: 'stat -f %m || stat -c %Y' selects the platform on exit status, but GNU stat -f is filesystem mode and can succeed with non-numeric output, so the fallback never fires and the following arithmetic dies under set -u ('File: unbound variable'). T005's implementer diagnosed precisely this and fixed it correctly at libexec/orchid-start:162-165, with the rationale in a comment — and five other sites still carry the raw form, including lib/common.sh:465 which every durable verb's lock acquisition runs through. Same shape as L016: the mechanism existed and nothing made it apply beyond the file that found it. RULE: when a task fixes a portability or safety idiom, grep the tree for the same idiom in the same commit, or file the sweep as its own task — do not leave the fix stranded in the file that discovered it.

## 2026-08-09T15:13:21Z T009 risk_change (operator e33)
low -> medium: operator-facing health signal for the channel the hero demo depends on (blocking_severity -> medium)

## 2026-08-09T15:13:22Z T010 risk_change (operator e33)
low -> medium: changes the rework contract every restricted-profile task depends on (blocking_severity -> medium)

## 2026-08-09T15:13:39Z T011 risk_change (operator e33)
low -> medium: settles whether repository content may reach execution without an acknowledgement (blocking_severity -> medium)

## 2026-08-09T15:13:39Z T012 risk_change (operator e33)
low -> medium: changes which reviewers can satisfy a tier, so it changes what review evidence means (blocking_severity -> medium)

## 2026-08-09T15:20:34Z T015 risk_change (operator e33)
low -> medium: owns the run's final honesty pass: docs, lessons and the acceptance evidence (blocking_severity -> medium)

## 2026-08-09T15:40:54Z run plan_revision (operator e33)
requirements imported from requirements.md

## 2026-08-09T15:54:03Z run plan_revision (operator e33)
requirements imported from requirements.md

## 2026-08-09T16:04:05Z run plan_revision (operator e33)
r-002 roadmap: 15 tasks closing r-001's deferred defects, making its guarantees self-enforcing, and settling two design questions; critique clean at attempt 5 after 30 findings folded in
