#!/bin/bash
# tests/bin/feature-capture-env-session-id-fallback.sh
# Tests: skills/worktree-end/scripts/capture-env.sh
# Tags: worktree, end, cleanup, skill, bin, feature-2696, plans-dir, scope:issue-specific
#
# Unit tests for the session-id fallback logic (and, P1-P3, the #2696 PLANS_DIR resolution) in:
#   skills/worktree-end/scripts/capture-env.sh
#
# Uses PATH-prepend mocking to avoid real gh/git calls.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/capture-env.sh"

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
    # REAL sibling-repos-json.js — capture-env.sh invokes it via LIB_DIR.
    cp "$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/sibling-repos-json.js" "$envdir/scripts/sibling-repos-json.js"
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
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$SCRIPT_CHECKOUT_ROOT\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"

    export PLANS_DIR="$TMPDIR_BASE/plans"
    export WORKFLOW_PLANS_DIR="$PLANS_DIR"
    export WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow"
    mkdir -p "$PLANS_DIR" "$WORKFLOW_STATE_DIR"
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

    local env_json="$TMPDIR_BASE/workflow/sess-xyz.control/final-report-env.json"
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
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$SCRIPT_CHECKOUT_ROOT\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
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
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$SCRIPT_CHECKOUT_ROOT\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
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

    local env_json_arg="$TMPDIR_BASE/workflow/arg-sid.control/final-report-env.json"
    local env_json_notes="$TMPDIR_BASE/workflow/notes-sid.control/final-report-env.json"
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
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$SCRIPT_CHECKOUT_ROOT\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
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

# ---- #2696: PLANS_DIR unset → resolved via bin/workflow-plans-dir ----
# /worktree-end WE-8 never passes PLANS_DIR, so capture-env.sh aborted with
# "PLANS_DIR must be set". It now resolves the dir itself; a resolver failure still aborts.
# $1 = case tag, $2 = checkout root the copy treats as SCRIPT_CHECKOUT_ROOT. Prints the copy path.
make_plans_dir_copy() {
    local tag="$1" root="$2"
    local envdir="$TMPDIR_BASE/mockenv_$tag"
    setup_mock_env "$envdir"
    local script_copy="$TMPDIR_BASE/capture-env-$tag.sh"
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$root\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"
    printf '%s' "$script_copy"
}

# $1 = case tag, $2 = "bootstrap" or "normal". Runs with PLANS_DIR unset and BACKUP_DIR '(none)',
# so the notes backup lands in the resolved plans dir.
run_plans_dir_unset() {
    local tag="$1" branch="$2" sid="pd-$1"
    local wt="$TMPDIR_BASE/$tag-wt"
    mkdir -p "$wt"
    printf 'Session-ID: %s\nBranch: fix/test\n' "$sid" > "$wt/WORKTREE_NOTES.md"
    local script_copy plans="$TMPDIR_BASE/plans_$tag"
    script_copy="$(make_plans_dir_copy "$tag" "$SCRIPT_CHECKOUT_ROOT")"
    mkdir -p "$plans" "$TMPDIR_BASE/workflow"
    local bootstrap=0
    [[ "$branch" == "bootstrap" ]] && bootstrap=1
    local output code
    output="$(PATH="$TMPDIR_BASE/mockenv_$tag/bin:$PATH" run_with_timeout 30 env -u PLANS_DIR \
        WORKFLOW_PLANS_DIR="$plans" WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow" \
        BOOTSTRAP_MODE="$bootstrap" BOOTSTRAP_COMMIT_SHA=abc \
        bash "$script_copy" "$wt" "testowner/testrepo" "(none)" "" 2>&1)"
    code=$?
    local backup="$plans/$sid-notes-backup/WORKTREE_NOTES.md"
    local env_json="$TMPDIR_BASE/workflow/$sid.control/final-report-env.json"
    if [[ "$code" == "0" && -f "$backup" && -f "$env_json" ]]; then
        pass "P-$tag: PLANS_DIR unset ($branch branch) → resolved; notes backup in WORKFLOW_PLANS_DIR, env JSON written"
    else
        fail "P-$tag: expected exit 0 + $backup + env JSON, got code=$code backup=$([[ -f "$backup" ]] && echo yes || echo no) env=$([[ -f "$env_json" ]] && echo yes || echo no) (output=$output)"
    fi
}

test_P1_plans_dir_unset_bootstrap_branch() { run_plans_dir_unset unset-bootstrap bootstrap; }
test_P2_plans_dir_unset_normal_branch() { run_plans_dir_unset unset-normal normal; }

test_P3_plans_dir_resolver_failure_aborts() {
    local tag="resolver-fail" sid="pd-resolver-fail"
    local fake_root="$TMPDIR_BASE/fake-root"
    mkdir -p "$fake_root/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_root/bin/workflow-plans-dir"
    chmod +x "$fake_root/bin/workflow-plans-dir"
    local wt="$TMPDIR_BASE/$tag-wt"
    mkdir -p "$wt"
    printf 'Session-ID: %s\n' "$sid" > "$wt/WORKTREE_NOTES.md"
    local script_copy
    script_copy="$(make_plans_dir_copy "$tag" "$fake_root")"
    local stderr code
    stderr="$(PATH="$TMPDIR_BASE/mockenv_$tag/bin:$PATH" run_with_timeout 30 env -u PLANS_DIR \
        WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans_$tag" WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow" \
        bash "$script_copy" "$wt" "testowner/testrepo" "(none)" "" 2>&1 >/dev/null)"
    code=$?
    if [[ "$code" != "0" ]] && grep -q "capture-env: cannot resolve PLANS_DIR" <<< "$stderr"; then
        pass "P3: PLANS_DIR unset + resolver CLI fails → exit non-zero + 'cannot resolve PLANS_DIR'"
    else
        fail "P3: expected exit non-zero + 'capture-env: cannot resolve PLANS_DIR', got code=$code stderr='$stderr'"
    fi
}

# P4: the resolver exits 0 but prints nothing — an empty PLANS_DIR must abort too.
test_P4_plans_dir_resolver_empty_output_aborts() {
    local tag="resolver-empty" sid="pd-resolver-empty"
    local fake_root="$TMPDIR_BASE/fake-root-empty"
    mkdir -p "$fake_root/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_root/bin/workflow-plans-dir"
    chmod +x "$fake_root/bin/workflow-plans-dir"
    local wt="$TMPDIR_BASE/$tag-wt"
    mkdir -p "$wt"
    printf 'Session-ID: %s\n' "$sid" > "$wt/WORKTREE_NOTES.md"
    local script_copy
    script_copy="$(make_plans_dir_copy "$tag" "$fake_root")"
    local stderr code
    stderr="$(PATH="$TMPDIR_BASE/mockenv_$tag/bin:$PATH" run_with_timeout 30 env -u PLANS_DIR \
        WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans_$tag" WORKFLOW_STATE_DIR="$TMPDIR_BASE/workflow" \
        bash "$script_copy" "$wt" "testowner/testrepo" "(none)" "" 2>&1 >/dev/null)"
    code=$?
    local env_json="$TMPDIR_BASE/workflow/$sid.control/final-report-env.json"
    if [[ "$code" != "0" && ! -f "$env_json" ]] && grep -q "capture-env: cannot resolve PLANS_DIR" <<< "$stderr"; then
        pass "P4: PLANS_DIR unset + resolver exits 0 with empty output → exit non-zero + 'cannot resolve PLANS_DIR', no env JSON"
    else
        fail "P4: expected exit non-zero + 'capture-env: cannot resolve PLANS_DIR' + no env JSON, got code=$code env=$([[ -f "$env_json" ]] && echo yes || echo no) stderr='$stderr'"
    fi
}

# ============ Run all ============

test_F1_fallback_reads_session_id_from_notes
test_F2a_no_notes_no_arg_errors
test_F2b_notes_without_session_id_errors
test_F3_arg_takes_precedence
test_F4_invalid_session_id_in_notes_rejected
test_P1_plans_dir_unset_bootstrap_branch
test_P2_plans_dir_unset_normal_branch
test_P3_plans_dir_resolver_failure_aborts
test_P4_plans_dir_resolver_empty_output_aborts

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
