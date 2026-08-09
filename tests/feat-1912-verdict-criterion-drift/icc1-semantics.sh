#!/usr/bin/env bash
# tests/feat-1912-verdict-criterion-drift/icc1-semantics.sh
# Tests: skills/_shared/issue-verdict-cascade.md
# Tags: issue-create, verdict, cascade, icc1, same-fix, doc-contract, ssot, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Whether a real grader OBEYS the criterion. Only a real-model run could show that;
#   #1912 accepted that residual risk explicitly. What is pinnable is that the criterion
#   the graders are handed still says what #1912 decided it should say.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Section of tests/feat-1912-verdict-criterion-drift.sh (subprocess; tests/lib/section-runner.sh).
#
# The parent pins fragments of the new IC-C1 sentence (O2–O7, N1–N3). This file pins the
# criterion as a semantic WHOLE — the four properties that make it decidable:
#   (a) simultaneity      one fix, both items, at the same time — not two fixes in a row
#   (b) cause identity    the shared thing is the underlying cause, not the appearance
#   (c) symptom exclusion symptom similarity ALONE is named and refused, for reopen
#   (d) reason contract   `reason` required; when same_fix is true it must make the single
#                         covering fix identifiable
# Section-scoped (CPR-SC): (a)–(c) read the IC-C1 block, (d) the `reason` rule. A
# whole-file grep would accept a sentence from anywhere (see M6 in the parent).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASCADE="$AGENTS_DIR/skills/_shared/issue-verdict-cascade.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# md_section <file> <heading-regex> → body of that `## ` section (headings excluded).
md_section() {
    [ -f "$1" ] || return 0
    awk -v re="$2" '
      /^##[[:space:]]/ { inb = ($0 ~ re) ? 1 : 0; next }
      inb { print }' "$1"
}

ICC1="$WORK/icc1.txt"; ICC1_FLAT="$WORK/icc1-flat.txt"
md_section "$CASCADE" '^##[[:space:]]+IC-C1' > "$ICC1" 2>/dev/null || : > "$ICC1"
tr '\n' ' ' < "$ICC1" > "$ICC1_FLAT" 2>/dev/null || : > "$ICC1_FLAT"

# The `reason` contract is a bullet, not a section: located by subject so a heading
# reshuffle cannot report a present contract as missing, and flattened because it wraps.
REASON_RULE="$WORK/reason-rule.txt"
: > "$REASON_RULE"
if [ -f "$CASCADE" ]; then
    awk '/^-?[[:space:]]*`reason`/ { inb = 1; buf = $0; next }
         inb && /^-[[:space:]]/ { inb = 0 }
         inb { buf = buf " " $0 }
         END { if (buf != "") print buf }' "$CASCADE" > "$REASON_RULE" 2>/dev/null || true
fi

echo "=== Q: the IC-C1 criterion as a semantic whole (4 properties) ==="

# Non-vacuity gate: if extraction produced nothing, every grep below fails for the wrong
# reason and points the next reader at the wrong defect.
if [ -s "$ICC1" ]; then
    pass "Q0-icc1-block-extracted"
else
    fail "Q0-icc1-block-extracted" "no '## IC-C1' section body found in $CASCADE — Q1..Q3 below read that block"
fi
if [ -s "$REASON_RULE" ]; then
    pass "Q0b-reason-rule-extracted"
else
    fail "Q0b-reason-rule-extracted" "no \`reason\` rule found in $CASCADE — Q4/Q5 read that rule"
fi

# (a) SIMULTANEITY. "one fix resolves both" is also true of two issues one PR touches in
# sequence, so the criterion must bind both resolutions to the SAME fix event.
if grep -qiE 'one fix[^.?]*(resolve|fix|close)[^.?]*(this proposal|the proposal)[^.?]*(candidate|issue)[^.?]*(at the same time|simultaneous)' "$ICC1_FLAT"; then
    pass "Q1-criterion-is-one-fix-both-sides-at-the-same-time"
else
    fail "Q1-criterion-is-one-fix-both-sides-at-the-same-time" "IC-C1 must ask, in one sentence, whether ONE fix resolves the proposal AND the candidate AT THE SAME TIME; block: $(cat "$ICC1_FLAT")"
fi

# (a′) It must be the DECIDING question: relegated to an aside, Q1 would still pass.
if grep -qiE '(ask|answer)[^.?]*(question|one fix)|if the answer is yes[^.]*(decide|reopen)' "$ICC1_FLAT"; then
    pass "Q2-criterion-is-posed-as-the-deciding-question"
else
    fail "Q2-criterion-is-posed-as-the-deciding-question" "the one-fix sentence must be posed as the question IC-C1 decides by, not stated as an aside; block: $(cat "$ICC1_FLAT")"
fi

# (b) CAUSE IDENTITY. Grounded in the underlying/root cause — the word separating "the
# same defect" from "two defects that look alike".
if grep -qiE '(underlying|root)[- ]?cause' "$ICC1_FLAT"; then
    pass "Q3-criterion-rests-on-cause-identity"
else
    fail "Q3-criterion-rests-on-cause-identity" "IC-C1 must ground the match in the underlying/root cause, not in appearance; block: $(cat "$ICC1_FLAT")"
fi

# (b′) The cause test needs its consequence — differing causes mean two fixes. A bare
# mention of "root cause" is decoration.
if grep -qiE '(underlying|root)[- ]?cause[^.]*(differ|different|not the same)[^.]*(two|separate|distinct)[^.]*fix' "$ICC1_FLAT" \
   || grep -qiE '(two|separate|distinct)[^.]*fix[^.]*(underlying|root)[- ]?cause[^.]*(differ|different)' "$ICC1_FLAT"; then
    pass "Q3b-differing-causes-mean-two-fixes"
else
    fail "Q3b-differing-causes-mean-two-fixes" "IC-C1 must state the consequence of the cause test — different underlying causes need two separate fixes; block: $(cat "$ICC1_FLAT")"
fi

# (c) SYMPTOM EXCLUSION. Refused by name, in the negative, and for a named verdict
# (reopen). "ALONE" is the substance: symptoms stay admissible evidence, just not
# sufficient on their own.
if grep -qiE 'symptom[^.]*(alone|only|by itself|on its own)[^.]*(must never|never|must not|do not)' "$ICC1_FLAT" \
   || grep -qiE '(must never|never|must not|do not)[^.]*symptom[^.]*(alone|only|by itself|on its own)' "$ICC1_FLAT"; then
    pass "Q4-symptom-similarity-alone-is-refused"
else
    fail "Q4-symptom-similarity-alone-is-refused" "IC-C1 must refuse symptom similarity ALONE in the negative — 'alone' is what keeps symptoms admissible as evidence while denying them sufficiency; block: $(cat "$ICC1_FLAT")"
fi

if grep -qiE 'symptom[^.]*reopen|reopen[^.]*symptom' "$ICC1_FLAT"; then
    pass "Q4b-symptom-refusal-names-reopen"
else
    fail "Q4b-symptom-refusal-names-reopen" "the symptom refusal must name the verdict it constrains (reopen), or it constrains nothing; block: $(cat "$ICC1_FLAT")"
fi

echo ""
echo "=== Q5/Q6: the reason contract makes the one-fix claim falsifiable ==="

# (d) REASON REQUIRED, and it must identify the matching rule — otherwise the review
# stage has nothing to check.
if grep -qiE '`?reason`?[^.]*(one sentence|required|must)' "$REASON_RULE" \
   && grep -qiE 'rule[^.]*identifiab|identifiab[^.]*rule' "$REASON_RULE"; then
    pass "Q5-reason-is-required-and-identifies-the-rule"
else
    fail "Q5-reason-is-required-and-identifies-the-rule" "the cascade must require a \`reason\` that makes the matching rule identifiable; rule: $(cat "$REASON_RULE")"
fi

# (d′) The #1912 addition: when same_fix is true the reason must make THE SINGLE COVERING
# FIX identifiable, or the claim is unfalsifiable.
if grep -qiE 'same_fix[^.]*(true)[^.]*(single|one)[^.]*fix[^.]*identifiab' "$REASON_RULE" \
   || grep -qiE '(single|one)[^.]*fix[^.]*identifiab[^.]*same_fix[^.]*true' "$REASON_RULE"; then
    pass "Q6-true-same-fix-requires-an-identifiable-single-fix"
else
    fail "Q6-true-same-fix-requires-an-identifiable-single-fix" "when same_fix is true the reason must make the single covering fix identifiable — otherwise the field asserts something nobody can check; rule: $(cat "$REASON_RULE")"
fi

# Counterweight to Q6: the requirement must stay conditional — on the four false verdicts
# there is no single covering fix to name.
if grep -qiE 'when[^.]*same_fix[^.]*true|same_fix[^.]*is[^.]*`?true`?[^.]*(so|then)' "$REASON_RULE"; then
    pass "Q6b-single-fix-requirement-is-conditional-on-same-fix"
else
    fail "Q6b-single-fix-requirement-is-conditional-on-same-fix" "the single-fix identification must be scoped to same_fix=true; on a false verdict there is no single covering fix to name; rule: $(cat "$REASON_RULE")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
