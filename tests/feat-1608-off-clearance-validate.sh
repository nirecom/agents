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
C-g valid                     | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}  | workflow | [workflow-bug] please fix | true
TABLE

# ---------------------------------------------------------------------------
# #1625 (S-5) — reason-binding becomes a STRUCTURAL match, not a substring match.
#
# Old: reasonText.includes(token.category). Any occurrence of the category text
# anywhere in the reason satisfied the binding — including one buried mid-sentence,
# or a bare unbracketed mention that the sentinel grammar never intended as a
# category declaration. That makes the binding trivially satisfiable by prose.
# New: REASON_CATEGORY_RE = /^\s*\[([A-Za-z0-9-]+)\]/ — the category bracket must be
# the FIRST token of the reason, and the captured category must equal token.category.
#
# NOTE on C-g: it previously used the mid-sentence form `please [workflow-bug] fix`,
# which passed only because of the substring rule. It has been re-pinned to the
# leading-bracket form (the form bin/request-off-clearance actually instructs users
# to emit), so it stays green under BOTH the old and the new rule and the negative
# cases below carry the behavioural change on their own.
# Columns: name | token-js | target | reasonText | want(true|false)
VALID_TOK="{target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()}"
while IFS='|' read -r name target reason want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"
    target="$(trim "$target")"; reason="$(trim "$reason")"
    # @SP@ survives column trimming, so leading-whitespace cases stay meaningful.
    reason="${reason//@SP@/ }"
    got=$("$RWT" 10 node -e "
const {evaluateOffClearance}=require('$SM_NODE');
const token=$VALID_TOK;
process.stdout.write(String(evaluateOffClearance(token, process.argv[1], process.argv[2])));" "$target" "$reason" 2>/dev/null)
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
R-a bracket at start                  | workflow | [workflow-bug] please fix                  | true
R-b bracket at start + leading spaces | workflow | @SP@@SP@[workflow-bug] please fix          | true
R-c bracket NOT at start              | workflow | please [workflow-bug] fix                  | false
R-d bare category, no brackets        | workflow | workflow-bug is blocking me                | false
R-e wrong category in leading bracket | workflow | [convenience] just easier                  | false
R-f leading bracket + category later  | workflow | [convenience] but really workflow-bug      | false
R-g category as a substring of a word | workflow | [workflow-bugfix] please fix               | false
R-h empty bracket                     | workflow | [] workflow-bug                            | false
R-i unclosed bracket                  | workflow | [workflow-bug please fix                   | false
R-j prose before the bracket          | workflow | intro text [workflow-bug] fix              | false
TABLE

# Extra guard: token=null and non-object token → false (fail-CLOSED on garbage).
got=$("$RWT" 10 node -e "const {evaluateOffClearance}=require('$SM_NODE');process.stdout.write(String(evaluateOffClearance(null,'workflow','x')));" 2>/dev/null)
assert_eq "C-h null-token → false" "false" "$got"
got=$("$RWT" 10 node -e "const {evaluateOffClearance}=require('$SM_NODE');process.stdout.write(String(evaluateOffClearance('not-an-object','workflow','x')));" 2>/dev/null)
assert_eq "C-i string-token → false" "false" "$got"

# ============================================================================
# #1608 / #1625 (C6) - adversarial edge cases for evaluateOffClearance.
#
# Separate loop because the reason column is evaluated as JS too: some cases need
# a 5000-character string or an explicit non-string, which cannot be expressed as
# a trimmed bash table field.
#
# Fail-closed expectation: anything the grammar cannot prove is a well-formed,
# structurally-bound category is REJECTED. Cases marked (RED until S-5) currently
# return true only because the shipped rule is a bare `reasonText.includes(category)`
# substring test, which a malformed category satisfies by accident. They are the
# fail-before-fix cases for the structural REASON_CATEGORY_RE binding
# (/^\s*\[([A-Za-z0-9-]+)\]/ - so space, underscore and regex metacharacters can
# never form a valid category, however the reason is written).
#
# Expiry boundary: the contract is "expiresAt <= Date.now() -> expired", so a token
# whose expires_at is the current instant is already dead by the time the comparison
# runs. An exact-tick equality case cannot be made deterministic any other way
# (Date.now() advances between fixture construction and evaluation), so the boundary
# is pinned as now / now-1ms / now+2s and the <= semantics is what is asserted.
#
# got is normalised to <harness-error> on empty output so a node crash can never be
# mistaken for the literal string "false".
# Columns: name | token-js | target | reason-js | want(true|false)
while IFS='|' read -r name tokenjs target reasonjs want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"
    tokenjs="$(trim "$tokenjs")"; target="$(trim "$target")"; reasonjs="$(trim "$reasonjs")"
    got=$("$RWT" 10 node -e "
const {evaluateOffClearance}=require('$SM_NODE');
const token=$tokenjs;
const reason=$reasonjs;
process.stdout.write(String(evaluateOffClearance(token, process.argv[1], reason)));" "$target" 2>/dev/null)
    [ -z "$got" ] && got="<harness-error>"
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
E-a empty category                          | {target:'workflow',category:'',expires_at:new Date(Date.now()+900000).toISOString()}              | workflow | '[] please fix'                         | false
E-b missing category                        | {target:'workflow',expires_at:new Date(Date.now()+900000).toISOString()}                         | workflow | '[workflow-bug] please fix'             | false
E-c null category                           | {target:'workflow',category:null,expires_at:new Date(Date.now()+900000).toISOString()}           | workflow | '[workflow-bug] please fix'             | false
E-d numeric category                        | {target:'workflow',category:42,expires_at:new Date(Date.now()+900000).toISOString()}             | workflow | '[42] please fix'                       | false
E-e category with spaces (RED until S-5)    | {target:'workflow',category:'work flow bug',expires_at:new Date(Date.now()+900000).toISOString()} | workflow | '[work flow bug] please fix'           | false
E-f category with underscore (RED until S-5)| {target:'workflow',category:'work_flow',expires_at:new Date(Date.now()+900000).toISOString()}    | workflow | '[work_flow] please fix'                | false
E-g regex-metachar category (RED until S-5) | {target:'workflow',category:'.*',expires_at:new Date(Date.now()+900000).toISOString()}           | workflow | '[.*] please fix'                       | false
E-h injection-shaped category (RED until S-5)| {target:'workflow',category:'a);rm -r x;(',expires_at:new Date(Date.now()+900000).toISOString()} | workflow | '[a);rm -r x;(] please fix'             | false
E-i very long legit category                | {target:'workflow',category:'x'.repeat(5000),expires_at:new Date(Date.now()+900000).toISOString()} | workflow | '[' + 'x'.repeat(5000) + '] please fix' | true
E-j very long reason, short category        | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()} | workflow | '[workflow-bug] ' + 'y'.repeat(20000)   | true
E-k expiry exactly now                      | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()).toISOString()}        | workflow | '[workflow-bug] please fix'             | false
E-l expiry one tick before now              | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()-1).toISOString()}      | workflow | '[workflow-bug] please fix'             | false
E-m expiry two seconds after now            | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+2000).toISOString()}   | workflow | '[workflow-bug] please fix'             | true
E-n non-string reason (null)                | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()} | workflow | null                                    | false
E-o empty reason                            | {target:'workflow',category:'workflow-bug',expires_at:new Date(Date.now()+900000).toISOString()} | workflow | ''                                      | false
E-p array token                             | [1,2,3]                                                                                          | workflow | '[workflow-bug] please fix'             | false
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
