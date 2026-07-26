# Orchid — Design Spec (v5)

**Date:** 2026-07-25 (v1 2026-07-24)
**Status:** v5 + round-5 (Perplexity deep-dive) incorporated. The monolith
has been split into four normative documents — `kernel.md`, `plugins.md`,
`operations.md`, `roadmap.md` — per the rule: if removing a section would
not change conformance, it lives outside the kernel spec.

## Purpose

Orchid is a multi-agent orchestrator for people who hold subscriptions to
several AI coding CLIs and want them working together on large, long-running
tasks. **Roles — orchestrator, implementer, reviewer, arbiter, plan_critic,
and future custom roles — are pure configuration**; any engine whose declared
capabilities satisfy a role's requirements can hold it. The shipped defaults
reflect the author's subscriptions (Claude Code orchestrates/arbitrates,
Codex implements, Antigravity and a fresh Codex session review), but nothing
in the architecture privileges them.

**Positioning:** orchid aims to be the standard way individuals turn a
collection of AI subscriptions into an autonomous development team: a
deliberately small kernel and a first-class plugin architecture.
Extensiveness is a property of the ecosystem orchid enables — any
subscription, any model, any role, any workflow — never of the core. Growth
happens at the extension points, not in the kernel.

The four documents below are normative; this page is orientation.

## Documents

| Document | Covers |
|---|---|
| [kernel.md](./kernel.md) | The normative core: architecture (process model, ownership table, run state), the two reference sequence diagrams, preflight, task lifecycle, memory & resumption, stuck-agent detection, guardrails, execution policy, glossary, kernel guarantees, and the conformance invariants (INV-01..12) that tests carry. |
| [plugins.md](./plugins.md) | The plugin architecture: trust model, extension points, request/envelope/input-pack contracts, manifests, the role & capability model, the archetype meta-contract, hooks, engine availability & failover, and the consolidated threat model. |
| [operations.md](./operations.md) | The operator's manual: installation & configuration, the operator walkthrough, and remote interaction (notify/answer today; the three-actor remote-channel topology in v1-m4). |
| [roadmap.md](./roadmap.md) | Requirements, delivery stages (v0 vertical slice through v1's four milestones), public distribution & ecosystem strategy, empirical verification findings and review history, and future (post-v1) work. |
