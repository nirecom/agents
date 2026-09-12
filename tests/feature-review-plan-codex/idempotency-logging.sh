# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Idempotency across repeat runs, JSONL append-only logging
# ===========================================================================

# ---------------------------------------------------------------------------
# 8. Idempotency: two runs produce same exit code and status label
# ---------------------------------------------------------------------------
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "clean output"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

OUT1=$(run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log 2>&1 || true)
OUT2=$(run_script "$MOCK_BIN:$PATH" --format detail-plan --no-log 2>&1 || true)

STATUS1=$(echo "$OUT1" | grep "## Codex Plan Review:" | head -1)
STATUS2=$(echo "$OUT2" | grep "## Codex Plan Review:" | head -1)

if [[ "$STATUS1" == "$STATUS2" ]]; then
    pass "Idempotency: two runs produce same status label"
else
    fail "Idempotency: status labels differ. Run1='$STATUS1' Run2='$STATUS2'"
fi

# ---------------------------------------------------------------------------
# 9. JSONL append-only (two runs → two entries)
# ---------------------------------------------------------------------------
rm -rf "$LOG_DIR"
cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "findings"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --input "$PLAN_FILE" --format detail-plan >/dev/null 2>&1 || true
PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" --input "$PLAN_FILE" --format detail-plan >/dev/null 2>&1 || true

JSONL_COUNT=0
if ls "$LOG_DIR"/*.jsonl >/dev/null 2>&1; then
    JSONL_COUNT=$(cat "$LOG_DIR"/*.jsonl | wc -l)
fi

if (( JSONL_COUNT >= 2 )); then
    pass "JSONL idempotency: two runs produced $JSONL_COUNT entries (append-only)"
else
    fail "JSONL idempotency: expected >=2 entries, got $JSONL_COUNT"
fi

