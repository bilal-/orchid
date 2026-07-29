#!/usr/bin/env bash

# The kernel version. `orchid version` (libexec/orchid-version) prints it
# verbatim; `manifest_validate` (lib/manifest.sh) compares a plugin's
# `requires_orchid=>=X.Y` against it (major.minor only -- semver-ish, per
# docs/specs/plugins.md's Manifest section). Bump alongside a milestone,
# never mid-milestone.
ORCHID_VERSION="1.0.0-m2"

orchid_die() { echo "orchid: $*" >&2; exit 1; }
atomic_write() { local d="$1" t; t="$(mktemp "${d}.tmp.XXXXXX")"; cat >"$t"; mv "$t" "$d"; }
orchid_state()   { echo "$1/.orchid"; }
orchid_runtime() { local r="$1/.orchid/runtime"; mkdir -p "$r"; echo "$r"; }

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

_cfg_env_name() { echo "ORCHID_$(echo "$1" | tr 'a-z.' 'A-Z_')"; }
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
lock_acquire() {
  local repo="$1" rt lock brk
  rt="$(orchid_runtime "$repo")"; lock="$rt/lock"
  brk="${ORCHID_LOCK_BREAK_S:-$(config_get "$repo" lock_break_s 900)}"
  if ! mkdir "$lock" 2>/dev/null; then
    local pid host pstart age now mt
    pid="$(jq -r .pid "$lock/owner.json" 2>/dev/null || echo 0)"
    host="$(jq -r .hostname "$lock/owner.json" 2>/dev/null || echo '?')"
    pstart="$(jq -r .pid_start "$lock/owner.json" 2>/dev/null || echo '?')"
    now="$(date +%s)"; mt="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock")"
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
      pid=0; host='?'; pstart='?'
      eval "$(printf '%s' "$owner_json" | jq -r \
        '"pid=" + (.pid|tostring) + "; host=" + (.hostname|@sh) + "; pstart=" + (.pid_start|@sh)' \
        2>/dev/null)"
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
