#!/usr/bin/env bash
# Recoverable publication of selected durable state paths. The caller owns the
# existing run/verb locks; Git CAS remains the integration publication fence.

_publication_runtime_record() { printf '%s/.orchid/runtime/publication.json\n' "${1%/}"; }

_publication_common_dir() {
  local repo="$1" dir
  dir="$(git -C "$repo" rev-parse --git-common-dir)" || return 1
  case "$dir" in /*) ;; *) dir="$repo/$dir" ;; esac
  orchid_physical_dir "$dir"
}

_publication_guard_path() {
  local common="$1" branch="$2" key
  key="$(printf '%s' "$branch" | _orchid_stream_sha256)" || return 1
  printf '%s/orchid-publications/%s.json\n' "$common" "$key"
}

_publication_fail() { printf 'orchid: durable publication: %s\n' "$*" >&2; return 1; }

# Fingerprints include every name, Git-semantic file mode, and byte content.
# NUL separators retain spaces/control bytes in names; symlinks are refused by
# admission rather than followed. This is not a general filesystem backup.
_publication_tree_stream() (
  local path="$1" entry mode digest
  export LC_ALL=C
  if [ -L "$path" ]; then
    _publication_fail "linked durable state is unsupported: $path"; return 1
  elif [ -f "$path" ]; then
    mode=100644; [ ! -x "$path" ] || mode=100755
    digest="$(_orchid_stream_sha256 < "$path")" || return 1
    printf 'file\000%s\000%s\000' "$mode" "$digest"
  elif [ -d "$path" ]; then
    printf 'directory\000'
    shopt -s dotglob nullglob
    for entry in "$path"/*; do
      printf 'entry\000%s\000' "${entry##*/}"
      _publication_tree_stream "$entry" || return 1
    done
    printf 'end\000'
  elif [ -e "$path" ]; then
    _publication_fail "unsupported filesystem entry: $path"; return 1
  else
    printf 'absent\000'
  fi
)

_publication_fingerprint() ( set -o pipefail; _publication_tree_stream "$1" | _orchid_stream_sha256; )

# Materialize immutable Git blobs without checkout filters/hooks or archive
# export-ignore rules. Git omits empty directories: postimages must do so too.
orchid_publication_materialize() {
  local repo="$1" sha="$2" dest="$3" entry meta path mode kind object entries; shift 3
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
    _publication_fail 'committed view must be a fresh owned directory'; return 1
  fi
  for entry in "$dest"/* "$dest"/.[!.]* "$dest"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      _publication_fail 'committed view is not empty (preserved)'; return 1
    fi
  done
  entries="$(mktemp)" || return 1
  if ! git --literal-pathspecs -C "$repo" ls-tree -r -z "$sha" -- "$@" > "$entries"; then rm -f "$entries"; return 1; fi
  mkdir -p "$dest" || { rm -f "$entries"; return 1; }
  while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}"; path="${entry#*$'\t'}"
    IFS=' ' read -r mode kind object <<< "$meta"
    case "$mode:$kind" in 100644:blob|100755:blob) ;; *)
      rm -f "$entries"; _publication_fail "committed durable path is not a regular blob: $path"; return 1 ;;
    esac
    case "/$path/" in *'/../'*|*'/./'*|*'//'*) rm -f "$entries"; _publication_fail 'unsafe committed path'; return 1 ;; esac
    case "$path" in .orchid/*) ;; *) rm -f "$entries"; return 1 ;; esac
    mkdir -p "$(dirname "$dest/$path")" || { rm -f "$entries"; return 1; }
    if ! git -C "$repo" cat-file blob "$object" > "$dest/$path"; then rm -f "$entries"; return 1; fi
    case "$mode" in 100755) chmod 755 "$dest/$path" ;; *) chmod 644 "$dest/$path" ;; esac || { rm -f "$entries"; return 1; }
    local physical_dest
    physical_dest="$(orchid_physical_dir "$dest")" || { rm -f "$entries"; return 1; }
    _orchid_agent_context_input_owned "$physical_dest" "$physical_dest" "$path" file || { rm -f "$entries"; return 1; }
  done < "$entries"
  rm -f "$entries"
}

_publication_owned() {
  local repo="$1" relative="$2" kind=file
  [ ! -d "$repo/$relative" ] || kind=directory
  _orchid_agent_context_input_owned "$repo" "$repo" "$relative" "$kind"
}

orchid_publication_validate_paths() {
  local repo="$1" p q; shift
  repo="$(orchid_physical_dir "$repo")" || return 1
  [ "$#" -gt 0 ] && [ "$#" -le 32 ] || { _publication_fail 'requires 1..32 durable paths'; return 1; }
  for p in "$@"; do
    case "$p" in
      .orchid/tasks|.orchid/reviews|.orchid/requirements.md|.orchid/roadmap.md|.orchid/journal.md|.orchid/BLOCKERS.md|.orchid/baseline.md|.orchid/lessons.md|.orchid/plugins.lock|.orchid/revisions/*) ;;
      *) _publication_fail "path is not a recoverable durable selection: $p"; return 1 ;;
    esac
    case "/$p/" in
      *'/runtime/'*|*'/.git/'*|*'/../'*|*'/./'*|*'//'*)
        _publication_fail "unsafe durable path: $p"; return 1 ;;
    esac
    case "$p" in *$'\n'*|*$'\r'*|*$'\t'*) _publication_fail 'control character in path'; return 1 ;; esac
    case "$p" in *[!A-Za-z0-9_./-]*) _publication_fail "unsupported durable path spelling: $p"; return 1 ;; esac
    for q in "$@"; do
      [ "$p" = "$q" ] && continue
      case "$p/" in "$q/"*) _publication_fail "overlapping durable paths: $p, $q"; return 1 ;; esac
    done
    if [ -d "$repo/$p" ]; then
      orchid_state_tree_owned "$repo" "$p" || return 1
    else
      _publication_owned "$repo" "$p" || return 1
    fi
  done
  [ "$(printf '%s\n' "$@" | LC_ALL=C sort -u | wc -l | tr -d ' ')" -eq "$#" ] || {
    _publication_fail 'duplicate durable paths'; return 1;
  }
}

_publication_guard_owned() {
  local common="$1" guard="$2" dir
  dir="$common/orchid-publications"
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; } || [ -L "$guard" ]; then
    _publication_fail 'publication guard must be an owned regular path'; return 1
  fi
  [ ! -e "$guard" ] || [ -f "$guard" ] || { _publication_fail 'publication guard is not a file'; return 1; }
}

# Called immediately before every durable CAS, including legacy publications.
# A guard owned by this transaction is admitted only by its exact nonce.
orchid_publication_admit() {
  local repo="$1" branch="$2" nonce="${3:-}" common guard owner existing
  common="$(_publication_common_dir "$repo")" || return 1
  guard="$(_publication_guard_path "$common" "$branch")" || return 1
  _publication_guard_owned "$common" "$guard" || return 1
  [ -e "$guard" ] || return 0
  _publication_record_valid "$guard" || return 1
  existing="$(jq -r '.nonce // empty' "$guard")" || return 1
  [ -z "$nonce" ] || { [ "$nonce" != "$existing" ] || return 0; }
  owner="$(jq -r '.repo // "unknown checkout"' "$guard")" || return 1
  _publication_fail "pending transaction for $branch belongs to $owner; resume that checkout first"
}

_publication_record_valid() {
  local record="$1"
  [ -f "$record" ] && [ ! -L "$record" ] || { _publication_fail 'missing or linked receipt'; return 1; }
  [ "$(wc -c < "$record" | tr -d ' ')" -le 65536 ] || { _publication_fail 'oversized receipt'; return 1; }
  jq -e -s '
    length == 1 and (.[0] |
      .schema == 1 and (.phase | IN("prepared","synchronized","unpublished")) and
      ([.repo,.common,.branch,.run_id,.new_run_id,.epoch,.nonce,.old_sha,.new_sha] | all(type == "string")) and
      (.nonce | test("^[a-f0-9]{40,64}-[0-9]+$")) and
      (.old_sha | test("^[a-f0-9]{40,64}$")) and (.new_sha | test("^[a-f0-9]{40,64}$")) and
      (.paths | type == "array" and length > 0 and length <= 32 and
        all(.[]; type == "object" and
          ([.path,.before,.after,.stage,.backup] | all(type == "string")) and
          (.before | test("^[a-f0-9]{64}$")) and (.after | test("^[a-f0-9]{64}$"))))
    )' "$record" >/dev/null || { _publication_fail 'malformed receipt'; return 1; }
}

# Capture once BEFORE any staging work. A later edit must never be absorbed as
# the transaction's preimage merely because it happened while Git was working.
orchid_publication_capture() (
  set -o pipefail
  local repo="$1" p digest rows result; shift
  rows="$(mktemp)" || return 1
  result="$(mktemp)" || { rm -f "$rows"; return 1; }
  trap 'rm -f "$rows" "$result"' EXIT
  for p in "$@"; do
    digest="$(_publication_fingerprint "$repo/$p")" || return 1
    jq -cn --arg p "$p" --arg d "$digest" '{path:$p,before:$d}' >> "$rows" || return 1
  done
  jq -cs . "$rows" > "$result" || return 1
  [ "$(wc -c < "$result" | tr -d ' ')" -le 65536 ] || { _publication_fail 'oversized preimage metadata'; return 1; }
  cat "$result"
)

orchid_publication_preimages_match() (
  set -o pipefail
  local repo="$1" before="$2" rows row p expected
  printf '%s' "$before" | jq -e -s '
    length == 1 and (.[0] | type == "array" and length > 0 and length <= 32 and
      all(.[]; (.path | type == "string") and (.before | type == "string" and test("^[a-f0-9]{64}$"))))' >/dev/null || return 1
  rows="$(printf '%s' "$before" | jq -ce '.[]')" || return 1
  while IFS= read -r row; do
    p="$(jq -r .path <<< "$row")"; expected="$(jq -r .before <<< "$row")"
    [ "$(_publication_fingerprint "$repo/$p")" = "$expected" ] || {
      _publication_fail "source changed during transaction construction: $p (preserved)"; return 1;
    }
  done <<< "$rows"
)

_publication_context_valid() {
  local repo="$1" record="$2" common current_run
  local paths=() p
  repo="$(orchid_physical_dir "$repo")" || return 1
  _publication_record_valid "$record" || return 1
  common="$(_publication_common_dir "$repo")" || return 1
  [ "$(jq -r .repo "$record")" = "$repo" ] && [ "$(jq -r .common "$record")" = "$common" ] || {
    _publication_fail 'receipt checkout identity differs'; return 1;
  }
  [ "$(jq -r .branch "$record")" = "$(config_get "$repo" integration_branch orchid/integration)" ] || {
    _publication_fail 'configured integration branch differs from receipt'; return 1;
  }
  [ "$(jq -r .epoch "$record")" = "$(epoch_current "$repo")" ] || {
    _publication_fail 'receipt epoch differs from current ownership'; return 1;
  }
  current_run="$(fm_get "$repo/.orchid/roadmap.md" run_id)"
  [ "$current_run" = "$(jq -r .run_id "$record")" ] || [ "$current_run" = "$(jq -r .new_run_id "$record")" ] || {
    _publication_fail 'receipt run identity differs'; return 1;
  }
  while IFS= read -r p; do paths+=("$p"); done < <(jq -r '.paths[].path' "$record")
  orchid_publication_validate_paths "$repo" "${paths[@]}"
}

# Installs complete provenance before CAS. Source and staging are still intact.
orchid_publication_prepare() {
  local repo="$1" wt="$2" branch="$3" old="$4" new="$5" preimages="$6"; shift 6
  local common guard runtime nonce rows before after p tmp run newrun
  repo="$(orchid_physical_dir "$repo")" || return 1
  orchid_publication_validate_paths "$repo" "$@" || return 1
  orchid_publication_preimages_match "$repo" "$preimages" || return 1
  [ "$(printf '%s' "$preimages" | jq length)" -eq "$#" ] || { _publication_fail 'preimage selections differ'; return 1; }
  common="$(_publication_common_dir "$repo")" || return 1
  guard="$(_publication_guard_path "$common" "$branch")" || return 1
  _publication_guard_owned "$common" "$guard" || return 1
  orchid_publication_admit "$repo" "$branch" || return 1
  runtime="$(_publication_runtime_record "$repo")"
  _publication_owned "$repo" '.orchid/runtime/publication.json' || return 1
  [ ! -e "$runtime" ] || { _publication_fail 'checkout already has a pending receipt'; return 1; }
  nonce="$new-$$"; rows="$(mktemp)" || return 1
  for p in "$@"; do
    if [ -e "$repo/$p.new.$nonce" ] || [ -L "$repo/$p.new.$nonce" ] ||
       [ -e "$repo/$p.old.$nonce" ] || [ -L "$repo/$p.old.$nonce" ]; then
      rm -f "$rows"; _publication_fail "staging collision for $p"; return 1
    fi
    before="$(printf '%s' "$preimages" | jq -er --arg p "$p" '.[] | select(.path == $p) | .before')" || { rm -f "$rows"; return 1; }
    after="$(_publication_fingerprint "$wt/$p")" || { rm -f "$rows"; return 1; }
    jq -cn --arg p "$p" --arg b "$before" --arg a "$after" --arg n "$nonce" \
      '{path:$p,before:$b,after:$a,stage:($p+".new."+$n),backup:($p+".old."+$n)}' >> "$rows" || { rm -f "$rows"; return 1; }
  done
  mkdir -p "$common/orchid-publications" || { rm -f "$rows"; return 1; }
  tmp="$(mktemp "$common/orchid-publications/receipt.XXXXXX")" || { rm -f "$rows"; return 1; }
  run="$(fm_get "$repo/.orchid/roadmap.md" run_id)"; newrun="$run"
  [ ! -f "$wt/.orchid/roadmap.md" ] || newrun="$(fm_get "$wt/.orchid/roadmap.md" run_id)"
  if ! jq -n --arg repo "$repo" --arg common "$common" --arg branch "$branch" \
      --arg old "$old" --arg new "$new" --arg nonce "$nonce" \
      --arg run "$run" --arg newrun "$newrun" --arg epoch "$(epoch_current "$repo")" \
      --slurpfile paths "$rows" \
      '{schema:1,phase:"prepared",repo:$repo,common:$common,branch:$branch,run_id:$run,new_run_id:$newrun,epoch:$epoch,nonce:$nonce,old_sha:$old,new_sha:$new,paths:$paths}' > "$tmp"; then
    rm -f "$tmp" "$rows"; return 1
  fi
  rm -f "$rows"
  _publication_record_valid "$tmp" || { rm -f "$tmp"; return 1; }
  if ! atomic_write "$runtime" < "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! ln "$tmp" "$guard"; then rm -f "$tmp" "$runtime"; return 1; fi
  rm -f "$tmp"
  printf '%s\n' "$nonce"
}

_publication_entry_sync() {
  local repo="$1" wt="$2" row="$3" nonce="$4" p stage backup before after current
  p="$(jq -r .path <<< "$row")"; stage="$(jq -r .stage <<< "$row")"; backup="$(jq -r .backup <<< "$row")"
  before="$(jq -r .before <<< "$row")"; after="$(jq -r .after <<< "$row")"
  [ "$stage" = "$p.new.$nonce" ] && [ "$backup" = "$p.old.$nonce" ] || { _publication_fail 'unowned staging names'; return 1; }
  _publication_owned "$repo" "$p" && _publication_owned "$repo" "$stage" && _publication_owned "$repo" "$backup" || return 1
  [ "$(_publication_fingerprint "$wt/$p")" = "$after" ] || { _publication_fail "committed source differs from receipt: $p"; return 1; }
  current="$(_publication_fingerprint "$repo/$p")" || return 1
  if [ "$current" != "$before" ] && [ "$current" != "$after" ]; then
    if [ ! -e "$repo/$p" ] && [ -e "$repo/$backup" ] &&
       [ "$(_publication_fingerprint "$repo/$backup")" = "$before" ]; then
      mv "$repo/$backup" "$repo/$p" || return 1
    else
      _publication_fail "source changed after publication began: $p (preserved)"; return 1
    fi
  fi
  if [ -e "$repo/$backup" ]; then
    [ "$(_publication_fingerprint "$repo/$backup")" = "$before" ] || { _publication_fail "foreign backup preserved: $backup"; return 1; }
    rm -rf "${repo:?}/$backup" || return 1
  fi
  if [ "$(_publication_fingerprint "$repo/$p")" = "$after" ]; then
    [ ! -e "$repo/$stage" ] || rm -rf "${repo:?}/$stage" || return 1
    return 0
  fi
  # Recorded staging paths are kernel-owned scratch, never user-selected paths.
  if [ -d "$wt/$p" ]; then
    _ocd_sync_dir_atomic "$repo/$p" "$wt/$p" "$repo/$stage" "$repo/$backup" exact || return 1
  elif [ -f "$wt/$p" ]; then
    _ocd_copy_path "$wt/$p" "$repo/$stage" exact || return 1
    mv "$repo/$stage" "$repo/$p" || return 1
  else
    [ ! -e "$repo/$p" ] || mv "$repo/$p" "$repo/$backup" || return 1
    [ ! -e "$repo/$backup" ] || rm -rf "${repo:?}/$backup" || return 1
  fi
  [ "$(_publication_fingerprint "$repo/$p")" = "$after" ] || { _publication_fail "published fingerprint differs: $p"; return 1; }
}

orchid_publication_sync() {
  local repo="$1" wt="$2" record row nonce
  record="$(_publication_runtime_record "$repo")"
  _publication_context_valid "$repo" "$record" || return 1
  nonce="$(jq -r .nonce "$record")" || return 1
  while IFS= read -r row; do
    _publication_entry_sync "$repo" "$wt" "$row" "$nonce" || return 1
  done < <(jq -c '.paths[]' "$record")
}

_publication_retire() {
  local repo="$1" record="$2" common branch guard nonce row p after
  _publication_context_valid "$repo" "$record" || return 1
  common="$(jq -r .common "$record")"; branch="$(jq -r .branch "$record")"; nonce="$(jq -r .nonce "$record")"
  guard="$(_publication_guard_path "$common" "$branch")" || return 1
  if [ "$(jq -r .phase "$record")" = synchronized ]; then
    while IFS= read -r row; do
      p="$(jq -r .path <<< "$row")"; after="$(jq -r .after <<< "$row")"
      [ "$(_publication_fingerprint "$repo/$p")" = "$after" ] || { _publication_fail "completed publication source changed: $p"; return 1; }
    done < <(jq -c '.paths[]' "$record")
  fi
  if [ -e "$guard" ]; then
    _publication_guard_owned "$common" "$guard" || return 1
    [ "$(jq -r .nonce "$guard")" = "$nonce" ] || { _publication_fail 'guard belongs to another transaction'; return 1; }
    case "$(jq -r .phase "$record")" in
      synchronized|unpublished)
        atomic_write "$(_publication_runtime_record "$repo")" < "$record" || return 1 ;;
    esac
    rm -f "$guard" || return 1
  fi
  rm -f "$(_publication_runtime_record "$repo")"
}

orchid_publication_finish() {
  local repo="$1" record common guard tmp row p after
  record="$(_publication_runtime_record "$repo")"
  _publication_context_valid "$repo" "$record" || return 1
  while IFS= read -r row; do
    p="$(jq -r .path <<< "$row")"; after="$(jq -r .after <<< "$row")"
    [ "$(_publication_fingerprint "$repo/$p")" = "$after" ] || { _publication_fail "cannot finish before path is published: $p"; return 1; }
  done < <(jq -c '.paths[]' "$record")
  common="$(jq -r .common "$record")"; guard="$(_publication_guard_path "$common" "$(jq -r .branch "$record")")" || return 1
  _publication_guard_owned "$common" "$guard" || return 1
  [ -f "$guard" ] && [ "$(jq -r .nonce "$guard")" = "$(jq -r .nonce "$record")" ] || return 1
  tmp="$(mktemp)" || return 1
  if ! jq '.phase="synchronized"' "$record" > "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! atomic_write "$guard" < "$tmp" || ! atomic_write "$record" < "$tmp"; then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  _publication_retire "$repo" "$record"
}

# CAS failure may retire an unpublished intent, never an already-visible commit.
orchid_publication_abort() {
  local repo="$1" record current new common guard tmp
  record="$(_publication_runtime_record "$repo")"
  _publication_context_valid "$repo" "$record" || return 1
  current="$(git -C "$repo" rev-parse "refs/heads/$(jq -r .branch "$record")")" || return 1
  new="$(jq -r .new_sha "$record")"
  if git -C "$repo" merge-base --is-ancestor "$new" "$current"; then
    _publication_fail 'commit is visible; resume pending publication'; return 1
  fi
  common="$(jq -r .common "$record")"; guard="$(_publication_guard_path "$common" "$(jq -r .branch "$record")")" || return 1
  tmp="$(mktemp)" || return 1
  if ! jq '.phase="unpublished"' "$record" > "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! atomic_write "$guard" < "$tmp" || ! atomic_write "$record" < "$tmp"; then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  _publication_retire "$repo" "$record"
}

# Requires both existing locks; run resume invokes this before epoch/journal work.
orchid_publication_recover() {
  local repo="$1" record common branch guard current new old phase wt p rc=0
  repo="$(orchid_physical_dir "$repo")" || return 1
  _publication_owned "$repo" '.orchid/runtime' || return 1
  record="$(_publication_runtime_record "$repo")"
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    common="$(_publication_common_dir "$repo")" || return 1
    branch="$(config_get "$repo" integration_branch orchid/integration)"
    guard="$(_publication_guard_path "$common" "$branch")" || return 1
    _publication_guard_owned "$common" "$guard" || return 1
    [ -e "$guard" ] || return 0
    _publication_record_valid "$guard" || return 1
    [ "$(jq -r .repo "$guard")" = "$repo" ] || { _publication_fail 'recovery belongs to another checkout'; return 1; }
    record="$guard"
  fi
  _publication_context_valid "$repo" "$record" || return 1
  [ "${ORCHID_VERB_LOCK_HELD:-0}" = 1 ] || { _publication_fail 'recovery requires the verb lock'; return 1; }
  [ -f "$repo/.orchid/runtime/lock/owner.json" ] &&
    [ "$(jq -r .pid "$repo/.orchid/runtime/lock/owner.json")" = "$$" ] || {
      _publication_fail 'recovery requires the run lock'; return 1;
    }
  common="$(_publication_common_dir "$repo")" || return 1
  branch="$(jq -r .branch "$record")"; guard="$(_publication_guard_path "$common" "$branch")" || return 1
  _publication_guard_owned "$common" "$guard" || return 1
  if [ -e "$guard" ]; then
    _publication_record_valid "$guard" || return 1
    [ "$(jq -r .nonce "$guard")" = "$(jq -r .nonce "$record")" ] || return 1
    if ! jq -e -s 'length == 2 and ((.[0]|del(.phase)) == (.[1]|del(.phase)))' "$guard" "$record" >/dev/null; then
      _publication_fail 'local and authoritative receipts disagree'; return 1
    fi
    if [ "$(jq -r .phase "$guard")" = prepared ] && [ "$(jq -r .phase "$record")" != prepared ]; then
      _publication_fail 'local completion marker precedes authoritative publication'; return 1
    fi
    # Authoritative completion survives interruption between the two records.
    case "$(jq -r .phase "$guard")" in synchronized|unpublished)
      new="$(jq -r .new_sha "$guard")"
      _publication_retire "$repo" "$guard" || return 1
      printf 'recovered durable publication: %s\n' "$new"; return 0 ;;
    esac
  fi
  phase="$(jq -r .phase "$record")"
  case "$phase" in synchronized|unpublished)
    new="$(jq -r .new_sha "$record")"
    _publication_retire "$repo" "$record" || return 1
    printf 'recovered durable publication: %s\n' "$new"; return 0 ;;
  esac
  old="$(jq -r .old_sha "$record")"; new="$(jq -r .new_sha "$record")"
  current="$(git -C "$repo" rev-parse "refs/heads/$branch")" || return 1
  if [ "$current" = "$old" ]; then _publication_retire "$repo" "$record"; return $?; fi
  git -C "$repo" merge-base --is-ancestor "$new" "$current" || { _publication_fail 'integration history no longer contains publication'; return 1; }
  local paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(jq -r '.paths[].path' "$record")
  orchid_publication_validate_paths "$repo" "${paths[@]}" || return 1
  if [ "$current" != "$new" ] && ! git -C "$repo" diff --quiet "$new" "$current" -- "${paths[@]}"; then
    _publication_fail 'a later integration commit changed selected paths'; return 1
  fi
  [ -e "$(_publication_runtime_record "$repo")" ] || atomic_write "$(_publication_runtime_record "$repo")" < "$record" || return 1
  wt="$(mktemp -d "${TMPDIR:-/tmp}/orchid-publication.XXXXXX")" || return 1
  if ! orchid_publication_materialize "$repo" "$new" "$wt" "${paths[@]}"; then rm -rf "${wt:?}"; return 1; fi
  orchid_publication_sync "$repo" "$wt" || rc=$?
  if [ "$rc" -eq 0 ]; then orchid_publication_finish "$repo" || rc=$?; fi
  rm -rf "${wt:?}"
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'recovered durable publication: %s\n' "$new"
}
