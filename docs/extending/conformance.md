# Plugin conformance battery reference

`orchid plugins conform <plugin-dir>` runs a fixed, seven-check battery
against a plugin directory, with **no repo state at all** — no `.orchid`,
no `orchid.config`, no role or resolver lookups, nothing. It is the plugin
author's own pre-flight: something you can run against a plugin dir on any
machine, before that plugin has ever been installed or bound to anything.

Every check invokes the plugin's own entrypoint under `ORCHID_DRYRUN=1` —
conform **never spends real quota** and never shells out to a real vendor
CLI, no matter which check is running.

Output is one line per check, `ok: <name>` or `FAIL: <name>: <reason>`, in
the fixed order below, followed by a summary line (`N/7 checks passed`).
Exit status is nonzero iff any check FAILed.

```
$ orchid plugins conform ~/src/my-engine
ok: manifest_valid
ok: entrypoint_executable
ok: declared_ops_dryrun
ok: stdin_closed_safe
ok: no_output_pollution
ok: env_survives_hygiene
ok: exit_discipline
7/7 checks passed
```

## The seven checks

### 1. `manifest_valid`

Runs `plugin.conf` through the same validator `orchid plugins validate`
uses (`lib/manifest.sh`'s `manifest_validate` — see docs/specs/plugins.md's
Manifest section for the full schema).

**Common failure modes:** missing or unknown `manifest_version`/
`api_version`; missing `id`/`kind`/`version`; a missing or non-executable
`entrypoint=` for `kind=engine`/`kind=hook`; an unknown capability atom
in `capabilities=`; a `requires_orchid` the running kernel doesn't satisfy.

### 2. `entrypoint_executable`

The manifest's `entrypoint=` key (default `run`) must name a regular,
executable file inside the plugin dir.

**Common failure modes:** the file is missing, or present but not
`chmod +x`'d.

When this check fails, the five checks below are reported as FAILed
("entrypoint not executable, skipped") rather than attempted — each of
them has to spawn the entrypoint to do anything at all.

### 3. `declared_ops_dryrun`

For every operation the manifest's declared capabilities imply, invokes
the entrypoint under `ORCHID_DRYRUN=1` with a minimal request document
naming that operation, then validates the resulting envelope against that
operation's required fields (`lib/envelope.sh`'s `envelope_validate`) AND
asserts the envelope's own `.operation` field echoes back the SAME
operation the request named. That second assertion matters on its own:
`envelope_validate` only checks that `.operation` satisfies whatever union
that field itself claims — it never cross-checks the claim against what
was actually requested. Without it, an adapter that hardcodes one easy
answer (for example, always replying with a valid `review` envelope no
matter what it was asked to do) would validate cleanly on every probe and
pass this check while never actually implementing `implement` or
`orchestrate` at all.

Capability → operation table:

| Manifest declares | Operation probed | Envelope must additionally have |
|---|---|---|
| `workspace_write` | `implement` | `summary` (string) |
| *(always, non-`kind=hook` plugins)* | `review` | `verdict` (`approve`\|`request-changes`), `scope_complete` (bool) |
| `shell` **and** `git` (both) | `orchestrate` | `actions` (array of strings), `summary` |
| `kind=hook` plugins | `hook` **only** | `artifact` (object), `summary` |

A `kind=hook` plugin is probed on `hook` alone — never `review`,
`implement`, or `orchestrate` — because a hook handler's entire contract is
`operation=hook` (docs/specs/plugins.md, Hooks section); it is never
invoked any other way.

**Common failure modes:** the adapter exits nonzero for a declared
operation, writes no envelope at all, writes one missing a required field
for that specific operation, or writes an envelope whose `.operation`
names a DIFFERENT operation than the one actually requested (the
hardcoded-one-answer bug above). The `FAIL` line names every operation
that failed, and for an operation mismatch specifically, both the
requested operation and the one the envelope claimed.

### 4. `stdin_closed_safe`

Invokes the entrypoint with one representative operation (the first one
`declared_ops_dryrun` would probe — `review` for a non-hook plugin, `hook`
for a `kind=hook` plugin) **twice**, each bounded by a 30-second
`with_timeout`:

1. stdin redirected from `/dev/null` — the shape the real kernel launcher
   (`runners/orchid-launch`) actually uses for every plugin it spawns.
2. stdin fully closed (`0<&-`) — a more hostile shape than production ever
   presents, exercised here for extra assurance.

Both invocations must return before the 30-second deadline with a valid
dryrun envelope.

**Common failure modes:** the adapter blocks waiting on input under either
shape — most often because it (or a real CLI it wraps, once you get to
that step) has an interactive prompt that was never disabled.

### 5. `no_output_pollution`

Runs the entrypoint with its working directory set to a fresh scratch
directory and a kernel-chosen output path inside that same scratch
directory, snapshotting the directory tree immediately before and after
the run. Only the requested output file is allowed to still exist
afterward — a tempfile the adapter creates and cleans up before exiting
never shows up in the "after" snapshot at all, so that's implicitly fine
too.

**Common failure modes:** the adapter leaves a stray file (a log, a lock,
a scratch artifact) behind anywhere outside the output path it was given.

### 6. `env_survives_hygiene`

Invokes the entrypoint under `env -i` plus exactly the fixed base
allowlist the real kernel launcher forwards to every plugin
(`lib/spawn.sh`'s `spawn_child_env`: `PATH`, `HOME`, `USER`, `LANG`,
`TERM`, `TMPDIR`, any `LC_*`, any `ORCHID_*`) — with **no** `permissions=`
opt-ins granted, even if the manifest declares some. A dryrun round trip
must still produce a valid envelope under that stripped environment.

**Common failure modes:** the adapter's dryrun path reads (and requires)
an environment variable outside the base allowlist — most often a
credential that should only ever be needed for a *real*, non-dryrun
invocation.

### 7. `exit_discipline`

Sends a request naming an operation no contract recognizes (`bogus`). The
adapter must exit **nonzero** and still write a well-formed envelope whose
`status` is anything **other than** `"ok"`.

**Common failure modes:** the adapter exits `0` for an operation it
doesn't understand (silently "succeeding" at nothing); exits nonzero but
writes no envelope at all; or writes `status: "ok"` for an operation it
never actually performed.

## `conform` vs `plugins test` (capsuite)

| | `orchid plugins conform <dir>` | `orchid plugins test <engine> <role>` |
|---|---|---|
| Gate | **Contract** — does this adapter honor the request/envelope contract at all | **Role-pairing** — is this installed engine eligible, right now, for this specific role |
| Input | a bare plugin directory | an engine **name**, resolved through the discovery search path |
| Repo state | none, ever | none required to run it, but reads/writes `$HOME/.orchid/capsuite/` |
| Durable result | none — nothing is written to disk | `~/.orchid/capsuite/<engine>--<role>.json`, digest-marked fresh/stale, consulted by the failover gate (`resolve_role_available`) before promoting a fallback engine |
| Extra checks beyond the shared dryrun round trip | stdin handling, filesystem discipline, env hygiene, exit discipline on an unsupported op | capability coverage for the specific role, `requires_binaries` actually present on `PATH` |
| Quota | never (`ORCHID_DRYRUN=1` always) | never for its own dryrun check either, but does check for real vendor binaries on `PATH` |
| When to run it | before you ever install the plugin or bind it to anything — an author's own pre-flight, on any machine | after installing, whenever you bind (or are considering binding) an engine to a role, on the operator's own machine |

Run `conform` first, and again every time you touch an adapter's
request/envelope handling — it's fast, needs nothing on disk, and never
spends quota. Run `plugins test` afterward, once the plugin is installed
and you're deciding whether to actually bind it to a role.
