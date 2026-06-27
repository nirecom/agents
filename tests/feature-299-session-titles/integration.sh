#!/usr/bin/env bash
# Tests: hooks/session-start.js, hooks/lib/session-title.js, skills/clarify-intent/SKILL.md
# Tags: scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Whether cc-session-title set-issue is actually invoked at runtime during a real clarify-intent session
# - Whether NON_GITHUB and closes_issues guards work correctly in a live Claude session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
# T18a/T18b: real session-start.js hook execution (writeSetIssue wired; writeClearWaiting NOT called)
# T19-T22: skip guard, cwd-constrained mtime fallback

# ===========================================================================
# T18a: REAL hooks/session-start.js execution — writeSetIssue is wired and writes the title.
# Runs the actual hook with piped stdin {"session_id","transcript_path"} so the title-write
# block is exercised end-to-end. Catches: hook syntax errors, broken require/wiring of
# writeSetIssue, and a missing intent.md → title resolution. (Review C1 (ii)(iii).)
# ===========================================================================
run_t18a() {
  local tmp_bash="$TMPDIR_BASE/t18a"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local workflow_bash="$tmp_bash/workflow"
  local sid="t18a-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local workflow_node
  workflow_node=$(to_node_path "$workflow_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  mkdir -p "$workflow_bash"
  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #11: Session start integration test
"
  # Pre-create the (empty) fixture JSONL — transcript_path points here.
  touch "$jsonl_bash"

  # Run the REAL hook. transcript_path → CLAUDE_SESSION_JSONL_PATH inside the hook →
  # _getJsonlPath resolves to this fixture JSONL. Other hook side-effects
  # (cleanupZombies, oracle spawn, additionalContext) fail-open in the fixture env.
  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_ENV_FILE CLAUDE_SESSION_ID CLAUDE_PROJECT_DIR
    printf '%s' "{\"session_id\":\"$sid\",\"transcript_path\":\"$jsonl_node\"}" | \
      CLAUDE_WORKFLOW_DIR="$workflow_node" WORKFLOW_PLANS_DIR="$plans_node" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 20 node "$SESSION_START_HOOK" >/dev/null 2>&1 || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#11 Session start integration test" ]; then
    pass "T18a: real session-start.js → writeSetIssue wired, title written to JSONL"
  else
    fail "T18a: real session-start.js (got: '$title', expected: '#11 Session start integration test')"
  fi
}

# ===========================================================================
# T18b: REAL hooks/session-start.js execution — writeClearWaiting is NOT called (regression).
# Pre-seed the extension temp form "⏳<non-space>". After the real hook runs:
#   (1) the title must be overwritten with the issue title (writeSetIssue fired), AND
#   (2) the LAST record must NOT be the empty-string "" unset record that
#       writeClearWaiting writes. A surviving writeClearWaiting call would append a
#       blank-title record after writeSetIssue, leaving an empty last title.
# Catches Review C1 (i): the hook still importing/calling writeClearWaiting.
# ===========================================================================
run_t18b() {
  local tmp_bash="$TMPDIR_BASE/t18b"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local workflow_bash="$tmp_bash/workflow"
  local sid="t18b-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local workflow_node
  workflow_node=$(to_node_path "$workflow_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  mkdir -p "$workflow_bash"
  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #11: Session start integration test
"
  # Pre-seed the extension temp form (⏳ glued to ai-title, no space).
  make_jsonl_with_title "$jsonl_bash" "$sid" "⏳#11 Session start integration test"

  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_ENV_FILE CLAUDE_SESSION_ID CLAUDE_PROJECT_DIR
    printf '%s' "{\"session_id\":\"$sid\",\"transcript_path\":\"$jsonl_node\"}" | \
      CLAUDE_WORKFLOW_DIR="$workflow_node" WORKFLOW_PLANS_DIR="$plans_node" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 20 node "$SESSION_START_HOOK" >/dev/null 2>&1 || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  # Assertion 1: overwrite occurred. Assertion 2: last record is not the empty
  # unset record (would be left by a surviving writeClearWaiting call).
  if [ -n "$title" ] && [ "$title" = "#11 Session start integration test" ]; then
    pass "T18b: real session-start.js → overwrite occurred AND no empty writeClearWaiting record"
  else
    fail "T18b: real session-start.js writeClearWaiting regression (got: '$title', expected: '#11 Session start integration test', non-empty)"
  fi
}

# ===========================================================================
# T19: Skip guard: writeSetIssue called twice → only first write (preserves PR#/✓)
# ===========================================================================
run_t19() {
  local tmp_bash="$TMPDIR_BASE/t19"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t19-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #22: Skip guard test
"

  # First call: writes "#22 Skip guard test"
  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"
  # Add PR suffix
  call_lib_fn "$transcript_node" "m.writeAddPr('$sid', '$tmp_node', '55');"
  # Second writeSetIssue call: should be no-op (title already exists)
  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  # Last record should still be "#22 Skip guard test PR #55" (second writeSetIssue was no-op)
  if [ "$title" = "#22 Skip guard test PR #55" ]; then
    pass "T19: Skip guard: writeSetIssue called twice → preserves subsequent PR#"
  else
    fail "T19: Skip guard (got: '$title', expected: '#22 Skip guard test PR #55')"
  fi
}

# ===========================================================================
# T20: Skip guard: title has "PR #N" suffix → writeSetIssue is no-op
# ===========================================================================
run_t20() {
  local tmp_bash="$TMPDIR_BASE/t20"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t20-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #33: Will be overwritten test
"
  # Pre-existing title with PR suffix
  make_jsonl_with_title "$jsonl_bash" "$sid" "#33 Already set PR #77"

  # writeSetIssue should be no-op (title already exists)
  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  if [ "$title" = "#33 Already set PR #77" ] && [ "$count" = "1" ]; then
    pass "T20: Skip guard: title has 'PR #N' suffix → writeSetIssue is no-op"
  else
    fail "T20: Skip guard PR suffix (title='$title', count=$count, expected '#33 Already set PR #77', count=1)"
  fi
}

# ===========================================================================
# T21: cwd-constrained mtime fallback: picks intent from current cwd only (not other repos)
# ===========================================================================
run_t21() {
  local tmp_bash="$TMPDIR_BASE/t21"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid_a="t21-session-repo-a"
  local sid_b="t21-session-repo-b"
  local cwd_a_bash="$tmp_bash/repo-a"
  local cwd_b_bash="$tmp_bash/repo-b"
  local cwd_a_node
  cwd_a_node=$(to_node_path "$cwd_a_bash")
  local cwd_b_node
  cwd_b_node=$(to_node_path "$cwd_b_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")

  local tdir_a_bash
  tdir_a_bash=$(make_transcript_dir "$transcript_bash" "$cwd_a_node")
  local tdir_b_bash
  tdir_b_bash=$(make_transcript_dir "$transcript_bash" "$cwd_b_node")
  local jsonl_a_bash="$tdir_a_bash/${sid_a}.jsonl"
  local jsonl_b_bash="$tdir_b_bash/${sid_b}.jsonl"
  local jsonl_a_node
  jsonl_a_node=$(to_node_path "$jsonl_a_bash")
  local jsonl_b_node
  jsonl_b_node=$(to_node_path "$jsonl_b_bash")

  mkdir -p "$cwd_a_bash" "$cwd_b_bash"
  # Create JSONL for both repos
  touch "$jsonl_a_bash"
  touch "$jsonl_b_bash"

  # Make repo-b's JSONL newer (to confirm it's not picked for repo-a queries)
  node -e "
const fs = require('fs');
const t = (Date.now() - 500) / 1000;
fs.utimesSync('$jsonl_b_node', t, t);
const t2 = (Date.now() - 2000) / 1000;
fs.utimesSync('$jsonl_a_node', t2, t2);
" 2>/dev/null

  make_intent "$plans_bash" "$sid_a" "# Intent

## Issues

- #111: Repo A issue
"
  make_intent "$plans_bash" "$sid_b" "# Intent

## Issues

- #222: Repo B issue
"

  # Call from repo-a cwd → should pick sid_a (from repo-a's transcript dir), not sid_b
  (
    cd "$cwd_a_bash"  # cd away from worktree so WORKTREE_NOTES.md is not found; mtime scan uses cwd_a's dir
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_SESSION_ID
    CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" set-issue "$cwd_a_node" "$plans_node" 2>/dev/null || true
  )

  local title_a
  title_a=$(read_last_title "$jsonl_a_node" "$sid_a")
  local title_b
  title_b=$(read_last_title "$jsonl_b_node" "$sid_b")

  if [ "$title_a" = "#111 Repo A issue" ] && [ -z "$title_b" ]; then
    pass "T21: cwd-constrained mtime fallback: picks intent from current cwd only (not other repos)"
  else
    fail "T21: cwd-constrained mtime fallback (title_a='$title_a', title_b='$title_b', expected title_a='#111 Repo A issue', title_b='')"
  fi
}

# ===========================================================================
# T22: Mtime fallback: priorId-intent.md present, newId absent → writes from prior intent
# ===========================================================================
run_t22() {
  local tmp_bash="$TMPDIR_BASE/t22"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local prior_sid="t22-prior-session"
  local new_sid="t22-new-session"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_prior_bash="$tdir_bash/${prior_sid}.jsonl"
  local jsonl_new_bash="$tdir_bash/${new_sid}.jsonl"
  local jsonl_prior_node
  jsonl_prior_node=$(to_node_path "$jsonl_prior_bash")

  # Both JSONL files exist; prior_sid is newer (mtime scan will pick it)
  touch "$jsonl_prior_bash"
  touch "$jsonl_new_bash"

  node -e "
const fs = require('fs');
const newer = (Date.now() - 500) / 1000;
const older = (Date.now() - 5000) / 1000;
fs.utimesSync('$jsonl_prior_node', newer, newer);
fs.utimesSync('$(to_node_path "$jsonl_new_bash")', older, older);
" 2>/dev/null

  # Only prior_sid has an intent.md
  make_intent "$plans_bash" "$prior_sid" "# Intent

## Issues

- #55: Prior session issue
"
  # new_sid has no intent.md

  # Mtime scan picks prior_sid (newer), which has intent.md
  (
    cd "$tmp_bash"  # cd away from worktree so WORKTREE_NOTES.md is not found by resolveSessionId step 6
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_SESSION_ID
    CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" set-issue "$tmp_node" "$plans_node" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_prior_node" "$prior_sid")
  if [ "$title" = "#55 Prior session issue" ]; then
    pass "T22: Mtime fallback: priorId-intent.md present, newId absent → writes from prior intent"
  else
    fail "T22: Mtime fallback prior intent (got: '$title', expected: '#55 Prior session issue')"
  fi
}

# ===========================================================================
# T-new1: Path B regression — CLI set-issue writes "#N title" when no prior
#         custom-title exists (null case). Validates the core Path B fix:
#         SKILL.md CI-C1a calling cc-session-title set-issue at the end of
#         clarify-intent ensures the title is written even when session-start.js
#         fired before intent.md was populated.
# ===========================================================================
run_tnew1() {
  local tmp_bash="$TMPDIR_BASE/tnew1"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="tnew1-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #299: Path B null regression
"
  # No pre-seed — the Path B scenario: intent.md wasn't ready when session-start.js
  # ran, so no custom-title was written by session-start.js. After CI-4 writes
  # intent.md, SKILL.md CI-C1a (cc-session-title set-issue) must now write the
  # issue title for the first time.
  touch "$jsonl_bash"

  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID
    CLAUDE_SESSION_ID="$sid" CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" set-issue "$tmp_node" "$plans_node" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#299 Path B null regression" ]; then
    pass "T-new1: Path B null regression — CLI set-issue writes '#N title' when no prior custom-title"
  else
    fail "T-new1: Path B null regression (got: '$title', expected: '#299 Path B null regression')"
  fi
}


run_t18a
run_t18b
run_t19
run_t20
run_t21
run_t22
run_tnew1
