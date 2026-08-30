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

## An engine keeps declining the work it is handed

**Symptom:** `orchid jobs reconcile` prints `refusal: <task> <engine>
declined by design`, and `orchid status`'s `== engines` section shows that
engine as `ok` with `refusals <n>` climbing. The job log names the reason —
typically `diff.patch is <n> bytes (> agy_max_bytes=100000); route to a
worktree-capable reviewer`.

This is not an engine problem and orchid deliberately does not treat it as
one: the engine read the request, recognized it as outside what its adapter
declares (an inline-only reviewer cannot see a diff it is not given), and
refused correctly. It keeps its health record and its place in every role
chain, so it goes on getting the work it *is* good at. Nothing is stuck.

Read the refusals as ROUTING, not health. If they keep appearing for the same
role, the remedy is on the chain, not on the engine: put a worktree-capable
reviewer on it (`role.reviewer=<worktree-capable>,<inline>`, with
`orchid plugins test <engine> reviewer` for a fallback), or raise that
adapter's cap (`agy_max_bytes` / `hermes_max_bytes`) if the diffs are only
marginally over and you want the inline reviewer to keep taking them.

Before v1-m5 these refusals were counted as engine faults, and on r-002 three
of them (diffs ~1% over the cap) marked a well-behaved reviewer `failing`,
halved that run's independent reviewer pool, and left a task stranded whose
review had already been filed. If you are reading an older ledger where an
engine went `failing` with no real errors in its logs, that is what happened;
an unrelated `ok` mark clears the streak.

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

## A run looks busy but nothing is moving

**Symptom:** `orchid status` shows a task in an active status, the log for its
job has plenty of plausible content in it, and hours pass with nothing landing.

This has cost three runs multi-hour stalls, and in the third it produced a
false report: a session told its operator that a critique was "actively
working" and quoted its recent findings, while that job had been **dead for
twelve and a half hours**. The findings were real. They were simply stale, and
nothing in what either the operator or the session was reading said so.

Everything needed to notice was already on disk, so the answer is one command:

```sh
orchid jobs ls
```

One row per outstanding job — job id, task, role, operation, attempt, engine,
pid, state, age, elapsed, budget consumed, who launched it, and its log path.
Two columns settle this symptom:

- **STATE is computed, never read.** A manifest records the pid its launcher
  stamped and nothing ever unstamps it, so the file reads the same whether the
  process is running or was killed yesterday. Every row asks the kernel
  instead: `running`, `dead` (process gone, no envelope — this one needs you),
  or `delivered` (process gone, envelope written and waiting for the next
  `orchid jobs reconcile` — this one does not). For `pid: 0`, no log means
  `never-started`, a fresh log means `prepared` (the engine may still be
  running), and a log silent past `stall_minutes` means `unstamped`; the
  latter two are explained in detail below.
- **AGE is how long since the job last wrote anything.** Content in a log says
  nothing about whether the process behind it still exists; the log's mtime
  does. An `AGE` of `12h30m` beside a `dead` state is the whole diagnosis.

You do not have to remember to run it. A job that is dead with no envelope,
never-started past the threshold, unstamped, or running but silent past
`stall_minutes` prints a `WARNING:` line on stderr that `orchid status` shows
in every mode, with no flag:

```
WARNING: job j-e12-T031-a4-9c2f (T031 reviewer/review a4, claude, pid 40122, by pump) is dead and left no envelope — it ran 41m18s and last wrote 12h31m ago; escalate or relaunch (log: ...)
```

`orchid status --jobs` puts the same table in status's `== jobs` section
(unflagged, that section keeps `orchid jobs check`'s machine-facing task/state
pairs), the static page has a Jobs section, `orchid jobs ls --watch` polls it,
and `orchid jobs ls --all` adds the jobs that already finished — what a task
ran, in what order, and how long each took.

If the answer is that the *driver* stopped rather than a job — no rows at all,
nothing in flight, and the run parked mid-walk — see
[Stale locks / lease](#stale-locks--lease); a supervising loop that exits at a
judgment boundary leaves exactly that shape, and cost one run seven hours.

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

**Symptom:** a task sits in `blocked` (rework attempts exhausted, a rework
loop that stopped converging, a genuine question raised via `orchid notify`,
or an operator-invoked stop).

```sh
orchid task show <id>              # read the blocking reason + BLOCKERS.md
orchid journal show --task <id>    # the task's decision capsule
orchid answer <qid> <choice>        # answer an open question (if one exists)
orchid task unblock <id> --reason "<qid>: <answer text>"
# -- or, when nothing needs to change and it should just try again:
orchid task retry <id> --reason "..."
# -- ...and when the block was "attempts exhausted", grant rounds too:
orchid task retry <id> --reason "..." --attempts 2
# -- or, when the tree is already green and only verification needs re-running:
orchid task reverify <id> --reason "..."
```

`orchid task unblock`/`orchid task retry` are validated transitions:
guidance is recorded into the task body and the intervention is logged in
the journal — never hand-edit a task file to un-stick it. If the block came
from a raised question (`orchid notify`), answer it first
(`orchid answer <qid> <choice>`, `--nonce <n>` required once
`answer_allowlist` is configured — see
[docs/engines/openclaw.md](./engines/openclaw.md#inbox-hardening-orchid-answer))
so the guidance text exists before `unblock` folds it in.

**Which of the three, and what each one actually does:**

| verb | use it when | attempts | what the reason does |
| --- | --- | --- | --- |
| `task unblock` | the answer changes the plan | unchanged | written into the task body |
| `task retry [--attempts N]` | nothing needs to change; `--attempts N` when it needs more than one more round | counter unchanged; the **budget** is raised to `attempts + N` (default `N` = 1) when the task has none left, never lowered | written into the task body |
| `task reverify` | the tree is already green — the failure was environmental, or you fixed it yourself in the task worktree | **none consumed** | journaled |

"Written into the task body" is the part that matters: the task file is what
the implementer's capsule carries, so a diagnosis put there is genuinely read
by the next attempt. Each verb prints a line telling you where the reason
went, so you never have to guess whether it was delivered.

`unblock` and `retry` both end in `rework`, and every entry to `rework`
deletes `reviews/<id>-verify.log` to keep INV-11's evidence gate armed — so
both copy it into `reviews/<id>-r<n>-rework.log` first and count the round,
exactly as the driver's own rework edge does. That matters most on `retry`:
the `attempts exhausted` stop parks the task at `blocked` without touching
the log, so the run that spent the last attempt is still fully documented
when you grant another round, and the round you grant is dispatched with that
output verbatim rather than with a pointer to a file the grant deleted. Two
such rounds failing identically therefore build the same
`rework_signature_repeats` streak a driver-run loop would — which is the
intent: an identical failure is not less of a repeat for having been retried
by hand.

Both verbs delete `reviews/<id>-merge.log` as well, so both look there too
when the verify log has nothing failing to say. That is the shape a red
repo-wide `merge_gate` leaves: the candidate's own suite PASSED (which is how
it reached `merging` at all), the gate went red, and once it has been red for
every round the task's budget allows, `orchid merge` parks the task at
`blocked` with both logs on disk. The verify log is a pass, so the failure you
are unblocking exists only in the merge log — and it is captured before it
goes, exactly like a verify failure. A merge log describing a candidate the
task has since moved off is refused instead, and the refusal says so in the
journal.

## A task sits in `testing` and nothing verifies it

**Symptom:** `orchid status --explain` shows a task in `testing` as
`awaiting-operator-handoff`, and every `orchid drive` pass exits 16 with a
judgment boundary of kind `operator-handoff` without running `orchid verify`.

This is not a fault — it is the operator hand-off doing its job. Your
repository set `handoff_before_verify=required`, which says the implementer
here is an engine profile that cannot execute anything (it denies on the
command *string*), so this candidate's mechanical work — applying a linter's
own fix, setting the mode bit on a newly added executable, running a generator
whose output is checked in — has to be done by you. The pass stops rather than
verifying a candidate that was never going to pass and spending one of the
task's configured `rework_max` rounds on it.

One thing is deliberately *not* on that list: an artifact derived from the
whole tree, such as the release-archive checksum pinned into
`Formula/orchid.rb`. Regenerating one per candidate makes every candidate
rewrite the same line to a different value, and the second to merge then
conflicts on it with nobody in the loop able to resolve it. Those are
regenerated on the integration branch instead — see
[contributing.md](./contributing.md#release-rehearsal).

The boundary can instead say the `mechanical` step could not be routed to the
engine that built this candidate (INV-16). `orchid run boundary show` says
which arm held it; either way, nothing was dispatched and no attempt was spent.

By far the likeliest reading is the first: you set the key. The routing arm
does **not** normally fire for a shortfall in an implementer's declared
capabilities, because `roles/implementer.role` requires
`workspace_write,shell,git` — an engine short of those is refused the role at
dispatch (`no eligible engine`, exit 14) and never builds a candidate for this
pause to hold. What that arm does catch is the wording below.

**The other wording of the same stop:** the boundary says the actor *is not
installed* rather than naming a capability, and names it. Then the engine
recorded against this candidate answers to neither name orchid looks it up by:
no directory beneath a plugin root's `engines/` is called that, and no installed
manifest declares that `id=`. A capability gate that cannot identify an actor
refuses rather than permits — it will not report "no objection" about a manifest
it never read. Install the plugin, or bind the role to the name it *is*
installed under, and the arm goes quiet on its own.

A qualified third-party id (`acme/foo`) does **not** read this way on its own.
Both forms resolve: the directory a binding names, and the `id=` an installed
manifest claims. So a healthy third-party implementer is priced from its own
manifest like any other, and this wording means the plugin is genuinely absent
— not that it is third-party. If it *is* installed and you still see this,
check that its `plugin.conf` declares the id the record carries, and that no
second installed plugin claims the same one (two claimants are refused rather
than chosen between, INV-10 — the boundary says so in those words).

**If the task is `reviewing`, not `testing`, this is a different stop wearing
the same boundary kind** — a *reviewer slot* whose engine cannot be routed the
`review` step, and `orchid task handoff --ack` will not clear it (that verb is
legal only from `testing`). The boundary names the config key that slot's
engine actually resolved from — `role.reviewer`, `review.<tier>`, or neither,
in which case it says the slot fell back to the engine that built the candidate
— **and** `orchid jobs review-plan <id> --repin`. You need both. This attempt's
slot table is *pinned* (kernel.md's "Independence" section), so
binding a capable engine moves live routing while the walk keeps dispatching
the pinned row; `--repin` is what rebinds the slots nobody has reviewed yet,
and it freezes the ones that already have a review so no filed evidence is
orphaned. Bind first, then repin — the repin recomputes from live routing, so
running it before the config change re-pins the same engine.

**And if it is not a boundary at all but a blocker about the ORCHESTRATOR**, the
scheduled pump raised it. `BLOCKERS.md` says no actor can be routed the
`orchestrate` step for role `orchestrator`, names each chain entry's missing
atom, and points at `role.orchestrator`. This is not a task's hand-off and no
`--ack` clears it: it means every engine in that chain is short `shell` or `git`
(`roles/orchestrator.role` requires both, and so does the step), so the pump has
nobody to wake for the judgment boundary the driver recorded on the same pass.
Bind an engine that declares both at `role.orchestrator` — or settle the
recorded boundary yourself, which `orchid run boundary show` names. The blocker
is raised once, not once per pass, and it does *not* replace the boundary
record; both are meant to be read. Once per *incident*, to be exact: answer it
(`orchid answer <qid> <choice>` — the `reply:` line under the entry spells the
whole command out) and the entry you closed stops silencing later passes, so if
the same chain is ever short again — a rebound role, an edited manifest — you
get a NEW blocker rather than the silence an append-only file would otherwise
leave you with. `pump: no capable orchestrator available` is
the *other* message and means the opposite: an engine that could do the work is
merely rate-limited, unproven or not installed yet, and the next pass may well
find it available.

```sh
orchid run boundary show           # what is being held, and why
orchid task show <id>              # candidate_sha, and handoff_ack beside it
# ...do the mechanical work in the task's worktree and commit it, giving each
# such commit the trailer "Orchid-Handoff: operator", then:
orchid task handoff <id> --ack --reason "applied the lint fix; set the exec bit"
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
`orchid task unblock`, `orchid task retry`, `orchid task reverify`'s re-stamp,
and `orchid merge`'s rebase arm all
clear it, because a rebased, reworked or re-stamped tree is a different
candidate and work done on the old one is not evidence about it. If a pass stops again right after
you acknowledged, compare the two fields — `handoff_ack` naming a sha other
than `candidate_sha` is exactly that invalidation, and the boundary reason
prints both.

Set `handoff_before_verify=off` (the default) if your implementer can run the
repository's own gates itself; nothing then gates and this boundary is never
raised. See [configuration.md](./configuration.md) and PROTOCOL.md's
"The operator hand-off".
## A task burns attempts on failures that are not its fault

**Symptom:** `orchid task show <id>` shows `attempts` climbing (and eventually
`blocked — attempts exhausted`) on verify failures the candidate did not
cause — a candidate-local package checksum only the operator can re-pin, an
executable that shipped without its mode bit, a fresh worktree that never
received the `node_modules` the integration checkout has, or an assertion everyone already
knows samples a race.

The driver classifies a failed `orchid verify` before charging it, so those
rounds should be landing on `infra_failures` instead. Check which way a round
went:

```sh
orchid task show <id>              # attempts vs infra_failures
orchid journal show --task <id>    # every non-candidate exit says 'attempt not charged'
```

**Four failures are waivable**, and none of them is one the implementer can
fix by trying again: the two operator hand-offs the protocol itself defines
(a stale package pin, an executable left mode 644), gitignored build state the
worktree never received, and an assertion the repository already recorded as
known-flaky. There is no signature list and no way to declare a failure
forgiven by its wording. Each needs two things to hold, and each one alone is
worth nothing:

1. **The state is proved against the world.** For the mode bit, orchid stats
   the files the candidate *added* (a `#!` file shipped mode 644) and the ones
   it *modified* whose base recorded mode 755 (a rewrite that lost an exec bit
   — an engine whose file writes recreate a file at 0644 does this to every
   executable it touches, and it cannot `chmod` it back). For the pin, orchid
   *runs* your explicitly configured candidate-local freshness check
   (`handoff.pin_check`, default `none`, run under its own `#!` interpreter
   when it is not executable) and requires it to **report a
   file stale** — a nonzero exit is not enough, because a check that cannot
   find the formula or trips over metadata the candidate corrupted exits
   nonzero too and re-pinning fixes neither. Never configure a whole-tree
   release checksum here; those belong to the integration/release gate so task
   branches do not conflict. For the missing build state,
   orchid *compares the two checkouts*: a directory that your own `.gitignore`
   covers, that exists where the run was dispatched from, and that does not
   exist in the worktree the verification ran in. For the flaky register,
   orchid reads a file **your candidate did not change** — touching it removes
   the route, which is what stops an implementer quarantining the assertion it
   is failing. No sentence in the *failure* can substitute for any of those
   proofs, which is why an ordinary defect that merely says `Permission
   denied` is charged.

   For the mode-bit, missing-build-state, and stale-pin routes, “proved” means
   captured in the `orchid verify` evidence header **before** the candidate's
   command starts. Missing-build-state evidence includes the package/command
   subjects the integration tree published then, not a later read of that
   tree. The header is accepted only while its SHA, candidate, and cwd bind it
   to the current task. Orchid deliberately does not rebuild those values from
   either checkout after a failure: a test command can strip a bit, delete
   dependencies, add a fake `.bin` subject under integration, or dirty release
   inputs until the pin turns stale to manufacture its own waiver. Old or
   malformed evidence therefore charges.
2. **This failure is attributed to that artifact**, in two steps, because one
   fault does not fail one check — it strands a whole suite. First, some
   failing line must *name the file and report its fault*
   (`.../orchid-frob: Permission denied`, `libexec/orchid-frob is not
   executable`, `package/component.pin ... is STALE`); that is the proof the state
   blocked this run. After it, every failing line that *names* the file is
   part of the same cascade and is attributed too, causal wording or not —
   `runners/orchid-drive must exist and be executable` and `T001 ... (last
   rc=126 ...)` are that mode bit's failures as surely as the refusal is.
   The legacy Orchid-format pin report has three exact continuations after its
   causal stale line — pinned checksum, expected checksum, and remedy — which
   are attributed too when an opt-in checker emits that format. An unfamiliar
   continuation remains unclaimed and charges. The route defaults to `none`;
   this compatibility grammar does not make Orchid's whole-tree Formula pin a
   candidate hand-off.
   Without that first line, naming alone attributes nothing: every assertion
   that fails inside a newly added file names it. The path must use its exact
   repository-relative, `./`-relative, or worktree-root absolute spelling,
   with a **boundary** after it. An outstanding `bin/tool` therefore never
   collects a real `bin/tool-helper: Permission denied`, nor a distinct
   `fixtures/bin/tool: Permission denied` by suffix.

   For a missing dependency tree the causal proof is the same shape asked of a
   different fact: a line saying something **could not be resolved**, where
   that something **lives inside the absent directory**. `error Command
   "jest" not found` attributes to `mobile/node_modules` because
   `mobile/node_modules/.bin/jest` was recorded there before verification in
   the checkout that still has it
   — and attributes to nothing when the absent directory is an unrelated
   `.cache`. That coincidence is exactly how an earlier version of this rule
   waived failures it had no part in, and it is why the rule now asks the
   filesystem instead of the sentence. It asks about the diagnostic's subject,
   not every token: `ENOENT: ... open 'src/config.json'` checks
   `src/config.json`; a dependency package coincidentally named `open` is not
   evidence about that missing source path. For Yarn v1, the version/help lines
   are exact neutral context; `$ <command> ...` and `error Command failed with
   exit code 127.` are claimed only when trusted inventory says that command
   came from the absent tree and a causal resolution line is present. An
   unfamiliar echo or exit record therefore still charges.

   Its cascade is the same rule as the mode bit's, too: a further failing line
   is claimed when it **names the directory**, or names a path **inside** it —
   `ENOENT: ... open '.../node_modules/x'` cannot be about anything but the
   tree that is not there. That last part is the environment arm's alone,
   because its artifact is a *directory* that is entirely absent; where the
   artifact is a file, `bin/tool/child` is a different file and `bin/tool` does
   not collect it. Merely mentioning something that
   lives inside it is not enough either — `node_modules/lodash` exists, so
   `FAIL: lodash helper returned 3, expected 4` would otherwise be laundered as
   a dependency-tree cascade because the thing under test shares a name with a
   package. A dependency tree's direct children are ordinary words.

   All three routes that read an authority out of your repository — the pin
   check, the flaky register, and the added/dropped file lists — ask git what
   this candidate changed, and **all of them charge when git cannot be asked**.
   A task record with no `base_sha`, or one naming a commit the tree no longer
   carries, produces an empty diff that reads exactly like "the candidate
   changed nothing"; treating that as permission would have let a candidate
   quarantine the assertion it was failing after all.

   And for the two that read a *file* — the pin check and the register — being
   untouched across `base_sha..candidate_sha` is not the whole question, because
   what runs and what is read is the copy in the worktree the verification ran
   in. Each is an authority only while it is **tracked in `candidate_sha`** and
   the worktree copy is **byte- and mode-identical to what that commit
   records**. An edit left unstaged, an edit staged and never committed, a file
   dropped in untracked, one deleted, one chmod'd: none of them appears in that
   diff, and every one of them closes the route and charges. If you keep a
   register or a pinning script, commit changes to it — a working-tree edit
   silently costs you the route for that round.

   The flaky register has one carried-branch exception. When both the task's
   base and candidate resolve and both predate the register path, the driver
   may read the integration checkout's tracked copy while its index, bytes, and
   mode are clean at integration `HEAD`. This is deliberately unavailable to a
   candidate that added the path (candidate has it) or deleted it (base had it),
   and any dirty or unanswerable state charges. It exists so a historical flake
   learned after old worktrees were cut can protect those worktrees too.

Where the state is outstanding and the failure is not attributable to it, the
attempt is **charged**, and the reason says what is outstanding and that
attribution was not established — so you can clear it and still see that it
was not what failed. It **reports** that state rather than prescribing an
action for it, with one exception: a *dropped* exec bit still reads `chmod +x
<path> is the operator's outstanding step`, because the base tree recorded mode
755 and restoring it is owed whether or not this round's failures noticed. A
file the candidate *added* at mode 644 is only named — nothing on disk tells a
new verb awaiting `chmod +x` from a library that is 644 because it is
*sourced*, attribution is what would have told them apart, and a charged round
has none.

**A round is never waived as a round.** It is waived only when *every* failing
line in it is individually claimed. That cuts both ways, and it works across
classes: a stale pin explaining part of the output and an absent dependency
tree explaining the rest together waive the round; one more line neither of
them owns charges it, and the reason quotes that line. The class the journal
*names* is the one somebody must act on first — `handoff`, then
`environment`, then `flaky` — and every contributing class is
named in the reason. Resolution refusals remain failing lines without a
`FAIL:` prefix — `missing-helper: command not found` beside an attributed
handoff therefore prevents a waiver. So do unmistakable fatal diagnostics
such as `panic:`, `RuntimeError:`, and `Segmentation fault`; word boundaries
exclude progress identifiers such as `test_panic_recovery.sh`. The named
diagnostics are conveniences, not a finite allowlist: any unfamiliar non-empty
line that is not an explicit progress, success, or neutral NOT-TESTED record
remains uncertain and charges. Orchid's terminal standalone `OK` and both
NOT-TESTED output forms are explicit members of that closed non-failure
vocabulary. The shipped whole-suite/CI parent captures each test's output and
waits for its exit status: zero exposes durable qualification records plus a
terminal `<path>: OK`, while nonzero exposes the child's output verbatim. No
candidate-controlled BEGIN/END marker is trusted, so a test cannot forge a
completed-success block around a real defect. Anchored NOT-TESTED/RED/GREEN
records remain neutral when their labels name the `failure` or `failed`
fixture they demonstrated; an arbitrary line ending in OK does not override a
failure match. An unknown line cannot be
claimed by a same-artifact cascade just
because it names that artifact. A separate
outstanding state does not earn attribution, but the waived reason retains it
when it names an operator action still owed, such as a dropped 755 bit. Perform
the proved hand-off (refresh the explicitly configured candidate-local
artifact or restore its mode with `chmod +x`), provision the worktree, or fix
the test, then re-dispatch; the same failure charges afterwards, because the
state it was proved against is gone. If a waived fault comes back a second
time — of any class — the pass
stops at an operator boundary rather than re-dispatching again, because none
of these gets better by being retried.

**Anything else charges**, including a flaky failure your repository never
wrote down, a resolution failure whose subject is not inside the missing
directory, and a run whose recorded exit status says it **stopped short**
(124, 137, 143). That last one was a fifth verdict once, on the reading that
the harness had reaped a pass which therefore never spoke about the candidate
— but the same trailer is what a candidate that *hangs* until a timeout reaps
it leaves, and what a suite that exits with the status deliberately leaves.
Nothing in the log tells them apart, so the attempt is charged and the reason
reports that the run stopped short, rather than leaving you to wonder why the
log ends where it does. Orchid forgives only what it can prove. Fix the test, or provision
the worktree, then `orchid task retry <id> --reason "..."`, which returns a
blocked task to `rework` without consuming an attempt. A test you have decided
is genuinely non-deterministic is a lesson-birth moment for `orchid lessons
add` — and, first, a reason to make the test **wait for what it is sampling**
rather than read one instant. If you cannot make it deterministic today, put
it in `flaky.quarantine` with the reason: an unreliable gate should announce
that it is unreliable, not fail silently and not charge for a race.
If an old suite runner exposes deterministic successful-fixture output only
because that later assertion failed, list each whole normalized line as
`FLAKE-CONTEXT:` in the same register. Context never opens a waiver: the
trusted `FLAKE:` signature must also match, and one unlisted line still charges.
Forgiveness is bounded either way: repeated waived failures still block the
task once `infra_failures` reaches `infra_max`.

## `attempts exhausted` — the task blocked and you have a diagnosis

**Symptom:** a task blocks with `attempts exhausted (3/3)`. Before v1.1 the
retry that followed restored the task's *status* without giving it a *round*,
so the very next verify failure blocked it again with no progress in between.

A retry now buys the round as well:

```sh
orchid task retry <id> --reason "the assertion wants 'ok', not 'OK'"
```

On a task with rounds left that changes nothing but status and guidance. On
one with none left it grants exactly one — and says so
(`attempt budget 3 -> 4`). Repeating it does not compound: the second retry
wants the same number the first already granted.

When one more round plainly is not enough, ask for the rest up front:

```sh
orchid task retry <id> --reason "the first two failures were the environment" --attempts 2
```

`--attempts N` is refused, not swallowed, when the task already has that many
rounds left — a grant only ever raises the cap, so on a task inside its budget
the flag would change nothing, and a flag that quietly does nothing gets
trusted and then blamed for a round it never bought. The refusal shows the
arithmetic and the smallest number that would work:

```
orchid: --attempts 1 would grant task T013 nothing: its budget is already 4
with 3 spent, so it has 1 round(s) left and a grant only ever raises the cap
(never lowers it). Retry on the rounds it already has with 'orchid task retry
T013 --reason "..."', or ask for one beyond them with '--attempts 2' or more.
```

Either form records `attempt_budget: <attempts + N>` in the task's
frontmatter (journaled, and refused through `orchid task set` — it is
kernel-owned), and the driver enforces that number instead of the repo-wide
`rework_max` (config, default 3 — raise it there if this is the whole repo's
problem, not one task's). `attempts` itself is never wound back: it is the
number every `reviews/<id>-a<n>-*.json` artifact is keyed on, so moving it
would point the next attempt at a previous one's envelopes.

If the candidate is fine and only the verification needs re-running, do not
spend a round at all:

```sh
orchid task reverify <id> --reason "the suite failure was the sandbox, not the candidate"
```

`reverify` moves the task `blocked|rework → testing`, re-stamps
`candidate_sha` from the task worktree's HEAD (so a fix you committed there
by hand is what gets tested), drops the stale verify log, and consumes no
attempt. A task whose archetype has no `testing` state at all — a
report-outcome one — refuses it as an illegal transition, exit 3.

**Commit your fix first.** `reverify` refuses a task worktree with
uncommitted changes (exit 3), listing exactly what is in the way:

```
orchid: the task worktree /path/to/wt has uncommitted changes — reverify refused
 M tests/test_thing.sh
orchid: verification runs in that worktree, so those would be exercised while
candidate_sha named 9c1f… — commit them on the task branch (or discard them),
then reverify
```

That is not pedantry about tidiness. Verification runs *in* the worktree but
the evidence it writes is bound to a **sha**, so an uncommitted edit is
exercised by the run while `candidate_sha` names a tree that never contained
it — a PASS certifying something nobody can check out again. Untracked files
count for the same reason: a suite reads a brand-new test file as happily as
an edited one. `.orchid/` is excluded, because orchid writes its own state
into the working tree by design and INV-04 keeps it out of candidates anyway.

**And a clean tree is not the right tree.** Being tidy says nothing about
*whose* work is standing in the worktree, so the commit's lineage is a gate as
much as the tree's state is: the HEAD `reverify` is about to stamp must
**descend from the candidate it replaces** (an operator's fix only ever adds
commits on top of the work under judgment) and be **contained in the branch the
task record names** (descent alone still admits a commit made on a branch that
merely forked from it — what working two tasks in two checkouts produces by
accident, and the shape whose commits silently vanish from the branch that
merges). Both refusals name both shas, because which two commits were about to
be conflated is the whole content of the mistake:

```
orchid: refusing to verify 4ab7… as task T013's candidate: 4ab7… does not
descend from the current candidate 9c1f…, so it is not this candidate's own
line of work (HEAD of /path/to/wt is on an unrelated history — check out the
branch task T013 names, commit on top of 9c1f…, and re-run)
```

Adopting whatever a clean HEAD happened to be is the *worse* mis-binding of the
two: afterwards every field agrees and the evidence produced for it looks
exactly right. `orchid task handoff --ack` moves a candidate onto an operator's
tree for the same reasons and is held to the same rule, by the same code.

If the record simply names the wrong branch (the work really is on another
one), point it at the truth with `orchid task set <id> branch <name>` and
re-run.

Every condition `reverify` can refuse on — the archetype's edge, a dirty
worktree, a commit that is not this task's, the entry-to-`testing` gate
(exit 3, the same code on both routes), the dispatch predicates (concurrency
cap, exclusive/resources, unmet deps) — is checked **before** it writes
anything. A refused `reverify` leaves the task exactly as it found it: same
status, same `candidate_sha`, nothing added to the journal.

**If an operator hand-off was acknowledged, `reverify` withdraws it.**
`handoff_ack` asserts one thing about one commit: that *you* looked at that tree
and confirmed the mechanical steps it needed — a mode bit, a linter fix, or a
regenerated candidate-local file — were done. A whole-tree release checksum
is never such a hand-off; it is pinned on integration at release time. The
commit `reverify` re-stamps to is by construction one
you committed *since*, and nobody has said that about it. Carrying the
acknowledgement forward would make that claim on your behalf about a tree you
never reviewed, and would then buy a verification guaranteed to fail on the
missing step and charge a rework round for it. Lineage does not change this: the
gate above proves the acknowledged work is still *present*, and says nothing
about whether the commits stacked on top need mechanical steps of their own.

So the hand-off reads `outstanding` again and the next pass stops at the
boundary. That costs one command and strands nothing: `reverify` leaves the task
in `testing`, which is exactly the status `orchid task handoff <id> --ack
--reason "..."` is legal from. Run it once the re-stamped candidate's own
mechanical steps are done, and the pass proceeds.

`blocked|rework → testing` is a declared transition, so `orchid task advance
<id> testing --reason "..."` walks the same edge by hand. It is not a way
round any of the above: the clean-worktree check, the lineage check and the
reason requirement live on the **edge**, not in the verb, so that route
enforces them too, and
it additionally requires `candidate_sha` to already be the worktree's HEAD —
the one thing it will not do for you is re-stamp it:

```
orchid: candidate_sha is not the HEAD of the task worktree — blocked -> testing refused
orchid: candidate_sha 9c1f…, worktree HEAD 4ab7… — verification would run against
the second and stamp its evidence with the first
orchid: use `orchid task reverify <id> --reason "..."`, which re-stamps the
candidate from the worktree and journals why
```

Use `reverify`. The raw edge exists because the transition table is data, not
because it is a second, laxer procedure.

**"rework not converging" is a different block, and needs a different
answer.** It means `rework_nonconvergence_max` (config, default 3)
consecutive attempts produced a BYTE-IDENTICAL failure — the same command,
the same output, the same exit code — so the loop is re-asking a question it
has already been answered. Retrying it unchanged will produce one more
identical failure. Read the captured evidence, which the kernel keeps one
file per round precisely for this:

```sh
ls .orchid/reviews/<id>-r*-rework.log   # one per captured round, oldest first
orchid task show <id>                   # rework_signature, rework_signature_repeats
```

Rounds a later verification PASSED are renamed `<id>-r<n>-rework.retired.log`
and stop being fed forward — the candidate went green after they were captured,
so "you already tried this and got exactly this" is no longer true about them.
They are kept, not deleted: that copy is the only surviving record of what the
task was red on before it went green, since the rework edge that captured it
deleted the verifier's own log. List them the same way when you want the whole
history rather than what the next attempt is being told.

**First check whose wall it is.** If the boundary goes on to say the repeated
failure is the repository's own `merge_gate`, the candidate is not what is
red: a gate is a check the repository applies to everything, the task was
never asked about it, and it will repeat identically until somebody clears it.
No implementer round can, so `retry` and `unblock` both buy rounds that end
the same way — fix the repository (or this candidate, if the gate names it),
then `orchid task reverify <id> --reason "..."`, which costs no attempt. For
the same reason the run does not reroute the role to another engine on that
kind of streak: there is nothing for a second engine to converge on.

**A pass that says it cannot name the engine to exclude has not misrouted
anything.** The reroute excludes the task's recorded `implementer_engine_id`
and nothing else, so it is withheld — and says so on the pass output — when
that record names an actor no single installed plugin answers to, or when it is
empty because the round's implement envelope was absent, refused as a no-op
delivery, degraded, or present but reporting no engine (that last one clears
the field on the way into `testing`, so a mixed chain leaves an empty record
rather than the previous round's engine). The dispatch still happens on the
chain as written, and
the engine that runs still gets the previous round's output in its brief; what
is withheld is the preference and the journal line, because the alternative is
a durable record naming an engine nothing on disk says ran. If you want the
reroute back, the fix is at the adapter: have it report `.engine` in its
envelope (`orchid jobs ls` shows what each round actually ran on while its job
record is still around).

Otherwise nothing in the candidate is moving that failure, so the useful
question is usually about the assertion rather than the code under test: what
is actually being asserted, and what is the failing value actually? Fold the answer into
`orchid task unblock <id> --reason "..."` (it is recorded into the task body,
and the next attempt's brief carries the failing output alongside it) rather
than `orchid task retry`, which buys the loop more rounds without changing
anything about the question it is being asked.

**Neither verb restarts the loop on its own, and both say so.** `unblock` and
`retry` take the task back to `rework` but deliberately leave the streak
standing — an identical signature reached over your route is the same evidence
of a loop that is not converging as one reached over the driver's — so the next
pass withholds the dispatch and stops the task again rather than spending a
round. Nothing is lost by that: your reason is already in the task body and the
next round that runs will carry it. What has to happen first is that
verification ANSWERS DIFFERENTLY. Change whatever produces the failure (the
assertion, the fixture, the repository), then:

```sh
orchid task reverify <id> --reason "..."   # re-runs the verifier, costs no attempt
```

A changed failure restarts the count at one and the following pass dispatches
normally; a passing one ends the streak outright and the task moves on. If the
loop really should get more rounds of the same question, the knob for that is
`rework_nonconvergence_max` in the repository config, not a second `retry`.

If the pass stops again with `awaiting-operator-prerequisite` instead, that is
the OTHER operator-owned stop at this point — a step outside the repository,
not inside the candidate — and the next section is the one you want. Do the
hand-off first when both are outstanding: the `--ack` above advances
`candidate_sha`, and a prerequisite acknowledged before it is superseded by
that move.

## A task's suite fails on the environment, not on the candidate

**Symptom:** a task authored a schema migration and tests that exercise the
altered table, and the suite dies with something like `Call to a member
function execute() on bool` — `prepare()` returned false, because the columns
do not exist yet. Apply the migration by hand and the same candidate passes.
Left alone, the run treats this as a bad implementation: the failing log goes
to a reviewer, the task goes to `rework`, and three rounds later it is
`blocked` for a defect that was never in it.

Nothing in the tick applies a migration a task itself just wrote, and that is
deliberate — the sandbox that authors a migration is not where write access to
a shared database belongs. Say so in the task instead, when you plan it:

```sh
orchid task set <id> operator_prerequisite "apply db/migrate/0007_*.sql to the test database"
```

Set it at planning time, not later: the implementer cannot set it at all,
because its commits may not touch `.orchid/`. From then on the run stops
before verifying — a `task-prerequisite` judgment boundary, an `orchid notify`
blocker naming the step, and `orchid status --explain` reporting
`awaiting-operator-prerequisite` rather than `awaiting-verify`. No suite runs,
no evidence is written, no attempt is spent.

Do the step, then record it:

```sh
orchid run boundary show            # which task, and the step it is waiting on
orchid task prereq-ack <id> --reason "applied 0007 to orchid_test"
orchid drive                        # the next pass verifies normally
```

The acknowledgement is bound to the candidate it was given for, and stops
counting the moment that candidate is superseded. Any route into `rework`
clears it, so the next attempt — which may author a different migration —
asks again; the declaration itself survives. A merge that finds the base
stale rebases the candidate and sends the task back to `testing` without
passing through `rework` at all, and the ack expires there too: it still
names the pre-rebase candidate, so the boundary re-raises and says so
("acknowledged for candidate <old>, superseded by <new>"). If you reword the
prerequisite, that clears it too, with a journal entry recording what was
cleared. `prerequisite_ack` cannot be hand-set: `orchid task set` refuses it
and points at `orchid task prereq-ack`.

The same wall stands at `merging`, for the same reason: `orchid merge` re-runs
the whole suite against the same database before it advances the integration
branch. Unacknowledged there, it refuses with the same exit 16 and the same
`task-prerequisite` boundary, leaves the task in `merging` — nothing merged,
no evidence written, the integration ref untouched — and the fix is the same
two commands:

```sh
orchid task prereq-ack <id> --reason "applied 0007 to orchid_test"
orchid merge <id>                   # or just let the next pass run it
```

That is why `prereq-ack` accepts `merging` as well as `testing`. Were merge
ungated, the one unapplied migration would be waved through at verify and
charged here, where the failing suite sends the task to `rework` for a full
round — implementer dispatch, re-verify, re-review — against a candidate that
was already independently verified and has nothing wrong with it.

If the suite can migrate its own store instead — a fixture database, a temp
file, an in-memory DB the tests build — do that and leave
`operator_prerequisite` empty. It is the better answer wherever it is
available; this is for where it is not.

## `plan apply` refuses: carried-forward items are unconsidered

**Symptom:** `orchid plan apply` exits 3 without committing anything, listing
items like `r-001#57` or `L016` as neither covered by a task nor deferred.
`orchid run advance` out of `planning` exits 3 with the same list — the run
leaving `planning` is gated as well as the verb, so taking that edge first
does not open the door for the `plan apply` behind it.

This is the planning cross-check. The previous run left findings behind —
ledger entries in `.orchid/runs/<prev>/journal.md` and the active lessons
`orchid run new` carried across — and no task in the new plan appears to
consider the ones it names. It exists because a run once omitted a defect the
previous run had already found and journaled, and paid for it hours in.

```sh
orchid plan crosscheck             # the same report, without committing
```

Two ways forward, per item. Cover it — add or extend a task whose text names
the thing (a snake_case identifier, a source path, an `INV-nn`, the lesson
id); matching is on those anchor terms only, and only in the task's body and
its intent-bearing frontmatter (`title`, `acceptance_criteria`,
`stop_condition`, `hook_guidance`, `resources`). A bare frontmatter key does
not count, and neither does `verification_commands` — every task's chain
names the same suite scripts, so a path in there would mark items covered
across the whole plan at once. The task has to actually say it. Where an
item does come back `covered`, the line names the anchor that earned it
(`… (task T010 via started_at)`); if that term reads as incidental, treat
the item as uncovered and cover or defer it properly. Or decide against it:

```sh
orchid plan defer r-001#57 --reason "owned by the follow-up PR, not this run"
```

Items are FINDINGS, not journal entries. One arbitration entry often records
several defects at once, so an entry written as `(1) … (2) … (3) …` is split
into `r-001#57.1`, `r-001#57.2`, `r-001#57.3` — cover or defer each on its
own; the undivided `r-001#57` is refused, since deferring it would absolve
all three in one command.

An item that reports as

```
UNCOVERED [ledger] r-001#57 — CARRIED AS LEDGER ITEMS, not fixed here: …
          ^ this entry records SEVERAL findings and cannot be split …
```

announces several findings that cannot be separated unambiguously — prose
with no enumeration, an enumeration shorter than the count the entry claims,
or one whose markers are scrambled (`1, 3, 2`), gapped (`1, 2, 4`) or
repeated. No task text closes that one, by design: a wrong guess at where one
finding ends would silently absolve the others. Read the entry, schedule what
it needs, then defer it naming what you scheduled.

A deferral journals the decision and satisfies the check for that item alone
— there is no bulk override. Use the verb: what the check reads is the
`plan_deferral` entry KIND, so a hand-written journal note whose text reads
`deferred r-001#57: …` records nothing and the item stays uncovered. A
deferral postpones rather than erases: the item reappears in the NEXT run's
cross-check, still wanting a task or a fresh reason. Read the full item with
`grep -n '^## ' .orchid/runs/<prev>/journal.md` and the entry at that
ordinal.

**The refusal does not lapse when the run leaves `planning`.** `plan apply`
revises a committed plan too, and a revision that deletes the one task naming
an item is exactly how an item becomes uncovered mid-run — so that revision is
refused as well, and the integration branch does not move at all: nothing is
committed, nothing journaled, and the edit stays sitting in your checkout
until you answer for the item. Both remedies are open there, which is why the
refusal can be a gate rather than a trap: `orchid plan defer` has no
`run_status` precondition, so record the decision, or put the coverage back
and re-run. A task is still the better answer once the run is moving — but
that is advice, not the door being closed.

## `plan apply` refuses: the cross-check cannot read the previous run

**Symptom:** `orchid plan apply`, `orchid plan crosscheck` or `orchid run
advance` out of `planning` exits **4** — not 3 — listing no items at all, and
saying the carry-forward question cannot be answered.

Exit 3 means *there are items and nobody considered them*. Exit 4 means *the
previous run's record could not be read*, which is a different problem with a
different repair: there is nothing to cover and nothing to defer, because
nothing could be listed. The check is derived from the roadmap's own
`run_id` — this is run `r-NNN`, so it carries from `r-(NNN-1)` — and one of
four things is wrong with the state under `.orchid/`:

- no archive for that run under `.orchid/runs/` (or no `runs/` at all);
- the archive is there but its `journal.md`, which IS the ledger this check
  reads, is missing or unreadable;
- `run_id` in `.orchid/roadmap.md` is not the `r-NNN` shape, so the previous
  run cannot be named;
- an archive at or above the current `run_id` exists — a rollover archives
  the OLD id and then increments, so the roadmap and the archive disagree
  about how many runs there have been.

It refuses rather than reporting because every one of those states produces
an EMPTY item list, and an empty list is exactly what a previous run that
genuinely left nothing produces. Reported, it printed `previous run r-001
recorded no ledger items … (stated, not skipped)` and committed the plan over
every finding in a record it never opened.

All of `.orchid/` is durable state on the integration branch, so the repair
is a restore:

```sh
git log --oneline -- .orchid/runs
git checkout <sha> -- .orchid/runs/r-001
```

Then re-run `orchid plan crosscheck`, which will report the items in that
record — usually as `UNCOVERED`, since nothing in the plan has answered for
them yet.

## `plan apply` refuses: the cross-check could not run at all

**Symptom:** `orchid plan apply`, `orchid plan crosscheck` or `orchid run
advance` out of `planning` exits **5**, saying no scratch directory could be
created under whatever `TMPDIR` names, and listing no items.

Nothing is wrong with `.orchid/` here. The archive is intact, the journal is
readable, every carried item is still in it — the check simply has nowhere to
write the list it would report, because it builds that list in a temporary
directory. So the repair is neither a task, nor a deferral, nor a restore:

```sh
echo "$TMPDIR"                     # unset means /tmp
mkdir -p "$TMPDIR" && df -h "${TMPDIR:-/tmp}"
```

An unusable `TMPDIR` is ordinary — a shell profile or a sandbox that exports
a directory it never creates, a full disk, a read-only `/tmp`, a directory
belonging to another user. Point it at a writable directory (or free space in
the one it names) and re-run.

It refuses rather than reporting for the same reason exit 4 does, and this is
the sharper version of it: with no directory to write into, the item list came
back empty, and an empty list is what a previous run that left nothing
produces. The report printed `all carried-forward item(s) considered` and
`plan apply` committed the plan — over findings that were sitting in a record
it never had anywhere to read into.

## One task needs a decision and the whole run stopped

**Symptom:** `orchid drive` exited 16 (or the pump printed `judgment boundary
[...] is operator-only`), somebody read that as "the run is stuck", and
twenty-nine tasks with no relationship to the boundaried one sat idle until a
human came back and restarted the pump.

Exit 16 says **a decision is outstanding somewhere** — never "no further
progress is possible". The pass that returns it has already walked every task
and taken every edge deterministic policy allows; the boundary is recorded at
the end of it. `orchid drive` is idempotent, so a boundaried task re-reports
the identical record on the next pass at no cost while every other task keeps
advancing. Exit 1, not 16, is the code that means a pass could not be made.

So keep driving. A scheduled pump does this by itself — each invocation runs
the whole roadmap again — which is why the correct response to a boundary is
to leave the schedule alone and read the blocker:

```sh
orchid run boundary show           # which task, which kind, why
cat .orchid/BLOCKERS.md            # the same thing, plus everything else waiting
orchid status --explain            # what did keep moving while it waited
```

If you are driving by hand in a loop, the loop condition must not be the
driver's exit code: `while :; do orchid drive; sleep 60; done` keeps the run
moving, `while orchid drive; do ...` stops at the first decision. A pump that
stops at the first arbitrable disagreement is attended operation wearing an
unattended label.

## `operator-decision`, and every review on the task says `approve`

**Symptom:** the boundary is `operator-decision` on a task in `arbitrating`,
`orchid jobs ls` shows a complete, unanimous, scope-complete review set with no
findings, and nothing in the envelopes disagrees with anything. The reason text
quotes a sentence you wrote yourself, some rounds ago.

That is arm 0 of the arbitration truth table, and the sentence is your own
`orchid task arbitrate --result request-changes --reason "..."`. A rejection is
recorded on the task as `unresolved_objection` and stands until an arbitration
approves — deliberately outliving the round it was raised in, because the round
after it is judged on its own reviews and nothing else in the run would ever ask
whether your objection was met. Dogfood F33 is the run where nothing did: the
same concurrency hole was rejected twice, round 3's reviewers returned
`approve`, and the deterministic path merged it.

```sh
orchid task show <id> | grep unresolved_objection   # the objection, and who raised it
orchid journal show --task <id>                     # every arbitration, in full
git diff <base_sha>..<candidate_sha>                # what this round actually changed
```

That `grep` prints the objection and, beside it, `unresolved_objection_by` —
who raised it, which is what decided that this stop reached you rather than a
woken model. `operator` is the case this section is about.
`unresolved_objection_by: orchestrator` means the run's own orchestrator
recorded the rejection, and that one is filed as `review-conflict` instead: it
still refuses the deterministic approval, but the pump wakes the surface that
raised it, so you would not normally be reading this page for one. A task
carrying an objection but no `_by` line at all was rejected before the field
existed, and is read as yours.

Then settle it, whichever way the diff says:

```sh
orchid task arbitrate <id> --result approve --reason "the raced write is now behind the lock at lib/foo.sh:120"
orchid task arbitrate <id> --result request-changes --reason "still unguarded on the retry path — same two constants"
```

An approval clears the field and journals the clear; anything else leaves it
standing. There is no other door — `unblock`, `retry` and `reverify` do not
clear it, and `orchid task set` refuses the key by name, because none of them
is an answer to "was this defect fixed".

**It is filed as `operator-decision` rather than `review-conflict` so that it
reaches you.** A `review-conflict` on an `arbitrating` task is arbitrable: the
pump wakes the orchestrator instead of paging a human, and `orchid task
arbitrate` is a write the brokered surface admits — so the model would clear
your objection from the same diff that produced it, and you would find out the
way F33's operator did, by reading the merged source. `operator-decision` names
no settling verb, so it is operator-only on every surface. The run stops here
until you decide, which is the point.

That is enforced at the verb as well as in the routing: `orchid task arbitrate`
refuses a non-operator arbitration of either result on a task carrying your
standing objection, so a model woken for some other boundary cannot reach this
one by naming its id. If you see that refusal in a tick's output, the model did
the right thing next — its move there is `orchid notify`, which is how this page
got to you.

If the objection is genuinely obsolete
(the task was re-scoped, the code it named is gone), that is still an
arbitration: approve it and say so in the reason, so the record shows a decision
rather than a field that quietly disappeared.

The reviewers see it too. Every shipped `review` adapter appends the objection
to the next round's prompt, so a reviewer that flips to `approve` with the
defect untouched is doing it having been shown your words — which is worth
knowing before you take its verdict as a second opinion.

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
status`, and hermes does, via `hermes gateway status`): doctor runs it with a
10s deadline and reports REACHABLE, NOT
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
to refresh a stale checkout by hand, it takes **two** commands, in this
order:

```sh
git checkout HEAD -- . ':(exclude).orchid'
git reset
```

**Both, and the reset second.** The checkout refreshes the working tree —
the code this checkout fell behind on, which is the part that matters, since
a stale checkout goes on *executing* pre-merge code. The bare `git reset` is
what clears the warning: `git checkout` never touches an index entry its own
pathspec excluded, so every `.orchid/` path the new `HEAD` carries and the
stale index does not is left staged for deletion — and that staged deletion
is the signature `doctor`/`status` read. Run the checkout alone and the
warning survives it — which is exactly what a dogfood operator hit (finding
F31) after following the old one-command version of this page character for
character.

The reset costs nothing: a mixed `git reset` writes no file and deletes no
file, it only brings the index to `HEAD`, so the live `.orchid/` run state on
disk is untouched. Do it *second* all the same — an operator who runs the
reset and then gets interrupted is left with pre-merge code under a checkout
that now looks healthy to every check there is, which is the L018 failure
with its one alarm switched off. That is the same hazard
[*Unstaging is not free*](#unstaging-is-not-free-it-can-hide-a-genuinely-stale-kernel)
spells out for the kernel refusal below, and the order is what disarms it
here: by the time the reset lands, the checkout has already brought the
working tree to `HEAD` for everything the launcher executes, so the index it
resyncs is no longer the only record of anything. What the reset covers is
`.orchid/` alone, where the live on-disk copy is the authority and no
refresh may run at all.

The checkout is the half that can cost you something. **Not** a bare `git
checkout HEAD -- .` — that clobbers uncommitted `.orchid/` run state (the
r-001 incident). And `':(exclude).orchid'` protects run state and *nothing
else*: every other tracked path is restored from `HEAD`, so an uncommitted
edit of your own outside `.orchid/` is overwritten with no reflog to recover
it from. A `requirements.md` being revised at the repository root is the file
this has actually cost an operator. Commit or stash first — `git status
--short` names what is at risk.

`orchid doctor`/`orchid status` detect and name this condition
automatically (staged-deletion signature against the checkout's own
branch), before you ever act on stale state by accident, and both print the
two-command recovery above.

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
<kernel paths>` is what tells you whether its code is current. That matters
more than it sounds, because `git reset` is also what this page prescribes for
clearing a staged-edit refusal — see *Unstaging is not free* below before you
run it.

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

It is printed only when that merge actually moved one of the kernel paths. A
merge of docs, config or tests over a checkout with kernel edits in it leaves
that checkout exactly as current as it found it, says nothing, and refuses
nothing — so a warning you *do* see is always about a checkout that really
did go stale.

A verb that starts in the fraction of a second between that merge's ref
advance and its refresh gets a different refusal and a different exit status;
see *A repair is in flight* at the end of this section.

### The one test that settles which case you are in

Reading a diff tells you what changed; it does not tell you whether those bytes
exist anywhere but here. This does, and it is read-only:

```sh
for c in $(git -C <root> rev-list -n 50 HEAD); do
  git -C <root> diff --cached --quiet "$c" -- \
    bin lib libexec runners plugins roles skills templates PROTOCOL.md \
    && { echo "index matches $c"; break; }
done
```

**A match is proof of case (1).** Your index is byte-for-byte an earlier commit
on this branch — the one the branch moved off — so every byte a restore
overwrites is already in the object store, and nothing you have is at risk.

**No match means the index carries bytes no commit does**, so at least part of
what is staged is yours and a restore would destroy it. It does *not* mean the
checkout is current: you can be stale *and* have a staged edit at the same
time, and that mixed state is the one the remedies below are most likely to get
wrong. Treat "no match" as *save your bytes first*, not as "nothing is stale".

Run it before either remedy below, while the index still holds the evidence —
`git reset` overwrites it, and *Unstaging is not free* later in this section is
what that costs.

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
section. **Read the warning under *Unstaging is not free* below before you
reach for that reset**: it clears the refusal whether or not the checkout is
also stale, and it is the one remedy on this page that can leave you running
pre-merge code with nothing left to say so.

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
working tree is left exactly as it was. **It also clears the refusal when the
checkout really had fallen behind, and nothing detects that afterwards** —
*Unstaging is not free* below has the whole of it, and the scan to run first.

To run a single command from a checkout you know is stale — to read something
out of it, or to recover — prefix it:

```sh
ORCHID_ALLOW_STALE_ROOT=1 orchid status
```

### `orchid.config` after a merge, when orchid runs from this checkout

The refusal above never fires over `orchid.config`, and the kernel refresh
never restores one you are part-way through editing. But that file is *read*
by every verb — `merge_gate`, `verify`, `concurrency`, the role bindings — so
a merge that lands a change to it would otherwise leave this checkout
resolving pre-merge values indefinitely, with nothing anywhere saying so. A
repository that adopts a `merge_gate` and then never runs it is the sharpest
version of that.

So a merge that changed the committed `orchid.config` does one of two things,
and tells you which:

* **Nothing here to lose** — your copy was byte-identical to `HEAD` in the
  working tree and the index, and no untracked file sat at that path. The
  merged configuration is made live, and the merge prints
  `refreshed <root>/orchid.config to <branch>`. From that moment the branch's
  values are the ones every verb resolves.
* **You had a pending edit** — it is left exactly as you wrote it, nothing is
  overwritten, and the merge warns on stderr that the merged configuration is
  *not* live here, naming what is pending. This is the only moment that fact
  is knowable: no verb downstream compares a working config against its
  branch, so nothing else will ever mention it.

"Pending" is wider than "modified": an `orchid.config` that is *untracked*
here — including one your `.gitignore` covers — is somebody's only copy of it
too, so it is preserved and reported on the same terms. The warning names it
in `git status` shorthand for that reason, since the `diff` below is silent
about a path `HEAD` does not carry.

In the second case, look at both sides before you do anything:

```sh
git -C <root> diff HEAD -- orchid.config          # yours, if it is tracked
git -C <root> status --porcelain --ignored -- orchid.config   # ...and if it is not
git -C <root> show orchid/integration:orchid.config   # the branch's
```

Then keep whatever you want kept, in one file. **Do not run `orchid config
commit` first**: that verb commits the bytes on disk here, so committing an
unreconciled file lands a configuration that drops the change the merge just
made. Merge the branch's change into your copy, *then* commit it.

### Unstaging is not free: it can hide a genuinely stale kernel

That `git reset` is safe for your *bytes* and unsafe for your *detection*, and
the two are easy to conflate because the refusal it clears looks the same in
both cases.

The check compares the **index** to `HEAD` (see *An ordinary dirty working tree
is not this* above for why it must). `git reset` resyncs the index to `HEAD` by
definition — so it clears the refusal **whether or not this checkout had also
fallen behind**. If the branch really was advanced under you and you unstage
instead of restoring, you are left with an index that matches `HEAD` over a
working tree that still holds pre-merge code: orchid runs, reports nothing, and
executes the old kernel indefinitely. That is lesson L018 exactly, reached by
following a remedy. Nothing detects it afterwards — not this check, not
`doctor`, not `status`; the index was the only record of the fall behind, and
the reset overwrote it.

So the order matters:

1. Run *The one test that settles which case you are in* **first**, while the
   index still holds the evidence. A match means you are in case (1) and should
   restore, not unstage.
2. If you unstage anyway — a mixed state, or you simply want the edit live —
   check the working tree immediately afterwards, because it is the only thing
   left to check:

   ```sh
   git -C <root> diff HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
   ```

   Every hunk in that diff should be *yours*. Anything you do not recognise —
   in particular anything that reads like a merge running backwards — is the
   branch having advanced under you, and the fix is *Case (1)* above: save your
   own edit, then restore.

If you have already unstaged and are unsure, the same scan works against the
working tree rather than the index; drop `--cached`:
`git -C <root> diff --quiet "$c" -- <kernel paths>`. A match against an
ancestor of `HEAD` means the tree you are executing is that older commit's.

### Why `doctor` and `status` refuse too

They are the verbs you want most in this state, and they are refused anyway.
`orchid help` and an unknown verb still answer (neither sources anything);
everything else, diagnostics included, stops.

No arm of `orchid trust` is exempt either, and one of them used to be.
`orchid trust unattended` and `orchid trust revoke` refuse because each leaves
a machine-local record behind that outlives the process that made it, and
neither may be made by code nobody has looked at. `orchid trust show` refuses
too, and the reason it stopped being an exception is the reason `doctor` and
`status` never were one: what it produces is the report you decide on — the
gate verdict, the record it resolved, the root verification, the provenance —
and out of a stale checkout that report is produced by the pre-merge code.
Writing nothing durable is not the same as having nothing to protect.

That leaves the unattended-trust contract untouched, which is what the old
exemption was written for — but not for the reason this page used to give.
What the contract forbids is Git spent on *the repository under inspection*
before an acknowledgement for it has been found. This refusal compares orchid's
own installation root against its own `HEAD`, and it spends even that only from
a root parked on the integration branch. It used to say here that the root is
*never* the repository you asked about, and that is not true of orchid, which is
self-hosted. `ORCHID_ROOT` is not where you are standing; it is the installation
the verb resolved from its own path. Run a separately installed `orchid` against
a checkout and the two really are different directories — that is nearly every
invocation, and it is why the claim went unchallenged. But run a checkout's own
`bin/orchid` against that same checkout — orchid developing and driving itself,
`orchid doctor` on its own tree, that tree named to its own `orchid trust show`
or `orchid trust revoke` — and the root *is* the target, so that comparison is a
query against it.

So the order is what keeps the contract, not the choice of directory: each of
those verbs makes its machine-local trust decision **first** and fires the
stale-root gate **second**, both still ahead of anything it prints or removes.
`show` looks the acknowledgement up; `revoke` derives the identity of the record
it would remove, which costs no Git either. As everywhere else on this page, the
way through is `ORCHID_ALLOW_STALE_ROOT=1` in front of the one command, so what
you are about to read is knowably the stale kernel's answer.

`./install.sh` refuses too, and it is the one entry point here that is not a
verb. What it produces is a machine-scoped wiring: your `orchid` becomes a
symlink into the checkout you ran it from, and so do the front-end skill
bundles. Run out of a stale checkout, that installs the pre-merge tree *as* your
orchid, at the one step nobody re-runs afterwards. `--uninstall` is behind the
same refusal, because which symlinks a pre-merge installer decides are its own
is decided by the pre-merge tree. The installer's own closing `orchid doctor`
is not this check and could not be — it runs only when you are standing in some
*other* repository, so it is skipped in exactly the case where the source
checkout is the one at risk. Same way through:
`ORCHID_ALLOW_STALE_ROOT=1 ./install.sh`.

The reason is not consistency for its own sake. **A diagnosis read out of a
stale checkout is produced by the stale code.** `orchid doctor` here runs the
checks the pre-merge tree carries, so it can pass a checkout the merged
`doctor` would fail — and it would be reporting on the very staleness that
makes it untrustworthy. Acting on a confident wrong diagnosis is worse than
being stopped, and trusting output from code nobody has looked at is the whole
of the failure this guard exists for.

**And they refuse in case (2) as well — where your code is not stale at all,
your own `git add` is what put a kernel change in the index, and every verb
including `doctor` and `status` stops over it.** That is the sharpest cost
this design has, and it is not an oversight; you have hit the tool protecting
you rather than a broken tool. Two things make it the right trade anyway.
Orchid genuinely cannot tell which case it is in — an index that differs from
`HEAD` in those paths is byte-for-byte the same whether a merge advanced the
branch or you staged an edit, which is the whole argument above — so the only
policies available are "refuse in both" and "run in both", and the second is
the one that cost a full day of a run executing pre-merge code. And the
refusal is cheap to clear when the cause is yours: unstage it and every verb
works again, contents untouched.

```sh
git -C <root> reset -q HEAD -- bin lib libexec runners plugins roles skills templates PROTOCOL.md
```

Nothing was run and nothing was changed while it refused — including by
`doctor` and `status`, which only ever read.

There is also nothing to gain by exempting them: the refusal already tells you
more than `doctor` would here — the branch, the paths whose index entries
differ, any unstaged modifications as context, and two read-only commands for
looking at them. And an exemption list is exactly how the earlier, advisory
version of this check failed: it was obeyable, so it was ignored.

What you want is one line up:

```sh
ORCHID_ALLOW_STALE_ROOT=1 orchid doctor
```

That is the diagnostics exemption — per-invocation, visible in your
scrollback, and taken *after* you have read what the refusal observed. The
difference from a built-in exemption is that this way the report you are about
to read is knowably produced by the stale kernel, rather than silently so.

### A repair is in flight (exit 75)

There is a fraction of a second between `orchid merge`'s ref advance and its
refresh in which this checkout genuinely holds the pre-merge code. A verb that
starts in that window — an `orchid status`, a heartbeat, a notify hook — gets
a different message and **exit 75**:

```
orchid: refusing to run: an 'orchid merge' started from this same checkout
(...) has just advanced 'orchid/integration' and is restoring this checkout's
kernel files to it right now. ... Retry in a moment
```

**Retry it; there is nothing here for you to fix.** Nothing ran and nothing
was changed. Exit 75 is `EX_TEMPFAIL` and orchid uses it for this and nothing
else, so a scheduler or hook wrapping orchid can retry on 75 and alert on 1
without parsing any text.

It refuses rather than running because that window is *defined* by this
checkout holding pre-merge code — running a verb out of it is precisely the
failure this whole section is about, and one that starts an `orchid tick` runs
a whole pass of it. Nor would waiting help the process that is already there:
by the time it can tell, it has read its own libraries off the pre-merge tree,
so only a fresh invocation picks up the merged ones.

If retrying keeps reporting this, the merge died mid-restore. Once its process
is gone, the next command reports the full state of the checkout instead and
the cases above apply. A half-finished restore cannot leave this checkout
*looking* current: the refresh writes each kernel file first and its index
entry only afterwards, so whatever it did not get to is still an index that
does not match `HEAD`, and you get case (1) rather than silence. Case (1)'s
`git checkout HEAD -- <kernel paths>` finishes what it started.
(The merge publishes its pid, process start time and
hostname at `.orchid/runtime/kernel-refresh`, and all three must match a live
process for this message to be used — a PID alone gets reissued to something
unrelated sooner or later, and would keep telling you to retry a merge that
had died. The file is removed on every exit path a merge can take short of
`SIGKILL`, and a leftover one is inert: it can change the wording of a
refusal, never lift it.)

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

## A task file is empty, or `task show` prints nothing

**Symptom:** `orchid task show <id>` prints nothing and exits 0; a `grep` for
one of the task's fields comes back empty; `orchid task list` shows a row with
no id, status or title; a run behaves as though a task it was working on
stopped existing.

On a current orchid the same damage announces itself instead: `task list`
carries a `DAMAGED` row for that task, `task show` exits non-zero saying which
way the file is broken, `orchid doctor` FAILs naming the path, and a driver
pass stops at an operator-decision boundary rather than skipping the task in
silence.

That task's file has been **destroyed, not emptied**. The cause was a value
containing a newline — typically a multi-paragraph `acceptance_criteria` or
`hook_guidance` pasted as prose:

```sh
orchid task set T002 hook_guidance "first paragraph

second paragraph"
```

Before v1.1 that printed `awk: newline in string` three times, **exited 0**,
and left `.orchid/tasks/T002.md` at zero bytes with every field gone. It then
failed quietly in both directions: later `task set` calls against the empty
file also reported success, and `task show` exited 0 printing nothing.

**Current behaviour.** A newline in a value is refused before anything is
opened — task frontmatter is one `key: value` per line, and a multi-line value
cannot be stored there. Two ways forward, both of them verbs:

- **Flatten it to one line.** A literal `\n` is safe and stores those two
  characters verbatim — it is **not** expanded into a real newline, so it
  cannot split the value across two frontmatter lines.
- **Send the prose to the task body through the verb that writes it there** —
  `orchid task unblock <id> --reason "..."` or `orchid task retry <id>
  --reason "..."`. Both record the reason in the task BODY, which is the file
  the implementer's own capsule carries. **Both are status-gated**: `unblock`
  runs only from `blocked`, `retry` only from `blocked` or `rework`. A task
  being planned is `pending`, where neither does — take it to one of them with
  `orchid task advance <id> blocked --reason "..."` (legal from every status)
  if the prose is guidance rather than a field's value. The refusal you got
  names whichever of these applies to that task right now, so read it rather
  than guessing from here.

Do not reach for the file itself. Editing anything under `.orchid/` by hand is
forbidden outright (PROTOCOL.md's Preamble), and this is the moment it is most
tempting — a verb has just declined to store what you typed.

Frontmatter writes now land through a temp file that is renamed only once the
rewrite has succeeded and produced a non-empty document, so a failed write
cannot truncate a task. `orchid task show` exits non-zero on an empty or
unparseable task file, and `orchid doctor` FAILs on one, naming the path.

**The quieter half of the same damage** is a task file that is not empty at
all: a value split across two lines leaves the key truncated at the break and
the remainder sitting in the frontmatter as a line belonging to no key. Every
line-oriented reader treats such a file as healthy — both delimiters are there
and `id` still resolves — so only the split field is wrong, and silently. That
is now refused too: `task show`, `orchid doctor` and every frontmatter write
report `malformed frontmatter: line N is not a 'key: value' entry`, naming the
line.

**And the same slip in the KEY.** `orchid task set T002 'hook guidance' "..."`
— a space where an underscore was meant — used to write `hook guidance: ...`,
exit 0, and leave that task unreadable to every verb from then on. It is
refused now, naming the argument. A key may hold letters, digits, `_` and `-`
and must start with a letter or `_`; it does **not** have to be a field the
kernel knows, since archetypes and plugins add their own. A `task set` against
a file that is already damaged is refused separately, and says so — rewriting
it would only bury the damage under a fresh value, so restore the file first
(below) and set the value afterwards.

**Recovering a file already destroyed** — the frontmatter is recoverable
wherever it was last committed, and often from a review pack. This is the one
place git is the answer rather than a verb: restoring a committed version of a
file is not a hand-edit, and no verb rebuilds a task's history from nothing.
Restore first, then go back to verbs.

```sh
git log --all --oneline -- .orchid/tasks/T002.md
git checkout <sha> -- .orchid/tasks/T002.md
ls .orchid/runtime/packs/            # a pack of that task carries its frontmatter
```

Restore the frontmatter rather than re-creating the task: a fresh `task create`
resets `attempts`, `base_sha`/`candidate_sha` and `status`, which throws away
the run's record of everything that task has already done.

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

**Check which budget is actually live before raising anything.** `orchid
doctor` prints it — `note: pack budget: pack_budget_bytes=<n> (from: env|repo|
user|default)` — and so does `orchid config list`. The value resolves against
the **target repository**, so a `pack_budget_bytes=` line in the orchid
installation's own `orchid.config` does nothing for the repo being driven; the
per-machine layer that does is `~/.orchid/config`. A run that failed every
launch on a 65536-byte budget while its operator believed 131072 was set had
set it in the wrong file.

## Every launch fails and nothing is ever reported

**Symptom:** tasks sit in `pending` (or an active status) pass after pass;
`orchid jobs check` lists manifests as `never-started`; `.orchid/runtime/jobs`
has manifests with `pid 0`, `started_at 0` and no log file beside them in
`runtime/logs`.

The launcher does real work before it spawns: `orchid jobs prepare`, then the
input pack. A failure in between (`input_overflow` above is the common one, a
missing binary the next) means no engine ever started — so there is no job to
call dead and no envelope to mark the engine with.

What the kernel does about it, and what to look for:

- The driver treats a non-zero launcher exit as a job failure: journaled, and
  one rung of the escalation ladder (`orchid task infra-fail`), which blocks
  the task at `infra_max`. So `orchid journal tail` names the exit code, and
  a task that cannot be launched ends up `blocked`, not retried forever.
- That rung is spent ONCE, and never zero times. Two arms can charge the same
  stranded launch — the driver's synchronous one and its ageing sweep, passes
  later — and they deduplicate on the `job_id` of the manifest that launch left
  behind. The receipt is the journal entry the charge itself wrote: every
  launch-failure rung's reason ends `[ladder job <job_id>]`, and a charge whose receipt
  is already on record is refused. So a pass killed between the launcher's exit
  and the charge loses nothing (no receipt → the sweep counts it, and the
  manifest is not reaped until after the ladder has run), and a pass that
  charged is never charged again. If you are auditing a blocked task's
  `infra_failures`, every rung should have a journal entry naming a launch that
  really was attempted, and no two rungs should name the same `[ladder job ...]`.
  `launch_exit` on the manifest is diagnostic only — it records *why* the
  manifest was stranded, and the sweep quotes that exit code when it is the arm
  that ends up charging.
- `orchid jobs prepare` refuses (exit 18) to mint a second manifest for a slot
  that already has an unlaunched one, so a broken launch leaves ONE orphan,
  not one per pass. That refusal is a wait, not a failure.
- An unattended `orchid jobs gc` reaps a never-started manifest once it is
  older than the bound the driver passes it (`stall_minutes`); after that, the
  identical dispatch is tried again. This reap runs in every phase, `PLANNING`
  included, so exit 18 always clears on its own. To clear one immediately,
  having looked at it yourself: `orchid jobs gc --older-than-s 0` (zero means
  zero — no floor is applied to what you type), or `orchid jobs gc
  --reap-prepared --older-than-s 0` when nothing else may be touched, e.g.
  mid-`PLANNING`, where no reconcile has run and the dead-job reap must not.
- **In `PLANNING` the journal is the only place this shows up, and it does.**
  Nothing wraps the launchers there — you run `runners/orchid-launch plan
  plan_critic critique` yourself — so no caller reports the exit code at the
  time. A planning pass sweeps the unlaunched manifests it is about to retire,
  journals each with the same `[ladder job ...]` receipt, spends a rung where
  there is a task to spend it against, and only then reaps. The reserved `plan`
  id has no task file and so no counter: read its failures with `orchid journal
  show --task plan`. The pass never relaunches in that phase — clearing the
  slot is all it does, and what to run next is yours to decide.

Fix the underlying launch failure first — the pass output and
`.orchid/runtime/pump.log` carry the launcher's own stderr — then
`orchid task retry <id> --reason "..."` if the ladder already blocked it.

**`prepared` and `unstamped` are a different symptom: pid 0 WITH a log.** That
manifest was spawned — the launcher creates the log by redirecting the engine
into it and stamps the pid only on the next line — and was then killed inside
that window, so an engine may still be running with its pid recorded nowhere.
The log's mtime is what the kernel reads, and it separates the two reports:

- **`prepared`** — the log was written to within `stall_minutes`. Something is
  producing output, so the driver WAITS on this manifest: it counts as a live
  job, no second engine is launched over it, and no `gc` mode reaps it. Let it
  finish and reconcile. If you want to watch it, `tail -f` the manifest's
  `.log`.
- **`unstamped`** — nothing has written to that log for `stall_minutes`, the
  same silence `orchid jobs check` kills a *stamped* job over. The kernel
  handles this one itself: one rung of the escalation ladder, then `gc`
  retires the manifest (quarantined `.reason-gc-unstamped`) and the slot is
  relaunched. **The log is deliberately kept**, unlike a dead job's — no pid
  was ever recorded, so nothing here was ever killable, and that log is the
  only surviving record of whatever was spawned.

There is one thing the kernel cannot do for `unstamped` and you may still want
to: kill the process, if it turns out to be alive but silent. `pgrep -f
<job_id>` finds it; nothing else on this machine knows its pid.

## Verification fails only in orchid's own checkouts

**Symptom:** the suite passes when you run it by hand, but every task fails
`orchid verify`, or passes verify and then fails validation inside `orchid
merge` — with an error about a missing module, binary, generated file or
`.env` rather than about the change itself.

Both checkouts orchid works in are `git worktree add` of a ref: the task's
dispatch worktree (a sibling directory named `<repo>-<task-id>`) and the
detached temp worktree merge validates in (under `$TMPDIR`). Each holds
**only what is committed**. Your own checkout also holds everything
untracked you have accumulated there — installed dependencies above all —
which is exactly the difference.

Point `worktree_prepare` at the command that supplies it:

```sh
# in <repo>/orchid.config
worktree_prepare=npm ci --silent
```

It runs inside each fresh checkout before anything else uses it, once per
checkout per command text, with `ORCHID_REPO_ROOT` set to this repository's
own canonical path — the way to reach back for something too expensive to
rebuild (`worktree_prepare=ln -s "$ORCHID_REPO_ROOT/node_modules" .`).
Output lands in `.orchid/runtime/worktree-prepare/<task>.log` (and
`<task>-merge.log` for the merge validation checkout); a failure stops the
run (a `worktree-conflict` boundary on dispatch, a refusal on merge) rather
than being scored against the candidate, and is retried on the next pass
once you have fixed it. It counts against `infra_failures`, never against
the task's `attempts`, so a bootstrap you never get round to fixing blocks
the task at `infra_max` instead of raising the same boundary forever. It
runs with **stdin closed**, so an installer that stops to ask a question
fails rather than hanging — pass whatever `--yes`/`--non-interactive` flag
it has. See [configuration.md](./configuration.md) for the full contract.

`ORCHID_REPO_ROOT` is exported to `verify` as well, in both checkouts, so a
suite that has to reach back for gitignored state at test time (rather than
once at setup time) can do it portably instead of hardcoding an absolute
path into committed config.

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
