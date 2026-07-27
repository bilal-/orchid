#!/usr/bin/env bash
# Installs orchid for the current user. Does exactly and only:
#   - symlink skills/* into $CLAUDE_SKILLS_DIR (default ~/.claude/skills)
#   - symlink bin/orchid into $ORCHID_BIN_DIR (default ~/.local/bin)
#   - create ~/.orchid/{plugins/engines,trust} and a commented ~/.orchid/config
#     (never overwritten if it already exists)
#   - finish by running `orchid doctor` (inside a git repo) or printing
#     next-steps (outside one)
# `./install.sh --uninstall` removes precisely the symlinks this script
# creates; config and trust are left in place with a note.
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

# link_one src dest: creates dest as a symlink to src, refusing to clobber
# anything at dest that isn't already a symlink (a real file/dir there is
# someone else's — leave it alone and say so, rather than destroying it).
link_one() {
  local src="$1" dest="$2"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
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

if [ "${1:-}" = "--uninstall" ]; then
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

mkdir -p "$HOME/.orchid/plugins/engines" "$HOME/.orchid/trust"
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

if git rev-parse --git-dir >/dev/null 2>&1; then
  "$ORCHID_BIN_DIR/orchid" doctor
else
  cat <<EOF
install complete — not currently inside a git repository, so nothing further
to check here. Next steps, from the repo you want to orchestrate:
  cd /path/to/your/repo
  orchid doctor
  orchid init
EOF
fi
