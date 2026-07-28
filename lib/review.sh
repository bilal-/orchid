#!/usr/bin/env bash
# Dual-review routing (v1-m2 Task 3) — see docs/specs/kernel.md's
# "Independence" section for the policy this encodes: `risk_tier` drives
# review ROUTING and independence requirements; `low` wants a single
# engine-independent reviewer (falling back to a labeled session-independent
# one when no other engine is available); `medium`/`high` want two reviewer
# slots (worktree-capable for depth + engine-independent for diversity).
#
# Sourced after lib/resolver.sh, lib/capsuite.sh, lib/ledger.sh (per those
# files' own sourcing-order headers). Callers must source, in this order:
# lib/common.sh, lib/frontmatter.sh, lib/manifest.sh, lib/roles.sh, lib/
# resolver.sh, lib/envelope.sh, lib/capsuite.sh, lib/ledger.sh, then this
# file — exactly the order libexec/orchid-jobs already sources everything
# else in.
#
# INV-05: every decision below is config-shaped (`role.reviewer`'s chain,
# the `review.<tier>` chain) or capability-shaped (manifest capabilities,
# role_eligibility_reason) — never a branch on a specific engine's name. The
# tier default engine names (`agy`, `codex-review,agy`) are config DEFAULT
# VALUES passed to config_get, not a case table keyed on engine identity.

# review_required_count <risk_tier> -- low -> 1; medium|high -> 2; anything
# else (unknown/empty) -> 2, fail-safe (never under-review an unrecognized
# tier).
review_required_count() {
  case "$1" in
    low) echo 1 ;;
    *) echo 2 ;;
  esac
}

# review_implementer_engine <repo> <task> -- the task's recorded
# `implementer_engine_id` frontmatter if set (kernel-derived, single-writer:
# `task advance implementing->testing` is the only writer of that field),
# else `resolve_role <repo> implementer` (first-of-chain) as the baseline
# for a task that hasn't reached testing yet, or was hand-walked by a
# fixture without a planted implement envelope.
review_implementer_engine() {
  local repo="$1" task="$2" tf v
  tf="$(orchid_state "$repo")/tasks/$task.md"
  v="$(fm_get "$tf" implementer_engine_id 2>/dev/null || true)"
  [ -n "$v" ] || v="$(resolve_role "$repo" implementer)"
  echo "$v"
}

# _review_tier_key <risk_tier> -- normalizes to low|medium|high for the
# review.<tier> config lookup; any unrecognized value reads as high (same
# fail-safe posture as review_required_count).
_review_tier_key() {
  case "$1" in
    low) echo low ;;
    medium) echo medium ;;
    *) echo high ;;
  esac
}

# _review_tier_chain <repo> <risk_tier> -- the review.<tier> config chain
# (comma-separated engine names), config default per kernel.md: low -> agy;
# medium/high -> codex-review,agy (worktree-capable depth + engine-
# independent diversity).
_review_tier_chain() {
  local repo="$1" key def
  key="$(_review_tier_key "$2")"
  case "$key" in
    low) def=agy ;;
    *) def="codex-review,agy" ;;
  esac
  config_get "$repo" "review.$key" "$def"
}

# _review_worktree_capable <plugin-dir> -- exit 0 iff the manifest declares
# workspace_read ("worktree-capable": able to inspect the full checkout, not
# just the diff). Built as the space-bounded "have" string idiom (lib/
# roles.sh, lib/capsuite.sh) rather than `manifest_capabilities | grep -q`,
# to sidestep the SIGPIPE-under-pipefail race those files already document.
_review_worktree_capable() {
  local dir="$1" atom have=" "
  while IFS= read -r atom; do
    [ -n "$atom" ] && have="$have$atom "
  done < <(manifest_capabilities "$dir" 2>/dev/null)
  case "$have" in *" workspace_read "*) return 0 ;; esac
  return 1
}

# _review_candidate_ok <repo> <engine> -- discovered + reviewer-role-
# eligible + ledger-available. Shared by both slots' candidate walks below.
_review_candidate_ok() {
  local repo="$1" engine="$2" dir
  dir="$(resolve_engine_dir "$engine" 2>/dev/null)" || return 1
  role_eligibility_reason reviewer "$dir" >/dev/null 2>&1 || return 1
  ledger_available "$repo" "$engine" || return 1
  return 0
}

# review_routing <repo> <task> -- prints the routing table for this task's
# current risk_tier, one line per required slot: <slot>\t<engine>\t
# <engine-independent|session-independent>.
review_routing() {
  local repo="$1" task="$2" tf risk_tier count impl_engine tier_chain
  tf="$(orchid_state "$repo")/tasks/$task.md"
  risk_tier="$(fm_get "$tf" risk_tier 2>/dev/null || true)"
  [ -n "$risk_tier" ] || risk_tier=low
  count="$(review_required_count "$risk_tier")"
  impl_engine="$(review_implementer_engine "$repo" "$task")"
  tier_chain="$(_review_tier_chain "$repo" "$risk_tier")"

  # Slot 1 (all tiers): the first entry of resolve_role_chain(reviewer) ++
  # the tier chain that differs from the implementer's engine and is
  # discovered + eligible + available -> engine-independent. No such entry
  # -> the implementer's own engine, labeled session-independent (never
  # silently -- the label itself is the record).
  local e slot1_engine="" slot1_label=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$e" != "$impl_engine" ] || continue
    _review_candidate_ok "$repo" "$e" || continue
    slot1_engine="$e"; slot1_label="engine-independent"
    break
  done < <(resolve_role_chain "$repo" reviewer; printf '%s\n' "$tier_chain" | tr ',' '\n')
  if [ -z "$slot1_engine" ]; then
    slot1_engine="$impl_engine"; slot1_label="session-independent"
  fi
  printf '1\t%s\t%s\n' "$slot1_engine" "$slot1_label"

  [ "$count" -ge 2 ] || return 0

  # Slot 2 (medium/high only): the next DISTINCT available engine from the
  # tier chain, worktree-capable entries tried first (depth), independence
  # labeled the same way as slot 1. Fewer distinct engines than slots ->
  # repeat slot 1's engine, forced session-independent (a single engine
  # reviewing twice is degraded independence regardless of its relation to
  # the implementer) -- never zero slots.
  local dir slot2_engine=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$e" != "$slot1_engine" ] || continue
    dir="$(resolve_engine_dir "$e" 2>/dev/null)" || continue
    _review_worktree_capable "$dir" || continue
    _review_candidate_ok "$repo" "$e" || continue
    slot2_engine="$e"; break
  done < <(printf '%s\n' "$tier_chain" | tr ',' '\n')
  if [ -z "$slot2_engine" ]; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      [ "$e" != "$slot1_engine" ] || continue
      dir="$(resolve_engine_dir "$e" 2>/dev/null)" || continue
      _review_worktree_capable "$dir" && continue   # already tried above
      _review_candidate_ok "$repo" "$e" || continue
      slot2_engine="$e"; break
    done < <(printf '%s\n' "$tier_chain" | tr ',' '\n')
  fi
  local slot2_label
  if [ -n "$slot2_engine" ]; then
    if [ "$slot2_engine" = "$impl_engine" ]; then slot2_label="session-independent"; else slot2_label="engine-independent"; fi
  else
    slot2_engine="$slot1_engine"; slot2_label="session-independent"
  fi
  printf '2\t%s\t%s\n' "$slot2_engine" "$slot2_label"
}
