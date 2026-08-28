#!/usr/bin/env bash
# Dual-review routing (v1-m2 Task 3) — see docs/specs/kernel.md's
# "Independence" section for the policy this encodes: `risk_tier` drives
# review ROUTING and independence requirements; `low` wants a single
# engine-independent reviewer (falling back to a labeled session-independent
# one when no other engine is available); `medium`/`high` want two reviewer
# slots (worktree-capable for depth + engine-independent for diversity).
#
# Sourced after lib/resolver.sh, lib/capsuite.sh, lib/ledger.sh (per those
# files' own sourcing-order headers). Callers must source, in this order:
# lib/common.sh, lib/frontmatter.sh, lib/manifest.sh, lib/roles.sh, lib/
# resolver.sh, lib/envelope.sh, lib/capsuite.sh, lib/ledger.sh, then this
# file — exactly the order libexec/orchid-jobs already sources everything
# else in.
#
# INV-05: every decision below is config-shaped (`role.reviewer`'s chain,
# the `review.<tier>` chain) or capability-shaped (manifest capabilities,
# role_eligibility_reason) — never a branch on a specific engine's name. The
# tier default engine names (`agy`, `codex-review,agy`) are config DEFAULT
# VALUES passed to config_get, not a case table keyed on engine identity.

# review_required_count <risk_tier> -- low -> 1; medium|high -> 2; anything
# else (unknown/empty) -> 2, fail-safe (never under-review an unrecognized
# tier).
review_required_count() {
  case "$1" in
    low) echo 1 ;;
    *) echo 2 ;;
  esac
}

# review_depth_required <risk_tier> -- exit 0 iff this tier requires DEPTH
# evidence as well as a count: at least one review produced by a WORKTREE-
# CAPABLE engine, one that can open a file the diff does not contain. `low`
# -> no; `medium`/`high` -> yes; anything unrecognized -> yes, the same
# fail-safe posture review_required_count and _review_tier_key already take.
#
# v1.1 (T012), from lesson L010 with direct evidence from run r-001: engine
# independence and review DEPTH are different axes. An inline, diff-only
# reviewer judges from diff text alone; on r-001's T003 one approved a
# candidate whose central acceptance criterion was unmet, with a null
# findings array, while a worktree-capable slot found the defect and cited
# the file and line. Independence is still required (slot 1, every tier, and
# the reason agy is never dropped); depth is what this predicate adds.
#
# WHY THIS KEYS ON risk_tier, NOT ON THE TASK'S PROSE. The requirement being
# encoded -- "the criteria involve interaction with existing kernel
# behaviour" -- is a judgement about the task, and `risk_tier` is already the
# kernel's operator-set, monotonic, `--reason`-carrying proxy for exactly
# that judgement (INV-08; kernel.md ties medium/high to shared/kernel
# surface). Deriving it a second time by reading `acceptance_criteria` would
# make the kernel parse prose, which it does nowhere else. See docs/specs/
# kernel.md, "Review depth", for the decision and the rejected alternatives.
review_depth_required() {
  case "$1" in
    low) return 1 ;;
    *) return 0 ;;
  esac
}

# review_implementer_engine <repo> <task> -- the task's recorded
# `implementer_engine_id` frontmatter if set (kernel-derived, single-writer:
# `task advance implementing->testing` is the only writer of that field),
# else `resolve_role <repo> implementer` (first-of-chain) as the baseline
# for a task that hasn't reached testing yet, or was hand-walked by a
# fixture without a planted implement envelope.
review_implementer_engine() {
  local repo="$1" task="$2" tf v
  tf="$(orchid_state "$repo")/tasks/$task.md"
  v="$(fm_get "$tf" implementer_engine_id 2>/dev/null || true)"
  [ -n "$v" ] || v="$(resolve_role "$repo" implementer)"
  echo "$v"
}

# _review_tier_key <risk_tier> -- normalizes to low|medium|high for the
# review.<tier> config lookup; any unrecognized value reads as high (same
# fail-safe posture as review_required_count).
_review_tier_key() {
  case "$1" in
    low) echo low ;;
    medium) echo medium ;;
    *) echo high ;;
  esac
}

# _review_tier_chain <repo> <risk_tier> -- the review.<tier> config chain
# (comma-separated engine names), config default per kernel.md: low -> agy;
# medium/high -> codex-review,agy (worktree-capable depth + engine-
# independent diversity).
_review_tier_chain() {
  local repo="$1" key def
  key="$(_review_tier_key "$2")"
  case "$key" in
    low) def=agy ;;
    *) def="codex-review,agy" ;;
  esac
  config_get "$repo" "review.$key" "$def"
}

# _review_worktree_capable <plugin-dir> -- exit 0 iff the manifest declares
# workspace_read ("worktree-capable": able to inspect the full checkout, not
# just the diff). Built as the space-bounded "have" string idiom (lib/
# roles.sh, lib/capsuite.sh) rather than `manifest_capabilities | grep -q`,
# to sidestep the SIGPIPE-under-pipefail race those files already document.
_review_worktree_capable() {
  local dir="$1" atom have=" "
  while IFS= read -r atom; do
    [ -n "$atom" ] && have="$have$atom "
  done < <(manifest_capabilities "$dir" 2>/dev/null)
  case "$have" in *" workspace_read "*) return 0 ;; esac
  return 1
}

# review_engine_depth <engine-name> -- the DEPTH column of the routing table:
# `worktree` when the named engine is worktree-capable, else `inline`. A name
# that does not resolve at all reads `inline` -- depth is a positive claim,
# and an engine nobody can discover cannot be proven to be able to open the
# checkout.
review_engine_depth() {
  local dir
  if dir="$(resolve_engine_dir "$1" 2>/dev/null)" && _review_worktree_capable "$dir"; then
    echo worktree
  else
    echo inline
  fi
}

# review_qid_worktree_capable <qualified-engine-id> -- exit 0 iff the engine
# that FILED a review is worktree-capable. Reviewer envelopes name their
# producer by its manifest `id=` (e.g. "orchid/claude"), never by the plugin
# DIRECTORY name a routing row carries, so this is the qualified-id-keyed
# counterpart of review_engine_depth: strip the publisher, resolve the bare
# name, and only trust the answer when that name qualifies BACK to the same
# id (resolve_engine_qualified_id's own round trip, fallback included). A
# publisher whose manifest id does not match its directory name, a forged
# `orchid/<anything>`, or an engine not installed here therefore reads as
# not-worktree-capable rather than as a lucky prefix match.
review_qid_worktree_capable() {
  local qid="$1" name dir
  [ -n "$qid" ] || return 1
  name="${qid##*/}"
  [ -n "$name" ] || return 1
  [ "$(resolve_engine_qualified_id "$name")" = "$qid" ] || return 1
  dir="$(resolve_engine_dir "$name" 2>/dev/null)" || return 1
  _review_worktree_capable "$dir"
}

# review_routing_has_depth <routing-table> -- exit 0 iff at least one row of
# a `review_routing`/`orchid jobs review-plan` table is a `worktree` slot.
# Read the 4th field only: an install with no eligible worktree-capable
# reviewer at all still gets its full complement of slots (never zero), so
# "how many slots" can never answer this question.
review_routing_has_depth() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | cut -s -f4)" = worktree ] || continue
    return 0
  done <<< "$1"
  return 1
}

# _review_candidate_ok <repo> <engine> -- discovered + reviewer-role-
# eligible + ledger-available. Shared by both slots' candidate walks below.
_review_candidate_ok() {
  local repo="$1" engine="$2" dir
  dir="$(resolve_engine_dir "$engine" 2>/dev/null)" || return 1
  role_eligibility_reason reviewer "$dir" >/dev/null 2>&1 || return 1
  ledger_available "$repo" "$engine" || return 1
  return 0
}

# review_routing <repo> <task> -- prints the routing table for this task's
# current risk_tier, one line per required slot: <slot>\t<engine>\t
# <engine-independent|session-independent>\t<worktree|inline>.
#
# The two labels are INDEPENDENT AXES and the table prints both because
# neither implies the other (lesson L010): column 3 is who the reviewer is
# NOT (the implementer), column 4 is what the reviewer can SEE. The depth
# column is descriptive, never a filter -- no slot is ever dropped for being
# `inline`, because on a diff it can inspect an inline reviewer is often the
# only genuine engine independence an install has. What reacts to an
# all-`inline` medium/high table is the arbitration policy (lib/drive.sh's
# drive_review_decision) and the journal, not this function.
review_routing() {
  local repo="$1" task="$2" tf risk_tier count impl_engine tier_chain
  tf="$(orchid_state "$repo")/tasks/$task.md"
  risk_tier="$(fm_get "$tf" risk_tier 2>/dev/null || true)"
  [ -n "$risk_tier" ] || risk_tier=low
  count="$(review_required_count "$risk_tier")"
  impl_engine="$(review_implementer_engine "$repo" "$task")"
  tier_chain="$(_review_tier_chain "$repo" "$risk_tier")"

  # Slot 1 (all tiers): the first entry of resolve_role_chain(reviewer) ++
  # the tier chain that differs from the implementer's engine and is
  # discovered + eligible + available -> engine-independent. No such entry
  # -> the implementer's own engine, labeled session-independent (never
  # silently -- the label itself is the record).
  local e slot1_engine="" slot1_label=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$e" != "$impl_engine" ] || continue
    _review_candidate_ok "$repo" "$e" || continue
    slot1_engine="$e"; slot1_label="engine-independent"
    break
  done < <(resolve_role_chain "$repo" reviewer; printf '%s\n' "$tier_chain" | tr ',' '\n')
  if [ -z "$slot1_engine" ]; then
    slot1_engine="$impl_engine"; slot1_label="session-independent"
  fi
  printf '1\t%s\t%s\t%s\n' "$slot1_engine" "$slot1_label" "$(review_engine_depth "$slot1_engine")"

  [ "$count" -ge 2 ] || return 0

  # Slot 2 (medium/high only): the next DISTINCT available engine,
  # worktree-capable entries tried first (depth), independence labeled the
  # same way as slot 1. Fewer distinct engines than slots -> repeat slot 1's
  # engine, forced session-independent (a single engine reviewing twice is
  # degraded independence regardless of its relation to the implementer) --
  # never zero slots.
  #
  # THE DEPTH PASS SEARCHES WIDER THAN THE TIER CHAIN (v1.1, T012). These
  # tiers exist to pair an inline reviewer with one that can open the file
  # the change must stay consistent with, so settling for a second INLINE
  # engine merely because it is the next name in `review.<tier>` gives up the
  # pairing over a config-ordering accident. Pass 1 therefore continues past
  # the tier chain into `role.reviewer`'s own chain and finally the
  # implementer's engine -- which is worktree-capable on any install whose
  # implementer can also review, and whose slot is honestly labeled
  # `session-independent` below. On r-001 that was exactly the slot that
  # caught the defect the inline slot approved (lesson L010). Everything
  # reached this way still passes the same discovery + reviewer-eligibility +
  # ledger test as a tier-chain entry; nothing is admitted that
  # `_review_candidate_ok` would refuse.
  #
  # Pass 2 (the INLINE fallback, below) is deliberately NOT widened: once no
  # depth is available anywhere, which inline engine fills the slot is a
  # plain preference question, and `review.<tier>` is the operator's answer
  # to it.
  local dir slot2_engine=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$e" != "$slot1_engine" ] || continue
    dir="$(resolve_engine_dir "$e" 2>/dev/null)" || continue
    _review_worktree_capable "$dir" || continue
    _review_candidate_ok "$repo" "$e" || continue
    slot2_engine="$e"; break
  done < <(printf '%s\n' "$tier_chain" | tr ',' '\n'
           resolve_role_chain "$repo" reviewer 2>/dev/null || true
           printf '%s\n' "$impl_engine")
  if [ -z "$slot2_engine" ]; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      [ "$e" != "$slot1_engine" ] || continue
      dir="$(resolve_engine_dir "$e" 2>/dev/null)" || continue
      _review_worktree_capable "$dir" && continue   # already tried above
      _review_candidate_ok "$repo" "$e" || continue
      slot2_engine="$e"; break
    done < <(printf '%s\n' "$tier_chain" | tr ',' '\n')
  fi
  local slot2_label
  if [ -n "$slot2_engine" ]; then
    if [ "$slot2_engine" = "$impl_engine" ]; then slot2_label="session-independent"; else slot2_label="engine-independent"; fi
  else
    slot2_engine="$slot1_engine"; slot2_label="session-independent"
  fi
  printf '2\t%s\t%s\t%s\n' "$slot2_engine" "$slot2_label" "$(review_engine_depth "$slot2_engine")"
}

# review_plan_row_valid <row> -- exit 0 iff <row> is one well-formed row of the
# grammar `review_routing` prints and `orchid jobs review-plan` re-emits:
# <slot>\t<engine>\t<engine-independent|session-independent>\t
# <worktree|inline>, and NOTHING after it. Readers that dispatch off the table
# fail closed on anything else, so a jq diagnostic or a stray stderr line can
# never be mistaken for a reviewer slot.
#
# It lives HERE, beside the function that emits the grammar, rather than at
# the reading end where it started. A validator kept next to its consumer
# drifts the moment the table grows a column, and it drifts SILENTLY in the
# safe-looking direction: runners/orchid-drive's copy pinned the row at
# exactly three fields and rejected any fourth, so T012's depth column made
# every row of a perfectly good pin read as a diagnostic, emptied the routing
# table, and stopped the driver from dispatching a reviewer at ANY tier. One
# definition, next to the printf that decides the shape, is what keeps the
# next column from doing it again.
review_plan_row_valid() {
  local slot eng label depth extra
  IFS=$'\t' read -r slot eng label depth extra <<< "$1"
  case "$slot" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$eng" ] || return 1
  case "$label" in engine-independent|session-independent) ;; *) return 1 ;; esac
  case "$depth" in worktree|inline) ;; *) return 1 ;; esac
  [ -z "$extra" ] || return 1
}

# ===========================================================================
# The PINNED plan (T039, run r-002's lesson L027)
# ===========================================================================
# `review_routing` above is computed LIVE, from engine health among other
# things. That is right for choosing where to send a review, and wrong for
# judging one that has already been filed -- and the two were the same table.
#
# What it cost, live on r-002: T024 collected two valid, candidate-bound
# review envelopes (one approve, one request-changes) from two different
# engines. Then the engine that had filed the FIRST of them accumulated three
# consecutive failures on unrelated work and went `failing` in the ledger.
# `_review_candidate_ok` therefore stopped offering it, slot 1 re-routed to
# another engine, and the review it had already filed was suddenly
# attributable to no slot at all. The driver refused to reconcile evidence it
# could not credit; the `feature` archetype declares `reviewing ->
# arbitrating` as the only forward edge; that edge is gated on slot coverage;
# and `orchid task arbitrate` refuses any status but `arbitrating`. The task
# had no legal exit left, and nothing about it was broken: no envelope was
# stale, no engine was misconfigured, and the reviews were exactly the two the
# tier asked for. THE PLAN MOVED UNDER THE EVIDENCE.
#
# So the plan is pinned. Once an attempt has a candidate to review, the table
# is written down once (`review_plan_pin_rows`, through `orchid jobs review-plan
# <id> --pin`) and every later reader gets THAT table back until the attempt
# or the candidate changes -- whichever engines are healthy at the moment of
# reading. Evidence keeps counting against the slots it was dispatched for,
# because those slots stop moving.
#
# The pin is per (task, attempt) by filename and per candidate by content:
# a new attempt files under a new name, and a candidate that moves within one
# attempt (the `merging` -> `testing` rebase edge, or a `--waive-attempt`
# rework round) invalidates the pin exactly as it invalidates the reviews it
# was pinned alongside. Two escapes exist for a plan that no longer fits its
# evidence, and both are verbs that record what they did:
# `--repin` (recompute from live routing) and `--adopt-evidence` (re-pin onto
# the engines that actually reviewed, refused when that would buy the
# task its exit by lowering the independence bar).

# review_plan_attempt <repo> <task> -- the attempt number this round's
# reviewer envelopes are filed under (`attempts` + 1), the same formula `jobs
# prepare` mints job ids with and the same one the kernel's own
# reviewing->arbitrating gate counts by. A missing/garbled `attempts` reads as
# 0 (so the answer is 1) rather than crashing an arithmetic expansion.
review_plan_attempt() {
  local tf a
  tf="$(orchid_state "$1")/tasks/$2.md"
  a="$(fm_get "$tf" attempts 2>/dev/null || true)"
  case "$a" in ''|*[!0-9]*) a=0 ;; esac
  echo $(( a + 1 ))
}

# review_plan_file <repo> <task> -- where this attempt's pin lives. Durable
# (`reviews/`, alongside the envelopes it credits), not runtime: a plan that
# vanished with a wiped runtime tree would re-derive itself live and re-open
# the dead end above.
#
# `<task>-a<n>.review-plan.json`, with a DOT where every envelope has a dash.
# Every reader of that directory globs `<task>-a<n>-<something>` -- `jobs
# reconcile` files envelopes at `-a<n>-<role>.json` for any role, including a
# custom `<name>.role` one, and lib/pack.sh's before_arbitration pack sweeps
# `-a<n>-*.json` wholesale. A plan named with a dash would sit inside all of
# those patterns: one custom role called `review-plan` and reconcile would
# quietly overwrite the pinned plan with an envelope. The dot puts this file
# outside every existing glob by construction rather than by luck.
review_plan_file() {
  printf '%s/reviews/%s-a%s.review-plan.json\n' \
    "$(orchid_state "$1")" "$2" "$(review_plan_attempt "$1" "$2")"
}

# _review_filed_order <base> -- the envelope paths matching `<base>*.json`, in
# the order `orchid jobs reconcile` FILED them, which is NOT the order the
# shell globs them in.
#
# Reconcile keeps a second accepted envelope for the same attempt as
# `<base>.2.json`, a third as `<base>.3.json` (libexec/orchid-jobs) -- and
# `<base>.2.json` sorts BEFORE `<base>.json`, because the first character
# that differs is '2' against 'j' and digits precede letters in every
# collation this runs under. So the shell hands back the SECOND review first.
#
# That is harmless for the pool matching below, which is order-free by
# construction. It is not harmless for `review_plan_adopt_evidence_rows`, which
# credits the i-th filed review to slot i: read in glob order, a two-review
# adoption pins slot 1 to whichever engine happened to file second, silently
# transposing the table against the evidence it is supposed to be recording.
#
# Decorate-sort-undecorate, rather than walking reconcile's own `.2`, `.3`
# counter until it gaps: that walk would drop a `.2.json` whose `.json` an
# operator had removed, changing which envelopes count. This changes ONLY the
# order -- the set is exactly the glob's, as before. A name that is not a
# counter suffix at all (a custom role whose name merely starts with
# `reviewer`) sorts last, deterministically, instead of jumping the queue.
_review_filed_order() {
  local base="$1" f n
  for f in "$base"*.json; do
    [ -e "$f" ] || continue
    n="${f%.json}"; n="${n#"$base"}"
    case "$n" in
      '') n=1 ;;           # `<base>.json` -- the first envelope reconcile filed
      .*) n="${n#.}" ;;    # `<base>.<n>.json` -- the n-th
    esac
    case "$n" in ''|*[!0-9]*) n=999999 ;; esac
    printf '%06d\t%s\n' "$n" "$f"
  done | sort | cut -f2-
}

# review_filed_engines <repo> <task> -- one line per reviewer envelope of the
# CURRENT attempt that is `ok` AND bound to the current candidate_sha: the
# QUALIFIED engine id it reports, or a bare `-` when it reports none, in the
# order they were filed (_review_filed_order).
#
# `.engine` is the only durable record of WHICH engine produced a filed
# review: `orchid jobs reconcile` cross-checks it against the job manifest's
# own engine (so it cannot be forged past reconcile) and then deletes the
# manifest, leaving the envelope as the sole survivor. Adapters that omit the
# field -- it is optional -- yield `-`, which every consumer below treats as
# attributable to any slot, and as proving no independence of its own.
review_filed_engines() {
  local repo="$1" id="$2" state tf attempt cand f e
  state="$(orchid_state "$repo")"; tf="$state/tasks/$id.md"
  attempt="$(review_plan_attempt "$repo" "$id")"
  cand="$(fm_get "$tf" candidate_sha 2>/dev/null || true)"
  [ -n "$cand" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(envelope_field "$f" '.status // empty' 2>/dev/null || true)" = ok ] || continue
    [ "$(envelope_field "$f" '.candidate_sha // empty' 2>/dev/null || true)" = "$cand" ] || continue
    e="$(envelope_field "$f" '.engine // empty' 2>/dev/null || true)"
    printf '%s\n' "${e:--}"
  done < <(_review_filed_order "$state/reviews/$id-a$attempt-reviewer")
}

# review_plan_pinned <repo> <task> -- the pinned table, iff a pin exists for
# this attempt AND is bound to the task's CURRENT candidate_sha. Exit 1
# (printing nothing) otherwise, so callers fall through to live routing.
review_plan_pinned() {
  local repo="$1" id="$2" f cand rows normalized="" slot engine label depth
  cand="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" candidate_sha 2>/dev/null || true)"
  [ -n "$cand" ] || return 1
  f="$(review_plan_file "$repo" "$id")"
  [ -f "$f" ] || return 1
  [ "$(jq -r '.candidate_sha // empty' "$f" 2>/dev/null || true)" = "$cand" ] || return 1
  rows="$(jq -r '.slots[]? | [(.slot|tostring), .engine, .label, (.depth // "")] | @tsv' "$f" 2>/dev/null || true)"
  [ -n "$rows" ] || return 1
  # Pins written before T012 have no depth field. Keep those durable plans
  # readable, but fail closed while normalizing: depth is a positive claim, so
  # an engine that cannot currently prove workspace_read is `inline`. A later
  # writing `review-plan --pin` migrates the normalized rows into the file.
  while IFS=$'\t' read -r slot engine label depth; do
    [ -n "$slot" ] && [ -n "$engine" ] && [ -n "$label" ] || continue
    case "$depth" in
      worktree|inline) ;;
      *) depth="$(review_engine_depth "$engine")" ;;
    esac
    normalized="$normalized$(printf '%s\t%s\t%s\t%s' "$slot" "$engine" "$label" "$depth")
"
  done <<< "$rows"
  [ -n "$normalized" ] || return 1
  printf '%s' "$normalized"
}

# review_plan_depth_persisted <repo> <task> -- true only when every row in the
# current candidate-bound pin carries T012's fourth (depth) field. Used by the
# writing verb to migrate a pre-T012 three-column pin even when its normalized
# table is otherwise identical, while the bare read remains read-only.
review_plan_depth_persisted() {
  local repo="$1" id="$2" f cand
  cand="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" candidate_sha 2>/dev/null || true)"
  [ -n "$cand" ] || return 1
  f="$(review_plan_file "$repo" "$id")"
  [ -f "$f" ] || return 1
  jq -e --arg cand "$cand" '
    (.candidate_sha // "") == $cand
    and ((.slots // []) | length > 0)
    and all(.slots[]; (.depth == "worktree" or .depth == "inline"))
  ' "$f" >/dev/null 2>&1
}

# review_plan <repo> <task> -- the EFFECTIVE table every reader should use:
# the pin when there is one, live routing when there is not (a task with no
# candidate yet has no evidence to protect, and nothing to pin against).
review_plan() {
  local rows
  if rows="$(review_plan_pinned "$1" "$2")"; then
    printf '%s\n' "$rows"
    return 0
  fi
  review_routing "$1" "$2"
}

# review_plan_store <repo> <task> <rows> -- write the pin. A LIBRARY helper:
# the epoch fence and the verb lock belong to the verb that calls it
# (libexec/orchid-jobs' review-plan arm), which is the only caller.
review_plan_store() {
  local repo="$1" id="$2" rows="$3" f cand attempt json
  cand="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" candidate_sha 2>/dev/null || true)"
  [ -n "$cand" ] || return 1
  [ -n "$rows" ] || return 1
  attempt="$(review_plan_attempt "$repo" "$id")"
  f="$(review_plan_file "$repo" "$id")"
  mkdir -p "$(dirname "$f")"
  # Rendered into a VARIABLE first, then written -- never `jq ... |
  # atomic_write`: atomic_write consumes whatever its producer managed to emit
  # and reports the success of `mv`, so a jq that died mid-pipe would land an
  # empty pin (a plan with no slots at all) and exit 0.
  json="$(printf '%s\n' "$rows" | jq -Rn --arg cand "$cand" --arg attempt "$attempt" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {contract:1, attempt:($attempt|tonumber), candidate_sha:$cand, pinned_at:$at,
       slots:[inputs | select(length > 0) | split("\t")
              | {slot:(.[0]|tonumber), engine:.[1], label:.[2],
                 depth:(if .[3] == "worktree" then "worktree" else "inline" end)}]}')" || return 1
  [ -n "$json" ] || return 1
  printf '%s\n' "$json" | atomic_write "$f"
}

# review_plan_pin_rows <repo> <task> -- COMPUTE the table `--pin` should land
# and print it, without writing durable state. IDEMPOTENT: a pin already bound
# to the current candidate is returned untouched (so the verb can recognize a
# no-op). Exit 1 when the task has no candidate_sha yet -- there is nothing to
# bind a plan to.
#
# Keeping computation separate from review_plan_store is deliberate: the
# writing verb must journal the exact rows FIRST and only then store them
# (kernel INV-08). A helper that computes and writes in one call makes that
# ordering impossible to enforce at the verb boundary.
review_plan_pin_rows() {
  local repo="$1" id="$2" rows cand
  cand="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" candidate_sha 2>/dev/null || true)"
  [ -n "$cand" ] || return 1
  if rows="$(review_plan_pinned "$repo" "$id")"; then
    printf '%s\n' "$rows"
    return 0
  fi
  rows="$(review_routing "$repo" "$id")"
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
}

# _review_pool_take <pool> <want> -- prints <pool> minus the FIRST line equal
# to <want>; exit 1 (pool printed unchanged) when there is none. Consuming
# rather than merely testing is what gives the matching below multiplicity:
# one envelope can satisfy exactly one slot.
_review_pool_take() {
  local want="$2" line found=0 out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$found" -eq 0 ] && [ "$line" = "$want" ]; then found=1; continue; fi
    out="$out$line
"
  done <<< "$1"
  printf '%s' "$out"
  [ "$found" -eq 1 ]
}

# review_plan_unsatisfied <repo> <task> <plan> -- the rows of <plan> that have
# NO review of their own yet. Empty output means every routed slot is covered.
#
# Keyed on SLOT IDENTITY, never on a count. A count is the wrong key the
# moment a slot is relaunched: with slot 1 routed to engine A and slot 2 to
# engine B, a relaunch that lands a SECOND A review takes the count to the
# tier's required number, and a count-keyed driver would then both stop
# dispatching slot 2 and hand two reviews from one engine to a unanimous
# approval -- defeating the engine independence the whole risk-tiered review
# policy exists to enforce (docs/specs/kernel.md, "Independence"). Here A's
# second review can only ever satisfy a slot the plan itself routed to A,
# which is exactly the degraded case `review_routing` already labels
# `session-independent` and journals.
#
# Envelopes that name no engine (`-`) are matched LAST, after every exact
# attribution has been made, and can stand in for any remaining slot: an
# adapter that omits `.engine` leaves nothing to attribute by, and refusing to
# credit its review would relaunch a slot forever.
review_plan_unsatisfied() {
  local repo="$1" id="$2" plan="$3" pool line eng qid unmatched out
  pool="$(review_filed_engines "$repo" "$id")"

  unmatched=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    eng="$(printf '%s' "$line" | cut -f2)"
    qid="$(resolve_engine_qualified_id "$eng" 2>/dev/null || true)"
    [ -n "$qid" ] || qid="$eng"
    if pool="$(_review_pool_take "$pool" "$qid")"; then
      continue
    fi
    unmatched="$unmatched$line
"
  done <<< "$plan"

  out=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if pool="$(_review_pool_take "$pool" -)"; then
      continue
    fi
    out="$out$line
"
  done <<< "$unmatched"
  printf '%s' "$out"
}

# review_plan_repin_rows <repo> <task> -- COMPUTE the table `--repin` should
# land, without writing it. It rebinds this attempt to the LIVE routing table,
# EXCEPT for the slots that already have a review of their own: those rows are
# frozen exactly as they are.
#
# That exception is the whole design. A repin that recomputed every row would
# be the defect this file exists to fix, offered as its own remedy: it would
# re-route a slot whose review is already on disk and orphan that review a
# second time. So repin only ever moves the slots that nobody has reviewed --
# which is precisely the case it exists for, a pinned slot whose engine can no
# longer be dispatched at all -- and it never hands one of those slots an
# engine a frozen row is already using, because two slots on one engine is
# degraded independence and has to be labeled as such rather than arrived at
# by accident.
review_plan_repin_rows() {
  local repo="$1" id="$2" old live unsat unsat_slots kept used rows impl cand depth
  cand="$(fm_get "$(orchid_state "$repo")/tasks/$id.md" candidate_sha 2>/dev/null || true)"
  [ -n "$cand" ] || return 1
  old="$(review_plan "$repo" "$id")"
  live="$(review_routing "$repo" "$id")"
  [ -n "$live" ] || return 1
  if [ -z "$old" ]; then
    printf '%s\n' "$live"
    return 0
  fi

  unsat="$(review_plan_unsatisfied "$repo" "$id" "$old")"
  unsat_slots=" "
  local line slot
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    unsat_slots="$unsat_slots$(printf '%s' "$line" | cut -f1) "
  done <<< "$unsat"

  # Pass 1 -- freeze every covered row, and book its engine as taken.
  kept=""; used=" "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    slot="$(printf '%s' "$line" | cut -f1)"
    case "$unsat_slots" in *" $slot "*) continue ;; esac
    kept="$kept$line
"
    used="$used$(printf '%s' "$line" | cut -f2) "
  done <<< "$old"

  # Pass 2 -- every slot the plan has, frozen row first, then the first live
  # engine nobody has taken, then (never zero slots) whatever the live table
  # named for it.
  local n_old n_live n i keptrow liverow eng label cand
  n_old="$(printf '%s\n' "$old" | grep -c '[^[:space:]]' || true)"
  n_live="$(printf '%s\n' "$live" | grep -c '[^[:space:]]' || true)"
  n="$n_old"; [ "$n_live" -le "$n" ] || n="$n_live"
  impl="$(review_implementer_engine "$repo" "$id")"
  rows=""
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$(( i + 1 ))
    # `!found` rather than `exit` in every awk below: `exit` closes the pipe
    # the instant it matches, and under `set -o pipefail` an upstream printf
    # still mid-write is SIGPIPEd, its 141 becomes the substitution's status,
    # and the caller (libexec/orchid-jobs runs `set -e`) dies on a row it
    # found. Reading to EOF costs nothing on a two-line table and cannot race.
    keptrow="$(printf '%s\n' "$kept" | awk -F'\t' -v s="$i" '$1 == s && !found { print; found = 1 }')"
    if [ -n "$keptrow" ]; then
      rows="$rows$keptrow
"
      continue
    fi
    liverow="$(printf '%s\n' "$live" | awk -F'\t' -v s="$i" '$1 == s && !found { print; found = 1 }')"
    eng=""
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      case "$used" in *" $cand "*) continue ;; esac
      eng="$cand"; break
    done < <(printf '%s\n' "$live" | cut -f2)
    if [ -z "$eng" ]; then
      eng="$(printf '%s' "$liverow" | cut -f2)"
      [ -n "$eng" ] || eng="$(printf '%s\n' "$old" | awk -F'\t' -v s="$i" '$1 == s && !found { print $2; found = 1 }')"
    fi
    [ -n "$eng" ] || continue
    # Labeled BEFORE the engine is booked: a slot that had to reuse an engine
    # another slot already holds is degraded independence regardless of its
    # relation to the implementer, exactly as `review_routing`'s own
    # fewer-engines-than-slots fallback says.
    label="engine-independent"
    case "$used" in *" $eng "*) label="session-independent" ;; esac
    [ "$eng" != "$impl" ] || label="session-independent"
    used="$used$eng "
    depth="$(review_engine_depth "$eng")"
    rows="$rows$(printf '%s\t%s\t%s\t%s' "$i" "$eng" "$label" "$depth")
"
  done
  [ -n "$rows" ] || return 1
  printf '%s' "$rows"
}

# _review_engine_name_for_qid <repo> <task> <qualified-id> -- the plugin NAME
# whose manifest claims <qualified-id>, or exit 1. A routing row names an
# engine the way config does (`agy`), while an envelope names it the way its
# manifest does (`orchid/agy`), so adopting filed evidence into a plan has to
# cross that boundary.
#
# The cheap direction first -- strip the publisher and ROUND-TRIP the result
# through resolve_engine_qualified_id, which is what makes the strip safe: it
# is accepted only when the stripped name really does resolve back to the same
# qualified id, so a third-party `acme/foo` whose bound name is not `foo`
# falls through instead of being silently mis-credited. The fallback walks the
# names this task could actually have been routed to.
_review_engine_name_for_qid() {
  local repo="$1" id="$2" qid="$3" tf risk_tier cand
  cand="${qid#*/}"
  if [ -n "$cand" ] && [ "$(resolve_engine_qualified_id "$cand" 2>/dev/null || true)" = "$qid" ]; then
    printf '%s\n' "$cand"
    return 0
  fi
  tf="$(orchid_state "$repo")/tasks/$id.md"
  risk_tier="$(fm_get "$tf" risk_tier 2>/dev/null || true)"
  [ -n "$risk_tier" ] || risk_tier=low
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    [ "$(resolve_engine_qualified_id "$e" 2>/dev/null || true)" = "$qid" ] || continue
    printf '%s\n' "$e"
    return 0
  done < <(resolve_role_chain "$repo" reviewer
           printf '%s\n' "$(_review_tier_chain "$repo" "$risk_tier")" | tr ',' '\n'
           review_implementer_engine "$repo" "$id")
  return 1
}

# _review_distinct_count -- how many DISTINCT non-empty lines its stdin holds,
# ignoring the anonymous `-` (an envelope naming no engine proves no
# independence, whichever slot it ends up credited to).
_review_distinct_count() {
  local line seen=" " n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" != "-" ] || continue
    case "$seen" in *" $line "*) continue ;; esac
    seen="$seen$line "; n=$(( n + 1 ))
  done
  echo "$n"
}

# review_plan_adopt_evidence_rows <repo> <task> -- COMPUTE the table
# `--adopt-evidence` should land, without writing it: re-pin this attempt's
# plan onto the engines that ACTUALLY filed valid, candidate-bound reviews.
# This is the recorded exit for a task whose plan no longer matches its
# evidence: the reviews on hand were dispatched, filed and reconciled against
# slots that have since been re-routed, and crediting them to the slots they
# came from is the whole of the remedy.
#
# It may never buy a task its exit by lowering the bar, so it refuses unless
# BOTH hold, with a diagnostic naming which one failed:
#   - there is at least one review per slot (a slot with no review at all
#     must be DISPATCHED, not adopted); and
#   - the filed reviews name at least as many distinct engines as the plan
#     they replace does. Two reviews from one engine can never be adopted into
#     a plan that asked for two different ones -- that is precisely the
#     same-engine pair the independence policy exists to refuse, and it stays
#     refused.
review_plan_adopt_evidence_rows() {
  local repo="$1" id="$2" plan filed need n_filed line qid name impl rows i depth
  plan="$(review_plan "$repo" "$id")"
  [ -n "$plan" ] || { echo "orchid: $id has no review plan to adopt evidence into" >&2; return 1; }
  filed="$(review_filed_engines "$repo" "$id")"
  need="$(printf '%s\n' "$plan" | grep -c '[^[:space:]]' || true)"
  n_filed=0
  [ -z "$filed" ] || n_filed="$(printf '%s\n' "$filed" | grep -c '[^[:space:]]' || true)"
  if [ "$n_filed" -lt "$need" ]; then
    echo "orchid: $id has $n_filed review envelope(s) bound to the current candidate but $need slot(s) — a slot with no review of its own must be dispatched, not adopted" >&2
    return 1
  fi
  local have_distinct want_distinct
  have_distinct="$(printf '%s\n' "$filed" | _review_distinct_count)"
  want_distinct="$(printf '%s\n' "$plan" | cut -f2 | _review_distinct_count)"
  if [ "$have_distinct" -lt "$want_distinct" ]; then
    echo "orchid: $id's filed reviews name $have_distinct distinct engine(s) but the plan routes $want_distinct — adopting them would lower the tier's engine independence, not record it" >&2
    return 1
  fi

  # The named engines, in the order `jobs reconcile` filed them, mapped back
  # to the plugin names a routing row carries.
  local named=""
  while IFS= read -r qid; do
    [ -n "$qid" ] || continue
    [ "$qid" != "-" ] || continue
    name="$(_review_engine_name_for_qid "$repo" "$id" "$qid")" || {
      echo "orchid: $id has a review filed by '$qid', which resolves to no installed engine — its slot cannot be pinned (install or bind that engine, or use --repin)" >&2
      return 1
    }
    named="$named$name
"
  done <<< "$filed"

  # Select the evidence engines the adopted slots will name. Required
  # distinct engines come first, in first-filing order; only then fill any
  # remaining degraded/session-independent slots from the unused envelope
  # pool. This ordering matters when more envelopes exist than slots. With
  # filed engines A,A,B and a two-distinct-engine plan, checking distinctness
  # over ALL evidence and then taking the first two would land A,A -- silently
  # lowering the independence the precheck just claimed to preserve while B
  # sat unused in the third envelope.
  local selected="" pool="$named" seen=" " selected_n=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    selected="$selected$name
"
    selected_n=$(( selected_n + 1 ))
    pool="$(_review_pool_take "$pool" "$name")" || return 1
    [ "$selected_n" -ge "$want_distinct" ] && break
  done <<< "$named"
  while [ "$selected_n" -lt "$need" ] && IFS= read -r name; do
    [ -n "$name" ] || continue
    selected="$selected$name
"
    selected_n=$(( selected_n + 1 ))
  done <<< "$pool"

  impl="$(review_implementer_engine "$repo" "$id")"
  local eng label used=" "
  rows=""; i=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$(( i + 1 ))
    # Slot i takes the i-th selected evidence engine when there is one; slots
    # left over (covered by an anonymous envelope, which is creditable to any
    # of them) keep the engine the plan already named. The label is re-derived,
    # never carried over: an adopted engine that is the implementer's own, or
    # one a slot above already holds, is degraded independence and has to say
    # so -- the same two rules `review_routing` labels by.
    eng="$(printf '%s\n' "$selected" | sed -n "${i}p")"
    [ -n "$eng" ] || eng="$(printf '%s' "$line" | cut -f2)"
    label="engine-independent"
    case "$used" in *" $eng "*) label="session-independent" ;; esac
    [ "$eng" != "$impl" ] || label="session-independent"
    used="$used$eng "
    depth="$(review_engine_depth "$eng")"
    rows="$rows$(printf '%s\t%s\t%s\t%s' "$i" "$eng" "$label" "$depth")
"
  done <<< "$plan"

  printf '%s' "$rows"
}
