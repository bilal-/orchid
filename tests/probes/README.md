# Real-engine probes

These scripts answer four open questions about the real `codex`, `agy`,
and `claude` CLIs that stub-based tests can't settle, because the stubs
*are* the answer to those questions by construction. They are **manual,
operator-run tools — never part of the automated suite.**

## Why they're excluded from `tests/run.sh`

`tests/run.sh` only globs `test_*.sh` directly inside `tests/` and
`tests/inv/`:

```sh
for t in "$(dirname "$0")"/test_*.sh "$(dirname "$0")"/inv/test_*.sh; do
```

Every file in this directory is named `probe-*.sh`, not `test_*.sh`, so
none of them match — that's the primary, intentional signal. They also
live one directory down (`tests/probes/`), which the glob doesn't
descend into, so even a stray `test_*.sh` rename in here still wouldn't
be picked up. Verified by inspection of `tests/run.sh` above; confirmed
empirically while writing these probes (`bash tests/run.sh` stays green
with this directory present).

## What each probe checks

| Probe | Question | Cost |
|---|---|---|
| `probe-codex-review-range.sh` | Does `codex exec review` accept an explicit base..head range, or only a single-ended selector? | **Free.** Reads `codex exec review --help` only; never runs an actual review. |
| `probe-agy-stdin.sh` | Does `agy -p` accept the prompt via stdin (the `-` convention, or plain redirection)? | **Real quota, small.** Runs up to two short "reply with exactly OK" round trips against the real model. |
| `probe-claude-implement.sh` | Can `claude -p --permission-mode acceptEdits` actually create a file and commit it, unattended? | **Real quota, larger.** Runs one full implement-shaped round trip (`claude -p ... --permission-mode acceptEdits`) against a scratch git repo. |
| `probe-claude-tick.sh` | Can `claude -p --permission-mode acceptEdits` actually EXECUTE a Bash verb (`orchid status`) headless — not just edit files — and reliably print the `ORCHID-ACTION:` marker the `orchestrate` adapter greps out of its transcript? (v1-m2 Task 7's "claude -p full tick" open question.) | **Real quota, one round trip.** Asks claude to run `orchid status` in a scratch repo and echo back the marker line. |

**Quota warning:** `probe-agy-stdin.sh`, `probe-claude-implement.sh`, and
`probe-claude-tick.sh` call the real, billed CLIs. Don't loop them, don't
wire them into CI, and don't run them more than needed to answer the
question. Treat `probe-claude-implement.sh` in particular as the most
expensive of the four — it drives a full implement-style agentic turn, not
a one-line reply.

## When/why to run

- **Before dogfooding** (e.g. Plan B2 Task 9's webBooks run): confirm the
  assumptions the engine adapters (`plugins/engines/{codex,agy,claude}/run`)
  are built on still hold against the CLIs actually installed, before
  spending a real task's worth of quota on the dogfood run itself.
- **After upgrading any of the three CLIs**: flag shapes and stdin
  handling are exactly the kind of thing a CLI upgrade silently changes.
  Re-run the relevant probe(s) rather than assuming the adapter still
  matches reality.
- Not otherwise. They are not regression tests and add no signal beyond
  the one question each was written to answer.

## Running them

Each probe is a standalone, self-contained script:

```sh
bash tests/probes/probe-codex-review-range.sh
bash tests/probes/probe-agy-stdin.sh
bash tests/probes/probe-claude-implement.sh
bash tests/probes/probe-claude-tick.sh
```

Each guards on `command -v <cli>` first and prints exactly one line on
success or absence:

```
PROBE-RESULT: SKIP (<cli> not installed)
```

when the CLI isn't on `PATH` (verified by PATH-masking each of the three
during development — see git history for this file's commit). Real
attempts are wrapped in a 60s (agy) / 120s (claude) inline timeout, and a
run that fails because the CLI isn't authenticated ends the same clean
way instead of hanging or throwing a raw error:

```
PROBE-RESULT: AUTH-UNAVAILABLE (<first line of the CLI's error>)
```

Otherwise each probe prints its finding — `YES` / `NO` / `PARTIAL` /
`AMBIGUOUS` / `WORKED` / `NONE` depending on the probe — with the
concrete evidence (raw usage line, CLI reply, or `git log` output) that
produced it, on a single `PROBE-RESULT:` line. All four exit 0
regardless of outcome; a probe's job is to report a finding, not to pass
or fail.

**Containment caveat:** the claude probes (`probe-claude-implement.sh`,
`probe-claude-tick.sh`) set cwd to a scratch repo, but containment is
instruction-level, not enforced — review the probe's aftermath (`git
status` in unexpected places) before trusting results.
