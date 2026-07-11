#!/bin/bash
# tests/fix-unblock-branch-d/_lib.sh
# Tests: hooks/enforce-worktree/branch-delete-guard.js, hooks/lib/command-parser.js, hooks/enforce-worktree.js
# Tags: test-lib, worktree, enforce, hook, branch-delete, redirect, scope:common
# Shared helpers and fixtures for fix-unblock-branch-d test groups.
#
# Sourced by:
#   - tests/fix-unblock-branch-d/unit.sh
#   - tests/fix-unblock-branch-d/integration.sh
#   - tests/fix-unblock-branch-d/hook-redirect.sh
#
# Each group script sources this file so it can run standalone, e.g.:
#   bash tests/fix-unblock-branch-d/unit.sh
#
# This library resolves AGENTS_DIR / MODULE / PATTERNS_MODULE / HOOK_SCRIPT,
# defines pass / fail / run_with_timeout, the unit-test node -e callers, and the
# git-repo fixture helpers. It does NOT initialize PASS/FAIL, create TMPDIR_BASE,
# register a cleanup trap, echo Results, or exit — the group scripts own those,
# because each group runs as an independent child bash process under the
# dispatcher and exits on its own.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
PATTERNS_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/branch-delete-guard.js"
PARSER_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/command-parser.js"
HOOK_SCRIPT="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
# Environment-gated skip: NOT counted as pass or fail (avoids false-green).
skip() { echo "SKIP: $1"; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Unit-test callers
# ─────────────────────────────────────────────────────────────────────────────

call_isBranchDeleteCommand() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.isBranchDeleteCommand(process.argv[1])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_parseTarget() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        console.log(JSON.stringify(m.parseBranchDeleteTarget(process.argv[1])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_classify() {
    run_with_timeout 30 node -e "
      try {
        const { classify } = require('$PATTERNS_MODULE');
        console.log(classify(process.argv[1]));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

# Run the hook end-to-end. Mirrors the wrapper used in feature-parallel-sessions-*.sh.
run_hook() {
    local payload="$1" cwd="$2"
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 node "$HOOK_SCRIPT" 2>&1)
}

# Run the hook capturing STDOUT ONLY (stderr discarded) so a crash cannot leak
# noise into the allow-payload equality check. Caller reads exit code via $?.
run_hook_stdout() {
    local payload="$1" cwd="$2"
    (cd "$cwd" && printf '%s' "$payload" | run_with_timeout 30 node "$HOOK_SCRIPT" 2>/dev/null)
}

# Observed hook contract (verified by hitting enforce-worktree.js directly):
#   ALLOW → stdout is exactly `{}`, exit 0.
#   BLOCK → stdout is `{"decision":"block",...}`, exit 0 (exit code does NOT
#           distinguish allow from block — the payload shape does).
# So a positive ALLOW assertion must check: exit 0 AND stdout parses as JSON
# with NO `decision` key (not merely "block absent from a merged blob"). This
# fails-loud on hook crash (non-JSON / non-empty stderr / nonzero exit) and on
# empty output, closing the false-green gap.

# Classify a hook run: prints "ALLOW" | "BLOCK" | "MALFORMED:<detail>".
# $1 = raw stdout (stderr must be captured separately, not merged), $2 = exit code.
classify_hook_decision() {
    local out="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then echo "MALFORMED:exit=$rc"; return; fi
    printf '%s' "$out" | node -e "
      let b='';
      process.stdin.on('data', c => b += c);
      process.stdin.on('end', () => {
        try {
          const d = JSON.parse(b);
          if (d && typeof d === 'object' && d.decision === 'block') { console.log('BLOCK'); return; }
          if (d && typeof d === 'object' && !('decision' in d)) { console.log('ALLOW'); return; }
          console.log('MALFORMED:unexpected-shape');
        } catch (e) { console.log('MALFORMED:not-json'); }
      });
    " 2>/dev/null
}

# Positive ALLOW assertion (exit 0 + allow payload shape). $1=label, $2=stdout, $3=rc.
assert_hook_allow() {
    local label="$1" out="$2" rc="$3" verdict
    verdict="$(classify_hook_decision "$out" "$rc")"
    if [ "$verdict" = "ALLOW" ]; then
        pass "$label (exit 0, allow payload {})"
    else
        fail "$label expected ALLOW (exit 0 + {}); got $verdict; rc=$rc out=[$out]"
    fi
}

# Positive BLOCK assertion (exit 0 + block payload shape). $1=label, $2=stdout, $3=rc.
assert_hook_block() {
    local label="$1" out="$2" rc="$3" verdict
    verdict="$(classify_hook_decision "$out" "$rc")"
    if [ "$verdict" = "BLOCK" ]; then
        pass "$label (exit 0, block payload)"
    else
        fail "$label expected BLOCK; got $verdict; rc=$rc out=[$out]"
    fi
}

# Build a Bash payload for the PreToolUse hook.
hook_payload_bash() {
    local cmd="$1"
    node -e "
      const c = process.argv[1];
      console.log(JSON.stringify({tool_name:'Bash', tool_input:{command:c}}));
    " -- "$cmd"
}

# ─────────────────────────────────────────────────────────────────────────────
# Worktree-list-based decision fixtures
# ─────────────────────────────────────────────────────────────────────────────

# Initialise a bare-ish source repo (single commit on main).
init_repo() {
    local repo="$1"
    mkdir -p "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t init -q -b main . && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m init)
}

# Add a linked worktree at $2 on a new branch $3 from repo $1.
add_linked_worktree() {
    local repo="$1" wpath="$2" branch="$3"
    (cd "$repo" && git worktree add -q "$wpath" -b "$branch" 2>/dev/null)
}
