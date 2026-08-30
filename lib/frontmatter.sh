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
# Deliberately a STRUCTURAL check, not a schema check: it asks whether the
# document has frontmatter at all (opens with `---`, closes with `---`), whether
# every line inside it is an ENTRY, and, when the caller names one, whether a
# single required key resolves. It never asks which keys are present, what their
# values mean, or whether they are the ones a task needs -- template frontmatter
# carries `# ...` comment lines and optional-empty keys, and anything stricter
# than "each line is `key:`, `key: value`, a comment, or blank" would reject
# files that are entirely healthy.
fm_check() {
  local f="$1" k="${2:-}" first="" delims=""
  local bad_line="" bad_no="" bad_txt=""
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
  # INSIDE the delimiters (T034 rework). Everything above asks whether the
  # document HAS frontmatter; nothing above looks in it, and the damage this
  # function exists to name lands in it. A value that arrives carrying a newline
  # -- an operator pasting prose, a `\n` an older `sed` renderer expanded, an
  # `awk -v` operand whose escape was processed -- does not empty the file: it
  # splits one entry across two lines, so the key is truncated at the break and
  # the REMAINDER sits in the frontmatter as a line belonging to no key. Every
  # reader here is line-oriented, so that file looks perfectly healthy to all of
  # them: both delimiters are present, `id` resolves, `task show` prints it, and
  # only the split field is quietly wrong. This is the one shape of task-file
  # damage that survives the checks above, and it is the shape the writers this
  # task hardened used to PRODUCE.
  #
  # Four line shapes are legal, which is exactly what the shipped templates and
  # every live task file use: `key: value`, a valued-later bare `key:`, a `#`
  # comment, and an empty line. Anything else is a remainder.
  #
  # The excerpt is truncated because this function contracts to print ONE line
  # and a split value carries as much prose as the operator pasted; the line
  # NUMBER is what locates the damage, and the text is there to make it
  # recognizable.
  #
  # `[[:space:]]`, never a `\t` inside a bracket expression: an escape sequence
  # there is undefined by POSIX and the awks disagree about it, and this
  # predicate decides whether live task files are readable on every platform
  # orchid runs on. The entry pattern requires colon-SPACE (or a bare colon)
  # for the same reason fm_get reads `k": "` -- a value this pattern admitted
  # but fm_get could not find would be a check disagreeing with the reader it
  # exists to protect.
  bad_line="$(awk '
    /^---$/ { n++; if (n >= 2) exit; next }
    n == 1 {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
      if ($0 ~ /^[A-Za-z_][A-Za-z0-9_-]*:( .*)?$/) next
      excerpt = $0
      if (length(excerpt) > 60) excerpt = substr(excerpt, 1, 57) "..."
      printf "%d\t%s\n", FNR, excerpt
      exit
    }' "$f" || true)"
  if [ -n "$bad_line" ]; then
    bad_no="${bad_line%%$'\t'*}"; bad_txt="${bad_line#*$'\t'}"
    printf "malformed frontmatter: line %s is not a 'key: value' entry (%s) — a value split across two lines leaves exactly this behind\n" \
      "$bad_no" "$bad_txt"
    return 1
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
# STRUCTURE only, never a required key: fm_check is called with no key here, so
# a rewrite is judged on whether the document it would land is READABLE, not on
# which fields it carries. A rework arm that refused a task for a missing
# `candidate_sha` would be a dead end where a truncation is a recoverable
# accident.
#
# It does check structure, though (T034 rework), and that is a deliberate
# widening: a producer that emits a task whose frontmatter has a line belonging
# to no key has produced damage, and appending a rework brief to a damaged task
# only buries it deeper. The refusal names the line and leaves the previous
# document in place to be recovered -- which is the same answer `task show` and
# `orchid doctor` give about the same file, from the read end.
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
  # Checked for the same reason fm_set's is, plus one of its own: an unchecked
  # `mv` that loses leaves the staged temp file next to the task, and these are
  # named `<task>.md.fmwrite.XXXXXX` in `.orchid/tasks/` itself.
  if ! mv "$t" "$f"; then
    rm -f "$t"
    echo "orchid: rewriting $f FAILED at the final rename — $f is unchanged, and nothing was written." >&2
    return 1
  fi
}

# fm_write_task_from <file> <producer> [args...] -- run <producer> to build a
# whole task document, and hand it to fm_write_task ONLY when the producer
# exited 0. The producer writes to stdout exactly as it would in a pipe; what
# changes is that its status is read BEFORE anything is renamed.
#
# T034 rework -- THE HOLE fm_write_task ALONE CANNOT SEE. Every caller spells
# the rewrite `producer | fm_write_task "$f"`, and in that shape the producer's
# exit status arrives (through `pipefail`) only after fm_write_task has already
# decided. fm_write_task judges the BYTES it was handed, which closes the two
# loud failures -- a producer that emits nothing, and one whose output is not a
# frontmatter document -- but not the quiet one: a producer that dies partway
# through a task it was streaming line by line has already emitted the opening
# `---`, the frontmatter, the closing `---` and part of the body. That fragment
# is a perfectly well-formed document. fm_check accepts it, the rename lands it,
# and the task silently loses the tail of its body -- the rework history, the
# operator guidance, everything appended below the fields. That is the same
# accident as F34's zero-byte file, one layer up and harder to notice, because
# what survives looks right.
#
# So the producer runs to a staged file and is judged on its STATUS first, and
# only a producer that finished is allowed to become the task. A producer that
# failed leaves the previous document in place, exactly as a refused rewrite
# does.
#
# THE PRODUCERS ARE FAIL-CLOSED THEMSELVES, and this is the other half. Callers
# of this function run under `set -e`, and errexit is suppressed inside any
# command whose status is being tested -- which is what this function does to
# the producer by construction. A producer that relied on errexit to abort
# partway would therefore run ON past its own failed step here and could still
# return 0. Every producer handed to this function checks its own steps and
# returns non-zero itself (see orchid-task's refresh_briefs); this function is
# what makes that return mean something.
fm_write_task_from() {
  local f="$1"; shift
  local stage="" prc=0 rc=0
  stage="$(mktemp "$f.fmprod.XXXXXX")" || return 1
  "$@" > "$stage" || prc=$?
  if [ "$prc" -ne 0 ]; then
    rm -f "$stage"
    echo "orchid: refusing to rewrite $f: the producer that builds the replacement document ('$1') exited $prc, so what it emitted is at best a fragment of the task — nothing was written to $f, which is left exactly as it was." >&2
    return 1
  fi
  fm_write_task "$f" < "$stage" || rc=$?
  rm -f "$stage"
  return "$rc"
}

# fm_render_task_template <template> <id> <title> <archetype> <engine> <date>
# -- render a `templates/task*.md` to stdout with its five __PLACEHOLDER__
# tokens replaced by the caller's values, LITERALLY. Hand it to
# fm_write_task_from, which is the writing half of the same contract.
#
# T034 rework (attempt-1 gap). `task create` used to render the template with
#
#     sed -e "s|__TITLE__|$title|g" ...
#
# and a sed REPLACEMENT string is not literal text -- it is a small language.
# Three of its metacharacters are ordinary characters in a task title an
# operator types, and two of the three fail SILENTLY: sed exits 0, the task file
# is well-formed frontmatter, and only the title is wrong.
#
#   * `&` stands for the WHOLE MATCH. `orchid task create T1 'parser & lexer'`
#     wrote `title: parser __TITLE__ lexer` -- the placeholder, reinstated into
#     the value that was supposed to replace it.
#   * `\` introduces an escape whose meaning is IMPLEMENTATION-DEFINED. The two
#     characters `\` `n` -- what an operator writes when flattening prose onto
#     one line, which is the same shape fm_set already had to close for values
#     -- become a REAL newline under GNU sed (splitting `title:` across two
#     lines and landing the remainder as a key-less frontmatter line) and the
#     single letter `n` under BSD sed. Two platforms, two different wrong
#     answers, neither of them what was typed.
#   * `|` is the s-command delimiter itself. That one at least failed loudly.
#
# So the substitution is done in awk out of ENVIRON, for exactly the reason
# fm_set reads its own operands that way: ENVIRON is a byte-for-byte read of the
# environment with no escape processing anywhere in it.
#
# ONE LEFT-TO-RIGHT SCAN, never one pass per placeholder. A sequence of passes
# rescans text that earlier passes already substituted, so a title of
# `__DATE__` would be replaced again by the pass that follows it. A value has to
# be INERT once placed, which a single scan gives for free: everything already
# emitted is behind the cursor.
#
# ALL-OR-NOTHING OUTPUT. The document is accumulated and printed from END, so an
# awk that dies partway emits nothing at all rather than a truncated document --
# which, cut in the body, would still carry both `---` delimiters and would sail
# through fm_write_task's shape check.
fm_render_task_template() {
  local tmpl="$1"
  if [ ! -f "$tmpl" ]; then
    echo "orchid: task template $tmpl is missing (or is not a regular file) — nothing was rendered and no task file was written" >&2
    return 1
  fi
  ORCHID_TPL_ID="$2" ORCHID_TPL_TITLE="$3" ORCHID_TPL_ARCHETYPE="$4" \
  ORCHID_TPL_ENGINE="$5" ORCHID_TPL_DATE="$6" awk '
    function render(s,   out, at, hit, i, p) {
      out = ""
      while (1) {
        at = 0; hit = 0
        for (i = 1; i <= np; i++) {
          p = index(s, ph[i])
          if (p > 0 && (at == 0 || p < at)) { at = p; hit = i }
        }
        if (hit == 0) return out s
        out = out substr(s, 1, at - 1) val[hit]
        s = substr(s, at + length(ph[hit]))
      }
    }
    BEGIN {
      np = 5
      ph[1] = "__ID__";        val[1] = ENVIRON["ORCHID_TPL_ID"]
      ph[2] = "__TITLE__";     val[2] = ENVIRON["ORCHID_TPL_TITLE"]
      ph[3] = "__ARCHETYPE__"; val[3] = ENVIRON["ORCHID_TPL_ARCHETYPE"]
      ph[4] = "__ENGINE__";    val[4] = ENVIRON["ORCHID_TPL_ENGINE"]
      ph[5] = "__DATE__";      val[5] = ENVIRON["ORCHID_TPL_DATE"]
    }
    { doc = doc render($0) "\n" }
    END { printf "%s", doc }
  ' "$tmpl"
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
#
# BOTH OPERANDS, not just the value. Moving off `-v` removed awk's own refusal
# of a newline, which is the only thing that ever objected to one in the KEY --
# `print k ": " v` would now emit it happily, splitting one frontmatter entry
# across two lines and landing the remainder as a key of its own. That is the
# same rule broken by the same accident (`task set` takes the key from the
# command line too), so the guard is written over the pair.
#
# THE REMEDY THIS MESSAGE NAMES IS THE ONE THAT IS ALWAYS TRUE HERE (T034
# rework). It used to name `orchid task unblock`/`orchid task retry`, and this
# function does not write only task files -- `orchid run` and `orchid plan`
# fm_set `run_status` into `.orchid/roadmap.md`, where a task verb is not a
# remedy at all, and even on a task file those two verbs are legal only from
# `blocked`/`rework`. A library backstop cannot know either thing. Flattening
# is the answer that holds for every caller and every file, so that is what it
# says; the VERB that called it is where a remedy fitted to the file and its
# current state belongs (orchid-task's _no_newline).
#
# AND THE DOCUMENT IT WOULD PRODUCE IS CHECKED, not just its emptiness (T034
# rework). The two guards above are about the operands arriving intact; neither
# asks whether what awk wrote is still a readable frontmatter document. It need
# not be, from either end:
#
#   * A KEY THAT IS NOT A KEY. `orchid task set T1 'hook guidance' x` -- a space
#     where an underscore was meant -- appends `hook guidance: x`, which is not
#     an entry. One typo in one argument, and every reader of that task
#     (`task show`, `orchid doctor`, the driver's walk) reports it DAMAGED from
#     then on. The write end has to refuse what the read end refuses, or a
#     single `task set` bricks a task exactly as the newline used to.
#   * A FILE THAT WAS ALREADY DAMAGED. awk copies the lines it does not match
#     through untouched, so a rewrite of a file carrying a key-less remainder
#     line produces another one, reports success, and buries the damage under a
#     fresh value. Naming it here is the difference between "this write is
#     wrong" and "this file was already wrong", which are different accidents
#     with different recoveries -- so the original is asked too, and answered
#     for separately.
fm_set() {
  local f="$1" k="$2" v="$3" t="" why="" was=""
  case "$k$v" in
    *$'\n'*)
      echo "orchid: refusing to write '$k': frontmatter is one 'key: value' per line and this key or value contains a newline. Nothing was written and $f is unchanged. Flatten it to a single line — a literal \\n is stored as those two characters and read back unchanged, never expanded. Nothing under .orchid/ is ever hand-edited; the verb you called names the remedy that fits this file." >&2
      return 1 ;;
  esac
  t="$(mktemp "$f.fmset.XXXXXX")" || return 1
  if ORCHID_FM_KEY="$k" ORCHID_FM_VAL="$v" awk '
    BEGIN { k = ENVIRON["ORCHID_FM_KEY"]; v = ENVIRON["ORCHID_FM_VAL"] }
    /^---$/ { n++; if (n==2 && !done) { print k ": " v; done=1 }; print; next }
    n==1 && index($0,k": ")==1 { print k ": " v; done=1; next }
    n==1 && $0==k":" { print k ": " v; done=1; next }
    { print }' "$f" > "$t" && [ -s "$t" ]; then
    if ! why="$(fm_check "$t")"; then
      rm -f "$t"
      if ! was="$(fm_check "$f")"; then
        echo "orchid: refusing to set '$k' in $f: that file is ALREADY damaged ($was), so this write would bury the damage under a fresh value rather than repair it. $f is unchanged. Recover it first — 'orchid task show <id>' and 'orchid doctor' report the same damage against the same path, and a committed copy comes back with 'git checkout <sha> -- <path>'." >&2
      else
        echo "orchid: refusing to set '$k' in $f: the document that write would produce cannot be read back ($why). $f is unchanged. A frontmatter entry is 'key: value' on one line, so the key must be a plain name — letters, digits, '_' and '-', starting with a letter or '_'." >&2
      fi
      return 1
    fi
    # The rename is CHECKED, and its failure is a failure of fm_set. `mv` can
    # lose (a read-only directory, a full filesystem) and the bare form left
    # `return 0` to run behind it -- reporting a successful write of a value
    # that is not in the file, which is the fail-open half of the very defect
    # this function was rewritten to close. Callers under `set -e` were covered
    # by errexit; every caller that spells `fm_set ... || rc=$?`, and every test
    # that sources this library without errexit, was not.
    if ! mv "$t" "$f"; then
      rm -f "$t"
      echo "orchid: setting '$k' in $f FAILED at the final rename — $f is unchanged (it still holds the previous value), and nothing was written." >&2
      return 1
    fi
    return 0
  fi
  rm -f "$t"
  echo "orchid: refusing to rewrite $f: setting '$k' produced an empty document (the file is unreadable, or already empty). Left byte-for-byte as it was — an empty rewrite here is how a task file gets destroyed, not how one gets updated." >&2
  return 1
}
