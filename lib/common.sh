#!/usr/bin/env bash

# orchid_die stays the FIRST command in this file on purpose: a ShellCheck
# directive that precedes a file's first command applies to the ENTIRE file,
# so the SC2034 suppression under it (ORCHID_VERSION) needs a real command
# ahead of it to stay scoped to that one assignment -- a file-wide SC2034
# would silently hide every genuinely-unused variable added to this library
# later (T004 rework; scripts/ci-local.sh's exception policy now rejects the
# file-wide placement outright).
orchid_die() { echo "orchid: $*" >&2; exit 1; }

# bin/orchid resolves itself and selects a libexec target while PATH is limited
# to fixed machine-local system/package-manager directories. It carries the
# caller's original PATH as inert environment data rather than restoring it
# before the handoff. Ordinary/manual verbs recover that PATH here, before any
# of their other libraries or helpers run. A trust-boundary entry point sets
# __orchid_entry_defer_restore=1 before sourcing this file and calls the helper
# only after its authorization decision when later work genuinely needs the
# operator PATH.
_orchid_entry_restore_operator_path() {
  [ "${__orchid_entry_context:-}" = 1 ] || return 0
  if [ "${__orchid_entry_path_was_set:-}" = x ]; then
    PATH="${__orchid_entry_operator_path-}"
    export PATH
  else
    unset PATH
  fi
  unset __orchid_entry_context __orchid_entry_path_was_set
  unset __orchid_entry_operator_path __orchid_entry_defer_restore
}
if [ "${__orchid_entry_defer_restore:-0}" != 1 ]; then
  _orchid_entry_restore_operator_path
fi

# The kernel version. `orchid version` (libexec/orchid-version) prints it
# verbatim; `manifest_validate` (lib/manifest.sh) compares a plugin's
# `requires_orchid=>=X.Y` against it (major.minor only -- semver-ish, per
# docs/specs/plugins.md's Manifest section). Bump alongside a milestone,
# never mid-milestone. The `-mN` milestone-suffix era ended at v1-m4; what
# ships now is the semver prerelease `1.0.0-beta.1`. A bare `1.0.0` would
# claim the kernel is hardened and in use, and neither is true yet: nothing
# outside this repository has run orchid, and no external beta has happened.
# 1.0.0 is what that beta earns. `_manifest_version_mm` (lib/manifest.sh)
# strips the `-beta.1` suffix before comparing, so `requires_orchid=>=1.0`
# is still satisfied by this value.
# ShellCheck rationale: this public constant is consumed by scripts that source this library.
# shellcheck disable=SC2034
ORCHID_VERSION="1.0.0-beta.1"
atomic_write() { local d="$1" t; t="$(mktemp "${d}.tmp.XXXXXX")"; cat >"$t"; mv "$t" "$d"; }
orchid_state()   { echo "$1/.orchid"; }
orchid_runtime() { local r="$1/.orchid/runtime"; mkdir -p "$r"; echo "$r"; }

# orchid_list_dir <dir> -- every depth-1 entry NAME in <dir> (dotfiles
# included, `.`/`..` never), one per line. Plain bash globbing, not find(1)
# depth primaries: limiting find to one level needs primaries that are not
# in POSIX find at all (T004 rework; scripts/ci-local.sh's portability
# policy now rejects them repo-wide), while `*` under dotglob is exactly
# "one level, hidden entries included" everywhere bash 3.2 runs. Subshell
# function body, so the shopt changes never leak into the caller.
orchid_list_dir() (
  shopt -s nullglob dotglob
  local entry
  for entry in "$1"/*; do
    printf '%s\n' "${entry##*/}"
  done
)

# file_mtime <path> [fallback] -- <path>'s mtime as whole seconds since the
# epoch, portably across BSD (`stat -f %m`) and GNU (`stat -c %Y`) stat.
#
# The obvious spelling of this, which this repo carried at six sites, is
# `stat -f %m PATH 2>/dev/null || stat -c %Y PATH`. That selects the platform
# on EXIT STATUS, and it is wrong on Linux. GNU's `-f` is `--file-system` and
# takes no argument, so `%m` is parsed as a second FILE operand: GNU stat then
# fails on `%m`, SUCCEEDS on PATH, and prints PATH's default filesystem block
# -- whose first line begins `File:` -- on stdout. Both commands' stdout lands
# in the one command substitution, so the caller's `mt` becomes that block
# with a number glued to the end, and the arithmetic that follows reads `File`
# as a variable name. Under `set -u` that is fatal, and it took down
# lock_acquire (and with it every durable verb) on ubuntu-latest:
#   lib/common.sh: line 466: File: unbound variable
#
# So select on the RESULT, not the exit status: a run of digits is an mtime
# and anything else -- empty, `?`, a filesystem block, a permission error's
# leftovers -- is not, no matter what the exit status claimed.
#
# <fallback> is what a wholly unreadable mtime yields, and callers genuinely
# differ on it, so it is a parameter rather than a baked-in 0: an age check
# that must fail CLOSED wants 0 ("age unknown, refuse"), while a liveness
# check that must fail SAFE wants the current time ("assume just touched, i.e.
# still live"). Defaults to 0.
file_mtime() {
  local path="$1" fallback="${2:-0}" mt
  mt="$(stat -f %m "$path" 2>/dev/null || true)"
  case "$mt" in
    ''|*[!0-9]*) mt="$(stat -c %Y "$path" 2>/dev/null || true)" ;;
  esac
  case "$mt" in
    ''|*[!0-9]*) mt="$fallback" ;;
  esac
  printf '%s\n' "$mt"
}

# commit_subject_from_output <stdout-text> <fallback-title> -- turns a
# model reply's own text into a sane git-commit-subject fragment. Shared by
# the implement-path self-commit logic in plugins/engines/codex/run and
# plugins/engines/claude/run (identical shape in both -- v1-m4 Task 9 live
# dogfood, F11): a real run shipped literal junk subjects lifted verbatim
# from the reply's last non-empty line when that line happened to be a bare
# markdown-fence delimiter or an unsanitized bullet -- e.g. `T001: ``` `
# and ``T002: - `git diff --check` passes.``.
#
# Scans the reply from its LAST line backward (same direction the adapters
# already used to pick their own envelope `summary` line, so an
# already-clean final line still wins unchanged). Each candidate line is:
# a bare ``` / ```lang fence line is dropped entirely (empty candidate,
# falls through to the line before it); a leading list marker (`-`/`*`/`+`
# or `1.`/`1)`) is stripped; backticks are removed; whitespace is collapsed
# and trimmed. The FIRST candidate that survives sanitization non-empty
# becomes the subject, truncated to ~72 chars. If nothing in the whole
# reply survives (e.g. the reply was fence-only start to finish), falls
# back to the caller-supplied title -- both adapters already have the
# task's own title on hand (from the task pack's frontmatter), so this
# never invents a new input.
commit_subject_from_output() {
  local text="$1" fallback="$2" line clean i
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done <<< "$text"
  for (( i=${#lines[@]}-1; i>=0; i-- )); do
    line="${lines[$i]}"
    case "$line" in '```'*) continue ;; esac
    clean="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+//')"
    clean="${clean//\`/}"
    clean="$(printf '%s' "$clean" | tr -s '[:space:]' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$clean" ] || continue
    printf '%s' "${clean:0:72}"
    return 0
  done
  printf '%s' "${fallback:0:72}"
}

# orchid_html_escape <string> -- escapes the three characters illegal bare
# inside HTML/XML element content: `&` (must run FIRST -- doing `<`/`>`
# first would corrupt when this step's own `&`-insertion is then
# re-escaped) becomes `&amp;`, `<` becomes `&lt;`, `>` becomes `&gt;`.
# Promoted here (v1-m4, static status page) from runners/orchid-service's
# `_svc_xml_escape` (still that name there, now a thin wrapper over this)
# so `orchid status --html` can share the exact same escaping for
# arbitrary operator-authored text (task titles, journal entries, blocker
# text) landing in the generated page -- one home for "make text safe to
# embed in an XML/HTML element", not two copies that could drift.
orchid_html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# orchid_split_brain <repo> -- v1-m3 Task 2 (F7, docs/dogfood-notes.md
# v1-m2 section): `orchid init` restores the user's OWN branch when it
# exits; the durable .orchid state (roadmap.md and everything gated on it)
# lives only on the integration branch. A task verb run against the wrong
# checkout happily builds untracked .orchid state there anyway (tasks/,
# journal.md), and nothing else on disk distinguishes that from a healthy
# repo -- except the one file only the integration branch ever carries:
# roadmap.md. True (exit 0) when EITHER tasks/ or journal.md exists but
# roadmap.md does NOT. A repo with none of the three is simply
# uninitialized (not split-brain); a repo with roadmap.md present is
# healthy regardless of what else exists alongside it.
orchid_split_brain() {
  local state; state="$(orchid_state "$1")"
  { [ -d "$state/tasks" ] || [ -f "$state/journal.md" ]; } && [ ! -f "$state/roadmap.md" ]
}

# orchid_stale_checkout <repo> -- v1-m3 final review (CRITICAL 2): the live
# run's 6638-line silent revert. Something (a pump-run tick, a stray script)
# advanced the integration branch's ref directly (`git update-ref`) while
# THIS checkout was itself sitting on that same branch -- unlike a normal
# `git checkout`/`commit`, that moves HEAD forward without ever touching the
# index or working tree here, so the checkout silently falls behind its own
# branch pointer. `git diff --cached --name-status` in that state prints one
# "D" row per path the NEW HEAD carries that the (stale) index does not --
# by definition, a "D" row only exists for a path present in HEAD (that is
# exactly what `--cached`/`--staged` means: HEAD vs index, i.e. what
# committing the index right now would change), so any D row at all, while
# parked on the integration branch itself, IS the stale-checkout signature —
# the next `git add -A && git commit` here would re-delete every one of
# those files, silently reverting real history. Read-only: this function
# only ever inspects, never mutates, and `orchid checkout HEAD -- .` (the
# fix it recommends) is left to the operator, never run here.
orchid_stale_checkout() {
  local repo="$1" integ cur
  integ="$(config_get "$repo" integration_branch orchid/integration)"
  cur="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$cur" ] && [ "$cur" = "$integ" ] || return 1
  git -C "$repo" diff --cached --name-status 2>/dev/null | awk '$1 == "D" { found=1 } END { exit !found }'
}

# orchid_stale_checkout_remedy -- the ONE copy of what an operator is told to
# do about the state above. `orchid doctor` and `orchid status` both print it,
# and until dogfood finding F31 they printed it as two separately maintained
# string literals; what that duplication bought was the same WRONG text in two
# places, which is why it lives here now.
#
# What was wrong with it. The printed recovery was `git checkout HEAD -- .
# ':(exclude).orchid'` and nothing else, and an operator who ran exactly that,
# character for character, watched the warning survive it. The exclusion is the
# reason, and it is not a defect in the exclusion: `git checkout` never touches
# an index entry for a path its own pathspec excluded, so every `.orchid/` path
# the new HEAD carries and the stale index does not is left exactly as it was --
# staged for deletion. Those staged deletions ARE the signature
# orchid_stale_checkout reads. The remedy cleared the half it was allowed to
# reach and left the half the check looks at, so the check went on firing, and
# the operator was left with a warning that survived its own documented fix.
#
# So the remedy is BOTH halves:
#
#     git checkout HEAD -- . ':(exclude).orchid'   # the working tree, minus run state
#     git reset                                    # the index, all of it
#
# THE ORDER IS PART OF IT, for the operator who runs the first command and then
# stops -- reads a message, gets interrupted, loses the shell. Both orders end
# in the same place; the two intermediate states are not equally safe. Checkout
# first leaves fresh code under a warning that is still displayed: honest, and
# the remaining step is still in front of them. Reset first leaves PRE-MERGE
# code under a checkout that now looks healthy to every check there is -- L018
# (a merged fix inert for two further rounds because the launcher kept
# executing the stale tree) with its one alarm switched off. So: reset LAST.
#
# And the exclusion is narrower than it reads, which is the other half of F31
# and cost that operator a file. `:(exclude).orchid` protects uncommitted
# DURABLE RUN STATE. It protects nothing else -- the checkout half restores
# every OTHER tracked path from HEAD, so an uncommitted edit anywhere outside
# `.orchid/` is overwritten, with no reflog to recover it from, and
# `requirements.md` being revised at the repository root is precisely the file
# an operator has an uncommitted edit to while driving a run. Naming that here
# is the difference between a remedy that can be run and one that can be run
# safely.
#
# A single-quoted heredoc, so the pathspec's own quoting reaches the operator
# verbatim and nothing in the prose is ever evaluated. First line is the
# headline (the caller prefixes its own `FAIL:`/`WARNING:`); the rest is the
# argument for why it is two commands and what each one costs.
orchid_stale_checkout_remedy() {
  cat <<'ORCHID_STALE_CHECKOUT_REMEDY'
integration checkout is stale — refresh with "git checkout HEAD -- . ':(exclude).orchid' && git reset" before committing anything here
  BOTH commands, in that order: the checkout restores the code this checkout fell behind on, and the bare "git reset" is what CLEARS this warning. A checkout never touches an index entry its own pathspec excluded, so the .orchid/ paths HEAD carries and this stale index does not stay staged for deletion — and those staged deletions are what this check reads. The checkout alone leaves it firing (dogfood finding F31).
  The reset writes no file and deletes no file: it brings the index to HEAD, and the live .orchid/ run state on disk is left exactly as it was. Whatever "git status" still shows under .orchid/ afterwards is this run's own working state — leave it to the run rather than hand-committing it.
  The checkout is the half that can cost you something: ':(exclude).orchid' protects uncommitted durable run state and NOTHING else, so any other uncommitted edit in this checkout — a requirements.md being revised at the repository root is the one this has already cost an operator — is overwritten from HEAD with no reflog to recover it from. Commit or stash those first ("git status --short" names them).
ORCHID_STALE_CHECKOUT_REMEDY
}

# ORCHID_KERNEL_PATHS -- what a run EXECUTES out of $ORCHID_ROOT. Eight
# directories: the verb, the libraries it sources, the runner it hands off to,
# the engine adapter that runner spawns, the role profile and prompt template
# given to that engine. ONE list, because three separate consumers have to
# agree on it or the guard below and the refresh that clears it drift apart
# (lesson L016): orchid_root_stale asks whether this checkout's INDEX still
# matches HEAD for these paths, orchid_kernel_clean asks whether anything local
# would be lost by restoring them, and orchid_refresh_kernel restores exactly
# them. docs/specs/kernel.md quotes the same list a fourth time, in prose, and
# has to be edited with it.
#
# And ONE file, PROTOCOL.md, which is not code and is executed all the same.
# The skills under skills/ carry no procedure of their own: each one tells the
# driving engine to `cat "$ORCHID_ROOT/PROTOCOL.md"` and follow the section it
# names, so the protocol on disk in this checkout IS the instruction stream a
# tick runs. Leaving it out reproduced this guard's own failure class on the
# one file that defines the procedure: a merge that changed only the protocol
# neither refused nor refreshed, every verb kept working, and the run went on
# executing the PRE-MERGE procedure with nothing anywhere saying so -- exactly
# the stale-adapter shape of L018, one layer up. It is restored by the same
# write-then-reset as any other path (a pathspec is a pathspec; nothing in the
# refresh assumes a directory).
#
# What is deliberately NOT here is as load-bearing as what is. `.orchid/`
# above all -- uncommitted durable run state is never inspected, never
# compared and never written by any of the three -- but also `orchid.config`
# (an operator edit awaiting `orchid config commit` is legitimate and
# uncommitted by definition), README/docs other than the protocol itself, and
# test fixtures. None of them changes what the launcher executes, so none of
# them can refuse a command and none of them is ever restored out from under
# an operator. requirements.md is the sharpest of those exclusions: it is an
# operator's working document, edited uncommitted for long stretches, and
# dogfood finding F31 is what happens when a refresh reaches one path further
# than it must.
#
# `orchid.config`'s exclusion from THIS list is not the same statement as "no
# code ever writes it" (T007). It is READ by every verb -- `merge_gate` lives
# in it -- so a self-hosted merge that lands a config change leaves this
# checkout resolving pre-merge values, and orchid_refresh_config below exists
# for exactly that. What keeps the exclusion honest is its precondition: that
# function writes only where the file is byte-equal to HEAD in both the tree
# and the index, so an operator's pending edit still refuses it and is still
# reported rather than restored. Membership HERE would mean something this
# file must never mean -- that a pending config edit makes the checkout stale
# and refuses every verb.
ORCHID_KERNEL_PATHS=(bin lib libexec runners plugins roles skills templates PROTOCOL.md)

# _orchid_head_branch_ondisk <dir> -- the short branch name <dir>'s HEAD points
# at, or non-zero when there is none: a detached HEAD, a directory that is not
# a work tree at all, or an admin directory this process cannot read. It reads
# Git's OWN on-disk files and never spawns `git`.
#
# Why not `git -C <dir> symbolic-ref --short -q HEAD`, which is exactly what
# this replaces and answers the identical question. The refusal at the bottom
# of this file runs at SOURCE time -- ahead of every verb's own code, and so
# ahead of lib/trust.sh's unattended gate, which rests on the invariant that
# orchid touches NO repository in ANY way until an acknowledgement for it has
# been found and the Git-version refusal has been cleared. Spawning `git` is
# touching, and a source-time `git` is the FIRST process of the run, so it
# lands in front of the acknowledgement lookup no matter how the gate is
# written. `orchid_root_stale` asks about $ORCHID_ROOT -- orchid's own
# installation, whose code is already executing -- rather than about a target
# repository, but the honest fix is not to argue the distinction from inside
# the process that is already running: it is to not need the subprocess.
# Reading two files answers precisely what was asked, and leaves the one
# remaining `git` below reachable only for a checkout PARKED ON THE
# INTEGRATION BRANCH, i.e. only for $ORCHID_ROOT and never for a repository
# the run was merely pointed at.
#
# Both layouts Git writes are handled, because the live run and the fixtures
# use both. An ordinary checkout has a `.git` DIRECTORY holding HEAD. A linked
# worktree -- `git worktree add`, which is how every task checkout in a run is
# made, and how this guard's own fixtures build the stale root -- has a `.git`
# FILE holding a single `gitdir: <path>` pointer to a per-worktree admin
# directory that carries that worktree's own HEAD; the pointer is resolved
# relative to <dir> when it is not absolute. Anything else (no `.git`, a
# pointer that does not parse, an unreadable or empty HEAD) reports no branch,
# which is the same fail-OPEN answer `symbolic-ref -q` gave for the ordinary
# `brew`/`install.sh` prefix. A HEAD that is not `ref: refs/heads/...` is a
# detached HEAD and likewise reports nothing, exactly as before.
#
# One deliberate difference from the subprocess: git resolves a work tree by
# walking UP from <dir>, this does not. That only matters when $ORCHID_ROOT is
# a plain subdirectory nested inside some UNRELATED repository's work tree, in
# which case the old call reported that outer repository's branch and this
# reports none. Reporting none is the better answer -- the outer repository is
# not the one `orchid merge` advances -- and it is fail-open either way.
_orchid_head_branch_ondisk() {
  local dir="$1" gitdir line=""
  gitdir="$dir/.git"
  if [ -f "$gitdir" ]; then
    [ -r "$gitdir" ] || return 1
    # `read` reports failure at an EOF it reached without a newline, having
    # nonetheless filled $line. Both files here normally end in one, but a
    # hand-repaired pointer or HEAD may not, and treating that as "no branch"
    # would silently disarm the guard -- so the status is only fatal when
    # nothing was read.
    read -r line 2>/dev/null < "$gitdir" || [ -n "$line" ] || return 1
    case "$line" in
      'gitdir: '*) gitdir="${line#gitdir: }" ;;
      *) return 1 ;;
    esac
    case "$gitdir" in /*) ;; *) gitdir="$dir/$gitdir" ;; esac
  fi
  [ -d "$gitdir" ] && [ -r "$gitdir/HEAD" ] || return 1
  line=""
  read -r line 2>/dev/null < "$gitdir/HEAD" || [ -n "$line" ] || return 1
  case "$line" in
    'ref: refs/heads/'*) printf '%s\n' "${line#ref: refs/heads/}" ;;
    *) return 1 ;;
  esac
}

# orchid_root_stale [root] -- lesson L018, and the counterpart to orchid_
# stale_checkout above. That helper asks whether the checkout holding a run's
# DURABLE STATE has fallen behind its branch; this one asks whether the
# checkout holding orchid's own CODE has.
#
# bin/orchid resolves $ORCHID_ROOT from its own location, so every verb, every
# lib/*.sh, every runners/* and every plugins/engines/*/run it executes is
# read from that checkout's WORKING TREE -- never from the branch head.
# `orchid merge` advances the integration branch with `update-ref` alone, and
# deliberately so: it must not reach into any other checkout's index or
# working tree. The consequence is that a checkout parked on that branch goes
# on running PRE-MERGE code indefinitely while every merge reports success.
# Observed live on 2026-08-06: a merged review-adapter fix stayed inert for
# two further rounds, reviewer findings[] empty the whole time, because the
# launcher kept executing the pre-merge adapter from a stale working tree.
#
# TWO conditions, and both are load-bearing:
#
#   1. This checkout is PARKED ON THE INTEGRATION BRANCH -- the same gate
#      orchid_stale_checkout uses. Development happens on `main`, on a feature
#      branch, in a task worktree; none of them is the branch a run merges
#      onto, so none of them can be advanced by `orchid merge` behind anyone's
#      back and none of them is ever asked about here, however dirty it is.
#
#      It is also, deliberately, the CHEAP condition and therefore the first
#      one: it is answered from Git's on-disk HEAD alone (_orchid_head_branch_
#      ondisk above), so NO `git` runs for a root that is not parked on that
#      branch -- which is every root in an ordinary run. That is not an
#      optimisation, it is the ordering this check owes the unattended-trust
#      gate; the helper's own comment has the argument.
#
#      Said exactly, because "costs nothing" is the sort of claim that rots:
#      a root with no branch at all (an install prefix, a detached HEAD)
#      leaves this function having spawned nothing whatever, while a root that
#      HAS a branch pays config_get's own text-processing subshells -- tr,
#      sed, grep, tail, cut -- to learn the integration branch's name before
#      the comparison on the line below can be made. Those read
#      $ORCHID_ROOT/orchid.config and $HOME/.orchid/config, which are files,
#      not repositories, and that is the distinction the ordering actually
#      turns on: what the unattended gate forbids ahead of an acknowledgement
#      is TOUCHING A REPOSITORY, and `git` is the only thing here that would.
#      tests/test_stale_root.sh check 11 fences precisely that, and fences
#      nothing about subshell count.
#   2. This checkout's INDEX does not match HEAD for the kernel paths.
#
#      THE INDEX, not the working tree, and that is the difference between a
#      usable tool and one that refuses to run in the checkout it is developed
#      in. The earlier version compared the WORKING TREE to HEAD, which made
#      every uncommitted kernel edit on this branch a refusal -- and orchid is
#      developed in a checkout of its own integration branch, so "edit
#      lib/common.sh, run orchid" was exactly the thing it refused. Exempting
#      every OTHER branch does not save it: the one checkout the exemption
#      cannot reach is the self-hosted one, which is the only checkout this
#      guard ever fires in at all.
#
#      The index is also where the hazard actually leaves its mark, so this is
#      not a trade of safety for convenience. `git update-ref` moves the
#      branch and touches neither the index nor the working tree, so a
#      checkout parked on the advanced branch is left with an index still
#      describing the commit the branch moved OFF. That IS "this checkout fell
#      behind", stated in the only place the fall is recorded. An operator
#      editing kernel files leaves the index alone, so ordinary dirty
#      development is silent here.
#
#      What that gives up, said plainly rather than discovered later: a
#      checkout that fell behind and then had `git reset` run in it -- index
#      resynced to HEAD, working tree still carrying the old code -- is not
#      detected. From here it is byte-for-byte an operator with uncommitted
#      edits, and refusing on that shape is the defect above. Nothing else
#      covers it either: orchid_stale_checkout keys on a staged DELETION,
#      which a reset has just cleared. It is a state only a deliberate `git
#      reset` in the integration checkout produces, and the cost of catching
#      it is refusing every ordinary edit, which is not a trade worth making.
#
# Fails OPEN on anything it cannot establish: no git on PATH, an $ORCHID_ROOT
# that is not a work tree at all (the ordinary `brew`/`install.sh` prefix,
# where there is no branch and no ref for anyone to advance), or a detached
# HEAD. A guard that refused on "cannot tell" would brick installs that were
# never at risk in the first place.
#
# L018 offered three structural remedies and this is the first of them. Why
# not the other two:
#
#   * Resolve $ORCHID_ROOT from HEAD instead of the working tree. It would
#     make the tool undevelopable -- an edit to lib/*.sh would have no effect
#     until committed, so every iteration becomes a commit -- and it does not
#     remove the hazard so much as invert it: `orchid` would then silently
#     ignore the very working tree the operator is reading. It also needs a
#     materialized copy of HEAD somewhere on disk to exec from (git cannot
#     exec a blob), which is a second, cache-shaped source of staleness.
#   * Have `orchid merge` refresh the other checkouts of the branch it
#     advanced. It cannot know what those checkouts are (`git worktree list`
#     is not the whole answer -- clones exist), and writing into a checkout
#     the merging process does not own is the r-001 journal-loss incident's
#     exact shape: the refresh that would have to run there is the one that
#     clobbers uncommitted durable state. Refusing instead puts the decision
#     in front of the operator standing in the affected checkout, who is the
#     only party who knows what is uncommitted in it.
#
# What it publishes are OBSERVATIONS, never a verdict on what caused them,
# and that distinction is the whole of this round's rework. TWO different
# things produce an index that does not match HEAD, they are byte-for-byte
# identical from here, and every attempt to tell them apart has instead
# produced a confident wrong answer:
#
#   * `orchid merge` advanced the branch with `update-ref`, leaving the index
#     describing the commit the branch moved off. Restoring costs nothing.
#   * Someone ran `git add` on a kernel edit here. The index carries bytes
#     that exist nowhere else, and restoring destroys them.
#
# `git diff --cached HEAD` reports both as an index that differs from HEAD.
# Name-status does not separate them either (a merge that only modified files
# gives M rows; a staged deletion gives D rows). `update-ref` leaves no
# fingerprint distinguishing an advance made from this checkout's own process
# from one made elsewhere. The reflog is not a proof either: it is optional,
# expirable, and reading a cause out of it is the same guess wearing a
# citation.
#
# So this function reports what it saw and the refusal below prints no
# command that could discard work. That is a deliberate trade of helpfulness
# for safety, made twice over: an earlier round diagnosed a HAND-EDITED kernel
# as "behind" and prescribed `git checkout HEAD -- <kernel paths>`, and the
# round after that did the identical thing to a STAGED-ONLY edit. Dogfood
# finding F31 is that same shape costing a requirements.md edit. A refusal
# that is merely unhelpful is one the operator recovers from in a minute; a
# confident wrong diagnosis carrying a lossy remedy is not recoverable at all.
#
# The unstaged half is published alongside it as CONTEXT, not as a cause --
# it never contributes to the decision to refuse (see condition 2 above), and
# it is reported only so the operator reading the refusal knows the whole
# state of the checkout before choosing what to do. It fails CLOSED to the
# literal `?`, spelled out rather than printed raw by the refusal.
#
# Read-only: it only ever inspects, exactly like orchid_stale_checkout. The
# branch it found is published so the refusal below can name it.
orchid_root_stale() {
  local root="${1:-${ORCHID_ROOT:-}}" integ cur staged unstaged
  # config_get reads "$HOME/.orchid/config" unguarded, and this is the one
  # caller that runs at SOURCE time -- ahead of any verb's own environment
  # setup, and in a headless context (launchd, cron) where HOME can genuinely
  # be unset. A `local` shadow is dynamically scoped, so config_get below sees
  # it and nothing outside this function does: an unset HOME becomes "no user
  # config layer" here rather than an `unbound variable` abort in every verb.
  local HOME="${HOME:-}"
  [ -n "$root" ] || return 1
  # Condition 1 FIRST, and answered WITHOUT a subprocess: see _orchid_head_
  # branch_ondisk above for why this may not be `git symbolic-ref`. Every root
  # that is not parked on the integration branch -- an install prefix, a
  # development checkout, a task worktree, every root in an ordinary run --
  # leaves this function having executed nothing but file reads.
  cur="$(_orchid_head_branch_ondisk "$root")" || return 1
  [ -n "$cur" ] || return 1
  integ="$(config_get "$root" integration_branch orchid/integration)"
  [ "$cur" = "$integ" ] || return 1
  # ORCHID_KERNEL_PATHS, never a literal list repeated here: see its own
  # comment above for what is deliberately outside it, and orchid_refresh_
  # kernel below for the restore that has to agree with it path for path. A
  # `git diff` pathspec that matches nothing is not an error, so a root
  # missing one of those directories is simply judged on the ones it has.
  #
  # Fails OPEN (`|| true`, an empty answer, no refusal) for the same reason
  # the branch half does: a `git` that cannot answer must not brick an
  # installation that was never at risk.
  staged="$(git -C "$root" diff --cached --name-only HEAD -- \
    "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null || true)"
  [ -n "$staged" ] || return 1
  # Only now, with a refusal already certain, is the context worth a second
  # subprocess -- so this never runs for a root that was going to be allowed.
  unstaged="$(git -C "$root" diff --name-only -- \
    "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null || echo '?')"
  ORCHID_ROOT_STALE_BRANCH="$cur"
  ORCHID_ROOT_STALE_INDEX="$staged"
  ORCHID_ROOT_STALE_UNSTAGED="$unstaged"
}

# _orchid_kernel_refresh_inflight <root> -- true while an `orchid merge`
# running out of <root> is inside its own advance-then-refresh window.
#
# The window is real and unavoidable. `orchid merge` advances the integration
# branch (`update-ref`) and then restores this checkout's kernel paths to the
# new HEAD; between those two steps the index legitimately does not match
# HEAD, which is precisely what orchid_root_stale reports. The merging process
# shields its OWN children with ORCHID_ALLOW_STALE_ROOT=1; nothing reaches any
# other verb started from this root in that window -- an operator's `orchid
# status`, a heartbeat, a notify hook.
#
# WHAT THIS DOES NOT DO, and the whole of this round's rework: it does not let
# those verbs RUN. An earlier version stood the refusal down while the window
# was open, which meant a concurrent verb executed the pre-merge working tree
# for the duration -- the exact failure L018 names, reintroduced by the
# tolerance built to make the fix for L018 comfortable. The window is short,
# but "short" is not a property the executed code has: an `orchid tick` that
# starts in it runs a whole pass of pre-merge kernel, and the stale-adapter
# incident this task exists for is what that costs.
#
# Waiting is not the remedy either, and the reason is structural rather than a
# matter of taste. By the time this line is reached, the process has ALREADY
# read this file -- and its verb, and every lib it sourced -- off the
# pre-merge tree. Sleeping until the restore lands would leave it executing
# the old bytes it is already holding, with only the illusion of currency. The
# one correct action for a process that finds itself holding pre-merge code is
# to stop, so that the NEXT invocation reads the refreshed tree from its first
# byte.
#
# So this predicate no longer decides WHETHER to refuse. It decides WHICH
# refusal is printed, and that is worth a file because the two are not the
# same message at all: "a repair is in flight, nothing ran, retry in a moment"
# sends the operator back to their prompt, while the full report sends them to
# `git diff --cached` and a decision about their own uncommitted bytes. Told
# the wrong one, an operator either goes diagnosing a condition that repaired
# itself while they read, or retries forever against a merge that died. The
# refusal is unconditional; only its accuracy depends on this file.
#
# IDENTITY, not a bare PID, and that is the second half of the rework. The
# marker records the same triple lock_acquire writes into owner.json -- pid,
# `_pid_start` and hostname -- and all three must still match for the marker
# to be believed. A bare PID cannot survive its own writer: a merge SIGKILLed
# mid-window leaves the file behind (an EXIT trap does not run on -9), the
# kernel eventually hands that number to an unrelated process, and from then
# on the marker names something alive. Under the old tolerance that silently
# disarmed the refusal outright; even now it would mean an operator told
# "retry in a moment" about a merge that died hours ago. A start time pins the
# process the number was borrowed from, and the hostname keeps a runtime
# directory that turns out to be shared from letting one host's PID answer
# for another's -- the identical argument lock_acquire makes, and deliberately
# the identical fields, so there is one notion of "that process is still
# there" in this file rather than two that can drift.
#
# LIVENESS being the predicate is also what means nothing has to reap this
# file. A marker and a separate garbage collector that disagreed about when it
# had expired would be two predicates, and the gap between them is where a
# stale marker starts speaking for a process that no longer exists. Every
# failure here -- dead PID, recycled PID, foreign host, truncated file, no
# file -- falls through to the full report, which is the answer that is never
# unsafe. `.orchid/runtime/` is local-only and ephemeral by contract, so a
# leftover marker is inert litter, not state.
#
# "Falls through to the full report" is only worth anything because the RESTORE
# leaves something to report. A merge killed mid-restore is exactly the case
# this predicate cannot cover -- its writer is gone, so the marker stops being
# believed at the instant the repair stops happening -- and what keeps that
# from becoming silence is orchid_refresh_kernel's ordering: it never lets a
# path's index entry match HEAD before that path's working tree does, so a
# half-done restore is still a stale index and still a refusal. Were it the
# other way round, this file would be the only thing standing between a killed
# merge and a run executing the pre-merge tree, and it is expressly not built
# to be that.
#
# It is not a bypass, and now cannot become one: an operator (or a hostile
# repository) who writes this file changes the TEXT of a refusal and nothing
# else. ORCHID_ALLOW_STALE_ROOT=1 remains the one documented way to actually
# run.
#
# Cost: two builtin file reads, `kill -0`, and -- only once those have passed
# -- `hostname` and the `ps` inside _pid_start. It is evaluated only after
# orchid_root_stale has already said yes, i.e. only when a refusal is certain
# and a `git` has already run, and it reads only under $ORCHID_ROOT -- orchid's
# own installation, never a repository a run was merely pointed at -- so it
# adds nothing in front of the unattended-trust gate. It deliberately does not
# call orchid_runtime, which would `mkdir` on a read-only question.
_orchid_kernel_refresh_inflight() {
  local root="$1" marker pid="" pstart="" host=""
  [ -n "$root" ] || return 1
  marker="$root/.orchid/runtime/kernel-refresh"
  [ -r "$marker" ] || return 1
  # Three lines, one open. A marker truncated to fewer -- or written by a
  # version of orchid that published only a PID -- leaves the later fields
  # empty, and every field is required below, so the old one-line format reads
  # as "cannot establish" rather than as a match. `read` reports failure at an
  # EOF it reached without a newline having nonetheless filled the variable,
  # so the group's status is discarded and content is what gets tested.
  { read -r pid; read -r pstart; read -r host; } < "$marker" 2>/dev/null || true
  # A non-numeric or empty PID is a truncated or hand-mangled marker: believe
  # nothing, print the full report. Same direction as a dead PID.
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$pstart" ] || return 1
  [ -n "$host" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [ "$host" = "$(hostname 2>/dev/null || true)" ] || return 1
  # The one that decides it, and last because the two checks above it are
  # cheaper (only this and the `hostname` on the line before spawn anything):
  # the PID is alive AND it is the same process that wrote the marker, not a
  # later tenant of the number. An unanswerable `ps` yields an empty string
  # here, which does not equal a recorded start, so "cannot tell" reports
  # not-in-flight.
  [ "$(_pid_start "$pid")" = "$pstart" ]
}

# orchid_kernel_refresh_open <root> / _close <root> -- the writer half of the
# marker above, called by libexec/orchid-merge around its advance-and-refresh.
#
# `_open` is best-effort: a runtime directory that cannot be written costs the
# accuracy of one refusal's wording, never the merge. It declines outright
# rather than publish an identity it cannot prove -- an empty `_pid_start`
# (a container with no `ps`) or an empty hostname would write a marker whose
# fields the reader must reject anyway, and writing one is strictly worse than
# writing none, since the file outlives this process and the next reader has
# no way to know it was born unusable.
#
# Written through atomic_write, so a reader can never catch a half-written
# marker: `>` truncates in place and would give a concurrent verb an empty
# file, which is merely the safe answer rather than the true one.
orchid_kernel_refresh_open() {
  local rt start host
  start="$(_pid_start "$$")"
  [ -n "$start" ] || return 1
  host="$(hostname 2>/dev/null || true)"
  [ -n "$host" ] || return 1
  rt="$(orchid_runtime "$1" 2>/dev/null)" || return 1
  printf '%s\n%s\n%s\n' "$$" "$start" "$host" \
    | atomic_write "$rt/kernel-refresh" 2>/dev/null || return 1
}
orchid_kernel_refresh_close() {
  rm -f "$1/.orchid/runtime/kernel-refresh" 2>/dev/null || true
}

# orchid_kernel_clean <root> -- true when <root>'s kernel paths match HEAD in
# BOTH the working tree and the index, i.e. when restoring them to HEAD would
# destroy nothing an operator has not committed. It is the PRECONDITION
# orchid_refresh_kernel is only ever called under, and it must be evaluated
# BEFORE the ref that HEAD follows is advanced -- afterwards every path looks
# drifted and the two cases (this checkout fell behind / someone is editing
# the kernel here) are no longer distinguishable.
#
# Both halves are needed. `diff HEAD` compares the WORKING TREE to HEAD and so
# misses a change that was staged and then reverted on disk; `diff --cached`
# compares the INDEX to HEAD and catches exactly that. Untracked files are not
# compared at all, so a local scratch file under plugins/ does not veto a
# refresh -- and is not harmed by one either, because orchid_refresh_kernel
# declines any path it would have to overwrite an untracked file to restore.
# That has to be enforced there rather than here: whether an untracked file
# collides with the branch is not knowable until after the ref has moved,
# which is precisely when this precondition is no longer askable.
#
# Fails CLOSED, unlike orchid_root_stale: a git invocation that cannot answer
# yields the literal `?`, which is not empty, so "cannot tell" reports dirty
# and the refresh is declined. The cost of declining is a refusal the operator
# clears by hand; the cost of a wrong "clean" is uncommitted work destroyed.
orchid_kernel_clean() {
  local root="$1"
  [ -z "$(git -C "$root" diff --name-only HEAD -- \
    "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null || echo '?')" ] || return 1
  [ -z "$(git -C "$root" diff --cached --name-only HEAD -- \
    "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null || echo '?')" ] || return 1
}

# orchid_refresh_kernel <root> [<base>] -- bring <root>'s kernel paths to HEAD,
# so a checkout that fell behind its own branch runs the code that branch now
# carries. The ONLY writer in this family; every other helper here inspects.
#
# <base> is the commit <root>'s HEAD was on at the moment orchid_kernel_clean
# passed, i.e. before the ref advance. Callers that know it SHOULD pass it: it
# is the snapshot every per-write safety check below is asked against, and
# _orchid_kernel_writable says why a snapshot rather than the live index is
# what that check needs. Omitting it falls back to the index, which differs
# only when something stages a kernel edit inside the window.
#
# Callers MUST have established orchid_kernel_clean first (see above). Under
# that precondition every path this touches was, moments earlier, byte-equal
# to the commit HEAD has just moved off, so nothing uncommitted exists for it
# to destroy. Nothing outside ORCHID_KERNEL_PATHS is read or written at all --
# `.orchid/` run state and a pending `orchid.config` edit are not merely
# preserved, they are never named. (orchid_refresh_config is a separate
# function, asked a separate question by the same caller, and reaches
# `orchid.config` only under its own precondition; this one still names
# nothing outside the list.)
#
# THE ORDER IS THE SAFETY PROPERTY, and it is why this is not three lines of
# `git`. orchid_root_stale reads the INDEX, so the index is the thing that
# makes this checkout look current to every other process on the machine. It
# is therefore written LAST, one path at a time, and only after that path's
# WORKING TREE already carries HEAD's bytes:
#
#   working tree first (installed by rename), verified, index last.
#
# Nothing that makes the guard look satisfied may happen before the thing the
# guard stands for is actually true. A refresh that dies at any instant --
# SIGKILL, a full disk, a machine going down -- therefore leaves every path it
# has not finished with an index entry still describing the commit the branch
# moved off, which is exactly the state the refusal fires on. An interrupted
# refresh REFUSES; it never permits.
#
# The version this replaces reset the index first and checked the file out
# second, and an interruption between those two left a CURRENT INDEX over a
# PRE-MERGE WORKING TREE -- which the guard reads as healthy and lets the run
# execute. That is L018 reproduced inside the fix for L018, reachable by
# nothing more exotic than ^C, and with no marker to save it: the in-flight
# marker below is believed only while its writer is alive, so the merge dying
# is precisely the case it cannot cover.
#
# Why not `git checkout HEAD -- <path>`, which writes the working tree and the
# index in one command. Two reasons, and the first decides it: the order in
# which it commits those two is an INTERNAL detail of git rather than a
# documented guarantee, so the property above would hold only for as long as
# another project's implementation happened not to change, and could not be
# checked by reading this file. The second is the one earlier rounds hit: it
# restores modified and missing files, but does NOT remove a file the new HEAD
# no longer carries. That path stays in the index, `git diff HEAD` keeps
# reporting it, and the refusal the refresh was supposed to clear survives the
# remedy -- an operator following the instruction verbatim and watching it not
# work. Both shapes are handled below in the one order: the tree first, then
# `git reset` to bring the index to HEAD, which is also what DROPS the entry
# for a path HEAD no longer has.
#
# THE PRECONDITION IS RE-ASKED PER WRITE, and that is the second safety
# property. orchid_kernel_clean is evaluated by the caller BEFORE the ref
# advance; the writes below happen after it, and an editor saving a kernel file
# in between would have its bytes silently overwritten by a refresh that had
# already been told the tree was clean. Passing a check once is not the
# requirement -- not losing an edit is -- so every write here is preceded,
# immediately, by _orchid_kernel_writable on the one path it is about to touch.
# A path whose file has changed under the check is DECLINED, and the refusal
# the operator then meets is the correct outcome: their bytes are still on
# disk. That check is asked against <base> rather than against the index for
# the reason spelled out there -- `git add` in the window moves the index and
# the file together, so the index cannot serve as the record of what was here
# when the precondition passed. What remains is the rename itself, which no
# check can get inside; the window this closes is the whole advance-and-walk,
# and what is left is one `mv`.
#
# Returns non-zero if any path could not be restored, leaving the refusal in
# place for the operator rather than reporting a refresh that did not happen.
orchid_refresh_kernel() {
  local root="$1" base="${2:-}" p q seen rc=0 top top_phys root_phys
  # `kernel_drift` rather than the obvious `drift`, and the prefix is load-
  # bearing rather than taste. ci-local lints every shell file in ONE
  # `shellcheck` invocation, which makes each sourced library visible to the
  # files that source it -- so an array declared here is an array in the
  # linter's model of every verb in libexec/, `local` or not. ShellCheck does
  # not model bash's function scoping across a `source` boundary. Plain
  # `drift` collided with the scalar of that name in libexec/orchid-plugins'
  # `plugins drift` arm and charged THAT file three SC2178s and an SC2128 for
  # a line it does not contain and an author who never touched it. Names
  # introduced in this library are effectively global to the gate; keep them
  # specific enough not to land on someone else's local.
  local -a kernel_drift=()
  # `git diff --name-only` prints paths relative to the REPOSITORY ROOT while
  # the pathspecs below are read relative to `-C "$root"`. Those agree only
  # when <root> IS the repository root, so that is required rather than
  # assumed -- a root that is some repository's subdirectory would otherwise
  # have each drifted path re-rooted one level down and quietly miss. Both
  # sides must resolve to a non-empty physical path: a failed `cd` on each
  # would compare equal as empty strings.
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || return 1
  top_phys="$(cd "$top" 2>/dev/null && pwd -P || true)"
  root_phys="$(cd "$root" 2>/dev/null && pwd -P || true)"
  [ -n "$top_phys" ] || return 1
  [ "$top_phys" = "$root_phys" ] || return 1
  # BOTH sides, unioned, because the two halves of a path's restore land at
  # different moments and a refresh has to be able to finish one that was
  # interrupted between them. `diff HEAD` names what the WORKING TREE still
  # gets wrong; `diff --cached HEAD` names what the INDEX does -- and a path
  # whose file was already written by a killed refresh appears only in the
  # second. Listing the working tree alone would make this function a no-op
  # against precisely the state it exists to repair, leaving a refusal that
  # nothing but an operator's own `git reset` could clear.
  #
  # The index half is also what the guard itself reads, so this is the set of
  # paths that have to be dealt with for the refusal to lift -- stated once,
  # here, rather than inferred from a comparison that answers a neighbouring
  # question.
  #
  # `-z` and a NUL-delimited read, never the newline-separated default. Without
  # it `git diff --name-only` C-QUOTES any path holding a space, a quote, a
  # backslash or a non-ASCII byte -- it prints `"roles/my role.md"`, quotes and
  # all, or `"templates/caf\303\251.md"` -- and every consumer below would then
  # be handed a name no file has: `cat-file -e HEAD:<that>` misses, the restore
  # declines, and the refresh reports failure over a path it never looked at.
  # `-z` disables the quoting entirely and terminates each name with a NUL, the
  # one byte a path cannot contain, so the walk is exact for every name git can
  # store. It also rules out `$(...)`, which strips NULs, hence the redirect.
  #
  # A path in both halves is deduped here rather than by `sort -u`, which has
  # no portable NUL-delimited spelling; the list is at most a few dozen entries
  # long, so the linear scan costs nothing and spawns nothing.
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    seen=0
    if [ "${#kernel_drift[@]}" -gt 0 ]; then
      for q in "${kernel_drift[@]}"; do
        [ "$q" = "$p" ] || continue
        seen=1
        break
      done
    fi
    [ "$seen" -eq 1 ] || kernel_drift+=("$p")
  done < <(git -C "$root" diff -z --name-only HEAD -- \
             "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null
           git -C "$root" diff -z --cached --name-only HEAD -- \
             "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null)
  # No early return on an empty list, and that is the fail-CLOSED half a
  # process substitution cannot carry in its exit status: a `git` that could
  # not answer produces no output, which is indistinguishable here from "no
  # drift". Falling through to the verification at the bottom -- which fails
  # closed on that same broken `git` -- is what keeps "it printed nothing" from
  # being reported as "refreshed".
  if [ "${#kernel_drift[@]}" -gt 0 ]; then
    for p in "${kernel_drift[@]}"; do
      _orchid_refresh_one_path "$root" "$p" "$base" || rc=1
    done
  fi
  # Success has to mean the thing its caller announces. A per-path failure
  # already yields non-zero above; this catches the rest -- a drift list that
  # did not name everything that drifted, anything that changed underneath the
  # loop -- and fails CLOSED on a `git` that cannot answer, because the cost of
  # a wrong "refreshed" is a run executing a tree nobody has looked at.
  #
  # BOTH halves, and for the caller's sake rather than this loop's: the working
  # tree is what the next process EXECUTES, the index is what the guard READS,
  # and a refresh that leaves either one behind has cleared nothing whatever
  # its per-path steps returned.
  if [ "$rc" -eq 0 ] \
     && { ! git -C "$root" diff --quiet HEAD -- \
            "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null \
          || ! git -C "$root" diff --quiet --cached HEAD -- \
            "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null; }; then
    rc=1
  fi
  return "$rc"
}

# _orchid_refresh_one_path <root> <path> [<base>] -- bring ONE path to HEAD:
# its WORKING TREE first, verified, and its index entry only afterwards.
#
# This is the body of the walk above, in a function because there is now a
# SECOND caller (orchid_refresh_config below) and that order is the safety
# property rather than an implementation detail. Two copies of an order are how
# two copies come to disagree, and the copy that drifts is the one that leaves
# a current index over a pre-merge file -- precisely the state the stale-root
# guard reads as healthy and lets a run execute.
#
# The `kernel` in the two helpers it calls names the family, not a restriction:
# both take a path and neither consults ORCHID_KERNEL_PATHS. WHICH paths may be
# written, and on what evidence, is the caller's question; this one answers only
# how.
_orchid_refresh_one_path() {
  local root="$1" p="$2" base="${3:-}"
  if git -C "$root" cat-file -e "HEAD:$p" 2>/dev/null; then
    # _orchid_restore_kernel_file asks _orchid_kernel_writable itself,
    # immediately before its rename, so nothing about this path is decided
    # here at a distance from the write it decides.
    _orchid_restore_kernel_file "$root" "$p" "$base" || return 1
  else
    # HEAD has dropped this path. The FILE goes first here too, and for the
    # same reason: a verb or library still on disk after the branch removed
    # it is pre-merge code that still executes, and an index entry dropped
    # ahead of it would tell the guard otherwise. Nothing is lost so long
    # as these bytes are still the ones the caller's precondition saw, which is
    # exactly what the line below re-establishes at the moment of the
    # removal rather than inheriting from a check made before the advance.
    _orchid_kernel_writable "$root" "$p" "$base" || return 1
    rm -f "$root/$p" || return 1
    [ ! -e "$root/$p" ] || return 1
  fi
  # Only now: this path's working tree matches HEAD, so the index may say so.
  git -C "$root" reset -q HEAD -- "$p" >/dev/null 2>&1 || return 1
}

# orchid_config_committed_clean <root> -- true when <root>/orchid.config holds
# exactly what HEAD carries, in the WORKING TREE and the INDEX both, with no
# untracked file sitting at that path.
#
# `orchid.config` is deliberately NOT in ORCHID_KERNEL_PATHS and must not
# become a member of it: an edit awaiting `orchid config commit` is legitimate
# and uncommitted by definition, so a checkout carrying one may neither be
# refused nor have that edit restored out from under it. What this answers is
# the narrower question `orchid merge` asks before it writes -- is there any
# edit here at all to lose -- so that the committed configuration can be made
# live in the one case where making it live costs nobody anything.
#
# Fails CLOSED, like orchid_kernel_clean and by the same `|| echo '?'`: a git
# that cannot answer reports an edit, so "cannot tell" keeps the operator's
# file and the caller says so instead of overwriting it.
#
# `--others` WITHOUT `--exclude-standard`, on purpose. An ignored orchid.config
# is still somebody's file; the cost of treating it as one is a warning nobody
# needed, and the cost of the other reading is their only copy.
#
# THAT CHOICE BINDS THE CALLER'S REPORT TOO. A caller that refuses here and
# then describes what it refused over must be able to see the same file: a
# plain `git status --porcelain` is silent about an ignored path, so the one
# case this line was widened to catch would be the one the operator is told
# nothing about. `orchid merge` passes `--ignored` for that reason. Widening
# what counts as an edit and leaving the report where it was is how a
# preserved file becomes an unfindable one.
orchid_config_committed_clean() {
  local root="$1"
  [ -z "$(git -C "$root" diff --name-only HEAD -- orchid.config 2>/dev/null || echo '?')" ] || return 1
  [ -z "$(git -C "$root" diff --cached --name-only HEAD -- orchid.config 2>/dev/null || echo '?')" ] || return 1
  [ -z "$(git -C "$root" ls-files --others -- orchid.config 2>/dev/null || echo '?')" ] || return 1
}

# orchid_refresh_config <root> [<base>] -- make the committed orchid.config the
# LIVE one in <root>: HEAD's bytes into the working tree, then the index, by
# exactly the same write order the kernel refresh uses.
#
# Callers MUST have established orchid_config_committed_clean BEFORE the ref
# advance that made this necessary (see `orchid merge`, which is the only
# caller and asks it beside its own kernel question). Under that precondition
# every byte replaced here is already in the object store. The per-write check
# inside _orchid_refresh_one_path is re-asked against <base> regardless, so an
# operator who saves this file inside the window is DECLINED rather than
# overwritten, and the caller reports a refresh that did not happen as one that
# did not happen.
orchid_refresh_config() {
  local root="$1" base="${2:-}"
  _orchid_refresh_one_path "$root" orchid.config "$base"
}

# _orchid_file_is_commit_blob <root> <rev> <path> -- true when the file on disk
# at <root>/<path> holds exactly the bytes <rev> carries for <path>, whatever
# the index says about either. `git hash-object` applies the same clean filter
# git would, so the comparison is the one git itself would make, and both sides
# fail CLOSED: an unreadable file, a <rev> that does not carry <path>, a <rev>
# that does not resolve at all, or a `git` that cannot answer is "not
# established", never "equal".
_orchid_file_is_commit_blob() {
  local root="$1" rev="$2" p="$3" want got
  want="$(git -C "$root" rev-parse --quiet --verify "$rev:$p" 2>/dev/null || true)"
  [ -n "$want" ] || return 1
  got="$(git -C "$root" hash-object -- "$p" 2>/dev/null || true)"
  [ -n "$got" ] && [ "$got" = "$want" ]
}

# _orchid_file_is_head_blob <root> <path> -- the same question against the
# commit this checkout is parked on right now.
_orchid_file_is_head_blob() {
  _orchid_file_is_commit_blob "$1" HEAD "$2"
}

# _orchid_file_is_index_blob <root> <path> -- the same question against the
# INDEX rather than HEAD: does the file on disk still hold exactly the bytes
# this checkout's index entry names? Fails CLOSED in every direction an answer
# is unavailable, including the two that matter -- a path with no stage-0 entry
# (untracked here, or unmerged) and a `git` that cannot answer -- both of which
# report "not established" rather than "equal".
_orchid_file_is_index_blob() {
  local root="$1" p="$2" want got
  want="$(git -C "$root" rev-parse --quiet --verify ":0:$p" 2>/dev/null || true)"
  [ -n "$want" ] || return 1
  got="$(git -C "$root" hash-object -- "$p" 2>/dev/null || true)"
  [ -n "$got" ] && [ "$got" = "$want" ]
}

# _orchid_kernel_writable <root> <path> [<base>] -- true when putting HEAD's
# bytes at <root>/<path>, or removing it, can destroy nothing. Asked by
# orchid_refresh_kernel immediately before each of its two writes, and it is
# the whole of what stands between a refresh and an operator's uncommitted
# work.
#
# <base> is the commit this checkout's HEAD was on when orchid_kernel_clean
# passed -- for `orchid merge`, the branch sha its CAS names as the expected
# old value. Given it, the question below is asked against a SNAPSHOT, and
# that is what makes the answer trustworthy rather than merely current.
#
# Three states are safe, and nothing else is:
#
#   * NO FILE THERE. Whatever the index or HEAD says, there are no bytes on
#     disk to lose.
#   * THE FILE STILL HOLDS THE BYTES THE PRECONDITION SAW. This is what closes
#     the window the caller's precondition cannot. orchid_kernel_clean
#     established working tree == index == <base> for these paths BEFORE the
#     ref advance, so a file still equal to <base>'s blob has not been edited
#     since. One that is not was written in the window -- an editor saving, a
#     script, a second operator -- and its bytes exist here and nowhere else.
#
#     WHY <base> AND NOT THE INDEX, which holds those same bytes and needs no
#     argument passed for it. Because the index is not a snapshot: `git add` in
#     the window moves it and the file TOGETHER, so an operator who edits and
#     stages a kernel file between the precondition and the write leaves a file
#     that matches its index entry perfectly and is nonetheless the only copy
#     of their work. Read against the index that state is indistinguishable
#     from an untouched checkout and gets overwritten; read against <base> it
#     is exactly what it is. The record has to be one the racing writer cannot
#     also move, and only a commit is that. Callers with no <base> to offer
#     fall back to the index, which is the same answer in every case but that
#     one.
#   * THE FILE ALREADY HOLDS HEAD'S BYTES. Nothing to lose either, and this
#     arm is load-bearing rather than an optimisation: a refresh killed after
#     it wrote a path the branch ADDED, but before that path's index entry
#     landed, leaves an untracked file carrying HEAD's own content. Declining
#     there would leave a refusal that no further refresh could ever clear.
#
# What that adds up to for the case the whole helper exists for: an untracked
# file of the operator's at a name the branch has since added a tracked file
# under matches neither <base> (which does not carry the path) nor HEAD (its
# content is the operator's), so it is DECLINED and survives. That is the
# r-001 journal-loss shape one directory over, and asking the question as
# "would writing here destroy the only copy of something?" rather than as "is
# this path tracked?" is what gets both it and the killed-refresh state right
# at once.
#
# A <base> that does not resolve -- a caller passing something that is not a
# commit -- makes the first arm unanswerable rather than true, so the file
# falls through to the HEAD comparison and an ordinary path is DECLINED. The
# failure mode of a bad argument is a refusal, never a write.
#
# Declining costs a refusal the operator clears by hand, having seen the file.
# Overwriting costs a file only they had a copy of.
_orchid_kernel_writable() {
  local root="$1" p="$2" base="${3:-}"
  [ -e "$root/$p" ] || return 0
  if [ -n "$base" ]; then
    if _orchid_file_is_commit_blob "$root" "$base" "$p"; then return 0; fi
  elif _orchid_file_is_index_blob "$root" "$p"; then
    return 0
  fi
  _orchid_file_is_head_blob "$root" "$p"
}

# _orchid_restore_kernel_file <root> <path> [<base>] -- put HEAD's bytes for
# <path> into <root>'s WORKING TREE, touching the index not at all. <path>
# exists in HEAD; the caller has established that. What the caller may NOT
# establish on this function's behalf is that writing there is safe:
# _orchid_kernel_writable is asked here, on the line above the rename, because
# a precondition checked before the ref advance cannot speak for a file saved
# since. <base> is passed straight through to it and means what it means
# there.
#
# Written from the blob rather than checked out because the index must not move
# yet (see the order in orchid_refresh_kernel above), and installed with a
# RENAME so the file some concurrently-executing verb may be reading is
# replaced whole: no instant exists in which a kernel file on disk holds half
# of each version.
#
# The mode comes from HEAD's tree entry, because a rename brings the temporary
# file's own mode with it -- and it is applied with `chmod +rw` / `+x` rather
# than a literal 644/755 so that the operator's umask is respected exactly as
# `git checkout` would respect it (symbolic modes with no `who` are masked by
# it; numeric ones are not). Restoring the mode is what makes a newly merged
# libexec verb executable rather than a file bin/orchid reports as an unknown
# command. Anything that is not an ordinary file in HEAD -- a symlink, a
# submodule -- is DECLINED rather than approximated, and the caller turns that
# into a refusal an operator resolves.
#
# The last line is a verification, and it is not ceremony: the guard's promise
# is that the index only ever says "current" over a working tree that IS
# current, and this is where that becomes a checked fact instead of an
# assumption -- the same question _orchid_file_is_head_blob answers above the
# write, asked again below it. It cannot be `git diff HEAD -- <path>`: that
# reads the INDEX for what exists, so a path the branch ADDED -- no index entry
# here yet -- reports as deleted however faithfully the working tree now
# carries it.
_orchid_restore_kernel_file() {
  local root="$1" p="$2" base="${3:-}" entry mode want dir tmp rc=0
  entry="$(git -C "$root" ls-tree -r HEAD -- "$p" 2>/dev/null || true)"
  [ -n "$entry" ] || return 1
  # "<mode> SP <type> SP <object> TAB <path>" -- the default IFS splits on both
  # the spaces and the tab, and the path is deliberately discarded: it is the
  # one field git may quote and escape.
  read -r mode _ want _ <<< "$entry"
  case "$mode" in 100644|100755) ;; *) return 1 ;; esac
  [ -n "$want" ] || return 1
  dir="$root/$p"; dir="${dir%/*}"
  mkdir -p "$dir" 2>/dev/null || return 1
  # Beside the destination, so installing it is a rename WITHIN one filesystem
  # and therefore atomic. Dot-prefixed and named for what it is: one left
  # behind by a killed refresh is untracked, is not a name bin/orchid can
  # dispatch as a verb, and `git clean` clears it.
  tmp="$(mktemp "$dir/.orchid-refresh.XXXXXX" 2>/dev/null)" || return 1
  git -C "$root" cat-file blob "$want" > "$tmp" 2>/dev/null || rc=1
  [ "$rc" -ne 0 ] || chmod +rw "$tmp" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ] && [ "$mode" = 100755 ]; then
    chmod +x "$tmp" 2>/dev/null || rc=1
  fi
  # THE LAST THING BEFORE THE WRITE, and deliberately after the blob, the mode
  # and the temporary file are already in hand: everything above this line is
  # preparation that touches nothing at the destination, so putting the check
  # here leaves the `mv` on the next line as the entire remaining window. The
  # caller's orchid_kernel_clean was asked before the ref advance and cannot
  # speak for what happened since -- an editor saving this very file while the
  # merge walked its drift list would otherwise be overwritten by a refresh
  # that had been told, truthfully but no longer accurately, that the tree was
  # clean. Declining leaves the operator's bytes on disk and the stale-root
  # refusal standing, which is the outcome they can act on.
  if [ "$rc" -eq 0 ] && ! _orchid_kernel_writable "$root" "$p" "$base"; then rc=1; fi
  [ "$rc" -ne 0 ] || mv -f "$tmp" "$root/$p" 2>/dev/null || rc=1
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  _orchid_file_is_head_blob "$root" "$p"
}

# _ocd_cleanup_wt <wt> <repo> -- removes a temp detached worktree (used by
# orchid_commit_durable below). A standalone function, not a closure, taking
# both paths as explicit STRING ARGUMENTS baked into the trap command at
# registration time (see orchid_commit_durable) rather than referencing a
# variable by name -- a `local` variable inside orchid_commit_durable would
# already be out of scope by the time a later EXIT trap actually fires if
# the function itself returned normally first.
_ocd_cleanup_wt() {
  local wt="$1" repo="$2"
  if [ -n "$wt" ]; then
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf "$wt" 2>/dev/null || true
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
  fi
}

# _ocd_copy_path <src> <dst> -- rebuild <dst> from <src> FROM SCRATCH, so a
# path removed on the source side is reflected as absent on the destination
# side too (not just additions/edits) -- same rsync-less approach orchid-
# plan's apply arm and orchid-run's new arm already use for .orchid/. A
# DIRECTORY is rebuilt one top-level entry at a time, skipping any entry
# literally named `runtime` (the one directory ever passed here that can
# contain one -- .orchid/runtime/ is local-only, ephemeral, and must never
# ride into a durable commit); a FILE is copied verbatim; a <src> that does
# not exist at all leaves <dst> absent (a deletion, carried through).
_ocd_copy_path() {
  local src="$1" dst="$2" entry name
  rm -rf "$dst"
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    for entry in "$src"/*; do
      [ -e "$entry" ] || continue
      name="$(basename "$entry")"
      [ "$name" = runtime ] && continue
      cp -R "$entry" "$dst/$name"
    done
  elif [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
  fi
}

# _ocd_sync_dir_atomic <dst-dir> <src-dir> -- syncs a DIRECTORY <dst-dir>
# (e.g. "$repo/.orchid") to match <src-dir> (the just-committed worktree's
# copy) via the same crash-safe shadow-dir-swap `orchid run new` already
# uses for its own whole-tree resync: build the complete replacement in a
# sibling shadow dir first (nothing observable changes yet), carry <dst-
# dir>'s own LIVE runtime/ across untouched (the worktree copy never had
# one), then swap it in with two same-parent `mv`s -- each is a single
# filesystem rename, so the only observable window is BETWEEN the two
# renames, when <dst-dir> briefly does not exist at all (never split-brain:
# see orchid-run's own comment on this exact window).
_ocd_sync_dir_atomic() {
  local dst="$1" src="$2" shadow old entry name
  shadow="$dst.new.$$"; old="$dst.old.$$"
  rm -rf "$shadow" "$old"
  mkdir -p "$shadow"
  for entry in "$src"/*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    [ "$name" = runtime ] && continue
    cp -R "$entry" "$shadow/$name"
  done
  [ -d "$dst/runtime" ] && cp -R "$dst/runtime" "$shadow/runtime"
  mv "$dst" "$old"
  mv "$shadow" "$dst"
  rm -rf "$old"
}

# orchid_commit_durable <repo> <message> <path...> -- the plan-apply temp-
# worktree + CAS + sync-back transaction (orchid-plan's `apply` arm; read
# its own header comments for the full CAS-discipline rationale), extracted
# into a single reusable helper. Commits the CURRENT on-disk content of each
# given <path> (relative to <repo> -- a file like `orchid.config`, or a
# directory like `.orchid`) onto `refs/heads/<integration_branch>`, entirely
# through a DETACHED temp worktree: <repo>'s own branch/HEAD/index/working
# tree are NEVER switched, staged into, or otherwise touched (the r-001
# stale-checkout config-commit hazard this closes -- see orchid-config's
# `commit` subverb -- is exactly a naive `git add`/`git commit` run directly
# in a possibly-stale checkout).
#
# Journal-first/epoch discipline is deliberately NOT this helper's job --
# each caller differs on WHEN it applies its own mutations relative to
# calling this (`orchid-plan apply` must apply its planning->running
# transition ONLY inside the temp worktree, never touching <repo> until the
# CAS below actually succeeds; `orchid run accept`/`orchid config commit`
# instead apply their own mutations to <repo> directly, BEFORE ever calling
# this helper, and simply let it commit whatever is now on disk). A caller
# that needs the former may set `ORCHID_COMMIT_DURABLE_HOOK` to the name of
# a function taking the temp worktree's absolute path as `$1`; if set, it is
# invoked once the worktree's copy is fully populated (below) but BEFORE
# `git add`/commit, so whatever it writes into the worktree rides into the
# SAME commit and — critically — is never visible in <repo> until CAS
# success. Callers that mutate <repo> directly beforehand simply leave it
# unset.
#
# Compare-and-swap: `refs/heads/<integ>` is read ONCE at entry and only
# advanced if it still points there once the worktree's commit is ready --
# same discipline `orchid-merge`/`orchid-run new` already use. On CAS
# failure the commit just built is left unreferenced (for gc); an
# `intervention` journal entry naming the conflict is written directly to
# <repo> and this function dies (nonzero) -- retryable, since nothing this
# helper itself wrote to <repo> is ever undone (and whatever the CALLER
# already wrote to <repo> before calling this, for callers that mutate
# first, is untouched either way).
#
# On CAS success, each given <path> is synced back from the worktree's
# just-committed copy over <repo>'s own copy -- a FILE via atomic_write, a
# DIRECTORY via the crash-safe shadow-dir-swap above -- so every caller's
# postcondition is simply "<repo> now matches what's committed." Sets
# ORCHID_COMMIT_DURABLE_SHA to the new commit sha on success.
#
# MUST be called as a plain statement, never via `$(...)`/a pipeline: this
# function manages its OWN EXIT trap (composed with whatever the caller's
# was, so a temp-worktree cleanup always runs before -- and never replaces
# -- the caller's own, e.g. verb_lock_release). A command substitution
# forks a subshell, so any trap manipulation inside would only ever affect
# that throwaway subshell, never the real calling script -- silently
# breaking that composition (and, since bash local variables/flags like
# `_verb_lock_owned` are copied into the subshell at fork time, a `trap`
# left armed there firing on the subshell's own exit could act on the
# caller's still-live state, e.g. releasing its verb lock too early).
orchid_commit_durable() {
  local repo="$1" message="$2"; shift 2
  [ "$#" -gt 0 ] || orchid_die "orchid_commit_durable: at least one path required"

  local integ integ_head
  integ="$(config_get "$repo" integration_branch orchid/integration)"
  git -C "$repo" rev-parse --verify -q "refs/heads/$integ" >/dev/null 2>&1 \
    || orchid_die "integration branch '$integ' does not exist"
  integ_head="$(git -C "$repo" rev-parse "refs/heads/$integ")"

  local wt; wt="$(mktemp -d "${TMPDIR:-/tmp}/orchid-commit.XXXXXX")"
  local wt_q repo_q; printf -v wt_q '%q' "$wt"; printf -v repo_q '%q' "$repo"
  local prev_trap; prev_trap="$(trap -p EXIT)"
  local prev_cmd=""
  case "$prev_trap" in
    "trap -- "*)
      prev_cmd="${prev_trap#trap -- \'}"; prev_cmd="${prev_cmd%\' EXIT}" ;;
  esac
  if [ -n "$prev_cmd" ]; then
    # ShellCheck rationale: quoted local paths and the prior trap are intentionally captured before locals leave scope.
    # shellcheck disable=SC2064
    trap "_ocd_cleanup_wt $wt_q $repo_q; $prev_cmd" EXIT
  else
    # ShellCheck rationale: the quoted local paths must be captured before locals leave scope.
    # shellcheck disable=SC2064
    trap "_ocd_cleanup_wt $wt_q $repo_q" EXIT
  fi

  git -C "$repo" worktree add -q --detach "$wt" "$integ_head" >/dev/null 2>&1 \
    || orchid_die "cannot create temp worktree at $integ_head"

  local p
  for p in "$@"; do
    _ocd_copy_path "$repo/$p" "$wt/$p"
  done

  if [ -n "${ORCHID_COMMIT_DURABLE_HOOK:-}" ]; then
    "$ORCHID_COMMIT_DURABLE_HOOK" "$wt"
  fi

  git -C "$wt" add -- "$@"
  if git -C "$wt" diff --cached --quiet -- "$@"; then
    orchid_die "orchid_commit_durable: nothing to commit -- no changes in: $*"
  fi
  git -C "$wt" commit -q -m "$message"
  local new_sha; new_sha="$(git -C "$wt" rev-parse HEAD)"

  if ! git -C "$repo" update-ref "refs/heads/$integ" "$new_sha" "$integ_head"; then
    local moved_to; moved_to="$(git -C "$repo" rev-parse "refs/heads/$integ" 2>/dev/null || echo "?")"
    ORCHID_REPO="$repo" "$ORCHID_ROOT/bin/orchid" journal add --kind intervention \
      "commit-durable CAS failure ($message) — integration branch '$integ' changed concurrently (expected $integ_head, now $moved_to) — retry"
    orchid_die "update-ref CAS failed: integration branch '$integ' changed concurrently (expected $integ_head) — retry"
  fi

  for p in "$@"; do
    if [ -f "$wt/$p" ]; then
      cat "$wt/$p" | atomic_write "$repo/$p"
    elif [ -d "$wt/$p" ]; then
      _ocd_sync_dir_atomic "$repo/$p" "$wt/$p"
    else
      rm -rf "${repo:?}/$p"
    fi
  done

  _ocd_cleanup_wt "$wt" "$repo"
  if [ -n "$prev_cmd" ]; then
    # ShellCheck rationale: this restores the exact previously captured EXIT command.
    # shellcheck disable=SC2064
    trap "$prev_cmd" EXIT
  else
    trap - EXIT
  fi
  # ShellCheck rationale: this public result is read by callers after this sourced function returns.
  # shellcheck disable=SC2034
  ORCHID_COMMIT_DURABLE_SHA="$new_sha"
}

# -- Recording an operator-facing fact exactly once --------------------------
#
# Two thin wrappers over the two verbs that make a refusal durable. They exist
# because every condition worth recording this way PERSISTS UNTIL A HUMAN ACTS,
# so a later pass re-reaches it: a writer that appends unconditionally buries the
# run's history under one unchanging fact, and a writer that skips
# unconditionally loses the record entirely. Each therefore asks the RECEIPT the
# previous write left behind -- the journal entry, the BLOCKERS.md line -- never
# a mark made ahead of one, which a process felled in between would turn into
# "already reported" about a report nobody made.
#
# THEY LIVE HERE, and not beside the policy that composes the line they record,
# because lib/drive.sh, lib/handoff.sh, lib/findings.sh and lib/capability.sh are
# the driver's read-only policy libraries: INV-13 forbids all four from reaching
# for a verb, precisely so a mutation cannot hide behind a function call the
# driver's own audit cannot see. Their callers are runners -- tier-2, effectful,
# and every one of them already sources this file.
#
# ONE IMPLEMENTATION EACH, BECAUSE EACH HAS TWO WRITERS. The task-scoped journal
# line is written by runners/orchid-launch (synchronously, on `orchid jobs
# prepare`'s exit 19) and by runners/orchid-drive (on the passes where the driver
# is what ran that launcher); the run-scoped blocker is written by
# runners/orchid-pump's pre-wake probe and by runners/orchid-tick, which is an
# unattended entry point in its own right and cannot assume the pump ever ran.
# Two copies of a dedup rule is two places for it to drift into a writer that
# never matches the other's record.

# orchid_journal_once <repo> <task> <line> -- append <line> to <task>'s journal
# unless that exact text is already in the task's own index. 0 whether it wrote
# or found it already there; nonzero only when the write itself failed.
#
# `journal show --task` reads a BOUNDED tail of that index (libexec/orchid-journal
# keeps 40 entries), so a task whose history has churned far past this entry may
# record it a second time. That is an honest re-statement after a long gap, not a
# line per pass, and the alternative -- scanning the whole journal for every
# candidate line -- makes the cost of the check grow with the run.
orchid_journal_once() {
  local repo="$1" task="$2" line="$3" prior
  prior="$(ORCHID_REPO="$repo" "$ORCHID_ROOT/bin/orchid" journal show --task "$task" 2>/dev/null || true)"
  case "$prior" in
    *"$line"*) return 0 ;;
  esac
  ORCHID_REPO="$repo" "$ORCHID_ROOT/bin/orchid" journal add --task "$task" "$line" >/dev/null
}

# _orchid_blocker_open <blockers-file> <answers-dir> <line> -- 0 iff some
# BLOCKERS.md entry carries <line> AND that entry's question is still open.
#
# PARSED RATHER THAN GREPPED, because the answer needs the entry's QID and a
# match alone does not carry one. libexec/orchid-notify writes each entry as a
# `## <qid>` header (or `## <qid> (task: <id>)`) followed by the text, so the
# header last seen above a matching body line is the qid that text was recorded
# under. Pure bash, like every other reader here: no subprocess per pass, and
# nothing to quote a sentence full of apostrophes and em dashes through.
#
# THE WALK DOES NOT STOP AT THE FIRST COPY. A line recorded, answered and
# recorded again has two entries, and it is the LATER one that decides -- so an
# answered entry only clears the qid and the loop keeps looking for a copy
# nobody has settled.
_orchid_blocker_open() {
  local file="$1" answers="$2" line="$3"
  local qid="" body
  while IFS= read -r body || [ -n "$body" ]; do
    case "$body" in
      '## '*)
        qid="${body:3}"
        qid="${qid%% *}"
        ;;
      *"$line"*)
        [ -n "$qid" ] || continue
        [ -f "$answers/$qid.answer" ] || return 0
        qid=""
        ;;
    esac
  done < "$file"
  return 1
}

# orchid_blocker_once <repo> <epoch> <line> -- raise <line> for an operator
# unless an UNRESOLVED blocker already carries it. Three outcomes, and a caller
# must read the status: 0 recorded now, 1 already on record, 2 the write failed.
#
# ONE VERB, WHICH IS BOTH HALVES. `orchid notify` journals the text (kind
# `blocker`) BEFORE it appends to BLOCKERS.md (libexec/orchid-notify's INV-08
# ordering note), so a single call produces the durable journal record AND the
# operator surface, in that order, epoch-fenced and verb-locked like every other
# durable write. One dedup therefore governs both halves: a caller that skips
# the call adds neither, and a dedup that let the call through twice would file
# a duplicate journal line as well as a duplicate blocker.
#
# DEDUPED ON BLOCKERS.md, which is the RECEIPT that call leaves: if the entry is
# there the notify happened, and if the notify died before it the entry is absent
# and the next pass re-raises. The WHOLE file is searched rather than a bounded
# tail -- this condition persists across arbitrarily many passes, and a window
# that scrolled past would start one blocker per pass.
#
# BUT THE RECEIPT IS SCOPED TO AN INCIDENT, NOT TO ALL TIME, and that is what
# reading it alone got wrong. BLOCKERS.md is append-only -- notify only ever
# concatenates -- so a line recorded once is in that file for the rest of the
# repository's life, and a dedup that asked the file and nothing else answered
# "already on record" forever. That is exactly right while nobody has dealt with
# the condition, which is the case it was written for: the same shortfall met on
# a hundred passes is ONE fact and must be raised once. It is wrong the moment
# somebody HAS dealt with it. An operator who answers the question, binds a
# capable engine and moves on has settled that incident; if the same shortfall
# comes back -- a manifest edited, a role rebound to an engine short the atom,
# a chain restored from an older config -- it is a NEW fact about a repository
# somebody already believes they fixed, and the one surface that would tell them
# stayed silent because a resolved entry was still sitting in the file. The
# permanence of the condition is the reason to raise it again, not a reason to
# stay quiet.
#
# SO THE RECEIPT IS READ TOGETHER WITH ITS RESOLUTION, in the terms this kernel
# already has for one. `orchid notify` mints `runtime/answers/<qid>.question`
# beside the BLOCKERS.md entry and `orchid answer` mints `<qid>.answer` beside
# that, and a question with no answer is precisely what libexec/orchid-status
# already lists as an OPEN blocker -- so this asks that same pair rather than
# inventing a second notion of settled. An entry carrying this line whose qid
# has no answer is the incident still standing, and there is nothing to add;
# once every recorded copy has been answered, the next occurrence raises a fresh
# blocker and a fresh journal line, mints a fresh qid, and every pass after it
# dedups against THAT one. One entry per incident: never one per pass, and never
# one for all time.
#
# RESOLUTION IS SHOWN, NEVER ASSUMED, which is the direction this must fail in.
# Only a recorded `.answer` re-arms the raise. An entry whose runtime record is
# gone entirely -- runtime/ is gitignored and rebuildable, and a state copy drops
# it (libexec/orchid-run) -- proves nothing about a human having acted on
# anything, so it reads as STILL OPEN and stays quiet. The failure this dedup
# exists to prevent is one unchanging fact restated once per pass forever, and
# "I cannot tell whether it was settled" must never be the thing that starts
# that up again.
#
# <epoch> is passed rather than read here because `orchid notify` is epoch-fenced
# (INV-02) and the fence must carry the epoch the CALLER's pass is inside.
# Sampled at the moment of the write, it would be vacuous: whatever epoch is
# current always satisfies `epoch_require`, so a session that fenced a fresh one
# while this pass ran would have its epoch silently borrowed.
orchid_blocker_once() {
  local repo="$1" epoch="$2" line="$3" blockers answers
  blockers="$(orchid_state "$repo")/BLOCKERS.md"
  answers="$(orchid_runtime "$repo")/answers"
  if [ -f "$blockers" ] && _orchid_blocker_open "$blockers" "$answers" "$line"; then
    return 1
  fi
  ORCHID_REPO="$repo" ORCHID_EPOCH="$epoch" \
    "$ORCHID_ROOT/bin/orchid" notify "$line" >/dev/null 2>&1 || return 2
  return 0
}

# with_timeout <secs> cmd... -- runs cmd (any command form, including a
# shell function name) with a wall-clock deadline; returns cmd's own exit
# status, or 124 on timeout. Both the timed command AND the watcher are
# backgrounded under `set -m` (job control) so each lands in its OWN process
# group (pgid == its own pid) -- same trick runners/orchid-launch's spawn
# line already uses. Two DISTINCT bugs this closes, both stemming from a
# bare `kill "$pid"`/`kill "$w"` only ever reaching one process, never a
# group:
#   (a) on timeout, `cmd` may itself be a wrapper (a shell function, or a
#       script) whose real work is a DISTINCT child process -- killing only
#       the wrapper's pid orphans that child, which keeps running (and, for
#       a real CLI, billing quota) under init. `kill -- "-$pid"` (negative
#       PGID) reaches the wrapper's whole group instead.
#   (b) on the (common) early-finish path, the watcher's own `sleep "$secs"`
#       is a real forked child of the watcher subshell by the time this
#       function gets around to cancelling it -- a bare `kill "$w"` (no
#       leading dash) terminates only the subshell itself, orphaning the
#       already-forked `sleep` under init for the REST of its full "$secs",
#       silently holding open any stdout/stderr pipe it inherited (e.g. a
#       caller capturing this function's output via `$(...)`) -- discovered
#       the hard way: runners/orchid-tick's `$(...)`-captured invocation
#       hung for the full deadline on every otherwise-successful run, and
#       `ps`/`lsof` after the fact showed the orphaned `sleep` still holding
#       an inherited pipe fd, reparented to pid 1. `kill -- "-$w"` reaches
#       the watcher's own group -- the subshell AND the sleep it forked
#       (same group, inherited across fork) -- so no orphan survives either
#       branch below.
with_timeout() {
  local secs="$1"; shift
  set -m
  "$@" & local pid=$!
  set +m
  set -m
  ( sleep "$secs"; kill -- "-$pid" 2>/dev/null ) & local w=$!
  set +m
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  if kill -0 "$w" 2>/dev/null; then kill -- "-$w" 2>/dev/null; wait "$w" 2>/dev/null; return "$rc"; fi
  return 124
}

# -- worktrees Orchid creates ------------------------------------------------

# orchid_physical_dir <path> -- <path> as a canonical, absolute, symlink-free
# directory path, or nothing (non-zero) when it does not exist or is not a
# directory.
#
# `cd` plus `pwd -P`, and nothing else. Both one-word spellings of this are
# traps: `realpath` is not installed on a stock macOS, and BSD `readlink` had
# no `-f` at all before macOS 12.3 -- either would work on the CI Linux runner
# and fail on the operator's own laptop, which is the worst way for a path
# helper to differ. This spelling is shell built-ins only, so it behaves the
# same everywhere bash 3.2 runs.
#
# CANONICAL matters as much as portable. macOS reaches $TMPDIR through a
# symlink (/var -> /private/var), so one directory has two spellings, and any
# path this repository hands to something running ELSEWHERE -- a `git worktree
# list` comparison, or a `worktree_prepare` command whose cwd is a fresh
# checkout under /var/folders -- must be the spelling both sides agree on.
orchid_physical_dir() {
  ( cd "$1" 2>/dev/null && pwd -P )
}

# A checkout Orchid creates holds exactly what is committed and nothing else:
# a task's dispatch worktree (runners/orchid-drive) and the detached
# validation worktree `orchid merge` runs the suite in are both `git worktree
# add` of a ref, never a copy of anybody's working directory. So every project
# whose verification needs something UNTRACKED -- installed dependencies, a
# generated lockfile, a .env, a built toolchain -- fails in those checkouts
# while passing in the operator's own, and the failure is reported against the
# candidate rather than against the environment that produced it.
#
# `worktree_prepare` (config, default unset) is the operator's one chance to
# close that gap: a command line run INSIDE the fresh checkout before anything
# else uses it. Parsed from config and never sourced -- same treatment
# `verify` gets -- and run through `bash -c` in the foreground, so this is a
# setup command rather than an engine spawn and INV-01 is untouched.
#
# The command is handed three environment variables, of which the first is the
# point of the exercise:
#
#   ORCHID_REPO_ROOT  the repository orchid dispatched from, canonicalized by
#                     orchid_physical_dir. A prepare command's job is nearly
#                     always to bring across something the checkout does not
#                     have (`ln -s "$ORCHID_REPO_ROOT/node_modules" .`), and
#                     it cannot work that path out for itself: a dispatch
#                     worktree is a SIBLING of the repository while a merge
#                     validation worktree is an unrelated mktemp directory
#                     under $TMPDIR, so no fixed number of `..` hops reaches
#                     the repository from both, and on macOS the $TMPDIR one
#                     is not even on the same spelling of the filesystem.
#   ORCHID_WORKTREE   the checkout being prepared (also its cwd).
#   ORCHID_TASK       the task id that checkout belongs to. The TASK ID, and
#                     nothing decorated onto it: a prepare command that keys a
#                     cache or names a scratch directory off this value has to
#                     get back the same string the rest of the protocol uses
#                     for that task. Which checkout of that task is being
#                     prepared is ORCHID_WORKTREE's job to say, and the log
#                     slug's -- neither of which is this variable.
#
# ORCHID_REPO_ROOT is deliberately NOT spelled `ORCHID_REPO`: that name is a
# verb's "which repository am I operating on" input, and setting it here would
# silently retarget any nested `orchid` call the prepare command makes -- at
# the exact moment the caller is standing in a different checkout.

# _worktree_prepare_gitdir <worktree> -- that checkout's PRIVATE git directory
# (`<common>/worktrees/<name>` for a linked worktree, `.git` for the main
# one), canonicalized, or nothing.
#
# This is where the prepared-stamp goes, and the choice is the whole
# crash-safety story: git deletes that directory when the worktree is removed
# or pruned, so a stamp can never outlive the checkout it describes, and a
# worktree recreated at the same path is never mistaken for a prepared one.
_worktree_prepare_gitdir() {
  local wt="$1" raw
  raw="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  case "$raw" in
    /*) ;;
    *) raw="$wt/$raw" ;;
  esac
  orchid_physical_dir "$raw"
}

# _worktree_prepare_run <worktree> <repo-root> <task> <command> -- the child
# side of the fork with_timeout backgrounds: working directory and
# environment, then the configured command line through `bash -c` WITH ITS
# STDIN CLOSED, exactly as `orchid verify` runs its own.
#
# `</dev/null` is the load-bearing token on that line, and leaving it off is a
# silent-data-loss bug rather than a hygiene miss. runners/orchid-drive walks
# its work through loops whose OWN stdin is the list being walked -- the task
# walk reads `< <("$ORCHID_BIN" task list | sort)`, and the binding,
# review-slot and escalation loops are herestring-fed the same way. Dispatch
# calls worktree_prepare from inside that walk, in a command substitution,
# which redirects stdout and nothing else; so an inherited stdin here is the
# driver's own worklist pipe. A prepare command that reads stdin for any
# ordinary reason -- an installer asking to continue, a bootstrap script with
# a bare `read`, anything ending in `cat` -- then consumes the tasks the
# driver has not walked yet. The loop sees EOF, the pass ends early having
# silently skipped real work, and NOTHING reports an error: every task it
# never reached simply looks like a task with nothing to do this pass.
#
# Closing stdin makes that impossible instead of unlikely, and costs a prepare
# command nothing it should have had: it is a setup step running unattended,
# with no operator on the other end of a prompt to answer it.
_worktree_prepare_run() {
  local wt="$1" root="$2" task="$3" cmd="$4"
  cd "$wt" || return 1
  ORCHID_REPO_ROOT="$root" ORCHID_WORKTREE="$wt" ORCHID_TASK="$task" \
    bash -c "$cmd" </dev/null
}

# worktree_prepare <repo> <worktree> <task> [log-slug] -- prepares <worktree>
# when the operator configured a command for it. Prints exactly one line,
# "<action><TAB><detail>" (the shape drive_worktree_plan already uses), and
# ALWAYS returns 0: the caller owns the consequence, and the two callers differ
# on it -- dispatch parks the run on a worktree-conflict boundary and leaves
# the task where it was, while `orchid merge` dies before it can report an
# environment's problem as a candidate's.
#
#   skip <reason>   nothing is configured, or this checkout's stamp already
#                   records this exact command
#   ok   <log>      the command ran and exited 0
#   fail <reason>   it exited non-zero, outlived worktree_prepare_timeout_s,
#                   or could not be run at all. Names the log either way.
#
# The stamp records the COMMAND TEXT, not merely the fact of a run, so editing
# `worktree_prepare` re-prepares every checkout on its next pass -- and a
# FAILED run is never stamped, so the next pass retries it once the operator
# has fixed whatever broke.
#
# <task> is the task id the checkout belongs to, and reaches the command as
# ORCHID_TASK -- undecorated, because that variable's contract is the task id.
# <log-slug> names the log and defaults to <task>; the ONLY caller that passes
# it is `orchid merge`, which prepares a SECOND checkout for a task that
# usually already has a dispatch worktree, and would otherwise overwrite that
# checkout's prepare log with this one's. Two checkouts, two records, one task
# id in both.
worktree_prepare() {
  local repo="$1" wt="$2" task="$3" slug="${4:-$3}"
  local cmd root phys gitdir stamp rt log secs out_tmp tail_txt rc=0
  cmd="$(config_get "$repo" worktree_prepare "")"
  if [ -z "$cmd" ]; then
    printf 'skip\tno worktree_prepare configured\n'
    return 0
  fi
  root="$(orchid_physical_dir "$repo")" || root=""
  if [ -z "$root" ]; then
    printf 'fail\tcannot resolve the repository root %s\n' "$repo"
    return 0
  fi
  phys="$(orchid_physical_dir "$wt")" || phys=""
  if [ -z "$phys" ]; then
    printf 'fail\tcannot resolve the worktree %s\n' "$wt"
    return 0
  fi
  gitdir="$(_worktree_prepare_gitdir "$phys")" || gitdir=""
  if [ -z "$gitdir" ]; then
    printf 'fail\t%s is not a git checkout, so nothing can record that it was prepared\n' "$phys"
    return 0
  fi
  stamp="$gitdir/orchid-prepared"
  if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$cmd" ]; then
    printf 'skip\t%s is already prepared with this command\n' "$phys"
    return 0
  fi

  secs="$(config_get "$repo" worktree_prepare_timeout_s 900)"
  # A non-numeric budget would go straight to with_timeout's own `sleep`,
  # whose immediate failure would have the watcher kill the command the
  # instant it started -- every prepare a zero-second timeout, silently. A
  # malformed value falls back to the default instead.
  case "$secs" in ''|*[!0-9]*) secs=900 ;; esac

  # The log lives under runtime/ (gitignored), never in .orchid/reviews/:
  # this is an environment record, not evidence about a candidate, and no
  # gate reads it.
  rt="$(orchid_runtime "$repo")"
  mkdir -p "$rt/worktree-prepare"
  slug="${slug//\//-}"; [ -n "$slug" ] || slug=worktree
  log="$rt/worktree-prepare/$slug.log"

  out_tmp="$(mktemp "${TMPDIR:-/tmp}/orchid-prepare.XXXXXX")"
  with_timeout "$secs" _worktree_prepare_run "$phys" "$root" "$task" "$cmd" \
    >"$out_tmp" 2>&1 || rc=$?
  {
    echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "worktree: $phys"
    echo "repo_root: $root"
    echo "task: $task"
    echo "command: $cmd"
    echo "---"
    cat "$out_tmp"
    echo "exit: $rc"
  } | atomic_write "$log"
  # A boundary reason is one line, so the tail that explains the failure is
  # flattened and bounded here rather than at each call site.
  tail_txt="$(tail -n 3 "$out_tmp" 2>/dev/null | tr '\n\t' '  ')" || tail_txt=""
  tail_txt="${tail_txt:0:200}"
  rm -f "$out_tmp"

  if [ "$rc" -eq 0 ]; then
    # An unwritable stamp costs a repeated prepare on the next pass, which is
    # exactly what an unprepared checkout would have got anyway -- never worth
    # aborting a caller running under `set -e` over.
    printf '%s\n' "$cmd" | atomic_write "$stamp" || true
    printf 'ok\t%s\n' "$log"
    return 0
  fi
  # 124 AND 143 are both "we killed it". with_timeout reports 124 only when
  # its watcher has already been reaped by the time the timed command is
  # waited on; win that race the other way -- the watcher fires, kills the
  # group, and is still a zombie when `kill -0` checks it -- and the caller
  # gets the command's OWN status for a SIGTERM it did not survive, which is
  # 128+15. Reading that as an ordinary non-zero exit would tell the operator
  # to go debug a command that never got to finish.
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    printf 'fail\tworktree_prepare timed out after %ss in %s (worktree_prepare_timeout_s; see %s)\n' \
      "$secs" "$phys" "$log"
    return 0
  fi
  printf 'fail\tworktree_prepare failed (exit status %s) in %s (see %s)%s\n' \
    "$rc" "$phys" "$log" "${tail_txt:+ -- $tail_txt}"
  return 0
}

# v1-m4: hyphenated config keys (a custom role id like `role.code-reviewer`)
# used to have NO working env override at all -- `tr 'a-z.'` never mapped
# `-`, so `ORCHID_ROLE_CODE-REVIEWER` (an invalid env var name; bash silently
# treats it as unset) was the only name ever produced, and `config_get`'s
# `eval "v=\${$env:-}"` line would in fact throw a "bad substitution" for that
# exact shape were it ever reached with the raw hyphen still in place. `-`
# now maps to `_` alongside `.`, so `role.code-reviewer` -> `ORCHID_ROLE_CODE_REVIEWER`.
_cfg_env_name() { echo "ORCHID_$(echo "$1" | tr 'a-z.-' 'A-Z__')"; }
# Last matching `key=value` line in the file wins (append-to-override, as in
# a typical shell/config file); this was a `head -n1` (first-wins) bug that
# silently made appended config overrides no-ops. Found while writing Task 8's
# doctor test, which appends a second `role.implementer=` line expecting it
# to take effect.
_cfg_file_get() {
  local k_esc
  k_esc=$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')
  [ -f "$1" ] && grep -E "^$k_esc=" "$1" | tail -n1 | cut -d= -f2- || true
}
config_get() {
  local repo="$1" key="$2" def="${3:-}" v env
  env="$(_cfg_env_name "$key")"
  eval "v=\${$env:-}"; [ -n "$v" ] && { echo "$v"; return; }
  v="$(_cfg_file_get "$repo/orchid.config" "$key")"; [ -n "$v" ] && { echo "$v"; return; }
  v="$(_cfg_file_get "$HOME/.orchid/config" "$key")"; [ -n "$v" ] && { echo "$v"; return; }
  echo "$def"
}
config_provenance() {
  local repo="$1" key="$2" env v
  env="$(_cfg_env_name "$key")"; eval "v=\${$env:-}"
  [ -n "$v" ] && { echo env; return; }
  [ -n "$(_cfg_file_get "$repo/orchid.config" "$key")" ] && { echo repo; return; }
  [ -n "$(_cfg_file_get "$HOME/.orchid/config" "$key")" ] && { echo user; return; }
  echo default
}

_pid_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -d ' ' || true; }

# _owner_field <owner-json> <field> -- print ONE field of a lock owner record,
# reading from a SNAPSHOT string (never re-reading the file), so callers that
# `cat` owner.json once keep the single-read atomicity they depend on: a naive
# per-field re-read could straddle two generations of owner and misjudge a
# genuinely live new owner as dead. Prints nothing and returns non-zero when
# the snapshot does not parse, so callers can keep their own defaults.
#
# Deliberately one variable per call rather than one jq that emits a shell
# fragment for `eval`. owner.json is REPOSITORY-CONTROLLED input: .orchid's
# gitignore does not stop `git add -f`, and a clone carries whatever the
# remote committed, so a hostile repo can hand any lock-taking verb the bytes
# of its choice. Under `eval` that was arbitrary command execution as the
# operator, needing no unattended-trust acknowledgement -- @sh-quoting each
# field only narrowed it, and one unquoted `tostring` reopened it. Nothing
# read here reaches the shell as code at all.
_owner_field() {
  printf '%s' "$1" | jq -er --arg f "$2" '.[$f]|tostring' 2>/dev/null
}
lock_acquire() {
  local repo="$1" rt lock brk
  rt="$(orchid_runtime "$repo")"; lock="$rt/lock"
  brk="${ORCHID_LOCK_BREAK_S:-$(config_get "$repo" lock_break_s 900)}"
  if ! mkdir "$lock" 2>/dev/null; then
    local pid host pstart age now mt
    pid="$(jq -r .pid "$lock/owner.json" 2>/dev/null || echo 0)"
    host="$(jq -r .hostname "$lock/owner.json" 2>/dev/null || echo '?')"
    pstart="$(jq -r .pid_start "$lock/owner.json" 2>/dev/null || echo '?')"
    # An unreadable lock mtime falls back to `now`, i.e. age 0, i.e. the
    # conservative "too young to break" answer -- never to a number that
    # would let this acquirer tear down a lock it cannot actually date.
    now="$(date +%s)"; mt="$(file_mtime "$lock" "$now")"
    age=$(( now - mt ))
    local alive=1
    if [ "$host" != "$(hostname)" ]; then alive=0
    elif ! kill -0 "$pid" 2>/dev/null; then alive=0
    elif [ "$(_pid_start "$pid")" != "$pstart" ]; then alive=0; fi
    if [ "$alive" -eq 0 ] && [ "$age" -gt "$brk" ]; then
      rm -rf "$lock"; mkdir "$lock" || return 1
      echo "lock-broken (owner pid $pid dead/foreign, age ${age}s)"
    else
      echo "orchid: lock held by pid $pid on $host" >&2; return 1
    fi
  fi
  if ! jq -n --arg p "$$" --arg s "$(_pid_start "$$")" --arg h "$(hostname)" \
    --arg e "$(epoch_current "$repo")" \
    '{pid:($p|tonumber), pid_start:$s, hostname:$h, epoch:($e|tonumber? // 0)}' \
    > "$lock/owner.json" 2>/dev/null; then
    rm -rf "$lock"
    return 1
  fi
}
lock_release() { rm -rf "$(orchid_runtime "$1")/lock"; }

# -- Per-verb transactional lock (runtime/verb-lock) -------------------------
# kernel.md: "Per-verb transactional locking ... is a Plan B deliverable,
# arriving alongside the tick loop." With a pump-launched tick and an
# interactive session both alive, epoch fencing alone still leaves a
# torn-write window between a verb's fence check and its write — this is a
# SEPARATE lock dir from the RUN lock above (`runtime/lock`, held only across
# `run start|resume`, above): every DURABLE-mutating verb wraps its own
# transaction in THIS lock instead, for its own (sub-second) duration.
#
# Reentrant BY DESIGN: `ORCHID_VERB_LOCK_HELD=1`, once exported, makes any
# NESTED acquisition (task advance -> journal add; plan apply -> journal add
# against its temp worktree's own runtime -- note a DIFFERENT repo; run
# advance/accept -> journal add; notify/answer -> journal add; orchid-launch
# -> jobs prepare) a no-op regardless of which repo the nested call names --
# acceptable for v1 (single-operator; the OUTER transaction already
# serializes the whole nested sequence). `_verb_lock_owned` is a plain shell
# variable (never re-derived from the env) precisely so a nested/reentrant
# call can never release its parent's lock out from under it at its own exit.
_verb_lock_owned=0
verb_lock_acquire() {
  local repo="$1" rt lock wait_s pid host pstart alive owner_json myhost self_json empty_since start_s elapsed
  [ "${ORCHID_VERB_LOCK_HELD:-0}" = 1 ] && return 0
  rt="$(orchid_runtime "$repo")"; lock="$rt/verb-lock"
  wait_s="$(config_get "$repo" verb_lock_wait_s 10)"
  myhost="$(hostname)"          # cached once -- not re-forked every retry iteration
  # Real wall-clock budget, NOT a try count: this function has two retry
  # paths with genuinely different paces -- the live-owner wait below sleeps
  # ~0.2s per try, while the self-verify-failure retry (further down) can
  # spin with no sleep at all when mkdir keeps winning fresh. A single
  # shared `tries` counter (the previous implementation) let a burst of the
  # unpaced path -- or any mix of the two -- trip the budget well before
  # wait_s real seconds had actually elapsed, making the die message's
  # "waited <n>s" claim false. Bounding on ACTUAL elapsed time instead (not
  # a spawn -- INV-01 scopes to libexec/*) keeps that claim honest
  # regardless of which path, or what mix, burns the budget.
  start_s="$(date +%s)"
  # Outer loop: a full acquire attempt is "win the mkdir race, then prove the
  # claim actually landed" (see the self-verification below) -- on ANY
  # failure to prove that, the whole attempt is abandoned and retried from
  # scratch here, never patched up by re-writing in place (see why below).
  while true; do
    empty_since=""   # reset per fresh outer-loop attempt -- see below
    while ! mkdir "$lock" 2>/dev/null; do
      # Read owner.json ONCE into a variable and parse every field from that
      # SAME snapshot -- not three separate `jq -r .field "$lock/owner.json"`
      # calls. Under real contention the file can be atomically REPLACED
      # (mv, below) between two separate reads: a naive per-field read could
      # straddle two different owners' records and misjudge a genuinely live
      # new owner as dead. A single `cat` either returns one complete
      # generation's content or none at all (mv is atomic on one filesystem)
      # -- an empty read (dir claimed but its owner.json not written yet, the
      # few-ms window right after ITS mkdir) is treated the same as "still
      # being claimed", never "dead/foreign": that misread would rm -rf a
      # brand-new legitimate owner's lock out from under it. Just wait it
      # out, uncounted against the wait budget below (a benign micro-race,
      # not real contention) -- UNLESS it has been empty for as long as the
      # full wait budget itself: a crash between the winner's mkdir and its
      # owner.json write leaves exactly this signature (dir present, no
      # owner.json, no pid/host/pid_start ever recorded), and nothing else
      # would ever break it. `empty_since` tracks how long THIS generation
      # has been observed empty (reset the moment a real owner record
      # appears, so a brand-new legitimately-empty generation always gets
      # its own fresh grace window, never inherited time from a prior one).
      owner_json="$(cat "$lock/owner.json" 2>/dev/null)"
      if [ -z "$owner_json" ]; then
        if [ -z "$empty_since" ]; then
          empty_since=$SECONDS
        elif [ $(( SECONDS - empty_since )) -ge "$wait_s" ]; then
          # Persistently empty past the wait budget: broken like a dead
          # owner. Re-confirmed against a fresh read immediately before the
          # destructive rm -rf, same reasoning as the dead-owner path below
          # -- a legitimate claimant may have written owner.json in the
          # instant since our last read.
          if [ -z "$(cat "$lock/owner.json" 2>/dev/null)" ]; then
            rm -rf "$lock" 2>/dev/null
          fi
          empty_since=""
          continue
        fi
        sleep 0.05
        continue
      fi
      empty_since=""
      # One field per variable, all three off the SAME snapshot -- see
      # _owner_field for why this must never be an `eval`ed shell fragment.
      # The fallbacks are the same ones the old defaults gave when jq failed
      # to parse the record at all: host='?' alone already reads dead/foreign.
      pid="$(_owner_field "$owner_json" pid || printf 0)"
      host="$(_owner_field "$owner_json" hostname || printf '?')"
      pstart="$(_owner_field "$owner_json" pid_start || printf '?')"
      alive=1
      if [ "$host" != "$myhost" ]; then alive=0
      elif ! kill -0 "$pid" 2>/dev/null; then alive=0
      elif [ "$(_pid_start "$pid")" != "$pstart" ]; then alive=0; fi
      if [ "$alive" -eq 0 ]; then
        # Dead/foreign owner: broken IMMEDIATELY, no age floor (unlike the
        # RUN lock's lock_break_s) -- verb transactions are sub-second, so a
        # dead owner's lock is never a legitimate long-running holder to
        # wait out.
        #
        # Re-confirmed against a FRESH read, immediately before the
        # destructive rm -rf: the liveness check above takes a few
        # subprocess forks' worth of wall time, and under heavy contention
        # (many verbs racing the same repo) that is enough time for the
        # truly-dead owner this decision was based on to have ALREADY been
        # reaped and the slot re-claimed by a brand-new, genuinely live
        # owner. Acting on stale information at that point would tear down
        # the new owner's lock mid-transaction -- exactly the torn-write
        # window this whole lock exists to close. Only break it if the
        # content is still identical to what was just judged dead;
        # otherwise the world has already moved on (someone else's problem
        # now, or already resolved) -- loop back and re-evaluate current
        # reality instead.
        #
        # This narrows, but cannot fully close, the window: `rm -rf` itself
        # is not atomic (fork+exec, then unlink-then-rmdir), so a THIRD
        # process can still win a fresh `mkdir` in the instant between this
        # recheck passing and the `rm -rf` line actually executing -- that
        # new owner's claim would then be destroyed by OUR rm -rf, which
        # decided "dead" against a generation that, by execution time, no
        # longer exists. That residual sliver is what the claim-side
        # self-verification below exists to catch: it is the OTHER half of
        # this same double-owner risk, closed from the victim's side rather
        # than the breaker's.
        if [ "$(cat "$lock/owner.json" 2>/dev/null)" = "$owner_json" ]; then
          rm -rf "$lock" 2>/dev/null
        fi
        continue
      fi
      elapsed=$(( $(date +%s) - start_s ))
      [ "$elapsed" -lt "$wait_s" ] || \
        orchid_die "verb lock held by pid $pid — another verb is mid-transaction (waited ${elapsed}s)"
      sleep 0.2
    done
    # mkdir won: we hold what SHOULD be a fresh, empty generation of
    # "$lock". Claim it -- but the exit condition for "I hold the lock" is
    # "owner.json exists AND names me", never "I successfully wrote it".
    # Those are NOT the same thing: a breaker elsewhere can have verified
    # some PRIOR occupant dead and be mid-flight on its own `rm -rf` (the
    # residual sliver noted above) that lands anywhere from just before our
    # mkdir to just after our write below. If it lands AFTER our write, our
    # directory -- the one we're using RIGHT NOW -- is gone or has since
    # been re-claimed by a third process. Blindly re-writing owner.json in
    # that case (the previous version of this code did exactly that, in a
    # retry loop) would stomp on that third process's legitimate claim:
    # TWO processes would then both believe they hold the lock -- the exact
    # double-owner failure this whole mechanism exists to prevent. So:
    # write, then RE-READ, and only trust the claim if the file we see now
    # is still exactly the one we just wrote. Any mismatch (vanished, or
    # naming someone else) means our claim on THIS generation was lost --
    # abandon it and retry the WHOLE acquire from scratch (the outer loop
    # above), rather than overwriting whatever is there now.
    self_json="$(jq -n --arg p "$$" --arg s "$(_pid_start "$$")" --arg h "$myhost" \
      '{pid:($p|tonumber), pid_start:$s, hostname:$h}')"
    # atomic_write (mktemp+mv), NOT a direct `jq -n > owner.json`: a direct
    # write leaves a window where the file exists but is only partially
    # written -- a concurrent reader could jq-parse a truncated JSON body,
    # fail, and fall back to pid=0/host='?', misreading a legitimate
    # brand-new owner as dead/foreign. mv is atomic on the same filesystem:
    # readers see either no file or a complete one, never a partial one.
    printf '%s' "$self_json" | atomic_write "$lock/owner.json" 2>/dev/null
    [ "$(cat "$lock/owner.json" 2>/dev/null)" = "$self_json" ] && break
    # Lost the race for this generation -- do NOT retry the write in place;
    # someone else may legitimately own this path now. Loop back to the top.
    #
    # This retry must still count against the overall wait budget: without
    # it, a repeated run of this same residual-sliver loss (adversarial or
    # just unlucky under heavy contention) would retry the WHOLE acquire
    # forever -- never bounded by verb_lock_wait_s, the one liveness
    # guarantee this function makes. Bounded on the SAME real-elapsed-time
    # budget the live-owner wait above uses (not a separate try count):
    # mkdir winning again immediately here (no sleep at all) means this
    # path can spin far faster than the live-owner wait's ~0.2s-per-try
    # cadence, so a shared TRY count would let a burst of these losses trip
    # the budget well before wait_s real seconds had elapsed. A small sleep
    # still guards against pure busy-spinning under sustained contention.
    elapsed=$(( $(date +%s) - start_s ))
    [ "$elapsed" -lt "$wait_s" ] || \
      orchid_die "verb lock contention unresolved — self-verification kept losing the claim race (waited ${elapsed}s)"
    sleep 0.05
  done
  _verb_lock_owned=1
  export ORCHID_VERB_LOCK_HELD=1
}
# verb_lock_release <repo> -- removes the dir iff THIS process is the one
# that acquired it (guarded on `_verb_lock_owned`, a shell flag, NOT the env
# -- a nested/reentrant call must never release its parent's lock).
verb_lock_release() {
  [ "$_verb_lock_owned" = 1 ] || return 0
  rm -rf "$(orchid_runtime "$1")/verb-lock"
  _verb_lock_owned=0
  unset ORCHID_VERB_LOCK_HELD
}
# verb_lock_guard <repo> -- convenience: acquire + release-on-EXIT. Only for
# verbs with NO pre-existing EXIT trap of their own (task/journal/notify/
# answer/requirements/jobs prepare+reconcile/run advance+accept); orchid-
# plan's `apply` arm already owns an EXIT trap (temp-worktree cleanup) and
# composes by hand instead (calls verb_lock_acquire directly, then extends
# its own trap string to also call verb_lock_release) -- a second, competing
# `trap ... EXIT` here would simply clobber it rather than compose with it.
verb_lock_guard() {
  local repo="$1" q
  verb_lock_acquire "$repo" || return 1
  printf -v q '%q' "$repo"
  # ShellCheck rationale: the safely shell-quoted local path must be captured before the function returns.
  # shellcheck disable=SC2064
  trap "verb_lock_release $q" EXIT
}

epoch_current() { cat "$(orchid_runtime "$1")/epoch" 2>/dev/null || echo 0; }
epoch_require() {
  local cur; cur="$(epoch_current "$1")"
  [ "${ORCHID_EPOCH:-}" = "$cur" ] || orchid_die "stale epoch '${ORCHID_EPOCH:-unset}' (current $cur) — refused (INV-02)"
}

# -- Digest-pinned trust store (docs/specs/plugins.md, Trust model; INV-09) --
# Records live in `~/.orchid/trust` — OUTSIDE any repo, so cloning a repo can
# never itself grant code execution to a repo-local plugin. One line per
# trusted path: `<sha256-digest> <canonical-abs-path>` -- digest FIRST,
# because it's a fixed-width, space-free 64-hex token, so the path (which may
# itself contain spaces) can safely be "everything after the first space"
# rather than a single awk field. The reverse order (`<path> <digest>`)
# silently truncated any spaced path at its first space and could never
# match, which fails closed (trust never resolves) but is still wrong.

_trust_canon_path() {  # dir -> canonical absolute path (no trailing slash,
  # symlinks resolved), or nonzero if it doesn't exist / isn't a directory.
  # The trust store's own name for orchid_physical_dir (above), kept because
  # four call sites outside this file speak it; the implementation is shared
  # so there is exactly one place this repository canonicalizes a path.
  orchid_physical_dir "$1"
}

_orchid_file_sha256() {  # file -> a line binding this file's path to its
  # content hash (exact format doesn't matter -- only that it's deterministic
  # and changes with either the path or the content -- since it is never
  # compared across machines/tools, only fed into plugin_digest below).
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    printf '%s %s\n' "$(openssl dgst -sha256 "$1" | awk '{print $NF}')" "$1"
  fi
}
_orchid_symlink_sha256() {  # symlink -> a line binding this symlink's path to
  # its TARGET STRING (not the target's content -- retargeting a symlink is
  # itself a change worth catching, whether or not the new target's bytes
  # happen to match the old one's), fed into plugin_digest below.
  if command -v shasum >/dev/null 2>&1; then
    printf '%s -> %s\n' "$1" "$(readlink "$1")" | shasum -a 256
  else
    printf '%s %s\n' \
      "$(printf '%s -> %s\n' "$1" "$(readlink "$1")" | openssl dgst -sha256 | awk '{print $NF}')" "$1"
  fi
}
_orchid_stream_sha256() {  # stdin -> hex digest of the whole stream
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

# plugin_digest <dir> -- SHA-256 over a stable sorted listing of the plugin
# dir's file AND symlink entries: `find <dir> \( -type f -o -type l \) |
# LC_ALL=C sort`, then per entry a regular file contributes `shasum -a 256
# <path>` while a symlink contributes a hash of "<path> -> <target>" (its
# target string, not the target's content), and the whole per-entry listing
# is rolled up with one final `shasum -a 256` (openssl dgst -sha256 fallback
# when shasum is absent). Symlinks must be covered, not just regular files:
# `find -type f` alone never sees a symlink, so a trusted plugin whose
# entrypoint is a symlink could have its executed target swapped without
# ever moving the digest (see also orchid-plugins' `trust`, which refuses to
# trust a symlinked entrypoint in the first place). With that covered, any
# file OR symlink added, removed, renamed, changed, or repointed inside the
# dir changes this digest.
plugin_digest() {
  local dir; dir="$(_trust_canon_path "$1")" || return 1
  [ -d "$dir" ] || return 1
  find "$dir" \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then _orchid_symlink_sha256 "$f"; else _orchid_file_sha256 "$f"; fi
  done | _orchid_stream_sha256
}

# plugin_digest_content <dir> -- like plugin_digest above, but (a) EXCLUDES
# this dir's own lifecycle metadata files (`.provenance`, and
# `.installed-digest` should one ever exist) from the digest walk, and (b)
# is PATH-INDEPENDENT: it `cd`s into the canonical dir and hashes over
# RELATIVE (`./...`) paths, never the absolute one. v1-m3 Task 9 (plugin
# install/update/remove/audit):
#
#   (a) `orchid plugins install` writes `.provenance` INTO the freshly-
#   copied plugin dir and then wants to record, inside that same file, a
#   digest of the plugin's actual content -- computing the FULL
#   plugin_digest after that write would be self-referential (the recorded
#   digest would cover the very file it's being written into, and appending
#   the `installed_digest=` line would immediately invalidate the digest
#   just recorded). Excluding the metadata file(s) entirely sidesteps the
#   self-reference: this function's result is stable regardless of whether
#   `.provenance` exists yet or what it contains.
#
#   (b) `orchid plugins update` builds a replacement in a TEMP dir
#   (`<dest>.build.XXXXXX`) and computes/records installed_digest there,
#   BEFORE the atomic `mv` swap into the real `<dest>`. plugin_digest (and
#   an earlier, buggy version of this function) bakes the ABSOLUTE path
#   into every hashed line (`shasum -a 256 <path>` includes <path> in its
#   output, which is what actually gets hashed) -- so a digest computed
#   over the temp build dir's path could never again match one computed
#   over the final dest path, even with byte-identical content, and every
#   `update` would then make `audit` report "modified since install"
#   FOREVER (found in review). `cd`-ing into the dir first and walking `.`
#   makes every hashed line read `./relative/path`, identical regardless of
#   which absolute directory the plugin happens to be sitting in at hash
#   time -- so "write installed_digest against the temp build dir" and
#   "recompute later against the swapped-in final dir" are now provably
#   the same digest whenever content is unchanged.
#
# Trust-store digests (INV-09, `plugins trust`) and capsuite markers (lib/
# capsuite.sh's tested_at_marker) deliberately keep using the FULL, absolute-
# path plugin_digest, UNCHANGED from v1-m1/m2 -- that is the recorded m2
# design (a trust pin / capsuite result is tied to the exact path it was
# taken against) and out of scope for this fix.
plugin_digest_content() {
  local dir; dir="$(_trust_canon_path "$1")" || return 1
  [ -d "$dir" ] || return 1
  ( cd "$dir" && find . \( -type f -o -type l \) \
      ! -name '.provenance' ! -name '.installed-digest' | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then _orchid_symlink_sha256 "$f"; else _orchid_file_sha256 "$f"; fi
  done ) | _orchid_stream_sha256
}

_orchid_trust_dir()  { echo "$HOME/.orchid"; }
_orchid_trust_file() { echo "$(_orchid_trust_dir)/trust"; }

trust_lookup() {  # abs-dir -> the recorded digest for that exact path, or
  # empty if there is no record. Last matching line wins (append-to-override,
  # consistent with _cfg_file_get's convention elsewhere in this file). Path
  # comparison strips only the leading `<digest> ` token off each line (see
  # the record-format note above), so a path containing spaces still matches
  # whole.
  local dir="$1" f; f="$(_orchid_trust_file)"
  [ -f "$f" ] || return 0
  awk -v d="$dir" '{p=$0; sub(/^[^ ]+ /, "", p); if (p==d) v=$1} END{if (v!="") print v}' "$f"
}

trust_status_for() {  # abs-dir -> trusted|untrusted|mismatch
  local dir="$1" rec cur
  rec="$(trust_lookup "$dir")"
  [ -n "$rec" ] || { echo untrusted; return 0; }
  cur="$(plugin_digest "$dir" 2>/dev/null)" || { echo mismatch; return 0; }
  [ "$rec" = "$cur" ] && echo trusted || echo mismatch
}

trust_store_set() {  # abs-dir digest -- atomic upsert (one record per path)
  local dir="$1" digest="$2" f; f="$(_orchid_trust_file)"
  mkdir -p "$(_orchid_trust_dir)"
  { [ -f "$f" ] && awk -v d="$dir" '{p=$0; sub(/^[^ ]+ /, "", p)} p!=d' "$f"; printf '%s %s\n' "$digest" "$dir"; } | atomic_write "$f"
}

trust_store_remove() {  # abs-dir -- atomic delete of any record for that path
  local dir="$1" f; f="$(_orchid_trust_file)"
  [ -f "$f" ] || return 0
  mkdir -p "$(_orchid_trust_dir)"
  awk -v d="$dir" '{p=$0; sub(/^[^ ]+ /, "", p)} p!=d' "$f" | atomic_write "$f"
}

# ---------------------------------------------------------------------------
# The stale-root refusal (lesson L018). Last in this file because it must run
# at SOURCE time -- it decides whether any caller of this library may run at
# all -- and orchid_root_stale needs config_get, defined above.
#
# It is a refusal rather than a fourth warning on purpose. `orchid doctor`
# FAILs and `orchid status` warns on the neighbouring staleness (orchid_stale_
# checkout, the run's DURABLE state), and in a self-hosted setup -- the only
# setup that can reach the condition here -- those are the same directory, so
# an operator in this state has been told. On 2026-08-06 one read that warning
# on the very first command of the session, filed it as the known cosmetic
# trap, and then drove a run for a full day in which none of the merged
# improvements were in effect for the code actually running it. A warning that
# must be obeyed but is never enforced will be ignored, and was.
#
# Note what that costs, since nothing else in the file says it: `doctor` and
# `status` source this library like every other verb, so once the refusal
# fires the two verbs whose job is to explain it refuse too. That is why the
# message below has to carry the whole OBSERVATION itself -- naming the branch
# and the files, and the read-only commands for looking at them -- and why the
# override is worth naming in it: `ORCHID_ALLOW_STALE_ROOT=1 orchid doctor` is
# how an operator reads the rest of the picture out of a checkout in this
# state (docs/troubleshooting.md).
#
# What this must NOT become is a run that halts on its own success. `orchid
# merge` advancing the integration branch is precisely what creates the
# condition, and the checkout it advances is, in a self-hosted run, the one it
# is itself executing from -- so libexec/orchid-merge refreshes that ONE
# checkout (orchid_kernel_clean + orchid_refresh_kernel above) immediately
# after the ref moves, and shields its own remaining bookkeeping from this
# refusal. Without that, the very next child process -- `task advance <id>
# done` -- would refuse, stranding the task in `merging` with the branch
# already moved and no verb left able to say so. The refusal is for the
# checkouts nothing owns: an operator's parallel checkout of the same branch,
# and a staged kernel edit that no refresh may silently discard.
#
# Shielding the merge's own children is not enough on its own, because the
# window between the ref advance and the refresh is open to every OTHER
# process too -- an operator's `orchid status`, a heartbeat, a notify hook,
# all started from this same root and none of them a child of the merge.
#
# Those verbs REFUSE in that window, and must. The window cannot be made
# atomic -- a ref advance and a tree restore are two operations, and no
# ordering of them is atomic to a third process -- but the thing that has to
# be closed is not the interval, it is the possibility of EXECUTING the
# pre-merge tree inside it, and refusing closes that completely. An earlier
# version instead stood the refusal down for the duration, which bought a
# heartbeat its exit status by handing it the stale kernel: the failure of
# L018, reintroduced inside the fix for L018. What the marker
# (_orchid_kernel_refresh_inflight above) now buys is a truthful message --
# "a repair is in flight, nothing ran, retry" instead of a report inviting an
# operator to diagnose a condition that is repairing itself -- and a distinct
# exit status for the automation that used to survive on the tolerance.
#
# Note the reach that claim does NOT have, because an earlier draft of this
# comment claimed it and the code never delivered it. A checkout that SHARES
# the advanced ref is covered -- a linked worktree (`git worktree add`) or any
# other checkout of the same repository parked on the integration branch, all
# of which see their own HEAD move when `orchid merge` runs `update-ref`. A
# SEPARATE CLONE is not: refs are per-repository, so nothing in a clone moves
# when the origin's branch does, its working tree goes on matching its own
# HEAD, and this guard has nothing to compare. That checkout stays stale until
# someone fetches into it, and no refusal here can tell it so.
#
# This library is sourced by every libexec/orchid-* verb and every runners/*
# entry point, so there is exactly one place the check fires from and no verb
# can be written that forgets to ask (lesson L016). It is deliberately NOT in
# bin/orchid: the runners resolve their own $ORCHID_ROOT and source this file
# without ever passing through the dispatcher, and the dispatcher stays
# verb-agnostic.
#
# Being last also puts it AFTER _orchid_entry_restore_operator_path above, so
# it adds no binary lookup ahead of that restore -- the property every
# trust-boundary entry point (trust/doctor/status, and the pump, tick and
# service runners) relies on, and which they preserve here anyway by holding
# the fixed bootstrap PATH across this whole file. An ordinary verb reaches
# this line with the operator's PATH restored, exactly as it reaches every
# other `git` call it makes; this check claims no stronger boundary than the
# verb around it already has.
#
# `orchid help` and an unknown verb still answer (bin/orchid handles both
# without sourcing anything). EVERYTHING ELSE REFUSES, `doctor` and `status`
# included, and that is the deliberate answer to the obvious objection: those
# two only read, they change nothing, and an operator meeting a refusal wants
# them more than any other verb. Four reasons they are in anyway, and the
# first is the one that decides it:
#
#   * A diagnostic read out of a stale checkout is produced BY the pre-merge
#     code. `orchid doctor` in this state runs the checks the old tree
#     carries, so it can pass a checkout the merged doctor fails, and it
#     reports on the very staleness it is a symptom of. Trusting output from
#     code nobody has looked at is the whole of L018; a wrong diagnosis is
#     worse than a refusal, because the operator acts on it.
#   * There is nothing to gain. The refusal below already carries more than
#     `doctor` would say here: the branch, the staged paths, the unstaged ones
#     as context, and two read-only commands for looking at them.
#   * An exemption list is exactly how the advisory version failed. It was
#     obeyable and therefore ignored, and every exemption reopens the same
#     door for whichever verb ends up on the list next.
#   * The exemption exists already, and is better: ORCHID_ALLOW_STALE_ROOT=1
#     orchid doctor is one token, per-invocation, visible in the transcript,
#     and chosen with the observation already in front of the operator -- so
#     the staleness of what they are about to read is explicit rather than
#     silent. docs/troubleshooting.md says all of this where an operator in
#     this state will find it.
#
# And the refusal itself SAYS all four of those things, in a sentence, rather
# than leaving an operator to infer them from a tool that has apparently
# stopped working. That matters most in the case where the cause is their own
# `git add` and nothing whatever is stale: from where they stand, orchid has
# refused to run over an edit they made deliberately, and a refusal that reads
# as a broken verb is one that gets worked around rather than resolved. It is
# named as protection, with the reason and the override, in the message and in
# docs/troubleshooting.md's "Why doctor and status refuse too".
# ---------------------------------------------------------------------------

# _orchid_stale_root_die -- the refusal text. ONE arm, because this verb's job
# is to REFUSE and REPORT, and it has no business claiming to know which of
# the two causes it is looking at.
#
# The history is why that is stated so flatly. The first version asserted the
# branch-advance cause unconditionally and prescribed `git checkout HEAD --
# <kernel paths>` to clear it. Met with a HAND-EDITED kernel -- the state
# `orchid merge` itself leaves behind when it declines to refresh, so orchid
# CREATES it -- both halves were wrong at once: a cause that had not happened,
# and a remedy that silently overwrote the operator's only copy. The version
# after that added arms to classify the cause, and did the identical thing to
# a STAGED-ONLY edit, which it also read as "behind". Two rounds, two states,
# the same data-loss defect, because the classification cannot be made
# correctly from what is observable here (orchid_root_stale says why).
#
# So the rule, and it removes the class rather than the state last seen: say
# what was OBSERVED, say plainly that the cause is not determinable from it,
# and print nothing that can discard work. The only commands here are
# read-only ones for LOOKING. The operator resolves it -- they are the one
# party who knows whether they staged that edit.
#
# One exception is provided for in principle and does not fire in practice: a
# state provably BEHIND with a clean tree could carry a bare restore, since
# every byte it overwrote would already be in the object store. There is no
# proof available (again, orchid_root_stale). Rather than approximate one for
# a third time, no restore is printed at all. docs/troubleshooting.md carries
# the repair options in a place that can spell out what each one costs.
#
# `orchid merge`'s automatic refresh is untouched by this and is NOT the same
# judgment: it is gated on orchid_kernel_clean asked BEFORE the ref moves, at
# a moment when "nothing uncommitted exists here" is a fact rather than an
# inference. That is why the self-healing path may write and this may not.
_orchid_stale_root_die() {
  local root="${ORCHID_ROOT:-unknown}" at="${ORCHID_ROOT:-.}" nl idx mods also
  nl=$'\n'
  idx="${ORCHID_ROOT_STALE_INDEX:-}"
  idx="${idx//$nl/ }"
  mods="${ORCHID_ROOT_STALE_UNSTAGED:-}"
  mods="${mods//$nl/ }"
  # The fail-closed sentinel from the context read, spelled out rather than
  # printed raw: "modified: ?" reads like a filename.
  [ "$mods" != '?' ] || mods="(this checkout's git could not list them)"
  also=""
  [ -z "$mods" ] || also=" ALSO OBSERVED, and not part of why this refuses: kernel files modified in the working tree and not staged — $mods."
  orchid_die "refusing to run: the checkout orchid itself runs from ($root) sits on the integration branch '$ORCHID_ROOT_STALE_BRANCH', and its INDEX does not match HEAD for the code orchid executes: $idx. Every verb, lib, runner, engine adapter, role profile and the PROTOCOL.md a tick follows are read from THIS working tree, so orchid stops here rather than run something nobody has looked at.$also
This is a report, not a diagnosis. Two different things leave an index that does not match HEAD and they are indistinguishable from here: 'orchid merge' advancing this branch with update-ref, which moves HEAD and leaves the index describing the commit it moved off (lesson L018 — a merged fix stayed inert for two further rounds because the launcher went on executing pre-merge code), or a kernel edit staged here with 'git add'. orchid will not guess between them, and prints no command that could discard your work: the remedy for one of those is a silent data loss in the other.
LOOK FIRST — both of these are read-only: \"git -C $at status --short -- ${ORCHID_KERNEL_PATHS[*]}\" and \"git -C $at diff --cached HEAD -- ${ORCHID_KERNEL_PATHS[*]}\". Then resolve it yourself, whichever it turns out to be. docs/troubleshooting.md 'Stale orchid itself' walks the options and says what each one costs. Note that the pathspec above names orchid's own code and nothing else: uncommitted .orchid run state and a pending orchid.config edit are outside it, and orchid neither inspects nor restores them. To run one command anyway: ORCHID_ALLOW_STALE_ROOT=1 orchid ...
This stops EVERY verb, 'doctor' and 'status' included, and in both of the two cases above — including the one where nothing is stale and your own staged edit is what orchid cannot tell apart from a branch advance. That is orchid protecting you rather than orchid broken: a diagnosis read out of a checkout that IS stale is produced by the stale checks themselves, so the two verbs you would reach for first are the two whose answers could not be trusted here. Nothing was run and nothing here was changed. docs/troubleshooting.md 'Why doctor and status refuse too' has the whole argument and the one-line way to read them anyway."
}

# _orchid_stale_root_inflight_die -- the same refusal, worded for the one
# state in which the checkout is knowably being repaired as it is read: an
# `orchid merge` from this very root is between its ref advance and its
# restore (_orchid_kernel_refresh_inflight above).
#
# It REFUSES like the other arm. What is different is only what the operator
# is told to do about it, and that difference is the entire reason the marker
# is worth a file: here the state clears itself within a moment and there is
# nothing to decide, so sending anyone to `git diff --cached` would be sending
# them to diagnose a condition that repaired itself while they read.
#
# A distinct exit status, because the callers this most affects are not
# people. A heartbeat, a notify hook or a scheduler that starts in the window
# used to be handed the pre-merge kernel and a zero exit; it now fails, and
# telling it "retry" apart from "an operator must look at this checkout" is
# what keeps that from becoming a page for a condition that resolves in a
# second. 75 is sysexits' EX_TEMPFAIL, it is used nowhere else in orchid, and
# it is the ONLY temporary refusal here: every other arm of this guard needs a
# human and exits 1.
ORCHID_STALE_ROOT_TEMPFAIL=75
_orchid_stale_root_inflight_die() {
  echo "orchid: refusing to run: an 'orchid merge' started from this same checkout (${ORCHID_ROOT:-unknown}) has just advanced '$ORCHID_ROOT_STALE_BRANCH' and is restoring this checkout's kernel files to it right now. Until that finishes, this working tree still holds the PRE-MERGE code, and running a verb out of it is the exact failure this guard exists for (lesson L018) — so nothing was run, and nothing here was changed. Waiting would not help this process: it has already read its libraries off the pre-merge tree, so only a fresh invocation can pick up the merged ones.
Retry in a moment — the window is one ref advance and one restore wide. If retrying keeps reporting this, the merge died mid-restore; the next command after its process is gone reports the full state of this checkout instead, and docs/troubleshooting.md 'Stale orchid itself' takes it from there. Exit $ORCHID_STALE_ROOT_TEMPFAIL means 'temporary, retry' and is used for nothing else." >&2
  exit "$ORCHID_STALE_ROOT_TEMPFAIL"
}

# Which refusal, never whether. `orchid merge`'s own advance-then-refresh
# window is asked about LAST, so it costs nothing until a refusal is already
# certain, and so the ordering the branch check owes the unattended-trust gate
# is unchanged: it reads only under $ORCHID_ROOT and spawns no `git`.
if [ "${ORCHID_ALLOW_STALE_ROOT:-}" != 1 ] && orchid_root_stale; then
  if _orchid_kernel_refresh_inflight "${ORCHID_ROOT:-}"; then
    _orchid_stale_root_inflight_die
  fi
  _orchid_stale_root_die
fi
