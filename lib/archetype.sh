#!/usr/bin/env bash
# lib/archetype.sh -- archetype (plugin.conf kind=archetype) discovery plus
# the meta-contract validator (docs/specs/plugins.md, "Archetype
# meta-contract"). Source AFTER lib/common.sh and lib/manifest.sh (uses
# manifest_get/manifest_validate/_manifest_split_csv from the latter).
#
# INV-05 discipline: nothing in this file (or in libexec/orchid-task's
# archetype-driven `legal()`) ever branches on an archetype's NAME -- every
# decision below reads the manifest's declared `outcome=`/`transitions=`
# data. `feature` and `review` are just two data points on disk, not two
# code paths.

# The kernel's full state set (docs/specs/kernel.md, Task lifecycle) --
# transition endpoints outside this set are rejected by archetype_validate.
# Space-padded for a substring-safe membership test.
_ARCHETYPE_KERNEL_STATES=" pending implementing testing reviewing arbitrating merging rework done blocked "

_archetype_known_state() {  # state -> 0 iff a real kernel state
  case "$_ARCHETYPE_KERNEL_STATES" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# archetype_dir <name> -- resolves an archetype's plugin directory. Search
# order (highest to lowest precedence), mirroring lib/resolver.sh's
# resolve_engine_exe for engines:
#   1. $ORCHID_ARCHETYPES_DIR -- a resolver-only TEST HOOK (mirrors
#      ORCHID_ENGINES_DIR) that real discovery (_plugins_roots/
#      _plugins_discover, libexec/orchid-plugins) never walks -- lets tests
#      plant an archetype without disturbing the real search roots below.
#   2. $ORCHID_PLUGIN_PATH entries (colon-delimited), each laid out
#      <entry>/archetypes/<name> -- same real-root convention as engines.
#   3. $HOME/.orchid/plugins/archetypes/<name>
#   4. $ORCHID_ROOT/plugins/archetypes/<name>
# Repo-local archetypes are deliberately NOT searched in m2: data-only, but
# workflow-shaping (a hostile `transitions=` could still misroute a task) --
# ledgered for m3's trust treatment rather than silently accepted here.
# A duplicate id resolved from two DIFFERENT roots is an INV-10 error:
# printed to stderr, nonzero return, nothing echoed on stdout.
archetype_dir() {
  local name="$1" d found="" p
  local -a search_dirs=()
  search_dirs+=("${ORCHID_ARCHETYPES_DIR:-}")
  if [ -n "${ORCHID_PLUGIN_PATH:-}" ]; then
    local IFS=':' parts=()
    read -ra parts <<< "$ORCHID_PLUGIN_PATH"
    for p in "${parts[@]}"; do
      [ -n "$p" ] && search_dirs+=("$p/archetypes")
    done
  fi
  search_dirs+=("$HOME/.orchid/plugins/archetypes" "${ORCHID_ROOT:-}/plugins/archetypes")
  for d in "${search_dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -f "$d/$name/plugin.conf" ]; then
      [ -z "$found" ] || {
        echo "orchid: duplicate archetype '$name' ($found vs $d/$name) (INV-10)" >&2
        return 1
      }
      found="$d/$name"
    fi
  done
  [ -n "$found" ] || return 1
  echo "$found"
}

# archetype_transitions <name> -- prints the archetype's declared `from:to`
# pairs, one per line, straight off its manifest's `transitions=` (comma
# list; reuses manifest.sh's own trimming split so a stray space after a
# comma behaves identically to every other comma-list key). Empty/absent ->
# no lines, nonzero from archetype_dir propagates.
archetype_transitions() {
  local name="$1" dir raw
  dir="$(archetype_dir "$name")" || return 1
  raw="$(manifest_get "$dir" transitions)"
  [ -n "$raw" ] || return 0
  _manifest_split_csv "$raw"
}

# archetype_outcome <name> -- `code` or `report`, read from the manifest's
# `outcome=` key (missing key, or an unresolvable archetype, -> `code`: the
# safe default that keeps every existing kernel gate switched ON rather than
# silently exempting a task from them).
archetype_outcome() {
  local name="$1" dir out
  dir="$(archetype_dir "$name" 2>/dev/null)" || { echo code; return 0; }
  out="$(manifest_get "$dir" outcome code)"
  case "$out" in
    code|report) echo "$out" ;;
    *) echo code ;;
  esac
}

# archetype_validate <name> -- exit 13 unless ALL of the meta-contract
# invariants (docs/specs/plugins.md, "Archetype meta-contract") hold; exit 0
# (printing an `ok:` line) otherwise. Every FAIL line is written to stderr so
# an invalid archetype is diagnosable without a second command.
#
#   - the archetype resolves to exactly one plugin dir (archetype_dir) and
#     its manifest passes manifest_validate, with kind=archetype
#   - outcome in {code, report}
#   - at least one transition is declared
#   - every transition's `from` AND `to` name a real kernel state
#   - outcome=code implies the declared set contains testing:reviewing AND
#     reviewing:arbitrating AND merging:done (no unreviewed/unverified path
#     to a code-merging terminal)
#   - outcome=report implies NO transition mentions `merging` on either side
#     (a report archetype can never reach the merge verb's state)
#   - at least one transition ends in `done` (a reachable terminal)
archetype_validate() {
  local name="$1" dir

  if ! dir="$(archetype_dir "$name")"; then
    echo "FAIL: archetype '$name': not found (or a duplicate id) on the archetype search path" >&2
    return 13
  fi

  local mv_out
  if ! mv_out="$(manifest_validate "$dir" 2>&1)"; then
    echo "$mv_out" >&2
    echo "FAIL: archetype '$name': manifest_validate failed" >&2
    return 13
  fi

  local kind; kind="$(manifest_get "$dir" kind)"
  if [ "$kind" != archetype ]; then
    echo "FAIL: archetype '$name': manifest kind '$kind' is not 'archetype'" >&2
    return 13
  fi

  local outcome; outcome="$(manifest_get "$dir" outcome code)"
  case "$outcome" in
    code|report) ;;
    *) echo "FAIL: archetype '$name': outcome '$outcome' is not one of code|report" >&2; return 13 ;;
  esac

  local transitions; transitions="$(archetype_transitions "$name")"
  if [ -z "$transitions" ]; then
    echo "FAIL: archetype '$name': no transitions declared" >&2
    return 13
  fi

  local line from to
  local has_testing_reviewing=0 has_reviewing_arbitrating=0 has_merging_done=0
  local mentions_merging=0 has_done_terminal=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    from="${line%%:*}"; to="${line#*:}"
    if ! _archetype_known_state "$from"; then
      echo "FAIL: archetype '$name': transition '$line' names unknown state '$from'" >&2
      return 13
    fi
    if ! _archetype_known_state "$to"; then
      echo "FAIL: archetype '$name': transition '$line' names unknown state '$to'" >&2
      return 13
    fi
    [ "$line" = "testing:reviewing" ] && has_testing_reviewing=1
    [ "$line" = "reviewing:arbitrating" ] && has_reviewing_arbitrating=1
    [ "$line" = "merging:done" ] && has_merging_done=1
    { [ "$from" = merging ] || [ "$to" = merging ]; } && mentions_merging=1
    [ "$to" = "done" ] && has_done_terminal=1
  done <<< "$transitions"

  if [ "$outcome" = code ]; then
    if [ "$has_testing_reviewing" -ne 1 ] || [ "$has_reviewing_arbitrating" -ne 1 ] || [ "$has_merging_done" -ne 1 ]; then
      echo "FAIL: archetype '$name': outcome=code requires testing:reviewing, reviewing:arbitrating, and merging:done in its transitions" >&2
      return 13
    fi
  fi

  if [ "$outcome" = report ] && [ "$mentions_merging" -eq 1 ]; then
    echo "FAIL: archetype '$name': outcome=report may never mention 'merging' in a transition" >&2
    return 13
  fi

  if [ "$has_done_terminal" -ne 1 ]; then
    echo "FAIL: archetype '$name': no transition reaches 'done' (unreachable terminal)" >&2
    return 13
  fi

  echo "ok: archetype $name"
  return 0
}
