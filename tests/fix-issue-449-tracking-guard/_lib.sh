#!/bin/bash
# tests/fix-issue-449-tracking-guard/_lib.sh
# Shared helpers for the fix-issue-449-tracking-guard split test suite.
#
# Sourced by each split file (d-series.sh / ggl-series.sh) so they can also
# run standalone. Provides path constants, PASS/FAIL counters, pass/fail/skip
# helpers, run_with_timeout, the gh state-check mock, and tmp-dir helpers.
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_TRACKING_GUARD_LIB_SOURCED:-}" ]; then
    return 0
fi
_TRACKING_GUARD_LIB_SOURCED=1

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$AGENTS_DIR/bin/github-issues/check-closes-issues-nonempty.sh"
STATE_CHECK="$AGENTS_DIR/bin/github-issues/issue-state-check.sh"
GUARD_LOOP="$AGENTS_DIR/bin/github-issues/clarify-guard-loop.sh"
CLARIFY_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"

# So `node -e "require('hooks/lib/parse-closes-issues.js')"` resolves
# correctly from the guard script (which uses AGENTS_CONFIG_DIR).
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# gh mock — intercepts `gh issue view N --json state`
mk_state_check_mock() {
    MOCK_TMP="$(mktemp -d)"
    mkdir -p "$MOCK_TMP/mock-bin"
    cat > "$MOCK_TMP/mock-bin/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
ARGS="$*"
case "$ARGS" in
  issue\ view\ *--json\ state*)
    if [ "${GH_MOCK_FAIL:-}" = "1" ]; then
        echo "error: gh failed" >&2
        exit 1
    fi
    N=$(printf '%s\n' "$ARGS" | grep -oE 'issue view [0-9]+' | awk '{print $3}')
    VAR="GH_MOCK_STATE_${N}"
    printf '%s\n' "${!VAR:-${GH_MOCK_STATE:-OPEN}}"
    exit 0 ;;
  *) exit 2 ;;
esac
MOCK_EOF
    chmod +x "$MOCK_TMP/mock-bin/gh"
    export PATH="$MOCK_TMP/mock-bin:$PATH"
}

rm_state_check_mock() {
    if [ -n "${MOCK_TMP:-}" ] && [ -d "$MOCK_TMP" ]; then
        export PATH="${PATH#"$MOCK_TMP/mock-bin:"}"
        rm -rf "$MOCK_TMP" 2>/dev/null || true
    fi
    MOCK_TMP=""
    unset GH_MOCK_STATE GH_MOCK_STATE_449 GH_MOCK_STATE_450 GH_MOCK_FAIL 2>/dev/null || true
}

setup_tmp() {
    TMP="$(mktemp -d)"
}

teardown_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
