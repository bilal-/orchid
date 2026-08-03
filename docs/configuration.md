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
| `timeout_minutes` | `60` | repo | v0 |
| `agy_max_bytes` | `100000` | repo or engine worktree | v0 |
| `hermes_max_bytes` | `100000` | repo or engine worktree | v1-m4 |
| `pack_budget_bytes` | `65536` | repo | v0 |
| `pack_diff_inline_max_bytes` | `262144` | repo | v1-m4 |
| `lessons_max_bytes` | `16384` | repo | v1-m3 |
| `spool_max_bytes` | `262144` | repo | v0 |
| `gc_older_than_s` | `86400` | repo | v0 |
| `infra_max` | `3` | repo | v0 |
| `model` | *(empty — engine's own default)* | repo or user | v0 |
| `effort` | `medium` | repo or user | v0 |
| `rate_limit_backoff_s` | `3600` | repo | v1-m2 |
| `engine_fail_threshold` | `3` | repo | v1-m2 |
| `pump_stale_s` | `900` | repo | v1-m2 |
| `pump_interval_s` | `240` | repo | v1-m4 |
| `arbiter_wait_s` | `14400` | repo | v1-m2 |
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
- **`role.*`** — each value is a comma-separated failover chain, primary
  first (e.g. `role.implementer=codex,claude`). A fallback only ever
  activates once it has passed `orchid plugins test <engine> <role>` (the
  capability suite) — `orchid doctor` prints each role's resolved chain and
  labels non-default bindings `unverified` until that suite passes them. See
  the [README's any-engine-any-role matrix](../README.md#any-engine-any-role)
  for the full picture and a worked swap example.
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
