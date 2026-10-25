#!/usr/bin/env bash
# RED: Failed journal writers cannot publish a partial plan or task revision.
# GREEN: The same public commands publish once their journal writer succeeds.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
export HOME="$MACHINE_HOME" ORCHID_ROOT="$REPO_ROOT"
mkdir -p "$WORK/origin" "$WORK/kernel"
cd_scratch "$WORK/origin" || exit 1
git init -q
git commit -q --allow-empty -m baseline
"$ORCHID_BIN" init >/dev/null || { fail 'initialize hook fixture'; exit 1; }
git worktree add -q "$WORK/control" orchid/integration || { fail 'hook control checkout'; exit 1; }
cd_scratch "$WORK/control" || exit 1
export ORCHID_REPO="$WORK/control"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"; export ORCHID_EPOCH
printf 'Journal every published transition.\n' > "$WORK/requirements.md"
"$ORCHID_BIN" requirements import "$WORK/requirements.md" >/dev/null || { fail 'hook requirements'; exit 1; }
"$ORCHID_BIN" task create A 'Audit node' --archetype review >/dev/null || { fail 'hook node'; exit 1; }

# Copy only executable dispatch surfaces that this fixture changes. Libraries
# remain read-only links to the tested tree; no actual kernel file is edited.
for entry in "$REPO_ROOT"/*; do
  name="${entry##*/}"
  case "$name" in
    bin|libexec) cp -R "$entry" "$WORK/kernel/$name" || { fail 'copy fixture dispatch'; exit 1; } ;;
    *) ln -s "$entry" "$WORK/kernel/$name" || { fail 'link fixture support'; exit 1; } ;;
  esac
done
healthy_journal() { cp -p "$REPO_ROOT/libexec/orchid-journal" "$WORK/kernel/libexec/orchid-journal"; }
failed_journal() {
  printf '#!/usr/bin/env bash\nprintf "injected journal failure\\n" >&2\nexit 79\n' > "$WORK/kernel/libexec/orchid-journal"
  chmod 755 "$WORK/kernel/libexec/orchid-journal"
}
state_digest() {
  git rev-parse orchid/integration
  git hash-object .orchid/roadmap.md .orchid/tasks/A.md .orchid/journal.md
}
reject_without_publication() {
  local label="$1" before rc=0; shift
  before="$(state_digest)" || return 1
  failed_journal || return 1
  "$WORK/kernel/bin/orchid" "$@" > "$WORK/refused.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label refuses a rejected journal writer"
  assert_eq "$before" "$(state_digest)" "$label preserves integration ref and source state"
  grep -F 'injected journal failure' "$WORK/refused.out" >/dev/null || fail "$label keeps journal stderr visible"
  healthy_journal || return 1
}
reject_without_publication plan plan apply --reason blocked-plan || { fail 'exercise plan refusal'; exit 1; }
red_case 'plan publication refuses before status mutation when its journal producer fails'
"$WORK/kernel/bin/orchid" plan apply --reason accepted-plan >/dev/null || { fail 'healthy plan publication'; exit 1; }
assert_eq running "$(fm_get .orchid/roadmap.md run_status)" 'healthy plan becomes running'
grep -F accepted-plan .orchid/journal.md >/dev/null || fail 'accepted plan has its journal reason'
green_case 'the same plan publishes with a healthy journal producer'

reject_without_publication restart task restart A --reason blocked-restart || { fail 'exercise restart refusal'; exit 1; }
red_case 'restart cannot archive or advance generations after a rejected journal write'
"$WORK/kernel/bin/orchid" task restart A --reason accepted-restart >/dev/null || { fail 'healthy restart'; exit 1; }
assert_eq 2 "$(fm_version .orchid/tasks/A.md execution_generation)" 'healthy restart advances generation'
grep -F accepted-restart .orchid/journal.md >/dev/null || fail 'accepted restart has its journal reason'
green_case 'the same restart publishes its archive generation and journal together'

reject_without_publication revision task revise A --acceptance-criteria 'Revised audit' --reason blocked-revision || { fail 'exercise revision refusal'; exit 1; }
red_case 'contract revision cannot publish after a rejected journal write'
"$WORK/kernel/bin/orchid" task revise A --acceptance-criteria 'Revised audit' --reason accepted-revision >/dev/null || { fail 'healthy revision'; exit 1; }
assert_eq 2 "$(fm_version .orchid/tasks/A.md contract_revision)" 'healthy revision advances contract'
assert_eq 3 "$(fm_version .orchid/tasks/A.md execution_generation)" 'healthy revision advances execution'
grep -F accepted-revision .orchid/journal.md >/dev/null || fail 'accepted revision has its journal reason'
green_case 'the same contract revision publishes with a healthy journal producer'
[ "$FAILS" -eq 0 ]
