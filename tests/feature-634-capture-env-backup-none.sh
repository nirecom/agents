#!/bin/bash
# tests/feature-634-capture-env-backup-none.sh
# Tests: skills/worktree-end/scripts/capture-env.sh
# Tags: worktree, end, cleanup, skill, bin, backup
#
# Unit tests for the BACKUP_DIR=(none) / missing-dir fallback logic in:
#   skills/worktree-end/scripts/capture-env.sh
#
# Uses PATH-prepend mocking to avoid real gh/git calls and uses the REAL
# write-env-json.js so NOTES_BACKUP_PATH / BACKUP_MANIFEST_PATH can be asserted
# from the output JSON.

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

# Setup a mock environment directory with fake gh, git, and required helper
# scripts. Uses the REAL write-env-json.js so we can assert on output JSON
# field values.
setup_mock_env() {
    local envdir="$1"

    mkdir -p "$envdir/bin"
    mkdir -p "$envdir/scripts"

    # Fake gh — handles pr list, pr view (default), and pr view --json mergeCommit
    cat > "$envdir/bin/gh" << 'GHEOF'
#!/bin/bash
if [[ "$*" == *"pr list"* ]]; then
    echo "42"
elif [[ "$*" == *"mergeCommit"* ]]; then
    printf 'deadbeef1234567'
elif [[ "$*" == *"pr view"* ]]; then
    printf '{"title":"test PR","url":"https://github.com/test/repo/pull/42","state":"MERGED"}'
fi
GHEOF
    chmod +x "$envdir/bin/gh"

    # Fake git — returns a branch name and a SHA
    cat > "$envdir/bin/git" << 'GITEOF'
#!/bin/bash
if [[ "$*" == *"rev-parse --abbrev-ref"* ]]; then
    echo "fix/634-test"
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

    # REAL write-env-json.js — copy from source so we can assert output JSON.
    cp "$AGENTS_DIR/skills/worktree-end/scripts/write-env-json.js" "$envdir/scripts/write-env-json.js"

    # Fake extract-pr-fields.js — parses JSON and emits key=value lines.
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

# Helper variant: pre-creates the backup_dir before running capture-env.sh.
# Use for G3 (real backup dir regression).
# Args: worktree repo backup_dir session_id [envdir_suffix]
run_capture_env_real_dir() {
    local worktree="$1"
    local repo="$2"
    local backup_dir="$3"
    local session_id_arg="$4"
    local suffix="${5:-$session_id_arg}"

    local envdir="$TMPDIR_BASE/mockenv-$suffix"
    setup_mock_env "$envdir"

    local script_copy="$TMPDIR_BASE/capture-env-$suffix.sh"
    sed "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"

    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PLANS_DIR="$TMPDIR_BASE/plans-$suffix"
    mkdir -p "$PLANS_DIR"
    mkdir -p "$backup_dir"

    PATH="$envdir/bin:$PATH" \
    run_with_timeout 30 bash "$script_copy" "$worktree" "$repo" "$backup_dir" "$session_id_arg" 2>&1
    return $?
}

# Helper variant: passes backup_dir verbatim with NO pre-creation.
# Use for G1, G2, G4 (sentinel '(none)' and missing-dir fallback).
# Args: worktree repo backup_dir session_id [envdir_suffix]
run_capture_env_raw() {
    local worktree="$1"
    local repo="$2"
    local backup_dir="$3"
    local session_id_arg="$4"
    local suffix="${5:-$session_id_arg}"

    local envdir="$TMPDIR_BASE/mockenv-$suffix"
    setup_mock_env "$envdir"

    local script_copy="$TMPDIR_BASE/capture-env-$suffix.sh"
    sed "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$envdir/scripts\"|" \
        "$SCRIPT" > "$script_copy"
    chmod +x "$script_copy"

    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    export PLANS_DIR="$TMPDIR_BASE/plans-$suffix"
    mkdir -p "$PLANS_DIR"

    PATH="$envdir/bin:$PATH" \
    run_with_timeout 30 bash "$script_copy" "$worktree" "$repo" "$backup_dir" "$session_id_arg" 2>&1
    return $?
}

# Read a JSON field via node (no jq dependency).
read_json_field() {
    local file="$1"
    local field="$2"
    node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))[process.argv[2]])" "$file" "$field"
}

# Normalize a path the same way Node sees it after MSYS env-var translation
# (Git Bash on Windows converts /tmp/... → C:/Users/.../Temp/... when passing
# env vars to a native Windows node.exe). On non-Windows this is a no-op.
normalize_path() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        # -m gives mixed (forward-slash) Windows form, matching Node's view.
        cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
    else
        printf '%s' "$p"
    fi
}

# ---- G1: fallback path on '(none)' literal ----
test_G1_none_literal_falls_back() {
    if [ ! -f "$SCRIPT" ]; then
        fail "G1: capture-env.sh not present"
        return
    fi
    local wt="$TMPDIR_BASE/g1-wt"
    mkdir -p "$wt"
    printf 'Session-ID: sess-g1\n' > "$wt/WORKTREE_NOTES.md"

    local cwd_before
    cwd_before="$(pwd)"
    local output
    output="$(run_capture_env_raw "$wt" "testowner/testrepo" "(none)" "sess-g1")"
    local code=$?

    local plans_dir="$TMPDIR_BASE/plans-sess-g1"
    local env_json="$plans_dir/sess-g1-final-report-env.json"
    local expected_notes
    expected_notes="$(normalize_path "$plans_dir/sess-g1-notes-backup/WORKTREE_NOTES.md")"

    if [ "$code" != "0" ]; then
        fail "G1: expected exit 0, got code=$code (output=$output)"
        return
    fi
    if [ ! -f "$env_json" ]; then
        fail "G1: env JSON not written at $env_json (output=$output)"
        return
    fi
    local notes_path manifest_path
    notes_path="$(read_json_field "$env_json" NOTES_BACKUP_PATH)"
    manifest_path="$(read_json_field "$env_json" BACKUP_MANIFEST_PATH)"
    if [ "$notes_path" != "$expected_notes" ]; then
        fail "G1: NOTES_BACKUP_PATH expected '$expected_notes', got '$notes_path'"
        return
    fi
    if [ "$manifest_path" != "(none)" ]; then
        fail "G1: BACKUP_MANIFEST_PATH expected '(none)', got '$manifest_path'"
        return
    fi
    if [ ! -f "$expected_notes" ]; then
        fail "G1: fallback file missing at $expected_notes"
        return
    fi
    # Verify content matches
    if ! diff -q "$wt/WORKTREE_NOTES.md" "$expected_notes" >/dev/null 2>&1; then
        fail "G1: copied content differs from source"
        return
    fi
    # Verify no literal '(none)' directory was created
    if [ -d "$cwd_before/(none)" ] || [ -d "$wt/(none)" ]; then
        fail "G1: a literal '(none)' directory was created"
        return
    fi
    pass "G1: '(none)' literal triggers fallback to PLANS_DIR/<sid>-notes-backup/"
}

# ---- G2: '(none)' with no notes file ----
test_G2_none_literal_no_notes() {
    if [ ! -f "$SCRIPT" ]; then
        fail "G2: capture-env.sh not present"
        return
    fi
    local wt="$TMPDIR_BASE/g2-wt"
    mkdir -p "$wt"
    # No WORKTREE_NOTES.md

    local output
    output="$(run_capture_env_raw "$wt" "testowner/testrepo" "(none)" "sess-g2")"
    local code=$?

    local plans_dir="$TMPDIR_BASE/plans-sess-g2"
    local env_json="$plans_dir/sess-g2-final-report-env.json"
    local fallback_dir="$plans_dir/sess-g2-notes-backup"

    if [ "$code" != "0" ]; then
        fail "G2: expected exit 0, got code=$code (output=$output)"
        return
    fi
    if [ ! -f "$env_json" ]; then
        fail "G2: env JSON not written at $env_json"
        return
    fi
    local notes_path manifest_path
    notes_path="$(read_json_field "$env_json" NOTES_BACKUP_PATH)"
    manifest_path="$(read_json_field "$env_json" BACKUP_MANIFEST_PATH)"
    if [ -n "$notes_path" ]; then
        fail "G2: NOTES_BACKUP_PATH expected empty string, got '$notes_path'"
        return
    fi
    if [ "$manifest_path" != "(none)" ]; then
        fail "G2: BACKUP_MANIFEST_PATH expected '(none)', got '$manifest_path'"
        return
    fi
    if [ -d "$fallback_dir" ]; then
        fail "G2: fallback dir $fallback_dir was unexpectedly created"
        return
    fi
    pass "G2: '(none)' with no notes file → empty NOTES_BACKUP_PATH, no fallback dir"
}

# ---- G3: real BACKUP_DIR still works (regression) ----
test_G3_real_backup_dir_still_works() {
    if [ ! -f "$SCRIPT" ]; then
        fail "G3: capture-env.sh not present"
        return
    fi
    local wt="$TMPDIR_BASE/g3-wt"
    mkdir -p "$wt"
    printf 'Session-ID: sess-g3\n' > "$wt/WORKTREE_NOTES.md"

    local backup_dir="$TMPDIR_BASE/g3-realdir"
    local output
    output="$(run_capture_env_real_dir "$wt" "testowner/testrepo" "$backup_dir" "sess-g3")"
    local code=$?

    local plans_dir="$TMPDIR_BASE/plans-sess-g3"
    local env_json="$plans_dir/sess-g3-final-report-env.json"

    if [ "$code" != "0" ]; then
        fail "G3: expected exit 0, got code=$code (output=$output)"
        return
    fi
    if [ ! -f "$env_json" ]; then
        fail "G3: env JSON not written at $env_json"
        return
    fi
    local notes_path manifest_path
    notes_path="$(read_json_field "$env_json" NOTES_BACKUP_PATH)"
    manifest_path="$(read_json_field "$env_json" BACKUP_MANIFEST_PATH)"
    local expected_notes expected_manifest
    expected_notes="$(normalize_path "$backup_dir/WORKTREE_NOTES.md")"
    expected_manifest="$(normalize_path "$backup_dir/manifest.json")"
    if [ "$notes_path" != "$expected_notes" ]; then
        fail "G3: NOTES_BACKUP_PATH expected '$expected_notes', got '$notes_path'"
        return
    fi
    if [ "$manifest_path" != "$expected_manifest" ]; then
        fail "G3: BACKUP_MANIFEST_PATH expected '$expected_manifest', got '$manifest_path'"
        return
    fi
    if [ ! -f "$backup_dir/WORKTREE_NOTES.md" ]; then
        fail "G3: file missing at $backup_dir/WORKTREE_NOTES.md"
        return
    fi
    pass "G3: real BACKUP_DIR populates manifest + notes paths normally"
}

# ---- G4: missing-directory BACKUP_DIR also falls back ----
test_G4_missing_dir_falls_back() {
    if [ ! -f "$SCRIPT" ]; then
        fail "G4: capture-env.sh not present"
        return
    fi
    local wt="$TMPDIR_BASE/g4-wt"
    mkdir -p "$wt"
    printf 'Session-ID: sess-g4\n' > "$wt/WORKTREE_NOTES.md"

    local bad_dir="$TMPDIR_BASE/g4-never-created"
    if [ -d "$bad_dir" ]; then
        fail "G4: precondition failed — $bad_dir should not exist"
        return
    fi

    local output
    output="$(run_capture_env_raw "$wt" "testowner/testrepo" "$bad_dir" "sess-g4")"
    local code=$?

    local plans_dir="$TMPDIR_BASE/plans-sess-g4"
    local env_json="$plans_dir/sess-g4-final-report-env.json"
    local expected_notes
    expected_notes="$(normalize_path "$plans_dir/sess-g4-notes-backup/WORKTREE_NOTES.md")"

    if [ "$code" != "0" ]; then
        fail "G4: expected exit 0, got code=$code (output=$output)"
        return
    fi
    local notes_path manifest_path
    notes_path="$(read_json_field "$env_json" NOTES_BACKUP_PATH)"
    manifest_path="$(read_json_field "$env_json" BACKUP_MANIFEST_PATH)"
    if [ "$notes_path" != "$expected_notes" ]; then
        fail "G4: NOTES_BACKUP_PATH expected '$expected_notes', got '$notes_path'"
        return
    fi
    if [ "$manifest_path" != "(none)" ]; then
        fail "G4: BACKUP_MANIFEST_PATH expected '(none)', got '$manifest_path'"
        return
    fi
    if [ ! -f "$expected_notes" ]; then
        fail "G4: fallback file missing at $expected_notes"
        return
    fi
    if [ -d "$bad_dir" ]; then
        fail "G4: missing dir $bad_dir was unexpectedly created"
        return
    fi
    pass "G4: missing BACKUP_DIR triggers same fallback as '(none)'"
}

# ============ Run all ============

test_G1_none_literal_falls_back
test_G2_none_literal_no_notes
test_G3_real_backup_dir_still_works
test_G4_missing_dir_falls_back

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
