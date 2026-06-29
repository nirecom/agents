#!/bin/bash
# Shared helpers for feature-1102-sibling-worktrees tests.
# Sourced by lib-tests.sh and cli-tests.sh — not a standalone runner.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
BIN_JS="${_AGENTS_DIR_NODE}/bin/worktree-write-notes.js"
LIB_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'sw-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
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

require_bin() {
    if [ ! -f "$BIN_JS" ]; then
        fail "$1 (bin/worktree-write-notes.js not implemented yet)"
        return 1
    fi
    return 0
}

require_lib() {
    if [ ! -f "$LIB_JS" ]; then
        fail "$1 (hooks/lib/worktree-notes.js not implemented yet)"
        return 1
    fi
    return 0
}

# Run a snippet that requires the lib. The snippet receives `lib` in scope.
# Usage: lib_eval "<js snippet>" [arg1 arg2 ...]
lib_eval() {
    local snippet="$1"; shift
    run_with_timeout 120 node -e "
        const lib = require('${LIB_JS}');
        ${snippet}
    " -- "$@"
}

# JSON field extraction via node (no jq dependency).
json_field() {
    local out="$1"
    local field="$2"
    node -e "
        let buf = '';
        process.stdin.on('data', c => buf += c);
        process.stdin.on('end', () => {
            try {
                const j = JSON.parse(buf);
                const v = j[process.argv[1]];
                process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
            } catch (e) {
                process.stdout.write('');
            }
        });
    " -- "$field" <<< "$out" 2>/dev/null
}

# Run the bin script with argv + COPIED_JSON env. Stdout only.
# Usage: run_bin mainRoot worktreePath branch [baseDir] [copiedJSON] [sid]
run_bin() {
    local main="$1" wt="$2" branch="$3" baseDir="${4:-}" copied="${5:-}" sid="${6:-}"
    COPIED_JSON="$copied" run_with_timeout 120 node "$BIN_JS" "$main" "$wt" "$branch" "$baseDir" "$sid" 2>/dev/null
}

run_bin_stderr() {
    local main="$1" wt="$2" branch="$3" baseDir="${4:-}" copied="${5:-}" sid="${6:-}"
    COPIED_JSON="$copied" run_with_timeout 120 node "$BIN_JS" "$main" "$wt" "$branch" "$baseDir" "$sid" 2>&1 >/dev/null
}

run_bin_exitcode() {
    local main="$1" wt="$2" branch="$3" baseDir="${4:-}" copied="${5:-}" sid="${6:-}"
    COPIED_JSON="$copied" run_with_timeout 120 node "$BIN_JS" "$main" "$wt" "$branch" "$baseDir" "$sid" >/dev/null 2>&1
    printf "%d\n" $?
}

# Make a fresh main-style git repo (with `.git` dir).
setup_main_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Make an empty worktree destination directory.
setup_worktree_dest() {
    local name="$1"
    local wt="$TMPDIR_BASE/$name"
    mkdir -p "$wt"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt"
    else
        echo "$wt"
    fi
}

# Convert path to node-friendly (forward slash) form when on Windows.
node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}
