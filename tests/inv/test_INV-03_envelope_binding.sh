#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: forged, mismatched, replayed, operation-mismatched and oversize
#      envelopes are each dropped into the real spool below and reconciled.
#      Every one must come back `quarantined` with its launch manifest still
#      on disk -- an envelope that was accepted, or one that was discarded
#      without a quarantine copy, is the failure this gate exists for.
# GREEN: a well-formed envelope bound to its own launch must be ACCEPTED
#      ("good envelope accepted" below), so the quarantines above are
#      evidence of binding rather than of a reconciler that rejects
#      everything and would pass this file while accepting nothing.
cd_scratch "$WORK" || exit 1; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
# v1-m2: `jobs prepare` resolves via resolve_role_available, gated on
# discoverability + role eligibility -- "fake" must exist on the search
# path and declare the implementer role's required capabilities.
export ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p "$WORK/eng/fake"
printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$WORK/eng/fake/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/fake/run"; chmod +x "$WORK/eng/fake/run"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 demo
m="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid="$(jq -r .job_id "$m")"; sp="$WORK/.orchid/runtime/spool"

# forged job_id -> quarantine
printf '{"contract":1,"job_id":"j-forged","task":"T001","operation":"implement","status":"ok","summary":"evil"}' > "$sp/j-forged.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: unknown job_id quarantined"
# Captured, then matched with a herestring -- never `list_dir_files ... |
# grep -q` (T016/INV-15 section 5): `grep -q` exits at its first match and
# SIGPIPEs the producer, and under helpers.sh's `set -o pipefail` that
# kill-by-signal status becomes the pipeline's, so a quarantine dir that DOES
# hold the forgery can read as empty.
quarantined_names="$(list_dir_files "$WORK/.orchid/runtime/quarantine")"
grep -q . <<<"$quarantined_names" \
  || fail "INV-03: quarantine dir holds it"
[ -f "$m" ] || fail "INV-03: manifest untouched by forgery"

# task mismatch -> quarantine
printf '{"contract":1,"job_id":"%s","task":"T999","operation":"implement","status":"ok","summary":"wrong"}' "$jid" > "$sp/$jid.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: task mismatch quarantined"
[ -f "$m" ] || fail "INV-03: manifest survives mismatch"

# replay: accept good, then same job_id again -> quarantine
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"real"}' "$jid" > "$sp/$jid.json"
assert_match "T001	ok" "$("$ORCHID_BIN" jobs reconcile)" "good envelope accepted"
green_case "an envelope genuinely bound to its own launch was ACCEPTED, so the quarantines around it are evidence of binding rather than of a reconciler that rejects everything"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"replay"}' "$jid" > "$sp/$jid-replay.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03: replay quarantined"
red_case "envelope binding quarantined a forged job_id, a task mismatch and a replay, while accepting the one envelope actually bound to its launch"

# quarantine must never clobber prior evidence: dropping the SAME forged
# filename twice across two reconciles must leave BOTH copies on disk.
qd="$WORK/.orchid/runtime/quarantine"
printf '{"contract":1,"job_id":"j-forged-repeat","task":"T001","operation":"implement","status":"ok","summary":"evil-1"}' > "$sp/j-repeat.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
printf '{"contract":1,"job_id":"j-forged-repeat","task":"T001","operation":"implement","status":"ok","summary":"evil-2"}' > "$sp/j-repeat.json"
"$ORCHID_BIN" jobs reconcile >/dev/null
count="$(list_dir_files "$qd" | grep -c '^j-repeat\.json\.reason-unknown-job')"
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
# Having served that assertion, it is cleared: an unlaunched manifest left on
# disk is exactly what `jobs prepare` refuses to duplicate since T027, and the
# reviewer/review slot is prepared again further down this same file.
rm -f "$m4"

# v0b2: same-attempt duplicate durable envelope. A relaunch of the same
# attempt (two distinct job_ids, both legitimately mapping to the same
# task+attempt+role — e.g. a crash-recovery relaunch before `attempts` was
# bumped) must never let the second acceptance silently overwrite the first
# reviewer/implementer verdict on disk. Both are forensic evidence; both must
# survive, via a counter suffix.
jobs_dir="$WORK/.orchid/runtime/jobs"
# The log path must NOT EXIST (T031). These manifests carry pid 0, and reconcile
# reads pid 0 with a log that exists as a job whose startup never resolved --
# deferred or held, never filed. `/dev/null` used to stand here and always
# exists, with an mtime that is the machine's BOOT TIME: whether these fixtures
# reconciled at all would have depended on how recently the host booted. A path
# under runtime/logs that was never created is the "no log, so the spawn line
# was never reached" this fixture always meant, said in a way that cannot drift.
for dj in j-dup-a j-dup-b; do
  jq -n --arg job_id "$dj" --arg task T001 --argjson attempt 9 --arg role implementer \
    --arg operation implement --arg engine fake \
    --arg log "$WORK/.orchid/runtime/logs/$dj.log" --arg output "$sp/$dj.json" \
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
# Cleared for the same reason $m4 was: the implementer/implement slot is
# prepared again below, and a stranded unlaunched manifest now refuses that.
rm -f "$m5"

# reset spool_max_bytes (raised above for the oversize case) back up so the
# candidate_sha fixtures below aren't spuriously quarantined as oversize.
printf 'spool_max_bytes=8192\n' >> orchid.config

# v0b2: F4 — candidate_sha is an OUTPUT of an IMPLEMENT operation, not an
# input: `jobs prepare` mints the manifest before any candidate exists, so
# its candidate_sha is the task's pre-launch (empty) value. The engine then
# produces a real candidate and the adapter's envelope carries it — that can
# never equal the manifest's empty value, so cross-checking it would
# quarantine every legitimate implement envelope. Confirm it is accepted.
m6="$("$ORCHID_BIN" jobs prepare T001 implementer implement)"
jid6="$(jq -r .job_id "$m6")"
m6_cand="$(jq -r .candidate_sha "$m6")"
[ -z "$m6_cand" ] || fail "sanity: fresh task has empty candidate_sha in manifest"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"implement","status":"ok","summary":"impl","candidate_sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}' "$jid6" > "$sp/$jid6.json"
out6="$("$ORCHID_BIN" jobs reconcile)"
# A herestring, and this NEGATIVE assertion is the direction that costs most
# (T016/INV-15 section 5): `echo ... | grep -q` is skipped by pipefail exactly
# when the pattern IS present -- grep exits at the match, SIGPIPEs `echo`, and
# the pipeline reports the kill -- so `&& fail` would never fire on the one
# output it exists to catch.
grep -q quarantined <<<"$out6" && fail "INV-03/F4: implement envelope with an output candidate_sha must NOT be quarantined ($out6)"
assert_match "T001	ok" "$out6" "INV-03/F4: implement envelope with differing candidate_sha accepted"
[ -f "$m6" ] && fail "INV-03/F4: manifest must be gone after an accepted implement envelope"

# v0b2: F4 — for review/critique, candidate_sha IS an input (it pins what's
# being reviewed), so the cross-check must still apply there: a mismatched
# candidate_sha on a review envelope is still quarantined.
m7="$("$ORCHID_BIN" jobs prepare T001 reviewer review)"
jid7="$(jq -r .job_id "$m7")"
printf '{"contract":1,"job_id":"%s","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"candidate_sha":"cafebabecafebabecafebabecafebabecafebabe"}' "$jid7" > "$sp/$jid7.json"
assert_match "quarantined" "$("$ORCHID_BIN" jobs reconcile)" "INV-03/F4: review envelope with mismatched candidate_sha still quarantined"
[ -e "$qd/$jid7.json.reason-mismatch" ] || fail "INV-03/F4: review candidate_sha mismatch quarantined with reason-mismatch"
[ -f "$m7" ] || fail "INV-03/F4: manifest survives review candidate_sha mismatch"
