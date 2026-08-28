# Orchid — Plugin Specification

*Normative. One of four documents split from the design spec; see [2026-07-24-orchid-design.md](./2026-07-24-orchid-design.md) for the index and orientation.*

## Plugin architecture

Everything outside the kernel is a plugin; **the built-ins are plugins**
(same discovery, same contracts — if a built-in needs a private API, the
design has failed). Kernel code never branches on a plugin's name; behavior
differences are declared capabilities.

### Trust model (the part that makes "any engine" safe to say)

- Executable plugins are **trusted code** — orchid v0/v1 does not sandbox
  them, and says so plainly rather than implying containment it doesn't
  have. Full containment (per-plugin sandbox profiles enforced by the
  launcher) is post-v1 roadmap.
- Consequently: plugins load ONLY from user-controlled locations —
  `~/.orchid/plugins/` and the orchid installation's `plugins/` — plus
  explicit `$ORCHID_PLUGIN_PATH` entries (colon-delimited, each entry a
  directory whose children are `<kind>/<name>/`).
- **Repo-local plugins (`<target-repo>/.orchid/plugins/`) are DISABLED by
  default.** Enabling one requires `orchid plugins trust <path>` (v1), which
  records the plugin's SHA-256 digest in `~/.orchid/trust` — OUTSIDE the
  repo. A digest mismatch (e.g. after a pull) de-trusts it. Cloning a repo
  must never grant code execution.
- **No silent shadowing:** duplicate plugin IDs across the search path are
  an ERROR reported by doctor, never a precedence win. IDs are qualified
  (`publisher/name`, built-ins under `orchid/`); names matching `..`,
  containing slashes beyond the qualifier, or resolving through symlinks
  outside their root are rejected.
- `orchid doctor` reports every discovered plugin's origin, trust status,
  and any collision BEFORE anything executes.
- **Kernel launcher hygiene (v1):** all plugin executables are launched by
  the kernel with stdin from `/dev/null` (kills a whole class of hidden
  interactive hangs: SSH/GPG/LFS prompts), an environment allowlist
  (secrets are opt-in per plugin via manifest `permissions`), a
  kernel-chosen private output location, and the invocation request document
  below. Vendor-CLI sandbox flags (workspace-write, read-only) remain the
  engine-level second layer. Hygiene is not syscall, network, or command
  containment.
- **Whole-repository unattended trust is separate from plugin trust.**
  `orchid trust unattended <repo> --reason <reason>` records an
  operator-authored acknowledgement under
  `~/.orchid/unattended-trust/`, never in tracked content. It binds Git
  common-directory device/inode, a non-reusable hard-link witness identity,
  root commit(s), and policy version. It gates the pump, direct headless tick,
  and service installation; it does not enable a repo-local plugin or assert
  that repository prompts are safe.

### Extension points and contracts

| Kind | Contract | Stage |
|---|---|---|
| **engine** | executable `run`; receives a request document; writes an envelope to the kernel-specified spool path; declares atomic capabilities | v0 (seam), v1 (manifests) |
| **archetype** | data-only workflow declaration validated against kernel invariants (below) | feature v0; review v1-m1; refactor/test/migrate v1-m3 — SHIPPED |
| **notify channel** | `send <question-id> <text>`; inbound via `orchid answer` | v1-m4 — SHIPPED |
| **hook** | named lifecycle hook handlers with typed payloads (below) | v1-m3 — SHIPPED |
| **role** | descriptor: required/forbidden capabilities + hook bindings | v1-m3 — SHIPPED |

Front-ends (Claude skill, headless tick, a future TUI) are a documented
CONVENTION — anything that executes PROTOCOL.md through verbs — not a
discovered plugin kind.

**Engine invocation — request document + input pack.** The tier-2 launcher
invokes `<plugin>/run <request.json>`. Requests are a discriminated union on
`operation` (`implement | review | critique | research | hook | orchestrate`
— the headless tick itself uses the same contract). Common fields:

```json
{ "request": 1, "job_id": "j-<nonce>", "run_id": "r-003", "epoch": 17,
  "task": "T001", "attempt": 3, "role": "reviewer", "operation": "review",
  "base_sha": "...", "candidate_sha": "...",
  "input_pack": "<abs dir>", "output": "<abs path in spool>",
  "worktree": "<abs path|null>", "deadline_s": 3600,
  "policy": "read-only|workspace-write", "model": "...", "effort": "medium" }
```

**The input pack** replaces path-guessing entirely: the kernel materializes
a per-job directory containing exactly the memory that role receives (per
the injection table in kernel.md, Memory & resumption), with a `pack.json` manifest listing every artifact,
its byte count and digest, and everything OMITTED for budget. Budgets are
concrete: 64 KB total default (per-role overridable); correctness-critical
inputs (task body, acceptance criteria, the diff for reviews) are
NON-TRUNCATABLE — if they alone exceed budget, the launch fails with
`input_overflow` rather than silently truncating; journal/lessons/context
trim in that order (journal tail-first, context head-first), and every trim
is recorded in the manifest. **Overflow classification:** `input_overflow`
is first a TASK-SHAPING signal — the orchestrator's prescribed response is
to split the task (journaled `plan_revision`), not raise the budget;
chunked review is a post-v1 fallback, and a raised budget is an operator
decision in config. **Visibility honesty:** worktree-capable
engines can physically read the whole checkout, including committed
`.orchid/` state — the pack defines what they are GIVEN, the execution
policy defines what they may DO, and review independence never rests on
secrecy. **Worktree-read review packs:** a review/critique diff larger than
`pack_diff_inline_max_bytes` (config, default 262144) is not, in itself, an
overflow — when the RESOLVED engine declares `workspace_read`, the pack
swaps the inline `diff.patch` for `diff.stat` (stat summary + name-status:
enough to navigate the checkout directly) and records the omission
honestly in `pack.json` (`{"name":"diff.patch","omitted":"worktree-read"}`).
An inline-only engine gets no such relief — a diff that large still hits
`input_overflow` exactly as above, since it has no other way to see it.

One adapter serves many roles by branching on `operation` — no pseudo-engine
identities. Adapters never guess paths, never choose output locations, exit
nonzero on detectable failure.

**Result envelope (versioned; fail closed).** Written atomically to the
request's `output` path:

```json
{ "contract": 1, "job_id": "j-<nonce>", "task": "T001", "attempt": 3,
  "engine": "orchid/codex", "role": "reviewer",
  "status": "ok|failed|rate_limited|timeout|auth|malformed",
  "failure_kind": "capability|engine",
  "base_sha": "...", "candidate_sha": "...", "session_id": "...",
  "started_at": "...", "ended_at": "...", "retry_after": null,
  "verdict": "approve|request-changes|n/a", "scope_complete": true,
  "findings": [ { "severity": "...", "title": "...", "detail": "..." } ],
  "diagnostics": { "trajectory_log": "<path>" } }
```

**Envelopes are the same union:** per-operation required payloads on top of
the common fields — `review` → `verdict`, `scope_complete`, `findings[]`;
`critique` → `findings[]`; `research` → `citations[]` + `summary`;
`implement` → `commits[]` (SHAs produced) + `summary`; `hook` → typed
artifact per hook schema; `orchestrate` → `actions[]` (the verb invocations
the tick performed, for audit). An `ok` missing its operation's required
payload is `malformed`.

**A non-approve verdict must carry a finding.** `findings[]` is the only
field any severity gate reads. An `ok` `review`/`critique` that withholds
approval while reporting `findings: []` has therefore put its objection
somewhere no gate can weigh it — free-text `summary` — and every
severity-based decision downstream is then made against an empty array. Such
an envelope is still ACCEPTED (the shipped verdict-only adapters write
`findings: []` verbatim on every review, so refusing it would quarantine
legitimate objections), but `orchid jobs reconcile` composes ONE finding from
the summary as it files it, at `severity: high` — the one value no task's
`blocking_severity` filters out — tagged with a `source` of
`orchid:synthesized-from-summary` and `synthesized: true`, and with the
summary kept whole in `detail`. Reconcile prints a `synthesized-finding:`
line naming the filed envelope when it does. An adapter that files its own
findings is never touched, so the way to keep severity yours is to report it.

**`failure_kind` — a refusal is not a fault (v1-m5).** Optional, and
meaningful only on a non-`ok` envelope (`capability` or `engine`; absent means
`engine`, so every adapter written before this field keeps its exact
meaning). An adapter sets `capability` when it declined the request BY DESIGN
— an operation it never claimed (`agy` handed `implement`, `codex-review`
handed anything outside review/critique), a plan pack it has no prompt shape
for, a diff over its own inline byte cap (`agy_max_bytes`,
`hermes_max_bytes`). Such an envelope is the adapter working correctly: it
read the request, recognized it as outside its declared envelope, and said so
naming the limit and the remedy. `engine` (or absence) is the ordinary case —
the engine crashed, timed out, lost its auth, or answered something
unparseable. The status itself stays `failed`/`malformed`, so nothing
downstream changes: the envelope is still not review evidence and the slot is
still relaunched. What changes is the LEDGER: `lib/ledger.sh` charges a
consecutive failure for the second kind and never for the first (see Engine
availability & role failover below). A `failure_kind` on an `ok` envelope, or
any value outside the two, fails validation and is quarantined.

**One status is the kernel's, not an adapter's: `no_envelope`.** It marks a
DEGRADED envelope `orchid jobs reconcile` writes itself for a job that exited
without producing one, reconstructed from results left in the job's log
(`degraded: true`, plus `exit_code` and `salvaged_from`). An adapter that
writes it is not reporting its own status but impersonating the kernel's
account of one, so reconcile quarantines any spool envelope carrying it
(`kernel-status`) on the same anti-forgery terms as any other bad binding.
No gate treats a `no_envelope` envelope as evidence — it is not `ok` — so it
recovers work without ever passing for a review, a delivery or a hook result.

**Binding rules (anti-forgery):** `job_id` is kernel-minted per launch
(distinct from the logical rework `attempt`); reconciliation accepts an
envelope ONLY if a live manifest matches its `job_id`, and takes engine
identity, role, task, and SHAs from the MANIFEST, cross-checking the
envelope; any mismatch, replay (already-reconciled job_id), oversize, or
schema violation → quarantine, never acceptance. "Tests pass" is
established solely by `orchid verify`, never by envelope claims (engine
trajectories are diagnostics).

**Manifest (`plugin.conf`, v1) — a real compatibility contract:**

```
manifest_version=1
id=orchid/codex            # qualified, immutable
version=0.3.0
kind=engine
api_version=1              # per-kind contract version
requires_orchid=>=0.2
capabilities=structured_text,workspace_write,shell,git
permissions=               # env vars / secrets requested (opt-in)
requires_binaries=codex,jq
platforms=macos,linux
command_surface=soft       # kind=engine only: brokered | soft (v1.1)
entrypoint=run
requires_config=           # kind=notify only: config keys the entrypoint
                           # cannot run without (v1-m4)
inbound_probe=             # kind=notify only: argv token for the read-only
                           # inbound probe mode (v1-m4, optional)
```

**`command_surface` (v1.1, kind=engine only) — an honest label, not a
capability.** It answers exactly one question: when this adapter runs the
ORCHESTRATOR role headlessly, can it enforce which commands the model may
execute?

- `brokered` — yes. The adapter restricts its orchestrator to
  `runners/orchid-orchestrator-command`, the default-deny,
  argument-validating broker that admits judgment-only forms (exact reads,
  `orchid task arbitrate`, `journal add`, `lessons add`, `notify`, `run
  boundary clear`) and refuses everything else with exit 17. This is
  vendor-enforced on WHICH command runs; it is not OS containment, and the
  broker itself is unsandboxed. It says nothing about FILE WRITES: the
  shipped brokered adapter runs under `--permission-mode acceptEdits`, whose
  file-write tools stay open over every path the process can reach —
  `.orchid/` and, in a layout where `ORCHID_ROOT` sits inside the driven
  repository, the broker script itself. The prompt's "never hand-edit
  `.orchid/`" is policy, not enforcement.
- `soft` — no. The vendor CLI offers no restriction Orchid can rely on, so
  the orchestrator's reach is bounded only by launcher environment hygiene,
  by the operator's machine-local unattended acknowledgement, and by the
  orchestrate prompt the adapter hands it. That last bound is asked for, not
  enforced — but it is the SAME judgment-boundary contract the broker
  enforces, so boundary policy classifies a `soft` surface against that same
  verb set, never against "every verb is reachable" (see
  [kernel.md](./kernel.md)'s `command_surface` section for why the wider
  reading suppressed the operator blocker).

An absent value reads as `soft`: this field may weaken its own claim by
omission, never strengthen it. `runners/orchid-tick` prints the resolved
engine's label on every headless tick, so the distinction is visible in a
pump log rather than only in documentation. Both kinds stay gated behind
`orchid trust unattended`.

Unknown keys in a known `manifest_version`: warn. Unknown
`manifest_version`/`api_version`: reject (fail closed). `requires_orchid`
(semver-ish `>=`, compared on major.minor only) is checked against the
running kernel's version: unsatisfied → reject (fail closed), same as an
unknown `manifest_version`/`api_version`. `orchid plugins validate` checks
all of this; `orchid version` prints the kernel version (`ORCHID_VERSION`)
that `requires_orchid` checks compare against.

**SHIPPED in v1-m1:** the manifest schema + validation above (including the
`requires_orchid` check), the capability model and role descriptors, the
digest-pinned trust store (INV-09), kernel launcher hygiene, the
capability-suite runner, the plugin lockfile, and the full `orchid plugins
list/validate/trust/test/lock/verify-lock` verb set plus `orchid version` —
all implemented and tested, not merely specified. Deferred to later
milestones: a real filesystem-write capability probe (m1's
`workspace_write_probe` is dryrun-only; a real-write probe is post-m1), and
hooks + custom-role registration — SHIPPED in v1-m3, per the Hooks and
Custom role registration sections below.

**Custom role registration (v1-m3 — SHIPPED):** a `role.<id>=` binding for
any id outside the built-in five resolves a `kind=role` plugin — a
`descriptor.role` file (same key=value shape as a manifest: `id`,
`requires=<cap,cap,...>`, optional `hook_bindings=<point>:<plugin-id>,...`)
discovered on the identical search path as engines (`lib/roles.sh`).
`orchid doctor` FAILs if a configured `role.<id>` binding's descriptor isn't
discoverable, exactly like an engine binding that doesn't resolve. Every
`role.<id>` binding, built-in or custom, additionally accepts a sibling
`role.<id>.blocking=false` (default `true`): a failed non-blocking role's
job is journaled and the run continues rather than infra-failing
(docs/specs/operations.md's optionality-is-binding-policy rule).

**Plugin lifecycle (v1-m3 — SHIPPED):** `orchid plugins install <src>
[--kind <k>]` (src is a local dir or a git URL; installs to
`~/.orchid/plugins/<kind>s/<name>`, kind/name always DERIVED from the
manifest; refuses an INV-10 collision against the WHOLE discovery search
path, not just the destination), `orchid plugins update <name>` (re-fetches
from the recorded `.provenance` source, builds into a temp dir, swaps in
atomically), `orchid plugins remove <name>`, and `orchid plugins audit`
(reports drift: content modified since install, or a tampered
`.provenance`). Every installed/updated plugin dir carries a `.provenance`
file (`source=`, `ref=`, `sig=` — `sig=` binds the two lines above it, so an
edited `source=`/`ref=` with no matching `sig=` is detectable tampering, not
silently trusted) and an `installed_digest=` computed by
`plugin_digest_content` (path-independent: hashes relative `./...` paths so
a digest computed in a temp build dir still matches once swapped into its
final location — unlike the trust-store/capsuite digests, which
deliberately stay path-bound).

**Conformance kit (v1-m3 — SHIPPED):** `orchid plugins conform <plugin-dir>`
runs a fixed seven-check battery (`manifest_valid`,
`entrypoint_executable`, `declared_ops_dryrun`, `stdin_closed_safe`,
`no_output_pollution`, `env_survives_hygiene`, `exit_discipline`) against a
plugin directory directly — no `.orchid`, no role/resolver lookups, no
repo state at all, so a third-party author can run it before ever
installing or binding the plugin to anything. Every check invokes the
plugin's own entrypoint under `ORCHID_DRYRUN=1`: it never spends real quota
or shells out to a vendor CLI. `declared_ops_dryrun` also catches an
operation-echo bypass — a stub that reports the SAME operation in its
envelope no matter which one was actually requested fails this check rather
than passing it. `orchid plugins conform` is a distinct gate from `orchid
plugins test <engine> <role>`: `test` is the ROLE-PAIRING capability suite
(needs a real repo, resolves the role×engine combination, writes a durable
result) that decides whether a binding may activate; `conform` is a
zero-state CONTRACT preflight an author runs standalone, with nothing
durable written. `docs/extending/first-engine.md` (a full adapter-authoring
walkthrough) and `docs/extending/conformance.md` (the seven-check
reference) ship alongside.

**Role & capability model (breaks the circularity):** engines declare atomic
capabilities (`structured_text`, `workspace_read`, `workspace_write`,
`shell`, `git`, `network`, `citations`, …). Role descriptors — including the
core five, which ship as descriptors like any custom role — declare required
(and optionally forbidden) capabilities. The resolver computes eligibility:
adding a `researcher` role never requires editing engine manifests. Core
role IDs are normalized (`orchestrator`, `implementer`, `reviewer`,
`arbiter`, `plan_critic`); config keys are `role.<id>`; **risk-tier routing
is policy on top of the reviewer role** (`review.low=...`,
`review.high=...`), not separate role names.

**Archetype meta-contract (kernel invariants no archetype can override):**
archetypes are data-only (states, transitions, templates, lens text — no
executable predicates) and are validated before activation: every path to a
code-merging terminal MUST pass `testing` (verify) and `reviewing`; retry
bounds are mandatory; terminal states are `done` and `blocked`; declared
`outcome: code|report` — `report` archetypes (like review) may skip
implement/merge but can never advance the integration branch. Unreachable
states are rejected.

**Hooks (v1-m3 — SHIPPED — one mechanism for custom roles AND middleware):**
a finite, kernel-owned set of named extension points — `after_plan_draft`,
`before_arbitration`, `on_verify_fail`, `before_merge`, `on_blocker` — each
with a typed request payload, ordering, timeout, and required/optional
semantics. Handlers are plugins invoked through the same launcher and
request/envelope contracts; their results are validated artifacts applied
ONLY through tier-1 verbs (e.g. a `researcher` consulted `before_arbitration`
returns citations that the tick attaches via `orchid task set`). PROTOCOL.md
itself is never edited by plugins. Shipped machinery: `hook.<point>` config
bindings (an ordered, comma-separated list of plugin NAMEs — the short
discovery name a binding resolves through `resolve_engine_dir`; a qualified
id like `acme/foo` is not accepted in a binding in v1 — `:required` marking a
handler whose failure blocks the edge — `lib/hooks.sh`'s `hooks_for`/
`hook_point_valid`); `orchid jobs prepare <task> hook hook --hook <point>`
(the `hook` operation, resolved by binding rather than by role chain) and
`runners/orchid-launch ... --hook <point>`; `hook_timeout_s` (config,
default 600s) as the per-hook-job wall-clock budget; hook envelopes filed at
`.orchid/reviews/<task>-a<attempt>-hook-<point>.json`. `before_merge` is the
ONE point the kernel itself also enforces: a `:required` entry with no fresh
`ok` envelope for the task's current `candidate_sha` makes `orchid merge`
refuse outright (exit 15); the other four points are read and applied by the
orchestrator's own PROTOCOL.md walk, never a kernel-verb gate.
`on_verify_fail`'s artifact reaches durable state through exactly one field,
`orchid task set <id> hook_guidance "..."` (kernel.md's frontmatter schema).
A plan-scoped hook job (task id `plan`, e.g. `hook.after_plan_draft`) receives
the PLAN pack (`lib/pack.sh`'s `_pack_build_plan`) by design, not the
per-point hook pack — `pack_build` routes on the reserved `plan` task id
before it ever checks the `hook` operation, since there is no `task.md` for
the per-point builder to read in the first place.

### Notify channel plugins (v1-m4 — SHIPPED)

A `kind=notify` plugin has no request/envelope contract (unlike engine/hook
plugins) — its manifest declares only the usual identity/version/platform
fields plus `entrypoint=send`; `send <question-id> <text>` is invoked with a
kernel-hygienic environment (env allowlist, stdin `/dev/null`, same
`spawn_child_env` discipline the launcher itself uses) and exits nonzero on
failure. Two built-ins ship: `plugins/notify/openclaw` and
`plugins/notify/hermes`.

**The outbox pattern (INV-01-clean):** `orchid notify` is tier-1 and must
never spawn — when `notify.channel` is configured, it only WRITES
`runtime/outbox/<qid>` (the fully-composed message text, nonce included).
`runners/orchid-pump` (tier-2) drains the outbox on every pass — including a
fresh-lease pass that would otherwise exit immediately, since a channel send
must never wait for a tick — spawning the resolved plugin's `send` directly
(not through `runners/orchid-launch`; the pump is already tier-2). A failed
send bumps a `.tries` sidecar and is retried on the next pass; after
`send_retry_max` (config, default 5) consecutive failures the message is
quarantined (`<qid>.reason-send-failed`) rather than retried forever —
`BLOCKERS.md` + terminal remains the complete surface regardless.

**Two independent config axes:** `notify.plugin` (default `openclaw`)
selects WHICH `kind=notify` plugin DIRECTORY the pump launches, resolved by
directory name on the same search path as any other plugin — never a
manifest id (the hermes notify plugin's own id, `orchid/hermes-notify`, is
deliberately distinct from the `kind=engine` hermes adapter's `orchid/
hermes`, precisely so this selector never confuses the two). `notify.to`
stays a target address, unchanged by this selector; `notify.channel` stays
each PLUGIN's OWN inner enum/target string (OpenClaw's own channel name, or
a hermes platform name) — a separate axis from which plugin sends it.

**`requires_config=` (optional, v1-m4 T006):** a comma list of CONFIG KEYS
this plugin's entrypoint cannot run without. The kernel gates on
`notify.channel` alone (nothing is ever sent without it), but what else a
send needs is per-plugin and only the plugin knows it: `plugins/notify/
openclaw`'s `send` does `to=${ORCHID_NOTIFY_TO:?…}` and declares
`requires_config=notify.channel,notify.to`, while `plugins/notify/hermes`
treats an empty `notify.to` as "the platform's home channel" and declares
only `notify.channel`. `orchid doctor` checks the declared keys before
reporting outbound `ok`, so a missing one is caught where an operator can
see it rather than as five silent retries and a quarantined message.

**The inbound probe (`inbound_probe=`, optional, v1-m4 T006):** sending and
receiving are different facts with different requirements, and doctor must
never infer the second from the first (see docs/specs/operations.md's
remote-interaction seam). A plugin that CAN determine whether its channel is
reachable declares the single ARGV TOKEN that puts its own `entrypoint` into
a read-only probe mode:

```
inbound_probe=--inbound-probe     # doctor runs: <entrypoint> --inbound-probe
```

The mode takes no other arguments, gets the same kernel-hygienic environment
`send` does (`env -i` + the launcher's `spawn_child_env`, stdin `/dev/null`,
`ORCHID_NOTIFY_CHANNEL`/`ORCHID_NOTIFY_TO` exported), must not send
anything, and answers with its EXIT CODE plus one line of human-readable
detail on stdout:

| exit | meaning |
| --- | --- |
| `0` | reachable — positively determined the channel transport is up |
| `1` | unreachable — positively determined it is down |
| `2` (or anything else, or doctor's 10s timeout) | undetermined, with a reason |

It is a mode of the existing entrypoint rather than a second executable on
purpose: the entrypoint is the one file whose executable bit orchid already
validates, and a mode-644 helper is invisible until the feature silently
stops working. A plugin that cannot determine liveness simply OMITS the key,
and doctor then reports "not verified" for that plugin specifically —
"there is no way to tell" must never be asserted on behalf of a plugin that
can in fact tell. Even exit `0` is bounded: it proves the transport a reply
travels over, never that a channel-side agent exists there to turn a reply
into an `orchid answer` call.

### Named patterns (the codebase vocabulary)

Verb kernel · Envelope · Adapter · Runner · Archetype · Ledger · Spool ·
Lease · Request document · Plugin trust record · Unattended trust record ·
Hook.

## Engine availability & role failover (v1-m2 — SHIPPED)

Ledger (`lib/ledger.sh`, `runtime/engines.json`: last status,
`rate_limited_until`, consecutive failures, capability refusals — updated by
`orchid jobs reconcile`'s `ledger_mark` from every accepted/quarantined
envelope, and by `runners/orchid-tick` for the tick's own orchestrator
pick; `rate_limited`
opens a window sized by `rate_limit_backoff_s`, config, default 3600s, or
the envelope's own `retry_after`; `engine_fail_threshold`, config, default
3, is the consecutive-failure count that flips an engine to `failing`;
`orchid status`'s `== engines` section reads it back) + primary→secondary
preference pairs per role in config (`role.<role>=<primary>,<fallback>,...`
— defaults: `role.orchestrator` claude→codex; `role.implementer`
codex→claude; `role.arbiter` claude→codex; `role.plan_critic` any engine
that did not author the plan; reviewers per risk-tier routing) + the
capability gate: `lib/resolver.sh`'s `resolve_role_available` walks the
chain and admits a fallback (engine, role) pair ONLY after it has passed the
role×engine capability suite (filesystem scope, network policy, subprocess,
git, structured output, recovery) — no survivor anywhere in the chain exits
14. The pump (`runners/orchid-pump`): LLM-free heartbeat that launches the
headless tick (`runners/orchid-tick`) on the best available capable
orchestrator engine when the lease is stale (`pump_stale_s`, config,
default 900s = 15 min); mutual exclusion via lease staleness plus epoch
fencing, not flock. Independence rules (kernel.md, Task lifecycle) apply
against the task's recorded `implementer_engine_id` (populated by `orchid
task advance ... testing`). High-risk arbitration waits (bounded by
`arbiter_wait_s`, config, default 14400s = 4h) for the preferred arbiter —
PROTOCOL.md's HEADLESS OPERATION section is normative on the wait/fallback
mechanics; this is orchestrator-followed policy, not a kernel-verb gate.
Model/effort: static per-role defaults in v1; risk×model matrix v1-m4.

**A capability refusal never counts toward `engine_fail_threshold`
(v1-m5).** `ledger_mark` takes the envelope's `failure_kind` (see the
envelope contract above) and, for a `capability` refusal, records the event
without touching the engine's health: `consecutive_failures` and `status` are
left exactly as they were, `last_status` becomes `refused` rather than
`failed`, and a separate cumulative `capability_refusals` count is
incremented. `orchid status`'s engines section shows that count
(`<engine> ok refusals 3`) so a refusal is visible rather than silent — the
reconcile pass that accepted it also prints one `refusal: <task> <engine>
declined by design` line, and the envelope naming the limit is filed durably
under `reviews/`. A `capability` claim on a `rate_limited` envelope is ignored
(there is no fault to reclassify, and it must not shorten a quota window).
Measured on r-002: `agy` refused three review packs whose diffs were ~1% over
`agy_max_bytes`, the ledger read those as three faults and marked it
`failing`, the run's reviewer pool silently dropped to one
session-independent engine, and a reviewer slot was recomputed out from under
a review `agy` had already filed — stranding that task. The refusal count is
deliberately NOT a second disqualifier: an adapter that claimed `capability`
on everything would stay in the rotation, exactly as an adapter that claimed
`ok` on work it never did would — envelopes are self-reports (see Binding
rules), and the answer to a lying plugin is the operator removing it, with
`refusals <n>` in `orchid status` being what makes the lie legible.

## Threat model (consolidated)

| Untrusted input | Boundary | Mitigation |
|---|---|---|
| cloned repo content (incl. `.orchid/plugins/`) | plugin discovery | repo-local disabled by default; digest-pinned trust records outside the repo; no silent shadowing |
| target-repository requirements, tasks, diffs, filenames, and source | unattended orchestrator prompt + shell tool | machine-local per-repository acknowledgement before pump/tick/service; explicit prompt-injection warning; vendor sandbox where available; no command broker yet (T002) and no claim that prompt policy is enforcement |
| plugin executables | trust decision at install | trusted-code classification (stated plainly); launcher hygiene; containment roadmap post-v1 |
| engine output (envelopes) | reconciliation | job_id binding to manifests; schema fail-closed; quarantine on mismatch/replay |
| task/diff content in reviewer prompts | reviewer/arbiter judgment | prompt injection is assumed possible; verdicts are advisory to the arbiter, which reads high-risk diffs itself; verification commands are selected by the operator and their recorded exit/evidence is deterministic, but the commands themselves are repository-specific code and are not made safe by Orchid |
| inbound answers | `orchid answer` | question-id + idempotency; channel adapters get no shell/repo access; nonce + sender allowlist (v1-m4 — SHIPPED): `answer_allowlist` unconfigured leaves the lenient v0 behavior (no nonce, no allowlist check) since no remote answer path exists to attack; once configured, EVERY caller (local or remote) must supply a matching `--nonce`, closing the prior bypass of simply omitting `ORCHID_ANSWER_SENDER` — that env var, when set, additionally requires the identity to appear in the allowlist |
| implementer commits | merge path | worktree contamination guard; review immutability; transactional merge |
| an operator-supplied candidate repository under beta qualification | `scripts/beta-qualify.sh` | read-only against the target; its ONE execution there is the operator's own configured `verify=` command, run to time it with both output streams discarded unread — that command is repository-specific code and this harness does not make it safe, exactly as the reviewer-prompt row above says of verification generally. Evidence is anonymized by construction: no subprocess output is ever copied into a record, so only harness-authored strings, measured numbers, and closed-vocabulary tokens are emitted — the single class of value another program chooses the characters of, a toolchain version or the platform name, must match a pattern authored in the harness or is recorded as `unrecognized`/`other` — and both files are re-scanned for the target/home/scratch/output paths before being left on disk. The harness never acknowledges unattended trust and deliberately requires none of its own — gating it on the record it exists to inform would invert the documented qualify-then-acknowledge order, so the in-place run is disclosed on stderr as it happens instead ([operations.md](./operations.md), which records that decision and the alternatives rejected with it). It never writes inside the target, never contacts a remote, and records what it could not settle as `not-tested` rather than as a pass |
