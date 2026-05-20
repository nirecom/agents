#!/bin/bash
# Tests for bin/github-issues/parent-all-closed-check.sh
#
# I/F: parent-all-closed-check.sh <owner/repo> <N>
#   exit 0: all sub-issues closed
#   exit 1: at least one sub-issue open
#   exit 2: zero sub-issues
#   exit 3: validation error / API failure
#
# RED: this suite fails clean while parent-all-closed-check.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/bin/github-issues/parent-all-closed-check.sh"
SKILL_CLOSE_FINALIZE="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"

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

# Doc-tests still run even when implementation is missing — but the script tests
# must report FAIL cleanly. Implementation-absent: emit FAIL for all script cases.
IMPL_PRESENT=1
if [ ! -f "$TARGET" ]; then
    IMPL_PRESENT=0
    echo "FAIL: bin/github-issues/parent-all-closed-check.sh not found (implementation missing)"
fi

# ---------------------------------------------------------------------------
# Inline gh mock factory
# ---------------------------------------------------------------------------

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  api\ repos/*/issues/*/sub_issues*)
    if [ "${GH_MOCK_SUBISSUE_LIST_FAIL:-0}" = "1" ]; then
        echo "error: API failed" >&2
        exit 1
    fi
    # Emit one or two pre-jq'd JSON lines simulating --jq + --paginate output.
    echo "${GH_MOCK_SUBISSUE_PAGE1_JSON:-{\"open\":0,\"total\":0}}"
    if [ -n "${GH_MOCK_SUBISSUE_PAGE2_JSON:-}" ]; then
        echo "${GH_MOCK_SUBISSUE_PAGE2_JSON}"
    fi
    exit 0 ;;
  repo\ view\ *nameWithOwner*)
    echo "nirecom/agents"
    exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_SUBISSUE_LIST_FAIL \
          GH_MOCK_SUBISSUE_PAGE1_JSON GH_MOCK_SUBISSUE_PAGE2_JSON 2>/dev/null || true
}

# Helper that emits FAIL for a case when implementation is missing.
skip_no_impl() {
    fail "$1 — RED until implementation"
}

# ---------------------------------------------------------------------------
# AC1: all sub-issues closed (single page) → exit 0
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC1"
else
    setup_mock
    export GH_MOCK_SUBISSUE_PAGE1_JSON='{"open":0,"total":3}'
    run_with_timeout 30 bash "$TARGET" nirecom/agents 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "AC1: all sub-issues closed → exit 0"
    else
        fail "AC1: expected exit 0, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC2: some sub-issues open (single page) → exit 1
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC2"
else
    setup_mock
    export GH_MOCK_SUBISSUE_PAGE1_JSON='{"open":1,"total":3}'
    run_with_timeout 30 bash "$TARGET" nirecom/agents 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 1 ]; then
        pass "AC2: some sub-issues open → exit 1"
    else
        fail "AC2: expected exit 1, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC3: zero sub-issues → exit 2
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC3"
else
    setup_mock
    export GH_MOCK_SUBISSUE_PAGE1_JSON='{"open":0,"total":0}'
    run_with_timeout 30 bash "$TARGET" nirecom/agents 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 2 ]; then
        pass "AC3: zero sub-issues → exit 2"
    else
        fail "AC3: expected exit 2, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC4: paginated, all closed across pages → exit 0
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC4"
else
    setup_mock
    export GH_MOCK_SUBISSUE_PAGE1_JSON='{"open":0,"total":30}'
    export GH_MOCK_SUBISSUE_PAGE2_JSON='{"open":0,"total":30}'
    run_with_timeout 30 bash "$TARGET" nirecom/agents 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "AC4: paginated, all closed → exit 0"
    else
        fail "AC4: expected exit 0, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC5: paginated, page2 has open → exit 1
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC5"
else
    setup_mock
    export GH_MOCK_SUBISSUE_PAGE1_JSON='{"open":0,"total":30}'
    export GH_MOCK_SUBISSUE_PAGE2_JSON='{"open":1,"total":30}'
    run_with_timeout 30 bash "$TARGET" nirecom/agents 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 1 ]; then
        pass "AC5: paginated, page2 has open → exit 1"
    else
        fail "AC5: expected exit 1, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC6: API call fails → exit 3
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC6"
else
    setup_mock
    export GH_MOCK_SUBISSUE_LIST_FAIL=1
    run_with_timeout 30 bash "$TARGET" nirecom/agents 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 3 ]; then
        pass "AC6: API failure → exit 3"
    else
        fail "AC6: expected exit 3, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC7a: non-numeric <N> → exit 3
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC7a"
else
    setup_mock
    run_with_timeout 30 bash "$TARGET" nirecom/agents abc >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 3 ]; then
        pass "AC7a: non-numeric <N> → exit 3"
    else
        fail "AC7a: expected exit 3, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# AC7b: invalid <owner/repo> → exit 3
# ---------------------------------------------------------------------------
if [ "$IMPL_PRESENT" -eq 0 ]; then
    skip_no_impl "AC7b"
else
    setup_mock
    run_with_timeout 30 bash "$TARGET" "bad@repo" 42 >/dev/null 2>&1
    RC=$?
    if [ "$RC" -eq 3 ]; then
        pass "AC7b: invalid <owner/repo> → exit 3"
    else
        fail "AC7b: expected exit 3, got rc=$RC"
    fi
    teardown_mock
fi

# ---------------------------------------------------------------------------
# SK1-SK3: SKILL.md doc-tests
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_CLOSE_FINALIZE" ]; then
    fail "SK1: skills/issue-close-finalize/SKILL.md not found"
    fail "SK2: skills/issue-close-finalize/SKILL.md not found"
    fail "SK3: skills/issue-close-finalize/SKILL.md not found"
else
    if grep -q "parent-close-proposal-prepare.sh" "$SKILL_CLOSE_FINALIZE"; then
        pass "SK1: issue-close-finalize SKILL.md references parent-close-proposal-prepare.sh"
    else
        fail "SK1: SKILL.md does not reference parent-close-proposal-prepare.sh — RED until implementation"
    fi
    if grep -q "parent-close-proposal-execute.sh" "$SKILL_CLOSE_FINALIZE"; then
        pass "SK2: issue-close-finalize SKILL.md references parent-close-proposal-execute.sh"
    else
        fail "SK2: SKILL.md does not reference parent-close-proposal-execute.sh — RED until implementation"
    fi
    if grep -q "G\.5" "$SKILL_CLOSE_FINALIZE"; then
        pass "SK3: issue-close-finalize SKILL.md references G.5"
    else
        fail "SK3: SKILL.md does not reference G.5 — RED until implementation"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
