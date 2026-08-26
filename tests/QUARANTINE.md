# Known-flaky assertions

This is orchid's own known-flaky register: the file `flaky.quarantine` names
(default `tests/QUARANTINE.md`, see [docs/configuration.md](../docs/configuration.md)).
When a verification fails, the driver reads it, and a failing line that matches
an entry here is classified `flaky` rather than `candidate` — it costs
`infra_failures` and it does **not** consume a rework attempt.

It carries exactly **one** live entry, at the bottom of this file. Read "What
the one live entry is, and what it cannot forgive" before adding a second.

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

**Nor can it reach around that by not committing.** A diff of two commits says
nothing about the file that is actually read, so the rule is the whole
question: this register is an authority only while it is untouched across
`base_sha..candidate_sha`, **tracked in `candidate_sha`**, and present in the
verified worktree with the **same bytes and mode that commit records**. An
entry left unstaged, an entry staged and never committed, an untracked
register dropped in where there was none, a deleted one, a chmod'd one — none
of those appears in that diff, and every one of them closes the route and
charges the round. If you add an entry here, commit it.

There is one bootstrap edge for branches already in flight when a register is
first introduced. If both the task's `base_sha` and `candidate_sha` resolve and
both lack this path, the driver may read the integration checkout's copy
instead — but only while that copy is tracked at integration `HEAD` and its
index, bytes, and mode are clean. A candidate that adds this path no longer
lacks it; one that deletes it had the path in its base. Neither can borrow the
integration copy, so this exception reaches old branches without reopening
self-quarantine.

## Quarantining is the second-best answer

The first is to make the test deterministic — usually by making it **wait for
what it samples** instead of reading one instant and calling that a verdict.
An entry here stops an unreliable gate from charging for a race, but the gate is
still unreliable, and this file is what keeps that visible instead of silent.
Anything listed here is an open problem, not a resolved one.

## L020, and why it is here in the shape it is

Lesson L020 is the reason this register exists. Eight engine-adapter cases — the
streaming and heartbeat liveness checks in each of `tests/test_engine_agy.sh`,
`test_engine_claude.sh`, `test_engine_codex.sh` and `test_engine_hermes.sh` —
sampled the job log at a fixed instant and asserted it had already moved. That
is a deadline for the writer, not the liveness property the cases mean, and on a
loaded machine it stranded eight tasks in r-002 and charged each one a rework
attempt for a scheduling artifact.

All eight were **de-flaked rather than quarantined**: `tests/helpers.sh`'s
`await_log_growth` / `await_log_heartbeat` poll for the condition under a bound,
and `stub_hold_until` holds the fixture's stub open until the sampler has
returned, so "while it was still running" is a fact the test controls rather
than a race it hopes to win. Every edge is pinned in `tests/test_engine_agy.sh`
(cases 12b, 12c and 12d), and `tests/test_helpers.sh` lints every
engine-adapter file for the old single-instant shape so it cannot come back one
file at a time.

**The de-flaked assertions are not quarantined and must never be.** They are
the stall detector's own evidence: an entry naming them would forgive a genuine
streaming regression as readily as a race.

## What the one live entry is, and what it cannot forgive

The live entry below is not the de-flaked assertion. It is the **pre-T019
single-instant assertion**, word for word, including the `(was 0 bytes at the
midpoint)` clause that only the old shape ever printed. The de-flaked case
prints a different sentence, so the entry cannot match it — and
`tests/test_drive.sh` asserts exactly that, in both directions, against the
files as they stand.

That distinction is the whole design, and it makes the entry mean something
narrow and true: **an assertion that samples one instant is not evidence about
a candidate.** It cannot tell a stall from a scheduling artifact — that is what
it was measured doing eight times in one run — so its failure says nothing, and
charging a rework attempt for it is the injustice this register exists to stop.
The de-flaked assertion says something, is not listed, and charges.

The entry is live rather than commented out because the shape is still
reachable: a task branch cut before the de-flaking, a worktree that never
rebased, a revert, a merge that resurrects the old hunk. In every one of those
the old sentence comes back and this register catches it as `flaky` — including
branches cut before this file existed, through the fail-closed integration
fallback above — costing `infra_failures`, escalating to a human on recurrence,
and never consuming a rework attempt. It will retire itself: once no branch in
flight can still print that sentence, delete the line.

Note what the timing rule does to this entry, and it is the right thing: the
candidate that introduced this file **cannot** be forgiven by it, because that
candidate changed it. It becomes an authority only for the candidates that come
after.

## What keeps the register honest

`tests/test_drive.sh` exercises the route's mechanics — literal matching, the
minimum length, the timing rule — against a fixture register it writes itself,
whose signature it reads out of `tests/test_engine_agy.sh` rather than typing.
It then parses **this** shipped file through the real parser and asserts that
its live entries are exactly the one documented above; that the entry does
match the pre-T019 line; that it does **not** match the assertion that replaced
it; and that no engine-adapter file in the tree contains the sentence at all.
So a second entry cannot slip in without somebody changing that count in the
same diff and saying out loud that a gate may now fail without failing.

<!-- Entries below. Column 0, one per line; see "Format" above. -->

FLAKE: job log must have grown WHILE the adapter was still running (was 0 bytes at the midpoint) -- L020: the PRE-T019 single-instant shape only. It samples one instant and cannot tell a stall from a loaded machine, so its failure is not evidence about a candidate; it stranded eight tasks in r-002. The de-flaked replacement prints a different sentence and is deliberately NOT covered. Delete this line once no branch in flight can still print it.
