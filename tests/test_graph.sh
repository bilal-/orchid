#!/usr/bin/env bash
# RED: Invalid graph references, milestone cycles and unbounded inputs refuse.
# GREEN: Candidate verification nests without changing legacy binding shapes.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/archetype.sh"
source "$REPO_ROOT/lib/schedule.sh"
source "$REPO_ROOT/lib/json.sh"
source "$REPO_ROOT/lib/output-contract.sh"
if [ ! -f "$REPO_ROOT/lib/graph.sh" ]; then fail 'graph model exists'; exit 1; fi
source "$REPO_ROOT/lib/graph.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/repo/.orchid/tasks"
cd_scratch "$WORK/repo" || exit 1
git init -q
git commit -q --allow-empty -m 'graph baseline'
candidate="$(git rev-parse HEAD)"
printf -- '---\nrun_id: r-001\nrun_status: running\n---\n' > .orchid/roadmap.md
printf 'Current requirements\n' > .orchid/requirements.md
node() {
  local id="$1" outcome="${2:-feature}"
  printf -- '---\nid: %s\ntitle: %s\nstatus: pending\narchetype: %s\ncontract_revision: 1\nexecution_generation: 1\nattempts: 0\nacceptance_criteria: %s acceptance\nverification_commands: true\nbase_sha: %s\ncandidate_sha: %s\n---\n' "$id" "$id" "$outcome" "$id" "$candidate" "$candidate" > ".orchid/tasks/$id.md"
}
snapshot() { graph_snapshot "$WORK/repo" "${1:-}" > "$WORK/snapshot.json"; }
expect_snapshot_refusal() {
  local label="$1" pattern="$2" rc=0 out
  out="$(graph_snapshot "$WORK/repo" "${3:-}" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label refuses"
  assert_match "$pattern" "$out" "$label diagnostic"
}
snapshot || { fail 'snapshot empty legacy run'; exit 1; }
jq -e '.contract == 1 and (.nodes|length) == 0 and .graph_enabled == false' "$WORK/snapshot.json" >/dev/null || fail 'empty legacy graph snapshot'
node A
node B
fm_set .orchid/tasks/B.md depends_on A
snapshot || { fail 'snapshot ordinary dependencies'; exit 1; }
graph_validate "$WORK/snapshot.json" || fail 'ordinary graph validates'
assert_eq '{"acceptance_criteria":"A acceptance","verification_commands":"true"}' "$(graph_terms "$WORK/snapshot.json" A)" 'legacy terms shape remains exact'
graph_inputs "$WORK/snapshot.json" B > "$WORK/inputs.json"
jq -e --arg candidate "$candidate" '.A == {contract_revision:1,execution_generation:1,candidate_sha:$candidate,contract_terms:{acceptance_criteria:"A acceptance",verification_commands:"true"}}' "$WORK/inputs.json" >/dev/null || fail 'legacy dependency input shape remains exact'
printf 'planner pseudo-task, not a delivery node\n' > .orchid/tasks/plan.md
snapshot || fail 'planner pseudo-task does not damage delivery graph'
jq -e '.nodes|has("plan")|not' "$WORK/snapshot.json" >/dev/null || fail 'planner pseudo-task excluded'
green_case 'empty and ordinary legacy graphs retain terms and input bindings'

node V review
node W review
fm_set .orchid/tasks/V.md verifies A
fm_set .orchid/tasks/W.md verifies V
snapshot || { fail 'snapshot nested candidate verification'; exit 1; }
jq -e '.graph_enabled and .nodes.A.required_verifiers == ["V"] and .nodes.V.required_verifiers == ["W"] and .nodes.A.terms.verification_obligations == [{id:"V",contract_revision:1}]' "$WORK/snapshot.json" >/dev/null || fail 'direct obligations are finite and versioned'
assert_eq "$(printf 'V\nW')" "$(graph_required "$WORK/snapshot.json" A)" 'required verifier closure includes nested checks'
assert_eq "$(printf 'A\nB\nV\nW')" "$(graph_affected "$WORK/snapshot.json" A)" 'candidate and done dependents invalidate together'
printf '["V","B"]\n' > "$WORK/roots.json"
assert_eq "$(printf 'B\nV\nW')" "$(graph_affected "$WORK/snapshot.json" "$WORK/roots.json")" 'multiple roots form unique bounded closure'
graph_target_binding "$WORK/snapshot.json" V > "$WORK/target.json"
jq -e --arg candidate "$candidate" '.task == "A" and .candidate_sha == $candidate and .base_sha == $candidate and .attempt == 1 and .execution_generation == 1 and .contract_revision == 1' "$WORK/target.json" >/dev/null || fail 'candidate target identity includes lineage and versions'
graph_inputs "$WORK/snapshot.json" V > "$WORK/verifier-input.json"
jq -e --arg candidate "$candidate" '.A.base_sha == $candidate and .A.attempt == 1' "$WORK/verifier-input.json" >/dev/null || fail 'candidate input adds lineage and attempt'
green_case 'milestone graph admits nested checks and exposes exact target identities'

fm_set .orchid/tasks/V.md depends_on A
expect_snapshot_refusal 'verifier waiting for target done' 'cycle'
fm_set .orchid/tasks/V.md depends_on ''
fm_set .orchid/tasks/A.md depends_on W
expect_snapshot_refusal 'indirect candidate completion cycle' 'cycle'
fm_set .orchid/tasks/A.md depends_on B
expect_snapshot_refusal 'ordinary dependency cycle' 'cycle'
fm_set .orchid/tasks/A.md depends_on ''
fm_set .orchid/tasks/V.md verifies missing
expect_snapshot_refusal 'unknown verification target' 'unknown|missing'
fm_set .orchid/tasks/V.md verifies V
expect_snapshot_refusal 'self-verification' 'self|cycle'
fm_set .orchid/tasks/V.md verifies A
fm_set .orchid/tasks/V.md archetype feature
expect_snapshot_refusal 'code outcome verifier' 'report'
fm_set .orchid/tasks/V.md archetype review
snapshot || fail 'valid twin remains accepted after graph admission refusals'
red_case 'milestone cycles, unknown targets, self verification and code verifiers refuse'
green_case 'same nested candidate graph accepts once invalid declarations are corrected'

for value in '' 0 01 '1+1' 1000000; do
  fm_set .orchid/tasks/A.md execution_generation "$value"
  expect_snapshot_refusal 'invalid execution generation' 'execution_generation|version'
done
fm_set .orchid/tasks/A.md execution_generation 1
fm_set .orchid/tasks/A.md contract_revision 2
snapshot || fail 'current contract version accepted'
graph_target_binding "$WORK/snapshot.json" V > "$WORK/target-v2.json"
jq -e '.contract_revision == 2' "$WORK/target-v2.json" >/dev/null || fail 'target contract revision changes binding'
fm_set .orchid/tasks/A.md execution_generation 2
fm_set .orchid/tasks/A.md attempts 1
snapshot || fail 'new execution identity accepted'
graph_target_binding "$WORK/snapshot.json" V > "$WORK/target-g2.json"
jq -e '.execution_generation == 2 and .attempt == 2' "$WORK/target-g2.json" >/dev/null || fail 'same candidate in new execution has a distinct binding'
red_case 'present empty, noncanonical or exhausted version values refuse'
green_case 'valid revisions and same-candidate attempt generations produce fresh bindings'

cp .orchid/tasks/A.md "$WORK/A.before"
printf '{"V":{"acceptance_criteria":"Revised check"}}\n' > "$WORK/overlay.json"
snapshot "$WORK/overlay.json" || fail 'semantic overlay normalizes'
assert_eq 'Revised check' "$(graph_terms "$WORK/snapshot.json" V | jq -r .acceptance_criteria)" 'overlay affects modeled terms'
cmp .orchid/tasks/A.md "$WORK/A.before" || fail 'overlay cannot change source records'
assert_eq 'V acceptance' "$(fm_get .orchid/tasks/V.md acceptance_criteria)" 'overlay leaves changed source record untouched'
printf '{"V":{"status":"done"}}\n' > "$WORK/overlay.json"
expect_snapshot_refusal 'runtime overlay' 'overlay|runtime|status' "$WORK/overlay.json"
printf '{"MISSING":null}\n' > "$WORK/overlay.json"
expect_snapshot_refusal 'deleting absent node' 'unknown|missing|overlay' "$WORK/overlay.json"
printf '{"V":{"output_contract":"broken JSON"}}\n' > "$WORK/overlay.json"
expect_snapshot_refusal 'malformed output contract' 'output_contract|JSON|parse' "$WORK/overlay.json"
printf '{"V":{"output_contract":{"artifacts":[]}}}\n' > "$WORK/overlay.json"
expect_snapshot_refusal 'missing output contract version' 'output contract|definition|unsupported' "$WORK/overlay.json"
printf '{"V":{"output_contract":{"contract":1,"envelope_schema":{"pattern":".*"}}}}\n' > "$WORK/overlay.json"
expect_snapshot_refusal 'unsupported output schema vocabulary' 'output contract|definition|unsupported' "$WORK/overlay.json"
red_case 'semantic overlays cannot mutate runtime fields or carry malformed contracts'
printf '{"V":{"output_contract":{"contract":1,"artifacts":[]}}}\n' > "$WORK/overlay.json"
rc=0; out="$(unset -f output_contract_validate; graph_snapshot "$WORK/repo" "$WORK/overlay.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'contract-bearing snapshot requires its definition owner'
assert_match 'output_contract_validate|prerequisite' "$out" 'missing contract owner diagnostic'
snapshot "$WORK/overlay.json" || fail 'structured output contract accepted'
jq -e '.nodes.V.output_contract == {contract:1,artifacts:[]}' "$WORK/snapshot.json" >/dev/null || fail 'output contract typed in snapshot'
graph_validate "$WORK/snapshot.json" || fail 'contract-bearing validated file delegates to definition owner'
green_case 'valid semantic overlays are normalized without touching durable state'

snapshot || fail 'snapshot before progress change'
digest="$(jq -r .run.digest "$WORK/snapshot.json")"
terms="$(graph_terms "$WORK/snapshot.json" V)"
fm_set .orchid/tasks/B.md status 'done'
snapshot || fail 'snapshot after unrelated progress'
assert_eq "$digest" "$(jq -r .run.digest "$WORK/snapshot.json")" 'requirements digest ignores progress'
assert_eq "$terms" "$(graph_terms "$WORK/snapshot.json" V)" 'unrelated progress leaves verifier terms unchanged'
printf 'Changed requirements\n' > .orchid/requirements.md
snapshot || fail 'snapshot changed requirements'
[ "$digest" != "$(jq -r .run.digest "$WORK/snapshot.json")" ] || fail 'requirements digest changes with actual content'
green_case 'requirements digest binds content without coupling every job to progress'

fm_set .orchid/tasks/A.md graph_wait '{"started_at":1,"seconds":2,"candidate_sha":"","generation":2,"attempt":2}'
snapshot || fail 'atomic waiting metadata accepted'
jq -e '.nodes.A.graph_wait.seconds == 2' "$WORK/snapshot.json" >/dev/null || fail 'waiting accounting remains typed'
fm_set .orchid/tasks/A.md graph_wait '{"started_at":-1,"seconds":2,"candidate_sha":"","generation":2,"attempt":2}'
expect_snapshot_refusal 'negative waiting time' 'graph_wait|waiting|started_at'
fm_set .orchid/tasks/A.md graph_wait ''
fm_set .orchid/tasks/V.md repair_target V
expect_snapshot_refusal 'self repair target' 'repair_target|immediate'
fm_set .orchid/tasks/V.md repair_target B
expect_snapshot_refusal 'unrelated repair target' 'repair_target|immediate'
fm_set .orchid/tasks/V.md repair_target A
fm_set .orchid/tasks/W.md repair_target A
expect_snapshot_refusal 'transitive repair target' 'repair_target|immediate'
fm_set .orchid/tasks/W.md repair_target V
fm_set .orchid/tasks/V.md repair_target A
snapshot || fail 'immediate repair targets accepted'
fm_set .orchid/tasks/W.md repair_target ''
fm_set .orchid/tasks/V.md repair_target A
snapshot || fail 'upstream repair target accepted'
red_case 'waiting accounting and explicit repair policy refuse self, transitive and unrelated targets'
green_case 'valid waiting metadata and immediate verifies repair policy accept'

# Pure-model bounds are exercised with generated overlays, not hundreds of CLI calls.
jq -n 'reduce range(0;257) as $i ({}; .["N\($i)"]={title:"bounded",archetype:"review"})' > "$WORK/over-limit.json"
expect_snapshot_refusal 'node bound' 'node|bound|limit' "$WORK/over-limit.json"
red_case 'graphs above the explicit node bound refuse'
jq -n 'reduce range(0;252) as $i ({}; .["N\($i)"]={title:"bounded",archetype:"review"})' > "$WORK/at-limit.json"
snapshot "$WORK/at-limit.json" || fail 'graph at node bound accepts'
assert_eq 256 "$(jq '.nodes|length' "$WORK/snapshot.json")" 'node bound accepting twin is exact'
green_case 'graph at explicit node bound accepts'

jq -n 'reduce range(0;31) as $i ({}; .["DEPTH\($i)"]={archetype:"review",verifies:(if $i == 0 then "W" else "DEPTH\($i-1)" end)})' > "$WORK/deep.json"
expect_snapshot_refusal 'verification depth bound' 'depth.*limit' "$WORK/deep.json"
jq 'del(.DEPTH30)' "$WORK/deep.json" > "$WORK/depth-limit.json"
snapshot "$WORK/depth-limit.json" || fail 'nested verification at depth bound accepts'
assert_eq 32 "$(graph_required "$WORK/snapshot.json" A | wc -l | tr -d ' ')" 'verification depth accepting twin is exact'
red_case 'verification nesting above the explicit depth bound refuses'
green_case 'verification nesting at the explicit depth bound accepts'

jq -n 'reduce range(0;91) as $i ({}; .["EDGE\($i)"]={archetype:"review",depends_on:[range(0;$i)|"EDGE\(.)"]})' > "$WORK/edges.json"
expect_snapshot_refusal 'input edge bound' 'edge.*limit' "$WORK/edges.json"
jq '.EDGE90.depends_on |= map(select(. != "EDGE0" and . != "EDGE1"))' "$WORK/edges.json" > "$WORK/edge-limit.json"
snapshot "$WORK/edge-limit.json" || fail 'graph at edge bound accepts'
assert_eq 4096 "$(jq '[.nodes[]|(.depends_on|length)+(if .verifies == null then 0 else 1 end)]|add' "$WORK/snapshot.json")" 'edge bound accepting twin is exact'
red_case 'input graph above the explicit edge bound refuses'
green_case 'input graph at the explicit edge bound accepts'

snapshot || fail 'snapshot before validated-file tampering cases'
jq '.nodes.A.contract_revision=1.5' "$WORK/snapshot.json" > "$WORK/tampered.json"
rc=0; graph_validate "$WORK/tampered.json" > "$WORK/tampered.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'graph_validate refuses noninteger typed version'
jq '.nodes.A.repair_budget=-1' "$WORK/snapshot.json" > "$WORK/tampered.json"
rc=0; graph_validate "$WORK/tampered.json" > "$WORK/tampered.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'graph_validate refuses invalid typed repair policy'
jq '.graph_enabled=false' "$WORK/snapshot.json" > "$WORK/tampered.json"
rc=0; graph_validate "$WORK/tampered.json" > "$WORK/tampered.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'graph_validate refuses disabling declared graph obligations'
red_case 'validated-file APIs reject forged typed versions, repair budgets and feature flags'
graph_validate "$WORK/snapshot.json" || fail 'untampered snapshot remains valid'
green_case 'the untampered typed snapshot remains accepted'

cp .orchid/tasks/B.md "$WORK/B.original"
fm_set .orchid/tasks/B.md id C
expect_snapshot_refusal 'task file identity mismatch' 'identity|filename|ID'
cp "$WORK/B.original" .orchid/tasks/B.md
mv .orchid/tasks/B.md "$WORK/foreign-B.md"
ln -s "$WORK/foreign-B.md" .orchid/tasks/B.md
expect_snapshot_refusal 'redirected task file' 'owned|unsafe'
rm .orchid/tasks/B.md
mv "$WORK/foreign-B.md" .orchid/tasks/B.md
red_case 'task identity mismatches and redirected reads refuse'
snapshot || fail 'owned task identity accepting twin'
green_case 'the same task file validates after ownership and identity are restored'

# A producer failure must not silently erase dependencies or archetype metadata.
rc=0; out="$(
  jq() { if [ "${1:-}" = -r ] && [ "${2:-}" = 'keys[]' ]; then return 42; fi; command jq "$@"; }
  graph_snapshot "$WORK/repo" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail 'failed node-key producer cannot silently drop dependency normalization'
rc=0; out="$(
  jq() { if [ "${1:-}" = -r ] && [ "${2:-}" = '[.[]|.archetype // "feature"|if . == "" then "feature" else . end]|unique[]' ]; then return 42; fi; command jq "$@"; }
  graph_snapshot "$WORK/repo" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail 'failed archetype producer cannot silently skip validation'
red_case 'bounded graph producer failures cannot publish a partial model'
snapshot || fail 'producer accepting twin'
green_case 'the same graph snapshot accepts when every producer completes'

# Byte limits are real UTF-8 byte counts, not shell character counts.
cp .orchid/tasks/A.md "$WORK/A.byte-original"
node_raw="$(fm_json .orchid/tasks/A.md)"
node_bytes="$(printf '%s' "$node_raw" | wc -c | tr -d ' ')"
python3 - .orchid/tasks/A.md "$node_bytes" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_text()
old = next(line for line in data.splitlines() if line.startswith('acceptance_criteria: '))
value = old.split(': ', 1)[1]
padding = 262144 - int(sys.argv[2]) + len(value.encode())
value = '🪻' + 'x' * (padding - len('🪻'.encode()))
p.write_text(data.replace(old, 'acceptance_criteria: ' + value, 1))
PY
snapshot || fail 'node data at byte bound accepts'
node_raw="$(fm_json .orchid/tasks/A.md)"
assert_eq 262144 "$(printf '%s' "$node_raw" | wc -c | tr -d ' ')" 'node byte accepting twin is exact'
python3 - .orchid/tasks/A.md <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('acceptance_criteria: ', 'acceptance_criteria: x', 1))
PY
expect_snapshot_refusal 'node data byte bound' 'byte bound'
cp "$WORK/A.byte-original" .orchid/tasks/A.md
red_case 'node metadata above its byte bound refuses'
green_case 'node metadata at its exact byte bound accepts'

python3 - "$WORK/overlay-byte-limit.json" "$WORK/overlay-byte-large.json" <<'PY'
from pathlib import Path
import json
import sys
data = {f'BYTE{i}': {'archetype': 'review', 'acceptance_criteria': 'x' * 32000} for i in range(64)}
encoded = json.dumps(data, separators=(',', ':'))
data['BYTE0']['acceptance_criteria'] += 'x' * (2097152 - len(encoded.encode()))
encoded = json.dumps(data, separators=(',', ':'))
assert len(encoded.encode()) == 2097152
Path(sys.argv[1]).write_text(encoded)
Path(sys.argv[2]).write_text(encoded + ' ')
PY
expect_snapshot_refusal 'overlay byte bound' 'overlay byte limit' "$WORK/overlay-byte-large.json"
snapshot "$WORK/overlay-byte-limit.json" || fail 'overlay at byte bound accepts'
assert_eq 2097152 "$(wc -c < "$WORK/overlay-byte-limit.json" | tr -d ' ')" 'overlay byte accepting twin is exact'
red_case 'semantic overlay above its byte bound refuses'
green_case 'semantic overlay at its exact byte bound accepts'

mkdir -p "$WORK/disk-bound/.orchid/tasks"
python3 - "$WORK/disk-bound/.orchid/tasks" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for i in range(257):
    (root / f'DISK{i}.md').write_text(f'---\nid: DISK{i}\n---\n')
PY
rc=0; out="$(graph_snapshot "$WORK/disk-bound" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'on-disk node count above bound refuses'
assert_match 'node limit' "$out" 'on-disk node bound diagnostic'
rm "$WORK/disk-bound/.orchid/tasks/DISK256.md"
graph_snapshot "$WORK/disk-bound" > "$WORK/disk-bound.json" || fail 'on-disk node count at bound accepts'
assert_eq 256 "$(jq '.nodes|length' "$WORK/disk-bound.json")" 'on-disk node accepting twin is exact'
red_case 'on-disk task files above the node bound refuse'
green_case 'on-disk task files at the node bound accept'

# Invalid bytes must be rejected before jq can replace them with U+FFFD.
cp .orchid/tasks/A.md "$WORK/A.encoding-original"
python3 - .orchid/tasks/A.md <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_bytes(p.read_bytes().replace(b'acceptance_criteria: ', b'acceptance_criteria: bad \xff ', 1))
PY
expect_snapshot_refusal 'raw task metadata encoding' 'UTF-8|UTF8|JSON'
cp "$WORK/A.encoding-original" .orchid/tasks/A.md
cp .orchid/tasks/W.md "$WORK/W.encoding-original"
python3 - .orchid/tasks/W.md <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_bytes(p.read_bytes().replace(b'acceptance_criteria: ', b'acceptance_criteria: bad \xff ', 1))
PY
rc=0; graph_snapshot "$WORK/repo" > "$WORK/partial-model.json" 2> "$WORK/partial-model.err" || rc=$?
[ "$rc" -ne 0 ] || fail 'malformed metadata in the final node aborts the graph'
[ ! -s "$WORK/partial-model.json" ] || fail 'malformed metadata cannot publish partial model stdout'
cp "$WORK/W.encoding-original" .orchid/tasks/W.md
cp .orchid/roadmap.md "$WORK/roadmap.encoding-original"
python3 - .orchid/roadmap.md <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_bytes(p.read_bytes().replace(b'run_status: ', b'note: bad \xff\nrun_status: ', 1))
PY
expect_snapshot_refusal 'raw roadmap metadata encoding' 'UTF-8|UTF8|JSON'
cp "$WORK/roadmap.encoding-original" .orchid/roadmap.md
python3 - "$WORK/bad-encoding-overlay.json" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'{"V":{"acceptance_criteria":"bad \xff"}}')
PY
expect_snapshot_refusal 'raw overlay encoding' 'UTF-8|UTF8|JSON' "$WORK/bad-encoding-overlay.json"
python3 - "$WORK/unicode-overlay.json" <<'PY'
from pathlib import Path
import json
import sys
Path(sys.argv[1]).write_text(json.dumps({'V': {'acceptance_criteria': '🪻 café \\n'}}, ensure_ascii=False))
PY
snapshot "$WORK/unicode-overlay.json" || fail 'valid Unicode semantic overlay accepts'
assert_eq '🪻 café \n' "$(graph_terms "$WORK/snapshot.json" V | jq -r .acceptance_criteria)" 'Unicode overlay preserves exact decoded metadata'
python3 - "$WORK/snapshot.json" "$WORK/bad-encoding-snapshot.json" <<'PY'
from pathlib import Path
import json
import sys
data = json.loads(Path(sys.argv[1]).read_text())
data['nodes']['A']['title'] = 'ENCODING_MARKER'
Path(sys.argv[2]).write_bytes(json.dumps(data).encode().replace(b'ENCODING_MARKER', b'bad \xff'))
PY
rc=0; out="$(graph_validate "$WORK/bad-encoding-snapshot.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'snapshot validator rejects original malformed UTF-8 bytes'
assert_match 'UTF-8|UTF8|JSON' "$out" 'snapshot encoding diagnostic'
red_case 'raw task, roadmap, overlay and snapshot encodings cannot be normalized after corruption'
graph_validate "$WORK/snapshot.json" || fail 'Unicode snapshot accepting twin'
green_case 'valid Unicode metadata and semantic overlays retain their exact data'

rc=0; out="$(orchid_json_file_valid() { return 42; }; graph_snapshot "$WORK/repo" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'shared JSON producer failure cannot admit graph input'
rc=0; out="$(unset -f orchid_json_file_valid; graph_snapshot "$WORK/repo" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'missing shared JSON prerequisite cannot admit graph input'
assert_match 'orchid_json_file_valid|prerequisite' "$out" 'missing shared JSON owner diagnostic'
rc=0; out="$(head() { return 42; }; graph_snapshot "$WORK/repo" "$WORK/unicode-overlay.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'failed bounded overlay snapshot cannot publish a model'
ln -s "$WORK/unicode-overlay.json" "$WORK/linked-overlay.json"
expect_snapshot_refusal 'redirected overlay' 'regular file' "$WORK/linked-overlay.json"
red_case 'shared JSON validation failure and missing prerequisites fail closed'
snapshot "$WORK/unicode-overlay.json" || fail 'shared JSON validation accepting twin'
green_case 'graph admission accepts when the shared JSON owner succeeds'

# Graph consumes only FM metadata: unrelated large Markdown bodies stay valid.
python3 - .orchid/tasks/A.md .orchid/roadmap.md <<'PY'
from pathlib import Path
import sys
for name in sys.argv[1:]:
    p = Path(name)
    p.write_bytes(p.read_bytes() + b'\n' + '🪻'.encode() + b'body ' * 60000)
PY
snapshot || fail 'large task and roadmap bodies are not graph metadata limits'
assert_eq 'A acceptance' "$(graph_terms "$WORK/snapshot.json" A | jq -r .acceptance_criteria)" 'large body cannot change FM terms'
cp "$WORK/A.encoding-original" .orchid/tasks/A.md
cp "$WORK/roadmap.encoding-original" .orchid/roadmap.md
green_case 'large unrelated Markdown bodies remain outside graph metadata limits'

# Roadmap metadata is bounded separately and never passed through shell argv.
roadmap_raw="$(fm_json .orchid/roadmap.md)"
roadmap_bytes="$(printf '%s' "$roadmap_raw" | wc -c | tr -d ' ')"
python3 - .orchid/roadmap.md "$roadmap_bytes" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = p.read_text()
empty_extra = len(',"note":""'.encode())
padding = 262144 - int(sys.argv[2]) - empty_extra
value = '🪻' + 'x' * (padding - len('🪻'.encode()))
p.write_text(data.replace('---\n', '---\nnote: ' + value + '\n', 1))
PY
snapshot || fail 'roadmap metadata at byte bound accepts without argv transport'
roadmap_raw="$(fm_json .orchid/roadmap.md)"
assert_eq 262144 "$(printf '%s' "$roadmap_raw" | wc -c | tr -d ' ')" 'roadmap metadata accepting twin is exact'
python3 - .orchid/roadmap.md <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('note: ', 'note: x', 1))
PY
expect_snapshot_refusal 'roadmap metadata byte bound' 'roadmap.*byte bound'
cp "$WORK/roadmap.encoding-original" .orchid/roadmap.md
red_case 'roadmap FM metadata above its byte bound refuses'
green_case 'roadmap FM metadata at its exact byte bound accepts'

# A newly admitted plan must be representable by the existing single-line FM
# writer. JSON-valued contracts keep their own escaped string representation.
python3 - "$WORK/multiline-overlay.json" "$WORK/literal-overlay.json" "$WORK/nul-overlay.json" <<'PY'
from pathlib import Path
import json
import sys
Path(sys.argv[1]).write_text(json.dumps({'V': {'acceptance_criteria': 'first\nsecond'}}))
Path(sys.argv[3]).write_text(json.dumps({'V': {'title': 'first\x00second'}}))
Path(sys.argv[2]).write_text(json.dumps({'V': {
    'title': '🪻 café \\n \\u0000',
    'acceptance_criteria': 'first\\nsecond',
    'output_contract': {'contract': 1, 'envelope_schema': {'const': 'first\nsecond\x00tail'}}
}}, ensure_ascii=False))
PY
expect_snapshot_refusal 'actual LF semantic scalar' 'single.line|multiline|newline' "$WORK/multiline-overlay.json"
expect_snapshot_refusal 'actual NUL semantic scalar' 'NUL|representable|single.line' "$WORK/nul-overlay.json"
red_case 'admitted semantic FM scalars cannot contain actual line feeds or NUL'
snapshot "$WORK/literal-overlay.json" || fail 'literal escapes and nested JSON strings remain representable'
assert_eq 'first\nsecond' "$(graph_terms "$WORK/snapshot.json" V | jq -r .acceptance_criteria)" 'literal backslash-n stays literal'
assert_eq '🪻 café \n \u0000' "$(jq -r .nodes.V.title "$WORK/snapshot.json")" 'Unicode scalar remains representable'
jq -e '.nodes.V.output_contract.envelope_schema.const == "first\nsecond\u0000tail"' "$WORK/snapshot.json" >/dev/null || fail 'JSON-valued schema strings retain decoded LF and NUL'
green_case 'literal escapes, Unicode and nested JSON LF or NUL values remain valid'

printf '{"A":{"verifies":"W","archetype":"review"}}\n' > "$WORK/overlay.json"
expect_snapshot_refusal 'verification depth cycle' 'cycle' "$WORK/overlay.json"
snapshot || fail 'graph restores after refused overlay'
standalone="$(/bin/bash -c 'unset ORCHID_ROOT; source "$1/lib/common.sh"; source "$1/lib/frontmatter.sh"; source "$1/lib/manifest.sh"; source "$1/lib/archetype.sh"; source "$1/lib/schedule.sh"; source "$1/lib/json.sh"; source "$1/lib/graph.sh"; graph_snapshot "$2"' standalone "$REPO_ROOT" "$WORK/repo")" || fail 'module works with documented primitives and no ambient ORCHID_ROOT'
assert_eq "$(jq -Sc . "$WORK/snapshot.json")" "$(printf '%s\n' "$standalone" | jq -Sc .)" 'standalone module uses its own kernel root safely'
[ "$FAILS" -eq 0 ]
