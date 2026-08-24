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
# AN ENTRY IS NOT A FINDING. The unit this check tracks is the FINDING, not
# the journal entry that records it, and the difference is the whole feature.
# r-001's journal really does carry entries like "CARRIED AS LEDGER ITEMS:
# (1) ... (2) ... (3) ... (4) ..." -- one entry, four separate defects in
# four separate subsystems. Tracked per ENTRY, a single task naming one of
# them marks the entry covered and the other three leave planning
# unconsidered, silently, under a green "covered" line. That is r-002's
# original miss reproduced by the very thing built to prevent it, so entries
# are decomposed into their individual findings (see plancheck_ledger_items)
# and each finding is covered, deferred or reported on its own.
#
# Decomposition is deliberately conservative, and what it does when it FAILS
# is the load-bearing part. An entry whose findings are written as an
# ascending `(1) `/`(2) `/... enumeration is split on those markers -- that
# is unambiguous. An entry that announces SEVERAL findings ("ledger items",
# "ledger candidates", "four outstanding findings") without enumerating them,
# or that enumerates fewer than the number it states, cannot be split without
# guessing where one finding ends and the next begins. Such an entry is
# marked UNDECOMPOSED: it is never matched against task text at all and
# reports UNCOVERED until an operator defers it by name with a reason. The
# operator says "I have considered these" in words; the check never infers it
# from a keyword that happens to appear. Refusing to decide beats deciding
# wrongly in the direction that loses findings.
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
#     confirm it with `grep -n '^## ' .orchid/runs/<prev>/journal.md`) --
#     or `<run-id>#<n>.<k>` for the k'th finding of an entry that was
#     decomposed into several.
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
# "id<TAB>kind<TAB>summary<TAB>mode<TAB>text" line per ledger FINDING in that
# journal (an entry recording several findings yields several lines).
# `summary` is the finding's own opening text, truncated for the report;
# `mode` is `anchor` (this finding may be matched against task text) or
# `undecomposed` (it may not -- see below); `text` is what anchor extraction
# reads. Every field has any literal tab squeezed to a space, and none is
# ever empty, so the five fields survive a `read -r` under IFS=tab: tab is
# IFS WHITESPACE, so two adjacent tabs would collapse into one delimiter and
# shift every later field left by one, reporting an entry as a mangled
# neighbour rather than as itself.
#
# THE THREE OUTCOMES, in the order they are tried:
#
#   ENUMERATED. The entry contains `(1) `, `(2) `, ... ascending, at least
#     two of them, each after the last -- the shape r-001's arbitration
#     entries actually use. Each marker opens a finding that runs to the next
#     marker (the last runs to the end), and each is emitted as
#     `<run>#<n>.<k>` with ONLY ITS OWN segment as text.
#
#     The preamble before `(1) ` is dropped from all of them on purpose:
#     text shared by every finding is text whose anchors would cover every
#     finding at once, which is the per-entry tracking this decomposition
#     exists to end. In r-001's journal the preamble is invariably the
#     lead-in narrative -- "ARBITRATION: APPROVE attempt 8 ... WHAT IS
#     KNOWINGLY DEFERRED:" -- and every finding lives inside the
#     enumeration, so nothing is lost by it; and the one way a preamble
#     could hide a finding of its own is by claiming more findings than the
#     enumeration accounts for, which the count cross-check below already
#     catches. Dropping it can only remove anchors, and a missing anchor
#     costs one `orchid plan defer` while a shared one costs a lost finding.
#
#   UNDECOMPOSED. Any of the ways the split cannot be trusted: the entry
#     says it carries SEVERAL findings -- the plural "ledger items"/"ledger
#     candidates", or an explicit count ("TWO KERNEL DEFECTS", "the four
#     outstanding findings") -- but has no usable enumeration; it enumerates
#     FEWER segments than the count it states; or its markers are scrambled,
#     gapped or repeated, so the ascending scan reports a clean prefix of a
#     list that is not one (see decompose). Where exactly one finding ends
#     and the next begins is then a guess, and a wrong guess silently
#     absolves the findings that fell on the wrong side of it. So the entry
#     is emitted as ONE item in mode `undecomposed`, which plancheck_report
#     never anchor-matches: no task text can close it, and only a named
#     deferral with a reason can.
#
#     All but the first are the half that matters most, and they say the same
#     thing: a SHORTER TIDY LIST IS WORSE THAN NO LIST. An entry stating four
#     findings and enumerating three would otherwise report three neat
#     `covered` lines and lose the fourth without ever naming it -- three
#     green verdicts standing in for the finding nobody read.
#
#   WHOLE. Anything else: one entry, one finding, `<run>#<n>`, matched on its
#     own text exactly as before. The motivating `started_at` item is this
#     shape ("recorded as a ledger candidate", singular), so the finding this
#     whole file was built for stays coverable by a task that names it.
plancheck_ledger_items() {
  local jf="$1" rid="$2"
  [ -f "$jf" ] || return 0
  awk -v rid="$rid" '
    # trunc(s) -- a report-safe one-line summary of s. An entry with no body
    # text at all is degenerate, not impossible, and must still report as
    # itself rather than as an empty field (see the IFS note above).
    function trunc(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
      if (s == "") s = "(entry has no body text)"
      if (length(s) > 120) s = substr(s, 1, 117) "..."
      gsub(/\t/, " ", s)
      return s
    }
    # numword(s) -- s as a small cardinal, or 0. Words as well as digits,
    # because arbitration prose writes "TWO KERNEL DEFECTS EXPOSED" far more
    # often than "2".
    function numword(s,   nums, i, n) {
      if (s ~ /^[0-9]+$/) return s + 0
      n = split("one two three four five six seven eight nine ten eleven twelve", nums, " ")
      for (i = 1; i <= n; i++) if (nums[i] == s) return i
      return 0
    }
    # statedcount(low) -- the largest number of findings the entry CLAIMS to
    # carry, or 0. A cardinal counts only when a findings noun follows it
    # within three words, so "four outstanding findings" counts and "two
    # independent reviewers" does not; and only 2..20, so a timestamp or a
    # line number cannot masquerade as a count. Read from the body alone --
    # the `## ` header is a timestamp and an actor, pure noise here.
    function statedcount(low,   n, w, i, j, c, best) {
      best = 0
      # String separator, not a /regex/ literal: the third argument to split
      # is an ERE either way, but only the string form is unambiguously
      # portable across the awks this repo runs under (BSD/BWK on macOS,
      # mawk and gawk on Linux CI).
      n = split(low, w, "[^a-z0-9]+")
      for (i = 1; i <= n; i++) {
        c = numword(w[i])
        if (c < 2 || c > 20) continue
        for (j = i + 1; j <= i + 3 && j <= n; j++) {
          if (w[j] == "findings" || w[j] == "defects" ||
              w[j] == "items" || w[j] == "candidates") {
            if (c > best) best = c
            break
          }
        }
      }
      return best
    }
    # markers(text, k) -- how many times the literal marker `(k) ` occurs
    # anywhere in text. `text` is a scalar parameter, so consuming it here is
    # a copy and the string belonging to the caller is untouched.
    function markers(text, k,   n, p, needle) {
      needle = "(" k ") "
      n = 0
      while ((p = index(text, needle)) > 0) {
        n++
        text = substr(text, p + length(needle))
      }
      return n
    }
    # decompose(text) -- how many `(k) ` markers text carries in ascending
    # order from 1, filling segstart[]; or -1 when the enumeration is
    # malformed. Each marker is searched for only AFTER its predecessor, so
    # "(2)" alone decomposes to nothing rather than to a mis-ordered split.
    # The trailing space is required so a bare "(1)" inside prose is not a
    # list marker.
    #
    # Then the split is CROSS-CHECKED against the whole text before it is
    # trusted, because the ascending scan alone reports a clean prefix for
    # three different malformed lists and each one buries a finding inside a
    # segment attributed to its neighbour:
    #
    #   SCRAMBLED   "(1) ... (3) ... (2) ..." -- the scan takes (1) then (2),
    #     which sits last, and never reaches (3).
    #   GAPPED      "(1) ... (2) ... (4) ..." -- the scan stops at (2)
    #     because no (3) follows, and the finding at (4) lands inside
    #     segment 2. An ordinal struck out of a hand-edited enumeration
    #     leaves exactly this shape, and checking only for the NEXT ordinal
    #     misses it.
    #   REPEATED    "(1) ... (2) ... (1) ..." -- a marker used twice means
    #     the position the scan assigned it is a choice between two, and the
    #     text after the other one is absorbed by whichever segment
    #     surrounds it.
    #
    # So each ordinal the scan consumed must appear EXACTLY ONCE, and no
    # higher ordinal may appear at all. A shorter tidy list is worse than no
    # list -- its survivors come back closeable with a green verdict line
    # while the finding that fell off is never named -- so any of the three
    # returns -1 and the entry is reported whole and unmatchable.
    #
    # nseg == 0 returns before those checks: there is no enumeration to
    # distrust, and a stray "(5) " in prose must not make an ordinary
    # single-finding entry unmatchable. That is the `started_at` shape, which
    # has to stay coverable by a task that names it.
    function decompose(text,   k, p, rest, needle) {
      nseg = 0; dpos = 1
      for (k = 1; k <= 99; k++) {
        needle = "(" k ") "
        rest = substr(text, dpos)
        p = index(rest, needle)
        if (p == 0) break
        segstart[k] = dpos + p - 1
        dpos = segstart[k] + length(needle)
        nseg = k
      }
      if (nseg == 0) return 0
      for (k = 1; k <= nseg; k++) if (markers(text, k) != 1) return -1
      for (k = nseg + 1; k <= 99; k++) if (markers(text, k) > 0) return -1
      return nseg
    }
    function segment(text, k) {
      if (k < nseg) return substr(text, segstart[k], segstart[k + 1] - segstart[k])
      return substr(text, segstart[k])
    }
    function emit(   kind, low, blow, ns, sc, i, seg, t) {
      if (hdr == "") return
      # Journal header shape: "## <ISO8601> <task|run> <kind> (<actor>)".
      split(hdr, ha, " ")
      kind = ha[4]
      low = tolower(hdr " " body)
      if (kind != "ledger" && kind != "plan_deferral" &&
          index(low, "ledger candidate") == 0 &&
          index(low, "ledger item") == 0) return
      blow = tolower(body)
      ns = decompose(body)
      sc = statedcount(blow)
      if (ns >= 2 && sc <= ns) {
        for (i = 1; i <= ns; i++) {
          seg = segment(body, i)
          t = seg; gsub(/\t/, " ", t)
          printf "%s#%d.%d\tledger\t%s\tanchor\t%s\n", rid, idx, i, trunc(seg), t
        }
        return
      }
      t = body; gsub(/\t/, " ", t)
      # `ns < 0` is a malformed enumeration, which is undecomposable on its
      # own evidence and needs no plural marker to say so. Otherwise the
      # marker has to be a PLURAL spelling: "ledger item" (singular) is the
      # ordinary way to record ONE carried finding and must stay
      # anchor-matchable, since the `started_at` miss that motivated this
      # whole file is written exactly that way.
      if (ns < 0 || sc >= 2 || index(blow, "ledger items") > 0 ||
          index(blow, "ledger candidates") > 0) {
        printf "%s#%d\tledger\t%s\tundecomposed\t%s\n", rid, idx, trunc(first), t
        return
      }
      printf "%s#%d\tledger\t%s\tanchor\t%s\n", rid, idx, trunc(first), t
    }
    BEGIN { idx = 0; hdr = ""; body = ""; first = "" }
    /^## / { emit(); idx++; hdr = $0; body = ""; first = ""; next }
    { body = body " " $0; if (first == "" && $0 ~ /[^ \t]/) first = $0 }
    END { emit() }
  ' "$jf"
}

# plancheck_lesson_items <lessons.md> <cutoff> -- the same five-field shape,
# one line per ACTIVE lesson block carried in from before <cutoff> (the
# current journal's first-entry date, i.e. this run's own start). Always mode
# `anchor`: a lesson block IS one lesson, so there is nothing to decompose.
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
    function emit(   s, t) {
      if (id == "" || lstate != "active") return
      if (cutoff != "" && firstd != "" && firstd > cutoff) return
      # Same empty-field rule as plancheck_ledger_items above, same reason.
      s = (stmt == "" ? "(lesson has no statement)" : stmt)
      if (length(s) > 120) s = substr(s, 1, 117) "..."
      gsub(/\t/, " ", s)
      # ...and the same tab rule for the TEXT field, which is built from the
      # raw statement rather than from the truncated summary. A tab there is
      # harmless only for as long as text stays the LAST field; squeezing it
      # here means the five-field contract holds on its own terms instead of
      # on that ordering. The id leads the text on purpose: a lesson id is
      # one of the four anchor shapes, so a task naming `L013` and nothing
      # else still covers it.
      t = id " " stmt; gsub(/\t/, " ", t)
      printf "%s\tlesson\t%s\tanchor\t%s\n", id, s, t
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
# `plan_deferral` journal entry.
#
# WHAT IS MATCHED IS THE ENTRY KIND, NOT THE LINE -- and that distinction is
# the gate. A deferral is the one thing that SATISFIES this cross-check, so
# whatever is read here is what the whole check rests on; matching raw text
# would make it forgeable by anyone who can write a journal entry at all.
# The brokered orchestrator surface (runners/orchid-orchestrator-command)
# refuses `--kind plan_deferral` for exactly that reason, but it admits
# `note` -- and `journal add --kind note "deferred r-001#57: handled"`
# produces a body line byte-identical to the real one. The broker's refusal
# only buys anything if this reader consults the field the broker actually
# guards, so the kind is parsed off the entry's `## ` header and a
# "deferred <id>: " line counts ONLY inside a `plan_deferral` entry. An
# operator's deferral satisfies the check; a forged note does not, and the
# item stays UNCOVERED.
#
# Ids are `L<nnn>` or `r-<n>#<n>` and carry no regex metacharacter, but the
# body match is a literal `index(...) == 1` prefix test anyway -- one less
# thing that has to stay true for the gate to hold. `kind` resets on every
# header line, so an entry's body can never inherit its predecessor's kind.
plancheck_deferral() {
  local jf="$1" id="$2" line
  [ -f "$jf" ] || return 1
  line="$(awk -v id="$id" '
    BEGIN { kind = ""; prefix = "deferred " id ": " }
    # Journal header shape: "## <ISO8601> <task|run> <kind> (<actor>)".
    /^## / { split($0, ha, " "); kind = ha[4]; next }
    kind == "plan_deferral" && index($0, prefix) == 1 {
      print substr($0, length(prefix) + 1); exit
    }
  ' "$jf")"
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
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
#
# MUST be called as a plain statement, never via `$(...)`/a pipeline. Like
# orchid_commit_durable (lib/common.sh) this function manages its own EXIT
# trap, COMPOSED with whatever the caller already armed rather than
# clobbering it -- `plan apply` reaches here holding the verb lock under
# `trap 'verb_lock_release ...' EXIT`, and a second competing trap would
# leak that lock on every refusal. A command substitution would fork a
# subshell, so the trap manipulation would apply only to the throwaway and
# the scratch directory would survive after all.
plancheck_report() {
  local state="$1"
  local prev cutoff tmp rc=0
  prev="$(plancheck_prev_run_id "$state")"
  if [ -z "$prev" ]; then
    echo "crosscheck: no previous run is archived under .orchid/runs/ — this is the first run of this repository, so nothing is carried forward"
    return 0
  fi

  cutoff="$(_lessons_journal_start_date "$state/journal.md")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/orchid-plancheck.XXXXXX")"

  # The scratch directory is removed on the way out of EVERY path, including
  # the ones this function does not choose: `plan apply` is a long
  # interactive step and an operator who interrupts it at the cross-check
  # used to leave an orchid-plancheck.* directory in TMPDIR forever, one per
  # interrupted attempt. The cleanup runs BEFORE the caller's own trap
  # command, and the caller's is restored verbatim on the normal return
  # below, so this composition is invisible to it either way.
  local tmp_q; printf -v tmp_q '%q' "$tmp"
  local prev_trap prev_cmd=""
  prev_trap="$(trap -p EXIT)"
  case "$prev_trap" in
    "trap -- "*)
      prev_cmd="${prev_trap#trap -- \'}"; prev_cmd="${prev_cmd%\' EXIT}" ;;
  esac
  if [ -n "$prev_cmd" ]; then
    # ShellCheck rationale: the quoted local path and the prior trap are intentionally captured before locals leave scope.
    # shellcheck disable=SC2064
    trap "_plancheck_cleanup $tmp_q; $prev_cmd" EXIT
  else
    # ShellCheck rationale: the quoted local path must be captured before locals leave scope.
    # shellcheck disable=SC2064
    trap "_plancheck_cleanup $tmp_q" EXIT
  fi

  # The report proper runs in a helper purely so this arming/disarming pair
  # is written once: the body has three exit points, and a cleanup repeated
  # at each is a cleanup that will be forgotten at the fourth.
  _plancheck_body "$state" "$prev" "$cutoff" "$tmp" || rc=$?

  _plancheck_cleanup "$tmp"
  if [ -n "$prev_cmd" ]; then
    # ShellCheck rationale: this restores the exact previously captured EXIT command.
    # shellcheck disable=SC2064
    trap "$prev_cmd" EXIT
  else
    trap - EXIT
  fi
  return "$rc"
}

# _plancheck_cleanup <dir> -- removes the report's scratch directory. A
# standalone function, not a closure, taking the path as an explicit STRING
# ARGUMENT baked into the trap command at registration time: a `local` inside
# plancheck_report is already out of scope by the time a later EXIT trap
# fires. Same shape, and same reason, as lib/common.sh's _ocd_cleanup_wt.
_plancheck_cleanup() {
  if [ -n "${1:-}" ]; then
    rm -rf "$1"
  fi
  return 0
}

# _plancheck_body <state> <prev> <cutoff> <tmp> -- plancheck_report's report,
# with the scratch directory supplied and its removal already guaranteed by
# the caller. Same exit codes.
_plancheck_body() {
  local state="$1" prev="$2" cutoff="$3" tmp="$4"
  local f id kind summary mode text hits hitfile hit via reason nitems nopen=0
  {
    plancheck_ledger_items "$state/runs/$prev/journal.md" "$prev"
    plancheck_lesson_items "$state/lessons.md" "$cutoff"
  } > "$tmp/items"

  nitems="$(wc -l < "$tmp/items" | tr -d ' ')"
  if [ "$nitems" -eq 0 ]; then
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
  while IFS=$'\t' read -r id kind summary mode text; do
    [ -n "$id" ] || continue
    hit=""; via=""
    # An UNDECOMPOSED entry is skipped here entirely rather than matched and
    # then overruled. It records several findings that could not be split
    # apart, so its text is the union of all of them and ANY anchor in it
    # would close the lot -- the precise per-entry absolution this
    # decomposition exists to end. There is no task text that can answer for
    # it; only a named deferral can.
    if [ "$mode" = anchor ]; then
      printf '%s\n' "$text" | plancheck_anchors > "$tmp/anchors"
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
    if [ "$mode" != anchor ]; then
      printf '            ^ this entry records SEVERAL findings and cannot be split into them unambiguously, so no task text can close it: schedule them, then defer this entry naming what you scheduled\n'
    fi
    nopen=$((nopen + 1))
    printf '%s\t%s\t%s\n' "$id" "$mode" "$summary" >> "$tmp/open"
  done < "$tmp/items"

  if [ "$nopen" -eq 0 ]; then
    echo "crosscheck: all $nitems carried-forward item(s) considered"
    return 0
  fi

  echo "crosscheck: $nopen of $nitems carried-forward item(s) from $prev are neither covered by a task in this plan nor explicitly deferred:" >&2
  while IFS=$'\t' read -r id mode summary; do
    [ -n "$id" ] || continue
    printf '  %s — %s\n' "$id" "$summary" >&2
    if [ "$mode" = anchor ]; then
      printf '      cover it with a task in this plan, or record the decision: orchid plan defer %s --reason "..."\n' "$id" >&2
    else
      printf '      several findings in one entry, not separable — only an explicit decision closes it: orchid plan defer %s --reason "..."\n' "$id" >&2
    fi
  done < "$tmp/open"
  return 3
}
