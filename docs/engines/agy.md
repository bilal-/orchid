# orchid/agy — engine guide

Status: **tested default reviewer** (`review.low=agy`, and one slot of
`review.medium`/`review.high`'s dual-review chain). Review/critique only —
`plugins/engines/agy/plugin.conf` declares `capabilities=structured_text`
alone (no `workspace_write`/`shell`/`git`), so the capability math never
routes `implement`/`orchestrate` to it. This is the adapter this guide
covers: `plugins/engines/agy/run`.

`agy` is the CLI for **Google Antigravity** (`agy`, not `antigravity`, is
the binary name).

## What the repository acceptance run proves

Orchid's local CI deliberately proves the suite with vendor CLIs unavailable
on `PATH`; it does not spend quota or perform a live agy review. Thus a green
run proves the kernel and this adapter's stubbed contract do not depend on an
ambient vendor install. The tested/live status above comes from its named
adapter qualification, not from r-002's local acceptance run.

## Install

```sh
curl -fsSL https://antigravity.google/cli/install.sh | bash
agy --version
```

The installer detects OS/architecture, verifies a checksum, and places the
binary at `~/.local/bin/agy`.

## Login

The first run needs a Google account approved for Antigravity: on a local
machine, `agy` checks the system keyring for an existing session and, if
none is found, opens your browser to a Google sign-in page. On a headless/
SSH session with no browser, it prints an authorization URL instead — open
that URL on any machine with a browser, sign in, and paste the resulting
code back into the SSH terminal. `orchid` never manages any of this — it
only invokes `agy` and reads its exit code/stdout. `orchid doctor` reports
a missing `agy`/`jq` binary or a failed auth probe against this guide
(`plugins/engines/agy/plugin.conf`'s `requires_binaries=agy,jq`).

Antigravity's own model picker (`agy`'s config/setup flow, out of band from
orchid) spans multiple backing models including Gemini Flash/Pro tiers,
Claude, and open-weight (gpt-oss) options — orchid never selects or
overrides this; whatever `agy` is configured to use is what runs.

## The verified invocation

```sh
agy -p "$prompt"
```

- **ALL of agy's own flags must precede `-p`** — this is a real, verified
  constraint of the CLI's own argument parser, not an orchid convention.
  The adapter passes no flags before `-p` today (nothing else is needed),
  but if you're extending this adapter, this ordering rule is the first
  thing to get right.
- **The prompt is a plain trailing argv value, not stdin.** This was
  verified empirically during design: neither `agy -p -` (piped) nor
  `agy -p < file` delivers the prompt to the model — `-` is read as a
  literal/flag-arg error either way. There is no stdin path for this CLI;
  the adapter passes the full prompt (task frontmatter, diff, everything)
  as the single argv string after `-p`. This does mean an oversized prompt
  eventually hits the platform's `ARG_MAX` ceiling — `agy_max_bytes`
  (config, default `100000`) fails the adapter closed on an oversized
  `diff.patch` well before that ceiling is a real risk.
- **Print-mode auto-denies any tool-use attempt, with zero permissions
  configured** — verified working as a real read-only posture for
  inline-diff review. This is *why* agy needs no `--sandbox`/`--permission`
  flag at all: there is nothing to explicitly restrict.

`orchid_run_engine_cli` (`lib/heartbeat.sh`) backgrounds agy directly and
runs a liveness heartbeat alongside it — agy takes its prompt as a plain
argv (no stdin/temp-file plumbing needed the way codex/claude require).

## Why agy needs a real prompt instruction against tool use (F6)

Print-mode auto-denying a tool call is harmless **only** as long as the
model never reaches for one. A real dogfood run found the opposite: agy's
model voted to use a tool, the denial was silent, and agy printed **nothing
at all** to stdout (exit 0, empty reply) — the adapter wrote `malformed`
with zero diagnostics, because nothing captured what had actually happened
(`docs/dogfood-notes.md`'s F6). The fix, now permanent in this adapter:

- Every prompt explicitly instructs "do not use any tools... judge from the
  diff text alone" (agy-style; `plugins/engines/hermes/run`'s prompt
  instruction is modeled directly on this one, though hermes additionally
  backs it with a real toolset restriction agy has no equivalent of).
- A reply with no parseable `VERDICT:` line — including a genuinely empty
  one — dumps the raw reply to **stderr** (which the launcher's job log
  does capture, unlike a local shell variable) before writing the
  `malformed` envelope, so an empty/garbled reply is never silently
  invisible again.

## No plan-critique mode

A `role.plan_critic` binding never resolves to agy in practice (its default
chain doesn't include it), and the adapter itself fails closed rather than
erroring obscurely if it's ever asked to critique a plan pack (no
`task.md`/`diff.patch` to read): "agy has no plan-critique mode — bind an
engine with a plan-critique prompt (codex/claude)."

## Known gotchas

- **Flags-before-`-p`** — see above; get this backwards and the CLI's own
  parser will misread your intended flag as part of the prompt or reject it
  outright.
- **No stdin acceptance** — don't try to pipe a prompt to agy; pass it as
  the trailing argv value, exactly as this adapter does.
- **An empty stdout reply is a real failure mode, not a fluke** — see F6
  above; if you're debugging a `malformed` agy envelope, the job log's
  stderr capture (not stdout) is where the diagnostic lives.

## Config keys

- `agy_max_bytes` (config, default `100000`) — `diff.patch` byte ceiling
  above which this adapter fails closed rather than invoking agy at all
  (no worktree-read fallback exists for an inline-only reviewer). Mirrors
  `hermes_max_bytes` — see [hermes.md](./hermes.md).
