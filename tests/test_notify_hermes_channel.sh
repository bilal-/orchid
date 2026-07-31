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
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
export ORCHID_ROOT="$REPO_ROOT"
SEND="$REPO_ROOT/plugins/notify/hermes/send"

cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
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
