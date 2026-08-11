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

# ORCHID_KERNEL_PATHS -- the directories bin/orchid EXECUTES from: the verb,
# the libraries it sources, the runner it hands off to, the engine adapter
# that runner spawns, the role profile and prompt template given to that
# engine. ONE list, because three separate consumers have to agree on it or
# the guard below and the refresh that clears it drift apart (lesson L016):
# orchid_root_stale asks whether these paths match HEAD, orchid_kernel_clean
# asks whether anything local would be lost by restoring them, and
# orchid_refresh_kernel restores exactly them.
#
# What is deliberately NOT here is as load-bearing as what is. `.orchid/`
# above all -- uncommitted durable run state is never inspected, never
# compared and never written by any of the three -- but also `orchid.config`
# (an operator edit awaiting `orchid config commit` is legitimate and
# uncommitted by definition), README/docs, and test fixtures. None of them
# changes which code the launcher runs, so none of them can refuse a command
# and none of them is ever restored out from under an operator.
ORCHID_KERNEL_PATHS=(bin lib libexec runners plugins roles skills templates)

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
#      orchid_stale_checkout uses, and the whole reason an ordinary DIRTY
#      DEVELOPMENT checkout is unaffected. Development happens on `main`, on
#      a feature branch, in a task worktree; none of them is the branch a run
#      merges onto, so none of them can be advanced by `orchid merge` behind
#      anyone's back and none of them is ever asked about here, however dirty
#      it is. The integration branch is the one place where "the working tree
#      differs from HEAD" means "someone merged and this checkout did not
#      notice" rather than "someone is editing".
#   2. The kernel code on disk actually differs from HEAD's. Comparing
#      CONTENT rather than trying to infer WHO moved the ref is what makes
#      this robust: `git update-ref` leaves no fingerprint that reliably
#      distinguishes an advance made from this checkout's own process from
#      one made elsewhere, but it never updates a working tree, so the
#      content is behind either way. It is also the self-healing half -- the
#      refresh the refusal recommends restores exactly these paths, so
#      running it clears the refusal and nothing else has to.
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
# Read-only: it only ever inspects, exactly like orchid_stale_checkout. The
# branch it found is published so the refusal below can name it.
orchid_root_stale() {
  local root="${1:-${ORCHID_ROOT:-}}" integ cur drift
  # config_get reads "$HOME/.orchid/config" unguarded, and this is the one
  # caller that runs at SOURCE time -- ahead of any verb's own environment
  # setup, and in a headless context (launchd, cron) where HOME can genuinely
  # be unset. A `local` shadow is dynamically scoped, so config_get below sees
  # it and nothing outside this function does: an unset HOME becomes "no user
  # config layer" here rather than an `unbound variable` abort in every verb.
  local HOME="${HOME:-}"
  [ -n "$root" ] || return 1
  cur="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$cur" ] || return 1
  integ="$(config_get "$root" integration_branch orchid/integration)"
  [ "$cur" = "$integ" ] || return 1
  # ORCHID_KERNEL_PATHS, never a literal list repeated here: see its own
  # comment above for what is deliberately outside it, and orchid_refresh_
  # kernel below for the restore that has to agree with it path for path. A
  # `git diff` pathspec that matches nothing is not an error, so a root
  # missing one of those directories is simply judged on the ones it has.
  drift="$(git -C "$root" diff --name-only HEAD -- \
    "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null || true)"
  [ -n "$drift" ] || return 1
  ORCHID_ROOT_STALE_BRANCH="$cur"
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

# orchid_refresh_kernel <root> -- bring <root>'s kernel paths to HEAD, so a
# checkout that fell behind its own branch runs the code that branch now
# carries. The ONLY writer in this family; every other helper here inspects.
#
# Callers MUST have established orchid_kernel_clean first (see above). Under
# that precondition every path this touches was, moments earlier, byte-equal
# to the commit HEAD has just moved off, so nothing uncommitted exists for it
# to destroy. Nothing outside ORCHID_KERNEL_PATHS is read or written at all --
# `.orchid/` run state and a pending `orchid.config` edit are not merely
# preserved, they are never named.
#
# Why not the one-liner `git checkout HEAD -- <paths>`: it restores modified
# and missing files, but it does NOT remove a file the new HEAD no longer
# carries. That path stays in the index, `git diff HEAD` keeps reporting it,
# and the refusal the refresh was supposed to clear survives the remedy --
# an operator following the instruction verbatim and watching it not work.
# So each drifted path is reset to HEAD first, and then either checked out
# (HEAD still has it: modified, or missing here because the branch added it)
# or deleted (HEAD no longer has it). The reset is also what restores the
# recorded FILE MODE, which is what makes a newly merged libexec verb
# executable rather than a 644 file bin/orchid silently reports as unknown.
#
# Returns non-zero if any path could not be restored, leaving the refusal in
# place for the operator rather than reporting a refresh that did not happen.
orchid_refresh_kernel() {
  local root="$1" drift p rc=0 top top_phys root_phys
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
  drift="$(git -C "$root" diff --name-only HEAD -- \
    "${ORCHID_KERNEL_PATHS[@]}" 2>/dev/null || echo '?')"
  [ "$drift" != '?' ] || return 1
  [ -n "$drift" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # The one path that is drift by git's reckoning and operator property by
    # every other: a file sitting on disk that this checkout does not TRACK,
    # at a name the branch has since added a tracked file under. The index
    # has no entry for it, so `git diff HEAD` reports the path as DELETED --
    # indistinguishable, from the drift list alone, from a merged file that
    # simply has not been written here yet -- and the reset-then-checkout
    # below would overwrite it without a word. That is the r-001 journal-loss
    # shape one directory over, and the reason orchid_kernel_clean's promise
    # that "untracked files are never touched by the restore" needs enforcing
    # HERE rather than being inferred from it: that precondition is evaluated
    # before the ref moves, when this path was not drift at all.
    #
    # Asked BEFORE the reset, which would itself create the index entry that
    # makes the file look tracked. Declining costs a refusal the operator
    # clears by hand, having seen the file; overwriting costs a file only
    # they had a copy of.
    if [ -e "$root/$p" ] \
       && ! git -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      rc=1; continue
    fi
    git -C "$root" reset -q HEAD -- "$p" >/dev/null 2>&1 || { rc=1; continue; }
    if git -C "$root" cat-file -e "HEAD:$p" 2>/dev/null; then
      git -C "$root" checkout -q -- "$p" >/dev/null 2>&1 || rc=1
    else
      rm -f "$root/$p" || rc=1
    fi
  done <<< "$drift"
  return "$rc"
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
  ( cd "$1" 2>/dev/null && pwd -P )
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
# message below has to carry the whole diagnosis and the exact remedy itself,
# and why the override is worth naming in it -- `ORCHID_ALLOW_STALE_ROOT=1
# orchid doctor` is how an operator reads the rest of the picture out of a
# checkout in this state (docs/troubleshooting.md).
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
# checkouts nothing owns: a second clone, an operator's parallel checkout, a
# hand-edited kernel that no refresh may silently discard.
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
# without sourcing anything). Everything else refuses, diagnostics included:
# the message below names the exact remedy, which is more than `doctor` tells
# an operator in this state, and an exemption list is precisely how the
# advisory version failed. ORCHID_ALLOW_STALE_ROOT=1 is the deliberate way to
# run one command anyway -- explicit, per-invocation, visible in the
# transcript, and the way to read state out of a checkout mid-recovery.
# ---------------------------------------------------------------------------
if [ "${ORCHID_ALLOW_STALE_ROOT:-}" != 1 ] && orchid_root_stale; then
  orchid_die "refusing to run: the checkout orchid itself runs from (${ORCHID_ROOT:-unknown}) sits on the integration branch '$ORCHID_ROOT_STALE_BRANCH' and its kernel files do not match HEAD — that branch was advanced without this working tree being refreshed (which is what 'orchid merge' does, by design), so every verb, lib, runner and engine adapter here would execute PRE-MERGE code (lesson L018). Refresh it with \"git -C ${ORCHID_ROOT:-.} checkout HEAD -- ${ORCHID_KERNEL_PATHS[*]}\" — that names orchid's own code and nothing else, so uncommitted .orchid run state and a pending orchid.config edit are not touched. If the refusal survives that, the branch DELETED a kernel file this checkout still has; see docs/troubleshooting.md 'Stale orchid itself'. To run this one command anyway: ORCHID_ALLOW_STALE_ROOT=1 orchid ..."
fi
