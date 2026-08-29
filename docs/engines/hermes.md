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
  running/connected/online/ready/active/healthy — or it names a **live
  process id** (`pid 4242`, `"PID" = 4242`), which is how a supervisor
  answers the question and is published only for a job that is actually
  running. A process id is the weakest evidence this probe accepts as health
  (it carries no status word at all), so it is refused on any row that also
  carries a **negation particle** — `not`, `never`, `cannot`, `unable`, `no
  longer`, `no such`. A row negating *anything* is a row the probe has not
  understood, and an unread row is undetermined rather than reachable: that
  is what stops the next phrasing nobody here has seen yet (`hermes-gateway:
  not responding (pid 4242)`) from being answered by the pid beside it. A
  bare `no` is deliberately not a particle, because `no errors` is how a
  healthy supervised row reports a clean run. A **fatality marker** —
  `fatal`, `panic`, `conflict` — withholds health from *both* of these, the
  status word as well as the pid: see the competing-poller note under exit 2.
- **exit 1 — NOT REACHABLE.** `hermes gateway status` failed *and its output
  named the transport as unreachable* (`connection refused`, `could not
  connect`, `not running`, `not responding`, `no such process`, `timed out`,
  …), or it answered and the judged line carries a negation (`not running`,
  `not responding`, `not listening`, `not alive`, `unresponsive`, `no longer
  running`, `not paired`, `stopped`, `disconnected`, `inactive`, `dead`,
  `crashed`, `not loaded`, `offline`, `expired`, `down`, `not up`,
  `unreachable`, `unhealthy`, …). The responsiveness words count on **both**
  halves: a phrase that names a dead transport out of a query that failed is
  no weaker when the query succeeded and hermes printed it itself. `timed
  out`/`timeout` is the one that does not cross the other way — in an
  answered status *row* it is as likely to be a configured knob
  (`connected (timeout 30s)`) as an outage.
  The pairing words (`not paired`, `not linked`, `not registered`, `not
  authenticated`, `unpaired`) are negations **only**: a bare `paired` is a
  stored fact about what you once attached, which a gateway reports whether or
  not it is currently running, so it never reads as health. They also count
  only on the *answered* half of this bullet: out of a query that **failed**,
  the pairing and credential words (`not paired`, `expired`, `unauthorized`, …)
  are as likely to be the CLI's own attachment or auth failing as the
  gateway's, so they determine nothing there — the same `not paired` decides on
  the success path and does not decide on the failed one. A bare `refused` is
  likewise not evidence — only `connection refused`, which names the transport,
  is; a policy or an authentication refusing the CLI is a query that was turned
  away.
  The **displacement** words are the other half of this bullet and the only
  ones that are not about the gateway's own health: `terminated by`,
  `superseded by`, `displaced by`, `preempted by`, and `another`/`other`/
  `second`/`duplicate`/`competing`/`concurrent` in front of a poller noun
  (`poller`, `instance`, `session`, `consumer`, `listener`, `client`). They
  count on the *answered* half only, with the pairing and credential class:
  in a row hermes printed they are the gateway naming what took its update
  stream, while out of a query that **failed** they are the CLI's own session
  losing a race, which says nothing about whether the gateway is serving.
  A **denied** competitor is not a competitor, and a counted zero is not an
  incident: `no other listener`, `without competing pollers`, `conflicts: 0`,
  `not superseded by another instance`, `never terminated by other getUpdates
  request` and `not fatal` are all a healthy row reporting the *absence* of the
  thing in the same words it would report its presence, so the denial is
  stripped before either the displacement words or the fatality marker is read
  — `no`/`zero`/`0`/`without` and the particles `not`/`never`/`no longer`
  alike. The particles deny only a displacement or a severity, never a state
  word, so `not running` remains the outage it has always been.
- **exit 2 — UNDETERMINED.** The `hermes` CLI isn't on `PATH`,
  `notify.channel` is unset, this build has no `gateway status` subcommand,
  the command printed nothing, or none of the candidate lines below is one
  the probe recognizes. Doctor prints "undetermined" and the most specific of
  those lines — never `ok`.

  **A running process is not a served inbound leg.** Start a second gateway
  on the same credentials and the update stream goes to one of them; the
  long-poll transports this plugin delivers on hand the connection to the
  newest caller and terminate the older one. The displaced gateway keeps
  running, keeps its pid, answers `gateway status` — and receives nothing,
  so every reply you send is delivered to the other instance. Its row states
  both halves at once (`hermes-gateway: running (pid 4242) — fatal:
  conflict: terminated by other getUpdates request`). The displacement words
  under exit 1 convict on it; a bare fatality marker (`fatal`, `panic`,
  `conflict`) with no displacement named is a failure the probe cannot rank,
  so it withholds health and reports undetermined rather than inventing an
  outage out of a severity. A marker qualified as history (`running (last
  fatal 2d ago)`) is a record, not the current state, and still reads as
  reachable — but a *displacement* is not softened that way, because the past
  tense is how the transport phrases it in the present (`was terminated by
  other getUpdates request` is printed on every poll for as long as the
  competitor is up) and the process it names is not one of this gateway's
  that has since gone.

  **A failed query is not a dead gateway**, and the exit code alone never
  decides which one it was. `hermes gateway status` exiting nonzero says the
  *question* failed; only its output can say whether the *subject* is down,
  and the two come apart constantly — a broken install, an interpreter
  traceback, an unreadable `~/.hermes/config.yaml`, a permission-denied on
  the socket path, or the CLI's own credentials expiring so it cannot ask a
  gateway that is answering everyone else perfectly well. All of those are
  undetermined. Note where that puts `expired`: in a status line hermes
  successfully *printed*, it is hermes reporting that channel's credential
  and the return leg really is broken (exit 1); as the reason the CLI could
  not run at all, it is a question that was never asked (exit 2). Calling
  any of them "down" would print *"Answers sent on this channel are being
  lost"* about a return leg carrying answers fine — the false alarm that
  teaches an operator to ignore the one check whose whole job is to be
  believed, and a broken CLI is a likelier cause of a nonzero exit than a
  stopped gateway is.

**Which lines get judged**, most specific evidence first. When the output
names the configured `notify.channel` at all, those rows are the *only*
evidence that may report **health** — judging the whole output instead would
let one unrelated platform's row condemn a healthy return leg. When it does
not, the
rows naming the gateway itself are judged, then the rows whose **label** is a
status word (`Active:`, `Status:`, `State:`, `Health:`, `Service:`,
`Gateway:`), then — only when it names no subject of its own — the first
line, each in turn until one of them actually determines something. "Names no
subject of its own" means it is not a `<word>:` or `<word>=` row whose label
the tier above already declined to recognize: a bare `running` is read, a
`discord: disconnected` is not, because on this CLI whatever is printed first
is as likely to be a sibling platform's row as the gateway's own state, and a
row that never mentions your channel must not decide your channel's return
leg — in either direction.

That first step is *exclusive for health*, not merely first-ranked, and it
has a visible consequence worth knowing before you file it as a bug. Output
that names your channel only in an enumeration —

```
gateway: running
platforms: telegram, discord
```

— reports **UNDETERMINED**, even though the gateway line directly above says
`running`: the enumeration row names the channel, so it is the only evidence
that may report health, and it carries no status word. Falling through to the
gateway's state there would be inventing REACHABLE out of a line the probe
never understood — and a row that names your channel while saying something
unreadable is weak evidence that this build *does* report per-channel state
and that yours is not in the healthy set. A wrong "undetermined" costs you one
manual check; a wrong "reachable" tells you answers are landing while every
one is dropped. A channel the output does not name at all is a different case
and is judged in both directions (nothing was misread there, because there was
nothing to read). If you hit this, run `hermes gateway status` by hand and
read it yourself — and report the wording, since most of this probe's
vocabulary is still waiting to be validated against a live gateway.

**The exclusivity is one-way**, and that is the third step of the ranking. An
unreadable channel row may not be rounded *up* by weaker evidence, but neither
may it hide weaker evidence pointing *down*: when no channel row reports the
outage, the gateway and label rows are consulted for a **NOT REACHABLE**
determination only. So

```
Gateway: not running
platforms: whatsapp, telegram
```

reports **NOT REACHABLE** on the gateway row, while the same shape with
`Gateway: running` still reports UNDETERMINED. The weaker tiers convict and
never acquit.

**And the outage is looked for first — in every row, and in every tier —
before anything is read as health.** Inside one line the word tests already
run negatives-first, because `not running` contains `running`. The same
sentence can arrive spread over two *rows*:

```
Gateway: not running
telegram: connected
```

Your channel's row says the one word that reads as health, so an ordering
that asked "is anything up?" before "is anything down?" answered
**REACHABLE** here and never looked at the line above it. A per-platform
`connected` is a fact about that platform's own attachment — the same kind of
stored fact as `paired`, which this probe already refuses to read as health —
and it says nothing about the process your reply is actually delivered to.
The gateway row says exactly that, and it says no. The same thing happens
inside a single tier when a build prints more than one row about your channel
(`telegram: connected` above `telegram inbound: not listening`): the row
printed first is not the highest-ranked row.

So every admitted row is scanned for the outage — your channel's rows, then
the gateway and label rows — and only if none of them convicts is your
channel's tier read again for health. Nothing else moves: REACHABLE still
comes only from the most specific tier that exists, the weaker tiers still
may only convict, and an undetermined verdict still quotes the most specific
line the probe was looking at.

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
(`discord: disconnected`) cannot reach it and condemn a channel it says
nothing about — and the first-line tier above is restricted to unlabelled
lines so that same row cannot get there either, by being printed first.
`inactive` is in the negative vocabulary for the same reason:
it is the whole word a service manager reports a stopped unit with.

**Under launchd the same problem arrives one step further in**, because a
launchd job is named by its *label* and a label is a compound —
`hermes-gateway`, `com.hermes.gateway`:

```
hermes-gateway: running (launchd, pid 4242)
```

"Names the gateway" therefore also admits **this CLI's own name** in front of
the noun — `hermes-`, `hermes.`, `hermes_` — on top of the dot-joined form
(`com.orchid.gateway`) that always worked. Any qualifier at all would be too
much: `discord-gateway` is a row about a *sibling platform's* gateway, and it
must no more decide your channel's return leg than `discord:` may. The
**right** side stays strict for the same reason, so a token *ending* in
`gateway` is this gateway while `gateway-alerts` — a name headed by *alerts* —
is not. And a row naming a **live pid** is read as up even when it
carries none of the status words, since that is what a supervisor's answer
looks like. Three things keep that from inventing REACHABLE: it is only
reached on a row an earlier tier already admitted (a sibling platform's
`discord: connected (pid 4242)` never gets there), the negatives are judged
first (`stopped, pid 4242` is the outage), and the pid must be the current one
— `last pid 4242` is a record of a process that is gone, and `pid 0`/`pid -`
is a placeholder, not a process. `dead`, `crashed` and `not loaded` are
negations for the same reason: they are the words a supervisor spells
deadness with on a row that may still quote a process id. A bare `loaded` is
not a positive — launchd and systemd both call a *stopped* job loaded.

**A record is not a state**, and that rule now governs the words as well as
the pid. Negatives are judged before positives (`not running` contains
`running`), but a supervised row reports the *last* outage beside the
*current* state, so applying that order to every word in the row read

```
telegram: connected (last disconnected 2026-08-27, 4 reconnects)
hermes-gateway: running (pid 4242, last down 2d ago)
```

as NOT REACHABLE — the outage message about a channel carrying answers fine.
Whole-word matching does not reach it: `last shutdown` is a substring, while
`last disconnected` genuinely is the word. So a state word introduced by
`last`, `previous`, `prior`, `former`, `old`, `stale`, `exited` or `was` —
the same qualifiers that already disqualify `last pid` — is elided before
either direction is judged. It cuts both ways: an *unqualified* negative
still decides (`disconnected (last connected …)` is the outage), a
qualified *positive* is not health (`was running` is undetermined, never
REACHABLE), and a row carrying nothing but history has not said what is true
now and decides neither way. The live-pid tier deliberately keeps reading the
unelided row, so `was not responding (pid 4242)` still stops short of health
on its negation particle.

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

**What an installed CLI actually printed.** `hermes gateway status` has been
run against exactly one real installation, in one state. It exists, it exits
**0** while reporting a dead gateway, and it answers with one row per subject:

```
Gateway: not running
WhatsApp: not paired
```

Two things follow, and both shaped the rules above. A real outage arrives on
the *success* path, not the failed-query one. And a platform's return leg is
reported as an **attachment** (`paired`), not only as a process state — which
is why the negations carry the pairing vocabulary, and why a channel row this
probe cannot read no longer hides the gateway row above it. That output is
pinned verbatim in `tests/test_notify_hermes_channel.sh`; before those two
rules it reported UNDETERMINED, on the only real evidence this probe has ever
been handed.

**PENDING-VALIDATION otherwise, and more so than for `send` above.** One
installation in one state is not the shape of every build's output: no
*healthy* `gateway status` has been read from an installed CLI at all. The
subcommand's presence on other builds and the rest of its output are
therefore still treated as untrusted — a build with no such subcommand is
caught as an unknown subcommand and answers **2**, never 1, so a version
difference can never masquerade as an outage, and any line outside the
recognized vocabularies above answers 2 with its own text quoted. Confirm the
healthy wording during the live hero-demo dogfood; if it is spelled
differently, this probe reports "undetermined" until it is corrected, which is
the safe direction.

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
