#!/usr/bin/env bash
# Input packs: kernel-materialized per-job memory. See docs/specs/plugins.md.

# v1-m3 Task 11: sourced relative to THIS file's own directory, not
# "$ORCHID_ROOT/lib/..." -- several test files source lib/pack.sh directly
# with no ORCHID_ROOT set at all (tests/test_pack.sh, tests/test_hooks.sh,
# tests/inv/test_INV-12_pack_overflow.sh, tests/test_review_routing.sh), so
# resolving relative to $BASH_SOURCE keeps every existing caller working
# unchanged. This is the one deliberate exception to the rest of lib/*.sh's
# convention of never sourcing a sibling lib file (the caller sources
# everything, in a fixed order) -- lib/lessons.sh has no further
# dependencies of its own, so there is no cycle risk.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lessons.sh"
# Same deliberate exception, same reason (T025): several test files source
# lib/pack.sh directly with no ORCHID_ROOT set, and lib/rework.sh has no
# dependencies of its own beyond lib/common.sh (which every caller of this
# file already sources for atomic_write/config_get), so there is no cycle.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rework.sh"

# _pack_fm_field <task-file> <key> -- a single frontmatter value, same
# one-key extraction the review/critique branch below inlines twice already
# (base_sha, candidate_sha); factored out here so the hook branch (needing
# base_sha, candidate_sha, AND attempts) doesn't triple that duplication a
# third time.
_pack_fm_field() {
  awk -v k="$2" '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$1"
}

# _pack_rework_brief <state> <task> [section] -- the rework brief, on stdout,
# or nothing at all when this task has no captured failure to feed back (its
# first attempt, or a rework nobody had evidence for).
#
# This is the OTHER half of the F27 fix. Capturing the failing output before
# the kernel invalidates it (lib/rework.sh) only makes it survivable; a pack
# that never carries it still hands the next attempt the same brief as the
# last one, which is how three attempts came back byte-identical. The brief
# leads with the CONVERGENCE fact, because that is the part a re-reading
# implementer cannot derive for itself: whether the previous round's change
# moved this failure at all.
#
# Verbatim output, never a summary: the whole finding is that a summarized
# "verify failed" is what the loop already had.
#
# `section` splits that into the three parts the BUDGET has to treat
# differently, and each split exists for one concrete failure:
#
#   head -- the round number, the signature, and whether it has repeated
#           unchanged, down to and including the heading that labels the log.
#           Small, bounded, and the single most valuable thing in the pack:
#           an implementer that loses it is back to re-reading raw output
#           with no idea it has already seen it, which IS finding F27. Split
#           out because rework.md trims TAIL-kept and this sits at the TOP.
#   body -- the captured log itself. Unbounded (a suite's whole output), and
#           the only part it is ever correct to CUT.
#   diff -- the comparison against the round before it. Unbounded too, and
#           the first part it is correct to DROP ENTIRELY.
#
# BODY AND DIFF ARE NOT ONE SECTION, and the reason is the whole trim rule
# read backwards. Tail-keeping a body of "the failing run, then the diff
# against the previous one" keeps the DIFF and eats the RUN: the pack would
# ship a comparison of two runs with neither run in it, under a heading
# promising the verbatim output of the one that failed. That is worse than
# omitting the comparison, because a diff is only meaningful against a
# baseline the reader can see -- so the failing run is kept whole first, and
# the comparison is dropped, whole, whenever it does not fit after it.
#
# Default `all` keeps the whole brief on stdout for any caller that has no
# budget to spend -- the three sections concatenate to exactly it.
#
# NOTHING AT ALL when the newest captured round does not bind to the task's
# CURRENT candidate (rework_evidence_current). The brief's own sentences are
# what make that mandatory: "you already tried this and got exactly this" is a
# claim about the code the recipient is holding, and against a superseded
# candidate it is simply false -- a confident, specific lie in place of the
# silence this feature was written to end. The candidate moves under this
# evidence in ordinary operation (the reworking implementer commits, `orchid
# merge`'s rebase arm mints a new sha, an operator re-derives the branch), so
# this is a routine state, not a corner.
_pack_rework_brief() {
  local state="$1" task="$2"
  local section="${3:-all}"
  # Separate declaration on purpose: within ONE `local`, the earlier
  # assignments have not taken effect yet, so `tf` would be built from the
  # OUTER scope's $state/$task (ShellCheck SC2318).
  local tf="$state/tasks/$task.md"
  local latest prev rounds sig reps
  latest="$(rework_latest_log "$state" "$task" 0)" || return 0
  # An EMPTY captured round is not evidence, and the brief's own framing is
  # what makes that dangerous: "the verbatim output of the run that FAILED is
  # reproduced below" over zero bytes asserts that the failing run printed
  # nothing, which is a claim about the failure rather than an absence of one.
  # No brief at all is the honest reading, and it is what the pre-T025 loop
  # already had -- so this degrades, never misleads. (`orchid verify` always
  # writes at least a header and an `exit:` line, so this is a torn/truncated
  # file, not an ordinary one.)
  [ -s "$latest" ] || return 0
  # The binding, checked HERE as well as at pack_build's call site: this
  # function is the one that writes the sentences, so it is the one that has
  # to be unable to write them about the wrong candidate. Callers get the
  # empty output that says "no previous failure applies to this candidate".
  rework_evidence_current "$state" "$task" "$(_pack_fm_field "$tf" candidate_sha)" || return 0
  prev="$(rework_latest_log "$state" "$task" 1 2>/dev/null || true)"
  rounds="$(_pack_fm_field "$tf" rework_rounds)"
  sig="$(_pack_fm_field "$tf" rework_signature)"
  reps="$(_pack_fm_field "$tf" rework_signature_repeats)"
  case "$reps" in ''|*[!0-9]*) reps=1 ;; esac

  if [ "$section" = all ] || [ "$section" = head ]; then
    echo "# Previous attempt (rework round ${rounds:-1}) — what it actually failed on"
    echo
    echo "You are reworking this task. The verbatim output of the run that FAILED"
    echo "is reproduced below. It is not a summary and not a pointer: it is the"
    echo "evidence itself, captured before the kernel invalidated it."
    echo
    echo "- failure signature: ${sig:-unknown}"
    if [ "$reps" -ge 2 ]; then
      echo "- **this signature has now repeated $reps times in a row, unchanged.**"
      echo
      echo "READ THAT AGAIN: the previous round's changes did not move this failure"
      echo "by a single byte. You already tried a fix and got exactly this. Whatever"
      echo "the last attempt did was either not the cause, or never reached the code"
      echo "under test. Do not re-apply it in another form. Establish what is"
      echo "actually being asserted, and what the failing value actually is, before"
      echo "changing anything — including the possibility that the ASSERTION is the"
      echo "defect and the production code is right."
    else
      echo "- this is the first time this particular failure has been seen."
    fi
    echo
    echo '## The failing run, verbatim'
    echo
  fi
  if [ "$section" = all ] || [ "$section" = body ]; then
    cat "$latest"
  fi
  if [ "$section" = all ] || [ "$section" = diff ]; then
    if [ -n "$prev" ]; then
      echo
      if [ "$reps" -ge 2 ]; then
        echo "## Versus the round before it"
        echo
        echo "Byte-identical after the volatile header (timestamp, shas, working"
        echo "directory). There is no diff to show."
      else
        echo '## What changed since the round before it'
        echo
        # Header lines included on purpose. They are volatile by design (the
        # signature strips them precisely so a re-run does not read as a new
        # failure), but this diff is read by a HUMAN-facing implementer, and a
        # hunk showing only `date:`/`sha:` moving is itself the answer to "did
        # anything change" -- silently hiding it would leave an empty diff
        # under a heading promising one.
        diff -u "$prev" "$latest" || true
      fi
    fi
  fi
  # Explicit, because the caller reads this status as "the brief could not be
  # built" and clears ALL THREE parts on it. Every arm above is an `if` whose
  # false condition yields 0, so this is what it already returns -- but a
  # single round (no `prev`) asking for the `diff` section leaves that
  # unstated-by-accident, and the day it stops being true the pack loses the
  # brief it did build, on the commonest shape there is.
  return 0
}

# _pack_build_plan <repo> <state> <dest> -- the plan-scoped pack (v1-m3):
# built for the reserved task id `plan` (role.plan_critic critiquing a draft
# roadmap, never a real task's diff). Non-truncatable inputs are
# requirements.md + the draft roadmap.md (mirrors task packs' task.md: the
# critic cannot judge a plan it can't fully see); every current tasks/*.md is
# concatenated into one truncatable tasks.md (tail-first trim -- `head -c`
# keeps the earliest-drafted tasks and drops the rest, same convention as
# journal.md's tail-first trim per docs/specs/plugins.md); lessons.md rides
# along, budget-permitting, when present. No task.md/diff.patch -- there is
# no single task and nothing has been committed yet.
_pack_build_plan() {
  local repo="$1" state="$2" dest="$3"
  local budget used=0 items="" omitted="" req="$state/requirements.md" roadmap="$state/roadmap.md"
  budget="$(config_get "$repo" pack_budget_bytes 65536)"
  [ -f "$req" ] || { echo "orchid: no requirements.md — run orchid requirements import first" >&2; return 1; }
  [ -f "$roadmap" ] || { echo "orchid: no roadmap.md — run orchid init first" >&2; return 1; }
  mkdir -p "$dest"

  cp "$req" "$dest/requirements.md"
  used=$(( used + $(wc -c < "$dest/requirements.md") ))
  items="{\"name\":\"requirements.md\",\"bytes\":$(wc -c < "$dest/requirements.md"),\"truncated\":false}"

  cp "$roadmap" "$dest/roadmap.md"
  used=$(( used + $(wc -c < "$dest/roadmap.md") ))
  items="$items,{\"name\":\"roadmap.md\",\"bytes\":$(wc -c < "$dest/roadmap.md"),\"truncated\":false}"

  if [ "$used" -gt "$budget" ]; then
    rm -rf "$dest"
    echo "orchid: input_overflow — non-truncatable inputs ($used bytes) exceed pack budget ($budget)" >&2
    return 12
  fi

  local tasks_tmp room tbytes ttrunc=false
  tasks_tmp="$(mktemp)"
  for tfile in "$state/tasks"/*.md; do
    [ -e "$tfile" ] || continue
    cat "$tfile" >> "$tasks_tmp"; printf '\n' >> "$tasks_tmp"
  done
  if [ -s "$tasks_tmp" ]; then
    room=$(( budget - used ))
    if [ "$room" -le 0 ]; then
      omitted="${omitted:+$omitted,}\"tasks.md\""
    else
      tbytes="$(wc -c < "$tasks_tmp")"
      if [ "$tbytes" -le "$room" ]; then
        cp "$tasks_tmp" "$dest/tasks.md"
      else
        head -c "$room" "$tasks_tmp" > "$dest/tasks.md"; ttrunc=true
      fi
      used=$(( used + $(wc -c < "$dest/tasks.md") ))
      items="$items,{\"name\":\"tasks.md\",\"bytes\":$(wc -c < "$dest/tasks.md"),\"truncated\":$ttrunc}"
    fi
  else
    omitted="${omitted:+$omitted,}\"tasks.md\""
  fi
  rm -f "$tasks_tmp"

  # v1-m3 Task 11: ACTIVE lessons only (kernel.md's per-role injection table
  # -- plan_critic receives "lessons.md", never the raw file, which may also
  # carry superseded/retired blocks that are historical record, not live
  # judgment input). lessons_active_only (lib/lessons.sh) extracts exactly
  # the "## L... [active] ..." blocks, verbatim, file order -- it also
  # strips the raw file's leading "# Lessons" heading (that line is not
  # itself a "## " block), so this pack's lessons.md never carries it; no
  # consumer needs it back.
  local lessons_active_tmp
  lessons_active_tmp="$(mktemp)"
  lessons_active_only "$state/lessons.md" > "$lessons_active_tmp"
  if [ -s "$lessons_active_tmp" ]; then
    local room2 lbytes ltrunc=false
    room2=$(( budget - used ))
    if [ "$room2" -le 0 ]; then
      omitted="${omitted:+$omitted,}\"lessons.md\""
    else
      lbytes="$(wc -c < "$lessons_active_tmp")"
      if [ "$lbytes" -le "$room2" ]; then
        cp "$lessons_active_tmp" "$dest/lessons.md"
      else
        head -c "$room2" "$lessons_active_tmp" > "$dest/lessons.md"; ltrunc=true
      fi
      used=$(( used + $(wc -c < "$dest/lessons.md") ))
      items="$items,{\"name\":\"lessons.md\",\"bytes\":$(wc -c < "$dest/lessons.md"),\"truncated\":$ltrunc}"
    fi
  else
    omitted="${omitted:+$omitted,}\"lessons.md\""
  fi
  rm -f "$lessons_active_tmp"

  printf '{"budget":%s,"total_bytes":%s,"items":[%s],"omitted":[%s]}\n' \
    "$budget" "$used" "$items" "$omitted" | jq . > "$dest/pack.json"
}

# _pack_build_hook <repo> <state> <task> <dest> <point> -- the hook-op pack
# (v1-m3): every hook operation is launched against a real, already-existing
# task (unlike the plan-scoped pack above), so task.md is always the
# non-truncatable base, exactly like the review/critique pack. Exactly one
# point-specific artifact rides alongside it: `on_verify_fail`'s verify log,
# `before_merge`'s diff, and `on_blocker`'s BLOCKERS.md are non-truncatable
# (added to `used` BEFORE the budget check below, same as diff.patch in the
# review/critique branch above -- a hook handler judging a verify failure or
# a merge diff must never be handed a partial one); `before_arbitration`'s
# concatenated reviews.json and `after_plan_draft`'s roadmap.md are
# truncatable tail-first (`head -c`, the same convention tasks.md/context.md
# already use elsewhere in this file), per the v1-m3 plan's pack rule.
_pack_build_hook() {
  local repo="$1" state="$2" task="$3" dest="$4" point="$5"
  local budget used=0 items="" omitted="" tf="$state/tasks/$task.md"
  budget="$(config_get "$repo" pack_budget_bytes 65536)"
  [ -f "$tf" ] || { echo "orchid: no task $task" >&2; return 1; }
  mkdir -p "$dest"

  cp "$tf" "$dest/task.md"
  used=$(( used + $(wc -c < "$dest/task.md") ))
  items="{\"name\":\"task.md\",\"bytes\":$(wc -c < "$dest/task.md"),\"truncated\":false}"

  case "$point" in
    on_verify_fail)
      local vlog="$state/reviews/$task-verify.log"
      [ -f "$vlog" ] || { rm -rf "$dest"; echo "orchid: no verify log for task $task -- run orchid verify first" >&2; return 1; }
      cp "$vlog" "$dest/verify.log"
      used=$(( used + $(wc -c < "$dest/verify.log") ))
      items="$items,{\"name\":\"verify.log\",\"bytes\":$(wc -c < "$dest/verify.log"),\"truncated\":false}"
      ;;
    before_merge)
      local b c
      b="$(_pack_fm_field "$tf" base_sha)"; c="$(_pack_fm_field "$tf" candidate_sha)"
      git -C "$repo" diff "$b".."$c" > "$dest/diff.patch"
      used=$(( used + $(wc -c < "$dest/diff.patch") ))
      items="$items,{\"name\":\"diff.patch\",\"bytes\":$(wc -c < "$dest/diff.patch"),\"truncated\":false}"
      ;;
    on_blocker)
      if [ -f "$state/BLOCKERS.md" ]; then
        cp "$state/BLOCKERS.md" "$dest/BLOCKERS.md"
        used=$(( used + $(wc -c < "$dest/BLOCKERS.md") ))
        items="$items,{\"name\":\"BLOCKERS.md\",\"bytes\":$(wc -c < "$dest/BLOCKERS.md"),\"truncated\":false}"
      else
        omitted="\"BLOCKERS.md\""
      fi
      ;;
    before_arbitration|after_plan_draft) ;;   # truncatable -- handled below, after the budget check
    *) rm -rf "$dest"; echo "orchid: unknown hook point '$point'" >&2; return 1 ;;
  esac

  if [ "$used" -gt "$budget" ]; then
    rm -rf "$dest"
    echo "orchid: input_overflow — non-truncatable inputs ($used bytes) exceed pack budget ($budget)" >&2
    return 12
  fi

  case "$point" in
    before_arbitration)
      # Filtered on the envelope's OWN `.operation` (review|critique), not a
      # blind `$task-a$attempt-*.json` glob: that directory also holds this
      # very attempt's implementer envelope and any hook-* envelopes already
      # filed at other points (e.g. before_merge) -- neither belongs in the
      # review evidence arbitration is about to weigh.
      local attempt revtmp room rbytes rtrunc=false any=0 rf rf_op
      attempt=$(( $(_pack_fm_field "$tf" attempts) + 1 ))
      revtmp="$(mktemp)"
      local -a rev_files=()
      for rf in "$state/reviews/$task-a$attempt-"*.json; do
        [ -e "$rf" ] || continue
        rf_op="$(jq -r '.operation // empty' "$rf" 2>/dev/null)"
        case "$rf_op" in
          review|critique) rev_files+=("$rf"); any=1 ;;
        esac
      done
      [ "$any" -eq 1 ] && jq -s '.' "${rev_files[@]}" > "$revtmp" 2>/dev/null
      if [ -s "$revtmp" ]; then
        room=$(( budget - used ))
        if [ "$room" -le 0 ]; then
          omitted="${omitted:+$omitted,}\"reviews.json\""
        else
          rbytes="$(wc -c < "$revtmp")"
          if [ "$rbytes" -le "$room" ]; then
            cp "$revtmp" "$dest/reviews.json"
          else
            head -c "$room" "$revtmp" > "$dest/reviews.json"; rtrunc=true
          fi
          used=$(( used + $(wc -c < "$dest/reviews.json") ))
          items="$items,{\"name\":\"reviews.json\",\"bytes\":$(wc -c < "$dest/reviews.json"),\"truncated\":$rtrunc}"
        fi
      else
        omitted="${omitted:+$omitted,}\"reviews.json\""
      fi
      rm -f "$revtmp"
      ;;
    after_plan_draft)
      local roadmap="$state/roadmap.md" room2 rmbytes rmtrunc=false
      if [ -f "$roadmap" ]; then
        room2=$(( budget - used ))
        if [ "$room2" -le 0 ]; then
          omitted="${omitted:+$omitted,}\"roadmap.md\""
        else
          rmbytes="$(wc -c < "$roadmap")"
          if [ "$rmbytes" -le "$room2" ]; then
            cp "$roadmap" "$dest/roadmap.md"
          else
            head -c "$room2" "$roadmap" > "$dest/roadmap.md"; rmtrunc=true
          fi
          used=$(( used + $(wc -c < "$dest/roadmap.md") ))
          items="$items,{\"name\":\"roadmap.md\",\"bytes\":$(wc -c < "$dest/roadmap.md"),\"truncated\":$rmtrunc}"
        fi
      else
        omitted="${omitted:+$omitted,}\"roadmap.md\""
      fi
      ;;
  esac

  printf '{"budget":%s,"total_bytes":%s,"items":[%s],"omitted":[%s]}\n' \
    "$budget" "$used" "$items" "$omitted" | jq . > "$dest/pack.json"
}

pack_build() {  # repo task op dest [hook-point|workspace_read=1] ; exit 12 = input_overflow
  # The 5th positional arg is overloaded exactly like the hook branch's own
  # `point` already is: `op=hook` reads it as the hook point (_pack_build_
  # hook below); `op=review|critique` instead reads it as the caller's
  # (runners/orchid-launch's) capability FACT for the RESOLVED engine --
  # the literal string "workspace_read=1" when that engine's manifest
  # declares workspace_read, empty/absent otherwise. The two meanings never
  # collide (hook and review/critique are different `op` values), so one
  # slot serves both, same as m3's hook-point precedent. pack.sh stays
  # resolver-dumb on purpose: it is handed a already-resolved FACT, never a
  # plugin dir or engine name to go look up itself (v1-m4 Task 3).
  local repo="$1" task="$2" op="$3" dest="$4" point="${5:-}"
  local state tf budget used=0 items="" omitted="" symbols_tmp=""
  state="$(orchid_state "$repo")"
  # `plan` (v1-m3): reserved task id, no task file exists at all (`orchid
  # task create` refuses it) -- routed to the plan-scoped pack builder
  # instead of the per-task path below. Checked BEFORE the `hook` op check
  # just below: a plan-scoped hook job (task=plan, op=hook) therefore still
  # receives the PLAN pack here, by design, never the per-point hook pack --
  # there is no task.md for _pack_build_hook to read in the first place.
  if [ "$task" = plan ]; then
    _pack_build_plan "$repo" "$state" "$dest"
    return $?
  fi
  # `hook` op (v1-m3): task.md + exactly one point-specific artifact --
  # routed to its own builder instead of the review/critique/implement path
  # below (see _pack_build_hook's header comment for the per-point rules).
  if [ "$op" = hook ]; then
    _pack_build_hook "$repo" "$state" "$task" "$dest" "$point"
    return $?
  fi
  tf="$state/tasks/$task.md"
  [ -f "$tf" ] || { echo "orchid: no task $task" >&2; return 1; }
  budget="$(config_get "$repo" pack_budget_bytes 65536)"
  mkdir -p "$dest"

  cp "$tf" "$dest/task.md"
  used=$(( used + $(wc -c < "$dest/task.md") ))
  items="{\"name\":\"task.md\",\"bytes\":$(wc -c < "$dest/task.md"),\"truncated\":false}"

  if [ "$op" = review ] || [ "$op" = critique ]; then
    local b c diff_tmp diff_bytes inline_max
    b="$(awk -v k=base_sha '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$tf")"
    c="$(awk -v k=candidate_sha '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$tf")"

    # v1-m4 Task 3 (promotes the r-001 live-run prototype): a worktree-
    # capable reviewer can navigate the checkout directly, so a diff.patch
    # over `pack_diff_inline_max_bytes` need not be inlined at all -- a
    # multi-MB extraction diff used to blow the budget outright for exactly
    # this reviewer shape. Computed into a tmp file first (never twice) so
    # the size check never re-runs the (potentially large) `git diff` a
    # second time.
    diff_tmp="$(mktemp)"
    git -C "$repo" diff "$b".."$c" > "$diff_tmp"
    diff_bytes="$(wc -c < "$diff_tmp")"
    inline_max="$(config_get "$repo" pack_diff_inline_max_bytes 262144)"

    if [ "$point" = "workspace_read=1" ] && [ "$diff_bytes" -gt "$inline_max" ]; then
      rm -f "$diff_tmp"
      # diff.stat: stat summary + name-status, enough for a worktree-capable
      # engine to navigate straight to the changed files itself -- honest
      # about the trade (docs/specs/plugins.md: "review independence never
      # rests on secrecy"), not a truncation of diff.patch (which would
      # silently lose hunks INV-12 exists to protect against).
      git -C "$repo" diff --stat "$b".."$c" > "$dest/diff.stat"
      printf '\n' >> "$dest/diff.stat"
      git -C "$repo" diff --name-status "$b".."$c" >> "$dest/diff.stat"
      used=$(( used + $(wc -c < "$dest/diff.stat") ))
      items="$items,{\"name\":\"diff.stat\",\"bytes\":$(wc -c < "$dest/diff.stat"),\"truncated\":false}"
      # Recorded as its OWN items[] entry (not the plain-string `omitted`
      # list used elsewhere in this file for budget-omitted artifacts) --
      # this omission is capability-shaped, not budget-shaped, and pack.json
      # readers deserve the reason, not just the name. jq's `add` treats a
      # missing "bytes" key as null, which behaves as the identity element
      # for +, so the total_bytes-sums-items invariant still holds with this
      # entry present.
      items="$items,{\"name\":\"diff.patch\",\"omitted\":\"worktree-read\"}"
    else
      mv "$diff_tmp" "$dest/diff.patch"
      used=$(( used + $(wc -c < "$dest/diff.patch") ))
      items="$items,{\"name\":\"diff.patch\",\"bytes\":$(wc -c < "$dest/diff.patch"),\"truncated\":false}"
    fi

    # symbols.txt: the inline blind-spot guard's data (changed-file list +
    # every hunk header) -- the changed-symbol list PROTOCOL's routing-
    # upgrade judgment (Task 10) reads to decide whether to upgrade to a
    # worktree-capable reviewer. Built now but only written into the pack
    # (further down) AFTER context.md has taken its share of the budget: it
    # is truncatable, and trimmed strictly after the higher-priority repo
    # context, never before it. Still built even when diff.patch itself was
    # swapped for diff.stat above -- a worktree-capable engine still
    # benefits from the same blind-spot guard data as everyone else.
    symbols_tmp="$(mktemp)"
    git -C "$repo" diff --unified=0 "$b".."$c" 2>/dev/null | grep -E '^(\+\+\+|@@)' > "$symbols_tmp" || true
  fi

  if [ "$used" -gt "$budget" ]; then
    rm -rf "$dest"; [ -z "$symbols_tmp" ] || rm -f "$symbols_tmp"
    echo "orchid: input_overflow — non-truncatable inputs ($used bytes) exceed pack budget ($budget)" >&2
    return 12
  fi

  # T025: rework.md -- the previous attempt's failure, fed back into the
  # attempt that has to fix it. Budgeted FIRST among the truncatables (ahead
  # of lessons.md and context.md): on a rework attempt this is the single
  # most specific input in the pack, and it is the one input whose absence
  # produced the identical-failure loop this feature exists to end.
  # Truncated TAIL-KEPT (`tail -c`), the opposite of tasks.md/lessons.md's
  # head-first trim and for a concrete reason: a suite's output ends with the
  # failing assertions and the exit line, so keeping the head of a long log
  # keeps the part that passed.
  #
  # But tail-kept applies to the LOG, not to the brief that frames it and not
  # to the comparison under it. Three parts, three different budget rules
  # (_pack_rework_brief's `section` argument):
  #
  #   * the PREAMBLE -- the round number, the signature, and "this signature
  #     has now repeated N times in a row, unchanged" -- sits at the top, so a
  #     whole-file tail trim would drop precisely the sentence this feature
  #     exists to deliver and hand the engine an unlabelled fragment of
  #     somebody's test output. That is not a degraded brief; it is the
  #     pre-T025 brief with extra noise, i.e. finding F27 again, reached
  #     through the budget instead of through the dangling pointer. Kept
  #     WHOLE, always.
  #   * the FAILING RUN is what everything else is about, and it is the only
  #     part that is ever cut -- tail-kept, so a trim keeps the assertions and
  #     the exit line.
  #   * the COMPARISON against the previous round is dropped ENTIRELY, and
  #     first, whenever it does not fit after the run. It is the one part that
  #     is worthless without the other: shipping a diff of two runs while
  #     trimming away the run itself leaves the engine holding a description
  #     of a change to output it cannot see.
  #
  # AND IT IS NEVER OMITTED SILENTLY WHEN IT IS REQUIRED. If a captured round
  # binds to this candidate, the failure IS the specific input this attempt was
  # dispatched to act on: sending an implementer without it, or with a token
  # fragment of it, is the identical-answer loop with extra steps. So a budget
  # that cannot carry the preamble plus a meaningful tail of the failing run
  # fails the pack (exit 12, input_overflow, the same class the launcher
  # already refuses to spawn on) rather than quietly shipping a pack that will
  # produce the same failure again. The operator gets a named budget problem
  # they can fix; the alternative is a run that looks healthy and converges on
  # nothing.
  #
  # `implement` only. A reviewer judges base_sha..candidate_sha as it stands,
  # against the task spec -- handing it the previous attempt's failure would
  # prejudge a candidate that no longer has that defect (or invite it to
  # review a diff it cannot see), and no shipped review prompt asks for it.
  if [ "$op" = implement ]; then
    local rework_head rework_body rework_diff
    local rwcand rwlatest rwclaim rwstate=absent
    local rwroom rwhbytes rwbbytes rwdbytes rwbodyroom rwfloor rwtrunc=false
    rwcand="$(_pack_fm_field "$tf" candidate_sha)"
    rwlatest="$(rework_latest_log "$state" "$task" 0 2>/dev/null || true)"
    # Four states, and the three non-`current` ones are deliberately told
    # apart. "No round was ever captured" is not an omission at all (a first
    # attempt), while evidence that exists and was WITHHELD is one -- and the
    # reason is what tells an operator whether the loop is healthy (the
    # candidate moved on, as it does every successful rework) or whether
    # something upstream stopped writing bindable logs.
    if [ -n "$rwlatest" ] && [ -s "$rwlatest" ]; then
      rwclaim="$(findings_log_candidate "$rwlatest")"
      if rework_evidence_current "$state" "$task" "$rwcand"; then
        rwstate=current
      elif [ -z "$rwcand" ] || [ "$rwcand" = none ]; then
        rwstate=no-candidate
      elif [ -z "$rwclaim" ]; then
        rwstate=unbindable
      else
        rwstate=superseded-candidate
      fi
    fi
    if [ "$rwstate" = current ]; then
      rework_head="$(mktemp)"; rework_body="$(mktemp)"; rework_diff="$(mktemp)"
      # Failure here is contained, for two independent reasons. (1) pack_build
      # runs inside runners/orchid-launch under `set -e`, so an unguarded
      # non-zero from this call would abort the LAUNCH -- taking a whole
      # dispatch down over an input that is optional by construction (a first
      # attempt has none at all). (2) A brief that died partway through is not
      # shipped half-written: "## The failing run, verbatim" with nothing under
      # it reads as "the run produced no output", which is a worse lie than no
      # brief. Degrading to no rework.md, recorded as such below, is never a
      # wrong answer -- and it is NOT routed into the refusal above, because a
      # brief that could not be built is a different fact from a budget that
      # could not carry one, and only the second is something an operator can
      # act on.
      # ALL THREE parts are cleared when ANY fails: a body with no preamble is
      # the unlabelled fragment described above, a preamble with no body claims
      # an output that is not there, and a comparison with neither is a diff
      # against nothing.
      if ! _pack_rework_brief "$state" "$task" head > "$rework_head" 2>/dev/null \
         || ! _pack_rework_brief "$state" "$task" body > "$rework_body" 2>/dev/null \
         || ! _pack_rework_brief "$state" "$task" diff > "$rework_diff" 2>/dev/null; then
        : > "$rework_head"; : > "$rework_body"; : > "$rework_diff"
      fi
      if [ ! -s "$rework_head" ] || [ ! -s "$rework_body" ]; then
        rwstate=unreadable
      else
        rwroom=$(( budget - used ))
        rwhbytes="$(wc -c < "$rework_head")"
        rwbbytes="$(wc -c < "$rework_body")"
        # The floor: what "carries the failure" has to mean in bytes before
        # the pack may claim it did. 512 is a few assertion lines and the
        # `exit:` line -- the tail of a failing suite, which is the part a
        # reader needs. A whole body shorter than that is not a shortfall, so
        # the floor never asks for more of a log than the log has.
        rwfloor=512
        if [ "$rwbbytes" -lt "$rwfloor" ]; then rwfloor="$rwbbytes"; fi
        if [ "$rwroom" -lt $(( rwhbytes + rwfloor )) ]; then
          rm -f "$rework_head" "$rework_body" "$rework_diff"
          rm -rf "$dest"; [ -z "$symbols_tmp" ] || rm -f "$symbols_tmp"
          echo "orchid: input_overflow — $task is reworking a captured failure, but the pack budget ($budget) leaves $rwroom bytes for rework.md and its brief needs at least $(( rwhbytes + rwfloor )); dispatching an implementer without the failure it was sent to fix reproduces it (raise pack_budget_bytes)" >&2
          return 12
        fi
        cat "$rework_head" > "$dest/rework.md"
        rwbodyroom=$(( rwroom - rwhbytes ))
        if [ "$rwbbytes" -le "$rwbodyroom" ]; then
          cat "$rework_body" >> "$dest/rework.md"
        else
          tail -c "$rwbodyroom" "$rework_body" >> "$dest/rework.md"
          rwtrunc=true
        fi
        # The comparison, last and optional. Only once the failing run landed
        # WHOLE (a truncated run has already taken every remaining byte), and
        # only if the whole comparison fits: half a diff is not a smaller
        # comparison, it is a misleading one. Dropping it marks the item
        # truncated, because that is what the flag means -- the engine did not
        # receive all of this input.
        if [ -s "$rework_diff" ]; then
          rwdbytes="$(wc -c < "$rework_diff")"
          if [ "$rwtrunc" = false ] && [ "$rwdbytes" -le $(( rwbodyroom - rwbbytes )) ]; then
            cat "$rework_diff" >> "$dest/rework.md"
          else
            rwtrunc=true
          fi
        fi
        used=$(( used + $(wc -c < "$dest/rework.md") ))
        items="$items,{\"name\":\"rework.md\",\"bytes\":$(wc -c < "$dest/rework.md"),\"truncated\":$rwtrunc}"
      fi
      rm -f "$rework_head" "$rework_body" "$rework_diff"
    fi
    # Recorded as its OWN items[] entry with the reason, exactly like
    # diff.patch's capability-shaped omission above and for the same reason:
    # this is not a budget omission, and a pack.json reader deserves to know
    # WHY an input the task plainly has evidence for did not travel.
    case "$rwstate" in
      absent|current) : ;;
      *) items="$items,{\"name\":\"rework.md\",\"omitted\":\"$rwstate\"}" ;;
    esac
  fi

  # v1-m3 Task 11: lessons.md, ACTIVE blocks only (kernel.md's per-role
  # table: implementer/reviewer both receive "context.md + lessons.md +
  # ..."), budgeted BEFORE context.md -- docs/specs/plugins.md's trim order
  # is "journal/lessons/context" (journal tail-first, context head-first);
  # packs never carry journal.md at all (that's resume-only, PROTOCOL.md's
  # RESUME step 5), so the only ordering that applies here is lessons before
  # context. Truncated tail-first (`head -c`), same convention as tasks.md/
  # lessons.md in the plan pack above (_pack_build_plan) -- keeps the
  # earliest-recorded lessons, drops the newest under a tight budget.
  # lessons_active_only also strips the raw file's leading "# Lessons"
  # heading (not itself a "## " block) -- this pack's lessons.md never
  # carries it either, same as the plan pack above.
  local lessons_active_tmp
  lessons_active_tmp="$(mktemp)"
  lessons_active_only "$state/lessons.md" > "$lessons_active_tmp"
  if [ -s "$lessons_active_tmp" ]; then
    local lroom lbytes ltrunc=false
    lroom=$(( budget - used ))
    if [ "$lroom" -le 0 ]; then
      omitted="${omitted:+$omitted,}\"lessons.md\""
    else
      lbytes="$(wc -c < "$lessons_active_tmp")"
      if [ "$lbytes" -le "$lroom" ]; then
        cp "$lessons_active_tmp" "$dest/lessons.md"
      else
        head -c "$lroom" "$lessons_active_tmp" > "$dest/lessons.md"; ltrunc=true
      fi
      used=$(( used + $(wc -c < "$dest/lessons.md") ))
      items="$items,{\"name\":\"lessons.md\",\"bytes\":$(wc -c < "$dest/lessons.md"),\"truncated\":$ltrunc}"
    fi
  else
    omitted="${omitted:+$omitted,}\"lessons.md\""
  fi
  rm -f "$lessons_active_tmp"

  if [ -f "$state/context.md" ]; then
    local room ctx_bytes trunc=false
    room=$(( budget - used ))
    ctx_bytes="$(wc -c < "$state/context.md")"
    if [ "$ctx_bytes" -le "$room" ]; then
      cp "$state/context.md" "$dest/context.md"
    else
      # Context is head-truncatable: the *beginning* is dropped and the most
      # recent (tail) content is kept. `tail -c N` returns the LAST N bytes
      # of the file, which is exactly this head-first trim.
      tail -c "$room" "$state/context.md" > "$dest/context.md"; trunc=true
    fi
    used=$(( used + $(wc -c < "$dest/context.md") ))
    items="$items,{\"name\":\"context.md\",\"bytes\":$(wc -c < "$dest/context.md"),\"truncated\":$trunc}"
  else
    # Appended, never assigned over. Every other arm in this function builds
    # `omitted` with the `${omitted:+$omitted,}` idiom; this one used a bare
    # assignment, so an absent context.md silently ERASED whatever was already
    # recorded there -- lessons.md's own omission (both arms above), and, since
    # T025, rework.md's. The pack then shipped claiming context.md was the only
    # thing left out, which is exactly the kind of quiet dishonesty pack.json
    # exists to prevent: an input the engine never received, recorded nowhere.
    omitted="${omitted:+$omitted,}\"context.md\""
  fi

  if [ -n "$symbols_tmp" ]; then
    local room2 sym_bytes strunc=false
    room2=$(( budget - used ))
    if [ "$room2" -le 0 ]; then
      omitted="${omitted:+$omitted,}\"symbols.txt\""
    else
      sym_bytes="$(wc -c < "$symbols_tmp")"
      if [ "$sym_bytes" -le "$room2" ]; then
        cp "$symbols_tmp" "$dest/symbols.txt"
      else
        head -c "$room2" "$symbols_tmp" > "$dest/symbols.txt"; strunc=true
      fi
      used=$(( used + $(wc -c < "$dest/symbols.txt") ))
      items="$items,{\"name\":\"symbols.txt\",\"bytes\":$(wc -c < "$dest/symbols.txt"),\"truncated\":$strunc}"
    fi
    rm -f "$symbols_tmp"
  fi

  printf '{"budget":%s,"total_bytes":%s,"items":[%s],"omitted":[%s]}\n' \
    "$budget" "$used" "$items" "$omitted" | jq . > "$dest/pack.json"
}
