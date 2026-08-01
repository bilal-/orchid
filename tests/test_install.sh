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
[ -e "$HOME/.orchid/trust" ] && fail "install must not pre-create ~/.orchid/trust (store FILE, made on demand by the trust verbs)"
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

# A FOREIGN symlink (already a symlink, but pointing somewhere other than
# this install's own source) already occupying a link path must also be left
# alone — mirrors unlink_one's exactness (readlink-checked before removal)
# in the other direction: link_one must readlink-check before ln -sfn too,
# rather than force-overwriting any symlink it finds there.
rm -f "$HOME/.local/bin/orchid"
ln -sfn "$WORK/somewhere-else-bin" "$HOME/.local/bin/orchid"
out3="$(cd "$nogit" && "$INSTALL" 2>&1)" || fail "install.sh must not hard-fail when a foreign symlink occupies the bin path"
assert_match "skip.*foreign symlink" "$out3" "install.sh warns instead of clobbering a foreign symlink at the bin path"
[ "$(readlink "$HOME/.local/bin/orchid")" = "$WORK/somewhere-else-bin" ] || fail "install.sh clobbered a foreign symlink at the bin path"
rm -f "$HOME/.local/bin/orchid"; ln -sfn "$REPO_ROOT/bin/orchid" "$HOME/.local/bin/orchid"  # restore for the uninstall check below

# --- v1-m4 Task 11: install.sh --prefix support. A custom prefix redirects
# ONLY the bin symlink (skills/config/trust locations are unaffected by
# --prefix — it means "where should the orchid binary land", not "move
# everything"); re-running with the same --prefix must stay idempotent, the
# same way the default-prefix path above already proved for ORCHID_BIN_DIR.
customprefix="$WORK/customprefix"
out_prefix="$(cd "$nogit" && "$INSTALL" --prefix "$customprefix" 2>&1)" || fail "install.sh --prefix exits 0"
[ -L "$customprefix/bin/orchid" ] || fail "install.sh --prefix did not create a bin symlink under <prefix>/bin"
[ "$(readlink "$customprefix/bin/orchid")" = "$REPO_ROOT/bin/orchid" ] || fail "install.sh --prefix's bin symlink does not resolve to $REPO_ROOT/bin/orchid"
[ -L "$HOME/.local/bin/orchid" ] || fail "install.sh --prefix must not remove the previously-linked default-prefix symlink"
out_prefix2="$(cd "$nogit" && "$INSTALL" --prefix "$customprefix" 2>&1)" || fail "install.sh --prefix re-run exits 0"
[ "$(readlink "$customprefix/bin/orchid")" = "$REPO_ROOT/bin/orchid" ] || fail "install.sh --prefix re-run left the bin symlink intact"

# --- Uninstall: removes exactly the symlinks it created; leaves config/trust.
printf '%s %s\n' "1111111111111111111111111111111111111111111111111111111111111111" "/nowhere/keepme" > "$HOME/.orchid/trust"
"$INSTALL" --uninstall >/dev/null 2>&1 || fail "install.sh --uninstall failed"
for name in orchid orchid-plan orchid-resume; do
  [ -e "$HOME/.claude/skills/$name" ] && fail "uninstall left skill symlink: $name"
done
[ -e "$HOME/.local/bin/orchid" ] && fail "uninstall left bin symlink"
[ -f "$HOME/.orchid/config" ] || fail "uninstall must leave ~/.orchid/config in place"
[ -f "$HOME/.orchid/trust" ] && grep -q "/nowhere/keepme" "$HOME/.orchid/trust" || fail "uninstall must leave the ~/.orchid/trust store FILE and its content in place"

# Uninstall must not remove a symlink it did not create (points elsewhere).
mkdir -p "$HOME/.claude/skills"
ln -sfn "$WORK/somewhere-else" "$HOME/.claude/skills/orchid"
"$INSTALL" --uninstall >/dev/null 2>&1 || fail "install.sh --uninstall failed (foreign symlink present)"
[ -L "$HOME/.claude/skills/orchid" ] || fail "uninstall removed a symlink it did not create"

# ===========================================================================
# v1-m4 Task 12 (rehearsal finding F17): ~/.orchid/trust is the digest-pinned
# trust STORE FILE, not a directory. The rehearsal failure was `mkdir -p`
# treating it as a directory: -p tolerates an existing DIRECTORY but still
# exits nonzero when the path exists as a FILE, so any machine that had ever
# run `orchid plugins trust` hard-failed every re-install under set -e.
# install.sh now creates only plugins/engines; the trust file is the trust
# verbs' business. Guard both shapes: fresh HOME twice, and a HOME whose
# trust STORE FILE already exists (the real failure shape).
# ===========================================================================
f17_home="$WORK/f17home"; mkdir -p "$f17_home"
f17_prefix="$WORK/f17prefix"
f17_nogit="$WORK/f17nogit"; mkdir -p "$f17_nogit"
f17_out1="$(cd "$f17_nogit" && HOME="$f17_home" "$INSTALL" --prefix "$f17_prefix" 2>&1)"; f17_rc1=$?
[ "$f17_rc1" -eq 0 ] || fail "install.sh (F17 regression): first run against a fresh scratch HOME/--prefix must exit 0 (rc=$f17_rc1): $f17_out1"
[ -d "$f17_home/.orchid/plugins/engines" ] || fail "install.sh (F17 regression): ~/.orchid/plugins/engines not created on first run"
[ -e "$f17_home/.orchid/trust" ] && fail "install.sh (F17 regression): install must NOT pre-create ~/.orchid/trust (a directory there breaks every trust-store read)"
f17_out2="$(cd "$f17_nogit" && HOME="$f17_home" "$INSTALL" --prefix "$f17_prefix" 2>&1)"; f17_rc2=$?
[ "$f17_rc2" -eq 0 ] || fail "install.sh (F17 regression): SECOND run against the same scratch HOME/--prefix must exit 0 (rc=$f17_rc2): $f17_out2"
printf '%s %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "/nowhere/example" > "$f17_home/.orchid/trust"
f17_out3="$(cd "$f17_nogit" && HOME="$f17_home" "$INSTALL" --prefix "$f17_prefix" 2>&1)"; f17_rc3=$?
[ "$f17_rc3" -eq 0 ] || fail "install.sh (F17 regression): re-install with an EXISTING trust store FILE must exit 0 — this is the exact rehearsal failure (rc=$f17_rc3): $f17_out3"
[ -f "$f17_home/.orchid/trust" ] || fail "install.sh (F17 regression): trust store file clobbered by re-install"
grep -q "/nowhere/example" "$f17_home/.orchid/trust" || fail "install.sh (F17 regression): trust store content lost on re-install"
[ -L "$f17_prefix/bin/orchid" ] || fail "install.sh (F17 regression): --prefix bin symlink missing after re-install"

# ===========================================================================
# ===========================================================================
# v1-m4 Task 11: Homebrew formula (prepare-only) + docs/install.md
# ===========================================================================
# Formula/orchid.rb is authored for a FUTURE bilal-/homebrew-orchid tap --
# never tapped, installed, or built by this suite (no `brew` invocation
# anywhere below; outward-facing actions are for the release-day operator,
# per docs/install.md, not this test). Lint only: valid Ruby syntax, and the
# placeholders/URL the release-day steps key off of are actually present.
FORMULA="$REPO_ROOT/Formula/orchid.rb"
[ -f "$FORMULA" ] || fail "Formula/orchid.rb missing"
if command -v ruby >/dev/null 2>&1; then
  ruby_err="$(ruby -c "$FORMULA" 2>&1)" || fail "Formula/orchid.rb fails 'ruby -c' syntax check: $ruby_err"
else
  echo "  SKIP: ruby not present on this machine -- Formula/orchid.rb syntax not linted"
fi
grep -q 'VERSION-PLACEHOLDER' "$FORMULA" || fail "Formula/orchid.rb missing the VERSION-PLACEHOLDER token"
grep -q 'SHA256-PLACEHOLDER' "$FORMULA" || fail "Formula/orchid.rb missing the SHA256-PLACEHOLDER token"
grep -q 'bilal-/orchid' "$FORMULA" || fail "Formula/orchid.rb does not reference the bilal-/orchid tarball URL"
grep -qE 'class +Orchid *< *Formula' "$FORMULA" || fail "Formula/orchid.rb does not define 'class Orchid < Formula'"

# --- Wrapper resolution: simulate exactly the directory shape Formula/
# orchid.rb's `install` block produces (bin/, libexec/, lib/, runners/,
# plugins/, templates/, roles/, PROTOCOL.md all siblings under one prefix
# dir, with a SEPARATE top-level bin/ symlinking back to <prefix>/bin/
# orchid, mirroring Homebrew's own bin.install_symlink) WITHOUT invoking
# brew/ruby/network -- proving bin/orchid's existing self-readlink-then-
# take-the-parent-of-parent ORCHID_ROOT resolution (bin/orchid lines 3-8)
# lands on the simulated prefix, not on this repo checkout, the same way
# the install.sh symlink check above proves it for ~/.local/bin.
sim_prefix="$WORK/formula-sim/libexec"
mkdir -p "$sim_prefix"
cp -R "$REPO_ROOT/bin" "$sim_prefix/bin"
cp -R "$REPO_ROOT/libexec" "$sim_prefix/libexec"
cp -R "$REPO_ROOT/lib" "$sim_prefix/lib"
cp -R "$REPO_ROOT/runners" "$sim_prefix/runners"
cp -R "$REPO_ROOT/plugins" "$sim_prefix/plugins"
cp -R "$REPO_ROOT/templates" "$sim_prefix/templates"
[ -d "$REPO_ROOT/roles" ] && cp -R "$REPO_ROOT/roles" "$sim_prefix/roles"
cp "$REPO_ROOT/PROTOCOL.md" "$sim_prefix/PROTOCOL.md"
sim_bin="$WORK/formula-sim/bin"
mkdir -p "$sim_bin"
ln -sfn "$sim_prefix/bin/orchid" "$sim_bin/orchid"

# stdout only (2>/dev/null): a pre-existing, unrelated common.sh wart
# (config-keys.txt's documentation-only `role.<id>.blocking` template line
# triggers a "bad substitution" warning on stderr that embeds the caller's
# OWN absolute path) would otherwise make this comparison fail for a reason
# that has nothing to do with whether ORCHID_ROOT resolution is correct --
# the sim lives under a different absolute path than the real checkout by
# construction, so that stderr text can never match even when everything
# this test actually cares about (the resolved config values on stdout) is
# identical.
sim_direct_out="$("$ORCHID_BIN" config list 2>/dev/null)" || fail "direct orchid config list failed (formula-sim comparison)"
sim_out="$("$sim_bin/orchid" config list 2>/dev/null)" || fail "formula-simulated bin/orchid failed to run (config list)"
assert_eq "$sim_direct_out" "$sim_out" "formula-simulated bin/orchid resolves ORCHID_ROOT to the simulated prefix, matching the direct binary's output"

# --- docs/install.md must exist and its own relative links must resolve --
# test_docs.sh's link-check (check 2) scans a fixed docs surface that
# pre-dates this task and deliberately excludes docs/install.md (same
# reason it excludes docs/specs/*.md and docs/dogfood-notes.md); this task
# owns docs/install.md, so its link hygiene is checked here instead.
INSTALL_MD="$REPO_ROOT/docs/install.md"
[ -f "$INSTALL_MD" ] || fail "docs/install.md missing"
install_md_link_count=0
while IFS= read -r link; do
  [ -n "$link" ] || continue
  case "$link" in
    http://*|https://*|mailto:*) continue ;;
    '#'*) continue ;;
  esac
  target="${link%%#*}"
  [ -n "$target" ] || continue
  install_md_link_count=$((install_md_link_count + 1))
  [ -e "$REPO_ROOT/docs/$target" ] || fail "docs/install.md: relative link target does not exist: $link (resolved: $REPO_ROOT/docs/$target)"
done < <(grep -oE '\]\([^) ]+\)' "$INSTALL_MD" | sed -E 's/^\]\(//; s/\)$//')
[ "$install_md_link_count" -gt 0 ] || fail "docs/install.md has no relative markdown links -- expected at least one (e.g. back to README.md)"

# README.md's install section must reference docs/install.md as a real
# markdown link (not just a bare code-span test_docs.sh's own link-check
# regex can't see) so test_docs.sh's existing check 2 (README.md is already
# in its docs_suite_files scan) enforces it resolves, permanently.
grep -qE '\]\(\.*/?docs/install\.md\)' "$REPO_ROOT/README.md" || fail "README.md's install section does not link to docs/install.md as a markdown link"

# --- PROTOCOL.md verb-existence lint: every `orchid <word>` mention (the
# first word after `orchid `, anywhere in the file, backtick-wrapped or not)
# must map to an existing, executable libexec/orchid-<word>; every
# `runners/orchid-launch` mention must map to an existing, executable runner.
# Note: this only covers TOP-LEVEL verbs (e.g. `task`, `jobs`, `run` ->
# libexec/orchid-task, orchid-jobs, orchid-run) — it does not, and cannot,
# validate that a subcommand named alongside one (e.g. `task infra-fail`,
# `jobs gc`) is actually implemented inside that dispatcher; the regex only
# ever captures the single word right after `orchid `. Subcommand coverage
# comes from the functional tests for each verb instead (tests/test_task.sh,
# tests/test_jobs.sh, ...).
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

# v1-m2 (Task 10): PROTOCOL.md's HEADLESS OPERATION section names the other
# two runners by their full `runners/orchid-<name>` path (never bare, unlike
# libexec verbs, which is why the top-level regex above can't already catch
# these) — same existence check as orchid-launch just above, one per runner.
for runner in orchid-tick orchid-pump; do
  count="$(grep -c "runners/$runner" "$PROTOCOL")"
  [ "$count" -gt 0 ] || fail "PROTOCOL.md never mentions runners/$runner"
  [ -x "$REPO_ROOT/runners/$runner" ] || fail "runners/$runner named in PROTOCOL.md but missing/not executable"
done

# `orchid jobs review-plan <id>` is a JOBS SUBCOMMAND, not a top-level verb --
# the top-level regex above only ever captures "jobs" (already checked), so
# this is a targeted second check: PROTOCOL.md must name the full subcommand,
# and libexec/orchid-jobs must actually implement a `review-plan)` case arm
# (not just claim to support it in its own usage string).
review_plan_count="$(grep -c 'jobs review-plan' "$PROTOCOL")"
[ "$review_plan_count" -gt 0 ] || fail "PROTOCOL.md never mentions 'orchid jobs review-plan'"
grep -qE '^\s*review-plan\)' "$REPO_ROOT/libexec/orchid-jobs" \
  || fail "PROTOCOL.md names 'orchid jobs review-plan' but libexec/orchid-jobs has no review-plan) case arm"

# v1-m2 (Task 10): the v0-era aspirational note ("marking an engine
# unavailable ... is not implemented by any verb [yet]") must be gone from
# PROTOCOL.md now that lib/ledger.sh + `orchid jobs reconcile` actually close
# that gap automatically -- a lingering copy would misdocument shipped
# behavior as still-missing. Both of PROTOCOL.md's own historical copies of
# this claim (THE TICK step 2's paragraph, and the discrepancies-list
# `infra_failures` bullet) used one of these two phrasings; neither may
# survive.
if grep -q 'remains aspirational' "$PROTOCOL"; then
  fail "PROTOCOL.md still calls engine-unavailable marking 'aspirational' -- lib/ledger.sh + jobs reconcile ship it now"
fi
if grep -qE 'engine.*unavailable.*not implemented by any verb' "$PROTOCOL"; then
  fail "PROTOCOL.md still claims marking an engine unavailable 'is not implemented by any verb' -- lib/ledger.sh + jobs reconcile ship it now"
fi

# v1-m3 (Task 6): `orchid-launch ... hook --hook <point>` is a NEW invocation
# form the top-level verb regex above can't validate on its own (it only
# ever captures the bare word after "orchid " -- here that word is "notify"/
# "task"/"jobs"/"merge", all already-existing verbs; the `--hook` flag and
# the `hook` operation are what's actually new). Same targeted-check pattern
# as the `jobs review-plan` check above: PROTOCOL.md must name the form, and
# runners/orchid-launch + libexec/orchid-jobs must actually implement it.
hook_flag_count="$(grep -c -- '--hook' "$PROTOCOL")"
[ "$hook_flag_count" -gt 0 ] || fail "PROTOCOL.md never mentions the --hook flag"
grep -qE -- '--hook' "$REPO_ROOT/runners/orchid-launch" \
  || fail "PROTOCOL.md names '--hook' but runners/orchid-launch has no --hook handling"
grep -qE -- '--hook' "$REPO_ROOT/libexec/orchid-jobs" \
  || fail "PROTOCOL.md names '--hook' but libexec/orchid-jobs has no --hook handling"

# v1-m3 final review (CRITICAL 1): PROTOCOL.md's Preamble must state the
# no-external-mutation policy (live ticks pushing branches to origin was a
# real finding), and both orchestrate-capable engine adapters must mirror it
# into their OWN instruction block -- the strings those adapters actually
# feed the engine, not just PROTOCOL.md's own prose -- same targeted-check
# pattern as the --hook check above.
push_policy_count="$(grep -c 'No external mutation' "$PROTOCOL")"
[ "$push_policy_count" -gt 0 ] || fail "PROTOCOL.md never states the no-external-mutation policy"
grep -q 'git push' "$PROTOCOL" || fail "PROTOCOL.md's no-external-mutation bullet never names git push"
for adapter in claude codex; do
  grep -q 'git push' "$REPO_ROOT/plugins/engines/$adapter/run" \
    || fail "plugins/engines/$adapter/run's orchestrate instructions never mirror the no-external-mutation policy (git push)"
done

# `orchid task set <id> hook_guidance ...` (PROTOCOL's on_verify_fail step):
# hook_guidance must actually be settable -- i.e. absent from orchid-task's
# `set` deny-list -- not just mentioned in prose.
grep -qF 'hook_guidance' "$PROTOCOL" || fail "PROTOCOL.md never mentions hook_guidance"
deny_line="$(grep -nE '^\s*status\|attempts\|infra_failures\|id\|created\|updated\|schema\)' "$REPO_ROOT/libexec/orchid-task")"
[ -n "$deny_line" ] || fail "orchid-task's set deny-list case arm not found -- update this check"
printf '%s' "$deny_line" | grep -q hook_guidance && fail "hook_guidance must never land in orchid-task's set deny-list"
