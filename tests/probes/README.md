# Real-engine probes

These scripts answer six open questions about the real `codex`, `agy`,
`claude`, and `hermes` CLIs that stub-based tests can't settle, because the stubs
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
| `probe-claude-tick.sh` | With `--allowedTools Bash` added (F8 fix, on top of `--permission-mode acceptEdits`), does headless claude actually EXECUTE `orchid` verbs by absolute binary path — real command output, not just a hallucinated `ORCHID-ACTION:` marker line with nothing behind it? | **Real quota, one round trip.** Asks claude to run `<abs>/bin/orchid version` and `<abs>/bin/orchid config list` in a scratch repo, echo the marker for each, and checks the transcript for the real output (`1.0.0`, `integration_branch`). |
| `probe-stream-buffering.sh` | v1-m3 log-streaming fix: adapters now `tee` each CLI's stdout to the job log as it runs (`stdout="$(cli ... 2>err \| tee /dev/stderr)"`). That idiom proves bash's own plumbing doesn't buffer — whether the real `codex`/`claude` binaries buffer THEIR OWN stdout internally until the whole reply is ready (which would still leave the job log jumping from 0 to full size in one shot, right at exit) is a separate, unverified question. | **Real quota, one small round trip each.** Runs a "count to 5, one number per line" prompt through the exact adapter pipeline shape for codex and (separately) claude, sampling a scratch log's byte size once a second while each CLI runs. One `PROBE-RESULT:` line per engine: `STREAMS` (log grew before exit) or `BUFFERED` (log stayed empty until exit, then jumped). |
| `probe-hermes.sh` | v1-m4 Task 6: (1) does `hermes --safe-mode -t clarify -z "<prompt>"` — the exact invocation `plugins/engines/hermes/run` uses for review/critique — still return the plain VERDICT/REASON contract text against the real CLI? (2) `hermes` has no `implement` path yet (flag research found no confinement flag; see `docs/engines/hermes.md`) — does a RELATIVE-path file write from `hermes --safe-mode -t file -z ...`, cwd-scoped to a scratch dir, land inside that scratch dir? (Deliberately does NOT test the absolute-path escape case for real — a `YES`/`PARTIAL` here narrows the open question, it does not close it.) | **Real quota, two small round trips.** One review-shaped reply, one short one-shot file-creation prompt in a scratch dir. Two `PROBE-RESULT:` lines, prefixed `review-shaped`/`implement-shaped`. |

**Quota warning:** `probe-agy-stdin.sh`, `probe-claude-implement.sh`,
`probe-claude-tick.sh`, `probe-stream-buffering.sh`, and `probe-hermes.sh`
call the real, billed CLIs (`probe-stream-buffering.sh` calls two of them,
codex and claude, in a single run). Don't loop them, don't wire them into
CI, and don't run them more than needed to answer the question. Treat
`probe-claude-implement.sh` in particular as the most expensive of the
six — it drives a full implement-style agentic turn, not a one-line reply.

## When/why to run

- **Before dogfooding** (e.g. Plan B2 Task 9's webBooks run): confirm the
  assumptions the engine adapters (`plugins/engines/{codex,agy,claude,hermes}/run`)
  are built on still hold against the CLIs actually installed, before
  spending a real task's worth of quota on the dogfood run itself.
- **After upgrading any of the four CLIs**: flag shapes and stdin
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
bash tests/probes/probe-stream-buffering.sh
bash tests/probes/probe-hermes.sh
```

Each guards on `command -v <cli>` first and prints exactly one line on
success or absence:

```
PROBE-RESULT: SKIP (<cli> not installed)
```

when the CLI isn't on `PATH` (verified by PATH-masking each during
development — see git history for this file's commit). Real attempts are
wrapped in a 60s (agy) / 120s (claude) / 60-90s (hermes) inline timeout,
and a run that fails because the CLI isn't authenticated ends the same clean
way instead of hanging or throwing a raw error:

```
PROBE-RESULT: AUTH-UNAVAILABLE (<first line of the CLI's error>)
```

Otherwise each probe prints its finding — `YES` / `NO` / `PARTIAL` /
`AMBIGUOUS` / `WORKED` / `NONE` / `STREAMS` / `BUFFERED` depending on the
probe — with the concrete evidence (raw usage line, CLI reply, `git log`
output, or log byte-size samples) that produced it, on a single
`PROBE-RESULT:` line. `probe-stream-buffering.sh` and `probe-hermes.sh` are
the two exceptions to "a single line": the former checks two CLIs (codex,
then claude) in one run and prints one `PROBE-RESULT: <engine> ...` line
per engine; the latter checks two shapes (review, then implement) in one
run and prints one `PROBE-RESULT: <shape> ...` line per shape. All six exit
0 regardless of outcome; a probe's job is to report a finding, not to pass
or fail.

**Containment caveat:** the claude probes (`probe-claude-implement.sh`,
`probe-claude-tick.sh`) set cwd to a scratch repo, but containment is
instruction-level, not enforced — review the probe's aftermath (`git
status` in unexpected places) before trusting results.
