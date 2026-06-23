#!/bin/bash
# tests/refactor-1045-target-aware-redesign.sh
# Tests: hooks/enforce-worktree/universal-target-allow.js, hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows.js, hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/enforce-worktree/session-scope.js
# Tags: worktree, enforce, hook, target-aware, refactor-1045, scope:issue-specific
#
# Post-refactor contract: enforce-worktree.js target-aware universal rule
# (hooks/enforce-worktree/universal-target-allow.js).
#
# The refactor:
#   1. Adds universal-target-allow.js: for Bash commands from main worktree,
#      if EVERY parseable write target resolves outside the repo, allow
#      (regardless of command shape — echo, cp, tee, New-Item, rm, etc.).
#   2. Removes plans-dir.js: the WORKFLOW_PLANS_DIR carve-out is now handled
#      by the universal rule (plans-dir is outside repo → allow).
#   3. Removes KNOWN_PLANS_DIR_WRITERS allowlist: node bin/<script> commands
#      are write-classified and may have no redirect targets. The universal rule
#      classifies them — if classify() returns "read", the hook fast-allows
#      before reaching main-worktree-allows at all.
#
# L3 gap:
#   - Real PreToolUse surface: only a live `claude -p` session fires the hook
#     via the Anthropic hook protocol. This L2 uses `node GUARD_JS` via stdin JSON.
#   - Windows path normalization under model command output: backslash paths
#     emitted by the model may differ from what the shell passes to Node.
#   - Live session env var resolution: WORKFLOW_PLANS_DIR may come from dotfiles,
#     .env.local, or system env. This L2 sets it directly as process env.
#   - Path edge cases (CWE-22 via additional traversal forms, Write/MultiEdit
#     tool names, relative paths, Windows backslash quoting, spaces in paths,
#     tilde expansion, symlinks) are not covered — gated at higher layers by
#     isPathOutsideRepo path normalization which is exercised by R-21.
#
# Regression carry — why fix-933 and feature-957 tests are deleted:
#
#   This PR DELETES tests/fix-933-enforce-worktree-plans-dir.sh and
#   tests/feature-957-plans-dir-node-bin-allow.sh. Rationale:
#
#   1. Both files test isAllowedWorkflowPlansDirWrite() by require()-ing
#      hooks/enforce-worktree/main-worktree-allows/plans-dir.js.
#      After WF-CODE-5 deletes plans-dir.js, those tests produce module-not-found
#      ERRORS (worse than a clean assert failure).
#
#   2. The hook-level cases (E1, E2, E3, E5, G1, G2) in fix-933 all rely on
#      FAKE_PLANS_DIR placed INSIDE the test repo (under MAIN_CLEAN) to bypass
#      the isInSessionScope fast-allow. This artificial setup is INCOMPATIBLE
#      with the universal rule: targets inside the repo are inside the session
#      scope → the universal rule abstains → the command reaches the main-worktree
#      block → BLOCK. There is no clean partial-fix path.
#
#   3. The bash -c '...' inner-redirect form (P6 / E3 in fix-933) loses its
#      allow path entirely with no replacement. This is Accepted Tradeoff C1
#      per the intent.md for this issue. No test in this suite asserts
#      this loss positively (the deletion of those cases IS the assertion).
#
#   The production-correct invariant — WORKFLOW_PLANS_DIR writes from main are
#   allowed when PLANS_DIR is OUTSIDE the repo — is preserved as R-5 and R-6
#   in this suite, with PLANS_DIR_FIXTURE placed under TMPDIR_BASE (not under
#   any test repo).

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
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Temp directory — use Node for Windows-compatible path resolution.
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'r1045-target-aware-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# PLANS_DIR_FIXTURE: outside any test repo (directly under TMPDIR_BASE).
# This mirrors the production layout: ~/.workflow-plans/ is outside any repo.
PLANS_DIR_FIXTURE="$TMPDIR_BASE/plans-fixture"
mkdir -p "$PLANS_DIR_FIXTURE/sess"
if command -v cygpath >/dev/null 2>&1; then
    PLANS_DIR_FIXTURE_N="$(cygpath -m "$PLANS_DIR_FIXTURE")"
else
    PLANS_DIR_FIXTURE_N="$PLANS_DIR_FIXTURE"
fi

# Create a minimal git repo (main worktree) at TMPDIR_BASE/<name>.
# Returns the repo path (Windows-normalized when on Cygwin/MSYS).
setup_main_checkout() {
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
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

# Create a main repo + linked worktree. Returns "<main>|<wt>" (Windows-normalized).
setup_linked_worktree() {
    local name="$1"
    local main_raw="$TMPDIR_BASE/$name-main"
    mkdir -p "$main_raw"
    git -C "$main_raw" init -q -b main
    git -C "$main_raw" config user.email "test@example.com"
    git -C "$main_raw" config user.name "Test"
    git -C "$main_raw" config core.hooksPath /dev/null
    echo "init" > "$main_raw/README.md"
    git -C "$main_raw" add README.md
    git -C "$main_raw" commit -q -m "initial"
    local wt_raw="$TMPDIR_BASE/$name-wt"
    git -C "$main_raw" worktree add -q -b "feature/$name" "$wt_raw" 2>/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        echo "$(cygpath -m "$main_raw")|$(cygpath -m "$wt_raw")"
    else
        echo "$main_raw|$wt_raw"
    fi
}

# Run enforce-worktree guard for a Bash command.
# Args: cmd cwd [env-VAR=val ...]
run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Run enforce-worktree guard for Edit/Write/MultiEdit tools.
# Args: toolName filePath cwd [env-VAR=val ...]
run_edit_guard() {
    local tool_name="$1"; shift
    local file_path="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name: process.argv[1], tool_input:{ file_path: process.argv[2] } };
      console.log(JSON.stringify(j));
    " -- "$tool_name" "$file_path" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# Returns 0 (allow) if output lacks "decision":"block"; 1 (block) otherwise.
guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# Precondition gate for cases that depend on the new universal-target-allow.js.
# Fails loud (records FAIL) when the file doesn't exist yet (pre-implementation).
UNIVERSAL_JS="$AGENTS_DIR/hooks/enforce-worktree/universal-target-allow.js"
require_impl() {
    local label="$1"
    if [ ! -f "$UNIVERSAL_JS" ]; then
        fail "$label (precondition missing: $UNIVERSAL_JS) — universal rule not yet implemented; expected FAIL in pre-implementation runs"
        return 1
    fi
    return 0
}

# Export all shared helpers and globals so sourced sibling scripts can use them.
export AGENTS_DIR _AGENTS_DIR_NODE GUARD_JS TMPDIR_BASE PLANS_DIR_FIXTURE PLANS_DIR_FIXTURE_N UNIVERSAL_JS
export -f pass fail skip run_with_timeout setup_main_checkout setup_linked_worktree
export -f run_bash_guard run_edit_guard guard_decision require_impl

# Source each section file; each file defines its test functions then immediately invokes them.
# Counters accumulate in this shell via the exported functions.
SECTION_DIR="$(dirname "${BASH_SOURCE[0]}")/refactor-1045-target-aware-redesign"

source "$SECTION_DIR/allow-outside-repo.sh"
source "$SECTION_DIR/block-inside-or-unparseable.sh"
source "$SECTION_DIR/mode-and-shape-allows.sh"
source "$SECTION_DIR/node-bin-classify.sh"
source "$SECTION_DIR/non-git-cwd.sh"
source "$SECTION_DIR/session-scope.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
