#!/usr/bin/env bash
# tests/feature-scriptify-survey-history.sh
# Tests: skills/survey-history/SKILL.md, skills/survey-history/scripts/keyword-only-mode.sh, skills/survey-history/scripts/history-docs-search.sh, skills/survey-history/scripts/artifact-template.sh
# Tags: survey, history, skill, scripts, scriptify, scope:issue-specific
#
# Tests for feature/scriptify-survey-history (Issue #1468):
#   - Inline bash blocks extracted to skills/survey-history/scripts/ files
#   - keyword-only-mode.sh, history-docs-search.sh, artifact-template.sh created
#   - SKILL.md line count < 100 (WARN resolved)
#   - SKILL.md no longer contains inline PLANS_DIR bash fenced block
#   - SKILL.md references the three extracted scripts
#   - SKILL.md references skills/_shared/resolve-plans-dir.md
#   - bin/review-prompt-size shows no WARN/HARD for survey-history/SKILL.md
#
# Tests are written BEFORE implementation. They SKIP (not FAIL) when the
# implementation hasn't happened yet, and PASS once implementation completes.
#
# L3 gap: These are L2 tests (real bash subprocesses, real filesystem). A full
# L3 test would invoke SKILL.md within a real `claude -p` session to verify
# end-to-end that the model correctly calls each extracted script, reads its
# template output, and produces a well-formed survey-history.md artifact. That
# level of verification requires RUN_E2E=on and is not covered here.

if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1: ${2:-}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1: ${2:-}"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# Master skip gate: implementation-dependent tests
# If skills/survey-history/scripts/ does not exist, the extraction hasn't
# happened yet — skip every script-dependent test below.
# ---------------------------------------------------------------------------
IMPL_DONE=false
if [ -d "$REPO_ROOT/skills/survey-history/scripts" ]; then
    IMPL_DONE=true
fi

KEYWORD_SCRIPT="$REPO_ROOT/skills/survey-history/scripts/keyword-only-mode.sh"
HISTORY_SCRIPT="$REPO_ROOT/skills/survey-history/scripts/history-docs-search.sh"
ARTIFACT_SCRIPT="$REPO_ROOT/skills/survey-history/scripts/artifact-template.sh"
SKILL_MD="$REPO_ROOT/skills/survey-history/SKILL.md"

# ---------------------------------------------------------------------------
# Test 1 — bash -n syntax check on keyword-only-mode.sh
# ---------------------------------------------------------------------------
echo "=== Test 1: bash -n syntax check on keyword-only-mode.sh ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T1: bash -n keyword-only-mode.sh" "scripts/ directory not yet created"
elif [ ! -f "$KEYWORD_SCRIPT" ]; then
    skip "T1: bash -n keyword-only-mode.sh" "keyword-only-mode.sh does not exist yet"
else
    if bash -n "$KEYWORD_SCRIPT" 2>&1; then
        pass "T1: keyword-only-mode.sh passes bash -n syntax check"
    else
        fail "T1: bash -n keyword-only-mode.sh" "syntax error(s) found"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 2 — bash -n syntax check on history-docs-search.sh
# ---------------------------------------------------------------------------
echo "=== Test 2: bash -n syntax check on history-docs-search.sh ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T2: bash -n history-docs-search.sh" "scripts/ directory not yet created"
elif [ ! -f "$HISTORY_SCRIPT" ]; then
    skip "T2: bash -n history-docs-search.sh" "history-docs-search.sh does not exist yet"
else
    if bash -n "$HISTORY_SCRIPT" 2>&1; then
        pass "T2: history-docs-search.sh passes bash -n syntax check"
    else
        fail "T2: bash -n history-docs-search.sh" "syntax error(s) found"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 3 — bash -n syntax check on artifact-template.sh
# ---------------------------------------------------------------------------
echo "=== Test 3: bash -n syntax check on artifact-template.sh ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T3: bash -n artifact-template.sh" "scripts/ directory not yet created"
elif [ ! -f "$ARTIFACT_SCRIPT" ]; then
    skip "T3: bash -n artifact-template.sh" "artifact-template.sh does not exist yet"
else
    if bash -n "$ARTIFACT_SCRIPT" 2>&1; then
        pass "T3: artifact-template.sh passes bash -n syntax check"
    else
        fail "T3: bash -n artifact-template.sh" "syntax error(s) found"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 4 — keyword-only-mode.sh output contains "DEGRADED MODE"
# ---------------------------------------------------------------------------
echo "=== Test 4: keyword-only-mode.sh output contains 'DEGRADED MODE' ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T4: keyword-only-mode.sh DEGRADED MODE output" "scripts/ directory not yet created"
elif [ ! -f "$KEYWORD_SCRIPT" ]; then
    skip "T4: keyword-only-mode.sh DEGRADED MODE output" "keyword-only-mode.sh does not exist yet"
else
    output="$(bash "$KEYWORD_SCRIPT" 2>&1 || true)"
    if echo "$output" | grep -qF "DEGRADED MODE"; then
        pass "T4: keyword-only-mode.sh output contains 'DEGRADED MODE'"
    else
        fail "T4: keyword-only-mode.sh DEGRADED MODE output" "'DEGRADED MODE' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 4b — SKILL.md retains "Do NOT invoke make-outline-plan" control-flow instruction
# (this line stays in SKILL.md, not in the script template — by design)
# ---------------------------------------------------------------------------
echo "=== Test 4b: SKILL.md retains 'Do NOT invoke make-outline-plan' control-flow instruction ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T4b: SKILL.md control-flow instruction" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T4b: SKILL.md control-flow instruction" "SKILL.md not found"
else
    if grep -qF 'Do NOT invoke make-outline-plan' "$SKILL_MD"; then
        pass "T4b: SKILL.md retains 'Do NOT invoke make-outline-plan' control-flow instruction"
    else
        fail "T4b: SKILL.md control-flow instruction" "'Do NOT invoke make-outline-plan' not found in SKILL.md"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 5 — history-docs-search.sh --since 2025-01-01 output contains "docs/history.md"
# ---------------------------------------------------------------------------
echo "=== Test 5: history-docs-search.sh --since 2025-01-01 mentions docs/history.md ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T5: history-docs-search.sh --since output" "scripts/ directory not yet created"
elif [ ! -f "$HISTORY_SCRIPT" ]; then
    skip "T5: history-docs-search.sh --since output" "history-docs-search.sh does not exist yet"
else
    output="$(bash "$HISTORY_SCRIPT" --since 2025-01-01 2>&1 || true)"
    if echo "$output" | grep -qF "docs/history.md"; then
        pass "T5: history-docs-search.sh --since 2025-01-01 output contains 'docs/history.md'"
    else
        fail "T5: history-docs-search.sh --since output" "'docs/history.md' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 5b — history-docs-search.sh output contains "docs/history/index.md"
# ---------------------------------------------------------------------------
echo "=== Test 5b: history-docs-search.sh output mentions docs/history/index.md ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T5b: history-docs-search.sh index.md mention" "scripts/ directory not yet created"
elif [ ! -f "$HISTORY_SCRIPT" ]; then
    skip "T5b: history-docs-search.sh index.md mention" "history-docs-search.sh does not exist yet"
else
    output="$(bash "$HISTORY_SCRIPT" --since 2025-01-01 2>&1 || true)"
    if echo "$output" | grep -qF "docs/history/index.md"; then
        pass "T5b: history-docs-search.sh output mentions 'docs/history/index.md'"
    else
        fail "T5b: history-docs-search.sh index.md mention" "'docs/history/index.md' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 5c — history-docs-search.sh: --since is a no-op (output identical with and without)
# ---------------------------------------------------------------------------
echo "=== Test 5c: history-docs-search.sh --since is a no-op ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T5c: history-docs-search.sh --since no-op" "scripts/ directory not yet created"
elif [ ! -f "$HISTORY_SCRIPT" ]; then
    skip "T5c: history-docs-search.sh --since no-op" "history-docs-search.sh does not exist yet"
else
    out_with="$(bash "$HISTORY_SCRIPT" --since 2025-01-01 2>&1 || true)"
    out_without="$(bash "$HISTORY_SCRIPT" 2>&1 || true)"
    if [ "$out_with" = "$out_without" ]; then
        pass "T5c: history-docs-search.sh --since produces same output as bare invocation (no-op)"
    else
        fail "T5c: history-docs-search.sh --since no-op" "output differs: --since changes template output unexpectedly"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 6 — artifact-template.sh output contains "## Survey history"
# ---------------------------------------------------------------------------
echo "=== Test 6: artifact-template.sh output contains '## Survey history' ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T6: artifact-template.sh Survey history output" "scripts/ directory not yet created"
elif [ ! -f "$ARTIFACT_SCRIPT" ]; then
    skip "T6: artifact-template.sh Survey history output" "artifact-template.sh does not exist yet"
else
    output="$(bash "$ARTIFACT_SCRIPT" 2>&1 || true)"
    if echo "$output" | grep -qF "## Survey history"; then
        pass "T6: artifact-template.sh output contains '## Survey history'"
    else
        fail "T6: artifact-template.sh Survey history output" "'## Survey history' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 6b — artifact-template.sh output contains "## Verified Claims"
# ---------------------------------------------------------------------------
echo "=== Test 6b: artifact-template.sh output contains '## Verified Claims' ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T6b: artifact-template.sh Verified Claims section" "scripts/ directory not yet created"
elif [ ! -f "$ARTIFACT_SCRIPT" ]; then
    skip "T6b: artifact-template.sh Verified Claims section" "artifact-template.sh does not exist yet"
else
    output="$(bash "$ARTIFACT_SCRIPT" 2>&1 || true)"
    if echo "$output" | grep -qF "## Verified Claims"; then
        pass "T6b: artifact-template.sh output contains '## Verified Claims'"
    else
        fail "T6b: artifact-template.sh Verified Claims section" "'## Verified Claims' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 6c — artifact-template.sh output contains "## Candidate class members"
# ---------------------------------------------------------------------------
echo "=== Test 6c: artifact-template.sh output contains '## Candidate class members' ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T6c: artifact-template.sh Candidate class members section" "scripts/ directory not yet created"
elif [ ! -f "$ARTIFACT_SCRIPT" ]; then
    skip "T6c: artifact-template.sh Candidate class members section" "artifact-template.sh does not exist yet"
else
    output="$(bash "$ARTIFACT_SCRIPT" 2>&1 || true)"
    if echo "$output" | grep -qF "## Candidate class members"; then
        pass "T6c: artifact-template.sh output contains '## Candidate class members'"
    else
        fail "T6c: artifact-template.sh Candidate class members section" "'## Candidate class members' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 6d — artifact-template.sh output contains "## Premise impact assessment"
# ---------------------------------------------------------------------------
echo "=== Test 6d: artifact-template.sh output contains '## Premise impact assessment' ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T6d: artifact-template.sh Premise impact assessment section" "scripts/ directory not yet created"
elif [ ! -f "$ARTIFACT_SCRIPT" ]; then
    skip "T6d: artifact-template.sh Premise impact assessment section" "artifact-template.sh does not exist yet"
else
    output="$(bash "$ARTIFACT_SCRIPT" 2>&1 || true)"
    if echo "$output" | grep -qF "## Premise impact assessment"; then
        pass "T6d: artifact-template.sh output contains '## Premise impact assessment'"
    else
        fail "T6d: artifact-template.sh Premise impact assessment section" "'## Premise impact assessment' not found in output"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 7 — all 3 scripts exit with code 0
# ---------------------------------------------------------------------------
echo "=== Test 7: all 3 scripts exit with code 0 ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T7: all scripts exit 0" "scripts/ directory not yet created"
else
    for script in "$KEYWORD_SCRIPT" "$HISTORY_SCRIPT" "$ARTIFACT_SCRIPT"; do
        name="$(basename "$script")"
        if [ ! -f "$script" ]; then
            skip "T7: $name exit 0" "script does not exist yet"
            continue
        fi
        if bash "$script" >/dev/null 2>&1; then
            pass "T7: $name exits with code 0"
        else
            ec=$?
            fail "T7: $name exit 0" "exited with code $ec"
        fi
    done
fi
echo ""

# ---------------------------------------------------------------------------
# Test 8 — SKILL.md line count < 100 (WARN resolved after implementation)
# ---------------------------------------------------------------------------
echo "=== Test 8: SKILL.md line count < 100 (WARN resolved) ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T8: SKILL.md line count < 100" "scripts/ not yet extracted — SKILL.md still contains inline blocks"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T8: SKILL.md line count" "SKILL.md not found"
else
    line_count="$(wc -l < "$SKILL_MD" | tr -d ' ')"
    if [ "$line_count" -lt 100 ]; then
        pass "T8: SKILL.md line count is $line_count (< 100, WARN resolved)"
    else
        fail "T8: SKILL.md line count < 100" "line count is $line_count (still >= 100)"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 9 — SKILL.md does NOT contain inline bash fenced block for PLANS_DIR
# ---------------------------------------------------------------------------
echo "=== Test 9: SKILL.md does NOT contain inline PLANS_DIR bash fenced block ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T9: SKILL.md no inline PLANS_DIR bash block" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T9: SKILL.md no inline PLANS_DIR bash block" "SKILL.md not found"
else
    # The old block contains `workflow-plans-dir` inside a ```bash fenced block
    inline_found=false
    if grep -qF 'workflow-plans-dir' "$SKILL_MD"; then
        # Check if it appears inside a fenced code block
        if awk '/^```bash/{in_block=1; next} /^```/{in_block=0} in_block && /workflow-plans-dir/{found=1} END{exit !found}' "$SKILL_MD"; then
            inline_found=true
        fi
    fi
    if [ "$inline_found" = true ]; then
        fail "T9: SKILL.md no inline PLANS_DIR bash block" "inline bash fenced block with workflow-plans-dir still present"
    else
        pass "T9: SKILL.md does not contain inline bash fenced PLANS_DIR block"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 10 — SKILL.md references skills/_shared/resolve-plans-dir.md
# ---------------------------------------------------------------------------
echo "=== Test 10: SKILL.md references skills/_shared/resolve-plans-dir.md ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T10: SKILL.md references resolve-plans-dir.md" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T10: SKILL.md references resolve-plans-dir.md" "SKILL.md not found"
else
    if grep -qF 'skills/_shared/resolve-plans-dir.md' "$SKILL_MD"; then
        pass "T10: SKILL.md references skills/_shared/resolve-plans-dir.md"
    else
        fail "T10: SKILL.md references resolve-plans-dir.md" "reference not found in SKILL.md"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 11 — SKILL.md calls keyword-only-mode.sh
# ---------------------------------------------------------------------------
echo "=== Test 11: SKILL.md calls skills/survey-history/scripts/keyword-only-mode.sh ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T11: SKILL.md calls keyword-only-mode.sh" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T11: SKILL.md calls keyword-only-mode.sh" "SKILL.md not found"
else
    if grep -qF 'skills/survey-history/scripts/keyword-only-mode.sh' "$SKILL_MD"; then
        pass "T11: SKILL.md references skills/survey-history/scripts/keyword-only-mode.sh"
    else
        fail "T11: SKILL.md calls keyword-only-mode.sh" "call not found in SKILL.md"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 12 — SKILL.md calls history-docs-search.sh
# ---------------------------------------------------------------------------
echo "=== Test 12: SKILL.md calls skills/survey-history/scripts/history-docs-search.sh ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T12: SKILL.md calls history-docs-search.sh" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T12: SKILL.md calls history-docs-search.sh" "SKILL.md not found"
else
    if grep -qF 'skills/survey-history/scripts/history-docs-search.sh' "$SKILL_MD"; then
        pass "T12: SKILL.md references skills/survey-history/scripts/history-docs-search.sh"
    else
        fail "T12: SKILL.md calls history-docs-search.sh" "call not found in SKILL.md"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 12b — SKILL.md calls history-docs-search.sh with --since argument
# ---------------------------------------------------------------------------
echo "=== Test 12b: SKILL.md calls history-docs-search.sh with '--since' argument ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T12b: SKILL.md --since argument" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T12b: SKILL.md --since argument" "SKILL.md not found"
else
    if grep -qF 'history-docs-search.sh" --since' "$SKILL_MD"; then
        pass "T12b: SKILL.md calls history-docs-search.sh with --since argument"
    else
        fail "T12b: SKILL.md --since argument" "--since not found in history-docs-search.sh call in SKILL.md"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 13 — SKILL.md calls artifact-template.sh
# ---------------------------------------------------------------------------
echo "=== Test 13: SKILL.md calls skills/survey-history/scripts/artifact-template.sh ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T13: SKILL.md calls artifact-template.sh" "implementation not yet done"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T13: SKILL.md calls artifact-template.sh" "SKILL.md not found"
else
    if grep -qF 'skills/survey-history/scripts/artifact-template.sh' "$SKILL_MD"; then
        pass "T13: SKILL.md references skills/survey-history/scripts/artifact-template.sh"
    else
        fail "T13: SKILL.md calls artifact-template.sh" "call not found in SKILL.md"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 14 — Idempotency: running each script twice produces identical output
# ---------------------------------------------------------------------------
echo "=== Test 14: idempotency — running each script twice produces identical output ==="
if [ "$IMPL_DONE" = false ]; then
    skip "T14: script idempotency" "scripts/ directory not yet created"
else
    for script in "$KEYWORD_SCRIPT" "$HISTORY_SCRIPT" "$ARTIFACT_SCRIPT"; do
        name="$(basename "$script")"
        if [ ! -f "$script" ]; then
            skip "T14: $name idempotency" "script does not exist yet"
            continue
        fi
        out1="$(bash "$script" 2>&1 || true)"
        out2="$(bash "$script" 2>&1 || true)"
        if [ "$out1" = "$out2" ]; then
            pass "T14: $name produces identical output on two runs"
        else
            fail "T14: $name idempotency" "output differs between runs"
        fi
    done
fi
echo ""

# ---------------------------------------------------------------------------
# Test 15 — bin/review-prompt-size shows no WARN/HARD for survey-history/SKILL.md
# ---------------------------------------------------------------------------
echo "=== Test 15: bin/review-prompt-size shows no WARN/HARD for survey-history/SKILL.md ==="
REVIEW_PROMPT_SIZE="$REPO_ROOT/bin/review-prompt-size"
if [ "$IMPL_DONE" = false ]; then
    skip "T15: review-prompt-size no WARN" "scripts not yet extracted — SKILL.md still WARN"
elif [ ! -f "$REVIEW_PROMPT_SIZE" ]; then
    skip "T15: review-prompt-size no WARN" "bin/review-prompt-size not found"
elif [ ! -f "$SKILL_MD" ]; then
    skip "T15: review-prompt-size no WARN" "SKILL.md not found"
else
    review_output="$(cd "$REPO_ROOT" && bash "$REVIEW_PROMPT_SIZE" --all 2>&1 || true)"
    skill_rel="skills/survey-history/SKILL.md"
    file_line="$(echo "$review_output" | grep "$skill_rel" || true)"
    if [ -z "$file_line" ]; then
        # Not listed in output means no WARN/HARD — this is the expected success case
        pass "T15: review-prompt-size: skills/survey-history/SKILL.md not in WARN/HARD list"
    elif echo "$file_line" | grep -qE '^(WARN|HARD):'; then
        fail "T15: review-prompt-size no WARN" "got: $file_line"
    else
        pass "T15: review-prompt-size shows no WARN/HARD for skills/survey-history/SKILL.md ($file_line)"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "============================================"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
