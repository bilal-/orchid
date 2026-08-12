# Quickstart — existing repo

Clone → install → doctor → init → your first completed task, in one sitting.
This is the literal path rehearsed on a clean machine profile before
release (`docs/specs/roadmap.md`'s release checklist) — if a step here
doesn't work as written, that's a docs bug, not something to route around.

Greenfield (no existing code yet)? See
[quickstart-greenfield.md](./quickstart-greenfield.md) instead.

**Prerequisites:** at least one of the engine CLIs orchid orchestrates,
already logged in under your own subscription — `claude`, `codex`, `agy`,
or one of the [reference adapters](./engines/hermes.md) (Hermes). Orchid
never manages vendor auth itself; see
[docs/engines/](./engines/) for the per-engine login flow. `git`, `jq`,
and bash 3.2+ (macOS's shipped `/bin/bash` is fine).

## 1. Clone and install

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0-beta.1/install.sh | bash
```

(goes live once the repo is public; see [docs/install.md](./install.md#one-line-install-recommended)
for the exact caveat and how flags like `--prefix`/`--uninstall` pass
through). The pinned install is independent of your current directory, even
if it is a dirty Orchid checkout. The URL is immutable: running this exact
line later reselects `v1.0.0-beta.1`; it does not upgrade Orchid. To upgrade, select
the install URL for a newer immutable released tag.

The shipped version is a prerelease on purpose: no one outside this
repository has run orchid yet, and no external beta has happened. `1.0.0` is
what that beta earns.

**Developing on orchid itself?** Clone it instead, so `install.sh` runs
from — and `orchid` resolves to — your own checkout:

```sh
git clone <this-repo-url> "$HOME/src/orchid"
cd "$HOME/src/orchid"
./install.sh
```

Either way, `install.sh` does exactly and only: wires the interactive orchestrator
skills (`skills/{orchid,orchid-plan,orchid-resume}`) into whichever agent
front-ends are **actually present** on this machine — Claude Code
(`~/.claude/skills/`) is today's tested default, and it also wires Hermes
(`~/.hermes/skills/orchestration/`) when that's present, skipping cleanly
(one-line note, no directory creation) for whichever front-end isn't
installed — symlinks `bin/orchid` into `~/.local/bin` (add it to `PATH` if
the installer warns it isn't there), creates `~/.orchid/plugins` and a
commented `~/.orchid/config` (the `~/.orchid/trust` store file appears on
first `orchid plugins trust`), then finishes by running `orchid doctor` if
your current directory is a repo to orchestrate. `./install.sh --uninstall`
reverses precisely those symlinks/dirs (your config and trust store are
left in place). See [frontends.md](./frontends.md) for driving orchid from
any of these agents (or codex/agy/OpenClaw, none of which need install.sh
wiring), and for exactly what's tested vs. untested per engine.

## 2. Point orchid at your project

```sh
cd "$HOME/path/to/your-project"
orchid doctor
```

The first run will report missing pieces — that's expected. Fix them:

- **No verify command:** add one line to `orchid.config` in your project
  root: `verify=<your test command>` (e.g. `npm test`, `pytest`, `make
  test`).
- **Role bindings:** the tested defaults
  (`role.orchestrator=claude`, `role.implementer=codex`,
  `role.reviewer=agy`, `role.arbiter=claude`, `role.plan_critic=codex`) work
  out of the box if you have those CLIs. Only add `role.*` lines to
  `orchid.config` if you want something else — see
  [configuration.md](./configuration.md) and the
  [any-engine-any-role matrix](../README.md#any-engine-any-role) in the
  README before doing so.

Re-run `orchid doctor` until it's green.

## 3. Write requirements and initialize

```sh
$EDITOR requirements.md   # goal, constraints, acceptance criteria — any format, any name
```

`orchid init` refuses to run against a dirty working tree — "orchid never
touches user work" — and both `requirements.md` and any `orchid.config` edit
from step 2 are, at this point, uncommitted. Commit them on your own branch
first:

```sh
git add -A
git commit -m "orchid: requirements + config for orchid init"
```

### One command: `orchid start`

Everything left in this step is mechanical, so there is a single command for
it:

```sh
orchid start requirements.md --verify "<your test command>"
```

It runs the full preflight (`orchid doctor`), validates your `orchid.config`,
initializes, creates the integration worktree, sets up the epoch, imports
`requirements.md` under that epoch, and prints the epoch, the paths, the run
state, and the planning handoff. Then **skip to [step 4](#4-plan)** — from the
worktree it just printed, with the `ORCHID_EPOCH` it just told you to export.

Options: `--verify <command>`, one line, appended as a `verify=` line to the
integration checkout's `orchid.config` and committed onto the integration
branch by that same run, but only when that file configures none yet — omit
the flag if you already set `verify=` in step 2. (One line because
`orchid.config` is a line-oriented `key=value` file: a multi-line command
would be read back truncated at its first line, so it is refused rather than
half-recorded. Put a multi-step command in a script and pass that.)
`--worktree <path>`, which defaults to
`../<repo>-orchid`; and `--ack-unattended --reason "..."`, both together, to
also make the machine-local unattended acknowledgement of
[step 5](#5-start-the-orchestrator-and-walk-away).

Committing that one line is part of the same command on purpose: there is no
follow-up step to remember, and the integration checkout is not handed back
dirty. A command that only your environment or your machine-local
`~/.orchid/config` supplies counts as "none yet" — it would not survive a
fresh checkout of the integration branch (a task worktree, another machine, a
headless pump), so it is recorded there too rather than left to vanish — and,
for the same reason, an explicit `--verify` overrides it without complaint. A
`verify=` line already committed on that branch is never replaced or
duplicated: `--verify` with a different command there is refused up front,
before anything is created, and re-running without the flag keeps the branch's
own command.

That commit is whole-file (the same granularity as `orchid config commit`), so
"append-only" is enforced against the branch too, not just against the file on
disk. If your integration checkout's `orchid.config` carries a *different*
`verify=` line from the one the branch already has, or is missing any other
line the branch has, committing it would replace or delete settings the run
reads — so that is refused up front as well, naming both ways out: take the
branch's copy back (`git -C <worktree> checkout -- orchid.config`), or land
your edit deliberately with `orchid config commit --reason "..."` from the
worktree. Additions ride along; removals never do. And because that commit is
how the command becomes durable at all, an `orchid.config` your `.gitignore`
excludes and no commit tracks is refused too — `git add` cannot stage it, and
`orchid start` will not force it past a rule you wrote.

What it will not do, by design:

- **never guess a verification command** — no `--verify`, no configured
  `verify=`, no setup;
- **never overwrite your files** — it appends at most one `verify=` line (and
  commits exactly that one file), never replaces a `verify=` line already on
  the integration branch, never commits an `orchid.config` that would drop a
  line that branch already carries, and refuses any worktree path that is not
  empty or is not exactly this repository's integration checkout;
- **never resume or take over a run** — against existing state it refuses if
  the run has left `planning`, if another session's lease is still fresh, if a
  run/verb lock is live, or if you cannot prove you hold the current epoch
  (`export ORCHID_EPOCH=<n>`; it never mints one over an existing one).
  `planning` has to hold on every copy that exists — your integration
  checkout's `.orchid/roadmap.md`, the roadmap as *committed* on the
  integration branch, and that branch carrying no committed `.orchid/tasks/`
  — because the two roadmaps can lag each other in opposite directions, and
  because committing onto a branch whose run is already in flight would move
  the head that every candidate's `base_sha` is pinned against;
- **never turn on unattended trust implicitly** — that needs both
  `--ack-unattended` and a non-empty `--reason`.

Re-running it with the same requirements file and the epoch it printed is a
no-op that just re-reports; anything it cannot do safely is refused with the
exact command to recover. It is a convenience over the verbs below, not a
replacement: everything in the rest of this step keeps working exactly as
written, and is what to reach for when you want to see each step.

### Or, step by step

```sh
orchid init
```

`orchid init` creates the integration branch (`orchid/integration`, or
whatever `integration_branch` names) from your current branch's HEAD and
commits `.orchid/` there — **your own branch is never touched.** It prints
a `git worktree add` command; run it, since durable orchid state only ever
lives on the integration branch (working from your own branch afterward is
exactly the split-brain trap — see
[troubleshooting.md#split-brain-checkout](./troubleshooting.md#split-brain-checkout)):

```sh
git worktree add ../your-project-orchid orchid/integration
cd ../your-project-orchid
```

Do the rest of this walkthrough from that worktree.

Every mutating verb fences itself against a monotonic **epoch**
(`ORCHID_EPOCH`; INV-02 — a stale epoch refuses to mutate durable state).
A fresh `orchid init` starts that epoch at `0`, but nothing prints it until
`orchid run start` does, so export it by hand now:

```sh
export ORCHID_EPOCH=0
```

`orchid run start`, `orchid run resume`, and every headless tick
(`runners/orchid-tick`) mint a **new** epoch — re-export after each one, or
the next verb refuses with `stale epoch '...' (current N) — refused
(INV-02)` (see
[troubleshooting.md#stale-epoch](./troubleshooting.md#stale-epoch)):

```sh
export ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"
```

```sh
orchid requirements import "$HOME/path/to/your-project/requirements.md"
```

## 4. Plan

Draft a roadmap of tasks against the requirements you just imported:

```sh
orchid task create T001 "Your first task"
orchid task set T001 acceptance_criteria "..."
orchid task set T001 verification_commands "..."
```

Then run the plan-critique loop (a second engine judges the draft before it
ever becomes real work) and commit it:

```sh
runners/orchid-launch plan plan_critic critique
orchid jobs reconcile
# fold .orchid/reviews/plan-a1-plan_critic.json's findings back into your tasks,
# repeat until nothing at/above medium severity remains, then:
orchid plan crosscheck
orchid plan apply --reason "initial plan"
```

`orchid plan crosscheck` asks what the PREVIOUS run left behind — ledger
items in its archived journal, and the active lessons carried across the
rollover — and names every one your new plan does not appear to consider.
On a repository's first run it says so and there is nothing to do. Once
there is a previous run, `orchid plan apply` runs the same check itself and
refuses while any carried item is neither covered by a task nor deferred
with `orchid plan defer <item-id> --reason "..."`.
`orchid run advance` applies the same refusal on every edge out of
`planning`, so it cannot be sidestepped by leaving `planning` first. One
journal entry often records several findings at once, so entries written as
`(1) … (2) …` are listed as `r-001#57.1`, `r-001#57.2` and answered
separately — covering one never closes its siblings. See PROTOCOL.md's
PLANNING section for what counts as coverage and why it is deliberately
cautious.

## 5. Start the orchestrator and walk away

Two equivalent front-ends execute the same `PROTOCOL.md` procedure — pick
whichever fits how you work:

**Interactive (default bindings — a Claude Code session):** open Claude
Code in this worktree and invoke the `orchid` skill (installed in step 1).
It reads `PROTOCOL.md` and drives the tick via `orchid` verbs, the same
commands shown throughout this page.

**Headless, right now:**

```sh
orchid trust unattended "$PWD" --reason "reviewed this repository for unattended execution"
orchid run start
runners/orchid-tick
```

The first command is an explicit acknowledgement of the target repository's
prompt-injection risk. It is machine-local state, not a tracked config knob;
neither cloning a repository nor accepting a repository-supplied
`orchid.config` can opt you in.

**Headless, unattended:** after that acknowledgement, install the pump as a
background service so ticks continue even after you close the terminal:

```sh
orchid service install
```

See [quickstart's service section below](#6-keep-it-running-unattended) —
or skip straight to it now if you don't want to babysit a terminal.

## 6. Keep it running unattended

```sh
orchid trust show "$PWD"
orchid service install
```

Installs a launchd agent (macOS) or a crontab line (Linux) that runs
`runners/orchid-pump` on an interval (`pump_interval_s`, config, default
`240`) — a no-op most passes, and a single headless tick whenever the
interactive session's lease has gone stale. `orchid service status` reports
whether it's loaded and when it last ran; `orchid service uninstall`
reverses it.

The pump and direct `runners/orchid-tick` entry point re-check trust on every
invocation, before creating runtime state, draining the notification outbox,
or spawning an engine. `orchid trust show "$PWD"` includes the operator's
reason/timestamp and the current binding: Git common-directory device/inode,
a non-reusable hard-link witness identity, root commit, and trust-policy
version. Linked worktrees share the record, and a same-filesystem move keeps
it; a clone, copy, recreated/replaced `.git`, root-history replacement, or
policy-version change does not. The trust store and Git common directory must
be on the same filesystem for the witness anchor. Trust inspection also
returns immediately with root verification `pending` when no identity-keyed
record exists. Acknowledgement and verification of an existing candidate
require Git 2.45 or newer so any required history walk can reliably forbid
promisor/lazy fetching; older Git remains usable manually, but the unattended
gate stays denied before inspecting repository objects. Re-acknowledge only
after reviewing the changed boundary:

```sh
orchid trust unattended "$PWD" --reason "reviewed the new repository identity/history"
orchid trust revoke "$PWD"       # fail closed on future pump/tick passes
```

Revocation does not uninstall an existing schedule; `orchid service status`
and `orchid service uninstall` intentionally remain available.

## 7. Check in

```sh
orchid status               # task table, engines, open questions
orchid status --explain     # + unattended gate/provenance and dispatch reasons
orchid status --jobs        # + a process table for the run in place of the
                             # bare task/state pairs (see below)
orchid status --html        # writes a static page to runtime/status.html —
                             # open it directly, "check from another room"
orchid status --html --explain # + gate/provenance in page; stdout remains its path
```

A run's jobs get their own table — one row per outstanding job, with the job
id, task, role, operation, attempt, engine, pid, state, age, elapsed, budget
consumed, who launched it, and its log path:

```sh
orchid jobs ls              # the process table
orchid jobs ls --watch      # ... refreshed every 5s (--interval N to change)
orchid jobs ls --all        # + jobs that already finished: what this task ran,
                             # in what order, and how long each took
```

Two things it is careful about. **State is computed, never read**: a manifest
records the pid its launcher stamped and nothing ever unstamps it, so every row
asks the same predicates as `jobs check` — a stamped job whose process is gone
reads `dead` (or `delivered`, if its envelope is written and simply not
reconciled yet); `pid: 0` with no log reads `never-started`, with a fresh log
reads `prepared`, and with a log silent past `stall_minutes` reads `unstamped`.
**Age is shown beside it**: `AGE` is how long since the job last wrote anything.
Dead jobs without envelopes, never-started jobs past the threshold, unstamped
jobs, and running jobs silent past the threshold get a `WARNING:` line on
stderr — which `orchid status` prints in every mode, with no flag, because a
run whose only in-flight job died is exactly the state nobody thinks to go
looking at a table for.

A genuine blocker raises a question in `BLOCKERS.md` and (if you configured
[a notify channel](./engines/openclaw.md)) pings you outside the terminal.
Answer it, or intervene directly — see
[troubleshooting.md#blocked-tasks](./troubleshooting.md#blocked-tasks):

```sh
orchid answer <qid> <choice>
orchid task unblock <id> --reason "..."
```

## 8. Done

Once every task is `done`, the orchestrator runs the acceptance procedure
itself (`orchid run advance accepting`, coverage + acceptance checks,
`orchid run accept --reason ... --evidence ...`) and `orchid status` shows
`run_status: complete`. The integration branch now holds your finished
product — pushing or deploying it from there is entirely up to you. Orchid's
supported verbs do not push; see the
[threat model](./specs/plugins.md#threat-model-consolidated) before treating
that prompt policy as containment.

It also holds the run's own bookkeeping. `.orchid/` — roadmap, journal,
blockers, `plugins.lock`, every review envelope — is committed on that branch
by design, because that is what makes a run survive a fresh checkout. If you
merge the integration branch into a branch bound for your `main`, those files
go with it, and in a large merge request they look like tooling and are
approved as tooling. Decide which you want before you take the work across:
[troubleshooting.md](./troubleshooting.md) — "Run state in your product's
history" — has both answers, and describes the two guards that will tell you
when it is happening (a warning from `orchid merge`, and a refused `git push`).

### Tearing it down

A completed run does not stop a schedule. Nothing does — not the last task
merging, not `orchid run accept`, not `run_status: complete`. If you installed
the service in step 6, the launchd agent or crontab line is still firing every
`pump_interval_s`, and every one of those wakes is now a certain no-op.

So when you are done with the working checkout, the order matters:

```sh
orchid service uninstall --repo "$PWD"        # FIRST — while the checkout exists
cd ..
git worktree remove your-project-orchid       # then this
```

Reversed, you leave a scheduler waking on a timer against a directory that is
no longer there, and the record naming that leftover schedule was inside the
directory you just deleted. `orchid service status` names this ordering next
to the schedule it applies to, and `orchid doctor` — run from anywhere on the
machine, not just from the repository — reports any binding whose repository
is gone, with the `orchid service uninstall` command that ends it. The pump
itself refuses to run, loudly, rather than waking against a deleted path.

`orchid service uninstall` is safe to run blind: it refuses cleanly, touching
nothing, when no schedule is installed for that path.

## Before you hand this to someone else

If you are about to point Orchid at a repository you do not already know it can
drive — someone else's project, or your own before a beta — qualify it first:

```sh
/bin/bash scripts/beta-qualify.sh --repo "$PWD" \
  --output "$(mktemp -d)/qualification" --bash /bin/bash
```

It times your verification command against `pump_stale_s`, checks whether the
configured implementer can run a command at all (two of the deadlocks that only
show up on a real codebase), reports the unattended trust gate without changing
it, and writes anonymized local evidence — check identities, durations, exit
codes, and outcomes, never contents, paths, prompts, diffs, or secrets. What it
cannot test locally, including the inbound half of the blocker round trip, it
records as `not-tested` with the reason rather than as a pass.

It executes exactly one thing inside that repository, and it says so on stderr
as it does: the repository's own configured `verify=` command, once, in place,
so the timing is measured instead of guessed. On someone else's project, read
their `verify=` line before you run this — it is their code, running with your
privileges, and the harness does not sandbox it. `--no-run-verify` skips it and
records that probe as `not-tested`. Qualification itself asks for no
acknowledgement; `orchid trust unattended` comes *after* this, once you know the
repository is drivable.

Full checklist, including the manual steps no harness can perform:
[beta-qualification.md](./beta-qualification.md).

## Next

- [beta-qualification.md](./beta-qualification.md) — qualifying a repository
  before a beta, and the local release rehearsal.
- [configuration.md](./configuration.md) — every key, its default, and
  which layer to set it in.
- [troubleshooting.md](./troubleshooting.md) — rate limits, resume, stale
  locks/leases, blocked tasks, stale/split-brain checkouts, pack overflow.
- [../README.md](../README.md#extending-orchid) — extending orchid with
  your own engine/role/hook/archetype/notify-channel plugin.
