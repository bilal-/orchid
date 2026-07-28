#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

# Mutating a "built-in" adapter to prove drift detection must never touch
# the real checkout -- bin/orchid always resolves ORCHID_ROOT relative to
# ITSELF (readlink-following its own path), ignoring any inherited
# ORCHID_ROOT env var, so the only safe way to exercise "mutate a built-in"
# is a throwaway copy of the whole kernel tree, driven via ITS OWN
# bin/orchid. plugins/ is tiny (a few KB), so a full copy per test run is
# cheap.
root="$WORK/root"; mkdir -p "$root"
for d in bin lib libexec plugins roles; do cp -R "$REPO_ROOT/$d" "$root/$d"; done
bin="$root/bin/orchid"

repoA="$WORK/repoA"; mkdir -p "$repoA"
(cd "$repoA" && git init -q . && git commit -q --allow-empty -m root)
homeA="$WORK/homeA"; mkdir -p "$homeA/.orchid"

run() { HOME="$homeA" ORCHID_REPO="$repoA" "$bin" "$@"; }

# -- lock produces one record per plugin bound by a default role, deduped --
out="$(run plugins lock)"; rc=$?
assert_eq 0 "$rc" "plugins lock exits 0 with only default bindings"
assert_match "^locked: " "$out" "prints a locked: confirmation line"
lockfile="$repoA/.orchid/plugins.lock"
[ -f "$lockfile" ] || fail "plugins lock must write $lockfile"

n="$(jq 'length' "$lockfile")"
assert_eq 3 "$n" "3 unique plugins bound by the 5 default roles (claude, codex, agy), deduped"

claude_digest=""
for id in orchid/claude orchid/codex orchid/agy; do
  rec="$(jq -c --arg id "$id" '.[] | select(.id==$id)' "$lockfile")"
  [ -n "$rec" ] || fail "lock missing record for $id"
  ver="$(echo "$rec" | jq -r .version)"; assert_eq "0.1.0" "$ver" "$id: version recorded"
  av="$(echo "$rec" | jq -r .api_version)"; assert_eq "1" "$av" "$id: api_version recorded"
  origin="$(echo "$rec" | jq -r .source_origin)"; assert_eq "builtin" "$origin" "$id: source_origin=builtin"
  digest="$(echo "$rec" | jq -r .digest)"; [ -n "$digest" ] || fail "$id: digest must be non-empty"
  passed="$(echo "$rec" | jq -r .capsuite_passed)"; assert_eq "false" "$passed" "$id: capsuite_passed=false (never tested)"
  [ "$id" != orchid/claude ] || claude_digest="$digest"
done

# -- digest matches plugins trust's algorithm (lib/common.sh's plugin_digest) --
expect_digest="$(HOME="$homeA" ORCHID_REPO="$repoA" ORCHID_ROOT="$root" bash -c \
  'source "$ORCHID_ROOT/lib/common.sh"; plugin_digest "$1"' _ "$root/plugins/engines/claude")"
assert_eq "$expect_digest" "$claude_digest" "lock's digest for orchid/claude matches plugin_digest directly (same algorithm 'plugins trust' uses)"

# -- verify-lock is clean immediately after lock -----------------------------
out="$(run plugins verify-lock)"; rc=$?
assert_eq 0 "$rc" "verify-lock exits 0 with no drift"
assert_match "clean" "$out" "verify-lock reports clean"

# -- verify-lock refuses to run with no lock file on record ------------------
repoNoLock="$WORK/repoNoLock"; mkdir -p "$repoNoLock"
(cd "$repoNoLock" && git init -q . && git commit -q --allow-empty -m root)
homeNoLock="$WORK/homeNoLock"; mkdir -p "$homeNoLock/.orchid"
rc=0; out="$(HOME="$homeNoLock" ORCHID_REPO="$repoNoLock" "$bin" plugins verify-lock 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "verify-lock must refuse to run when no plugins.lock exists"
assert_match "no plugins.lock" "$out" "verify-lock names the missing lock file"

# -- mutating a built-in adapter -> verify-lock reports drift (RED scenario) -
printf '\n# mutated for drift test\n' >> "$root/plugins/engines/claude/run"
rc=0; out="$(run plugins verify-lock)" || rc=$?
[ "$rc" -ne 0 ] || fail "verify-lock must exit nonzero after a built-in adapter's bytes change"
assert_match "CHANGED: orchid/claude" "$out" "drift report labels orchid/claude as CHANGED"

# -- doctor: drift is a WARNING, not a FAIL, in v1-m1 ------------------------
printf 'verify=true\n' > "$repoA/orchid.config"
docout="$(run doctor 2>&1)"; rc=$?
assert_eq 0 "$rc" "doctor still passes cleanly (lock drift is a warning, not a fail, in v1-m1)"
assert_match "WARN.*drift" "$docout" "doctor surfaces the drift as a WARNing"
assert_match "orchid/claude" "$docout" "doctor's warning names the drifted plugin"

# -- restoring the file's bytes -> clean again -------------------------------
cp "$REPO_ROOT/plugins/engines/claude/run" "$root/plugins/engines/claude/run"
out="$(run plugins verify-lock)"; rc=$?
assert_eq 0 "$rc" "verify-lock is clean again once the adapter's bytes are restored"
assert_match "clean" "$out" "verify-lock reports clean after restoring the file"

# -- a locked plugin that's no longer resolvable at all -> MISSING ----------
rm -rf "$root/plugins/engines/agy"
rc=0; out="$(run plugins verify-lock)" || rc=$?
[ "$rc" -ne 0 ] || fail "verify-lock must exit nonzero when a locked plugin is no longer resolvable via its bound role"
assert_match "MISSING: orchid/agy" "$out" "drift report labels orchid/agy as MISSING"

# -- a fresh, unmutated kernel copy for the remaining scenarios (the "root"
# copy above has permanently lost plugins/engines/agy and had claude's run
# script mutated-then-restored -- a second pristine copy keeps those
# scenarios from depending on either) ---------------------------------------
root2="$WORK/root2"; mkdir -p "$root2"
for d in bin lib libexec plugins roles; do cp -R "$REPO_ROOT/$d" "$root2/$d"; done
bin2="$root2/bin/orchid"

# -- doctor is unaffected when no plugins.lock exists at all -----------------
repoB="$WORK/repoB"; mkdir -p "$repoB"
(cd "$repoB" && git init -q . && git commit -q --allow-empty -m root)
printf 'verify=true\n' > "$repoB/orchid.config"
homeB="$WORK/homeB"; mkdir -p "$homeB/.orchid"
out="$(HOME="$homeB" ORCHID_REPO="$repoB" "$bin2" doctor)"; rc=$?
assert_eq 0 "$rc" "doctor passes when no plugins.lock exists at all"
( echo "$out" | grep -q "plugin lock" ) && fail "doctor must not mention plugin lock when no lock file exists"

# -- orchid-init writes an initial plugins.lock, committed on the
# integration branch, recording the default builtin bindings (not just
# overrides -- so drift on a stock built-in is catchable from run one) ------
repoInit="$WORK/repoInit"; mkdir -p "$repoInit"
(cd "$repoInit" && git init -q . && git commit -q --allow-empty -m root)
printf 'verify=true\n' > "$repoInit/orchid.config"
(cd "$repoInit" && git add -A && git commit -q -m "fixture: config")
homeInit="$WORK/homeInit"; mkdir -p "$homeInit/.orchid"
HOME="$homeInit" ORCHID_REPO="$repoInit" "$bin2" init >/dev/null

lockOnBranch="$(git -C "$repoInit" show orchid/integration:.orchid/plugins.lock 2>/dev/null)" \
  || fail "plugins.lock must be committed on the integration branch by orchid-init"
n="$(echo "$lockOnBranch" | jq 'length')"
[ "$n" -ge 3 ] || fail "init's plugins.lock should record at least the 3 default builtin bindings (claude/codex/agy), got $n"
for id in orchid/claude orchid/codex orchid/agy; do
  echo "$lockOnBranch" | jq -e --arg id "$id" '.[] | select(.id==$id)' >/dev/null \
    || fail "init's plugins.lock is missing the default builtin binding $id"
done
