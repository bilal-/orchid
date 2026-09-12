#!/usr/bin/env bash
source "$(dirname "$0")/../helpers.sh"
# INV-17: `--help` IS ANSWERED BY THE VERB, NEVER BY THE RUN STATE, AND NEVER
# BY DOING THE THING IT ASKS ABOUT.
#
# Dogfood F45 (2026-08-11, wasiyyat): `orchid task arbitrate --help` refused
# with `stale epoch 'unset' (current 0)` and printed no usage at all. The
# operator was reading help precisely BECAUSE the state was already wrong --
# they were mid-recovery from F44, a task nothing could move -- and the one
# surface that exists to say what to do next was gated on the thing that had
# gone wrong. The same sweep that repaired it found a second, worse shape:
# several verbs read their first argument as data, so `orchid plugins lock
# --help` WROTE `.orchid/plugins.lock` and `orchid plugins untrust --help`
# reported untrusting a plugin named `--help`.
#
# THE INVARIANT IS DERIVED, NOT LISTED (the INV-14/INV-15 discipline). The
# scan below walks `libexec/orchid-*` itself and, for each file, extracts its
# subverbs from its own `case "$sub" in` block. A verb added tomorrow is
# covered by this file without anyone remembering to extend it, and a subverb
# added to an existing verb is covered the moment it appears in that case
# block. That is the difference between an invariant and the one-off sweep
# that repaired F45.
#
# WHAT IS CHECKED, for every (verb) and every (verb, subverb):
#
#   1. `--help` exits 0. A usage string on a non-zero exit is a refusal that
#      happens to be informative; help is not a refusal.
#   2. Its first line begins `usage: orchid <verb>`. This is what separates
#      "the verb answered" from "the epoch fence answered", from "the command
#      ran", and from a raw `set -u` error naming a source file.
#   3. It is run under a DELIBERATELY STALE EPOCH. That is the condition F45
#      was reported under, and an unfenced help path is the only way to satisfy
#      it.
#   4. Nothing is written. The repository state is captured before and after
#      the whole sweep and must be byte-identical -- this is the check that
#      would have caught `plugins lock --help`.

cd_scratch "$WORK" || exit 1
git init -q .
git commit -q --allow-empty -m root
export ORCHID_REPO="$WORK" HOME="$WORK/home"
mkdir -p "$HOME"
"$ORCHID_BIN" init >/dev/null 2>&1 || true
"$ORCHID_BIN" run start >/dev/null 2>&1 || true

# The stale epoch every probe below runs under. `run start` fenced epoch 0, so
# this value is wrong by construction and every mutating verb must refuse it.
STALE_EPOCH=999999

# inv17_subverbs <file> -- the subverb labels of one libexec file, derived from
# its own `case "$sub" in` block and nothing else.
#
# Scoped to that block deliberately. A bare `grep` for `^  <word>)` across the
# file also collects the arms of unrelated case statements -- `orchid-merge`
# has one keyed on a preparation result whose `fail)` arm is not a subverb at
# all -- and probing those would test a claim nobody makes.
#
# EVERY such block, not the first one. The help gate this invariant exists for
# is ITSELF a `case "$sub" in` -- carrying only the two help spellings -- so a
# scan that stopped at the first `esac` would derive nothing at all from the
# very files it most needs to cover, and would then pass by walking an empty
# list. The probe count assertion below is the backstop for exactly that.
inv17_subverbs() {
  awk '
    /^case "\$sub" in/ { inblock = 1; next }
    inblock && /^esac/ { inblock = 0; next }
    inblock && /^  [^ ]*\)/ {
      line = $0
      sub(/^  /, "", line)
      sub(/\).*$/, "", line)
      n = split(line, parts, "|")
      for (i = 1; i <= n; i++) {
        # Help spellings are what this file probes WITH, and the catch-all is
        # not a subverb. Quoted empty labels ('"''"') are the no-argument arm.
        if (parts[i] ~ /^[a-z][a-z-]*$/) print parts[i]
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

inv17_state_digest() {
  # Content, not mtimes: a help path that rewrote a file with identical bytes
  # is not what this guards against, and a digest over mtimes would fail for
  # any read that touches an atime-like field.
  find "$WORK/.orchid" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(cksum < "$f")"
  done
}

INV17_BEFORE="$(inv17_state_digest)"
inv17_probed=0
inv17_bad=0

inv17_probe() {
  local out rc=0 first
  inv17_probed=$(( inv17_probed + 1 ))
  out="$(ORCHID_EPOCH="$STALE_EPOCH" "$ORCHID_BIN" "$@" --help 2>&1)" || rc=$?
  first="$(printf '%s\n' "$out" | head -1)"
  if [ "$rc" -ne 0 ]; then
    fail "INV-17: 'orchid $* --help' exited $rc — help is not a refusal (first line: $first)"
    inv17_bad=$(( inv17_bad + 1 ))
    return 0
  fi
  case "$first" in
    "usage: orchid $1"*) ;;
    *)
      fail "INV-17: 'orchid $* --help' did not answer with its own usage (first line: $first)"
      inv17_bad=$(( inv17_bad + 1 )) ;;
  esac
}

for inv17_f in "$REPO_ROOT"/libexec/orchid-*; do
  [ -e "$inv17_f" ] || continue
  inv17_verb="${inv17_f##*/orchid-}"
  # `drive` and `service` are tier-1 -> tier-2 hand-offs that exec a runner;
  # they are probed as verbs like any other, and the runner is responsible for
  # the same answer.
  inv17_probe "$inv17_verb"
  while IFS= read -r inv17_sub; do
    [ -n "$inv17_sub" ] || continue
    inv17_probe "$inv17_verb" "$inv17_sub"
  done <<< "$(inv17_subverbs "$inv17_f")"
done

# THE FLOOR IS SET ABOVE A KNOWN-BROKEN DERIVATION, not above zero. The first
# version of inv17_subverbs stopped at the first `esac` and collected 25
# probes -- enough to clear any floor written as "more than nothing", and
# missing almost every subverb in the tree. The shipped derivation collects 78.
[ "$inv17_probed" -ge 60 ] \
  || fail "INV-17: the derivation collected only $inv17_probed probes — the shipped tree yields 78, so this scan is walking a fraction of the surface and its silence means nothing"

INV17_AFTER="$(inv17_state_digest)"
assert_eq "$INV17_BEFORE" "$INV17_AFTER" \
  "INV-17: asking for help wrote to .orchid/ — 'orchid plugins lock --help' used to mint the lock file, which is the shape this compares for"

red_case "every verb and subverb in the shipped tree ($inv17_probed probes, derived from libexec/ and each file's own case block) answers --help itself, on a stale epoch, without writing anything"

# GREEN twin: the checks above are not matchers that accept anything. A verb
# that ignores --help fails check 2, and a mutating call on the same stale
# epoch is still refused -- so the sweep's silence is evidence that the fence
# is intact rather than evidence that it is gone.
inv17_shim="$WORK/shim"
mkdir -p "$inv17_shim/libexec" "$inv17_shim/bin"
cat > "$inv17_shim/libexec/orchid-notahelper" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
echo "did the thing instead of printing usage"
SHIM
chmod +x "$inv17_shim/libexec/orchid-notahelper"
cp "$REPO_ROOT/bin/orchid" "$inv17_shim/bin/orchid"
inv17_shim_out="$("$inv17_shim/bin/orchid" notahelper --help 2>&1 || true)"
case "$(printf '%s\n' "$inv17_shim_out" | head -1)" in
  "usage: orchid notahelper"*)
    fail "INV-17: the check accepted a verb that never printed usage — it would pass over the very defect it exists to find" ;;
esac

inv17_fence_rc=0
inv17_fence="$(ORCHID_EPOCH="$STALE_EPOCH" "$ORCHID_BIN" task create INV17 "must not be created" 2>&1)" || inv17_fence_rc=$?
[ "$inv17_fence_rc" -ne 0 ] \
  || fail "INV-17: the help gate opened a hole in the epoch fence — a real mutating call on the stale epoch was accepted"
assert_match "stale epoch" "$inv17_fence" \
  "INV-17: ...and INV-02 is still what answers a mutating call on a stale epoch"
[ ! -f "$WORK/.orchid/tasks/INV17.md" ] \
  || fail "INV-17: the refused create wrote a task file"
green_case "a verb that runs instead of printing usage is REJECTED by the same check, and the epoch fence still refuses a real mutating call on the same stale epoch"
