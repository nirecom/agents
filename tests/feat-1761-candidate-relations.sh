#!/usr/bin/env bash
# tests/feat-1761-candidate-relations.sh
# Tests: bin/github-issues/candidate-relations.sh, bin/github-issues/lib/candidate-relation-one.sh
# Tags: issue-create, verdict, candidate-relations, graphql, gh-mock, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The real GitHub GraphQL schema accepting the aliased batch query (needs a live token).
# - Real partial-error payload shapes from api.github.com.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S5 contract under test:
#   candidate-relations.sh <owner/repo> <N,M,...>
#   stdout: JSON array of { number, relation_status, parent_number, parent_is_meta, has_sub_issues }
#   stderr: "relations_mode: batched|fallback|mixed" + unresolved candidate numbers
#   exit:   0 = all resolved, 3 = some unresolved, 4 = all unresolved
# The gh mock replies from a per-call canned-response directory, so the batched path
# and the per-candidate fallback path are both driven without knowing the query text.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
CR="$AGENTS_DIR/bin/github-issues/candidate-relations.sh"
CR_ONE="$AGENTS_DIR/bin/github-issues/lib/candidate-relation-one.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

CR_PRESENT=no; [ -f "$CR" ] && CR_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

cat > "$MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
# Canned-response gh mock. Each invocation consumes the next response in
# $GH_MOCK_DIR: call-<n>.json (stdout) and optional call-<n>.rc (exit code).
# A missing call-<n>.json means "API failure" (exit 1, empty stdout).
printf '%s\n' "$*" >> "${GH_MOCK_ARGS_LOG:-/dev/null}"
CURSOR="${GH_MOCK_DIR}/cursor"
IDX=1; [ -f "$CURSOR" ] && IDX=$(cat "$CURSOR")
echo $((IDX + 1)) > "$CURSOR"
RESP="${GH_MOCK_DIR}/call-${IDX}.json"
RCF="${GH_MOCK_DIR}/call-${IDX}.rc"
if [ -f "$RESP" ]; then cat "$RESP"; else echo "mock: no canned response for call ${IDX}" >&2; exit 1; fi
if [ -f "$RCF" ]; then exit "$(cat "$RCF")"; fi
exit 0
MOCK
chmod +x "$MOCKDIR/gh"

# new_case <name> → creates $WORK/<name> as a fresh mock response dir, echoes it
new_case() { local d="$WORK/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# run_cr <mockdir> <slug> <numbers> → sets RC, OUT, ERR
run_cr() {
    local d="$1" slug="$2" nums="$3"
    if [ "$CR_PRESENT" != "yes" ]; then RC=127; OUT=""; ERR="candidate-relations.sh missing"; return; fi
    # Config pinning (rules/test.md): relation collection feeds the review stage, so
    # both switches are declared rather than inherited from the developer's .env.
    OUT=$(ISSUE_VERDICT_REVIEW=on ISSUE_PROVENANCE=off \
            GH_MOCK_DIR="$d" GH_MOCK_ARGS_LOG="$d/args.log" PATH="$MOCKDIR:$PATH" \
            "$RWT" 30 bash "$CR" "$slug" "$nums" 2>"$d/stderr.txt")
    RC=$?
    ERR=$(cat "$d/stderr.txt" 2>/dev/null)
}

# jq_out <node-expr over `a`> → value from $OUT
jq_out() {
    OUTJSON="$OUT" "$RWT" 12 node -e "
try { const a = JSON.parse(process.env.OUTJSON);
  const v = ($1);
  process.stdout.write(typeof v === 'object' ? JSON.stringify(v) : String(v));
} catch (e) { process.stdout.write('parse-error'); }" 2>/dev/null
}

red() { fail "$1" "RED-EXPECTED: bin/github-issues/candidate-relations.sh not yet created"; }

BATCHED_OK='{"data":{"repository":{
  "c10":{"number":10,"state":"OPEN","parent":{"number":99,"state":"OPEN","labels":{"nodes":[{"name":"meta"},{"name":"type:task"}]}},"subIssues":{"totalCount":0}},
  "c11":{"number":11,"state":"CLOSED","parent":{"number":88,"state":"OPEN","labels":{"nodes":[{"name":"type:task"}]}},"subIssues":{"totalCount":2}},
  "c12":{"number":12,"state":"OPEN","parent":null,"subIssues":{"totalCount":0}}}}}'

echo "=== R1: batched success — exit 0, parent_is_meta from the parent's labels ==="
D=$(new_case r1); printf '%s' "$BATCHED_OK" > "$D/call-1.json"
run_cr "$D" "nirecom/agents" "10,11,12"
if [ "$CR_PRESENT" != "yes" ]; then
    red "R1-exit-0"; red "R1-parent-is-meta-true"; red "R1-parent-is-meta-false"
    red "R1-parent-number"; red "R1-has-sub-issues"; red "R1-relations-mode-batched"; red "R1-single-round-trip"
else
    [ "$RC" -eq 0 ] && pass "R1-exit-0" || fail "R1-exit-0" "want exit 0, got $RC (stderr: $ERR)"
    T=$(jq_out "a.find(x=>x.number===10).parent_is_meta"); [ "$T" = "true" ] \
        && pass "R1-parent-is-meta-true" || fail "R1-parent-is-meta-true" "candidate 10's parent carries the meta label (got: $T)"
    T=$(jq_out "a.find(x=>x.number===11).parent_is_meta"); [ "$T" = "false" ] \
        && pass "R1-parent-is-meta-false" || fail "R1-parent-is-meta-false" "candidate 11's parent has no meta label (got: $T)"
    T=$(jq_out "a.find(x=>x.number===10).parent_number"); [ "$T" = "99" ] \
        && pass "R1-parent-number" || fail "R1-parent-number" "want parent_number 99 (got: $T)"
    T=$(jq_out "a.find(x=>x.number===11).has_sub_issues"); [ "$T" = "true" ] \
        && pass "R1-has-sub-issues" || fail "R1-has-sub-issues" "want has_sub_issues true for candidate 11 (got: $T)"
    printf '%s' "$ERR" | grep -q 'relations_mode: *batched' \
        && pass "R1-relations-mode-batched" || fail "R1-relations-mode-batched" "stderr lacks 'relations_mode: batched' (got: $ERR)"
    CALLS=$(wc -l < "$D/args.log" 2>/dev/null | tr -d ' '); [ "${CALLS:-0}" = "1" ] \
        && pass "R1-single-round-trip" || fail "R1-single-round-trip" "batched path must issue exactly 1 gh call (got: ${CALLS:-0})"
fi

echo ""
echo "=== R2: batched partial errors — fallback still yields correct parent_is_meta ==="
D=$(new_case r2)
cat > "$D/call-1.json" <<'JSON'
{"data":{"repository":{
  "c10":null,
  "c11":{"number":11,"state":"CLOSED","parent":null,"subIssues":{"totalCount":0}}}},
 "errors":[{"path":["repository","c10"],"message":"Something went wrong"}]}
JSON
cat > "$D/call-2.json" <<'JSON'
{"data":{"repository":{"issue":{"number":10,"state":"OPEN","parent":{"number":77,"state":"OPEN","labels":{"nodes":[{"name":"meta"}]}},"subIssues":{"totalCount":0}}}}}
JSON
run_cr "$D" "nirecom/agents" "10,11"
if [ "$CR_PRESENT" != "yes" ]; then
    red "R2-exit-0-after-fallback"; red "R2-fallback-parent-is-meta"; red "R2-relations-mode-mixed"
else
    [ "$RC" -eq 0 ] && pass "R2-exit-0-after-fallback" || fail "R2-exit-0-after-fallback" "want exit 0 once the fallback resolves, got $RC (stderr: $ERR)"
    T=$(jq_out "a.find(x=>x.number===10).parent_is_meta"); [ "$T" = "true" ] \
        && pass "R2-fallback-parent-is-meta" || fail "R2-fallback-parent-is-meta" "fallback must produce parent_is_meta from the parent's labels (got: $T)"
    printf '%s' "$ERR" | grep -qE 'relations_mode: *(mixed|fallback)' \
        && pass "R2-relations-mode-mixed" || fail "R2-relations-mode-mixed" "stderr lacks 'relations_mode: mixed' (got: $ERR)"
fi

echo ""
echo "=== R3: partial failure — exit 3, unresolved candidate still present in stdout ==="
D=$(new_case r3)
cat > "$D/call-1.json" <<'JSON'
{"data":{"repository":{
  "c10":null,
  "c11":{"number":11,"state":"OPEN","parent":null,"subIssues":{"totalCount":0}}}},
 "errors":[{"path":["repository","c10"],"message":"boom"}]}
JSON
# call-2 (the fallback for c10) is intentionally absent → mock exits 1.
run_cr "$D" "nirecom/agents" "10,11"
if [ "$CR_PRESENT" != "yes" ]; then
    red "R3-exit-3"; red "R3-unresolved-status"; red "R3-unresolved-explicit-nulls"; red "R3-resolved-sibling-intact"; red "R3-stderr-lists-unresolved"
else
    [ "$RC" -eq 3 ] && pass "R3-exit-3" || fail "R3-exit-3" "want exit 3 for partial resolution, got $RC (stderr: $ERR)"
    T=$(jq_out "a.find(x=>x.number===10).relation_status"); [ "$T" = "unresolved" ] \
        && pass "R3-unresolved-status" || fail "R3-unresolved-status" "want relation_status 'unresolved' (got: $T)"
    T=$(jq_out "(a.find(x=>x.number===10).parent_number === null) && (a.find(x=>x.number===10).parent_is_meta === false) && (a.find(x=>x.number===10).has_sub_issues === false)")
    [ "$T" = "true" ] && pass "R3-unresolved-explicit-nulls" \
        || fail "R3-unresolved-explicit-nulls" "unresolved rows must still write explicit null/false fields (got: $T)"
    T=$(jq_out "a.find(x=>x.number===11).relation_status"); [ "$T" = "resolved" ] \
        && pass "R3-resolved-sibling-intact" || fail "R3-resolved-sibling-intact" "want the sibling still 'resolved' (got: $T)"
    printf '%s' "$ERR" | grep -q '10' \
        && pass "R3-stderr-lists-unresolved" || fail "R3-stderr-lists-unresolved" "stderr must list the unresolved candidate numbers (got: $ERR)"
fi

echo ""
echo "=== R4: total failure — exit 4, stdout still a complete array ==="
D=$(new_case r4)
printf '%s' '{"errors":[{"message":"total outage"}]}' > "$D/call-1.json"
printf '1' > "$D/call-1.rc"
run_cr "$D" "nirecom/agents" "10,11"
if [ "$CR_PRESENT" != "yes" ]; then
    red "R4-exit-4"; red "R4-complete-array"; red "R4-all-unresolved"
else
    [ "$RC" -eq 4 ] && pass "R4-exit-4" || fail "R4-exit-4" "want exit 4 when no candidate resolves, got $RC (stderr: $ERR)"
    T=$(jq_out "a.length"); [ "$T" = "2" ] \
        && pass "R4-complete-array" || fail "R4-complete-array" "stdout must always carry one row per candidate (got length: $T)"
    T=$(jq_out "a.every(x=>x.relation_status==='unresolved')"); [ "$T" = "true" ] \
        && pass "R4-all-unresolved" || fail "R4-all-unresolved" "every row must be 'unresolved' (got: $T)"
fi

echo ""
echo "=== R5: parent info absent from the response — parent_is_meta stays false, no crash ==="
D=$(new_case r5)
printf '%s' '{"data":{"repository":{"c10":{"number":10,"state":"OPEN","subIssues":{"totalCount":0}}}}}' > "$D/call-1.json"
run_cr "$D" "nirecom/agents" "10"
if [ "$CR_PRESENT" != "yes" ]; then
    red "R5-no-parent-field-ok"
else
    T=$(jq_out "a.length===1 && a[0].parent_is_meta===false && a[0].parent_number===null")
    [ "$T" = "true" ] && pass "R5-no-parent-field-ok" \
        || fail "R5-no-parent-field-ok" "a response without a parent field must degrade to parent_number null / parent_is_meta false (got: $T)"
fi

echo ""
echo "=== R6/R7: argument validation ==="
D=$(new_case r6); run_cr "$D" "not-a-slug" "10"
if [ "$CR_PRESENT" != "yes" ]; then red "R6-invalid-slug"; else
    if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qi 'error'; then pass "R6-invalid-slug"
    else fail "R6-invalid-slug" "want a non-zero exit + error message for a malformed owner/repo (rc=$RC stderr=$ERR)"; fi
fi
D=$(new_case r7); run_cr "$D" "nirecom/agents" "10,abc"
if [ "$CR_PRESENT" != "yes" ]; then red "R7-invalid-number-list"; else
    if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -qi 'error'; then pass "R7-invalid-number-list"
    else fail "R7-invalid-number-list" "want a non-zero exit + error message for a malformed number list (rc=$RC stderr=$ERR)"; fi
fi

echo ""
echo "=== R8: parent resolution comes from GraphQL, never from parent-all-closed-check.sh ==="
if [ "$CR_PRESENT" != "yes" ]; then
    red "R8-graphql-parent-query"; red "R8-no-parent-inference-from-child-check"
    fail "R8-candidate-relation-one-exists" "RED-EXPECTED: bin/github-issues/lib/candidate-relation-one.sh not yet created"
else
    if grep -q 'parent' "$CR"; then pass "R8-graphql-parent-query"
    else fail "R8-graphql-parent-query" "the batched query must request the parent node"; fi
    # parent-all-closed-check.sh may only be consulted for child presence, never for parents.
    if grep -n 'parent-all-closed-check' "$CR" | grep -qi 'parent_number\|parent_is_meta'; then
        fail "R8-no-parent-inference-from-child-check" "parent-all-closed-check.sh must not feed parent_number / parent_is_meta"
    else
        pass "R8-no-parent-inference-from-child-check"
    fi
    if [ -f "$CR_ONE" ]; then pass "R8-candidate-relation-one-exists"
    else fail "R8-candidate-relation-one-exists" "RED-EXPECTED: bin/github-issues/lib/candidate-relation-one.sh not yet created"; fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
