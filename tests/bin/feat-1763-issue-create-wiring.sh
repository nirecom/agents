#!/usr/bin/env bash
# tests/bin/feat-1763-issue-create-wiring.sh
# Tests: bin/github-issues/review-survey-verdict-codex.sh, skills/issue-create/scripts/eval-confirm-gate.sh, skills/issue-create/SKILL.md
# Tags: issue-create, verdict, review, worth-filing, confirm-gate, wiring, cross-module, integration, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap: the skill body executing these steps in a live turn, and AskUserQuestion being raised
# on "confirm: yes". Mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
set -u

# Pins the seam survey artifact → review-survey-verdict-codex.sh → --out artifact → eval-confirm-gate.sh
# with real components and mocks only at codex/gh: what the reviewer writes is what the gate reads.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
RS="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/review-survey-verdict-codex.sh"
GATE="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/eval-confirm-gate.sh"
SKILL="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/SKILL.md"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

MISSING_PARTS=""
for p in "$RS" "$GATE"; do [ -f "$p" ] || MISSING_PARTS="$MISSING_PARTS $(basename "$p")"; done
CHAIN_READY=no; [ -z "$MISSING_PARTS" ] && CHAIN_READY=yes
redchain() { fail "$1" "RED-EXPECTED: chain component(s) not yet created:$MISSING_PARTS"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# External boundary 1: codex. Replays a canned verdict.
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
if [ -n "${CODEX_MOCK_OUT:-}" ] && [ -f "$CODEX_MOCK_OUT" ]; then cat "$CODEX_MOCK_OUT"; fi
MOCK
chmod +x "$MOCKDIR/codex"
# External boundary 2: gh. Never allowed to reach the network in a test.
cat > "$MOCKDIR/gh" <<'MOCK'
#!/usr/bin/env bash
echo "gh must not be called from this test" >&2
exit 1
MOCK
chmod +x "$MOCKDIR/gh"

# PATH with the real codex (and the mock) removed — the honest way to exercise the
# "no reviewer available" path now that no env switch can turn the review off.
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

make_survey() {  # <path> <verdict> <target>
    V="$2" T="$3" node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  proposal: { title: 'wiring proposal', background: 'BG', changes: 'CH' },
  verdict: process.env.V,
  same_fix: process.env.V === 'reopen',
  target: process.env.T === 'null' ? null : Number(process.env.T),
  children: [], related: [], reason: 'survey reason',
  relations_mode: 'batched', relation_errors: [],
  candidates: [{ number: 10, title: 'c10', state: 'open', labels: [], body: 'b10',
    relation_status: 'resolved', parent_number: null, parent_is_meta: false, has_sub_issues: false }]
}, null, 2));" "$(node_path "$1")"
}

# run_chain <name> <survey-verdict> <survey-target> <codex-stdout> [nocodex]
# Returns: FINAL / CONFIRM / REASONS / WORTH_INFO / GATE_RC
run_chain() {
    local name="$1" sv="$2" st="$3" cx="$4" nocodex="${5:-}"
    local B="$WORK/$name"; mkdir -p "$B"
    CHAIN_BASE="$B"
    make_survey "$B/survey.json" "$sv" "$st"
    printf '%s' "$cx" > "$B/codex-out.txt"
    FINAL="$B/final.json"
    if [ -n "$nocodex" ]; then
        env PATH="$NOCODEX_PATH" \
            "$RWT" 40 bash "$RS" --artifact "$B/survey.json" --out "$FINAL" --no-log \
            >"$B/review-stdout.txt" 2>&1
    else
        env CODEX_MOCK_OUT="$B/codex-out.txt" PATH="$MOCKDIR:$PATH" \
            "$RWT" 40 bash "$RS" --artifact "$B/survey.json" --out "$FINAL" --no-log \
            >"$B/review-stdout.txt" 2>&1
    fi
    local out
    # One argument, no session environment (#1926): everything the gate needs lives in the artifact.
    out=$("$RWT" 20 bash "$GATE" "$FINAL" 2>/dev/null)
    GATE_RC=$?
    CONFIRM=$(printf '%s\n' "$out" | sed -n 's/^confirm: *//p' | head -n 1 | tr -d '[:space:]')
    REASONS=$(printf '%s\n' "$out" | sed -n 's/^reasons: *//p' | head -n 1 | tr -d '[:space:]')
    WORTH_INFO=$(printf '%s\n' "$out" | sed -n 's/^worth_filing: *//p' | head -n 1 | tr -d '[:space:]')
}

final_q() {  # <node-expr over `d`>
    [ -f "$FINAL" ] || { printf 'no-final'; return; }
    "$RWT" 12 node -e "
try { const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  process.stdout.write(String($1)); } catch (e) { process.stdout.write('parse-error'); }" "$(node_path "$FINAL")" 2>/dev/null
}

WORTH='{"verdict":"none","target":null,"children":[],"related":[],"reason":"distinct root cause","worth_filing":true,"same_fix":false}'
NOT_WORTH='{"verdict":"none","target":null,"children":[],"related":[],"reason":"already fixed upstream in v2.1","worth_filing":false,"same_fix":false}'

echo "=== A: the reviewer affirms the issue is worth filing — nothing fires ==="
if [ "$CHAIN_READY" != "yes" ]; then
    for t in A1-review-upheld A2-artifact-carries-worth-filing A3-gate-no A4-no-provenance-in-artifact; do redchain "$t"; done
else
    run_chain a none null "$WORTH"
    S=$(final_q "d.review.status"); [ "$S" = "upheld" ] && pass "A1-review-upheld" \
        || fail "A1-review-upheld" "want review.status upheld (got: $S)"
    W=$(final_q "d.review.worth_filing"); [ "$W" = "true" ] && pass "A2-artifact-carries-worth-filing" \
        || fail "A2-artifact-carries-worth-filing" "the reviewer's boolean must reach the artifact as a boolean (got: $W)"
    [ "$CONFIRM" = "no" ] && pass "A3-gate-no" \
        || fail "A3-gate-no" "an affirmed, unchanged, non-destructive verdict must not confirm (confirm=$CONFIRM reasons=$REASONS)"
    # The gate's old third input is gone from the artifact too — a surviving key would
    # mean the writer half of the mechanism outlived the reader half.
    P=$(final_q "d.provenance === undefined && d.provenance_layer === undefined")
    [ "$P" = "true" ] && pass "A4-no-provenance-in-artifact" \
        || fail "A4-no-provenance-in-artifact" "the artifact still carries provenance fields nothing reads (got: $P)"
fi

echo ""
echo "=== B: the reviewer declines to affirm — reported on the info line, never a gate reason (#1926) ==="
# The reviewer's "not worth filing" must survive to the gate's output so CC's agreement call
# sees it, but whether to file is that call's job, not the gate's.
if [ "$CHAIN_READY" != "yes" ]; then
    for t in B1-artifact-carries-false B2-gate-no-reason-from-worth B3-info-line-reports-false; do redchain "$t"; done
else
    run_chain b none null "$NOT_WORTH"
    W=$(final_q "d.review.worth_filing"); [ "$W" = "false" ] && pass "B1-artifact-carries-false" \
        || fail "B1-artifact-carries-false" "a negative answer must survive as boolean false, not be dropped as falsy (got: $W)"
    [ "$GATE_RC|$CONFIRM|$REASONS" = "0|no|" ] && pass "B2-gate-no-reason-from-worth" \
        || fail "B2-gate-no-reason-from-worth" "worth_filing:false alone must not confirm (rc=$GATE_RC confirm=$CONFIRM reasons=$REASONS)"
    [ "$WORTH_INFO" = "false" ] && pass "B3-info-line-reports-false" \
        || fail "B3-info-line-reports-false" "want worth_filing: false on the gate's info line (got: '$WORTH_INFO')"
fi

echo ""
echo "=== C: a reviewer that omits worth_filing is not a completed review ==="
# The field is required, so an answer without it is rejected at the validator rather than
# defaulted; the gate then sees an unverified review (G4) and reports worth_filing unknown.
if [ "$CHAIN_READY" != "yes" ]; then
    for t in C1-review-invalid C2-worth-filing-null C3-gate-G4-only; do redchain "$t"; done
else
    run_chain c none null '{"verdict":"none","target":null,"children":[],"related":[],"reason":"looks new"}'
    S=$(final_q "d.review.status"); [ "$S" = "invalid" ] && pass "C1-review-invalid" \
        || fail "C1-review-invalid" "a review answer missing worth_filing is not usable (got: $S)"
    W=$(final_q "d.review.worth_filing === null"); [ "$W" = "true" ] && pass "C2-worth-filing-null" \
        || fail "C2-worth-filing-null" "an unusable review must record worth_filing as null, never as a default (got: $W)"
    [ "$CONFIRM|$REASONS|$WORTH_INFO" = "yes|G4|unknown" ] && pass "C3-gate-G4-only" \
        || fail "C3-gate-G4-only" "an unverified review fires G4 alone and reports worth unknown (confirm=$CONFIRM reasons=$REASONS worth=$WORTH_INFO)"
fi

echo ""
echo "=== D: a disagreeing reviewer reaches the gate as G2, without overwriting the survey (#2225) ==="
# codex says reopen, the survey said none: the artifact keeps the survey's verdict at top
# level, records the reviewer's under review.*, and the gate reads the dispute.
if [ "$CHAIN_READY" != "yes" ]; then
    for t in D1-review-disputed D2-survey-kept-at-top-level D3-gate-G2-not-G1; do redchain "$t"; done
else
    run_chain d none null \
        '{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect as #10","worth_filing":true,"same_fix":true}'
    S=$(final_q "d.review.status + '/' + d.review.verdict + '/' + d.review.target"); [ "$S" = "disputed/reopen/10" ] && pass "D1-review-disputed" \
        || fail "D1-review-disputed" "want review status/verdict/target disputed/reopen/10 (got: $S)"
    SV=$(final_q "d.survey.verdict + '/' + d.verdict + '/' + d.target"); [ "$SV" = "none/none/null" ] && pass "D2-survey-kept-at-top-level" \
        || fail "D2-survey-kept-at-top-level" "want survey/top-level verdict/target none/none/null (got: $SV)"
    [ "$CONFIRM|$REASONS" = "yes|G2" ] && pass "D3-gate-G2-not-G1" \
        || fail "D3-gate-G2-not-G1" "a disputed reopen keeps the non-destructive survey verdict, so only G2 fires (confirm=$CONFIRM reasons=$REASONS)"
fi

echo ""
echo "=== E: a broken review stage cannot silently disable the gate ==="
if [ "$CHAIN_READY" != "yes" ]; then
    for t in E1-review-invalid E2-gate-G4; do redchain "$t"; done
else
    run_chain e none null 'not json at all'
    S=$(final_q "d.review.status"); [ "$S" = "invalid" ] && pass "E1-review-invalid" \
        || fail "E1-review-invalid" "want review.status invalid (got: $S)"
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "E2-gate-G4"
    else
        fail "E2-gate-G4" "an unverified verdict must force the gate via G4 (confirm=$CONFIRM reasons=$REASONS)"
    fi
fi

echo ""
echo "=== F: no reviewer on the machine — skipped, not silently affirmed ==="
# A missing codex binary is the only way the review does not run. It lands on the same side
# as a failed one: G4, with no worth_filing to report.
if [ "$CHAIN_READY" != "yes" ]; then
    for t in F1-review-skipped F2-worth-filing-null F3-gate-G4-only F4-exit-zero; do redchain "$t"; done
else
    run_chain f none null "$WORTH" nocodex
    S=$(final_q "d.review.status"); [ "$S" = "skipped" ] && pass "F1-review-skipped" \
        || fail "F1-review-skipped" "want review.status skipped when codex is unavailable (got: $S)"
    W=$(final_q "d.review.worth_filing === null"); [ "$W" = "true" ] && pass "F2-worth-filing-null" \
        || fail "F2-worth-filing-null" "a review that never ran has no opinion to record (got: $W)"
    [ "$CONFIRM|$REASONS|$WORTH_INFO" = "yes|G4|unknown" ] && pass "F3-gate-G4-only" \
        || fail "F3-gate-G4-only" "a skipped review confirms via G4 and reports worth unknown (confirm=$CONFIRM reasons=$REASONS worth=$WORTH_INFO)"
    [ "$GATE_RC" -eq 0 ] && pass "F4-exit-zero" \
        || fail "F4-exit-zero" "the gate classifies rather than fails; want exit 0 (got: $GATE_RC)"
fi

echo ""
echo "=== G: the skill wires the steps in the contracted order ==="
# The chain above proves the components compose. This proves the skill is what
# composes them — otherwise the wiring is only ever exercised by this test.
if [ ! -f "$SKILL" ]; then
    for t in G1-skill-invokes-all-steps G2-skill-order-review-before-gate G3-no-provenance-step; do
        fail "$t" "skills/issue-create/SKILL.md not found"
    done
else
    MISS=""
    for s in review-survey-verdict-codex eval-confirm-gate; do
        grep -qF "$s" "$SKILL" || MISS="$MISS $s"
    done
    [ -z "$MISS" ] && pass "G1-skill-invokes-all-steps" \
        || fail "G1-skill-invokes-all-steps" "RED-EXPECTED: step(s) not referenced by SKILL.md:$MISS"

    I_REV=$(grep -nF 'review-survey-verdict-codex' "$SKILL" | head -n 1 | cut -d: -f1)
    I_GATE=$(grep -nF 'eval-confirm-gate' "$SKILL" | head -n 1 | cut -d: -f1)
    if [ -n "$I_REV" ] && [ -n "$I_GATE" ] && [ "$I_REV" -lt "$I_GATE" ]; then
        pass "G2-skill-order-review-before-gate"
    else
        fail "G2-skill-order-review-before-gate" "RED-EXPECTED: the gate must be documented after the review that feeds it (review=$I_REV gate=$I_GATE)"
    fi

    # The consume step is deleted: a SKILL.md that still tells the model to run it
    # would leave the documented procedure calling a CLI that no longer exists.
    if grep -qF 'issue-provenance' "$SKILL"; then
        fail "G3-no-provenance-step" "RED-EXPECTED: SKILL.md still instructs a provenance step: $(grep -nF 'issue-provenance' "$SKILL" | head -n 2 | tr '\n' ' ')"
    else
        pass "G3-no-provenance-step"
    fi
fi

echo ""
echo "=== H: gh was never invoked anywhere in the chain ==="
# A wiring test that reached the network would be both flaky and destructive.
if [ "$CHAIN_READY" != "yes" ]; then
    redchain "H1-no-gh-calls"
else
    if grep -rqF 'gh must not be called' "$WORK"/*/review-stdout.txt 2>/dev/null; then
        fail "H1-no-gh-calls" "some step in the chain shelled out to gh"
    else
        pass "H1-no-gh-calls"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
