#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/ledger.sh"
export HOME="$WORK/home"; mkdir -p "$HOME/.orchid"

# ---------------------------------------------------------------------------
# Unit-level: ledger_mark / ledger_available / ledger_show against a bare
# repo dir (no orchid init needed -- these three functions only ever touch
# <repo>/.orchid/runtime/engines.json).
# ---------------------------------------------------------------------------
repo="$WORK/repo"; mkdir -p "$repo/.orchid"
lf="$repo/.orchid/runtime/engines.json"

# missing ledger file: every engine available
ledger_available "$repo" nope || fail "missing ledger file -> every engine available"

# rate_limited: unavailable now, available again once the window (faked via
# a direct jq rewrite of rate_limited_until, simulating time passing) is past
ledger_mark "$repo" acme rate_limited 60
[ -f "$lf" ] || fail "ledger_mark creates the ledger file"
ledger_available "$repo" acme && fail "engine must be unavailable immediately after a rate_limited mark"
assert_eq rate_limited "$(jq -r '.acme.status' "$lf")" "rate_limited mark sets status"
now="$(date +%s)"
past=$(( now - 1 ))
jq --argjson p "$past" '.acme.rate_limited_until = $p' "$lf" | atomic_write "$lf"
ledger_available "$repo" acme || fail "a past rate_limited_until must be available again, even before any ok mark"

# retry_after=0 (not a positive integer) must fall back to the
# rate_limit_backoff_s default (3600), not now+0
ledger_mark "$repo" eps rate_limited 0
u="$(jq -r '.eps.rate_limited_until' "$lf")"
d=$(( u - $(date +%s) ))
[ "$d" -gt 3000 ] || fail "retry_after=0 must fall back to rate_limit_backoff_s default (got ${d}s)"

# three consecutive failed marks -> unavailable; status flips to "failing"
# only once the default threshold (3) is reached
ledger_mark "$repo" beta failed
ledger_mark "$repo" beta failed
ledger_available "$repo" beta || fail "2 consecutive failures (below default threshold 3) must still be available"
assert_eq ok "$(jq -r '.beta.status' "$lf")" "status stays ok below threshold"

# v1-m3 (m2 ledger finding): ledger_show's detail column must surface a
# sub-threshold consecutive_failures count even while status is still "ok"
# -- an operator staring at `orchid status` should see an engine is
# accumulating failures before it actually flips to "failing", not just
# after.
line="$(ledger_show "$repo" | grep '^beta	')"
assert_match "^beta	ok	failures 2\$" "$line" "ledger_show: sub-threshold consecutive_failures>0 shows 'failures <n>' even while status is still ok"

ledger_mark "$repo" beta failed
ledger_available "$repo" beta && fail "3 consecutive failures must make the engine unavailable"
assert_eq 3 "$(jq -r '.beta.consecutive_failures' "$lf")" "consecutive_failures counted"
assert_eq failing "$(jq -r '.beta.status' "$lf")" "status flips to failing at threshold"

# one ok mark resets failures and restores availability
ledger_mark "$repo" beta ok
ledger_available "$repo" beta || fail "an ok mark must restore availability"
assert_eq 0 "$(jq -r '.beta.consecutive_failures' "$lf")" "ok mark resets consecutive_failures"
assert_eq 0 "$(jq -r '.beta.rate_limited_until' "$lf")" "ok mark resets rate_limited_until"
assert_eq ok "$(jq -r '.beta.status' "$lf")" "ok mark resets status"

# engine_fail_threshold / rate_limit_backoff_s config keys are honored
printf 'engine_fail_threshold=2\nrate_limit_backoff_s=10\n' > "$repo/orchid.config"
ledger_mark "$repo" gamma failed
ledger_mark "$repo" gamma failed
assert_eq failing "$(jq -r '.gamma.status' "$lf")" "engine_fail_threshold config is honored (threshold=2)"
ledger_mark "$repo" delta rate_limited notanumber
d="$(( $(jq -r '.delta.rate_limited_until' "$lf") - $(date +%s) ))"
[ "$d" -ge 8 ] && [ "$d" -le 12 ] || fail "rate_limit_backoff_s config is honored (expected ~10s, got ${d}s)"
rm -f "$repo/orchid.config"

# ledger_show formatting: ok -> "-", rate_limited -> "until <iso>", failing -> "failures <n>"
ledger_mark "$repo" zeta ok
line="$(ledger_show "$repo" | grep '^zeta	')"
assert_match "^zeta	ok	-\$" "$line" "ledger_show: ok engine detail is '-'"
line="$(ledger_show "$repo" | grep '^acme	')"
assert_match "^acme	rate_limited	until [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$" "$line" "ledger_show: rate_limited detail is 'until <iso>'"
line="$(ledger_show "$repo" | grep '^beta	')"
assert_match "^beta	ok	-\$" "$line" "ledger_show: beta was reset to ok by the earlier ok mark"
ledger_mark "$repo" theta failed; ledger_mark "$repo" theta failed; ledger_mark "$repo" theta failed
line="$(ledger_show "$repo" | grep '^theta	')"
assert_match "^theta	failing	failures 3\$" "$line" "ledger_show: failing detail is 'failures <n>'"

unset repo lf

# ---------------------------------------------------------------------------
# Integration: `orchid jobs reconcile` marks the ledger from the MANIFEST's
# engine (never the envelope's self-reported one), and quarantined envelopes
# never touch the ledger. `orchid status` shows the engines section.
# ---------------------------------------------------------------------------
full="$WORK/fullrepo"
mkdir -p "$full"; (cd "$full" && git init -q . && git commit -q --allow-empty -m root)
mkdir -p "$full/.orchid/tasks" "$full/.orchid/reviews"
export ORCHID_REPO="$full"
printf 'verify=true\nrole.implementer=acme\n' > "$full/orchid.config"
# v1-m2: `jobs prepare` resolves via resolve_role_available, gated on
# discoverability + role eligibility -- "acme" must actually exist on the
# real search path ($HOME/.orchid/plugins/engines, already exported above)
# and declare the implementer role's required capabilities.
mkdir -p "$HOME/.orchid/plugins/engines/acme"
printf 'manifest_version=1\nid=test/acme\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$HOME/.orchid/plugins/engines/acme/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$HOME/.orchid/plugins/engines/acme/run"
chmod +x "$HOME/.orchid/plugins/engines/acme/run"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo

m="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid="$(jq -r .job_id "$m")"
out="$(jq -r .output "$m")"
printf '{"contract":1,"job_id":"%s","task":"T001","status":"rate_limited","retry_after":120}' "$jid" > "$out"
line="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	rate_limited" "$line" "reconcile reports the rate_limited envelope"

flf="$full/.orchid/runtime/engines.json"
[ -f "$flf" ] || fail "reconcile creates the ledger file"
assert_eq 1 "$(jq -r 'keys | length' "$flf")" "ledger has exactly one engine entry"
assert_eq acme "$(jq -r 'keys[0]' "$flf")" "reconcile ledger-marks the MANIFEST's engine ('acme'), not an envelope-reported one"
assert_eq rate_limited "$(jq -r '.acme.status' "$flf")" "reconcile marks rate_limited"
d=$(( $(jq -r '.acme.rate_limited_until' "$flf") - $(date +%s) ))
[ "$d" -ge 110 ] && [ "$d" -le 130 ] || fail "reconcile passes the envelope's retry_after (120) through to ledger_mark (got ${d}s)"

# Reset acme to 'ok' before the next prepare call below: the rate_limited
# mark just asserted above would otherwise make acme -- implementer's ONLY
# configured engine here, no fallback configured -- ledger-unavailable, and
# `jobs prepare` would (correctly, per v1-m2's resolve_role_available gate)
# refuse with "no eligible engine available". That refusal is working as
# designed; it's just orthogonal to what this section actually tests (the
# mismatched-engine-field quarantine path), so give it a healthy engine.
ledger_mark "$full" acme ok
before="$(jq -c . "$flf")"

# a mismatched self-reported `engine` field is quarantined -- must never
# reach ledger_mark at all
m2="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid2="$(jq -r .job_id "$m2")"
out2="$(jq -r .output "$m2")"
printf '{"contract":1,"job_id":"%s","task":"T001","status":"rate_limited","retry_after":5,"engine":"orchid/not-acme"}' "$jid2" > "$out2"
line2="$("$ORCHID_BIN" jobs reconcile)"
assert_match "quarantined:.*\(mismatch\)" "$line2" "envelope with a mismatched engine field is quarantined"
assert_eq "$before" "$(jq -c . "$flf")" "quarantined mismatch envelope must leave the ledger byte-for-byte untouched"

# Restore a rate_limited mark for the `status` assertion below (reset to
# 'ok' above so the mismatch-envelope prepare call could proceed).
ledger_mark "$full" acme rate_limited 120

status_out="$("$ORCHID_BIN" status)"
assert_match "== engines" "$status_out" "status prints the engines section"
assert_match "acme	rate_limited	until" "$status_out" "status's engines section shows ledger_show's output"

# empty ledger -> explicit placeholder, in an otherwise-uninitialized repo
empty="$WORK/emptyrepo"
mkdir -p "$empty"; (cd "$empty" && git init -q . && git commit -q --allow-empty -m root)
empty_out="$(ORCHID_REPO="$empty" "$ORCHID_BIN" status)"
assert_match "\(no engine events yet\)" "$empty_out" "empty/missing ledger prints the placeholder line"
