#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# v1-m4 Task 8: docs suite lint. Three independent, purely mechanical
# checks over the published documentation set -- no repo/run state, no git --
# mirroring test_config_keys.sh's own annotation-driven
# approach (grep-only, no prose heuristics) so this suite carries zero
# false-positive risk from trying to parse free text:
#
#   1. every `orchid <word>` CODE-SPAN, and every line INSIDE A FENCED BLOCK
#      that starts with "orchid <word>", in README.md, PROTOCOL.md, and the
#      two quickstarts
#      names a real tier-1 verb (a libexec/orchid-<word> file actually on
#      disk) -- catches a renamed/typo'd verb before a reader ever hits it.
#      Both spellings are MARKED: a code span and a fence are structural
#      facts about the document, so a bare word after "orchid" in ordinary
#      prose ("at dispatch orchid creates a worktree") is never read as an
#      invocation. That reading is what failed r-002/T023 against correct
#      documentation, and section 1 below has the full account plus the
#      RED and GREEN cases that hold both halves in place. PROTOCOL.md is in
#      this set deliberately: its ordinary prose was the r-002/T023 false
#      positive, so a fix that never exercises that page does not close the
#      reported defect.
#   2. every RELATIVE markdown link across this task's docs surface
#      (`docs_suite_files` below -- README + quickstarts + configuration/
#      troubleshooting/research + docs/engines/* + docs/extending/*;
#      deliberately NOT docs/specs/*.md, docs/plans/*.md, or
#      docs/dogfood-notes.md, which pre-date this task) resolves to a file
#      that actually exists on disk (absolute http(s)/mailto links and pure
#      #anchor links are out of scope -- nothing to resolve locally). The
#      link TARGET itself may freely point outside that surface (e.g. at
#      docs/specs/kernel.md or a plugins/engines/*/run source file).
#   3. every config key referenced, anywhere in that same surface, via
#      either annotation convention this docs suite actually uses --
#      PROTOCOL.md's own "`key` (config, default ...)" shape, and
#      docs/engines/{hermes,openclaw}.md's established "`key` (default
#      ...)" shape (Task 6/7, unmodified by this task) -- is a real line in
#      lib/config-keys.txt; AND docs/configuration.md (the
#      "generated-faithful complete key table") literally contains every
#      single line in lib/config-keys.txt, backtick-wrapped, so the table
#      can never silently drift behind a key addition/removal.
#
# RED (before this task writes anything): every check below fails --
# README.md and the quickstarts don't exist yet (verb/link loops find
# nothing, but the counts below they're compared against are all
# hand-listed as "must exist" assertions), docs/configuration.md doesn't
# exist (key-coverage loop fails outright), and the annotation-scan file
# list itself doesn't resolve.

KEYFILE="$REPO_ROOT/lib/config-keys.txt"

# docs_suite_files -- the exact surface this lint's relative-link/config-key
# conventions cover: README + quickstarts + configuration/troubleshooting/
# research + every engine guide (built-in and reference-adapter alike) + the
# extending guides. Deliberately NOT docs/specs/*.md (the normative design
# specs are audited by T015 but use different prose conventions -- e.g.
# kernel.md's task-frontmatter field `blocking_severity` reads exactly like a
# config key under a naive scan but is not one), docs/plans/*.md, or
# docs/dogfood-notes.md (historical incident log, not part of the docs
# bar) -- those pre-date this task and use their own conventions.
docs_suite_files() {
  local f
  for f in "$REPO_ROOT/README.md" \
           "$REPO_ROOT/docs/quickstart.md" \
           "$REPO_ROOT/docs/quickstart-greenfield.md" \
           "$REPO_ROOT/docs/configuration.md" \
           "$REPO_ROOT/docs/troubleshooting.md" \
           "$REPO_ROOT/docs/research.md" \
           "$REPO_ROOT/docs/beta-qualification.md" \
           "$REPO_ROOT/docs/frontends.md"; do
    [ -f "$f" ] && echo "$f"
  done
  [ -d "$REPO_ROOT/docs/engines" ] && find "$REPO_ROOT/docs/engines" -name '*.md' | sort
  [ -d "$REPO_ROOT/docs/extending" ] && find "$REPO_ROOT/docs/extending" -name '*.md' | sort
  return 0
}

# ===========================================================================
# 0 -- the files this task's brief requires must exist at all. Every check
# below silently finds "nothing to lint" against a missing file (an empty
# grep is not a failure on its own) -- so without this section, deleting
# README.md entirely would make checks 1-3 all pass vacuously.
# ===========================================================================
required_files="
README.md
PROTOCOL.md
docs/quickstart.md
docs/quickstart-greenfield.md
docs/architecture.md
docs/configuration.md
docs/troubleshooting.md
docs/research.md
docs/beta-qualification.md
docs/r-002-acceptance-evidence.md
docs/frontends.md
docs/engines/codex.md
docs/engines/claude.md
docs/engines/agy.md
docs/engines/codex-review.md
docs/engines/hermes.md
docs/engines/openclaw.md
"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$REPO_ROOT/$rel" ] || fail "required doc missing: $rel"
done <<< "$required_files"

# ===========================================================================
# 1 -- every `orchid <word>` code-span in README.md, PROTOCOL.md, and the two
# quickstarts names a real tier-1 verb.
#
# THE EXTRACTOR IS ANCHORED TO HOW A VERB IS WRITTEN, NEVER TO THE BARE WORD
# AFTER "orchid", and that is r-002/T023's finding rather than a refinement.
# An earlier form of this gate took every `orchid <word>` it could see and
# demanded a matching libexec file, so the ordinary English sentence "orchid
# creates a worktree for the task" failed a task with
#
#     PROTOCOL.md names orchid creates but libexec/orchid-creates does not exist
#
# against documentation that was correct. It is the same defect as INV-13's
# purity scan reading `git worktree add` inside a printf as an operation (see
# tests/inv/test_INV-13_driver_verb_only.sh), and it has the same natural
# workaround -- reword the prose -- which degrades the documentation to
# satisfy a linter. The gate is worth keeping; reading English as a command is
# not, so a name counts only where the page has MARKED it as a command:
#
#   * inside a code span -- `orchid <word>` -- anywhere on the page; or
#   * as the first word of a line INSIDE A FENCED BLOCK, which is how these
#     four pages spell a command an operator types.
#
# The fenced-block half is what closes the prose hole. The check used to take
# any line merely STARTING with "orchid ", so a paragraph that happened to
# begin with a lowercase "orchid handles ..." was read as an invocation, and
# the only thing standing between that and a red suite was a comment asking
# future authors not to write one. A fence is a structural fact about the
# document, so nothing about the sentence has to be promised.
# ===========================================================================

# doc_verb_names <file> -- the verb names <file> documents as invocations, one
# per line, in both marked spellings. Named once so the loop below and the
# RED/GREEN probes beside it are judged by the SAME extractor: a probe aimed
# at a private copy of the pattern proves that copy works and says nothing
# about the gate.
doc_verb_names() {
  awk '
    /^[[:space:]]*```/ { infence = 1 - infence; next }
    {
      line = $0
      if (infence && match(line, /^orchid [a-zA-Z][a-zA-Z-]*/))
        print substr(line, 8, RLENGTH - 7)
      while (match(line, /`orchid [a-zA-Z][a-zA-Z-]*/)) {
        print substr(line, RSTART + 8, RLENGTH - 8)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

verb_check_files="README.md PROTOCOL.md docs/quickstart.md docs/quickstart-greenfield.md"
verb_words=""
for rel in $verb_check_files; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  # An UNCLOSED fence inverts "inside a fence" for the whole rest of the page,
  # which would either read every later paragraph as commands or stop reading
  # every later command block -- silently, and in a file nobody would think to
  # re-lint. The anchor is only worth what its delimiters are worth, so the
  # delimiters are counted.
  fences="$(grep -cE '^[[:space:]]*```' "$f" || true)"
  [ $((fences % 2)) -eq 0 ] \
    || fail "$rel has an odd number of code-fence delimiters ($fences) -- the verb extractor below decides what is a command by whether it sits inside a fence, and an unclosed one flips that decision for every line after it"
  words="$(doc_verb_names "$f" || true)"
  verb_words="$verb_words
$words"
done
verb_count=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  verb_count=$((verb_count + 1))
  [ -x "$REPO_ROOT/libexec/orchid-$v" ] || fail "a documented invocation names 'orchid $v' but libexec/orchid-$v doesn't exist (or isn't executable)"
done < <(printf '%s\n' "$verb_words" | sort -u)
[ "$verb_count" -gt 0 ] || fail "verb-name extraction from README/PROTOCOL/quickstarts found nothing -- files missing, or the extractor broke"

# RED: a page that documents an invocation of a verb this repository does not
#      have must still be CAUGHT. Both marked spellings are fed in, because
#      anchoring the gate is exactly the change that could have narrowed it
#      into uselessness, and a gate that finds nothing passes silently.
# GREEN: the same extractor, fed the English that failed r-002/T023 -- the
#      word after "orchid" in ordinary prose, both mid-sentence and opening a
#      line outside any fence -- must yield NOTHING. Without this the RED case
#      above is satisfied by a matcher that fires on every mention of the
#      word, which is the gate that cost the attempt.
verb_probe_red="$WORK/docs-verb-probe-red.md"
printf '%s\n' \
  'Run `orchid frobnicate --now` to do the thing.' \
  '' \
  '```sh' \
  'orchid quuxify --all' \
  '```' \
  > "$verb_probe_red"
verb_probe_red_out="$(doc_verb_names "$verb_probe_red")"
assert_match 'frobnicate' "$verb_probe_red_out" \
  "docs verb gate: a code span naming a nonexistent verb must be extracted -- anchoring the extractor to marked commands has narrowed it past the failure it exists to catch"
assert_match 'quuxify' "$verb_probe_red_out" \
  "docs verb gate: a fenced command line naming a nonexistent verb must be extracted -- the fenced half of the extractor is not reading fences"
red_case "the documentation verb gate extracted 'frobnicate' from a code span and 'quuxify' from a fenced command line, neither of which has a libexec verb, so it still catches an undocumented or renamed verb"

verb_probe_green="$WORK/docs-verb-probe-green.md"
printf '%s\n' \
  'At dispatch orchid creates a worktree and records its base sha.' \
  'orchid handles the rest of the walk without an operator.' \
  'A sentence may also say orchid merge in passing without meaning the verb.' \
  > "$verb_probe_green"
verb_probe_green_out="$(doc_verb_names "$verb_probe_green")"
[ -z "$verb_probe_green_out" ] \
  || fail "docs verb gate: ordinary prose was read as a verb invocation (extracted: $verb_probe_green_out) -- this is the shape that failed r-002/T023 with 'PROTOCOL.md names orchid creates but libexec/orchid-creates does not exist' against correct documentation"
green_case "the same extractor read three prose sentences naming orchid -- mid-sentence, opening a line, and one naming a real verb in passing -- and extracted nothing, so the gate reads marked commands rather than English"

# ===========================================================================
# 2 -- every relative markdown link across this task's docs surface
# resolves to a real file (which may legitimately live outside that surface
# -- e.g. a link to docs/specs/kernel.md or plugins/engines/codex/run).
# Absolute http(s)/mailto links and pure #anchor links are skipped --
# nothing local to resolve.
# ===========================================================================
link_count=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  dir="$(dirname "$f")"
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in
      http://*|https://*|mailto:*) continue ;;
      '#'*) continue ;;
    esac
    target="${link%%#*}"
    [ -n "$target" ] || continue
    link_count=$((link_count + 1))
    [ -e "$dir/$target" ] || fail "$f: relative link target does not exist: $link (resolved: $dir/$target)"
  done < <(grep -oE '\]\([^) ]+\)' "$f" | sed -E 's/^\]\(//; s/\)$//')
done < <(docs_suite_files)
[ "$link_count" -gt 0 ] || fail "relative-link extraction across README/docs found nothing -- files missing, or the regex broke"

# ===========================================================================
# 3a -- every config key referenced via either annotation shape this docs
# suite uses is a real line in lib/config-keys.txt.
# ===========================================================================
[ -f "$KEYFILE" ] || fail "lib/config-keys.txt missing"
key_known() { grep -qxF "$1" "$KEYFILE"; }

annot_count=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    annot_count=$((annot_count + 1))
    key_known "$key" || fail "$f: documents config key '$key' but lib/config-keys.txt has no such line"
  done < <(
    {
      grep -oE '`[a-zA-Z_][a-zA-Z_.<>-]*`[[:space:]]*\(config, default' "$f" | sed -E 's/`([a-zA-Z_.<>-]+)`.*/\1/'
      grep -oE '`[a-zA-Z_][a-zA-Z_.<>-]*`[[:space:]]*\(default' "$f" | sed -E 's/`([a-zA-Z_.<>-]+)`.*/\1/'
    } | sort -u
  )
done < <(docs_suite_files)
[ "$annot_count" -gt 0 ] || fail "config-key annotation scan across README/docs found nothing -- files missing, or the annotation convention changed"

# ===========================================================================
# 3b -- docs/configuration.md (the "generated-faithful complete key table")
# literally contains every single line in lib/config-keys.txt,
# backtick-wrapped -- the completeness direction test_config_keys.sh
# doesn't cover (that suite checks orchid.config.example/PROTOCOL.md, never
# docs/configuration.md, and never asserts completeness, only that
# mentioned keys are real).
# ===========================================================================
CONFIGURATION_MD="$REPO_ROOT/docs/configuration.md"
if [ -f "$CONFIGURATION_MD" ]; then
  cov_count=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    cov_count=$((cov_count + 1))
    grep -qF "\`$key\`" "$CONFIGURATION_MD" || fail "docs/configuration.md is missing key-reference row for '$key' (lib/config-keys.txt)"
  done < "$KEYFILE"
  [ "$cov_count" -gt 0 ] || fail "lib/config-keys.txt appears empty -- nothing to check completeness against"
else
  fail "docs/configuration.md missing -- cannot check key-table completeness"
fi

# ===========================================================================
# 4 -- mermaid-fence lint over README.md + docs/*.md (top level; docs/specs
# and docs/plans keep their own conventions, same scoping rationale as
# check 2's docs_suite_files): every ```mermaid fence is balanced (a
# closing ``` before EOF), never nested, and its first non-blank line
# opens with one of the three diagram types this repo permits --
# flowchart / stateDiagram-v2 / sequenceDiagram -- the boring, universally
# GitHub-rendered subset. A cheap grep/awk-level parse guard: it cannot
# prove a diagram renders, but it catches the common breakages (unclosed
# fence, a typo'd or exotic diagram type) with no node/mermaid-cli
# dependency.
# ===========================================================================
mermaid_total=0
for f in "$REPO_ROOT/README.md" "$REPO_ROOT"/docs/*.md; do
  [ -f "$f" ] || continue
  out="$(awk '
    BEGIN { open = 0; count = 0 }
    /^[[:space:]]*```mermaid[[:space:]]*$/ {
      if (open) { print "ERR nested mermaid fence at line " NR; open = 0 }
      open = 1; first = 1; count++; next
    }
    open && /^[[:space:]]*```/ { open = 0; next }
    open && first && NF > 0 {
      t = $1
      if (t != "flowchart" && t != "stateDiagram-v2" && t != "sequenceDiagram")
        print "ERR unsupported diagram type \"" t "\" at line " NR
      first = 0
    }
    END {
      if (open) print "ERR unclosed mermaid fence"
      print "COUNT " count
    }
  ' "$f")"
  while IFS= read -r line; do
    case "$line" in
      ERR*)    fail "$f: ${line#ERR }" ;;
      COUNT*)  mermaid_total=$((mermaid_total + ${line#COUNT })) ;;
    esac
  done <<< "$out"
done
[ "$mermaid_total" -gt 0 ] || fail "mermaid-fence scan over README.md + docs/*.md found no fences -- README's architecture diagrams are gone, or the scan broke"

# ===========================================================================
# 5 -- pinned-install and release-day instructions remain executable and
# honest. An immutable installer URL always reselects its named release; it
# cannot be an upgrade command. Each release command that consumes the
# documented tag must derive version/tag from release metadata and cross-check
# them in that same shell block before use, so copying either block into a
# fresh shell never relies on an undefined variable.
# ===========================================================================
QUICKSTART_MD="$REPO_ROOT/docs/quickstart.md"
quickstart_text="$(tr '\n' ' ' < "$QUICKSTART_MD" | tr -s '[:space:]' ' ')"
grep -qF \
  'The URL is immutable: running this exact line later reselects `v1.0.0-beta.1`; it does not upgrade Orchid. To upgrade, select the install URL for a newer immutable released tag.' \
  <<<"$quickstart_text" \
  || fail "docs/quickstart.md must explain that upgrading requires a newer immutable released tag"
grep -qF \
  'Running this exact line again later is the upgrade command too.' \
  <<<"$quickstart_text" \
  && fail "docs/quickstart.md falsely calls the immutable v1.0.0-beta.1 URL an upgrade command"

INSTALL_MD="$REPO_ROOT/docs/install.md"
release_command_audit="$(awk '
  /^### Release-day steps \(operator, not automated\)$/ {
    in_release_steps = 1
    next
  }
  in_release_steps && /^## / { in_release_steps = 0 }
  !in_release_steps { next }

  /^[[:space:]]*```sh[[:space:]]*$/ {
    in_shell = 1
    version_from_metadata = 0
    tag_from_metadata = 0
    metadata_cross_checked = 0
    next
  }
  in_shell && /^[[:space:]]*```[[:space:]]*$/ {
    in_shell = 0
    next
  }
  !in_shell { next }

  index($0, "version=\"$(") && index($0, "release/metadata.conf") {
    version_from_metadata = 1
  }
  index($0, "tag=\"$(") && index($0, "release/metadata.conf") {
    tag_from_metadata = 1
  }
  index($0, "[ \"$tag\" != \"v$version\" ]") {
    metadata_cross_checked = 1
  }
  index($0, "git tag \"$tag\"") {
    tag_commands++
    if (!version_from_metadata || !tag_from_metadata || !metadata_cross_checked)
      print "ERR git tag command lacks prior metadata derivation/cross-check at line " NR
  }
  index($0, "scripts/release.sh --tag \"$tag\"") {
    release_commands++
    if (!version_from_metadata || !tag_from_metadata || !metadata_cross_checked)
      print "ERR release command lacks prior metadata derivation/cross-check at line " NR
  }
  END {
    print "TAG_COUNT " tag_commands + 0
    print "RELEASE_COUNT " release_commands + 0
  }
' "$INSTALL_MD")"
release_tag_commands=0
release_gate_commands=0
while IFS= read -r line; do
  case "$line" in
    ERR*)           fail "docs/install.md: ${line#ERR }" ;;
    TAG_COUNT*)     release_tag_commands="${line#TAG_COUNT }" ;;
    RELEASE_COUNT*) release_gate_commands="${line#RELEASE_COUNT }" ;;
  esac
done <<< "$release_command_audit"
assert_eq 1 "$release_tag_commands" \
  "docs/install.md must contain one metadata-bound release-day git tag command"
assert_eq 1 "$release_gate_commands" \
  "docs/install.md must contain one metadata-bound release-day release-gate command"

# ===========================================================================
# 6 -- README's compact guardrails summary must preserve the threat model's
# trust-boundary distinction. Orchid can omit external-mutation verbs from
# its own action surface, but prompt policy is not enforcement over an
# engine process: without brokerage/containment, host capabilities remain.
# Keep this scoped to the Guardrails paragraph so an accurate FAQ elsewhere
# cannot mask a new overclaim in the summary operators are most likely to
# rely on.
# ===========================================================================
guardrails="$(
  awk '
    /^\*\*Guardrails:\*\*/ { capture = 1 }
    capture { print }
    capture && /^$/ { exit }
  ' "$REPO_ROOT/README.md"
)"
[ -n "$guardrails" ] || fail "README.md: Guardrails paragraph missing"
guardrails_one_line="$(printf '%s' "$guardrails" | tr '\n' ' ')"
assert_match "deterministic verbs provide no push,.*deploy, or publish operation" \
  "$guardrails_one_line" \
  "README guardrails must limit Orchid's enforced boundary to its own action surface"
assert_match "blocker instruction is prompt policy" "$guardrails_one_line" \
  "README guardrails must identify the blocker instruction as prompt policy"
assert_match "no command broker.*or OS containment" "$guardrails_one_line" \
  "README guardrails must disclose missing brokerage and OS containment"
assert_match "engine process with external credentials, network access, or.*host capabilities could invoke another executable" \
  "$guardrails_one_line" \
  "README guardrails must disclose residual engine-process capabilities"
# v1.1: the orchestrator seat IS narrowed now, and the summary must say so --
# under-claiming an implemented guardrail is as much a documentation defect as
# over-claiming an absent one. Both halves are required: the narrowing, and
# the limit of that narrowing.
assert_match "command_surface=brokered" "$guardrails_one_line" \
  "README guardrails must name the brokered orchestrator command surface"
assert_match "still not OS containment" "$guardrails_one_line" \
  "README guardrails must state the limit of the brokered surface"
# Track 1 honesty, the other direction: `brokered` restricts COMMANDS. The
# adapter runs under acceptEdits, which leaves the vendor's file-write tools
# open over every reachable path -- `.orchid/` and, in a dogfood layout, the
# broker script itself. Describing a prompt-level constraint as structural
# enforcement is exactly what this section exists to catch.
assert_match "COMMANDS only" "$guardrails_one_line" \
  "README guardrails must scope the brokered allowlist to commands"
assert_match "acceptEdits" "$guardrails_one_line" \
  "README guardrails must name the permission mode that leaves file writes open"
assert_match "prompt policy" "$guardrails_one_line" \
  "README guardrails must label 'never hand-edit .orchid/' as prompt policy, not enforcement"

# The same honesty, at the source of truth for the adapter and for the label.
claude_doc_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/engines/claude.md" | tr -s '[:space:]' ' ')"
assert_match "does not cover: file writes" "$claude_doc_one_line" \
  "docs/engines/claude.md must state what the brokered surface does NOT cover"
assert_match "acceptEdits.*leaves the vendor's own file-write tools auto-approved" \
  "$claude_doc_one_line" \
  "docs/engines/claude.md must say precisely why file writes stay open"

plugins_spec_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/specs/plugins.md" | tr -s '[:space:]' ' ')"
assert_match "says nothing about FILE WRITES" "$plugins_spec_one_line" \
  "the command_surface spec must bound its own claim to command execution"

# Lesson L006: the driver's findings[]-severity gate is only as live as the
# reviewer adapter feeding it -- it stays inert for a reviewer whose adapter
# never populates findings[]. Wherever the deterministic approval path is
# documented, that has to be said, or the gate reads as a protection nobody
# is getting. v1-m4 T006 split the shipped adapters into two camps, so the
# docs claim is now per-adapter and this check is too.
protocol_one_line="$(tr '\n' ' ' < "$REPO_ROOT/PROTOCOL.md" | tr -s '[:space:]' ' ')"
assert_match "the \`blocking_severity\` gate is \*\*inert\*\*" "$protocol_one_line" \
  "PROTOCOL.md's approval arm must say the severity gate is inert for verdict-only review adapters"
assert_match "plugins/engines/claude/run" "$protocol_one_line" \
  "PROTOCOL.md's approval arm must name which shipped adapters do and do not populate findings[]"
# claude (v1-m4 T006): its `review` prompt asks for FINDING: lines and its
# parser is NOT gated to critique, so findings[] is genuinely populated for
# reviews. If either half regresses, PROTOCOL.md's per-adapter note is wrong.
grep -q "findings" "$REPO_ROOT/plugins/engines/claude/run" \
  || fail "plugins/engines/claude/run: findings[] handling vanished — re-check the L006 claim in the docs"
# Twice, deliberately: once in the review prompt, once in the critique
# prompt. A single occurrence means one of the two branches dropped it, and
# a `grep -q` would not notice which.
[ "$(grep -c "One line per issue found, exactly: FINDING:" "$REPO_ROOT/plugins/engines/claude/run")" -ge 2 ] \
  || fail "plugins/engines/claude/run: both the review and critique prompts must ask for FINDING: lines — PROTOCOL.md now over-claims for this adapter"
grep -q 'if \[ "\$operation" = critique \]' "$REPO_ROOT/plugins/engines/claude/run" \
  && fail "plugins/engines/claude/run scrapes FINDING: lines for critique only again — review findings would be silently dropped"
# codex: still verdict-only on `review` (FINDING: lines requested by the
# critique prompt alone), which is exactly what PROTOCOL.md's inert-gate
# sentence must keep covering.
grep -q "findings" "$REPO_ROOT/plugins/engines/codex/run" \
  || fail "plugins/engines/codex/run: findings[] handling vanished — re-check the L006 claim in the docs"
grep -q 'if \[ "\$operation" = critique \]' "$REPO_ROOT/plugins/engines/codex/run" \
  || fail "plugins/engines/codex/run no longer scrapes FINDING: lines for critique only — PROTOCOL.md's L006 note is now wrong"

# The OTHER half of a live gate, and the one that will actually surprise an
# operator: now that a claude review populates findings[], a NON-empty one
# blocks an otherwise-approving review (blocking_severity defaults to
# medium). Every doc sentence stressing that an EMPTY array blocks nothing is
# only half the contract; the halting half has to be written down too, or the
# first approve-with-one-medium-nit review reads as a broken driver.
assert_match "blocks an otherwise-approving review" "$protocol_one_line" \
  "PROTOCOL.md must state that a non-empty findings[] halts an approving review, not just that an empty one blocks nothing"

# T039 (lesson L027): the reviewer-slot table is pinned per attempt -- and the
# DRIVER is not the only thing that dispatches slots. PROTOCOL's risk-tiered
# review policy is the procedure a model-driven orchestrator follows, and it
# launches each printed slot itself, so a pin described as something only the
# deterministic driver takes leaves that path recomputing a live table between
# one dispatch and the next: exactly the r-002 dead end, reached by the one
# route the fix did not cover. Both halves are asserted on the FOLDED text
# (these sentences straddle hard wraps): the dispatch instruction itself must
# carry `--pin`, and it must say the pin comes BEFORE the first launch -- a
# table pinned after slot 1 went out has already had its chance to move.
assert_match 'review-plan <id> --pin` FIRST' "$protocol_one_line" \
  "PROTOCOL.md's risk-tiered review policy must tell whoever dispatches the slots to PIN the table, not merely to read it"
assert_match "Pin BEFORE launching the first slot" "$protocol_one_line" \
  "...and must say the pin precedes the first launch, since a plan pinned afterwards could already have moved between the two dispatches"
# The main TICK repeats the concrete reviewing procedure much later than the
# Preamble. Assert that block on its own: a correct Preamble cannot rescue a
# later copy-and-paste command that reads the live plan immediately before it
# tells the operator to launch every returned slot.
protocol_reviewing="$(sed -n '/^- \*\*reviewing\*\*/,/^- \*\*arbitrating\*\*/p' "$REPO_ROOT/PROTOCOL.md" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
assert_match 'review-plan <id> --pin' "$protocol_reviewing" \
  "PROTOCOL.md's concrete reviewing arm must pin the plan it immediately dispatches, not contradict the Preamble with a bare read"

kernel_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/specs/kernel.md" | tr -s '[:space:]' ' ')"
assert_match "one \`medium\` finding turns an all-\`approve\`" "$kernel_one_line" \
  "docs/specs/kernel.md must state the same halting half of the severity gate"
# And the prompt has to define severity by CONSEQUENCE, or a reviewer files
# nits as `medium` and stops runs nobody meant to stop.
assert_match "Use low for anything you would call a nit" \
  "$(tr '\n' ' ' < "$REPO_ROOT/plugins/engines/claude/run" | tr -s '[:space:]' ' ')" \
  "the review prompt must give severity explicit blocking semantics, not just a line format"
# ...and it must name THIS task's threshold. The shipped archetypes disagree
# (templates/task.md and task-test.md ship `high`; task-migrate and
# task-refactor ship `medium`), so any hardcoded default in the prompt is
# wrong for some of them -- on the very gate this milestone made live.
# Squeezed to one line first: the offending text was WRAPPED in the source
# ("blocking_severity (medium by\ndefault)"), so a line-oriented grep for it
# would never have fired -- a guard that cannot fail is not a guard.
claude_run_one_line="$(tr '\n' ' ' < "$REPO_ROOT/plugins/engines/claude/run" | tr -s '[:space:]' ' ')"
grep -qF 'blocking_severity (medium by default)' <<<"$claude_run_one_line" \
  && fail "plugins/engines/claude/run hardcodes a blocking_severity default in the review prompt — the shipped templates do not agree on one"
grep -qF 'fm_get "$input_pack/task.md" blocking_severity' <<<"$claude_run_one_line" \
  || fail "plugins/engines/claude/run no longer reads the task's own blocking_severity — docs/engines/claude.md's per-task-threshold claim is now wrong"
# The doc's claim is concrete and checkable: it names templates/task.md and
# task-test.md as `high` and task-migrate/task-refactor as `medium`. Check
# each against the template it describes, so re-pinning a template's severity
# without touching the doc fails here instead of silently making it a lie.
# `claude_doc_one_line` is already built above, from the same file.
for bsev_pair in task:high task-test:high task-migrate:medium task-refactor:medium; do
  bsev_tmpl="${bsev_pair%%:*}"; bsev_want="${bsev_pair#*:}"
  bsev_val="$(grep -m1 '^blocking_severity:' "$REPO_ROOT/templates/$bsev_tmpl.md" 2>/dev/null | sed 's/^blocking_severity:[[:space:]]*//')"
  assert_eq "$bsev_want" "$bsev_val" \
    "templates/$bsev_tmpl.md's blocking_severity changed — docs/engines/claude.md still describes it as $bsev_want"
  assert_match "templates/$bsev_tmpl\\.md" "$claude_doc_one_line" \
    "docs/engines/claude.md must name templates/$bsev_tmpl.md when explaining why no default is hardcoded"
done
assert_match "ship \`high\`" "$claude_doc_one_line" \
  "docs/engines/claude.md must state the high-threshold archetypes' actual value"
assert_match "ship \`medium\`" "$claude_doc_one_line" \
  "docs/engines/claude.md must state the medium-threshold archetypes' actual value"

# USAGE TEXT IS DOCUMENTATION TOO, and it is the copy an operator reads at
# the moment it matters. Every prose site above was updated when one shipped
# review adapter started filling findings[]; `orchid drive --help` was not,
# and nothing here noticed, so for a full milestone the runner told operators
# the severity clause "is inert for a reviewer whose adapter never fills
# findings[] -- the shipped review adapters ask for a VERDICT line only". A
# stale help string that denies the existence of a gate which WILL halt a run
# is worse than no help at all. `--help` is parsed before any repo lookup, so
# this spawns nothing beyond one process and needs no fixture.
drive_help="$("$ORCHID_BIN" drive --help)" \
  || fail "orchid drive --help must exit 0 without a repo"
drive_help_one_line="$(printf '%s' "$drive_help" | tr -s '[:space:]' ' ')"
# Asserted by CAPABILITY, not by naming a plugin: INV-13 forbids the driver
# from referencing a plugin path at all and INV-14 from branching on an engine
# identifier, so an assertion demanding the literal `plugins/engines/claude/run`
# in this file's own help text would put two of this suite's tests in direct
# contradiction -- and it did, until this line was rewritten. What actually
# matters to an operator is that the help distinguishes an adapter that REQUESTS
# AND PARSES findings from one that does not, so the live gate is discoverable
# for whatever adapter they have bound.
#
# Plain-substring shapes only, carrying no ERE metacharacters at all.
# `assert_match` is `grep -E`, and the help's `<low|medium|high>` token is an
# ALTERNATION there unless every `|` in it is backslash-escaped. Escaping is
# one keystroke from silently useless: drop a single backslash and the
# pattern becomes `FINDING: <low` OR `medium` OR `high>: <title>`, whose
# middle arm this same help text satisfies independently where it explains
# that `medium` is only the fallback threshold -- so the assertion would keep
# passing with the FINDING line shape deleted outright, which is the one
# regression it exists to catch.
# Nothing here should hinge on a backslash nobody re-reads.
# tests/test_engine_claude.sh documents the same hazard and takes the same
# way out: assert the metacharacter-free prefix instead.
assert_match "adapter that asks a review for \`FINDING:" "$drive_help_one_line" \
  "orchid drive --help must state which adapter shape makes the severity clause live"
assert_match "parses them makes the clause LIVE" "$drive_help_one_line" \
  "orchid drive --help must say the clause is live for such an adapter, not describe every reviewer as verdict-only"
assert_match "empty findings\[\] blocks nothing" "$drive_help_one_line" \
  "orchid drive --help must keep the other half: an empty findings[] is a valid review, not a missing one"
grep -q "the shipped review adapters ask for a VERDICT line only" <<<"$drive_help_one_line" \
  && fail "orchid drive --help still calls every shipped review adapter verdict-only — one shipped review adapter has not been since v1-m4 T006"
# ...and it must not over-correct into the opposite false claim, which is
# where it landed next: for one round this help asserted the shipped DEFAULT
# reviewer parses FINDING lines. lib/resolver.sh's `reviewer` default resolves
# to an adapter that writes no findings key at all, so that read as a promise
# of a gate most operators are not getting. INV-13/INV-14 want this drawn by
# CAPABILITY anyway — the help states what each adapter SHAPE does and claims
# nothing about which one is bound.
grep -qi "default reviewer" <<<"$drive_help_one_line" \
  && fail "orchid drive --help asserts what the DEFAULT reviewer's adapter does — lib/resolver.sh's reviewer default populates no findings[], and the help is supposed to distinguish adapters by capability, not by which is default"
# The other thing an operator reads at the moment it matters: what exit 16
# actually means. "The judgment-boundary exit code" invites the halting
# reading — stop the run, fetch a human — and a caller that takes it halts
# every task over a decision affecting one (a live run lost seven hours and
# twenty-eight idle tasks to exactly that). The help must say which of the two
# it is. Plain substrings again, no ERE metacharacters.
assert_match "A DECISION IS OUTSTANDING SOMEWHERE" "$drive_help_one_line" \
  "orchid drive --help must say exit 16 reports an outstanding decision, not a run that cannot proceed"
assert_match "walked EVERY task" "$drive_help_one_line" \
  "...and that the pass which returns it still advanced every other task"

# T015 owns the cross-cutting help audit. These four behaviors are easy to
# document only in PROTOCOL.md while leaving the operator's first-line help on
# the old state machine, which is how r-001 shipped a stale gate description.
# Fixed strings avoid turning the punctuation in the usage prose into regex.
grep -qF 'An `ok` implementer envelope is not itself a candidate.' <<<"$drive_help" \
  || fail "orchid drive --help must say an ok envelope with no candidate is refused rather than advanced"
grep -qF '`orchid verify` exit 20 is REFUSED, not FAIL' <<<"$drive_help" \
  || fail "orchid drive --help must distinguish verify tree-drift refusal from a charged candidate failure"
grep -qF 'An approval is also never deterministic while the task carries an unresolved objection from an earlier arbitration.' <<<"$drive_help_one_line" \
  || fail "orchid drive --help must say a later review round cannot erase an unresolved objection"
grep -qF 'Completing the run does not remove an installed schedule' <<<"$drive_help" \
  || fail "orchid drive --help must keep the run-complete/service-lifetime boundary visible"

ci_help="$("$BASH" "$REPO_ROOT/scripts/ci-local.sh" --help)" \
  || fail "scripts/ci-local.sh --help must exit 0"
ci_help_one_line="$(printf '%s' "$ci_help" | tr -s '[:space:]' ' ')"
grep -qF 'local equivalent of the hosted CI command' <<<"$ci_help" \
  || fail "scripts/ci-local.sh --help must identify the command whose local result corresponds to hosted CI"
grep -qF 'hermetic suite proof that vendor CLIs are not required on PATH' <<<"$ci_help_one_line" \
  || fail "scripts/ci-local.sh --help must name the hermetic proof included in a full local run"
grep -qF 'does not claim the merged integration' <<<"$ci_help" \
  || fail "scripts/ci-local.sh --help must not let a candidate-local run imply the integration-branch row passed"

# ...and the same claim must not survive in any other shipped usage text.
stale_help="$(grep -rln "adapter never fills findings" "$REPO_ROOT/runners" "$REPO_ROOT/libexec" "$REPO_ROOT/bin" 2>/dev/null || true)"
[ -z "$stale_help" ] || fail "stale L006 severity-gate claim still shipped in: $stale_help"

# T033 (dogfood F32): the severity-gate claim moved again, and this help is
# the site that was left behind LAST time it moved -- the block above exists
# because of exactly that. `orchid jobs reconcile` now composes a finding from
# a non-approve review's free-text summary, so "an empty findings[] blocks
# nothing" is true only of an APPROVING review. Unqualified, it tells an
# operator who then sees a `high` entry in a filed envelope that the reviewer
# put it there. Both halves are pinned so neither can drift on its own: the
# assertion above keeps the approving half, these keep the scope and the
# marker that distinguishes a kernel-composed entry from a reviewer's own.
assert_match "approving review an empty findings\[\] blocks nothing" "$drive_help_one_line" \
  "orchid drive --help must scope its empty-findings claim to an APPROVING review — reconcile synthesizes a finding for one that withholds approval"
assert_match "synthesized-finding:" "$drive_help_one_line" \
  "orchid drive --help must name the line reconcile prints when it composes a finding from a non-approve review's summary"
assert_match "synthesized: true" "$drive_help_one_line" \
  "orchid drive --help must say a synthesized entry is marked, so it is never read as the reviewer's own severity call"
# ...and the marker is a plugin CONTRACT too: an adapter author reading only
# the spec has to be able to tell a kernel-composed finding from their own.
assert_match "synthesized: true" "$plugins_spec_one_line" \
  "docs/specs/plugins.md must document the synthesized finding's marker as part of the envelope contract"
# The third arm of the same complaint, and the one the two above cannot reach:
# an APPROVING review is where an empty findings[] is both routine and
# invisible, so the approval line itself has to say how much the severity gate
# had to weigh. The help is where an operator learns to read that clause; if it
# goes unmentioned here, the sentence in lib/drive.sh reads as an alarm rather
# than the disclosure it is.
assert_match "weighed an empty array" "$drive_help_one_line" \
  "orchid drive --help must explain that a deterministic approval says when the severity gate weighed nothing, so the clause is not read as a failure"
assert_match "weighed against it" "$drive_help_one_line" \
  "…and must give the other half of that clause, the count of findings a clean approval did weigh"

# THE SAME CLAIM IS WRITTEN DOWN IN FIVE PLACES (PROTOCOL.md, architecture.md,
# docs/engines/claude.md, lib/drive.sh, the driver's own help), so qualifying
# it in one place is how it went stale the last two times (the L006 sweep above
# is the scar). "An
# empty findings[] blocks nothing" is now true only of an APPROVING review, so
# every live surface that states it must carry that word within the same
# sentence -- and a NEW site written a year from now must not be able to state
# the old, unqualified version. This is the sweep, not another per-file pin: it
# reads whatever files carry the phrase rather than a list someone has to
# remember to extend. Folded first, and folded at BOTH ends of the sweep:
# every one of these sentences straddles a hard wrap, so a line-oriented step
# anywhere in the path silently drops the files the sweep exists for.
# docs/architecture.md is the live proof -- it writes the claim as "blocks\n
# nothing", so `grep -rl "blocks nothing"` does not list it at all, and a
# discovery step built that way would hand the matcher four of the five files
# and call the repo clean. Discovery therefore ENUMERATES the surface and folds
# each file, rather than pre-filtering it with a line-oriented grep.
# docs/plans/ and docs/dogfood-notes.md are excluded by construction: they are
# dated records of what was true when written, and rewriting them would falsify
# the history the rest of this suite cites.
#
# unqualified_blocks_nothing <file> -- prints " <file>" once per occurrence of
# the claim that does NOT carry its qualifier within the 120 folded characters
# before it. Silent when the file is clean AND when it carries no claim at all,
# which is what lets sweep_unqualified_claims below hand it the whole surface
# instead of a pre-filtered shortlist.
unqualified_blocks_nothing() {
  local cf="$1"
  local cf_one_line hit out
  # Silenced because the sweep now hands this every regular file on the
  # surface, not a grep-filtered shortlist: an unreadable file is simply a file
  # that carries no claim, and its complaint would otherwise land in the run's
  # stderr and read there as a failed assertion. `2>/dev/null` comes BEFORE the
  # input redirect on purpose -- redirections are applied left to right, so the
  # other order leaves fd 2 still pointing at the terminal when `< "$cf"` is the
  # thing that fails.
  cf_one_line="$(tr '\n' ' ' 2>/dev/null < "$cf" | tr -s '[:space:]' ' ')"
  out=""
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    # Lowercased once rather than matched in two cases: these sentences shout
    # the qualifier in the code comments (APPROVING) and whisper it in the
    # prose (approving), and a third spelling must not read as a missing one.
    case "$(printf '%s' "$hit" | tr '[:upper:]' '[:lower:]')" in
      *approving*) ;;
      *) out="$out $cf" ;;
    esac
  done < <(printf '%s\n' "$cf_one_line" | grep -o '.\{0,120\}blocks nothing' || true)
  printf '%s' "$out"
}

# sweep_claim_sites <path>... -- DISCOVERY, and the half the finding was about.
# Walks every regular file under the given paths, folds each one, and emits the
# ones that carry the claim at all (qualified or not). Folding here rather than
# pre-filtering with `grep -rl` is the whole point: a wrapped occurrence is
# invisible to any line-oriented step, so the enumeration costs one read per
# file on the surface and buys back the files that step drops. NUL-delimited at
# both ends because a path may legally contain a newline, and a `find`-to-`read`
# handoff on newlines would split one such path into two that do not exist.
sweep_claim_sites() {
  local sweep_file sweep_folded
  while IFS= read -r -d '' sweep_file; do
    # Silenced, and ordered, for the same reason unqualified_blocks_nothing is:
    # the walk reaches every regular file, and an unreadable one is a file
    # carrying no claim, not a failure to report.
    sweep_folded="$(tr '\n' ' ' 2>/dev/null < "$sweep_file" | tr -s '[:space:]' ' ')"
    case "$sweep_folded" in
      *"blocks nothing"*) printf '%s\0' "$sweep_file" ;;
    esac
  done < <(find "$@" -type f -print0 2>/dev/null)
}

# sweep_claim_site_count <path>... -- how many files discovery reached, counted
# off the NUL delimiters rather than lines so a path containing a newline counts
# once. The stream itself is never captured in a command substitution: bash
# drops NUL bytes there (and says so on stderr), so the count is taken inside
# the pipeline and only the digit crosses out.
sweep_claim_site_count() {
  sweep_claim_sites "$@" | tr -dc '\000' | wc -c | tr -d '[:space:]'
}

# sweep_unqualified_claims <path>... -- the whole sweep, discovery included, so
# the RED case below can drive the same entry point production does rather than
# the matcher on its own.
sweep_unqualified_claims() {
  local sweep_file sweep_out
  sweep_out=""
  while IFS= read -r -d '' sweep_file; do
    sweep_out="$sweep_out$(unqualified_blocks_nothing "$sweep_file")"
  done < <(sweep_claim_sites "$@")
  printf '%s' "$sweep_out"
}

sweep_roots=(
  "$REPO_ROOT/PROTOCOL.md" "$REPO_ROOT/README.md" "$REPO_ROOT/docs/architecture.md"
  "$REPO_ROOT/docs/specs" "$REPO_ROOT/docs/engines" "$REPO_ROOT/lib"
  "$REPO_ROOT/libexec" "$REPO_ROOT/runners" "$REPO_ROOT/plugins"
)
stale_claim="$(sweep_unqualified_claims "${sweep_roots[@]}")"
[ -z "$stale_claim" ] || fail "unqualified 'an empty findings[] blocks nothing' claim — true only of an APPROVING review since reconcile synthesizes one for a withheld verdict — still shipped in:$stale_claim"

# The sweep goes green two ways and only one of them is good news: nothing
# unqualified, or nothing FOUND. A mistyped root, a directory that has moved,
# or a rewording that carried the sentence off this surface all read as clean
# and would keep reading as clean forever. So discovery is required to still be
# looking at something: at least one file under the roots above must carry the
# claim.
claim_site_count="$(sweep_claim_site_count "${sweep_roots[@]}")"
[ "${claim_site_count:-0}" -gt 0 ] \
  || fail "the empty-findings sweep found the claim on no file at all — its roots no longer reach the surface that states it, so it would pass whatever the docs said"

# ...and the sweep is fed both answers through its own front door, because a
# sweep that never fires would pass this repo in exactly the state the finding
# describes -- and one that fires only when HANDED the file cannot say it would
# have found it. So the fixture is a directory, with the claim nested a level
# below the root the sweep is pointed at, and both cases go in through
# sweep_unqualified_claims: what is under test is discovery + fold + qualifier,
# not the matcher alone. The fixture WRAPS the claim mid-phrase, which is how
# docs/architecture.md actually writes it, so this is exactly the shape a
# line-oriented discovery step drops on the floor.
sweep_root="$WORK/stale-claim-sweep"
mkdir -p "$sweep_root/nested"
sweep_doc="$sweep_root/nested/claim.md"
printf 'the gate cuts both ways: an empty findings[] blocks\nnothing, and one finding at or above the threshold halts the pass.\n' \
  > "$sweep_doc"
# The witness for the finding this fixture encodes: the discarded line-oriented
# discovery step, run against the very same tree, comes back empty. Without it
# the RED case below passes just as well with a `grep -rl` pre-filter restored,
# and the regression walks straight back in.
[ -z "$(grep -rl "blocks nothing" "$sweep_root" 2>/dev/null || true)" ] \
  || fail "the wrapped-claim fixture is discoverable by a line-oriented grep — it no longer stands for the wrapped shape the sweep must fold to reach"
[ "$(sweep_claim_site_count "$sweep_root")" -gt 0 ] \
  || fail "the sweep's discovery step does not find a wrapped claim a line-oriented grep also misses — no step in the path would ever reach it"
[ -n "$(sweep_unqualified_claims "$sweep_root")" ] \
  || fail "the stale-claim sweep does not report the unqualified sentence it exists for — it would accept whatever it is pointed at"
red_case "the empty-findings sweep DISCOVERS and reports a wrapped, unqualified 'blocks nothing' claim that a line-oriented grep never lists"
printf 'on an approving review an empty findings[] blocks\nnothing, and one finding at or above the threshold halts the pass.\n' \
  > "$sweep_doc"
# Still discovered -- only the qualifier arm changes verdict. Pinning both keeps
# the GREEN case honest: a discovery step that had quietly stopped finding the
# file would otherwise look identical to a qualifier that correctly passed it.
[ "$(sweep_claim_site_count "$sweep_root")" -gt 0 ] \
  || fail "the qualified fixture is no longer discovered at all — the GREEN case below would pass for the wrong reason"
[ -z "$(sweep_unqualified_claims "$sweep_root")" ] \
  || fail "the stale-claim sweep flags a correctly qualified sentence — it would force the stale wording back into the docs"
green_case "the same sweep still discovers the wrapped sentence but accepts it once it names the approving review"

# The two doc sites that carry the claim in prose say what happens INSTEAD, not
# merely that the old sentence was narrowed: an operator who meets a `high`
# entry in a filed envelope has to be able to learn, from the page describing
# the adapter that filed it, that the kernel composed it.
arch_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/architecture.md" | tr -s '[:space:]' ' ')"
assert_match "WITHHOLDS approval never reaches that gate with an empty" "$arch_one_line" \
  "docs/architecture.md must say a non-approve review does not reach the severity gate with an empty findings[]"
assert_match "synthesized: true" "$claude_doc_one_line" \
  "docs/engines/claude.md must name the marker that tells a kernel-composed finding from the reviewer's own"

# THE ADAPTER HALF OF THE SAME FINDING. The synthesis lifts an envelope's
# `summary` and reads nothing else, and plugins/engines/claude/run -- the only
# shipped reviewer that populates findings[] itself -- wrote no summary at all,
# so on the one reply that needs it (request-changes with no parseable FINDING
# line) there was nothing to lift. It asks for the `REASON:` line its siblings
# already did, which is what lets PROTOCOL.md state the contract of EVERY
# shipped review adapter rather than of most of them.
#
# Checked against the adapters rather than trusted, and as a glob rather than a
# list, so a sixth engine added next year is held to it the day it lands. Both
# ends are pinned because the two can drift apart in either direction: the
# prompt must ASK for the line, and the envelope must CARRY it. Guarded on the
# prompt line so `plugins/engines/codex-review/run`, which `exec`s codex's
# adapter and carries no prompt of its own, is not asked for a contract it
# delegates.
assert_match "REASON: one sentence" "$claude_doc_one_line" \
  "docs/engines/claude.md's reply contract must show the REASON line the adapter asks for"
for adapter_run in "$REPO_ROOT"/plugins/engines/*/run; do
  [ -e "$adapter_run" ] || continue
  grep -q "^VERDICT: approve OR request-changes" "$adapter_run" || continue
  grep -q "^REASON: one sentence" "$adapter_run" \
    || fail "$adapter_run prompts for a verdict but never asks for a REASON line — PROTOCOL.md's synthesis arm claims every shipped review adapter does, and its summary is the only thing that arm can lift"
  grep -q 'verdict:\$v.*summary:\$s' "$adapter_run" \
    || fail "$adapter_run asks for a REASON line but never carries it into the VERDICT envelope's summary — the synthesis would file a placeholder for a real objection"
done
assert_match "line and carries it into" "$protocol_one_line" \
  "PROTOCOL.md must say where the summary the synthesis lifts comes from, not just that it is lifted"

# v1-m4 T006, the notify return leg: the two manifest keys doctor's check
# reads are a plugin CONTRACT, so they belong in the plugin spec — an
# operator writing a notify plugin has nowhere else to learn them.
assert_match "The inbound probe" "$plugins_spec_one_line" \
  "docs/specs/plugins.md must document the optional inbound-probe contract notify plugins may declare"
assert_match "requires_config" "$plugins_spec_one_line" \
  "docs/specs/plugins.md must document requires_config, which gates doctor's outbound ok"
for k in inbound_probe requires_config; do
  grep -q "$k" "$REPO_ROOT/lib/manifest.sh" \
    || fail "lib/manifest.sh no longer knows the manifest key '$k' — docs/specs/plugins.md documents it as valid"
done
grep -q "inbound_probe=--inbound-probe" "$REPO_ROOT/plugins/notify/openclaw/plugin.conf" \
  || fail "the openclaw notify plugin must declare an inbound probe — docs promise doctor actually probes the return leg for it"
# v1-m4 T009 reversed T006's deliberate omission here: hermes was the channel
# r-001 actually delivered on, and the one whose gateway being down swallowed
# a real operator answer (lesson L011), so shipping the ONE channel that
# demonstrated the failure without the check for it was the wrong way round.
# The claim these two lines guard is the same in both directions — a doc that
# says doctor probes this plugin's return leg, and a manifest that makes it
# true — so hermes.md must describe the probe rather than an omission.
grep -q "inbound_probe=--inbound-probe" "$REPO_ROOT/plugins/notify/hermes/plugin.conf" \
  || fail "the hermes notify plugin must declare an inbound probe — hermes.md documents 'hermes gateway status' as the return-leg query doctor runs for it"
grep -qF "This plugin ships no inbound probe" "$REPO_ROOT/docs/engines/hermes.md" \
  && fail "docs/engines/hermes.md still says the hermes notify plugin ships no inbound probe — plugins/notify/hermes/plugin.conf declares one"
# Folded, like every other prose assertion in this file: the sentence this
# pins straddles a hard wrap in the source, and `grep` against the raw file
# would silently never match it.
hermes_doc_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/engines/hermes.md" | tr -s '[:space:]' ' ')"
assert_match "hermes gateway status" "$hermes_doc_one_line" \
  "docs/engines/hermes.md must name the CLI query its inbound probe actually asks"
assert_match "prove anything on the channel side will turn that reply into an actual" "$hermes_doc_one_line" \
  "docs/engines/hermes.md must bound what a REACHABLE probe proves — the gateway, never a channel-side agent"

# ===========================================================================
# 7 -- beta qualification and the release rehearsal: the tooling exists, and
# every surface that mentions it keeps the two claims this repository is not
# allowed to blur. A third-party beta run and any publication are OPERATOR-
# owned, have not happened, and must never be described as if they had; and
# the qualification evidence is anonymized, which is a promise a tester reads
# before pointing this at a repository they cannot show anyone.
#
# grep -qF against fixed strings throughout (no regex): these are exact
# sentences the docs own, and a metacharacter in one of them would quietly
# change what is being asserted.
# ===========================================================================
QUALIFY_SH="$REPO_ROOT/scripts/beta-qualify.sh"
REHEARSAL_SH="$REPO_ROOT/tests/test_e2e_release_rehearsal.sh"
BETA_MD="$REPO_ROOT/docs/beta-qualification.md"
ACCEPTANCE_MD="$REPO_ROOT/docs/r-002-acceptance-evidence.md"
[ -f "$QUALIFY_SH" ] || fail "scripts/beta-qualify.sh missing — the beta docs describe a harness that does not exist"
[ -f "$REHEARSAL_SH" ] || fail "tests/test_e2e_release_rehearsal.sh missing — the release docs describe a rehearsal that does not exist"
[ -f "$ACCEPTANCE_MD" ] || fail "r-002 acceptance evidence missing — the candidate/post-merge boundary has no owning record"

# The harness's own --help is part of the documentation surface: it is what an
# operator reads before running it against a repository they cannot share. So
# it is asserted against the text `--help` ACTUALLY PRINTS, not against the
# file's bytes: a promise moved into a comment, or into a branch --help never
# reaches, would still satisfy a grep over the source. `--help` is parsed
# before --repo is required, so this costs one process and needs no fixture.
qualify_help="$("$BASH" "$QUALIFY_SH" --help)" \
  || fail "scripts/beta-qualify.sh --help must exit 0 without a repo"
grep -qF 'It never pushes, publishes, deploys, tags, or contacts a remote' <<<"$qualify_help" \
  || fail "scripts/beta-qualify.sh --help must state that it never publishes or contacts a remote"
grep -qF 'never copies repository content into the evidence' <<<"$qualify_help" \
  || fail "scripts/beta-qualify.sh --help must state the anonymization rule"
grep -qF 'Genuine third-party beta runs and public release remain operator-owned' <<<"$qualify_help" \
  || fail "scripts/beta-qualify.sh --help must name third-party beta and release as operator-owned"

# THE PROMISE AND ITS EXCEPTION MUST NOT DRIFT APART. "writes nothing inside
# --repo" is false on its own: by default this harness runs the target's own
# verify= command IN PLACE, which is the right design for a timing probe and is
# already stated in docs/beta-qualification.md. The document a tester actually
# reads before pointing this at a repository they cannot show anyone is the
# header comment and --help -- so both have to carry the exception in the same
# breath as the promise, and these assertions are what keeps them together.
grep -qF 'ONE EXCEPTION to "writes nothing inside --repo"' <<<"$qualify_help" \
  || fail "scripts/beta-qualify.sh --help states 'writes nothing inside --repo' without naming the in-place verify= run that contradicts it"
grep -qF 'IN PLACE' <<<"$qualify_help" \
  || fail "scripts/beta-qualify.sh --help must say the verify= command runs IN PLACE inside --repo"
# `-e` is REQUIRED here, not stylistic: the pattern begins with `--`, so grep
# parses it as an OPTION and exits 2 with "invalid option" before ever looking
# at the input. The assertion then fails against help text that does contain
# the flag -- a test that can only ever report absence.
grep -qF -e '--no-run-verify' <<<"$qualify_help" \
  || fail "scripts/beta-qualify.sh --help must name the flag that opts out of the in-place verify= run"
# ...and the same pairing at the top of the file, which is what a reader of the
# source meets first.
qualify_header="$(awk '/^set -uo pipefail$/ { exit } { print }' "$QUALIFY_SH" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
grep -qF 'writes nothing OF ITS OWN inside the target repository' <<<"$qualify_header" \
  || fail "scripts/beta-qualify.sh's header must scope its no-write promise to what the harness itself writes"
grep -qF 'IN PLACE, to time it' <<<"$qualify_header" \
  || fail "scripts/beta-qualify.sh's header must state the in-place verify= exception in the same breath as the no-write promise"
# The bare, unqualified form is the claim that must never come back.
grep -qF 'and writes nothing inside the target repository' <<<"$qualify_header" \
  && fail "scripts/beta-qualify.sh's header promises it writes nothing inside the target repository — it runs that repository's verify= command in place by default"

# The checklist page must carry the anonymization promise, the not-tested
# discipline, and the unclaimed operator-owned work.
grep -qF 'never contents, paths, filenames,' "$BETA_MD" \
  || fail "docs/beta-qualification.md must say exactly what the evidence never contains"
grep -qF 'both of its output streams discarded unread' "$BETA_MD" \
  || fail "docs/beta-qualification.md must state that the verify command's output is never recorded"
grep -qF 'never as a pass' "$BETA_MD" \
  || fail "docs/beta-qualification.md must state that an unperformed check is recorded as not-tested, never as a pass"
grep -qF 'Still operator-owned, and not claimed anywhere in this repository' "$BETA_MD" \
  || fail "docs/beta-qualification.md must keep its operator-owned section heading"
grep -qF 'genuine third-party beta run' "$BETA_MD" \
  || fail "docs/beta-qualification.md must name a genuine third-party beta run as operator-owned"
grep -qF 'no file in this repository records' "$BETA_MD" \
  || fail "docs/beta-qualification.md must state plainly that no third-party beta run is recorded here"
# `expires_when` is what keeps a non-blocking gap from becoming a permanent,
# meaningless warning. If the docs stop describing it, the discipline is gone.
grep -qF 'expires_when' "$BETA_MD" \
  || fail "docs/beta-qualification.md must explain that every non-blocking gap states what makes it expire"
grep -qF 'a warning that can never expire is noise' "$BETA_MD" \
  || fail "docs/beta-qualification.md must say why a non-expiring warning is not evidence"
# "No subprocess output reaches a record" has exactly one exception -- the
# toolchain version and platform strings -- and a promise with an unstated
# exception is not a promise. Both the code and every page that repeats the
# rule have to carry it, or they drift apart silently.
grep -qF 'version_token' "$QUALIFY_SH" \
  || fail "scripts/beta-qualify.sh must validate the version strings it records instead of copying them"
grep -qF 'unrecognized' "$BETA_MD" \
  || fail "docs/beta-qualification.md must state that a version outside the harness's pattern is recorded as 'unrecognized'"
grep -qF 'unrecognized' "$REPO_ROOT/README.md" \
  || fail "README.md's anonymization summary must state the version-string rule"
grep -qF 'unrecognized' "$REPO_ROOT/docs/specs/plugins.md" \
  || fail "docs/specs/plugins.md's threat model must state the version-string rule"

# The rehearsal's isolation claim is only as good as its scope. The page must
# keep saying what the snapshots watch and what they deliberately do not.
grep -qF 'has no business' "$BETA_MD" \
  || fail "docs/beta-qualification.md must state that the rehearsal never reads an operator's real trust records"

# The two asymmetries a tester will otherwise meet as "the product is broken".
grep -qF 'persistent answering agent' "$BETA_MD" \
  || fail "docs/beta-qualification.md must explain that the inbound answer leg needs a persistent agent"
grep -qF 'no command allowlist' "$BETA_MD" \
  || fail "docs/beta-qualification.md must explain why a manifest capability is not a grant"

# README's own summary must not soften either claim.
grep -qF 'A genuine third-party beta run and any publication remain operator-owned.' "$REPO_ROOT/README.md" \
  || fail "README.md must state that a third-party beta run and publication remain operator-owned"
grep -qF 'Neither has happened, and nothing in this repository claims otherwise.' "$REPO_ROOT/README.md" \
  || fail "README.md must state that neither has happened"

# Candidate evidence must remain honest until the operator performs the steps
# a candidate cannot. These are explicit OPEN/NOT-RUN claims, not placeholders
# that a docs edit may silently soften into past tense.
grep -qF 'Status: **NOT YET ACCEPTED. Operator completion is required after merge.**' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must identify itself as a candidate hand-off, not completed run acceptance"
grep -qF 'Canonical candidate-local CI | **NOT RUN**' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must say candidate-local CI was not run by the no-shell implementer"
grep -qF 'Suite on the integration branch itself | **NOT RUN; REQUIRED AFTER MERGE**' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must leave the integration-branch suite as an explicit post-merge operator step"
grep -qF 'Hosted GitHub Actions | **NOT OBSERVED BY THIS RUN**' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must state that this local run did not observe remote CI"
grep -qF 'No third-party beta run has occurred.' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must preserve the no-third-party-beta release posture"
grep -qF 'Nothing was published, pushed, tagged, uploaded, deployed, announced, or' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must preserve the no-publication/push/tag/remote posture"
grep -qF 'The shipped version remains `1.0.0-beta.1`' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must keep the shipped version in the beta series"
grep -qF 'Bootstrap-journal audit' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must own the pre-bootstrap dispatch journal audit"
grep -qF 'Operator result: **OPEN — do not accept the run.**' "$ACCEPTANCE_MD" \
  || fail "r-002 evidence must not hide an unperformed journal/lesson audit"

# The threat model owns the one thing the harness really does execute inside a
# candidate repository.
grep -qF 'scripts/beta-qualify.sh' "$REPO_ROOT/docs/specs/plugins.md" \
  || fail "docs/specs/plugins.md's threat model must cover the beta qualification harness"

# PROTOCOL.md's headless section must tell an operator to qualify before
# acknowledging: the acknowledgement opens the gate, it does not make a
# repository drivable.
grep -qF 'Qualify a repository before acknowledging it' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md's HEADLESS OPERATION section must tell an operator to qualify before acknowledging"

# T011 -- THAT ORDER IS A DECISION, AND A DECISION RECORDED ONLY AS AN OUTCOME
# IS ONE NOBODY CAN REVISIT.
#
# The harness runs the target's own verify= command in place with no
# acknowledgement of any kind, which is repository content reaching execution.
# Keeping it ungated was chosen over two live alternatives -- a narrower
# qualification-scoped acknowledgement, and making --no-run-verify the default
# -- and the next person to notice the exposure will reach for one of exactly
# those two. So the spec must carry the reasoning, BOTH rejected options, and
# the condition that would reopen the question; losing any of them sends that
# person round the same loop with no record that it was already walked.
#
# Folded first, then grep -qF: these are prose SENTENCES, every one of them
# straddles a hard wrap in the source, and a fixed-string search over the raw
# file would never match one.
ops_spec_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/specs/operations.md" | tr -s '[:space:]' ' ')"
grep -qF 'Qualification stays ungated anyway.' <<<"$ops_spec_one_line" \
  || fail "docs/specs/operations.md must record the decision that beta qualification takes no trust step of its own"
grep -qF 'It would invert the documented order.' <<<"$ops_spec_one_line" \
  || fail "docs/specs/operations.md must say why requiring an acknowledgement to qualify would invert the documented order"
grep -qF 'Rejected: a qualification-scoped acknowledgement' <<<"$ops_spec_one_line" \
  || fail "docs/specs/operations.md must record the narrower qualification-scoped acknowledgement as a REJECTED alternative rather than omit it"
grep -qF 'Rejected: making `--no-run-verify` the default' <<<"$ops_spec_one_line" \
  || fail "docs/specs/operations.md must record making --no-run-verify the default as a REJECTED alternative"
grep -qF 'What would reopen this.' <<<"$ops_spec_one_line" \
  || fail "docs/specs/operations.md must state what would make this decision have to be made again"

# The two surfaces that would otherwise state the order without the reasoning.
beta_md_one_line="$(tr '\n' ' ' < "$BETA_MD" | tr -s '[:space:]' ' ')"
grep -qF 'no acknowledgement of its own' <<<"$beta_md_one_line" \
  || fail "docs/beta-qualification.md must tell a tester plainly that qualification needs no trust step of its own"
grep -qF 'specs/operations.md' <<<"$beta_md_one_line" \
  || fail "docs/beta-qualification.md must point at the recorded decision instead of restating only its outcome"
grep -qF 'requires no acknowledgement of its own' <<<"$protocol_one_line" \
  || fail "PROTOCOL.md must say that beta qualification itself requires no acknowledgement, not only that it never grants one"

# TWO-WAY, against the code. While qualification is ungated the docs must say
# so; the day someone gates it, this fails and sends them to the sentences that
# have just become false rather than leaving the spec quietly wrong.
grep -qF 'unattended_trust_require' "$QUALIFY_SH" \
  && fail "scripts/beta-qualify.sh now gates itself on the unattended acknowledgement, which inverts the order PROTOCOL.md and docs/specs/operations.md document — if that decision has changed, change those two and this assertion with it"
grep -qF 'docs/specs/operations.md' "$QUALIFY_SH" \
  || fail "scripts/beta-qualify.sh must point at the recorded decision, so an editor tempted to add a gate finds the reasoning first"

# ...and that last one is a grep over the FILE'S BYTES, which the header comment
# alone satisfies. It cannot tell whether --help still says any of this. That
# matters here more than usual: the decision above is that qualification carries
# a stated exception INSTEAD of a gate, and --help is one of the two surfaces
# stating it -- delete the paragraph, keep the header comment, and every
# assertion so far still passes while the mitigation the decision rests on is
# gone. So pin what --help PRINTS, exactly as the --help block earlier in this
# file requires of the promise it guards. Folded first: both sentences straddle
# a hard wrap in the usage text, and grep -qF over the raw output would never
# match one.
qualify_help_one_line="$(tr '\n' ' ' <<<"$qualify_help" | tr -s '[:space:]' ' ')"
grep -qF 'That notice stands in place of a trust step: qualification is deliberately ungated' <<<"$qualify_help_one_line" \
  || fail "scripts/beta-qualify.sh --help must say that the in-place notice stands IN PLACE OF a trust step and that qualification is ungated by design — the two halves are one claim and neither is safe alone"
grep -qF 'See docs/specs/operations.md for that decision and what was rejected.' <<<"$qualify_help_one_line" \
  || fail "scripts/beta-qualify.sh --help must send the operator who doubts that choice to the recorded decision, not only state its outcome"

# ...and one last two-way assertion, this one about the CALLERS rather than the
# script. The third reason in that spec section turns on a fact nothing above
# touches: "the harness is a foreground command with two required paths on it,
# never scheduled and never invoked by the kernel". That is the whole of why the
# unattended gate's subject is a different one -- the gate exists because nobody
# is in front of the pump, and this argument is that somebody is always in front
# of qualification. Wire it into a runner, a service unit or a kernel verb and
# that sentence is false and the third reason collapses -- while
# scripts/beta-qualify.sh has not changed by one byte and every assertion above
# still passes. So it is pinned where it can actually break.
qualify_caller_roots=("$REPO_ROOT/lib" "$REPO_ROOT/libexec" "$REPO_ROOT/runners")
for qualify_caller_root in "${qualify_caller_roots[@]}"; do
  [ -d "$qualify_caller_root" ] \
    || fail "$qualify_caller_root is missing, so the kernel-caller search below would pass by looking at nothing"
done
# Non-vacuous by construction: the same search shape, over the same roots, has
# to find something that IS there. `unattended_trust_require` is called from
# exactly the three surfaces that spec section names, all three under these
# roots, so an empty control result means the search itself is broken -- moved
# directories, a wrong root -- rather than that the kernel is clean.
grep -rqF 'unattended_trust_require' "${qualify_caller_roots[@]}" \
  || fail "the kernel-caller search cannot even find an unattended_trust_require call, so it is searching nothing and proves nothing about qualification"
qualify_callers="$(grep -rlF 'beta-qualify' "${qualify_caller_roots[@]}" || true)"
[ -z "$qualify_callers" ] \
  || fail "docs/specs/operations.md rests part of this decision on qualification being 'never scheduled and never invoked by the kernel', but kernel code now names the harness: $qualify_callers — if that changed on purpose, the third reason has to be remade and this assertion changed with it"

# T012 is the other r-002 decision this reconciliation task owns. Preserve the
# decision and every rejected alternative together: an outcome without the
# rejected routes sends the next editor through the same design loop.
grep -qF 'Review depth (v1.1 — decision, T012)' "$REPO_ROOT/docs/specs/kernel.md" \
  || fail "docs/specs/kernel.md must identify T012's review-depth section as a recorded decision"
grep -qF 'Engine independence and review depth are different axes' <<<"$kernel_one_line" \
  || fail "docs/specs/kernel.md must record T012's choice: medium/high deterministic approval needs depth as well as independence"
grep -qF 'Rejected: make `review.<tier>` itself refuse to resolve, or refuse to dispatch' <<<"$kernel_one_line" \
  || fail "docs/specs/kernel.md must retain T012's rejected routing/dispatch refusal alternative"
grep -qF 'Rejected: a per-task flag deciding whether the criteria' <<<"$kernel_one_line" \
  || fail "docs/specs/kernel.md must retain T012's rejected per-task flag/prose-scan alternative"
grep -qF 'Rejected: a `review.require_depth` config key.' <<<"$kernel_one_line" \
  || fail "docs/specs/kernel.md must retain T012's rejected global depth-disable alternative"

# The release-day checklist must include the local rehearsal.
grep -qF 'tests/test_e2e_release_rehearsal.sh' "$REPO_ROOT/docs/install.md" \
  || fail "docs/install.md's release-day steps must include the local rehearsal"

# ...and it must not prescribe a run whose guarantee is weaker than the page's
# description of it (T004). tests/run.sh globs the rehearsal and the suite is
# runnable inside an unpacked release archive, where the tree has no Git
# metadata at its root: the working-tree, HEAD and remote-ref half of the
# isolation claim cannot be asked there, and the rehearsal records it as
# not-tested (tests/test_rehearsal_source_snapshot.sh proves that behaviour).
# The page has to say both things, or an operator reads the archive run's
# silence as the whole claim having held. Folded to one line first: these are
# SENTENCES, and each straddles a hard wrap in the source.
install_md_one_line="$(tr '\n' ' ' < "$INSTALL_MD" | tr -s '[:space:]' ' ')"
grep -qF 'Run it from the Git checkout you are tagging' <<<"$install_md_one_line" \
  || fail "docs/install.md's release-day rehearsal step must tell the operator to run it from the Git checkout being tagged -- an archive run cannot make the isolation claim the step is there for"
grep -qF 'records the working-tree, `HEAD` and remote-ref half of the claim above as `NOT-TESTED`' \
  <<<"$install_md_one_line" \
  || fail "docs/install.md must say what the rehearsal does NOT prove when it runs outside a Git checkout, rather than describing the checkout run's guarantee as the only one"

# ===========================================================================
# T010 -- THE DOCS DESCRIBE THE TREE THEY SHIP IN, in BOTH directions.
#
# The operator hand-off leaves `candidate_sha` equal to the `HEAD` its own
# commits produced, and it is tempting to explain that by naming the check that
# would consume the equality: a verification that REFUSES to run when the two
# disagree. When this tripwire was written no such refusal was in the tree --
# `libexec/orchid-verify` recorded both shas into its evidence header and ran
# regardless, and the only gate that read them was INV-11's, on the
# `testing -> reviewing` advance, afterwards. The task proposing the
# verify-side refusal (T031) was unmerged, and a doc that describes an unmerged
# task's design in the present tense is indistinguishable, to every later
# reader, from one describing shipped behaviour.
#
# T031 HAS SINCE LANDED, and this tripwire fired in exactly the direction it
# was built to fire: the docs no longer say `orchid verify` compares nothing,
# because it now does (exit 20 on a mismatch, before the suite runs). The
# assertion below is unchanged and still runs BOTH ways -- the day someone
# reverts or reshapes that comparison out of the verb, it sends them straight
# back to the sentences that would have become false again. The discriminator
# is mechanical: a line of that verb outside a comment mentions both shas
# exactly when it compares them.
#
# T024's prerequisite refusal is deliberately not what this tripwire watches:
# that gate compares an acknowledgement against `candidate_sha` without
# comparing the verifier's `$sha` to the recorded candidate.
VERIFY_SRC="$REPO_ROOT/libexec/orchid-verify"
[ -f "$VERIFY_SRC" ] \
  || fail "libexec/orchid-verify must exist — the check below reads it as the source of truth about what verification does"
verify_compares=0
# Captured, then matched from a HERESTRING -- never `grep -v ... | grep -Eq`.
# This file runs under `pipefail`, and `grep -q` exits at its first match,
# SIGPIPEing the upstream grep mid-write; pipefail then promotes that 141 to
# the pipeline's status and the `if` reads "no match" for a pattern that DID
# match. A tripwire that silently inverts is worse than no tripwire.
verify_body="$(grep -v '^[[:space:]]*#' "$VERIFY_SRC" 2>/dev/null || true)"
if grep -Eq '\$sha.*\$cand|\$cand.*\$sha' <<<"$verify_body"; then
  verify_compares=1
fi
for doc in PROTOCOL.md docs/specs/kernel.md; do
  if [ "$verify_compares" -eq 1 ]; then
    grep -qF 'does not compare' "$REPO_ROOT/$doc" \
      && fail "$doc still says 'orchid verify' compares no shas before running, but libexec/orchid-verify now does — the sentence that was honest about an unlanded gate has become a false one about a landed gate"
  else
    grep -qF 'does not compare' "$REPO_ROOT/$doc" \
      || fail "$doc must state that 'orchid verify' performs no sha comparison as this ships — describing an unmerged task's design (T031) in the present tense reads as shipped behaviour to every later reader"
  fi
done
if [ "$verify_compares" -eq 0 ]; then
  grep -qF 'verify-side sha check requires' "$REPO_ROOT/PROTOCOL.md" \
    && fail "PROTOCOL.md asserts a verify-side sha refusal in the present tense and no such refusal is in libexec/orchid-verify — state the dependency as a dependency, or describe the tree this ships in"
fi

# ===========================================================================
# T022 -- THE TRANSITION TABLE MUST NOT CREDIT A VERB WITH A GATE IT CANNOT
# PERFORM. The no-op-delivery refusal is a comparison between the worktree's
# `HEAD` and the sha the round was dispatched to move, and the driver makes it
# in the only window where both exist: it reads `HEAD`, compares, and only then
# writes that `HEAD` into `candidate_sha` and calls `orchid task advance`. By
# the time the verb runs the two shas are equal by construction and the prior
# candidate is gone from the record, so a table listing "HEAD moved off the
# prior candidate_sha" as a PRECONDITION of `task advance` names a gate nothing
# performs — and the table is this project's declared test oracle, so the next
# reader to trust it removes the driver-side check as redundant.
#
# Two-way, on the ORDER in the driver rather than on the prose alone: the day
# the write moves after the advance (or the verb grows the comparison), this
# fails and sends whoever landed it to the sentence that has just changed
# meaning.
#
# Captured whole and split with parameter expansion -- no `grep | head`, for
# the pipefail/SIGPIPE reason spelled out above. Each pattern matches exactly
# one line, which is asserted rather than assumed: two matches would make
# `${hits%%:*}` a line number for one of them and the comparison meaningless.
kernel_cand_hits="$(grep -n 'task set "\$id" candidate_sha "\$cand"' "$REPO_ROOT/runners/orchid-drive" || true)"
kernel_adv_hits="$(grep -n 'task advance "\$id" testing' "$REPO_ROOT/runners/orchid-drive" || true)"
assert_eq 1 "$(printf '%s' "$kernel_cand_hits" | grep -c . || true)" \
  "T022 tripwire: the driver must have exactly one candidate_sha write on the implementing arm — the check below reads its position (found: $kernel_cand_hits)"
assert_eq 1 "$(printf '%s' "$kernel_adv_hits" | grep -c . || true)" \
  "T022 tripwire: the driver must have exactly one implementing -> testing advance (found: $kernel_adv_hits)"
kernel_cand_set="${kernel_cand_hits%%:*}"
kernel_cand_adv="${kernel_adv_hits%%:*}"
# Defaulted so a missing match cannot turn the comparison below into a bash
# error on a non-numeric operand: 0 vs 0 takes the `else` arm, which reports a
# tripwire that could not read the driver alongside the count assertions above.
case "$kernel_cand_set" in ''|*[!0-9]*) kernel_cand_set=0 ;; esac
case "$kernel_cand_adv" in ''|*[!0-9]*) kernel_cand_adv=0 ;; esac
if [ "$kernel_cand_set" -lt "$kernel_cand_adv" ]; then
  assert_match "orchestrator-checked before the verb is called" "$kernel_one_line" \
    "docs/specs/kernel.md's implementing -> testing row must attribute the delivery check to the orchestrator: the driver writes candidate_sha to the HEAD it just read BEFORE advancing, so 'task advance' sees the two equal and has nothing left to compare"
  assert_match "could not enforce this even if it were asked to" "$kernel_one_line" \
    "docs/specs/kernel.md must SAY why that precondition is orchestrator-enforced rather than kernel-enforced — an unexplained exception to the enforcement-ownership paragraph reads as an oversight to be tidied up"
else
  fail "T022 tripwire: the driver no longer writes candidate_sha before its implementing -> testing advance (write at line $kernel_cand_set, advance at line $kernel_cand_adv) — either the verb can now see both shas, or this check can no longer read the driver; docs/specs/kernel.md's account of why the precondition is orchestrator-enforced must be revisited either way"
fi

# The rework brief is one brief, not an accumulating pile: PROTOCOL.md has to
# say that each block names its candidate and that superseded ones are aged
# out, because an implementer handed three briefs cannot tell which describes
# the tree it was just given.
grep -qF 'aged out' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md's rework-brief section must state that briefs describing a replaced candidate are aged out — otherwise re-serving them reads as intended behaviour"
grep -qF 'FINDINGS_BRIEF_MARK' "$REPO_ROOT/lib/findings.sh" \
  || fail "lib/findings.sh must keep the marker that binds each brief to its candidate — the aging pass is only as good as what identifies a block"

# The two refusals `orchid task handoff --ack` carries beyond its sha checks are
# BOTH things an operator hits while doing the procedure correctly-looking:
# applying the fix without committing it, and acknowledging once the candidate
# has moved on to reviewers. A refusal an operator meets with no sentence in the
# procedure explaining it is indistinguishable from a bug in the verb, and the
# usual response to a verb that looks broken is to work around it.
grep -qF 'an ack over a dirty tree is refused' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md's hand-off procedure must say that --ack refuses over an uncommitted tree — an operator who hits that refusal with nothing in the procedure about it reads it as a broken verb"
grep -qF 'acknowledged from `testing` only' "$REPO_ROOT/PROTOCOL.md" \
  || fail "PROTOCOL.md's hand-off procedure must say which status --ack is legal from — the advance it performs moves candidate_sha, which is destructive once reviewers hold that commit"

# ===========================================================================
# T024 -- the two operator-owned stops before verify are DISTINCT, and the
# docs must say which comes first.
#
# `operator-handoff` (T010) and `task-prerequisite` (T024) sit at the same
# point in the procedure and read almost identically at a glance: both hold a
# candidate before verification on an acknowledgement bound to `candidate_sha`.
# They are not the same thing, and the difference has a cost attached: the
# hand-off's ack ADVANCES `candidate_sha`, which supersedes a prerequisite ack
# taken before it. An operator who does them in the other order pays a re-run.
#
# Pinned on the folded text because each sentence straddles a hard wrap.
# ===========================================================================
grep -qF 'Take the hand-off FIRST when both are outstanding' <<<"$protocol_one_line" \
  || fail "PROTOCOL.md must state which of the two operator-owned stops before verify to take first — the hand-off advances candidate_sha and expires a prerequisite ack made before it"
grep -qF 'the driver raises the hand-off first' <<<"$kernel_one_line" \
  || fail "docs/specs/kernel.md must record that the driver raises operator-handoff ahead of task-prerequisite, so the ordering is a documented property and not an accident of the code"

# ...and the docs must not present that supersession as a closed list of
# verbs. Three routes move `candidate_sha` without any clear of the ack --
# merge's rebase-reset, `task reverify`'s re-stamp, and the hand-off's own
# advance -- and only the SHA comparison catches all three. Prose that names
# one of them as "the" case invites the maintenance a comparison exists to
# avoid: a fourth mover added later, and a reader who goes looking for the
# clear it was supposed to have remembered.
grep -qF 'not a list of verbs to keep in step' <<<"$protocol_one_line" \
  || fail "PROTOCOL.md's prerequisite bullet must say the binding is a comparison rather than a list of clearing verbs — merge's rebase-reset is one candidate mover among several (task reverify and the hand-off ack are others), and naming it as the only one is the reading that goes stale"
grep -qF '`orchid task reverify` re-stamps `candidate_sha`' <<<"$protocol_one_line" \
  || fail "PROTOCOL.md's prerequisite bullet must name task reverify among the candidate moves that expire an acknowledgement — it re-stamps candidate_sha and reaches testing from blocked without entering rework, so no clear on any rework path sees it"

# ===========================================================================
# T024/T023 -- the rejected alternative in kernel.md must describe
# `worktree_prepare` in whichever tense is true of THIS tree.
#
# The operator-prerequisite section records why a `migrate=` step run as part
# of `worktree_prepare` was rejected. The command was proposed by T023 and,
# when T024 wrote that section, was nowhere in this tree: no config key, no
# code. Argued in the present tense then, it read as a description of shipped
# behaviour a reader could grep for and never find.
#
# T023 has since landed, so this tripwire has fired once and been answered:
# its arms are now swapped, and it remains a test rather than a comment
# because it still has to hold in both directions.
#   - While something DOES define it, the paragraph must speak of a landed
#     mechanism, and must carry the re-reading that landing forced. The four
#     reasons were written against a design as specified; the fourth of them
#     -- that a failed prepare could only park the run on a
#     `worktree-conflict` boundary -- is answered by what shipped, which
#     charges the infra ladder instead, and it is marked withdrawn rather
#     than left standing as an argument that is no longer true.
#   - Should the mechanism ever be REMOVED, this fails on purpose: the
#     paragraph would then be arguing in the present tense about something
#     a reader cannot find, which is the exact defect the original half of
#     this tripwire existed to prevent.
#
# Every assertion runs against the whitespace-folded `kernel_one_line` built
# above, not the file. Each pins a whole SENTENCE, and a sentence in this spec
# is hard-wrapped across two lines -- `grep -F` on the raw file matches a line
# at a time, so it would report the paragraph missing whenever the prose
# happened to wrap mid-phrase, which is the normal state of it.
# ===========================================================================
wp_defined=0
grep -qxF 'worktree_prepare' "$KEYFILE" && wp_defined=1
grep -rqF 'worktree_prepare' "$REPO_ROOT/lib" "$REPO_ROOT/libexec" "$REPO_ROOT/runners" 2>/dev/null && wp_defined=1
if [ "$wp_defined" -eq 1 ]; then
  grep -qF 'task T023 has since landed' <<<"$kernel_one_line" \
    || fail 'worktree_prepare exists in this tree: docs/specs/kernel.md must say T023 landed it, so the rejected alternative reads as an argument about a shipped mechanism rather than about a design on paper'
  grep -qF 'this reason is withdrawn' <<<"$kernel_one_line" \
    || fail "docs/specs/kernel.md's rejected alternative must mark the fail-honestly reason withdrawn: what shipped charges a failed prepare to the infra ladder rather than parking the run on a worktree-conflict boundary, so that bullet no longer argues against anything and must not sit there as hedging nobody revisits"
  # The negative half, and the reason it is spelled as an `if` rather than as
  # `grep ... && fail`: this suite runs under `set -o pipefail`, and the
  # herestring keeps the matcher's status its own (helpers.sh's assert_match
  # carries the full account). A paragraph that says BOTH things -- landed,
  # and "nothing named this exists" -- is the half-finished edit this arm is
  # here to catch, and the two positive assertions above cannot see it.
  if grep -qF 'Nothing named `worktree_prepare` exists in this tree' <<<"$kernel_one_line"; then
    fail 'docs/specs/kernel.md still claims nothing named worktree_prepare exists in this tree, but the config key and its code are both here — that sentence must go, not merely be argued around'
  fi
else
  fail 'worktree_prepare is no longer defined anywhere in lib/, libexec/, runners/ or lib/config-keys.txt, yet docs/specs/kernel.md argues against it as a landed mechanism: that paragraph must be re-read against what is actually in this tree'
fi

# ===========================================================================
# T024 -- PLANNING step 2 is the ONLY place `operator_prerequisite` can be
# named, so it has to name it there.
#
# The field is settable at exactly one moment in a run's life: while the plan
# is being drafted. The implementer cannot set it afterwards -- its commits
# may not touch `.orchid/` at all, and INV-04 refuses entry to `testing` over
# one that does -- so a planner who never reads the word never writes it, and
# the whole convention silently applies to nothing.
#
# templates/task-migrate.md's prose is NOT a substitute, and that is the
# regression this pins: a task whose migration is incidental (a `feature`
# that alters a table, a `test` archetype exercising one) never renders that
# template and its planner never sees the instruction. THE TICK's `testing`
# step describes the gate for whoever meets it; only PLANNING step 2 reaches
# the one actor who can prevent meeting it.
#
# Sliced to step 2 rather than grepped over the whole file, because "PROTOCOL
# mentions the field somewhere" is exactly the state this replaces -- it was
# already described at length under THE TICK while step 2 said nothing.
# ===========================================================================
planning_step2="$(sed -n '/^## PLANNING/,/^## THE TICK/p' "$REPO_ROOT/PROTOCOL.md" \
  | sed -n '/^2\. Draft the roadmap/,/^3\. /p' \
  | tr '\n' ' ' | tr -s '[:space:]' ' ')"
# The slice's own witness, asserted before anything is read out of it. Both
# range markers are ordinary prose headings and either could be reworded; an
# empty slice would otherwise fail the two checks below with "the docs lost
# this sentence", which is a lie about which thing broke.
[ -n "$planning_step2" ] \
  || fail 'test bug, not a docs failure: the PLANNING-step-2 slice came back empty — one of the sed range markers (## PLANNING, ## THE TICK, "2. Draft the roadmap", "3. ") no longer matches PROTOCOL.md'
grep -qF 'orchid task create' <<<"$planning_step2" \
  || fail 'test bug, not a docs failure: the PLANNING-step-2 slice does not contain the task-drafting step it is supposed to be — re-check the sed range before reading the assertions below'
# Folded, like every other pinned sentence here: this one is hard-wrapped
# mid-phrase in the source and `grep -F` matches a line at a time.
grep -qF 'Include `operator_prerequisite` for any task whose verification depends on a step taken OUTSIDE the sandbox' <<<"$planning_step2" \
  || fail "PROTOCOL.md's PLANNING step 2 must tell the planner to set operator_prerequisite — it is the only moment in a run when that field can be written, so a planner who is not told there is never told at all"
grep -qF 'this applies to every archetype, not only the `migrate` one' <<<"$planning_step2" \
  || fail "PROTOCOL.md's PLANNING step 2 must say the field applies to every archetype — left to templates/task-migrate.md alone, a feature or test task that happens to alter a schema never carries the instruction"

# ===========================================================================
# T007 -- `--charge-attempt`'s admitted edges are a CLOSED SET, and both
# normative docs must describe the set the KERNEL actually enforces.
#
# The flag shipped as `testing -> blocked` only, and both docs said so in the
# absolute ("legal only on/for `testing -> blocked`"). T007 widened the set to
# admit `merging -> rework` and `merging -> blocked` for `orchid merge`'s
# `gate_failed` arm, which turned two normative sentences into false ones --
# the failure mode docs/specs/kernel.md's own transition table exists to
# prevent, since the table is this project's declared test oracle and a reader
# who trusts the prose over it removes the widening as unsupported.
#
# Two-way, keyed on libexec/orchid-task's `case` label rather than on the
# prose alone: the day that set changes in either direction, the docs are the
# thing this sends the next reader to. A narrowing back to the single edge
# fails on the second arm, so this cannot rot into a check that only ever
# demands the wider wording.
# ===========================================================================
charge_case_src="$REPO_ROOT/libexec/orchid-task"
[ -f "$charge_case_src" ] \
  || fail "libexec/orchid-task must exist — the check below reads its --charge-attempt case list as the source of truth about which edges admit the flag"
charge_merging_admitted=0
if grep -qF 'testing:blocked|merging:rework|merging:blocked' "$charge_case_src"; then
  charge_merging_admitted=1
fi
# Folded, like every other pinned sentence in this file: both claims are
# hard-wrapped mid-phrase in the source and `grep -F` matches a line at a time.
charge_protocol_one_line="$(tr '\n' ' ' < "$REPO_ROOT/PROTOCOL.md" | tr -s '[:space:]' ' ')"
charge_kernel_one_line="$(tr '\n' ' ' < "$REPO_ROOT/docs/specs/kernel.md" | tr -s '[:space:]' ' ')"
for charge_doc in PROTOCOL.md docs/specs/kernel.md; do
  if [ "$charge_doc" = PROTOCOL.md ]; then
    charge_folded="$charge_protocol_one_line"
  else
    charge_folded="$charge_kernel_one_line"
  fi
  [ -n "$charge_folded" ] \
    || fail "test bug, not a docs failure: the folded text of $charge_doc came back empty — nothing below is reading the document it names"
  if [ "$charge_merging_admitted" -eq 1 ]; then
    grep -qF 'flag is legal only' <<<"$charge_folded" \
      && fail "$charge_doc still calls --charge-attempt legal on one edge alone, but libexec/orchid-task admits merging -> rework and merging -> blocked as well — the sentence that was true of the narrow flag has become a false account of the kernel's own case list"
    grep -qF '`merging -> rework`' <<<"$charge_folded" \
      || fail "$charge_doc must name \`merging -> rework\` among the edges --charge-attempt is admitted on: it is the edge orchid merge charges a red merge_gate through, and a doc listing only testing -> blocked describes a kernel that no longer exists"
    grep -qF '`merging -> blocked`' <<<"$charge_folded" \
      || fail "$charge_doc must name \`merging -> blocked\` beside it — that is where the charge lands once the gate has spent the task's last rework round, and a set described as two-thirds of itself is the reading a later reader tidies up"
  else
    grep -qF '`merging -> rework`' <<<"$charge_folded" \
      && fail "libexec/orchid-task no longer admits --charge-attempt on the merging pair, yet $charge_doc still describes it as legal there — describing a withdrawn edge in the present tense reads as shipped behaviour to every later reader"
  fi
done
