# orchid/openclaw — notify channel guide

Status: **build-only** (v1-m4 Task 7). The invocation below is verified
against installed OpenClaw help text ONLY — no real `openclaw message send`
has ever been executed by this task, and no live channel has been
configured/dogfooded yet. That live round trip is a later controller task
(hero-demo dogfood); this adapter's job here is a correct, honest BUILD.

This is the plugin `plugins/notify/openclaw/send` covers — orchid's kind=notify
channel plugin (docs/specs/plugins.md's "notify channel" row: `send
<question-id> <text>`).

## What this is (and isn't)

`openclaw` is this milestone's *reference* notify-channel plugin, and the
default (`notify.plugin` unset resolves to it — see "Config keys" below).
A second, sibling `kind=notify` plugin, `plugins/notify/hermes` (see
[hermes.md](./hermes.md)'s own "Notify channel" section), also ships —
`notify.plugin` is the selector between the two. OpenClaw itself is
additionally a multi-channel hub in its own right (Telegram, WhatsApp,
Discord, Slack, Signal, iMessage, ...), so THIS plugin doesn't get one
orchid plugin per chat app under it — `notify.channel` configures WHICH of
OpenClaw's own channels to use, a separate axis from `notify.plugin`
(which orchid plugin to invoke in the first place).

## Install

```sh
npm install -g openclaw
openclaw --version
```

Verified during this task against **OpenClaw 2026.7.1-2** (installed via
mise's node, `openclaw` on `$PATH`). `orchid doctor`/`orchid plugins
validate` report a missing `openclaw` binary against
`plugins/notify/openclaw/plugin.conf`'s `requires_binaries=openclaw`.

## Setup

`openclaw onboard` / `openclaw configure` (interactive; connects a chat
account under one of the channel names below) is entirely orchid's
responsibility to run once, out of band — orchid never manages OpenClaw's
own auth/gateway/channel connection, exactly like every other engine
adapter in this codebase only invokes a vendor CLI and reads its exit code
(docs/specs/plugins.md's trust model). `openclaw channels status` shows
what's currently connected.

## The verified invocation

Flag research for this task was `openclaw message --help` and `openclaw
message send --help` (help text only, run against the real installed CLI —
no message was ever actually sent). The task brief's own placeholder flags
(`--to`, `--text`) do **not** exist on the real CLI. The actual, verified
send shape is:

```sh
openclaw message send --channel <channel> --target <to> --message "<text>"
```

- `--channel <channel>` — one of: `telegram|whatsapp|discord|irc|
  googlechat|slack|signal|imessage|feishu|nostr|msteams|mattermost|
  nextcloud-talk|matrix|raft|line|zalo|clickclack|zalouser|sms|
  synology-chat|tlon|qqbot|twitch`. This is `notify.channel`'s value,
  forwarded verbatim.
- `-t, --target <dest>` — recipient: E.164 for WhatsApp/Signal, a Telegram
  chat id/`@username`, Discord/Slack/Mattermost
  `<channelId|user:ID|channel:ID>`, or an iMessage handle/chat_id. This is
  `notify.to`'s value.
- `-m, --message <text>` — the message body. This is the full outbox line
  `orchid notify` composed (qid + text + reply instructions + nonce).

`plugins/notify/openclaw/send`'s own header carries this exact writeup so
the adapter and this doc can never drift on which flags are real.

## Config keys

- `notify.plugin` (default `openclaw`) — selects which `kind=notify`
  plugin dir under `plugins/notify/` the pump's outbox drain launches
  (`openclaw` or `hermes`; a directory name, not a manifest id). Unset
  stays on this plugin — nothing below changes behavior on its own.
- `notify.channel` (default empty — no channel configured, `orchid notify`
  never writes an outbox file at all) — OpenClaw's channel enum, see above.
- `notify.to` (default empty) — the `--target` recipient. **Required for this
  plugin**: `send` dies without it, so the manifest declares
  `requires_config=notify.channel,notify.to` and `orchid doctor` refuses to
  report outbound `ok` while either is unset — otherwise every queued blocker
  fails, retries to `send_retry_max` and quarantines behind a green doctor.
- `answer_allowlist` (default empty) — comma-separated sender identifiers.
  Configuring this at all turns inbox hardening ON: every `orchid answer`
  then requires `--nonce` (see "Inbox hardening" below), and a caller that
  additionally sets `ORCHID_ANSWER_SENDER` (a remote surface — currently
  only the openclaw AgentSkill, below) must appear in this list.
- `answer_expiry_s` (default `86400`) — a question expires this many
  seconds after being minted (`.question` file mtime); an expired `orchid
  answer` dies and leaves a journal note, regardless of sender.
- `send_retry_max` (default `5`) — the pump's outbox drain quarantines a
  queued message after this many consecutive failed `send` attempts.

## The OUTBOX pattern (why `orchid notify` never spawns)

`orchid notify` is a tier-1 verb; INV-01 forbids tier-1 verbs from
spawning/detaching a process. So when `notify.channel` is configured,
`orchid notify` only ever **writes** `runtime/outbox/<qid>` — the fully
composed message text, nonce included and the repo binding inline so the
command runs verbatim from any cwd (F18): `"<qid>: <text> — reply:
ORCHID_REPO="<repo>" orchid answer <qid> <choice> --nonce <nonce>"`.

`runners/orchid-pump` (tier-2) is what actually launches
`plugins/notify/openclaw/send <qid> <text>` for each queued outbox file —
on every pump pass, right after its lease-staleness decision and before
handing off to the tick (even when the lease is fresh: channel-send must
never wait for a tick). The spawn reuses `lib/spawn.sh`'s
`spawn_child_env` (the same env-hygiene walk `runners/orchid-launch` uses:
a fixed base allowlist — `PATH`/`HOME`/`USER`/`LANG`/`TERM`/`TMPDIR`,
`LC_*`, `ORCHID_*` — nothing else). `notify.channel`/`notify.to` reach the
plugin as `ORCHID_NOTIFY_CHANNEL`/`ORCHID_NOTIFY_TO` (ORCHID_*-prefixed,
so they ride the existing wildcard with no `permissions=` opt-in needed).

- Exit `0` — the outbox file is removed.
- Nonzero — a `.tries` sidecar is bumped; the outbox file is left for the
  next pump pass. After `send_retry_max` consecutive failures, the entry is
  quarantined: the original file is removed and replaced with
  `runtime/outbox/<qid>.reason-send-failed` (a short note, for audit —
  never retried again).
- **Nothing about this is load-bearing.** `BLOCKERS.md` + the terminal is
  always a complete interaction surface (docs/specs/operations.md) — a
  channel that never sends anything at all changes nothing about how a run
  proceeds; it only removes a convenience.

## The AgentSkill (the inbound side)

`skills-external/openclaw-orchid/` is the answering half: an OpenClaw
AgentSkill bundle exposing exactly two operations, `orchid status`
(read-only) and `orchid answer <qid> <choice> --nonce <n>` (sets
`ORCHID_ANSWER_SENDER`). See that directory's own `README.md` for
registration and the full security posture (allowlist, nonce, no shell/repo
access beyond those two commands).

## The inbound probe (`orchid doctor` checks the return leg)

The AgentSkill above is the half orchid cannot see: it lives on the OpenClaw
side, orchid neither starts nor supervises it, and when it (or the gateway
under it) is down, blockers still go out and every answer typed back is lost
with **no local trace at all**. That is not hypothetical — it cost this
project a full day and one lost answer.

So this plugin declares an inbound probe in its manifest
(`inbound_probe=--inbound-probe`, see docs/specs/plugins.md), and `orchid
doctor` runs it:

```sh
plugins/notify/openclaw/send --inbound-probe    # what doctor invokes; sends nothing
openclaw channels status                        # what the probe asks
```

- **exit 0 — REACHABLE.** OpenClaw reports the configured `notify.channel`
  connected.
- **exit 1 — NOT REACHABLE.** `openclaw channels status` failed (gateway
  down, auth expired, daemon not running), or it answered and reported that
  channel disconnected, or it does not list that channel at all.
- **exit 2 — UNDETERMINED.** The `openclaw` CLI isn't on `PATH`,
  `notify.channel` is unset, this build has no `channels status` subcommand,
  or the status line isn't one the probe recognizes. Doctor prints
  "undetermined" and the raw line — never `ok`.

**What a REACHABLE result does and does not prove.** It proves the
*transport* your reply travels over is up. It does **not** prove the
AgentSkill is registered on the other side, or that anything there will turn
your reply into an actual `orchid answer` invocation against this repo —
nothing local can observe that. Doctor's own wording keeps those two apart;
so does the probe's. Unrecognized output always exits 2 rather than guessing:
a wrong "not reachable" is a false alarm that teaches you to ignore the line,
and a wrong "reachable" is the unproven-ok the check exists to remove.

The probe is a mode of `send` rather than a second script on purpose — the
entrypoint is the one file whose executable bit orchid already validates, and
a mode-644 helper would be invisible until the feature silently stopped
working. `runners/orchid-pump` never passes this flag (a qid is always
`q-<epoch>-<hex>`), so the send path can't reach it.

## Inbox hardening (`orchid answer`)

**Hardening turns on the moment a remote path is configured — it is not
opt-in per call.** The gate is `answer_allowlist` being configured at all
(repo config), not anything a caller self-asserts:

- **`answer_allowlist` NOT configured** — no remote answer path was ever
  set up, so there is nothing to defend: `orchid answer` stays in its
  lenient v0 shape (no nonce, no allowlist check) for every caller,
  `ORCHID_ANSWER_SENDER` or not.
- **`answer_allowlist` configured** — hardening is ON, unconditionally,
  for every caller:
  - **Nonce is ALWAYS required**, whether or not `ORCHID_ANSWER_SENDER` is
    set. Every question `orchid notify` mints now carries its own nonce
    (`.question` file's `nonce: <hex>` line, also echoed into
    `BLOCKERS.md` — unrelated to the qid's own collision-avoidance
    suffix), and `orchid answer` requires `--nonce <n>` matching it. This
    is the fix for a review-round finding: gating the nonce check on
    `ORCHID_ANSWER_SENDER` being set let ANY caller bypass it outright by
    simply not setting that env var — an unauthenticated bypass with no
    forging required. The nonce check no longer looks at that var at all.
  - **`ORCHID_ANSWER_SENDER`, when set, additionally requires allowlist
    membership** — that identity must appear in `answer_allowlist` (comma
    list), or the answer is refused outright.
  - **`ORCHID_ANSWER_SENDER`, when unset, is "local-with-nonce"** — the
    nonce is still mandatory, but there is no sender identity to check
    against the allowlist, so only the nonce gates. This is the local
    terminal path: the operator reads the nonce off `BLOCKERS.md` (or the
    `.question` file) and copies it straight into `--nonce`, one paste,
    no separate lookup.
- **Expiry.** Unconditional either way (local and remote alike): a
  question older than `answer_expiry_s` (by `.question` file mtime) is
  refused — die, plus a journal note (`blocker_expired`) so the run's
  history shows it, not just a silent stderr refusal.

**Nonce entropy.** Minting the nonce itself refuses to degrade silently:
if `notify.channel` OR `answer_allowlist` is configured (i.e. a real
answer path exists to attack), `orchid notify` requires a genuine
high-entropy source — `xxd` against `/dev/urandom`, then `od` as a second
independent strong source — and DIES (with a `notify_entropy_failure`
journal note, before raising the blocker at all) if both fail, rather than
quietly handing out a guessable date+pid nonce. That weak fallback only
ever survives when NEITHER is configured, in which case the nonce is
purely decorative (nothing outside this machine could present it anyway).

## Known gotchas / PENDING-VALIDATION

- **The send invocation above is help-text-verified only.** No real
  `openclaw message send` has been run by this task. The live hero-demo
  dogfood (a later controller task) is where this gets a real round trip
  against a configured channel — revisit this doc and
  `plugins/notify/openclaw/send` together if that turns up a surprise.
- **So is the probe's `openclaw channels status`.** Its *output format* has
  never been seen by this code against a live gateway, which is exactly why
  every unrecognized shape exits 2 (undetermined) instead of guessing a
  verdict. The same live dogfood is where its token matching gets confirmed
  or corrected.
- **`--dry-run` exists on the real CLI** (prints the payload, skips
  sending) but this adapter never passes it — a real send is exactly what
  its entrypoint exists to perform once an operator has genuinely
  configured a channel.
- **One channel plugin, many OpenClaw channels.** `notify.channel` is
  OpenClaw's own enum, not an orchid plugin selector — see "What this is"
  above.
- **No repo-local notify-plugin trust (yet), by design, not oversight.**
  `lib/resolver.sh`'s `resolve_notify_dir` only walks `$ORCHID_PLUGIN_PATH`,
  `~/.orchid/plugins/notify`, and the builtin `plugins/notify` root — it
  does not implement `<repo>/.orchid/plugins/notify` discovery or the
  digest-pinned trust (INV-09) that `resolve_engine_exe` gives engines.
  This is a documented no-op, not a gap that silently does nothing: no
  shipped notify plugin needs a repo-local location this milestone, so
  there is nothing to trust yet. Extend it the same way engines already
  work if a repo-local notify channel is ever needed.

## See also

- [../../README.md](../../README.md) — the "requirements sent from your
  phone in the morning, OpenClaw pings you the finished diff by evening"
  hero demo this channel + the AgentSkill together enable.
- [../configuration.md](../configuration.md) — the general config-key
  reference; every key this page names is documented there too.
- [../troubleshooting.md#blocked-tasks](../troubleshooting.md#blocked-tasks) —
  the operator verbs (`orchid answer`, `orchid task unblock/retry`) this
  channel's inbound side ultimately drives.
- [../extending/first-engine.md](../extending/first-engine.md) — the engine
  extension point this notify-channel plugin is a sibling of (different
  `kind=`, same discovery/trust model).
