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

cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks .orchid/reviews
printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > .orchid/roadmap.md
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH

# This repo's own HEAD, for both shas: entry to `testing` scans a real, EMPTY
# range. A placeholder that exists nowhere used to serve here, and T026 made
# that scan fail CLOSED on a range `git log` cannot answer.
edge_sha="$(git rev-parse HEAD)"
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
# T035: the read-only process table. This seat was one of the two readers that
# got dogfood F36 wrong -- a woken orchestrator reported a critique as actively
# working, and quoted its findings, while the job had been dead for twelve and
# a half hours. It had no admitted way to ask whether anything was alive.
admit 'jobs ls' jobs ls >/dev/null
admit 'jobs ls --all' jobs ls --all >/dev/null
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
# T039: `reviews/` is durable state too, and it is where the refused
# `jobs review-plan --pin|--repin|--adopt-evidence` forms below would land a
# pinned slot plan. Without this capture those three refusals would be
# asserted only on their exit code -- and a broker that refused loudly while
# the verb had already written would pass.
reviews_before="$(list_dir_files .orchid/reviews | LC_ALL=C sort)"
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
# T021: the verb that SATISFIES the planning cross-check. Refused here for the
# same reason the `plan_deferral` journal kind is below -- deciding what a plan
# will not carry is operator work, and an orchestrator that could defer a
# carried-forward item could retire the previous run's findings without anyone
# deciding to. Refused in every run_status, which is the whole set the verb is
# now legal in for an operator: this arm runs against a fixture that has left
# planning, so widening the verb's own precondition must never widen this.
refuse "deferring a carried item"       plan defer L001 --reason x
refuse "importing requirements"         requirements import "$WORK/requirements.md"
refuse "answering a blocker"            answer q-1 "yes"
refuse "merging"                        merge T001
refuse "running the verification suite" verify T001
refuse "preparing a job"                jobs prepare T001 implementer implement
refuse "reconciling jobs"               jobs reconcile
refuse "collecting jobs"                jobs gc
# A command that never returns is exactly what this surface exists to bound:
# admitting the table does not admit polling it forever.
refuse "watching the job table"         jobs ls --watch
refuse "an unadmitted jobs ls modifier" jobs ls --tsv
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
refuse "re-verifying a task"            task reverify T001 --reason x
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
# T039: `jobs review-plan` grew three WRITING forms (they pin the reviewer-slot
# plan under .orchid/reviews). The bare read stays admitted -- a woken
# orchestrator judges evidence against the plan its attempt was dispatched
# under, and the bare read now returns exactly that pinned table -- but this
# surface must not be able to MOVE the plan. Re-pinning is how a plan and its
# evidence are brought back into agreement, and a boundary that an
# orchestrator could settle by re-pinning until the numbers line up is not a
# judgment at all. The arity check is what refuses these, so all three are
# named: an admission widened to "review-plan plus flags" would let every one
# of them through at once.
refuse "pinning the review plan"        jobs review-plan T001 --pin
refuse "re-pinning the review plan"     jobs review-plan T001 --repin
refuse "adopting review evidence"       jobs review-plan T001 --adopt-evidence

refuse "an unadmitted status flag"      status --html
refuse "an unadmitted lessons listing"  lessons list
refuse "a non-numeric tail count"       journal tail -n abc
refuse "extra arguments to task list"   task list --all
refuse "a traversal-shaped task id"     task show ../../etc/passwd
refuse "a command-shaped task id"       task show "T001; rm -rf /"
refuse "a forged acceptance entry"      journal add --kind acceptance "the run is accepted"
# T021, and the sharpest of the forged-kind refusals: `plan_deferral` is what
# SATISFIES the planning cross-check for a carried-forward item. An
# orchestrator able to write one free-standing could talk the next plan out of
# a defect the previous run recorded -- without ever running `orchid plan
# defer`, which refuses an unknown id, refuses a re-deferral, and refuses once
# planning is over. Pinned, because a comment saying the kind is excluded is
# not a mechanism that keeps it excluded (L016).
refuse "a forged planning deferral"     journal add --kind plan_deferral "deferred L016: not this run"
refuse "a journal entry with no text"   journal add --kind note
refuse "a notify with no text"          notify --task T001
refuse "a choice with no value"         notify --choice
refuse "a command-shaped choice value"  notify --choice "rm -rf /" --task T001 "question"
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
assert_eq "$reviews_before" "$(list_dir_files .orchid/reviews | LC_ALL=C sort)" \
  "no refused command wrote to reviews/ — in particular, none of the three review-plan writing forms landed a pinned slot plan on its way to being refused"
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
# T021: the converse of the `plan_deferral` refusal above. Arbitration is
# where a run decides a real defect is out of THIS task's scope, and the
# orchestrator is the actor that decides it -- so the kind the NEXT run's
# planning cross-check reads back out of the archived journal has to be
# writable from here, or a finding this run knowingly does not close leaves
# no trace for the next plan to be held to.
admit 'journal add --kind ledger' journal add --task T001 --kind ledger \
  "libexec/orchid-task stamps started_at only when empty; real, out of this task's scope" >/dev/null
assert_match "stamps started_at only when empty" "$(cat .orchid/journal.md)" \
  "an admitted ledger entry really lands, so the next run's cross-check has something to read"

admit 'lessons add' lessons add --scope repo --invalidate-when "the fixture clock is pinned" \
  "fixture time drifts under parallel runs" >/dev/null
assert_match "fixture time drifts" "$(cat .orchid/lessons.md)" "an admitted lesson really lands"

admit 'notify' notify --task T001 "which behaviour is intended here?" >/dev/null
assert_match "which behaviour is intended here" "$(cat .orchid/BLOCKERS.md)" "an admitted blocker really lands"

admit 'notify with declared choices' notify --task T001 --choice approve --choice request-changes \
  "approve the candidate or send it back?" >/dev/null
assert_match "choices: approve \| request-changes" "$(cat .orchid/BLOCKERS.md)" \
  "the brokered choice set really lands with the question (T039: a new flag must be admitted deliberately, never auto-refused into silence)"

# ===========================================================================
# 3b -- T021: this surface and the orchestrate PROMPTS must agree.
#
# The two halves already proven above -- `ledger` admitted, `plan_deferral`
# refused -- are only half a mechanism. What a woken orchestrator actually
# runs is what its prompt asks for, and an admitted verb no prompt names is a
# verb nobody runs: the ledger stays empty, and the next run's planning
# cross-check reads that emptiness as "the previous run found nothing". The
# mismatch was live in this tree -- both shipped orchestrate prompts named
# only `--kind arbitration` -- and it is the L016 shape the cross-check itself
# exists to close, one layer up: the surface permitted the recording, and
# nothing asked for it.
#
# So each adapter's prompt is required to name the admitted form and to forbid
# the refused one, here, beside the two runs that prove which is which.
# tests/test_drive.sh's Part R sweeps the same clauses from the driver's side,
# where the classification of what a surface can be relied on to run lives;
# this end is what ties them to a broker that really answered 0 and 17.
prompt_adapters=0
for _prun in "$REPO_ROOT"/plugins/engines/*/run; do
  [ -f "$_prun" ] || continue
  grep -q 'operation" = orchestrate' "$_prun" || continue
  _pname="$(basename "$(dirname "$_prun")")"
  _pinstr="$(grep 'instructions=' "$_prun" || true)"
  [ -n "$_pinstr" ] \
    || fail "$_pname handles orchestrate but builds no instruction block this check can read"
  prompt_adapters=$(( prompt_adapters + 1 ))
  case "$_pinstr" in
    *"--kind ledger"*) ;;
    *) fail "$_pname's orchestrate prompt never asks for the ledger kind this surface admits — an out-of-scope finding it approves past would reach the next plan as silence" ;;
  esac
  case "$_pinstr" in
    *"never journal add --kind plan_deferral"*) ;;
    *) fail "$_pname's orchestrate prompt does not forbid the deferral kind this surface refuses — the two must say the same thing, and only the brokered adapter's list is enforced" ;;
  esac
done
[ "$prompt_adapters" -ge 2 ] \
  || fail "the prompt/surface agreement check swept $prompt_adapters orchestrate-capable adapter(s) — it is not looking at the shipped ones"

# ===========================================================================
# 4 -- the one judgment result, and releasing the boundary afterwards.
# ===========================================================================
assert_eq arbitrating "$(status_of T001)" "T001 is still awaiting judgment"
admit 'task arbitrate' task arbitrate T001 --result request-changes --reason "the finding is real" >/dev/null
assert_eq rework "$(status_of T001)" "the judgment verb is admitted, and its decision takes effect"

admit 'run boundary clear' run boundary clear --reason "arbitrated: sent back for rework" >/dev/null
rc=0; "$ORCHID_BIN" run boundary show >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "the brokered clear really released the boundary"
