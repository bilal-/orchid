# Contributing

## One local CI command

Run the same deterministic gate as Linux CI, macOS CI, and extracted-release
rehearsal:

```sh
/bin/bash scripts/ci-local.sh --bash /bin/bash
```

The explicit interpreter is used for syntax checks and propagated to the test
runner. The gate discovers tracked and untracked, non-ignored shell files by
content: every `.sh` file and every Bash/sh shebang. That includes root scripts,
templates, extensionless commands, runners, adapters, tests, and helpers under
skills without maintaining a directory allowlist. `--list-shell` prints the
discovered set without running the gate.

The command runs Bash syntax, ShellCheck at warning severity, the full test
suite, and then calls out invariant and documentation suites explicitly. It
needs only Bash 3.2+, Git, jq, and ShellCheck; it reads no repository secrets.

## ShellCheck exceptions

The baseline is zero warnings. Fix a finding unless ShellCheck cannot see a
real cross-file contract, such as a public variable consumed by scripts that
source a library. A necessary exception must be line-local, name exactly one
`SC` code, and be immediately preceded by this form:

```sh
# ShellCheck rationale: concrete reason this one line is safe.
# shellcheck disable=SC1234
the_one_affected_command
```

The CI script rejects missing rationales, multi-code directives, directives
placed before a file's first command (ShellCheck scopes those to the entire
file, turning one annotation into a silent baseline), and blanket exclusions
in a repository `.shellcheckrc`. It invokes ShellCheck with `--norc`, so
repository-parent and user/global `.shellcheckrc` files cannot suppress the
warnings enforced by CI; the audited inline directives above are the only
exceptions. Test files and generated templates are not exempt from lint.

## Portability

Shipped scripts run under whatever `find(1)` the host provides, so the gate
also rejects find's non-POSIX depth primaries (`-mindepth`/`-maxdepth`).
One-level directory listings use plain bash globbing instead:
`orchid_list_dir` in `lib/common.sh` for shipped code, `list_dir_entries` /
`list_dir_files` in `tests/helpers.sh` for tests.

## Test fixtures and scratch directories

A test file never `cd`s into a scratch root with plain `cd`. Use
`cd_scratch "$WORK"` (and `make_scratch VAR` to mint a further root), both from
`tests/helpers.sh`. `cd ""` is a silent bash no-op — exit 0, cwd unchanged — so
a fixture whose scratch variable arrived empty would run its `git init` and
commits against the caller's checkout, which has happened twice and once
rewrote a real `orchid.config`. `cd_scratch` refuses an empty path, a
non-directory, and any path outside a directory the run itself created; and
because it is an *undefined command* when `helpers.sh` failed to load, the
fixture's `|| exit 1` also covers a copied test file whose `source` never
resolved. Paths built from a root (`"$WORK/repo"`) may keep plain `cd` — they
cannot come out empty. `tests/test_helpers.sh` proves the guard and lints the
suite for the plain-`cd` shape.

## Release rehearsal

Release identity lives in `release/metadata.conf` and is cross-checked with the
kernel, installer, tag, and Homebrew formula by `scripts/release.sh`. Follow the
local-only checklist in [install.md](./install.md#release-day-steps-operator-not-automated).
The script emits files to the requested output directory but does not upload,
push, publish, or alter a tag.

The formula's pinned SHA-256 must stay fresh for the tree that carries it:
`scripts/pin-formula.sh` recomputes the deterministic archive checksum from
current content and rewrites `Formula/orchid.rb`; its `--check` mode runs in
the test suite on every commit, so any change to shipped bytes must be
committed together with a re-pinned formula (`Formula/` is export-ignored,
so re-pinning never changes the archive itself).

Both tools build compressed bytes through the disposable repository's
config-isolated `git archive --format=tar.gz` backend. With archive-command
overrides excluded, Git uses its internal gzip implementation; a host `gzip`
found on `PATH` cannot influence the pinned bytes. Linux and macOS CI each
recompute and compare those bytes with the same committed formula checksum.

`tests/test_e2e_release_rehearsal.sh` runs the whole operator story once inside
one private temporary root — setup, unattended refusal, acknowledgement, beta
qualification, a deterministic drive, the release gate, and installer wiring —
with every network tool, vendor CLI, and remote-capable `git` subcommand
shadowed by a `PATH` tripwire that logs and fails. It is part of the suite the
gate above runs, so a change that reaches outside that root, moves a remote ref,
or modifies the source checkout fails CI rather than a tester's machine.

## Beta qualification

`scripts/beta-qualify.sh` qualifies one operator-supplied repository against
this build and writes anonymized local evidence. Genuine third-party beta runs
and publication remain operator-owned; this repository performs neither and
claims neither. See [beta-qualification.md](./beta-qualification.md) for the
probe list, the evidence rule, and the manual checklist.
