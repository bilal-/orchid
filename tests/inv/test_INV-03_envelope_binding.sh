#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
export ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
"$ORCHID_BIN" task create T001 demo
m="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid="$(jq -r .job_id "$m")"; sp="$WORK/.orchid/runtime/spool"

# forged job_id -> quarantine
printf '{"contract":1,"job_id":"j-forged","task":"T001","operation":"implement","status":"ok","summary":"evil"}' > "$sp/j-forged.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: unknown job_id quarantined"
[ -e "$WORK/.orchid/runtime/quarantine/"* ] || fail "INV-03: quarantine dir holds it"
[ -f "$m" ] || fail "INV-03: manifest untouched by forgery"

# task mismatch -> quarantine
printf '{"contract":1,"job_id":"%s","task":"T999","operation":"implement","status":"ok","summary":"wrong"}' "$jid" > "$sp/$jid.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: task mismatch quarantined"
[ -f "$m" ] || fail "INV-03: manifest survives mismatch"

# replay: accept good, then same job_id again -> quarantine
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"real"}' "$jid" > "$sp/$jid.json"
assert_match "T001	ok" "$("$ORCHID_BIN" jobs reconcile)" "good envelope accepted"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"replay"}' "$jid" > "$sp/$jid-replay.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: replay quarantined"

# quarantine must never clobber prior evidence: dropping the SAME forged
# filename twice across two reconciles must leave BOTH copies on disk.
qd="$WORK/.orchid/runtime/quarantine"
printf '{"contract":1,"job_id":"j-forged-repeat","task":"T001","operation":"implement","status":"ok","summary":"evil-1"}' > "$sp/j-repeat.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
printf '{"contract":1,"job_id":"j-forged-repeat","task":"T001","operation":"implement","status":"ok","summary":"evil-2"}' > "$sp/j-repeat.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
count="$(ls "$qd" | grep -c '^j-repeat\.json\.reason-unknown-job')"
assert_eq "2" "$count" "quarantine: repeat forged filename preserves both copies"
c1="$(cat "$qd/j-repeat.json.reason-unknown-job" 2>/dev/null)"
c2="$(cat "$qd/j-repeat.json.reason-unknown-job.2" 2>/dev/null)"
[ -n "$c1" ] && [ -n "$c2" ] && [ "$c1" != "$c2" ] || fail "quarantine: repeat copies must have distinct contents"
