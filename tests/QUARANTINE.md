# Known-flaky assertions

This is orchid's own known-flaky register: the file `flaky.quarantine` names
(default `tests/QUARANTINE.md`, see [docs/configuration.md](../docs/configuration.md)).
When a verification fails, the driver reads it, and a failing line that matches
an entry here is classified `flaky` rather than `candidate` — it costs
`infra_failures` and it does **not** consume a rework attempt.

It carries exactly **two causal signatures**, at the bottom of this file.
Together they name the two pre-T019 liveness-message families. A closed set of
exact companion-context records follows them for the successful fixture output
the old suite runner exposes when either assertion fails. Read "What the two
live signatures are, and what they cannot forgive" before adding another.

## Format

There are two record types. A causal entry begins `FLAKE:` **at column 0**,
then a **literal substring** of the failing line, then optionally ` -- ` and
why:

```
    FLAKE: <literal substring of the failing line> -- <why, and what would remove it>
```

A companion entry begins `FLAKE-CONTEXT:` at column 0, followed by one
**whole line** after surrounding whitespace is normalized:

```
    FLAKE-CONTEXT: <exact successful-fixture output line>
```

Context has no reason suffix because every byte after the colon is matched.
Explain a group in prose around it. Everything else in this file is prose the
reader ignores, so this can stay the document a human actually reads. The
templates above are indented by four spaces precisely so they are prose: a
record has to start at column 0.

Three things keep an entry from becoming a blanket amnesty, and they are worth
knowing before you write one:

- **Literal, never a pattern.** `FAIL: .* returned` matches a line containing
  those exact characters and nothing else. A regex here would waive every round
  forever.
- **At least 16 characters.** A short entry would match half the output of any
  suite.
- **It ordinarily claims only the lines the causal signature matches.**
  Companion context is the sole extension: it is inert unless a causal
  `FLAKE:` signature from this same trusted register matched this failed body
  first, and then it claims only listed whole lines. There is no child-block
  cascade. If the suite also prints `3 tests failed`, or one novel diagnostic,
  that line is unexplained and the round is charged anyway.

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

## What the two live signatures are, and what they cannot forgive

The live signatures below are not the de-flaked assertions. They are the common
literal prefixes of the **two pre-T019 single-instant families**: one sampled
ordinary stream growth, the other sampled heartbeat count. The common prefix
is intentional: it includes the longer Agy/Claude/Codex diagnostics and the
shorter Hermes diagnostics without broadening beyond those old families. The
de-flaked cases describe their bounded waits with different sentences, so
neither signature can match them — and `tests/test_drive.sh` asserts that in both
directions across all four adapter files.

That distinction is the whole design, and it makes the entries mean something
narrow and true: **an assertion that samples one instant is not evidence about
a candidate.** It cannot tell a stall from a scheduling artifact — that is what
it was measured doing eight times in one run — so its failure says nothing, and
charging a rework attempt for it is the injustice this register exists to stop.
The de-flaked assertion says something, is not listed, and charges.

The signatures are live rather than commented out because both shapes are still
reachable: a task branch cut before the de-flaking, a worktree that never
rebased, a revert, a merge that resurrects an old hunk. In every one of those
an old sentence can come back and this register catches it as `flaky` —
including branches cut before this file existed, through the fail-closed
integration fallback above — costing `infra_failures`, escalating to a human on
recurrence, and never consuming a rework attempt. They retire together: once
no branch in flight can still print either family, delete both signatures and
their companion records.

The companion records are the unique non-empty output lines emitted by the
four pre-T019 engine-adapter tests before and after their liveness assertions.
Those tests intentionally exercise alarming negative fixtures: malformed
replies, rate limits, rejected operations, oversize packs, and reviewer
findings. The current suite runner buffers a passing child and replaces that
chatter with one `OK`; the old runner printed the same buffer verbatim when a
later assertion failed. Without the companion set, the causal signature is
recognized but its deterministic successful setup remains “unknown”, so the
round still charges.

The set does not make those lines neutral globally. It becomes active only in
a body that also contains one of the two trusted historical signatures. The
same line without that cause charges, any longer line that merely contains it
charges, and any new line beside it charges. This preserves the mixed-failure
rule while making the actual carried-branch body classifiable.

Note what the timing rule does to these entries, and it is the right thing: the
candidate that introduced this file **cannot** be forgiven by it, because that
candidate changed it. It becomes an authority only for the candidates that come
after.

## What keeps the register honest

`tests/test_drive.sh` exercises the route's mechanics — literal matching, the
minimum length, the timing rule — against a fixture register it writes itself,
whose signature it reads out of `tests/test_engine_agy.sh` rather than typing.
It then parses **this** shipped file through the real parser and asserts that
its live signatures are exactly the two documented above; that each signature matches
its pre-T019 family, including Hermes's shorter form; that neither matches the
assertions that replaced it; and that no engine-adapter file in the tree
contains either sentence at all. The classifier test source may exercise those
sentences only by reading them from this register at runtime; a static tripwire
refuses either signature verbatim in `tests/test_drive.sh`, where a failing
self-check could otherwise print its own amnesty. So another entry cannot slip
in without somebody changing that count in the same diff and saying out loud
that a gate may now fail without failing.

<!-- Causal signatures below. Column 0, one per line; see "Format" above. -->

FLAKE: streaming stub: job log must have grown WHILE the adapter was still running -- L020: the PRE-T019 single-instant stream-growth family only, including Hermes's shorter diagnostic. It samples one instant and cannot tell a stall from a loaded machine, so its failure is not evidence about a candidate. The bounded-wait replacement prints a different sentence and is deliberately NOT covered. Delete both L020 lines once no branch in flight can still print either old family.
FLAKE: heartbeat stub: job log must gain at least one [hb line WHILE the adapter is still running -- L020: the PRE-T019 single-instant heartbeat-count family only, including Hermes's shorter diagnostic. It samples one instant and cannot tell a stall from a loaded machine, so its failure is not evidence about a candidate. The bounded-wait replacement prints a different sentence and is deliberately NOT covered. Delete both L020 lines once no branch in flight can still print either old family.

<!-- Closed companion context for the four pre-T019 engine-adapter files. -->

FLAKE-CONTEXT: - `git diff --check` passes.
FLAKE-CONTEXT: 429 usage limit exceeded
FLAKE-CONTEXT: FINDING: <low|medium|high>: <title>
FLAKE-CONTEXT: FINDING: bogus-severity: should be dropped
FLAKE-CONTEXT: FINDING: bogus: severity token is not one of the three
FLAKE-CONTEXT: FINDING: high: doctor claims inbound ok from an outbound-only fact
FLAKE-CONTEXT: FINDING: high: ignored for review
FLAKE-CONTEXT: FINDING: low: acceptance criteria too vague on T003
FLAKE-CONTEXT: FINDING: low: comment says v1-m3 but the change is v1-m4
FLAKE-CONTEXT: FINDING: medium:
FLAKE-CONTEXT: FINDING: medium: missing rollback plan for T002
FLAKE-CONTEXT: Implemented and committed.
FLAKE-CONTEXT: Implemented the caching layer end to end.
FLAKE-CONTEXT: Implemented the feature end to end.
FLAKE-CONTEXT: Implemented via plain codex.
FLAKE-CONTEXT: Implemented via stdin.
FLAKE-CONTEXT: Nothing to do here.
FLAKE-CONTEXT: ORCHID-ACTION: orchid task advance T001 implementing --reason tick
FLAKE-CONTEXT: REASON: tests pass and the diff is scoped tightly
FLAKE-CONTEXT: REASON: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
FLAKE-CONTEXT: Unauthorized: please login
FLAKE-CONTEXT: VERDICT: approve
FLAKE-CONTEXT: VERDICT: approve (draft, ignore)
FLAKE-CONTEXT: VERDICT: approve OR request-changes
FLAKE-CONTEXT: VERDICT: request-changes
FLAKE-CONTEXT: ```
FLAKE-CONTEXT: advancing the task
FLAKE-CONTEXT: looks fine
FLAKE-CONTEXT: nothing to do this tick
FLAKE-CONTEXT: nothing to report
FLAKE-CONTEXT: one more look...
FLAKE-CONTEXT: orchid/agy: diff.patch is 200000 bytes (> agy_max_bytes=100000); route to a worktree-capable reviewer
FLAKE-CONTEXT: orchid/agy: diff.patch is 500 bytes (> agy_max_bytes=100); route to a worktree-capable reviewer
FLAKE-CONTEXT: orchid/agy: malformed reply (no VERDICT line); raw output follows:
FLAKE-CONTEXT: orchid/agy: unsupported operation 'implement' (review|critique only)
FLAKE-CONTEXT: orchid/claude: unsupported operation 'research'
FLAKE-CONTEXT: orchid/codex-review: operation 'implement' not permitted for orchid/codex-review
FLAKE-CONTEXT: orchid/codex: unsupported operation 'research'
FLAKE-CONTEXT: orchid/hermes: diff.patch is 200000 bytes (> hermes_max_bytes=100000); route to a worktree-capable reviewer
FLAKE-CONTEXT: orchid/hermes: diff.patch is 500 bytes (> hermes_max_bytes=100); route to a worktree-capable reviewer
FLAKE-CONTEXT: orchid/hermes: malformed reply (no VERDICT line); raw output follows:
FLAKE-CONTEXT: orchid/hermes: unsupported operation 'bogus' (review|critique only -- see docs/engines/hermes.md)
FLAKE-CONTEXT: orchid/hermes: unsupported operation 'implement' (review|critique only -- see docs/engines/hermes.md)
FLAKE-CONTEXT: orchid/hermes: unsupported operation 'orchestrate' (review|critique only -- see docs/engines/hermes.md)
FLAKE-CONTEXT: orchid/hermes: unsupported operation 'research' (review|critique only -- see docs/engines/hermes.md)
FLAKE-CONTEXT: rambling, no reply contract
FLAKE-CONTEXT: reviewed the diff
FLAKE-CONTEXT: some rambling output with no reply contract
FLAKE-CONTEXT: thinking it over...
FLAKE-CONTEXT: tick complete
FLAKE-CONTEXT: working...
