#!/usr/bin/env bash
# tests/fix-416-classify-sentinel-reason-text.sh
# Tests: hooks/lib/bash-write-patterns.js classify()
# Tags: classify, strip-kinds, sentinel-echo, isSentinelEchoSafe, issue-416, unsafe-reason-chars, scope:issue-specific
#
# After fix (#416):
#   1. STRIP_KINDS gains "pkg-mgr" and "gh" → quoted pkg-mgr/gh verbs in grep/echo
#      content are no longer false-positives.
#   2. isSentinelEchoSafe early-return: strict-DQ sentinel echo with a safe reason
#      → classify returns "read"; with unsafe reason (contains $, `, ;, |, >) → "write".
#
# Expected:
#   Group A (T3.1–T3.9):    FAIL until write-code adds pkg-mgr/gh to STRIP_KINDS.
#   Group B (T3.10–T3.13c): FAIL until write-code adds isSentinelEchoSafe.
#   Group C (T3.14–T3.16):  PASS now (real writes remain write).
#   Group C2 (T3.14b–T3.28): FAIL until write-code adds pkg-mgr/gh to STRIP_KINDS.
#   Group D (T3.17–T3.36):  Mixed: T3.19/T3.36 are PASS (read, false-neg accepted);
#                           T3.21/T3.23-T3.25/T3.31/T3.34-T3.35 FAIL until fix.
#
# After UNSAFE_REASON_CHARS narrowing (this PR):
#   Group B2 (T3.13d–h): FAIL until write-code narrows UNSAFE_REASON_CHARS to 3-char set.
#   Group D2 (T3.37–41): PASS now (3-char set: $ ` " still blocks all DQ expansion).
#   T3.24/T3.34/T3.35:   Flipped write→read (| and ; are literal in DQ; safe).
#   Group E (T3.0a–c, T3.13i, T3.50): Edge inputs and dispatch guard.
#
# L3 gap: These tests spawn Node.js to call classify() directly (L2). An L3 test
# would invoke enforce-worktree.js with a real Claude Code hook session and verify
# that each command string is allow/block at the hook level, not just at the
# classify() return value level. L3 is out of scope for this PR.
#
# Dispatcher: shared helpers/fixtures live in fix-416-classify-sentinel-reason-text/common.sh;
# case groups live in groups-a-b.sh, groups-c-d.sh, group-e.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}/fix-416-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-416-classify-sentinel-reason-text"

# shellcheck source=./fix-416-classify-sentinel-reason-text/common.sh
. "$SCRIPT_DIR/common.sh"
# shellcheck source=./fix-416-classify-sentinel-reason-text/groups-a-b.sh
. "$SCRIPT_DIR/groups-a-b.sh"
# shellcheck source=./fix-416-classify-sentinel-reason-text/groups-c-d.sh
. "$SCRIPT_DIR/groups-c-d.sh"
# shellcheck source=./fix-416-classify-sentinel-reason-text/group-e.sh
. "$SCRIPT_DIR/group-e.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Runner summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
