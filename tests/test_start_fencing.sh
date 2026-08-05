#!/usr/bin/env bash
# v1.1 Track 2: `orchid start` against EXISTING run state. Setup convenience
# must never become a way to take a run over, so this file proves the four
# refusals that keep it honest -- a live lease, a live run/verb lock, an
# unproven or stale epoch (INV-02), and a run that has already left planning
# -- plus the one success path (the caller proving ownership of the CURRENT
# epoch), and that none of the refusals mutates a thing.
#
# RED (before libexec/orchid-start exists): the first `orchid start` below
# exits 2 with "unknown command 'start'".
source "$(dirname "$0")/helpers.sh"

W="$(cd "$WORK" && pwd -P)"
export HOME="$MACHINE_HOME"; mkdir -p "$HOME/.orchid"
export ORCHID_ENGINES_DIR="$W/eng"
mkdir -p "$W/eng/fake"
printf '#!/usr/bin/env bash\n' > "$W/eng/fake/run"
chmod +x "$W/eng/fake/run"

REQ="$W/requirements.md"
printf '# Requirements\n\nShip the thing.\n' > "$REQ"
# A DIFFERENT file for every refusal attempt: if a refused `orchid start`
# ever imported anything, the snapshot below would stop matching $REQ.
INTRUDER="$W/intruder.md"
printf '# Requirements\n\nSomething else entirely.\n' > "$INTRUDER"

repo="$W/proj"
mkdir -p "$repo"
git -C "$repo" init -q
printf 'verify=true\nrole.orchestrator=fake\nrole.implementer=fake\nrole.reviewer=fake\nrole.arbiter=fake\nrole.plan_critic=fake\n' \
  > "$repo/orchid.config"
git -C "$repo" add -A
git -C "$repo" commit -q -m "fixture: project + orchid.config"

wt="$W/proj-orchid"
ORCHID_REPO="$repo" "$ORCHID_BIN" start "$REQ" >/dev/null \
  || fail "fixture: the initial orchid start must succeed"
[ -d "$wt/.orchid" ] || fail "fixture: the integration worktree must exist"
assert_eq "0" "$(cat "$wt/.orchid/runtime/epoch")" "fixture: a fresh setup is fenced at epoch 0"

snapshot_unchanged() {  # <label>
  assert_eq "$(cat "$REQ")" "$(cat "$wt/.orchid/requirements.md")" \
    "a refused orchid start ($1) must not import anything"
}

# ---------------------------------------------------------------------------
# A live session's lease: `orchid run start` mints epoch 1 AND a fresh,
# unreleased lease. That lease is the signal another session is driving this
# run; setup never takes it over.
# ---------------------------------------------------------------------------
e1="$(ORCHID_REPO="$wt" "$ORCHID_BIN" run start | sed 's/epoch: //')"
assert_eq "1" "$e1" "fixture: run start mints the next epoch"

rc=0
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH="$e1" "$ORCHID_BIN" start "$INTRUDER" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse while another session's lease is fresh"
assert_match "lease refreshed" "$out" "the refusal names the live lease"
assert_match "never takes a run over" "$out" "the refusal states the rule"
snapshot_unchanged "live lease"
assert_eq "1" "$(cat "$wt/.orchid/runtime/epoch")" "a refused start must not touch the epoch"

# A cleanly-exited session (PROTOCOL.md's COMPLETION ends with this) reads as
# gone immediately, regardless of how recently the lease was refreshed.
ORCHID_REPO="$wt" ORCHID_EPOCH="$e1" "$ORCHID_BIN" run release-lease >/dev/null \
  || fail "fixture: run release-lease must succeed"

# ---------------------------------------------------------------------------
# Epoch ownership (INV-02): with an epoch already materialized, the caller
# must prove it holds the CURRENT one. orchid start never mints a fresh epoch
# over an existing one, and never accepts a stale one.
# ---------------------------------------------------------------------------
rc=0
out="$(ORCHID_REPO="$repo" "$ORCHID_BIN" start "$INTRUDER" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse when ORCHID_EPOCH is unset and the run is already fenced"
assert_match "already fenced at epoch 1" "$out" "the refusal names the current epoch"
assert_match "export ORCHID_EPOCH=1" "$out" "the refusal prints the exact recovery command"
snapshot_unchanged "unset epoch"
assert_eq "1" "$(cat "$wt/.orchid/runtime/epoch")" "an unproven start must not reset the epoch"

rc=0
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=0 "$ORCHID_BIN" start "$INTRUDER" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a stale epoch"
assert_match "stale epoch '0' \(current 1\)" "$out" "the refusal quotes both epochs"
assert_match "INV-02" "$out" "the refusal names the invariant it enforces"
snapshot_unchanged "stale epoch"
assert_eq "1" "$(cat "$wt/.orchid/runtime/epoch")" "a stale-epoch refusal must not reset the epoch"

# ---------------------------------------------------------------------------
# A live run lock or verb lock means some other verb is mid-transaction.
# Both lock directories are fabricated here against THIS test process, which
# is genuinely alive, so the liveness check has a real pid/host/start-time
# triple to agree with -- the same triple lib/common.sh's lock_acquire and
# verb_lock_acquire record. Writing runtime/ directly is safe (and only)
# because it is machine-local, ephemeral state in a disposable fixture.
# ---------------------------------------------------------------------------
mk_live_lock() {  # <lock-dir>
  mkdir -p "$1"
  jq -n --arg p "$$" --arg s "$(ps -o lstart= -p $$ | tr -d ' ')" --arg h "$(hostname)" \
    '{pid:($p|tonumber), pid_start:$s, hostname:$h}' > "$1/owner.json"
}

mk_live_lock "$wt/.orchid/runtime/lock"
rc=0
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=1 "$ORCHID_BIN" start "$INTRUDER" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse while the run lock is held by a live process"
assert_match "run lock is held by a live process" "$out" "the refusal names the run lock"
snapshot_unchanged "live run lock"
rm -rf "$wt/.orchid/runtime/lock"

mk_live_lock "$wt/.orchid/runtime/verb-lock"
rc=0
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=1 "$ORCHID_BIN" start "$INTRUDER" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse while the verb lock is held by a live process"
assert_match "verb lock is held by a live process" "$out" "the refusal names the verb lock"
snapshot_unchanged "live verb lock"
rm -rf "$wt/.orchid/runtime/verb-lock"

# ---------------------------------------------------------------------------
# Ownership proven, nothing else in the way: the existing epoch is READ, not
# reset, and the import runs fenced under it.
# ---------------------------------------------------------------------------
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=1 "$ORCHID_BIN" start "$INTRUDER" 2>&1)" \
  || fail "start must proceed once the caller proves it owns the current epoch: $out"
assert_match "^epoch: 1 \(reused\)$" "$out" "the existing epoch is reused, never re-minted"
assert_match "^requirements: imported from $INTRUDER$" "$out" \
  "the import runs under the validated epoch"
assert_eq "1" "$(cat "$wt/.orchid/runtime/epoch")" "a successful start still never resets the epoch"
assert_eq "$(cat "$INTRUDER")" "$(cat "$wt/.orchid/requirements.md")" \
  "the requirements snapshot is the file that was actually imported"
assert_match "^  export ORCHID_EPOCH=1$" "$out" "the handoff names the epoch that is actually current"

# ---------------------------------------------------------------------------
# A lock DIRECTORY carrying no owner.json at all -- a crash in the few
# milliseconds between the winner's mkdir and its owner-record write. Inside
# the grace window it reads live (never race a claim that is still landing);
# past it, it must NOT read live forever, or a single crash would brick
# `orchid start` permanently, blaming a pid that never existed. Both acquirers
# in lib/common.sh break exactly this shape on exactly this floor.
# ---------------------------------------------------------------------------
vlock="$wt/.orchid/runtime/verb-lock"
mkdir -p "$vlock"
rc=0
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=1 "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a lock claimed moments ago, owner record not written yet, must still be refused"
assert_match "verb lock" "$out" "the refusal names the verb lock"
assert_match "no owner record yet" "$out" "the refusal describes the shape it actually found"
assert_match "remove it" "$out" "the refusal names a recovery that does not depend on a pid"
assert_eq "$(cat "$INTRUDER")" "$(cat "$wt/.orchid/requirements.md")" \
  "a refused orchid start (owner-less verb lock) must not import anything"

# Older than that grace window: an abandoned claim, not a race.
touch -t 200001010000 "$vlock"
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=1 "$ORCHID_BIN" start "$INTRUDER" 2>&1)" \
  || fail "an owner-less lock older than the grace window must not brick setup forever: $out"
assert_match "^epoch: 1 \(reused\)$" "$out" "setup proceeds under the epoch the caller proved it owns"
rm -rf "$vlock"

# ---------------------------------------------------------------------------
# Once the run leaves planning, setup is over: requirements are immutable and
# orchid start is not a resume.
# ---------------------------------------------------------------------------
ORCHID_REPO="$wt" ORCHID_EPOCH=1 "$ORCHID_BIN" run advance running --reason "fencing fixture" >/dev/null \
  || fail "fixture: run advance planning -> running must succeed"
rc=0
out="$(ORCHID_REPO="$repo" ORCHID_EPOCH=1 "$ORCHID_BIN" start "$REQ" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start must refuse a run that has already left planning"
assert_match "already left planning \(run_status: running\)" "$out" "the refusal names the run_status"
assert_match "orchid run resume" "$out" "the refusal points at the resume path instead"
assert_eq "$(cat "$INTRUDER")" "$(cat "$wt/.orchid/requirements.md")" \
  "requirements stay immutable once the run has left planning"
