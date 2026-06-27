#!/usr/bin/env bash
# Tests: hooks/lib/session-title.js
# Tags: scope:issue-specific
# T1-T11: writeSetIssue, writeAddPr, writeMarkComplete, subagent guard

# ===========================================================================
# T1: writeSetIssue single issue → "#N title" JSONL entry
# ===========================================================================
run_t1() {
  local tmp_bash="$TMPDIR_BASE/t1"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t1-session-abc"
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

- #42: Fix login bug
"

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#42 Fix login bug" ]; then
    pass "T1: writeSetIssue single issue → '#N title'"
  else
    fail "T1: writeSetIssue single issue (got: '$title', expected: '#42 Fix login bug')"
  fi
}

# ===========================================================================
# T2: writeSetIssue multi-issue → "#N1 #N2 title-of-first"
# ===========================================================================
run_t2() {
  local tmp_bash="$TMPDIR_BASE/t2"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t2-session-abc"
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

- #10: First issue title
- #20: Second issue title
"

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#10 #20 First issue title" ]; then
    pass "T2: writeSetIssue multi-issue → '#N1 #N2 title-of-first'"
  else
    fail "T2: writeSetIssue multi-issue (got: '$title', expected: '#10 #20 First issue title')"
  fi
}

# ===========================================================================
# T3: writeSetIssue missing intent.md → no write
# ===========================================================================
run_t3() {
  local tmp_bash="$TMPDIR_BASE/t3"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t3-session-abc"
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

  mkdir -p "$plans_bash"
  # No intent.md

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  if [ ! -f "$jsonl_bash" ]; then
    pass "T3: writeSetIssue missing intent.md → no write"
  else
    local count
    count=$(count_title_records "$jsonl_node" "$sid")
    if [ "$count" = "0" ]; then
      pass "T3: writeSetIssue missing intent.md → no write"
    else
      fail "T3: writeSetIssue missing intent.md: expected no write, got $count records"
    fi
  fi
}

# ===========================================================================
# T4: writeSetIssue empty ## Issues section → no write
# ===========================================================================
run_t4() {
  local tmp_bash="$TMPDIR_BASE/t4"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t4-session-abc"
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

## Background

No issues listed.
"

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  if [ ! -f "$jsonl_bash" ]; then
    pass "T4: writeSetIssue empty ## Issues → no write"
  else
    local count
    count=$(count_title_records "$jsonl_node" "$sid")
    if [ "$count" = "0" ]; then
      pass "T4: writeSetIssue empty ## Issues → no write"
    else
      fail "T4: writeSetIssue empty ## Issues: expected no write, got $count records"
    fi
  fi
}

# ===========================================================================
# T5: writeAddPr appends "PR #N" to existing title
# ===========================================================================
run_t5() {
  local tmp_bash="$TMPDIR_BASE/t5"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t5-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_jsonl_with_title "$jsonl_bash" "$sid" "#42 Fix login bug"

  call_lib_fn "$transcript_node" "m.writeAddPr('$sid', '$tmp_node', '123');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "#42 Fix login bug PR #123" ]; then
    pass "T5: writeAddPr appends 'PR #N' to existing title"
  else
    fail "T5: writeAddPr (got: '$title', expected: '#42 Fix login bug PR #123')"
  fi
}

# ===========================================================================
# T6: writeAddPr idempotent (second call no-op)
# ===========================================================================
run_t6() {
  local tmp_bash="$TMPDIR_BASE/t6"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t6-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_jsonl_with_title "$jsonl_bash" "$sid" "#42 Fix login bug"

  # First call
  call_lib_fn "$transcript_node" "m.writeAddPr('$sid', '$tmp_node', '123');"
  # Second call (should be no-op)
  call_lib_fn "$transcript_node" "m.writeAddPr('$sid', '$tmp_node', '123');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  # Should have exactly 2 records: original + one add-pr (second is no-op)
  if [ "$title" = "#42 Fix login bug PR #123" ] && [ "$count" = "2" ]; then
    pass "T6: writeAddPr idempotent (second call no-op, count=2)"
  else
    fail "T6: writeAddPr idempotent (title='$title', count=$count, expected title='#42 Fix login bug PR #123', count=2)"
  fi
}

# ===========================================================================
# T7: writeAddPr no prior title → writes "PR #N"
# ===========================================================================
run_t7() {
  local tmp_bash="$TMPDIR_BASE/t7"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t7-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")
  # No prior JSONL

  call_lib_fn "$transcript_node" "m.writeAddPr('$sid', '$tmp_node', '456');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "PR #456" ]; then
    pass "T7: writeAddPr no prior title → writes 'PR #N'"
  else
    fail "T7: writeAddPr no prior (got: '$title', expected: 'PR #456')"
  fi
}

# ===========================================================================
# T8: writeMarkComplete prepends "✓ "
# ===========================================================================
run_t8() {
  local tmp_bash="$TMPDIR_BASE/t8"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t8-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_jsonl_with_title "$jsonl_bash" "$sid" "#42 Fix login bug PR #123"

  call_lib_fn "$transcript_node" "m.writeMarkComplete('$sid', '$tmp_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "✓ #42 Fix login bug PR #123" ]; then
    pass "T8: writeMarkComplete prepends '✓ '"
  else
    fail "T8: writeMarkComplete (got: '$title', expected: '✓ #42 Fix login bug PR #123')"
  fi
}

# ===========================================================================
# T9: writeMarkComplete idempotent
# ===========================================================================
run_t9() {
  local tmp_bash="$TMPDIR_BASE/t9"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t9-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  make_jsonl_with_title "$jsonl_bash" "$sid" "#42 Fix login bug"

  # First call
  call_lib_fn "$transcript_node" "m.writeMarkComplete('$sid', '$tmp_node');"
  # Second call (should be no-op)
  call_lib_fn "$transcript_node" "m.writeMarkComplete('$sid', '$tmp_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  if [ "$title" = "✓ #42 Fix login bug" ] && [ "$count" = "2" ]; then
    pass "T9: writeMarkComplete idempotent (count=2, second call no-op)"
  else
    fail "T9: writeMarkComplete idempotent (title='$title', count=$count)"
  fi
}

# ===========================================================================
# T10: writeMarkComplete no prior title → writes "✓"
# ===========================================================================
run_t10() {
  local tmp_bash="$TMPDIR_BASE/t10"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t10-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  call_lib_fn "$transcript_node" "m.writeMarkComplete('$sid', '$tmp_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "✓" ]; then
    pass "T10: writeMarkComplete no prior title → writes '✓'"
  else
    fail "T10: writeMarkComplete no prior (got: '$title', expected: '✓')"
  fi
}

# ===========================================================================
# T11: CLAUDE_CODE_CHILD_SESSION=1 → skip all writes
# ===========================================================================
run_t11() {
  local tmp_bash="$TMPDIR_BASE/t11"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t11-session-abc"
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

- #99: Child session test
"

  # All three functions should be no-ops when CLAUDE_CODE_CHILD_SESSION=1
  (
    CLAUDE_CODE_CHILD_SESSION="1"
    export CLAUDE_CODE_CHILD_SESSION
    CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node"
    export CLAUDE_TRANSCRIPT_BASE_DIR
    run_with_timeout 10 node -e "
const m = require('$SESSION_TITLE_LIB');
m.writeSetIssue('$sid', '$tmp_node', '$plans_node');
m.writeAddPr('$sid', '$tmp_node', '42');
m.writeMarkComplete('$sid', '$tmp_node');
" 2>/dev/null || true
  )

  if [ ! -f "$jsonl_bash" ]; then
    pass "T11: CLAUDE_CODE_CHILD_SESSION=1 → skip all writes"
  else
    local count
    count=$(count_title_records "$jsonl_node" "$sid")
    if [ "$count" = "0" ]; then
      pass "T11: CLAUDE_CODE_CHILD_SESSION=1 → skip all writes"
    else
      fail "T11: CLAUDE_CODE_CHILD_SESSION=1 expected no writes, got $count records"
    fi
  fi
}

run_t1
run_t2
run_t3
run_t4
run_t5
run_t6
run_t7
run_t8
run_t9
run_t10
run_t11
