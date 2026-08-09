#!/usr/bin/env bash
# tests/feat-1912-same-fix-fold.sh
# Tests: bin/github-issues/review-survey-verdict-codex.sh, bin/github-issues/lib/validate-review-verdict.js
# Tags: issue-create, verdict, review, same-fix, fold, artifact, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether a real `codex exec` emits a FINAL_VERDICT_JSON block in the shape the mock
#   emits, and whether a real reviewer's same_fix agrees with its own verdict. The mock
#   is scripted; only a real-model run exercises the reviewer's judgment.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# `same_fix` appears three times in the FINAL artifact:
#   survey.same_fix  — what the survey concluded, always preserved
#   review.same_fix  — what the reviewer answered, or null when there was no usable review
#   .same_fix        — the operative value downstream reads, folded from one of the two
# The fold has two branches (`replaced` takes the review's fields, every other status holds
# the survey's); both are exercised with a survey value of `true` AND `false`, since a
# single-polarity test passes against a fold that hard-codes the tested constant.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

CODEX_SH="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$CODEX_SH" ]; then
    fail "F0-script-present" "review-survey-verdict-codex.sh not found at $CODEX_SH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not available — the fold is implemented in node and cannot be exercised"
    exit 77
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# --- fixtures ---------------------------------------------------------------------------

# write_artifact <path> <verdict> <same_fix> — minimal complete survey artifact.
# <same_fix> takes `true`, `false`, or `omit` to leave the field out entirely.
write_artifact() {
    local path="$1" verdict="$2" sf="$3"
    SF="$sf" VERDICT="$verdict" node -e '
"use strict";
const fs = require("fs");
const a = {
  schema_version: 3,
  proposal: { title: "P", background: "B", changes: "C" },
  verdict: process.env.VERDICT, target: null, children: [], related: [],
  reason: "survey reason",
  relations_mode: "batched", relation_errors: [],
  candidates: [
    { number: 10, title: "c10", state: "open", labels: [], body: "b10",
      relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false }
  ]
};
if (process.env.SF !== "omit") a.same_fix = process.env.SF === "true";
if (process.env.VERDICT === "reopen") a.target = 10;
fs.writeFileSync(process.argv[1], JSON.stringify(a, null, 2));' "$(node_path "$path")"
}

# write_mock_codex <mode> <review-json> — mode `ok` emits the block, `fail` exits non-zero
# without emitting anything (the transport failure that drives the `invalid` fold).
write_mock_codex() {
    local mode="$1" review="$2"
    if [ "$mode" = "fail" ]; then
        printf '%s\n' '#!/usr/bin/env bash' 'cat > /dev/null' 'echo "codex: simulated failure" >&2' 'exit 3' \
            > "$MOCKDIR/codex"
    else
        {
            printf '%s\n' '#!/usr/bin/env bash' 'cat > /dev/null' "printf '%s\\n' 'FINAL_VERDICT_JSON:'"
            printf "printf '%%s\\\\n' '%s'\n" "$review"
        } > "$MOCKDIR/codex"
    fi
    chmod +x "$MOCKDIR/codex"
}

# run_review <artifact> <out> — the script under test, with the mock reviewer on PATH.
run_review() {
    PATH="$MOCKDIR:$PATH" "$RWT" 60 bash "$CODEX_SH" --artifact "$1" --out "$2" --no-log >/dev/null 2>&1
}

# jval <file> <js-path> → value at <js-path>, JSON-encoded so `false`, `null` and absent
# stay distinguishable rather than collapsing to three empties.
jval() {
    node -e '
"use strict";
const fs = require("fs");
let o = null, ok = true;
try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { ok = false; }
if (!ok) {
  process.stdout.write("<unparseable>");
} else {
  const v = process.argv[2].split(".").reduce((acc, k) => (acc == null ? undefined : acc[k]), o);
  process.stdout.write(v === undefined ? "<absent>" : JSON.stringify(v));
}' "$(node_path "$1")" "$2" 2>/dev/null
}

# assert_field <case> <file> <js-path> <want-json>
assert_field() {
    local cid="$1" f="$2" path="$3" want="$4" got
    got="$(jval "$f" "$path")"
    if [ "$got" = "$want" ]; then
        pass "${cid}"
    else
        fail "${cid}" "$path: want $want, got $got"
    fi
}

REVIEW_REOPEN_TRUE='{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"one fix covers both","worth_filing":true,"same_fix":true}'
REVIEW_NONE_FALSE='{"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true,"same_fix":false}'

echo "=== F1: replaced — the top level takes the REVIEW's same_fix ==="

# Survey none/false vs reviewer reopen/true: the verdict changed, so the fold is
# `replaced` and every top-level field must come from the review.
ART="$WORK/a1.json"; OUT="$WORK/o1.json"
write_artifact "$ART" none false
write_mock_codex ok "$REVIEW_REOPEN_TRUE"
run_review "$ART" "$OUT"
if [ -f "$OUT" ]; then
    pass "F1-final-artifact-written"
else
    fail "F1-final-artifact-written" "no artifact at $OUT — every assertion below is unreachable"
fi
assert_field F1a-status-replaced          "$OUT" review.status  '"replaced"'
assert_field F1b-top-level-from-review    "$OUT" same_fix       'true'
assert_field F1c-review-object-records-it "$OUT" review.same_fix 'true'
# The survey's own answer is not overwritten — that is why `survey{}` exists.
assert_field F1d-survey-object-preserved  "$OUT" survey.same_fix 'false'
# Sanity: the verdict moved too, so F1b cannot be passing on an un-run fold.
assert_field F1e-verdict-also-replaced    "$OUT" verdict        '"reopen"'

echo ""
echo "=== F2: upheld — the top level HOLDS the survey's same_fix ==="

ART="$WORK/a2.json"; OUT="$WORK/o2.json"
write_artifact "$ART" none false
write_mock_codex ok "$REVIEW_NONE_FALSE"
run_review "$ART" "$OUT"
assert_field F2a-status-upheld            "$OUT" review.status  '"upheld"'
assert_field F2b-top-level-held           "$OUT" same_fix       'false'
assert_field F2c-survey-object-preserved  "$OUT" survey.same_fix 'false'
# `upheld` carries a real review, so review.same_fix is a boolean; null is reserved for
# "there was no usable review".
assert_field F2d-review-object-not-null   "$OUT" review.same_fix 'false'

echo ""
echo "=== F3: invalid — no usable review, survey held verbatim, review.same_fix null ==="

# The reviewer exits non-zero; nothing it printed is trusted, so the survey's verdict
# reaches the caller unchanged.
ART="$WORK/a3.json"; OUT="$WORK/o3.json"
write_artifact "$ART" none false
write_mock_codex fail ""
run_review "$ART" "$OUT"
assert_field F3a-status-invalid           "$OUT" review.status  '"invalid"'
assert_field F3b-top-level-held-false     "$OUT" same_fix       'false'
assert_field F3c-survey-object-preserved  "$OUT" survey.same_fix 'false'
# null, not false: "the reviewer said no" must stay distinguishable from "no reviewer".
assert_field F3d-review-same-fix-null     "$OUT" review.same_fix 'null'

# Same fold, opposite survey value — a fold hard-coded to `false` passes F3b, fails here.
ART="$WORK/a4.json"; OUT="$WORK/o4.json"
write_artifact "$ART" reopen true
write_mock_codex fail ""
run_review "$ART" "$OUT"
assert_field F3e-status-invalid           "$OUT" review.status  '"invalid"'
assert_field F3f-top-level-held-true      "$OUT" same_fix       'true'
assert_field F3g-survey-object-true       "$OUT" survey.same_fix 'true'
assert_field F3h-review-same-fix-null     "$OUT" review.same_fix 'null'
assert_field F3i-verdict-held             "$OUT" verdict        '"reopen"'

echo ""
echo "=== F4: a survey artifact with no same_fix at all ==="

# Pre-#1912 artifacts (schema 2) have no same_fix. The fold must yield `null` (unknown),
# not a manufactured `false` indistinguishable from a reviewed answer.
ART="$WORK/a5.json"; OUT="$WORK/o5.json"
write_artifact "$ART" none omit
write_mock_codex fail ""
run_review "$ART" "$OUT"
assert_field F4a-survey-object-null       "$OUT" survey.same_fix 'null'
assert_field F4b-top-level-null           "$OUT" same_fix        'null'
assert_field F4c-review-same-fix-null     "$OUT" review.same_fix 'null'

echo ""
echo "=== F5: a non-boolean same_fix is normalised, not carried ==="

# The fold's `typeof === "boolean"` guard turns a string that slipped past an older
# validator into null, not a truthy value every downstream `if (same_fix)` reads as true.
ART="$WORK/a6.json"; OUT="$WORK/o6.json"
write_artifact "$ART" none false
node -e '
"use strict";
const fs = require("fs");
const a = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
a.same_fix = "true";
fs.writeFileSync(process.argv[1], JSON.stringify(a, null, 2));' "$(node_path "$ART")"
write_mock_codex fail ""
run_review "$ART" "$OUT"
assert_field F5a-string-same-fix-becomes-null "$OUT" survey.same_fix 'null'
assert_field F5b-top-level-not-truthy-string  "$OUT" same_fix        'null'

echo ""
echo "=== F6: a self-contradictory SURVEY artifact cannot be upheld ==="

# The upheld/replaced decision compares verdict/target/children/related, not same_fix —
# so a same_fix-only disagreement would fold as `upheld`. It cannot: such a disagreement
# requires a contradictory SURVEY pair, which the validator rejects before the comparison
# (a guarantee that lives in another file). If that cross-check is ever relaxed, F6a
# flips to "upheld" and says so.
ART="$WORK/a7.json"; OUT="$WORK/o7.json"
write_artifact "$ART" none true
write_mock_codex ok "$REVIEW_NONE_FALSE"
run_review "$ART" "$OUT"
assert_field F6a-contradictory-survey-not-upheld "$OUT" review.status   '"invalid"'
assert_field F6b-no-review-value-recorded        "$OUT" review.same_fix 'null'
# The contradiction is preserved, not repaired — the fold holds the survey verbatim, and
# repairing here would hide a broken survey from the operator.
assert_field F6c-top-level-keeps-survey-true     "$OUT" same_fix        'true'
assert_field F6d-survey-object-keeps-true        "$OUT" survey.same_fix 'true'

# --- Paired gaps (Pattern 3, skills/_shared/test-design/protection-fix-tests.md) ---------
# SKIPPED: the `skipped` fold status (codex absent from PATH).
# Because: removing codex from PATH at TL2 means emptying PATH, which removes node and
#          bash with it — the degraded no-node copy path would run instead, and it writes
#          no `review` object at all, so nothing about same_fix could be asserted.
# L3 gap:  only a host genuinely without codex exercises that branch; it shares the
#          `else` arm with `invalid`, which F3/F4 cover.
#
# SKIPPED: whether the confirm gate and the issue body actually read the top-level
#          same_fix this file pins.
# Because: those consumers live in the skill prompt, not in a callable script.
# L3 gap:  only a full /issue-create run shows the folded value reaching a human decision.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
