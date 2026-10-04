#!/usr/bin/env bash
# Optional exact-intent receipts; never a replacement for a kernel epoch fence.
# An interrupted claim remains pending and refuses automatic re-execution.
# Admission also applies to historical replays. Run in a subshell so a guard's
# refusal returns through the public structured-error channel. This is read-only:
# it never acquires a run epoch or performs the requested transition.
orchid_request_admit() {
  local verb="$1" parsed="$2" path repo
  path="$(jq -r '.command.path|join(" ")' <<< "$parsed")" || return 1
  repo="${ORCHID_REPO:-$PWD}"
  case "$verb:$path" in
    service:install)
      repo="$(jq -r --arg default "$repo" '.option_values["--repo"] // $default' <<< "$parsed")" || return 1
      [ -d "$repo" ] || orchid_die "no such repo directory: $repo"
      repo="$(cd "$repo" && pwd -P)" || return 1
      unattended_service_install_require "$repo" || return 1
      ;;
    trust:show)
      repo="$(jq -r --arg default "$repo" '.positionals[0] // $default' <<< "$parsed")" || return 1
      unattended_trust_inspect "$repo"
      ;;
    trust:revoke)
      repo="$(jq -r --arg default "$repo" '.positionals[0] // $default' <<< "$parsed")" || return 1
      unattended_trust_revoke_resolve "$repo" || :
      ;;
    status:*)
      if jq -e '.option_values|has("--explain")' <<< "$parsed" >/dev/null; then
        unattended_trust_inspect "$repo"
      fi
      ;;
  esac
  orchid_root_stale_gate
}

orchid_request_begin() {
  local request_id="$1" verb="$2" parsed="$3" root repo scope key intent existing
  ORCHID_REQUEST_DIR=""
  [ -n "$request_id" ] || return 0
  local __orchid_entry_defer_restore=1
  source "$ORCHID_ROOT/lib/common.sh"
  source "$ORCHID_ROOT/lib/trust.sh"
  (orchid_request_admit "$verb" "$parsed") || return 1
  repo="${ORCHID_REPO:-$PWD}"
  repo="$(cd "$repo" && pwd -P)" || return 1
  # Reuse filesystem-only worktree discovery: receipt scope does not need Git
  # against a target that may have no unattended authorization.
  scope="$(_unattended_worktree_root "$repo" 2>/dev/null || printf '%s' "$repo")"
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
