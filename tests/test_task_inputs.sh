#!/usr/bin/env bash
# RED: Non-task identifiers cannot reach public task-file consumers.
# GREEN: The shared flat namespace accepts ordinary task identifiers.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m baseline
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create valid_1-A 'Valid task' >/dev/null || { fail 'create valid task'; exit 1; }
before="$(git hash-object .orchid/tasks/valid_1-A.md)"
for id in 'two words' 'name.md' ''; do
  if orchid_task_file "$WORK" "$id" > "$WORK/invalid-path.out" 2>&1; then fail 'shared task path rejects invalid identifier'; fi
  for action in create set show verify merge jobs; do
    rc=0
    case "$action" in
      create) "$ORCHID_BIN" task create "$id" Invalid > "$WORK/refusal.out" 2>&1 || rc=$? ;;
      set) "$ORCHID_BIN" task set "$id" title Changed > "$WORK/refusal.out" 2>&1 || rc=$? ;;
      show) "$ORCHID_BIN" task show "$id" > "$WORK/refusal.out" 2>&1 || rc=$? ;;
      verify) "$ORCHID_BIN" verify "$id" > "$WORK/refusal.out" 2>&1 || rc=$? ;;
      merge) "$ORCHID_BIN" merge "$id" > "$WORK/refusal.out" 2>&1 || rc=$? ;;
      jobs) "$ORCHID_BIN" jobs prepare "$id" reviewer review > "$WORK/refusal.out" 2>&1 || rc=$? ;;
    esac
    [ "$rc" -ne 0 ] || fail "$action refuses invalid identifier"
  done
done
assert_eq "$before" "$(git hash-object .orchid/tasks/valid_1-A.md)" 'refused identifiers leave existing task untouched'
count=0
for file in .orchid/tasks/*.md; do [ ! -f "$file" ] || count=$((count + 1)); done
assert_eq 1 "$count" 'refused creation leaves no partial task'
red_case 'invalid identifiers are refused by public task-file consumers'
assert_eq "$WORK/.orchid/tasks/valid_1-A.md" "$(orchid_task_file "$WORK" valid_1-A)" 'shared owner resolves a valid task'
"$ORCHID_BIN" task set valid_1-A title Updated >/dev/null || { fail 'update valid task'; exit 1; }
"$ORCHID_BIN" task show valid_1-A > "$WORK/valid.out" || { fail 'show valid task'; exit 1; }
assert_match Updated "$(cat "$WORK/valid.out")" 'valid task remains readable and writable'
green_case 'ordinary flat task identifiers retain public read and write behavior'
