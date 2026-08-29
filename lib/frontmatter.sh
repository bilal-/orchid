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
  # Checked for the same reason fm_set's is, plus one of its own: an unchecked
  # `mv` that loses leaves the staged temp file next to the task, and these are
  # named `<task>.md.fmwrite.XXXXXX` in `.orchid/tasks/` itself.
  if ! mv "$t" "$f"; then
    rm -f "$t"
    echo "orchid: rewriting $f FAILED at the final rename — $f is unchanged, and nothing was written." >&2
    return 1
  fi
}

# fm_render_task_template <template> <id> <title> <archetype> <engine> <date>
# -- render a `templates/task*.md` to stdout with its five __PLACEHOLDER__
# tokens replaced by the caller's values, LITERALLY. Pipe it into fm_write_task,
# which is the writing half of the same contract.
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
fm_set() {
  local f="$1" k="$2" v="$3" t=""
  case "$k$v" in
    *$'\n'*)
      echo "orchid: refusing to write '$k': task frontmatter is one 'key: value' per line and this key or value contains a newline. Nothing was written and $f is unchanged. Flatten the value to a single line, or put multi-paragraph text in the task BODY (below the closing '---')." >&2
      return 1 ;;
  esac
  t="$(mktemp "$f.fmset.XXXXXX")" || return 1
  if ORCHID_FM_KEY="$k" ORCHID_FM_VAL="$v" awk '
    BEGIN { k = ENVIRON["ORCHID_FM_KEY"]; v = ENVIRON["ORCHID_FM_VAL"] }
    /^---$/ { n++; if (n==2 && !done) { print k ": " v; done=1 }; print; next }
    n==1 && index($0,k": ")==1 { print k ": " v; done=1; next }
    n==1 && $0==k":" { print k ": " v; done=1; next }
    { print }' "$f" > "$t" && [ -s "$t" ]; then
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
