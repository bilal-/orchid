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
# itself fails AND SAYS the transport could not be reached. That is a
# determination -- the process a reply is delivered to cannot be reached at
# all.
probe telegram "error: could not connect to the hermes gateway socket" 1
assert_eq "1" "$probe_rc" "a gateway that cannot even answer 'gateway status' is a down return leg"
assert_match "is not answering" "$probe_out" "the probe names what failed, in the operator's terms"

# A FAILED QUERY IS NOT A DEAD GATEWAY, and the exit code alone must never
# decide which one it was. `hermes gateway status` exiting nonzero says the
# QUESTION failed; only its output can say whether the SUBJECT is down, and
# the two come apart constantly -- a broken install, an unreadable config, a
# permission-denied on the socket path, expired credentials the CLI needs to
# ask at all. Reading any of those as `down` prints "Answers sent on this
# channel are being lost" about a return leg that is carrying answers fine:
# the false alarm every other branch of this probe is built to refuse, and
# the likelier cause of a nonzero exit than a stopped gateway is.
#
# RED half -- the shapes a broken CLI fails with, none of which name the
# transport. Each must be UNDETERMINED, and each must say so rather than
# borrowing the outage's wording.
probe telegram "$(printf 'Traceback (most recent call last):\n  File "/usr/lib/hermes/cli.py", line 3\nModuleNotFoundError: No module named %s\n' "'hermes.gateway'")" 1
assert_eq "2" "$probe_rc" "an interpreter traceback is a broken CLI install, never evidence the gateway is down"
assert_match "not evidence about the gateway" "$probe_out" "the probe says the query broke rather than claiming the return leg did"
grep -q "is not answering" <<<"$probe_out" \
  && fail "a broken query must not borrow the outage message -- that is the false alarm this case exists to prevent"
probe telegram "hermes: error: no configuration found at ~/.hermes/config.yaml -- run 'hermes init'" 1
assert_eq "2" "$probe_rc" "an unconfigured CLI cannot ask the gateway anything, so it has determined nothing about it"
probe telegram "hermes: error: permission denied: /Users/op/.hermes/gateway.sock" 1
assert_eq "2" "$probe_rc" "a permission-denied on the socket path means this CLI may not ask -- the socket is right there, and the gateway may well be serving"
probe telegram "hermes: error: credentials expired, run 'hermes auth login'" 1
assert_eq "2" "$probe_rc" "the CLI's OWN auth expiring is a query it could not make, not a gateway that did not answer"
probe telegram "" 127
assert_eq "2" "$probe_rc" "a nonzero exit with no output at all has said nothing, and nothing is not 'down'"
assert_match "no output" "$probe_out" "the probe says the failing query printed nothing rather than inventing a line for it"
# ...and `expired` is exactly where the two paths part company, which is what
# makes the case above a distinction rather than a blanket softening: the same
# word in a status row hermes SUCCESSFULLY printed is still the outage,
# because there it is hermes reporting the channel's credential, not the CLI
# reporting its own. (The rc=0 twin is asserted further down.)
#
# GREEN half -- a failing query that DOES name the transport still decides,
# so this branch has not been softened into never determining anything.
probe telegram "error: connection refused (gateway socket /run/hermes.sock)" 1
assert_eq "1" "$probe_rc" "a connection refused by the gateway socket is a determination, not a shrug"
assert_match "is not answering" "$probe_out" "the probe still names the outage when the output actually names the transport"
probe telegram "hermes: error: the gateway is not running (start it with 'hermes gateway up')" 1
assert_eq "1" "$probe_rc" "a CLI that says outright the gateway is not running has determined the return leg is down"
probe telegram "error: gateway process is not responding after 30s" 1
assert_eq "1" "$probe_rc" "a gateway that stopped responding is a down return leg"
# ...and that list is held to the same whole-word, name-elided discipline as
# the per-row negatives, for the same reason: without it a channel named
# `downtime-alerts` is condemned by its own name on any CLI hiccup.
probe downtime-alerts "hermes: error: could not read ~/.hermes/config.yaml for downtime-alerts" 1
assert_eq "2" "$probe_rc" "a channel whose NAME contains 'down' must not turn a broken config read into an outage"

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

# ...BUT THAT PRECEDENCE RANKS THE ROW'S STATE, NOT EVERY WORD IN IT, and
# applying it to the whole row unconditionally was a false-alarm defect of
# exactly the kind the whole-word rule above exists to prevent -- one word
# further out. A supervised gateway reports the LAST outage beside the
# CURRENT state, because that is what a status row is for; a negative-first
# order with no notion of history reads every one of those healthy rows as
# the outage, and doctor prints "Answers sent on this channel are being lost"
# about a channel that is carrying answers fine. Whole words do not reach it:
# `last shutdown` (pinned above) is a substring, while `last disconnected` is
# genuinely the word, sitting in a row whose state word is `connected`.
#
# RED -- the two shapes that were read as NOT up while saying outright they
# were up. The record qualifiers are the ones the live-pid tier already
# refuses a `last pid`/`was pid` on; the word tests simply never learned them.
probe telegram "telegram: connected (last disconnected 2026-08-27, 4 reconnects)" 0
assert_eq "0" "$probe_rc" "a healthy row that also reports its LAST outage is reachable -- a record is not the current state"
grep -q "NOT up" <<<"$probe_out" \
  && fail "a past disconnection must not outrank the 'connected' the same row states -- that is the false alarm this case exists to prevent"
assert_match "up: telegram: connected" "$probe_out" "the probe quotes the row verbatim, elision notwithstanding"
probe telegram "hermes-gateway: running (pid 4242, last down 2d ago)" 0
assert_eq "0" "$probe_rc" "'last down' in a running supervisor row is history, not the gateway's state"
# GREEN -- and it is not a blanket softening in either direction. An
# UNQUALIFIED negative still convicts even when the row's history is the
# healthy half, which is the mirror image of the two cases above.
probe telegram "telegram: disconnected (last connected 2026-08-27)" 0
assert_eq "1" "$probe_rc" "the outage still decides when it is the row's state and the healthy word is the record"
assert_match "NOT up" "$probe_out" "the probe says which way it decided"
probe telegram "hermes-gateway: down (last running 2d ago)" 0
assert_eq "1" "$probe_rc" "a gateway that is down now is down, whatever it was running 2d ago"
# ...and a row carrying NOTHING BUT history has not said what is true now, so
# it decides neither way. Undetermined costs an operator one manual check;
# either verdict invented from a record would be a claim the row never made.
probe telegram "gateway: last stopped 2d ago" 0
assert_eq "2" "$probe_rc" "a row that reports only a past outage has not reported the present one"
assert_match "not one this probe recognizes" "$probe_out" "the probe admits it could not read the row rather than convicting on the record"
probe telegram "hermes-gateway: was running" 0
assert_eq "2" "$probe_rc" "...and the same rule in the direction that matters more: 'was running' is not running, and must never read as health"
grep -q "carrying channel 'telegram' up:" <<<"$probe_out" \
  && fail "a historical positive must not be read as a live return leg -- that is the worse of the two errors"
# ...and the live-pid tier is deliberately NOT given the benefit of the
# record rule, because it is the weakest evidence this probe accepts as
# health: eliding the negation would leave it a bare live pid and nothing
# saying "no", which is the exact false REACHABLE the particle guard closed.
probe telegram "hermes-gateway: com.hermes.gateway (pid 4242, was not responding)" 0
assert_eq "2" "$probe_rc" "the pid tier reads the unelided row, so a negation it cannot rank still stops it short of health"

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
probe telegram "error: gateway is not responding (see usage: hermes gateway)" 1
assert_eq "1" "$probe_rc" "a gateway failure that merely mentions 'usage:' mid-line is still a failing return leg"

# `refused` IS ONLY EVIDENCE WITH ITS SUBJECT ATTACHED, and a bare one used to
# sit in the failed-query list -- quietly re-opening the conflation the whole
# block above closes. On its own the word is what a query failing for reasons of
# ITS OWN says: a policy turning the CLI away, an authentication rejected, a
# token missing a scope. None of them is the gateway failing to answer, and
# reading them as `down` prints "Answers sent on this channel are being lost"
# about a return leg carrying answers fine.
probe telegram "hermes: error: request refused: token lacks scope 'gateway:read'" 1
assert_eq "2" "$probe_rc" "a request refused for the CLI's own lack of scope is a query that was turned away, not a gateway that did not answer"
assert_match "not evidence about the gateway" "$probe_out" "the probe says the query broke rather than claiming the return leg did"
probe telegram "hermes: error: authentication refused by ~/.hermes/config.yaml" 1
assert_eq "2" "$probe_rc" "an authentication refused is the CLI being turned away, and it has determined nothing about the gateway"
# The GREEN twin, and it is what keeps that removal from being a blanket
# softening: `connection refused` names the transport -- it is the kernel's own
# words for nothing listening on the other end -- and still decides.
probe telegram "hermes: error: connection refused by /Users/op/.hermes/gateway.sock" 1
assert_eq "1" "$probe_rc" "'connection refused' still names the transport and still determines the return leg is down"
assert_match "is not answering" "$probe_out" "the probe still names the outage when the refusal names the transport"

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

# WHAT AN INSTALLED CLI ACTUALLY PRINTED, and the two defects it exposed. Every
# case above this line was written against output nobody had ever seen. The
# operator finally ran `hermes gateway status` against a real installation and
# it answered, exiting 0, with one row per subject:
#     Gateway: not running
#     WhatsApp: not paired
# The probe said UNDETERMINED. Both of those lines name the outage, one of them
# in the plainest words this file already knew, and the verdict was a shrug --
# on the single piece of real evidence this probe has ever been handed. So this
# exact output is pinned, byte for byte, as the case that must never regress.
probe whatsapp "$(printf 'Gateway: not running\nWhatsApp: not paired\n')" 0
assert_eq "1" "$probe_rc" "the two-line output an installed hermes actually printed reports the return leg as down -- it named the outage on both of its lines and the probe answered undetermined"
assert_match "NOT up" "$probe_out" "the probe says which way it decided"

# DEFECT ONE: THE VOCABULARY. hermes reports a platform's return leg as an
# ATTACHMENT, not only as a process state -- and `paired` was in neither list,
# so the channel row (which step 1 makes the only evidence for health when it
# exists) decided nothing. An unpaired channel delivers no reply to anybody;
# that is a determination, not an unreadable line.
probe whatsapp "WhatsApp: not paired" 0
assert_eq "1" "$probe_rc" "'not paired' is a determination -- a channel not attached to the gateway carries no reply under any gateway state"
assert_match "WhatsApp: not paired" "$probe_out" "the probe quotes the row it judged"
# ...and the pairing words are negations ONLY, never positives, which is the
# half that keeps this from becoming a false REACHABLE: `paired` is a stored
# fact about what the operator once attached, and a gateway reports it whether
# or not the gateway is currently running. Its negation carries no such
# ambiguity; the bare word does, so it stays unreadable.
probe whatsapp "WhatsApp: paired" 0
assert_eq "2" "$probe_rc" "a bare 'paired' is a stored attachment, not a live return leg -- reading it as health is the false REACHABLE this file refuses"
# ...and it is held to the same whole-word, name-elided discipline as every
# other negative, so a channel named for the word is not condemned by its name.
probe paired-alerts "paired-alerts   connected" 0
assert_eq "0" "$probe_rc" "a channel whose NAME contains 'paired' is still connected -- the name is not a status word"
# ...and the pairing words join `expired`/`unauthor*` on the OTHER side of the
# success/failed-query line, which is the asymmetry that keeps the vocabulary
# widening above from leaking into the branch it was never about. On a query
# that FAILED, the CLI reported nothing successfully, so the very same words
# are as likely to be its own attachment failing as the gateway's -- and
# reading that as `down` is the false alarm the failed-query branch exists to
# refuse. Undetermined, with the line quoted.
probe whatsapp "hermes: error: WhatsApp is not paired" 1
assert_eq "2" "$probe_rc" "'not paired' out of a query that FAILED is the CLI's own attachment, not a gateway that did not answer"
assert_match "not evidence about the gateway" "$probe_out" "the probe says the query broke rather than claiming the return leg did"
# The GREEN twin, and it is what makes that a distinction rather than a hole:
# the identical words in a row hermes SUCCESSFULLY printed still decide, exactly
# as the `WhatsApp: not paired` case at the top of this block does -- so the
# exclusion is about which path the words arrived on, never about the words.
probe whatsapp "WhatsApp: is not paired" 0
assert_eq "1" "$probe_rc" "the same wording on the success path is still the outage -- the failed-query exclusion is about the path, not the vocabulary"

# DEFECT TWO: THE RANKING, which is the same misread one level up and the one
# that matters for every hermes phrasing of "not attached" nobody has seen yet.
# Step 1 stays exclusive FOR HEALTH: a channel row this probe cannot read must
# not be rounded up by the gateway row above it. Nothing about that argument
# says an unreadable channel row may HIDE a gateway row that plainly reports the
# outage -- and treating it as if it did is what turned two lines of unambiguous
# evidence into a shrug. So the weaker tiers are consulted after the channel tier
# comes up empty, and they may only convict.
probe whatsapp "$(printf 'Gateway: not running\nplatforms: whatsapp, telegram\n')" 0
assert_eq "1" "$probe_rc" "a channel row this probe cannot read must not hide a gateway row that says the return leg is down"
assert_match "Gateway: not running" "$probe_out" "the probe quotes the gateway row it convicted on"
# The GREEN twin, and it is the whole point of the asymmetry: the SAME shape
# with the gateway row reporting health stays UNDETERMINED. The second pass
# convicts and never acquits, so REACHABLE still comes only from the most
# specific tier that exists.
probe whatsapp "$(printf 'Gateway: running\nplatforms: whatsapp, telegram\n')" 0
assert_eq "2" "$probe_rc" "the second pass may only convict -- a healthy gateway row must not acquit a channel row that was never understood"
assert_match "platforms: whatsapp, telegram" "$probe_out" "and the quoted line is still the most specific candidate, not the row the pass declined to borrow"
# ...and a sibling platform's dead row reaches no tier in either pass, so the
# second pass is not a back door into the property step 1 exists to protect.
probe whatsapp "$(printf 'Gateway: running\nplatforms: whatsapp, telegram\ndiscord: disconnected\n')" 0
assert_eq "2" "$probe_rc" "the second pass judges the gateway/label tiers, never an unrelated platform's row"
# ...including through the LAST-RESORT tier, which the second pass is not given
# at all. That tier reads a first line naming no subject of its own as the
# gateway's state, which holds when the output named nothing else either -- but
# once a channel row exists the output has demonstrated it names a subject per
# row, and an unlabelled first line is then likelier a sibling platform's than
# the gateway's own. Admitting it would let one platform's dead row condemn
# another platform's return leg, which is exactly what step 1 is exclusive for.
probe whatsapp "$(printf 'discord disconnected\nwhatsapp pending\n')" 0
assert_eq "2" "$probe_rc" "an unlabelled sibling row must not convict through the second pass -- the last-resort tier is not part of it"
assert_match "whatsapp pending" "$probe_out" "and the quoted line is the channel row this probe could not read"

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

# THE LAUNCHD SHAPE, which is the same problem one step further in. A gateway
# run under launchd is named by its JOB LABEL, and a job label is a hyphen- or
# dot-joined compound: 'hermes-gateway', 'com.hermes.gateway'. A boundary that
# refused a hyphen on the left matched no tier at all for the plainest healthy
# output there is -- not a gateway row (the hyphen sits before the word), not a
# status label (the label is the whole compound), and not the last-resort first
# line (it is a labelled row, so that tier declines it) -- and answered
# UNDETERMINED about a gateway that says it is running.
probe telegram "hermes-gateway: running (launchd, pid 4242)" 0
assert_eq "0" "$probe_rc" "a hyphen-joined job label still names the gateway -- 'hermes-gateway' is not a different subject from 'gateway'"
assert_match "up: hermes-gateway: running" "$probe_out" "the probe quotes the label row it decided on"
# ...and the RED half of that same widening: the identical label reporting the
# outage is read as the outage, not left as unknown.
probe telegram "hermes-gateway: not running" 0
assert_eq "1" "$probe_rc" "the same job label reporting the outage is NOT reachable, not undetermined"
assert_match "NOT up" "$probe_out" "the probe says which way it decided"
# The boundary is ASYMMETRIC on purpose and this is the case that pays for it:
# a token merely STARTING with 'gateway' is a name headed by something else,
# and must not decide this channel's return leg any more than a sibling
# platform's row may. Both directions, because the second is the worse error.
probe telegram "gateway-alerts: disconnected" 0
assert_eq "2" "$probe_rc" "a name that merely starts with 'gateway' is a different subject and cannot condemn the return leg"
assert_match "not one this probe recognizes" "$probe_out" "the probe says it could not read the line rather than borrowing another subject's verdict"
probe telegram "gateway-alerts: connected" 0
assert_eq "2" "$probe_rc" "and that subject being up is not this gateway being up"
# ...and the left side is widened to THIS CLI's own name, not to any qualifier
# at all: a sibling platform's own gateway row is still a row about another
# subject, and the healthy direction is the worse one to get wrong.
probe telegram "discord-gateway: connected" 0
assert_eq "2" "$probe_rc" "a sibling platform's gateway is not the gateway carrying this channel"
probe telegram "discord-gateway: disconnected" 0
assert_eq "2" "$probe_rc" "...in the other direction too -- it cannot condemn a channel it says nothing about"

# A LIVE PROCESS ID IS THE OTHER HEALTHY LAUNCHD SHAPE. A supervisor answers
# "is it up" with the process it is supervising, and launchd publishes a pid
# only for a job that is actually running -- so a row naming the gateway and a
# live pid has reported health even though it contains none of the status
# words above.
probe telegram "hermes-gateway: com.hermes.gateway (pid 4242)" 0
assert_eq "0" "$probe_rc" "a gateway row carrying a live process id is REACHABLE -- the pid is the supervisor's answer"
probe telegram '"Label" = "com.hermes.gateway"; "PID" = 4242;' 0
assert_eq "0" "$probe_rc" "the plist spelling a supervisor query prints reads the same as a bare 'pid 4242'"
# ...and the three things that keep that tier from inventing REACHABLE, each
# pinned, because every one of them is the difference between reading health
# and asserting it. (1) A pid that is a PLACEHOLDER is not a running process.
probe telegram "hermes-gateway: com.hermes.gateway (pid -)" 0
assert_eq "2" "$probe_rc" "a placeholder where the pid would be is not a running process"
probe telegram "hermes-gateway: com.hermes.gateway (pid 0)" 0
assert_eq "2" "$probe_rc" "a zero pid is not a running process either"
# (2) A HISTORICAL pid is a record of a process that is gone.
probe telegram "hermes-gateway: com.hermes.gateway (last pid 4242)" 0
assert_eq "2" "$probe_rc" "a last-pid record is a process that has gone, never evidence the gateway is up"
# ...including when the row spells the deadness with the supervisor's own
# vocabulary, which is why those words are negations: negatives are judged
# first, so the pid in the same line cannot be read as health.
probe telegram "hermes-gateway: dead (pid 4242 reaped)" 0
assert_eq "1" "$probe_rc" "a dead gateway is NOT reachable, whatever process id its row still carries"
probe telegram "hermes-gateway: crashed (pid 4242)" 0
assert_eq "1" "$probe_rc" "a crashed gateway is NOT reachable, whatever process id its row still carries"
probe telegram "hermes-gateway: stopped (pid 4242)" 0
assert_eq "1" "$probe_rc" "the negatives are judged before the pid, so a stopped row stays the outage"
# 'loaded' is negated but never positive on its own: launchd and systemd both
# call a STOPPED job loaded, so the word says the supervisor knows about the
# gateway, not that it is running.
probe telegram "hermes-gateway: not loaded" 0
assert_eq "1" "$probe_rc" "'not loaded' is a negation the positives must not read as up"
probe telegram "hermes-gateway: loaded" 0
assert_eq "2" "$probe_rc" "...and a bare 'loaded' is a supervisor knowing about the job, not the job running"
# (3) The tier is only reachable on a row an earlier tier ADMITTED, so a
# sibling platform carrying a pid still cannot decide this channel's return
# leg -- the property step 1 is exclusive for, held across the new tier.
probe telegram "discord: connected (pid 4242)" 0
assert_eq "2" "$probe_rc" "a sibling platform's live pid is not this channel's return leg being up"
probe telegram "$(printf 'hermes-gateway: running (pid 4242)\ndiscord: disconnected\n')" 0
assert_eq "0" "$probe_rc" "an unrelated platform's dead row still cannot condemn a job label that reports running"
probe telegram "$(printf 'hermes-gateway: running (pid 4242)\ntelegram: disconnected\n')" 0
assert_eq "1" "$probe_rc" "and the configured channel's own row still outranks the job label above it"

# THE RESPONSIVENESS WORDS, AND THE LIVE-PID FALSE REACHABLE THEIR ABSENCE
# PRODUCED. The failed-query list has read `not responding`, `not listening`,
# `not alive` and `unresponsive` as evidence about the transport since it was
# written; the per-row list had never learned them. So this exact row --
# hermes exiting 0 and saying outright that the gateway it supervises is not
# answering -- matched no negative, matched no positive, and was then read as
# HEALTH by the pid tier above, which is the one verdict this whole file is
# ordered to make impossible. Every assertion here is the CONFIRMED shape,
# with the pid attached, because the pid is what turned a shrug into a lie.
probe telegram "hermes-gateway: not responding (pid 4242)" 0
assert_eq "1" "$probe_rc" "a gateway that says it is not responding is NOT reachable, and its live pid must not overturn its own words"
assert_match "NOT up" "$probe_out" "the probe says which way it decided"
grep -q "carrying channel 'telegram' up:" <<<"$probe_out" \
  && fail "the live-pid tier must never report a not-responding row as up -- that is the false REACHABLE this case exists to prevent"
# ...and the same words without a pid, so the vocabulary is pinned on its own
# rather than only through the tier it was rescuing.
probe telegram "hermes-gateway: not responding" 0
assert_eq "1" "$probe_rc" "'not responding' is a determination whether or not the row carries a process id"
probe telegram "hermes-gateway: unresponsive (pid 4242)" 0
assert_eq "1" "$probe_rc" "'unresponsive' is the standalone form of the same fact"
probe telegram "hermes-gateway: not listening (pid 4242)" 0
assert_eq "1" "$probe_rc" "a gateway process that is not listening carries no reply back, pid or no pid"
probe telegram "hermes-gateway: not alive (pid 4242)" 0
assert_eq "1" "$probe_rc" "'not alive' is the third phrasing the failed-query list already knew and this one did not"
# `no longer` is the failed-query list's own third negation prefix, and it puts
# a state word this list already knew behind one it did not.
probe telegram "hermes-gateway: no longer running (pid 4242)" 0
assert_eq "1" "$probe_rc" "'no longer running' is the outage, not a live process id"
# `up` is negated even though it is refused as a positive: `not up` says one
# thing only, while a bare `up` also occurs in `could not bring up the gateway`
# (pinned above). The two rulings agree rather than conflict.
probe telegram "gateway: not up" 0
assert_eq "1" "$probe_rc" "'not up' is unambiguous in the direction a bare 'up' is not"

# THE GUARD THAT DOES NOT DEPEND ON A WORD LIST BEING COMPLETE. Closing the
# vocabulary gap above fixes the phrasings hermes was actually observed using;
# it does nothing for the next one nobody here has seen. So the pid tier --
# the weakest evidence this probe accepts as health, circumstantial with no
# state word in it at all -- now declines any row carrying a negation
# particle. An unknown negation is a row this probe has not understood, and
# unread is UNDETERMINED, never REACHABLE.
probe telegram "hermes-gateway: com.hermes.gateway (pid 4242, never finished bootstrapping)" 0
assert_eq "2" "$probe_rc" "a negation this probe cannot read must not be overruled by the pid beside it -- undetermined, never up"
assert_match "not one this probe recognizes" "$probe_out" "the probe admits it could not read the row rather than reading the pid as health"
probe telegram "hermes-gateway: com.hermes.gateway (pid 4242) -- cannot serve inbound replies" 0
assert_eq "2" "$probe_rc" "'cannot' is a particle that can only negate, so the row stops short of health"
probe telegram "hermes-gateway: com.hermes.gateway (pid 4242, unable to bind the inbound socket)" 0
assert_eq "2" "$probe_rc" "...and so is 'unable'"
# A BARE `no` IS DELIBERATELY NOT A PARTICLE, and this is the GREEN half that
# says why: `no errors` is how a healthy supervised row reports a clean run,
# and blocking it would trade the false REACHABLE above for a false
# undetermined on the commonest healthy shape there is.
probe telegram "hermes-gateway: com.hermes.gateway (pid 4242, no errors)" 0
assert_eq "0" "$probe_rc" "a clean-run report is not a negation -- the pid tier still reads a healthy supervised row as up"
# ...and the guard is NOT extended to the word-positive tier above it, because
# a row that states `running` outright has said the thing, and the negatives
# now cover `(not|never|no longer) <word>` for every word that tier matches.
probe telegram "hermes-gateway: running (launchd, pid 4242, not paused)" 0
assert_eq "0" "$probe_rc" "a gateway that says it is running stays REACHABLE -- the particle guard belongs to the pid tier, not to a stated state"

# THE LAST-RESORT TIER, and the subject it may not borrow. Output carrying no
# channel row, no gateway row and no status label still deserves a reading --
# a `gateway status` answering with the bare word `running` has said
# something, and refusing to read it would report UNDETERMINED for output that
# could not be plainer.
probe telegram "running" 0
assert_eq "0" "$probe_rc" "output that is nothing but a state word is that state -- the first line is the last-resort tier and it does determine"
probe telegram "not running" 0
assert_eq "1" "$probe_rc" "...and the same tier reads the negation as the outage, not as the word inside it"
# ...but that tier is held to the SAME property step 1 is exclusive for. The
# first line is only admitted when it names no subject of its own: a
# `<word>:` row whose label the status-label tier above already declined to
# recognize names something else, and on a CLI nobody here has ever observed
# it is as likely to be a sibling platform's row as the gateway's own state.
# Admitting it unconditionally hands the verdict to whatever happens to be
# printed first -- which is how a row that never mentions the configured
# channel ends up deciding that channel's return leg. Both directions, because
# the two errors are not equal and the worse one is the second:
probe telegram "discord: disconnected" 0
assert_eq "2" "$probe_rc" "a sibling platform's row must not condemn a channel it says nothing about, even when it is the only line printed"
assert_match "not one this probe recognizes" "$probe_out" "the probe says it could not read the output rather than borrowing another channel's verdict"
assert_match "discord: disconnected" "$probe_out" "and still quotes the line it was looking at -- quoting is not judging"
probe telegram "discord: connected" 0
assert_eq "2" "$probe_rc" "and the worse error is refused the same way: a sibling platform being up is not this channel's return leg being up"

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

# ...and the SAME outage in the wording a supervised gateway reports it with,
# driven the whole way to the line an operator reads. The probe-level assertion
# above pins the exit code; this pins the consequence, which is the half that
# was wrong: a gateway saying `not responding` while its supervisor still names
# a pid used to reach doctor as `ok: notify inbound ... REACHABLE`, telling an
# operator their answers were landing on the exact return leg that was dropping
# every one of them.
printf 'hermes-gateway: not responding (pid 4242)\n' > "$HG_OUT"; printf '0' > "$HG_RC"
doc_doctor hermes
assert_doc_advisory "a gateway that is not responding is a warning, never a doctor failure"
assert_match "WARN: notify inbound \\(the return leg\\): 'hermes' probed its channel and reports it NOT REACHABLE" "$doc_out" \
  "doctor reports the outage for a supervised gateway that says it is not responding"
assert_match "Answers sent on this channel are being lost" "$doc_out" \
  "doctor names the consequence for this phrasing too, not only for 'not running'"
grep -q "^ok: notify inbound" <<<"$doc_out" \
  && fail "a live pid beside 'not responding' must never reach the operator as an inbound ok"

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

# ===========================================================================
# 8 -- THE PAGE'S ATTEMPT LINE NAMES THE ROUND BEING DECIDED (T009).
#
# The page body's whole purpose is to let an operator line the message on
# their phone up against the evidence in the repo, and `attempt:` is the line
# that does it. `attempts` in the task's frontmatter counts attempts already
# CHARGED, so rendering it verbatim named the round BEFORE the one being
# decided -- and named `attempt: 0`, a round that does not exist, for every
# task raising its first boundary. Meanwhile the artifacts of that round are
# all filed under `attempts + 1`: `jobs prepare`'s job ids, the reviewer
# envelopes at `<task>-a<n>-<role>.json`, and lib/review.sh's
# review_plan_attempt(). An operator following the page to the evidence
# looked one round short every time.
#
# This lives here rather than beside the rest of the page-body assertions in
# tests/test_notify_channel.sh because this task's verification runs THIS
# file; that file's section 10 owns the page's full shape and asserts the
# same values from the other end.
# ===========================================================================
# The full chain lib/review.sh's own header requires, so review_plan_attempt()
# below is the REAL function rather than a re-derivation of the formula this
# section exists to hold the page to (the top of this file already sourced
# common/manifest/roles/resolver/capsuite/ledger).
source "$REPO_ROOT/lib/frontmatter.sh"; source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/review.sh"
PAGE_REPO="$WORK/page-repo"; mkdir -p "$PAGE_REPO/.orchid/tasks"
(cd "$PAGE_REPO" && git init -q . && git commit -q --allow-empty -m root)

# page_orchid <verb...> -- the fixture's invocation shape, shared so the
# `task create` that seeds the counter and the `notify` that renders it can
# never disagree about which repo or engine set they are talking about. The
# roles resolve to section 7's `fake` engine for the same reason doc_doctor
# above uses it: `task create` seeds `engine:` from resolve_role, and this
# section is about the attempt line, not about role routing.
#
# ORCHID_EPOCH is read here rather than captured once because BOTH verbs this
# helper runs are epoch-fenced (`task create` via libexec/orchid-task's create
# arm, `notify` at the top of libexec/orchid-notify) and this file never mints
# an epoch of its own -- it has no `run start`, so ORCHID_EPOCH is unset and
# epoch_require compares '' against the fixture's current 0 and refuses every
# verb. Re-reading through epoch_current() on each call, instead of hard-wiring
# the 0 this fixture happens to sit at, means a verb that later rolls the epoch
# cannot strand the calls after it -- the same reason the runners export it
# from the repo rather than from their own environment.
page_orchid() {
  ORCHID_REPO="$PAGE_REPO" ORCHID_EPOCH="$(epoch_current "$PAGE_REPO")" \
    HOME="$HOME" ORCHID_ENGINES_DIR="$WORK/eng" \
    "$ORCHID_BIN" "$@"
}
# page_attempt <task-id> -> the page's `attempt:` line in $page_attempt_line
# ("" when the page carries none), with the whole page in $page_out. Both are
# pre-seeded because this file runs under `set -u`: if `notify` ever failed,
# the early return below would leave them unset and the READ would abort the
# whole file, hiding every assertion after it behind a bare unbound-variable
# error instead of the FAIL that was already recorded.
page_out=""; page_attempt_line=""
page_attempt() {
  local qid
  qid="$(page_orchid notify --task "$1" "decide it")" \
    || { fail "orchid notify must raise a blocker for $1"; return 0; }
  page_out="$(cat "$PAGE_REPO/.orchid/runtime/outbox/$qid")"
  page_attempt_line="$(grep -E '^attempt: ' <<<"$page_out" || true)"
}

printf 'notify.channel=telegram\nrole.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' \
  > "$PAGE_REPO/orchid.config"
page_orchid task create T900 "name the round" >/dev/null \
  || fail "fixture task for the attempt-line section must be creatable"
assert_eq "0" "$(fm_get "$PAGE_REPO/.orchid/tasks/T900.md" attempts)" \
  "the fixture starts where every task starts: no attempt charged yet"

# RED. A task with nothing charged is on its FIRST attempt, and the page must
# say so. `attempt: 0` is the defect: a round number no artifact in the repo
# is filed under, printed on the line whose only job is to point at them.
page_attempt T900
assert_eq "attempt: 1" "$page_attempt_line" \
  "a task with attempts=0 is paging its FIRST attempt -- the page must never say 'attempt: 0'"

# GREEN, and it is what makes the RED half non-vacuous: the same page against
# a charged counter tracks it, rather than being hard-wired to 1.
fm_set "$PAGE_REPO/.orchid/tasks/T900.md" attempts 4
page_attempt T900
assert_eq "attempt: 5" "$page_attempt_line" \
  "with four attempts charged the page names the fifth -- the round being decided, not the last one finished"
# ...and that is exactly the number this round's reviewer envelopes are filed
# under, which is the whole reason the line exists.
assert_eq "5" "$(review_plan_attempt "$PAGE_REPO" T900)" \
  "the page's round number IS the one review_plan_attempt() files this round's envelopes under"

# A counter that cannot be read omits the line rather than inventing a round
# for it. review_plan_attempt() must answer 1 there because it NAMES A FILE;
# a page has a third option a filename does not, and saying nothing is the
# honest one.
fm_set "$PAGE_REPO/.orchid/tasks/T900.md" attempts "many"
page_attempt T900
assert_eq "" "$page_attempt_line" \
  "a garbled attempts counter omits the line -- the page never renders a round number the task file did not state"
assert_match "^task: T900 — name the round\$" "$page_out" \
  "...and the rest of the body is unaffected, so the omission is the attempt line alone"

# ===========================================================================
# 9 -- A BLOCKED TASK'S PAGE STATES ITS CAUSE, AND DECLARES EVERY RECOVERY
#      THE KERNEL OFFERS OUT OF THAT STATE (T009).
#
# `blocked` is the one status the driver re-reports on EVERY pass until a human
# acts, so its page is the message an operator meets over and over -- and it
# said only "task is blocked", which is the status restated, not a cause. The
# operator was then asked to choose between `unblock` (record guidance),
# `retry` (grant a round) and `reverify` (re-run verification alone), three
# remedies that differ by exactly the thing the page left out. Worse, the
# declared answer set named only two of the three, and `orchid answer` refuses
# everything outside a declared set: an operator who read the reason text, took
# the verb it pointed at and answered `reverify` was told their answer was
# invalid. A page that contradicts itself is worse than the bare `<choice>`
# placeholder this whole feature retired.
#
# Both halves live here, beside section 8's attempt line, for the same reason
# that section gives: this task's verification runs THIS file.
# ===========================================================================
# The same prerequisite chain tests/test_drive.sh sources before this library;
# everything but drive.sh itself is already sourced above. Sourced rather than
# re-derived so the values asserted below are the ones the driver really
# declares -- a hand-copied set here would pass while the page shipped another.
source "$REPO_ROOT/lib/drive.sh"

# --- 9a: the cause, read back from the journal that recorded the block ------
# THE FIXTURE IS BUILT BY THE REAL PRODUCERS. `orchid task advance <id> blocked
# --reason "..."` is the verb that records a block, and a hand-written journal
# here would pin this reader to a format nothing else has to keep. So every
# entry below is written by the kernel, and each fixture step is witnessed
# before it is read from.
page_orchid task create T901 "state the cause" >/dev/null \
  || fail "fixture task for the blocked-cause section must be creatable"
page_orchid task advance T901 blocked --reason "the hermes gateway was down and the answer was lost" >/dev/null \
  || fail "fixture: blocking T901 with a reason must succeed, or there is no journal entry to read back"

# RED. The cause the block was recorded with comes back, verbatim. This string
# appears nowhere else on the page, so a reason text that merely repeated the
# remedy list -- the defect -- fails here.
assert_eq "the hermes gateway was down and the answer was lost" \
  "$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T901)" \
  "a blocked task's cause is the reason its block was journaled with, not the status restated"

# ...and a PAGE for the same task does not become the next page's cause. This
# is the edge that makes matching on the entry's KIND wrong: `orchid notify`
# journals its own text under kind `blocker`, the very kind `task advance`
# uses for a block, so a kind-keyed reader would quote the previous page back
# as though it were a cause. The `<from> -> blocked: ` prefix is what tells
# them apart, and the notify below is a real one, minted by the real verb.
qid_collide="$(page_orchid notify --task T901 "judgment boundary [blocked-task] needs an operator")" \
  || fail "fixture: raising a page against T901 must succeed, or the collision below is untested"
# The heading immediately above the page's own body line, so the witness is
# about THAT entry's kind and not about the block's entry, which carries the
# same one.
assert_match "^## .* T901 blocker" \
  "$(grep -B1 -F "$qid_collide: judgment boundary" "$PAGE_REPO/.orchid/journal.md" || true)" \
  "fixture witness: orchid notify really does journal its page under kind 'blocker' — the same kind a block uses, which is why this reader cannot key on the kind"
assert_eq "the hermes gateway was down and the answer was lost" \
  "$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T901)" \
  "a previous PAGE journaled under kind 'blocker' is not a cause — the reader selects on the transition's shape, not its kind"

# The MOST RECENT block wins: a task can be blocked, worked and blocked again,
# and the cause an operator is being asked about is the current one.
page_orchid task advance T901 blocked --reason "verify failed for something the candidate never caused" >/dev/null \
  || fail "fixture: re-blocking T901 must succeed, or 'most recent wins' is untested"
assert_eq "verify failed for something the candidate never caused" \
  "$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T901)" \
  "the cause is the LATEST block on record, not the first one the journal ever saw"

# GREEN, the honest negative: a task that IS blocked while the journal holds no
# record of why. INV-08 closes the obvious door -- `task advance <id> blocked`
# demands `--reason`, asserted below rather than assumed, so no block taken
# through the verb is ever causeless -- but the record is not indestructible:
# a journal that was rotated, truncated or restored short, or a task file
# carried in from another run, leaves exactly this state. The reader says
# nothing there rather than inventing something, which is what lets
# runners/orchid-drive's blocked arm say "the journal records no cause" instead
# of printing an empty clause after a colon.
page_orchid task create T902 "blocked with nothing on record" >/dev/null \
  || fail "fixture task for the no-cause case must be creatable"
rc902=0
page_orchid task advance T902 blocked >/dev/null 2>&1 || rc902=$?
[ "$rc902" -ne 0 ] \
  || fail "fixture witness: a block with no --reason must be refused (INV-08) — if it were accepted, the empty-cause branch would have a second and much commoner source than a lost record"
# So the state is reached the only way it is reachable: the status without the
# entry. `fm_set` is the same direct write section 8 above uses on `attempts`.
fm_set "$PAGE_REPO/.orchid/tasks/T902.md" status blocked
assert_eq blocked "$(fm_get "$PAGE_REPO/.orchid/tasks/T902.md" status)" \
  "fixture witness: T902 really is blocked, so an empty cause below means 'nothing recorded', not 'never blocked'"
assert_eq "" "$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T902)" \
  "a blocked task whose journal holds no transition record yields no cause — the page must never invent one"
# ...and one task's cause is never read off another's entries.
assert_eq "" "$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T900)" \
  "a task that was never blocked has no cause, even while another task's block sits in the same journal"
# ...nor is a missing journal an error that kills the pass: this is read
# through a command substitution inside a `set -e` driver.
assert_eq "" "$(drive_blocked_cause "$PAGE_REPO/.orchid/no-such-journal.md" T901)" \
  "a journal that is not there at all answers 'no cause on record', not a non-zero status"

# A cause is CLIPPED to one line's worth. A charged verify failure's reason
# carries the whole classifier paragraph, and this text has to survive as one
# line of a phone notification.
page_orchid task create T903 "a very long cause" >/dev/null \
  || fail "fixture task for the clipping case must be creatable"
long_cause=""
while [ "${#long_cause}" -lt 300 ]; do long_cause="${long_cause}0123456789"; done
page_orchid task advance T903 blocked --reason "$long_cause" >/dev/null \
  || fail "fixture: blocking T903 with a 300-character reason must succeed"
clipped_cause="$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T903)"
[ "${#clipped_cause}" -lt 300 ] \
  || fail "a 300-character block reason must be clipped for the page, got ${#clipped_cause} characters"
assert_match '\.\.\.$' "$clipped_cause" \
  "and the clip is marked, so nobody reads a truncated cause as the whole of it"

# --- 9b: the declared answers, enforced by `orchid answer` ------------------
# THE SET IS READ FROM drive_boundary_choices, NEVER RETYPED HERE. The whole
# property is that the set an operator is OFFERED and the set `orchid answer`
# ENFORCES are one object, so a hand-copied list in this fixture would pass
# while the page shipped another. The argv is assembled exactly the way
# runners/orchid-drive's own drive_notify assembles it, for the same reason.
page_blocked_notify() {
  local text="$1" choice
  local -a nargs
  nargs=(notify --task T901)
  while IFS= read -r choice; do
    [ -n "$choice" ] || continue
    nargs+=(--choice "$choice")
  done <<< "$(drive_boundary_choices blocked-task)"
  nargs+=("$text")
  page_orchid "${nargs[@]}"
}

# Composed by the driver's own composer rather than typed out here, for the
# reason the helper above gives about the set: a hand-copied page would pass
# while the driver shipped another. Section 12 below is what holds that
# composer to naming every remedy and the cause.
blocked_reason="$(drive_blocked_reason T901 "verify failed for something the candidate never caused")"
qidB="$(page_blocked_notify "$blocked_reason")" \
  || fail "fixture: a blocked-task page must be raisable with its declared set"
assert_eq "unblock,retry,reverify,defer" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidB.choices")" \
  "the set recorded with the question is the kernel's whole recovery list out of blocked, reverify included"
assert_match "^choices: unblock \| retry \| reverify \| defer\$" \
  "$(cat "$PAGE_REPO/.orchid/runtime/outbox/$qidB")" \
  "and the page an operator actually reads names all four"

# RED, and it is the assertion the shipped defect fails: `reverify` is a verb
# the reason text points the operator at, so `orchid answer` must ACCEPT it.
# With the set that omitted it, this call is refused -- the page inviting an
# answer it then rejects.
outB="$(page_orchid answer "$qidB" reverify 2>&1)" \
  || fail "orchid answer must ACCEPT 'reverify' for a blocked-task page: it is a remedy the reason text names (got: $outB)"
assert_eq "reverify" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidB.answer")" \
  "and records it verbatim, so the operator's decision survives as the verb they intend to run"

# GREEN, the other edge: the gate is still a gate. A value outside the set is
# refused, and the refusal NAMES the valid ones including reverify (L028: a
# refusal names the action that clears it).
qidB2="$(page_blocked_notify "$blocked_reason")" \
  || fail "fixture: a second blocked-task page must be raisable for the refusal case"
rcB=0
errB="$(page_orchid answer "$qidB2" unblokc 2>&1 1>/dev/null)" || rcB=$?
[ "$rcB" -ne 0 ] || fail "a typoed answer must be refused, never recorded silently as a decision"
assert_match "'unblokc' is not among $qidB2's declared choices" "$errB" \
  "the refusal names the rejected value and the question"
assert_match "unblock \| retry \| reverify \| defer" "$errB" \
  "and lists every answer that WOULD be accepted, reverify included"
[ ! -f "$PAGE_REPO/.orchid/runtime/answers/$qidB2.answer" ] \
  || fail "a refused out-of-set answer must never be recorded as answered"

# ===========================================================================
# 10 -- EVERY DECLARED CHOICE IS PASSABLE BACK AS `orchid answer`'s <choice>
#      (T009).
#
# A declared set is a promise with two ends: the page NAMES the answers, and
# `orchid answer` refuses everything outside the set (section 9b). That makes
# an unrepresentable member worse than no set at all -- the named answer
# cannot be given, and every other answer is refused because it was not named,
# so the question is answerable by nothing. `-foo` is exactly that value:
# libexec/orchid-answer routes any `-*` argument to its usage arm and offers
# no `--` terminator, so a leading dash can never reach the <choice> slot.
# `orchid notify` used to admit it anyway -- it banned only whitespace and
# commas -- and would print it on the `choices:` line directly above a reply
# command that cannot carry it.
#
# The mint now enforces the same word grammar
# runners/orchid-orchestrator-command's `is_id` has always enforced for this
# same flag, so the brokered door and the direct one agree about what a choice
# is. This section pins both edges of that grammar.
# ===========================================================================
# The other end of the promise, witnessed rather than assumed: a leading-dash
# value really is unusable as an answer even for a question with NO declared
# set, where free text is otherwise accepted verbatim. If this ever stopped
# being true the RED below would be guarding nothing.
qidF="$(page_orchid notify --task T900 "free text, no declared set")" \
  || fail "fixture: a question with no declared set must be raisable, or the witness below tests nothing"
rcF=0
errF="$(page_orchid answer "$qidF" -foo 2>&1 1>/dev/null)" || rcF=$?
[ "$rcF" -ne 0 ] \
  || fail "witness: 'orchid answer <qid> -foo' must be refused — the whole reason a leading-dash choice may not be minted"
assert_match "usage: orchid answer <qid> <choice>" "$errF" \
  "...and it is refused by the ARGV parser, on usage: the dash is read as a flag, so no such value can reach the choice slot"

# RED. So the mint refuses it, and refuses it BEFORE any durable write: no
# question, no page, nothing for an operator to read and fail to answer.
outbox_before="$(find "$PAGE_REPO/.orchid/runtime/outbox" -type f | wc -l | tr -d ' ')"
rcX=0
errX="$(page_orchid notify --task T900 --choice -foo "declare an answer nobody can give" 2>&1 1>/dev/null)" || rcX=$?
[ "$rcX" -ne 0 ] \
  || fail "orchid notify must refuse --choice -foo: it names an answer 'orchid answer' can never be given"
assert_match "not a valid choice value" "$errX" \
  "the refusal says the value is the problem, not the flag"
assert_match "orchid answer <qid> <choice>" "$errX" \
  "...and names the parser the value has to survive, so the fix is obvious from the message alone (L028)"
assert_eq "$outbox_before" "$(find "$PAGE_REPO/.orchid/runtime/outbox" -type f | wc -l | tr -d ' ')" \
  "a refused choice mints no question at all — the page is never written, so nothing unanswerable ships"

# ...and the same refusal covers a value that would FORGE a line rather than
# merely fail to parse. This is why the guard reads the whole argument instead
# of matching it line-by-line: a value whose first line is a legal word would
# pass a line-oriented check and then split the `choices:` header and the CSV
# sidecar into rows nobody declared.
rcN=0
page_orchid notify --task T900 --choice "$(printf 'approve\nrogue')" "forge a line" >/dev/null 2>&1 || rcN=$?
[ "$rcN" -ne 0 ] \
  || fail "a --choice value carrying a newline must be refused — its first line is a legal word, and the rest would forge a row in the recorded set"

# GREEN, and it is what keeps the RED from being a ban on hyphens: the
# vocabulary the kernel actually declares is hyphenated (`request-changes`,
# `plan-apply`, `run-accept` in lib/drive.sh's table), so an interior hyphen
# must still mint, still print, and still answer.
qidG="$(page_orchid notify --task T900 --choice request-changes --choice defer "hyphenated answers still work")" \
  || fail "orchid notify must accept a hyphenated alphanumeric choice — it is the shape the kernel's own boundary table declares"
assert_eq "request-changes,defer" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidG.choices")" \
  "the hyphenated value is recorded verbatim in the declared set"
assert_match "^choices: request-changes \| defer\$" \
  "$(cat "$PAGE_REPO/.orchid/runtime/outbox/$qidG")" \
  "...and reaches the page unaltered"
outG="$(page_orchid answer "$qidG" request-changes 2>&1)" \
  || fail "orchid answer must ACCEPT the hyphenated choice the page declared (got: $outG)"
assert_eq "request-changes" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidG.answer")" \
  "a declared choice is answerable end to end: minted, printed, given back and recorded"

# ===========================================================================
# 11 -- A REVIEW PAGE NAMES THE ANSWERS LEGAL FROM THE STATE IT WAS RAISED IN
#       (T009).
#
# The declared set is a promise with two ends: the page NAMES the answers and
# `orchid answer` refuses everything else. Which answers are honest is therefore
# the same three-fact question the boundary's own ranking asks -- and one of
# those facts is the TASK'S STATUS. `orchid task arbitrate` refuses any status
# but `arbitrating` (libexec/orchid-task, exit 3), yet every `review-evidence`
# boundary the reviewing walk raises fires while the task is still `reviewing`:
# a review-plan pin that failed, a routing table with no unfilled slot, a
# tier-complete set whose routed slot has no review of its own, a slot pinned to
# an engine that cannot be dispatched. Those pages declared `approve |
# request-changes | defer` -- three answers whose verb would have exited 3 --
# while the gate refused the two `orchid jobs review-plan` modes the same pages'
# reason texts told the operator to run. Not merely an unhelpful menu: the
# operator who took the named remedy could not record that they had.
#
# BOTH EDGES ARE PROVEN HERE, and at the notify/answer level rather than through
# a drive pass, because the two states reach a page by DIFFERENT producers. A
# review boundary on a `reviewing` task is operator-only, so runners/orchid-drive
# raises it through `orchid notify` itself (tests/test_drive.sh's slot fixture
# pins that page end to end). On an `arbitrating` task the same kind is
# arbitrable, so the driver wakes an orchestrator instead -- and the page then
# comes from the woken model's own `notify --task <id> --choice ...` through the
# brokered surface when it judges the decision a human's after all. One verb,
# two producers; what both must agree about is the set, which is what this
# section holds them to.
# ===========================================================================
# The driver's own argv assembly (runners/orchid-drive's drive_notify), status
# included, so the pages asserted below are the pages that verb really composes.
# Never a hand-copied list, for section 9b's reason.
page_review_notify() {
  local task="$1" status="$2" text="$3" choice
  local -a nargs
  nargs=(notify --task "$task")
  while IFS= read -r choice; do
    [ -n "$choice" ] || continue
    nargs+=(--choice "$choice")
  done <<< "$(drive_boundary_choices review-evidence "$status")"
  nargs+=("$text")
  page_orchid "${nargs[@]}"
}

page_orchid task create T904 "prove both review edges" >/dev/null \
  || fail "fixture task for the review-page section must be creatable"
# The status is set directly, exactly as section 8 sets `attempts` and section 9
# sets `blocked`: what this section is about is the page raised FROM a status,
# not the route the task took to reach it.
fm_set "$PAGE_REPO/.orchid/tasks/T904.md" status reviewing
assert_eq reviewing "$(fm_get "$PAGE_REPO/.orchid/tasks/T904.md" status)" \
  "fixture witness: T904 really is reviewing, so the page below is the reviewing-state one"

# THE FACT THE WHOLE SECTION RESTS ON, witnessed rather than assumed: the
# arbitration verb is refused outright from `reviewing`. If this ever stopped
# being true, `approve` would be a legal answer here and the RED below would be
# guarding nothing.
rc904=0
err904="$(page_orchid task arbitrate T904 --result approve --reason "witness: is this legal from reviewing?" 2>&1 1>/dev/null)" || rc904=$?
[ "$rc904" -eq 3 ] \
  || fail "witness: 'orchid task arbitrate' must refuse a reviewing task with exit 3 (got $rc904: $err904)"
assert_match "is not arbitrating" "$err904" \
  "...and refuse it on the STATUS, which is why an arbitration result is not an answer a reviewing page may offer"

# --- 11a: the reviewing edge -----------------------------------------------
reviewing_reason="1 of 2 review envelope(s) bound to the current candidate, but slot(s) 2 have no review of their own — the tier's engine independence is unproven. Expected: 'orchid jobs review-plan T904 --adopt-evidence' when those envelopes were dispatched for the slots the plan has since re-routed, otherwise 'orchid task advance T904 blocked --reason ...' to hand it to a human"
qidRV="$(page_review_notify T904 reviewing "$reviewing_reason")" \
  || fail "fixture: a review-evidence page must be raisable from reviewing with its declared set"
assert_eq "adopt-evidence,repin,block,defer" \
  "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidRV.choices")" \
  "the set recorded with a reviewing page is the recovery list legal from reviewing"
assert_match "^choices: adopt-evidence \| repin \| block \| defer\$" \
  "$(cat "$PAGE_REPO/.orchid/runtime/outbox/$qidRV")" \
  "...and that is what the operator reads on the page itself"
if grep -q '^choices: approve' "$PAGE_REPO/.orchid/runtime/outbox/$qidRV"; then
  fail "a reviewing page must not open its answer set with an arbitration result — that verb exits 3 from this status"
fi

# RED. `--adopt-evidence` and `--repin` are the verbs this page's own reason
# text points at, so the gate must ACCEPT the answer that records taking one.
# Under the arbitration set this call was refused: the page named a remedy and
# then rejected the operator who took it.
outRV="$(page_orchid answer "$qidRV" repin 2>&1)" \
  || fail "orchid answer must ACCEPT 'repin' for a reviewing review page: it is a remedy the reason text names (got: $outRV)"
assert_eq "repin" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidRV.answer")" \
  "and records it verbatim, so the operator's decision survives as the verb they intend to run"

# ...and the gate is still a gate here: the answers that are legal one
# transition later are refused, and the refusal names the ones that are not.
qidRV2="$(page_review_notify T904 reviewing "$reviewing_reason")" \
  || fail "fixture: a second reviewing page must be raisable for the refusal case"
rcRV=0
errRV="$(page_orchid answer "$qidRV2" approve 2>&1 1>/dev/null)" || rcRV=$?
[ "$rcRV" -ne 0 ] \
  || fail "'approve' must be refused on a reviewing page — 'orchid task arbitrate' exits 3 from that status, so it names no decision anybody can carry out"
assert_match "'approve' is not among $qidRV2's declared choices" "$errRV" \
  "the refusal names the rejected value and the question"
assert_match "adopt-evidence \| repin \| block \| defer" "$errRV" \
  "and lists the answers that WOULD be accepted, which are the remedies the reason text points at (L028)"
[ ! -f "$PAGE_REPO/.orchid/runtime/answers/$qidRV2.answer" ] \
  || fail "a refused out-of-set answer must never be recorded as answered"

# --- 11b: the arbitrating edge ---------------------------------------------
# GREEN, and it is what keeps 11a from being a rename: one transition later the
# very same kind names the arbitration results, because there the verb behind
# them runs. Without this half, "state-correct" would be satisfied by a table
# that had simply dropped `approve` everywhere.
fm_set "$PAGE_REPO/.orchid/tasks/T904.md" status arbitrating
assert_eq arbitrating "$(fm_get "$PAGE_REPO/.orchid/tasks/T904.md" status)" \
  "fixture witness: the same task is now arbitrating, so the page below is the arbitrating-state one"
qidAR="$(page_review_notify T904 arbitrating "incomplete review evidence: 1 of 2 required for risk_tier medium")" \
  || fail "fixture: a review-evidence page must be raisable from arbitrating with its declared set"
assert_eq "approve,request-changes,defer" \
  "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidAR.choices")" \
  "the set recorded with an arbitrating page is the arbitration truth table's own results"
assert_match "^choices: approve \| request-changes \| defer\$" \
  "$(cat "$PAGE_REPO/.orchid/runtime/outbox/$qidAR")" \
  "...and the page names them where the operator reads it"
outAR="$(page_orchid answer "$qidAR" approve 2>&1)" \
  || fail "orchid answer must ACCEPT 'approve' for an arbitrating review page — 'orchid task arbitrate --result approve' is legal there (got: $outAR)"
assert_eq "approve" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidAR.answer")" \
  "and records the arbitration result verbatim"

# ...and the mirror image of 11a's refusal, which is what proves the two sets
# are keyed on the state rather than merged into one permissive union: the
# reviewing remedies are refused HERE, where the routing they repair is already
# settled and the decision on the table is the arbitration.
qidAR2="$(page_review_notify T904 arbitrating "incomplete review evidence: 1 of 2 required for risk_tier medium")" \
  || fail "fixture: a second arbitrating page must be raisable for the refusal case"
rcAR=0
errAR="$(page_orchid answer "$qidAR2" repin 2>&1 1>/dev/null)" || rcAR=$?
[ "$rcAR" -ne 0 ] \
  || fail "'repin' must be refused on an arbitrating page — the declared set is the state's own recovery list, not the union of every state's"
assert_match "approve \| request-changes \| defer" "$errAR" \
  "and that refusal names the arbitration results, so the operator is pointed at the decision this state is actually waiting on"

# --- 11c: a state with no decided recovery list keeps free text -------------
# The third arm, and the only one that falls back rather than choosing a set. A
# review page on a status neither verb-set belongs to is a state nobody has
# enumerated remedies for; naming either list there could refuse the one answer
# that was correct, so the pre-choice free-text contract stands and the page
# carries no `choices:` line at all.
assert_eq "" "$(drive_boundary_choices review-evidence testing)" \
  "a review boundary on an undecided status declares no set"
fm_set "$PAGE_REPO/.orchid/tasks/T904.md" status testing
assert_eq testing "$(fm_get "$PAGE_REPO/.orchid/tasks/T904.md" status)" \
  "fixture witness: the task really is on the undecided status the page below is raised from"
qidFT="$(page_review_notify T904 testing "a review boundary on a status nobody enumerated remedies for")" \
  || fail "fixture: a review page on an undecided status must still be raisable"
[ ! -f "$PAGE_REPO/.orchid/runtime/answers/$qidFT.choices" ] \
  || fail "an undecided status must record no declared set — the sidecar's existence is what switches the gate on"
if grep -q '^choices: ' "$PAGE_REPO/.orchid/runtime/outbox/$qidFT"; then
  fail "a page with no declared set must not print a choices: line"
fi
outFT="$(page_orchid answer "$qidFT" "the routing table was hand-repaired after a restore" 2>&1)" \
  || fail "with no set declared, free text is accepted exactly as it was before choice sets existed (got: $outFT)"
assert_eq "the routing table was hand-repaired after a restore" \
  "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidFT.answer")" \
  "...and is recorded verbatim, so the fallback is a real contract rather than a silent drop"

# ===========================================================================
# 12 -- ONE STOP, ONE PAGE: THE TASK THE DRIVER BLOCKS ITSELF (T009).
#
# A page is a QUESTION -- its own qid, its own nonce, its own `.answer` file --
# so the number of pages a stop raises is not cosmetic. Two pages for one
# decision are two questions an operator has to answer, and answering either
# leaves the other standing in BLOCKERS.md until `answer_expiry_s` turns it
# into a refusal, with nothing on either page saying which one was live.
#
# PROTOCOL.md's budget is ONE blocker per DISTINCT boundary record, and the
# only thing that can enforce it is the de-dup at the foot of
# runners/orchid-drive: it reads the previous record back and compares it field
# by field, so a page raised anywhere else is compared against nothing, and a
# record whose wording changes is a record that changed. An exhausted task
# defeated that twice over. The exhausted-budget arm raised its own `orchid
# notify` and THEN recorded an `operator-decision` boundary which the foot of
# the file notified for as well -- two qids on the pass that blocked the task --
# and the blocked walk restated the same stop on the very next pass in a third
# wording, which the comparison could only read as a new record: a third qid,
# for one decision, out of one `attempts exhausted (3/3)`. Only the first of
# the three declared an answer set at all; the other two invited free text for
# a question with exactly four known answers. Two more arms had the identical
# shape -- the wallclock backstop, which paged the task it was about to block,
# and the stuck-merge arm, which paged and then recorded the very boundary the
# foot of the file pages for.
#
# The repair is that a task the driver blocks is recorded through the ONE
# composition every later pass over that task recomputes (lib/drive.sh's
# drive_blocked_reason), and nothing pages beside the record. Pinned here in
# three parts: what that single page has to carry, what two wordings of one
# stop actually cost an operator, and the producer count itself.
# tests/test_drive.sh's attempt-budget fixture drives the same property end to
# end through real passes; this file is the one this task's verification runs.
# ===========================================================================

# The driver's own argv assembly again (runners/orchid-drive's drive_notify),
# generalized over the task the way section 9b's is over its text. Never a
# hand-copied set, for the reason that helper gives.
page_block_notify() {
  local task="$1" text="$2" choice
  local -a nargs
  nargs=(notify --task "$task")
  while IFS= read -r choice; do
    [ -n "$choice" ] || continue
    nargs+=(--choice "$choice")
  done <<< "$(drive_boundary_choices blocked-task)"
  nargs+=("$text")
  page_orchid "${nargs[@]}"
}

# --- 12a: the one page carries what all three texts carried -----------------
# The page that survives is the blocked-task one, so everything the retired
# `operator-decision` text told the operator has to be on it: the cause WITH
# its evidence pointer, and each recovery verb spelled out runnably. The
# pointer rides in the BLOCK's own `--reason` now, which is why it survives
# every later pass instead of only the one-shot page that used to carry it.
page_orchid task create T905 "spend its last round" >/dev/null \
  || fail "fixture task for the one-page section must be creatable"
page_orchid task advance T905 blocked \
  --reason "attempts exhausted (3/3): see .orchid/reviews/T905-verify.log" >/dev/null \
  || fail "fixture: blocking T905 the way the exhausted-budget arm blocks it must succeed"
blk_cause="$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T905)"
assert_eq "attempts exhausted (3/3): see .orchid/reviews/T905-verify.log" "$blk_cause" \
  "fixture witness: the evidence pointer is IN the block's journaled reason, so the page reads it back on this pass and on every pass after it"

blk_reason="$(drive_blocked_reason T905 "$blk_cause")"
assert_match "attempts exhausted \(3/3\)" "$blk_reason" \
  "the blocked-task page states the cause it was blocked with (reason: $blk_reason)"
assert_match "\.orchid/reviews/T905-verify\.log" "$blk_reason" \
  "...including the evidence the retired exhaustion page pointed at, which is the file the operator has to read before choosing (reason: $blk_reason)"
assert_match "orchid task unblock T905" "$blk_reason" \
  "...and names the verb that clears the block, on the task it is about"
assert_match "orchid task retry T905 \[--attempts N\]" "$blk_reason" \
  "...the verb that grants rounds, with the flag the exhaustion case specifically needs — a page read on a phone must be runnable from it, not decoded from an a|b|c shorthand"
assert_match "orchid task reverify T905" "$blk_reason" \
  "...and the verb that re-runs verification alone: the whole recovery list, which is also the set orchid answer accepts"

# The composition is a pure function of (task, cause), which is what makes the
# two producers agree: the arm that BLOCKS and the walk that finds it BLOCKED
# read the same journal and print the same string.
assert_eq "$blk_reason" "$(drive_blocked_reason T905 "$(drive_blocked_cause "$PAGE_REPO/.orchid/journal.md" T905)")" \
  "the same task and the same journal compose the same page — which is why the next pass's record equals this one's and de-dups instead of minting"
# ...and the honest arm survives: a blocked task whose journal lost its record
# says so rather than printing an empty clause after a colon.
assert_match "^task is blocked, and the journal records no cause for it —" \
  "$(drive_blocked_reason T905 "")" \
  "a page composed with no cause on record says that plainly, and still names the remedies"

qidX="$(page_block_notify T905 "$blk_reason")" \
  || fail "fixture: the blocked-task page must be raisable with its declared set"
page_x="$(cat "$PAGE_REPO/.orchid/runtime/outbox/$qidX")"
assert_match "attempts exhausted \(3/3\)" "$page_x" \
  "all of that reaches the page an operator actually reads, not just the boundary record"
assert_match "\.orchid/reviews/T905-verify\.log" "$page_x" \
  "...evidence pointer included"
assert_match "^choices: unblock \| retry \| reverify \| defer\$" "$page_x" \
  "...and the one surviving page is the one that declares the answer set, which two of the three retired pages never did"

# --- 12b: what a second wording of one stop costs ---------------------------
# The witness the whole section rests on: pages are not de-duplicated by
# subject. Two texts about ONE stop are two independent questions, and
# answering either says nothing about the other. This is why the driver's two
# arms may not describe a block in their own words.
qidY="$(page_block_notify T905 "attempts exhausted after 3 of 3 rework round(s): see .orchid/reviews/T905-verify.log")" \
  || fail "fixture: a second wording of the same stop must be raisable, or the cost below is untested"
[ "$qidX" != "$qidY" ] \
  || fail "witness: two notifies must mint two qids — if they collided there would be no duplicate-page defect to fix"
outX="$(page_orchid answer "$qidX" retry 2>&1)" \
  || fail "orchid answer must accept 'retry' for the blocked-task page (got: $outX)"
assert_eq "retry" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidX.answer")" \
  "the operator's decision is recorded against the qid they answered"
[ ! -f "$PAGE_REPO/.orchid/runtime/answers/$qidY.answer" ] \
  || fail "answering one qid must never answer another — the second page for the same stop is still outstanding"
outY="$(page_orchid answer "$qidY" defer 2>&1)" \
  || fail "...and it is still LIVE: the operator is asked a second time about a decision they already made (got: $outY)"
assert_eq "defer" "$(cat "$PAGE_REPO/.orchid/runtime/answers/$qidY.answer")" \
  "which is the whole cost of a duplicate page — two answers recorded for one stop, and nothing on either page saying which one the run reads"

# --- 12c: RED — the driver has exactly one page producer --------------------
# The assertion the shipped defect fails. `drive_notify` is the only thing in
# runners/orchid-drive that raises a page, and it is called from exactly one
# place: the boundary record at the foot of the file, the one site the
# field-by-field de-dup covers. Three arms used to call it as well -- two
# paging a task they were about to block, one paging a boundary it recorded in
# the same breath -- so those pages were compared against nothing. Counting the
# call sites is what keeps a fourth from being added: the count is the
# invariant, and it fails on the addition rather than on the duplicate page an
# operator would have had to notice in a channel.
drive_src="$REPO_ROOT/runners/orchid-drive"
[ -f "$drive_src" ] || fail "fixture: runners/orchid-drive must be readable for the producer count below"
drive_notify_calls="$(grep -cE '^[[:space:]]*drive_notify ' "$drive_src" || true)"
assert_eq "1" "$drive_notify_calls" \
  "runners/orchid-drive must raise its pages from exactly ONE call site — every other one is a page nothing de-duplicates (found $drive_notify_calls)"
assert_match "boundary_kind" "$(grep -E '^[[:space:]]*drive_notify ' "$drive_src" || true)" \
  "...and that site is the boundary record's own, so the page and the record are the same fact"
if grep -qE '^[[:space:]]*drive_notify blocked-task' "$drive_src"; then
  fail "no arm may page a task it is blocking: the page for that stop belongs to the blocked-task boundary the block produces, which is the only thing that de-dups it against the next pass"
fi
# ...and the arm really does record that boundary, rather than having simply
# dropped the page. Without this half, deleting the notify would pass 12c while
# leaving the exhausted task silent.
assert_match "drive_block_boundary" \
  "$(grep -E -A 8 'attempts exhausted \(\$attempts/\$budget\): see' "$drive_src" || true)" \
  "the exhausted-budget arm records the blocked-task boundary its own block produced — that record IS the page"
