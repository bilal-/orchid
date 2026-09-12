# Install

Three ways to get orchid onto a machine — the one-liner below (recommended
for most people), a Homebrew tap (prepared here, not yet published), or a
plain git clone (best if you're hacking on orchid itself). All three end up
running the same bash+git+jq kernel — see [quickstart.md](./quickstart.md)
for what happens after any of them.

## One-line install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0-beta.1/install.sh | bash
```

**The prepared version is `1.0.0-beta.1`, a prerelease.** Orchid has run on
its own repository and on the webBooks and wasiyyat application repositories,
but all of that was author-operated dogfood. No genuine third-party beta or
public release has happened; `1.0.0` is reserved for the stronger evidence in
[the r-002 retrospective](./r-002-retrospective.md#the-requirements-for-10).

**This is the prepared release-day URL, not evidence that a release was
published.** r-002 did not push a tag or publish the repository, installer, or
Homebrew tap. Until the operator performs those steps, use the
[git clone method](#git-clone-for-hacking-on-orchid-itself) below instead.

This downloads the installer from the version tag and runs it. A piped
invocation always selects that same exact tag in the canonical checkout at
`${ORCHID_HOME:-~/.local/share/orchid}`—shallow-cloning when it is absent and
reusing it otherwise—regardless of the caller's current directory. Running
the command from inside another, even dirty, Orchid checkout never installs
from that checkout: piped Bash has no installer pathname, so the current
directory is never accepted as source. The stable channel never resolves
`HEAD`, a branch name, or another moving ref. Re-running the same command
re-selects `v1.0.0-beta.1`; it does not silently upgrade. To upgrade, run the
URL for the new release version.

The development channel is deliberately more conspicuous because it follows
the moving `main` branch:

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/main/install.sh | bash -s -- --channel development
```

Do not use the development channel when you need a reproducible install.

**Flags pass through** — since `bash` is reading the script off a pipe,
put them after `-s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0-beta.1/install.sh | bash -s -- --prefix /usr/local
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0-beta.1/install.sh | bash -s -- --uninstall
```

`--uninstall` this way removes the symlinks the canonical clone created,
the same as it would from a manual checkout — but the clone at
`$ORCHID_HOME` itself is **not** deleted (it's what the next one-liner run
reuses to upgrade, not the installer's scratch space); the command prints
a one-line note confirming the clone's path.

## Homebrew (prepared, not yet published)

`Formula/orchid.rb` in the source repository is a tap-ready
formula: it installs `bin/`, `libexec/`, `lib/`, `runners/`, `plugins/`,
`templates/`, `roles/`, and `PROTOCOL.md` under the formula's own
`libexec` prefix, then symlinks `bin/orchid` out into Homebrew's `bin` —
`bin/orchid`'s existing self-resolution (it follows its own symlink to a
real file, then takes that file's grandparent directory as `ORCHID_ROOT`)
lands on that `libexec` prefix without any wrapper script or rewriting.
`git` and `jq` are declared as formula dependencies.

**This formula is not tapped, installed, or published by this repository or
its tests.** Its version, release-asset URL, and SHA-256 are concrete inputs
cross-checked by the local release gate. The formula itself is export-ignored
from the source archive, avoiding a checksum self-reference.

### Release-day steps (operator, not automated)

These steps begin only after run acceptance is complete: candidate-local CI
has been recorded, the assembled tree has run the canonical suite from a
checkout actually parked on the configured integration branch, and any
required hosted CI has been observed after the operator pushed. A candidate
cannot pre-claim either post-merge observation. Release-day formula pinning is
later still and remains an integration/release operation, never a candidate
hand-off.

1. Update `release/metadata.conf`, `ORCHID_VERSION` in `lib/common.sh`, the
   two `ORCHID_INSTALL_*` assignments in `install.sh`, and the formula's
   version and URL. Commit the release payload while the tree is clean.

   The version may be a plain `MAJOR.MINOR.PATCH` or carry a semver
   prerelease suffix (`1.0.0-beta.1`, `1.1.0-rc.2`) — `scripts/release.sh`,
   `install.sh`'s stable-channel gate, and the checks below all accept both.
   Build metadata (`+…`) is not accepted anywhere.

2. Re-pin the formula checksum with the canonical tool (the same fixed
   mtime, prefix, and tree inputs the verifier uses — it snapshots current
   content through a disposable, config-isolated Git repository and rewrites
   `Formula/orchid.rb` in place; `--check` verifies without rewriting).

   Expect the pin to be stale when you arrive here, and re-pin on the
   integration branch. That is deliberate: the checksum is derived from the
   whole tree, so obliging every branch to re-pin would have every branch
   rewrite the same line to a different value, and the second one to merge
   would conflict with no way to resolve it unattended. Nothing upstream of
   this step re-pins, and step 4's release gate is what refuses to ship if
   you skip it — see [contributing.md](./contributing.md#release-rehearsal):

   ```sh
   /bin/bash scripts/pin-formula.sh
   ```

3. Commit the formula-only change and create the version tag on that clean
   commit. `Formula/` is export-ignored, so this commit does not alter the
   archive bytes — which is exactly why the pinned digest stays valid for
   the tagged commit:

   ```sh
   version="$(sed -n 's/^version=//p' release/metadata.conf)"
   tag="$(sed -n 's/^tag=//p' release/metadata.conf)"
   if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'; then
     echo "invalid release metadata version: $version" >&2
     exit 1
   fi
   if [ "$tag" != "v$version" ]; then
     echo "release metadata mismatch: tag=$tag version=$version" >&2
     exit 1
   fi
   git tag "$tag"
   ```

4. Run the local, non-publishing gate:

   ```sh
   version="$(sed -n 's/^version=//p' release/metadata.conf)"
   tag="$(sed -n 's/^tag=//p' release/metadata.conf)"
   if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'; then
     echo "invalid release metadata version: $version" >&2
     exit 1
   fi
   if [ "$tag" != "v$version" ]; then
     echo "release metadata mismatch: tag=$tag version=$version" >&2
     exit 1
   fi
   /bin/bash scripts/release.sh --tag "$tag" \
     --output "$(mktemp -d)/orchid-release" --bash /bin/bash
   ```

   It requires a clean HEAD at the exact tag, peels that tag to one commit,
   builds twice from that commit's tree with `git archive`, compares bytes and
   checksums, validates prefix/content and all metadata, extracts the archive,
   and runs `scripts/ci-local.sh` inside it. Archive generation uses disposable
   Git metadata and the tree's own attributes only: system/global/local Git
   configuration, custom archive commands, and the source checkout's
   `info/attributes` cannot change the bytes. It never reads payload files
   from the working tree and never pushes or publishes.

5. Rehearse the whole operator story locally, inside a single private
   temporary root, with every network tool, vendor CLI, and remote-capable
   `git`/`openssl` subcommand shadowed by a `PATH` tripwire that logs and
   fails (those two are shadowed per-subcommand, so local `git` work and the
   `openssl dgst` digest fallback still reach the real binary):

   ```sh
   /bin/bash tests/test_e2e_release_rehearsal.sh
   ```

   It covers one-command setup, the unattended refusal, an explicit
   acknowledgement, beta qualification, a deterministic drive, the release
   gate's accept and refuse paths, and installer wiring — then asserts that no
   tripwire fired, that no repository acquired a remote or a remote ref, that
   the source checkout is unchanged afterwards (working tree, file listing,
   `HEAD`, and remote refs), and that removing the root leaves the machine as
   it found it.

   Run it from the Git checkout you are tagging, which is what this step
   assumes. The suite is runnable inside an unpacked release archive too, and
   there the tree has no Git metadata at its root: the rehearsal detects that
   context, compares the file listing only, and records the working-tree,
   `HEAD` and remote-ref half of the claim above as `NOT-TESTED`. It is never
   reported as a pass — three Git questions a tree cannot answer would
   otherwise compare equal before and after whatever the run did. So a
   rehearsal for release day has to happen in the checkout, or the isolation
   claim you are relying on is one that run did not make.

   Qualify each candidate repository with
   `scripts/beta-qualify.sh` and work through
   [beta-qualification.md](./beta-qualification.md)'s operator checklist before
   handing a build to anyone.

6. Inspect the emitted archive, checksum file, and formula. Uploading the
   archive, pushing the tag, and updating a tap remain separate, explicit
   operator actions; neither CI nor the release script performs them. A genuine
   third-party beta run is likewise operator-owned: nothing in this repository
   performs one or records that one happened.

7. After those operator-owned publication steps are complete, install from
   the tap with:

   ```sh
   brew tap bilal-/orchid
   brew install orchid
   ```

   (equivalently, `brew install bilal-/orchid/orchid` without a separate
   `brew tap` step).

No publication step is executed by repository tests or CI.

## git clone (for hacking on orchid itself)

```sh
git clone <this-repo-url> "$HOME/src/orchid"
cd "$HOME/src/orchid"
./install.sh
```

Does exactly and only: wires the interactive orchestrator skills
(`skills/{orchid,orchid-plan,orchid-resume}`) into whichever agent
front-ends are **actually present** on this machine — not one hardcoded
vendor. Concretely: Claude Code (symlinked into `$CLAUDE_SKILLS_DIR`,
default `~/.claude/skills` — today's tested default, wired if `~/.claude`
exists or `CLAUDE_SKILLS_DIR` is set) and Hermes (symlinked into
`~/.hermes/skills/orchestration/`, wired if that directory exists) each get
wired when present, and skipped with a one-line note (no directory
creation) when absent; OpenClaw gets a suggested `openclaw skills install`
command printed instead of an automatic run, since registration targets a
specific agent/gateway install.sh has no business choosing. See
[frontends.md](./frontends.md) for the full per-engine breakdown (what's
tested vs. untested) and for driving orchid from codex/agy, which need no
install.sh wiring at all. Regardless of front-end, install.sh also
symlinks `bin/orchid` into `$ORCHID_BIN_DIR` (default `~/.local/bin`),
creates `~/.orchid/plugins/engines` and a commented `~/.orchid/config` (the
`~/.orchid/trust` store file appears on first `orchid plugins trust`; the
separate `~/.orchid/unattended-trust/` directory appears on first
`orchid trust unattended`)
(never overwritten if it already exists), then finishes by running `orchid
doctor` (inside a git repo you'd orchestrate) or printing next-steps
(outside one). Re-running it is safe: an existing `~/.orchid/config` is
left untouched, and a real file or a symlink to somewhere else already
sitting at a link path is left alone (with a warning) rather than
clobbered.

**Custom bin location:** pass `--prefix DIR` (or `--prefix=DIR`) to link
`bin/orchid` under `DIR/bin` instead of `~/.local/bin` — useful if
`~/.local/bin` isn't on `PATH` on this machine, or a shared install
location is preferred. Only the bin symlink moves; skills and
`~/.orchid/{config,trust,unattended-trust}` are always per-user, never
per-prefix:

```sh
./install.sh --prefix /usr/local        # links /usr/local/bin/orchid
```

**Uninstall** reverses precisely the symlinks `install.sh` created
(config, plugin trust, and unattended acknowledgements are left in place):

```sh
./install.sh --uninstall
./install.sh --prefix /usr/local --uninstall   # if a custom --prefix was used to install
```

See [quickstart.md's step 1](./quickstart.md#1-clone-and-install) for the
full walkthrough this feeds into.
