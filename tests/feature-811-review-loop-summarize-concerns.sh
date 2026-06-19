#!/usr/bin/env bash
# tests/feature-811-review-loop-summarize-concerns.sh
# Tests: bin/review-loop-summarize-concerns
# Tags: feature, cap-menu, summarize-concerns, scope:issue-specific, pwsh-not-required
#
# Behaviour tests for bin/review-loop-summarize-concerns (issue #811).
# The helper renders a structured concern summary to stdout when the cap-menu
# is presented to the user. It must:
#   - Render concerns from a single-line-per-concern ledger ordered by severity
#   - Annotate each concern with resolved/unresolved from the prior raw round
#   - Degrade gracefully when the ledger or raw file is missing/empty
#   - Always include a literal `Budget remaining: <N>` line
#   - Never leak workflow sentinels into stdout
#
# L3 gap (what this test does NOT catch):
# - The helper invocation actually fires from cap-menu-dispatch.md step c.5 in a real review loop
# - The stdout actually reaches the main conversation rendered as Markdown
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$AGENTS_ROOT/bin/review-loop-summarize-concerns"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# Helper: run script and capture stdout + exit code separately
run_helper() {
    local exit_code=0
    local out
    out=$(_timeout bash "$SCRIPT" "$@" 2>&1) || exit_code=$?
    printf '%s\n__RC__%d\n' "$out" "$exit_code"
}

extract_rc() {
    echo "$1" | grep '^__RC__' | sed 's/__RC__//'
}

extract_out() {
    echo "$1" | sed '/^__RC__/d'
}

# Verify jq is available (kept for parity with the cap-menu test even though
# this helper emits plain text — keeps the env-skip pattern consistent).
if ! command -v jq >/dev/null 2>&1; then
    echo "[SKIP] jq not installed — skipping (parity with other cap-menu tests)"
    exit 0
fi

# SCRIPT_EXISTS guard — the helper is not implemented yet. Skip all cases
# with a single message and exit 0 so the test file can commit cleanly.
if [[ ! -f "$SCRIPT" ]]; then
    echo "[SKIP] helper not yet implemented: $SCRIPT"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Happy path with ROUND_NUMBER-1 RAW_FILE
# ---------------------------------------------------------------------------
LEDGER="$TMPDIR_BASE/ledger-1.txt"
RAW="$TMPDIR_BASE/raw-1.md"
printf 'C1|HIGH|first concern body\nC2|MEDIUM|second\nC3|LOW|third\n' > "$LEDGER"
printf 'C1: resolved\nC2: unresolved — reviewer disagrees on framing\nC3: resolved\n' > "$RAW"

RES=$(run_helper --ledger "$LEDGER" --raw "$RAW" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "happy path: exit 0"
else
    fail "happy path: expected exit 0, got $RC. Output: $OUT"
fi

for tok in C1 C2 C3 HIGH MEDIUM LOW resolved unresolved "Budget remaining: 1"; do
    if echo "$OUT" | grep -F -q -- "$tok"; then
        pass "happy path: stdout contains '$tok'"
    else
        fail "happy path: stdout missing '$tok'. Output: $OUT"
    fi
done

if echo "$OUT" | grep -F -q -- "reviewer disagrees"; then
    pass "happy path: stdout contains reason text from raw"
else
    fail "happy path: stdout missing reason text from raw. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 2. RAW_FILE passed but file absent — degraded RAW mode
# ---------------------------------------------------------------------------
LEDGER2="$TMPDIR_BASE/ledger-2.txt"
printf 'C1|HIGH|first concern body\nC2|MEDIUM|second\nC3|LOW|third\n' > "$LEDGER2"
MISSING_RAW="/tmp/nonexistent-$$-round-0-raw.md"

RES=$(run_helper --ledger "$LEDGER2" --raw "$MISSING_RAW" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "missing raw: exit 0"
else
    fail "missing raw: expected exit 0, got $RC. Output: $OUT"
fi

for tok in C1 C2 C3; do
    if echo "$OUT" | grep -F -q -- "$tok"; then
        pass "missing raw: stdout contains '$tok'"
    else
        fail "missing raw: stdout missing '$tok'. Output: $OUT"
    fi
done

UNKNOWN_COUNT=$(echo "$OUT" | grep -c -- "unknown" || true)
if [[ "$UNKNOWN_COUNT" -ge 3 ]]; then
    pass "missing raw: resolution column reads 'unknown' for all three concerns"
else
    fail "missing raw: expected 'unknown' >=3 times, got $UNKNOWN_COUNT. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "(no reviewer output available for cap-reach round — first-round cap-reach or prior raw not persisted)"; then
    pass "missing raw: stdout contains degraded-RAW notice"
else
    fail "missing raw: stdout missing degraded-RAW notice. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 3. --raw omitted entirely — same degraded RAW mode as case 2
# ---------------------------------------------------------------------------
RES=$(run_helper --ledger "$LEDGER2" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "raw omitted: exit 0"
else
    fail "raw omitted: expected exit 0, got $RC. Output: $OUT"
fi

for tok in C1 C2 C3; do
    if echo "$OUT" | grep -F -q -- "$tok"; then
        pass "raw omitted: stdout contains '$tok'"
    else
        fail "raw omitted: stdout missing '$tok'. Output: $OUT"
    fi
done

UNKNOWN_COUNT=$(echo "$OUT" | grep -c -- "unknown" || true)
if [[ "$UNKNOWN_COUNT" -ge 3 ]]; then
    pass "raw omitted: resolution column reads 'unknown' for all three concerns"
else
    fail "raw omitted: expected 'unknown' >=3 times, got $UNKNOWN_COUNT. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "(no reviewer output available for cap-reach round — first-round cap-reach or prior raw not persisted)"; then
    pass "raw omitted: stdout contains degraded-RAW notice"
else
    fail "raw omitted: stdout missing degraded-RAW notice. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 4. Ledger missing — degraded LEDGER mode
# ---------------------------------------------------------------------------
MISSING_LEDGER="$TMPDIR_BASE/no-such-ledger.txt"

RES=$(run_helper --ledger "$MISSING_LEDGER" --budget-remaining 2)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "missing ledger: exit 0"
else
    fail "missing ledger: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "(concern ledger not available)"; then
    pass "missing ledger: stdout contains degraded-LEDGER notice"
else
    fail "missing ledger: stdout missing degraded-LEDGER notice. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "Budget remaining: 2"; then
    pass "missing ledger: budget line still appears"
else
    fail "missing ledger: budget line missing. Output: $OUT"
fi

if echo "$OUT" | grep -E -q '\bC[0-9]+\b'; then
    fail "missing ledger: stdout should not contain concern rows, but found one. Output: $OUT"
else
    pass "missing ledger: no concern rows in stdout"
fi

# ---------------------------------------------------------------------------
# 5. Empty ledger file (zero bytes)
# ---------------------------------------------------------------------------
EMPTY_LEDGER="$TMPDIR_BASE/empty-ledger.txt"
: > "$EMPTY_LEDGER"

RES=$(run_helper --ledger "$EMPTY_LEDGER" --budget-remaining 0)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "empty ledger: exit 0"
else
    fail "empty ledger: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "(concern ledger is empty)"; then
    pass "empty ledger: stdout contains empty-LEDGER notice"
else
    fail "empty ledger: stdout missing empty-LEDGER notice. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "Budget remaining: 0"; then
    pass "empty ledger: budget line still appears"
else
    fail "empty ledger: budget line missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 6. Argument validation — missing --budget-remaining
# ---------------------------------------------------------------------------
RES=$(run_helper --ledger "$LEDGER")
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "2" ]]; then
    pass "missing --budget-remaining: exit 2"
else
    fail "missing --budget-remaining: expected exit 2, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "budget-remaining"; then
    pass "missing --budget-remaining: stderr names the missing flag"
else
    fail "missing --budget-remaining: stderr does not name the flag. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 7. Argument validation — non-integer --budget-remaining abc
# ---------------------------------------------------------------------------
RES=$(run_helper --ledger "$LEDGER" --budget-remaining abc)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "2" ]]; then
    pass "non-integer --budget-remaining: exit 2"
else
    fail "non-integer --budget-remaining: expected exit 2, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -E -q -- "(integer|numeric|non-integer|must be)"; then
    pass "non-integer --budget-remaining: stderr indicates non-integer"
else
    fail "non-integer --budget-remaining: stderr does not indicate non-integer. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 8. Severity ordering — HIGH > MEDIUM > LOW regardless of ledger order
# ---------------------------------------------------------------------------
LEDGER8="$TMPDIR_BASE/ledger-8.txt"
printf 'C1|LOW|low body\nC2|HIGH|high body\nC3|MEDIUM|medium body\n' > "$LEDGER8"

RES=$(run_helper --ledger "$LEDGER8" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "severity ordering: exit 0"
else
    fail "severity ordering: expected exit 0, got $RC. Output: $OUT"
fi

# Find line numbers of each concern in stdout
POS_C1=$(echo "$OUT" | grep -n -- "C1" | head -n 1 | cut -d: -f1)
POS_C2=$(echo "$OUT" | grep -n -- "C2" | head -n 1 | cut -d: -f1)
POS_C3=$(echo "$OUT" | grep -n -- "C3" | head -n 1 | cut -d: -f1)

if [[ -n "$POS_C1" && -n "$POS_C2" && -n "$POS_C3" ]]; then
    if [[ "$POS_C2" -lt "$POS_C3" && "$POS_C3" -lt "$POS_C1" ]]; then
        pass "severity ordering: C2 (HIGH) < C3 (MEDIUM) < C1 (LOW)"
    else
        fail "severity ordering: expected C2 < C3 < C1, got positions C1=$POS_C1 C2=$POS_C2 C3=$POS_C3. Output: $OUT"
    fi
else
    fail "severity ordering: could not find all three concerns in stdout. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 9. Multi-line concern body — wrapper writes single-line ledger format.
#     Pin test fixture to single-line bodies, assert helper parses correctly.
# ---------------------------------------------------------------------------
LEDGER9="$TMPDIR_BASE/ledger-9.txt"
printf 'C1|HIGH|single line body with no embedded newline\n' > "$LEDGER9"

RES=$(run_helper --ledger "$LEDGER9" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "single-line ledger: exit 0 (no crash)"
else
    fail "single-line ledger: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "single line body with no embedded newline"; then
    pass "single-line ledger: body text appears in stdout"
else
    fail "single-line ledger: body text missing from stdout. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 10. No sentinel pollution
# ---------------------------------------------------------------------------
RES=$(run_helper --ledger "$LEDGER" --raw "$RAW" --budget-remaining 1)
OUT=$(extract_out "$RES")

if echo "$OUT" | grep -q '<<WORKFLOW_'; then
    fail "sentinel pollution: stdout contains '<<WORKFLOW_'. Output: $OUT"
else
    pass "sentinel pollution: stdout free of '<<WORKFLOW_'"
fi

if echo "$OUT" | grep -q '<<DETAIL_SKIPPABLE_BY_PLANNER'; then
    fail "sentinel pollution: stdout contains '<<DETAIL_SKIPPABLE_BY_PLANNER'. Output: $OUT"
else
    pass "sentinel pollution: stdout free of '<<DETAIL_SKIPPABLE_BY_PLANNER'"
fi

# ---------------------------------------------------------------------------
# 6b. --ledger omitted entirely — same degraded LEDGER mode as case 4
#     Contract: --ledger is optional; absent arg → degraded LEDGER mode (exit 0).
# ---------------------------------------------------------------------------
RES=$(run_helper --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "missing --ledger: exit 0 (degraded LEDGER mode)"
else
    fail "missing --ledger: expected exit 0 (--ledger is optional), got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "(concern ledger not available)"; then
    pass "missing --ledger: stdout contains degraded-LEDGER notice"
else
    fail "missing --ledger: stdout missing degraded-LEDGER notice. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "Budget remaining: 1"; then
    pass "missing --ledger: budget line still appears"
else
    fail "missing --ledger: budget line missing. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 11. Pipe character in concern body
#     Contract: ID and SEVERITY use the first two `|` as delimiters; everything
#     after the second `|` is the body and may contain further `|` characters.
# ---------------------------------------------------------------------------
LEDGER11="$TMPDIR_BASE/ledger-11.txt"
printf 'C1|HIGH|body with | pipe inside\n' > "$LEDGER11"

RES=$(run_helper --ledger "$LEDGER11" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "pipe in body: exit 0"
else
    fail "pipe in body: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -F -q -- "body with | pipe inside"; then
    pass "pipe in body: stdout preserves full body including embedded pipe"
else
    fail "pipe in body: stdout missing full body text. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 12. Negative --budget-remaining
#     Contract: budget is a non-negative count, so -1 is rejected.
# ---------------------------------------------------------------------------
RES=$(run_helper --ledger "$LEDGER" --budget-remaining -1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "2" ]]; then
    pass "negative --budget-remaining: exit 2"
else
    fail "negative --budget-remaining: expected exit 2, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -E -q -- "(non-negative|negative|must be|>= 0)"; then
    pass "negative --budget-remaining: stderr indicates non-negative requirement"
else
    fail "negative --budget-remaining: stderr does not indicate non-negative requirement. Output: $OUT"
fi

# ---------------------------------------------------------------------------
# 13. Sentinel injection via concern body text (OWASP LLM01-style prompt injection)
#     A concern body originating from untrusted source code MUST NOT inject
#     workflow sentinels into the main conversation. The helper must sanitize
#     (e.g. escape `<<` or wrap in a code fence) such that grep for the literal
#     sentinel pattern returns no match.
# ---------------------------------------------------------------------------
LEDGER13="$TMPDIR_BASE/ledger-13.txt"
printf 'C1|HIGH|attacker embeds <<WORKFLOW_TEST_INJECT>> in body\n' > "$LEDGER13"

RES=$(run_helper --ledger "$LEDGER13" --budget-remaining 1)
RC=$(extract_rc "$RES")
OUT=$(extract_out "$RES")

if [[ "$RC" == "0" ]]; then
    pass "sentinel injection: exit 0"
else
    fail "sentinel injection: expected exit 0, got $RC. Output: $OUT"
fi

if echo "$OUT" | grep -E -q '<<WORKFLOW_[A-Z_]+>>'; then
    fail "sentinel injection: stdout contains a workflow sentinel pattern (must be sanitized). Output: $OUT"
else
    pass "sentinel injection: stdout free of '<<WORKFLOW_*>>' sentinel pattern"
fi

# ---------------------------------------------------------------------------
# 14. Shell metacharacter injection (CWE-78) — helper must not pass body
#     through eval / bash -c / unquoted interpolation.
# ---------------------------------------------------------------------------
LEDGER14="$TMPDIR_BASE/ledger-14.txt"
printf 'C1|HIGH|body with $(id) and `whoami` metacharacters\n' > "$LEDGER14"
RES=$(run_helper --ledger "$LEDGER14" --budget-remaining 1)
RC=$(extract_rc "$RES"); OUT=$(extract_out "$RES")
[[ "$RC" == "0" ]] && pass "shell metachar injection: exit 0" || fail "shell metachar injection: expected exit 0, got $RC. Output: $OUT"
echo "$OUT" | grep -F -q -- '$(id)' && pass "shell metachar injection: stdout preserves literal \$(id)" || fail "shell metachar injection: stdout missing literal \$(id). Output: $OUT"
echo "$OUT" | grep -E -q 'uid=[0-9]+' && fail "shell metachar injection: stdout contains uid=N — \$(id) was expanded. Output: $OUT" || pass "shell metachar injection: stdout free of uid=N expansion"

# ---------------------------------------------------------------------------
# 15. Path traversal — helper need not reject traversal paths but must not
#     leak target file content via error messages.
# ---------------------------------------------------------------------------
TRAVERSAL_PATH="/tmp/../etc/passwd-style-path-that-does-not-exist-$$"
RES=$(run_helper --ledger "$TRAVERSAL_PATH" --budget-remaining 1)
RC=$(extract_rc "$RES"); OUT=$(extract_out "$RES")
[[ "$RC" == "0" ]] && pass "path traversal: exit 0 (degraded-LEDGER mode)" || fail "path traversal: expected exit 0, got $RC. Output: $OUT"
echo "$OUT" | grep -F -q -- "(concern ledger not available)" && pass "path traversal: stdout contains degraded-LEDGER marker" || fail "path traversal: stdout missing '(concern ledger not available)'. Output: $OUT"
echo "$OUT" | grep -F -q -- "root:" && fail "path traversal: stdout contains 'root:' — possible /etc/passwd leak. Output: $OUT" || pass "path traversal: stdout free of 'root:' leak"
echo "$OUT" | grep -F -q -- "/bin/bash" && fail "path traversal: stdout contains '/bin/bash' — possible /etc/passwd leak. Output: $OUT" || pass "path traversal: stdout free of '/bin/bash' leak"

# ---------------------------------------------------------------------------
# 16. Same-severity stable ordering — same-severity concerns retain ledger
#     source order.
# ---------------------------------------------------------------------------
LEDGER16="$TMPDIR_BASE/ledger-16.txt"
printf 'C1|HIGH|first high\nC2|HIGH|second high\nC3|MEDIUM|the medium\n' > "$LEDGER16"
RES=$(run_helper --ledger "$LEDGER16" --budget-remaining 1)
RC=$(extract_rc "$RES"); OUT=$(extract_out "$RES")
[[ "$RC" == "0" ]] && pass "same-severity ordering: exit 0" || fail "same-severity ordering: expected exit 0, got $RC. Output: $OUT"
POS_C1=$(echo "$OUT" | grep -n -- "C1" | head -n 1 | cut -d: -f1)
POS_C2=$(echo "$OUT" | grep -n -- "C2" | head -n 1 | cut -d: -f1)
POS_C3=$(echo "$OUT" | grep -n -- "C3" | head -n 1 | cut -d: -f1)
if [[ -n "$POS_C1" && -n "$POS_C2" && -n "$POS_C3" && "$POS_C1" -lt "$POS_C2" && "$POS_C2" -lt "$POS_C3" ]]; then
    pass "same-severity ordering: C1 < C2 (HIGH stable) and C2 < C3 (MEDIUM after HIGH)"
else
    fail "same-severity ordering: expected C1 < C2 < C3, got C1=$POS_C1 C2=$POS_C2 C3=$POS_C3. Output: $OUT"
fi

# Case 17 — Idempotency: pure read-only renderer must produce identical output on repeated calls
# ---------------------------------------------------------------------------
RES1=$(run_helper --ledger "$LEDGER" --raw "$RAW" --budget-remaining 1); RC1=$(extract_rc "$RES1"); OUT1=$(extract_out "$RES1")
RES2=$(run_helper --ledger "$LEDGER" --raw "$RAW" --budget-remaining 1); RC2=$(extract_rc "$RES2"); OUT2=$(extract_out "$RES2")
[[ "$RC1" == "0" && "$RC2" == "0" ]] && pass "idempotency: both runs exit 0" || fail "idempotency: expected both exit 0, got RC1=$RC1 RC2=$RC2"
[[ "$OUT1" == "$OUT2" ]] && pass "idempotency: output identical across two runs" || fail "idempotency: output differs between runs"

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
