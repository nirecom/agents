#!/bin/bash
# tests/feature-2120-workflow-gate-block-heredoc-heredoc.sh
# Tests: hooks/workflow-gate/early-gate-messages.js, hooks/enforce-worktree.js, hooks/enforce-worktree/handle-edit-write.js, hooks/workflow-gate/worktree-entry-gate.js, hooks/enforce-worktree/shared-cmd-utils.js, hooks/enforce-worktree/universal-target-allow.js, hooks/lib/strip-quoted-args.js, hooks/lib/alt-target-remedy.js
# Tags: workflow-gate, enforce-worktree, heredoc, block-message, tier3, TL2, pwsh-not-required, scope:issue-specific
#
# #2120 — block messages advertise Bash and name no writable target, so the agent
# retries through Bash and is blocked again. Fix: drop Bash from the read-tools
# note, append an alternative write target to every block reason.
# #2121 — stripHeredocBody() strips only `cat`-prefixed heredocs (M8), and the
# literal widening would hide EXECUTED interpreter bodies (M7).

set -u

# EXPECTED-WORDING CONTRACT (read before implementing #2120): each block reason in
# enforce-worktree.js, handle-edit-write.js and worktree-entry-gate.js must name an
# alternative write target in the vocabulary early-gate-messages.js already uses —
# the words "plans" and "scratchpad". M2-M6 assert both, case-insensitively. Other
# wording stays RED on purpose: four sites saying one thing four ways is the
# CPR-SSOT/CPR-ORTH failure this contract exists to prevent.
# RED before the fix: M1, M2-M6, M8 (plus one M7 case). GREEN before and after:
# the rest of M7 — the invariant the widening must not break.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
AN="$(np "$AGENTS_DIR")"

# TL3 gap (what this test does NOT catch):
# - whether a real agent stops reaching for Bash after reading the narrowed
#   message (model behaviour, not a hook-output assertion);
# - how Claude Code renders two PreToolUse hooks blocking the same call.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

EARLY_MSG="$AN/hooks/workflow-gate/early-gate-messages.js"
ENTRY_GATE="$AN/hooks/workflow-gate/worktree-entry-gate.js"
GATE_HOOK="$AN/hooks/workflow-gate.js"
EW_HOOK="$AN/hooks/enforce-worktree.js"
HANDLE_EW="$AN/hooks/enforce-worktree/handle-edit-write.js"
SCU="$AN/hooks/enforce-worktree/shared-cmd-utils.js"
IRJS="$AN/hooks/lib/command-ir.js"
TARGETS="$AN/hooks/lib/bash-write-targets.js"
CLASSIFY="$AN/hooks/lib/bash-write-patterns/classify.js"

SUITE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2120-workflow-gate-block-heredoc-heredoc"

# Entrypoint only (rules/coding/file-split.md Pattern A): frontmatter, the source
# paths under test, and the run order. Harness first (tallies + decoders the
# fixture guards already use), then the fixture (M0/M0b, the throwaway git repo,
# the isolation env), then the case files. All live in the sibling folder.
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/helpers.sh
. "$SUITE_DIR/helpers.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/fixture.sh
. "$SUITE_DIR/fixture.sh"

# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-block-messages.sh
. "$SUITE_DIR/cases-block-messages.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-heredoc-strip.sh
. "$SUITE_DIR/cases-heredoc-strip.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-hasheredoc-predicate.sh
. "$SUITE_DIR/cases-hasheredoc-predicate.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-heredoc-routing.sh
. "$SUITE_DIR/cases-heredoc-routing.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-scratchpad-scope.sh
. "$SUITE_DIR/cases-scratchpad-scope.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-verdict-helper.sh
. "$SUITE_DIR/cases-verdict-helper.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-alt-remedy-fallback.sh
. "$SUITE_DIR/cases-alt-remedy-fallback.sh"
# shellcheck source=./feature-2120-workflow-gate-block-heredoc-heredoc/cases-sequencing-failclosed.sh
. "$SUITE_DIR/cases-sequencing-failclosed.sh"

run_M1; run_M2; run_M3; run_M4; run_M4b; run_M5; run_M5b; run_M6; run_M7; run_M8; run_M8b; run_M9; run_M10
run_M11; run_M12; run_M13; run_M14; run_M15

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
