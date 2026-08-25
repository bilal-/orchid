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
channel; when set, `send` composes `<channel>:<to>`. That difference is
declared, not assumed: this plugin's manifest carries
`requires_config=notify.channel` while openclaw's carries
`notify.channel,notify.to`, and `orchid doctor` checks whichever plugin is
actually configured against its own declaration before reporting outbound
`ok`.

**This plugin ships an inbound probe** (`inbound_probe=--inbound-probe` in
its manifest, see docs/specs/plugins.md) — see "The inbound probe" below for
what it asks and what its answer is worth. Note that `hermes send --list` is
*not* what it asks: that enumerates configured platform credentials, an
outbound-config fact that would prove nothing about whether a reply can get
back.

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

## The inbound probe (`orchid doctor` checks the return leg)

Sending and receiving are different facts with different requirements, and
for *this* plugin they are unusually far apart. `hermes send` talks to the
platform's bot-token API directly with the gateway's stored credentials and
needs no running gateway at all; a reply coming back is delivered to the
gateway process, which is what would hand it to a channel-side agent. So
hermes can send perfectly while the return leg is dead — which is exactly
what happened on r-001: the gateway was down for a day, blockers kept
arriving on the operator's phone, and the answer typed back was lost with
**no local trace at all** (lesson L011). Hermes was the channel that run
actually delivered on, and the channel that swallowed that answer.

`hermes gateway status` is the CLI's own report of that fact, so this plugin
declares a probe rather than asserting "no way to tell" on behalf of a CLI
that can tell:

```sh
plugins/notify/hermes/send --inbound-probe    # what doctor invokes; sends nothing
hermes gateway status                         # what the probe asks
```

- **exit 0 — REACHABLE.** The judged status line reports the gateway
  running/connected/online/ready/active/healthy.
- **exit 1 — NOT REACHABLE.** `hermes gateway status` failed (gateway not
  running, socket refused, auth expired), or it answered and the judged line
  carries a negation (`not running`, `stopped`, `disconnected`, `inactive`,
  `offline`, `expired`, `down`, `unreachable`, `unhealthy`, …).
- **exit 2 — UNDETERMINED.** The `hermes` CLI isn't on `PATH`,
  `notify.channel` is unset, this build has no `gateway status` subcommand,
  the command printed nothing, or none of the candidate lines below is one
  the probe recognizes. Doctor prints "undetermined" and the most specific of
  those lines — never `ok`.

**Which lines get judged**, most specific evidence first. When the output
names the configured `notify.channel` at all, those rows are the *only*
evidence considered — judging the whole output instead would let one
unrelated platform's row condemn a healthy return leg. When it does not, the
rows naming the gateway itself are judged, then the rows whose **label** is a
status word (`Active:`, `Status:`, `State:`, `Health:`, `Service:`,
`Gateway:`), then the first line — each in turn until one of them actually
determines something.

That first step is *exclusive*, not merely first-ranked, and it has a visible
consequence worth knowing before you file it as a bug. Output that names your
channel only in an enumeration —

```
gateway: running
platforms: telegram, discord
```

— reports **UNDETERMINED**, even though the gateway line directly above says
`running`: the enumeration row names the channel, so it is the only evidence
considered, and it carries no status word. Falling through to the gateway's
state there would be inventing REACHABLE out of a line the probe never
understood, on a CLI whose output nobody has yet observed — and a row that
names your channel while saying something unreadable is weak evidence that
this build *does* report per-channel state and that yours is not in the
healthy set. A wrong "undetermined" costs you one manual check; a wrong
"reachable" tells you answers are landing while every one is dropped. A
channel the output does not name at all is a different case and does fall
through (nothing was misread there, because there was nothing to read). If
you hit this, run `hermes gateway status` by hand and read it yourself — and
report the wording, since that is the shape this probe is still waiting to be
validated against.

That last part is what a **service-managed** gateway needs. A gateway run
under launchd or systemd reports through its supervisor, which puts a unit
header on the line naming the gateway and the verdict on an indented label
line below it:

```
* hermes-gateway.service - Hermes Gateway
     Active: active (running) since Mon 2026-08-24 09:14:02 UTC
```

Picking the gateway row and taking its silence for the whole answer reported
UNDETERMINED for a return leg that is plainly up — on the deployment shape a
long-running gateway most commonly has. The label tier is a fixed set of
status words and contains no platform name, so a per-platform row
(`discord: disconnected`) still cannot reach it and condemn a channel it says
nothing about. `inactive` is in the negative vocabulary for the same reason:
it is the whole word a service manager reports a stopped unit with.

One deliberate difference from openclaw's probe: `openclaw channels status`
is documented to *enumerate* channels, so a channel missing from it is a
determination there (exit 1). Nothing establishes that `hermes gateway
status` lists platforms at all, so a channel it does not name is absence of
evidence here — the probe falls through to the gateway's own state rather
than declaring the return leg dead.

**What a REACHABLE result does and does not prove.** It proves the gateway
your reply is delivered to is up. It does **not** prove anything on the
channel side will turn that reply into an actual `orchid answer` invocation
against this repo — orchid ships no inbound listener and neither starts nor
supervises that agent, so nothing local can observe it. Doctor's wording
keeps those two apart; so does the probe's.

**PENDING-VALIDATION, and more so than for `send` above.** Unlike `hermes
send --help`, `hermes gateway status` has *not* been read from an installed
CLI — the task that added this probe could execute nothing at all. Both its
existence and its output are therefore treated as untrusted: a build with no
such subcommand is caught as an unknown subcommand and answers **2**, never
1, so a version difference can never masquerade as an outage, and any line
outside the two recognized vocabularies above answers 2 with its own text
quoted. Confirm the subcommand and its wording during the live hero-demo
dogfood; if it turns out to be spelled differently, this probe reports
"undetermined" until it is corrected, which is the safe direction.

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
