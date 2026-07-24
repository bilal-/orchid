# Orchid — Design Spec

**Date:** 2026-07-24
**Status:** Approved (design review complete; pending final spec review)

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
glue to maintain. All orchestration state is markdown files in git — the
session is disposable; the files are the truth.

## Requirements (from design session)

- **Run model:** semi-attended. An interactive Claude Code session with a
  self-paced `/loop`; the machine stays awake with the terminal open. State is
  designed so a headless driver could be added later without redesign.
- **Scope:** both existing repos (multi-day features/refactors) and greenfield
  products (scaffold from requirements) from day one.
- **Engine roles:** Codex implements. Antigravity AND a fresh Codex review
  session both review. Claude arbitrates all disagreements and makes final
  judgment. Plans are always critiqued by Codex before execution.
- **Autonomy:** fully autonomous — no user approval gates. Only genuine
  blockers are surfaced to the user.
- **Distribution:** public GitHub repository for general benefit (see
  Distribution section).
- **Non-goals (v1):** daemon/service, web UI, cost ledger, multi-user,
  cross-machine operation, chat-style inter-agent messaging.

## Architecture

Two locations; strict split between tooling (global, this repo) and run state
(per target repo).

### Tool repo: `~/workspace/personal/orchid/`

```
skills/
  orchid/SKILL.md           # main loop protocol the orchestrator follows each tick
  orchid-plan/SKILL.md      # requirements → roadmap, mandatory codex critique
  orchid-resume/SKILL.md    # re-enter a run after crash/restart/rate-limit
bin/
  engine-codex              # wraps `codex exec` (implementer role)
  engine-codex-review       # wraps `codex exec review` (reviewer, fresh session)
  engine-agy                # wraps `agy -p` (reviewer role, inline-diff mode)
templates/
  roadmap.md  task.md  review.md
install.sh                  # symlinks skills into ~/.claude/skills
docs/specs/                 # this document and successors
README.md  LICENSE          # public-facing docs (MIT)
```

Wrappers encapsulate all engine flags (model, effort, sandbox,
`--output-last-message`, logging, single retry) so skills stay short and any
engine can be swapped or later fronted by a CLI/daemon without touching skills
or state formats.

### Run state: `<target-repo>/.orchid/` (committed to git)

```
requirements.md             # user's original brief, verbatim
roadmap.md                  # milestones → tasks with statuses
tasks/T001.md ...           # one spec per task (frontmatter + body)
reviews/T001-agy.md, T001-codex.md
BLOCKERS.md                 # the only file the user is expected to read
```

Greenfield: `orchid-plan` creates the repo, writes `.orchid/`, and makes
scaffolding itself task T001 (stack choice justified in the plan). Everything
after is identical to the existing-repo flow.

## Task lifecycle

Task frontmatter is the state machine:

```
pending → implementing → reviewing → arbitrating → merging → done
                ↑                        │
                └──── rework (≤3) ───────┤
                                         └→ blocked
```

Frontmatter fields: `id, title, status, branch, depends_on, attempts,
risk_threshold, stop_condition, engine, effort, created, updated`.

`risk_threshold` and `stop_condition` are injected into every reviewer prompt,
e.g. "report at most 8 findings at or above medium severity; no style nits;
one pass only." This prevents the infinite-diligence loop.

Role rules:

- Codex implements on branch `task/<id>` in its own git worktree.
- Reviewers run in parallel: `agy -p` and a fresh `codex exec review` session
  (never the implementing session — nobody signs off on their own work; agy is
  the fully independent party). The agy reviewer receives the diff and any
  needed file context inline in the prompt (built by `engine-agy` from
  `git show`/`git diff`), because headless agy auto-denies tool permissions
  (see Verification findings). Inline-diff review is verified working and
  needs no permission grants.
- The orchestrator arbitrates: findings below the task's risk threshold never
  block; reviewer agreement is strong signal; on disagreement the orchestrator
  reads the diff and decides. The orchestrator does not implement, except
  arbitration-level trivia (≤ ~10 lines); anything larger returns to Codex as
  a rework spec with `attempts` incremented.

## The loop

Interactive Claude Code session running `/loop` (self-paced). Each tick:

1. Read `.orchid/` state.
2. Collect finished background engine jobs; advance their tasks.
3. Launch new work up to the concurrency cap (default 2 implementers plus
   their reviews).
4. Merge approved tasks into the integration branch; run the test suite;
   update `roadmap.md`.
5. Commit state changes.
6. Sleep with a long fallback wakeup. Background job completions re-invoke the
   session, so ticks are event-driven, not polling.

**Plan phase** (`orchid-plan`): the orchestrator drafts the roadmap from
`requirements.md` → `engine-codex` in critic mode attacks it (missing
requirements, sequencing risk, stack choice) → the orchestrator revises →
loop starts. No user gate.

## Guardrails & failure handling

- **Engine calls:** hard timeout (default 60 min), exit-code and output-file
  checks, one automatic retry, then `attempts++`; three strikes → `blocked`.
- **Rate limits:** wrappers detect quota errors distinctly from failures; the
  task re-queues untouched and the loop lengthens its wakeup. Runs pause
  across limit windows; they never die from them and never burn attempts.
- **Runaway protection:** ≤3 rework cycles per task, concurrency cap, reviewer
  stop-conditions.
- **Blockers:** appended to `BLOCKERS.md` and surfaced in-session; everything
  else self-heals.
- **Isolation:** every task in its own worktree/branch; Codex runs at sandbox
  `workspace-write`; agy needs no permissions in inline-diff mode. A poisoned
  run is `git branch -D` plus an auditable `.orchid/` history.
- **Crash/restart:** `orchid-resume` rebuilds reality from state files plus
  `codex exec resume --last`, re-attaches or relaunches jobs, and continues.
  State files are the only truth; the session is disposable.

## Stuck-agent detection

Silent stalls are the primary threat to multi-day autonomy. Four distinct
stuck modes, each with its own defense:

| Mode | Description | Defense |
|---|---|---|
| Dead | process crashed/killed | PID liveness check each tick |
| Hung | alive but frozen | stall detector: log mtime unchanged ~10 min → kill, `attempts++` |
| Blocked on prompt | waiting for input headless mode can't give | made impossible: wrappers must pass never-prompt flags; verified agy soft-denies and exits rather than hanging |
| Spinning | alive, output flowing, no progress | orchestrator judgment on log tail each tick (repetition, circular retries) → kill + rework spec naming the dead-end |

Mechanisms:

- **Job manifests:** every engine launch writes `.orchid/jobs/<task>.json`
  (pid, started_at, log_path, engine, attempt). The orchestrator always knows
  what *should* be running.
- **Reconciliation ticks, never trust:** the loop treats background-completion
  notifications as an optimization only. Every tick — including the
  guaranteed fallback wakeup — re-derives job status from disk: PID alive?
  log growing? worktree commits advancing? A lost notification costs minutes,
  never days.
- **Escalation ladder per job:** stall (~10 min silent) → kill and retry;
  hard timeout (60 min) → kill, `attempts++`; task wall-clock budget
  exhausted or 3 attempts → `blocked`, surfaced in `BLOCKERS.md`. No task can
  silently consume a day.
- **Spinning is a judgment call, not a metric:** each tick the orchestrator
  reads only the log tail (cheap) and kills work that is circling; the rework
  spec for the next attempt documents the dead-end so it is not repeated.

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
  VERDICT/REASON response. Constraint: review context is bounded by prompt
  size, so `engine-agy` must select context (diff + key files), not offer
  repo browsing.

## Distribution (public GitHub repo)

- Public repository `orchid` under the author's personal GitHub account,
  created with `gh repo create` at implementation start, once README and
  LICENSE exist so the first public state is presentable.
- **License:** MIT.
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
     an engine via the `bin/engine-*` contract).
- **Screenshots:** stored in `docs/assets/`; captured during the rollout
  runs (first webBooks feature run and the greenfield demo). Minimum set:
  hero shot of the loop mid-run with background engine jobs, the roadmap +
  task files in an editor, an arbitration verdict, and a finished-run diff
  summary. Refreshed whenever UX-visible behavior changes.
- **Commit hygiene:** history starts clean at publication (squashed); commits
  carry no AI co-author trailers; no personal machine paths or secrets in any
  committed file — wrappers resolve engine binaries from `PATH` and
  user-specific config from env vars, never hardcoded paths.
- **Generalization requirement:** nothing in skills/, bin/, or templates/ may
  assume this author's machine. Home-directory references use `$HOME`;
  engine model/effort defaults are overridable via an `orchid.config`
  (simple env-style file) in the target repo.
- **Not included in v1 distribution:** engine adapters beyond
  codex/agy/claude; CI; package-manager publishing. Contributions can add
  engines by writing a new `bin/engine-*` wrapper honoring the same contract
  (prompt via arg or stdin, output file, exit codes: 0 ok / 75 rate-limited /
  other fail).

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

## Future (explicitly deferred)

- Headless driver (launchd/cron invoking `claude -p` ticks) for fully
  unattended runs surviving reboots.
- Two-way Telegram/Slack notify backend (see Remote interaction — first
  post-v1 milestone).
- Static mobile-readable status page generated from `.orchid/` state.
- Companion CLI with usage/cost ledger, if observability outgrows `git log`.
- Per-task engine routing beyond the fixed role split.
