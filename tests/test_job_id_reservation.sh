#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
# RED: a colliding job ID must not replace a live job or legacy evidence.
# GREEN: an unused job ID reserves its namespace and launches normally.
export ORCHID_ROOT="$REPO_ROOT" HOME="$MACHINE_HOME"

cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" ORCHID_ENGINES_DIR="$WORK/eng"
mkdir -p .orchid/tasks .orchid/reviews "$ORCHID_ENGINES_DIR/fake" "$WORK/nonce-bin"
printf 'verify=true\nrole.implementer=fake\n' > orchid.config
cat > "$ORCHID_ENGINES_DIR/fake/plugin.conf" <<'CONF'
manifest_version=1
id=test/fake
version=1.0.0
kind=engine
api_version=1
capabilities=workspace_write,shell,git
entrypoint=run
CONF
printf '#!/bin/bash\ntrue\n' > "$ORCHID_ENGINES_DIR/fake/run"
chmod +x "$ORCHID_ENGINES_DIR/fake/run"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create N001 collision >/dev/null
printf '#!/bin/bash\nprintf abcd\n' > "$WORK/nonce-bin/xxd"
chmod +x "$WORK/nonce-bin/xxd"
export PATH="$WORK/nonce-bin:$PATH"

first="$("$ORCHID_BIN" jobs prepare N001 implementer implement)" || exit 1
sleep 100 & owner_pid=$!
trap 'kill "$owner_pid" 2>/dev/null || true; wait "$owner_pid" 2>/dev/null || true; _scratch_cleanup' EXIT
jq --argjson pid "$owner_pid" '.pid=$pid | .pgid=0 | .ownership_marker="live-job"' "$first" > "$first.tmp"
mv "$first.tmp" "$first"
plant_job_process_identity "$first"
cp "$first" "$WORK/original.json"
rc=0; refused="$("$ORCHID_BIN" jobs prepare N001 implementer implement 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'a repeated nonce cannot replace a live job'
cmp -s "$WORK/original.json" "$first" || fail 'collision keeps the entire live manifest'
kill -0 "$owner_pid" || fail 'collision leaves the owned process alive'
assert_match 'unused job id' "$refused" 'collision exhaustion names its refusal'
red_case 'repeated job nonce preserves live PID identity and refuses allocation'

printf '#!/bin/bash\nprintf abce\n' > "$WORK/nonce-bin/xxd"
second="$("$ORCHID_BIN" jobs prepare N001 implementer implement)" || fail 'fresh nonce is accepted'
[ "$second" != "$first" ] && [ -f "$second" ] || fail 'fresh nonce creates a separate job'
cmp -s "$WORK/original.json" "$first" || fail 'fresh nonce preserves the earlier identity'
green_case 'fresh nonce admits the same task without disturbing its live job'

# Allocation is shared with question IDs and protects every legacy artifact,
# including names whose manifest has already disappeared and dangling links.
for artifact in jobs/ID.json spool/ID.json logs/ID.log requests/ID.json packs/ID exits/ID exits/ID.tmp quarantine/ID.json.reason-invalid spool/bad/ID.json jobs/ID.reserved broken history; do
  fixture="$WORK/artifact-${artifact//\//_}"
  rt="$fixture/.orchid/runtime"
  old_id=j-e1-N001-a1-abcd
  if [ "$artifact" = history ]; then
    old_path="$rt/jobs-history.tsv"
    mkdir -p "$rt"
    printf '1\t%s\tN001\n' "$old_id" > "$old_path"
  elif [ "$artifact" = broken ]; then
    old_path="$rt/requests/$old_id.json"
    mkdir -p "$(dirname "$old_path")"
    ln -s missing "$old_path"
  else
    old_path="$rt/${artifact/ID/$old_id}"
    mkdir -p "$(dirname "$old_path")"
    case "$artifact" in packs/*|*.reserved) mkdir "$old_path" ;; *) printf keep > "$old_path" ;; esac
  fi
  printf '#!/bin/bash\nprintf abcd\n' > "$WORK/nonce-bin/xxd"
  rc=0; orchid_job_id_reserve "$fixture" j-e1-N001-a1 >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "existing $artifact must occupy its job ID"
  [ -e "$old_path" ] || [ -L "$old_path" ] || fail "existing $artifact was lost"
  red_case "job ID allocation refuses the occupied $artifact namespace"
  printf '#!/bin/bash\nprintf abce\n' > "$WORK/nonce-bin/xxd"
  allocated="$(orchid_job_id_reserve "$fixture" j-e1-N001-a1)" || fail "fresh ID rejected beside $artifact"
  assert_eq j-e1-N001-a1-abce "$allocated" "fresh ID accepted beside $artifact"
  [ -d "$rt/jobs/$allocated.reserved" ] || fail 'allocation leaves a permanent exclusive claim'
  green_case "fresh job ID remains available beside $artifact"
done

# The shared question allocator also treats a dangling legacy artifact as an
# occupied ID, rather than replacing it during a later notification.
qid_repo="$WORK/qid-dangling"
mkdir -p "$qid_repo/.orchid/runtime/answers"
ln -s missing "$qid_repo/.orchid/runtime/answers/q-1-abcd.question"
printf '#!/bin/bash\nprintf abcd\n' > "$WORK/nonce-bin/xxd"
rc=0; orchid_qid_reserve "$qid_repo" 1 >/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail 'dangling question artifact must occupy its ID'
red_case 'shared question allocation refuses dangling legacy artifacts'
printf '#!/bin/bash\nprintf abce\n' > "$WORK/nonce-bin/xxd"
assert_eq q-1-abce "$(orchid_qid_reserve "$qid_repo" 1)" 'fresh question ID beside dangling artifact'
green_case 'shared question allocation still accepts an unused ID'

# GC removes manifests; allocation claims intentionally survive that cleanup.
printf '#!/bin/bash\nprintf abce\n' > "$WORK/nonce-bin/xxd"
touch -t 200001010000 "$second"
"$ORCHID_BIN" jobs gc --reap-prepared --older-than-s 0 >/dev/null
[ ! -e "$second" ] || fail 'prepared manifest was reaped'
[ -d "${second%.json}.reserved" ] || fail 'GC must preserve the retired allocation claim'
rc=0; orchid_job_id_reserve "$WORK" "j-e${ORCHID_EPOCH}-N001-a1" >/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail 'retired job ID must not be reused after GC'
red_case 'retired allocation stays occupied after GC removes the manifest'
printf '#!/bin/bash\nprintf abcf\n' > "$WORK/nonce-bin/xxd"
assert_eq "j-e${ORCHID_EPOCH}-N001-a1-abcf" "$(orchid_job_id_reserve "$WORK" "j-e${ORCHID_EPOCH}-N001-a1")" 'fresh ID after GC is accepted'
green_case 'GC retention does not block a fresh job ID'

exit "$FAILS"
