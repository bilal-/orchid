# Selective task restart

Revision: 3

## Unchanged-contract restart

The second slice adds `orchid task restart <id> --reason "..." [--dry-run]`.
It shares the revision transaction, ownership gates, impact traversal, archive
layout, and execution-generation invalidation. It preserves contract terms and
all contract revisions, including a contract already at its revision cap. The
execution-generation cap still applies. It journals a `task_restart` reason.
Restart accepts no contract-changing flags; `task revise` still requires a
changed contract. Both remain operator-owned and refuse active affected work.

Existing report-outcome tasks can form independent verification branches. For
`A -> B,C -> D`, restarting B reruns B and D while A and C, including their
evidence, remain unchanged. The target candidate is repinned through the normal
report-task interface. A late result for the same candidate is obsolete if it
belongs to the preceding execution generation. This does not add candidate-ready
dependencies, arbitrary nested verification inside active tasks, automatic
restart policy, or autonomous contract replanning.

The in-session design review chose one shared transaction rather than another
reset path. The regression uses real review and arbitration transitions on a
branched graph, a delayed old job, and a fresh replacement job against the same
candidate. It also exercises repeated restarts without increasing contract
revision. No independent reviewer is claimed.

Before these slices, the driver scheduled dependencies but could not reopen completed work when
an upstream task contract changes. Requirements remain immutable after planning.
This first slice revises task acceptance criteria or verification commands within
the existing run requirements; it does not revise those requirements or introduce
arbitrary verification graphs.

## Operator contract

`orchid task revise <id> --acceptance-criteria "..." --reason "..."`
revises that task and restarts its transitive dependents. The optional
`--verification-commands "..."` revises the verification command. At least one
contract field must change. `--dry-run` reports impact without acquiring
ownership or changing state.

Only running or accepting runs may be revised. The actual mutation requires the
current epoch. Each affected task must be idle (`pending`, `rework`, `blocked`,
or `done`), have no outstanding jobs, no unresolved objection, and no uncommitted
work in a recorded worktree. Active execution must finish or be stopped and
reconciled through existing recovery procedures before revision. A completed,
accepted run requires a new run instead.

## Version and execution identity

`contract_revision` changes when a task's own acceptance criteria or verification
command changes. `execution_generation` changes for every invalidated task,
including downstream tasks whose own contract is unchanged. Missing fields mean
revision and generation 1 for compatibility with existing runs.

Affected tasks return to `pending`, retaining their dependency edges and policy
fields. New generations use fresh branches and worktree paths; existing code,
commits, branches, and worktrees are preserved. Restarting work does not revert
code that has already merged. The new execution repairs or extends that code.

The previous task records, review envelopes, verification logs, and review plans
are archived under `.orchid/revisions/<root>-g<generation>/`. Current evidence and
execution-specific markers are withdrawn. Original attempts remain in the archive;
the replacement generation has a fresh bounded attempt budget. Outstanding
objections must be resolved before revision rather than silently cleared.

## Publication and evidence

Use the existing `orchid_commit_durable` detached-worktree, compare-and-swap, and
sync-back mechanism, selecting only durable task, evidence, archive, roadmap,
and journal paths so the live runtime directory keeps its identity. Journal revision intent inside that transaction before
changing task fields. Publish all affected tasks, archives, and any accepting to
running transition in one durable commit. The existing filesystem/Git publication
crash window remains; this is not a new cross-resource atomicity guarantee.

Prepared job manifests pin the task's contract revision, execution generation,
the exact acceptance criteria and verification command, and direct dependency
revisions, generations, candidates, and contract terms. Launch requests
carry the same data. Reconciliation rejects obsolete bindings and enriches filed
evidence from the trusted manifest. Legacy manifests remain valid only against
legacy generation 1 tasks. Already-reconciled job IDs cannot be replayed.

After a task enters revision tracking, semantic fields cannot be changed through
`task set` once execution starts. Version fields are kernel-owned. All harnesses
use the same verbs; the headless judgment broker does not admit contract revision.

## Verification

Exercise rejection and accepting twins for stale epochs, outstanding affected
jobs, dirty or foreign worktrees, objections, branch collisions, malformed
versions, and unchanged contracts. Demonstrate transitive invalidation while an
unrelated branch's state and evidence remain byte-identical. Reopen real completed
work, verify fresh generation dispatch, and reject a delayed old result. Check
dry-run purity and failed publication before accepting the full local CI result.

## Review record

The operator requested review within the current session. No external reviewer
was launched, and this is not an independent crossfire review. The design review
identified three constraints incorporated above: preserve merged history with
fresh execution branches, refuse outstanding jobs rather than racing them, and
retain unresolved-objection authority by refusing revision until resolution.

Implementation review also found and addressed evidence-prefix collisions between
task IDs, historical branch ownership after revision, revision archive retention
across run rollover, and compatibility with orphan-job diagnostics. The focused
fixture uses real verification and merge cycles for both execution generations.

Final review also preserved the legacy rebase safety fence: a versioned task can
only name its canonical execution branch, and rebase derives that identity
independently of task-record pointers. A live-worker fixture verifies that
selective durable publication retains an unrelated log's open-file identity.
A final first-execution fixture reproduced a missing review-directory pathspec
failure; the staging hook now creates that directory before publication. The
regression pairs dirty-checkout refusal with successful revision of the same
clean recorded checkout and checks that its original branch, commit, and
payload survive.
