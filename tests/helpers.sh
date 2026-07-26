#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHID_BIN="$REPO_ROOT/bin/orchid"
FAILS=0
fail()        { echo "  FAIL: $*"; FAILS=$((FAILS+1)); }
assert_eq()   { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
assert_match(){ echo "$2" | grep -Eq "$1" || fail "$3 (no match '$1')"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"; exit $((FAILS>0))' EXIT
