#!/usr/bin/env bash
fm_get() {
  awk -v k="$2" '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3);exit} n>=2{exit}' "$1"
}

# fm_check <file> [required-key] -- 0 when <file> can be read as a frontmatter
# document; otherwise prints ONE line saying what is wrong with it and returns
# 1. The reason is printed rather than returned as a code because every caller
# (`orchid task show`, `orchid doctor`) exists to tell a human WHICH way the
# file is broken -- "empty" and "the delimiters are gone" are different
# accidents with different recoveries.
#
# T034 (dogfood F34, and the same accident on r-002's own T002): a task file
# destroyed by a failed rewrite reads as an ordinary absence to every consumer
# here -- `task show` printed nothing and exited 0, `task list` printed a row of
# empty fields -- so the first signal either dogfood operator got was a grep
# coming back empty. A file that cannot be parsed must be named as DAMAGED, not
# reported as a task with nothing in it.
#
# Deliberately a shape check, not a schema check: it asks whether the document
# has frontmatter at all (opens with `---`, closes with `---`) and, when the
# caller names one, whether a single required key resolves. Template frontmatter
# carries `# ...` comment lines and optional-empty keys, so anything stricter
# would reject files that are entirely healthy.
fm_check() {
  local f="$1" k="${2:-}" first="" delims=""
  if [ ! -e "$f" ]; then printf 'the file does not exist\n'; return 1; fi
  if [ ! -f "$f" ]; then printf 'the path is not a regular file\n'; return 1; fi
  if [ ! -s "$f" ]; then printf 'the file is EMPTY (0 bytes)\n'; return 1; fi
  # `|| true`, never `|| first=""`: `read` returns 1 on a final line with no
  # trailing newline, having ALREADY assigned it -- clearing the variable there
  # would report "no frontmatter" for a one-line file whose one line is `---`.
  IFS= read -r first < "$f" || true
  if [ "$first" != "---" ]; then
    printf 'no frontmatter: the first line is not the opening --- delimiter\n'; return 1
  fi
  # `|| true` because `grep -c` exits 1 when the count is zero.
  delims="$(grep -c '^---$' "$f" || true)"
  case "$delims" in ''|*[!0-9]*) delims=0 ;; esac
  if [ "$delims" -lt 2 ]; then
    printf 'unterminated frontmatter: there is no closing --- delimiter\n'; return 1
  fi
  if [ -n "$k" ] && [ -z "$(fm_get "$f" "$k")" ]; then
    printf "the frontmatter carries no '%s:' value\n" "$k"; return 1
  fi
  return 0
}

# fm_write_task <file> -- read a WHOLE task document from stdin and land it on
# <file> only if what arrived still parses as frontmatter; otherwise leave the
# file exactly as it was and refuse. A drop-in replacement for
# `... | atomic_write "$f"` at the sites that rewrite a task's entire body
# (libexec/orchid-task's rework arms, which pipe an aged body plus a fresh
# brief through a pipeline of their own).
#
# T034: atomic_write renames whatever its stdin gave it, and a producer that
# dies partway through -- or emits nothing at all -- therefore truncates the
# task. That is the same accident F34 hit through fm_set, reached from the
# other writer, and it is worth closing here rather than trusting each
# pipeline: `set -o pipefail` reports the producer's failure only AFTER the
# rename has already happened, so the caller's own error handling can never be
# early enough.
#
# Shape only (no required key), deliberately: this guard exists to catch a
# truncated or empty document, and refusing a task file that a repository has
# been running with for other reasons would turn a rework into a dead end.
fm_write_task() {
  local f="$1" t="" why=""
  t="$(mktemp "$f.fmwrite.XXXXXX")" || return 1
  if ! cat > "$t"; then
    rm -f "$t"
    echo "orchid: refusing to rewrite $f: the replacement document could not be staged to a temp file — nothing was written to $f" >&2
    return 1
  fi
  if ! why="$(fm_check "$t")"; then
    rm -f "$t"
    echo "orchid: refusing to rewrite $f: the replacement document is unusable ($why) — nothing was written to $f, which is left exactly as it was" >&2
    return 1
  fi
  mv "$t" "$f"
}

# fm_set (v1-m3, m2 ledger F9): the second n==1 rule below catches a key
# whose CURRENT line is bare "key:" (no trailing space, no value) --
# templates/task.md seeds exactly that for base_sha, candidate_sha,
# started_at, etc. Without it, that line matches neither this rule nor the
# "key: "-prefixed one above, so it falls through to `{ print }` untouched
# and a SECOND "key: value" line gets appended at the closing '---' instead
# -- a silently accumulating duplicate (fm_get still reads correctly, since
# it takes the first match and only the appended line ever matches, but the
# file itself rots). Both rules are scoped to n==1 (between the two '---'
# delimiters), so body text is never touched even if it looks like a key line.
#
# REWRITE-OR-REFUSE (T034, dogfood F34). This function used to be
# `awk ... | atomic_write "$f"`, and that pipeline had no way to tell a
# successful rewrite from a failed one: atomic_write consumes whatever awk
# managed to emit -- including NOTHING -- and renames it over the file. Two
# reachable inputs made awk emit nothing:
#
#   * a VALUE CONTAINING A NEWLINE. `awk -v v=...` rejects it ("newline in
#     string"), so awk dies before reading a single line of the file, and the
#     task file was left at ZERO BYTES: id, title, status, every field gone.
#     Not a rejected write, a destroyed file -- and the verb still exited 0.
#     It took out `.orchid/tasks/T002.md` on r-002 while an operator was
#     setting a multi-paragraph `hook_guidance`, and F34 hit it again.
#   * an ALREADY-EMPTY (or unreadable) `$f`. awk has nothing to print, so the
#     rewrite "succeeded" over and over against a file with nothing in it,
#     which is why the destruction stayed silent: every later `task set`
#     reported success too.
#
# So the newline is refused BEFORE anything is opened, naming the constraint
# (frontmatter is one `key: value` per line -- a reasonable rule; destroying
# the file when it is violated is not), and the rewrite lands through a temp
# file that is renamed ONLY when awk succeeded AND produced a non-empty
# document. A failed rewrite can no longer leave a truncated task behind: the
# original file is never opened for writing at all.
#
# ENVIRON, NEVER `-v` (T034). The guard above rejects a value that ARRIVES with
# a newline in it, but `-v v=...` is not a plain assignment: POSIX requires awk
# to process escape sequences in a `-v` operand, so the two characters `\` `n`
# typed on a command line -- `orchid task set T1 acceptance_criteria 'a\nb'`,
# which is an ordinary thing to write about a separator -- reach awk's `v` as a
# REAL newline that the case above never saw. That value then prints as two
# lines: the key's line is truncated at `a` and the remainder lands as a bogus
# frontmatter line of its own. Not the zero-byte destruction F34 found, but the
# same rule broken by the same field, and silently. `ENVIRON[...]` is a byte-
# for-byte read of the environment with no escape processing anywhere in it, so
# what the operator typed is what the file gets. The key travels the same way:
# it is caller-supplied too, and there is no reason to leave one operand in a
# quoting regime the other one needed to escape.
fm_set() {
  local f="$1" k="$2" v="$3" t=""
  case "$v" in
    *$'\n'*)
      echo "orchid: refusing to write '$k': task frontmatter is one 'key: value' per line and this value contains a newline. Nothing was written and $f is unchanged. Flatten the value to a single line, or put multi-paragraph text in the task BODY (below the closing '---')." >&2
      return 1 ;;
  esac
  t="$(mktemp "$f.fmset.XXXXXX")" || return 1
  if ORCHID_FM_KEY="$k" ORCHID_FM_VAL="$v" awk '
    BEGIN { k = ENVIRON["ORCHID_FM_KEY"]; v = ENVIRON["ORCHID_FM_VAL"] }
    /^---$/ { n++; if (n==2 && !done) { print k ": " v; done=1 }; print; next }
    n==1 && index($0,k": ")==1 { print k ": " v; done=1; next }
    n==1 && $0==k":" { print k ": " v; done=1; next }
    { print }' "$f" > "$t" && [ -s "$t" ]; then
    mv "$t" "$f"
    return 0
  fi
  rm -f "$t"
  echo "orchid: refusing to rewrite $f: setting '$k' produced an empty document (the file is unreadable, or already empty). Left byte-for-byte as it was — an empty rewrite here is how a task file gets destroyed, not how one gets updated." >&2
  return 1
}
