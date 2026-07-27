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

# v0b2: operation cross-check. A forged/buggy envelope that otherwise passes
# structural validation (real job_id, matching task, well-formed for its
# claimed operation) but whose `operation` disagrees with what the manifest
# actually recorded must still be caught — the manifest is what `orchid jobs
# prepare` minted (kernel-controlled), the envelope's operation field is
# whatever the tier-3 adapter claims, and those two must agree.
m4="$("$ORCHID_BIN" jobs prepare T001 reviewer review)"
jid4="$(jq -r .job_id "$m4")"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"op-mismatch"}' "$jid4" > "$sp/$jid4.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: operation mismatch quarantined"
[ -e "$qd/$jid4.json.reason-mismatch" ] || fail "INV-03: operation-mismatch envelope quarantined with reason-mismatch"
[ -f "$m4" ] || fail "INV-03: manifest survives operation mismatch"

# v0b2: same-attempt duplicate durable envelope. A relaunch of the same
# attempt (two distinct job_ids, both legitimately mapping to the same
# task+attempt+role — e.g. a crash-recovery relaunch before `attempts` was
# bumped) must never let the second acceptance silently overwrite the first
# reviewer/implementer verdict on disk. Both are forensic evidence; both must
# survive, via a counter suffix.
jobs_dir="$WORK/.orchid/runtime/jobs"
for dj in j-dup-a j-dup-b; do
  jq -n --arg job_id "$dj" --arg task T001 --argjson attempt 9 --arg role implementer \
    --arg operation implement --arg engine fake --arg log "/dev/null" --arg output "$sp/$dj.json" \
    --arg base_sha "" --arg candidate_sha "" \
    '{job_id:$job_id, task:$task, attempt:$attempt, role:$role, operation:$operation,
      engine:$engine, pid:0, pgid:0, started_at:0, log:$log, output:$output,
      base_sha:$base_sha, candidate_sha:$candidate_sha}' > "$jobs_dir/$dj.json"
  printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"dup-%s"}' "$dj" "$dj" > "$sp/$dj.json"
done
"$ORCHID_BIN" jobs reconcile >/dev/null
[ -f ".orchid/reviews/T001-a9-implementer.json" ] || fail "INV-03: first same-attempt envelope moved durable"
[ -f ".orchid/reviews/T001-a9-implementer.2.json" ] || fail "INV-03: duplicate same-attempt envelope preserved via counter suffix, not overwritten"
dc1="$(cat ".orchid/reviews/T001-a9-implementer.json")"
dc2="$(cat ".orchid/reviews/T001-a9-implementer.2.json")"
[ -n "$dc1" ] && [ -n "$dc2" ] && [ "$dc1" != "$dc2" ] || fail "INV-03: both same-attempt copies must have distinct contents"

# v0b2: spool_max_bytes oversize quarantine. A spool file bigger than the
# configured budget is quarantined on size alone, before any JSON parsing —
# a cheap, early defense against a runaway/forged tier-3 adapter dumping an
# oversized payload into the spool directory.
m5="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid5="$(jq -r .job_id "$m5")"
printf 'spool_max_bytes=64\n' >> orchid.config
big_summary="$(printf 'x%.0s' $(seq 1 100))"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"%s"}' "$jid5" "$big_summary" > "$sp/$jid5.json"
sz="$(wc -c < "$sp/$jid5.json" | tr -d ' ')"
[ "$sz" -gt 64 ] || fail "sanity: oversize fixture actually exceeds spool_max_bytes"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: oversize spool file quarantined"
[ -e "$qd/$jid5.json.reason-oversize" ] || fail "INV-03: oversize envelope quarantined with reason-oversize"
[ -f "$m5" ] || fail "INV-03: manifest survives oversize spool file"
