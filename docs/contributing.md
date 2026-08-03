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

The CI script rejects missing rationales, multi-code directives, and blanket
exclusions in `.shellcheckrc`. Test files and generated templates are not
exempt from lint.

## Release rehearsal

Release identity lives in `release/metadata.conf` and is cross-checked with the
kernel, installer, tag, and Homebrew formula by `scripts/release.sh`. Follow the
local-only checklist in [install.md](./install.md#release-day-steps-operator-not-automated).
The script emits files to the requested output directory but does not upload,
push, publish, or alter a tag.
