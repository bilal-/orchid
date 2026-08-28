#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# Two things the deterministic driver must get right without ever naming
# anything:
#
#   HOOKS -- a hook is a JOB, so the driver dispatches a bound point and
#   DEFERS the step that point guards to the next pass rather than blocking a
#   pass on an engine. `optional` never gates; `:required` without an ok
#   envelope for the current candidate raises a hook-failure boundary and
#   takes NO transition.
#
#   ARCHETYPES -- the walk is driven by an archetype's DECLARED
#   `transitions=`/`outcome=`, never by its name. A report archetype builds no
#   worktree and never merges; a custom archetype nobody wrote code for takes
#   exactly the same code path.
#
# RED before this task: runners/orchid-drive and lib/drive.sh do not exist.

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/archetype.sh"
source "$REPO_ROOT/lib/schedule.sh"
source "$REPO_ROOT/lib/drive.sh"
export ORCHID_ROOT="$REPO_ROOT"

DRIVE="$REPO_ROOT/runners/orchid-drive"
export ORCHID_ENGINES_DIR="$WORK/eng"
export HOME="$MACHINE_HOME"
# The candidate range every fixture task below is given: the CURRENT scenario
# repository's own HEAD, on both ends, so entry to `testing` scans a real,
# EMPTY range. `use_repo` re-derives it for each disposable repo, because each
# one has a root commit of its own and a sha from the previous repo would not
# resolve here.
#
# It used to be one placeholder sha that exists in no repository at all, which
# made `git log <base>..<candidate>` FAIL rather than answer -- and the INV-04
# scan read that silence as a clean range. T026 made the scan fail CLOSED, so a
# range nothing can walk is refused in the same direction every other
# unreadable-input check in this codebase fails.
#
# T031 additionally requires that real HEAD: verify now refuses a worktree
# that is not the recorded candidate, and H4 depends on verify genuinely
# running and failing.
edge_sha=""

# --- hook plugins ----------------------------------------------------------
# `hookok` reports success and carries a guidance artifact; `hookbad` reports
# a plain failure. Both are kind=hook, discovered exactly like any engine.
mkdir -p "$WORK/eng/hookok" "$WORK/eng/hookbad"
printf 'manifest_version=1\nid=test/hookok\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/hookok/plugin.conf"
cat > "$WORK/eng/hookok/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
cand="$(jq -r '.candidate_sha // ""' "$req")"
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"hook", status:"ok",
    engine:"test/hookok", candidate_sha:$cand,
    artifact:{guidance:"pin the fixture clock before re-running"}, summary:"hook ok"}' > "$out"
EOF
chmod +x "$WORK/eng/hookok/run"

printf 'manifest_version=1\nid=test/hookbad\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/hookbad/plugin.conf"
cat > "$WORK/eng/hookbad/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
cand="$(jq -r '.candidate_sha // ""' "$req")"
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"hook", status:"failed",
    engine:"test/hookbad", candidate_sha:$cand, summary:"hook failed"}' > "$out"
EOF
chmod +x "$WORK/eng/hookbad/run"

# `hookmute` runs and exits cleanly WITHOUT writing an envelope at all -- the
# handler that dies (or is killed, or was misconfigured) leaving nothing
# behind. Distinct from hookbad, which reports a failure in a valid envelope.
mkdir -p "$WORK/eng/hookmute"
printf 'manifest_version=1\nid=test/hookmute\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/hookmute/plugin.conf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/eng/hookmute/run"
chmod +x "$WORK/eng/hookmute/run"

# `hookprose` reports success carrying MULTI-PARAGRAPH guidance -- the natural
# thing for a handler asked to explain a verify failure to write, and (T034,
# dogfood F34) the one value on the whole driver path that is neither typed by
# an operator nor bounded by a schema. Frontmatter holds one line per key, so
# `task set` refuses a newline outright; the driver must therefore FOLD this to
# one line rather than hand it over and abort an autonomous round -- and, before
# T034, handing it over destroyed the task file mid-run with no operator
# present at all.
mkdir -p "$WORK/eng/hookprose"
printf 'manifest_version=1\nid=test/hookprose\nversion=0.1.0\nkind=hook\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/hookprose/plugin.conf"
cat > "$WORK/eng/hookprose/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
cand="$(jq -r '.candidate_sha // ""' "$req")"
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  --arg g "$(printf 'the first paragraph of prose guidance\n\nthe second paragraph of prose guidance')" \
  '{contract:1, job_id:$jid, task:$task, operation:"hook", status:"ok",
    engine:"test/hookprose", candidate_sha:$cand,
    artifact:{guidance:$g}, summary:"hook ok, multi-paragraph guidance"}' > "$out"
EOF
chmod +x "$WORK/eng/hookprose/run"

# --- a stub reviewer, for the archetype walks ------------------------------
mkdir -p "$WORK/eng/stubreview" "$WORK/eng/stubimpl"
printf 'manifest_version=1\nid=test/stubreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubreview/plugin.conf"
cat > "$WORK/eng/stubreview/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
cand="$(jq -r .candidate_sha "$req")"
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"stub review", candidate_sha:$cand, findings:[]}' > "$out"
EOF
chmod +x "$WORK/eng/stubreview/run"

printf 'manifest_version=1\nid=test/stubimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/stubimpl/plugin.conf"
cat > "$WORK/eng/stubimpl/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
jq -n --arg jid "$jid" --arg task "$task" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok", summary:"noop"}' > "$out"
EOF
chmod +x "$WORK/eng/stubimpl/run"

# --- fixture helpers -------------------------------------------------------
# Each scenario gets its OWN disposable repository, so a boundary raised by
# one can never be attributed to another (the driver records the first
# boundary of a pass, in task-id order).
use_repo() {
  local d="$WORK/$1"
  mkdir -p "$d/.orchid/tasks" "$d/.orchid/reviews"
  ( cd "$d" && git init -q . && git commit -q --allow-empty -m root \
      && git branch -f orchid/integration HEAD ) >/dev/null 2>&1
  printf -- '---\nrun_status: running\nrun_id: r-001\n---\n# Roadmap\n' > "$d/.orchid/roadmap.md"
  cd "$d" || exit 1
  export ORCHID_REPO="$d"
  # Re-derived per repo -- see the comment on `edge_sha` above.
  edge_sha="$(git -C "$d" rev-parse HEAD)"
  ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
  export ORCHID_EPOCH
}

status_of() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }
field_of() { "$ORCHID_BIN" task show "$1" | grep "^$2: " | cut -d' ' -f2-; }

# to_arbitrating <id> -- the light-weight walk tests/test_task.sh uses for
# archetype edge coverage: this repo's own HEAD on both ends of the candidate
# range (a real, EMPTY range, so INV-04's scan runs and finds nothing) plus
# verification_commands=true.
to_arbitrating() {
  local id="$1"
  "$ORCHID_BIN" task create "$id" "hook subject" >/dev/null
  "$ORCHID_BIN" task set "$id" base_sha "$edge_sha" >/dev/null
  "$ORCHID_BIN" task set "$id" candidate_sha "$edge_sha" >/dev/null
  "$ORCHID_BIN" task set "$id" verification_commands true >/dev/null
  "$ORCHID_BIN" task advance "$id" implementing --reason d >/dev/null
  "$ORCHID_BIN" task advance "$id" testing --reason d >/dev/null
  "$ORCHID_BIN" verify "$id" >/dev/null
  "$ORCHID_BIN" task advance "$id" reviewing --reason d >/dev/null
  plant_reviewer_envelope "$id"
  "$ORCHID_BIN" task advance "$id" arbitrating --reason d >/dev/null
}

DRIVE_RC=0
DRIVE_OUT=""
run_drive() {
  DRIVE_RC=0
  DRIVE_OUT="$("$DRIVE" 2>&1)" || DRIVE_RC=$?
}

# drive_settle -- passes until the driver stops changing anything, bounded.
# Hook jobs are real background processes, so a pass may legitimately report
# "awaiting" once or twice before the envelope lands.
drive_settle() {
  local want_status="$1" id="$2" i=0
  while [ "$i" -lt 25 ]; do
    run_drive
    if [ "$(status_of "$id")" = "$want_status" ]; then return 0; fi
    i=$((i + 1))
    sleep 0.3
  done
  return 1
}

# ===========================================================================
# H1 -- an OPTIONAL before_arbitration hook: dispatched on one pass, read on
# the next, and the approval proceeds. The hook's artifact is an input to the
# same weighing, never a separate decision.
# ===========================================================================
use_repo h1
printf 'hook.before_arbitration=hookok\n' > orchid.config
to_arbitrating H1
run_drive
assert_eq 0 "$DRIVE_RC" "dispatching a hook is not a boundary"
assert_match "dispatched the before_arbitration hook" "$DRIVE_OUT" \
  "the pass says it dispatched the hook and deferred the step it guards"
assert_eq arbitrating "$(status_of H1)" "the guarded step is deferred, not taken, while the hook is in flight"

drive_settle merging H1 || fail "once the hook envelope lands, the approval proceeds (last rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq merging "$(status_of H1)" "an ok optional hook does not stand in the way of a deterministic approval"
ls .orchid/reviews/H1-a1-hook-before_arbitration*.json >/dev/null 2>&1 \
  || fail "the hook envelope must reconcile under the hook-point filename"

# ===========================================================================
# H2 -- a :required before_arbitration hook that FAILS: a hook-failure
# boundary, and NO transition. A required dependency that did not pass is not
# something deterministic policy may shrug off.
# ===========================================================================
use_repo h2
printf 'hook.before_arbitration=hookbad:required\n' > orchid.config
to_arbitrating H2
i=0
while [ "$i" -lt 25 ]; do
  run_drive
  [ "$DRIVE_RC" -eq 16 ] && break
  i=$((i + 1)); sleep 0.3
done
assert_eq 16 "$DRIVE_RC" "a failed required hook stops the pass at a judgment boundary"
assert_eq arbitrating "$(status_of H2)" "a failed required hook takes NO transition"
boundary="$("$ORCHID_BIN" run boundary show 2>&1 || true)"
assert_eq hook-failure "$(printf '%s' "$boundary" | jq -r .kind)" "the boundary kind names the hook failure"
assert_match "hookbad" "$(printf '%s' "$boundary" | jq -r .reason)" "the boundary names the binding that failed"

# ===========================================================================
# H3 -- an OPTIONAL hook that fails never gates anything, on any point.
# ===========================================================================
use_repo h3
printf 'hook.before_arbitration=hookbad\n' > orchid.config
to_arbitrating H3
drive_settle merging H3 || fail "a failing OPTIONAL hook must never block (last rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq merging "$(status_of H3)" "an optional hook's failure is read and moved past"

# ===========================================================================
# H3b -- ...and neither does an optional hook that files NO envelope at all.
# H3 above covers the handler that reports a failure; this is the handler that
# dies leaving nothing behind, which is the shape that could loop forever: no
# envelope means "nothing has run yet", so a driver that cannot tell required
# from optional here re-dispatches the point on every pass and walks the
# task's infra_failures counter to its auto-block cap while the step it guards
# never happens.
# ===========================================================================
use_repo h3b
printf 'hook.before_arbitration=hookmute\n' > orchid.config
to_arbitrating H3B
drive_settle merging H3B \
  || fail "an OPTIONAL hook that files no envelope must never gate the step it guards (last rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq merging "$(status_of H3B)" "the guarded step is taken once the hook's job has resolved, envelope or not"
assert_eq 0 "$(field_of H3B infra_failures)" \
  "a binding that gates nothing must not spend the task's infra_failures budget either"
[ ! -e .orchid/reviews/H3B-a1-hook-before_arbitration.json ] \
  || fail "fixture sanity: hookmute must really file no envelope"

# ===========================================================================
# H5 -- a `:required` hook must stay RE-RUNNABLE when candidate_sha moves
# WITHIN one attempt (the merging->testing rebase edge does exactly that).
# Satisfaction is bound to the current candidate, so evidence from the
# previous one is not evidence here; counting it as "the point already
# answered" would leave the binding permanently unsatisfiable and the guarded
# step gated forever, with no verb able to release it.
# ===========================================================================
use_repo h5
printf 'hook.before_arbitration=hookok:required\n' > orchid.config

# plant_review <id> <candidate> <verdict> <suffix>
plant_review() {
  jq -n --arg jid "j-fixture-$1-$4" --arg task "$1" --arg cand "$2" --arg v "$3" \
    '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
      verdict:$v, scope_complete:true, summary:"fixture reviewer", candidate_sha:$cand}' \
    > ".orchid/reviews/$1-a1-reviewer$4.json"
}

to_arbitrating H5
# Contested, so the pass stops in `arbitrating` instead of running on: what
# this phase proves is that the required hook was SATISFIED for this
# candidate (an unsatisfied one would raise hook-failure instead).
plant_review H5 "$edge_sha" request-changes ""
i=0
while [ "$i" -lt 25 ]; do
  run_drive
  [ "$DRIVE_RC" -eq 16 ] && [ "$("$ORCHID_BIN" run boundary show 2>/dev/null | jq -r .kind)" = review-conflict ] && break
  i=$((i + 1)); sleep 0.3
done
assert_eq review-conflict "$("$ORCHID_BIN" run boundary show 2>/dev/null | jq -r .kind)" \
  "the required hook is satisfied for the first candidate, so the pass gets as far as the verdicts (out: $DRIVE_OUT)"
assert_eq arbitrating "$(status_of H5)" "and takes no transition on a contested review"

# The candidate moves under the same attempt, and the reviews are re-planted
# against it. The hook's earlier envelope belongs to the old candidate.
new_cand="feedfacefeedfacefeedfacefeedface00000000"
fm_set .orchid/tasks/H5.md candidate_sha "$new_cand"
plant_review H5 "$new_cand" approve ".2"

drive_settle merging H5 \
  || fail "a required hook must be dispatched again for the NEW candidate, not gated forever on the old one's envelope (last rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq merging "$(status_of H5)" "once the hook has an ok envelope for the current candidate, the approval proceeds"
ls .orchid/reviews/H5-a1-hook-before_arbitration.2.json >/dev/null 2>&1 \
  || fail "the point must have been dispatched a SECOND time, filing a second hook envelope"

# ===========================================================================
# H4 -- on_verify_fail: the hook's guidance is attached to the task through
# `orchid task set <id> hook_guidance` BEFORE the rework advance, exactly as
# PROTOCOL.md specifies.
# ===========================================================================
use_repo h4
printf 'hook.on_verify_fail=hookok\n' > orchid.config
"$ORCHID_BIN" task create H4 "verify fails" >/dev/null
"$ORCHID_BIN" task set H4 base_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set H4 candidate_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set H4 verification_commands false >/dev/null
"$ORCHID_BIN" task advance H4 implementing --reason d >/dev/null
"$ORCHID_BIN" task advance H4 testing --reason d >/dev/null

drive_settle rework H4 || fail "a failing verify must reach rework once the hook has been read (last rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq rework "$(status_of H4)" "verify FAIL walks the task to rework"
assert_eq "pin the fixture clock before re-running" "$(field_of H4 hook_guidance)" \
  "the on_verify_fail hook's guidance is attached to the task before the rework advance"

# ===========================================================================
# H6 (T034, dogfood F34) -- on_verify_fail guidance that spans PARAGRAPHS.
#
# Same walk as H4, one difference: the handler writes prose. Frontmatter is one
# `key: value` per line, so `orchid task set` now refuses a newline-bearing
# value outright -- correct for an operator typing one, and the wrong answer
# here, where the guidance is advisory (it never changes a routing decision)
# and there is no operator present to retype it. The driver folds it to one
# line instead, so the round completes and every word stays attached to the
# task.
#
# Before T034 this path did neither: `task set` attempted the write, the
# rewrite died inside awk's own argument parsing, and the task file was left at
# ZERO BYTES mid-run -- which is why the assertions below are as much about the
# task still EXISTING as about the value.
# ===========================================================================
use_repo h6
printf 'hook.on_verify_fail=hookprose\n' > orchid.config
"$ORCHID_BIN" task create H6 "verify fails, prose guidance" >/dev/null
"$ORCHID_BIN" task set H6 base_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set H6 candidate_sha "$edge_sha" >/dev/null
"$ORCHID_BIN" task set H6 verification_commands false >/dev/null
"$ORCHID_BIN" task advance H6 implementing --reason d >/dev/null
"$ORCHID_BIN" task advance H6 testing --reason d >/dev/null

drive_settle rework H6 \
  || fail "multi-paragraph hook guidance must not stop the round: a failing verify still has to reach rework (last rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq rework "$(status_of H6)" "the round completes rather than aborting over a formatting detail nobody chose"
# `task show` exits non-zero on a damaged task file now, so `field_of` reaching
# a value at all is itself the evidence the file survived the write.
assert_eq "the first paragraph of prose guidance  the second paragraph of prose guidance" \
  "$(field_of H6 hook_guidance)" \
  "the paragraphs are FOLDED onto one line, keeping every word attached to the task"
assert_eq 1 "$(grep -c '^hook_guidance: ' .orchid/tasks/H6.md)" \
  "and land as exactly one frontmatter line -- a second line would be body text no reader of this field ever sees"
[ -s .orchid/tasks/H6.md ] || fail "THE TASK FILE IS EMPTY: attaching prose guidance destroyed it mid-run, which is the defect F34 found"

# ===========================================================================
# A1 -- dispatch targets are read off the DECLARED transitions. No archetype
# name appears in the driver; these four all resolve through the same lookup.
# ===========================================================================
export ORCHID_ARCHETYPES_DIR="$WORK/arch"
mkdir -p "$WORK/arch/audit"
printf 'manifest_version=1\nid=test/audit\nversion=0.1.0\nkind=archetype\napi_version=1\noutcome=report\ntransitions=pending:reviewing,reviewing:arbitrating,arbitrating:done,arbitrating:rework,rework:reviewing\n' \
  > "$WORK/arch/audit/plugin.conf"
archetype_validate audit >/dev/null || fail "the custom archetype fixture must satisfy the meta-contract"

assert_eq implementing "$(drive_dispatch_target feature pending)" "feature dispatches into implementing"
assert_eq implementing "$(drive_dispatch_target test pending)" "the shipped test archetype dispatches into implementing"
assert_eq reviewing "$(drive_dispatch_target review pending)" "the shipped review archetype dispatches straight into reviewing"
assert_eq reviewing "$(drive_dispatch_target audit pending)" "a custom archetype dispatches into whatever IT declares"
assert_eq reviewing "$(drive_dispatch_target audit rework)" "the same lookup serves the rework re-dispatch edge"
assert_eq "" "$(drive_dispatch_target audit merging)" "a status the archetype declares no active edge out of yields nothing"

# T026: the reverify edge (`<idle>:testing`) is NOT a dispatch target, and the
# lookup must not depend on the ORDER an archetype lists its transitions in.
# The scan is first-active-wins, so an archetype that merely wrote
# `rework:testing` before `rework:implementing` would otherwise send every
# reworked task straight back into verification of the candidate that just
# failed -- no implementer spawned, no operator vouching for the tree, which
# is the whole precondition that edge carries. This fixture writes them in
# exactly that order.
mkdir -p "$WORK/arch/reordered"
printf 'manifest_version=1\nid=test/reordered\nversion=0.1.0\nkind=archetype\napi_version=1\noutcome=code\ntransitions=pending:implementing,implementing:testing,testing:reviewing,testing:rework,reviewing:arbitrating,arbitrating:merging,arbitrating:rework,merging:done,merging:rework,merging:testing,rework:testing,rework:implementing,blocked:testing\n' \
  > "$WORK/arch/reordered/plugin.conf"
archetype_validate reordered >/dev/null || fail "the reordered archetype fixture must satisfy the meta-contract"
assert_eq implementing "$(drive_dispatch_target reordered rework)" \
  "a rework dispatch still resolves to implementing with rework:testing listed FIRST — the reverify edge is never a dispatch target"
assert_eq implementing "$(drive_dispatch_target reordered pending)" "and the ordinary pending edge is unaffected"
assert_eq "" "$(drive_dispatch_target reordered blocked)" \
  "a status whose only active edge IS the reverify one yields no dispatch target at all — blocked is resolved by an operator verb, never by the driver"
assert_eq "" "$(drive_dispatch_target feature blocked)" "the same holds for the shipped feature archetype"
assert_eq testing "$(drive_dispatch_target feature merging)" \
  "and merging:testing — an ACTIVE source, orchid merge's own rebase reset — is untouched by that skip"

assert_eq implementer "$(drive_role_for_status implementing | cut -f1)" "implementing waits on the implementer role"
assert_eq reviewer "$(drive_role_for_status reviewing | cut -f1)" "reviewing waits on the reviewer role"
assert_eq "" "$(drive_role_for_status testing)" "testing launches nothing — orchid verify runs in the pass's own foreground"
assert_eq "" "$(drive_role_for_status arbitrating)" "arbitrating launches nothing — it is inline judgment"

# ===========================================================================
# A2 -- a report archetype, driven end to end. No worktree is built, no
# candidate is produced, `merging` is never reached, and the task finishes at
# `done` through the same judgment verb everything else uses.
# ===========================================================================
use_repo a2
printf 'role.reviewer=stubreview\n' > orchid.config
"$ORCHID_BIN" task create A1 "audit report" --archetype review >/dev/null
integ_head="$(git rev-parse orchid/integration)"

i=0
while [ "$i" -lt 30 ]; do
  run_drive
  [ "$(status_of A1)" = "done" ] && break
  [ "$DRIVE_RC" -eq 0 ] || break
  i=$((i + 1)); sleep 0.3
done
assert_eq "done" "$(status_of A1)" "a report archetype reaches done under the deterministic driver (rc=$DRIVE_RC, out: $DRIVE_OUT)"
assert_eq "" "$(field_of A1 worktree)" "an outcome=report task never gets a dispatch worktree"
assert_eq "$integ_head" "$(field_of A1 candidate_sha)" \
  "its candidate pins to the integration head so review envelopes still bind to something concrete"
[ ! -d "$WORK/a2-A1" ] || fail "no sibling worktree may be created for an outcome=report task"
assert_match "arbitrating -> done: arbitrate\(approve\)" "$(cat .orchid/journal.md)" \
  "the report archetype's approval was recorded through the judgment verb and landed in done, never merging"

# ===========================================================================
# A3 -- a CUSTOM archetype nobody wrote code for takes the same path. This is
# the INV-05/INV-14 claim made behavioural: the driver has no table of
# archetype names to consult.
# ===========================================================================
use_repo a3
printf 'role.reviewer=stubreview\n' > orchid.config
"$ORCHID_BIN" task create C1 "custom archetype" --archetype audit >/dev/null
run_drive
assert_eq reviewing "$(status_of C1)" "a custom archetype dispatches into the active status it declares"
assert_eq "" "$(field_of C1 worktree)" "the custom report archetype builds no worktree either"

i=0
while [ "$i" -lt 30 ]; do
  run_drive
  [ "$(status_of C1)" = "done" ] && break
  [ "$DRIVE_RC" -eq 0 ] || break
  i=$((i + 1)); sleep 0.3
done
assert_eq "done" "$(status_of C1)" "the custom archetype completes with no code that knows its name (rc=$DRIVE_RC, out: $DRIVE_OUT)"
