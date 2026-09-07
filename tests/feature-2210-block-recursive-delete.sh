#!/bin/bash
# tests/feature-2210-block-recursive-delete.sh
# Tests: hooks/block-recursive-delete.js, hooks/lib/bash-write-targets/rm.js, hooks/lib/bash-write-targets/pwsh.js, hooks/lib/bash-write-targets/cmd-exe.js, hooks/lib/bash-write-targets/recursive-delete-scan/scan.js, hooks/lib/bash-write-targets/recursive-delete-scan/head-peeling.js, hooks/lib/bash-write-targets/recursive-delete-scan/interpreter-bodies.js, hooks/lib/bash-write-targets/recursive-delete-scan/stdin-delivery.js, hooks/lib/bash-write-targets/recursive-delete-scan/var-tracking.js, hooks/lib/bash-write-targets/recursive-delete-scan/wrapper-bodies.js, hooks/lib/bash-write-patterns/segment-utils/interpreter-specs.js, settings.json
# Tags: scope:issue-specific, recursive-delete, hook, hook-registration, settings-json, TL2, pwsh-not-required
#
# #2210: the settings.json recursive-delete deny globs become one PreToolUse
# hook. Entrypoint only — harness and cases live in the sibling folder.

set -u

# TL3 gap: no real Claude Code host invokes the hook here, and no real cmd.exe
# or PowerShell expands these payloads. Mitigated at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
AN="$(np "$AGENTS_DIR")"

HOOK="$AN/hooks/block-recursive-delete.js"
SETTINGS="$AN/settings.json"

# Fixture isolation: a spawned hook must not resolve the parent live session.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

SUITE_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-2210-block-recursive-delete"

# shellcheck source=./feature-2210-block-recursive-delete/helpers.sh
. "$SUITE_DIR/helpers.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-posix.sh
. "$SUITE_DIR/cases-posix.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-pwsh.sh
. "$SUITE_DIR/cases-pwsh.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-cmdexe.sh
. "$SUITE_DIR/cases-cmdexe.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-negative.sh
. "$SUITE_DIR/cases-negative.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-registration.sh
. "$SUITE_DIR/cases-registration.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-tool-shapes.sh
. "$SUITE_DIR/cases-tool-shapes.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-bypass.sh
. "$SUITE_DIR/cases-bypass.sh"
# shellcheck source=./feature-2210-block-recursive-delete/cases-protection-fix.sh
. "$SUITE_DIR/cases-protection-fix.sh"

echo ""
echo "=== Node unit suites (C1: previously written but never invoked) ==="
run_unit_suite "hasRecursiveRmFlag/hasRecursivePwshFlag/hasRecursiveCmdExeFlag unit suite" \
    "$AN/tests/lib/test-recursive-delete-flags.js"
run_unit_suite "scanCommandTextForRecursiveDelete unit suite" \
    "$AN/tests/lib/test-recursive-delete-scan.js"

run_posix_cases
run_pwsh_cases
run_cmdexe_cases
run_negative_cases
run_tool_shape_cases
run_registration_cases
run_bypass_cases
run_protection_fix_cases

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
