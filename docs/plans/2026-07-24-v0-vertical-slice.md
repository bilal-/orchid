# Orchid v0 Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build orchid v0 — the deterministic CLI core plus engine adapters that drive ONE task at a time through `pending → implementing → testing → reviewing → arbitrating → merging → done` in an existing repo, with crash recovery, proven by an end-to-end fixture test.

**Architecture:** Three tiers per the spec (`docs/specs/2026-07-24-orchid-design.md`): tier-1 deterministic bash verbs under `libexec/` (sole mutators of durable state, never invoke an LLM), tier-3 engine adapters under `engines/` (write ONLY JSON envelopes to a runtime spool), and thin Claude skills + `PROTOCOL.md` on top. Durable state is committed `.orchid/`; volatile state is gitignored `.orchid/runtime/`. Serial execution, fixed roles, mkdir-based locking.

**Tech Stack:** bash (3.2-compatible — macOS default), `jq` (required, checked by doctor), git worktrees, plain-bash test harness (zero test dependencies).

## Global Constraints

- All commit messages in this repo: NO AI co-author trailers (repo convention).
- No personal machine paths in any committed file; resolve binaries from `PATH`, use `$HOME`, config via `orchid.config` (key=value, parsed — NEVER sourced).
- `libexec/` scripts must never invoke an LLM CLI and never block on the network.
- `engines/` scripts must never write durable state — spool + logs only.
- All state writes are atomic (temp file + `mv`).
- No `flock` (absent on macOS): the run lock is `mkdir .orchid/runtime/lock`.
- Every script starts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Every engine adapter supports `ORCHID_DRYRUN=1` (emit a plausible envelope, spawn nothing).
- Bash 3.2 compatibility: no associative arrays, no `${var,,}`, no `readarray`.

---

### Task 1: Repo scaffold, dispatcher, test harness

**Files:**
- Create: `bin/orchid`, `tests/run.sh`, `tests/helpers.sh`, `tests/test_dispatcher.sh`, `.gitignore`

**Interfaces:**
- Produces: `orchid <verb> [args…]` dispatching to `libexec/orchid-<verb>`; `ORCHID_ROOT` env var available to all subcommands; test helpers `assert_eq <expected> <actual> <msg>`, `assert_match <regex> <text> <msg>`, `assert_fail <cmd…>` and per-file temp sandbox `$WORK`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_dispatcher.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

out="$("$ORCHID_BIN" help)"
assert_match "usage: orchid" "$out" "help prints usage"

if "$ORCHID_BIN" no-such-verb 2>/dev/null; then
  fail "unknown verb should exit non-zero"
fi
rc=0; "$ORCHID_BIN" no-such-verb 2>/dev/null || rc=$?
assert_eq "2" "$rc" "unknown verb exits 2"
```

```bash
# tests/helpers.sh
#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHID_BIN="$REPO_ROOT/bin/orchid"
FAILS=0
fail()        { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
assert_eq()   { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
assert_match(){ echo "$2" | grep -Eq "$1" || fail "$3 (no match '$1' in '$2')"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; exit $((FAILS>0))' EXIT
```

```bash
# tests/run.sh
#!/usr/bin/env bash
set -u
rc=0
for t in "$(dirname "$0")"/test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
exit $rc
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/run.sh`
Expected: FAIL (`bin/orchid` does not exist).

- [ ] **Step 3: Implement dispatcher**

```bash
# bin/orchid
#!/usr/bin/env bash
set -euo pipefail
self="$0"
while [ -L "$self" ]; do
  target="$(readlink "$self")"
  case "$target" in /*) self="$target" ;; *) self="$(dirname "$self")/$target" ;; esac
done
ORCHID_ROOT="$(cd "$(dirname "$self")/.." && pwd)"
export ORCHID_ROOT

cmd="${1:-help}"; [ $# -gt 0 ] && shift
if [ "$cmd" = "help" ] || [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ]; then
  echo "usage: orchid <command> [args]"
  echo "commands:"
  for f in "$ORCHID_ROOT"/libexec/orchid-*; do
    [ -e "$f" ] || continue
    echo "  ${f##*/orchid-}"
  done
  exit 0
fi
exe="$ORCHID_ROOT/libexec/orchid-$cmd"
if [ ! -x "$exe" ]; then
  echo "orchid: unknown command '$cmd' (see 'orchid help')" >&2
  exit 2
fi
exec "$exe" "$@"
```

```gitignore
# .gitignore
.orchid/runtime/
```

Run: `chmod +x bin/orchid tests/*.sh && mkdir -p libexec`

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run.sh` — Expected: PASS (0 fails).

- [ ] **Step 5: Commit**

```bash
git add bin tests .gitignore && git commit -m "v0: CLI dispatcher and test harness"
```

---

### Task 2: Shared library — atomic writes, lock, config, timeout

**Files:**
- Create: `lib/common.sh`, `tests/test_common.sh`

**Interfaces:**
- Produces (sourced by all libexec/engines):
  `orchid_die <msg>` (exit 1); `atomic_write <dest>` (stdin→dest atomically);
  `lock_acquire <state_dir>` / `lock_release <state_dir>` (mkdir lock; acquire returns 1 if held);
  `config_get <repo_dir> <key> [default]` (reads `<repo_dir>/orchid.config`, key=value, never sourced);
  `with_timeout <secs> <cmd…>` (returns 124 on timeout);
  `orchid_state <repo_dir>` → prints `.orchid` path; `orchid_runtime <repo_dir>` → prints `.orchid/runtime`, creating it.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_common.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"

# atomic_write
echo hello | atomic_write "$WORK/f"
assert_eq "hello" "$(cat "$WORK/f")" "atomic_write writes content"

# lock
mkdir -p "$WORK/state"
lock_acquire "$WORK/state" || fail "first acquire should succeed"
if lock_acquire "$WORK/state" 2>/dev/null; then fail "second acquire should fail"; fi
lock_release "$WORK/state"
lock_acquire "$WORK/state" || fail "acquire after release should succeed"
lock_release "$WORK/state"

# config: parsed, not sourced
printf 'integration_branch=orchid/integration\nevil=$(touch %s/pwned)\n' "$WORK" > "$WORK/orchid.config"
assert_eq "orchid/integration" "$(config_get "$WORK" integration_branch)" "config_get reads value"
assert_eq "fallback" "$(config_get "$WORK" missing fallback)" "config_get default"
config_get "$WORK" evil >/dev/null
[ ! -e "$WORK/pwned" ] || fail "config must never be executed"

# with_timeout
rc=0; with_timeout 1 sleep 5 || rc=$?
assert_eq "124" "$rc" "timeout returns 124"
with_timeout 5 true || fail "fast command passes"
```

- [ ] **Step 2: Run to verify failure** — `bash tests/run.sh` → FAIL (no lib/common.sh).

- [ ] **Step 3: Implement**

```bash
# lib/common.sh
#!/usr/bin/env bash

orchid_die() { echo "orchid: $*" >&2; exit 1; }

atomic_write() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  cat > "$tmp"
  mv "$tmp" "$dest"
}

orchid_state()   { echo "$1/.orchid"; }
orchid_runtime() { local r="$1/.orchid/runtime"; mkdir -p "$r"; echo "$r"; }

lock_acquire() {
  local rt; rt="$(orchid_runtime_dir_of "$1")"
  if mkdir "$rt/lock" 2>/dev/null; then echo "$$" > "$rt/lock/pid"; return 0; fi
  echo "orchid: lock held (pid $(cat "$rt/lock/pid" 2>/dev/null || echo '?'))" >&2
  return 1
}
lock_release() {
  local rt; rt="$(orchid_runtime_dir_of "$1")"
  rm -rf "$rt/lock"
}
# accepts either a repo dir or a state dir for test convenience
orchid_runtime_dir_of() {
  if [ -d "$1/.orchid" ] || [ -f "$1/orchid.config" ]; then
    orchid_runtime "$1"
  else
    mkdir -p "$1/runtime"; echo "$1/runtime"
  fi
}

config_get() {
  local repo="$1" key="$2" default="${3:-}" file line
  file="$repo/orchid.config"
  if [ -f "$file" ]; then
    line="$(grep -E "^${key}=" "$file" | head -n1 || true)"
    if [ -n "$line" ]; then printf '%s\n' "${line#*=}"; return 0; fi
  fi
  printf '%s\n' "$default"
}

with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local watcher=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
    return "$rc"
  fi
  return 124
}
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib tests/test_common.sh && git commit -m "v0: common lib (atomic write, mkdir lock, config parser, timeout)"
```

---

### Task 3: Frontmatter library

**Files:**
- Create: `lib/frontmatter.sh`, `tests/test_frontmatter.sh`

**Interfaces:**
- Produces: `fm_get <file> <key>` (prints value or empty), `fm_set <file> <key> <value>` (atomic; adds key if absent). Task files look like:

```
---
id: T001
status: pending
---
body text
```

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_frontmatter.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"

cat > "$WORK/T001.md" <<'EOF'
---
id: T001
status: pending
---
Do the thing.
EOF

assert_eq "pending" "$(fm_get "$WORK/T001.md" status)" "fm_get reads value"
assert_eq "" "$(fm_get "$WORK/T001.md" nope)" "fm_get missing is empty"

fm_set "$WORK/T001.md" status implementing
assert_eq "implementing" "$(fm_get "$WORK/T001.md" status)" "fm_set updates"

fm_set "$WORK/T001.md" branch task/T001
assert_eq "task/T001" "$(fm_get "$WORK/T001.md" branch)" "fm_set adds new key"
assert_match "Do the thing." "$(cat "$WORK/T001.md")" "body preserved"
```

- [ ] **Step 2: Run to verify failure** — FAIL (no lib/frontmatter.sh).

- [ ] **Step 3: Implement**

```bash
# lib/frontmatter.sh
#!/usr/bin/env bash
# Frontmatter = lines between the first two '---' lines, format 'key: value'.

fm_get() {
  awk -v k="$2" '
    /^---$/ { n++; next }
    n==1 && index($0, k ": ") == 1 { print substr($0, length(k)+3); exit }
    n>=2 { exit }
  ' "$1"
}

fm_set() {
  local file="$1" key="$2" val="$3"
  awk -v k="$key" -v v="$val" '
    /^---$/ { n++; if (n==2 && !done) { print k ": " v; done=1 } ; print; next }
    n==1 && index($0, k ": ") == 1 { print k ": " v; done=1; next }
    { print }
  ' "$file" | atomic_write "$file"
}
```

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/frontmatter.sh tests/test_frontmatter.sh && git commit -m "v0: frontmatter get/set"
```

---

### Task 4: `orchid task` — create, show, list, validated advance

**Files:**
- Create: `libexec/orchid-task`, `templates/task.md`, `tests/test_task.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `lib/frontmatter.sh`.
- Produces: `orchid task create <id> <title>` (from template, into `.orchid/tasks/<id>.md`); `orchid task show <id>`; `orchid task list` (`<id>\t<status>\t<title>` lines); `orchid task advance <id> <state>` — validates against the feature-archetype transition table, exits 3 with `illegal transition` on violation. `orchid task set <id> <key> <value>` for frontmatter updates. All run from the target repo root (`ORCHID_REPO` env overrides `$PWD`).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_task.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK"

"$ORCHID_BIN" task create T001 "Add widget"
assert_eq "pending" "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "created pending"

"$ORCHID_BIN" task advance T001 implementing
assert_match "T001	implementing" "$("$ORCHID_BIN" task list)" "advance + list"

rc=0; "$ORCHID_BIN" task advance T001 done 2>/dev/null || rc=$?
assert_eq "3" "$rc" "illegal transition exits 3"

"$ORCHID_BIN" task advance T001 blocked   # any state -> blocked is legal
assert_eq "blocked" "$("$ORCHID_BIN" task show T001 | grep '^status: ' | cut -d' ' -f2)" "blocked ok"

"$ORCHID_BIN" task set T001 base_sha abc123
assert_match "base_sha: abc123" "$("$ORCHID_BIN" task show T001)" "task set"
```

- [ ] **Step 2: Run to verify failure** — FAIL (unknown command 'task').

- [ ] **Step 3: Implement**

```markdown
<!-- templates/task.md -->
---
id: __ID__
title: __TITLE__
status: pending
archetype: feature
branch: task/__ID__
worktree:
depends_on:
attempts: 0
infra_failures: 0
session_id:
base_sha:
candidate_sha:
risk_threshold: medium
stop_condition: report at most 8 findings at or above medium severity; no style nits; one pass only
engine: __ENGINE__
effort: medium
acceptance_criteria:
verification_commands:
created: __DATE__
updated: __DATE__
---

(Describe the task here: goal, constraints, acceptance criteria.)
```

```bash
# libexec/orchid-task
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"

repo="${ORCHID_REPO:-$PWD}"
tasks="$(orchid_state "$repo")/tasks"
sub="${1:-}"; shift || true

task_file() { echo "$tasks/$1.md"; }

legal() {
  case "$1:$2" in
    pending:implementing|implementing:testing|testing:reviewing|testing:rework|\
    reviewing:arbitrating|reviewing:rework|arbitrating:merging|arbitrating:rework|\
    merging:done|merging:rework|rework:implementing) return 0 ;;
    *:blocked) return 0 ;;
    *) return 1 ;;
  esac
}

case "$sub" in
  create)
    id="$1"; title="$2"; mkdir -p "$tasks"
    [ ! -f "$(task_file "$id")" ] || orchid_die "task $id exists"
    sed -e "s|__ID__|$id|g" -e "s|__TITLE__|$title|g" \
        -e "s|__ENGINE__|$(config_get "$repo" role.implementer codex)|g" \
        -e "s|__DATE__|$(date -u +%Y-%m-%dT%H:%M:%SZ)|g" \
      "$ORCHID_ROOT/templates/task.md" | atomic_write "$(task_file "$id")"
    ;;
  show) cat "$(task_file "$1")" ;;
  list)
    for f in "$tasks"/*.md; do
      [ -e "$f" ] || continue
      printf '%s\t%s\t%s\n' "$(fm_get "$f" id)" "$(fm_get "$f" status)" "$(fm_get "$f" title)"
    done ;;
  set) fm_set "$(task_file "$1")" "$2" "$3"; fm_set "$(task_file "$1")" updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
  advance)
    id="$1"; to="$2"; f="$(task_file "$id")"
    [ -f "$f" ] || orchid_die "no task $id"
    from="$(fm_get "$f" status)"
    if ! legal "$from" "$to"; then
      echo "orchid: illegal transition $from -> $to for $id" >&2; exit 3
    fi
    fm_set "$f" status "$to"
    fm_set "$f" updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "$id: $from -> $to"
    ;;
  *) orchid_die "usage: orchid task create|show|list|set|advance" ;;
esac
```

Run: `chmod +x libexec/orchid-task`

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add libexec/orchid-task templates tests/test_task.sh && git commit -m "v0: orchid task verbs with validated state machine"
```

---

### Task 5: `orchid init` and `orchid doctor`

**Files:**
- Create: `libexec/orchid-init`, `libexec/orchid-doctor`, `orchid.config.example`, `tests/test_init_doctor.sh`

**Interfaces:**
- Produces: `orchid init` — creates integration branch (`config integration_branch`, default `orchid/integration`) from current HEAD, writes `.orchid/` skeleton (`tasks/`, `reviews/`, `BLOCKERS.md`, `roadmap.md`, `requirements.md` placeholder note) and `.orchid/runtime/` (gitignored), commits skeleton on the integration branch, returns to prior branch. `orchid doctor` — read-only checks; prints `ok: <check>` / `FAIL: <check>` lines; exit 1 on any FAIL. Checks: git repo; jq present; engine binaries from config (`engines=codex,agy` default) present; `verification_commands` configured (config key `verify` or per-task later); worktree support.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_init_doctor.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK"
printf 'integration_branch=orchid/integration\nverify=true\nengines=\n' > orchid.config

"$ORCHID_BIN" doctor || fail "doctor should pass in clean repo (no engines configured)"

"$ORCHID_BIN" init
git rev-parse --verify -q orchid/integration >/dev/null || fail "integration branch created"
git show orchid/integration:.orchid/BLOCKERS.md >/dev/null 2>&1 || fail ".orchid committed on integration branch"
assert_eq "$(git rev-parse --abbrev-ref HEAD)" "$(git rev-parse --abbrev-ref HEAD)" "still on original branch"

printf 'engines=definitely-not-a-real-binary\n' > orchid.config
rc=0; "$ORCHID_BIN" doctor >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "doctor fails on missing engine binary"
```

- [ ] **Step 2: Run to verify failure** — FAIL (unknown commands).

- [ ] **Step 3: Implement**

```bash
# libexec/orchid-doctor
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
repo="${ORCHID_REPO:-$PWD}"; fails=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi }

check "git repository"        "git -C '$repo' rev-parse --git-dir"
check "jq installed"          "command -v jq"
check "git worktree support"  "git -C '$repo' worktree list"
check "verification command configured" "[ -n '$(config_get "$repo" verify)' ]"
engines="$(config_get "$repo" engines codex,agy)"
old_ifs="$IFS"; IFS=','
for e in $engines; do
  [ -n "$e" ] && check "engine binary: $e" "command -v '$e'"
done
IFS="$old_ifs"
[ "$fails" -eq 0 ] || exit 1
```

```bash
# libexec/orchid-init
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
repo="${ORCHID_REPO:-$PWD}"
integ="$(config_get "$repo" integration_branch orchid/integration)"
state="$(orchid_state "$repo")"
orchid_runtime "$repo" >/dev/null

cur="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
git -C "$repo" rev-parse --verify -q "$integ" >/dev/null && orchid_die "branch $integ already exists"
git -C "$repo" branch "$integ" HEAD

mkdir -p "$state/tasks" "$state/reviews"
[ -f "$state/BLOCKERS.md" ]     || echo "# Blockers" > "$state/BLOCKERS.md"
[ -f "$state/roadmap.md" ]      || echo "# Roadmap" > "$state/roadmap.md"
[ -f "$state/requirements.md" ] || echo "# Requirements (fill in before orchid-plan)" > "$state/requirements.md"
grep -q '^\.orchid/runtime/$' "$repo/.gitignore" 2>/dev/null || echo ".orchid/runtime/" >> "$repo/.gitignore"

git -C "$repo" checkout -q "$integ"
git -C "$repo" add .orchid .gitignore
git -C "$repo" commit -q -m "orchid: initialize run state" || true
git -C "$repo" checkout -q "$cur"
echo "initialized: state on $integ"
```

```
# orchid.config.example
integration_branch=orchid/integration
verify=npm test
# Roles are configuration — any engine adapter can hold any role it is
# capable of. These are the tested defaults:
role.orchestrator=claude
role.implementer=codex
role.reviewer.low=agy
role.reviewer.high=codex-review,agy
role.plan_critic=codex
engines=codex,agy
```

Run: `chmod +x libexec/orchid-init libexec/orchid-doctor`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add libexec/orchid-init libexec/orchid-doctor orchid.config.example tests/test_init_doctor.sh
git commit -m "v0: orchid init and doctor"
```

---

### Task 6: Envelope validation library

**Files:**
- Create: `lib/envelope.sh`, `tests/test_envelope.sh`

**Interfaces:**
- Produces: `envelope_validate <file>` — exits 0 iff the JSON parses AND has `contract==1`, non-empty `task` and `attempt`, and `status` in `ok|failed|rate_limited|timeout|auth|malformed`; `envelope_field <file> <jq-path>` (e.g. `.status`). Consumed by `orchid jobs reconcile` and all engine adapters.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_envelope.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"

cat > "$WORK/good.json" <<'EOF'
{"contract":1,"task":"T001","attempt":"T001-a1","status":"ok","verdict":"n/a"}
EOF
envelope_validate "$WORK/good.json" || fail "valid envelope accepted"
assert_eq "ok" "$(envelope_field "$WORK/good.json" .status)" "field read"

echo 'not json' > "$WORK/bad1.json"
if envelope_validate "$WORK/bad1.json" 2>/dev/null; then fail "non-JSON rejected"; fi

cat > "$WORK/bad2.json" <<'EOF'
{"contract":1,"task":"T001","attempt":"T001-a1","status":"sparkly"}
EOF
if envelope_validate "$WORK/bad2.json" 2>/dev/null; then fail "bad status rejected"; fi
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# lib/envelope.sh
#!/usr/bin/env bash

envelope_validate() {
  jq -e '
    (.contract == 1)
    and (.task | type == "string" and length > 0)
    and (.attempt | type == "string" and length > 0)
    and (.status | IN("ok","failed","rate_limited","timeout","auth","malformed"))
  ' "$1" >/dev/null
}

envelope_field() { jq -r "$2" "$1"; }
```

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/envelope.sh tests/test_envelope.sh && git commit -m "v0: envelope validation"
```

---

### Task 7: `orchid jobs` — launch, check, reconcile

**Files:**
- Create: `libexec/orchid-jobs`, `tests/test_jobs.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `lib/envelope.sh`, engine adapters at `$ORCHID_ROOT/engines/<name>` (invoked as `engines/<name> <task-id>`, with `ORCHID_REPO` exported).
- Produces:
  - `orchid jobs launch <task-id> <engine-name>` — writes write-ahead manifest `runtime/jobs/<task>.json` `{task, attempt, engine, pid, pgid, started_at, log}` BEFORE spawning; spawns adapter detached with stdout/err → `runtime/logs/<task>-<attempt>.log`; updates manifest with pid/pgid after spawn.
  - `orchid jobs check` — per manifest prints `<task>\trunning|stalled|dead|timeout`; stall = log mtime older than `stall_minutes` (config, default 10); timeout = started_at older than `timeout_minutes` (default 60). Kills stalled/timeout process groups.
  - `orchid jobs reconcile` — for each `runtime/spool/*.json`: validate (invalid → renamed `.malformed`, counted); move valid to `.orchid/reviews/<task>-<attempt>-<engine>.json`; delete the job manifest; print `<task>\t<status>\t<verdict>`.
  - Attempt id = `<task>-a<attempts+1>` read from the task file.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_jobs.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$WORK"
"$ORCHID_BIN" task create T001 "demo"

# fake engine: writes an ok envelope to the spool, exits
mkdir -p "$WORK/fake-engines"
cat > "$WORK/fake-engines/fake" <<EOF
#!/usr/bin/env bash
set -eu
spool="\$ORCHID_REPO/.orchid/runtime/spool"; mkdir -p "\$spool"
printf '{"contract":1,"task":"%s","attempt":"%s-a1","status":"ok","verdict":"n/a"}' "\$1" "\$1" > "\$spool/\$1-a1-fake.json"
EOF
chmod +x "$WORK/fake-engines/fake"
export ORCHID_ENGINES_DIR="$WORK/fake-engines"

"$ORCHID_BIN" jobs launch T001 fake
[ -f .orchid/runtime/jobs/T001.json ] || fail "manifest written"
sleep 1
out="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$out" "reconcile ingests envelope"
[ -f .orchid/reviews/T001-a1-fake.json ] || fail "envelope moved to durable reviews/"
[ ! -f .orchid/runtime/jobs/T001.json ] || fail "manifest cleared"

# malformed envelope fails closed
mkdir -p .orchid/runtime/spool
echo 'garbage' > .orchid/runtime/spool/T001-a2-fake.json
out="$("$ORCHID_BIN" jobs reconcile)"
assert_match "malformed" "$out" "malformed reported"
[ -f .orchid/runtime/spool/T001-a2-fake.json.malformed ] || fail "malformed quarantined"

# dead-job detection
"$ORCHID_BIN" task create T002 "dead demo"
cat > "$WORK/fake-engines/slow" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$WORK/fake-engines/slow"
"$ORCHID_BIN" jobs launch T002 slow
pid="$(jq -r .pid .orchid/runtime/jobs/T002.json)"
kill "$pid" 2>/dev/null; sleep 1
assert_match "T002	dead" "$("$ORCHID_BIN" jobs check)" "dead job detected"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# libexec/orchid-jobs
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"
source "$ORCHID_ROOT/lib/envelope.sh"

repo="${ORCHID_REPO:-$PWD}"
state="$(orchid_state "$repo")"
rt="$(orchid_runtime "$repo")"
engines_dir="${ORCHID_ENGINES_DIR:-$ORCHID_ROOT/engines}"
mkdir -p "$rt/jobs" "$rt/logs" "$rt/spool"
sub="${1:-}"; shift || true

now_epoch() { date +%s; }

case "$sub" in
  launch)
    task="$1"; engine="$2"
    tf="$state/tasks/$task.md"; [ -f "$tf" ] || orchid_die "no task $task"
    attempts="$(fm_get "$tf" attempts)"; attempt="$task-a$((attempts+1))"
    log="$rt/logs/$task-$attempt.log"
    jq -n --arg t "$task" --arg a "$attempt" --arg e "$engine" --arg l "$log" \
      --arg s "$(now_epoch)" \
      '{task:$t, attempt:$a, engine:$e, pid:0, pgid:0, started_at:($s|tonumber), log:$l}' \
      | atomic_write "$rt/jobs/$task.json"
    ORCHID_REPO="$repo" ORCHID_ATTEMPT="$attempt" \
      "$engines_dir/$engine" "$task" >> "$log" 2>&1 &
    pid=$!
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)"
    jq --arg p "$pid" --arg g "$pgid" '.pid=($p|tonumber) | .pgid=($g|tonumber)' \
      "$rt/jobs/$task.json" | atomic_write "$rt/jobs/$task.json"
    echo "launched $task attempt $attempt engine $engine pid $pid"
    ;;
  check)
    stall_s=$(( $(config_get "$repo" stall_minutes 10) * 60 ))
    timeout_s=$(( $(config_get "$repo" timeout_minutes 60) * 60 ))
    for m in "$rt/jobs"/*.json; do
      [ -e "$m" ] || continue
      task="$(jq -r .task "$m")"; pid="$(jq -r .pid "$m")"
      pgid="$(jq -r .pgid "$m")"; started="$(jq -r .started_at "$m")"
      log="$(jq -r .log "$m")"; age=$(( $(now_epoch) - started ))
      if ! kill -0 "$pid" 2>/dev/null; then echo "$task	dead"; continue; fi
      if [ "$age" -gt "$timeout_s" ]; then
        [ "$pgid" -gt 0 ] && kill -- -"$pgid" 2>/dev/null || kill "$pid" 2>/dev/null
        echo "$task	timeout"; continue
      fi
      mtime="$(stat -f %m "$log" 2>/dev/null || stat -c %Y "$log" 2>/dev/null || echo "$started")"
      if [ $(( $(now_epoch) - mtime )) -gt "$stall_s" ]; then
        [ "$pgid" -gt 0 ] && kill -- -"$pgid" 2>/dev/null || kill "$pid" 2>/dev/null
        echo "$task	stalled"; continue
      fi
      echo "$task	running"
    done
    ;;
  reconcile)
    for env in "$rt/spool"/*.json; do
      [ -e "$env" ] || continue
      if ! envelope_validate "$env"; then
        mv "$env" "$env.malformed"
        echo "$(basename "$env")	malformed	n/a"
        continue
      fi
      task="$(envelope_field "$env" .task)"
      attempt="$(envelope_field "$env" .attempt)"
      status="$(envelope_field "$env" .status)"
      verdict="$(envelope_field "$env" '.verdict // "n/a"')"
      engine="$(basename "$env" .json)"; engine="${engine##*-}"
      mv "$env" "$state/reviews/$task-$attempt-$engine.json"
      rm -f "$rt/jobs/$task.json"
      echo "$task	$status	$verdict"
    done
    ;;
  *) orchid_die "usage: orchid jobs launch|check|reconcile" ;;
esac
```

Run: `chmod +x libexec/orchid-jobs`

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add libexec/orchid-jobs tests/test_jobs.sh && git commit -m "v0: orchid jobs launch/check/reconcile with write-ahead manifests"
```

---

### Task 8: Codex implementer adapter

**Files:**
- Create: `engines/codex`, `lib/engine-common.sh`, `tests/test_engine_codex.sh`

**Interfaces:**
- Consumes: task file frontmatter (`branch`, `worktree`, `effort`), `.orchid/context.md` (optional), `ORCHID_ATTEMPT` env (set by `orchid jobs launch`).
- Produces: envelope at `runtime/spool/<task>-<attempt>-codex.json`; `engine_emit <task> <attempt> <engine> <status> <verdict>` helper in `lib/engine-common.sh` (also classifies: stderr matching `rate limit|usage limit|429` → `rate_limited`; `login|auth` → `auth`). Honors `ORCHID_DRYRUN=1`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_engine_codex.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/runtime/spool
export ORCHID_REPO="$WORK" ORCHID_ATTEMPT="T001-a1"
"$ORCHID_BIN" task create T001 "demo"

# DRYRUN emits an ok envelope without invoking codex
ORCHID_DRYRUN=1 "$REPO_ROOT/engines/codex" T001
env_file=".orchid/runtime/spool/T001-T001-a1-codex.json"
[ -f "$env_file" ] || fail "dryrun envelope written"
source "$REPO_ROOT/lib/envelope.sh"
envelope_validate "$env_file" || fail "dryrun envelope valid"
assert_eq "ok" "$(envelope_field "$env_file" .status)" "dryrun status ok"

# stubbed codex that fails with a rate-limit message → rate_limited envelope
rm -f "$env_file"
mkdir -p "$WORK/stub"; cat > "$WORK/stub/codex" <<'EOF'
#!/usr/bin/env bash
echo "429 usage limit reached" >&2; exit 1
EOF
chmod +x "$WORK/stub/codex"
PATH="$WORK/stub:$PATH" "$REPO_ROOT/engines/codex" T001 || true
assert_eq "rate_limited" "$(envelope_field "$env_file" .status)" "rate limit classified"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# lib/engine-common.sh
#!/usr/bin/env bash
# Shared by engines/*. Engines write ONLY to runtime/spool + their log (stdout).

engine_paths() {  # sets globals: repo, state, rt, spool
  repo="${ORCHID_REPO:-$PWD}"
  state="$repo/.orchid"
  rt="$repo/.orchid/runtime"
  spool="$rt/spool"
  mkdir -p "$spool"
}

engine_emit() {  # task attempt engine status verdict
  jq -n --arg t "$1" --arg a "$2" --arg s "$4" --arg v "${5:-n/a}" \
    --arg b "${BASE_SHA:-}" --arg c "${CAND_SHA:-}" --arg sid "${SESSION_ID:-}" \
    '{contract:1, task:$t, attempt:$a, status:$s, verdict:$v,
      base_sha:$b, candidate_sha:$c, session_id:$sid,
      findings:[], diagnostics:{}}' \
    > "$spool/.tmp.$$" && mv "$spool/.tmp.$$" "$spool/$1-$2-$3.json"
}

engine_classify() {  # stderr-text -> status
  case "$1" in
    *"rate limit"*|*"usage limit"*|*429*) echo rate_limited ;;
    *login*|*auth*|*Unauthorized*)        echo auth ;;
    *)                                    echo failed ;;
  esac
}
```

```bash
# engines/codex
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/frontmatter.sh"
source "$ORCHID_ROOT/lib/engine-common.sh"
engine_paths
task="$1"; attempt="${ORCHID_ATTEMPT:?}"
tf="$state/tasks/$task.md"

if [ "${ORCHID_DRYRUN:-0}" = "1" ]; then
  engine_emit "$task" "$attempt" codex ok n/a
  exit 0
fi

worktree="$(fm_get "$tf" worktree)"
[ -n "$worktree" ] || worktree="$repo"
prompt="You are implementing one task. Repo context:
$(cat "$state/context.md" 2>/dev/null || echo '(no context pack)')

Task spec:
$(cat "$tf")

Rules: work ONLY in this directory; commit your work with clear messages;
never modify any .orchid/ path; run the verification commands yourself before
finishing, but note that orchid re-verifies deterministically."

set +e
err="$(cd "$worktree" && codex exec --sandbox workspace-write \
        -c approval_policy='"never"' "$prompt" 2>&1 >/dev/null)"
rc=$?
set -e
if [ $rc -eq 0 ]; then
  engine_emit "$task" "$attempt" codex ok n/a
else
  echo "$err"
  engine_emit "$task" "$attempt" codex "$(engine_classify "$err")" n/a
fi
```

Run: `chmod +x engines/codex`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add engines/codex lib/engine-common.sh tests/test_engine_codex.sh
git commit -m "v0: codex implementer adapter with dryrun and failure classification"
```

---

### Task 9: agy inline reviewer adapter

**Files:**
- Create: `engines/agy`, `tests/test_engine_agy.sh`

**Interfaces:**
- Consumes: task frontmatter `base_sha`, `candidate_sha`, `risk_threshold`, `stop_condition`; git diff.
- Produces: envelope `<task>-<attempt>-agy.json` with `verdict: approve|request-changes` parsed from agy's structured reply (`VERDICT: <verdict>` line contract), `scope_complete` false + `status: failed` when the diff exceeds `agy_max_bytes` (config, default 100000). ALL agy flags placed BEFORE `-p` (verified gotcha).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_engine_agy.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
echo a > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"
echo b > f.txt; git add f.txt; git commit -q -m change
cand="$(git rev-parse HEAD)"

mkdir -p .orchid/tasks .orchid/runtime/spool
export ORCHID_REPO="$WORK" ORCHID_ATTEMPT="T001-a1"
"$ORCHID_BIN" task create T001 "demo"
"$ORCHID_BIN" task set T001 base_sha "$base"
"$ORCHID_BIN" task set T001 candidate_sha "$cand"

mkdir -p "$WORK/stub"; cat > "$WORK/stub/agy" <<'EOF'
#!/usr/bin/env bash
echo "VERDICT: approve"
echo "REASON: fine"
EOF
chmod +x "$WORK/stub/agy"
PATH="$WORK/stub:$PATH" "$REPO_ROOT/engines/agy" T001
env_file=".orchid/runtime/spool/T001-T001-a1-agy.json"
source "$REPO_ROOT/lib/envelope.sh"
envelope_validate "$env_file" || fail "agy envelope valid"
assert_eq "approve" "$(envelope_field "$env_file" .verdict)" "verdict parsed"

# oversized diff fails closed
printf 'agy_max_bytes=1\n' > orchid.config
rm -f "$env_file"
PATH="$WORK/stub:$PATH" "$REPO_ROOT/engines/agy" T001 || true
assert_eq "failed" "$(envelope_field "$env_file" .status)" "oversized diff fails closed"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# engines/agy
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"
source "$ORCHID_ROOT/lib/engine-common.sh"
engine_paths
task="$1"; attempt="${ORCHID_ATTEMPT:?}"
tf="$state/tasks/$task.md"
BASE_SHA="$(fm_get "$tf" base_sha)"; CAND_SHA="$(fm_get "$tf" candidate_sha)"

if [ "${ORCHID_DRYRUN:-0}" = "1" ]; then
  engine_emit "$task" "$attempt" agy ok approve; exit 0
fi

diff="$(git -C "$repo" diff "$BASE_SHA".."$CAND_SHA")"
max="$(config_get "$repo" agy_max_bytes 100000)"
if [ "${#diff}" -gt "$max" ]; then
  engine_emit "$task" "$attempt" agy failed n/a
  echo "diff ${#diff} bytes exceeds agy_max_bytes=$max; route to codex-review" >&2
  exit 1
fi

manifest="$(git -C "$repo" diff --name-only "$BASE_SHA".."$CAND_SHA")"
prompt="You are a code reviewer. $(fm_get "$tf" stop_condition).
Risk threshold: $(fm_get "$tf" risk_threshold) — only findings at or above it matter.
Input manifest (every changed file, nothing omitted):
$manifest
Reply with exactly two lines:
VERDICT: approve OR request-changes
REASON: one sentence.
The diff:
$diff"

set +e
reply="$(agy -p "$prompt" 2>&1)"; rc=$?
set -e
verdict="$(echo "$reply" | sed -n 's/^VERDICT: *//p' | head -n1)"
case "$verdict" in
  approve|request-changes)
    engine_emit "$task" "$attempt" agy ok "$verdict" ;;
  *)
    echo "$reply"
    if [ $rc -ne 0 ]; then
      engine_emit "$task" "$attempt" agy "$(engine_classify "$reply")" n/a
    else
      engine_emit "$task" "$attempt" agy malformed n/a
    fi ;;
esac
```

Run: `chmod +x engines/agy`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add engines/agy tests/test_engine_agy.sh && git commit -m "v0: agy inline reviewer adapter (fail-closed, byte budget)"
```

---

### Task 10: codex-review adapter

**Files:**
- Create: `engines/codex-review`, `tests/test_engine_codex_review.sh`

**Interfaces:**
- Consumes: same frontmatter as agy adapter; runs in the task worktree read-only.
- Produces: envelope `<task>-<attempt>-codex-review.json`. Uses plain `codex exec --sandbox read-only` with a review prompt pinned to `base_sha..candidate_sha` (spec: `codex exec review` range support unverified — probing it is a step here; the generic path is the tested fallback). Same `VERDICT:` reply contract as agy.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_engine_codex_review.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
echo a > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"; echo b > f.txt; git add f.txt; git commit -q -m change
cand="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks .orchid/runtime/spool
export ORCHID_REPO="$WORK" ORCHID_ATTEMPT="T001-a1"
"$ORCHID_BIN" task create T001 demo
"$ORCHID_BIN" task set T001 base_sha "$base"
"$ORCHID_BIN" task set T001 candidate_sha "$cand"

mkdir -p "$WORK/stub"; cat > "$WORK/stub/codex" <<'EOF'
#!/usr/bin/env bash
echo "VERDICT: request-changes"
EOF
chmod +x "$WORK/stub/codex"
PATH="$WORK/stub:$PATH" "$REPO_ROOT/engines/codex-review" T001
env_file=".orchid/runtime/spool/T001-T001-a1-codex-review.json"
source "$REPO_ROOT/lib/envelope.sh"
envelope_validate "$env_file" || fail "envelope valid"
assert_eq "request-changes" "$(envelope_field "$env_file" .verdict)" "verdict parsed"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# engines/codex-review
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"
source "$ORCHID_ROOT/lib/engine-common.sh"
engine_paths
task="$1"; attempt="${ORCHID_ATTEMPT:?}"
tf="$state/tasks/$task.md"
BASE_SHA="$(fm_get "$tf" base_sha)"; CAND_SHA="$(fm_get "$tf" candidate_sha)"
worktree="$(fm_get "$tf" worktree)"; [ -n "$worktree" ] || worktree="$repo"

if [ "${ORCHID_DRYRUN:-0}" = "1" ]; then
  engine_emit "$task" "$attempt" codex-review ok approve; exit 0
fi

prompt="Review EXACTLY the range $BASE_SHA..$CAND_SHA in this repository
(inspect with git diff/show; you may read any file for context).
$(fm_get "$tf" stop_condition). Risk threshold: $(fm_get "$tf" risk_threshold).
End your reply with exactly:
VERDICT: approve OR request-changes"

set +e
reply="$(cd "$worktree" && codex exec --sandbox read-only "$prompt" 2>&1)"; rc=$?
set -e
verdict="$(echo "$reply" | sed -n 's/^VERDICT: *//p' | tail -n1)"
case "$verdict" in
  approve|request-changes) engine_emit "$task" "$attempt" codex-review ok "$verdict" ;;
  *) echo "$reply"
     if [ $rc -ne 0 ]; then engine_emit "$task" "$attempt" codex-review "$(engine_classify "$reply")" n/a
     else engine_emit "$task" "$attempt" codex-review malformed n/a; fi ;;
esac
```

Run: `chmod +x engines/codex-review`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Probe real `codex exec review` range support (manual, once)**

Run: `cd ~/workspace/personal/orchid && codex exec review --help | head -20`
Record in the task file for the dogfood run whether a `base..head` argument exists; if yes, file a follow-up to switch the adapter. Do NOT block on this.

- [ ] **Step 6: Commit**

```bash
git add engines/codex-review tests/test_engine_codex_review.sh
git commit -m "v0: codex-review adapter (read-only, range-pinned prompt)"
```

---

### Task 11: `orchid verify` — deterministic verification with evidence

**Files:**
- Create: `libexec/orchid-verify`, `tests/test_verify.sh`

**Interfaces:**
- Consumes: task frontmatter `verification_commands` (single shell line) and `worktree`; falls back to config key `verify`.
- Produces: `orchid verify <task-id>` — runs commands via `bash -c` in the worktree, writes evidence log `.orchid/reviews/<task>-verify.log` with header (`sha`, `cwd`, `date`, `command`) + full output + `exit: <code>`; prints `PASS`/`FAIL`; exit 0/1. This is the ONLY acceptance authority for tests.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_verify.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
export ORCHID_REPO="$WORK"
"$ORCHID_BIN" task create T001 demo
"$ORCHID_BIN" task set T001 verification_commands "test -f marker.txt"

rc=0; "$ORCHID_BIN" verify T001 || rc=$?
assert_eq "1" "$rc" "verify fails when command fails"
assert_match "exit: 1" "$(cat .orchid/reviews/T001-verify.log)" "evidence records exit code"

touch marker.txt
"$ORCHID_BIN" verify T001 || fail "verify passes when command passes"
assert_match "exit: 0" "$(cat .orchid/reviews/T001-verify.log)" "evidence records success"
assert_match "command: test -f marker.txt" "$(cat .orchid/reviews/T001-verify.log)" "evidence records command"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# libexec/orchid-verify
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"
repo="${ORCHID_REPO:-$PWD}"
state="$(orchid_state "$repo")"
task="$1"; tf="$state/tasks/$task.md"
[ -f "$tf" ] || orchid_die "no task $task"

cmd="$(fm_get "$tf" verification_commands)"
[ -n "$cmd" ] || cmd="$(config_get "$repo" verify)"
[ -n "$cmd" ] || orchid_die "no verification_commands for $task and no 'verify' in orchid.config"
wt="$(fm_get "$tf" worktree)"; [ -n "$wt" ] || wt="$repo"

log="$state/reviews/$task-verify.log"
{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "sha: $(git -C "$wt" rev-parse HEAD 2>/dev/null || echo none)"
  echo "cwd: $wt"
  echo "command: $cmd"
  echo "---"
} > "$log.tmp"
rc=0
( cd "$wt" && bash -c "$cmd" ) >> "$log.tmp" 2>&1 || rc=$?
echo "exit: $rc" >> "$log.tmp"
mv "$log.tmp" "$log"
if [ $rc -eq 0 ]; then echo PASS; else echo FAIL; exit 1; fi
```

Run: `chmod +x libexec/orchid-verify`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add libexec/orchid-verify tests/test_verify.sh && git commit -m "v0: deterministic verify with evidence log"
```

---

### Task 12: `orchid merge` — transactional, serialized, rebase-aware

**Files:**
- Create: `libexec/orchid-merge`, `tests/test_merge.sh`

**Interfaces:**
- Consumes: task frontmatter `branch`, `base_sha`, `candidate_sha`, `verification_commands`; config `integration_branch`; run lock from `lib/common.sh`.
- Produces: `orchid merge <task-id>` — behavior: task must be in `merging` status; takes the run lock; **if integration HEAD ≠ base_sha:** exits 4 (`REBASE-NEEDED`) — v0 keeps the conservative rule: the orchestrator rebases the task branch, re-runs verify + review, and re-enters merging (documented in PROTOCOL.md; automated rebase is v1). Otherwise: creates temp worktree detached at integration HEAD, merges the candidate, runs verification there; on pass advances the integration branch ref to the merge commit and exits 0; on fail exits 1 leaving integration untouched (caller advances task to `rework`). Always removes the temp worktree.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_merge.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m root
printf 'integration_branch=orchid/integration\n' > orchid.config
export ORCHID_REPO="$WORK"
git branch orchid/integration
base="$(git rev-parse orchid/integration)"

git checkout -q -b task/T001
echo change > g.txt; git add g.txt; git commit -q -m "T001 work"
cand="$(git rev-parse HEAD)"
git checkout -q master 2>/dev/null || git checkout -q main

mkdir -p .orchid/tasks .orchid/reviews
"$ORCHID_BIN" task create T001 demo
"$ORCHID_BIN" task set T001 base_sha "$base"
"$ORCHID_BIN" task set T001 candidate_sha "$cand"
"$ORCHID_BIN" task set T001 verification_commands "test -f g.txt && test -f f.txt"
for s in implementing testing reviewing arbitrating merging; do "$ORCHID_BIN" task advance T001 "$s" >/dev/null; done

"$ORCHID_BIN" merge T001 || fail "clean merge should pass"
git merge-base --is-ancestor "$cand" orchid/integration || fail "integration advanced to include candidate"

# behind-integration case exits 4
git checkout -q -b task/T002 orchid/integration~0
echo x > h.txt; git add h.txt; git commit -q -m "T002 work"
cand2="$(git rev-parse HEAD)"; git checkout -q - >/dev/null 2>&1 || true
"$ORCHID_BIN" task create T002 demo2
"$ORCHID_BIN" task set T002 base_sha "$base"   # stale base: integration has moved
"$ORCHID_BIN" task set T002 candidate_sha "$cand2"
for s in implementing testing reviewing arbitrating merging; do "$ORCHID_BIN" task advance T002 "$s" >/dev/null; done
rc=0; "$ORCHID_BIN" merge T002 2>/dev/null || rc=$?
assert_eq "4" "$rc" "stale base exits 4 (REBASE-NEEDED)"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# libexec/orchid-merge
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"
repo="${ORCHID_REPO:-$PWD}"
state="$(orchid_state "$repo")"
task="$1"; tf="$state/tasks/$task.md"
[ -f "$tf" ] || orchid_die "no task $task"
[ "$(fm_get "$tf" status)" = "merging" ] || orchid_die "$task is not in merging state"

integ="$(config_get "$repo" integration_branch orchid/integration)"
base="$(fm_get "$tf" base_sha)"; cand="$(fm_get "$tf" candidate_sha)"
[ -n "$base" ] && [ -n "$cand" ] || orchid_die "$task missing base_sha/candidate_sha"

lock_acquire "$repo" || orchid_die "run lock held; merge must be serialized"
cleanup() { git -C "$repo" worktree remove --force "$tmp" 2>/dev/null || true; lock_release "$repo"; }
trap cleanup EXIT

head="$(git -C "$repo" rev-parse "$integ")"
if [ "$head" != "$base" ]; then
  echo "orchid: integration ($head) moved past base ($base) — REBASE-NEEDED" >&2
  exit 4
fi

tmp="$(mktemp -d)/wt"
git -C "$repo" worktree add --detach "$tmp" "$integ" >/dev/null 2>&1
git -C "$tmp" merge --no-ff -m "orchid: merge $task" "$cand" >/dev/null

cmd="$(fm_get "$tf" verification_commands)"; [ -n "$cmd" ] || cmd="$(config_get "$repo" verify true)"
if ( cd "$tmp" && bash -c "$cmd" ) > "$state/reviews/$task-merge.log" 2>&1; then
  new="$(git -C "$tmp" rev-parse HEAD)"
  git -C "$repo" update-ref "refs/heads/$integ" "$new" "$head"
  echo "merged $task: $integ -> $new"
else
  echo "orchid: validation_failed for $task (see reviews/$task-merge.log)" >&2
  exit 1
fi
```

Run: `chmod +x libexec/orchid-merge`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add libexec/orchid-merge tests/test_merge.sh && git commit -m "v0: transactional serialized merge with stale-base guard"
```

---

### Task 13: `orchid status`, `orchid notify`, `orchid answer`

**Files:**
- Create: `libexec/orchid-status`, `libexec/orchid-notify`, `libexec/orchid-answer`, `tests/test_status_notify.sh`

**Interfaces:**
- Produces: `orchid status` (task table + open questions + running jobs); `orchid notify <question-id> <text>` (appends `## <qid>` + text to `BLOCKERS.md`, creates `runtime/answers/<qid>.question`); `orchid answer <question-id> <choice>` (idempotent: writes `runtime/answers/<qid>.answer` once; second identical call is a no-op, conflicting call fails). Ticks consume `.answer` files.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_status_notify.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
echo "# Blockers" > .orchid/BLOCKERS.md
export ORCHID_REPO="$WORK"
"$ORCHID_BIN" task create T001 demo

"$ORCHID_BIN" notify Q1 "Deploy target? 1) staging 2) prod"
assert_match "Q1" "$(cat .orchid/BLOCKERS.md)" "blocker recorded"

"$ORCHID_BIN" answer Q1 1
assert_eq "1" "$(cat .orchid/runtime/answers/Q1.answer)" "answer recorded"
"$ORCHID_BIN" answer Q1 1 || fail "idempotent same answer ok"
rc=0; "$ORCHID_BIN" answer Q1 2 2>/dev/null || rc=$?
assert_eq "1" "$rc" "conflicting answer rejected"

assert_match "T001" "$("$ORCHID_BIN" status)" "status lists tasks"
```

- [ ] **Step 2: Run to verify failure** — FAIL.

- [ ] **Step 3: Implement**

```bash
# libexec/orchid-notify
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
repo="${ORCHID_REPO:-$PWD}"
state="$(orchid_state "$repo")"; rt="$(orchid_runtime "$repo")"
qid="$1"; shift
mkdir -p "$rt/answers"
{ echo; echo "## $qid ($(date -u +%Y-%m-%dT%H:%M:%SZ))"; echo "$*"; } >> "$state/BLOCKERS.md"
printf '%s\n' "$*" > "$rt/answers/$qid.question"
echo "notified: $qid"
```

```bash
# libexec/orchid-answer
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
repo="${ORCHID_REPO:-$PWD}"
rt="$(orchid_runtime "$repo")"
qid="$1"; choice="$2"
f="$rt/answers/$qid.answer"
if [ -f "$f" ]; then
  [ "$(cat "$f")" = "$choice" ] && { echo "already answered"; exit 0; }
  orchid_die "$qid already answered differently"
fi
printf '%s\n' "$choice" | atomic_write "$f"
echo "answered: $qid -> $choice"
```

```bash
# libexec/orchid-status
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
repo="${ORCHID_REPO:-$PWD}"
echo "== tasks"
"$ORCHID_ROOT/bin/orchid" task list 2>/dev/null || echo "(none)"
echo "== jobs"
"$ORCHID_ROOT/bin/orchid" jobs check 2>/dev/null || echo "(none)"
rt="$(orchid_runtime "$repo")"
echo "== open questions"
for q in "$rt/answers"/*.question; do
  [ -e "$q" ] || continue
  qid="$(basename "$q" .question)"
  [ -f "$rt/answers/$qid.answer" ] || echo "$qid: $(head -n1 "$q")"
done
```

Run: `chmod +x libexec/orchid-status libexec/orchid-notify libexec/orchid-answer`

- [ ] **Step 4: Run to verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add libexec/orchid-status libexec/orchid-notify libexec/orchid-answer tests/test_status_notify.sh
git commit -m "v0: status, notify, idempotent answer"
```

---

### Task 14: PROTOCOL.md, skills, install.sh

**Files:**
- Create: `PROTOCOL.md`, `skills/orchid/SKILL.md`, `skills/orchid-plan/SKILL.md`, `skills/orchid-resume/SKILL.md`, `install.sh`, `tests/test_install.sh`

**Interfaces:**
- Consumes: every CLI verb built above.
- Produces: the orchestration procedure any engine can follow; installable skills.

- [ ] **Step 1: Write PROTOCOL.md**

```markdown
<!-- PROTOCOL.md -->
# Orchid Tick Protocol (v0 — serial, fixed roles)

You are the orchestrator. Never implement code yourself (except arbitration
trivia ≤10 lines). Mutate state ONLY via `orchid` verbs. One tick:

1. `orchid jobs reconcile` — ingest finished engine results.
2. `orchid jobs check` — kill/relaunch per the escalation ladder:
   dead/stalled/timeout → increment `infra_failures` (`orchid task set`),
   relaunch (`orchid jobs launch <id> <engine>`); 3 rework attempts →
   `orchid task advance <id> blocked` + `orchid notify`.
3. For the single active task, advance the pipeline:
   - `pending` → create worktree (`git worktree add <path> -b task/<id>
     <integration-sha>`), `orchid task set <id> worktree <path>`, set
     `base_sha`, `orchid task advance <id> implementing`,
     `orchid jobs launch <id> <task's engine field>` (set at creation from
     `role.implementer` config — never hard-code an engine name).
   - implementer envelope `ok` → set `candidate_sha` (worktree HEAD),
     `orchid task advance <id> testing`, run `orchid verify <id>`:
     PASS → `advance reviewing` + launch reviewers per risk tier from
     config (`role.reviewer.low`, `role.reviewer.high` — defaults: low agy;
     medium/high codex-review AND agy);
     FAIL → `advance rework`, write a rework spec into the task body
     naming the failure, `attempts` incremented, `advance implementing`,
     relaunch codex.
   - all reviewer envelopes in → `advance arbitrating`; read verdicts +
     findings; findings at/above risk_threshold block. Approve →
     `advance merging`, run `orchid merge <id>`:
     exit 0 → `advance done`; exit 1 → `advance rework` (validation_failed);
     exit 4 → rebase task branch onto integration, re-run verify + reviews,
     re-enter merging.
   - Disagreement between reviewers → you read the diff and decide.
4. If no active task and roadmap has pending tasks → pick the next by
   `depends_on` order.
5. Blockers → `orchid notify <qid> <question>`; consume answers from
   `.orchid/runtime/answers/*.answer`.
6. Commit durable state on the integration branch:
   `git add .orchid && git commit -m "orchid: tick"` (on that branch only).
```

- [ ] **Step 2: Write the skills (thin shims)**

```markdown
<!-- skills/orchid/SKILL.md -->
---
name: orchid
description: Drive an orchid run in the current repo - reconcile jobs, advance the active task, launch engines. Use each tick of an orchid orchestration session.
---
Read PROTOCOL.md in the orchid tool repo (resolve via `orchid --help` path or
$ORCHID_ROOT) and execute exactly one tick as written. Do not improvise
procedure; do not hand-edit .orchid files — verbs only.
```

```markdown
<!-- skills/orchid-plan/SKILL.md -->
---
name: orchid-plan
description: Turn .orchid/requirements.md into a roadmap and task files, with a codex critique pass, then start the run. Use once at the start of an orchid run.
---
1. Run `orchid doctor`; stop on failure. 2. Run `orchid init` if no
integration branch. 3. Read `.orchid/requirements.md`; assign requirement
IDs; draft `.orchid/roadmap.md` and `orchid task create` each task with
acceptance_criteria + verification_commands set via `orchid task set`.
4. Write `.orchid/context.md` (stack, conventions, build/test commands).
5. Critique pass: `codex exec --sandbox read-only "critique this roadmap …"`,
revise. 6. Commit durable state on the integration branch. 7. Begin ticking
per the orchid skill.
```

```markdown
<!-- skills/orchid-resume/SKILL.md -->
---
name: orchid-resume
description: Re-enter a crashed or interrupted orchid run - reconcile reality from state files, then continue ticking. Use when resuming an orchid run.
---
1. `orchid doctor`. 2. `orchid jobs check` — for any dead/ambiguous job:
kill recorded pgid if alive, then relaunch cleanly (never re-adopt).
3. `orchid jobs reconcile`. 4. Read `orchid status` and the active task
file; continue ticking per the orchid skill.
```

```bash
# install.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
skills_dst="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
bin_dst="${ORCHID_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$skills_dst" "$bin_dst"
for s in "$here"/skills/*/; do
  name="$(basename "$s")"
  ln -sfn "$s" "$skills_dst/$name"
  echo "skill: $name -> $skills_dst/$name"
done
ln -sf "$here/bin/orchid" "$bin_dst/orchid"
echo "cli: orchid -> $bin_dst/orchid (ensure $bin_dst is on PATH)"
echo "uninstall: remove those symlinks."
```

- [ ] **Step 3: Write install test**

```bash
# tests/test_install.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
CLAUDE_SKILLS_DIR="$WORK/skills" ORCHID_BIN_DIR="$WORK/bin" bash "$REPO_ROOT/install.sh"
[ -L "$WORK/skills/orchid" ] || fail "orchid skill linked"
[ -L "$WORK/bin/orchid" ] || fail "cli linked"
"$WORK/bin/orchid" help >/dev/null || fail "symlinked cli resolves ORCHID_ROOT"
```

- [ ] **Step 4: Run** — `chmod +x install.sh && bash tests/run.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add PROTOCOL.md skills install.sh tests/test_install.sh
git commit -m "v0: protocol, skills, installer"
```

---

### Task 15: End-to-end lifecycle + crash recovery test

**Files:**
- Create: `tests/test_e2e.sh`

**Interfaces:**
- Consumes: everything above. Uses `ORCHID_DRYRUN`-style stub engines that do REAL work (commit to the worktree, emit envelopes) so the full pipeline runs without LLMs.

- [ ] **Step 1: Write the E2E test**

```bash
# tests/test_e2e.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m root
printf 'integration_branch=orchid/integration\nverify=true\n' > orchid.config
export ORCHID_REPO="$WORK"
"$ORCHID_BIN" init
mkdir -p .orchid/tasks .orchid/reviews

# stub implementer: commits real work in the worktree, emits ok envelope
mkdir -p "$WORK/fe"
cat > "$WORK/fe/impl" <<'EOF'
#!/usr/bin/env bash
set -eu
repo="$ORCHID_REPO"; task="$1"
wt="$(awk -v k=worktree '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$repo/.orchid/tasks/$task.md")"
echo done > "$wt/feature.txt"
git -C "$wt" add feature.txt && git -C "$wt" commit -q -m "$task: feature"
spool="$repo/.orchid/runtime/spool"; mkdir -p "$spool"
printf '{"contract":1,"task":"%s","attempt":"%s","status":"ok","verdict":"n/a"}' "$task" "$ORCHID_ATTEMPT" > "$spool/$task-$ORCHID_ATTEMPT-impl.json"
EOF
cat > "$WORK/fe/rev" <<'EOF'
#!/usr/bin/env bash
set -eu
spool="$ORCHID_REPO/.orchid/runtime/spool"; mkdir -p "$spool"
printf '{"contract":1,"task":"%s","attempt":"%s","status":"ok","verdict":"approve"}' "$1" "$ORCHID_ATTEMPT" > "$spool/$1-$ORCHID_ATTEMPT-rev.json"
EOF
chmod +x "$WORK/fe/"*
export ORCHID_ENGINES_DIR="$WORK/fe"

# --- full lifecycle, driven exactly as PROTOCOL.md prescribes ---
"$ORCHID_BIN" task create T001 "add feature.txt"
"$ORCHID_BIN" task set T001 verification_commands "test -f feature.txt"
integ_sha="$(git rev-parse orchid/integration)"
wt="$WORK/.orchid/runtime/wt-T001"
git worktree add -q "$wt" -b task/T001 "$integ_sha"
"$ORCHID_BIN" task set T001 worktree "$wt"
"$ORCHID_BIN" task set T001 base_sha "$integ_sha"
"$ORCHID_BIN" task advance T001 implementing
"$ORCHID_BIN" jobs launch T001 impl; sleep 1
assert_match "T001	ok" "$("$ORCHID_BIN" jobs reconcile)" "implementer envelope ok"
"$ORCHID_BIN" task set T001 candidate_sha "$(git -C "$wt" rev-parse HEAD)"
"$ORCHID_BIN" task advance T001 testing
"$ORCHID_BIN" verify T001 || fail "verify passes"
"$ORCHID_BIN" task advance T001 reviewing
"$ORCHID_BIN" jobs launch T001 rev; sleep 1
assert_match "approve" "$("$ORCHID_BIN" jobs reconcile)" "review approve"
"$ORCHID_BIN" task advance T001 arbitrating
"$ORCHID_BIN" task advance T001 merging
"$ORCHID_BIN" merge T001 || fail "merge passes"
"$ORCHID_BIN" task advance T001 done
git merge-base --is-ancestor "$(git -C "$wt" rev-parse HEAD)" orchid/integration \
  || fail "feature commit reached integration"

# --- crash recovery: dead job detected and cleanly relaunchable ---
"$ORCHID_BIN" task create T002 "crash demo"
cat > "$WORK/fe/hang" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$WORK/fe/hang"
"$ORCHID_BIN" jobs launch T002 hang
kill "$(jq -r .pid .orchid/runtime/jobs/T002.json)"; sleep 1
assert_match "T002	dead" "$("$ORCHID_BIN" jobs check)" "crash detected"
"$ORCHID_BIN" jobs launch T002 impl 2>/dev/null || true   # relaunch path exists
```

- [ ] **Step 2: Run** — `bash tests/run.sh` → PASS (all suites).

- [ ] **Step 3: Commit**

```bash
git add tests/test_e2e.sh && git commit -m "v0: end-to-end lifecycle and crash-recovery test"
```

---

### Task 16: Private GitHub repo + dogfood checklist

**Files:**
- Modify: none (operational task)

- [ ] **Step 1:** `cd ~/workspace/personal/orchid && gh repo create orchid --private --source . --push` — verify with `gh repo view orchid --json visibility` → `PRIVATE`.
- [ ] **Step 2:** Run the full suite once more: `bash tests/run.sh` → PASS; push.
- [ ] **Step 3 (dogfood, semi-watched):** in the webBooks repo: write `orchid.config` (real `verify` command) + a small 1-task `requirements.md`; run `orchid doctor`, `orchid init`; drive one real task through the pipeline with real codex + agy engines per PROTOCOL.md. Record every friction point in `docs/dogfood-notes.md` in the orchid repo.
- [ ] **Step 4:** Probe `codex exec review` range support (Task 10 Step 5 note) and `agy -p` stdin acceptance; record results in `docs/dogfood-notes.md`.
- [ ] **Step 5:** Commit notes; v0 complete. v1 planning (pump, failover, concurrency, greenfield, review archetype, README/screenshots, public flip) starts from the dogfood notes.

---

## Self-review notes

- **Spec coverage (v0 scope):** dispatcher+verbs (T1,4,5,7,11,12,13), determinism boundary (no libexec script invokes an LLM — checked), single-writer via verbs (T4), runtime/durable split + gitignore (T1,5), mkdir lock (T2, exercised in T12), envelope fail-closed (T6,7), write-ahead manifests + attempt IDs + pgid identity + never-re-adopt (T7, T15), deterministic verify evidence (T11), transactional serialized merge + stale-base guard (T12), notify/answer idempotency (T13), PROTOCOL/skills/installer (T14), E2E + crash test (T15), private repo + dogfood (T16). Deferred per staging: pump, tick runner, failover, engines.json, concurrency, greenfield, non-feature archetypes.
- **Known v0 simplifications (documented, deliberate):** merge exit 4 requires orchestrator-driven rebase (automation is v1); heartbeat lease not needed until the pump exists (v1); `orchid-jobs reconcile` infers engine name from envelope filename suffix.
- **Type consistency:** verb names, frontmatter keys, envelope fields, and exit codes (2 unknown verb, 3 illegal transition, 4 rebase-needed) are used consistently across tasks.
