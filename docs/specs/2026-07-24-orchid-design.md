# Orchid — Design Spec (v5)

**Date:** 2026-07-25 (v1 2026-07-24)
**Status:** Approved through three external review rounds (codex + agy) plus
internal audits; v5 reconciles the round-4 three-way audit; pending user
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
  `orchid-tick` (v1-m2) keep the run advancing when the interactive session
  is rate-limited or closed; service packaging ships in v1-m4.
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
- **Non-goals (all stages):** HOSTED or dynamic services (a locally
  generated static status page and launchd/cron packaging of the pump are
  in scope; a server is not), web app UI, usage/cost ledger, multi-user,
  cross-machine operation, chat-style inter-agent messaging, native phone
  app, central plugin registry (provenance and pinning are required; a
  registry is not). Orchid never builds ON agent runtimes (OpenClaw,
  Hermes) — they plug in as engines or notify channels only.

## Delivery stages

- **v0 — vertical slice:** one existing repo, ONE active task at a time,
  default role bindings, `feature` archetype only, CLI kernel verbs,
  deterministic verify/merge, crash recovery (no PID re-adoption), manual
  resume. The plugin seam ships FINAL-SHAPED in v0: the real
  `ORCHID_PLUGIN_PATH` layout, one role→engine resolver used by doctor,
  jobs, and PROTOCOL alike, launch-by-role, and a fake non-default-binding
  test proving no engine name is hard-coded. Repo-local plugins DISABLED (no
  trust store yet). Manifest validation minimal (existence + executable).
- **v1 — the full delivery**, in four milestones whose order follows the
  dependency graph (round-4 consensus fix: platform foundations BEFORE the
  features gated on them):
  - **v1-m1 (plugin & role foundation):** minimal manifest schema with
    capability declarations, core role DESCRIPTORS (the five built-in roles
    formalized — required in spirit since v0), the pinned resolver, plugin
    lockfile, kernel launcher hygiene, the role×engine capability-suite
    runner, `orchid plugins list/validate/trust`.
  - **v1-m2 (core autonomy):** pump + failover (now actually gateable on
    m1's capability suite), concurrency 2 with the rebase/re-review rules,
    risk-tiered dual review, greenfield mode, `review` archetype.
  - **v1-m3 (SDLC suite + custom extensibility):** hooks; CUSTOM role
    registration opens (core registry existed since m1);
    `refactor`/`test`/`migrate` archetypes with their tooling adapters;
    third-party plugin lifecycle UX (`install/update/remove/test/audit`) +
    distributable conformance kit.
  - **v1-m4 (ecosystem + polish):** split into release-blocking core —
    static status page, service packaging (launchd/cron pump), Homebrew
    tap, full docs suite — and CONDITIONAL reference adapters (OpenClaw
    channel + AgentSkill, Hermes, Kimi reviewer, Perplexity researcher):
    upstream churn may drop an individual adapter from launch, and any
    dropped adapter automatically disappears from the README headline,
    compatibility matrix, and tutorial list. The escape hatch never waives
    a core conformance gate.
  - **Release checklist (binary, no judgment calls at the gate):** all
    m1–m3 conformance suites green; m4 core complete; docs suite passes the
    15-minute clean-machine rehearsal; screenshots from real dogfood runs;
    works-with claims match actually-shipped adapters; THEN public release.

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
libexec/                    # TIER 1 — deterministic verbs: state transitions
  orchid-doctor             #   only. Never invoke an LLM, never block on the
  orchid-init               #   network, never spawn long-lived processes.
  orchid-run                #   start/resume/advance/accept/new — epochs, runs
  orchid-task               #   create/show/list/set/advance/unblock/retry
  orchid-requirements       #   import (operator-owned exception)
  orchid-plan               #   apply/refresh-context (atomic transactions)
  orchid-verify             #   deterministic verification + evidence
  orchid-merge              #   transactional merge (never triggers reviews)
  orchid-jobs               #   prepare/check/reconcile (NOT launch — tier 2)
  orchid-plugins            #   list/validate/trust (v1-m1); lifecycle (v1-m3)
  orchid-journal            #   add/tail/show — decision journal
  orchid-lessons            #   add/update/retire/consolidate (v1)
  orchid-config             #   list effective config with per-key provenance
  orchid-status             #   task + run-level status
  orchid-notify             #   user questions out
  orchid-answer             #   user answers in (idempotent inbox)
runners/                    # TIER 2 — effectful: launch processes.
  orchid-launch             #   the kernel launcher: spawns engine adapters
  orchid-tick  orchid-pump  #   headless tick; LLM-free heartbeat (v1-m2)
plugins/                    # TIER 3 — the BUILT-IN plugin set, discovered via
  engines/codex/            #   the same path and contracts as third-party
  engines/agy/              #   plugins. Engine adapters write ONLY to the
  engines/claude/           #   runtime spool, never durable state.
  archetypes/feature/
templates/  install.sh  docs/specs/  docs/extending/  README.md  LICENSE
```

**The determinism boundary (hard rule, tier 1 only):** `libexec/` verbs are
deterministic plumbing — state transitions over files: no LLM calls, no
daemon, no database, no message routing, and — round-4 fix — **no spawning
of long-lived processes.** `orchid jobs launch` is therefore reclassified:
the CLI keeps the ergonomic entry point, but it delegates to the tier-2
launcher (`runners/orchid-launch`), and is documented as effectful. Tier-1
`orchid jobs` retains only `prepare` (mint job_id, write manifest), `check`,
and `reconcile`.

**The normative process model (who runs, who authorizes):**

1. A run has a monotonic **epoch**. `orchid run start|resume` (tier 1)
   increments the epoch, fences out stale processes, and records the
   orchestrating front-end.
2. The orchestrating engine is either operator-started (the interactive
   session — the ONE process the kernel does not launch; this privilege
   exception is explicit, and its authority derives from holding the
   current lease, not from how it was started) or kernel-launched by the
   pump (`orchid-tick`).
3. The orchestrator holds the **lease** (identity + epoch, refreshed per
   turn). Individual verb invocations are separate short-lived processes:
   each takes the mkdir lock for its own transaction and validates
   `ORCHID_EPOCH` (passed by the orchestrator, minted at `run
   start/resume`). A verb bearing a stale epoch refuses to run — fencing,
   so a zombie orchestrator from before a crash can never mutate state.
4. Engines are launched ONLY by the tier-2 launcher, which writes the
   manifest via tier-1 `jobs prepare` first. Engines never spawn engines.

**Single-writer rule with a complete ownership table** — every durable file
has exactly one writing verb; anything not listed is read-only for everyone:

| File | Sole writer (verb) |
|---|---|
| `tasks/*.md` | `orchid task create/set/advance/unblock/retry` |
| `roadmap.md` | `orchid plan apply` (atomic roadmap+tasks transaction), `orchid run advance/accept` (run_status) |
| `requirements.md` | `orchid requirements import <file>` — the operator-owned EXCEPTION: authored by hand anywhere, imported by verb, immutable after plan |
| `context.md` | `orchid plan apply` / `orchid plan refresh-context` |
| `journal.md` | `orchid journal add` (also auto-written by reason-bearing verbs) |
| `lessons.md` | `orchid lessons add/update/retire/consolidate` |
| `baseline.md` | `orchid init` |
| `reviews/*` | `orchid jobs reconcile` (envelopes), `orchid verify`/`orchid merge` (evidence), `orchid run accept` (acceptance) |
| `plugins.lock` | `orchid plugins lock` |
| `BLOCKERS.md` | `orchid notify` |

Task/run schemas are versioned (`schema: 1` in frontmatter) and include the
scheduling and budget fields the loop relies on: `exclusive`, `resources`,
`wallclock_budget_s`, `started_at`, `run_id`.

### Run state: `<target-repo>/.orchid/`

```
# committed (durable, on the integration branch only):
requirements.md  roadmap.md  baseline.md  context.md
tasks/T001.md ...           # frontmatter + body; state machine lives here
reviews/ ...                # envelopes (renamed from spool), verify/merge logs
journal.md                  # v0: append-only decision journal (see Memory)
lessons.md                  # v1: cross-run repo lessons (see Memory)
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
the injection table), with a `pack.json` manifest listing every artifact,
its byte count and digest, and everything OMITTED for budget. Budgets are
concrete: 64 KB total default (per-role overridable); correctness-critical
inputs (task body, acceptance criteria, the diff for reviews) are
NON-TRUNCATABLE — if they alone exceed budget, the launch fails with
`input_overflow` rather than silently truncating; journal/lessons/context
trim in that order (journal tail-first, context head-first), and every trim
is recorded in the manifest. **Visibility honesty:** worktree-capable
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

## Installation & configuration

### Install

`git clone` + `./install.sh`, which does exactly and only: symlink `skills/`
into `~/.claude/skills/`; link `bin/orchid` into `~/.local/bin` (or
`$ORCHID_BIN_DIR`), warning if that dir is not on `PATH`; create
`~/.orchid/{plugins,trust}` and a commented `~/.orchid/config`; finish by
running `orchid doctor` so the user's first output is a readiness report.
`./install.sh --uninstall` removes precisely those symlinks/dirs (config and
trust are left with a note). At public launch additionally: a pinned
`curl -fsSL … | bash` one-liner (fetching the same install.sh) and a
Homebrew tap (v1-m4) — install must feel first-class on a Mac.

### Connecting the CLIs (per-engine setup)

Orchid never manages vendor auth — each CLI's own login is the source of
truth. The flow is doctor-driven: `orchid doctor` names each configured
engine's missing binary or failed auth probe and points at
`docs/engines/<name>.md` — one guide per built-in engine covering: install
command, subscription login command, the sandbox/approval flags orchid uses
and why, verified CLI versions (from the capability suite), and known
gotchas (e.g. agy's flags-before-`-p` rule, print-mode permission
auto-denial). Adding a new engine = adapter + its `docs/engines/` guide;
the conformance kit checks the guide exists.

### Configuration (layered, with provenance)

One key set, four layers, strict precedence (highest wins):

```
ORCHID_* env vars  >  <repo>/orchid.config  >  ~/.orchid/config  >  defaults
```

Per-user preferences (role bindings, model tiers, notify channel) belong in
`~/.orchid/config` — set once, apply to every repo; per-repo facts
(integration branch, verify command, resources) in `orchid.config`; env for
one-off overrides. All layers are key=value, parsed never sourced.
`orchid config list` (tier-1, read-only) prints the EFFECTIVE configuration
with per-key provenance (which layer won) — no guessing why a setting
applies. `docs/configuration.md` is the complete key reference (key,
default, layer it belongs in, stage introduced) and is the single source of
truth the README links to.

### Docs as a v1 deliverable (the stellar bar, made testable)

The docs suite — README, `docs/quickstart.md` (existing-repo and
greenfield), `docs/configuration.md`, `docs/engines/*`, `docs/extending/*`,
`docs/troubleshooting.md` (rate limits, resume, stale locks, blocked tasks),
FAQ — ships INSIDE v1's release gate with a measurable acceptance
criterion: **a new user with Claude+Codex subscriptions goes from clone to
their first completed orchid task in under 15 minutes using only the
quickstart** — rehearsed during dogfood on a clean machine profile. Docs
that fail the rehearsal block the release the same way failing tests do.

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
- **merging** = `orchid merge <id>`: serialized, transactional, and — round-4
  determinism fix — NEVER triggers reviews itself. If integration HEAD ≠
  `base_sha`, the verb performs the rebase, then exits
  `rebase_rereview_required` (code 5), resetting the task to `testing` with
  updated SHAs. The TICK then relaunches verify and reviews (delta review:
  reviewers receive the range-diff and new base; full re-review if
  non-trivial — the classification is the orchestrator's, journaled with
  kind `rebase_review`). A rebased candidate is UNCONDITIONALLY re-verified;
  a textually clean rebase is not semantically safe against parallel
  changes. On a current base: merge in a temp worktree, run the suite,
  advance the integration ref on pass; `validation_failed` returns that
  exact candidate to rework with logs. **v0 baseline semantics:** the suite
  must pass, full stop; `baseline.md` records pre-existing failures for
  humans. Baseline-aware comparison is post-v1.
- **Attempt fairness (tier-boundary clean):** `orchid task advance` to
  rework increments `attempts` BY DEFAULT — the deterministic verb never
  judges semantics. The orchestrator may pass `--waive-attempt --reason`
  when the failure signature is disjoint from the prior attempt's (distinct
  forward progress); the waiver is a journaled decision (kind
  `attempt_waiver`). The ≤3 cap targets repeated identical failures; the
  per-task wall-clock budget is the unconditional backstop.
  `infra_failures` NEVER consume attempts.

Frontmatter (`schema: 1`): `id, title, status, archetype, scaffold, branch,
worktree, run_id, depends_on, attempts, infra_failures, session_id,
implementer_engine_id, base_sha, candidate_sha, risk_tier,
blocking_severity, stop_condition, engine, effort, acceptance_criteria,
verification_commands, resources, exclusive, wallclock_budget_s,
started_at, created, updated`.

**Review immutability:** reviewers inspect exactly `base_sha..candidate_sha`;
any candidate change invalidates reviews (see rebase rule). Incomplete or
malformed review NEVER counts as approval.

**Risk is two separate fields (round-4 fix — `risk_threshold` was doing
contradictory double duty):** `risk_tier: low|medium|high` drives review
ROUTING and independence requirements, monotonic (upgradable, never
downgradable, `--reason` required); `blocking_severity` (default derived:
low tier → high-severity findings block; medium/high tier → medium+ block)
drives which findings block. High-risk tasks therefore block on MORE
findings, never fewer.

**Independence:** *session independence* (fresh session, same engine) vs
*engine independence* (different vendor), enforced by the resolver against
the task's recorded `implementer_engine_id`. Routing: `low` → single
engine-independent reviewer (default agy inline); if NO engine-independent
reviewer is available, the resolver falls back to session independence
LABELED AND JOURNALED as such — never silently. `medium`/`high` → dual
review (worktree-capable for depth + engine-independent for diversity).
Two-engine installs are "degraded independence": medium accepts labeled
session independence; high queues for engine independence.
**Inline-review blind-spot guard:** inline prompts include the pack
manifest AND the changed-symbol list; routing upgrades to a
worktree-capable reviewer when changed symbols are referenced in un-diffed
files.

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
preference pairs per role in config (defaults: `role.orchestrator`
claude→codex; `role.implementer` codex→claude; `role.arbiter` claude→codex;
`role.plan_critic` any engine that did not author the plan; reviewers per
risk-tier routing) + the capability gate: a fallback (engine, role) pair
activates ONLY after passing the role×engine capability suite (filesystem
scope, network policy, subprocess, git, structured output, recovery). The pump: LLM-free heartbeat that launches
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
| Spinning | deterministic FIRST, with a false-positive guard: duplicate-line checks apply to the ADAPTER's own output, use a sliding window (≥5 min identical lines AND no CPU/disk delta AND no new commits) — build tools legitimately repeat progress lines and are never judged by line content alone; LLM log-tail judgment is the ESCALATION tier |

Write-ahead manifests keyed by job_id (task, attempt, role, engine id +
digest, pgid, start-time, session_id, worktree, base_sha, log) with child
handshake marker; reconciliation never trusts notifications; escalation
ladder bounded by wall-clock budget; orchestrator token cost stays flat.

## Remote interaction

- **v0/v1 seam:** `orchid notify` (question-id minted by the kernel,
  multiple-choice preferred) → `BLOCKERS.md` + terminal; `orchid answer
  <qid> <choice>` — idempotent, expiring, consumed by the next tick.
- **v1-m4 channels — three explicit actors (round-4 topology fix):**
  (1) a kernel-launched OUTBOUND channel plugin (`send` only, no repo
  access); (2) the **orchid AgentSkill inside OpenClaw** — an authenticated
  external front-end authorized for exactly two verbs, `orchid status` and
  `orchid answer` (this, not the channel plugin, answers "how's the run?"
  from your phone); (3) a lock-safe kernel INBOX: `orchid answer` validates
  nonce, sender allowlist, and expiry before recording — no listener
  daemon; the tick polls the inbox. Telegram fallback uses the same
  three-actor shape. An unanswered question is just a blocked task.
- **API-billing exception, stated plainly:** API-backed engines (Kimi,
  Perplexity researcher) are metered per call, unlike subscription CLIs;
  their role descriptors carry call budgets and retry ceilings, and
  research failure is OPTIONAL-degrading (a run continues without
  citations), never blocking.
- Non-goal: native app. `orchid status` (later a static page) is the
  read surface.

## Memory & resumption

Orchid has memories, deliberately not thoughts. Durable files carry every
fact needed to resume or hand off; in-flight LLM reasoning dies with its
session BY DESIGN — stateless ticks re-derive judgment from durable facts,
which is precisely what lets a different engine (or a fresh session) pick up
mid-run: facts and decisions transfer between models; chains of thought do
not. (A session MAY keep scratch notes under `runtime/scratch/<session>/`;
they are garbage on resume — no successor ever reads them. Engine trajectory
logs are retained as diagnostics for humans, never re-fed to models.)

### The decision journal (`journal.md`, v0)

Append-only, one entry per decision, written ONLY via the verb:

```
orchid journal add --task T007 --kind arbitration \
  --by "claude/orchestrator s-9f2" \
  "Approved over agy's request-changes: the flagged race is unreachable —
   writes serialize on the run lock (libexec/orchid-task:41). Codex-review
   concurred. Findings below medium ignored per risk_threshold."
```

renders as:

```markdown
## 2026-07-25T14:02:11Z T007 arbitration (claude/orchestrator s-9f2)
Approved over agy's request-changes: the flagged race is unreachable — ...
```

- **Entry kinds (closed set):** `arbitration` (BOTH outcomes), `risk_change`,
  `attempt_waiver`, `kill` (spinning/stall, dead-end named), `blocker`,
  `blocker_resolved`, `rebase_review` (delta-vs-full classification),
  `plan_revision`, `acceptance`, `intervention` (operator verbs log
  automatically), `lesson` (mirrored to `lessons.md`).
- **Enforcement is a complete decision matrix, kernel-level:** every
  judgment-bearing verb refuses to run without `--reason`, which it writes
  atomically with the state change — `task advance` to `merging`, `blocked`,
  and `rework`-from-`arbitrating` (both arbitration outcomes recorded);
  `task set risk_tier` (monotonicity enforced separately from prose);
  `--waive-attempt`; `task unblock/retry`; `run accept`;
  `lessons retire`. Actor identity (`engine/role/session`), run, epoch,
  job, and SHAs are derived from KERNEL context — never caller-supplied, so
  the audit trail is not forgeable. A decision without a recorded why is
  structurally impossible.
- **Read surface:** `orchid journal tail [-n N]`,
  `orchid journal show --task T007` (that task's full decision history).
  Entries are prose for successors and humans; NEVER parsed for control
  flow — the state machine remains the only authority.

### Cross-run lessons (`lessons.md`, v1)

A lesson is a durable repo truth worth remembering across runs: a flaky
test, an unstated convention, a build quirk, an engine-specific weakness
("codex ignores the barrel-file rule in this repo").

- **Structure (round-4 fix — prose lines can't be safely maintained):**
  each lesson has a stable ID and fields: `scope` (repo | plugin/model
  identity for engine-specific lessons, which EXPIRE with the engine
  version), statement, evidence pointers (task/journal refs),
  first/last-confirmed dates, invalidation condition, and state
  (`active | superseded | retired`).
- **Birth:** PROTOCOL directs the orchestrator to consider a lesson at
  exactly three moments — a rework caused by something `context.md` failed
  to state; a recurring REPO-behavior flake (test/build — vendor
  infrastructure blips belong in the availability ledger, never in
  lessons); an arbitration that turned on repo knowledge no file contained.
- **Verbs:** `orchid lessons add/update/retire/consolidate` — deterministic,
  journaled (retire requires `--reason`). Caps by bytes/items, not lines.
  At plan phase: prune falsified, consolidate overlaps, and PROMOTE lessons
  that have become encoded in code/docs into `context.md` (then retire them
  — a truth the repo now states is context, not a lesson).
- **Across runs:** `orchid run new` archives the previous run's tasks,
  reviews, and journal under `runs/<run_id>/` and carries forward ONLY
  `context.md` + ACTIVE lessons — the defined inheritance boundary.
- **Distinct from `context.md`:** context is what the repo IS (regenerable
  from the code); lessons are what the code CANNOT tell you (learned the
  hard way).

### Per-role memory injection (what each engine call receives)

Assembled by the kernel into every request document, under a byte budget —
recipients get what their judgment needs, nothing more:

| Role | Receives |
|---|---|
| implementer | context.md + lessons.md + task body (incl. its OWN rework history and named dead-ends) |
| reviewer | context.md + lessons.md + diff/manifest + acceptance criteria + stop condition (never other tasks' state) |
| arbiter | both review envelopes + this task's journal history + diff on demand |
| plan_critic | requirements + draft roadmap + lessons.md |
| orchestrator (tick) | status + active task files + decision capsules + journal tail + lessons.md (it owns lessons hygiene) + open answers |

### Resumption procedure (reconcile FIRST, then bounded snapshot)

Round-4 ordering fix: reading memories before reconciling jobs lets a
just-finished job invalidate the snapshot. `orchid-resume`:
1. acquire lock, fence epoch (`orchid run resume`);
2. `orchid jobs check` + `orchid jobs reconcile` (quarantine included);
3. `orchid status` — NOW compute the active set from reconciled reality;
4. per active task: task file (full, non-truncatable) + its **decision
   capsule** — the kernel maintains `runtime/journal-index/<task>` (open
   decisions + last N entries per task, updated on every journal write), so
   task-scoped judgment is O(capsule), never a scan of the monolithic
   journal;
5. `journal tail -n 20` + `context.md` + active `lessons.md` — all under
   the same explicit byte budgets as request packs;
6. tick normally.
The same procedure serves crash recovery, engine failover (a codex tick
inherits a claude tick's decisions with rationale), and cold-start weeks
later. The append-only journal remains the audit truth; the index is a
derived cache, rebuildable from it.

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
  agy comprehensive 10 incl. 1 critical, internal 10), round 4 three-way on
  the platform+memory spec (codex 10 incl. 2 critical — verdict "not yet
  normative", agy 9 incl. 1 critical — verdict "conditional approve",
  internal 6). v5 reconciles round 4: normative process model with epochs
  and fencing, complete file→verb ownership table, operation-discriminated
  request/envelope unions with materialized input packs, complete decision
  matrix with kernel-derived actor identity, structured lessons with
  lifecycle verbs and run rollover, reconcile-first bounded resume,
  milestone reorder (foundation before failover), risk_tier /
  blocking_severity split, three-actor remote topology, spinning
  false-positive guard, research-grounding pillar map. v4 incorporates:
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
diagram + one task's journey — including an explicit **"who runs whom"**
panel: engines never spawn engines; the deterministic kernel launches every
engine and brokers all results as files; the orchestrating engine needs
exactly one power — running a bash CLI — and every other role×engine combo
is disabled until the capability suite proves it; why this design; **any engine, any role**
matrix (capability table, tested defaults, degraded-independence labeling,
worked `role.*` swap example); install/uninstall; quickstarts (existing +
greenfield) with screenshots; state files, guardrails, operator verbs;
**Extending orchid** (five extension points, patterns glossary, "first
adapter in under an hour" against `docs/extending/` guides — referencing
built-ins until the v1-m4 reference plugins ship); FAQ; **Research grounding** (below). CONTRIBUTING.md + a
community plugin listing section (awesome-orchid) at public launch.

**Research grounding (`docs/research.md` + inline citations):** orchid's
design pillars each cite the literature that genuinely supports them —
citations appear NEXT TO the claim they support in README/docs, and
`docs/research.md` is the annotated bibliography. The rule is relevance,
not volume: padding with tangential papers reads as spam and inverts
credibility. The pillar map:

| Design pillar | Supporting work |
|---|---|
| multi-agent division of labor for software dev | MetaGPT (Hong et al.), ChatDev (Qian et al.), AutoGen (Wu et al.), CAMEL (Li et al.) |
| nobody signs off on their own work / engine independence | LLM-as-judge (Zheng et al., MT-Bench); self-preference bias — LLM evaluators favor their own generations (Panickssery et al.) |
| reviewer diversity & arbitration on disagreement | multi-agent debate (Du et al.), More Agents Is All You Need (Li et al.), Mixture-of-Agents (Wang et al.) |
| rework specs, journal, lessons (memory design) | Reflexion (Shinn et al.), Self-Refine (Madaan et al.), Voyager skill library (Wang et al.), Generative Agents memory streams (Park et al.), MemGPT (Packer et al.) |
| deterministic verification over model claims; agentic SE evaluation | SWE-bench (Jimenez et al.), SWE-agent (Yang et al.); trajectory evaluation per Google's "The New SDLC With Vibe Coding" whitepaper |
| harness > model; factory model; model routing | Google whitepaper; Karpathy's agentic-engineering framing |
| productivity claims (stated with nuance, both directions) | METR RCT (experienced devs can be SLOWER with AI — cited honestly), Peng et al. Copilot study |

Exact citations (authors, venues, years, links) are verified against the
published papers when `docs/research.md` is written — titles above are
from design-time knowledge and MUST be link-checked before public release. Commit
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

Usage/cost ledger · per-task engine routing · resource auto-allocation ·
chunk-and-aggregate inline reviews · OS-level plugin containment profiles ·
baseline-aware test comparison. (Status page and service packaging are v1-m4
core — no longer future.)
