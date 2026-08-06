# orchid/claude — engine guide

Status: **default orchestrator and arbiter**; fallback implementer/reviewer.
This is the adapter this guide covers: `plugins/engines/claude/run`.

## Install

```sh
npm install -g @anthropic-ai/claude-code
# or, the recommended installer on macOS/Linux:
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

Node.js 22+ if installing via npm.

## Login

The first time you run `claude`, it opens your default browser and asks you
to sign in to your Anthropic account (Claude Pro/Max/Team/Enterprise — the
free claude.ai plan does not include Claude Code access), then authorizes
the CLI. Alternatively `claude login` accepts an API key interactively, or
set `ANTHROPIC_API_KEY` before launching for API-metered billing. Orchid
never manages this itself — it only invokes `claude` and reads its exit
code/stdout. `orchid doctor` reports a missing `claude`/`jq` binary or a
failed auth probe against this guide
(`plugins/engines/claude/plugin.conf`'s `requires_binaries=claude,jq`).

**This is also the engine the `orchid` skill itself runs inside** — the
default front-end for the orchestrator role is an interactive Claude Code
session with the `orchid`/`orchid-plan`/`orchid-resume` skills installed
(`install.sh`, step 1 of [quickstart.md](../quickstart.md)), separate from
this adapter's own *headless* `orchestrate` path below (used by the pump,
not by an interactive session).

## Flags orchid uses, and why

**Implement / review / critique:**

```sh
claude -p --permission-mode acceptEdits    # implement
claude -p                                  # review/critique (no edit permission needed)
```

- **`-p`/`--print`** — headless, non-interactive mode; the documented flag
  for piping. The prompt is delivered via **stdin** (no positional prompt
  argument) rather than argv — `claude -p` reads stdin whenever no prompt
  argument is given, which sidesteps the same leading-dash argv risk
  codex's adapter works around explicitly (task.md frontmatter starts with
  `---`).
- **`--permission-mode acceptEdits`** (implement only) — authorizes file
  edits without an interactive prompt. It does **not** authorize running
  Bash/git commands — see "Known gotchas" below for what that means for
  self-committing.
- **Review/critique passes neither flag** — headless print-mode auto-denies
  any tool-use attempt, which is exactly the read-only posture a
  reviewer/critic needs; nothing to explicitly disable.

**Orchestrate (headless tick):**

```sh
claude -p --permission-mode acceptEdits \
  --allowedTools "Bash(<orchid-root>/runners/orchid-orchestrator-command:*)"
```

An `--allowedTools` entry is required in addition to `acceptEdits` — a real
pump-driven tick was found to execute **zero** verbs under `acceptEdits`
alone (`docs/dogfood-notes.md`'s F8): claude politely explained it lacked
permission to run Bash and exited 0 having done nothing. Since every command
goes through the Bash tool (there is no other way to invoke one), the
orchestrator role's job requires it.

What that entry admits is now narrow. It is scoped to a **single
executable**: `runners/orchid-orchestrator-command`, the default-deny,
argument-validating broker. The broker admits a short list of exact read
forms (`task show`, `task list`, `status [--explain]`, `jobs review-plan`,
`journal tail`, `journal show`, `lessons list --active`, `run boundary
show`), the one judgment-result verb (`task arbitrate`), `journal add`,
`lessons add`, `notify`, and `run boundary clear` — and refuses `trust`,
`service`, `config`, `plugins`, `init`, `start`, every tier-2 runner, every
vendor CLI, and anything a shell would interpret. This adapter's manifest
therefore declares `command_surface=brokered`; adapters whose vendor CLI
offers no equivalent restriction declare `command_surface=soft`, and every
tick prints which of the two it just resolved.

This is a vendor-enforced restriction on **which command may run**, not
prompt policy — but it is not OS containment: the broker itself runs
unsandboxed, and the launcher's environment allowlist, stdin `/dev/null`
and private output path are what bound the rest. There is still no
filesystem jail or network namespace.

**What it does not cover: file writes.** `--allowedTools "Bash(<broker>:*)"`
scopes the Bash tool; `--permission-mode acceptEdits` leaves the vendor's own
file-write tools auto-approved. A woken orchestrator can therefore create and
edit files anywhere this process can reach — including paths under
`.orchid/`, and, when `ORCHID_ROOT` lives inside the driven repository (the
layout Orchid dogfoods itself in), including the broker script itself and the
rest of the Orchid tree. Reads are unrestricted too. The prompt tells the
orchestrator never to hand-edit `.orchid/` and never to touch a remote; those
are **prompt policy**, not enforcement. `brokered` claims exactly one thing —
that no command outside the broker can be executed — and nothing more.

For all of those reasons, direct/pump-driven
headless ticks remain separately denied until `orchid trust unattended`
records the operator's machine-local acknowledgement of the target
repository's prompt-injection risk — for `brokered` and `soft` adapters
alike.

The mechanical tick is no longer this model's job at all: `orchid drive`
(`runners/orchid-drive`) runs it deterministically, and the pump wakes an
orchestrator only for a named judgment boundary it refused to resolve.

`orchid_run_engine_cli` (`lib/heartbeat.sh`) backgrounds claude directly
(same reasoning as codex's adapter — real claude was also found to buffer
all output until exit) and runs a liveness heartbeat alongside it.

## Reviewer: the reply contract carries findings, not just a verdict

A `review` reply is asked for the same two line shapes a `critique` reply is:

```
VERDICT: approve OR request-changes
FINDING: <low|medium|high>: <title>      # zero or more; omit entirely if none
```

The adapter parses those `FINDING:` lines into the envelope's `findings[]`
(a line whose severity token is not exactly one of the three, or whose title
is empty, is dropped — this is a best-effort scrape, not a strict parser).
Before v1-m4 a review was asked for the `VERDICT:` line alone, so every
review envelope carried `findings: []` and the reviewer's reasoning survived
only if it happened to appear in prose in the engine log, which is reaped —
a real run lost three reported findings from a single review round that way.
The verdict contract is unchanged, and a review that reports no findings
still writes `findings: []`; that empty array blocks nothing, in the
driver's `blocking_severity` gate or anywhere else. Other shipped review
adapters remain verdict-only — see PROTOCOL.md's deterministic-approval arm
for which reviewer makes that gate live.

## Implementer: review-only in practice (adapter commits when it can)

`claude -p --permission-mode acceptEdits` creates/edits files but does
**not** run `git commit` — `acceptEdits` authorizes file edits, not the
Bash/commit step, in headless mode (`docs/dogfood-notes.md`'s probe
finding). The adapter (unsandboxed, like every implementer adapter here)
stages and commits claude's edits itself afterward — but since claude
itself never commits, **claude as the default implementer produces the
same envelope contract as codex's adapter, with one caveat**: if claude
edits nothing committable in a given attempt, the adapter's own empty-diff
check catches it (`status: failed`, "engine produced no changes") rather
than silently reporting success. `role.implementer`'s tested default is
`codex`, not claude, precisely because codex's sandbox is proven to commit
reliably headless; claude remains a capability-gated fallback (`orchid
plugins test claude implementer`) — see the
[any-engine-any-role matrix](../../README.md#any-engine-any-role).

## `orchestrate` (headless tick)

Requires `shell,git` (declared in `plugins/engines/claude/plugin.conf`).
The adapter feeds claude PROTOCOL.md's full text plus a fixed instruction
block naming the concrete `$worktree`/`$ORCHID_ROOT` paths (absolute —
dev checkouts may not have `orchid` on `PATH` at all) and greps the
transcript for `ORCHID-ACTION: <command>` lines into the envelope's
`actions[]`. Those transcript lines are observability, not proof that no
other command ran; there is no command broker in this release (T002 owns
that boundary).

## Known gotchas

- **`--permission-mode acceptEdits` does not authorize Bash.** This is the
  single most surprising thing about this adapter, and the reason the
  `orchestrate` branch's flags differ from the `implement` branch's — see
  above.
- **Claude headless does not self-commit.** Don't expect `git log` inside
  a claude-implemented task worktree to show a commit claude itself made —
  the adapter is what commits, always.
- **No `--skip-git-repo-check`-equivalent flag exists or is needed** —
  claude does not refuse an untrusted worktree the way codex does.

## Config keys

No claude-specific config keys — see [configuration.md](../configuration.md)
for the general `role.*` routing keys that decide when this engine is
invoked at all.
