#!/usr/bin/env bash
# Tests: bin/cc-session-title, hooks/lib/session-title.js, skills/clarify-intent/SKILL.md, hooks/stop-session-title-waiting.js, hooks/user-prompt-clear-waiting.js, hooks/pre-askuserquestion-clear-waiting.js
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

# ===========================================================================
# T-new2: Static contract — skills/clarify-intent/SKILL.md contains a call to
#         cc-session-title set-issue (CI-C1a step). Fails before write-code adds it.
# ===========================================================================
run_tnew2() {
  local skill_md="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    fail "T-new2: skills/clarify-intent/SKILL.md not found at $skill_md"
    return
  fi
  if grep -q "cc-session-title set-issue" "$skill_md" 2>/dev/null; then
    pass "T-new2: SKILL.md contains 'cc-session-title set-issue' call (CI-C1a present)"
  else
    fail "T-new2: SKILL.md missing 'cc-session-title set-issue' (CI-C1a not yet added by write-code)"
  fi
}

# ===========================================================================
# T-new3: Static contract — NON_GITHUB guard appears near the set-issue call
#         in SKILL.md. The guard must prevent the call on non-GitHub repos,
#         mirroring the Path A (workflow-init A1a) guard already in place.
#         Verifies that "NON_GITHUB" is mentioned within the context of the
#         cc-session-title set-issue call (within 20 lines of it).
# ===========================================================================
run_tnew3() {
  local skill_md="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
  if [ ! -f "$skill_md" ]; then
    fail "T-new3: skills/clarify-intent/SKILL.md not found"
    return
  fi
  # Find the line number of "cc-session-title set-issue" in SKILL.md
  local line_num
  line_num=$(grep -n "cc-session-title set-issue" "$skill_md" 2>/dev/null | head -1 | cut -d: -f1 || true)
  if [ -z "$line_num" ]; then
    fail "T-new3: 'cc-session-title set-issue' not found in SKILL.md — cannot check NON_GITHUB guard context"
    return
  fi
  # Extract 20 lines before and after the set-issue call and check for NON_GITHUB
  local start=$(( line_num - 20 ))
  [ "$start" -lt 1 ] && start=1
  local end=$(( line_num + 20 ))
  if sed -n "${start},${end}p" "$skill_md" 2>/dev/null | grep -q "NON_GITHUB" 2>/dev/null; then
    pass "T-new3: NON_GITHUB guard found within 20 lines of 'cc-session-title set-issue' in SKILL.md"
  else
    fail "T-new3: NON_GITHUB guard NOT found near 'cc-session-title set-issue' in SKILL.md (write-code must add the guard)"
  fi
}

# ===========================================================================
# T-new4: Static absence — writeWaiting and writeClearWaiting functions are
#         removed from hooks/lib/session-title.js. These were for the retired
#         ⏳ waiting-indicator lifecycle that couldn't work in the CC hook model.
# ===========================================================================
run_tnew4() {
  local session_title_js="$AGENTS_DIR/hooks/lib/session-title.js"
  if [ ! -f "$session_title_js" ]; then
    fail "T-new4: hooks/lib/session-title.js not found"
    return
  fi
  if grep -qE "writeWaiting|writeClearWaiting" "$session_title_js" 2>/dev/null; then
    local count
    count=$(grep -E "writeWaiting|writeClearWaiting" "$session_title_js" 2>/dev/null | wc -l)
    fail "T-new4: writeWaiting/writeClearWaiting still present in hooks/lib/session-title.js ($count occurrences — write-code must remove them)"
  else
    pass "T-new4: writeWaiting and writeClearWaiting NOT present in hooks/lib/session-title.js (removed by write-code)"
  fi
}

# ===========================================================================
# T-new5: Static absence — write-waiting and clear-waiting CLI subcommands are
#         removed from bin/cc-session-title. These depended on the removed
#         writeWaiting/writeClearWaiting functions.
# ===========================================================================
run_tnew5() {
  local cc_bin="$AGENTS_DIR/bin/cc-session-title"
  if [ ! -f "$cc_bin" ]; then
    fail "T-new5: bin/cc-session-title not found"
    return
  fi
  if grep -qE "write-waiting|clear-waiting" "$cc_bin" 2>/dev/null; then
    local count
    count=$(grep -E "write-waiting|clear-waiting" "$cc_bin" 2>/dev/null | wc -l)
    fail "T-new5: write-waiting/clear-waiting still present in bin/cc-session-title ($count occurrences — write-code must remove them)"
  else
    pass "T-new5: write-waiting and clear-waiting NOT present in bin/cc-session-title (removed by write-code)"
  fi
}

# ===========================================================================
# T-new6: Static absence — 3 orphan hook files that depended on the retired
#         writeWaiting/writeClearWaiting functions must NOT exist on disk.
#         write-code deletes them as part of the cleanup.
# ===========================================================================
run_tnew6() {
  local existing_files=""

  for hook_file in \
    "$AGENTS_DIR/hooks/stop-session-title-waiting.js" \
    "$AGENTS_DIR/hooks/user-prompt-clear-waiting.js" \
    "$AGENTS_DIR/hooks/pre-askuserquestion-clear-waiting.js"
  do
    if [ -e "$hook_file" ]; then
      existing_files="$existing_files $(basename "$hook_file")"
    fi
  done

  if [ -z "$existing_files" ]; then
    pass "T-new6: All 3 orphan hook files absent (stop-session-title-waiting.js, user-prompt-clear-waiting.js, pre-askuserquestion-clear-waiting.js)"
  else
    fail "T-new6: Orphan hook files still exist (write-code must delete them):$existing_files"
  fi
}

run_t12
run_t13
run_t14
run_t15
run_t16
run_t17
run_tnew2
run_tnew3
run_tnew4
run_tnew5
run_tnew6
