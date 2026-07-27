#!/usr/bin/env bash
# Input packs: kernel-materialized per-job memory. See docs/specs/plugins.md.

pack_build() {  # repo task op dest ; exit 12 = input_overflow
  local repo="$1" task="$2" op="$3" dest="$4"
  local state tf budget used=0 items="" omitted=""
  state="$(orchid_state "$repo")"; tf="$state/tasks/$task.md"
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
  fi

  if [ "$used" -gt "$budget" ]; then
    rm -rf "$dest"
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
    items="$items,{\"name\":\"context.md\",\"bytes\":$(wc -c < "$dest/context.md"),\"truncated\":$trunc}"
  else
    omitted="\"context.md\""
  fi

  printf '{"budget":%s,"total_bytes":%s,"items":[%s],"omitted":[%s]}\n' \
    "$budget" "$used" "$items" "$omitted" | jq . > "$dest/pack.json"
}
