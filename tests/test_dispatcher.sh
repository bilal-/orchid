#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
out="$("$ORCHID_BIN" help)"
assert_match "usage: orchid" "$out" "help prints usage"
rc=0; "$ORCHID_BIN" no-such-verb 2>/dev/null || rc=$?
assert_eq "2" "$rc" "unknown verb exits 2"

# `orchid version` (libexec/orchid-version), run through the dispatcher --
# exits 0 and prints a line naming the running kernel's ORCHID_VERSION
# (lib/common.sh), currently the prerelease 1.0.0-beta.1. Matched with the
# suffix attached: a bare `1\.0\.0` pattern would also match `1.0.0` itself,
# so it could not tell the shipped prerelease from an unearned 1.0.0.
rc=0; out="$("$ORCHID_BIN" version)" || rc=$?
assert_eq "0" "$rc" "version exits 0"
assert_match "1\.0\.0-beta\.1" "$out" "version prints a line containing ORCHID_VERSION"
