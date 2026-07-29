# Your first orchid engine, in under an hour

This walks a minimal, dryrun-only `sh`-based engine adapter from `mkdir`
to a green `orchid plugins conform`, an `orchid plugins install`, and an
`orchid plugins test` — the full loop a third-party author needs before
ever wiring up a real vendor CLI.

An **engine** plugin is a directory with two things: a `plugin.conf`
manifest (docs/specs/plugins.md, Manifest section) and an executable
**entrypoint** (conventionally named `run`) that reads a JSON request
document as its one argument and writes a JSON result envelope to the path
the request names — the request/envelope contract, also in
docs/specs/plugins.md.

## Step 1 — `mkdir` + manifest (a couple of minutes)

```sh
mkdir -p ~/src/my-engine
cd ~/src/my-engine
cat > plugin.conf <<'EOF'
manifest_version=1
id=acme/my-engine
version=0.1.0
kind=engine
api_version=1
capabilities=structured_text,workspace_read,workspace_write,shell,git
entrypoint=run
EOF
```

- `id=` is `publisher/name` — yours, qualified, immutable once you
  publish it.
- `capabilities=` decides which operations `orchid plugins conform`'s
  `declared_ops_dryrun` check will probe (full table in
  [conformance.md](./conformance.md)): `workspace_write` implies
  `implement`; every non-`kind=hook` plugin is always probed for `review`;
  `shell` **and** `git` together imply `orchestrate`. Declare only the
  capabilities your engine genuinely has — a read-only critique tool would
  drop `workspace_write`/`shell`/`git` entirely and declare
  `capabilities=structured_text,workspace_read`.

## Step 2 — the entrypoint (the bulk of the hour)

A minimal, dryrun-only skeleton is enough to pass every conform check
without touching a real vendor CLI yet:

```sh
cat > run <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
req="${1:?usage: run <request.json>}"
operation="$(jq -r .operation "$req")"
output="$(jq -r .output "$req")"
job_id="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"

write() {  # status extra-json
  local extra="${2:-}"; [ -n "$extra" ] || extra='{}'
  jq -n --arg job_id "$job_id" --arg task "$task" --arg operation "$operation" \
        --arg status "$1" --argjson extra "$extra" \
    '{contract:1, job_id:$job_id, task:$task, operation:$operation, status:$status} + $extra' \
    > "$output"
}

if [ "${ORCHID_DRYRUN:-0}" != "1" ]; then
  write failed '{}'
  exit 1
fi

case "$operation" in
  implement)       write ok '{"summary":"dryrun"}' ;;
  review|critique) write ok '{"verdict":"approve","scope_complete":true}' ;;
  orchestrate)     write ok '{"actions":[],"summary":"dryrun"}' ;;
  *)
    write failed '{}'
    exit 1 ;;
esac
exit 0
EOF
chmod +x run
```

A few things here are load-bearing for conform, worth understanding rather
than just copying:

- **The operation gate runs before anything else, dryrun or not.** An
  operation this adapter doesn't recognize always fails loudly (`write
  failed`, `exit 1`) — never silently. This is exactly what conform's
  `exit_discipline` check verifies.
- **Every branch writes ONLY to `$output`.** No log file, no scratch
  state, nothing else touches disk. conform's `no_output_pollution` check
  runs your adapter in a scratch directory and fails on any file left
  behind that isn't the requested output.
- **Nothing here reads stdin.** There's nothing to hang on. conform's
  `stdin_closed_safe` check invokes your adapter with stdin closed two
  different ways and expects a result well within 30 seconds either way —
  free once your adapter simply never tries to read input it was never
  given.
- **Nothing here reads any environment variable beyond what `jq`/bash
  themselves need.** conform's `env_survives_hygiene` check strips the
  environment down to a fixed base allowlist (`PATH`, `HOME`, `USER`,
  `LANG`, `TERM`, `TMPDIR`, any `LC_*`/`ORCHID_*`) before invoking you, with
  no credentials forwarded — correct for a dryrun round trip, which should
  never need one. Once you wire up a real CLI that needs a credential,
  declare it in `plugin.conf`'s `permissions=` and read it only in the
  **non-dryrun** branch below the `if` above — `env_survives_hygiene` only
  ever exercises the dryrun path, by design.

## Step 3 — `orchid plugins conform` (iterate until green)

```sh
orchid plugins conform ~/src/my-engine
```

```
ok: manifest_valid
ok: entrypoint_executable
ok: declared_ops_dryrun
ok: stdin_closed_safe
ok: no_output_pollution
ok: env_survives_hygiene
ok: exit_discipline
7/7 checks passed
```

Each line is `ok: <check>` or `FAIL: <check>: <reason>`; see
[conformance.md](./conformance.md) for exactly what each of the seven
checks verifies and the most common way to break it. `conform` needs no
repo, no `.orchid` state whatsoever, and never spends real quota
(`ORCHID_DRYRUN=1` for every probe, every time) — run it as often as you
like, anywhere, before you've installed anything at all.

## Step 4 — `orchid plugins install` (a minute)

```sh
orchid plugins install ~/src/my-engine
```

This copies your plugin dir to `$HOME/.orchid/plugins/engines/my-engine`
(the name part of your `id=`), records its provenance, and refuses if the
id collides with anything already discoverable. `orchid plugins install
<git-url>` (including a `file://` URL) works the same way, if you'd rather
publish from a git repo than a local directory.

## Step 5 — `orchid plugins test` (a couple of minutes)

```sh
orchid plugins test my-engine implementer
```

This is a **different** gate than `conform`: `plugins test` resolves your
now-installed engine by **name** through the discovery search path and
runs the role-pairing battery for `implementer` specifically — manifest
validity, capability coverage for that role, `requires_binaries` actually
present on `PATH`, and the same dryrun envelope round trip `conform`
already exercised. It writes a durable pass/fail record to
`~/.orchid/capsuite/my-engine--implementer.json` that the failover gate
consults before ever letting a fallback engine take over a role. See
[conformance.md](./conformance.md)'s "`conform` vs `plugins test`" table
for when to reach for which.

## Step 6 — bind it, then go read the built-ins

To actually use your engine for a role in a repo, set (for example)
`role.implementer=my-engine` in that repo's `orchid.config`.

Everything up to here has been dryrun-only. Wiring a **real** vendor CLI
into the `if [ "${ORCHID_DRYRUN:-0}" != "1" ]` branch — actually calling
out to whatever tool your engine wraps, self-committing an implementer's
edits, producing a real review verdict — is genuinely engine-specific, and
the built-in adapters are the best reading material for the patterns that
come up there:

- `plugins/engines/codex/run` — streaming a real CLI with a liveness
  heartbeat, an implementer self-committing its own edits, classifying
  failures (`rate_limited`/`auth`/`failed`) from CLI output.
- `plugins/engines/claude/run` — the same set of operations against a
  different vendor CLI's own invocation conventions.
- `plugins/engines/agy/run` — a review-only engine with a narrower
  capability set (no `workspace_write`/`shell`/`git`).
- `plugins/engines/codex-review/run` — a capability-restricted *wrapper*
  around another built-in adapter (`ORCHID_ALLOWED_OPS`), for exposing the
  same underlying tool as a second, more restricted engine identity.

Whatever you change, `orchid plugins conform` stays your fast, no-quota,
no-repo feedback loop — run it again after every edit to the entrypoint.
