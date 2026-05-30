#!/usr/bin/env bash
# tests/feature-630-skill-scripts-extraction.sh
#
# Tests for feature/630-skill-scripts-extraction:
#   - rules/ rename: prompt-criteria→prompt, docs-convention→docs, test-rules→test
#   - Repo root CLAUDE.md does not reference old rules/ paths
#   - Internal Sub-rules links in rules/docs.md, rules/test.md point to new dirs
#   - Inline code blocks extracted to skills/.../scripts/ files
#   - SKILL.md / _shared/codex-review-loop.md inline blocks removed
#   - rules/prompt.md contains §1.4 prohibition heading + text
#   - Scripts have set -euo pipefail and are executable (git mode 100755)
#
# Tests are written BEFORE implementation. They SKIP (not FAIL) when the
# implementation hasn't happened yet, and PASS once implementation completes.

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
# If rules/prompt.md does not exist, the rename hasn't happened yet —
# skip every rename/structure test below.
# ---------------------------------------------------------------------------
RENAME_DONE=false
if [ -f "$REPO_ROOT/rules/prompt.md" ]; then
    RENAME_DONE=true
fi

# ---------------------------------------------------------------------------
# Test 1 — rules/prompt-criteria.md is GONE after rename
# ---------------------------------------------------------------------------
echo "=== Test 1: rules/prompt-criteria.md is GONE ==="
if [ "$RENAME_DONE" = false ]; then
    skip "T1: rules/prompt-criteria.md removed" "run after rules/ rename implementation"
else
    if [ ! -f "$REPO_ROOT/rules/prompt-criteria.md" ]; then
        pass "T1: rules/prompt-criteria.md no longer exists"
    else
        fail "T1: rules/prompt-criteria.md removed" "file still present"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 2 — rules/prompt.md EXISTS after rename
# ---------------------------------------------------------------------------
echo "=== Test 2: rules/prompt.md EXISTS ==="
if [ -f "$REPO_ROOT/rules/prompt.md" ]; then
    pass "T2: rules/prompt.md exists"
else
    skip "T2: rules/prompt.md exists" "run after rules/ rename implementation"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 3 — rules/docs-convention.md is GONE after rename
# ---------------------------------------------------------------------------
echo "=== Test 3: rules/docs-convention.md is GONE ==="
if [ "$RENAME_DONE" = false ]; then
    skip "T3: rules/docs-convention.md removed" "run after rules/ rename implementation"
else
    if [ ! -f "$REPO_ROOT/rules/docs-convention.md" ]; then
        pass "T3: rules/docs-convention.md no longer exists"
    else
        fail "T3: rules/docs-convention.md removed" "file still present"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 4 — rules/docs.md EXISTS after rename
# ---------------------------------------------------------------------------
echo "=== Test 4: rules/docs.md EXISTS ==="
if [ -f "$REPO_ROOT/rules/docs.md" ]; then
    pass "T4: rules/docs.md exists"
else
    skip "T4: rules/docs.md exists" "run after rules/ rename implementation"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 5 — rules/docs-convention/ directory is GONE after rename
# ---------------------------------------------------------------------------
echo "=== Test 5: rules/docs-convention/ directory is GONE ==="
if [ "$RENAME_DONE" = false ]; then
    skip "T5: rules/docs-convention/ removed" "run after rules/ rename implementation"
else
    if [ ! -d "$REPO_ROOT/rules/docs-convention" ]; then
        pass "T5: rules/docs-convention/ no longer exists"
    else
        fail "T5: rules/docs-convention/ removed" "directory still present"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 6 — rules/docs/ directory EXISTS after rename
# ---------------------------------------------------------------------------
echo "=== Test 6: rules/docs/ directory EXISTS ==="
if [ -d "$REPO_ROOT/rules/docs" ]; then
    pass "T6: rules/docs/ exists"
else
    skip "T6: rules/docs/ exists" "run after rules/ rename implementation"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 7 — rules/test-rules/ directory is GONE after rename
# ---------------------------------------------------------------------------
echo "=== Test 7: rules/test-rules/ directory is GONE ==="
if [ "$RENAME_DONE" = false ]; then
    skip "T7: rules/test-rules/ removed" "run after rules/ rename implementation"
else
    if [ ! -d "$REPO_ROOT/rules/test-rules" ]; then
        pass "T7: rules/test-rules/ no longer exists"
    else
        fail "T7: rules/test-rules/ removed" "directory still present"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 8 — rules/test/ directory EXISTS after rename
# ---------------------------------------------------------------------------
echo "=== Test 8: rules/test/ directory EXISTS ==="
if [ -d "$REPO_ROOT/rules/test" ]; then
    pass "T8: rules/test/ exists"
else
    skip "T8: rules/test/ exists" "run after rules/ rename implementation"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 9 — CLAUDE.md (repo root) does NOT reference old rules/ paths
# ---------------------------------------------------------------------------
echo "=== Test 9: CLAUDE.md does NOT reference old rules/ paths ==="
if [ "$RENAME_DONE" = false ]; then
    skip "T9: CLAUDE.md references" "run after rules/ rename implementation"
else
    CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
    if [ ! -f "$CLAUDE_MD" ]; then
        fail "T9: CLAUDE.md does NOT reference old paths" "CLAUDE.md not found"
    else
        any_fail=0
        for old in "prompt-criteria" "docs-convention" "test-rules"; do
            if grep -qF "$old" "$CLAUDE_MD"; then
                fail "T9: CLAUDE.md does NOT reference '$old'" "still referenced"
                any_fail=1
            fi
        done
        if [ "$any_fail" -eq 0 ]; then
            pass "T9: CLAUDE.md has no references to old rules/ paths"
        fi
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 10 — rules/docs.md Sub-rules links point to docs/ (not docs-convention/)
# ---------------------------------------------------------------------------
echo "=== Test 10: rules/docs.md Sub-rules links use docs/ ==="
if [ ! -f "$REPO_ROOT/rules/docs.md" ]; then
    skip "T10: rules/docs.md Sub-rules links" "rules/docs.md not yet created"
else
    DOCS_MD="$REPO_ROOT/rules/docs.md"
    if grep -qE '\]\(docs-convention/' "$DOCS_MD"; then
        fail "T10: rules/docs.md Sub-rules links" "still references docs-convention/ in links"
    else
        # Positive: must reference docs/ path somewhere
        if grep -qE '\]\(docs/' "$DOCS_MD"; then
            pass "T10: rules/docs.md links point to docs/"
        else
            fail "T10: rules/docs.md Sub-rules links" "no docs/ links found"
        fi
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 11 — rules/test.md Sub-rules links point to test/ (not test-rules/)
# ---------------------------------------------------------------------------
echo "=== Test 11: rules/test.md Sub-rules links use test/ ==="
if [ "$RENAME_DONE" = false ]; then
    skip "T11: rules/test.md Sub-rules links" "run after rules/ rename implementation"
else
    TEST_MD="$REPO_ROOT/rules/test.md"
    if [ ! -f "$TEST_MD" ]; then
        fail "T11: rules/test.md Sub-rules links" "rules/test.md not found"
    else
        if grep -qE '\]\(test-rules/' "$TEST_MD"; then
            fail "T11: rules/test.md Sub-rules links" "still references test-rules/ in links"
        else
            if grep -qE '\]\(test/' "$TEST_MD"; then
                pass "T11: rules/test.md links point to test/"
            else
                fail "T11: rules/test.md Sub-rules links" "no test/ links found"
            fi
        fi
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 12 — skills/make-detail-plan/scripts/run-codex-review-loop.sh EXISTS
# ---------------------------------------------------------------------------
echo "=== Test 12: make-detail-plan run-codex-review-loop.sh EXISTS ==="
DETAIL_SCRIPT="$REPO_ROOT/skills/make-detail-plan/scripts/run-codex-review-loop.sh"
if [ -f "$DETAIL_SCRIPT" ]; then
    pass "T12: $DETAIL_SCRIPT exists"
else
    skip "T12: detail-plan run-codex-review-loop.sh" "script not yet extracted"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 13 — skills/make-outline-plan/scripts/run-codex-review-loop.sh EXISTS
# ---------------------------------------------------------------------------
echo "=== Test 13: make-outline-plan run-codex-review-loop.sh EXISTS ==="
OUTLINE_SCRIPT="$REPO_ROOT/skills/make-outline-plan/scripts/run-codex-review-loop.sh"
if [ -f "$OUTLINE_SCRIPT" ]; then
    pass "T13: $OUTLINE_SCRIPT exists"
else
    skip "T13: outline-plan run-codex-review-loop.sh" "script not yet extracted"
fi
echo ""

# ---------------------------------------------------------------------------
# Test 14 — Both run-codex-review-loop.sh scripts contain `set -euo pipefail`
# ---------------------------------------------------------------------------
echo "=== Test 14: scripts contain 'set -euo pipefail' ==="
for s in "$DETAIL_SCRIPT" "$OUTLINE_SCRIPT"; do
    if [ ! -f "$s" ]; then
        skip "T14: $s 'set -euo pipefail'" "script does not exist yet"
        continue
    fi
    if grep -qF 'set -euo pipefail' "$s"; then
        pass "T14: $s contains 'set -euo pipefail'"
    else
        fail "T14: $s 'set -euo pipefail'" "directive not found"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Test 15 — Both scripts reference `bin/run-codex-review-loop`
# ---------------------------------------------------------------------------
echo "=== Test 15: scripts reference bin/run-codex-review-loop ==="
for s in "$DETAIL_SCRIPT" "$OUTLINE_SCRIPT"; do
    if [ ! -f "$s" ]; then
        skip "T15: $s references bin/run-codex-review-loop" "script does not exist yet"
        continue
    fi
    if grep -qF 'bin/run-codex-review-loop' "$s"; then
        pass "T15: $s references bin/run-codex-review-loop"
    else
        fail "T15: $s reference" "bin/run-codex-review-loop not referenced"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Test 16 — detail-plan script is executable (git ls-files --stage 100755)
# ---------------------------------------------------------------------------
echo "=== Test 16: detail-plan script is executable in git ==="
if [ ! -f "$DETAIL_SCRIPT" ]; then
    skip "T16: detail-plan script executable" "script does not exist yet"
else
    rel="skills/make-detail-plan/scripts/run-codex-review-loop.sh"
    mode="$(cd "$REPO_ROOT" && git ls-files --stage -- "$rel" 2>/dev/null | awk '{print $1}')"
    if [ -z "$mode" ]; then
        skip "T16: detail-plan script executable" "not tracked by git yet"
    elif [ "$mode" = "100755" ]; then
        pass "T16: $rel has git mode 100755"
    else
        fail "T16: detail-plan script executable" "git mode is $mode (want 100755)"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 17 — outline-plan script is executable (git ls-files --stage 100755)
# ---------------------------------------------------------------------------
echo "=== Test 17: outline-plan script is executable in git ==="
if [ ! -f "$OUTLINE_SCRIPT" ]; then
    skip "T17: outline-plan script executable" "script does not exist yet"
else
    rel="skills/make-outline-plan/scripts/run-codex-review-loop.sh"
    mode="$(cd "$REPO_ROOT" && git ls-files --stage -- "$rel" 2>/dev/null | awk '{print $1}')"
    if [ -z "$mode" ]; then
        skip "T17: outline-plan script executable" "not tracked by git yet"
    elif [ "$mode" = "100755" ]; then
        pass "T17: $rel has git mode 100755"
    else
        fail "T17: outline-plan script executable" "git mode is $mode (want 100755)"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 18 — make-detail-plan/SKILL.md does NOT contain inline run-codex-review-loop
# ---------------------------------------------------------------------------
echo "=== Test 18: make-detail-plan/SKILL.md inline block removed ==="
DETAIL_SKILL="$REPO_ROOT/skills/make-detail-plan/SKILL.md"
if [ ! -f "$DETAIL_SKILL" ]; then
    skip "T18: make-detail-plan/SKILL.md inline block" "SKILL.md not found"
elif [ ! -f "$DETAIL_SCRIPT" ]; then
    skip "T18: make-detail-plan/SKILL.md inline block" "extraction not yet performed"
else
    if grep -qF '$AGENTS_CONFIG_DIR/bin/run-codex-review-loop' "$DETAIL_SKILL"; then
        fail "T18: make-detail-plan/SKILL.md inline block" "inline reference still present"
    else
        pass "T18: make-detail-plan/SKILL.md no inline run-codex-review-loop reference"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 19 — make-outline-plan/SKILL.md does NOT contain inline run-codex-review-loop
# ---------------------------------------------------------------------------
echo "=== Test 19: make-outline-plan/SKILL.md inline block removed ==="
OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
if [ ! -f "$OUTLINE_SKILL" ]; then
    skip "T19: make-outline-plan/SKILL.md inline block" "SKILL.md not found"
elif [ ! -f "$OUTLINE_SCRIPT" ]; then
    skip "T19: make-outline-plan/SKILL.md inline block" "extraction not yet performed"
else
    if grep -qF '$AGENTS_CONFIG_DIR/bin/run-codex-review-loop' "$OUTLINE_SKILL"; then
        fail "T19: make-outline-plan/SKILL.md inline block" "inline reference still present"
    else
        pass "T19: make-outline-plan/SKILL.md no inline run-codex-review-loop reference"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 20 — skills/_shared/codex-review-loop.md does NOT contain inline block
# ---------------------------------------------------------------------------
echo "=== Test 20: _shared/codex-review-loop.md inline block removed ==="
SHARED_LOOP="$REPO_ROOT/skills/_shared/codex-review-loop.md"
if [ ! -f "$SHARED_LOOP" ]; then
    skip "T20: _shared/codex-review-loop.md inline block" "file not found"
elif [ ! -f "$DETAIL_SCRIPT" ] && [ ! -f "$OUTLINE_SCRIPT" ]; then
    skip "T20: _shared/codex-review-loop.md inline block" "extraction not yet performed"
else
    if grep -qF '$AGENTS_CONFIG_DIR/bin/run-codex-review-loop' "$SHARED_LOOP"; then
        fail "T20: _shared/codex-review-loop.md inline block" "inline reference still present"
    else
        pass "T20: _shared/codex-review-loop.md no inline run-codex-review-loop reference"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 21 — rules/prompt.md contains `### 1.4` heading
# ---------------------------------------------------------------------------
echo "=== Test 21: rules/prompt.md contains '### 1.4' heading ==="
PROMPT_MD="$REPO_ROOT/rules/prompt.md"
if [ ! -f "$PROMPT_MD" ]; then
    skip "T21: rules/prompt.md §1.4 heading" "rules/prompt.md not yet created"
else
    if grep -qE '^### 1\.4' "$PROMPT_MD"; then
        pass "T21: rules/prompt.md contains '### 1.4' heading"
    else
        fail "T21: rules/prompt.md §1.4 heading" "'### 1.4' heading not found"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 22 — rules/prompt.md §1.4 section contains prohibition text about code blocks
# ---------------------------------------------------------------------------
echo "=== Test 22: rules/prompt.md §1.4 contains code-block prohibition ==="
if [ ! -f "$PROMPT_MD" ]; then
    skip "T22: rules/prompt.md §1.4 prohibition" "rules/prompt.md not yet created"
else
    # Extract content from `### 1.4` to next heading
    section="$(awk '/^### 1\.4/{flag=1; next} /^### /{flag=0} flag' "$PROMPT_MD")"
    if [ -z "$section" ]; then
        fail "T22: rules/prompt.md §1.4 prohibition" "§1.4 section empty or heading missing"
    else
        # Must mention "code block" (case insensitive) and prohibition language
        if echo "$section" | grep -qiE 'code block' && \
           echo "$section" | grep -qiE 'inline|prohibit|must not|do not|forbidden|never'; then
            pass "T22: rules/prompt.md §1.4 contains code-block prohibition text"
        else
            fail "T22: rules/prompt.md §1.4 prohibition" "§1.4 lacks code-block prohibition language"
        fi
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 23 — OPTIONAL: detail-plan assemble-mandatory.sh executable + set -euo pipefail
# ---------------------------------------------------------------------------
echo "=== Test 23: OPTIONAL detail-plan assemble-mandatory.sh ==="
DETAIL_ASSEMBLE="$REPO_ROOT/skills/make-detail-plan/scripts/assemble-mandatory.sh"
if [ ! -f "$DETAIL_ASSEMBLE" ]; then
    skip "T23: detail-plan assemble-mandatory.sh" "optional script not present (acceptable)"
else
    any_fail=0
    if ! grep -qF 'set -euo pipefail' "$DETAIL_ASSEMBLE"; then
        fail "T23: detail-plan assemble-mandatory.sh" "missing 'set -euo pipefail'"
        any_fail=1
    fi
    rel="skills/make-detail-plan/scripts/assemble-mandatory.sh"
    mode="$(cd "$REPO_ROOT" && git ls-files --stage -- "$rel" 2>/dev/null | awk '{print $1}')"
    if [ -z "$mode" ]; then
        skip "T23: detail-plan assemble-mandatory.sh executable" "not tracked by git yet"
    elif [ "$mode" != "100755" ]; then
        fail "T23: detail-plan assemble-mandatory.sh executable" "git mode is $mode (want 100755)"
        any_fail=1
    fi
    if [ "$any_fail" -eq 0 ]; then
        pass "T23: detail-plan assemble-mandatory.sh is executable + has set -euo pipefail"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Test 24 — OPTIONAL: outline-plan assemble-mandatory.sh executable + set -euo pipefail
# ---------------------------------------------------------------------------
echo "=== Test 24: OPTIONAL outline-plan assemble-mandatory.sh ==="
OUTLINE_ASSEMBLE="$REPO_ROOT/skills/make-outline-plan/scripts/assemble-mandatory.sh"
if [ ! -f "$OUTLINE_ASSEMBLE" ]; then
    skip "T24: outline-plan assemble-mandatory.sh" "optional script not present (acceptable)"
else
    any_fail=0
    if ! grep -qF 'set -euo pipefail' "$OUTLINE_ASSEMBLE"; then
        fail "T24: outline-plan assemble-mandatory.sh" "missing 'set -euo pipefail'"
        any_fail=1
    fi
    rel="skills/make-outline-plan/scripts/assemble-mandatory.sh"
    mode="$(cd "$REPO_ROOT" && git ls-files --stage -- "$rel" 2>/dev/null | awk '{print $1}')"
    if [ -z "$mode" ]; then
        skip "T24: outline-plan assemble-mandatory.sh executable" "not tracked by git yet"
    elif [ "$mode" != "100755" ]; then
        fail "T24: outline-plan assemble-mandatory.sh executable" "git mode is $mode (want 100755)"
        any_fail=1
    fi
    if [ "$any_fail" -eq 0 ]; then
        pass "T24: outline-plan assemble-mandatory.sh is executable + has set -euo pipefail"
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
