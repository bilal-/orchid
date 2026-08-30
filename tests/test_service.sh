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

# The same real uninstall, with the stubbed scheduler call MADE TO FAIL.
# A stub that can only succeed cannot reach the arm that matters most -- what
# uninstall does when `launchctl unload` returns nonzero -- and that arm is the
# one deciding whether the plist and the binding record survive. $1 is an ERE
# matched against the quoted command line, so a caller can fail the unload
# alone (launchd still holds the job) or the unload and the `list` together
# (nothing was ever loaded). See K7.
#
# It is equally how a caller ANSWERS `launchctl list` -- the one call whose
# nonzero status is not a malfunction but a fact ("launchd holds no such job").
# Failing it alone is the only way to stage a never-loaded label, which is what
# K6 and K8's green arms are about; leaving it to succeed stages a job launchd
# still holds, the half that both refusals turn on.
svc_uninstall_failing() {
  local fail_re="$1"; shift
  : > "$SCHED_LOG"
  ORCHID_SERVICE_DEBUG_SCHEDULER_LOG="$SCHED_LOG" \
  ORCHID_SERVICE_DEBUG_SCHEDULER_FAIL="$fail_re" "$SERVICE" uninstall "$@"
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
# had to be undone. Six parts, in the order an operator meets them:
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
# ===========================================================================
source "$REPO_ROOT/lib/common.sh"

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
# anything at all has been committed. (A directory at the record's own path
# would not: `mv file dir` moves the file INTO it and succeeds.) Moved aside
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
# `svc_uninstall_failing 'launchctl list'`, not `svc_uninstall_real`: the state
# under test is an artifact that NEVER LANDED, so launchd holds no job under
# this label, and since K8 that is a question uninstall actually asks. Failing
# the stubbed `list` is how this fixture answers it -- a stub that answered
# "still loaded" would be describing a different state, and would be asserting
# the wrong half of K8's distinction here.
orphan_out="$(svc_uninstall_failing 'launchctl list' --repo "$BIND_REPO" 2>&1)" || rc=$?
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

# GREEN, and the reason the exit status alone could not have decided it: an
# unload of a plist that was never loaded fails too. `install` writes the plist
# before loading it, so anything failing in between leaves one -- an ordinary
# state uninstall must still clear. Here BOTH stubbed calls fail, which is what
# launchd reports when it holds no such job, and the removals proceed.
rc=0
never_out="$(svc_uninstall_failing 'launchctl (unload|list)' --repo "$BIND_REPO" 2>&1)" || rc=$?
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
freed_out="$(svc_uninstall_failing 'launchctl list' --repo "$BIND_REPO" 2>&1)" || rc=$?
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

# ===========================================================================
# J -- --help / usage documents idempotence for install and uninstall.
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
