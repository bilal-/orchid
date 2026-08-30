#!/usr/bin/env bash
# THE OBJECTION INSTANCE, AND THE AUTHORITY RECORD THAT SETTLES ONE
# (T032, dogfood F33 -- convergence after the attempt-5 arbitration).
#
# lib/review.sh holds the POLICY around an arbiter's standing objection: what
# it is, who may clear it, and why a deterministic approval may not fire past
# one. This file holds the two mechanical facts that policy rests on, and it
# exists as its own library for one reason: `libexec/orchid-notify` is a tier-1
# verb that sources lib/common.sh and lib/frontmatter.sh and nothing else, while
# lib/review.sh sits behind the whole manifest/roles/resolver/envelope/capsuite/
# ledger chain. The page WRITES an authority record and the arbitration READS
# it, so the two ends need one definition of what that record is; putting it
# here is what keeps the writer from being a hand-rolled second format sitting
# in a verb that cannot see the reader.
#
# Sourced after lib/common.sh (atomic_write, orchid_state) and
# lib/frontmatter.sh (fm_get), by libexec/orchid-notify, libexec/orchid-task,
# runners/orchid-drive and lib/review.sh's own callers.
#
# ---------------------------------------------------------------------------
# 1. THE INSTANCE. `unresolved_objection` is the arbiter's TEXT, and text is not
# an identity. Two facts made that bite:
#
#   * `orchid task arbitrate --result request-changes --waive-attempt` is the
#     documented way to reject a round without charging the implementer for it,
#     and it leaves `attempts` exactly where it was. The stored line opens with
#     `a<attempt>:`, so an operator who rejects the same defect twice across a
#     waived round raises a BYTE-IDENTICAL objection the second time.
#   * An objection is cleared and later re-raised in the same words whenever the
#     fix regresses -- which is the case this whole feature exists for.
#
# In both, an answer the operator gave about the EARLIER objection is
# indistinguishable from one about the objection standing now, and the relay
# below would spend it. So the instance is a counter of its own,
# `objection_seq`, bumped on every request-changes arbitration and never reset:
# it rotates when the text does not, and it does not rewind when the objection
# is cleared, so an authority minted for instance 1 can never be spent on
# instance 2 however identical the two read.
#
# ---------------------------------------------------------------------------
# 2. THE AUTHORITY. An operator's objection may only be settled by an operator
# (lib/review.sh). An operator who has ALREADY decided -- by answering the page
# the driver raised for the stop -- must still not need a shell of their own,
# because the actor at the keyboard of an unattended run is a woken
# orchestrator. The relay that lets that model carry the decision therefore
# needs to know, unforgeably, that a given `.answer` file is an answer to THIS
# objection.
#
# It used to read that off the question's TEXT: a page quoting the objection and
# naming the settling verb was treated as a page about settling the objection.
# `notify` is on the brokered write table, so a woken model could mint exactly
# that page -- the whole of the evidence was text the model itself supplied.
#
# So the evidence is no longer the page's prose. It is a separate, structured
# record written BESIDE the question by the page's own producer:
#
#     runtime/answers/<qid>.objection
#       task: <task id>
#       seq: <objection_seq at the moment the page was raised>
#       objection: <the canonical stored objection line, byte for byte>
#       candidate: <candidate_sha at the moment the page was raised>
#       evidence: <objection_evidence at the moment the page was raised>
#
# Every field is read out of durable task state by the writer, never taken from
# the caller, and every field is compared by the reader as a WHOLE LINE, exactly
# -- no substring, no prefix, nothing an approximate match could stretch. The
# only thing that decides whether the record exists at all is which argv form
# raised the page: `orchid notify --objection` writes it, and
# runners/orchid-orchestrator-command refuses that flag structurally ("unexpected
# flag"), so the surface a woken model reaches cannot produce one.
#
# ---------------------------------------------------------------------------
# 3. THE EVIDENCE (T032 convergence, after the attempt-7 arbitration). The three
# fields above bind an answer to a TASK, an INSTANCE and a TEXT. None of them
# binds it to what the operator was actually looking at when they typed
# `approve`.
#
# An operator answering an objection page is answering one question -- "given
# this round's diff and this round's reviews, was my objection met?" -- and every
# term of it can move underneath the answer without touching a character of the
# objection or a digit of the instance: a rebase or a hand-fix re-points
# `candidate_sha`; a relaunched slot files a second accepted reviewer envelope;
# `jobs reconcile` overwrites the one already filed with a different verdict; a
# repin rewrites the pinned review plan the round is judged against. The stored
# objection line is `a<attempt>: <reason>`, so even the round number only moves
# when `attempts` does -- and `--waive-attempt` is the documented way to reject a
# round without moving it. So the answer would be relayed against evidence its
# author never saw, which is F33's shape with the operator's own `approve` as the
# instrument.
#
# The record therefore gains those two terms. `candidate:` is the diff itself,
# stored PLAINLY: it is the one term a human reading `runtime/answers/` after the
# fact has to be able to see, and it is short and fixed-width, so there is no
# reason to hide it inside a hash. `evidence:` is `objection_evidence` -- one
# digest over the candidate, the round, the pinned plan and the accepted review
# envelopes of the round the page was raised for. Both are recomputed at the
# relay and compared as whole lines like the three above them, so ANY of those
# moving invalidates the answer rather than being carried past it. The operator
# is paged again for the round that actually exists, which is the only question
# they can answer.
#
# The second is a DIGEST rather than the fields themselves for one reason: that
# set is open at the bottom (an envelope's whole content is in it, and a plan's),
# and a record with an unbounded field is one no reader can compare as a line. A
# digest is a fixed-width whole-line compare over an arbitrary amount of
# evidence. The candidate is inside it as well as beside it, and the redundancy
# is deliberate: the plain line is what a person reads, the digest is what makes
# `objection_evidence` a complete identity of the round on its own rather than a
# fragment that only means something next to another field.
#
# WHY EXACT-COMPARING THE TEXT AS WELL AS THE SEQ. The seq alone identifies the
# instance; the text is what the operator was actually shown. Comparing both
# means a record whose objection has been edited underneath it -- by a hand
# repair, a restored backup, a half-applied write -- stops matching rather than
# settling an objection nobody read. It also makes the record self-describing to
# a human reading `runtime/answers/` after the fact, which a bare counter is not.
#
# CONSUMED, NOT MERELY CHECKED. The relay's caller deletes the record before it
# clears anything (objection_authority_consume), so the authority is spent
# exactly once. A crash between the consume and the clear leaves the objection
# STANDING with no authority left to settle it: the operator pays a shell of
# their own, and the guarantee pays nothing. That is the direction a reader
# whose yes lets a model act with a human's authority has to fail in.
#
# THE RESIDUAL, stated rather than hidden. An objection re-raised in BYTE-
# IDENTICAL words composes a byte-identical page, and lib/drive.sh's
# drive_page_on_record reads an already-answered page carrying the same text as
# this stop's page and suppresses the next one (its own header documents that
# property and why). So the new instance may get no page of its own, and with no
# page there is no record and nothing to relay. The evidence field of section 3
# widens that residual rather than adding a new one: an objection whose text and
# instance are unchanged while the round's candidate, plan or envelopes have
# moved composes the same page too, so it can be suppressed the same way. Every
# part of that fails CLOSED -- the seq refuses the old instance's record, the
# evidence refuses a record raised against a round that has moved, the
# arbitration is refused, and the task stays on its `operator-decision` boundary
# where `orchid status` reports it. What is lost is a convenience, not a
# guarantee: the operator who would have been paged is the operator who typed the
# objection a moment ago, at a shell, and `orchid task arbitrate` is theirs to run
# from it.

# The suffix the authority record is filed under, beside the `.question`,
# `.answer` and `.choices` files `orchid notify`/`orchid answer` already keep
# for a qid. One constant because the writer globs nothing and the reader globs
# exactly this.
OBJECTION_AUTHORITY_EXT=objection

# objection_seq <repo> <task> -- the task's objection instance counter. Absent,
# empty or garbled reads as 0 (so the first objection is instance 1) rather than
# crashing an arithmetic expansion inside a verb running under `set -u`.
#
# `10#` because the normalization above admits a leading zero: a counter written
# `08` is decimal eight everywhere else in the kernel, and bare arithmetic would
# read it as octal -- and `09` as a fatal parse error.
objection_seq() {
  local v
  v="$(fm_get "$(orchid_state "$1")/tasks/$2.md" objection_seq 2>/dev/null || true)"
  case "$v" in ''|*[!0-9]*) printf '0\n'; return 0 ;; esac
  printf '%s\n' "$(( 10#$v ))"
}

# objection_candidate <repo> <task> -- the commit the page is about, plainly.
# Nonzero (printing nothing) when the task has none, which every caller must
# treat as "no authority": a page raised about no diff at all is one whose answer
# could be spent against any diff that arrived afterwards.
#
# It exists as a function rather than as an `fm_get` at each end so the WRITER
# and the READER cannot come to disagree about which field this is -- the same
# reason objection_authority_file is one path composer rather than two.
objection_candidate() {
  local tf v
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  tf="$(orchid_state "$1")/tasks/$2.md"
  [ -f "$tf" ] || return 1
  v="$(fm_get "$tf" candidate_sha 2>/dev/null || true)"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# objection_evidence <repo> <task> -- the digest section 3 above argues for: a
# deterministic identity of the review evidence this task's arbitration is
# standing on RIGHT NOW. Prints one hex digest; nonzero (printing nothing) when
# it cannot be computed at all, which every caller must treat as "no authority".
#
# WHAT IS IN IT, and each term is one thing that can move under an answer:
#
#   candidate:  the task's `candidate_sha` -- the diff the objection is about.
#   attempt:    `attempts` + 1, the round the evidence below is filed under. The
#               same formula lib/review.sh's review_plan_attempt uses, and the
#               same one `jobs prepare` mints this round's job ids with.
#   plan:       the pinned review plan for that round, by content, or `-` when
#               the round has none. A repin changes which slots and which depth
#               the round is judged against.
#   envelope:   every accepted review envelope of that round, by NAME and by
#               CONTENT. The name because an envelope appearing or disappearing
#               changes the set; the content because reconcile files a replaced
#               verdict at the same path.
#
# COMPUTED HERE RATHER THAN THROUGH lib/review.sh, which owns those two path
# shapes (`review_plan_file`, `_review_filed_order`). `orchid notify` is the
# writer, and it is a tier-1 verb that sources lib/common.sh, lib/frontmatter.sh
# and this file -- lib/review.sh sits behind the whole manifest/roles/resolver/
# envelope/capsuite/ledger chain and cannot be reached from there (the same
# constraint that keeps `notify`'s own attempt line from calling
# review_plan_attempt). The shapes are therefore restated, and tests/test_drive.sh
# Part AJ pins the restatement against `review_plan_file`/`review_plan_attempt`
# themselves -- so a rename on either side fails a test rather than silently
# digesting a plan that is not this round's, which reads exactly like a round
# that never had one.
#
# THE ENVELOPE GLOB IS DELIBERATELY WIDER THAN review_filed_engines'. That reader
# drops an envelope whose `.status` is not `ok` or whose `.candidate_sha` has
# moved, because it is deciding whether a slot is COVERED. This is deciding
# whether anything moved, so a rejected or stale envelope arriving beside the
# accepted ones is a change like any other -- and reading a JSON field would put
# `jq` inside a tier-1 verb besides.
#
# SORTED, not left in glob order: the digest must be a function of the SET, and
# `<base>.2.json` globs before `<base>.json` (lib/review.sh's _review_filed_order
# header has the collation argument). Filing order is not what is being recorded
# here -- presence and content are -- so the cheaper total order is the right one,
# as long as it is a total order. LC_ALL=C makes it one on any machine.
#
# FAILS CLOSED, and note where that lands. `_orchid_stream_sha256` needs `shasum`
# or `openssl`; with neither, this returns nonzero, `orchid notify --objection`
# refuses the page before it writes anything (libexec/orchid-notify), and the
# operator settles the objection from their own shell. Every other digest in the
# kernel (plugin_digest, and the trust records built on it) rests on the same two
# tools, so a machine with neither has no trust boundary to relay across either.
objection_evidence() {
  local repo="${1:-}" task="${2:-}" state tf cand attempts attempt plan base f d
  [ -n "$repo" ] && [ -n "$task" ] || return 1
  state="$(orchid_state "$repo")"
  tf="$state/tasks/$task.md"
  [ -f "$tf" ] || return 1
  cand="$(fm_get "$tf" candidate_sha 2>/dev/null || true)"
  attempts="$(fm_get "$tf" attempts 2>/dev/null || true)"
  # A missing or garbled counter reads as 0 (so the round is 1), exactly as
  # review_plan_attempt reads it, and `10#` because the guard admits a leading
  # zero -- `08` is decimal eight everywhere else in the kernel and bare
  # arithmetic would read it as octal.
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  attempt=$(( 10#$attempts + 1 ))
  plan="$state/reviews/$task-a$attempt.review-plan.json"
  base="$state/reviews/$task-a$attempt-"
  d="$({
    printf 'candidate: %s\n' "$cand"
    printf 'attempt: %s\n' "$attempt"
    if [ -f "$plan" ]; then
      printf 'plan: %s\n' "$(_orchid_stream_sha256 < "$plan")"
    else
      printf 'plan: -\n'
    fi
    for f in "$base"*.json; do
      # The glob matching nothing yields the pattern itself, which is not a file
      # -- a round with no envelope filed yet contributes no line, and that is a
      # state the digest has to be able to name.
      [ -f "$f" ] || continue
      printf 'envelope: %s %s\n' "${f##*/}" "$(_orchid_stream_sha256 < "$f")"
    done | LC_ALL=C sort
  } | _orchid_stream_sha256)" || return 1
  # An empty or non-hex roll-up is a digest tool that produced nothing, never an
  # evidence set that happens to hash to it.
  case "$d" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  printf '%s\n' "$d"
}

# objection_authority_file <repo> <qid> -- where the record for that page lives.
# Composed rather than taken from lib/common.sh's `orchid_runtime`, which
# mkdir -p's what it returns: the readers below must not create the directory
# they are asking about, and lib/drive.sh's drive_page_on_record composes the
# same path the same way for the same reason.
objection_authority_file() {
  printf '%s/.orchid/runtime/answers/%s.%s\n' "$1" "$2" "$OBJECTION_AUTHORITY_EXT"
}

# objection_authority_write <repo> <qid> <task> <seq> <objection> <candidate>
# <evidence> --
# mint the record. Every argument is a fact the CALLER read out of durable state;
# this function invents nothing and validates that it was given all of it.
#
# Rendered into a variable and only then written, never `printf ... |
# atomic_write`: atomic_write consumes whatever its producer managed to emit and
# reports the success of `mv`, so a producer that died mid-pipe would land a
# TRUNCATED authority record -- and a truncated one is a record whose missing
# lines the reader compares against empty strings.
objection_authority_write() {
  local repo="$1" qid="$2" task="$3" seq="$4" objection="$5"
  local candidate="${6:-}" evidence="${7:-}" answers body
  [ -n "$repo" ] && [ -n "$qid" ] && [ -n "$task" ] && [ -n "$objection" ] || return 1
  # The candidate and the evidence digest are as required as the three fields
  # above them: a record minted without either is one the reader below can only
  # ever compare against an empty line, which is an authority that binds to no
  # round at all.
  [ -n "$candidate" ] && [ -n "$evidence" ] || return 1
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  body="$(printf 'task: %s\nseq: %s\nobjection: %s\ncandidate: %s\nevidence: %s' \
    "$task" "$seq" "$objection" "$candidate" "$evidence")" || return 1
  [ -n "$body" ] || return 1
  answers="$repo/.orchid/runtime/answers"
  mkdir -p "$answers" || return 1
  printf '%s\n' "$body" | atomic_write "$answers/$qid.$OBJECTION_AUTHORITY_EXT"
}

# objection_authority_qids <repo> -- one qid per authority record on disk, in
# glob order. Prints nothing when the answers directory does not exist, which is
# the ordinary state of a repository nobody has ever paged.
#
# The WALK IS OVER THE RECORDS, not over the questions, and that is the shape of
# the whole reading: a page with no record beside it is not a page the relay
# knows anything about, so a question a model minted for itself never enters the
# loop at all. It lives here rather than at the reader so the suffix stays a
# single constant in a single file -- a glob spelled at the reading end would be
# one rename away from silently matching nothing, which reads exactly like an
# operator who never answered.
objection_authority_qids() {
  local answers f q
  answers="$1/.orchid/runtime/answers"
  [ -d "$answers" ] || return 0
  for f in "$answers"/*."$OBJECTION_AUTHORITY_EXT"; do
    # The glob matching nothing yields the pattern itself under bash's default
    # nullglob-off, which is not a file.
    [ -f "$f" ] || continue
    q="${f##*/}"; q="${q%".$OBJECTION_AUTHORITY_EXT"}"
    printf '%s\n' "$q"
  done
}

# objection_authority_matches <file> <task> <seq> <objection> <candidate>
# <evidence> -- exit
# 0 iff that record authorises a decision about exactly this task, this instance,
# this objection text, this candidate and this review evidence.
#
# FIVE LINES AND NOTHING ELSE. A sixth line is refused rather than ignored,
# for the reason lib/review.sh's review_plan_row_valid refuses a sixth column: a
# record this reader does not fully understand is not one it may act on, and
# "parse what I recognize and skip the rest" is how a format grows a field that
# changes the meaning of the ones above it without any reader noticing.
#
# A record written before the `candidate:` and `evidence:` lines existed
# therefore stops matching outright, on its empty fourth line, rather than being
# read as one that binds no round -- which is the fail-closed direction: the
# operator is paged again for the round that exists now, and the page they
# answered before the fields existed authorises nothing.
#
# Every `read` is `|| true`: a record with fewer than five lines leaves the
# remaining variables empty, and an empty variable fails the whole-line compare
# below on its own. Letting the read's status decide instead would make a
# short record and a mismatched one two different code paths for one answer.
objection_authority_matches() {
  local f="$1" a_task="" a_seq="" a_obj="" a_cand="" a_ev="" a_extra=""
  [ -f "$f" ] || return 1
  # A candidate or an evidence digest the CALLER could not read is not a
  # wildcard: with nothing to compare, no record may match.
  [ -n "${5:-}" ] && [ -n "${6:-}" ] || return 1
  {
    IFS= read -r a_task   || true
    IFS= read -r a_seq    || true
    IFS= read -r a_obj    || true
    IFS= read -r a_cand   || true
    IFS= read -r a_ev     || true
    IFS= read -r a_extra  || true
  } < "$f"
  [ -z "$a_extra" ] || return 1
  [ "$a_task" = "task: $2" ] || return 1
  [ "$a_seq" = "seq: $3" ] || return 1
  [ "$a_obj" = "objection: $4" ] || return 1
  [ "$a_cand" = "candidate: $5" ] || return 1
  [ "$a_ev" = "evidence: $6" ] || return 1
  return 0
}

# objection_authority_consume <repo> <qid> -- spend the record, and report
# whether it is really gone. Nonzero means the caller must NOT go on to clear
# anything: an authority that survives its own consumption is one a replay could
# spend a second time, which is the whole property this call exists to keep.
objection_authority_consume() {
  local f
  f="$(objection_authority_file "$1" "$2")"
  rm -f "$f" 2>/dev/null || true
  [ ! -e "$f" ] || return 1
  return 0
}
