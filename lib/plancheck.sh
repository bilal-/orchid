#!/usr/bin/env bash
# lib/plancheck.sh -- the PLANNING-time carry-forward cross-check (T021).
#
# THE FAILURE THIS EXISTS FOR. r-002's own requirements omitted a defect
# r-001 had already found, recorded, and journaled -- the once-only
# `started_at` anchor -- and it blocked a task hours into the run. The
# operator had eighteen active lessons and the previous run's entire journal
# available while scoping, and still missed one. That is lesson L016's
# pattern ("a correct mechanism that nothing forces you to use is not a
# fix") applied to KNOWLEDGE rather than to a gate: the information existed
# and nothing made anyone look at it.
#
# So this is not a search tool an operator may remember to run. It is wired
# into `orchid plan apply` -- the one irreversible step of PROTOCOL.md's
# PLANNING procedure -- and refuses to let a roadmap be committed while a
# carried-forward item is neither covered by a task nor explicitly deferred.
#
# WHAT IS CARRIED FORWARD. Two kinds, both already durable; this file
# invents no new store:
#
#   ledger items -- entries in the PREVIOUS run's archived journal
#     (`.orchid/runs/<prev>/journal.md`, which `orchid run new` moves there
#     verbatim and nothing ever rewrites) that record a finding the run
#     knowingly did not close. Recognized three ways: an entry whose kind is
#     `ledger` (the deliberate spelling, docs/specs/kernel.md's journal
#     kinds); an entry whose kind is `plan_deferral`, because a deferral is
#     a decision about ONE plan and must not become a permanent silencing --
#     an item deferred last run comes back this run, still needing a task or
#     a fresh reason; and -- because r-001 predates the `ledger` kind and
#     wrote its ledger candidates as prose inside `intervention`/
#     `arbitration` entries -- an entry whose text contains "ledger
#     candidate" or "ledger item". That prose fallback is not decoration: it
#     is the only reason this check catches the exact miss that motivated
#     it. Ids are `<run-id>#<n>`, where n is the entry's ordinal in that
#     archived journal (immutable, so the id is stable, and an operator can
#     confirm it with `grep -n '^## ' .orchid/runs/<prev>/journal.md`).
#
#   active lessons -- blocks in `.orchid/lessons.md` that `orchid run new`
#     carried across the rollover (it keeps ACTIVE blocks only). Ids are the
#     lesson ids. A lesson written DURING this run's own planning is not
#     carried-forward context, so blocks whose `first:` postdates the
#     current journal's start are skipped -- see plancheck_lesson_items for
#     why that comparison is deliberately inclusive at the boundary.
#
# COVERAGE IS APPROXIMATE, AND ASYMMETRICALLY SO. The question this check
# asks is "did anyone LOOK at this?", not "is this correctly scheduled?" --
# no text match can answer the second. So the matching is built to fail
# toward UNCOVERED: it associates an item with a task only on a distinctive
# anchor term (a snake_case identifier, a repo-relative source path, an
# `INV-nn`, a lesson id), never on ordinary prose, and an item that yields
# no anchor at all is reported as uncovered rather than waved through. A
# spurious "uncovered" costs one `orchid plan defer`; a spurious "covered"
# costs what r-002 already paid.
#
# And because it IS approximate, every `covered` line names the anchor that
# fired. A bare "covered (task T010)" has to be taken on trust; "covered
# (task T010 via started_at)" can be read and rejected in a second. The
# whole feature exists because a plausible-looking pass went unexamined, so
# the one verdict that closes an item states its own evidence.
#
# Sourced after lib/common.sh (orchid_die is not used here, but callers'
# error paths are) and after lib/lessons.sh, whose
# _lessons_journal_start_date defines "this run started here" for both this
# file and `lessons consolidate`.

# plancheck_prev_run_id <state> -- the newest run id archived under
# <state>/runs, or nothing at all when no run has ever rolled over (the
# first run of a repository, which is a legitimate and reported state, not
# an error). Numeric comparison on the suffix rather than a string sort, so
# r-1000 ranks above r-999 the day that matters.
plancheck_prev_run_id() {
  local state="$1" entry name num best="" best_num=-1
  [ -d "$state/runs" ] || return 0
  for entry in "$state"/runs/*; do
    [ -d "$entry" ] || continue
    name="${entry##*/}"
    case "$name" in
      r-[0-9]*) num="${name#r-}" ;;
      *) continue ;;
    esac
    case "$num" in ''|*[!0-9]*) continue ;; esac
    if [ "$((10#$num))" -gt "$best_num" ]; then
      best_num="$((10#$num))"; best="$name"
    fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

# plancheck_ledger_items <archived-journal> <run-id> -- one tab-separated
# "id<TAB>kind<TAB>summary<TAB>text" line per ledger item in that journal.
# `summary` is the entry's first non-blank body line (truncated for the
# report); `text` is the whole entry flattened onto one line, which is what
# anchor extraction reads. Both have any literal tab squeezed to a space so
# the four fields survive a `read -r` with IFS=tab.
plancheck_ledger_items() {
  local jf="$1" rid="$2"
  [ -f "$jf" ] || return 0
  awk -v rid="$rid" '
    function emit(   k, low, s, t) {
      if (hdr == "") return
      # Journal header shape: "## <ISO8601> <task|run> <kind> (<actor>)".
      split(hdr, ha, " ")
      k = ha[4]
      low = tolower(hdr " " body)
      if (k != "ledger" && k != "plan_deferral" &&
          index(low, "ledger candidate") == 0 &&
          index(low, "ledger item") == 0) return
      # Never emit an empty field: the reader is `read -r` under IFS=tab,
      # and tab is IFS WHITESPACE, so a run of two tabs collapses to one
      # delimiter and every later field shifts left by one. An entry with no
      # body text is degenerate, not impossible, and it must still report as
      # itself rather than as a mangled neighbour.
      s = (first == "" ? "(entry has no body text)" : first)
      if (length(s) > 120) s = substr(s, 1, 117) "..."
      t = body
      gsub(/\t/, " ", s); gsub(/\t/, " ", t)
      printf "%s#%d\tledger\t%s\t%s\n", rid, idx, s, t
    }
    BEGIN { idx = 0; hdr = ""; body = ""; first = "" }
    /^## / { emit(); idx++; hdr = $0; body = ""; first = ""; next }
    { body = body " " $0; if (first == "" && $0 ~ /[^ \t]/) first = $0 }
    END { emit() }
  ' "$jf"
}

# plancheck_lesson_items <lessons.md> <cutoff> -- the same four-field shape,
# one line per ACTIVE lesson block carried in from before <cutoff> (the
# current journal's first-entry date, i.e. this run's own start).
#
# The boundary comparison is `<=`, not `<`, on purpose. Journal and lesson
# timestamps are both second-resolution, so a rollover and a lesson written
# in the same second are indistinguishable here; a tie therefore resolves
# toward INCLUDING the lesson. That is the safe direction for a gate whose
# whole job is to raise a question -- the cost of an extra item is one
# `orchid plan defer`, the cost of a dropped one is the miss this file
# exists to prevent. An empty cutoff (a journal with no entries at all)
# includes everything, for the same reason.
#
# Parsed here rather than through lib/lessons.sh's lessons_list_blocks
# because that helper's four-field line has no `first:`, and this check
# needs it to tell a carried-forward lesson from one this run's own planning
# wrote. Same header/field grammar, same source of truth (kernel.md's
# lessons.md format, restated at the top of lib/lessons.sh) -- if that
# grammar ever changes, both parsers move together.
plancheck_lesson_items() {
  local lf="$1" cutoff="$2"
  [ -f "$lf" ] || return 0
  awk -v cutoff="$cutoff" '
    function emit(   s) {
      if (id == "" || lstate != "active") return
      if (cutoff != "" && firstd != "" && firstd > cutoff) return
      # Same empty-field rule as plancheck_ledger_items above, same reason.
      s = (stmt == "" ? "(lesson has no statement)" : stmt)
      if (length(s) > 120) s = substr(s, 1, 117) "..."
      gsub(/\t/, " ", s)
      printf "%s\tlesson\t%s\t%s %s\n", id, s, id, stmt
    }
    /^## L/ {
      emit()
      line = $0; sub(/^## /, "", line); split(line, a, " ")
      id = a[1]; lstate = a[2]; gsub(/[][]/, "", lstate)
      stmt = ""; firstd = ""
      next
    }
    index($0, "statement: ") == 1 { stmt = substr($0, 12) }
    index($0, "first: ") == 1 { firstd = substr($0, 8) }
    END { emit() }
  ' "$lf"
}

# plancheck_item_ids <state> -- every carried-forward item id, one per line,
# in report order. Used by `orchid plan defer` to refuse an id that is not
# actually on the list (a typo'd deferral would otherwise look recorded
# while leaving the real item unconsidered -- the exact silent-pass shape
# this whole check exists to close).
plancheck_item_ids() {
  local state="$1" prev cutoff
  prev="$(plancheck_prev_run_id "$state")"
  [ -n "$prev" ] || return 0
  cutoff="$(_lessons_journal_start_date "$state/journal.md")"
  {
    plancheck_ledger_items "$state/runs/$prev/journal.md" "$prev"
    plancheck_lesson_items "$state/lessons.md" "$cutoff"
  } | cut -f1
}

# plancheck_anchors -- item text on stdin, its distinctive anchor terms on
# stdout (sorted, unique, one per line). Four shapes only:
#
#   L013                     a lesson id
#   INV-11                   an invariant id
#   libexec/orchid-task      a repo-relative source path
#   started_at               a snake_case identifier
#
# and snake_case/path terms shorter than six characters are dropped. What is
# deliberately NOT an anchor is ordinary English: "trust", "worktree",
# "review" appear in every task ever written and would make every item read
# as covered. The `|| true` on grep is required, not defensive -- callers run
# under `set -o pipefail`, where a no-match exit 1 would abort them.
plancheck_anchors() {
  { grep -oE 'L[0-9][0-9][0-9]|INV-[0-9]+|(lib|libexec|runners|roles|plugins|scripts|tests|docs|templates|bin)/[A-Za-z0-9_.-][A-Za-z0-9_./-]*|[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+' || true; } \
    | sed -E 's![./_-]+$!!' \
    | awk 'length($0) >= 6 || /^L[0-9][0-9][0-9]$/ || /^INV-[0-9]+$/' \
    | LC_ALL=C sort -u
}

# plancheck_task_text <task-file> -- the text a task is searched in: its body
# verbatim, plus the VALUES of the frontmatter fields that carry an author's
# INTENT (title, acceptance_criteria, stop_condition, hook_guidance,
# resources). Every other frontmatter line -- key and value both -- is
# dropped.
#
# This scoping is what makes the whole match trustworthy, and it is narrow
# in two separate ways, each closing a false `covered` that would reproduce
# the exact miss this file exists to prevent:
#
#   the KEYS go, because every task file carries `started_at:`,
#   `risk_tier:`, `wallclock_budget_s:` and a dozen more literally, so a
#   whole-file grep reports the `started_at` ledger item as covered by every
#   task in a plan that never once mentions it;
#
#   the MECHANICAL VALUES go too -- and `verification_commands` above all --
#   because they are boilerplate the operator writes for every task, which
#   makes any path inside them a UNIVERSAL anchor rather than a distinctive
#   one. This is not hypothetical: in r-002's own plan `scripts/ci-local.sh`
#   appears in all fifteen task files and in nothing but their verification
#   chains, and it is an anchor of two of r-001's largest ledger items --
#   including "make the CI gate part of every task's chain", the one finding
#   whose whole point is that per-task chains were not enough. Searching
#   those values reports both as covered by whichever task the glob happens
#   to list first. A task that runs the suite has not thereby CONSIDERED a
#   finding about the suite.
#
# An allowlist rather than a denylist, so a frontmatter field added later is
# ignored until someone decides it carries intent -- that direction costs an
# `orchid plan defer`, the other costs a silent pass. Frontmatter lines with
# no `key:` at all are dropped for the same reason: `fm_set` refuses an
# embedded newline, so a continuation line is malformed state, not a value
# this check should read intent from.
plancheck_task_text() {
  awk '
    BEGIN {
      n = split("title acceptance_criteria stop_condition hook_guidance resources", f, " ")
      for (i = 1; i <= n; i++) intent[f[i]] = 1
    }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm == 1 && $0 == "---" { fm = 0; next }
    fm == 1 {
      c = index($0, ":")
      if (c > 0 && substr($0, 1, c - 1) in intent) print substr($0, c + 1)
      next
    }
    { print }
  ' "$1"
}

# plancheck_deferral <journal.md> <item-id> -- the recorded deferral reason
# for that item, or exit 1 when none is recorded. `orchid plan defer` writes
# exactly one line, "deferred <id>: <reason>", as the body of a
# `plan_deferral` journal entry; item ids are `L<nnn>` or `r-<n>#<n>` and
# carry no regex metacharacter, so a line-anchored match is exact.
plancheck_deferral() {
  local jf="$1" id="$2" prefix line
  [ -f "$jf" ] || return 1
  prefix="deferred $id: "
  line="$(grep -m1 "^$prefix" "$jf" || true)"
  [ -n "$line" ] || return 1
  printf '%s\n' "${line#"$prefix"}"
}

# plancheck_report <state> -- print the cross-check for the roadmap
# currently drafted in <state>, and say what the caller should do:
#
#   0  nothing left unconsidered (including "there is no previous run" and
#      "the previous run left nothing", both of which are STATED rather than
#      passed over in silence -- an empty check and an unrun one look
#      identical otherwise, which is the L016 shape again)
#   3  at least one carried-forward item is neither covered nor deferred
#
# The per-item lines go to stdout (they are the report); the refusal and the
# recovery commands go to stderr, so a caller redirecting the report away
# still shows an operator why it stopped.
plancheck_report() {
  local state="$1"
  local prev cutoff tmp f id kind summary text hits hitfile hit via reason nitems nopen=0
  prev="$(plancheck_prev_run_id "$state")"
  if [ -z "$prev" ]; then
    echo "crosscheck: no previous run is archived under .orchid/runs/ — this is the first run of this repository, so nothing is carried forward"
    return 0
  fi

  cutoff="$(_lessons_journal_start_date "$state/journal.md")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-plancheck.XXXXXX")"
  {
    plancheck_ledger_items "$state/runs/$prev/journal.md" "$prev"
    plancheck_lesson_items "$state/lessons.md" "$cutoff"
  } > "$tmp/items"

  nitems="$(wc -l < "$tmp/items" | tr -d ' ')"
  if [ "$nitems" -eq 0 ]; then
    rm -rf "$tmp"
    echo "crosscheck: previous run $prev recorded no ledger items and carried no active lessons forward — nothing to cross-check (stated, not skipped)"
    return 0
  fi

  # One searchable copy per task of the CURRENT plan (body + intent-bearing
  # frontmatter, per plancheck_task_text), so each item costs a single
  # `grep -l` over the set rather than a grep per (item, task) pair.
  # Archived tasks under runs/<prev>/tasks/ are deliberately not searched:
  # the question is what THIS plan covers.
  mkdir -p "$tmp/tasks"
  for f in "$state"/tasks/*.md; do
    [ -f "$f" ] || continue
    plancheck_task_text "$f" > "$tmp/tasks/${f##*/}"
  done

  echo "crosscheck: $prev left $nitems carried-forward item(s); each must be covered by a task in this plan or explicitly deferred"
  while IFS=$'\t' read -r id kind summary text; do
    [ -n "$id" ] || continue
    printf '%s\n' "$text" | plancheck_anchors > "$tmp/anchors"
    hit=""; via=""
    if [ -s "$tmp/anchors" ]; then
      # No `| head -1`: `grep -l` short-circuits per file and head would
      # close the pipe under it, which `set -o pipefail` reports as a
      # failure of the whole match (lesson L005). Take the first line of a
      # captured result instead.
      hits="$(grep -lF -f "$tmp/anchors" "$tmp"/tasks/* 2>/dev/null || true)"
      hitfile="${hits%%$'\n'*}"
      if [ -n "$hitfile" ]; then
        hit="${hitfile##*/}"; hit="${hit%.md}"
        # WHICH anchor fired, so the one verdict that closes an item carries
        # its own evidence. Capped at three with a count of the rest --
        # `awk`, not `head`, for the L005 reason above -- because a long
        # arbitration entry can yield a dozen anchors and a report line
        # nobody finishes reading is a report nobody checks.
        via="$({ grep -oF -f "$tmp/anchors" "$hitfile" || true; } | LC_ALL=C sort -u \
          | awk 'NR <= 3 { printf "%s%s", (NR > 1 ? ", " : ""), $0 }
                 END { if (NR > 3) printf ", +%d more", NR - 3 }')"
      fi
    fi
    if [ -n "$hit" ]; then
      printf '  covered   [%s] %s — %s (task %s via %s)\n' "$kind" "$id" "$summary" "$hit" "$via"
      continue
    fi
    if reason="$(plancheck_deferral "$state/journal.md" "$id")"; then
      printf '  deferred  [%s] %s — %s (deferred: %s)\n' "$kind" "$id" "$summary" "$reason"
      continue
    fi
    printf '  UNCOVERED [%s] %s — %s\n' "$kind" "$id" "$summary"
    nopen=$((nopen + 1))
    printf '%s\t%s\n' "$id" "$summary" >> "$tmp/open"
  done < "$tmp/items"

  if [ "$nopen" -eq 0 ]; then
    rm -rf "$tmp"
    echo "crosscheck: all $nitems carried-forward item(s) considered"
    return 0
  fi

  echo "crosscheck: $nopen of $nitems carried-forward item(s) from $prev are neither covered by a task in this plan nor explicitly deferred:" >&2
  while IFS=$'\t' read -r id summary; do
    [ -n "$id" ] || continue
    printf '  %s — %s\n' "$id" "$summary" >&2
    printf '      cover it with a task in this plan, or record the decision: orchid plan defer %s --reason "..."\n' "$id" >&2
  done < "$tmp/open"
  rm -rf "$tmp"
  return 3
}
