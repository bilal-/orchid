---
schema: 1
id: __ID__
title: __TITLE__
status: pending
archetype: __ARCHETYPE__
scaffold: false
branch: task/__ID__
worktree:
run_id:
depends_on:
attempts: 0
infra_failures: 0
session_id:
implementer_engine_id:
base_sha:
candidate_sha:
risk_tier: low
blocking_severity: high
stop_condition: report at most 8 findings at or above medium severity; no style nits; one pass only
hook_guidance:
engine: __ENGINE__
effort: medium
acceptance_criteria:
verification_commands:
resources:
exclusive: false
wallclock_budget_s: 28800
started_at:
created: __DATE__
updated: __DATE__
---

(Task spec: goal, constraints, acceptance criteria. Rework history appended below.)

Test lens: adds/extends tests only; production code edits forbidden beyond
trivial testability seams (journal any).
