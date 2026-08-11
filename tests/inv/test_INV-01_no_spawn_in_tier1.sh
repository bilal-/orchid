#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# Background-detection regex: a trailing `&` (optionally followed by
# whitespace) is backgrounding, but `&&` (logical AND / line continuation)
# must NOT false-positive — the `[^&]` (or start-of-line) before the final
# `&` rules out a preceding second `&`.
bg_re='(^|[^&])&[[:space:]]*$'
# RED: `foo &` -- a real backgrounding line, fed to this gate's own detector
#      below, which must flag it. A regex that stopped matching it would let
#      a tier-1 verb spawn a process while this file kept printing a pass,
#      which is the whole failure INV-01 exists to catch.
# GREEN: `foo &&` -- a logical AND, which the same detector must NOT flag, so
#      the RED case above is evidence of detection rather than of a matcher
#      that says yes to everything.
# Self-check the regex in isolation before trusting it against real files.
if printf 'foo &&\n' | grep -Eq "$bg_re"; then
  fail "INV-01 self-check: 'foo &&' must not match the background regex"
fi
if ! printf 'foo &\n' | grep -Eq "$bg_re"; then
  fail "INV-01 self-check: 'foo &' must match the background regex"
fi
red_case "INV-01's background detector fired on a real trailing '&'"
green_case "the same detector left 'foo &&' -- a logical AND -- alone, so the RED case above is detection rather than a pattern that flags every line"

# Tier-1 verbs must not background/detach processes or invoke engine CLIs.
# Scope limitation: these two greps only scan libexec/* (the tier-1 verb
# dispatchers themselves) — lib/*.sh helper functions (lock_acquire,
# config_get, etc.) are shared library code invoked BY tier-1 verbs, not
# verbs in their own right, so they are intentionally out of scope here. If
# a helper ever backgrounded/detached internally, this check would only
# catch it indirectly (via a libexec/* caller that itself matches one of
# these patterns) — a helper that hides it behind its own abstraction would
# slip through. Known v0 gap; tracked, not closed by this test.
if grep -nE "($bg_re|nohup|setsid|disown)" "$REPO_ROOT"/libexec/*; then
  fail "INV-01: tier-1 verb spawns/detaches a process"
fi
if grep -nE '\b(codex|agy|claude) (exec|-p)\b' "$REPO_ROOT"/libexec/*; then
  fail "INV-01: tier-1 verb invokes an engine CLI"
fi
