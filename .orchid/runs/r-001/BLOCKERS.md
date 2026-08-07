# Blockers

## q-4-df78 (task: T001)
attempts exhausted: final review found linked-worktree trust bypasses; unauthorized attempt 4 stopped
nonce: 0adf68218c0d876b
reply: ORCHID_REPO="/Users/bilal/workspace/personal/orchid-orchid" orchid answer q-4-df78 <choice> --nonce 0adf68218c0d876b

## q-4-2711 (task: T004)
attempts exhausted: final review found remaining macOS find portability and file-wide ShellCheck suppression defects
nonce: 099e960d63f4bbe5
reply: ORCHID_REPO="/Users/bilal/workspace/personal/orchid-orchid" orchid answer q-4-2711 <choice> --nonce 099e960d63f4bbe5

## q-25-605a
--list
nonce: 2d89e22d9eefdc32
reply: ORCHID_REPO="/Users/bilal/workspace/personal/orchid-orchid" orchid answer q-25-605a <choice> --nonce 2d89e22d9eefdc32

## q-32-09f5 (task: T002)
T002 review round 4: both slots request-changes again. Attempt 8 passed the full suite (4th green) and fixed everything from round 3, but a NEW high landed: drive_implementing is missing the liveness guard its sibling arms have, so a failed implementer spawns duplicate concurrent implementers into one worktree. 8 attempts, 4 review rounds, each finding real defects in a DIFFERENT subsystem of a 6-feature task. T003 and T005 have not started. Choose: split = land the driver core now and move broker/boundary/hooks to follow-on tasks with their own budgets (recommended); continue = dispatch attempt 9 as-is; accept = merge now and record remaining findings as ledger items.
nonce: e16bde11aff26d47
reply: ORCHID_REPO="/Users/bilal/workspace/personal/orchid-orchid" orchid answer q-32-09f5 <choice> --nonce e16bde11aff26d47

## q-33-1e9f (task: T003)
T003 round 3: agy approve (3rd generic one-liner), claude request-changes with 3 findings — ALL THREE LOST. The claude review adapter asks review replies for a VERDICT line only; FINDING: lines are requested by the critique prompt alone, so findings[] is always empty and rationale survives only if the model happens to put it in prose. That has now cost real information 3 times today, and T005 (the release gate) is next. Two decisions: (1) FIX THE ADAPTER first - one-line prompt change to plugins/engines/claude/run so review replies emit FINDING: lines, as a small task before T005; or CARRY ON and keep losing findings. (2) T005 SCOPE - it bundles a qualification harness, checklist, multi-repo fixtures and evidence recording at high risk. That is the T002 shape that cost 8 attempts. SPLIT it into 2-3 tasks, or dispatch AS-IS. Recommend: fix-adapter + split. Reply with e.g. 'fix-adapter-split' or 'carry-on-asis'.
nonce: de893cb8cb0f1e89
reply: ORCHID_REPO="/Users/bilal/workspace/personal/orchid-orchid" orchid answer q-33-1e9f <choice> --nonce de893cb8cb0f1e89

## q-33-ed9d
Gateway restart test — the hermes gateway was DOWN all day, which is why your earlier phone reply never arrived (outbound worked, inbound had no listener). It is running now. Reply to this one from your phone to prove the return leg works; if it lands I will see it and say so. Also answers the open question: T005 scope, split or as-is. Reply 'split' or 'asis' (or anything, I just need to see it arrive).
nonce: 6b9413fa86fd5d87
reply: ORCHID_REPO="/Users/bilal/workspace/personal/orchid-orchid" orchid answer q-33-ed9d <choice> --nonce 6b9413fa86fd5d87
