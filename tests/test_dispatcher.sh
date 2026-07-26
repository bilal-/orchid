#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
out="$("$ORCHID_BIN" help)"
assert_match "usage: orchid" "$out" "help prints usage"
rc=0; "$ORCHID_BIN" no-such-verb 2>/dev/null || rc=$?
assert_eq "2" "$rc" "unknown verb exits 2"
