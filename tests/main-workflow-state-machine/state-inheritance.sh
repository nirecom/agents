# shellcheck shell=bash
# Case group: Section 1 — State Inheritance.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.

run_state_inheritance_tests() {
    # ---------------------------------------------------------------------------
    # Section 1: State Inheritance
    # (Smoke — details in tests/feature-workflow-inherit-state.sh)
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 1: State Inheritance ==="

    # L1-a: transcript + state with research=complete → findLatestStateForContext returns it
    CWD_1A="/users/test/repo-l1a-$$"
    ENC_1A=$(encode_path "$CWD_1A")
    HOME_1A="$TMPDIR_BASE/home-1a"
    mkdir -p "$HOME_1A/.claude/projects/$ENC_1A"
    SID_1A="l1a-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1A" "$(INHERIT_STATE_JSON "$SID_1A" "main")"
    write_transcript_line "$HOME_1A/.claude/projects/$ENC_1A/${SID_1A}.jsonl" \
        "$SID_1A" "$(to_node_path "$WORKFLOW_DIR/${SID_1A}.json")"
    RESULT_1A=$(call_find_latest "$CWD_1A" "main" "$HOME_1A")
    RESEARCH_1A=$(get_json_step_status "$RESULT_1A" "research")
    if [ "$RESEARCH_1A" = "complete" ]; then
        pass "L1-a. transcript + research=complete state → inherited research=complete"
    else
        fail "L1-a. inheritance smoke — expected research=complete, got: $RESEARCH_1A (result: $RESULT_1A)"
    fi

    # L1-b: state with user_verification=complete → NOT inherited (break out of search)
    HOME_1B="$TMPDIR_BASE/home-1b"
    CWD_1B="/users/test/repo-l1b-$$"
    ENC_1B=$(encode_path "$CWD_1B")
    mkdir -p "$HOME_1B/.claude/projects/$ENC_1B"
    SID_1B="l1b-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1B" "$(ALL_COMPLETE_JSON "$SID_1B" "main")"
    write_transcript_line "$HOME_1B/.claude/projects/$ENC_1B/${SID_1B}.jsonl" \
        "$SID_1B" "$(to_node_path "$WORKFLOW_DIR/${SID_1B}.json")"
    RESULT_1B=$(call_find_latest "$CWD_1B" "main" "$HOME_1B")
    if [ "$RESULT_1B" = "null" ] || [ -z "$RESULT_1B" ]; then
        pass "L1-b. user_verification=complete → not inherited (returns null)"
    else
        fail "L1-b. user_verification=complete → unexpectedly returned state: $RESULT_1B"
    fi

    # L1-c: session-start called twice on same session ID → state not overwritten (idempotency)
    REPO_1C=$(setup_repo)
    SID_1C="l1c-$(printf '%04x%04x' $RANDOM $RANDOM)"
    ENV_FILE_1C="$TMPDIR_BASE/1c.env"
    write_state "$SID_1C" "$(INHERIT_STATE_JSON "$SID_1C" "main")"
    for _i in 1 2; do
        echo "{\"session_id\":\"$SID_1C\"}" | \
            CLAUDE_PROJECT_DIR="$REPO_1C" CLAUDE_ENV_FILE="$ENV_FILE_1C" \
            CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$SESSION_START" 2>/dev/null || true
    done
    expect_state_step "L1-c. session-start 2 runs → research remains complete (idempotent)" \
        "$SID_1C" "research" "complete"

    # L1-d: PostCompact in newer transcript file wins over SessionStart in older file
    HOME_1D="$TMPDIR_BASE/home-1d"
    CWD_1D="/users/test/repo-l1d-$$"
    ENC_1D=$(encode_path "$CWD_1D")
    mkdir -p "$HOME_1D/.claude/projects/$ENC_1D"
    SID_1D_SS="l1d-ss-$(printf '%04x%04x' $RANDOM $RANDOM)"   # SessionStart: research=complete only
    SID_1D_PC="l1d-pc-$(printf '%04x%04x' $RANDOM $RANDOM)"   # PostCompact: research+outline+detail=complete
    write_state "$SID_1D_SS" "$(INHERIT_STATE_JSON "$SID_1D_SS" "main")"
    write_state "$SID_1D_PC" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_1D_PC", "git_branch": "main",
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
    # Older file: SessionStart
    JSONL_1D_OLD="$HOME_1D/.claude/projects/$ENC_1D/old-${SID_1D_SS}.jsonl"
    write_transcript_line "$JSONL_1D_OLD" "$SID_1D_SS" "$(to_node_path "$WORKFLOW_DIR/${SID_1D_SS}.json")"
    node -e "const fs=require('fs');const old=new Date(Date.now()-60000);fs.utimesSync('$JSONL_1D_OLD',old,old);" 2>/dev/null || true
    # Newer file: PostCompact
    JSONL_1D_NEW="$HOME_1D/.claude/projects/$ENC_1D/new-${SID_1D_PC}.jsonl"
    write_postcompact_line "$JSONL_1D_NEW" "$SID_1D_PC" "$(to_node_path "$WORKFLOW_DIR/${SID_1D_PC}.json")"
    RESULT_1D=$(call_find_latest "$CWD_1D" "main" "$HOME_1D")
    PLAN_1D=$(get_json_step_status "$RESULT_1D" "detail")
    if [ "$PLAN_1D" = "complete" ]; then
        pass "L1-d. PostCompact (newer mtime) wins over SessionStart (older) → detail=complete"
    else
        fail "L1-d. PostCompact mtime priority — expected detail=complete, got: $PLAN_1D"
    fi
}
