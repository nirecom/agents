#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# TL3 gap (what this TL1 test does NOT catch):
#   - A real linked-worktree family with NTFS junctions / bind mounts (realpath differs).
#   - Real PLANS_DIR shared between concurrent sessions.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u
# Wall-clock guard, re-exec form — MUST precede the fixture block, or the outer
# shell builds the whole fixture tree before re-exec and the inner builds it again.
# 180s: above rules/test.md's 120s default (21 real dispatches) but low enough that
# a hang surfaces as a visible failure rather than a lost summary line.
if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_CAP_INNER:-}" ]; then
    _WD1643_CAP_INNER=1 timeout 180 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
# Issue #1643 — capability attack matrix: each row drives one hostile field type and
# asserts a rejection status, no effectful child process, and no filesystem write.
# Entrypoint only sources the modules and tallies; the cases live in the sibling dir.
CASE_DIR="$AGENTS_DIR/tests/bin/feature-1643-worker-dispatch-capability"
. "$CASE_DIR/helpers.sh"
. "$CASE_DIR/fixtures.sh"
. "$CASE_DIR/observe.sh"
. "$CASE_DIR/matrix.sh"
. "$CASE_DIR/validator.sh"

# Group V runs FIRST: it is seconds of in-process function calls, while the
# matrix below is a dispatch (and a full fixture-tree hash) per row. Ordering the
# cheap deterministic rows ahead of the expensive ones means a run that is cut
# short by the wall-clock guard still reports the validator verdicts.
group_validator_rows
run_matrix

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
