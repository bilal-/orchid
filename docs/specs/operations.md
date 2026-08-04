# Orchid — Operations Guide

*Normative. One of four documents split from the design spec; see [2026-07-24-orchid-design.md](./2026-07-24-orchid-design.md) for the index and orientation.*

## Installation & configuration

### Install

`git clone` + `./install.sh`, which does exactly and only: symlink `skills/`
into `~/.claude/skills/`; link `bin/orchid` into `~/.local/bin` (or
`$ORCHID_BIN_DIR`), warning if that dir is not on `PATH`; create
`~/.orchid/plugins/engines` and a commented `~/.orchid/config`; finish by
running `orchid doctor` so the user's first output is a readiness report.
The plugin-trust file (`~/.orchid/trust`) and unattended-trust directory
(`~/.orchid/unattended-trust/`) are created on first use, never by tracked
content. `./install.sh --uninstall` removes precisely installed symlinks
(config and both trust stores are left with a note). `install.sh --prefix
DIR` redirects only the `orchid` binary symlink to `DIR/bin`; skills,
configuration, and trust stay per-user, unaffected by `--prefix`. At public
launch additionally: a
pinned `curl -fsSL … | bash` one-liner (fetching the same install.sh) and a
Homebrew tap — install must feel first-class on a Mac. **v1-m4 — prepared,
not yet released:** `Formula/orchid.rb` + `docs/install.md` are written and
lint-tested (`ruby -c`, placeholder tokens, a simulated-prefix resolution
proof), but the formula is never tapped, built, or installed by the test
suite or by any part of orchid itself — tapping the Homebrew repo and
publishing a real release tarball are release-day operator actions (see the
release checklist, roadmap.md).

### Installing plugins (v1-m3)

`install.sh` sets up the orchid tool itself; third-party PLUGINS (engines,
hooks, custom roles, archetypes) are a separate, per-plugin lifecycle:
`orchid plugins install <src>` (a local directory or a git URL — kind/name
derive from the plugin's own manifest), `orchid plugins update <name>`,
`orchid plugins remove <name>`, and `orchid plugins audit` (reports
content drift since install or a tampered `.provenance`) — see
docs/specs/plugins.md's Plugin lifecycle section. Authoring a new plugin
starts with `docs/extending/first-engine.md` (a full walkthrough) and
`docs/extending/conformance.md` (the `orchid plugins conform` seven-check
reference) — the conformance kit is the pre-install self-check every
third-party plugin should pass before `orchid plugins install` ever runs
against it.

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

## Unattended trust gate

`runners/orchid-pump`, direct `runners/orchid-tick`, and `orchid service
install` fail closed until an operator explicitly acknowledges the target:

```sh
orchid trust unattended <repo> --reason "<operator-authored reason>"
orchid trust show <repo>
orchid trust revoke <repo>
```

The JSON record and identity anchor are machine-local under
`~/.orchid/unattended-trust/`, outside the target. Their key and validation
bind Git's shared common-directory device/inode, the inode of Git's stable
untracked `description` witness, the reachable root commit set, and an in-code
policy version. The anchor is a second hard link to that witness. Its outside
link keeps the witness inode allocated after repository replacement, so a
fresh clone cannot inherit an old decision even if the filesystem reuses the
common directory's device/inode. Creating this non-reusable binding requires
the trust store and common directory to be on the same filesystem.
That intentionally shares trust across linked worktrees and survives a
same-filesystem move, while a fresh clone, copy, replaced/recreated `.git`,
root-history replacement, or policy-version change is denied. Path text,
tracked content, origin metadata, Git config, and `orchid.config` never grant
trust. Identity inspection ignores inherited Git repository-selection and
object-view variables (for example `GIT_DIR`/`GIT_WORK_TREE`), disables
replacement refs, legacy grafts, and shallow boundaries, and disables lazy
object fetching. Pump, tick, and service entry paths use `/bin/bash` directly
and replace inherited `PATH` with fixed machine-local system/package-manager
directories before self-resolution or identity inspection. The scheduler or
operator `PATH` is captured only as inert data and is restored by pump/tick
after the gate allows execution, so engine discovery still sees the operator's
tools; service installation likewise writes that captured value into the
scheduler artifact without using it to authorize the target. Unattended trust
inspection first derives only the on-disk common-directory identity and
identity-keyed record path. With no candidate it reports root verification as
pending and denies without invoking Git, enumerating worktrees, walking
history, or creating scratch files. Acknowledgement and verification of an
existing candidate require Git 2.45 or newer (the release that added a
reliable client-side no-lazy-fetch control); on older Git, the gate stays
denied before any target-repository Git query or history object walk, while
manual operation remains available. A shallow repository cannot be
acknowledged until its commit ancestry is locally complete. Every
trust-boundary path is captured and compared losslessly, including paths
ending in a literal newline.
Trust-store containment uses the physical checkout marker, not a
repository-configurable worktree path. A linked checkout's marker must
reciprocally match the path registered under the common directory, so copying
a linked worktree together with its `.git` pointer cannot inherit the
registered original's acknowledgement. If `HOME` or a symlinked `~/.orchid`
would place the record inside the target or any registered sibling worktree,
acknowledgement refuses instead of creating repository-controlled trust state.
The record itself must be an operator-owned, single-link regular file without
group/other write permission. Symbolic links, hard-link aliases (including
aliases of tracked files), non-files, and unsafe permissions are denied;
the separate identity anchor is intentionally the witness's second link.
`orchid trust revoke` removes the outside record and anchor, and removes a
record symlink itself rather than following it. Revocation deliberately does
not inherit inspection's preconditions. It reuses only the bounded identity
derivation above — the same physical marker, linked-worktree registration,
common-directory, and store-placement checks that name this repository's
record — and applies no Git version, ref, history, object, root, or
scratch-space check. An operator can therefore always withdraw an
acknowledgement, including on an unsupported Git or for a mismatched,
shallow, object-missing, or corrupt-history repository that inspection
refuses to read; otherwise the record would survive on disk and authorize
unattended execution again as soon as the repository became inspectable.
Because that path runs no Git command, ordinary revocation costs nothing
proportional to repository history.

Root verification is never cached and never reused. Acknowledgement and every
later gate each walk the complete reachable history from `HEAD` and re-hash
each commit's exact stored payload; `orchid trust show` reports this as
`root_verification: walked`, and no machine-local file records a previous
verification. That repetition is the point rather than an oversight. A stored
derivation keyed by the common-directory identity, the incarnation anchor, and
the verified `HEAD` would defeat every *identity* substitution — clone, copy,
replaced common directory, moved or rewritten branch all change one of those
keys — but it would not defeat a *content* substitution, which is what this
verification exists to catch. Rewriting the bytes stored under a reachable
commit's advertised OID, removing or corrupting a reachable object, introducing
a shallow boundary, or repointing alternates all leave the ref values and the
anchor untouched, so a warm entry would be reused and the mismatch never
recomputed.

Proving the object store unchanged instead of re-reading it is not portably
available either: every cheap witness is filesystem metadata, and an in-place
rewrite that preserves size and restores mtime leaves all of it identical,
while reading the store's bytes to prove they are unchanged costs at least what
the walk costs over a store that is usually larger than the reachable commit
set. The optimization Orchid keeps is therefore the one that cannot trade
integrity for speed: verification is batched, using one long-lived `cat-file`
and one long-lived `hash-object` process per batch of commits rather than a
process pair per commit. Cost stays proportional to history length without
paying per-commit process overhead. Operators who schedule a pump against a
very large repository should size the interval accordingly.

A scheduled pump has nowhere to print. The installed cron line and launchd
agent both send its output to `/dev/null`, and the repo-local
`.orchid/runtime/pump.log` is deliberately not opened until after the gate has
passed — opening a target-controlled path first would let a revoked or replaced
repository be written to before it was trusted. Refusals from a scheduled
invocation are therefore also appended to
`~/.orchid/unattended-trust/refusals.log` (time, surface, repository, binding
state, and reason; bounded, machine-local, never inside the target, and refused
outright if the store would resolve into the target). `orchid doctor` warns and
shows the most recent entries. An interactive refusal prints to the caller's
terminal and does not append to that file.

`jq` is one of the kernel's three required binaries and the only reader of the
acknowledgement record. If it is missing, the gate stays closed and says so —
`orchid trust show` reports the boundary as unavailable with a `why:` naming
the missing tool, and acknowledgement refuses — rather than reporting a
perfectly good record as malformed. A launchd agent starts from a bare
environment, so re-run `orchid service install` after a `PATH` change to
refresh the `PATH` baked into the scheduler artifact.

The acknowledgement means only that the operator accepts this repository as
input to an unattended, shell-capable model. Target content may prompt-inject
the orchestrator. Launcher environment hygiene reduces ambient authority;
vendor sandbox flags enforce only what that vendor documents; PROTOCOL.md's
command rules are prompt policy; no command broker is available yet (T002);
and Orchid provides no OS-level containment for adapter/plugin process trees.
Interactive/manual operation, planning, and read-only commands remain
available and never create an acknowledgement.

## Operator walkthrough (the human's seat)

1. `orchid doctor` — readiness + plugin/trust report.
2. Write `.orchid/requirements.md`; set `orchid.config` (verify command,
   role bindings if non-default). `orchid init`.
3. Start your configured orchestrator front-end — any front-end executing
   PROTOCOL.md via verbs (with the default bindings: a Claude Code session
   → `/orchid-plan`). A direct headless tick first requires `orchid trust
   unattended "$PWD" --reason "..."`, then `orchid run start &&
   runners/orchid-tick`.
4. Walk away. Check `orchid status` anytime (or `orchid status --html` for a
   self-contained static page — v1-m4 — SHIPPED); answer questions via
   `orchid answer`; intervene via `orchid task unblock/retry/set`. After the
   same acknowledgement, `orchid service install` schedules the pump via the
   host's own scheduler (a launchd agent on macOS, a marker-guarded crontab
   line elsewhere) so ticks continue without a terminal open —
   `orchid service status`/`orchid service uninstall` report/reverse it.
5. Run ends at `run_status: complete` (acceptance evidence in
   `reviews/acceptance.log`) or surfaces a blocker. Integration branch holds
   the product; pushing/deploying is yours.

## Remote interaction

- **v0/v1 seam:** `orchid notify` (question-id minted by the kernel,
  multiple-choice preferred) → `BLOCKERS.md` + terminal; `orchid answer
  <qid> <choice>` — idempotent, expiring, consumed by the next tick.
- **v1-m4 channels — three explicit actors (round-4 topology fix) — SHIPPED:**
  (1) a kernel-launched OUTBOUND channel plugin (`send` only, no repo
  access) — `orchid notify` (tier-1) never spawns it directly; it only
  writes `runtime/outbox/<qid>`, and `runners/orchid-pump` (tier-2) drains
  the outbox every pass through whichever `kind=notify` plugin `notify.plugin`
  selects (default `openclaw`; `hermes` is the other built-in), quarantining
  a message after `send_retry_max` consecutive failures rather than retrying
  forever; (2) the **orchid AgentSkill inside OpenClaw**
  (`skills-external/openclaw-orchid`) — an authenticated external front-end
  authorized for exactly two verbs, `orchid status` and `orchid answer`
  (this, not the channel plugin, answers "how's the run?" from your phone);
  (3) a lock-safe kernel INBOX: `orchid answer` validates nonce, sender
  allowlist, and expiry before recording — no listener daemon; the tick
  polls the inbox. Telegram fallback uses the same three-actor shape. An
  unanswered question is just a blocked task.
- **API-billing exception, stated plainly:** API-backed engines are metered
  per call, unlike subscription CLIs; their role BINDINGS carry call budgets
  and retry ceilings. **Dropped, per the v1-m4 escape hatch (roadmap.md):**
  the Kimi reviewer and Perplexity researcher reference adapters named
  earlier in this exception did not ship this milestone — their CLIs are not
  installed on the dogfood machine, so neither was built past the roadmap
  mention; neither appears anywhere in the README, compatibility matrix, or
  `docs/engines/` as an available adapter. The mechanism this exception
  describes (call-budget/retry-ceiling bindings for a metered API-backed
  engine) remains available to any future adapter that needs it. **Optionality
  is binding policy, not role identity** (Perplexity's own fix): any role
  binding may declare `blocking: false` — the run continues without that
  role's output when it fails — so future non-blocking roles need no
  special-casing; `role.researcher` merely defaults to `blocking: false`.
- **The entire remote stack is post-core:** no kernel behavior may assume a
  channel, AgentSkill, or inbox exists — `BLOCKERS.md` + terminal is always
  a complete interaction surface.
- Non-goal: native app. `orchid status` (or `orchid status --html`, a
  self-contained static page — v1-m4 — SHIPPED) is the read surface.
