# Known-flaky assertions

This is orchid's own known-flaky register: the file `flaky.quarantine` names
(default `tests/QUARANTINE.md`, see [docs/configuration.md](../docs/configuration.md)).
When a verification fails, the driver reads it, and a failing line that matches
an entry here is classified `flaky` rather than `candidate` — it costs
`infra_failures` and it does **not** consume a rework attempt.

**It is currently empty of entries, on purpose.** That is not an oversight; see
"Why L020 is not in here" below.

## Format

One entry per line, beginning `FLAKE:` **at column 0**, then a **literal
substring** of the failing line, then optionally ` -- ` and why:

```
    FLAKE: <literal substring of the failing line> -- <why, and what would remove it>
```

Everything else in this file is prose the reader ignores, so this can stay the
document a human actually reads. The template above is indented by four spaces
precisely so that it is prose: an entry has to start at column 0, which is what
keeps a worked example from becoming a live signature.

Three things keep an entry from becoming a blanket amnesty, and they are worth
knowing before you write one:

- **Literal, never a pattern.** `FAIL: .* returned` matches a line containing
  those exact characters and nothing else. A regex here would waive every round
  forever.
- **At least 16 characters.** A short entry would match half the output of any
  suite.
- **It claims only the lines it matches.** There is no cascade. If your suite
  also prints an aggregate `3 tests failed`, that line is unexplained and the
  round is charged anyway.

And one thing keeps it honest: **a register the candidate changed is not an
authority on that candidate.** The moment a candidate's diff touches this file,
the whole route is gone for that round — including for entries it did not
write. An implementer cannot quarantine the assertion it is failing.

## Quarantining is the second-best answer

The first is to make the test deterministic — usually by making it **wait for
what it samples** instead of reading one instant and calling that a verdict.
An entry here stops an unreliable gate from charging for a race, but the gate is
still unreliable, and this file is what keeps that visible instead of silent.
Anything listed here is an open problem, not a resolved one.

## Why L020 is not in here

Lesson L020 is the reason this register exists. Eight engine-adapter cases — the
streaming and heartbeat liveness checks in each of `tests/test_engine_agy.sh`,
`test_engine_claude.sh`, `test_engine_codex.sh` and `test_engine_hermes.sh` —
sampled the job log at a fixed instant and asserted it had already moved. That
is a deadline for the writer, not the liveness property the cases mean, and on a
loaded machine it stranded eight tasks in r-002 and charged each one a rework
attempt for a scheduling artifact.

They were **de-flaked rather than quarantined**: `tests/helpers.sh`'s
`await_log_growth` / `await_log_heartbeat` poll for the condition under a bound,
and `stub_hold_until` holds the fixture's stub open until the sampler has
returned, so "while it was still running" is a fact the test controls rather
than a race it hopes to win. Both edges are pinned in `tests/test_engine_agy.sh`
(cases 12b and 12c), and `tests/test_helpers.sh` lints every engine-adapter file
for the old single-instant shape so it cannot come back one file at a time.

Listing them here would be actively harmful now: those assertions are the stall
detector's own evidence, and an entry would forgive a genuine streaming
regression as readily as a race.

## What keeps an empty register honest

A route nothing exercises is one nobody notices breaking, and this file
exercises nothing. So the route is proved against the entry that *would* go
here if the family ever came back. `tests/test_drive.sh` Part W builds its
fixture register from the literal string

```
job log must have grown WHILE the adapter was still running
```

and asserts, in the same breath, that this is still the message
`tests/test_engine_agy.sh` prints when that liveness case genuinely fails. If
the message is ever reworded, that assertion fails and whoever reworded it
learns that the worked example has to move with it. If the classifier ever
stops recognising a pre-candidate signature, it fails there too.

That is a proof about **recognition**, and deliberately not an amnesty: no line
in this file forgives anything in orchid's own runs. Adding one is still a
decision somebody has to make out loud — `tests/test_drive.sh` asserts this
file's live entry count is zero, so the entry and the change to that assertion
land in the same diff.
