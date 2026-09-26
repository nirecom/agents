# shellcheck shell=bash
# Case group: Section 2 — Cross-Repo Commit.
# Sourced by main-workflow-state-machine.sh; relies on helpers from common.sh.

run_cross_repo_commit_tests() {
    # ---------------------------------------------------------------------------
    # Section 2: Cross-Repo Commit
    # ---------------------------------------------------------------------------
    echo ""
    echo "=== Section 2: Cross-Repo Commit ==="

    REPO_A=$(setup_repo)
    REPO_B=$(setup_repo)
    REPO_C=$(setup_repo)

    # L2-a: repoA all complete, git -C repoA issued from repoB context → approve
    SID_2A="l2a-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2A" "$(ALL_COMPLETE_JSON "$SID_2A")"
    L2A_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2A\"}"
    expect_approve_gate "L2-a. repoA all complete, git -C repoA from repoB → approve" \
        "$REPO_B" "$L2A_JSON"

    # L2-b: repoA write_tests=pending, git -C repoA from repoB → block (mentions write_tests)
    SID_2B="l2b-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2B" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2B", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
    L2B_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2B\"}"
    # Inline call: CLAUDE_PROJECT_DIR=REPO_B (invoking session), AGENTS_CONFIG_DIR=REPO_A
    # (agents session repo), git -C REPO_A targets REPO_A → same git dir → enforce.
    L2B_RESULT=$(echo "$L2B_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        AGENTS_CONFIG_DIR="$REPO_A" node "$GATE_HOOK" 2>/dev/null || true)
    if echo "$L2B_RESULT" | grep -q '"block"' && echo "$L2B_RESULT" | grep -qi "write_tests"; then
        pass "L2-b. repoA write_tests=pending, git -C repoA → block (write_tests)"
    else
        fail "L2-b. repoA write_tests=pending, git -C repoA → block (write_tests) — got: $L2B_RESULT"
    fi

    # L2-c: repoA docs-only staged, git -C repoA → docs-only message (user_verification needed)
    SID_2C="l2c-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2C" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2C", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "pending",  "updated_at": null}
  }
}
EOF
)"
    mkdir -p "$REPO_A/docs"
    echo "change" > "$REPO_A/docs/todo.md"
    git -C "$REPO_A" add docs/todo.md
    L2C_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C\"}"
    L2C_RESULT=$(echo "$L2C_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        AGENTS_CONFIG_DIR="$REPO_A" node "$GATE_HOOK" 2>/dev/null || true)
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    git -C "$REPO_A" clean -fdq 2>/dev/null || true
    if echo "$L2C_RESULT" | grep -q '"block"' && echo "$L2C_RESULT" | grep -qi "docs-only"; then
        pass "L2-c. docs-only staged cross-repo → block with docs-only message"
    else
        fail "L2-c. docs-only staged cross-repo — expected block+docs-only, got: $L2C_RESULT"
    fi

    # L2-c2: root README.md only staged → docs-only short-circuit
    SID_2C2="l2c2-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2C2" "$(ALL_PENDING_JSON "$SID_2C2")"
    echo "readme change" > "$REPO_A/README.md"
    git -C "$REPO_A" add README.md
    L2C2_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C2\"}"
    L2C2_RESULT=$(run_gate "$REPO_A" "$L2C2_JSON")
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    git -C "$REPO_A" checkout -- README.md 2>/dev/null || true
    if echo "$L2C2_RESULT" | grep -q '"block"' && echo "$L2C2_RESULT" | grep -qi "docs-only"; then
        pass "L2-c2. root README.md only staged → docs-only short-circuit"
    else
        fail "L2-c2. root README.md only staged → docs-only short-circuit — got: $L2C2_RESULT"
    fi

    # L2-c3: docs/todo.md + README.md mixed staged → docs-only short-circuit
    SID_2C3="l2c3-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2C3" "$(ALL_PENDING_JSON "$SID_2C3")"
    mkdir -p "$REPO_A/docs"
    echo "todo change" > "$REPO_A/docs/todo.md"
    echo "readme change" > "$REPO_A/README.md"
    git -C "$REPO_A" add docs/todo.md README.md
    L2C3_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C3\"}"
    L2C3_RESULT=$(run_gate "$REPO_A" "$L2C3_JSON")
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    git -C "$REPO_A" clean -fdq 2>/dev/null || true
    git -C "$REPO_A" checkout -- README.md 2>/dev/null || true
    if echo "$L2C3_RESULT" | grep -q '"block"' && echo "$L2C3_RESULT" | grep -qi "docs-only"; then
        pass "L2-c3. docs/todo.md + README.md mixed staged → docs-only short-circuit"
    else
        fail "L2-c3. docs/todo.md + README.md mixed staged → docs-only short-circuit — got: $L2C3_RESULT"
    fi

    # L2-c4: root CLAUDE.md only staged → full gate (behavior code)
    SID_2C4="l2c4-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2C4" "$(ALL_PENDING_JSON "$SID_2C4")"
    echo "# claude config" > "$REPO_A/CLAUDE.md"
    git -C "$REPO_A" add CLAUDE.md
    L2C4_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C4\"}"
    L2C4_RESULT=$(run_gate "$REPO_A" "$L2C4_JSON")
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    rm -f "$REPO_A/CLAUDE.md"
    if echo "$L2C4_RESULT" | grep -q '"block"' \
       && ! echo "$L2C4_RESULT" | grep -qi "docs-only" \
       && echo "$L2C4_RESULT" | grep -q "outline"; then
        pass "L2-c4. root CLAUDE.md only staged → full gate (behavior code)"
    else
        fail "L2-c4. root CLAUDE.md only staged → full gate (behavior code) — got: $L2C4_RESULT"
    fi

    # L2-c5: subdirectory README.md staged → full gate (root-only allowlist)
    SID_2C5="l2c5-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2C5" "$(ALL_PENDING_JSON "$SID_2C5")"
    mkdir -p "$REPO_A/subproject"
    echo "sub readme" > "$REPO_A/subproject/README.md"
    git -C "$REPO_A" add subproject/README.md
    L2C5_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2C5\"}"
    L2C5_RESULT=$(run_gate "$REPO_A" "$L2C5_JSON")
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    rm -rf "$REPO_A/subproject"
    if echo "$L2C5_RESULT" | grep -q '"block"' \
       && ! echo "$L2C5_RESULT" | grep -qi "docs-only"; then
        pass "L2-c5. subdirectory README.md staged → full gate (root-only allowlist)"
    else
        fail "L2-c5. subdirectory README.md staged → full gate (root-only allowlist) — got: $L2C5_RESULT"
    fi

    # L2-d: repoA tests/ staged, write_tests=pending → approve (evidence-based override)
    SID_2D="l2d-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2D" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2D", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "skipped",  "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}
EOF
)"
    mkdir -p "$REPO_A/tests"
    echo "test" > "$REPO_A/tests/test-case.sh"
    git -C "$REPO_A" add tests/test-case.sh
    L2D_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2D\"}"
    L2D_RESULT=$(echo "$L2D_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$GATE_HOOK" 2>/dev/null || true)
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    git -C "$REPO_A" clean -fdq 2>/dev/null || true
    if echo "$L2D_RESULT" | grep -q '"approve"'; then
        pass "L2-d. tests/ staged cross-repo, write_tests=pending → approve (evidence override)"
    else
        fail "L2-d. tests/ staged cross-repo — expected approve, got: $L2D_RESULT"
    fi

    # L2-e: CLAUDE_PROJECT_DIR=third-repo, git -C repoA → state still resolved from WORKFLOW_DIR
    SID_2E="l2e-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2E" "$(ALL_COMPLETE_JSON "$SID_2E")"
    L2E_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2E\"}"
    expect_approve_gate "L2-e. CLAUDE_PROJECT_DIR=third-repo, -C repoA → state from WORKFLOW_DIR" \
        "$REPO_C" "$L2E_JSON"

    # L2-f: git -C /nonexistent → block (no crash)
    SID_2F="l2f-$(printf '%04x%04x' $RANDOM $RANDOM)"
    NONEXISTENT="$TMPDIR_BASE/nonexistent-l2f-$$"
    L2F_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $NONEXISTENT commit -m test\"},\"session_id\":\"$SID_2F\"}"
    L2F_RESULT=$(echo "$L2F_JSON" | CLAUDE_PROJECT_DIR="$REPO_A" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$GATE_HOOK" 2>/dev/null || true)
    if echo "$L2F_RESULT" | grep -q '"block"'; then
        pass "L2-f. git -C /nonexistent → block (no crash)"
    else
        fail "L2-f. git -C /nonexistent — expected block, got: $L2F_RESULT"
    fi

    # L2-g(DQ): double-quoted -C argument correctly resolved
    REPO_DQ=$(setup_repo)
    SID_2G_DQ="l2g-dq-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2G_DQ" "$(ALL_COMPLETE_JSON "$SID_2G_DQ")"
    L2G_DQ_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C \\\"$REPO_DQ\\\" commit -m test\"},\"session_id\":\"$SID_2G_DQ\"}"
    expect_approve_gate 'L2-g(DQ). git -C "path" commit → resolved and approved' "$REPO_B" "$L2G_DQ_JSON"

    # L2-g(SQ): single-quoted -C argument correctly resolved
    REPO_SQ=$(setup_repo)
    SID_2G_SQ="l2g-sq-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2G_SQ" "$(ALL_COMPLETE_JSON "$SID_2G_SQ")"
    L2G_SQ_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C '$REPO_SQ' commit -m test\"},\"session_id\":\"$SID_2G_SQ\"}"
    expect_approve_gate "L2-g(SQ). git -C 'path' commit → resolved and approved" "$REPO_B" "$L2G_SQ_JSON"

    # L2-h: test/ (single t, not tests/) staged with write_tests=pending → approve (evidence override)
    SID_2H="l2h-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2H" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2H", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "skipped",  "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}
EOF
)"
    mkdir -p "$REPO_A/test"
    echo "unit test" > "$REPO_A/test/unit.sh"
    git -C "$REPO_A" add test/unit.sh
    L2H_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2H\"}"
    L2H_RESULT=$(echo "$L2H_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$GATE_HOOK" 2>/dev/null || true)
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    git -C "$REPO_A" clean -fdq 2>/dev/null || true
    if echo "$L2H_RESULT" | grep -q '"approve"'; then
        pass "L2-h. test/ (single t) staged, write_tests=pending → approve (evidence override)"
    else
        fail "L2-h. test/ staged cross-repo — expected approve, got: $L2H_RESULT"
    fi

    # L2-i: root-level *.md staged with docs=pending → approve (hasStagedDocChanges *.md match)
    SID_2I="l2i-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2I" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2I", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "skipped",  "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}
EOF
)"
    echo "changelog" > "$REPO_A/CHANGES.md"
    git -C "$REPO_A" add CHANGES.md
    L2I_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_A commit -m test\"},\"session_id\":\"$SID_2I\"}"
    L2I_RESULT=$(echo "$L2I_JSON" | CLAUDE_PROJECT_DIR="$REPO_B" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$GATE_HOOK" 2>/dev/null || true)
    git -C "$REPO_A" reset HEAD -- . 2>/dev/null || true
    git -C "$REPO_A" clean -fdq 2>/dev/null || true
    if echo "$L2I_RESULT" | grep -q '"approve"'; then
        pass "L2-i. root-level *.md staged, docs=pending → approve (hasStagedDocChanges *.md match)"
    else
        fail "L2-i. root-level *.md cross-repo — expected approve, got: $L2I_RESULT"
    fi

    # L2-j(security): path traversal in git -C (../ sequences) → block gracefully, no crash
    # git diff fails on non-repo traversal path → evidence checks return false → state-based block
    SID_2J="l2j-$(printf '%04x%04x' $RANDOM $RANDOM)"
    write_state "$SID_2J" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2J", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "pending",  "updated_at": null},
    "review_tests":      {"status": "pending",  "updated_at": null},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "complete", "updated_at": "2026-04-11T10:06:00.000Z"},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
    L2J_TRAVERSAL="$TMPDIR_BASE/sub/../../nonexistent-l2j-$$"
    L2J_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $L2J_TRAVERSAL commit -m test\"},\"session_id\":\"$SID_2J\"}"
    L2J_RESULT=$(echo "$L2J_JSON" | CLAUDE_PROJECT_DIR="$REPO_A" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
        node "$GATE_HOOK" 2>/dev/null || true)
    if echo "$L2J_RESULT" | grep -q '"block"'; then
        pass "L2-j(security). path traversal in git -C → block (git fails gracefully, state check succeeds)"
    else
        fail "L2-j(security). path traversal — expected block, got: $L2J_RESULT"
    fi

    # L2-k / L2-l: docs/ symlink/junction → external git repo, evidence detection
    REPO_2K_SRC=$(setup_repo)
    REPO_2K_EXT=$(setup_repo)
    mkdir -p "$REPO_2K_EXT/docs"
    JUNCTION_OK=0
    ln -sfn "$REPO_2K_EXT/docs" "$REPO_2K_SRC/docs" 2>/dev/null && JUNCTION_OK=1 || true

    if [ "$JUNCTION_OK" = "1" ]; then
        # L2-k: docs staged in junction target → approve
        SID_2K="l2k-$(printf '%04x%04x' $RANDOM $RANDOM)"
        write_state "$SID_2K" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2K", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"},
    "cleanup":           {"status": "skipped",  "updated_at": "2026-04-11T10:08:00.000Z"}
  }
}
EOF
)"
        echo "change" > "$REPO_2K_EXT/docs/todo.md"
        git -C "$REPO_2K_EXT" add docs/todo.md
        L2K_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_2K_SRC commit -m test\"},\"session_id\":\"$SID_2K\"}"
        L2K_RESULT=$(echo "$L2K_JSON" | CLAUDE_PROJECT_DIR="$REPO_2K_SRC" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
            node "$GATE_HOOK" 2>/dev/null || true)
        git -C "$REPO_2K_EXT" reset HEAD -- . 2>/dev/null || true
        git -C "$REPO_2K_EXT" clean -fdq 2>/dev/null || true
        if echo "$L2K_RESULT" | grep -q '"approve"'; then
            pass "L2-k. docs/ symlink/junction → external git repo, docs staged there → approve"
        else
            fail "L2-k. docs/ symlink/junction → external git repo — expected approve, got: $L2K_RESULT"
        fi

        # L2-l: junction exists but no docs staged anywhere → block
        SID_2L="l2l-$(printf '%04x%04x' $RANDOM $RANDOM)"
        write_state "$SID_2L" "$(cat <<EOF
{
  "version": 1, "session_id": "$SID_2L", "git_branch": "main",
  "created_at": "2026-04-11T10:00:00.000Z",
  "steps": {
    "research":          {"status": "complete", "updated_at": "2026-04-11T10:01:00.000Z"},
    "outline":           {"status": "complete", "updated_at": "2026-04-11T10:02:00.000Z"},
    "detail":            {"status": "complete", "updated_at": "2026-04-11T10:02:30.000Z"},
    "write_tests":       {"status": "complete", "updated_at": "2026-04-11T10:03:00.000Z"},
    "review_tests":      {"status": "skipped", "updated_at": "2026-04-11T10:03:30.000Z"},
    "review_security":   {"status": "complete", "updated_at": "2026-04-11T10:04:30.000Z"},
    "run_tests":         {"status": "complete", "updated_at": "2026-04-11T10:05:00.000Z"},
    "docs":              {"status": "pending",  "updated_at": null},
    "user_verification": {"status": "complete", "updated_at": "2026-04-11T10:07:00.000Z"}
  }
}
EOF
)"
        L2L_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $REPO_2K_SRC commit -m test\"},\"session_id\":\"$SID_2L\"}"
        L2L_RESULT=$(echo "$L2L_JSON" | CLAUDE_PROJECT_DIR="$REPO_2K_SRC" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" \
            node "$GATE_HOOK" 2>/dev/null || true)
        if echo "$L2L_RESULT" | grep -q '"block"'; then
            pass "L2-l. docs/ symlink/junction, no staged docs → block"
        else
            fail "L2-l. docs/ symlink/junction, no staged docs — expected block, got: $L2L_RESULT"
        fi

        rm -rf "$REPO_2K_SRC/docs"
    else
        echo "SKIP: L2-k/L2-l (symlink or junction creation not available)"
    fi
}
