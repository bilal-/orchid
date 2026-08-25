#!/usr/bin/env bash
# Reusable LOCAL beta qualification harness.
#
# Run this against an operator-supplied repository to find out whether THIS
# Orchid build can actually drive THAT repository unattended, before a beta
# tester spends a day discovering it cannot. It contacts nothing, publishes
# nothing, and writes nothing OF ITS OWN inside the target repository -- with
# one exception, stated here rather than discovered later: by default this
# harness runs the target repository's own configured `verify=` command once,
# IN PLACE, to time it. That command is the operator's code, chosen by the
# operator, and whatever it writes it writes; this harness neither sandboxes
# it nor makes it safe. Running it is what makes the timing probe a
# measurement instead of a guess, which is why the exception exists rather
# than the promise being quietly weakened. `--no-run-verify` skips it and
# records the timing probe as `not-tested`, never as a pass.
#
# That exception is also announced ON STDERR at the moment it happens, because
# a header comment and a `--help` page are read by whoever goes looking and the
# operator who does not look is exactly the one who needed telling. That notice
# stands in place of a trust step: qualification takes NO acknowledgement of its
# own, deliberately, and the reasoning together with the
# alternatives that were rejected is recorded in docs/specs/operations.md
# ("Qualification runs the target verify= command, and takes no
# acknowledgement"). Read that before adding a gate here.
#
# ---------------------------------------------------------------------------
# THE EVIDENCE RULE (the reason this file is shaped the way it is)
# ---------------------------------------------------------------------------
# Recorded evidence carries ANONYMIZED metadata, check identities, durations,
# and outcomes. It never carries repository contents, paths, prompts, diffs,
# filenames, command lines, or secrets. That is enforced structurally, not by
# care: NO subprocess output is ever copied into a probe record. Every string
# in the emitted JSON/text is either
#   * a literal authored in this file, or
#   * a number this file measured (a duration, an exit code, a bucketed count),
#     or
#   * a value drawn from a CLOSED vocabulary this file defines (pass/fail/
#     blocked/not-tested, allowed/denied, present/absent, and the platform
#     names `os_token` maps `uname -s` onto), or
#   * a toolchain version that MATCHED a pattern authored here -- dotted digits
#     and nothing else, see `version_token`, which replaces anything else with
#     the closed token `unrecognized`. This is the one class of recorded value
#     another program chose the characters of, which is exactly why it is
#     validated rather than trusted: a vendor build is free to append a build
#     path or a packager's tag to its own version string, or
#   * this build's own version constant (`ORCHID_VERSION`, lib/common.sh),
#     which describes the harness rather than the target repository.
# Subprocess output is otherwise inspected only to derive one of those closed
# values and is then discarded. `_scrub_guard` re-checks the finished evidence
# for the target, home, scratch, and output PATHS and refuses to leave the
# files on disk if any appears.
#
# ---------------------------------------------------------------------------
# PROBE, DO NOT INFER
# ---------------------------------------------------------------------------
# Every record states what was actually executed (`tested`), why the check
# exists (`why`), and why THIS outcome was reached (`result`). `why` and
# `result` are mandatory: this repository's own hardening run lost reviewer
# reasoning five times because a verdict was recorded without it, and a harness
# that records pass/fail without the why reproduces exactly the evidence gap it
# exists to close.
#
# A check this harness cannot perform is recorded as `not-tested` with the
# reason it was not performed -- never as a pass, and never silently omitted.
# The verdict names its own scope and enumerates what it does not certify. A
# non-blocking gap carries `expires_when`, so no warning outlives its cause.
#
# Genuine third-party beta runs and public release are OPERATOR-OWNED. This
# harness never performs them and never records that they happened.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORCHID_ROOT="$ROOT"
export ORCHID_ROOT
ORCHID_BIN="$ROOT/bin/orchid"

QUALIFY_SCHEMA=1
REPO=""
OUTPUT=""
LABEL="candidate"
BASH_BIN="${BASH:-/bin/bash}"
VERIFY_TIMEOUT_S=900
RUN_VERIFY=1
SCRATCH=""

die() { echo "beta-qualify: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
usage: scripts/beta-qualify.sh --repo DIR --output DIR [options]

Qualifies one operator-supplied repository against this Orchid build and writes
anonymized local evidence to DIR/qualification.json and DIR/qualification.txt.

  --repo DIR             the repository to qualify (read-only input, apart from
                         the one in-place verify= run described below)
  --output DIR           where to write the evidence pair (never overwritten)
  --label NAME           name for this repository in the evidence
                         ([A-Za-z0-9._-], 1-32 chars; default "candidate")
  --bash PATH            Bash interpreter to version-check (default $BASH)
  --verify-timeout-s N   cap on the single verify run (default 900)
  --no-run-verify        do not execute the repository's verify= command; the
                         duration probe is then recorded as not-tested
  -h, --help             this text

It never pushes, publishes, deploys, tags, or contacts a remote, writes nothing
of its own inside --repo, and never copies repository content into the evidence.

ONE EXCEPTION to "writes nothing inside --repo", and it is deliberate: unless
you pass --no-run-verify, this harness executes --repo's own configured verify=
command once, IN PLACE, to time it. That is the operator's own code running in
the operator's own repository -- whatever it writes, it writes, and this harness
neither sandboxes it nor makes it safe. Timing it any other way would be a
guess. With --no-run-verify the duration probe is recorded as not-tested, never
as a pass. The run is also announced on stderr as it starts. That notice stands
in place of a trust step: qualification is deliberately ungated, because the
acknowledgement that opens the headless gate is meant to be made AFTER a
repository qualifies, not as a precondition for finding out whether it does.
See docs/specs/operations.md for that decision and what was rejected.

The verify= command's own output is discarded unread: its exit code and
wall-clock duration are the only things recorded about it. The recorded
toolchain versions and platform name are matched against fixed patterns
authored in this script; anything that does not match is recorded as
"unrecognized"/"other" rather than verbatim, and never changes an outcome.

Genuine third-party beta runs and public release remain operator-owned. This
harness does not perform them and never records that they happened.

Exit: 0 qualified, 1 not qualified, 2 usage or precondition failure.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a directory"; REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --output) [ "$#" -ge 2 ] || die "--output requires a directory"; OUTPUT="$2"; shift 2 ;;
    --output=*) OUTPUT="${1#--output=}"; shift ;;
    --label) [ "$#" -ge 2 ] || die "--label requires a value"; LABEL="$2"; shift 2 ;;
    --label=*) LABEL="${1#--label=}"; shift ;;
    --bash) [ "$#" -ge 2 ] || die "--bash requires a path"; BASH_BIN="$2"; shift 2 ;;
    --bash=*) BASH_BIN="${1#--bash=}"; shift ;;
    --verify-timeout-s) [ "$#" -ge 2 ] || die "--verify-timeout-s requires a value"
      VERIFY_TIMEOUT_S="$2"; shift 2 ;;
    --verify-timeout-s=*) VERIFY_TIMEOUT_S="${1#--verify-timeout-s=}"; shift ;;
    --no-run-verify) RUN_VERIFY=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] || { usage >&2; die "--repo is required"; }
[ -n "$OUTPUT" ] || { usage >&2; die "--output is required"; }
[ -d "$REPO" ] || die "--repo is not a directory"
# The label is operator-supplied text that lands verbatim in the evidence.
# A closed character class keeps it from smuggling in a path fragment.
#
# A HERESTRING, never `producer | grep -q`: this file runs under `set -o
# pipefail`, and `grep -q` exits at its FIRST match, which SIGPIPEs the producer
# mid-write. pipefail then promotes that 141 to the pipeline's status, so a
# pattern that DID match reads as a refusal. It only fires once the input is
# long enough that the producer is still writing, which makes it a silent,
# size-dependent coin flip rather than an obvious break. `<<<` feeds grep from a
# temp file: no pipe, no SIGPIPE, and the status is the matcher's alone.
grep -Eq '^[A-Za-z0-9._-]{1,32}$' <<<"$LABEL" \
  || die "--label must be 1-32 characters of [A-Za-z0-9._-]"
grep -Eq '^[0-9]+$' <<<"$VERIFY_TIMEOUT_S" \
  || die "--verify-timeout-s must be a non-negative integer"
command -v jq >/dev/null 2>&1 || die "jq is required to emit evidence"
command -v git >/dev/null 2>&1 || die "git is required"

REPO="$(cd "$REPO" && pwd -P)" || die "cannot resolve --repo"
# Reject an output path inside the target BEFORE creating anything, so the
# refusal itself cannot be the first write into the repository it protects.
# The logical form is checked first for exactly that reason; the physical form
# is re-checked after resolution, in case a symlink hid the containment, and
# that later refusal removes the directory it just made when it is still empty.
case "$OUTPUT" in /*) output_logical="$OUTPUT" ;; *) output_logical="$PWD/$OUTPUT" ;; esac
case "$output_logical/" in
  "$REPO"/*) die "--output must not live inside --repo (this harness never places evidence inside the target repository)" ;;
esac
mkdir -p "$OUTPUT" || die "cannot create --output"
OUTPUT="$(cd "$OUTPUT" && pwd -P)" || die "cannot resolve --output"
case "$OUTPUT/" in
  "$REPO"/*)
    rmdir "$OUTPUT" 2>/dev/null
    die "--output must not live inside --repo (this harness never places evidence inside the target repository)" ;;
esac
JSON_OUT="$OUTPUT/qualification.json"
TEXT_OUT="$OUTPUT/qualification.txt"
[ ! -e "$JSON_OUT" ] || die "refusing to overwrite $JSON_OUT"
[ ! -e "$TEXT_OUT" ] || die "refusing to overwrite $TEXT_OUT"

SCRATCH="$(mktemp -d)" || die "cannot create a scratch directory"
[ -n "$SCRATCH" ] && [ -d "$SCRATCH" ] || die "mktemp -d produced no usable scratch directory"
cleanup() { if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then rm -rf "${SCRATCH:?}"; fi; }
trap cleanup EXIT

# Resolve roles, plugins, and config through Orchid's own libraries rather than
# re-deriving any of it here: a qualification harness that disagreed with the
# kernel about which implementer is configured would qualify the wrong profile.
# ORCHID_REPO is what repo-local plugin discovery keys on (lib/resolver.sh).
export ORCHID_REPO="$REPO"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/manifest.sh"
source "$ROOT/lib/roles.sh"
source "$ROOT/lib/resolver.sh"

PROBES="$SCRATCH/probes.jsonl"
: > "$PROBES"

now_s()   { date -u +%s; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

PROBE_T0=0
PROBE_DUR=0
probe_start() { PROBE_T0="$(now_s)"; PROBE_DUR=0; }
probe_stop()  { PROBE_DUR=$(( $(now_s) - PROBE_T0 )); }

# record <id> <title> <outcome> <blocking:true|false> <tested> <why> <result>
#        [expires_when]
#
# Duration comes from the probe_start/probe_stop pair, so no caller can record
# a probe without having bracketed the work it claims to have done.
record() {
  local id="$1" title="$2" outcome="$3" blocking="$4"
  local tested="$5" why="$6" result="$7" expires="${8:-}"
  case "$outcome" in
    pass|fail|blocked|not-tested) ;;
    *) die "internal: probe $id has an outcome outside the closed vocabulary: $outcome" ;;
  esac
  case "$blocking" in true|false) ;; *) die "internal: probe $id blocking must be true or false" ;; esac
  [ -n "$tested" ] || die "internal: probe $id records no 'tested' statement"
  [ -n "$why" ] || die "internal: probe $id records no 'why' -- refusing to record an outcome without its reasoning"
  [ -n "$result" ] || die "internal: probe $id records no 'result' -- refusing to record an outcome without its reasoning"
  jq -cn --arg id "$id" --arg title "$title" --arg outcome "$outcome" \
        --argjson blocking "$blocking" --argjson duration_s "$PROBE_DUR" \
        --arg tested "$tested" --arg why "$why" --arg result "$result" \
        --arg expires_when "$expires" \
    '{id:$id, title:$title, outcome:$outcome, blocking:$blocking,
      duration_s:$duration_s, tested:$tested, why:$why, result:$result}
     + (if $expires_when == "" then {} else {expires_when:$expires_when} end)' \
    >> "$PROBES" || die "internal: cannot record probe $id"
}

# bucket <count> -- an order-of-magnitude band. Repository size is legitimate
# qualification metadata; an exact count is a fingerprint, so only the band is
# recorded.
bucket() {
  local n="$1"
  if   [ "$n" -lt 10 ];    then echo "0-9"
  elif [ "$n" -lt 100 ];   then echo "10-99"
  elif [ "$n" -lt 1000 ];  then echo "100-999"
  elif [ "$n" -lt 10000 ]; then echo "1000-9999"
  else echo "10000+"; fi
}

# version_token <string> -- the only class of value in the emitted evidence
# whose characters another program chose. Which toolchain a candidate runs is
# legitimate qualification metadata, but the reporting program owns the whole
# string and vendor builds routinely append a build path, a distribution tag,
# or a packager's suffix to it -- `git --version` on a Homebrew or Apple build
# is the standing example. So the string is matched against a pattern authored
# HERE (dotted digits, at most 32 characters, no leading, trailing, or doubled
# dot) and anything else is recorded as the closed token `unrecognized`.
# Case patterns, not grep: no subprocess, so nothing can be leaked by the
# matcher itself. PRESENCE is derived separately, from the raw output, so an
# unusual version spelling never turns a working toolchain into a failed probe.
version_token() {
  local v="$1"
  [ "${#v}" -le 32 ] || { echo unrecognized; return 0; }
  case "$v" in
    ""|*[!0-9.]*|.*|*.|*..*) echo unrecognized; return 0 ;;
  esac
  printf '%s\n' "$v"
}

# os_token -- the same discipline for the platform name. `uname -s` is another
# string this file does not author, and a kernel is free to report whatever it
# likes there. Map it onto the closed set this repository's portability policy
# actually distinguishes, and record anything else as `other`.
os_token() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)  echo Darwin ;;
    Linux)   echo Linux ;;
    FreeBSD) echo FreeBSD ;;
    OpenBSD) echo OpenBSD ;;
    NetBSD)  echo NetBSD ;;
    SunOS)   echo SunOS ;;
    CYGWIN*|MINGW*|MSYS*) echo Windows-POSIX-layer ;;
    *)       echo other ;;
  esac
}

# run_quiet <cmd...> -- run, discard BOTH streams, return the exit code. This
# is how the harness executes anything it does not own: nothing the command
# prints can reach a probe record.
run_quiet() { "$@" >/dev/null 2>&1; }

# first_line <text> -- no `producer | head -n 1` anywhere in this file. This
# script runs under `set -o pipefail`, and head exits at its first line, which
# SIGPIPEs the producer mid-write; pipefail then promotes that 141 to the
# pipeline's status, so a perfectly good multi-line result reads as a failure.
# Parameter expansion has no pipe, so it has no such failure mode.
first_line() { printf '%s' "${1%%$'\n'*}"; }

# Wall-clock capping uses lib/common.sh's own `with_timeout` (124 on timeout,
# the command's own status otherwise). timeout(1) is absent on a stock macOS,
# and reimplementing the kill-the-process-GROUP handling that function already
# carries would reintroduce the orphaned-child bugs its comment documents.

STARTED_AT="$(now_utc)"
STARTED_S="$(now_s)"
OS_TOKEN="$(os_token)"

# ===========================================================================
# toolchain -- Orchid's stated floor is Bash 3.2, Git, and jq, with no daemon,
# database, or language runtime. A tester on a short toolchain otherwise meets
# this as an unrelated verb failure three commands later.
# ===========================================================================
probe_start
bash_version="$(version_token "$("$BASH_BIN" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || true)")"
bash_ok=0
if run_quiet "$BASH_BIN" -c '[ -n "${BASH_VERSION:-}" ] && (( BASH_VERSINFO[0] > 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] >= 2) ))'; then
  bash_ok=1
fi
# Presence from the RAW output, the recorded string from the validated token:
# a version this harness cannot parse still counts as a present tool.
git_raw="$(git --version 2>/dev/null | awk '{print $3}')"
jq_raw="$(jq --version 2>/dev/null | sed 's/^jq-//')"
git_state=absent; [ -n "$git_raw" ] && git_state=present
jq_state=absent;  [ -n "$jq_raw" ]  && jq_state=present
git_version="$(version_token "$git_raw")"
jq_version="$(version_token "$jq_raw")"
TOOLCHAIN_TESTED="ran the named Bash with a BASH_VERSINFO floor check, then 'git --version' and 'jq --version'"
TOOLCHAIN_WHY="Orchid is Bash 3.2 plus Git plus jq with no daemon, database, or language runtime; a short toolchain surfaces later as an unrelated verb failure whose real cause is invisible"
probe_stop
if [ "$bash_ok" -eq 1 ] && [ "$git_state" = present ] && [ "$jq_state" = present ]; then
  record toolchain "interpreter and tool floor" pass true \
    "$TOOLCHAIN_TESTED" "$TOOLCHAIN_WHY" \
    "bash is at or above 3.2 (version $bash_version); git present (version $git_version); jq present (version $jq_version); a version outside this harness's authored pattern reads 'unrecognized' and never affects the outcome"
else
  bash_state=absent; [ "$bash_ok" -eq 1 ] && bash_state=present
  record toolchain "interpreter and tool floor" fail true \
    "$TOOLCHAIN_TESTED" "$TOOLCHAIN_WHY" \
    "bash at or above 3.2: $bash_state; git: $git_state; jq: $jq_state"
fi

# ===========================================================================
# repo-config -- a Git worktree with a repo-local orchid.config carrying a
# verify= command. Verification EVIDENCE is bound to that command's recorded
# exit status; with none configured, every task stalls before a reviewer ever
# sees a candidate.
# ===========================================================================
probe_start
is_git=0
run_quiet git -C "$REPO" rev-parse --git-dir && is_git=1
has_config=absent; [ -f "$REPO/orchid.config" ] && has_config=present
verify_cmd="$(config_get "$REPO" verify)"
has_verify=absent; [ -n "$verify_cmd" ] && has_verify=present
commit_bucket="n/a"; file_bucket="n/a"
if [ "$is_git" -eq 1 ]; then
  commit_bucket="$(bucket "$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)")"
  file_bucket="$(bucket "$(git -C "$REPO" ls-files 2>/dev/null | wc -l | tr -d ' ')")"
fi
REPO_CONFIG_TESTED="ran 'git rev-parse --git-dir' inside the target, read orchid.config through Orchid's own config resolver, and bucketed the commit and tracked-file counts"
REPO_CONFIG_WHY="verification evidence is the recorded exit status of the operator-selected verify= command; with none configured every task stalls at testing and no reviewer ever sees a candidate"
probe_stop
worktree_state=no; [ "$is_git" -eq 1 ] && worktree_state=yes
if [ "$is_git" -eq 1 ] && [ "$has_verify" = present ]; then
  record repo-config "Git worktree with a configured verify command" pass true \
    "$REPO_CONFIG_TESTED" "$REPO_CONFIG_WHY" \
    "git worktree: $worktree_state; orchid.config: $has_config; verify=: $has_verify; commits: $commit_bucket; tracked files: $file_bucket"
else
  record repo-config "Git worktree with a configured verify command" fail true \
    "$REPO_CONFIG_TESTED" "$REPO_CONFIG_WHY" \
    "git worktree: $worktree_state; orchid.config: $has_config; verify=: $has_verify; commits: $commit_bucket; tracked files: $file_bucket"
fi

# ===========================================================================
# unattended-gate -- REPORT the machine-local gate; never change it. An
# acknowledgement is an operator act carrying an operator-authored reason, so a
# qualification harness that granted one would be granting itself trust.
# ===========================================================================
probe_start
gate_state() {
  local out token
  out="$("$ORCHID_BIN" trust show "$REPO" 2>/dev/null)" || { echo unreadable; return 0; }
  # Extract the closed token only; the rest of that output names real paths.
  token="$(first_line "$(printf '%s\n' "$out" | sed -n 's/^gate: //p')")"
  case "$token" in
    allowed) echo allowed ;;
    denied)  echo denied ;;
    *)       echo unreadable ;;
  esac
}
gate_before="$(gate_state)"
gate_after="$(gate_state)"
GATE_TESTED="ran 'orchid trust show' against the target twice, extracted only the gate token from each, and compared the two"
GATE_WHY="headless ticks and background-service installation stay refused until an operator acknowledges the prompt-injection risk of this specific repository; a tester who cannot read that gate cannot tell a deliberate refusal from a hang"
probe_stop
if [ "$gate_before" = unreadable ] || [ "$gate_after" = unreadable ]; then
  record unattended-gate "machine-local unattended trust gate" fail true \
    "$GATE_TESTED" "$GATE_WHY" \
    "the gate state could not be read, so it is reported as unreadable rather than assumed to be either state"
elif [ "$gate_before" != "$gate_after" ]; then
  # The second read is only worth taking if its answer can change the outcome.
  # Two different answers mean the gate moved WHILE this harness was looking at
  # it -- and since this harness never acknowledges, whatever moved it was
  # something else on this machine. Reporting either token as "the" gate state
  # would be reporting a state that had already stopped being true.
  record unattended-gate "machine-local unattended trust gate" fail true \
    "$GATE_TESTED" "$GATE_WHY" \
    "the gate read '$gate_before' and then '$gate_after': it changed between two back-to-back inspections, so no single state can be reported for it; this harness never acknowledges, so something else on this machine moved it and the target's gate must be settled before its qualification means anything"
else
  record unattended-gate "machine-local unattended trust gate" pass true \
    "$GATE_TESTED" "$GATE_WHY" \
    "the gate reads '$gate_before' and both back-to-back reads agree, so it is unchanged across inspection; this harness never acknowledges, so an unattended run stays refused until the operator runs 'orchid trust unattended <repo> --reason ...' themselves"
fi

# ===========================================================================
# implementer-shell -- the no-shell implementer profile, half one.
#
# An implementer that cannot run a command cannot run a repository script (a
# candidate-local codegen step, a lockfile refresh, a formatter) and cannot
# change a file mode.
# Both are silent, recurring operator hand-offs, and both are headless
# DEADLOCKS: no other actor in the loop can perform them either, so a task
# needing one can neither finish nor fail.
#
# This half checks the DECLARATION -- the resolved engine plugin's manifest
# capabilities= -- which is decisive when `shell` is absent. When it is
# present, see implementer-command-execution below: a declaration is not a
# grant, and the shipped `claude` adapter is the standing counter-example.
# ===========================================================================
probe_start
impl_primary=""
impl_caps=""
impl_resolved=absent
impl_chain="$(resolve_role_chain "$REPO" implementer 2>/dev/null)"
impl_primary="$(first_line "$impl_chain")"
if [ -n "$impl_primary" ] && impl_dir="$(resolve_engine_dir "$impl_primary" 2>/dev/null)"; then
  impl_resolved=present
  impl_caps="$(manifest_get "$impl_dir" capabilities)"
fi
IMPLEMENTER_SHELL=absent
case ",$impl_caps," in *,shell,*) IMPLEMENTER_SHELL=present ;; esac
IMPL_TESTED="resolved role.implementer through Orchid's own resolver, then read the winning engine plugin's declared capabilities= from its manifest on disk"
IMPL_WHY="an implementer that cannot run a command cannot run a repository script or chmod a file; both are recurring operator hand-offs and both are headless deadlocks, because no other actor in the loop can perform them either"
probe_stop
if [ "$impl_resolved" = absent ]; then
  record implementer-shell "implementer declares the shell capability" fail true \
    "$IMPL_TESTED" "$IMPL_WHY" \
    "the configured implementer did not resolve to an installed engine plugin, so its capabilities are unknown; recorded as unqualified rather than assumed capable"
elif [ "$IMPLEMENTER_SHELL" = present ]; then
  record implementer-shell "implementer declares the shell capability" pass true \
    "$IMPL_TESTED" "$IMPL_WHY" \
    "the resolved implementer plugin declares the shell capability. That is a DECLARATION, not a proof that the adapter launches its vendor CLI with command execution enabled -- see the implementer-command-execution probe, which this harness cannot settle"
else
  record implementer-shell "implementer declares the shell capability" fail true \
    "$IMPL_TESTED" "$IMPL_WHY" \
    "the resolved implementer plugin declares NO shell capability, so on this profile 'run a repository script' and 'chmod a new executable' are operator hand-offs no actor in the loop can perform; any task requiring one cannot finish unattended"
fi

# ===========================================================================
# implementer-command-execution -- the no-shell implementer profile, half two,
# recorded as NOT-TESTED because it cannot honestly be recorded as anything
# else.
#
# The manifest declaration above and the grant the adapter actually makes are
# different facts, and they disagree in the shipped tree: plugins/engines/
# claude/plugin.conf lists `shell`, while that adapter's implement branch runs
# the vendor CLI with a file-edit permission mode and NO command allowlist. So
# a claude implementer edits files happily and cannot run one command. Proving
# the grant needs a live vendor round trip with real quota, which this harness
# will neither spend nor contact.
# ===========================================================================
probe_start
probe_stop
record implementer-command-execution "the adapter actually grants command execution on the implement path" not-tested false \
  "nothing was executed: settling this needs a live vendor-CLI round trip, which would spend real quota and contact a remote" \
  "a manifest capability is a declaration; the grant is whatever permission flags the adapter passes its vendor CLI, and the two disagree in the shipped tree -- the claude adapter declares shell but launches its implement path with file-edit permission and no command allowlist, so it cannot run scripts or chmod anything" \
  "not tested here. Qualify it by hand, once per profile: give the implementer one task whose acceptance genuinely requires executing a repository script or changing a file mode. If the reply asks you to run it yourself, the profile is no-shell in practice regardless of what its manifest declares, and every such task on it is an operator hand-off and a headless deadlock" \
  "engine manifests declare, per operation, whether the adapter launches its CLI with command execution enabled, and orchid doctor reports that grant rather than only the declaration"

# ===========================================================================
# verify-duration -- the slow-suite probe.
#
# A qualification suite made only of fast fixtures certifies a build that
# deadlocks on any real codebase. The deterministic driver holds no lease
# refresh across a synchronous verification, and `orchid merge` re-verifies
# after its rebase, so one pass can spend roughly twice the verify duration
# with the lease untouched. Past pump_stale_s another pump treats the run as
# abandoned. This probe measures the real command against the real timeout.
# ===========================================================================
pump_stale_s="$(config_get "$REPO" pump_stale_s 900)"
grep -Eq '^[0-9]+$' <<<"$pump_stale_s" || pump_stale_s=900
VERIFY_TESTED="executed the repository's own verify= command once, in the repository, with both output streams discarded unread; recorded only wall-clock seconds and the exit code"
VERIFY_WHY="the deterministic driver holds no lease refresh across a synchronous verification and orchid merge re-verifies after its rebase, so one pass costs about twice the verify duration with the lease untouched; past pump_stale_s another pump treats the run as abandoned and the two collide"
probe_start
if [ "$RUN_VERIFY" -eq 0 ]; then
  probe_stop
  record verify-duration "verify duration against the lease-staleness window" not-tested false \
    "nothing was executed: --no-run-verify was passed" "$VERIFY_WHY" \
    "--no-run-verify was requested, so the verify= command was not executed and its duration is unknown; this is the single most load-bearing timing fact about a candidate repository and must be measured before qualifying it"
elif [ -z "$verify_cmd" ]; then
  probe_stop
  record verify-duration "verify duration against the lease-staleness window" not-tested false \
    "nothing was executed: no verify= command is configured" "$VERIFY_WHY" \
    "no verify= command is configured (see the repo-config probe), so there was nothing to time"
else
  # IN-BAND DISCLOSURE, printed only on the path that actually executes
  # something. This is the mitigation qualification carries INSTEAD of a trust
  # step, so it fires where the exposure is and nowhere else: a notice that also
  # printed under --no-run-verify would be a warning about something that did
  # not happen, and warnings that fire when nothing happened are how an operator
  # learns to skip them. Stderr, not stdout: the two evidence paths this script
  # prints last are what a caller pipes. No path is named -- the operator passed
  # --repo and knows what it is, and _scrub_guard reaches only the two evidence
  # FILES, never this stream; tests/test_beta_qualification.sh holds that by
  # hand, so keep these two lines path-free when you edit them.
  printf 'beta-qualify: executing the configured verify= command IN PLACE inside --repo, to time it.\n' >&2
  printf 'beta-qualify: that is repository-specific code, run with your privileges; this harness does not sandbox it. --no-run-verify skips it and records the timing probe as not-tested.\n' >&2
  verify_rc=0
  # Both streams discarded: nothing the repository prints can reach a record.
  ( cd "$REPO" && with_timeout "$VERIFY_TIMEOUT_S" "$BASH_BIN" -c "$verify_cmd" >/dev/null 2>&1 ) || verify_rc=$?
  probe_stop
  verify_s="$PROBE_DUR"
  pass_cost=$(( verify_s * 2 ))
  if [ "$verify_rc" -eq 124 ]; then
    record verify-duration "verify duration against the lease-staleness window" fail true \
      "$VERIFY_TESTED" "$VERIFY_WHY" \
      "the verify command was still running at the ${VERIFY_TIMEOUT_S}s cap and was killed; a suite this long cannot be driven unattended at pump_stale_s=${pump_stale_s}s"
  elif [ "$verify_rc" -ne 0 ]; then
    record verify-duration "verify duration against the lease-staleness window" fail true \
      "$VERIFY_TESTED" \
      "verification evidence is the exit status of this exact command; if it does not already pass on a clean checkout, every task fails verification for a reason no reviewer can act on" \
      "the verify command exited $verify_rc after ${verify_s}s on the current checkout; its output was discarded by design, so re-run it yourself to see why"
  elif [ "$pass_cost" -ge "$pump_stale_s" ]; then
    record verify-duration "verify duration against the lease-staleness window" fail true \
      "$VERIFY_TESTED" "$VERIFY_WHY" \
      "verify passed but took ${verify_s}s, so one pass costs about ${pass_cost}s of unrefreshed lease against pump_stale_s=${pump_stale_s}s; raise pump_stale_s above that or shorten the suite before running this repository unattended"
  else
    record verify-duration "verify duration against the lease-staleness window" pass true \
      "$VERIFY_TESTED" "$VERIFY_WHY" \
      "verify passed in ${verify_s}s, so one pass costs about ${pass_cost}s of unrefreshed lease against pump_stale_s=${pump_stale_s}s"
  fi
fi

# ===========================================================================
# merge-rebase-regeneration -- the headless deadlock this repository met for
# real. `orchid merge` rebases the candidate onto the integration head. A
# committed candidate-local artifact derived from nearby content -- a lockfile
# or generated file -- can be invalidated by that rebase, and post-rebase
# verification then fails. Regenerating it needs an actor able to run a
# command. On a no-shell profile there is none in the loop, and the run stops
# with nobody able to move it. A whole-tree release checksum is deliberately
# excluded: T030 places it on integration at release time, never in a candidate.
# ===========================================================================
probe_start
probe_stop
MERGE_TESTED="derived from the resolved implementer plugin's declared capabilities; no merge was performed against the target repository"
MERGE_WHY="orchid merge rebases the candidate, which can invalidate a committed candidate-local generated artifact, and then re-verifies; regenerating one needs an actor able to run a command, while whole-tree release artifacts must not live on candidate branches"
if [ "$IMPLEMENTER_SHELL" = present ]; then
  record merge-rebase-regeneration "an in-loop actor can regenerate candidate-local artifacts after the merge rebase" pass true \
    "$MERGE_TESTED" "$MERGE_WHY" \
    "the resolved implementer declares the shell capability, so a rework attempt after a failed post-rebase verification can regenerate a candidate-local artifact in-loop -- subject to the implementer-command-execution probe, which this harness cannot settle"
else
  record merge-rebase-regeneration "an in-loop actor can regenerate candidate-local artifacts after the merge rebase" fail true \
    "$MERGE_TESTED" "$MERGE_WHY" \
    "the resolved implementer cannot run a command, so a candidate-local generated artifact invalidated by the merge rebase has no in-loop actor able to regenerate it; if this repository commits such an artifact, an unattended run deadlocks there and only the operator can clear it"
fi

# ===========================================================================
# stale-run-lock-visibility -- a killed merge leaves the run lock on disk.
# Probe whether any read-only command tells an operator that a lock is held and
# when it becomes breakable. Runs entirely inside this harness's own disposable
# scratch repository, so the target's lock state is never touched. NON-blocking:
# this is a property of the BUILD, not of the candidate repository, and it
# carries an explicit expiry so it cannot outlive its cause.
#
# "No lock line in the output" is evidence of a build gap ONLY if the command
# actually got as far as producing a report. On a bare scratch repository it
# might not -- and a check that could not run is not a check that failed, so
# recording one as a gap would put a defect this build may not have on a list
# an operator is meant to work through. The probe therefore establishes its own
# preconditions and records `not-tested` when one is missing, the same
# distinction the notify and command-execution probes already draw.
# ===========================================================================
probe_start
lock_probe="$SCRATCH/lock-probe"
lock_report=absent
lock_ran=0
lock_untested_why=""
mkdir -p "$lock_probe"
if run_quiet git -C "$lock_probe" init; then
  mkdir -p "$lock_probe/.orchid/runtime/lock"
  jq -n '{pid:21474836, pid_start:"stale", hostname:"orchid-qualify.invalid", epoch:0}' \
    > "$lock_probe/.orchid/runtime/lock/owner.json" 2>/dev/null
  lock_rc=0
  lock_out="$(ORCHID_REPO="$lock_probe" "$ORCHID_BIN" status --explain 2>&1)" || lock_rc=$?
  # PRECONDITION, then the question. `run_status:` is the first line of every
  # text status report, printed whether or not the repository has ever been
  # initialized, so its presence is what separates "the command reported, and
  # said nothing about the lock" from "the command never got that far". Only
  # the first of those two is a statement about this build.
  if grep -Eq '^run_status:' <<<"$lock_out"; then
    lock_ran=1
    # A closed set of phrases, never the bare substring "lock": "blocked"
    # contains it, and matching that would report a lock the operator was never
    # actually told about. Herestring, not a pipe, for the SIGPIPE reason above.
    # The captured output is discarded either way.
    if grep -Eqi 'run lock|lock held|lock_break_s' <<<"$lock_out"; then
      lock_report=present
    fi
  else
    lock_untested_why="'orchid status --explain' exited $lock_rc without printing a status report, so its silence about the lock says nothing about whether the report would have named one"
  fi
else
  lock_untested_why="a disposable scratch Git repository could not be created here, so there was nowhere to plant a lock to look for"
fi
probe_stop
LOCK_WHY="a killed merge leaves the run lock on disk; if no read-only command reports it, an operator sees a run that has simply stopped, with no indication that anything is breakable or when"
if [ "$lock_ran" -eq 0 ]; then
  record stale-run-lock-visibility "a held run lock is visible to a read-only command" not-tested false \
    "attempted to plant a dead-owner run lock in this harness's own disposable scratch repository and read a status report back from it; the attempt did not get far enough to ask the question" \
    "$LOCK_WHY" \
    "the check could not be performed on this machine: $lock_untested_why; it is recorded as untested rather than as a build gap, because an unrun check is not evidence that the behaviour is missing"
elif [ "$lock_report" = present ]; then
  record stale-run-lock-visibility "a held run lock is visible to a read-only command" pass false \
    "planted a dead-owner run lock in this harness's own disposable scratch repository and ran 'orchid status --explain' against it, which returned a status report" \
    "$LOCK_WHY" \
    "the read-only status report names the held lock, so an operator can see it without reading .orchid by hand"
else
  record stale-run-lock-visibility "a held run lock is visible to a read-only command" fail false \
    "planted a dead-owner run lock in this harness's own disposable scratch repository and ran 'orchid status --explain' against it, which returned a status report" \
    "$LOCK_WHY" \
    "the status report came back and said nothing about the planted lock: the next verb that wants it refuses with the owner pid alone, and nothing states that a dead owner becomes breakable after lock_break_s; an operator meets this as a run that stopped for no stated reason" \
    "a read-only Orchid command reports a held run lock, its owner's liveness, and the age after which it becomes breakable"
fi

# ===========================================================================
# notify-return-leg -- the asymmetry, stated instead of assumed.
#
# Outbound needs only a CLI on PATH. Inbound needs a PERSISTENT answering agent
# paired to a live channel, and an operator gets no signal when that agent is
# gone -- so a tester whose blocker question is never answered concludes the
# whole phone workflow is broken when only the return leg is. This harness will
# not contact a remote, so the round trip is recorded as not-tested. The
# outbound half is recorded as CONFIGURED or not; never as working.
# ===========================================================================
probe_start
notify_plugin="$(config_get "$REPO" notify.plugin "")"
notify_channel="$(config_get "$REPO" notify.channel "")"
notify_configured=absent
if [ -n "$notify_plugin" ] || [ -n "$notify_channel" ]; then notify_configured=present; fi
notify_binary=absent
if [ -n "$notify_plugin" ] && notify_dir="$(resolve_notify_dir "$notify_plugin" 2>/dev/null)"; then
  notify_binary=present
  while IFS= read -r requirement; do
    [ -n "$requirement" ] || continue
    command -v "$requirement" >/dev/null 2>&1 || notify_binary=absent
  done < <(_manifest_split_csv "$(manifest_get "$notify_dir" requires_binaries)")
fi
probe_stop
record notify-return-leg "blocker round trip: outbound send and inbound answer" not-tested false \
  "read notify.plugin and notify.channel from config and checked whether the named channel plugin resolves and its required binaries are on PATH; NOTHING was sent and no agent was contacted" \
  "the two legs are not symmetric: outbound needs only a CLI, while inbound needs a persistent answering agent paired to a live channel, and an operator gets no signal when that agent is gone -- a tester whose blocker question is never answered concludes the phone workflow is broken when only the return leg is" \
  "outbound configuration: $notify_configured; channel plugin and its required binaries resolvable: $notify_binary. Neither leg was exercised: a send would contact a remote, which this harness never does, and the inbound leg additionally needs a persistent answering agent this harness cannot observe. Qualify the round trip by hand: raise a real blocker, confirm the message arrives, answer it from the channel, and confirm 'orchid answer' recorded it" \
  "an operator has completed one real blocker round trip on this machine, outbound and inbound, and Orchid reports when the answering agent is absent"

# ===========================================================================
# Assemble, scrub, emit.
# ===========================================================================
DURATION_S=$(( $(now_s) - STARTED_S ))

# _scrub_guard <file> -- refuse to leave evidence naming the target, the
# operator's home, or the scratch/output paths. The structural rule at the top
# of this file (no subprocess output is ever copied into a record) is what
# actually keeps repository content out; this is the backstop that catches a
# future edit which stops being disciplined. It deliberately checks whole PATHS
# only: a bare directory NAME is often an ordinary English word, and a guard
# rejecting "repo" would be tripped by this harness's own probe ids rather than
# by a leak. The paired tests plant canary content, filenames, and path
# components and assert none of them survives into either output file.
scrub_violation=""
_scrub_guard() {
  local file="$1" needle
  for needle in "$REPO" "$OUTPUT" "$SCRATCH" "${HOME:-}" "${TMPDIR:-}"; do
    [ -n "$needle" ] || continue
    case "$needle" in /|.|..) continue ;; esac
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
      scrub_violation="$file names a forbidden absolute path"
      return 1
    fi
  done
  return 0
}

blocking_total="$(jq -s '[.[] | select(.blocking)] | length' "$PROBES")"
blocking_passed="$(jq -s '[.[] | select(.blocking) | select(.outcome == "pass")] | length' "$PROBES")"
VERDICT=not-qualified
[ "$blocking_total" = "$blocking_passed" ] && VERDICT=qualified

jq -s \
  --argjson schema "$QUALIFY_SCHEMA" \
  --arg orchid_version "$ORCHID_VERSION" \
  --arg label "$LABEL" \
  --arg started_at "$STARTED_AT" \
  --argjson duration_s "$DURATION_S" \
  --arg os "$OS_TOKEN" \
  --arg bash_version "$bash_version" \
  --arg git_version "$git_version" \
  --arg jq_version "$jq_version" \
  --arg commits "$commit_bucket" \
  --arg tracked_files "$file_bucket" \
  --arg verdict "$VERDICT" \
  '{schema:$schema, harness:"scripts/beta-qualify.sh", orchid_version:$orchid_version,
    repo:{label:$label, commits:$commits, tracked_files:$tracked_files},
    environment:{os:$os, bash:$bash_version, git:$git_version, jq:$jq_version},
    started_at:$started_at, duration_s:$duration_s,
    probes:.,
    totals:{
      total:(. | length),
      pass:([.[] | select(.outcome=="pass")] | length),
      fail:([.[] | select(.outcome=="fail")] | length),
      blocked:([.[] | select(.outcome=="blocked")] | length),
      not_tested:([.[] | select(.outcome=="not-tested")] | length),
      blocking_total:([.[] | select(.blocking)] | length),
      blocking_passed:([.[] | select(.blocking) | select(.outcome=="pass")] | length)
    },
    not_certified:[.[] | select(.outcome=="not-tested") | {id:.id, why_not:.result}],
    known_gaps:[.[] | select(.blocking|not) | select(.outcome=="fail")
                | {id:.id, gap:.result, expires_when:(.expires_when // "")}],
    verdict:$verdict,
    verdict_scope:"This verdict covers only the probes listed above, on this machine, against this build. It certifies nothing recorded as not-tested. It is not a third-party beta run and not a release: both remain operator-owned and neither was performed here.",
    operator_owned:[
      "a genuine third-party beta run, on a repository this operator does not control",
      "any publication, tag, push, or release of this build",
      "the blocker round trip end to end, including the inbound answering agent",
      "one task per implementer profile whose acceptance requires executing a repository script or changing a file mode",
      "re-pinning Formula/orchid.rb once on the integration branch at release time, immediately before the local release gate",
      "chmod +x on any newly added libexec verb"
    ]}' \
  "$PROBES" > "$JSON_OUT" || die "cannot write $JSON_OUT"

{
  printf 'orchid beta qualification\n'
  printf 'repo label:   %s\n' "$LABEL"
  printf 'harness:      scripts/beta-qualify.sh (schema %s, orchid %s)\n' "$QUALIFY_SCHEMA" "$ORCHID_VERSION"
  printf 'started:      %s (%ss)\n' "$STARTED_AT" "$DURATION_S"
  printf 'environment:  %s / bash %s / git %s / jq %s\n' \
    "$OS_TOKEN" "$bash_version" "$git_version" "$jq_version"
  printf 'repo shape:   commits %s, tracked files %s (bucketed: an exact count is a fingerprint)\n' \
    "$commit_bucket" "$file_bucket"
  printf '\nPROBES\n'
  jq -r '.probes[]
         | "  [\(.outcome)] \(.id) (\(.duration_s)s, \(if .blocking then "blocking" else "non-blocking" end))"
           + "\n      what: \(.title)"
           + "\n      tested: \(.tested)"
           + "\n      why: \(.why)"
           + "\n      result: \(.result)"
           + (if .expires_when then "\n      expires when: \(.expires_when)" else "" end)' \
    "$JSON_OUT"
  printf '\nVERDICT: %s (%s of %s blocking probes passed)\n' "$VERDICT" "$blocking_passed" "$blocking_total"
  jq -r '"  scope: " + .verdict_scope' "$JSON_OUT"
  printf '\nNOT CERTIFIED BY THIS RUN\n'
  if [ "$(jq -r '.not_certified | length' "$JSON_OUT")" = 0 ]; then
    printf '  (nothing: every probe was executed)\n'
  else
    jq -r '.not_certified[] | "  - \(.id): \(.why_not)"' "$JSON_OUT"
  fi
  printf '\nKNOWN BUILD GAPS (non-blocking; each states what makes it expire)\n'
  if [ "$(jq -r '.known_gaps | length' "$JSON_OUT")" = 0 ]; then
    printf '  (none)\n'
  else
    jq -r '.known_gaps[] | "  - \(.id): \(.gap)\n    expires when: \(.expires_when)"' "$JSON_OUT"
  fi
  printf '\nOPERATOR-OWNED, NOT PERFORMED HERE\n'
  jq -r '.operator_owned[] | "  - " + .' "$JSON_OUT"
} > "$TEXT_OUT" || die "cannot write $TEXT_OUT"

if ! _scrub_guard "$JSON_OUT" || ! _scrub_guard "$TEXT_OUT"; then
  rm -f "$JSON_OUT" "$TEXT_OUT"
  die "refusing to emit evidence: $scrub_violation (nothing was left on disk)"
fi

echo "beta qualification: $VERDICT ($blocking_passed of $blocking_total blocking probes passed)"
echo "evidence: $JSON_OUT"
echo "evidence: $TEXT_OUT"
[ "$VERDICT" = qualified ] || exit 1
exit 0
