#!/usr/bin/env bash
# Canonical secret-free CI entry point, shared by hosted CI and release
# archive rehearsal. It intentionally runs on Bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="${BASH:-/bin/bash}"
LIST_ONLY=0
RUN_TESTS=1

# Recursion guard for the repo-wide merge gate (T007, libexec/orchid-merge).
# When this script IS a repository's `merge_gate`, `orchid merge` already sets
# this marker in the gate's environment; setting it here covers the other
# direction — an operator, or the hosted CI job in .github/workflows/ci.yml,
# running the suite DIRECTLY with no merge above it, where any `orchid merge`
# a test spawns would otherwise be free to open the first level of the loop
# and re-enter this file. Between the two, the nesting is closed from both
# ends.
#
# Set before the arguments are parsed, so no early-exit path (`--help`,
# `--list-shell`) is a hole a later addition could fall through, and a long
# way ahead of the `tests/run.sh` invocation at the bottom, which is where the
# re-entry would actually happen.
export ORCHID_MERGE_GATE_ACTIVE=1

usage() {
  cat <<'EOF'
usage: scripts/ci-local.sh [--bash /path/to/bash] [--list-shell] [--no-tests]

  --bash PATH    use PATH for syntax checks and every test script
  --list-shell   print every discovered shipped shell script, then exit
  --no-tests     run every static check, run no test script, then exit
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
    --no-tests) RUN_TESTS=0; shift ;;
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

# The mtime idiom that must not come back. `stat` spells the mtime format one
# way on BSD and another on GNU, and the obvious way to bridge that -- run one
# spelling, fall back to the other on non-zero exit -- is wrong on Linux: GNU's
# -f is --file-system and takes no argument, so the format word is read as a
# second FILE operand. GNU stat then fails on it, succeeds on the real path,
# prints that path's filesystem block, and the caller's arithmetic dies under
# set -u with `File: unbound variable`. That is not hypothetical: it took
# lock_acquire, and with it every durable verb, down on ubuntu-latest.
#
# lib/common.sh's file_mtime is the one correct implementation -- it selects
# on the RESULT, not the exit status -- and this gate exists because the fix
# ALREADY existed once, in libexec/orchid-start, and five other sites kept the
# broken form anyway (lesson L019, and L016 before it). A correct pattern that
# nothing forces you to use is not a fix. Call file_mtime; only `file_mtime`
# ITSELF may name either spelling, and docs/contributing.md writes them out
# for humans -- it is not a shell file, so this gate never scans it.
#
# That exemption is the helper's own comment-and-body block, NOT the six
# hundred lines of lib/common.sh around it. A whole-file pass would let the
# next raw idiom land beside the helper written to prevent it -- L016 and
# L019 a third time, one file in -- and lib/common.sh is the worst place to
# allow it, since lock_acquire lives there too.
#
# The match is deliberately wider than the single spelling that broke CI: the
# separator between the option and the format is optional and may be quoted,
# and GNU's long-option spellings are covered alongside -c -- with their `=`
# optional too, because getopt_long takes the value as a separate argument
# just as happily, so a bare `--format <fmt>` is the same command written a
# different way. A gate that only rejects the exact text of the last outage
# is not a gate -- the next author reaches for whichever spacing they
# habitually type, and it sails through.
# As with the find gate above, the pattern is assembled -- here around the `%`
# -- so this file never contains either directive literally and cannot flag
# itself. That is also why the prose above says "the mtime format" rather than
# writing it out; docs/contributing.md is where a human reads the real thing.
echo "== Portability policy (mtime via lib/common.sh file_mtime)"
mtime_sep="[[:space:]'\"]*"
raw_mtime_idiom="stat[^;|&]*[-]f${mtime_sep}%"
raw_mtime_idiom="${raw_mtime_idiom}m|stat[^;|&]*[-](c|-format|-printf)=?${mtime_sep}%"
raw_mtime_idiom="${raw_mtime_idiom}Y"

# Line bounds of file_mtime's documented block in lib/common.sh: its doc
# header through the closing brace of the function that follows. Both are
# anchored to column 0, so nothing nested inside the helper can end it early.
# Returns non-zero when the block cannot be located at all -- the helper was
# renamed or moved -- which the caller treats as "cannot judge", never as
# "exempt".
MTIME_EXEMPT_FIRST=0
MTIME_EXEMPT_LAST=0
locate_mtime_helper() {
  local file="$1" line
  MTIME_EXEMPT_FIRST=0
  MTIME_EXEMPT_LAST=0
  while IFS= read -r line; do
    MTIME_EXEMPT_FIRST="${line%%:*}"
    break
  done < <(grep -n '^# file_mtime <path>' "$file" || true)
  [ "$MTIME_EXEMPT_FIRST" -gt 0 ] || return 1
  while IFS= read -r line; do
    if [ "${line%%:*}" -gt "$MTIME_EXEMPT_FIRST" ]; then
      MTIME_EXEMPT_LAST="${line%%:*}"
      break
    fi
  done < <(grep -n '^}$' "$file" || true)
  [ "$MTIME_EXEMPT_LAST" -gt 0 ] || return 1
}

# lib/common.sh, scanned with the helper's own block carved out.
check_mtime_helper_file() {
  local file="$1" line hit=0
  if ! locate_mtime_helper "$file"; then
    grep -Eq "$raw_mtime_idiom" "$file" || return 0
    echo "ci-local: lib/common.sh names a platform-specific stat format but its file_mtime helper cannot be located — the exemption is scoped to that helper, so a hit outside it cannot be judged (see lesson L019)" >&2
    return 1
  fi
  while IFS= read -r line; do
    if [ "${line%%:*}" -lt "$MTIME_EXEMPT_FIRST" ] || [ "${line%%:*}" -gt "$MTIME_EXEMPT_LAST" ]; then
      printf '%s\n' "$line" >&2
      hit=1
    fi
  done < <(grep -En "$raw_mtime_idiom" "$file" || true)
  [ "$hit" -eq 0 ] || {
    echo "ci-local: lib/common.sh reads an mtime with a platform-specific stat format outside its own file_mtime helper (exempt: lines $MTIME_EXEMPT_FIRST-$MTIME_EXEMPT_LAST) — call file_mtime instead (see lesson L019)" >&2
    return 1
  }
  return 0
}

for rel in "${SHELL_FILES[@]}"; do
  if [ "$rel" = lib/common.sh ]; then
    check_mtime_helper_file "$ROOT/$rel" || exit 1
    continue
  fi
  if grep -En "$raw_mtime_idiom" "$ROOT/$rel" >&2; then
    echo "ci-local: $rel reads an mtime with a platform-specific stat format — call lib/common.sh's file_mtime instead (it selects on the result, not the exit status; see lesson L019)" >&2
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
# Inline, line-scoped directives audited above are the only allowed policy.
# Ignore repository-parent and user/global rc files so ambient configuration
# cannot suppress a warning that CI is responsible for detecting.
shellcheck --norc --shell=bash --severity=warning -- "${SHELLCHECK_PATHS[@]}"

# Everything above this line is static: it reads the shipped scripts and never
# runs one. Everything below runs test scripts — the aggregate suite, then the
# invariant and documentation rehearsals. `--no-tests` is the cut between
# them, and it exists for one caller: this repository's `merge_gate`
# (orchid.config; libexec/orchid-merge). At merge, the merged tree has already
# had THE TASK'S OWN suite run on it, because `orchid merge` runs that task's
# `verification_commands` (or, failing that, config `verify`) in the same temp
# worktree first. What that run does NOT give you is any of the static half
# above — no task's own suite has ever included the ShellCheck gate, which is
# the whole of lesson L016: seventeen findings behind a green suite. So the
# floor this repository sets for itself is that static half alone. Adding the
# test half to it would re-run, on the identical tree, tests that had just
# finished; the cut here is where the reason to run something stops.
#
# SAY THE LIMIT OUT LOUD, because it is L016's own shape one level in. "The
# task's own suite" is not "the full suite": `verification_commands` is
# authored per task, and a narrowly-scoped task names two or three files, not
# tests/run.sh. So what `--no-tests` leaves in the floor is the static half
# only, and the TEST half of a merge's coverage is still exactly as wide as
# the task author made it. This cut does not fix that and is not pretending
# to — it fixes the half no task ever named at all. A repository that wants
# its whole suite in the floor drops `--no-tests` from its `merge_gate` and
# pays a second full run on every merge; that is the honest price of the
# stronger guarantee, and it is a repository-level decision rather than one
# this script should make by omission.
#
# It is a cut, not a filter: a static check added ANYWHERE above this line is
# in the gate automatically, with nothing to remember and nothing to enrol.
# tests/test_ci_release.sh runs this flag for real and asserts what it printed,
# so a new section added below the line by mistake is caught rather than
# silently skipped at every merge.
if [ "$RUN_TESTS" -eq 0 ]; then
  echo "CI PASS (static checks only; --no-tests)"
  exit 0
fi

echo "== Full test suite"
ORCHID_TEST_BASH="$BASH_BIN" "$BASH_BIN" "$ROOT/tests/run.sh"

# These are already part of tests/run.sh. Rehearse them explicitly so their
# status remains visible as first-class CI gates even if the aggregate runner
# is reorganized later.
ci_run_test() {
  local label="$1" out rc=0
  shift
  out="$(mktemp "${TMPDIR:-/tmp}/orchid-ci-test-output.XXXXXX")"
  ORCHID_TEST_BASH="$BASH_BIN" "$@" > "$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Match tests/run.sh's evidence-preserving quiet-success contract.  The
    # parent observes the exit status before deciding what to expose, so test
    # output cannot manufacture a successful framing record around a defect.
    grep -E '^[[:space:]]*(NOT-TESTED:|not-tested:|RED-CASE:|GREEN-CASE:|red-cases:)' \
      "$out" || true
    printf '%s: OK\n' "$label"
  else
    cat "$out"
  fi
  rm -f "$out"
  return "$rc"
}

echo "== Invariant tests"
for rel in "$ROOT"/tests/inv/test_*.sh; do
  [ -e "$rel" ] || continue
  ci_run_test "$rel" "$BASH_BIN" "$rel"
done

echo "== Documentation checks"
ci_run_test "$ROOT/tests/test_docs.sh" "$BASH_BIN" "$ROOT/tests/test_docs.sh"

echo "CI PASS"
