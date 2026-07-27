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

echo 'not json' > "$WORK/e.json"
envelope_validate "$WORK/e.json" 2>/dev/null && fail "non-JSON rejected"
printf '{"status":"ok","value":"test"}' > "$WORK/f.json"
assert_eq "ok" "$(envelope_field "$WORK/f.json" .status)" "field read"
