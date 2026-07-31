# Quickstart — greenfield (new product, no code yet)

For an **existing** repo, see [quickstart.md](./quickstart.md) instead —
that's the more common path and the one timed for the 15-minute release
rehearsal. This page covers the greenfield path: starting orchid before a
single line of product code exists.

**Prerequisites:** same as the existing-repo quickstart — at least one
engine CLI logged in under your own subscription, `git`, `jq`, bash 3.2+.
`orchid` installed via `./install.sh` (see
[quickstart.md's step 1](./quickstart.md#1-clone-and-install)).

## 1. An empty directory, and nothing else

```sh
mkdir "$HOME/path/to/your-new-product"
cd "$HOME/path/to/your-new-product"
git init
```

`orchid init --greenfield` refuses a directory that isn't empty apart from
`.git` — greenfield never silently adopts a pre-existing pile of files. If
you already have some scaffolding you want to keep, this is the existing-repo
path (`orchid init`, no `--greenfield`), not this one.

## 2. Initialize

```sh
orchid init --greenfield
```

On a repo with no commits yet (an "unborn HEAD"), this mints an empty root
commit first — the integration branch needs *some* HEAD to branch from —
then falls through into ordinary `init` unchanged: creates the integration
branch, commits `.orchid/` there, and prints the same `git worktree add`
hint as the existing-repo path. Run it:

```sh
git worktree add ../your-new-product-orchid orchid/integration
cd ../your-new-product-orchid
```

```sh
orchid doctor --greenfield
```

`--greenfield` skips the two preflight checks that cannot hold pre-scaffold:
a configured `verify` command, and the integration branch already existing
(both established the moment T001 below runs). Everything else — plugin
discovery, role bindings, git topology — is checked exactly as normal.

## 3. Requirements, then the scaffold task

```sh
$EDITOR requirements.md
orchid requirements import "$HOME/path/to/your-new-product/requirements.md"
```

The **first task drafted is, by convention, the scaffold task** (typically
`T001`) — it bootstraps the project itself (package manifest, a test
runner, a build command) before any task after it can rely on those
existing:

```sh
orchid task create T001 "Scaffold the project"
orchid task set T001 scaffold true
orchid task set T001 acceptance_criteria "..."
orchid task set T001 verification_commands "..."
```

`scaffold: true`'s `verification_commands` should be **structural**
assertions — files exist, the manifest parses, the build command exits 0 —
rather than product tests that cannot exist until this task creates the
test runner in the first place. This resolves the bootstrap paradox of
testing a test-runner that doesn't exist yet. Every task drafted after
T001 works exactly like the existing-repo path.

Run the same plan-critique loop as the existing-repo quickstart
([step 4](./quickstart.md#4-plan)), then:

```sh
orchid plan apply --reason "initial plan"
```

## 4. Everything else is identical

From here, follow [quickstart.md](./quickstart.md) starting at
[step 5](./quickstart.md#5-start-the-orchestrator-and-walk-away) — starting
the orchestrator, `orchid service install` for unattended operation,
`orchid status`/`orchid status --html` to check in, and answering any
genuine blocker via `orchid answer`/`orchid task unblock`.

## Next

- [quickstart.md](./quickstart.md) — the existing-repo path, referenced
  above for everything after planning.
- [configuration.md](./configuration.md), [troubleshooting.md](./troubleshooting.md)
