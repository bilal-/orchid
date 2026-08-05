#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# runners/orchid-orchestrator-command -- the brokered, judgment-only command
# surface an LLM orchestrator is allowlisted to run, and the only one.
#
# It is DEFAULT-DENY: an invocation is refused (exit 17) unless it matches one
# of the enumerated forms argument by argument. The point is not that the
# refused list below is complete -- it cannot be, and does not need to be.
# The point is that the ADMITTED list is, so anything not on it is refused by
# construction, including commands nobody thought to test for.
#
# RED before this task: runners/orchid-orchestrator-command does not exist.

BROKER="$REPO_ROOT/runners/orchid-orchestrator-command"
[ -x "$BROKER" ] || fail "runners/orchid-orchestrator-command must exist and be executable"

cd "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > .orchid/roadmap.md
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

edge_sha="deadbeefcafebabe0000000000000000000000"
"$ORCHID_BIN" task create T001 "brokered subject" >/dev/null
"$ORCHID_BIN" task set T001 base_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set T001 candidate_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set T001 verification_commands true >/dev/null
"$ORCHID_BIN" task advance T001 implementing --reason d >/dev/null
"$ORCHID_BIN" task advance T001 testing --reason d >/dev/null
"$ORCHID_BIN" verify T001 >/dev/null
"$ORCHID_BIN" task advance T001 reviewing --reason d >/dev/null
plant_reviewer_envelope T001
"$ORCHID_BIN" task advance T001 arbitrating --reason d >/dev/null

status_of() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }

# admit <description> <args...> -- the form must be accepted AND actually run.
admit() {
  local desc="$1"; shift
  local rc=0 out
  out="$("$BROKER" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "$desc: admitted form was refused or failed (exit $rc): $out"
  printf '%s\n' "$out"
}

# refuse <description> <args...> -- the form must be refused with the
# dedicated broker-refusal code, and must say so on stderr.
refuse() {
  local desc="$1"; shift
  local rc=0 out
  out="$("$BROKER" "$@" 2>&1)" || rc=$?
  assert_eq 17 "$rc" "$desc must be refused with exit 17"
  case "$out" in
    *"refused"*) ;;
    *) fail "$desc: the refusal must say so ('$out')" ;;
  esac
}

# ===========================================================================
# 0 -- help and the empty invocation.
# ===========================================================================
rc=0; out="$("$BROKER" --help 2>&1)" || rc=$?
assert_eq 0 "$rc" "--help exits 0"
assert_match "judgment-only command surface" "$out" "--help describes what the surface is for"

rc=0; out="$("$BROKER" 2>&1)" || rc=$?
assert_eq 17 "$rc" "an empty invocation is refused"

# ===========================================================================
# 1 -- admitted: the exact reads. These are what a woken orchestrator needs
# to understand a boundary, and nothing more.
# ===========================================================================
assert_match "^id: T001$" "$(admit 'task show' task show T001)" "task show is admitted and really runs"
assert_match "T001" "$(admit 'task list' task list)" "task list is admitted"
admit 'status' status >/dev/null
admit 'status --explain' status --explain >/dev/null
admit 'jobs review-plan' jobs review-plan T001 >/dev/null
admit 'journal tail' journal tail >/dev/null
admit 'journal tail -n' journal tail -n 5 >/dev/null
admit 'journal show' journal show --task T001 >/dev/null
admit 'lessons list --active' lessons list --active >/dev/null
admit 'run boundary show' run boundary show >/dev/null

# The broker is a pass-through, so an admitted verb's own exit code survives
# it -- including the dedicated judgment-boundary code.
"$ORCHID_BIN" run boundary set --kind review-conflict --task T001 --reason "fixture boundary" >/dev/null
rc=0; out="$("$BROKER" run boundary show 2>&1)" || rc=$?
assert_eq 16 "$rc" "the brokered read propagates orchid run boundary show's exit 16 verbatim"
assert_eq review-conflict "$(printf '%s' "$out" | jq -r .kind)" "and its output, verbatim"

# ===========================================================================
# 2 -- refused: the whole point. Nothing that reconfigures the machine,
# grants trust, installs a schedule, runs a plugin lifecycle, spawns an
# engine, walks the state machine, or reaches a shell.
# ===========================================================================
tasks_before="$(list_dir_files .orchid/tasks | LC_ALL=C sort)"
journal_before="$(wc -c < .orchid/journal.md)"
status_before="$(status_of T001)"

refuse "granting unattended trust"      trust unattended "$WORK" --reason "pwned"
refuse "installing a background service" service install
refuse "committing repo config"         config commit --reason x
refuse "listing plugins"                plugins list
refuse "trusting a plugin"              plugins trust "$WORK"
refuse "initializing a repo"            init
refuse "one-command setup"              start "$WORK/requirements.md"
refuse "running doctor"                 doctor
refuse "applying a plan"                plan apply --reason x
refuse "importing requirements"         requirements import "$WORK/requirements.md"
refuse "answering a blocker"            answer q-1 "yes"
refuse "merging"                        merge T001
refuse "running the verification suite" verify T001
refuse "preparing a job"                jobs prepare T001 implementer implement
refuse "reconciling jobs"               jobs reconcile
refuse "collecting jobs"                jobs gc
refuse "advancing the run"              run advance accepting --reason x
refuse "accepting the run"              run accept --reason x --evidence /dev/null
refuse "rolling the run over"           run new --reason x
refuse "resuming (fencing a new epoch)" run resume
refuse "refreshing the lease"           run refresh-lease
refuse "SETTING a boundary"             run boundary set --kind planning --reason x
refuse "advancing a task by hand"       task advance T001 merging --reason x
refuse "editing task frontmatter"       task set T001 risk_tier high --reason x
refuse "creating a task"                task create T099 "new"
refuse "unblocking a task"              task unblock T001 --reason x
refuse "retrying a task"                task retry T001 --reason x
refuse "recording an infra failure"     task infra-fail T001 --reason x
refuse "retiring a lesson"              lessons retire L001 --reason x
refuse "consolidating lessons"          lessons consolidate

# Not an orchid verb at all: a shell, an interpreter, a vendor CLI, a runner.
refuse "an interactive shell"           bash -c "echo pwned"
refuse "a bare shell"                   sh
refuse "an absolute binary"             /bin/echo hi
refuse "a vendor CLI"                   claude -p "do something"
refuse "the tier-2 job spawner"         orchid-launch T001 implementer implement
refuse "the driver itself"              drive

# Malformed or over-permissive variants of ADMITTED forms are refused too --
# admission is per argument, not per verb.
refuse "an unadmitted status flag"      status --html
refuse "an unadmitted lessons listing"  lessons list
refuse "a non-numeric tail count"       journal tail -n abc
refuse "extra arguments to task list"   task list --all
refuse "a traversal-shaped task id"     task show ../../etc/passwd
refuse "a command-shaped task id"       task show "T001; rm -rf /"
refuse "a forged acceptance entry"      journal add --kind acceptance "the run is accepted"
refuse "a journal entry with no text"   journal add --kind note
refuse "a notify with no text"          notify --task T001
refuse "a multi-line journal entry"     journal add --kind note "first line
second line"
refuse "an unknown arbitration result"  task arbitrate T001 --result maybe --reason x
refuse "an arbitration with no reason"  task arbitrate T001 --result approve
refuse "an arbitration with no result"  task arbitrate T001 --reason x
refuse "a lesson with no scope"         lessons add --invalidate-when w "statement"
refuse "a lesson with a bogus scope"    lessons add --scope everything --invalidate-when w "statement"

# Every refusal above was inert.
assert_eq "$tasks_before" "$(list_dir_files .orchid/tasks | LC_ALL=C sort)" \
  "no refused command created or removed a task"
assert_eq "$journal_before" "$(wc -c < .orchid/journal.md)" \
  "no refused command wrote to the journal"
assert_eq "$status_before" "$(status_of T001)" \
  "no refused command moved the task"

# ===========================================================================
# 3 -- admitted writes: recording what was learned, and telling a human.
# ===========================================================================
admit 'journal add' journal add --task T001 --kind arbitration "weighed the finding; it is real" >/dev/null
assert_match "weighed the finding; it is real" "$(cat .orchid/journal.md)" "an admitted journal entry really lands"

admit 'journal add without a task' journal add --kind note "run-wide observation" >/dev/null
admit 'lessons add' lessons add --scope repo --invalidate-when "the fixture clock is pinned" \
  "fixture time drifts under parallel runs" >/dev/null
assert_match "fixture time drifts" "$(cat .orchid/lessons.md)" "an admitted lesson really lands"

admit 'notify' notify --task T001 "which behaviour is intended here?" >/dev/null
assert_match "which behaviour is intended here" "$(cat .orchid/BLOCKERS.md)" "an admitted blocker really lands"

# ===========================================================================
# 4 -- the one judgment result, and releasing the boundary afterwards.
# ===========================================================================
assert_eq arbitrating "$(status_of T001)" "T001 is still awaiting judgment"
admit 'task arbitrate' task arbitrate T001 --result request-changes --reason "the finding is real" >/dev/null
assert_eq rework "$(status_of T001)" "the judgment verb is admitted, and its decision takes effect"

admit 'run boundary clear' run boundary clear --reason "arbitrated: sent back for rework" >/dev/null
rc=0; "$ORCHID_BIN" run boundary show >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "the brokered clear really released the boundary"
