# Orchid v1-m2 — Core Autonomy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make autonomous multi-task runs real: an engine availability ledger, capability-gated role failover, the second-reviewer launch path (dogfood F5), risk-tiered dual review with kernel-enforced envelope counts, archetype-driven transitions + the `review` archetype, concurrency 2 with deterministic scheduling gates, per-verb transactional locking, the headless tick runner, the LLM-free pump, and greenfield mode.

**Architecture:** Per `docs/specs/kernel.md` (loop, scheduling rules, risk/independence, greenfield bootstrap), `docs/specs/plugins.md` (Engine availability & role failover; archetype meta-contract; request/envelope union), `docs/specs/roadmap.md` (v1-m2 scope). Built on merged v1-m1: the capsuite gate (`capsuite_passed`) is exactly what makes failover safe to ship. Kernel code never branches on a plugin's name (INV-05).

**Tech Stack:** bash 3.2, jq, git. Harness `tests/run.sh`.

**North star reminder:** the Pathway to Peace app (greenfield, under webBooks) is m2's grand dogfood — it runs AFTER this branch merges, driven by the machinery this plan builds. Task 11's in-branch dogfood proves the machinery on a small scratch project first.

## Global Constraints

- NO Claude/AI references anywhere (commits, files, PR). Post-commit `git log -1 --format=%B`; single-line subject, body-less; amend if violated.
- Branch `v1m2-autonomy` from main; never commit to main.
- Reviewers/fixers NEVER `git checkout/switch/reset/commit` in the shared checkout — scratch worktrees (`git worktree add`, removed after) or `git show` only.
- Tier rules hold: INV-01/06 statics stay green. `runners/` is tier 2 (may spawn); `libexec/` never spawns long-lived processes or engines. All durable writes atomic; bash 3.2 (no assoc arrays, no `${var,,}`); config/`plugin.conf`/`.role` files parsed as key=value, never sourced.
- Exit-code registry: 2 unknown verb, 3 illegal transition, 5 rebase_rereview_required, 12 input_overflow, 13 plugin validation failure; **add: 14 = no eligible engine available for a role**.
- Runtime files (ledger, lease, locks, capsuite results) are machine-local — never committed, never in the durable ownership table.
- Every new config key lands in `lib/config-keys.txt` + `orchid.config.example` in the same task that introduces it.

---

### Task 1: Engine availability ledger

**Files:** Create `lib/ledger.sh`, `tests/test_ledger.sh`. Modify `libexec/orchid-jobs` (reconcile), `libexec/orchid-status`, `lib/config-keys.txt`, `orchid.config.example`.

**Interfaces (lib/ledger.sh, sourced after common.sh):**
- Ledger file: `<repo>/.orchid/runtime/engines.json` — `{ "<engine>": {"status":"ok|rate_limited|failing", "rate_limited_until":<epoch-s|0>, "consecutive_failures":<n>, "last_status":"<envelope status>", "updated_at":<epoch-s>} }`. Atomic read-modify-write via `atomic_write`. Missing file = every engine available.
- `ledger_mark <repo> <engine> <envelope-status> [retry_after_s]` — `ok` → status ok, failures 0, rate_limited_until 0. `rate_limited` → rate_limited_until = now + (retry_after_s if a positive integer, else `rate_limit_backoff_s` config, default 3600). `failed|timeout|auth|malformed` → consecutive_failures++, status `failing` when count ≥ `engine_fail_threshold` (config, default 3).
- `ledger_available <repo> <engine>` — exit 0 iff (no record) OR (rate_limited_until ≤ now AND consecutive_failures < threshold). A past `rate_limited_until` is available again (window reopened) even before any ok.
- `ledger_show <repo>` — one line per engine: `<engine>\t<status>\t<detail>` (detail = `until <iso>` or `failures <n>` or `-`).
- `orchid jobs reconcile`: after accepting an envelope (durable filing), call `ledger_mark` with the MANIFEST's engine, the envelope's `status`, and the envelope's `.retry_after // empty`. Quarantined envelopes never touch the ledger (forgeable input).
- `orchid status`: new `== engines` section printing `ledger_show` output (after `== jobs`); empty ledger prints `(no engine events yet)`.

- [ ] **Step 1:** `tests/test_ledger.sh` RED — mark rate_limited with retry_after 60 → unavailable now, available after faking `rate_limited_until` past (rewrite the JSON field via jq to now-1); three consecutive `failed` marks → unavailable; one `ok` mark → available + failures reset; reconcile fixture: accepted envelope with status `rate_limited` and `retry_after: 120` updates the ledger from the manifest's engine (not the envelope's self-reported `engine`); quarantined mismatch envelope leaves ledger untouched; `orchid status` shows the engines section.
- [ ] **Step 2:** Implement. Full suite green.
- [ ] **Step 3:** ONE commit: `v1m2: engine availability ledger; reconcile marks, status shows`.

---

### Task 2: Failover-aware role resolution (capsuite-gated)

**Files:** Modify `lib/resolver.sh`, `libexec/orchid-jobs` (prepare), `libexec/orchid-task` (create), `libexec/orchid-doctor`, `orchid.config.example`, `tests/test_config_resolver.sh` (extend), `bin/orchid` (exit-14 note in dispatcher comment only if any). Create `tests/test_failover.sh`.

**Interfaces:**
- Role config values become comma-separated preference chains: `role.implementer=codex,claude`. Built-in default chains (in `resolve_role_chain`, replacing `resolve_role`'s scalar defaults): orchestrator `claude,codex`; implementer `codex,claude`; reviewer `agy` (routing handles tiers — Task 3); arbiter `claude,codex`; plan_critic `codex,claude`.
- `resolve_role_chain <repo> <role>` — prints the chain one engine per line (config value split on comma, or the default chain). Existing `resolve_role` MUST keep returning the first entry only (it already does `${v%%,*}` — extend its defaults to the chains' first elements, behavior unchanged).
- `resolve_role_available <repo> <role>` — walks the chain; prints the first engine that is (a) discovered (`resolve_engine_dir`), (b) role-eligible (`role_eligibility_reason`), (c) `ledger_available`, and (d) — for every entry AFTER the first — `capsuite_passed <engine> <role>` (the m1 gate: a fallback pair activates ONLY after passing the capability suite; the primary is the tested-default and needs no capsuite record). plan_critic additionally skips any chain entry equal to `resolve_role <repo> orchestrator`'s engine (the drafting engine never critiques its own plan). No survivor → return 14 with `orchid: no eligible engine available for role <role> (chain: ...)` on stderr, naming each entry's disqualifier.
- Callers must source, in order: common.sh, manifest.sh, roles.sh, resolver.sh, capsuite.sh, ledger.sh.
- `orchid jobs prepare` resolves the engine via `resolve_role_available` (was `resolve_role`) and propagates exit 14. The manifest keeps recording the resolved single engine.
- `orchid task create` seeds the template `engine` field via `resolve_role` (first-of-chain), NOT raw `config_get` — a comma chain in config must never land verbatim in frontmatter.
- `orchid doctor`: per-role line now prints the full chain with per-entry state: `role implementer -> codex (primary), claude (fallback: capsuite passed|capsuite UNVERIFIED — run orchid plugins test claude implementer)`. Missing primary is still a FAIL; an unverified fallback is a note, not a FAIL.

- [ ] **Step 1:** RED — `resolve_role_chain` splits config chains and supplies defaults; `resolve_role` still returns scalars (existing tests untouched); `resolve_role_available` picks primary when healthy; primary ledger-marked rate_limited + fallback WITH a passed capsuite record (write one via `capsuite_run` against a stub engine, or plant a result file whose `tested_at_marker` matches `plugin_digest`) → fallback returned; fallback WITHOUT capsuite record → exit 14 (never silently used); plan_critic never resolves to the orchestrator's engine; `jobs prepare` on a rate-limited-primary/no-fallback role → exit 14; `task create` writes `engine: codex` (not `codex,claude`) under a chain config; doctor shows chain lines.
- [ ] **Step 2:** Implement. Full suite green.
- [ ] **Step 3:** ONE commit: `v1m2: capsuite-gated failover resolution; prepare and doctor consume chains`.

---

### Task 3: Dual review — engine override (F5), routing, kernel envelope-count gate

**Files:** Create `lib/review.sh`, `tests/test_review_routing.sh`. Modify `libexec/orchid-jobs` (prepare `--engine`, review-plan subverb), `runners/orchid-launch` (`--engine` pass-through), `libexec/orchid-task` (implementer_engine_id capture; reviewing→arbitrating gate; blocking_severity derivation), `lib/pack.sh` (symbols.txt), `lib/config-keys.txt`, `orchid.config.example`.

**Interfaces:**
- `orchid jobs prepare <task> <role> <op> [--engine <name>]` — the override names ANY discovered engine; validated: discovered + `role_eligibility_reason <role> <dir>` passes (else die 14). Overridden engine is recorded in the manifest exactly like a resolved one (F5 closed: the second dual-review engine is now launchable). `runners/orchid-launch <task> <role> <op> [--engine <name>]` forwards the flag to prepare verbatim.
- `lib/review.sh` (source after resolver.sh/capsuite.sh/ledger.sh):
  - `review_required_count <risk_tier>` — low → 1; medium|high → 2; unknown → 2 (fail safe).
  - `review_implementer_engine <repo> <task>` — the task's `implementer_engine_id` frontmatter if set, else `resolve_role <repo> implementer`.
  - `review_routing <repo> <task>` — prints one line per required reviewer slot: `<slot>\t<engine>\t<engine-independent|session-independent>`. Slot 1 (all tiers): first entry of `resolve_role_chain reviewer` chain ++ `review.<tier>` config override (`review.low=`, `review.medium=`, `review.high=` — each a comma chain of engine names; default: low `agy`; medium/high `codex-review,agy`) that differs from the implementer engine and is discovered+eligible+available → labeled `engine-independent`; if only the implementer's engine is available → labeled `session-independent` (never silently). Slot 2 (medium/high only): the next distinct available engine from the tier chain (worktree-capable preferred: an engine whose manifest capabilities include `workspace_read` sorts first), labeled by the same independence comparison. Fewer distinct engines than slots → repeat the available engine with `session-independent` label (degraded-independence install), never zero slots.
  - Exposed as read-only tier-1 subverb: `orchid jobs review-plan <task>` printing the routing table (no epoch fence — pure read).
- `orchid task advance implementing→testing` additionally sets `implementer_engine_id` from the accepted implement envelope `reviews/<id>-a<attempt>-implementer.json`'s `.engine` (stripping a leading `orchid/`), where `<attempt>` = current `attempts`+1; file absent → leave the field alone (fixtures that hand-walk without envelopes keep working). Kernel-derived, single-writer preserved (the task verb writes it).
- `orchid task advance reviewing→arbitrating` gains a kernel gate: the count of files matching `reviews/<id>-a<attempt>-reviewer*.json` must be ≥ `review_required_count(risk_tier)`; else die `arbitrating requires N reconciled review envelope(s) for risk_tier <tier> (have M)`.
- `orchid task set risk_tier` (after the monotonic check) also derives `blocking_severity` per kernel.md: low → `high`; medium|high → `medium`; the derivation rides the same `risk_change` journal entry text. An explicit later `task set blocking_severity` still wins (no new mechanism — it's a plain settable key).
- `lib/pack.sh` review/critique packs gain `symbols.txt` (the inline blind-spot guard's data): the changed-file list plus every hunk header — `git -C <repo> diff --unified=0 <base>..<cand> | grep -E '^(\+\+\+|@@)'` — counted against the budget as truncatable (trim after context.md). Routing-upgrade judgment stays with the orchestrator (PROTOCOL, Task 10).

- [ ] **Step 1:** RED — prepare `--engine` records the override in the manifest, refuses an undiscovered engine and an ineligible one (agy for implementer) with 14; launch forwards `--engine`; `review_required_count` table; routing: low-tier task with codex implementer → single agy slot `engine-independent`; medium task → two slots, distinct engines, worktree-capable first; config where only the implementer's engine exists → slot labeled `session-independent`; implementer_engine_id set from a planted implement envelope on advance to testing; reviewing→arbitrating refused at medium with one reviewer envelope, passes with two (second via the `.2.json` counter suffix — plant both); risk_tier bump low→medium flips blocking_severity to medium; review pack contains symbols.txt with the hunk headers.
- [ ] **Step 2:** Implement. Full suite green (existing e2e lifecycle stays green: low-tier default → count gate needs 1, exactly what the walk already produces).
- [ ] **Step 3:** ONE commit: `v1m2: dual review routing, launch engine override, review-count gate`.

---

### Task 4: Archetype-driven transitions + `review` archetype

**Files:** Create `lib/archetype.sh`, `plugins/archetypes/review/plugin.conf`, `tests/test_archetype.sh`. Modify `plugins/archetypes/feature/plugin.conf`, `libexec/orchid-task` (legal() via archetype; create `--archetype`), `libexec/orchid-merge` (report-outcome refusal), `templates/task.md` (`__ARCHETYPE__`), `tests/test_task.sh` (extend).

**Interfaces:**
- `plugin.conf` (kind=archetype) gains: `outcome=code|report`, `transitions=<from:to,from:to,...>`. feature declares its current table verbatim: `outcome=code`, `transitions=pending:implementing,implementing:testing,testing:reviewing,testing:rework,reviewing:arbitrating,arbitrating:merging,arbitrating:rework,merging:done,merging:rework,merging:testing,rework:implementing`. review declares: `outcome=report`, `transitions=pending:reviewing,reviewing:arbitrating,arbitrating:done,arbitrating:rework,rework:reviewing`.
- `lib/archetype.sh` (source after common.sh, manifest.sh):
  - `archetype_dir <name>` — searches `$ORCHID_PLUGIN_PATH` roots → `~/.orchid/plugins/archetypes/<name>` → `$ORCHID_ROOT/plugins/archetypes/<name>`; duplicate id across roots → INV-10 error. Repo-local archetypes: NOT searched in m2 (data-only but workflow-shaping; ledgered for m3's trust treatment).
  - `archetype_transitions <name>` — prints `from:to` pairs one per line from the manifest; `archetype_outcome <name>` — `code|report` (missing → `code`).
  - `archetype_validate <name>` — exit 13 unless: manifest_validate passes; outcome ∈ {code, report}; every transition endpoint ∈ the kernel state set (pending implementing testing reviewing arbitrating merging rework done blocked); `outcome=code` implies the declared set contains `testing:reviewing` AND `reviewing:arbitrating` AND `merging:done` (no unreviewed/unverified path to a code-merging terminal); `outcome=report` implies NO transition mentions `merging` (a report archetype can never reach the merge verb's state); at least one transition ends in `done` (reachable terminal).
- `orchid task advance`: `legal()` becomes archetype-driven — read the task's `archetype` frontmatter, accept the transition iff it is in `archetype_transitions` (validated once per invocation via `archetype_validate`; invalid/unknown archetype → die 13) OR `to=blocked` (universal). `needs_reason` gains `arbitrating:done` (the report-accept edge is an arbitration outcome; journal kind `arbitration` — extend the existing `from=arbitrating → kind=arbitration` mapping which already covers it).
- `orchid task create <id> <title> [--archetype <name>]` — default `feature`; validates via `archetype_validate` before writing; template gains `__ARCHETYPE__` substitution.
- `orchid merge <id>`: first check — task's archetype outcome is `report` → die `merge refused: archetype '<name>' outcome=report never advances the integration branch (exit 3)`.
- Review-archetype walk (for tests + PROTOCOL): base_sha/candidate_sha set by `task set` (the range under audit — INV-04's `.orchid/` scan and INV-11's evidence gate live on edges review-archetype tasks never traverse, so they are naturally inert); reviewing → launch reviewer(s) per Task 3 routing; arbitrating→done `--reason` records the report acceptance.

- [ ] **Step 1:** RED — feature transitions exactly reproduce today's `legal()` (drive every previously-legal edge through a feature task and one previously-illegal edge → still exit 3); review task: pending→reviewing legal, pending→implementing exit 3, arbitrating→done requires `--reason` and journals kind arbitration; `orchid merge` on a review task refused; `archetype_validate` rejects: outcome=report with a `merging:*` transition; outcome=code missing `testing:reviewing`; transition naming an unknown state; `task create --archetype review` writes `archetype: review`; unknown archetype on create → 13.
- [ ] **Step 2:** Implement. Full suite green (every existing task fixture is archetype `feature` and must behave identically).
- [ ] **Step 3:** ONE commit: `v1m2: archetype-declared transitions; review archetype ships`.

---

### Task 5: Concurrency 2 + deterministic scheduling gates

**Files:** Create `lib/schedule.sh`, `tests/test_schedule.sh`, `tests/test_e2e_concurrency.sh`. Modify `libexec/orchid-task` (dispatch gate), `libexec/orchid-status` (predicates), `lib/config-keys.txt`, `orchid.config.example`.

**Interfaces:**
- Config: `concurrency` (default **2** — the v1 cap; operators can set 1 to get v0 behavior).
- `lib/schedule.sh`:
  - `schedule_active_tasks <repo>` — task ids whose status ∈ {implementing, testing, reviewing, arbitrating, merging}, one per line.
  - `schedule_dispatch_blockers <repo> <task>` — prints every blocking predicate for dispatching `<task>` now, one per line, empty + exit 0 when dispatchable: `concurrency-cap (<n>/<cap>)`; `exclusive-overlap (<active-id>)` — some active task has `exclusive: true`, or THIS task is exclusive and anything is active; `resource-conflict (<res>: <active-id>)` — non-empty intersection of comma-separated `resources` lists; `waiting-deps (<id> ...)` — moved here from orchid-status so the predicate set has one home.
- `orchid task advance pending→implementing` (and `rework→implementing`) enforces the gate kernel-side: any blocker → die exit 3 listing the predicates. (Deps stay orchestrator-supplied facts for worktree/base_sha; the kernel now refuses over-cap/conflicting dispatch outright.)
- `orchid status --explain`: pending/rework rows print `schedule_dispatch_blockers` output (or `ready-to-dispatch`); testing rows keep `awaiting-verify (or rebase-pending)`.
- `tests/test_e2e_concurrency.sh` — the m2 integration proof, stub engines, real verbs end to end: two independent tasks T1/T2 dispatched concurrently (both implementing at once — cap 2 honored); a third task refused with `concurrency-cap`; T1 merges first; T2's merge then exits 5 (`rebase_rereview_required`, base moved), T2 returns to testing with fresh SHAs and invalidated evidence, re-verify + re-review + re-arbitrate, second merge lands (INV-07 exercised through the REAL two-task flow, not a fixture); an `exclusive: true` task dispatches only once both are done; two tasks sharing `resources: db` never active together.
- [ ] **Step 1:** RED — unit: blockers for cap (cap=1 fixture), exclusive both directions, resource intersection, deps; advance refused with predicate text; status shows predicates. Then the e2e (expected to pass once the gate exists; failures are bugs to fix).
- [ ] **Step 2:** Implement. Full suite green, e2e 3× for flake check.
- [ ] **Step 3:** ONE commit: `v1m2: concurrency cap and scheduling predicates; two-task rebase-rereview proof`.

---

### Task 6: Per-verb transactional locking

**Files:** Modify `lib/common.sh`, `libexec/orchid-task`, `libexec/orchid-run` (advance/accept arms), `libexec/orchid-plan`, `libexec/orchid-requirements`, `libexec/orchid-jobs` (prepare/reconcile arms), `libexec/orchid-journal`, `libexec/orchid-notify`, `libexec/orchid-answer`. Create `tests/test_verb_lock.sh`.

**Interfaces:**
- kernel.md: "Per-verb transactional locking … is a Plan B deliverable, arriving alongside the tick loop." The tick loop arrives this milestone; with a pump-launched tick and an interactive session both alive, epoch fencing alone leaves a torn-write window between the fence check and the write.
- `lib/common.sh`:
  - `verb_lock_acquire <repo>` — mkdir `runtime/verb-lock` with owner.json (pid, pid_start, hostname); on contention retry every 0.2s up to `verb_lock_wait_s` (config, default 10); a held lock whose owner is verifiably dead (same three-way liveness test as `lock_acquire`) is broken immediately (verb transactions are sub-second; no age floor). Reentrant: when `ORCHID_VERB_LOCK_HELD=1` is already exported, return 0 without acquiring (nested verb calls — task advance → journal add — must not self-deadlock). On acquire, export `ORCHID_VERB_LOCK_HELD=1`.
  - `verb_lock_release <repo>` — removes the dir iff this process acquired it (guard on a shell flag set by acquire, NOT the env — a nested reentrant call must never release its parent's lock).
  - `verb_lock_guard <repo>` — convenience: acquire + `trap 'verb_lock_release <repo>' EXIT` composed with any existing trap.
- Wired at the top of every DURABLE-mutating arm: task create/set/advance/unblock/retry/infra-fail; run advance/accept (start/resume keep the RUN lock — different lock, unchanged); plan apply; requirements import; jobs prepare + reconcile; journal add; notify; answer. Read-only arms (show/list/check/gc/review-plan/status/config) never lock.
- Timeout → die `verb lock held by pid <p> — another verb is mid-transaction (waited <n>s)`.

- [ ] **Step 1:** RED — 30 parallel `orchid journal add` invocations land exactly 30 entries (today's read-modify-write loses some without the lock — demonstrate, then fix); nested advance→journal does not deadlock (reentrancy); dead-owner verb-lock broken immediately; second concurrent verb waits then succeeds (hold the lock in a background sleep-holder with a live pid, assert the waiter's wall time ≥ hold time); read-only verbs run lock-free while the lock is held by a live owner.
- [ ] **Step 2:** Implement. Full suite green (watch: e2e tests spawn verbs in sequence — no behavior change expected; INV-01 static must not flag the retry loop — `sleep 0.2` in a bounded loop is not a long-lived process, but keep it inside lib/ regardless).
- [ ] **Step 3:** ONE commit: `v1m2: per-verb transactional locking`.

---

### Task 7: Headless tick — `runners/orchid-tick` + `orchestrate` operation

**Files:** Create `runners/orchid-tick`, `lib/spawn.sh`, `tests/test_tick.sh`, `tests/probes/probe-claude-tick.sh`. Modify `runners/orchid-launch` (use lib/spawn.sh), `plugins/engines/claude/run`, `plugins/engines/codex/run`, `lib/envelope.sh`, `tests/probes/README.md`.

**Interfaces:**
- `lib/spawn.sh` — the env-hygiene logic extracted VERBATIM from orchid-launch into `spawn_child_env <plugin-dir>`: prints `NAME=value` lines for the allowlist base (PATH HOME USER LANG TERM TMPDIR, LC_*, ORCHID_*) plus the plugin's `permissions=` opt-ins. orchid-launch rewires to it (behavior identical; existing launch/env tests are the regression net).
- `lib/envelope.sh`: the ok-union gains `orchestrate` — `.operation == "orchestrate"` requires `.actions` (array of strings) and `.summary` (non-empty string).
- Adapters (claude, codex) gain an `operation=orchestrate` branch: prompt = the full text of `$ORCHID_ROOT/PROTOCOL.md` + a fixed instruction block: execute ONE tick of THE TICK procedure against `ORCHID_REPO` using only `orchid` verbs and `runners/orchid-launch`; print one line `ORCHID-ACTION: <command>` for every verb invocation made. The adapter greps `^ORCHID-ACTION: ` from the CLI transcript into the envelope `actions[]` (empty array when none — still `ok` if the CLI exited 0). `ORCHID_DRYRUN=1` short-circuits to a stub `ok` envelope with `actions: []`, `summary: "dryrun"` (same pattern as the existing ops). Headless flags follow each adapter's existing conventions (codex: stdin prompt + `--skip-git-repo-check`, sandbox `workspace-write`; claude: `-p` — the exact permission flags claude needs to run Bash verbs headless are UNVERIFIED (roadmap's "claude -p full tick"), which is what the probe is for).
- `runners/orchid-tick` (tier 2, effectful, synchronous):
  1. repo from `ORCHID_REPO`/`$PWD`; `run_status` `complete` → print + exit 0 (never spends quota on a finished run).
  2. `orchid run resume` (fences a fresh epoch; breaks stale locks per policy) — capture the printed epoch; export `ORCHID_EPOCH`, `ORCHID_REPO`.
  3. Engine = `resolve_role_available <repo> orchestrator` (exit 14 propagated: rate-limited primary + unverified fallback → tick refuses, pump retries later).
  4. Build the orchestrate request document under `runtime/requests/tick-<epoch>.json` (`request:1, job_id: "tick-e<epoch>", task:"run", operation:"orchestrate", role:"orchestrator", deadline_s` from `timeout_minutes`, `policy:"workspace-write"`, output → `runtime/logs/tick-e<epoch>.envelope.json`) — deliberately NOT via jobs prepare/spool (a tick is not a task job; its envelope must never enter reconcile's manifest-matching path).
  5. Spawn the adapter through the same hygiene as the launcher (`env -i` + `spawn_child_env`), stdin `/dev/null`, log `runtime/logs/tick-e<epoch>.log`, and WAIT (with `with_timeout deadline_s`).
  6. Envelope validate; status `rate_limited|failed|timeout|auth` → `ledger_mark` the orchestrator engine accordingly (the pump's next pass then fails over); `ok` → `ledger_mark ok`. Print `tick: <engine> <status> actions=<n>`.
- `tests/probes/probe-claude-tick.sh` — guarded like the existing probes: real `claude -p` asked to run `orchid status` in a scratch repo and print an ORCHID-ACTION line; PROBE-RESULT states whether headless verb execution works and with which flags. Documented in probes README; NOT in tests/run.sh.

- [ ] **Step 1:** RED — `tests/test_tick.sh` with a stub orchestrator engine (via `ORCHID_ENGINES_DIR`) whose orchestrate branch runs `orchid status` for real and writes a valid envelope with one action: tick exits 0, epoch was incremented, envelope logged + validated, ledger marks ok, `tick: ... actions=1` printed; stub variant emitting `rate_limited` → ledger shows the engine rate-limited and tick exits nonzero; run_status complete → no spawn (stub would create a marker file; assert absent); envelope union: an ok orchestrate envelope without `actions` is malformed.
- [ ] **Step 2:** Implement (spawn.sh refactor first — launch tests stay green — then tick). Full suite green.
- [ ] **Step 3:** ONE commit: `v1m2: headless tick runner and orchestrate operation`.

---

### Task 8: The pump — `runners/orchid-pump`

**Files:** Create `runners/orchid-pump`, `tests/test_pump.sh`. Modify `lib/config-keys.txt`, `orchid.config.example`.

**Interfaces:**
- `runners/orchid-pump` (tier 2; LLM-free — the pump itself NEVER builds prompts or reads envelopes beyond exit codes; one shot per invocation, cron/launchd packaging is v1-m4):
  1. repo from `ORCHID_REPO`/`$PWD`; not initialized → exit 0 `pump: not an orchid repo`.
  2. `run_status` `complete` (or roadmap absent) → exit 0 `pump: run complete`.
  3. Lease check: `runtime/lease.json` `refreshed_at` age < `pump_stale_s` (config, default 900 — the spec's >15 min) → exit 0 `pump: lease fresh (<age>s)`. Mutual exclusion is EXACTLY this staleness test (spec: "mutual exclusion via lease staleness, not flock") — a live orchestrator refreshes its lease every tick, so the pump only ever acts on an abandoned run. Missing lease file with run_status `running` → treated as stale (crashed before first refresh).
  4. Dry-check an orchestrator engine exists: `resolve_role_available <repo> orchestrator` — none → exit 0 with `pump: no capable orchestrator available (<reason>)` (cron-friendly: waiting for a window to reopen is normal, not an error).
  5. Exec `runners/orchid-tick` (foreground; the tick does its own `run resume`, engine pick, ledger marking). Pump's exit code = tick's.
- Config: `pump_stale_s` (default 900).

- [ ] **Step 1:** RED — fresh lease → no tick (stub engine marker absent), `lease fresh` printed; stale lease + healthy stub orchestrator → tick runs (marker present, epoch bumped); stale lease + primary rate-limited + capsuite-passed stub fallback → tick ran on the FALLBACK (marker names the engine); fallback lacking capsuite record → `no capable orchestrator`, exit 0, nothing spawned; run_status complete → nothing spawned; uninitialized dir → exit 0.
- [ ] **Step 2:** Implement. Full suite green.
- [ ] **Step 3:** ONE commit: `v1m2: LLM-free pump with lease-staleness gate`.

---

### Task 9: Greenfield mode

**Files:** Modify `libexec/orchid-doctor` (`--greenfield`), `libexec/orchid-init` (`--greenfield`), `docs/specs/kernel.md` (Bootstrap paragraph — root-commit owner corrected to init), `tests/test_init_doctor.sh` (extend). Create `tests/test_greenfield.sh`.

**Interfaces:**
- `orchid init --greenfield` — in a repo with NO commits (unborn HEAD: `git rev-parse -q --verify HEAD` fails): requires an empty-or-only-.git directory listing (never adopts a dirty pre-git pile silently — die listing strays), then creates the root commit itself: `git commit --allow-empty -m "orchid: root"` on the current (unborn) branch, then proceeds with the normal init flow (integration branch from the new HEAD, `.orchid/` skeleton, lockfile, commit). On a repo WITH commits, `--greenfield` is a no-op modifier. (kernel.md said "orchid-plan makes a root commit"; init is where the integration branch needs a HEAD, so init owns it — the spec edit in this task records that correction.)
- `orchid doctor --greenfield` — skips exactly the checks that cannot hold pre-scaffold: `verify command configured` (skipped with a note `greenfield: verify command deferred to scaffold task`) and `integration branch exists or creatable` accepts the unborn-HEAD case (will be creatable after init's root commit — print `ok (greenfield: root commit pending)`). Everything else (plugins, jq, roles) runs unchanged.
- Scaffold task convention (no new mechanism — document in the test + PROTOCOL Task 10): T001 carries `scaffold: true` (settable — not kernel-owned) with structural `verification_commands` (files exist, build exits 0), per kernel.md's scaffold-verification paragraph.
- `tests/test_greenfield.sh` — full walk in a scratch EMPTY repo with stub engines: `doctor --greenfield` passes; `init --greenfield` creates root commit + integration branch; T001 (`scaffold: true`, structural verify `test -f README.md`) walked pending→done through the real verbs (stub implementer creates README.md + commits); a second normal task builds on the scaffold. Also: init --greenfield refused in a dir with stray uncommitted files; plain `init` in an unborn-HEAD repo still dies with a hint to use `--greenfield`.

- [ ] **Step 1:** RED per the test file above.
- [ ] **Step 2:** Implement. Full suite green.
- [ ] **Step 3:** ONE commit: `v1m2: greenfield init and doctor`.

---

### Task 10: PROTOCOL v1 rewrite + spec/docs/version sync

**Files:** Modify `PROTOCOL.md`, `lib/common.sh` (`ORCHID_VERSION="1.0.0-m2"`), `docs/specs/roadmap.md`, `docs/specs/kernel.md`, `docs/specs/plugins.md`, `docs/specs/operations.md` (only where m2 delivered something described as future), `lib/config-keys.txt`, `orchid.config.example`, `skills/orchid/SKILL.md` (only if it hard-codes v0 policy text), `tests/test_install.sh` (PROTOCOL verb-existence lint keeps passing).

**Interfaces (PROTOCOL.md changes — keep the file's voice and verb-only discipline):**
- Preamble: "One active task" → the concurrency policy: up to `concurrency` (default 2) active tasks; dispatch is gated by the kernel's scheduling predicates (`orchid status --explain` names them); `testing` (synchronous verify) and `merging` remain one-at-a-time within a tick; at most one `orchid merge` per tick.
- Single-reviewer policy section → **risk-tiered review policy**: consult `orchid jobs review-plan <id>`; launch each slot via `runners/orchid-launch <id> reviewer review --engine <slot-engine>`; journal any `session-independent` slot BEFORE dispatch (unchanged rule, now per-slot); blind-spot guard: when `symbols.txt` names symbols referenced in files absent from the diff, upgrade to a worktree-capable reviewer slot and journal it.
- reviewing→arbitrating: note the kernel now enforces the envelope count per tier.
- Failover: launches can exit 14 (`no eligible engine`) — the task WAITS (window reopens; the ledger in `orchid status`'s engines section says why); a rate-limit pauses an engine, never work. The step-2 aspiration note ("marking an engine unavailable is not implemented") is DELETED — the ledger + reconcile close it; rewrite the escalation ladder's second occurrence to note the ledger records engine-level failures automatically via reconcile.
- New section **HEADLESS OPERATION**: the pump (`runners/orchid-pump`, cron-invoked or manual) launches `runners/orchid-tick` when the lease is stale; a tick executes THIS file once; interactive sessions and ticks exclude each other via lease staleness + epoch fencing; high-risk arbitration waits (bounded by `arbiter_wait_s`, config, default 14400) for the preferred arbiter engine before a fallback arbiter engine may decide — journal the wait/fallback either way. Greenfield: PLANNING notes `orchid init --greenfield` + the scaffold-task convention; review-archetype tasks walk pending→reviewing→arbitrating→done.
- Config keys new this milestone (verify complete): `concurrency`, `rate_limit_backoff_s`, `engine_fail_threshold`, `verb_lock_wait_s`, `pump_stale_s`, `arbiter_wait_s`, `review.low`, `review.medium`, `review.high`.
- Spec sync: roadmap.md marks v1-m2 SHIPPED (mirroring the m1 pattern) and moves the Pathway dogfood note to "post-m2, running"; kernel.md loop/scheduling text updated from "(v1: 2 + scheduling rules)" future-tense to shipped; plugins.md failover section marked SHIPPED with the ledger/pump/tick names; PROTOCOL discrepancy list updated (implementer_engine_id now populated by advance-to-testing; engine-unavailable now real).
- `orchid version` prints `1.0.0-m2`.

- [ ] **Step 1:** RED where testable — version string test; PROTOCOL verb-lint (every named verb/runner exists — now includes review-plan, orchid-tick, orchid-pump); grep-tests that the aspiration note is gone and config-keys.txt covers every key named in PROTOCOL/example config.
- [ ] **Step 2:** Write the docs + bump. Full suite green.
- [ ] **Step 3:** ONE commit: `v1m2: protocol v1, spec sync, version 1.0.0-m2`.

---

### Task 11: Whole-branch review + v1-m2 dogfood (CONTROLLER-EXECUTED)

**Files:** modify `docs/dogfood-notes.md`.

- [ ] **Step 1 (whole-branch review):** strongest model, full v1-m2 diff, Minor triage; fix wave; verdict.
- [ ] **Step 2 (machinery dogfood, stub-free where cheap):** in a scratch repo with REAL engines: (a) rate-limit simulation — mark codex rate-limited via a planted envelope, watch `jobs prepare` fail over to a capsuite-passed claude (run `orchid plugins test claude implementer` first) and `status` explain it; (b) dual review on a real medium-tier task — `jobs review-plan`, launch both slots (F5 path: `--engine codex-review`), kernel count gate holds; (c) pump/tick — stale the lease, run `runners/orchid-pump` with the REAL claude orchestrator for ONE tick on a trivial task (this is the "claude -p full tick" verification; run `tests/probes/probe-claude-tick.sh` first and record PROBE-RESULT); (d) greenfield — `init --greenfield` + scaffold task on a scratch dir; (e) a review-archetype task over a real diff.
- [ ] **Step 3:** Record findings in dogfood notes; fix blocking bugs via the fix loop; non-blocking → v1-m3 ledger. Commit notes; PR `v1m2-autonomy` → main. **Post-merge (separate run, not this branch):** kick off the Pathway to Peace greenfield run under webBooks — m2's grand dogfood.

---

## Self-review notes
- Roadmap m2 deliverables all mapped: pump (T8) + failover gateable on m1 capsuite (T2, gate in `resolve_role_available`), concurrency 2 with rebase/re-review rules (T5 — INV-07 exercised via real two-task flow), risk-tiered dual review (T3), greenfield mode (T9), review archetype (T4). Headless `orchid-tick` (kernel.md tree, roadmap requirement line) is T7. Per-verb locking "arriving alongside the tick loop" (kernel.md) is T6. Dogfood ledger: F5 closed (T3); PROTOCOL's aspirational engine-unavailable note closed (T1+T10); machine-specific lockfile paths stay ledgered (single-operator v1).
- Cross-task interface consistency: `resolve_role_available` (T2) consumed by prepare (T2), review routing (T3), tick (T7), pump (T8); `ledger_mark/ledger_available` (T1) consumed by T2/T7/T8; `review_required_count`/`review-plan` (T3) consumed by PROTOCOL (T10); exit 14 introduced in T2, honored in T3/T7/T8; `capsuite_passed` is m1 surface, unchanged.
- Back-compat: `resolve_role` behavior unchanged (chains split first-entry); feature archetype declares today's exact transition table (T4 asserts equivalence); default risk_tier low keeps the count gate at 1 for every existing fixture; concurrency default 2 only ADMITS more parallelism — existing serial walks stay legal; verb locks are reentrant and read-paths lock-free.
- Sequencing: T1→T2→T3 (ledger → failover → routing); T7→T8 (tick → pump); T4/T5/T6/T9 independent; T10 after all code tasks; T11 last.
