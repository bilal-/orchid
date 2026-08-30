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

## Qualification runs the target verify= command, and takes no acknowledgement

`scripts/beta-qualify.sh` executes exactly one thing inside the repository it is
qualifying: that repository's own configured `verify=` command, once, in place,
to time it. That is repository content reaching execution with no
acknowledgement of any kind, which is the same class of exposure the gate above
exists for. **Qualification stays ungated anyway.** That is a decision, and it
is recorded here with what was rejected, because an outcome without its
reasoning is not a decision anyone can revisit.

What the harness carries instead of a gate: the exception is stated in its
header and in `--help`, in the same breath as the no-write promise; it is
announced on stderr at the moment the command is executed, on that path only;
and `--no-run-verify` opts out, recording the timing probe as `not-tested`
rather than as a pass.

**One gate the harness does fire, and it is not an exception to any of this,
because it is not about the target.** `scripts/beta-qualify.sh` calls
`orchid_root_stale_gate` above its own argument parse. That gate asks about
`ORCHID_ROOT` — whether the Orchid checkout the harness is *itself* running out
of is parked on its integration branch with kernel files staged, i.e. whether
the harness is pre-merge code (lesson L018) — and asks nothing whatever about
`--repo`. It authorizes nothing and records nothing. What it stops is a build
that cannot be trusted to describe itself from producing evidence an operator
decides a beta on, or from running the target's `verify=` command on that
build's terms. Loading `lib/common.sh` is what arms it, and this file lives
outside `bin/`, `libexec/` and `runners/`, so nothing fires it unless this file
does (INV-15). It sits ahead of the parse for the same reason every kernel verb
refuses before reading its arguments, `--help` included: the text such a build
would print is its own pre-merge account of itself. `ORCHID_ALLOW_STALE_ROOT=1`
in front of the command remains the one documented, per-invocation way past it.

Three reasons the unattended acknowledgement is the wrong instrument here.

- **It would invert the documented order.** PROTOCOL.md's HEADLESS OPERATION
  section and [beta-qualification.md](../beta-qualification.md) both say to
  qualify a repository *before* acknowledging it: the acknowledgement opens the
  headless gate, it does not make a target drivable. Requiring trust in order to
  qualify would make the operator acknowledge a repository before holding any
  evidence about it, which hollows out the deliberate, reason-carrying act the
  gate exists to protect. And a qualification that then *failed* would leave the
  acknowledgement behind: the headless gate open on a repository just proved
  undrivable, closable only by remembering to revoke.
- **It would gate one command and leave its neighbour open.**
  `unattended_trust_require` guards exactly three surfaces — the pump, a direct
  tick, and service installation — because nobody is in front of those. (The
  two scheduled runners call its `_loaded` half, which decides and reports on
  an inspection they made earlier so their own stale-root gate could fire
  between the two; the surfaces are the same three.)
  `orchid verify` executes repository-supplied commands too — the task's
  `verification_commands`, or this same `orchid.config` `verify=` as its
  fallback — in the foreground, and asks for nothing. Gating qualification but
  not `orchid verify`
  would not remove the exposure; it would move it one command to the left while
  reading like a fix.
- **The gate's subject is a different one.** The acknowledgement means the
  operator accepts this repository as input to an unattended, shell-capable
  *model*, and its threat is target content prompt-injecting an orchestrator
  nobody is watching. Qualification builds no prompt, spawns no engine, and runs
  no model. Its exposure is the direct execution of a command the operator can
  read in one line of the target's `orchid.config` before typing anything — and
  the harness is a foreground command with two required paths on it, never
  scheduled and never invoked by the kernel.

**Rejected: a qualification-scoped acknowledgement, narrower than unattended
trust.** It would need its own store, identity binding, policy version,
revocation verb, and refusal log — all of the machinery above, which exists
because a scheduled pump has nobody in front of it and no terminal to print to.
Qualification has both, by construction. A trust record whose only audience is
the person who just typed the command is a confirmation prompt wearing a trust
boundary's clothes, and a second record keyed to the same repository is a second
thing to revoke and a second way for two stores to disagree about one target.
The in-band notice is that confirmation, at its honest weight.

**Rejected: making `--no-run-verify` the default, with an explicit opt-in to
run.** The timing probe is the most load-bearing fact in the report: the driver
holds no lease refresh across a synchronous verification and the merge
re-verifies after its rebase, so a suite approaching `pump_stale_s` strands a
headless run with no actor able to move it. When `--no-run-verify` is passed,
`verify-duration` is recorded as a non-blocking `not-tested`, so the verdict can
still read `qualified` with that fact unmeasured. As an opt-out that is honest —
the operator asked for it, and `not_certified` names it. As the *default* it
would mean the ordinary run prints `qualified` for a repository whose suite was
never timed, trading a stated execution exception for a quietly weaker headline.
A default that must be overridden to produce the report's most important number
is not a safer default, only a less-read one.

**What would reopen this.** Two facts hold the balance up, and either one going
means this decision has to be made again rather than quietly inherited.

The first is that the harness executes nothing but the operator-configured
`verify=` command. If a probe is ever added that runs something else in the
target — spawning an engine, executing a repository hook, running a plugin
entrypoint from the target tree — the exposure stops being one readable line of
config.

The second is that qualification stays a foreground command nobody schedules.
The third reason above is *only* true while no runner, service unit or kernel
verb invokes `scripts/beta-qualify.sh`: the moment one does, the operator this
argument assumes is standing in front of it is not there, and the stderr notice
carrying the mitigation is printing to nobody. That one is held by
`tests/test_docs.sh`, which fails if any file under `lib/`, `libexec/` or
`runners/` so much as names the harness — a change that would otherwise leave
this section false without touching a byte of it.

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
   `orchid answer`; intervene via `orchid task unblock/retry/reverify/set`
   (`retry --attempts N` grants a task more rework rounds; `reverify` re-runs
   verification against a tree you have already made green, spending no
   attempt). After the
   same acknowledgement, `orchid service install` schedules the pump via the
   host's own scheduler (a launchd agent on macOS, a marker-guarded crontab
   line elsewhere) so ticks continue without a terminal open —
   `orchid service status`/`orchid service uninstall` report/reverse it.
5. Run ends at `run_status: complete` (acceptance evidence in
   `reviews/acceptance.log`) or surfaces a blocker. A run does not reach that
   state on its own: the pass that finds every task `done` advances it to
   `accepting` and stops at a `run-complete` boundary, so an unattended run
   parks in `accepting` until an operator runs `orchid run accept`. Integration
   branch holds the product; pushing/deploying is yours. A schedule installed
   in step 4 does NOT end with it — nothing ties one to a run's lifetime, so
   every wake from `accepting` onward can only repeat one pass, and every wake
   after completion is a certain no-op that runs forever. Tearing the checkout
   down is therefore ordered, not interchangeable — and is one command rather
   than two: `orchid service teardown --repo <path>` uninstalls the schedule
   and removes that worktree only if the uninstall succeeded, so a refusal
   cannot be followed by a removal that runs anyway. Run raw, the pair must be
   chained (`orchid service uninstall --repo <path> && git worktree remove
   <path>`, from the MAIN checkout — `git worktree remove` needs a repository
   to run in, which `teardown` resolves for itself); orchid can refuse only the
   removals it performs itself, never a
   `git worktree remove` an operator types. Reversed, the
   scheduler keeps firing against a directory that is gone and the binding
   record naming the leftover schedule went into the bin with it — `orchid
   doctor` reads the machine-local copy under `~/.orchid/services/` and names
   what is still owed an uninstall: a binding whose checkout is gone, one whose
   repository is gone under a surviving directory, one whose run has already
   reached a terminal state, and one whose run is parked in `accepting`. A
   schedule that has actually woken and refused says so there too, from a note
   the pump leaves beside that same record. `uninstall` removes the scheduler
   artifact and clears the binding only once the scheduler has let the job go:
   a macOS unload that fails while `launchctl list` still reports the label
   removes nothing and refuses, since the artifact and the record are the only
   things that could name the still-loaded agent afterwards. An artifact that
   is already gone is not the answer to that question either — removing a plist
   unloads nothing — so that case asks launchd too, and refuses on the same
   fact, holding the record that is by then the agent's last name. Only launchd
   ANSWERING that it holds no such job clears those records: `launchctl list`
   exits nonzero both for that answer and for every way of failing to ask, and a
   query that never reached launchd is treated as a loaded job, not as an
   absence — it refuses, names the failing command and its status, and keeps
   both binding records and the checkout guard. Every one of those refusals is
   what `teardown` makes load-bearing: it is the same uninstall, and the
   worktree removal is its success branch, so a refusal that used to print
   above a removal an operator ran anyway now stops the removal outright and
   exits nonzero with the checkout untouched. `teardown` refuses up front,
   uninstalling nothing, when `--repo` is not a linked worktree, and removes
   neither half under `--dry-run`. Exactly one of its failures fires with the
   uninstall already done — `git worktree remove` declining a worktree it
   considers unclean — and that one names both halves: the schedule is ended
   and will not fire again, only the checkout is left, and the `--force`
   removal that finishes it is printed, because re-running `teardown` there
   would report `no service installed` and remove nothing. Doctor is the
   surface that reaches an operator here: the pump says the same thing on every
   wake, but it says it before the repo-local service log is opened (nothing
   may open a path inside the target ahead of the unattended trust gate), so a
   scheduled wake reports it to the scheduler's `/dev/null`. See PROTOCOL.md's
   COMPLETION.

## Remote interaction

- **v0/v1 seam:** `orchid notify` (question-id minted by the kernel,
  multiple-choice preferred) → `BLOCKERS.md` + terminal; `orchid answer
  <qid> <choice>` — idempotent, expiring, consumed by the next tick.
- **Multiple choice is DECLARED, and enforced (v1-m4 T009) — SHIPPED:**
  `orchid notify [--choice <value>]...` records the permitted answers with the
  question (a `runtime/answers/<qid>.choices` sidecar) and names them on every
  surface the question reaches — `BLOCKERS.md`, the channel page, and
  `orchid status --html`. `orchid answer` then refuses a value outside the
  set and lists the valid ones in the refusal, so a typo can no longer be
  recorded silently as a decision. The gate keys on the sidecar's EXISTENCE,
  never on the question's prose: a question minted with no `--choice` has no
  sidecar and keeps the free-text contract in full, which is the contract
  every question raised before this shipped still has. A sidecar that exists
  but yields no readable choice is refused rather than waved through — "the
  record of a declared set is gone" is not "no set was declared".
  A declared value is one `[A-Za-z0-9_-]` word, alphanumeric first, at most
  64 characters; `orchid notify` refuses anything else at mint time, which is
  the same grammar `runners/orchid-orchestrator-command` admits for the same
  flag on the brokered surface. That narrowness is representability, not
  taste: `orchid answer` takes `<choice>` as a positional and routes any
  argument beginning with `-` to its usage arm, with no `--` terminator, so a
  value outside the word grammar could be named on a page and then be
  answerable by nobody — and because the declared set also refuses every
  value it did not name, such a question would be answerable by nothing at
  all.
  `runners/orchid-drive` declares the set for every boundary kind that has
  one (`lib/drive.sh`'s `drive_boundary_choices`; PROTOCOL.md's boundary
  table), and the kinds whose answer is genuinely prose declare none. The set
  is a property of the kind AND the task's status, not of the kind alone: a
  `review-evidence`/`review-conflict` page names the arbitration results
  (`approve | request-changes | defer`) only from `arbitrating`, where `orchid
  task arbitrate` is legal, and names the review-plan remedies its own reason
  text points at (`adopt-evidence | repin | block | defer`) from `reviewing`,
  where that verb exits 3. Declaring one state's verbs on the other state's
  page is the self-contradiction the gate makes worst: the page invites answers
  that cannot be carried out and refuses the ones that can. The same keying is
  what closes the `operator-decision` catch-all's set from `blocked` and from
  nowhere else: a task blocked by a repo-wide `merge_gate` red at the rework cap
  is filed under that kind rather than `blocked-task` (a judgment about the
  repository, not a candidate defect), carries `drive_blocked_reason`'s text
  naming `orchid task unblock|retry|reverify`, and so has the same four answers
  as any other blocked task. From every other status the catch-all still declares
  none, because there its reason really is composed per site.
  **One stop raises one page, and every stop raises one.** `runners/orchid-drive`
  sends every page from a single call site, over the list of every boundary the
  pass MET, de-duplicated per stop: a page for that TASK carrying that exact
  text which is already on record — a question still awaiting an answer, or one
  already answered — is that stop's page, and only a question that expired
  unanswered (which `orchid answer` would now refuse) counts as no page at all.
  So a condition that persists for a hundred passes raises one blocker. A stop
  is a task and a text, never a text alone: most boundary reasons do not name
  their own task, so two tasks failing the same hook compose the identical
  sentence, and matching on the text alone would answer the second one's stop
  with the first one's page. The boundary RECORD is still compared, but only as
  the fallback for a stop whose inbox holds no question at all — it is durable
  and a blocked task's never changes, so consulting it first left an expired
  page un-raisable: unanswerable to the operator and "already announced" to the
  driver, forever. A notify raised anywhere else is compared against nothing.
  Three arms used to
  do exactly that — the exhausted-budget arm and the wallclock backstop, each
  paging a task it was about to block, and the stuck-merge arm, paging a
  boundary it recorded in the same breath — so one decision reached the
  operator as two or three `qid`s, each with its own nonce and its own
  `.answer` file, only one of them carrying the kind's declared set. Answering
  one says nothing about the others: they stand in `BLOCKERS.md` until
  `answer_expiry_s` turns them into refusals. A task the driver blocks is now
  recorded as a `blocked-task` boundary in the same words every later pass over
  that task recomputes, so the block pages once and the passes after it page
  not at all. The kind is derived from the block's own journaled cause rather
  than from which arm reached it (`lib/drive.sh`'s `drive_blocked_kind`), which
  is what keeps the one block filed under a different kind — a repo-wide
  `merge_gate` red at the rework cap, an `operator-decision` — recomputing to
  that same kind on every later walk instead of changing under the task.
  A rework loop stopped for non-convergence (T025) is the second cause that
  derivation files under `operator-decision`, and it reached the same route
  the same way: the arm shipped raising its own notify AND recording a
  boundary in its own second wording, so one stuck loop asked the operator
  twice on the pass that blocked it and a third time on the next.
  De-duplicating against the boundary RECORD instead — which is what the first
  repair of those arms did — fails the same sentence in the other direction.
  Only one boundary is recorded per pass, so a stop that loses the ranking has
  no record to be compared against and raises no page at all; blocked tasks all
  rank equal, so the lowest-id one held the slot on every pass and every other
  blocked task in the run was silent. The ranking decides which stop is
  RECORDED, never which stops are paged.
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
- **The return leg is a separate fact from the send leg (v1-m4 T006):**
  actor (1) needs only a CLI on the orchid machine, while an ANSWER depends
  entirely on actor (2) — a persistent agent orchid neither starts nor
  supervises. When that agent is down, blockers still arrive and every reply
  to them is lost with no local trace (observed: a gateway down for a day,
  a phone answer gone). `orchid doctor` therefore reports outbound and
  inbound as two separate lines and never infers the second from the first.
  Outbound is `ok` only when the plugin resolves, its `requires_binaries`
  are on PATH, AND the config it declares in `requires_config=` is set.
  Inbound is **actually probed** where the configured plugin declares an
  `inbound_probe=` mode (docs/specs/plugins.md): doctor runs it and reports
  reachable / not reachable / undetermined as the plugin itself determined,
  bounded honestly — a reachable transport is not proof that a channel-side
  agent exists to run `orchid answer`. A plugin that declares no probe is
  reported **NOT VERIFIED** *for that plugin*, never as a claim that liveness
  is unknowable in general. Alongside either, doctor reports local evidence:
  blockers still WAITING for an answer. The only exclusion is expiry (past
  `answer_expiry_s`), mirroring the one refusal `orchid answer` itself
  enforces — nothing can ever write an answer for those, and a permanent
  warning is what teaches an operator to ignore the line. Task status is NOT
  an exclusion: `orchid answer` never reads it, so a question is evidence
  whatever status its task holds. When nothing is waiting, doctor reports
  that as an ABSENCE and names its bound — no question outstanding is not
  proof the return leg works. Every line here is advisory; a run with no
  channel configured is legitimate and stays green.
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
