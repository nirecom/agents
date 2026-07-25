#!/usr/bin/env bash
# tests/feat-1608-off-clearance-validate.sh
# Tests: hooks/lib/session-markers.js
# Tags: off-clearance, validator, evaluate-off-clearance, fail-closed, session-markers, scope:issue-specific, pwsh-not-required, TL1
#
# #1608: evaluateOffClearance(token, target, reasonText) is the single fail-CLOSED
# SSOT validator for OFF-clearance tokens. A token is valid iff it is unexpired, its
# target matches the requested target, and its category appears as a substring of the
# emitted sentinel reason (reason-binding). Malformed/absent expiry metadata is treated
# as EXPIRED (a token that cannot prove it is live is not live). Pure node require — no
# subprocess — so this is TL1 and carries no TL3 gap.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
SM_NODE="$_AGENTS_DIR_NODE/hooks/lib/session-markers.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# Table-driven (parser-regex-tests.md). token-js is evaluated inside a node harness so
# future/past ISO timestamps are generated in-process; the validator's own Date() use is
# irrelevant to any workflow-script Date ban (this is a test harness, not a workflow script).
# Columns: name | token-js | target | reasonText | want(true|false)
while IFS='|' read -r name tokenjs target reason want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
    tokenjs="$(trim "$tokenjs")"; target="$(trim "$target")"; reason="$(trim "$reason")"
    got=$("$RWT" 10 node -e "
const {evaluateOffClearance}=require('$SM_NODE');
const token=$tokenjs;
process.stdout.write(String(evaluateOffClearance(token, process.argv[1], process.argv[2])));" "$target" "$reason" 2>/dev/null)
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
C-a missing-expires_at        | {target:'workflow',category:'workflow-bug'}                                                       | workflow | x workflow-bug y | false
C-b1 expires_at-number        | {target:'workflow',category:'workflow-bug',expires_at:12345}                                      | workflow | x workflow-bug y | false
C-b2 expires_at-object        | {target:'workflow',category:'workflow-bug',expires_at:{}}                                         | workflow | x workflow-bug y | false
C-c expires_at-unparseable    | {target:'workflow',category:'workflow-bug',expires_at:'not-a-date'}                               | workflow | x workflow-bug y | false
C-d expires_at-past           | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()-60000).toISOString()}   | workflow | x workflow-bug y | false
C-e target-mismatch           | {target:'worktree',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}  | workflow | x workflow-bug y | false
C-f reason-missing-category   | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}  | workflow | no category here  | false
C-g valid                     | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}  | workflow | please [workflow-bug] fix | true
TABLE

# Extra guard: token=null and non-object token → false (fail-CLOSED on garbage).
got=$("$RWT" 10 node -e "const {evaluateOffClearance}=require('$SM_NODE');process.stdout.write(String(evaluateOffClearance(null,'workflow','x')));" 2>/dev/null)
assert_eq "C-h null-token → false" "false" "$got"
got=$("$RWT" 10 node -e "const {evaluateOffClearance}=require('$SM_NODE');process.stdout.write(String(evaluateOffClearance('not-an-object','workflow','x')));" 2>/dev/null)
assert_eq "C-i string-token → false" "false" "$got"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
