#!/usr/bin/env bash
# tests/feat-1912-same-fix-crosscheck/value-class-matrix.sh
# Tests: bin/github-issues/lib/validate-review-verdict.js
# Tags: issue-create, verdict, review, validator, same-fix, table-driven, matrix, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether a real producer (survey worker / codex) ever emits these value classes.
#   This file pins only what the validator does when one arrives.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Section of tests/feat-1912-same-fix-crosscheck.sh (run as a subprocess by the parent;
# see tests/lib/section-runner.sh).
#
# The parent probes missing/null/non-boolean against `none` alone, which assumes the type
# check is verdict-independent — true today, pinned nowhere. This file is the full cross
# product: every verdict × every value class, on both producers.
#
# Every row also asserts ATTRIBUTION: "invalid" alone cannot distinguish a same_fix
# rejection from an incidental shape defect. The two `bulk-sub-of` rows are the
# counterweight (rejected for a documented non-same_fix cause) — without them an
# implementation that answered "same_fix" to everything would pass the whole file.

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

# ---------------------------------------------------------------------------
# Fixtures. CAND = {10, 11}, both resolved orphans, so every verdict is expressible.
# ---------------------------------------------------------------------------
mk_artifact() {  # <path> <verdict> <same_fix-json | __OMIT__>
    V="$2" SF="$3" "$RWT" 15 node -e '
const fs = require("fs");
const a = {
  schema_version: 3,
  proposal: { title: "T", background: "B", changes: "C" },
  verdict: process.env.V, target: null, children: [], related: [],
  reason: "survey reason",
  relations_mode: "batched", relation_errors: [],
  candidates: [
    { number: 10, title: "c10", state: "open", labels: [], body: "b10",
      relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false },
    { number: 11, title: "c11", state: "open", labels: [], body: "b11",
      relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false }
  ]
};
if (process.env.SF !== "__OMIT__") a.same_fix = JSON.parse(process.env.SF);
fs.writeFileSync(process.argv[1], JSON.stringify(a, null, 2));' "$(node_path "$1")"
}

run_validate() {  # <artifact> <raw review text> → VERDICT, REASON
    VERDICT='<missing>'; REASON=''
    [ "$VALIDATOR_PRESENT" = "yes" ] || return 0
    printf '%s' "$2" > "$WORK/raw.txt"
    local out
    out=$("$RWT" 15 node "$(node_path "$VALIDATOR")" \
            --artifact "$(node_path "$1")" \
            --review-raw "$(node_path "$WORK/raw.txt")" 2>/dev/null)
    VERDICT=$(printf '%s\n' "$out" | sed -n '1p'); VERDICT="${VERDICT//[[:space:]]/}"
    REASON=$(printf '%s\n' "$out" | sed -n '2p')
}

# assert_cell <label> <want valid|invalid> <want-reason-names: same_fix|not-same_fix|-> <artifact> <raw>
# One helper for routing + attribution, so a row cannot assert one without the other.
assert_cell() {
    local label="$1" want="$2" attr="$3"
    run_validate "$4" "$5"
    if [ "$VERDICT" = '<missing>' ]; then
        fail "$label" "RED-EXPECTED: validate-review-verdict.js not found"
        return
    fi
    if [ "$VERDICT" != "$want" ]; then
        fail "$label" "want '$want' (got: '${VERDICT:-<none>}'${REASON:+, reason: $REASON})"
        return
    fi
    case "$attr" in
        same_fix)
            if printf '%s' "$REASON" | grep -qF -- 'same_fix'; then
                pass "$label"
            else
                fail "$label" "rejected correctly but for the wrong cause — the reason must name same_fix (got: '${REASON:-<none>}')"
            fi ;;
        not-same_fix)
            if printf '%s' "$REASON" | grep -qF -- 'same_fix'; then
                fail "$label" "this row is rejected for a documented NON-same_fix cause, but the reason names same_fix (got: '${REASON:-<none>}') — same_fix attribution is being over-applied"
            else
                pass "$label"
            fi ;;
        *)  pass "$label" ;;
    esac
}

# The six value classes:
#   correct  → the SAME_FIX_BY_VERDICT value (non-vacuity counterweight)
#   wrong    → its negation
#   missing  → key absent
#   null     → JSON null
#   string   → "true": truthy in JS, so a coercing implementation accepts it
#   number   → 1: a separate class because `typeof v === "string" ? ... : v` rejects only
#              the string, and JSON producers emit 1/0 for booleans routinely.
# `reopen` is the only verdict whose correct value is true (parent X4–X9); kept as data
# so a future flip is a one-line diff.
sf_for() { case "$1" in reopen) printf 'true' ;; *) printf 'false' ;; esac; }
not_sf_for() { case "$1" in reopen) printf 'false' ;; *) printf 'true' ;; esac; }

OK_REVIEW='{"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true,"same_fix":false}'

echo "=== E: artifact side — every verdict × every same_fix value class ==="
# `bulk-sub-of` is artifact-only: a well-formed one folds to invalid on the review
# grammar, but the artifact same_fix check runs BEFORE that fold — so the defective
# classes must still be attributed to same_fix and the `correct` row must not be.
for V in none reopen sub-of bulk-sub-of make-parent sibling; do
    OKV="$(sf_for "$V")"; BADV="$(not_sf_for "$V")"

    if [ "$V" = "bulk-sub-of" ]; then
        WANT_OK=invalid; ATTR_OK=not-same_fix
    else
        WANT_OK=valid;   ATTR_OK=-
    fi

    mk_artifact "$WORK/e-ok.json"      "$V" "$OKV"
    mk_artifact "$WORK/e-wrong.json"   "$V" "$BADV"
    mk_artifact "$WORK/e-missing.json" "$V" '__OMIT__'
    mk_artifact "$WORK/e-null.json"    "$V" 'null'
    mk_artifact "$WORK/e-string.json"  "$V" '"true"'
    mk_artifact "$WORK/e-number.json"  "$V" '1'

    assert_cell "E-$V-correct-$OKV"  "$WANT_OK" "$ATTR_OK" "$WORK/e-ok.json"      "$OK_REVIEW"
    assert_cell "E-$V-wrong-$BADV"   invalid    same_fix   "$WORK/e-wrong.json"   "$OK_REVIEW"
    assert_cell "E-$V-missing"       invalid    same_fix   "$WORK/e-missing.json" "$OK_REVIEW"
    assert_cell "E-$V-null"          invalid    same_fix   "$WORK/e-null.json"    "$OK_REVIEW"
    assert_cell "E-$V-string"        invalid    same_fix   "$WORK/e-string.json"  "$OK_REVIEW"
    assert_cell "E-$V-number"        invalid    same_fix   "$WORK/e-number.json"  "$OK_REVIEW"
done

echo ""
echo "=== F: review side — every verdict × every same_fix value class ==="
# The artifact is held at `none`/false throughout, so every F row is decided by the
# REVIEW's own same_fix, never by the artifact's.
ART="$WORK/f-artifact.json"
mk_artifact "$ART" none false

# Per-verdict review shapes; `%s` is where the same_fix fragment is appended.
review_body() {  # <verdict> <same_fix-fragment-or-empty>
    local v="$1" sf="$2"
    case "$v" in
        none)        printf '{"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true%s}' "$sf" ;;
        reopen)      printf '{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same root cause","worth_filing":true%s}' "$sf" ;;
        sub-of)      printf '{"verdict":"sub-of","target":10,"children":[],"related":[],"reason":"belongs under it","worth_filing":true%s}' "$sf" ;;
        make-parent) printf '{"verdict":"make-parent","target":null,"children":[10,11],"related":[],"reason":"one theme","worth_filing":true%s}' "$sf" ;;
        sibling)     printf '{"verdict":"sibling","target":null,"children":[],"related":[10],"reason":"adjacent","worth_filing":true%s}' "$sf" ;;
        bulk-sub-of) printf '{"verdict":"bulk-sub-of","target":10,"children":[],"related":[],"reason":"bulk route","worth_filing":true%s}' "$sf" ;;
    esac
}

for V in none reopen sub-of make-parent sibling; do
    OKV="$(sf_for "$V")"; BADV="$(not_sf_for "$V")"
    assert_cell "F-$V-correct-$OKV" valid   -        "$ART" "$(review_body "$V" ",\"same_fix\":$OKV")"
    assert_cell "F-$V-wrong-$BADV"  invalid same_fix "$ART" "$(review_body "$V" ",\"same_fix\":$BADV")"
    assert_cell "F-$V-missing"      invalid same_fix "$ART" "$(review_body "$V" "")"
    assert_cell "F-$V-null"         invalid same_fix "$ART" "$(review_body "$V" ',"same_fix":null')"
    assert_cell "F-$V-string"       invalid same_fix "$ART" "$(review_body "$V" ',"same_fix":"true"')"
    assert_cell "F-$V-number"       invalid same_fix "$ART" "$(review_body "$V" ',"same_fix":1')"
done

# Review-side counterweight: `bulk-sub-of` is outside the review grammar, so it must be
# rejected on the VERDICT despite a deliberately wrong same_fix — reaching the cross-check
# would mean indexing SAME_FIX_BY_VERDICT with an unvalidated verdict.
assert_cell "F-bulk-sub-of-rejected-on-verdict-not-same-fix" invalid not-same_fix \
    "$ART" "$(review_body bulk-sub-of ',"same_fix":true')"

# Same shape with the "correct" value: the verdict check genuinely precedes same_fix.
assert_cell "F-bulk-sub-of-rejected-regardless-of-same-fix" invalid not-same_fix \
    "$ART" "$(review_body bulk-sub-of ',"same_fix":false')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
