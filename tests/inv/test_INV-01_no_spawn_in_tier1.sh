#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# Tier-1 verbs must not background/detach processes or invoke engine CLIs.
if grep -nE '(&[[:space:]]*$|nohup|setsid|disown)' "$REPO_ROOT"/libexec/*; then
  fail "INV-01: tier-1 verb spawns/detaches a process"
fi
if grep -nE '\b(codex|agy|claude) (exec|-p)\b' "$REPO_ROOT"/libexec/*; then
  fail "INV-01: tier-1 verb invokes an engine CLI"
fi
