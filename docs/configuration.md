# Configuration reference

*Generated-faithful: every key in [`lib/config-keys.txt`](../lib/config-keys.txt)
appears in the table below — a test
([`tests/test_docs.sh`](../tests/test_docs.sh)) asserts it, so this file can
never silently drift behind a key addition or removal.*

## Layers (highest wins)

```
ORCHID_* env vars  >  <repo>/orchid.config  >  ~/.orchid/config  >  defaults
```

All layers are `key=value`, one per line, **parsed, never sourced** — a
malicious or malformed `orchid.config`/`plugin.conf` cannot execute
anything. Per-user preferences (role bindings, model tiers, notify channel)
belong in `~/.orchid/config` — set once, apply to every repo. Per-repo facts
(integration branch, verify command, resources) belong in `<repo>/orchid.config`.
Env vars are for one-off overrides (`ORCHID_<KEY>`, uppercased, `.`/`-` both
map to `_` — e.g. `role.code-reviewer` overrides via `ORCHID_ROLE_CODE_REVIEWER`).

`<repo>` above is the **target repository** — the one being driven
(`$ORCHID_REPO`, else the current directory). The orchid installation's own
`orchid.config` (the one sitting next to `bin/orchid` in a checkout of orchid
itself) is **never** a layer, however plausible a global default it looks: a
value set there applies to orchid's own repository when orchid is the repo
being driven, and to nothing else. `~/.orchid/config` is the per-machine layer
that does apply everywhere. This has now wedged two runs through
`pack_budget_bytes` alone, so `orchid doctor` prints the resolved pack budget
and the layer it came from on every invocation.

`orchid config list` prints the **effective** value of every key together
with which layer won it — never guess why a setting applies. `orchid config
commit --reason "..."` is the safe way to land an `orchid.config` edit onto
the integration branch from a dirty or stale checkout (see
[troubleshooting.md](./troubleshooting.md)) — never hand-commit it from a
live checkout.

Unattended trust is intentionally **not a configuration key or layer**.
The supported interface for creating that operator-authored record is
`orchid trust unattended <repo> --reason <reason>`; it writes the JSON record
and non-reusable identity anchor under `~/.orchid/unattended-trust/`. No
`ORCHID_*` configuration override, tracked `orchid.config`, Git config, or
origin metadata can grant trust. (`HOME` selects the operator's machine-local
store in the normal Unix way.) Inspect the effective decision with `orchid
trust show <repo>`; remove it with `orchid trust revoke <repo>`.

## Key table

| Key | Default | Layer | Introduced |
|---|---|---|---|
| `integration_branch` | `orchid/integration` | repo | v0 |
| `verify` | *(none — required)* | repo | v0 |
| `concurrency` | `2` | repo or user | v0 (1) / v1-m2 (2 + scheduling) |
| `role.orchestrator` | `claude` (fallback chain default: `claude,codex`) | repo or user | v0 |
| `role.implementer` | `codex` (fallback chain default: `codex,claude`) | repo or user | v0 |
| `role.reviewer` | `agy` | repo or user | v0 |
| `role.arbiter` | `claude` (fallback chain default: `claude,codex`) | repo or user | v0 |
| `role.plan_critic` | `codex` (fallback chain default: `codex,claude`) | repo or user | v0 |
| `role.<id>.blocking` | `true` | repo or user | v1-m3 |
| `review.low` | `agy` | repo | v1-m2 |
| `review.medium` | `codex-review,agy` | repo | v1-m2 |
| `review.high` | `codex-review,agy` | repo | v1-m2 |
| `lock_break_s` | `900` | repo | v0 |
| `verb_lock_wait_s` | `10` | repo | v1-m2 |
| `stall_minutes` | `10` | repo | v0 |
| `cpu_stall_min_s` | `0` | repo | v1.1 |
| `timeout_minutes` | `60` | repo | v0 |
| `agy_max_bytes` | `100000` | repo or engine worktree | v0 |
| `hermes_max_bytes` | `100000` | repo or engine worktree | v1-m4 |
| `pack_budget_bytes` | `65536` | repo | v0 |
| `pack_diff_inline_max_bytes` | `262144` | repo | v1-m4 |
| `lessons_max_bytes` | `16384` | repo | v1-m3 |
| `spool_max_bytes` | `262144` | repo | v0 |
| `gc_older_than_s` | `86400` | repo | v0 |
| `infra_max` | `3` | repo | v0 |
| `rework_max` | `3` | repo | v1.1 |
| `handoff.pin_check` | `scripts/pin-formula.sh --check` | repo | v1.1 |
| `flaky.quarantine` | `tests/QUARANTINE.md` | repo | v1.1 |
| `model` | *(empty — engine's own default)* | repo or user | v0 |
| `effort` | `medium` | repo or user | v0 |
| `rate_limit_backoff_s` | `3600` | repo | v1-m2 |
| `engine_fail_threshold` | `3` | repo | v1-m2 |
| `pump_stale_s` | `900` | repo | v1-m2 |
| `pump_interval_s` | `240` | repo | v1-m4 |
| `arbiter_wait_s` | `14400` | repo | v1-m2 |
| `handoff_before_verify` | `off` | repo | v1.1 |
| `hook.after_plan_draft` | *(unbound — no handler)* | repo | v1-m3 |
| `hook.before_arbitration` | *(unbound)* | repo | v1-m3 |
| `hook.on_verify_fail` | *(unbound)* | repo | v1-m3 |
| `hook.before_merge` | *(unbound)* | repo | v1-m3 |
| `hook.on_blocker` | *(unbound)* | repo | v1-m3 |
| `hook_timeout_s` | `600` | repo | v1-m3 |
| `push_guard` | `true` | repo | v1-m4 |
| `status_page` | `runtime/status.html` | repo | v1-m4 |
| `notify.plugin` | `openclaw` | repo or user | v1-m4 |
| `notify.channel` | *(empty — no channel configured)* | repo or user | v1-m4 |
| `notify.to` | *(empty)* | repo or user | v1-m4 |
| `answer_allowlist` | *(empty — hardening off)* | repo | v1-m4 |
| `answer_expiry_s` | `86400` | repo | v1-m4 |
| `send_retry_max` | `5` | repo | v1-m4 |

## Notes on individual keys

- **`verify`** has no default on purpose: `orchid doctor` FAILs preflight
  until it's set (`orchid.config`), except `--greenfield` mode, which skips
  this check pre-scaffold (nothing to verify yet).
- **`stall_minutes`** is the kernel's one "no sign of life for long enough to
  call it stuck" bound, and it is read in three places. For a job that stamped
  a pid, `orchid jobs check` kills it and reports `stalled` after that long
  without a write to its log. For a job that was spawned but never stamped a
  pid (its launcher was killed in between), the same silence is what turns
  `prepared` — which the driver WAITS on, since something is producing output
  and a second engine in the same worktree is the worse outcome — into
  `unstamped`, which walks the escalation ladder once and is then reaped, log
  kept. And `runners/orchid-drive` passes it to `orchid jobs gc` as
  `--prepared-older-than-s`, the margin an unattended sweep needs so it never
  reaps a manifest out from under a launcher that is between its own `jobs
  prepare` and its spawn line. That margin is the DRIVER's, not the verb's: an
  operator running `orchid jobs gc --older-than-s 0` by hand gets zero.
- **`cpu_stall_min_s`** (default `0`: the check is OFF until an operator
  opts in) is the CPU floor of the stall check. `stall_minutes` catches a
  job that stops writing to its log; this catches the job that keeps writing
  and stops working — an engine still emitting heartbeats while its
  cumulative CPU time barely moves. With a floor above zero, `orchid jobs
  check` reads the `cpu` field of the heartbeat lines already in every job
  log and reports `stalled` (and kills the job, exactly as the log-mtime arm
  does) when the job burned less than this many CPU-seconds across the last
  `stall_minutes` of heartbeats. The check is opt-in because CPU alone
  cannot separate a dead engine from a healthy one blocked on a vendor API —
  the incident this check came from (F35) later retracted the signal after a
  working job was observed at ~9 CPU-seconds across 40 minutes — so set a
  floor above zero only if you know your engines' CPU profile. A heartbeat
  CPU counter that goes backwards (pid reuse) is treated as unknown and
  never kills.
- **`role.*`** — each value is a comma-separated failover chain, primary
  first (e.g. `role.implementer=codex,claude`). A fallback only ever
  activates once it has passed `orchid plugins test <engine> <role>` (the
  capability suite) — `orchid doctor` prints each role's resolved chain and
  labels non-default bindings `unverified` until that suite passes them. See
  the [README's any-engine-any-role matrix](../README.md#any-engine-any-role)
  for the full picture and a worked swap example.
- **`rework_max`** is the rework budget: the number of consumed `attempts` at
  which `orchid drive` stops retrying a failing task and blocks it for a
  human. It was a hardcoded `3` in the driver until v1.1. One task can be
  given a larger budget of its own with `orchid task retry <id> --reason
  "..." --attempts N` (recorded as `attempt_budget` in its frontmatter, and
  journaled); this key is the repo-wide default everything else falls back
  to. `infra_failures` never consume attempts, and neither does `orchid task
  reverify`.
- **`role.<id>.blocking=false`** marks a role (built-in or custom)
  non-blocking: a failed job for that role is journaled and the run
  continues rather than infra-failing (`docs/specs/operations.md`'s
  optionality-is-binding-policy rule — e.g. a future `role.researcher`).
- **`review.<tier>`** chains drive risk-tiered review routing (see
  `docs/specs/kernel.md`, Task lifecycle → Independence): `low` wants one
  engine-independent reviewer; `medium`/`high` want two (worktree-capable
  for depth + engine-independent for diversity).
- **`hook.<point>`** — an ordered, comma-separated list of plugin **names**
  (not qualified ids); append `:required` to a handler to make its failure
  block the edge (exit 15). No built-in defaults — an unbound point runs no
  handler at all.
- **`handoff_before_verify`** (`off` by default) names the OPERATOR HAND-OFF
  pause in [PROTOCOL.md](../PROTOCOL.md)'s THE TICK: the point, after an
  implementer's envelope reconciles and before `orchid verify` runs, where a
  candidate's execution-requiring mechanical work happens — applying a
  linter's own fix, re-pinning a release checksum, setting the mode bit on a
  newly added executable. Set it to `required` when your implementer is an
  engine profile that denies on the command *string* and so can perform none
  of those: a drive pass then stops at an `operator-handoff` boundary instead
  of verifying a candidate that was never going to pass and spending one of
  its rework rounds (`rework_max`, above) on the failure. It ships `off`, and turning it on is
  an operator decision landed through `orchid config commit --reason "..."`
  like any other config change — never a line a task's candidate adds to the
  live `orchid.config` of the run it is executing inside, which would switch a
  new driver gate on mid-run, for every remaining task, with no reason
  recorded. Perform the steps, commit them, then
  `orchid task handoff <id> --ack --reason "..."` — which advances
  `candidate_sha` to the commit the hand-off produced (so the record names the
  tree verification will run, not the one captured before it; a `HEAD` that
  does not descend from the current candidate, or does not sit on the task's
  branch, is refused rather than adopted) and binds the acknowledgement to
  that, so a resumed session or a second driver pass
  proceeds. Acknowledge LAST: a commit made after the ack leaves the tree ahead
  of what was acknowledged, which reopens the pause until you re-run the verb.
  The verb refuses an ack over a tree with uncommitted changes (naming them),
  over a tree whose state it could not read at all — a failed `git status` is
  reported as an uninspected tree, never as a clean one — and
  from any status but `testing`, where reviewers, an arbiter or a merge would
  already be holding the commit it wants to advance; `--clear` carries neither
  restriction.
  A rebase or a fresh rework round invalidates it exactly as
  INV-07 invalidates verify evidence. Any value
  other than `off` reads as `required`, so a typo can only route more work to
  a human, never less.
- **Verification-failure classification** has **no signature surface**, and
  that is the design rather than an omission. A repository cannot declare a
  *failure sentence* that forgives its own rounds: earlier versions of this
  feature offered one, and every signature list, directory-name list and
  whole-round exemption in them ended up forgiving something it never meant
  to. Four failures are waivable, and each is **proved against the world**
  rather than read out of the failure's wording:
  - **A package pin the repository's own freshness check reports stale**
    (`handoff.pin_check`, below).
  - **An executable this candidate left mode 644** — a file carrying a `#!`
    line with no execute permission, either one it *added* at that mode or one
    it *modified* that its `base_sha` recorded mode 755, which is what a
    rewrite that loses an exec bit looks like and is just as much the
    operator's `chmod`.
  - **Gitignored build state the worktree never received** — a directory that
    is present in the integration checkout, ignored by the repository's own
    rules, and absent from the worktree the verification ran in. `git worktree
    add` reproduces what git *tracks*, so `node_modules`, `vendor`, `.venv`
    and a symlink into a sibling checkout simply are not there (lesson L003).
  - **An assertion the repository already recorded as known-flaky**
    (`flaky.quarantine`, below).

  A run whose recorded exit status says it **stopped short** (`orchid verify`
  recorded exit 124, 137 or 143) is **reported and still charged**. It was a
  fifth verdict once, on the reading that the harness had reaped a pass which
  therefore never spoke about the candidate — and that reading was never
  proved. The same trailer is what a candidate that *hangs* until a timeout
  reaps it leaves, which is the very defect a `timeout` in a verification
  command line exists to catch, and what a suite that exits with the status
  deliberately leaves. Nothing in the log tells them apart, so it takes the
  uncertain reading: the attempt is charged, and the reason says the run
  stopped short so you are not left wondering why the log ends where it does.

  Each needs **two halves, and neither is worth anything alone**:
  - *The state, proved against the world* — `stat` for the mode bit, *running*
    the freshness check for the pin, comparing the two checkouts for the
    missing build state, and reading a register the candidate did not touch
    for the flaky one. No sentence in the failure can answer any of those
    questions, because `Permission denied`, `is not executable`, `checksum is
    stale` and `Cannot find module` are all things an ordinary defect prints.
  - *The attribution, from the failure to that artifact.* Per failing
    **line**, and in two steps, because one fault does not produce one failure
    — it produces a cascade. At least one failing line must **name that file**
    and report its fault (refuse to execute it, or call it stale); that is the
    proof the outstanding state blocked this run. Every failing line that then
    names the file is part of its cascade, whether or not it repeats the
    causal wording (`runners/orchid-drive must exist and be executable` is
    unmistakably that mode bit's failure). The path must use its exact
    repository-relative, `./`-relative, or worktree-root absolute spelling,
    with a **boundary** after it: an outstanding `bin/tool` does not collect a
    genuine `bin/tool-helper: Permission denied` or a distinct
    `fixtures/bin/tool: Permission denied` by suffix.

    For the missing build state the causal proof is the same shape asked of a
    different fact: a line reporting that something **could not be resolved**,
    where the thing it could not resolve **lives inside the absent
    directory**. `error Command "jest" not found` attributes to
    `mobile/node_modules` because `mobile/node_modules/.bin/jest` exists in the
    checkout that still has it — and attributes to nothing at all when the
    absent directory is a `.cache` with no `jest` in it, which is exactly the
    coincidence that made the first version of this arm dangerous. Only the
    diagnosed subject is looked up: `ENOENT: ... open 'src/config.json'` asks
    about `src/config.json`, so an unrelated package named `open` cannot earn a
    waiver. Its cascade
    claims a line that **names the directory**, or that names a path **inside**
    it — `ENOENT: ... open '.../node_modules/x'` cannot be about anything but
    the tree that is not there. That last part belongs to this arm alone,
    because its artifact is a *directory* that is entirely absent; where the
    artifact is a file, `bin/tool/child` is a different file and `bin/tool`
    does not collect it either. For the
    flaky register the signature *is* the proof, matched literally and
    claiming only the lines it matches.

  **Two of those proofs read a file out of your repository — the pin check and
  the flaky register — and a file is normally an authority on a candidate only
  while it is that candidate's own record of it.** Each is read only when it is
  *untouched* across `base_sha..candidate_sha`, *tracked in* `candidate_sha` as
  an ordinary file, and present in the verified worktree with the same bytes
  and the same mode that commit records. The first clause alone is not the
  question, because a diff of two commits cannot see the file that actually
  ran: an edit left unstaged, an edit staged and never committed, a file
  dropped in untracked, one deleted, and one whose mode has moved are all
  invisible to it, and every one of them is a way to hand the driver a file the
  implementer controls. Any of those, and any form of the question that cannot
  be *answered* — a missing or unresolvable `base_sha`/`candidate_sha` produces
  the same empty diff an untouched file does — closes the route and charges.

  The flaky register alone has a bootstrap path for tasks already in flight
  when the register is introduced. If both task commits resolve and both lack
  the configured path, Orchid may read the integration checkout's tracked copy
  while its index, bytes, and mode are clean at integration `HEAD`. A candidate
  addition no longer lacks the path, and a candidate deletion had it in the
  base, so neither can borrow that copy. An unanswerable history or dirty
  integration register closes the route and charges.

  Being outstanding is not being to blame — a repository whose sourced
  libraries carry `#!` lines at mode 644 (orchid is one, in every `lib/*.sh`)
  has that state outstanding on any candidate that adds one, and a stale pin
  is outstanding on the whole tree for as long as it is stale. Where the state
  is outstanding and the failure is not attributable to it, the attempt is
  **charged** and the reason says attribution was not established.

  **A round is never waived as a round.** It is waived only when *every*
  failing line in it has been individually claimed, which lets one round hold
  a mix *across classes*: a stale pin explaining six lines and an absent
  dependency tree explaining four together account for all of it and it is
  waived; one further unexplained line charges it and the reason quotes that
  line. The class the journal *names* is the one somebody must act on first —
  `handoff`, then `environment`, then `flaky` — and every contributing class
  is named in the reason regardless. Unprefixed resolution refusals such as
  `missing-helper: command not found`, `ENOENT`, and `Cannot find module` are
  failing lines too, as are unmistakable fatal diagnostics such as `panic:`,
  `RuntimeError:`, and `Segmentation fault`; an attributable fault beside one
  cannot hide it. Word boundaries keep progress identifiers such as
  `test_panic_recovery.sh` out. An unfamiliar non-empty line is not silently
  dropped: unless it is one of the classifier's explicit progress, success,
  or neutral NOT-TESTED records, it is uncertain, stays unattributed, and
  charges. Orchid's terminal standalone `OK` and both NOT-TESTED output forms are
  explicit members of that closed non-failure vocabulary. In particular,
  merely naming the same artifact cannot pull an unknown line into that
  artifact's cascade.
  A separate outstanding state contributes no
  attribution, but a waived reason still reports it when it is an operator
  action the candidate owes, such as a dropped 755 bit. What remains forgiven,
  and is bounded on purpose: a
  candidate that produces *no failing line of its own* while one of those
  states is outstanding is waived for that round — an operator clears the
  state in seconds, the round is charged to `infra_failures`, and it stops for
  a human if it recurs.

  A waived round re-enters rework with `--waive-attempt`, and requires a
  *fresh* implement envelope of its own: `--waive-attempt` leaves `attempts`
  where it is, so without that the re-dispatched round would resolve the
  previous round's envelope and re-verify a candidate that never moved. If a
  waived fault recurs — a second waived round on the same task — the pass
  stops at an operator boundary instead of re-dispatching, because a hand-off
  is a fault an operator clears and an identical retry cannot. That guard
  counts *this task's own* waived rounds rather than `infra_failures`, which
  also counts unrelated harness faults.
- **`handoff.pin_check`** — the package-pin freshness check the `handoff`
  route runs, as a command line relative to the verified tree
  (default `scripts/pin-formula.sh --check`). It is only invoked when the
  named script is a regular file there *and* states how to run it — directly
  when it is executable, otherwise under the interpreter its own `#!` line
  names, which is how orchid runs its own mode-644
  `scripts/pin-formula.sh`; a file that is neither executable nor names a
  working interpreter is never run, and that is no pin route. It is read as an
  authority only under the rule above: the candidate must not have changed it
  (a bug an implementer just introduced into a pinning script fails exactly
  like a stale pin, and that is the implementer's), the candidate must
  *record* it, and the worktree must still carry what was recorded.
  **A nonzero exit does not prove the pin stale** — a
  check that cannot find the formula, cannot find a git checkout, or trips
  over packaging metadata the candidate itself corrupted exits nonzero too,
  and re-pinning fixes none of those. The check must *say* something is stale
  and *name* a file the repository tracks; that file is what the waiver is
  attributed to, and a check that fails silently proves nothing and forgives
  nothing. `none` disables the route.
- **`flaky.quarantine`** — the known-flaky register the `flaky` route reads,
  relative to the verified tree (default `tests/QUARANTINE.md` — orchid ships
  one, carrying two entries for the two pre-T019 liveness-message families and
  the reasoning for them written down). One
  entry per line,
  `FLAKE: <literal substring of the failing line>` at **column 0** and
  optionally ` -- <why>`; everything else in the file is prose the route
  ignores (including an indented `FLAKE:`, so a register can document its own
  format without that example becoming a live signature), so it can be the
  document a human actually reads. **The safety here is not the
  path, it is the timing:** a register *this candidate changed* is not an
  authority on this candidate, so the moment a candidate touches the file the
  route is gone and the round charges — an implementer cannot quarantine the
  assertion it is failing, and cannot reach around that by leaving the entry
  uncommitted in the worktree either, because the register is read only under
  the authority rule above. The integration bootstrap described above reaches
  only branches whose base and candidate both predate the path. Three more
  things keep it narrow: a signature is
  matched
  **literally**, never as a pattern, so no entry can be written that
  matches everything; it must be at least 16 characters, so no entry can match
  everything by being short; and it claims **only** the lines it matches, with
  no cascade, so a suite that also prints an aggregate `3 tests failed` leaves
  that line unexplained and charges the round. `none` disables the route.
  Quarantining is the *second*-best answer — a case that reports without
  failing the suite is still an unresolved problem, and the register is what
  keeps it visible instead of silent. Making the test deterministic is the
  first.
- **`pack_diff_inline_max_bytes`** only relieves a `workspace_read`-capable
  reviewer/critic (the diff is swapped for a `diff.stat` summary, honestly
  recorded as omitted); an inline-only engine (agy, hermes) still gets the
  full diff subject to `pack_budget_bytes`'s ordinary overflow check — see
  [troubleshooting.md](./troubleshooting.md#pack-overflow).
- **`agy_max_bytes`** / **`hermes_max_bytes`** are the inline-reviewer
  byte ceilings above which those two adapters fail closed rather than
  invoking the vendor CLI at all (they have no worktree-read fallback) —
  see [docs/engines/agy.md](./engines/agy.md) and
  [docs/engines/hermes.md](./engines/hermes.md).
- **`push_guard`** governs whether `orchid init` installs a `.git/hooks/pre-push`
  guard that refuses pushing `task/*` branches or the integration branch
  (defense-in-depth; PROTOCOL.md instructs the model not to push, but that
  prompt policy is not OS/network containment).
  `ORCHID_ALLOW_PUSH=1` overrides it for one push.
- **`status_page`** is where `orchid status --html` writes its
  self-contained static page — never served, open the file directly.
- **`notify.plugin`** (default `openclaw`) selects WHICH `kind=notify`
  plugin `runners/orchid-pump`'s outbox drain launches — the value is a
  plugin **directory name** under `plugins/notify/` (e.g. `openclaw` or
  `hermes`), resolved the same way any other notify-plugin lookup is, never
  a manifest `id=`. Leaving it unset is a no-op (same `openclaw` default as
  before this key existed). An unresolvable value (missing plugin dir, or
  one whose entrypoint isn't executable) feeds the same failure/quarantine
  path a real send failure does — every queued message eventually
  quarantines with a clear reason rather than retrying forever silently.
- **`notify.channel`** / **`notify.to`** / **`answer_allowlist`** /
  **`answer_expiry_s`** / **`send_retry_max`** are per-PLUGIN keys (each
  plugin's own inner channel enum/target string, plus the shared
  inbox-hardening/retry knobs) — see
  [docs/engines/openclaw.md](./engines/openclaw.md) (the reference plugin,
  `notify.plugin` unset/`openclaw`) and
  [docs/engines/hermes.md](./engines/hermes.md) (`notify.plugin=hermes`) for
  the full setup and inbox-hardening story.
- `ORCHID_HB_INTERVAL_S` (the adapter heartbeat interval) is deliberately
  **not** a layered config key — it's an env-only override read directly by
  `lib/heartbeat.sh`, never through `config_get`, so it is intentionally
  absent from `lib/config-keys.txt` and from the table above.

See also: [README.md](../README.md), [quickstart.md](./quickstart.md),
[troubleshooting.md](./troubleshooting.md), `docs/specs/operations.md`
(the normative configuration section this file mirrors).
