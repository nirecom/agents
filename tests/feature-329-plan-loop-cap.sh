#!/usr/bin/env bash
# Tests: bin/review-plan-codex
# Tags: 329, plan-loop-cap
# Integration tests for bin/review-plan-codex with new round-counter / cap args
# (--cap, --max-extensions, --extensions-used, --session-id, --log-dir,
#  --accepted-tradeoffs).
# Uses a mock codex placed on PATH.
#
# Tests will FAIL until the new args + cap logic are implemented.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-plan-codex"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 70 "$@"
    else
        perl -e 'alarm 70; exec @ARGV' -- "$@"
    fi
}

PLAN_FILE="$TMPDIR_BASE/plan.md"
cat > "$PLAN_FILE" << 'PLAN_EOF'
# Implementation Plan
## Phase 1
- Step one
- Step two
PLAN_EOF

# Mock codex bin dir
MOCK_BIN="$TMPDIR_BASE/mock-bin"
mkdir -p "$MOCK_BIN"

# Mock codex captures its prompt (stdin) to a file and emits configurable output
CAPTURE_FILE="$TMPDIR_BASE/codex-stdin-capture.txt"
make_mock_codex() {
    local response="$1"
    cat > "$MOCK_BIN/codex" << MOCK_EOF
#!/usr/bin/env bash
# Drain any args, capture stdin to a file
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-" ]]; then
    shift
    cat > "$CAPTURE_FILE"
    break
  fi
  shift
done
# Fallback: also read stdin if it wasn't captured above
if [[ ! -s "$CAPTURE_FILE" ]]; then
  cat > "$CAPTURE_FILE" 2>/dev/null || true
fi
printf '%s\n' "$response"
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

# Helper: run the script with given log dir + session id
run_with_log() {
    local log_dir="$1"; shift
    local sess="$1"; shift
    PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
        _timeout bash "$SCRIPT" \
        --input "$PLAN_FILE" --format detail-plan \
        --log-dir "$log_dir" --session-id "$sess" \
        "$@" 2>&1 || true
}

# ---------------------------------------------------------------------------
# 1. First call (no log) → PERFORMED + ROUND_LOG has 1 row for session/label
# ---------------------------------------------------------------------------
make_mock_codex "APPROVED"$'\n'"plan ok"

LOG_DIR1="$TMPDIR_BASE/log1"
mkdir -p "$LOG_DIR1"
OUT=$(run_with_log "$LOG_DIR1" "sess001" --cap 2 --extensions-used 0 --max-extensions 2 --no-log)

if echo "$OUT" | grep -q "## Codex Plan Review: PERFORMED"; then
    pass "first call: PERFORMED label present"
else
    fail "first call: PERFORMED missing. Output: $OUT"
fi

# Round log: implementation creates ${log_dir}/${session_id}-plan.jsonl
ROUND_LOG="$LOG_DIR1/sess001-plan.jsonl"
if [[ -f "$ROUND_LOG" ]]; then
    COUNT=$(jq -s '[.[] | select(.session=="sess001" and .label=="detail-plan")] | length' "$ROUND_LOG" 2>/dev/null || grep -c '"sess001"' "$ROUND_LOG" 2>/dev/null || echo 0)
    if [[ "$COUNT" -ge 1 ]]; then
        pass "first call: round log has >=1 row for sess001"
    else
        fail "first call: round log present but no sess001 row. File: $ROUND_LOG"
    fi
else
    fail "first call: round log not created under $LOG_DIR1"
fi

# ---------------------------------------------------------------------------
# 2. --cap 2 --extensions-used 2 --max-extensions 2, 4 rows present
#    → FAILED "absolute ceiling reached"; no codex invocation
# ---------------------------------------------------------------------------
LOG_DIR2="$TMPDIR_BASE/log2"
mkdir -p "$LOG_DIR2"
# Pre-populate with 4 rows for sess002/detail-plan using the implementation's field names
ROUND_LOG2="$LOG_DIR2/sess002-plan.jsonl"
for i in 1 2 3 4; do
    printf '{"session":"sess002","label":"detail-plan","verdict":"X","ts":"t%d","round":%d,"severity_summary":""}\n' "$i" "$i" >> "$ROUND_LOG2"
done

# Make codex emit something distinctive so we can detect if it ran
make_mock_codex "SHOULD_NOT_APPEAR"

OUT=$(run_with_log "$LOG_DIR2" "sess002" --cap 2 --extensions-used 2 --max-extensions 2 --no-log)

if echo "$OUT" | grep -q "## Codex Plan Review: FAILED" && echo "$OUT" | grep -qi "absolute ceiling reached"; then
    pass "ceiling: FAILED with 'absolute ceiling reached'"
else
    fail "ceiling: expected FAILED + 'absolute ceiling reached'. Output: $OUT"
fi

if echo "$OUT" | grep -q "SHOULD_NOT_APPEAR"; then
    fail "ceiling: codex was invoked despite ceiling"
else
    pass "ceiling: codex not invoked"
fi

# ---------------------------------------------------------------------------
# 3. --cap 2 --extensions-used 0 --max-extensions 2, 2 rows → "extension available"
# ---------------------------------------------------------------------------
LOG_DIR3="$TMPDIR_BASE/log3"
mkdir -p "$LOG_DIR3"
ROUND_LOG3="$LOG_DIR3/sess003-plan.jsonl"
for i in 1 2; do
    printf '{"session":"sess003","label":"detail-plan","verdict":"X","ts":"t%d","round":%d,"severity_summary":""}\n' "$i" "$i" >> "$ROUND_LOG3"
done

make_mock_codex "APPROVED"

OUT=$(run_with_log "$LOG_DIR3" "sess003" --cap 2 --extensions-used 0 --max-extensions 2 --no-log)

if echo "$OUT" | grep -q "## Codex Plan Review: FAILED" && echo "$OUT" | grep -qi "extension available"; then
    pass "at-limit: FAILED with 'extension available'"
else
    fail "at-limit: expected FAILED + 'extension available'. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 4. Read-only log dir → FAILED + "round log persistence failure" + no PERFORMED
# ---------------------------------------------------------------------------
case "$(uname -s)" in
    MINGW*|CYGWIN*|MSYS*)
        pass "read-only log dir: skipped on Windows (chmod unreliable)"
        ;;
    *)
        RO_LOG="$TMPDIR_BASE/ro-log"
        mkdir -p "$RO_LOG"
        chmod 555 "$RO_LOG"
        make_mock_codex "APPROVED"
        OUT=$(run_with_log "$RO_LOG" "sess004" --cap 2 --extensions-used 0 --max-extensions 2 --no-log)
        chmod 755 "$RO_LOG"

        if echo "$OUT" | grep -q "## Codex Plan Review: FAILED" && echo "$OUT" | grep -qi "round log persistence failure"; then
            pass "read-only log dir: FAILED + 'round log persistence failure'"
        else
            fail "read-only log dir: expected FAILED + 'round log persistence failure'. Output: $OUT"
        fi

        if echo "$OUT" | grep -q "## Codex Plan Review: PERFORMED"; then
            fail "read-only log dir: PERFORMED unexpectedly present (log-before-emit contract violated)"
        else
            pass "read-only log dir: PERFORMED absent (log-before-emit contract)"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# 5. --accepted-tradeoffs <file>: content appears in codex prompt
# ---------------------------------------------------------------------------
TRADEOFFS_FILE="$TMPDIR_BASE/tradeoffs.md"
cat > "$TRADEOFFS_FILE" << 'TR_EOF'
## Accepted Tradeoffs
- Skipping bundle optimization (UNIQUE_TRADEOFF_MARKER_QWERTY)
TR_EOF

# Reset capture file
> "$CAPTURE_FILE"
make_mock_codex "APPROVED"

LOG_DIR5="$TMPDIR_BASE/log5"
mkdir -p "$LOG_DIR5"
OUT=$(run_with_log "$LOG_DIR5" "sess005" --cap 2 --extensions-used 0 --max-extensions 2 \
        --accepted-tradeoffs "$TRADEOFFS_FILE" --no-log)

if [[ -s "$CAPTURE_FILE" ]] && grep -q "UNIQUE_TRADEOFF_MARKER_QWERTY" "$CAPTURE_FILE"; then
    pass "--accepted-tradeoffs: content reached codex prompt"
else
    fail "--accepted-tradeoffs: marker not found in codex prompt. Capture: $(cat "$CAPTURE_FILE" 2>/dev/null | head -20)"
fi

# ---------------------------------------------------------------------------
# 6. --extensions-used 3 --max-extensions 2 → FAILED validation error (exit 0)
# ---------------------------------------------------------------------------
make_mock_codex "APPROVED"
LOG_DIR6="$TMPDIR_BASE/log6"
mkdir -p "$LOG_DIR6"

EXIT_CODE=0
OUT=$(PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" _timeout bash "$SCRIPT" \
    --input "$PLAN_FILE" --format detail-plan \
    --log-dir "$LOG_DIR6" --session-id "sess006" \
    --cap 2 --extensions-used 3 --max-extensions 2 --no-log 2>&1) || EXIT_CODE=$?

if [[ "$EXIT_CODE" == "0" ]]; then
    pass "extensions-used > max-extensions: exit 0"
else
    fail "extensions-used > max-extensions: expected exit 0, got $EXIT_CODE"
fi

if echo "$OUT" | grep -q "## Codex Plan Review: FAILED"; then
    pass "extensions-used > max-extensions: FAILED label present"
else
    fail "extensions-used > max-extensions: FAILED missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 7. Numbering: mock returns NEEDS_REVISION + numbered prefixed concerns
# ---------------------------------------------------------------------------
make_mock_codex "NEEDS_REVISION"$'\n'"1. [HIGH] issue alpha"
LOG_DIR7="$TMPDIR_BASE/log7"
mkdir -p "$LOG_DIR7"
OUT=$(run_with_log "$LOG_DIR7" "sess007" --cap 2 --extensions-used 0 --max-extensions 2 --no-log)

if echo "$OUT" | grep -q "1. \[HIGH\]"; then
    pass "numbering: '1. [HIGH]' passes through validator"
else
    fail "numbering: '1. [HIGH]' missing from output. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
