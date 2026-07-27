---
name: orchid-resume
description: Resume an orchid run after a crash, restart, or a fresh session — reconcile jobs and load task capsules per PROTOCOL.md's RESUME procedure before continuing the tick. Use when starting a session against an orchid repo that already has run state.
---

# orchid-resume — reconcile and load context before ticking

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

`cat "$ORCHID_ROOT/PROTOCOL.md"` — read the **RESUME** section in full
before doing anything else. It is the actual procedure; this file does not
restate it.

## 3. Execute RESUME

With `ORCHID_REPO` set to the target repo, run that section's steps in
order, exactly as PROTOCOL.md specifies them, then continue into THE TICK's
state-machine walk using the now-reconciled state.

Once RESUME has handed off into THE TICK, subsequent passes are ordinary
ticks — use the `orchid` skill for those; this skill's job ends once the
first tick after resume is under way.
