#!/usr/bin/env bash
# tests/feature-690-step6h-docs.sh
# Tests: bin/github-issues/issue-close-finalize-triage.sh, skills/worktree-end/scripts/write-env-json.js, bin/github-issues/issue-to-history.sh, agents/issue-close-finalize-worker.md, bin/compose-doc-append-entry, hooks/lib/lint-worktree-notes-lang.js
# Tags: issue-close, docs-write, step6h, consolidation, triage
#
# Static contract tests for issue #690 — Step 6h docs-write consolidation.
# These are "red" tests initially — they define the expected post-implementation
# state and will go green after implementation.
#
# No subprocess spawning — tests use grep/stat on source files only.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run() {
    local name="$1"
    local fn="$2"
    local rc=0
    local output
    output="$("$fn" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$name"
    else
        fail "$name"
        if [ -n "$output" ]; then
            echo "  detail: $output"
        fi
    fi
}

# T1: issue-close-finalize-triage.sh must not reference Step E in NEXT_STEPS
# After Step E removal, no NEXT_STEPS assignment should contain "E,"
test_t1_triage_no_step_e_in_next_steps() {
    local f="$AGENTS_DIR/bin/github-issues/issue-close-finalize-triage.sh"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    # Should find NO lines with "E," in a NEXT_STEPS context
    if grep -qE '(NEXT_STEPS|next_steps).*"?E,' "$f" 2>/dev/null; then
        echo "found Step E reference in NEXT_STEPS in $f"
        grep -nE '(NEXT_STEPS|next_steps).*"?E,' "$f"
        return 1
    fi
    return 0
}

# T2: write-env-json.js must include MERGE_SHA in its FIELDS array
test_t2_write_env_json_has_merge_sha() {
    local f="$AGENTS_DIR/skills/worktree-end/scripts/write-env-json.js"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    if grep -q "MERGE_SHA" "$f" 2>/dev/null; then
        return 0
    fi
    echo "MERGE_SHA not found in $f"
    return 1
}

# T3: capture-env.sh must NOT contain a git rev-parse HEAD assignment for MERGE_SHA
test_t3_capture_env_no_rev_parse_fallback() {
    local f="$AGENTS_DIR/skills/worktree-end/scripts/capture-env.sh"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    # After consolidation the MERGE_SHA="$(git ... rev-parse HEAD ...)" line must be gone
    if grep -qE 'MERGE_SHA.*rev-parse' "$f" 2>/dev/null; then
        echo "found rev-parse assignment for MERGE_SHA in $f (should be removed)"
        grep -nE 'MERGE_SHA.*rev-parse' "$f"
        return 1
    fi
    return 0
}

# T4: issue-to-history.sh must exist AND contain a comment indicating it is used standalone
# (called directly, not as a sub-step of issue-close-finalize step-e.sh)
test_t4_issue_to_history_standalone_annotation() {
    local f="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    # After the step-e.sh deletion and annotation, a comment marking standalone/step-6h
    # use must appear. The old "Used by step-e.sh" reference must be absent.
    if grep -qiE '(standalone|step.6h|step_6h|called.directly.by)' "$f" 2>/dev/null; then
        return 0
    fi
    echo "no standalone-only annotation (step-6h/standalone) found in $f"
    return 1
}

# T5: agents/issue-close-finalize-worker.md must contain written_by_step_6h constant
test_t5_worker_md_has_written_by_step_6h() {
    local f="$AGENTS_DIR/agents/issue-close-finalize-worker.md"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    if grep -q "written_by_step_6h" "$f" 2>/dev/null; then
        return 0
    fi
    echo "written_by_step_6h not found in $f"
    return 1
}

# T6: bin/compose-doc-append-entry must NOT contain --skip-history as a recognized flag
test_t6_compose_no_skip_history_flag() {
    local f="$AGENTS_DIR/bin/compose-doc-append-entry"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    if grep -q "skip-history" "$f" 2>/dev/null; then
        echo "found --skip-history in $f (flag should be removed)"
        grep -n "skip-history" "$f"
        return 1
    fi
    return 0
}

# T7: hooks/lib/lint-worktree-notes-lang.js must NOT contain skipHistory option
test_t7_lint_no_skip_history_option() {
    local f="$AGENTS_DIR/hooks/lib/lint-worktree-notes-lang.js"
    if [ ! -f "$f" ]; then
        echo "file not found: $f"
        return 1
    fi
    if grep -q "skipHistory" "$f" 2>/dev/null; then
        echo "found skipHistory in $f (option should be removed)"
        grep -n "skipHistory" "$f"
        return 1
    fi
    return 0
}

# T8: skills/issue-close-finalize/scripts/step-e.sh must NOT exist (deleted)
test_t8_step_e_sh_deleted() {
    local f="$AGENTS_DIR/skills/issue-close-finalize/scripts/step-e.sh"
    if [ -f "$f" ]; then
        echo "file still exists (should be deleted): $f"
        return 1
    fi
    return 0
}

echo "=== feature-690-step6h-docs: Step 6h docs-write consolidation contracts ==="
echo ""

run "T1: triage.sh — no Step E in NEXT_STEPS after removal"    test_t1_triage_no_step_e_in_next_steps
run "T2: write-env-json.js — FIELDS includes MERGE_SHA"         test_t2_write_env_json_has_merge_sha
run "T3: capture-env.sh — no rev-parse HEAD fallback for MERGE_SHA" test_t3_capture_env_no_rev_parse_fallback
run "T4: issue-to-history.sh — standalone-only annotation present" test_t4_issue_to_history_standalone_annotation
run "T5: issue-close-finalize-worker.md — written_by_step_6h present" test_t5_worker_md_has_written_by_step_6h
run "T6: compose-doc-append-entry — --skip-history flag removed" test_t6_compose_no_skip_history_flag
run "T7: lint-worktree-notes-lang.js — skipHistory option removed" test_t7_lint_no_skip_history_option
run "T8: step-e.sh — file deleted"                              test_t8_step_e_sh_deleted

echo ""
echo "Results: $PASS passed, $FAIL failed"
# These tests are expected to fail initially (RED phase) — exit 1 is correct
[ "$FAIL" -eq 0 ]
