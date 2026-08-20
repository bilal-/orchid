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
