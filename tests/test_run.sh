#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
# Fixture correction (Plan-A backlog step 2): `run start` now refuses an
# uninitialized repo (neither .orchid/tasks/ nor .orchid/roadmap.md present).
# This fixture predates that guard and only created the bare .orchid/ dir —
# widen it to .orchid/tasks so the happy-path `run start` below still passes.
mkdir -p .orchid/tasks; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
e1="$("$ORCHID_BIN" run start | sed 's/epoch: //')"
e2="$("$ORCHID_BIN" run resume | sed 's/epoch: //')"
[ "$e2" -gt "$e1" ] || fail "resume increments epoch ($e1 -> $e2)"
[ -f .orchid/runtime/lease.json ] || fail "lease written"

# lock must not leak when a middle step fails (regression)
mkdir -p "$WORK/stub"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/stub/jq"; chmod +x "$WORK/stub/jq"
rc=0; PATH="$WORK/stub:$PATH" "$ORCHID_BIN" run start >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run start should fail with broken jq"
[ ! -d .orchid/runtime/lock ] || fail "lock leaked after failed run start"
"$ORCHID_BIN" run start >/dev/null || fail "run start works again after failed attempt"

# failed acquire must NOT remove a lock held by another process
"$ORCHID_BIN" run start >/dev/null   # we do not hold the lock now (trap released it), so take it manually:
source "$REPO_ROOT/lib/common.sh"; lock_acquire "$WORK" >/dev/null || fail "manual acquire for fixture"
rc=0; PATH="$WORK/stub:$PATH" "$ORCHID_BIN" run start >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "acquire against held lock should fail"
[ -d .orchid/runtime/lock ] || fail "holder's lock must survive a failed acquire"
lock_release "$WORK"

# run start refuses an uninitialized repo (no .orchid/tasks and no roadmap.md)
scratch="$WORK/scratch-uninit"; mkdir -p "$scratch"
(cd "$scratch" && git init -q . && git commit -q --allow-empty -m root)
rc=0; ORCHID_REPO="$scratch" HOME="$WORK/home" "$ORCHID_BIN" run start >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run start must refuse an uninitialized repo"

# v0b2: `run resume` requires initialized state too (same guard as start) —
# resume recovers an existing run after a crash/restart, it does not
# bootstrap one; letting it proceed against an uninitialized repo would mint
# an epoch/lease for state that was never created.
rc=0; ORCHID_REPO="$scratch" HOME="$WORK/home" "$ORCHID_BIN" run resume >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "run resume must refuse an uninitialized repo"
