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

cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
export ORCHID_ROOT="$REPO_ROOT"

# $WORK (from mktemp -d) commonly has a symlinked component on macOS
# (/var/folders/... -> /private/var/folders/...) -- the service always
# hashes/bakes in the CANONICAL, physically-resolved repo path (the brief's
# own wording for the label), so every assertion against path TEXT actually
# baked into a rendered artifact compares against $repo_canon, never the
# raw $WORK string. Plain file-existence checks against "$WORK/..." remain
# fine as-is -- the OS resolves the symlink either way when opening a path.
repo_canon="$(cd "$WORK" && pwd -P)"

label_re='com\.orchid\.pump\.[0-9a-f]{12}'

# ===========================================================================
# A -- install refuses an uninitialized repo (no .orchid/ at all).
# ===========================================================================
out="$("$SERVICE" install --repo "$WORK" --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "install must refuse an uninitialized repo (no .orchid/)"
assert_match 'uninitialized|no \.orchid' "$out" "install names the uninitialized-repo refusal plainly"
[ -d "$HOME/Library/LaunchAgents" ] && fail "a refused install must not render/place anything"

mkdir -p .orchid/tasks

# ===========================================================================
# B -- macOS (default host branch, no ORCHID_SERVICE_OS override): install
# renders the launchd plist template with the correct label, ORCHID_REPO,
# TMPDIR (the repo's PARENT dir -- the live-run TMPDIR incident), interval,
# and pump.log path, then PRINTS (never runs) the launchctl load command.
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
grep -qF "<string>$repo_canon/.orchid/runtime/pump.log</string>" "$plist" || fail "plist Std{Out,Err}Path does not point at runtime/pump.log"
assert_match 'DRY-RUN:.*launchctl load' "$out" "install --dry-run prints the launchctl load command"

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
echo "$out" | grep -q 'DRY-RUN' && fail "a refused uninstall must never print a launchctl command -- there is nothing to reverse"

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
out="$("$SERVICE" install --repo "$WORK" --interval-s 150 --dry-run 2>&1)"; rc=$?
assert_eq 0 "$rc" "linux install --dry-run exits 0"
assert_match "$label_re" "$out" "linux install prints a label"
labelL="$(echo "$out" | grep -oE "$label_re" | head -n1)"
assert_eq "$label" "$labelL" "the label is the same hash regardless of platform (same repo path)"
record="$WORK/.orchid/runtime/pump.cron"
[ -f "$record" ] || fail "linux install must render + place a local pump.cron record for real, same as the plist on darwin"
line="$(cat "$record")"
assert_match '^\*/2 \* \* \* \*' "$line" "150s floors to 2 minutes (150/60=2, integer division)"
assert_match "ORCHID_REPO=$repo_canon" "$line" "cron line carries ORCHID_REPO (canonical)"
assert_match "TMPDIR=$parent" "$line" "cron line carries TMPDIR set to the repo's parent (same rationale as the plist)"
assert_match "$repo_canon/.orchid/runtime/pump.log" "$line" "cron line redirects into runtime/pump.log"
assert_match "# orchid-service:$label" "$line" "cron line carries the marker comment used to find/remove it later"
assert_match 'DRY-RUN:.*crontab' "$out" "linux install --dry-run prints (never runs) the crontab pipeline"

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

outp="$("$SERVICE" install --repo "$WORKP" --interval-s 120 --dry-run 2>&1)"; rcp=$?
assert_eq 0 "$rcp" "linux install --dry-run exits 0 even when --repo contains %"
recordp="$WORKP/.orchid/runtime/pump.cron"
[ -f "$recordp" ] || fail "linux install must render + place a pump.cron record even when --repo contains %"
linep="$(cat "$recordp")"
assert_match "ORCHID_REPO=$(printf '%s' "$WORKP_canon" | sed 's/%/\\\\%/g')" "$linep" \
  "cron line escapes a literal % in the repo path as \\% (cron's own escape for a literal percent)"
case "$linep" in
  *"ORCHID_REPO=$WORKP_canon "*)
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
# I -- multiple repos = multiple distinct labels, never colliding, and each
# repo's own uninstall never disturbs the other's.
# ===========================================================================
# No new EXIT trap here -- helpers.sh already owns one (WORK cleanup + the
# FAILS-based exit code); a second `trap ... EXIT` in this file would
# silently REPLACE it, not chain, dropping both. WORK2 is removed by hand
# at the end of this section instead.
WORK2="$(mktemp -d)"
( cd "$WORK2" && git init -q . && git commit -q --allow-empty -m root && mkdir -p .orchid/tasks )

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
