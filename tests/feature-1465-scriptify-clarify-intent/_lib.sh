#!/usr/bin/env bash
# tests/feature-1465-scriptify-clarify-intent/_lib.sh
# Shared helpers for the feature-1465 test suite.
# Sourced by run-completion.sh and check-complexity-skip.sh; guarded against double-sourcing.

if [ -n "${_F1465_LIB_SOURCED:-}" ]; then
    return 0
fi
_F1465_LIB_SOURCED=1

PASS=${PASS:-0}; FAIL=${FAIL:-0}; SKIP=${SKIP:-0}

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Guard: skip a test when the script under test is not yet implemented.
require_script() {
    local label="$1" script="$2"
    if [ ! -f "$script" ]; then
        skip "$label (script not implemented yet: $script)"
        return 1
    fi
    return 0
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

# Create a fresh temp dir; sets TEST_DIR and TEST_DIR_NODE (node-friendly path)
setup_test_dir() {
    TEST_DIR="$(mktemp -d)"
    if command -v cygpath >/dev/null 2>&1; then
        TEST_DIR_NODE="$(cygpath -m "$TEST_DIR")"
    else
        TEST_DIR_NODE="$TEST_DIR"
    fi
    mkdir -p "$TEST_DIR/bin/github-issues"
    mkdir -p "$TEST_DIR/bin/workflow"
    mkdir -p "$TEST_DIR/bin"
    mkdir -p "$TEST_DIR/hooks/lib"
}

cleanup_test_dir() {
    [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"
    TEST_DIR=""
}

# Write a mock executable that exits with a given code and optionally prints text
write_mock() {
    local path="$1" exit_code="$2" stdout_text="${3:-}"
    cat > "$path" <<EOF
#!/usr/bin/env bash
${stdout_text:+printf '%s\n' "$stdout_text"}
exit $exit_code
EOF
    chmod +x "$path"
}
