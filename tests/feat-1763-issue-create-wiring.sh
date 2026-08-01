#!/usr/bin/env bash
# tests/feat-1763-issue-create-wiring.sh
# Tests: hooks/issue-provenance-mint.js, bin/github-issues/issue-provenance, bin/github-issues/review-survey-verdict-codex.sh, skills/issue-create/scripts/eval-confirm-gate.sh, skills/issue-create/SKILL.md
# Tags: issue-create, provenance, verdict, confirm-gate, wiring, cross-module, integration, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The skill body actually executing these steps in a live Claude Code turn, and
#   AskUserQuestion actually being raised. That is tests/TL3-hook-issue-provenance-mint.sh
#   plus the skill-orchestration verification gate.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Every sibling test pins ONE seam. This file pins the seams between them, with real
# components on both sides of each join and mocks only at the two external boundaries
# (codex, gh). The chain under test:
#
#   UserPromptSubmit → mint token          (hooks/issue-provenance-mint.js)
#     → issue-provenance --consume         → provenance + layer
#       → review-survey-verdict-codex.sh   → the --out artifact
#         → eval-confirm-gate.sh           → confirm: yes|no
#
# The property that no single-seam test can establish: the provenance decided at the
# FIRST join is the same provenance the LAST join gates on. A seam that silently
# defaults to `user-explicit` would pass every isolated test while disabling the gate.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
_AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
HOOK="$AGENTS_DIR/hooks/issue-provenance-mint.js"
CLI="$AGENTS_DIR/bin/github-issues/issue-provenance"
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
GATE="$AGENTS_DIR/skills/issue-create/scripts/eval-confirm-gate.sh"
SKILL="$AGENTS_DIR/skills/issue-create/SKILL.md"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

MISSING_PARTS=""
for p in "$HOOK" "$CLI" "$RS" "$GATE"; do [ -f "$p" ] || MISSING_PARTS="$MISSING_PARTS $(basename "$p")"; done
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

SID="cc-session-wiring"

# new_env <name> <workflow-active: yes|no> <newest-user-message>
new_env() {
    local base="$WORK/$1"
    mkdir -p "$base/state" "$base/plans" "$base/cwd"
    printf 'Session-ID: %s\n' "$SID" > "$base/cwd/WORKTREE_NOTES.md"
    : > "$base/plans/$SID-intent.md"
    MSG="$3" node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({type:'user',message:{role:'user',content:process.env.MSG}}) + '\n');
" "$(node_path "$base/transcript.jsonl")"
    printf '%s' "$(node_path "$base/transcript.jsonl")" > "$base/state/$SID.session-transcript"
    # "Workflow active" means PART WAY through — a step already off `pending` AND a
    # step not yet terminal. An all-complete state is a FINISHED workflow and reads
    # inactive, which would let layer C grant `user-explicit` and quietly turn every
    # mid-workflow chain below into a user-explicit one.
    [ "$2" = "yes" ] && printf '%s' \
        '{"steps":{"research":{"status":"complete"},"write_code":{"status":"pending"}}}' \
        > "$base/state/$SID.json"
    printf '%s' "$base"
}

env_common() {  # <base> → prints env assignments consumed via `env`
    printf 'CLAUDE_WORKFLOW_DIR=%s\nWORKFLOW_PLANS_DIR=%s\nAGENTS_CONFIG_DIR=%s\nCLAUDE_CODE_SESSION_ID=%s\n' \
        "$(node_path "$1/state")" "$(node_path "$1/plans")" "$_AGENTS_DIR_NODE" "$SID"
}

fire_hook() {  # <base> <prompt>
    local base="$1" prompt="$2"
    local payload
    payload=$(PROMPT="$prompt" TP="$(node_path "$base/transcript.jsonl")" node -e "
process.stdout.write(JSON.stringify({session_id:'$SID',prompt:process.env.PROMPT,
  transcript_path:process.env.TP,cwd:process.argv[1]}));" "$(node_path "$base/cwd")")
    ( cd "$base/cwd" && env $(env_common "$base") ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=on \
        "$RWT" 15 node "$HOOK" <<< "$payload" >/dev/null 2>&1 )
}

consume() {  # <base> → PROV / LAYER
    PROV=$( ( cd "$1/cwd" && env $(env_common "$1") \
        ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=on \
        "$RWT" 20 bash "$CLI" --consume 2>"$1/prov-stderr.txt" ) )
    PROV=$(printf '%s' "$PROV" | tr -d '[:space:]')
    LAYER=$(sed -n 's/^layer: *//p' "$1/prov-stderr.txt" 2>/dev/null | head -n 1 | tr -d '[:space:]')
}

make_survey() {  # <path> <verdict> <target>
    V="$2" T="$3" node -e "
const fs=require('fs');
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 2,
  proposal: { title: 'wiring proposal', background: 'BG', changes: 'CH' },
  verdict: process.env.V, target: process.env.T === 'null' ? null : Number(process.env.T),
  children: [], related: [], reason: 'survey reason',
  relations_mode: 'batched', relation_errors: [],
  candidates: [{ number: 10, title: 'c10', state: 'open', labels: [], body: 'b10',
    relation_status: 'resolved', parent_number: null, parent_is_meta: false, has_sub_issues: false }]
}, null, 2));" "$(node_path "$1")"
}

# run_chain <name> <prompt> <workflow-active> <newest-user-msg> <survey-verdict> <survey-target>
#           <codex-stdout> <severity-label>
# Returns: PROV / LAYER / FINAL / CONFIRM / REASONS / GATE_RC
run_chain() {
    local name="$1" prompt="$2" active="$3" msg="$4" sv="$5" st="$6" cx="$7" sev="$8"
    local B; B=$(new_env "$name" "$active" "$msg")
    CHAIN_BASE="$B"
    [ -n "$prompt" ] && fire_hook "$B" "$prompt"
    consume "$B"
    make_survey "$B/survey.json" "$sv" "$st"
    printf '%s' "$cx" > "$B/codex-out.txt"
    FINAL="$B/final.json"
    env $(env_common "$B") ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=on \
        ISSUE_PROVENANCE_VALUE="$PROV" ISSUE_PROVENANCE_LAYER="$LAYER" \
        CODEX_MOCK_OUT="$B/codex-out.txt" PATH="$MOCKDIR:$PATH" \
        "$RWT" 40 bash "$RS" --artifact "$B/survey.json" --out "$FINAL" --no-log >"$B/review-stdout.txt" 2>&1
    local out
    # The gate re-resolves provenance itself (issue-provenance --result) instead of
    # believing the value handed to it, so it MUST run under the same session env as
    # the consume call above — otherwise it looks in a different workflow dir, finds
    # no decision record, and every row degrades to G3 regardless of the real chain.
    out=$(env $(env_common "$B") ISSUE_PROVENANCE=on ISSUE_VERDICT_REVIEW=on \
        "$RWT" 20 bash "$GATE" "$FINAL" "$PROV" "$sev" 2>/dev/null)
    GATE_RC=$?
    CONFIRM=$(printf '%s\n' "$out" | sed -n 's/^confirm: *//p' | head -n 1 | tr -d '[:space:]')
    REASONS=$(printf '%s\n' "$out" | sed -n 's/^reasons: *//p' | head -n 1 | tr -d '[:space:]')
}

final_q() {  # <node-expr over `d`>
    [ -f "$FINAL" ] || { printf 'no-final'; return; }
    "$RWT" 12 node -e "
try { const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  process.stdout.write(String($1)); } catch (e) { process.stdout.write('parse-error'); }" "$(node_path "$FINAL")" 2>/dev/null
}

HONEST_NONE='{"verdict":"none","target":null,"children":[],"related":[],"reason":"distinct root cause"}'

echo "=== A: layer A — an explicit /issue-create turn suppresses the gate end to end ==="
if [ "$CHAIN_READY" != "yes" ]; then
    for t in A1-provenance-user-explicit A2-layer-A A3-artifact-records-provenance A4-artifact-records-layer A5-gate-no; do redchain "$t"; done
else
    run_chain a "/issue-create the flaky provenance hook" yes "run the tests please" none null "$HONEST_NONE" "severity:low"
    [ "$PROV" = "user-explicit" ] && pass "A1-provenance-user-explicit" \
        || fail "A1-provenance-user-explicit" "the minted token must survive to the consume seam (got: '${PROV:-<none>}')"
    [ "$LAYER" = "A" ] && pass "A2-layer-A" || fail "A2-layer-A" "want layer A (got: '${LAYER:-<none>}')"
    P=$(final_q "d.provenance");       [ "$P" = "user-explicit" ] && pass "A3-artifact-records-provenance" \
        || fail "A3-artifact-records-provenance" "the --out artifact must carry the consumed provenance (got: $P)"
    L=$(final_q "d.provenance_layer"); [ "$L" = "A" ] && pass "A4-artifact-records-layer" \
        || fail "A4-artifact-records-layer" "the --out artifact must carry the observation layer (got: $L)"
    # verdict none + upheld + user-explicit ⇒ nothing fires.
    [ "$CONFIRM" = "no" ] && pass "A5-gate-no" \
        || fail "A5-gate-no" "an explicitly-requested, unchanged, non-destructive verdict must not confirm (confirm=$CONFIRM reasons=$REASONS)"
fi

echo ""
echo "=== B: layer B — a natural-language request in the transcript, no token ==="
if [ "$CHAIN_READY" != "yes" ]; then
    for t in B1-provenance-user-explicit B2-layer-B B3-gate-no; do redchain "$t"; done
else
    # No hook turn at all: the classification must come from re-reading the transcript.
    run_chain b "" yes "この件、チケット起票しておいて" none null "$HONEST_NONE" "severity:low"
    [ "$PROV" = "user-explicit" ] && pass "B1-provenance-user-explicit" \
        || fail "B1-provenance-user-explicit" "a transcript-derived explicit request must still classify as user-explicit (got: '${PROV:-<none>}')"
    [ "$LAYER" = "B" ] && pass "B2-layer-B" || fail "B2-layer-B" "want layer B (got: '${LAYER:-<none>}')"
    [ "$CONFIRM" = "no" ] && pass "B3-gate-no" || fail "B3-gate-no" "confirm=$CONFIRM reasons=$REASONS"
fi

echo ""
echo "=== C: layer C — no workflow running, so an unattributed request is not mid-workflow ==="
if [ "$CHAIN_READY" != "yes" ]; then
    for t in C1-provenance-user-explicit C2-layer-C C3-gate-no; do redchain "$t"; done
else
    run_chain c "" no "fix the typo in the readme" none null "$HONEST_NONE" "severity:low"
    [ "$PROV" = "user-explicit" ] && pass "C1-provenance-user-explicit" \
        || fail "C1-provenance-user-explicit" "with no workflow active there is no mid-workflow context to attribute to (got: '${PROV:-<none>}')"
    [ "$LAYER" = "C" ] && pass "C2-layer-C" || fail "C2-layer-C" "want layer C (got: '${LAYER:-<none>}')"
    [ "$CONFIRM" = "no" ] && pass "C3-gate-no" || fail "C3-gate-no" "confirm=$CONFIRM reasons=$REASONS"
fi

echo ""
echo "=== D: mid-workflow — no token, no request in the transcript, workflow active ==="
# The case the whole feature exists for: Claude decided to file an issue on its own.
if [ "$CHAIN_READY" != "yes" ]; then
    for t in D1-provenance-mid-workflow D2-layer-none D3-artifact-records-mid-workflow D4-gate-yes-G3 D5-high-severity-suppresses-G3 D6-high-severity-carveout-not-elevation; do redchain "$t"; done
else
    run_chain d "" yes "run the tests please" none null "$HONEST_NONE" "severity:low"
    [ "$PROV" = "mid-workflow" ] && pass "D1-provenance-mid-workflow" \
        || fail "D1-provenance-mid-workflow" "an unrequested issue during an active workflow must be mid-workflow (got: '${PROV:-<none>}')"
    [ "$LAYER" = "none" ] && pass "D2-layer-none" || fail "D2-layer-none" "want layer none (got: '${LAYER:-<none>}')"
    P=$(final_q "d.provenance"); [ "$P" = "mid-workflow" ] && pass "D3-artifact-records-mid-workflow" \
        || fail "D3-artifact-records-mid-workflow" "the artifact must carry mid-workflow (got: $P)"
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G3'; then
        pass "D4-gate-yes-G3"
    else
        fail "D4-gate-yes-G3" "mid-workflow at non-high severity must confirm via G3 (confirm=$CONFIRM reasons=$REASONS)"
    fi
    # D5 differs from D4 in exactly one input: the severity label. D6 pins that the
    # suppression really is the severity carve-out and not an accidentally elevated
    # provenance — without it, a chain that leaked `user-explicit` would pass D5 too.
    run_chain d2 "" yes "run the tests please" none null "$HONEST_NONE" "severity:high"
    [ "$CONFIRM" = "no" ] && pass "D5-high-severity-suppresses-G3" \
        || fail "D5-high-severity-suppresses-G3" "high severity is the documented G3 exemption (confirm=$CONFIRM reasons=$REASONS)"
    [ "$PROV" = "mid-workflow" ] && pass "D6-high-severity-carveout-not-elevation" \
        || fail "D6-high-severity-carveout-not-elevation" "D5 must pass via the severity carve-out over a mid-workflow provenance, not via an elevated one (got: '${PROV:-<none>}')"
fi

echo ""
echo "=== E: the review stage's replacement reaches the gate as G2 ==="
# Two joins at once: codex replaces the verdict, the artifact preserves the survey's,
# and the gate reads the difference. Any join that flattened the artifact would break
# only here.
if [ "$CHAIN_READY" != "yes" ]; then
    for t in E1-review-replaced E2-survey-preserved E3-gate-G1-and-G2; do redchain "$t"; done
else
    run_chain e "/issue-create please" yes "run the tests please" none null \
        '{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect as #10"}' "severity:high"
    S=$(final_q "d.review.status"); [ "$S" = "replaced" ] && pass "E1-review-replaced" \
        || fail "E1-review-replaced" "want review.status replaced (got: $S)"
    SV=$(final_q "d.survey.verdict"); [ "$SV" = "none" ] && pass "E2-survey-preserved" \
        || fail "E2-survey-preserved" "the survey verdict must be preserved for G2 (got: $SV)"
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G1' && printf '%s' "$REASONS" | grep -q 'G2'; then
        pass "E3-gate-G1-and-G2"
    else
        fail "E3-gate-G1-and-G2" "a reopen produced by replacement must fire both G1 and G2 (confirm=$CONFIRM reasons=$REASONS)"
    fi
fi

echo ""
echo "=== F: a broken review stage cannot silently disable the gate ==="
if [ "$CHAIN_READY" != "yes" ]; then
    for t in F1-review-invalid F2-gate-G4; do redchain "$t"; done
else
    run_chain f "/issue-create please" yes "run the tests please" none null 'not json at all' "severity:high"
    S=$(final_q "d.review.status"); [ "$S" = "invalid" ] && pass "F1-review-invalid" \
        || fail "F1-review-invalid" "want review.status invalid (got: $S)"
    if [ "$CONFIRM" = "yes" ] && printf '%s' "$REASONS" | grep -q 'G4'; then
        pass "F2-gate-G4"
    else
        fail "F2-gate-G4" "an unverified verdict must force the gate via G4 (confirm=$CONFIRM reasons=$REASONS)"
    fi
fi

echo ""
echo "=== G: the skill wires the steps in the contracted order ==="
# The chain above proves the components compose. This proves the skill is what
# composes them — otherwise the wiring is only ever exercised by this test.
if [ ! -f "$SKILL" ]; then
    fail "G1-skill-invokes-all-steps" "skills/issue-create/SKILL.md not found"
    fail "G2-skill-order-consume-before-gate" "skills/issue-create/SKILL.md not found"
else
    MISS=""
    for s in issue-provenance review-survey-verdict-codex eval-confirm-gate; do
        grep -qF "$s" "$SKILL" || MISS="$MISS $s"
    done
    [ -z "$MISS" ] && pass "G1-skill-invokes-all-steps" \
        || fail "G1-skill-invokes-all-steps" "RED-EXPECTED: step(s) not referenced by SKILL.md:$MISS"

    I_CONS=$(grep -nF 'issue-provenance' "$SKILL" | head -n 1 | cut -d: -f1)
    I_REV=$(grep -nF 'review-survey-verdict-codex' "$SKILL" | head -n 1 | cut -d: -f1)
    I_GATE=$(grep -nF 'eval-confirm-gate' "$SKILL" | head -n 1 | cut -d: -f1)
    if [ -n "$I_CONS" ] && [ -n "$I_REV" ] && [ -n "$I_GATE" ] && [ "$I_CONS" -lt "$I_GATE" ] && [ "$I_REV" -lt "$I_GATE" ]; then
        pass "G2-skill-order-consume-before-gate"
    else
        fail "G2-skill-order-consume-before-gate" "RED-EXPECTED: the gate must be documented after both of its inputs (consume=$I_CONS review=$I_REV gate=$I_GATE)"
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
