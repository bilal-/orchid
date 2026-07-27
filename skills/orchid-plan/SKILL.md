---
name: orchid-plan
description: Draft or revise an orchid run's roadmap from requirements.md before the tick starts — import requirements, draft/critique tasks, commit via orchid plan apply, per PROTOCOL.md's PLANNING procedure. Use when asked to plan, re-plan, or set up tasks for an orchid run.
---

# orchid-plan — draft the roadmap before the run starts

This is a thin front-end for `PROTOCOL.md`. It carries no procedure of its
own; every step it performs is a command named there.

## 1. Locate the orchid root

Resolve `command -v orchid` the same way `bin/orchid` resolves itself
(follow the symlink chain to its real file, then go up one directory):

```sh
self="$(command -v orchid)" || { echo "orchid: not on PATH — see install.sh"; exit 1; }
while [ -L "$self" ]; do
  t="$(readlink "$self")"
  case "$t" in /*) self="$t" ;; *) self="$(dirname "$self")/$t" ;; esac
done
ORCHID_ROOT="$(cd "$(dirname "$self")/.." && pwd)"
```

## 2. Read PROTOCOL.md

`cat "$ORCHID_ROOT/PROTOCOL.md"` — read the **PLANNING** section in full
before doing anything else. It is the actual procedure; this file does not
restate it.

## 3. Execute PLANNING

With `ORCHID_REPO` set to the target repo, run PLANNING's three steps
exactly as PROTOCOL.md specifies them: `orchid requirements import` →
draft tasks (`orchid task create`/`task set`) with the `role.plan_critic`
engine critiquing the draft → `orchid plan apply --reason "..."` to commit.

Once `orchid plan apply` reports `run_status: planning → running`, planning
is over for this run — hand off to the `orchid` skill (THE TICK) or
`orchid-resume` for subsequent sessions.
