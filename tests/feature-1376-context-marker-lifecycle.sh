#!/bin/bash
# tests/feature-1376-context-marker-lifecycle.sh
# Tests: bin/run-codex-review-loop
# Tags: review-tests, codex-context, marker-lifecycle, built-marker, scope:issue-specific
#
# Issue #1376: FORMAT=test-review must force-clear the built marker before checking,
# so every /review-tests invocation rebuilds codex context fresh. Other formats
# (detail-plan, outline-plan) preserve the marker (idempotent expensive context build).
#
# L3 gap: whether rebuilt context includes new test files or parallel FORMAT=test-review
# runs cause a race — L2 cannot simulate true parallel execution of the hook.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP_BIN="$AGENTS_DIR/bin/run-codex-review-loop"
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

# ---------------------------------------------------------------------------
# Precondition gate
# ---------------------------------------------------------------------------
if [[ ! -f "$LOOP_BIN" ]]; then
    echo "FAIL: precondition missing — bin/run-codex-review-loop"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/mk1376.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Helper: run the loop binary with minimal required args.
# Captures whether build-codex-context was invoked by watching the marker file.
# The loop will fail (exit 4 or 3) because codex is unavailable; that is fine —
# we only care about the marker lifecycle BEFORE the codex invocation.
#
# Strategy: replace build-codex-context with a stub that creates a sentinel file
# so we can detect whether it was called.
# ---------------------------------------------------------------------------

SID="test-sid-1376"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_DIR"

# Minimal required files for the loop binary.
: > "$PLANS_DIR/$SID-test-review.md"
: > "$PLANS_DIR/$SID-outline.md"
: > "$PLANS_DIR/$SID-detail-plan.md"

MARKER_TR="$PLANS_DIR/$SID-codex-context.test-review.built"
MARKER_DP="$PLANS_DIR/$SID-codex-context.detail-plan.built"
CONTEXT_OUT="$PLANS_DIR/$SID-codex-context.md"

# Stub out build-codex-context: create a temporary bin/ that intercepts the call.
STUB_BIN="$TMPDIR_BASE/stubbin"
mkdir -p "$STUB_BIN"
STUB_CALLED_FILE="$TMPDIR_BASE/stub-called"

cat > "$STUB_BIN/build-codex-context" <<'STUBEOF'
#!/bin/bash
# Stub for build-codex-context: record invocation, write placeholder context.
touch "$STUB_CALLED_FILE_PATH"
# Parse --output flag to write placeholder content.
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" && -n "${2:-}" ]]; then
        echo "stub-context" > "$2"
        break
    fi
    shift
done
exit 0
STUBEOF
chmod +x "$STUB_BIN/build-codex-context"

# Stub out review-plan-codex too so the loop reaches the reviewer then exits 3.
cat > "$STUB_BIN/review-plan-codex" <<'RPCEOF'
#!/bin/bash
echo "## Codex Review: SKIPPED — codex unavailable (stub)"
exit 0
RPCEOF
chmod +x "$STUB_BIN/review-plan-codex"

# Override AGENTS_CONFIG_DIR to point at a local dir that has the stub bin/ but
# falls back to real rules/ from the real AGENTS_DIR.
FAKE_AGENTS="$TMPDIR_BASE/fake-agents"
mkdir -p "$FAKE_AGENTS/bin" "$FAKE_AGENTS/rules"
cp "$STUB_BIN/build-codex-context" "$FAKE_AGENTS/bin/"
cp "$STUB_BIN/review-plan-codex" "$FAKE_AGENTS/bin/"
# Symlink rules so core-principles.md is reachable.
if [[ -d "$AGENTS_DIR/rules" ]]; then
    cp -r "$AGENTS_DIR/rules" "$FAKE_AGENTS/" 2>/dev/null || true
fi
# Also copy bin/run-with-timeout.sh and review-loop-verdict if present.
for f in run-with-timeout.sh review-loop-verdict; do
    [[ -f "$AGENTS_DIR/bin/$f" ]] && cp "$AGENTS_DIR/bin/$f" "$FAKE_AGENTS/bin/" 2>/dev/null || true
done
mkdir -p "$FAKE_AGENTS/bin/lib/codex-review-loop"
cp "$AGENTS_DIR/bin/lib/codex-review-loop/"*.sh "$FAKE_AGENTS/bin/lib/codex-review-loop/" 2>/dev/null || true
cp "$AGENTS_DIR/bin/lib/safe-plans-path.sh" "$FAKE_AGENTS/bin/lib/safe-plans-path.sh" 2>/dev/null || true
cp "$AGENTS_DIR/bin/concern-ledger" "$FAKE_AGENTS/bin/concern-ledger" 2>/dev/null || true
chmod +x "$FAKE_AGENTS/bin/concern-ledger" 2>/dev/null || true
cp "$AGENTS_DIR/bin/lib/concern-ledger.sh" "$FAKE_AGENTS/bin/lib/concern-ledger.sh" 2>/dev/null || true
mkdir -p "$FAKE_AGENTS/bin/lib/concern-ledger"
cp "$AGENTS_DIR"/bin/lib/concern-ledger/*.sh "$FAKE_AGENTS/bin/lib/concern-ledger/" 2>/dev/null || true

run_loop() {
    local format="$1" round="${2:-1}"
    STUB_CALLED_FILE_PATH="$STUB_CALLED_FILE" \
    export STUB_CALLED_FILE_PATH
    AGENTS_CONFIG_DIR="$FAKE_AGENTS" \
    "$RWT" 120 bash "$LOOP_BIN" \
        --format "$format" \
        --session-id "$SID" \
        --plans-dir "$PLANS_DIR" \
        --draft-file "$PLANS_DIR/$SID-${format}.md" \
        --cap 1 \
        --max-extensions 0 \
        --extensions-used 0 \
        --accepted-tradeoffs "$PLANS_DIR/$SID-outline.md" \
        --round "$round" \
        2>/dev/null || true
}

# ===========================================================================
# Case 9 — FORMAT=test-review + stale marker exists → marker cleared, context
#           rebuilt (stub invoked) even though marker was present at entry.
# EXPECTED: FAIL before fix (loop skips build when marker exists).
# ===========================================================================
rm -f "$STUB_CALLED_FILE" "$MARKER_TR"
# Pre-plant a stale marker (simulates previous /review-tests run).
: > "$MARKER_TR"
marker_mtime_before=$(stat -c %Y "$MARKER_TR" 2>/dev/null || stat -f %m "$MARKER_TR" 2>/dev/null || echo "0")

run_loop "test-review"

if [[ -f "$STUB_CALLED_FILE" ]]; then
    pass "9: FORMAT=test-review + stale marker → build-codex-context invoked (marker cleared)"
else
    fail "9: FORMAT=test-review + stale marker → build-codex-context NOT invoked (stale context reused)"
fi
rm -f "$STUB_CALLED_FILE" "$MARKER_TR" "$CONTEXT_OUT"

# ===========================================================================
# Case 10 — FORMAT=test-review + no marker → fresh context built.
#            (This should pass both before and after; it's a base-case sanity.)
# ===========================================================================
rm -f "$STUB_CALLED_FILE" "$MARKER_TR"
run_loop "test-review"

if [[ -f "$STUB_CALLED_FILE" ]]; then
    pass "10: FORMAT=test-review + no marker → build-codex-context invoked (fresh context built)"
else
    fail "10: FORMAT=test-review + no marker → build-codex-context NOT invoked (context not built)"
fi
rm -f "$STUB_CALLED_FILE" "$MARKER_TR" "$CONTEXT_OUT"

# ===========================================================================
# Case 11 (regression guard) — FORMAT=detail-plan + stale marker → marker
#           PRESERVED; build NOT invoked (expensive context reused as intended).
# EXPECTED: PASS both before and after fix (only test-review gets forced rebuild).
# ===========================================================================
rm -f "$STUB_CALLED_FILE" "$MARKER_DP"
: > "$MARKER_DP"   # pre-plant stale marker

run_loop "detail-plan"

if [[ ! -f "$STUB_CALLED_FILE" ]]; then
    pass "11: FORMAT=detail-plan + stale marker → build NOT invoked (marker preserved)"
else
    fail "11: REGRESSION — FORMAT=detail-plan forced a rebuild when marker was present"
fi
rm -f "$STUB_CALLED_FILE" "$MARKER_DP" "$CONTEXT_OUT"

# ===========================================================================
# Case 12 (C5) — Stale context file → stderr warning.
# When FORMAT=test-review and stale context (codex-context.md) exists, the script
# must emit a warning containing "stale" or "rebuilding" to stderr.
# Source NOT yet implemented → FAILS (fail-before-fix). After fix: detect stale
# context, print warning, proceed to rebuild.
# EXPECTED: FAIL before fix (no stale warning is emitted by current code).
# ===========================================================================
rm -f "$STUB_CALLED_FILE" "$MARKER_TR" "$CONTEXT_OUT"

# Pre-plant BOTH a stale marker AND a stale context file.
: > "$MARKER_TR"
echo "stale-context-content" > "$CONTEXT_OUT"

# Capture stderr separately for this run.
STDERR_FILE_12="$TMPDIR_BASE/stderr-case12.txt"

STUB_CALLED_FILE_PATH="$STUB_CALLED_FILE" \
export STUB_CALLED_FILE_PATH
AGENTS_CONFIG_DIR="$FAKE_AGENTS" \
"$RWT" 120 bash "$LOOP_BIN" \
    --format "test-review" \
    --session-id "$SID" \
    --plans-dir "$PLANS_DIR" \
    --draft-file "$PLANS_DIR/$SID-test-review.md" \
    --cap 1 \
    --max-extensions 0 \
    --extensions-used 0 \
    --accepted-tradeoffs "$PLANS_DIR/$SID-outline.md" \
    --round 1 \
    2>"$STDERR_FILE_12" >/dev/null || true

STDERR_CONTENT_12="$(cat "$STDERR_FILE_12" 2>/dev/null || echo "")"
if echo "$STDERR_CONTENT_12" | grep -qi "stale\|rebuilding"; then
    pass "12: FORMAT=test-review + stale context file → stderr warning contains 'stale' or 'rebuilding'"
else
    fail "12: FORMAT=test-review + stale context file → no stale/rebuilding warning in stderr (got: $(echo "$STDERR_CONTENT_12" | head -3 | tr '\n' '|'))"
fi
rm -f "$STUB_CALLED_FILE" "$MARKER_TR" "$CONTEXT_OUT" "$STDERR_FILE_12"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
