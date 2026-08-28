#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
source "$REPO_ROOT/lib/envelope.sh"
good() { cat > "$WORK/e.json"; envelope_validate "$WORK/e.json"; }
bad()  { cat > "$WORK/e.json"; if envelope_validate "$WORK/e.json" 2>/dev/null; then return 1; fi; }

good <<'EOF' || fail "implement ok accepted"
{"contract":1,"job_id":"j-1","task":"T001","operation":"implement","status":"ok","summary":"did work"}
EOF
good <<'EOF' || fail "review ok accepted"
{"contract":1,"job_id":"j-2","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true}
EOF
bad <<'EOF' || fail "review ok without verdict rejected"
{"contract":1,"job_id":"j-3","task":"T001","operation":"review","status":"ok"}
EOF
bad <<'EOF' || fail "implement ok without summary rejected"
{"contract":1,"job_id":"j-4","task":"T001","operation":"implement","status":"ok"}
EOF
good <<'EOF' || fail "failed status needs no payload"
{"contract":1,"job_id":"j-5","task":"T001","operation":"review","status":"failed"}
EOF
bad <<'EOF' || fail "missing job_id rejected"
{"contract":1,"task":"T001","operation":"implement","status":"ok","summary":"x"}
EOF
bad <<'EOF' || fail "ok status with unknown operation rejected (null-operation escape closed)"
{"contract":1,"job_id":"j-6","task":"T001","operation":"research","status":"ok"}
EOF
bad <<'EOF' || fail "ok status with absent operation rejected (null-operation escape closed)"
{"contract":1,"job_id":"j-7","task":"T001","status":"ok"}
EOF

good <<'EOF' || fail "findings array with valid objects accepted"
{"contract":1,"job_id":"j-8","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"findings":[{"severity":"minor","title":"nit"}]}
EOF
good <<'EOF' || fail "empty findings array accepted"
{"contract":1,"job_id":"j-9","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"findings":[]}
EOF
bad <<'EOF' || fail "findings not an array rejected"
{"contract":1,"job_id":"j-10","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"findings":{"severity":"minor","title":"nit"}}
EOF
bad <<'EOF' || fail "findings item missing title rejected"
{"contract":1,"job_id":"j-11","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"findings":[{"severity":"minor"}]}
EOF
bad <<'EOF' || fail "findings item severity wrong type rejected"
{"contract":1,"job_id":"j-12","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"findings":[{"severity":1,"title":"nit"}]}
EOF
good <<'EOF' || fail "commits array of strings accepted"
{"contract":1,"job_id":"j-13","task":"T001","operation":"implement","status":"ok","summary":"did work","commits":["abc123","def456"]}
EOF
good <<'EOF' || fail "empty commits array accepted"
{"contract":1,"job_id":"j-14","task":"T001","operation":"implement","status":"ok","summary":"did work (no commits produced)","commits":[]}
EOF
bad <<'EOF' || fail "commits not an array rejected"
{"contract":1,"job_id":"j-15","task":"T001","operation":"implement","status":"ok","summary":"did work","commits":"abc123"}
EOF
bad <<'EOF' || fail "commits item non-string rejected"
{"contract":1,"job_id":"j-16","task":"T001","operation":"implement","status":"ok","summary":"did work","commits":[123]}
EOF
good <<'EOF' || fail "findings and commits optional together on non-ok status too"
{"contract":1,"job_id":"j-17","task":"T001","operation":"review","status":"failed","findings":[],"commits":[]}
EOF

# failure_kind (v1-m5 T008): optional, a known value, and only on an envelope
# that actually reports a failure. lib/ledger.sh spares a `capability` refusal
# its consecutive-failure charge, so an unrecognized or incoherent value must
# be quarantined rather than guessed at.
good <<'EOF' || fail "failure_kind capability on a failed envelope accepted"
{"contract":1,"job_id":"j-18","task":"T001","operation":"review","status":"failed","failure_kind":"capability"}
EOF
good <<'EOF' || fail "failure_kind engine on a malformed envelope accepted"
{"contract":1,"job_id":"j-19","task":"T001","operation":"review","status":"malformed","failure_kind":"engine"}
EOF
good <<'EOF' || fail "absent failure_kind still accepted (every pre-T008 adapter and fixture)"
{"contract":1,"job_id":"j-20","task":"T001","operation":"review","status":"failed"}
EOF
bad <<'EOF' || fail "unknown failure_kind value rejected"
{"contract":1,"job_id":"j-21","task":"T001","operation":"review","status":"failed","failure_kind":"whatever"}
EOF
bad <<'EOF' || fail "failure_kind on an ok envelope rejected (nothing to classify)"
{"contract":1,"job_id":"j-22","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"failure_kind":"capability"}
EOF
bad <<'EOF' || fail "failure_kind of the wrong type rejected"
{"contract":1,"job_id":"j-23","task":"T001","operation":"review","status":"failed","failure_kind":true}
EOF

echo 'not json' > "$WORK/e.json"
envelope_validate "$WORK/e.json" 2>/dev/null && fail "non-JSON rejected"
printf '{"status":"ok","value":"test"}' > "$WORK/f.json"
assert_eq "ok" "$(envelope_field "$WORK/f.json" .status)" "field read"

# ---------------------------------------------------------------------------
# T033 (dogfood F32): the summary-excerpt and prose-only-objection helpers.
# Their end-to-end behaviour is proven where it bites -- tests/test_jobs.sh
# files a prose-only objection through `jobs reconcile`, and
# tests/test_review_routing.sh folds one through drive_review_decision's
# record -- so these unit cases pin only the edges neither suite reaches:
# the truncation marker, each boundary of the objection predicate on its
# own, and the composed entry's exact fields.
# ---------------------------------------------------------------------------

# Truncation. The whitespace fold is exercised end-to-end elsewhere; the cut
# is not, and it is what keeps a boundary record bounded when a reviewer's
# summary is a paragraph.
jq -n '{summary: ("x" * 200)}' > "$WORK/long.json"
x160="$(jq -rn '"x" * 160')"
x170="$(jq -rn '"x" * 170')"
assert_eq "$x160..." "$(envelope_summary_excerpt "$WORK/long.json")" \
  "a summary over the 160-char default is cut there and marked with an ellipsis"
assert_eq "$x170..." "$(envelope_summary_excerpt "$WORK/long.json" 170)" \
  "a caller's own max wins over the default"
jq -n '{summary: "short"}' > "$WORK/short.json"
assert_eq "short" "$(envelope_summary_excerpt "$WORK/short.json")" \
  "a summary under the max passes through whole, no marker"
jq -n '{status: "ok"}' > "$WORK/nosum.json"
assert_eq "" "$(envelope_summary_excerpt "$WORK/nosum.json")" \
  "no summary, no excerpt"

# The predicate, one boundary at a time. `objection` expects a match,
# `no_objection` expects none -- same shape as good/bad above.
objection()    { cat > "$WORK/po.json"; envelope_prose_only_objection "$WORK/po.json"; }
no_objection() { cat > "$WORK/po.json"; if envelope_prose_only_objection "$WORK/po.json"; then return 1; fi; }

objection <<'EOF' || fail "an ok review withholding approval over an empty findings[] is the F32 shape"
{"contract":1,"job_id":"j-t33-1","task":"T001","operation":"review","status":"ok","verdict":"request-changes","scope_complete":true,"summary":"the objection","findings":[]}
EOF
objection <<'EOF' || fail "absent findings reports exactly as much as an empty array, and a critique counts like a review"
{"contract":1,"job_id":"j-t33-2","task":"T001","operation":"critique","status":"ok","verdict":"request-changes","scope_complete":true,"summary":"the objection"}
EOF
no_objection <<'EOF' || fail "an approving review with an empty findings[] is the verdict-only adapters' ordinary output, never matched"
{"contract":1,"job_id":"j-t33-3","task":"T001","operation":"review","status":"ok","verdict":"approve","scope_complete":true,"summary":"caveat kept in prose","findings":[]}
EOF
no_objection <<'EOF' || fail "a non-approve review that filed its own finding needs nothing lifted"
{"contract":1,"job_id":"j-t33-4","task":"T001","operation":"review","status":"ok","verdict":"request-changes","scope_complete":true,"summary":"the objection","findings":[{"severity":"medium","title":"filed by the reviewer"}]}
EOF
no_objection <<'EOF' || fail "a failed slot is the residue of an errored launch -- it carries no judgment to lift"
{"contract":1,"job_id":"j-t33-5","task":"T001","operation":"review","status":"failed","verdict":"request-changes","findings":[]}
EOF
# T040's salvage writes exactly this shape when a dead job's log held a
# VERDICT line and no FINDING lines. It is the KERNEL's reconstruction of a
# job that never filed a judgment, not a reviewer's filed objection, and
# composing a `high` out of it would put gate-blocking weight on a scrape.
no_objection <<'EOF' || fail "a salvaged no_envelope review is the kernel's own reconstruction -- nothing is synthesized into it"
{"contract":1,"job_id":"j-t33-5b","task":"T001","operation":"review","status":"no_envelope","verdict":"request-changes","degraded":true,"findings":[]}
EOF
no_objection <<'EOF' || fail "verdict means nothing on an implement envelope, so it is never matched"
{"contract":1,"job_id":"j-t33-6","task":"T001","operation":"implement","status":"ok","summary":"did work","verdict":"request-changes"}
EOF
no_objection <<'EOF' || fail "a review with no verdict at all has withheld nothing -- there is no objection to lift"
{"contract":1,"job_id":"j-t33-7","task":"T001","operation":"review","status":"ok","summary":"prose only","findings":[]}
EOF

# The composed entry, field by field.
cat > "$WORK/syn.json" <<'EOF'
{"contract":1,"job_id":"j-t33-8","task":"T001","operation":"review","status":"ok","verdict":"request-changes","scope_complete":true,"summary":"the whole objection","findings":[]}
EOF
envelope_synthesize_finding "$WORK/syn.json" > "$WORK/syn.out"
envelope_validate "$WORK/syn.out" \
  || fail "the composed envelope must itself validate -- reconcile refuses the synthesis otherwise and files the original untouched"
assert_eq "1" "$(jq '.findings | length' "$WORK/syn.out")" "exactly one composed finding"
assert_eq "high" "$(jq -r '.findings[0].severity' "$WORK/syn.out")" \
  "composed at high -- the one severity no blocking_severity filters out"
assert_eq "synthesized from summary: the whole objection" "$(jq -r '.findings[0].title' "$WORK/syn.out")" \
  "the title says on its face that the kernel composed it"
assert_eq "true" "$(jq -r '.findings[0].synthesized' "$WORK/syn.out")" "the entry is marked synthesized"
assert_eq "$ENVELOPE_SYNTHESIZED_FINDING_SOURCE" "$(jq -r '.findings[0].source' "$WORK/syn.out")" \
  "the entry names its source constant"
assert_eq "the whole objection" "$(jq -r '.findings[0].detail' "$WORK/syn.out")" \
  "the summary survives whole in detail"
assert_eq "the whole objection" "$(jq -r '.summary' "$WORK/syn.out")" \
  "the reviewer's own summary is left exactly as written"
assert_eq "0" "$(jq '.findings | length' "$WORK/syn.json")" \
  "synthesize prints and writes nothing: the input file is untouched"

# An objection filed with neither findings nor a summary still yields an
# entry: the absence itself is what the gate must be told.
cat > "$WORK/syn2.json" <<'EOF'
{"contract":1,"job_id":"j-t33-9","task":"T001","operation":"review","status":"ok","verdict":"request-changes","scope_complete":true,"findings":[]}
EOF
envelope_synthesize_finding "$WORK/syn2.json" > "$WORK/syn2.out"
envelope_validate "$WORK/syn2.out" \
  || fail "a no-summary objection must still compose a valid envelope, not a title validation rejects"
assert_eq "synthesized from summary: a non-approve verdict filed with no findings[] and no summary" \
  "$(jq -r '.findings[0].title' "$WORK/syn2.out")" \
  "with nothing to carry, the entry says exactly that instead of handing the gate a silent empty array again"
