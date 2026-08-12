#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

INSTALL="$REPO_ROOT/install.sh"

# --- Sandbox install: HOME redirected, defaults (no CLAUDE_SKILLS_DIR/
# ORCHID_BIN_DIR override) so both resolve under the sandbox HOME. Run from
# a plain (non-git) directory so install.sh takes the "next steps" branch
# instead of running `orchid doctor` against some incidental repo.
# `~/.claude` is pre-created here so this main flow exercises the
# already-present-front-end path (front-end presence detection itself --
# ~/.claude only / ~/.hermes/skills only / neither -- gets its own isolated
# block further down, each with its own fresh sandbox HOME).
export HOME="$WORK/home"
mkdir -p "$HOME/.claude"
nogit="$WORK/nogit"; mkdir -p "$nogit"
out="$(cd "$nogit" && "$INSTALL" 2>&1)" || fail "install.sh exits 0 on a fresh sandbox HOME (got: $out)"
assert_match "[Nn]ext steps" "$out" "install.sh prints next-steps outside a git repo"
assert_match "skip Hermes skills" "$out" "install.sh notes the Hermes skip when ~/.hermes/skills is absent"
[ -e "$HOME/.hermes" ] && fail "install.sh must not create ~/.hermes on a HOME that never had it"

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

[ -d "$HOME/.orchid/plugins/engines" ] || fail "user plugin engine directory not created"
[ -e "$HOME/.orchid/trust" ] && fail "install must not pre-create ~/.orchid/trust (store FILE, made on demand by the trust verbs)"
[ -f "$HOME/.orchid/config" ] || fail "user orchid config not created"
grep -q '^# integration_branch=' "$HOME/.orchid/config" || fail "user orchid config missing a commented key (integration_branch)"

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
_out_prefix="$(cd "$nogit" && "$INSTALL" --prefix "$customprefix" 2>&1)" || fail "install.sh --prefix exits 0"
[ -L "$customprefix/bin/orchid" ] || fail "install.sh --prefix did not create a bin symlink under <prefix>/bin"
[ "$(readlink "$customprefix/bin/orchid")" = "$REPO_ROOT/bin/orchid" ] || fail "install.sh --prefix's bin symlink does not resolve to $REPO_ROOT/bin/orchid"
[ -L "$HOME/.local/bin/orchid" ] || fail "install.sh --prefix must not remove the previously-linked default-prefix symlink"
_out_prefix2="$(cd "$nogit" && "$INSTALL" --prefix "$customprefix" 2>&1)" || fail "install.sh --prefix re-run exits 0"
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
# Front-end presence detection (front-end-neutral install.sh): install.sh
# wires whichever agent front-ends are ACTUALLY PRESENT on this machine and
# skips the rest cleanly -- a one-line note, exit 0, and (crucially) never
# creating that front-end's OWN top-level config directory (~/.claude,
# ~/.hermes) on a machine that never had it. Three fresh, isolated sandbox
# HOMEs, no CLAUDE_SKILLS_DIR/ORCHID_BIN_DIR override:
#   fe1: ~/.claude present only       -> claude wired, hermes skipped
#   fe2: ~/.hermes/skills present only -> hermes wired, claude skipped
#   fe3: neither present               -> both skipped, still exits 0
# ===========================================================================
fe_nogit="$WORK/fe-nogit"; mkdir -p "$fe_nogit"

fe1_home="$WORK/fe1-home"; mkdir -p "$fe1_home/.claude"
fe1_out="$(cd "$fe_nogit" && HOME="$fe1_home" "$INSTALL" 2>&1)" || fail "install.sh (front-end detection): ~/.claude-only HOME must exit 0"
for name in orchid orchid-plan orchid-resume; do
  link="$fe1_home/.claude/skills/$name"
  [ -L "$link" ] || fail "front-end detection: ~/.claude-only HOME did not wire Claude Code skill $name"
  [ "$(readlink "$link")" = "$REPO_ROOT/skills/$name" ] \
    || fail "front-end detection: ~/.claude-only HOME's $name symlink does not resolve to the repo"
done
[ -e "$fe1_home/.hermes" ] && fail "front-end detection: ~/.claude-only HOME must not have ~/.hermes created"
assert_match "skip Hermes skills" "$fe1_out" "front-end detection: ~/.claude-only HOME notes the Hermes skip"

fe2_home="$WORK/fe2-home"; mkdir -p "$fe2_home/.hermes/skills"
fe2_out="$(cd "$fe_nogit" && HOME="$fe2_home" "$INSTALL" 2>&1)" || fail "install.sh (front-end detection): ~/.hermes/skills-only HOME must exit 0"
for name in orchid orchid-plan orchid-resume; do
  link="$fe2_home/.hermes/skills/orchestration/$name"
  [ -L "$link" ] || fail "front-end detection: ~/.hermes/skills-only HOME did not wire Hermes skill $name"
  [ "$(readlink "$link")" = "$REPO_ROOT/skills/$name" ] \
    || fail "front-end detection: ~/.hermes/skills-only HOME's $name symlink does not resolve to the repo"
done
[ -e "$fe2_home/.claude" ] && fail "front-end detection: ~/.hermes-only HOME must not have ~/.claude created"
assert_match "skip Claude Code skills" "$fe2_out" "front-end detection: ~/.hermes-only HOME notes the Claude Code skip"

fe3_home="$WORK/fe3-home"; mkdir -p "$fe3_home"
fe3_out="$(cd "$fe_nogit" && HOME="$fe3_home" "$INSTALL" 2>&1)"; fe3_rc=$?
[ "$fe3_rc" -eq 0 ] || fail "install.sh (front-end detection): neither-present HOME must still exit 0 (rc=$fe3_rc): $fe3_out"
assert_match "skip Claude Code skills" "$fe3_out" "front-end detection: neither-present HOME notes the Claude Code skip"
assert_match "skip Hermes skills" "$fe3_out" "front-end detection: neither-present HOME notes the Hermes skip"
[ -e "$fe3_home/.claude" ] && fail "front-end detection: neither-present HOME must not have ~/.claude created"
[ -e "$fe3_home/.hermes" ] && fail "front-end detection: neither-present HOME must not have ~/.hermes created"
[ -L "$fe3_home/.local/bin/orchid" ] || fail "front-end detection: neither-present HOME must still wire bin/orchid regardless of any front-end's presence"

# --uninstall on the hermes-only HOME must remove exactly the Hermes
# symlinks it created (mirrors the Claude uninstall checks above) and leave
# the orchestration category directory itself in place (install.sh owns the
# symlinks it placed inside it, never the directory).
_fe2_uninstall_out="$(cd "$fe_nogit" && HOME="$fe2_home" "$INSTALL" --uninstall 2>&1)" || fail "install.sh --uninstall (front-end detection, hermes-only HOME) failed"
for name in orchid orchid-plan orchid-resume; do
  [ -e "$fe2_home/.hermes/skills/orchestration/$name" ] && fail "uninstall left Hermes skill symlink: $name"
done
[ -d "$fe2_home/.hermes/skills/orchestration" ] || fail "uninstall must leave the Hermes orchestration category directory itself in place"

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
# pinned version, release-asset URL, and checksum are concrete.
FORMULA="$REPO_ROOT/Formula/orchid.rb"
if [ "${ORCHID_RELEASE_ARCHIVE_TEST:-0}" = 1 ]; then
  [ ! -e "$FORMULA" ] || fail "release archive must keep the external tap formula export-ignored"
else
  [ -f "$FORMULA" ] || fail "Formula/orchid.rb missing"
  if command -v ruby >/dev/null 2>&1; then
    ruby_err="$(ruby -c "$FORMULA" 2>&1)" || fail "Formula/orchid.rb fails 'ruby -c' syntax check: $ruby_err"
  else
    echo "  SKIP: ruby not present on this machine -- Formula/orchid.rb syntax not linted"
  fi
  grep -q 'version "1.0.0-beta.1"' "$FORMULA" \
    || fail "Formula/orchid.rb version is not pinned to 1.0.0-beta.1"
  grep -q 'releases/download/v1.0.0-beta.1/orchid-1.0.0-beta.1.tar.gz' "$FORMULA" \
    || fail "Formula/orchid.rb does not reference the version-pinned release asset"
  grep -Eq 'sha256 "[0-9a-f]{64}"' "$FORMULA" || fail "Formula/orchid.rb does not contain a concrete SHA-256"
  grep -Eq 'VERSION-PLACEHOLDER|SHA256-PLACEHOLDER' "$FORMULA" \
    && fail "Formula/orchid.rb still contains a release placeholder"
  grep -qE 'class +Orchid *< *Formula' "$FORMULA" || fail "Formula/orchid.rb does not define 'class Orchid < Formula'"
fi
grep -q '^ORCHID_INSTALL_VERSION="1.0.0-beta.1"$' "$INSTALL" || fail "install.sh release version metadata mismatch"
grep -q '^ORCHID_INSTALL_REF="v1.0.0-beta.1"$' "$INSTALL" || fail "install.sh stable ref is not version-pinned"

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

# v1-m2 (Task 10), extended v1.1: PROTOCOL.md's HEADLESS OPERATION section
# names the other runners by their full `runners/orchid-<name>` path (never
# bare, unlike libexec verbs, which is why the top-level regex above can't
# already catch these) -- same existence check as orchid-launch just above,
# one per runner. The deterministic driver and the brokered command surface
# join the list: both are named normatively by that section, so a rename that
# left the prose behind would be caught here.
for runner in orchid-tick orchid-pump orchid-drive orchid-orchestrator-command; do
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

# T039: the plan is PINNED for the life of an attempt, and the two verbs that
# move a pinned plan are the recorded exits a `review-evidence` boundary names
# (no arbitration verb is legal from `reviewing`, so a boundary that named
# neither left an operator with nothing but a hand-edit of durable state --
# which is exactly how r-002 lost a task). Same targeted doc<->code binding as
# the `--hook` check below: PROTOCOL.md must name each form, and
# libexec/orchid-jobs must actually parse it.
for plan_flag in --pin --repin --adopt-evidence; do
  grep -qF -- "$plan_flag" "$PROTOCOL" \
    || fail "PROTOCOL.md never mentions 'orchid jobs review-plan $plan_flag' — the pinned plan's own escape hatches must be documented where the review policy is"
  grep -qF -- "$plan_flag)" "$REPO_ROOT/libexec/orchid-jobs" \
    || fail "PROTOCOL.md names '$plan_flag' but libexec/orchid-jobs has no '$plan_flag)' case arm to parse it"
done

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

# ===========================================================================
# Bootstrap mode (single-line curl|bash install): install.sh, run OUTSIDE
# an orchid checkout, must clone (or update) a canonical copy and hand off
# to it -- WITHOUT any real network access. A fake `git` on PATH intercepts
# every invocation, records its argv, and (on `clone`) fabricates a minimal
# fake checkout: bin/orchid + lib/common.sh (the two anchor files
# install.sh's own bootstrap-detection checks for) plus a stub install.sh
# that records the args IT was exec'd with. This proves several things with
# no network at all: (1) git is invoked as `clone --depth 1 --branch <ref>
# --single-branch <url> <tmp sibling of ORCHID_HOME>`, never ORCHID_HOME
# directly (the atomic
# clone-then-mv pattern -- installer-review.md Finding 1: a `git clone`
# interrupted partway through, network drop/Ctrl-C/disk full, must never
# leave ORCHID_HOME itself half-populated, since real git creates .git/
# before it has fetched every object); (2) the cloned installer is exec'd
# with the original pass-through args (--prefix, --uninstall); (3) an
# already-cloned $home fetches and detaches at the selected channel's exact
# commit instead of cloning again; (4) ANY $home that exists on disk but
# isn't a usable checkout -- whatever put it there -- is REFUSED with a
# nonzero exit and left completely intact, never auto-deleted. The
# "run the same line again" retry story after a dropped connection holds
# without any cleanup step because the clone targets a temp sibling and
# only ever lands at $home via mv after git fully succeeds, so an
# interrupted clone leaves $home absent, not half-populated. Existing
# clones select an exact fetched commit for either the stable tag or the
# explicitly requested moving development channel.
# ===========================================================================

# fake_git_bin DIR: writes an executable `git` into DIR that logs every
# invocation to DIR/../gitlog.txt, fabricates a fake orchid checkout on
# `clone`, and answers the bootstrap's `-C <dir>` metadata/fetch/checkout
# calls against whatever fake checkouts already exist on disk (no
# state of its own -- the filesystem IS the state, same as real git).
# `-C <dir> config ...` (used by install.sh's stale-clone safety check,
# review-round-2 fix) delegates to REAL git instead of being faked, so it
# reads whatever genuine `.git/config` a fixture set up with real
# `git init`/`git remote add` actually contains -- there is no safe way to
# fake "what does this repo's remote.origin.url say" without just running
# real git against a real repo. Anything else (bare `rev-parse`,
# `worktree`, etc. -- the calls install.sh makes for its OWN unrelated "am
# I inside a repo to orchestrate" check) also delegates to the real git so
# the rest of install.sh's behavior stays correct; only clone and bootstrap's
# own `-C` command shapes are faked.
fake_git_bin() {
  local dir="$1" gitlog="$2" real_git
  real_git="$(command -v git)"
  mkdir -p "$dir"
  cat > "$dir/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gitlog"
case "\$1" in
  clone)
    dest="\${*: -1}"
    mkdir -p "\$dest/bin" "\$dest/lib" "\$dest/.git"
    touch "\$dest/bin/orchid" "\$dest/lib/common.sh"
    cat > "\$dest/install.sh" <<'INNER'
#!/usr/bin/env bash
printf -- '%s\n' "\$@" > "\$STUB_INSTALL_RECORD"
INNER
    chmod +x "\$dest/install.sh"
    exit 0
    ;;
  -C)
    fedir="\$2"; sub="\$3"
    case "\$sub" in
      rev-parse)
        [ -d "\$fedir/.git" ] || exit 1
        case "\${4:-}" in
          --git-dir) printf '%s\n' .git ;;
          --verify)
            case "\${5:-}" in
              refs/tags/*)
                [ "\${FAKE_GIT_NO_TAG:-0}" != 1 ] || exit 1
                printf '%s\n' 1111111111111111111111111111111111111111
                ;;
              'FETCH_HEAD^{commit}') printf '%s\n' 2222222222222222222222222222222222222222 ;;
              'HEAD^{commit}') printf '%s\n' 2222222222222222222222222222222222222222 ;;
              *) exit 1 ;;
            esac
            ;;
          *) exit 1 ;;
        esac
        ;;
      config)
        if [ -f "\$fedir/bin/orchid" ] && [ -f "\$fedir/lib/common.sh" ]; then
          printf '%s\n' 'https://github.com/bilal-/orchid.git'
          exit 0
        fi
        exec "$real_git" "\$@"
        ;;
      fetch|checkout|pull|status) exit 0 ;;
      *) exec "$real_git" "\$@" ;;
    esac
    ;;
  *)
    exec "$real_git" "\$@"
    ;;
esac
EOF
  chmod +x "$dir/git"
}

# --- fresh bootstrap: no ORCHID_HOME clone yet -> git clone --depth 1 --
bs_work="$WORK/bootstrap"; mkdir -p "$bs_work/bare/nogit"
# "copy install.sh alone" -- no sibling bin/ or lib/, so install.sh's own
# ROOT-has-both-anchor-files check can't find a real checkout to run from.
cp "$INSTALL" "$bs_work/bare/nogit/install.sh"
chmod +x "$bs_work/bare/nogit/install.sh"

bs_gitbin="$bs_work/gitbin1"; bs_gitlog="$bs_work/gitlog1.txt"; : > "$bs_gitlog"
fake_git_bin "$bs_gitbin" "$bs_gitlog"
export STUB_INSTALL_RECORD="$bs_work/record1.txt"
bs_home="$bs_work/home1"
bs_out="$(PATH="$bs_gitbin:$PATH" ORCHID_HOME="$bs_home" "$bs_work/bare/nogit/install.sh" --prefix "$bs_work/customprefix" 2>&1)"
bs_rc=$?
[ "$bs_rc" -eq 0 ] || fail "bootstrap (fresh clone): install.sh exits 0 (got rc=$bs_rc, output: $bs_out)"
bs_clone_line="$(grep '^clone' "$bs_gitlog")"
assert_match '^clone --depth 1 --branch v1\.0\.0-beta\.1 --single-branch https://github\.com/bilal-/orchid\.git ' "$bs_clone_line" \
  "bootstrap (fresh clone): git invoked with the immutable stable tag"
assert_match '\-C .* rev-parse --verify refs/tags/v1\.0\.0-beta\.1\^\{commit\}' "$(cat "$bs_gitlog")" \
  "bootstrap (fresh clone): resolves the stable name specifically through refs/tags"
assert_match '\-C .* checkout --detach 1111111111111111111111111111111111111111' "$(cat "$bs_gitlog")" \
  "bootstrap (fresh clone): detaches at the stable tag's peeled commit"
bs_clone_dest="$(printf '%s' "$bs_clone_line" | awk '{print $NF}')"
[ "$(dirname "$bs_clone_dest")" = "$(dirname "$bs_home")" ] \
  || fail "bootstrap (fresh clone): git clone target's parent must be ORCHID_HOME's own parent dir (clone target: $bs_clone_dest)"
[ "$bs_clone_dest" != "$bs_home" ] \
  || fail "bootstrap (fresh clone): git clone must target a TEMP sibling of ORCHID_HOME, never ORCHID_HOME itself (atomic clone-then-mv pattern, installer-review.md Finding 1)"
[ -d "$bs_clone_dest" ] && fail "bootstrap (fresh clone): the temp clone dir must not remain on disk after a successful mv into place ($bs_clone_dest)"
[ -f "$bs_home/bin/orchid" ] && [ -f "$bs_home/lib/common.sh" ] \
  || fail "bootstrap (fresh clone): ORCHID_HOME missing the cloned checkout's anchor files after the atomic mv"
[ -f "$bs_work/record1.txt" ] || fail "bootstrap (fresh clone): cloned install.sh was never exec'd"
assert_eq "--prefix
$bs_work/customprefix" "$(cat "$bs_work/record1.txt")" \
  "bootstrap (fresh clone): cloned installer exec'd with the original pass-through args (--prefix DIR)"

# A real curl-to-bash invocation has no BASH_SOURCE filename. Its $0 names
# bash, so dirname "$0" is just the caller's cwd. Make that cwd adversarial:
# it looks exactly like an Orchid checkout, is backed by Git, and is dirty.
# The piped stable installer must ignore it completely, clone v1.0.0-beta.1
# into the canonical ORCHID_HOME, peel the tag, and execute only that cloned
# installer.
bs_pipe_cwd="$bs_work/dirty-caller-checkout"
mkdir -p "$bs_pipe_cwd/bin" "$bs_pipe_cwd/lib"
touch "$bs_pipe_cwd/bin/orchid" "$bs_pipe_cwd/lib/common.sh"
git init -q "$bs_pipe_cwd"
printf '%s\n' 'dirty caller content' > "$bs_pipe_cwd/untracked"
[ -n "$(git -C "$bs_pipe_cwd" status --porcelain --untracked-files=all)" ] \
  || fail "bootstrap (piped from dirty checkout): adversarial caller fixture is not dirty"

bs_pipe_gitlog="$bs_work/gitlog-pipe.txt"; : > "$bs_pipe_gitlog"
bs_pipe_gitbin="$bs_work/gitbin-pipe"; fake_git_bin "$bs_pipe_gitbin" "$bs_pipe_gitlog"
bs_pipe_home="$bs_work/home-pipe"
export STUB_INSTALL_RECORD="$bs_work/record-pipe.txt"; rm -f "$STUB_INSTALL_RECORD"
bs_pipe_out="$(
  cd "$bs_pipe_cwd" &&
    PATH="$bs_pipe_gitbin:$PATH" ORCHID_HOME="$bs_pipe_home" \
      "$BASH" -s -- --prefix "$bs_work/prefix-pipe" < "$INSTALL" 2>&1
)"
bs_pipe_rc=$?
[ "$bs_pipe_rc" -eq 0 ] \
  || fail "bootstrap (piped from dirty checkout): stable install exits 0 (rc=$bs_pipe_rc, output: $bs_pipe_out)"
bs_pipe_clone_line="$(grep '^clone' "$bs_pipe_gitlog")"
assert_match '^clone --depth 1 --branch v1\.0\.0-beta\.1 --single-branch https://github\.com/bilal-/orchid\.git ' "$bs_pipe_clone_line" \
  "bootstrap (piped from dirty checkout): ignores cwd and clones immutable v1.0.0-beta.1"
assert_match '\-C .* rev-parse --verify refs/tags/v1\.0\.0-beta\.1\^\{commit\}' "$(cat "$bs_pipe_gitlog")" \
  "bootstrap (piped from dirty checkout): peels the stable tag"
assert_match '\-C .* checkout --detach 1111111111111111111111111111111111111111' "$(cat "$bs_pipe_gitlog")" \
  "bootstrap (piped from dirty checkout): detaches at the pinned commit"
[ -f "$STUB_INSTALL_RECORD" ] \
  || fail "bootstrap (piped from dirty checkout): immutable clone's installer was not executed"
assert_eq "--prefix
$bs_work/prefix-pipe" "$(cat "$STUB_INSTALL_RECORD")" \
  "bootstrap (piped from dirty checkout): cloned installer receives pass-through args"

# `git clone --branch vX.Y.Z` also accepts a branch with that name. A stable
# bootstrap must prove refs/tags/vX.Y.Z exists before promoting the clone.
bs_gitlog_notag="$bs_work/gitlog-notag.txt"; : > "$bs_gitlog_notag"
bs_gitbin_notag="$bs_work/gitbin-notag"; fake_git_bin "$bs_gitbin_notag" "$bs_gitlog_notag"
bs_home_notag="$bs_work/home-notag"
export STUB_INSTALL_RECORD="$bs_work/record-notag.txt"; rm -f "$bs_work/record-notag.txt"
bs_out_notag="$(FAKE_GIT_NO_TAG=1 PATH="$bs_gitbin_notag:$PATH" ORCHID_HOME="$bs_home_notag" \
  "$bs_work/bare/nogit/install.sh" 2>&1)"
bs_rc_notag=$?
[ "$bs_rc_notag" -ne 0 ] || fail "bootstrap (same-named branch): stable install accepted a clone with no version tag"
assert_match 'refs/tags' "$bs_out_notag" \
  "bootstrap (same-named branch): refusal explains that the stable tag ref is missing"
[ ! -e "$bs_home_notag" ] || fail "bootstrap (same-named branch): refused clone must not be promoted into ORCHID_HOME"
[ ! -e "$STUB_INSTALL_RECORD" ] || fail "bootstrap (same-named branch): refused clone's installer must not execute"

# ===========================================================================
# T004 rework (destructive-install prevention): a $home that exists but
# isn't a usable checkout is NEVER auto-deleted -- not even with "positive
# proof" that its .git's remote.origin.url matches this repo's clone URL.
# An expected-origin repo missing an anchor file is still routinely a
# user-controlled checkout (a contributor's own clone with uncommitted
# work, or bin/orchid deleted mid-edit); a prior round of this fix rm
# -rf'd exactly that shape. install.sh now fails closed for EVERY
# non-usable shape: nonzero exit, path named in the message, both
# remedies printed, contents (including .git) left completely intact, no
# clone attempted. Three shapes at the SAME kind of path ($ORCHID_HOME,
# user-settable), all refused identically:
#   2b. an expected-origin orchid clone missing its anchor files, with
#       local (dirty/user) content on disk -> REFUSED, intact, nonzero
#   2c. a plain directory of unrelated user files (no .git at all)
#                                          -> REFUSED, intact, nonzero
#   2d. the user's own unrelated git repo (real .git, no matching origin)
#                                          -> REFUSED, intact, nonzero
# ===========================================================================

# --- 2b: expected-origin clone lacking anchor files, with user content ->
# REFUSED and left intact. This is the exact shape the reverted fix used to
# rm -rf: real .git, remote.origin.url matching the hardcoded clone URL,
# anchor files absent, plus a local file a deletion would destroy.
bs_gitlog2b="$bs_work/gitlog2b.txt"; : > "$bs_gitlog2b"
bs_gitbin2b="$bs_work/gitbin2b"; fake_git_bin "$bs_gitbin2b" "$bs_gitlog2b"
bs_home_partial="$bs_work/home-partial"
mkdir -p "$bs_home_partial"
git init -q "$bs_home_partial"
git -C "$bs_home_partial" remote add origin https://github.com/bilal-/orchid.git
echo "uncommitted local work" > "$bs_home_partial/dirty-user-file.txt"
export STUB_INSTALL_RECORD="$bs_work/record2b.txt"; rm -f "$bs_work/record2b.txt"
bs_out2b="$(PATH="$bs_gitbin2b:$PATH" ORCHID_HOME="$bs_home_partial" "$bs_work/bare/nogit/install.sh" 2>&1)"
bs_rc2b=$?
[ "$bs_rc2b" -ne 0 ] || fail "bootstrap (expected-origin clone, anchors missing): install.sh must exit nonzero rather than delete or proceed (output: $bs_out2b)"
assert_match "$bs_home_partial" "$bs_out2b" "bootstrap (expected-origin clone, anchors missing): refusal message names the exact path"
assert_match "refusing" "$bs_out2b" "bootstrap (expected-origin clone, anchors missing): refusal message says it is refusing, not repairing"
[ -f "$bs_home_partial/dirty-user-file.txt" ] || fail "bootstrap (expected-origin clone, anchors missing): local user file was deleted -- must be left completely intact"
[ "$(cat "$bs_home_partial/dirty-user-file.txt")" = "uncommitted local work" ] \
  || fail "bootstrap (expected-origin clone, anchors missing): local user file content was altered"
[ -d "$bs_home_partial/.git" ] || fail "bootstrap (expected-origin clone, anchors missing): the repo's .git was deleted -- must be left completely intact"
[ "$(git -C "$bs_home_partial" config --get remote.origin.url)" = "https://github.com/bilal-/orchid.git" ] \
  || fail "bootstrap (expected-origin clone, anchors missing): the repo's own remote must be untouched"
grep -q '^clone' "$bs_gitlog2b" && fail "bootstrap (expected-origin clone, anchors missing): must never attempt a clone against a refused path"
[ ! -e "$bs_work/record2b.txt" ] || fail "bootstrap (expected-origin clone, anchors missing): no installer may execute after a refusal"

# --- 2c: plain directory of unrelated user files (no .git at all) ->
# REFUSED: nonzero exit, files untouched, message names the path, no
# clone attempted.
bs_gitlog2c="$bs_work/gitlog2c.txt"; : > "$bs_gitlog2c"
bs_gitbin2c="$bs_work/gitbin2c"; fake_git_bin "$bs_gitbin2c" "$bs_gitlog2c"
bs_home_userfiles="$bs_work/home-userfiles"
mkdir -p "$bs_home_userfiles/subdir"
echo "do not delete me" > "$bs_home_userfiles/my-precious-file.txt"
echo "nested" > "$bs_home_userfiles/subdir/nested.txt"
bs_out2c="$(PATH="$bs_gitbin2c:$PATH" ORCHID_HOME="$bs_home_userfiles" "$bs_work/bare/nogit/install.sh" 2>&1)"
bs_rc2c=$?
[ "$bs_rc2c" -ne 0 ] || fail "bootstrap (unrelated user directory): install.sh must exit nonzero rather than proceed (output: $bs_out2c)"
assert_match "$bs_home_userfiles" "$bs_out2c" "bootstrap (unrelated user directory): refusal message names the exact path"
[ -f "$bs_home_userfiles/my-precious-file.txt" ] || fail "bootstrap (unrelated user directory): user file was deleted -- must be left completely intact"
[ "$(cat "$bs_home_userfiles/my-precious-file.txt")" = "do not delete me" ] || fail "bootstrap (unrelated user directory): user file content was altered"
[ -f "$bs_home_userfiles/subdir/nested.txt" ] || fail "bootstrap (unrelated user directory): nested user file/subdir was deleted -- must be left completely intact"
grep -q '^clone' "$bs_gitlog2c" && fail "bootstrap (unrelated user directory): must never attempt a clone against a refused path"

# --- 2d: the user's own unrelated git repo (real .git, but NOT this
# repo's remote) -> REFUSED: nonzero exit, repo untouched, message names
# the path, no clone attempted. This is the one .git-having-but-wrong
# shape (b) must still catch even though (a) alone would have let it
# through.
bs_gitlog2d="$bs_work/gitlog2d.txt"; : > "$bs_gitlog2d"
bs_gitbin2d="$bs_work/gitbin2d"; fake_git_bin "$bs_gitbin2d" "$bs_gitlog2d"
bs_home_userrepo="$bs_work/home-userrepo"
mkdir -p "$bs_home_userrepo"
git init -q "$bs_home_userrepo"
git -C "$bs_home_userrepo" remote add origin https://example.com/someone-else/unrelated.git
echo "my own project" > "$bs_home_userrepo/README.md"
git -C "$bs_home_userrepo" add README.md
git -C "$bs_home_userrepo" -c user.email=test@example.com -c user.name=test commit -q -m "unrelated user commit"
bs_out2d="$(PATH="$bs_gitbin2d:$PATH" ORCHID_HOME="$bs_home_userrepo" "$bs_work/bare/nogit/install.sh" 2>&1)"
bs_rc2d=$?
[ "$bs_rc2d" -ne 0 ] || fail "bootstrap (user's own git repo): install.sh must exit nonzero rather than proceed (output: $bs_out2d)"
assert_match "$bs_home_userrepo" "$bs_out2d" "bootstrap (user's own git repo): refusal message names the exact path"
[ -f "$bs_home_userrepo/README.md" ] || fail "bootstrap (user's own git repo): user's repo content was deleted -- must be left completely intact"
[ "$(git -C "$bs_home_userrepo" config --get remote.origin.url)" = "https://example.com/someone-else/unrelated.git" ] \
  || fail "bootstrap (user's own git repo): the repo's own remote must be untouched"
grep -q '^clone' "$bs_gitlog2d" && fail "bootstrap (user's own git repo): must never attempt a clone against a refused path"

# --- already-cloned stable: re-fetch the exact version-tag ref, verify that
# its object did not move, and detach at that object without re-cloning.
bs_gitlog_stable="$bs_work/gitlog-stable.txt"; : > "$bs_gitlog_stable"
bs_gitbin_stable="$bs_work/gitbin-stable"; fake_git_bin "$bs_gitbin_stable" "$bs_gitlog_stable"
export STUB_INSTALL_RECORD="$bs_work/record-stable.txt"; rm -f "$bs_work/record-stable.txt"
bs_out_stable="$(PATH="$bs_gitbin_stable:$PATH" ORCHID_HOME="$bs_home" "$bs_work/bare/nogit/install.sh" 2>&1)"
bs_rc_stable=$?
[ "$bs_rc_stable" -eq 0 ] || fail "bootstrap (existing stable clone): install.sh exits 0 (got rc=$bs_rc_stable, output: $bs_out_stable)"
grep -q '^clone' "$bs_gitlog_stable" && fail "bootstrap (existing stable clone): must not re-clone"
assert_match '\-C .* fetch --depth 1 origin refs/tags/v1\.0\.0-beta\.1:refs/tags/v1\.0\.0-beta\.1' "$(cat "$bs_gitlog_stable")" \
  "bootstrap (existing stable clone): fetches only the immutable stable tag"
assert_match '\-C .* checkout --detach 1111111111111111111111111111111111111111' "$(cat "$bs_gitlog_stable")" \
  "bootstrap (existing stable clone): detaches at the verified tag object"
[ -f "$bs_work/record-stable.txt" ] || fail "bootstrap (existing stable clone): cloned installer was not exec'd"

# --- already-cloned development: this starts from the stable clone above,
# which is detached at a tag. Fetch main explicitly and detach at FETCH_HEAD's
# exact commit so switching channels never depends on `git pull` having an
# attached/upstream-configured branch.
bs_gitlog2="$bs_work/gitlog2.txt"; : > "$bs_gitlog2"
bs_gitbin2="$bs_work/gitbin2"; fake_git_bin "$bs_gitbin2" "$bs_gitlog2"
export STUB_INSTALL_RECORD="$bs_work/record2.txt"; rm -f "$bs_work/record2.txt"
bs_out2="$(PATH="$bs_gitbin2:$PATH" ORCHID_HOME="$bs_home" "$bs_work/bare/nogit/install.sh" --channel development 2>&1)"
bs_rc2=$?
[ "$bs_rc2" -eq 0 ] || fail "bootstrap (already cloned): install.sh exits 0 (got rc=$bs_rc2, output: $bs_out2)"
grep -q '^clone' "$bs_gitlog2" && fail "bootstrap (already cloned): must not re-clone an existing checkout ($(cat "$bs_gitlog2"))"
assert_match '\-C .* fetch --depth 1 origin refs/heads/main' "$(cat "$bs_gitlog2")" \
  "bootstrap (already cloned): development channel fetches moving main explicitly"
assert_match '\-C .* checkout --detach 2222222222222222222222222222222222222222' "$(cat "$bs_gitlog2")" \
  "bootstrap (already cloned): development channel detaches at the exact fetched commit"
grep -q 'pull --ff-only' "$bs_gitlog2" \
  && fail "bootstrap (already cloned): development switch must not pull from a detached stable checkout"
[ -f "$bs_work/record2.txt" ] || fail "bootstrap (already cloned): cloned install.sh was never exec'd on the update path"

# --- bootstrap --uninstall: operates against the canonical clone if
# present, never deletes the clone itself, and prints a one-line note
# saying so.
bs_gitlog3="$bs_work/gitlog3.txt"; : > "$bs_gitlog3"
bs_gitbin3="$bs_work/gitbin3"; fake_git_bin "$bs_gitbin3" "$bs_gitlog3"
export STUB_INSTALL_RECORD="$bs_work/record3.txt"; rm -f "$bs_work/record3.txt"
bs_out3="$(PATH="$bs_gitbin3:$PATH" ORCHID_HOME="$bs_home" "$bs_work/bare/nogit/install.sh" --uninstall 2>&1)"
bs_rc3=$?
[ "$bs_rc3" -eq 0 ] || fail "bootstrap (--uninstall, clone present): install.sh exits 0 (got rc=$bs_rc3, output: $bs_out3)"
grep -q '^clone' "$bs_gitlog3" && fail "bootstrap (--uninstall): must not clone just to uninstall"
assert_match "$bs_home" "$bs_out3" "bootstrap (--uninstall): note names the path the clone stays at"
assert_match "not delete|left in place|is not deleted|never delete" "$bs_out3" "bootstrap (--uninstall): note says the clone itself is not removed"
[ -d "$bs_home/.git" ] || fail "bootstrap (--uninstall): the canonical clone must still exist afterward"
[ -f "$bs_work/record3.txt" ] || fail "bootstrap (--uninstall): cloned install.sh was never exec'd"
assert_eq "--uninstall" "$(cat "$bs_work/record3.txt")" "bootstrap (--uninstall): cloned installer exec'd with --uninstall"

# --- bootstrap --uninstall with NO clone present: nothing to clone just to
# tear down, so exit cleanly without ever calling `git clone`.
bs_gitlog4="$bs_work/gitlog4.txt"; : > "$bs_gitlog4"
bs_gitbin4="$bs_work/gitbin4"; fake_git_bin "$bs_gitbin4" "$bs_gitlog4"
bs_home_missing="$bs_work/home-never-cloned"
bs_out4="$(PATH="$bs_gitbin4:$PATH" ORCHID_HOME="$bs_home_missing" "$bs_work/bare/nogit/install.sh" --uninstall 2>&1)"
bs_rc4=$?
[ "$bs_rc4" -eq 0 ] || fail "bootstrap (--uninstall, no clone): install.sh still exits 0 (got rc=$bs_rc4, output: $bs_out4)"
grep -q '^clone' "$bs_gitlog4" && fail "bootstrap (--uninstall, no clone): must not clone when there is nothing to uninstall"
[ -e "$bs_home_missing" ] && fail "bootstrap (--uninstall, no clone): must not create a clone dir as a side effect of --uninstall"
unset STUB_INSTALL_RECORD

# --- inside-checkout path never triggers bootstrap: the real $INSTALL,
# run from $REPO_ROOT (which genuinely has bin/orchid + lib/common.sh
# beside it), must never touch the fake git's clone/pull machinery, even
# with the same fake git stub sitting first on PATH.
bs_gitlog5="$bs_work/gitlog5.txt"; : > "$bs_gitlog5"
bs_gitbin5="$bs_work/gitbin5"; fake_git_bin "$bs_gitbin5" "$bs_gitlog5"
bs_insidecheckout_home="$bs_work/should-never-exist"
insidecheckout_nogit="$bs_work/insidecheckout-nogit"; mkdir -p "$insidecheckout_nogit"
bs_out5="$(cd "$insidecheckout_nogit" && PATH="$bs_gitbin5:$PATH" ORCHID_HOME="$bs_insidecheckout_home" "$INSTALL" 2>&1)"
grep -qE '^clone|fetch --depth|checkout --detach' "$bs_gitlog5" && fail "inside-checkout install.sh must never invoke bootstrap's clone/fetch/checkout (git calls seen: $(cat "$bs_gitlog5"))"
[ -e "$bs_insidecheckout_home" ] && fail "inside-checkout install.sh must never create/touch ORCHID_HOME -- bootstrap must not have triggered"
assert_match "[Nn]ext steps" "$bs_out5" "inside-checkout install.sh (with bootstrap's fake git on PATH) still runs its normal flow, not bootstrap"
