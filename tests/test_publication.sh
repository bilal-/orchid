#!/usr/bin/env bash
# RED: Interrupted/foreign publication cannot admit another mutation or overwrite edits.
# GREEN: Resume finishes the exact committed paths once, preserving runtime and index.
source "$(dirname "$0")/helpers.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/publication.sh"
mkdir -p "$WORK/origin"
cd_scratch "$WORK/origin" || exit 1
git init -q
git commit -q --allow-empty -m root
"$ORCHID_BIN" init >/dev/null || { fail 'initialize publication fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'control worktree'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$PWD"
repo="$PWD"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed -n 's/^epoch: //p')"; export ORCHID_EPOCH
"$ORCHID_BIN" task create T 'original task' >/dev/null
mkdir -p .orchid/reviews/runtime
printf 'hidden evidence\n' > .orchid/reviews/.hidden
printf 'nested runtime is durable evidence\n' > .orchid/reviews/runtime/proof
printf 'unrelated staged content\n' > staged.txt
git add staged.txt
git ls-files --stage -z > "$WORK/index-before.entries"
printf 'unrelated live log\n' > .orchid/runtime/live.log
exec 3>> .orchid/runtime/live.log

# Every call runs in a separate process so deliberate SIGKILL cannot kill the
# test harness. No fixture script points to Orchid's actual operational state.
cat > "$WORK/commit.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$ORCHID_ROOT/lib/common.sh"
source "$ORCHID_ROOT/lib/frontmatter.sh"
repo="$ORCHID_REPO"
verb_lock_acquire "$repo"
trap 'verb_lock_release "$repo"' EXIT
publication_hook() {
  local wt="$1"
  if [ "${PUBLICATION_CRASH:-}" = editor ]; then
    fm_set "$repo/.orchid/tasks/T.md" title 'concurrent editor change'
  fi
  fm_set "$wt/.orchid/tasks/T.md" title "$PUBLICATION_VALUE"
  mkdir -p "$wt/.orchid/reviews"
  mkdir -p "$wt/.orchid/reviews/empty-$PUBLICATION_VALUE"
  printf '%s\n' "$PUBLICATION_VALUE" > "$wt/.orchid/reviews/T-proof.log"
  printf '\npublication: %s\n' "$PUBLICATION_VALUE" >> "$wt/.orchid/journal.md"
}
git() {
  command git "$@" || return "$?"
  local arg
  for arg in "$@"; do
    if [ "$arg" = update-ref ] && [ "${PUBLICATION_CRASH:-}" = cas ]; then kill -KILL "$$"; fi
  done
}
ln() {
  if [ "${PUBLICATION_CRASH:-}" = before-guard ]; then kill -KILL "$$"; fi
  command ln "$@" || return "$?"
  if [ "${PUBLICATION_CRASH:-}" = after-guard ]; then kill -KILL "$$"; fi
}
rm() {
  command rm "$@" || return "$?"
  if [ "${PUBLICATION_CRASH:-}" = retire-guard ]; then
    case "${2:-}" in */orchid-publications/*.json) kill -KILL "$$" ;; esac
  fi
}
mv() {
  command mv "$@" || return "$?"
  if [ "${PUBLICATION_CRASH:-}" = backup ] && [ "${1:-}" = "$repo/.orchid/tasks" ]; then kill -KILL "$$"; fi
  if [ "${PUBLICATION_CRASH:-}" = first ] && [ "${2:-}" = "$repo/.orchid/tasks" ]; then kill -KILL "$$"; fi
  if [ "${PUBLICATION_CRASH:-}" = finish-guard ]; then
    case "${2:-}" in */orchid-publications/*.json) kill -KILL "$$" ;; esac
  fi
}
ORCHID_COMMIT_DURABLE_HOOK=publication_hook
ORCHID_COMMIT_DURABLE_RECOVERABLE=1
orchid_commit_durable "$repo" "publication $PUBLICATION_VALUE" .orchid/tasks .orchid/reviews .orchid/journal.md
EOF

commit_value() {
  PUBLICATION_VALUE="$1" PUBLICATION_CRASH="${2:-}" /bin/bash "$WORK/commit.sh"
}
resume_publication() {
  local output
  output="$(ORCHID_LOCK_BREAK_S=0 "$ORCHID_BIN" run resume)" || { fail "resume failed: $output"; return 1; }
  ORCHID_EPOCH="$(printf '%s\n' "$output" | sed -n 's/^epoch: //p')"; export ORCHID_EPOCH
  printf '%s\n' "$output"
}
assert_index_preserved() {
  # HEAD advances during publication, so diff --cached compares against a new
  # base even when the index is untouched. Compare its actual entries instead.
  git ls-files --stage -z > "$WORK/index-after.entries"
  cmp "$WORK/index-before.entries" "$WORK/index-after.entries" || fail 'publication/recovery preserves whole source index'
}

before="$(git rev-parse orchid/integration)"
rc=0
out="$(ORCHID_COMMIT_DURABLE_RECOVERABLE=1 orchid_commit_durable "$repo" unsafe .orchid/runtime 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'runtime selection refused'
assert_eq "$before" "$(git rev-parse orchid/integration)" 'unsafe selection cannot publish'
red_case 'runtime and whole-state publication are outside recoverable path admission'
admission_paths=()
for ((n=1; n<=32; n++)); do admission_paths+=(".orchid/revisions/admission-$n"); done
orchid_publication_validate_paths "$repo" "${admission_paths[@]}" || fail '32 distinct selected paths accepted'
rc=0; orchid_publication_validate_paths "$repo" "${admission_paths[@]}" .orchid/revisions/one-more > "$WORK/path-count.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail '33 selected paths refused'
rc=0; orchid_publication_validate_paths "$repo" .orchid/tasks .orchid/tasks > "$WORK/path-duplicate.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'duplicate selections refused'
rc=0; orchid_publication_validate_paths "$repo" .orchid/revisions/group .orchid/revisions/group/tasks > "$WORK/path-overlap.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'overlapping selections refused'
red_case 'oversized, duplicate, and overlapping selections cannot enter publication'
green_case '32 distinct owned selections meet the exact path-count boundary'

# Callers often inspect status; Bash then disables implicit errexit inside
# sourced functions. A rejected hook must never publish its partial writes.
publication_failed_hook() {
  fm_set "$1/.orchid/tasks/T.md" title 'partial rejected hook' || return 1
  return 77
}
failed_before="$(git rev-parse orchid/integration)"
failed_title="$(fm_get .orchid/tasks/T.md title)"
if ( trap - EXIT
  ORCHID_COMMIT_DURABLE_HOOK=publication_failed_hook ORCHID_COMMIT_DURABLE_RECOVERABLE=1 \
    orchid_commit_durable "$repo" 'rejected hook' .orchid/tasks
); then fail 'conditional caller cannot ignore a rejected publication hook'; fi
assert_eq "$failed_before" "$(git rev-parse orchid/integration)" 'hook failure cannot move integration ref'
assert_eq "$failed_title" "$(fm_get .orchid/tasks/T.md title)" 'hook failure cannot overwrite source state'
red_case 'conditional helper invocation propagates rejected staging hooks before publication'
publication_success_hook() { fm_set "$1/.orchid/tasks/T.md" title 'accepted hook'; }
( trap - EXIT
  ORCHID_COMMIT_DURABLE_HOOK=publication_success_hook ORCHID_COMMIT_DURABLE_RECOVERABLE=1 \
    orchid_commit_durable "$repo" 'accepted hook' .orchid/tasks
) || fail 'healthy staging hook publishes through the same conditional call'
assert_eq 'accepted hook' "$(fm_get .orchid/tasks/T.md title)" 'healthy hook publishes complete selected state'
green_case 'successful hook status permits the identical publication path'

# Failed Git producers must be explicit even when the caller tests status.
publication_producer_hook() {
  fm_set "$1/.orchid/tasks/T.md" title "producer ${producer:-healthy}" || return 1
  printf 'producer %s\n' "${producer:-healthy}" >> "$1/.orchid/journal.md"
}
for producer in add diff commit rev-parse; do
  producer_before="$(git rev-parse orchid/integration)"
  producer_title="$(fm_get .orchid/tasks/T.md title)"
  if ( trap - EXIT
    git() {
      if [ "${1:-}" = -C ]; then
        case "${2:-}" in
          */orchid-commit.*)
            if [ "${3:-}" = "$producer" ]; then
              case "$producer" in
                add) [ "${6:-}" != .orchid/journal.md ] || return 77 ;;
                rev-parse) if [ "${4:-}" = HEAD ]; then command git "$@"; return 77; fi ;;
                *) return 77 ;;
              esac
            fi
            ;;
        esac
      fi
      command git "$@"
    }
    ORCHID_COMMIT_DURABLE_HOOK=publication_producer_hook ORCHID_COMMIT_DURABLE_RECOVERABLE=1 \
      orchid_commit_durable "$repo" "failed $producer" .orchid/tasks .orchid/journal.md
  ); then fail "failed $producer cannot report publication success"; fi
  assert_eq "$producer_before" "$(git rev-parse orchid/integration)" "failed $producer cannot move integration ref"
  assert_eq "$producer_title" "$(fm_get .orchid/tasks/T.md title)" "failed $producer cannot overwrite source state"
done
red_case 'conditional publication propagates staging diff commit and commit-ID producer failures'
producer=healthy
( trap - EXIT
  ORCHID_COMMIT_DURABLE_HOOK=publication_producer_hook ORCHID_COMMIT_DURABLE_RECOVERABLE=1 \
    orchid_commit_durable "$repo" 'healthy Git producers' .orchid/tasks .orchid/journal.md
) || fail 'healthy producers publish through the same conditional call'
assert_eq 'producer healthy' "$(fm_get .orchid/tasks/T.md title)" 'healthy producers publish complete selected state'
green_case 'healthy Git producers permit complete selected publication'

# A fresh nested selection must enter the commit, not only a staging worktree.
publication_nested_hook() {
  mkdir -p "$1/.orchid/revisions/nested/tasks" || return 1
  printf 'archived generation\n' > "$1/.orchid/revisions/nested/tasks/T.md"
}
( trap - EXIT
  ORCHID_COMMIT_DURABLE_HOOK=publication_nested_hook ORCHID_COMMIT_DURABLE_RECOVERABLE=1 \
    orchid_commit_durable "$repo" 'nested archive publication' .orchid/revisions/nested
) || fail 'publish fresh nested selection'
[ -f .orchid/revisions/nested/tasks/T.md ] || fail 'fresh archive cannot silently disappear during publication'
git cat-file -e orchid/integration:.orchid/revisions/nested/tasks/T.md || fail 'fresh nested archive must be committed'
red_case 'a newly created nested archive cannot be silently omitted by Git pathspec exclusion'
assert_index_preserved
green_case 'the committed nested archive appears in the source without altering its index'

commit_value normal > "$WORK/normal.log" 2>&1 || { cat "$WORK/normal.log" >&2; fail 'normal recoverable commit'; exit 1; }
assert_eq normal "$(fm_get .orchid/tasks/T.md title)" 'normal durable state published'
[ ! -e .orchid/runtime/publication.json ] || fail 'successful publication retires local receipt'
assert_eq 'hidden evidence' "$(cat .orchid/reviews/.hidden)" 'exact durable copy preserves hidden evidence'
assert_eq 'nested runtime is durable evidence' "$(cat .orchid/reviews/runtime/proof)" 'nested runtime name is not global runtime'
assert_index_preserved
green_case 'selected durable paths publish completely without moving runtime or index'

mkdir -p "$WORK/occupied-view"
printf 'preserved\n' > "$WORK/occupied-view/marker"
rc=0; out="$(orchid_publication_materialize "$repo" "$(git rev-parse orchid/integration)" "$WORK/occupied-view" .orchid/tasks 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'nonempty committed view refused'
assert_eq preserved "$(cat "$WORK/occupied-view/marker")" 'occupied view bytes preserved'
red_case 'committed materialization refuses an existing populated destination'

for target in target $'target\n'; do
  ln -s "$target" .orchid/reviews/link
  before="$(git rev-parse orchid/integration)"
  rc=0; commit_value linked > "$WORK/linked.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'nested durable symlink refused'
  assert_eq "$before" "$(git rev-parse orchid/integration)" 'linked state cannot publish'
  [ -L .orchid/reviews/link ] || fail 'refused nested link is preserved'
  rm .orchid/reviews/link
done
red_case 'nested state symlinks are refused including distinct trailing-newline targets'
printf 'ordinary proof\n' > .orchid/reviews/link
commit_value regular-proof > "$WORK/regular-proof.log" 2>&1 || { cat "$WORK/regular-proof.log" >&2; fail 'regular durable proof'; exit 1; }
assert_eq 'ordinary proof' "$(cat .orchid/reviews/link)" 'regular proof accepted in the same selected namespace'
green_case 'fresh committed views and regular durable blobs admit publication'

for crash in before-guard after-guard; do
  before="$(git rev-parse orchid/integration)"
  title_before="$(fm_get .orchid/tasks/T.md title)"
  rc=0; commit_value "unpublished-$crash" "$crash" > "$WORK/$crash.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$crash interruption occurred"
  assert_eq "$before" "$(git rev-parse orchid/integration)" "$crash did not publish a commit"
  [ -f .orchid/runtime/publication.json ] || fail "$crash retained intent"
  rc=0; "$ORCHID_BIN" task set T title bypass > "$WORK/$crash-refused.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$crash incomplete intent blocks mutation"
  red_case "$crash interruption retains intent and refuses mutation before CAS"
  resume_publication > "$WORK/$crash-resume.log" || { fail "$crash unpublished recovery"; exit 1; }
  ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
  assert_eq "$before" "$(git rev-parse orchid/integration)" "$crash recovery invents no committed state"
  assert_eq "$title_before" "$(fm_get .orchid/tasks/T.md title)" "$crash source preimage remains unchanged"
  [ ! -e .orchid/runtime/publication.json ] || fail "$crash abandoned intent retired"
  green_case "$crash resume retires an unpublished intent without replaying its hook"
done

for crash in cas first backup finish-guard retire-guard; do
  value="after-$crash"
  cp .orchid/tasks/T.md "$WORK/pre-$crash.md"
  rc=0; commit_value "$value" "$crash" > "$WORK/crash-$crash.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$crash interruption occurred"
  [ -f .orchid/runtime/publication.json ] || { fail "$crash retains receipt"; exit 1; }
  published="$(git rev-parse orchid/integration)"
  assert_eq "$value" "$(git show "$published:.orchid/tasks/T.md" | awk '/^title: /{print substr($0,8);exit}')" "$crash commit is authoritative"
  rc=0; out="$("$ORCHID_BIN" task set T title bypass 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$crash blocks new mutations"
  assert_match 'interrupted durable publication' "$out" "$crash admission names recovery"
  red_case "interruption at $crash blocks mutation before mixed state can become another commit"
  out="$(resume_publication 2>&1)" || { fail "$crash resume"; exit 1; }
  # A command substitution cannot export the new epoch into this shell.
  ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
  assert_match 'recovered durable publication' "$out" "$crash resumes from committed transaction"
  assert_eq "$value" "$(fm_get .orchid/tasks/T.md title)" "$crash complete task restored"
  assert_eq "$value" "$(cat .orchid/reviews/T-proof.log)" "$crash remaining evidence restored"
  [ ! -e ".orchid/reviews/empty-$value" ] || fail 'recovery matches committed tree rather than untracked empty directories'
  [ ! -e .orchid/runtime/publication.json ] || fail "$crash receipt retired after all paths"
  [ ! -e .orchid/runtime/verb-lock ] || fail "$crash verb lock released"
  [ ! -e .orchid/runtime/lock ] || fail "$crash run lock released"
  before="$(git rev-parse orchid/integration)"
  resume_publication > "$WORK/second-resume-$crash.log" || { fail 'second resume'; exit 1; }
  ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
  assert_eq "$before" "$(git rev-parse orchid/integration)" 'repeated resume creates no duplicate durable commit'
  assert_index_preserved
  green_case "resume at $crash finishes selected publication idempotently"
done
printf 'after recovery\n' >&3
exec 3>&-
assert_match 'after recovery' "$(cat .orchid/runtime/live.log)" 'unrelated open log descriptor survives all recovery paths'

# Foreign edits must remain intact and keep publication pending until reconciled.
rc=0; commit_value foreign cas > "$WORK/foreign-crash.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'foreign edit interruption occurred'
cp .orchid/tasks/T.md "$WORK/pre-foreign.md"
fm_set .orchid/tasks/T.md title 'foreign user edit'
rc=0; out="$(ORCHID_LOCK_BREAK_S=0 "$ORCHID_BIN" run resume 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'foreign source edit prevents recovery'
assert_eq 'foreign user edit' "$(fm_get .orchid/tasks/T.md title)" 'foreign source bytes preserved'
[ -f .orchid/runtime/publication.json ] || fail 'foreign edit retains pending receipt'
[ ! -e .orchid/runtime/verb-lock ] && [ ! -e .orchid/runtime/lock ] || fail 'refused recovery releases both locks'
red_case 'recovery refuses changed source bytes and releases both locks without deleting the receipt'
cp "$WORK/pre-foreign.md" .orchid/tasks/T.md
resume_publication > "$WORK/foreign-resume.log" || { fail 'restore expected preimage then recover'; exit 1; }
ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
assert_eq foreign "$(fm_get .orchid/tasks/T.md title)" 'matching preimage permits recovery'
green_case 'the original preimage recovers after a foreign edit is separately preserved'

# A later unrelated commit is compatible; a selected-state descendant is not.
for kind in unrelated selected; do
  rc=0; commit_value "$kind-descendant" cas > "$WORK/$kind-crash.log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$kind interruption"
  published="$(git rev-parse orchid/integration)"
  desc="$WORK/descendant-$kind"
  git worktree add -q --detach "$desc" "$published" || { fail 'descendant checkout'; exit 1; }
  if [ "$kind" = unrelated ]; then
    printf 'unrelated change\n' > "$desc/other.txt"
    git -C "$desc" add other.txt
  else
    fm_set "$desc/.orchid/tasks/T.md" title 'later durable state'
    git -C "$desc" add .orchid/tasks/T.md
  fi
  git -C "$desc" commit -q -m "$kind descendant"
  descendant="$(git -C "$desc" rev-parse HEAD)"
  git update-ref refs/heads/orchid/integration "$descendant" "$published"
  if [ "$kind" = selected ]; then
    rc=0; out="$(ORCHID_LOCK_BREAK_S=0 "$ORCHID_BIN" run resume 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || fail 'selected descendant must refuse recovery'
    assert_match 'later integration commit changed selected paths' "$out" 'selected descendant diagnostic'
    [ -f .orchid/runtime/publication.json ] || fail 'selected descendant retains receipt'
    red_case 'a later selected-state commit cannot be overwritten by recovery'
    git update-ref refs/heads/orchid/integration "$published" "$descendant"
  fi
  resume_publication > "$WORK/$kind-resume.log" || { fail "$kind descendant recovery"; exit 1; }
  ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
  assert_eq "$kind-descendant" "$(fm_get .orchid/tasks/T.md title)" "$kind candidate state recovered"
done
green_case 'unrelated descendant commits preserve recovery and selected-state conflicts remain explicit'

# Damage in the local pointer must not override authoritative receipt phase.
rc=0; commit_value damaged-pointer cas > "$WORK/damaged-crash.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'pointer damage interruption'
cp .orchid/runtime/publication.json "$WORK/original-receipt.json"
jq '.phase="synchronized"' "$WORK/original-receipt.json" > "$WORK/damaged-receipt.json"
cp "$WORK/damaged-receipt.json" .orchid/runtime/publication.json
before="$(fm_get .orchid/tasks/T.md title)"
rc=0; out="$(ORCHID_LOCK_BREAK_S=0 "$ORCHID_BIN" run resume 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail 'local completion claim cannot supersede prepared common guard'
[ -f .orchid/runtime/publication.json ] || fail 'inconsistent receipt remains available'
assert_eq "$before" "$(fm_get .orchid/tasks/T.md title)" 'damaged pointer causes no source mutation'
red_case 'a damaged local completion marker cannot retire an unfinished authoritative publication'
cp "$WORK/original-receipt.json" .orchid/runtime/publication.json
resume_publication > "$WORK/damaged-resume.log" || { fail 'consistent receipt recovers'; exit 1; }
ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
assert_eq damaged-pointer "$(fm_get .orchid/tasks/T.md title)" 'consistent pointer recovers pending state'
green_case 'matching local and authoritative receipts admit recovery'

# JSON whitespace changes no intent; it exercises the raw receipt byte bound
# while preserving real source/ref/epoch identities from an actual preparation.
rc=0; commit_value bounded-receipt before-guard > "$WORK/receipt-crash.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'receipt-bound interruption'
cp .orchid/runtime/publication.json "$WORK/bounded-receipt.json"
receipt_bytes="$(wc -c < "$WORK/bounded-receipt.json" | tr -d ' ')"
padding=$((65536 - receipt_bytes))
[ "$padding" -ge 0 ] || { fail 'fixture receipt fits raw boundary'; exit 1; }
printf '%*s' "$padding" '' >> "$WORK/bounded-receipt.json"
cp "$WORK/bounded-receipt.json" .orchid/runtime/publication.json
printf ' ' >> .orchid/runtime/publication.json
before="$(git rev-parse orchid/integration)"
rc=0; out="$(ORCHID_LOCK_BREAK_S=0 "$ORCHID_BIN" run resume 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail '65537-byte receipt refused'
assert_match 'oversized receipt' "$out" 'receipt limit diagnostic'
assert_eq "$before" "$(git rev-parse orchid/integration)" 'oversized receipt causes no publication'
[ -f .orchid/runtime/publication.json ] || fail 'oversized receipt preserved'
red_case 'oversized raw receipt is refused before recovery can interpret it'
cp "$WORK/bounded-receipt.json" .orchid/runtime/publication.json
resume_publication > "$WORK/bounded-receipt-resume.log" || { fail 'exact receipt boundary recovers'; exit 1; }
ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"; export ORCHID_EPOCH
[ ! -e .orchid/runtime/publication.json ] || fail 'exact-boundary intent retires'
assert_eq "$before" "$(git rev-parse orchid/integration)" 'unpublished exact-boundary receipt invents no state'
green_case '65536-byte single-document receipt preserves its valid recovery semantics'

before="$(git rev-parse orchid/integration)"
rc=0; commit_value 'older transaction' editor > "$WORK/editor-window.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail 'source edit during construction refuses publication'
assert_eq "$before" "$(git rev-parse orchid/integration)" 'construction-window edit cannot publish older state'
assert_eq 'concurrent editor change' "$(fm_get .orchid/tasks/T.md title)" 'construction-window editor bytes are preserved'
[ ! -e .orchid/runtime/publication.json ] || fail 'refused pre-CAS construction leaves no pending publication'
red_case 'source edits during staging are compared to the original preimage rather than absorbed and overwritten'
commit_value 'after editor reconciliation' > "$WORK/editor-green.log" 2>&1 || { fail 'stable source after editor change'; exit 1; }
assert_eq 'after editor reconciliation' "$(fm_get .orchid/tasks/T.md title)" 'stable source accepts a new intent'
green_case 'a new intent against the actual unchanged source preimage publishes normally'
assert_index_preserved
# Broad legacy selection still must exclude the actual runtime namespace.
(
  trap - EXIT
  mkdir -p "$WORK/exclusion" || exit 1
  cd "$WORK/exclusion" || exit 1
  git init -q || exit 1
  git commit -q --allow-empty -m root || exit 1
  export ORCHID_REPO="$PWD"
  "$ORCHID_BIN" init >/dev/null || exit 1
  runtime_exclusion_hook() {
    mkdir -p "$1/.orchid/runtime" "$1/.orchid/reviews" || return 1
    printf 'private runtime\n' > "$1/.orchid/runtime/secret" || return 1
    printf 'durable proof\n' > "$1/.orchid/reviews/proof" || return 1
  }
  ORCHID_COMMIT_DURABLE_HOOK=runtime_exclusion_hook ORCHID_COMMIT_DURABLE_RECOVERABLE=0 \
    orchid_commit_durable "$PWD" 'runtime exclusion' .orchid || exit 1
  if git cat-file -e orchid/integration:.orchid/runtime/secret 2>/dev/null; then exit 1; fi
  git cat-file -e orchid/integration:.orchid/reviews/proof || exit 1
) || fail 'literal top-level runtime exclusion preserves broad legacy staging'
green_case 'broad legacy publication commits durable state while excluding runtime files'

[ "$FAILS" -eq 0 ]
