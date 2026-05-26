#!/usr/bin/env bash
# Integration tests for review-plan-codex --print-prompt-only (issue #558).
# Tests that the assembled codex prompt includes triage sections.
# Will FAIL until review-plan-codex is updated and triage-split.sh exists (test-first).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
CODEX_BIN="$AGENTS_ROOT/bin/review-plan-codex"
TRIAGE_SPLIT="$AGENTS_ROOT/skills/_shared/triage-split.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Shared fixture: full document with MUST/OPTIONAL/NA members.
FIXTURE_MAIN="$TMPDIR_BASE/fixture-main.md"
cat > "$FIXTURE_MAIN" << 'FIXTURE_EOF'
# Intent

## Issue

Issue body for codex block tests.

## Class members

- alpha: a must-fix item — disposition: MUST
- beta: an optional improvement — disposition: OPTIONAL
- gamma: explicitly out of scope — disposition: NA

## Accepted Tradeoffs

- none relevant
FIXTURE_EOF

# Fixture with unknown disposition (for C7).
FIXTURE_BOGUS="$TMPDIR_BASE/fixture-bogus.md"
cat > "$FIXTURE_BOGUS" << 'BOGUS_EOF'
# Intent

## Issue

Issue body.

## Class members

- alpha: a broken item — disposition: BOGUS

## Accepted Tradeoffs

- none
BOGUS_EOF

echo "=== feature-558 codex block tests ==="
echo ""

# ---------------------------------------------------------------------------
# C1: review-plan-codex is executable
# ---------------------------------------------------------------------------
if [[ -x "$CODEX_BIN" ]]; then
    pass "C1: bin/review-plan-codex is executable"
else
    fail "C1: bin/review-plan-codex is not executable or missing: $CODEX_BIN"
fi

# ---------------------------------------------------------------------------
# C2: --print-prompt-only exits 0 (requires triage-split.sh to exist)
# ---------------------------------------------------------------------------
EC=0
PROMPT_OUT="$TMPDIR_BASE/prompt-out.txt"
run_with_timeout bash "$CODEX_BIN" --print-prompt-only "$FIXTURE_MAIN" >"$PROMPT_OUT" 2>&1 || EC=$?
if [[ "$EC" == "0" ]]; then
    pass "C2: review-plan-codex --print-prompt-only exits 0"
else
    fail "C2: review-plan-codex --print-prompt-only exited $EC. Output: $(cat "$PROMPT_OUT")"
fi

# ---------------------------------------------------------------------------
# C3: Output contains ### MUST
# ---------------------------------------------------------------------------
if grep -q '^### MUST' "$PROMPT_OUT" 2>/dev/null; then
    pass "C3: --print-prompt-only output contains '### MUST'"
else
    fail "C3: --print-prompt-only output missing '### MUST'. Output: $(cat "$PROMPT_OUT" 2>/dev/null | head -20)"
fi

# ---------------------------------------------------------------------------
# C4: Output contains ### OPTIONAL
# ---------------------------------------------------------------------------
if grep -q '^### OPTIONAL' "$PROMPT_OUT" 2>/dev/null; then
    pass "C4: --print-prompt-only output contains '### OPTIONAL'"
else
    fail "C4: --print-prompt-only output missing '### OPTIONAL'"
fi

# ---------------------------------------------------------------------------
# C5: Output contains ### NA
# ---------------------------------------------------------------------------
if grep -q '^### NA' "$PROMPT_OUT" 2>/dev/null; then
    pass "C5: --print-prompt-only output contains '### NA'"
else
    fail "C5: --print-prompt-only output missing '### NA'"
fi

# ---------------------------------------------------------------------------
# C6: Output contains legacy mapping note (fix in scope / track separately / legacy mapping)
# ---------------------------------------------------------------------------
if grep -qE 'fix in scope|track separately|legacy mapping' "$PROMPT_OUT" 2>/dev/null; then
    pass "C6: --print-prompt-only output contains legacy mapping note"
else
    fail "C6: --print-prompt-only output missing legacy mapping note (fix in scope / track separately / legacy mapping)"
fi

# ---------------------------------------------------------------------------
# C7: Unknown disposition in fixture → review-plan-codex exits non-zero
# ---------------------------------------------------------------------------
EC=0
BOGUS_OUT="$TMPDIR_BASE/bogus-out.txt"
run_with_timeout bash "$CODEX_BIN" --print-prompt-only "$FIXTURE_BOGUS" >"$BOGUS_OUT" 2>&1 || EC=$?
if [[ "$EC" != "0" ]]; then
    pass "C7: review-plan-codex exits non-zero when triage-split fails (unknown disposition)"
else
    fail "C7: review-plan-codex should exit non-zero for unknown disposition, but exited 0. Output: $(cat "$BOGUS_OUT")"
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
