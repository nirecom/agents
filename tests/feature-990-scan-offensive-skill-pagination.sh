#!/bin/bash
# tests/feature-990-scan-offensive-skill-pagination.sh
# Tests: skills/scan-offensive/scripts/scan-repo.sh
# Tags: scan, offensive, skill, pagination, jsonl, scope:issue-specific
# RED for issue #990 — retroactive scan-repo.sh must:
#   - paginate via `gh api repos/{owner}/{repo}/issues?state=all&per_page=100 --paginate`
#   - exclude PRs via `select(.pull_request == null)` jq filter
#   - use JSONL-safe per-object loop (jq -c '.[]' piped to while-read)
#   - invoke `bin/scan-offensive --stdin` for each issue body
#
# Static content check: since scan-repo.sh does not yet exist, the test asserts
# the required patterns appear in the script source once it is written.
#
# L3 gap (what this test does NOT catch):
# - real `gh api` pagination behavior against GitHub
# - real issue-edit redaction round-trip
# Closest-to-action mitigation: manual dry-run on a sample repo before applying.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/skills/scan-offensive/scripts/scan-repo.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_script() {
    if [ ! -f "$SCRIPT" ]; then
        skip "$1 (skills/scan-offensive/scripts/scan-repo.sh not implemented yet)"
        return 1
    fi
    return 0
}

run_p1() {
    require_script "P1: uses gh api repos/{owner}/{repo}/issues with --paginate (not gh issue list)" || return
    # Must contain a `gh api .../issues` call with state=all and per_page=100 and --paginate.
    # Must NOT use `gh issue list --paginate` (issue list does not support paginate flag).
    local ok=1
    if ! grep -Eq 'repos/.*issues.*state=all|state=all.*repos/.*issues|ISSUE_QUERY=.*state=all' "$SCRIPT"; then
        ok=0
    fi
    if ! grep -Eq 'per_page=100' "$SCRIPT"; then
        ok=0
    fi
    if ! grep -Eq '\-\-paginate' "$SCRIPT"; then
        ok=0
    fi
    if grep -Eq 'gh[[:space:]]+issue[[:space:]]+list[[:space:]]+[^|;&]*--paginate' "$SCRIPT"; then
        ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        pass "P1: uses gh api repos/{owner}/{repo}/issues with --paginate"
    else
        fail "P1: required pagination pattern not found in $SCRIPT"
    fi
}

run_p2() {
    require_script "P2: excludes PRs via select(.pull_request == null)" || return
    if grep -Fq 'select(.pull_request == null)' "$SCRIPT"; then
        pass "P2: excludes PRs via select(.pull_request == null)"
    else
        fail "P2: jq PR-exclusion filter not found in $SCRIPT"
    fi
}

run_p3() {
    require_script "P3: JSONL-safe per-object loop (jq -c '.[]' + while-read)" || return
    local has_jq_c=0 has_while_read=0
    # Look for `jq -c` somewhere paired with `.[]` and a `while IFS= read -r` loop.
    if grep -Eq "jq[[:space:]]+(-[a-zA-Z]*c[a-zA-Z]*)[[:space:]]+'[^']*\.\[\]" "$SCRIPT" \
       || grep -Eq 'jq[[:space:]]+(-[a-zA-Z]*c[a-zA-Z]*)[[:space:]]+"[^"]*\.\[\]' "$SCRIPT"; then
        has_jq_c=1
    fi
    if grep -Eq 'while[[:space:]]+IFS=[[:space:]]*read[[:space:]]+-r' "$SCRIPT"; then
        has_while_read=1
    fi
    if [ "$has_jq_c" -eq 1 ] && [ "$has_while_read" -eq 1 ]; then
        pass "P3: JSONL-safe per-object loop present"
    else
        fail "P3: jq -c '.[]'=$has_jq_c, while IFS= read -r=$has_while_read"
    fi
}

run_p4() {
    require_script "P4: calls bin/scan-offensive --stdin for each item" || return
    # Must reference bin/scan-offensive or $SCANNER with --stdin somewhere
    if grep -Eq '(\$SCANNER|scan-offensive).*--stdin' "$SCRIPT"; then
        pass "P4: calls bin/scan-offensive --stdin"
    else
        fail "P4: bin/scan-offensive --stdin invocation not found in $SCRIPT"
    fi
}

run_p5() {
    require_script "P5: apply mode calls gh issue edit for redaction" || return
    if grep -Eq 'gh[[:space:]]+issue[[:space:]]+edit' "$SCRIPT"; then
        pass "P5: apply mode calls gh issue edit"
    else
        fail "P5: gh issue edit redaction call not found in $SCRIPT"
    fi
}

run_p1
run_p2
run_p3
run_p4
run_p5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
