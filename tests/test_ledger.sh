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

# ---------------------------------------------------------------------------
# v1-m5 (T008): a CAPABILITY REFUSAL is not an engine fault. `agy` declining a
# diff over agy_max_bytes -- naming the limit, the actual size and the remedy
# -- is the adapter doing exactly what it was designed to do, so it must cost
# the engine nothing. BOTH fields are asserted, not just the counter:
# consecutive_failures is what resolve_role_available gates on (via
# ledger_available), and last_status is this ledger's record of what actually
# happened -- an operator reading runtime/engines.json after a refusal must
# not find a fault filed against an engine that never committed one.
# ---------------------------------------------------------------------------
# An engine whose ONLY events are refusals: threshold-many of them (default 3)
# leave it completely healthy and available. This is the r-002 case exactly --
# three refusals marked agy `failing` and cost that run a reviewer.
ledger_mark "$repo" refuseonly failed "" capability
ledger_mark "$repo" refuseonly failed "" capability
ledger_mark "$repo" refuseonly failed "" capability
assert_eq 0 "$(jq -r '.refuseonly.consecutive_failures' "$lf")" "a capability refusal leaves consecutive_failures unchanged (3 refusals, still 0)"
assert_eq refused "$(jq -r '.refuseonly.last_status' "$lf")" "a capability refusal records last_status 'refused', never 'failed'"
assert_eq ok "$(jq -r '.refuseonly.status' "$lf")" "threshold-many capability refusals never flip the engine to failing"
assert_eq 0 "$(jq -r '.refuseonly.rate_limited_until' "$lf")" "a first-ever refusal writes a complete healthy record, not a partial one"
ledger_available "$repo" refuseonly || fail "an engine that has only ever refused work outside its contract must stay available"
assert_eq 3 "$(jq -r '.refuseonly.capability_refusals' "$lf")" "refusals are counted separately so they are visible rather than silent (dogfood F12)"
line="$(ledger_show "$repo" | grep '^refuseonly	')"
assert_match "^refuseonly	ok	refusals 3\$" "$line" "ledger_show reports refusals without the word 'failures' next to a well-behaved engine"

# The same engine, both kinds of event: a genuine fault still increments, and a
# refusal in between neither advances nor clears the streak it is sitting in.
ledger_mark "$repo" mixed failed
assert_eq 1 "$(jq -r '.mixed.consecutive_failures' "$lf")" "a genuine fault increments consecutive_failures"
assert_eq failed "$(jq -r '.mixed.last_status' "$lf")" "a genuine fault records last_status 'failed'"
ledger_mark "$repo" mixed failed "" capability
assert_eq 1 "$(jq -r '.mixed.consecutive_failures' "$lf")" "a capability refusal does not advance an existing failure streak"
assert_eq refused "$(jq -r '.mixed.last_status' "$lf")" "the refusal is still recorded as the last event"
ledger_mark "$repo" mixed timeout
assert_eq 2 "$(jq -r '.mixed.consecutive_failures' "$lf")" "a capability refusal does not clear an existing failure streak either"
line="$(ledger_show "$repo" | grep '^mixed	')"
assert_match "^mixed	ok	failures 2 refusals 1\$" "$line" "ledger_show reports both counts when both are nonzero"
ledger_mark "$repo" mixed ok
assert_eq 0 "$(jq -r '.mixed.consecutive_failures' "$lf")" "an ok mark still resets consecutive_failures"
assert_eq 1 "$(jq -r '.mixed.capability_refusals' "$lf")" "an ok mark does not erase the cumulative refusal count"

# failure_kind is honored ONLY where there is a fault to reclassify: a
# `capability` claim on a rate_limited envelope must not suppress the
# rate-limit window.
ledger_mark "$repo" rlrefuse rate_limited 999999 capability
assert_eq rate_limited "$(jq -r '.rlrefuse.status' "$lf")" "a capability claim on a rate_limited envelope is ignored, not obeyed"
assert_eq rate_limited "$(jq -r '.rlrefuse.last_status' "$lf")" "a rate_limited mark still records last_status rate_limited"
ledger_available "$repo" rlrefuse && fail "a capability claim must not open a rate-limited engine back up"

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

# v1-m5 (T008): end to end, `jobs reconcile` carries the envelope's own
# `failure_kind` through to ledger_mark, so a capability refusal costs the
# engine nothing even though the envelope's status really is `failed` (which
# it must remain: every downstream gate goes on skipping it exactly as before,
# and the filed envelope under reviews/ is the durable record of the refusal).
m3="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid3="$(jq -r .job_id "$m3")"
out3="$(jq -r .output "$m3")"
printf '{"contract":1,"job_id":"%s","task":"T001","status":"failed","failure_kind":"capability","summary":"diff.patch is 101108 bytes (> agy_max_bytes=100000)"}' "$jid3" > "$out3"
line3="$("$ORCHID_BIN" jobs reconcile)"
assert_match "T001	failed" "$line3" "reconcile accepts and reports the refusal envelope like any other non-ok envelope"
assert_match "^refusal: T001 acme declined by design" "$line3" "reconcile names the capability refusal on its own line, so it is not silent in the run's output"
assert_eq 0 "$(jq -r '.acme.consecutive_failures' "$flf")" "reconcile: a capability refusal does not increment consecutive_failures"
assert_eq refused "$(jq -r '.acme.last_status' "$flf")" "reconcile: a capability refusal is recorded as 'refused', not 'failed'"
assert_eq 1 "$(jq -r '.acme.capability_refusals' "$flf")" "reconcile: the refusal is counted where an operator can see it"
# The whole point of the distinction: the engine is still dispatchable, so the
# role's chain never silently shortens (the r-002 cascade started here).
resolved="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
assert_eq acme "$(jq -r .engine "$resolved")" "an engine that refused stays resolvable for the very next job"
# That prepare was a resolution probe, never launched -- sweep its pid-0
# manifest so the sections below start from the same clean runtime they used
# to (ordinary `gc` deliberately skips pid-0 manifests; --reap-prepared is the
# mode that targets exactly them). Best-effort, deliberately not asserted:
# --reap-prepared compares the manifest's file mtime with `-gt`, so a manifest
# minted in this same second is still too young and survives. Nothing below
# depends on it either way -- `jobs reconcile` walks the SPOOL, not the
# manifest dir, and a manifest with no envelope beside it is invisible to that
# walk (which is exactly why the probe could not be left to the ordinary gc).
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 >/dev/null

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
