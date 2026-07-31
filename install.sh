#!/usr/bin/env bash
# Installs orchid for the current user. Does exactly and only:
#   - symlink skills/* into $CLAUDE_SKILLS_DIR (default ~/.claude/skills)
#   - symlink bin/orchid into $ORCHID_BIN_DIR (default ~/.local/bin, or
#     <prefix>/bin when --prefix DIR / --prefix=DIR is given)
#   - create ~/.orchid/{plugins/engines,trust} and a commented ~/.orchid/config
#     (never overwritten if it already exists)
#   - finish by running `orchid doctor` (inside a git repo) or printing
#     next-steps (outside one)
# `./install.sh --uninstall` removes precisely the symlinks this script
# creates; config and trust are left in place with a note. `--uninstall` and
# `--prefix` combine (uninstall reads the same ORCHID_BIN_DIR --prefix would
# have set, so it un-links the right place).
set -euo pipefail

self="$0"
while [ -L "$self" ]; do
  t="$(readlink "$self")"
  case "$t" in /*) self="$t" ;; *) self="$(dirname "$self")/$t" ;; esac
done
ROOT="$(cd "$(dirname "$self")" && pwd)"

CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
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
  for name in $SKILLS; do
    unlink_one "$ROOT/skills/$name" "$CLAUDE_SKILLS_DIR/$name"
  done
  unlink_one "$ROOT/bin/orchid" "$ORCHID_BIN_DIR/orchid"
  echo "uninstall complete (~/.orchid/config and ~/.orchid/trust left in place)"
  exit 0
fi

mkdir -p "$CLAUDE_SKILLS_DIR"
for name in $SKILLS; do
  link_one "$ROOT/skills/$name" "$CLAUDE_SKILLS_DIR/$name"
done

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
