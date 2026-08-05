#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
source "$REPO_ROOT/lib/common.sh"; source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/manifest.sh"; source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"; source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/capsuite.sh"; source "$REPO_ROOT/lib/ledger.sh"
source "$REPO_ROOT/lib/review.sh"
export ORCHID_ROOT="$REPO_ROOT"

# INV-14: no kernel source branches on any DISCOVERED engine identifier.
#
# INV-05 already asserts this for three hardcoded names in two directories.
# That check cannot notice a fourth engine shipping tomorrow, or a branch
# added to `bin/` or `runners/`. This one discovers the identifier set from
# the plugin tree itself -- every kind=engine and kind=notify directory name
# AND every manifest `id=` (qualified and bare) -- and scans all four kernel
# source roots against it. Add an engine, and it is covered automatically.
#
# Scope note: archetype names are deliberately NOT in the identifier set.
# `review` is simultaneously a shipped archetype's directory name and the
# kernel's own operation name (`orchid jobs prepare <task> reviewer review`),
# so scanning for it would flag every legitimate branch on an OPERATION.
# lib/archetype.sh's own header carries the archetype half of this rule, and
# tests/test_drive_hooks_archetypes.sh proves it behaviourally by driving a
# custom archetype nobody wrote code for.

# ===========================================================================
# 1 -- discover the identifier set.
# ===========================================================================
identifiers=""
add_id() {
  local v="$1"
  [ -n "$v" ] || return 0
  case " $identifiers " in
    *" $v "*) return 0 ;;
  esac
  identifiers="$identifiers $v"
}
for d in "$REPO_ROOT"/plugins/engines/*/ "$REPO_ROOT"/plugins/notify/*/; do
  [ -d "$d" ] || continue
  dir="${d%/}"
  add_id "$(basename "$dir")"
  qid="$(manifest_get "$dir" id)"
  add_id "$qid"
  add_id "${qid#*/}"
done
identifiers="${identifiers# }"
[ -n "$identifiers" ] || fail "INV-14: no engine identifiers discovered — the plugin tree moved, or discovery broke"

id_count=0
for _i in $identifiers; do id_count=$((id_count + 1)); done
[ "$id_count" -ge 5 ] || fail "INV-14: only $id_count identifiers discovered; the shipped adapter set is larger than that"

# ===========================================================================
# 2 -- scan bin, lib, libexec and runners for a CONDITIONAL use of any of
# them. Three shapes cover every way shell branches on a literal:
#
#   a. an if/elif/while/until/case keyword line naming it
#   b. a comparison against it (`= name`, `== name`, `!= name`) -- note the
#      REQUIRED whitespace before `=`, which is exactly what distinguishes a
#      comparison from an assignment (`v=codex,claude`, a config default
#      table, is data and stays legal)
#   c. a case-pattern arm ending in `name)`
#
# Comment lines are excluded (this codebase documents engine behaviour
# extensively and must be able to keep doing so), as is any line calling
# `config_get` -- a config DEFAULT VALUE is data passed to a lookup, the same
# exemption INV-05 already makes.
# ===========================================================================
scan_files() {
  printf '%s\n' "$REPO_ROOT/bin/orchid"
  local f
  for f in "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/libexec/* "$REPO_ROOT"/runners/*; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

hits=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  body="$(grep -nE '.' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'config_get' || true)"
  [ -n "$body" ] || continue
  for name in $identifiers; do
    found="$(printf '%s\n' "$body" | grep -nE \
      "(^[0-9]+:[[:space:]]*(if|elif|while|until|case)[[:space:]].*[^A-Za-z0-9_./-]$name([^A-Za-z0-9_./-]|\$))|([[:space:]](=|==|!=)[[:space:]]*\"?$name\"?([^A-Za-z0-9_./-]|\$))|([^A-Za-z0-9_./-]$name\))" \
      || true)"
    if [ -n "$found" ]; then
      hits="$hits
$f [$name]: $found"
    fi
  done
done < <(scan_files)

if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  fail "INV-14: kernel source branches on a discovered engine identifier"
fi

# Self-check: the scan must actually be capable of finding something, or a
# broken regex would pass this invariant vacuously forever.
probe="$WORK/probe.sh"
first_id="${identifiers%% *}"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$engine" = %s ]; then echo branch; fi\n' "$first_id"
} > "$probe"
probe_hit="$(grep -nE "[[:space:]](=|==|!=)[[:space:]]*\"?$first_id\"?([^A-Za-z0-9_./-]|\$)" "$probe" || true)"
[ -n "$probe_hit" ] || fail "INV-14 self-check: the comparison pattern fails to match a real name branch"

probe_assign="$WORK/probe-assign.sh"
printf 'v=%s,other\n' "$first_id" > "$probe_assign"
probe_assign_hit="$(grep -nE "[[:space:]](=|==|!=)[[:space:]]*\"?$first_id\"?([^A-Za-z0-9_./-]|\$)" "$probe_assign" || true)"
[ -z "$probe_assign_hit" ] || fail "INV-14 self-check: an assignment (a config default table) must not read as a branch"

# ===========================================================================
# 3 -- neutrality, behaviourally. An engine whose name appears nowhere in
# this codebase must resolve, validate, qualify, pass role eligibility, and
# be routed to, exactly like a shipped one. If any layer had a name table,
# this fixture is what would fall through it.
# ===========================================================================
cd "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
mkdir -p .orchid/tasks
export ORCHID_REPO="$WORK" HOME="$MACHINE_HOME"
export ORCHID_ENGINES_DIR="$WORK/eng"
NEUTRAL=zqxwv-neutral-9
mkdir -p "$WORK/eng/$NEUTRAL"
printf 'manifest_version=1\nid=neutral/%s\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text,workspace_read,git\nrequires_binaries=jq\nentrypoint=run\n' \
  "$NEUTRAL" > "$WORK/eng/$NEUTRAL/plugin.conf"
printf '#!/usr/bin/env bash\ntrue\n' > "$WORK/eng/$NEUTRAL/run"
chmod +x "$WORK/eng/$NEUTRAL/run"

grep -rq "$NEUTRAL" "$REPO_ROOT/lib" "$REPO_ROOT/libexec" "$REPO_ROOT/runners" "$REPO_ROOT/bin" \
  && fail "INV-14: the neutrality fixture's name must appear nowhere in kernel source"

# resolver
assert_eq "$WORK/eng/$NEUTRAL" "$(resolve_engine_dir "$NEUTRAL")" "an unknown engine name resolves to its directory"
assert_eq "$WORK/eng/$NEUTRAL/run" "$(resolve_engine_exe "$NEUTRAL")" "an unknown engine name resolves to its entrypoint"
assert_eq "neutral/$NEUTRAL" "$(resolve_engine_qualified_id "$NEUTRAL")" \
  "its qualified id comes from its own manifest, never an assumed orchid/ prefix"

# manifest
manifest_validate "$WORK/eng/$NEUTRAL" >/dev/null || fail "an unknown engine's manifest validates on the same rules as a shipped one"
assert_eq engine "$(manifest_get "$WORK/eng/$NEUTRAL" kind)" "its kind is read from the manifest"
assert_eq soft "$(manifest_get "$WORK/eng/$NEUTRAL" command_surface soft)" \
  "an absent command_surface label reads as soft — the weaker claim, never the stronger one"

# every SHIPPED engine declares the label explicitly, so the honest-label
# rule cannot rot into "everything is unlabelled".
for d in "$REPO_ROOT"/plugins/engines/*/; do
  [ -d "$d" ] || continue
  surface="$(manifest_get "${d%/}" command_surface)"
  case "$surface" in
    brokered|soft) ;;
    *) fail "INV-14: shipped engine ${d%/} must declare command_surface=brokered|soft (got '${surface:-none}')" ;;
  esac
done

# role eligibility + config-driven role binding
role_eligibility_reason reviewer "$WORK/eng/$NEUTRAL" >/dev/null \
  || fail "an unknown engine is judged eligible by capability, not by name"

# The implementer is bound to a DIFFERENT engine than the reviewer, discovered
# from the shipped plugin tree rather than named here (this file may not
# contain an engine name any more than the kernel may).
#
# Review routing's slot 1 is required to be engine-independent, so it skips any
# candidate equal to the implementer's engine. Binding both roles to $NEUTRAL
# would disqualify the neutral engine from the very slot this section exists to
# observe, and routing would fall through to the tier chain for a reason that
# has nothing to do with the engine being unknown -- the fixture would then
# pass or fail on independence policy while claiming to measure neutrality.
impl_engine=""
for d in "$REPO_ROOT"/plugins/engines/*/; do
  [ -d "$d" ] || continue
  cand="$(basename "${d%/}")"
  [ "$cand" != "$NEUTRAL" ] || continue
  impl_dir="$(resolve_engine_dir "$cand" 2>/dev/null)" || continue
  role_eligibility_reason implementer "$impl_dir" >/dev/null 2>&1 || continue
  impl_engine="$cand"; break
done
[ -n "$impl_engine" ] || fail "INV-14: no shipped engine is implementer-eligible to bind against"

printf 'role.reviewer=%s\nrole.implementer=%s\n' "$NEUTRAL" "$impl_engine" > "$WORK/orchid.config"
assert_eq "$NEUTRAL" "$(resolve_role "$WORK" reviewer)" "role binding resolves an unknown engine name"
assert_eq "$NEUTRAL" "$(resolve_role_available "$WORK" reviewer)" "availability resolution accepts an unknown engine name"

# review routing
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" task create N001 "neutral routing" >/dev/null
routing="$("$ORCHID_BIN" jobs review-plan N001)"
assert_match "$NEUTRAL" "$routing" "review routing selects an unknown engine on capability and config alone"
# ...and selects it for the ENGINE-INDEPENDENT slot specifically. Matching the
# name alone would also be satisfied by a session-independent fallback, i.e. by
# routing settling on $NEUTRAL because nothing else was left rather than
# because an unknown engine is a first-class candidate.
assert_match "^1[[:space:]]+$NEUTRAL[[:space:]]+engine-independent\$" "$routing" \
  "an unknown engine fills the engine-independent slot, not a degraded fallback"
