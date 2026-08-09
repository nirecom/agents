#!/usr/bin/env bash
# tests/feat-1912-same-fix-crosscheck.sh
# Tests: bin/github-issues/lib/validate-review-verdict.js
# Tags: issue-create, verdict, review, validator, same-fix, schema-version, cascade, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether a real survey worker / real `codex exec` actually emits `same_fix`. This
#   file pins only the validator's contract over hand-written fixtures.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# #1912 adds one field, `same_fix`, to BOTH verdict producers (survey artifact and
# codex review), and raises the artifact schema to 3. `same_fix` answers exactly one
# question — "does ONE fix resolve the proposal and the named existing issue at the
# same time?" — and because that answer is a function of the verdict, it is not free
# text a producer may fill in as it likes: each verdict has exactly one admissible
# value, and any other value is a producer whose reasoning drifted.
#
# The cross-check is the whole point. Without it `same_fix` would be a field nobody
# reads, and a model that emitted `make-parent` while thinking "one fix covers both"
# would sail through. `make-parent` = false is the value that catches that drift, and
# it is a REVERSAL of the earlier draft (which keyed on close-state coupling), so it
# is asserted in both directions here — a table that quietly flipped back would fail.
#
# `sub-of` / `bulk-sub-of` = false are the same kind of reversal, on the parent-ATTACHING
# side: the issue those verdicts name is a meta parent, a container that is never
# implemented against, so attaching to one resolves it no more than creating one does.
# `reopen` is the only `true` left, and the cascade order says the same thing
# independently — IC-C1 asks the one-fix question of every candidate and only falls
# through to IC-C2 when the answer was no for all of them. Both polarities are pinned
# for each verdict below so a table that flipped back would fail here too.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
# X: SAME_FIX_BY_VERDICT is exported, and it is the machine-readable SSOT.
# A prose table in the cascade doc cannot be read by the validator, the survey
# worker or the reviewer prompt; only an exported map can, so its absence is a
# failure in its own right rather than a stylistic preference.
# ---------------------------------------------------------------------------
echo "=== X: exported constants (SCHEMA_VERSION, SAME_FIX_BY_VERDICT) ==="

EXPORTS="$WORK/exports.txt"
: > "$EXPORTS"
if [ "$VALIDATOR_PRESENT" = "yes" ]; then
    "$RWT" 15 node -e '
const m = require(process.argv[1]);
const t = m.SAME_FIX_BY_VERDICT;
console.log("SCHEMA_VERSION=" + JSON.stringify(m.SCHEMA_VERSION));
console.log("TABLE_TYPE=" + (t && typeof t === "object" && !Array.isArray(t) ? "object" : typeof t));
if (t && typeof t === "object" && !Array.isArray(t)) {
  console.log("KEYS=" + Object.keys(t).sort().join(","));
  for (const k of Object.keys(t).sort()) console.log("V:" + k + "=" + JSON.stringify(t[k]));
}' "$(node_path "$VALIDATOR")" > "$EXPORTS" 2>/dev/null || true
fi

assert_export() {  # <label> <prefix> <want>
    local label="$1" prefix="$2" want="$3" got
    if [ "$VALIDATOR_PRESENT" != "yes" ]; then
        fail "$label" "RED-EXPECTED: validate-review-verdict.js not found"
        return
    fi
    got=$(grep -m1 -F -- "$prefix" "$EXPORTS" 2>/dev/null)
    got="${got#"$prefix"}"
    if [ "$got" = "$want" ]; then
        pass "$label"
    else
        fail "$label" "want '${prefix}${want}' (got: '${prefix}${got:-<absent>}')"
    fi
}

assert_export X1-schema-version-3 "SCHEMA_VERSION=" "3"
assert_export X2-table-is-an-object "TABLE_TYPE=" "object"
# Exactly six keys: a table missing bulk-sub-of would make the artifact-side check
# unresolvable for the bulk route, and an extra key means a verdict nobody dispatches.
assert_export X3-table-covers-every-verdict "KEYS=" "bulk-sub-of,make-parent,none,reopen,sibling,sub-of"

# reopen is the ONLY true: it re-uses the existing issue, so the one fix that closes the
# proposal is literally the fix that closes it.
assert_export X4-reopen-true       "V:reopen="       "true"
# Both parent-attaching verdicts are false. The issue they name is a meta parent — a
# container that is never implemented against — so attaching to one (sub-of/bulk-sub-of)
# resolves it no more than creating one (make-parent) does. These are the values #1912
# reverses; A9/A10 and B9/B10 below pin the same flip through the validator.
assert_export X5-sub-of-false      "V:sub-of="       "false"
assert_export X6-bulk-sub-of-false "V:bulk-sub-of="  "false"
# make-parent groups issues that each still need their OWN fix — the grouping is
# organisational, not a shared repair.
assert_export X7-make-parent-false "V:make-parent="  "false"
assert_export X8-sibling-false     "V:sibling="      "false"
assert_export X9-none-false        "V:none="         "false"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
# CAND = {10, 11}, both resolved orphans, so every review verdict is expressible.
mk_artifact() {  # <path> <verdict> <same_fix-json-or-__OMIT__> [schema_version]
    V="$2" SF="$3" SCH="${4:-3}" "$RWT" 15 node -e '
const fs = require("fs");
const a = {
  schema_version: JSON.parse(process.env.SCH),
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

# run_validate <artifact-path> <raw-review-text> → VERDICT, REASON, REVIEW_JSON
run_validate() {
    VERDICT='<missing>'; REASON=''; REVIEW_JSON=''
    [ "$VALIDATOR_PRESENT" = "yes" ] || return 0
    printf '%b' "$2" > "$WORK/raw.txt"
    local out
    out=$("$RWT" 15 node "$(node_path "$VALIDATOR")" \
            --artifact "$(node_path "$1")" \
            --review-raw "$(node_path "$WORK/raw.txt")" 2>/dev/null)
    VERDICT=$(printf '%s\n' "$out" | sed -n '1p'); VERDICT="${VERDICT//[[:space:]]/}"
    REASON=$(printf '%s\n' "$out" | sed -n '2p')
    REVIEW_JSON=$(printf '%s\n' "$out" | sed -n '3p')
}

assert_route() {  # <label> <want valid|invalid> <artifact-path> <raw>
    local label="$1" want="$2"
    run_validate "$3" "$4"
    if [ "$VERDICT" = '<missing>' ]; then
        fail "$label" "RED-EXPECTED: validate-review-verdict.js not found (want=$want)"
    elif [ "$VERDICT" = "$want" ]; then
        pass "$label"
    else
        fail "$label" "want '$want' (got: '${VERDICT:-<none>}'${REASON:+, reason: $REASON})"
    fi
}

assert_reason_names() {  # <label> <needle> <artifact-path> <raw>
    local label="$1" needle="$2"
    run_validate "$3" "$4"
    if [ "$VERDICT" = '<missing>' ]; then
        fail "$label" "RED-EXPECTED: validate-review-verdict.js not found"
    elif [ "$VERDICT" != "invalid" ]; then
        fail "$label" "expected 'invalid' before checking the reason (got: '$VERDICT')"
    elif printf '%s' "$REASON" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label" "the invalid reason must name '$needle' (got: '${REASON:-<none>}')"
    fi
}

# A review the shape checks accept, so every A-case fails (or passes) on the ARTIFACT.
OK_REVIEW='{"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true,"same_fix":false}'

echo ""
echo "=== A: same_fix on the survey artifact ==="

mk_artifact "$WORK/a-none.json"    none  false
mk_artifact "$WORK/a-v2.json"      none  false 2
mk_artifact "$WORK/a-omit.json"    none  __OMIT__
mk_artifact "$WORK/a-str.json"     none  '"true"'
mk_artifact "$WORK/a-null.json"    none  null
mk_artifact "$WORK/a-num.json"     none  1

# A1 is the positive control: without it every "invalid" below could come from an
# unrelated defect in the fixture rather than from same_fix.
assert_route A1-schema3-consistent  valid   "$WORK/a-none.json" "$OK_REVIEW"
assert_route A2-schema-version-2    invalid "$WORK/a-v2.json"   "$OK_REVIEW"
assert_reason_names A2r-reason-names-schema-version schema_version "$WORK/a-v2.json" "$OK_REVIEW"

assert_route A3-same-fix-missing    invalid "$WORK/a-omit.json" "$OK_REVIEW"
assert_reason_names A3r-reason-names-same-fix same_fix "$WORK/a-omit.json" "$OK_REVIEW"
# No coercion: "true" and 1 are producer defects, and a truthy string would flip the
# cross-check the wrong way exactly like worth_filing's `"false"`.
assert_route A4-same-fix-string     invalid "$WORK/a-str.json"  "$OK_REVIEW"
assert_route A5-same-fix-null       invalid "$WORK/a-null.json" "$OK_REVIEW"
assert_route A6-same-fix-number     invalid "$WORK/a-num.json"  "$OK_REVIEW"

# Per-verdict consistency, both directions. The "wrong" row of each pair is the one
# that catches a producer whose verdict and reasoning disagree; the "right" row keeps
# the wrong row non-vacuous.
while IFS='|' read -r name verdict sf want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; verdict="${verdict//[[:space:]]/}"
    sf="${sf//[[:space:]]/}"; want="${want//[[:space:]]/}"
    mk_artifact "$WORK/a-case.json" "$verdict" "$sf"
    assert_route "$name" "$want" "$WORK/a-case.json" "$OK_REVIEW"
done <<'TABLE'
A7-reopen-true        | reopen      | true  | valid
A8-reopen-false       | reopen      | false | invalid
A9-sub-of-false       | sub-of      | false | valid
A10-sub-of-true       | sub-of      | true  | invalid
A11-make-parent-false | make-parent | false | valid
A12-make-parent-true  | make-parent | true  | invalid
A13-sibling-false     | sibling     | false | valid
A14-sibling-true      | sibling     | true  | invalid
A15-none-false        | none        | false | valid
A16-none-true         | none        | true  | invalid
TABLE

# A12 is the reversal guard, so its reason is pinned too: "make-parent groups issues
# that each keep their own fix" must be legible to whoever reads the failure.
mk_artifact "$WORK/a-mp-true.json" make-parent true
assert_reason_names A12r-reason-names-same-fix same_fix "$WORK/a-mp-true.json" "$OK_REVIEW"

# A10 is the parent-attaching reversal guard, and it gets the same treatment: an artifact
# claiming one fix covers both while attaching to a meta parent must be rejected FOR
# same_fix, not for some incidental shape defect.
mk_artifact "$WORK/a-so-true.json" sub-of true
assert_reason_names A10r-reason-names-same-fix same_fix "$WORK/a-so-true.json" "$OK_REVIEW"

# bulk-sub-of is folded to invalid by the review grammar, but the ARTIFACT is checked
# first — so a bulk artifact with the wrong same_fix must be rejected FOR same_fix, not
# swallowed by the grammar fold. Both rows together pin that ordering.
mk_artifact "$WORK/a-bulk-bad.json" bulk-sub-of true
mk_artifact "$WORK/a-bulk-ok.json"  bulk-sub-of false
assert_reason_names A17-bulk-wrong-same-fix-named same_fix "$WORK/a-bulk-bad.json" "$OK_REVIEW"
assert_reason_names A18-bulk-consistent-folds-on-grammar grammar "$WORK/a-bulk-ok.json" "$OK_REVIEW"

echo ""
echo "=== B: same_fix on the codex review verdict ==="

ART="$WORK/b-artifact.json"
mk_artifact "$ART" none false

BASE='"target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true'

assert_route B1-review-same-fix-missing invalid "$ART" "{\"verdict\":\"none\",$BASE}"
# B2 keeps B1 non-vacuous: identical review, one extra field.
assert_route B2-review-same-fix-false   valid   "$ART" "{\"verdict\":\"none\",$BASE,\"same_fix\":false}"
assert_route B3-review-same-fix-string  invalid "$ART" "{\"verdict\":\"none\",$BASE,\"same_fix\":\"false\"}"
assert_route B4-review-same-fix-null    invalid "$ART" "{\"verdict\":\"none\",$BASE,\"same_fix\":null}"
assert_route B5-review-same-fix-number  invalid "$ART" "{\"verdict\":\"none\",$BASE,\"same_fix\":0}"
assert_reason_names B6-review-reason-names-same-fix same_fix "$ART" "{\"verdict\":\"none\",$BASE}"

# Per-verdict consistency on the review side. The review may disagree with the survey
# (artifact verdict is `none` throughout), so each row exercises the review's OWN row
# of the table, not the artifact's.
while IFS='|' read -r name body want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
    assert_route "$name" "${want//[[:space:]]/}" "$ART" "$body"
done <<TABLE
B7-reopen-true        | {"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same root cause","worth_filing":true,"same_fix":true}   | valid
B8-reopen-false       | {"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same root cause","worth_filing":true,"same_fix":false}  | invalid
B9-sub-of-false       | {"verdict":"sub-of","target":10,"children":[],"related":[],"reason":"belongs under it","worth_filing":true,"same_fix":false}  | valid
B10-sub-of-true       | {"verdict":"sub-of","target":10,"children":[],"related":[],"reason":"belongs under it","worth_filing":true,"same_fix":true}   | invalid
B11-make-parent-false | {"verdict":"make-parent","target":null,"children":[10,11],"related":[],"reason":"one theme","worth_filing":true,"same_fix":false} | valid
B12-make-parent-true  | {"verdict":"make-parent","target":null,"children":[10,11],"related":[],"reason":"one theme","worth_filing":true,"same_fix":true}  | invalid
B13-sibling-false     | {"verdict":"sibling","target":null,"children":[],"related":[10],"reason":"adjacent","worth_filing":true,"same_fix":false}    | valid
B14-sibling-true      | {"verdict":"sibling","target":null,"children":[],"related":[10],"reason":"adjacent","worth_filing":true,"same_fix":true}     | invalid
B15-none-true         | {"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true,"same_fix":true}     | invalid
TABLE

# B15 completes the review-side cross-product: every one of the five verdicts is now
# asserted in BOTH polarities (its table value, and the wrong one). The `none` row is the
# one that could most easily have been left out — B2 already covers `none`+false, so the
# verdict looked "done" — and it is also the most consequential omission, because
# `none` + `same_fix: true` is self-contradictory in a way the other rows are not: it
# claims one fix resolves the proposal and an existing issue while simultaneously
# reporting that no existing issue is related at all (`target` null, both lists empty).

# B12 is the review-side reversal guard.
assert_reason_names B12r-reason-names-same-fix same_fix "$ART" \
    '{"verdict":"make-parent","target":null,"children":[10,11],"related":[],"reason":"one theme","worth_filing":true,"same_fix":true}'

# B10 is the same guard on the parent-attaching side, and its reason is pinned for the
# same reason: sub-of passes every shape check, so the only thing that may reject it is
# the same_fix cross-check itself.
assert_reason_names B10r-reason-names-same-fix same_fix "$ART" \
    '{"verdict":"sub-of","target":10,"children":[],"related":[],"reason":"belongs under it","worth_filing":true,"same_fix":true}'

echo ""
echo "=== C: same_fix survives into the emitted review object ==="

# A field the validator checks but drops is a field no downstream consumer can act on.
if [ "$VALIDATOR_PRESENT" != "yes" ]; then
    fail "C1-review-json-carries-same-fix" "RED-EXPECTED: validate-review-verdict.js not found"
else
    run_validate "$ART" \
        '{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same root cause","worth_filing":true,"same_fix":true}'
    if [ "$VERDICT" != "valid" ]; then
        fail "C1-review-json-carries-same-fix" "review did not validate (got: '$VERDICT', reason: '${REASON:-<none>}')"
    elif printf '%s' "$REVIEW_JSON" | grep -qE '"same_fix":[[:space:]]*true'; then
        pass "C1-review-json-carries-same-fix"
    else
        fail "C1-review-json-carries-same-fix" "emitted review JSON omits same_fix (got: '${REVIEW_JSON:-<none>}')"
    fi
fi

echo ""
echo "=== D: make-empty-verdict.sh agrees with SAME_FIX_BY_VERDICT ==="

# The empty-verdict route bypasses the survey worker entirely (zero candidates,
# non-GitHub remote, --skip-survey). It is a THIRD producer of the field, and a
# producer that hard-codes the wrong constant is invisible to A and B above —
# those read fixtures, this one reads the shipped script.
MEV="$AGENTS_DIR/skills/issue-create/scripts/make-empty-verdict.sh"

mev_field() {  # <artifact-path> <field> → JSON value, or <absent>
    "$RWT" 12 node -e '
try {
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const v = d[process.argv[2]];
  process.stdout.write(v === undefined ? "<absent>" : JSON.stringify(v));
} catch (e) { process.stdout.write("<unreadable>"); }' "$(node_path "$1")" "$2" 2>/dev/null
}

while IFS='|' read -r name verdict extra want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; verdict="${verdict//[[:space:]]/}"
    extra="${extra//[[:space:]]/}"; want="${want//[[:space:]]/}"
    if [ ! -f "$MEV" ]; then
        fail "$name" "RED-EXPECTED: make-empty-verdict.sh not found"
        continue
    fi
    OUTA="$WORK/mev-$verdict.json"
    # shellcheck disable=SC2086
    "$RWT" 20 bash "$MEV" "$OUTA" "$verdict" --title "T" --background "B" --changes "C" \
        ${extra:+--target 10} >/dev/null 2>&1
    GOT_SF=$(mev_field "$OUTA" same_fix)
    GOT_SCH=$(mev_field "$OUTA" schema_version)
    if [ "$GOT_SF" = "$want" ] && [ "$GOT_SCH" = "3" ]; then
        pass "$name"
    else
        fail "$name" "want same_fix=$want schema_version=3 (got same_fix=$GOT_SF schema_version=$GOT_SCH)"
    fi
done <<'TABLE'
D1-mev-none        | none        |        | false
D2-mev-reopen      | reopen      | target | true
D3-mev-sub-of      | sub-of      | target | false
D4-mev-bulk-sub-of | bulk-sub-of | target | false
D5-mev-make-parent | make-parent |        | false
D6-mev-sibling     | sibling     |        | false
TABLE


# --- sections ------------------------------------------------------------------------
# A / B above walk each verdict in two value classes (the table's value and its
# negation) and probe the remaining classes against `none` alone. The section below is
# the full verdict × value-class cross product on both producers, plus the reason
# attribution. It lives in a section file because this one is already ~360 lines.
# tests/run-all.sh globs tests/*.sh (top level only), so without this block it would
# never run — see tests/lib/section-runner.sh.
SECTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feat-1912-same-fix-crosscheck"
# shellcheck source=./lib/section-runner.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/section-runner.sh"

run_section "value-class-matrix.sh" 240

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
