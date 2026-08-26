#!/usr/bin/env bash
set -uo pipefail
# Manual probe (NOT run by tests/run.sh — see tests/probes/README.md).
#
# ============================================================================
# WHICH OF T027's CLAIMED FIXES WERE ACTUALLY BROKEN AT THE PARENT?
# ============================================================================
#
# T027's tests assert a pile of behaviour about jobs that never launched, and
# their prose says which of it is newly fixed. Nothing checks that prose --
# which is exactly how a wrong label got in. The F41 "pid is gone" case was
# written up as a newly fixed shape; the parent already reaped that manifest
# with the very call the case makes. A wrong RED label is worse than no label:
# it invents a defect, and the assertion that supposedly proves the fix passes
# on the parent too, so it can never fail and running the suite can never
# catch it.
#
# This probe settles it MECHANICALLY. It materialises the parent commit's
# whole tree, drives the SAME seeded fixture through the parent's binary and
# through this checkout's, and derives, per behaviour:
#
#   NEW-FIX       the parent is wrong here and the candidate is right
#   PRE-EXISTING  BOTH are right -- the candidate did not fix this, so a test
#                 asserting it is a regression tripwire, not a proof
#   REGRESSED     the parent was right and the candidate is wrong
#   UNFIXED       neither is right
#
# Each row also carries the classification T027's own narrative claims for it.
# A mismatch names the row and exits non-zero. So this is not a report to be
# read and interpreted: it is T027's RED claims, made checkable.
#
# Free. No engine CLI is invoked, no quota is spent, nothing outside a
# temporary directory is written -- which is why it sits beside the billed
# probes here rather than under tests/, and why the README's quota warning
# does not name it.
#
# It is out of tests/run.sh because it needs a parent ref to compare against,
# and a suite that guessed one would go silently vacuous the moment this work
# merged: the "parent" it found would already contain the fix, and every RED
# row would flip to PRE-EXISTING for a reason that has nothing to do with the
# code. So the ref is an argument, and never defaulted.
#
# USAGE
#   bash tests/probes/probe-t027-parent-red.sh <parent-ref>
#
# For the candidate as reviewed, <parent-ref> is T027's recorded base_sha --
# `git log --oneline` shows it as the last commit before the first `T027:` one:
#
#   bash tests/probes/probe-t027-parent-red.sh f875aee
#
# The ref is validated: it must be an ancestor of HEAD, and its copies of the
# files T027 changed must actually differ from HEAD's. Pointing this at the
# candidate itself aborts instead of printing a page of PRE-EXISTING.
#
# WHAT THIS DOES NOT COVER, and why -- stated because a proof harness that
# quietly stops short reads as "everything is proved":
#
#   * runners/orchid-drive's launch-failure handling (a non-zero launcher exit
#     journaled and charged one rung; one orphan manifest per slot rather than
#     one per pass). Reaching that code needs a fully planned run -- init, an
#     integration branch, imported requirements, `plan apply` -- against BOTH
#     trees, which is a fixture several times the size of everything below and
#     a far larger surface for the harness itself to be wrong on.
#     tests/test_drive.sh Part T owns those assertions; to see the parent side
#     by hand, extract the parent tree (`git archive <ref> | tar -x -C /tmp/p`)
#     and re-run Part T's fixture with $DRIVE and $ORCHID_BIN pointed at it.
#   * The pack-budget resolution ORDER itself (as opposed to `doctor` printing
#     the resolved value, which is row 8). It is a property of lib/common.sh's
#     config_get, which T027 did not change -- the finding was that nothing
#     PRINTED the resolved value, and that is what row 8 checks.
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-Orchid Probe}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-orchid-probe@example.invalid}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

die() { echo "probe: $*" >&2; exit 2; }

PARENT_REF="${1:-}"
[ -n "$PARENT_REF" ] \
  || die "usage: bash tests/probes/probe-t027-parent-red.sh <parent-ref>  (T027's base_sha; never defaulted -- see this file's header)"

command -v jq >/dev/null 2>&1 || die "jq is required"
git -C "$REPO_ROOT" rev-parse --verify "$PARENT_REF^{commit}" >/dev/null 2>&1 \
  || die "'$PARENT_REF' is not a commit in this repository"
PARENT_SHA="$(git -C "$REPO_ROOT" rev-parse "$PARENT_REF^{commit}")"
git -C "$REPO_ROOT" merge-base --is-ancestor "$PARENT_SHA" HEAD \
  || die "'$PARENT_REF' is not an ancestor of HEAD -- comparing against an unrelated commit proves nothing"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/orchid-t027-parent.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
PARENT_TREE="$TMP/parent"
mkdir -p "$PARENT_TREE"
git -C "$REPO_ROOT" archive "$PARENT_SHA" | tar -x -C "$PARENT_TREE" \
  || die "could not materialise $PARENT_SHA"

# VACUITY GUARD. Every row below is a difference between two trees; if the two
# trees agree on the file a row exercises there is no difference to find, and a
# clean run would mean nothing at all. Checked per file rather than in
# aggregate, so a ref that is parent-shaped for one verb and not the other is
# caught instead of averaged away.
for probe_f in libexec/orchid-jobs libexec/orchid-doctor; do
  [ -f "$PARENT_TREE/$probe_f" ] || die "$PARENT_SHA has no $probe_f"
  if cmp -s "$PARENT_TREE/$probe_f" "$REPO_ROOT/$probe_f"; then
    die "$PARENT_SHA's $probe_f is identical to this checkout's -- that ref is not the parent of the change being proved"
  fi
done

PARENT_BIN="$PARENT_TREE/bin/orchid"
CAND_BIN="$REPO_ROOT/bin/orchid"
[ -x "$PARENT_BIN" ] || die "$PARENT_BIN is not executable (git archive should have preserved the mode)"

echo "probe: parent    $PARENT_SHA  $(git -C "$REPO_ROOT" log -1 --format=%s "$PARENT_SHA")"
echo "probe: candidate $(git -C "$REPO_ROOT" rev-parse HEAD)  $(git -C "$REPO_ROOT" log -1 --format=%s HEAD)"
echo

FAILURES=0
ROWS=0

# report <id> <expected-verdict> <parent-correct 0|1> <candidate-correct 0|1> <detail>
#
# "correct" means: exhibits the behaviour T027's tests assert. The verdict is
# DERIVED from the pair; the caller only states which verdict it expects, which
# is the claim being checked.
report() {
  local id="$1" expect="$2" p_ok="$3" c_ok="$4" detail="$5" verdict
  if [ "$p_ok" -eq 0 ] && [ "$c_ok" -eq 1 ]; then verdict=NEW-FIX
  elif [ "$p_ok" -eq 1 ] && [ "$c_ok" -eq 1 ]; then verdict=PRE-EXISTING
  elif [ "$p_ok" -eq 1 ] && [ "$c_ok" -eq 0 ]; then verdict=REGRESSED
  else verdict=UNFIXED
  fi
  ROWS=$((ROWS + 1))
  if [ "$verdict" = "$expect" ]; then
    echo "PROBE-RESULT: $id — $verdict, as claimed — $detail"
  else
    echo "PROBE-RESULT: $id — $verdict, BUT T027 CLAIMS $expect — $detail"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# The fixture: a scratch repo shaped like tests/test_jobs.sh's own, built once
# per tree so neither binary ever reads state the other wrote. Nothing lives
# inside the fixture repo that git would see as a dirty worktree beyond what
# test_jobs.sh already leaves there; the epoch is parked outside it.
# ---------------------------------------------------------------------------
epoch_file() { echo "$TMP/epoch.$(basename "$1")"; }

mk_fixture() {  # <dir> <bin>
  local dir="$1" bin="$2" epoch
  mkdir -p "$dir/.orchid/tasks" "$dir/.orchid/reviews" "$dir/home" "$dir/eng/fake"
  ( cd "$dir" && git init -q . && git commit -q --allow-empty -m root ) >/dev/null 2>&1 \
    || die "could not init the fixture repo at $dir"
  printf 'verify=true\nrole.implementer=fake\nstall_minutes=1\n' > "$dir/orchid.config"
  printf 'manifest_version=1\nid=test/fake\nversion=0.1.0\nkind=engine\napi_version=1\ncapabilities=workspace_write,shell,git\nrequires_binaries=jq\nentrypoint=run\n' \
    > "$dir/eng/fake/plugin.conf"
  printf '#!/usr/bin/env bash\ntrue\n' > "$dir/eng/fake/run"
  chmod +x "$dir/eng/fake/run"
  epoch="$( cd "$dir" && HOME="$dir/home" ORCHID_REPO="$dir" ORCHID_ENGINES_DIR="$dir/eng" \
    "$bin" run start 2>/dev/null | sed 's/epoch: //' )"
  [ -n "$epoch" ] || die "could not start a run in the fixture at $dir"
  printf '%s\n' "$epoch" > "$(epoch_file "$dir")"
  mkdir -p "$dir/.orchid/runtime/jobs" "$dir/.orchid/runtime/logs"
  orun "$dir" "$bin" task create T001 demo >/dev/null \
    || die "could not create a task in the fixture at $dir"
}

orun() {  # <dir> <bin> <args...> -- one verb against one fixture, stdout only
  local dir="$1" bin="$2"; shift 2
  ( cd "$dir" && HOME="$dir/home" ORCHID_REPO="$dir" ORCHID_ENGINES_DIR="$dir/eng" \
    ORCHID_EPOCH="$(cat "$(epoch_file "$dir")")" "$bin" "$@" 2>/dev/null )
}

# seed_manifest <dir> <name> <job-id> <task> <pid> <withlog|nolog>
#
# started_at is 0 for the pid-0 shapes (an unlaunched manifest has no start
# time to record — only the pid stamp sets one) and now-5 for a real pid, which
# is what the launcher writes. The manifest FILE is aged past any bound either
# tree could apply, so no row below can pass or fail on youth alone.
seed_manifest() {
  local dir="$1" name="$2" jid="$3" task="$4" pid="$5" want_log="$6"
  local started=0 logpath="$dir/.orchid/runtime/logs/$2.log"
  [ "$pid" = 0 ] || started=$(( $(date +%s) - 5 ))
  jq -n --arg jid "$jid" --arg task "$task" --argjson pid "$pid" \
        --argjson started "$started" --arg log "$logpath" \
    '{job_id:$jid, task:$task, attempt:1, role:"implementer", operation:"implement",
      engine:"fake", pid:$pid, pgid:0, started_at:$started, log:$log, output:"/dev/null",
      base_sha:"", candidate_sha:""}' > "$dir/.orchid/runtime/jobs/$name.json"
  if [ "$want_log" = withlog ]; then
    printf 'seeded\n' > "$logpath"
    touch -t 202001010000 "$logpath"
  else
    rm -f "$logpath"
  fi
  touch -t 202001010000 "$dir/.orchid/runtime/jobs/$name.json"
}

# A pid nothing can answer to: spawned and reaped here, so `kill -0` fails for
# it in both trees for the same reason.
dead_pid() {
  ( exit 0 ) &
  local p=$!
  wait "$p" 2>/dev/null
  printf '%s\n' "$p"
}

status_of() {  # <task> <jobs-check-output>
  awk -F'\t' -v t="$1" '$1 == t { print $2; exit }' <<<"$2"
}

present() {  # <dir> <name> -- 1 if the manifest is still in the jobs dir
  if [ -f "$1/.orchid/runtime/jobs/$2.json" ]; then echo 1; else echo 0; fi
}
reaped() {  # <dir> <name> -- 1 if gc took the manifest out of the jobs dir
  if [ -f "$1/.orchid/runtime/jobs/$2.json" ]; then echo 0; else echo 1; fi
}

P="$TMP/fix-parent"; C="$TMP/fix-cand"
mk_fixture "$P" "$PARENT_BIN"
mk_fixture "$C" "$CAND_BIN"

# ---------------------------------------------------------------------------
# 1-2. `jobs check` over the two pid-0 shapes.
#
# Claimed: one word, `prepared`, used to cover both, which is how a whole
# run's worth of failed launches read as "queued and fine" for 73 passes (F29).
# The candidate splits them on the log — no log at all is `never-started`, a
# log gone silent past stall_minutes is `unstamped`.
# ---------------------------------------------------------------------------
for probe_d in "$P" "$C"; do
  seed_manifest "$probe_d" j-nolog j-e1-TNOLOG-a1-aaaa0001 TNOLOG 0 nolog
  seed_manifest "$probe_d" j-withlog j-e1-TWITHLOG-a1-bbbb0001 TWITHLOG 0 withlog
done
p_check="$(orun "$P" "$PARENT_BIN" jobs check)"
c_check="$(orun "$C" "$CAND_BIN" jobs check)"
p_nolog="$(status_of TNOLOG "$p_check")"
c_nolog="$(status_of TNOLOG "$c_check")"
p_wlog="$(status_of TWITHLOG "$p_check")"
c_wlog="$(status_of TWITHLOG "$c_check")"
if [ -z "$p_nolog" ] || [ -z "$c_nolog" ] || [ -z "$p_wlog" ] || [ -z "$c_wlog" ]; then
  die "a tree reported nothing at all for a seeded manifest — the fixture, not the behaviour, is wrong (parent: '$p_check' / candidate: '$c_check')"
fi

p_ok=0; [ "$p_nolog" = never-started ] && p_ok=1
c_ok=0; [ "$c_nolog" = never-started ] && c_ok=1
report check-never-started NEW-FIX "$p_ok" "$c_ok" \
  "pid 0 with no log: parent says '$p_nolog', candidate says '$c_nolog'"

p_ok=0; [ "$p_wlog" = unstamped ] && p_ok=1
c_ok=0; [ "$c_wlog" = unstamped ] && c_ok=1
report check-unstamped NEW-FIX "$p_ok" "$c_ok" \
  "pid 0 with a log silent past stall_minutes: parent says '$p_wlog', candidate says '$c_wlog'"

# ---------------------------------------------------------------------------
# 3-5. `orchid jobs gc --older-than-s 0` — the exact call the operator made,
# over all three shapes their `pid == 0 || ! kill -0 <pid>` sweep matched.
#
# Rows 3 and 4 are the claimed fix: ordinary gc skipped every pid-0 manifest
# outright, so 74 of them were deleted by hand across two runs.
#
# Row 5 is the CONTROL, and it is the row this probe exists for. T027's
# acceptance criteria calls the pid-gone half "the same defect" and asks for a
# RED case per shape; one test case was duly written up as that proof. It was
# not one — the parent already reaps an ordinary dead-pid manifest on exactly
# this call. PRE-EXISTING is the truthful classification, tests/test_jobs.sh
# now labels that case as the regression tripwire it is, and THIS ROW FAILS
# the moment anyone re-labels it as a fix.
# ---------------------------------------------------------------------------
for probe_d in "$P" "$C"; do
  seed_manifest "$probe_d" j-nolog j-e1-TNOLOG-a1-aaaa0001 TNOLOG 0 nolog
  seed_manifest "$probe_d" j-withlog j-e1-TWITHLOG-a1-bbbb0001 TWITHLOG 0 withlog
  seed_manifest "$probe_d" j-gone j-e1-TGONE-a1-cccc0001 TGONE "$(dead_pid)" withlog
done
orun "$P" "$PARENT_BIN" jobs gc --older-than-s 0 >/dev/null
orun "$C" "$CAND_BIN" jobs gc --older-than-s 0 >/dev/null

report gc-zero-never-started NEW-FIX "$(reaped "$P" j-nolog)" "$(reaped "$C" j-nolog)" \
  "gc --older-than-s 0 over a pid-0 manifest with no log"
report gc-zero-unstamped NEW-FIX "$(reaped "$P" j-withlog)" "$(reaped "$C" j-withlog)" \
  "gc --older-than-s 0 over a pid-0 manifest whose log went silent"
report gc-zero-dead-pid PRE-EXISTING "$(reaped "$P" j-gone)" "$(reaped "$C" j-gone)" \
  "gc --older-than-s 0 over a launched job whose pid is gone — the half the parent ALREADY handled"

# ---------------------------------------------------------------------------
# 6. `--prepared-older-than-s`, the separate bound the unattended sweep needs
# for a launcher that may be mid-flight between its own `prepare` and its spawn
# line. "Correct" is both halves at once: the verb must ACCEPT the flag and
# must HOLD BACK a manifest younger than it. Either alone is not the fix — a
# flag parsed and then dropped on the floor is F41 one level up, and holding
# a manifest back while rejecting the call is just the parent skipping pid 0.
# ---------------------------------------------------------------------------
for probe_d in "$P" "$C"; do
  rm -f "$probe_d"/.orchid/runtime/jobs/*.json
  seed_manifest "$probe_d" j-bound j-e1-TBOUND-a1-dddd0001 TBOUND 0 nolog
  touch "$probe_d/.orchid/runtime/jobs/j-bound.json"   # young: inside the bound
done
p_rc=0; orun "$P" "$PARENT_BIN" jobs gc --older-than-s 0 --prepared-older-than-s 3600 >/dev/null 2>&1 || p_rc=$?
c_rc=0; orun "$C" "$CAND_BIN" jobs gc --older-than-s 0 --prepared-older-than-s 3600 >/dev/null 2>&1 || c_rc=$?
p_ok=0; [ "$p_rc" -eq 0 ] && [ "$(present "$P" j-bound)" -eq 1 ] && p_ok=1
c_ok=0; [ "$c_rc" -eq 0 ] && [ "$(present "$C" j-bound)" -eq 1 ] && c_ok=1
report gc-prepared-older-than-s NEW-FIX "$p_ok" "$c_ok" \
  "accepted the flag and spared a young manifest: parent exit $p_rc / still there $(present "$P" j-bound); candidate exit $c_rc / still there $(present "$C" j-bound)"

# ---------------------------------------------------------------------------
# 7. `jobs prepare` refusing (exit 18) a second manifest for a slot that
# already holds an unlaunched one. This is the property that turned ONE broken
# launch into 74 files: one fresh orphan per pass, every pass, for 73 passes.
# ---------------------------------------------------------------------------
for probe_d in "$P" "$C"; do
  rm -f "$probe_d"/.orchid/runtime/jobs/*.json
done
p_first="$(orun "$P" "$PARENT_BIN" jobs prepare T001 implementer implement)"
c_first="$(orun "$C" "$CAND_BIN" jobs prepare T001 implementer implement)"
if [ -z "$p_first" ] || [ -z "$c_first" ]; then
  die "a tree could not prepare even the FIRST manifest — the fixture, not the behaviour, is wrong"
fi
p_rc=0; orun "$P" "$PARENT_BIN" jobs prepare T001 implementer implement >/dev/null 2>&1 || p_rc=$?
c_rc=0; orun "$C" "$CAND_BIN" jobs prepare T001 implementer implement >/dev/null 2>&1 || c_rc=$?
p_ok=0; [ "$p_rc" -eq 18 ] && p_ok=1
c_ok=0; [ "$c_rc" -eq 18 ] && c_ok=1
report prepare-refuses-second NEW-FIX "$p_ok" "$c_ok" \
  "a second prepare for the same (task, attempt, role, operation): parent exit $p_rc, candidate exit $c_rc"

# ---------------------------------------------------------------------------
# 8. `orchid doctor` naming the RESOLVED pack budget. The incident's second
# half: the live budget matched neither the file the operator had edited nor
# the target repo's, every launch failed on it, and nothing anywhere printed
# which value was in force.
# ---------------------------------------------------------------------------
p_doc_out="$(orun "$P" "$PARENT_BIN" doctor)"
c_doc_out="$(orun "$C" "$CAND_BIN" doctor)"
if [ -z "$p_doc_out" ] || [ -z "$c_doc_out" ]; then
  die "a tree's doctor printed nothing at all in this fixture — the fixture, not the behaviour, is wrong"
fi
p_ok=0; grep -q 'pack budget: pack_budget_bytes=' <<<"$p_doc_out" && p_ok=1
c_ok=0; grep -q 'pack budget: pack_budget_bytes=' <<<"$c_doc_out" && c_ok=1
report doctor-pack-budget NEW-FIX "$p_ok" "$c_ok" \
  "a resolved-pack-budget note in 'orchid doctor' output"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PROBE-RESULT: SUMMARY — $ROWS/$ROWS behaviours are classified exactly as T027 claims"
  exit 0
fi
echo "PROBE-RESULT: SUMMARY — $FAILURES of $ROWS behaviours are NOT what T027 claims; see the rows above" >&2
exit 1
