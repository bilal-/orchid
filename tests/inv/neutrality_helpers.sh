#!/usr/bin/env bash
# Test-only source inventory shared by INV-05 and INV-14. Native session
# adapters are Tier2 host integration, not engine or notification policy.
# Keep the exemption exact; newly added kernel sources remain in the scan.
inv_kernel_source_files() {
  local root="$1" f rel
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="${f#"$root"/}"
    case "$rel" in
      lib/frontend.sh|runners/orchid-setup) continue ;;
      bin/*|lib/*.sh|libexec/*|runners/*) printf '%s\n' "$f" ;;
    esac
  done < <(find "$root/bin" "$root/lib" "$root/libexec" "$root/runners" \
    \( -type f -o -type l \) -print | LC_ALL=C sort)
}

# A kernel cannot import the host adapter, call its API, or dispatch setup.
# The dedicated public bridge may perform only its exact Tier2 delegation.
# Provider-name branch checks are separate and still scan that bridge.
inv_native_host_boundary_hits() {
  local root="$1" f rel body refs
  while IFS= read -r f; do
    rel="${f#"$root"/}"
    body="$(grep -nE '.' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    refs="$(printf '%s\n' "$body" | grep -E \
      'frontend\.sh|frontend_[A-Za-z0-9_]+|orchid-setup|(^|[[:space:]])(load_lib|source)[[:space:]].*frontend|(^[0-9]+:|[;|&()])[[:space:]]*(exec[[:space:]]+)?("[^"]*/(bin/)?orchid"|"\$ORCHID_BIN"|[^[:space:];|&()"]*orchid)[[:space:]]+setup([[:space:]]|$)' || true)"
    if [ "$rel" = libexec/orchid-setup ]; then
      refs="$(printf '%s\n' "$refs" | grep -vE \
        '^[0-9]+:exec /bin/bash -p "\$ORCHID_ROOT/runners/orchid-setup" "\$@"$' || true)"
    fi
    [ -z "$refs" ] || printf '%s: %s\n' "$f" "$refs"
  done < <(inv_kernel_source_files "$root")
}

inv_assert_native_host_boundary() {
  local root="$1" gate="$2" hits probe sources
  hits="$(inv_native_host_boundary_hits "$root")"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    fail "$gate: kernel imports or invokes a native host adapter outside the dedicated setup bridge"
  fi

  probe="$WORK/$gate-native-boundary"
  mkdir -p "$probe/bin" "$probe/lib/nested" "$probe/libexec" "$probe/runners"
  printf '#!/bin/bash\nprintf neutral\\n\n' > "$probe/bin/orchid"
  printf 'config_get role.implementer codex\n' > "$probe/lib/nested/neutral.sh"
  printf 'jq -n '\''{"next":["orchid setup --help"]}'\''\n' >> "$probe/lib/nested/neutral.sh"
  printf 'case "$host" in codex) frontend_context ;; esac\n' > "$probe/lib/frontend.sh"
  printf 'case "$host" in claude) frontend_hook claude ;; esac\n' > "$probe/runners/orchid-setup"
  printf 'exec /bin/bash -p "$ORCHID_ROOT/runners/orchid-setup" "$@"\n' > "$probe/libexec/orchid-setup"
  sources="$(inv_kernel_source_files "$probe")"
  grep -Fx "$probe/lib/nested/neutral.sh" <<< "$sources" >/dev/null \
    || fail "$gate self-check: nested kernel source was omitted from shared inventory"
  if grep -Fx "$probe/lib/frontend.sh" <<< "$sources" >/dev/null \
    || grep -Fx "$probe/runners/orchid-setup" <<< "$sources" >/dev/null; then
    fail "$gate self-check: exact Tier2 adapter inventory leaked into the kernel scan"
  fi
  hits="$(inv_native_host_boundary_hits "$probe")"
  [ -z "$hits" ] || fail "$gate self-check: neutral kernel and exact setup bridge must remain legal"
  green_case "$gate shared inventory accepts neutral kernel code and its exact Tier2 setup bridge"

  printf 'source "$ORCHID_ROOT/lib/frontend.sh"\n' > "$probe/lib/nested/import.sh"
  printf 'frontend_context\n' > "$probe/libexec/orchid-injected"
  printf 'exec /bin/bash -p "$ORCHID_ROOT/runners/orchid-setup" --frontend codex\n' > "$probe/runners/injected"
  printf '"$ORCHID_ROOT/bin/orchid" setup --frontend codex\n' >> "$probe/bin/orchid"
  printf 'source "$ORCHID_ROOT/lib/frontend.sh"\n' >> "$probe/libexec/orchid-setup"
  hits="$(inv_native_host_boundary_hits "$probe")"
  local path
  for path in lib/nested/import.sh libexec/orchid-injected runners/injected bin/orchid libexec/orchid-setup; do
    grep -F "$probe/$path:" <<< "$hits" >/dev/null \
      || fail "$gate self-check: native adapter boundary failed to reject $path"
  done
  red_case "$gate shared boundary rejects injected adapter imports, API calls, public dispatch and extra setup-bridge effects"
}
