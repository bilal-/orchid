# Orchid v0 Dogfood Notes

## Real-engine probe results (2026-07-27)

Run before the first real orchestration, answering the three open questions
the design flagged as unverified:

- **`codex exec review` range support** — `PARTIAL`. No two-endpoint
  `base..head` flag exists; it offers `--base <BRANCH>` (compares against
  current HEAD/worktree) and `--commit <SHA>` (single commit). **Impact:
  none** — the `engines/codex-review` path already falls back to plain
  `codex exec --sandbox read-only` with a range-pinned prompt, which is the
  correct choice given this finding. No code change needed.

- **`agy -p` stdin** — `NONE`. Neither `agy -p -` (piped) nor `agy -p < file`
  delivers the prompt; the `-` is consumed as a literal/flag-arg error.
  **Impact: none** — the `engines/agy` adapter already passes the full prompt
  as the single argv after `-p` (inline-diff mode), which the empirical work
  in the design phase established. stdin is simply not an option; the ARG_MAX
  ceiling on inline prompts remains the real bound, handled by `agy_max_bytes`
  + the codex-review fallback for oversized diffs. No code change needed.

- **`claude -p --permission-mode acceptEdits` commit capability** —
  `PARTIAL`. Claude creates the file but does **not** run `git commit`
  (acceptEdits does not auto-authorize the Bash/commit step in headless mode).
  **Impact: the `engines/claude` FALLBACK implementer cannot self-commit**,
  so an orchid task implemented by the claude fallback would produce an
  uncommitted worktree and orchid would see no candidate commit. The DEFAULT
  implementer is `codex` (sandbox `workspace-write`), which DOES commit, so
  the default triangle is unaffected. **Action:** logged for v1 — the claude
  adapter's implement path needs an explicit post-edit `git commit` step (or
  a permission-mode that authorizes it) before claude is a viable fallback
  implementer. Until then, claude fallback is review-only in practice.

## First real run

(pending — awaiting scope confirmation: which repo, which task)

## First real run — scratch repo (orchid-dogfood-1), task: add slugify

Existing-repo run: a `shout` util + `test.sh`; task R1 adds `slugify`.
Drove PROTOCOL by hand with real codex (implement) + agy (review). Findings:

### F1 (design bug, medium) — risk_tier `low` is unreachable
Task template defaults `risk_tier: medium`; `task set risk_tier` is
monotonic-upward-only, so `set risk_tier low` is refused as a downgrade.
Net: a task can NEVER be single-reviewer (`low`) — the whole low-risk
routing path is dead on arrival. Fix (v1): default the template to `low`,
OR let planning set the initial tier before the monotonic rule engages
(the rule should guard post-implementation changes, not the plan-time
assignment). Logged; dogfood proceeded at medium (dual review).

### F2 (adapter bug, HIGH — blocking) — codex invocation fails on real engine
`codex exec … "$prompt"` fails two ways the stub tests can't see:
  (a) when `$prompt` begins with `---` (task.md frontmatter), codex's clap
      parser treats it as a flag → "Usage: codex exec …" error, exit non-2
      captured as `failed`.
  (b) codex refuses a git worktree it doesn't trust: "Not inside a trusted
      directory and --skip-git-repo-check was not specified."
Root cause confirmed by minimal repro. FIX (both codex paths, implement +
review): pipe the prompt via stdin with `-` as the prompt arg AND add
`--skip-git-repo-check`:
  `printf '%s' "$prompt" | codex exec <flags> --skip-git-repo-check -`
Verified working in isolation (short prompt → clean `DONE`). This also
lifts the ARG_MAX ceiling on large prompts for free. The claude adapter
shares the leading-dash risk (same `"$prompt"` argv shape) — fix
symmetrically.

### Value proven
The stub-based suite (30+ files, all green) could not catch F1 or F2 —
both are real-engine/real-verb integration bugs surfaced only by driving
the actual pipeline. This is the dogfood's entire purpose, delivered.

### F3 (design refinement, HIGH) — engines can't commit inside a worktree sandbox
After F2's fix codex runs, edits files, but its `git commit` fails:
"index.lock: Operation not permitted — the linked Git index is outside the
writable sandbox." Root cause: orchid isolates tasks in git WORKTREES, whose
index/gitdir live under the MAIN repo's `.git/worktrees/<name>/` — OUTSIDE
the worktree dir that `--sandbox workspace-write` makes writable. Codex
edits land but can't be committed. (This is the same class as the probe's
claude-can't-commit finding — no engine commits reliably headless.)

**Fix (implemented): engines edit, the ADAPTER commits.** The adapter script
runs UNSANDBOXED, so after the engine CLI exits with edits, the adapter does
`git -C <worktree> add -A && git commit -m "<task>: <summary>"` itself and
captures the resulting sha into `commits[]`. This makes the implement
contract engine-agnostic (no engine needs commit capability — which the
probes showed is fragile/unavailable anyway) and resolves F3 + the claude
probe finding together. Empty-diff after an engine run → `status: failed`
(the engine produced nothing to commit).

## RESULT: first real run SUCCEEDED end-to-end
After F1/F2/F3 fixes, task T001 ran the full pipeline with REAL engines:
codex implemented `slugify` (lowercase + hyphenate + trim) and a test →
adapter committed b61f02b → `orchid verify` ran real `bash test.sh` (PASS,
candidate-bound evidence) → real `agy` reviewed the diff and APPROVED
(scope_complete) → arbitration approve → transactional `orchid merge`
re-ran the suite in a temp worktree and advanced orchid/integration →
`run accept` → run_status COMPLETE. The merged function works:
`slugify 'Hello, Shell World!'` => `hello-shell-world`. Journal carries the
full decision trail with kernel-derived actors. **v0 proven on real code.**

### F4 (reconcile bug, medium) — implement envelopes falsely quarantined
`jobs reconcile` cross-checks the envelope's candidate_sha against the
manifest; but for an IMPLEMENT op the candidate is an OUTPUT the engine
creates, so the manifest's pre-launch value (empty) never matches → the
implement envelope is quarantined `.reason-mismatch` (durable filing lost;
the walk only continued because candidate was set by hand). Fix: skip the
candidate_sha cross-check for `operation=implement` (base_sha still checked);
keep it for review/critique where candidate is an input. Fixed this commit.

### F5 (protocol gap, minor) — no way to launch the 2nd dual-review engine
`orchid-launch <task> <role> <op>` resolves engine from role only, so the
medium/high dual-review's second (session-independent codex) reviewer can't
be launched by hand — only the role's primary engine. Needs an engine
override arg or a `reviewer.secondary` binding. Logged for v1; the
engine-independent reviewer (agy) is the load-bearing one and ran fine.

### F1 — FIXED earlier this branch (template default risk_tier now `low`).

## v1-m1 dogfood: plugin machinery (2026-07-28)
Proved the plugin/role foundation with real `orchid plugins` commands on a
sandbox repo (no app — that's m2). All properties held:
- `plugins list` → the 5 built-ins as `builtin`.
- **Trust lifecycle:** a repo-local engine lists `DISABLED (untrusted)` →
  `plugins trust` → `trusted` → tamper a file → `DISABLED (digest mismatch)`.
  The INV-09 boundary works end-to-end on real commands.
- **Capability suite:** `plugins test agy implementer` → `FAIL` (agy lacks
  workspace_write); `plugins test agy reviewer` → pass. The gate that m2's
  failover will consume is correct.
- **Lockfile:** `plugins lock` → 3 records; `verify-lock` clean; a
  corrupt/merge-markered lock → loud nonzero (not false-clean).
No orchid bugs surfaced (unlike the v0 dogfood's 5) — the plugin layer is
pure deterministic bash with no real-engine integration surface, so the
stub-tested behavior matched real behavior. v1-m1 foundation is solid.
Note (ledgered m2): plugin_digest embeds absolute paths → lockfiles are
machine-specific; fine for single-operator v1.

## v1-m2 dogfood: core autonomy (2026-07-28)

Scratch repos (existing-repo `dogfood-m2` + empty-dir `dogfood-gf`), REAL
engines throughout (codex implement, agy + codex-review review, claude
orchestrate). All five m2 surfaces exercised end-to-end:

- **(a) Failover:** `plugins test claude implementer` (capsuite pass) →
  ledger-marked codex `rate_limited` → `jobs prepare` resolved **claude**
  (capsuite-gated fallback). `status`'s engines section explained why.
- **(b) Dual review (medium):** `jobs review-plan` produced 2
  engine-independent slots (agy, codex-review); the second slot launched via
  `orchid-launch … --engine codex-review` (F5 closed for real); sha-bound
  count gate held; disagreement arbitrated (approve — request-changes
  carried zero findings ≥ blocking_severity); transactional merge landed.
  Bonus: verify caught a genuine bug in the hand-written candidate first.
- **(c) Pump + headless tick:** stale lease → `orchid-pump` → REAL
  `claude -p` tick. After F8's fix the tick ran the full COMPLETION
  procedure autonomously: reconcile → status → `run advance accepting` →
  wrote acceptance evidence → `run accept` → `run_status: complete`, all
  epoch-fenced (1→2→3) and journaled. The autonomy loop is real.
- **(d) Greenfield:** `doctor --greenfield` + `init --greenfield` (root
  commit on unborn HEAD) → scaffold T001 (`scaffold: true`, structural
  verification_commands) implemented by REAL codex → verify → real agy
  approve → merge → `run accept` → complete.
- **(e) Review archetype:** R001 over the merged range: pending→reviewing
  (real agy approve with reason) → arbitrating → done; `orchid merge R001`
  refused (`outcome=report`), exactly as specified.

### F6 (adapter bug, HIGH — FIXED this branch) — agy headless replies die on tool use
Real `agy -p` review produced EMPTY stdout (rc 0): the model reached for a
command tool, headless print-mode auto-denied it, and agy emitted nothing →
adapter wrote `malformed` with zero diagnostics (job log empty — the
adapter swallowed stdout). The v0-era assumption ("print-mode auto-denial
is harmless for inline review") no longer holds when the model votes to use
a tool. Fix (commit `agy adapter forbids tool use…`): prompt now forbids
tools/commands ("judge from the diff text alone"), malformed replies dump
the raw reply into the job log, and the REASON line is captured into the
envelope summary. Re-launch after the fix: `ok approve` with rationale.

### F7 (UX trap, ledgered m3) — split-brain checkout after init
`orchid init` restores the user's branch; durable `.orchid/` lives only on
the integration branch. Task verbs happily build UNTRACKED state on the
wrong checkout (everything "works"), then the pump reads the absent
roadmap as "run complete" and refuses to tick. Operator rule (now
followed here): after init, work from the integration branch or a worktree
of it. m3: doctor/status should detect the split-brain checkout
(tasks/ present, roadmap absent) and say so; pump message should
distinguish "no roadmap in this checkout" from "run complete".

### F8 (adapter bug, HIGH — FIXED this branch) — claude tick couldn't run verbs
First real tick: `claude -p --permission-mode acceptEdits` authorizes file
edits, NOT Bash — claude explained which permissions it lacked and exited 0
(envelope ok, actions=0, nothing executed). Also bare `orchid` verbs are
not on PATH in dev checkouts. Fix (commit `claude tick allowlists Bash…`):
orchestrate branch passes `--allowedTools Bash` and the instruction block
mandates the absolute `$ORCHID_ROOT/bin/orchid` path. Second real tick
completed the run autonomously (see (c)).

### F9 (pre-existing since v0, cosmetic, ledgered m3) — fm_set duplicate keys
`fm_set` on a key whose template line has an empty value (`worktree:` — no
trailing space) APPENDS a new `key: value` line after `updated:` instead of
replacing, leaving both. Every reader matches `key: ` (with space/value) so
behavior is consistent; the file is just ugly and a first-match reader
would break. m3: fm_set should replace empty-valued keys in place.

### Smaller notes (m3 ledger)
- Tick envelopes report `actions=0` even when verbs ran — the model narrates
  instead of printing `ORCHID-ACTION:` lines; journal (kernel-derived) is
  the real audit trail, but the marker discipline needs reinforcement.
- The reviewing→arbitrating count gate counts a `malformed` envelope toward
  N (sha-bound but status-blind); arbitration handles it, still m3 should
  count only `status: ok` envelopes.
- Journal actor for headless-tick verbs reads `operator eN`; should derive
  the engine/role identity for tick sessions.
- codex-review's single-line verdict contract drops its reasoning (empty
  summary/findings on request-changes) — capture a reason like agy now does.
- The tick, sandbox-denied from /tmp, wrote its acceptance evidence to the
  repo root (untracked) — harmless, but a kernel-designated scratch path
  for tick-authored evidence files would be tidier.

### Verdict
Every m2 deliverable held up against real engines; the two HIGH findings
were both in tier-3 adapters (the deterministic kernel needed zero fixes),
were caught by exactly the layers built for it (malformed envelope, ledger,
epoch fencing), and were fixed and re-proven live. **v1-m2 autonomy is
real: a pump-launched, headless claude tick drove a run to
`run_status: complete` unattended.**

## v1-m3 dogfood: extensibility surface (2026-07-29)

Scratch project + sandbox/real HOME split; REAL engines for critique,
implement, review. All m3 surfaces exercised end-to-end:

- **Third-party author journey (the "under an hour" claim):** executed
  `docs/extending/first-engine.md`'s literal code blocks — skeleton passed
  `plugins conform` 7/7 on the first try, `plugins install` recorded signed
  provenance, a `kind=role` plugin (researcher) discovered via the
  descriptor search path, `plugins test` passed the pair, `plugins audit`
  reported coherently (digest unchanged, capsuite fresh). Minutes, not an
  hour.
- **Plan-critique loop (REAL codex):** round 1 returned four substantive
  findings (missing acceptance criteria/verification); the operator's fold
  introduced a task overlap that round 2 CAUGHT (high: T001/T002 scope
  collision) — the loop demonstrably improves plans. Bonus: a sandbox-HOME
  auth failure was classified `auth` in the envelope, exactly per contract.
- **Hooks live:** `hook.before_merge=<name>:required` — `orchid merge`
  refused with exit 15 and the verbatim gate message until the hook launch
  reconciled a sha-bound ok envelope; then merged. Exercised on two tasks.
- **Archetypes:** `test` archetype walked pending→done with real engines
  (tests-only lens); `migrate` template defaults verified
  (medium/medium/exclusive:true).
- **Lessons + rollover:** add/retire/list; `run new` archived r-001 →
  `runs/r-001/`, minted r-002 with a fresh journal naming the archive,
  carried ACTIVE lessons only (retired L001 correctly dropped); next-run
  `requirements import` worked immediately.
- **Fix-wave features self-verified live:** the new lease-freshness guard
  refused `run new` while this session's own lease was fresh (by-design
  friction; the parked m4 `run release-lease` verb is the affordance).
  The init worktree hint printed. The stale-checkout detector's fixture
  behavior was covered in-suite.

### Findings
- F-m3-1 (minor, ledgered m4): sandbox-HOME auth classification worked, but
  nothing in doctor warns that a HOME override hides engine credentials —
  a one-line doctor note would save the next operator the puzzle.
- F-m3-2 (observation): `plugins install` printing next-steps that name
  `plugins test <name> <role>` proved exactly right as UX — followed it
  verbatim during the walk.
- No orchid defects surfaced that the task-review/fix-wave cycle had not
  already caught; the m3 surface behaved as documented on first real use.

### Live-run cross-check (Pathway, running on main/m2 throughout)
m3 development coexisted with the live m2 run all day; the run's incidents
(stall false-positives, pack overflows, stale-checkout corruption, tick
pushes to origin) were folded into m3 as the log-streaming/heartbeat work,
worktree-read reviewer prototype, stale-checkout detection, and the
PROTOCOL no-push policy — the milestone was shaped by production evidence.

## v1-m4 Task 9 — Hermes live dogfood (scratch greeter repo, r-001/r-002)

Setup: fresh scratch repo, quickstart followed literally with the dev
checkout; `role.reviewer=hermes`, `role.implementer=codex` (r-001), then
`role.implementer=hermes,codex` (r-002). Both runs reached
`run_status: complete` — codex implemented, hermes reviewed real diffs
(T001 approve, T002 approve, both in the exact VERDICT/REASON contract),
arbitration/merge/accept clean, shipped behavior verified by hand.
PROBE-RESULT (review-shaped): YES — the adapter's exact invocation returns
the contract live. `plugins conform` 7/7; capsuite: hermes reviewer PASS,
hermes implementer FAIL (as designed — review-only adapter).

### F10 (docs bug, HIGH — quickstart fails as written) — ORCHID_EPOCH never taught
`orchid requirements import` (and 10 more verbs) call `epoch_require`, but
no doc in the new suite mentions `ORCHID_EPOCH` at all. The quickstart's
step-3 path dies with INV-02 "stale epoch 'unset'" on a fresh init: the
epoch file doesn't exist yet (current = 0) and `orchid run start` — the
only verb that prints the epoch — is two steps later. Operator remedy used
live: `export ORCHID_EPOCH=0` after init, re-export after every
`run start`/`run new`/tick (each mints a fresh epoch). Docs fix required
before release; also nit: quickstart says `reviews/plan-a1-plan_critic.json`,
real path is `.orchid/reviews/…`.

### F11 (adapter bug, medium, cosmetic-but-shipped) — codex commit subjects are garbage
Both live tasks merged with junk subjects taken verbatim from model
output: ``T001: ``` `` and ``T002: - `git diff --check` passes.``. The
codex adapter's commit-subject extraction grabs the first line of the
reply even when it's a markdown fence or a bullet. Wants a sanitize/
fallback (strip fences/list markers; fall back to the task title).

### F12 (observability gap, minor, ledgered) — capability fallback is silent in the run record
With `role.implementer=hermes,codex`, the launcher correctly skipped
hermes (no implement op) and ran codex — verified only by the job's pid
pointing at `plugins/engines/codex/run`. `orchid doctor` labels the chain,
but nothing in journal/status/request records says "hermes skipped:
capsuite/ops gate" for the actual dispatch. Fine for m4; wants a journal
note at launch time.

### F13 (environment note) — hermes refuses mktemp scratch dirs as "sensitive system path"
`probe-hermes.sh`'s implement-shaped half can't get a real answer from a
`mktemp -d` scratch (macOS `/var/folders/…`): hermes's file tools refuse
all writes there ("classified as a sensitive system path"), rc=0, no
marker. Manual retry from a `$HOME` scratch dir: the relative-path write
landed inside the scratch dir (PARTIAL per the probe's own definition —
necessary, not sufficient; absolute-path confinement still unsettled, so
the review-only stance stands).

### Observations (no fix needed)
- Plan critic (codex) took 4 rounds to approve a one-task plan; every
  finding was individually legitimate (bash-3.2 coverage, verification
  bypassing `./test.sh`, missing --shout assertion). Real quota cost of
  the honesty bar on trivial plans.
- `orchid jobs check` run between a job's exit and reconcile reports it
  `dead` even though its envelope is already in the spool; the next
  `jobs reconcile` harvests it fine. PROTOCOL's reconcile-first ordering
  exists precisely for this; expected, but easy to misread as a failure.
- m4's stale-checkout warning + scoped-exclude remedy and the r-001→r-002
  `run new` rollover both behaved exactly as designed under live use.

## v1-m4 Task 10 — hero demo (hermes-telegram live, OpenClaw AgentSkill registered)

Live evidence (scratch repo ~/orchid-m4t10-demo-orchid, notify.plugin=hermes,
notify.channel=telegram, answer_allowlist configured):
- Outbound leg PROVEN three times: `orchid notify` → strong nonce minted →
  outbox → pump drain → `hermes send -t telegram` → operator's phone, ~2s
  per message; drain fires even on a fresh lease (channel-send never waits
  for a tick), exactly as specified.
- Inbox hardening PROVEN on live questions: no-nonce, wrong-nonce, and
  unlisted-sender answers all refused with the exact contract messages;
  the consumed nonce (q-0) correctly refused a second answer.
- AgentSkill bundle registered into the local OpenClaw instance
  (`openclaw skills install <dir>` → enabled, ✓ Ready once `orchid` was
  resolvable to the gateway); OpenClaw answer leg untested — no chat
  channel paired yet (operator action).
- The same SKILL.md installed unmodified into hermes
  (~/.hermes/skills/orchestration/orchid/) — the single-file AgentSkill
  format is portable across both products; the operator's Telegram agent
  loaded it and, on the second blocker, constructed the exact correct
  `orchid answer <qid> <choice> --nonce <nonce>` command from a natural-
  language reply.

### F14 (UX gap, medium) — outbound-only channel is a dead-end reply experience
The operator's first instinct was to reply "proceed" in the same Telegram
chat. The receiving agent (hermes, pre-skill) had no idea what to do with
it. A notify channel whose agent can't answer is a confusing
half-experience — the docs now under-sell this. Wants: (a) docs/openclaw.md
+ hermes.md to say plainly that the answering agent must be skilled up or
replies dead-end; (b) future: richer sends (Telegram inline buttons) once
the receiving side can act on them.

### F15 (skill-config lesson, medium) — inline the repo/env in the command template
First skilled attempt failed: the agent ran bare `orchid answer …` from its
own cwd — "unknown question" — because the installed skill's configuration
expressed ORCHID_REPO/sender as prose. Fix that worked: the operator-config
section must carry the COMPLETE command template inline
(`ORCHID_REPO="…" ORCHID_ANSWER_SENDER=… /abs/path/orchid answer <qid>
<choice> --nonce <n>`). skills-external/openclaw-orchid/SKILL.md's
Configuration section should model exactly that shape.

### Status
q-0/q-1 answered (operator intent via controller relay after the above
failures); q-2-0518 remains OPEN for the operator's true phone round trip
with the hardened skill. Screenshots for the README hero panel: operator
capture pending.

## v1-m4 Task 12 — release rehearsal

Timed rehearsal PASSED on a clean-machine profile (fresh sandbox HOME, PATH
restricted to the real CLIs, fresh clone of the release branch), following
`docs/quickstart.md` ONLY, as written, using nothing but the commands the
quickstart itself shows: clone → install → doctor (14 ok) → init → plan
critique (approve round 1) → codex implement → agy review → merge → run
accepted, in **13m19s** (release-gate bar: 15 minutes).

### F16 (docs bug, HIGH — quickstart fails as written) — step 3 hits `orchid init` on a dirty tree
Following step 2's own instructions (add a `verify=` line / role bindings to
`orchid.config`) then step 3's `$EDITOR requirements.md` leaves both files
uncommitted; `orchid init` refuses outright ("working tree not clean —
commit or stash first — orchid never touches user work"). Fixed this
commit: `docs/quickstart.md` step 3 now commits `requirements.md` and
`orchid.config` on the operator's own branch before ever calling
`orchid init`.

### F17 (installer bug, medium) — install.sh mkdir'd the trust STORE FILE as a directory
Re-install exited 1 on any machine that had ever run `orchid plugins
trust`: `~/.orchid/trust` is the digest-pinned trust store FILE, and
install.sh ran `mkdir -p` on that path — `-p` tolerates an existing
directory but still fails on an existing file, and under `set -e` that
killed the whole re-install (the rehearsal hit exactly this). First fix
attempt missed it by testing only fresh scratch HOMEs (no trust store yet).
Fixed: install.sh creates only `~/.orchid/plugins/engines`; the trust file
is created on demand by the trust verbs and never pre-created (a directory
at that path would break every trust read). `tests/test_install.sh` now
guards the real shape: re-install with an existing trust store FILE exits 0
and leaves the file and its content intact.

### Greenfield quickstart — correctness pass (no timer)
Re-ran `docs/quickstart-greenfield.md` end to end for correctness (not
speed, per the roadmap's rehearsal scope): the unborn-HEAD root commit,
`orchid init --greenfield`'s empty-dir refusal, `orchid doctor
--greenfield`'s pre-scaffold check skipping, and the epoch-export note all
behave exactly as documented — green. Engine dispatch itself was not
re-exercised in this pass (the implement→review→merge pipeline has already
been proven live three times this milestone — Tasks 9 and 10 above, plus
this task's own existing-repo rehearsal); this pass targeted the
greenfield-specific bootstrap surface only.

### F11 observed live, this rehearsal
F11's fix (sanitizing the codex adapter's commit-subject extraction) held
up under a real run: the rehearsal task's merged commit carried a clean,
correctly truncated sentence subject, not the markdown-fence/bullet garbage
F11 originally reported.

### F18 (design fix, medium) — the notify reply command must be self-sufficient
Four consecutive phone attempts failed the same way: the Telegram-side
agent reliably executed the reply command from the message VERBATIM — and
that command, run from the agent's own cwd, died with "no such question"
because nothing bound the repo. Skill-side configuration (F15's inline
template) was not dependable either: gateway sessions did not load the
locally-installed skill's config section even after a restart, while the
same skill worked perfectly in a fresh CLI session (nonce-verified answer,
journaled). Fix: `orchid notify` now composes the reply instruction with
the repo binding inline — `reply: ORCHID_REPO="<repo>" orchid answer <qid>
<choice> --nonce <n>` — in both BLOCKERS.md and the outbox message, so the
command is complete from any cwd on any answering surface. The skill
remains useful (sender identity, guardrails) but is no longer load-bearing
for correctness.
CONFIRMED LIVE: with the complete command in the message, the operator's
Telegram reply worked on the first attempt — the hermes agent executed the
message's command verbatim (its consistent behavior across all five
rounds) and the demo repo journaled `blocker_resolved: proceed`. The
phone→orchid answer leg of the hero demo is now proven end-to-end over
hermes-telegram. (The suite flake seen once during this branch's gate —
test_engine_claude's midpoint-liveness assertion — passed 3/3 isolated and
is unrelated to this diff.)

## webBooks — Pathway to Peace enrichment run (external production repo, 2026-08-05 → 08)

Six tasks (schema change, three content-authoring tasks, a shared-visibility
fix, a bootstrap) driven to `done` on a real app repo, but only by heavy
operator hand-driving of the state machine: every one of the six needed manual
`task advance` / `arbitrate` / `merge` calls, and two needed conflict surgery.
Codex ran out of vendor credits at the start, so the whole run executed on
claude (implementer) + agy (reviewer). The findings below are what that
exposed.

### F19 (data loss, HIGH) — `orchid task set` with a multi-line value truncates the task file
`orchid task set T001 acceptance_criteria "line1<newline>line2"` fails with
`awk: newline in string` and leaves `.orchid/tasks/T001.md` **0 bytes**. The
whole record — status, attempts, candidate_sha, base_sha, worktree — is gone.
`orchid task show` then prints nothing and exits **0**, so it reads as "task
vanished" rather than "write rejected". Recovery is `git checkout <last plan
apply> -- .orchid/tasks/<id>.md`, which restores a pre-run copy and silently
resets the escalation counters (attempts 3 → 0). Suggested fix: validate the
value before writing, reject newlines with a clear error, and write via a
temp-file rename so a failed write can never truncate the record.

### F20 (failover gap, HIGH) — the per-task `engine` field pins a dead engine forever
Tasks record `engine:` at creation time and it is never re-resolved against the
role chain. This run created T001–T005 while `role.implementer` was codex;
rebinding the role to claude afterwards changed nothing, because each task
still said `engine: codex`. With codex out of credits the drive simply declined
to dispatch T004 — correctly, per the task record — while the pump kept waking
an orchestrator that had no legal transition. Eight consecutive wakeups, the
interval shrinking to ~31s, all no-ops. T006, created after the rebinding, ran
fine on claude: same run, same engines, different creation time. Suggested fix:
treat the task's `engine` as a *preference* and re-resolve through the role
chain at dispatch when the pinned engine is unavailable, or have `doctor` /
`status` flag tasks pinned to an engine the ledger shows as unavailable.

### F21 (config trap, HIGH — silent) — a gitignored `.orchid/` wedges the run in `planning`
`orchid plan apply` commits `.orchid/` to the integration branch. This repo
gitignored `.orchid/` as "local orchestration state", so the plain `git add`
refused the ignored path and plan apply exited 1 — printing only git's generic
"paths are ignored" hint, with no mention of orchid. `run_status` stayed
`planning`, and because the state machine walk is skipped outside `running`,
every subsequent tick was a legitimate, silent no-op. Suggested fix: a `doctor`
check for `git check-ignore .orchid` — it is a one-line test that would have
saved a long debugging session, and the failure mode is otherwise invisible.

### F22 (review-loop cost, medium) — re-review is demanded for a base-only change
After resolving a rebase conflict by hand, `orchid merge` detected the base had
moved (`199fec9 → bae4947`, the parent task's merge) and sent the task back for
re-review with `rebase_rereview_required` — even though `candidate_sha` was
byte-identical. The prior review envelopes were bound to the old base, so both
had to be re-run: for `risk_tier: medium` that is two more agy dispatches per
merge, ~90s each, on an unchanged tree. Legitimate as an invariant, expensive
in a dependency chain where every task's merge moves the next one's base.
Worth considering: carry review envelopes forward when the candidate tree hash
is unchanged and only the base advanced cleanly.

### F23 (pack budget, medium) — a regenerated artifact overflows the reviewer pack
`orchid-launch T003 reviewer review` died with `input_overflow —
non-truncatable inputs (74693 bytes) exceed pack budget (65536)`. The diff was
not large in human terms; it was one committed generated artifact
(`books.json`, the parse mirror the verify chain regenerates). Raising
`pack_budget_bytes` to 262144 fixed it. Generated-but-tracked artifacts are
common in app repos, and the reviewer does not need to read them. Worth
considering: a `pack_exclude` glob, or excluding paths the verify command is
known to regenerate.

### Observations (no fix proposed)
- **The orchestrator's own reporting was excellent.** It correctly refused to
  transition when no transition was legal, identified the pid-0 ghost job as a
  known false positive rather than escalating it, and named the pinned-engine
  problem itself before I found it. The tick logs were the most useful
  diagnostic surface in the run.
- **agy as reviewer worked well** once inside the pack budget: five review
  dispatches, all returning structured verdicts, and one genuine
  `request-changes` that caught a real scope question (it flagged a generated
  artifact and a provenance doc as out-of-scope — the task's acceptance
  criteria were at fault, not the work).
- **Claude implement dispatches remain edits-only** (`--permission-mode
  acceptEdits`, no `Bash`), so every task ended with "verification not run" and
  the operator had to run `verify-full.sh` and commit the regenerated artifact
  by hand. This is the single biggest source of manual work in the run.

## Run — wasiyyat-schedule-c (2026-08-09)

First exposure to a large, messy production repo: PHP 7.4 / MySQL, ~2,100
PHPUnit tests across three suites plus 65 Playwright specs, hand-vendored
runtime libraries, and several gitignored multi-GB data directories. 9 tasks,
driven by a Claude Code session executing PROTOCOL.md via `orchid drive`.

Findings F24–F31 live in **`dogfood-2026-08-09-wasiyyat-schedule-c.md`**.
Headlines:

- **F24/F25 (high)** — task worktrees cannot obtain gitignored dependencies
  (`vendor/`, data dirs, `node_modules/`), and the merge validator's worktree
  lives under `$TMPDIR` rather than beside the repo, so a bootstrap that works
  for task worktrees does not reach it. Suggests a `prepare=` step distinct
  from `verify=`, plus an exported `ORCHID_REPO_ROOT`.
- **F26 (high)** — a task that authors a schema migration cannot make its own
  tests pass; nothing applies the migration to the test database, and it
  presents as a task failure that consumes attempts.
- **F27/F28 (high)** — three byte-identical failure signatures each consumed an
  attempt, and `task retry` restores status but no attempt budget, so operator
  guidance gets exactly one shot. There is also no supported "operator fixed
  it, just re-verify" edge.
- **F29 (high)** — **F23 recurs**, and worse than F23 recorded: through
  `orchid drive` an `input_overflow` launch failure is entirely silent. 73
  passes produced 73 `pid: 0` manifests, no logs, no journal entries, engine
  still `ok`, and `jobs gc` cannot reap them. The escalation ladder never fires
  because a job that never started is not `dead`/`stalled`/`timeout`. Note this
  makes the "pid-0 ghost job is a known false positive" observation above
  unsafe at scale.
- **F30 (high)** — `depends_on: "T002,T003"` silently deadlocks: the scheduler
  splits on whitespace, so the comma-joined value is one unmatchable token. The
  rendered `waiting-deps (T002,T003)` is byte-identical to a correct
  two-dependency wait, which hid it for hours.
- **F31 (low/medium)** — stale-epoch handoff, a stale-checkout hint that does
  not clear the flag (needs `git reset`, not the printed command), raw bash
  errors on missing positionals, and a journal reference written before its log.

The plan critique loop was the run's highest-value component: seven rounds to a
clean approve, and it caught a real data-loss bug (an unscoped
`DELETE ... WHERE filename = ?` in a file outside the one under review).

### F24 (lifecycle gap, HIGH) — the pump outlives the run it was installed for
`orchid service install` registers a launchd agent, and nothing ever takes it
away. On the webBooks run the six tasks reached `done`, the work was reviewed,
merged and released — and the agent was still loaded, still firing every
`pump_interval_s`. Two consequences, both observed:

- **It burns model calls on a finished run.** Earlier in the same run the pump
  woke an orchestrator eight consecutive times against a state with no legal
  transition, and the interval was seen shrinking to ~31s. After the merge
  every wake is guaranteed to be a no-op, forever, because `run_status` never
  leaves `running` on its own — nothing advances a run to a terminal state when
  its last task is merged.
- **It survives the thing it points at.** Cleaning up meant removing the
  integration worktree. Had `orchid service uninstall` not been run *first*, the
  agent would have been left pointing at a deleted directory, waking on a
  schedule against nothing. That ordering is not written down anywhere and there
  is no guard for it.

Suggested: uninstall the service (or refuse to fire) when the run reaches a
terminal state; have `orchid merge` on the last task advance the run rather than
leaving it `running`; and make `git worktree remove` of the integration checkout
warn while a service for it is loaded.

### F25 (state leak, HIGH) — `.orchid/` follows the integration branch into the product's main
Fixing F21 by un-ignoring `.orchid/` has a consequence that only shows up at the
end. Durable state is committed on the integration branch; that branch merges
into the feature branch; the feature branch merges into `main`. webBooks' `main`
now tracks **14 orchestrator files** — `roadmap.md`, `journal.md`,
`BLOCKERS.md`, `baseline.md`, `plugins.lock` and review envelopes — none of
which belong in a shipped app repository. Nobody noticed during review because
the MR was large and the paths look like tooling.

So the two requirements are in direct tension: plan apply needs `.orchid/`
committable, and the product repo needs it absent. Both cannot hold with a
plain `git add` and a normal merge.

Suggested: have orchid stage its own state with `git add -f` so the target repo
can keep `.orchid/` ignored permanently — the state is still committed on the
integration branch, but a merge into main carries nothing, because the path is
ignored there. Failing that, `orchid merge` should exclude `.orchid/` from what
it hands back, or the docs should tell the operator to strip it before the final
merge.
