#!/usr/bin/env bash
# Installs orchid for the current user. Does exactly and only:
#   - wire the interactive orchestrator skills (skills/{orchid,orchid-plan,
#     orchid-resume}) into whichever agent front-ends are ACTUALLY PRESENT
#     on this machine (front-end neutral -- orchid itself is engine-neutral
#     already; see docs/frontends.md):
#       - Claude Code: symlink into $CLAUDE_SKILLS_DIR (default
#         ~/.claude/skills) -- wired if ~/.claude exists or CLAUDE_SKILLS_DIR
#         is set; otherwise skipped with a one-line note (never creates
#         ~/.claude on a machine that doesn't have it).
#       - Hermes: symlink into ~/.hermes/skills/orchestration/<name> -- wired
#         if ~/.hermes/skills exists; otherwise skipped with a one-line note.
#       - OpenClaw: never auto-registered (registration can prompt for an
#         agent/gateway target) -- if the `openclaw` binary and ~/.openclaw
#         are both present, prints the suggested `openclaw skills install`
#         command for the answering AgentSkill instead.
#   - symlink bin/orchid into $ORCHID_BIN_DIR (default ~/.local/bin, or
#     <prefix>/bin when --prefix DIR / --prefix=DIR is given)
#   - create ~/.orchid/{plugins/engines,trust} and a commented ~/.orchid/config
#     (never overwritten if it already exists)
#   - finish by running `orchid doctor` (inside a git repo) or printing
#     next-steps (outside one)
# `./install.sh --uninstall` removes precisely the symlinks this script
# creates (across whichever front-ends were actually wired); config and
# trust are left in place with a note. `--uninstall` and `--prefix` combine
# (uninstall reads the same ORCHID_BIN_DIR --prefix would have set, so it
# un-links the right place).
#
# Bootstrap mode: run OUTSIDE an orchid checkout. The default stable channel
# checks out the immutable version tag below. Following the moving `main`
# branch requires an explicit `--channel development` argument.
set -euo pipefail

# Release tooling reads these exact assignments from the tagged Git object and
# cross-checks them against release/metadata.conf, the tag, and the formula.
# ShellCheck rationale: release tooling reads this public metadata assignment from the tagged file.
# shellcheck disable=SC2034
ORCHID_INSTALL_VERSION="1.0.0-beta.1"
ORCHID_INSTALL_REF="v1.0.0-beta.1"
ORCHID_INSTALL_REPOSITORY="https://github.com/bilal-/orchid.git"

BOOTSTRAP_CHANNEL="stable"
_install_scan_args=("$@")
_install_scan_i=0
while [ "$_install_scan_i" -lt "${#_install_scan_args[@]}" ]; do
  _install_scan_arg="${_install_scan_args[$_install_scan_i]}"
  case "$_install_scan_arg" in
    --channel)
      _install_scan_i=$((_install_scan_i + 1))
      [ "$_install_scan_i" -lt "${#_install_scan_args[@]}" ] || {
        echo "orchid: install.sh: --channel requires stable or development" >&2
        exit 2
      }
      BOOTSTRAP_CHANNEL="${_install_scan_args[$_install_scan_i]}"
      ;;
    --channel=*) BOOTSTRAP_CHANNEL="${_install_scan_arg#--channel=}" ;;
  esac
  _install_scan_i=$((_install_scan_i + 1))
done
case "$BOOTSTRAP_CHANNEL" in
  stable|development) ;;
  *) echo "orchid: install.sh: --channel must be stable or development" >&2; exit 2 ;;
esac
if [ "$BOOTSTRAP_CHANNEL" = stable ]; then
  # Same shape rule scripts/release.sh enforces on the tag: vMAJOR.MINOR.PATCH
  # with an optional semver prerelease suffix (the shipped 1.0.0-beta.1), and
  # nothing that could name a moving ref.
  #
  # A HERESTRING, never `printf ... | grep -Eq`, which is how this was written.
  # `grep -q` exits at its first match and SIGPIPEs the producer; this file runs
  # under `set -o pipefail`, so that kill-by-signal status becomes the
  # pipeline's and a ref that MATCHED is read as a ref that did not. Fail-closed
  # here -- a correctly pinned installer refusing to install -- but it is the
  # shape tests/inv/test_INV-15_no_optional_gate.sh section 5 exists to remove,
  # and a gate decided by whether the producer finished writing first is not a
  # gate. `<<<` feeds grep from a temp file: no pipe, no signal, no race.
  grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.((0|[1-9][0-9]*)|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$' <<<"$ORCHID_INSTALL_REF" || {
      echo "orchid: stable installer ref is not version-pinned: $ORCHID_INSTALL_REF" >&2
      exit 1
    }
  [ "$ORCHID_INSTALL_REF" = "v$ORCHID_INSTALL_VERSION" ] || {
    echo "orchid: stable installer version/ref mismatch: $ORCHID_INSTALL_VERSION vs $ORCHID_INSTALL_REF" >&2
    exit 1
  }
fi

self="${BASH_SOURCE[0]:-}"
ROOT=""
if [ -n "$self" ]; then
  while [ -L "$self" ]; do
    t="$(readlink "$self")"
    case "$t" in /*) self="$t" ;; *) self="$(dirname "$self")/$t" ;; esac
  done
  ROOT="$(cd "$(dirname "$self")" && pwd)"
fi

# --- Bootstrap mode ------------------------------------------------------
# A file-backed invocation has a BASH_SOURCE path and may run directly from a
# real checkout. A piped invocation has no BASH_SOURCE at all; $0 merely names
# bash and its dirname is the CALLER'S cwd. Never treat that cwd as installer
# source, even if it is itself a dirty orchid checkout with both anchor files.
# A bare copy of install.sh likewise lacks the adjacent anchors. In either
# bootstrap shape there is nothing trustworthy to symlink FROM yet, so clone
# (or update) the canonical checkout and hand off to ITS install.sh.
if [ -z "$ROOT" ] || [ ! -f "$ROOT/bin/orchid" ] || [ ! -f "$ROOT/lib/common.sh" ]; then
  bootstrap_and_exec() {
    command -v git >/dev/null 2>&1 || {
      echo "orchid: install.sh: git is required to install orchid this way (curl|bash) -- install git and re-run" >&2
      exit 1
    }

    local home="${ORCHID_HOME:-$HOME/.local/share/orchid}"
    local orchid_url="$ORCHID_INSTALL_REPOSITORY"
    local uninstalling=0 a parent tmp origin_url
    local tag_object_before tag_object_after tag_commit_before tag_commit_after selected_commit
    for a in "$@"; do [ "$a" = "--uninstall" ] && uninstalling=1; done

    # "Already a checkout" is judged by the same two anchor files checked
    # above, plus actual git metadata -- not just "a directory exists here"
    # -- so a stray non-orchid directory at $home is never mistaken for one
    # and silently `pull`ed or uninstalled against.
    if [ -f "$home/bin/orchid" ] && [ -f "$home/lib/common.sh" ] \
       && git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
      if [ "$uninstalling" = 1 ]; then
        echo "orchid: uninstalling via the canonical checkout at $home (the clone itself is left in place -- --uninstall never deletes it)"
      else
        origin_url="$(git -C "$home" config --get remote.origin.url 2>/dev/null || true)"
        [ "$origin_url" = "$orchid_url" ] || {
          echo "orchid: canonical checkout at $home has unexpected origin '$origin_url' -- refusing to update or execute it" >&2
          exit 1
        }
        [ -z "$(git -C "$home" status --porcelain --untracked-files=all)" ] || {
          echo "orchid: canonical checkout at $home has local changes -- refusing to replace or update it" >&2
          exit 1
        }
        if [ "$BOOTSTRAP_CHANNEL" = stable ]; then
          tag_object_before="$(git -C "$home" rev-parse --verify "refs/tags/$ORCHID_INSTALL_REF" 2>/dev/null || true)"
          tag_commit_before="$(git -C "$home" rev-parse --verify "refs/tags/$ORCHID_INSTALL_REF^{commit}" 2>/dev/null || true)"
          echo "orchid: canonical checkout already present at $home -- selecting stable $ORCHID_INSTALL_REF"
          git -C "$home" fetch --depth 1 origin \
            "refs/tags/$ORCHID_INSTALL_REF:refs/tags/$ORCHID_INSTALL_REF"
          tag_object_after="$(git -C "$home" rev-parse --verify "refs/tags/$ORCHID_INSTALL_REF")"
          tag_commit_after="$(git -C "$home" rev-parse --verify "refs/tags/$ORCHID_INSTALL_REF^{commit}")"
          [ -z "$tag_object_before" ] || { [ "$tag_object_before" = "$tag_object_after" ] \
            && [ "$tag_commit_before" = "$tag_commit_after" ]; } || {
            echo "orchid: stable tag moved locally ($tag_object_before -> $tag_object_after) -- refused" >&2
            exit 1
          }
          git -C "$home" checkout --detach "$tag_commit_after"
        else
          echo "orchid: DEVELOPMENT channel: fetching the moving main branch at $home"
          git -C "$home" fetch --depth 1 origin refs/heads/main
          selected_commit="$(git -C "$home" rev-parse --verify 'FETCH_HEAD^{commit}')"
          echo "orchid: selecting development snapshot $selected_commit"
          git -C "$home" checkout --detach "$selected_commit"
        fi
      fi
    else
      if [ "$uninstalling" = 1 ]; then
        echo "orchid: nothing to uninstall -- no canonical checkout found at $home"
        exit 0
      fi

      # $home exists but failed the checkout test above (missing an anchor
      # file, or `git rev-parse --git-dir` doesn't recognize it). That is
      # only a NEGATIVE signal ("not currently a usable orchid checkout")
      # -- and it is NEVER grounds for deleting anything: $home is
      # `${ORCHID_HOME:-...}`, a user-settable env var, so this branch is
      # reached just as easily by a user pointing ORCHID_HOME at their own
      # directory (or git repo) as by wreckage from some earlier failed
      # install. Two review rounds each caught a destructive repair here:
      # first an unconditional rm -rf (verified live to destroy an
      # unrelated directory of user files), then an rm -rf gated on
      # $home/.git's remote.origin.url matching this repo's clone URL --
      # but an expected-origin repo that lacks an anchor file is still
      # routinely a USER-CONTROLLED checkout (a contributor's own clone
      # with uncommitted work, stash state, or bin/orchid deleted
      # mid-edit), and nothing observable here can prove otherwise. So
      # this installer fails closed: name the path, explain, give both
      # remedies, exit nonzero, delete nothing -- recursively or
      # otherwise. Half-populated wreckage at $home cannot come from THIS
      # installer anyway: the clone below lands in a temp sibling and is
      # only ever mv'd into place after git fully succeeds.
      if [ -e "$home" ]; then
        echo "orchid: install.sh: $home already exists but is not a usable orchid checkout -- refusing to touch it (this installer never deletes an existing ORCHID_HOME)" >&2
        echo "orchid: inspect $home yourself and remove it only if it's safe to discard, or set ORCHID_HOME to a different path and re-run" >&2
        exit 1
      fi

      echo "orchid: cloning orchid to $home"
      parent="$(dirname "$home")"
      mkdir -p "$parent"
      # Clone to a TEMP SIBLING of $home (same parent -- same filesystem,
      # so the mv below is a pure rename, not a copy) and only mv it into
      # place once git has fully succeeded. This is what keeps a clone
      # interrupted partway through from ever leaving $home itself
      # half-populated for the next run to trip over -- and it is the
      # load-bearing guarantee behind the fail-closed refusal above: since
      # a dead clone never lands at $home, anything already sitting there
      # is presumed to be the user's and is never auto-removed.
      tmp="$(mktemp -d "$parent/.orchid-clone.XXXXXX")"
      trap 'rm -rf "$tmp"' EXIT
      if [ "$BOOTSTRAP_CHANNEL" = stable ]; then
        echo "orchid: stable channel pinned to $ORCHID_INSTALL_REF"
        git clone --depth 1 --branch "$ORCHID_INSTALL_REF" --single-branch "$orchid_url" "$tmp"
        # `git clone --branch NAME` accepts either a tag or a same-named
        # branch. Prove the immutable tag ref exists, peel it to one commit,
        # and detach there before the clone becomes the canonical install.
        selected_commit="$(git -C "$tmp" rev-parse --verify "refs/tags/$ORCHID_INSTALL_REF^{commit}" 2>/dev/null)" || {
          echo "orchid: stable ref $ORCHID_INSTALL_REF did not resolve through refs/tags -- refused" >&2
          exit 1
        }
        git -C "$tmp" checkout --detach "$selected_commit"
      else
        echo "orchid: DEVELOPMENT channel follows moving ref main"
        git clone --depth 1 --branch main --single-branch "$orchid_url" "$tmp"
        selected_commit="$(git -C "$tmp" rev-parse --verify 'HEAD^{commit}')"
        echo "orchid: selecting development snapshot $selected_commit"
        git -C "$tmp" checkout --detach "$selected_commit"
      fi
      trap - EXIT
      mv "$tmp" "$home"
    fi

    exec "$home/install.sh" "$@"
  }
  bootstrap_and_exec "$@"
fi

# CLAUDE_SKILLS_DIR_SET tracks whether the caller overrode the env var
# BEFORE the default below is applied -- an explicit override is itself
# taken as "yes, wire Claude Code here" even on a machine with no ~/.claude
# yet (e.g. a test harness pointing it at a scratch dir).
CLAUDE_SKILLS_DIR_SET=0
if [ -n "${CLAUDE_SKILLS_DIR+x}" ]; then CLAUDE_SKILLS_DIR_SET=1; fi
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
HERMES_SKILLS_DIR="$HOME/.hermes/skills"
HERMES_ORCH_DIR="$HERMES_SKILLS_DIR/orchestration"
ORCHID_BIN_DIR="${ORCHID_BIN_DIR:-$HOME/.local/bin}"
SKILLS="orchid orchid-plan orchid-resume"

# Argument parsing. Channel controls bootstrap source selection only and is
# accepted as a no-op after the pinned checkout hands off to its installer.
# either order (`--prefix DIR --uninstall` or `--uninstall --prefix DIR`).
# --prefix only ever redirects ORCHID_BIN_DIR (where the `orchid` binary
# symlink lands); it does not move skills/config/trust, which are always
# per-user (CLAUDE_SKILLS_DIR / ~/.orchid), never per-prefix.
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --channel) [ $# -ge 2 ] || { echo "orchid: install.sh: --channel requires stable or development" >&2; exit 2; }
               case "$2" in stable|development) ;; *) echo "orchid: install.sh: --channel must be stable or development" >&2; exit 2 ;; esac
               shift ;;
    --channel=*) case "${1#--channel=}" in stable|development) ;; *) echo "orchid: install.sh: --channel must be stable or development" >&2; exit 2 ;; esac ;;
    --prefix) [ $# -ge 2 ] || { echo "orchid: install.sh: --prefix requires a directory argument" >&2; exit 2; }
              ORCHID_BIN_DIR="$2/bin"; shift ;;
    --prefix=*) ORCHID_BIN_DIR="${1#--prefix=}/bin" ;;
    *) echo "orchid: install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# THE STALE-ROOT GATE, FIRED HERE BECAUSE NOTHING ELSE IN THIS FILE FIRES IT
# (INV-15, lesson L018).
#
# What this script produces is a machine-scoped WIRING: the operator's `orchid`
# becomes a symlink into $ROOT, three skill bundles become symlinks into $ROOT,
# and ~/.orchid is created from $ROOT's own key list. Every one of those is
# decided and performed by the code in THIS checkout. Run out of a checkout
# parked on its configured integration branch with a kernel edit staged, that
# is the pre-merge tree wiring itself in as the operator's orchid -- which is
# the whole of L018, at the one moment it is hardest to notice, because
# installation is the step nobody re-runs afterwards.
#
# THE POST-INSTALL `orchid doctor` IS NOT THAT GATE, and the reason is exactly
# the shape INV-15 exists for. It runs only when cwd is a git repo whose
# toplevel is not $ROOT (below), so it is skipped precisely in the self-hosted
# case -- `./install.sh` from inside the orchid checkout itself -- which is the
# only case in which $ROOT can be the stale integration checkout at all. A gate
# whose one blind spot is the only environment that can reach the condition is
# a gate that is reachable and cannot see.
#
# AN EXPLICIT CALL, not a source-time fire. lib/common.sh refuses at source time
# only for bin/orchid, libexec/orchid-* and runners/orchid-* (its
# _orchid_kernel_entry_point); a file outside those three roots ARMS the guard
# by loading the library and is left to fire it, so this file must ask. That is
# scripts/beta-qualify.sh's shape, and tests/inv/test_INV-15_no_optional_gate.sh
# section 4 derives the whole set rather than trusting either of them to
# remember.
#
# AFTER THE ARGUMENT PARSE, BEFORE THE FIRST MUTATION. After, so a mistyped flag
# is answered with its own diagnosis rather than a refusal about the checkout --
# the rule libexec/orchid-trust and runners/orchid-service are already held to.
# Before, because `--uninstall` is below this line too: which symlinks a
# pre-merge installer decides are "its own" is decided by the pre-merge tree,
# and removal is not exempt for being the safe direction (`orchid trust revoke`
# carries the same argument). Availability is preserved the documented way, per
# invocation and visible in the transcript: ORCHID_ALLOW_STALE_ROOT=1
# ./install.sh.
#
# The load cannot fail closed against a bootstrap invocation: the block above
# already exec'd away unless $ROOT holds both anchor files, one of which is this
# library. And it costs nothing anywhere else -- for every root not parked on
# its configured integration branch (an extracted archive, a tagged clone at
# $ORCHID_HOME, an ordinary development checkout) the gate is a no-op that
# spends no subprocess.
#
# ORCHID_ROOT is set from $ROOT rather than inherited, and exported the way
# scripts/beta-qualify.sh exports it: the guard reads that variable, and an
# ORCHID_ROOT already in the environment names some other installation, not the
# checkout whose code is about to be wired in. The `orchid doctor` handoff at
# the end is unaffected -- bin/orchid resolves and re-exports its own root from
# its own $0 before dispatching anything.
ORCHID_ROOT="$ROOT"
export ORCHID_ROOT
source "$ROOT/lib/common.sh"
orchid_root_stale_gate

# link_one src dest: creates dest as a symlink to src, refusing to clobber
# anything at dest that isn't already a symlink (a real file/dir there is
# someone else's — leave it alone and say so, rather than destroying it) —
# and, mirroring unlink_one's exactness the other direction, refusing to
# clobber a FOREIGN symlink too: one that already exists at dest but points
# somewhere other than src (some other tool's doing, or a previous install
# of something else at this path). `-L` is checked before `-e` on purpose,
# since `-e` is false for a dangling symlink — this must catch that case too.
link_one() {
  local src="$1" dest="$2"
  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" != "$src" ]; then
      echo "orchid: skip (foreign symlink, left alone): $dest -> $(readlink "$dest")" >&2
      return 0
    fi
  elif [ -e "$dest" ]; then
    echo "orchid: skip (not a symlink, left alone): $dest" >&2
    return 0
  fi
  ln -sfn "$src" "$dest"
  echo "linked: $dest -> $src"
}

# unlink_one src dest: removes dest only if it is a symlink pointing at src
# (this script's own doing) — never a bare `rm -f`, so a symlink some other
# tool planted at the same path is never touched.
unlink_one() {
  local src="$1" dest="$2"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    rm -f "$dest"
    echo "removed: $dest"
  fi
}

if [ "$UNINSTALL" = 1 ]; then
  # Reverses exactly what an install could have created, across every
  # front-end this script knows how to wire -- unlink_one is a no-op for a
  # front-end that was never wired in the first place (dest either doesn't
  # exist or isn't a symlink back to $ROOT), so it's safe to attempt all of
  # them unconditionally rather than re-deriving "was this one installed".
  for name in $SKILLS; do
    unlink_one "$ROOT/skills/$name" "$CLAUDE_SKILLS_DIR/$name"
    unlink_one "$ROOT/skills/$name" "$HERMES_ORCH_DIR/$name"
  done
  unlink_one "$ROOT/bin/orchid" "$ORCHID_BIN_DIR/orchid"
  echo "uninstall complete (~/.orchid/config and ~/.orchid/trust left in place)"
  exit 0
fi

# --- Front-end wiring: whichever agent products are actually present on
# this machine, per docs/frontends.md. Never creates a front-end's own
# config directory (~/.claude, ~/.hermes) on a machine that doesn't already
# have it -- only ever adds INSIDE a directory that's already there (or
# whose location was explicitly overridden), the same "leave what I don't
# own alone" philosophy link_one/unlink_one already follow for symlinks.

if [ "$CLAUDE_SKILLS_DIR_SET" = 1 ] || [ -d "$HOME/.claude" ]; then
  mkdir -p "$CLAUDE_SKILLS_DIR"
  for name in $SKILLS; do
    link_one "$ROOT/skills/$name" "$CLAUDE_SKILLS_DIR/$name"
  done
else
  echo "orchid: skip Claude Code skills (no ~/.claude found -- set CLAUDE_SKILLS_DIR to wire this front-end anyway)"
fi

# Hermes: verified 2026-08-01 against a live Hermes Agent v0.19.0 install --
# `hermes skills list` discovers a SYMLINKED skill directory under
# ~/.hermes/skills/<category>/<name>/ and reads its name/description
# straight out of SKILL.md frontmatter (agent/skill_utils.py's
# iter_skill_index_files walks os.walk(..., followlinks=True)); all three
# of skills/{orchid,orchid-plan,orchid-resume}'s minimal frontmatter (name +
# description only -- no Claude-Code-only keys) round-tripped this way,
# each showing up `enabled`/`local` under category `orchestration`. That is
# a real, checked result (unlike skills-external/openclaw-orchid/SKILL.md's
# own dogfood, which only ever exercised hermes with a COPY, not a symlink,
# per docs/dogfood-notes.md's v1-m4 Task 10 entry) -- symlinking here is
# safe, not a guess, and keeps a `git pull` updating these in place exactly
# like the Claude Code wiring above.
if [ -d "$HERMES_SKILLS_DIR" ]; then
  mkdir -p "$HERMES_ORCH_DIR"
  for name in $SKILLS; do
    link_one "$ROOT/skills/$name" "$HERMES_ORCH_DIR/$name"
  done
else
  echo "orchid: skip Hermes skills (no ~/.hermes/skills found -- see docs/engines/hermes.md to install it)"
fi

# OpenClaw: registration is a SUGGESTION, never run automatically here --
# `openclaw skills install` targets a specific agent workspace/gateway
# (`--agent`, `--global`), which install.sh has no business picking for the
# operator, and this script must stay non-interactive. Only the ANSWERING
# AgentSkill (skills-external/openclaw-orchid -- status + nonce-verified
# blocker answers, nothing else) has an OpenClaw-shaped bundle today; there
# is no OpenClaw orchestrator front-end to suggest (see docs/frontends.md).
if command -v openclaw >/dev/null 2>&1 && [ -d "$HOME/.openclaw" ]; then
  cat <<EOF
orchid: OpenClaw detected -- to register orchid's answering-skill bundle
(read-only status + nonce-verified blocker answers; see
skills-external/openclaw-orchid/README.md), run:
  openclaw skills install "$ROOT/skills-external/openclaw-orchid" --as orchid
(not run automatically -- registration targets a specific agent/gateway,
which install.sh does not choose on your behalf; see docs/frontends.md)
EOF
else
  echo "orchid: skip OpenClaw registration suggestion (openclaw binary or ~/.openclaw not found)"
fi

mkdir -p "$ORCHID_BIN_DIR"
link_one "$ROOT/bin/orchid" "$ORCHID_BIN_DIR/orchid"

case ":$PATH:" in
  *":$ORCHID_BIN_DIR:"*) ;;
  *) echo "warning: $ORCHID_BIN_DIR is not on PATH — add it to your shell profile" >&2 ;;
esac

# v1-m4 Task 12 (rehearsal F17): ~/.orchid/trust is the digest-pinned trust
# STORE FILE (lib/common.sh's trust model), not a directory — `mkdir -p` on a
# path that exists as a file still exits nonzero, which under `set -e` killed
# every re-install on a machine that had ever run `orchid plugins trust`.
# Only plugins/engines is a directory here; the trust file is created on
# demand by the trust verbs and must never be pre-created (an empty file vs
# absent file is meaningful to nothing, but a DIRECTORY at that path would
# break every trust read). tests/test_install.sh covers the
# trust-store-file-already-exists re-install case.
mkdir -p "$HOME/.orchid/plugins/engines"
if [ ! -e "$HOME/.orchid/config" ]; then
  {
    echo "# orchid user config — key=value, one per line, parsed never sourced."
    echo "# Per-user preferences (role bindings, model tiers, notify channel)"
    echo "# that should apply to every repo. Per-repo facts (integration"
    echo "# branch, verify command, resources) belong in <repo>/orchid.config"
    echo "# instead. See orchid.config.example for the current key set."
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      echo "# $key="
    done < "$ROOT/lib/config-keys.txt"
  } > "$HOME/.orchid/config"
  echo "created: $HOME/.orchid/config"
else
  echo "exists (left untouched): $HOME/.orchid/config"
fi

# Run `orchid doctor` at the end only when cwd is actually a repo meant to
# BE orchestrated — i.e. a git repo whose toplevel isn't this install's own
# source checkout. Running from inside the orchid source repo itself (e.g.
# `./install.sh` from a clone) is not "a repo to orchestrate"; treat it the
# same as the no-repo case below instead of running doctor against it.
# doctor's own exit code must never fail the installer itself — install
# already completed by this point regardless of what doctor finds.
if git rev-parse --git-dir >/dev/null 2>&1 && [ "$(git rev-parse --show-toplevel)" != "$ROOT" ]; then
  "$ORCHID_BIN_DIR/orchid" doctor || { echo "orchid: doctor reported issues above (install itself still completed)" >&2; true; }
else
  cat <<EOF
install complete — not currently inside a repository to orchestrate, so
nothing further to check here. Next steps, from the repo you want to
orchestrate:
  cd /path/to/your/repo
  orchid doctor
  orchid init
EOF
fi
