#!/usr/bin/env bash
# v1-m4 Task 4: pump service packaging. `orchid service install/uninstall/
# status` schedules the ALREADY one-shot, lease-gated pump (runners/orchid-
# pump, v1-m2 Task 8) via the host's own scheduler -- a launchd agent on
# macOS, a marker-guarded crontab line everywhere else -- so a run proceeds
# semi-attended without a hand-run nohup loop. Every subverb accepts
# --dry-run; this suite runs EXCLUSIVELY under --dry-run (never invokes a
# real launchctl/crontab) -- see individual sections for what --dry-run
# does and does not skip (file rendering + placement is real; only the
# scheduler mutation/query itself is printed instead of run).
source "$(dirname "$0")/helpers.sh"
SERVICE="$REPO_ROOT/runners/orchid-service"
PUMP="$REPO_ROOT/runners/orchid-pump"

cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"; mkdir -p "$HOME"
export ORCHID_ROOT="$REPO_ROOT"

trust_repo() {
  HOME="$HOME" "$ORCHID_BIN" trust unattended "$1" --reason "service test fixture" >/dev/null \
    || fail "service fixture acknowledgement failed for $1"
}

# UNINSTALL, FOR REAL -- everything except the one system call.
#
# `--dry-run` removes nothing (T036): a preview that deleted the plist and the
# binding record while only PRINTING `launchctl unload` would leave a loaded
# agent that nothing names and nothing can unload by path, which is the exact
# leftover this verb exists to prevent. So --dry-run can no longer be the way
# this suite reaches the uninstalled state -- and a genuinely unstubbed
# uninstall is not available to it either: on darwin it would talk to the
# host's own launchd, and on linux it would rewrite the operator's REAL
# crontab, which no test may ever do.
#
# ORCHID_SERVICE_DEBUG_SCHEDULER_LOG is the service runner's test-only seam for
# exactly this: the launchctl/crontab call is appended to a file instead of
# run, and every removal, record, refusal and message around it is the real
# one. Truncated per call, so a caller asserting on it sees only its own
# command. Kept outside every fixture repo, since sections below assert on
# those trees' exact contents.
SCHED_LOG="$HOME/scheduler-calls.txt"
svc_uninstall_real() {
  : > "$SCHED_LOG"
  ORCHID_SERVICE_DEBUG_SCHEDULER_LOG="$SCHED_LOG" "$SERVICE" uninstall "$@"
}

# INSTALL, FOR REAL -- everything except the one system call, through the same
# seam. Nearly every section installs with `--dry-run`, which is enough for them:
# the plist, the cron record and both binding halves are placed for real either
# way, and only the launchctl/crontab call is printed. K15 is the one section
# that cannot use it, because the fact it turns on is exactly the one --dry-run
# does not establish -- whether a schedule was actually replaced -- and a preview
# that destroyed the evidence of the schedule it left running would be the
# uninstall-under---dry-run hazard wearing install's clothes.
svc_install_real() {
  : > "$SCHED_LOG"
  ORCHID_SERVICE_DEBUG_SCHEDULER_LOG="$SCHED_LOG" "$SERVICE" install "$@"
}

# The same real uninstall, with the stubbed scheduler call MADE TO FAIL.
# A stub that can only succeed cannot reach the arm that matters most -- what
# uninstall does when `launchctl unload` returns nonzero -- and that arm is the
# one deciding whether the plist and the binding record survive. $1 is an ERE
# matched against the quoted command line, so a caller can fail the unload
# alone (launchd still holds the job) or the unload and the `list` together.
#
# $2/$3 are the exit STATUS and the stderr text a matching call produces, and
# they are the whole of K11: for `launchctl list`, "nonzero" is two different
# facts. Exit 113 (or launchd's own "Could not find service" sentence) is
# launchd ANSWERING that it holds no such job; every other nonzero is a query
# that never got an answer -- launchctl missing, denied, unable to reach
# launchd. Read alike, the second silently clears the binding record of an agent
# that is still firing. So the two wrappers below name which one they are
# staging, and no caller passes a bare "it failed" for a `list` again.
#
# Pointed at a SUBVERB, because `teardown` (K12) is the same removal path with
# `git worktree remove` as its success branch -- every refusal staged here has
# to be stageable against both doors, or the suite could prove uninstall
# refuses while teardown walked past the identical failure.
svc_stub_subverb() {
  local sub="$1" fail_re="$2" fail_rc="$3" fail_err="$4"; shift 4
  : > "$SCHED_LOG"
  ORCHID_SERVICE_DEBUG_SCHEDULER_LOG="$SCHED_LOG" \
  ORCHID_SERVICE_DEBUG_SCHEDULER_FAIL="$fail_re" \
  ORCHID_SERVICE_DEBUG_SCHEDULER_FAIL_RC="$fail_rc" \
  ORCHID_SERVICE_DEBUG_SCHEDULER_FAIL_ERR="$fail_err" \
  "$SERVICE" "$sub" "$@"
}
svc_uninstall_stub() {
  local fail_re="$1" fail_rc="$2" fail_err="$3"; shift 3
  svc_stub_subverb uninstall "$fail_re" "$fail_rc" "$fail_err" "$@"
}

# A matching call fails the way a MALFUNCTION does: an ordinary nonzero and a
# message that answers nothing. Right for an unload, whose failure is only ever
# a malfunction (K7's red arm); for a `list` this is the indeterminate case, and
# uninstall must refuse on it exactly as it refuses on a loaded job.
svc_uninstall_failing() {
  local fail_re="$1"; shift
  svc_uninstall_stub "$fail_re" 1 'Operation not permitted' "$@"
}

# A matching call fails the way launchd ANSWERS "I hold no such job": exit 113,
# which launchctl reports as `Could not find service`. This is the only way to
# stage a never-loaded label, which is what K6, K7's and K8's green arms are
# about; leaving `list` to succeed stages a job launchd still holds, the half
# both refusals turn on. Deliberately says nothing on stderr, so these arms
# prove the STATUS rule on its own (K11 proves the sentence rule separately).
svc_uninstall_notfound() {
  local fail_re="$1"; shift
  svc_uninstall_stub "$fail_re" 113 '' "$@"
}

# $WORK (from mktemp -d) commonly has a symlinked component on macOS
# (/var/folders/... -> /private/var/folders/...) -- the service always
# hashes/bakes in the CANONICAL, physically-resolved repo path (the brief's
# own wording for the label), so every assertion against path TEXT actually
# baked into a rendered artifact compares against $repo_canon, never the
# raw $WORK string. Plain file-existence checks against "$WORK/..." remain
# fine as-is -- the OS resolves the symlink either way when opening a path.
repo_canon="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root"; exit 1; }

# The same rule applies to the CHECKOUT under test: helpers.sh must hand this
# suite a physically-resolved REPO_ROOT, or the assertions below that compare
# against a path the service baked in (ProgramArguments) fail on exactly the
# symlinked checkouts -- a /var/folders merge-validation worktree -- that a
# non-symlinked developer checkout never reproduces.
assert_eq "$(cd "$REPO_ROOT" && pwd -P)" "$REPO_ROOT" "REPO_ROOT must be physically canonical"

label_re='com\.orchid\.pump\.[0-9a-f]{12}'

# ===========================================================================
# A -- install refuses an uninitialized repo (no .orchid/ at all).
# ===========================================================================
out="$("$SERVICE" install --repo "$WORK" --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "install must refuse an uninitialized repo (no .orchid/)"
assert_match 'uninitialized|no \.orchid' "$out" "install names the uninitialized-repo refusal plainly"
[ -d "$HOME/Library/LaunchAgents" ] && fail "a refused install must not render/place anything"

mkdir -p .orchid/tasks

# An initialized repo is still denied until acknowledged. Dry-run is gated
# too because it places real scheduler artifacts.
rc=0
out="$("$SERVICE" install --repo "$WORK" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "install must refuse an initialized but unacknowledged repo"
assert_match 'service installation refused: unattended trust is denied' "$out" \
  "service refusal names the unattended trust gate"
[ ! -d "$HOME/Library/LaunchAgents" ] \
  || fail "trust-refused install must not place a launchd artifact"
[ ! -d "$WORK/.orchid/runtime" ] \
  || fail "trust-refused install must not create runtime state"

trust_repo "$WORK"

# ===========================================================================
# B -- macOS (default host branch, no ORCHID_SERVICE_OS override): install
# renders the launchd plist template with the correct label, ORCHID_REPO,
# TMPDIR (the repo's PARENT dir -- the live-run TMPDIR incident), interval,
# a scheduler-safe output sink, then PRINTS (never runs) the launchctl load
# command. The pump itself starts repo-local logging only after trust succeeds.
# ===========================================================================
parent="$(cd "$WORK/.." && pwd -P)"
out="$("$SERVICE" install --repo "$WORK" --interval-s 300 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "darwin install --dry-run exits 0"
assert_match "$label_re" "$out" "install prints a com.orchid.pump.<12-hex> label"
label="$(echo "$out" | grep -oE "$label_re" | head -n1)"
plist="$HOME/Library/LaunchAgents/$label.plist"
[ -f "$plist" ] || fail "install --dry-run must still render + place the plist file for real"
grep -qF "<string>$label</string>" "$plist" || fail "plist Label does not match the printed label"
grep -qF "<string>$repo_canon</string>" "$plist" || fail "plist ORCHID_REPO does not match --repo (canonical)"
grep -qF "<string>$parent</string>" "$plist" || fail "plist TMPDIR is not the repo's parent directory"
grep -qF "<integer>300</integer>" "$plist" || fail "plist StartInterval does not match --interval-s 300"
grep -qF "<string>$REPO_ROOT/runners/orchid-pump</string>" "$plist" || fail "plist ProgramArguments does not point at runners/orchid-pump"
grep -qF -- "<string>--service-log</string>" "$plist" || fail "plist does not ask the trusted pump to begin service logging"
assert_eq 2 "$(grep -cF '<string>/dev/null</string>' "$plist")" \
  "plist sends both scheduler-owned output streams to /dev/null"
grep -qF 'pump.log' "$plist" \
  && fail "launchd must never open the target-controlled pump.log path before the pump trust gate"
assert_match 'DRY-RUN:.*launchctl load' "$out" "install --dry-run prints the launchctl load command"

# IMPORTANT fix (final review #1): a launchd agent gets only launchd's own
# bare PATH -- the installing user's OWN $PATH (this test process's own, the
# same one the script itself ran under) must be baked into the plist's
# EnvironmentVariables, so `jq`/engine CLIs are findable by a scheduled pump.
grep -qF "<key>PATH</key>" "$plist" || fail "plist must declare a PATH key in EnvironmentVariables"
grep -qF "<string>$PATH</string>" "$plist" || fail "plist PATH does not carry the installing user's \$PATH"

# A real `launchctl` invocation must never happen: the fixture HOME has no
# real launchd session behind it, so if the script ever ran it for real
# instead of printing it, the command would either hang or error loudly
# rather than exit 0 above -- exit 0 plus the printed command is the proof.

# ===========================================================================
# B2 -- CRITICAL fix (task review): a repo path containing XML metacharacters
# (& < >) used to render NON-well-formed XML (sed-escaping the path for the
# substitution mechanism is not the same thing as escaping it for the
# target FORMAT) -- launchctl would refuse to load it while this script
# still reported success. A repo path containing all three now renders a
# plist a real XML parser (python3's xml.dom.minidom -- the same
# well-formedness bar launchd's own plist parser enforces) accepts, and
# whose parsed (i.e. entity-DECODED) ORCHID_REPO string round-trips back to
# the exact original path.
# ===========================================================================
if command -v python3 >/dev/null 2>&1; then
  WORKX="$(mktemp -d)/repo & <weird> path"
  mkdir -p "$WORKX"
  ( cd "$WORKX" && git init -q . && git commit -q --allow-empty -m root && mkdir -p .orchid/tasks )
  WORKX_canon="$(cd "$WORKX" && pwd -P)"
  trust_repo "$WORKX"

  outx="$("$SERVICE" install --repo "$WORKX" --dry-run 2>&1)"; rcx=$?
  assert_eq 0 "$rcx" "install --dry-run exits 0 even when --repo contains & < >"
  labelx="$(echo "$outx" | grep -oE "$label_re" | head -n1)"
  plistx="$HOME/Library/LaunchAgents/$labelx.plist"
  [ -f "$plistx" ] || fail "install must still render/place a plist for a repo path containing XML metacharacters"

  xml_check="$(python3 - "$plistx" "$WORKX_canon" <<'PYEOF'
import sys, xml.dom.minidom as m
plist_path, expected_repo = sys.argv[1], sys.argv[2]
try:
    d = m.parse(plist_path)
except Exception as e:
    print("PARSE-FAIL: %s" % e)
    sys.exit(0)
strings = [s.firstChild.data for s in d.getElementsByTagName("string") if s.firstChild]
if expected_repo in strings:
    print("OK")
else:
    print("REPO-STRING-NOT-FOUND: %r not in %r" % (expected_repo, strings))
PYEOF
)"
  assert_eq OK "$xml_check" "plist with a repo path containing & < > is well-formed XML and round-trips the exact repo path"
  grep -qF "$WORKX_canon" "$plistx" && fail "the RAW (unescaped) repo path must never appear literally in the rendered plist -- only the entity-escaped form should"
  grep -qF '&amp;' "$plistx" || fail "plist must contain the XML-entity-escaped ampersand (&amp;) for the repo path's literal &"
  grep -qF '&lt;' "$plistx" || fail "plist must contain the XML-entity-escaped less-than (&lt;) for the repo path's literal <"
  grep -qF '&gt;' "$plistx" || fail "plist must contain the XML-entity-escaped greater-than (&gt;) for the repo path's literal >"

  rm -f "$plistx"
  rm -rf "$(dirname "$WORKX")"
else
  echo "  SKIP: python3 not found -- skipping the XML well-formedness regression check (B2)"
fi

# ===========================================================================
# C -- default pump_interval_s (240) is used when --interval-s is omitted.
# ===========================================================================
rm -rf "$HOME/Library/LaunchAgents"
out2="$("$SERVICE" install --repo "$WORK" --dry-run 2>&1)"
label2="$(echo "$out2" | grep -oE "$label_re" | head -n1)"
assert_eq "$label" "$label2" "the label is stable across re-installs of the same repo (hash of the canonical path)"
plist2="$HOME/Library/LaunchAgents/$label2.plist"
grep -qF "<integer>240</integer>" "$plist2" || fail "install without --interval-s must use the pump_interval_s default (240)"

# A custom pump_interval_s in orchid.config (no --interval-s flag) is honored.
printf 'pump_interval_s=90\n' > orchid.config
out3="$("$SERVICE" install --repo "$WORK" --dry-run 2>&1)"
plist3="$HOME/Library/LaunchAgents/$(echo "$out3" | grep -oE "$label_re" | head -n1).plist"
grep -qF "<integer>90</integer>" "$plist3" || fail "install must read pump_interval_s from orchid.config when --interval-s is not given"
rm -f orchid.config

# ===========================================================================
# D -- status (macOS): parses the installed plist for label/interval, never
# calls real launchctl under --dry-run, and always tails runtime/pump.log.
# ===========================================================================
mkdir -p .orchid/runtime
printf 'pump: run complete\npump: run complete\n' > .orchid/runtime/pump.log
HOME="$HOME" "$ORCHID_BIN" trust revoke "$WORK" >/dev/null \
  || fail "service fixture revocation must succeed"
out="$("$SERVICE" status --repo "$WORK" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "status always exits 0"
assert_match "$label_re" "$out" "status names the label"
assert_match 'installed: *yes' "$out" "status reports installed: yes after install"
assert_match 'interval_s: *90' "$out" "status reports the interval actually baked into the installed plist (90, from the config-driven install above)"
assert_match 'DRY-RUN:.*launchctl list' "$out" "status --dry-run prints (never runs) the launchctl list query"
assert_match 'pump: run complete' "$out" "status tails runtime/pump.log"

# ===========================================================================
# E -- uninstall removes exactly the plist file this install created, and
# prints (never runs) the launchctl unload command.
#
# E1 comes first because it is the arm an operator reaches by accident. A
# --dry-run uninstall PRINTS `launchctl unload` instead of running it, so the
# agent is still loaded when it returns -- and the two things it used to delete
# anyway were the plist (the path a real unload needs) and the binding record
# (the only thing on this machine naming that schedule at all). A preview that
# performed those removals manufactured the invisible leftover the whole
# teardown mechanism exists to prevent, in the one mode an operator runs
# expecting no consequences. It now removes nothing and says what it would.
# ===========================================================================
bind_before="$WORK/.orchid/runtime/service.json"
[ -f "$bind_before" ] || fail "fixture: the installs above must have recorded a binding for \$WORK"
out="$("$SERVICE" uninstall --repo "$WORK" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "uninstall --dry-run exits 0 when something is installed"
assert_match 'DRY-RUN:.*launchctl unload' "$out" "uninstall --dry-run prints the launchctl unload command"
assert_match 'would remove' "$out" "and names what a real run would remove"
# The paths are compared literally, never as patterns: a scratch path carries
# `.` and can carry other ERE metacharacters.
case "$out" in
  *"$plist3"*) ;;
  *) fail "the --dry-run preview must name the exact plist a real uninstall would remove" ;;
esac
assert_match 'would clear: +the service binding' "$out" "and names the binding record it would clear"
assert_match 'nothing was removed' "$out" "and says plainly that it did neither"
[ -f "$plist3" ] \
  || fail "uninstall --dry-run must NOT remove the plist: launchctl unload was only printed, so the agent is still loaded and this file is the only path anything can unload it by"
[ -f "$bind_before" ] \
  || fail "uninstall --dry-run must NOT clear the binding record: it is the only thing naming a schedule this run deliberately left running"
red_case "a --dry-run uninstall leaves the schedule it did not unload nameable"

# GREEN: the same verb without --dry-run really does remove both, and really
# does run the unload it only printed above. The system call is stubbed to a
# file (see svc_uninstall_real) -- everything else here is the real path.
out="$(svc_uninstall_real --repo "$WORK" 2>&1)"; rc=$?
assert_eq 0 "$rc" "uninstall exits 0 when something was installed"
assert_match 'launchctl unload' "$(cat "$SCHED_LOG")" \
  "the real uninstall runs the unload that --dry-run only printed"
[ -f "$plist3" ] && fail "uninstall must remove the plist file it created"
[ -f "$bind_before" ] && fail "uninstall must clear the binding record it wrote"
remaining="$(find "$HOME/Library/LaunchAgents" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 0 "$remaining" "uninstall removes exactly the one plist file (no collateral removal)"
green_case "a real uninstall removes the plist and the binding it printed under --dry-run"

# ===========================================================================
# F -- uninstall refuses cleanly when nothing is installed (idempotent: no
# stack trace, no attempt to touch launchctl at all).
# ===========================================================================
out="$("$SERVICE" uninstall --repo "$WORK" --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "uninstall must refuse when nothing is installed for this repo"
assert_match 'no service installed|not installed' "$out" "uninstall names the nothing-installed refusal plainly"
grep -q 'DRY-RUN' <<<"$out" && fail "a refused uninstall must never print a launchctl command -- there is nothing to reverse"

# ===========================================================================
# G -- status on a never-installed repo degrades gracefully (installed: no,
# still exits 0, still tails whatever pump.log already exists).
# ===========================================================================
out="$("$SERVICE" status --repo "$WORK" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "status exits 0 even when nothing is installed"
assert_match 'installed: *no' "$out" "status reports installed: no"
assert_match 'pump: run complete' "$out" "status still tails an existing pump.log even when nothing is installed"

# ===========================================================================
# H -- Linux/cron fallback (ORCHID_SERVICE_OS=Linux, a test-only override so
# both platform branches are exercised deterministically regardless of the
# host actually running this suite): install renders a marker-guarded
# crontab line (never touching the real crontab under --dry-run), flooring
# the interval to whole minutes; uninstall reverses it; status parses it.
# ===========================================================================
export ORCHID_SERVICE_OS=Linux
trust_repo "$WORK"
out="$("$SERVICE" install --repo "$WORK" --interval-s 150 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "linux install --dry-run exits 0"
assert_match "$label_re" "$out" "linux install prints a label"
labelL="$(echo "$out" | grep -oE "$label_re" | head -n1)"
assert_eq "$label" "$labelL" "the label is the same hash regardless of platform (same repo path)"
record="$WORK/.orchid/runtime/pump.cron"
[ -f "$record" ] || fail "linux install must render + place a local pump.cron record for real, same as the plist on darwin"
line="$(cat "$record")"
assert_match '^\*/2 \* \* \* \*' "$line" "150s floors to 2 minutes (150/60=2, integer division)"
assert_match "ORCHID_REPO='$repo_canon'" "$line" "cron line carries ORCHID_REPO (canonical), single-quoted"
assert_match "TMPDIR='$parent'" "$line" "cron line carries TMPDIR set to the repo's parent (same rationale as the plist), single-quoted"
assert_match ' --service-log >> /dev/null 2>&1 ' "$line" \
  "cron sends scheduler-owned output to /dev/null and delegates logging to the gated pump"
grep -qF 'pump.log' <<<"$line" \
  && fail "cron must never open the target-controlled pump.log path before the pump trust gate"
assert_match "# orchid-service:$label" "$line" "cron line carries the marker comment used to find/remove it later"
assert_match 'DRY-RUN:.*crontab' "$out" "linux install --dry-run prints (never runs) the crontab pipeline"

# IMPORTANT fix (final review #1): same PATH-baking as the plist, for the
# cron fallback -- a scheduled cron pump gets scarcely more environment than
# launchd's own bare default, so PATH must be baked into the rendered line
# too (single-quoted, same as every other path-shaped value here -- Minor
# #5/final review).
assert_match "PATH='$PATH'" "$line" "cron line bakes in the installing user's \$PATH, single-quoted"

# Sub-minute interval floors to 1, never 0.
out="$("$SERVICE" install --repo "$WORK" --interval-s 30 --dry-run 2>&1)"
line="$(cat "$record")"
assert_match '^\*/1 \* \* \* \*' "$line" "an interval under 60s floors to 1 minute, never 0"

out="$("$SERVICE" status --repo "$WORK" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "linux status exits 0"
assert_match 'installed: *yes' "$out" "linux status reports installed: yes"
assert_match 'DRY-RUN:.*crontab' "$out" "linux status --dry-run prints (never runs) the crontab query"
assert_match 'pump: run complete' "$out" "linux status also tails pump.log"

out="$("$SERVICE" uninstall --repo "$WORK" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "linux uninstall --dry-run exits 0 when something is installed"
assert_match 'DRY-RUN:.*crontab' "$out" "linux uninstall --dry-run prints (never runs) the crontab pipeline"
assert_match 'nothing was removed' "$out" "and reports that it removed nothing"
[ -f "$record" ] \
  || fail "linux uninstall --dry-run must NOT remove the pump.cron record: the crontab line it describes is still installed, and this record is what status and uninstall reason from"
[ -f "$WORK/.orchid/runtime/service.json" ] \
  || fail "linux uninstall --dry-run must NOT clear the binding record either -- same reason as the darwin branch"

out="$(svc_uninstall_real --repo "$WORK" 2>&1)"; rc=$?
assert_eq 0 "$rc" "linux uninstall exits 0 when something was installed"
assert_match 'crontab' "$(cat "$SCHED_LOG")" \
  "the real linux uninstall runs the crontab pipeline that --dry-run only printed"
[ -f "$record" ] && fail "linux uninstall must remove exactly the pump.cron record it created"

out="$("$SERVICE" uninstall --repo "$WORK" --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "linux uninstall must also refuse cleanly when nothing is installed"

# ===========================================================================
# H2 -- IMPORTANT fix (task review): an unescaped % in a cron command field
# is cron's own line-continuation/stdin-feed marker -- a repo/log path
# containing a bare % used to render a command that cron would silently
# truncate at that character. % must render as the cron-escaped \% in the
# rendered line.
# ===========================================================================
WORKP="$(mktemp -d)/repo%with%percent"
mkdir -p "$WORKP"
( cd "$WORKP" && git init -q . && git commit -q --allow-empty -m root && mkdir -p .orchid/tasks )
WORKP_canon="$(cd "$WORKP" && pwd -P)"
trust_repo "$WORKP"

_outp="$("$SERVICE" install --repo "$WORKP" --interval-s 120 --dry-run 2>&1)"; rcp=$?
assert_eq 0 "$rcp" "linux install --dry-run exits 0 even when --repo contains % (out: $_outp)"
recordp="$WORKP/.orchid/runtime/pump.cron"
[ -f "$recordp" ] || fail "linux install must render + place a pump.cron record even when --repo contains %"
linep="$(cat "$recordp")"
assert_match "ORCHID_REPO='$(printf '%s' "$WORKP_canon" | sed 's/%/\\\\%/g')'" "$linep" \
  "cron line escapes a literal % in the repo path as \\% (cron's own escape for a literal percent), inside single quotes"
case "$linep" in
  *"ORCHID_REPO=$WORKP_canon "*|*"ORCHID_REPO='$WORKP_canon'"*)
    fail "cron line must NEVER carry an unescaped % in ORCHID_REPO -- cron would treat it as a line-continuation/stdin marker and silently truncate the command" ;;
esac
rm -rf "$(dirname "$WORKP")"

# ===========================================================================
# H3 -- IMPORTANT fix (task review): the crontab install/uninstall pipeline
# used to be hand-duplicated for --dry-run (print) vs. real (run), and had
# already drifted (the dry-run print was missing `|| true` and used a
# `(...)` subshell where the real path used a `{...}` group). Both paths
# now read ONE shared pipeline-string variable; ORCHID_SERVICE_DEBUG_CRON_
# CMD_FILE is a test-only seam that dumps that exact variable to a file
# (a plain `export` can't cross the process boundary to this test, since
# `orchid-service` runs as its own subprocess) so this suite can assert the
# --dry-run print (its "DRY-RUN: " prefix stripped) is byte-identical to
# it -- proof the two surfaces share one origin, not merely that they
# currently happen to read alike.
# ===========================================================================
seam_file="$WORK/.orchid/runtime/cron_seam.txt"
export ORCHID_SERVICE_DEBUG_CRON_CMD_FILE="$seam_file"

rm -f "$seam_file"
out="$("$SERVICE" install --repo "$WORK" --interval-s 90 --dry-run 2>&1)"
[ -f "$seam_file" ] || fail "install must write the test-only cron pipeline seam file when ORCHID_SERVICE_DEBUG_CRON_CMD_FILE is set"
dry_cmd="$(printf '%s\n' "$out" | grep '^DRY-RUN:' | sed 's/^DRY-RUN: //')"
seam_cmd="$(cat "$seam_file")"
assert_eq "$seam_cmd" "$dry_cmd" \
  "install --dry-run's printed command is byte-identical to the pipeline string the real path would eval"
assert_match 'grep -vF' "$seam_cmd" "the shared pipeline string strips any prior line for this marker"
assert_match '\|\| true' "$seam_cmd" "the shared pipeline string carries the || true guard (set -e safety, IMPORTANT 2)"

rm -f "$seam_file"
out="$("$SERVICE" uninstall --repo "$WORK" --dry-run 2>&1)"
[ -f "$seam_file" ] || fail "uninstall must also write the test-only cron pipeline seam file"
dry_cmd="$(printf '%s\n' "$out" | grep '^DRY-RUN:' | sed 's/^DRY-RUN: //')"
seam_cmd="$(cat "$seam_file")"
assert_eq "$seam_cmd" "$dry_cmd" \
  "uninstall --dry-run's printed command is byte-identical to the pipeline string the real path would eval"
assert_match '\|\| true' "$seam_cmd" "uninstall's shared pipeline string also carries the || true guard"

unset ORCHID_SERVICE_DEBUG_CRON_CMD_FILE
unset ORCHID_SERVICE_OS

# ===========================================================================
# H4 -- unattended-boundary regression: installed launchd/cron artifacts must
# send their own stdout/stderr to a no-effect sink. Only orchid-pump may open
# pump.log, after trust succeeds. Exercise the artifacts against all three
# adversarial states from the review: a trusted repo with a pump.log symlink,
# revoked trust, and a fresh repo replacing the acknowledged target path.
# ===========================================================================
make_scratch ATTACK_ROOT
ATTACK_REPO="$ATTACK_ROOT/repo"
ATTACK_OLD="$ATTACK_ROOT/original-repo"
ATTACK_VICTIM="$ATTACK_ROOT/outside.log"
mkdir -p "$ATTACK_REPO"
(
  cd "$ATTACK_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: planning\nrun_id: service-boundary\n---\n# Roadmap\n' \
    > .orchid/roadmap.md
)
ATTACK_REPO_CANON="$(cd "$ATTACK_REPO" && pwd -P)"
ATTACK_PARENT="$(cd "$ATTACK_REPO/.." && pwd -P)"
trust_repo "$ATTACK_REPO"

export ORCHID_SERVICE_OS=Darwin
attack_launchd_out="$("$SERVICE" install --repo "$ATTACK_REPO" --dry-run 2>&1)"
attack_label="$(printf '%s\n' "$attack_launchd_out" | grep -oE "$label_re" | head -n1)"
attack_plist="$HOME/Library/LaunchAgents/$attack_label.plist"
[ -f "$attack_plist" ] \
  || fail "adversarial launchd fixture must retain its installed plist"
attack_launchd_stdout="$(
  awk '/<key>StandardOutPath<\/key>/{getline; gsub(/^.*<string>|<\/string>.*$/, ""); print; exit}' \
    "$attack_plist"
)"
attack_launchd_stderr="$(
  awk '/<key>StandardErrorPath<\/key>/{getline; gsub(/^.*<string>|<\/string>.*$/, ""); print; exit}' \
    "$attack_plist"
)"
assert_eq /dev/null "$attack_launchd_stdout" \
  "installed launchd stdout is scheduler-owned /dev/null"
assert_eq /dev/null "$attack_launchd_stderr" \
  "installed launchd stderr is scheduler-owned /dev/null"

export ORCHID_SERVICE_OS=Linux
attack_cron_out="$("$SERVICE" install --repo "$ATTACK_REPO" --interval-s 60 --dry-run 2>&1)"
attack_record="$ATTACK_REPO/.orchid/runtime/pump.cron"
[ -f "$attack_record" ] \
  || fail "adversarial cron fixture must retain its installed record (out: $attack_cron_out)"
attack_cron_line="$(cat "$attack_record")"
assert_match ' --service-log >> /dev/null 2>&1 ' "$attack_cron_line" \
  "installed cron firing has no target-controlled pre-gate output path"

# Run the command portion of the exact installed cron line. Five schedule
# fields precede it; the final marker comment is service bookkeeping, not part
# of the command cron gives /bin/sh.
fire_installed_cron() {
  local installed_line="$1" installed_command
  installed_command="$(printf '%s\n' "$installed_line" | cut -d' ' -f6-)"
  installed_command="${installed_command% # orchid-service:*}"
  eval "$installed_command"
}

# Reproduce launchd's pre-exec stream handling from the paths parsed out of the
# installed plist, then invoke its exact pump mode and environment contract.
fire_installed_launchd() {
  HOME="$HOME" ORCHID_REPO="$ATTACK_REPO_CANON" TMPDIR="$ATTACK_PARENT" PATH="$PATH" \
    "$PUMP" --service-log \
    >> "$attack_launchd_stdout" 2>> "$attack_launchd_stderr"
}

printf 'trusted-symlink-sentinel\n' > "$ATTACK_VICTIM"
ln -s "$ATTACK_VICTIM" "$ATTACK_REPO/.orchid/runtime/pump.log"
if fire_installed_launchd; then
  fail "trusted service-mode pump must refuse a pump.log symlink"
fi
if fire_installed_cron "$attack_cron_line"; then
  fail "trusted cron firing must refuse a pump.log symlink"
fi
assert_eq trusted-symlink-sentinel "$(cat "$ATTACK_VICTIM")" \
  "installed scheduler firings never append through a trusted repo's pump.log symlink"

rc=0
out="$(ORCHID_REPO="$ATTACK_REPO" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "manual pump remains available when service logging is unsafe"
assert_match '^pump: run not running \(planning\), no lease yet$' "$out" \
  "manual pump preserves terminal diagnostics without opening the service log"
assert_eq trusted-symlink-sentinel "$(cat "$ATTACK_VICTIM")" \
  "manual diagnostics do not follow the service-log symlink"

HOME="$HOME" "$ORCHID_BIN" trust revoke "$ATTACK_REPO" >/dev/null \
  || fail "adversarial service fixture revocation must succeed"
printf 'revoked-sentinel\n' > "$ATTACK_VICTIM"
if fire_installed_launchd; then
  fail "installed launchd firing must be denied after trust revocation"
fi
if fire_installed_cron "$attack_cron_line"; then
  fail "installed cron firing must be denied after trust revocation"
fi
assert_eq revoked-sentinel "$(cat "$ATTACK_VICTIM")" \
  "revoked installed-service firings have no pre-gate symlink write"

# Re-acknowledge the original incarnation, leave both installed artifacts in
# place, then replace the target at the same canonical path. The old schedule
# must not lend trust or a writable log stream to the replacement.
trust_repo "$ATTACK_REPO"
mv "$ATTACK_REPO" "$ATTACK_OLD"
mkdir -p "$ATTACK_REPO"
(
  cd "$ATTACK_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks .orchid/runtime
  printf -- '---\nrun_status: planning\nrun_id: service-replacement\n---\n# Roadmap\n' \
    > .orchid/roadmap.md
)
ln -s "$ATTACK_VICTIM" "$ATTACK_REPO/.orchid/runtime/pump.log"
printf 'replacement-sentinel\n' > "$ATTACK_VICTIM"
if fire_installed_launchd; then
  fail "installed launchd firing must deny a replacement repository"
fi
if fire_installed_cron "$attack_cron_line"; then
  fail "installed cron firing must deny a replacement repository"
fi
assert_eq replacement-sentinel "$(cat "$ATTACK_VICTIM")" \
  "replacement-repo installed-service firings have no pre-gate symlink write"
assert_eq pump.log "$(list_dir_entries "$ATTACK_REPO/.orchid/runtime")" \
  "denied replacement firings leave target runtime state untouched"

rm -f "$attack_plist"
rm -rf "$ATTACK_ROOT"
unset ORCHID_SERVICE_OS

# ===========================================================================
# I -- multiple repos = multiple distinct labels, never colliding, and each
# repo's own uninstall never disturbs the other's.
# ===========================================================================
# No new EXIT trap here -- helpers.sh already owns one (WORK cleanup + the
# FAILS-based exit code); a second `trap ... EXIT` in this file would
# silently REPLACE it, not chain, dropping both. WORK2 is removed by hand
# at the end of this section instead.
make_scratch WORK2
( cd_scratch "$WORK2" && git init -q . && git commit -q --allow-empty -m root && mkdir -p .orchid/tasks )
trust_repo "$WORK2"

out1="$("$SERVICE" install --repo "$WORK" --dry-run 2>&1)"
out2="$("$SERVICE" install --repo "$WORK2" --dry-run 2>&1)"
l1="$(echo "$out1" | grep -oE "$label_re" | head -n1)"
l2="$(echo "$out2" | grep -oE "$label_re" | head -n1)"
[ "$l1" != "$l2" ] || fail "two distinct repos must get two distinct labels"
[ -f "$HOME/Library/LaunchAgents/$l1.plist" ] || fail "repo 1's plist must exist"
[ -f "$HOME/Library/LaunchAgents/$l2.plist" ] || fail "repo 2's plist must exist"

svc_uninstall_real --repo "$WORK2" >/dev/null 2>&1
[ -f "$HOME/Library/LaunchAgents/$l1.plist" ] || fail "uninstalling repo 2 must not remove repo 1's plist"
[ -f "$HOME/Library/LaunchAgents/$l2.plist" ] && fail "uninstalling repo 2 must remove repo 2's own plist"
svc_uninstall_real --repo "$WORK" >/dev/null 2>&1
rm -rf "$WORK2"

# ===========================================================================
# K (T036) -- THE PUMP OUTLIVES ITS RUN. `orchid service install` registers a
# schedule and nothing ever removes it: not the last task merging, not `orchid
# run accept`, not a `complete` run. Observed live: six tasks reached done, the
# work was merged and released, and the agent was still firing every 240s --
# and had the operator not uninstalled first, it would have been left waking
# against a DELETED directory, an ordering written down nowhere.
#
# The gap was never a missing verb (`uninstall` has always existed). It was
# that nothing tied the schedule's lifetime to anything, and nothing said it
# had to be undone. The parts below are in the order an operator meets them, and
# each was added by a finding rather than planned as a set -- so the list grows
# and is deliberately not headed by a count that would go stale the day it does:
#
#   K1  install RECORDS what it bound itself to, on both sides of the
#       boundary, and says the ordering that record exists to keep.
#   K2  RED/GREEN: a pump whose checkout is GONE fails loudly; the same pump
#       against a checkout that is present stays an ordinary quiet no-op.
#       Then the two arms about ORDER: that refusal is reached even when the
#       run is `complete` (the cheerful no-op must not answer first), and a
#       `complete` run that still has a schedule bound to it names the
#       command that ends the certain waste — on the pump's own output, and
#       again through `orchid doctor`, which is the only one of the two a
#       real scheduler does not send to /dev/null.
#   K3  RED/GREEN: a checkout carrying a live binding is refused for removal,
#       naming the uninstall command; one without a binding is not.
#   K4  uninstall still works once the checkout is gone -- the command
#       `orchid doctor` names for a leftover schedule must not itself need
#       the directory that is missing.
#   K5  the binding lands whole or not at all, and it lands BEFORE the
#       scheduler does: an install that cannot record it installs nothing.
#   K6  ...and the record that ordering can leave behind is always clearable,
#       so a half-failed install cannot wedge the removal guard.
#   K7  RED/GREEN: an uninstall whose `launchctl unload` FAILED removes
#       nothing while launchd still reports the job -- and still clears
#       normally when the failure was a plist nothing had ever loaded.
#   K8  RED/GREEN: the same distinction where there is no unload to try --
#       a plist already gone is not evidence of an unloaded agent, and the
#       binding is then the last name that agent has.
#   K9  RED/GREEN: the record path itself obstructed -- an install that would
#       report a binding orchid_service_bound cannot see must install no
#       schedule, since that pairing is a live agent behind a guard that
#       waves the checkout through.
#   K10 RED/GREEN: the same obstruction at the OTHER destination -- an install
#       that would report a binding no machine-local walk can find must
#       install no schedule either, since that pairing is a live agent with
#       no name left anywhere once its checkout is removed.
#   K11 RED/GREEN: `launchctl list` returns nonzero for two different facts,
#       and only one of them is an answer. Both teardown paths must clear on
#       launchd's own "no such job" and refuse on a query that never reached
#       launchd -- read alike, the second deletes the last name a still-firing
#       agent has.
#   K12 RED/GREEN: the ordering every one of the arms above protects is ONE
#       conditional operation, not two commands. A refused uninstall must never
#       reach `git worktree remove`; the identical command with the identical
#       fixture must remove the worktree once the uninstall succeeds.
#   K13 RED/GREEN: WHICH schedule those arms act on. Every one of them used to
#       re-hash the CURRENT repo path, which stops naming the installed
#       schedule the moment a checkout is moved. Identity comes from the
#       binding twins install wrote, and twins that disagree are refused.
#   K14 RED/GREEN: ...and WHO is allowed to act on it. Twins that agree name the
#       schedule; they say nothing about the caller, because a checkout copied
#       with `cp -R` carries the repo-local half inside it byte for byte. A copy
#       must refuse before any scheduler call, binding removal or worktree
#       removal, while the checkout git actually has registered -- including one
#       that was MOVED -- still tears down normally. And the refusal must not
#       wedge: once the checkout a record names is GONE, the record is clearable
#       again, or a directory is guarded by a file no verb can take.
#   K15 RED/GREEN: a recorded refusal is evidence about the LAST wake, not a
#       property of the label. It must survive a refused wake and a preview, and
#       be retired by a real (re)install and by a wake that found the target
#       healthy and succeeded -- or `orchid doctor` prints a schedule as failing
#       directly beneath its own line calling that schedule healthy. K15b carries
#       that rule through the WHOLE wake: the tick hand-off is the last statement
#       of a scheduled pass, so a tick that fails is a wake that failed and
#       retires nothing, while one that succeeds retires the note.
#   K16 RED/GREEN: the repo-local record is UNTRUSTED INPUT. It lives inside the
#       checkout a run's engines write to, and its label becomes a path
#       COMPONENT while its artifact becomes a whole path that is unloaded and
#       then deleted. Both are held to what `orchid service install` could have
#       produced, and anything else is refused before any path built from it is
#       opened, probed, cleared or removed -- while the record install actually
#       wrote tears the schedule down exactly as before.
# ===========================================================================
source "$REPO_ROOT/lib/common.sh"
# ...and lib/frontmatter.sh for K15b alone, which parks a task at `arbitrating`
# to stage the judgment boundary a wake has to find before it can reach the
# tick. Asserted rather than assumed: this file runs without `set -e`, so a
# source that failed would leave `fm_set` as a silent 127 per call, the task
# would stay `pending`, the wake would never hand off, and the arm would be
# testing a pump that stopped three steps earlier.
source "$REPO_ROOT/lib/frontmatter.sh"
command -v fm_set >/dev/null 2>&1 \
  || fail "fixture: lib/frontmatter.sh did not load — K15b's boundary could not be staged"

export ORCHID_SERVICE_OS=Darwin
make_scratch BIND
BIND_REPO="$BIND/repo"
mkdir -p "$BIND_REPO"
(
  cd "$BIND_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: planning\nrun_id: r-bind\n---\n# Roadmap\n' > .orchid/roadmap.md
)
BIND_CANON="$(cd "$BIND_REPO" && pwd -P)"
trust_repo "$BIND_REPO"

# -- K1: the binding record ------------------------------------------------
bind_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "install --dry-run exits 0 for the binding fixture (out: $bind_out)"
bind_label="$(echo "$bind_out" | grep -oE "$label_re" | head -n1)"
bind_rec="$BIND_REPO/.orchid/runtime/service.json"
[ -f "$bind_rec" ] \
  || fail "install must record the binding INSIDE the checkout it bound itself to -- that copy is what a removal guard reads"
assert_eq "$BIND_CANON" "$(jq -r '.repo' "$bind_rec")" \
  "the binding names the canonical repo path the label was hashed from"
assert_eq "$bind_label" "$(jq -r '.label' "$bind_rec")" \
  "the binding names the label the schedule was actually installed under"
assert_eq darwin "$(jq -r '.platform' "$bind_rec")" "the binding names the platform branch that installed it"
assert_eq 240 "$(jq -r '.interval_s' "$bind_rec")" "the binding carries the interval actually installed"

bind_mrec="$HOME/.orchid/services/$bind_label.json"
[ -f "$bind_mrec" ] \
  || fail "install must ALSO record the binding machine-locally -- that is the copy that OUTLIVES the checkout, and the only thing left to name a leftover schedule once the repo is gone"
assert_eq "$BIND_CANON" "$(jq -r '.repo' "$bind_mrec")" "the machine-local copy names the same repo"

assert_match 'teardown:' "$bind_out" \
  "install states the obligation it just created, at the moment it creates it"
assert_match 'BEFORE removing' "$bind_out" \
  "and states the ORDERING, not merely that a reversal exists"
assert_match 'service uninstall --repo' "$bind_out" "and names the exact command that ends it"

bind_status="$("$SERVICE" status --repo "$BIND_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "status still exits 0 with a binding recorded"
assert_match 'binding:' "$bind_status" "status names the binding record"
assert_match 'BEFORE removing' "$bind_status" \
  "status states the teardown ordering next to the schedule it constrains"

# -- K2: the pump against a checkout that is, and is not, still there -------
# GREEN first, so the RED case below is evidence of DETECTION rather than of a
# pump that refuses everything: the same binary, the same repo, the checkout
# present, is the ordinary cron-friendly no-op it has always been.
rc=0
bind_green="$(ORCHID_REPO="$BIND_CANON" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "a pump whose checkout is present is an ordinary quiet no-op"
assert_match '^pump: run not running \(planning\), no lease yet$' "$bind_green" \
  "and reports the wait state it found, without refusing"
green_case "a pump whose integration worktree is present still exits 0 with its ordinary diagnostic"

# RED: the checkout the schedule was installed against is deleted -- the exact
# state `git worktree remove` leaves. Every other check in the pump answers
# "nothing to do here, exit 0" for a path that does not exist, so before this
# the agent polled forever in silence with no signal anywhere.
GONE_REPO="$BIND/gone-repo"
mkdir -p "$GONE_REPO"
(
  cd "$GONE_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: running\nrun_id: r-gone\n---\n# Roadmap\n' > .orchid/roadmap.md
)
GONE_CANON="$(cd "$GONE_REPO" && pwd -P)"
trust_repo "$GONE_REPO"
gone_install="$("$SERVICE" install --repo "$GONE_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the leftover-schedule fixture installs cleanly first (out: $gone_install)"
gone_label="$(echo "$gone_install" | grep -oE "$label_re" | head -n1)"
[ -f "$HOME/.orchid/services/$gone_label.json" ] \
  || fail "fixture: the machine-local binding must exist before the checkout is removed"

rm -rf "$GONE_REPO"
[ -d "$GONE_CANON" ] && fail "fixture: the checkout must really be gone before the RED case runs"

rc=0
gone_pump="$(ORCHID_REPO="$GONE_CANON" "$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a pump whose checkout has been deleted must FAIL, not exit 0 -- a silent successful no-op is exactly what hid this for a whole run"
assert_match 'does not exist' "$gone_pump" "the refusal says plainly that the checkout is gone"
assert_match 'service uninstall --repo' "$gone_pump" \
  "and names the command that removes the schedule still pointing at it"
red_case "a pump whose integration worktree has been deleted refuses loudly instead of polling forever"

# The other half of the same failure: the DIRECTORY survived while the
# repository behind it did not. A `.git` file pointing at a gitdir that is not
# there is exactly what a pruned/removed worktree registration leaves.
DEAD_REPO="$BIND/dead-git"
mkdir -p "$DEAD_REPO"
(
  cd "$DEAD_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: running\nrun_id: r-dead\n---\n# Roadmap\n' > .orchid/roadmap.md
)
rm -rf "$DEAD_REPO/.git"
printf 'gitdir: %s\n' "$DEAD_REPO/no-such-common-dir" > "$DEAD_REPO/.git"
rc=0
dead_pump="$(ORCHID_REPO="$DEAD_REPO" "$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a checkout whose repository is gone must refuse too -- the driver's first act is a ref read, and no later pass repairs it"
assert_match 'no longer a git checkout' "$dead_pump" \
  "the refusal distinguishes a dead repository from a missing directory"
red_case "a pump whose repository is gone while the directory remains also refuses loudly"

# ...and the arms that must STAY quiet no-ops are still quiet: the loud
# refusals above must not have been bought by making the pump strict about
# every unusual directory it meets.
QUIET_DIR="$BIND/not-an-orchid-repo"
mkdir -p "$QUIET_DIR"
rc=0
quiet_pump="$(ORCHID_REPO="$QUIET_DIR" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "a directory that is not an orchid repo at all is still a silent, successful no-op"
assert_eq "pump: not an orchid repo" "$quiet_pump" \
  "and says so plainly -- a non-git scratch directory must not trip the dead-repository refusal"
green_case "an ordinary not-an-orchid-repo directory keeps its exit-0 no-op, git or no git"

# ...and the liveness question is asked BEFORE the arm most likely to be true
# at the same time. A run reaching `complete` is exactly when its checkout gets
# torn down -- that was the live finding's cleanup step -- so "the run is
# finished" and "the repository behind this directory is gone" arrive together.
# The `complete` arm is a cheerful `exit 0`; asked first, it swallows the
# refusal entirely and the schedule reports "pump: run complete" against a dead
# checkout every interval, forever.
DEAD_DONE="$BIND/dead-git-complete"
mkdir -p "$DEAD_DONE"
(
  cd "$DEAD_DONE" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: complete\nrun_id: r-dead-done\n---\n# Roadmap\n' > .orchid/roadmap.md
)
rm -rf "$DEAD_DONE/.git"
printf 'gitdir: %s\n' "$DEAD_DONE/no-such-common-dir" > "$DEAD_DONE/.git"
rc=0
dead_done_pump="$(ORCHID_REPO="$DEAD_DONE" "$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a dead checkout must refuse even when its run is complete -- the 'run complete' no-op must not be what answers for a repository that is gone"
assert_match 'no longer a git checkout' "$dead_done_pump" \
  "and refuses with the broken-target reason, not with the run's status"
red_case "a completed run's dead checkout still refuses: liveness is asked before the no-op that would swallow it"

# -- the first half of the finding: a COMPLETE run keeps waking forever ----
# `run_status` never leaves a terminal state on its own, so every wake after
# the last task merges is a certain no-op. Exit 0 is right -- a finished run is
# not a failure -- but the silence is what let an agent fire every 240s against
# a finished run for an afternoon. When a binding says a schedule really is
# installed here, the no-op names the command that ends it.
DONE_REPO="$BIND/done-run"
mkdir -p "$DONE_REPO"
(
  cd "$DONE_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: complete\nrun_id: r-done\n---\n# Roadmap\n' > .orchid/roadmap.md
)
DONE_CANON="$(cd "$DONE_REPO" && pwd -P)"
trust_repo "$DONE_REPO"
done_install="$("$SERVICE" install --repo "$DONE_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the finished-run fixture installs a schedule first (out: $done_install)"
rc=0
done_pump="$(ORCHID_REPO="$DONE_CANON" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "a completed run is still a quiet, successful no-op -- a cron poll must not start erroring once a run finishes"
assert_match '^pump: run complete$' "$done_pump" "and still reports the run's state verbatim, on its own line"
assert_match 'every further wake is a no-op' "$done_pump" \
  "but says plainly that nothing here will ever change again"
assert_match 'service uninstall --repo' "$done_pump" \
  "and names the command that stops the waste, which nothing anywhere used to do"
red_case "a completed run with a schedule still installed against it names the command that ends the waste"

# ...and the same fact, said where a SCHEDULED wake can actually be heard.
# Every line the arm above prints is written before the pump opens its repo-
# local service log -- nothing may open a target-controlled path ahead of the
# unattended trust gate -- so a real launchd agent or cron line sends both to
# /dev/null, and this arm exits 0, so there is not even a nonzero status left
# behind. Read only from the pump's own output, the remedy for the certain-
# waste half of the finding is therefore invisible in exactly the configuration
# it exists for. `orchid doctor` reads the machine-local binding store instead
# and asks the SAME predicate about the run each binding points at.
done_label="$(echo "$done_install" | grep -oE "$label_re" | head -n1)"
done_doctor="$(ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 || true)"
assert_match "WARN: pump service $done_label is still installed" "$done_doctor" \
  "doctor warns about a schedule bound to a run that has already finished"
assert_match 'whose run is complete' "$done_doctor" \
  "and names the run state that makes every further wake certain waste"
assert_match 'every further wake is a certain no-op' "$done_doctor" \
  "and says the waste is guaranteed rather than merely possible"
assert_match 'uninstall the schedule, THEN remove the checkout' "$done_doctor" \
  "and states the ordering, not just that a reversal exists"
# Compared literally, never as a pattern: a scratch path carries `.` and can
# carry other ERE metacharacters, and a pattern that matched anyway would not be
# evidence that this path was named.
case "$done_doctor" in
  *"$DONE_CANON"*) ;;
  *) fail "doctor's finished-run warning must name the exact checkout the schedule is bound to" ;;
esac
red_case "doctor reports a live schedule whose run has already reached a terminal state"

# GREEN, from the SAME doctor output: a binding whose run is still under way is
# ordinary state and keeps its `ok:` line. Without this the warning above would
# be satisfied by a doctor that flagged every binding it could see.
case "$done_doctor" in
  *"ok: pump service installed for $BIND_CANON (label $bind_label)"*) ;;
  *) fail "a binding whose run is still under way must stay an ok: line -- the warning must be about the run's state, not about having a binding at all" ;;
esac
green_case "a schedule bound to a run that is still under way is reported as ordinary state"

# And `orchid service status` -- the verb an operator actually runs to ask "is
# this schedule still needed?" -- answers that question rather than only "yes, a
# schedule exists". Same predicate again, so the three surfaces cannot disagree.
done_status="$("$SERVICE" status --repo "$DONE_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "status still exits 0 against a finished run (out: $done_status)"
assert_match '^ +run: +complete ' "$done_status" \
  "status names the finished run behind the schedule it is reporting"
assert_match 'every further wake of this schedule is a certain no-op' "$done_status" \
  "and says what that means for the schedule, not merely what the run_status is"
red_case "service status names a finished run as the reason its schedule has nothing left to do"

bind_status_live="$("$SERVICE" status --repo "$BIND_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "status still exits 0 against a run that is under way"
grep -qE 'every further wake of this schedule is a certain no-op' <<<"$bind_status_live" \
  && fail "a schedule whose run is still under way must NOT be reported as certain waste"
assert_match 'teardown:' "$bind_status_live" \
  "and still states the teardown ordering, which applies either way"
green_case "service status leaves a live run's schedule unqualified"

# The same complete run with NO schedule bound is told nothing extra: the line
# exists to end a real obligation, not to lecture a hand-run pump.
svc_uninstall_real --repo "$DONE_REPO" >/dev/null 2>&1
rc=0
done_unbound="$(ORCHID_REPO="$DONE_CANON" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "an unbound completed run is still a quiet no-op"
assert_eq "pump: run complete" "$done_unbound" \
  "and says only that -- with no schedule installed there is no teardown to name"
green_case "a completed run with no schedule bound to it keeps its one-line no-op"

# -- K2b: `accepting` -- the state the live finding was ACTUALLY in --------
# `complete` is not a state a run reaches on its own. runners/orchid-drive
# takes COMPLETION's mechanical half itself: the pass that finds every task
# done runs `run advance accepting`, and then stops, because the acceptance
# evidence behind `orchid run accept` is judgment work no verb decides. So the
# run in the live finding -- six tasks done, merged, released, an agent still
# firing every 240s -- was sitting in `accepting` the whole time, and a report
# that knew only `complete` said nothing at all about it.
#
# It is reported as its own fact, never folded into the finished-run one:
# `accepting -> running` is a legal edge, so this run is PARKED rather than
# over, and the first thing an operator needs is the verb that unparks it.
ACC_REPO="$BIND/accepting-run"
mkdir -p "$ACC_REPO"
(
  cd "$ACC_REPO" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: accepting\nrun_id: r-accepting\n---\n# Roadmap\n' > .orchid/roadmap.md
)
ACC_CANON="$(cd "$ACC_REPO" && pwd -P)"
trust_repo "$ACC_REPO"
acc_install="$("$SERVICE" install --repo "$ACC_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the awaiting-acceptance fixture installs a schedule first (out: $acc_install)"
acc_label="$(echo "$acc_install" | grep -oE "$label_re" | head -n1)"

rc=0
acc_pump="$(ORCHID_REPO="$ACC_CANON" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "a run waiting for acceptance is a wait state, not a failure"
assert_match 'waiting for an operator' "$acc_pump" \
  "the pump names the wait rather than passing over it in silence"
assert_match 'orchid run accept' "$acc_pump" \
  "and names the verb that ends it, which is the one thing no scheduled wake can do"
assert_match 'run not running \(accepting\)' "$acc_pump" \
  "and still reports the ordinary state it found -- the diagnosis is added, never substituted"
red_case "a run parked on an operator's acceptance is named by the pump instead of polled in silence"

acc_doctor="$(ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 || true)"
assert_match "WARN: pump service $acc_label is still installed" "$acc_doctor" \
  "doctor warns about a schedule bound to a run that only an operator can move"
assert_match 'whose run is accepting' "$acc_doctor" "and names the state it is parked in"
assert_match 'only an operator can accept the run' "$acc_doctor" \
  "and says why no wake of that schedule will change it"
grep -qE 'run is accepting.*never leaves that state on its own' <<<"$acc_doctor" \
  && fail "an accepting run must NOT be reported as finished: it can still go back to running, and telling an operator to tear the checkout down would be wrong"
red_case "doctor reports a schedule bound to a run that is waiting for its operator"

acc_status="$("$SERVICE" status --repo "$ACC_REPO" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "status still exits 0 against a run awaiting acceptance (out: $acc_status)"
assert_match '^ +run: +accepting ' "$acc_status" "status names the parked run behind the schedule"
assert_match 'orchid run accept' "$acc_status" "and the verb an operator has to run"

# GREEN twin, from the SAME doctor output: the live-run binding is untouched by
# any of this. Without it the warnings above would be satisfied by a doctor
# that flagged every binding it can see.
case "$acc_doctor" in
  *"ok: pump service installed for $BIND_CANON (label $bind_label)"*) ;;
  *) fail "a binding whose run is still under way must stay an ok: line while an accepting one is warned about" ;;
esac
green_case "a schedule bound to a run that is still under way is not reported as parked"

# -- K2c: a bound checkout whose REPOSITORY is gone, and the refusal it left
# The pump refuses this shape as loudly as a deleted directory -- and just as
# inaudibly: the plist and cron line it fires from send both streams to
# /dev/null. So the refusal is recorded machine-locally, beside the binding
# that outlives the checkout, and `orchid doctor` reads it back. Doctor can see
# for itself that a target is dead; only the schedule can say that it fired at
# it, which is what tells an operator this is costing them right now.
DEADBIND="$BIND/dead-git-bound"
mkdir -p "$DEADBIND"
(
  cd "$DEADBIND" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: running\nrun_id: r-dead-bound\n---\n# Roadmap\n' > .orchid/roadmap.md
)
# The CANONICAL path, because that is what `install` hashes its label from and
# bakes into the artifact as ORCHID_REPO -- a scheduled pump therefore arrives
# with exactly this string, which is what lets it find its own binding.
DEADBIND_CANON="$(cd "$DEADBIND" && pwd -P)"
trust_repo "$DEADBIND"
db_install="$("$SERVICE" install --repo "$DEADBIND" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the dead-repository fixture installs a schedule first (out: $db_install)"
db_label="$(echo "$db_install" | grep -oE "$label_re" | head -n1)"

db_doctor_before="$(ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 || true)"
case "$db_doctor_before" in
  *"ok: pump service installed for $DEADBIND_CANON"*) ;;
  *) fail "GREEN: while the repository is intact its binding is ordinary state" ;;
esac
green_case "a bound checkout with its repository intact is reported as ordinary state"

rm -rf "$DEADBIND/.git"
printf 'gitdir: %s\n' "$DEADBIND/no-such-common-dir" > "$DEADBIND/.git"
rc=0
db_pump="$(ORCHID_REPO="$DEADBIND_CANON" "$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "the pump must still refuse a bound checkout whose repository is gone (out: $db_pump)"
assert_match 'no longer a git checkout' "$db_pump" "and says which of the two shapes it met"
db_doctor="$(ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 || true)"
assert_match "WARN: pump service $db_label is still installed" "$db_doctor" \
  "doctor warns about a schedule whose repository is gone, not only about one whose directory is"
assert_match 'whose repository is gone' "$db_doctor" \
  "and distinguishes it from a directory that was deleted outright"
assert_match 'the schedule last woke and refused' "$db_doctor" \
  "and reports that the schedule really did fire and refuse -- the pump's own words, which the scheduler sent to /dev/null"
assert_match 'refused: .*no longer a git checkout' "$db_doctor" \
  "and the refusal it prints is the pump's own reason, not a rewording of it"
red_case "a bound checkout whose repository is gone is reported, with the refusal its schedule recorded"

# ...and the record goes when the schedule does: a refusal describing a
# schedule that no longer exists would be a warning nobody can act on.
svc_uninstall_real --repo "$DEADBIND_CANON" >/dev/null 2>&1
[ -f "$HOME/.orchid/services/$db_label.refusal" ] \
  && fail "uninstall must clear the recorded refusal along with the binding it belongs to"
db_doctor_after="$(ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 || true)"
case "$db_doctor_after" in
  *"$db_label"*) fail "doctor must stop reporting an uninstalled schedule entirely" ;;
esac
green_case "uninstalling a leftover schedule clears its recorded refusal with it"

# -- K3: no removal walks past a live binding ------------------------------
# The guard is asked at every checkout-removal site orchid owns (the durable-
# commit temp worktree, `run new`'s rollover worktree, `orchid merge`'s
# validation worktree). Those are all mktemp trees that never carry a binding,
# so the only way to show the guard can DETECT anything is to feed it one.
rc=0
guard_red="$(orchid_service_removal_guard "$BIND_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a checkout with a live pump-service binding must not be removable"
assert_match 'refusing to remove' "$guard_red" "the guard says it is refusing, and which path"
assert_match 'uninstall the schedule FIRST' "$guard_red" "and states the ordering, not just the objection"
assert_match 'service uninstall --repo' "$guard_red" "and names the command that clears the way"
red_case "a checkout carrying a live pump-service binding is refused for removal"

rc=0
guard_green="$(orchid_service_removal_guard "$BIND/never-bound" 2>&1)" || rc=$?
assert_eq 0 "$rc" "a checkout with no binding is removable"
assert_eq "" "$guard_green" "and the guard says nothing at all about it"
green_case "a checkout with no pump-service binding passes the removal guard silently"

# -- K4: the leftover schedule is removable, and findable -----------------
# `orchid doctor` is the only surface left once the checkout is gone: the
# repo-local record went into the bin with it, and the pump's own refusal goes
# to the scheduler's /dev/null. Deliberately NOT scoped to the repo doctor was
# run in -- a report scoped to a repository can say nothing about one that no
# longer exists.
doctor_out="$(ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 || true)"
assert_match "WARN: pump service $gone_label is still installed" "$doctor_out" \
  "doctor reports the leftover schedule from the record that outlived its repository"
assert_match 'which no longer exists' "$doctor_out" \
  "and says the repository it is bound to is gone, rather than merely listing it"
# The PATH itself is compared literally, never as a pattern: a scratch path
# carries `.` and can carry other ERE metacharacters, and a pattern that
# happens to match anyway would not be evidence that this path was named.
case "$doctor_out" in
  *"$GONE_CANON"*) ;;
  *) fail "doctor's warning must name the exact repository path the leftover schedule points at" ;;
esac
assert_match "orchid service uninstall --repo" "$doctor_out" \
  "and names the command that removes it"
# The pump refused against that deleted path back in K2, and under a real
# scheduler said so to /dev/null. Doctor reports the refusal itself, not just
# the fact that a binding exists -- an operator can then tell a schedule that
# was installed and never fired from one failing on its interval right now.
assert_match 'refused: .*does not exist' "$doctor_out" \
  "doctor reports the refusal the schedule recorded, in the pump's own words -- the only trace a scheduled wake leaves"

rc=0
gone_uninstall="$(svc_uninstall_real --repo "$GONE_CANON" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "uninstall must work once the checkout is gone -- it is the command doctor names for exactly that state (out: $gone_uninstall)"
assert_match 'no longer exists' "$gone_uninstall" \
  "and says why it is reasoning from the machine-local record instead of the repo"
[ -f "$HOME/Library/LaunchAgents/$gone_label.plist" ] \
  && fail "uninstall must remove the leftover plist even though its repository is gone"
[ -f "$HOME/.orchid/services/$gone_label.json" ] \
  && fail "uninstall must remove the machine-local binding too, or doctor keeps reporting a schedule that no longer exists"

# A successful uninstall of a LIVE checkout clears both records and says the
# checkout is now safe to remove -- the other end of K3's refusal.
bind_uninstall="$(svc_uninstall_real --repo "$BIND_REPO" 2>&1)"; rc=$?
assert_eq 0 "$rc" "uninstall exits 0 for the live binding fixture"
assert_match 'is now safe to remove' "$bind_uninstall" \
  "uninstall says the one thing the operator was waiting to hear before removing the checkout"
[ -f "$bind_rec" ] && fail "uninstall must remove the repo-local binding record"
[ -f "$bind_mrec" ] && fail "uninstall must remove the machine-local binding record"
rc=0
guard_after="$(orchid_service_removal_guard "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" "and the removal guard lets the checkout go once the schedule is gone"
green_case "a checkout whose schedule has been uninstalled passes the removal guard"

# -- K5: the binding lands whole, or not at all ----------------------------
# An install writes its binding BEFORE it touches the scheduler, and both
# halves land together or neither does. The ordering is the point: a record
# with no schedule is harmless and self-correcting (the guard is merely
# conservative, doctor names it, uninstall clears it), while a schedule with no
# record is precisely the invisible leftover this whole section exists to stop
# -- and every failure between the two produces one, if the scheduler goes
# first.
#
# The store is made unwritable by putting a regular FILE where the directory
# belongs, which is the one injection that fails at the STAGING step, before
# anything at all has been committed. (A directory at the record's OWN path
# fails somewhere else entirely -- `mv file dir` moves the file INTO it and
# succeeds -- so it is refused before staging rather than by it, and K9/K10
# are where that arm is proved for each destination in turn.) Moved aside
# rather than removed -- other sections' bindings live in there.
mv "$HOME/.orchid/services" "$HOME/.orchid/services.saved" \
  || fail "fixture: could not set the machine-local binding store aside"
printf 'not a directory\n' > "$HOME/.orchid/services"
rc=0
atom_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an install that cannot record its binding must refuse -- the copy that survives the checkout is the only thing that can ever name a leftover schedule"
assert_match 'could not record the service binding' "$atom_out" \
  "and names the binding as what it refused on, not some generic install failure"
[ -f "$bind_rec" ] \
  && fail "a refused install must leave NO repo-local record either: both halves are prepared and only then committed"
[ -f "$HOME/Library/LaunchAgents/$bind_label.plist" ] \
  && fail "and must have placed no scheduler artifact at all: the binding is written BEFORE the scheduler is touched, so a failure there installs nothing"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the checkout stays removable -- a refused install must not wedge the guard it never armed"
red_case "an install whose binding cannot be recorded installs nothing at all"

rm -f "$HOME/.orchid/services"
mv "$HOME/.orchid/services.saved" "$HOME/.orchid/services" \
  || fail "fixture: could not restore the machine-local binding store"

# -- K6: the record is always clearable -----------------------------------
# Writing the record first makes "a binding with no artifact behind it" a
# REACHABLE state, and that record makes the removal guard refuse the checkout.
# So the one verb the guard names must not itself require the artifact, or a
# half-failed install wedges a checkout that has no schedule at all.
reinstall_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the fixture re-installs cleanly once its record store is writable again (out: $reinstall_out)"
[ -f "$bind_rec" ] || fail "fixture: the re-install must have recorded the binding"
rm -f "$HOME/Library/LaunchAgents/$bind_label.plist"
rc=0
# `svc_uninstall_notfound 'launchctl list'`, not `svc_uninstall_real`: the state
# under test is an artifact that NEVER LANDED, so launchd holds no job under
# this label, and since K8 that is a question uninstall actually asks. Having
# the stubbed `list` answer 113 is how this fixture answers it -- a stub that
# answered "still loaded" would be describing a different state, and one that
# merely failed would be describing no state at all (K11).
orphan_out="$(svc_uninstall_notfound 'launchctl list' --repo "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "uninstall must clear a binding whose scheduler artifact is not there (out: $orphan_out)"
assert_match 'clearing the binding record' "$orphan_out" \
  "and says it is doing exactly that, rather than reporting an agent it did not unload"
[ -f "$bind_rec" ] && fail "the orphaned repo-local record must be gone"
[ -f "$bind_mrec" ] && fail "and so must its machine-local copy"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the checkout is removable again -- the guard cannot be left armed by a record no verb could clear"
green_case "uninstall clears a binding record whose scheduler artifact never landed"

# -- K7: a failed unload removes nothing ----------------------------------
# The same finding as K5, reached from the far end of the lifetime. K5 is about
# an install that cannot record its binding; this is about an UNINSTALL whose
# `launchctl unload` fails. The removals immediately after it are the plist --
# the only path an unload can name that agent by -- and the binding record, the
# only thing on this machine that names the schedule at all. Performed while
# the job is still loaded, they manufacture precisely the leftover this whole
# section exists to prevent, and report success while doing it: the guard stops
# refusing, `orchid doctor` has nothing left to see, and the agent keeps firing.
#
# The unload is failed through the scheduler stub (svc_uninstall_failing) --
# the system call is the only stubbed thing; every removal, record and refusal
# around it is the real one.
reinst2_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the failed-unload fixture re-installs a schedule first (out: $reinst2_out)"
bind_plist="$HOME/Library/LaunchAgents/$bind_label.plist"
[ -f "$bind_plist" ] || fail "fixture: the re-install must have placed the plist"
[ -f "$bind_rec" ] || fail "fixture: the re-install must have written the repo-local binding"
[ -f "$bind_mrec" ] || fail "fixture: the re-install must have written the machine-local binding"

rc=0
stuck_out="$(svc_uninstall_failing 'launchctl unload' --repo "$BIND_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an uninstall whose unload failed while launchd still holds the job must refuse, not report success (out: $stuck_out)"
assert_match 'still reports that job as loaded' "$stuck_out" \
  "and says why it refused -- the unload failed AND the agent is still there, which are two facts, not one"
assert_match 'left exactly as they were' "$stuck_out" \
  "and states that it changed nothing, so the operator is not left guessing how far it got"
assert_match 'unload it by hand' "$stuck_out" "and names the hand step that unblocks it"
assert_match 'service uninstall --repo' "$stuck_out" "and the uninstall to re-run afterwards"
[ -f "$bind_plist" ] \
  || fail "a refused uninstall must NOT remove the plist: it is the only path anything can unload that still-loaded agent by"
[ -f "$bind_rec" ] \
  || fail "and must NOT clear the repo-local binding: it is what keeps the removal guard refusing this checkout"
[ -f "$bind_mrec" ] \
  || fail "and must NOT clear the machine-local binding: it is the only thing that could name the schedule once the checkout is gone"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "and the checkout must still be refused for removal -- a failed uninstall that unwedged the guard would be the worst of both"
assert_match 'launchctl list' "$(cat "$SCHED_LOG")" \
  "the refusal is decided by asking launchd whether the job is still there, never by the unload's exit status alone"
red_case "an uninstall whose launchctl unload failed leaves the schedule nameable and the checkout guarded"

# GREEN, and the reason the unload's exit status alone could not have decided
# it: an unload of a plist that was never loaded fails too. `install` writes the
# plist before loading it, so anything failing in between leaves one -- an
# ordinary state uninstall must still clear. Here BOTH stubbed calls fail, and
# the `list` fails with launchd's own "no such job" status, so the removals
# proceed. K11 is this same line with the other kind of failure.
rc=0
never_out="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "an unload that failed because nothing was ever loaded still clears the records (out: $never_out)"
assert_match 'is now safe to remove' "$never_out" \
  "and reaches the same conclusion an ordinary uninstall does"
[ -f "$bind_plist" ] && fail "the plist must be gone: launchd holds no job that needed it"
[ -f "$bind_rec" ] && fail "and so must the repo-local binding"
[ -f "$bind_mrec" ] && fail "and its machine-local copy"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the checkout is removable again"
green_case "a failed unload with no job behind it is the never-loaded case, and still clears the binding"

# -- K8: a missing plist is not an unloaded agent --------------------------
# K6 established that a binding whose plist never landed must stay clearable,
# and the arm serving it read the missing plist as proof that nothing was
# loaded. It is not proof. REMOVING A PLIST UNLOADS NOTHING: launchd holds the
# job it loaded until something unloads it or the machine reboots, so a plist
# deleted by hand -- by an operator tidying ~/Library/LaunchAgents, by a
# restore, by a cleanup script -- leaves a live agent whose ONLY remaining name
# on this machine is the binding record that arm went on to delete.
#
# What that produced is this task's leftover with every trace removed at once:
# an agent still firing on its interval, no plist to unload it by, no record for
# `orchid doctor` to warn from, a removal guard that now waves the checkout
# through -- and `uninstall` reporting success. Worse than K7's, which at least
# leaves a plist behind; here the ONE surviving name is the thing being deleted.
#
# The two states are identical on disk and different to launchd, so launchd is
# asked. Here the stubbed `list` answers "still loaded" (its default), which is
# the dangerous half; K6 above is the same fixture with the other answer.
reinst3_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the missing-plist fixture re-installs a schedule first (out: $reinst3_out)"
[ -f "$bind_plist" ] || fail "fixture: the re-install must have placed the plist"
[ -f "$bind_rec" ] || fail "fixture: the re-install must have written the repo-local binding"
[ -f "$bind_mrec" ] || fail "fixture: the re-install must have written the machine-local binding"
rm -f "$bind_plist"   # deleted by hand -- the agent it loaded is still loaded

rc=0
orphan_loaded="$(svc_uninstall_real --repo "$BIND_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an uninstall whose plist is gone while launchd still holds the job must refuse, not report success (out: $orphan_loaded)"
assert_match 'still reports that job as loaded' "$orphan_loaded" \
  "and refuses for the fact that matters -- launchd holds the job -- not for the missing file"
assert_match 'removing a plist does not unload' "$orphan_loaded" \
  "and says why the absent plist was never evidence of an unloaded agent"
assert_match 'left exactly as it was' "$orphan_loaded" \
  "and states that the one surviving name was not touched"
assert_match 'launchctl remove' "$orphan_loaded" \
  "and names a hand step that can actually reach the job -- an unload by plist path is impossible now"
assert_match 'service uninstall --repo' "$orphan_loaded" "and the uninstall to re-run afterwards"
[ -f "$bind_rec" ] \
  || fail "the repo-local binding must survive: it is what keeps the removal guard refusing this checkout"
[ -f "$bind_mrec" ] \
  || fail "and the machine-local copy must too: with the plist gone it is the only thing left that names the loaded agent at all"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "and the checkout must still be refused for removal -- unwedging the guard here would drop the last trace"
sched_seen="$(cat "$SCHED_LOG")"
assert_match 'launchctl list' "$sched_seen" \
  "the refusal is decided by asking launchd, never by reading the absence of a file as an answer"
# A herestring, never `cat | grep -q`: this suite runs under pipefail, where a
# `grep -q` that exits on its first match can SIGPIPE the producer and hand the
# pipeline a nonzero status on the very input that DID match -- a negative
# assertion built that way passes precisely when it should fire.
grep -q 'launchctl unload' <<<"$sched_seen" \
  && fail "and it must not try to unload a plist that is not there -- that call could only ever fail, and its failure would say nothing about the job"
red_case "an uninstall whose plist is gone while launchd still holds the job keeps the binding that names it"

# GREEN, and the point of refusing rather than clearing: the refusal is a step,
# not a wedge. Once launchd no longer holds the job -- the operator ran the
# named `launchctl remove`, or the machine rebooted -- the SAME command that
# refused clears everything and hands the checkout back.
rc=0
freed_out="$(svc_uninstall_notfound 'launchctl list' --repo "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "once launchd holds no such job, the same uninstall clears the orphaned binding (out: $freed_out)"
assert_match 'clearing the binding record' "$freed_out" \
  "and says what it is doing, rather than reporting an agent it did not unload"
[ -f "$bind_rec" ] && fail "the repo-local binding must be gone once nothing is loaded behind it"
[ -f "$bind_mrec" ] && fail "and so must its machine-local copy"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the checkout is removable again -- the refusal above cost the operator a step, not the verb"
green_case "the missing-plist refusal clears on a re-run once launchd has let the job go"

# -- K9: a recorded binding the guard cannot see --------------------------
# K5 injects its failure at the machine-local store because that is the one
# that fails at the STAGING step, and its own note says why it could not use
# the record's own path: `mv file dir` moves the file INTO the directory and
# exits 0. That is not a reason to leave the case alone -- it is the case.
#
# THE COMBINATION THIS FORBIDS. With a directory sitting where the repo-local
# record belongs, every check the write performs passes: jq produces its temp,
# the machine-local copy stages and commits, and the rename that was supposed
# to place the record deposits it inside the directory and reports success. So
# install goes on to render the plist and hand launchd a schedule that fires on
# its interval -- while orchid_service_bound, whose entire test is `[ -f ]`,
# says NO for that checkout, and so the removal guard waves it through. That is
# this task's finding rebuilt from the inside: a live agent, and every path in
# the kernel that removes a worktree cheerfully deleting the directory it wakes
# against. Worse than an unrecorded install, because `install` reported success
# and the machine-local copy says a binding exists.
#
# So the pairing is asserted, not the mechanism: an install that cannot leave a
# record the guard can SEE must install no schedule at all.
mkdir -p "$bind_rec" \
  || fail "fixture: could not put a directory where the repo-local record belongs"
rc=0
obstructed_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an install whose record path is obstructed must refuse: it cannot report a binding that orchid_service_bound will not see (out: $obstructed_out)"
assert_match 'could not record the service binding' "$obstructed_out" \
  "and refuses on the binding, the same way K5's install does -- the obstruction is a failure to record, not a scheduler problem"
assert_match '/\.orchid/runtime/service\.json is not a regular file' "$obstructed_out" \
  "and names the obstructed path: the refusal above names the repo and the obligation, and an operator cannot see inside .orchid/runtime/ from that alone"
[ -f "$bind_plist" ] \
  && fail "and no plist may be placed: the record is written BEFORE the scheduler is touched precisely so this failure schedules nothing"
[ -f "$bind_mrec" ] \
  && fail "and no machine-local copy either -- a copy claiming a binding whose repo-local half is invisible is the leftover doctor would report and the guard would not enforce"
rmdir "$bind_rec" \
  || fail "the obstruction must be left EMPTY: a write that had staged its record first would have deposited it INSIDE the directory, which is exactly the rename that silently succeeds"

# The invariant itself, at the library boundary rather than through the verb:
# a 0 from the writer is a promise about what the READERS will say. Asserted
# here as well because every caller acts on that return value alone -- the
# service runner installs a schedule on it -- and a writer that returns 0 while
# orchid_service_bound returns false makes the guard blind for every one of
# them at once, not only for `service install`.
mkdir -p "$bind_rec" || fail "fixture: could not re-obstruct the record path"
rc=0
write_out="$(orchid_service_binding_write "$BIND_REPO" "$bind_label" darwin "/nonexistent.plist" 240 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "orchid_service_binding_write must fail closed on a non-regular record path, not report a binding no reader can find"
assert_match 'invisible to every removal guard' "$write_out" \
  "and says why, in the terms that matter -- the record is refused for what the READERS would make of it, not for a filesystem error"
orchid_service_bound "$BIND_REPO" \
  && fail "fixture check: orchid_service_bound must indeed be false here -- if it were true the writer's 0 would have been honest and this case would prove nothing"
rmdir "$bind_rec" || fail "and the failed write must have left nothing behind in the obstruction"
red_case "an install that cannot leave a record the removal guard can see installs no schedule"

# GREEN: with the obstruction gone the same install records a binding the guard
# actually reads, and the checkout is refused for removal while it stands. The
# two halves together are the property: bound-and-refused, or unbound-and-
# unscheduled, and never a schedule on one side of the guard's answer.
rc=0
clear_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)" || rc=$?
assert_eq 0 "$rc" "the same install succeeds once the record path is a place a record can go (out: $clear_out)"
[ -f "$bind_plist" ] \
  || fail "fixture check: this arm must really have placed a schedule -- with no plist there is no live agent for the guard below to be protecting, and the assertion would prove nothing"
[ -f "$bind_rec" ] || fail "and the record is a regular file -- the thing orchid_service_bound tests for"
orchid_service_bound "$BIND_REPO" \
  || fail "so the predicate every removal path consults says the checkout is bound"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "and the checkout carrying that live schedule is refused for removal"
green_case "a schedule installed over a usable record path is one the removal guard can still refuse"
# Hand the fixture back in the state K9 found it: the green arm above really
# installed a schedule, and a binding left standing here would be a leftover of
# exactly the kind this section is about. `launchctl list` answers "no such job"
# because nothing was ever loaded under the stub, which is the never-loaded
# answer uninstall needs (see K6's note).
svc_uninstall_notfound 'launchctl list' --repo "$BIND_REPO" >/dev/null 2>&1

# -- K10: the SAME obstruction at the machine-local destination -------------
# K9 proves the rule at the repo-local record. It is the same rule at the other
# half, because `mv file dir` is the same syscall at $bind_mrec -- and the half
# it protects is the one that matters AFTER the checkout is gone. With a
# directory sitting where the machine-local record belongs, staging succeeds
# (the temp is a sibling path, not the record), the commit rename deposits the
# file INSIDE and exits 0, and install reports success. What is then true: a
# launchd agent firing on its interval, and the only copy of the binding that
# outlives the worktree is not a file orchid_service_bindings will walk. So
# `orchid doctor` reports no binding, `orchid service uninstall` has no label to
# take, and once the operator removes the checkout the schedule has no name
# anywhere on the machine. That IS this task's original finding, rebuilt through
# the half K9 does not cover.
#
# Fixture check first: K9's cleanup must really have left this unbound, or the
# install below would be a re-install and prove something else.
[ -f "$bind_rec" ] \
  && fail "fixture: K9's cleanup must have left the binding fixture unbound before K10 obstructs the machine-local half"
mkdir -p "$bind_mrec" \
  || fail "fixture: could not put a directory where the machine-local record belongs"
mobstructed_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] \
  || fail "an install whose MACHINE-LOCAL record path is obstructed must refuse: it cannot report a binding that survives the checkout (out: $mobstructed_out)"
assert_match 'could not record the service binding' "$mobstructed_out" \
  "and refuses on the binding, exactly as the repo-local obstruction does -- neither half is best-effort"
assert_match '/\.orchid/services/.*\.json is not a regular file' "$mobstructed_out" \
  "and names the obstructed machine-local path: an operator cannot see inside ~/.orchid/services/ from a refusal that names only the repo"
grep -qF "$bind_mrec" <<<"$mobstructed_out" \
  || fail "and names it EXACTLY -- the store holds one record per label, and a refusal pointing at the wrong one sends the operator to a file that is fine (out: $mobstructed_out)"
assert_match 'could not name this schedule once the checkout is gone' "$mobstructed_out" \
  "and says why in the reader's terms -- what is lost is the copy that outlives the worktree, not a filesystem detail"
[ -f "$bind_plist" ] \
  && fail "and no plist may be placed: the binding is written BEFORE the scheduler is touched precisely so this failure schedules nothing"
[ -f "$bind_rec" ] \
  && fail "and no repo-local half either -- the machine-local obstruction is refused before the first byte, so this failure leaves nothing at all behind"
orchid_service_machine_bound "$bind_label" \
  && fail "fixture check: orchid_service_machine_bound must indeed be false here -- if it were true the writer's 0 would have been honest and this case would prove nothing"

# The invariant at the library boundary, the twin of K9's: every caller acts on
# this return value alone, and a 0 here is a promise about BOTH readers.
rc=0
mwrite_out="$(orchid_service_binding_write "$BIND_REPO" "$bind_label" darwin "/nonexistent.plist" 240 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "orchid_service_binding_write must fail closed on a non-regular machine-local record path, not report a binding no reader can find (out: $mwrite_out)"
orchid_service_machine_bound "$bind_label" \
  && fail "and it must not have produced a machine-local record the readers can see -- the obstruction is still there"
[ -f "$bind_rec" ] \
  && fail "and it must leave NO residue on the other side either: this half is refused before the first byte, so an unsafe repo-local record cannot be what a failed write hands back"
rmdir "$bind_mrec" \
  || fail "and the failed write must have left nothing behind in the obstruction: a write that had staged into it first would have deposited its record INSIDE, which is exactly the rename that silently succeeds"
red_case "an install that cannot leave a record surviving its checkout installs no schedule"

# GREEN: with the obstruction gone the same install records a binding that the
# machine-local walk -- the one thing left naming a schedule after the worktree
# is deleted -- actually reports. Bound-and-nameable, or unbound-and-
# unscheduled, and never a schedule that no walk can find.
rc=0
mclear_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)" || rc=$?
assert_eq 0 "$rc" "the same install succeeds once the machine-local record path is a place a record can go (out: $mclear_out)"
[ -f "$bind_plist" ] \
  || fail "fixture check: this arm must really have placed a schedule -- with no plist there is no live agent for the binding below to be naming"
orchid_service_machine_bound "$bind_label" \
  || fail "and the machine-local half is a regular file -- what orchid_service_bindings tests before it walks an entry"
assert_eq "$bind_label" "$(orchid_service_binding_label_for "$BIND_CANON")" \
  "so the walk that survives the checkout can still name this schedule's label -- which is what uninstall and doctor need once the repo is gone"
green_case "a schedule installed over a usable machine-local path is one that can still be named after its checkout"
# Hand the fixture back unbound, exactly as K9 does.
svc_uninstall_notfound 'launchctl list' --repo "$BIND_REPO" >/dev/null 2>&1

# -- K11: an unanswered launchd query is not an absence --------------------
# K7 and K8 both end at the same question -- does launchd still hold this job --
# and both used to read the answer as a boolean. `launchctl list` is not a
# boolean. It exits nonzero for launchd's own "no job by that name" (status 113,
# `Could not find service`) AND for every way of failing to ask at all:
# launchctl missing from PATH, denied, unable to reach the user's launchd
# session, killed. The first is an answer; the second is silence.
#
# Collapsed together, silence clears. That is K7's and K8's own finding rebuilt
# through the query instead of through the artifact: a launchctl that cannot
# answer on a machine whose agent is very much still loaded takes the plist and
# both binding records with it, unwedges the removal guard, and reports success
# -- a schedule still firing with no name anywhere. So the two are staged here
# as twins: the SAME uninstall, the SAME stubbed call, differing only in what
# launchctl returned.
reinst4_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the indeterminate-query fixture re-installs a schedule first (out: $reinst4_out)"
[ -f "$bind_plist" ] || fail "fixture: the re-install must have placed the plist"
[ -f "$bind_rec" ] || fail "fixture: the re-install must have written the repo-local binding"
[ -f "$bind_mrec" ] || fail "fixture: the re-install must have written the machine-local binding"

# RED, the unload path: the unload failed and the `list` after it failed too --
# but with an ordinary error, not an answer. K7's green arm is this same command
# line; the only difference is the status launchctl handed back.
rc=0
indet_out="$(svc_uninstall_failing 'launchctl (unload|list)' --repo "$BIND_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an uninstall whose launchd query never answered must refuse, not treat silence as an absence (out: $indet_out)"
assert_match 'could not be asked whether it still holds that job' "$indet_out" \
  "and says exactly which fact is missing -- not that the job is gone, and not that it is there"
assert_match 'an unanswered query is not an absence' "$indet_out" \
  "and states the rule it is applying, so the refusal is not mistaken for the loaded one"
# A herestring, never `echo | grep -q`: under pipefail a `grep -q` that exits on
# its first match can SIGPIPE the producer, so a negative assertion built that
# way passes precisely when it should fire.
grep -q 'still reports that job as loaded' <<<"$indet_out" \
  && fail "and must NOT claim launchd reported the job -- launchd reported nothing at all, and a refusal that overstates its evidence sends the operator to a launchctl remove that will not apply"
assert_match 'launchctl list .* exited 1: Operation not permitted' "$indet_out" \
  "and names the launchctl failure whole -- the query, its status and what it printed. Pinned as ONE line on purpose: the unload's own error is printed just above, and an operator who cannot tell the two calls apart cannot act on either"
assert_match 'ask launchd yourself' "$indet_out" "and names the step that resolves the unknown"
assert_match 'service uninstall --repo' "$indet_out" "and the uninstall to re-run afterwards"
[ -f "$bind_plist" ] \
  || fail "a refused uninstall must NOT remove the plist: nothing established that the agent it loaded is gone"
[ -f "$bind_rec" ] \
  || fail "and must NOT clear the repo-local binding: it is what keeps the removal guard refusing this checkout"
[ -f "$bind_mrec" ] \
  || fail "and must NOT clear the machine-local binding: it is the only thing that could name the schedule once the checkout is gone"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "and the checkout must still be refused for removal -- an unanswered query that unwedged the guard is the leftover this section exists to prevent"
assert_match 'launchctl list' "$(cat "$SCHED_LOG")" \
  "the refusal is still decided by asking launchd -- the point is what happened to the question, not that it was skipped"
red_case "an uninstall whose launchd query could not answer keeps the schedule nameable and the checkout guarded"

# GREEN twin: the same fixture, the same command, the same two stubbed calls --
# and this time the `list` fails with launchd's own "no such job" status. That
# IS an answer, so the removals proceed.
rc=0
answered_out="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "the identical uninstall clears once the same call returns launchd's answer instead of an error (out: $answered_out)"
assert_match 'is now safe to remove' "$answered_out" "and reaches the ordinary conclusion"
[ -f "$bind_plist" ] && fail "the plist must be gone: launchd answered that it holds no job that needed it"
[ -f "$bind_rec" ] && fail "and so must the repo-local binding"
[ -f "$bind_mrec" ] && fail "and its machine-local copy"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the checkout is removable again"
green_case "a launchd query that answers 'no such job' still clears, so the refusal above is the failure and not the question"

# RED, the orphan path: the same distinction where there is no unload to try.
# K8 asks launchd because a missing plist proves nothing about a loaded agent;
# if that question comes back unanswered, the binding record being cleared is
# still the only name a live agent has.
reinst5_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the orphan-path indeterminate fixture re-installs a schedule first (out: $reinst5_out)"
[ -f "$bind_plist" ] || fail "fixture: the re-install must have placed the plist"
rm -f "$bind_plist"   # deleted by hand, exactly as in K8
rc=0
orphan_indet="$(svc_uninstall_failing 'launchctl list' --repo "$BIND_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an uninstall whose plist is gone and whose launchd query never answered must refuse (out: $orphan_indet)"
assert_match 'its plist is already gone and launchd could not be asked' "$orphan_indet" \
  "and names both halves of what it does not know: the file is gone, and the job's state was never established"
assert_match 'an unanswered query is not an absence' "$orphan_indet" \
  "and applies the same rule the unload path does -- one collapse, one fix, both doors"
assert_match 'launchctl list .* exited 1: Operation not permitted' "$orphan_indet" \
  "and names the launchctl failure here too -- this arm runs no unload at all, so this line is the only account of what went wrong"
[ -f "$bind_rec" ] \
  || fail "the repo-local binding must survive: it is what keeps the removal guard refusing this checkout"
[ -f "$bind_mrec" ] \
  || fail "and the machine-local copy must too: with the plist gone it is the only thing that could name the agent at all"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "and the checkout must still be refused for removal"
red_case "an uninstall whose plist is gone keeps the binding when launchd could not be asked about the job"

# GREEN twin: nothing about the fixture changes except the answer.
rc=0
orphan_answered="$(svc_uninstall_notfound 'launchctl list' --repo "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "the identical uninstall clears the orphaned binding once launchd answers (out: $orphan_answered)"
assert_match 'clearing the binding record' "$orphan_answered" "and says what it is doing"
[ -f "$bind_rec" ] && fail "the repo-local binding must be gone"
[ -f "$bind_mrec" ] && fail "and so must its machine-local copy"
green_case "the unanswered-query refusal clears on a re-run once launchd answers"

# The second signature of the SAME answer. `Could not find service` is what
# launchctl prints when it holds no such job, and a launchctl generation that
# reports that with a plain exit 1 is still ANSWERING -- reading only the status
# would turn the ordinary never-loaded state into a permanent refusal, which is
# a wedge rather than a step (K6's own point). Staged with status 1 precisely so
# it cannot pass through the 113 rule the arms above prove.
reinst6_out="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the not-found-sentence fixture re-installs a schedule first (out: $reinst6_out)"
rm -f "$bind_plist"
rc=0
sentence_out="$(svc_uninstall_stub 'launchctl list' 1 'Could not find service "com.orchid.pump" in domain for uid: 501' --repo "$BIND_REPO" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "launchd's own not-found sentence is an answer even when the status is a plain 1 (out: $sentence_out)"
assert_match 'clearing the binding record' "$sentence_out" "and the binding it left behind is cleared"
[ -f "$bind_rec" ] && fail "the repo-local binding must be gone -- launchd said it holds no such job"
[ -f "$bind_mrec" ] && fail "and so must its machine-local copy"
rc=0
orchid_service_removal_guard "$BIND_REPO" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the checkout is removable again -- a definitive absence is definitive however launchctl spells it"
green_case "launchd's not-found sentence clears the binding even when its exit status is an ordinary 1"

# The linux/cron branch keeps its own binding record too -- the record is not
# a launchd-only affordance, and the cron record it points at lives inside the
# checkout, which is exactly the copy a removal destroys.
export ORCHID_SERVICE_OS=Linux
LBIND="$BIND/linux-repo"
mkdir -p "$LBIND"
(
  cd "$LBIND" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
)
trust_repo "$LBIND"
lbind_out="$("$SERVICE" install --repo "$LBIND" --interval-s 300 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "linux install exits 0 for the binding fixture (out: $lbind_out)"
lbind_label="$(echo "$lbind_out" | grep -oE "$label_re" | head -n1)"
assert_eq linux "$(jq -r '.platform' "$LBIND/.orchid/runtime/service.json")" \
  "the cron branch records its own platform"
[ -f "$HOME/.orchid/services/$lbind_label.json" ] \
  || fail "the cron branch must write the machine-local binding too"
rc=0
lguard="$(orchid_service_removal_guard "$LBIND" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a cron-scheduled checkout is no more removable than a launchd-scheduled one"
svc_uninstall_real --repo "$LBIND" >/dev/null 2>&1
[ -f "$LBIND/.orchid/runtime/service.json" ] \
  && fail "linux uninstall must remove the binding record it wrote"
unset ORCHID_SERVICE_OS

# -- K12: the teardown is ONE conditional operation ------------------------
# EVERY REFUSAL K7/K8/K11 PROVE WAS UNENFORCEABLE, and that is what this
# section is about. The ordering was documented everywhere -- this file's own
# usage text, `install`, `status`, the pump, `orchid doctor` -- as a PAIR of
# commands: uninstall first, `git worktree remove` second. A pair of commands
# is run as a pair of commands. So an uninstall that refused because launchd
# still held the job printed its refusal, and the operator's second line
# removed the worktree anyway, taking the checkout, the repo-local binding
# inside it and the last path anything had to the still-loaded agent. The
# refusals were advisory against exactly the hazard they exist for.
#
# `orchid service teardown` makes the removal the SUCCESS BRANCH of the
# uninstall instead. This proves it in both directions against ONE fixture --
# a real linked worktree, a real schedule bound to it -- with the twins
# differing only in what the stubbed `launchctl list` answered, which is the
# same axis K7/K8/K11 turn on.
export ORCHID_SERVICE_OS=Darwin
svc_teardown_failing() {   # the query never answered -- nothing is known
  local fail_re="$1"; shift
  svc_stub_subverb teardown "$fail_re" 1 'Operation not permitted' "$@"
}
svc_teardown_notfound() {  # launchd ANSWERS that it holds no such job
  local fail_re="$1"; shift
  svc_stub_subverb teardown "$fail_re" 113 '' "$@"
}

TD_MAIN="$BIND/td-main"
mkdir -p "$TD_MAIN"
(
  cd "$TD_MAIN" || exit 1
  git init -q .
  # runtime/ gitignored and .orchid/ committed, exactly as a real integration
  # branch carries them -- so the worktree git sees is CLEAN and the green arm
  # exercises a plain `git worktree remove`, not a --force that would mask a
  # removal git had refused.
  printf '.orchid/runtime/\n' > .gitignore
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: complete\nrun_id: r-td\n---\n# Roadmap\n' > .orchid/roadmap.md
  git add .gitignore .orchid
  git commit -q -m root
  git worktree add -q -b td-integration ../td-wt
) || fail "K12 fixture: could not build a main checkout with a linked integration worktree"
[ -d "$BIND/td-wt" ] || fail "K12 fixture: the linked worktree was not created"
TD_WT="$(cd "$BIND/td-wt" && pwd -P)"
trust_repo "$TD_WT"

# The composer first, because every surface that names a teardown reads it, and
# what it names has to depend on whether there is a worktree to remove at all.
td_cmd="$(orchid_service_teardown_command "$TD_WT")"
assert_match 'orchid service teardown --repo' "$td_cmd" \
  "a linked worktree is told the one command whose second half cannot run without its first"
td_plain="$(orchid_service_teardown_command "$BIND_REPO")"
assert_match 'orchid service uninstall --repo' "$td_plain" \
  "an ordinary checkout is told the uninstall, which is the whole of what orchid is owed there"
# A herestring, never `printf ... | grep -q && fail`: a pipeline whose reader
# exits at its first match can hand back a signal status on exactly the input
# that MATCHED, so the negative would pass while the thing it forbids is there.
grep -qF 'teardown' <<<"$td_plain" \
  && fail "a main checkout must NOT be told to run 'teardown' -- 'git worktree remove' has nothing to take there, so the verb would refuse"

td_inst="$("$SERVICE" install --repo "$TD_WT" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the teardown fixture installs a schedule against the worktree first (out: $td_inst)"
td_label="$(echo "$td_inst" | grep -oE "$label_re" | head -n1)"
td_plist="$HOME/Library/LaunchAgents/$td_label.plist"
td_rec="$TD_WT/.orchid/runtime/service.json"
td_mrec="$HOME/.orchid/services/$td_label.json"
[ -f "$td_plist" ] || fail "K12 fixture: the install must have placed the plist"
[ -f "$td_rec" ] || fail "K12 fixture: the install must have written the repo-local binding"
[ -f "$td_mrec" ] || fail "K12 fixture: the install must have written the machine-local binding"
assert_match 'service teardown --repo' "$td_inst" \
  "and install names THAT command for a worktree, not an ordering to remember"

# --dry-run holds BOTH halves. A preview that removed the worktree while only
# PRINTING the launchctl call would perform the reversed ordering under the one
# flag an operator runs precisely to avoid consequences.
td_dry="$("$SERVICE" teardown --repo "$TD_WT" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "teardown --dry-run exits 0 (out: $td_dry)"
assert_match 'DRY-RUN: git -C .* worktree remove' "$td_dry" \
  "and prints the removal it would run, verbatim"
assert_match 'was NOT removed' "$td_dry" "and says plainly that it removed nothing"
[ -d "$TD_WT" ] || fail "a dry-run teardown must not remove the worktree"
[ -f "$td_plist" ] || fail "nor the plist"
[ -f "$td_rec" ] || fail "nor the binding it would need to name the schedule again"

# RED: the uninstall half refuses -- `launchctl unload` failed and the `list`
# after it never answered, so nothing is known about whether the agent is still
# loaded. This is K11's red arm reached through the OTHER door, and the thing
# being proved is what comes after it: no removal.
rc=0
td_red="$(svc_teardown_failing 'launchctl (unload|list)' --repo "$TD_WT" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a teardown whose uninstall could not prove the scheduler stopped must exit nonzero (out: $td_red)"
assert_match 'launchd could not be asked' "$td_red" \
  "and refuses for the uninstall's own reason, not a new one"
assert_match 'left exactly as they were' "$td_red" "and states that it changed nothing"
assert_match 'then re-run: launchctl list .* && orchid service teardown --repo' "$td_red" \
  "and names THIS command as the re-run -- told to re-run the uninstall alone, the operator ends the schedule and is handed back the worktree, which is the two-step ordering again"
[ -d "$TD_WT" ] \
  || fail "THE FINDING: a refused uninstall must never reach 'git worktree remove' -- the checkout carries the binding record and is what the still-loaded agent points at"
[ -f "$td_plist" ] || fail "and the plist must survive: it is the only path an unload can name that agent by"
[ -f "$td_rec" ] || fail "and the repo-local binding, which is what keeps the removal guard refusing"
[ -f "$td_mrec" ] || fail "and the machine-local copy, the only name that would outlive the checkout"
td_wt_list="$(git -C "$TD_MAIN" worktree list 2>&1)"
assert_match 'td-wt' "$td_wt_list" "and git still has the worktree registered"
rc=0
orchid_service_removal_guard "$TD_WT" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "and the checkout is still guarded against removal"
red_case "a teardown whose uninstall could not prove the scheduler stopped removes neither the schedule nor the worktree"

# GREEN twin: the SAME command against the SAME fixture, differing only in what
# launchctl answered. K7's green arm established that a failed unload with
# launchd answering "no such job" is the ordinary never-loaded case; here that
# answer carries the removal through.
rc=0
td_green="$(svc_teardown_notfound 'launchctl (unload|list)' --repo "$TD_WT" 2>&1)" || rc=$?
assert_eq 0 "$rc" "the identical teardown succeeds once launchd answers that it holds no such job (out: $td_green)"
assert_match 'is now safe to remove' "$td_green" "and the uninstall half reaches its ordinary conclusion"
assert_match 'removed the integration worktree' "$td_green" "and the removal half then runs"
[ -d "$TD_WT" ] && fail "the worktree must be gone -- otherwise the red arm proves only that this verb never removes anything"
[ -f "$td_plist" ] && fail "and the plist"
[ -f "$td_mrec" ] && fail "and the machine-local binding"
td_wt_list2="$(git -C "$TD_MAIN" worktree list 2>&1)"
grep -qF 'td-wt' <<<"$td_wt_list2" \
  && fail "and git must no longer have the worktree registered"
green_case "the same teardown removes the worktree once the uninstall proved the schedule was gone"

# -- K12b: the ONE mid-state this verb can leave, and the recovery it names --
# The refusals proved above all fire having done nothing. Exactly one failure
# fires with the uninstall ALREADY SUCCEEDED: git declines a worktree it
# considers unclean, and by then the schedule is gone. The ordering is satisfied
# there -- nothing is waking at this path any more -- but git's own message says
# nothing about a schedule, so an operator reading it cannot tell whether the
# half that mattered ran. And the obvious recovery, re-running the command that
# failed, reports `no service installed` and removes nothing, because the
# uninstall half is done. So the verb has to say both halves itself.
TD_WT2="$BIND/td-wt2"
(
  cd "$TD_MAIN" || exit 1
  git worktree add -q -b td-integration2 ../td-wt2
) || fail "K12b fixture: could not add a second linked worktree"
[ -d "$TD_WT2" ] || fail "K12b fixture: the second linked worktree was not created"
TD_WT2="$(cd "$TD_WT2" && pwd -P)"
trust_repo "$TD_WT2"
td2_inst="$("$SERVICE" install --repo "$TD_WT2" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the unclean-worktree fixture installs a schedule first (out: $td2_inst)"
td2_label="$(echo "$td2_inst" | grep -oE "$label_re" | head -n1)"
td2_plist="$HOME/Library/LaunchAgents/$td2_label.plist"
td2_mrec="$HOME/.orchid/services/$td2_label.json"
[ -f "$td2_plist" ] || fail "K12b fixture: the install must have placed the plist"
[ -f "$td2_mrec" ] || fail "K12b fixture: the install must have written the machine-local binding"
# A TRACKED file modified, which is what `git worktree remove` refuses over.
# Not an IGNORED one: `.orchid/runtime/` is ignored here precisely so the green
# arm above exercised a plain removal, and adding a file there would have proved
# nothing -- git's cleanliness check does not see ignored paths.
printf '.orchid/runtime/\n# dirty\n' > "$TD_WT2/.gitignore"
rc=0
td2_out="$(svc_teardown_notfound 'launchctl (unload|list)' --repo "$TD_WT2" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a teardown whose removal half failed must exit nonzero (out: $td2_out)"
[ -d "$TD_WT2" ] || fail "K12b fixture: git was supposed to REFUSE this worktree, not remove it"
assert_match 'is uninstalled' "$td2_out" \
  "THE FINDING: the one failure that fires AFTER a successful uninstall must say the schedule is gone -- git's own message names no schedule, so the operator cannot otherwise tell which half ran"
assert_match 'it will not fire again' "$td2_out" \
  "and say it in the terms the ordering is about: nothing is waking against this path"
assert_match 'do NOT re-run teardown' "$td2_out" \
  "and steer off the obvious recovery, which reports 'no service installed' and removes nothing"
assert_match 'worktree remove [-]-force' "$td2_out" \
  "and name the command that finishes the job by hand"
[ -f "$td2_plist" ] && fail "the uninstall half really did complete: no plist survives"
[ -f "$td2_mrec" ] && fail "nor the machine-local binding"
[ -f "$TD_WT2/.orchid/runtime/service.json" ] \
  && fail "nor the repo-local binding, still reachable because the checkout is still standing"
rc=0
orchid_service_removal_guard "$TD_WT2" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" \
  "and the checkout is no longer guarded -- the guard exists to hold a LIVE schedule, and there is none"
red_case "a teardown whose worktree removal failed names the schedule it did end and the removal still owed"
git -C "$TD_MAIN" worktree remove --force "$TD_WT2" >/dev/null 2>&1 || true

# The refusal that belongs to the REMOVAL half is asked FIRST, with the schedule
# still installed. A teardown that uninstalled and only then discovered it had
# nothing to remove would leave the operator in the one state neither command
# names: no schedule, a checkout still standing, and a verb reporting failure.
td_reinst="$("$SERVICE" install --repo "$BIND_REPO" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the not-a-worktree fixture re-installs a schedule first (out: $td_reinst)"
[ -f "$bind_rec" ] || fail "K12 fixture: the re-install must have written the repo-local binding"
rc=0
td_notwt="$(svc_teardown_failing 'launchctl' --repo "$BIND_REPO" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "teardown must refuse a checkout that is not a linked worktree (out: $td_notwt)"
assert_match 'not a linked worktree' "$td_notwt" "and says why"
assert_match 'nothing was uninstalled and nothing was removed' "$td_notwt" \
  "and states that the schedule is untouched, so the operator knows what is still owed"
assert_match 'service uninstall --repo' "$td_notwt" "and names the half that does apply there"
[ -f "$bind_rec" ] \
  || fail "the binding must be untouched: this refusal is asked BEFORE the uninstall, not after it"
[ -s "$SCHED_LOG" ] \
  && fail "and no scheduler call may have been made at all -- that is what 'before the uninstall' means"
red_case "teardown refuses a non-worktree checkout before uninstalling anything, naming the uninstall instead"

# -- K13: the schedule a removal acts on is the one INSTALL RECORDED --------
# `install` derives its label by hashing the canonical repo path, and every
# removing arm above used to re-derive it the same way. That is the same
# schedule only while the checkout stays where it is, and `git worktree move`
# is the ordinary way it stops being: the repo-local binding travels INSIDE the
# worktree, the machine-local copy never moves at all, and the path they were
# hashed from is now nobody's. Re-hashed, `uninstall` asked about a label that
# was never installed -- it found no plist and no binding, reported `no service
# installed`, and left a launchd agent firing every interval with both its
# records on disk and no verb able to name them. That is this task's own
# leftover, reached through a rename instead of a deletion.
MV_MAIN="$BIND/mv-main"
mkdir -p "$MV_MAIN"
(
  cd "$MV_MAIN" || exit 1
  git init -q .
  # Same shape as K12's fixture, and for the same reason: runtime/ ignored and
  # .orchid/ committed, so the worktree git sees is CLEAN and the green arm
  # exercises a plain `git worktree remove` rather than a --force that would
  # mask a removal git had refused.
  printf '.orchid/runtime/\n' > .gitignore
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: complete\nrun_id: r-mv\n---\n# Roadmap\n' > .orchid/roadmap.md
  git add .gitignore .orchid
  git commit -q -m root
  git worktree add -q -b mv-integration ../mv-wt
) || fail "K13 fixture: could not build a main checkout with a linked integration worktree"
[ -d "$BIND/mv-wt" ] || fail "K13 fixture: the linked worktree was not created"
MV_WT="$(cd "$BIND/mv-wt" && pwd -P)"
trust_repo "$MV_WT"

mv_inst="$("$SERVICE" install --repo "$MV_WT" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the moved-worktree fixture installs a schedule at the ORIGINAL path first (out: $mv_inst)"
mv_label="$(echo "$mv_inst" | grep -oE "$label_re" | head -n1)"
mv_plist="$HOME/Library/LaunchAgents/$mv_label.plist"
mv_mrec="$HOME/.orchid/services/$mv_label.json"
[ -f "$mv_plist" ] || fail "K13 fixture: the install must have placed the plist"
[ -f "$mv_mrec" ] || fail "K13 fixture: the install must have written the machine-local binding"

# THE MOVE, through git's own verb -- the thing an operator actually does, not
# a hand-built approximation of its result.
git -C "$MV_MAIN" worktree move "$MV_WT" "$BIND/mv-wt-moved" \
  || fail "K13 fixture: 'git worktree move' failed, so nothing below is about a moved worktree"
MV_NEW="$(cd "$BIND/mv-wt-moved" && pwd -P)"
mv_rec="$MV_NEW/.orchid/runtime/service.json"
[ -f "$mv_rec" ] \
  || fail "K13 fixture: the repo-local binding must have travelled inside the checkout, or the move took the very record this section is about"
[ ! -e "$MV_WT" ] || fail "K13 fixture: the original path must be gone, or the checkout was copied rather than moved"

# THE WITNESS THAT MAKES EVERY ASSERTION BELOW NON-VACUOUS: both records still
# name the path the schedule was installed against, and that is not where this
# checkout is any more -- so a label hashed from the CURRENT path cannot be the
# one the schedule was installed under.
assert_eq "$MV_WT" "$(jq -r '.repo' "$mv_rec")" \
  "the binding still names the path it was installed against, which the checkout has left"
assert_eq "$MV_WT" "$(jq -r '.repo' "$mv_mrec")" \
  "and so does the machine-local copy, which never moved at all"

# The resolution itself, at the library boundary, before any verb is asked to
# act on it -- the same place K9/K10 pin the write-side invariant.
rc=0
orchid_service_identity "$MV_NEW" || rc=$?
assert_eq 0 "$rc" \
  "the twins must resolve for a moved checkout: they were written from one staged file and the move touched neither"
assert_eq "$mv_label" "$ORCHID_SERVICE_ID_LABEL" \
  "and resolve to the label INSTALL created, never to a hash of the path the checkout now sits at"
assert_eq twins "$ORCHID_SERVICE_ID_SOURCE" \
  "from BOTH halves -- the machine-local copy is found by LABEL, since finding it by path is the same mistake one indirection further along"
# And the move is OWNED, which is the half K14 turns on: `git worktree move`
# re-registers the checkout at its new path, so the ownership proof the copied-
# checkout refusal rests on must pass here or a legitimate move is refused.
assert_eq "$MV_NEW" "$(orchid_checkout_registered_path "$MV_NEW")" \
  "and git's own registration now names the moved path, which is what distinguishes a move from a copy"
rc=0
orchid_service_binding_owned "$MV_NEW" "$ORCHID_SERVICE_ID_REPO" || rc=$?
assert_eq 0 "$rc" \
  "so a MOVED checkout owns the binding whose record still names where it used to be"

# RED: twins that DISAGREE are refused rather than guessed at. A record edited
# by hand, or a checkout COPIED rather than moved, would otherwise have this
# unload an agent belonging to a different checkout -- or clear the last name
# the one here has.
cp "$mv_mrec" "$mv_mrec.keep" || fail "K13 fixture: could not stash the machine-local twin"
jq '.repo = "/somewhere/else"' "$mv_mrec.keep" > "$mv_mrec" \
  || fail "K13 fixture: could not stage a tampered machine-local twin"
rc=0
mv_tamper="$(svc_teardown_notfound 'launchctl (unload|list)' --repo "$MV_NEW" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a teardown whose two binding records disagree must refuse, not pick one of them (out: $mv_tamper)"
assert_match 'do not name the same schedule' "$mv_tamper" \
  "and says which fact stopped it -- the launchd answer here is the one that CLEARS, so this cannot be some other refusal"
assert_match 'reconcile or delete the wrong record' "$mv_tamper" "and names the step that resolves it"
[ -d "$MV_NEW" ] || fail "and it removes nothing: not the worktree"
[ -f "$mv_plist" ] || fail "nor the plist"
[ -f "$mv_rec" ] || fail "nor the repo-local binding"
[ -f "$mv_mrec" ] || fail "nor the machine-local one"
[ -s "$SCHED_LOG" ] \
  && fail "and makes no scheduler call at all -- an identity nothing agrees on is refused before launchd is asked anything about it"
red_case "a teardown whose binding twins disagree about the schedule they name removes nothing and asks the scheduler nothing"
mv "$mv_mrec.keep" "$mv_mrec" || fail "K13 fixture: could not restore the machine-local twin"

# RED: the identity resolves, and every refusal the schedule's own liveness
# earns still holds through the moved path. Pinned by the refusal's TEXT and by
# the label it names, never by its exit status alone: re-hashed, this same
# command also exited nonzero -- with `no service installed`, about a schedule
# that never existed, while the real one kept firing.
rc=0
mv_red="$(svc_teardown_failing 'launchctl (unload|list)' --repo "$MV_NEW" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a teardown whose launchd query never answered must refuse (out: $mv_red)"
assert_match 'launchd could not be asked' "$mv_red" \
  "and it must be the LIVENESS refusal -- 'no service installed' is a different nonzero, about a label the current path hashes to and nothing ever installed"
assert_match "$mv_label" "$mv_red" \
  "and it names the label install created, not one derived from where the checkout was moved to"
[ -d "$MV_NEW" ] || fail "THE FINDING: nothing is removed -- the moved worktree stands"
[ -f "$mv_plist" ] || fail "and the plist, the only path an unload can name that agent by"
[ -f "$mv_rec" ] || fail "and the repo-local binding, which is what keeps the removal guard refusing"
[ -f "$mv_mrec" ] || fail "and its machine-local copy, the only name that would outlive the checkout"
rc=0
orchid_service_removal_guard "$MV_NEW" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "and the moved checkout is still guarded against removal"
red_case "a moved checkout's teardown resolves the schedule install recorded and preserves every refusal that schedule's liveness earns"

# GREEN twin: the same command against the same moved fixture, differing only
# in what launchctl answered. This is the whole of the finding in one line --
# the ORIGINAL schedule ends, both records go, and the checkout at its NEW path
# is removed.
rc=0
mv_green="$(svc_teardown_notfound 'launchctl (unload|list)' --repo "$MV_NEW" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "the identical teardown succeeds once launchd answers that it holds no such job (out: $mv_green)"
assert_match "$mv_label" "$mv_green" "and it is the ORIGINAL schedule it reports having ended"
assert_match 'removed the integration worktree' "$mv_green" "and the removal half then runs"
[ -f "$mv_plist" ] \
  && fail "the plist install created must be gone -- re-hashed, this teardown left it in place and firing"
[ -f "$mv_mrec" ] \
  && fail "and the machine-local binding, which was the last thing on this machine that could name it"
[ -f "$mv_rec" ] && fail "and the repo-local binding went with the checkout"
[ -d "$MV_NEW" ] && fail "and the moved worktree is removed"
mv_wt_list="$(git -C "$MV_MAIN" worktree list 2>&1)"
grep -qF 'mv-wt-moved' <<<"$mv_wt_list" \
  && fail "and git must no longer have the moved worktree registered"
green_case "a teardown of a MOVED worktree ends the schedule install recorded, clears both binding records, and removes the checkout at its new path"

# -- K14: matching records are not ownership -------------------------------
# K13 made every removing arm resolve its schedule from the binding TWINS, and
# proved twins that disagree are refused. Agreement answers "which schedule is
# this"; it cannot answer "may THIS caller end it", and the two are not the same
# question. `cp -R` of a bound checkout copies `.orchid/runtime/service.json`
# with everything else, so the duplicate's repo-local half is byte-identical to
# the machine-local one: the twins agree, the identity resolves to the ORIGINAL
# checkout's label, and a removal run inside the copy unloads the agent the
# original is still driven by, deletes both records, and leaves that checkout
# bound to a schedule nothing on the machine can name. The leftover this whole
# task is about, minted by tearing down a backup.
#
# The distinction is not in the records at all -- it is in git's own worktree
# registration, which `git worktree move` rewrites (K13's green arm) and `cp -R`
# does not. Both are exercised against ONE fixture here so the refusal is
# provably about ownership and not about the tree being broken.
CP_MAIN="$BIND/cp-main"
mkdir -p "$CP_MAIN"
(
  cd "$CP_MAIN" || exit 1
  git init -q .
  # Same shape as K12/K13: runtime/ ignored and .orchid/ committed, so the
  # worktree git sees is CLEAN and the green arm below exercises a plain
  # `git worktree remove` rather than a --force that would mask a refusal.
  printf '.orchid/runtime/\n' > .gitignore
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: complete\nrun_id: r-cp\n---\n# Roadmap\n' > .orchid/roadmap.md
  git add .gitignore .orchid
  git commit -q -m root
  git worktree add -q -b cp-integration ../cp-wt
) || fail "K14 fixture: could not build a main checkout with a linked integration worktree"
[ -d "$BIND/cp-wt" ] || fail "K14 fixture: the linked worktree was not created"
CP_WT="$(cd "$BIND/cp-wt" && pwd -P)"
trust_repo "$CP_WT"

cp_inst="$("$SERVICE" install --repo "$CP_WT" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the copied-checkout fixture installs a schedule against the REAL worktree first (out: $cp_inst)"
cp_label="$(echo "$cp_inst" | grep -oE "$label_re" | head -n1)"
cp_plist="$HOME/Library/LaunchAgents/$cp_label.plist"
cp_rec="$CP_WT/.orchid/runtime/service.json"
cp_mrec="$HOME/.orchid/services/$cp_label.json"
[ -f "$cp_plist" ] || fail "K14 fixture: the install must have placed the plist"
[ -f "$cp_rec" ] || fail "K14 fixture: the install must have written the repo-local binding"
[ -f "$cp_mrec" ] || fail "K14 fixture: the install must have written the machine-local binding"

# THE COPY, made the way anyone makes one -- a plain recursive copy of the
# checkout, which is what a backup, a `cp -R` before a risky rebase, or a
# restored snapshot leaves standing beside the original.
cp -R "$CP_WT" "$BIND/cp-wt-copy" || fail "K14 fixture: could not copy the bound checkout"
CP_COPY="$(cd "$BIND/cp-wt-copy" && pwd -P)"
cp_copy_rec="$CP_COPY/.orchid/runtime/service.json"
[ -f "$cp_copy_rec" ] || fail "K14 fixture: the copy must carry the repo-local binding, or there is nothing here to refuse"

# THE WITNESS THAT MAKES THE REFUSAL BELOW NON-VACUOUS: the copy's record is not
# merely similar, it is the same bytes -- so every test the twins apply passes
# for it, and the identity resolves to the ORIGINAL schedule. Whatever refuses
# the copy cannot be the twins check.
assert_eq "$(cat "$cp_rec")" "$(cat "$cp_copy_rec")" \
  "the copy carries a byte-identical binding record -- which is exactly why matching records cannot be the proof of ownership"
rc=0
orchid_service_identity "$CP_COPY" || rc=$?
assert_eq 0 "$rc" \
  "and the twins RESOLVE for the copy: they were written from one staged file and copying touched neither"
assert_eq "$cp_label" "$ORCHID_SERVICE_ID_LABEL" \
  "resolving to the label the ORIGINAL checkout's schedule was installed under"
assert_eq "$CP_WT" "$ORCHID_SERVICE_ID_REPO" \
  "and naming the checkout it was installed against, which is not this one"

# ...and the fact that DOES tell them apart, read directly. A linked worktree's
# `.git` file names an administrative directory, and that directory's own
# `gitdir` file names the worktree's `.git` file in return. `git worktree move`
# rewrites that back-pointer; `cp -R` cannot, because it never touches the
# original's administrative directory at all -- so asked from INSIDE the copy,
# git's registration still answers with the original.
assert_eq "$CP_WT" "$(orchid_checkout_registered_path "$CP_WT")" \
  "git's own registration names the checkout it was made for"
assert_eq "$CP_WT" "$(orchid_checkout_registered_path "$CP_COPY")" \
  "and still names it when asked from inside the copy -- the copy shares the original's administrative directory and its back-pointer was never rewritten"
rc=0
orchid_service_binding_owned "$CP_COPY" "$ORCHID_SERVICE_ID_REPO" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "the ownership predicate itself must reject the copy -- git's registration still names the original, and nothing else on disk tells the two apart"
rc=0
orchid_service_binding_owned "$CP_WT" "$ORCHID_SERVICE_ID_REPO" || rc=$?
assert_eq 0 "$rc" \
  "and accept the checkout git actually has registered, or the predicate refuses everything and proves nothing"

# RED, through the door that removes most: `teardown` would unload the agent,
# delete both records AND take a worktree. Staged with launchd ANSWERING "no such
# job" -- the answer that CLEARS -- so nothing but ownership can be what stops it.
rc=0
cp_red_td="$(svc_teardown_notfound 'launchctl (unload|list)' --repo "$CP_COPY" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "a teardown run inside a COPY of the bound checkout must refuse (out: $cp_red_td)"
assert_match 'not the checkout that binding was installed against' "$cp_red_td" \
  "and say what stopped it -- matching records are not ownership"
assert_match 'matching records are not ownership' "$cp_red_td" \
  "and say it in the terms an operator can check, rather than as a bare identity error"
case "$cp_red_td" in
  *"$CP_WT"*) ;;
  *) fail "and the refusal must name the checkout that DOES own the schedule, since that is where the operator has to run it" ;;
esac
[ -f "$cp_plist" ] || fail "and the ORIGINAL schedule's plist must survive: the copy has no business unloading it"
[ -f "$cp_mrec" ] || fail "and the machine-local binding, the only name that outlives the original checkout"
[ -f "$cp_rec" ] || fail "and the original's own repo-local binding, which is what keeps its removal guard refusing"
[ -d "$CP_WT" ] || fail "and the checkout that owns the schedule is untouched"
[ -d "$CP_COPY" ] || fail "and so is the copy -- a refusal removes nothing at all"
[ -s "$SCHED_LOG" ] \
  && fail "and no scheduler call may have been made: an unowned binding is refused before launchd is asked anything about it"

# ...and through the other door, which is the one an operator reaches for when
# the copy is not a worktree they mean to delete.
rc=0
cp_red_un="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$CP_COPY" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "and an uninstall run inside the copy must refuse for the same reason (out: $cp_red_un)"
assert_match 'not the checkout that binding was installed against' "$cp_red_un" \
  "with the same refusal, since it is the same resolution"
assert_match 'service uninstall --repo' "$cp_red_un" \
  "naming the uninstall this time, because that is the command that was actually run"
[ -f "$cp_plist" ] || fail "and again nothing is removed"
[ -f "$cp_mrec" ] || fail "and again the machine-local binding stands"
[ -s "$SCHED_LOG" ] \
  && fail "and again launchd is asked nothing"
red_case "a removal run inside a COPY of the bound checkout refuses before any scheduler call, and preserves the original schedule and both records"

# GREEN twin: the SAME command, the SAME schedule, the SAME stubbed launchd
# answer -- run in the checkout git has registered. If the refusal above were
# about the fixture rather than about ownership, this would refuse too.
rc=0
cp_green="$(svc_teardown_notfound 'launchctl (unload|list)' --repo "$CP_WT" 2>&1)" || rc=$?
assert_eq 0 "$rc" \
  "the identical teardown succeeds in the checkout the binding was installed against (out: $cp_green)"
assert_match "$cp_label" "$cp_green" "and it is that schedule it reports having ended"
assert_match 'removed the integration worktree' "$cp_green" "and the removal half then runs"
[ -f "$cp_plist" ] && fail "the plist must be gone -- otherwise the red arm proves only that this verb never removes anything"
[ -f "$cp_mrec" ] && fail "and the machine-local binding must go with it"
[ -d "$CP_WT" ] && fail "and the worktree that owned the schedule must be removed"
green_case "the same teardown ends the schedule and removes the checkout when it is run in the worktree git has registered"

# ...and the refusal must not WEDGE what it refused. The teardown above took the
# original checkout, so the copy is now standing alone holding a repo-local
# record for a path that no longer exists -- and that record is what makes the
# removal guard refuse this directory. A rule that only ever asked "is this the
# registered checkout" would refuse here too, forever, since there is no
# registration left to name anybody: a checkout guarded against removal by a
# file no verb can take. So the second, weaker way a record may honestly name
# another path is that the path is GONE, and in exactly that case there is no
# other checkout for the removal to harm. (It is also the plain-rename case: git
# can only speak for a linked worktree.)
[ -f "$cp_copy_rec" ] || fail "K14: the copy must still hold the record the original's teardown could not reach"
rc=0
orchid_service_removal_guard "$CP_COPY" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "K14: and that record must still be guarding the copy, or there is no wedge to disprove"
rc=0
orchid_service_binding_owned "$CP_COPY" "$CP_WT" || rc=$?
assert_eq 0 "$rc" \
  "the copy owns the leftover record once the checkout it names is gone -- nothing is left for a removal to harm, and refusing would strand it"
rc=0
cp_orphan="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$CP_COPY" 2>&1)" || rc=$?
assert_eq 0 "$rc" "so the uninstall the guard names really can clear it (out: $cp_orphan)"
[ -f "$cp_copy_rec" ] && fail "and the stale record must be gone, or the guard below has nothing to release"
rc=0
orchid_service_removal_guard "$CP_COPY" >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" "and the copy is removable again -- the ownership rule cost a step, not the verb"
green_case "a copy left holding a record for a checkout that no longer exists can still clear it, so the ownership refusal never wedges the removal guard"

# -- K15: a refusal is evidence about the LAST wake ------------------------
# The two arms of K2/K2c record, machine-locally, that this schedule woke and
# refused -- because the plist and cron line send both streams to /dev/null and
# `orchid doctor` is the only place that note can be read. Nothing but
# `uninstall` used to retire it, so it outlived what it described: a checkout
# restored or a repository repaired, and doctor went on printing `the schedule
# last woke and refused: ...` indented directly under its own `ok:` line for a
# service that was demonstrably healthy. Two contradictory sentences about one
# binding is worse than neither -- it is how an operator learns to discount the
# surface that carries the real finding.
STALE="$BIND/stale-refusal"
mkdir -p "$STALE"
(
  cd "$STALE" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: planning\nrun_id: r-stale\n---\n# Roadmap\n' > .orchid/roadmap.md
)
# CANONICAL, because that is the string install hashes its label from and bakes
# into the artifact as ORCHID_REPO -- a scheduled pump arrives with exactly it,
# which is what lets it find its own binding to record against.
STALE_CANON="$(cd "$STALE" && pwd -P)"
trust_repo "$STALE"
st_inst="$("$SERVICE" install --repo "$STALE" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the stale-refusal fixture installs a schedule first (out: $st_inst)"
st_label="$(echo "$st_inst" | grep -oE "$label_re" | head -n1)"
st_refusal="$HOME/.orchid/services/$st_label.refusal"
[ -f "$st_refusal" ] && fail "K15 fixture: a fresh install must start with no recorded refusal"

# st_doctor_lines <label> -- doctor's report for ONE binding: the line naming it
# plus the line after, which is where the refusal note is indented. Scoped
# deliberately: doctor walks every binding on the machine and earlier sections
# leave their own, so a match against the whole report could be another
# schedule's refusal entirely.
st_doctor_lines() {
  ORCHID_REPO="$WORK" "$ORCHID_BIN" doctor 2>&1 | grep -A1 -F "$1" || true
}

# BREAK THE REPOSITORY, the K2c way: the directory survives, its `.git` points at
# a gitdir that is not there. Saved rather than destroyed, because this section
# needs to put it back.
mv "$STALE/.git" "$BIND/stale-gitdir" || fail "K15 fixture: could not set the repository aside"
printf 'gitdir: %s\n' "$STALE/no-such-common-dir" > "$STALE/.git"
rc=0
st_pump_red="$(ORCHID_REPO="$STALE_CANON" "$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "K15 fixture: the pump must refuse a checkout whose repository is gone (out: $st_pump_red)"
[ -f "$st_refusal" ] || fail "K15 fixture: that refused wake must have recorded its reason"
st_doctor_red="$(st_doctor_lines "$st_label")"
assert_match 'the schedule last woke and refused' "$st_doctor_red" \
  "a refused wake is reported: doctor is the only surface that hears it, and the note must survive the wake that wrote it"
red_case "a wake that refused leaves its reason where doctor reads it"

# GREEN: the repository is back, and the very next wake is an ordinary quiet
# no-op. That pass DISPROVES the note -- the directory is there and so is the
# repository behind it -- so the note must go, or doctor prints a schedule as
# failing directly beneath its own line calling it healthy.
rm -f "$STALE/.git"
mv "$BIND/stale-gitdir" "$STALE/.git" || fail "K15 fixture: could not restore the repository"
rc=0
st_pump_green="$(ORCHID_REPO="$STALE_CANON" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "the repaired checkout's next wake is an ordinary quiet no-op (out: $st_pump_green)"
[ -f "$st_refusal" ] \
  && fail "THE FINDING: a healthy successful wake must retire the refusal it has just disproved"
st_doctor_green="$(st_doctor_lines "$st_label")"
case "$st_doctor_green" in
  *"ok: pump service installed for $STALE_CANON"*) ;;
  *) fail "doctor must now report this binding as ordinary state (got: $st_doctor_green)" ;;
esac
grep -qF 'last woke and refused' <<<"$st_doctor_green" \
  && fail "and must print no refusal beside it -- an obsolete note under an 'ok:' line is two contradictory sentences about one binding"
green_case "a wake that found the target healthy and succeeded retires the refusal, so doctor never prints one beside a healthy service"

# The other retirement, and the flag it must NOT happen under. Stage the refusal
# again, then repair the checkout -- so the note is stale but the schedule the
# note is about is still exactly the schedule that is loaded.
mv "$STALE/.git" "$BIND/stale-gitdir" || fail "K15 fixture: could not set the repository aside again"
printf 'gitdir: %s\n' "$STALE/no-such-common-dir" > "$STALE/.git"
rc=0
ORCHID_REPO="$STALE_CANON" "$PUMP" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "K15 fixture: the second refused wake must fail as the first did"
[ -f "$st_refusal" ] || fail "K15 fixture: and must have recorded its reason again"
rm -f "$STALE/.git"
mv "$BIND/stale-gitdir" "$STALE/.git" || fail "K15 fixture: could not restore the repository again"

# RED: a --dry-run install makes no scheduler call, so the schedule that refused
# is still the schedule that is loaded, and the note is still about it. A
# preview that destroyed it would be the uninstall-under---dry-run hazard wearing
# install's clothes: evidence about a LIVE schedule taken by the one flag an
# operator runs expecting no consequences.
st_dry="$("$SERVICE" install --repo "$STALE" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "a --dry-run re-install exits 0 (out: $st_dry)"
[ -f "$st_refusal" ] \
  || fail "a --dry-run install must leave the recorded refusal exactly where it found it -- it replaced no schedule"
red_case "a --dry-run install leaves a recorded refusal standing, because it left the schedule that refused running"

# GREEN: the real re-install unloads whatever was there and loads a fresh agent,
# so the wake that note describes belongs to neither.
rc=0
st_real="$(svc_install_real --repo "$STALE" --interval-s 240 2>&1)" || rc=$?
assert_eq 0 "$rc" "a real re-install exits 0 (out: $st_real)"
grep -qE 'launchctl load' "$SCHED_LOG" \
  || fail "K15 fixture: the real install must actually have reached the scheduler (log: $(cat "$SCHED_LOG"))"
[ -f "$st_refusal" ] \
  && fail "a real (re)install must retire the refusal recorded against the schedule it just replaced"
st_doctor_reinst="$(st_doctor_lines "$st_label")"
grep -qF 'last woke and refused' <<<"$st_doctor_reinst" \
  && fail "and doctor must print none beside the service it has just been told is installed"
green_case "a real install retires the refusal recorded against the schedule it replaces"

# -- K15b: the wake is not over until the TICK is ---------------------------
# The arms above all end inside the pump, and for those the EXIT trap is the
# whole story: the note is retired only when the pass ended zero with the target
# healthy. The pump's last statement was different in kind -- it `exec`ed
# runners/orchid-tick, which replaces the process image, so no trap of the
# pump's could ever run after it. That left one way to retire the note on the
# handoff path: clear it UP FRONT, on the pump's own success, and hand over.
#
# The pump's pass had succeeded. THE WAKE HAD NOT. A wake is one thing to
# everybody who reads its outcome -- launchd keeps its exit status, `orchid
# doctor` reads the note beside its binding -- and the tick goes on to run an
# orchestrator, which can fail. So a schedule whose every wake woke a model that
# wrote no envelope reported a clean binding to the one surface an operator can
# read, with the last thing that actually went wrong deleted by the pass that was
# about to go wrong again.
#
# Both arms below are ONE fixture and ONE staged refusal, differing only in
# whether the orchestrator the tick spawns produces an envelope -- so what is
# proved is the tick's exit status deciding, and not the fixture.
TK="$BIND/tick-wake"
TK_ENG="$BIND/tick-engines"
mkdir -p "$TK" "$TK_ENG"

# mk_tick_engine <name> <ok|fail> -- a stub orchestrator engine (capabilities
# shell,git, matching roles/orchestrator.role's requires) whose `run` either
# writes a valid `ok` orchestrate envelope or writes nothing at all. The second
# is how a HEALTHY target still ends the wake nonzero: runners/orchid-tick treats
# a missing/invalid envelope as `failed` and its last statement is
# `[ "$status" = ok ]`.
mk_tick_engine() {
  # Split declarations: a multi-assignment `local` cannot see its own earlier
  # names (SC2318), so `dir` would be built from an empty `name`.
  local name="$1" mode="$2"
  local dir="$TK_ENG/$name"
  mkdir -p "$dir"
  printf 'manifest_version=1\nid=test/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
    "$name" > "$dir/plugin.conf"
  if [ "$mode" = ok ]; then
    cat > "$dir/run" <<'EOF'
#!/usr/bin/env bash
set -eu
req="$1"; out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"; task="$(jq -r .task "$req")"
printf '{"contract":1,"job_id":"%s","task":"%s","operation":"orchestrate","status":"ok","actions":[],"summary":"K15b stub ok"}' \
  "$jid" "$task" > "$out"
EOF
  else
    cat > "$dir/run" <<'EOF'
#!/usr/bin/env bash
# Writes no envelope at all -- an adapter that crashed. The tick marks the
# engine failed and exits nonzero; nothing about the CHECKOUT is wrong.
exit 1
EOF
  fi
  chmod +x "$dir/run"
}
mk_tick_engine tkfail fail
mk_tick_engine tkok ok

# tk_lease <age_s> -- a lease old enough that the pump treats the run as
# abandoned. Re-written before every wake: the tick's own `run resume` refreshes
# it, so a second pass over the same fixture would otherwise stop at "lease
# fresh" and never reach the handoff this section is about.
tk_lease() {
  local age="$1" now target iso
  now="$(date -u +%s)"; target=$((now - age))
  iso="$(date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$TK/.orchid/runtime"
  jq -n --arg t "$iso" '{epoch:1, refreshed_at:$t}' > "$TK/.orchid/runtime/lease.json"
}

(
  cd "$TK" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: running\nrun_id: r-tk\n---\n# Roadmap\n' > .orchid/roadmap.md
  # pump_wake_max out of the way: this section re-drives ONE unchanged boundary
  # across several passes, and the wake budget exists to stop exactly that. Its
  # own RED/GREEN pair lives in tests/test_run.sh.
  printf 'role.orchestrator=tkfail\npump_wake_max=99\n' > orchid.config
) || fail "K15b fixture: could not build the tick-handoff repo"
TK_CANON="$(cd "$TK" && pwd -P)"
trust_repo "$TK"

# A judgment boundary an ORCHESTRATOR can settle -- a task parked at
# `arbitrating` over a request-changes review. Anything else and the pump
# declines the hand-off and never reaches the tick at all.
TK_EPOCH="$(ORCHID_REPO="$TK" "$ORCHID_BIN" run start | sed 's/epoch: //')"
[ -n "$TK_EPOCH" ] || fail "K15b fixture: 'run start' gave no epoch, so nothing below is fenced"
ORCHID_REPO="$TK" ORCHID_EPOCH="$TK_EPOCH" "$ORCHID_BIN" task create TK1 "contested review" >/dev/null \
  || fail "K15b fixture: could not create the boundaried task"
TK_CAND=7777777777777777777777777777777777777777
fm_set "$TK/.orchid/tasks/TK1.md" status arbitrating
fm_set "$TK/.orchid/tasks/TK1.md" candidate_sha "$TK_CAND"
mkdir -p "$TK/.orchid/reviews"
jq -n --arg cand "$TK_CAND" \
  '{contract:1, job_id:"j-fixture-TK1", task:"TK1", operation:"review", status:"ok",
    verdict:"request-changes", scope_complete:true, summary:"K15b fixture review",
    candidate_sha:$cand, findings:[]}' > "$TK/.orchid/reviews/TK1-a1-reviewer.json"

tk_inst="$("$SERVICE" install --repo "$TK" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the tick-handoff fixture installs a schedule first (out: $tk_inst)"
tk_label="$(echo "$tk_inst" | grep -oE "$label_re" | head -n1)"
tk_refusal="$HOME/.orchid/services/$tk_label.refusal"

# STAGE THE REFUSAL the way a real one is staged -- a wake against a broken
# repository -- then put the repository back. From here on the target is healthy
# and the note is stale; the only question either arm asks is what retires it.
mv "$TK/.git" "$BIND/tk-gitdir" || fail "K15b fixture: could not set the repository aside"
printf 'gitdir: %s\n' "$TK/no-such-common-dir" > "$TK/.git"
rc=0
ORCHID_REPO="$TK_CANON" "$PUMP" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "K15b fixture: the staging wake must refuse a checkout whose repository is gone"
[ -f "$tk_refusal" ] || fail "K15b fixture: that refused wake must have recorded its reason"
rm -f "$TK/.git"
mv "$BIND/tk-gitdir" "$TK/.git" || fail "K15b fixture: could not restore the repository"
orchid_checkout_git_alive "$TK_CANON" \
  || fail "K15b fixture: the target must be healthy again, or both arms below are about a dead checkout"

# RED: a healthy target, a wake that reaches the hand-off, and a tick that ends
# nonzero. The refusal is the most recent thing that went wrong with this
# schedule and nothing about this pass disproved it.
tk_lease 1000
rc=0
tk_red="$(ORCHID_ENGINES_DIR="$TK_ENG" ORCHID_REPO="$TK_CANON" "$PUMP" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a wake whose tick failed must exit nonzero (out: $tk_red)"
assert_match 'tick: tkfail failed' "$tk_red" \
  "and it must really have reached the tick -- an arm that stopped in the pump would prove nothing about the hand-off"
[ -f "$tk_refusal" ] \
  || fail "THE FINDING: a wake that ended in a failing tick must leave the recorded refusal exactly where it found it"
tk_doctor_red="$(st_doctor_lines "$tk_label")"
assert_match 'the schedule last woke and refused' "$tk_doctor_red" \
  "so doctor still reports the schedule as having something wrong with it, which is the only surface a scheduled wake has"
red_case "a wake that hands off to a failing tick retains the recorded refusal, because the wake did not succeed"

# GREEN twin: the same fixture, the same staged note, the same hand-off -- and an
# orchestrator that writes its envelope. The wake ends zero, so it has disproved
# the note as thoroughly as any of the pump's own quiet exits.
printf 'role.orchestrator=tkok\npump_wake_max=99\n' > "$TK/orchid.config"
tk_lease 1000
rc=0
tk_green="$(ORCHID_ENGINES_DIR="$TK_ENG" ORCHID_REPO="$TK_CANON" "$PUMP" 2>&1)" || rc=$?
assert_eq 0 "$rc" "the identical wake exits 0 once the orchestrator it spawns succeeds (out: $tk_green)"
assert_match 'tick: tkok ok' "$tk_green" "and it is the same hand-off, differing only in what the tick made of it"
[ -f "$tk_refusal" ] \
  && fail "and a wake that ended zero with a healthy target must retire the note it disproved"
tk_doctor_green="$(st_doctor_lines "$tk_label")"
grep -qF 'last woke and refused' <<<"$tk_doctor_green" \
  && fail "so doctor prints no refusal beside this binding either"
green_case "a wake that hands off to a tick that succeeds retires the refusal, and the two arms differ only in the tick's exit status"

# -- K16: the repo-local record is UNTRUSTED INPUT --------------------------
# Every removing arm above reads `.orchid/runtime/service.json` and builds paths
# out of what it says: the machine-local twin to open and delete, the refusal
# note to clear, the plist to hand `launchctl unload` and then `rm -f`. That file
# lives inside the checkout a run is driven in -- gitignored, and writable by
# every engine the run spawns -- so taken at face value those are two
# arbitrary-path primitives wearing a schedule's clothes:
#
#   the LABEL is a path COMPONENT. `../../stolen` resolves the machine-local
#     record to $HOME/.orchid/services/../../stolen.json and the plist to
#     $HOME/Library/LaunchAgents/../../stolen.plist -- outside both stores -- and
#     uninstall unloads and deletes exactly those.
#   the ARTIFACT is a whole path, unloaded and then removed as it stands.
#
# Neither is refused for LOOKING dangerous. Both are checked against what
# `orchid service install` could have produced (lib/common.sh's
# orchid_service_label_valid / orchid_service_artifact_valid), which is the only
# rule that needs no judgment about which other spellings would have been safe.
FRG="$BIND/forged"
mkdir -p "$FRG"
(
  cd "$FRG" || exit 1
  git init -q .
  git commit -q --allow-empty -m root
  mkdir -p .orchid/tasks
  printf -- '---\nrun_status: planning\nrun_id: r-frg\n---\n# Roadmap\n' > .orchid/roadmap.md
) || fail "K16 fixture: could not build the forged-record repo"
FRG_CANON="$(cd "$FRG" && pwd -P)"
trust_repo "$FRG"
frg_inst="$("$SERVICE" install --repo "$FRG" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "the forged-record fixture installs a real schedule first (out: $frg_inst)"
frg_label="$(echo "$frg_inst" | grep -oE "$label_re" | head -n1)"
frg_plist="$HOME/Library/LaunchAgents/$frg_label.plist"
frg_rec="$FRG_CANON/.orchid/runtime/service.json"
frg_mrec="$HOME/.orchid/services/$frg_label.json"
[ -f "$frg_plist" ] || fail "K16 fixture: the install must have placed the plist"
[ -f "$frg_rec" ] || fail "K16 fixture: the install must have written the repo-local binding"
[ -f "$frg_mrec" ] || fail "K16 fixture: the install must have written the machine-local binding"
cp "$frg_rec" "$BIND/frg-rec.keep" || fail "K16 fixture: could not stash the honest record"
cp "$frg_mrec" "$BIND/frg-mrec.keep" || fail "K16 fixture: could not stash the honest twin"

# THE DECOYS ARE THE EXACT PATHS THE FORGED LABEL RESOLVES TO, and they are
# operator files: one where the machine-local record would land, one where the
# plist would. Both are outside the stores this verb owns.
FRG_STOLEN_REC="$HOME/stolen.json"
FRG_STOLEN_PLIST="$HOME/stolen.plist"
FRG_FAKE_LABEL='../../stolen'
printf 'an operator file orchid never wrote\n' > "$FRG_STOLEN_PLIST"
# ...and the forged TWIN, so the twins check passes for the forgery exactly as it
# does for an honest pair. Without it this section would prove only that
# mismatched records are refused, which K13 already proves.
jq --arg l "$FRG_FAKE_LABEL" --arg a "$HOME/Library/LaunchAgents/$FRG_FAKE_LABEL.plist" \
   '.label = $l | .artifact = $a' "$BIND/frg-rec.keep" > "$FRG_STOLEN_REC" \
  || fail "K16 fixture: could not stage the forged machine-local twin"
jq --arg l "$FRG_FAKE_LABEL" --arg a "$HOME/Library/LaunchAgents/$FRG_FAKE_LABEL.plist" \
   '.label = $l | .artifact = $a' "$BIND/frg-rec.keep" > "$frg_rec" \
  || fail "K16 fixture: could not stage the forged repo-local record"
assert_eq "$(cat "$FRG_STOLEN_REC")" "$(cat "$frg_rec")" \
  "the forged pair is byte-identical, so nothing but the label rule can be what refuses it"

# The containment itself, at the one place a label becomes a path: a label orchid
# does not derive resolves to nothing at all, so even a caller that skipped the
# validation upstream cannot be handed a path outside the store.
rc=0
orchid_service_machine_record "$FRG_FAKE_LABEL" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] \
  || fail "orchid_service_machine_record must refuse a label install could not have derived: it is joined in as a path component"
rc=0
orchid_service_refusal_path "$FRG_FAKE_LABEL" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "and so must the refusal path, which uninstall rm -f's"
rc=0
orchid_service_identity "$FRG_CANON" || rc=$?
assert_eq 2 "$rc" \
  "and the resolution answers with its own third code -- 'this record is not usable' is not the same finding as 'the two records disagree'"
assert_match "$FRG_FAKE_LABEL" "$ORCHID_SERVICE_ID_REJECTED" \
  "naming the value it rejected"
assert_match 'service.json' "$ORCHID_SERVICE_ID_REJECTED" \
  "and the record it came from, since repairing or deleting that file is the recovery"

# RED, through the verb: nothing removed, nothing unloaded, and the operator's
# own files untouched.
rc=0
frg_red="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$FRG_CANON" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an uninstall whose record names a label orchid could not have derived must refuse (out: $frg_red)"
assert_match 'does not name a schedule orchid could have installed' "$frg_red" \
  "and say what stopped it, in terms that are about the RECORD rather than about the schedule"
assert_match 'is not one .orchid service install. derives' "$frg_red" \
  "naming the rule it failed"
[ -f "$FRG_STOLEN_REC" ] \
  || fail "THE FINDING: the file the forged label resolves to is an operator's, and a removal must not take it"
[ -f "$FRG_STOLEN_PLIST" ] || fail "nor the file the forged label's plist path resolves to"
[ -s "$SCHED_LOG" ] \
  && fail "and launchd is asked nothing at all -- a record that cannot be believed is refused before any path built from it is probed"
[ -f "$frg_plist" ] || fail "and the real schedule's plist stands"
[ -f "$frg_mrec" ] || fail "and so does its machine-local binding"
red_case "a repo-local record naming a label orchid could not have derived is refused before any path built from it is opened, unloaded or deleted"

# GREEN twin: the same command against the same fixture with the record install
# actually wrote. If the refusal above were about the fixture rather than about
# the record's contents, this would refuse too.
rm -f "$FRG_STOLEN_REC"
cp "$BIND/frg-rec.keep" "$frg_rec" || fail "K16: could not restore the honest record"
rc=0
frg_green="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$FRG_CANON" 2>&1)" || rc=$?
assert_eq 0 "$rc" "the identical uninstall succeeds with the record install wrote (out: $frg_green)"
[ -f "$frg_plist" ] && fail "and it really removes the schedule's plist"
[ -f "$frg_mrec" ] && fail "and the machine-local binding"
[ -f "$FRG_STOLEN_PLIST" ] || fail "while the operator file the forgery pointed at is still none of its business"
green_case "the same uninstall ends the schedule when the record names the label install derived"

# -- K16b: the same rule for the ARTIFACT ----------------------------------
# A label that validates says where the plist SHOULD be; the record also says
# where it IS, and uninstall unloads and deletes that path as it stands
# (_svc_artifact). Staged in BOTH halves, so the twins agree and ownership holds
# -- the artifact rule is the only thing left that can refuse it.
FRG_PRECIOUS="$BIND/precious-launchagent.plist"
printf 'an operator plist orchid never installed\n' > "$FRG_PRECIOUS"
frg2_inst="$("$SERVICE" install --repo "$FRG_CANON" --interval-s 240 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "K16b fixture: re-installs the schedule K16 ended (out: $frg2_inst)"
[ -f "$frg_plist" ] || fail "K16b fixture: the re-install must have placed the plist"
cp "$frg_rec" "$BIND/frg-rec.keep" || fail "K16b fixture: could not stash the honest record"
cp "$frg_mrec" "$BIND/frg-mrec.keep" || fail "K16b fixture: could not stash the honest twin"
jq --arg a "$FRG_PRECIOUS" '.artifact = $a' "$BIND/frg-rec.keep" > "$frg_rec" \
  || fail "K16b fixture: could not stage the forged artifact"
jq --arg a "$FRG_PRECIOUS" '.artifact = $a' "$BIND/frg-mrec.keep" > "$frg_mrec" \
  || fail "K16b fixture: could not stage the forged artifact in the twin"
assert_eq "$(cat "$frg_rec")" "$(cat "$frg_mrec")" \
  "the twins agree about the forged artifact, so the twins check cannot be what refuses it"
rc=0
orchid_service_identity "$FRG_CANON" || rc=$?
assert_eq 2 "$rc" "the resolution rejects the record itself, with the same third code the forged label earns"
assert_match 'precious-launchagent' "$ORCHID_SERVICE_ID_REJECTED" "naming the path it would have acted on"

rc=0
frg2_red="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$FRG_CANON" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an uninstall whose record names an artifact install could not have written must refuse (out: $frg2_red)"
assert_match 'does not name a schedule orchid could have installed' "$frg2_red" "with the same refusal, since it is the same rule"
assert_match 'is not a path .orchid service install. writes' "$frg2_red" "naming the half that failed it this time"
[ -f "$FRG_PRECIOUS" ] \
  || fail "THE FINDING: an artifact a record names is unloaded and then deleted, so an operator's own file must never be reachable that way"
[ -s "$SCHED_LOG" ] \
  && fail "and it is never handed to launchctl either -- the refusal is ahead of every scheduler call"
[ -f "$frg_plist" ] || fail "and the real plist is left exactly where it was"
[ -f "$frg_mrec" ] || fail "and the machine-local binding too"
red_case "a record naming an artifact orchid could not have written is refused before that path is unloaded or removed"

# GREEN twin: the honest artifact, and the same uninstall ends the schedule.
cp "$BIND/frg-rec.keep" "$frg_rec" || fail "K16b: could not restore the honest record"
cp "$BIND/frg-mrec.keep" "$frg_mrec" || fail "K16b: could not restore the honest twin"
rc=0
frg2_green="$(svc_uninstall_notfound 'launchctl (unload|list)' --repo "$FRG_CANON" 2>&1)" || rc=$?
assert_eq 0 "$rc" "the identical uninstall succeeds with the artifact install wrote (out: $frg2_green)"
[ -f "$frg_plist" ] && fail "and the plist it named is the one that goes"
[ -f "$FRG_PRECIOUS" ] || fail "while the operator's own plist is still standing"
green_case "the same uninstall ends the schedule when the record names the artifact install wrote"

unset ORCHID_SERVICE_OS

# ===========================================================================
# J -- --help / usage documents idempotence for install and uninstall, and
# the teardown ordering as the ONE conditional operation it actually is.
# ===========================================================================
out="$("$SERVICE" --help 2>&1)"; rc=$?
assert_eq 0 "$rc" "--help exits 0"
assert_match 'install' "$out" "help mentions install"
assert_match 'uninstall' "$out" "help mentions uninstall"
assert_match 'status' "$out" "help mentions status"
assert_match 'idempotent' "$out" "help documents install/uninstall idempotence"
assert_match 'dry-run' "$out" "help documents --dry-run"
assert_match 'trust unattended' "$out" "help documents the unattended acknowledgement prerequisite"
assert_match 'TEARDOWN ORDERING' "$out" "help documents the teardown ordering, where an operator reading about install will meet it"
assert_match 'uninstall the service FIRST' "$out" "and states which of the two steps comes first"
assert_match 'ONE conditional operation' "$out" \
  "and that the two steps are one operation rather than an ordering to remember -- an ordering stated as two commands is run as two commands"
assert_match 'orchid service teardown --repo' "$out" "and names the command that is that operation"
assert_match 'uninstall --repo <path> && git worktree remove <path>' "$out" \
  "and, for an operator who would rather run the pair themselves, the chained form -- orchid can refuse only the removals it performs itself"
