#!/usr/bin/env bash
# tests/skills/feature-1465-scriptify-clarify-intent/_lib.sh
# Shared helpers for the feature-1465 test suite.
# Sourced by run-completion.sh; guarded against double-sourcing.

if [ -n "${_F1465_LIB_SOURCED:-}" ]; then
    return 0
fi
_F1465_LIB_SOURCED=1

PASS=${PASS:-0}; FAIL=${FAIL:-0}; SKIP=${SKIP:-0}

# The scripts under test find their tooling from their own location, so
# setup_test_dir places a copy of them in TEST_DIR next to the mocks and every
# case runs that copy.
F1465_SUT_REL_DIR="skills/clarify-intent/scripts"
_F1465_SUT_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../$F1465_SUT_REL_DIR" && pwd)"
_F1465_REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# #2748: the SUT resolves the intent path through bin/plan-artifact-path, which reads
# the state file of the session chain; pin both dirs so the real CLI sees an empty store.
readonly _F1465_ISO_ROOT="$(mktemp -d)"
trap 'rm -rf "$_F1465_ISO_ROOT"' EXIT
mkdir -p "$_F1465_ISO_ROOT/state" "$_F1465_ISO_ROOT/plans"
export WORKFLOW_STATE_DIR="$_F1465_ISO_ROOT/state" WORKFLOW_PLANS_DIR="$_F1465_ISO_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID

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
    mkdir -p "$TEST_DIR/$F1465_SUT_REL_DIR"
    cp "$_F1465_SUT_SRC_DIR"/*.sh "$TEST_DIR/$F1465_SUT_REL_DIR/" 2>/dev/null || true
    _f1465_delegate_plan_artifact_path
}

# The fake tree's bin/plan-artifact-path delegates to the real CLI, so the SUT gets the
# real first_session_id contract while hooks/lib in the fake tree stays mockable.
_f1465_delegate_plan_artifact_path() {
    local real_node
    real_node="$(cygpath -m "$_F1465_REAL_ROOT/bin/plan-artifact-path" 2>/dev/null || printf '%s' "$_F1465_REAL_ROOT/bin/plan-artifact-path")"
    printf '%s\n' "require('$real_node');" > "$TEST_DIR/bin/plan-artifact-path"
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

# #2277: run-completion.sh runs `node <root>/bin/workflow/check-plan-approval`, so the
# mock is a JS file. Prints <stdout> (literal "APPROVAL=..." line), exits <exit>, and
# records its argv (one per line) to <args-file> when one is given.
mock_plan_approval() {
    local stdout_text="$1" exit_code="${2:-0}" args_file="${3:-}"
    local file="$TEST_DIR/bin/workflow/check-plan-approval"
    local args_node=""
    [ -n "$args_file" ] && args_node="$(cygpath -m "$args_file" 2>/dev/null || printf '%s' "$args_file")"
    printf '%s\n' "const fs = require('fs');" \
        "const a = process.argv.slice(2).join('\\n') + '\\n';" \
        "if ('$args_node') fs.writeFileSync('$args_node', a);" \
        "if ('$stdout_text') process.stdout.write('$stdout_text\\n');" \
        "process.exit($exit_code);" > "$file"
}
