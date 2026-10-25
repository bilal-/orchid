#!/usr/bin/env bash
# Output-contract policy is data. Source common.sh before evaluating evidence;
# definition validation itself has no ORCHID_ROOT or common.sh dependency.
_ORCHID_OUTPUT_CONTRACT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$_ORCHID_OUTPUT_CONTRACT_LIB/json.sh"

_output_contract_fail() {
  jq -cn --arg kind "$1" --arg reason "$2" --arg path "${3:-}" \
    '{contract:1,passed:false,kind:$kind,reason:$reason} +
     (if $path == "" then {} else {path:$path} end)'
}

# A string-only API avoids interpreting a malformed definition as a filename.
output_contract_validate() (
  local definition="${1:-}" bytes normalized snapshot
  bytes="$(printf '%s' "$definition" | wc -c | tr -d ' ')"
  if [ "$bytes" -gt 65536 ]; then
    _output_contract_fail definition 'output contract exceeds 65536 bytes'
    return 1
  fi
  snapshot="$(mktemp "${TMPDIR:-/tmp}/orchid-output-definition.XXXXXX")" || {
    _output_contract_fail definition 'cannot snapshot output contract definition'; return 1;
  }
  trap 'rm -f "$snapshot"' EXIT
  if ! printf '%s' "$definition" > "$snapshot" || ! orchid_json_file_valid "$snapshot"; then
    _output_contract_fail definition 'output contract must contain one valid UTF-8 JSON document'
    return 1
  fi
  if ! normalized="$(jq -ceS -L "$_ORCHID_OUTPUT_CONTRACT_LIB" \
      'include "output-schema"; if oc_contract_valid then . else error("invalid contract") end' "$snapshot" 2>/dev/null)"; then
    _output_contract_fail definition 'invalid or unsupported output contract definition'
    return 1
  fi
  bytes="$(printf '%s' "$normalized" | wc -c | tr -d ' ')"
  if [ "$bytes" -gt 65536 ]; then
    _output_contract_fail definition 'normalized output contract exceeds 65536 bytes'
    return 1
  fi
  printf '%s\n' "$normalized"
)

_output_contract_schema_file() {
  orchid_json_file_valid "$1" || return 1
  jq -e --argjson schema "$2" -L "$_ORCHID_OUTPUT_CONTRACT_LIB" \
    'include "output-schema"; oc_schema_matches($schema)' "$1" >/dev/null 2>&1
}

# The subshell owns its temporary directory and trap; caller traps are untouched.
_output_contract_evaluate() (
  local mode="$1" repo="$2" candidate="$3" definition="$4" envelope="${5:-}"
  local normalized schema operation status contract_hash envelope_hash="" resolved
  local artifact path entry metadata tree_path blob_mode blob_type blob bytes min max
  local literal literal_rc body artifact_hash rows="" work spec literal_file
  normalized="$(output_contract_validate "$definition")" || { printf '%s\n' "$normalized"; return 1; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/orchid-output.XXXXXX")" || {
    _output_contract_fail candidate 'cannot create output validation workspace'; return 1;
  }
  trap 'rm -rf "$work"' EXIT
  if [ "$mode" = full ]; then
    if [ ! -f "$envelope" ] || [ -L "$envelope" ]; then
      _output_contract_fail envelope 'output reply must be one JSON object with operation and status'
      return 1
    fi
    bytes="$(wc -c < "$envelope" | tr -d ' ')" || {
      _output_contract_fail candidate 'cannot inspect output reply'; return 1;
    }
    if [ "$bytes" -gt 1048576 ]; then
      _output_contract_fail envelope 'output reply exceeds 1048576 bytes'
      return 1
    fi
    # Bound the snapshot read as well as the earlier size observation: even a
    # concurrently growing reply must not create unbounded validation input.
    if ! head -c 1048577 < "$envelope" > "$work/envelope"; then
      _output_contract_fail candidate 'cannot snapshot output reply'
      return 1
    fi
    envelope="$work/envelope"
    bytes="$(wc -c < "$envelope" | tr -d ' ')"
    if [ "$bytes" -gt 1048576 ]; then
      _output_contract_fail envelope 'output reply exceeds 1048576 bytes'
      return 1
    fi
    if ! orchid_json_file_valid "$envelope" ||
       ! jq -e 'type == "object" and (.operation | type == "string") and (.status | type == "string")' "$envelope" >/dev/null 2>&1; then
      _output_contract_fail envelope 'output reply must be one JSON object with operation and status'
      return 1
    fi
    operation="$(jq -r .operation "$envelope")"
    status="$(jq -r .status "$envelope")"
    if [ "$status" != ok ] ||
       ! printf '%s' "$normalized" | jq -e --arg operation "$operation" \
         'if has("operations") then any(.operations[]; . == $operation) else true end' >/dev/null; then
      jq -cn '{contract:1,passed:true,applicable:false,scope:"full",envelope_checked:false}'
      return 0
    fi
  elif [ "$(printf '%s' "$normalized" | jq '(.artifacts // []) | length')" -eq 0 ]; then
    jq -cn '{contract:1,passed:true,applicable:false,scope:"artifacts",envelope_checked:false,artifacts:[]}'
    return 0
  fi

  # An opaque exact commit, never a branch expression, is the evidence identity.
  case "$candidate" in ''|*[!0-9a-f]*) _output_contract_fail candidate 'candidate must be an exact full commit identifier'; return 1 ;; esac
  if [ "${#candidate}" -ne 40 ] && [ "${#candidate}" -ne 64 ]; then
    _output_contract_fail candidate 'candidate must be an exact full commit identifier'
    return 1
  fi
  resolved="$(git -C "$repo" rev-parse --verify "$candidate^{commit}" 2>/dev/null)" || {
    _output_contract_fail candidate 'candidate commit is unavailable'; return 1;
  }
  if [ "$resolved" != "$candidate" ]; then
    _output_contract_fail candidate 'candidate does not name its exact commit'
    return 1
  fi
  if [ "$mode" = full ] && ! jq -e --arg candidate "$candidate" \
      '(.candidate_sha // "") == "" or .candidate_sha == $candidate' "$envelope" >/dev/null; then
    _output_contract_fail candidate 'reply candidate differs from the bound candidate'
    return 1
  fi
  if ! declare -F _orchid_stream_sha256 >/dev/null; then
    _output_contract_fail definition 'output evidence requires the shared hashing helpers'
    return 1
  fi
  contract_hash="$(printf '%s' "$normalized" | _orchid_stream_sha256)" || {
    _output_contract_fail definition 'cannot hash output contract'; return 1;
  }
  if [ "$mode" = full ]; then
    schema="$(printf '%s' "$normalized" | jq -c '.envelope_schema // {}')"
    if ! _output_contract_schema_file "$envelope" "$schema"; then
      _output_contract_fail envelope 'reply does not satisfy the declared output schema'
      return 1
    fi
    envelope_hash="$(_orchid_stream_sha256 < "$envelope")" || {
      _output_contract_fail candidate 'cannot hash output reply'; return 1;
    }
  fi
  body="$work/blob"; spec="$work/artifacts"; literal_file="$work/literals"
  printf '%s' "$normalized" | jq -c '.artifacts[]?' > "$spec" || {
    _output_contract_fail definition 'cannot read output artifacts'; return 1;
  }
  while IFS= read -r artifact; do
    path="$(printf '%s' "$artifact" | jq -r .path)"
    if ! git --literal-pathspecs -C "$repo" ls-tree -z "$candidate" -- "$path" > "$work/tree" 2>/dev/null; then
      _output_contract_fail candidate 'cannot inspect the committed candidate tree' "$path"
      return 1
    fi
    if [ ! -s "$work/tree" ]; then
      _output_contract_fail artifact 'required committed artifact is missing' "$path"
      return 1
    fi
    entry=""
    if ! IFS= read -r -d '' entry < "$work/tree"; then
      _output_contract_fail candidate 'cannot read the committed artifact tree entry' "$path"
      return 1
    fi
    metadata="${entry%%$'\t'*}"; tree_path="${entry#*$'\t'}"
    IFS=' ' read -r blob_mode blob_type blob <<< "$metadata"
    if [ "$tree_path" != "$path" ] || [ "$blob_type" != blob ]; then
      _output_contract_fail artifact 'required artifact is not a committed file' "$path"
      return 1
    fi
    case "$blob_mode" in 100644|100755) ;; *) _output_contract_fail artifact 'required artifact must not be a symlink or special entry' "$path"; return 1 ;; esac
    bytes="$(git -C "$repo" cat-file -s "$blob" 2>/dev/null)" || {
      _output_contract_fail candidate 'artifact blob is unavailable' "$path"; return 1;
    }
    min="$(printf '%s' "$artifact" | jq '.min_bytes // 0')"
    max="$(printf '%s' "$artifact" | jq '.max_bytes // 1048576')"
    if [ "$bytes" -lt "$min" ] || [ "$bytes" -gt "$max" ]; then
      _output_contract_fail artifact 'committed artifact violates its byte bounds' "$path"
      return 1
    fi
    if ! git -C "$repo" cat-file blob "$blob" > "$body" 2>/dev/null; then
      _output_contract_fail candidate 'cannot read the committed artifact blob' "$path"
      return 1
    fi
    if printf '%s' "$artifact" | jq -e 'has("schema")' >/dev/null; then
      schema="$(printf '%s' "$artifact" | jq -c .schema)"
      if ! _output_contract_schema_file "$body" "$schema"; then
        _output_contract_fail artifact 'committed artifact does not satisfy its JSON schema' "$path"
        return 1
      fi
    fi
    printf '%s' "$artifact" | jq -r '.contains[]?' > "$literal_file" || {
      _output_contract_fail definition 'cannot read artifact literal constraints' "$path"; return 1;
    }
    while IFS= read -r literal; do
      if LC_ALL=C grep -Fq -- "$literal" "$body"; then
        :
      else
        literal_rc=$?
        if [ "$literal_rc" -eq 1 ]; then
          _output_contract_fail artifact 'committed artifact lacks a required literal' "$path"
        else
          _output_contract_fail candidate 'cannot read artifact literal constraints' "$path"
        fi
        return 1
      fi
    done < "$literal_file"
    artifact_hash="$(_orchid_stream_sha256 < "$body")" || {
      _output_contract_fail candidate 'cannot hash the committed artifact' "$path"; return 1;
    }
    rows="$rows$(jq -cn --arg path "$path" --arg blob "$blob" --arg hash "$artifact_hash" --argjson bytes "$bytes" \
      '{path:$path,git_blob:$blob,sha256:$hash,bytes:$bytes}')"$'\n'
  done < "$spec"
  printf '%s' "$rows" | jq -cs --arg mode "$mode" --arg candidate "$candidate" --arg contract_hash "$contract_hash" --arg envelope_hash "$envelope_hash" \
    '{contract:1,passed:true,applicable:true,scope:$mode,envelope_checked:($mode == "full"),candidate_sha:$candidate,contract_sha256:$contract_hash,artifacts:.} +
     (if $mode == "full" then {envelope_sha256:$envelope_hash} else {} end)'
)

output_contract_evaluate() { _output_contract_evaluate full "$@"; }
output_contract_artifacts() { _output_contract_evaluate artifacts "$@"; }
