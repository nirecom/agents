#!/usr/bin/env bash
# Tests: hooks/lib/session-title.js
# Tags: scope:issue-specific
# T26/T28/T29: writeSetIssue overwrite-guard behavior over null / bare "⏳" / extension
#              "⏳<non-space>" temp form, and preservation of the "⏳ <title>" space form.
#
# The ⏳ "waiting" indicator feature was retired (#299): UserPromptSubmit fires after the
# message is sent, so "⏳ on session open" is impossible in the CC hook model. The waiting
# lifecycle cases (former T23/T24/T25/T27) were removed. What remains is the writeSetIssue
# skip-guard, which must overwrite the leftover sentinel/extension temp forms with the real
# issue title while preserving genuine titles.

# ===========================================================================
# T26: writeSetIssue with existing bare "⏳" sentinel → writes issue title (overrides)
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

  # Pre-seed JSONL with bare "⏳" sentinel
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
    pass "T26: writeSetIssue with bare '⏳' → writes issue title (overrides sentinel)"
  else
    fail "T26: writeSetIssue overrides bare sentinel (title='$title' expected '#42 Fix login bug', count=$count expected 2)"
  fi
}

# ===========================================================================
# T28: writeSetIssue with extension temp form "⏳<non-space>" → OVERWRITE (the bug fix)
# This is the production failure: the VS Code extension rewrites our bare "⏳" into
# "⏳<ai-title>" (⏳ glued to the ai-title with no space). The old skip-guard
# `existing !== "⏳"` then treated it as a real title and skipped the issue write,
# so the issue # title was never displayed. The fixed guard overwrites it.
# ===========================================================================
run_t28() {
  local tmp_bash="$TMPDIR_BASE/t28"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t28-session-abc"
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

  # Pre-seed JSONL with the extension's temp form: "⏳" glued to ai-title, no space.
  make_jsonl_with_title "$jsonl_bash" "$sid" "⏳#299-re session title"

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #299: re session title
"

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  if [ "$title" = "#299 re session title" ] && [ "$count" = "2" ]; then
    pass "T28: writeSetIssue overwrites extension temp '⏳<non-space>' form (bug fix)"
  else
    fail "T28: writeSetIssue overwrite extension temp form (title='$title' expected '#299 re session title', count=$count expected 2)"
  fi
}

# ===========================================================================
# T29: writeSetIssue with our own "⏳ <title>" space form → PRESERVE (negative case)
# Guards against the fixed regex `/^⏳\S/` over-matching: the space form has a space
# right after ⏳, so \S does not match and the title is preserved (no overwrite).
# ===========================================================================
run_t29() {
  local tmp_bash="$TMPDIR_BASE/t29"
  local plans_bash="$tmp_bash/plans"
  local transcript_bash="$tmp_bash/transcript"
  local sid="t29-session-abc"
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

  # Pre-seed JSONL with the space form "⏳ <title>" (our own former waiting prefix).
  make_jsonl_with_title "$jsonl_bash" "$sid" "⏳ #299 already-waiting"

  make_intent "$plans_bash" "$sid" "# Intent

## Issues

- #299: re session title
"

  call_lib_fn "$transcript_node" "m.writeSetIssue('$sid', '$tmp_node', '$plans_node');"

  local title
  title=$(read_last_title "$jsonl_node" "$sid")
  local count
  count=$(count_title_records "$jsonl_node" "$sid")
  if [ "$title" = "⏳ #299 already-waiting" ] && [ "$count" = "1" ]; then
    pass "T29: writeSetIssue preserves '⏳ <title>' space form (negative — no overwrite)"
  else
    fail "T29: writeSetIssue space-form preservation (title='$title' expected '⏳ #299 already-waiting', count=$count expected 1)"
  fi
}

run_t26
run_t28
run_t29
