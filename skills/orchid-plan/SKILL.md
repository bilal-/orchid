---
name: orchid-plan
description: Plan and critique work for an Orchid-managed repository from user requirements. Use when asked to initialize or plan Orchid work.
---

Read `orchid` first. Load `orchid protocol planning --full` for the canonical procedure, and use focused `orchid start --help` and `orchid plan --help` for command forms. Ask for a verification command when the user has not supplied one; never invent a passing test command.

On a new repository, the user-authorized `orchid start requirements.md --verify "<real test command>"` performs preflight, initialization, integration worktree setup, ownership and requirements import, then returns the planning handoff. On existing work, inspect the current run and ownership before issuing a mutation. Pass `ORCHID_REPO` and the returned `ORCHID_EPOCH` explicitly. Preserve unrelated working trees and files.

Follow the planning procedure's independent critique and evidence gates. Use scoped task and requirement records, not a full protocol dump. Do not author or rewrite durable `.orchid/` state outside Orchid verbs. The kernel's refusal and stderr are evidence; inspect them before trying a different command. User choices, unresolved discrepancies and completion acceptance remain operator decisions. Hand off established work to the `orchid` skill.
