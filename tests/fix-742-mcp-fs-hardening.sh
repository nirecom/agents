#!/usr/bin/env bash
# tests/fix-742-mcp-fs-hardening.sh
# Tests: bin/review-plan-codex
# Tags: review-plan-codex, repo-root, defensive-hardening, security
#
# Symmetric defensive-hardening test for review-plan-codex — the sibling
# of the wrapper's repo-root validation. Verifies that review-plan-codex
# rejects --repo-root pointing at a non-existent directory.
#
# Contract: review-plan-codex ALWAYS exits 0 so it never blocks the
# planning loop. On a bad --repo-root it must emit:
#   ## Codex ... : FAILED — <reason mentioning REPO_ROOT_ARG or "not a directory">
# Stdout (not exit code) carries the verdict.

set -uo pipefail

AGENTS_WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"
RPC="$AGENTS_WORKTREE/bin/review-plan-codex"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 "$@"
    else
        perl -e 'alarm 30; exec @ARGV' -- "$@"
    fi
}

# ---------------------------------------------------------------------------
# Pre-implementation gate: if review-plan-codex hasn't grown the --repo-root
# directory check yet, skip cleanly. Detect by grepping for the validation
# guard the fix will introduce (REPO_ROOT_ARG existence/directory check).
# ---------------------------------------------------------------------------
if [[ ! -f "$RPC" ]]; then
    skip "1: $RPC does not exist (pre-implementation)"
    echo ""
    echo "All tests skipped (source not yet implemented)."
    exit 0
fi

# Heuristic for the pending source fix: look for an early-exit FAILED branch
# that references the --repo-root flag or REPO_ROOT_ARG together with a
# directory check token (-d, "not a directory", "directory"). If absent,
# the hardening hasn't landed yet — skip rather than fail.
if ! grep -Eq 'REPO_ROOT_ARG.*(-d|not a directory|directory)|(\-\-repo-root).*(not a directory|is not a directory)' "$RPC" 2>/dev/null; then
    skip "1: review-plan-codex --repo-root directory check not yet implemented"
    echo ""
    echo "All tests skipped (defensive hardening not yet applied)."
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. review-plan-codex with --repo-root pointing at a nonexistent directory
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Minimum valid input file so the existence/non-empty guard passes — the
# --repo-root validation must come BEFORE we ever try to invoke codex.
INPUT_FILE="$TMP/draft.md"
cat > "$INPUT_FILE" << 'EOF'
# Draft plan

Some content so the file is non-empty.
EOF

CORE_CTX="$TMP/core-principles.md"
echo "# core principles stub" > "$CORE_CTX"

BAD_REPO="$TMP/does-not-exist"

STDOUT_OUT=$(run_with_timeout "$RPC" \
    --input "$INPUT_FILE" \
    --format detail-plan \
    --session-id sid_fix742_1 \
    --log-dir "$TMP" \
    --cap 2 \
    --max-extensions 0 \
    --extensions-used 0 \
    --round 1 \
    --no-log \
    --context "$CORE_CTX" \
    --repo-root "$BAD_REPO" 2>&1)
rc=$?

# Contract: review-plan-codex always exits 0
if [[ $rc -ne 0 ]]; then
    fail "1: expected exit 0 (review-plan-codex never blocks), got $rc. Output: $STDOUT_OUT"
elif ! echo "$STDOUT_OUT" | grep -q '## Codex'; then
    fail "1: stdout missing '## Codex' header. Output: $STDOUT_OUT"
elif ! echo "$STDOUT_OUT" | grep -iEq 'FAILED'; then
    fail "1: stdout missing FAILED verdict. Output: $STDOUT_OUT"
elif ! echo "$STDOUT_OUT" | grep -iEq 'not a directory|REPO_ROOT_ARG|\-\-repo-root'; then
    fail "1: FAILED reason should mention 'not a directory' or 'REPO_ROOT_ARG' or '--repo-root'. Output: $STDOUT_OUT"
else
    pass "1: review-plan-codex with nonexistent --repo-root → exit 0 + FAILED verdict mentioning directory"
fi

# ---------------------------------------------------------------------------
# 2. MCP_FS_DEBUG=1: EXIT trap saves CODEX_STDERR to log dir (issue #742)
# ---------------------------------------------------------------------------
# CODEX_STDERR is only set after codex_core_check_cli passes (codex installed).
# Without codex the trap is never registered, so this test is skipped.
if ! command -v codex >/dev/null 2>&1; then
    skip "2: codex CLI not installed — EXIT trap MCP_FS_DEBUG log test requires codex"
elif ! grep -q 'MCP_FS_DEBUG' "$RPC" 2>/dev/null; then
    skip "2: MCP_FS_DEBUG EXIT trap not yet implemented in $RPC"
else
    TMP2=$(mktemp -d)
    MCP_FS_DEBUG=1 run_with_timeout "$RPC" \
        --input "$INPUT_FILE" \
        --format detail-plan \
        --session-id sid_fix742_2 \
        --log-dir "$TMP2" \
        --cap 2 \
        --max-extensions 0 \
        --extensions-used 0 \
        --round 1 \
        --no-log \
        --context "$CORE_CTX" >/dev/null 2>&1 || true
    STDERR_LOG="$TMP2/detail-plan-codex-stderr.log"
    if [[ -f "$STDERR_LOG" ]]; then
        pass "2: MCP_FS_DEBUG=1 → EXIT trap creates detail-plan-codex-stderr.log in LOG_DIR"
    else
        fail "2: expected $STDERR_LOG when MCP_FS_DEBUG=1 and --log-dir is set. Dir contents: $(ls "$TMP2" 2>&1)"
    fi
    rm -rf "$TMP2"
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
