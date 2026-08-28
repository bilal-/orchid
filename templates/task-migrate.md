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
operator_prerequisite:
prerequisite_ack:
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

Applying the migration is NOT part of this task. A migration task authors
the migration and the tests that prove it; nothing in the tick applies it to
the store those tests run against, and the sandbox that writes the migration
is not the place to hold schema-write credentials for it. So if this task's
verification cannot pass against an unmigrated store, whoever plans it sets
`operator_prerequisite` to the exact step a human must take first (`orchid
task set <id> operator_prerequisite "apply db/migrate/00NN_*.sql to the test
database"`). The run then stops at a `task-prerequisite` judgment boundary
BEFORE the suite runs — no failing log, no attempt spent — until the
operator does it and records that with `orchid task prereq-ack <id> --reason
"..."`. Leave it empty when the suite migrates its own store (a fixture,
a temp file, an in-memory DB the tests build), which is the better design
where it is available at all.

Rollback note:
Idempotence statement:
