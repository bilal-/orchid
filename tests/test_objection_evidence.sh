#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/objection.sh"

# RED: a failed component hash cannot mint authority over incomplete evidence.
# GREEN: successful component hashes bind both plan and envelope contents.
cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create T001 'objection evidence fixture' >/dev/null
"$ORCHID_BIN" task set T001 candidate_sha "$(git rev-parse HEAD)" >/dev/null
plant_reviewer_envelope T001
printf '{"plan_probe":"original"}\n' > .orchid/reviews/T001-a1.review-plan.json
objection_real_hash="$(declare -f _orchid_stream_sha256)"
eval "${objection_real_hash/_orchid_stream_sha256/_objection_test_real_stream_sha256}"

for objection_probe in plan_probe j-fixture-T001; do
  objection_rc=0
  objection_error="$(
    (
      _orchid_stream_sha256() {
        local input
        input="$(cat)" || return 1
        if grep -qF "$objection_probe" <<< "$input"; then
          printf 'simulated component hash failure\n' >&2
          return 7
        fi
        printf '%s' "$input" | _objection_test_real_stream_sha256
      }
      objection_evidence "$WORK" T001
    ) 2>&1
  )" || objection_rc=$?
  [ "$objection_rc" -ne 0 ] || fail 'objection evidence must reject a failed component hash'
  assert_match 'simulated component hash failure' "$objection_error" 'component hash stderr remains visible'
  red_case "objection evidence rejects failed $objection_probe hashing even when the outer hash succeeds"

  objection_before="$(objection_evidence "$WORK" T001)" || fail 'complete objection evidence hashing succeeds'
  assert_match '^[0-9a-f]{64}$' "$objection_before" 'complete objection evidence emits its digest'
  if [ "$objection_probe" = plan_probe ]; then
    printf '{"plan_probe":"changed"}\n' > .orchid/reviews/T001-a1.review-plan.json
  else
    printf '\n' >> .orchid/reviews/T001-a1-reviewer.json
  fi
  objection_after="$(objection_evidence "$WORK" T001)" || fail 'changed objection evidence hashing succeeds'
  [ "$objection_before" != "$objection_after" ] || fail 'objection evidence must bind component bytes'
  green_case "successful objection hashing detects a byte change in $objection_probe evidence"
done
