#!/usr/bin/env bash
# tests/feat-1761-review-verdict-validate/malformed-artifact.sh
# Tests: bin/github-issues/lib/validate-review-verdict.js
# Tags: issue-create, verdict, review, validator, malformed-artifact, table-driven, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - A survey artifact produced by a real LLM worker rather than hand-built here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Split out of tests/feat-1761-review-verdict-validate.sh (rules/coding/file-split.md
# Pattern A, 300-line WARN). The sibling file varies the REVIEW output against a
# well-formed artifact; this one varies the ARTIFACT against a well-formed review.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
VALIDATOR="$AGENTS_DIR/bin/github-issues/lib/validate-review-verdict.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

VALIDATOR_PRESENT=no; [ -f "$VALIDATOR" ] && VALIDATOR_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== E: malformed SURVEY artifacts — the other input, and the one not yet covered ==="
# Sections A–D vary the review output against a well-formed artifact. But the artifact
# is written by an LLM worker too, and the allowlists (CAND / PARENTS) are derived from
# it. A validator that trusted a malformed artifact would build an empty or bogus
# allowlist — and an empty allowlist silently accepts nothing OR everything depending
# on how the check is written. Both directions are dangerous, so every malformed
# artifact must be rejected outright rather than silently narrowing the allowlist.
VALID_REVIEW='{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect"}'

# run_validate_art <artifact-json-literal-or-path> <raw> → verdict word
run_validate_art() {
    local art="$1" raw="$2" out f="$WORK/mal.json"
    if [ "$VALIDATOR_PRESENT" != "yes" ]; then printf '<missing>'; return; fi
    if [ -f "$art" ]; then f="$art"; else printf '%s' "$art" > "$f"; fi
    printf '%s' "$raw" > "$WORK/mal-raw.txt"
    out=$(ISSUE_VERDICT_REVIEW=on ISSUE_PROVENANCE=off \
            "$RWT" 15 node "$(node_path "$VALIDATOR")" \
            --artifact "$(node_path "$f")" \
            --review-raw "$(node_path "$WORK/mal-raw.txt")" 2>/dev/null | head -n 1)
    printf '%s' "${out//[[:space:]]/}"
}

assert_art_invalid() {  # <name> <artifact-literal-or-path>
    local got; got=$(run_validate_art "$2" "$VALID_REVIEW")
    if [ "$got" = "<missing>" ]; then
        fail "$1" "RED-EXPECTED: validate-review-verdict.js not yet created"
    elif [ "$got" = "invalid" ]; then
        pass "$1"
    else
        fail "$1" "a malformed survey artifact must make the review invalid (got: $got)"
    fi
}

BASE_CANDS='{ "number": 10, "title": "c10", "state": "open", "labels": [], "body": "b",
  "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false }'

assert_art_invalid E1-wrong-schema-version \
  "{ \"schema_version\": 1, \"proposal\": {\"title\":\"T\",\"background\":\"B\",\"changes\":\"C\"},
     \"verdict\": \"none\", \"target\": null, \"children\": [], \"related\": [], \"reason\": \"r\",
     \"relations_mode\": \"batched\", \"relation_errors\": [], \"candidates\": [ $BASE_CANDS ] }"

assert_art_invalid E2-candidates-missing \
  '{ "schema_version": 2, "proposal": {"title":"T","background":"B","changes":"C"},
     "verdict": "none", "target": null, "children": [], "related": [], "reason": "r",
     "relations_mode": "batched", "relation_errors": [] }'

assert_art_invalid E3-candidates-not-an-array \
  '{ "schema_version": 2, "proposal": {"title":"T","background":"B","changes":"C"},
     "verdict": "none", "target": null, "children": [], "related": [], "reason": "r",
     "relations_mode": "batched", "relation_errors": [], "candidates": {"10": {}} }'

assert_art_invalid E4-candidate-number-is-a-string \
  '{ "schema_version": 2, "proposal": {"title":"T","background":"B","changes":"C"},
     "verdict": "none", "target": null, "children": [], "related": [], "reason": "r",
     "relations_mode": "batched", "relation_errors": [],
     "candidates": [ { "number": "10", "title": "c", "state": "open", "labels": [], "body": "b",
       "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false } ] }'

# Duplicate candidate numbers make the allowlist ambiguous: which #10 did the review mean?
assert_art_invalid E5-duplicate-candidate-numbers \
  "{ \"schema_version\": 2, \"proposal\": {\"title\":\"T\",\"background\":\"B\",\"changes\":\"C\"},
     \"verdict\": \"none\", \"target\": null, \"children\": [], \"related\": [], \"reason\": \"r\",
     \"relations_mode\": \"batched\", \"relation_errors\": [], \"candidates\": [ $BASE_CANDS, $BASE_CANDS ] }"

assert_art_invalid E6-candidate-missing-relation-fields \
  '{ "schema_version": 2, "proposal": {"title":"T","background":"B","changes":"C"},
     "verdict": "none", "target": null, "children": [], "related": [], "reason": "r",
     "relations_mode": "batched", "relation_errors": [],
     "candidates": [ { "number": 10, "title": "c", "state": "open", "labels": [], "body": "b" } ] }'

assert_art_invalid E7-survey-verdict-not-in-enum \
  "{ \"schema_version\": 2, \"proposal\": {\"title\":\"T\",\"background\":\"B\",\"changes\":\"C\"},
     \"verdict\": \"merge\", \"target\": null, \"children\": [], \"related\": [], \"reason\": \"r\",
     \"relations_mode\": \"batched\", \"relation_errors\": [], \"candidates\": [ $BASE_CANDS ] }"

assert_art_invalid E8-artifact-root-is-null 'null'
assert_art_invalid E9-artifact-is-an-array  '[]'
assert_art_invalid E10-artifact-truncated   '{ "schema_version": 2, "candidates": ['
assert_art_invalid E11-artifact-empty       ''

# A nonexistent artifact path is not the same defect as a malformed one, but must
# fold the same way — and must not be reported as "valid" by omission.
assert_art_invalid E12-artifact-missing-file "$WORK/definitely-not-here.json"

echo ""
echo "=== E14-E24: relation fields carry the wrong TYPE or an out-of-enum VALUE ==="
# E6 covers relation fields being absent. Present-but-wrong is the harder case and the
# more likely one: the fields are produced by an LLM worker from GraphQL output, so a
# string "true", a stringified number, or a status word the cascade never defined all
# arrive looking structurally plausible.
#
# These are not cosmetic. The cascade reads exactly these fields to decide the verdict:
#   relation_status  gates whether a candidate is eligible for IC-C2 / IC-C3 at all
#   parent_number    decides orphanhood, which is what make-parent is built on
#   parent_is_meta   decides whether sub-of may attach to that parent
# A validator that coerces instead of rejecting turns "unknown" into a truthy value and
# silently widens the allowlist the review's target is checked against.
cand() {  # <field-overrides-json-fragment> → a one-candidate artifact
    printf '{ "schema_version": 2, "proposal": {"title":"T","background":"B","changes":"C"},
     "verdict": "none", "target": null, "children": [], "related": [], "reason": "r",
     "relations_mode": "batched", "relation_errors": [],
     "candidates": [ { "number": 10, "title": "c", "state": "open", %s } ] }' "$1"
}

RS_OK='"relation_status": "resolved"'
PN_OK='"parent_number": null'
PM_OK='"parent_is_meta": false'
HS_OK='"has_sub_issues": false'
LB_OK='"labels": []'
BD_OK='"body": "b"'

while IFS='|' read -r name frag; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    assert_art_invalid "$name" "$(cand "$frag")"
done <<TABLE
E14-relation-status-unknown-word | $LB_OK, $BD_OK, "relation_status": "maybe", $PN_OK, $PM_OK, $HS_OK
E15-relation-status-not-a-string | $LB_OK, $BD_OK, "relation_status": true, $PN_OK, $PM_OK, $HS_OK
E16-relation-status-empty        | $LB_OK, $BD_OK, "relation_status": "", $PN_OK, $PM_OK, $HS_OK
E17-parent-number-string         | $LB_OK, $BD_OK, $RS_OK, "parent_number": "99", $PM_OK, $HS_OK
E18-parent-number-negative       | $LB_OK, $BD_OK, $RS_OK, "parent_number": -1, $PM_OK, $HS_OK
E19-parent-number-float          | $LB_OK, $BD_OK, $RS_OK, "parent_number": 9.5, $PM_OK, $HS_OK
E20-parent-number-zero           | $LB_OK, $BD_OK, $RS_OK, "parent_number": 0, $PM_OK, $HS_OK
E21-parent-is-meta-string        | $LB_OK, $BD_OK, $RS_OK, $PN_OK, "parent_is_meta": "true", $HS_OK
E22-has-sub-issues-number        | $LB_OK, $BD_OK, $RS_OK, $PN_OK, $PM_OK, "has_sub_issues": 1
E23-labels-not-an-array          | "labels": "type:task", $BD_OK, $RS_OK, $PN_OK, $PM_OK, $HS_OK
E24-body-not-a-string            | $LB_OK, "body": {"text":"b"}, $RS_OK, $PN_OK, $PM_OK, $HS_OK
TABLE

# E25 is the positive control for the whole block: the same shape with every relation
# field correct must NOT be rejected. Without it, a validator that refuses every
# artifact outright would pass E1-E24 and this file would prove nothing.
if [ "$VALIDATOR_PRESENT" != "yes" ]; then
    fail "E25-well-formed-relations-accepted" "RED-EXPECTED: validate-review-verdict.js not yet created"
else
    GOT=$(run_validate_art "$(cand "$LB_OK, $BD_OK, $RS_OK, $PN_OK, $PM_OK, $HS_OK")" "$VALID_REVIEW")
    if [ "$GOT" = "valid" ]; then pass "E25-well-formed-relations-accepted"
    else fail "E25-well-formed-relations-accepted" "a fully well-formed artifact was rejected (got: $GOT) — E14-E24 would be vacuous"; fi
fi

echo ""
echo "=== E13: extreme-length fields are rejected, not truncated into acceptance ==="
# Silent truncation would turn an over-long candidate list into a shorter allowlist,
# which changes which targets are accepted. Reject instead.
if [ "$VALIDATOR_PRESENT" != "yes" ]; then
    fail "E13-huge-candidate-list" "RED-EXPECTED: validate-review-verdict.js not yet created"
    fail "E13-huge-string-field"   "RED-EXPECTED: validate-review-verdict.js not yet created"
else
    node -e "
const fs = require('fs');
const cand = n => ({ number: n, title: 'c' + n, state: 'open', labels: [], body: 'b',
  relation_status: 'resolved', parent_number: null, parent_is_meta: false, has_sub_issues: false });
fs.writeFileSync(process.argv[1], JSON.stringify({ schema_version: 2,
  proposal: { title: 'T', background: 'B', changes: 'C' },
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  relations_mode: 'batched', relation_errors: [],
  candidates: Array.from({ length: 5000 }, (_, i) => cand(i + 1)) }));" "$(node_path "$WORK/huge.json")"
    GOT=$(run_validate_art "$WORK/huge.json" '{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect"}')
    [ "$GOT" = "invalid" ] && pass "E13-huge-candidate-list" \
        || fail "E13-huge-candidate-list" "a 5000-candidate artifact exceeds the documented 25-candidate ceiling and must be rejected (got: $GOT)"

    node -e "
const fs = require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({ schema_version: 2,
  proposal: { title: 'T', background: 'B', changes: 'C' },
  verdict: 'none', target: null, children: [], related: [], reason: 'r',
  relations_mode: 'batched', relation_errors: [],
  candidates: [ { number: 10, title: 'x'.repeat(1000000), state: 'open', labels: [], body: 'b',
    relation_status: 'resolved', parent_number: null, parent_is_meta: false, has_sub_issues: false } ] }));" \
      "$(node_path "$WORK/hugestr.json")"
    GOT=$(run_validate_art "$WORK/hugestr.json" '{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect"}')
    # Either verdict is defensible here; what must NOT happen is a crash or a hang,
    # which would surface as an empty first line.
    if [ "$GOT" = "valid" ] || [ "$GOT" = "invalid" ]; then
        pass "E13-huge-string-field"
    else
        fail "E13-huge-string-field" "a 1MB title must still produce a defined verdict (got: '${GOT:-<none>}')"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
