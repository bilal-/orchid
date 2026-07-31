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

<!-- SCREENSHOT: terminal — orchid doctor's readiness report after install -->

## 1. Clone and install

```sh
git clone <this-repo-url> "$HOME/src/orchid"
cd "$HOME/src/orchid"
./install.sh
```

`install.sh` does exactly and only: symlinks `skills/{orchid,orchid-plan,orchid-resume}`
into `~/.claude/skills/` (so a Claude Code session can drive orchid via
those three skills), symlinks `bin/orchid` into `~/.local/bin` (add it to
`PATH` if the installer warns it isn't there), creates
`~/.orchid/{plugins,trust}` and a commented `~/.orchid/config`, then finishes
by running `orchid doctor` if your current directory is a repo to
orchestrate. `./install.sh --uninstall` reverses precisely those
symlinks/dirs (your config and trust store are left in place).

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
orchid plan apply --reason "initial plan"
```

<!-- SCREENSHOT: terminal — orchid plan apply committing the first roadmap -->

## 5. Start the orchestrator and walk away

Two equivalent front-ends execute the same `PROTOCOL.md` procedure — pick
whichever fits how you work:

**Interactive (default bindings — a Claude Code session):** open Claude
Code in this worktree and invoke the `orchid` skill (installed in step 1).
It reads `PROTOCOL.md` and drives the tick via `orchid` verbs, the same
commands shown throughout this page.

**Headless, right now:**

```sh
orchid run start
runners/orchid-tick
```

**Headless, unattended (recommended once you trust the loop):** install the
pump as a background service so ticks continue even after you close the
terminal:

```sh
orchid service install
```

See [quickstart's service section below](#6-keep-it-running-unattended) —
or skip straight to it now if you don't want to babysit a terminal.

## 6. Keep it running unattended

```sh
orchid service install
```

Installs a launchd agent (macOS) or a crontab line (Linux) that runs
`runners/orchid-pump` on an interval (`pump_interval_s`, config, default
`240`) — a no-op most passes, and a single headless tick whenever the
interactive session's lease has gone stale. `orchid service status` reports
whether it's loaded and when it last ran; `orchid service uninstall`
reverses it.

## 7. Check in

```sh
orchid status               # task table, engines, open questions
orchid status --explain     # + why each pending/rework task isn't dispatching
orchid status --html        # writes a static page to runtime/status.html —
                             # open it directly, "check from another room"
```

<!-- SCREENSHOT: orchid status --html rendered in a browser -->

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
product — pushing or deploying it from there is entirely up to you; orchid
never pushes anywhere on its own.

## Next

- [configuration.md](./configuration.md) — every key, its default, and
  which layer to set it in.
- [troubleshooting.md](./troubleshooting.md) — rate limits, resume, stale
  locks/leases, blocked tasks, stale/split-brain checkouts, pack overflow.
- [../README.md](../README.md#extending-orchid) — extending orchid with
  your own engine/role/hook/archetype/notify-channel plugin.
