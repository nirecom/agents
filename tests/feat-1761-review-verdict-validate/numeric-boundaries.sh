#!/usr/bin/env bash
# tests/feat-1761-review-verdict-validate/numeric-boundaries.sh
# Tests: bin/github-issues/lib/validate-review-verdict.js
# Tags: issue-create, verdict, review, validator, boundary, numbers, table-driven, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether GitHub itself can ever mint an issue number near Number.MAX_SAFE_INTEGER.
#   It cannot today; the point of the row is that the validator's rule is stated over
#   the whole integer domain and does not quietly depend on numbers staying small.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Section of tests/feat-1761-review-verdict-validate.sh (subprocess; see
# tests/lib/section-runner.sh).
#
# Why this exists (CPR-UNV): every number in both inputs is attacker- or model-supplied
# and reaches the validator as raw JSON, where JavaScript has no integer type at all.
# The existing tables sample the numeric fields only at ordinary issue numbers, so the
# rules "positive integer" and "integer or null" are pinned nowhere near their edges —
# and each edge fails differently:
#
#   0                       falsy. Any `if (n)` guard silently treats it as absent.
#   negative                a valid JS integer; only an explicit `< 1` rejects it.
#   fractional (1.5)        Number.isInteger is the ONLY thing standing between this
#                           and an allowlist lookup that can never match.
#   Number.MAX_SAFE_INTEGER the largest integer JS represents exactly. It must be
#                           ACCEPTED where the rule says "positive integer" — a bound
#                           the rule does not state must not appear in the code.
#   MAX_SAFE_INTEGER + 1    still Number.isInteger === true, but no longer exactly
#                           representable. Pinned so the loss is a recorded fact rather
#                           than a surprise.
#
# Two field families, kept apart (CPR-SC): ARTIFACT numbers (candidates[].number,
# parent_number) are checked by validateArtifact with an explicit `< 1`; REVIEW numbers
# (target, children[], related[]) are checked only for integer-ness and then looked up
# in the allowlist. The same input therefore yields a different REASON on each side,
# and each row asserts the reason so a rejection cannot be credited to the wrong rule.

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

MAXSAFE=9007199254740991      # Number.MAX_SAFE_INTEGER
OVERSAFE=9007199254740992     # MAX_SAFE_INTEGER + 1 — still an integer, no longer exact

# mk_artifact <path> <candidate-number-json> <parent-number-json>
# CAND always also contains #10 and #11 so that make-parent/sibling rows stay
# expressible and no row can fail merely for want of a second candidate.
mk_artifact() {
    CN="$2" PN="$3" "$RWT" 15 node -e '
const fs = require("fs");
const base = (n) => ({ number: n, title: "c" + n, state: "open", labels: [], body: "b",
  relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false });
const probe = base(JSON.parse(process.env.CN));
probe.parent_number = JSON.parse(process.env.PN);
if (probe.parent_number !== null) probe.parent_is_meta = true;
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  proposal: { title: "T", background: "B", changes: "C" },
  verdict: "none", same_fix: false, target: null, children: [], related: [],
  reason: "survey reason", relations_mode: "batched", relation_errors: [],
  candidates: [probe, base(10), base(11)]
}, null, 2));' "$(node_path "$1")"
}

# A clean artifact for the review-side rows: CAND = {10, 11, 12}, no exotic numbers.
# The probe number must differ from 10/11 — mk_artifact always emits those two, and a
# repeat would be rejected by the duplicate-candidate check for the wrong reason.
mk_artifact "$WORK/clean.json" 12 null
CLEAN="$WORK/clean.json"

run_validate() {  # <artifact> <raw>
    VERDICT='<missing>'; REASON=''
    [ "$VALIDATOR_PRESENT" = "yes" ] || return 0
    printf '%s' "$2" > "$WORK/raw.txt"
    local out
    out=$("$RWT" 15 node "$(node_path "$VALIDATOR")" \
            --artifact "$(node_path "$1")" --review-raw "$(node_path "$WORK/raw.txt")" 2>/dev/null)
    VERDICT=$(printf '%s\n' "$out" | sed -n '1p'); VERDICT="${VERDICT//[[:space:]]/}"
    REASON=$(printf '%s\n' "$out" | sed -n '2p')
}

# assert_num <label> <want valid|invalid> <reason-needle | -> <artifact> <raw>
assert_num() {
    local label="$1" want="$2" needle="$3"
    run_validate "$4" "$5"
    if [ "$VERDICT" = '<missing>' ]; then
        fail "$label" "RED-EXPECTED: validate-review-verdict.js not found"
    elif [ "$VERDICT" != "$want" ]; then
        fail "$label" "want '$want' (got: '${VERDICT:-<none>}'${REASON:+, reason: $REASON})"
    elif [ "$needle" = "-" ]; then
        pass "$label"
    elif printf '%s' "$REASON" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label" "rejected, but not by the rule under test — the reason must name '$needle' (got: '${REASON:-<none>}')"
    fi
}

OK_REVIEW='{"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true,"same_fix":false}'

echo "=== N1: artifact candidates[].number across the integer domain ==="
# N1a is the non-vacuity control for the whole group: an ordinary number must pass, so
# every rejection below is attributable to the boundary value and not to the fixture.
mk_artifact "$WORK/n-ok.json"    12  null;  assert_num N1a-number-ordinary        valid   -                             "$WORK/n-ok.json"    "$OK_REVIEW"
mk_artifact "$WORK/n-one.json"   1   null;  assert_num N1b-number-1-lower-bound   valid   -                             "$WORK/n-one.json"   "$OK_REVIEW"
mk_artifact "$WORK/n-zero.json"  0   null;  assert_num N1c-number-zero            invalid "candidate number must be a positive integer" "$WORK/n-zero.json"  "$OK_REVIEW"
mk_artifact "$WORK/n-neg.json"   -1  null;  assert_num N1d-number-negative        invalid "candidate number must be a positive integer" "$WORK/n-neg.json"   "$OK_REVIEW"
mk_artifact "$WORK/n-frac.json"  1.5 null;  assert_num N1e-number-fractional      invalid "candidate number must be a positive integer" "$WORK/n-frac.json"  "$OK_REVIEW"
# MAX_SAFE_INTEGER is a positive integer, so the stated rule must admit it. A row that
# went red here would mean an undocumented ceiling had been introduced.
mk_artifact "$WORK/n-max.json"  "$MAXSAFE"  null; assert_num N1f-number-max-safe-integer valid - "$WORK/n-max.json" "$OK_REVIEW"
# Still Number.isInteger, so still admitted — recorded deliberately. The exactness loss
# above MAX_SAFE_INTEGER is a JSON-number property, not something this validator can fix.
mk_artifact "$WORK/n-over.json" "$OVERSAFE" null; assert_num N1g-number-above-max-safe-still-integer valid - "$WORK/n-over.json" "$OK_REVIEW"

echo ""
echo "=== N2: artifact candidates[].parent_number across the integer domain ==="
# parent_number carries an extra admissible value (null) that number does not, so the
# null row is the one that keeps "must be null or a positive integer" honest.
mk_artifact "$WORK/p-null.json" 12 null;              assert_num N2a-parent-null          valid   -                                                   "$WORK/p-null.json" "$OK_REVIEW"
mk_artifact "$WORK/p-ok.json"   12 99;                assert_num N2b-parent-ordinary      valid   -                                                   "$WORK/p-ok.json"   "$OK_REVIEW"
mk_artifact "$WORK/p-one.json"  12 1;                 assert_num N2c-parent-1-lower-bound valid   -                                                   "$WORK/p-one.json"  "$OK_REVIEW"
mk_artifact "$WORK/p-zero.json" 12 0;                 assert_num N2d-parent-zero          invalid "parent_number must be null or a positive integer"  "$WORK/p-zero.json" "$OK_REVIEW"
mk_artifact "$WORK/p-neg.json"  12 -1;                assert_num N2e-parent-negative      invalid "parent_number must be null or a positive integer"  "$WORK/p-neg.json"  "$OK_REVIEW"
mk_artifact "$WORK/p-frac.json" 12 2.5;               assert_num N2f-parent-fractional    invalid "parent_number must be null or a positive integer"  "$WORK/p-frac.json" "$OK_REVIEW"
mk_artifact "$WORK/p-max.json"  12 "$MAXSAFE";        assert_num N2g-parent-max-safe      valid   -                                                   "$WORK/p-max.json"  "$OK_REVIEW"

echo ""
echo "=== N3: review target across the integer domain ==="
# Different rule, different failure. 0 / -1 / MAX_SAFE_INTEGER are integers, so they
# clear the type gate and are rejected by the ALLOWLIST; 1.5 never gets that far.
# Asserting the two reasons apart is what proves the type gate exists at all: an
# implementation with no Number.isInteger check would reject 1.5 too, but for the
# allowlist reason, and N3d would catch it.
rt() { printf '{"verdict":"reopen","target":%s,"children":[],"related":[],"reason":"same root cause","worth_filing":true,"same_fix":true}' "$1"; }
assert_num N3a-target-in-allowlist       valid   -                                             "$CLEAN" "$(rt 10)"
assert_num N3b-target-zero               invalid "reopen: target must be one of the surveyed candidates" "$CLEAN" "$(rt 0)"
assert_num N3c-target-negative           invalid "reopen: target must be one of the surveyed candidates" "$CLEAN" "$(rt -1)"
assert_num N3d-target-fractional         invalid "target must be an integer or null"           "$CLEAN" "$(rt 1.5)"
assert_num N3e-target-max-safe           invalid "reopen: target must be one of the surveyed candidates" "$CLEAN" "$(rt "$MAXSAFE")"

echo ""
echo "=== N4: review children[] / related[] across the integer domain ==="
mkp() { printf '{"verdict":"make-parent","target":null,"children":[%s],"related":[],"reason":"one theme","worth_filing":true,"same_fix":false}' "$1"; }
sib() { printf '{"verdict":"sibling","target":null,"children":[],"related":[%s],"reason":"adjacent","worth_filing":true,"same_fix":false}' "$1"; }

assert_num N4a-children-in-allowlist  valid   -                                       "$CLEAN" "$(mkp '10,11')"
assert_num N4b-children-zero          invalid "make-parent: children must all be surveyed candidates" "$CLEAN" "$(mkp '0,10')"
assert_num N4c-children-negative      invalid "make-parent: children must all be surveyed candidates" "$CLEAN" "$(mkp '-1,10')"
assert_num N4d-children-fractional    invalid "children must be an array of integers" "$CLEAN" "$(mkp '1.5,10')"
assert_num N4e-children-max-safe      invalid "make-parent: children must all be surveyed candidates" "$CLEAN" "$(mkp "$MAXSAFE,10")"

assert_num N4f-related-in-allowlist   valid   -                                       "$CLEAN" "$(sib 10)"
assert_num N4g-related-zero           invalid "sibling: related must all be surveyed candidates" "$CLEAN" "$(sib 0)"
assert_num N4h-related-negative       invalid "sibling: related must all be surveyed candidates" "$CLEAN" "$(sib -1)"
assert_num N4i-related-fractional     invalid "related must be an array of integers" "$CLEAN" "$(sib 1.5)"
assert_num N4j-related-max-safe       invalid "sibling: related must all be surveyed candidates" "$CLEAN" "$(sib "$MAXSAFE")"

echo ""
echo "=== N5: an exotic number that IS in the allowlist round-trips ==="
# The counterweight for N1f/N2g/N3e/N4e: those rows show a large integer is rejected by
# the allowlist, which would also be the observed result if the validator had truncated
# it to something else. Surveying MAX_SAFE_INTEGER and then naming it must be VALID —
# so the number that came out is the number that went in.
mk_artifact "$WORK/max-cand.json" "$MAXSAFE" null
assert_num N5-max-safe-target-accepted-when-surveyed valid - "$WORK/max-cand.json" "$(rt "$MAXSAFE")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
