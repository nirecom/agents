#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-worktree-add.sh
# Tests: hooks/enforce-worktree.js, hooks/bash-guard.js, skills/worktree-start/SKILL.md
# Tags: TL1, hook, enforce, worktree, worktree-add, bash-guard, regression, scope:permanent
# #1174 (via #2393): /worktree-start once generated a cd-first `cd X && git
# worktree add` shape that the guards reject. The skill now emits the isolated
# form (WS-6); these cases pin that the canonical form passes BOTH bash-guard
# and enforce-worktree from the main checkout, and the cd-first form does not.
# Regression guard: every case is expected GREEN pre-fix.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$AGENTS_DIR/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

MAIN="$(np "$T/main")"
EXT="$(np "$T/worktrees/my-task/main")"
ew_make_repo "$MAIN"
EW_CONFIG_DIR="$MAIN"
BG="$(np "$AGENTS_DIR/hooks/bash-guard.js")"

# bg_run <command> → approve | block | other:<out>
bg_run() {
    local out
    out="$(cd "$MAIN" && ew_bash_payload test "$1" | run_with_timeout 30 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u WORKFLOW_OFF \
        "AGENTS_CONFIG_DIR=$MAIN" node "$BG" 2>/dev/null)" || true
    out="$(printf '%s' "$out" | tr -d '\r\n')"
    case "$out" in
        *'"decision":"block"'*) printf 'block' ;;
        *'"decision":"approve"'*) printf 'approve' ;;
        *) printf 'other:%s' "$out" ;;
    esac
}
ew() { ew_run "$MAIN" "$(ew_bash_payload test "$1")"; }
bg_expect() { if [[ "$3" == "$1" ]]; then pass "$2"; else fail "$2" "want=$1 got=$3"; fi; }

CANON="git worktree add \"$EXT\" -b feature/my-task"
WITH_C="git -C \"$MAIN\" worktree add \"$EXT\" -b feature/my-task"
CD_FIRST="cd \"$MAIN\" && git worktree add \"$EXT\" -b feature/my-task"

case_begin "worktree-add-canonical-form" "hooks/enforce-worktree.js"
ew_expect allow "H1. enforce-worktree: canonical WS-6 form from main → ALLOW" "$(ew "$CANON")"
bg_expect approve "H1b. bash-guard: canonical WS-6 form → approve" "$(bg_run "$CANON")"
ew_expect allow "H3. enforce-worktree: git -C <main> worktree add <ext> → ALLOW" "$(ew "$WITH_C")"
bg_expect approve "H3b. bash-guard: git -C <main> worktree add <ext> → approve" "$(bg_run "$WITH_C")"
case_end

case_begin "worktree-add-cd-first-form" "hooks/bash-guard.js"
bg_expect block "H2. bash-guard: cd <main> && git worktree add → block (&& is forbidden)" "$(bg_run "$CD_FIRST")"
ew_expect block "H2b. enforce-worktree: cd <main> && git worktree add → BLOCK (chaining voids the allow)" "$(ew "$CD_FIRST")"
case_end

case_begin "worktree-start-skill-emits-isolated-form" "skills/worktree-start/SKILL.md"
WS_SKILL="$AGENTS_DIR/skills/worktree-start/SKILL.md"
if grep -qE '^[[:space:]]*git worktree add <path> -b ' "$WS_SKILL"; then
    pass "S1. worktree-start SKILL.md WS-6 emits the isolated git worktree add form"
else
    fail "S1. worktree-start SKILL.md WS-6 emits the isolated git worktree add form" "canonical line missing"
fi
if grep -qE 'cd [^`]*&&[[:space:]]*git worktree add' "$WS_SKILL"; then
    fail "S2. worktree-start SKILL.md has no cd-first worktree add shape" "cd-first form found"
else
    pass "S2. worktree-start SKILL.md has no cd-first worktree add shape"
fi
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
