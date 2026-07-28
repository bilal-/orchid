# Orchid v1-m1 — Plugin & Role Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build orchid's plugin & role foundation: a manifest schema with capability declarations, capability-based role descriptors, a capability-aware resolver, a digest-pinned trust store, kernel launcher env hygiene, a role×engine capability-suite runner, and the `orchid plugins` verb — the platform substrate every later milestone gates on.

**North star (v1, not this milestone):** deliver a "Pathway to Peace" book app under webBooks (14 language PDFs at `~/workspace/alislam/webBooks/books/pathway-to-peace/pdfs/`, pattern = the existing `the-will` app). That is a v1-m2+ dogfood once orchid runs autonomously; v1-m1's own dogfood proves the plugin/capability machinery.

**Architecture:** Per `docs/specs/plugins.md` (normative: manifest, capability model, trust model, threat model) + `roadmap.md` (v1-m1 scope). Built on merged v0. Kernel code never branches on a plugin's name (INV-05); capability declarations replace name-based assumptions.

**Tech Stack:** bash 3.2, jq, git, `shasum -a 256`/`openssl dgst`. Harness `tests/run.sh`.

## Global Constraints

- NO Claude/AI references anywhere (commits, files, PR). Post-commit `git log -1 --format=%B`; single-line subject, body-less; amend if violated.
- Branch `v1m1-foundation` from main; never commit to main.
- Reviewers/fixers NEVER `git checkout/switch/reset/commit` in the shared checkout — scratch worktrees (`git worktree add`, removed after) or `git show` only.
- Tier rules hold (INV-01/06 statics green); all durable writes atomic; bash 3.2; `plugin.conf`/config parsed never sourced.
- Manifest/capability data is parsed as key=value; capabilities/lists are comma-separated.
- Exit-code registry unchanged (2 unknown verb, 3 illegal transition, 5 rebase_rereview_required, 12 input_overflow); add: 13 = plugin validation failure.

---

### Task 1: Manifest library + built-in plugin.conf files

**Files:** Create `lib/manifest.sh`, `plugins/engines/codex/plugin.conf`, `plugins/engines/codex-review/plugin.conf`, `plugins/engines/agy/plugin.conf`, `plugins/engines/claude/plugin.conf`, `plugins/archetypes/feature/plugin.conf`, `tests/test_manifest.sh`.

**Interfaces (lib/manifest.sh, sourced):**
- `manifest_get <plugin-dir> <key> [default]` — reads `<dir>/plugin.conf` (key=value, parsed never sourced; reuse `_cfg_file_get`-style logic).
- `manifest_validate <plugin-dir>` — exit 0 iff: file exists; `manifest_version` present and == 1 (unknown → reject, exit 13); `id` present, qualified (`^[a-z0-9_-]+/[a-z0-9_-]+$`), no `..`; `kind` in `engine|archetype|notify|hook|role`; `api_version` present, integer, == 1 for now (unknown → reject 13); `version` present (semver-ish `^[0-9]+\.[0-9]+`); `entrypoint` names an executable file in the dir (for engine/notify kinds); `capabilities` (engine) is a comma list of known atoms. Unknown KEYS (in a known manifest_version) → warn to stderr, still valid. Prints `ok`/`warn: ...`/`FAIL: ...` lines.
- `manifest_capabilities <plugin-dir>` — prints the capability atoms one per line.
- Known capability atoms constant: `structured_text workspace_read workspace_write shell git network citations` (in `lib/capabilities.txt`).

**Built-in manifests** (fill real values; `id=orchid/<name>`, `manifest_version=1`, `api_version=1`, `requires_orchid=>=1.0`, `entrypoint=run`):
- codex: `kind=engine capabilities=structured_text,workspace_read,workspace_write,shell,git requires_binaries=codex,jq platforms=macos,linux`
- codex-review: `kind=engine capabilities=structured_text,workspace_read,git requires_binaries=codex,jq`
- agy: `kind=engine capabilities=structured_text requires_binaries=agy,jq` (inline reviewer — text in/out only)
- claude: `kind=engine capabilities=structured_text,workspace_read,workspace_write,shell,git requires_binaries=claude,jq`
- feature archetype: `kind=archetype api_version=1` (no capabilities/entrypoint).

- [ ] **Step 1:** `tests/test_manifest.sh` RED — valid built-in manifest passes; missing manifest_version → FAIL; manifest_version=2 → reject exit 13; unqualified id (`codex`) → FAIL; id with `..` → FAIL; unknown capability atom → FAIL; unknown extra key → warn but valid; `manifest_capabilities` lists atoms; each of the 5 built-in dirs validates clean.
- [ ] **Step 2:** Implement lib + write the 5 plugin.conf files. Full suite green.
- [ ] **Step 3:** ONE commit: `v1m1: manifest schema, capability atoms, built-in plugin.conf`.

---

### Task 2: Role descriptors + capability-based eligibility

**Files:** Create `lib/roles.sh`, `roles/orchestrator.role`, `roles/implementer.role`, `roles/reviewer.role`, `roles/arbiter.role`, `roles/plan_critic.role`, `tests/test_roles.sh`. Modify `lib/resolver.sh`.

**Interfaces:**
- `.role` files (key=value): `id=<role>`, `requires=<cap,cap>`, `forbids=<cap,...>` (optional), `description=...`.
  - orchestrator: `requires=shell,git` (drives verbs, launches adapters)
  - implementer: `requires=workspace_write,shell,git`
  - reviewer: `requires=structured_text` (text in/out minimum — agy qualifies)
  - arbiter: `requires=structured_text`
  - plan_critic: `requires=structured_text`
- `lib/roles.sh`: `role_requires <role>` / `role_forbids <role>` (read from `$ORCHID_ROOT/roles/<role>.role`, extensible via search path later); `role_eligible <role> <plugin-dir>` — exit 0 iff the plugin's capabilities ⊇ requires AND ∩ forbids == ∅.
- `lib/resolver.sh` gains `resolve_role_checked <repo> <role>` — resolves the engine (existing `resolve_role`), finds its plugin dir, and returns the engine name ONLY if `role_eligible` passes; else exit 1 with a clear "engine X lacks capability Y for role Z" message. Existing `resolve_role`/`resolve_engine_exe` unchanged (back-compat).

- [ ] **Step 1:** `tests/test_roles.sh` RED — each core role's requires parsed; agy (structured_text only) eligible for reviewer/arbiter/plan_critic but NOT implementer (lacks workspace_write); codex eligible for all; `resolve_role_checked` returns codex for implementer, rejects a fake `role.implementer=agy` binding with the capability message. INV-05 stays green (no name branching — eligibility is capability-driven).
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m1: capability-based role descriptors and eligibility`.

---

### Task 3: `orchid plugins list` + `validate` + discovery report

**Files:** Create `libexec/orchid-plugins`, `tests/test_plugins_list.sh`. Modify `libexec/orchid-doctor`.

**Interfaces:**
- `orchid plugins list` — walks the discovery search path (`$ORCHID_PLUGIN_PATH` (colon list) → `~/.orchid/plugins/<kind>s/` → `$ORCHID_ROOT/plugins/<kind>s/`; repo-local `<repo>/.orchid/plugins/` listed but marked `disabled` unless trusted — Task 5), prints `<id>\t<kind>\t<version>\t<origin>\t<trust>` per discovered plugin (trust=`builtin|user|trusted|DISABLED`). Duplicate `id` across path → a `COLLISION` line + nonzero exit (INV-10 full).
- `orchid plugins validate [<id>|--all]` — runs `manifest_validate` on one/all; aggregate exit 13 on any FAIL.
- `orchid doctor` gains a "plugins:" section printing the discovery report (origin/trust/collisions) BEFORE role checks; a collision is a doctor FAIL.

- [ ] **Step 1:** RED — list shows the 5 built-ins as `builtin`; a `~/.orchid/plugins/engines/fake/` (sandbox HOME) with a valid manifest shows as `user`; two dirs with the same `id` → COLLISION + nonzero; validate --all passes on built-ins, fails on a malformed planted manifest; doctor shows the plugins section.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m1: orchid plugins list/validate; doctor plugin report`.

---

### Task 4: Trust store + repo-local plugin enablement

**Files:** Modify `libexec/orchid-plugins`, `lib/resolver.sh` (resolve_engine_exe search path), `tests/test_plugins_trust.sh`.

**Interfaces:**
- `orchid plugins trust <plugin-dir>` — computes the plugin's content digest (SHA-256 over a stable sorted listing of its files' hashes — `find -type f | sort | xargs shasum -a 256 | shasum -a 256`), appends `<abs-path> <digest>` to `~/.orchid/trust` (atomic; refuse duplicate path with different digest → prompt to `trust --update`). `trust --update <dir>` re-pins.
- `orchid plugins untrust <dir>` — removes the record.
- Repo-local plugins (`<repo>/.orchid/plugins/<kind>s/`) are DISCOVERED but only EXECUTABLE (resolvable by `resolve_engine_exe`) when a trust record exists AND the current digest matches (digest mismatch after a repo pull → de-trusted, resolver skips + warns). Built-in and `~/.orchid` plugins need no trust (user-controlled locations).
- `orchid plugins list` reflects `trusted`/`DISABLED (untrusted)`/`DISABLED (digest mismatch)`.

- [ ] **Step 1:** RED — a repo-local engine is DISABLED by default (resolve_engine_exe skips it, list shows DISABLED); after `plugins trust <dir>` it resolves + lists `trusted`; mutating a file in the dir → digest mismatch → DISABLED again; untrust → gone. Trust record lives in sandbox HOME, never in the repo. INV-09 (repo-local never executes without trust) as a named test `tests/inv/test_INV-09_repo_local_trust.sh`.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m1: digest-pinned trust store; repo-local plugin gating (INV-09)`.

---

### Task 5: Kernel launcher env hygiene + manifest permissions

**Files:** Modify `runners/orchid-launch`, `lib/manifest.sh` (permissions read), `tests/test_launch.sh`.

**Interfaces:**
- The launcher spawns the adapter with a STRIPPED environment: an allowlist base (`PATH HOME USER LANG LC_* TERM TMPDIR` + `ORCHID_*`) plus exactly the env var names the plugin's `plugin.conf` `permissions=` opts into (comma list of env var names, e.g. `permissions=OPENAI_API_KEY`). Everything else is unset for the child. Implement via `env -i` with the allowlist reconstructed, or an explicit unset of non-allowlisted names (bash 3.2: enumerate `compgen -e`-free via `env` parse). stdin `/dev/null` and the request document stay as-is.
- A plugin requesting a permission not present in the environment → the launcher still runs it (the adapter reports auth failure), but `orchid doctor`/`plugins validate` warns "permission X requested, not set".

- [ ] **Step 1:** RED — launch a stub engine that echoes a marker env var (e.g. `SECRET_LEAK`) into its envelope summary; assert the child did NOT see `SECRET_LEAK` (set in the parent, not allowlisted, not in permissions); then add `permissions=SECRET_LEAK` to the stub's plugin.conf → child DOES see it. ORCHID_* and PATH always pass.
- [ ] **Step 2:** Implement. Suite green (existing launch tests must still pass — they rely on ORCHID_* + PATH reaching the child). — [ ] **Step 3:** ONE commit: `v1m1: launcher env allowlist with manifest-opt-in permissions`.

---

### Task 6: Capability-suite runner — `orchid plugins test`

**Files:** Modify `libexec/orchid-plugins`, create `lib/capsuite.sh`, `tests/test_plugins_test.sh`.

**Interfaces:**
- `orchid plugins test <engine-id> <role>` — runs the (engine, role) pair through a capability battery WITHOUT spending real quota where possible, recording a durable result to `~/.orchid/capsuite/<engine>--<role>.json` `{engine, role, passed, checks:[{name,ok}], tested_at_marker}`. Checks (each maps to a declared capability, verified by a real but minimal probe via ORCHID_DRYRUN where the engine supports it + static manifest checks):
  - `manifest_valid`, `capabilities_cover_role` (static, from role_eligible),
  - `binaries_present` (requires_binaries resolve on PATH),
  - `dryrun_envelope_valid` (invoke the adapter with ORCHID_DRYRUN=1 for the role's operation → envelope passes `envelope_validate`),
  - for implementer role: `workspace_write_probe` (dryrun path only in v1-m1; a real-write probe is noted as post-m1).
- Result feeds v1-m2 failover gating: `capsuite_passed <engine> <role>` helper in lib/capsuite.sh reads the recorded result (stale/absent → not-passed).
- `orchid plugins test --all-defaults` runs the default role→engine pairs.

- [ ] **Step 1:** RED — `plugins test codex implementer` with a stubbed codex (dryrun) → passed, result file written, all checks ok; `plugins test agy implementer` → FAILS at `capabilities_cover_role` (agy lacks workspace_write) and records passed=false; `capsuite_passed` reflects both. Missing binary → binaries_present fails.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m1: capability-suite runner and durable results`.

---

### Task 7: Plugin lockfile

**Files:** Modify `libexec/orchid-plugins`, `libexec/orchid-init` (or `orchid-plan`), `tests/test_plugins_lock.sh`.

**Interfaces:**
- `orchid plugins lock` — writes `.orchid/plugins.lock` (durable, committed) recording, for every plugin a resolved role binds to in this repo's config: `{id, version, digest, source_origin, api_version, capsuite_passed}`. Atomic. This pins the run's plugin reality so a mid-run plugin change is detectable.
- `orchid plugins verify-lock` — compares current discovery against `plugins.lock`; drift (version/digest change, or a bound plugin now missing) → nonzero + a report. `orchid doctor` runs verify-lock when a lock exists (drift = doctor warning, not fail, in v1-m1).
- `orchid-init` writes an initial `plugins.lock` after creating state (best-effort; empty if no non-default bindings).

- [ ] **Step 1:** RED — `plugins lock` produces a lock with the default engine bindings' ids+digests; mutating a built-in adapter then `verify-lock` → drift reported; unchanged → clean. Lock is on the integration branch (committed), digests match `plugins trust`'s algorithm.
- [ ] **Step 2:** Implement. Suite green. — [ ] **Step 3:** ONE commit: `v1m1: plugin lockfile and drift verification`.

---

### Task 8: INV coherence + `orchid version` + docs sync

**Files:** Create `tests/inv/test_INV-10_no_shadow.sh`; modify `libexec/orchid-version` (create), `bin/orchid` (version verb), `docs/specs/plugins.md`, `docs/specs/roadmap.md`, `lib/config-keys.txt`.

**Interfaces:**
- `orchid version` — prints the kernel version (`ORCHID_VERSION` constant, set to `1.0.0-m1`); `requires_orchid` checks in manifest_validate compare against it (semver-ish `>=` on major.minor).
- INV-10 named test: duplicate plugin id across the search path is an ERROR everywhere it matters (list, resolve, doctor) — never a silent precedence win.
- docs sync: update plugins.md/roadmap.md where v1-m1 delivered something the spec described as future (mark the manifest/capability/trust/capsuite/lock items as SHIPPED in m1; note real-write capability probe + hooks/custom-role registration remain m3). Config keys added (`infra_max` already; add any new).

- [ ] **Step 1:** RED for INV-10 (planted duplicate id); version verb prints; requires_orchid `>=2.0` on a manifest → reject.
- [ ] **Step 2:** Implement + docs edits. Suite green. — [ ] **Step 3:** ONE commit: `v1m1: orchid version, INV-10 full, spec sync`.

---

### Task 9: Whole-branch review + v1-m1 dogfood

**Files:** modify `docs/dogfood-notes.md`.

- [ ] **Step 1 (whole-branch review):** strongest model, full v1-m1 diff, Minor triage; fix wave; verdict.
- [ ] **Step 2 (CONTROLLER-EXECUTED dogfood — proves the plugin machinery, no app):** in a scratch repo, (a) `orchid plugins list` shows built-ins; (b) drop a repo-local engine, confirm DISABLED, `plugins trust` it, confirm enabled; (c) `orchid plugins test agy implementer` → correctly FAILS on capability (agy can't implement), `plugins test codex implementer` → passes; (d) `orchid plugins lock` + mutate + `verify-lock` shows drift. Record findings; fix blocking bugs via the fix-loop; non-blocking → v1-m2 ledger.
- [ ] **Step 3:** commit dogfood notes; PR `v1m1-foundation` → main.

---

## After v1-m1
v1-m2 (pump + capability-gated failover + concurrency) is the milestone that
makes autonomous multi-task runs real — and the Pathway to Peace app becomes
its grand dogfood: write `requirements.md` decomposing the app (parse 14
PDFs → per-language content JSON, author.json/books.json, enrichments,
following `the-will`'s structure), then let orchid drive it with codex
implementing and agy reviewing. The capability suite (Task 6) is what lets
m2 safely fail over between engines during that long run.

## Self-review notes
- Every v1-m1 roadmap deliverable maps to a task: manifest schema (T1),
  capability role descriptors (T2), pinned/capability-aware resolver (T2),
  plugin lockfile (T7), launcher hygiene (T5), capability-suite runner (T6),
  `orchid plugins list/validate/trust` (T3-T4). INV-09 (T4), INV-10 (T8).
- Back-compat: existing resolve_role/resolve_engine_exe keep working; new
  capability checks are additive (resolve_role_checked). v0 tests stay green.
- The app is explicitly deferred to m2 (autonomy) — m1 dogfood tests plugins.
