#!/bin/bash
# tests/fix-1483-issue-create-allowlist.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, security, scope:issue-specific
#
# SKIPPED: Real hook firing inside a live Claude Code session
# Because: Requires a live claude -p session with ENFORCE_WORKTREE=on; not achievable at L2
# L3 gap: Live session test would verify the hook actually intercepts the Bash tool call
#
# Fix #1483: three new scripts added to the SANCTIONED allowlist in worker-script.js:
#   - bin/github-issues/issue-create-dispatch.sh
#   - skills/issue-create/scripts/run-bulk-dispatch.sh
#   - skills/issue-create/scripts/run-phase5-record.sh
#
# Drive surface (full hook):
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && AGENTS_CONFIG_DIR=<fake-acd> node hooks/enforce-worktree.js)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

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

# Tempdir base, cleaned up at exit. Node gives a POSIX-style path on Windows.
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1483-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Existence gate.
if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_bash_payload() {
    local cmd="$1"
    local q; q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

# Run the guard with cwd set to <main-worktree>.
# Returns: 0 = ALLOW, 1 = BLOCK, 2 = CRASH.
GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1"; shift
    local main_wt="$1"; shift
    # Remaining args are extra env vars (KEY=VAL form), e.g. AGENTS_CONFIG_DIR=...
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        -C "$main_wt" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        return 2
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# `env -C` is a GNU coreutils extension (>=8.28). Fallback: subshell `cd` + env.
if ! env -C "$TMPDIR_BASE" true 2>/dev/null; then
    run_guard() {
        local payload="$1"; shift
        local main_wt="$1"; shift
        GUARD_RC=0
        GUARD_OUT="$(cd "$main_wt" && printf '%s' "$payload" | run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE \
            "ENFORCE_WORKTREE=on" \
            "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
            "$@" \
            node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
        if [ "$GUARD_RC" -ne 0 ]; then
            return 2
        fi
        if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
            return 1
        fi
        return 0
    }
fi

assert_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; out: $GUARD_OUT)" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

# ----------------------------------------------------------------------------
# Fixture builders
# ----------------------------------------------------------------------------

# Initialize a minimal main worktree. Echoes cygpath-normalized path.
setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    mkdir -p "$repo/docs/history"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Add a linked worktree under <main-worktree>/.wt/<name>. Echoes its path.
add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt_path"
    else
        echo "$wt_path"
    fi
}

# Create a fake AGENTS_CONFIG_DIR with the pre-existing sanctioned worker scripts
# (from fix-959) plus the three new scripts added by fix-1483. Echoes the
# cygpath-normalized path.
setup_fake_acd_1483() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-1483-$name"
    mkdir -p "$d/bin/github-issues"
    mkdir -p "$d/skills/issue-create/scripts"
    # Pre-existing sanctioned scripts (fix-959 baseline)
    touch "$d/bin/check-unstaged-tracked.sh"
    touch "$d/bin/probe-remote-bootstrap.sh"
    touch "$d/bin/issue-close-gate.sh"
    touch "$d/bin/github-issues/issue-close-stage-triage.sh"
    touch "$d/bin/github-issues/parent-body-update.sh"
    # New scripts added by fix-1483
    touch "$d/bin/github-issues/issue-create-dispatch.sh"
    touch "$d/skills/issue-create/scripts/run-bulk-dispatch.sh"
    touch "$d/skills/issue-create/scripts/run-phase5-record.sh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# ============================================================================
# F1483 series — new SANCTIONED entries in worker-script.js
#
# Setup contract: every case registers BOTH the main worktree and the linked
# worktree (ENFORCE_WORKTREE_ADDITIONAL_REPOS="$repo;$linked"), matching the
# fix-959 pattern. This reproduces the condition where the hook sees a write
# target inside the linked worktree and must decide whether to allow or block.
# ============================================================================

# Case 1 — ALLOW: issue-create-dispatch.sh called from main worktree, no redirect.
# No write targets → ALLOW unconditionally (targets===null path).
test_F1483_1_allow_issue_create_dispatch_no_redirect() {
    local repo; repo="$(setup_main_worktree "f1483-1")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw1" "feature/f1483-lw1")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "1")"
    local cmd; cmd="bash \"$fake_acd/bin/github-issues/issue-create-dispatch.sh\" \"$repo\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_allow "F1483-1: issue-create-dispatch.sh + no redirect → ALLOW" "$rc"
}

# Case 2 — ALLOW: run-bulk-dispatch.sh called from main worktree, no redirect.
test_F1483_2_allow_run_bulk_dispatch_no_redirect() {
    local repo; repo="$(setup_main_worktree "f1483-2")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw2" "feature/f1483-lw2")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "2")"
    local cmd; cmd="bash \"$fake_acd/skills/issue-create/scripts/run-bulk-dispatch.sh\" \"$repo\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_allow "F1483-2: run-bulk-dispatch.sh + no redirect → ALLOW" "$rc"
}

# Case 3 — ALLOW: run-phase5-record.sh called from main worktree, no redirect.
test_F1483_3_allow_run_phase5_record_no_redirect() {
    local repo; repo="$(setup_main_worktree "f1483-3")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw3" "feature/f1483-lw3")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "3")"
    local cmd; cmd="bash \"$fake_acd/skills/issue-create/scripts/run-phase5-record.sh\" \"$repo\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_allow "F1483-3: run-phase5-record.sh + no redirect → ALLOW" "$rc"
}

# Case 4 — ALLOW: issue-create-dispatch.sh with log redirect to linked worktree.
# Write target lands in a registered linked worktree → ALLOW.
test_F1483_4_allow_issue_create_dispatch_linked_log() {
    local repo; repo="$(setup_main_worktree "f1483-4")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw4" "feature/f1483-lw4")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "4")"
    mkdir -p "$linked/artifacts"
    local log_path="$linked/artifacts/dispatch.log"
    local cmd; cmd="bash \"$fake_acd/bin/github-issues/issue-create-dispatch.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_allow "F1483-4: issue-create-dispatch.sh + linked-wt log → ALLOW" "$rc"
}

# Case 5 — BLOCK: issue-create-dispatch.sh with log redirect to main worktree.
# Write target is inside the main worktree → BLOCK (fail-closed).
test_F1483_5_block_issue_create_dispatch_main_log() {
    local repo; repo="$(setup_main_worktree "f1483-5")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw5" "feature/f1483-lw5")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "5")"
    local log_path="$repo/bad-dispatch.log"
    local cmd; cmd="bash \"$fake_acd/bin/github-issues/issue-create-dispatch.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_block "F1483-5: issue-create-dispatch.sh + main-wt log → BLOCK (fail-closed)" "$rc"
}

# Case 7 — BLOCK: run-bulk-dispatch.sh with log redirect to main worktree.
# Write target is inside the main worktree → BLOCK (fail-closed). Symmetric to F1483-5.
test_F1483_7_block_run_bulk_dispatch_main_log() {
    local repo; repo="$(setup_main_worktree "f1483-7")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw7" "feature/f1483-lw7")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "7")"
    local log_path="$repo/bad-bulk.log"
    local cmd; cmd="bash \"$fake_acd/skills/issue-create/scripts/run-bulk-dispatch.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_block "F1483-7: run-bulk-dispatch.sh + main-wt log → BLOCK (fail-closed)" "$rc"
}

# Case 8 — BLOCK: run-phase5-record.sh with log redirect to main worktree.
# Write target is inside the main worktree → BLOCK (fail-closed). Symmetric to F1483-5.
test_F1483_8_block_run_phase5_record_main_log() {
    local repo; repo="$(setup_main_worktree "f1483-8")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw8" "feature/f1483-lw8")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "8")"
    local log_path="$repo/bad-phase5.log"
    local cmd; cmd="bash \"$fake_acd/skills/issue-create/scripts/run-phase5-record.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_block "F1483-8: run-phase5-record.sh + main-wt log → BLOCK (fail-closed)" "$rc"
}

# Case 6 — BLOCK: non-SANCTIONED script (issue-create.sh) called from main worktree.
# issue-create.sh is not in the SANCTIONED list → identity gate rejects → BLOCK.
test_F1483_6_block_non_sanctioned_issue_create() {
    local repo; repo="$(setup_main_worktree "f1483-6")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lw6" "feature/f1483-lw6")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "6")"
    mkdir -p "$fake_acd/bin/github-issues"
    touch "$fake_acd/bin/github-issues/issue-create.sh"  # not in SANCTIONED list
    mkdir -p "$linked/artifacts"
    local log_path="$linked/artifacts/test.log"
    local cmd; cmd="bash \"$fake_acd/bin/github-issues/issue-create.sh\" \"$repo\" &> \"$log_path\""
    local payload; payload="$(build_bash_payload "$cmd")"
    local rc=0
    run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
    assert_block "F1483-6: non-SANCTIONED issue-create.sh → BLOCK (identity gate rejects)" "$rc"
}

# Table-driven: all 8 SANCTIONED entries → ALLOW (no redirect, no write targets).
# Uses a single main worktree + linked worktree + fake_acd to cover every entry.
test_F1483_table_sanctioned_allow() {
    local repo; repo="$(setup_main_worktree "f1483-tbl")"
    local linked; linked="$(add_linked_worktree "$repo" "f1483-lwtbl" "feature/f1483-lwtbl")"
    local fake_acd; fake_acd="$(setup_fake_acd_1483 "tbl")"

    local scripts=(
        "bin/check-unstaged-tracked.sh"
        "bin/probe-remote-bootstrap.sh"
        "bin/issue-close-gate.sh"
        "bin/github-issues/issue-close-stage-triage.sh"
        "bin/github-issues/parent-body-update.sh"
        "bin/github-issues/issue-create-dispatch.sh"
        "skills/issue-create/scripts/run-bulk-dispatch.sh"
        "skills/issue-create/scripts/run-phase5-record.sh"
    )

    local script
    for script in "${scripts[@]}"; do
        local cmd; cmd="bash \"$fake_acd/$script\" \"$repo\""
        local payload; payload="$(build_bash_payload "$cmd")"
        local rc=0
        run_guard "$payload" "$repo" "AGENTS_CONFIG_DIR=$fake_acd" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$repo;$linked" || rc=$?
        assert_allow "F1483-table: $script → ALLOW" "$rc"
    done
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    test_F1483_1_allow_issue_create_dispatch_no_redirect
    test_F1483_2_allow_run_bulk_dispatch_no_redirect
    test_F1483_3_allow_run_phase5_record_no_redirect
    test_F1483_4_allow_issue_create_dispatch_linked_log
    test_F1483_5_block_issue_create_dispatch_main_log
    test_F1483_6_block_non_sanctioned_issue_create
    test_F1483_7_block_run_bulk_dispatch_main_log
    test_F1483_8_block_run_phase5_record_main_log
    test_F1483_table_sanctioned_allow
}

# 180s outer timeout so a stuck git op cannot wedge the suite.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1483_TEST_INNER:-}" ]; then
        _FIX1483_TEST_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
