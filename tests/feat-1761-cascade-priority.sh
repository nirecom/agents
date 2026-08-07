#!/usr/bin/env bash
# tests/feat-1761-cascade-priority.sh
# Tests: skills/_shared/issue-verdict-cascade.md, agents/issue-create-survey-worker.md, bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, cascade, priority, ordering, ssot, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether an LLM actually obeys the ordering. Two non-deterministic deciders (the
#   survey worker and the codex reviewer) read this SSOT; no offline test can pin
#   their output. What IS testable — and what this file pins — is that the ordering
#   is stated unambiguously in exactly one place, and that this same place is what
#   reaches BOTH deciders, with fixtures that make every rule decidable.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# S4 cascade — evaluated strictly in order, first match wins:
#   IC-C1 reopen       同一根本原因/症状の候補がある
#   IC-C2 sub-of       IC-C1 非該当 かつ parent_is_meta: true の親を持つ候補がある
#   IC-C3 make-parent  IC-C1/C2 非該当 かつ parent_number が全て null の同クラス候補が2件以上
#   IC-C4 sibling/none それ以外
# The ordering is the security property: a later rule must never be able to pre-empt
# an earlier one, because reopen (destructive) and make-parent (restructuring) carry
# the confirm gate while sibling/none do not.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
SSOT="$AGENTS_DIR/skills/_shared/issue-verdict-cascade.md"
WORKER="$AGENTS_DIR/agents/issue-create-survey-worker.md"
RS="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# first_index <file> <literal>  → 1-based line number of the first occurrence, or empty
first_index() { grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }

echo "=== S1: the cascade SSOT exists and is a prompt file within the size limit ==="
if [ ! -f "$SSOT" ]; then
    fail "S1-ssot-exists" "RED-EXPECTED: skills/_shared/issue-verdict-cascade.md not yet created"
    fail "S1-ssot-size"   "RED-EXPECTED: skills/_shared/issue-verdict-cascade.md not yet created"
else
    pass "S1-ssot-exists"
    LINES=$(wc -l < "$SSOT" | tr -d ' ')
    # rules/coding/file-split.md Pattern B: prompt files WARN >100, and S4 caps this one at 100.
    if [ "$LINES" -le 100 ]; then pass "S1-ssot-size"; else fail "S1-ssot-size" "cascade SSOT is $LINES lines (must stay <=100)"; fi
fi

echo ""
echo "=== S2: all four rule IDs are present and appear in cascade order ==="
if [ ! -f "$SSOT" ]; then
    fail "S2-rule-ids-present" "RED-EXPECTED: cascade SSOT not yet created"
    fail "S2-rule-ids-ordered" "RED-EXPECTED: cascade SSOT not yet created"
else
    MISSING=""
    for id in IC-C1 IC-C2 IC-C3 IC-C4; do grep -qF "$id" "$SSOT" || MISSING="$MISSING $id"; done
    if [ -z "$MISSING" ]; then pass "S2-rule-ids-present"; else fail "S2-rule-ids-present" "missing rule id(s):$MISSING"; fi

    I1=$(first_index "$SSOT" IC-C1); I2=$(first_index "$SSOT" IC-C2)
    I3=$(first_index "$SSOT" IC-C3); I4=$(first_index "$SSOT" IC-C4)
    if [ -n "$I1" ] && [ -n "$I2" ] && [ -n "$I3" ] && [ -n "$I4" ] \
       && [ "$I1" -lt "$I2" ] && [ "$I2" -lt "$I3" ] && [ "$I3" -lt "$I4" ]; then
        pass "S2-rule-ids-ordered"
    else
        fail "S2-rule-ids-ordered" "rules must be written in evaluation order (line numbers: C1=$I1 C2=$I2 C3=$I3 C4=$I4)"
    fi
fi

echo ""
echo "=== S3: each rule binds its trigger condition to its verdict token ==="
# A rule ID with no verdict beside it is unactionable; a verdict with no rule ID
# beside it cannot be ordered. Both must sit in the same neighbourhood.
if [ ! -f "$SSOT" ]; then
    for r in "IC-C1:reopen" "IC-C2:sub-of" "IC-C3:make-parent" "IC-C4:sibling"; do
        fail "S3-${r%%:*}-binds-${r##*:}" "RED-EXPECTED: cascade SSOT not yet created"
    done
else
    for r in "IC-C1:reopen" "IC-C2:sub-of" "IC-C3:make-parent" "IC-C4:sibling"; do
        RID="${r%%:*}"; VERD="${r##*:}"
        IDX=$(first_index "$SSOT" "$RID")
        if [ -n "$IDX" ] && sed -n "${IDX},$((IDX + 6))p" "$SSOT" | grep -qF "$VERD"; then
            pass "S3-$RID-binds-$VERD"
        else
            fail "S3-$RID-binds-$VERD" "RED-EXPECTED: '$VERD' does not appear within the $RID rule block"
        fi
    done
fi

echo ""
echo "=== S4: precedence is stated explicitly, not merely implied by layout ==="
# Reading order alone is not a contract — an LLM reading a bullet list may evaluate
# in any order. The document must say the evaluation is ordered and first-match-wins.
if [ ! -f "$SSOT" ]; then
    fail "S4-precedence-stated" "RED-EXPECTED: cascade SSOT not yet created"
    fail "S4-later-rules-gated-on-earlier" "RED-EXPECTED: cascade SSOT not yet created"
else
    if grep -qiE '順|order|先に|上から|first match|優先' "$SSOT"; then
        pass "S4-precedence-stated"
    else
        fail "S4-precedence-stated" "RED-EXPECTED: the SSOT never states that the rules are evaluated in order"
    fi
    # IC-C2 must be gated on IC-C1 being inapplicable, and IC-C3 on IC-C1/IC-C2.
    I2=$(first_index "$SSOT" IC-C2); I3=$(first_index "$SSOT" IC-C3)
    OK=1
    if [ -z "$I2" ] || ! sed -n "${I2},$((I2 + 6))p" "$SSOT" | grep -qF 'IC-C1'; then OK=0; fi
    if [ -z "$I3" ] || ! sed -n "${I3},$((I3 + 6))p" "$SSOT" | grep -qE 'IC-C1|IC-C2'; then OK=0; fi
    if [ "$OK" -eq 1 ]; then
        pass "S4-later-rules-gated-on-earlier"
    else
        fail "S4-later-rules-gated-on-earlier" "RED-EXPECTED: IC-C2/IC-C3 do not restate the non-applicability of the earlier rules"
    fi
fi

echo ""
echo "=== S5: the discriminating fields and the unresolved-candidate exclusion are named ==="
# Without these, a multi-condition candidate set is not decidable from the artifact
# alone, and 'relation unknown' would silently read as 'has no parent' — which would
# let IC-C3 fire on candidates that actually sit under a meta parent (IC-C2).
if [ ! -f "$SSOT" ]; then
    fail "S5-fields-named" "RED-EXPECTED: cascade SSOT not yet created"
    fail "S5-unresolved-excluded" "RED-EXPECTED: cascade SSOT not yet created"
    fail "S5-tiebreak-order" "RED-EXPECTED: cascade SSOT not yet created"
else
    MISSING=""
    for f in relation_status parent_number parent_is_meta; do grep -qF "$f" "$SSOT" || MISSING="$MISSING $f"; done
    if [ -z "$MISSING" ]; then pass "S5-fields-named"; else fail "S5-fields-named" "RED-EXPECTED: discriminating field(s) not named:$MISSING"; fi

    IU=$(first_index "$SSOT" 'relation_status')
    if [ -n "$IU" ] && grep -qF 'resolved' "$SSOT" && grep -qE 'IC-C2|IC-C3' "$SSOT"; then
        pass "S5-unresolved-excluded"
    else
        fail "S5-unresolved-excluded" "RED-EXPECTED: the SSOT does not exclude non-resolved candidates from IC-C2/IC-C3"
    fi

    # Tie-break is auxiliary only: closed > open, newer > older, smaller number > larger.
    if grep -qF 'closed' "$SSOT" && grep -qE '新し|newer' "$SSOT" && grep -qE '小さ|smaller' "$SSOT"; then
        pass "S5-tiebreak-order"
    else
        fail "S5-tiebreak-order" "RED-EXPECTED: the three tie-break keys are not all stated"
    fi
fi

echo ""
echo "=== S6: no numeric similarity threshold leaks into the cascade ==="
# S4 is deliberately threshold-free — a hard-coded score would make the cascade
# untestable and would silently reorder as candidate wording drifts.
if [ ! -f "$SSOT" ]; then
    fail "S6-no-numeric-threshold" "RED-EXPECTED: cascade SSOT not yet created"
else
    HITS=$(grep -nE '[0-9]+ *%|類似度 *[0-9]|similarity *(score)? *[>=<]|score *[>=<] *0?\.[0-9]' "$SSOT" || true)
    if [ -z "$HITS" ]; then
        pass "S6-no-numeric-threshold"
    else
        fail "S6-no-numeric-threshold" "a numeric similarity threshold appeared in the cascade: $(printf '%s' "$HITS" | head -n 1)"
    fi
fi

echo ""
echo "=== S7: the survey worker defers to the SSOT rather than restating the cascade ==="
# CPR-SSOT: two copies of the ordering will drift, and the drifting copy is the one
# that decides. The worker must reference the shared file.
if [ ! -f "$WORKER" ]; then
    fail "S7-worker-references-ssot" "agents/issue-create-survey-worker.md not found"
    fail "S7-worker-no-duplicate-cascade" "agents/issue-create-survey-worker.md not found"
else
    if grep -qF 'issue-verdict-cascade' "$WORKER"; then
        pass "S7-worker-references-ssot"
    else
        fail "S7-worker-references-ssot" "RED-EXPECTED: the worker does not reference skills/_shared/issue-verdict-cascade.md"
    fi
    # A reference is fine; a second full statement of the rules is not. Count how many
    # rule IDs carry their own trigger prose in the worker.
    DUP=0
    for id in IC-C1 IC-C2 IC-C3 IC-C4; do
        IDX=$(first_index "$WORKER" "$id")
        [ -n "$IDX" ] && [ "$(sed -n "${IDX}p" "$WORKER" | wc -c)" -gt 120 ] && DUP=$((DUP + 1))
    done
    if [ "$DUP" -eq 0 ]; then
        pass "S7-worker-no-duplicate-cascade"
    else
        fail "S7-worker-no-duplicate-cascade" "$DUP rule(s) are restated in full in the worker instead of referencing the SSOT"
    fi
fi

echo ""
echo "=== S8: the ordering actually reaches the codex reviewer, in order ==="
# The SSOT is `cat`-ed into the assembled prompt (S13 step 2). If that step were
# dropped or reordered, every test above would still pass while the reviewer
# decided with no cascade at all.
if [ ! -f "$RS" ] || [ ! -f "$SSOT" ]; then
    fail "S8-cascade-in-prompt"          "RED-EXPECTED: review-survey-verdict-codex.sh and/or the cascade SSOT not yet created"
    fail "S8-cascade-ordered-in-prompt"  "RED-EXPECTED: review-survey-verdict-codex.sh and/or the cascade SSOT not yet created"
    fail "S8-cascade-precedes-candidates" "RED-EXPECTED: review-survey-verdict-codex.sh and/or the cascade SSOT not yet created"
else
    MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"
    cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
printf '%s\n' '{"verdict":"none","target":null,"children":[],"related":[],"reason":"no overlap"}'
MOCK
    chmod +x "$MOCKDIR/codex"

    # Multi-condition fixture: EVERY rule's precondition holds at once.
    #  #10 shares the root cause with the proposal            → IC-C1 applies
    #  #10 also has a meta parent (#99)                       → IC-C2 would apply
    #  #11 and #12 are same-class orphans (parent_number null) → IC-C3 would apply
    #  all three are plausible siblings                       → IC-C4 would apply
    # Only IC-C1 may win. The fixture carries every discriminating field so the
    # decision is derivable from the artifact alone.
    ART="$WORK/multi.json"
    cat > "$ART" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "provenance token is consumed twice", "background": "BG", "changes": "CH" },
  "verdict": "reopen", "target": 10, "children": [], "related": [11, 12],
  "reason": "#10 is the same root cause",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "provenance token consumed twice", "state": "closed", "labels": ["type:task"],
      "body": "same root cause as the proposal", "relation_status": "resolved",
      "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "provenance marker cleanup", "state": "open", "labels": ["type:task"],
      "body": "orphan sibling", "relation_status": "resolved",
      "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 12, "title": "provenance marker rotation", "state": "open", "labels": ["type:task"],
      "body": "orphan sibling", "relation_status": "resolved",
      "parent_number": null, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

    PROMPT="$WORK/prompt.txt"
    CODEX_PROMPT_LOG="$PROMPT" PATH="$MOCKDIR:$PATH" \
      "$RWT" 40 bash "$RS" --artifact "$ART" --out "$WORK/final.json" --no-log >/dev/null 2>&1

    if [ ! -s "$PROMPT" ]; then
        fail "S8-cascade-in-prompt"           "the assembled prompt was never captured (codex not invoked?)"
        fail "S8-cascade-ordered-in-prompt"   "the assembled prompt was never captured"
        fail "S8-cascade-precedes-candidates" "the assembled prompt was never captured"
    else
        MISSING=""
        for id in IC-C1 IC-C2 IC-C3 IC-C4; do grep -qF "$id" "$PROMPT" || MISSING="$MISSING $id"; done
        if [ -z "$MISSING" ]; then pass "S8-cascade-in-prompt"; else fail "S8-cascade-in-prompt" "rule(s) absent from the assembled prompt:$MISSING"; fi

        P1=$(first_index "$PROMPT" IC-C1); P2=$(first_index "$PROMPT" IC-C2)
        P3=$(first_index "$PROMPT" IC-C3); P4=$(first_index "$PROMPT" IC-C4)
        if [ -n "$P1" ] && [ -n "$P2" ] && [ -n "$P3" ] && [ -n "$P4" ] \
           && [ "$P1" -lt "$P2" ] && [ "$P2" -lt "$P3" ] && [ "$P3" -lt "$P4" ]; then
            pass "S8-cascade-ordered-in-prompt"
        else
            fail "S8-cascade-ordered-in-prompt" "the cascade reached codex out of order (C1=$P1 C2=$P2 C3=$P3 C4=$P4)"
        fi

        PC=$(first_index "$PROMPT" '[CANDIDATES START]')
        if [ -n "$P4" ] && [ -n "$PC" ] && [ "$P4" -lt "$PC" ]; then
            pass "S8-cascade-precedes-candidates"
        else
            fail "S8-cascade-precedes-candidates" "the rules must be stated before the untrusted candidate block (rules end=$P4, candidates start=$PC)"
        fi
    fi
fi

echo ""
echo "=== S9: the multi-condition fixture carries every field each rule needs ==="
# Guards the fixtures themselves: if a candidate row omitted parent_is_meta, an
# IC-C2-vs-IC-C3 disagreement would be unresolvable and the ordering untestable.
FIXTURE="$WORK/multi.json"
if [ ! -f "$FIXTURE" ]; then
    fail "S9-fixture-fields-complete" "RED-EXPECTED: the multi-condition fixture is only built once the review script exists"
else
    OUT=$("$RWT" 15 node -e "
const d = JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const need = ['number','title','state','labels','body','relation_status','parent_number','parent_is_meta','has_sub_issues'];
const bad = d.candidates.filter(c => need.some(k => !(k in c))).map(c => c.number);
const orphans = d.candidates.filter(c => c.relation_status === 'resolved' && c.parent_number === null).length;
const metaParents = d.candidates.filter(c => c.parent_is_meta === true).length;
process.stdout.write(JSON.stringify({ bad, orphans, metaParents }));" "$(node_path "$FIXTURE")" 2>/dev/null)
    # Every rule's precondition must genuinely hold in the fixture, or the
    # ordering assertion above would be vacuous.
    if printf '%s' "$OUT" | grep -q '"bad":\[\]' \
       && printf '%s' "$OUT" | grep -q '"orphans":2' \
       && printf '%s' "$OUT" | grep -q '"metaParents":1'; then
        pass "S9-fixture-fields-complete"
    else
        fail "S9-fixture-fields-complete" "the multi-condition fixture does not satisfy all four preconditions: $OUT"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
