#!/bin/bash
# Tests: hooks/preuse-auto-approve.js
# Tags: scope:issue-specific
#
# PreToolUse hook (matcher: Monitor|EnterWorktree) that auto-approves
# low-risk tool calls: Monitor always, EnterWorktree only when the target
# path resolves inside WORKTREE_BASE_DIR.
#
# TL3 gap (what this test does NOT catch):
# - Does not verify the hook fires in a live CC session when Monitor/EnterWorktree is called
# - Does not verify permissionDecision is honored by the CC runtime
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SRC="$AGENTS_DIR/hooks/preuse-auto-approve.js"

PASS=0; FAIL=0; SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$HOOK_SRC" ]; then
    fail "all cases (hooks/preuse-auto-approve.js not implemented yet)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# make_fixture writes a fixture .env into a fresh subdir and echoes its path.
# Args are raw lines to write into the .env file.
make_fixture() {
    local dir
    dir="$(mktemp -d "$WORK_DIR/fixture.XXXXXX")"
    : > "$dir/.env"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$dir/.env"
    done
    printf '%s' "$dir"
}

# run_hook <config_dir> <stdin_json>
# Runs the hook from the repo root with AGENTS_CONFIG_DIR pointed at
# <config_dir>, feeding <stdin_json> on stdin. Sets globals OUT and RC.
#
# C3: uses `env -i` to run with a CLEAN environment (PATH/HOME/AGENTS_CONFIG_DIR
# only) so an AUTO_APPROVE_TOOLS or WORKTREE_BASE_DIR value inherited from the
# real shell environment cannot flip the verdict — every config-dependent
# value must come from the fixture .env file, not from ambient env.
run_hook() {
    local config_dir="$1" stdin_json="$2"
    OUT="$(cd "$AGENTS_DIR" && printf '%s' "$stdin_json" | run_with_timeout 10 env -i PATH="$PATH" HOME="$HOME" AGENTS_CONFIG_DIR="$config_dir" node hooks/preuse-auto-approve.js 2>/dev/null)"
    RC=$?
}

BASE_DIR="C:/git/worktrees"

# Expected JSON payloads emitted by hooks/preuse-auto-approve.js.
# allow() emits the full PreToolUse hookSpecificOutput envelope; passThrough()
# emits a bare "{}" (still valid JSON, distinct from "no output").
MONITOR_ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Monitor auto-approved: low-risk background monitoring"}}'
ENTERWORKTREE_ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"EnterWorktree auto-approved: path is within WORKTREE_BASE_DIR"}}'
PASSTHROUGH_OUT='{}'

# is_allow returns success when the given output is an allow decision
# (any reason text), used where the test only cares about allow-vs-not.
is_allow() {
    case "$1" in
        *'"permissionDecision":"allow"'*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- Case 1: Monitor, AUTO_APPROVE_TOOLS unset -> allow ---------------------
run_case1() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"Monitor","tool_input":{"command":"echo hi"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$MONITOR_ALLOW" ]; then
        pass "1: Monitor, AUTO_APPROVE_TOOLS unset -> allow"
    else
        fail "1: Monitor, AUTO_APPROVE_TOOLS unset -> allow (rc=$RC out=$OUT)"
    fi
}

# --- Case 2: Monitor, AUTO_APPROVE_TOOLS=on -> allow -------------------------
run_case2() {
    local cfg
    cfg="$(make_fixture "AUTO_APPROVE_TOOLS=on" "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"Monitor","tool_input":{"command":"echo hi"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$MONITOR_ALLOW" ]; then
        pass "2: Monitor, AUTO_APPROVE_TOOLS=on -> allow"
    else
        fail "2: Monitor, AUTO_APPROVE_TOOLS=on -> allow (rc=$RC out=$OUT)"
    fi
}

# --- Case 3: EnterWorktree inside WORKTREE_BASE_DIR -> allow -----------------
run_case3() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":"C:/git/worktrees/task/agents"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$ENTERWORKTREE_ALLOW" ]; then
        pass "3: EnterWorktree inside WORKTREE_BASE_DIR -> allow"
    else
        fail "3: EnterWorktree inside WORKTREE_BASE_DIR -> allow (rc=$RC out=$OUT)"
    fi
}

# --- Case 4: AUTO_APPROVE_TOOLS=off + Monitor -> pass-through, exit 0 -------
run_case4() {
    local cfg
    cfg="$(make_fixture "AUTO_APPROVE_TOOLS=off" "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"Monitor","tool_input":{"command":"echo hi"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "4: AUTO_APPROVE_TOOLS=off + Monitor -> pass-through, exit 0"
    else
        fail "4: AUTO_APPROVE_TOOLS=off + Monitor -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 5: AUTO_APPROVE_TOOLS=off + EnterWorktree -> pass-through, exit 0 -
run_case5() {
    local cfg
    cfg="$(make_fixture "AUTO_APPROVE_TOOLS=off" "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":"C:/git/worktrees/task/agents"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "5: AUTO_APPROVE_TOOLS=off + EnterWorktree -> pass-through, exit 0"
    else
        fail "5: AUTO_APPROVE_TOOLS=off + EnterWorktree -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 6: EnterWorktree outside WORKTREE_BASE_DIR -> pass-through, exit 0
run_case6() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":"C:/git/other/task/agents"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "6: EnterWorktree outside WORKTREE_BASE_DIR -> pass-through, exit 0"
    else
        fail "6: EnterWorktree outside WORKTREE_BASE_DIR -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 7: EnterWorktree, no path -> pass-through, exit 0 -----------------
run_case7() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{},"session_id":"s1"}'
    local rc1="$RC" out1="$OUT"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":""},"session_id":"s1"}'
    if [ "$rc1" = "0" ] && [ "$out1" = "$PASSTHROUGH_OUT" ] && [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "7: EnterWorktree, no path / empty path -> pass-through, exit 0"
    else
        fail "7: EnterWorktree, no path / empty path -> pass-through, exit 0 (rc1=$rc1 out1=$out1 rc2=$RC out2=$OUT)"
    fi
}

# --- Case 8: WORKTREE_BASE_DIR not set + EnterWorktree -> pass-through, exit 0
run_case8() {
    local cfg
    cfg="$(make_fixture "# no WORKTREE_BASE_DIR here")"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":"C:/git/worktrees/task/agents"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "8: WORKTREE_BASE_DIR not set + EnterWorktree -> pass-through, exit 0"
    else
        fail "8: WORKTREE_BASE_DIR not set + EnterWorktree -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 9: empty stdin -> pass-through, exit 0 -----------------------------
run_case9() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" ''
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "9: empty stdin -> pass-through, exit 0"
    else
        fail "9: empty stdin -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 10: malformed JSON stdin -> pass-through, exit 0 ------------------
run_case10() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{not valid json'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "10: malformed JSON stdin -> pass-through, exit 0"
    else
        fail "10: malformed JSON stdin -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 11: path traversal must NOT produce allow output ------------------
run_case11() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    # Attempts to forge a prefix match: base + "/../../etc/passwd" collapses
    # (via .. resolution) to a path no longer under WORKTREE_BASE_DIR.
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":"C:/git/worktrees/../../etc/passwd"},"session_id":"s1"}'
    local rc1="$RC" out1="$OUT"
    # Bare relative traversal, unrelated to WORKTREE_BASE_DIR entirely.
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":"../../etc"},"session_id":"s1"}'
    if ! is_allow "$out1" && ! is_allow "$OUT"; then
        pass "11: path traversal -> must NOT allow"
    else
        fail "11: path traversal -> must NOT allow (rc1=$rc1 out1=$out1 rc2=$RC out2=$OUT)"
    fi
}

# --- Case 12: tool_name=Bash (unrelated tool) -> pass-through, exit 0 -------
run_case12() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "12: tool_name=Bash -> pass-through, exit 0"
    else
        fail "12: tool_name=Bash -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 13: tool_name=UnknownTool -> pass-through, exit 0 -----------------
run_case13() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"UnknownTool","tool_input":{"foo":"bar"},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "13: tool_name=UnknownTool -> pass-through, exit 0"
    else
        fail "13: tool_name=UnknownTool -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 14: EnterWorktree boundary matrix (table-driven) ------------------
# Each row: description|base_dir|candidate_path|expect ("allow"|"deny")
# Uses a JSON-escaped candidate_path (backslashes doubled for JSON string).
BOUNDARY_CASES=(
    "exact base match|C:/git/worktrees|C:/git/worktrees|allow"
    "descendant two levels deep|C:/git/worktrees|C:/git/worktrees/task/agents|allow"
    "sibling-prefix directory (not a real descendant)|C:/git/worktrees|C:/git/worktrees-other/task|deny"
    "mixed separators (backslash)|C:/git/worktrees|C:\\\\git\\\\worktrees\\\\task\\\\agents|allow"
    "case difference on drive letter|C:/git/worktrees|c:/git/worktrees/task/agents|allow"
    "trailing separator on base|C:/git/worktrees/|C:/git/worktrees/task/agents|allow"
    "trailing separator on candidate|C:/git/worktrees|C:/git/worktrees/task/agents/|allow"
    ". segment in candidate path|C:/git/worktrees|C:/git/worktrees/./task/agents|allow"
    ".. traversal attempt|C:/git/worktrees|C:/git/worktrees/task/../../etc|deny"
)

run_case14() {
    local idx=0 row desc base cand expect cfg json
    for row in "${BOUNDARY_CASES[@]}"; do
        idx=$((idx + 1))
        IFS='|' read -r desc base cand expect <<< "$row"
        cfg="$(make_fixture "WORKTREE_BASE_DIR=$base")"
        json="{\"tool_name\":\"EnterWorktree\",\"tool_input\":{\"path\":\"$cand\"},\"session_id\":\"s1\"}"
        run_hook "$cfg" "$json"
        if [ "$expect" = "allow" ]; then
            if [ "$RC" = "0" ] && [ "$OUT" = "$ENTERWORKTREE_ALLOW" ]; then
                pass "14.$idx: $desc -> allow"
            else
                fail "14.$idx: $desc -> allow (rc=$RC out=$OUT base=$base cand=$cand)"
            fi
        else
            if [ "$RC" = "0" ] && ! is_allow "$OUT"; then
                pass "14.$idx: $desc -> NOT allow"
            else
                fail "14.$idx: $desc -> NOT allow (rc=$RC out=$OUT base=$base cand=$cand)"
            fi
        fi
    done
}

# --- Case 15: non-string path (JSON number) -> pass-through, exit 0 ---------
run_case15() {
    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$BASE_DIR")"
    run_hook "$cfg" '{"tool_name":"EnterWorktree","tool_input":{"path":12345},"session_id":"s1"}'
    if [ "$RC" = "0" ] && [ "$OUT" = "$PASSTHROUGH_OUT" ]; then
        pass "15: EnterWorktree, non-string path -> pass-through, exit 0"
    else
        fail "15: EnterWorktree, non-string path -> pass-through, exit 0 (rc=$RC out=$OUT)"
    fi
}

# --- Case 16: symlink inside WORKTREE_BASE_DIR pointing outside -------------
# C6: creates a real symlink under the base dir that resolves outside it.
# The implementation resolves symlinks via fs.realpathSync before the
# boundary check (see hooks/preuse-auto-approve.js), so a symlink cannot be
# used to bypass WORKTREE_BASE_DIR containment: the resolved target lives
# outside the base, so this asserts NOT allow.
# Skipped on Windows when symlink creation requires elevated privilege
# (Developer Mode / admin) — detected via a live symlink probe.
run_case16() {
    local base_real outside_real link_path
    base_real="$(mktemp -d "$WORK_DIR/base.XXXXXX")"
    outside_real="$(mktemp -d "$WORK_DIR/outside.XXXXXX")"
    link_path="$base_real/symlink"

    # Normalize to a Windows-recognizable path form so Node (which sees
    # native Windows paths, not the MSYS/Git-Bash /tmp/... view) resolves
    # WORKTREE_BASE_DIR and the symlink target consistently.
    if command -v cygpath >/dev/null 2>&1; then
        base_real="$(cygpath -m "$base_real")"
        outside_real="$(cygpath -m "$outside_real")"
        link_path="$(cygpath -m "$link_path")"
    fi

    # Probe: can we create symlinks at all in this environment?
    if ! node -e '
        const fs = require("fs");
        try { fs.symlinkSync(process.argv[2], process.argv[1], "dir"); }
        catch (e) { process.exit(1); }
    ' "$link_path" "$outside_real" 2>/dev/null; then
        skip "16: symlink inside WORKTREE_BASE_DIR pointing outside (symlink creation unsupported/unprivileged on this host)"
        return
    fi

    local cfg
    cfg="$(make_fixture "WORKTREE_BASE_DIR=$base_real")"
    local json
    json="{\"tool_name\":\"EnterWorktree\",\"tool_input\":{\"path\":\"$link_path\"},\"session_id\":\"s1\"}"
    run_hook "$cfg" "$json"
    if [ "$RC" = "0" ] && ! is_allow "$OUT"; then
        pass "16: symlink inside WORKTREE_BASE_DIR pointing outside -> NOT allow (symlinks resolved)"
    else
        fail "16: symlink inside WORKTREE_BASE_DIR pointing outside -> NOT allow (rc=$RC out=$OUT)"
    fi
}

run_case1
run_case2
run_case3
run_case4
run_case5
run_case6
run_case7
run_case8
run_case9
run_case10
run_case11
run_case12
run_case13
run_case14
run_case15
run_case16

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
