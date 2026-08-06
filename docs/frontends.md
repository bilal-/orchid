# Driving orchid from any agent

Orchid's kernel/verbs/roles are engine-neutral by construction: a role is a
capability requirement (`shell`, `git`, `workspace_write`, `structured_text`),
never a hardcoded vendor name, and any engine whose adapter declares enough
capability can hold any role (`README.md`'s
[any-engine-any-role](../README.md#any-engine-any-role)). This page is the
other half of that promise — which agent *products* can sit in the driver's
seat today, what's actually been proven live versus what's true "by
construction" but not yet exercised, and how `install.sh` wires each one up.

## Two front-end modes

Every front-end — an interactive Claude Code session, a headless pump tick,
a human typing verbs by hand — executes the exact same procedure,
`PROTOCOL.md`, by running the commands it names, in the order given
(`PROTOCOL.md`'s own opening paragraph: *"Any front-end — a Claude Code
skill, a codex-driven tick runner, a human typing commands — executes this
procedure..."*). There are exactly two shapes this takes:

- **Interactive session** — an agent CLI (Claude Code, or any other) running
  in a terminal, told (via a skill, an `AGENTS.md` pointer, or a person just
  reading the file) to open `PROTOCOL.md` and drive it. This is the front-end
  `skills/{orchid,orchid-plan,orchid-resume}` wire up for Claude Code today.
- **Headless tick** — `runners/orchid-pump` wakes an abandoned run and hands
  off to `runners/orchid-tick`, which resolves the orchestrator role to a
  vendor CLI and feeds it PROTOCOL.md's text plus a fixed instruction block,
  exactly once, no human in the loop. Both runners require the separate
  machine-local `orchid trust unattended` acknowledgement (`PROTOCOL.md`'s
  **HEADLESS OPERATION** section).

Neither mode is more "real" than the other — they're the same procedure, two
different callers. See `PROTOCOL.md` itself for the full THE TICK / RESUME /
HEADLESS OPERATION procedures this page never restates. Orchid's supported
source paths use the one-way topology drawn in
[architecture.md](./architecture.md) (diagram 1, "Who runs whom"). That
diagram is not an OS sandbox or command broker for a shell-capable engine.

## Per-engine status

Labels used below, honestly, not aspirationally:

- **tested** — driven live, end-to-end, in this project's own dogfood record
  (`docs/dogfood-notes.md`), in the role described.
- **works-by-construction** — the adapter code and declared capabilities
  exist and would pass the same capability math every engine goes through
  (`docs/specs/plugins.md`), but the path has not been exercised live in
  that role.
- **untested** — a real, describable path that has not been tried at all —
  named honestly as a gap, not a claim.
- **not eligible** — the engine's own declared capabilities structurally
  cannot satisfy the role's requirements (`docs/specs/plugins.md`'s
  capability math), so no capsuite run could ever pass it. Not a gap; a
  correct restriction.

### claude — Claude Code

**Interactive orchestrator front-end: tested (today's default).** The
`orchid`/`orchid-plan`/`orchid-resume` skills (`install.sh` step 1) are
themselves executed by a Claude Code session; the m4 release rehearsal ran
the full clone → install → doctor → plan → implement → review → merge →
accept path this way in 13m19s
(`docs/dogfood-notes.md`'s "v1-m4 Task 12 — release rehearsal"). Claude also
holds `role.orchestrator`'s tested-default **headless** binding — a
pump-driven `claude -p --allowedTools Bash` tick ran the full COMPLETION
procedure unattended after F8's fix (`docs/dogfood-notes.md`'s v1-m2 (c),
"the autonomy loop is real"). Since v1.1 that wholesale `Bash` grant is
gone: the headless tick allowlists only the brokered command surface
(`runners/orchid-orchestrator-command`), which is why this adapter's
manifest declares `command_surface=brokered`. It is also woken far less
often — `orchid drive` runs the mechanical tick deterministically, and the
pump reaches an LLM only at a named judgment boundary. See
[engines/claude.md](./engines/claude.md).

### codex

**Implementer: tested (today's default)** — real `codex` implemented tasks
end-to-end across every live dogfood run cited above and in
[engines/codex.md](./engines/codex.md).

**Headless orchestrator: works-by-construction, untested live.**
`plugins/engines/codex/run`'s `orchestrate` branch exists and declares
`shell,git` (`engines/codex.md`'s "`orchestrate` (headless tick)" section),
and `docs/specs/operations.md`'s operator walkthrough names it as a valid
alternative to the Claude Code front-end (*"with codex as orchestrator:
`orchid run start && runners/orchid-tick`"*). But the headless tick actually
proven live end-to-end used **claude**, not codex (v1-m2 (c) above, and the
m4 rehearsal used the interactive Claude Code front-end too) — and
`docs/specs/roadmap.md`'s own "Verification findings" section lists
"codex-as-orchestrator subprocess/git under sandbox" as explicitly
**unproven** ("capability suite exists because this is unproven"). Bind it
(`role.orchestrator=codex,claude`) the same capability-gated way as any
non-default role — `orchid plugins test codex orchestrator` first (see the
[worked example](../README.md#any-engine-any-role)) — and expect to hit a
blocker requiring an operator answer the same way any orchestrator does
(`docs/troubleshooting.md#blocked-tasks`) if something the sandbox can't do
comes up.

**Interactive front-end: untested, describable.** Nothing in this repo
wires codex's own `AGENTS.md` convention up to PROTOCOL.md today. The
pattern would mirror the Claude Code skill: an `AGENTS.md` at the repo root
telling an interactive `codex` session to read `PROTOCOL.md` and drive it by
running the verbs named there. Nobody has tried this — label it exactly
that, not "supported."

See [engines/codex.md](./engines/codex.md) and
[engines/codex-review.md](./engines/codex-review.md) (the review-only
identity wrapping the same adapter).

### agy (Google Antigravity)

**Reviewer: tested (today's default)** — `review.low=agy`, real `agy -p`
reviews across every dogfood run, including the F6 fix for its empty-reply
failure mode (`docs/dogfood-notes.md`; [engines/agy.md](./engines/agy.md)).

**Orchestrator: not eligible, not just "untested."**
`plugins/engines/agy/plugin.conf` declares `capabilities=structured_text`
only — no `shell`, no `git`, no `workspace_write`. `orchid`'s capability
math (`docs/specs/plugins.md`) requires `shell,git` for `orchestrator` and
`workspace_write,shell,git` for `implementer`; agy satisfies neither, so no
capsuite run (`orchid plugins test agy orchestrator`) could ever pass it —
the resolver's own `capsuite_passed` gate (`lib/resolver.sh`,
`lib/capsuite.sh`) would refuse it structurally, not just because nobody's
tried. This isn't a gap to fill; it's what the vendor CLI's own posture
(print-mode auto-denies every tool call — see `engines/agy.md`) makes
correct.

See [engines/agy.md](./engines/agy.md).

### hermes (Hermes Agent)

**Reviewer/critique: tested.** `role.reviewer=hermes` and
`role.implementer=hermes,codex` both ran real live tasks to
`run_status: complete` (`docs/dogfood-notes.md`'s "v1-m4 Task 9 — Hermes
live dogfood"; `plugins conform` 7/7, capsuite hermes-reviewer PASS).
`implement` itself is **not offered** by this adapter — see
[engines/hermes.md](./engines/hermes.md)'s "Why no `implement` yet" for the
honest reasoning (no documented flag confines a write to the task's
worktree).

**Interactive orchestrator front-end via `install.sh`: tested, this task.**
Verified live against Hermes Agent v0.19.0: `hermes skills list` discovers
a **symlinked** skill directory under `~/.hermes/skills/<category>/<name>/`
and reads `name`/`description` straight out of `SKILL.md` frontmatter
(hermes's own skill-discovery walk follows symlinks) — all three of
`skills/{orchid,orchid-plan,orchid-resume}`'s minimal Claude-Code-shaped
frontmatter (just `name` + `description`, no Claude-only keys) round-tripped
this way, each listed `enabled`/`local` under a new `orchestration`
category. `install.sh` now symlinks them into
`~/.hermes/skills/orchestration/` whenever `~/.hermes/skills` exists (see
"Install wiring" below). This is a different claim from the one the m4
hero-demo dogfood already proved: that dogfood installed
`skills-external/openclaw-orchid/SKILL.md` — the **answering** AgentSkill,
not an orchestrator front-end — into hermes as a plain copy, not a symlink
(`docs/dogfood-notes.md`'s v1-m4 Task 10: *"The same SKILL.md installed
unmodified into hermes (`~/.hermes/skills/orchestration/orchid/`)"*). Skill
discovery is proven for both shapes now; actually driving a full tick
through a hermes session reading these three skills has not been dogfooded
end-to-end — the same "describable, not yet a live run" gap the codex
interactive path above has.

**Headless orchestrator: not eligible.** `plugins/engines/hermes/plugin.conf`
declares neither `shell` nor `git` — same structural non-eligibility as agy
above (`engines/hermes.md`'s own "`orchestrate`" section: "Not offered").

**Notify channel: tested live**, despite `engines/hermes.md`'s own "Notify
channel" section still carrying a pre-hero-demo "build-only,
PENDING-VALIDATION" label (written before the live run below; a known
staleness in that page, out of scope here). A second, unrelated plugin
(`plugins/notify/hermes`) proved three real outbound sends over Telegram —
`orchid notify` → outbox → `runners/orchid-pump` drain → `hermes send -t
telegram` → operator's phone, ~2s per message — plus a full nonce-hardened
answer round trip (`docs/dogfood-notes.md`'s "v1-m4 Task 10 — hero demo",
F18).

See [engines/hermes.md](./engines/hermes.md).

### openclaw (OpenClaw)

**Notify channel (`plugins/notify/openclaw`): untested live, honest
PENDING-VALIDATION.** The hero demo's live outbound proof (three real sends
over Telegram, `docs/dogfood-notes.md`'s v1-m4 Task 10) configured
`notify.plugin=hermes` — the *sibling* channel plugin
(`plugins/notify/hermes`, see [hermes.md](./engines/hermes.md)) — not this
one. OpenClaw's own `openclaw message send` invocation remains verified
against installed `--help` text only; no real send has been run
([engines/openclaw.md](./engines/openclaw.md)'s own "Known gotchas /
PENDING-VALIDATION").

**The answering AgentSkill (inbound, `skills-external/openclaw-orchid/`):
registration tested, the OpenClaw-side answer leg not yet.** Registered
live into a local OpenClaw instance (`openclaw skills install <dir>` →
enabled, ✓ Ready — `docs/dogfood-notes.md`'s Task 10) — but the
question-answer round trip itself was proven over **hermes**-Telegram, not
OpenClaw's own channel: "OpenClaw answer leg untested — no chat channel
paired yet" (same Task 10 entry; the hermes-side proof is F18). Register the
same bundle into hermes or OpenClaw interchangeably — the format is
portable — but only the hermes-Telegram round trip has a live answer
proven end-to-end so far.

**As an orchestrator (interactive or headless): untested, not attempted.**
There is no OpenClaw-shaped orchestrator skill in this repo — only the
answering AgentSkill above, which is deliberately scoped to exactly two
read-only/nonce-gated operations
(`skills-external/openclaw-orchid/SKILL.md`'s own header: *"no shell, no
repo file access beyond those two orchid subcommands"*). `install.sh`
reflects this honestly: it never suggests registering an orchestrator role
for OpenClaw, only the answering skill (see "Install wiring" below).

See [engines/openclaw.md](./engines/openclaw.md).

## Which engine in which role

Don't duplicate the matrix here — see
[README.md#any-engine-any-role](../README.md#any-engine-any-role) for the
full capability table (tested defaults, fallback chains, and every built-in
engine's eligible roles), and the "Worked example" there for how to bind and
capsuite-verify a non-default engine into any role before trusting it.

## Install wiring

`install.sh` auto-detects and wires:

- **Claude Code** — if `~/.claude` exists (or `CLAUDE_SKILLS_DIR` is set),
  symlinks `skills/{orchid,orchid-plan,orchid-resume}` into
  `$CLAUDE_SKILLS_DIR` (default `~/.claude/skills`). Absent: skipped with a
  one-line note; `~/.claude` is never created by this script.
- **Hermes** — if `~/.hermes/skills` exists, symlinks the same three skills
  into `~/.hermes/skills/orchestration/<name>/`. Absent: skipped with a
  one-line note; `~/.hermes` is never created by this script.
- **OpenClaw** — if the `openclaw` binary is on `PATH` and `~/.openclaw`
  exists, prints an `openclaw skills install <repo-path>/skills-external/
  openclaw-orchid --as orchid` command as a suggested next step (never run
  automatically — it targets a specific agent/gateway, which `install.sh`
  has no business choosing non-interactively).

`--uninstall` reverses exactly the symlinks it created, for whichever
front-ends were actually wired (`tests/test_install.sh`'s front-end
presence-detection cases cover all three combinations: Claude-only,
Hermes-only, neither).

Manual one-liners for everything `install.sh` doesn't wire:

- **codex** — no skill to install; point an interactive session at
  `PROTOCOL.md` yourself (an `AGENTS.md` pointer, untested — see above), or
  bind `role.orchestrator=codex,claude` in `orchid.config` for the headless
  pump path after capsuite-verifying it
  (`orchid plugins test codex orchestrator`).
- **agy** — reviewer/critic only; nothing to install beyond the CLI itself
  (`engines/agy.md`'s Install section) — it is not, and cannot become,
  orchestrator-eligible (see above).
- **OpenClaw as an answering agent** — register the AgentSkill bundle
  yourself: `openclaw skills install <this-repo>/skills-external/openclaw-orchid
  --as orchid` (`skills-external/openclaw-orchid/README.md` has the full
  configuration walkthrough — repo path, sender id, `answer_allowlist`).
