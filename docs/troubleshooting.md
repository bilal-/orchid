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

## A task sits in `testing` and nothing verifies it

**Symptom:** `orchid status --explain` shows a task in `testing` as
`awaiting-operator-handoff`, and every `orchid drive` pass exits 16 with a
judgment boundary of kind `operator-handoff` without running `orchid verify`.

This is not a fault — it is the operator hand-off doing its job. Your
repository set `handoff_before_verify=required`, which says the implementer
here is an engine profile that cannot execute anything (it denies on the
command *string*), so this candidate's mechanical work — applying a linter's
own fix, re-pinning a release checksum, setting the mode bit on a newly added
executable — has to be done by you. The pass stops rather than verifying a
candidate that was never going to pass and spending one of the task's three
rework rounds on it.

```sh
orchid run boundary show           # what is being held, and why
orchid task show <id>              # candidate_sha, and handoff_ack beside it
# ...do the mechanical work in the task's worktree and commit it, giving each
# such commit the trailer "Orchid-Handoff: operator", then:
orchid task handoff <id> --ack --reason "re-pinned the formula; set the exec bit"
```

Commit first, acknowledge second: `--ack` moves `candidate_sha` forward to the
commit your hand-off produced and binds the acknowledgement to *that*. Without
it the record would keep naming the commit captured before you started, while
verification ran the tree you just committed — evidence about a commit nobody
verified. (It re-runs the `.orchid/` scan over `base_sha..HEAD` while it moves,
so a mechanical commit that touched state is refused here rather than slipping
past entry to `testing`.)

"Commit first" is enforced, not advice: `--ack` refuses while the tree has
uncommitted changes and prints the paths. Applying the fix feels like performing
the hand-off, but every sha this verb compares describes a *commit* — acknowledge
before committing and `handoff_ack`, `candidate_sha` and `HEAD` would all agree
about a commit that does not contain your work, while `orchid verify` runs the
tree that does. (Uncommitted `.orchid/` state does not count; it is no part of
the candidate.) If that read cannot be made at all — the `worktree` field names
a path that is not a checkout, or is a bare repository — the refusal says the
tree could not be *inspected*, which is a different problem from a dirty one and
is fixed by pointing the record at a real checkout, not by committing anything.
The same applies after the fact: edit the tree after
acknowledging and the next pass stops again until you either commit (then
re-`--ack`, since `HEAD` moved) or discard the edit (no second ack needed —
nothing was committed, so the acknowledgement standing still names the tree that
will run).

`--ack` is also refused from any status but `testing`. Past that point a
reviewer, an arbiter or a merge is already judging that exact commit, and
advancing `candidate_sha` underneath them would leave the record naming a
candidate none of them looked at. If you need to withdraw an acknowledgement
from one of those states, `orchid task handoff <id> --clear` is legal from
anywhere.

The acknowledgement is bound to the task's **current** `candidate_sha`, which
is why the next pass proceeds and why nothing has to remember that you did it.
It is invalidated the same way verify evidence is (INV-07): entry to `rework`,
`orchid task unblock`, `orchid task retry`, and `orchid merge`'s rebase arm all
clear it, because a rebased or reworked tree is a different candidate and work
done on the old one is not evidence about it. If a pass stops again right after
you acknowledged, compare the two fields — `handoff_ack` naming a sha other
than `candidate_sha` is exactly that invalidation, and the boundary reason
prints both.

Set `handoff_before_verify=off` (the default) if your implementer can run the
repository's own gates itself; nothing then gates and this boundary is never
raised. See [configuration.md](./configuration.md) and PROTOCOL.md's
"The operator hand-off".

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
first.

**Outbound** is `ok` only when the plugin resolves, its required binaries are
on PATH, *and* the config that plugin declares it cannot send without is set
(`requires_config=` in its manifest — `notify.to` is mandatory for openclaw
and optional for hermes). An unset one is called out here rather than
discovered as five silent retries and a quarantined message.

**Inbound** is genuinely probed when the configured plugin ships a probe
(`inbound_probe=` in its manifest — openclaw does, via `openclaw channels
status`): doctor runs it with a 10s deadline and reports REACHABLE, NOT
REACHABLE, or UNDETERMINED as the plugin itself determined. A gateway that is
down shows up here as NOT REACHABLE — that is the line that would have caught
the outage above on day one. Note what a REACHABLE result does *not* claim:
the transport your reply travels over is up, which is not proof that a
channel-side agent exists there to turn the reply into an `orchid answer`
call. For a plugin that declares no probe, doctor says NOT VERIFIED for that
plugin rather than pretending nothing could ever be known.

Alongside either, doctor shows local evidence: blockers still *waiting* for
an answer. Several you believe you already answered is the signature of a
broken return leg. Exactly one class is excluded and counted separately —
questions that expired past `answer_expiry_s` — because that is the one
refusal `orchid answer` itself enforces, so no answer can ever arrive and a
permanent warning would only train you to skim past the line. Task status is
*not* a filter: `orchid answer` never reads it, so a question raised on a task
now in `merging`, `arbitrating` or `rework` is still answerable and its
silence is still evidence. A task resolved locally with `orchid task unblock`
does leave its question answer-less by design; that one ages out through the
same expiry rather than being dropped on sight.

When nothing is waiting, doctor reports the *absence* — "no question is
currently unanswered" — and says so as an absence. It is not an all-clear on
the return leg: a channel that drops every reply looks identical to a healthy
one until something is actually asked. The probe above is the line that
speaks to liveness; this one only tells you whether anything is outstanding.

Every line here is advisory — a run with no channel at all is legitimate and
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

## Stale orchid itself (`refusing to run`)

**Symptom:** every verb refuses immediately with `refusing to run: the
checkout orchid itself runs from (...) sits on the integration branch ..., and
its INDEX does not match HEAD for the code orchid executes:` followed by the
paths, and by any unstaged modifications as context.

**The refusal does not tell you the cause, on purpose, and neither can this
page without you looking first.** Exactly two things leave the index not
matching HEAD in those paths, and from inside the checkout they are
indistinguishable:

1. `orchid merge` advanced this branch with `update-ref`. That moves `HEAD`
   and touches neither the index nor the working tree, so the index is left
   describing the commit the branch moved off. Nothing of yours is here.
2. Someone ran `git add` on a kernel edit in this checkout. Those bytes exist
   nowhere else.

The remedy for (1) — restoring the kernel paths to `HEAD` — is a silent,
unrecoverable data loss under (2). Two earlier versions of this guard guessed,
and guessed wrong: one read a hand-edited kernel as a branch advance, the next
did the same to a staged edit, and both printed the restoring command. So the
refusal now reports and stops. Look before you type:

```sh
git -C <root> status --short -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
git -C <root> diff --cached HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
```

If the second command shows changes you recognise as your own, you are in case
(2) — go to *Case (2)* below. If it shows the shape of a merge you did not
make in this checkout, you are in case (1) — go to *Case (1)*. If you cannot
tell, `git -C <root> log --oneline -3` on the branch
and the paths above will usually settle it; there is no hurry, and the override
at the bottom of this section runs a single read-only verb meanwhile.

This is the same staleness one level down, and it is a refusal rather than a
warning because the advisory version was read and dismissed for a full day
while it mattered. `bin/orchid` resolves `ORCHID_ROOT` from its own location,
so every verb, every `lib/*.sh`, every `runners/*` and every
`plugins/engines/*/run` is read from **that checkout's working tree** — not
from the branch head. `orchid merge` advances the integration branch with
`update-ref` alone, on purpose, so it never reaches into another checkout's
index or working tree. Run orchid out of a checkout of that branch and it
keeps executing pre-merge code indefinitely while every merge reports
success.

**An ordinary dirty working tree is not this, and never refuses.** The check
looks at the **index**, not the working tree, precisely so that editing
`lib/*.sh` and running `orchid` in the integration checkout — which is how
orchid is developed — keeps working. Only `git add` (or a branch advanced
under you) puts a kernel change in the index. The cost of drawing the line
there is stated rather than hidden: a checkout that fell behind and then had
`git reset` run in it has an index matching `HEAD` again and is *not*
detected — by this check or by any other. Catching it would mean refusing on
every ordinary edit, which is the trade that made the tool unusable. If you
have run `git reset` in the integration checkout, `git -C <root> diff HEAD --
<kernel paths>` is what tells you whether its code is current.

The same applies to `PROTOCOL.md`, which is not code and is executed all the
same: the skills under `skills/` carry no procedure of their own, they tell
the engine to read `$ORCHID_ROOT/PROTOCOL.md` and follow it, so a merge that
changes only the protocol leaves a stale checkout running the **pre-merge
procedure**. It is compared and refreshed exactly like the eight directories.

Only self-hosted setups can hit this — an installation root that is not a git
checkout (the `brew`/`install.sh` prefix) has no branch for anything to
advance. Nor does it reach a **separate clone**: refs are per-repository, so
your clone's `HEAD` does not move when the origin's integration branch does,
its working tree goes on matching its own `HEAD`, and there is nothing for
this check to compare. A clone goes stale the ordinary way and is refreshed
the ordinary way (`git pull`). What *is* covered is any checkout that shares
the advanced ref — a linked worktree (`git worktree add`), or a second
checkout of the same repository parked on that branch.

**You should rarely see it at all.** The merge that creates the condition
repairs the checkout it is itself running from: after the ref advance,
`orchid merge` restores that one checkout's kernel directories to the branch
it just moved, prints `refreshed <path> to <branch>`, and the run goes on
executing its own merged work. The refusal is for the checkouts no process
owns — a parallel checkout of the same branch, or one whose kernel files you
had already changed (which is the one case `orchid merge` deliberately will
**not** refresh, because refreshing it would throw your edits away). In that
last case the merge says so on stderr as it happens (one line, wrapped here):

```
orchid: warning: orchid/integration advanced and orchid runs from this
checkout (...), but its kernel files were already modified before the merge
— refreshing would have discarded that work, so it was not done. Modified:
<paths> — those bytes are in this checkout and nowhere else. ... Deal with
the edit whichever way you want it kept, then bring this checkout to
orchid/integration yourself.
```

**That warning is the one place the cause is known**, because the merge saw
the checkout before it advanced the branch. If you have it in your scrollback,
your own edit is why the next verb refuses and you are in case (2) — no
further diagnosis needed.

The merge also stands its refusal down for the fraction of a second between
its ref advance and its refresh, so an `orchid status` or a heartbeat that
happens to start in that window does not fail for a condition already being
repaired. It does that by publishing its own PID at
`.orchid/runtime/kernel-refresh` and standing down only while that process is
alive; a merge killed mid-refresh therefore leaves the refusal working.

### Case (2), a change of yours in the index: save it first

`git -C <root> diff --cached HEAD -- <kernel paths>` showed changes you
recognise. Those bytes exist nowhere else, so deal with them *before* the
restore below, which overwrites them:

```sh
git stash push -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
# ...or commit them on a task branch and let the run merge them.
```

If you only want to keep working with the change live — the ordinary case for
someone developing orchid in its own integration checkout — don't restore at
all; unstage it (`git -C <root> reset -q HEAD -- <kernel paths>`, which leaves
the file contents alone) or run with the override at the bottom of this
section.

### Case (1), the branch was advanced under you: restore orchid's own code

This is the case where the restore costs nothing, **once you have established
that it is the case you are in** — every byte it overwrites is already in the
object store. Nothing but your own look at `git diff --cached HEAD` above
establishes that; orchid will not assert it for you.

```sh
git checkout HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
```

Then re-run the verb. Note what that command does *not* name: `.orchid/`,
`orchid.config` and `requirements.md` are outside it, so uncommitted run
state, a config edit awaiting `orchid config commit` and a requirements draft
are untouched. Prefer it over `git checkout HEAD -- .`, which restores your
pending `orchid.config` and `requirements.md` along with the kernel — and
which, without `':(exclude).orchid'`, clobbers uncommitted `.orchid/` run
state as well. (Dogfood finding F31 is an operator's `requirements.md` edit
lost to a restore run to clear a refusal — the same shape as the two rounds
in which this refusal itself printed that command against a state it had
misread, which is why it now prints none.)

**If the refusal survives that command**, the branch *deleted* a kernel file
your checkout still has. `git checkout <tree> -- <paths>` never removes an
index entry the tree has dropped, so that file stays tracked and keeps
counting as drift. Clear it with:

```sh
git reset -q HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
git checkout -q HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
git clean -qfd -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
```

The `git clean` step removes **every** untracked file inside those eight
directories, not just the one the reset dropped — check `git clean -nd -- ...`
first if you keep scratch files under `plugins/`. It cannot reach `.orchid/`,
`orchid.config` or `requirements.md`, which are outside the pathspec.

**The other way the refusal survives a refresh** is an untracked file of your
own sitting at a path the branch has since added — say a draft
`libexec/orchid-foo` here, and a merged `libexec/orchid-foo` there. `orchid
merge`'s automatic refresh will not overwrite it (it reports
`could not be fully refreshed` and points you at `git status`), because from
the drift list alone that path is indistinguishable from a merged file that
simply has not been written here yet, and the branch's copy is not the one at
risk. Move or delete your file, then re-run the refresh. The hand-run
`git checkout HEAD -- <paths>` above makes no such distinction — it will
overwrite it — which is the difference between a command you typed and one a
merge ran on your behalf.

Two things this deliberately does **not** do. It only asks about a checkout
parked on the **integration branch** — the one branch a run merges onto, and
so the only one that can move behind your back. A development checkout on
`main`, on a feature branch, or in a task worktree is never asked, however
dirty it is. And even on the integration branch it only compares what the
launcher executes — the eight directories `bin/`, `lib/`, `libexec/`,
`runners/`, `plugins/`, `roles/`, `skills/`, `templates/`, plus `PROTOCOL.md`
— so an uncommitted `orchid.config` awaiting `orchid config commit`, a
`requirements.md` you are still drafting, or `.orchid/` run state the branch
has since moved past is not a refusal.

And it does not refuse over an ordinary uncommitted edit. Editing kernel files
in the integration checkout is how orchid is developed; only staging one puts
it in the index, where it becomes indistinguishable from a branch advance and
so has to be reported. If a `git add -A` is what put it there and you meant to
keep iterating, unstage it and carry on:

```sh
git -C <root> reset -q HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
```

`git reset` without `--hard` moves index entries only; every byte in your
working tree is left exactly as it was.

To run a single command from a checkout you know is stale — to read something
out of it, or to recover — prefix it:

```sh
ORCHID_ALLOW_STALE_ROOT=1 orchid status
```

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
