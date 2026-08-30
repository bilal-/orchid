#!/usr/bin/env bash
# v1.1 Track 2: `orchid start <requirements-file>` -- one-command setup for an
# EXISTING repository. This file covers the mechanics (preflight, config
# validation, init, worktree create/reuse, epoch, import, trust, handoff) and
# every refusal that protects operator-owned state; the session/epoch fencing
# half lives in tests/test_start_fencing.sh.
#
# RED (before libexec/orchid-start exists): `orchid start` exits 2 with
# "unknown command 'start'", so every assertion below fails.
source "$(dirname "$0")/helpers.sh"

# $WORK itself may be a symlinked path (macOS /var -> /private/var). Every
# path orchid start prints is canonical (`pwd -P`), so the fixture has to be
# too, or every path assertion below compares two spellings of one directory.
W="$(cd_scratch "$WORK" && pwd -P)" \
  || { fail "cd_scratch refused the scratch root"; exit 1; }
export HOME="$MACHINE_HOME"; mkdir -p "$HOME/.orchid"

# A resolvable engine for every role, so the full preflight (`orchid doctor`)
# is genuinely green rather than skipped -- same minimal fixture shape
# tests/test_init_doctor.sh uses.
export ORCHID_ENGINES_DIR="$W/eng"
mkdir -p "$W/eng/fake"
printf '#!/usr/bin/env bash\n' > "$W/eng/fake/run"
chmod +x "$W/eng/fake/run"

REQ="$W/requirements.md"
cat > "$REQ" <<'EOF'
# Requirements

## Goal
Ship the thing.

## Acceptance criteria
- it works
EOF

mk_repo() {  # <dir> [extra orchid.config line ...]
  local repo="$1"; shift
  mkdir -p "$repo"
  git -C "$repo" init -q
  {
    printf 'role.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\n'
    printf 'role.arbiter=fake\nrole.plan_critic=fake\n'
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$repo/orchid.config"
  printf 'print("hello")\n' > "$repo/app.py"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "fixture: project + orchid.config"
}

# ===========================================================================
# 1 -- the happy path on a fresh existing repo: one command replaces doctor +
# init + `git worktree add` + epoch export + requirements import.
# ===========================================================================
r1="$W/r1"; mk_repo "$r1"
r1_branch="$(git -C "$r1" rev-parse --abbrev-ref HEAD)"
r1_head="$(git -C "$r1" rev-parse HEAD)"

out1="$(ORCHID_REPO="$r1" "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" \
  || fail "orchid start must succeed on a clean, configured, existing repo: $out1"
wt1="$W/r1-orchid"

assert_match "^preflight: orchid doctor" "$out1" "start runs the full preflight and says so"
assert_match "^orchid start: initialized a new run$" "$out1" "start names what it did"
assert_match "^integration branch: orchid/integration$" "$out1" "start prints the integration branch"
assert_match "^integration worktree: $wt1 \(created\)$" "$out1" "start prints the worktree path it created"
assert_match "^epoch: 0 \(created\)$" "$out1" "start prints the epoch it created"
assert_match "^run: r-001 \(planning\)$" "$out1" "start prints run id and run_status"
assert_match "^requirements: imported from $REQ$" "$out1" "start reports the requirements import"
assert_match "^unattended trust: untrusted" "$out1" "trust stays off unless explicitly acknowledged"
assert_match "^  cd $wt1$" "$out1" "the handoff names the worktree to work from"
# T029 (dogfood finding F31): the handoff used to print `export ORCHID_EPOCH=0`
# -- a literal, into a shell the operator keeps for the rest of the run, naming
# the one value certain to expire (every `orchid run start|resume` and every
# headless tick fences a fresh epoch, so the first drive pass makes it stale
# and the next mutating verb typed in that shell is refused). It now hands over
# the READ of `.orchid/runtime/epoch`, which is the same line after every drive
# pass instead of a different number to hunt for, and it says so rather than
# leaving the operator to meet the refusal first. `grep -F`, not `assert_match`:
# the line is nothing but shell metacharacters.
grep -qF 'export ORCHID_EPOCH="$(cat .orchid/runtime/epoch)"' <<<"$out1" \
  || fail "the handoff must export the epoch by READING .orchid/runtime/epoch, not as a literal"
assert_match "^  export ORCHID_EPOCH.*# 0 right now$" "$out1" \
  "the handoff still shows the epoch it just fenced this run at"
grep -qF 'export ORCHID_EPOCH=0' <<<"$out1" \
  && fail "the handoff must not hand an operator a bare epoch literal to carry (dogfood F31)"
assert_match "snapshot, not a constant" "$out1" \
  "the handoff says the exported epoch expires"
assert_match "stale epoch '0' \(current N\)" "$out1" \
  "the handoff names the refusal an expired epoch produces, so it is recognized when it arrives"
assert_match "orchid plan apply --reason" "$out1" "the handoff points at the planning procedure"

git -C "$r1" rev-parse --verify -q orchid/integration >/dev/null \
  || fail "start must create the integration branch"
[ -d "$wt1/.orchid" ] || fail "start must create the integration worktree"
assert_eq "orchid/integration" "$(git -C "$wt1" rev-parse --abbrev-ref HEAD)" \
  "the worktree is a checkout of the integration branch"
assert_eq "$(cat "$REQ")" "$(cat "$wt1/.orchid/requirements.md")" \
  "requirements are imported verbatim into the integration checkout"
assert_eq "0" "$(cat "$wt1/.orchid/runtime/epoch")" "the epoch is materialized at 0"
grep -q '^verify=true$' "$wt1/orchid.config" \
  || fail "--verify is recorded as a verify= line in the integration checkout's orchid.config"
grep -q "requirements imported from requirements.md" "$wt1/.orchid/journal.md" \
  || fail "the import is journaled by the requirements verb itself"

# ONE command means no mandatory follow-up: the recorded verify command is
# committed onto the integration branch by this same run, so it survives a
# fresh checkout (a task worktree, another machine, a headless pump) and the
# integration checkout is not handed back dirty (dogfood finding F16).
assert_match "^verify: true — recorded in $wt1/orchid.config and committed on orchid/integration" \
  "$out1" "start commits the verify command it recorded, rather than leaving homework"
assert_match '^verify=true$' "$(git -C "$r1" show orchid/integration:orchid.config)" \
  "the verify= line is committed on the integration branch, not just written to the checkout"
assert_eq "" "$(git -C "$wt1" status --porcelain -- orchid.config)" \
  "recording the verify command leaves the integration checkout's orchid.config clean"
# Nor may that commit leave the checkout looking STALE to doctor/status: a
# branch pointer advanced over an unrefreshed per-worktree index is exactly
# lib/common.sh's orchid_stale_checkout signature (any HEAD-vs-index row
# while parked on the integration branch).
assert_eq "" "$(git -C "$wt1" diff --cached --name-status)" \
  "start's own commit must not leave a stale index behind in the integration checkout"

# "orchid never touches user work": the operator's own branch and working
# tree are exactly as they were.
assert_eq "$r1_branch" "$(git -C "$r1" rev-parse --abbrev-ref HEAD)" \
  "start leaves the operator on their own branch"
assert_eq "$r1_head" "$(git -C "$r1" rev-parse HEAD)" \
  "start never commits on the operator's own branch"
assert_eq "" "$(git -C "$r1" status --porcelain)" \
  "start leaves the operator's own working tree clean"

# ===========================================================================
# 2 -- idempotence: the same command, same file, with the epoch it just
# printed, is a no-op that re-reports rather than re-doing.
# ===========================================================================
out2="$(ORCHID_REPO="$r1" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" \
  || fail "a second orchid start with the current epoch must succeed: $out2"
assert_match "^orchid start: reused existing run state$" "$out2" "a re-run reuses existing state"
assert_match "^integration worktree: $wt1 \(reused\)$" "$out2" "a re-run reuses the existing worktree"
assert_match "^epoch: 0 \(reused\)$" "$out2" "a re-run reads the existing epoch instead of minting one"
assert_match "^requirements: unchanged \(already imported verbatim\)$" "$out2" \
  "an identical requirements file is not re-imported"
assert_match "^verify: true — already configured" "$out2" \
  "an already-configured verify command is reported, not rewritten"
assert_eq 1 "$(grep -c "requirements imported from requirements.md" "$wt1/.orchid/journal.md")" \
  "a no-op re-run must not journal a second plan revision"
assert_eq 1 "$(grep -c '^verify=true$' "$wt1/orchid.config")" \
  "a no-op re-run must not append a second verify= line"

# A CHANGED requirements file is re-imported (still in planning, so this is
# legal) -- idempotence is by content, never by "already ran once".
req2="$W/requirements-v2.md"
{ cat "$REQ"; echo "- and it is fast"; } > "$req2"
out2b="$(ORCHID_REPO="$r1" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$req2" 2>&1)" \
  || fail "re-importing a revised requirements file during planning must succeed: $out2b"
assert_match "^requirements: imported from $req2$" "$out2b" "a changed requirements file is re-imported"
assert_eq "$(cat "$req2")" "$(cat "$wt1/.orchid/requirements.md")" "the revised snapshot replaces the old one"

# ===========================================================================
# 3 -- verification is never guessed, and never overwritten.
# ===========================================================================
r3="$W/r3"; mk_repo "$r3"
rc=0; out3="$(ORCHID_REPO="$r3" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a repo with no verification command and no --verify"
assert_match "never guesses one" "$out3" "the refusal says orchid start does not guess a verify command"
git -C "$r3" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "a refused start must not have initialized anything"

r4="$W/r4"; mk_repo "$r4" 'verify=make test'
rc=0; out4="$(ORCHID_REPO="$r4" "$ORCHID_BIN" start "$REQ" --verify 'npm test' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse to replace an already-configured verify command"
assert_match "already configured as 'make test'" "$out4" "the refusal quotes the configured command"
assert_match "never replaces it" "$out4" "the refusal says the configured command is not replaced"
grep -q '^verify=make test$' "$r4/orchid.config" || fail "the operator's orchid.config is untouched"
assert_eq 1 "$(grep -c '^verify=' "$r4/orchid.config")" "no second verify= line was appended"

# The same --verify as the one already configured is accepted (idempotent),
# because nothing has to change.
out4b="$(ORCHID_REPO="$r4" "$ORCHID_BIN" start "$REQ" --verify 'make test' 2>&1)" \
  || fail "start must accept a --verify identical to the configured one: $out4b"
assert_match "^verify: make test — already configured" "$out4b" "a matching --verify changes nothing"
assert_eq 1 "$(grep -c '^verify=' "$W/r4-orchid/orchid.config")" \
  "an already-configured command is never duplicated into the integration checkout"

# "Already configured" is judged by the `verify=` LINE the integration branch
# actually carries, never by the merged value: a command that resolves only
# from a MACHINE-LOCAL layer (~/.orchid/config, or ORCHID_VERIFY) does not
# survive a fresh checkout, so it is recorded and committed like any other.
r15="$W/r15"; mk_repo "$r15"
printf 'verify=true\n' > "$HOME/.orchid/config"
rc=0; out15="$(ORCHID_REPO="$r15" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
rm -f "$HOME/.orchid/config"
[ "$rc" -eq 0 ] || fail "a machine-local verify command must be enough to set up: $out15"
assert_match "committed on orchid/integration" "$out15" \
  "a verify command that only a machine-local layer supplies is recorded durably"
assert_match '^verify=true$' "$(git -C "$r15" show orchid/integration:orchid.config)" \
  "the run's verification command survives a fresh checkout of the integration branch"

# A verify command already committed on the integration branch is the run's,
# even when the operator's OWN branch configures none and no integration
# checkout exists yet to compare against up front: refused, never silently
# ignored in favor of the configured one.
r16="$W/r16"; mk_repo "$r16" 'verify=make test'
ORCHID_REPO="$r16" "$ORCHID_BIN" init >/dev/null || fail "fixture: orchid init must succeed on r16"
grep -v '^verify=' "$r16/orchid.config" > "$r16/config.tmp"
mv "$r16/config.tmp" "$r16/orchid.config"
git -C "$r16" commit -qam "fixture: the operator's own branch drops verify=" \
  || fail "fixture: committing the operator's own branch must succeed"
rc=0; out16="$(ORCHID_REPO="$r16" "$ORCHID_BIN" start "$REQ" --verify 'npm test' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse to replace the integration branch's own verify command"
assert_match "already configured as 'make test'" "$out16" "the refusal quotes the command the run actually uses"
assert_match "never replaces it" "$out16" "the refusal states the rule"
assert_match '^verify=make test$' "$(git -C "$r16" show orchid/integration:orchid.config)" \
  "and nothing was committed over it"
# The refusal has to land ABOVE the mutation boundary: refusing after the
# worktree exists and an epoch has been minted would print a recovery that the
# epoch-ownership guard then rejects on the very next run.
[ -e "$W/r16-orchid" ] && fail "the conflict must be refused before any worktree is created (and so before any epoch is minted)"

# ...and the recovery it prints has to actually WORK -- re-running without
# --verify keeps the branch's own command rather than dying or pinning the run
# to something else.
out16b="$(ORCHID_REPO="$r16" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "the recovery the refusal prints (re-run without --verify) must succeed: $out16b"
assert_match "^verify: make test — already configured" "$out16b" \
  "the re-run keeps the integration branch's own verification command"
assert_match '^verify=make test$' "$(git -C "$r16" show orchid/integration:orchid.config)" \
  "and still never replaces it"
assert_eq 1 "$(grep -c '^verify=' "$W/r16-orchid/orchid.config")" \
  "no second verify= line was appended to the integration checkout"

# A MACHINE-LOCAL layer is not the run's verification command either, so an
# explicit --verify is not "replacing" one and is taken as given. Refusing here
# would be actively backwards: the recovery it printed ("re-run without
# --verify") would then commit the machine-local command onto the integration
# branch -- pinning the run to the exact command the operator just overrode.
r18="$W/r18"; mk_repo "$r18"
printf 'verify=make check\n' > "$HOME/.orchid/config"
rc=0; out18="$(ORCHID_REPO="$r18" "$ORCHID_BIN" start "$REQ" --verify 'npm test' 2>&1)" || rc=$?
rm -f "$HOME/.orchid/config"
[ "$rc" -eq 0 ] || fail "--verify must be accepted when only a machine-local layer configures one: $out18"
assert_match "^verify: npm test — recorded in $W/r18-orchid/orchid.config and committed on orchid/integration" \
  "$out18" "the operator's explicit command is the one recorded"
assert_match '^verify=npm test$' "$(git -C "$r18" show orchid/integration:orchid.config)" \
  "the branch carries the operator's command, never the machine-local one"
assert_eq 1 "$(grep -c '^verify=' "$W/r18-orchid/orchid.config")" \
  "exactly one verify= line is written"

# Convergence: a `verify=` line sitting in the integration checkout that never
# landed on the branch (an earlier setup whose commit lost its CAS race, or an
# operator edit made there) is FINISHED on a re-run -- reporting it as
# "already configured" would leave a run whose verification command still
# vanishes on a fresh checkout. The line itself is never rewritten.
r17="$W/r17"; mk_repo "$r17"
ORCHID_REPO="$r17" "$ORCHID_BIN" init >/dev/null || fail "fixture: orchid init must succeed on r17"
git -C "$r17" worktree add -q "$W/r17-orchid" orchid/integration \
  || fail "fixture: the integration worktree must be creatable"
printf 'verify=true\n' >> "$W/r17-orchid/orchid.config"
out17="$(ORCHID_REPO="$r17" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must finish an uncommitted verify= line rather than refuse: $out17"
assert_match "^verify: true — already in .*orchid.config, now committed on orchid/integration" "$out17" \
  "the uncommitted line is committed by this run, and said to be"
assert_match '^verify=true$' "$(git -C "$r17" show orchid/integration:orchid.config)" \
  "the line the operator already wrote is what landed on the branch"
assert_eq 1 "$(grep -c '^verify=' "$W/r17-orchid/orchid.config")" \
  "the existing line is committed, never rewritten or duplicated"
assert_eq "" "$(git -C "$W/r17-orchid" status --porcelain -- orchid.config)" \
  "and the integration checkout is left clean"

# ...but convergence stops exactly where it would REPLACE the branch's own
# command. The commit that records a verify= line is whole-file, so an
# integration checkout whose verify= line disagrees with the one $integ
# already carries would put the checkout's command over the branch's -- the
# one thing this verb promises never to do (docs/quickstart.md, PROTOCOL.md).
# It is refused above the mutation boundary, and refused on the path that
# reaches it: `--verify` conflicts print "re-run without --verify", and that
# re-run is precisely the one that used to perform the replacement.
r20="$W/r20"; mk_repo "$r20" 'verify=make test'
ORCHID_REPO="$r20" "$ORCHID_BIN" init >/dev/null || fail "fixture: orchid init must succeed on r20"
r20wt="$W/r20-orchid"
git -C "$r20" worktree add -q "$r20wt" orchid/integration \
  || fail "fixture: the integration worktree must be creatable"
grep -v '^verify=' "$r20wt/orchid.config" > "$r20wt/config.tmp"
mv "$r20wt/config.tmp" "$r20wt/orchid.config"
printf 'verify=npm test\n' >> "$r20wt/orchid.config"

rc=0; out20="$(ORCHID_REPO="$r20" "$ORCHID_BIN" start "$REQ" --verify 'npm test' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a --verify that the branch's own command disagrees with"
assert_match "never replaces one already committed" "$out20" "the refusal states the rule"
assert_match "make test" "$out20" "the refusal quotes the branch's command"

# The same refusal WITHOUT the flag -- this is the run the old "re-run without
# --verify" recovery leads to, and the one that would have done the replacing.
rc=0; out20b="$(ORCHID_REPO="$r20" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse to commit the checkout's verify= line over the branch's own"
assert_match "never replaces one already committed" "$out20b" "the bare re-run states the same rule"
assert_match '^verify=make test$' "$(git -C "$r20" show orchid/integration:orchid.config)" \
  "and the branch's own command still stands"
assert_eq "verify=npm test" "$(grep '^verify=' "$r20wt/orchid.config")" \
  "the operator's own uncommitted edit is left exactly as they wrote it"
[ -e "$r20wt/.orchid/runtime/epoch" ] \
  && fail "the conflict must be refused before any epoch is minted"

# The recovery it names has to actually work.
git -C "$r20wt" checkout -- orchid.config || fail "fixture: restoring the branch's copy must succeed"
out20c="$(ORCHID_REPO="$r20" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "the recovery the refusal prints (restore the branch's copy) must succeed: $out20c"
assert_match "^verify: make test — already configured" "$out20c" \
  "the re-run keeps the integration branch's own verification command"

# The same rule for every OTHER line the branch carries: whole-file
# granularity means a checkout copy that has lost one would delete a setting
# the run reads, so that commit is refused too, above the boundary.
r21="$W/r21"; mk_repo "$r21" 'pump_stale_s=600'
ORCHID_REPO="$r21" "$ORCHID_BIN" init >/dev/null || fail "fixture: orchid init must succeed on r21"
r21wt="$W/r21-orchid"
git -C "$r21" worktree add -q "$r21wt" orchid/integration \
  || fail "fixture: the integration worktree must be creatable"
grep -v '^pump_stale_s=' "$r21wt/orchid.config" > "$r21wt/config.tmp"
mv "$r21wt/config.tmp" "$r21wt/orchid.config"
printf 'verify=true\n' >> "$r21wt/orchid.config"
rc=0; out21="$(ORCHID_REPO="$r21" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a commit that would drop a committed config line"
assert_match "pump_stale_s=600" "$out21" "the refusal names the line that would be lost"
assert_match "never removes from it" "$out21" "the refusal states the rule"
assert_match '^pump_stale_s=600$' "$(git -C "$r21" show orchid/integration:orchid.config)" \
  "and the branch still carries that line"

# A checkout carrying no verify= line at all while the branch does is NOT that
# case: the append below writes the branch's own line straight back, so the
# commit adds nothing and removes nothing.
git -C "$r21wt" checkout -- orchid.config || fail "fixture: restoring the branch's copy must succeed"
printf 'verify=true\n' >> "$r21wt/orchid.config"
out21b="$(ORCHID_REPO="$r21" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "an append-only checkout copy must still be committable: $out21b"
grep -v '^verify=' "$r21wt/orchid.config" > "$r21wt/config.tmp"
mv "$r21wt/config.tmp" "$r21wt/orchid.config"
out21c="$(ORCHID_REPO="$r21" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "re-appending the branch's own verify= line must not be read as a deletion: $out21c"
assert_eq 1 "$(grep -c '^verify=true$' "$r21wt/orchid.config")" \
  "the branch's own command is written back, exactly once"
assert_match "^verify: true — already configured" "$out21c" \
  "restoring a line the branch already carries commits nothing, and says so"
assert_eq "" "$(git -C "$r21wt" status --porcelain -- orchid.config)" \
  "and leaves the integration checkout clean"

# ===========================================================================
# 4 -- a clean existing repo is required, and a malformed repo config is
# refused rather than silently ignored.
# ===========================================================================
r5="$W/r5"; mk_repo "$r5" 'verify=true'
printf 'wip\n' > "$r5/scratch.txt"
rc=0; out5="$(ORCHID_REPO="$r5" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a dirty working tree"
assert_match "working tree not clean" "$out5" "the refusal names the dirty tree"
assert_match "commit or stash first" "$out5" "the refusal says exactly how to recover"
git -C "$r5" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "a dirty-tree refusal must not create the integration branch"

r6="$W/r6"; mk_repo "$r6" 'verify=true'
printf 'verify true\n' >> "$r6/orchid.config"
git -C "$r6" add -A; git -C "$r6" commit -q -m "fixture: malformed config line"
rc=0; out6="$(ORCHID_REPO="$r6" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a malformed orchid.config line"
assert_match "is not a 'key=value' line" "$out6" "the refusal names the malformed line shape"
assert_match "Fix that line in $r6/orchid.config" "$out6" "and names the file to fix"

# `verify = true` is the same defect wearing a plausible face: config lookups
# match `^verify=` literally, so the spaces make the most important line in
# the file configure nothing at all while looking like it configures
# everything. Fatal, not a warning.
r6b="$W/r6b"; mk_repo "$r6b" 'verify=true'
printf 'pump_stale_s = 900\n' >> "$r6b/orchid.config"
git -C "$r6b" add -A; git -C "$r6b" commit -q -m "fixture: spaces around ="
rc=0; out6b="$(ORCHID_REPO="$r6b" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a config key with whitespace in it"
assert_match "whitespace in its config key" "$out6b" "the refusal names what is wrong"
git -C "$r6b" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "a config refusal must not initialize anything"

# An unknown key is a warning, never a refusal: a config written for a newer
# orchid, or a custom role binding, must not brick setup.
r7="$W/r7"; mk_repo "$r7" 'verify=true' 'not_a_real_key=1' 'role.reviewer.blocking=true'
out7="$(ORCHID_REPO="$r7" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "an unknown config key must not fail setup: $out7"
assert_match "warn: .*not_a_real_key" "$out7" "an unknown config key is warned about"
# A HERESTRING, never `echo "$out7" | grep -q`: `grep -q` exits at its first
# match and SIGPIPEs the producer, which under this file's pipefail turns a
# genuine match into a nonzero pipeline status -- i.e. a negative check that
# silently stops checking (lesson L005).
if grep -Eq "warn: .*role\." <<<"$out7"; then
  fail "a role.* binding must never be reported as an unknown config key"
fi

# The config the RUN reads is the blob COMMITTED on the integration branch --
# what a fresh checkout, another machine, or a headless pump gets -- not the
# integration checkout's working copy, which legitimately differs from it (an
# uncommitted `verify=` line is exactly that case). A malformed line there is
# just as invisible to config_get, so it is validated on its own terms even
# when a checkout is sitting right there to look at instead.
r19="$W/r19"; mk_repo "$r19" 'verify=true'
ORCHID_REPO="$r19" "$ORCHID_BIN" start "$REQ" >/dev/null \
  || fail "fixture: the initial start on r19 must succeed"
r19wt="$W/r19-orchid"
printf 'pump_stale_s 900\n' >> "$r19wt/orchid.config"
ORCHID_REPO="$r19wt" ORCHID_EPOCH=0 "$ORCHID_BIN" config commit \
  --reason "fixture: land a malformed line on the branch" >/dev/null \
  || fail "fixture: config commit must land the malformed line"
grep -v '^pump_stale_s ' "$r19wt/orchid.config" > "$r19wt/config.tmp"
mv "$r19wt/config.tmp" "$r19wt/orchid.config"
rc=0; out19="$(ORCHID_REPO="$r19" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a malformed line in the config COMMITTED on the integration branch"
assert_match "orchid.config as committed on orchid/integration line [0-9]+ is not a 'key=value' line" \
  "$out19" "the refusal names the committed copy, not the checkout's clean one"
# Those bytes are in a git blob the operator cannot open and edit, so naming
# the defect without naming the route to it is a dead end -- every other
# refusal in this verb names its recovery, and this one needs it most.
assert_match "git show orchid/integration:orchid.config" "$out19" \
  "the refusal says how to read the offending bytes"
assert_match "orchid config commit" "$out19" "and how to land the fix"

# orchid.config has to be COMMITTABLE onto the integration branch, because
# that commit is how the run's verification command becomes durable. A
# .gitignore that excludes it makes `git add` fail outright -- below the
# mutation boundary that is git's raw error, after init has run and the epoch
# is minted, on every re-run. Refused above it instead, with the recovery.
r22="$W/r22"; mkdir -p "$r22"; git -C "$r22" init -q
printf 'orchid.config\n' > "$r22/.gitignore"
{
  printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\n'
  printf 'role.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n'
} > "$r22/orchid.config"
printf 'print("hello")\n' > "$r22/app.py"
git -C "$r22" add -A
git -C "$r22" commit -q -m "fixture: project with an ignored orchid.config"
assert_eq "" "$(git -C "$r22" status --porcelain)" \
  "fixture: an ignored orchid.config leaves the tree looking clean"
rc=0; out22="$(ORCHID_REPO="$r22" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a repo whose orchid.config it cannot commit"
assert_match "excluded by .gitignore" "$out22" "the refusal names why the file cannot be committed"
assert_match "git add -f orchid.config" "$out22" "the refusal names a way out"
git -C "$r22" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "the refusal must land above the mutation boundary"
[ -e "$W/r22-orchid" ] && fail "and before any worktree is created"

# ...and the recovery works: a tracked orchid.config is committable whatever
# .gitignore says about it.
git -C "$r22" add -f orchid.config
git -C "$r22" commit -q -m "fixture: track orchid.config deliberately"
out22b="$(ORCHID_REPO="$r22" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "the recovery the refusal prints must succeed: $out22b"
assert_match '^verify=true$' "$(git -C "$r22" show orchid/integration:orchid.config)" \
  "and the run's verification command lands on the branch"

# `.orchid/` is the OTHER half of that asymmetry, and it is answered the
# opposite way on purpose (T037, dogfood finding F21).
#
# An operator who does not want orchid's bookkeeping in their product writes
# `.orchid/` into .gitignore -- a reasonable thing to want, and the reported
# incident is exactly what happens when they do not. Before this fix that line
# broke the run outright: `orchid init` stages the skeleton with a plain `git
# add`, git refuses an ignored pathspec, and init died on git's own error; the
# operator's only way forward was to un-ignore `.orchid/`, which is precisely
# what made the state merge-able into their product in the first place. Same
# failure again, later, at `orchid plan apply` (lib/common.sh's
# orchid_commit_durable), which is the first durable verb a planning
# orchestrator reaches.
#
# So run state is force-staged and orchid.config is not. The distinction is
# ownership: `.orchid/` is orchid's own, was already tracked before any ignore
# rule existed, and a run whose state is not committed does not survive a
# fresh checkout -- whereas orchid.config is the operator's file and whether
# it belongs in history is their call (r22 above). The want behind the ignore
# line is answered where it actually lives: orchid-merge's containment warning
# and the pre-push run-state guard, not by leaving init broken.
#
# RED (before this fix): `orchid start` exits non-zero here with "The
# following paths are ignored by one of your .gitignore files: .orchid".
r37_ignored="$W/r37-ignored"; mkdir -p "$r37_ignored"; git -C "$r37_ignored" init -q
printf '.orchid/\n' > "$r37_ignored/.gitignore"
{
  printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\n'
  printf 'role.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n'
} > "$r37_ignored/orchid.config"
printf 'print("hello")\n' > "$r37_ignored/app.py"
git -C "$r37_ignored" add -A
git -C "$r37_ignored" commit -q -m "fixture: project that ignores .orchid/"

out37_ignored="$(ORCHID_REPO="$r37_ignored" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must succeed on a repo whose .gitignore excludes .orchid/: $out37_ignored"
wt37_ignored="$W/r37-ignored-orchid"
git -C "$r37_ignored" cat-file -e "orchid/integration:.orchid/roadmap.md" 2>/dev/null \
  || fail "the run's own state must be COMMITTED on the integration branch even when .orchid/ is ignored"
assert_eq "$(cat "$REQ")" "$(cat "$wt37_ignored/.orchid/requirements.md")" \
  "and the imported requirements are there to read in the integration checkout"

# The durable-commit path itself, which is where F21 was actually reported:
# `orchid plan apply` commits `.orchid/` onto the integration branch through
# orchid_commit_durable's temp worktree, and that worktree inherits the same
# .gitignore.
apply37_ignored="$(ORCHID_REPO="$wt37_ignored" ORCHID_EPOCH=0 "$ORCHID_BIN" plan apply --reason "first plan" 2>&1)" \
  || fail "plan apply must succeed with .orchid/ ignored: $apply37_ignored"
assert_match "^applied: orchid/integration -> " "$apply37_ignored" "plan apply reports the commit it landed"
assert_match "^run_status: running$" "$(git -C "$r37_ignored" show 'orchid/integration:.orchid/roadmap.md')" \
  "and the planning->running transition it owns landed ON THE BRANCH, not just on disk"
assert_match "first plan" "$(git -C "$r37_ignored" show 'orchid/integration:.orchid/journal.md')" \
  "the plan-apply journal entry is committed on the branch, not left in one checkout"

# The price of `-f`, held to: forcing past .gitignore also forces past the
# `.orchid/runtime/` line, so `runtime/` is excluded by an explicit pathspec at
# every staging site instead of being left to an ignore rule that `-f` has
# switched off. lease.json, the epoch and the lock are local-only and must
# never be committed -- least of all here, where the operator ignored the
# whole directory.
[ -f "$wt37_ignored/.orchid/runtime/epoch" ] \
  || fail "fixture: runtime/ must exist on disk for this exclusion to be worth asserting"
assert_eq "" "$(git -C "$r37_ignored" ls-tree -r --name-only orchid/integration -- .orchid/runtime)" \
  "no .orchid/runtime/ path is ever committed, even when -f overrides the ignore rule that used to stop it"

# The GREEN twin: the identical sequence on a repo that does NOT ignore
# `.orchid/` behaves exactly as it always did -- the force-stage is not doing
# the work here, so a regression that broke the ordinary path would show up
# as this block failing rather than as silence.
r37_green="$W/r37-green"; mk_repo "$r37_green" 'verify=true'
out37_green="$(ORCHID_REPO="$r37_green" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must still succeed on a repo that does not ignore .orchid/: $out37_green"
apply37_green="$(ORCHID_REPO="$W/r37-green-orchid" ORCHID_EPOCH=0 "$ORCHID_BIN" plan apply --reason "first plan" 2>&1)" \
  || fail "plan apply must still succeed with .orchid/ un-ignored: $apply37_green"
assert_match "^applied: orchid/integration -> " "$apply37_green" "the un-ignored path reports the same commit line"

# And the deliberate stance on orchid.config is NOT reversed by any of this:
# the same repo, with orchid.config ALSO ignored and untracked, is still
# refused with the actionable message rather than force-committed.
r37_config="$W/r37-config"; mkdir -p "$r37_config"; git -C "$r37_config" init -q
printf '.orchid/\norchid.config\n' > "$r37_config/.gitignore"
{
  printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\n'
  printf 'role.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n'
} > "$r37_config/orchid.config"
printf 'print("hello")\n' > "$r37_config/app.py"
git -C "$r37_config" add -A
git -C "$r37_config" commit -q -m "fixture: project that ignores both"
rc=0; out37_config="$(ORCHID_REPO="$r37_config" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "ignoring .orchid/ must not have made an ignored orchid.config force-committable"
assert_match "excluded by .gitignore" "$out37_config" "the orchid.config refusal is unchanged"
git -C "$r37_config" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "and it still lands above the mutation boundary"

# ---------------------------------------------------------------------------
# T037 -- the push guard an ALREADY-INITIALIZED repository can actually reach.
#
# `orchid init` installs .git/hooks/pre-push and, until now, was the only
# thing that ever did -- and init runs exactly once in a repository's life
# (every later run dies with `branch orchid/integration exists`). So a
# repository initialized by an older orchid keeps that day's hook forever, no
# matter how many times orchid itself is upgraded: the run-state leg added by
# this task, the one refusal standing between a run's bookkeeping and a
# product's remote, would have reached exactly zero existing repositories. The
# leak this task exists for was reported from one of them.
#
# `orchid start` is the supported door back into an initialized repo, so it is
# where the upgrade lands (lib/common.sh's orchid_install_push_guard, the same
# function init calls).
#
# RED (before this fix): start touches no hook at all, so the stale one below
# survives the run and never grows the run-state leg.
# ---------------------------------------------------------------------------
r37_hook="$W/r37-hook"; mk_repo "$r37_hook" 'verify=true'
ORCHID_REPO="$r37_hook" "$ORCHID_BIN" init >/dev/null \
  || fail "fixture: orchid init must succeed on r37-hook"
hook37="$r37_hook/.git/hooks/pre-push"
[ -f "$hook37" ] || fail "fixture: init must have installed a push guard to go stale"

# Stand in for the hook a repository initialized by an older orchid carries:
# orchid's own, with the name-based leg only and no run-state leg.
#
# Line 2 is what identifies it, and it is deliberately NOT byte-identical to
# the template's own line 2 -- it STARTS with `# orchid pre-push guard` and
# then says something else. That is the GREEN half of the recognizer's second
# twin: the header is a prefix contract, so prose that has been reworded since
# a legacy hook was written still recognizes it, which is the only reason the
# upgrade reaches the repositories it exists for. The RED half -- a hook that
# mentions the same words somewhere OTHER than the start of line 2 -- is
# below, after the user-hook case.
cat > "$hook37" <<'STALE_HOOK'
#!/usr/bin/env bash
# orchid pre-push guard -- installed by `orchid init` (v1-m4 vintage: this is
# the whole hook a repository initialized before T037 carries).
[ "${ORCHID_ALLOW_PUSH:-0}" = 1 ] && exit 0
integ="orchid/integration"
exit 0
STALE_HOOK
chmod +x "$hook37"
grep -q "run state" "$hook37" \
  && fail "fixture: the stale hook must NOT already carry the run-state leg, or this case proves nothing"

out37_hook="$(ORCHID_REPO="$r37_hook" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must succeed on an already-initialized repo: $out37_hook"
assert_match "pre-push guard upgraded" "$out37_hook" \
  "start says it replaced the stale guard, rather than upgrading it silently"
assert_match "carries orchid.s own run state" "$(cat "$hook37")" \
  "an existing repository's stale hook GAINS the run-state leg -- the whole point of the upgrade"
assert_match "^integ=.orchid/integration.$" "$(cat "$hook37")" \
  "and the integration branch is still baked in, resolved at install time as ever"
[ -x "$hook37" ] || fail "an upgraded hook that is not executable is not a hook"
green_case 'a legacy hook whose line 2 STARTS with the header is recognized and upgraded'

# Idempotent, and quiet about it: the same start again must not report an
# upgrade it did not perform, or the line stops meaning anything. Re-run under
# the epoch the first one minted (INV-02: start never mints a fresh epoch over
# an existing one).
epoch37="$(cat "$W/r37-hook-orchid/.orchid/runtime/epoch" 2>/dev/null)"
[ -n "$epoch37" ] || epoch37=0
hook37_sum="$(cat "$hook37")"
out37_hook2="$(ORCHID_REPO="$r37_hook" ORCHID_EPOCH="$epoch37" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "a repeat start on the same repo must still succeed: $out37_hook2"
assert_eq "$hook37_sum" "$(cat "$hook37")" "a hook already current is left byte-for-byte alone"
grep -q "pre-push guard upgraded" <<<"$out37_hook2" \
  && fail "a repeat start must not claim an upgrade it did not make"

# The never-overwrite rule is NOT relaxed by any of this: a hook orchid did
# not write is the operator's, is authoritative whatever it does, and survives
# start untouched -- said out loud rather than skipped in silence.
r37_user="$W/r37-userhook"; mk_repo "$r37_user" 'verify=true'
mkdir -p "$r37_user/.git/hooks"
user_hook37="$r37_user/.git/hooks/pre-push"
printf '#!/bin/sh\n# my own pre-push hook\nexit 0\n' > "$user_hook37"
chmod +x "$user_hook37"
user_hook37_body="$(cat "$user_hook37")"
ORCHID_REPO="$r37_user" "$ORCHID_BIN" init >/dev/null \
  || fail "fixture: orchid init must succeed on r37-userhook"
out37_user="$(ORCHID_REPO="$r37_user" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must succeed on a repo carrying the operator's own pre-push hook: $out37_user"
assert_eq "$user_hook37_body" "$(cat "$user_hook37")" \
  "start never overwrites a pre-push hook orchid did not write"
assert_match "leaving it untouched" "$out37_user" \
  "and says so, so the operator knows the guard is not installed"

# ---------------------------------------------------------------------------
# The hook that MENTIONS orchid without being orchid's. This is the shape the
# never-overwrite rule is actually load-bearing for, and the one that used to
# lose: recognition was `grep -F` over the whole file, which asks "does this
# file contain the phrase anywhere" -- and the operator most likely to have
# written a deliberate pre-push hook is exactly the operator most likely to
# name orchid in it, in a comment or in a chain to orchid's own guard. Theirs
# was overwritten.
#
# Recognition is now POSITION plus ANCHOR: the second line, starting with the
# header. Both halves are exercised by the one fixture below --
#
#   line 2 contains the phrase, but not at the start   -> the ANCHOR half
#   line 3 starts with the phrase, but is not line 2   -> the POSITION half
#
# -- and either half failing overwrites a file the operator wrote by hand,
# which is the one outcome this function must never produce.
#
# Both verbs are asked, because both install the guard: init on the way in,
# start on every existing-repository pass afterwards.
#
# RED (before this fix): the hook below is replaced by orchid's template, its
# `exec` chain lost silently, and start reports an upgrade of a file it had no
# business touching.
# ---------------------------------------------------------------------------
r37_mention="$W/r37-mentionhook"; mk_repo "$r37_mention" 'verify=true'
mkdir -p "$r37_mention/.git/hooks"
mention_hook37="$r37_mention/.git/hooks/pre-push"
cat > "$mention_hook37" <<'MENTION_HOOK'
#!/bin/sh
# pre-push: my own checks run first, then the orchid pre-push guard.
# orchid pre-push guard -- chained below, if this checkout has one installed.
./scripts/my-own-checks.sh || exit 1
exec "$(dirname "$0")/pre-push.orchid" "$@"
MENTION_HOOK
chmod +x "$mention_hook37"
mention_hook37_body="$(cat "$mention_hook37")"
grep -Fq "orchid pre-push guard" "$mention_hook37" \
  || fail "fixture: the operator's hook must MENTION the phrase, or it tests nothing"
ORCHID_REPO="$r37_mention" "$ORCHID_BIN" init >/dev/null \
  || fail "fixture: orchid init must succeed on r37-mentionhook"
assert_eq "$mention_hook37_body" "$(cat "$mention_hook37")" \
  "init leaves a hook that merely MENTIONS orchid byte-for-byte alone"
out37_mention="$(ORCHID_REPO="$r37_mention" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must succeed on a repo carrying such a hook: $out37_mention"
assert_eq "$mention_hook37_body" "$(cat "$mention_hook37")" \
  "and so does start -- a mention of the marker is not the marker"
assert_match "leaving it untouched" "$out37_mention" \
  "and start says the guard is not installed rather than claiming an upgrade"
grep -q "pre-push guard upgraded" <<<"$out37_mention" \
  && fail "orchid must never report upgrading a hook the operator wrote"
red_case 'a user hook that MENTIONS the marker off line 2 is left byte-for-byte alone'

# `push_guard=false` still opts out of the whole thing, upgrade included.
r37_off="$W/r37-guardoff"; mk_repo "$r37_off" 'verify=true' 'push_guard=false'
ORCHID_REPO="$r37_off" "$ORCHID_BIN" init >/dev/null \
  || fail "fixture: orchid init must succeed on r37-guardoff"
[ -e "$r37_off/.git/hooks/pre-push" ] && fail "fixture: push_guard=false must install no hook"
out37_off="$(ORCHID_REPO="$r37_off" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must succeed with push_guard=false: $out37_off"
[ -e "$r37_off/.git/hooks/pre-push" ] \
  && fail "push_guard=false must opt out of the existing-repository upgrade too"

# ---------------------------------------------------------------------------
# T037 -- a RELATIVE `core.hooksPath` is not one hook file, it is one PER
# WORKTREE, so orchid installs nothing and says so.
#
# `core.hooksPath` relocates every hook in a repository, and plenty of real
# projects set it: a shared team hooks directory, a `.githooks/` tracked in
# the tree, anything Husky-shaped. Orchid used to derive
# `<git-common-dir>/hooks` by hand and write there regardless -- so on such a
# repository the guard landed in `.git/hooks/`, which git no longer reads, and
# orchid REPORTED it as installed. That is worse than installing nothing: an
# inert file at a path nothing executes reads, to an operator and to `ls`,
# exactly like protection.
#
# Asking git for the path fixes the ABSOLUTE spelling (below) and does NOT fix
# the relative one, which is a different defect wearing the same clothes.
# git's rule for a relative value (githooks(5), `core.hooksPath`) is that it
# resolves against the directory hooks are RUN from -- the top level of the
# working tree the push comes from. The key lives in the shared config, so
# every checkout reads the same string and resolves it somewhere else, and
# orchid gives the integration branch and every task a linked worktree of its
# own. Installing into the one checkout the process can see and reporting
# `installed` would be the same false protection at a new address.
#
# THE PREMISE IS PROVED HERE, NOT ASSERTED: the guard is installed by hand into
# the main checkout's copy, a linked worktree is added, and the same managed
# push is refused from one and allowed from the other.
#
# RED (before this fix): init writes `ci-hooks/pre-push` and prints
# "pre-push guard installed", claiming a repository-wide guard from a file that
# covers exactly one of this repository's checkouts.
# ---------------------------------------------------------------------------
r37_hp="$W/r37-hookspath"; mk_repo "$r37_hp" 'verify=true'
git -C "$r37_hp" config core.hooksPath ci-hooks

# `orchid doctor` first, on the bare fixture: this is where an operator meets
# the condition without having run a verb that installs hooks, and it is the
# same preflight `orchid start` runs. It WARNS and never fails -- an
# unguardable hooks layout is a risk, not a broken repository, and failing here
# would take start's own preflight down with it.
rc=0; doc37_hp="$(ORCHID_REPO="$r37_hp" "$ORCHID_BIN" doctor 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "the hooks-path warning must never flip doctor's exit code: $doc37_hp"
assert_match "WARN: push guard: core.hooksPath is set to the RELATIVE path" "$doc37_hp" \
  "doctor names the condition in the same words the installer uses"
assert_match "config --unset core.hooksPath" "$doc37_hp" \
  "and carries the recovery with it, rather than only the diagnosis"

out37_hp="$(ORCHID_REPO="$r37_hp" "$ORCHID_BIN" init 2>&1)" \
  || fail "init must still succeed on a repo that configures core.hooksPath: $out37_hp"
[ -e "$r37_hp/ci-hooks/pre-push" ] \
  && fail "a relative core.hooksPath must install NOTHING -- one checkout's hook is not a repository's guard"
[ -e "$r37_hp/.git/hooks/pre-push" ] \
  && fail "and .git/hooks is not a fallback: git does not read it once core.hooksPath is set"
assert_match "core.hooksPath is set to the RELATIVE path .ci-hooks." "$out37_hp" \
  "init names the setting and its value"
assert_match "EACH worktree.s own top level" "$out37_hp" \
  "and names the reason -- git resolves it per checkout, not per repository"
assert_match "was NOT installed" "$out37_hp" \
  "and says plainly that this repository is unguarded"
# The absolute recovery names a REAL directory inside this repository's git
# dir, never a `/absolute/path/to/hooks` placeholder: an absolute path outside
# the git dir is itself unsupported (the shared-hooks case below), so a
# placeholder would invite the operator to point the key at their ~/.githooks
# and meet this same refusal a second time.
assert_match "config core.hooksPath '$r37_hp/.git/hooks'" "$out37_hp" \
  "the absolute recovery, as a command, naming a directory this repository owns"
assert_match "config --unset core.hooksPath" "$out37_hp" \
  "and the unset recovery, as a command"
assert_match "refresh-push-guard" "$out37_hp" \
  "and what to run once it is changed, so the fix has an end"
grep -q "guard installed" <<<"$out37_hp" \
  && fail "no output may claim an install that did not happen"
grep -q "already current" <<<"$out37_hp" \
  && fail "and none may claim the repository is current"
assert_eq "ci-hooks" "$(git -C "$r37_hp" config --get core.hooksPath)" \
  "orchid never rewrites the operator's own git configuration to make itself installable"

# The premise, proved. Install orchid's guard BY HAND at the path the main
# checkout resolves -- so the only thing under test is git's resolution rule,
# not orchid's refusal -- then ask for the same managed push from two
# checkouts of the same repository.
mkdir -p "$r37_hp/ci-hooks"
sed 's|__INTEGRATION_BRANCH__|orchid/integration|g' "$REPO_ROOT/templates/pre-push.sh" \
  > "$r37_hp/ci-hooks/pre-push"
chmod +x "$r37_hp/ci-hooks/pre-push"
remote37_hp="$W/r37-hookspath-remote.git"
git init -q --bare "$remote37_hp"
git -C "$r37_hp" remote add origin "$remote37_hp"
rc=0; push37_hp="$(git -C "$r37_hp" push origin orchid/integration 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "fixture: a hand-installed guard at the MAIN checkout's resolved path must refuse a managed push, or this case proves nothing"
assert_match "push blocked" "$push37_hp" \
  "fixture: and the refusal is orchid's own hook speaking"

git -C "$r37_hp" worktree add -q "$W/r37-hookspath-wt" -b hp-linked \
  || fail "fixture: a linked worktree must be addable"
[ -e "$W/r37-hookspath-wt/ci-hooks/pre-push" ] \
  && fail "fixture: the linked worktree must NOT have its own copy, which is the whole point"
rc=0; push37_hp_wt="$(git -C "$W/r37-hookspath-wt" push origin orchid/integration 2>&1)" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "the SAME push from a linked worktree must go through unguarded, since git resolves 'ci-hooks' against that worktree's own top level (got: $push37_hp_wt)"
grep -q "push blocked" <<<"$push37_hp_wt" \
  && fail "and no hook may have run there -- if one did, this repository would be guardable after all"
red_case 'a relative core.hooksPath installs nothing and is reported, because one file cannot guard every worktree'

# An ABSOLUTE core.hooksPath INSIDE this repository's own git directory, in a
# directory whose name contains a space -- the supported relocation, and the
# quoting that has to survive it.
#
# Inside the git dir is the whole condition (T037, after review): a directory
# under `.git/` belongs to this repository by construction and cannot be the
# one another repository reads, which is what makes writing a guard there --
# with THIS repository's integration branch baked in -- a decision about this
# repository alone. The external spelling is a separate case below.
r37_hpa="$W/r37-hookspath-abs"; mk_repo "$r37_hpa" 'verify=true'
hp_abs="$r37_hpa/.git/r37 hooks dir"
mkdir -p "$hp_abs"
git -C "$r37_hpa" config core.hooksPath "$hp_abs"
out37_hpa="$(ORCHID_REPO="$r37_hpa" "$ORCHID_BIN" init 2>&1)" \
  || fail "init must succeed with an absolute core.hooksPath containing a space: $out37_hpa"
[ -x "$hp_abs/pre-push" ] \
  || fail "an absolute core.hooksPath is honored too, spaces and all"
[ -e "$r37_hpa/.git/hooks/pre-push" ] \
  && fail "and again nothing is written to the .git/hooks git is configured not to read"
assert_match "pre-push guard installed: $hp_abs/pre-push" "$out37_hpa" \
  "the reported path is the configured one"
grep -q "RELATIVE path" <<<"$out37_hpa" \
  && fail "a repo-contained absolute core.hooksPath must keep normal behavior -- no warning, no refusal"
grep -q "ABSOLUTE path" <<<"$out37_hpa" \
  && fail "and it is not the shared-directory case either: this one IS inside the repository's git dir"

# And it is genuinely REPOSITORY-WIDE, which is the whole difference: one
# absolute path is the same file for every checkout, so the linked worktree
# that walked straight past the relative spelling above is guarded here.
remote37_hpa="$W/r37-hookspath-abs-remote.git"
git init -q --bare "$remote37_hpa"
git -C "$r37_hpa" remote add origin "$remote37_hpa"
git -C "$r37_hpa" worktree add -q "$W/r37-hookspath-abs-wt" -b hpa-linked \
  || fail "fixture: a linked worktree must be addable"
rc=0
push37_hpa="$(git -C "$W/r37-hookspath-abs-wt" push origin orchid/integration 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "an absolute core.hooksPath must guard EVERY checkout, linked worktrees included (got: $push37_hpa)"
assert_match "push blocked" "$push37_hpa" \
  "and the refusal is orchid's own hook, running from a worktree it was never installed into"

# The GREEN control, so the case above cannot pass because the hook refuses
# everything: an ordinary branch carrying no run state still pushes.
rc=0; push37_hpa_ok="$(git -C "$r37_hpa" push origin hpa-linked 2>&1)" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "the relocated guard must still let an unmanaged branch through (got: $push37_hpa_ok)"

# And doctor is SILENT about a repository it can guard -- the twin of the WARN
# asserted on the relative fixture above, and the half that makes that WARN
# evidence of detection rather than of a classifier that answers `relative` for
# everything. Both guardable spellings are asked: the absolute value here, and
# the unset default on the r37-hook repository set up earlier in this file.
doc37_hpa="$(ORCHID_REPO="$r37_hpa" "$ORCHID_BIN" doctor 2>&1 || true)"
grep -q "WARN: push guard" <<<"$doc37_hpa" \
  && fail "doctor must not warn about a repo-contained absolute core.hooksPath -- that layout IS guarded"
doc37_def="$(ORCHID_REPO="$r37_hook" "$ORCHID_BIN" doctor 2>&1 || true)"
grep -q "WARN: push guard" <<<"$doc37_def" \
  && fail "and must not warn about git's own default, where core.hooksPath is unset entirely"
green_case 'a repo-contained absolute core.hooksPath keeps normal behavior and guards every worktree of the repository'

# ---------------------------------------------------------------------------
# T037 -- an ABSOLUTE core.hooksPath OUTSIDE the git directory is a hooks
# directory orchid does not own, and TWO repositories pointing at one is why.
#
# An absolute path says nothing about whose directory it is. `~/.githooks`, a
# team mount, a `git config --global core.hooksPath` set once by a dotfiles
# repository: every repository on the machine then reads the same files.
# Installing orchid's guard there is not "guarding this repository", it is
# writing a hook -- carrying THIS repository's integration branch name, baked
# in at install time -- in front of every repository that shares it, and
# overwriting whatever another one had installed for the same reason. The
# never-overwrite rule cannot save the second repository either: the hook
# orchid wrote for the first IS orchid's own hook, so it is recognized and
# replaced rather than left alone.
#
# So the supported shape is the containable one, and this case is the twin of
# the fixture just above: the same absolute spelling, the same quoting, the
# only difference being which directory it names.
#
# RED (before this fix): the first init writes the shared hook and reports it
# installed; the second init overwrites it with its own integration branch,
# reports an upgrade, and the first repository's guard is silently gone.
# ---------------------------------------------------------------------------
hp_shared="$W/r37 shared hooks"
mkdir -p "$hp_shared"
r37_sh1="$W/r37-shared-one"; mk_repo "$r37_sh1" 'verify=true'
r37_sh2="$W/r37-shared-two"; mk_repo "$r37_sh2" 'verify=true'
git -C "$r37_sh1" config core.hooksPath "$hp_shared"
git -C "$r37_sh2" config core.hooksPath "$hp_shared"

rc=0; doc37_sh="$(ORCHID_REPO="$r37_sh1" "$ORCHID_BIN" doctor 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "an unguardable hooks layout must never flip doctor's exit code: $doc37_sh"
assert_match "WARN: push guard: core.hooksPath is set to the ABSOLUTE path" "$doc37_sh" \
  "doctor names the condition before any verb has installed anything"
assert_match "OUTSIDE this repository's git directory" "$doc37_sh" \
  "and names the reason, which is containment and not absoluteness"

out37_sh1="$(ORCHID_REPO="$r37_sh1" "$ORCHID_BIN" init 2>&1)" \
  || fail "init must still succeed on a repo whose hooks are shared: $out37_sh1"
assert_match "core.hooksPath is set to the ABSOLUTE path .$hp_shared." "$out37_sh1" \
  "init names the setting and its value"
assert_match "was NOT installed" "$out37_sh1" \
  "and says plainly that this repository is unguarded"
assert_match "config core.hooksPath '$r37_sh1/.git/hooks'" "$out37_sh1" \
  "the recovery names an absolute directory inside THIS repository's git dir"
assert_match "config --unset core.hooksPath" "$out37_sh1" \
  "and the unset recovery, as a command"
assert_match "refresh-push-guard" "$out37_sh1" \
  "and what to run once it is changed"
grep -q "guard installed" <<<"$out37_sh1" \
  && fail "no output may claim an install into a directory orchid does not own"
grep -q "already current" <<<"$out37_sh1" \
  && fail "nor that the repository is current"
[ -e "$hp_shared/pre-push" ] \
  && fail "and nothing at all is written into the shared directory"
[ -e "$r37_sh1/.git/hooks/pre-push" ] \
  && fail "nor to the .git/hooks git is configured not to read"
assert_eq "$hp_shared" "$(git -C "$r37_sh1" config --get core.hooksPath)" \
  "orchid never rewrites the operator's own git configuration to make itself installable"

# The second repository is the point: it shares the directory, and neither
# repository's setup may put anything in front of the other.
ORCHID_REPO="$r37_sh2" "$ORCHID_BIN" init >/dev/null 2>&1 \
  || fail "fixture: init must succeed on the second repository too"
out37_sh2="$(ORCHID_REPO="$r37_sh2" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "a shared hooks directory must not stop a run being set up: $out37_sh2"
assert_match "orchid: core.hooksPath is set to the ABSOLUTE path" "$out37_sh2" \
  "start's own install call names it, not just its doctor preflight"
grep -q "guard upgraded" <<<"$out37_sh2" \
  && fail "start carries the upgrade, so it is the door that must not write into a shared directory"
[ -e "$hp_shared/pre-push" ] \
  && fail "no hook may exist in the shared directory after BOTH repositories have been set up"
[ -f "$W/r37-shared-two-orchid/.orchid/roadmap.md" ] \
  || fail "and the run must still have been set up: an unguardable hooks layout is reported, never fatal"

# The explicit route refuses too, and refuses NON-ZERO -- the one command whose
# whole purpose is to install the guard must not answer "done" with nothing on
# disk.
rc=0
out37_shref="$(ORCHID_REPO="$r37_sh1" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "--refresh-push-guard must not report success where it will not install: $out37_shref"
assert_match "outside this repository's git directory" "$out37_shref" "naming why it refused"
assert_match "config --unset core.hooksPath" "$out37_shref" "and carrying the recovery"
grep -q "already current" <<<"$out37_shref" \
  && fail "a refusal must never also claim the guard is current"
grep -q "guard installed" <<<"$out37_shref" \
  && fail "nor claim an install"
[ -e "$hp_shared/pre-push" ] \
  && fail "and the shared directory is still untouched"
red_case 'an absolute core.hooksPath outside the git dir installs nothing, because the directory may be another repository'

# ---------------------------------------------------------------------------
# T037 -- the THIRD door onto a relative `core.hooksPath`: `orchid start`'s
# existing-repository path.
#
# `orchid init` is covered above and `--refresh-push-guard` below, but the door
# an operator actually walks through on a repository that is already
# initialized and still in `planning` is a plain `orchid start` -- and it is
# the door that carries the hook UPGRADE, so it is the one most likely to write
# a per-worktree file and call the repository protected.
#
# It must warn, install nothing, claim nothing, and STILL SET THE RUN UP: a
# hooks layout orchid cannot guard is a risk to report, never a reason to
# refuse a run. Both prefixes are pinned because both legs have to be there --
# `WARN: push guard:` is the doctor preflight, `orchid:` is start's own install
# call further down, and a fix that only reached one of them would leave the
# other silently claiming or silently skipping.
#
# RED (before this fix): start writes `ci-hooks/pre-push` in the main checkout
# and prints "pre-push guard upgraded", which is a repository-wide claim made
# from a file that covers exactly one of this repository's checkouts.
# ---------------------------------------------------------------------------
r37_hps="$W/r37-hookspath-start"; mk_repo "$r37_hps" 'verify=true'
git -C "$r37_hps" config core.hooksPath ci-hooks
ORCHID_REPO="$r37_hps" "$ORCHID_BIN" init >/dev/null 2>&1 \
  || fail "fixture: init must succeed under a relative core.hooksPath"
out37_hps="$(ORCHID_REPO="$r37_hps" "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "a hooks layout orchid cannot guard must not stop a run being set up: $out37_hps"
assert_match "orchid: core.hooksPath is set to the RELATIVE path .ci-hooks." "$out37_hps" \
  "start's own install call names the condition, not just its doctor preflight"
assert_match "WARN: push guard: core.hooksPath is set to the RELATIVE path" "$out37_hps" \
  "and the preflight names it too -- every door, or an operator meets it at none"
assert_match "config core.hooksPath /absolute/path/to/hooks" "$out37_hps" \
  "with the absolute recovery"
assert_match "config --unset core.hooksPath" "$out37_hps" \
  "and the unset recovery, as commands"
grep -q "guard installed" <<<"$out37_hps" \
  && fail "start may not claim an install it did not perform"
grep -q "guard upgraded" <<<"$out37_hps" \
  && fail "nor an upgrade -- this is the door that carries the upgrade, so it is the one that must not"
grep -q "already current" <<<"$out37_hps" \
  && fail "nor that a repository nothing guards is current"
[ -e "$r37_hps/ci-hooks/pre-push" ] \
  && fail "and nothing is written to the one checkout this process happens to see"
[ -e "$r37_hps/.git/hooks/pre-push" ] \
  && fail "nor to the .git/hooks git is configured not to read"
assert_eq "ci-hooks" "$(git -C "$r37_hps" config --get core.hooksPath)" \
  "start never rewrites the operator's git configuration to make orchid installable"
# Non-vacuity: the run really was set up, so the assertions above are about a
# start that RAN rather than one that died early for some unrelated reason.
[ -f "$W/r37-hookspath-start-orchid/.orchid/roadmap.md" ] \
  || fail "the run must still have been set up: an unguardable hooks layout is reported, never fatal"
red_case 'orchid start warns and installs nothing under a relative core.hooksPath, and still sets the run up'

# ---------------------------------------------------------------------------
# T037 -- `orchid start --refresh-push-guard`: the route into a repository
# whose run has already left planning.
#
# The upgrade above rides `orchid start`, and start is a SETUP command: rule 3
# at the top of libexec/orchid-start refuses a run past `planning` outright.
# So every repository that is actually running -- which is every repository
# the reported leak could come from, including the one it did come from --
# could not reach a newer guard at all. `orchid init` is no help either; it
# dies on `branch orchid/integration exists`.
#
# The answer is an explicit invocation, not a side effect: calling the
# installer above the planning check would work, and would also mean a command
# that refuses on the very next line had quietly rewritten a file under
# `.git/` first. "run r-001 has already left planning" reads as "nothing
# happened", and a mutation nobody can name is a mutation nobody can audit.
#
# RED (before this fix): there is no such form -- start exits with "unknown
# option '--refresh-push-guard'" -- and the stale hook below survives the run
# forever.
# ---------------------------------------------------------------------------
r37_pp="$W/r37-pastplanning"; mk_repo "$r37_pp" 'verify=true'
ORCHID_REPO="$r37_pp" "$ORCHID_BIN" start "$REQ" >/dev/null 2>&1 \
  || fail "fixture: start must set r37-pastplanning up"
ORCHID_REPO="$W/r37-pastplanning-orchid" ORCHID_EPOCH=0 "$ORCHID_BIN" plan apply --reason "first plan" >/dev/null 2>&1 \
  || fail "fixture: plan apply must take this run out of planning"
assert_match "^run_status: running$" "$(git -C "$r37_pp" show 'orchid/integration:.orchid/roadmap.md')" \
  "fixture: the run must really be past planning, or every case below is vacuous"

# The hook a repository initialized by an older orchid carries: orchid's own
# (line 2 starts with the header), name-based leg only, no run-state leg.
hook37_pp="$r37_pp/.git/hooks/pre-push"
cat > "$hook37_pp" <<'STALE_PP_HOOK'
#!/usr/bin/env bash
# orchid pre-push guard -- installed by `orchid init` (v1-m4 vintage).
[ "${ORCHID_ALLOW_PUSH:-0}" = 1 ] && exit 0
integ="orchid/integration"
exit 0
STALE_PP_HOOK
chmod +x "$hook37_pp"
stale37_pp="$(cat "$hook37_pp")"
grep -q "run state" "$hook37_pp" \
  && fail "fixture: the stale hook must NOT already carry the run-state leg"

# A normal start still refuses here -- and must not have touched the hook on
# its way to that refusal.
rc=0
out37_pp="$(ORCHID_REPO="$r37_pp" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must still refuse a run that has left planning"
assert_match "has already left planning" "$out37_pp" "and say so plainly"
assert_eq "$stale37_pp" "$(cat "$hook37_pp")" \
  "a start that refuses must not have rewritten a file under .git/ first"

refs37_pp="$(git -C "$r37_pp" for-each-ref --format='%(refname) %(objectname)')"
out37_ref="$(ORCHID_REPO="$r37_pp" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" \
  || fail "--refresh-push-guard must succeed against a run past planning: $out37_ref"
assert_match "pre-push guard upgraded: $hook37_pp" "$out37_ref" \
  "the explicit route names the file it replaced"
assert_match "carries orchid.s own run state" "$(cat "$hook37_pp")" \
  "and the stale hook finally gains the run-state leg -- the whole reason the route exists"
[ -x "$hook37_pp" ] || fail "a refreshed hook that is not executable is not a hook"
red_case 'a run past planning reaches the current push guard via start --refresh-push-guard'

# Idempotent, and explicit about it: this is the one command an operator runs
# to fix exactly this, so "already current" is the answer, not silence.
body37_pp="$(cat "$hook37_pp")"
out37_ref2="$(ORCHID_REPO="$r37_pp" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" \
  || fail "a repeat --refresh-push-guard must still succeed: $out37_ref2"
assert_match "pre-push guard already current: $hook37_pp" "$out37_ref2" \
  "a second run reports the state it found rather than claiming an upgrade"
grep -q "pre-push guard upgraded" <<<"$out37_ref2" \
  && fail "and it must never report an upgrade it did not make"
assert_eq "$body37_pp" "$(cat "$hook37_pp")" "a current hook is left byte-for-byte alone"

# It installs a hook and does nothing else -- no ref moves, no commit, no run
# state written -- which is what makes it safe against a run in flight.
assert_eq "$refs37_pp" "$(git -C "$r37_pp" for-each-ref --format='%(refname) %(objectname)')" \
  "--refresh-push-guard moves no ref in the repository it runs against"
assert_match "^run_status: running$" "$(git -C "$r37_pp" show 'orchid/integration:.orchid/roadmap.md')" \
  "and neither resumes nor rewinds the run it ran alongside"
green_case '--refresh-push-guard is idempotent and mutates nothing but the hook'

# It is maintenance, not setup, and refuses anything that would read as setup
# rather than half-performing it.
rc=0
out37_req="$(ORCHID_REPO="$r37_pp" "$ORCHID_BIN" start --refresh-push-guard "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--refresh-push-guard must refuse a requirements file"
assert_match "takes no requirements file" "$out37_req" "and name what it refused"
rc=0
out37_opt="$(ORCHID_REPO="$r37_pp" "$ORCHID_BIN" start --refresh-push-guard --verify 'true' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--refresh-push-guard must refuse a setup option it cannot act on"
assert_match "takes no other option" "$out37_opt" "and say why"

# Run from the integration WORKTREE, which is where an operator mid-run
# actually is. A linked worktree shares the main checkout's hooks directory,
# and `git rev-parse --git-path` maps `hooks/` onto the common git dir for
# exactly that reason -- so this call must find the hook already installed at
# the MAIN checkout rather than conclude there is none here.
#
# "already current" is the whole proof: a route that resolved a
# worktree-local hooks path would find no file there, install a second copy,
# and report `installed`.
[ -f "$W/r37-pastplanning-orchid/.git" ] \
  || fail "fixture: the integration worktree must be a LINKED worktree (.git as a file) for this case to mean anything"
out37_wtref="$(ORCHID_REPO="$W/r37-pastplanning-orchid" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" \
  || fail "--refresh-push-guard must work from the integration worktree: $out37_wtref"
assert_match "pre-push guard already current: .*/[.]git/hooks/pre-push" "$out37_wtref" \
  "a linked worktree resolves the shared hooks dir, not one of its own"
assert_eq "$body37_pp" "$(cat "$hook37_pp")" \
  "and the one shared hook is what it found -- unchanged, not duplicated"

# An ABSOLUTE core.hooksPath is resolved by this route too, at inspection as
# well as at install: a route that looked in .git/hooks would find nothing
# there and report an install it had already performed elsewhere.
out37_hpa_ref="$(ORCHID_REPO="$r37_hpa" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" \
  || fail "--refresh-push-guard must succeed under an absolute core.hooksPath: $out37_hpa_ref"
assert_match "pre-push guard already current: $hp_abs/pre-push" "$out37_hpa_ref" \
  "it inspects and reports the same path git runs, so it re-installs nothing"
[ -e "$r37_hpa/.git/hooks/pre-push" ] \
  && fail "and it still writes nothing to the .git/hooks git does not read"

# A RELATIVE one refuses, and refuses NON-ZERO: this is the one command whose
# entire purpose is to put a guard in place, so "did nothing" must not read as
# "done". It installs nothing at either candidate path and says neither
# `installed` nor `already current` -- the hand-installed file from the case
# far above is still exactly where the fixture put it, untouched.
hp_body37="$(cat "$r37_hp/ci-hooks/pre-push")"
rc=0
out37_hp_ref="$(ORCHID_REPO="$r37_hp" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || fail "--refresh-push-guard must not report success where it cannot install a repository-wide guard: $out37_hp_ref"
assert_match "core.hooksPath is relative" "$out37_hp_ref" "naming why it refused"
assert_match "config --unset core.hooksPath" "$out37_hp_ref" "and carrying the recovery"
grep -q "already current" <<<"$out37_hp_ref" \
  && fail "a refusal must never also claim the guard is current"
grep -q "guard installed" <<<"$out37_hp_ref" \
  && fail "nor claim an install"
grep -q "guard upgraded" <<<"$out37_hp_ref" \
  && fail "nor an upgrade"
assert_eq "$hp_body37" "$(cat "$r37_hp/ci-hooks/pre-push")" \
  "and it writes nothing at the per-worktree path either"
[ -e "$r37_hp/.git/hooks/pre-push" ] \
  && fail "nor falls back to the .git/hooks git does not read"
red_case 'start --refresh-push-guard exits non-zero under a relative core.hooksPath instead of half-installing'

# The never-overwrite rule holds through the explicit route, and the route
# says so with a non-zero exit: the operator asked for a guard git will run,
# and there is not one.
rc=0
out37_userref="$(ORCHID_REPO="$r37_user" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "the route must not report success when no guard was installed"
assert_eq "$user_hook37_body" "$(cat "$user_hook37")" \
  "--refresh-push-guard never overwrites a hook orchid did not write, either"
assert_match "is yours, not orchid.s" "$out37_userref" "it says whose file that is"
assert_match "exec" "$out37_userref" "and how to have both, rather than only what it would not do"
red_case '--refresh-push-guard refuses rather than overwriting an operator-authored hook'

# An opted-out repository is told, never silently left unguarded.
rc=0
out37_offref="$(ORCHID_REPO="$r37_off" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "push_guard=false must be reported, not answered with a shrug"
assert_match "push_guard is off" "$out37_offref" "naming the setting that turned it off"
[ -e "$r37_off/.git/hooks/pre-push" ] \
  && fail "and the opt-out is still honored -- nothing is installed"

# And it is maintenance for an ALREADY-INITIALIZED repository: with no run to
# guard it points at the setup that installs the guard itself.
r37_noinit="$W/r37-noinit"; mk_repo "$r37_noinit" 'verify=true'
rc=0
out37_noinit="$(ORCHID_REPO="$r37_noinit" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--refresh-push-guard must refuse a repository with no run in it"
assert_match "has no orchid/integration branch" "$out37_noinit" "naming what is missing"
assert_match "orchid start <requirements-file>" "$out37_noinit" "and the command that sets it up"
[ -e "$r37_noinit/.git/hooks/pre-push" ] \
  && fail "an uninitialized repository gets no hook out of a refusal"

# ---------------------------------------------------------------------------
# T037 -- a guard whose BYTES are current but whose execute bit is gone.
#
# git runs a hook by exec'ing it and does exactly nothing when the file is not
# executable: no error, no warning, the push simply proceeds. So the execute
# bit is not a detail of "installed", it is half of it -- and it goes missing
# for ordinary reasons: a hook copied out of a template directory with `cp`, a
# restore from an archive that dropped the mode, a tight `umask`, an orchid
# install whose own chmod failed. Comparing bytes alone answers "already
# current" about a repository nothing is guarding.
#
# RED (before this fix): the refresh below prints "already current" and exits
# 0 while the push that follows it goes straight through.
# ---------------------------------------------------------------------------
r37_x="$W/r37-noexec"; mk_repo "$r37_x" 'verify=true'
ORCHID_REPO="$r37_x" "$ORCHID_BIN" init >/dev/null \
  || fail "fixture: orchid init must succeed on r37-noexec"
hook37_x="$r37_x/.git/hooks/pre-push"
[ -x "$hook37_x" ] || fail "fixture: init must leave an executable guard for this case to strip"
body37_x="$(cat "$hook37_x")"
# TWO remotes, and that is not incidental. git skips an already-up-to-date ref
# when it feeds the pre-push hook, so pushing the same branch to the same
# remote twice hands the hook an empty stdin the second time and it exits 0
# having judged nothing -- a "refused" that proves the repair and a "passed"
# that proves nothing would be indistinguishable. Each push below therefore
# has real work to do.
remote37_x="$W/r37-noexec-remote.git"
git init -q --bare "$remote37_x"
git -C "$r37_x" remote add origin "$remote37_x"
remote37_x2="$W/r37-noexec-remote2.git"
git init -q --bare "$remote37_x2"
git -C "$r37_x" remote add second "$remote37_x2"

# Non-vacuity first: with the bit off, the guard is genuinely inert. If this
# push were refused anyway, everything below would prove nothing.
chmod -x "$hook37_x"
rc=0; push37_x="$(git -C "$r37_x" push origin orchid/integration 2>&1)" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "fixture: a non-executable hook must be inert, or this case has nothing to repair (got: $push37_x)"
grep -q "push blocked" <<<"$push37_x" \
  && fail "fixture: git must have run nothing at all with the execute bit off"

rc=0; out37_x="$(ORCHID_REPO="$r37_x" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "--refresh-push-guard must repair the bit and succeed: $out37_x"
assert_match "pre-push guard repaired: $hook37_x" "$out37_x" \
  "the repair is reported -- the bytes did not change, but the repository's protection did"
assert_match "not executable" "$out37_x" "and says what was wrong with it"
grep -q "already current" <<<"$out37_x" \
  && fail "a hook git will not run must never be reported as current"
[ -x "$hook37_x" ] || fail "and the execute bit is actually back"
assert_eq "$body37_x" "$(cat "$hook37_x")" \
  "while the bytes are left exactly as they were -- this is a chmod, not a rewrite"

# Proved by the push, not by the stat: the same branch, to a remote that does
# not have it yet, is refused now.
rc=0; push37_x2="$(git -C "$r37_x" push second orchid/integration 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "the repaired guard must actually refuse a managed push"
assert_match "push blocked" "$push37_x2" "and it is orchid's own hook speaking"
red_case 'a byte-current but non-executable guard is repaired and reported, never called current'

# The GREEN twin: once the bit is really set, the very next run is `already
# current` again and reports no repair it did not perform.
out37_x2="$(ORCHID_REPO="$r37_x" "$ORCHID_BIN" start --refresh-push-guard 2>&1)" \
  || fail "a repeat refresh must still succeed: $out37_x2"
assert_match "pre-push guard already current: $hook37_x" "$out37_x2" \
  "an executable, byte-current guard is current -- both halves, or neither"
grep -q "guard repaired" <<<"$out37_x2" \
  && fail "and no repair may be claimed once there is nothing to repair"
[ -x "$hook37_x" ] || fail "and the bit the previous run restored is still set"
green_case 'an executable, byte-current guard is reported current and repaired never'

# ---------------------------------------------------------------------------
# T037 -- a Gerrit review upload is a BRANCH-BOUND push, and the run-state leg
# must read it as one.
#
# The leg refuses a branch whose tip carries `.orchid/`. On a Gerrit-hosted
# project that leg never sees a branch: nobody pushes `refs/heads/main` at all,
# the upload IS the push (`git push origin HEAD:refs/for/main`), and the change
# is submitted onto `main` afterwards on the forge, where no local hook runs.
# A leg scoped to `refs/heads/*` therefore passes every Gerrit upload straight
# through -- the whole leak, on an entire class of repository, walking past a
# guard that reports itself installed.
#
# It fails CLOSED, and it has to: `refs/for/...` is magic, never advertised by
# the remote, so the remote sha git supplies is all zeros and the
# already-carries-run-state exemption can never apply. The refusal says that
# rather than offering the push-once-with-the-override recovery, which would
# leave a Gerrit operator refused identically on their next upload.
#
# RED (before this fix): every push below succeeds and run state is uploaded
# for review, then submitted onto the product's branch.
# ---------------------------------------------------------------------------
r37_g="$W/r37-gerrit"; mk_repo "$r37_g" 'verify=true'
ORCHID_REPO="$r37_g" "$ORCHID_BIN" init >/dev/null \
  || fail "fixture: orchid init must succeed on r37-gerrit"
[ -x "$r37_g/.git/hooks/pre-push" ] || fail "fixture: init must have installed the guard"
g37_branch="$(git -C "$r37_g" rev-parse --abbrev-ref HEAD)"
remote37_g="$W/r37-gerrit-remote.git"; git init -q --bare "$remote37_g"
git -C "$r37_g" remote add origin "$remote37_g"

# The realistic shape: an ordinarily-named feature branch that picked up run
# state by merging the integration branch, uploaded for review.
git -C "$r37_g" branch feature/gerrit orchid/integration
[ -n "$(git -C "$r37_g" ls-tree feature/gerrit -- .orchid)" ] \
  || fail "fixture: the uploaded branch must actually carry .orchid/, or this case proves nothing"

rc=0
g37_push="$(git -C "$r37_g" push origin "feature/gerrit:refs/for/$g37_branch" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a review upload carrying run state must be refused (got: $g37_push)"
assert_match "push blocked" "$g37_push" "and it is orchid's own hook speaking"
assert_match "carries orchid.s own run state" "$g37_push" "which says what is on the tip"
assert_match "review upload for branch .$g37_branch." "$g37_push" \
  "naming the branch submitting it would land the state on, which is the ref the operator can act on"
grep -q "every later push of this ref is exempt" <<<"$g37_push" \
  && fail "the branch leg's exemption cannot exist for a magic ref the remote never advertises, so it must not be offered"
# The remote is asked for EVERY ref and the answer filtered here, rather than
# handed `refs/for/*` as an ls-remote pattern: this has to be able to prove an
# ABSENCE, and a pattern that silently matched nothing would prove it for free.
grep -q "refs/for/" <<<"$(git -C "$r37_g" ls-remote "$remote37_g" 2>/dev/null || true)" \
  && fail "a blocked upload must not have landed on the remote"

# The fully-qualified spelling, and a push-option suffix -- both are ordinary
# Gerrit, and both are what git hands the hook verbatim.
rc=0
g37_push2="$(git -C "$r37_g" push origin "feature/gerrit:refs/for/refs/heads/$g37_branch%topic=leak,r=someone" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "the fully-qualified spelling with push options must be refused too (got: $g37_push2)"
assert_match "review upload for branch .$g37_branch." "$g37_push2" \
  "the branch is read out from under both the refs/heads/ spelling and the % push options"
red_case 'a Gerrit review upload whose tip carries run state is refused, and told it has no exemption'

# The GREEN twin, and the half that keeps the case above from passing because
# the hook refuses every upload: the SAME magic ref, uploading a branch that
# carries no run state, goes through -- and actually lands.
rc=0
g37_ok="$(git -C "$r37_g" push origin "$g37_branch:refs/for/$g37_branch%topic=clean" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "a clean review upload must push exactly as plain git does (got: $g37_ok)"
grep -q "refs/for/" <<<"$(git -C "$r37_g" ls-remote "$remote37_g" 2>/dev/null || true)" \
  || fail "and it must actually have landed on the remote, not merely not-errored"
green_case 'a review upload carrying no run state is untouched by the leg'

# ===========================================================================
# 5 -- worktrees: create at an explicit path, reuse only an EXACT integration
# checkout, never adopt or overwrite anything else.
# ===========================================================================
r8="$W/r8"; mk_repo "$r8" 'verify=true'
custom_wt="$W/r8-custom"
out8="$(ORCHID_REPO="$r8" "$ORCHID_BIN" start "$REQ" --worktree "$custom_wt" 2>&1)" \
  || fail "--worktree must place the integration worktree where asked: $out8"
assert_match "^integration worktree: $custom_wt \(created\)$" "$out8" "--worktree is honored"
[ -d "$custom_wt/.orchid" ] || fail "--worktree must actually create the worktree there"
[ -e "$W/r8-orchid" ] && fail "--worktree must suppress the default worktree path"

# Pointing a second run at a DIFFERENT path, while the branch is already
# checked out somewhere, is refused with the path that already holds it --
# never moved, never stolen.
rc=0; out8b="$(ORCHID_REPO="$r8" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" --worktree "$W/r8-elsewhere" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse to relocate an existing integration checkout"
assert_match "already checked out at $custom_wt" "$out8b" "the refusal names the existing checkout"
[ -e "$W/r8-elsewhere" ] && fail "a refused relocation must not create the requested path"

# With no --worktree at all, the existing integration checkout is reused
# rather than a second one being created at the default path.
out8c="$(ORCHID_REPO="$r8" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" 2>&1)" \
  || fail "start must reuse the existing integration checkout: $out8c"
assert_match "^integration worktree: $custom_wt \(reused\)$" "$out8c" "the existing checkout is reused"
[ -e "$W/r8-orchid" ] && fail "reuse must not also create the default worktree path"

# A non-empty directory sitting on the target path is somebody else's; it is
# refused, and nothing at all is initialized.
r9="$W/r9"; mk_repo "$r9" 'verify=true'
mkdir -p "$W/r9-orchid"; printf 'mine\n' > "$W/r9-orchid/notes.txt"
rc=0; out9="$(ORCHID_REPO="$r9" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a non-empty directory on the worktree path"
assert_match "never overwrites an existing directory" "$out9" "the refusal states the rule"
assert_eq "mine" "$(cat "$W/r9-orchid/notes.txt")" "the existing directory's contents are untouched"
git -C "$r9" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "a worktree-path refusal must happen before anything is initialized"

# ===========================================================================
# 6 -- unattended trust: off by default, and only ever turned on by BOTH
# explicit flags, through the machine-local trust verb.
# ===========================================================================
assert_match '^unattended trust: untrusted$' \
  "$("$ORCHID_BIN" trust show "$wt1" | sed -n '1p')" \
  "an ordinary orchid start leaves the repository unacknowledged"

r10="$W/r10"; mk_repo "$r10" 'verify=true'
rc=0; out10="$(ORCHID_REPO="$r10" "$ORCHID_BIN" start "$REQ" --ack-unattended 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--ack-unattended without --reason must be refused"
assert_match "requires a non-empty --reason" "$out10" "the refusal names the missing reason"
git -C "$r10" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "an argument refusal must happen before anything is initialized"

rc=0; out10b="$(ORCHID_REPO="$r10" "$ORCHID_BIN" start "$REQ" --reason "just because" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--reason without --ack-unattended must be refused"
assert_match "only meaningful with --ack-unattended" "$out10b" \
  "the refusal explains that trust is never acknowledged implicitly"

out10c="$(ORCHID_REPO="$r10" "$ORCHID_BIN" start "$REQ" \
  --ack-unattended --reason "reviewed this repository for unattended execution" 2>&1)" \
  || fail "both flags together must acknowledge unattended trust: $out10c"
assert_match "^unattended trust: trusted$" "$out10c" "start reports the acknowledged gate"
assert_match '^unattended trust: trusted$' \
  "$("$ORCHID_BIN" trust show "$W/r10-orchid" | sed -n '1p')" \
  "the acknowledgement is a real machine-local trust record"
assert_match "reason: reviewed this repository for unattended execution" \
  "$("$ORCHID_BIN" trust show "$W/r10-orchid")" \
  "the operator's reason is recorded by the trust verb"

# ===========================================================================
# 7 -- out-of-scope and malformed inputs fail before touching anything.
# ===========================================================================
r11="$W/r11"; mkdir -p "$r11"; git -C "$r11" init -q     # unborn HEAD
rc=0; out11="$(ORCHID_REPO="$r11" "$ORCHID_BIN" start "$REQ" --verify true 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a repo with no commits"
assert_match "greenfield" "$out11" "the refusal points at the greenfield path"
git -C "$r11" rev-parse -q --verify HEAD >/dev/null 2>&1 \
  && fail "a refused start must not mint a root commit"

r12="$W/r12"; mk_repo "$r12" 'verify=true'
rc=0; out12="$(ORCHID_REPO="$r12" "$ORCHID_BIN" start "$W/nope.md" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a missing requirements file"
assert_match "no such requirements file" "$out12" "the refusal names the missing file"

: > "$W/empty.md"
rc=0; out12b="$(ORCHID_REPO="$r12" "$ORCHID_BIN" start "$W/empty.md" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse an empty requirements file"
assert_match "never invents requirements" "$out12b" "the refusal says requirements are the operator's"

rc=0; out12c="$(ORCHID_REPO="$r12" "$ORCHID_BIN" start "$REQ" --bogus 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must reject an unknown option"
assert_match "unknown option '--bogus'" "$out12c" "the refusal names the unknown option"

# orchid.config is a LINE-ORIENTED key=value store, so a multi-line --verify
# would be recorded truncated at its first line -- the run verifying with less
# than was asked for, the report printing the whole value as recorded, and
# every later config read dying on the orphan lines. Rejected at
# argument-parsing time, before anything is read, let alone written.
rc=0; out12e="$(ORCHID_REPO="$r12" "$ORCHID_BIN" start "$REQ" --verify 'make lint
make test' 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must reject a multi-line --verify"
assert_match "must be a single line" "$out12e" "the refusal names the rule"
assert_match "pass that instead" "$out12e" "and says what to do instead"

rc=0; out12f="$(ORCHID_REPO="$r12" "$ORCHID_BIN" start "$REQ" --verify "$(printf 'make test\t')" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must reject a control character in --verify"
assert_match "must be a single line" "$out12f" "any control character is refused, not just a newline"

rc=0; out12d="$(ORCHID_REPO="$r12" "$ORCHID_BIN" start "$REQ" "$req2" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must reject two requirements files"
assert_match "exactly one requirements file" "$out12d" "the refusal names the arity"
git -C "$r12" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "argument refusals must happen before anything is initialized"

# A failing preflight stops setup outright, with doctor's own output shown.
r13="$W/r13"; mk_repo "$r13" 'verify=true' 'role.implementer=missing-engine'
rc=0; out13="$(ORCHID_REPO="$r13" "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse to build on a repo whose preflight fails"
assert_match "FAIL: role implementer" "$out13" "the preflight's own findings are shown"
assert_match "preflight failed" "$out13" "the refusal names the preflight"
git -C "$r13" rev-parse --verify -q orchid/integration >/dev/null 2>&1 \
  && fail "a failed preflight must not initialize anything"

# ===========================================================================
# 8 -- help, and the lower-level verbs it is built from, all still work.
# ===========================================================================
help_out="$("$ORCHID_BIN" start --help)" || fail "orchid start --help must exit 0"
assert_match "usage:" "$help_out" "help prints a usage block"
assert_match "never guesses a verification command" "$help_out" "help states the verification rule"
# `[-]` rather than a leading `-`: assert_match passes its pattern to grep
# without a `--` terminator, so a pattern that starts with a dash would be
# read as an option instead.
assert_match "[-]-ack-unattended" "$help_out" "help documents the unattended opt-in"
assert_match "[-]-worktree" "$help_out" "help documents the worktree option"
assert_match "[-]-refresh-push-guard" "$help_out" \
  "help documents the maintenance route, so the upgrade command an operator needs is discoverable from the verb itself"

assert_match "start" "$("$ORCHID_BIN" help)" "the dispatcher lists the new verb"

# The bare-word alias is the FIRST argument only. Matched anywhere in argv it
# also swallows a requirements file that happens to be named `help`, printing
# usage (and exiting 0) instead of the setup that was asked for.
assert_match "usage:" "$("$ORCHID_BIN" start help)" "'help' as the first argument still prints usage"
r24="$W/r24"; mk_repo "$r24" 'verify=true'
cp "$REQ" "$W/help"
out24="$(cd "$W" && ORCHID_REPO="$r24" "$ORCHID_BIN" start --verify true help 2>&1)" \
  || fail "a requirements file named 'help' must be read as a file: $out24"
assert_match "^orchid start: initialized a new run$" "$out24" \
  "a requirements file named 'help' is a file, not a request for usage"
assert_eq "$(cat "$REQ")" "$(cat "$W/r24-orchid/.orchid/requirements.md")" \
  "and it is the file that gets imported"

# The manual path is unchanged: doctor/init/requirements import still work on
# their own, against a repo orchid start never touched.
r14="$W/r14"; mk_repo "$r14" 'verify=true'
ORCHID_REPO="$r14" "$ORCHID_BIN" doctor >/dev/null || fail "orchid doctor still works standalone"
ORCHID_REPO="$r14" "$ORCHID_BIN" init >/dev/null || fail "orchid init still works standalone"
git -C "$r14" worktree add -q "$W/r14-orchid" orchid/integration
ORCHID_REPO="$W/r14-orchid" ORCHID_EPOCH=0 "$ORCHID_BIN" requirements import "$REQ" >/dev/null \
  || fail "orchid requirements import still works standalone"
assert_eq "$(cat "$REQ")" "$(cat "$W/r14-orchid/.orchid/requirements.md")" \
  "the documented manual sequence still produces the same result"

# ===========================================================================
# 9 -- T002 (r-001 follow-up): `orchid start` must stay idempotent on a repo
# whose own history already carries .orchid/tasks/.
#
# r-001's reviewer reported an .orchid/tasks/ idempotence break and the finding
# text was lost to an empty findings[], so this Part was written first as a
# diagnosis derived by READING libexec/orchid-start. The break is real, and the
# source trace that establishes it is:
#
#   * `orchid init` cuts $integ from the operator's own HEAD
#     (libexec/orchid-init:80) and commits a fresh roadmap.md over whatever
#     .orchid/ that HEAD carried -- but it never clears an inherited
#     .orchid/tasks/, because it only `mkdir -p`s that directory
#     (libexec/orchid-init:81) and git tracks no empty one. Those inherited
#     task files ride onto the integration branch.
#   * `orchid start` cleared the committed-tasks witness for mode=new, and was
#     right to: nothing on that branch came from `plan apply`. But the
#     exemption was scoped to the INVOCATION while the state it excuses is
#     durable, so the next identical run read mode=existing and refused --
#     with a premise untrue of the state `orchid start` itself created, and a
#     recovery (`run resume`/`run new`) that does not apply to a run still in
#     planning with no plan on it.
#
# The fix reads the witness against the branch's fork point
# (_start_tasks_inherited), so both runs reach the same verdict from committed
# state. This Part is now the regression guard for it, and the tripwire below
# is the other half: the witness must still fire when a plan really has landed,
# or the fix would have "passed" by disabling it.
#
# The precondition is a repository whose own history carries .orchid/tasks/:
# an orchid-managed repo whose integration branch was merged back into its
# mainline and whose next run gets a new integration branch. That is exactly
# how this repository's own main branch looks, so the fixture below is the
# dogfood shape rather than an invented one.
#
# Part 2 above already pins idempotence for a repo with no inherited .orchid
# state; this Part is the same question asked of the one input shape Part 2
# does not carry.
# ===========================================================================
r25="$W/r25"; mk_repo "$r25"
mkdir -p "$r25/.orchid/tasks"
printf -- '---\nrun_status: complete\nrun_id: r-001\n---\n# Roadmap\n' > "$r25/.orchid/roadmap.md"
printf -- '---\nid: T001\nstatus: merged\n---\n# T001\n' > "$r25/.orchid/tasks/T001.md"
printf '# Journal\n' > "$r25/.orchid/journal.md"
git -C "$r25" add -A
git -C "$r25" commit -q -m "fixture: a finished orchid run, merged back into the mainline"
# roadmap.md is committed alongside tasks/ deliberately: without it the
# operator's own checkout matches orchid_split_brain (lib/common.sh) and the
# preflight would fail this fixture for that instead, never reaching the
# witness under test.

rc=0
out25a="$(ORCHID_REPO="$r25" "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "the FIRST orchid start refused a repo whose own history carries .orchid/tasks/ (exit $rc) — setup must accept that shape before idempotence on it means anything, so read this before the assertions below: $out25a"
else
  assert_match "^orchid start: initialized a new run$" "$out25a" \
    "setup succeeds on a repo whose own history already carries .orchid/tasks/"
  # The premise of the whole Part: those inherited task files are now
  # COMMITTED on the integration branch, put there by `orchid init` branching
  # from the operator's HEAD -- never by `orchid plan apply`.
  assert_eq ".orchid/tasks/T001.md" \
    "$(git -C "$r25" ls-tree --name-only refs/heads/orchid/integration -- .orchid/tasks/)" \
    "the inherited task file rides onto the integration branch that setup just created"

  rc=0
  out25b="$(ORCHID_REPO="$r25" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # One report, not three: `fail` accumulates rather than exits (helpers.sh),
    # so the two assertions below would otherwise pile two derived failures on
    # top of the one that actually explains them.
    printf '%s\n' "$out25b" | sed 's/^/    | /'
    fail "the second identical 'orchid start' exited $rc where the first exited 0 — setup refuses the state it created one run earlier (output above). orchid start must be idempotent, or fail with a recovery that applies; this fails with a recovery for a run in flight."
  else
    assert_match "^orchid start: reused existing run state$" "$out25b" \
      "a second identical run reuses the state the first one built"
    assert_match "^requirements: unchanged \(already imported verbatim\)$" "$out25b" \
      "and re-imports nothing"
  fi
fi

# The tripwire, and the reason the Part above is not satisfied by simply
# deleting the witness: .orchid/tasks/ content that a plan really DID put on
# the branch must still be refused. The fixture is the same inherited-tasks
# shape, so the only difference between refusing and reusing is the provenance
# of the task files -- which is exactly what _start_tasks_inherited judges.
r26="$W/r26"; mk_repo "$r26"
mkdir -p "$r26/.orchid/tasks"
printf -- '---\nrun_status: complete\nrun_id: r-001\n---\n# Roadmap\n' > "$r26/.orchid/roadmap.md"
printf -- '---\nid: T001\nstatus: merged\n---\n# T001\n' > "$r26/.orchid/tasks/T001.md"
printf '# Journal\n' > "$r26/.orchid/journal.md"
git -C "$r26" add -A
git -C "$r26" commit -q -m "fixture: a finished orchid run, merged back into the mainline"

# --worktree so the integration checkout is at a path this test knows, rather
# than one it would have to parse back out of the output.
r26wt="$W/r26wt"
ORCHID_REPO="$r26" "$ORCHID_BIN" start "$REQ" --verify 'true' --worktree "$r26wt" >/dev/null 2>&1 \
  || fail "setup failed on the tripwire fixture"

# A plan lands: committed .orchid/tasks/ content on $integ that the branch did
# NOT inherit. The roadmap is left reading `planning` on purpose -- that is
# precisely the case the tasks witness exists for, the one the two roadmap
# witnesses cannot see.
#
# The edit is to the BODY of the file already there, leaving its frontmatter
# (and so the set of task ids, and every id/status the preflight reads) exactly
# as it was one successful `orchid start` ago. Two reasons: this refusal is
# then attributable to provenance alone rather than to some other check
# noticing a new id, and it pins the blob-sha comparison specifically -- a
# witness that compared only PATHS would sail past this.
printf -- '---\nid: T001\nstatus: merged\n---\n# T001\n\nplanned onto the branch\n' \
  > "$r26wt/.orchid/tasks/T001.md"
# Pathspec-limited, so this commits the one file it means to even if setup left
# anything else staged in that checkout -- the subject of this tripwire is the
# task file's provenance, and nothing else should ride along and muddy it.
git -C "$r26wt" commit -q -m "orchid: plan apply" -- .orchid/tasks/T001.md

rc=0
out26="$(ORCHID_REPO="$r26" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  fail "orchid start accepted a branch carrying a task file that a plan put there — the inherited-tasks exemption must not disable the witness: $out26"
else
  assert_match "already carries committed .orchid/tasks/" "$out26" \
    "and refuses on the tasks witness, naming it"
fi

# ===========================================================================
# 10 -- the second half of that tripwire: the inherited-tasks exemption must
# decline on COMMIT identity, not on branch names.
#
# _start_tasks_inherited answers by comparing $integ's committed .orchid/tasks/
# against the same path at the branch's fork point, and it must refuse to
# answer whenever that fork point IS the branch tip -- the comparison is
# vacuously true there, so an unguarded reading would not inform the witness
# but silently disable it.
#
# HEAD sitting on $integ is the obvious way to land in that state and a name
# check catches it. This Part is the way that a name check does NOT catch: an
# operator who fast-forwards their own branch onto $integ mid-run. The names
# still differ, the commits no longer do, and every task file `plan apply` put
# on the branch is now also on the merge base. That is precisely the state the
# witness exists for -- a plan on the branch, candidates whose base_sha this
# verb's durable commit could move -- so it must still refuse.
#
# Part 9's tripwire above cannot see this: it leaves the operator's branch at
# the fork point, where names and commits agree about which is which.
# ===========================================================================
r27="$W/r27"; mk_repo "$r27"
mkdir -p "$r27/.orchid/tasks"
printf -- '---\nrun_status: complete\nrun_id: r-001\n---\n# Roadmap\n' > "$r27/.orchid/roadmap.md"
printf -- '---\nid: T001\nstatus: merged\n---\n# T001\n' > "$r27/.orchid/tasks/T001.md"
printf '# Journal\n' > "$r27/.orchid/journal.md"
git -C "$r27" add -A
git -C "$r27" commit -q -m "fixture: a finished orchid run, merged back into the mainline"

r27wt="$W/r27wt"
ORCHID_REPO="$r27" "$ORCHID_BIN" start "$REQ" --verify 'true' --worktree "$r27wt" >/dev/null 2>&1 \
  || fail "setup failed on the commit-identity fixture"

# A plan lands, exactly as in Part 9's tripwire.
printf -- '---\nid: T001\nstatus: merged\n---\n# T001\n\nplanned onto the branch\n' \
  > "$r27wt/.orchid/tasks/T001.md"
git -C "$r27wt" commit -q -m "orchid: plan apply" -- .orchid/tasks/T001.md

# ...and THEN the operator moves their own branch onto $integ. `reset --hard`
# rather than `merge --ff-only` on purpose: it reaches the same commit without
# depending on the operator checkout being clean, or on setup having added no
# path that a merge would refuse to overwrite. Either way the branch names stay
# distinct while the commits become identical, which is the whole subject here.
r27_branch="$(git -C "$r27" rev-parse --abbrev-ref HEAD)"
[ "$r27_branch" != "orchid/integration" ] \
  || fail "fixture: the operator checkout must be on its own branch, not \$integ — this Part is about two NAMES over one commit"
git -C "$r27" reset -q --hard refs/heads/orchid/integration \
  || fail "fixture: could not fast-forward the operator's branch onto the integration branch"
assert_eq "$(git -C "$r27" rev-parse refs/heads/orchid/integration)" \
  "$(git -C "$r27" rev-parse HEAD)" \
  "fixture: the operator's branch and the integration branch now name one commit"

rc=0
out27="$(ORCHID_REPO="$r27" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$REQ" --verify 'true' 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  fail "orchid start accepted a branch with a plan on it because the operator's own branch had been moved onto that branch — the fork point was the branch tip, so the inherited-tasks comparison was vacuous and must have declined to answer rather than passed: $out27"
else
  assert_match "already carries committed .orchid/tasks/" "$out27" \
    "and still refuses on the tasks witness when the fork point is the branch tip under another name"
fi
