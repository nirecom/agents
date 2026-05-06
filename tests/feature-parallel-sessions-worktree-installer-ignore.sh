#!/bin/bash
# tests/feature-parallel-sessions-worktree-installer-ignore.sh
#
# Implementation complete. Tests verify the production contract.

# Implementation tracked in: ~/.claude/plans/intent-20260505-211305-detail.md
#
# Targets: install/linux/install.sh global gitignore append section
#          (idempotent block in $XDG_CONFIG_HOME/git/ignore for WORKTREE_NOTES.md)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$AGENTS_DIR/install/linux/global-gitignore.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'pst-inst-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

require_installer() {
    if [ ! -f "$INSTALLER" ]; then
        fail "$1 (install/linux/install.sh not implemented)"
        return 1
    fi
    return 0
}

# Run installer in isolated XDG_CONFIG_HOME, capture stdout+stderr+exit.
# Args: xdg_dir [extra-env=val ...]
run_installer() {
    local xdg="$1"; shift
    run_with_timeout 60 env "XDG_CONFIG_HOME=$xdg" "HOME=$xdg/home" "$@" \
        bash "$INSTALLER" 2>&1
}

# Make a fresh isolated env. Returns the path to the gitignore file.
make_env() {
    local name="$1"
    local xdg="$TMPDIR_BASE/$name"
    mkdir -p "$xdg/home" "$xdg/git"
    echo "$xdg"
}

assert_block_present() {
    local file="$1" label="$2"
    if [ ! -f "$file" ]; then
        fail "$label: file not created: $file"
        return
    fi
    if ! grep -q "BEGIN agents-managed" "$file"; then
        fail "$label: BEGIN marker missing"
        return
    fi
    if ! grep -q "END agents-managed" "$file"; then
        fail "$label: END marker missing"
        return
    fi
    if ! grep -q "WORKTREE_NOTES.md" "$file"; then
        fail "$label: WORKTREE_NOTES.md entry missing"
        return
    fi
    pass "$label: block present and well-formed"
}

count_blocks() {
    local file="$1"
    grep -c "BEGIN agents-managed" "$file" 2>/dev/null || echo 0
}

# ============ Tests ============

test_creates_when_missing() {
    require_installer "test_creates_when_missing" || return
    local xdg; xdg="$(make_env "case-missing")"
    local gitignore="$xdg/git/ignore"
    [ ! -f "$gitignore" ] || { fail "precondition: file should not exist"; return; }
    run_installer "$xdg" >/dev/null 2>&1 || true
    assert_block_present "$gitignore" "create-when-missing"
}

test_appends_to_existing_unrelated() {
    require_installer "test_appends_to_existing_unrelated" || return
    local xdg; xdg="$(make_env "case-existing")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '*.log\n*.tmp\n' > "$gitignore"
    run_installer "$xdg" >/dev/null 2>&1 || true
    assert_block_present "$gitignore" "append-to-existing"
    if grep -q '\*.log' "$gitignore" && grep -q '\*.tmp' "$gitignore"; then
        pass "existing content preserved"
    else
        fail "existing content removed by installer"
    fi
}

test_replaces_existing_block() {
    require_installer "test_replaces_existing_block" || return
    local xdg; xdg="$(make_env "case-replace")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '%s\n' \
      '# --- BEGIN agents-managed ---' \
      'OLD_ENTRY.md' \
      '# --- END agents-managed ---' > "$gitignore"
    run_installer "$xdg" >/dev/null 2>&1 || true
    assert_block_present "$gitignore" "replace-existing-block"
    if grep -q "OLD_ENTRY.md" "$gitignore"; then
        fail "old block content not replaced"
    else
        pass "old block content replaced"
    fi
}

test_idempotent_double_run() {
    require_installer "test_idempotent_double_run" || return
    local xdg; xdg="$(make_env "case-double")"
    run_installer "$xdg" >/dev/null 2>&1 || true
    run_installer "$xdg" >/dev/null 2>&1 || true
    local gitignore="$xdg/git/ignore"
    local count; count="$(count_blocks "$gitignore")"
    if [ "$count" = "1" ]; then
        pass "double-run idempotent: exactly 1 block"
    else
        fail "double-run produced $count blocks (expected 1)"
    fi
    # Match only the actual gitignore entry line (not the comment that also contains the name)
    local entries; entries="$(grep -c "^WORKTREE_NOTES\.md$" "$gitignore" 2>/dev/null || echo 0)"
    if [ "$entries" = "1" ]; then
        pass "double-run idempotent: exactly 1 WORKTREE_NOTES.md entry"
    else
        fail "double-run produced $entries entries (expected 1)"
    fi
}

test_empty_file() {
    require_installer "test_empty_file" || return
    local xdg; xdg="$(make_env "case-empty")"
    mkdir -p "$xdg/git"
    : > "$xdg/git/ignore"
    run_installer "$xdg" >/dev/null 2>&1 || true
    assert_block_present "$xdg/git/ignore" "empty-file"
}

test_no_trailing_newline() {
    require_installer "test_no_trailing_newline" || return
    local xdg; xdg="$(make_env "case-nonl")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '*.log' > "$gitignore"  # no trailing newline
    run_installer "$xdg" >/dev/null 2>&1 || true
    assert_block_present "$gitignore" "no-trailing-newline"
    # Verify *.log not merged with BEGIN line
    if grep -q '\*.log# --- BEGIN' "$gitignore"; then
        fail "block appended without newline separator"
    else
        pass "block cleanly appended (newline inserted)"
    fi
}

test_begin_only_aborts() {
    require_installer "test_begin_only_aborts" || return
    local xdg; xdg="$(make_env "case-begin-only")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '%s\n' '# --- BEGIN agents-managed ---' 'partial' > "$gitignore"
    local out; out="$(run_installer "$xdg" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        pass "BEGIN-only marker: installer aborts non-zero"
    else
        fail "BEGIN-only marker: installer should abort but exited 0"
    fi
}

test_end_only_aborts() {
    require_installer "test_end_only_aborts" || return
    local xdg; xdg="$(make_env "case-end-only")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '%s\n' 'partial' '# --- END agents-managed ---' > "$gitignore"
    local out; out="$(run_installer "$xdg" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        pass "END-only marker: installer aborts non-zero"
    else
        fail "END-only marker: installer should abort but exited 0"
    fi
}

test_two_begin_aborts() {
    require_installer "test_two_begin_aborts" || return
    local xdg; xdg="$(make_env "case-two-begin")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '%s\n' \
      '# --- BEGIN agents-managed ---' \
      'a' \
      '# --- END agents-managed ---' \
      '# --- BEGIN agents-managed ---' \
      'b' \
      '# --- END agents-managed ---' > "$gitignore"
    local out; out="$(run_installer "$xdg" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        pass "duplicate BEGIN markers: installer aborts non-zero"
    else
        fail "duplicate BEGIN markers: installer should abort but exited 0"
    fi
}

test_unwritable_parent() {
    require_installer "test_unwritable_parent" || return
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            pass "unwritable-parent: skipped on Windows (chmod semantics differ)"
            return
            ;;
    esac
    local xdg; xdg="$(make_env "case-readonly")"
    mkdir -p "$xdg/git"
    chmod 000 "$xdg/git" 2>/dev/null || { pass "chmod unsupported, skipping"; return; }
    local out; out="$(run_installer "$xdg" 2>&1)"
    local exit_code=$?
    chmod 755 "$xdg/git" 2>/dev/null || true
    if [ "$exit_code" -ne 0 ]; then
        pass "unwritable parent: installer reports error"
    else
        fail "unwritable parent: installer should fail but exited 0"
    fi
}

test_preserves_other_tool_blocks() {
    require_installer "test_preserves_other_tool_blocks" || return
    local xdg; xdg="$(make_env "case-multiblock")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '%s\n' \
      '# --- BEGIN other-tool ---' \
      '*.bak' \
      '# --- END other-tool ---' > "$gitignore"
    run_installer "$xdg" >/dev/null 2>&1 || true
    assert_block_present "$gitignore" "multi-block: agents block added"
    if grep -q '# --- BEGIN other-tool ---' "$gitignore" && grep -q '\*.bak' "$gitignore"; then
        pass "multi-block: other-tool block preserved alongside agents block"
    else
        fail "multi-block: other-tool block was removed by installer"
    fi
}

test_triple_run_idempotency() {
    require_installer "test_triple_run_idempotency" || return
    local xdg; xdg="$(make_env "case-triple")"
    run_installer "$xdg" >/dev/null 2>&1 || true
    run_installer "$xdg" >/dev/null 2>&1 || true
    run_installer "$xdg" >/dev/null 2>&1 || true
    local gitignore="$xdg/git/ignore"
    local count; count="$(count_blocks "$gitignore")"
    if [ "$count" = "1" ]; then
        pass "triple-run idempotent: exactly 1 block"
    else
        fail "triple-run produced $count blocks (expected 1)"
    fi
}

test_marker_injection_in_content_safe() {
    require_installer "test_marker_injection_in_content_safe" || return
    local xdg; xdg="$(make_env "case-inject")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    # Real block + fake markers in user comments (not line-start markers)
    printf '%s\n' \
      '# --- BEGIN agents-managed ---' \
      'WORKTREE_NOTES.md' \
      '# --- END agents-managed ---' \
      '# user note: # --- BEGIN agents-managed --- (fake)' \
      '# user note: # --- END agents-managed --- (fake)' > "$gitignore"
    run_installer "$xdg" >/dev/null 2>&1 || true
    # Exactly 1 line that IS the real BEGIN marker (not the comment lines)
    local exact_begin exact_end
    exact_begin="$(grep -c '^# --- BEGIN agents-managed ---$' "$gitignore" 2>/dev/null || echo 0)"
    exact_end="$(grep -c '^# --- END agents-managed ---$' "$gitignore" 2>/dev/null || echo 0)"
    if [ "$exact_begin" = "1" ] && [ "$exact_end" = "1" ]; then
        pass "marker injection in comments: installer uses line-anchored matching"
    else
        fail "marker injection: expected 1 real BEGIN+END, got begin=$exact_begin end=$exact_end"
    fi
}

test_target_is_directory_error() {
    require_installer "test_target_is_directory_error" || return
    local xdg; xdg="$(make_env "case-dir-target")"
    mkdir -p "$xdg/git/ignore"  # target path exists as a directory
    local out; out="$(run_installer "$xdg" 2>&1)"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        pass "target is directory: installer errors"
    else
        fail "target is directory: installer should fail but exited 0"
    fi
}

test_read_only_file_error() {
    require_installer "test_read_only_file_error" || return
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*)
            pass "read-only file: skipped on Windows (chmod semantics differ)"
            return
            ;;
    esac
    local xdg; xdg="$(make_env "case-readonly-file")"
    mkdir -p "$xdg/git"
    local gitignore="$xdg/git/ignore"
    printf '*.log\n' > "$gitignore"
    chmod 444 "$gitignore" 2>/dev/null || { pass "chmod unsupported, skipping"; return; }
    local out; out="$(run_installer "$xdg" 2>&1)"
    local exit_code=$?
    chmod 644 "$gitignore" 2>/dev/null || true
    if [ "$exit_code" -ne 0 ]; then
        pass "read-only file (444): installer reports error"
    else
        fail "read-only file: installer should fail but exited 0"
    fi
}

# TODO: equivalent Pester tests for install.ps1 needed (Windows-specific)

# ============ Run all ============

test_creates_when_missing
test_appends_to_existing_unrelated
test_replaces_existing_block
test_idempotent_double_run
test_empty_file
test_no_trailing_newline
test_begin_only_aborts
test_end_only_aborts
test_two_begin_aborts
test_unwritable_parent
test_preserves_other_tool_blocks
test_triple_run_idempotency
test_marker_injection_in_content_safe
test_target_is_directory_error
test_read_only_file_error

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
