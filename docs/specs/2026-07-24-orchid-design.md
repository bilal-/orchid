# Orchid — Design Spec

**Date:** 2026-07-24
**Status:** Approved (two external design-review rounds by codex and agy plus
an internal review incorporated; pending final user review)

## Purpose

Orchid is a lean multi-agent orchestrator for people who hold subscriptions to
several AI coding CLIs and want them working together on large, long-running
tasks. **Roles — orchestrator, implementer, reviewers, arbiter — are pure
configuration** (`role.*` keys in `orchid.config`); any engine meeting a
role's capability requirements can hold it. The shipped defaults reflect the
author's subscriptions — Claude Code orchestrates/arbitrates, Codex CLI
implements, Antigravity (`agy`) and a fresh Codex session review — but
nothing in the architecture privileges them: the orchestration procedure
lives in engine-neutral `PROTOCOL.md`, state lives in files, and engines are
adapters behind one envelope contract. Heavy token usage lands on whichever
subscriptions hold the implementer/reviewer roles, keeping the orchestrating
session cheap enough to drive multi-day runs.

**Positioning:** orchid aims to be the standard way individuals turn a
*collection of AI subscriptions* into an autonomous development team. The
strategy for getting there is the one every category-winning developer tool
used (git, VS Code, Neovim): a deliberately small kernel and a first-class
plugin architecture. Extensiveness is a property of the ecosystem orchid
enables — any subscription, any model, any role, any workflow — never of
the core. Growth happens at the five extension points (see Plugin
architecture), not in the kernel.

Honestly stated, the kernel is a small **file-based workflow scheduler**:
deterministic CLI verbs plus stateless LLM ticks over git state. Design
principles: no daemon, no dashboard, no terminal emulation, no persistent
runtime process. Engines are driven through their first-party headless
modes, so billing stays on each vendor's subscription. All durable state is
files in git — sessions are disposable; the files are the truth.

## Requirements (from design session)

- **Run model:** semi-attended. An interactive Claude Code session is the
  primary surface; the machine stays awake. The LLM-free pump plus headless
  `orchid-tick` (stage v1) keep the run advancing when the interactive
  session is rate-limited or closed; service packaging (survive reboots) is
  deferred.
- **Scope:** existing repos first (stage v0); greenfield products (stage v1).
- **Engine roles:** fully configurable via `role.*` keys from v0 — orchid
  never hard-codes an engine to a role. v0 ships and TESTS only the default
  bindings (Claude orchestrates/arbitrates, Codex implements, reviewers per
  risk tier); non-default bindings are supported-but-unverified until the
  capability suite (v1) passes them. Preference-ordered failover per role
  arrives in v1.

  Role capability requirements (what a candidate engine must provide):

  | Role | Needs |
  |---|---|
  | orchestrator | headless mode + shell/git/subprocess execution (to run `orchid` verbs and launch adapters) |
  | implementer | headless mode + file writes and shell inside a worktree |
  | reviewer | text in, text out — nothing else (inline mode); worktree read access optional for depth |
  | plan-critic | text in, text out |

  The reviewer/critic rows are deliberately minimal: ANY model — including
  API-only models with no CLI tooling — can review via inline mode with a
  ~40-line adapter.
- **Autonomy:** fully autonomous — no user approval gates; only genuine
  blockers are surfaced, bounded by the Execution policy. **Continuity
  promise (stated precisely):** a single engine outage never loses state and
  never stops *eligible* work; work whose policy requires an unavailable
  engine queues until that engine's window reopens. With failover enabled,
  orchestration itself continues on a fallback engine.
- **Distribution:** public GitHub repository for general benefit (see
  Distribution; public only after dogfooding).
- **Non-goals (all stages):** daemon/service, web UI, cost ledger,
  multi-user, cross-machine operation, chat-style inter-agent messaging,
  native phone app. Orchid never builds ON agent runtimes (OpenClaw, Hermes)
  — they plug in as engines or notify channels only.

## Delivery stages

The full design below is the destination; delivery is staged so each layer is
proven before the next depends on it. (Both external reviewers independently
flagged v1-in-one-bite as infeasible; staging preserves the vision.)

- **v0 — vertical slice:** one existing repo, ONE active task at a time
  (serial), default role bindings (roles read from `role.*` config from day
  one; only the defaults are tested), `feature` archetype only. The plugin
  SEAM ships in v0 (engine resolution via the search path, so a dropped-in
  adapter works day one); manifests, `orchid plugins list`, and doctor
  validation arrive in v1. CLI core verbs
  (doctor/task/verify/merge/jobs/status/notify), deterministic verification
  and transactional merge, hard timeout + clean relaunch (no PID
  re-adoption), manual `orchid-resume`. Includes crash/recovery test and
  webBooks dogfood run.
- **v1:** pump + orchestrator/implementer failover (each role×engine fallback
  enabled only after passing the capability suite), concurrency 2 with
  scheduling rules, risk-tiered dual review + arbitration policy, greenfield
  mode, `review` archetype, README + screenshots, **public release**.
- **v1.x:** `refactor`/`test`/`migrate` archetypes (need per-ecosystem
  tooling adapters), cost/risk routing matrix, OpenClaw two-way notify,
  static status page, launchd/cron service packaging, **role registry**
  (custom roles with PROTOCOL extension points), and two REFERENCE
  third-party plugins that prove the surface: an API-backed reviewer engine
  (e.g. Kimi) and a `researcher` role (e.g. Perplexity) — each doubling as
  the tutorial in `docs/extending/`.

## Architecture

Two locations; strict split between tooling (global, this repo) and run state
(per target repo).

### Tool repo: `~/workspace/personal/orchid/`

```
PROTOCOL.md                 # engine-neutral tick procedure — the single source
                            # of orchestration truth, written in CLI verbs
skills/                     # the CLAUDE front-end for the orchestrator role —
  orchid/SKILL.md           #   one of several possible front-ends, not the
  orchid-plan/SKILL.md      #   architecture. Thin shims: they load PROTOCOL.md
  orchid-resume/SKILL.md    #   and call verbs. Other engines orchestrate via
  orchid-review/SKILL.md    #   runners/orchid-tick rendering the same PROTOCOL.
                            #   (orchid-review skill: v1; others v1.x)
bin/
  orchid                    # THE CLI: git-style dispatcher
libexec/                    # TIER 1 — deterministic verbs. Never invoke an LLM,
  orchid-doctor             #   never block on the network. Sole mutators of
  orchid-task               #   durable state (validated transitions, atomic).
  orchid-verify             #   `orchid verify <id>`: run verification_commands
  orchid-merge              #   `orchid merge <id>`: transactional merge (below)
  orchid-jobs               #   manifests, reconcile, deterministic stall checks
  orchid-status
  orchid-notify
runners/                    # TIER 2 — effectful: launch LLM sessions. Explicitly
  orchid-tick               #   OUTSIDE the deterministic core.
  orchid-pump               #   (v1)
plugins/                    # TIER 3 — the BUILT-IN plugin set, discovered via
  engines/codex/            #   the same search path and contracts as any
  engines/codex-review/     #   third-party plugin (see Plugin architecture).
  engines/agy/              #   Engine adapters write ONLY to the runtime
  engines/claude/           #   spool (envelopes, logs), never durable state.
  archetypes/feature/       #   Archetype = transition table + templates.
templates/
  roadmap.md  task.md  review.md
install.sh                  # symlinks skills into ~/.claude/skills AND links
                            #   bin/orchid onto PATH; prints uninstall steps
docs/specs/                 # this document and successors
README.md  LICENSE          # public-facing docs (MIT)
```

**The determinism boundary (hard rule, tier 1 only):** `libexec/` verbs are
deterministic plumbing — verbs over files, no LLM calls, no daemon, no
database, no message routing. Runners and engines are effectful by nature and
are named as such; they hold no orchestration logic. Any proposed tier-1
feature that fails the determinism test is rejected.

**Single-writer rule:** durable state (`.orchid/`, committed) is mutated ONLY
through tier-1 verbs, ONLY by the process holding the run lock (normally the
tick). Engines and runners write ONLY to the runtime spool. Human
intervention also goes through verbs (`orchid task ...`), never hand-edits.
`orchid task advance` validates every transition against the state machine —
per-archetype transition tables — and refuses illegal moves: malformed state
is impossible by construction.

### Run state: `<target-repo>/.orchid/`

```
# committed (durable, on the integration branch only):
requirements.md             # user's brief, verbatim, with requirement IDs
roadmap.md                  # milestones → tasks + requirement coverage map
baseline.md                 # pre-run test results (pre-existing failures)
context.md                  # context pack (see Plan phase)
tasks/T001.md ...           # one spec per task (frontmatter + body)
reviews/ ...                # review verdicts and verification logs (durable)
BLOCKERS.md                 # human-readable blocker log

# runtime/ (gitignored — machine-local, volatile):
lock/                       # run lock (portable mkdir-lock; flock(1) does not
                            #   exist on macOS)
lease.json                  # orchestrator heartbeat lease (see Locking)
jobs/ ...                   # write-ahead job manifests
spool/ ...                  # engine result envelopes awaiting reconciliation
engines.json                # availability ledger (quota state is per-machine)
answers/                    # user replies awaiting consumption
logs/ ...                   # engine session logs
```

**Bootstrap order (existing repo):** `orchid doctor` → create the integration
branch from the user's default-branch HEAD → write and commit `.orchid/`
there. User branches are never touched; orchid operates only on branches it
creates. **Greenfield (v1):** `orchid-plan` creates the repo and MUST make a
root commit (`requirements.md`, `.orchid/`, `.gitignore`) before any worktree
is created — `git worktree add` requires an existing HEAD; scaffolding is
task T001; `orchid doctor --greenfield` skips checks that cannot apply before
scaffolding (e.g. test-command discovery).

### Locking & the orchestrator lease

- **Run lock:** `mkdir`-based lock in `.orchid/runtime/lock/` (portable;
  works on macOS). Exactly one process — a tick, or a human-invoked verb
  batch — holds it for a complete reconcile-and-dispatch transition.
- **Heartbeat lease:** whoever is orchestrating (interactive session or
  headless tick) refreshes `lease.json` each turn. The pump (v1) launches a
  headless tick ONLY when the lease is stale (default >15 min) — `flock`-style
  mutual exclusion cannot span a multi-step interactive LLM turn; the lease
  can. One orchestrator context at a time, guaranteed by staleness, not luck.
- The pump itself never takes the run lock; it merely launches `orchid-tick`,
  which acquires the lock exactly once for its full transition.

## Plugin architecture

Everything outside the kernel is a plugin. The kernel is: the state machine
(`orchid task`), jobs/spool/lock, verify/merge, and the envelope contract.
**The built-ins are themselves plugins** — codex/agy/claude adapters and the
feature archetype use the exact same discovery and contracts as third-party
plugins. This is the proof the plugin surface is real: if the built-ins need
a private API, the design has failed.

### Five extension points

| Kind | Contract | Example third-party plugin |
|---|---|---|
| **engine** | executable `run <task-id>`; reads task file + context; writes envelope (contract 1) to spool; honors `ORCHID_DRYRUN`; declares which roles it can hold (capability table) | `kimi-k3` (Moonshot CLI or API-backed), `hermes` |
| **archetype** | manifest declaring its legal transition table + task/roadmap templates + reviewer lens text | `security-audit`, `docs-site` |
| **notify channel** | executables `send <question-id> <text>` and (optional) inbound calls to `orchid answer` | OpenClaw bridge, Telegram bot, ntfy |
| **orchestrator front-end** | anything that executes PROTOCOL.md via CLI verbs | Claude skill (built-in), `orchid-tick` headless (built-in), a future TUI |
| **role** *(v1.x)* | named role + capability requirements + PROTOCOL extension point where it is consulted | `researcher` (Perplexity: consulted at plan time and on arbitration disagreements, returns cited findings into the task file) |

### Discovery & manifests

Plugins are directories found on a search path (first match wins):

```
$ORCHID_PLUGIN_PATH → <target-repo>/.orchid/plugins/ → ~/.orchid/plugins/ → <orchid>/plugins/ (built-ins)
```

Each plugin directory contains `plugin.conf` (key=value, parsed never
sourced) plus its executables/templates:

```
~/.orchid/plugins/engines/kimi-k3/
  plugin.conf     # kind=engine  name=kimi-k3  contract=1
                  # roles=reviewer,plan-critic  (what it is capable of)
  run             # the adapter executable
```

`orchid plugins list` shows everything discovered with kind, version, and
contract; `orchid doctor` validates that every configured `role.*` binding
resolves to a discovered plugin whose declared roles include it.

### Contract rules

- Every contract is versioned; the kernel rejects (fails closed) a plugin
  declaring a contract version it does not support.
- Contracts only ever gain optional fields within a major version.
- An engine plugin needs no orchid code changes — drop the directory, add a
  `role.*` line, done. Target: **a working third-party engine adapter in
  under an hour, under 60 lines** (the reviewer role's minimal capability —
  text in, text out — makes API-only models like Perplexity or a Kimi API
  key first-class citizens, not second-class to CLI subscriptions).
- Kernel code never branches on a plugin's name. If a feature needs
  `if engine == codex`, it becomes a capability flag in `plugin.conf`.

### Named patterns (the vocabulary of the codebase and docs)

- **Verb kernel** — deterministic tier-1 CLI; sole mutator of durable state.
- **Envelope** — the versioned JSON result contract between engines and the
  kernel.
- **Adapter** — an engine plugin translating one vendor's CLI/API into the
  envelope.
- **Runner** — effectful launcher of LLM sessions (tick, pump); outside the
  determinism boundary.
- **Archetype** — a declared transition table + templates configuring the
  one state machine for an SDLC workflow.
- **Ledger** — runtime availability records driving failover dispatch.
- **Spool** — the write-only channel from engines to the kernel.
- **Lease** — staleness-based orchestrator ownership.

## Preflight (`orchid doctor`)

Runs before `orchid-plan` and before `orchid-resume`; fails safely without
modifying the repository. Validates: git topology (repo, clean-tree policy,
branch-name collisions, submodule/LFS presence noted), worktree support,
engine binaries/versions/authentication (cheap no-op call per engine),
configured models available, explicit verification commands present
(auto-discovery is v1.x; v0 requires them declared in `orchid.config`),
integration branch creatable, platform supported. `--greenfield` relaxes
repo-content checks as above.

## Task lifecycle

Task frontmatter is the state machine (the `feature` archetype's full table;
other archetypes declare their legal subset in their template, enforced by
`orchid task advance`):

```
pending → implementing → testing → reviewing → arbitrating → merging → done
                ↑            │         │            │
                └── rework (≤3) ───────┴────────────┤
                                                    └→ blocked
```

- **testing** is owned by `orchid verify <id>` — tier-1, deterministic: runs
  the task's `verification_commands` in the task worktree and records
  command, cwd, candidate SHA, timestamps, exit codes, and a log digest to
  `reviews/<id>-verify.log`. This is the ONLY acceptance authority for "tests
  pass." Engine-reported trajectories are stored as diagnostics, never
  trusted for control flow. Failures return to rework without spending
  reviewer tokens.
- **merging** is owned by `orchid merge <id>` — transactional and serialized:
  if integration HEAD has advanced past the task's `base_sha`, rebase the
  candidate onto HEAD first; any non-trivial delta (beyond clean rebase with
  no conflict and no semantic overlap per `git range-diff`) resets the task
  to `testing` for re-verification and re-review — a tree that was never
  reviewed must never merge. Then: merge into a temporary integration
  worktree, run the full suite against `baseline.md`, and only on pass
  advance the real integration branch and mark `done`; on failure
  (`validation_failed`) that exact candidate returns to rework with captured
  logs. Attribution is never ambiguous.

Frontmatter fields: `id, title, status, archetype, branch, worktree,
depends_on, attempts, infra_failures, session_id, base_sha, candidate_sha,
risk_threshold, stop_condition, engine, effort, acceptance_criteria,
verification_commands, created, updated`.

**Review immutability:** reviewers inspect exactly `base_sha..candidate_sha`;
any change to the candidate invalidates existing reviews. Dependencies must
be `done` before a task starts. An incomplete or malformed review NEVER
counts as approval (fail closed).

**Acceptance:** requirements get IDs at plan time; `roadmap.md` maintains the
requirement→task coverage map; every task carries observable acceptance
criteria and verification commands. A final acceptance gate — coverage check
plus end-to-end acceptance tests — runs before the run is declared complete.

`risk_threshold` and `stop_condition` are injected into every reviewer
prompt, e.g. "report at most 8 findings at or above medium severity; no style
nits; one pass only." This prevents the infinite-diligence loop.

**Independence (two distinct notions, both used):**

- *Session independence:* a different session of the same engine (fresh
  `codex exec review` vs. the implementing codex session). Guards against
  in-context self-justification.
- *Engine independence:* a different vendor's model entirely. Guards against
  shared blind spots.

Role rules:

- Codex implements on branch `task/<id>` in its own git worktree.
- **Review routing is risk-tiered:** `low` → single reviewer: agy inline
  (engine-independent, cheap; fallback `codex exec review` when agy is
  unavailable or the diff exceeds inline budgets). `medium`/`high` → dual
  review in parallel: `codex exec review` (session-independent, reads the
  worktree — depth) + agy inline (engine-independent — diversity). Risk is
  assigned at plan time; the orchestrator may upgrade after seeing the diff,
  never downgrade. When outages leave no engine-independent reviewer for a
  medium/high task, the task QUEUES (two-engine installs are labeled
  "degraded" in the README matrix and accept session independence for
  medium; high always queues for engine independence).
- The orchestrator arbitrates: findings below the task's risk threshold never
  block; reviewer agreement is strong signal; on disagreement the
  orchestrator reads the diff and decides. The orchestrator does not
  implement, except arbitration-level trivia (≤ ~10 lines); anything larger
  returns to Codex as a rework spec with `attempts` incremented.

## Run archetypes (the SDLC suite)

Archetypes are entry skills that configure the same machinery: each declares
its legal transition table, task defaults, acceptance shape, and reviewer
lens. `feature` and `review` are template-only; `refactor`/`test`/`migrate`
additionally need per-ecosystem tooling adapters (metrics, mutation,
inventory) and therefore land in v1.x, not as "just templates."

| Archetype | Stage | What changes |
|---|---|---|
| feature | v0 | the default full pipeline above |
| review | v1 | transitions `pending → reviewing → arbitrating → done`; reviewers + arbitration over a supplied `base..head`; output is a verdict report, not a merge |
| refactor | v1.x | precondition: characterization tests (generated if missing); acceptance = characterization suite passes UNCHANGED + stated goal metric; lens: behavior preservation |
| test | v1.x | generates tests/evals; acceptance = coverage delta + new tests fail against mutated code ("tests bite") |
| migrate | v1.x | inventory task, then batched per-site tasks; acceptance = suite green + grep gate: no deprecated API remains |

### Review completeness (inline agy reviews)

`engines/agy` builds the review prompt from `git diff base_sha..candidate_sha`
plus selected file context under an explicit byte budget. It always includes
an input manifest — every changed file, and anything omitted or truncated —
and requires `scope_complete: true/false`. Oversized diffs route to
`codex exec review` (worktree access); chunk-and-aggregate is v1.x.
`scope_complete: false` without a completed fallback blocks approval.

## Engine result contract

Every `engines/*` adapter writes a versioned JSON envelope atomically into
the runtime spool (temp file + rename); the locked tick reconciles spool →
durable state via tier-1 verbs:

```json
{ "contract": 1, "task": "T001", "attempt": "T001-a2",
  "status": "ok|failed|rate_limited|timeout|auth|malformed",
  "session_id": "...", "base_sha": "...", "candidate_sha": "...",
  "started_at": "...", "ended_at": "...", "retry_after": null,
  "scope_complete": true, "verdict": "approve|request-changes|n/a",
  "findings": [ { "severity": "...", "title": "...", "detail": "..." } ],
  "diagnostics": { "trajectory_log": "<path>" } }
```

Codex output uses its output-schema support; the agy adapter
validates/normalizes in the wrapper. Schema violations → `malformed`, which
fails closed. Free-form engine text is stored as diagnostics, never parsed
for control flow. "Tests pass" is established solely by `orchid verify`
(see lifecycle), not by any envelope claim. Contributors add engines by
writing one adapter honoring this envelope.

## The loop

The orchestrating session (interactive Claude, or a headless tick) executes
`PROTOCOL.md` — expressed entirely in CLI verbs. Each tick, under the run
lock:

1. `orchid jobs reconcile` — manifests vs. reality; ingest spool envelopes.
2. Advance tasks for finished jobs (`orchid task advance`).
3. Launch new work up to the concurrency cap (v0: 1 active task; v1: 2
   implementers plus reviews), honoring scheduling rules.
4. `orchid merge` at most one approved candidate.
5. Commit durable state; refresh the lease.
6. Sleep with a long fallback wakeup. Background job completions re-invoke
   the interactive session (Claude Code task notifications) — events are an
   optimization; the fallback tick plus reconciliation is the guarantee, and
   the pump (v1) guarantees ticks continue when this session is gone.

**Scheduling rules (v1):** tasks touching dependency manifests are
serialized; unknown test environments run `testing`/`merging` serially;
`exclusive: true` demands solo execution. Worktrees isolate git state only —
never caches, ports, databases, or servers.

**Plan phase** (`orchid-plan`): the orchestrator drafts the roadmap from
`requirements.md` → `engines/codex` in critic mode attacks it → the
orchestrator revises → loop starts. No user gate.

**Context pack:** plan phase creates `.orchid/context.md` — a dense,
engine-neutral brief (stack, layout, conventions, hard rules, test/build
commands) injected into every implementer and reviewer prompt. Static after
planning; refreshed only by explicit `orchid-plan --refresh-context`
(automatic drift tracking deferred).

## Engine availability & role failover (v1)

Precise continuity promise: no state loss, eligible work continues, policy-
blocked work queues. Mechanisms:

**1. Engine-neutral orchestration (`PROTOCOL.md`).** The tick procedure is
one document in CLI verbs; the Claude skill follows it interactively,
`runners/orchid-tick` renders it for `claude -p` or `codex exec`. A handoff
moves nothing because there is nothing to move but files.

**2. Availability ledger + preference pairs.** `runtime/engines.json` records
per engine: last status, `rate_limited_until` (from `retry_after` or
exponential backoff probe), consecutive failures. Adapters update it via
spool events. Roles bind to primary→secondary pairs in `orchid.config`
(defaults: orchestrator claude→codex; implementer codex→claude; reviewer
per risk tier above; plan-critic: any engine that did not author the plan).
Model/effort is a static per-role default in v1; the risk×model matrix is
v1.x.

**3. Capability gate.** A fallback (engine, role) pair is enabled ONLY after
passing the role×engine capability suite: filesystem scope, network policy,
subprocess spawning, git operations, structured output, recovery behavior.
The Execution policy defines a per-role profile for every enabled pair —
an orchestrator profile is required before codex-as-orchestrator ships.
Until a pair passes, that fallback is disabled and the role queues instead.

**4. The pump (`runners/orchid-pump`).** An LLM-free shell heartbeat (spare
terminal in v1) that, when the orchestrator lease is stale, launches
`orchid-tick` on the first available capable orchestrator engine. No quota,
cannot be rate-limited. "Fable hit its cap at 3am" becomes "ticks quietly
ran on codex until the window reset."

**Independence under failover** follows the review-routing rules above,
enforced against the task's recorded implementer engine. High-risk
arbitration waits (bounded, default 4h, configurable) for the preferred
arbiter; low/medium proceeds on the fallback immediately.

**Honest caveat:** orchestration quality is not engine-symmetric; failover
trades judgment quality for continuity, deliberately, only during outages.

## Execution policy (the autonomy boundary)

Defined per enabled role×engine pair, enforced by adapters:

- **Implementer (codex):** worktree-only writes (`workspace-write`),
  `approval_policy=never` (can never stall on a prompt), env stripped to an
  allowlist, no secret-file reads, network disabled except declared
  dependency-install phases.
- **Orchestrator (claude interactive / claude -p):** repo + `.orchid/` scope,
  spawns tier-1 verbs, runners, and adapters; no external mutations. A codex
  orchestrator profile must be defined and capability-tested before that
  fallback is enabled.
- **Reviewers:** read-only (`codex exec review` sandboxed read-only; agy
  receives inline context, zero permissions).
- **External mutations are prohibited in v0/v1:** no `git push`, deploys,
  publishing, or production data changes — by any engine or the orchestrator.
  Tasks requiring one raise a blocker.
- `orchid.config` is parsed as key=value data, never shell-sourced.

## Guardrails & failure handling

- **Engine calls:** hard timeout (default 60 min), envelope status checks,
  one automatic retry, then escalation. **Infrastructure failures
  (`timeout`, `auth`, `rate_limited`, crash) increment `infra_failures`,
  never `attempts`** — rework attempts measure code quality, not machine
  weather. Three rework attempts → `blocked`; repeated infra failures →
  engine marked unavailable + task re-queued.
- **Rate limits:** `rate_limited` (with `retry_after`) marks the engine in
  the ledger; the task re-queues untouched; dispatch falls to the secondary
  (v1) or waits (v0). A limit window pauses an engine, never loses work.
- **Runaway protection:** ≤3 rework cycles, concurrency cap, reviewer
  stop-conditions, per-task wall-clock budget.
- **Blockers:** appended to `BLOCKERS.md` and pushed through `orchid notify`.
- **Isolation:** every task in its own worktree/branch under the Execution
  policy. A poisoned run is `git branch -D` plus auditable history.
- **Crash/restart:** `orchid-resume` runs doctor, takes the lock, reconciles
  manifests and spool. **v0/v1 recovery rule: never re-adopt an ambiguous
  process.** Job identity is attempt-ID + process-group + start-time; if a
  manifest's process cannot be positively identified, confirm termination
  (kill the recorded pgid if present), then relaunch cleanly. Session resume
  via recorded `session_id` is an optimization, never required.

## Stuck-agent detection

| Mode | Defense |
|---|---|
| Dead | liveness check (pgid + start-time identity) each `orchid jobs check` |
| Hung | deterministic stall detector: log mtime/size frozen ~10 min → kill, retry |
| Blocked on prompt | made impossible: `approval_policy=never` + never-prompt flags (agy verified to soft-deny and exit) |
| Spinning | deterministic heuristics FIRST (duplicate log lines, no new commits, size growth without progress markers); only on heuristic escalation does the orchestrator read the log tail and judge — LLM judgment is the escalation tier, not the per-tick default |

Mechanisms: write-ahead job manifests (attempt ID, engine, pgid, start-time,
session_id, worktree, base_sha, log_path) written before launch with a child
handshake marker after; reconciliation ticks that never trust notifications;
escalation ladder (stall → kill/retry; timeout 60 min → `infra_failures++`;
budget or 3 rework attempts → `blocked` via `orchid notify`). No task can
silently consume a day, and the orchestrator's token cost stays flat.

## Remote interaction (seam in v1, channel in v1.x)

Human answer latency is the throughput ceiling of an autonomous run. The
seam ships early; the channels later:

- **v0/v1 seam:** all user-facing questions flow through `orchid notify`
  (default: `BLOCKERS.md` + terminal). Questions carry a question-ID and are
  multiple-choice where possible. Answers enter via `orchid answer
  <question-id> <choice>` — idempotent, expiring, recorded to
  `runtime/answers/` and consumed by the next tick.
- **v1.x channel:** OpenClaw as preferred transport (outbound
  `openclaw message`, inbound via its webhook triggers calling
  `orchid answer` with an opaque nonce, sender/channel allowlist, expiry;
  the adapter gets NO general shell or repo access). Hand-rolled Telegram
  bot as fallback. An unanswered question is just a blocked task.
- **Non-goal:** native phone app; status is `orchid status` (and later a
  static page).

## Verification findings (2026-07-24, empirical)

- `codex exec --sandbox read-only "<prompt>"` works headless: 3.6 s
  round-trip, token usage reported. `codex exec resume` and
  `codex exec review` subcommands exist.
- `agy -p "<prompt>"` works headless: 3.8 s. **Gotcha:** all flags must come
  BEFORE `-p`; flags between `-p` and the prompt mangle parsing.
- `agy models`: gemini-3.6-flash tiers, gemini-3.5-flash tiers,
  gemini-3.1-pro (high/low), claude-sonnet-4-6, claude-opus-4-6-thinking,
  gpt-oss-120b-medium.
- **agy headless permissions:** confirmation-requiring tools are auto-denied
  in print mode; allow-rules in `~/.gemini/antigravity-cli/settings.json`
  (`permissions.allow`), `command(<target>)` rules load but did not match the
  `Bash` tool; settings are normalized on load. Blanket `Bash` allow /
  `--dangerously-skip-permissions` deliberately NOT configured.
- **Verified workaround:** inline-diff review with zero permissions returns
  correct structured verdicts. Test whether `agy -p` accepts stdin (lifts
  ARG_MAX) during v0.
- **To verify in v0/v1 (not yet tested):** `claude -p` executing a full tick;
  `codex exec` orchestrating (subprocess spawning + git ops under sandbox —
  the capability suite exists precisely because this is unproven);
  `codex exec review` accepting an explicit `base..head` range (else the
  adapter falls back to plain `codex exec` with a review prompt);
  `git range-diff` triviality detection for post-rebase review reuse.
- **Design reviews:** round 1 (codex 10 findings, agy 8) and round 2 (codex
  10, agy 9, internal 5) incorporated: three-tier CLI with event spool and
  single-writer reconciliation, portable lock + heartbeat lease,
  runtime/durable state split, verify/merge owning verbs with
  rebase-then-reverify, attempt-ID job identity without ambiguous
  re-adoption, infra-vs-rework failure accounting, per-archetype transition
  tables, session-vs-engine independence with degraded two-engine labeling,
  deterministic-first stall detection, staged delivery. Rejected across
  rounds: polling-only loop (background notifications verified working);
  cutting the pump/failover entirely (staged and capability-gated instead —
  they are the user's core continuity requirement).

## Distribution (public GitHub repo)

- Repository `orchid` under the author's personal GitHub account, created
  **private** at implementation start; flipped **public** at the end of
  stage v1, after dogfooding produces real screenshots. The first public
  state must be presentable AND true.
- **License:** MIT.
- **README** is a first-class deliverable (written at end of v1): hero pitch
  + screenshot; how-it-works Mermaid diagram + one task's journey; why this
  design (subscription billing, no daemon, git as truth); prerequisites &
  subscription matrix — framed as "any engine, any role": the role
  capability table, the tested default combo (Claude+Codex+Antigravity full
  triangle; Claude+Codex labeled "degraded independence"), and the adapter
  contract for wiring in ANY other CLI or API-only model, with a worked
  example of swapping `role.orchestrator`; install (`git clone` + `./install.sh`, PATH setup, uninstall);
  quickstart walkthroughs (existing-repo and greenfield) with screenshots;
  state files, guardrails, and intervention (via CLI verbs);
  **Extending orchid** — the five extension points, the named patterns
  glossary, and "write your first engine adapter in under an hour" pointing
  at `docs/extending/` (one guide per plugin kind, each built around a real
  reference plugin); FAQ; **Research & further reading** — attributed citations: Google's "The New SDLC With
  Vibe Coding" whitepaper (factory model, harness engineering, trajectory
  evaluation, model routing), the METR productivity study, Karpathy's
  vibe-coding/agentic-engineering framing, and future sources as they inform
  the design.
- **Screenshots:** `docs/assets/`, captured during v1 dogfood runs (loop
  mid-run, roadmap/tasks, arbitration verdict, finished-run diff summary);
  refreshed when visible behavior changes.
- **Commit hygiene:** history starts clean at publication; no AI co-author
  trailers; no personal paths or secrets — binaries from `PATH`, config from
  env/`orchid.config`.
- **Generalization:** nothing assumes the author's machine; `$HOME` only;
  engine defaults overridable via `orchid.config`.

## Future (explicitly deferred beyond v1.x)

- Service packaging: `orchid-pump` under launchd/cron (survive reboots).
- Static mobile-readable status page.
- Usage/cost ledger, if observability outgrows `git log`.
- Per-task engine routing beyond role preference pairs.
- Task resource declarations beyond `exclusive` (ports, databases,
  containers) with automatic allocation.
- Chunk-and-aggregate for oversized inline reviews.
