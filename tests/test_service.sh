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
# ===========================================================================
out="$("$SERVICE" uninstall --repo "$WORK" --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "uninstall exits 0 when something was installed"
assert_match 'DRY-RUN:.*launchctl unload' "$out" "uninstall --dry-run prints the launchctl unload command"
[ -f "$plist3" ] && fail "uninstall must remove the plist file it created"
remaining="$(find "$HOME/Library/LaunchAgents" -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq 0 "$remaining" "uninstall removes exactly the one plist file (no collateral removal)"

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
assert_eq 0 "$rc" "linux uninstall exits 0 when something was installed"
assert_match 'DRY-RUN:.*crontab' "$out" "linux uninstall --dry-run prints (never runs) the crontab pipeline"
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

"$SERVICE" uninstall --repo "$WORK2" --dry-run >/dev/null 2>&1
[ -f "$HOME/Library/LaunchAgents/$l1.plist" ] || fail "uninstalling repo 2 must not remove repo 1's plist"
[ -f "$HOME/Library/LaunchAgents/$l2.plist" ] && fail "uninstalling repo 2 must remove repo 2's own plist"
"$SERVICE" uninstall --repo "$WORK" --dry-run >/dev/null 2>&1
rm -rf "$WORK2"

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
