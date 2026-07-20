#!/bin/bash
# Tests: resolveRepoCwd linked-worktree input.cwd priority (Approach B guard)
# Tags: scope:issue-specific unit path-normalize
#
# Unit tests (L1) for the NEW resolveRepoCwd guard in hooks/lib/path-normalize.js.
#
# The guard (Approach B): when the command carries no `-C` flag AND input.cwd is
# present AND normalizeCwd(input.cwd) !== normalizeCwd(CLAUDE_PROJECT_DIR),
# resolveRepoCwd returns normalizeCwd(input.cwd). This makes a PostToolUse hook
# operate on the linked worktree the tool actually ran in, not on the main
# worktree that CLAUDE_PROJECT_DIR points at. Without the guard, evidence checks
# (staged tests, HEAD) run against the wrong repo (#1521).
#
# L3 gap (what this test does NOT catch):
# - Whether Claude Code actually populates stdin `cwd` with the linked worktree
#   path during a real PostToolUse hook invocation. Only a live `claude -p`
#   session (RUN_TL3) exercises the real stdin cwd wiring end-to-end. This unit
#   test asserts the resolution logic given controlled inputs, not the wiring.
#
# Pre-implementation expectation: C1 FAILS until the guard is added (existing
# behavior returns CLAUDE_PROJECT_DIR). C2-C5 pass on current code (unchanged
# behavior). C6 is Windows-only.

set -u

# Disable Git Bash (MSYS2) POSIX->Windows path conversion for argv. Without this,
# Unix-style test inputs like /main/repo are rewritten to C:/Program Files/Git/...
# when handed to the native node.exe, corrupting the fixtures.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# AGENTS_DIR must be a native (Windows) path so node.exe can require modules from
# it once MSYS argv conversion is disabled. `pwd -W` yields the Windows form on
# Git Bash; on POSIX it is unsupported, so fall back to plain `pwd`.
AGENTS_DIR="$(cd "$(dirname "$0")/.." && { pwd -W 2>/dev/null || pwd; })"
PATH_NORMALIZE="$AGENTS_DIR/hooks/lib/path-normalize.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@"
    fi
}

# Invoke resolveRepoCwd with controlled inputs.
# Args: <command> <input_cwd> <state_cwd>   (empty string = omit that field)
# CLAUDE_PROJECT_DIR is passed via the environment by the caller.
call_resolve() {
    local command="$1" input_cwd="$2" state_cwd="$3"
    run_with_timeout 10 node -e "
        try {
            const { resolveRepoCwd } = require(process.argv[1]);
            const command = process.argv[2] || '';
            const inputCwd = process.argv[3];
            const stateCwd = process.argv[4];
            const args = { command };
            if (inputCwd) args.input = { cwd: inputCwd };
            if (stateCwd) args.stateCwd = stateCwd;
            process.stdout.write(String(resolveRepoCwd(args)));
        } catch (e) {
            process.stdout.write('ERROR:' + e.message);
        }
    " "$PATH_NORMALIZE" "$command" "$input_cwd" "$state_cwd" 2>/dev/null
}

# --- Pre-implementation file gate ---
if [ ! -f "$PATH_NORMALIZE" ]; then
    echo "INFO: path-normalize.js not found — tests will FAIL by design"
fi

MAIN="/main/repo"
WT="/worktree/repo"

# ---------------------------------------------------------------------------
# C1: CLAUDE_PROJECT_DIR=/main/repo, input.cwd=/worktree/repo, no -C
#     → returns input.cwd (NEW guard — FAILS before fix, returns MAIN today)
# ---------------------------------------------------------------------------
RES_C1="$(CLAUDE_PROJECT_DIR="$MAIN" call_resolve "git status" "$WT" "")"
if [ "$RES_C1" = "$WT" ]; then
    pass "C1. input.cwd differs from CLAUDE_PROJECT_DIR + no -C → returns input.cwd"
else
    fail "C1. expected $WT (linked-worktree guard), got: $RES_C1"
fi

# ---------------------------------------------------------------------------
# C2: CLAUDE_PROJECT_DIR same as input.cwd → returns CLAUDE_PROJECT_DIR
#     (guard does not fire; existing behavior unchanged)
# ---------------------------------------------------------------------------
RES_C2="$(CLAUDE_PROJECT_DIR="$MAIN" call_resolve "git status" "$MAIN" "")"
if [ "$RES_C2" = "$MAIN" ]; then
    pass "C2. input.cwd == CLAUDE_PROJECT_DIR → returns CLAUDE_PROJECT_DIR"
else
    fail "C2. expected $MAIN, got: $RES_C2"
fi

# ---------------------------------------------------------------------------
# C3: input.cwd absent → returns CLAUDE_PROJECT_DIR (existing behavior)
# ---------------------------------------------------------------------------
RES_C3="$(CLAUDE_PROJECT_DIR="$MAIN" call_resolve "git status" "" "")"
if [ "$RES_C3" = "$MAIN" ]; then
    pass "C3. input.cwd absent → returns CLAUDE_PROJECT_DIR"
else
    fail "C3. expected $MAIN, got: $RES_C3"
fi

# ---------------------------------------------------------------------------
# C4: command has `git -C /explicit/path` → -C path takes priority over
#     input.cwd (regression guard — -C must always win)
# ---------------------------------------------------------------------------
EXPLICIT="/explicit/path"
RES_C4="$(CLAUDE_PROJECT_DIR="$MAIN" call_resolve "git -C $EXPLICIT status" "$WT" "")"
if [ "$RES_C4" = "$EXPLICIT" ]; then
    pass "C4. -C path takes priority over input.cwd and CLAUDE_PROJECT_DIR"
else
    fail "C4. expected $EXPLICIT (-C wins), got: $RES_C4"
fi

# ---------------------------------------------------------------------------
# C5: CLAUDE_PROJECT_DIR unset, input.cwd present → returns input.cwd
#     (existing candidates loop still finds input.cwd)
# ---------------------------------------------------------------------------
RES_C5="$(env -u CLAUDE_PROJECT_DIR MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    node -e "
        const { resolveRepoCwd } = require(process.argv[1]);
        process.stdout.write(String(resolveRepoCwd({ command: 'git status', input: { cwd: process.argv[2] } })));
    " "$PATH_NORMALIZE" "$WT" 2>/dev/null)"
if [ "$RES_C5" = "$WT" ]; then
    pass "C5. CLAUDE_PROJECT_DIR unset + input.cwd present → returns input.cwd"
else
    fail "C5. expected $WT, got: $RES_C5"
fi

# ---------------------------------------------------------------------------
# C6 (Windows-only): CLAUDE_PROJECT_DIR as drive-letter (C:/main/repo),
#     input.cwd as Unix drive form (/c/main/repo) but SAME path →
#     normalizeCwd makes them equal → guard does NOT fire.
#     Skipped on non-win32 (normalizeCwd is a no-op off Windows).
# ---------------------------------------------------------------------------
PLATFORM="$(node -e "process.stdout.write(process.platform)" 2>/dev/null)"
if [ "$PLATFORM" = "win32" ]; then
    WIN_MAIN="C:/main/repo"
    WIN_UNIX="/c/main/repo"   # normalizeCwd -> C:\main\repo == C:/main/repo (both -> backslash form)
    RES_C6="$(CLAUDE_PROJECT_DIR="$WIN_MAIN" call_resolve "git status" "$WIN_UNIX" "")"
    # After normalization both collapse to the same drive-letter path → guard
    # must NOT fire → the result equals the normalized CLAUDE_PROJECT_DIR.
    EXPECT_C6="$(node -e "
        const { normalizeCwd } = require(process.argv[1]);
        process.stdout.write(normalizeCwd(process.argv[2]));
    " "$PATH_NORMALIZE" "$WIN_MAIN" 2>/dev/null)"
    if [ "$RES_C6" = "$EXPECT_C6" ]; then
        pass "C6. (win32) drive-letter vs Unix form for same path → guard does not fire"
    else
        fail "C6. (win32) expected $EXPECT_C6 (no guard fire), got: $RES_C6"
    fi
else
    echo "SKIP: C6 (win32-only path normalization; platform=$PLATFORM)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"

if [ "$FAIL" -eq 0 ]; then
    exit 0
else
    exit 1
fi
