# Orchid v1-m3 — SDLC Suite & Custom Extensibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Open orchid's extension surface — kernel-owned hooks, custom role registration, the `refactor`/`test`/`migrate` archetypes, third-party plugin lifecycle UX (`install/update/remove/audit`) plus a distributable conformance kit — and pay down the v1-m2 dogfood ledger (split-brain checkout, fm_set duplicates, plan-critique launch gap, adapter fidelity, lock liveness).

**Scope addition, stated plainly:** structured cross-run **lessons** (`orchid lessons` + `run new` rollover) are kernel.md v1 deliverables never assigned to a milestone; m3 is the last feature-shaped milestone (m4 is packaging/docs), so they land here (Task 11) and the roadmap sync records that.

**Architecture:** Per `docs/specs/plugins.md` (Hooks; role plugin kind; lifecycle; conformance), `docs/specs/kernel.md` (lessons, decision matrix, memory injection), `docs/specs/roadmap.md` (v1-m3 scope), and the v1-m2 ledger in `docs/dogfood-notes.md`. Built on merged v1-m2. Kernel code never branches on a plugin's name (INV-05); hooks/roles/archetypes are declared data + launched executables, never sourced.

**Tech Stack:** bash 3.2, jq, git. Harness `tests/run.sh`.

## Global Constraints

- NO Claude/AI references anywhere (commits, files, PR). Post-commit `git log -1 --format=%B`; single-line subject, body-less; amend if violated.
- Branch `v1m3-sdlc`, worktree `/Users/bilal/workspace/personal/orchid-m3` — **the main checkout at `/Users/bilal/workspace/personal/orchid` serves a LIVE orchid run (the Pathway pump executes its runners/libexec directly); never touch it, never switch its branch, run all tests inside the worktree.**
- Reviewers/fixers NEVER `git checkout/switch/reset/commit` in the shared worktree — scratch worktrees or `git show` only.
- Tier rules hold (INV-01/06 statics green); durable writes atomic; bash 3.2; config/`plugin.conf`/`.role` parsed never sourced; repo-local plugins stay trust-gated (INV-09).
- Exit-code registry: 2 unknown verb, 3 illegal transition, 5 rebase_rereview_required, 12 input_overflow, 13 plugin validation failure, 14 no eligible engine; **add: 15 = hook handler failure (required hook)**.
- Every new config key lands in `lib/config-keys.txt` + `orchid.config.example` in the task that introduces it.
- Hook/lesson/plan artifacts are durable state → single-writer table entries updated in the docs-sync task; anything runtime-only stays machine-local.

---

### Task 1: m2-ledger kernel hardening sweep

**Files:** Modify `lib/frontmatter.sh`, `libexec/orchid-task`, `lib/schedule.sh`, `lib/common.sh`, `lib/ledger.sh`, `tests/helpers.sh`. Extend `tests/test_frontmatter.sh`, `tests/test_task.sh`, `tests/test_schedule.sh`, `tests/test_verb_lock.sh`, `tests/test_ledger.sh`.

**Interfaces (each item = one ledgered m2 finding):**
- `fm_set` (F9): replaces an EMPTY-valued frontmatter key line (`key:` with no value) in place instead of appending a duplicate; existing valued-line replacement unchanged; never touches body text after the closing `---`.
- Review-count gate (`orchid-task`, reviewing→arbitrating): counts only envelopes with `status == "ok"` (sha-binding kept); die message unchanged in shape.
- `tests/helpers.sh`: dies loudly when `$WORK` is unset/empty before any `cd`/`git` (the m2 stray-commit mishap).
- `verb_lock_acquire`: the self-verify-failure retry path counts against `tries` (bounded liveness); an empty lock dir whose `owner.json` never appears within `verb_lock_wait_s` is broken like a dead owner (crash-between-mkdir-and-claim window closed) — both journal-free (runtime only).
- `ledger_show`: sub-threshold `consecutive_failures > 0` prints `failures <n>` in the detail column even while status is still `ok`.
- `schedule_dispatch_blockers`: non-numeric `concurrency` config → `orchid_die "concurrency must be a positive integer (got '<v>')"`.
- `lib/manifest.sh` `_manifest_split_csv` empty-input bash-3.2 quirk (pre-existing, flagged in m2 Task 2): fixed so a manifest with NO `requires_binaries` key validates without fixture workarounds.

- [ ] **Step 1:** RED per item (duplicate-key file → fm_set replaces in place, one line per key after; waived-rework gate test extended with a planted `status:"failed"` envelope that must NOT count; helpers guard: run a test file with WORK= unset → dies before touching git; verb-lock: stress + planted never-claimed empty dir → waiter breaks it within budget; ledger_show shows `failures 1`; `concurrency=abc` → clean die; empty-CSV manifest validates).
- [ ] **Step 2:** Implement. Full suite green. — [ ] **Step 3:** ONE commit: `v1m3: kernel hardening from the m2 ledger`.

---

### Task 2: Split-brain checkout detection (F7) + operator UX

**Files:** Modify `libexec/orchid-doctor`, `libexec/orchid-status`, `runners/orchid-pump`, `libexec/orchid-init`. Extend `tests/test_init_doctor.sh`, `tests/test_status.sh`, `tests/test_pump.sh`.

**Interfaces:**
- Split-brain predicate (shared helper in `lib/common.sh`: `orchid_split_brain <repo>` → exit 0 when `.orchid/tasks/` or `.orchid/journal.md` exists but `.orchid/roadmap.md` does NOT): `orchid doctor` → FAIL naming the fix (`work from the integration branch or a worktree of it — see 'orchid init' output`); `orchid status` → first line `WARNING: split-brain checkout (.orchid state without roadmap.md — run from the integration branch)`.
- `runners/orchid-pump`: roadmap absent + tasks present → `pump: no roadmap in this checkout (split-brain — run from the integration branch)`, exit 0, distinct from `pump: run complete` (roadmap absent + NO other state = the existing not-an-orchid-repo arm).
- `orchid init` final output gains two lines: the integration branch name and the exact worktree command to start operating (`git worktree add ../<repo>-orchid <integ> && cd ../<repo>-orchid`).

- [ ] **Step 1:** RED — fixture with tasks/ but no roadmap: doctor FAILs, status warns, pump prints the split-brain line and never spawns; healthy fixture unchanged; init prints the worktree hint.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: split-brain checkout detection; init worktree hint`.

---

### Task 3: Tick actor identity + adapter fidelity

**Files:** Modify `runners/orchid-tick`, `libexec/orchid-journal`, `plugins/engines/codex/run`, `plugins/engines/codex-review/run` (conf only if needed), `plugins/engines/claude/run`, `tests/test_tick.sh`, `tests/test_engine_codex.sh`, `tests/test_engine_claude.sh`, `tests/test_jobs.sh`.

**Interfaces:**
- Actor identity: `orchid-tick` exports `ORCHID_ACTOR="<engine>/orchestrator tick-e<epoch>"` before spawning; `orchid journal add` uses `${ORCHID_ACTOR:-operator e<epoch>}` as the actor string (kernel-set env, documented as trusted-within-machine; the launcher already forwards ORCHID_*). Journal entries from headless ticks read `claude/orchestrator tick-e7` instead of `operator e7`.
- codex review path: the reply contract gains a `REASON: one sentence` second line (mirroring agy); the adapter captures it into envelope `summary` (200-char cap); `verdict`-only replies stay valid (summary optional).
- Log streaming (live-run finding): implement/review/orchestrate branches in codex+claude+agy adapters tee the engine CLI's combined output to the job log AS IT RUNS (log mtime advances during execution — the stall detector's signal) while still capturing it for parsing; zero-byte logs during a live job are the bug being fixed. Test: stub CLI sleeping 2s between lines → log grows during the run.
- ORCHID-ACTION discipline: both orchestrate branches' instruction blocks strengthen the marker contract (exact-line requirement, one per verb, printed BEFORE running each verb) AND the adapters fall back to counting `^ORCHID-ACTION:` in the LOG FILE tail when stdout-captured text has none (belt-and-braces; still `[]` when genuinely none).
- agy adapter: no change (m2 already fixed); test only.

- [ ] **Step 1:** RED — tick fixture asserts journal entry actor contains `orchestrator tick-e`; codex review stub replying VERDICT+REASON → summary captured; orchestrate stub printing markers only to the log file → actions still captured.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: tick actor identity; codex review reasons; action-marker fallback`.

---

### Task 4: Plan-phase critique launch path

**Files:** Modify `libexec/orchid-jobs` (prepare), `runners/orchid-launch`, `lib/pack.sh`, `libexec/orchid-plan` (no verb change — doc comment), `PROTOCOL.md` (PLANNING section), `tests/test_jobs.sh`, `tests/test_launch.sh`, `tests/test_pack.sh`.

**Interfaces (closes the gap hit in BOTH dogfoods — no way to launch `role.plan_critic` against a draft):**
- `orchid jobs prepare plan <role> critique` — the literal task id `plan` is reserved (task create refuses it): prepare skips the task-file read (attempt=1+count of existing `reviews/plan-a*-<role>.json`, base/candidate empty) and mints a plan-scoped manifest/job.
- `pack_build` for task `plan`: pack contains `requirements.md`, draft `roadmap.md`, every `tasks/*.md` (concatenated as `tasks.md`, truncatable tail-first), `lessons.md` when present — NOT the usual task.md/diff.
- `runners/orchid-launch plan plan_critic critique` works unchanged (it just forwards); reconcile files the envelope to `reviews/plan-a<n>-plan_critic.json` (existing counter-suffix logic).
- PROTOCOL PLANNING step 2 rewritten to actually run the loop: draft → `runners/orchid-launch plan plan_critic critique` → reconcile → fold findings → repeat until the critique's `findings[]` has nothing at/above medium → `plan apply`.

- [ ] **Step 1:** RED — prepare with task `plan` mints a manifest without a task file; pack contains requirements+roadmap+tasks.md; a stub critic envelope reconciles to `reviews/plan-a1-plan_critic.json`; `task create plan x` refused; PROTOCOL verb-lint still green.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: plan-scoped critique jobs`.

---

### Task 5: Hooks machinery

**Files:** Create `lib/hooks.sh`, `tests/test_hooks.sh`. Modify `lib/envelope.sh`, `lib/pack.sh`, `libexec/orchid-jobs` (prepare `--hook`), `runners/orchid-launch`, `lib/config-keys.txt`, `orchid.config.example`.

**Interfaces:**
- Hook points (closed set, kernel-owned): `after_plan_draft`, `before_arbitration`, `on_verify_fail`, `before_merge`, `on_blocker`.
- Config binding: `hook.<point>=<plugin-id>[:required][,<plugin-id>[:required]...]` — ordered list; `:required` marks a handler whose failure blocks the edge (exit 15 surfaces to the caller), optional handlers' failures are journaled and skipped.
- `lib/hooks.sh`: `hooks_for <repo> <point>` (prints `plugin-id\trequired|optional` per line, order preserved); `hook_timeout_s` config (default 600).
- Launch path: `orchid jobs prepare <task> <hook-plugin-role?> hook --hook <point> [--engine <plugin-name>]` — simpler: hooks are ENGINE-KIND plugins invoked with `operation=hook`; prepare gains `--hook <point>` which records `hook_point` in the manifest and resolves the engine by NAME from the binding (validated: discovered, `manifest_get kind` = engine or hook — a new `kind=hook` is accepted by manifest_validate with the same fields as engine). Request document gains `"hook_point": "<point>"`.
- Envelope union: `operation=hook` ok requires `.artifact` (object) + `.summary`; reconcile files to `reviews/<task>-a<n>-hook-<point>.json`.
- Pack for hook ops: task.md + the point-specific artifact — `on_verify_fail` → the verify log; `before_arbitration` → all current attempt review envelopes (concatenated `reviews.json`); `before_merge` → diff; `after_plan_draft`/`on_blocker` → roadmap/BLOCKERS respectively. Budgeted like review packs.
- Results are applied ONLY by the orchestrator through tier-1 verbs (PROTOCOL wiring is Task 6); `lib/hooks.sh` itself never mutates durable state (INV-01-clean, it's a lib).

- [ ] **Step 1:** RED — `hooks_for` parses ordered bindings + required flags; prepare `--hook` records the point + resolves the bound plugin; a stub hook engine (kind=hook) round-trips a valid hook envelope through launch+reconcile to `reviews/T001-a1-hook-before_merge.json`; malformed hook envelope (missing artifact) quarantined; unknown point → die; `hook.<point>` keys in config-keys.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: hook bindings, hook operation, typed hook envelopes`.

---

### Task 6: Hook wiring — PROTOCOL + kernel gates

**Files:** Modify `PROTOCOL.md`, `libexec/orchid-merge`, `libexec/orchid-verify` (no-op — read note), `tests/test_hooks.sh` (extend), `tests/test_merge.sh`, `tests/test_install.sh` (verb lint).

**Interfaces:**
- PROTOCOL THE TICK gains hook invocations at the defined edges, each following the same shape: reconcile the hook envelope, then act — `on_verify_fail` after a FAIL verify (attach the artifact's `guidance` string to the task via `orchid task set <id> hook_guidance "<...>"` before the rework advance); `before_arbitration` before weighing findings; `after_plan_draft` in PLANNING; `on_blocker` after `orchid notify`.
- `before_merge` is the ONE kernel-enforced point: `orchid merge` — when `hook.before_merge` has a `:required` binding — refuses (exit 15, `merge blocked: required before_merge hook '<id>' has no ok envelope for this candidate`) unless `reviews/<task>-a<n>-hook-before_merge.json` exists, `status=ok`, and its `candidate_sha` matches (sha-bound like the review gate). Optional bindings never gate merge.
- Frontmatter: `hook_guidance` added to the settable keys (template line + schema note in docs task).

- [ ] **Step 1:** RED — merge with a required before_merge binding + no envelope → exit 15; with a sha-matched ok envelope → proceeds; optional binding absent → proceeds; PROTOCOL verb-lint covers the new text; stub-driven tick-walk test exercising on_verify_fail guidance attach.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: hook points wired; before_merge kernel gate`.

---

### Task 7: Custom role registration

**Files:** Modify `lib/roles.sh`, `lib/manifest.sh` (kind=role), `libexec/orchid-plugins` (list/validate cover role plugins), `libexec/orchid-doctor`, `tests/test_roles.sh`, `tests/test_plugins_list.sh`. Create `tests/test_custom_roles.sh`.

**Interfaces:**
- Role plugin kind: `plugin.conf` with `kind=role` + a `role.descriptor` file (`<dir>/descriptor.role`, same key=value schema as built-ins: id/requires/forbids/description, plus optional `hook_bindings=<point>:<plugin-id>,...` recorded for doctor display only in m3). `manifest_validate` for kind=role: no entrypoint/capabilities required; `descriptor.role` must exist and its `id` must equal the manifest id's name part.
- `_role_file` search path (mirrors engine discovery): `$ORCHID_ROLES_DIR` (test hook) → `$ORCHID_PLUGIN_PATH/roles/<name>/descriptor.role` → `~/.orchid/plugins/roles/<name>/descriptor.role` → `$ORCHID_ROOT/roles/<name>.role` (built-ins last, INV-10 collision on duplicates INCLUDING a custom role shadowing a core role id — error, never a shadow).
- `resolve_role_chain`: a `role.<custom>` config key with no default chain resolves purely from config (empty default → exit 14 with `no binding for custom role '<x>' (set role.<x>=...)`).
- Non-blocking bindings (operations.md): `role.<id>.blocking=false` config key parsed by a new `role_binding_blocking <repo> <id>` helper (default true); consumed by PROTOCOL prose (a failed non-blocking role's job → journal + continue, never infra-fail). Config-keys entry documents the pattern.
- `orchid plugins list` shows role plugins (`kind=role`); doctor validates every `role.*` binding whose role is CUSTOM has a discoverable descriptor.

- [ ] **Step 1:** RED — a planted `~/.orchid/plugins/roles/researcher/` (manifest + descriptor requires=structured_text,citations) discovers, lists, validates; `role.researcher=agy` fails eligibility (agy lacks citations) with the capability message; a stub engine with citations passes; duplicate role id vs built-in `reviewer` → INV-10 error; unbound custom role → 14; blocking helper parses.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: custom role plugins with descriptor discovery`.

---

### Task 8: `refactor` / `test` / `migrate` archetypes

**Files:** Create `plugins/archetypes/refactor/plugin.conf`, `plugins/archetypes/test/plugin.conf`, `plugins/archetypes/migrate/plugin.conf`, `templates/task-refactor.md`, `templates/task-test.md`, `templates/task-migrate.md`, `tests/test_archetype_suite.sh`. Modify `libexec/orchid-task` (per-archetype template lookup), `templates/task.md` (unchanged content, becomes the fallback).

**Interfaces:**
- All three are `outcome=code` with the full feature transition set (they merge code and MUST pass testing+reviewing per the meta-contract); they differ in template lens text and defaults:
  - refactor: template body lens "behavior-preserving; the verification suite must pass UNCHANGED before and after — new tests forbidden except characterization tests"; `blocking_severity` default medium (template frontmatter), `risk_tier: medium` (refactors touch shared surface by nature).
  - test: lens "adds/extends tests only; production code edits forbidden beyond trivial testability seams (journal any)"; risk_tier low.
  - migrate: lens "schema/data/format migration; MUST include a rollback note and an idempotence statement in the task body"; risk_tier medium; `exclusive: true` default (migrations serialize against everything).
- `orchid task create --archetype <a>` uses `templates/task-<a>.md` when present, else `templates/task.md` (substitutions identical); template frontmatter may pre-set risk_tier/exclusive/blocking_severity (create-time values, not monotonic-rule violations — the rule guards post-create changes).
- `archetype_validate` already enforces the meta-contract — a test asserts all three validate and that a tampered copy (report outcome + merging transition) still exits 13.

- [ ] **Step 1:** RED — create with each archetype yields the right template defaults (migrate task is exclusive+medium, its dispatch is gated by the m2 scheduler when anything is active); each walks its full transition set with stubs; risk_tier medium from template does not require --reason at create; tampered archetype rejected.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: refactor, test, migrate archetypes with templates`.

---

### Task 9: Plugin lifecycle — install / update / remove / audit

**Files:** Modify `libexec/orchid-plugins`, `lib/config-keys.txt` (none expected — verify), `tests/test_plugins_lifecycle.sh` (create).

**Interfaces:**
- `orchid plugins install <src> [--kind <k>]` — `<src>` is a local directory or a git URL (`git clone --depth 1` to a temp dir; the ONLY network use, explicit to this verb — documented as such vs the tick's no-network posture). Flow: `manifest_validate` (13 on fail) → derive kind/name from manifest id → refuse if destination `~/.orchid/plugins/<kind>s/<name>` exists (say `update`) → refuse INV-10 collisions against the whole search path → copy → write `~/.orchid/plugins/<kind>s/<name>/.provenance` (`source=<path|url>`, `ref=<git rev-parse HEAD || ->`, `installed_digest=<plugin_digest>`) → print next steps (`orchid plugins test <name> <role>`; `orchid plugins lock` in repos).
- `update <name>` — re-fetches from `.provenance` source (refuses when source was a local dir that no longer exists), re-validates, replaces atomically (rsync-less: build in temp, `mv` swap), rewrites `.provenance`, and PRINTS the stale-capsuite warning (results invalidate automatically via the digest marker — m1 design).
- `remove <name>` — deletes the plugin dir; warns if any repo lockfile in `~/.orchid/known-repos` references it (best-effort: skip registry, just print the generic reminder to re-run `plugins lock`).
- `audit [<name>|--all]` — per plugin one block: id, version, kind, origin, trust status (repo-local only), provenance (source/ref or `local`), digest-now vs installed_digest (`modified since install` warning), capsuite results on record (per role, fresh/stale), lockfile references in the CURRENT repo when run inside one. Exit nonzero iff any audited plugin fails manifest validation — everything else is report-only.
- `.provenance` is parsed key=value, never sourced; excluded from `plugin_digest`? NO — digest covers it (any tamper flags), so `update` computes `installed_digest` AFTER writing `.provenance`.

- [ ] **Step 1:** RED — install from a local dir lands in sandbox `~/.orchid/plugins/engines/<name>` with provenance; duplicate install refused; collision with a built-in id refused (INV-10); update from a bumped source dir swaps version + digest; remove deletes; audit reports modified-since-install after a tamper; git-URL install exercised against a `file://` local bare repo fixture (no network in tests).
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: plugin install, update, remove, audit`.

---

### Task 10: Distributable conformance kit

**Files:** Create `libexec/orchid-plugins` subverb (`conform`), `lib/conform.sh`, `docs/extending/first-engine.md`, `docs/extending/conformance.md`, `tests/test_conform.sh`.

**Interfaces:**
- `orchid plugins conform <plugin-dir>` — runs WITHOUT any repo state (no `.orchid` needed): the third-party author's pre-flight. Battery (each check named, `ok/FAIL` lines, summary + nonzero on any FAIL):
  1. `manifest_valid` (existing validator),
  2. `entrypoint_executable`,
  3. `declared_ops_dryrun` — for each operation implied by capabilities (implement if workspace_write; review always; orchestrate if shell+git): invoke with `ORCHID_DRYRUN=1` + a minimal request doc → envelope validates against that operation's union,
  4. `stdin_closed_safe` — adapter invoked with stdin closed must not hang (run under `with_timeout 30`),
  5. `no_output_pollution` — adapter writes ONLY to the request's `output` path + stdout/stderr (probe: run in a scratch dir, assert no new files outside the output location),
  6. `env_survives_hygiene` — adapter runs under the same `env -i` allowlist the launcher uses (via `spawn_child_env`) and still produces a valid envelope,
  7. `exit_discipline` — a request naming an unsupported operation exits nonzero AND writes a failed envelope.
- `lib/conform.sh` reuses capsuite helpers where they fit but is repo-state-free; `plugins test` (capsuite) remains the ROLE-pairing gate — conform is the CONTRACT gate; docs explain the difference.
- `docs/extending/first-engine.md`: the "first adapter in under an hour" guide — walk a minimal `sh`-based adapter from `mkdir` to `conform` pass to `plugins install` to `plugins test`, referencing built-ins as reading material. `docs/extending/conformance.md`: the battery reference.

- [ ] **Step 1:** RED — a known-good stub adapter passes all 7; mutations break each check individually (non-executable entrypoint; envelope missing required field; adapter that reads stdin (planted `read` line) times out → FAIL; adapter dropping a stray file → no_output_pollution FAIL; adapter requiring an un-allowlisted env var → env check FAIL; silent exit-0 on unsupported op → FAIL).
- [ ] **Step 2:** Implement + write both docs. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: conformance kit and extending guides`.

---

### Task 11: Lessons + run rollover

**Files:** Create `libexec/orchid-lessons`, `tests/test_lessons.sh`. Modify `bin/orchid` (dispatch), `libexec/orchid-run` (`new` subverb), `lib/pack.sh` (lessons injection), `PROTOCOL.md` (lesson-birth moments + resume step 5), `tests/test_run.sh`, `tests/test_pack.sh`.

**Interfaces:**
- `lessons.md` format: `## <L-id> [<state>] <scope>` header + fields `statement:`, `evidence:`, `first:`, `last_confirmed:`, `invalidate_when:` — one block per lesson; states `active|superseded|retired`.
- `orchid lessons add --scope <repo|engine:<id>> --invalidate-when "..." "<statement>"` (mints `L00N`, journals kind `lesson`); `lessons update <id> [--confirm|--statement ...]` (bumps last_confirmed); `lessons retire <id> --reason "..."` (state flip + journal, reason required per the decision matrix); `lessons consolidate` — deterministic hygiene only: drops retired blocks older than the current run, enforces the byte cap (`lessons_max_bytes` config, default 16384; over-cap → refuses with the list of candidates, never auto-deletes active lessons); `lessons list [--active]`.
- Single-writer: `lessons.md` ← `orchid lessons` only (ownership table row already exists in kernel.md).
- Packs: implementer/reviewer/plan(+plan_critic) packs gain `lessons.md` (ACTIVE blocks only), truncatable after journal, before context (kernel.md trim order: journal → lessons → context — verify against the spec text and match it).
- `orchid run new --reason` — requires `run_status: complete|blocked`; archives `tasks/ reviews/ journal.md roadmap.md BLOCKERS.md` to `runs/<run_id>/` (durable, committed via the same temp-worktree commit pattern as plan apply), carries forward `context.md` + ACTIVE lessons, resets `roadmap.md` to `run_status: planning` with `run_id` incremented (`r-002`...), journals kind `intervention` into the FRESH journal naming the archived run.
- PROTOCOL: the three lesson-birth moments (rework caused by something context.md failed to state; recurring repo-behavior flake; arbitration that turned on unwritten repo knowledge) added at the corresponding walk steps; RESUME step 5 already reads lessons — sync the text.

- [ ] **Step 1:** RED — add/update/retire lifecycle with journal entries; retire without --reason dies; consolidate enforces the cap without deleting active; implementer pack contains active lessons only; `run new` refused while running, archives+resets on complete, next `plan apply` works on the fresh run; `runs/r-001/journal.md` intact.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m3: structured lessons and run rollover`.

---

### Task 12: Spec/docs sync + version + INV additions

**Files:** Modify `lib/common.sh` (`ORCHID_VERSION="1.0.0-m3"`), `docs/specs/roadmap.md`, `docs/specs/kernel.md`, `docs/specs/plugins.md`, `docs/specs/operations.md`, `PROTOCOL.md` (final consistency pass), `lib/config-keys.txt`, `orchid.config.example`, `tests/test_common.sh` (version), `tests/test_config_keys.sh`, `tests/test_install.sh`.

**Interfaces:**
- roadmap.md: v1-m3 marked SHIPPED (mirroring m1/m2), lessons scope-addition recorded; kernel.md: ownership table gains `runs/<id>/` + hook envelope rows, lessons section future-tense → shipped, decision matrix rows for `lessons retire`/hook journal kinds confirmed; plugins.md: Hooks + role-kind + lifecycle + conformance sections marked SHIPPED with verb names; operations.md: install flow updated (`plugins install` now exists), `docs/extending/` referenced.
- Config keys full check: `hook.<point>` family, `hook_timeout_s`, `lessons_max_bytes`, `role.<id>.blocking` — present in both files; `tests/test_config_keys.sh` extended for the new PROTOCOL/example mentions.
- Version bump + `requires_orchid` tolerance test (>=1.0 manifests still pass under 1.0.0-m3).

- [ ] **Step 1:** RED where testable (version, config-key coverage, PROTOCOL verb lint incl. `lessons`, `run new`, `plugins install/audit/conform`).
- [ ] **Step 2:** Edit docs + bump. Full suite green. — [ ] **Step 3:** ONE commit: `v1m3: spec sync, version 1.0.0-m3`.

---

### Task 13: Whole-branch review + v1-m3 dogfood (CONTROLLER-EXECUTED)

**Files:** modify `docs/dogfood-notes.md`.

- [ ] **Step 1 (whole-branch review):** strongest model, full v1-m3 diff, ledger-informed triage; fix wave; verdict.
- [ ] **Step 2 (dogfood, real commands, scratch repos + sandbox HOME):** (a) author a toy third-party engine adapter following `docs/extending/first-engine.md` FROM THE GUIDE ALONE, `plugins conform` it to green, `plugins install` from a local dir + a `file://` git URL, `audit` it, bind it to a CUSTOM role (`role.researcher`) and `plugins test` the pair; (b) hooks: bind a stub `before_merge:required` hook in a scratch run, watch merge refuse then pass; `on_verify_fail` guidance lands in the task body; (c) archetypes: walk one `test`-archetype and one `migrate`-archetype task (exclusive gating observed); (d) lessons: births during (b)/(c), `run new` rollover carries them; (e) plan-critique: run the new PLANNING loop with real codex against a 3-task draft. Cross-check the LIVE Pathway run's state (read-only `orchid status` against the webBooks worktree) for any m2 regression the m3 branch must not assume away.
- [ ] **Step 3:** Record findings; fix blocking bugs via the fix loop; non-blocking → v1-m4 ledger. Commit notes; PR `v1m3-sdlc` → main. **Post-merge:** the Pathway run (if still active) keeps using main — merge only after the run is idle or accept the mid-run kernel upgrade consciously (journal it in the webBooks run).

---

## Self-review notes
- Roadmap m3 deliverables mapped: hooks (T5+T6), custom role registration (T7), refactor/test/migrate archetypes + tooling lenses (T8), third-party lifecycle UX install/update/remove/test/audit (T9 — `test` existed since m1) + distributable conformance kit (T10). Ledger paydown: T1 (F9, count-gate, helpers, verb-lock liveness, ledger display, concurrency guard, empty-CSV), T2 (F7 + pump message), T3 (tick actor, codex-review reasons, ORCHID-ACTION), T4 (plan-critique gap — hit in both dogfoods). Scope addition T11 (lessons + run new) justified in the header. T12 sync, T13 proof.
- Exit 15 introduced once (T5/T6 required-hook failure); no collisions with 2/3/5/12/13/14.
- Cross-task consistency: `hooks_for`/`hook_point` (T5) consumed by T6; `descriptor.role` search path (T7) extends `_role_file` without breaking built-ins (last in path, collision = error); per-archetype templates (T8) fall back to the m2 template; `plugins conform` (T10) reuses `spawn_child_env` (m2 T7) and `envelope_validate` unions incl. T5's hook op; `run new` (T11) reuses plan apply's temp-worktree commit pattern.
- Live-run safety: all work in the `orchid-m3` worktree; main untouched until the user merges (T13 Step 3 spells out the mid-run upgrade decision).
- Every new config key named in a task also appears in T12's coverage check.
