#!/usr/bin/env bash
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, skill-orchestration, auto-naming, claude-e2e, TL3, run-e2e, scope:common
#
# TL3: live `claude -p` runs the real worktree-start SKILL.md (WS-1..WS-6)
# against a throwaway git repo. Pins what only a real host shows: no
# AskUserQuestion for name/branch, created path+branch equal
# derive-worktree-name.sh output, and a re-run reuses the worktree.

# Sub-files: helpers.sh (fixture/probe/runner),
# case-session.sh (WSE-1..7 no-arg + re-run), case-headless.sh (WSE-8..12).

# TL3 gap: WS-7..WS-9 out of scope (need a real worker fleet / IDE tool);
# derivation logic is covered at TL2 by
# tests/feature-worktree-start-non-interactive.sh (the daily runner).
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

[ -x "$AGENTS_DIR/bin/get-config-var" ] || exit 77
"$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && exit 77
command -v claude >/dev/null 2>&1 || exit 77

ERRORS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }

# shellcheck source=tests/TL3-skill-worktree-start-auto-naming/helpers.sh
. "$AGENTS_DIR/tests/TL3-skill-worktree-start-auto-naming/helpers.sh"
# shellcheck source=tests/TL3-skill-worktree-start-auto-naming/case-session.sh
. "$AGENTS_DIR/tests/TL3-skill-worktree-start-auto-naming/case-session.sh"
# shellcheck source=tests/TL3-skill-worktree-start-auto-naming/case-headless.sh
. "$AGENTS_DIR/tests/TL3-skill-worktree-start-auto-naming/case-headless.sh"

echo ""
echo "=== Results ==="
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
