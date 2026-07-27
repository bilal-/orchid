#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# Background-detection regex: a trailing `&` (optionally followed by
# whitespace) is backgrounding, but `&&` (logical AND / line continuation)
# must NOT false-positive — the `[^&]` (or start-of-line) before the final
# `&` rules out a preceding second `&`.
bg_re='(^|[^&])&[[:space:]]*$'
# Self-check the regex in isolation before trusting it against real files.
if printf 'foo &&\n' | grep -Eq "$bg_re"; then
  fail "INV-01 self-check: 'foo &&' must not match the background regex"
fi
if ! printf 'foo &\n' | grep -Eq "$bg_re"; then
  fail "INV-01 self-check: 'foo &' must match the background regex"
fi

# Tier-1 verbs must not background/detach processes or invoke engine CLIs.
if grep -nE "($bg_re|nohup|setsid|disown)" "$REPO_ROOT"/libexec/*; then
  fail "INV-01: tier-1 verb spawns/detaches a process"
fi
if grep -nE '\b(codex|agy|claude) (exec|-p)\b' "$REPO_ROOT"/libexec/*; then
  fail "INV-01: tier-1 verb invokes an engine CLI"
fi
