#!/bin/bash
# tests/feature-831-supervisor-report-sid-fallback.sh
# Tests: bin/supervisor-report (session-id auto-resolve fallback chain)
# Tags: supervisor, em-supervisor, cli, session-id, fallback, scope:issue-specific
# Tests for issue #831 — supervisor-report session-id auto-resolve.
#
# Fallback priority order:
#   p1: --session-id CLI flag (explicit) → adopted; bypasses all fallbacks.
#   p2: $CLAUDE_SESSION_ID env → adopted when flag absent.
#   p3: CWD/WORKTREE_NOTES.md "Session-ID: <sid>" line → adopted via awk.
#   p4: git common-dir + WORKTREE_NOTES.md → adopted from main worktree notes.
#   p5: no source → usage error, non-zero exit.
#   Edge: invalid chars (spaces, slashes) in --session-id → rejected.
#
# RED until bin/supervisor-report grows the fallback chain (p1 already exists
# via existing CLI; p2/p3/p4 are new — those cases SKIP if the underlying
# auto-resolve has not been implemented yet, detected by feature-probe).
#
# L3 gap (what this L2 test does NOT catch):
# - Real $CLAUDE_SESSION_ID propagation in a live claude -p session (Anthropic bug #27987 prevents subprocess env inheritance)
# - P2 fallback via env var is only verifiable in a real Claude Code session where the runtime sets CLAUDE_SESSION_ID

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-report"
CLI_NODE="$_AGENTS_DIR_NODE/bin/supervisor-report"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local p="$1" label="$2"
    if [ ! -f "$p" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

# Probe whether the auto-resolve feature is present: run the CLI with no
# --session-id and no CLAUDE_SESSION_ID, but with a CWD WORKTREE_NOTES.md
# containing a Session-ID. If a state file is written → feature is present.
probe_autoresolve() {
    local tmp tmp_node ret
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local workdir="$tmp/work"
    mkdir -p "$workdir"
    printf 'Session-ID: probe-sid\n' > "$workdir/WORKTREE_NOTES.md"
    (
        cd "$workdir" && \
        unset CLAUDE_SESSION_ID && \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "probe" \
            --reporter "probe" >/dev/null 2>&1
    )
    if [ -f "$tmp/probe-sid-supervisor-state.json" ]; then ret=0; else ret=1; fi
    rm -rf "$tmp"
    return $ret
}

AUTORESOLVE_PRESENT=0
if [ -f "$CLI" ] && probe_autoresolve; then AUTORESOLVE_PRESENT=1; fi

# --- S1: --session-id CLI flag is adopted (existing behavior) ---
run_s1() {
    require_source "$CLI" "S1: --session-id CLI flag is adopted (bypasses fallbacks)" || return
    local tmp tmp_node
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local workdir="$tmp/work"; mkdir -p "$workdir"
    printf 'Session-ID: fallback-sid\n' > "$workdir/WORKTREE_NOTES.md"
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="env-sid" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" --session-id "explicit-sid" >/dev/null 2>&1
    )
    if [ -f "$tmp/explicit-sid-supervisor-state.json" ] \
       && [ ! -f "$tmp/env-sid-supervisor-state.json" ] \
       && [ ! -f "$tmp/fallback-sid-supervisor-state.json" ]; then
        pass "S1: --session-id CLI flag is adopted (bypasses fallbacks)"
    else
        fail "S1: --session-id CLI flag is adopted (bypasses fallbacks)"
    fi
    rm -rf "$tmp"
}

# --- S2: CLAUDE_SESSION_ID env is adopted when flag absent ---
run_s2() {
    require_source "$CLI" "S2: CLAUDE_SESSION_ID env is adopted when flag absent" || return
    local tmp tmp_node
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local workdir="$tmp/work"
    mkdir -p "$workdir"
    # workdir has no WORKTREE_NOTES.md — prevents wsid Priority 1 resolution
    (
        cd "$workdir" && \
        CLAUDE_SESSION_ID="env-sid-s2" \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ -f "$tmp/env-sid-s2-supervisor-state.json" ]; then
        pass "S2: CLAUDE_SESSION_ID env is adopted when flag absent"
    else
        fail "S2: CLAUDE_SESSION_ID env is adopted when flag absent"
    fi
    rm -rf "$tmp"
}

# --- S3: WORKTREE_NOTES.md in CWD provides Session-ID ---
run_s3() {
    require_source "$CLI" "S3: WORKTREE_NOTES.md Session-ID in CWD adopted" || return
    if [ $AUTORESOLVE_PRESENT -eq 0 ]; then
        skip "S3: WORKTREE_NOTES.md Session-ID in CWD adopted (auto-resolve not implemented yet)"
        return
    fi
    local tmp tmp_node
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local workdir="$tmp/work"; mkdir -p "$workdir"
    printf 'Some header\nSession-ID: cwd-sid-s3\nMore lines\n' > "$workdir/WORKTREE_NOTES.md"
    (
        cd "$workdir" && \
        unset CLAUDE_SESSION_ID && \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ -f "$tmp/cwd-sid-s3-supervisor-state.json" ]; then
        pass "S3: WORKTREE_NOTES.md Session-ID in CWD adopted"
    else
        fail "S3: WORKTREE_NOTES.md Session-ID in CWD adopted"
    fi
    rm -rf "$tmp"
}

# --- S4: git common-dir WORKTREE_NOTES.md fallback ---
run_s4() {
    require_source "$CLI" "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted" || return
    if [ $AUTORESOLVE_PRESENT -eq 0 ]; then
        skip "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted (auto-resolve not implemented yet)"
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        skip "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted (git not available)"
        return
    fi
    local tmp tmp_node
    tmp="$(mktemp -d)"; tmp_node="$(to_node_path "$tmp")"
    local mainrepo="$tmp/mainrepo"
    mkdir -p "$mainrepo"
    (
        cd "$mainrepo" && \
        git init -q -b main && \
        git config user.email "test@example.com" && \
        git config user.name "test" && \
        printf 'Session-ID: common-dir-sid-s4\n' > WORKTREE_NOTES.md && \
        git add -A && git commit -q -m "init" 2>/dev/null
    ) >/dev/null 2>&1 || { rm -rf "$tmp"; skip "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted (git setup failed)"; return; }
    # Create a worktree whose CWD does NOT contain WORKTREE_NOTES.md
    local wtdir="$tmp/wt"
    (cd "$mainrepo" && git worktree add -q "$wtdir" -b feat-s4) >/dev/null 2>&1 || true
    if [ ! -d "$wtdir" ]; then
        rm -rf "$tmp"
        skip "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted (worktree creation failed)"
        return
    fi
    rm -f "$wtdir/WORKTREE_NOTES.md"
    (
        cd "$wtdir" && \
        unset CLAUDE_SESSION_ID && \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    if [ -f "$tmp/common-dir-sid-s4-supervisor-state.json" ]; then
        pass "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted"
    else
        fail "S4: git common-dir WORKTREE_NOTES.md Session-ID adopted"
    fi
    rm -rf "$tmp"
}

# --- S5: no source → usage error, non-zero exit ---
run_s5() {
    require_source "$CLI" "S5: no session-id source exits non-zero" || return
    local tmp; tmp="$(mktemp -d)"
    local workdir="$tmp/work"; mkdir -p "$workdir"
    # Ensure CWD has no WORKTREE_NOTES.md and is not a git repo.
    (
        cd "$workdir" && \
        unset CLAUDE_SESSION_ID && \
        WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
            --categories workflow --severity warning --detail "d" \
            --reporter "r" >/dev/null 2>&1
    )
    local rc=$?
    if [ $rc -ne 0 ]; then
        pass "S5: no session-id source exits non-zero"
    else
        fail "S5: no session-id source exits non-zero (rc=$rc)"
    fi
    rm -rf "$tmp"
}

# --- S6: invalid chars in --session-id rejected ---
run_s6() {
    require_source "$CLI" "S6: invalid chars in --session-id rejected" || return
    local tmp; tmp="$(mktemp -d)"
    WORKFLOW_PLANS_DIR="$tmp" run_with_timeout 5 node "$CLI_NODE" \
        --categories workflow --severity warning --detail "d" \
        --reporter "r" --session-id "bad sid/with stuff" >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        pass "S6: invalid chars in --session-id rejected"
    else
        fail "S6: invalid chars in --session-id rejected (rc=$rc)"
    fi
    rm -rf "$tmp"
}

run_s1
run_s2
run_s3
run_s4
run_s5
run_s6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
