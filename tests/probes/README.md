# Manual probes

Six of these scripts answer open questions about the real `codex`, `agy`,
`claude`, and `hermes` CLIs that stub-based tests can't settle, because the stubs
*are* the answer to those questions by construction. They are **manual,
operator-run tools — never part of the automated suite.**

The seventh, `probe-t027-parent-red.sh`, is a different animal that lands here
for the same reason: it answers a question the suite structurally cannot. It
contacts no CLI and costs nothing. See "The probe that is not a real-engine
probe" below — including the one convention it deliberately breaks.

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
| `probe-claude-tick.sh` | With `--allowedTools Bash` added (F8 fix, on top of `--permission-mode acceptEdits`), does headless claude actually EXECUTE `orchid` verbs by absolute binary path — real command output, not just a hallucinated `ORCHID-ACTION:` marker line with nothing behind it? | **Real quota, one round trip.** Asks claude to run `<abs>/bin/orchid version` and `<abs>/bin/orchid config list` in a scratch repo, echo the marker for each, and checks the transcript for the real output of both. Neither needle is ever handed to the model: the prompt carries only a generic hint of each command's shape, and the greps look for this checkout's own `orchid version` line and for a per-run token the probe seeds into the scratch repo's `orchid.config` as `integration_branch`. See "Evidence has to be independent of the prompt" below. |
| `probe-stream-buffering.sh` | v1-m3 log-streaming fix: adapters now `tee` each CLI's stdout to the job log as it runs (`stdout="$(cli ... 2>err \| tee /dev/stderr)"`). That idiom proves bash's own plumbing doesn't buffer — whether the real `codex`/`claude` binaries buffer THEIR OWN stdout internally until the whole reply is ready (which would still leave the job log jumping from 0 to full size in one shot, right at exit) is a separate, unverified question. | **Real quota, one small round trip each.** Runs a "count to 5, one number per line" prompt through the exact adapter pipeline shape for codex and (separately) claude, sampling a scratch log's byte size once a second while each CLI runs. One `PROBE-RESULT:` line per engine: `STREAMS` (log grew before exit) or `BUFFERED` (log stayed empty until exit, then jumped). |
| `probe-hermes.sh` | v1-m4 Task 6: (1) does `hermes --safe-mode -t clarify -z "<prompt>"` — the exact invocation `plugins/engines/hermes/run` uses for review/critique — still return the plain VERDICT/REASON contract text against the real CLI? (2) `hermes` has no `implement` path yet (flag research found no confinement flag; see `docs/engines/hermes.md`) — does a RELATIVE-path file write from `hermes --safe-mode -t file -z ...`, cwd-scoped to a scratch dir, land inside that scratch dir? (Deliberately does NOT test the absolute-path escape case for real — a `YES`/`PARTIAL` here narrows the open question, it does not close it.) | **Real quota, two small round trips.** One review-shaped reply, one short one-shot file-creation prompt in a scratch dir. Two `PROBE-RESULT:` lines, prefixed `review-shaped`/`implement-shaped`. |

## The probe that is not a real-engine probe

`probe-t027-parent-red.sh` — **free; no CLI, no quota, no network.**

> Which of the behaviours T027's tests describe as newly fixed were actually
> broken at the parent commit?

Usage: `bash tests/probes/probe-t027-parent-red.sh <parent-ref>` (T027's
recorded `base_sha`; never defaulted).

It materialises the parent commit's whole tree with `git archive`, drives the
same seeded manifests through the parent's `bin/orchid` and this checkout's,
and classifies each behaviour as `NEW-FIX`, `PRE-EXISTING`, `REGRESSED` or
`UNFIXED` from the observed pair. Each row also carries the classification
T027's own narrative claims for it, so the run checks the *claims*, not just
the code — which is the whole reason it exists: an F41 case had been written
up as a newly fixed shape that the parent already handled, and no amount of
running the suite could ever have caught that, because the assertion passes on
both trees.

**It breaks two of this directory's conventions, deliberately:**

- **It exits non-zero** when a row is not what T027 claims. The six engine
  probes always exit 0 because a finding about someone else's CLI is not a
  pass or a fail; this one is checking a claim made *in this repository*, and
  a wrong claim is a defect.
- **It takes a required argument.** A guessed parent would go silently vacuous
  the moment this work merged — the commit it picked would already contain the
  fix, every `NEW-FIX` row would flip to `PRE-EXISTING`, and the flip would say
  nothing about the code. So the ref is passed in and validated (must be an
  ancestor of `HEAD`; its copies of the changed files must actually differ from
  `HEAD`'s), and pointing it at the candidate itself aborts rather than
  printing a page of `PRE-EXISTING`.

It is **not** a regression test and must not be wired into `tests/run.sh`: it
is only meaningful while the parent it names is still the parent.

**Quota warning:** `probe-agy-stdin.sh`, `probe-claude-implement.sh`,
`probe-claude-tick.sh`, `probe-stream-buffering.sh`, and `probe-hermes.sh`
call the real, billed CLIs (`probe-stream-buffering.sh` calls two of them,
codex and claude, in a single run). Don't loop them, don't wire them into
CI, and don't run them more than needed to answer the question. Treat
`probe-claude-implement.sh` in particular as the most expensive of the
six — it drives a full implement-style agentic turn, not a one-line reply.

## Evidence has to be independent of the prompt

A probe that asks a model to run a command and then checks the reply is only
worth its quota if the thing it checks for is something the model could not
have produced *without* running the command. `probe-claude-tick.sh` broke that
rule on one half and it went unnoticed for two milestones: the prompt said
"its output looks like `orchid 1.0.0-beta.1`" and the probe then grepped the
reply for `orchid 1.0.0-beta.1`, so an engine echoing the prompt back scored
that half for free. Only the second half — the config check — still
discriminated, and even it looked for the literal key name
`integration_branch`, which an engine can guess without running anything.

Both halves are now independent of the prompt:

- The prompt describes only the **shape** of each command's output ("one short
  line naming the tool and its version"; "a table of configuration keys and
  their effective values"), never a value.
- The version needle is this checkout's real `orchid version` output, read at
  probe start (never hard-coded — a hard-coded one silently rotted to the
  long-dead `1.0.0-m2` across two version bumps).
- The config needle is a **per-run token** the probe writes into the scratch
  repo's own `orchid.config` as `integration_branch`. Nothing can guess it;
  only reading it back out of that repo prints it. That last part is the
  bound worth knowing: the token is in a file, so an engine that reads the
  file rather than running `orchid config list` would print it too. Narrowing
  the needle to the tab-separated three-column line `config list` actually
  emits would close that, at the price of a `NO` for every cooperative engine
  that reformats the table — a false negative on a billed run, bought against
  a shortcut nothing takes when it was told to run the command. The version
  needle has no such shortcut (nothing in the scratch repo carries this
  checkout's version line), and a `YES` requires both halves.
- Both needles are checked for reachability in this checkout *before* any
  quota is spent, so a probe that has become unsatisfiable reports
  `ENV-UNAVAILABLE` rather than a confident `NO` about the engine.

That rule is the one part of this directory that **is** covered by the
automated suite, in `tests/test_probe_evidence.sh` (`bash
tests/test_probe_evidence.sh`, and picked up by `tests/run.sh` like any other
`test_*.sh`). It runs `probe-claude-tick.sh` three times against stub `claude`
binaries on a PATH where the stub is the only one there is — an engine that
echoes the prompt back, an engine that invents a plausible version line and
config table, and an engine that honestly executes both verbs — and asserts
that the first two are not scored `YES` while the third is. No engine is
contacted and no quota is spent; the probe itself stays manual, as below.

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
bash tests/probes/probe-t027-parent-red.sh <parent-ref>
```

Each of the six engine probes guards on `command -v <cli>` first and prints
exactly one line on success or absence:

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
0 regardless of outcome; an engine probe's job is to report a finding, not to
pass or fail. `probe-t027-parent-red.sh` is the exception on both counts — one
`PROBE-RESULT:` line per behaviour plus a `SUMMARY` line, and a non-zero exit
when a behaviour is not what T027 claims (see its own section above).

**Containment caveat:** the claude probes (`probe-claude-implement.sh`,
`probe-claude-tick.sh`) set cwd to a scratch repo, but containment is
instruction-level, not enforced — review the probe's aftermath (`git
status` in unexpected places) before trusting results.
