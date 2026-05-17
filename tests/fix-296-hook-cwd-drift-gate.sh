#!/bin/bash
# tests/fix-296-hook-cwd-drift-gate.sh
#
# Tests for hooks/workflow-gate.js resolveRepoDir(command) — verifies that
# the existing `git -C <path>` resolution still wins, AND that a leading
# `cd <abs-path> && git commit ...` is honored before the staged-changes
# scan (issue #296).
#
# resolveRepoDir IS already a function in workflow-gate.js but is NOT yet
# in module.exports — the fix will add it and also wire parseCdCommand into
# its precedence chain (between `git -C` and the staged-changes scan).
#
# Pre-implementation, every W-case fails with NOT_EXPORTED (clean failure,
# not a node crash).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
WG="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"

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

if [ ! -f "$AGENTS_DIR/hooks/workflow-gate.js" ]; then
    echo "FAIL: hooks/workflow-gate.js not found"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

norm_path() {
    local p="$1"
    p="${p//\\//}"
    p="${p%/}"
    echo "$p" | tr '[:upper:]' '[:lower:]'
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: main repo + linked worktree under a temp dir. core.hooksPath is
# pointed at an empty dir so the agents-repo pre-commit hook does NOT fire
# against the fixture (it would otherwise refuse on commits from main).
# ─────────────────────────────────────────────────────────────────────────────

setup_repo() {
    TMPDIR_G="$(mktemp -d 2>/dev/null || mktemp -d -t gate_test)"
    MAIN="$TMPDIR_G/main"
    LINKED="$TMPDIR_G/linked"
    HOOKS_NULL="$TMPDIR_G/null-hooks"
    mkdir -p "$HOOKS_NULL"
    git init -q "$MAIN"
    (
        cd "$MAIN"
        git config core.hooksPath "$HOOKS_NULL"
        git config user.email t@example.com
        git config user.name "T"
        echo a > a.txt
        git add a.txt
        git -c commit.gpgsign=false commit -q -m init
    )
    git -C "$MAIN" -c core.hooksPath="$HOOKS_NULL" worktree add -q "$LINKED" -b test/gate-296 >/dev/null 2>&1

    # Create a stub HOME so node's os.homedir() never resolves to the real
    # ~/.claude/settings.json (which would list c:/git/agents and contaminate W4).
    FAKE_HOME="$TMPDIR_G/fakehome"
    mkdir -p "$FAKE_HOME/.claude"
    printf '{"permissions":{"additionalDirectories":[]}}' > "$FAKE_HOME/.claude/settings.json"

    if command -v cygpath >/dev/null 2>&1; then
        MAIN_NODE="$(cygpath -m "$MAIN")"
        LINKED_NODE="$(cygpath -m "$LINKED")"
        MAIN_LITERAL="$(cygpath -w "$MAIN")"
        LINKED_LITERAL="$(cygpath -w "$LINKED")"
    else
        MAIN_NODE="$MAIN"
        LINKED_NODE="$LINKED"
        MAIN_LITERAL="$MAIN"
        LINKED_LITERAL="$LINKED"
    fi
}

cleanup_repo() {
    if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ]; then
        git -C "$MAIN" worktree remove -f "$LINKED" >/dev/null 2>&1 || true
    fi
    [ -n "${TMPDIR_G:-}" ] && [ -d "$TMPDIR_G" ] && rm -rf "$TMPDIR_G" 2>/dev/null || true
}

# Stage a new file in <repo>. <suffix> keeps multiple stage-calls from
# colliding on the same path.
stage_in() {
    local repo="$1"
    local suffix="$2"
    local f="$repo/staged-$suffix.txt"
    echo "stage-$suffix" > "$f"
    git -C "$repo" add "staged-$suffix.txt" >/dev/null 2>&1
}

# Unstage everything in <repo> (returns to clean state).
unstage_all() {
    local repo="$1"
    git -C "$repo" reset -q >/dev/null 2>&1 || true
}

setup_repo
trap cleanup_repo EXIT INT TERM HUP

# ─────────────────────────────────────────────────────────────────────────────
# Helper: call resolveRepoDir(cmd) with CLAUDE_PROJECT_DIR=MAIN and cwd=MAIN.
# Echoes the function's return value, or NOT_EXPORTED / ERROR: ...
# ─────────────────────────────────────────────────────────────────────────────
call_resolve() {
    local cmd="$1"
    (
        cd "$MAIN" && CLAUDE_PROJECT_DIR="$MAIN_LITERAL" HOME="$FAKE_HOME" USERPROFILE="$FAKE_HOME" run_with_timeout 30 node -e "
          try {
            const m = require('$WG');
            if (typeof m.resolveRepoDir !== 'function') {
              console.log('NOT_EXPORTED'); process.exit(2);
            }
            const r = m.resolveRepoDir(process.argv[1]);
            console.log(r === null || r === undefined ? '' : r);
          } catch(e) { console.log('ERROR: '+e.message); }
        " -- "$cmd" 2>/dev/null
    )
}

assert_resolve_eq() {
    local id="$1"
    local cmd="$2"
    local expected_node="$3"
    local r got exp
    r="$(call_resolve "$cmd")"
    case "$r" in
        NOT_EXPORTED) fail "$id: resolveRepoDir not exported"; return ;;
        ERROR*) fail "$id: $r"; return ;;
    esac
    got="$(norm_path "$r")"
    exp="$(norm_path "$expected_node")"
    if [ "$got" = "$exp" ]; then
        pass "$id: $cmd → $r"
    else
        fail "$id: expected $exp, got $got (raw=$r)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# W1: git -C <LINKED> commit → LINKED (existing -C path, regression)
# ─────────────────────────────────────────────────────────────────────────────
unstage_all "$MAIN"
unstage_all "$LINKED"
assert_resolve_eq "W1" "git -C \"$LINKED_LITERAL\" commit -m x" "$LINKED_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# W2: cd <LINKED> && git commit → LINKED (new cd path)
# ─────────────────────────────────────────────────────────────────────────────
unstage_all "$MAIN"
unstage_all "$LINKED"
assert_resolve_eq "W2" "cd \"$LINKED_LITERAL\" && git commit -m x" "$LINKED_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# W3: bare git commit, MAIN has staged changes, LINKED clean → MAIN
#     (existing staged-changes fallback, regression)
# ─────────────────────────────────────────────────────────────────────────────
unstage_all "$MAIN"
unstage_all "$LINKED"
stage_in "$MAIN" "w3"
assert_resolve_eq "W3" "git commit -m x" "$MAIN_NODE"
unstage_all "$MAIN"

# ─────────────────────────────────────────────────────────────────────────────
# W4: bare git commit, nothing staged anywhere → MAIN (final fallback)
# ─────────────────────────────────────────────────────────────────────────────
unstage_all "$MAIN"
unstage_all "$LINKED"
assert_resolve_eq "W4" "git commit -m x" "$MAIN_NODE"

# ─────────────────────────────────────────────────────────────────────────────
# W5: git -C <LINKED> commit, MAIN has staged changes → LINKED
#     (-C beats staged-changes)
# ─────────────────────────────────────────────────────────────────────────────
unstage_all "$MAIN"
unstage_all "$LINKED"
stage_in "$MAIN" "w5"
assert_resolve_eq "W5" "git -C \"$LINKED_LITERAL\" commit -m x" "$LINKED_NODE"
unstage_all "$MAIN"

# ─────────────────────────────────────────────────────────────────────────────
# W6: cd <LINKED> && git commit, MAIN has staged changes → LINKED
#     (cd beats staged-changes, new behaviour)
# ─────────────────────────────────────────────────────────────────────────────
unstage_all "$MAIN"
unstage_all "$LINKED"
stage_in "$MAIN" "w6"
assert_resolve_eq "W6" "cd \"$LINKED_LITERAL\" && git commit -m x" "$LINKED_NODE"
unstage_all "$MAIN"

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
