#!/bin/bash
# Tests: bin/github-issues/check-closes-issues-nonempty.sh, bin/github-issues/wip-set-single.sh, bin/github-issues/issue-state-check.sh
# Tags: cross-repo, wire-format, closes-issues, wip, issue-state, tests
# Tests for issues #1100/#1101 — cross-repo wire format support.
#
# All C-series tests are RED until source files are updated to handle
# cross-repo {repo, number} objects from parse-closes-issues.js.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="$AGENTS_DIR/tests/fixtures/gh-mock"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

for f in gh doc-append git; do
    if [ -f "$MOCK_DIR/$f" ] && [ ! -x "$MOCK_DIR/$f" ]; then
        chmod +x "$MOCK_DIR/$f" 2>/dev/null || true
    fi
done

setup_tmp() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PATH="$MOCK_DIR:$PATH"
    export GH_MOCK_COMMENT_LOG="$TMP/comments.log"
    : > "$GH_MOCK_COMMENT_LOG"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    unset AGENTS_CONFIG_DIR GH_MOCK_COMMENT_LOG
}

# ============================================================================
# C1: check-closes-issues-nonempty.sh with cross-repo intent.md → exit 0
#
# When intent.md contains `- owner/repo#42` (cross-repo entry), the script
# must parse it, resolve it as "open", and exit 0.
#
# RED: current parse-closes-issues.js does not parse cross-repo entries.
# ============================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- nirecom/dotfiles-private#42
EOF
GH_MOCK_SCENARIO=issue_task \
    run_with_timeout 30 bash "$AGENTS_DIR/bin/github-issues/check-closes-issues-nonempty.sh" "$TMP/intent.md"
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "C1: check-closes-issues-nonempty.sh with cross-repo entry → exit 0"
else
    fail "C1: rc=$RC expected exit 0 for cross-repo entry nirecom/dotfiles-private#42"
fi
teardown_tmp

# ============================================================================
# C2: parse-closes-issues CLI with mixed formats returns 2 entries
#
# When intent.md mixes `- #1` (local) and `- owner/repo#2` (cross-repo),
# the parser must return a 2-element array. Current source only parses `- #N`
# forms, so the cross-repo entry is ignored → returns 1 element.
#
# RED: current source returns [1] (length 1), not 2-element array.
# ============================================================================
setup_tmp
cat > "$TMP/intent.md" <<'EOF'
# Intent

## Issues
- #1
- nirecom/dotfiles-private#2
EOF
OUT=$(run_with_timeout 30 node "$AGENTS_DIR/bin/parse-closes-issues" "$TMP/intent.md" 2>/dev/null)
RC=$?
LEN=$(node -e "try{const a=JSON.parse(process.argv[1]);process.stdout.write(String(a.length));}catch(e){process.stdout.write('0');}" "$OUT" 2>/dev/null)
if [ "$RC" -eq 0 ] && [ "$LEN" = "2" ] && ! printf '%s' "$OUT" | grep -q '\[object Object\]'; then
    pass "C2: mixed formats → 2-element array, no '[object Object]'"
else
    fail "C2: rc=$RC out='$OUT' len=$LEN (expected 2-element array without [object Object])"
fi
teardown_tmp

# ============================================================================
# C3: wip-set-single.sh --repo nirecom/dotfiles-private 42 → gh called correctly
#
# When invoked with a --repo flag, wip-set-single.sh must pass --repo to the
# underlying gh call so the label probe targets the correct repository.
#
# RED: current wip-set-single.sh does not accept --repo; exits with usage error.
# ============================================================================
setup_tmp
WIP_SCRIPT="$AGENTS_DIR/bin/github-issues/wip-set-single.sh"
if [ ! -f "$WIP_SCRIPT" ]; then
    fail "C3: precondition missing — bin/github-issues/wip-set-single.sh"
else
    # wip-state.sh is called internally; provide a stub so the test focuses on --repo routing.
    mkdir -p "$TMP/bin/github-issues"
    cat > "$TMP/bin/github-issues/wip-state.sh" <<'STUB'
#!/bin/bash
# Stub: record args and exit 0
echo "WIP_STATE_CALLED: $*" >> "${GH_MOCK_COMMENT_LOG:-/dev/null}"
exit 0
STUB
    chmod +x "$TMP/bin/github-issues/wip-state.sh"

    # Patch: override AGENTS_CONFIG_DIR to the tmp dir so wip-set-single finds our stub wip-state.sh
    GH_MOCK_SCENARIO=issue_task AGENTS_CONFIG_DIR="$TMP" \
        run_with_timeout 30 bash "$WIP_SCRIPT" --repo nirecom/dotfiles-private 42
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "C3: wip-set-single.sh --repo nirecom/dotfiles-private 42 → exit 0"
    else
        fail "C3: rc=$RC expected exit 0 for --repo flag support"
    fi
fi
teardown_tmp

# ============================================================================
# C4: issue-state-check.sh --repo nirecom/dotfiles-private 42 → exit 0 + 'open'
#
# When invoked with --repo, issue-state-check.sh must pass --repo to gh so the
# state lookup targets the correct repository.
#
# RED: current issue-state-check.sh does not accept --repo; exits with usage error.
# ============================================================================
setup_tmp
STATE_SCRIPT="$AGENTS_DIR/bin/github-issues/issue-state-check.sh"
if [ ! -f "$STATE_SCRIPT" ]; then
    fail "C4: precondition missing — bin/github-issues/issue-state-check.sh"
else
    GH_MOCK_SCENARIO=issue_task \
        OUT=$(run_with_timeout 30 bash "$STATE_SCRIPT" --repo nirecom/dotfiles-private 42 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "open" ]; then
        pass "C4: issue-state-check.sh --repo nirecom/dotfiles-private 42 → exit 0 + 'open'"
    else
        fail "C4: rc=$RC out='$OUT' expected exit 0 + 'open' for --repo flag support"
    fi
fi
teardown_tmp

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
