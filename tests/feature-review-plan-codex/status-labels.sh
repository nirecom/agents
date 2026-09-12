# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Status labels: SKIPPED / PERFORMED / FAILED / TIMEOUT, visibility invariant, JSONL-on-SKIPPED logging
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. SKIPPED — codex CLI not installed
# Use only minimal system paths so codex (in fnm/nvm/npm dirs) is not found,
# while bash, git, date, mktemp etc. remain accessible.
# ---------------------------------------------------------------------------
MINIMAL_PATH="/usr/local/bin:/usr/bin:/bin"
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --input "$PLAN_FILE" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "SKIPPED case: expected exit 0, got $EXIT_CODE"
else
    pass "SKIPPED case: exits 0 when codex not found"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: SKIPPED — codex CLI not installed"; then
    pass "SKIPPED case: correct status label present"
else
    fail "SKIPPED case: status label missing. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 2. Visibility invariant — status label always present in all outputs
# ---------------------------------------------------------------------------
if echo "$OUTPUT" | grep -q "## Codex Plan Review:"; then
    pass "Visibility invariant: status label always present in SKIPPED case"
else
    fail "Visibility invariant: no '## Codex Plan Review:' line in SKIPPED output"
fi

# ---------------------------------------------------------------------------
# 3. JSONL logging on SKIPPED
# ---------------------------------------------------------------------------
PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --input "$PLAN_FILE" --format detail-plan >/dev/null 2>&1 || true
if ls "$LOG_DIR"/*.jsonl >/dev/null 2>&1; then
    if grep -q '"status":"skipped"' "$LOG_DIR"/*.jsonl; then
        pass "JSONL logging: skipped status written"
    else
        fail "JSONL logging: expected 'skipped' in JSONL. Contents: $(cat "$LOG_DIR"/*.jsonl 2>/dev/null)"
    fi
else
    fail "JSONL logging: no log file created under $LOG_DIR"
fi

# ---------------------------------------------------------------------------
# 4. PERFORMED — mock codex exits 0
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "APPROVED"
echo "The plan looks solid."
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "PERFORMED case: expected exit 0, got $EXIT_CODE"
else
    pass "PERFORMED case: exits 0"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: PERFORMED"; then
    pass "PERFORMED case: correct status label present"
else
    fail "PERFORMED case: status label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "begin-codex-output"; then
    pass "PERFORMED case: output wrapped in safety comment block"
else
    fail "PERFORMED case: output not wrapped. Output: $OUTPUT"
fi

# ---------------------------------------------------------------------------
# 5. FAILED — mock codex exits non-zero
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "some error" >&2
exit 2
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "FAILED case: expected exit 0, got $EXIT_CODE"
else
    pass "FAILED case: exits 0 despite codex failure"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED — codex exec exit code 2"; then
    pass "FAILED case: correct status label present"
else
    fail "FAILED case: status label missing. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review:"; then
    pass "Visibility invariant: status label present in FAILED case"
else
    fail "Visibility invariant: no '## Codex Plan Review:' in FAILED output"
fi

# ---------------------------------------------------------------------------
# 6. FAILED — simulate timeout via a wrapper that makes codex return exit 124
# ---------------------------------------------------------------------------
TIMEOUT_BIN="$TMPDIR_BASE/timeout-shim-bin"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/timeout" << 'MOCK_EOF'
#!/usr/bin/env bash
shift  # drop the timeout duration arg
"$@" >/dev/null 2>&1 || true
exit 124
MOCK_EOF
chmod +x "$TIMEOUT_BIN/timeout"

cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "would run forever"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

OUTPUT=$(PATH="$TIMEOUT_BIN:$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --input "$PLAN_FILE" --format detail-plan --no-log 2>&1 || true)
EXIT_CODE=0
(PATH="$TIMEOUT_BIN:$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" bash "$SCRIPT" --input "$PLAN_FILE" --format detail-plan --no-log >/dev/null 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "TIMEOUT case: expected exit 0, got $EXIT_CODE"
else
    pass "TIMEOUT case: exits 0 despite codex timeout"
fi

if echo "$OUTPUT" | grep -q "## Codex Plan Review: FAILED — timeout"; then
    pass "TIMEOUT case: correct status label present"
else
    fail "TIMEOUT case: status label missing. Output: $OUTPUT"
fi

