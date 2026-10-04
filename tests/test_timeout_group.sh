#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
# RED: a TERM-resistant command and descendant must stop by deadline + grace.
# GREEN: normal deadline termination and early successful completion still work.
cat > "$WORK/resistant" <<'ENGINE'
#!/bin/bash
[ "${3:-ignore}" != ignore ] || trap '' TERM
printf '%s\n' "$$" > "$1"
/bin/bash -c 'trap "" TERM; printf "%s\n" "$$" > "$1"; while :; do sleep .1; done' bash "$2" &
wait
ENGINE
chmod +x "$WORK/resistant"
# Isolate the helper itself so the baseline hang can be observed and cleaned.
(
  group_rc=0
  with_timeout 1 "$WORK/resistant" "$WORK/leader" "$WORK/descendant" || group_rc=$?
  printf '%s\n' "$group_rc" > "$WORK/result"
) > "$WORK/timeout.log" 2>&1 & helper_pid=$!
for ((i=0;i<50;i++)); do [ ! -f "$WORK/descendant" ] || break; sleep .1; done
[ -f "$WORK/leader" ] && [ -f "$WORK/descendant" ] || fail 'resistant fixture starts both owned processes'
leader="$(cat "$WORK/leader")"; descendant="$(cat "$WORK/descendant")"
leader_group="$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d ' ')"
for ((i=0;i<40;i++)); do [ ! -f "$WORK/result" ] || break; sleep .1; done
if [ ! -f "$WORK/result" ]; then
  fail 'TERM-resistant group exceeds deadline plus one-second grace'
  kill -KILL -- "-$leader_group" 2>/dev/null || true
fi
wait "$helper_pid" 2>/dev/null || true
[ -f "$WORK/result" ] || fail 'deadline helper returns after resistant group cleanup'
assert_eq 124 "$(cat "$WORK/result" 2>/dev/null)" 'resistant timeout reports the deadline sentinel'
kill -0 "$leader" 2>/dev/null && fail 'resistant leader remains alive after timeout'
# A killed descendant may briefly be a zombie under init. It must not be running.
state="$(ps -o stat= -p "$descendant" 2>/dev/null | tr -d ' ')"
case "$state" in ''|Z*) ;; *) fail "resistant descendant remains running: $state" ;; esac
red_case 'TERM-resistant owned command group cannot exceed deadline plus bounded grace'
# The group anchor must also survive a cooperative immediate child dying while
# its own descendant ignores TERM. Otherwise that descendant can be orphaned.
rm -f "$WORK/leader" "$WORK/descendant" "$WORK/result"
(
  group_rc=0
  with_timeout 1 "$WORK/resistant" "$WORK/leader" "$WORK/descendant" cooperative || group_rc=$?
  printf '%s\n' "$group_rc" > "$WORK/result"
) > "$WORK/timeout-descendant.log" 2>&1 & helper_pid=$!
for ((i=0;i<50;i++)); do [ ! -f "$WORK/descendant" ] || break; command sleep .1; done
leader="$(cat "$WORK/leader")"; descendant="$(cat "$WORK/descendant")"
wait "$helper_pid" 2>/dev/null || true
state="$(ps -o stat= -p "$descendant" 2>/dev/null | tr -d ' ')"
case "$state" in
  ''|Z*) ;;
  *) fail "descendant survived after its cooperative parent exited: $state"
     kill -KILL "$descendant" 2>/dev/null || true ;;
esac
assert_eq 124 "$(cat "$WORK/result")" 'descendant cleanup still reports deadline'
red_case 'deadline cleanup reaches resistant descendant even after cooperative command exits'
normal_rc=0; start="$(date +%s)"
with_timeout 1 sleep 30 || normal_rc=$?
assert_eq 124 "$normal_rc" 'normal deadline reports the deadline sentinel'
[ "$(( $(date +%s)-start ))" -le 3 ] || fail 'normal deadline returns promptly'
green_case 'normal signal-sensitive command still terminates at deadline'
# Trace the watcher's original process group; job control output is not parsed.
# Override only sleep in this fixture to capture the actual group leader before
# calling the platform sleep. The early command waits causally for that marker.
sleep() {
  if [ "$1" = 4 ]; then
    /bin/bash -c 'ps -o pgid= -p "$PPID" | tr -d " "' > "$WORK/watcher-group"
  fi
  command sleep "$@"
}
_early_success() {
  while [ ! -s "$WORK/watcher-group" ]; do command sleep .05; done
  return 0
}
early_rc=0; with_timeout 4 _early_success || early_rc=$?
assert_eq 0 "$early_rc" 'early successful command retains its own exit status'
watcher_group="$(cat "$WORK/watcher-group")"
case "$watcher_group" in ''|*[!0-9]*) fail 'captured original watcher process group' ;; esac
remaining="$(ps -axo pgid=,stat= | awk -v group="$watcher_group" '$1==group && $2 !~ /^Z/ { print }')"
assert_eq '' "$remaining" 'early success cancels watcher and its deadline sleep'
green_case 'early success leaves no live deadline watcher or delayed signal'
early_rc=0; with_timeout 4 /bin/bash -c 'exit 7' || early_rc=$?
assert_eq 7 "$early_rc" 'early failure retains its own exit status rather than becoming timeout'
green_case 'early nonzero command retains its original status'
exit "$FAILS"
