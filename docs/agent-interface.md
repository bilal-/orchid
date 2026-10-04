# Agent interface

Orchid's public command surface is designed for LLM callers. The kernel still
owns deterministic transitions, evidence, locking and authorization. Claude
Code, Codex, Hermes and OpenCode share this contract; native frontend registration
is described in [frontends](frontends.md).

The implementation follows all ten [AXI principles](https://axi.md/), reviewed
against [AXI commit `9fb95abba854`](https://github.com/kunchenguid/axi/blob/9fb95abba8546697512ea70befd3c73c445a4cb2/.agents/skills/axi/SKILL.md). This is a local conformance contract,
not third-party qualification or permission for an agent to accept or publish.

| AXI principle | Orchid behavior | Evidence |
| --- | --- | --- |
| 1. Token-efficient output | TOON by default, JSON with `--json`; internal state stays JSON/TSV | format round-trip and command tests |
| 2. Minimal useful fields | Declared list schemas default to three or four useful columns; `--fields` selects available columns | read and command tests |
| 3. Bounded long text | Text previews report original character length; lists report total/shown; `--full` retrieves complete content | command tests |
| 4. Aggregated information | Context includes run, epoch, boundary, task/job counts and grouped status | read tests |
| 5. Definitive empty results | Collections explicitly report count 0 and `0 results` | read tests |
| 6. Agent-ready execution | No prompts, validated flags before effects, stdout errors, success 0/error 1/usage 2; safe repeated mutations and exact-intent receipts | mutation, request and command tests |
| 7. Ambient lifecycle integration | Explicit `orchid setup --frontend …` registers compact read-only context; portable skills remain separately installed | all-four native fixture and installer tests |
| 8. Bare command home | `orchid` reads live context; `orchid --help` discovers commands | read and command tests |
| 9. Next-step guidance | Lists, truncation, boundaries and command results expose relevant retrieval/next actions | read and command tests |
| 10. Scoped help/version | Every command form declares accepted flags, examples and help; `--version`, `-v`, `-V` return the bare version | command and mutation tests |

Use `orchid protocol` to discover canonical procedure sections, and load a section
with `orchid protocol resume --full` when needed. `orchid skill` discovers the
three portable skills. An ambient hook never resumes ownership, reconciles jobs,
kills a process or writes runtime state. Host trust and approvals remain host-owned.

## Output and compatibility

`orchid task list --fields id,status,title --limit 20` limits presentation while
retaining the total count. Bare context defaults to ten rows per collection;
other lists default to 100. `--full` removes presentation limits. Output escaping
follows TOON 4.1; the release gate independently round-trips representative output
with the official decoder. The base kernel requires Bash 3.2, Git and jq.
Optional native integrations use host runtimes: Hermes registration requires
its Python with PyYAML; OpenCode's callback uses its JavaScript host.

`orchid setup` reads registration state. Choose the Claude Code, Codex, Hermes
or OpenCode setup command in [frontends](frontends.md) to register that host.
`orchid setup --frontend all` configures all four profiles, creating missing
profile directories, and requires the Hermes parser. Missing PyYAML or invalid
configuration is refused before any selected profile is edited.

`orchid --raw <command>` or `ORCHID_OUTPUT=raw` preserves the kernel's historical
text/TSV/JSON and domain-specific exit codes. Internal callers and existing kernel
tests use this explicit channel. The public presentation layer maps domain exits
to error 1 and retains the original code as `kernel_exit`; usage remains 2. Raw
output is a compatibility interface, never an authorization bypass. `orchid jobs ls` is a bounded snapshot; `--watch` is available only through the
explicit raw compatibility channel. Supervisor runners retain their documented
lifecycle and require their explicitly authorized intent.

## Exact-intent retries

For effects whose intentional repetition would change ownership or create a new
run, use a stable ID such as `orchid run start --request-id session-20261003`.
The secure user-local receipt binds the physical repository, verb, normalized
arguments, actor and explicit epoch. Repeating that exact intent returns the
recorded result and marks it `replayed` and `result_is_historical`; it does not
claim the current state is unchanged. Every attempt, including a replay, first
checks the installed kernel's stale-root safeguard. Service installation also
rechecks current machine-local authorization for the exact target before any
cache claim or replay; a revoked acknowledgement cannot return cached success.
Changing the intent under the same ID is a usage error 2. Different intentional
operations need different IDs.

An interrupted or concurrent request without a published result is refused.
Inspect current state before choosing a new ID. This refuses uncertainty rather
than promising transactional exactly-once execution across process death. Receipts
are stored in `~/.orchid/requests`; they do not alter project durable state. Plain
reads without request IDs create no receipt. Historical results must never be
used as a fresh ownership or evidence proof.

## Qualification boundary

Tests exercise native Claude/Codex hook JSON, actual host-owned Hermes PyYAML and
actual OpenCode Node callbacks with isolated profiles. They prove registration,
contract shape, read-only context, failure handling and uninstall ownership.
They do not prove third-party usage, authenticated live model completion, or that
a host grants a command approval. The release remains in `1.0.0-beta.x` until the
separate stable-release prerequisites are met.
