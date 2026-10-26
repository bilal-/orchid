#!/usr/bin/env bash
# RED: Application changes, rewritten history and failed comparisons cannot
# qualify as reserved-state progress or equal delivered project trees.
# GREEN: Forward state-only commits preserve an unchanged reviewed candidate.
source "$(dirname "$0")/helpers.sh"
export ORCHID_ROOT="$REPO_ROOT" HOME="$MACHINE_HOME"
source "$REPO_ROOT/lib/graph-runtime.sh"
source "$REPO_ROOT/lib/graph-integration.sh"
mkdir -p "$WORK/repo"
cd_scratch "$WORK/repo" || exit 1
git init -q
mkdir .orchid
printf 'zero\n' > app
printf 'initial\n' > .orchid/state
git add app .orchid/state
git commit -q -m baseline
base="$(git rev-parse HEAD)"
git checkout -q -b candidate
printf 'feature\n' > feature
git add feature
git commit -q -m candidate
candidate="$(git rev-parse HEAD)"
git checkout -q -b integration "$base"
printf 'published state\n' > .orchid/state
git add .orchid/state
git commit -q -m state
state="$(git rev-parse HEAD)"
orchid_graph_state_progress "$PWD" "$base" "$candidate" "$state" || fail 'forward reserved state qualifies'
git checkout -q -b delivered "$state"
git merge -q --no-ff candidate -m delivered || { fail 'state-only three-way merge'; exit 1; }
delivered="$(git rev-parse HEAD)"
orchid_graph_project_equal "$PWD" "$candidate" "$delivered" || fail 'delivered project equals reviewed candidate'
green_case 'forward state-only progress and actual merged project equality both hold'
assert_eq already_integrated "$(orchid_graph_merge_basis "$PWD" "$base" "$candidate" "$delivered")" 'already delivered project preserves its reviewed candidate'
git merge -q --no-ff candidate -m revalidation >/dev/null || fail 'revalidating an integrated candidate is a legitimate no-op merge'
assert_eq "$delivered" "$(git rev-parse HEAD)" 'revalidation does not manufacture an implementation commit'
green_case 'an already integrated equal project reuses the candidate while retaining real merge checks'
git checkout -q -b newer-project "$delivered"
printf 'new application behavior\n' > later-app
git add later-app
git commit -q -m newer-project
rc=0; orchid_graph_merge_basis "$PWD" "$base" "$candidate" "$(git rev-parse HEAD)" > "$WORK/basis" || rc=$?
assert_eq 1 "$rc" 'additional application changes cannot use already-integrated equal-project replay'
red_case 'already integrated candidates still require ordinary rebase when the project differs'


for change in application reserved-prefix mode symlink deletion gitlink; do
  git checkout -q -B "case-$change" "$state" || { fail 'case branch'; exit 1; }
  case "$change" in
    application) printf 'changed\n' > app; git add app ;;
    reserved-prefix) printf 'application file\n' > .orchid-extra; git add .orchid-extra ;;
    mode) chmod 755 app; git update-index --chmod=+x app ;;
    symlink) rm app; ln -s feature app; git add app ;;
    deletion) git rm -q app ;;
    gitlink) git update-index --add --cacheinfo "160000,$candidate,linked" ;;
  esac
  git commit -q -m "$change"
  changed="$(git rev-parse HEAD)"
  rc=0; orchid_graph_state_progress "$PWD" "$base" "$candidate" "$changed" || rc=$?
  assert_eq 1 "$rc" "$change requires normal candidate rebase"
  rc=0; orchid_graph_project_equal "$PWD" "$base" "$changed" || rc=$?
  assert_eq 1 "$rc" "$change is significant project content"
done
red_case 'application content namespace prefixes modes symlinks deletions and gitlinks remain significant'
orchid_graph_state_progress "$PWD" "$base" "$candidate" "$state" || fail 'the original state-only history still qualifies'
green_case 'only the exact reserved state namespace is excluded from project identity'

# An endpoint diff can hide intervening application edits. The merge-base
# topology can then change candidate bytes despite equal endpoint trees.
git checkout -q -B intermediate "$base"
printf 'one\n' > app
git add app
git commit -q -m intermediate
intermediate="$(git rev-parse HEAD)"
git checkout -q -b topology-candidate
printf 'feature\n' > topology-feature
git add topology-feature
git commit -q -m topology-candidate
topology_candidate="$(git rev-parse HEAD)"
git checkout -q -b topology-integration "$intermediate"
printf 'zero\n' > app
printf 'new state\n' > .orchid/state
git add app .orchid/state
git commit -q -m reverted-application
topology_integration="$(git rev-parse HEAD)"
orchid_graph_project_equal "$PWD" "$base" "$topology_integration" || fail 'topology fixture endpoints really match'
rc=0; orchid_graph_state_progress "$PWD" "$base" "$topology_candidate" "$topology_integration" || rc=$?
assert_eq 1 "$rc" 'intervening application changes cannot masquerade as state progress'
git checkout -q -b topology-delivered
git merge -q --no-ff topology-candidate -m topology-delivered || { fail 'topology merge'; exit 1; }
rc=0; orchid_graph_project_equal "$PWD" "$topology_candidate" HEAD || rc=$?
assert_eq 1 "$rc" 'actual merge cannot substitute different project bytes for reviewed candidate'
red_case 'net-restored application history and divergent three-way results refuse the exception'
orchid_graph_project_equal "$PWD" "$candidate" "$delivered" || fail 'the actual equal-project merge remains acceptable'
green_case 'the same delivered-tree check accepts an equal reviewed project'

git checkout -q --orphan rewritten
git rm -rq --cached .
git add app .orchid/state
git commit -q -m rewritten
rewritten="$(git rev-parse HEAD)"
rc=0; orchid_graph_state_progress "$PWD" "$base" "$candidate" "$rewritten" || rc=$?
assert_eq 1 "$rc" 'unrelated history cannot qualify as forward state progress'
rc=0
(
  git() { if [ "${1:-}" = -C ] && [ "${3:-}" = diff ]; then return 77; fi; command git "$@"; }
  orchid_graph_state_progress "$PWD" "$base" "$candidate" "$state"
) || rc=$?
assert_eq 2 "$rc" 'comparison failure is infrastructure refusal rather than project equality'
red_case 'nonancestor histories and failed Git comparison producers never admit the exception'
orchid_graph_state_progress "$PWD" "$base" "$candidate" "$state" || fail 'healthy Git comparison accepts the original forward history'
green_case 'the same ancestry and comparison checks accept healthy state progress'
[ "$FAILS" -eq 0 ]
