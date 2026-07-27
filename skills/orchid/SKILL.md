---
name: orchid
description: Run one orchid tick against the current repo — reconcile jobs, walk the active task's state machine, and dispatch the next role via verbs, per PROTOCOL.md. Use when asked to run/continue/tick an orchid-managed repo.
---

# orchid — run the tick

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

`cat "$ORCHID_ROOT/PROTOCOL.md"` — read the **Preamble** and **THE TICK**
sections in full before doing anything else. They are the actual procedure;
this file does not restate them.

## 3. Execute THE TICK

With `ORCHID_REPO` set to the target repo (default: current directory),
run THE TICK's five steps exactly as PROTOCOL.md specifies them — refresh
the lease, reconcile-then-check, walk the state machine for the one active
task, raise/resolve blockers via `orchid notify`/reading
`.orchid/runtime/answers/`, then `orchid status --explain` +
`orchid run refresh-lease` before yielding.

Repeat until `orchid status --explain` shows nothing left to dispatch this
pass, a blocker is raised, or every task is `done` — in the last case, hand
off to PROTOCOL.md's **COMPLETION** procedure instead of ticking again.

If this is the first action taken in a fresh session against a repo that
already has run state (rather than a continuous loop already in progress),
use the `orchid-resume` skill first — its RESUME procedure is a prerequisite
to ticking, not an alternative to it.
