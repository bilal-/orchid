# openclaw-orchid — AgentSkill bundle

An OpenClaw AgentSkill exposing exactly two operations against one
orchid-managed repo: `orchid status` (read-only) and `orchid answer <qid>
<choice> --nonce <n>`. See `SKILL.md` for the full instruction body and
security posture; this file covers registration.

Status: **PENDING-VALIDATION** (v1-m4 Task 7, build-only) — the `SKILL.md`
frontmatter format is verified against OpenClaw's own installed skills
documentation and several bundled skills (real, checked — not guessed);
actually registering and running this bundle against a live OpenClaw
session has not been done yet. That is the live hero-demo dogfood, a later
controller task.

## Registration

Per `openclaw skills --help` / `openclaw skills install --help` (OpenClaw
2026.7.1-2):

```sh
# Into the active workspace's skills/ directory:
openclaw skills install /path/to/orchid/skills-external/openclaw-orchid --as orchid

# Or, visible to every local agent:
openclaw skills install /path/to/orchid/skills-external/openclaw-orchid --as orchid --global
```

`openclaw skills install` expects `SKILL.md` at the source root (this
directory has it) and derives the slug from its `name:` frontmatter
(`orchid`) unless `--as` overrides it. Confirm it's visible with:

```sh
openclaw skills list --verbose
openclaw skills info orchid
```

## Required operator configuration

This skill is NOT usable out of the box — two things must be set up by
whoever registers it, on BOTH sides:

1. **Skill side** — the repo path this skill's `status`/`answer` commands
   operate against, and the exact sender id string it will set as
   `ORCHID_ANSWER_SENDER` for every answer.
2. **Repo side** (`orchid.config` in the target repo) —
   `answer_allowlist=<the same sender id>`, so `orchid answer` actually
   accepts it. Optionally `notify.channel`/`notify.to` if this same
   OpenClaw instance is also the outbound channel (see
   `docs/engines/openclaw.md`) — that is a separate, independent config
   concern from this skill (the skill answers; the notify plugin sends).

Without both, every `orchid answer` call through this skill is refused,
fail-closed — never silently accepted from an unconfigured or unlisted
sender.

## Security posture (summary — see `SKILL.md` for the full writeup)

- Exactly two verbs: `status` (read-only) and `answer` (writes one choice
  for an already-existing question).
- **Hardening is on whenever a remote path is configured — not opt-in per
  call.** The instant the target repo's `answer_allowlist` is set to
  anything, `orchid answer` requires `--nonce` on EVERY call for a
  nonce-bearing question, regardless of whether `ORCHID_ANSWER_SENDER` is
  set — a caller cannot bypass the nonce check by simply not asserting a
  sender identity. `ORCHID_ANSWER_SENDER`, when set, additionally requires
  allowlist membership. With no `answer_allowlist` configured at all, there
  is no remote path to defend and `orchid answer` stays lenient.
- Sender allowlist (`answer_allowlist`, repo config) — revocable from the
  repo side alone, no skill-side change needed.
- Nonce required for every call once `answer_allowlist` is configured —
  guessing a bare qid cannot answer anything.
- Question expiry (`answer_expiry_s`, repo config, default 86400s).
- No shell access, no repo file access, and no other `orchid` verb is ever
  invoked through this skill.
