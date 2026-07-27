#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
if grep -rnE 'plugins/engines|orchid-launch' "$REPO_ROOT"/libexec/ "$REPO_ROOT"/lib/ \
   | grep -vE 'resolve_engine_exe|#|resolver\.sh'; then
  fail "INV-06: engine spawning referenced outside runners/"
fi
grep -q '</dev/null' "$REPO_ROOT/runners/orchid-launch" || fail "INV-06: launcher must close stdin"
