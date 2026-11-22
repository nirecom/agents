#!/usr/bin/env bash
# Tests: agents/outline-reviewer.md, agents/detail-reviewer.md, agents/test-reviewer.md, agents/plan-security-reviewer.md
# Tags: feature-2478, cc-fallback, codex-review-loop, static, scope:issue-specific, TL1, pwsh-not-required
#
# #2478 S3-1: a CC-fallback reviewer's report is parsed by the loop's path-kind parser, so all four
# reviewers share one output contract: verdict + concerns inside the codex-output block, round 2+ as
# "C<N>: resolved|unresolved", INPUT_ERROR at line start, the form chosen by FALLBACK_ROUND; and
# plan-security-reviewer is no longer single-round. Text-only: the agent prompts are not code.
# TL3 gap: a live reviewer agent actually emitting this shape (claude -p) is not run.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

LINE_START_RE='(start of (a|the) line|line start|line-leading|beginning of (a|the) line|first column)'

# has <label> <file> <needle> — fixed-string match in an existing file.
has() {
    if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then pass "$1"
    else fail "$1" "'$3' absent from $(basename "$2")"; fi
}

# input_error_at_line_start <file> — an example line starting with INPUT_ERROR <path>, or prose saying so.
input_error_at_line_start() {
    [[ -f "$1" ]] || return 1
    grep -qE '^[[:punct:]]?INPUT_ERROR <path>' "$1" && return 0
    grep -qiE "INPUT_ERROR.*$LINE_START_RE|$LINE_START_RE.*INPUT_ERROR" "$1"
}

# reviewer_contract <reviewer> — the four S3-1 contract points of agents/<reviewer>.md.
reviewer_contract() {
    local r="$1" f="$SCRIPT_CHECKOUT_ROOT/agents/$1.md"
    has "$r wraps the report in begin-codex-output" "$f" "<!-- begin-codex-output"
    has "$r wraps the report in end-codex-output" "$f" "<!-- end-codex-output -->"
    if [[ -f "$f" ]] && grep -qE 'C(<N>|[0-9]+): resolved' "$f" && grep -qE 'C(<N>|[0-9]+): unresolved' "$f"; then
        pass "$r writes round 2+ as C<N>: resolved|unresolved"
    else fail "$r writes round 2+ as C<N>: resolved|unresolved" "line form absent from $r.md"; fi
    if input_error_at_line_start "$f"; then pass "$r puts INPUT_ERROR at line start"
    else fail "$r puts INPUT_ERROR at line start" "no line-leading INPUT_ERROR instruction in $r.md"; fi
    has "$r chooses the form by FALLBACK_ROUND" "$f" "FALLBACK_ROUND"
}

case_begin "outline-reviewer-fallback-output-contract" "agents/outline-reviewer.md"
reviewer_contract outline-reviewer
case_end

case_begin "detail-reviewer-fallback-output-contract" "agents/detail-reviewer.md"
reviewer_contract detail-reviewer
case_end

case_begin "test-reviewer-fallback-output-contract" "agents/test-reviewer.md"
reviewer_contract test-reviewer
case_end

case_begin "plan-security-reviewer-fallback-output-contract" "agents/plan-security-reviewer.md"
reviewer_contract plan-security-reviewer
PSR="$SCRIPT_CHECKOUT_ROOT/agents/plan-security-reviewer.md"
if [[ ! -s "$PSR" ]]; then fail "plan-security-reviewer is not single-round" "file missing or empty; absence not provable"
elif grep -qF "Single-round only" "$PSR"; then fail "plan-security-reviewer is not single-round" "'Single-round only' still present"
else pass "plan-security-reviewer is not single-round"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
