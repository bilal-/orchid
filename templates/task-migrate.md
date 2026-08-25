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
# depends_on: comma- or whitespace-separated ids of tasks that must reach
# `done` before this one dispatches (e.g. `T001,T002`); each must already exist
depends_on:
attempts: 0
attempt_budget:
infra_failures: 0
session_id:
implementer_engine_id:
base_sha:
candidate_sha:
risk_tier: medium
blocking_severity: medium
stop_condition: report at most 8 findings at or above medium severity; no style nits; one pass only
hook_guidance:
handoff_ack:
engine: __ENGINE__
effort: medium
acceptance_criteria:
verification_commands:
resources:
exclusive: true
wallclock_budget_s: 28800
started_at:
created: __DATE__
updated: __DATE__
---

(Task spec: goal, constraints, acceptance criteria. Rework history appended below.)

Migrate lens: schema/data/format migration; MUST include a rollback note
and an idempotence statement in the task body.

Rollback note:
Idempotence statement:
