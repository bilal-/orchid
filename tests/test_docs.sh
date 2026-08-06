#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
# v1-m4 Task 8: docs suite lint. Three independent, purely mechanical
# checks over the published documentation set -- no repo/run state, no git --
# mirroring test_config_keys.sh's own annotation-driven
# approach (grep-only, no prose heuristics) so this suite carries zero
# false-positive risk from trying to parse free text:
#
#   1. every `orchid <word>` CODE-SPAN, and every fenced-shell-block line
#      STARTING with "orchid <word>", in README.md/the two quickstarts
#      names a real tier-1 verb (a libexec/orchid-<word> file actually on
#      disk) -- catches a renamed/typo'd verb before a reader ever hits it.
#      (Scoped to just these three files deliberately: a prose sentence
#      elsewhere -- e.g. docs/engines/hermes.md's "orchid never manages
#      this..." -- would false-positive against the start-of-line half of
#      this pattern; README/the quickstarts never open a line with prose
#      starting in lowercase "orchid ", only with real fenced commands.)
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

# docs_suite_files -- the exact surface this task owns: README + the
# quickstarts + configuration/troubleshooting/research + every engine guide
# (built-in and reference-adapter alike) + the extending guides (cross-
# linked, not rewritten, by this task). Deliberately NOT docs/specs/*.md
# (the normative design spec, untouched by this task -- e.g. kernel.md's
# task-frontmatter field `blocking_severity` reads exactly like a config
# key under a naive scan but is not one), docs/plans/*.md, or
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
docs/quickstart.md
docs/quickstart-greenfield.md
docs/configuration.md
docs/troubleshooting.md
docs/research.md
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
# 1 -- every `orchid <word>` code-span in README.md + the two quickstarts
# names a real tier-1 verb.
# ===========================================================================
verb_check_files="README.md docs/quickstart.md docs/quickstart-greenfield.md"
verb_words=""
for rel in $verb_check_files; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  words="$( { grep -oE '`orchid [a-zA-Z][a-zA-Z-]*' "$f" | sed -E 's/`orchid //'
             grep -oE '^orchid [a-zA-Z][a-zA-Z-]*' "$f" | sed -E 's/^orchid //'; } || true)"
  verb_words="$verb_words
$words"
done
verb_count=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  verb_count=$((verb_count + 1))
  [ -x "$REPO_ROOT/libexec/orchid-$v" ] || fail "a code-span names 'orchid $v' but libexec/orchid-$v doesn't exist (or isn't executable)"
done < <(printf '%s\n' "$verb_words" | sort -u)
[ "$verb_count" -gt 0 ] || fail "verb-name extraction from README/quickstarts found nothing -- files missing, or the regex broke"

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
printf '%s\n' "$quickstart_text" | grep -qF \
  'The URL is immutable: running this exact line later reselects `v1.0.0-beta.1`; it does not upgrade Orchid. To upgrade, select the install URL for a newer immutable released tag.' \
  || fail "docs/quickstart.md must explain that upgrading requires a newer immutable released tag"
printf '%s\n' "$quickstart_text" | grep -qF \
  'Running this exact line again later is the upgrade command too.' \
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
# ...and the same claim must not survive in any other shipped usage text.
stale_help="$(grep -rln "adapter never fills findings" "$REPO_ROOT/runners" "$REPO_ROOT/libexec" "$REPO_ROOT/bin" 2>/dev/null || true)"
[ -z "$stale_help" ] || fail "stale L006 severity-gate claim still shipped in: $stale_help"

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
grep -q "^inbound_probe" "$REPO_ROOT/plugins/notify/hermes/plugin.conf" \
  && fail "plugins/notify/hermes declares an inbound probe, but hermes.md documents (and the hermes CLI supports) no inbound-liveness query"
