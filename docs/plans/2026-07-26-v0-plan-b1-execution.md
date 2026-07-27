# Orchid v0 Plan B1 — Execution Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the effectful half of orchid v0: job manifests bound to kernel-minted job IDs, the tier-2 launcher, input packs with budgets, the three default engine adapters, and deterministic `verify`/`merge` — plus the Plan-A review backlog sweep. Ends with every execution-path invariant (INV-03/06/07/11/12) as a named test.

**Architecture:** Per `docs/specs/kernel.md` + `docs/specs/plugins.md`. Tier-1 additions (`jobs`, `verify`, `merge`) stay deterministic; `runners/orchid-launch` is the ONLY engine spawner (INV-06); adapters live at `plugins/engines/<name>/run`, receive a request document, write envelopes to the kernel-chosen spool path. Plan B2 adds PROTOCOL/skills/notify/E2E/dogfood.

**Tech Stack:** bash 3.2, jq, git. Same harness (`tests/run.sh`).

## Global Constraints

- NO Claude/AI references anywhere: commit messages, PR bodies, file content. After EVERY commit run `git log -1 --format=%B`; anything beyond the single subject line → `git commit --amend -m "<subject>"`.
- Branch: create `v0b1-execution` from main; never commit to main.
- `libexec/` verbs: no LLM calls, no network, no long-lived process spawning (INV-01 suite enforces).
- Engine adapters: write ONLY to their request's `output` path + stdout/stderr logs; never durable state.
- All durable writes atomic; bash 3.2; every executable `#!/usr/bin/env bash` + `set -euo pipefail`.
- Every adapter honors `ORCHID_DRYRUN=1` (emit plausible envelope, spawn nothing).
- Conformance tests named `tests/inv/test_INV-XX_*.sh`.

---

### Task 1: Plan-A backlog sweep

**Files:**
- Modify: `lib/common.sh`, `libexec/orchid-run`, `libexec/orchid-task`, `libexec/orchid-doctor`, `libexec/orchid-status`, `libexec/orchid-init`, `tests/inv/test_INV-01_no_spawn_in_tier1.sh`, `docs/specs/kernel.md`
- Test: extend existing suites inline per item

**Interfaces:** no new interfaces — hardening only. Items (each cited from the final-review ledger):

- [ ] **Step 1:** `lib/common.sh` `_cfg_file_get`: escape the key for ERE (`k_esc=$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')`) before grep. Test (append to `tests/test_common.sh`): a key `a.b` must not match line `axb=1`.
- [ ] **Step 2:** `libexec/orchid-run` `start`: require initialized state — `[ -d "$(orchid_state "$repo")/tasks" ] || [ -f "$(orchid_state "$repo")/roadmap.md" ] || orchid_die "not initialized — run orchid init"`. Test (append to `tests/test_run.sh`): `run start` in a bare git repo without `.orchid/roadmap.md` fails.
- [ ] **Step 3:** `libexec/orchid-task`: (a) add `updated` and `schema` to the kernel-owned deny-list; (b) `--reason` parsing: when `--reason` is the last arg with no value, die with `orchid_die "--reason requires a value"` instead of an unbound-variable error (guard `${2:-}`). Tests: append both cases to `tests/inv/test_INV-08_reasons.sh`.
- [ ] **Step 4:** `libexec/orchid-doctor`: add check `integration branch exists or creatable` — ok when `git rev-parse --verify -q "$integ"` succeeds OR the repo has a HEAD to branch from; FAIL only when neither. Test: append to `tests/test_init_doctor.sh` (doctor ok pre-init and post-init).
- [ ] **Step 5:** `libexec/orchid-status`: suppress fm_get stderr for missing roadmap (`2>/dev/null`, print `run_status: (uninitialized)` when empty). Test: status in un-init repo prints `(uninitialized)` and exits 0.
- [ ] **Step 6:** `libexec/orchid-init`: make the `.gitignore` append atomic (`{ cat existing 2>/dev/null; echo ".orchid/runtime/"; } | atomic_write`, keeping the existing dedup grep guard).
- [ ] **Step 7:** `tests/inv/test_INV-01_no_spawn_in_tier1.sh`: tighten the background regex to `(^|[^&])&[[:space:]]*$` (no `&&` false positive). Verify by adding a scratch file with `foo &&` continuation under libexec in the TEST's sandbox only — actually verify by piping both `foo &&` and `foo &` through the new grep in the test itself (self-check assertions).
- [ ] **Step 8:** `docs/specs/kernel.md` (docs, no code): (a) annotate the canonical table's preconditions with enforcement owner — add a sentence: preconditions marked deps/worktree/SHAs are ORCHESTRATOR-enforced in v0; the kernel enforces legality, reasons, risk monotonicity, and the `.orchid/` guard (and refuses `testing` entry when SHAs are unset — see step 9); (b) bless journal kind `intervention` for lock-break entries; (c) one sentence noting the lock-break journal entry is written post-epoch-mint (exception to journal-first, informational).
- [ ] **Step 9:** `libexec/orchid-task`: close the INV-04 conditionality — entry to `testing` now REQUIRES non-empty `base_sha` and `candidate_sha` (`orchid_die "testing requires base_sha and candidate_sha set"`), making the guard non-vacuous. Update `tests/inv/test_INV-04_state_guard.sh`: add assertion that advance-to-testing with unset SHAs fails.
- [ ] **Step 10:** Full suite green; ONE commit: `v0b1: plan-A review backlog sweep`.

---

### Task 2: Envelope library with per-operation requirements

**Files:**
- Create: `lib/envelope.sh`, `tests/test_envelope.sh`

**Interfaces:**
- `envelope_validate <file>` — 0 iff JSON with `contract==1`, non-empty `job_id`, `task`, `status ∈ ok|failed|rate_limited|timeout|auth|malformed`, AND per-operation payload when `status==ok`: `operation==review|critique` → `verdict ∈ approve|request-changes` and `scope_complete` boolean present; `operation==implement` → `summary` non-empty. `envelope_field <file> <jq-path>`.

- [ ] **Step 1: Test**

```bash
# tests/test_envelope.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
good() { cat > "$WORK/e.json"; envelope_validate "$WORK/e.json"; }
bad()  { cat > "$WORK/e.json"; if envelope_validate "$WORK/e.json" 2>/dev/null; then return 1; fi; }

good <<'EOF' || fail "implement ok accepted"
{"contract":1,"job_id":"j-1","task":"T001","operation":"implement","status":"ok","summary":"did work"}
EOF
good <<'EOF' || fail "review ok accepted"
{"contract":1,"job_id":"j-2","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true}
EOF
bad <<'EOF' || fail "review ok without verdict rejected"
{"contract":1,"job_id":"j-3","task":"T001","operation":"review","status":"ok"}
EOF
bad <<'EOF' || fail "implement ok without summary rejected"
{"contract":1,"job_id":"j-4","task":"T001","operation":"implement","status":"ok"}
EOF
good <<'EOF' || fail "failed status needs no payload"
{"contract":1,"job_id":"j-5","task":"T001","operation":"review","status":"failed"}
EOF
bad <<'EOF' || fail "missing job_id rejected"
{"contract":1,"task":"T001","operation":"implement","status":"ok","summary":"x"}
EOF
echo 'not json' > "$WORK/e.json"
envelope_validate "$WORK/e.json" 2>/dev/null && fail "non-JSON rejected"
assert_eq "ok" "$(envelope_field "$WORK/e.json" .status 2>/dev/null || echo parse-fail; printf '{"status":"ok"}' > "$WORK/f.json"; envelope_field "$WORK/f.json" .status)" "field read"
```

- [ ] **Step 2: RED.** — [ ] **Step 3: Implement**

```bash
# lib/envelope.sh
#!/usr/bin/env bash
envelope_validate() {
  jq -e '
    (.contract == 1)
    and (.job_id | type == "string" and length > 0)
    and (.task   | type == "string" and length > 0)
    and (.status | IN("ok","failed","rate_limited","timeout","auth","malformed"))
    and (
      .status != "ok" or (
        (.operation == "implement" and (.summary | type == "string" and length > 0))
        or ((.operation | IN("review","critique"))
            and (.verdict | IN("approve","request-changes"))
            and (.scope_complete | type == "boolean"))
        or (.operation | IN("review","critique","implement") | not)
      )
    )
  ' "$1" >/dev/null
}
envelope_field() { jq -r "$2" "$1"; }
```

- [ ] **Step 4: GREEN (full suite).** — [ ] **Step 5: Commit** `v0b1: envelope validation with per-operation requirements`.

---

### Task 3: Input packs with budgets (INV-12)

**Files:**
- Create: `lib/pack.sh`, `tests/test_pack.sh`, `tests/inv/test_INV-12_pack_overflow.sh`

**Interfaces:**
- `pack_build <repo> <task-id> <operation> <dest-dir>` — creates `<dest-dir>` containing: `task.md` (copy; NON-TRUNCATABLE), `context.md` (copy if exists; head-truncatable), `diff.patch` (for review/critique ops: `git diff base..candidate`; NON-TRUNCATABLE), and `pack.json` manifest `{budget, total_bytes, items:[{name, bytes, truncated}], omitted:[]}`. Budget = `config_get pack_budget_bytes 65536`. If non-truncatables alone exceed budget → exit 12 (`input_overflow`), dest removed. Context trimmed head-first to fit; trim recorded.

- [ ] **Step 1: Tests**

```bash
# tests/test_pack.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/pack.sh"
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"; echo change > f.txt; git add f.txt; git commit -q -m c
cand="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks
printf -- '---\nid: T001\nstatus: reviewing\nbase_sha: %s\ncandidate_sha: %s\n---\nSpec body.\n' "$base" "$cand" > .orchid/tasks/T001.md
echo "repo context here" > .orchid/context.md
export ORCHID_REPO="$WORK"

pack_build "$WORK" T001 review "$WORK/p1" || fail "pack build"
[ -f "$WORK/p1/task.md" ] && [ -f "$WORK/p1/diff.patch" ] && [ -f "$WORK/p1/pack.json" ] || fail "pack contents"
grep -q "change" "$WORK/p1/diff.patch" || fail "diff captured"
assert_eq "false" "$(jq -r '.items[] | select(.name=="task.md") | .truncated' "$WORK/p1/pack.json")" "task never truncated"

# context trimming under tight budget (non-truncatables still fit)
big_ctx="$(printf 'x%.0s' $(seq 1 5000))"; echo "$big_ctx" > .orchid/context.md
tight=$(( $(wc -c < .orchid/tasks/T001.md) + $(cd "$WORK" && git diff "$base".."$cand" | wc -c) + 200 ))
printf 'pack_budget_bytes=%s\n' "$tight" > orchid.config
pack_build "$WORK" T001 review "$WORK/p2" || fail "pack build with trim"
assert_eq "true" "$(jq -r '.items[] | select(.name=="context.md") | .truncated' "$WORK/p2/pack.json")" "context trimmed"
[ "$(wc -c < "$WORK/p2/context.md")" -lt 5000 ] || fail "context actually smaller"
```

```bash
# tests/inv/test_INV-12_pack_overflow.sh
#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/pack.sh"
cd "$WORK"; git init -q .; echo base > f.txt; git add f.txt; git commit -q -m base
base="$(git rev-parse HEAD)"
printf 'y%.0s' $(seq 1 9000) > f.txt; git add f.txt; git commit -q -m big
cand="$(git rev-parse HEAD)"
mkdir -p .orchid/tasks
printf -- '---\nid: T001\nbase_sha: %s\ncandidate_sha: %s\n---\nbody\n' "$base" "$cand" > .orchid/tasks/T001.md
printf 'pack_budget_bytes=100\n' > orchid.config
rc=0; pack_build "$WORK" T001 review "$WORK/p" 2>/dev/null || rc=$?
assert_eq "12" "$rc" "INV-12: non-truncatable overflow exits 12, never silently truncates"
[ ! -d "$WORK/p" ] || fail "INV-12: dest removed on overflow"
```

- [ ] **Step 2: RED.** — [ ] **Step 3: Implement**

```bash
# lib/pack.sh
#!/usr/bin/env bash
# Input packs: kernel-materialized per-job memory. See docs/specs/plugins.md.

pack_build() {  # repo task op dest ; exit 12 = input_overflow
  local repo="$1" task="$2" op="$3" dest="$4"
  local state tf budget used=0 items="" omitted=""
  state="$(orchid_state "$repo")"; tf="$state/tasks/$task.md"
  [ -f "$tf" ] || { echo "orchid: no task $task" >&2; return 1; }
  budget="$(config_get "$repo" pack_budget_bytes 65536)"
  mkdir -p "$dest"

  cp "$tf" "$dest/task.md"
  used=$(( used + $(wc -c < "$dest/task.md") ))
  items="{\"name\":\"task.md\",\"bytes\":$(wc -c < "$dest/task.md"),\"truncated\":false}"

  if [ "$op" = review ] || [ "$op" = critique ]; then
    local b c
    b="$(awk -v k=base_sha '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$tf")"
    c="$(awk -v k=candidate_sha '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$tf")"
    git -C "$repo" diff "$b".."$c" > "$dest/diff.patch"
    used=$(( used + $(wc -c < "$dest/diff.patch") ))
    items="$items,{\"name\":\"diff.patch\",\"bytes\":$(wc -c < "$dest/diff.patch"),\"truncated\":false}"
  fi

  if [ "$used" -gt "$budget" ]; then
    rm -rf "$dest"
    echo "orchid: input_overflow — non-truncatable inputs ($used bytes) exceed pack budget ($budget)" >&2
    return 12
  fi

  if [ -f "$state/context.md" ]; then
    local room ctx_bytes trunc=false
    room=$(( budget - used ))
    ctx_bytes="$(wc -c < "$state/context.md")"
    if [ "$ctx_bytes" -le "$room" ]; then
      cp "$state/context.md" "$dest/context.md"
    else
      tail -c "$room" "$state/context.md" > "$dest/context.md"; trunc=true
    fi
    items="$items,{\"name\":\"context.md\",\"bytes\":$(wc -c < "$dest/context.md"),\"truncated\":$trunc}"
  else
    omitted="\"context.md\""
  fi

  printf '{"budget":%s,"total_bytes":%s,"items":[%s],"omitted":[%s]}\n' \
    "$budget" "$used" "$items" "$omitted" | jq . > "$dest/pack.json"
}
```

(Note: context trims HEAD-first per spec — `tail -c` keeps the end; the spec says context is head-truncatable, i.e. the head is what gets dropped. That is what `tail -c` does. Keep a one-line comment saying so.)

- [ ] **Step 4: GREEN.** — [ ] **Step 5: Commit** `v0b1: input packs with budgets and overflow fail-fast`.

---

### Task 4: `orchid jobs` — prepare / check / reconcile (INV-03)

**Files:**
- Create: `libexec/orchid-jobs`, `tests/test_jobs.sh`, `tests/inv/test_INV-03_envelope_binding.sh`

**Interfaces:**
- `orchid jobs prepare <task-id> <role> <operation>` (tier-1; epoch-fenced): resolves engine via `resolve_role`; mints `job_id=j-e<epoch>-<task>-a<attempt>-<4hex from /dev/urandom>`; writes manifest `runtime/jobs/<job_id>.json` `{job_id, task, attempt, role, operation, engine, pid:0, pgid:0, started_at:0, log, output, base_sha, candidate_sha}` where `output=runtime/spool/<job_id>.json`; prints the manifest path. Does NOT spawn (INV-01).
- `orchid jobs check` — per manifest with pid>0: dead / running / stalled (log mtime older than `stall_minutes`, kill pgid) / timeout (started_at older than `timeout_minutes`, kill pgid). pid==0 manifests print `prepared`.
- `orchid jobs reconcile` — for each `runtime/spool/*.json`: `envelope_validate` AND a live manifest whose `job_id` matches the envelope's AND manifest task/SHAs cross-check envelope (when envelope carries them) — else move to `runtime/quarantine/` with a reason suffix, print `quarantined`. Accepted: move to `.orchid/reviews/<task>-a<attempt>-<role>.json`, delete manifest, print `<task>\t<status>\t<verdict|n/a>`. A spool file whose job_id matches NO manifest (replay or forgery) → quarantine.

- [ ] **Step 1: Tests**

```bash
# tests/test_jobs.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo

m="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
[ -f "$m" ] || fail "manifest written at printed path"
jid="$(jq -r .job_id "$m")"
assert_match "^j-e[0-9]+-T001-a1-" "$jid" "job id shape"
assert_eq "fake" "$(jq -r .engine "$m")" "engine resolved from role"
assert_eq "0" "$(jq -r .pid "$m")" "prepare does not spawn"
assert_match "T001	prepared" "$("$ORCHID_BIN" jobs check)" "prepared state visible"

# reconcile a good envelope
out="$(jq -r .output "$m")"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"done"}' "$jid" > "$out"
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "reconciled"
[ -f ".orchid/reviews/T001-a1-implementer.json" ] || fail "envelope moved durable"
[ ! -f "$m" ] || fail "manifest deleted"
```

```bash
# tests/inv/test_INV-03_envelope_binding.sh
#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo
m="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid="$(jq -r .job_id "$m")"; sp="$WORK/.orchid/runtime/spool"

# forged job_id -> quarantine
printf '{"contract":1,"job_id":"j-forged","task":"T001","operation":"implement","status":"ok","summary":"evil"}' > "$sp/j-forged.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: unknown job_id quarantined"
[ -e "$WORK/.orchid/runtime/quarantine/"* ] || fail "INV-03: quarantine dir holds it"
[ -f "$m" ] || fail "INV-03: manifest untouched by forgery"

# task mismatch -> quarantine
printf '{"contract":1,"job_id":"%s","task":"T999","operation":"implement","status":"ok","summary":"wrong"}' "$jid" > "$sp/$jid.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: task mismatch quarantined"
[ -f "$m" ] || fail "INV-03: manifest survives mismatch"

# replay: accept good, then same job_id again -> quarantine
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"real"}' "$jid" > "$sp/$jid.json"
assert_match "T001	ok" "$("$ORCHID_BIN" jobs reconcile)" "good envelope accepted"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"replay"}' "$jid" > "$sp/$jid-replay.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: replay quarantined"
```

- [ ] **Step 2: RED.** — [ ] **Step 3: Implement** (~95 lines; key points: `prepare` reads attempt from frontmatter +1, SHAs copied from frontmatter, epoch from `epoch_current`; random suffix `xxd -p -l2 /dev/urandom 2>/dev/null || printf '%04x' $$`; `reconcile` matches manifests by iterating `runtime/jobs/*.json` and comparing `.job_id`; quarantine = `mv` with `.reason-<why>` suffix appended to filename; all writes atomic where durable.)

- [ ] **Step 4: GREEN.** — [ ] **Step 5: Commit** `v0b1: job manifests with kernel-minted ids; reconcile binds and quarantines`.

---

### Task 5: `runners/orchid-launch` — the ONLY engine spawner (INV-06)

**Files:**
- Create: `runners/orchid-launch`, `tests/test_launch.sh`, `tests/inv/test_INV-06_launcher_only.sh`

**Interfaces:**
- `runners/orchid-launch <task-id> <role> <operation>` (tier-2, effectful): calls `bin/orchid jobs prepare` → builds pack (`pack_build`) into `runtime/packs/<job_id>/` → writes request document `runtime/requests/<job_id>.json` (fields per plugins.md: request:1, job_id, task, attempt, role, operation, base_sha, candidate_sha, worktree, input_pack, output, deadline_s from `timeout_minutes`*60, policy read-only|workspace-write by operation, model/effort from config) → spawns `<engine>/run <request.json>` detached: stdin `</dev/null`, stdout+stderr appended to the manifest's log, background; records pid+pgid into the manifest. Prints `launched <job_id> pid <pid>`.
- INV-06 (static): no file under `libexec/` or `lib/` spawns `plugins/engines/*` paths or calls `orchid-launch`; only `runners/` may. Plus: `runners/orchid-launch` must contain `</dev/null` on the spawn line.

- [ ] **Step 1: Tests**

```bash
# tests/test_launch.sh
#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; echo a > f.txt; git add f.txt; git commit -q -m base
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
mkdir -p "$WORK/eng/fake"
cat > "$WORK/eng/fake/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
[ -f "$(jq -r .input_pack "$req")/pack.json" ] || exit 1
[ "$(jq -r .operation "$req")" = implement ] || exit 1
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"implement","status":"ok","summary":"stub done"}' "$jid" "$task" > "$out"
EOF
chmod +x "$WORK/eng/fake/run"
export ORCHID_ENGINES_DIR="$WORK/eng"
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo

out="$("$REPO_ROOT/runners/orchid-launch" T001 implementer implement)"
assert_match "launched j-" "$out" "launch reports job id"
sleep 1
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	ok" "$line" "stub engine envelope reconciled end-to-end"
# request document sanity: recorded in runtime/requests
req="$(ls "$WORK/.orchid/runtime/requests/"*.json | head -n1)"
assert_eq "implement" "$(jq -r .operation "$req")" "request operation"
assert_eq "workspace-write" "$(jq -r .policy "$req")" "implement policy"
```

```bash
# tests/inv/test_INV-06_launcher_only.sh
#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
if grep -rnE 'plugins/engines|orchid-launch' "$REPO_ROOT"/libexec/ "$REPO_ROOT"/lib/ \
   | grep -vE 'resolve_engine_exe|#|resolver\.sh'; then
  fail "INV-06: engine spawning referenced outside runners/"
fi
grep -q '</dev/null' "$REPO_ROOT/runners/orchid-launch" || fail "INV-06: launcher must close stdin"
```

(Note: `lib/resolver.sh` legitimately *names* engine paths for resolution — the filter exempts it; it never executes them. The test asserts pattern presence, reviewers judge substance.)

- [ ] **Step 2: RED.** — [ ] **Step 3: Implement** (~70 lines; spawn shape:)

```bash
  ORCHID_DRYRUN="${ORCHID_DRYRUN:-0}" "$exe" "$req_file" </dev/null >> "$log" 2>&1 &
  pid=$!
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)"
```

- [ ] **Step 4: GREEN.** — [ ] **Step 5: Commit** `v0b1: tier-2 launcher — packs, request documents, detached spawn`.

---

### Task 6: Codex adapter

**Files:** Create: `plugins/engines/codex/run`, `tests/test_engine_codex.sh`

**Interfaces:** reads request document; `operation=implement`: `cd worktree`, prompt = pack task.md + context.md + rules (never touch `.orchid/`, commit your work); `codex exec --sandbox workspace-write -c approval_policy='"never"'`; on success emit implement envelope (`summary` = first 200 chars of codex's final message or "implemented"); `operation=review|critique`: read-only sandbox, prompt from pack diff + task acceptance criteria, reply contract `VERDICT: approve|request-changes` parsed to envelope with `scope_complete:true`. Classification on failure: stderr matching `rate limit|usage limit|429`→rate_limited; `login|auth|Unauthorized`→auth; else failed. `ORCHID_DRYRUN=1` → plausible ok envelope for the requested operation, no spawn. All envelope writes atomic to the request's `output`.

- [ ] **Step 1: Test** (stubbed `codex` on PATH: one stub that prints `VERDICT: approve` for review; one that exits 1 with `429 usage limit` on stderr → assert envelope statuses `ok`/`rate_limited`; plus DRYRUN for both operations → valid envelopes per `envelope_validate`).
- [ ] **Step 2-4: RED → implement (~80 lines) → GREEN.** — [ ] **Step 5: Commit** `v0b1: codex adapter — implement and review operations`.

---

### Task 7: agy adapter (inline reviewer)

**Files:** Create: `plugins/engines/agy/run`, `tests/test_engine_agy.sh`

**Interfaces:** `operation=review|critique` ONLY (other ops → envelope `failed` + stderr note). Builds inline prompt from pack: manifest line (files + truncation flags from pack.json), acceptance criteria + stop condition from task.md frontmatter, full `diff.patch` inline. ALL flags before `-p` (empirical gotcha). Reply contract `VERDICT:` line → envelope with `scope_complete` = NOT any `truncated:true` in pack.json. Byte guard: if `diff.patch` exceeds `agy_max_bytes` (config, default 100000) → envelope `failed` (router falls back to a worktree-capable reviewer). DRYRUN honored.

- [ ] **Step 1: Test** (stub `agy`: assert prompt arrives as the LAST argv (flags-before--p shape — stub checks `$#` ordering by verifying no argv after the prompt), VERDICT parse → ok/approve; truncated pack → `scope_complete:false`; oversized diff → `failed`; DRYRUN valid).
- [ ] **Step 2-4: RED → implement (~70 lines) → GREEN.** — [ ] **Step 5: Commit** `v0b1: agy adapter — inline review with scope honesty`.

---

### Task 8: claude adapter (fallback implement/review)

**Files:** Create: `plugins/engines/claude/run`, `tests/test_engine_claude.sh`

**Interfaces:** mirrors codex adapter shape using `claude -p "<prompt>" --permission-mode acceptEdits` for implement (in worktree) and `claude -p` read-only prompt for review. Same classification, DRYRUN, envelope contract. (Real-CLI behavior is a Plan-B2 dogfood probe; tests use stubs.)

- [ ] **Steps 1-4: same TDD shape with a stub `claude`.** — [ ] **Step 5: Commit** `v0b1: claude adapter — fallback implementer and reviewer`.

---

### Task 9: `orchid verify` (INV-11)

**Files:** Create: `libexec/orchid-verify`, `tests/test_verify.sh`, `tests/inv/test_INV-11_verify_evidence.sh`

**Interfaces:** `orchid verify <task-id>` (tier-1; epoch-fenced): runs `verification_commands` frontmatter (fallback config `verify`) via `bash -c` in the task worktree (fallback repo root); writes evidence `reviews/<task>-verify.log` atomically: header `date/sha/cwd/command`, full output, `exit: <code>`; prints PASS/FAIL; exit 0/1. INV-11 test: the evidence log exists, records the exact command and exit code, and re-running flips honestly when the command's result changes (create marker → PASS after FAIL).

- [ ] **Steps 1-4: TDD** (reuse Plan A's original Task-11 test shape, plus INV-11 flip assertions). — [ ] **Step 5: Commit** `v0b1: deterministic verify with evidence (INV-11)`.

---

### Task 10: `orchid merge` (INV-07)

**Files:** Create: `libexec/orchid-merge`, `tests/test_merge.sh`, `tests/inv/test_INV-07_rebase_reverify.sh`

**Interfaces:** `orchid merge <task-id>` (tier-1; epoch-fenced; takes run lock via `lock_acquire`+trap): requires status `merging`; integration branch from config.
  - Base current (`integ HEAD == base_sha`): merge candidate in temp worktree (detached), run verification there, on pass `git update-ref refs/heads/<integ> <new> <old>` + advance task `done`; on fail exit 1 + advance `rework --reason "validation_failed"`... **correction per state machine:** merge itself performs `orchid task advance <id> done` on success and `orchid task advance <id> rework --reason "validation_failed: see reviews/<task>-merge.log"` on suite failure (merging→rework is legal, reason recorded).
  - Base stale: rebase task branch onto integ HEAD, update `base_sha`/`candidate_sha` via `orchid task set`, `orchid task advance <id> testing`, exit 5 (`rebase_rereview_required`). Reviews on the old candidate are dead by SHA change (INV-07).
  - Temp worktree always removed (trap).
- INV-07 test: after a parallel commit advances integration, `merge` exits 5, task lands in `testing` with UPDATED SHAs, and integration ref is untouched; then a verify+merge on the new SHAs succeeds; also assert the old reviews' candidate_sha no longer matches the task (staleness detectable).

- [ ] **Steps 1-4: TDD** (fixture: repo with integration branch, task branch with real commits, second task's commit landing first to force staleness). — [ ] **Step 5: Commit** `v0b1: transactional merge with rebase-reverify (INV-07)`. Push branch; STOP for review per process.

---

## Plan B2 outline (separate plan after B1)
`orchid requirements import` / `plan apply` / `run advance|accept` ownership verbs → `notify`/`answer` inbox → PROTOCOL.md + skills (orchid/orchid-plan/orchid-resume) + install.sh → E2E lifecycle test (stub engines drive pending→done via verbs exactly as PROTOCOL prescribes, single-reviewer v0 policy) → crash/fence E2E → real-engine probes (codex exec review range support; agy stdin; claude -p tick) → webBooks dogfood run → dogfood notes → v0 COMPLETE.

## Self-review notes
- Backlog sweep (T1) covers every fix-now/cheap item from the Plan-A ledger; remaining ledger items are B2/v1 concerns (per-verb locking → v1-m1 note already in kernel.md; INV-05 same-line blind spot → revisit when files grow).
- INV coverage after B1: INV-01/02/03/04/05/06/07/08/11/12 active; INV-09/10 (trust store, duplicate IDs full) are v1-m1 — kernel.md's INV list already stages them; tests to be marked pending in B2's conformance summary.
- Exit-code registry consistent: 2 unknown verb, 3 illegal transition, 5 rebase_rereview_required, 12 input_overflow.
- Type consistency: job_id shape, manifest fields, request fields, envelope fields match plugins.md; `reviews/<task>-a<attempt>-<role>.json` naming consistent between jobs reconcile and B2's protocol reading.
