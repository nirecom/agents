#!/usr/bin/env bash
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, skill-orchestration, auto-naming, claude-e2e, TL3, run-e2e, scope:common
#
# Real-host seam test for the worktree-start skill's auto-naming path.
# A live `claude -p` session reads the real SKILL.md and executes WS-1..WS-6
# against a throwaway git repo. What only a real host can show:
#   - the model never reaches for AskUserQuestion to pick a name or branch type
#     (WS-2 is auto-derived in every context) — proven by a PreToolUse probe
#     registered on AskUserQuestion, not by grepping SKILL.md prose;
#   - the path and branch it actually creates equal what
#     derive-worktree-name.sh itself emits for the same repo and session;
#   - a second invocation reuses the registered worktree instead of adding a
#     second one (WS-2 reuse-safety as executed, not as reimplemented).
# Layer: TL3 (live claude -p, real skill file, real script, real git worktrees).
#
# Sub-files under TL3-skill-worktree-start-auto-naming/:
#   helpers.sh      — fixture builder, AskUserQuestion probe, claude runner
#   case-session.sh — WSE-1..WSE-7: no-argument invocation + idempotent re-run
#   case-headless.sh— WSE-8..WSE-12: forked `--headless <label>` invocation
#
# TL3 gap (what this test does NOT catch):
# - WS-7 (worktree-copy worker dispatch), WS-8 (EnterWorktree) and WS-9 are out
#   of scope here: they need a real worker fleet and a real IDE-side tool. The
#   run is explicitly stopped after WS-6.
# - The derivation logic itself is exhaustively covered at TL2 by
#   tests/feature-worktree-start-non-interactive.sh; this file only pins the
#   model-executed seam and is gated on RUN_TL3, so TL2 stays the daily runner.
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
