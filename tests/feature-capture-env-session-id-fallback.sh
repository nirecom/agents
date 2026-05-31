#!/bin/bash
# tests/feature-capture-env-session-id-fallback.sh
# Tests: bin/gh, bin/git, skills/worktree-end/scripts/capture-env.sh
# Tags: worktree, end, cleanup, skill, bin
#
# Unit tests for the session-id fallback logic in:
#   skills/worktree-end/scripts/capture-env.sh
#
# Uses PATH-prepend mocking to avoid real gh/git calls.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/skills/worktree-end/scripts/capture-env.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

# Setup a mock environment directory with fake gh, git, node, bash (for detect-restart.sh)
# and a fake LIB_DIR with detect-restart.sh and write-env-json.js.
setup_mock_env() {
    local envdir="$1"

    mkdir -p "$envdir/bin"
    mkdir -p "$envdir/scripts"

    # Fake gh — always returns a valid PR number
    cat > "$envdir/bin/gh" << 'GHEOF'
#!/bin/bash
# Fake gh: returns pr number for list, pr fields for view
if [[ "$*" == *"pr list"* ]]; then
    echo "42"
elif [[ "$*" == *"pr view"* ]]; then
    printf '{"title":"test PR","url":"https://github.com/test/repo/pull/42","state":"OPEN"}'
fi
GHEOF
    chmod +x "$envdir/bin/gh"

    # Fake git — always returns a branch name and a SHA
    cat > "$envdir/bin/git" << 'GITEOF'
#!/bin/bash
if [[ "$*" == *"rev-parse --abbrev-ref"* ]]; then
    echo "fix/642-test"
elif [[ "$*" == *"rev-parse HEAD"* ]]; then
    echo "abc1234567890"
fi
GITEOF
    chmod +x "$envdir/bin/git"

    # Fake detect-restart.sh — outputs minimal required fields
    cat > "$envdir/scripts/detect-restart.sh" << 'DREOF'
#!/bin/bash
echo "cc_restart=not_required|"
echo "vscode_reload=not_required|"
echo "installer_rerun=not_required|"
echo "os_reboot=not_required|"
DREOF
    chmod +x "$envdir/scripts/detect-restart.sh"

    # Fake write-env-json.js — writes a minimal JSON file at argv[1]
    cat > "$envdir/scripts/write-env-json.js" << 'WEJEOF'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const outPath = process.argv[2];
const env = process.env;
const obj = {
    session_id: env.SESSION_ID || "",
    pr_number: env.PR_NUMBER || "",
};
fs.mkdirSync(require("path").dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify(obj) + "\n");
WEJEOF

    # Fake extract-pr-fields.js — parses JSON and emits key=value
    cat > "$envdir/scripts/extract-pr-fields.js" << 'EPFEOF'
#!/usr/bin/env node
"use strict";
const fields = process.argv.slice(process.argv.indexOf("--fields") + 1).join("").split(",");
let buf = "";
process.stdin.on("data", c => buf += c);
process.stdin.on("end", () => {
    try {
        const j = JSON.parse(buf);
        for (const f of fields) {
            process.stdout.write(f + "=" + (j[f] || "") + "\n");
        }
    } catch(e) {
        process.exit(1);
    }
});
EPFEOF
}

# Run capture-env.sh with a mock environment
# Args: worktree repo backup_dir [session_id_arg4]
run_capture_env() {
    local worktree="$1"
    local repo="${2:-testowner/testrepo}"
    local backup_dir="$3"
    local session_id_arg="${4:-}"

    local envdir="$TMPDIR_BASE/mockenv"
    setup_mock_env "$envdir"

    local script_copy="$TMPDIR_BASE/capture-env-test.sh"
    sed "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"

    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PLANS_DIR="$TMPDIR_BASE/plans"
    mkdir -p "$PLANS_DIR"
    mkdir -p "$backup_dir"

    PATH="$envdir/bin:$PATH" \
    run_with_timeout 30 bash "$script_copy" "$worktree" "$repo" "$backup_dir" "$session_id_arg" 2>&1
    return $?
}


# ---- F1: WORKTREE_NOTES.md has Session-ID + arg4 empty → reads from notes ----
test_F1_fallback_reads_session_id_from_notes() {
    if [ ! -f "$SCRIPT" ]; then
        fail "F1: capture-env.sh not implemented yet (expected to fail)"
        return
    fi
    local wt="$TMPDIR_BASE/f1-wt"
    mkdir -p "$wt"
    printf 'Session-ID: sess-xyz\nBranch: fix/test\n' > "$wt/WORKTREE_NOTES.md"

    local backup="$TMPDIR_BASE/f1-backup"
    mkdir -p "$backup"

    local output
    output="$(run_capture_env "$wt" "testowner/testrepo" "$backup" "")"
    local code=$?

    local env_json="$TMPDIR_BASE/plans/sess-xyz-final-report-env.json"
    if [ "$code" = "0" ] && [ -f "$env_json" ]; then
        pass "F1: fallback reads Session-ID from WORKTREE_NOTES.md → sess-xyz-final-report-env.json created"
    else
        fail "F1: expected exit 0 + sess-xyz-final-report-env.json, got code=$code (output=$output, json_exists=$(test -f "$env_json" && echo yes || echo no))"
    fi
}

# ---- F2a: No WORKTREE_NOTES.md + arg4 empty → error ----
test_F2a_no_notes_no_arg_errors() {
    if [ ! -f "$SCRIPT" ]; then
        fail "F2a: capture-env.sh not implemented yet (expected to fail)"
        return
    fi
    local wt="$TMPDIR_BASE/f2a-wt"
    mkdir -p "$wt"

    local backup="$TMPDIR_BASE/f2a-backup"
    local envdir="$TMPDIR_BASE/mockenv_f2a"
    setup_mock_env "$envdir"
    local script_copy="$TMPDIR_BASE/capture-env-f2a.sh"
    sed "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PLANS_DIR="$TMPDIR_BASE/plans_f2a"
    mkdir -p "$PLANS_DIR" "$backup"

    local stderr
    stderr="$(PATH="$envdir/bin:$PATH" run_with_timeout 30 bash "$script_copy" "$wt" "testowner/testrepo" "$backup" "" 2>&1 >/dev/null)"
    local code=$?

    if [ "$code" != "0" ] && echo "$stderr" | grep -qi "session-id\|session_id\|unresolved"; then
        pass "F2a: no WORKTREE_NOTES.md + no arg4 → exit non-zero + error mentions session-id"
    else
        fail "F2a: expected exit non-zero + session-id error, got code=$code stderr='$stderr'"
    fi
}

# ---- F2b: WORKTREE_NOTES.md exists but no Session-ID line + arg4 empty → error ----
test_F2b_notes_without_session_id_errors() {
    if [ ! -f "$SCRIPT" ]; then
        fail "F2b: capture-env.sh not implemented yet (expected to fail)"
        return
    fi
    local wt="$TMPDIR_BASE/f2b-wt"
    mkdir -p "$wt"
    printf 'Branch: fix/test\nCreated: 2024-01-15\n' > "$wt/WORKTREE_NOTES.md"

    local backup="$TMPDIR_BASE/f2b-backup"
    local envdir="$TMPDIR_BASE/mockenv_f2b"
    setup_mock_env "$envdir"
    local script_copy="$TMPDIR_BASE/capture-env-f2b.sh"
    sed "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PLANS_DIR="$TMPDIR_BASE/plans_f2b"
    mkdir -p "$PLANS_DIR" "$backup"

    local stderr
    stderr="$(PATH="$envdir/bin:$PATH" run_with_timeout 30 bash "$script_copy" "$wt" "testowner/testrepo" "$backup" "" 2>&1 >/dev/null)"
    local code=$?

    if [ "$code" != "0" ] && echo "$stderr" | grep -qi "session-id\|session_id\|unresolved"; then
        pass "F2b: WORKTREE_NOTES.md without Session-ID line + no arg4 → exit non-zero + session-id error"
    else
        fail "F2b: expected exit non-zero + session-id error, got code=$code stderr='$stderr'"
    fi
}

# ---- F3: arg4 takes precedence over WORKTREE_NOTES.md ----
test_F3_arg_takes_precedence() {
    if [ ! -f "$SCRIPT" ]; then
        fail "F3: capture-env.sh not implemented yet (expected to fail)"
        return
    fi
    local wt="$TMPDIR_BASE/f3-wt"
    mkdir -p "$wt"
    printf 'Session-ID: notes-sid\nBranch: fix/test\n' > "$wt/WORKTREE_NOTES.md"

    local backup="$TMPDIR_BASE/f3-backup"
    mkdir -p "$backup"

    local output
    output="$(run_capture_env "$wt" "testowner/testrepo" "$backup" "arg-sid")"
    local code=$?

    local env_json_arg="$TMPDIR_BASE/plans/arg-sid-final-report-env.json"
    local env_json_notes="$TMPDIR_BASE/plans/notes-sid-final-report-env.json"
    if [ "$code" = "0" ] && [ -f "$env_json_arg" ] && [ ! -f "$env_json_notes" ]; then
        pass "F3: arg4 'arg-sid' takes precedence over notes 'notes-sid' → arg-sid JSON created, notes-sid JSON absent"
    else
        fail "F3: expected arg-sid JSON only, got code=$code arg_json=$(test -f "$env_json_arg" && echo yes || echo no) notes_json=$(test -f "$env_json_notes" && echo yes || echo no) (output=$output)"
    fi
}

# ---- F4: invalid session-id in notes → error ----
test_F4_invalid_session_id_in_notes_rejected() {
    if [ ! -f "$SCRIPT" ]; then
        fail "F4: capture-env.sh not implemented yet (expected to fail)"
        return
    fi
    local wt="$TMPDIR_BASE/f4-wt"
    mkdir -p "$wt"
    printf 'Session-ID: bad/path\nBranch: fix/test\n' > "$wt/WORKTREE_NOTES.md"

    local backup="$TMPDIR_BASE/f4-backup"
    local envdir="$TMPDIR_BASE/mockenv_f4"
    setup_mock_env "$envdir"
    local script_copy="$TMPDIR_BASE/capture-env-f4.sh"
    sed "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PLANS_DIR="$TMPDIR_BASE/plans_f4"
    mkdir -p "$PLANS_DIR" "$backup"

    local stderr
    stderr="$(PATH="$envdir/bin:$PATH" run_with_timeout 30 bash "$script_copy" "$wt" "testowner/testrepo" "$backup" "" 2>&1 >/dev/null)"
    local code=$?

    if [ "$code" != "0" ] && echo "$stderr" | grep -qi "invalid\|SESSION_ID"; then
        pass "F4: invalid session-id 'bad/path' in notes → exit non-zero + invalid error"
    else
        fail "F4: expected exit non-zero + invalid error, got code=$code stderr='$stderr'"
    fi
}

# ============ Run all ============

test_F1_fallback_reads_session_id_from_notes
test_F2a_no_notes_no_arg_errors
test_F2b_notes_without_session_id_errors
test_F3_arg_takes_precedence
test_F4_invalid_session_id_in_notes_rejected

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
