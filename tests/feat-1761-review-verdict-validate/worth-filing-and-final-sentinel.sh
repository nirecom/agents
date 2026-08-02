#!/usr/bin/env bash
# tests/feat-1761-review-verdict-validate/worth-filing-and-final-sentinel.sh
# Tests: bin/github-issues/lib/validate-review-verdict.js, bin/lib/last-json-object.js
# Tags: issue-create, verdict, review, validator, worth-filing, final-verdict-sentinel, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - A real `codex exec` transcript, where the prose before the sentinel is model output
#   rather than a hand-written fixture.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Two additions to the validator land in the same PR and are tested together here
# because they share one input (the raw review text) and one output (the parsed verdict):
#
#   1. `worth_filing` becomes a REQUIRED boolean on the review verdict. It is the
#      confirm gate's G3 input, replacing the deleted provenance token — so a missing,
#      stringified or null value must be rejected outright rather than coerced. A
#      coerced `"false"` is truthy and would silently flip G3 the wrong way.
#   2. The raw text is scoped to whatever follows the LAST `FINAL_VERDICT_JSON:`
#      sentinel. With web search enabled the reviewer's prose can legitimately quote
#      JSON it found; under the old whole-text "exactly one object" rule that quoted
#      object would collide with the real answer and fold the review to `invalid`.

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

# CAND = {10, 11}; both resolved and parentless, so reopen/none/sibling are expressible.
cat > "$WORK/batched.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "open", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "closed", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

# run_validate <raw-review-text> → sets VERDICT and REASON
run_validate() {
    VERDICT='<missing>'; REASON=''
    [ "$VALIDATOR_PRESENT" = "yes" ] || return 0
    printf '%b' "$1" > "$WORK/raw.txt"
    local out
    out=$("$RWT" 15 node "$(node_path "$VALIDATOR")" \
            --artifact "$(node_path "$WORK/batched.json")" \
            --review-raw "$(node_path "$WORK/raw.txt")" 2>/dev/null)
    VERDICT=$(printf '%s\n' "$out" | sed -n '1p'); VERDICT="${VERDICT//[[:space:]]/}"
    REASON=$(printf '%s\n' "$out" | sed -n '2p')
}

# assert_verdict <label> <want> <raw>
assert_verdict() {
    local label="$1" want="$2"
    run_validate "$3"
    if [ "$VERDICT" = '<missing>' ]; then
        fail "$label" "RED-EXPECTED: validate-review-verdict.js not yet created (want=$want)"
    elif [ "$VERDICT" = "$want" ]; then
        pass "$label"
    else
        fail "$label" "want '$want' (got: '${VERDICT:-<none>}'${REASON:+, reason: $REASON})"
    fi
}

echo "=== W: worth_filing is a REQUIRED boolean on the review verdict ==="

BASE='"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches"'

# W1/W5 are the pair that makes the rest non-vacuous: the identical verdict differs
# only in worth_filing, so a validator that ignored the field entirely would fail W1
# while a validator that rejected everything would fail W5.
assert_verdict W1-worth-filing-missing   invalid "{$BASE}"
assert_verdict W5-worth-filing-true      valid   "{$BASE,\"worth_filing\":true}"
# `false` is the value the confirm gate actually acts on (G3 fires on NOT-true), so it
# must be accepted, not treated as an absent field.
assert_verdict W4-worth-filing-false     valid   "{$BASE,\"worth_filing\":false}"
assert_verdict W2-worth-filing-string    invalid "{$BASE,\"worth_filing\":\"true\"}"
assert_verdict W3-worth-filing-null      invalid "{$BASE,\"worth_filing\":null}"
assert_verdict W6-worth-filing-number    invalid "{$BASE,\"worth_filing\":1}"
assert_verdict W7-worth-filing-string-no invalid "{$BASE,\"worth_filing\":\"false\"}"

# The reason line has to name the offending field: the caller folds every invalid
# review the same way, so the reason string is the only diagnostic a human gets.
if [ "$VALIDATOR_PRESENT" != "yes" ]; then
    fail "W8-reason-names-worth-filing" "RED-EXPECTED: validate-review-verdict.js not yet created"
else
    run_validate "{$BASE}"
    if printf '%s' "$REASON" | grep -qF 'worth_filing'; then
        pass "W8-reason-names-worth-filing"
    else
        fail "W8-reason-names-worth-filing" "the invalid reason must name worth_filing (got: '${REASON:-<none>}')"
    fi
fi

echo ""
echo "=== S: raw text is scoped to the LAST FINAL_VERDICT_JSON: sentinel ==="

GOOD="{\"verdict\":\"reopen\",\"target\":10,\"children\":[],\"related\":[],\"reason\":\"same root cause\",\"worth_filing\":true}"
OTHER="{\"verdict\":\"none\",\"target\":null,\"children\":[],\"related\":[],\"reason\":\"different\",\"worth_filing\":false}"

# S1 is the whole point: a reviewer that quoted a JSON object while reasoning (now
# likely, because web search is enabled) used to collide with its own answer.
assert_verdict S1-prose-json-then-sentinel valid \
    "I searched and found this payload: $OTHER\nFINAL_VERDICT_JSON:\n$GOOD"

# Cardinality is still enforced — but only over the scoped tail.
assert_verdict S2-two-objects-after-sentinel invalid \
    "FINAL_VERDICT_JSON:\n$GOOD\n$OTHER"

# Only the LAST sentinel counts: a reviewer that restated its answer must be read at
# its final word, not its first.
assert_verdict S3-last-sentinel-wins valid \
    "FINAL_VERDICT_JSON:\n$GOOD\n$OTHER\nOn reflection:\nFINAL_VERDICT_JSON:\n$OTHER"

# ... and the converse: a well-formed earlier block cannot rescue a malformed last one.
assert_verdict S4-last-sentinel-malformed invalid \
    "FINAL_VERDICT_JSON:\n$GOOD\nOn reflection:\nFINAL_VERDICT_JSON:\n{\"verdict\":\"reopen\",\"target\":4242,\"children\":[],\"related\":[],\"reason\":\"not a candidate\",\"worth_filing\":true}"

# A sentinel with nothing after it is an empty answer, not a licence to fall back to
# the prose above it — falling back would resurrect the collision S1 exists to remove.
assert_verdict S5-sentinel-with-empty-tail invalid \
    "$GOOD\nFINAL_VERDICT_JSON:\n"

# Legacy shape (no sentinel at all) keeps the whole-text reading: the reviewer prompt
# is changing in the same PR, but an in-flight review written before the change must
# still validate rather than fold to invalid.
assert_verdict S6-no-sentinel-single-object valid \
    "Reasoning...\nHere is my answer:\n$GOOD"
assert_verdict S7-no-sentinel-two-objects invalid "$GOOD\n$OTHER"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
