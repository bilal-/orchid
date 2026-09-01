#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# RED: a synthetic tier-1 file naming `plugins/engines/...` outside the
#      allowed sites must be FOUND by the same pipeline this gate scans with.
#      The scan passes on an empty match, which is also what a broken pattern
#      or a moved source root produces -- so without the probe below, a kernel
#      that spawned engines from every verb would keep this gate green.
# GREEN: a `resolve_engine_exe` line and a comment mentioning the same path
#      must NOT survive the exclusion filter, since those are the legal ways
#      the string appears; otherwise the RED case would only prove the
#      pipeline matches everything.
SPAWN_RE='plugins/engines|orchid-launch'
SPAWN_EXCLUDE='resolve_engine_exe|#|resolver\.sh'
probe_bad="$WORK/inv06-probe-bad"; mkdir -p "$probe_bad"
printf 'exec "$root/plugins/engines/some/run"\n' > "$probe_bad/spawner.sh"
# Captured rather than piped into `grep -q`: pipefail plus -q's early exit
# turns a found match into a 141 and the probe would report the opposite of
# what it saw (the scan below uses no -q for the same reason).
probe_hit="$(grep -rnE "$SPAWN_RE" "$probe_bad" | grep -vE "$SPAWN_EXCLUDE" || true)"
[ -n "$probe_hit" ] \
  || fail "INV-06 self-check: the scan does not match a direct plugins/engines spawn, so it would pass over a tier-1 verb that spawns an engine"
probe_ok="$WORK/inv06-probe-ok"; mkdir -p "$probe_ok"
printf '%s\n' \
  '# plugins/engines is documented here' \
  'resolve_engine_exe() { printf "%s" "$root/plugins/engines/$1/run"; }' \
  > "$probe_ok/legal.sh"
probe_legal_hit="$(grep -rnE "$SPAWN_RE" "$probe_ok" | grep -vE "$SPAWN_EXCLUDE" || true)"
[ -z "$probe_legal_hit" ] \
  || fail "INV-06 self-check: a comment and a resolve_engine_exe call must stay legal -- those exemptions are what let the kernel document and resolve engines at all"
red_case "INV-06's scan found a direct plugins/engines spawn in a synthetic tier-1 file"
green_case "the same scan exempted a comment and a resolve_engine_exe call -- the legal ways the string appears -- so the hit above is detection rather than a pipeline that flags every mention"

if grep -rnE "$SPAWN_RE" "$REPO_ROOT"/libexec/ "$REPO_ROOT"/lib/ \
   | grep -vE "$SPAWN_EXCLUDE"; then
  fail "INV-06: engine spawning referenced outside runners/"
fi
grep -q '</dev/null' "$REPO_ROOT/runners/orchid-launch" || fail "INV-06: launcher must close stdin"
