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
W="$(cd_scratch "$WORK" && pwd -P)"
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
assert_match "^  export ORCHID_EPOCH=0$" "$out1" "the handoff names the epoch to export"
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
