#!/usr/bin/env bash
# tests/feat-1761-verdict-replacement.sh
# Tests: bin/github-issues/review-survey-verdict-codex.sh, bin/github-issues/lib/validate-review-verdict.js, bin/lib/last-json-object.js
# Tags: issue-create, verdict, review, codex, replacement, gh-mock, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real `codex exec` latency, prompt-size limits and non-deterministic output.
# - The /issue-create skill actually invoking this script at Phase 2.5.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S13 — the highest-priority behaviour of this PR: a valid review verdict REPLACES the
# survey verdict in BOTH directions (escalation and de-escalation), and every failure
# mode folds into "upheld survey verdict + a gate-forcing review_result".
#
# Output contract asserted here:
#   stdout line 1  = "## Issue Verdict Review: PERFORMED|SKIPPED — …|FAILED — …"
#   stdout last ln = "review_result: replaced|upheld|invalid|skipped"
#   exit           = 0 always
#   --out          = schema-v2 final artifact with verdict/target/children/related/reason
#                    + survey{} + review{status,…}

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
red()  { fail "$1" "RED-EXPECTED: bin/github-issues/review-survey-verdict-codex.sh not yet created"; }

RS_PRESENT=no; [ -f "$RS" ] && RS_PRESENT=yes

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"

# codex mock: records the prompt it received, then replays $CODEX_MOCK_OUT.
# CODEX_MOCK_SLEEP simulates a hang so the wrapper's timeout can be exercised.
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
[ -n "${CODEX_MOCK_SLEEP:-}" ] && sleep "$CODEX_MOCK_SLEEP"
if [ -n "${CODEX_MOCK_OUT:-}" ] && [ -f "$CODEX_MOCK_OUT" ]; then cat "$CODEX_MOCK_OUT"; fi
exit "${CODEX_MOCK_RC:-0}"
MOCK
chmod +x "$MOCKDIR/codex"

# --- survey artifact fixtures (schema v2). CAND = {10, 11}; PARENTS = {99} -------
write_artifact() {  # <path> <survey-verdict> <survey-target> [--no-proposal] [--upper-state]
    local path="$1" v="$2" t="$3"; shift 3
    local proposal='"proposal": { "title": "Fix the flaky provenance hook", "background": "BG text", "changes": "CH text" },'
    # Default casing is the lowercase the artifact schema is written in. --upper-state
    # reproduces what `gh issue view --json state` actually answers (#1862), so a
    # fixture built the way a real survey builds one can be exercised end-to-end.
    local S_OPEN="open" S_CLOSED="closed"
    local flag
    for flag in "$@"; do
        case "$flag" in
            --no-proposal) proposal='' ;;
            --upper-state) S_OPEN="OPEN"; S_CLOSED="CLOSED" ;;
        esac
    done
    cat > "$path" <<JSON
{ "schema_version": 2,
  $proposal
  "verdict": "$v", "target": $t, "children": [], "related": [],
  "reason": "survey reason",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "$S_OPEN", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "$S_CLOSED", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON
}

# run_review <case> <artifact> <codex-out-content> [env assignments...] → RC/OUT/FIRST/LAST/FINAL
run_review() {
    local name="$1" artifact="$2" codexout="$3"; shift 3
    CASE_DIR="$WORK/$name"; mkdir -p "$CASE_DIR"
    printf '%s' "$codexout" > "$CASE_DIR/codex-out.txt"
    FINAL="$CASE_DIR/final.json"
    if [ "$RS_PRESENT" != "yes" ]; then RC=127; OUT=""; FIRST=""; LAST=""; return; fi
    OUT=$(env "$@" \
            CODEX_MOCK_OUT="$CASE_DIR/codex-out.txt" \
            CODEX_PROMPT_LOG="$CASE_DIR/prompt.txt" \
            PATH="$MOCKDIR:$PATH" \
            "$RWT" 40 bash "$RS" --artifact "$artifact" --out "$FINAL" --no-log 2>"$CASE_DIR/stderr.txt")
    RC=$?
    FIRST=$(printf '%s\n' "$OUT" | head -n 1)
    LAST=$(printf '%s\n' "$OUT" | grep -E '^review_result:' | tail -n 1)
}

# final_q <node-expr over `d`>
final_q() {
    [ -f "${FINAL:-/nonexistent}" ] || { printf 'no-final'; return; }
    "$RWT" 12 node -e "
try { const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
  const v = ($1); process.stdout.write(typeof v === 'object' ? JSON.stringify(v) : String(v));
} catch (e) { process.stdout.write('parse-error'); }" "$(node_path "$FINAL")" 2>/dev/null
}

assert_case() {  # <label> <want-review_result> <want-final-verdict>
    local label="$1" wantrr="$2" wantv="$3"
    if [ "$RS_PRESENT" != "yes" ]; then red "$label-review_result"; red "$label-final-verdict"; red "$label-exit-0"; return; fi
    [ "$RC" -eq 0 ] && pass "$label-exit-0" || fail "$label-exit-0" "want exit 0 (got $RC)"
    if [ "$LAST" = "review_result: $wantrr" ]; then pass "$label-review_result"
    else fail "$label-review_result" "want 'review_result: $wantrr' as the last line (got: '${LAST:-<none>}')"; fi
    local gv; gv=$(final_q "d.verdict")
    if [ "$gv" = "$wantv" ]; then pass "$label-final-verdict"
    else fail "$label-final-verdict" "want final verdict '$wantv' (got: '$gv')"; fi
}

ART_NONE="$WORK/survey-none.json";     write_artifact "$ART_NONE"   none   null
ART_REOPEN="$WORK/survey-reopen.json"; write_artifact "$ART_REOPEN" reopen 10
ART_NOPROP="$WORK/survey-noprop.json"; write_artifact "$ART_NOPROP" none   null --no-proposal
# Uppercase-state counterparts of ART_NONE / ART_REOPEN (#1862) — same survey verdicts,
# only the candidate `state` casing differs.
ART_NONE_UPPER="$WORK/survey-none-upper.json";     write_artifact "$ART_NONE_UPPER"   none   null --upper-state
ART_REOPEN_UPPER="$WORK/survey-reopen-upper.json"; write_artifact "$ART_REOPEN_UPPER" reopen 10   --upper-state

REVIEW_REOPEN='{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same root cause as #10","worth_filing":true}'
REVIEW_REOPEN_11='{"verdict":"reopen","target":11,"children":[],"related":[],"reason":"same root cause as #11","worth_filing":true}'
REVIEW_NONE='{"verdict":"none","target":null,"children":[],"related":[],"reason":"the candidates differ in root cause","worth_filing":true}'
REVIEW_BAD='{"verdict":"reopen","target":4242,"children":[],"related":[],"reason":"a number that is not a candidate","worth_filing":true}'

echo "=== (a) escalation: survey none → review reopen → replaced ==="
run_review a "$ART_NONE" "$REVIEW_REOPEN"
assert_case "A-escalation" "replaced" "reopen"
if [ "$RS_PRESENT" = "yes" ]; then
    T=$(final_q "d.target"); [ "$T" = "10" ] && pass "A-escalation-target-carried" \
        || fail "A-escalation-target-carried" "review target must land in the final artifact (got: $T)"
    T=$(final_q "d.survey && d.survey.verdict"); [ "$T" = "none" ] && pass "A-escalation-survey-preserved" \
        || fail "A-escalation-survey-preserved" "the original survey verdict must be preserved under survey{} (got: $T)"
    T=$(final_q "d.review && d.review.status"); [ "$T" = "replaced" ] && pass "A-escalation-review-status" \
        || fail "A-escalation-review-status" "review.status must record the fold (got: $T)"
else
    red "A-escalation-target-carried"; red "A-escalation-survey-preserved"; red "A-escalation-review-status"
fi

echo ""
echo "=== (b) de-escalation: survey reopen → review none → replaced ==="
run_review b "$ART_REOPEN" "$REVIEW_NONE"
assert_case "B-deescalation" "replaced" "none"
if [ "$RS_PRESENT" = "yes" ]; then
    T=$(final_q "d.target"); [ "$T" = "null" ] && pass "B-deescalation-target-cleared" \
        || fail "B-deescalation-target-cleared" "a 'none' verdict must clear target (got: $T)"
else
    red "B-deescalation-target-cleared"
fi

echo ""
echo "=== (c) agreement → upheld ==="
run_review c "$ART_REOPEN" "$REVIEW_REOPEN"
assert_case "C-agreement" "upheld" "reopen"

echo ""
echo "=== (d) validation failure → survey verdict upheld, review_result invalid ==="
run_review d "$ART_REOPEN" "$REVIEW_BAD"
assert_case "D-invalid" "invalid" "reopen"
if [ "$RS_PRESENT" = "yes" ]; then
    T=$(final_q "d.review && d.review.status"); [ "$T" = "invalid" ] && pass "D-invalid-review-status" \
        || fail "D-invalid-review-status" "review.status must be 'invalid' (got: $T)"
    T=$(final_q "d.target"); [ "$T" = "10" ] && pass "D-invalid-survey-target-held" \
        || fail "D-invalid-survey-target-held" "the survey target must be held when the review is invalid (got: $T)"
else
    red "D-invalid-review-status"; red "D-invalid-survey-target-held"
fi

echo ""
echo "=== (e) codex CLI absent → SKIPPED + survey verdict upheld ==="
if [ "$RS_PRESENT" != "yes" ]; then
    red "E-skipped-first-line"; red "E-skipped-review_result"; red "E-skipped-final-verdict"; red "E-skipped-exit-0"
else
    CASE_DIR="$WORK/e"; mkdir -p "$CASE_DIR"; FINAL="$CASE_DIR/final.json"
    # PATH with the mock dir AND any real codex install dir removed, so `codex` is
    # genuinely absent while node/bash/coreutils stay reachable.
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
    OUT=$("$RWT" 30 env PATH="$NOCODEX_PATH" bash "$RS" \
            --artifact "$ART_REOPEN" --out "$FINAL" --no-log 2>"$CASE_DIR/stderr.txt")
    RC=$?
    FIRST=$(printf '%s\n' "$OUT" | head -n 1)
    LAST=$(printf '%s\n' "$OUT" | grep -E '^review_result:' | tail -n 1)
    [ "$RC" -eq 0 ] && pass "E-skipped-exit-0" || fail "E-skipped-exit-0" "want exit 0 when codex is absent (got $RC)"
    printf '%s' "$FIRST" | grep -q 'SKIPPED' && pass "E-skipped-first-line" \
        || fail "E-skipped-first-line" "first line must announce SKIPPED (got: '$FIRST')"
    [ "$LAST" = "review_result: skipped" ] && pass "E-skipped-review_result" \
        || fail "E-skipped-review_result" "want 'review_result: skipped' (got: '${LAST:-<none>}')"
    T=$(final_q "d.verdict"); [ "$T" = "reopen" ] && pass "E-skipped-final-verdict" \
        || fail "E-skipped-final-verdict" "the survey verdict must be held when the review is skipped (got: $T)"
    # No reviewer ran, so there is no worth_filing opinion to carry: the field must be
    # an explicit null rather than a defaulted boolean, otherwise the confirm gate would
    # read a fabricated "not worth filing" (or "worth filing") out of a skipped review.
    T=$(final_q "d.review && d.review.worth_filing"); [ "$T" = "null" ] && pass "E-skipped-worth-filing-null" \
        || fail "E-skipped-worth-filing-null" "a skipped review must leave review.worth_filing null (got: $T)"
fi

echo ""
echo "=== (f) codex timeout → invalid + survey verdict upheld ==="
run_review f "$ART_REOPEN" "$REVIEW_NONE" CODEX_MOCK_SLEEP=10 CODEX_TIMEOUT_SECS=2
assert_case "F-timeout" "invalid" "reopen"

echo ""
echo "=== (g) proposal missing → codex is never called, FAILED + invalid ==="
run_review g "$ART_NOPROP" "$REVIEW_NONE"
if [ "$RS_PRESENT" != "yes" ]; then
    red "G-noproposal-first-line"; red "G-noproposal-review_result"; red "G-noproposal-codex-not-called"
else
    printf '%s' "$FIRST" | grep -qi 'FAILED.*proposal' && pass "G-noproposal-first-line" \
        || fail "G-noproposal-first-line" "first line must be 'FAILED — proposal missing …' (got: '$FIRST')"
    [ "$LAST" = "review_result: invalid" ] && pass "G-noproposal-review_result" \
        || fail "G-noproposal-review_result" "want 'review_result: invalid' (got: '${LAST:-<none>}')"
    if [ -s "$WORK/g/prompt.txt" ]; then
        fail "G-noproposal-codex-not-called" "codex was invoked despite the missing proposal"
    else
        pass "G-noproposal-codex-not-called"
    fi
fi

echo ""
echo "=== (h) uppercase gh state → the review actually runs ==="
# `gh issue view --json state` answers OPEN/CLOSED, so this is the casing every
# artifact built from real gh output carries. The artifact gate runs before any
# per-verdict logic, so rejecting that casing does not merely mis-handle reopen —
# it fails the whole wrapper ("FAILED — candidate #10: state must be open or
# closed") and folds every review to invalid, whatever the reviewer said.
run_review h1 "$ART_NONE_UPPER" "$REVIEW_REOPEN_11"
assert_case "H1-uppercase-escalation" "replaced" "reopen"
if [ "$RS_PRESENT" = "yes" ]; then
    # #11 is the CLOSED candidate: it surviving the allowlist and landing as the
    # reopen target is the whole point of the fix.
    T=$(final_q "d.target"); [ "$T" = "11" ] && pass "H1-uppercase-target-carried" \
        || fail "H1-uppercase-target-carried" "an uppercase-CLOSED candidate must be usable as the reopen target (got: $T)"
    T=$(final_q "d.review && d.review.status"); [ "$T" = "replaced" ] && pass "H1-uppercase-review-status" \
        || fail "H1-uppercase-review-status" "review.status must record the fold (got: $T)"
    printf '%s' "$FIRST" | grep -q '^## Issue Verdict Review: PERFORMED' && pass "H1-uppercase-first-line-performed" \
        || fail "H1-uppercase-first-line-performed" "the review must actually run, not fail on state casing (got: '$FIRST')"
else
    red "H1-uppercase-target-carried"; red "H1-uppercase-review-status"; red "H1-uppercase-first-line-performed"
fi

# Agreement counterpart (CPR-ORTH): the same casing must not push an agreeing
# review into a replacement either.
run_review h2 "$ART_REOPEN_UPPER" "$REVIEW_REOPEN"
assert_case "H2-uppercase-agreement" "upheld" "reopen"
if [ "$RS_PRESENT" = "yes" ]; then
    T=$(final_q "d.review && d.review.status"); [ "$T" = "upheld" ] && pass "H2-uppercase-review-status" \
        || fail "H2-uppercase-review-status" "review.status must be 'upheld' when the reviewer agrees (got: $T)"
else
    red "H2-uppercase-review-status"
fi

echo ""
echo "=== prompt assembly: proposal block is present and carries the proposal title ==="
if [ "$RS_PRESENT" != "yes" ]; then
    red "P-prompt-proposal-markers"; red "P-prompt-proposal-title"; red "P-prompt-candidates-markers"; red "P-prompt-untrusted-notice"
else
    P="$WORK/a/prompt.txt"
    if [ -s "$P" ]; then
        grep -qF '[PROPOSAL START]' "$P" && grep -qF '[PROPOSAL END]' "$P" \
            && pass "P-prompt-proposal-markers" || fail "P-prompt-proposal-markers" "prompt lacks [PROPOSAL START]/[PROPOSAL END]"
        grep -qF 'Fix the flaky provenance hook' "$P" \
            && pass "P-prompt-proposal-title" || fail "P-prompt-proposal-title" "prompt does not carry proposal.title"
        grep -qF '[CANDIDATES START]' "$P" && grep -qF '[CANDIDATES END]' "$P" \
            && pass "P-prompt-candidates-markers" || fail "P-prompt-candidates-markers" "prompt lacks [CANDIDATES START]/[CANDIDATES END]"
        grep -qiE 'untrusted|do not follow' "$P" \
            && pass "P-prompt-untrusted-notice" || fail "P-prompt-untrusted-notice" "prompt lacks the untrusted-data notice before the candidate block"
    else
        fail "P-prompt-proposal-markers" "codex was never invoked in case (a) — no prompt captured"
        fail "P-prompt-proposal-title" "codex was never invoked in case (a) — no prompt captured"
        fail "P-prompt-candidates-markers" "codex was never invoked in case (a) — no prompt captured"
        fail "P-prompt-untrusted-notice" "codex was never invoked in case (a) — no prompt captured"
    fi
fi

echo ""
echo "=== final artifact schema: provenance fields gone, review.worth_filing carried ==="
# The provenance token is deleted in this PR, so the final artifact must not keep a
# vestigial copy of it: a stale key would keep downstream readers (and the confirm
# gate) able to branch on a value nothing writes any more. The reviewer's
# worth_filing boolean takes its place as the gate's input.
run_review s "$ART_NONE" "$REVIEW_REOPEN"
if [ "$RS_PRESENT" != "yes" ]; then
    red "S-no-provenance-key"; red "S-no-provenance-layer-key"; red "S-review-worth-filing"
else
    T=$(final_q "Object.prototype.hasOwnProperty.call(d, 'provenance')")
    [ "$T" = "false" ] && pass "S-no-provenance-key" \
        || fail "S-no-provenance-key" "the final artifact must no longer carry a top-level 'provenance' key (got: $T)"
    T=$(final_q "Object.prototype.hasOwnProperty.call(d, 'provenance_layer')")
    [ "$T" = "false" ] && pass "S-no-provenance-layer-key" \
        || fail "S-no-provenance-layer-key" "the final artifact must no longer carry 'provenance_layer' (got: $T)"
    T=$(final_q "d.review && d.review.worth_filing")
    [ "$T" = "true" ] && pass "S-review-worth-filing" \
        || fail "S-review-worth-filing" "review.worth_filing must carry the reviewer's boolean verbatim (got: $T)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
