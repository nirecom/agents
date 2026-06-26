#!/usr/bin/env bash
# Tests: hooks/lib/session-title.js
# Tags: scope:issue-specific
# T23-T27: null-title sentinel behavior (writeWaiting/writeClearWaiting/writeMarkComplete/writeSetIssue)

# ===========================================================================
# T23: writeWaiting with no prior title → writes "⏳" sentinel
# ===========================================================================
run_t23() {
  local tmp_bash="$TMPDIR_BASE/t23"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t23-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  # No JSONL pre-created — no prior title
  call_lib_fn "$transcript_node" "m.writeWaiting('$sid', '$tmp_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "⏳" ]; then
    pass "T23: writeWaiting no prior title → writes '⏳' sentinel"
  else
    fail "T23: writeWaiting no prior title (got: '$title', expected: '⏳')"
  fi
}

# ===========================================================================
# T24: writeClearWaiting("⏳") → writes "" unset record; _readCurrentTitle returns null;
#      subsequent writeWaiting sees null and writes "⏳" again
# ===========================================================================
run_t24() {
  local tmp_bash="$TMPDIR_BASE/t24"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t24-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  # Pre-seed JSONL with ⏳ sentinel record
  make_jsonl_with_title "$jsonl_bash" "$sid" "⏳"

  # writeClearWaiting should write "" (unset) record
  call_lib_fn "$transcript_node" "m.writeClearWaiting('$sid', '$tmp_node');"

  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  if [ "$count" != "2" ]; then
    fail "T24: writeClearWaiting should append a record (count=$count, expected 2)"
    return
  fi

  # _readCurrentTitle should return null (empty → null in source)
  local result
  result=$(
    unset CLAUDE_CODE_CHILD_SESSION 2>/dev/null || true
    CLAUDE_TRANSCRIPT_BASE_DIR="$transcript_node"
    export CLAUDE_TRANSCRIPT_BASE_DIR
    run_with_timeout 10 node -e "
const m = require('$SESSION_TITLE_LIB');
const r = m._readCurrentTitle('$sid', '$tmp_node');
process.stdout.write(r === null ? '__NULL__' : String(r));
" 2>/dev/null || echo "__ERROR__"
  )

  if [ "$result" != "__NULL__" ]; then
    fail "T24: _readCurrentTitle after writeClearWaiting('⏳') should be null (got: '$result')"
    return
  fi

  # writeWaiting again → should see null and write "⏳" (total 3 records)
  call_lib_fn "$transcript_node" "m.writeWaiting('$sid', '$tmp_node');"

  local count2
  count2=$(count_title_records "$jsonl_node" "$sid")
  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$count2" = "3" ] && [ "$title" = "⏳" ]; then
    pass "T24: writeClearWaiting('⏳') → unset record + null; subsequent writeWaiting writes '⏳' again"
  else
    fail "T24: writeClearWaiting+writeWaiting (count=$count2 expected 3, title='$title' expected '⏳')"
  fi
}

# ===========================================================================
# T25: writeMarkComplete on "⏳" sentinel → writes "✓" (no base, no trailing space)
# ===========================================================================
run_t25() {
  local tmp_bash="$TMPDIR_BASE/t25"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t25-session-abc"
  local tmp_node
  tmp_node=$(to_node_path "$tmp_bash")
  local transcript_node
  transcript_node=$(to_node_path "$transcript_bash")
  local tdir_bash
  tdir_bash=$(make_transcript_dir "$transcript_bash" "$tmp_node")
  local jsonl_bash="$tdir_bash/${sid}.jsonl"
  local jsonl_node
  jsonl_node=$(to_node_path "$jsonl_bash")

  # Pre-seed JSONL with ⏳ sentinel
  make_jsonl_with_title "$jsonl_bash" "$sid" "⏳"

  call_lib_fn "$transcript_node" "m.writeMarkComplete('$sid', '$tmp_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title" = "✓" ]; then
    pass "T25: writeMarkComplete('⏳') → writes '✓' (no base, no trailing space)"
  else
    fail "T25: writeMarkComplete on sentinel (got: '$title', expected: '✓')"
  fi
}

# ===========================================================================
# T26: writeSetIssue with existing "⏳" sentinel → writes issue title (overrides sentinel)
# ===========================================================================
run_t26() {
  local tmp_bash="$TMPDIR_BASE/t26"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t26-session-abc"
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

  # Pre-seed JSONL with ⏳ sentinel (written by writeWaiting before intent.md existed)
  make_jsonl_with_title "$jsonl_bash" "$sid" "⏳"

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #42: Fix login bug
"

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  if [ "$title" = "#42 Fix login bug" ] && [ "$count" = "2" ]; then
    pass "T26: writeSetIssue with existing '⏳' sentinel → writes issue title (overrides sentinel)"
  else
    fail "T26: writeSetIssue overrides sentinel (title='$title' expected '#42 Fix login bug', count=$count expected 2)"
  fi
}

# ===========================================================================
# T27: Integration — null-start lifecycle
# No intent.md → writeWaiting → "⏳" → create intent.md → writeSetIssue → "#42 Fix login bug"
# → writeWaiting → "⏳ #42 Fix login bug"
# ===========================================================================
run_t27() {
  local tmp_bash="$TMPDIR_BASE/t27"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t27-session-abc"
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

  # Step 1: writeSetIssue with no intent.md → no write (JSONL doesn't exist)
  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local count_after_step1
  count_after_step1=$(count_title_records "$jsonl_node" "$sid")
  if [ "$count_after_step1" != "0" ]; then
    fail "T27: Step 1 writeSetIssue with no intent.md should not write (count=$count_after_step1)"
    return
  fi

  # Step 2: writeWaiting → null title → writes "⏳"
  call_lib_fn "$transcript_node" "m.writeWaiting('$sid', '$tmp_node');"

  local title_step2
  title_step2=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title_step2" != "⏳" ]; then
    fail "T27: Step 2 writeWaiting should write '⏳' (got: '$title_step2')"
    return
  fi

  # Step 3: create intent.md with #42
  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #42: Fix login bug
"

  # Step 4: writeSetIssue → sees "⏳" → writes "#42 Fix login bug"
  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title_step4
  title_step4=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title_step4" != "#42 Fix login bug" ]; then
    fail "T27: Step 4 writeSetIssue should write '#42 Fix login bug' (got: '$title_step4')"
    return
  fi

  # Step 5: writeWaiting → sees "#42 Fix login bug" → writes "⏳ #42 Fix login bug"
  call_lib_fn "$transcript_node" "m.writeWaiting('$sid', '$tmp_node');"

  # Step 6: read_last_title → expect "⏳ #42 Fix login bug"
  local title_final
  title_final=$(read_last_title "$jsonl_node" "$sid")
  if [ "$title_final" = "⏳ #42 Fix login bug" ]; then
    pass "T27: Integration null-start lifecycle → final title '⏳ #42 Fix login bug'"
  else
    fail "T27: Integration null-start lifecycle (got: '$title_final', expected: '⏳ #42 Fix login bug')"
  fi
}

run_t23
run_t24
run_t25
run_t26
run_t27
