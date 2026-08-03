#!/usr/bin/env bash
# Canonical secret-free CI entry point, shared by hosted CI and release
# archive rehearsal. It intentionally runs on Bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH:-/bin/bash}"
LIST_ONLY=0

usage() {
  cat <<'EOF'
usage: scripts/ci-local.sh [--bash /path/to/bash] [--list-shell]

  --bash PATH    use PATH for syntax checks and every test script
  --list-shell   print every discovered shipped shell script, then exit
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bash)
      [ "$#" -ge 2 ] || { echo "ci-local: --bash requires a path" >&2; exit 2; }
      BASH_BIN="$2"
      shift 2
      ;;
    --bash=*) BASH_BIN="${1#--bash=}"; shift ;;
    --list-shell) LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ci-local: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -x "$BASH_BIN" ] || { echo "ci-local: Bash interpreter is not executable: $BASH_BIN" >&2; exit 2; }
if ! "$BASH_BIN" -c '[ -n "${BASH_VERSION:-}" ] && (( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) ))'; then
  echo "ci-local: --bash must name Bash 3.2 or newer: $BASH_BIN" >&2
  exit 2
fi

is_shell_file() {
  local rel="$1" first="" shell_command="" token
  local index=0
  local -a shebang_words
  case "$rel" in *.sh|*.bash) return 0 ;; esac
  IFS= read -r first < "$ROOT/$rel" || true
  case "$first" in '#!'*) ;; *) return 1 ;; esac

  # Parse the shebang by interpreter name, including the common env and
  # env -S forms. This keeps extensionless POSIX-sh helpers visible without
  # relying on a substring match or a directory allowlist.
  read -r -a shebang_words <<< "${first#\#!}"
  [ "${#shebang_words[@]}" -gt 0 ] || return 1
  shell_command="${shebang_words[0]##*/}"
  if [ "$shell_command" = env ]; then
    index=1
    shell_command=""
    while [ "$index" -lt "${#shebang_words[@]}" ]; do
      token="${shebang_words[$index]}"
      case "$token" in
        --) index=$((index + 1)); [ "$index" -lt "${#shebang_words[@]}" ] || break
            shell_command="${shebang_words[$index]##*/}"; break ;;
        -u|--unset|-C|--chdir) index=$((index + 2)); continue ;;
        -*|*=*) index=$((index + 1)); continue ;;
        *) shell_command="${token##*/}"; break ;;
      esac
    done
  fi
  case "$shell_command" in bash|sh) return 0 ;; *) return 1 ;; esac
}

# Prefer Git's tracked-file set in a checkout. An extracted release archive
# has no .git directory, so the same content-based discovery falls back to
# find there. Names and shebangs, rather than directory allowlists, cover root
# scripts, templates, extensionless runners/adapters, tests, and skill helpers.
discover_shell_files() {
  local top="" rel
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ "$top" = "$ROOT" ]; then
    while IFS= read -r -d '' rel; do
      case "$rel" in .orchid/*) continue ;; esac
      [ -f "$ROOT/$rel" ] || continue
      is_shell_file "$rel" && printf '%s\n' "$rel"
    done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard -z)
  else
    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      is_shell_file "$rel" && printf '%s\n' "$rel"
    done < <(cd "$ROOT" && find . \( -path './.git' -o -path './.orchid' \) -prune -o -type f -print0)
  fi
}

SHELL_FILES=()
while IFS= read -r rel; do
  [ -n "$rel" ] && SHELL_FILES+=("$rel")
done < <(discover_shell_files | LC_ALL=C sort -u)

[ "${#SHELL_FILES[@]}" -gt 0 ] || { echo "ci-local: no shipped shell scripts discovered" >&2; exit 1; }
if [ "$LIST_ONLY" -eq 1 ]; then
  printf '%s\n' "${SHELL_FILES[@]}"
  exit 0
fi

echo "== Bash syntax (${#SHELL_FILES[@]} shipped scripts; $BASH_BIN)"
for rel in "${SHELL_FILES[@]}"; do
  "$BASH_BIN" -n "$ROOT/$rel"
done

# Every suppression must be one code, immediately preceded by a rationale,
# and must not sit ahead of the file's first command: ShellCheck scopes a
# directive that precedes the first command to the ENTIRE file, so even a
# well-documented single code placed there becomes a file-wide baseline
# that silently hides every later instance of that warning. This prevents
# both that placement and a new multi-code baseline from hiding warnings
# while still permitting a narrow false-positive annotation.
echo "== ShellCheck exception policy"
for rel in "${SHELL_FILES[@]}"; do
  awk -v file="$rel" '
    /#[[:space:]]*shellcheck[[:space:]]+disable=/ {
      directive = $0
      sub(/^.*disable=/, "", directive)
      sub(/[[:space:]].*$/, "", directive)
      if (directive !~ /^SC[0-9]+$/) {
        printf "%s:%d: ShellCheck suppression must name exactly one SC code\n", file, NR > "/dev/stderr"
        bad = 1
      }
      if (previous !~ /^[[:space:]]*#[[:space:]]*ShellCheck rationale: .+/) {
        printf "%s:%d: ShellCheck suppression lacks an adjacent rationale\n", file, NR > "/dev/stderr"
        bad = 1
      }
      if (!seen_command) {
        printf "%s:%d: ShellCheck suppression precedes the first command, so it would apply file-wide\n", file, NR > "/dev/stderr"
        bad = 1
      }
    }
    !/^[[:space:]]*(#|$)/ { seen_command = 1 }
    { previous = $0 }
    END { exit bad }
  ' "$ROOT/$rel"
done
while IFS= read -r rc_file; do
  if grep -Eq '^[[:space:]]*(disable|exclude)=' "$rc_file"; then
    echo "ci-local: $rc_file may not contain blanket exclusions" >&2
    exit 1
  fi
done < <(find "$ROOT" \( -path "$ROOT/.git" -o -path "$ROOT/.orchid" \) -prune -o -name .shellcheckrc -type f -print)

# find(1)'s depth-limiting primaries (min/max) are not POSIX, so a shipped
# script leaning on them ties the suite to one find implementation. One-level
# listings use plain bash globbing instead (lib/common.sh orchid_list_dir,
# tests/helpers.sh list_dir_entries/list_dir_files). The pattern is
# assembled, never written literally, so this gate does not flag itself.
echo "== Portability policy (POSIX find only)"
nonportable_find_depth='[-]m'
nonportable_find_depth="${nonportable_find_depth}(in|ax)depth"
for rel in "${SHELL_FILES[@]}"; do
  if grep -En "$nonportable_find_depth" "$ROOT/$rel" >&2; then
    echo "ci-local: $rel uses a non-POSIX find depth primary — use shell globbing (see tests/helpers.sh list_dir_entries)" >&2
    exit 1
  fi
done

command -v shellcheck >/dev/null 2>&1 || {
  echo "ci-local: shellcheck is required (see docs/contributing.md)" >&2
  exit 1
}
echo "== ShellCheck (zero warnings)"
SHELLCHECK_PATHS=()
for rel in "${SHELL_FILES[@]}"; do SHELLCHECK_PATHS+=("$ROOT/$rel"); done
unset SHELLCHECK_OPTS || true
shellcheck --shell=bash --severity=warning -- "${SHELLCHECK_PATHS[@]}"

echo "== Full test suite"
ORCHID_TEST_BASH="$BASH_BIN" "$BASH_BIN" "$ROOT/tests/run.sh"

# These are already part of tests/run.sh. Rehearse them explicitly so their
# status remains visible as first-class CI gates even if the aggregate runner
# is reorganized later.
echo "== Invariant tests"
for rel in "$ROOT"/tests/inv/test_*.sh; do
  [ -e "$rel" ] || continue
  ORCHID_TEST_BASH="$BASH_BIN" "$BASH_BIN" "$rel"
done

echo "== Documentation checks"
ORCHID_TEST_BASH="$BASH_BIN" "$BASH_BIN" "$ROOT/tests/test_docs.sh"

echo "CI PASS"
