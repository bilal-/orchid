#!/usr/bin/env bash
# v1-m4 Task 7: OpenClaw notify channel (OUTBOX pattern + pump drain),
# inbox hardening (nonce/allowlist/expiry, gated on answer_allowlist being
# configured at all -- NOT on a self-asserted ORCHID_ANSWER_SENDER, see
# libexec/orchid-answer's header for the review-round fix this encodes),
# nonce-entropy fail-closed behavior, kind=notify plugin
# validate/list/conform, and the INV-01 carve-out (orchid notify itself
# never spawns -- only writes runtime/outbox/<qid>; runners/orchid-pump,
# tier-2, is what actually launches the channel plugin's `send`).
#
# Follow-up (hermes notify channel task): `notify.plugin` (default
# `openclaw`) now selects WHICH kind=notify plugin dir the pump's outbox
# drain launches -- section 8 (bottom of this file) covers that selector:
# the default (unset, still openclaw -- every section above this comment
# exercises exactly that, unchanged), an explicit `notify.plugin=hermes`
# (stubbed), and a bogus value's failure/quarantine path. Everything above
# section 8 is untouched by that change.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"; source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
export ORCHID_ROOT="$REPO_ROOT"
PUMP="$REPO_ROOT/runners/orchid-pump"

cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"

# -- stub `openclaw` on PATH: captures argv, never sends anything real -----
STUBBIN="$WORK/stubbin"; mkdir -p "$STUBBIN"
OC_LOG="$WORK/openclaw-calls.log"; : > "$OC_LOG"
OC_MODE_FILE="$WORK/openclaw-mode"   # absent/"ok" -> exit 0; "fail" -> exit 1
cat > "$STUBBIN/openclaw" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$OC_LOG"
if [ -f "$OC_MODE_FILE" ] && [ "\$(cat "$OC_MODE_FILE")" = fail ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$STUBBIN/openclaw"
export PATH="$STUBBIN:$PATH"

# -- a PATH prefix that SHADOWS xxd/od with always-failing stubs, so
# _notify_strong_nonce (libexec/orchid-notify) can never find a strong
# entropy source, without touching the real /dev/urandom or removing any
# other coreutil this suite (or orchid itself) needs. ---------------------
BLOCKENT="$WORK/blockent"; mkdir -p "$BLOCKENT"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BLOCKENT/xxd"; chmod +x "$BLOCKENT/xxd"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BLOCKENT/od"; chmod +x "$BLOCKENT/od"

# ===========================================================================
# 0 -- INV-01 (static): `orchid notify` must never spawn/detach/invoke a
# vendor CLI -- only write files. Same class of grep the real INV-01 suite
# test runs (tests/inv/test_INV-01_no_spawn_in_tier1.sh), scoped here
# specifically to the two files this task touches.
# ===========================================================================
bg_re='(^|[^&])&[[:space:]]*$'
if grep -nE "($bg_re|nohup|setsid|disown)" "$REPO_ROOT/libexec/orchid-notify" "$REPO_ROOT/libexec/orchid-answer"; then
  fail "INV-01: orchid-notify/orchid-answer spawns or detaches a process"
fi
# The channel CLI itself is never invoked from either file -- only real
# executable calls matter here (a comment mentioning the vendor name is
# fine; an actual invocation of it is not), so this greps for a real
# command position, not just the bare word anywhere in the file.
if grep -nE '(^|[;&|]|\bexec )\s*openclaw\b' "$REPO_ROOT/libexec/orchid-notify" "$REPO_ROOT/libexec/orchid-answer"; then
  fail "INV-01: orchid-notify/orchid-answer invokes the channel CLI directly (should only ever touch runtime/outbox/*)"
fi

# ===========================================================================
# 1 -- kind=notify plugin discovery: list/validate cover it, and conform
# takes the minimal send-contract lint path, never the 7-check battery.
# ===========================================================================
out="$(HOME="$HOME" "$ORCHID_BIN" plugins list)"
assert_match "orchid/openclaw	notify" "$out" "plugins list shows the openclaw notify plugin with kind=notify"

out="$(HOME="$HOME" "$ORCHID_BIN" plugins validate orchid/openclaw)"; rc=$?
[ "$rc" -eq 0 ] || fail "plugins validate orchid/openclaw should pass (rc=$rc): $out"
assert_match "^ok: " "$out" "plugins validate orchid/openclaw reports ok"

out="$(HOME="$HOME" "$ORCHID_BIN" plugins conform "$REPO_ROOT/plugins/notify/openclaw")"; rc=$?
[ "$rc" -eq 0 ] || fail "plugins conform on the notify plugin should pass (rc=$rc): $out"
assert_match "send-contract lint only" "$out" "conform names the notify-lint path, not the engine battery"
assert_match "^2/2 checks passed\$" "$out" "conform on kind=notify runs exactly 2 checks (manifest_valid + entrypoint_executable)"
[ -s "$OC_LOG" ] && fail "conform must never invoke the plugin's own entrypoint (openclaw stub was called)"

# ===========================================================================
# 2 -- no remote path configured at all yet (no orchid.config exists):
# no outbox dir; a weak/guessable nonce fallback is TOLERATED when entropy
# is unavailable (decorative only -- nothing can reach it remotely); and
# `orchid answer` stays fully lenient for everyone (no allowlist configured
# means no remote path to defend), even for a caller that asserts a sender.
# ===========================================================================
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
qid_nochan="$("$ORCHID_BIN" notify "no channel configured yet")"
[ -d ".orchid/runtime/outbox" ] && fail "no notify.channel configured: outbox dir must not even be created"

qid_weak="$(PATH="$BLOCKENT:$PATH" "$ORCHID_BIN" notify "weak nonce tolerated, no remote path")"; rc=$?
[ "$rc" -eq 0 ] || fail "with no notify.channel/answer_allowlist configured, notify must still succeed even with no strong entropy source"
wnonce="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qid_weak.question" | sed 's/^nonce: //')"
assert_match "^[0-9a-f]{16}\$" "$wnonce" "the decorative weak-fallback nonce is still well-formed hex"

qid_lenient="$("$ORCHID_BIN" notify "lenient, no allowlist configured")"
out="$(ORCHID_ANSWER_SENDER=whoever "$ORCHID_BIN" answer "$qid_lenient" yes)"
assert_match "yes" "$out" "with no answer_allowlist configured, an answer succeeds with no --nonce even when a sender is asserted"

# ===========================================================================
# 3 -- configure the channel + allowlist; notify now writes
# runtime/outbox/<qid> with the composed message (qid + text + reply
# instructions + nonce), AND a strong entropy source becomes MANDATORY:
# with both xxd/od shadowed, notify must refuse outright (die + a
# notify_entropy_failure journal note) rather than mint a guessable nonce,
# and must never raise the blocker at all in that case.
# ===========================================================================
{
  echo "notify.channel=slack"
  echo "notify.to=#ops"
  echo "answer_allowlist=agent1"
  echo "send_retry_max=2"
} > orchid.config

before_ob_count="$(find .orchid/runtime/outbox -type f 2>/dev/null | wc -l | tr -d ' ')"
rc=0
PATH="$BLOCKENT:$PATH" "$ORCHID_BIN" notify "should never be raised, no entropy" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "with a remote path configured (answer_allowlist), notify must refuse when no strong entropy source is available"
assert_match "notify_entropy_failure" "$(cat .orchid/journal.md)" "entropy failure leaves a notify_entropy_failure journal note"
[ -z "$(grep -F 'should never be raised, no entropy' .orchid/journal.md 2>/dev/null)" ] \
  || fail "an entropy-refused notify must never journal the blocker text at all"
after_ob_count="$(find .orchid/runtime/outbox -type f 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$before_ob_count" "$after_ob_count" "an entropy-refused notify must not write an outbox file either"

qid1="$("$ORCHID_BIN" notify "db migration ready")"
[ -f ".orchid/runtime/outbox/$qid1" ] || fail "notify.channel configured: outbox file must be written"
obtext="$(cat ".orchid/runtime/outbox/$qid1")"
assert_match "$qid1: db migration ready" "$obtext" "outbox message carries qid+text"
assert_match "nonce [0-9a-f]+" "$obtext" "outbox message carries a nonce"
assert_match "reply: orchid answer $qid1 <choice>" "$obtext" "outbox message carries the reply instructions"

qf1nonce="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qid1.question" | sed 's/^nonce: //')"
[ -n "$qf1nonce" ] || fail "question file must carry a nonce: line"
assert_match "$qf1nonce" "$obtext" "the outbox nonce matches the .question file's own nonce"
assert_match "nonce: $qf1nonce" "$(cat .orchid/BLOCKERS.md)" "BLOCKERS.md also carries the nonce (one-copy-paste for the local terminal path)"

# ===========================================================================
# 4 -- pump drains the outbox even while the lease is fresh: send is
# invoked with the composed text via the real (stubbed) openclaw CLI, and
# the outbox file is removed on success.
# ===========================================================================
printf -- '---\nrun_status: running\nrun_id: r-notify\n---\n# Roadmap\n' > .orchid/roadmap.md
now="$(date -u +%s)"; iso="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg t "$iso" '{epoch:1, refreshed_at:$t}' > .orchid/runtime/lease.json

out="$("$PUMP" 2>&1)"
assert_match '^pump: lease fresh \([0-9]+s\)$' "$out" "pump still reports lease-fresh (drain must not block/replace that exit)"
[ -f ".orchid/runtime/outbox/$qid1" ] && fail "outbox file must be removed after a successful send"
assert_match "channel slack" "$(cat "$OC_LOG")" "openclaw stub was invoked with --channel slack"
assert_match "target #ops" "$(cat "$OC_LOG")" "openclaw stub was invoked with --target #ops"
assert_match "$qid1: db migration ready" "$(cat "$OC_LOG")" "openclaw stub's --message carries the qid+text"
assert_match "$qf1nonce" "$(cat "$OC_LOG")" "openclaw stub's --message carries the nonce"

# ===========================================================================
# 5 -- failure path: send_retry_max=2 -- first failure leaves the outbox
# file + bumps a .tries sidecar; second consecutive failure quarantines it
# (.reason-send-failed written, original + sidecar removed).
# ===========================================================================
echo fail > "$OC_MODE_FILE"
qid2="$("$ORCHID_BIN" notify "will fail to send")"

"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qid2" ] || fail "a failed send must leave the outbox file for the next pass"
[ -f ".orchid/runtime/outbox/$qid2.tries" ] || fail "a failed send must write a .tries sidecar"
assert_eq "1" "$(cat ".orchid/runtime/outbox/$qid2.tries")" "first failure records tries=1"

"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qid2" ] && fail "after send_retry_max consecutive failures the outbox file must be quarantined (removed)"
[ -f ".orchid/runtime/outbox/$qid2.tries" ] && fail "quarantine must also remove the .tries sidecar"
[ -f ".orchid/runtime/outbox/$qid2.reason-send-failed" ] || fail "quarantine must write a .reason-send-failed sidecar"
assert_match "quarantined" "$(cat ".orchid/runtime/outbox/$qid2.reason-send-failed")" "quarantine sidecar explains why"

rm -f "$OC_MODE_FILE"   # back to success mode for the rest of the suite

# ===========================================================================
# 6 -- answer matrix with answer_allowlist configured (hardening ON for
# EVERY caller, per the review-round fix -- not gated on ORCHID_ANSWER_
# SENDER at all).
# ===========================================================================

# 6a. THE FIXED VULNERABILITY: an injection-shaped omission attempt -- a
# caller that simply does not set ORCHID_ANSWER_SENDER and supplies no
# --nonce must now be REFUSED, because hardening is gated on
# answer_allowlist being configured (it is, from step 3), not on whether
# this particular call happens to assert a sender. Before the fix, this
# exact call silently bypassed every check.
qidV="$("$ORCHID_BIN" notify "vulnerable-shape omission attempt")"
rc=0
"$ORCHID_BIN" answer "$qidV" yes 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "SECURITY: an answer with no sender AND no --nonce must be refused once answer_allowlist is configured (this was the bypass)"

# 6b. The legitimate local-with-nonce path: no sender, but the CORRECT
# nonce (as read from BLOCKERS.md/.question by a human at the terminal)
# still succeeds.
nV="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qidV.question" | sed 's/^nonce: //')"
out="$("$ORCHID_BIN" answer "$qidV" yes --nonce "$nV")"
assert_match "yes" "$out" "local-with-nonce (no sender, correct --nonce) succeeds"

# 6c. Remote sender, right nonce, allowlisted -> succeeds.
qidR="$("$ORCHID_BIN" notify "remote right nonce")"
nR="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qidR.question" | sed 's/^nonce: //')"
out="$(ORCHID_ANSWER_SENDER=agent1 "$ORCHID_BIN" answer "$qidR" yes --nonce "$nR")"
assert_match "yes" "$out" "remote answer with the right nonce + allowlisted sender succeeds"

# 6d. Remote sender, WRONG nonce -> dies.
qidW="$("$ORCHID_BIN" notify "remote wrong nonce")"
rc=0
ORCHID_ANSWER_SENDER=agent1 "$ORCHID_BIN" answer "$qidW" yes --nonce deadbeefdeadbeef 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "remote answer with the wrong nonce must die"

# 6e. Remote sender, ABSENT nonce -> dies (nonce is mandatory regardless of
# sender once answer_allowlist is configured).
qidA="$("$ORCHID_BIN" notify "remote absent nonce")"
rc=0
ORCHID_ANSWER_SENDER=agent1 "$ORCHID_BIN" answer "$qidA" yes 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "remote answer with NO --nonce at all must die"

# 6f. Remote sender NOT on the allowlist -> dies, even with the right nonce.
qidU="$("$ORCHID_BIN" notify "unlisted sender")"
nU="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qidU.question" | sed 's/^nonce: //')"
rc=0
ORCHID_ANSWER_SENDER=nobody "$ORCHID_BIN" answer "$qidU" yes --nonce "$nU" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "an unlisted sender must be refused even with the correct nonce"

# ===========================================================================
# 7 -- expiry: unconditional regardless of sender/allowlist, and a journal
# note is left.
# ===========================================================================
qidE="$("$ORCHID_BIN" notify "will expire")"
nE="$(grep -m1 '^nonce: ' ".orchid/runtime/answers/$qidE.question" | sed 's/^nonce: //')"
sleep 2
before_j="$(wc -l < .orchid/journal.md)"
rc=0
ORCHID_ANSWER_EXPIRY_S=1 "$ORCHID_BIN" answer "$qidE" yes --nonce "$nE" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "an expired question must die, even with a valid nonce"
assert_match "blocker_expired" "$(cat .orchid/journal.md)" "expiry leaves a blocker_expired journal note"
assert_match "$qidE" "$(cat .orchid/journal.md)" "expiry journal note names the qid"
after_j="$(wc -l < .orchid/journal.md)"
[ "$after_j" -gt "$before_j" ] || fail "expiry must actually append a new journal entry, not just fail silently"

[ ! -f ".orchid/runtime/answers/$qidE.answer" ] || fail "an expired question must never be recorded as answered"

# ===========================================================================
# 8 -- notify.plugin selector (hermes notify channel follow-up): default
# stays openclaw (every section above this one already proves that, with
# no notify.plugin key in orchid.config at all); an explicit
# notify.plugin=hermes routes the SAME outbox/pump machinery to the
# sibling plugin instead; a bogus value feeds the identical
# failure/quarantine path a real send failure does, rather than silently
# looping forever untouched.
# ===========================================================================

# 8a -- default: a direct, explicit check of the resolved default in
# isolation (orchid.config still has no notify.plugin line at this point).
out="$(config_get "$WORK" notify.plugin openclaw)"
assert_eq "openclaw" "$out" "notify.plugin defaults to openclaw when never configured"

# -- stub `hermes` on PATH too (the sibling channel plugin), same shape as
# the openclaw stub above: captures argv, never sends anything real.
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

# 8b -- notify.plugin=hermes: the SAME outbox/pump machinery now resolves
# and launches plugins/notify/hermes/send instead of plugins/notify/
# openclaw/send -- reusing this file's already-configured notify.channel=
# slack / notify.to=#ops (irrelevant to hermes's own real-world semantics;
# the point here is purely selector routing, not a realistic hermes
# platform name -- plugins/notify/hermes's own target-composition contract
# is covered in full in tests/test_notify_hermes_channel.sh).
echo "notify.plugin=hermes" >> orchid.config
: > "$OC_LOG"; : > "$H_LOG"
qidH="$("$ORCHID_BIN" notify "hermes-routed message")"
[ -f ".orchid/runtime/outbox/$qidH" ] || fail "notify.plugin=hermes: outbox file must still be written the same way"
"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qidH" ] && fail "notify.plugin=hermes: outbox file must be removed after a successful send"
[ -s "$OC_LOG" ] && fail "notify.plugin=hermes: the openclaw stub must NOT be invoked once hermes is selected"
assert_match "^send --to slack:#ops $qidH: hermes-routed message" "$(cat "$H_LOG")" "notify.plugin=hermes: the hermes stub was invoked with the composed target+message"

# 8c -- a bogus notify.plugin value: send_retry_max is already 2 (section
# 3) -- two consecutive pump passes must quarantine the message with a
# clear reason, exactly like a real send failure would, rather than
# retrying forever with nothing but a stderr line to show for it. No
# spawn (openclaw OR hermes) may happen at all -- resolution fails before
# either stub is ever reached.
echo "notify.plugin=totally-bogus-plugin-name" >> orchid.config
: > "$OC_LOG"; : > "$H_LOG"
qidB="$("$ORCHID_BIN" notify "bogus plugin selector")"
"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qidB" ] || fail "bogus notify.plugin, attempt 1: outbox file must be left for the next pass (not silently dropped)"
[ -f ".orchid/runtime/outbox/$qidB.tries" ] || fail "bogus notify.plugin, attempt 1: must bump a .tries sidecar, same as a real send failure"
assert_eq "1" "$(cat ".orchid/runtime/outbox/$qidB.tries")" "bogus notify.plugin, attempt 1: tries=1"
[ -s "$OC_LOG" ] && fail "bogus notify.plugin: the openclaw stub must never be invoked"
[ -s "$H_LOG" ] && fail "bogus notify.plugin: the hermes stub must never be invoked either -- resolution fails before any spawn"

"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qidB" ] && fail "bogus notify.plugin, attempt 2 (= send_retry_max): must quarantine, same as a real send failure would"
[ -f ".orchid/runtime/outbox/$qidB.reason-send-failed" ] || fail "bogus notify.plugin: quarantine must write a .reason-send-failed sidecar"
assert_match "not found on search path" "$(cat ".orchid/runtime/outbox/$qidB.reason-send-failed")" "the quarantine reason names the resolution failure, not a generic 'send failed'"
assert_match "totally-bogus-plugin-name" "$(cat ".orchid/runtime/outbox/$qidB.reason-send-failed")" "the quarantine reason names the bogus notify.plugin value itself"

# 8d -- final review Important #2: a notify.plugin value containing a path
# separator or '..' must be refused by resolve_notify_dir BEFORE it ever
# touches the filesystem (unrefused, `$d/$name/plugin.conf` traverses out of
# every notify root, and the pump would then exec that directory's `send`
# with NO INV-09 digest/trust gate at all). Must feed the identical
# failure/quarantine path the bogus-name case above does -- never a silent
# no-op, and never a spawn of either stub. `_cfg_file_get` is last-line-wins
# (lib/common.sh), so appending a new notify.plugin= line below is enough to
# override the bogus-name value from 8c without editing the file in place.
echo "notify.plugin=../../etc" >> orchid.config
: > "$OC_LOG"; : > "$H_LOG"
qidT="$("$ORCHID_BIN" notify "traversal plugin selector")"
"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qidT" ] || fail "traversal notify.plugin, attempt 1: outbox file must be left for the next pass (not silently dropped)"
assert_eq "1" "$(cat ".orchid/runtime/outbox/$qidT.tries")" "traversal notify.plugin, attempt 1: tries=1"
[ -s "$OC_LOG" ] && fail "traversal notify.plugin: the openclaw stub must never be invoked"
[ -s "$H_LOG" ] && fail "traversal notify.plugin: the hermes stub must never be invoked either -- resolution fails before any spawn"

"$PUMP" >/dev/null 2>&1
[ -f ".orchid/runtime/outbox/$qidT" ] && fail "traversal notify.plugin, attempt 2 (= send_retry_max): must quarantine, same as a real send failure would"
[ -f ".orchid/runtime/outbox/$qidT.reason-send-failed" ] || fail "traversal notify.plugin: quarantine must write a .reason-send-failed sidecar"
assert_match "invalid notify plugin name" "$(cat ".orchid/runtime/outbox/$qidT.reason-send-failed")" "the quarantine reason names the traversal refusal, not a generic 'not found'"
