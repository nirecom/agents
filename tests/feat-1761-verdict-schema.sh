#!/usr/bin/env bash
# tests/feat-1761-verdict-schema.sh
# Tests: skills/issue-create/scripts/make-empty-verdict.sh, agents/issue-create-survey-worker.md, skills/_shared/issue-verdict-cascade.md, bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, schema-v2, survey-artifact, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - The real survey sub-agent actually emitting schema v2 (LLM output, not shell-testable).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S7 CLI contract fixed by this test:
#   make-empty-verdict.sh <out-path> <verdict> --title T --background B --changes C [--target N] [--parent N]

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
MEV="$AGENTS_DIR/skills/issue-create/scripts/make-empty-verdict.sh"
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
WORKER_MD="$AGENTS_DIR/agents/issue-create-survey-worker.md"
CASCADE_MD="$AGENTS_DIR/skills/_shared/issue-verdict-cascade.md"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MEV_PRESENT=no; [ -f "$MEV" ] && MEV_PRESENT=yes

# The 10 top-level keys that schema v2 declares always present (S6).
TOP_KEYS="schema_version proposal verdict target children related reason relations_mode relation_errors candidates"

# jsonq <file> <node-expression using variable `d`> → prints result, or empty on error
jsonq() {
    "$RWT" 12 node -e "
try {
  const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const v = ($2);
  process.stdout.write(typeof v === 'object' ? JSON.stringify(v) : String(v));
} catch (e) { process.stdout.write(''); }
" "$(node_path "$1")" 2>/dev/null
}

# gen <out-name> <verdict> <extra args...> → 0 on success
gen() {
    local out="$1" verdict="$2"; shift 2
    [ "$MEV_PRESENT" = "yes" ] || return 1
    "$RWT" 20 bash "$MEV" "$WORK/$out" "$verdict" \
        --title "Proposed title" --background "Some background" --changes "Some changes" \
        "$@" >/dev/null 2>&1
}

# assert_route <label> <out-name>
assert_route() {
    local label="$1" out="$2" f="$WORK/$2" missing="" k
    if [ ! -f "$f" ]; then
        fail "$label" "RED-EXPECTED: make-empty-verdict.sh did not produce $out (script not yet created)"
        return
    fi
    for k in $TOP_KEYS; do
        if [ "$(jsonq "$f" "Object.prototype.hasOwnProperty.call(d,'$k')")" != "true" ]; then
            missing="${missing:+$missing }$k"
        fi
    done
    if [ -n "$missing" ]; then
        fail "$label" "schema v2 keys missing: $missing"
    else
        pass "$label"
    fi
}

echo "=== S7: the three worker-bypassing routes all emit schema v2 ==="

gen "no-candidates.json"  none
assert_route "E1-no-candidates route has all 10 top-level keys" "no-candidates.json"

gen "non-github.json"     none
assert_route "E2-non-github route has all 10 top-level keys" "non-github.json"

# The --skip-survey route attaches N children to one parent. Its verdict word is
# `bulk-sub-of`, not `sub-of`: writing the singular form here would tell every
# downstream reader that one child was attached when N were.
gen "bulk-sub-of.json"    bulk-sub-of --parent 4242
assert_route "E3-skip-survey/bulk-sub-of route has all 10 top-level keys" "bulk-sub-of.json"

echo ""
echo "=== S7: explicit defaults must be written, never omitted ==="

F="$WORK/no-candidates.json"
if [ ! -f "$F" ]; then
    fail "E4-proposal-title-non-empty"   "RED-EXPECTED: make-empty-verdict.sh not yet created"
    fail "E5-candidates-empty-array"     "RED-EXPECTED: make-empty-verdict.sh not yet created"
    fail "E6-children-related-arrays"    "RED-EXPECTED: make-empty-verdict.sh not yet created"
    fail "E7-relations-mode-unavailable" "RED-EXPECTED: make-empty-verdict.sh not yet created"
    fail "E8-relation-errors-array"      "RED-EXPECTED: make-empty-verdict.sh not yet created"
    fail "E9-schema-version-2"           "RED-EXPECTED: make-empty-verdict.sh not yet created"
else
    T=$(jsonq "$F" "d.proposal && d.proposal.title ? 'nonempty' : 'empty'")
    [ "$T" = "nonempty" ] && pass "E4-proposal-title-non-empty" \
        || fail "E4-proposal-title-non-empty" "proposal.title is empty or absent (got: $T)"

    T=$(jsonq "$F" "Array.isArray(d.candidates) && d.candidates.length === 0")
    [ "$T" = "true" ] && pass "E5-candidates-empty-array" \
        || fail "E5-candidates-empty-array" "candidates is not an explicit empty array (got: $T)"

    T=$(jsonq "$F" "Array.isArray(d.children) && Array.isArray(d.related)")
    [ "$T" = "true" ] && pass "E6-children-related-arrays" \
        || fail "E6-children-related-arrays" "children/related are not both arrays (got: $T)"

    T=$(jsonq "$F" "d.relations_mode")
    [ "$T" = "unavailable" ] && pass "E7-relations-mode-unavailable" \
        || fail "E7-relations-mode-unavailable" "relations_mode should be 'unavailable' on the worker-bypassing routes (got: $T)"

    T=$(jsonq "$F" "Array.isArray(d.relation_errors)")
    [ "$T" = "true" ] && pass "E8-relation-errors-array" \
        || fail "E8-relation-errors-array" "relation_errors is not an array (got: $T)"

    T=$(jsonq "$F" "d.schema_version")
    [ "$T" = "2" ] && pass "E9-schema-version-2" \
        || fail "E9-schema-version-2" "schema_version should be 2 (got: $T)"
fi

# E10: the bulk-sub-of route must carry --parent through to target.
F2="$WORK/bulk-sub-of.json"
if [ ! -f "$F2" ]; then
    fail "E10-bulk-sub-of-target" "RED-EXPECTED: make-empty-verdict.sh not yet created"
    fail "E20-bulk-sub-of-verdict-not-degraded" "RED-EXPECTED: make-empty-verdict.sh not yet created"
else
    T=$(jsonq "$F2" "d.target")
    [ "$T" = "4242" ] && pass "E10-bulk-sub-of-target" \
        || fail "E10-bulk-sub-of-target" "--parent 4242 not reflected in target (got: $T)"

    T=$(jsonq "$F2" "d.verdict")
    [ "$T" = "bulk-sub-of" ] && pass "E20-bulk-sub-of-verdict-not-degraded" \
        || fail "E20-bulk-sub-of-verdict-not-degraded" "the --skip-survey route must record 'bulk-sub-of', not the singular form (got: $T)"
fi

echo ""
echo "=== S7: bulk-sub-of survives the artifact round-trip without degrading to sub-of ==="
# `bulk-sub-of` is the one verdict word that exists only at survey level — it is outside
# the review grammar, so the review stage has no reviewer verdict to fold in and must
# carry the survey's word through verbatim. A stage that normalised it to `sub-of` would
# still produce a well-formed artifact, so only an end-to-end round trip catches it.
# The review is skipped by making codex unreachable: that is the shortest path
# through write_final, and any normalisation on that path is normalisation on every
# path. (The old ISSUE_VERDICT_REVIEW=off toggle no longer exists.)
if [ ! -f "$RS" ] || [ ! -f "$WORK/bulk-sub-of.json" ]; then
    fail "E21-roundtrip-verdict-held"        "RED-EXPECTED: review-survey-verdict-codex.sh or the bulk-sub-of artifact is missing"
    fail "E22-roundtrip-survey-verdict-held" "RED-EXPECTED: review-survey-verdict-codex.sh or the bulk-sub-of artifact is missing"
    fail "E23-roundtrip-target-held"         "RED-EXPECTED: review-survey-verdict-codex.sh or the bulk-sub-of artifact is missing"
else
    RT="$WORK/bulk-sub-of-final.json"
    # Strip codex's directory from PATH so the review stage takes its skip exit while
    # node/bash/coreutils stay reachable.
    # Drop EVERY directory that provides a codex executable. There is routinely more
    # than one on PATH (version managers keep parallel shims), and leaving a single
    # one behind runs the real reviewer instead of exercising the skip path — which
    # looks like a passing review rather than a broken fixture.
    NOCODEX_PATH=""
    _OLDIFS="$IFS"; IFS=":"
    for _d in $PATH; do
        [ -n "$_d" ] || continue
        [ "$_d" = "${MOCKDIR:-}" ] && continue
        if [ -x "$_d/codex" ] || [ -f "$_d/codex.exe" ] || [ -f "$_d/codex.cmd" ] || [ -f "$_d/codex.bat" ]; then continue; fi
        NOCODEX_PATH="${NOCODEX_PATH:+$NOCODEX_PATH:}$_d"
    done
    IFS="$_OLDIFS"
    # Dropping that directory can also drop node: version managers ship node and the
    # tools installed under it in one shim directory. The script under test needs node,
    # and losing it would surface as a failed review rather than a skipped one — so node
    # is re-provided from its absolute path.
    NOCODEX_SHIM="$WORK/nocodex-shim"; mkdir -p "$NOCODEX_SHIM"
    printf '#!/usr/bin/env bash
exec "%s" "$@"
' "$(command -v node)" > "$NOCODEX_SHIM/node"
    chmod +x "$NOCODEX_SHIM/node"
    NOCODEX_PATH="$NOCODEX_SHIM:$NOCODEX_PATH"
    env PATH="$NOCODEX_PATH" \
        "$RWT" 40 bash "$RS" --artifact "$WORK/bulk-sub-of.json" --out "$RT" --no-log >/dev/null 2>&1

    T=$(jsonq "$RT" "d.verdict")
    [ "$T" = "bulk-sub-of" ] && pass "E21-roundtrip-verdict-held" \
        || fail "E21-roundtrip-verdict-held" "the final artifact must keep verdict 'bulk-sub-of' (got: '$T')"

    T=$(jsonq "$RT" "d.survey && d.survey.verdict")
    [ "$T" = "bulk-sub-of" ] && pass "E22-roundtrip-survey-verdict-held" \
        || fail "E22-roundtrip-survey-verdict-held" "survey.verdict must preserve 'bulk-sub-of' (got: '$T')"

    T=$(jsonq "$RT" "d.target")
    [ "$T" = "4242" ] && pass "E23-roundtrip-target-held" \
        || fail "E23-roundtrip-target-held" "the bulk parent must survive the round trip (got: '$T')"

    # The provenance token is gone from the schema in this PR. A vestigial key would
    # let a downstream reader keep branching on a value nothing writes any more.
    T=$(jsonq "$RT" "Object.prototype.hasOwnProperty.call(d, 'provenance')")
    [ "$T" = "false" ] && pass "E24-roundtrip-no-provenance-key" \
        || fail "E24-roundtrip-no-provenance-key" "the final artifact must not carry a top-level 'provenance' key (got: '$T')"

    T=$(jsonq "$RT" "Object.prototype.hasOwnProperty.call(d, 'provenance_layer')")
    [ "$T" = "false" ] && pass "E25-roundtrip-no-provenance-layer-key" \
        || fail "E25-roundtrip-no-provenance-layer-key" "the final artifact must not carry 'provenance_layer' (got: '$T')"

    # review.worth_filing replaces it as the confirm gate's input; on a skipped review
    # there is no reviewer opinion, so the key must be present and explicitly null.
    T=$(jsonq "$RT" "d.review && Object.prototype.hasOwnProperty.call(d.review, 'worth_filing')")
    [ "$T" = "true" ] && pass "E26-roundtrip-review-worth-filing-key" \
        || fail "E26-roundtrip-review-worth-filing-key" "review.worth_filing must always be present (got: '$T')"

    T=$(jsonq "$RT" "d.review && d.review.worth_filing")
    [ "$T" = "null" ] && pass "E27-roundtrip-worth-filing-null-on-skip" \
        || fail "E27-roundtrip-worth-filing-null-on-skip" "a skipped review must leave review.worth_filing null, not a fabricated boolean (got: '$T')"
fi

echo ""
echo "=== S7: regeneration is idempotent and never half-writes ==="
# The empty-verdict routes are re-runnable: a retried /issue-create, a resumed
# session, or a user re-answering the confirm gate can all land here twice with the
# same arguments. A second run must leave a byte-identical artifact — an appended,
# merged, or timestamp-stamped file would make the downstream diff meaningless and
# would make `--out` non-reproducible across a retry.
sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

if [ "$MEV_PRESENT" != "yes" ]; then
    for t in E16-rerun-byte-identical E17-rerun-exit-0 E18-overwrite-not-append E19-no-temp-left-behind; do
        fail "$t" "RED-EXPECTED: make-empty-verdict.sh not yet created"
    done
else
    gen "idem.json" "none"; RC1=$?
    S1=""; [ -f "$WORK/idem.json" ] && S1=$(sha_of "$WORK/idem.json")
    SZ1=0; [ -f "$WORK/idem.json" ] && SZ1=$(wc -c < "$WORK/idem.json" | tr -d ' ')
    gen "idem.json" "none"; RC2=$?
    S2=""; [ -f "$WORK/idem.json" ] && S2=$(sha_of "$WORK/idem.json")
    SZ2=0; [ -f "$WORK/idem.json" ] && SZ2=$(wc -c < "$WORK/idem.json" | tr -d ' ')

    if [ -n "$S1" ] && [ "$S1" = "$S2" ]; then pass "E16-rerun-byte-identical"
    else fail "E16-rerun-byte-identical" "a second identical run changed the artifact (sha $S1 -> $S2)"; fi

    if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]; then pass "E17-rerun-exit-0"
    else fail "E17-rerun-exit-0" "rerun must be a clean no-op (rc1=$RC1 rc2=$RC2)"; fi

    # Distinguishes "overwrote with the same content" from "appended a second object":
    # an append keeps the sha different AND grows the file, so size is checked too.
    if [ "$SZ1" -gt 0 ] && [ "$SZ1" = "$SZ2" ]; then pass "E18-overwrite-not-append"
    else fail "E18-overwrite-not-append" "artifact size changed on rerun ($SZ1 -> $SZ2 bytes)"; fi

    # A generator that writes via <out>.tmp must clean it up; a stray temp file next
    # to the artifact is the classic symptom of a half-completed write.
    STRAY=$(ls "$WORK"/idem.json.* 2>/dev/null | tr '\n' ' ')
    if [ -z "$STRAY" ]; then pass "E19-no-temp-left-behind"
    else fail "E19-no-temp-left-behind" "temp artifacts left next to the output: $STRAY"; fi
fi

echo ""
echo "=== S6: the worker prompt documents schema v2 ==="

if [ ! -f "$WORKER_MD" ]; then
    fail "E11-worker-schema-keys" "agents/issue-create-survey-worker.md not found"
else
    missing=""
    for k in $TOP_KEYS; do
        grep -qF "\"$k\"" "$WORKER_MD" || missing="${missing:+$missing }$k"
    done
    if [ -z "$missing" ]; then pass "E11-worker-schema-keys"
    else fail "E11-worker-schema-keys" "RED-EXPECTED: worker.md schema example lacks: $missing"; fi

    CAND_KEYS="relation_status parent_number parent_is_meta has_sub_issues"
    missing=""
    for k in $CAND_KEYS; do
        grep -qF "\"$k\"" "$WORKER_MD" || missing="${missing:+$missing }$k"
    done
    if [ -z "$missing" ]; then pass "E12-worker-candidate-relation-keys"
    else fail "E12-worker-candidate-relation-keys" "RED-EXPECTED: worker.md candidate schema lacks: $missing"; fi

    if grep -qF "issue-verdict-cascade.md" "$WORKER_MD"; then pass "E13-worker-references-cascade-ssot"
    else fail "E13-worker-references-cascade-ssot" "RED-EXPECTED: worker.md does not reference the cascade SSOT"; fi
fi

echo ""
echo "=== S4: cascade SSOT file exists and carries IC-C1..IC-C4 ==="

if [ ! -f "$CASCADE_MD" ]; then
    fail "E14-cascade-ssot-exists" "RED-EXPECTED: skills/_shared/issue-verdict-cascade.md not yet created"
    fail "E15-cascade-under-100-lines" "RED-EXPECTED: skills/_shared/issue-verdict-cascade.md not yet created"
else
    missing=""
    for k in IC-C1 IC-C2 IC-C3 IC-C4; do
        grep -qF "$k" "$CASCADE_MD" || missing="${missing:+$missing }$k"
    done
    if [ -z "$missing" ]; then pass "E14-cascade-ssot-exists"
    else fail "E14-cascade-ssot-exists" "cascade SSOT missing rules: $missing"; fi

    LN=$(wc -l < "$CASCADE_MD" | tr -d ' ')
    if [ "$LN" -le 100 ]; then pass "E15-cascade-under-100-lines ($LN)"
    else fail "E15-cascade-under-100-lines" "cascade SSOT is $LN lines (WARN threshold 100, rules/coding/file-split.md)"; fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
