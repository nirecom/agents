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

    run_state_inheritance_derivation_tests
}

# ---------------------------------------------------------------------------
# #1305 / #1681: read-time derivation of the inheritance verdict.
# The staleness boundary is the verification TIER (review_security onward), and
# a "complete" clarify_intent that has no intent.md on disk is not real evidence
# of a completed intent stage — readState() synthesizes that status for legacy
# state files, so inheriting from it resurrects a session that never ran.
# ---------------------------------------------------------------------------

# Fixture builder: one step-status map, everything else pending.
# $1 sid, $2 extra JSON step entries (already comma-terminated), $3 branch
DERIVATION_STATE_JSON() {
    local sid="$1" extra="$2" branch="${3:-main}"
    cat <<EOF
{
  "version": 1, "session_id": "$sid", "git_branch": "$branch",
  "created_at": "$NOW_ISO",
  "steps": {
    $extra
    "research":          {"status": "complete", "updated_at": "$NOW_ISO"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "run_tests":         {"status": "pending",  "updated_at": null},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
}

# Set up an isolated cwd-context + transcript dir. Sets CWD_X / ENC_X / HOME_X.
derivation_ctx() {
    local tag="$1"
    D_CWD="/users/test/repo-${tag}-$$"
    D_ENC=$(encode_path "$D_CWD")
    D_HOME="$TMPDIR_BASE/home-${tag}"
    mkdir -p "$D_HOME/.claude/projects/$D_ENC"
}

expect_not_inherited() {
    local desc="$1" result="$2"
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        pass "$desc"
    else
        fail "$desc — expected null, got: $result"
    fi
}

run_state_inheritance_derivation_tests() {
    echo ""
    echo "=== Section 1b: State Inheritance — read-time derivation (#1305/#1681) ==="

    # L1-e: verification-tier boundary. review_security=complete means the prior
    # session already reached the verification tier; user_verification alone is
    # too late a boundary (the session is stale well before it is emitted).
    derivation_ctx "l1e"
    SID_1E="l1e-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1E" "$(DERIVATION_STATE_JSON "$SID_1E" \
        '"review_security":   {"status": "complete", "updated_at": "'"$NOW_ISO"'"},')"
    write_transcript_line "$D_HOME/.claude/projects/$D_ENC/${SID_1E}.jsonl" \
        "$SID_1E" "$(to_node_path "$WORKFLOW_DIR/${SID_1E}.json")"
    RESULT_1E=$(call_find_latest "$D_CWD" "main" "$D_HOME")
    expect_not_inherited \
        "L1-e. review_security=complete (user_verification still pending) → not inherited" \
        "$RESULT_1E"

    # L1-f: clarify_intent literally recorded complete but no intent.md artifact.
    # A recorded-complete intent stage with no artifact is unusable state.
    derivation_ctx "l1f"
    SID_1F="l1f-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1F" "$(DERIVATION_STATE_JSON "$SID_1F" \
        '"clarify_intent":    {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "review_security":   {"status": "pending",  "updated_at": null},')"
    rm -f "$TEST_PLANS_DIR/${SID_1F}-intent.md"
    write_transcript_line "$D_HOME/.claude/projects/$D_ENC/${SID_1F}.jsonl" \
        "$SID_1F" "$(to_node_path "$WORKFLOW_DIR/${SID_1F}.json")"
    RESULT_1F=$(call_find_latest "$D_CWD" "main" "$D_HOME")
    expect_not_inherited \
        "L1-f. clarify_intent recorded complete without intent.md → not inherited" \
        "$RESULT_1F"

    # L1-g (positive control): outline+detail reach "complete" via the plan→
    # outline/detail migration inside readState(), with NO plan artifacts on disk.
    # That is legitimate legacy state — narrowing the artifact check to
    # clarify_intent must NOT break it.
    derivation_ctx "l1g"
    SID_1G="l1g-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1G" "$(DERIVATION_STATE_JSON "$SID_1G" \
        '"plan":              {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "review_security":   {"status": "pending",  "updated_at": null},')"
    rm -f "$TEST_PLANS_DIR/${SID_1G}-outline.md" "$TEST_PLANS_DIR/${SID_1G}-detail.md"
    write_transcript_line "$D_HOME/.claude/projects/$D_ENC/${SID_1G}.jsonl" \
        "$SID_1G" "$(to_node_path "$WORKFLOW_DIR/${SID_1G}.json")"
    RESULT_1G=$(call_find_latest "$D_CWD" "main" "$D_HOME")
    DETAIL_1G=$(get_json_step_status "$RESULT_1G" "detail")
    if [ "$DETAIL_1G" = "complete" ]; then
        pass "L1-g. synthesized outline/detail complete without artifacts → still inherited"
    else
        fail "L1-g. expected inherited detail=complete, got: $DETAIL_1G (result: $RESULT_1G)"
    fi

    # L1-h (boundary): a mid-review-cycle round-number file must not make the
    # prior session look stale — plan-artifact presence, not completion evidence,
    # is what the inheritance check may consult.
    derivation_ctx "l1h"
    SID_1H="l1h-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_1H" "$(DERIVATION_STATE_JSON "$SID_1H" \
        '"clarify_intent":    {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "outline":           {"status": "complete", "updated_at": "'"$NOW_ISO"'"},
    "review_security":   {"status": "pending",  "updated_at": null},')"
    printf 'intent\n'  > "$TEST_PLANS_DIR/${SID_1H}-intent.md"
    printf 'outline\n' > "$TEST_PLANS_DIR/${SID_1H}-outline.md"
    printf '2\n'       > "$TEST_PLANS_DIR/${SID_1H}-outline-plan-round-number.txt"
    write_transcript_line "$D_HOME/.claude/projects/$D_ENC/${SID_1H}.jsonl" \
        "$SID_1H" "$(to_node_path "$WORKFLOW_DIR/${SID_1H}.json")"
    RESULT_1H=$(call_find_latest "$D_CWD" "main" "$D_HOME")
    OUTLINE_1H=$(get_json_step_status "$RESULT_1H" "outline")
    if [ "$OUTLINE_1H" = "complete" ]; then
        pass "L1-h. outline.md present + in-flight review round → still inherited"
    else
        fail "L1-h. expected inherited outline=complete, got: $OUTLINE_1H (result: $RESULT_1H)"
    fi

    # L1-i (#1305 core): the newest transcript carries stale state. Hitting the
    # staleness boundary must stop the WHOLE search — not merely the inner loop
    # over ids in that one file, which would let an older, still-inheritable
    # transcript be picked up instead.
    derivation_ctx "l1i"
    SID_1I_OLD="l1iold-$(printf '%04x%04x' $RANDOM $RANDOM)"   # valid, inheritable
    SID_1I_NEW="l1inew-$(printf '%04x%04x' $RANDOM $RANDOM)"   # stale boundary
    write_state "$SID_1I_OLD" "$(INHERIT_STATE_JSON "$SID_1I_OLD" "main")"
    write_state "$SID_1I_NEW" "$(DERIVATION_STATE_JSON "$SID_1I_NEW" \
        '"review_security":   {"status": "complete", "updated_at": "'"$NOW_ISO"'"},')"
    JSONL_1I_OLD="$D_HOME/.claude/projects/$D_ENC/old-${SID_1I_OLD}.jsonl"
    write_transcript_line "$JSONL_1I_OLD" "$SID_1I_OLD" \
        "$(to_node_path "$WORKFLOW_DIR/${SID_1I_OLD}.json")"
    node -e "const fs=require('fs');const t=new Date(Date.now()-120000);fs.utimesSync('$JSONL_1I_OLD',t,t);" 2>/dev/null || true
    JSONL_1I_NEW="$D_HOME/.claude/projects/$D_ENC/new-${SID_1I_NEW}.jsonl"
    write_transcript_line "$JSONL_1I_NEW" "$SID_1I_NEW" \
        "$(to_node_path "$WORKFLOW_DIR/${SID_1I_NEW}.json")"
    RESULT_1I=$(call_find_latest "$D_CWD" "main" "$D_HOME")
    if [ "$RESULT_1I" = "null" ] || [ -z "$RESULT_1I" ]; then
        pass "L1-i. stale newest transcript stops the entire search (no fallback to older)"
    elif echo "$RESULT_1I" | grep -qF "$SID_1I_OLD"; then
        fail "L1-i. search leaked past the staleness boundary into the OLDER transcript ($SID_1I_OLD)"
    else
        fail "L1-i. expected null, got: $RESULT_1I"
    fi
}
