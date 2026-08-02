# Install

Three ways to get orchid onto a machine — the one-liner below (recommended
for most people), a Homebrew tap (prepared here, not yet published), or a
plain git clone (best if you're hacking on orchid itself). All three end up
running the same bash+git+jq kernel — see [quickstart.md](./quickstart.md)
for what happens after any of them.

## One-line install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/main/install.sh | bash
```

**This goes live once the repo is public.** `raw.githubusercontent.com`
cannot serve a file out of a private repository, so until then this
command 404s — use the [git clone method](#git-clone-for-hacking-on-orchid-itself)
below instead.

This downloads `install.sh` and runs it. Since that's happening outside
any existing orchid checkout, `install.sh` first clones a canonical copy
(shallow, `--depth 1`) to `${ORCHID_HOME:-~/.local/share/orchid}`, then
hands off to that checkout's own `install.sh` — which is exactly the
git-clone method's `install.sh`, so it does exactly the same thing
described in the [git-clone section](#git-clone-for-hacking-on-orchid-itself)
below (front-end detection, `bin/orchid` symlink, `~/.orchid/` seeding,
`orchid doctor`).

**Running the exact same line again is the upgrade command:** if
`$ORCHID_HOME` already holds an orchid checkout, it's fast-forwarded
(`git pull --ff-only`) instead of re-cloned.

**Flags pass through** — since `bash` is reading the script off a pipe,
put them after `-s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/main/install.sh | bash -s -- --prefix /usr/local
curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/main/install.sh | bash -s -- --uninstall
```

`--uninstall` this way removes the symlinks the canonical clone created,
the same as it would from a manual checkout — but the clone at
`$ORCHID_HOME` itself is **not** deleted (it's what the next one-liner run
reuses to upgrade, not the installer's scratch space); the command prints
a one-line note confirming the clone's path.

## Homebrew (prepared, not yet published)

[`Formula/orchid.rb`](../Formula/orchid.rb) in this repo is a tap-ready
formula: it installs `bin/`, `libexec/`, `lib/`, `runners/`, `plugins/`,
`templates/`, `roles/`, and `PROTOCOL.md` under the formula's own
`libexec` prefix, then symlinks `bin/orchid` out into Homebrew's `bin` —
`bin/orchid`'s existing self-resolution (it follows its own symlink to a
real file, then takes that file's grandparent directory as `ORCHID_ROOT`)
lands on that `libexec` prefix without any wrapper script or rewriting.
`git` and `jq` are declared as formula dependencies.

**This formula is not tapped, installed, or published by this repository
or its tests.** `VERSION-PLACEHOLDER` and `SHA256-PLACEHOLDER` are literal
placeholder tokens; they are filled in by the steps below, by a human, on
release day — nothing here does it automatically.

### Release-day steps (operator, not automated)

1. Tag the release and push the tag:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

2. Compute the tarball's sha256 the same way GitHub's own
   `archive/refs/tags/vX.Y.Z.tar.gz` link generates it, via `git archive`
   against that tag (reproducible — no need to actually download the
   GitHub asset first):

   ```sh
   git archive --format=tar.gz --prefix=orchid-X.Y.Z/ vX.Y.Z | shasum -a 256
   ```

3. In `Formula/orchid.rb`, replace both placeholders with the values from
   steps 1–2: `VERSION-PLACEHOLDER` → `X.Y.Z` (two occurrences: the `url`
   line's `vVERSION-PLACEHOLDER` and the `version` line), `SHA256-PLACEHOLDER`
   → the `shasum -a 256` output from step 2.

4. Create the tap repository `bilal-/homebrew-orchid` (empty except for a
   `Formula/` directory), commit the filled-in `Formula/orchid.rb` there,
   and push it.

5. Pin the install one-liner below into `README.md`'s install section
   (replacing "once published") once step 4 is live:

   ```sh
   brew tap bilal-/orchid
   brew install orchid
   ```

   (equivalently, `brew install bilal-/orchid/orchid` without a separate
   `brew tap` step).

None of steps 1–5 are executed as part of this task — this section exists
so the operator has exact, copy-pasteable commands the day they're ready
to publish, and so [README.md](../README.md)'s current "once published"
note has somewhere concrete to point.

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
