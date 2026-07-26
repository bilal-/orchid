#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
source "$REPO_ROOT/lib/common.sh"

# Stub: full INV-02 (epoch fencing across kernel operations) lands in Task 5.
# For now, just assert the epoch_require primitive this invariant depends on exists.
type epoch_require >/dev/null 2>&1 || fail "epoch_require helper missing (INV-02 depends on it)"
type epoch_current >/dev/null 2>&1 || fail "epoch_current helper missing (INV-02 depends on it)"
