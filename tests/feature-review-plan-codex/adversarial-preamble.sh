# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Adversarial preamble: 'authored by Claude' present in codex prompt for both formats
# ===========================================================================

# ---------------------------------------------------------------------------
# 19. Adversarial preamble: assert "authored by Claude" in prompt for detail-plan
# ---------------------------------------------------------------------------
CAPTURE_FILE="$TMPDIR_BASE/captured-prompt.txt"
cat > "$MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
# Write stdin (the prompt) to capture file, then succeed
cat > "$CAPTURE_FILE"
echo "APPROVED"
echo "captured"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log >/dev/null 2>&1 || true

if [[ -f "$CAPTURE_FILE" ]] && grep -q "authored by Claude" "$CAPTURE_FILE"; then
    pass "Adversarial preamble (detail-plan): 'authored by Claude' present in prompt"
else
    fail "Adversarial preamble (detail-plan): 'authored by Claude' not found in captured prompt. File exists: $([ -f "$CAPTURE_FILE" ] && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------
# 20. Adversarial preamble: assert "authored by Claude" in prompt for outline-plan
# ---------------------------------------------------------------------------
CAPTURE_FILE2="$TMPDIR_BASE/captured-prompt-outline-plan.txt"
cat > "$MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
cat > "$CAPTURE_FILE2"
echo "APPROVED directionally sound"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

run_script "$MOCK_BIN:$PATH" --format outline-plan --no-log >/dev/null 2>&1 || true

if [[ -f "$CAPTURE_FILE2" ]] && grep -q "authored by Claude" "$CAPTURE_FILE2"; then
    pass "Adversarial preamble (outline-plan): 'authored by Claude' present in prompt"
else
    fail "Adversarial preamble (outline-plan): 'authored by Claude' not found in captured prompt. File exists: $([ -f "$CAPTURE_FILE2" ] && echo yes || echo no)"
fi

