#!/usr/bin/env bash
# tests/hooks/feature-2256-input-version-full-hash/_common.sh
# Tests: hooks/lib/diff-fingerprint.js
# Tags: test-infrastructure, fixture, shared-lib, scope:issue-specific
# Shared fixture + assertion preamble for the feature-2256-input-version-full-hash sections.
# Sourced, never run as a section: the parent lists section files explicitly.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE="$AGENTS_DIR"
fi
FP_NODE="$AGENTS_NODE/hooks/lib/diff-fingerprint.js"
BD_NODE="$AGENTS_NODE/hooks/lib/branch-diff.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_ne() {
    if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "both sides are '$2'"; fi
}
assert_match() {
    if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256iv)"
trap 'rm -rf "$WORK"' EXIT
if command -v cygpath >/dev/null 2>&1; then WORK_NODE="$(cygpath -m "$WORK")"; else WORK_NODE="$WORK"; fi

mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$AGENTS_NODE"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

# mk_repo <name> — a git fixture whose hooks are disabled and whose line endings are fixed.
mk_repo() {
    local name="$1" dir="$WORK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name tester
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m seed
    git -C "$dir" checkout -q -b work
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$dir"; else printf '%s' "$dir"; fi
}

# fp <fn> <cwd-node-path> [extra-args-json] — call one diff-fingerprint export, print its value.
fp() {
    local fn="$1" cwd="$2" extra="${3:-}"
    local js="$WORK/fp-$$.js"
    {
        printf '%s\n' "const fp = require('$FP_NODE');"
        printf '%s\n' "const v = fp.$fn('$cwd'$extra);"
        printf '%s\n' "process.stdout.write(v === null || v === undefined ? 'null' : (typeof v === 'object' ? JSON.stringify(v) : String(v)));"
    } > "$js"
    bash "$RWT" 60 node "$js" 2>&1
}
