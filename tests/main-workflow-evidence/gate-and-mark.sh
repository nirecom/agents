# shellcheck shell=bash
# Tests: hooks/workflow-gate.js, hooks/workflow-mark.js
# Tags: workflow, gate, hook, bin, git
#
# Case group: workflow-gate.js evidence checks (WS-EV-1..5) +
# workflow-mark.js MARK_STEP rejection / NOT_NEEDED handlers (WS-EV-6..8).
# Sourced by main-workflow-evidence.sh; relies on helpers from common.sh.

run_gate_and_mark_tests() {
    local REPO REPO_N SID GATE_INPUT GATE_OUT MARK_JSON MARK_OUT ACTUAL_STATUS EV8_REASON

    # =======================================================================
    # workflow-gate.js — evidence-based checks
    # =======================================================================

    echo ""
    echo "=== WS-EV-1: tests/ file staged, write_tests=pending → gate approves ==="

    REPO=$(setup_repo)
    REPO_N=$(to_node_path "$REPO")
    SID="ev1-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"
    # Stage a test file
    mkdir -p "$REPO/tests"
    echo "test content" > "$REPO/tests/my-test.sh"
    git -C "$REPO" add tests/my-test.sh

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"approve"'; then
        pass "WS-EV-1. tests/ staged + write_tests=pending → approve"
    else
        fail "WS-EV-1. expected approve, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-2: docs/*.md file staged, docs=pending → gate approves ==="

    REPO=$(setup_repo)
    REPO_N=$(to_node_path "$REPO")
    SID="ev2-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    # Stage a doc file
    mkdir -p "$REPO/docs"
    echo "doc content" > "$REPO/docs/guide.md"
    git -C "$REPO" add docs/guide.md

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"approve"'; then
        pass "WS-EV-2. docs/ staged + docs=pending → approve"
    else
        fail "WS-EV-2. expected approve, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-3: no tests/ staged, write_tests=pending → gate blocks ==="

    REPO=$(setup_repo)
    REPO_N=$(to_node_path "$REPO")
    SID="ev3-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"
    # Stage a non-test file only
    echo "source code" > "$REPO/app.js"
    git -C "$REPO" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'write_tests'; then
        pass "WS-EV-3. no tests/ staged + write_tests=pending → block mentioning write_tests"
    else
        fail "WS-EV-3. expected block mentioning write_tests, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-4: no docs staged, docs=pending → gate blocks ==="

    REPO=$(setup_repo)
    REPO_N=$(to_node_path "$REPO")
    SID="ev4-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    # Stage a non-doc file only
    echo "source code" > "$REPO/app.js"
    git -C "$REPO" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'docs'; then
        pass "WS-EV-4. no docs staged + docs=pending → block mentioning docs"
    else
        fail "WS-EV-4. expected block mentioning docs, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-5: claude-global/ only staged, write_tests=pending → gate blocks ==="

    REPO=$(setup_repo)
    REPO_N=$(to_node_path "$REPO")
    SID="ev5-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"
    # Stage a file in claude-global/ only (no tests/)
    mkdir -p "$REPO/claude-global"
    echo "config" > "$REPO/claude-global/settings.json"
    git -C "$REPO" add claude-global/settings.json

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'write_tests'; then
        pass "WS-EV-5. claude-global/ only + write_tests=pending → block (no exempt)"
    else
        fail "WS-EV-5. expected block mentioning write_tests, got: $GATE_OUT"
    fi

    # =======================================================================
    # workflow-mark.js — MARK_STEP rejection + NOT_NEEDED handlers
    # =======================================================================

    echo ""
    echo "=== WS-EV-6: MARK_STEP write_tests_complete → rejected, NOT recorded ==="

    REPO=$(setup_repo)
    SID="ev6-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

    MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_write_tests_complete>>"' "$SID")
    MARK_OUT=$(run_mark "$MARK_JSON")

    if echo "$MARK_OUT" | grep -q "NOT recorded"; then
        pass "WS-EV-6a. MARK_STEP write_tests_complete → additionalContext contains 'NOT recorded'"
    else
        fail "WS-EV-6a. expected 'NOT recorded' in output, got: $MARK_OUT"
    fi

    ACTUAL_STATUS=$(read_state_status "$SID" "write_tests")
    if [ "$ACTUAL_STATUS" = "pending" ]; then
        pass "WS-EV-6b. write_tests state remains pending"
    else
        fail "WS-EV-6b. expected write_tests=pending, got: $ACTUAL_STATUS"
    fi

    echo ""
    echo "=== WS-EV-7: MARK_STEP docs_complete → rejected, NOT recorded ==="

    REPO=$(setup_repo)
    SID="ev7-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"

    MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_docs_complete>>"' "$SID")
    MARK_OUT=$(run_mark "$MARK_JSON")

    if echo "$MARK_OUT" | grep -q "NOT recorded"; then
        pass "WS-EV-7a. MARK_STEP docs_complete → additionalContext contains 'NOT recorded'"
    else
        fail "WS-EV-7a. expected 'NOT recorded' in output, got: $MARK_OUT"
    fi

    ACTUAL_STATUS=$(read_state_status "$SID" "docs")
    if [ "$ACTUAL_STATUS" = "pending" ]; then
        pass "WS-EV-7b. docs state remains pending"
    else
        fail "WS-EV-7b. expected docs=pending, got: $ACTUAL_STATUS"
    fi

    echo ""
    echo "=== WS-EV-8: WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason> → write_tests=skipped ==="

    REPO=$(setup_repo)
    SID="ev8-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT write_tests "$SID")"

    MARK_JSON=$(build_mark_json 'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: hook refactor, no test coverage affected>>"' "$SID")
    MARK_OUT=$(run_mark "$MARK_JSON")

    expect_state_step "WS-EV-8. WORKFLOW_WRITE_TESTS_NOT_NEEDED → write_tests=skipped" \
        "$SID" "write_tests" "skipped"

    EV8_REASON=$(read_state_field "$SID" "write_tests" "skip_reason")
    if [ "$EV8_REASON" = "hook refactor, no test coverage affected" ]; then
        pass "WS-EV-8b. write_tests.skip_reason recorded"
    else
        fail "WS-EV-8b. expected skip_reason='hook refactor, no test coverage affected', got: $EV8_REASON"
    fi
}
