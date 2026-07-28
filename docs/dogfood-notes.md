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
