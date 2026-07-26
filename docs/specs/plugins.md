# Orchid — Plugin Specification

*Normative. One of four documents split from the design spec; see [2026-07-24-orchid-design.md](./2026-07-24-orchid-design.md) for the index and orientation.*

## Plugin architecture

Everything outside the kernel is a plugin; **the built-ins are plugins**
(same discovery, same contracts — if a built-in needs a private API, the
design has failed). Kernel code never branches on a plugin's name; behavior
differences are declared capabilities.

### Trust model (the part that makes "any engine" safe to say)

- Executable plugins are **trusted code** — orchid v0/v1 does not sandbox
  them, and says so plainly rather than implying containment it doesn't
  have. Full containment (per-plugin sandbox profiles enforced by the
  launcher) is post-v1 roadmap.
- Consequently: plugins load ONLY from user-controlled locations —
  `~/.orchid/plugins/` and the orchid installation's `plugins/` — plus
  explicit `$ORCHID_PLUGIN_PATH` entries (colon-delimited, each entry a
  directory whose children are `<kind>/<name>/`).
- **Repo-local plugins (`<target-repo>/.orchid/plugins/`) are DISABLED by
  default.** Enabling one requires `orchid plugins trust <path>` (v1), which
  records the plugin's SHA-256 digest in `~/.orchid/trust` — OUTSIDE the
  repo. A digest mismatch (e.g. after a pull) de-trusts it. Cloning a repo
  must never grant code execution.
- **No silent shadowing:** duplicate plugin IDs across the search path are
  an ERROR reported by doctor, never a precedence win. IDs are qualified
  (`publisher/name`, built-ins under `orchid/`); names matching `..`,
  containing slashes beyond the qualifier, or resolving through symlinks
  outside their root are rejected.
- `orchid doctor` reports every discovered plugin's origin, trust status,
  and any collision BEFORE anything executes.
- **Kernel launcher hygiene (v1):** all plugin executables are launched by
  the kernel with stdin from `/dev/null` (kills a whole class of hidden
  interactive hangs: SSH/GPG/LFS prompts), an environment allowlist
  (secrets are opt-in per plugin via manifest `permissions`), a
  kernel-chosen private output location, and the invocation request document
  below. Vendor-CLI sandbox flags (workspace-write, read-only) remain the
  engine-level second layer.

### Extension points and contracts

| Kind | Contract | Stage |
|---|---|---|
| **engine** | executable `run`; receives a request document; writes an envelope to the kernel-specified spool path; declares atomic capabilities | v0 (seam), v1 (manifests) |
| **archetype** | data-only workflow declaration validated against kernel invariants (below) | feature v0; review v1-m1; rest v1-m3 |
| **notify channel** | `send <question-id> <text>`; inbound via `orchid answer` | v1-m4 |
| **hook** | named lifecycle hook handlers with typed payloads (below) | v1-m3 |
| **role** | descriptor: required/forbidden capabilities + hook bindings | v1-m3 |

Front-ends (Claude skill, headless tick, a future TUI) are a documented
CONVENTION — anything that executes PROTOCOL.md through verbs — not a
discovered plugin kind.

**Engine invocation — request document + input pack.** The tier-2 launcher
invokes `<plugin>/run <request.json>`. Requests are a discriminated union on
`operation` (`implement | review | critique | research | hook | orchestrate`
— the headless tick itself uses the same contract). Common fields:

```json
{ "request": 1, "job_id": "j-<nonce>", "run_id": "r-003", "epoch": 17,
  "task": "T001", "attempt": 3, "role": "reviewer", "operation": "review",
  "base_sha": "...", "candidate_sha": "...",
  "input_pack": "<abs dir>", "output": "<abs path in spool>",
  "worktree": "<abs path|null>", "deadline_s": 3600,
  "policy": "read-only|workspace-write", "model": "...", "effort": "medium" }
```

**The input pack** replaces path-guessing entirely: the kernel materializes
a per-job directory containing exactly the memory that role receives (per
the injection table in kernel.md, Memory & resumption), with a `pack.json` manifest listing every artifact,
its byte count and digest, and everything OMITTED for budget. Budgets are
concrete: 64 KB total default (per-role overridable); correctness-critical
inputs (task body, acceptance criteria, the diff for reviews) are
NON-TRUNCATABLE — if they alone exceed budget, the launch fails with
`input_overflow` rather than silently truncating; journal/lessons/context
trim in that order (journal tail-first, context head-first), and every trim
is recorded in the manifest. **Overflow classification:** `input_overflow`
is first a TASK-SHAPING signal — the orchestrator's prescribed response is
to split the task (journaled `plan_revision`), not raise the budget;
chunked review is a post-v1 fallback, and a raised budget is an operator
decision in config. **Visibility honesty:** worktree-capable
engines can physically read the whole checkout, including committed
`.orchid/` state — the pack defines what they are GIVEN, the execution
policy defines what they may DO, and review independence never rests on
secrecy.

One adapter serves many roles by branching on `operation` — no pseudo-engine
identities. Adapters never guess paths, never choose output locations, exit
nonzero on detectable failure.

**Result envelope (versioned; fail closed).** Written atomically to the
request's `output` path:

```json
{ "contract": 1, "job_id": "j-<nonce>", "task": "T001", "attempt": 3,
  "engine": "orchid/codex", "role": "reviewer",
  "status": "ok|failed|rate_limited|timeout|auth|malformed",
  "base_sha": "...", "candidate_sha": "...", "session_id": "...",
  "started_at": "...", "ended_at": "...", "retry_after": null,
  "verdict": "approve|request-changes|n/a", "scope_complete": true,
  "findings": [ { "severity": "...", "title": "...", "detail": "..." } ],
  "diagnostics": { "trajectory_log": "<path>" } }
```

**Envelopes are the same union:** per-operation required payloads on top of
the common fields — `review` → `verdict`, `scope_complete`, `findings[]`;
`critique` → `findings[]`; `research` → `citations[]` + `summary`;
`implement` → `commits[]` (SHAs produced) + `summary`; `hook` → typed
artifact per hook schema; `orchestrate` → `actions[]` (the verb invocations
the tick performed, for audit). An `ok` missing its operation's required
payload is `malformed`.

**Binding rules (anti-forgery):** `job_id` is kernel-minted per launch
(distinct from the logical rework `attempt`); reconciliation accepts an
envelope ONLY if a live manifest matches its `job_id`, and takes engine
identity, role, task, and SHAs from the MANIFEST, cross-checking the
envelope; any mismatch, replay (already-reconciled job_id), oversize, or
schema violation → quarantine, never acceptance. "Tests pass" is
established solely by `orchid verify`, never by envelope claims (engine
trajectories are diagnostics).

**Manifest (`plugin.conf`, v1) — a real compatibility contract:**

```
manifest_version=1
id=orchid/codex            # qualified, immutable
version=0.3.0
kind=engine
api_version=1              # per-kind contract version
requires_orchid=>=0.2
capabilities=structured_text,workspace_write,shell,git
permissions=               # env vars / secrets requested (opt-in)
requires_binaries=codex,jq
platforms=macos,linux
entrypoint=run
```

Unknown keys in a known `manifest_version`: warn. Unknown
`manifest_version`/`api_version`: reject (fail closed). `orchid plugins
validate` checks all of this; `orchid version` exposes the kernel version.

**Role & capability model (breaks the circularity):** engines declare atomic
capabilities (`structured_text`, `workspace_read`, `workspace_write`,
`shell`, `git`, `network`, `citations`, …). Role descriptors — including the
core five, which ship as descriptors like any custom role — declare required
(and optionally forbidden) capabilities. The resolver computes eligibility:
adding a `researcher` role never requires editing engine manifests. Core
role IDs are normalized (`orchestrator`, `implementer`, `reviewer`,
`arbiter`, `plan_critic`); config keys are `role.<id>`; **risk-tier routing
is policy on top of the reviewer role** (`review.low=...`,
`review.high=...`), not separate role names.

**Archetype meta-contract (kernel invariants no archetype can override):**
archetypes are data-only (states, transitions, templates, lens text — no
executable predicates) and are validated before activation: every path to a
code-merging terminal MUST pass `testing` (verify) and `reviewing`; retry
bounds are mandatory; terminal states are `done` and `blocked`; declared
`outcome: code|report` — `report` archetypes (like review) may skip
implement/merge but can never advance the integration branch. Unreachable
states are rejected.

**Hooks (v1-m3 — one mechanism for custom roles AND middleware):** a finite,
kernel-owned set of named extension points — `after_plan_draft`,
`before_arbitration`, `on_verify_fail`, `before_merge`, `on_blocker` — each
with a typed request payload, ordering, timeout, and required/optional
semantics. Handlers are plugins invoked through the same launcher and
request/envelope contracts; their results are validated artifacts applied
ONLY through tier-1 verbs (e.g. a `researcher` consulted `before_arbitration`
returns citations that the tick attaches via `orchid task set`). PROTOCOL.md
itself is never edited by plugins.

### Named patterns (the codebase vocabulary)

Verb kernel · Envelope · Adapter · Runner · Archetype · Ledger · Spool ·
Lease · Request document · Trust record · Hook.

## Engine availability & role failover (v1)

Ledger (`runtime/engines.json`: last status, `rate_limited_until`,
consecutive failures — updated via spool events) + primary→secondary
preference pairs per role in config (defaults: `role.orchestrator`
claude→codex; `role.implementer` codex→claude; `role.arbiter` claude→codex;
`role.plan_critic` any engine that did not author the plan; reviewers per
risk-tier routing) + the capability gate: a fallback (engine, role) pair
activates ONLY after passing the role×engine capability suite (filesystem
scope, network policy, subprocess, git, structured output, recovery). The pump: LLM-free heartbeat that launches
`orchid-tick` on the best available capable orchestrator engine when the
lease is stale (>15 min); mutual exclusion via lease staleness, not flock.
Independence rules (kernel.md, Task lifecycle) apply against the task's recorded implementer.
High-risk arbitration waits (bounded, default 4h) for the preferred arbiter.
Model/effort: static per-role defaults in v1; risk×model matrix v1-m4.

## Threat model (consolidated)

| Untrusted input | Boundary | Mitigation |
|---|---|---|
| cloned repo content (incl. `.orchid/plugins/`) | plugin discovery | repo-local disabled by default; digest-pinned trust records outside the repo; no silent shadowing |
| plugin executables | trust decision at install | trusted-code classification (stated plainly); launcher hygiene; containment roadmap post-v1 |
| engine output (envelopes) | reconciliation | job_id binding to manifests; schema fail-closed; quarantine on mismatch/replay |
| task/diff content in prompts | reviewer/arbiter judgment | prompt injection is assumed possible; verdicts are advisory to the arbiter, which reads high-risk diffs itself; verification is deterministic and immune to prompt content (`orchid verify`) |
| inbound answers | `orchid answer` | question-id + idempotency; channel adapters get no shell/repo access; nonce + sender allowlist when remote channels ship (v1-m4) |
| implementer commits | merge path | worktree contamination guard; review immutability; transactional merge |
