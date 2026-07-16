#!/bin/bash
# tests/feature-1466-detect-non-github.sh
# Tests: bin/detect-non-github.sh
# Tags: non-github, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - actual git remote URL inspection in a real repository
# - integration with the real SKILL.md invocation patterns
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
set -u

AGENTS_CONFIG_DIR="${AGENTS_CONFIG_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DETECT_SCRIPT="$AGENTS_CONFIG_DIR/bin/detect-non-github.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# Skip if the script doesn't exist yet (write-code pending)
if [ ! -f "$DETECT_SCRIPT" ]; then
    echo "SKIP: bin/detect-non-github.sh not yet created (write-code pending)"
    exit 0
fi

# Windows-compatible tmpdir
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# run_with_mock <mock_rc> [label_arg]
# Runs detect-non-github.sh with a mock is-github-dotcom-remote that exits <mock_rc>.
# Captures stdout, stderr, and exit code.
# Sets: MOCK_STDOUT, MOCK_STDERR, MOCK_RC
run_with_mock() {
    local mock_rc="$1"
    shift
    local tmpdir
    tmpdir="$(mktemp -d "$TMPDIR_BASE/mock.XXXXXX")"
    mkdir -p "$tmpdir/bin"

    # Create mock is-github-dotcom-remote
    printf '#!/bin/bash\nexit %s\n' "$mock_rc" > "$tmpdir/bin/is-github-dotcom-remote"
    chmod +x "$tmpdir/bin/is-github-dotcom-remote"

    # Copy the real detect-non-github.sh into temp dir
    cp "$DETECT_SCRIPT" "$tmpdir/bin/detect-non-github.sh"
    chmod +x "$tmpdir/bin/detect-non-github.sh"

    # Run with patched AGENTS_CONFIG_DIR
    MOCK_STDOUT=$(AGENTS_CONFIG_DIR="$tmpdir" bash "$tmpdir/bin/detect-non-github.sh" "$@" 2>/dev/null)
    MOCK_RC=$?
    MOCK_STDERR=$(AGENTS_CONFIG_DIR="$tmpdir" bash "$tmpdir/bin/detect-non-github.sh" "$@" 2>&1 1>/dev/null)
}

# ---------------------------------------------------------------------------
# Test 1: GitHub (rc=0) → exits 0, no stdout
# ---------------------------------------------------------------------------
echo "=== Test 1: GitHub remote (rc=0) ==="
run_with_mock 0 "issue-close-stage"
if [ "$MOCK_RC" -eq 0 ]; then
    pass "exits 0 for GitHub remote"
else
    fail "expected exit 0 for GitHub remote, got $MOCK_RC"
fi
if [ -z "$MOCK_STDOUT" ]; then
    pass "no stdout output for GitHub remote"
else
    fail "unexpected stdout for GitHub remote: $MOCK_STDOUT"
fi

# ---------------------------------------------------------------------------
# Test 2: non-GitHub (rc=1) → exits 1, stdout contains skip message with label
# ---------------------------------------------------------------------------
echo "=== Test 2: non-GitHub remote (rc=1) ==="
run_with_mock 1 "issue-close-stage"
if [ "$MOCK_RC" -eq 1 ]; then
    pass "exits 1 for non-GitHub remote"
else
    fail "expected exit 1 for non-GitHub remote, got $MOCK_RC"
fi
if echo "$MOCK_STDOUT" | grep -qF "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping issue-close-stage]"; then
    pass "stdout contains expected skip message"
else
    fail "stdout missing expected skip message, got: $MOCK_STDOUT"
fi

# ---------------------------------------------------------------------------
# Test 3: fail-open (rc=2) → exits 0, no output
# ---------------------------------------------------------------------------
echo "=== Test 3: fail-open (rc=2) ==="
run_with_mock 2 "issue-close-stage"
if [ "$MOCK_RC" -eq 0 ]; then
    pass "exits 0 for fail-open (rc=2)"
else
    fail "expected exit 0 for fail-open, got $MOCK_RC"
fi
if [ -z "$MOCK_STDOUT" ]; then
    pass "no stdout for fail-open"
else
    fail "unexpected stdout for fail-open: $MOCK_STDOUT"
fi

# ---------------------------------------------------------------------------
# Test 4: custom label — skip message contains the label
# ---------------------------------------------------------------------------
echo "=== Test 4: custom label 'Phase 1 pre-flight' ==="
run_with_mock 1 "Phase 1 pre-flight"
if echo "$MOCK_STDOUT" | grep -qF "skipping Phase 1 pre-flight"; then
    pass "skip message contains custom label 'Phase 1 pre-flight'"
else
    fail "skip message missing custom label, got: $MOCK_STDOUT"
fi

# ---------------------------------------------------------------------------
# Test 5: default label when $1 omitted → "issue routing"
# ---------------------------------------------------------------------------
echo "=== Test 5: default label when \$1 omitted ==="
run_with_mock 1
if echo "$MOCK_STDOUT" | grep -qF "skipping issue routing"; then
    pass "default label 'issue routing' present in skip message"
else
    fail "default label 'issue routing' missing from skip message, got: $MOCK_STDOUT"
fi

# ---------------------------------------------------------------------------
# Test 6: AGENTS_CONFIG_DIR unset → exits non-zero with error
# ---------------------------------------------------------------------------
echo "=== Test 6: AGENTS_CONFIG_DIR unset ==="
unset_rc=0
unset_out=$(unset AGENTS_CONFIG_DIR; bash "$DETECT_SCRIPT" "label" 2>&1) || unset_rc=$?
if [ "$unset_rc" -ne 0 ]; then
    pass "exits non-zero when AGENTS_CONFIG_DIR is unset"
else
    fail "expected non-zero exit when AGENTS_CONFIG_DIR unset, got 0"
fi

# ---------------------------------------------------------------------------
# Test 7: stdout not stderr — rc=1 output goes to stdout only
# ---------------------------------------------------------------------------
echo "=== Test 7: output goes to stdout, not stderr ==="
run_with_mock 1 "issue-close-stage"
if [ -n "$MOCK_STDOUT" ]; then
    pass "skip message present on stdout"
else
    fail "skip message missing from stdout"
fi
if [ -z "$MOCK_STDERR" ]; then
    pass "no output on stderr (rc=1 output is stdout-only)"
else
    fail "unexpected output on stderr: $MOCK_STDERR"
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
