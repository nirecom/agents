#!/bin/bash
# tests/feature-workflow-off-bypass-pre-commit.sh
#
# End-to-end test for hooks/pre-commit session-marker bypass (issue #550).
#
# TDD note: tests B and C will FAIL until pre-commit honors the session markers
# (.workflow-off / .worktree-off) via session-markers.js.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'eprecommitbypass-'+process.pid).replace(/\\\\/g,'/');
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
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# Create a synthetic main worktree (no linked) → git-common-dir == git-dir
setup_main_repo() {
    local name="$1"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    echo "init" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
    echo "change" > "$dir/README.md"
    git -C "$dir" add README.md
    echo "$dir"
}

# Write CLAUDE_ENV_FILE with CLAUDE_SESSION_ID=<sid>
write_env_file() {
    local sid="$1"
    local f="$TMPDIR_BASE/envfile-$RANDOM-$$"
    printf 'CLAUDE_SESSION_ID=%s\n' "$sid" > "$f"
    echo "$f"
}

# Run pre-commit hook from within the repo.
run_precommit() {
    local repo="$1"; shift
    (cd "$repo" && run_with_timeout 30 env "$@" bash "$AGENTS_DIR/hooks/pre-commit") 2>&1
}

# ----------------------------------------------------------------------------
test_A_baseline_blocks_main_worktree() {
    local repo; repo="$(setup_main_repo "repoA")"
    local out rc=0
    out="$(run_precommit "$repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on")" || rc=$?
    if [ "$rc" -ne 0 ] && echo "$out" | grep -q "commits from main worktree are blocked"; then
        pass "A: baseline — pre-commit blocks commits from main worktree"
    else
        fail "A: expected block with main-worktree message; rc=$rc out=$out"
    fi
}

test_B_workflow_off_marker_bypasses() {
    local repo; repo="$(setup_main_repo "repoB")"
    local sid="testsessB001"
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local envfile; envfile="$(write_env_file "$sid")"
    printf '{"set_at":"x"}' > "$wfdir/$sid.workflow-off"
    local out rc=0
    out="$(run_precommit "$repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile")" || rc=$?
    if [ "$rc" = "0" ]; then
        pass "B: .workflow-off marker → pre-commit bypassed"
    else
        fail "B: expected exit 0, got rc=$rc (bypass not implemented?); out=$out"
    fi
}

test_C_worktree_off_marker_bypasses() {
    local repo; repo="$(setup_main_repo "repoC")"
    local sid="testsessC001"
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local envfile; envfile="$(write_env_file "$sid")"
    printf '{"set_at":"x"}' > "$wfdir/$sid.worktree-off"
    local out rc=0
    out="$(run_precommit "$repo" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile")" || rc=$?
    if [ "$rc" = "0" ]; then
        pass "C: .worktree-off marker → pre-commit bypassed"
    else
        fail "C: expected exit 0, got rc=$rc (bypass not implemented?); out=$out"
    fi
}

test_D_no_markers_no_session_id_blocks_gracefully() {
    local repo; repo="$(setup_main_repo "repoD")"
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local empty_transcript="$TMPDIR_BASE/empty-transcript-$RANDOM"
    mkdir -p "$empty_transcript"
    local out rc=0
    # Selectively unset CLAUDE_ENV_FILE and CLAUDE_SESSION_ID; keep AGENTS_CONFIG_DIR
    out="$(cd "$repo" && run_with_timeout 30 env \
        -u CLAUDE_ENV_FILE \
        -u CLAUDE_SESSION_ID \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_TRANSCRIPT_BASE_DIR=$empty_transcript" \
        bash "$AGENTS_DIR/hooks/pre-commit" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ] && echo "$out" | grep -q "commits from main worktree are blocked"; then
        pass "D: no markers + no session id → graceful block (no crash)"
    else
        fail "D: expected graceful block; rc=$rc out=$out"
    fi
}

test_E_no_node_falls_through_to_enforcement() {
    if command -v cygpath >/dev/null 2>&1; then
        skip "E: Cygwin PATH manipulation unreliable — skipped"
        return
    fi
    local repo; repo="$(setup_main_repo "repoE")"
    local sid="testsessE001"
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local envfile; envfile="$(write_env_file "$sid")"
    printf '{"set_at":"x"}' > "$wfdir/$sid.workflow-off"
    local out rc=0
    # Strip PATH so node is not findable; bash builtins still work
    out="$(cd "$repo" && run_with_timeout 30 env \
        "PATH=/nonexistent" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        bash "$AGENTS_DIR/hooks/pre-commit" 2>&1)" || rc=$?
    # Without node, marker check (which requires node) cannot succeed → falls through to enforcement → exit 1.
    if [ "$rc" -ne 0 ]; then
        pass "E: node unavailable → bypass attempt fails gracefully, enforcement runs"
    else
        fail "E: expected non-zero (enforcement); got rc=$rc out=$out"
    fi
}

test_F_bad_agents_config_dir_falls_through() {
    local repo; repo="$(setup_main_repo "repoF")"
    local sid="testsessF001"
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local envfile; envfile="$(write_env_file "$sid")"
    printf '{"set_at":"x"}' > "$wfdir/$sid.workflow-off"
    local out rc=0
    # Bad AGENTS_CONFIG_DIR for the marker-check; the script itself still resolves via $0.
    out="$(cd "$repo" && run_with_timeout 30 env \
        "AGENTS_CONFIG_DIR=/nonexistent/path" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        bash "$AGENTS_DIR/hooks/pre-commit" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "F: bad AGENTS_CONFIG_DIR → graceful fall-through to enforcement"
    else
        fail "F: expected non-zero, got rc=$rc out=$out"
    fi
}

# G: enforce-worktree.js still emits its session-override notice with .worktree-off marker.
test_G_enforce_worktree_notice_regression() {
    local repo; repo="$(setup_main_repo "repoG")"
    local sid="testsessG001"
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local envfile; envfile="$(write_env_file "$sid")"
    printf '{"set_at":"x"}' > "$wfdir/$sid.worktree-off"

    local q_sid q_fp payload
    q_sid="$(json_quote "$sid")"
    q_fp="$(json_quote "$repo/foo.txt")"
    payload="$(printf '{"session_id":%s,"tool_name":"Write","tool_input":{"file_path":%s,"content":"test"}}' \
        "$q_sid" "$q_fp")"

    local out rc=0
    out="$(printf '%s' "$payload" | run_with_timeout 30 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "ENFORCE_WORKTREE=on" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "CLAUDE_ENV_FILE=$envfile" \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$repo" \
        node "$AGENTS_DIR/hooks/enforce-worktree.js" 2>&1)" || rc=$?

    local ok=1
    echo "$out" | grep -q "session override active" || ok=0
    echo "$out" | grep -q "$sid.worktree-off" || ok=0
    if [ "$ok" = "1" ]; then
        pass "G: enforce-worktree.js still emits session-override notice with marker path"
    else
        fail "G: expected 'session override active' + marker path; rc=$rc out=$out"
    fi
}

run_all() {
    test_A_baseline_blocks_main_worktree
    test_B_workflow_off_marker_bypasses
    test_C_worktree_off_marker_bypasses
    test_D_no_markers_no_session_id_blocks_gracefully
    test_E_no_node_falls_through_to_enforcement
    test_F_bad_agents_config_dir_falls_through
    test_G_enforce_worktree_notice_regression
}

# Outer timeout guard
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_PRECOMMIT_BYPASS_INNER:-}" ]; then
        _PRECOMMIT_BYPASS_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
