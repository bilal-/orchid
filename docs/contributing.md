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

`stat(1)` is the other split: mtime is `-f %m` on BSD and `-c %Y` on GNU. Read
one through `file_mtime` in `lib/common.sh` and never name either format in a
shipped shell script — the gate rejects that. The one exemption is
`file_mtime`'s own comment-and-body block, *not* the rest of `lib/common.sh`:
a whole-file pass would let the next raw idiom land beside the helper written
to prevent it, in the same file as `lock_acquire`. Rename or move the helper
and a format left anywhere in that file is refused rather than exempted, so
the hole cannot reopen quietly. The gate is also not keyed to one spelling:
it matches with or without a space, quoted or bare, and covers GNU's
`--format`/`--printf` long options too, each with or without its `=` — so no
spacing of the option and its format quietly gets through. (This page is
prose, not a shell script, which is why it may write the formats out.)

Bridging the two by exit status (`stat -f … || stat -c …`) looks
right and is wrong: GNU's `-f` is `--file-system` and takes no argument, so
the format becomes a second FILE operand, GNU `stat` succeeds on the real path
anyway, and the caller gets a filesystem block whose first line is `File:`.
The arithmetic that follows then dies under `set -u` with
`File: unbound variable`. Select on the *result* — digits or nothing —
which is what `file_mtime` does.

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

## Every gate ships a RED case

A check that cannot fail is not a check. Runs r-001 and r-002 shipped, in good
faith, a review envelope with an empty `findings[]`, a probe that grepped the
reply for the string it had itself fed into the prompt, a rehearsal snapshot
comparing a tree that was never at risk, a `doctor` reporting outbound ok
without reading the config its plugin requires, and an inbound line whose
output was identical whether or not a gateway existed. In a log, none of those
is distinguishable from a check that ran. The rule is normative in
[docs/specs/kernel.md](./specs/kernel.md) ("Proof discipline") and in
[PROTOCOL.md](../PROTOCOL.md)'s Preamble: **a check that gates anything must
ship a RED case demonstrating that it detects the failure it exists for, and
that RED case must itself be exercised by the suite.**

In practice, when you write a gate:

1. Feed the check an input it MUST reject, watch it fire, and record that with
   `red_case "<what fired, and on what>"` from `tests/helpers.sh`. The label is
   printed as a `RED-CASE:` line, so the log shows *which* failure was
   demonstrated.
2. Pair it with the GREEN twin — an input the same check must accept. A matcher
   that rejects everything detects nothing.
3. Annotate the file with `# RED:` and `# GREEN:` comments naming both, in a
   sentence rather than a word.
4. What you cannot demonstrate goes through `not_tested`, never a pass.

Enforcement is in two halves, because structure alone cannot carry a rule about
proof. `tests/helpers.sh`'s `EXIT` trap fails any file under `tests/inv/` that
records no RED case *at run time* — by path, so a new invariant gate cannot opt
out by not knowing the rule exists, and no comment can satisfy it.
`tests/test_red_case_rule.sh` lints every enrolled gate for the annotations and
the `red_case` call, and exercises both halves against fixtures — a rule about
unfalsifiable checks enforced by an unfalsifiable check would be the same
defect one level up. Put a new gate under `tests/inv/`, where the requirement
reaches it; the rest of `tests/test_*.sh` predates the rule and is held to it by
review, which that file records as `NOT-TESTED:` rather than implying coverage
it does not have. Whether a recorded RED case is *honest* — whether the input
really was one the check must reject — is reviewer-owned and cannot be
mechanized; ask it of every new gate.

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
with every network tool, vendor CLI, and remote-capable `git`/`openssl`
subcommand shadowed by a `PATH` tripwire that logs and fails (those two are
shadowed per-subcommand, so local `git` work and the `openssl dgst` digest
fallback still reach the real binary). It is part of the suite the
gate above runs, so a change that reaches outside that root, moves a remote ref,
or modifies the source checkout fails CI rather than a tester's machine.

## The suite is hermetic: no vendor CLI required

The deterministic suite must pass on a machine with no `codex`, `claude`,
`agy`, `hermes`, or `openclaw` installed. It did not, once: capsuite's
`binaries_present` check resolves each engine manifest's `requires_binaries`
on `PATH`, and `tests/test_plugins_test.sh` asserted those pairs pass — so the
suite was quietly asserting a fact about the author's laptop. It stayed green
locally and failed on both hosted runners.

`tests/test_hermetic_suite.sh` is the standing proof:

```sh
/bin/bash tests/test_hermetic_suite.sh
```

It builds a `PATH` on which every vendor CLI is *unresolvable* — each `PATH`
entry that contains one is replaced by a scratch directory of symlinks to
everything else in it, so `jq` living beside `codex` in the same Homebrew bin
survives — and then runs the whole suite on it. It is a `tests/test_*.sh` file,
so `tests/run.sh` and therefore `scripts/ci-local.sh` and hosted CI run it too.

The mirror is the only thing that can lose a tool the suite needs, so it
asserts, on the rebuilt `PATH`, that each one still resolves — including a
SHA-256 tool (`shasum`, or `openssl` as `plugin_digest`'s documented fallback).
Losing that one is the least legible failure available: capsuite's freshness
marker and the digest-pinned trust store are both built on it, so the nested
run would fail broadly with digest mismatches that name neither `PATH` nor the
mirror.

Resolving is not the same as *working*. A mirrored entry is a symlink in a
scratch directory, and a wrapper script that finds its payload with `dirname
"$0"` resolves that to the scratch directory instead — so a mirrored tool can
behave differently from the real one, and a proof standing on it would be
proving something about a tool nobody has. The file demonstrates that rather
than assuming it: a wrapper is mirrored, both copies are run, and their answers
must differ; a location-independent tool's must not. The same detector is then
pointed at every tool the suite needs inside every entry the mirror actually
replaced, and a hit is a failure — the remedy is to fix the mirror for that
tool or record a named exemption with its reason, never to widen the detector.
Compiled binaries that resolve their own location from `argv[0]` are outside
what a text scan can see and are recorded as `NOT-TESTED:` (`git` is the
interesting case, and is safe: it canonicalizes through the symlink).

When the nested run does fail, its log is copied out of the scratch tree
*before* anything names it — `$TMPDIR/orchid-hermetic-suite-failure.<pid>.log`
— because the trap that deletes `$WORK` runs before anyone reads the message.
The diagnostic itself is never empty: a run that died without reaching an
assertion has no `FAIL:` lines to extract, so the report says so and prints the
tail instead of a header, a blank and a footer. Both behaviours are exercised
against synthetic logs on every run, including on the machines where the nested
run is skipped — that is where the next red run will be the first time anyone
reads this output.

That nesting means one gate run can execute the suite twice, so the second run
is launched only when it can differ from the first. On a machine where a vendor
CLI really does resolve — a developer laptop, which is where the divergence
hides — it always runs. Where none resolves, the surrounding `tests/run.sh`
(`ORCHID_SUITE_RUN`) is *itself* the vendor-CLI-free whole-suite run: if any
test depends on an installed vendor CLI, that run goes red, and a nested copy
would only double every CI job to reach the same verdict. The skip is printed
as a `NOT-TESTED:` line rather than passing quietly. Invoked on its own,
outside `tests/run.sh`, there is no surrounding run to lean on and the nested
run happens regardless.

Both halves of that condition are *measured*, never assumed. Which vendor CLIs
resolve is asked of the ambient `PATH` rather than inferred from how many
`PATH` entries needed mirroring: an empty `PATH` element means the current
directory and cannot be mirrored at all, so the count would report a clean
machine while the surrounding run could still reach a `codex` in its cwd. And
`ORCHID_SUITE_RUN` carries `tests/run.sh`'s own physical path, which the proof
compares against the runner it resolved for itself — a bare `1` would be
forgeable by accident, and a stray one in an operator's environment would stand
the proof down on a vendor-CLI-free machine with nothing having run in its
place. Losing the marker only ever costs a duplicate run; that asymmetry is why
it is a path.

One boundary the file records rather than covers: `bin/orchid` replaces `PATH`
with a fixed machine-local list for its own bootstrap and restores the caller's
at each verb's first `source` of `lib/common.sh`, so every binary lookup that
exists today — `binaries_present` included — runs on the restricted `PATH`. A
lookup added *ahead* of that restore would read the fixed list, which no `PATH`
restriction can reach.

`PATH` is not the only ambient input, so the nested run also gets a **HOME of
its own** — a scratch directory that did not exist a moment ago, holds no
Orchid state, and whose path nothing else on the machine knows. Everything
machine-local the suite reads resolves through `HOME`: user config
(`$HOME/.orchid/config`), the unattended-trust store, capsuite freshness
markers, and the home-rooted plugin search paths in `lib/resolver.sh`,
`lib/roles.sh` and `lib/archetype.sh`. That state is shared with every other
Orchid on the box, including a drive loop polling the same repository while the
suite runs — which is how a verification of this very change failed twice on an
unchanged tree and passed twice more (lesson L024). `XDG_*` goes with `HOME`,
because git reads its own configuration through those names and they can point
back inside the operator's home; `ORCHID_ACTOR`/`ORCHID_REPO`/`ORCHID_EPOCH`
are unset for the reason `tests/helpers.sh` (not `tests/run.sh`) unsets them —
an inherited durable identity binds a disposable fixture to the outer run. The
attribution matters: the guard is one line at the top of `helpers.sh`, and a
reader who believes it lives in the runner can delete it there without finding
anything that stops them.

That isolation is demonstrated rather than asserted, and every probe is paired
with a control that can fail. A decoy scratch home stands in for the
operator's, seeded with poisonous machine-local state; the controls prove the
decoy is a live sink (a write through `HOME` is visible to the fingerprint) and
a live source (the poison is legible through `HOME`), and the probes then show
a child launched *through the same function the nested run is launched with*
writes into the disposable home, leaves the inherited one byte-identical, reads
none of the poison, and receives no durable run identity. The nested suite then
runs with a writer concurrently rewriting the decoy's Orchid state for the
whole duration; the run must pass, the writer must have ticked, and the churn
must never turn up inside the nested home. What no test file can defend
against — a second Orchid rebasing, re-pinning or rewriting *this checkout*
mid-run — is recorded as `NOT-TESTED:` and left as an operator scheduling
constraint: do not verify this repository while a drive loop is dispatching
against the same worktree.

The recursion guard (`ORCHID_HERMETIC_PROOF`) stops a nested run from
re-launching a third. It is an **exact match against a token literal in the
file**, never a truthiness test: a bare `-n` check is satisfied by any value,
so a stray `ORCHID_HERMETIC_PROOF=1` in an operator's shell would make the
whole proof print one `NOT-TESTED:` line and exit 0 — an unproven-ok in the
harness built to prevent unproven-oks, and one that is indistinguishable in a
log from a flaky run. Same asymmetry as `ORCHID_SUITE_RUN`: losing the marker
costs a duplicate run, forging it costs the guarantee. The file asserts the
guard fires against a synthetic re-entry carrying the exact token, that a
battery of stray and near-miss values do *not* satisfy it (`--guard-probe`
reports which side of the guard an invocation landed on without running the
proof; the guard is checked ahead of it, so it cannot pre-empt it), that a real
nested run re-enters exactly once with that token, and — separately, and in
both modes, because it has to hold even when nothing is nested — that
`tests/run.sh`'s glob still reaches this file at all. That last one failing
means the guarantee has silently stopped being enforced.

A test that genuinely needs a vendor CLI present plants a stub on `PATH`
(`tests/test_plugins_test.sh`) rather than asking the machine. Weakening the
check itself is not an option: `capsuite_passed` is what gates failover
(`resolve_role_available`), and a `binaries_present` that cannot fail would
make that gate blind. `tests/test_capsuite.sh` pins the check in both
directions with no vendor name in it at all.

What a stub cannot prove — that a real vendor CLI is installed, authenticated,
and behaves — is recorded by `not_tested` from `tests/helpers.sh`, which prints
a `NOT-TESTED:` line in `scripts/beta-qualify.sh`'s vocabulary. Skipping is
allowed; skipping silently is not. Qualify those claims out of band with
`orchid plugins test --all-defaults` on a machine that has the CLIs.

## Beta qualification

`scripts/beta-qualify.sh` qualifies one operator-supplied repository against
this build and writes anonymized local evidence. Genuine third-party beta runs
and publication remain operator-owned; this repository performs neither and
claims neither. See [beta-qualification.md](./beta-qualification.md) for the
probe list, the evidence rule, and the manual checklist.
