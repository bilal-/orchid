# orchid/codex-review — engine guide

Status: **tested default second reviewer** in `review.medium`/`review.high`'s
dual-review chain (alongside `agy`). Not a separate vendor CLI — this is a
**capability-restricted wrapper** around [`orchid/codex`](./codex.md)'s own
adapter, exposed as a distinct engine identity so a review slot can be
routed to a fresh, engine-independent-labeled codex session distinct from
whichever engine implemented the task.

## Install / login

Nothing separate to install — this engine **is** `codex` (see
[codex.md](./codex.md) for install/login/flags). `plugin.conf`
(`plugins/engines/codex-review/plugin.conf`) declares
`requires_binaries=codex,jq`, same as the underlying adapter; `orchid
doctor` checks it identically.

## What the wrapper actually does

`plugins/engines/codex-review/run` is a two-line script:

```sh
exec env ORCHID_ENGINE_ID=orchid/codex-review \
         ORCHID_ALLOWED_OPS=review,critique \
         "$here/../codex/run" "$@"
```

- **`ORCHID_ENGINE_ID=orchid/codex-review`** — the underlying adapter
  stamps this into every envelope's `.engine` field instead of
  `orchid/codex`, so reconciliation, the ledger, and independence labeling
  all see a genuinely distinct engine identity.
- **`ORCHID_ALLOWED_OPS=review,critique`** — an allowed-ops gate the shared
  `plugins/engines/codex/run` checks **before** its own operation
  dispatch (and before `ORCHID_DRYRUN`): any request naming an operation
  outside this list fails closed with `operation ... not permitted for
  orchid/codex-review`, even though the underlying codex adapter itself
  fully supports `implement`/`orchestrate`. This is why `plugin.conf`
  declares `capabilities=structured_text,workspace_read,git` (no
  `workspace_write`, no `shell`) — the manifest and the runtime gate agree:
  this identity is review/critique-only.

## Why this exists

Risk-tiered dual review (`docs/specs/kernel.md`, Task lifecycle →
Independence) wants, for `medium`/`high` risk tasks, one worktree-capable
reviewer (for depth — able to read the whole checkout, not just an inline
diff) *and* one engine-independent reviewer (a different vendor from
whichever engine implemented the task) in the same review round. A plain
second `codex` binding wouldn't give you engine independence when codex
also implemented the task; wrapping it under a separate qualified id gives
`orchid` a way to launch "codex, but declared and tracked as review-only,"
without duplicating `plugins/engines/codex/run`'s actual logic anywhere.

## Known gotchas

- **Everything in [codex.md](./codex.md) applies here too** (stdin-piped
  prompts, `--skip-git-repo-check`, `--sandbox read-only` for review) —
  this is the exact same code path, just gated and relabeled.
- **`codex-review`'s single-line verdict contract can drop its reasoning**
  on a `request-changes` outcome with no `REASON:` line in the reply — an
  empty `summary`/`findings` is valid per the envelope schema, just less
  useful for the audit trail than agy's own REASON-capture idiom
  (`docs/dogfood-notes.md`, m2 smaller-notes ledger).
- **Independence is about identity, not literal process separation** — a
  `codex-review` job and a `codex` implement job for the same task may
  still share the same underlying vendor account/session state; the
  distinction this wrapper buys is *tracked, declared* independence (ledger,
  reconciliation, doctor's labeling), consistent with
  `docs/specs/kernel.md`'s own session-independence-vs-engine-independence
  distinction.

## Config keys

No `codex-review`-specific config keys — see
[configuration.md](../configuration.md) for the `review.<tier>` chains that
decide when this engine identity is invoked.
