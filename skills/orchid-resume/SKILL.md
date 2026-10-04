---
name: orchid-resume
description: Recover context and establish interactive ownership of an existing Orchid run. Use when resuming Orchid work in a new agent session.
---

Begin with `orchid` or `orchid context`. These reads do not acquire an epoch, create runtime state, reconcile jobs or kill processes. A live supervisor already owns execution; observe it instead of driving or acquiring competing ownership.

Load `orchid protocol resume --full` before a new session acquires ownership. Inspect the active run, lease, jobs and boundary. Follow the canonical procedure, using `orchid run resume --help` to confirm its exact form. Resume mints a fresh epoch; record the returned number and pass `ORCHID_EPOCH` explicitly on later fenced mutations. Exact-intent retries can use a stable `--request-id`; a pending receipt means inspect state before choosing a new intent.

Run reconciliation only at the procedure's authorized point. Do not infer progress from a stale historical receipt, acknowledge a boundary without its required operator decision, or accept a run solely because tasks say done. Load relevant protocol sections and complete records on demand, then continue through the `orchid` skill. Never hand-edit durable `.orchid/` state. Keep stderr visible and preserve unrelated working trees.
