#!/usr/bin/env bash
# RED: Invalid output definitions, mismatched candidates, and bad committed
# artifacts produce classified failures without disclosing artifact contents.
# GREEN: Valid schemas and immutable committed artifacts yield bounded evidence.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
unset ORCHID_ROOT
source "$REPO_ROOT/lib/output-contract.sh"
export HOME="$MACHINE_HOME"

accept_definition() {
  local out rc=0
  out="$(output_contract_validate "$1")" || rc=$?
  [ "$rc" -eq 0 ] || fail "valid contract rejected: $out"
  printf '%s' "$out" | jq -e 'type == "object" and .contract == 1' >/dev/null || fail 'valid definition is canonical JSON'
}
reject_definition() {
  local out rc=0
  out="$(output_contract_validate "$1")" || rc=$?
  [ "$rc" -ne 0 ] || fail 'invalid contract accepted'
  printf '%s' "$out" | jq -e '.passed == false and .kind == "definition"' >/dev/null || fail 'invalid definition has structured diagnostic'
}
accept_definition '{"contract":1}'
accept_definition '{"contract":1,"operations":["review"],"envelope_schema":{"type":"object","required":["summary"],"properties":{"summary":{"type":"string","minLength":1}},"additionalProperties":true}}'
for definition in '' 'null' '[]' '{"contract":2}' '{"contract":1,"unknown":true}' '{"contract":1} {"contract":1}' \
  '{"contract":1,"operations":[]}' '{"contract":1,"operations":["review","review"]}' '{"contract":1,"operations":["evaluate"]}' \
  '{"contract":1,"envelope_schema":{"$ref":"http://example.invalid/schema"}}' \
  '{"contract":1,"envelope_schema":{"pattern":".*"}}' \
  '{"contract":1,"envelope_schema":{"type":["string","null"]}}' \
  '{"contract":1,"envelope_schema":{"required":["x","x"]}}' \
  '{"contract":1,"envelope_schema":{"items":[]}}' \
  '{"contract":1,"envelope_schema":{"enum":[]}}' \
  '{"contract":1,"envelope_schema":{"minItems":2,"maxItems":1}}' \
  '{"contract":1,"envelope_schema":{"minimum":2,"maximum":1}}' \
  '{"contract":1,"envelope_schema":{"additionalProperties":{}}}'; do
  reject_definition "$definition"
done
red_case 'unknown contract/schema keys, references, executable patterns, invalid bounds, and JSON streams refuse'
green_case 'bounded explicit schema vocabulary validates without ORCHID_ROOT'

for path in '/outside' '../outside' 'a/../outside' '.git/config' '.orchid/tasks/x' 'a/.GIT/config' 'a//b' 'a/./b' 'a/' 'C:/outside' 'a\b'; do
  reject_definition "$(jq -cn --arg path "$path" '{contract:1,artifacts:[{path:$path}]}')"
done
reject_definition '{"contract":1,"artifacts":[{"path":"a\nb"}]}'
reject_definition '{"contract":1,"artifacts":[{"path":"a\u0000b"}]}'
reject_definition '{"contract":1,"artifacts":[{"path":"x","contains":["a\nb"]}]}'
reject_definition '{"contract":1,"artifacts":[{"path":"x"},{"path":"x"}]}'
reject_definition '{"contract":1,"artifacts":[{"path":"x","max_bytes":1048577}]}'
reject_definition '{"contract":1,"artifacts":[{"path":"x","min_bytes":2,"max_bytes":1}]}'
reject_definition "$(printf '{"contract":1,"envelope_schema":{"const":"\377"}}')"
accept_definition '{"contract":1,"artifacts":[{"path":"a space/:(literal)","min_bytes":0,"max_bytes":1048576,"contains":["a.*b"]}]}'
red_case 'absolute, traversal, reserved, control, ambiguous literal, duplicate, and oversized artifact definitions refuse'
green_case 'ordinary relative paths and literal constraints remain data'

deep16="$(jq -cn 'reduce range(0;16) as $i ({}; {items:.}) | {contract:1,envelope_schema:.}')"
deep17="$(jq -cn 'reduce range(0;17) as $i ({}; {items:.}) | {contract:1,envelope_schema:.}')"
accept_definition "$deep16"
reject_definition "$deep17"
accept_definition "$(jq -cn '{contract:1,artifacts:[range(0;32)|{path:("p"+tostring)}]}')"
reject_definition "$(jq -cn '{contract:1,artifacts:[range(0;33)|{path:("p"+tostring)}]}')"
base="$(jq -cn '{contract:1,envelope_schema:{const:""}}')"
bound="$(jq -cn --argjson size "$((65536 - ${#base}))" '{contract:1,envelope_schema:{const:("x"*$size)}}')"
accept_definition "$bound"
reject_definition "$(jq -cn '{contract:1,envelope_schema:{const:("x"*65536)}}')"
red_case 'schema nesting, definition bytes, and artifact cardinality exceed their hard bounds'
green_case 'schema depth sixteen, bounded definitions, and thirty-two artifacts are admitted'

mkdir -p "$WORK/repo"
cd_scratch "$WORK/repo" || exit 1
git init -q
printf '{"name":"orchid","version":2,"checks":[true,false]}\n' > result.json
printf 'kernel-secret-fixture\na.*b\n' > text.txt
printf '#!/bin/sh\nexit 0\n' > executable
chmod 755 executable
mkdir -p 'a space'
printf 'literal path\n' > 'a space/:(literal)'
printf 'literal leading pathspec\n' > ':(glob)*'
ln -s text.txt alias
git add result.json text.txt executable alias 'a space/:(literal)'
git --literal-pathspecs add -- ':(glob)*'
git commit -q -m 'committed output fixture'
candidate="$(git rev-parse HEAD)"
jq -n --arg candidate "$candidate" '{contract:1,operation:"review",status:"ok",candidate_sha:$candidate,summary:"verified",verdict:"approve",scope_complete:true}' > "$WORK/envelope.json"
schema_contract='{"contract":1,"operations":["review"],"envelope_schema":{"type":"object","required":["summary","verdict"],"properties":{"summary":{"type":"string","minLength":1,"maxLength":20},"verdict":{"enum":["approve"]}}},"artifacts":[{"path":"result.json","schema":{"type":"object","required":["name","version","checks"],"properties":{"name":{"const":"orchid"},"version":{"type":"integer","minimum":1,"maximum":3},"checks":{"type":"array","minItems":2,"maxItems":2,"items":{"type":"boolean"}}},"additionalProperties":false}},{"path":"text.txt","contains":["a.*b"],"min_bytes":1},{"path":"executable"},{"path":"a space/:(literal)"}]}'
evaluate_ok() {
  local out rc=0
  out="$(output_contract_evaluate "$WORK/repo" "$candidate" "$1" "$WORK/envelope.json")" || rc=$?
  [ "$rc" -eq 0 ] || fail "valid committed output rejected: $out"
  printf '%s' "$out" | jq -e '.passed == true and .applicable == true and .scope == "full" and .envelope_checked == true' >/dev/null || fail 'full evidence marks its actual scope'
  printf '%s' "$out"
}
evaluate_bad() {
  local expected="$1" definition="$2" bound_candidate="${3:-$candidate}" out rc=0
  out="$(output_contract_evaluate "$WORK/repo" "$bound_candidate" "$definition" "$WORK/envelope.json")" || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid output unexpectedly passed ($expected)"
  printf '%s' "$out" | jq -e --arg expected "$expected" '.passed == false and .kind == $expected and (.reason|type=="string")' >/dev/null || fail "output failure is classified as $expected"
  if grep -Fq 'kernel-secret-fixture' <<< "$out"; then fail 'failure diagnostic must not leak artifact data'; fi
}
evidence="$(evaluate_ok "$schema_contract")"
printf '%s' "$evidence" | jq -e '.artifacts|length==4' >/dev/null || fail 'all artifact evidence retained'
printf '%s' "$evidence" | jq -e 'all(.artifacts[]; (.sha256|test("^[0-9a-f]{64}$")) and (.git_blob|test("^[0-9a-f]{40,64}$")) and (.bytes|type=="number"))' >/dev/null || fail 'artifact evidence contains content digests and byte sizes'
if grep -Fq 'kernel-secret-fixture' <<< "$evidence"; then fail 'success evidence must not leak artifact data'; fi
assert_eq "$evidence" "$(evaluate_ok "$schema_contract")" 'evidence hashes are independent of temporary paths'
printf 'invalid dirty replacement\n' > result.json
assert_eq "$evidence" "$(evaluate_ok "$schema_contract")" 'dirty checkout cannot replace committed output evidence'
green_case 'committed JSON/text/executable artifacts produce stable metadata-only hashes despite dirty checkout changes'

evaluate_bad candidate "$schema_contract" HEAD
evaluate_bad candidate "$schema_contract" 0000000000000000000000000000000000000000
evaluate_bad candidate "$schema_contract" deadbeef
jq '.candidate_sha="0000000000000000000000000000000000000000"' "$WORK/envelope.json" > "$WORK/mismatch.json"
mv "$WORK/mismatch.json" "$WORK/envelope.json"
evaluate_bad candidate "$schema_contract"
jq --arg candidate "$candidate" '.candidate_sha=$candidate' "$WORK/envelope.json" > "$WORK/restored.json"
mv "$WORK/restored.json" "$WORK/envelope.json"
red_case 'symbolic, missing, abbreviated, and reply-mismatched candidates cannot acquire artifact evidence'
green_case 'the exact committed candidate remains admissible after identity refusals'

evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"missing"}]}'
printf 'uncommitted\n' > missing
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"missing"}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"alias"}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"alias/child"}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"a space"}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"text.txt","schema":{"type":"object"}}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"text.txt","contains":["aZZb"]}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"text.txt","min_bytes":1000}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"text.txt","max_bytes":1}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"result.json","schema":{"properties":{"version":{"maximum":1}}}}]}'
evaluate_bad envelope '{"contract":1,"envelope_schema":{"required":["missing"]}}'
evaluate_bad envelope '{"contract":1,"envelope_schema":{"properties":{"summary":{"type":"number"}}}}'
evaluate_bad envelope '{"contract":1,"envelope_schema":{"additionalProperties":false}}'
red_case 'missing/uncommitted/symlink/directory/schema/literal/bounds artifacts and malformed worker output fail with distinct kinds'
green_case 'accepted output after refusal still comes from the committed candidate'
evaluate_ok '{"contract":1,"artifacts":[{"path":":(glob)*"}]}' >/dev/null
green_case 'leading Git pathspec syntax is interpreted as a literal committed filename'

printf '{"operation":"review","status":"ok"}\n{"operation":"review","status":"ok"}\n' > "$WORK/stream-envelope.json"
out="$(output_contract_evaluate "$WORK/repo" "$candidate" '{"contract":1}' "$WORK/stream-envelope.json")"; rc=$?
[ "$rc" -ne 0 ] || fail 'multi-document envelope refused'
printf '%s' "$out" | jq -e '.kind=="envelope" and .passed==false' >/dev/null || fail 'envelope JSON stream has classified failure'
printf '{"operation":"review","status":"ok","summary":"\377"}' > "$WORK/invalid-utf8-envelope.json"
out="$(output_contract_evaluate "$WORK/repo" "$candidate" '{"contract":1}' "$WORK/invalid-utf8-envelope.json")"; rc=$?
[ "$rc" -ne 0 ] || fail 'invalid UTF-8 reply refused before parser replacement'
printf '%s' "$out" | jq -e '.kind=="envelope" and .passed==false' >/dev/null || fail 'invalid UTF-8 reply has envelope diagnostic'
jq '.status="failed"' "$WORK/envelope.json" > "$WORK/failure.json"
out="$(output_contract_evaluate "$WORK/repo" opaque '{"contract":1,"artifacts":[{"path":"absent"}]}' "$WORK/failure.json")" || fail 'failure diagnostics remain fileable'
printf '%s' "$out" | jq -e '.passed and (.applicable|not) and (.envelope_checked|not)' >/dev/null || fail 'failed operation does not claim output verification'
out="$(output_contract_evaluate "$WORK/repo" opaque '{"contract":1,"operations":["implement"],"artifacts":[{"path":"absent"}]}' "$WORK/envelope.json")" || fail 'non-applicable operation remains fileable'
printf '%s' "$out" | jq -e '.passed and (.applicable|not)' >/dev/null || fail 'undeclared operation has explicit nonapplicable scope'
red_case 'multiple JSON replies are not silently accepted as one envelope'
green_case 'failure and undeclared operations preserve diagnostics without claiming successful contract validation'

out="$(output_contract_artifacts "$WORK/repo" "$candidate" "$schema_contract")" || fail 'artifact-only checkpoint validation succeeds'
printf '%s' "$out" | jq -e '.passed and .applicable and .scope=="artifacts" and (.envelope_checked|not) and (has("envelope_sha256")|not)' >/dev/null || fail 'artifact recheck never claims a fresh worker reply'
out="$(output_contract_artifacts "$WORK/repo" opaque '{"contract":1,"envelope_schema":{"required":["x"]}}')" || fail 'no-artifact partial check is explicitly nonapplicable'
printf '%s' "$out" | jq -e '.scope=="artifacts" and (.applicable|not)' >/dev/null || fail 'empty artifact scope is not full contract evidence'
green_case 'checkpoint rechecks are explicitly limited to artifact subconstraints'

# Size limits are inspected from blob metadata before materializing content.
dd if=/dev/zero of=limit.bin bs=1024 count=1024 >/dev/null 2>&1 || { fail 'create maximum blob'; exit 1; }
printf 'x' > excess.bin
cat limit.bin >> excess.bin
printf '{}\n{}\n' > stream.json
printf '"\377"\n' > invalid-utf8.json
git add limit.bin excess.bin stream.json invalid-utf8.json
git update-index --add --cacheinfo "160000,$candidate,linked-repository"
git commit -q -m 'bounded artifact cases'
candidate="$(git rev-parse HEAD)"
jq --arg candidate "$candidate" '.candidate_sha=$candidate' "$WORK/envelope.json" > "$WORK/new-envelope.json"
mv "$WORK/new-envelope.json" "$WORK/envelope.json"
evaluate_ok '{"contract":1,"artifacts":[{"path":"limit.bin","min_bytes":1048576,"max_bytes":1048576}]}' >/dev/null
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"excess.bin"}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"stream.json","schema":{}}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"invalid-utf8.json","schema":{"type":"string"}}]}'
evaluate_bad artifact '{"contract":1,"artifacts":[{"path":"linked-repository"}]}'
too_large="$(jq -cn --arg candidate "$candidate" '{operation:"review",status:"ok",candidate_sha:$candidate,summary:("x"*1048576)}')"
printf '%s' "$too_large" > "$WORK/oversize-envelope.json"
out="$(output_contract_evaluate "$WORK/repo" "$candidate" '{"contract":1}' "$WORK/oversize-envelope.json")"; rc=$?
[ "$rc" -ne 0 ] || fail 'oversized worker reply is bounded before schema admission'
printf '%s' "$out" | jq -e '.kind=="envelope" and .passed==false' >/dev/null || fail 'oversized worker output has envelope diagnostic'
red_case 'oversized committed blobs and JSON artifact streams fail bounded artifact admission'
green_case 'a blob exactly at one MiB passes without relaxing the default hard ceiling'

# A malformed worker reply must never become hashed passing evidence.
printf '{"operation":"implement","status":"ok","result":+1}\n' > "$WORK/number-envelope.json"
number_contract='{"contract":1,"envelope_schema":{"properties":{"result":{"type":"integer","const":1}}}}'
rc=0
out="$(output_contract_evaluate "$WORK/repo" "$candidate" "$number_contract" "$WORK/number-envelope.json")" || rc=$?
[ "$rc" -ne 0 ] || fail 'nonstandard JSON envelope must be refused'
printf '%s' "$out" | jq -e '.kind=="envelope" and .passed==false' >/dev/null || fail 'malformed numeric envelope diagnostic'
red_case 'a jq numeric extension cannot become passing output evidence'
printf '{"operation":"implement","status":"ok","result":1}\n' > "$WORK/number-envelope.json"
output_contract_evaluate "$WORK/repo" "$candidate" "$number_contract" "$WORK/number-envelope.json" >/dev/null || fail 'standard numeric envelope passes identical schema'
green_case 'standard JSON passes the same evidence contract'

[ "$FAILS" -eq 0 ]
