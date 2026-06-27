#!/usr/bin/env bash
# Tests: bin/cc-session-title
# Tags: scope:issue-specific
# T12-T17: CLI smoke tests, session ID resolution, CLAUDE_PROJECT_DIR

# ===========================================================================
# T12: bin/cc-session-title set-issue CLI smoke test
# ===========================================================================
run_t12() {
  local tmp_bash="$TMPDIR_BASE/t12"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t12-session-abc"
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

- #77: CLI smoke test
"

  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID
    CLAUDE_SESSION_ID="$sid" CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" set-issue "$tmp_node" "$plans_node" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#77 CLI smoke test" ]; then
    pass "T12: bin/cc-session-title set-issue CLI smoke test"
  else
    fail "T12: bin/cc-session-title set-issue (got: '$title', expected: '#77 CLI smoke test')"
  fi
}

# ===========================================================================
# T13: bin/cc-session-title add-pr CLI smoke test
# ===========================================================================
run_t13() {
  local tmp_bash="$TMPDIR_BASE/t13"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t13-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_jsonl_with_title "$jsonl_bash" "$sid" "#88 some issue"

  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID
    CLAUDE_SESSION_ID="$sid" CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" add-pr "$tmp_node" "999" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#88 some issue PR #999" ]; then
    pass "T13: bin/cc-session-title add-pr CLI smoke test"
  else
    fail "T13: bin/cc-session-title add-pr (got: '$title', expected: '#88 some issue PR #999')"
  fi
}

# ===========================================================================
# T14: bin/cc-session-title mark-complete CLI smoke test
# ===========================================================================
run_t14() {
  local tmp_bash="$TMPDIR_BASE/t14"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t14-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_jsonl_with_title "$jsonl_bash" "$sid" "#55 completed task PR #101"

  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID
    CLAUDE_SESSION_ID="$sid" CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" mark-complete "$tmp_node" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "✓ #55 completed task PR #101" ]; then
    pass "T14: bin/cc-session-title mark-complete CLI smoke test"
  else
    fail "T14: bin/cc-session-title mark-complete (got: '$title', expected: '✓ #55 completed task PR #101')"
  fi
}

# ===========================================================================
# T15: CLAUDE_ENV_FILE resolution → correct session ID used
# ===========================================================================
run_t15() {
  local tmp_bash="$TMPDIR_BASE/t15"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t15-session-abc"
  local env_file_bash="$tmp_bash/claude.env"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local env_file_node
  env_file_node=$(to_node_path "$env_file_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #33: Env file resolution test
"
  # Write env file with session ID
  printf "CLAUDE_SESSION_ID=%s\n" "$sid" > "$env_file_bash"

  (
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID
    CLAUDE_ENV_FILE="$env_file_node" CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" set-issue "$tmp_node" "$plans_node" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#33 Env file resolution test" ]; then
    pass "T15: CLAUDE_ENV_FILE resolution → correct session ID"
  else
    fail "T15: CLAUDE_ENV_FILE resolution (got: '$title', expected: '#33 Env file resolution test')"
  fi
}

# ===========================================================================
# T16: Both CLAUDE_ENV_FILE and CLAUDE_SESSION_ID absent → mtime JSONL fallback
# ===========================================================================
run_t16() {
  local tmp_bash="$TMPDIR_BASE/t16"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t16-fallback-sid"
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

- #44: Mtime fallback test
"
  # Create a JSONL file with the session ID as the filename (mtime-based discovery)
  # The file just needs to exist; the session ID is derived from the filename
  touch "$jsonl_bash"

  (
    cd "$tmp_bash"  # cd away from worktree so WORKTREE_NOTES.md is not found by resolveSessionId step 6
    unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_SESSION_ID
    CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node "$BIN_CC_SESSION_TITLE" set-issue "$tmp_node" "$plans_node" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#44 Mtime fallback test" ]; then
    pass "T16: Both absent → mtime JSONL fallback picks correct session ID"
  else
    fail "T16: mtime JSONL fallback (got: '$title', expected: '#44 Mtime fallback test')"
  fi
}

# ===========================================================================
# T17: CLAUDE_PROJECT_DIR set → JSONL in correct encoded dir
# ===========================================================================
run_t17() {
  local tmp_bash="$TMPDIR_BASE/t17"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t17-session-abc"
  local project_dir_bash="$tmp_bash/project"
  local other_cwd_bash="$tmp_bash/other-cwd"
  local project_dir_node
  project_dir_node=$(to_node_path "$project_dir_bash")
  local other_cwd_node
  other_cwd_node=$(to_node_path "$other_cwd_bash")
  local plans_node
  plans_node=$(to_node_path "$plans_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")

  # The JSONL should be at transcript/<encoded(project_dir)>/<sid>.jsonl
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$project_dir_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #66: Project dir encoding test
"
  mkdir -p "$project_dir_bash"
  mkdir -p "$other_cwd_bash"

  # Pass other_cwd as cwd but CLAUDE_PROJECT_DIR overrides encoding
  (
    unset CLAUDE_CODE_CHILD_SESSION
    CLAUDE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR="$project_dir_node" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node" \
      run_with_timeout 10 node -e "
const m = require('$SESSION_TITLE_LIB');
m.writeSetIssue('$sid', '$other_cwd_node', '$plans_node');
" 2>/dev/null || true
  )

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#66 Project dir encoding test" ]; then
    pass "T17: CLAUDE_PROJECT_DIR set → JSONL in correct encoded dir"
  else
    fail "T17: CLAUDE_PROJECT_DIR encoding (got: '$title' in $jsonl_bash, expected: '#66 Project dir encoding test')"
  fi
}

run_t12
run_t13
run_t14
run_t15
run_t16
run_t17
