# Tests: bin/review-plan-codex, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md, skills/make-detail-plan/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: outline, planning, detail, codex, review, scope:common
# ===========================================================================
# Issue #329 arg parsing: --cap, --max-extensions/--extensions-used, --session-id, --log-dir
# ===========================================================================

# ---------------------------------------------------------------------------
# 31. Issue #329 — new arg parsing: --cap 2 accepted (no arg-parse error)
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan --cap 2 --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "#329 --cap 2: expected exit 0, got $EXIT_CODE"
else
    pass "#329 --cap 2: exits 0 (arg accepted)"
fi

# Should not emit an "Unknown argument" or arg-parse error
if echo "$OUTPUT" | grep -qi "unknown argument: --cap\|invalid.*--cap"; then
    fail "#329 --cap 2: arg-parse error emitted. Output: $OUTPUT"
else
    pass "#329 --cap 2: no arg-parse error"
fi

# ---------------------------------------------------------------------------
# 32. #329 --max-extensions 2 --extensions-used 1 accepted
# ---------------------------------------------------------------------------
EXIT_CODE=0
OUTPUT=$(PATH="$MINIMAL_PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan \
  --max-extensions 2 --extensions-used 1 --no-log 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "#329 --max-extensions/--extensions-used: expected exit 0, got $EXIT_CODE"
else
    pass "#329 --max-extensions/--extensions-used: exits 0"
fi

if echo "$OUTPUT" | grep -qi "unknown argument: --max-extensions\|unknown argument: --extensions-used"; then
    fail "#329 --max-extensions/--extensions-used: arg-parse error. Output: $OUTPUT"
else
    pass "#329 --max-extensions/--extensions-used: no arg-parse error"
fi

# ---------------------------------------------------------------------------
# 33. #329 --session-id mysession accepted, log keyed to that session
# ---------------------------------------------------------------------------
CUSTOM_LOG="$TMPDIR_BASE/log-329-custom"
mkdir -p "$CUSTOM_LOG"

cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "APPROVED"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

EXIT_CODE=0
OUTPUT=$(PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan \
  --session-id "mysession329" --log-dir "$CUSTOM_LOG" 2>&1) || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    fail "#329 --session-id: expected exit 0, got $EXIT_CODE"
else
    pass "#329 --session-id: exits 0"
fi

# Look for any file in the custom log dir whose contents reference our session id
SESSION_FOUND=false
if [[ -d "$CUSTOM_LOG" ]]; then
    for f in "$CUSTOM_LOG"/*.jsonl; do
        [[ -f "$f" ]] || continue
        if grep -q "mysession329" "$f" 2>/dev/null || [[ "$(basename "$f")" == mysession329* ]]; then
            SESSION_FOUND=true
            break
        fi
    done
fi
if $SESSION_FOUND; then
    pass "#329 --session-id: log keyed to provided session id"
else
    fail "#329 --session-id: no log file references 'mysession329' in $CUSTOM_LOG"
fi

# ---------------------------------------------------------------------------
# 34. #329 --log-dir creates log in custom dir
# ---------------------------------------------------------------------------
CUSTOM_LOG2="$TMPDIR_BASE/log-329-customdir"

cat > "$MOCK_BIN/codex" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "APPROVED"
exit 0
MOCK_EOF
chmod +x "$MOCK_BIN/codex"

PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
  --input "$PLAN_FILE" --format detail-plan \
  --log-dir "$CUSTOM_LOG2" >/dev/null 2>&1 || true

if [[ -d "$CUSTOM_LOG2" ]] && ls "$CUSTOM_LOG2"/*.jsonl >/dev/null 2>&1; then
    pass "#329 --log-dir: log file created under custom dir"
else
    fail "#329 --log-dir: no log file under $CUSTOM_LOG2"
fi

