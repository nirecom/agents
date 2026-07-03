# shellcheck shell=bash
# Case groups A and B: STRIP_KINDS extension + isSentinelEchoSafe.
# Sourced by fix-416-classify-sentinel-reason-text.sh; relies on helpers from common.sh.
# Tests execute inline on dot-source (no function wrapper).

echo "=== fix-416: classify() STRIP_KINDS + isSentinelEchoSafe ==="
echo ""
echo "--- Group A: STRIP_KINDS extension (pkg-mgr, gh) ---"

# T3.1: grep scans for "npm install" text in a docs file → read (after fix)
assert_classify \
  "T3.1 grep npm install in docs" \
  'grep -n "npm install" docs/foo.md' \
  "read"

# T3.2: grep scans for "pnpm add foo" text → read
assert_classify \
  "T3.2 grep pnpm add in file" \
  'grep -n "pnpm add foo" file.md' \
  "read"

# T3.3: grep scans for "pip install pytest" text → read
assert_classify \
  "T3.3 grep pip install in notes" \
  'grep -n "pip install pytest" notes.md' \
  "read"

# T3.4: grep scans for "uv pip install" text → read
assert_classify \
  "T3.4 grep uv pip install in docs" \
  'grep -n "uv pip install" docs/x.md' \
  "read"

# T3.5: grep scans for "gh pr merge 123" text → read
assert_classify \
  "T3.5 grep gh pr merge in docs" \
  'grep -n "gh pr merge 123" docs/y.md' \
  "read"

# T3.6: grep scans for "gh issue delete 1" text → read
assert_classify \
  "T3.6 grep gh issue delete in file" \
  'grep -n "gh issue delete 1" file.md' \
  "read"

# T3.7: grep scans for "gh api -X DELETE foo" text → read
assert_classify \
  "T3.7 grep gh api DELETE in file" \
  'grep -n "gh api -X DELETE foo" file.md' \
  "read"

# T3.8: echo describes npm install in prose → read
assert_classify \
  "T3.8 echo npm install in prose" \
  'echo "Run npm install first"' \
  "read"

# T3.9: echo describes gh pr merge in prose → read
assert_classify \
  "T3.9 echo gh pr merge in prose" \
  'echo "Then gh pr merge --squash"' \
  "read"

echo ""
echo "--- Group B: isSentinelEchoSafe (safe sentinel reasons → read) ---"

# T3.10: strict DQ sentinel with safe reason containing "npm install" → read
# isSentinelEchoSafe: reason text is safe (no $, `, ;, |, >) → early-return read.
assert_classify \
  "T3.10 sentinel RESEARCH_NOT_NEEDED with npm install in reason" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: npm install handled>>"' \
  "read"

# T3.11: sentinel WRITE_TESTS_NOT_NEEDED with "gh pr merge done" in reason → read
assert_classify \
  "T3.11 sentinel WRITE_TESTS_NOT_NEEDED with gh pr merge in reason" \
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: gh pr merge done>>"' \
  "read"

# T3.12: sentinel BRANCHING_COMPLETE with "bash -c stuff" in reason → read
assert_classify \
  "T3.12 sentinel BRANCHING_COMPLETE with bash -c in reason" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch:bash -c stuff>>"' \
  "read"

# T3.13: sentinel USER_VERIFIED with "rm -rf cleanup" as reason text → read
# The rm is in the REASON FIELD (inside the sentinel), not an actual command.
# isSentinelEchoSafe: rm in reason text without ; $ ` | > shell metacharacters → safe.
assert_classify \
  "T3.13 sentinel USER_VERIFIED with rm -rf in reason text" \
  'echo "<<WORKFLOW_USER_VERIFIED: rm -rf cleanup>>"' \
  "read"

# T3.13b: MARK_STEP sentinel (no reason field) → read
assert_classify \
  "T3.13b sentinel MARK_STEP write_code_complete (no reason)" \
  'echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"' \
  "read"

# T3.13c: RESET_FROM sentinel (with reason field) → read
assert_classify \
  "T3.13c sentinel RESET_FROM research (with reason)" \
  'echo "<<WORKFLOW_RESET_FROM_research: test reason>>"' \
  "read"

echo ""
echo "--- Group B2: isSentinelEchoSafe — chars safe in DQ context (after 3-char narrowing) ---"
echo "    WILL FAIL until write-code narrows UNSAFE_REASON_CHARS from 11 to 3 chars"

# T3.13d: BRANCHING_COMPLETE with | separator and POSIX path → read
# Canonical sentinel form per WF-CODE-3: branch:...|worktree:...|main
assert_classify \
  "T3.13d sentinel BRANCHING_COMPLETE with | separator and POSIX worktree path → read" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: fix/416-narrow|worktree: /home/u/wt/agents|main>>"' \
  "read"

# T3.13e: BRANCHING_COMPLETE with | separator and Windows backslash path → read
# \ before > is NOT a bash escape sequence; safe in DQ context
assert_classify \
  "T3.13e sentinel BRANCHING_COMPLETE with | separator and Windows path → read" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: fix/416-narrow|worktree: C:\git\worktrees\416\agents>>"' \
  "read"

# T3.13g: USER_VERIFIED with semicolon-separated prose → read
# ; is literal inside DQ; no injection possible
assert_classify \
  "T3.13g sentinel USER_VERIFIED with semicolon prose → read" \
  'echo "<<WORKFLOW_USER_VERIFIED: docs-only edit; no behavior change>>"' \
  "read"

# T3.13h: USER_VERIFIED with Windows backslash path → read
# \ before non-expansion char (g) is literal in DQ
assert_classify \
  "T3.13h sentinel USER_VERIFIED with Windows backslash path → read" \
  'echo "<<WORKFLOW_USER_VERIFIED: path C:\git\agents normalised>>"' \
  "read"
