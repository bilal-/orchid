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
