# shellcheck shell=bash
# Tests: hooks/workflow-gate.js
# Tags: workflow, gate, hook, git
#
# Case group: WORKTREE_NOTES.md docs evidence (issue #484), WS-EV-9..13.
# Sourced by main-workflow-evidence.sh; relies on helpers from common.sh.

# Set up a main repo + linked worktree on a feature branch. Echoes the worktree path.
setup_worktree() {
    local main_repo="$TMPDIR_BASE/main-$RANDOM"
    local wt="$TMPDIR_BASE/wt-$RANDOM"
    mkdir -p "$main_repo"
    git -C "$main_repo" init -q -b main
    # Disable inherited global core.hooksPath (points to agents/hooks pre-commit,
    # which blocks commits it cannot resolve to a linked worktree).
    git -C "$main_repo" config core.hooksPath /dev/null
    git -C "$main_repo" config user.email "test@example.com"
    git -C "$main_repo" config user.name "Test"
    echo "init" > "$main_repo/README.md"
    git -C "$main_repo" add README.md
    git -C "$main_repo" commit -q --no-verify -m "initial"
    git -C "$main_repo" worktree add -q -b feat/ev "$wt" >/dev/null
    echo "$wt"
}

# Write a WORKTREE_NOTES.md with given History Notes / Changelog Notes content.
# Args: <worktree-path> <history-bullets-pipe-delimited-or-empty> <changelog-bullets-pipe-delimited-or-empty>
# Empty arg means write "- (none)" placeholder.
write_notes_file() {
    local wt="$1" hist="$2" chg="$3"
    {
        echo "# Worktree Notes"
        echo "Branch: feat/ev"
        echo ""
        echo "## History Notes"
        if [ -z "$hist" ]; then
            echo "- (none)"
        else
            IFS='|' read -ra arr <<< "$hist"
            for b in "${arr[@]}"; do echo "- $b"; done
        fi
        echo ""
        echo "## Changelog Notes"
        if [ -z "$chg" ]; then
            echo "- (none)"
        else
            IFS='|' read -ra arr <<< "$chg"
            for b in "${arr[@]}"; do echo "- $b"; done
        fi
    } > "$wt/WORKTREE_NOTES.md"
}

run_worktree_notes_tests() {
    local WT WT_N WT_SUB_N REPO REPO_N SID GATE_INPUT GATE_OUT

    echo ""
    echo "=== WS-EV-9: linked worktree + History Notes has bullet → approve ==="

    WT=$(setup_worktree)
    WT_N=$(to_node_path "$WT")
    SID="ev9-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    write_notes_file "$WT" "fixed bug in foo handler" ""
    echo "console.log('hi');" > "$WT/app.js"
    git -C "$WT" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$WT_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"approve"'; then
        pass "WS-EV-9. linked worktree + History Notes bullet + docs=pending → approve"
    else
        fail "WS-EV-9. expected approve, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-10: linked worktree + notes only contain '- (none)' → block ==="

    WT=$(setup_worktree)
    WT_N=$(to_node_path "$WT")
    SID="ev10-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    write_notes_file "$WT" "" ""
    echo "console.log('hi');" > "$WT/app.js"
    git -C "$WT" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$WT_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'docs'; then
        pass "WS-EV-10. WORKTREE_NOTES.md only '- (none)' + docs=pending → block mentioning docs"
    else
        fail "WS-EV-10. expected block mentioning docs, got: $GATE_OUT"
    fi

    if echo "$GATE_OUT" | grep -q 'WORKTREE_NOTES.md'; then
        pass "WS-EV-10b. block message mentions WORKTREE_NOTES.md guidance"
    else
        fail "WS-EV-10b. expected block message to mention WORKTREE_NOTES.md, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-11: linked worktree + Changelog Notes only has bullet → approve ==="

    WT=$(setup_worktree)
    WT_N=$(to_node_path "$WT")
    SID="ev11-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    write_notes_file "$WT" "" "user-visible change to CLI output"
    echo "console.log('hi');" > "$WT/app.js"
    git -C "$WT" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$WT_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"approve"'; then
        pass "WS-EV-11. Changelog Notes bullet only + docs=pending → approve"
    else
        fail "WS-EV-11. expected approve, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-12: main worktree (not linked) + WORKTREE_NOTES.md → block (isWorktreeContext guard) ==="

    REPO=$(setup_repo)
    REPO_N=$(to_node_path "$REPO")
    SID="ev12-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    write_notes_file "$REPO" "fixed something" "user-visible change"
    echo "console.log('hi');" > "$REPO/app.js"
    git -C "$REPO" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$REPO_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"block"' && echo "$GATE_OUT" | grep -q 'docs'; then
        pass "WS-EV-12. main worktree + WORKTREE_NOTES.md → block (isWorktreeContext early-false)"
    else
        fail "WS-EV-12. expected block mentioning docs, got: $GATE_OUT"
    fi

    echo ""
    echo "=== WS-EV-13: linked worktree + commit invoked from subdir → approve (rev-parse toplevel) ==="

    WT=$(setup_worktree)
    mkdir -p "$WT/sub"
    WT_SUB_N=$(to_node_path "$WT/sub")
    SID="ev13-$$"
    write_state "$SID" "$(ALL_COMPLETE_EXCEPT docs "$SID")"
    write_notes_file "$WT" "subdir test bullet" ""
    echo "console.log('hi');" > "$WT/sub/app.js"
    git -C "$WT/sub" add app.js

    GATE_INPUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"test\\""},"session_id":"%s"}' "$WT_SUB_N" "$SID")
    GATE_OUT=$(run_gate "$GATE_INPUT")

    if echo "$GATE_OUT" | grep -q '"approve"'; then
        pass "WS-EV-13. linked worktree subdir command + History Notes bullet → approve"
    else
        fail "WS-EV-13. expected approve, got: $GATE_OUT"
    fi
}
