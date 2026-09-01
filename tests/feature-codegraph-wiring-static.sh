#!/usr/bin/env bash
# tests/feature-codegraph-wiring-static.sh
# Tests: .env.example, install.ps1, install.sh, install/win/codegraph.ps1, install/linux/codegraph.sh, install/codegraph-mcp.js, bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js, bin/codegraph-lifecycle/process-identity.js, hooks/post-checkout, hooks/post-merge, bin/sweep-worktrees.sh, bin/sweep-worktrees/orphan-dirs.sh, skills/worktree-start/SKILL.md, skills/worktree-end/SKILL.md, skills/worktree-end/scripts/cleanup-cascade.md, skills/sweep-worktrees/SKILL.md, settings.json, agents/lib/codegraph-usage.md, agents/survey-code.md, agents/detail-planner.md, agents/outline-planner.md, agents/detail-reviewer.md, agents/outline-reviewer.md, agents/security-scanner.md, agents/test-reviewer.md, agents/skip-verifier.md, agents/plan-security-reviewer.md, agents/supervisor.md, agents/supervisor-audit.md
# Tags: codegraph, installer, hook-registration, mcp, agent-frontmatter, wiring, static, table-driven, TL2, pwsh-not-required, scope:issue-specific
#
# WHY (CPR-WPH): #2150 threads one opt-in flag through call sites that never execute
# together — two OS installers, two git hooks, three deletion paths, nine agent
# frontmatters, one settings file. A missing or misplaced line there does not fail; it
# makes CodeGraph quietly do nothing. This file is the ratchet over that wiring, and it
# pins as permanent NEGATIVE assertions the four shortcuts the plan rejected (C1 the
# upstream installer, C2 substring daemon matching, C5 init-as-repair, C6 magic-only).
set -u

# Layer TL2 — the repo tree read as text, JSON and frontmatter; nothing is spawned.
# TL3 gap (what this test does NOT catch):
# - Whether install.ps1 / install/win/codegraph.ps1 complete non-interactively under
#   real pwsh, and whether `claude mcp add` writes a real ~/.claude.json user scope.
# - Whether the hook blocks fire on a real `git checkout` / `git merge`.
# - Whether stopping the daemon clears the Windows EPERM on `git worktree remove`,
#   and whether a real `codegraph index -q` rebuilds a zero-byte index.
# - Whether the three deletion paths reach their stop calls at run time: Accepted
#   Tradeoffs settles this wiring as static-only verification, so no sweep is executed.
# Closest-to-action: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$AGENTS_DIR/tests/feature-codegraph-wiring-static"
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

# assert_eq <name> <want> <got> — table comparisons (counts, verdicts, entry sets).
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

# shellcheck source=./feature-codegraph-wiring-static/harness.sh
. "$SCRIPT_DIR/harness.sh"
# shellcheck source=./feature-codegraph-wiring-static/required-strings.sh
. "$SCRIPT_DIR/required-strings.sh"
# shellcheck source=./feature-codegraph-wiring-static/negative-guards.sh
. "$SCRIPT_DIR/negative-guards.sh"
# shellcheck source=./feature-codegraph-wiring-static/hooks.sh
. "$SCRIPT_DIR/hooks.sh"
# shellcheck source=./feature-codegraph-wiring-static/skill-wiring.sh
. "$SCRIPT_DIR/skill-wiring.sh"
# shellcheck source=./feature-codegraph-wiring-static/agent-exposure.sh
. "$SCRIPT_DIR/agent-exposure.sh"
# shellcheck source=./feature-codegraph-wiring-static/settings-env.sh
. "$SCRIPT_DIR/settings-env.sh"
# shellcheck source=./feature-codegraph-wiring-static/version-ssot.sh
. "$SCRIPT_DIR/version-ssot.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
