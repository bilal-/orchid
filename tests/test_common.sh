#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/common.sh"
export HOME="$WORK/home"; mkdir -p "$HOME/.orchid"

echo hi | atomic_write "$WORK/f"; assert_eq hi "$(cat "$WORK/f")" "atomic write"

# v1-m3 Task 12: the running kernel's version constant, checked directly
# against lib/common.sh (tests/test_dispatcher.sh covers the same fact
# through the CLI's `orchid version` verb; this is the library-level source
# of truth both that verb and every manifest's `requires_orchid` check read).
# T008: the shipped version is the semver prerelease 1.0.0-beta.1. A bare
# 1.0.0 is what an external beta earns; nothing outside this repository has
# run orchid yet. Asserted exactly, so a silent re-bump to 1.0.0 fails here.
assert_eq "1.0.0-beta.1" "$ORCHID_VERSION" "ORCHID_VERSION is 1.0.0-beta.1"

# layered config
mkdir -p "$WORK/repo"; cd_scratch "$WORK/repo" || exit 1; git init -q .
printf 'role.implementer=codex\n' > "$HOME/.orchid/config"
assert_eq codex "$(config_get "$WORK/repo" role.implementer)" "user layer"
printf 'role.implementer=claude\n' > "$WORK/repo/orchid.config"
assert_eq claude "$(config_get "$WORK/repo" role.implementer)" "repo overrides user"
ORCHID_ROLE_IMPLEMENTER=agy \
  assert_eq agy "$(ORCHID_ROLE_IMPLEMENTER=agy config_get "$WORK/repo" role.implementer)" "env overrides repo"
assert_eq repo "$(config_provenance "$WORK/repo" role.implementer)" "provenance"

# v1-m4: hyphenated keys (a custom role id, e.g. role.code-reviewer) must get
# a working env override too -- `_cfg_env_name` used to only map `.` to `_`,
# never `-`, so a hyphenated key's "env name" carried a raw hyphen through
# (an invalid bash identifier -- config_get's own `eval "v=\${$env:-}"` would
# throw a bad-substitution error if that value were ever actually consulted).
assert_eq "ORCHID_ROLE_CODE_REVIEWER" "$(_cfg_env_name role.code-reviewer)" \
  "_cfg_env_name maps both '.' and '-' to '_'"
printf 'role.code-reviewer=agy\n' > "$WORK/repo/orchid.config"
assert_eq agy "$(config_get "$WORK/repo" role.code-reviewer)" "hyphenated key resolves from repo config"
assert_eq codex "$(ORCHID_ROLE_CODE_REVIEWER=codex config_get "$WORK/repo" role.code-reviewer)" \
  "hyphenated key's env override wins over repo config"
printf 'evil=$(touch %s/pwned)\n' "$WORK" >> "$WORK/repo/orchid.config"
config_get "$WORK/repo" evil >/dev/null; [ ! -e "$WORK/pwned" ] || fail "never sourced"

# key must be ERE-escaped before grep: dotted key `a.b` must not match `axb=1`
# (unescaped `.` in an ERE matches any char)
printf 'axb=1\n' > "$WORK/repo/orchid.config.dots"
[ -z "$(_cfg_file_get "$WORK/repo/orchid.config.dots" a.b)" ] || fail "unescaped '.' in key a.b must not match axb=1"
printf 'a.b=2\n' >> "$WORK/repo/orchid.config.dots"
assert_eq 2 "$(_cfg_file_get "$WORK/repo/orchid.config.dots" a.b)" "escaped key a.b still matches literal a.b=2"

# lock: acquire, contend, identity-guarded break
mkdir -p "$WORK/repo/.orchid"
lock_acquire "$WORK/repo" || fail "first acquire"
if lock_acquire "$WORK/repo" 2>/dev/null; then fail "second acquire must fail (live owner)"; fi
lock_release "$WORK/repo"
# dead-owner break: fake owner.json with dead pid and old mtime
lock_acquire "$WORK/repo"; rt="$WORK/repo/.orchid/runtime"
jq -n '{pid: 999999, pid_start: "x", epoch: 1, hostname: "'"$(hostname)"'"}' > "$rt/lock/owner.json"
touch -t 202001010000 "$rt/lock" "$rt/lock/owner.json"
out="$(ORCHID_LOCK_BREAK_S=1 lock_acquire "$WORK/repo")" || fail "break stale dead lock"
assert_match "lock-broken" "$out" "break reported"
lock_release "$WORK/repo"
# live-owner break attempt must fail: age alone is not enough. Craft
# owner.json around a genuinely live process (real pid, real pid_start via
# the same `ps -o lstart=` recipe lib/common.sh uses, current hostname),
# backdate the lock dir AND owner.json mtime far beyond lock_break_s, then
# confirm ORCHID_LOCK_BREAK_S=1 still refuses to break it: liveness must
# win over age, or a live owner's lock could be stolen out from under it.
lock_acquire "$WORK/repo"
sleep 60 & live_pid=$!
live_pstart="$(ps -o lstart= -p "$live_pid" 2>/dev/null | tr -d ' ')"
jq -n --arg p "$live_pid" --arg s "$live_pstart" --arg h "$(hostname)" \
  '{pid: ($p|tonumber), pid_start: $s, epoch: 1, hostname: $h}' > "$rt/lock/owner.json"
touch -t 202001010000 "$rt/lock" "$rt/lock/owner.json"
if out="$(ORCHID_LOCK_BREAK_S=1 lock_acquire "$WORK/repo" 2>&1)"; then
  fail "live owner's lock must not break on stale age alone (got: $out)"
fi
[ -d "$rt/lock" ] || fail "live owner's lock dir must survive a failed break attempt"
kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
lock_release "$WORK/repo"

# epochs
echo 3 > "$rt/epoch"
assert_eq 3 "$(epoch_current "$WORK/repo")" "epoch read"
( export ORCHID_EPOCH=2; if ( epoch_require "$WORK/repo" ) 2>/dev/null; then exit 1; fi ) || fail "stale epoch refused"
( export ORCHID_EPOCH=3; epoch_require "$WORK/repo" ) || fail "current epoch accepted"

# -- plugin_digest covers symlinks (Fix 1: a symlinked entrypoint must not be
# swappable without changing the digest) -----------------------------------
mkdir -p "$WORK/plugin" "$WORK/link-target-a" "$WORK/link-target-b"
echo body > "$WORK/plugin/file"
ln -s "$WORK/link-target-a" "$WORK/plugin/link"
d1="$(plugin_digest "$WORK/plugin")"
# repointing the symlink -- no regular file touched at all -- must still
# change the digest; a `find -type f` digest would miss this entirely.
rm "$WORK/plugin/link"; ln -s "$WORK/link-target-b" "$WORK/plugin/link"
d2="$(plugin_digest "$WORK/plugin")"
[ -n "$d1" ] && [ -n "$d2" ] || fail "plugin_digest must produce a nonempty digest"
[ "$d1" != "$d2" ] || fail "plugin_digest must change when a symlink inside the dir is repointed"

# -- trust store record format: `<digest> <path>`, so paths with spaces
# resolve correctly (Fix 2) --------------------------------------------------
spaced="$WORK/plugin dir with spaces"
mkdir -p "$spaced"
trust_store_set "$spaced" "deadbeef"
assert_eq "deadbeef $spaced" "$(cat "$HOME/.orchid/trust")" "trust record is '<digest> <path>' (digest first field)"
assert_eq deadbeef "$(trust_lookup "$spaced")" "trust_lookup resolves a path containing spaces"
trust_store_set "$spaced" "deadbeef"
trust_line_count="$(wc -l < "$HOME/.orchid/trust" | tr -d ' ')"
assert_eq 1 "$trust_line_count" "re-setting the same spaced path does not duplicate the record"
trust_store_remove "$spaced"
[ -z "$(trust_lookup "$spaced")" ] || fail "trust_store_remove clears a spaced-path record"
[ ! -s "$HOME/.orchid/trust" ] || fail "trust file is empty after removing its only (spaced-path) record"

# -- with_timeout (v1-m2 Task 7 regression): a fast command's own exit
# status/output must survive capture through $(...), and the run must
# return promptly even with a LONG deadline -- not just eventually succeed,
# but return well under the deadline. This is the regression net for a real
# bug found wiring up runners/orchid-tick: the watcher's own `sleep "$secs"`
# had already forked as a real child of the watcher subshell by the time
# with_timeout went to cancel it, and a bare `kill "$w"` (no process-group
# targeting) killed only the subshell, orphaning that `sleep` under init for
# the rest of its deadline -- which kept the orphan's inherited stdout pipe
# open and hung any `$(...)`-capturing caller (exactly runners/orchid-tick's
# own usage) for the full deadline on every otherwise-successful run.
start="$(date +%s)"
out="$(with_timeout 3600 bash -c 'echo fast; exit 7')"; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq fast "$out" "with_timeout captures the timed command's stdout"
assert_eq 7 "$rc" "with_timeout returns the timed command's own exit status"
[ "$elapsed" -lt 10 ] || fail "with_timeout must return promptly on early finish, not linger near the deadline (took ${elapsed}s)"

# timeout path: a command that outlives the deadline is killed and 124 is
# returned.
start="$(date +%s)"
out="$(with_timeout 1 bash -c 'sleep 30; echo should-not-print')"; rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq 124 "$rc" "with_timeout returns 124 on timeout"
assert_eq "" "$out" "with_timeout's killed command produces no output"
[ "$elapsed" -lt 10 ] || fail "with_timeout must return promptly after killing on timeout (took ${elapsed}s)"

# ---------------------------------------------------------------------------
# T014 (lesson L019): file_mtime chooses between the BSD and GNU spellings of
# stat on the RESULT, never on the exit status.
#
# The idiom this replaced ran both spellings inside ONE command substitution
# and picked between them with `||`. That is broken on Linux in a way that is
# invisible on macOS: GNU's -f is --file-system and takes no argument, so the
# format word is parsed as a FILE operand. GNU stat is now in filesystem mode
# against a path that really does exist, so it writes that path's filesystem
# block -- whose first line begins `File:` -- to stdout. The caller then does
# arithmetic on a word, and under `set -u` bash dies with
# `File: unbound variable`, which is precisely how lock_acquire (and with it
# every durable verb) went down on ubuntu-latest.
#
# What the caller ends up holding depends on an exit status it should never
# have been reading in the first place: if the filesystem probe exits 0 the
# `||` short-circuits and `mt` is the block alone; if it exits non-zero the
# fallback runs into the SAME substitution and glues its digits onto the end
# of the block. Neither is a number, and that is the whole point -- the exit
# status is not a reliable signal about the output, so the RED case below
# models the shape that a status-reading caller gets WRONG most directly: a
# probe that succeeds while printing something that is not an mtime.
#
# There is a second, quieter hazard on the same axis, and file_mtime rejects
# it for the same reason: an EMPTY result does not blow up in arithmetic at
# all. Bash treats a set-but-empty variable as zero under `set -u`, so an
# undatable path would silently read as the epoch -- age = "now", every lock
# instantly stale -- rather than failing loudly. Two different bad values,
# two different wrong outcomes, so both must be rejected upstream, before any
# value reaches arithmetic.
#
# WHAT THESE CASES ASSERT, AND WHAT THEY DELIBERATELY DO NOT. Every case here
# asserts file_mtime's OUTPUT. None asserts how an interpreter REACTS to a bad
# value, because that reaction is not a property of this codebase: the operator
# measured the same filesystem block yielding exit 127 under /bin/bash 3.2,
# exit 1 under zsh, and exit 0 inside this suite's own execution context. A
# case pinning the bug's failure MODE is therefore unreliable by construction
# -- and one that "passes" at status 0 here would be reporting the hazard as
# absent while the hazard is exactly what it was written to prove. The fix's
# guarantee is not shell-dependent in that way: file_mtime never returns a
# value that is not a run of digits. That is what is asserted below, on the
# output itself, by the same character class file_mtime selects with.
#
# The stub below is a shell FUNCTION, so it shadows the real binary inside its
# subshell and nowhere else. That is deliberate: the point of these cases is
# that they assert the same thing on a macOS laptop and a Linux runner, so
# none of them may consult the platform actually underneath -- the Linux bug
# cannot be provoked out of a BSD stat, so it has to be modelled. The cases
# that do run the real stat are the last two.
#
# The format arguments live in variables so this file never spells the raw
# idiom out literally -- scripts/ci-local.sh greps every shipped shell script
# for it, and that gate should not need an exception for its own test.
# ---------------------------------------------------------------------------
probe="$WORK/mtime-probe"; : > "$probe"
bsd_fmt="%m"; gnu_fmt="%Y"

# RED: under a GNU-behaving stat, the old idiom really does yield a non-number.
# Without this the GREEN cases below would prove nothing -- they would just be
# asserting that a stub returns what the stub was told to return.
#
# The stub SUCCEEDS on the filesystem probe, because that is what filesystem
# mode does against a path that exists. A stub that failed there would model
# the safe half of the hazard: the `||` would fire, the GNU spelling would
# answer, and the idiom would look serviceable.
red_mt="$(
  stat() {
    if [ "$1" = "-f" ]; then
      printf '  File: "%s"\n    ID: 0 Namelen: 255     Type: ext2/ext3\n' "$3"
      return 0
    fi
    printf '1700000000\n'
  }
  stat -f "$bsd_fmt" "$probe" 2>/dev/null || stat -c "$gnu_fmt" "$probe" 2>/dev/null
)"
case "$red_mt" in
  '') fail "RED: the exit-status-selected stat idiom must produce the filesystem block, not nothing -- the Linux hazard is not being reproduced here" ;;
  *[!0-9]*) : ;;
  *) fail "RED: the exit-status-selected stat idiom must come out non-numeric against a GNU-behaving stat (got '$red_mt') -- the Linux hazard is not being reproduced here" ;;
esac

# What that value then DOES to the caller is not asserted, here or anywhere
# below, and the omission is the deliberate kind. Feeding the block to
# arithmetic under `set -u` is what killed lock_acquire on ubuntu-latest, but
# the operator measured that same value exiting 127 under /bin/bash 3.2, 1
# under zsh, and 0 inside this suite's own execution context -- so an assertion
# that it "must fail" pins the interpreter, not the bug, and an assertion that
# it "must fail with status N" pins the interpreter twice. The empty result
# behaves differently again and is a distinct hazard for that reason: a
# set-but-empty variable is not an unbound one, so arithmetic accepts it as
# zero and an undatable path reads as the epoch rather than crashing. Both bad
# values are rejected by file_mtime before any of that can matter, and the
# GREEN cases below assert exactly that, on file_mtime's output.

# GREEN: the same stub, through file_mtime, produces the GNU mtime -- the
# filesystem probe's exit 0 does not stop the fall-through, because file_mtime
# reads the result and not the status.
green_gnu="$(
  stat() {
    if [ "$1" = "-f" ]; then
      printf '  File: "%s"\n    ID: 0 Namelen: 255     Type: ext2/ext3\n' "$3"
      return 0
    fi
    printf '1700000000\n'
  }
  file_mtime "$probe"
)"
assert_eq 1700000000 "$green_gnu" \
  "file_mtime discards a filesystem block and falls through to the GNU spelling"

# GREEN: the other half of "the status is not a signal" -- the same block, but
# printed by a probe that exits non-zero. The raw idiom would glue the two
# outputs together inside its single substitution; file_mtime runs each
# spelling in its own substitution, so the block is discarded outright and the
# caller gets the GNU number alone, never the number with a word in front of
# it.
green_gnu_rc1="$(
  stat() {
    if [ "$1" = "-f" ]; then
      printf '  File: "%s"\n    ID: 0 Namelen: 255     Type: ext2/ext3\n' "$3"
      return 1
    fi
    printf '1700000004\n'
  }
  file_mtime "$probe"
)"
assert_eq 1700000004 "$green_gnu_rc1" \
  "file_mtime never concatenates the two spellings' output, whatever the first one's exit status"

# GREEN: selection is on the RESULT, so a BSD probe that SUCCEEDS (exit 0)
# while printing something non-numeric must still fall through. Exit status
# alone would stop here and hand the caller a literal question mark.
green_ok="$(
  stat() {
    if [ "$1" = "-f" ]; then printf '?\n'; return 0; fi
    printf '1700000001\n'
  }
  file_mtime "$probe"
)"
assert_eq 1700000001 "$green_ok" \
  "file_mtime falls through on a non-numeric result even when that probe exited 0"

# GREEN: a BSD probe that does yield a number wins outright -- the fallback is
# never consulted, so a machine where only one spelling exists is unaffected.
green_bsd="$(
  stat() {
    if [ "$1" = "-f" ]; then printf '1700000002\n'; return 0; fi
    printf 'gnu-spelling-should-not-have-been-consulted\n'
  }
  file_mtime "$probe"
)"
assert_eq 1700000002 "$green_bsd" "file_mtime keeps a numeric BSD result and stops there"

# GREEN: neither spelling usable -> the fallback, defaulting to 0. Callers
# differ on what that should be and the difference is a safety property:
# orchid-answer wants 0 so an undatable question is refused (fail closed),
# while lock_acquire passes the current time so an undatable lock reads as
# age 0 and cannot be broken (fail safe).
green_default="$(
  stat() { return 1; }
  file_mtime "$probe"
)"
assert_eq 0 "$green_default" "file_mtime defaults to 0 when no spelling yields a number"
green_fallback="$(
  stat() { printf 'File: not a number\n'; return 0; }
  file_mtime "$probe" 4242
)"
assert_eq 4242 "$green_fallback" "file_mtime honours a caller-supplied fallback"

# GREEN, the second hazard: a probe that prints NOTHING and exits 0 is the
# case no downstream crash would ever catch, so file_mtime has to catch it.
# Both spellings answer with empty success here; the caller must still get the
# fallback, not an empty string that would later evaluate as zero and make
# every lock look infinitely old.
green_empty="$(
  stat() { return 0; }
  file_mtime "$probe" 4243
)"
assert_eq 4243 "$green_empty" \
  "file_mtime rejects an empty result even when both spellings exited 0 -- empty would pass arithmetic as zero, not crash"

# GREEN, the invariant the whole task is about, stated over every case above
# at once: EVERY value file_mtime can hand a caller is a non-empty run of
# digits. That single shape rules out both hazards at their source -- a word
# can never reach the arithmetic that read `File` as a variable name, and an
# empty string can never reach the arithmetic that would quietly call it zero.
#
# Asserted on the value, with the character class, rather than by handing each
# value to arithmetic and watching what happens: an arithmetic probe reports
# the interpreter's mood (127, 1 or 0 for the same input, depending on the
# shell and the surrounding context -- see the header), while `*[!0-9]*`
# reports the helper's contract and reports it identically everywhere. It is
# also the strictly stronger check, because it is the one that still fails
# when the interpreter shrugs the bad value off.
for case_mt in "$green_gnu" "$green_gnu_rc1" "$green_ok" "$green_bsd" \
               "$green_default" "$green_fallback" "$green_empty"; do
  case "$case_mt" in
    '') fail "file_mtime returned an empty result; arithmetic accepts that as zero, so an undatable path would read as the epoch instead of being refused" ;;
    *[!0-9]*) fail "file_mtime returned '$case_mt', which is not a run of digits -- a non-numeric mtime reaching arithmetic is exactly the 'File: unbound variable' crash this helper exists to make impossible" ;;
  esac
done

# GREEN, unstubbed: whatever stat this platform actually ships, a real file's
# mtime comes back as a plausible epoch second. This is the case that would
# catch a helper that is internally consistent but wrong about both platforms.
real_mt="$(file_mtime "$probe")"
case "$real_mt" in
  ''|*[!0-9]*) fail "file_mtime must return digits for a real file on this platform (got '$real_mt')" ;;
  *) [ "$real_mt" -gt 1600000000 ] \
       || fail "file_mtime read an implausible mtime for a just-created file (got '$real_mt') -- it is falling back instead of reading either stat spelling" ;;
esac

# GREEN, unstubbed, FAILURE path: every case above that exercises a probe
# which cannot answer does it against a shell function, so it proves what the
# stub was told to say and nothing about the binary on this machine. The
# unreadable path is the one failure the real stat CAN be made to produce
# identically on both platforms, so run it for real: whatever this box ships,
# BOTH spellings come back empty-handed and the caller still gets digits.
#
# That matters more than it looks. On the platform where the wrong spelling
# does not merely fail but PRINTS -- GNU's --file-system block for a path that
# does exist -- the leak into arithmetic is what took CI down; here neither
# spelling has anything to print, which is the other half of the same
# guarantee and the half a stub cannot vouch for. This is the hermetic case:
# it asserts the same thing on a macOS laptop and a Linux runner, and it is
# the only mtime case whose verdict depends on the real binary's behaviour
# rather than on a fixture agreeing with itself (lesson L019's first root
# cause -- a suite that passes because of what the machine happens to have).
absent="$WORK/mtime-probe-absent"
[ -e "$absent" ] && fail "test fixture error: $absent must not exist"
absent_default="$(file_mtime "$absent")"
assert_eq 0 "$absent_default" \
  "file_mtime falls back to 0 when the real stat cannot date the path at all"
absent_fallback="$(file_mtime "$absent" 1700000003)"
assert_eq 1700000003 "$absent_fallback" \
  "file_mtime honours a caller-supplied fallback against the real stat, not just a stub"
# And the invariant, once more and in the same shape, on the values the REAL
# binary produced rather than a stub's.
for case_mt in "$real_mt" "$absent_default" "$absent_fallback"; do
  case "$case_mt" in
    '') fail "file_mtime returned an empty result from the platform's own stat; arithmetic would take that as zero rather than refusing it" ;;
    *[!0-9]*) fail "file_mtime returned '$case_mt' from the platform's own stat, which is not a run of digits and so is not safe in the arithmetic every caller does with it" ;;
  esac
done
