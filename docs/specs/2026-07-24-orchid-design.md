# Orchid — Design Spec

**Date:** 2026-07-24
**Status:** Approved (design review complete; revised after external design
review by codex and agy critics; pending final user review)

## Purpose

Orchid is a lean multi-agent orchestrator for people who hold subscriptions to
several AI coding CLIs and want them working together on large, long-running
tasks. Claude Code orchestrates, plans, arbitrates, and merges; Codex CLI
implements; Antigravity (`agy`) and a separate Codex session review. Heavy
token usage is offloaded to the implementer/reviewer subscriptions, keeping
the orchestrating session cheap enough to drive multi-day runs.

Design principles: no daemon, no dashboard, no terminal emulation, no custom
agentic loop. Every engine is driven through its first-party headless CLI
mode, so billing stays on each vendor's subscription and there is no fragile
glue to maintain. All orchestration state is markdown/JSON files in git — the
session is disposable; the files are the truth.

## Requirements (from design session)

- **Run model:** semi-attended. An interactive Claude Code session with a
  self-paced `/loop` is the primary surface; the machine stays awake. The
  LLM-free pump plus headless `orchid-tick` keep the run advancing when the
  interactive session is rate-limited or closed; only service packaging
  (survive reboots) is deferred.
- **Scope:** both existing repos (multi-day features/refactors) and greenfield
  products (scaffold from requirements) from day one.
- **Engine roles (preference-ordered, not fixed):** default wiring is Codex
  implements; Antigravity and a fresh Codex review session review; Claude
  arbitrates and orchestrates; plans are always critiqued by a non-authoring
  engine. Every role has an ordered fallback list (see Engine availability &
  role failover) so a rate-limited engine degrades the run instead of
  stopping it.
- **Autonomy:** fully autonomous — no user approval gates. Only genuine
  blockers are surfaced to the user. Autonomy is bounded by the Execution
  policy below. A run must never block solely because one engine hit its
  usage limit.
- **Distribution:** public GitHub repository for general benefit (see
  Distribution section).
- **Non-goals (v1):** daemon/service, web UI, cost ledger, multi-user,
  cross-machine operation, chat-style inter-agent messaging, native phone app.

## Architecture

Two locations; strict split between tooling (global, this repo) and run state
(per target repo).

### Tool repo: `~/workspace/personal/orchid/`

```
PROTOCOL.md                 # engine-neutral tick procedure — the single source
                            # of orchestration truth, consumed by every runner
skills/
  orchid/SKILL.md           # Claude runner: interactive loop following PROTOCOL.md
  orchid-plan/SKILL.md      # requirements → roadmap, mandatory external critique
  orchid-resume/SKILL.md    # re-enter a run after crash/restart/rate-limit
bin/
  orchid-doctor             # preflight validation (see Preflight)
  orchid-pump               # LLM-free heartbeat: invokes one tick on the best
                            # available orchestrator engine (see failover)
  orchid-tick               # runs a single tick headless via claude -p or
                            # codex exec, prompt generated from PROTOCOL.md
  engine-codex              # wraps `codex exec` (implementer role)
  engine-codex-review       # wraps `codex exec review` (reviewer, fresh session)
  engine-agy                # wraps `agy -p` (reviewer role, inline-diff mode)
  engine-claude             # wraps `claude -p` (fallback implementer/orchestrator)
  notify                    # user-facing question/notification channel
templates/
  roadmap.md  task.md  review.md
install.sh                  # symlinks skills into ~/.claude/skills
docs/specs/                 # this document and successors
README.md  LICENSE          # public-facing docs (MIT)
```

Wrappers encapsulate all engine flags (model, effort, sandbox, output capture,
logging, single retry) so skills stay short and any engine can be swapped or
later fronted by a CLI/daemon without touching skills or state formats.

### Run state: `<target-repo>/.orchid/` (committed to git)

```
requirements.md             # user's original brief, verbatim, with requirement IDs
roadmap.md                  # milestones → tasks with statuses + requirement coverage map
baseline.md                 # pre-run test results (pre-existing failures recorded)
tasks/T001.md ...           # one spec per task (frontmatter + body)
reviews/T001-agy.md, T001-codex.md
jobs/T001.json ...          # write-ahead job manifests (see Stuck-agent detection)
answers/                    # user replies consumed by ticks (see Remote interaction)
engines.json                # per-engine availability ledger (see failover)
BLOCKERS.md                 # the only file the user is expected to read
lock                        # run lock (flock) — one orchestrator tick at a time
```

**State ownership rule:** `.orchid/` is mutated ONLY by the orchestrator, only
on the integration branch. Task branches never modify it; implementer prompts
forbid it and wrappers revert any `.orchid/` changes found on a task branch
before review. This eliminates state merge conflicts by construction.

Greenfield: `orchid-plan` creates the repo and MUST make a root commit
(`requirements.md`, `.orchid/`, `.gitignore`) on the default branch before any
worktree is created — `git worktree add` requires an existing HEAD. Scaffolding
is task T001. Everything after is identical to the existing-repo flow.

## Preflight (`orchid-doctor`)

Runs before `orchid-plan` and before `orchid-resume`; fails safely without
modifying the repository when prerequisites are unresolved. Validates: git
topology (repo, clean tree policy, no branch-name collisions, submodule/LFS
presence noted), worktree support, engine binaries and versions, engine
authentication (cheap no-op call per engine), configured models available,
test command discovered or explicitly configured, integration branch
creatable, platform supported. Existing user work is never touched: orchid
operates only on branches it creates.

## Task lifecycle

Task frontmatter is the state machine:

```
pending → implementing → testing → reviewing → arbitrating → merging → done
                ↑            │         │            │
                └── rework (≤3) ───────┴────────────┤
                                                    └→ blocked
```

- **testing:** the task's verification commands run in the task worktree.
  Failures return to rework without spending reviewer tokens or attempts on
  code that cannot pass its own tests.
- **merging** is transactional: the candidate is validated one-at-a-time in a
  temporary integration worktree (merge + full suite against the recorded
  baseline). Only on pass does the real integration branch advance and the
  task become `done`; on failure (`validation_failed`) that exact candidate
  returns to rework with captured logs. Merges are serialized; test-failure
  attribution is never ambiguous.

Frontmatter fields: `id, title, status, branch, worktree, depends_on,
attempts, session_id, base_sha, candidate_sha, risk_threshold,
stop_condition, engine, effort, acceptance_criteria, verification_commands,
created, updated`.

**Review immutability:** both reviewers inspect exactly
`base_sha..candidate_sha`. Any change to the candidate invalidates existing
reviews. Dependencies must be `done` before a task starts, so its base is
final. An incomplete or malformed review NEVER counts as approval
(fail closed).

**Acceptance:** requirements get IDs at plan time; `roadmap.md` maintains the
requirement→task coverage map; every task carries observable acceptance
criteria and verification commands. A final acceptance gate — coverage check
plus end-to-end acceptance tests — runs before the run is declared complete.
Passing tests and clean reviews prove absence of detected defects; the
acceptance gate proves the requested product was delivered.

`risk_threshold` and `stop_condition` are injected into every reviewer prompt,
e.g. "report at most 8 findings at or above medium severity; no style nits;
one pass only." This prevents the infinite-diligence loop.

Role rules:

- Codex implements on branch `task/<id>` in its own git worktree.
- **Review routing is risk-tiered:** tasks with `risk_threshold: low` (docs,
  config tweaks, trivial changes — assigned at plan time, orchestrator may
  upgrade but never downgrade after implementation) get a single reviewer:
  agy inline (the party fully independent of the implementer), falling back
  to `codex exec review` when agy is unavailable or the diff exceeds inline
  budgets. Medium- and high-risk tasks get dual review in parallel:
  `agy -p` and a fresh `codex exec review` session (never the implementing
  session — nobody signs off on their own work).
- The orchestrator arbitrates: findings below the task's risk threshold never
  block; reviewer agreement is strong signal; on disagreement the orchestrator
  reads the diff and decides. The orchestrator does not implement, except
  arbitration-level trivia (≤ ~10 lines); anything larger returns to Codex as
  a rework spec with `attempts` incremented.

### Review completeness (inline agy reviews)

`engine-agy` builds the review prompt from `git diff base_sha..candidate_sha`
plus selected file context under an explicit byte budget. It always includes
an input manifest — every changed file, and anything omitted or truncated —
and requires the reviewer to return `scope_complete: true/false`. Oversized
diffs are chunked with an aggregation pass, or routed to `codex exec review`
(which reads the worktree directly). `scope_complete: false` without a
completed fallback blocks approval.

## Engine result contract

Every `bin/engine-*` wrapper writes a versioned JSON result envelope
atomically (temp file + rename):

```json
{ "contract": 1, "task": "T001", "attempt": 2, "status": "ok|failed|rate_limited|timeout|auth|malformed",
  "session_id": "...", "base_sha": "...", "candidate_sha": "...",
  "started_at": "...", "ended_at": "...", "retry_after": null,
  "scope_complete": true, "verdict": "approve|request-changes|n/a",
  "findings": [ { "severity": "...", "title": "...", "detail": "..." } ] }
```

Codex output uses its output-schema support; `engine-agy` validates/normalizes
agy's response in the wrapper. Schema violations → `malformed`, which fails
closed. Free-form engine text is stored alongside for the orchestrator to
read, never parsed for control flow. Contributors add engines by writing one
wrapper honoring this envelope.

## The loop

Interactive Claude Code session running `/loop` (self-paced). Each tick:

1. Read `.orchid/` state; reconcile job manifests against reality.
2. Collect finished background engine jobs; advance their tasks.
3. Launch new work up to the concurrency cap (default 2 implementers plus
   their reviews), honoring scheduling rules below.
4. Validate at most one approved candidate in the merge worktree; advance
   integration on pass.
5. Commit state changes.
6. Sleep with a long fallback wakeup. Background job completions re-invoke
   the session (Claude Code background-task notifications), so ticks are
   event-driven — but events are an optimization; the fallback tick plus
   reconciliation is the guarantee (see Stuck-agent detection), and the
   pump guarantees ticks continue even if this session is rate-limited or
   gone (see Engine availability & role failover).

**Scheduling rules:** tasks that modify dependency manifests (`package.json`,
lockfiles, `Cargo.toml`, …) are serialized. When the test environment's
parallel-safety is unknown, `testing`/`merging` phases run serially by
default. Tasks may declare `exclusive: true` in frontmatter to demand solo
execution. Worktrees isolate git state only — never assume they isolate
caches, ports, databases, or servers.

**Plan phase** (`orchid-plan`): the orchestrator drafts the roadmap from
`requirements.md` → `engine-codex` in critic mode attacks it (missing
requirements, sequencing risk, stack choice) → the orchestrator revises →
loop starts. No user gate.

## Engine availability & role failover

The run must survive any single engine hitting its usage limit — including
the orchestrator's. Three mechanisms:

**1. Engine-neutral orchestration (`PROTOCOL.md`).** The tick procedure is
written once, engine-neutrally, in `PROTOCOL.md`. The Claude skill follows it
interactively; `bin/orchid-tick` renders it into a headless prompt for
`claude -p` or `codex exec`. Orchestration by Claude and orchestration by
Codex are the same program on different runtimes — a handoff moves nothing,
because there is nothing to move but the files. The run lock serializes
ticks, so interactive session and headless ticks can coexist safely.

**2. Availability ledger + preference lists.** `.orchid/engines.json` records
per engine: last status, `rate_limited_until` (from `retry_after` when known,
else exponential backoff probe), consecutive failures. Every wrapper updates
it on every call. Roles bind to ordered preference lists, overridable in
`orchid.config`:

```
orchestrator:  claude → codex
implementer:   codex  → claude
reviewer:      agy + first available engine that did not implement the task
plan-critic:   first available engine that did not author the plan
```

The scheduler picks the first available engine per role at dispatch time and
records the choice in task frontmatter. When a preferred engine's window
reopens, it simply wins the next dispatch — failback is automatic and
stateless.

**3. The pump (`bin/orchid-pump`).** A rate-limited orchestrator cannot
notice its own outage, so liveness sits below the LLM layer: the pump is a
small LLM-free shell heartbeat (run in a spare terminal in v1) that every few
minutes takes the run lock and, if no tick has completed recently, invokes
`orchid-tick` on the first available orchestrator engine. It uses no quota,
cannot be rate-limited, and turns "Fable hit its weekly cap at 3am" from a
dead run into ticks quietly running on codex until the window resets.

**Independence under failover.** "Nobody signs off on their own work" is
enforced dynamically against the task's recorded implementer engine — if
Claude implemented a task (as fallback), Claude does not review or solely
arbitrate it. When outages make independence temporarily unsatisfiable, the
affected task QUEUES rather than violates; other tasks continue. One
taste-guard, configurable: arbitration of high-risk tasks waits (bounded,
default 4h) for the preferred arbiter rather than settling for whichever
engine is awake; low/medium-risk arbitration proceeds on the fallback
immediately.

**Honest caveat:** orchestration quality is not engine-symmetric — the
preference order exists because judgment differs. Failover trades some
judgment quality for continuity, deliberately, and only while the outage
lasts.

## Execution policy (the autonomy boundary)

"Fully autonomous" is bounded by what engines are permitted to do, defined
per role and enforced by wrappers:

- **Implementer (codex):** writes only inside its task worktree
  (`workspace-write`), `approval_policy=never` so it can never stall waiting
  for input, environment stripped to an allowlist, no secret-file reads,
  network disabled except during declared dependency-install phases.
- **Reviewers:** read-only (`codex exec review` sandboxed read-only; agy
  receives inline context and needs no permissions at all).
- **External mutations are prohibited in v1:** no `git push`, no deploys, no
  package publishing, no production data changes — by any engine or by the
  orchestrator. Any task requiring one raises a blocker for the user instead.
- `orchid.config` is parsed as key=value data, never shell-sourced.

## Guardrails & failure handling

- **Engine calls:** hard timeout (default 60 min), envelope status checks,
  one automatic retry, then `attempts++`; three strikes → `blocked`.
- **Rate limits:** `rate_limited` status (with `retry_after` when known) is
  distinct from failure; the engine is marked in `engines.json`, the task
  re-queues untouched, and dispatch falls through to the next engine in the
  role's preference list. A limit window pauses an engine, never the run,
  and never burns attempts.
- **Runaway protection:** ≤3 rework cycles per task, concurrency cap,
  reviewer stop-conditions, per-task wall-clock budget.
- **Blockers:** appended to `BLOCKERS.md` and pushed through `bin/notify`;
  everything else self-heals.
- **Isolation:** every task in its own worktree/branch under the Execution
  policy. A poisoned run is `git branch -D` plus an auditable `.orchid/`
  history.
- **Crash/restart:** `orchid-resume` runs preflight, takes the run lock, and
  rebuilds reality from state files and job manifests: live PIDs are
  re-adopted; dead jobs are relaunched cleanly (session resume via recorded
  `session_id` is an optimization, never required — task state always permits
  clean relaunch). State files are the only truth; the session is disposable.

## Stuck-agent detection

Silent stalls are the primary threat to multi-day autonomy. Four distinct
stuck modes, each with its own defense:

| Mode | Description | Defense |
|---|---|---|
| Dead | process crashed/killed | PID liveness check each tick |
| Hung | alive but frozen | stall detector: log mtime unchanged ~10 min → kill, `attempts++` |
| Blocked on prompt | waiting for input headless mode can't give | made impossible: `approval_policy=never` + never-prompt flags; verified agy soft-denies and exits rather than hanging |
| Spinning | alive, output flowing, no progress | orchestrator judgment on log tail each tick (repetition, circular retries) → kill + rework spec naming the dead-end |

Mechanisms:

- **Write-ahead job manifests:** `.orchid/jobs/<task>.json` (task, attempt,
  engine, pid, session_id, worktree, base_sha, log_path, started_at) is
  written BEFORE launch and updated after. A crash between write and launch
  is detected on resume as a manifest with no live PID and no output — safe
  to relaunch. The orchestrator always knows what *should* be running.
- **Reconciliation ticks, never trust:** completion notifications are an
  optimization only. Every tick — including the guaranteed fallback wakeup —
  re-derives job status from disk: PID alive? log growing? worktree commits
  advancing? A lost notification costs minutes, never days.
- **Escalation ladder per job:** stall (~10 min silent) → kill and retry;
  hard timeout (60 min) → kill, `attempts++`; task wall-clock budget
  exhausted or 3 attempts → `blocked`, surfaced via `bin/notify`. No task can
  silently consume a day.
- **Spinning is a judgment call, not a metric:** each tick the orchestrator
  reads only the log tail (cheap) and kills work that is circling; the rework
  spec for the next attempt documents the dead-end so it is not repeated.

## Remote interaction (seam in v1, channel post-v1)

Human answer latency is the throughput ceiling of a fully-autonomous run: a
blocker raised at 2am and seen at 9am idles that task for seven hours. The
design therefore treats "reach the user off-machine" as a first-class seam:

- **v1 seam:** all user-facing questions flow through one wrapper,
  `bin/notify` (default implementation: append to `BLOCKERS.md` + terminal).
  Questions are phrased multiple-choice wherever possible so they can be
  answered from a phone lock screen. Answers are consumed from
  `.orchid/answers/` by the next reconciliation tick — the tick loop is the
  message pump; no new moving parts.
- **First post-v1 milestone:** two-way Telegram bot backend for `bin/notify`
  (push question → user replies in Telegram → tick polls replies into
  `.orchid/answers/`). Slack/Discord are equivalent alternates. An unanswered
  question is just a blocked task: bounded, visible, and non-blocking for all
  other tasks.
- **Explicit non-goal:** a native phone app. Push + two-way Q&A comes free
  with messaging platforms; run status can be a static page generated from
  `.orchid/` state per tick. Session management from mobile is expected to
  arrive via Claude Code's own web/mobile surface rather than orchid.

## Verification findings (2026-07-24, empirical)

- `codex exec --sandbox read-only "<prompt>"` works headless: 3.6 s
  round-trip, token usage printed in output. `codex exec resume` and
  `codex exec review` subcommands exist.
- `agy -p "<prompt>"` works headless: 3.8 s round-trip, clean stdout.
  **Gotcha:** all other flags must come BEFORE `-p`; flags placed between
  `-p` and the prompt mangle prompt parsing. Wrappers must enforce this.
- `agy models` lists usable models: gemini-3.6-flash (high/medium/low),
  gemini-3.5-flash tiers, gemini-3.1-pro (high/low), claude-sonnet-4-6,
  claude-opus-4-6-thinking, gpt-oss-120b-medium.
- **agy headless permission limitation:** tools requiring confirmation are
  auto-denied in print mode ("soft-denying tool confirmation \"Bash\"").
  Allow-rules live in `~/.gemini/antigravity-cli/settings.json` under
  `permissions.allow`; `command(<target>)` rules load but did not match the
  `Bash` tool's needs in testing, and settings are normalized on load
  (unknown rule names are stripped). Granting a blanket `Bash` allow or using
  `--dangerously-skip-permissions` would unblock repo browsing but grants
  unrestricted shell — deliberately NOT configured; user decision.
- **Verified workaround (v1 approach):** inline-diff review needs no tools at
  all — a diff embedded in the `-p` prompt returned a correct structured
  VERDICT/REASON response. See Review completeness for size handling.
  Implementation must also test whether `agy -p` accepts stdin, which would
  lift ARG_MAX limits on inline prompts.
- **To verify in the vertical slice (not yet tested):** `claude -p` executing
  one full tick headless; `codex exec` as orchestrator spawning engine
  subprocesses and performing git operations under its sandbox (sandbox
  policy may need explicit process/exec allowances for the orchestrator
  role, distinct from the implementer profile).
- **Design review round:** the spec was critiqued by codex (10 findings) and
  agy (8 findings) in headless critic sessions; accepted findings are
  incorporated throughout (job identity, review immutability, test-first
  sequencing, transactional merges, execution policy, engine envelope,
  preflight, review completeness, greenfield root commit, rollout order).
  Rejected: polling-only loop (background-task notifications verified working
  in the Claude Code harness, with reconciliation as the guarantee).

## Distribution (public GitHub repo)

- Repository `orchid` under the author's personal GitHub account, created
  **private** at implementation start; flipped **public** only after the
  rollout sequence below proves the documented flows and produces real
  screenshots. The first public state must be presentable AND true.
- **License:** MIT.
- **Rollout sequence (also the implementation order):** deterministic
  single-task vertical slice → crash/recovery test → existing-repo dogfood
  run (webBooks) → concurrency + agy review exercised → greenfield demo run
  → README + screenshots from those runs → public release.
- **README** is a first-class deliverable, written to sell the idea to a
  stranger in 30 seconds and get them running in 10 minutes. Required
  structure:
  1. **Hero:** one-paragraph pitch — "you're paying for two or three AI
     coding subscriptions; orchid makes them work as a team" — followed by a
     hero screenshot of a live run.
  2. **How it works:** the role triangle (orchestrator / implementer /
     reviewers / arbiter) as a Mermaid diagram (renders natively on GitHub),
     plus a short narrative of one task's journey through the state machine.
  3. **Why this design:** subscription billing via first-party headless CLIs
     (no API keys, no per-token metering), no daemon, git as the only state.
  4. **Prerequisites & subscription matrix:** a table of supported
     combinations — Claude Code required as orchestrator; Codex CLI required
     as implementer; Antigravity optional as second reviewer — with an
     explicit section "What if I have more than one subscription?" mapping
     each supported combo (Claude+Codex minimum; Claude+Codex+Antigravity
     full triangle) to which roles run where and what the added subscription
     buys (an independent second reviewer). States plainly that a Codex
     subscription is required in v1 and points to the engine-wrapper
     contract for anyone wanting to substitute another implementer.
  5. **Install:** `git clone` + `./install.sh`, what it symlinks and where;
     uninstall note.
  6. **Quickstart:** existing-repo walkthrough (write `requirements.md`,
     start the loop) and greenfield walkthrough, each with a screenshot of
     the roadmap/tasks state and the loop ticking.
  7. **State files, guardrails, and how to intervene** (edit task files,
     `BLOCKERS.md`), then FAQ (rate limits, resuming after a crash, adding
     an engine via the envelope contract).
- **Screenshots:** stored in `docs/assets/`; captured during the rollout
  runs. Minimum set: hero shot of the loop mid-run with background engine
  jobs, the roadmap + task files in an editor, an arbitration verdict, and a
  finished-run diff summary. Refreshed whenever UX-visible behavior changes.
- **Commit hygiene:** history starts clean at publication; commits carry no
  AI co-author trailers; no personal machine paths or secrets in any
  committed file — wrappers resolve engine binaries from `PATH` and
  user-specific config from env vars, never hardcoded paths.
- **Generalization requirement:** nothing in skills/, bin/, or templates/ may
  assume this author's machine. Home-directory references use `$HOME`;
  engine model/effort defaults are overridable via an `orchid.config`
  (key=value data file, never shell-sourced) in the target repo.

## Future (explicitly deferred)

- Fully unattended operation: installing `orchid-pump` as a launchd/cron
  service so runs survive reboots and closed terminals (the pump and
  headless `orchid-tick` already exist in v1; only the service packaging is
  deferred).
- Two-way Telegram/Slack notify backend (see Remote interaction — first
  post-v1 milestone).
- Static mobile-readable status page generated from `.orchid/` state.
- Companion CLI with usage/cost ledger, if observability outgrows `git log`.
- Per-task engine routing beyond the fixed role split.
- Task resource declarations beyond `exclusive` (ports, databases,
  containers) with automatic allocation.
