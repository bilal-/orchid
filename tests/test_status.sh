#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\n' > orchid.config
# init now refuses a dirty tree (Task 8 safety fix): commit the fixture's
# config before init, mirroring tests/test_init_doctor.sh.
git add -A && git commit -q -m "fixture: config"
"$ORCHID_BIN" init >/dev/null
# init leaves the operator back on the pre-init branch (cleanup restores
# $cur); the run state (.orchid/roadmap.md etc.) only lives on the
# integration branch it just committed to, so check that out before
# touching task/status state — mirrors the real operator workflow
# (docs/specs/operations.md: "Integration branch holds the product").
git checkout -q orchid/integration
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo
"$ORCHID_BIN" task create T002 dep
"$ORCHID_BIN" task set T002 depends_on T001
assert_match "run_status: planning" "$("$ORCHID_BIN" status)" "run status shown"
assert_match "T001	pending" "$("$ORCHID_BIN" status)" "task table"
assert_match "T002.*waiting-deps \(T001\)" "$("$ORCHID_BIN" status --explain)" "explain names predicate"
assert_match "T001.*ready-to-dispatch" "$("$ORCHID_BIN" status --explain)" "explain ready"

# status in an uninitialized repo (no .orchid/roadmap.md) must not leak awk's
# stderr and must print an explicit marker instead of a blank run_status.
scratch="$WORK/uninit"; mkdir -p "$scratch"
(cd "$scratch" && git init -q . && git commit -q --allow-empty -m root)
rc=0; out="$(ORCHID_REPO="$scratch" HOME="$HOME" "$ORCHID_BIN" status 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "status must exit 0 in an uninitialized repo"
assert_match "run_status: \(uninitialized\)" "$out" "status prints (uninitialized) marker"
echo "$out" | grep -qi "no such file\|awk:" && fail "status must not leak fm_get's stderr for a missing roadmap"

# v1-m3 Task 2: split-brain checkout (F7) -- .orchid/tasks/ exists (a task
# verb ran against this checkout) but roadmap.md does not (durable state
# lives only on the integration branch). status must WARN, and the warning
# must be the FIRST line, above run_status.
splitb="$WORK/splitbrain"; mkdir -p "$splitb/.orchid/tasks"
(cd "$splitb" && git init -q . && git commit -q --allow-empty -m root)
out_sb="$(ORCHID_REPO="$splitb" HOME="$HOME" "$ORCHID_BIN" status 2>&1)"
assert_eq "WARNING: split-brain checkout (.orchid state without roadmap.md — run from the integration branch)" \
  "$(echo "$out_sb" | head -n1)" "status warns about split-brain as the very first line"
assert_match "^run_status: \(uninitialized\)$" "$out_sb" "status still prints run_status after the split-brain warning"

# healthy fixture (the main $WORK repo on orchid/integration) is unaffected.
echo "$("$ORCHID_BIN" status)" | grep -q "split-brain" && fail "status must not warn split-brain on a healthy checkout"

# ===========================================================================
# v1-m4 Task 5: static status page (`orchid status --html`)
# ===========================================================================

# Regression pin: refactoring the task-row/explain-predicate logic into
# functions shared with the new --html path must not change one byte of the
# existing `status --explain` TEXT output (still on the $WORK fixture above:
# T001 pending/ready, T002 pending/waiting-deps, no engine events).
expected_explain="$(printf 'run_status: planning\n== tasks\nT001\tpending\tdemo\tready-to-dispatch\nT002\tpending\tdep\twaiting-deps (T001)\n== jobs\n== engines\n(no engine events yet)')"
actual_explain="$("$ORCHID_BIN" status --explain)"
assert_match '^unattended: denied' "$actual_explain" \
  "status --explain reports the unacknowledged headless gate"
actual_explain_without_trust="$(printf '%s\n' "$actual_explain" | grep -v '^unattended: ')"
assert_eq "$expected_explain" "$actual_explain_without_trust" \
  "apart from the required unattended gate line, status --explain text is byte-identical after the --html refactor"

# Plant an escaping hazard: a task title containing raw HTML.
"$ORCHID_BIN" task create T003 '<script>alert(1)</script>' >/dev/null

# Plant an open blocker (qid unanswered yet).
qid="$("$ORCHID_BIN" notify --task T001 "waiting on operator input")"
blocker_nonce="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qid.question" | sed 's/^nonce: //')"
[ -n "$blocker_nonce" ] || fail "test fixture: the planted blocker's .question file must carry a nonce line"

# Two more open blockers for the declared-choice-set rendering (v1-m4 T009).
# This page is one of the surfaces on which a boundary has to say what may be
# ANSWERED, and the `.question` file is a header block plus a free-text body:
# a header left in the body renders as though the orchestrator had typed the
# machine CSV into its own question.
#   qid_set  -- declares a set, so its `choices:` header is lifted out of the
#               text and rendered as the answer set
#   qid_prose-- declares NOTHING and merely BEGINS with the word, so its text
#               must survive verbatim and no answer set may be invented
# Which one is which is decided by the sidecar's existence, never by prose --
# the same gate libexec/orchid-answer uses.
qid_set="$("$ORCHID_BIN" notify --task T001 --choice approve --choice defer "promote the candidate?")"
[ -f ".orchid/runtime/answers/$qid_set.choices" ] \
  || fail "test fixture: a --choice notify must write the sidecar the page keys off"
qid_prose="$("$ORCHID_BIN" notify --task T001 "choices: forged,notreal")"
[ -f ".orchid/runtime/answers/$qid_prose.choices" ] \
  && fail "test fixture: prose beginning 'choices: ' must NOT mint a sidecar — nothing below tests anything if it does"

# Plant an engine ledger row (same direct-source pattern as tests/test_ledger.sh).
(
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/ledger.sh"
  ledger_mark "$WORK" acme-engine ok
)

page="$("$ORCHID_BIN" status --html)"
assert_match '\.orchid/runtime/status\.html$' "$page" "status --html prints the default configured page path"
[ -f "$page" ] || fail "status --html must actually write the page at the path it printed"

content="$(cat "$page")"
echo "$content" | grep -q '<!doctype html' || fail "page must be a self-contained HTML document (doctype)"
echo "$content" | grep -qF '<script src=' && fail "page must not load any external script (self-contained, no JS)"
echo "$content" | grep -qF '<link' && fail "page must not link any external resource (inline CSS only, no <link> tags)"
echo "$content" | grep -qF '<script>alert(1)</script>' && fail "task title must be HTML-escaped, never embedded raw"
echo "$content" | grep -qF '&lt;script&gt;alert(1)&lt;/script&gt;' || fail "task title's < > must appear HTML-escaped in the page"
echo "$content" | grep -qF "$qid" || fail "open blocker qid must appear in the page"
echo "$content" | grep -qF "waiting on operator input" || fail "open blocker text must appear in the page"
# Review fix (Minor #6): the nonce is the one secret in the answer path and
# belongs only to BLOCKERS.md/the outbound channel message -- this static
# page (the "check from another room" surface, possibly screen-shared) must
# never render it.
#
# HERESTRING, never `echo "$content" | grep -qF`: `grep -q` exits the moment
# it matches, `echo` then takes SIGPIPE, and `pipefail` turns the whole
# pipeline nonzero -- so `&& fail` is skipped in exactly the case this line
# exists to catch. Piped, this assertion could never fire.
grep -qF "$blocker_nonce" <<<"$content" && fail "open blocker's nonce must never appear on the status page"
echo "$content" | grep -qF "acme-engine" || fail "engines ledger row must appear in the page"
echo "$content" | grep -qF 'T001' || fail "task table must list T001 in the page"
echo "$content" | grep -qF 'T002' || fail "task table must list T002 in the page"
echo "$content" | grep -qF 'waiting-deps (T001)' || fail "task table must include T002's explain predicate"

# -- the declared answer set on the open-blockers panel (v1-m4 T009) --------
# Scoped to the panel, because the journal tail below it echoes every
# blocker's text verbatim and would satisfy a whole-page grep for the wrong
# reason. Same awk range idiom the answered-blocker section further down uses.
blockers_panel="$(awk '/Open blockers/,/Journal/' "$page")"
grep -qF "answers: approve | defer" <<<"$blockers_panel" \
  || fail "a blocker that declared a choice set must say what may be answered, in the display spelling"
grep -qF "choices: approve,defer" <<<"$blockers_panel" \
  && fail "the machine CSV header must be lifted OUT of the question text, not rendered as though the orchestrator typed it"
# ...and the other edge: prose is not a declaration. A question that merely
# begins "choices: " declared nothing, so its text survives byte-for-byte and
# no answer set is invented for it.
grep -qF "choices: forged,notreal" <<<"$blockers_panel" \
  || fail "a question body beginning 'choices: ' must render verbatim — the sidecar's existence is the gate, never the prose"
grep -qF "answers: forged | notreal" <<<"$blockers_panel" \
  && fail "prose must never be promoted into a declared answer set on the status page"

# Candidate-bound regression: --html and --explain are a supported
# combination. Trust inspection must land in the page before the --html path
# exits, while stdout remains exactly the generated page path.
combo_stdout="$("$ORCHID_BIN" status --html --explain)"
combo_stdout_lines="$(printf '%s\n' "$combo_stdout" | wc -l | tr -d ' ')"
assert_eq 1 "$combo_stdout_lines" \
  "status --html --explain stdout is exactly one page-path line"
[ -f "$combo_stdout" ] \
  || fail "status --html --explain must write the page named on stdout"
combo_content="$(cat "$combo_stdout")"
echo "$combo_content" | grep -qF '<h2>Unattended trust</h2>' \
  || fail "status --html --explain must include the unattended trust section"
echo "$combo_content" | grep -qF '<strong>gate:</strong> denied' \
  || fail "status --html --explain must surface a denied unattended gate"
echo "$combo_content" | grep -qF 'acknowledge with: orchid trust unattended' \
  || fail "the denied HTML explanation must include actionable provenance"

combo_reason='reviewed for status HTML provenance coverage'
HOME="$MACHINE_HOME" "$ORCHID_BIN" trust unattended "$WORK" \
  --reason "$combo_reason" >/dev/null
trusted_combo_stdout="$(HOME="$MACHINE_HOME" "$ORCHID_BIN" status --html --explain)"
trusted_combo_lines="$(printf '%s\n' "$trusted_combo_stdout" | wc -l | tr -d ' ')"
assert_eq 1 "$trusted_combo_lines" \
  "trusted status --html --explain stdout remains exactly one page-path line"
trusted_combo_content="$(cat "$trusted_combo_stdout")"
echo "$trusted_combo_content" | grep -qF '<strong>gate:</strong> allowed' \
  || fail "status --html --explain must surface an allowed unattended gate"
echo "$trusted_combo_content" | grep -qF "$combo_reason" \
  || fail "status --html --explain must surface operator-authored provenance"
echo "$trusted_combo_content" | grep -qF 'acknowledged at' \
  || fail "status --html --explain must surface the acknowledgement timestamp"
HOME="$MACHINE_HOME" "$ORCHID_BIN" trust revoke "$WORK" >/dev/null

# Atomic write: no leftover tmp artifact beside the page (atomic_write's
# own mktemp+mv idiom -- confirms the --html path actually used it).
list_dir_entries "$(dirname "$page")" | grep -q '\.tmp\.' \
  && fail "status --html must not leave a stray atomic-write tmp file behind"

# Answering a blocker must drop it from the "open blockers" section on the
# NEXT --html regeneration (it still legitimately appears elsewhere, e.g.
# the journal's blocker_resolved entry -- only the open-blockers listing
# itself is asserted here).
"$ORCHID_BIN" answer "$qid" ack >/dev/null
# The two choice-set blockers planted above are open too, and "no open
# blockers" below means ALL of them: leaving either behind would make that
# assertion fail for a reason that has nothing to do with what it tests.
# `defer` for the one that declared a set, because `orchid answer` refuses
# anything outside it; free text for the one that declared none.
"$ORCHID_BIN" answer "$qid_set" defer >/dev/null
"$ORCHID_BIN" answer "$qid_prose" "prose is still a legitimate answer" >/dev/null
page2="$("$ORCHID_BIN" status --html)"
blockers_section="$(awk '/Open blockers/,/Journal/' "$page2")"
echo "$blockers_section" | grep -qF "$qid" && fail "an ANSWERED blocker must no longer be listed in Open blockers"
echo "$blockers_section" | grep -qi 'no open blockers' || fail "Open blockers must say so once the only blocker is answered"

# Last-10 journal entries: the just-added blocker/blocker_resolved entries
# must be in the page's journal section.
journal_section="$(awk '/Journal \(last 10\)/,0' "$page2")"
echo "$journal_section" | grep -qF "$qid" || fail "journal tail must include the recent blocker entry"
echo "$journal_section" | grep -qF 'blocker_resolved' || fail "journal tail must include the recent blocker_resolved entry"

# status_page is config-able: point it at a custom relative path (resolved
# under .orchid/, same as every other runtime/ path) and confirm the page
# lands there instead of the default.
printf 'status_page=runtime/custom-status.html\n' >> orchid.config
custom_page="$("$ORCHID_BIN" status --html)"
assert_match 'runtime/custom-status\.html$' "$custom_page" "status_page config controls where the page is written"
[ -f "$custom_page" ] || fail "custom status_page path must actually be written"
[ -f "$WORK/.orchid/runtime/custom-status.html" ] || fail "custom status_page resolves relative to .orchid/, not repo root"

# Review fix: split-brain/stale-checkout warnings must land on STDERR only,
# in EVERY mode -- they were breaking `--html`'s "stdout is exactly the path
# it wrote" contract exactly on a broken checkout, the state where having
# the right page path matters most. Reuse the $splitb fixture from above.
html_stderr_file="$WORK/html-stderr.txt"
html_stdout="$(ORCHID_REPO="$splitb" HOME="$HOME" "$ORCHID_BIN" status --html 2>"$html_stderr_file")"
html_stderr="$(cat "$html_stderr_file")"
html_stdout_lines="$(printf '%s\n' "$html_stdout" | wc -l | tr -d ' ')"
assert_eq 1 "$html_stdout_lines" \
  "status --html stdout is EXACTLY one line (the path), even on a split-brain checkout"
echo "$html_stdout" | grep -qF '.orchid/runtime/status.html' \
  || fail "status --html stdout must be the page path on a split-brain checkout too"
[ -f "$html_stdout" ] || fail "the path --html printed on stdout must be a real file even on a split-brain checkout"
assert_match "WARNING: split-brain checkout" "$html_stderr" \
  "the split-brain warning lands on stderr (not stdout) in --html mode"

# ===========================================================================
# T035: the process table under `status --jobs`, and the liveness warnings
# that need no flag at all.
#
# What this section could show while two jobs existed for one task was a task
# id and a state word. Worse, in the incident that sharpened the requirement
# (dogfood F36) `orchid status` showed a run in planning with no hint that its
# only in-flight job had died twelve and a half hours earlier -- so the warning
# below is deliberately not behind a flag.
# ===========================================================================
mkdir -p "$WORK/.orchid/runtime/jobs" "$WORK/.orchid/runtime/logs"
( exit 0 ) & st_dead_pid=$!
wait "$st_dead_pid" 2>/dev/null || true
echo stale-log > "$WORK/.orchid/runtime/logs/j-st-dead.log"
touch -t 202001010000 "$WORK/.orchid/runtime/logs/j-st-dead.log"
jq -n --argjson pid "$st_dead_pid" --argjson st "$(( $(date +%s) - 45000 ))" \
  --arg log "$WORK/.orchid/runtime/logs/j-st-dead.log" \
  '{job_id:"j-e1-T001-a1-9999ffff", task:"T001", attempt:1, role:"reviewer", operation:"review",
    engine:"acme-engine", pid:$pid, pgid:0, started_at:$st, log:$log, output:"/dev/null",
    base_sha:"", candidate_sha:"", launched_by:"pump"}' \
  > "$WORK/.orchid/runtime/jobs/j-st-dead.json"

# Plain status: stdout unchanged. `jobs check` is the surface THE TICK is
# specified against and it kills what it calls stalled -- swapping its
# vocabulary out from under every existing reader is not what an operator
# asking for a nicer table wanted.
st_plain="$("$ORCHID_BIN" status 2>/dev/null)"
assert_match "^== jobs$" "$st_plain" "plain status keeps its jobs section"
assert_match "^T001[[:space:]]dead$" "$st_plain" \
  "plain status still prints jobs check's machine-facing task/state pairs"
grep -q "j-e1-T001-a1-9999ffff" <<< "$st_plain" \
  && fail "the table is what --jobs asks for; plain status's stdout is unchanged"

# The warning, however, is behind no flag at all: the F36 operator was reading
# exactly this command.
st_plain_err="$("$ORCHID_BIN" status 2>&1 >/dev/null)"
assert_match "WARNING: job j-e1-T001-a1-9999ffff .* is dead and left no envelope" "$st_plain_err" \
  "status warns about a job whose pid is gone and whose envelope never landed, with no flag asked for"
assert_match "last wrote [0-9]+d[0-9]+h ago" "$st_plain_err" \
  "and says how long ago it last wrote — the timestamp both the operator and an assistant read past"

# --jobs: the same table `orchid jobs ls` renders, in place of the pairs.
st_jobs="$("$ORCHID_BIN" status --jobs 2>/dev/null)"
assert_match "^JOB[[:space:]]+TASK[[:space:]]+ROLE[[:space:]]+OP[[:space:]]+ATT[[:space:]]+ENGINE[[:space:]]+PID[[:space:]]+STATE[[:space:]]+AGE[[:space:]]+ELAPSED[[:space:]]+BUDGET[[:space:]]+LAUNCHER[[:space:]]+LOG$" \
  "$st_jobs" "status --jobs renders the process table"
assert_match "j-e1-T001-a1-9999ffff[[:space:]]+T001[[:space:]]+reviewer[[:space:]]+review[[:space:]]+1[[:space:]]+acme-engine[[:space:]]+${st_dead_pid}[[:space:]]+dead[[:space:]]" \
  "$st_jobs" "one row per outstanding job: which job, whose work, which engine, which pid, and its computed state"
grep -Eq "^T001[[:space:]]dead$" <<< "$st_jobs" \
  && fail "--jobs replaces the bare task/state pair rather than printing both"

# --explain, --html and --jobs stay independent flags.
st_both="$("$ORCHID_BIN" status --explain --jobs 2>/dev/null)"
assert_match "ready-to-dispatch" "$st_both" "status --explain --jobs keeps the explain predicates"
assert_match "j-e1-T001-a1-9999ffff" "$st_both" "and adds the process table"

# The static page -- the surface an operator checks from another room, which
# is the room the F36 operator was checking from -- carries the same rows,
# read back through the same producer.
st_page="$("$ORCHID_BIN" status --html 2>/dev/null)"
st_page_content="$(cat "$st_page")"
# Herestrings, not `echo "$page" | grep -q`: this file runs under `set -o
# pipefail` and `grep -q` exits at its FIRST match, SIGPIPEing the upstream
# `echo` mid-write. pipefail promotes that 141 to the pipeline's status, so
# `|| fail` fires for a pattern grep DID find. A whole status page is easily
# long enough for echo to still be writing, and `<h2>Jobs</h2>` matches
# roughly halfway down it -- exactly the size-dependent coin flip helpers.sh
# documents at assert_match.
grep -qF '<h2>Jobs</h2>' <<< "$st_page_content" || fail "the status page must have a Jobs section"
grep -qF 'j-e1-T001-a1-9999ffff' <<< "$st_page_content" || fail "the outstanding job must appear on the page"
grep -qF '>dead<' <<< "$st_page_content" \
  || fail "the page must render the COMPUTED state, not the pid the manifest still records"

rm -f "$WORK/.orchid/runtime/jobs/j-st-dead.json"
st_empty="$("$ORCHID_BIN" status --jobs 2>/dev/null)"
assert_match "\(no outstanding jobs\)" "$st_empty" \
  "with nothing outstanding the section says so, rather than printing a bare header"
st_empty_err="$("$ORCHID_BIN" status 2>&1 >/dev/null)"
grep -q "WARNING: job " <<< "$st_empty_err" \
  && fail "and warns about nothing — a warning that fires on a healthy run is one an operator learns to ignore"

# --- PROTOCOL.md lint: THE TICK step 5 must regenerate the page ------------
grep -q 'orchid status --html' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md's THE TICK step 5 must mention 'orchid status --html'"
grep -q 'status_page' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md must document the status_page config key"
grep -qi 'best-effort' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md must describe the status page regeneration as best-effort"

# ===========================================================================
# T024 (dogfood F26): a task parked at `testing` on an unacknowledged
# operator prerequisite is NOT awaiting a verify. The driver refuses to start
# one and will keep refusing until a human acts, so reporting "awaiting-
# verify" sends the operator looking for a running suite that does not
# exist -- at the one moment they are themselves the thing being waited on.
# ===========================================================================
"$ORCHID_BIN" task create T004 "authors a migration it is not allowed to apply" >/dev/null
prq_sha="$(git rev-parse HEAD)"
"$ORCHID_BIN" task set T004 base_sha "$prq_sha"
"$ORCHID_BIN" task set T004 candidate_sha "$prq_sha"
"$ORCHID_BIN" task advance T004 implementing >/dev/null
"$ORCHID_BIN" task advance T004 testing >/dev/null
assert_match "T004.*awaiting-verify" "$("$ORCHID_BIN" status --explain)" \
  "a testing task that declares no prerequisite reports awaiting-verify, exactly as before"

"$ORCHID_BIN" task set T004 operator_prerequisite "apply db/migrate/0007_isolation.sql to the test database"
assert_match "T004.*awaiting-operator-prerequisite \(orchid task prereq-ack T004\)" \
  "$("$ORCHID_BIN" status --explain)" \
  "declared and unacknowledged, the row names the human as the thing being waited on -- and the verb that settles it"

"$ORCHID_BIN" task prereq-ack T004 --reason "applied 0007 by hand" >/dev/null
assert_match "T004.*awaiting-verify" "$("$ORCHID_BIN" status --explain)" \
  "and acknowledging it hands the task straight back to the ordinary verify wait"

# ...until the candidate moves out from under the acknowledgement. This is the
# frontmatter merge's rebase-reset writes (new candidate_sha, back to
# `testing`, through none of the verbs that clear the ack), and the row must
# park on the operator again rather than report a verify wait nothing will
# start.
"$ORCHID_BIN" task set T004 candidate_sha cafecafecafecafecafecafecafecafecafecafe
assert_match "T004.*awaiting-operator-prerequisite \(orchid task prereq-ack T004\)" \
  "$("$ORCHID_BIN" status --explain)" \
  "an acknowledgement for a superseded candidate leaves the human as the thing being waited on"

# -- and the same at `merging` ----------------------------------------------
# `orchid merge` re-runs the same suite against the same store and refuses on
# the same predicate, so a task parked HERE on an unacknowledged prerequisite
# is no more awaiting a merge than the one above was awaiting a verify -- the
# verb will keep refusing until a human acts. Reported symmetrically, or the
# row sends an operator looking for a merge that will never start.
#
# `status` is a report, not a gate, so it does not (and need not) distinguish
# the one case this overstates: on a STALE base, merge rebase-resets to
# `testing` before it ever reaches the gate. The driver's own boundary, raised
# only when merge actually refused, is the authoritative signal.
# No verb takes `testing` -> `merging`, so the frontmatter is moved directly
# (same direct-source pattern as the ledger row above; fm_set needs
# common.sh's atomic_write).
(
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/lib/frontmatter.sh"
  fm_set "$WORK/.orchid/tasks/T004.md" status merging
)
assert_match "T004.*awaiting-operator-prerequisite \(orchid task prereq-ack T004\)" \
  "$("$ORCHID_BIN" status --explain)" \
  "a merging task blocked on the prerequisite names the human, not the merge"

"$ORCHID_BIN" task prereq-ack T004 --reason "applied 0007 for the candidate now in hand" >/dev/null
assert_match "T004.*awaiting-merge" "$("$ORCHID_BIN" status --explain)" \
  "and acknowledging it hands the task back to the ordinary merge wait"
