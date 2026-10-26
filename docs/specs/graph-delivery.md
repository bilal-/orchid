# Graph delivery

Orchid adds durable coordination to the coding harness that hosts the session.
The harness still supplies its tools, authentication, and approval rules. Graph
delivery uses the same task records, worker adapters, and public commands as
the original task lifecycle. It does not require a particular host.

## Definition and evidence

Declare tasks during planning, then use `orchid graph enable --reason "..."`.
Enabling requires an unstarted plan with no outstanding jobs. `graph show` and
`graph validate` expose the normalized model. Existing runs adopt graph mode
through an explicit operator replan that invalidates their old evidence.

`depends_on` waits for completed inputs. A report node's `verifies` field names
the candidate it checks. That candidate can become available before its parent
completes; every verifier must complete before the parent can be approved.
Verifiers can have their own verifiers. The combined candidate and completion
milestones must be acyclic. An ordinary dependency on the parent would create
a cycle when the parent also requires that verifier, and is refused.

Each graph report receives an owned checkout of its frozen candidate. Verifiers
never use a parent's writable checkout. Jobs bind the run and requirements
digest, task contract revision, execution generation, attempt, input revisions,
contract terms, and verification target. Old results remain historical evidence;
even an unchanged commit requires fresh evidence after a generation changes.
Approval, merge, and run acceptance enforce required-verifier completion through
public command gates as well as the driver.

For example, after creating the build and report tasks during planning:

```sh
orchid task set CHECK verifies BUILD
orchid task set BUILD repair_budget 2
orchid task set CHECK repair_target BUILD
orchid task set BUILD output_contract '{"contract":1,"artifacts":[{"path":"result.json","schema":{"type":"object","required":["result"]}}]}'
orchid graph validate
orchid graph enable --reason "require independent candidate verification"
```

To change a contract later, a patch can contain
`{"CHECK":{"acceptance_criteria":"Check the revised edge cases"}}`.

## Output contracts

`output_contract` is a versioned JSON definition with `contract: 1`, optional
`envelope_schema`, and optional `artifacts`. The schema supports a bounded
subset: types, required properties, properties, boolean additionalProperties,
items, enum, const, string and array lengths, and numeric bounds. Unsupported
keywords are refused. It does not execute expressions or resolve references.

Artifact entries name literal repository paths and can constrain byte counts,
required literal text, and JSON structure. Checks read committed Git blobs;
working-tree edits, symlinks, directories, and submodules cannot substitute for
committed artifacts. Evidence records commit and content hashes without copying
artifact contents. Inputs must be standard JSON with valid UTF-8.

The shipped native worker adapters receive this mandatory delivery context,
including inherited repair obligations. They retain their standard reply
format. Use committed JSON artifacts for application-specific structured
outputs; custom adapters can supply additional envelope fields.

By default a code node's contract applies to its implement result and a report
node's contract to its review result. Explicit `operations` select other worker
operations. A valid envelope proves its declared shape; independent verification
and mechanical checks supply evidence about the requested behavior.

An artifact defect is candidate rework. A malformed worker reply is a delivery
failure. An unsafe or unavailable candidate is an infrastructure boundary.
Those cases do not share a retry counter or silently downgrade engine capability.
Revalidating a retained candidate produces artifact-only evidence and does not
invent a fresh implementation reply.

## Repair and replanning

A verifier may declare `repair_target` equal to its immediate `verifies` target.
The source declares a finite `repair_budget`. `orchid graph repair <verifier>`
routes current blocking evidence to that source, archives the affected execution
closure, and starts new generations. The source's `repair_rounds` survives those
generations. A machine repair obligation records the failure and its lineage,
travels with subsequent jobs, and requires fresh bound approval to discharge.
An existing unresolved objection remains a judgment boundary. Repair does not
impersonate its author or clear it.

Use `orchid graph replan --patch changes.json --reason "..."` to change an
executing graph. The patch maps task IDs to semantic fields; `null` removes a
node. A previously unused ID creates a pending task through the same archetype
template and role resolver as ordinary task creation. Optional `title` and
`archetype` fields select its initial definition; retired IDs cannot be reused
within the same run. `--requirements requirements.md` revises the run's requirements, and can
be used without a patch. `--dry-run` previews the impact. The operator must
explicitly enumerate outstanding machine obligations in `--resolve-repairs`
when retiring them through a replan; this does not reset repair budgets or
clear objections.

Replanning validates both graphs before mutation. Impact includes old and new
input edges and the ancestors whose verification obligations changed. Changed
contracts receive new revisions; affected executions receive new generations.
Existing immutable candidates can be revalidated in fresh checkouts. A code
checkpoint resumes at testing and a report checkpoint at reviewing. A task
without a candidate starts pending. Old branches and checkouts remain intact.
`task restart` retains contracts and repeats execution; graph-mode `task revise`
uses the same semantic replanning mechanism.

Retained `testing` and `reviewing` checkpoints can be queued before work
starts. They acquire capacity, exclusive/resource reservations, and a budget
anchor atomically after their current inputs are ready. This prevents a
checkpoint from starving its own new dependencies at concurrency one. Its
verifiers cannot consume it before admission. Preparation, binding, and resume
do not refresh an existing admission clock.

A forward integration change confined to `.orchid/` does not require another
source rebase. A candidate already integrated with an equal project tree can
also complete fresh validation without a new code commit. Both paths preserve
the approved candidate identity and compare the actual merged project tree
against it before running final checks or publishing. Real application changes
still rebase and invalidate required verification. File modes, symlinks,
gitlinks and `.orchid-extra` remain part of project identity.

## Recovery and qualification

Graph changes use one recoverable publication transaction. A pending receipt
fences mutations across linked checkouts. Resume reconciles a committed
transaction before advancing the epoch, preserves unrelated runtime files and
the source index, and refuses conflicting edits instead of overwriting them.

The driver can resume between candidate replacement and verifier invalidation.
Waiting ancestors yield only to their required verifier descendants. Their
recorded wait time pauses the task budget; unrelated tasks retain normal
resource and exclusivity constraints.

Local regression tests, dry-run adapter checks, and live vendor qualification
are different evidence. A synthetic live qualification receipt names the source
tree, adapter, CLI version, role, job, candidate, contract, and result. An absent
or unavailable harness remains not tested or blocked; host compatibility does
not imply a shipped worker adapter or live qualification.

Run a bounded real-provider probe with:

```sh
scripts/graph-qualify.sh --live --engine ENGINE --review-engine OTHER_ENGINE --role all --output receipt.json
```

This uses synthetic repositories and a private Orchid configuration. An
ephemeral adapter wrapper restores the existing CLI authentication environment
and enforces its deadline; receipts pin both the source adapter and wrapper.
The full probe exercises fresh postcommit program inputs, a hidden review read,
a seeded defect, ownership resumption, replay refusal, and graph acceptance.
It has a 900-second ceiling, 120 seconds per job, and no retries. Receipts contain
identities, hashes and outcomes; raw prompts, review text and artifact contents
remain private. The qualification read marker leads the reason because Claude's standard
adapter retains its first 200 bytes. Missing read proof and an unproved approval
are reported separately from launch, reconciliation and kernel-transition
refusals. Failure receipts expose status and scope facts without raw review text.
Dry-run or fake-CLI tests do not establish vendor qualification.
