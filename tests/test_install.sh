#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

INSTALL="$REPO_ROOT/install.sh"

# --- Sandbox install: HOME redirected, defaults (no CLAUDE_SKILLS_DIR/
# ORCHID_BIN_DIR override) so both resolve under the sandbox HOME. Run from
# a plain (non-git) directory so install.sh takes the "next steps" branch
# instead of running `orchid doctor` against some incidental repo.
export HOME="$WORK/home"
nogit="$WORK/nogit"; mkdir -p "$nogit"
out="$(cd "$nogit" && "$INSTALL" 2>&1)" || fail "install.sh exits 0 on a fresh sandbox HOME (got: $out)"
assert_match "[Nn]ext steps" "$out" "install.sh prints next-steps outside a git repo"

for name in orchid orchid-plan orchid-resume; do
  link="$HOME/.claude/skills/$name"
  [ -L "$link" ] || fail "skill symlink missing: $link"
  [ "$(readlink "$link")" = "$REPO_ROOT/skills/$name" ] \
    || fail "skill symlink $link does not resolve to $REPO_ROOT/skills/$name (got: $(readlink "$link"))"
done

bin_link="$HOME/.local/bin/orchid"
[ -L "$bin_link" ] || fail "bin symlink missing: $bin_link"
[ "$(readlink "$bin_link")" = "$REPO_ROOT/bin/orchid" ] || fail "bin symlink does not point at $REPO_ROOT/bin/orchid (got: $(readlink "$bin_link"))"

# orchid resolves THROUGH the installed symlink: bin/orchid's own symlink
# resolution must land back on the real ORCHID_ROOT (the repo checkout),
# proven by comparing `config list` output (reads lib/config-keys.txt under
# ORCHID_ROOT) run via the installed symlink vs. run directly.
export ORCHID_REPO="$nogit"
direct_out="$("$ORCHID_BIN" config list 2>&1)" || fail "direct orchid config list failed"
linked_out="$("$bin_link" config list 2>&1)" || fail "orchid resolved through the installed symlink failed to run (config list)"
assert_eq "$direct_out" "$linked_out" "orchid via the installed symlink resolves to the same ORCHID_ROOT as the direct binary"

# Also resolvable purely via PATH, the way a real shell would find it.
path_out="$(PATH="$HOME/.local/bin:$PATH" command -v orchid)"
assert_eq "$bin_link" "$path_out" "orchid is found on PATH at the installed symlink"

[ -d "$HOME/.orchid/plugins/engines" ] || fail "~/.orchid/plugins/engines not created"
[ -d "$HOME/.orchid/trust" ] || fail "~/.orchid/trust not created"
[ -f "$HOME/.orchid/config" ] || fail "~/.orchid/config not created"
grep -q '^# integration_branch=' "$HOME/.orchid/config" || fail "~/.orchid/config missing a commented key (integration_branch)"

# Re-running install.sh must never clobber an already-customized user config.
printf '\nrole.implementer=my-custom-engine\n' >> "$HOME/.orchid/config"
(cd "$nogit" && "$INSTALL" >/dev/null 2>&1) || fail "second install.sh run failed"
grep -q '^role.implementer=my-custom-engine$' "$HOME/.orchid/config" || fail "install.sh clobbered an existing ~/.orchid/config"

# A real (non-symlink) file already occupying a link path must be left alone,
# not silently overwritten.
rm -f "$HOME/.local/bin/orchid"
mkdir -p "$HOME/.local/bin"
echo "not orchid" > "$HOME/.local/bin/orchid"
out2="$(cd "$nogit" && "$INSTALL" 2>&1)" || fail "install.sh must not hard-fail when a link path is occupied by a real file"
assert_match "skip" "$out2" "install.sh warns instead of clobbering a non-symlink at the bin path"
[ "$(cat "$HOME/.local/bin/orchid")" = "not orchid" ] || fail "install.sh clobbered a pre-existing real file at the bin path"
rm -f "$HOME/.local/bin/orchid"; ln -sfn "$REPO_ROOT/bin/orchid" "$HOME/.local/bin/orchid"  # restore for the uninstall check below

# --- Uninstall: removes exactly the symlinks it created; leaves config/trust.
"$INSTALL" --uninstall >/dev/null 2>&1 || fail "install.sh --uninstall failed"
for name in orchid orchid-plan orchid-resume; do
  [ -e "$HOME/.claude/skills/$name" ] && fail "uninstall left skill symlink: $name"
done
[ -e "$HOME/.local/bin/orchid" ] && fail "uninstall left bin symlink"
[ -f "$HOME/.orchid/config" ] || fail "uninstall must leave ~/.orchid/config in place"
[ -d "$HOME/.orchid/trust" ] || fail "uninstall must leave ~/.orchid/trust in place"

# Uninstall must not remove a symlink it did not create (points elsewhere).
mkdir -p "$HOME/.claude/skills"
ln -sfn "$WORK/somewhere-else" "$HOME/.claude/skills/orchid"
"$INSTALL" --uninstall >/dev/null 2>&1 || fail "install.sh --uninstall failed (foreign symlink present)"
[ -L "$HOME/.claude/skills/orchid" ] || fail "uninstall removed a symlink it did not create"

# --- PROTOCOL.md verb-existence lint: every `orchid <word>` mention (the
# first word after `orchid `, anywhere in the file, backtick-wrapped or not)
# must map to an existing, executable libexec/orchid-<word>; every
# `runners/orchid-launch` mention must map to an existing, executable runner.
PROTOCOL="$REPO_ROOT/PROTOCOL.md"
[ -f "$PROTOCOL" ] || fail "PROTOCOL.md missing"

verb_count=0
while IFS= read -r verb; do
  [ -n "$verb" ] || continue
  verb_count=$((verb_count + 1))
  exe="$REPO_ROOT/libexec/orchid-$verb"
  [ -x "$exe" ] || fail "PROTOCOL.md names 'orchid $verb' but $exe does not exist (or isn't executable)"
done < <(grep -oE 'orchid [A-Za-z_-]+' "$PROTOCOL" | awk '{print $2}' | sort -u)
[ "$verb_count" -gt 0 ] || fail "PROTOCOL.md verb lint found no 'orchid <verb>' mentions at all — regex broken?"

runner_count="$(grep -c 'runners/orchid-launch' "$PROTOCOL")"
[ "$runner_count" -gt 0 ] || fail "PROTOCOL.md never mentions runners/orchid-launch"
[ -x "$REPO_ROOT/runners/orchid-launch" ] || fail "runners/orchid-launch named in PROTOCOL.md but missing/not executable"
