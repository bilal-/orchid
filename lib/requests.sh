#!/usr/bin/env bash
# Optional exact-intent receipts; never a replacement for a kernel epoch fence.
# An interrupted claim remains pending and refuses automatic re-execution.
orchid_request_begin() {
  local request_id="$1" verb="$2" parsed="$3" root repo scope key intent existing
  ORCHID_REQUEST_DIR=""
  [ -n "$request_id" ] || return 0
  local __orchid_entry_defer_restore=1
  source "$ORCHID_ROOT/lib/common.sh"
  repo="${ORCHID_REPO:-$PWD}"
  repo="$(cd "$repo" && pwd -P)" || return 1
  # Resolve nested directories without changing the kernel's explicit target.
  scope="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo")"
  root="$HOME/.orchid/requests"
  [ ! -L "$HOME/.orchid" ] && [ ! -L "$root" ] || {
    printf 'orchid: request cache may not be a symlink\n' >&2; return 1;
  }
  (umask 077; mkdir -p "$root") || return 1
  chmod 700 "$root" || return 1
  key="$(printf '%s\n%s\n' "$scope" "$request_id" | _orchid_stream_sha256)" || return 1
  ORCHID_REQUEST_DIR="$root/$key.claim"
  intent="$(jq -cn --arg id "$request_id" --arg repo "$repo" --arg scope "$scope" \
    --arg verb "$verb" --arg actor "${ORCHID_ACTOR:-}" --arg epoch "${ORCHID_EPOCH:-}" \
    --argjson argv "$(jq -c '.argv' <<< "$parsed")" \
    '{id:$id,repo:$repo,scope:$scope,verb:$verb,argv:$argv,actor:$actor,epoch:$epoch}')" || return 1
  if (umask 077; orchid_claim_once "$ORCHID_REQUEST_DIR"); then
    printf '%s\n' "$intent" | atomic_write "$ORCHID_REQUEST_DIR/intent.json" || return 1
    return 0
  fi
  [ -d "$ORCHID_REQUEST_DIR" ] && [ ! -L "$ORCHID_REQUEST_DIR" ] || return 1
  existing="$(cat "$ORCHID_REQUEST_DIR/intent.json" 2>/dev/null)" || {
    printf 'orchid: request %s has an incomplete claim; inspect state before issuing a new request\n' "$request_id" >&2; return 1;
  }
  [ "$existing" = "$intent" ] || {
    printf 'orchid: request %s was already used for a different intent, actor or epoch\n' "$request_id" >&2; return 2;
  }
  if [ ! -f "$ORCHID_REQUEST_DIR/result.json" ]; then
    printf 'orchid: request %s is pending or interrupted; inspect state before issuing a new request\n' "$request_id" >&2
    return 1
  fi
  [ ! -L "$ORCHID_REQUEST_DIR/result.json" ] || return 1
  jq -e -s 'length==1 and (.[0]|type=="object" and
    (.exit==0 or .exit==1 or .exit==2) and (.data|type=="object"))' \
    "$ORCHID_REQUEST_DIR/result.json" >/dev/null || {
    printf 'orchid: request %s has a corrupt receipt; inspect state before issuing a new request\n' "$request_id" >&2; return 1;
  }
  return 3
}
orchid_request_finish() {
  local data="$1" rc="$2"
  [ -n "${ORCHID_REQUEST_DIR:-}" ] || return 0
  jq -e -s 'length==1 and (.[0]|type=="object")' "$data" >/dev/null || return 1
  case "$rc" in 0|1|2) ;; *) return 1 ;; esac
  jq -n --slurpfile data "$data" --argjson rc "$rc" \
    '{exit:$rc,data:$data[0]}' | atomic_write "$ORCHID_REQUEST_DIR/result.json"
}
