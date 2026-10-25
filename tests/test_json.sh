#!/usr/bin/env bash
# RED: jq's replacement of invalid UTF-8 and lost process-substitution failure
# must not permit malformed or unreadable input to become trusted metadata.
# GREEN: Valid Unicode/plaintext and exactly one JSON value retain their bytes.
source "$(dirname "$0")/helpers.sh"
unset ORCHID_ROOT
source "$REPO_ROOT/lib/json.sh"
mkdir -p "$WORK/tmp" "$WORK/inputs"
export TMPDIR="$WORK/tmp"
valid_plain="$WORK/inputs/plain"
valid_json="$WORK/inputs/json"
printf 'orchid café λ 🌱\n\t\r' > "$valid_plain"
printf '{"name":"café λ 🌱","control":"\\u0000\\n\\t"}\n' > "$valid_json"
printf 'raw\000control\n' > "$WORK/inputs/plain-control"
printf 'broken\377text\n' > "$WORK/inputs/invalid-plain"
printf '{"name":"\377"}\n' > "$WORK/inputs/invalid-json"
printf '{}\n[]\n' > "$WORK/inputs/multiple"
printf 'not json\n' > "$WORK/inputs/not-json"
: > "$WORK/inputs/empty"
printf '{"control":"raw\001control"}\n' > "$WORK/inputs/raw-json-control"

assert_no_scratch() {
  assert_eq '' "$(list_dir_entries "$WORK/tmp")" 'encoding validation removes all private scratch files'
}
reject() {
  local predicate="$1" file="$2" out rc=0
  out="$("$predicate" "$file" 2>&1)" || rc=$?
  assert_eq 1 "$rc" "$predicate returns a boolean refusal"
  assert_eq '' "$out" "$predicate does not disclose payload or diagnostics"
  assert_no_scratch
}
accept() {
  local predicate="$1" file="$2" out rc=0
  out="$("$predicate" "$file" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "$predicate accepts valid bytes"
  assert_eq '' "$out" "$predicate is a silent predicate"
  assert_no_scratch
}

# Causal witness: ordinary jq parsing silently changes these malformed bytes.
jq -e . "$WORK/inputs/invalid-json" >/dev/null || fail 'invalid-UTF8 parser fixture reproduces jq replacement'
reject orchid_utf8_file_valid "$WORK/inputs/invalid-plain"
reject orchid_utf8_file_valid "$WORK/inputs/invalid-json"
reject orchid_json_file_valid "$WORK/inputs/invalid-json"
red_case 'invalid UTF-8 plaintext and JSON refuse before jq can replace their bytes'
accept orchid_utf8_file_valid "$valid_plain"
accept orchid_utf8_file_valid "$WORK/inputs/plain-control"
accept orchid_json_file_valid "$valid_json"
green_case 'valid Unicode, plaintext control bytes, and escaped JSON controls are preserved'

reject orchid_json_file_valid "$WORK/inputs/multiple"
reject orchid_json_file_valid "$WORK/inputs/not-json"
reject orchid_json_file_valid "$WORK/inputs/empty"
reject orchid_json_file_valid "$WORK/inputs/raw-json-control"
reject orchid_utf8_file_valid "$WORK/inputs/missing"
reject orchid_json_file_valid "$WORK/inputs/missing"
reject orchid_json_file_valid "$WORK/inputs"
red_case 'streams, malformed JSON, raw JSON controls, missing input, and directories refuse'
for value in null false 0 '"text"' '[]' '{}'; do
  printf '%s\n' "$value" > "$WORK/inputs/scalar"
  accept orchid_json_file_valid "$WORK/inputs/scalar"
done
accept orchid_utf8_file_valid "$WORK/inputs/empty"
green_case 'one JSON value includes false and null, while empty plaintext remains valid UTF-8'

# The old process-substitution comparison loses jq's producer exit status.
# This fake writes byte-identical output, then reports an I/O failure.
jq() { cat; return 9; }
if ! cmp -s "$valid_plain" <(jq -Rrsj . < "$valid_plain"); then
  fail 'producer-error fixture reproduces the unsafe comparison accepting bytes'
fi
reject orchid_utf8_file_valid "$valid_plain"
reject orchid_json_file_valid "$valid_json"
unset -f jq
red_case 'a byte-identical jq result with failing producer status is refused and cleaned up'
accept orchid_utf8_file_valid "$valid_plain"
accept orchid_json_file_valid "$valid_json"
green_case 'the same inputs pass after the producer becomes healthy'

real_jq="$(command -v jq)"
jq() {
  if [ "${1:-}" = -Rrsj ]; then "$real_jq" "$@"; else printf 'true\n'; return 7; fi
}
accept orchid_utf8_file_valid "$valid_json"
reject orchid_json_file_valid "$valid_json"
unset -f jq
red_case 'JSON parser failure cannot be hidden by an earlier successful UTF-8 roundtrip'
accept orchid_json_file_valid "$valid_json"
green_case 'a successful complete JSON parse is required as well as valid encoding'

# Strict JSON numbers are a lexical admission rule; jq alone permits extensions.
for value in NaN Infinity -Infinity +1 01 -01 .5 1. 0x1 1e 1e+; do
  printf '{"value":%s}\n' "$value" > "$WORK/inputs/extensions"
  reject orchid_json_file_valid "$WORK/inputs/extensions"
done
red_case 'nonstandard JSON number tokens cannot be normalized into evidence'
for value in 0 -0 1 -1 1.5 -0.5 1e2 1E+2 -1.2e-3; do
  printf '{"value":%s}\n' "$value" > "$WORK/inputs/standard"
  accept orchid_json_file_valid "$WORK/inputs/standard"
done
green_case 'standard JSON integer fraction and exponent tokens remain accepted'

prior_tmp="$TMPDIR"
export TMPDIR="$WORK/nonexistent-parent"
reject orchid_utf8_file_valid "$valid_plain"
export TMPDIR="$prior_tmp"
accept orchid_utf8_file_valid "$valid_plain"
red_case 'scratch allocation failure remains failure without leaving partial state'
green_case 'validation recovers once its private scratch directory is available'

cd_scratch "$WORK/inputs" || exit 1
printf '{"dash":true}' > ./-leading-dash
accept orchid_json_file_valid -leading-dash
green_case 'a literal leading-dash filename is not interpreted as a tool option'
[ "$FAILS" -eq 0 ]
