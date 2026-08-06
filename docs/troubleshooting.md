# Troubleshooting

Every entry below is a **real incident** hit while dogfooding orchid on
itself (`docs/dogfood-notes.md`'s F-numbered findings), with the exact
remedy verb that fixed it — not a hypothetical.

## Rate limits

**Symptom:** an engine's calls start failing with a `rate_limited` envelope
status, or `orchid status` shows an engine as unavailable.

Orchid never treats a rate limit as a run failure: `orchid jobs reconcile`
marks the engine `rate_limited` in `runtime/engines.json` for a window sized
by `rate_limit_backoff_s` (config, default `3600`) or the envelope's own
`retry_after`. Dispatch falls back to the role's next chain entry once it
has passed the capability suite (`orchid plugins test <engine> <role>`); if
no fallback is eligible, the affected task's jobs simply wait — a rate
limit pauses one engine, never the run. No operator action is required;
`orchid status` (`== engines` section) explains what's rate-limited and
until when. To force a retry sooner (e.g. you know the vendor's quota reset
early), there is no override verb — the ledger window is time-based by
design, so waiting it out or configuring a fallback chain
(`role.<role>=<primary>,<fallback>`) is the supported path.

## Unattended trust refusal

**Symptom:** the pump, direct headless tick, or `orchid service install`
prints `unattended trust is denied` and exits before acting.

```sh
orchid trust show "$PWD"
orchid status --explain
```

Read the `why` field. With no record, review the target repository as
potentially prompt-injecting input, then acknowledge it with an honest reason:

```sh
orchid trust unattended "$PWD" --reason "reviewed target and accept unattended prompt risk"
```

A root-commit or policy mismatch is deliberately not auto-updated; inspect
the changed history/policy and run the same acknowledgement command again
only if the new boundary is acceptable. A clone, copy, or recreated `.git`
needs its own decision. Normally its Git common-directory device/inode is
different; even if the filesystem reuses those numbers, its common-directory
witness cannot match the old machine-local hard-link anchor.
`orchid trust revoke "$PWD"` denies future pump/tick invocations. It does not
remove a scheduler entry, so use `orchid service status` and `orchid service
uninstall` as needed; both remain available while denied. Revocation only
needs the repository's on-disk identity, so it also works when `orchid trust
show` cannot finish — an unsupported Git, or a mismatched, shallow,
object-missing, or corrupt history. Revoke in that situation rather than
leaving the record in place: it would apply again once the repository is
readable. Revocation still needs a usable `.git` marker to know which record
applies; if a linked worktree's own marker or registration is broken, revoke
from the main checkout, which shares the same record.

## An installed service runs on schedule but nothing happens

**Symptom:** `orchid service status` looks healthy, the scheduler fires, and
`.orchid/runtime/pump.log` is empty or missing.

The pump is being denied at the unattended gate. Its output goes to
`/dev/null` (that is what the installed cron line and launchd agent specify),
and it deliberately does not open the repo-local `pump.log` until after the
gate passes — so a refusal leaves no repo-local trace by design. Look at the
machine-local record instead:

```sh
orchid doctor
tail ~/.orchid/unattended-trust/refusals.log
```

Each line carries the time, the refused surface, the repository, the binding
state, and the gate's own reason — `unattended trust is denied — <why>`, the
wording the refused invocation would have printed, where `<why>` is the same
text `orchid trust show` reports. Fix the cause above and the next scheduled
invocation proceeds; nothing needs to be cleared.

If the `why` names a missing `jq`, `jq`'s location — not the scheduler's
environment — is the problem. Every unattended entry point (the pump and the
headless tick runner) overwrites `PATH` with a fixed list of system prefixes
at entry, so whatever `PATH` a scheduler hands it is never consulted, and
re-running `orchid service install` cannot change the answer.
The gate prints the exact list it searched; install `jq` into one of those
directories (`/usr/local/bin`, `/opt/homebrew/bin` and `/usr/bin` are on it)
or symlink it there. A `jq` in `~/.local/bin`, a nix profile, or an
asdf/cargo shim is invisible to headless runs by design.

`orchid doctor` and `orchid status --explain` evaluate the same probe on the
same fixed `PATH`, so they now agree with the gate instead of reporting `ok
jq` about a `jq` no scheduled run can reach. When the two `PATH`s disagree
they say so explicitly: doctor prints a `WARN:` line naming the surface that
is short, and `status --explain` prints an `unattended_tools: WARNING:` line.

## Unattended trust breaks after a machine-wide deduplication pass

**Symptom:** repositories that were acknowledged and working start reporting

```
binding_state: mismatch
why: repository incarnation anchor does not match the machine-local
     acknowledgement, and Git's common-directory identity witness
     <repo>/.git/description carries N hard links ...
```

and re-acknowledging fails with `unexpected hard-link alias`.

A disk-space deduplicator — `jdupes -L`, `rdfind -makehardlinks`,
`hardlink(1)`, and some backup/sync tools — replaces byte-identical files
with hard links to one copy. Git's stock `.git/description` is identical in
every repository on the machine, so such a pass links them all together.

Orchid binds each acknowledgement to a two-link pair: `.git/description` and
a second link to that same inode under `~/.orchid/unattended-trust/`. A
foreign third link breaks the pair, and that refusal is deliberate — the
gate cannot tell a deduplicator's link from an attacker's, so it fails
closed both at the gate and at re-acknowledgement.

The fix is cheap and lossless, because Orchid never reads the witness's
contents and Git does not track them. Give the file an inode of its own
again, then acknowledge the repository once more:

```sh
cp .git/description .git/description.orchid-new
mv .git/description.orchid-new .git/description
orchid trust unattended "$PWD" --reason "reviewed target and accept unattended prompt risk"
```

From a linked worktree, `.git` is a file rather than a directory: use the
path `orchid trust show` prints as `identity_witness`, which is the shared
common directory's `description`. Linked worktrees share one record, so one
repair covers them all.

Do this per affected repository. To keep it from recurring, exclude
`.git/description` (or the whole `.git` directory) from the deduplicator's
scan.

## Resume (crash / restart)

**Symptom:** the interactive session died mid-run (crash, closed terminal,
laptop sleep) and you're picking a run back up.

```sh
orchid run resume
orchid jobs check
orchid jobs reconcile
orchid status --explain
```

`orchid run resume` fences a fresh epoch and, if the previous run's lock is
held by a dead or foreign owner past `lock_break_s` (config, default `900`),
breaks it — journaled. `jobs check` kills anything genuinely
stalled/timed-out from before the crash; `jobs reconcile` lands any
already-finished envelopes. Never re-adopt an ambiguous process by hand —
job identity is `job_id` + pgid + start-time; an unidentifiable one is
confirmed dead and relaunched cleanly. See PROTOCOL.md's `RESUME` section
for the full capsule-loading walk a resuming session performs before
touching any task.

**Headless equivalent:** you don't need to do any of this by hand at all —
`runners/orchid-pump` (acknowledged and installed as a service, see
[quickstart.md](./quickstart.md)) detects an abandoned run itself (a lease
older than `pump_stale_s`, default `900`) and runs the exact same resume
sequence via `runners/orchid-tick` on its own.

## Stale locks / lease

**Symptom:** a verb refuses with a lock-held error, or `orchid status`
shows a lease that looks old.

- A **verb lock** (per-verb transactional locking) that a dead process still
  appears to hold is broken automatically by the next verb invocation once
  its owner fails the liveness check (dead pid, pid-start-time mismatch, or
  foreign hostname) **and** it's older than `lock_break_s` — nothing to do
  by hand; `orchid run resume` breaks the coarser run-lock the same way.
- A **stale lease** (`runtime/lease.json`, the orchestrator's own heartbeat)
  is not a lock file — it's the pump's mutual-exclusion signal
  (`pump_stale_s`). If you're ending a session cleanly and want the pump (or
  `orchid run new`) to treat this run as done-with immediately, rather than
  waiting out `pump_stale_s`:

  ```sh
  orchid run release-lease
  ```

  This writes `released: true` into the lease so both the pump and `run
  new`'s freshness guard treat it as immediately stale, regardless of how
  recently it was refreshed. PROTOCOL.md's `COMPLETION` procedure ends every
  run with it.

## Stale epoch

**Symptom:** a verb refuses immediately with `stale epoch '...' (current N)
— refused (INV-02)`, often on the very first mutating verb after `orchid
init` (`orchid requirements import`, `orchid task create`, ...).

Every mutating verb fences itself against a monotonic **epoch**
(`ORCHID_EPOCH`) via `epoch_require` — INV-02: a stale (or unset) epoch can
never mutate durable state, by design. A fresh `orchid init` starts the
epoch at `0`, but nothing prints it until `orchid run start` does, so
export it by hand right after init:

```sh
export ORCHID_EPOCH=0
```

`orchid run start`, `orchid run resume`, and every headless tick
(`runners/orchid-tick`) mint a **new** epoch — re-export after each one, or
the very next verb call in that shell hits this exact error:

```sh
export ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"
```

## Blocked tasks

**Symptom:** a task sits in `blocked` (rework attempts exhausted, a genuine
question raised via `orchid notify`, or an operator-invoked stop).

```sh
orchid task show <id>              # read the blocking reason + BLOCKERS.md
orchid journal show --task <id>    # the task's decision capsule
orchid answer <qid> <choice>        # answer an open question (if one exists)
orchid task unblock <id> --reason "<qid>: <answer text>"
# -- or, when nothing needs to change and it should just try again:
orchid task retry <id> --reason "..."
```

`orchid task unblock`/`orchid task retry` are validated transitions:
guidance is recorded into the task body and the intervention is logged in
the journal — never hand-edit a task file to un-stick it. If the block came
from a raised question (`orchid notify`), answer it first
(`orchid answer <qid> <choice>`, `--nonce <n>` required once
`answer_allowlist` is configured — see
[docs/engines/openclaw.md](./engines/openclaw.md#inbox-hardening-orchid-answer))
so the guidance text exists before `unblock` folds it in.

## Answers sent on a channel never arrive

**Symptom:** blockers reach your phone, you answer them there, and the run
stays blocked — no `blocker_resolved` entry in the journal, no `.answer`
file, no trace at all locally.

Sending and receiving are **different legs with different requirements**.
Outbound needs only a CLI on this machine (the pump runs the notify plugin's
`send`). Inbound needs a persistent agent on the *channel* side that turns
your reply into an actual `orchid answer` invocation against this repo —
orchid ships no inbound listener and neither starts nor supervises that
agent. A gateway that is down (or a skill that was never installed there)
loses every answer silently, because nothing local is involved in the
attempt.

```sh
orchid doctor            # read the "notify outbound" / "notify inbound" lines
```

Doctor reports the two separately and never infers the second from the
first: outbound is `ok` when the plugin and its binaries resolve, while the
return leg is always reported as **NOT VERIFIED** — its liveness is not
portably observable from here, so doctor states that rather than implying
it. What doctor *can* show is local evidence: blockers raised with no answer
recorded beside them. Several unanswered blockers you believe you already
answered is the signature of a broken return leg.

Both lines are advisory — a run with no channel at all is legitimate and
stays green. To answer while the return leg is down, run the command
`BLOCKERS.md` prints for the question directly on this machine.

## Stale checkout

**Symptom:** `orchid doctor`/`orchid status` warns `integration checkout is
stale`, or a commit you just watched land on the integration branch (from
another worktree, or a pump-driven `run accept`/`plan apply`) seems to have
silently reverted files that a passing task had just added.

This is the real incident behind it: a long-lived checkout of the
integration branch whose ref gets advanced from **outside** that checkout
(another worktree's commit, a headless tick) falls behind its own branch
pointer without its index/working tree ever refreshing. A naive `git add -A
&& git commit` from that stale checkout re-commits whatever stray staged
deletions the stale index still carries — a silent revert of real history.

**Never hand-commit `orchid.config` (or anything else) from a checkout of
the integration branch directly.** For a config change, use the safe path
instead:

```sh
orchid config commit --reason "..."
```

This stages exactly `orchid.config`'s current on-disk content into a
separate temp worktree of the integration branch and commits it there —
never touching your checkout's own git index. For any other reason you need
to refresh a stale checkout by hand:

```sh
git checkout HEAD -- . ':(exclude).orchid'
```

**Not** a bare `git checkout HEAD -- .` — that would also clobber any
uncommitted `.orchid/` run state sitting in that checkout.
`orchid doctor`/`orchid status` detect and name this condition
automatically (staged-deletion signature against the checkout's own
branch), before you ever act on stale state by accident.

## Split-brain checkout

**Symptom:** `orchid doctor`/`orchid status` warns `split-brain checkout`,
or the pump reports "run complete" on a checkout where you know work is in
progress.

`orchid init` restores your own branch when it finishes — durable `.orchid/`
state (`roadmap.md` and everything gated on it) lives only on the
integration branch. Running task verbs from your own branch happily builds
untracked `.orchid/` state there anyway (nothing else on disk distinguishes
it from a healthy repo, except that `roadmap.md` never landed) — and a pump
reading that checkout sees no roadmap and assumes there's nothing to do.

**The fix is to always work from the integration branch or a worktree of
it** — exactly what `orchid init`'s own final output tells you to run:

```sh
git worktree add ../<repo>-orchid <integration-branch>
cd ../<repo>-orchid
```

`orchid doctor` and `orchid status` both detect this condition (`tasks/` or
`journal.md` present, `roadmap.md` absent) and name it by exactly this
name, rather than leaving you to debug a missing roadmap.

## Pack overflow

**Symptom:** an engine launch fails with `input_overflow` on a review,
critique, or implement job.

`input_overflow` is a **task-shaping signal first**, not a config problem:
the correctness-critical parts of a job's input (task body, acceptance
criteria, the diff for reviews) are non-truncatable, and when they alone
exceed the job's byte budget, the launch fails rather than silently
truncating. The prescribed response is to **split the task**:

```sh
orchid task set <id> ...   # narrow scope, or split into <id>-a/<id>-b
```

journaled as a `plan_revision`. Two things reduce how often this happens
without touching a budget at all:

- A review/critique diff larger than `pack_diff_inline_max_bytes` (config,
  default `262144`) is automatically relieved when the resolved
  reviewer/critic declares `workspace_read` — the pack ships `diff.stat` +
  `symbols.txt` instead of the full patch (the engine reads the worktree
  itself). An inline-only engine (agy, hermes) gets no such relief; a
  diff that large still overflows for those engines specifically — route
  the task's `review.<tier>` chain to a worktree-capable reviewer
  (`codex-review`, `claude`) instead.
- `agy_max_bytes` / `hermes_max_bytes` are separate, smaller ceilings that
  make those two inline-only adapters fail closed **before** even invoking
  the vendor CLI on an oversized diff — same idea, engine-specific.

Raising `pack_budget_bytes` in `orchid.config` is a legitimate **operator**
decision (e.g. a repo whose tasks are genuinely large-diff by nature), but
it is deliberately not the first thing to reach for — task-splitting keeps
every engine's job bounded and reviewable regardless of which one is
bound to a role.

## Scheduled pump can't find jq / engine CLIs

**Symptom:** `orchid service install` succeeds and `orchid service status`
reports installed/loaded, but the pump's own log
(`.orchid/runtime/pump.log`) shows failures that look like a missing
command (`jq: command not found`, or an engine CLI failing to launch)
even though the same repo runs fine by hand.

A launchd user agent starts from launchd's own bare default PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`); a cron fallback's environment is
scarcely richer. Neither ever sources an interactive shell's profile, so
`jq` (a Homebrew install) and every engine CLI the pump's tick execs
(`claude`/`codex`/`hermes` — npm or Homebrew paths) can be invisible to a
scheduled run even though they're on the operator's own `$PATH`.

`orchid service install` bakes the installing user's own `$PATH` (captured
at install time) into the rendered plist's `EnvironmentVariables` /
the cron line's `PATH=` prefix — re-run `orchid service install` after
changing your `$PATH` (e.g. installing a new engine CLI) so the scheduled
pump picks up the change; editing the shell's profile alone does not touch
an already-installed schedule. For safety, the pump holds that captured value
without searching it while unattended trust is checked; pre-gate Git/jq and
filesystem helpers resolve only from fixed system, Homebrew/Linuxbrew, or
MacPorts directories. The captured operator path becomes active only after
trust succeeds, in time for engine/plugin discovery and execution.

## See also

- [docs/configuration.md](./configuration.md) — every config key named
  above, with its default and which layer it belongs in.
- [docs/quickstart.md](./quickstart.md) / [docs/quickstart-greenfield.md](./quickstart-greenfield.md)
- `docs/specs/kernel.md`'s Guardrails & failure handling and Stuck-agent
  detection sections (the normative behavior this page explains in
  operator terms).
- `docs/dogfood-notes.md` — the full incident log these remedies are drawn
  from.
