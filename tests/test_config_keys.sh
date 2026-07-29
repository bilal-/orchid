#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# v1-m2 (Task 10): a config-key coverage check -- lib/config-keys.txt is
# meant to be the COMPLETE key reference (orchid.config.example's own header
# says so: "Full key reference: lib/config-keys.txt"). Two directions are
# checked, both one-way (config-keys.txt as the superset being verified
# against):
#
#   1. Every `key=value` (live or commented-out) line in orchid.config.example
#      names a key that is actually a line in lib/config-keys.txt -- this is
#      fully mechanical (every line in that file IS a key assignment, no
#      prose ambiguity), so it is checked exhaustively.
#   2. Every config key PROTOCOL.md documents with the file's own
#      "`key` (config, default ...)" / "(`key`, config, default ...)"
#      annotation convention is also a line in lib/config-keys.txt -- checked
#      only for text actually written in that annotated shape (PROTOCOL.md is
#      full of OTHER backticked tokens -- verbs, frontmatter fields, statuses
#      -- that are not config keys at all, so a blanket backtick scan would
#      false-positive; the "(config, default" annotation is what THIS file
#      itself uses, consistently, to mark an actual config key).
#
# This is the RED-first regression net for Task 10: run against v1-m1's
# PROTOCOL.md/config-keys.txt (before this milestone's edits), it fails
# because `arbiter_wait_s` is named in the new HEADLESS OPERATION section
# but absent from config-keys.txt/orchid.config.example.

KEYFILE="$REPO_ROOT/lib/config-keys.txt"
EXAMPLE="$REPO_ROOT/orchid.config.example"
PROTOCOL="$REPO_ROOT/PROTOCOL.md"
[ -f "$KEYFILE" ] || fail "lib/config-keys.txt missing"
[ -f "$EXAMPLE" ] || fail "orchid.config.example missing"
[ -f "$PROTOCOL" ] || fail "PROTOCOL.md missing"

key_known() {  # key -> 0 iff it's an exact line in config-keys.txt
  grep -qxF "$1" "$KEYFILE"
}

# -- 1. orchid.config.example: every key=value line (commented or not) ------
example_count=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  example_count=$((example_count + 1))
  key_known "$key" || fail "orchid.config.example sets '$key' but lib/config-keys.txt has no such line"
done < <(grep -oE '^#? *[a-zA-Z_][a-zA-Z_.]*=' "$EXAMPLE" | sed -E 's/^#? *//; s/=$//' | sort -u)
[ "$example_count" -gt 0 ] || fail "orchid.config.example key extraction found nothing -- regex broken?"

# -- 2. PROTOCOL.md: keys annotated "(config, default ...)" in either of the
# two shapes this file actually uses --------------------------------------
protocol_count=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  protocol_count=$((protocol_count + 1))
  key_known "$key" || fail "PROTOCOL.md documents config key '$key' but lib/config-keys.txt has no such line"
done < <(
  {
    grep -oE '`[a-zA-Z_][a-zA-Z_.]*`[[:space:]]*\(config' "$PROTOCOL" | sed -E 's/`([a-zA-Z_.]+)`.*/\1/'
    grep -oE '\(`[a-zA-Z_][a-zA-Z_.]*`, config,' "$PROTOCOL" | sed -E 's/\(`([a-zA-Z_.]+)`.*/\1/'
  } | sort -u
)
[ "$protocol_count" -gt 0 ] || fail "PROTOCOL.md '(config, default ...)' extraction found nothing -- regex broken, or the annotation convention changed"

# -- 3. Every m2-new key the brief names explicitly is present everywhere --
for key in concurrency rate_limit_backoff_s engine_fail_threshold \
           verb_lock_wait_s pump_stale_s arbiter_wait_s \
           review.low review.medium review.high; do
  key_known "$key" || fail "v1-m2 config key '$key' missing from lib/config-keys.txt"
  grep -qF "$key" "$EXAMPLE" || fail "v1-m2 config key '$key' missing from orchid.config.example"
done

# -- 4. Every m3-new key (Task 12) is present everywhere -- hook.<point>
# family + hook_timeout_s (lib/hooks.sh, Task 6) and lessons_max_bytes
# (lib/lessons.sh, Task 11). role.<id>.blocking is checked against
# config-keys.txt only: it is a PATTERN (a literal "<id>" placeholder), not
# a real key=value line, so orchid.config.example documents it in prose +
# a commented example (`role.<id>.blocking=false`) that check #1 above
# can't parse as a key=value assignment either -- its actual behavior is
# covered functionally by tests/test_roles.sh and tests/test_custom_roles.sh
# (role_binding_blocking), not this doc-coverage check.
for key in hook.after_plan_draft hook.before_arbitration hook.on_verify_fail \
           hook.before_merge hook.on_blocker hook_timeout_s lessons_max_bytes; do
  key_known "$key" || fail "v1-m3 config key '$key' missing from lib/config-keys.txt"
  grep -qF "$key" "$EXAMPLE" || fail "v1-m3 config key '$key' missing from orchid.config.example"
done
key_known "role.<id>.blocking" || fail "v1-m3 config key pattern 'role.<id>.blocking' missing from lib/config-keys.txt"
grep -qF "role.<id>.blocking" "$EXAMPLE" || fail "v1-m3 config key pattern 'role.<id>.blocking' not documented in orchid.config.example"

# ORCHID_HB_INTERVAL_S (lib/heartbeat.sh, Task 3) is deliberately an
# ENV-ONLY override, never layered through config_get -- it must NOT appear
# in lib/config-keys.txt (which is specifically the layered-config key
# reference: env > repo orchid.config > user ~/.orchid/config > defaults).
if key_known ORCHID_HB_INTERVAL_S; then
  fail "ORCHID_HB_INTERVAL_S is an env-only override (lib/heartbeat.sh) -- it must not be listed in lib/config-keys.txt as a layered config key"
fi
