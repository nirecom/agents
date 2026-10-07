#!/bin/bash
# bin/check-plans-dir-isolation.sh — test-fixture isolation gate (#1799, #2512).
# A gate, not a report: exit 1 on a violation, 2 on a usage error.
# Wired into the agents-repo pre-commit gate (--staged) and the migration-blocks-audit CI job.
# Modes and labels: bin/check-plans-dir-isolation/main.js. Contract: rules/test/fixture-isolation.md.
# Usage: bin/check-plans-dir-isolation.sh [--staged | --root <dir> | <file>...]

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$REPO_ROOT/bin/check-plans-dir-isolation/main.js" "$@"
