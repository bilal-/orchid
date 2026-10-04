#!/usr/bin/env bash
# Independent contract checks use disposable kernel entries and primary TOON
# fixtures. No vendor calls, hooks, project runs or durable state are launched.
source "$(dirname "$0")/helpers.sh"
export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/nogit" "$WORK/payload"
payload="$WORK/payload"
for dir in bin lib libexec runners release skills; do cp -R "$REPO_ROOT/$dir" "$payload/"; done
cp "$REPO_ROOT/PROTOCOL.md" "$payload/"
fixture_bin="$payload/bin/orchid"
export ORCHID_REPO="$WORK/nogit"

# GREEN: current context names uninitialized repos honestly and performs no
# project writes. The ambient interface remains silent in a fresh session.
context="$($fixture_bin --json context)" || fail 'fresh context query failed'
assert_eq false "$(jq -r .initialized <<< "$context")" 'fresh repo is explicitly uninitialized'
assert_eq uninitialized "$(jq -r .run.status <<< "$context")" 'fresh run status is uninitialized'
assert_eq 0 "$(jq '.tasks.count' <<< "$context")" 'empty task count is integer zero'
assert_eq '' "$($fixture_bin context --ambient)" 'ambient context is empty outside initialized repo'
[ ! -e "$ORCHID_REPO/.orchid" ] || fail 'context query wrote target state'
green_case 'context reports uninitialized repo without creating project state'

# Usage recovery is one response: the same scoped help as --help, with the
# original error and exit2. The semantic walk must observe a later --json while
# consuming an option's literal --json value even after an earlier failure.
cat > "$payload/libexec/orchid-fixture-usage" <<'EOF'
#!/bin/bash
printf 'reached\n' >> "$ORCHID_REPO/usage-marker"
printf '{"accepted":true}\n'
EOF
chmod 755 "$payload/libexec/orchid-fixture-usage"
printf '%s\n' '{"description":"Scoped usage recovery fixture.","default":[],"commands":[{"path":[],"kind":"json","usage":"usage: orchid fixture-usage [--message <value>] [--approve]","options":{"--message":1,"--approve":0},"min_args":0,"max_args":0,"output_fields":["accepted"],"examples":["orchid fixture-usage --message example"],"notes":["No prompts."]}]}' > "$payload/lib/cli/fixture-usage.json"
usage_help="$($fixture_bin --json fixture-usage --help --full)" || fail 'fixture scoped help failed'
usage_error_json() {
  local label="$1" rc=0 output; shift
  ORCHID_OUTPUT=toon "$fixture_bin" fixture-usage "$@" > "$WORK/usage-$label.out" 2> "$WORK/usage-$label.err" || rc=$?
  assert_eq 2 "$rc" "usage recovery $label exits2"
  output="$(cat "$WORK/usage-$label.out")"
  case "$output" in
    \{*)
      jq -e '.kernel_exit==2 and (.error|type=="string") and (.help|type=="string")' <<< "$output" >/dev/null \
        || fail "usage recovery $label lacks structured error"
      assert_eq "$(jq -c '{usage,commands,description,options,output,examples,notes}' <<< "$usage_help")" \
        "$(jq -c '{usage,commands,description,options,output,examples,notes}' <<< "$output")" \
        "usage recovery $label includes identical complete scoped help"
      ;;
    *) fail "usage recovery $label lost requested JSON format" ;;
  esac
}
usage_error_json json-first --json --bad
usage_error_json json-last --bad --json
usage_error_json after-literal --bad --message --json --json
usage_error_json bad-value --limit nope --json
usage_error_json cache-refusal --bad --request-id usage-recovery-red --json
assert_match 'positive integer' "$(jq -r .error "$WORK/usage-bad-value.out")" 'format recovery preserves the first bad-value cause'
for label in literal inline-literal duplicate-literal separator-literal; do
  rc=0
  case "$label" in
    literal) set -- --bad --message --json ;;
    inline-literal) set -- --bad --message=--json ;;
    duplicate-literal) set -- --message first --message --json --bad ;;
    separator-literal) set -- --bad -- --json ;;
  esac
  ORCHID_OUTPUT=toon "$fixture_bin" fixture-usage "$@" > "$WORK/usage-$label.out" 2> "$WORK/usage-$label.err" || rc=$?
  assert_eq 2 "$rc" "literal presentation twin $label exits2"
  assert_match '^error:' "$(cat "$WORK/usage-$label.out")" "literal $label keeps default TOON format"
  assert_match '^usage:.*orchid fixture-usage' "$(cat "$WORK/usage-$label.out")" "literal $label carries scoped recovery"
done
assert_match 'duplicate option --message' "$(cat "$WORK/usage-duplicate-literal.out")" 'duplicate literal option keeps its first error cause'
[ ! -e "$ORCHID_REPO/usage-marker" ] || fail 'usage error reached its kernel body'
[ ! -e "$ORCHID_REPO/.orchid" ] || fail 'usage error initialized target state'
[ ! -e "$HOME/.orchid/requests" ] || fail 'usage error created a retry cache'
red_case 'usage failures include full scoped help in requested format without kernel or cache effects'
accepted="$(ORCHID_OUTPUT=toon "$fixture_bin" fixture-usage --message --json)" || fail 'literal --json semantic value failed valid admission'
assert_match '^accepted: true' "$accepted" 'valid literal --json value remains default TOON'
assert_eq reached "$(cat "$ORCHID_REPO/usage-marker")" 'valid literal option twin reaches its kernel exactly once'
green_case 'same declared kernel accepts literal --json option value without changing presentation'

# Recognized read failures refuse; only return2 means no adapter and permits
# generic transport. A captured body must not become a successful fallback.
cp "$payload/lib/agent-read.sh" "$WORK/agent-read.owned"
cat > "$payload/libexec/orchid-fixture-read-failure" <<'EOF'
#!/bin/bash
printf '{"text":"ORCHID_FAKE_CAPTURED_BODY"}\n'
EOF
chmod 755 "$payload/libexec/orchid-fixture-read-failure"
printf '%s\n' '{"description":"Read adapter failure fixture.","default":[],"commands":[{"path":[],"kind":"json","usage":"usage: orchid fixture-read-failure","options":{},"min_args":0,"max_args":0,"output_fields":["text"]}]}' > "$payload/lib/cli/fixture-read-failure.json"
cat > "$payload/lib/agent-read.sh" <<'EOF'
orchid_agent_read_json() { printf 'orchid: unsafe fixture input ownership\n' >&2; return 1; }
EOF
rc=0; "$fixture_bin" --json fixture-read-failure > "$WORK/read-failure.json" 2> "$WORK/read-failure.err" || rc=$?
assert_eq 1 "$rc" 'recognized read adapter failure refuses public output'
jq -e '.kernel_exit==1 and (.error|contains("ownership"))' "$WORK/read-failure.json" >/dev/null || fail 'read adapter failure lacks structured ownership refusal'
if grep -F ORCHID_FAKE_CAPTURED_BODY "$WORK/read-failure.json" "$WORK/read-failure.err"; then fail 'recognized read failure disclosed captured body through fallback'; fi
assert_match 'unsafe fixture input' "$(cat "$WORK/read-failure.err")" 'recognized read failure preserves safe ownership diagnostic'
red_case 'recognized read failure returns structured1 without captured-body fallback'
printf 'orchid_agent_read_json() { return 2; }\n' > "$payload/lib/agent-read.sh"
assert_eq ORCHID_FAKE_CAPTURED_BODY "$("$fixture_bin" --json fixture-read-failure | jq -r .text)" 'unhandled2 permits declared JSON transport'
cp "$WORK/agent-read.owned" "$payload/lib/agent-read.sh"
green_case 'same declared response uses generic transport only for an unhandled adapter'

# Every shipped verb needs command admission metadata, and every declared leaf
# must expose scoped help without executing that leaf or requiring an epoch.
for entry in "$REPO_ROOT"/libexec/orchid-*; do
  verb="${entry##*/orchid-}"
  [ -f "$REPO_ROOT/lib/cli/$verb.json" ] || fail "missing metadata for shipped verb $verb"
done
for metadata in "$REPO_ROOT"/lib/cli/*.json; do
  verb="${metadata##*/}"; verb="${verb%.json}"
  jq -e '.description|type=="string"' "$metadata" >/dev/null || fail "$verb metadata missing description"
  while IFS= read -r leaf; do
    args=()
    while IFS= read -r -d '' arg; do args[${#args[@]}]="$arg"; done < <(jq -jr '.[]|.+"\u0000"' <<< "$leaf")
    help="$($fixture_bin --json "$verb" ${args[@]+"${args[@]}"} --help)" || fail "$verb leaf scoped help failed: $leaf"
    assert_match '^usage: orchid ' "$(jq -r .usage <<< "$help")" "$verb help has an executable usage form"
  done < <(jq -c '.commands[].path' "$metadata")
done
help="$($fixture_bin --json run --help)" || fail 'run group help failed'
while IFS= read -r invocation; do
  grep -Fq "$invocation" <<< "$help" || fail "run scoped help omits supported leaf $invocation"
done < <(jq -r '.commands[]|"orchid run "+(.path|join(" "))' "$REPO_ROOT/lib/cli/run.json")
green_case 'metadata and scoped help cover every shipped verb and declared leaf'
rc=0; "$fixture_bin" --json task list --help --fields id > "$WORK/help-invalid.json" 2> "$WORK/help-invalid.err" || rc=$?
assert_eq 2 "$rc" 'help rejects fields from the data response schema'
jq -e '.error|type=="string"' "$WORK/help-invalid.json" >/dev/null || fail 'invalid help field lacks typed usage error'
red_case 'help data-only field projection is refused with a typed usage error'
projected_help="$($fixture_bin --json run --help --fields usage,commands)" || fail 'declared help field projection failed'
assert_eq '["commands","usage"]' "$(jq -c 'keys' <<< "$projected_help")" 'help projection uses its actual schema'
assert_eq 10 "$(jq '.commands|length' <<< "$projected_help")" 'projected scoped help retains complete child command list'
green_case 'declared help field projection returns usage and complete commands'

# RED: a discovered but non-executable entry must report its mode, even when
# no metadata exists yet. GREEN: executable registered entry runs normally.
printf '#!/bin/bash\nprintf "{\\"accepted\\":true}\\n"\n' > "$payload/libexec/orchid-fixture-mode"
chmod 644 "$payload/libexec/orchid-fixture-mode"
rc=0; "$fixture_bin" --json fixture-mode > "$WORK/mode.json" 2> "$WORK/mode.err" || rc=$?
assert_eq 2 "$rc" 'unregistered non-executable entry refuses with usage exit'
assert_match 'not executable' "$(cat "$WORK/mode.json" "$WORK/mode.err")" 'mode failure names actual executable bit problem'
red_case 'unregistered non-executable kernel entry is diagnosed before metadata admission'
chmod 755 "$payload/libexec/orchid-fixture-mode"
printf '{"description":"fixture","default":[],"commands":[{"path":[],"kind":"json","usage":"usage: orchid fixture-mode","options":{},"min_args":0,"max_args":0}]}\n' > "$payload/lib/cli/fixture-mode.json"
assert_eq true "$($fixture_bin --json fixture-mode | jq -r .accepted)" 'executable registered fixture succeeds'
green_case 'registered executable entry produces its typed response'

# A disposable jobs producer exercises actual presentation admission, count,
# field projection and long-lived watch rejection without any real jobs.
cat > "$payload/libexec/orchid-jobs" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = --watch ]; then
    while :; do printf 'streaming fixture\n'; sleep 1; done
  fi
done
i=0
while [ "$i" -lt "${ORCHID_FIXTURE_ROWS:-103}" ]; do
  printf '%03d\tT001\timplementer\timplement\t2\tfixture\t42\trunning\t3\t4\t5\tfixture\tlog\n' "$i"
  i=$((i+1))
done
EOF
chmod 755 "$payload/libexec/orchid-jobs"
rows="$($fixture_bin --json jobs ls)" || fail 'bounded jobs list failed'
assert_eq 103 "$(jq .count <<< "$rows")" 'list count is pre-limit total'
assert_eq 100 "$(jq .shown <<< "$rows")" 'default list row budget is 100'
assert_eq 1 "$(jq '[.next[]|select(contains("--full"))]|length' <<< "$rows")" 'pagination has one recovery hint'
assert_match 'orchid jobs.*ls.*--full' "$(jq -r '.next[]|select(contains("--full"))' <<< "$rows")" 'pagination gives complete recovery command'
rows="$($fixture_bin --json jobs ls --limit 2 --fields id,pid,attempt)" || fail 'explicit projected jobs list failed'
assert_eq 2 "$(jq .shown <<< "$rows")" 'explicit row budget is applied'
assert_eq string "$(jq -r '.items[0].id|type' <<< "$rows")" 'numeric-looking identifiers remain strings'
assert_eq 000 "$(jq -r '.items[0].id' <<< "$rows")" 'leading zero identifier remains intact'
assert_eq number "$(jq -r '.items[0].pid|type' <<< "$rows")" 'PID is a typed number'
assert_eq number "$(jq -r '.items[0].attempt|type' <<< "$rows")" 'attempt is a typed number'
assert_eq '["attempt","id","pid"]' "$(jq -c '.items[0]|keys' <<< "$rows")" 'only selected fields appear'
assert_eq 103 "$($fixture_bin --json jobs ls --full | jq '.items|length')" 'full mode returns complete list'
assert_eq '0 results' "$(ORCHID_FIXTURE_ROWS=0 "$fixture_bin" --json jobs ls | jq -r .empty)" 'empty collection is explicit'

export ORCHID_ROOT="$payload"
source "$payload/lib/common.sh"
rc=0; with_timeout 3 "$fixture_bin" --json jobs ls --watch > "$WORK/watch.json" 2> "$WORK/watch.err" || rc=$?
assert_eq 2 "$rc" 'agent watch returns usage instead of entering infinite capture'
assert_match 'watch|stream' "$(cat "$WORK/watch.json" "$WORK/watch.err")" 'watch error identifies streaming mode'
red_case 'agent channel refuses unbounded watch before starting kernel loop'
assert_eq 103 "$($fixture_bin --json jobs ls | jq .count)" 'bounded jobs read remains available'
green_case 'bounded jobs read returns typed count fields and recovery command'
rc=0; with_timeout 2 "$fixture_bin" --raw jobs ls --watch > "$WORK/raw-watch.out" 2> "$WORK/raw-watch.err" || rc=$?
assert_eq 124 "$rc" 'explicit raw watch retains the streaming interface'
assert_match 'streaming fixture' "$(cat "$WORK/raw-watch.out")" 'raw watch emits stream before timeout'

# RED/GREEN: reject invalid flags/fields/duplicate semantic flags before the
# kernel producer runs; valid field/limit twins above exercise accepting path.
for flag in '--bad' '--limit=0' '--fields=unknown'; do
  rc=0; "$fixture_bin" --json jobs ls "$flag" > "$WORK/invalid.json" 2> "$WORK/invalid.err" || rc=$?
  assert_eq 2 "$rc" "invalid $flag refuses with usage exit"
  jq -e '.error|type=="string"' "$WORK/invalid.json" >/dev/null || fail 'invalid presentation flag lacks typed error'
done
rc=0; "$fixture_bin" --json jobs ls --interval 1 --interval 2 > "$WORK/duplicate.json" 2> "$WORK/duplicate.err" || rc=$?
assert_eq 2 "$rc" 'duplicate semantic flag refuses instead of changing meaning'
red_case 'invalid flags fields limits and duplicate semantic flags reject before execution'
green_case 'declared field projection and positive output limits accept typed rows'

# Canonical argument transport is tested through both dispatcher admission and
# direct-entry admission, matching the kernel's real two-stage handoff.
for transport_verb in task notify; do
  cat > "$payload/libexec/orchid-$transport_verb" <<'EOF'
#!/bin/bash
source "$ORCHID_ROOT/lib/common.sh"
verb="${0##*/orchid-}"
orchid_cli_validate "$verb" "$@"
set -- ${ORCHID_CLI_ARGS[@]+"${ORCHID_CLI_ARGS[@]}"}
jq -cn --args '$ARGS.positional' -- "$@"
EOF
  chmod 755 "$payload/libexec/orchid-$transport_verb"
done
transport="$($fixture_bin --json task set --reason because T001 acceptance_criteria 'literal prose')" || fail 'options-before-fixed-positions transport failed'
assert_eq '["set","T001","acceptance_criteria","literal prose","--reason","because"]' "$(jq -c '.text|fromjson' <<< "$transport")" 'semantic option values normalize after fixed identifiers'
transport="$($fixture_bin --json task set T001 acceptance_criteria --reason because 'literal prose')" || fail 'options-between-fixed-positions transport failed'
assert_eq '["set","T001","acceptance_criteria","literal prose","--reason","because"]' "$(jq -c '.text|fromjson' <<< "$transport")" 'interleaved options preserve fixed argument meaning'
transport="$($fixture_bin --json task set T001 acceptance_criteria -- --help)" || fail 'literal help value transport failed'
assert_eq '["set","T001","acceptance_criteria","--help"]' "$(jq -c '.text|fromjson' <<< "$transport")" 'literal separator preserves help-looking value through both admissions'
transport="$($fixture_bin --json notify --choice approve --choice defer 'literal question')" || fail 'repeatable choices transport failed'
assert_eq '["--choice","approve","--choice","defer","literal question"]' "$(jq -c '.text|fromjson' <<< "$transport")" 'documented repeatable semantic flags remain repeatable'
transport="$($fixture_bin --json notify --choice approve -- '-literal question')" || fail 'trailing prose literal transport failed'
assert_eq '["--choice","approve","--","-literal question"]' "$(jq -c '.text|fromjson' <<< "$transport")" 'trailing literal prose retains its delimiter'
green_case 'canonical transport preserves semantic option order repeatable choices and literal prose'

# The capture controller must finish when the kernel finishes; a disposable
# background child keeps stderr open but carries no project state or job.
cat > "$payload/libexec/orchid-fixture-background" <<'EOF'
#!/bin/bash
(sleep 7) &
printf 'synchronous diagnostic\n' >&2
printf '{"finished":true}\n'
EOF
chmod 755 "$payload/libexec/orchid-fixture-background"
printf '{"description":"fixture","default":[],"commands":[{"path":[],"kind":"json","usage":"usage: orchid fixture-background","options":{},"min_args":0,"max_args":0}]}\n' > "$payload/lib/cli/fixture-background.json"
rc=0; with_timeout 4 "$fixture_bin" --json fixture-background > "$WORK/background.json" 2> "$WORK/background.err" || rc=$?
assert_eq 0 "$rc" 'completed kernel response does not await descendant-held stderr'
assert_eq true "$(jq -r .finished "$WORK/background.json")" 'completed kernel typed result survives capture'
assert_match 'synchronous diagnostic' "$(cat "$WORK/background.err")" 'kernel stderr remains visible'
green_case 'completed kernel result returns without waiting for unrelated descendants'

# Validated against primary @toon-format/toon 4.1.1 (including the equivalent
# compact empty-array spelling). Exercise mixed/nested arrays,
# empty keys, escaped text, numeric-looking strings and ordinary tabular rows.
cat > "$WORK/shape.json" <<'JSON'
{"emptykeys":{"":"value","inner":{"":"nested"}},"numbers":{"strings":[".5","1.","-.5","Inf","Infinity","NaN","+1","01","-0","1e3"]},"arrays":[[1,2],[],[{"x":1},{"x":2}]],"items":[{"id":"001","title":"a,b","attempt":2},{"id":"002","title":"a\nb","attempt":3}],"nested":[{"id":"one","data":{"empty":[],"value":null}},{},{"data":["one",true,null]}]}
JSON
cat > "$WORK/shape.expected" <<'TOON'
emptykeys:
  "": value
  inner:
    "": nested
numbers:
  strings[10]: .5,1.,"-.5",Inf,Infinity,NaN,"+1","01","-0","1e3"
arrays[3]:
  - [2]: 1,2
  - []
  - [2]:
    - x: 1
    - x: 2
items[2]{id,title,attempt}:
  "001","a,b",2
  "002","a\nb",3
nested[3]:
  - id: one
    data:
      empty: []
      value: null
  -
  - data[3]: one,true,null
TOON
jq -r -f "$REPO_ROOT/lib/agent-output.jq" "$WORK/shape.json" > "$WORK/shape.toon" || fail 'TOON rendering failed'
cmp -s "$WORK/shape.expected" "$WORK/shape.toon" || fail 'TOON differs from independent primary format fixture'
cp "$WORK/shape.toon" "$WORK/shape.bad"
printf 'bad trailing row\n' >> "$WORK/shape.bad"
cmp -s "$WORK/shape.expected" "$WORK/shape.bad" && fail 'independent TOON fixture check accepted invalid trailing data'
red_case 'independent TOON reference fixture rejects malformed nested table output'
green_case 'TOON reference matches empty keys nested arrays escaped text and typed scalar distinctions'
if [ -n "${ORCHID_TOON_MODULE:-}" ] && command -v node >/dev/null 2>&1; then
  node --input-type=module - "$ORCHID_TOON_MODULE" "$WORK/shape.json" "$WORK/shape.toon" <<'JS' || fail 'primary TOON decoder roundtrip failed'
import {readFileSync} from 'node:fs';
import {isDeepStrictEqual} from 'node:util';
import {pathToFileURL} from 'node:url';
const {decode}=await import(pathToFileURL(process.argv[2]));
const expected=JSON.parse(readFileSync(process.argv[3],'utf8'));
const actual=decode(readFileSync(process.argv[4],'utf8'));
if(!isDeepStrictEqual(actual,expected))throw Error('TOON changed JSON semantics');
JS
else
  not_tested 'primary-TOON-decoder-roundtrip' 'portable expected-format fixture ran; qualify with Node and ORCHID_TOON_MODULE pointing to pinned official dist/index.mjs'
fi
