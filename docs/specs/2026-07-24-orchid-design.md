# Orchid — Design Spec (v4)

**Date:** 2026-07-25 (v1 2026-07-24)
**Status:** Approved through three external review rounds (codex + agy) plus
internal audits; v4 reconciles the round-3 three-way audit; pending user
review. Plan redo follows user approval.

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

Honestly stated, the kernel is a small **file-based workflow scheduler**:
deterministic CLI verbs plus stateless LLM ticks over git state. Design
principles: no daemon, no dashboard, no terminal emulation, no persistent
runtime process. Engines are driven through their first-party headless modes,
so billing stays on each vendor's subscription. All durable state is files in
git — sessions are disposable; the files are the truth.

**Platforms:** macOS and Linux (bash 3.2+, git, jq); Windows via WSL2.

## Requirements (from design sessions)

- **Run model:** semi-attended. An interactive Claude Code session is the
  primary surface; the machine stays awake. The LLM-free pump plus headless
  `orchid-tick` (v1) keep the run advancing when the interactive session is
  rate-limited or closed; service packaging (survive reboots) is deferred.
- **Scope:** existing repos first (v0); greenfield products (v1).
- **Engine roles:** fully configurable via `role.*` keys from v0; orchid
  never hard-codes an engine to a role and kernel code never branches on a
  plugin's name. v0 ships and TESTS the default bindings; non-default
  bindings are supported-but-unverified (labeled by doctor) until the
  capability suite (v1) passes them.
- **Autonomy:** fully autonomous — no user approval gates; only genuine
  blockers surface, bounded by the Execution policy. **Continuity promise
  (precise):** a single engine outage never loses state and never stops
  eligible work; work whose policy requires an unavailable engine queues
  until that engine's window reopens. With failover enabled (v1),
  orchestration itself continues on a fallback engine.
- **Distribution:** public GitHub repository for general benefit; public
  only after dogfooding (see Distribution).
- **Non-goals (all stages):** daemon/service, web UI, cost ledger,
  multi-user, cross-machine operation, chat-style inter-agent messaging,
  native phone app, central plugin registry (provenance and pinning are
  required; a registry is not). Orchid never builds ON agent runtimes
  (OpenClaw, Hermes) — they plug in as engines or notify channels only.

## Delivery stages

- **v0 — vertical slice:** one existing repo, ONE active task at a time,
  default role bindings, `feature` archetype only, CLI kernel verbs,
  deterministic verify/merge, crash recovery (no PID re-adoption), manual
  resume. The plugin seam ships FINAL-SHAPED in v0: the real
  `ORCHID_PLUGIN_PATH` layout, one role→engine resolver used by doctor,
  jobs, and PROTOCOL alike, launch-by-role, and a fake non-default-binding
  test proving no engine name is hard-coded. Repo-local plugins DISABLED (no
  trust store yet). Manifest validation minimal (existence + executable).
- **v1 — the full delivery**, built in four dependency-ordered milestones,
  ending in public release:
  - **v1-m1 (core autonomy):** pump + failover (capability-suite gated),
    concurrency 2 with the rebase/re-review rules below, risk-tiered dual
    review, greenfield mode, `review` archetype.
  - **v1-m2 (plugin platform):** full manifest schema, `orchid plugins
    list/validate/trust/install/update/remove/test/audit`, conformance kit,
    plugin lockfile, kernel launcher hygiene.
  - **v1-m3 (SDLC suite):** hooks + role registry;
    `refactor`/`test`/`migrate` archetypes with their ecosystem tooling
    adapters.
  - **v1-m4 (ecosystem):** OpenClaw notify channel + orchid AgentSkill,
    Hermes engine adapter (reviewer role first), API-backed Kimi reviewer,
    Perplexity `researcher` role — each doubling as a `docs/extending/`
    tutorial; cost/risk routing matrix; static status page; service
    packaging (launchd/cron pump). Escape hatch: third-party upstream churn
    can delay an individual adapter, never the launch.
  - **Release gate:** README + screenshots from real dogfood runs, then
    **public release**. Extension guides reference plugins that actually
    shipped (never promise unshipped references).

## Architecture

Two locations; strict split between tooling (global) and run state (per
target repo).

### Tool repo layout

```
PROTOCOL.md                 # engine-neutral tick procedure — KERNEL-OWNED,
                            #   written in CLI verbs; plugins never edit it
skills/                     # the CLAUDE front-end for the orchestrator role —
  orchid/SKILL.md           #   one of several front-ends, not the architecture.
  orchid-plan/SKILL.md      #   Front-ends are a CONVENTION (anything that
  orchid-resume/SKILL.md    #   executes PROTOCOL.md via verbs), not a
  orchid-review/SKILL.md    #   discovered plugin kind. (review skill: v1)
bin/
  orchid                    # THE CLI: git-style dispatcher
libexec/                    # TIER 1 — deterministic verbs. Never invoke an
  orchid-doctor             #   LLM, never block on the network. Sole mutators
  orchid-init               #   of durable state.
  orchid-task               #   create/show/list/set/advance/unblock/retry
  orchid-verify             #   deterministic verification + evidence
  orchid-merge              #   transactional merge
  orchid-jobs               #   launch/check/reconcile (kernel launcher)
  orchid-plugins            #   full lifecycle verbs (v1-m2)
  orchid-status             #   task + run-level status
  orchid-notify             #   user questions out
  orchid-answer             #   user answers in (idempotent)
runners/                    # TIER 2 — effectful: launch LLM sessions.
  orchid-tick  orchid-pump  #   Outside the determinism boundary. (pump: v1)
plugins/                    # TIER 3 — the BUILT-IN plugin set, discovered via
  engines/codex/            #   the same path and contracts as third-party
  engines/agy/              #   plugins. Engine adapters write ONLY to the
  engines/claude/           #   runtime spool, never durable state.
  archetypes/feature/
templates/  install.sh  docs/specs/  docs/extending/  README.md  LICENSE
```

**The determinism boundary (hard rule, tier 1 only):** `libexec/` verbs are
deterministic plumbing — verbs over files, no LLM calls, no daemon, no
database, no message routing. Runners and engines are effectful and named as
such; they hold no orchestration logic.

**Single-writer rule:** durable state is mutated ONLY through tier-1 verbs,
ONLY by the process holding the run lock. Engines, runners, hooks, and
custom roles produce results exclusively as spool envelopes; the tick applies
them through verbs. Human intervention also uses verbs (`orchid task
unblock/retry/set`), never hand-edits.

### Run state: `<target-repo>/.orchid/`

```
# committed (durable, on the integration branch only):
requirements.md  roadmap.md  baseline.md  context.md
tasks/T001.md ...           # frontmatter + body; state machine lives here
reviews/ ...                # envelopes (renamed from spool), verify/merge logs
plugins.lock                # v1: resolved plugin identities for this run
                            #   (id, version, digest, source, contract,
                            #   capability-test result) — a run's behavior
                            #   never silently changes because a plugin did
BLOCKERS.md

# runtime/ (gitignored — machine-local, volatile):
lock/                       # mkdir lock; contains owner.json (pid, hostname,
                            #   created_at). Tier-1 verbs BREAK a lock whose
                            #   pid is dead or whose age exceeds 60s past
                            #   lease staleness — no permanent deadlock after
                            #   SIGKILL.
lease.json                  # orchestrator heartbeat lease
jobs/<job_id>.json          # write-ahead manifests, keyed by JOB (not task):
                            #   parallel reviewers never collide
spool/                      # engine result envelopes awaiting reconciliation
engines.json                # availability ledger (per-machine quota state)
answers/  logs/
```

**Bootstrap (existing repo):** `orchid doctor` → `orchid init` creates the
integration branch from the default-branch HEAD and commits `.orchid/` there.
User branches are never touched. **Greenfield (v1):** `orchid-plan` makes a
root commit before any worktree exists (`git worktree add` needs a HEAD);
scaffolding is T001; `orchid doctor --greenfield` skips checks that cannot
apply pre-scaffold. **Scaffold verification:** tasks flagged
`archetype: feature, scaffold: true` may use structural assertions (files
exist, manifest parses, build command exits 0) as `verification_commands` —
resolving the bootstrap paradox of testing a test-runner that doesn't exist
yet.

**Worktree contamination guard:** task worktrees get `.orchid/` appended to
`.git/info/exclude`, implementer prompts forbid touching it, and
`orchid task advance` REFUSES entry to `testing` while any commit in
`base_sha..candidate_sha` touches `.orchid/` paths (the orchestrator strips
such commits and re-verifies). State corruption via task branches is
structurally impossible.

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

**Engine invocation — the request document.** `orchid jobs launch` invokes
`<plugin>/run <request.json>` where the request contains:

```json
{ "request": 1, "job_id": "j-<nonce>", "task": "T001", "attempt": 3,
  "role": "reviewer", "operation": "review",
  "base_sha": "...", "candidate_sha": "...",
  "worktree": "<abs path>", "context": "<abs path to context.md>",
  "task_file": "<abs path>", "output": "<abs path in spool>",
  "deadline_s": 3600, "policy": "read-only|workspace-write",
  "model": "...", "effort": "medium" }
```

One adapter can serve many roles by branching on `operation`
(implement/review/critique/research) — no pseudo-engine identities. Adapters
never guess paths, never choose their own output location, and exit nonzero
on any failure they can detect.

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

**Binding rules (anti-forgery):** `job_id` is kernel-minted per launch
(distinct from the logical rework `attempt`); reconciliation accepts an
envelope ONLY if a live manifest matches its `job_id`, and takes engine
identity, role, task, and SHAs from the MANIFEST, cross-checking the
envelope; any mismatch, replay (already-reconciled job_id), oversize, or
schema violation → quarantine, never acceptance. Status-specific
requirements: a reviewer `ok` without `verdict` and `scope_complete` is
malformed. "Tests pass" is established solely by `orchid verify`, never by
envelope claims (engine trajectories are diagnostics).

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

## Threat model (consolidated)

| Untrusted input | Boundary | Mitigation |
|---|---|---|
| cloned repo content (incl. `.orchid/plugins/`) | plugin discovery | repo-local disabled by default; digest-pinned trust records outside the repo; no silent shadowing |
| plugin executables | trust decision at install | trusted-code classification (stated plainly); launcher hygiene; containment roadmap post-v1 |
| engine output (envelopes) | reconciliation | job_id binding to manifests; schema fail-closed; quarantine on mismatch/replay |
| task/diff content in prompts | reviewer/arbiter judgment | prompt injection is assumed possible; verdicts are advisory to the arbiter, which reads high-risk diffs itself; verification is deterministic and immune to prompt content (`orchid verify`) |
| inbound answers | `orchid answer` | question-id + idempotency; channel adapters get no shell/repo access; nonce + sender allowlist when remote channels ship (v1-m4) |
| implementer commits | merge path | worktree contamination guard; review immutability; transactional merge |

## Preflight (`orchid doctor`)

Read-only; fails safely. Validates: git topology, worktree support, jq,
plugin discovery report (origin/trust/collisions), every `role.*` binding
resolving to a discovered plugin whose capabilities satisfy the role
descriptor (labeled `unverified` until the v1 capability suite passes it),
engine binaries/auth (cheap no-op probes derived from resolved adapters —
not a separate `engines=` list), explicit verification commands (or
`--greenfield`), integration branch creatable, platform supported.

## Task lifecycle

Feature-archetype table (others declare subsets within kernel invariants):

```
pending → implementing → testing → reviewing → arbitrating → merging → done
                ↑            │         │            │
                └── rework (≤3) ───────┴────────────┤
                                                    └→ blocked
```

- **testing** = `orchid verify <id>`: runs `verification_commands` in the
  task worktree; records evidence (command, cwd, SHA, timestamps, exit
  codes, log digest). Sole acceptance authority for tests.
- **merging** = `orchid merge <id>`: serialized, transactional. **Rebase
  rule (hardened, round 3):** if integration HEAD ≠ `base_sha`, the
  candidate is rebased onto HEAD and then UNCONDITIONALLY re-verified — a
  textually clean rebase is not semantically safe against parallel changes.
  Reviews are invalidated and re-run as a delta review (reviewers receive
  the range-diff and the new base) — full re-review if the delta is
  non-trivial. Only then: merge in a temp worktree, run the suite, advance
  the integration ref on pass; `validation_failed` returns that exact
  candidate to rework with logs. **v0 baseline semantics:** the suite must
  pass, full stop; `baseline.md` records pre-existing failures for humans.
  Baseline-aware comparison is post-v1.
- **Attempt fairness:** `attempts` increments on verify-FAIL or arbitration
  rejection. If a rework's failure/finding signature is DISJOINT from the
  previous attempt's (distinct forward progress, e.g. new review nits after
  fixing prior ones), the orchestrator may decline to count it; the ≤3 cap
  targets repeated identical failures. The per-task wall-clock budget is the
  unconditional backstop. `infra_failures` (timeout/auth/rate_limited/crash)
  NEVER consume attempts.

Frontmatter: `id, title, status, archetype, scaffold, branch, worktree,
depends_on, attempts, infra_failures, session_id, base_sha, candidate_sha,
risk_threshold, stop_condition, engine, effort, acceptance_criteria,
verification_commands, resources, created, updated`.

**Review immutability:** reviewers inspect exactly `base_sha..candidate_sha`;
any candidate change invalidates reviews (see rebase rule). Incomplete or
malformed review NEVER counts as approval.

**Independence:** *session independence* (fresh session, same engine) vs
*engine independence* (different vendor). Risk-tiered routing: `low` →
single engine-independent reviewer (default agy inline; fallback
codex-review when unavailable or over inline budget); `medium`/`high` → dual
review (worktree-capable reviewer for depth + engine-independent reviewer
for diversity). **Inline-review blind-spot guard:** inline prompts include
an input manifest (all changed files + omissions) AND the changed-symbol
list; the orchestrator upgrades routing to a worktree-capable reviewer when
changed symbols are referenced in un-diffed files. Two-engine installs are
labeled "degraded independence": medium accepts session independence; high
queues for engine independence. Risk is assigned at plan time; upgradable,
never downgradable.

**Arbitration:** findings below the task's risk threshold never block;
reviewer agreement is strong signal; on disagreement the orchestrator reads
the diff and decides. The orchestrator implements nothing beyond ≤ ~10-line
arbitration trivia.

**Acceptance:** requirement IDs at plan time; roadmap keeps the
requirement→task coverage map; run-level status lives in roadmap frontmatter
(`run_status: planning|running|accepting|complete|blocked`); the final
acceptance gate (coverage check + end-to-end acceptance tests) writes an
evidence record to `reviews/acceptance.log` before `run_status: complete`.
`orchid status` shows task table, jobs, open questions, AND run-level state.

## The loop

The orchestrating session executes PROTOCOL.md under the run lock each tick:
reconcile spool → advance tasks → launch by ROLE via the resolver (never by
engine name) up to the concurrency cap (v0: 1; v1: 2 + scheduling rules) →
`orchid merge` at most one candidate → commit durable state → refresh lease
→ sleep with fallback wakeup. Events (background-task notifications) are an
optimization; reconciliation is the guarantee; the pump (v1) guarantees
ticks outlive the session.

**Scheduling rules (v1):** dependency-manifest tasks serialize; unknown test
environments run `testing`/`merging` serially; `exclusive: true` and
`resources:` declarations (ports, dbs) gate parallelism — worktrees isolate
git state only, never caches/ports/servers.

**Plan phase** (`orchid-plan`): draft roadmap from requirements → the
resolved `role.plan_critic` engine critiques (never the drafting engine) →
revise → loop. **Context pack:** `.orchid/context.md` created at plan time,
injected into every request document; static until explicit
`--refresh-context`.

## Engine availability & role failover (v1)

Ledger (`runtime/engines.json`: last status, `rate_limited_until`,
consecutive failures — updated via spool events) + primary→secondary
preference pairs per role in `orchid.config` + the capability gate: a
fallback (engine, role) pair activates ONLY after passing the role×engine
capability suite (filesystem scope, network policy, subprocess, git,
structured output, recovery). The pump: LLM-free heartbeat that launches
`orchid-tick` on the best available capable orchestrator engine when the
lease is stale (>15 min); mutual exclusion via lease staleness, not flock.
Independence rules above apply against the task's recorded implementer.
High-risk arbitration waits (bounded, default 4h) for the preferred arbiter.
Model/effort: static per-role defaults in v1; risk×model matrix v1-m4.

## Execution policy (the autonomy boundary)

Per enabled role×engine pair, enforced by the kernel launcher (env
allowlist, stdin `/dev/null`, private output path) plus vendor-CLI sandbox
flags: implementer worktree-write + `approval_policy=never` + no secrets +
network only in declared install phases; reviewers read-only; orchestrator
repo+`.orchid/` scope. **External mutations prohibited in v0/v1** (no push,
deploy, publish, prod-data) — blockers instead. `orchid.config` and
`plugin.conf` are parsed data, never sourced.

## Guardrails & failure handling

- Engine calls: deadline in the request (default 60 min), envelope checks,
  one auto-retry, then `infra_failures++` or rework per Attempt fairness;
  3 rework attempts → `blocked`; repeated infra failures → engine marked
  unavailable, task re-queued.
- Rate limits: ledger-marked; task re-queues untouched; dispatch falls to
  the secondary (v1) or waits (v0). A window pauses an engine, never work.
- Runaway: rework cap, concurrency cap, reviewer stop-conditions, per-task
  wall-clock budget.
- Blockers: `BLOCKERS.md` + `orchid notify`. **Operator verbs:** `orchid
  task unblock <id> [--guidance "..."]` and `orchid task retry <id>` —
  validated transitions, guidance recorded into the task body, intervention
  logged in the audit trail. No hand-editing needed, ever.
- Crash/restart: `orchid-resume` = doctor → break stale lock if owner dead →
  reconcile manifests/spool. Never re-adopt ambiguous processes: job
  identity is job_id + pgid + start-time; unidentifiable → confirm
  termination, relaunch cleanly. Session resume is an optimization.

## Stuck-agent detection

| Mode | Defense |
|---|---|
| Dead | pgid + start-time liveness per `orchid jobs check` |
| Hung | stall: log mtime/size frozen ~10 min → kill, retry |
| Blocked on prompt | structurally impossible: launcher stdin `/dev/null` + `approval_policy=never` + never-prompt flags |
| Spinning | deterministic FIRST: duplicate log lines, no new commits, keep-alive-only output (progress-marker check, not just mtime); LLM log-tail judgment is the ESCALATION tier |

Write-ahead manifests keyed by job_id (task, attempt, role, engine id +
digest, pgid, start-time, session_id, worktree, base_sha, log) with child
handshake marker; reconciliation never trusts notifications; escalation
ladder bounded by wall-clock budget; orchestrator token cost stays flat.

## Remote interaction

- **v0/v1 seam:** `orchid notify` (question-id minted by the kernel,
  multiple-choice preferred) → `BLOCKERS.md` + terminal; `orchid answer
  <qid> <choice>` — idempotent, expiring, consumed by the next tick.
- **v1-m4 channels:** OpenClaw preferred transport (outbound `openclaw
  message`; inbound webhook → `orchid answer` with opaque nonce, sender
  allowlist, expiry; adapter gets NO shell/repo access); Telegram fallback.
- Non-goal: native app. `orchid status` (later a static page) is the
  read surface.

## Operator walkthrough (the human's seat)

1. `orchid doctor` — readiness + plugin/trust report.
2. Write `.orchid/requirements.md`; set `orchid.config` (verify command,
   role bindings if non-default). `orchid init`.
3. Start the orchestrator front-end (Claude session → `/orchid-plan`,
   or any front-end executing PROTOCOL.md).
4. Walk away. Check `orchid status` anytime; answer questions via
   `orchid answer`; intervene via `orchid task unblock/retry/set`.
5. Run ends at `run_status: complete` (acceptance evidence in
   `reviews/acceptance.log`) or surfaces a blocker. Integration branch holds
   the product; pushing/deploying is yours.

## Verification findings (empirical)

- `codex exec` headless verified (3.6 s; resume + review subcommands exist).
- `agy -p` headless verified (3.8 s; ALL flags before `-p`; print-mode
  auto-denies tools → inline-diff review verified working with zero
  permissions; stdin acceptance untested — test in v0).
- agy models list includes gemini flash/pro tiers + claude + gpt-oss.
- **To verify in v0/v1:** `claude -p` full tick; codex-as-orchestrator
  subprocess/git under sandbox (capability suite exists because this is
  unproven); `codex exec review` explicit range support (fallback: plain
  exec with review prompt); range-diff triviality detection.
- **Review history:** round 1 (codex 10, agy 8), round 2 (codex 10, agy 9,
  internal 5), round 3 three-way (codex 10 incl. 3 critical, agy focused 9 +
  agy comprehensive 10 incl. 1 critical, internal 10). v4 incorporates:
  plugin trust model, kernel launcher, request/envelope binding,
  capability-based role resolution, archetype meta-invariants, kernel-owned
  hooks, unconditional rebase re-verification, stale-lock recovery, worktree
  contamination guard, operator verbs, scaffold verification, attempt
  fairness, threat model, plugin lockfile, platform statement. Rejected with
  rationale: OS-level plugin containment in v1 (declared trusted-code
  instead, containment roadmapped); central plugin registry (provenance +
  pinning without a registry); polling-only loop (round 1, still rejected).

## Distribution (public GitHub repo)

Private at implementation start; public at end of v1 after dogfooding
produces real screenshots. MIT. README: hero + screenshot; how-it-works
diagram + one task's journey; why this design; **any engine, any role**
matrix (capability table, tested defaults, degraded-independence labeling,
worked `role.*` swap example); install/uninstall; quickstarts (existing +
greenfield) with screenshots; state files, guardrails, operator verbs;
**Extending orchid** (five extension points, patterns glossary, "first
adapter in under an hour" against `docs/extending/` guides — referencing
built-ins until the v1-m4 reference plugins ship); FAQ; **Research & further
reading** (attributed: Google's "The New SDLC With Vibe Coding" whitepaper,
METR study, Karpathy's framing, and successors). CONTRIBUTING.md + a
community plugin listing section (awesome-orchid) at public launch. Commit
hygiene: clean history, no AI trailers, no personal paths, `$HOME`/`PATH`
resolution only.

**Ecosystem piggyback strategy (launch checklist):** ride the distribution
of adjacent popular projects rather than competing with them —
1. Launch README headline: "Works with OpenClaw · Hermes · Claude Code ·
   Codex · Antigravity" (compatibility wording only; never imply
   endorsement or partnership).
2. Publish the **orchid AgentSkill into OpenClaw's skill ecosystem** —
   status queries and blocker answers from WhatsApp/Telegram — so orchid is
   discoverable where OpenClaw's own users browse; hero demo:
   "requirements sent from your phone in the morning; OpenClaw pings you
   the finished diff summary by evening."
3. Hermes-side listing: an example integration contributed to their
   community docs; Hermes ships as the first non-default engine adapter.
4. GitHub topics (`openclaw`, `hermes-agent`, `multi-agent`,
   `ai-orchestration`) + PRs to the relevant awesome-lists.
5. Rule: integrations are optional dependencies — upstream churn can delay
   an adapter, never the launch.

## Future (beyond v1)

Service packaging (launchd/cron pump) · static status page · usage/cost
ledger · per-task engine routing · resource auto-allocation ·
chunk-and-aggregate inline reviews · OS-level plugin containment profiles.
