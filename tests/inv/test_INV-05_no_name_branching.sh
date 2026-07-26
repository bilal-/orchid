#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# Kernel never branches on plugin names: engine literals may appear only in
# defaults inside config lookups, never in conditionals.
if grep -nE 'if .*(codex|agy|claude)|case .*(codex|agy|claude)' "$REPO_ROOT"/libexec/* "$REPO_ROOT"/lib/*.sh \
   | grep -v 'config_get.*role\.'; then
  fail "INV-05: kernel branches on an engine name"
fi
