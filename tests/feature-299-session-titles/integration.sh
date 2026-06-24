#!/usr/bin/env bash
# Tests: hooks/session-start.js, hooks/lib/session-title.js
# Tags: scope:issue-specific
# T18-T22: session-start integration, skip guard, mtime fallback

# ===========================================================================
# T18: session-start.js integration — intent.md present → title written to JSONL
# ===========================================================================
run_t18() {
  local tmp_bash="$TMPDIR_BASE/t18"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local workflow_bash="$tmp_bash/workflow"
  local sid="t18-session-abc"
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
  # Pre-create the JSONL file
  touch "$jsonl_bash"

  # Simulate the session-start.js title-write block exactly as Step 3 specifies:
  # "After the existing writeState block, add writeSetIssue call"
  (
    unset CLAUDE_CODE_CHILD_SESSION
    CLAUDE_WORKFLOW_DIR="$workflow_node" WORKFLOW_PLANS_DIR="$plans_node" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 15 node -e "
const sessionId = '$sid';
const cwd = '$tmp_node';
if (sessionId) {
  try {
    const { writeSetIssue } = require('$SESSION_TITLE_LIB');
    const plansDir = process.env.WORKFLOW_PLANS_DIR;
    writeSetIssue(sessionId, cwd, plansDir);
  } catch (e) {
    // fail-open
  }
}
" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#11 Session start integration test" ]; then
    pass "T18: session-start.js integration: intent.md present → title written to JSONL"
  else
    fail "T18: session-start.js integration (got: '$title', expected: '#11 Session start integration test')"
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
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_ENV_FILE CLAUDE_SESSION_ID
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
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_ENV_FILE CLAUDE_SESSION_ID
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

run_t18
run_t19
run_t20
run_t21
run_t22
