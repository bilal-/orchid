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
W="$(cd "$WORK" && pwd -P)"
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
assert_match '^verify=make test$' "$(cat "$W/r16-orchid/orchid.config")" \
  "the integration checkout's own config is left exactly as it was"
assert_match '^verify=make test$' "$(git -C "$r16" show orchid/integration:orchid.config)" \
  "and nothing was committed over it"

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
