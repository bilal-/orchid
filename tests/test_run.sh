#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
cd "$WORK"; git init -q .; git commit -q --allow-empty -m root
mkdir -p .orchid; export ORCHID_REPO="$WORK" HOME="$WORK/home"; mkdir -p "$HOME"
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
