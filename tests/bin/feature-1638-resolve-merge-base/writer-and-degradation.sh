# ============================================================================
# The writer — write-once, the branching-HEAD contract, and the approval path
# ============================================================================

r14_record_is_write_once() {
  local repo first second sid="sid-r14"
  repo="$(repo_with_main)"
  node_state init "$sid" "$repo" work >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  first="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" base 2>/dev/null)"
  # A new commit changes what a SECOND record call would compute, so an overwrite is visible.
  commit_file "$repo" fourth.txt 1 fourth
  node_state record "$sid" "$repo" >/dev/null
  second="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" base 2>/dev/null)"
  if [ -n "$first" ] && [ "$first" != "NONE" ] && [ "$first" != "undefined" ]; then
    check "R14: a second automatic record does not overwrite the first" "$first" "$second"
  else
    fail "R14: the first record produced no base -- got [$first] (recordMergeBaseBaseline not implemented?)"
  fi
}

r15_base_is_branching_head() {
  local repo head mb recorded sid="sid-r15"
  repo="$(repo_with_main)"
  head="$(git -C "$repo" rev-parse HEAD)"
  mb="$(git -C "$repo" merge-base main HEAD)"
  node_state init "$sid" "$repo" work >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  recorded="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" base 2>/dev/null)"
  check "R15-head: the recorded base is the HEAD at branching time" "$head" "$recorded"
  if [ "$head" = "$mb" ]; then
    fail "R15-fixture: the fixture is not ahead of main, so the row asserts nothing"
  elif [ -z "$recorded" ] || [ "$recorded" = "NONE" ] || [ "$recorded" = "undefined" ]; then
    fail "R15-remote: nothing was recorded, so the row cannot distinguish the two candidates"
  elif [ "$recorded" = "$mb" ]; then
    fail "R15-remote: the recorded base is a remote-derived merge-base -- the withdrawn ahead_count branch is back"
  else
    pass "R15-remote: and NOT the merge-base against the default branch"
  fi
}

r16_approve_overrides_write_once() {
  local repo other src reason sid="sid-r16"
  repo="$(repo_with_main)"
  node_state init "$sid" "$repo" work >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  other="$(git -C "$repo" rev-parse HEAD~1)"
  node_state approve "$sid" "$repo" "$other" "confirmed by the user during run-tests" >/dev/null
  check "R16-base: an approved base overwrites the write-once record" "$other" \
    "$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" base 2>/dev/null)"
  src="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" source 2>/dev/null)"
  check "R16-source: and is labelled as the user's decision" "user-approved" "$src"
  reason="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" approved_reason 2>/dev/null)"
  check_match "R16-reason: with the reason kept for audit" "confirmed by the user" "$reason"
}

r17_approve_rejects_bad_base() {
  local repo before side rc sid="sid-r17"
  repo="$(repo_with_main)"
  node_state init "$sid" "$repo" work >/dev/null
  node_state record "$sid" "$repo" >/dev/null
  before="$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" base 2>/dev/null)"

  rc=0
  env "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$RECORD_CLI" --session "$sid" \
    --base 0000000000000000000000000000000000000000 --reason "nonexistent sha" \
    --repo "$repo" >/dev/null 2>&1 || rc=$?
  check "R17-missing: a sha that does not resolve is refused" "1" "$rc"

  side="$(side_commit "$repo")"
  rc=0
  env "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$RECORD_CLI" --session "$sid" \
    --base "$side" --reason "not an ancestor" --repo "$repo" >/dev/null 2>&1 || rc=$?
  check "R17-ancestor: a sha that is not an ancestor of HEAD is refused" "1" "$rc"

  check "R17-intact: and neither refusal touched the stored baseline" "$before" \
    "$(env "AGENTS_DIR=$AGENTS_DIR" "CLAUDE_WORKFLOW_DIR=$WFDIR" node "$STATE_JS" field "$sid" base 2>/dev/null)"
}

# ============================================================================
# Diagnostics and the degradation contract
# ============================================================================

r18_explain_goes_to_stderr() {
  local repo cand missing=""
  repo="$(repo_with_main)"
  HELPER_ENV=()
  run_helper "$repo" - --explain
  for cand in "recorded-baseline" "origin/main" "main" "HEAD~1" "safe"; do
    printf '%s\n' "$HB_ERR" | grep -qF -- "$cand" || missing="$missing [$cand]"
  done
  check "R18-candidates: --explain lists every candidate on stderr" "" "$missing"
  check_match "R18-stdout: and stdout is still the ordinary kv output" '^[A-Z]+$' "$(kv state)"
  if printf '%s\n' "$HB_OUT" | grep -qE '^\[resolve-merge-base\]'; then
    fail "R18-clean: the diagnostic block leaked into stdout -- [$HB_OUT]"
  else
    pass "R18-clean: the diagnostic block never reaches stdout"
  fi
}

r19_standalone_copy_still_works() {
  local repo lone rc=0 out
  repo="$(repo_with_main)"
  lone="$(mktemp -d "$TMPROOT/lone.XXXXXX")"
  if [ ! -f "$HELPER" ]; then
    fail "R19: bin/resolve-merge-base.sh does not exist, so the standalone copy cannot be made"
    return
  fi
  cp "$HELPER" "$lone/resolve-merge-base.sh"
  out="$(env "MERGE_BASE_MAX_DIFF_LINES=1" "MERGE_BASE_MAX_DIFF_FILES=500" \
    bash "$lone/resolve-merge-base.sh" -C "$repo" --no-fetch --format kv 2>/dev/null)" || rc=$?
  check "R19-rc: a copy with no sibling scripts still exits 0" "0" "$rc"
  check "R19-state: and the env-var threshold still takes effect" "SUSPECT" \
    "$(printf '%s\n' "$out" | sed -n 's/^state=//p' | head -1)"
  # #1779: base_is_head is derived from git alone, so it must survive the same amputation as
  # the rest of the kv block. A field that only appears when the sibling scripts are present
  # would be absent in exactly the fixture (fix-quality-gates-not-found) that copies one file.
  if printf '%s\n' "$out" | grep -qE '^base_is_head='; then
    pass "R19-base_is_head: the standalone copy still reports base_is_head"
  else
    fail "R19-base_is_head: no base_is_head= line in the standalone copy's kv output
--- output ---
$out"
  fi
}

