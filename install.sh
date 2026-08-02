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
# Bootstrap mode: run OUTSIDE an orchid checkout --
#   curl -fsSL https://raw.githubusercontent.com/bilal-/orchid/main/install.sh | bash
# -- clones a canonical copy to ${ORCHID_HOME:-~/.local/share/orchid} (or
# fast-forwards it if already cloned there, making the same one-liner the
# upgrade command too) and hands off to that checkout's own install.sh with
# the original arguments. Inside a real checkout, this is a complete no-op
# -- behavior is identical to before bootstrap mode existed.
set -euo pipefail

self="$0"
while [ -L "$self" ]; do
  t="$(readlink "$self")"
  case "$t" in /*) self="$t" ;; *) self="$(dirname "$self")/$t" ;; esac
done
ROOT="$(cd "$(dirname "$self")" && pwd)"

# --- Bootstrap mode ------------------------------------------------------
# A real orchid checkout always has both bin/orchid and lib/common.sh next
# to install.sh. When either is missing, ROOT isn't a checkout at all --
# it's just wherever $0 happened to resolve to, which for `curl|bash` is
# "bash" itself (dirname "bash" -> "."), i.e. the caller's cwd, and for a
# bare copy of this one file (this task's own test fixture) is whatever
# scratch dir that copy lives in. Neither $0 nor BASH_SOURCE is a usable
# repo anchor in that shape, so there is nothing to symlink FROM yet --
# clone (or update) one first, then hand off to ITS install.sh.
if [ ! -f "$ROOT/bin/orchid" ] || [ ! -f "$ROOT/lib/common.sh" ]; then
  bootstrap_and_exec() {
    command -v git >/dev/null 2>&1 || {
      echo "orchid: install.sh: git is required to install orchid this way (curl|bash) -- install git and re-run" >&2
      exit 1
    }

    local home="${ORCHID_HOME:-$HOME/.local/share/orchid}"
    local orchid_url="https://github.com/bilal-/orchid.git"
    local uninstalling=0 a parent tmp origin_url is_dead_orchid_clone
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
        echo "orchid: canonical checkout already present at $home -- updating (git pull --ff-only)"
        git -C "$home" pull --ff-only
      fi
    else
      if [ "$uninstalling" = 1 ]; then
        echo "orchid: nothing to uninstall -- no canonical checkout found at $home"
        exit 0
      fi

      # $home exists but failed the checkout test above (missing an anchor
      # file, or `git rev-parse --git-dir` doesn't recognize it). That is
      # only a NEGATIVE signal ("not currently a usable orchid checkout")
      # -- on its own it is NOT enough to justify deleting anything: $home
      # is `${ORCHID_HOME:-...}`, a user-settable env var, so this branch
      # is reached just as easily by a user pointing ORCHID_HOME at their
      # own unrelated directory (or git repo) as by an actually-interrupted
      # prior bootstrap clone. A review found the earlier version of this
      # fix rm -rf'd unconditionally here -- verified live to destroy an
      # unrelated directory of user files with no warning beyond a message
      # asserting a cause ("left behind by an interrupted clone") the code
      # never actually checked. Auto-removal now requires POSITIVE proof
      # this is dead wreckage from orchid's own bootstrap and nothing
      # else -- ALL three, not just the pre-existing negative one:
      #   (a) $home/.git exists at all (a plain directory of unrelated
      #       files, no git repo, fails here -- left untouched)
      #   (b) that .git's own remote.origin.url is EXACTLY this repo's
      #       clone URL (a user's own unrelated git repo at this path
      #       fails here -- left untouched, even though it has a .git)
      #   (c) it is still incomplete -- true by construction (this whole
      #       `else` only runs when the checkout test above failed), kept
      #       as an explicit check for readability rather than relying
      #       purely on control flow
      # Anything short of all three is refused loudly instead -- named
      # path, why, and both remedies -- never silently deleted, never
      # silently proceeded past.
      is_dead_orchid_clone=0
      if [ -e "$home" ]; then
        if [ -e "$home/.git" ]; then
          origin_url="$(git -C "$home" config --get remote.origin.url 2>/dev/null || true)"
          if [ "$origin_url" = "$orchid_url" ] \
             && { [ ! -f "$home/bin/orchid" ] || [ ! -f "$home/lib/common.sh" ] \
                  || ! git -C "$home" rev-parse --git-dir >/dev/null 2>&1; }; then
            is_dead_orchid_clone=1
          fi
        fi

        if [ "$is_dead_orchid_clone" = 1 ]; then
          echo "orchid: removing incomplete clone at $home (verified: .git present, remote.origin.url is $orchid_url, but the checkout is missing its files) before retrying"
          rm -rf "$home"
        else
          echo "orchid: install.sh: $home already exists and is not a usable orchid checkout -- refusing to touch it" >&2
          echo "orchid: either remove $home yourself if it's safe to discard, or set ORCHID_HOME to a different path and re-run" >&2
          exit 1
        fi
      fi

      echo "orchid: cloning orchid to $home"
      parent="$(dirname "$home")"
      mkdir -p "$parent"
      # Clone to a TEMP SIBLING of $home (same parent -- same filesystem,
      # so the mv below is a pure rename, not a copy) and only mv it into
      # place once git has fully succeeded. This is what keeps a clone
      # interrupted partway through from ever leaving $home itself
      # half-populated for the next run to trip over -- the failure mode
      # the stale-clone recovery above recovers FROM, but recovery is only
      # ever needed once here, going forward, because a dead clone never
      # lands at $home at all anymore.
      tmp="$(mktemp -d "$parent/.orchid-clone.XXXXXX")"
      trap 'rm -rf "$tmp"' EXIT
      git clone --depth 1 "$orchid_url" "$tmp"
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

# Argument parsing -- deliberately just these two flags, combinable in
# either order (`--prefix DIR --uninstall` or `--uninstall --prefix DIR`).
# --prefix only ever redirects ORCHID_BIN_DIR (where the `orchid` binary
# symlink lands); it does not move skills/config/trust, which are always
# per-user (CLAUDE_SKILLS_DIR / ~/.orchid), never per-prefix.
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) UNINSTALL=1 ;;
    --prefix) [ $# -ge 2 ] || { echo "orchid: install.sh: --prefix requires a directory argument" >&2; exit 2; }
              ORCHID_BIN_DIR="$2/bin"; shift ;;
    --prefix=*) ORCHID_BIN_DIR="${1#--prefix=}/bin" ;;
    *) echo "orchid: install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

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
