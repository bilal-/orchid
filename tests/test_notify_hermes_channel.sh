#!/usr/bin/env bash
# v1-m4: hermes notify channel plugin (plugins/notify/hermes) -- a second
# kind=notify plugin, sibling to plugins/notify/openclaw. `notify.plugin`
# (default `openclaw`) is what selects between the two at the pump's
# outbox drain (`runners/orchid-pump`'s `_pump_drain_outbox`); the full
# pump-driven end-to-end path for THIS plugin (`notify.plugin=hermes`,
# including the routing-selector's failure/quarantine behavior for a bogus
# value) is exercised in tests/test_notify_channel.sh's section 8, right
# alongside the openclaw plugin's own equivalent pump coverage, rather than
# duplicated here -- that file already owns the full git/roadmap/lease/
# pump scaffolding this would otherwise have to rebuild from scratch.
# What's specific to THIS file is the plugin's own send-contract
# compliance and target composition in isolation: it invokes
# `plugins/notify/hermes/send <qid> <text>` directly, under the identical
# env-hygiene shape (`env -i` + the two ORCHID_NOTIFY_* vars) the pump
# uses when it launches it, and checks exactly the contract the pump
# depends on: argv shape, exit-code discipline (0 success / nonzero
# failure), and no stdout pollution.
#
# v1-m4 T009 added a second thing specific to this plugin: its INBOUND PROBE
# (sections 6 and 7 below), the read-only `--inbound-probe` mode `orchid
# doctor` runs to say whether an answer can get back at all. It lives here
# rather than in tests/test_init_doctor.sh because what T009 changes is this
# plugin's own manifest and entrypoint; test_init_doctor.sh keeps the
# plugin-agnostic half, driven by a fixture plugin whose manifest it rewrites
# per case.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
export ORCHID_ROOT="$REPO_ROOT"
SEND="$REPO_ROOT/plugins/notify/hermes/send"

cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"

# -- stub `hermes` on PATH: captures argv, never sends anything real -------
STUBBIN="$WORK/stubbin"; mkdir -p "$STUBBIN"
H_LOG="$WORK/hermes-calls.log"; : > "$H_LOG"
H_MODE_FILE="$WORK/hermes-mode"   # absent/"ok" -> exit 0; "fail" -> exit 1
cat > "$STUBBIN/hermes" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$H_LOG"
if [ -f "$H_MODE_FILE" ] && [ "\$(cat "$H_MODE_FILE")" = fail ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$STUBBIN/hermes"
export PATH="$STUBBIN:$PATH"

# ===========================================================================
# 0 -- discovery/validate/conform: same kind=notify minimal-lint path the
# openclaw plugin gets (lib/conform.sh's conform_run_notify), never the
# seven-check engine battery, and conform never invokes `send` itself.
# ===========================================================================
out="$(HOME="$HOME" "$ORCHID_BIN" plugins list)"
assert_match "orchid/hermes-notify	notify" "$out" "plugins list shows the hermes notify plugin with kind=notify"
# ...and it must NOT collide with the pre-existing kind=engine plugin that
# also happens to wrap the hermes CLI (plugins/engines/hermes, id=orchid/
# hermes) -- INV-10 collisions are keyed on id across the WHOLE discovered
# set regardless of kind, which is exactly why this plugin's manifest uses
# the distinct id `orchid/hermes-notify` rather than reusing `orchid/hermes`.
[ -z "$(printf '%s\n' "$out" | grep '^COLLISION:')" ] || fail "plugins list must not report a COLLISION (orchid/hermes-notify vs the engine plugin's orchid/hermes)"

out="$(HOME="$HOME" "$ORCHID_BIN" plugins validate orchid/hermes-notify)"; rc=$?
[ "$rc" -eq 0 ] || fail "plugins validate orchid/hermes-notify should pass (rc=$rc): $out"
assert_match "^ok: " "$out" "plugins validate orchid/hermes-notify reports ok"

out="$(HOME="$HOME" "$ORCHID_BIN" plugins conform "$REPO_ROOT/plugins/notify/hermes")"; rc=$?
[ "$rc" -eq 0 ] || fail "plugins conform on the hermes notify plugin should pass (rc=$rc): $out"
assert_match "send-contract lint only" "$out" "conform names the notify-lint path, not the engine battery"
assert_match "^2/2 checks passed\$" "$out" "conform on kind=notify runs exactly 2 checks (manifest_valid + entrypoint_executable)"
[ -s "$H_LOG" ] && fail "conform must never invoke the plugin's own entrypoint (hermes stub was called)"

# ===========================================================================
# 1 -- target composition WITHOUT ORCHID_NOTIFY_TO: hermes has a "home
# channel" default (unlike openclaw, where notify.to is mandatory), so a
# bare platform name is a legitimate --to target -- no colon, no empty
# trailing segment.
# ===========================================================================
rc=0
env -i PATH="$PATH" ORCHID_NOTIFY_CHANNEL=telegram "$SEND" q-home "q-home: bare home-channel target" >/dev/null 2>"$WORK/stderr1" || rc=$?
[ "$rc" -eq 0 ] || fail "send should succeed with only ORCHID_NOTIFY_CHANNEL set (rc=$rc): $(cat "$WORK/stderr1")"
[ -s "$WORK/stderr1" ] && fail "a successful send must not pollute stderr"
assert_match "^send --to telegram q-home: bare home-channel target\$" "$(cat "$H_LOG")" "no ORCHID_NOTIFY_TO -> --to is the bare platform (home channel), message is the positional arg"
: > "$H_LOG"

# ===========================================================================
# 2 -- target composition WITH ORCHID_NOTIFY_TO: composes <channel>:<to>.
# ===========================================================================
rc=0
env -i PATH="$PATH" ORCHID_NOTIFY_CHANNEL=telegram ORCHID_NOTIFY_TO="-100123456789" \
  "$SEND" q-to "q-to: explicit chat id target" >/dev/null 2>"$WORK/stderr2" || rc=$?
[ "$rc" -eq 0 ] || fail "send should succeed with ORCHID_NOTIFY_CHANNEL+ORCHID_NOTIFY_TO set (rc=$rc): $(cat "$WORK/stderr2")"
assert_match "^send --to telegram:-100123456789 q-to: explicit chat id target\$" "$(cat "$H_LOG")" "ORCHID_NOTIFY_TO set -> --to composes channel:to, message is the positional arg"
: > "$H_LOG"

# a discord channel-name-shaped target composes the same way (no special-
# casing of the '#' form -- it just rides through as part of $to verbatim).
rc=0
env -i PATH="$PATH" ORCHID_NOTIFY_CHANNEL=discord ORCHID_NOTIFY_TO="#ops" \
  "$SEND" q-hash "q-hash: channel-name target" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "send should succeed with a #channel-name-shaped ORCHID_NOTIFY_TO (rc=$rc)"
assert_match "^send --to discord:#ops q-hash: channel-name target\$" "$(cat "$H_LOG")" "a #channel-name ORCHID_NOTIFY_TO composes verbatim after the colon"
: > "$H_LOG"

# ===========================================================================
# 3 -- missing ORCHID_NOTIFY_CHANNEL: must refuse (nonzero), same as
# openclaw's send, and never invoke the real CLI.
# ===========================================================================
rc=0
env -i PATH="$PATH" "$SEND" q-nochan "q-nochan: no channel configured" >/dev/null 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "send must refuse when ORCHID_NOTIFY_CHANNEL is unset"
[ -s "$H_LOG" ] && fail "send must never invoke the hermes CLI when ORCHID_NOTIFY_CHANNEL is missing"

# ===========================================================================
# 4 -- failure/retry visibility: the pump's outbox drain (channel-agnostic,
# already covered end-to-end for openclaw in tests/test_notify_channel.sh)
# decides retry vs quarantine purely off this script's own exit code. With
# the hermes stub set to fail, send's exit code must be nonzero so that
# contract holds for this plugin too.
# ===========================================================================
echo fail > "$H_MODE_FILE"
rc=0
env -i PATH="$PATH" ORCHID_NOTIFY_CHANNEL=telegram "$SEND" q-fail "q-fail: will fail to send" >/dev/null 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "send must exit nonzero when the hermes CLI fails (this is what feeds the pump's retry/quarantine decision)"
assert_match "^send --to telegram q-fail: will fail to send\$" "$(cat "$H_LOG")" "the hermes stub was still invoked with the composed target+message even though it failed"
rm -f "$H_MODE_FILE"   # back to success mode
: > "$H_LOG"

# ===========================================================================
# 5 -- exit-code passthrough: the hermes CLI's own documented usage-error
# exit code (2, per `hermes send --help`) must also surface as this
# script's exit code unchanged (no swallowing/translating to 0 or 1).
# ===========================================================================
cat > "$STUBBIN/hermes" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
chmod +x "$STUBBIN/hermes"
rc=0
env -i PATH="$PATH" ORCHID_NOTIFY_CHANNEL=telegram "$SEND" q-usage "q-usage: usage error" >/dev/null 2>/dev/null || rc=$?
assert_eq "2" "$rc" "the hermes CLI's own exit code (2, usage error) passes straight through unchanged"

# ===========================================================================
# 6 -- THE INBOUND PROBE (v1-m4 T009). r-001 delivered on hermes, and hermes
# is the channel whose gateway went down for a day while blockers kept
# arriving on the operator's phone and the answer typed back was lost with no
# local trace (lesson L011). The asymmetry that makes that possible is
# specific to this plugin: `hermes send` reaches the platform's bot-token API
# directly with the gateway's stored credentials and needs no running gateway,
# while a reply is delivered TO the gateway. So sending green while the return
# leg is dead is this plugin's normal failure mode, not an exotic one.
#
# T006 shipped the manifest key and openclaw's probe; this section is the
# hermes half. Every branch is driven through a stub, so the whole verdict
# table is reachable with no live gateway anywhere.
# ===========================================================================
assert_eq "--inbound-probe" "$(manifest_get "$REPO_ROOT/plugins/notify/hermes" inbound_probe)" \
  "the hermes plugin must declare its probe in the manifest -- doctor never guesses a probe argument"
[ -x "$SEND" ] || fail "the hermes entrypoint must be executable -- the probe mode ships inside it precisely because this bit is already validated"

PROBEBIN="$WORK/probebin"; mkdir -p "$PROBEBIN"
HG_OUT="$WORK/hermes-gateway-out"; HG_RC="$WORK/hermes-gateway-rc"
HG_LOG="$WORK/hermes-gateway-calls.log"; : > "$HG_LOG"
printf 'gateway: running\n' > "$HG_OUT"; printf '0' > "$HG_RC"
cat > "$PROBEBIN/hermes" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$HG_LOG"
cat "$HG_OUT"
exit "\$(cat "$HG_RC")"
EOF
chmod +x "$PROBEBIN/hermes"

# probe <channel> <stub-stdout> <stub-exit> -> $probe_out / $probe_rc
probe() {
  printf '%s\n' "$2" > "$HG_OUT"; printf '%s' "$3" > "$HG_RC"
  : > "$HG_LOG"
  probe_rc=0
  probe_out="$(PATH="$PROBEBIN:$PATH" ORCHID_NOTIFY_CHANNEL="$1" ORCHID_NOTIFY_TO="" \
    "$SEND" --inbound-probe 2>&1)" || probe_rc=$?
}

# A running gateway -> 0 (reachable). The ONLY path to a green inbound line.
probe telegram "gateway: running (hermes 0.19.0, telegram connected)" 0
assert_eq "0" "$probe_rc" "a running gateway must probe as reachable"
# The full phrase, never a bare "up: ": the NOT-reachable line below reads
# "as NOT up: ..." and contains that substring too, so a looser pattern would
# pass on the exact verdict this case exists to distinguish it from.
assert_match "carrying channel 'telegram' up: gateway: running" "$probe_out" \
  "the probe echoes the status line it decided on"

# The outage this exists for: the gateway answers and says it is not running.
probe telegram "gateway: not running" 0
assert_eq "1" "$probe_rc" "a stopped gateway must probe as NOT reachable, not as running"
assert_match "NOT up" "$probe_out" "the probe says which way it decided"

# ...and the same fact reported the other way a CLI can report it: the query
# itself fails. That is still a determination -- the process a reply is
# delivered to cannot be reached at all.
probe telegram "error: could not connect to the hermes gateway socket" 1
assert_eq "1" "$probe_rc" "a gateway that cannot even answer 'gateway status' is a down return leg"
assert_match "is not answering" "$probe_out" "the probe names what failed, in the operator's terms"

# A build without the subcommand is a CLI-VERSION difference, NOT an outage.
# This branch matters more here than it does for openclaw: nothing in this
# repository has ever run `hermes gateway status` against an installed CLI,
# so the wrong answer for an absent subcommand would be the probe's most
# likely real-world verdict.
probe telegram "hermes: error: argument command: invalid choice: 'gateway'" 2
assert_eq "2" "$probe_rc" "an unsupported subcommand is undetermined, never 'down'"
assert_match "does not support 'gateway status'" "$probe_out" "the probe says why it could not tell"
probe telegram "Usage: hermes [-h] ..." 2
assert_eq "2" "$probe_rc" "a usage banner at the start of a line is also a build without the subcommand"

# Output shaped in a way this probe has never seen against a live gateway ->
# undetermined, with the line quoted. Never rounded up to reachable.
probe telegram "gateway: bewildered" 0
assert_eq "2" "$probe_rc" "an unrecognized status line is undetermined -- doctor prints it as unknown"
assert_match "not one this probe recognizes" "$probe_out" "the probe admits what it does not know"
probe telegram "" 0
assert_eq "2" "$probe_rc" "a subcommand that exits 0 and prints nothing has told us nothing"
assert_match "printed nothing" "$probe_out" "the probe says the output was empty rather than inventing a verdict"

# WHOLE-WORD negatives, against the row with the channel's OWN NAME elided.
# Bare substrings would call a channel named `downtime-alerts` dead and read
# a healthy row mentioning a past shutdown as down -- the false alarm that
# teaches an operator to ignore the one line whose job is to be believed.
probe downtime-alerts "gateway: running, downtime-alerts connected" 0
assert_eq "0" "$probe_rc" "a channel whose NAME contains 'down' is still up -- the name is not a status word"
probe telegram "telegram   connected   (last shutdown 2d ago)" 0
assert_eq "0" "$probe_rc" "'shutdown' inside a connected row must not be read as the status word 'down'"
probe expired-queue "expired-queue   connected" 0
assert_eq "0" "$probe_rc" "a channel whose NAME contains 'expired' is still connected"
# ...and the words this probe exists to catch still catch, as words.
probe telegram "gateway: down (restarting)" 0
assert_eq "1" "$probe_rc" "a row whose status word IS 'down' is still NOT reachable"
probe telegram "gateway: running, credential expired" 0
assert_eq "1" "$probe_rc" "an expired credential still fails the return leg, whole-word matching notwithstanding"
probe telegram "gateway: stopped" 0
assert_eq "1" "$probe_rc" "a stopped gateway is NOT reachable"
# Negatives run FIRST, because "not running" contains the whole word
# "running": a positive-first order would read a dead gateway as up, the one
# mistake this probe must never make.
probe telegram "gateway: not ready (starting)" 0
assert_eq "1" "$probe_rc" "'not ready' is a negation -- the whole word 'ready' inside it must not read as up"
assert_match "NOT up" "$probe_out" "the probe says which way it decided"
# ...and the positive side is held to the same two disciplines.
probe ready-queue "ready-queue   flapping" 0
assert_eq "2" "$probe_rc" "a channel whose NAME contains 'ready' must not invent a REACHABLE verdict out of its own name"
probe telegram "gateway: deactivated" 0
assert_eq "2" "$probe_rc" "a word merely CONTAINING 'active' is not the status word 'active'"
# `inactive` is the exception, and a deliberate one: it is the whole word a
# service manager reports a stopped unit with (`Active: inactive (dead)`), so
# it is spelled out as a negation rather than left to fall through as unknown.
probe telegram "gateway: inactive" 0
assert_eq "1" "$probe_rc" "'inactive' is a negation, never the status word 'active'"
# `up` is deliberately not a positive word: as a whole word it also appears
# in a sentence that says the opposite, and no negation above catches that
# phrasing. Undetermined is the honest answer; REACHABLE would be the worse
# of the two possible errors.
probe telegram "could not bring up the gateway" 0
assert_eq "2" "$probe_rc" "'bring up' must never be read as a gateway that is up"
# A gateway failure that merely quotes the word 'usage' mid-line is still a
# failing return leg, not an unsupported build.
probe telegram "error: gateway refused the request (see usage: hermes gateway)" 1
assert_eq "1" "$probe_rc" "a gateway failure that merely mentions 'usage:' mid-line is still a failing return leg"

# WHICH LINE gets judged. The configured channel's own row is the most
# specific evidence and wins over the gateway headline; judging the whole
# blob instead would let one unrelated platform's row condemn a healthy
# return leg.
probe telegram "$(printf 'gateway: running\ndiscord: connected\ntelegram: disconnected')" 0
assert_eq "1" "$probe_rc" "the configured channel's own row decides, even under a running-gateway headline"
assert_match "telegram: disconnected" "$probe_out" "the probe quotes the row it actually judged"
probe telegram "$(printf 'gateway: running\ndiscord: not connected')" 0
assert_eq "0" "$probe_rc" "an unrelated platform's dead row must not condemn a running gateway"
# ...and a channel hermes does not name at all is absence of evidence, not a
# determination -- unlike openclaw, nothing establishes that `hermes gateway
# status` enumerates platforms, so a missing row must fall through to the
# gateway's own state rather than reporting the return leg dead.
probe telegram "gateway: running" 0
assert_eq "0" "$probe_rc" "a channel the gateway status does not name must not be reported as unreachable on that basis alone"

# ...but a channel the output DOES name, on a line carrying no status word, is
# a different situation and is answered differently ON PURPOSE. Step 1 of the
# ranking is EXCLUSIVE: when any row names the configured channel, those rows
# are the only evidence considered, so an enumeration row wins over the
# gateway headline above it and the verdict is UNDETERMINED. Ranking the tiers
# instead would answer REACHABLE here, and that answer happens to be right in
# this example -- which is exactly why the choice needs pinning rather than
# leaving as a comment somebody later reads as an oversight. It is refused
# because a row that names the channel and says something unreadable is weak
# evidence that this CLI reports per-channel state AND that this channel's
# state is not one of the healthy words; falling through to the gateway would
# invent REACHABLE out of a line that was never understood. A wrong
# "undetermined" costs one manual check; a wrong "reachable" tells an operator
# their answers are landing while every one is dropped.
probe telegram "$(printf 'gateway: running\nplatforms: telegram, discord\n')" 0
assert_eq "2" "$probe_rc" "a row naming the channel with no status word decides the verdict, and it decides UNDETERMINED -- never REACHABLE borrowed from the gateway row above it"
assert_match "not one this probe recognizes" "$probe_out" "the probe says it could not read the row rather than rounding it up"
assert_match "platforms: telegram, discord" "$probe_out" "and quotes the channel row it could not read, not the gateway row it declined to fall back on"
# The GREEN twin, and it is what makes the case above non-vacuous: strike the
# enumeration row and the very same gateway line reads REACHABLE. So the 2
# above is caused by that row, not by a gateway line this probe cannot judge.
probe telegram "gateway: running" 0
assert_eq "0" "$probe_rc" "the same gateway line without the enumeration row is REACHABLE -- the undetermined verdict above is caused by the channel row, not by unreadable gateway output"
# ...and an unrelated platform's dead row still cannot reach any tier, even
# when an enumeration row has already pinned the verdict to the channel tier.
probe telegram "$(printf 'gateway: running\nplatforms: telegram, discord\ndiscord: disconnected\n')" 0
assert_eq "2" "$probe_rc" "a sibling platform's dead row is neither a channel row, a gateway row nor a status label -- it cannot condemn a channel it says nothing about"

# THE SERVICE-MANAGED SHAPE. A gateway supervised by launchd/systemd reports
# through its supervisor: a unit HEADER on the line that names the gateway and
# the actual verdict on an indented label line below it. Picking the gateway
# row and taking its silence for the whole answer reported UNDETERMINED for a
# return leg that is plainly up -- on the deployment shape a long-running
# gateway most commonly has, which is to say on the r-001 setup itself. The
# rows are judged in rank order until one of them decides instead.
probe telegram "$(printf '* hermes-gateway.service - Hermes Gateway\n   Loaded: loaded (/etc/systemd/system/hermes-gateway.service; enabled)\n   Active: active (running) since Mon 2026-08-24 09:14:02 UTC\n')" 0
assert_eq "0" "$probe_rc" "a service-managed gateway whose verdict is on a label line below the unit header is REACHABLE, not undetermined"
assert_match "Active: active .running." "$probe_out" "the probe quotes the label row it actually decided on, not the unit header"
# ...and the same shape reporting the outage reads as the outage, both ways a
# supervisor spells it.
probe telegram "$(printf '* hermes-gateway.service - Hermes Gateway\n   Active: inactive (dead) since Sun 2026-08-23 22:02:41 UTC\n')" 0
assert_eq "1" "$probe_rc" "a service-managed gateway reported inactive is NOT reachable"
probe telegram "$(printf 'Gateway: managed by launchd (com.orchid.hermes)\nState: not running\n')" 0
assert_eq "1" "$probe_rc" "a launchd-managed gateway reported not running is NOT reachable"
# The label tier must not become a back door for the unrelated-platform row
# step 1 exists to keep out: a platform name is not a status label, so a dead
# sibling channel still cannot condemn a running gateway.
probe telegram "$(printf 'Gateway: managed by launchd (com.orchid.hermes)\nState: running\ndiscord: disconnected\n')" 0
assert_eq "0" "$probe_rc" "an unrelated platform's row is not a status label and must not reach the label tier"
# ...and the configured channel's OWN row still outranks every one of them,
# supervisor header or not.
probe telegram "$(printf '* hermes-gateway.service - Hermes Gateway\n   Active: active (running) since Mon 2026-08-24 09:14:02 UTC\n   telegram: disconnected\n')" 0
assert_eq "1" "$probe_rc" "the configured channel's own row still decides, even under a healthy service-managed header"

# No channel configured, and no CLI at all: both undetermined, both saying so.
probe_rc=0
probe_out="$(PATH="$PROBEBIN:$PATH" ORCHID_NOTIFY_CHANNEL="" "$SEND" --inbound-probe 2>&1)" || probe_rc=$?
assert_eq "2" "$probe_rc" "with no channel configured there is nothing to probe"
assert_match "no channel to probe" "$probe_out" "the probe explains the unset-channel case"
EMPTYBIN="$WORK/emptybin"; mkdir -p "$EMPTYBIN"
probe_rc=0
probe_out="$(PATH="$EMPTYBIN:$(dirname "$BASH")" ORCHID_NOTIFY_CHANNEL=telegram \
  "$SEND" --inbound-probe 2>&1)" || probe_rc=$?
assert_eq "2" "$probe_rc" "a missing hermes CLI is undetermined, not 'down'"
assert_match "not on PATH" "$probe_out" "the probe explains the missing-CLI case"

# The probe must SEND NOTHING, ever -- it is invoked by a read-only doctor.
probe telegram "gateway: running" 0
assert_eq "gateway status" "$(cat "$HG_LOG")" \
  "the probe asks hermes exactly one read-only question and nothing else"
# ...and the flag takes no further arguments, so a stray one is a usage
# problem the probe reports rather than half-answering.
probe_rc=0
probe_out="$(PATH="$PROBEBIN:$PATH" ORCHID_NOTIFY_CHANNEL=telegram \
  "$SEND" --inbound-probe extra 2>&1)" || probe_rc=$?
assert_eq "2" "$probe_rc" "--inbound-probe with a trailing argument is undetermined, not a send"

# Adding the probe mode must not have moved the ordinary send path. The probe
# flag is unreachable from the pump's own invocation shape (a qid is always
# `q-<epoch>-<hex>`), so this is the branch that actually runs in production.
cat > "$STUBBIN/hermes" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$H_LOG"
exit 0
EOF
chmod +x "$STUBBIN/hermes"
: > "$H_LOG"
rc=0
env -i PATH="$PATH" ORCHID_NOTIFY_CHANNEL=telegram "$SEND" q-still "q-still: send after the probe mode landed" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "adding the probe mode must not break the ordinary send path (rc=$rc)"
assert_match "^send --to telegram q-still: send after the probe mode landed\$" "$(cat "$H_LOG")" \
  "the send path still composes the same --to target and positional message"

# ===========================================================================
# 7 -- WHAT DOCTOR MAKES OF IT. The probe's exit code is only half the
# feature; the other half is doctor's honesty rules, and they are asserted
# here against the REAL hermes plugin rather than a fixture, because what
# T009 changes is this plugin's own manifest.
#
# Three rules, all of them things doctor got wrong before T006 and must not
# regress now that a second plugin declares a probe:
#   * inbound `ok` comes ONLY from a plugin's own POSITIVE probe;
#   * "cannot determine" is reported as such, never as health -- including
#     for a configured plugin that declares NO probe, which is the negative
#     twin of the hermes case below and is asserted right beside it so the
#     rule is enforced rather than merely intended;
#   * the whole notify block is ADVISORY and can never flip doctor's exit
#     code, because a run with no working channel is entirely legitimate.
# ===========================================================================
mkdir -p "$WORK/eng/fake"; printf '#!/usr/bin/env bash\n' > "$WORK/eng/fake/run"
chmod +x "$WORK/eng/fake/run"
DOC_REPO="$WORK/doctor-repo"; mkdir -p "$DOC_REPO"
(cd "$DOC_REPO" && git init -q . && git commit -q --allow-empty -m root)
# A second notify plugin that declares NO inbound probe -- the negative case.
# Its required binary is `git`, certainly present, so its OUTBOUND line is
# deterministic on any machine and the inbound assertion below is about the
# missing probe alone.
DOC_PLUGINS="$WORK/doctor-plugins"
mkdir -p "$DOC_PLUGINS/notify/noprobe"
printf 'manifest_version=1\nid=orchid-test/noprobe\nversion=0.1.0\nkind=notify\napi_version=1\nrequires_orchid=>=1.0\nentrypoint=send\nrequires_binaries=git\n' \
  > "$DOC_PLUGINS/notify/noprobe/plugin.conf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DOC_PLUGINS/notify/noprobe/send"
chmod +x "$DOC_PLUGINS/notify/noprobe/send"

# doc_doctor <notify.plugin> -> combined doctor output in $doc_out
doc_doctor() {
  printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\nnotify.plugin=%s\nnotify.channel=telegram\n' \
    "$1" > "$DOC_REPO/orchid.config"
  doc_out="$(ORCHID_REPO="$DOC_REPO" HOME="$HOME" PATH="$PROBEBIN:$PATH" \
    ORCHID_ENGINES_DIR="$WORK/eng" ORCHID_PLUGIN_PATH="$DOC_PLUGINS" \
    "$ORCHID_BIN" doctor 2>&1)" || true
}
# "advisory" is the invariant, and doctor's GLOBAL exit code is the wrong way
# to assert it -- it covers every check in the file, so it would couple this
# to whatever else this fixture happens to trip. Assert it on the lines that
# carry the claim instead. Herestring, never `echo | grep -q`: same SIGPIPE/
# pipefail trap helpers.sh documents for assert_match.
assert_doc_advisory() {
  local hits; hits="$(grep -E '^FAIL:.*(notify|return leg)' <<<"$doc_out" || true)"
  [ -z "$hits" ] || fail "$1 (doctor failed on a notify verdict: $hits)"
}

# A running gateway: the one path to a green inbound line, and even it is
# bounded -- the gateway being up is not a channel-side agent existing.
printf 'gateway: running (hermes 0.19.0)\n' > "$HG_OUT"; printf '0' > "$HG_RC"
doc_doctor hermes
assert_doc_advisory "a reachable return leg is reported, never as a doctor failure"
assert_match "^ok: notify inbound \\(the return leg\\): 'hermes' probed its channel and reports it REACHABLE" "$doc_out" \
  "doctor runs THIS plugin's probe and reports its positive verdict"
assert_match "does NOT prove a channel-side agent" "$doc_out" \
  "even a reachable gateway must not be reported as a working answer path"

# The r-001 outage, as doctor would have shown it on day one.
printf 'gateway: not running\n' > "$HG_OUT"; printf '0' > "$HG_RC"
doc_doctor hermes
assert_doc_advisory "a dead return leg is a warning, never a doctor failure"
assert_match "WARN: notify inbound \\(the return leg\\): 'hermes' probed its channel and reports it NOT REACHABLE" "$doc_out" \
  "doctor reports the hermes probe's negative verdict instead of staying silent about it"
assert_match "Answers sent on this channel are being lost" "$doc_out" \
  "doctor names the consequence an operator has to act on"
grep -q "^ok: notify inbound" <<<"$doc_out" \
  && fail "a NOT REACHABLE probe must never produce an inbound ok"

# Cannot determine -> reported as unknown. Never as health.
printf 'gateway: bewildered\n' > "$HG_OUT"; printf '0' > "$HG_RC"
doc_doctor hermes
assert_doc_advisory "an undetermined return leg is a warning, never a doctor failure"
assert_match "WARN: notify inbound \\(the return leg\\): UNDETERMINED" "$doc_out" \
  "a probe that cannot tell is reported as unknown"
assert_match "Reported as unknown rather than ok, deliberately" "$doc_out" \
  "doctor says it is deliberately declining to call an unknown result ok"
grep -q "^ok: notify inbound" <<<"$doc_out" \
  && fail "an undetermined probe must never produce an inbound ok"

# THE NEGATIVE TWIN. A configured notify plugin that declares no probe at all
# must be reported as not verified -- blaming THIS plugin's missing probe,
# never asserting that liveness is unknowable in general, and never as an
# inbound ok. Without this assertion beside the hermes case above, "cannot
# determine is not health" would be an intention rather than a rule: a doctor
# that reported every no-probe plugin green would still satisfy every
# assertion in this file.
doc_doctor noprobe
assert_doc_advisory "an unverifiable return leg is a warning, never a doctor failure"
assert_match "^WARN: notify inbound \\(the return leg\\): NOT VERIFIED" "$doc_out" \
  "doctor reports the inbound leg as unverified rather than implying it from outbound"
assert_match "'noprobe' declares no inbound probe" "$doc_out" \
  "doctor blames the specific plugin's missing probe, not 'nothing can ever be known'"
assert_match "nothing here can tell whether a reply can get back" "$doc_out" \
  "doctor states the cannot-determine fact outright rather than leaving the line to be read as health"
grep -q "^ok: notify inbound" <<<"$doc_out" \
  && fail "with no probe declared, doctor must never report the inbound return leg as ok"
# ...and the outbound half stays a separate fact for that plugin: send
# capability is exactly what it says and never implies the return leg.
assert_match "^ok: notify outbound: 'noprobe' resolves" "$doc_out" \
  "outbound remains its own fact for a plugin that cannot prove the return leg"
assert_match "SEND capability only" "$doc_out" \
  "doctor labels the outbound fact as send capability alone"
