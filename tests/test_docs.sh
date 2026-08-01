#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# v1-m4 Task 8: docs suite lint. Three independent, purely mechanical
# checks over the published documentation set -- no repo/run state, no git,
# nothing spawned -- mirroring test_config_keys.sh's own annotation-driven
# approach (grep-only, no prose heuristics) so this suite carries zero
# false-positive risk from trying to parse free text:
#
#   1. every `orchid <word>` CODE-SPAN, and every fenced-shell-block line
#      STARTING with "orchid <word>", in README.md/the two quickstarts
#      names a real tier-1 verb (a libexec/orchid-<word> file actually on
#      disk) -- catches a renamed/typo'd verb before a reader ever hits it.
#      (Scoped to just these three files deliberately: a prose sentence
#      elsewhere -- e.g. docs/engines/hermes.md's "orchid never manages
#      this..." -- would false-positive against the start-of-line half of
#      this pattern; README/the quickstarts never open a line with prose
#      starting in lowercase "orchid ", only with real fenced commands.)
#   2. every RELATIVE markdown link across this task's docs surface
#      (`docs_suite_files` below -- README + quickstarts + configuration/
#      troubleshooting/research + docs/engines/* + docs/extending/*;
#      deliberately NOT docs/specs/*.md, docs/plans/*.md, or
#      docs/dogfood-notes.md, which pre-date this task) resolves to a file
#      that actually exists on disk (absolute http(s)/mailto links and pure
#      #anchor links are out of scope -- nothing to resolve locally). The
#      link TARGET itself may freely point outside that surface (e.g. at
#      docs/specs/kernel.md or a plugins/engines/*/run source file).
#   3. every config key referenced, anywhere in that same surface, via
#      either annotation convention this docs suite actually uses --
#      PROTOCOL.md's own "`key` (config, default ...)" shape, and
#      docs/engines/{hermes,openclaw}.md's established "`key` (default
#      ...)" shape (Task 6/7, unmodified by this task) -- is a real line in
#      lib/config-keys.txt; AND docs/configuration.md (the
#      "generated-faithful complete key table") literally contains every
#      single line in lib/config-keys.txt, backtick-wrapped, so the table
#      can never silently drift behind a key addition/removal.
#
# RED (before this task writes anything): every check below fails --
# README.md and the quickstarts don't exist yet (verb/link loops find
# nothing, but the counts below they're compared against are all
# hand-listed as "must exist" assertions), docs/configuration.md doesn't
# exist (key-coverage loop fails outright), and the annotation-scan file
# list itself doesn't resolve.

DOCS="$REPO_ROOT/docs"
KEYFILE="$REPO_ROOT/lib/config-keys.txt"

# docs_suite_files -- the exact surface this task owns: README + the
# quickstarts + configuration/troubleshooting/research + every engine guide
# (built-in and reference-adapter alike) + the extending guides (cross-
# linked, not rewritten, by this task). Deliberately NOT docs/specs/*.md
# (the normative design spec, untouched by this task -- e.g. kernel.md's
# task-frontmatter field `blocking_severity` reads exactly like a config
# key under a naive scan but is not one), docs/plans/*.md, or
# docs/dogfood-notes.md (historical incident log, not part of the docs
# bar) -- those pre-date this task and use their own conventions.
docs_suite_files() {
  local f
  for f in "$REPO_ROOT/README.md" \
           "$REPO_ROOT/docs/quickstart.md" \
           "$REPO_ROOT/docs/quickstart-greenfield.md" \
           "$REPO_ROOT/docs/configuration.md" \
           "$REPO_ROOT/docs/troubleshooting.md" \
           "$REPO_ROOT/docs/research.md"; do
    [ -f "$f" ] && echo "$f"
  done
  [ -d "$REPO_ROOT/docs/engines" ] && find "$REPO_ROOT/docs/engines" -name '*.md' | sort
  [ -d "$REPO_ROOT/docs/extending" ] && find "$REPO_ROOT/docs/extending" -name '*.md' | sort
  return 0
}

# ===========================================================================
# 0 -- the files this task's brief requires must exist at all. Every check
# below silently finds "nothing to lint" against a missing file (an empty
# grep is not a failure on its own) -- so without this section, deleting
# README.md entirely would make checks 1-3 all pass vacuously.
# ===========================================================================
required_files="
README.md
docs/quickstart.md
docs/quickstart-greenfield.md
docs/configuration.md
docs/troubleshooting.md
docs/research.md
docs/engines/codex.md
docs/engines/claude.md
docs/engines/agy.md
docs/engines/codex-review.md
docs/engines/hermes.md
docs/engines/openclaw.md
"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || fail "required doc missing: $rel"
done <<< "$required_files"

# ===========================================================================
# 1 -- every `orchid <word>` code-span in README.md + the two quickstarts
# names a real tier-1 verb.
# ===========================================================================
verb_check_files="README.md docs/quickstart.md docs/quickstart-greenfield.md"
verb_words=""
for rel in $verb_check_files; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  words="$( { grep -oE '`orchid [a-zA-Z][a-zA-Z-]*' "$f" | sed -E 's/`orchid //'
             grep -oE '^orchid [a-zA-Z][a-zA-Z-]*' "$f" | sed -E 's/^orchid //'; } || true)"
  verb_words="$verb_words
$words"
done
verb_count=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  verb_count=$((verb_count + 1))
  [ -x "$REPO_ROOT/libexec/orchid-$v" ] || fail "a code-span names 'orchid $v' but libexec/orchid-$v doesn't exist (or isn't executable)"
done < <(printf '%s\n' "$verb_words" | sort -u)
[ "$verb_count" -gt 0 ] || fail "verb-name extraction from README/quickstarts found nothing -- files missing, or the regex broke"

# ===========================================================================
# 2 -- every relative markdown link across this task's docs surface
# resolves to a real file (which may legitimately live outside that surface
# -- e.g. a link to docs/specs/kernel.md or plugins/engines/codex/run).
# Absolute http(s)/mailto links and pure #anchor links are skipped --
# nothing local to resolve.
# ===========================================================================
link_count=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  dir="$(dirname "$f")"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in
      http://*|https://*|mailto:*) continue ;;
      '#'*) continue ;;
    esac
    target="${link%%#*}"
    [ -n "$target" ] || continue
    link_count=$((link_count + 1))
    [ -e "$dir/$target" ] || fail "$f: relative link target does not exist: $link (resolved: $dir/$target)"
  done < <(grep -oE '\]\([^) ]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//')
done < <(docs_suite_files)
[ "$link_count" -gt 0 ] || fail "relative-link extraction across README/docs found nothing -- files missing, or the regex broke"

# ===========================================================================
# 3a -- every config key referenced via either annotation shape this docs
# suite uses is a real line in lib/config-keys.txt.
# ===========================================================================
[ -f "$KEYFILE" ] || fail "lib/config-keys.txt missing"
key_known() { grep -qxF "$1" "$KEYFILE"; }

annot_count=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    annot_count=$((annot_count + 1))
    key_known "$key" || fail "$f: documents config key '$key' but lib/config-keys.txt has no such line"
  done < <(
    {
      grep -oE '`[a-zA-Z_][a-zA-Z_.<>-]*`[[:space:]]*\(config, default' "$f" | sed -E 's/`([a-zA-Z_.<>-]+)`.*/\1/'
      grep -oE '`[a-zA-Z_][a-zA-Z_.<>-]*`[[:space:]]*\(default' "$f" | sed -E 's/`([a-zA-Z_.<>-]+)`.*/\1/'
    } | sort -u
  )
done < <(docs_suite_files)
[ "$annot_count" -gt 0 ] || fail "config-key annotation scan across README/docs found nothing -- files missing, or the annotation convention changed"

# ===========================================================================
# 3b -- docs/configuration.md (the "generated-faithful complete key table")
# literally contains every single line in lib/config-keys.txt,
# backtick-wrapped -- the completeness direction test_config_keys.sh
# doesn't cover (that suite checks orchid.config.example/PROTOCOL.md, never
# docs/configuration.md, and never asserts completeness, only that
# mentioned keys are real).
# ===========================================================================
CONFIGURATION_MD="$REPO_ROOT/docs/configuration.md"
if [ -f "$CONFIGURATION_MD" ]; then
  cov_count=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    cov_count=$((cov_count + 1))
    grep -qF "\`$key\`" "$CONFIGURATION_MD" || fail "docs/configuration.md is missing key-reference row for '$key' (lib/config-keys.txt)"
  done < "$KEYFILE"
  [ "$cov_count" -gt 0 ] || fail "lib/config-keys.txt appears empty -- nothing to check completeness against"
else
  fail "docs/configuration.md missing -- cannot check key-table completeness"
fi
