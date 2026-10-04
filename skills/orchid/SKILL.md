---
name: orchid
description: Continue an Orchid-managed coding project through the deterministic kernel. Use when asked to run, continue or finish Orchid work.
---

Start with `orchid` in the target repository. This read-only, compact view includes the active run, ownership epoch, task/job counts and any decision boundary. Use `orchid context --json` when you need structured data. Never hand-edit `.orchid/`.

If a supervisor is live, observe its context; do not start another owner. In a new interactive session, load `orchid skill orchid-resume --full` and follow its ownership procedure. Pass the returned `ORCHID_EPOCH` explicitly to every fenced mutation.

For routine execution, run the bounded `orchid drive` pass using the configured engine and verification command. The kernel owns reconciliation, dispatch, evidence and merge gates. Repeat only while the returned state permits progress. A decision boundary is a handoff: inspect `orchid run boundary show`; load the relevant canonical `orchid protocol <section> --full` before deciding. Do not clear a boundary, accept a run, push or publish unless the user's intent authorizes that action.

Use focused help (`orchid task show --help`) and selective rows (`orchid task list --fields id,status,title`). Long text is previewed; request `--full` only for the needed record. `orchid protocol` indexes the canonical procedure. At completion, load `orchid protocol completion --full` and verify its evidence before proposing acceptance. Exact retry of an effectful intent may use a stable `--request-id`; a pending receipt requires inspection, not automatic repetition.
