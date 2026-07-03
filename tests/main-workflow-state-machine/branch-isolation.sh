# shellcheck shell=bash
# Case group: Section 5 — Branch Isolation.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.

run_branch_isolation_tests() {
    # ---------------------------------------------------------------------------
    # Section 5: Branch Isolation
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 5: Branch Isolation ==="

    # Setup: two states for the same cwd, different branches
    CWD_5="/users/test/repo-branch-$$"
    ENC_5=$(encode_path "$CWD_5")
    HOME_5="$TMPDIR_BASE/home-5"
    mkdir -p "$HOME_5/.claude/projects/$ENC_5"

    SID_5_MAIN="l5-main-$(printf '%04x%04x' $RANDOM $RANDOM)"
    SID_5_FEAT="l5-feat-$(printf '%04x%04x' $RANDOM $RANDOM)"

    # main state: research=complete only (outline=pending distinguishes it from feature/x)
    write_state "$SID_5_MAIN" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_5_MAIN", "git_branch": "main",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":           {"status": "pending",  "updated_at": null},
    "detail":            {"status": "pending",  "updated_at": null},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
    # feature/x state: research+outline+detail=complete
    write_state "$SID_5_FEAT" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_5_FEAT", "git_branch": "feature/x",
  "created_at": "$NOW_ISO",
  "steps": {
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "outline":           {"status": "complete", "updated_at": "$NOW_ISO"},
    "detail":            {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
    write_transcript_line "$HOME_5/.claude/projects/$ENC_5/main-${SID_5_MAIN}.jsonl" \
        "$SID_5_MAIN" "$(to_node_path "$WORKFLOW_DIR/${SID_5_MAIN}.json")"
    write_transcript_line "$HOME_5/.claude/projects/$ENC_5/feat-${SID_5_FEAT}.jsonl" \
        "$SID_5_FEAT" "$(to_node_path "$WORKFLOW_DIR/${SID_5_FEAT}.json")"

    # L5-a: query main → returns main state (outline=pending, not feature/x's outline=complete)
    RESULT_5A=$(call_find_latest "$CWD_5" "main" "$HOME_5")
    PLAN_5A=$(get_json_step_status "$RESULT_5A" "outline")
    if [ "$PLAN_5A" = "pending" ]; then
        pass "L5-a. query main → main state (outline=pending, not feature/x outline=complete)"
    else
        fail "L5-a. query main — expected outline=pending (main), got: $PLAN_5A (result: $RESULT_5A)"
    fi

    # L5-b: query feature/x → returns feature/x state (outline=complete, not main's outline=pending)
    RESULT_5B=$(call_find_latest "$CWD_5" "feature/x" "$HOME_5")
    PLAN_5B=$(get_json_step_status "$RESULT_5B" "outline")
    if [ "$PLAN_5B" = "complete" ]; then
        pass "L5-b. query feature/x → feature/x state (outline=complete)"
    else
        fail "L5-b. query feature/x — expected outline=complete, got: $PLAN_5B (result: $RESULT_5B)"
    fi

    # L5-c: detached HEAD (git_branch=null) query → does NOT match main state (branch mismatch)
    HOME_5C="$TMPDIR_BASE/home-5c"
    CWD_5C="/users/test/repo-detached-$$"
    ENC_5C=$(encode_path "$CWD_5C")
    mkdir -p "$HOME_5C/.claude/projects/$ENC_5C"
    SID_5C="l5c-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_5C" "$(INHERIT_STATE_JSON "$SID_5C" "main")"
    write_transcript_line "$HOME_5C/.claude/projects/$ENC_5C/${SID_5C}.jsonl" \
        "$SID_5C" "$(to_node_path "$WORKFLOW_DIR/${SID_5C}.json")"
    RESULT_5C=$(call_find_latest "$CWD_5C" "null" "$HOME_5C")
    if [ "$RESULT_5C" = "null" ] || [ -z "$RESULT_5C" ]; then
        pass "L5-c. detached HEAD (git_branch=null) query → null (no match with main state)"
    else
        fail "L5-c. detached HEAD → expected null, got: $RESULT_5C"
    fi

    # L5-d: security — CLAUDE_PROJECT_DIR with shell metacharacters → no command injection, no crash
    # getCurrentContext calls: git -C JSON.stringify(cwd) rev-parse --abbrev-ref HEAD
    # On Windows (cmd.exe), $(...) syntax is not expanded, so this is safe.
    PWNED_MARKER="$TMPDIR_BASE/L5d-pwned.txt"
    # Build injection path with literal $() in the dirname (bash does not expand \$)
    INJECTION_PATH="${TMPDIR_BASE}/repo-l5d-\$(touch ${PWNED_MARKER})-$$"
    SID_5D="l5d-$(printf '%04x%04x' $RANDOM $RANDOM)"
    ENV_5D="$TMPDIR_BASE/5d.env"
    L5D_EXIT=0
    echo "{\"session_id\":\"$SID_5D\"}" | \
        CLAUDE_PROJECT_DIR="$INJECTION_PATH" CLAUDE_ENV_FILE="$ENV_5D" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || L5D_EXIT=$?
    if [ "$L5D_EXIT" = "0" ]; then
        pass "L5-d(exit). shell metachar in CLAUDE_PROJECT_DIR → exit 0 (no crash)"
    else
        fail "L5-d(exit). shell metachar → unexpected non-zero exit: $L5D_EXIT"
    fi
    if [ ! -f "$PWNED_MARKER" ]; then
        pass "L5-d(security). shell metachar → no command injection (pwned file not created)"
    else
        fail "L5-d(security). INJECTION DETECTED — $PWNED_MARKER was created"
        rm -f "$PWNED_MARKER"
    fi
}
