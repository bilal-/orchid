#!/usr/bin/env bash
# RED: Failed, wrong-operation, or multiple replies cannot qualify a fallback;
# an occupied foreign installer bin must never be executed as Orchid's doctor.
# GREEN: Repair the same adapter to one successful requested-operation reply;
# the same installer must invoke its known source doctor and retain the foreign bin.
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/manifest.sh"
source "$REPO_ROOT/lib/roles.sh"
source "$REPO_ROOT/lib/resolver.sh"
source "$REPO_ROOT/lib/envelope.sh"
source "$REPO_ROOT/lib/capsuite.sh"
source "$REPO_ROOT/lib/ledger.sh"
export ORCHID_ROOT="$REPO_ROOT" HOME="$MACHINE_HOME" ORCHID_ENGINES_DIR="$WORK/eng"

mkdir -p "$ORCHID_ENGINES_DIR/qualification" "$WORK/qualification-repo"
printf 'role.implementer=absent-qualification,qualification\n' > "$WORK/qualification-repo/orchid.config"
cat > "$ORCHID_ENGINES_DIR/qualification/plugin.conf" <<'CONF'
manifest_version=1
id=test/qualification
version=1.0.0
kind=engine
api_version=1
capabilities=structured_text,workspace_read,workspace_write,shell,git
entrypoint=run
CONF
cat > "$ORCHID_ENGINES_DIR/qualification/run" <<'ADAPTER'
#!/usr/bin/env bash
set -euo pipefail
req="$1"
out="$(jq -r .output "$req")"
op="$(jq -r .operation "$req")"
case "$op" in
  implement|review|critique|orchestrate) ;;
  *) jq -n --arg op "$op" '{contract:1,job_id:"x",task:"x",operation:$op,status:"failed"}' > "$out"; exit 1 ;;
esac
mode="$(cat "$(dirname "$0")/mode")"
reply_op="$op"; status=ok
[ "$mode" != wrong ] || reply_op=review
[ "$mode" != failed ] || status=failed
case "$reply_op" in
  review|critique) extra='{"verdict":"approve","scope_complete":true}' ;;
  orchestrate) extra='{"summary":"orchestrated","actions":[]}' ;;
  *) extra='{"summary":"implemented"}' ;;
esac
jq -n --arg op "$reply_op" --arg status "$status" --argjson extra "$extra" \
  '{contract:1,job_id:"x",task:"x",operation:$op,status:$status} + $extra' > "$out"
[ "$mode" != multiple ] || cat "$out" >> "$out.second"
if [ "$mode" = multiple ]; then cat "$out.second" >> "$out"; rm -f "$out.second"; fi
ADAPTER
chmod +x "$ORCHID_ENGINES_DIR/qualification/run"
result="$HOME/.orchid/capsuite/qualification--implementer.json"

for mode in wrong failed multiple; do
  printf '%s\n' "$mode" > "$ORCHID_ENGINES_DIR/qualification/mode"
  rc=0; capsuite_run qualification implementer || rc=$?
  [ "$rc" -ne 0 ] || fail "$mode reply qualified the implementer"
  assert_eq false "$(jq -r .passed "$result")" "$mode reply persists failed qualification"
  rc=0; capsuite_passed qualification implementer || rc=$?
  [ "$rc" -ne 0 ] || fail "$mode reply read back as passed"
  rc=0; picked="$(resolve_role_available "$WORK/qualification-repo" implementer)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$mode reply admitted fallback '$picked'"
  rc=0; out="$("$ORCHID_BIN" plugins conform "$ORCHID_ENGINES_DIR/qualification")" || rc=$?
  [ "$rc" -ne 0 ] || fail "$mode reply passed the complete conformance battery"
  assert_match '^FAIL: declared_ops_dryrun:' "$out" "$mode reply fails declared operation qualification"
  if [ "$mode" = wrong ]; then
    assert_match "implement.*envelope claims operation 'review'" "$out" 'wrong-operation diagnostic retains both operations'
  fi
  red_case "$mode reply cannot qualify a fallback or declared operation"

  printf 'good\n' > "$ORCHID_ENGINES_DIR/qualification/mode"
  rc=0; capsuite_run qualification implementer || rc=$?
  assert_eq 0 "$rc" "repair of $mode reply qualifies the same implementer"
  capsuite_passed qualification implementer || fail "repair of $mode reply records passed qualification"
  rc=0; picked="$(resolve_role_available "$WORK/qualification-repo" implementer)" || rc=$?
  assert_eq 0 "$rc" "repair of $mode reply admits fallback"
  assert_eq qualification "$picked" "repair of $mode reply picks the same fallback"
  rc=0; out="$("$ORCHID_BIN" plugins conform "$ORCHID_ENGINES_DIR/qualification")" || rc=$?
  assert_eq 0 "$rc" "repair of $mode reply passes complete conformance"
  assert_match '^7/7 checks passed$' "$out" 'one successful requested-operation reply passes all seven checks'
  green_case "repair $mode reply to one successful reply for the requested operation"
done

# A digest-matching receipt made before successful-operation qualification was
# enforced cannot retain admission under the new kernel. Requalify the same
# unchanged, good adapter; no plugin edit is needed to restore eligibility.
marker_before="$(plugin_digest "$ORCHID_ENGINES_DIR/qualification")"
jq 'del(.qualification_contract)' "$result" > "$result.legacy"
mv "$result.legacy" "$result"
assert_eq true "$(jq -r .passed "$result")" 'legacy receipt retains its old passed flag'
assert_eq "$marker_before" "$(jq -r .tested_at_marker "$result")" 'legacy receipt still matches unchanged plugin digest'
rc=0; capsuite_passed qualification implementer || rc=$?
[ "$rc" -ne 0 ] || fail 'unstamped legacy receipt retained passed qualification'
rc=0; picked="$(resolve_role_available "$WORK/qualification-repo" implementer)" || rc=$?
[ "$rc" -ne 0 ] || fail "unstamped legacy receipt admitted fallback '$picked'"
red_case 'legacy passed receipt cannot confer qualification despite unchanged plugin digest'
rc=0; capsuite_run qualification implementer || rc=$?
assert_eq 0 "$rc" 'requalification accepts the unchanged good adapter'
assert_eq 1 "$(jq -r .qualification_contract "$result")" 'requalification stamps current qualification contract'
assert_eq "$marker_before" "$(plugin_digest "$ORCHID_ENGINES_DIR/qualification")" 'requalification leaves plugin bytes unchanged'
capsuite_passed qualification implementer || fail 'fresh current-contract receipt did not qualify adapter'
rc=0; picked="$(resolve_role_available "$WORK/qualification-repo" implementer)" || rc=$?
assert_eq 0 "$rc" 'requalification restores actual fallback admission'
assert_eq qualification "$picked" 'requalification restores the same adapter'
green_case 'requalification accepts unchanged good bytes and restores current-contract eligibility'

# Construct the actual Git-target branch of install.sh using a copied installer
# and a controlled source doctor. No vendor or installed machine binary runs.
mkdir -p "$WORK/install-source/bin" "$WORK/install-source/lib" "$WORK/install-target"
cp "$REPO_ROOT/install.sh" "$WORK/install-source/install.sh"
cp "$REPO_ROOT/lib/common.sh" "$WORK/install-source/lib/common.sh"
# The installer now requires the shared frontend helper before binary admission.
cp "$REPO_ROOT/lib/frontend.sh" "$WORK/install-source/lib/frontend.sh"
cp "$REPO_ROOT/lib/config-keys.txt" "$WORK/install-source/lib/config-keys.txt"
cat > "$WORK/install-source/bin/orchid" <<'OWNED'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HOME/owned-doctor"
OWNED
chmod +x "$WORK/install-source/bin/orchid"
git -C "$WORK/install-target" init -q .
for kind in file symlink; do
  install_home="$WORK/install-home-$kind"
  mkdir -p "$install_home/.local/bin"
  cat > "$install_home/foreign-orchid" <<'FOREIGN'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HOME/foreign-doctor"
FOREIGN
  chmod +x "$install_home/foreign-orchid"
  if [ "$kind" = file ]; then
    cp "$install_home/foreign-orchid" "$install_home/.local/bin/orchid"
  else
    ln -s "$install_home/foreign-orchid" "$install_home/.local/bin/orchid"
  fi
  rc=0
  out="$(cd "$WORK/install-target" && HOME="$install_home" /bin/bash "$WORK/install-source/install.sh" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "installer accepts occupied foreign $kind in a target Git checkout"
  assert_match 'skip.*(not (a )?symlink|foreign symlink)' "$out" "installer discloses occupied foreign $kind"
  [ ! -e "$install_home/foreign-doctor" ] || fail "installer executed foreign $kind"
  assert_eq doctor "$(cat "$install_home/owned-doctor" 2>/dev/null)" "installer invokes its source doctor despite occupied $kind"
  cmp -s "$install_home/foreign-orchid" "$install_home/.local/bin/orchid" || fail "installer changed foreign $kind bytes"
  red_case "Git-target installer refuses to invoke occupied foreign $kind"

  rm -f "$install_home/.local/bin/orchid" "$install_home/owned-doctor" "$install_home/foreign-doctor"
  rc=0
  out="$(cd "$WORK/install-target" && HOME="$install_home" /bin/bash "$WORK/install-source/install.sh" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "same installer accepts free binary path after $kind removal"
  assert_eq "$WORK/install-source/bin/orchid" "$(readlink "$install_home/.local/bin/orchid")" 'installer creates the owned binary link'
  assert_eq doctor "$(cat "$install_home/owned-doctor" 2>/dev/null)" 'normal Git-target install invokes the same source doctor'
  [ ! -e "$install_home/foreign-doctor" ] || fail 'normal install invoked foreign doctor'
  green_case "same Git-target installer creates its owned link and invokes its source doctor"
done
