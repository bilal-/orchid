#!/usr/bin/env bash
# Input packs: kernel-materialized per-job memory. See docs/specs/plugins.md.

# _pack_fm_field <task-file> <key> -- a single frontmatter value, same
# one-key extraction the review/critique branch below inlines twice already
# (base_sha, candidate_sha); factored out here so the hook branch (needing
# base_sha, candidate_sha, AND attempts) doesn't triple that duplication a
# third time.
_pack_fm_field() {
  awk -v k="$2" '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$1"
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

  if [ -f "$state/lessons.md" ]; then
    local room2 lbytes ltrunc=false
    room2=$(( budget - used ))
    if [ "$room2" -le 0 ]; then
      omitted="${omitted:+$omitted,}\"lessons.md\""
    else
      lbytes="$(wc -c < "$state/lessons.md")"
      if [ "$lbytes" -le "$room2" ]; then
        cp "$state/lessons.md" "$dest/lessons.md"
      else
        head -c "$room2" "$state/lessons.md" > "$dest/lessons.md"; ltrunc=true
      fi
      used=$(( used + $(wc -c < "$dest/lessons.md") ))
      items="$items,{\"name\":\"lessons.md\",\"bytes\":$(wc -c < "$dest/lessons.md"),\"truncated\":$ltrunc}"
    fi
  else
    omitted="${omitted:+$omitted,}\"lessons.md\""
  fi

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

pack_build() {  # repo task op dest [hook-point] ; exit 12 = input_overflow
  local repo="$1" task="$2" op="$3" dest="$4" point="${5:-}"
  local state tf budget used=0 items="" omitted="" symbols_tmp=""
  state="$(orchid_state "$repo")"
  # `plan` (v1-m3): reserved task id, no task file exists at all (`orchid
  # task create` refuses it) -- routed to the plan-scoped pack builder
  # instead of the per-task path below.
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
    local b c
    b="$(awk -v k=base_sha '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$tf")"
    c="$(awk -v k=candidate_sha '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3)}' "$tf")"
    git -C "$repo" diff "$b".."$c" > "$dest/diff.patch"
    used=$(( used + $(wc -c < "$dest/diff.patch") ))
    items="$items,{\"name\":\"diff.patch\",\"bytes\":$(wc -c < "$dest/diff.patch"),\"truncated\":false}"

    # symbols.txt: the inline blind-spot guard's data (changed-file list +
    # every hunk header) -- the changed-symbol list PROTOCOL's routing-
    # upgrade judgment (Task 10) reads to decide whether to upgrade to a
    # worktree-capable reviewer. Built now but only written into the pack
    # (further down) AFTER context.md has taken its share of the budget: it
    # is truncatable, and trimmed strictly after the higher-priority repo
    # context, never before it.
    symbols_tmp="$(mktemp)"
    git -C "$repo" diff --unified=0 "$b".."$c" 2>/dev/null | grep -E '^(\+\+\+|@@)' > "$symbols_tmp" || true
  fi

  if [ "$used" -gt "$budget" ]; then
    rm -rf "$dest"; [ -z "$symbols_tmp" ] || rm -f "$symbols_tmp"
    echo "orchid: input_overflow — non-truncatable inputs ($used bytes) exceed pack budget ($budget)" >&2
    return 12
  fi

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
    omitted="\"context.md\""
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
