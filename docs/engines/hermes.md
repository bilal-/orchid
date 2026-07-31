# orchid/hermes — engine guide

Status: **review/critique only** (v1-m4 Task 6, build-only). `implement` is
NOT wired up yet — see "Why no `implement` yet" below. This is the adapter
this guide covers: `plugins/engines/hermes/run`.

## Install

```sh
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

Verified during this task against **Hermes Agent v0.19.0** (installed at
`~/.local/bin/hermes`, `hermes --version`). `orchid doctor` reports a
missing `hermes`/`jq` binary against this guide (`requires_binaries=hermes,jq`
in `plugins/engines/hermes/plugin.conf`).

## Login / provider setup

Hermes has no single `hermes login` subcommand — auth lives under:

- `hermes setup` — interactive wizard (model/provider, TTS, terminal,
  gateway, tools, telemetry). Run once after install.
- `hermes setup model` — just the model/provider picker.
- `hermes auth add/list/remove/status/logout <provider>` — manage pooled
  provider credentials directly.
- `hermes status` / `hermes status --deep` — readiness check across every
  configured component.

orchid never manages this — it only invokes `hermes` and reads its exit
code/stdout, exactly like the other engine adapters (docs/specs/plugins.md's
trust model).

## Flags orchid uses, and why

Every real invocation from `plugins/engines/hermes/run` is exactly:

```sh
hermes --safe-mode -t clarify -z "<prompt>"
```

- **`-z/--oneshot PROMPT`** — the probed, working headless one-shot form:
  `hermes --safe-mode -z "Reply with exactly: ORCHID-PROBE-OK"` returns
  exactly `ORCHID-PROBE-OK` on stdout, nothing else (no banner/spinner/
  session line). The prompt is passed as a plain trailing argv value, not
  via stdin — every prompt this adapter builds starts with a fixed literal
  (`"Acceptance criteria: "` or `"Requirements:\n"`), never a raw `---`
  frontmatter body the way codex/claude's *own* prompts sometimes do, so
  there is no leading-dash argv-parsing risk here to route around with a
  stdin trick.
- **`--safe-mode`** — disables plugins, MCP servers, and injection of the
  user's own `config.yaml`/`AGENTS.md`/memory/preloaded skills for this
  invocation (`hermes --help`: "Troubleshooting mode: disable ALL
  customizations"). Reduces what an untrusted target repo's own config
  could inject into a review run.
- **`-t clarify`** — the adapter's REAL tool-visibility restriction, and
  the single most important flag-research finding of this task (see below).
  `clarify` is the one built-in hermes toolset whose tool list
  (`toolsets.py`'s `TOOLSETS["clarify"]`) is exactly one tool — asking the
  user a clarifying question — with no file, terminal, network, or shell
  reach at all. In one-shot mode there is no user to answer, so even a
  noncompliant reply that tries to call it gets back an inert
  "not available in this execution context" tool error, never a hang.
  Every prompt this adapter builds also carries its own "do not use any
  tools" instruction (agy-style), but that line is advisory only — see the
  next section for why it can't be trusted alone with hermes.

Nothing more. There is no `--model`/`--provider` override (uses whatever the
operator configured via `hermes setup`), and every review/critique call runs
from the adapter's OWN cwd (never `cd`'d into the request's worktree) — see
the capability note below.

## Why hermes needs a REAL toolset restriction, not just a prompt instruction

This is specific to hermes among orchid's built-in engines, and is the load-
bearing finding of this task's flag research (done by reading
`hermes --help` plus the installed CLI's own source under
`~/.hermes/hermes-agent/` — never by spending real quota on a live prompt):

- **`-z`/one-shot mode unconditionally auto-bypasses tool approvals.**
  `hermes_cli/oneshot.py`'s own docstring: "Approvals = auto-bypassed
  (`HERMES_YOLO_MODE=1` is set for the call)." This is true regardless of
  `--safe-mode`/`--yolo`/anything else — one-shot mode is *always* effectively
  yolo. Contrast:
  - `codex exec --sandbox read-only` — a real, enforced read-only sandbox.
  - `claude -p` with no `--permission-mode` flag — tool calls require
    interactive approval, which auto-denies in headless mode (this is WHY
    claude's own review path is safe by default, and why its implement path
    has to explicitly opt in via `--permission-mode acceptEdits`).
  - hermes has **no headless mode that denies-by-default or enforces a
    read-only sandbox**. Whatever toolset is active WILL execute, silently,
    if the model decides to call it.
- Given that, this adapter cannot lean on hermes's own defaults or on the
  prompt's "do not use tools" instruction alone (unenforced free text) the
  way `plugins/engines/agy/run` and the review branches of
  `plugins/engines/{codex,claude}/run` do — those either have no tool access
  to begin with (agy) or a real enforced/default-deny mechanism (codex/
  claude). `-t clarify` closes that gap: a technical guarantee, verified by
  reading `toolsets.py`, that no filesystem/network/shell-capable tool is
  even present in the model's schema for this call, not just discouraged.

## Why review/critique is fully inline (no worktree access), unlike codex/claude

`plugins/engines/{codex,claude}/run`'s review path `cd`s into the request's
worktree and declares the `workspace_read` capability. This adapter does
NOT — `plugins/engines/hermes/plugin.conf` declares only
`capabilities=structured_text`, the same as `plugins/engines/agy/run`.

Reason: `docs/specs/plugins.md`'s "Worktree-read review packs" section says
that when the RESOLVED engine declares `workspace_read`, an oversized diff
gets swapped for a `diff.stat` summary on the assumption the engine can
browse the checkout itself to fill in the rest. With tool visibility cut
down to `-t clarify`, hermes genuinely cannot do that — declaring
`workspace_read` here would be a capability the adapter can't actually back
up. So this adapter stays fully inline (agy-style): the whole pack travels
in the prompt text, an oversized `diff.patch` fails closed via the
`hermes_max_bytes` byte guard (config key, default 100000, env override
`ORCHID_HERMES_MAX_BYTES` — identical shape to agy's `agy_max_bytes`) rather
than being silently truncated, and the router falls back to a
worktree-capable reviewer (codex/claude) for anything that trips it.

## Why no `implement` yet

The task brief for this adapter asked for the MOST RESTRICTIVE write-enabled
invocation, established from `hermes --help` (and, since it doesn't spend
real quota, the installed CLI's own source) alone — not a guess. That
research could not establish one:

- `-z` is always yolo (see above) — there is no way to make hermes ask
  before writing a file or running a command in one-shot mode.
- `--worktree`/`-w` looks at first glance like "operate in this worktree,"
  but `hermes --help` is explicit that it means the opposite: "Run in an
  ISOLATED git worktree (for parallel agents)" — hermes creates its OWN NEW
  worktree, a different checkout entirely, not the one orchid's launcher
  already prepared and expects the adapter to commit into (the F3 pattern
  every other `implement` branch in this codebase relies on). Passing it
  would silently point hermes at the wrong repository.
- `-t file` (or any toolset including `write_file`/`patch`) enables real
  writes, but `tools/file_tools.py`'s own path resolution
  (`_path_resolution_warning`) only **warns** when a *relative* path
  resolves outside the workspace root — a resolved *absolute* path is never
  blocked at all. There is no `--sandbox`/`--jail`/`--allowed-root` flag
  anywhere in `hermes --help` to close that gap.

No combination of documented flags confines a write to the request's
worktree. Per the task brief's own principle — "an honest narrower adapter
beats a guessed broad one" — this adapter ships review/critique-only rather
than a write-enabled invocation nobody actually verified is safe.
`plugins/engines/hermes/plugin.conf` declares
`capabilities=structured_text` only (no `workspace_write`, no `shell`, no
`git`) precisely so the resolver's capability math can never route an
`implement`/`orchestrate` role to it. **This is a BUILD-only task; the live
dogfood (a later controller task) is where a real round trip against the
installed CLI would be run** — if a future hermes version ships a genuine
sandbox/jail flag, or the live dogfood turns up one this research missed,
revisit this section and `plugins/engines/hermes/run`'s `implement` gate
together. Until then, `tests/probes/probe-hermes.sh`'s implement-shaped probe
exists specifically to re-check the relative-path-write behavior above
against the real CLI without ever asserting the absolute-path question is
answered (see that probe's own header).

## `orchestrate`

Not offered. `plugins/engines/hermes/plugin.conf` declares neither `shell`
nor `git`, so by `docs/specs/plugins.md`'s capability math (`orchestrate`
requires BOTH), hermes is orchestrator-ineligible regardless of the
`implement` question above.

## Known gotchas

- **One-shot mode is always yolo.** Don't be misled by `--safe-mode`'s name
  into thinking it adds any tool-execution guardrail — it only strips
  config/plugin/MCP injection. See "Why hermes needs a REAL toolset
  restriction" above.
- **`--worktree`/`-w` does not mean "use this worktree."** It means "make me
  a new one." Never pass it expecting cwd-scoping.
- **`-t` is all-or-nothing per call, not additive to config.** An explicit
  `--toolsets`/`-t` value REPLACES whatever's configured for that one
  invocation (`hermes_cli/oneshot.py`); it does not layer on top.
- **An unresolvable `-t` name is a hard usage error (exit 2), not "no
  tools."** There is no `-t none`/`-t ""` that yields zero tools — passing
  an empty or unrecognized toolset name fails the whole invocation rather
  than silently disabling everything. `-t clarify` is deliberately a real,
  valid, minimal toolset for exactly this reason.
- **`hermes tools list`** (no prompt, no quota spent) is the fastest way to
  see what's enabled for the CLI platform on a given machine/config — useful
  for confirming `-t clarify` actually narrows things down versus whatever
  the operator has configured by default.
- **File tools refuse a macOS `mktemp -d` scratch dir outright.** A live
  v1-m4 dogfood run found `-t file` rejecting every write under
  `/var/folders/…` (macOS's `mktemp -d`/`$TMPDIR`) as "classified as a
  sensitive system path" — rc 0, no marker file, nothing written. Any
  scratch experiment against hermes's file tools needs a directory under
  `$HOME` instead; `tests/probes/probe-hermes.sh`'s implement-shaped half
  is affected by exactly this (see that probe's header comment).

## Config keys

- `hermes_max_bytes` (default `100000`) — `diff.patch` byte ceiling above
  which this adapter fails closed rather than invoking hermes (mirrors
  `agy_max_bytes`). Env override: `ORCHID_HERMES_MAX_BYTES`.

## Notify channel

Status: **build-only** (v1-m4, sibling task to the one above). This is a
*second*, unrelated plugin that also happens to wrap the `hermes` CLI:
`plugins/notify/hermes/send`, a `kind=notify` channel plugin
(`plugins/notify/hermes/plugin.conf`, `id=orchid/hermes-notify` —
deliberately NOT `orchid/hermes`, to avoid colliding with this page's own
engine plugin's id; `orchid plugins list`'s collision check is keyed on id
across every discovered plugin regardless of kind). It has nothing to do
with the `implement`/`review`/`critique` engine adapter documented above —
it drives `hermes send`, a separate, no-LLM message pipe subcommand that
reuses the gateway's own already-configured platform credentials
(`~/.hermes/.env` + `~/.hermes/config.yaml`); no agent loop, no running
gateway required for bot-token platforms (Telegram/Discord/Slack/Signal).

The OUTBOX pattern this plugin fits into — why `orchid notify` (tier-1)
never spawns anything itself, how `runners/orchid-pump` (tier-2) drains
`runtime/outbox/<qid>` by launching a channel plugin's `send`, retry/
quarantine via `send_retry_max`, and the inbox-hardening (`orchid answer`
nonce/allowlist/expiry) story on the way back in — is documented once, in
[openclaw.md](./openclaw.md), and not repeated here; that pattern is
channel-agnostic and this plugin fits it exactly the same way.

**One difference from openclaw worth calling out:** openclaw's `notify.to`
is mandatory (its `send` dies without a `--target`). Hermes has its own
notion of a "home channel" per platform (`~/.hermes/config.yaml`), so
`notify.to` is **optional** for this plugin — when empty, `send` passes the
bare platform name as `--to` and hermes routes to that platform's home
channel; when set, `send` composes `<channel>:<to>`.

```
notify.plugin=hermes    # selects THIS plugin (default is openclaw -- see below)
notify.channel=telegram
notify.to=              # optional here (unlike openclaw) -- home channel if empty
```

- `notify.plugin=hermes` — `hermes` here is the plugin's **directory name**
  under `plugins/notify/` (`plugins/notify/hermes`), not this plugin's
  manifest id (`orchid/hermes-notify`) and not the kind=engine hermes
  adapter documented above. `runners/orchid-pump`'s outbox drain resolves
  this the same way any other notify plugin lookup works
  (`resolve_notify_dir`); leaving `notify.plugin` unset keeps the default,
  `openclaw`, so configuring `notify.channel`/`notify.to` alone (with no
  `notify.plugin` line) still drives the openclaw plugin, exactly as
  before this key existed.
- `notify.channel` (default empty) — a hermes platform name recognized by
  the operator's own `~/.hermes/config.yaml` (whatever `hermes send --list`
  shows configured — e.g. `telegram`, `discord`, `slack`, `signal`).
- `notify.to` (default empty) — a chat id (`-100123456789`), a
  `#channel-name` (Discord/Slack), or an E.164 number (Signal); composed
  onto `notify.channel` as `<channel>:<to>`. **Optional for this plugin** —
  unlike openclaw, where it's required — left empty, the platform's home
  channel is used instead.

**The verified invocation**, per `hermes send --help` (Hermes Agent v0.19.0,
help text only — no real `hermes send` has been run by this task):

```sh
hermes send --to <channel[:to]> "<text>"
```

`plugins/notify/hermes/send`'s own header comment carries the full flag
research (the `-t`/`--to` target-format grammar, exit codes 0/1/2, no
`--dry-run` flag exists) so the adapter and this doc can't drift.

**Known gotchas / PENDING-VALIDATION**, same shape as openclaw's own list:
this invocation has not yet been run against a live, configured Hermes
gateway with a real platform connected — that live round trip is a later
controller task (hero-demo dogfood), not this build task. `notify.plugin`
must actually be set to `hermes` for the pump to launch this plugin at all
— leaving it unset (or setting `notify.channel`/`notify.to` alone, the way
the openclaw section above documents) still drives the openclaw plugin,
since `openclaw` remains `notify.plugin`'s default.

## See also

- [../../README.md#any-engine-any-role](../../README.md#any-engine-any-role) —
  where hermes sits in the capability-eligibility matrix (`reviewer`,
  `plan_critic`; not `implementer`/`orchestrate` — see above).
- [../configuration.md](../configuration.md) — the general `role.*`/
  `review.<tier>` keys that decide when this engine is actually invoked.
- [../troubleshooting.md#pack-overflow](../troubleshooting.md#pack-overflow) —
  what happens when a diff exceeds `hermes_max_bytes`.
- [agy.md](./agy.md) — the other inline-only (no worktree-read) reviewer,
  same byte-ceiling shape.
- [openclaw.md](./openclaw.md) — the shipped reference notify-channel plugin
  and the OUTBOX pattern this section's plugin is a sibling of (retry/
  quarantine, inbox hardening, the `orchid answer` nonce/allowlist/expiry
  story) — documented there once, not duplicated here.
