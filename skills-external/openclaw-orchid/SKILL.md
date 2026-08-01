---
name: orchid
description: "Read-only status checks and nonce-verified blocker answers for one orchid-managed repo. Exactly two operations: status and answer -- no shell, no repo file access beyond those two orchid subcommands."
metadata:
  {
    "openclaw":
      {
        "requires": { "bins": ["orchid"] },
      },
  }
---

# orchid (AgentSkill)

Status: **PENDING-VALIDATION** (v1-m4 Task 7, build-only). The frontmatter
shape here (`name`/`description`/`metadata.openclaw`) is verified against
OpenClaw 2026.7.1-2's own installed skills documentation
(`docs/tools/skills.md` in the installed package) and several of its
bundled `SKILL.md` files (e.g. `skills/weather/SKILL.md`,
`skills/healthcheck/SKILL.md`) -- this is a real, checked format, not a
guess. What is NOT yet validated: actually registering this bundle
(`openclaw skills install ...`) and running it end-to-end inside a live
OpenClaw session. That is the live hero-demo dogfood, a later controller
task -- revisit this file then if anything about registration surprises.

This skill authorizes an OpenClaw agent to do exactly two things against
one configured orchid repo, both through the `orchid` CLI, never a raw
shell:

1. **`orchid status`** — read-only. Run it in the configured repo (see
   "Configuration" below) and return its text verbatim. Never pass
   `--html`, never redirect its output anywhere durable — this is a read,
   nothing else.
2. **`orchid answer <qid> <choice> --nonce <n>`** — answers a blocker
   raised by `orchid notify`. `<qid>` and `<n>` (the nonce) both come from
   the inbound notify-channel message itself (its text ends with
   `— reply: orchid answer <qid> <choice> --nonce <nonce>` — copy `<qid>`
   and the real nonce value straight out of that message). `<choice>` is
   whatever the user replied, passed through as ONE opaque argument to
   `orchid answer` — never parsed, split, or re-interpreted by this skill
   first; it is the target repo's own business what a valid choice looks
   like. Before invoking, set `ORCHID_ANSWER_SENDER=<this skill's
   configured sender id>` in the command's environment — every answer
   through this skill carries that identity.

No other orchid verb, and no shell/file access to the repo beyond running
those two commands, is in scope for this skill. Do not run `git`, do not
edit files, do not run any other `orchid` subcommand on the user's behalf
through this skill.

## Configuration (skill-side, set by the operator registering this bundle)

- **Repo path** — the absolute path to the orchid-managed repo `orchid
  status`/`orchid answer` run against (set `ORCHID_REPO` to it, or run both
  commands with that directory as cwd).
- **Sender id** — the exact string this skill sets as
  `ORCHID_ANSWER_SENDER`. The operator must ALSO add this exact string to
  that repo's `answer_allowlist` config (comma list) — `orchid answer`
  refuses any sender not on it. There is no default; an unconfigured sender
  id or a missing allowlist entry means every answer through this skill is
  refused, fail-closed.

## Security posture

- **Exactly two verbs.** `status` (read-only) and `answer` (writes exactly
  one durable choice for one already-existing question — never creates a
  question, never edits a task, never touches git).
- **Hardening turns on the moment a remote path is configured — it is
  NOT opt-in per call.** The target repo's `answer_allowlist` config is
  what decides this, not anything this skill sends. Once that repo has
  `answer_allowlist` set at all: **every** `orchid answer` call for a
  nonce-bearing question requires the correct `--nonce`, full stop —
  whether or not `ORCHID_ANSWER_SENDER` happens to be set on that call.
  There is no way to answer without the nonce by simply omitting the
  sender identity; that would-be bypass is exactly what closed a prior
  design flaw (a caller could previously skip every check just by not
  setting the sender var). `ORCHID_ANSWER_SENDER`, when set, ADDITIONALLY
  requires that identity to be listed in `answer_allowlist` — an operator
  revokes this skill's answering ability entirely by removing its entry
  there, no skill-side change needed. If the target repo has NO
  `answer_allowlist` configured at all, there is no remote path to defend
  in the first place, and `orchid answer` stays in its plain local-terminal
  mode (no nonce needed) — this skill should still always send `--nonce`
  regardless, since it costs nothing and covers the repo turning hardening
  on later without a skill-side update.
- **Nonce, not just a qid.** A qid alone cannot answer anything once
  `answer_allowlist` is configured — `orchid answer` also requires the
  nonce minted specifically for that question, which only ever reaches
  this skill's user via the actual outbound channel message (or, for a
  human at the actual terminal, `BLOCKERS.md`/the `.question` file).
  Guessing or replaying a bare qid cannot answer anything.
- **Expiry.** A question older than `answer_expiry_s` (repo config, default
  86400s) is refused regardless of sender or nonce.
- **No shell, no broader repo access.** This skill never runs an arbitrary
  command, never reads/writes repo files directly, and never invokes any
  `orchid` verb outside the two above — everything else about the run
  (planning, merging, reviewing) stays entirely on the machine running
  `orchid`, reachable only through `BLOCKERS.md` + the terminal
  (docs/specs/operations.md: "the entire remote stack is post-core").
