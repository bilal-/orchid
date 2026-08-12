#!/usr/bin/env bash
# THE SOURCE-TREE SNAPSHOT MUST NOT PASS VACUOUSLY OUTSIDE A GIT CHECKOUT (T004).
#
# tests/test_e2e_release_rehearsal.sh's whole point is the claim that the tree
# it ran from is read-only input: working tree, file listing, HEAD and remote
# refs, compared before and after. Three of those four are Git questions.
#
# tests/run.sh globs test_*.sh, and the suite is deliberately runnable inside an
# extracted release archive -- scripts/release.sh unpacks one and runs
# scripts/ci-local.sh inside it, and tests/test_ci_release.sh skips its
# Git-dependent checks there by design. An archive has no `.git` at its root, so
# in that context all three Git questions answer the empty string BEFORE and
# AFTER alike: the comparison holds, reports the tree as untouched, and has
# compared a tree that was never at risk. docs/install.md's release-day step 5
# prescribes running the rehearsal, which is what makes it worth proving rather
# than arguing about.
#
# So the snapshot now establishes its context first (tests/helpers.sh's
# source_tree_is_checkout / snapshot_source_tree / note_source_tree_context),
# states it on the snapshot's own first line, drops the Git sections when they
# cannot be asked, keeps comparing the file listing -- real evidence in either
# context -- and records the rest as not-tested, never as a pass.
#
# This file is the focused proof of that logic. It costs a few scratch
# repositories rather than the whole rehearsal.
#
# RED: the Git-only snapshot really is blind outside a checkout -- the exact
#      vacuity this change removed is reproduced here and watched to hold, with
#      the same modification caught in a checkout as the control; an archive
#      unpacked INSIDE an unrelated repository is refused as a checkout of
#      itself even though Git answers a toplevel for it; a tree that loses its
#      Git metadata mid-run reads as a DIFFERENCE rather than as a quiet
#      downgrade; and outside a checkout the not-tested record is really
#      written, and counted, by a real process.
# GREEN: in a Git checkout the same snapshot detects a content-only edit, a new
#      untracked file, and returns to its original value when the edit is
#      undone -- so the rejections above are the context reaching the check
#      rather than a snapshot that differs from everything, or from itself. In
#      an archive the file-listing half still catches a file created beside the
#      tree's content, and a real checkout records nothing as not-tested.
source "$(dirname "$0")/helpers.sh"

# ===========================================================================
# 0 -- fixtures. Three trees with the same content and different contexts, so
# every difference below is attributable to the context and to nothing else.
# ===========================================================================
mk_tree() {  # <dir> -- the payload an extracted archive would have
  local d="$1"
  mkdir -p "$d/sub"
  printf 'payload\n' > "$d/a.txt"
  printf 'nested payload\n' > "$d/sub/b.txt"
}
mk_checkout() {  # <dir> -- the same payload, committed
  local d="$1"
  mk_tree "$d"
  git -C "$d" init -q || fail "cannot create the checkout fixture at $d"
  git -C "$d" add -A
  git -C "$d" commit -q -m "fixture payload"
}

CHECKOUT="$WORK/checkout"
ARCHIVE="$WORK/archive"
ENCLOSING="$WORK/enclosing"
ENCLOSED="$ENCLOSING/orchid-1.2.3"
mk_checkout "$CHECKOUT"
mk_tree "$ARCHIVE"
mkdir -p "$ENCLOSING"
git -C "$ENCLOSING" init -q || fail "cannot create the enclosing-repository fixture"
mk_tree "$ENCLOSED"

# The extracted-archive fixture has to be a tree Git cannot answer for AT ALL,
# or section 2's demonstration of the blind spot is measuring something else.
# Asserted rather than assumed: it depends on where mktemp puts scratch trees.
archive_toplevel="$(git -C "$ARCHIVE" rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$archive_toplevel" ] \
  || fail "the extracted-archive fixture sits inside a repository (git reports '$archive_toplevel'), so it cannot stand in for an unpacked release archive"

# ===========================================================================
# 1 -- the predicate. It is what decides whether the Git half of the claim is
# made at all, so it is asked directly rather than inferred from a snapshot.
# ===========================================================================
source_tree_is_checkout "$CHECKOUT" \
  || fail "a real checkout must be recognized as one -- otherwise every run would record its Git state as not-tested and the claim would never be made anywhere"
green_case 'the context predicate recognizes a real Git checkout'

source_tree_is_checkout "$ARCHIVE" \
  && fail "a tree with no Git metadata was accepted as a checkout, so its empty Git answers would be compared as though they meant something"

# The enclosed case is the one a "does git answer anything?" test gets wrong:
# git DOES answer here, about a different tree.
enclosed_toplevel="$(git -C "$ENCLOSED" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$enclosed_toplevel" ] \
  || fail "the enclosed-archive fixture is not inside a repository at all, so it cannot demonstrate the case it exists for"
[ "$enclosed_toplevel" != "$ENCLOSED" ] \
  || fail "the enclosed-archive fixture became a checkout of itself, so it no longer stands for an archive unpacked inside someone else's repository"
source_tree_is_checkout "$ENCLOSED" \
  && fail "an archive unpacked inside an unrelated repository was accepted as its own checkout -- every Git answer about it describes the ENCLOSING repository's working tree, HEAD and refs"

# An empty argument must be refused outright: `cd ""` is a silent no-op, so a
# predicate that canonicalized it would answer about the CALLER's directory.
source_tree_is_checkout "" \
  && fail "an empty path was accepted as a checkout -- the answer would have been about whatever directory the caller happened to be in"
source_tree_is_checkout "$WORK/never-created" \
  && fail "a path that does not exist was accepted as a checkout"
red_case 'the context predicate refuses a tree with no Git metadata, an archive unpacked inside an unrelated repository, an empty path and a missing one'

# ===========================================================================
# 2 -- THE VACUITY, DEMONSTRATED. The shape this change removed, reproduced
# here as a local function: three Git questions and nothing else. It is fed the
# same modification in both contexts, so what differs is the context.
# ===========================================================================
legacy_snapshot() {  # <dir> -- the Git-only snapshot, exactly as it was
  git -C "$1" status --porcelain=v1 --untracked-files=all -- ':!.orchid' 2>/dev/null
  echo "--remote-refs--"
  git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/remotes 2>/dev/null
  echo "--head--"
  git -C "$1" rev-parse HEAD 2>/dev/null
}

legacy_archive_before="$(legacy_snapshot "$ARCHIVE")"
printf 'modified by the run under test\n' > "$ARCHIVE/a.txt"
assert_eq "$legacy_archive_before" "$(legacy_snapshot "$ARCHIVE")" \
  "the Git-only snapshot is identical before and after a real modification outside a checkout, which is why comparing it there proved nothing (if this assertion ever fails, the vacuity is gone and this file's reason to exist must be re-read)"
printf 'payload\n' > "$ARCHIVE/a.txt"

# The control. Without it, the line above would be satisfied by a modification
# nothing could see rather than by a context that cannot see it.
legacy_checkout_before="$(legacy_snapshot "$CHECKOUT")"
printf 'modified by the run under test\n' > "$CHECKOUT/a.txt"
[ "$legacy_checkout_before" != "$(legacy_snapshot "$CHECKOUT")" ] \
  || fail "the same modification was invisible to the same Git-only snapshot in a real checkout, so the archive result above says nothing about the context"
printf 'payload\n' > "$CHECKOUT/a.txt"
red_case 'the Git-only snapshot reported an extracted archive as unchanged after a modification it caught in a checkout'

# ===========================================================================
# 3 -- the replacement, in a checkout: it detects, it accepts, and it is stable.
# ===========================================================================
checkout_before="$(snapshot_source_tree "$CHECKOUT")"
grep -qF 'source-context-- git-checkout' <<<"$checkout_before" \
  || fail "a checkout's snapshot must say so on its own first line: $checkout_before"
grep -qF 'head--' <<<"$checkout_before" \
  || fail "a checkout's snapshot must carry the HEAD it can read"

# Content only -- no name is created or removed, so this is exactly the change
# the file listing alone cannot see.
printf 'modified by the run under test\n' > "$CHECKOUT/a.txt"
checkout_modified="$(snapshot_source_tree "$CHECKOUT")"
[ "$checkout_before" != "$checkout_modified" ] \
  || fail "a content-only edit in a checkout must change the snapshot"
assert_match '^ M a\.txt$' "$checkout_modified" \
  "the working-tree half must name the file it saw change"
printf 'payload\n' > "$CHECKOUT/a.txt"
assert_eq "$checkout_before" "$(snapshot_source_tree "$CHECKOUT")" \
  "undoing the edit must restore the snapshot exactly -- a snapshot that never compares equal to itself would satisfy every detection assertion above while detecting nothing"

printf 'stray\n' > "$CHECKOUT/stray.txt"
[ "$checkout_before" != "$(snapshot_source_tree "$CHECKOUT")" ] \
  || fail "a file created in a checkout must change the snapshot"
rm -f "$CHECKOUT/stray.txt"

git -C "$CHECKOUT" commit -q --allow-empty -m "a commit into the tree under test"
[ "$checkout_before" != "$(snapshot_source_tree "$CHECKOUT")" ] \
  || fail "a commit into the tree under test must change the snapshot -- that is what the HEAD half is for"
git -C "$CHECKOUT" reset -q --hard HEAD~1
assert_eq "$checkout_before" "$(snapshot_source_tree "$CHECKOUT")" \
  "undoing that commit must restore the snapshot exactly"
green_case 'in a checkout the snapshot caught a content-only edit, a new file and a commit, and compared equal to itself again once each was undone'

# ===========================================================================
# 4 -- the replacement, outside one: labelled, honest about its scope, and
# still comparing the half that remains real.
# ===========================================================================
archive_before="$(snapshot_source_tree "$ARCHIVE")"
grep -qF 'source-context-- no-git-metadata' <<<"$archive_before" \
  || fail "a snapshot taken outside a checkout must say so on its own first line: $archive_before"
grep -qF 'head--' <<<"$archive_before" \
  && fail "the snapshot carried a Git section it could not fill -- an empty '--head--' reads in a log exactly like a HEAD that did not move"
grep -qF 'worktree--' <<<"$archive_before" \
  && fail "the snapshot carried a working-tree section it could not fill"

printf 'stray\n' > "$ARCHIVE/stray.txt"
[ "$archive_before" != "$(snapshot_source_tree "$ARCHIVE")" ] \
  || fail "the file-listing half must still catch a file created beside an archive's own content -- it is the part that stays real in both contexts, and deleting the assertion instead of scoping it would have lost it"
rm -f "$ARCHIVE/stray.txt"
assert_eq "$archive_before" "$(snapshot_source_tree "$ARCHIVE")" \
  "removing that file must restore the snapshot exactly"
green_case 'outside a checkout the snapshot still caught a file created beside the tree content, and compared equal to itself once it was removed'

# The gap that the not-tested record exists for, stated as a fact rather than
# as a caveat: a content-only change is invisible here.
printf 'content changed in place\n' > "$ARCHIVE/sub/b.txt"
assert_eq "$archive_before" "$(snapshot_source_tree "$ARCHIVE")" \
  "outside a checkout a change to the CONTENT of a file that was already there is invisible to the file listing -- which is exactly why that claim must be RECORDED as not-tested rather than reported as a pass"
printf 'nested payload\n' > "$ARCHIVE/sub/b.txt"

# ===========================================================================
# 5 -- losing the Git metadata mid-run is a DIFFERENCE. Without the context on
# the snapshot's own first line, a tree that stopped being a checkout between
# the two snapshots would quietly narrow what the comparison covered and still
# compare equal on the half that was left.
# ===========================================================================
FLIP="$WORK/flip"
mk_checkout "$FLIP"
flip_before="$(snapshot_source_tree "$FLIP")"
rm -rf "$FLIP/.git"
flip_after="$(snapshot_source_tree "$FLIP")"
[ "$flip_before" != "$flip_after" ] \
  || fail "a tree that stopped being a checkout mid-run compared equal to its own earlier snapshot, so the comparison silently covered less than it claimed"
grep -qF 'source-context-- git-checkout' <<<"$flip_before" \
  || fail "the pre-flip snapshot must record the checkout context it was taken in"
grep -qF 'source-context-- no-git-metadata' <<<"$flip_after" \
  || fail "the post-flip snapshot must record the context it was taken in"
red_case 'a tree that lost its Git metadata between two snapshots was reported as a difference instead of quietly narrowing the claim'

# ===========================================================================
# 6 -- THE RECORD ITSELF, written by a real process. A skip that is silent is
# indistinguishable in a log from a check that ran, which is the whole defect
# this change is about -- so the not-tested line, its count, and the EXIT
# summary that carries it are exercised rather than assumed.
# ===========================================================================
NOTE_FIXTURE="$WORK/note-context-fixture.sh"
cat > "$NOTE_FIXTURE" <<EOF
#!/usr/bin/env bash
source "$REPO_ROOT/tests/helpers.sh"
EOF
# Quoted heredoc for the body: the fixture's own positional argument and the
# counter it reports are its, not this file's, and must reach it unexpanded.
cat >> "$NOTE_FIXTURE" <<'EOF'
note_source_tree_context "$1" || true
echo "COUNT=$NOT_TESTED"
EOF

note_checkout_out="$("$BASH" "$NOTE_FIXTURE" "$CHECKOUT" 2>&1)"
grep -qF 'COUNT=0' <<<"$note_checkout_out" \
  || fail "a run from a real checkout must record nothing as not-tested -- it tests all of it: $note_checkout_out"
grep -qF 'NOT-TESTED' <<<"$note_checkout_out" \
  && fail "a run from a real checkout recorded a claim as not-tested that it could have tested: $note_checkout_out"
green_case 'a run from a real checkout recorded no not-tested claim, so the record below is the context and not the helper announcing itself everywhere'

note_archive_out="$("$BASH" "$NOTE_FIXTURE" "$ARCHIVE" 2>&1)"
grep -qF 'COUNT=1' <<<"$note_archive_out" \
  || fail "a run outside a checkout must COUNT the claim it did not test, or the file's summary cannot report it: $note_archive_out"
assert_match 'NOT-TESTED: source-tree-git-state' "$note_archive_out" \
  "the record must name the claim that was not tested"
assert_match 'not-tested: 1 claim' "$note_archive_out" \
  "the EXIT summary must carry the count, so a reader of a suite log sees that the claim was not made"
assert_match 'docs/install.md' "$note_archive_out" \
  "the record must say how to qualify the claim out of band, rather than leaving a reader with an absence"
red_case 'a run outside a checkout wrote, counted and summarised the Git-state claim as not-tested instead of comparing three empty answers and passing'

# ===========================================================================
# 7 -- the rehearsal is wired to this, and has not re-grown a private snapshot
# of its own source tree.
# ===========================================================================
REHEARSAL="$REPO_ROOT/tests/test_e2e_release_rehearsal.sh"
[ -f "$REHEARSAL" ] \
  || fail "tests/test_e2e_release_rehearsal.sh is gone -- it is the consumer everything above exists for"
# The needles name a variable, so the `$` is assembled rather than written
# inside single quotes -- same reason tests/test_ci_release.sh assembles the
# tokens it searches for.
dollar='$'
repo_root_ref="\"${dollar}REPO_ROOT\""
grep -qF "snapshot_source_tree $repo_root_ref" "$REHEARSAL" \
  || fail "the rehearsal no longer snapshots its source tree through the context-aware helper this file proves"
grep -qF "note_source_tree_context $repo_root_ref" "$REHEARSAL" \
  || fail "the rehearsal no longer records what its source-tree comparison could not test, so an extracted-archive run would report the claim as a pass again"
rehearsal_direct_git="$(grep -nF "git -C $repo_root_ref" "$REHEARSAL" || true)"
[ -z "$rehearsal_direct_git" ] \
  || fail "the rehearsal asks Git about its own source tree directly again, outside the helper that establishes whether the question can be answered: $rehearsal_direct_git"

# docs/install.md prescribes the rehearsal as a release-day step, so what that
# run proves and what the page says it proves have to move together. The prose
# itself is pinned in tests/test_docs.sh; this is the direction that matters
# here -- the step must still name the file whose guarantee just changed.
grep -qF 'tests/test_e2e_release_rehearsal.sh' "$REPO_ROOT/docs/install.md" \
  || fail "docs/install.md's release-day steps no longer name the rehearsal"

not_tested "rehearsal-executed-inside-a-real-extracted-archive" \
  "the whole rehearsal run end to end from an unpacked release archive. It stands up a private root and walks setup, the unattended refusal, an acknowledgement, qualification, a deterministic drive, the release gate and the installer, which takes minutes; what is proven here is the snapshot logic that run now calls, in both contexts, plus the wiring that it calls it. Qualify the end-to-end shape by unpacking a built archive and running tests/run.sh inside it on release day"
