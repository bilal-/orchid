# Install

Three ways to get orchid onto a machine — the one-liner below (recommended
for most people), a Homebrew tap (prepared here, not yet published), or a
plain git clone (best if you're hacking on orchid itself). All three end up
running the same bash+git+jq kernel — see [quickstart.md](./quickstart.md)
for what happens after any of them.

## One-line install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0/install.sh | bash
```

**This goes live once the repo is public.** `raw.githubusercontent.com`
cannot serve a file out of a private repository, so until then this
command 404s — use the [git clone method](#git-clone-for-hacking-on-orchid-itself)
below instead.

This downloads the installer from the version tag and runs it. Outside an
existing orchid checkout, the stable channel shallow-clones that same exact
tag to `${ORCHID_HOME:-~/.local/share/orchid}` and checks it out detached.
It never resolves `HEAD`, a branch name, or another moving ref. Re-running the
same command re-selects `v1.0.0`; it does not silently upgrade. To upgrade,
run the URL for the new release version.

The development channel is deliberately more conspicuous because it follows
the moving `main` branch:

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/main/install.sh | bash -s -- --channel development
```

Do not use the development channel when you need a reproducible install.

**Flags pass through** — since `bash` is reading the script off a pipe,
put them after `-s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0/install.sh | bash -s -- --prefix /usr/local
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/v1.0.0/install.sh | bash -s -- --uninstall
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

1. Update `release/metadata.conf`, `ORCHID_VERSION` in `lib/common.sh`, the
   two `ORCHID_INSTALL_*` assignments in `install.sh`, and the formula's
   version and URL. Commit the release payload while the tree is clean.

2. Compute the candidate checksum from Git objects only. The fixed mtime and
   tree object are the same inputs used by the verifier:

   ```sh
   version=X.Y.Z
   commit=$(git rev-parse HEAD)
   git archive --format=tar.gz --mtime=1970-01-01T00:00:00Z \
     --prefix="orchid-$version/" "${commit}^{tree}" | shasum -a 256
   ```

3. Put that exact digest in `Formula/orchid.rb`, commit the formula-only
   change, and create the version tag on that clean commit. `Formula/` is
   export-ignored, so this commit does not alter the archive bytes:

   ```sh
   git tag "v$version"
   ```

4. Run the local, non-publishing gate:

   ```sh
   /bin/bash scripts/release.sh --tag "v$version" \
     --output "$(mktemp -d)/orchid-release" --bash /bin/bash
   ```

   It requires a clean HEAD at the exact tag, peels that tag to one commit,
   builds twice from that commit's tree with `git archive`, compares bytes and
   checksums, validates prefix/content and all metadata, extracts the archive,
   and runs `scripts/ci-local.sh` inside it. It never reads payload files from
   the working tree and never pushes or publishes.

5. Inspect the emitted archive, checksum file, and formula. Uploading the
   archive, pushing the tag, and updating a tap remain separate, explicit
   operator actions; neither CI nor the release script performs them.

6. After those operator-owned publication steps are complete, install from
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
`~/.orchid/trust` store file appears on first `orchid plugins trust`)
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
`~/.orchid/{config,trust}` are always per-user, never per-prefix:

```sh
./install.sh --prefix /usr/local        # links /usr/local/bin/orchid
```

**Uninstall** reverses precisely the symlinks `install.sh` created
(config and trust are left in place):

```sh
./install.sh --uninstall
./install.sh --prefix /usr/local --uninstall   # if a custom --prefix was used to install
```

See [quickstart.md's step 1](./quickstart.md#1-clone-and-install) for the
full walkthrough this feeds into.
