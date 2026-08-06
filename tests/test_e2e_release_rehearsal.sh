#!/usr/bin/env bash
# END-TO-END LOCAL RELEASE REHEARSAL.
#
# One private temporary root holds EVERYTHING this rehearsal touches: HOME,
# XDG_CONFIG_HOME, XDG_DATA_HOME, TMPDIR, ORCHID_HOME, CLAUDE_SKILLS_DIR, the
# install prefix, the plugin/engine search paths, Git's global and system
# config files, and every fixture, worktree, and output path. Nothing outside
# that root may change; the source checkout is read-only input and is proven
# unchanged -- working tree, file listing, HEAD, and remote refs (see step 0c
# for what each snapshot deliberately leaves out, and why watching less is what
# makes the claim mean something on a live machine).
#
# It walks the whole operator story once, with no network and no external
# mutation anywhere:
#
#   1. one-command setup            orchid start
#   2. unattended refusal           pump / tick / service install, all gated
#   3. explicit acknowledgement     orchid trust unattended --reason ...
#   4. beta qualification           scripts/beta-qualify.sh
#   5. deterministic drive          orchid drive, pending -> done, no model
#   6. release checks               scripts/release.sh, positive and negative
#   7. installer wiring             install.sh --prefix ... and --uninstall
#
# PATH TRIPWIRES. Every network tool, vendor CLI, notify sender, package
# manager, and remote-capable git subcommand is shadowed by an executable that
# LOGS and FAILS. At the end the log must be empty. Because bin/orchid pins a
# fixed PATH across each trust-boundary decision before restoring the operator
# PATH, the tripwires cannot cover literally every microsecond of every phase --
# so "no tripwire fired" is backed up by an outcome-level check that needs no
# PATH at all: no remote ref anywhere moved, and nothing outside the root
# changed.
#
# CWD DISCIPLINE (lesson L014 -- "use cd_scratch, never a bare `cd`, in any
# fixture that runs git"). No exception, and nothing to remember: every
# directory change in this file, canonicalisation included, goes through
# tests/helpers.sh's cd_scratch, which refuses an empty path, a
# non-directory, and any path outside a scratch root THIS run created. The
# hazard it exists for is that `cd ""` is a silent bash no-op -- exit 0, cwd
# unchanged -- so an empty scratch root would leave the git work that follows
# pointed at the caller's real checkout.
#
# The rehearsal proper needs no cwd at all: every git call is `git -C
# <absolute path>` and every Orchid verb gets an explicit ORCHID_REPO. Two
# steps change directory, both through cd_scratch:
#
#  * step 0b's tripwire self-test, which INVOKES `git push`, `git fetch`, and
#    the rest of the remote-capable set to prove the shim refuses and logs
#    them. It moves onto a throwaway repository under the private root first,
#    and stays off the caller's checkout for the rest of the file: the shim is
#    what SHOULD stop those commands, but it must not be the only thing that
#    does. See the long note there.
#  * step 7's installer phase, which has to: install.sh ends by offering
#    `orchid doctor` against the CURRENT directory, so from an unrelated cwd
#    that offer would reach outside the private root -- the one thing this
#    rehearsal must not do. It uses `cd_scratch "$R"` inside a `$( ... )`
#    subshell, so the change cannot leak into any later phase.
#
# (The one other `cd` in this file's TEXT is not this file's: it sits inside
# the stub engine adapter written out in step 0d, which Orchid runs as a
# separate process against the worktree named in its own request JSON, exactly
# as a real adapter does.)
#
# RED before this task: scripts/beta-qualify.sh does not exist, so phase 4
# cannot run.
source "$(dirname "$0")/helpers.sh"

QUALIFY="$REPO_ROOT/scripts/beta-qualify.sh"
RELEASE="$REPO_ROOT/scripts/release.sh"
DRIVE="$REPO_ROOT/runners/orchid-drive"
PUMP="$REPO_ROOT/runners/orchid-pump"
TICK="$REPO_ROOT/runners/orchid-tick"
[ -f "$QUALIFY" ] || fail "scripts/beta-qualify.sh missing"
[ -f "$RELEASE" ] || fail "scripts/release.sh missing"

REAL_HOME="$HOME"
REAL_GIT="$(command -v git)" || fail "git is required"
# May legitimately be empty -- a host without openssl is fine, because
# lib/common.sh only reaches for it when `shasum` is absent, and at least one
# of the two exists everywhere this runs. The shim below handles both cases.
REAL_OPENSSL="$(command -v openssl 2>/dev/null || true)"
REAL_TMPDIR="${TMPDIR:-/tmp}"

# ===========================================================================
# 0 -- the one private root, and every environment variable that could
# otherwise let a step reach outside it.
# ===========================================================================
# CAPTURE, CHECK, THEN COMPOSE -- never `R="$(cd_scratch "$WORK" && pwd -P)/rehearsal"`
# in one breath. This suite runs under `set -uo pipefail` WITHOUT -e, so a
# failing assignment halts nothing: cd_scratch dies inside the command
# substitution, the substitution yields the empty string, and R silently becomes
# "/rehearsal" -- every path below then hangs off the real filesystem root and
# the L014 guard this file's header claims to apply is inert. That is the exact
# shape of the bug cd_scratch exists to prevent, reintroduced by composing its
# output before checking its status. `fail` alone would not do either: it only
# counts a FAILS, so the `exit 1` is what actually stops the file. (The FAILS
# increment inside the substitution's subshell is lost with the subshell, which
# is why it is re-counted here.)
scratch_root="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root — refusing to run the rehearsal against an unresolved path"; exit 1; }
R="$scratch_root/rehearsal"
mkdir -p "$R"/{home,tmp,eng,plugins,prefix,out,fixtures}
mkdir -p "$R/home/.config" "$R/home/.local/share" "$R/home/.claude/skills"

export HOME="$R/home"
export XDG_CONFIG_HOME="$R/home/.config"
export XDG_DATA_HOME="$R/home/.local/share"
export TMPDIR="$R/tmp"
export ORCHID_HOME="$R/home/.local/share/orchid"
export CLAUDE_SKILLS_DIR="$R/home/.claude/skills"
export ORCHID_PLUGIN_PATH="$R/plugins"
export ORCHID_ENGINES_DIR="$R/eng"
# Git's global AND system scopes both redirected inside the root, so no
# ambient machine configuration reaches a fixture and no fixture can write one.
export GIT_CONFIG_GLOBAL="$R/gitconfig-global"
export GIT_CONFIG_SYSTEM="$R/gitconfig-system"
: > "$GIT_CONFIG_GLOBAL"
: > "$GIT_CONFIG_SYSTEM"

# ===========================================================================
# 0b -- PATH tripwires.
# ===========================================================================
TRIPWIRE_DIR="$R/tripwire"
TRIPWIRE_LOG="$R/tripwire.log"
mkdir -p "$TRIPWIRE_DIR"
: > "$TRIPWIRE_LOG"

mk_tripwire() {
  local name="$1"
  {
    echo '#!/bin/bash'
    printf 'LOG=%s\n' "$(printf '%q' "$TRIPWIRE_LOG")"
    printf 'printf "%s %%s\\n" "$*" >> "$LOG"\n' "$name"
    printf 'echo "tripwire: %s must never run during the release rehearsal" >&2\n' "$name"
    echo 'exit 97'
  } > "$TRIPWIRE_DIR/$name"
  chmod +x "$TRIPWIRE_DIR/$name"
}

# Network clients, remote copy/shell, vendor engine CLIs, notify senders, and
# package/network tooling. None of these has any business running here.
for tool in curl wget ssh scp sftp rsync nc netcat telnet ftp \
            claude codex agy hermes openclaw \
            npm npx pip pip3 brew apt apt-get yum dnf pacman gem cargo go \
            docker kubectl gh hub aws gcloud az; do
  mk_tripwire "$tool"
done

# git is not shadowed wholesale -- the rehearsal is made of local git work.
# Only the REMOTE-CAPABLE subcommands are refused, and everything else is
# delegated to the real binary. Both paths are baked in as literals because
# scripts/release.sh re-executes git under `env -i`, which wipes the
# environment this shim would otherwise read them from.
{
  echo '#!/bin/bash'
  printf 'LOG=%s\n' "$(printf '%q' "$TRIPWIRE_LOG")"
  printf 'REAL=%s\n' "$(printf '%q' "$REAL_GIT")"
  cat <<'GITSHIM'
ALL_ARGS="$*"
args=("$@")
count="${#args[@]}"
i=0
sub=""
while [ "$i" -lt "$count" ]; do
  a="${args[$i]}"
  case "$a" in
    -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
      i=$((i + 2)); continue ;;
    -*) i=$((i + 1)); continue ;;
    *) sub="$a"; break ;;
  esac
done
next=""
if [ $((i + 1)) -lt "$count" ]; then next="${args[$((i + 1))]}"; fi
refuse() {
  printf 'git %s [%s]\n' "$1" "$ALL_ARGS" >> "$LOG"
  echo "tripwire: git $1 must never run during the release rehearsal" >&2
  exit 97
}
case "$sub" in
  push|fetch|pull|clone|ls-remote|send-pack|receive-pack|upload-pack|upload-archive|request-pull|http-push|http-fetch|daemon)
    refuse "$sub" ;;
  remote)
    case "$next" in update|add|set-url|prune) refuse "remote $next" ;; esac ;;
  submodule)
    case "$next" in update|init|sync|add) refuse "submodule $next" ;; esac ;;
esac
exec "$REAL" "$@"
GITSHIM
} > "$TRIPWIRE_DIR/git"
chmod +x "$TRIPWIRE_DIR/git"

# openssl is not shadowed wholesale either, and for a reason that is easy to
# miss: it is a network client (`s_client`, `s_server`, `s_time`, `ocsp`, `ts`)
# AND this repository's documented digest fallback. lib/common.sh's
# `_orchid_file_sha256`/`_orchid_symlink_sha256`/`_orchid_stream_sha256` each
# use `shasum -a 256` when it exists and `openssl dgst -sha256` when it does
# not -- so a blanket openssl tripwire would report "the rehearsal contacted
# the network" on any host without shasum, when what actually happened was
# plugin_digest taking the fallback the code says it may take. A tripwire that
# fires on documented, entirely local behaviour teaches operators to ignore
# tripwire output, which is worse than not having one. So: the remote-capable
# subcommands are refused and logged exactly as before, and everything else --
# `dgst` above all -- is delegated to the real binary. Literal paths, same
# `env -i` reason as the git shim.
{
  echo '#!/bin/bash'
  printf 'LOG=%s\n' "$(printf '%q' "$TRIPWIRE_LOG")"
  printf 'REAL=%s\n' "$(printf '%q' "$REAL_OPENSSL")"
  cat <<'SSLSHIM'
ALL_ARGS="$*"
sub=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *) sub="$a"; break ;;
  esac
done
refuse() {
  printf 'openssl %s [%s]\n' "$1" "$ALL_ARGS" >> "$LOG"
  echo "tripwire: openssl $1 must never run during the release rehearsal" >&2
  exit 97
}
case "$sub" in
  s_client|s_server|s_time|ocsp|ts) refuse "$sub" ;;
esac
# No real openssl on this host: nothing local to delegate to. Refusing (rather
# than exiting 0) keeps a would-be caller's failure visible instead of handing
# it a silently empty digest.
if [ -z "$REAL" ]; then
  echo "tripwire: openssl is not installed on this host" >&2
  exit 127
fi
exec "$REAL" "$@"
SSLSHIM
} > "$TRIPWIRE_DIR/openssl"
chmod +x "$TRIPWIRE_DIR/openssl"

# Kept so the tripwires can be stood down once the rehearsal is over. They
# live INSIDE the root and therefore stop existing the moment cleanup removes
# it, so the post-cleanup snapshots -- which are instrumentation, not part of
# the rehearsal -- must not still be looking for them (step 9).
ORIGINAL_PATH="$PATH"
export PATH="$TRIPWIRE_DIR:$PATH"
[ "$(command -v curl)" = "$TRIPWIRE_DIR/curl" ] || fail "the curl tripwire is not first on PATH"
[ "$(command -v git)" = "$TRIPWIRE_DIR/git" ] || fail "the git tripwire is not first on PATH"

# ---------------------------------------------------------------------------
# The self-test's GROUND, before any of the self-test itself.
#
# What follows invokes the real shapes -- `git push`, `git fetch`, `git pull`,
# `git clone`, `git ls-remote origin`, `git remote update`, `git submodule
# update`, `git send-pack` -- because an empty tripwire log at step 8 means
# "nothing ran" only if the tripwires are known to fire AND to log. That is the
# right design and it stays. But it decides WHERE it stands from, and the
# obvious place is wrong: this file runs from the operator's live checkout,
# which has a real `origin`. Standing there, the only thing between `git push`
# and that remote is the PATH assertion two lines above. One assertion is a
# fine check and a poor floor, and this is the file that certifies "never
# contact a remote" for the whole build -- the shape of the guarantee matters
# as much as the outcome, because an operator reading it has to be able to see
# that it holds without having to trust the shim first.
#
# So the self-test runs from a throwaway repository created here, inside the
# private root, with no remote and no history. If the shim were removed
# outright, every command below would reach a scratch directory with nothing
# to push to, nothing to fetch from, and no `origin` to resolve -- the failure
# mode of a total shim failure is "a scratch repo declines", not "the
# operator's work is published". Real git creates it (`init` is not a refused
# subcommand, but setup must not depend on the thing under test), and the
# no-remote property is asserted through real git too, for the same reason.
# ---------------------------------------------------------------------------
SELFTEST_REPO="$R/tripwire-selftest"
mkdir -p "$SELFTEST_REPO"
"$REAL_GIT" -C "$SELFTEST_REPO" init -q >/dev/null 2>&1 \
  || fail "cannot create the disposable repository the tripwire self-test stands on"
selftest_remotes="$("$REAL_GIT" -C "$SELFTEST_REPO" remote 2>/dev/null)"
[ -z "$selftest_remotes" ] \
  || fail "the tripwire self-test repository must have no remote, got '$selftest_remotes'"
# cd_scratch, not `cd` (L014): it refuses an empty path and anything outside a
# root this run created, so the self-test cannot silently end up running from
# the caller's checkout after all -- which is the entire point of moving it.
cd_scratch "$SELFTEST_REPO"
# Belt and braces: ask git itself which repository the following commands would
# act on, and refuse to run them anywhere but the throwaway one. Compared
# against "$SELFTEST_REPO" as-is, with no second canonicalisation step: "$R"
# hangs off a `pwd -P` result, so this path is already physical, and git's own
# answer comes from getcwd(), which is physical too. (A bare `cd` to
# re-canonicalise here would be exactly the L014 violation the header forbids.)
selftest_toplevel="$("$REAL_GIT" rev-parse --show-toplevel 2>/dev/null)"
[ "$selftest_toplevel" = "$SELFTEST_REPO" ] \
  || fail "the tripwire self-test must run against its throwaway repository ($SELFTEST_REPO), not '$selftest_toplevel'"

# The git shim must be transparent for ordinary local work, or every phase
# below would be testing the shim rather than Orchid.
git --version >/dev/null 2>&1 || fail "the git tripwire broke ordinary 'git --version'"
# Prove both tripwire shapes really fail AND really log, so the empty-log
# assertion at the end means "nothing ran", not "nothing was ever recorded".
tripwire_rc=0
curl https://example.invalid >/dev/null 2>&1 || tripwire_rc=$?
assert_eq 97 "$tripwire_rc" "a network-tool tripwire must fail"
grep -qF 'curl https://example.invalid' "$TRIPWIRE_LOG" || fail "a network-tool tripwire must LOG its invocation"
tripwire_rc=0
git ls-remote origin >/dev/null 2>&1 || tripwire_rc=$?
assert_eq 97 "$tripwire_rc" "the git tripwire must refuse a remote-capable subcommand"
grep -qF 'git ls-remote' "$TRIPWIRE_LOG" || fail "the git tripwire must LOG the refused subcommand"
for remote_sub in push fetch pull clone; do
  tripwire_rc=0
  git "$remote_sub" >/dev/null 2>&1 || tripwire_rc=$?
  assert_eq 97 "$tripwire_rc" "the git tripwire must refuse 'git $remote_sub'"
done
tripwire_rc=0
git remote update >/dev/null 2>&1 || tripwire_rc=$?
assert_eq 97 "$tripwire_rc" "the git tripwire must refuse 'git remote update'"
tripwire_rc=0
git submodule update >/dev/null 2>&1 || tripwire_rc=$?
assert_eq 97 "$tripwire_rc" "the git tripwire must refuse 'git submodule update'"
tripwire_rc=0
git send-pack >/dev/null 2>&1 || tripwire_rc=$?
assert_eq 97 "$tripwire_rc" "the git tripwire must refuse 'git send-pack'"
# The openssl shim, both halves. The refusal half is a tripwire like any other;
# the delegation half is what stops this rehearsal from failing on a host that
# has no shasum and therefore takes lib/common.sh's documented openssl fallback.
[ "$(command -v openssl)" = "$TRIPWIRE_DIR/openssl" ] || fail "the openssl tripwire is not first on PATH"
tripwire_rc=0
openssl s_client -connect example.invalid:443 >/dev/null 2>&1 || tripwire_rc=$?
assert_eq 97 "$tripwire_rc" "the openssl tripwire must refuse a network subcommand"
grep -qF 'openssl s_client' "$TRIPWIRE_LOG" || fail "the openssl tripwire must LOG the refused subcommand"
if [ -n "$REAL_OPENSSL" ]; then
  ssl_digest="$(printf 'rehearsal\n' | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  assert_match '^[0-9a-f]{64}$' "$ssl_digest" \
    "the openssl shim must pass 'dgst' through to the real binary -- lib/common.sh falls back to it when shasum is absent"
  grep -qF 'openssl dgst' "$TRIPWIRE_LOG" \
    && fail "the openssl shim logged a local 'dgst' as a tripwire hit -- the documented shasum fallback would read as a network contact"
fi
: > "$TRIPWIRE_LOG"
# Off the self-test ground, and NOT back to the caller's checkout: the
# rehearsal proper needs no cwd (every git call is `git -C <absolute path>`,
# every verb gets an explicit ORCHID_REPO), so the safest place to leave it is
# the scratch root -- a plain directory with no repository above it, where an
# accidental bare `git` finds nothing rather than the operator's work. Not
# "$R" itself: step 9 removes that while snapshots are still running, and a
# process whose cwd has been deleted is a confusing way to fail.
cd_scratch "$scratch_root"

# ===========================================================================
# 0c -- outside-the-root snapshots. Taken AFTER the root exists so the root
# itself is already accounted for, and re-taken at the very end.
#
# Both are deliberately NARROW, for the same reason. This suite runs from a
# live Orchid worktree, under an outer run that writes its own state while the
# tests execute, on an operator's real machine. A snapshot that walked either
# wholesale would report the CALLER's bookkeeping -- a lease refresh, a branch
# another worktree moved, a skill some other tool installed -- as a rehearsal
# that touched what it must not; and to prove it never wrote a trust record it
# would have to READ the operator's real ones, which a harness whose whole
# promise is "nothing outside the private root is touched" has no business
# doing. So each snapshot watches only what this rehearsal could itself
# change, at names this file can write down in advance.
# ===========================================================================
# Captured and checked before use, for the reason spelled out at step 0: an
# unchecked substitution here would leave WORKP empty and point every snapshot
# below at the filesystem root.
WORKP="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root — refusing to snapshot an unresolved path"; exit 1; }
list_names() {
  if [ ! -e "$1" ]; then printf 'ABSENT %s\n' "$1"; return 0; fi
  find "$1" 2>/dev/null | LC_ALL=C sort
}
# Everything the rehearsal creates must land UNDER the root, never beside it.
# The root's own entry is excluded because step 9 deletes it on purpose, and a
# snapshot that counted it could not tell "cleanup worked" from "something
# moved".
sibling_entries() {
  list_dir_entries "$WORKP" | grep -vxF rehearsal | LC_ALL=C sort
}
# On mismatch, report only the differing lines: a whole-tree snapshot is far
# too large to read as a raw assertion message.
assert_snapshot_unchanged() {
  local label="$1" before="$2" after="$3" delta
  [ "$before" = "$after" ] && return 0
  # Process substitution, not temporary files: a scratch file written here
  # would itself show up in the very listing this function is comparing.
  # `sed -n '1,40p'` rather than `head`, which would SIGPIPE diff under the
  # pipefail this suite runs with.
  delta="$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed -n '1,40p')"
  fail "$label -- changed:
$delta"
}
# The source checkout is read-only input. Three questions, each scoped to
# something this rehearsal actually controls:
#
#  * WORKING TREE -- git's own porcelain, `.orchid` excluded. That directory
#    is the OUTER run's live state (its journal, task records, and runtime
#    lease), rewritten by the kernel that invoked this suite while the suite
#    runs, so including it makes the caller's own progress look like damage.
#    It is not a channel this rehearsal can write through either: every verb
#    it runs is handed an explicit ORCHID_REPO under the private root, and no
#    step ever names the source checkout as a repository.
#  * REFS -- REMOTE refs only, which is exactly the promise ("no remote ref
#    moved") and the only part of the ref namespace nothing local can disturb.
#    Local branches live in a Git common directory shared with every other
#    worktree of this checkout, so an outer commit or merge moves them mid-run
#    through no act of this file's. HEAD is kept: it answers "did anything
#    commit into the checkout under test".
#  * NAMES -- the file listing with `.git` and `.orchid` pruned, which catches
#    a file created or removed beside the checkout's own content.
snapshot_source() {
  git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all -- ':!.orchid'
  echo "--remote-refs--"
  git -C "$REPO_ROOT" for-each-ref --format='%(refname) %(objectname)' refs/remotes
  echo "--head--"
  git -C "$REPO_ROOT" rev-parse HEAD
  echo "--names--"
  find "$REPO_ROOT" -name .git -prune -o -name .orchid -prune -o -print 2>/dev/null \
    | LC_ALL=C sort
}
# path_state <path> -- one token from a closed set, and nothing about what a
# directory CONTAINS. A path this process cannot even test reads `absent` both
# times, which is honest: a path unreachable to this uid is one the rehearsal
# could not have created either. Symlink first, because that is what install.sh
# makes and a symlink to a directory would otherwise read `dir`.
path_state() {
  # Every value quoted: `state=file` and `state=dir` are bare words that name
  # real commands, which ShellCheck reads as an attempt to capture their output
  # (SC2209). Quoting says "string", which is what is meant, and keeps the
  # zero-warning gate green.
  local p="$1" state="absent"
  if   [ -L "$p" ]; then state="symlink"
  elif [ -d "$p" ]; then state="dir"
  elif [ -f "$p" ]; then state="file"
  elif [ -e "$p" ]; then state="other"
  fi
  printf '%s %s\n' "$state" "$p"
}
# Machine-local state a step could reach if one of the isolation variables
# above failed to take. Every path here is one ORCHID ITSELF creates, at a name
# this file writes down in advance: the skill symlinks install.sh wires
# (install.sh:225-334), the entry point it links into its default prefix
# (install.sh:228), the per-user config and data directories, the machine-local
# trust store (lib/trust.sh), and the launch-agent directory a service install
# would write into (runners/orchid-service). Nothing here enumerates, recurses
# into, or reads what the operator already has, and no line changes when
# another process writes inside one of these directories -- ~/.claude/skills
# and ~/.orchid genuinely are written by other tools while this runs.
#
# The blind spot a per-path state leaves is a NEW entry inside a directory the
# operator already has. The only such entry this rehearsal could produce is an
# unattended-trust record, whose name is derivable -- step 3 derives it, proves
# the derivation against the isolated store, and watches that one path in the
# operator's store across the acknowledgement, without listing either store.
snapshot_machine() {
  local name
  for name in orchid orchid-plan orchid-resume; do
    path_state "$REAL_HOME/.claude/skills/$name"
    path_state "$REAL_HOME/.hermes/skills/orchestration/$name"
  done
  # The containers too, so a machine that has neither front end still catches
  # an install.sh that created one.
  path_state "$REAL_HOME/.claude/skills"
  path_state "$REAL_HOME/.hermes/skills/orchestration"
  path_state "$REAL_HOME/.openclaw"
  path_state "$REAL_HOME/.local/bin/orchid"
  path_state "$REAL_HOME/.orchid"
  path_state "$REAL_HOME/.orchid/unattended-trust"
  path_state "$REAL_HOME/.config/orchid"
  path_state "$REAL_HOME/.local/share/orchid"
  path_state "$REAL_HOME/Library/LaunchAgents"
  echo "--siblings--"
  sibling_entries
  echo "--machine-home--"
  list_names "$MACHINE_HOME"
}
SOURCE_BEFORE="$(snapshot_source)"
MACHINE_BEFORE="$(snapshot_machine)"

# ===========================================================================
# 0d -- stub engines. No vendor CLI is reachable (each is a tripwire), so the
# rehearsal runs real adapters that are stubs, exactly as the other end-to-end
# suites do.
# ===========================================================================
mkdir -p "$R/eng/stubimpl" "$R/eng/stubreview"
printf 'manifest_version=1\nid=test/stubimpl\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$R/eng/stubimpl/plugin.conf"
printf 'manifest_version=1\nid=test/stubreview\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=structured_text\nrequires_binaries=jq\nentrypoint=run\n' \
  > "$R/eng/stubreview/plugin.conf"

cat > "$R/eng/stubimpl/run" <<'STUBIMPL'
#!/usr/bin/env bash
set -eu
req="$1"
worktree="$(jq -r .worktree "$req")"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
[ "$op" = implement ] || exit 1
cd "$worktree" || exit 1
echo "rehearsal implementation for $task" > rehearsal_feature.txt
git add rehearsal_feature.txt
git -c user.email=stub@example.invalid -c user.name="stub" commit -q -m "stub: implement $task"
sha="$(git rev-parse HEAD)"
jq -n --arg jid "$jid" --arg task "$task" --arg sha "$sha" \
  '{contract:1, job_id:$jid, task:$task, operation:"implement", status:"ok",
    summary:"stub implemented", commits:[$sha]}' > "$out"
STUBIMPL
chmod +x "$R/eng/stubimpl/run"

cat > "$R/eng/stubreview/run" <<'STUBREVIEW'
#!/usr/bin/env bash
set -eu
req="$1"
out="$(jq -r .output "$req")"
jid="$(jq -r .job_id "$req")"
task="$(jq -r .task "$req")"
op="$(jq -r .operation "$req")"
cand="$(jq -r .candidate_sha "$req")"
[ "$op" = review ] || exit 1
jq -n --arg jid "$jid" --arg task "$task" --arg cand "$cand" \
  '{contract:1, job_id:$jid, task:$task, operation:"review", status:"ok",
    verdict:"approve", scope_complete:true, summary:"stub review",
    candidate_sha:$cand, findings:[]}' > "$out"
STUBREVIEW
chmod +x "$R/eng/stubreview/run"

ROLE_LINES='role.orchestrator=stubreview
role.implementer=stubimpl
role.reviewer=stubreview
role.arbiter=stubreview
role.plan_critic=stubreview'

mk_project() {  # <dir>
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s\n' "$ROLE_LINES" > "$repo/orchid.config"
  printf 'print("hello")\n' > "$repo/app.py"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "fixture: project and orchid.config"
}

REQ="$R/fixtures/requirements.md"
cat > "$REQ" <<'EOF'
# Requirements

## Goal
Rehearse the release without touching anything outside the private root.

## Acceptance criteria
- rehearsal_feature.txt reaches the integration branch
EOF

# ===========================================================================
# 1 -- ONE-COMMAND SETUP. orchid start replaces doctor + init + worktree add +
# epoch export + requirements import.
# ===========================================================================
PROJ="$R/fixtures/proj"
mk_project "$PROJ"
start_rc=0
start_out="$(ORCHID_REPO="$PROJ" "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" || start_rc=$?
assert_eq 0 "$start_rc" "orchid start must set up a clean configured repository in one command: $start_out"
WT="$R/fixtures/proj-orchid"
assert_match "^integration worktree: $WT \(created\)$" "$start_out" \
  "start reports the integration worktree it created"
assert_match "^epoch: 0 \(created\)$" "$start_out" "start reports the epoch it created"
assert_match "^requirements: imported from $REQ$" "$start_out" "start reports the requirements import"
assert_match "^unattended trust: untrusted" "$start_out" \
  "one-command setup must not silently opt a repository into unattended execution"
[ -d "$WT/.orchid" ] || fail "start must create the integration worktree"
grep -q '^verify=true$' "$WT/orchid.config" \
  || fail "start records the operator-supplied verification command"

# ===========================================================================
# 2 -- UNATTENDED REFUSAL. Every headless surface is gated, and each says so
# actionably. Service installation is exercised with --dry-run, which is gated
# identically and cannot reach launchctl or crontab even if the gate failed.
# ===========================================================================
# The gate is evaluated against the integration checkout, which is where a
# headless surface actually runs: it is the checkout that carries the run
# state the pump and tick need before they ever reach the gate.
assert_refused() {  # <label> <needle> <cmd...>
  local label="$1" needle="$2"; shift 2
  local out rc=0
  out="$(ORCHID_REPO="$WT" "$@" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: an unacknowledged repository must be refused, got exit 0: $out"
  case "$out" in
    *"$needle"*) ;;
    *) fail "$label: refusal did not name its reason ('$needle' absent): $out" ;;
  esac
  case "$out" in
    *"orchid trust unattended"*) ;;
    *) fail "$label: refusal must tell the operator exactly how to acknowledge: $out" ;;
  esac
}
assert_refused "unattended pump" "unattended pump refused" "$BASH" "$PUMP"
assert_refused "headless tick" "headless tick refused" "$BASH" "$TICK"
assert_refused "service install" "service installation refused" \
  "$ORCHID_BIN" service install --dry-run
[ -e "$HOME/Library/LaunchAgents" ] \
  && fail "a refused service installation must not create a launch-agent directory"

# Read-only and interactive work stays available on an unacknowledged repo:
# the gate exists for headless execution, not for looking at a repository.
ORCHID_REPO="$WT" "$ORCHID_BIN" status >/dev/null 2>&1 \
  || fail "the trust gate must not affect ordinary read-only commands"

# ===========================================================================
# 3 -- EXPLICIT ACKNOWLEDGEMENT, WITH A REASON. No reason, no acknowledgement.
# ===========================================================================
# lib/trust.sh keys a record by the filesystem identity of the target's Git
# common directory (<device>-<inode>.json), so the name this acknowledgement
# will use is derivable BEFORE it happens. That is what lets the machine
# snapshot stay out of the operator's real store: instead of listing what is
# there, this watches the one name the rehearsal could add, from before the
# first acknowledgement attempt to after the successful one. Watching the state
# rather than asserting absence also survives the operator already having a
# record under that name -- inodes are recycled, and a stale record for a
# repository that no longer exists is not this rehearsal's doing.
fs_identity() {  # <path> -> "<device>-<inode>", exactly lib/trust.sh's key
  local out
  out="$(stat -f '%d %i' "$1" 2>/dev/null)" || out="$(stat -c '%d %i' "$1" 2>/dev/null)" || return 1
  case "$out" in ""|*[!0-9\ ]*) return 1 ;; esac
  printf '%s-%s\n' "${out%% *}" "${out#* }"
}
TRUST_KEY="$(fs_identity "$PROJ/.git")" \
  || fail "cannot derive the trust record name for the rehearsal fixture"
REAL_RECORD="$REAL_HOME/.orchid/unattended-trust/$TRUST_KEY.json"
REAL_RECORD_BEFORE="$(path_state "$REAL_RECORD")"

noreason_rc=0
"$ORCHID_BIN" trust unattended "$WT" >/dev/null 2>&1 || noreason_rc=$?
[ "$noreason_rc" -ne 0 ] || fail "acknowledgement without --reason must be refused"
[ -d "$HOME/.orchid/unattended-trust" ] \
  && fail "a refused acknowledgement must not create the machine-local trust store"

ACK_REASON="release rehearsal on a disposable local fixture; no remote is configured"
ack_rc=0
ack_out="$("$ORCHID_BIN" trust unattended "$WT" --reason "$ACK_REASON" 2>&1)" || ack_rc=$?
assert_eq 0 "$ack_rc" "an explicit acknowledgement with a reason must succeed: $ack_out"
show_out="$("$ORCHID_BIN" trust show "$WT" 2>&1)"
assert_match "^gate: allowed$" "$show_out" "the gate opens only after the operator acknowledges"
case "$show_out" in
  *"$ACK_REASON"*) ;;
  *) fail "the acknowledgement must record the operator's own reason verbatim: $show_out" ;;
esac
[ -d "$HOME/.orchid/unattended-trust" ] \
  || fail "the acknowledgement record must live in the machine-local store, outside the repository"

# One acknowledgement covers the repository, not a path: the main checkout and
# its linked integration worktree share a Git common directory and therefore
# one record.
proj_show="$("$ORCHID_BIN" trust show "$PROJ" 2>&1)"
assert_match "^gate: allowed$" "$proj_show" \
  "a linked worktree and its main checkout share one acknowledgement"

# It really is machine-local: nothing about it was written into the repository.
[ -e "$WT/.orchid/unattended-trust" ] \
  && fail "unattended trust must never be recorded inside the target repository"

# ...and it landed in the ISOLATED store under the derived name. The POSITIVE
# half comes first, and is what keeps the negative half honest: a derivation
# that had drifted from lib/trust.sh's would otherwise leave the check below
# watching a name nothing ever writes, and passing forever.
[ -f "$HOME/.orchid/unattended-trust/$TRUST_KEY.json" ] \
  || fail "the acknowledgement is not recorded where lib/trust.sh keys it ($TRUST_KEY.json): this file's derivation has drifted from the kernel's, so the operator-store check proves nothing"
assert_eq "$REAL_RECORD_BEFORE" "$(path_state "$REAL_RECORD")" \
  "an acknowledgement for a rehearsal fixture must not appear in the operator's own machine-local trust store"

# ===========================================================================
# 4 -- BETA QUALIFICATION against the integration checkout, with its evidence
# written under the private root.
# ===========================================================================
QUAL_OUT="$R/out/qualification"
qual_rc=0
qual_stdout="$("$BASH" "$QUALIFY" --repo "$WT" --output "$QUAL_OUT" \
  --label rehearsal --bash "$BASH" --verify-timeout-s 60 2>&1)" || qual_rc=$?
assert_eq 0 "$qual_rc" "the rehearsal fixture must qualify: $qual_stdout"
QUAL_JSON="$QUAL_OUT/qualification.json"
[ -f "$QUAL_JSON" ] || fail "beta qualification emitted no JSON evidence"
assert_eq qualified "$(jq -r .verdict "$QUAL_JSON")" "the rehearsal fixture's qualification verdict"
assert_eq allowed "$(jq -r '[.probes[] | select(.id == "unattended-gate")][0].result
                            | if contains("gate reads '\''allowed'\''") then "allowed" else "other" end' "$QUAL_JSON")" \
  "qualification reports the acknowledged gate it actually read, rather than a state it assumed"
# The rehearsal must not let a qualification run claim what it never tested.
[ "$(jq '.not_certified | length' "$QUAL_JSON")" -ge 2 ] \
  || fail "qualification must enumerate what it did not test"

# ===========================================================================
# 5 -- DETERMINISTIC DRIVE. A separate fixture walks pending -> done under
# `orchid drive` alone, with no model anywhere in the loop.
# ===========================================================================
DRIVEN="$R/fixtures/driven"
mk_project "$DRIVEN"
export ORCHID_REPO="$DRIVEN"
init_rc=0
init_out="$("$ORCHID_BIN" init 2>&1)" || init_rc=$?
assert_eq 0 "$init_rc" "orchid init on the drive fixture: $init_out"
git -C "$DRIVEN" checkout -q orchid/integration \
  || fail "the drive fixture must be able to check out the integration branch"
ORCHID_EPOCH="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
export ORCHID_EPOCH
"$ORCHID_BIN" requirements import "$REQ" >/dev/null || fail "requirements import"
"$ORCHID_BIN" task create T001 "deterministic rehearsal task" >/dev/null || fail "task create"
"$ORCHID_BIN" task set T001 verification_commands "test -f rehearsal_feature.txt" >/dev/null \
  || fail "task set verification_commands"
"$ORCHID_BIN" plan apply --reason "rehearsal plan" >/dev/null || fail "plan apply"

status_of() { "$ORCHID_BIN" task show "$1" | grep '^status: ' | cut -d' ' -f2; }
DRIVE_RC=0
DRIVE_OUT=""
drive_until_done() {
  local i=0
  while [ "$i" -lt 40 ]; do
    DRIVE_RC=0
    DRIVE_OUT="$("$BASH" "$DRIVE" 2>&1)" || DRIVE_RC=$?
    [ "$(status_of T001)" = "done" ] && return 0
    [ "$DRIVE_RC" -ne 0 ] && return 1
    i=$((i + 1))
    sleep 0.3
  done
  return 1
}
drive_until_done \
  || fail "the deterministic driver must walk T001 to done with no model in the loop (rc=$DRIVE_RC, output: $DRIVE_OUT)"
assert_eq "done" "$(status_of T001)" "T001 reached done under deterministic passes alone"
git -C "$DRIVEN" show "orchid/integration:rehearsal_feature.txt" >/dev/null 2>&1 \
  || fail "the integration branch must carry the commit the stub implementer made"
unset ORCHID_REPO ORCHID_EPOCH

# ===========================================================================
# 6 -- RELEASE CHECKS. A synthetic, self-contained release fixture, built
# inside the root and never cloned (clone is a tripwire). The real
# scripts/release.sh runs against it: once for a clean tagged commit, then for
# the failures the release gate exists to catch.
# ===========================================================================
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
write_formula() {  # <repo> <version> <sha>
  cat > "$1/Formula/orchid.rb" <<EOF
class Orchid < Formula
  url "https://github.com/bilal-/orchid/releases/download/v$2/orchid-$2.tar.gz"
  sha256 "$3"
  version "$2"
end
EOF
}
mk_release_fixture() {  # <dir>
  local fx="$1"
  mkdir -p "$fx"/{Formula,bin,docs,lib,release,scripts,.orchid}
  cp "$RELEASE" "$fx/scripts/release.sh"
  printf '/.orchid export-ignore\n/Formula export-ignore\n' > "$fx/.gitattributes"
  cat > "$fx/release/metadata.conf" <<'EOF'
version=1.2.3
tag=v1.2.3
archive=orchid-1.2.3.tar.gz
prefix=orchid-1.2.3/
installer_ref=v1.2.3
EOF
  printf '#!/usr/bin/env bash\nORCHID_VERSION="1.2.3"\n' > "$fx/lib/common.sh"
  cat > "$fx/install.sh" <<'EOF'
#!/usr/bin/env bash
ORCHID_INSTALL_VERSION="1.2.3"
ORCHID_INSTALL_REF="v1.2.3"
ORCHID_INSTALL_REPOSITORY="https://github.com/bilal-/orchid.git"
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/bin/orchid"
  # The archive's own CI entry point is a stub here: this phase qualifies the
  # RELEASE GATE, and the full suite already runs the real one.
  cat > "$fx/scripts/ci-local.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "${ORCHID_RELEASE_ARCHIVE_TEST:-0}" = 1 ]
[ "$1" = --bash ]
[ -x "$2" ]
[ ! -e .git ]
[ ! -e .orchid ]
[ ! -e Formula ]
[ -f release/metadata.conf ]
echo "archive fixture CI PASS"
EOF
  printf '# Release fixture\n' > "$fx/README.md"
  printf '# Install fixture\n' > "$fx/docs/install.md"
  printf '# Quickstart fixture\n' > "$fx/docs/quickstart.md"
  printf 'private run state\n' > "$fx/.orchid/private"
  write_formula "$fx" 1.2.3 "0000000000000000000000000000000000000000000000000000000000000000"
  git -C "$fx" init -q
  git -C "$fx" add -A
  git -C "$fx" commit -q -m "fixture payload"
  # Formula/ is export-ignored, so pinning its checksum cannot change the
  # archive it describes -- pin it, commit, then tag the fixed point.
  local probe
  probe="$R/out/release-probe-$(basename "$fx").tar.gz"
  git -C "$fx" archive --format=tar.gz --mtime=1970-01-01T00:00:00Z \
    --prefix=orchid-1.2.3/ --output="$probe" 'HEAD^{tree}'
  write_formula "$fx" 1.2.3 "$(sha256_file "$probe")"
  git -C "$fx" add -A
  git -C "$fx" commit -q -m "pin formula checksum"
  git -C "$fx" tag v1.2.3
}

RELFIX="$R/fixtures/relfix"
mk_release_fixture "$RELFIX"
rel_rc=0
rel_out="$("$BASH" "$RELFIX/scripts/release.sh" --tag v1.2.3 \
  --output "$R/out/release" --bash "$BASH" 2>&1)" || rel_rc=$?
assert_eq 0 "$rel_rc" "the release gate must accept a clean, tagged, metadata-consistent tree: $rel_out"
assert_match "release verified: v1.2.3" "$rel_out" "the release gate names the tag it verified"
[ -f "$R/out/release/orchid-1.2.3.tar.gz" ] || fail "no release archive was emitted"
[ -f "$R/out/release/orchid-1.2.3.tar.gz.sha256" ] || fail "no release checksum was emitted"

assert_release_refusal() {  # <label> <needle> <repo> <tag>
  local label="$1" needle="$2" repo="$3" tag="$4" out rc=0
  out="$("$BASH" "$repo/scripts/release.sh" --tag "$tag" \
    --output "$R/out/release-$label" --bash "$BASH" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "$label: the release gate accepted what it must refuse"
  case "$out" in
    *"$needle"*) ;;
    *) fail "$label: refusal did not name its reason ('$needle' absent): $out" ;;
  esac
}
assert_release_refusal moving-ref "moving refs" "$RELFIX" main
assert_release_refusal missing-tag "does not exist" "$RELFIX" v9.9.9
printf 'dirty\n' > "$RELFIX/untracked"
assert_release_refusal dirty "clean" "$RELFIX" v1.2.3
rm -f "$RELFIX/untracked"

# A release-facing placeholder must fail the gate. Built as its own fixture,
# because cloning one is exactly what the tripwires forbid.
PLACEHOLDER="$R/fixtures/relfix-placeholder"
mk_release_fixture "$PLACEHOLDER"
printf '<!-- SCREENSHOT: missing evidence -->\n' >> "$PLACEHOLDER/README.md"
git -C "$PLACEHOLDER" add -A
git -C "$PLACEHOLDER" commit -q -m "plant a release-facing placeholder"
git -C "$PLACEHOLDER" tag -f v1.2.3 >/dev/null
assert_release_refusal placeholder "placeholder" "$PLACEHOLDER" v1.2.3

# Nothing in the release phase may publish. The gate's own contract is that it
# writes only into --output, so the fixture repositories must be untouched.
[ -z "$(git -C "$RELFIX" status --porcelain=v1 --untracked-files=all)" ] \
  || fail "the release gate must leave its source repository clean"

# ===========================================================================
# 7 -- INSTALLER WIRING, entirely inside the root: prefix, skills dir, and the
# reversal. Run from this checkout, so install.sh never reaches its
# clone-a-canonical-copy bootstrap.
# ===========================================================================
# Run from inside the root. install.sh ends by offering to run `orchid doctor`
# against the CURRENT directory when that directory is a repository other than
# its own source checkout -- from an unrelated cwd that would reach outside the
# root, which is the one thing this rehearsal must not do. cd_scratch, not a
# bare `cd`: it checks the target against the roots this run created, so the
# only directory this file ever moves into is one it owns.
inst_rc=0
inst_out="$( cd_scratch "$R" && "$BASH" "$REPO_ROOT/install.sh" --prefix "$R/prefix" 2>&1 )" || inst_rc=$?
assert_eq 0 "$inst_rc" "install.sh must wire an isolated prefix without touching a network: $inst_out"
[ -L "$R/prefix/bin/orchid" ] || fail "install.sh must link the orchid entry point into the prefix"
[ -L "$CLAUDE_SKILLS_DIR/orchid" ] || fail "install.sh must wire the skills directory it was pointed at"
uninst_rc=0
uninst_out="$( cd_scratch "$R" && "$BASH" "$REPO_ROOT/install.sh" --prefix "$R/prefix" --uninstall 2>&1 )" || uninst_rc=$?
assert_eq 0 "$uninst_rc" "install.sh --uninstall must reverse cleanly: $uninst_out"
[ -e "$R/prefix/bin/orchid" ] && fail "--uninstall must remove the symlink it created"
[ -e "$CLAUDE_SKILLS_DIR/orchid" ] && fail "--uninstall must remove the skill symlink it created"

# ===========================================================================
# 8 -- THE WHOLE POINT: no tripwire fired, no remote ref moved, and nothing
# outside the private root changed.
# ===========================================================================
if [ -s "$TRIPWIRE_LOG" ]; then
  fail "a network, vendor, package, or remote-capable git tripwire fired: $(cat "$TRIPWIRE_LOG")"
fi

# Remote refs, checked at the outcome level so the answer does not depend on
# PATH at all: no fixture may have acquired one, and the source checkout's own
# must be byte-identical to the snapshot taken before anything ran.
for repo in "$PROJ" "$WT" "$DRIVEN" "$RELFIX" "$PLACEHOLDER"; do
  remote_refs="$(git -C "$repo" for-each-ref --format='%(refname)' refs/remotes 2>/dev/null)"
  [ -z "$remote_refs" ] || fail "a rehearsal fixture acquired remote refs: $repo -> $remote_refs"
  remotes="$(git -C "$repo" remote 2>/dev/null)"
  [ -z "$remotes" ] || fail "a rehearsal fixture acquired a git remote: $repo -> $remotes"
done

assert_snapshot_unchanged \
  "the source checkout is read-only input: no file, remote ref, or working-tree state may change" \
  "$SOURCE_BEFORE" "$(snapshot_source)"
assert_snapshot_unchanged \
  "nothing outside the private rehearsal root may change" \
  "$MACHINE_BEFORE" "$(snapshot_machine)"

# ===========================================================================
# 9 -- CLEANUP. The root is the only thing to remove, and removing it must
# leave the machine exactly as the snapshots above already proved it was. The
# environment stays pointed at the (now absent) root across these final
# snapshots on purpose: restoring the ambient Git config first could change
# what `git status` reports about the source checkout and turn a clean
# comparison into a false alarm.
#
# PATH is the one exception, and it has to be. The tripwires live INSIDE the
# root, so `rm -rf "$R"` deletes the very shims PATH points at -- including the
# git shim, which every snapshot function calls. The tripwires have already
# done their job: step 8 asserted the log is empty, no fixture acquired a
# remote, and nothing outside the root changed, all while the shims were still
# in place. What follows is instrumentation ABOUT the cleanup, not a phase of
# the rehearsal, so it must run against a git that still exists.
# ===========================================================================
rm -rf "$R"
[ -e "$R" ] && fail "the private rehearsal root must be removable in one step"
# Stand the tripwires down. `hash -r` is not optional: bash caches the full
# path of every command it has already resolved, and with `checkhash` off (the
# default) it re-uses that path WITHOUT re-checking that the file is still
# there. Restoring PATH alone would therefore leave `git` bound to the deleted
# "$TRIPWIRE_DIR/git" and every snapshot below would silently come back empty.
export PATH="$ORIGINAL_PATH"
hash -r
# Prove the re-resolution really happened rather than assuming it: a `git` that
# still resolves under the deleted root would turn the two comparisons below
# into a confusing "everything vanished" diff instead of a clear failure.
resolved_git="$(command -v git 2>/dev/null || true)"
case "$resolved_git" in
  ""|"$R"/*)
    fail "post-cleanup git must re-resolve outside the removed root, got '$resolved_git'" ;;
  *)
    [ -x "$resolved_git" ] \
      || fail "post-cleanup git re-resolved to '$resolved_git', which is not executable" ;;
esac
# The two config files just went with it. Repoint both scopes at /dev/null
# rather than at a now-missing path: an empty file and /dev/null are the same
# input to git, while restoring the ambient machine config here could change
# what `git status` reports and fake a difference the rehearsal never caused.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
assert_snapshot_unchanged \
  "the source checkout is still unchanged after cleanup" \
  "$SOURCE_BEFORE" "$(snapshot_source)"
assert_snapshot_unchanged \
  "cleanup removed only the private root and left the machine untouched" \
  "$MACHINE_BEFORE" "$(snapshot_machine)"

export HOME="$REAL_HOME"
export TMPDIR="$REAL_TMPDIR"
exit 0
