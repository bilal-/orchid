#!/usr/bin/env bash
fm_get() {
  awk -v k="$2" '/^---$/{n++;next} n==1 && index($0,k": ")==1{print substr($0,length(k)+3);exit} n>=2{exit}' "$1"
}
# fm_set (v1-m3, m2 ledger F9): the second n==1 rule below catches a key
# whose CURRENT line is bare "key:" (no trailing space, no value) --
# templates/task.md seeds exactly that for base_sha, candidate_sha,
# started_at, etc. Without it, that line matches neither this rule nor the
# "key: "-prefixed one above, so it falls through to `{ print }` untouched
# and a SECOND "key: value" line gets appended at the closing '---' instead
# -- a silently accumulating duplicate (fm_get still reads correctly, since
# it takes the first match and only the appended line ever matches, but the
# file itself rots). Both rules are scoped to n==1 (between the two '---'
# delimiters), so body text is never touched even if it looks like a key line.
fm_set() {
  local f="$1" k="$2" v="$3"
  awk -v k="$k" -v v="$v" '
    /^---$/ { n++; if (n==2 && !done) { print k ": " v; done=1 }; print; next }
    n==1 && index($0,k": ")==1 { print k ": " v; done=1; next }
    n==1 && $0==k":" { print k ": " v; done=1; next }
    { print }' "$f" | atomic_write "$f"
}
