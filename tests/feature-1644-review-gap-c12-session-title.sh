#!/usr/bin/env bash
# tests/feature-1644-review-gap-c12-session-title.sh
# Tests: hooks/lib/session-title.js
# Tags: tl2, workflow, session-title, jsonl, idempotency, parser, scope:issue-specific, pwsh-not-required
#
# #1644 review gap C12 (MEDIUM) — hooks/lib/session-title.js.
# tests/feature-299-session-titles/ already covers the happy paths (T1-T29:
# single/multi issue titles, PR-suffix and completion idempotency once each,
# the ⏳ overwrite guard, session-id resolution). This file extends into the
# input-domain edges that file leaves open:
#   - the ## Issues parser: MULTIPLE sections, a MALFORMED section, a section
#     terminated by a following heading, the absent legacy fallback;
#   - JSONL robustness: malformed lines, foreign-session and wrong-typed
#     records, an EMPTY-string customTitle, an ABSENT transcript directory;
#   - repeated application of the PR suffix and the completion mark, including
#     interleaved and thrice-repeated sequences;
#   - the overwrite guard as a table over every existing-title form;
#   - the child-session and empty-sessionId suppressions across all three
#     writers (CPR-ORTH: the guard must hold for every sibling).
#
# The library is driven through a node probe with CLAUDE_SESSION_JSONL_PATH
# pinned at a fixture file — exactly how the real hook supplies the transcript
# path (from stdin's transcript_path).
#
# Dispatcher: fixtures/probe in feature-1644-review-gap-c12-session-title/helpers.sh;
# case groups in parsing.sh (C12-1/C12-2) and robustness.sh (C12-3..C12-5).
#
# TL3 gap (what this test does NOT catch):
# - The VS Code extension actually reading the custom-title record and painting
#   the tab, including its own rewrite of "⏳" into "⏳<ai-title>".
# - CLAUDE_CODE_CHILD_SESSION propagation into real Claude Code subagents.
# - The cwd-encoded JSONL path used when CLAUDE_SESSION_JSONL_PATH is absent in
#   a live session (covered by feature-299's mtime/encoding cases).
# Closest-to-action mitigation: the parser and guard logic tested here are pure
# functions of file bytes, which TL2 reproduces faithfully.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1644-review-gap-c12-session-title"

# shellcheck source=./feature-1644-review-gap-c12-session-title/helpers.sh
. "$SUBDIR/helpers.sh"
# shellcheck source=./feature-1644-review-gap-c12-session-title/parsing.sh
. "$SUBDIR/parsing.sh"
# shellcheck source=./feature-1644-review-gap-c12-session-title/robustness.sh
. "$SUBDIR/robustness.sh"

run_parsing_cases
run_robustness_cases

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
