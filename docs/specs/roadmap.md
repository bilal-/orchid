# Orchid — Roadmap

*Normative. One of four documents split from the design spec; see [2026-07-24-orchid-design.md](./2026-07-24-orchid-design.md) for the index and orientation.*

## Requirements (from design sessions)

- **Run model:** semi-attended. The primary surface is an interactive
  session of WHICHEVER front-end holds the orchestrator role (a Claude Code
  session with the orchid skill in the author's default configuration — but
  any front-end executing PROTOCOL.md qualifies); the machine stays awake.
  The LLM-free pump plus headless `orchid-tick` (v1-m2) keep the run
  advancing when the interactive session is rate-limited or closed; service
  packaging ships in v1-m4.
- **Scope:** existing repos first (v0); greenfield products (v1).
- **Engine roles:** fully configurable via `role.*` keys from v0; orchid
  never hard-codes an engine to a role and kernel code never branches on a
  plugin's name. v0 ships and TESTS the default bindings; non-default
  bindings are supported-but-unverified (labeled by doctor) until the
  capability suite (v1) passes them.
- **Autonomy:** fully autonomous — no user approval gates; only genuine
  blockers surface, bounded by the Execution policy (see kernel.md). **Continuity promise
  (precise):** a single engine outage never loses state and never stops
  eligible work; work whose policy requires an unavailable engine queues
  until that engine's window reopens. With failover enabled (v1),
  orchestration itself continues on a fallback engine.
- **Distribution:** public GitHub repository for general benefit; public
  only after dogfooding (see Distribution).
- **Non-goals (all stages):** HOSTED or dynamic services (a locally
  generated static status page and launchd/cron packaging of the pump are
  in scope; a server is not), web app UI, usage/cost ledger, multi-user,
  cross-machine operation, chat-style inter-agent messaging, native phone
  app, central plugin registry (provenance and pinning are required; a
  registry is not). Orchid never builds ON agent runtimes (OpenClaw,
  Hermes) — they plug in as engines or notify channels only.

## Delivery stages

- **v0 — vertical slice:** one existing repo, ONE active task at a time,
  default role bindings, `feature` archetype only, CLI kernel verbs,
  deterministic verify/merge, crash recovery (no PID re-adoption), manual
  resume. **One reviewer policy in v0** (round-5 simplification): exactly
  one reviewer per task — engine-independent when available, else labeled
  session-independent fallback; dual review and full risk-tier routing
  arrive with v1-m2, after baseline data exists. Alternate role bindings
  resolve but are UNSUPPORTED until v1-m1's capability suite. The plugin seam ships FINAL-SHAPED in v0: the real
  `ORCHID_PLUGIN_PATH` layout, one role→engine resolver used by doctor,
  jobs, and PROTOCOL alike, launch-by-role, and a fake non-default-binding
  test proving no engine name is hard-coded. Repo-local plugins DISABLED (no
  trust store yet). Manifest validation minimal (existence + executable).
- **v1 — the full delivery**, in four milestones whose order follows the
  dependency graph (round-4 consensus fix: platform foundations BEFORE the
  features gated on them):
  - **v1-m1 (plugin & role foundation) — SHIPPED:** minimal manifest schema
    with capability declarations (incl. `requires_orchid` version-compatibility
    checks against `orchid version`), core role DESCRIPTORS (the five
    built-in roles formalized — required in spirit since v0), the pinned
    capability-aware resolver, the digest-pinned trust store (INV-09), plugin
    lockfile, kernel launcher hygiene, the role×engine capability-suite
    runner, and the full `orchid plugins list/validate/trust/test/lock/
    verify-lock` verb set. Deferred to later milestones: a real
    filesystem-write capability probe (m1 ships dryrun-only) and hooks +
    custom-role registration (both v1-m3, per plugins.md's Hooks section).
  - **v1-m2 (core autonomy) — SHIPPED:** the engine availability ledger
    (`runtime/engines.json`, `orchid jobs reconcile`-driven, `orchid
    status`'s `== engines` section); failover-aware role resolution
    (`role.*` comma preference chains, `resolve_role_available`'s
    discovery→eligibility→ledger→capsuite gate, exit 14 on no survivor);
    risk-tiered dual review (`review.<tier>` routing, `orchid jobs
    review-plan`, per-slot `--engine` launches, the kernel's own
    reviewing→arbitrating envelope-count gate); archetype-driven
    transitions (`plugins/archetypes/*/plugin.conf`'s `transitions=`/
    `outcome=`) and the shipped `review` archetype; concurrency 2 with
    `lib/schedule.sh`'s dispatch predicates (`concurrency-cap`,
    `exclusive-overlap`, `resource-conflict`, `waiting-deps`) and the
    rebase/re-review rules; per-verb transactional locking
    (`verb_lock_wait_s`) across the durable-mutating CLI verbs
    (`task`/`run advance`+`accept`/`plan`/`requirements`/`jobs
    prepare`+`reconcile`/`journal`/`notify`/`answer` — `merge`, `init`,
    `verify`, and `plugins` deliberately excluded: `merge` keeps its
    coarser run-lock discipline by design); the headless
    tick (`runners/orchid-tick`, the `orchestrate` request/envelope
    operation) and the LLM-free pump (`runners/orchid-pump`, lease-staleness
    mutual exclusion); greenfield mode (`orchid init --greenfield`, `orchid
    doctor --greenfield`, the scaffold-task convention) — all implemented
    and tested, not merely specified. PROTOCOL.md's v1 rewrite (concurrency
    preamble, risk-tiered review policy, HEADLESS OPERATION) and the
    version bump to `1.0.0-m2` land in the same milestone. An in-branch
    scratch-project dogfood exercises the shipped machinery before merge;
    the grand proof is the Pathway to Peace greenfield app under webBooks —
    post-m2, running once this branch lands, driven entirely by the
    autonomy this milestone built.
  - **v1-m3 (SDLC suite + custom extensibility) — SHIPPED:** kernel
    hardening from the m2 dogfood ledger (`fm_set` empty-value in-place
    replacement, an ok-only review-count gate, the verb-lock elapsed-time
    budget + empty-dir break, `ledger_show`'s sub-threshold reporting, a
    concurrency guard, the empty-CSV manifest fix); split-brain checkout
    detection (`orchid_split_brain` wired into `doctor`/`status`/the pump,
    plus an `init` worktree hint); tick actor identity (`ORCHID_ACTOR`) +
    adapter log streaming + a heartbeat (`lib/heartbeat.sh`, the
    `ORCHID_HB_INTERVAL_S` env-only override) + codex REASON capture + a
    no-resume tick instruction; plan-scoped critique jobs (the reserved task
    id `plan`, plan packs, PROTOCOL.md's PLANNING critique loop); hooks
    (`lib/hooks.sh`, `hook.<point>` config bindings, the `operation=hook`
    request/envelope shape, the kernel-enforced `before_merge` gate at exit
    15, `hook_guidance`); CUSTOM role registration (core registry existed
    since m1; `kind=role` plugins, `descriptor.role` discovery on the same
    search path as engines, `role.<id>.blocking`); `refactor`/`test`/
    `migrate` archetypes with their templates; third-party plugin lifecycle
    UX (`orchid plugins install/update/remove/audit`, digest-verified
    `.provenance` with `sig=`, path-independent `plugin_digest_content`) +
    the distributable conformance kit (`orchid plugins conform`'s seven
    checks, `docs/extending/first-engine.md` + `conformance.md`); and
    cross-run lessons + run rollover (`orchid lessons
    add/update/retire/consolidate`, per-role pack injection, `orchid run
    new`'s `runs/<run_id>/` archival with the context+active-lessons
    inheritance boundary, temp-worktree CAS shadow-swap sync-back with
    git-checkout recovery). **Scope addition, recorded honestly:** the
    lessons lifecycle and run rollover are NOT in this bullet's original
    text above (they were slated only generically under kernel.md's
    `lessons.md, v1` placeholder) — they were pulled forward into m3 proper
    because the archetype and plugin-lifecycle work this milestone shipped
    only becomes safely dogfoodable across MULTIPLE runs of the same repo
    once a defined cross-run memory boundary exists; shipping `orchid run
    new` without ALSO shipping the lessons lifecycle it depends on
    (carry-forward vs. archive) would have left that boundary undefined.
    All implemented and tested, not merely specified.
  - **v1-m3 ledger — carried into v1-m4 as candidates, not yet scheduled**
    (found live, during this milestone's own dogfooding; none of these are
    fixed on this branch):
    - **(HIGH) Ref-only merges leave a stale checked-out integration
      worktree.** `orchid merge` advances the integration branch with `git
      update-ref` alone (kernel.md, Task lifecycle) — it never touches any
      OTHER checkout of that branch. A long-lived checkout left open across
      a merge (e.g. an operator inspecting the integration branch) keeps a
      stale index/tree; a direct operator commit made from it silently
      REVERTS the just-merged work (its parent is still the pre-merge SHA).
      Candidates: staged-deletion detection in `doctor`/`status` (a
      revert-shaped commit deletes files a passing task just added); a safe
      operator config-commit verb, built on the same plan-apply-style
      temp-worktree pattern `orchid plan apply`/`orchid run new` already
      use, so a human edit never touches a live checkout directly;
      worktree-aware ref advance (refresh any other checkout of the
      integration branch as part of the same transaction `update-ref`
      performs, not left to operator discipline).
    - **pack_build packs the full diff regardless of reviewer capability.**
      `lib/pack.sh`'s review/critique pack always ships `git diff
      base..candidate` in full — it never checks whether the launched
      reviewer actually declares `workspace_read` (and so could read the
      diff off its own worktree checkout instead). Bulk-content tasks
      therefore need an operator budget raise (`pack_budget_bytes`) that a
      worktree-capable reviewer shouldn't need at all. Roadmap item: a
      worktree-read review pack that ships a reference + changed-path list
      instead of the literal diff when the launched reviewer is
      worktree-capable (a scoped-reviewer plugin built for the webBooks
      greenfield dogfood — Distribution above — is the prototype for this,
      outside this repo).
    - **`jobs gc` cannot reap a pid-0 (prepared-never-launched) manifest.**
      By design (INV-01-clean: gc never kills anything live), a manifest
      whose launch failed before it ever recorded a real pid stays
      `prepared` forever — `jobs gc` explicitly skips `pid: 0` entries, and
      `jobs check` re-reports the same one every pass. Harmless today (rare:
      only a launcher crash between `jobs prepare` and the actual spawn
      produces one) but perpetual noise once it happens. Roadmap note: a
      bounded pid-0 reap path (age-gated, distinct from the live-pid gc
      path) for v1-m4.
  - **v1-m4 (ecosystem + polish) — SHIPPED:** split into release-blocking
    core and CONDITIONAL reference adapters, per this milestone's own escape
    hatch (upstream churn may drop an individual adapter from launch; a
    dropped adapter disappears from the README headline, compatibility
    matrix, and tutorial list — never from a core conformance gate). Shipped
    scope by theme:
    - **Durable state (m3 ledger paydown):** `orchid_commit_durable`
      (`lib/common.sh`) — the shared plan-apply-style temp-worktree commit
      helper now backs `orchid run accept` and `orchid config` (a safe
      operator config-commit verb), closing the journal-loss incident's
      root cause; `orchid run release-lease` (clean-session-exit affordance
      so a session's own final tick no longer blocks `run new`/the pump for
      up to `pump_stale_s`); `orchid jobs gc --reap-prepared` (bounded,
      age-gated reap of pid-0 prepared-never-launched manifests, a separate
      exclusive mode from ordinary gc); a baked pre-push hook (installed by
      `orchid init`, `push_guard` config, refuses pushes to task branches or
      the integration branch with the branch name substituted in at install
      time, `ORCHID_ALLOW_PUSH=1` override).
    - **Worktree-read review packs:** `pack_diff_inline_max_bytes` (config,
      default 262144) — a diff larger than this swaps the inline
      `diff.patch` for a `diff.stat` summary when the resolved reviewer
      declares `workspace_read`, honestly recorded in `pack.json`; an
      inline-only engine still hits `input_overflow` at that size. The
      scoped-reviewer prototype from the m3 ledger is promoted into the
      kernel pack builder proper.
    - **Service packaging:** `orchid service install/uninstall/status`
      (`runners/orchid-service`) — a launchd agent on macOS, a
      marker-guarded crontab line elsewhere, both idempotent re-install,
      both testable end-to-end under `--dry-run` without ever touching the
      real scheduler.
    - **Status page:** `orchid status --html` — a self-contained static
      page (run header, task table with `--explain`-style predicates,
      engines ledger, open blockers, last-10 journal entries) written to
      `status_page` (config, default `runtime/status.html`); independent of
      `--explain`, stdout is exactly the path written.
    - **Hermes adapter:** a conditional reference engine adapter
      (`plugins/engines/hermes`, `docs/engines/hermes.md`) verified live
      against real quota.
    - **OpenClaw + Hermes notify channels, and the orchid AgentSkill:** the
      outbox pattern (`orchid notify` writes `runtime/outbox/<qid>`;
      `runners/orchid-pump` drains it through the configured
      `notify.plugin`'s `send`, tier-2 only, INV-01-clean); nonce +
      allowlist hardening on `orchid answer` (`answer_allowlist` configured
      ⇒ `--nonce` mandatory for every caller, local or remote — closes the
      prior bypass of simply omitting `ORCHID_ANSWER_SENDER`); the orchid
      AgentSkill (`skills-external/openclaw-orchid`) — an OpenClaw-hosted
      front-end authorized for exactly `orchid status` and `orchid answer`.
      Verified live against real quota (hero demo).
    - **Docs suite + rehearsal gate:** full quickstart (existing +
      greenfield), `docs/configuration.md`, `docs/engines/*`,
      `docs/extending/*`, `docs/troubleshooting.md`, README — rehearsed
      clean-machine, clone-to-first-completed-task under 15 minutes.
    - **Homebrew prep:** `Formula/orchid.rb` (prepare-only — never tapped,
      installed, or built by the suite) + `docs/install.md` + `install.sh
      --prefix`.
    - **Dropped, per the escape hatch:** the Kimi reviewer and Perplexity
      researcher reference adapters did NOT ship this milestone — the
      relevant CLIs are not installed on the dogfood machine, so both were
      never built past the roadmap-stage mention above. Verified plain:
      README, the compatibility matrix, the tutorial list, and every
      `docs/engines/*` guide name only the adapters that actually shipped
      (Claude Code, Codex, Antigravity, agy, Hermes, OpenClaw) — neither
      name appears anywhere in that surface as an available adapter.
  - **Release checklist (binary, no judgment calls at the gate):** all
    m1–m3 conformance suites green; m4 core complete; docs suite passes the
    15-minute clean-machine rehearsal; screenshots from real dogfood runs;
    works-with claims match actually-shipped adapters; THEN public release.

## Distribution (public GitHub repo)

Private at implementation start; public at end of v1 after dogfooding
produces real screenshots. MIT. README: hero + screenshot; how-it-works
diagram + one task's journey — including an explicit **"who runs whom"**
panel: Orchid's source routes engine launches through tier-2 runners and
brokers results as files (a topology invariant, not OS containment); the
orchestrating engine needs
exactly one power — running a bash CLI — and every other role×engine combo
is disabled until the capability suite proves it; why this design; **any engine, any role**
matrix (capability table, tested defaults, degraded-independence labeling,
worked `role.*` swap example); install/uninstall; quickstarts (existing +
greenfield) with screenshots; state files, guardrails, operator verbs;
**Extending orchid** (five extension points, patterns glossary, "first
adapter in under an hour" against `docs/extending/` guides — referencing
built-ins until the v1-m4 reference plugins ship); FAQ; **Research grounding** (below). CONTRIBUTING.md + a
community plugin listing section (awesome-orchid) at public launch.

**Research grounding (`docs/research.md` + inline citations):** orchid's
design pillars each cite the literature that genuinely supports them —
citations appear NEXT TO the claim they support in README/docs, and
`docs/research.md` is the annotated bibliography. The rule is relevance,
not volume: padding with tangential papers reads as spam and inverts
credibility. The pillar map:

| Design pillar | Supporting work |
|---|---|
| multi-agent division of labor for software dev | MetaGPT (Hong et al.), ChatDev (Qian et al.), AutoGen (Wu et al.), CAMEL (Li et al.) |
| nobody signs off on their own work / engine independence | LLM-as-judge (Zheng et al., MT-Bench); self-preference bias — LLM evaluators favor their own generations (Panickssery et al.) |
| reviewer diversity & arbitration on disagreement | multi-agent debate (Du et al.), More Agents Is All You Need (Li et al.), Mixture-of-Agents (Wang et al.) |
| rework specs, journal, lessons (memory design) | Reflexion (Shinn et al.), Self-Refine (Madaan et al.), Voyager skill library (Wang et al.), Generative Agents memory streams (Park et al.), MemGPT (Packer et al.) |
| deterministic verification over model claims; agentic SE evaluation | SWE-bench (Jimenez et al.), SWE-agent (Yang et al.); trajectory evaluation per Google's "The New SDLC With Vibe Coding" whitepaper |
| harness > model; factory model; model routing | Google whitepaper; Karpathy's agentic-engineering framing |
| productivity claims (stated with nuance, both directions) | METR RCT (experienced devs can be SLOWER with AI — cited honestly), Peng et al. Copilot study |

Exact citations (authors, venues, years, links) are verified against the
published papers when `docs/research.md` is written — titles above are
from design-time knowledge and MUST be link-checked before public release. Commit
hygiene: clean history, no AI trailers, no personal paths, `$HOME`/`PATH`
resolution only.

**Ecosystem piggyback strategy (launch checklist):** ride the distribution
of adjacent popular projects rather than competing with them —
1. Launch README headline: "Works with OpenClaw · Hermes · Claude Code ·
   Codex · Antigravity" (compatibility wording only; never imply
   endorsement or partnership).
2. Publish the **orchid AgentSkill into OpenClaw's skill ecosystem** —
   status queries and blocker answers from WhatsApp/Telegram — so orchid is
   discoverable where OpenClaw's own users browse; hero demo:
   "requirements sent from your phone in the morning; OpenClaw pings you
   the finished diff summary by evening."
3. Hermes-side listing: an example integration contributed to their
   community docs; Hermes ships as the first non-default engine adapter.
4. GitHub topics (`openclaw`, `hermes-agent`, `multi-agent`,
   `ai-orchestration`) + PRs to the relevant awesome-lists.
5. Rule: integrations are optional dependencies — upstream churn can delay
   an adapter, never the launch.

## Verification findings (empirical)

- `codex exec` headless verified (3.6 s; resume + review subcommands exist).
- `agy -p` headless verified (3.8 s; ALL flags before `-p`; print-mode
  auto-denies tools → inline-diff review verified working with zero
  permissions; stdin acceptance untested — test in v0).
- agy models list includes gemini flash/pro tiers + claude + gpt-oss.
- **To verify in v0/v1:** `claude -p` full tick; codex-as-orchestrator
  subprocess/git under sandbox (capability suite exists because this is
  unproven); `codex exec review` explicit range support (fallback: plain
  exec with review prompt); range-diff triviality detection.
- **Review history:** round 1 (codex 10, agy 8), round 2 (codex 10, agy 9,
  internal 5), round 3 three-way (codex 10 incl. 3 critical, agy focused 9 +
  agy comprehensive 10 incl. 1 critical, internal 10), round 4 three-way on
  the platform+memory spec (codex 10 incl. 2 critical — verdict "not yet
  normative", agy 9 incl. 1 critical — verdict "conditional approve",
  internal 6). v5 reconciles round 4: normative process model with epochs
  and fencing, complete file→verb ownership table, operation-discriminated
  request/envelope unions with materialized input packs, complete decision
  matrix with kernel-derived actor identity, structured lessons with
  lifecycle verbs and run rollover, reconcile-first bounded resume,
  milestone reorder (foundation before failover), risk_tier /
  blocking_severity split, three-actor remote topology, spinning
  false-positive guard, research-grounding pillar map. v4 incorporates:
  plugin trust model, kernel launcher, request/envelope binding,
  capability-based role resolution, archetype meta-invariants, kernel-owned
  hooks, unconditional rebase re-verification, stale-lock recovery, worktree
  contamination guard, operator verbs, scaffold verification, attempt
  fairness, threat model, plugin lockfile, platform statement. Rejected with
  rationale: OS-level plugin containment in v1 (declared trusted-code
  instead, containment roadmapped); central plugin registry (provenance +
  pinning without a registry); polling-only loop (round 1, still rejected).

## Future (beyond v1)

Usage/cost ledger · per-task engine routing · resource auto-allocation ·
chunk-and-aggregate inline reviews · OS-level plugin containment profiles ·
baseline-aware test comparison. (Status page and service packaging are v1-m4
core — no longer future.)
