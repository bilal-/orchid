# orchid/codex — engine guide

Status: **default implementer**; also usable as orchestrator/reviewer/critic
(`role.orchestrator`/`role.plan_critic` fallback chains both list it). This
is the adapter this guide covers: `plugins/engines/codex/run`.

## What the repository acceptance run proves

Orchid's local CI deliberately proves the suite with vendor CLIs unavailable
on `PATH`; it does not spend quota or launch a live Codex session. Thus a green
run proves the kernel and this adapter's stubbed contract do not depend on an
ambient vendor install. The live claims below come from their named
manual/dogfood probes, not from r-002's local acceptance run.

## Install

```sh
npm install -g @openai/codex
codex --version
```

Requires Node.js 22+. (`npm i -g codex` — without the `@openai/` scope — is
the single most common install mistake; it installs the wrong package.)

## Login

Either sign in with your ChatGPT account (Plus/Pro/Team/Edu/Enterprise —
subscription billing, the path orchid's default bindings assume) via the
CLI's own interactive login flow, or set `OPENAI_API_KEY` for API-metered
billing instead. `orchid` never manages this — it only invokes `codex` and
reads its exit code/stdout, exactly like every other engine adapter
(`docs/specs/plugins.md`'s trust model). `orchid doctor` reports a missing
`codex`/`jq` binary or a failed auth probe against this guide
(`plugins/engines/codex/plugin.conf`'s `requires_binaries=codex,jq`).

## Flags orchid uses, and why

Every real invocation from `plugins/engines/codex/run` pipes the prompt via
**stdin** with `-` as the trailing prompt argument, rather than passing it
as a plain argv string:

```sh
printf '%s' "$prompt" | codex exec --sandbox <read-only|workspace-write> \
  -c approval_policy='"never"' --skip-git-repo-check -
```

- **`--sandbox read-only`** (review/critique) — codex cannot write anything;
  the reviewer/critic path is enforced read-only, not just discouraged by
  the prompt.
- **`--sandbox workspace-write`** (implement) — codex may edit files in the
  worktree it was launched against. It runs alongside `approval_policy=never`
  (below) so it never blocks waiting for interactive confirmation.
- **`-c approval_policy='"never"'`** — disables interactive approval
  prompts entirely; combined with the launcher's `stdin </dev/null`
  hygiene, codex cannot hang waiting on a prompt that will never come.
- **`--skip-git-repo-check`** — codex refuses to operate in a git
  worktree it doesn't independently trust ("Not inside a trusted directory")
  by default; every worktree orchid launches codex against is one orchid
  itself created, so this flag is safe and necessary here.
- **Stdin, not argv, for the prompt** — the real-engine dogfood (F2,
  `docs/dogfood-notes.md`) found codex's clap-based arg parser reads a
  leading `-`/`--` argv string (task.md frontmatter starts with `---`) as a
  flag, producing a usage error rather than running the prompt. Piping via
  stdin with `-` as the prompt argument sidesteps this entirely, and lifts
  the `ARG_MAX` ceiling on large prompts for free.

`orchid_run_engine_cli` (`lib/heartbeat.sh`) backgrounds codex directly
(rather than a plain pipe) so the adapter can track its real pid and emit a
liveness heartbeat every `ORCHID_HB_INTERVAL_S` seconds — codex was found to
buffer all output until exit (`tests/probes/probe-stream-buffering.sh`), so
a stall detector watching log-mtime alone would otherwise misjudge a live,
slow-to-flush codex run as hung.

## Implementer: adapter commits, not the engine

Codex under `--sandbox workspace-write` cannot commit its own edits inside
an orchid task worktree — the worktree's git index/gitdir live under the
main repo's `.git/worktrees/<name>/`, outside the sandbox's writable root
(`docs/dogfood-notes.md`'s F3). So the **adapter** (which runs unsandboxed)
stages and commits codex's edits itself after the CLI exits, capturing the
resulting SHA(s) into the envelope's `commits[]`. This is the one contract
every implementer adapter in this codebase follows — see
`plugins/engines/claude/run` for the identical pattern.

## `orchestrate` (headless tick)

Codex can hold the orchestrator role: the adapter feeds it PROTOCOL.md's
full text plus a fixed instruction block naming the concrete `$worktree`/
`$ORCHID_ROOT` paths, and greps its transcript for `ORCHID-ACTION: <command>`
lines to populate the envelope's `actions[]`.

Since v1.1 that instruction block is the **judgment-boundary contract**, not
"execute one tick": `orchid drive` has already run every mechanical step of
the pass, and this adapter is reached for exactly one reason — a boundary
deterministic policy refused to resolve. The block therefore directs the
model to `orchid run boundary show`, the named task and its reviews, and then
exactly one recorded decision (`orchid task arbitrate`, or `orchid notify`
when the boundary is not one it can settle), finishing at `orchid run
boundary clear`. Those verbs, plus `journal add`/`lessons add`, are the whole
admitted set — the same one `lib/drive.sh` classifies a boundary against
(`_DRIVE_SOFT_WRITE_VERBS`), which is why the two are pinned together by a
test: a tick-style prompt here would mean a model woken for a boundary that
policy had already counted as handled, with no blocker raised for the human.
Nothing enforces the list — this adapter declares `command_surface=soft`, so
every "only these verbs" line is prompt policy, unlike the brokered adapter's
vendor-enforced allowlist.

Requires `shell,git`
capabilities (`plugins/engines/codex/plugin.conf` declares both) —
`--sandbox workspace-write` is used for this path too, since a tick needs to
run `git`/`orchid` verbs, not just edit files. That vendor sandbox is a real
filesystem/network policy enforced by Codex, but it is not Orchid command
brokerage: repository content can still prompt-inject a shell-capable model
within the granted sandbox, and `ORCHID-ACTION` transcript lines do not prove
that only reported commands ran. `orchid trust unattended` therefore gates
the headless runner separately; T002, not this adapter, owns any future
broker.

## Known gotchas

- **A leading `-`/`--` in a prompt is a real risk for any argv-based
  invocation** — this is exactly why every prompt this adapter builds is
  delivered via stdin, never argv. If you're writing your own adapter
  against a CLI with a similar argv parser, read `docs/extending/first-engine.md`
  and this section together.
- **`--skip-git-repo-check` is required** the first time codex ever sees
  one of orchid's task worktrees — without it, codex refuses to run at all
  in an untrusted directory.
- **`codex exec review`'s range support is partial**: no two-endpoint
  `base..head` flag exists (`--base <BRANCH>` compares against current
  HEAD/worktree; `--commit <SHA>` is single-commit only) — this is exactly
  why the review/critique path uses plain `codex exec --sandbox read-only`
  with a range-pinned prompt instead of `codex exec review`.
- **`codex-review`** (a separate, capability-restricted engine identity
  wrapping this same adapter) exists specifically for routing a review slot
  to a fresh codex session distinct from whichever codex session implemented
  the task — see [codex-review.md](./codex-review.md).

## Config keys

No codex-specific config keys — see [configuration.md](../configuration.md)
for the general `role.*`/`review.<tier>` routing keys that decide when this
engine is invoked at all.
