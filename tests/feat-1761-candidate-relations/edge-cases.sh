#!/usr/bin/env bash
# tests/feat-1761-candidate-relations/edge-cases.sh
# Tests: bin/github-issues/candidate-relations.sh, bin/github-issues/lib/candidate-relation-one.sh
# Tags: issue-create, verdict, candidate-relations, graphql, gh-mock, edge-cases, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real api.github.com behaviour for oversized batches, NOT_FOUND and FORBIDDEN payloads.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Split out of tests/feat-1761-candidate-relations.sh (rules/coding/file-split.md
# Pattern A, 300-line WARN). The sibling file owns the contracted happy/fallback
# paths; this one owns the degenerate candidate lists and repository-level failures.
# The setup below is duplicated deliberately: a shared helpers.sh would couple two
# files that must stay independently runnable by the test runner.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

echo "=== R9: candidate-list edge cases — bounded calls, deterministic output ==="
# The number list is assembled upstream from a survey, so it can legitimately be
# empty, hold one entry, repeat an entry, or exceed the batch ceiling. Each shape
# must produce a complete array and a defined exit status, and must never fan out
# into an unbounded number of API calls.
calls_made() { wc -l < "$1/args.log" 2>/dev/null | tr -d ' '; }

if [ "$CR_PRESENT" != "yes" ]; then
    for t in R9a-empty-list R9b-single R9c-duplicates-collapse R9d-over-25-bounded \
             R9e-large-number-all-unresolved-exit-4 R9f-all-nonexistent-exit-4; do red "$t"; done
else
    # Empty list: nothing to resolve, so nothing may be asked of the API.
    D=$(new_case r9a); run_cr "$D" "nirecom/agents" ""
    if [ "$OUT" = "[]" ] || [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "[]" ]; then
        if [ "$(calls_made "$D")" = "" ] || [ "$(calls_made "$D")" = "0" ]; then
            pass "R9a-empty-list"
        else
            fail "R9a-empty-list" "an empty candidate list must not call gh at all ($(calls_made "$D") call(s))"
        fi
    else
        fail "R9a-empty-list" "an empty candidate list must yield an empty array (rc=$RC out='$OUT')"
    fi

    D=$(new_case r9b)
    printf '%s' '{"data":{"repository":{"c10":{"number":10,"state":"OPEN","parent":null,"subIssues":{"totalCount":0}}}}}' > "$D/call-1.json"
    run_cr "$D" "nirecom/agents" "10"
    T=$(jq_out "a.length"); C=$(calls_made "$D")
    if [ "$T" = "1" ] && [ "$C" = "1" ]; then pass "R9b-single"
    else fail "R9b-single" "a single candidate must be one row from one call (rows=$T calls=$C rc=$RC)"; fi

    # Duplicates must not multiply the API cost or the output rows.
    D=$(new_case r9c)
    printf '%s' '{"data":{"repository":{"c10":{"number":10,"state":"OPEN","parent":null,"subIssues":{"totalCount":0}}}}}' > "$D/call-1.json"
    run_cr "$D" "nirecom/agents" "10,10,10"
    T=$(jq_out "a.length")
    if [ "$T" = "1" ]; then pass "R9c-duplicates-collapse"
    else fail "R9c-duplicates-collapse" "a repeated candidate number must collapse to one row (rows=$T rc=$RC)"; fi

    # Over the documented 25-candidate ceiling: either rejected outright or chunked,
    # but never one call per candidate.
    D=$(new_case r9d)
    NUMS=$(seq 1 40 | paste -sd, -)
    for i in $(seq 1 4); do
        printf '%s' '{"data":{"repository":{}}}' > "$D/call-$i.json"
    done
    run_cr "$D" "nirecom/agents" "$NUMS"
    C=$(calls_made "$D"); [ -z "$C" ] && C=0
    if [ "$RC" -ne 0 ] && [ "$C" -le 1 ]; then
        pass "R9d-over-25-bounded"
    elif [ "$C" -le 4 ]; then
        pass "R9d-over-25-bounded"
    else
        fail "R9d-over-25-bounded" "40 candidates produced $C API calls — the batch ceiling is not enforced (rc=$RC)"
    fi

    # A number far outside any plausible issue range must still be handled as data,
    # not crash the alias construction. The API answers `null` — the issue does not
    # exist — so this candidate is unresolved, and it is the ONLY candidate.
    #
    # The exit code is pinned to exactly 4, not "one of 0/3/4". The three codes are
    # not interchangeable: 0 tells the caller every relation is trustworthy, 3 tells
    # it some rows are guesses, 4 tells it none are. Accepting 0 here would accept an
    # implementation that reports a null candidate as a resolved orphan — and an
    # orphan with no parent is precisely what IC-C3 (make-parent) keys on. A loose
    # assertion at this seam is how a wrong verdict gets rationalised downstream.
    D=$(new_case r9e)
    printf '%s' '{"data":{"repository":{"c999999999":null}}}' > "$D/call-1.json"
    printf '%s' '{"data":{"repository":{"c999999999":null}}}' > "$D/call-2.json"
    run_cr "$D" "nirecom/agents" "999999999"
    T=$(jq_out "a.length")
    U=$(jq_out "a.filter(x => x.relation_status !== 'resolved').length")
    if [ "$T" = "1" ] && [ "$U" = "1" ] && [ "$RC" -eq 4 ]; then
        pass "R9e-large-number-all-unresolved-exit-4"
    else
        fail "R9e-large-number-all-unresolved-exit-4" "a nonexistent candidate is unresolved, and with no resolved rows the contract is exit 4 (rows=$T unresolved=$U rc=$RC)"
    fi

    # R9f: the general form of the same rule — several candidates, none of which the
    # repository knows about. "All unresolved" must be exit 4 regardless of how many
    # rows there are, and every row must still be present and marked.
    D=$(new_case r9f)
    printf '%s' '{"data":{"repository":{"c8001":null,"c8002":null,"c8003":null}}}' > "$D/call-1.json"
    run_cr "$D" "nirecom/agents" "8001,8002,8003"
    T=$(jq_out "a.length")
    U=$(jq_out "a.filter(x => x.relation_status !== 'resolved').length")
    if [ "$T" = "3" ] && [ "$U" = "3" ] && [ "$RC" -eq 4 ]; then
        pass "R9f-all-nonexistent-exit-4"
    else
        fail "R9f-all-nonexistent-exit-4" "want exit 4 with 3 complete unresolved rows (rows=$T unresolved=$U rc=$RC)"
    fi
fi

echo ""
echo "=== R12: chunked collection is complete and deterministic across the boundary ==="
# R9d only bounds the CALL COUNT. Chunking introduces a second, quieter risk: the
# rows come back in N pieces and have to be reassembled. A reassembly that drops the
# tail chunk, or that orders rows by arrival, produces a plausible-looking array that
# silently omits or reshuffles candidates — and the review's allowlist is built from
# exactly that array.
if [ "$CR_PRESENT" != "yes" ]; then
    red "R12a-chunked-output-complete"; red "R12b-chunked-output-deterministic"
else
    # 30 candidates spanning the 25-item ceiling. Every chunk response is populated so
    # that a dropped chunk shows up as missing rows rather than as unresolved rows.
    NUMS=$(seq 101 130 | paste -sd, -)
    mk_chunk_responses() {  # <dir>
        node -e "
const fs=require('fs');
const d=process.argv[1];
const all=[]; for (let n=101;n<=130;n++) all.push(n);
// Same payload in every slot: whichever chunk boundary the implementation picks,
// the alias it asks for is present. Unrequested aliases are ignored by the reader.
const repo={}; all.forEach(n => { repo['c'+n]={number:n,state:'OPEN',parent:null,subIssues:{totalCount:0}}; });
for (let i=1;i<=8;i++) fs.writeFileSync(d+'/call-'+i+'.json', JSON.stringify({data:{repository:repo}}));
" "$1"
    }

    D=$(new_case r12a); mk_chunk_responses "$D"
    run_cr "$D" "nirecom/agents" "$NUMS"
    T=$(jq_out "a.length")
    MISS=$(jq_out "(() => { const s=new Set(a.map(x=>x.number)); const m=[]; for(let n=101;n<=130;n++) if(!s.has(n)) m.push(n); return m; })()")
    if [ "$T" = "30" ] && [ "$MISS" = "[]" ]; then
        pass "R12a-chunked-output-complete"
    else
        fail "R12a-chunked-output-complete" "chunked collection lost rows (rows=$T missing=$MISS rc=$RC)"
    fi
    FIRST="$OUT"

    # Determinism across the chunk boundary, with the input order shuffled: the row
    # order must be a function of the candidate set, not of chunk arrival order.
    D=$(new_case r12b); mk_chunk_responses "$D"
    run_cr "$D" "nirecom/agents" "$(seq 101 130 | sort -r | paste -sd, -)"
    ORDER_A=$(OUTJSON="$FIRST" node -e "try{process.stdout.write(JSON.parse(process.env.OUTJSON).map(x=>x.number).join(','))}catch(e){process.stdout.write('parse-error')}" 2>/dev/null)
    ORDER_B=$(jq_out "a.map(x=>x.number).join(',')")
    if [ -n "$ORDER_A" ] && [ "$ORDER_A" != "parse-error" ] && [ "$ORDER_A" = "$ORDER_B" ]; then
        pass "R12b-chunked-output-deterministic"
    else
        fail "R12b-chunked-output-deterministic" "row order depends on input or chunk order (A=$ORDER_A B=$ORDER_B)"
    fi
fi

echo ""
echo "=== R10: repository-level API failures degrade, they do not corrupt ==="
# NOT_FOUND and FORBIDDEN are whole-request failures: no candidate can be resolved.
# The contract says exit 4 with a complete array of unresolved rows — a truncated or
# absent array would let the cascade read "no parent" and fire IC-C3 wrongly.
if [ "$CR_PRESENT" != "yes" ]; then
    red "R10a-repo-not-found"; red "R10b-permission-denied"
else
    for CASE in "r10a:NOT_FOUND:R10a-repo-not-found" "r10b:FORBIDDEN:R10b-permission-denied"; do
        NAME="${CASE%%:*}"; REST="${CASE#*:}"; CODE="${REST%%:*}"; LABEL="${REST##*:}"
        D=$(new_case "$NAME")
        for i in 1 2 3 4 5; do
            printf '{"errors":[{"type":"%s","message":"api error"}]}' "$CODE" > "$D/call-$i.json"
            printf '1' > "$D/call-$i.rc"
        done
        run_cr "$D" "nirecom/agents" "10,11"
        T=$(jq_out "a.length")
        U=$(jq_out "a.filter(x => x.relation_status !== 'resolved').length")
        if [ "$RC" -eq 4 ] && [ "$T" = "2" ] && [ "$U" = "2" ]; then
            pass "$LABEL"
        else
            fail "$LABEL" "want exit 4 with 2 complete unresolved rows (rc=$RC rows=$T unresolved=$U)"
        fi
    done
fi

echo ""
echo "=== R11: identical input produces identical output (deterministic ordering) ==="
if [ "$CR_PRESENT" != "yes" ]; then
    red "R11-deterministic"
else
    RUN_ONE=""
    for n in 1 2; do
        D=$(new_case "r11-$n")
        printf '%s' "$BATCHED_OK" > "$D/call-1.json"
        run_cr "$D" "nirecom/agents" "12,10,11"
        if [ "$n" = "1" ]; then RUN_ONE="$OUT"; fi
    done
    if [ -n "$RUN_ONE" ] && [ "$RUN_ONE" = "$OUT" ]; then
        pass "R11-deterministic"
    else
        fail "R11-deterministic" "two identical runs produced different output — row order must be deterministic"
    fi
fi

echo ""

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
