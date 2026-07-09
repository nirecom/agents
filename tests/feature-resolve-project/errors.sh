#!/bin/bash
# tests/feature-resolve-project/errors.sh
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: workflow, github, issues, plans, bin
#
# Error/edge-case tests: mv failure (non-fatal cache write), cache dir
# auto-creation, gh not in PATH, graphql API failure.
#
# L3 gap: whether filesystem permission errors, real network failures, or
# missing gh CLI produce the expected warnings in a real environment.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Early-exit: if the helper is missing, report cleanly and exit.
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/resolve-project.sh not found (implementation missing)"
    echo ""
    echo "Results: 0 passed, 4 failed"
    exit 1
fi

# ===========================================================================
# T9: mv fails → warn on stderr, resolver still returns 0 (non-fatal)
# ===========================================================================
setup_mock
cat > "$TMP/mock-bin/mv" <<'MV_EOF'
#!/bin/bash
echo "mock mv: simulated failure" >&2
exit 1
MV_EOF
chmod +x "$TMP/mock-bin/mv"
STDERR_FILE="$TMP/t9-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_NUM=$(get_field "$OUT" RESOLVED_PROJECT_NUM)
if [ "$RC" = "0" ] \
   && [ "$R_NUM" = "1" ] \
   && grep -qi "cache write failed" "$STDERR_FILE" 2>/dev/null; then
    pass "T9: mv fails → warn 'cache write failed', resolver returns 0 (non-fatal)"
else
    fail "T9: rc=$RC num=$R_NUM stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T9b: cache directory does not exist → mkdir -p creates it, write succeeds
# ===========================================================================
setup_mock
CACHE_DIR="$WORKFLOW_PLANS_DIR/cache"
CACHE_FILE="$CACHE_DIR/project-resolve.tsv"
[ -d "$CACHE_DIR" ] && rm -rf "$CACHE_DIR"
STDERR_FILE="$TMP/t9b-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "0" ] && [ -d "$CACHE_DIR" ] && [ -f "$CACHE_FILE" ]; then
    pass "T9b: cache dir auto-created via mkdir -p, write succeeds"
else
    fail "T9b: rc=$RC dir_exists=$([ -d "$CACHE_DIR" ] && echo yes || echo no) file_exists=$([ -f "$CACHE_FILE" ] && echo yes || echo no) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T10: gh not in PATH → return 1, stderr contains warning
# ===========================================================================
setup_mock
SAVED_PATH="$PATH"
_T10_BASH_DIR="$(dirname "$(command -v bash 2>/dev/null || echo /bin/bash)")"
export PATH="$_T10_BASH_DIR:/nonexistent/path"
STDERR_FILE="$TMP/t10-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
export PATH="$SAVED_PATH"
if [ "$RC" = "1" ] && [ -s "$STDERR_FILE" ]; then
    pass "T10: gh not in PATH → return 1 + warn on stderr"
else
    fail "T10: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T11: gh api graphql fails → return 1, stderr contains warning
# ===========================================================================
setup_mock
export GH_MOCK_GRAPHQL_FAIL=1
STDERR_FILE="$TMP/t11-stderr.log"
OUT=$(run_with_timeout 30 bash -c "$(declare -f run_resolver get_field); run_resolver '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
if [ "$RC" = "1" ] && [ -s "$STDERR_FILE" ]; then
    pass "T11: gh api graphql fails → return 1 + warn"
else
    fail "T11: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

finish
