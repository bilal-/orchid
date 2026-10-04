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
  `skills/{orchid,orchid-plan,orchid-resume}` register for Claude Code, Codex,
  Hermes, and OpenCode through the per-user installer.
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

**Interactive front-end: portable skills and native session registration are
implemented.** Current Codex discovers the user skills in `~/.agents/skills`.
Explicit `orchid setup --frontend codex` registers read-only session context in
`~/.codex/hooks.json`; review it with Codex's `/hooks` before use. The registration
and callback contract have disposable fixture coverage. A genuine interactive
Codex session driving Orchid end to end remains unqualified. This is separate
from the historical implementer and headless observations above.

See [engines/codex.md](./engines/codex.md) and
[engines/codex-review.md](./engines/codex-review.md).

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

## Install and session discovery

`install.sh` links the same three small, portable skills (`orchid`,
`orchid-plan`, `orchid-resume`) into the shared `~/.agents/skills` directory.
Current Codex uses this user path; generic shell agents can discover the same
skills or run `orchid --help` directly. When a host's profile already exists,
the installer also wires its native skills path:

| Host | Native user skill path | Setup command | Explicit session integration |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/skills/<name>` | `orchid setup --frontend claude` | `SessionStart` command in `~/.claude/settings.json` |
| Codex | `~/.agents/skills/<name>` | `orchid setup --frontend codex` | `SessionStart` command in `~/.codex/hooks.json` |
| Hermes | `~/.hermes/skills/orchestration/<name>` | `orchid setup --frontend hermes` | `pre_llm_call` shell hook in `~/.hermes/config.yaml` |
| OpenCode | `~/.config/opencode/skills/<name>` | `orchid setup --frontend opencode` | Local `~/.config/opencode/plugins/orchid.js` plugin |

The installer leaves foreign files and links alone, including dangling links.
It creates the shared skills path even before an agent is installed. It does
not create absent vendor profiles or enable session integrations. OpenClaw's
answering skill remains a separate, manually registered bundle; when OpenClaw
is present, the installer prints the suggested registration command.

Session integration is an explicit per-user operation:

```sh
orchid setup
```

This command only reports registration state. Choose your host's setup command
from the table to register it. `orchid setup --frontend all` explicitly
configures all four profiles, creating missing profile directories, and needs
Hermes's Python runtime with PyYAML even when no Hermes profile exists. Every
selected configuration is validated before any profile is edited. You can
reverse a selected registration with its setup command plus `--uninstall`.
Setup responses put runnable commands in `next` and prerequisites or host
approval directions in `notes`. Successful setup and uninstall point back to
the read-only `orchid setup` overview.

The selected setup commands
register a bounded, optional callback that runs `orchid context --ambient` in
the host's working directory. This provides compact ambient context and the
next useful command. It reads existing Orchid state and is silent outside an
initialized Orchid repository. It does not initialize a project, acquire an
epoch, check or signal jobs, reconcile, drive, or launch work. Missing, failed,
oversized, or timed-out context produces no extra prompt. Context checks the
ownership of its project inputs before reading them, including inputs used by
the existing jobs and orchestration-policy readers. Linked files, linked or
dangling ancestors, and job references outside the owned runtime refuse with
an error; unsafe state is unavailable rather than reported as empty. User
configuration, installed engines and qualification records remain
operator-controlled machine inputs. This read gate does not grant trust to
project file contents or execute project code. Claude and Codex get
native `SessionStart` JSON; Hermes gets native `{"context":"..."}` JSON; OpenCode
appends the context to its system prompt through its plugin hook. Host callback
JSON is independent of Orchid's default TOON command output.

The three installed skills are on-demand entry points for discovering commands,
planning a project, and resuming a run. An agent without native skills can use
the same CLI help and protocol interface. Installing or registering Orchid is
not permission to start a run; the normal command contracts, evidence gates,
and operator authorization still apply.

### Native trust and compatibility

Restart the selected host after registration. **Codex** keeps hook trust in its
own review workflow: open `/hooks` and approve the registered definition.
Current Codex hooks are enabled by default; Orchid does not modify TOML feature
flags or native approval records. **Hermes** prompts for approval of its native
shell-hook command when first used; approve it in Hermes. Orchid does not write
`shell-hooks-allowlist.json` or turn on fail-closed behavior. Claude and OpenCode
retain their normal host trust and project controls.

Hermes registration parses YAML using its Python runtime and PyYAML. Setup
looks for the usual Hermes `hermes-agent/venv/bin/python` or `.venv/bin/python`
under `HERMES_HOME`, then a `python3` with PyYAML. For another installation,
set `ORCHID_FRONTEND_PYTHON` to its executable Python interpreter. Missing
PyYAML or malformed/unsupported config is refused before any selected profile
is edited. The YAML editor preserves unrelated source bytes and comments;
Top-level flow-style YAML and aliases for the managed hook mapping/list must
first be changed to an explicit block mapping/list. Ambiguous duplicate managed
entries are refused rather than removed using an old ownership record.

OpenCode's local plugin uses the current
`experimental.chat.system.transform` typed plugin hook. Its experimental name
is a compatibility limit: future OpenCode releases may change it. The plugin
uses only native `node:child_process`, with a three-second timeout and an
8 KiB output bound; it requires no plugin dependency downloads.

`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `HERMES_HOME`, and `XDG_CONFIG_HOME` select
native profiles for setup; `CLAUDE_SKILLS_DIR` still overrides Claude skill
installation. Homebrew-generated registrations use the stable
`opt/orchid/libexec` path when it resolves to the active Cellar installation.
Re-running setup repairs an owned registration after source relocation. A
moved profile requires uninstalling from its previous profile first.

Registration records and small callback files live in `~/.orchid/frontends`.
Setup preflights every selected host before editing profiles. Existing
registration files must match their recorded contents; changed files or
foreign hook definitions are refused. `--uninstall` removes only recorded
entries and files, retaining foreign hooks, settings, user preferences, and
host approval stores. `install.sh --uninstall` also reverses owned native
registrations and owned skill links.

Setup records a pending registration before publishing its callback or native
configuration, then finalizes the record after both succeed. An interrupted
setup remains visible as pending in `orchid setup`; repeat the same setup to
complete it, or uninstall its owned entries. During relocation, a pending
record recognizes the exact previously owned callback as well as its intended
replacement. Changed callback bytes still cause refusal. Completed records
retain ownership of only the current callback.

### Qualification evidence

Disposable tests exercise native config formats, callbacks, host working
directories, malformed input, ownership refusal, idempotence, source relocation,
stable Homebrew paths, and safe uninstall. Hermes uses real PyYAML and OpenCode's
plugin runs under Node when those native test prerequisites are present;
missing prerequisites are explicitly reported `NOT-TESTED`.
`ORCHID_REQUIRE_NATIVE_FRONTENDS=1 /bin/bash tests/test_frontend_setup.sh`
requires both for four-host local qualification. These fixtures do not prove a
live host session or a genuine third-party beta. Historical adapter and
skill-discovery observations above remain historical evidence.

The integration formats are grounded in current primary documentation:
[Claude hooks](https://code.claude.com/docs/en/hooks),
[Codex hooks](https://learn.chatgpt.com/docs/hooks),
[Codex skills](https://learn.chatgpt.com/docs/build-skills),
[Hermes shell hooks](https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks/),
[OpenCode plugins](https://opencode.ai/docs/plugins/),
[OpenCode skills](https://opencode.ai/docs/skills/), and
[OpenCode's typed plugin hook](https://github.com/anomalyco/opencode/blob/dev/packages/plugin/src/index.ts).
