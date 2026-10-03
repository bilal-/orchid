#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# A task's status says which evidence it owns, not whether an engine still
# owns its checkout. Construct a real integration checkout and a live process.
rb_repo="$WORK/repo"
rb_integration="$WORK/integration"
rb_worktree="$WORK/task"
mkdir -p "$rb_repo"
git -C "$rb_repo" init -q
git -C "$rb_repo" commit -q --allow-empty -m root
ORCHID_REPO="$rb_repo" "$ORCHID_BIN" init >/dev/null \
  || { fail 'fixture: init'; exit 1; }
git -C "$rb_repo" worktree add -q "$rb_integration" orchid/integration \
  || { fail 'fixture: integration worktree'; exit 1; }
export ORCHID_REPO="$rb_integration"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# Prepare through the supported verb; the fake engine needs no vendor CLI.
export ORCHID_ENGINES_DIR="$WORK/engines"
mkdir -p "$ORCHID_ENGINES_DIR/fake"
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$ORCHID_ENGINES_DIR/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$ORCHID_ENGINES_DIR/fake/run"
chmod +x "$ORCHID_ENGINES_DIR/fake/run"
printf 'verify=true\nrole.implementer=fake\n' > "$rb_integration/orchid.config"
"$ORCHID_BIN" task create RB1 "sibling rebase safety" >/dev/null \
  || { fail 'fixture: task create'; exit 1; }
rb_base="$(git -C "$rb_repo" rev-parse orchid/integration)"
git -C "$rb_repo" branch task/RB1 "$rb_base"
git -C "$rb_repo" worktree add -q "$rb_worktree" task/RB1 \
  || { fail 'fixture: task worktree'; exit 1; }
printf 'task work\n' > "$rb_worktree/task.txt"
git -C "$rb_worktree" add task.txt
git -C "$rb_worktree" commit -q -m task
"$ORCHID_BIN" task set RB1 worktree "$rb_worktree" >/dev/null \
  || { fail 'fixture: record worktree'; exit 1; }
"$ORCHID_BIN" task set RB1 base_sha "$rb_base" >/dev/null \
  || { fail 'fixture: record base'; exit 1; }
"$ORCHID_BIN" task advance RB1 implementing >/dev/null \
  || { fail 'fixture: dispatch'; exit 1; }

rb_move_integration() {
  git -C "$rb_integration" commit -q --allow-empty -m sibling \
    || { fail 'fixture: move integration'; exit 1; }
  rb_target="$(git -C "$rb_repo" rev-parse orchid/integration)"
}

rb_assert_refused() {
  local label="$1" before_sha before_base before_attempts before_journal rc=0 out
  before_sha="$(git -C "$rb_worktree" rev-parse HEAD)"
  before_base="$("$ORCHID_BIN" task get RB1 base_sha)"
  before_attempts="$("$ORCHID_BIN" task get RB1 attempts)"
  before_journal="$(cat "$rb_integration/.orchid/journal.md")"
  out="$("$ORCHID_BIN" task rebase RB1 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: rebase must refuse an outstanding job"
  assert_match "$rb_job_id" "$out" "$label: refusal names the owning job"
  assert_match 'orchid jobs reconcile' "$out" "$label: refusal names recovery"
  assert_eq "$before_sha" "$(git -C "$rb_worktree" rev-parse HEAD)" "$label: candidate unchanged"
  assert_eq "$before_base" "$("$ORCHID_BIN" task get RB1 base_sha)" "$label: base unchanged"
  assert_eq "$before_attempts" "$("$ORCHID_BIN" task get RB1 attempts)" "$label: attempts unchanged"
  assert_eq "$before_journal" "$(cat "$rb_integration/.orchid/journal.md")" "$label: refusal precedes intervention journal"
}

rb_move_integration
rb_job="$("$ORCHID_BIN" jobs prepare RB1 implementer implement)" \
  || { fail 'fixture: prepare live job'; exit 1; }
rb_job_id="$(jq -r .job_id "$rb_job")"
sleep 100 &
rb_pid=$!
# Only synthetic runtime fields are changed, matching tests/test_jobs.sh.
jq --argjson pid "$rb_pid" '.pid=$pid' "$rb_job" > "$WORK/live.json"
mv "$WORK/live.json" "$rb_job"
rb_rows="$("$ORCHID_BIN" jobs ls --tsv)"
assert_match "$rb_job_id.*running" "$rb_rows" "fixture: Orchid reports the implementer live"
kill -0 "$rb_pid" 2>/dev/null || fail "fixture: implementer process must be alive"
rb_assert_refused 'live implementer'
kill -0 "$rb_pid" 2>/dev/null || fail "refusing a rebase must leave the implementer alive"
kill "$rb_pid" 2>/dev/null || true
wait "$rb_pid" 2>/dev/null || true
rm -f "$rb_job"
red_case 'rebase refuses a live implementer before changing its checkout, base, attempt count, or journal'

# A newly prepared manifest can still be handed to a launcher. Absence of a
# stamped PID or log cannot authorize racing that launch with a rebase.
rb_move_integration
rb_job="$("$ORCHID_BIN" jobs prepare RB1 implementer implement)" \
  || { fail 'fixture: prepare pending launch'; exit 1; }
rb_job_id="$(jq -r .job_id "$rb_job")"
rb_rows="$("$ORCHID_BIN" jobs ls --tsv)"
assert_match "$rb_job_id.*never-started" "$rb_rows" "fixture: pending launch has no PID or log"
rb_assert_refused 'pending launch'
rm -f "$rb_job"
red_case 'rebase refuses a prepared job even before its launcher creates a log or stamps a process identity'

# The gate is task-scoped: an unrelated task's job must not prevent this
# idle sibling from moving to the integration head.
"$ORCHID_BIN" task create OTHER "unrelated implementer" >/dev/null \
  || { fail 'fixture: create unrelated task'; exit 1; }
"$ORCHID_BIN" task advance OTHER implementing >/dev/null \
  || { fail 'fixture: dispatch unrelated task'; exit 1; }
rb_job="$("$ORCHID_BIN" jobs prepare OTHER implementer implement)" \
  || { fail 'fixture: prepare unrelated job'; exit 1; }
jq --argjson pid "$$" '.pid=$pid' "$rb_job" > "$WORK/other.json"
mv "$WORK/other.json" "$rb_job"
rb_before_attempts="$("$ORCHID_BIN" task get RB1 attempts)"
rb_rc=0
rb_out="$("$ORCHID_BIN" task rebase RB1 2>&1)" || rb_rc=$?
assert_eq 0 "$rb_rc" "idle sibling accepts a rebase with an unrelated live job (out: $rb_out)"
assert_eq "$rb_target" "$("$ORCHID_BIN" task get RB1 base_sha)" "successful rebase records the actual integration head"
git -C "$rb_worktree" merge-base --is-ancestor "$rb_target" HEAD \
  || fail "successful candidate must descend from the recorded integration head"
assert_eq 'task work' "$(cat "$rb_worktree/task.txt")" "rebase preserves the sibling's own committed work"
assert_eq "$rb_before_attempts" "$("$ORCHID_BIN" task get RB1 attempts)" "a successful rebase spends no attempt"
green_case 'rebase accepts an idle sibling despite an unrelated live job, preserves its work, and records its true base without charging an attempt'
