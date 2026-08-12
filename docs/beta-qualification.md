# Beta qualification and the local release rehearsal

Two things live here, and they answer different questions.

- **`scripts/beta-qualify.sh`** answers *"can this Orchid build actually drive
  THIS repository unattended?"* Run it once per operator-supplied repository,
  before a beta tester spends a day finding out the hard way.
- **`tests/test_e2e_release_rehearsal.sh`** answers *"does the whole operator
  story still work end to end, locally, with no network and no external
  mutation?"* It runs as part of the ordinary suite.

Neither is a release, and neither is a third-party beta run. Both of those are
operator-owned and are listed as such at the end of this page.

## What the harness records, and what it refuses to record

Evidence is **anonymized by construction**. The harness never copies subprocess
output into a record. Every string it emits is a literal authored in
`scripts/beta-qualify.sh`, a number it measured, or a token from a closed
vocabulary it defines (`pass` / `fail` / `blocked` / `not-tested`, `allowed` /
`denied`, `present` / `absent`). Repository output is inspected only long
enough to derive one of those tokens, then discarded.

The one exception is stated rather than hidden, because a rule with a quiet
exception is not a rule. The recorded **toolchain versions and platform name**
are strings another program chose the characters of, and a vendor build is free
to append a build path or a packager's tag to its own version. So they are
*validated, not trusted*: a version must match a pattern authored in the
harness — dotted digits, at most 32 characters — or it is recorded as the
closed token `unrecognized`, and `uname -s` is mapped onto a closed set of
platform names or recorded as `other`. Whether a tool is *present* is derived
separately from the raw output, so an unusual version spelling never changes an
outcome. The build's own `ORCHID_VERSION` is also recorded; it describes the
harness, not the repository under test.

So the evidence contains check identities, durations, exit codes, order-of-
magnitude size bands, and outcomes — and never contents, paths, filenames,
prompts, diffs, command lines, or secrets. In particular the `verify=` command
is executed with **both of its output streams discarded unread**: only its exit
code and wall-clock duration are recorded. Before either file is left on disk,
the harness re-scans them for the target path, the operator's home, and the
scratch and output paths, and refuses to emit anything if one appears.

Every record also carries **why**: what was actually executed (`tested`), why
the check exists (`why`), and why this outcome was reached (`result`). The
harness refuses to write a record missing any of them. A pass/fail with the
reasoning left in some engine log is the evidence gap this exists to close.

## Running it

```sh
/bin/bash scripts/beta-qualify.sh \
  --repo /path/to/candidate-repo \
  --output "$(mktemp -d)/orchid-qualification" \
  --label candidate-a \
  --bash /bin/bash
```

It writes `qualification.json` and `qualification.txt` into `--output`, never
overwrites either, writes nothing of its own inside `--repo` (see the exception
immediately below), and never contacts a remote.
Exit `0` means qualified, `1` means not qualified, `2` means a usage or
precondition failure. `--help` lists every option.

`--repo` is read-only input with one deliberate exception: by default the
harness executes that repository's own configured `verify=` command once, in
place, to time it. That command is repository-specific code chosen by the
operator, and running it is what makes the timing probe real rather than a
guess. Pass `--no-run-verify` to skip it — the timing probe is then recorded as
`not-tested`, never as a pass.

## The probes, and the defects each one exists to catch

| Probe | Blocking | What it does |
|---|---|---|
| `toolchain` | yes | Runs the named Bash with a version floor check, plus `git --version` and `jq --version`. |
| `repo-config` | yes | Confirms a Git worktree with a configured `verify=` command; buckets commit and tracked-file counts. |
| `unattended-gate` | yes | **Reports** the machine-local unattended trust gate, and never changes it. A harness that acknowledged would be granting itself trust. It reads the gate twice and compares the two: matching reads are reported as the gate's state, and a gate that moved between two back-to-back reads fails the probe rather than being reported as either state. |
| `implementer-shell` | yes | Resolves `role.implementer` and reads the winning plugin's declared `capabilities=`. No `shell` means running a repository script and changing a file mode are operator hand-offs no in-loop actor can perform — a headless deadlock. |
| `implementer-command-execution` | no (`not-tested`) | Whether the adapter *actually grants* command execution, which is a different fact from the manifest declaration. See below. |
| `verify-duration` | yes | Times one real `verify=` run against `pump_stale_s`. The driver holds no lease refresh across a synchronous verification and the merge re-verifies after its rebase, so one pass costs roughly twice the verify duration with the lease untouched. |
| `merge-rebase-regeneration` | yes | The merge rebase invalidates any committed artifact derived from the tree's exact content (a checksum pin, a lockfile, a generated file). Regenerating one needs an actor that can run a command. |
| `stale-run-lock-visibility` | no | Plants a dead-owner run lock in the harness's own disposable scratch repository and checks whether a read-only command reports it. Recorded as `not-tested` — not as a gap — if the scratch repository could not be created or `orchid status --explain` never returned a report, because a check that could not run is not evidence that the behaviour is missing. |
| `notify-return-leg` | no (`not-tested`) | Records whether an outbound channel is *configured*; never that it works. See below. |

A **blocking** probe decides the repository's verdict. A non-blocking failure is
a property of the build rather than of the candidate repository, and every one
of them carries an `expires_when` line stating exactly what makes the warning go
away — a warning that can never expire is noise, not evidence.

A gate is only evidence once something actually runs it, and that is a separate
fact from whether it exists and works. This repository proved the point on
itself: `scripts/ci-local.sh` was built and passing, then went unrun for an
entire run because no task afterwards listed it among its verification
commands, and warnings across nine files accumulated behind a gate that existed
and worked the whole time. So qualify a gate the way you qualify a repository —
confirm it rejects a change you know it must reject, *and* confirm the command
that runs it sits in the path every change travels.

### Why two probes for one implementer question

`implementer-shell` reads the manifest, and a manifest `capabilities=` entry is
a **declaration by the plugin, not a grant**. Orchid uses those atoms to decide
which plugin is *eligible* for a role (`lib/roles.sh`); nothing derives a
runtime permission from them. There is no command allowlist anywhere that turns
a declared `shell` into a session that may actually execute a command. So
`shell` in a manifest means "this plugin says its work needs a shell" — never
"the engine's session will be permitted to run one".

The two facts already disagree in the shipped tree.
`plugins/engines/claude/plugin.conf` declares `shell`, but that adapter's
implement path launches the vendor CLI with a file-edit permission mode
(`--permission-mode acceptEdits`) and no `--allowedTools` argument at all — and
`acceptEdits` authorizes file edits only, so the Bash tool is never admitted.
Nothing reads the manifest's `shell` atom on that path. (The same
adapter's *orchestrate* path does pass `--allowedTools`, scoped to the brokered
command surface. That is a different launch, and an implementer never reaches
it.) A `claude` implementer therefore edits files happily and cannot run one
command — so `chmod +x` on a new `libexec` verb and applying a linter's own fix
are both silent, recurring operator hand-offs on that profile. (Re-pinning
`Formula/orchid.rb` is *not* one of them: that checksum is derived from the
whole tree, so it is regenerated on the integration branch at release time
rather than in any candidate — see [contributing.md](./contributing.md).)

That asymmetry is why `implementer-shell` is only a floor: a *missing* `shell`
declaration is decisive, because the profile certainly cannot run commands, while
a *present* one settles nothing. Proving the grant needs a live vendor round trip
with real quota, which this harness will neither spend nor contact, so
`implementer-command-execution` is recorded as `not-tested` with the manual
procedure attached. **Do that manual step once per implementer profile** (see the
checklist below).

### Why the notify probe never says "working"

The two legs are not symmetric. Outbound needs only a CLI on `PATH`. Inbound
needs a *persistent answering agent* paired to a live channel, and an operator
gets no signal when that agent is gone. A tester whose blocker question is never
answered concludes the whole phone workflow is broken when only the return leg
is. The harness contacts nothing, so it records the outbound half as configured
or not, records the round trip as `not-tested`, and tells you how to qualify it
by hand.

## Operator checklist (the parts no harness can do)

Run the harness first; it tells you which of these are still open for your
repository. Then, per candidate repository and per implementer profile:

- [ ] **Command execution, proven.** Give the implementer one task whose
      acceptance genuinely requires executing a repository script or changing a
      file mode. If the reply asks you to run it yourself, that profile is
      no-shell in practice regardless of its manifest, and every such task on it
      is an operator hand-off and a headless deadlock.
- [ ] **The blocker round trip, end to end.** Raise a real blocker, confirm the
      message arrives on the channel, answer it from the channel, and confirm
      `orchid answer` recorded it. Confirm the answering agent is running — its
      absence is not currently reported anywhere.
- [ ] **A killed verb.** Interrupt a merge, then check what a fresh operator can
      see about the run lock left behind. Today no read-only command reports it.
- [ ] **Content-derived artifacts.** If the repository commits anything derived
      from its own exact content, decide in advance who regenerates it after the
      merge rebase, and confirm that actor is actually in the loop.
- [ ] **Suite duration.** If `verify-duration` failed, either shorten the suite
      or raise `pump_stale_s` above roughly twice the measured duration before
      running unattended.
- [ ] **Unattended trust.** Acknowledge deliberately, with a real reason:
      `orchid trust unattended <repo> --reason "<why>"`. Nothing else opens that
      gate, and this harness never does.

## The local release rehearsal

`tests/test_e2e_release_rehearsal.sh` runs the whole story once, inside a single
private temporary root that holds `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
`TMPDIR`, `ORCHID_HOME`, `CLAUDE_SKILLS_DIR`, the install prefix, the plugin and
engine search paths, Git's global *and* system config, and every fixture,
worktree, and output path:

1. one-command setup (`orchid start`);
2. unattended refusal on the pump, the headless tick, and service installation;
3. explicit acknowledgement with an operator-authored reason;
4. beta qualification, with its evidence written under the root;
5. a deterministic drive from `pending` to `done` with no model in the loop;
6. the release gate, accepted once and refused for a moving ref, a missing tag,
   a dirty tree, and a release-facing placeholder;
7. installer wiring and its reversal.

Throughout, every network client, remote copy/shell tool, vendor CLI, notify
sender, package manager, and remote-capable `git` subcommand — `push`, `fetch`,
`pull`, `clone`, `ls-remote`, `remote update`, `submodule update`, `send-pack` —
is shadowed on `PATH` by a tripwire that logs and fails. `git` and `openssl` are
shadowed by *subcommand*, not wholesale, for the same reason: the rehearsal is
made of local `git` work, and `openssl dgst` is the digest fallback
`lib/common.sh` takes on a host without `shasum`. Only the remote-capable
subcommands are refused; the rest are delegated to the real binary. A tripwire
that fired on documented local behaviour would teach an operator to ignore
tripwire output. The rehearsal asserts
the log is empty, that no repository acquired a remote or a remote ref, that the
source checkout is unchanged afterwards, and that removing the root leaves the
machine exactly as it found it.

An empty tripwire log only means *nothing ran* if the tripwires are known to
fire and to log, so the rehearsal proves that first: it invokes each refused
shape — `curl`, `git push`, `git fetch`, `git pull`, `git clone`, `git
ls-remote origin`, `git remote update`, `git submodule update`, `git
send-pack`, `openssl s_client` — and asserts each one exits 97 *and* records
the invocation. That self-test runs from a throwaway repository created inside
the private root, with no remote and no history, and the rehearsal stays off
the caller's checkout from then on. The `PATH` shim is what should stop those
commands; it must not be the only thing that does. Standing on ground with no
remote means that even a total shim failure reaches a scratch directory with
nothing to push to and no `origin` to resolve.

Those last two claims are deliberately **narrow**, which is what makes them
mean anything on a real machine. The suite runs from a live Orchid worktree,
under an outer run that writes its own state as the tests execute:

- The source checkout is compared on its working tree (with `.orchid`, the
  outer run's live state, excluded), its file listing, its `HEAD`, and its
  **remote** refs. Local branches are shared with every other worktree of the
  same checkout and move through no act of the rehearsal's. All but the file
  listing are Git questions, and the suite is also runnable inside an unpacked
  release archive, which has no Git metadata at its root — so the rehearsal
  establishes that context first and, outside a checkout, records those three
  as `NOT-TESTED` rather than comparing three empty answers and calling the
  tree untouched. Run the rehearsal from the checkout when you need the whole
  claim.
- Machine-local state is compared path by path, at names the rehearsal writes
  down in advance — the skill symlinks `install.sh` wires, the entry point it
  links into its default prefix, the per-user config and data directories, the
  trust store, the launch-agent directory — and each one is recorded as a
  single token (`absent` / `dir` / `file` / `symlink` / `other`). The rehearsal
  never enumerates or reads what an operator already has there: a harness whose
  promise is *nothing outside the private root was touched* has no business
  reading real trust records to prove it. The one entry it could add to a
  directory an operator already owns is an unattended-trust record, whose name
  `lib/trust.sh` derives from the target's Git common directory — so the
  rehearsal derives that same name, proves the derivation against its own
  isolated store, and watches only that one path in the operator's.

Because `bin/orchid` deliberately pins a fixed `PATH` across each trust-boundary
decision before restoring the operator's, the tripwires cannot cover literally
every instant of every phase. That is why "no tripwire fired" is backed by an
outcome-level check that needs no `PATH` at all: no remote ref anywhere moved,
and nothing outside the root changed.

Run it directly:

```sh
/bin/bash tests/test_e2e_release_rehearsal.sh
```

## Still operator-owned, and not claimed anywhere in this repository

- A **genuine third-party beta run**, on a repository this operator does not
  control. Nothing here has done that, and no file in this repository records
  that it happened.
- **Publication** of any kind: pushing a tag, uploading an archive, updating a
  tap, or announcing a release. The release gate builds and verifies locally and
  stops there ([install.md](./install.md)).
- **Re-pinning `Formula/orchid.rb`** after any change to shipped bytes, and
  **`chmod +x`** on any newly added `libexec` verb. Both are hand-offs on a
  no-shell implementer profile.

## See also

- [install.md](./install.md) — the release-day steps and the local gate.
- [quickstart.md](./quickstart.md) — the ordinary operator path.
- [troubleshooting.md](./troubleshooting.md) — unattended trust refusals, stale
  locks, and stale checkouts.
- [specs/plugins.md](./specs/plugins.md#threat-model-consolidated) — the
  consolidated threat model.
- [contributing.md](./contributing.md) — the local CI gate.
